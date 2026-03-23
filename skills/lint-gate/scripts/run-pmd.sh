#!/usr/bin/env bash
# run-pmd.sh — 用獨立 PMD CLI 執行 PMD + CPD 檢查
# 用法: source run-pmd.sh && run_pmd <module> [project_root] [filelist]
#        source run-pmd.sh && run_cpd <module> [project_root] [filelist]
#
# filelist: 可選的檔案清單路徑。提供時只掃該清單內的檔案（增量模式）。
#           不提供時掃整個模組（全量模式，適用 --full 或 CI）。
#
# 需要先跑 detect-env.sh 或手動 export PMD_RUN, PMD_ENGINE_VERSION 等
# 依賴: bash, java (PMD 用 Java 8+ 即可)
#
# PMD 版本相容性：目前語法為 PMD 6.x（bin/run.sh pmd -d ... -R ...）。
# 若 maven-pmd-plugin 升級到 4.x（PMD 7.x），CLI 語法會變（pmd check --dir ... --rulesets ...）。
# 屆時需根據 PMD_ENGINE_VERSION 的 major version 分流。

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
    RULESET_PATH=$(grep '^ruleset=' "$VERSIONS_FILE" | cut -d= -f2)

    local pmd_dir="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}"
    PMD_RUN="${PMD_RUN:-$pmd_dir/bin/run.sh}"
    PMD_DIR="$pmd_dir"
}

# Try run.sh first; if it fails (readlink -f issue on Git Bash), use java -cp
# PMD 6.x run.sh 用第一引數選工具: pmd → net.sourceforge.pmd.PMD
#                                    cpd → net.sourceforge.pmd.cpd.CPD
# fallback 必須同樣分流，且不把子命令名稱傳給 main class
_exec_pmd() {
    local tool="$1"
    shift
    local tool_args=("$@")
    local exit_code=0
    local stderr_file
    stderr_file=$(mktemp)

    # Attempt 1: run.sh
    # stderr 存到 temp file — PMD 6.x 輸出大量 diagnostic 噪音（Auxclasspath 等），
    # 但不能用 2>/dev/null 全吞，否則真正錯誤也看不到
    bash "$PMD_RUN" "$tool" "${tool_args[@]}" 2>"$stderr_file" || exit_code=$?

    if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
        # run.sh might have failed due to readlink -f — fallback to java -cp
        cat "$stderr_file" >&2  # 顯示 stderr 幫助 debug
        echo "  (run.sh failed with $exit_code, trying java -cp fallback...)" >&2

        local main_class
        case "$tool" in
            pmd) main_class="net.sourceforge.pmd.PMD" ;;
            cpd) main_class="net.sourceforge.pmd.cpd.CPD" ;;
            *)   echo "ERROR: Unknown PMD tool: $tool" >&2; rm -f "$stderr_file"; return 1 ;;
        esac

        exit_code=0
        java -cp "$PMD_DIR/lib/*" "$main_class" "${tool_args[@]}" 2>"$stderr_file" || exit_code=$?

        # fallback 也失敗時才顯示 stderr
        if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
            cat "$stderr_file" >&2
        fi
    fi

    rm -f "$stderr_file"
    return $exit_code
}

# run_pmd <module> [project_root] [filelist]
# filelist 提供時 = 增量模式（只掃清單內檔案）
# filelist 不提供時 = 全量模式（掃整個 src/main/java）
run_pmd() {
    local module="$1"
    local project_root="${2:-.}"
    local filelist="${3:-}"
    _load_versions

    local src_dir="$project_root/$module/src/main/java"
    local ruleset="$project_root/$RULESET_PATH"
    local cache_file="$TOOLS_DIR/pmd-cache-${module}.bin"

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        return 1
    fi
    if [[ ! -f "$ruleset" ]]; then
        echo "ERROR: Ruleset not found: $ruleset" >&2
        return 1
    fi

    # 增量模式：檔案清單為空 → 無需檢查
    if [[ -n "$filelist" ]]; then
        if [[ ! -s "$filelist" ]]; then
            echo "PMD: No changed files to check (incremental mode)."
            return 0
        fi
        local file_count
        file_count=$(wc -l < "$filelist")
        echo "Running PMD on $module — $file_count changed file(s) (engine=$PMD_ENGINE_VERSION, ruleset=$RULESET_PATH)..."
    else
        echo "Running PMD on $module — full scan (engine=$PMD_ENGINE_VERSION, ruleset=$RULESET_PATH)..."
    fi

    local report_file
    report_file=$(mktemp /tmp/pmd-report-XXXXXX.txt)

    # PMD 6.x exit codes: 0=no violations, 4=violations found, other=error
    local exit_code=0
    if [[ -n "$filelist" ]]; then
        # 增量模式：-filelist
        _exec_pmd pmd \
            -filelist "$filelist" \
            -R "$ruleset" \
            -f text \
            -r "$report_file" \
            --cache "$cache_file" || exit_code=$?
    else
        # 全量模式：-d
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

# run_cpd <module> [project_root] [filelist]
# CPD 必須掃全模組才能偵測跨檔案重複。
# filelist 提供時 = 增量模式：仍掃全模組，但輸出只保留涉及變更檔案的 duplication。
# filelist 不提供時 = 全量模式：報告所有 duplication。
run_cpd() {
    local module="$1"
    local project_root="${2:-.}"
    local filelist="${3:-}"
    _load_versions

    local src_dir="$project_root/$module/src/main/java"

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        return 1
    fi

    if [[ -n "$filelist" && ! -s "$filelist" ]]; then
        echo "CPD: No changed files to check (incremental mode)."
        return 0
    fi

    local mode_label="full scan"
    [[ -n "$filelist" ]] && mode_label="full scan, filtered to changed files"
    echo "Running CPD on $module — $mode_label (minimumTokens=$MINIMUM_TOKENS)..."

    local report_file
    report_file=$(mktemp /tmp/cpd-report-XXXXXX.txt)

    # Note: CPD 不支援 -r flag（run_pmd 用的方式），只能用 stdout 重導向
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
            # 增量模式：過濾輸出，只保留涉及變更檔案的 duplication block
            local filtered_file
            filtered_file=$(mktemp /tmp/cpd-filtered-XXXXXX.txt)
            local in_block=0
            local block=""
            local block_relevant=0

            while IFS= read -r line; do
                if [[ "$line" == "Found a"* ]]; then
                    # 輸出前一個 block（如果 relevant）
                    if [[ $in_block -eq 1 && $block_relevant -eq 1 ]]; then
                        echo "$block" >> "$filtered_file"
                    fi
                    block="$line"
                    block_relevant=0
                    in_block=1
                elif [[ $in_block -eq 1 ]]; then
                    block="$block"$'\n'"$line"
                    # 檢查這行是否包含變更檔案的路徑
                    while IFS= read -r changed_file; do
                        if [[ "$line" == *"$changed_file"* ]]; then
                            block_relevant=1
                            break
                        fi
                    done < "$filelist"
                fi
            done < "$report_file"
            # 輸出最後一個 block
            if [[ $in_block -eq 1 && $block_relevant -eq 1 ]]; then
                echo "$block" >> "$filtered_file"
            fi

            if [[ -s "$filtered_file" ]]; then
                local count
                count=$(grep -c '^Found a' "$filtered_file" 2>/dev/null || echo "0")
                echo "CPD: $count duplication(s) involving changed files (filtered from full scan)."
                cat "$filtered_file"
            else
                echo "CPD: Duplications exist in module but none involve changed files."
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
