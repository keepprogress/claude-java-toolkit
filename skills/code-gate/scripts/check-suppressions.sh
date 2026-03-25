#!/usr/bin/env bash
# check-suppressions.sh — grep 版 suppression guard
# 用法: bash check-suppressions.sh <module> [project_root] [filelist]
# 結束碼: 0=pass, 1=violations found
#
# module:  模組名或 "." (單模組)
# filelist: 增量模式檔案清單。不提供 = 全量掃描。
#
# 檢查 PMD XPath 無法覆蓋的 3 項：
#   1. CPD-OFF / NOPMD — comment-based suppressions
#   2. @SuppressWarnings("all") — PMD framework-level bypass
#   3. @SuppressWarnings("PMD") — suppresses all PMD rules
#
# 輸出協定:
#   stderr → debug / progress 訊息
#   stdout → violation 明細 + ---CODE_GATE_RESULT--- JSON summary

set -euo pipefail

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "ERROR: bash 4+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

log() { echo "$1" >&2; }

if [[ $# -lt 1 ]]; then
    echo "Usage: check-suppressions.sh <module> [project_root] [filelist]" >&2
    echo "  module:       module directory name, or '.' for single-module projects" >&2
    echo "  project_root: project root directory (default: '.')" >&2
    echo "  filelist:     file list for incremental mode (optional)" >&2
    exit 1
fi

MODULE="$1"
PROJECT_ROOT="${2:-.}"
FILELIST="${3:-}"

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# Resolve source directory
if [[ "$MODULE" == "." ]]; then
    SRC_DIR="$PROJECT_ROOT/src/main/java"
    MODULE_DIR="$PROJECT_ROOT"
else
    SRC_DIR="$PROJECT_ROOT/$MODULE/src/main/java"
    MODULE_DIR="$PROJECT_ROOT/$MODULE"
fi

ALLOWLIST="$MODULE_DIR/src/test/resources/lint-suppression-allowlist.txt"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found" >&2
    echo "---CODE_GATE_RESULT---"
    echo "{\"tool\":\"suppressions\",\"status\":\"error\",\"message\":\"source directory not found\"}"
    exit 1
fi

if [[ -n "$FILELIST" && ! -s "$FILELIST" ]]; then
    echo "---CODE_GATE_RESULT---"
    echo "{\"tool\":\"suppressions\",\"status\":\"skip\",\"violations\":0}"
    exit 0
fi

INCREMENTAL=0
if [[ -n "$FILELIST" ]]; then
    INCREMENTAL=1
    log "Suppression guard: incremental mode ($(wc -l < "$FILELIST") changed files)"
else
    log "Suppression guard: full scan"
fi

violations=()

# ------------------------------------------------------------------
# Check 1: CPD-OFF / NOPMD
# ------------------------------------------------------------------
log "  [1/3] CPD-OFF/NOPMD suppressions..."

if [[ $INCREMENTAL -eq 1 ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        count=$(grep -c 'CPD-OFF\|NOPMD' "$file" 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: new suppression(s) detected ($count)")
        fi
    done < "$FILELIST"
elif [[ -f "$ALLOWLIST" ]]; then
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
    log "    (no allowlist found — skipping count check)"
fi

# ------------------------------------------------------------------
# Check 2: @SuppressWarnings("all")
# ------------------------------------------------------------------
log "  [2/3] @SuppressWarnings(\"all\") bypasses..."

# Match: @SuppressWarnings("all"), @SuppressWarnings({"all"}), @SuppressWarnings(value="all")
SW_ALL_PATTERN='SuppressWarnings.*[("{\s]all["})]'

if [[ $INCREMENTAL -eq 1 ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        if grep -qE "$SW_ALL_PATTERN" "$file" 2>/dev/null; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: SuppressWarnings(\"all\") bypass")
        fi
    done < "$FILELIST"
else
    while IFS= read -r file; do
        rel="${file#$MODULE_DIR/}"
        violations+=("$rel: SuppressWarnings(\"all\") bypass")
    done < <(grep -rlE "$SW_ALL_PATTERN" "$SRC_DIR" 2>/dev/null || true)
fi

# ------------------------------------------------------------------
# Check 3: @SuppressWarnings("PMD")
# ------------------------------------------------------------------
# @SuppressWarnings("PMD") = blanket suppress (report as violation)
# @SuppressWarnings("PMD.SpecificRule") = targeted suppress (acceptable, not reported)
log "  [3/3] @SuppressWarnings(\"PMD\") blanket bypasses..."

if [[ $INCREMENTAL -eq 1 ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        # Match "PMD" but NOT "PMD.Something" (targeted suppress is acceptable)
        if grep -q 'SuppressWarnings("PMD")' "$file" 2>/dev/null; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: SuppressWarnings(\"PMD\") blanket bypass")
        fi
    done < "$FILELIST"
else
    while IFS= read -r file; do
        # Only flag files with blanket "PMD" suppress, not targeted "PMD.RuleName"
        if grep -q 'SuppressWarnings("PMD")' "$file" 2>/dev/null; then
            rel="${file#$MODULE_DIR/}"
            violations+=("$rel: SuppressWarnings(\"PMD\") blanket bypass")
        fi
    done < <(grep -rl 'SuppressWarnings("PMD"' "$SRC_DIR" 2>/dev/null || true)
fi

# ------------------------------------------------------------------
# Report — violation details on stdout, then JSON summary
# ------------------------------------------------------------------
if [[ ${#violations[@]} -eq 0 ]]; then
    log "Suppression guard: PASS"
    echo "---CODE_GATE_RESULT---"
    echo "{\"tool\":\"suppressions\",\"status\":\"pass\",\"violations\":0}"
    exit 0
else
    log "Suppression guard: FAIL (${#violations[@]} violations)"
    # Violation details on stdout for Claude to read
    for v in "${violations[@]}"; do
        echo "  - $v"
    done
    echo "---CODE_GATE_RESULT---"
    echo "{\"tool\":\"suppressions\",\"status\":\"fail\",\"violations\":${#violations[@]}}"
    exit 1
fi
