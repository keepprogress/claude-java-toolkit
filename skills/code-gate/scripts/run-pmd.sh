#!/usr/bin/env bash
# run-pmd.sh — PMD + CPD runner
# 用法: source run-pmd.sh && run_pmd <module> [project_root] [filelist]
#        source run-pmd.sh && run_cpd <module> [project_root] [filelist]
#
# module:       模組目錄名，或 "." 代表單模組專案
# project_root: 專案根目錄（預設 "."）
# filelist:     增量模式的檔案清單路徑。空字串 = 全量模式。
#
# PMD 版本相容性：支援 PMD 6.x 和 7.x，根據 major version 自動分流 CLI 語法。
#
# 輸出協定:
#   stderr → debug / progress 訊息
#   stdout → violation 明細（供 Claude auto-fix）+ ---CODE_GATE_RESULT--- JSON summary

set -euo pipefail

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "ERROR: bash 4+ required for run-pmd.sh (current: $BASH_VERSION)" >&2
    echo "On macOS: brew install bash" >&2
    exit 1
fi

TOOLS_DIR="${CODE_GATE_TOOLS_DIR:-$HOME/.claude/tools}"
VERSIONS_FILE="$TOOLS_DIR/code-gate-versions.txt"

# Temp file tracking for trap-based cleanup
_CODE_GATE_TMP_FILES=()
_code_gate_cleanup() { rm -f "${_CODE_GATE_TMP_FILES[@]}" 2>/dev/null; }
trap _code_gate_cleanup EXIT

_tracked_mktemp() {
    local f
    f=$(mktemp "$@")
    _CODE_GATE_TMP_FILES+=("$f")
    echo "$f"
}

log() { echo "$1" >&2; }

_load_versions() {
    if [[ ! -f "$VERSIONS_FILE" ]]; then
        echo "ERROR: $VERSIONS_FILE not found. Please re-run /claude-java-toolkit:code-gate — it will auto-detect and set up the environment." >&2
        return 1
    fi
    PMD_ENGINE_VERSION=$(grep '^pmd-engine=' "$VERSIONS_FILE" | cut -d= -f2)
    MINIMUM_TOKENS=$(grep '^minimumTokens=' "$VERSIONS_FILE" | cut -d= -f2)
    RULESET_PATH=$(grep '^ruleset=' "$VERSIONS_FILE" | cut -d= -f2 || true)

    PMD_MAJOR="${PMD_ENGINE_VERSION%%.*}"
    local pmd_dir="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}"
    if [[ "$PMD_MAJOR" -ge 7 ]]; then
        PMD_RUN="${PMD_RUN:-$pmd_dir/bin/pmd}"
    else
        PMD_RUN="${PMD_RUN:-$pmd_dir/bin/run.sh}"
    fi
    PMD_DIR="$pmd_dir"
}

# Resolve source dir: module can be "." for single-module projects
_resolve_src_dir() {
    local module="$1"
    local project_root="$2"

    if [[ "$module" == "." ]]; then
        echo "$project_root/src/main/java"
    else
        echo "$project_root/$module/src/main/java"
    fi
}

# Resolve ruleset: project file > PMD built-in categories
_resolve_ruleset() {
    local project_root="$1"

    if [[ -n "${RULESET_PATH:-}" && -f "$project_root/$RULESET_PATH" ]]; then
        echo "$project_root/$RULESET_PATH"
    elif [[ -f "$project_root/pmd-rules.xml" ]]; then
        echo "$project_root/pmd-rules.xml"
    elif [[ -f "$project_root/pmd-ruleset.xml" ]]; then
        echo "$project_root/pmd-ruleset.xml"
    else
        echo "category/java/bestpractices.xml,category/java/errorprone.xml,category/java/codestyle.xml,category/java/multithreading.xml,category/java/performance.xml"
    fi
}

