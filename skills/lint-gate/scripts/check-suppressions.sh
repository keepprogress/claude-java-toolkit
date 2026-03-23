#!/usr/bin/env bash
# check-suppressions.sh — grep 版 LintSuppressionGuardTest（PMD 自指悖論補完）
# 用法: bash check-suppressions.sh <module> [project_root] [filelist]
# 結束碼: 0=pass, 1=violations found
#
# filelist: 可選的檔案清單路徑。
#   - 提供時 = 增量模式：只掃清單內的檔案（不比對 allowlist）
#   - 不提供 + allowlist 存在 = 全量模式：掃全模組，比對 allowlist 計數
#   - 不提供 + allowlist 不存在 = 跳過 Check 1，只做 Check 2/3 全掃
#
# 本腳本檢查 PMD XPath 無法覆蓋的 3 項（自指悖論 + comment 限制）：
#   1. CPD-OFF / NOPMD → 比對 allowlist 計數（對齊 Java test 的 line.contains 語意）
#   2. @SuppressWarnings("all") → PMD 框架層 suppression，XPath 看不到
#   3. @SuppressWarnings("PMD") → 同上（壓全部 PMD 規則）
#
# @Generated 由 pmd-rules.xml NoGeneratedAnnotation XPath 覆蓋。
# @SuppressWarnings("PMD.SpecificRule") 由 NoSuppressWarningsPmd XPath 覆蓋
#   （只壓特定規則，自訂規則不受影響）。
#
# 依賴: bash, grep

set -euo pipefail

# [R7#5] bash 4+ 必須（declare -A associative array）
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "ERROR: bash 4+ required (current: $BASH_VERSION). Git Bash 5.2+ expected." >&2
    exit 1
fi

MODULE="$1"
PROJECT_ROOT="${2:-.}"
FILELIST="${3:-}"

# [R2#3] 路徑正規化：cd + pwd 確保 MINGW64 路徑無冒號
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
MODULE_DIR="$PROJECT_ROOT/$MODULE"
SRC_DIR="$MODULE_DIR/src/main/java"
ALLOWLIST="$MODULE_DIR/src/test/resources/lint-suppression-allowlist.txt"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found" >&2
    exit 1
fi

# 增量模式：檔案清單為空 → 無需檢查
if [[ -n "$FILELIST" && ! -s "$FILELIST" ]]; then
    echo "Suppression guard: SKIP (no changed files)"
    exit 0
fi

# 決定掃描範圍
INCREMENTAL=0
if [[ -n "$FILELIST" ]]; then
    INCREMENTAL=1
    echo "Suppression guard: incremental mode ($(wc -l < "$FILELIST") changed files)"
else
    echo "Suppression guard: full scan"
fi

violations=()

# ------------------------------------------------------------------
# Check 1: CPD-OFF / NOPMD
# 增量模式 → 只掃變更檔案，發現即報告（不比對 allowlist）
# 全量模式 + allowlist 存在 → 掃全模組，比對 allowlist 計數
# 全量模式 + allowlist 不存在 → 跳過（避免誤報一堆歷史 suppression）
# ------------------------------------------------------------------
echo "  [1/3] CPD-OFF/NOPMD suppressions..."

if [[ $INCREMENTAL -eq 1 ]]; then
    # 增量模式：只掃變更檔案
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        count=$(grep -c 'CPD-OFF\|NOPMD' "$file" 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: new suppression(s) detected ($count occurrence(s)) — check allowlist")
        fi
    done < "$FILELIST"
elif [[ -f "$ALLOWLIST" ]]; then
    # 全量模式 + allowlist 存在：比對計數
    declare -A allowlist_map
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" == \#* ]] && continue
        filepath="${line%:*}"
        count="${line##*:}"
        allowlist_map["$filepath"]="$count"
    done < "$ALLOWLIST"

    declare -A found_counts
    while IFS= read -r file; do
        count=$(grep -c 'CPD-OFF\|NOPMD' "$file" 2>/dev/null || echo "0")
        rel="${file#$MODULE_DIR/}"
        found_counts["$rel"]="$count"
    done < <(grep -rl 'CPD-OFF\|NOPMD' "$SRC_DIR" 2>/dev/null || true)

    declare -A all_files
    for key in "${!allowlist_map[@]}"; do all_files["$key"]=1; done
    for key in "${!found_counts[@]}"; do all_files["$key"]=1; done

    for rel in "${!all_files[@]}"; do
        found="${found_counts[$rel]:-0}"
        allowed="${allowlist_map[$rel]:-0}"
        if [[ "$found" -ne "$allowed" ]]; then
            violations+=("$rel: found $found suppression(s), allowed $allowed")
        fi
    done
else
    echo "    (no allowlist found — skipping CPD-OFF/NOPMD count check)"
    echo "    Tip: create $MODULE/src/test/resources/lint-suppression-allowlist.txt for full-module checks"
fi

# ------------------------------------------------------------------
# Check 2 & 3: @SuppressWarnings("all") / @SuppressWarnings("PMD")
# 增量模式 → 只掃變更檔案
# 全量模式 → 掃全模組
# ------------------------------------------------------------------
echo "  [2/3] @SuppressWarnings(\"all\") bypasses..."

if [[ $INCREMENTAL -eq 1 ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        if grep -q 'SuppressWarnings("all"' "$file" 2>/dev/null; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: SuppressWarnings(\"all\") bypass")
        fi
    done < "$FILELIST"
else
    while IFS= read -r file; do
        rel="${file#$MODULE_DIR/}"
        violations+=("$rel: SuppressWarnings(\"all\") bypass")
    done < <(grep -rl 'SuppressWarnings("all"' "$SRC_DIR" 2>/dev/null || true)
fi

echo "  [3/3] @SuppressWarnings(\"PMD\") bypasses..."

if [[ $INCREMENTAL -eq 1 ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        if grep -q 'SuppressWarnings("PMD")' "$file" 2>/dev/null; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: SuppressWarnings(\"PMD\") bypass (suppresses all PMD rules)")
        fi
    done < "$FILELIST"
else
    while IFS= read -r file; do
        rel="${file#$MODULE_DIR/}"
        if grep -q 'SuppressWarnings("PMD")' "$file" 2>/dev/null; then
            violations+=("$rel: SuppressWarnings(\"PMD\") bypass (suppresses all PMD rules)")
        fi
    done < <(grep -rl 'SuppressWarnings("PMD"' "$SRC_DIR" 2>/dev/null || true)
fi

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
echo ""
if [[ ${#violations[@]} -eq 0 ]]; then
    echo "Suppression guard: PASS"
    exit 0
else
    echo "Suppression guard: FAIL (${#violations[@]} violations)"
    for v in "${violations[@]}"; do
        echo "  - $v"
    done
    exit 1
fi
