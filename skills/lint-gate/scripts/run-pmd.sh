#!/usr/bin/env bash
# run-pmd.sh — PMD + CPD runner
# 用法: source run-pmd.sh && run_pmd <module> [project_root] [filelist]
#        source run-pmd.sh && run_cpd <module> [project_root] [filelist]
#
# module:       模組目錄名，或 "." 代表單模組專案
# project_root: 專案根目錄（預設 "."）
# filelist:     增量模式的檔案清單路徑。空字串 = 全量模式。
#
# PMD 版本相容性：目前語法為 PMD 6.x。
# PMD 7.x CLI 語法不同（pmd check --dir），升級時需依 major version 分流。

set -euo pipefail

TOOLS_DIR="$HOME/.claude/tools"
VERSIONS_FILE="$TOOLS_DIR/lint-gate-versions.txt"

_load_versions() {
    if [[ ! -f "$VERSIONS_FILE" ]]; then
        echo "ERROR: $VERSIONS_FILE not found. Run detect-env.sh first." >&2
        return 1
    fi
    PMD_ENGINE_VERSION=$(grep '^pmd-engine=' "$VERSIONS_FILE" | cut -d= -f2)
    MINIMUM_TOKENS=$(grep '^minimumTokens=' "$VERSIONS_FILE" | cut -d= -f2)
    RULESET_PATH=$(grep '^ruleset=' "$VERSIONS_FILE" | cut -d= -f2 || true)

    local pmd_dir="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}"
    PMD_RUN="${PMD_RUN:-$pmd_dir/bin/run.sh}"
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
        echo "category/java/bestpractices.xml,category/java/errorprone.xml,category/java/codestyle.xml"
    fi
}

# Try run.sh first; fallback to java -cp (Git Bash readlink -f issue)
_exec_pmd() {
    local tool="$1"
    shift
    local tool_args=("$@")
    local exit_code=0
    local stderr_file
    stderr_file=$(mktemp)

    bash "$PMD_RUN" "$tool" "${tool_args[@]}" 2>"$stderr_file" || exit_code=$?

    if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
        cat "$stderr_file" >&2
        echo "  (run.sh failed with $exit_code, trying java -cp fallback...)" >&2

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
    local cache_file="$TOOLS_DIR/pmd-cache-${module//\//_}.bin"

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        return 1
    fi

    # Incremental: empty filelist = nothing to check
    if [[ -n "$filelist" && ! -s "$filelist" ]]; then
        echo "PMD: No changed files to check (incremental mode)."
        return 0
    fi

    local label="$module"
    [[ "$module" == "." ]] && label="(root)"

    if [[ -n "$filelist" ]]; then
        echo "Running PMD on $label — $(wc -l < "$filelist") changed file(s) (engine=$PMD_ENGINE_VERSION)..."
    else
        echo "Running PMD on $label — full scan (engine=$PMD_ENGINE_VERSION)..."
    fi

    # Show which ruleset is being used
    if [[ "$ruleset" == category/* ]]; then
        echo "  (Using PMD built-in rulesets — no project ruleset found)"
    else
        echo "  (Ruleset: $ruleset)"
    fi

    local report_file
    report_file=$(mktemp /tmp/pmd-report-XXXXXX.txt)

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
        echo "PMD: No violations found."
        rm -f "$report_file"
        return 0
    elif [[ $exit_code -eq 4 ]]; then
        local count
        count=$(wc -l < "$report_file")
        echo "PMD: $count violation(s) found."
        cat "$report_file"
        rm -f "$report_file"
        return 4
    else
        echo "ERROR: PMD exited with code $exit_code" >&2
        cat "$report_file" 2>/dev/null
        rm -f "$report_file"
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
        return 1
    fi

    if [[ -n "$filelist" && ! -s "$filelist" ]]; then
        echo "CPD: No changed files to check (incremental mode)."
        return 0
    fi

    local label="$module"
    [[ "$module" == "." ]] && label="(root)"

    local mode_label="full scan"
    [[ -n "$filelist" ]] && mode_label="full scan, filtered to changed files"
    echo "Running CPD on $label — $mode_label (minimumTokens=$MINIMUM_TOKENS)..."

    local report_file
    report_file=$(mktemp /tmp/cpd-report-XXXXXX.txt)

    local exit_code=0
    _exec_pmd cpd \
        --minimum-tokens "$MINIMUM_TOKENS" \
        --dir "$src_dir" \
        --language java \
        --format text \
        --encoding UTF-8 \
        > "$report_file" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "CPD: No duplications found."
        rm -f "$report_file"
        return 0
    elif [[ $exit_code -eq 4 ]]; then
        if [[ -n "$filelist" ]]; then
            # Incremental: filter output to only show duplications involving changed files
            local filtered_file
            filtered_file=$(mktemp /tmp/cpd-filtered-XXXXXX.txt)
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
                    while IFS= read -r changed_file; do
                        if [[ "$line" == *"$changed_file"* ]]; then
                            block_relevant=1
                            break
                        fi
                    done < "$filelist"
                fi
            done < "$report_file"
            if [[ $in_block -eq 1 && $block_relevant -eq 1 ]]; then
                echo "$block" >> "$filtered_file"
            fi

            if [[ -s "$filtered_file" ]]; then
                local count
                count=$(grep -c '^Found a' "$filtered_file" 2>/dev/null || echo "0")
                echo "CPD: $count duplication(s) involving changed files."
                cat "$filtered_file"
            else
                echo "CPD: Duplications exist but none involve changed files."
            fi
            rm -f "$filtered_file"
        else
            local count
            count=$(grep -c '^Found a' "$report_file" 2>/dev/null || echo "0")
            echo "CPD: $count duplication(s) found."
            cat "$report_file"
        fi
        rm -f "$report_file"
        return 4
    else
        echo "ERROR: CPD exited with code $exit_code" >&2
        cat "$report_file" 2>/dev/null
        rm -f "$report_file"
        return "$exit_code"
    fi
}