# Execute PMD/CPD with version-aware CLI syntax and fallback
_exec_pmd() {
    local tool="$1"
    shift
    local tool_args=("$@")
    local exit_code=0
    local stderr_file
    stderr_file=$(_tracked_mktemp)

    if [[ "$PMD_MAJOR" -ge 7 ]]; then
        # PMD 7.x: bin/pmd <tool> [args] (e.g., pmd check ..., pmd cpd ...)
        local pmd_cmd="$tool"
        [[ "$tool" == "pmd" ]] && pmd_cmd="check"

        bash "$PMD_RUN" "$pmd_cmd" "${tool_args[@]}" --no-progress 2>"$stderr_file" || exit_code=$?

        # PMD 7.3.0+: exit code 5 = recoverable errors, report still valid
        if [[ $exit_code -eq 5 ]]; then
            log "  (PMD 7: completed with recoverable errors — report is still valid)"
            exit_code=4
        fi

        if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
            cat "$stderr_file" >&2
        fi
    else
        # PMD 6.x: bin/run.sh <tool> [args]
        bash "$PMD_RUN" "$tool" "${tool_args[@]}" 2>"$stderr_file" || exit_code=$?

        if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
            cat "$stderr_file" >&2
            log "  (run.sh failed with $exit_code, trying java -cp fallback...)"

            local main_class
            case "$tool" in
                pmd) main_class="net.sourceforge.pmd.PMD" ;;
                cpd) main_class="net.sourceforge.pmd.cpd.CPD" ;;
                *)   echo "ERROR: Unknown PMD tool: $tool" >&2; rm -f "$stderr_file"; return 1 ;;
            esac

            exit_code=0
            java -cp "$PMD_DIR/lib/*" "$main_class" "${tool_args[@]}" 2>"$stderr_file" || exit_code=$?

            if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
                cat "$stderr_file" >&2
            fi
        fi
    fi

    rm -f "$stderr_file"
    return $exit_code
}

