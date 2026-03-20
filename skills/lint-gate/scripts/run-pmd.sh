#!/usr/bin/env bash
# run-pmd.sh — 用獨立 PMD CLI 執行 PMD + CPD 檢查
# 用法: source run-pmd.sh && run_pmd <module> [project_root]
#        source run-pmd.sh && run_cpd <module> [project_root]
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

run_pmd() {
    local module="$1"
    local project_root="${2:-.}"
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

    echo "Running PMD on $module (engine=$PMD_ENGINE_VERSION, ruleset=$RULESET_PATH)..."

    local report_file
    report_file=$(mktemp /tmp/pmd-report-XXXXXX.txt)

    # PMD 6.x exit codes: 0=no violations, 4=violations found, other=error
    local exit_code=0
    _exec_pmd pmd \
        -d "$src_dir" \
        -R "$ruleset" \
        -f text \
        -r "$report_file" \
        --cache "$cache_file" || exit_code=$?

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
    _load_versions

    local src_dir="$project_root/$module/src/main/java"

    if [[ ! -d "$src_dir" ]]; then
        echo "ERROR: Source directory not found: $src_dir" >&2
        return 1
    fi

    echo "Running CPD on $module (minimumTokens=$MINIMUM_TOKENS)..."

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
        local count
        count=$(grep -c '^Found a' "$report_file" 2>/dev/null || echo "0")
        echo "CPD: $count duplication(s) found."
        cat "$report_file"
        rm -f "$report_file"
        return 4
    else
        echo "ERROR: CPD exited with code $exit_code" >&2
        cat "$report_file" 2>/dev/null
        rm -f "$report_file"
        return "$exit_code"
    fi
}
