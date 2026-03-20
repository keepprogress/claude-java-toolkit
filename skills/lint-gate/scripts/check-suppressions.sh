#!/usr/bin/env bash
# check-suppressions.sh — grep 版 LintSuppressionGuardTest（PMD 自指悖論補完）
# 用法: bash check-suppressions.sh <module> [project_root]
# 結束碼: 0=pass, 1=violations found
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

# [R2#3] 路徑正規化：cd + pwd 確保 MINGW64 路徑無冒號
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
MODULE_DIR="$PROJECT_ROOT/$MODULE"
SRC_DIR="$MODULE_DIR/src/main/java"
ALLOWLIST="$MODULE_DIR/src/test/resources/lint-suppression-allowlist.txt"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found" >&2
    exit 1
fi

violations=()

# ------------------------------------------------------------------
# Check 1: CPD-OFF / NOPMD — count must match allowlist
# [R6#1] 不加 // 前綴，對齊 Java test 的 line.contains() 語意
#        （block comment /* CPD-OFF */ 也要算進去）
# [R6#4] 用 grep -rl + grep -c 分離，避免 IFS=: 在含冒號路徑上斷裂
# ------------------------------------------------------------------
echo "  [1/3] CPD-OFF/NOPMD suppressions..."

declare -A allowlist_map
if [[ -f "$ALLOWLIST" ]]; then
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" == \#* ]] && continue
        filepath="${line%:*}"
        count="${line##*:}"
        allowlist_map["$filepath"]="$count"
    done < "$ALLOWLIST"
fi

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

# ------------------------------------------------------------------
# Check 2 & 3: @SuppressWarnings("all") / @SuppressWarnings("PMD")
# [R6#2] "PMD"（無特定規則名）也有自指悖論，PMD 6.55 實測確認
# [R6#3] 無 @ 前綴，對齊 Java test 的 findFilesContaining() 語意
# [R6#5] 用 grep -rl（file-level），語意對齊 Java test
# ------------------------------------------------------------------
echo "  [2/3] @SuppressWarnings(\"all\") bypasses..."

while IFS= read -r file; do
    rel="${file#$MODULE_DIR/}"
    violations+=("$rel: SuppressWarnings(\"all\") bypass")
done < <(grep -rl 'SuppressWarnings("all"' "$SRC_DIR" 2>/dev/null || true)

echo "  [3/3] @SuppressWarnings(\"PMD\") bypasses..."

while IFS= read -r file; do
    rel="${file#$MODULE_DIR/}"
    # 排除 "PMD.XxxRule"（有點號 = 特定規則，PMD XPath 已覆蓋）
    # 只抓 "PMD" 精確匹配（壓全部 PMD 規則 = 自指悖論）
    if grep -q 'SuppressWarnings("PMD")' "$file" 2>/dev/null; then
        violations+=("$rel: SuppressWarnings(\"PMD\") bypass (suppresses all PMD rules)")
    fi
done < <(grep -rl 'SuppressWarnings("PMD"' "$SRC_DIR" 2>/dev/null || true)

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