run_pmd() {
    local module="$1"
    local project_root="${2:-.}"
    local filelist="${3:-}"
    _load_versions

    local src_dir
    src_dir=$(_resolve_src_dir "$module" "$project_root")
    local ruleset
    ruleset=$(_resolve_ruleset "$project_root")
    # Include project root hash in cache key to prevent cross-project cache pollution
    local project_hash
    project_hash=$(echo "$project_root" | md5sum 2>/dev/null | cut -c1-8 || echo "default")
    local cache_file="$TOOLS_DIR/pmd-cache-${project_hash}-${module//\//_}.bin"
    local ruleset_type="project"
    [[ "$ruleset" == category/* ]] && ruleset_type="built-in"

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"pmd\",\"status\":\"error\",\"exit_code\":1,\"message\":\"source directory not found\"}"
        return 1
    fi

    # Incremental: empty filelist = nothing to check
    if [[ -n "$filelist" && ! -s "$filelist" ]]; then
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"pmd\",\"status\":\"skip\",\"violations\":0,\"files_checked\":0,\"engine\":\"$PMD_ENGINE_VERSION\",\"ruleset_type\":\"$ruleset_type\"}"
        return 0
    fi

    local label="$module"
    [[ "$module" == "." ]] && label="(root)"
    local file_count=0

    if [[ -n "$filelist" ]]; then
        file_count=$(wc -l < "$filelist")
        log "Running PMD on $label — $file_count changed file(s) (engine=$PMD_ENGINE_VERSION)..."
    else
        log "Running PMD on $label — full scan (engine=$PMD_ENGINE_VERSION)..."
    fi

    if [[ "$ruleset_type" == "built-in" ]]; then
        log "  (Using PMD built-in rulesets — no project ruleset found)"
    else
        log "  (Ruleset: $ruleset)"
    fi

    local report_file
    report_file=$(_tracked_mktemp /tmp/pmd-report-XXXXXX.txt)

    local exit_code=0
    if [[ -n "$filelist" ]]; then
        _exec_pmd pmd \
            -filelist "$filelist" \
            -R "$ruleset" \
            -f text \
            -r "$report_file" \
            --cache "$cache_file" || exit_code=$?
    else
        _exec_pmd pmd \
            -d "$src_dir" \
            -R "$ruleset" \
            -f text \
            -r "$report_file" \
            --cache "$cache_file" || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        log "PMD: No violations found."
        rm -f "$report_file"
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"pmd\",\"status\":\"pass\",\"violations\":0,\"files_checked\":$file_count,\"engine\":\"$PMD_ENGINE_VERSION\",\"ruleset_type\":\"$ruleset_type\"}"
        return 0
    elif [[ $exit_code -eq 4 ]]; then
        local count
        count=$(wc -l < "$report_file")
        log "PMD: $count violation(s) found."
        # Violation details on stdout for Claude to parse and auto-fix
        cat "$report_file"
        rm -f "$report_file"
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"pmd\",\"status\":\"fail\",\"violations\":$count,\"files_checked\":$file_count,\"engine\":\"$PMD_ENGINE_VERSION\",\"ruleset_type\":\"$ruleset_type\"}"
        return 4
    else
        echo "ERROR: PMD exited with code $exit_code" >&2
        cat "$report_file" >&2 2>/dev/null
        rm -f "$report_file"
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"pmd\",\"status\":\"error\",\"exit_code\":$exit_code}"
        return "$exit_code"
    fi
}

run_cpd() {
    local module="$1"
    local project_root="${2:-.}"
    local filelist="${3:-}"
    _load_versions

    local src_dir
    src_dir=$(_resolve_src_dir "$module" "$project_root")

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"cpd\",\"status\":\"error\",\"exit_code\":1,\"message\":\"source directory not found\"}"
        return 1
    fi

    if [[ -n "$filelist" && ! -s "$filelist" ]]; then
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"cpd\",\"status\":\"skip\",\"duplications\":0}"
        return 0
    fi

    local label="$module"
    [[ "$module" == "." ]] && label="(root)"

    local mode_label="full scan"
    [[ -n "$filelist" ]] && mode_label="incremental"
    log "Running CPD on $label — $mode_label (minimumTokens=$MINIMUM_TOKENS)..."

    local report_file
    report_file=$(_tracked_mktemp /tmp/cpd-report-XXXXXX.txt)

    local exit_code=0
    _exec_pmd cpd \
        --minimum-tokens "$MINIMUM_TOKENS" \
        --dir "$src_dir" \
        --language java \
        --format text \
        --encoding UTF-8 \
        > "$report_file" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log "CPD: No duplications found."
        rm -f "$report_file"
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"cpd\",\"status\":\"pass\",\"duplications\":0}"
        return 0
    elif [[ $exit_code -eq 4 ]]; then
        if [[ -n "$filelist" ]]; then
            # Design decision: CPD requires full source context for cross-file duplication
            # detection, so we scan the entire src_dir even in incremental mode, then
            # post-filter to only report duplications involving changed files.
            # Using --filelist would miss "changed file duplicates unchanged file" cases.
            # Build associative array for O(1) lookup instead of O(n×m) nested loop
            declare -A changed_set
            while IFS= read -r f; do
                changed_set["$f"]=1
            done < "$filelist"

            local filtered_file
            filtered_file=$(_tracked_mktemp /tmp/cpd-filtered-XXXXXX.txt)
            local in_block=0 block="" block_relevant=0

            while IFS= read -r line; do
                if [[ "$line" == "Found a"* ]]; then
                    if [[ $in_block -eq 1 && $block_relevant -eq 1 ]]; then
                        echo "$block" >> "$filtered_file"
                    fi
                    block="$line"
                    block_relevant=0
                    in_block=1
                elif [[ $in_block -eq 1 ]]; then
                    block="$block"$'\n'"$line"
                    # Extract file path from CPD output line and check against set
                    local candidate
                    candidate=$(echo "$line" | sed -n 's/.*Starting at line .* of \(.*\)/\1/p')
                    if [[ -n "$candidate" && -n "${changed_set[$candidate]:-}" ]]; then
                        block_relevant=1
                    fi
                fi
            done < "$report_file"
            if [[ $in_block -eq 1 && $block_relevant -eq 1 ]]; then
                echo "$block" >> "$filtered_file"
            fi

            if [[ -s "$filtered_file" ]]; then
                local count
                count=$(grep -c '^Found a' "$filtered_file" 2>/dev/null || echo "0")
                log "CPD: $count duplication(s) involving changed files."
                cat "$filtered_file"
                rm -f "$filtered_file" "$report_file"
                echo "---CODE_GATE_RESULT---"
                echo "{\"tool\":\"cpd\",\"status\":\"fail\",\"duplications\":$count,\"mode\":\"incremental\"}"
            else
                log "CPD: Duplications exist but none involve changed files."
                rm -f "$filtered_file" "$report_file"
                echo "---CODE_GATE_RESULT---"
                echo "{\"tool\":\"cpd\",\"status\":\"pass\",\"duplications\":0,\"mode\":\"incremental\",\"note\":\"duplications exist outside changed files\"}"
                return 0
            fi
        else
            local count
            count=$(grep -c '^Found a' "$report_file" 2>/dev/null || echo "0")
            log "CPD: $count duplication(s) found."
            cat "$report_file"
            rm -f "$report_file"
            echo "---CODE_GATE_RESULT---"
            echo "{\"tool\":\"cpd\",\"status\":\"fail\",\"duplications\":$count,\"mode\":\"full\"}"
        fi
        return 4
    else
        echo "ERROR: CPD exited with code $exit_code" >&2
        cat "$report_file" >&2 2>/dev/null
        rm -f "$report_file"
        echo "---CODE_GATE_RESULT---"
        echo "{\"tool\":\"cpd\",\"status\":\"error\",\"exit_code\":$exit_code}"
        return "$exit_code"
    fi
}
