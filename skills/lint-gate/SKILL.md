---
name: lint-gate
description: >
  Use when checking code quality before committing, when CI lint fails,
  or when reviewing PMD/CPD/suppression violations on Java modules.
disable-model-invocation: true
---

# Lint Gate Skill

Run project lint checks with auto-fix capability. Two-phase progressive approach:
fast standalone checks first, optional Maven-based ArchUnit second.

## Arguments

`$ARGUMENTS` = `[module] [--full]`

- **module** (optional): Module name. Default: auto-detect from recent git changes.
- **--full** (optional): Scan entire module instead of only branch-changed files.

Valid modules: `TlwCrpFrontendApi`, `TlwCrpRestServer`

### Incremental vs Full Mode

| Mode | Scope | Use Case |
|------|-------|----------|
| **Incremental** (default) | Only files changed on branch vs master + untracked | Commit 前自檢，只看自己改的 |
| **Full** (`--full`) | Entire `src/main/java` | CI 驗證、首次導入、全模組健檢 |

## Phase 0 — Environment Setup + File List

Run `${CLAUDE_SKILL_DIR}/scripts/detect-env.sh` to check environment.

The script will:
1. Verify Java 8 exists at `/c/Developer/AmazonCorretto1.8.0_452`
2. Verify Java 17+ exists for google-java-format
3. Run `${CLAUDE_SKILL_DIR}/scripts/resolve-pmd-version.sh` to sync PMD CLI version with pom.xml
4. Download PMD CLI and google-java-format to `~/.claude/tools/` if missing or outdated

If any step fails, report what's missing and suggest installation commands.
Do NOT proceed to Phase 1 until environment is ready.

### Generate changed file list (incremental mode)

Unless `--full` is specified, generate a file list of branch changes:

```bash
MODULE=$1  # e.g. TlwCrpFrontendApi
FILELIST=$(mktemp /tmp/lint-gate-filelist-XXXXXX.txt)

# Branch diff (all commits since diverging from master) + untracked new files
{
  git diff --name-only --diff-filter=ACMR "$(git merge-base master HEAD)" -- "$MODULE/src/main/java/"
  git ls-files --others --exclude-standard -- "$MODULE/src/main/java/"
} | grep '\.java$' | sort -u > "$FILELIST"

FILE_COUNT=$(wc -l < "$FILELIST")
echo "Incremental mode: $FILE_COUNT changed file(s) to check."
```

If `$FILE_COUNT` is 0, report "No changed Java files — nothing to lint." and stop.

If `--full` is specified, set `FILELIST=""` (empty string, not a file) to signal full-scan mode to all scripts.

## Phase 1 — Standalone Checks (no compilation needed)

### Step 1: Auto-fix imports (tool-based, no Claude judgement needed)

`--fix-imports-only` removes unused imports, sorts, and groups — it does NOT reformat other code.
It does NOT add missing imports (that requires compilation).
It does NOT convert fully-qualified names to import + short name (that's Step 2, Claude does it).

```bash
# Read verified paths from detect-env.sh (Phase 0)
# [R7#1] 不用 command -v java — JAVA_HOME 可能指向 Java 8
source "$HOME/.claude/tools/lint-gate-env.sh"

if [[ -n "$FILELIST" && -s "$FILELIST" ]]; then
    # 增量模式：只處理變更檔案
    xargs -r "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace < "$FILELIST"
else
    # 全量模式：掃整個模組
    find "$MODULE/src/main/java" -name '*.java' | \
        xargs -r "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace
fi
```

Report how many files were modified. If any changed, show the diff summary.

### Step 2: Run PMD + Claude auto-fix (Claude reads code and applies fixes)

```bash
source "${CLAUDE_SKILL_DIR}/scripts/run-pmd.sh"
run_pmd "$MODULE" "." "$FILELIST"
# $FILELIST 為空字串時 = 全量模式，為檔案路徑時 = 增量模式
```

PMD uses the project's `pmd-rules.xml` (same file CI uses). This includes:
- Standard lint rules (imports, logger, System.out, etc.)
- Suppression guard rules: `NoSuppressWarningsPmd`, `NoGeneratedAnnotation`

If violations found, Claude reads `${CLAUDE_SKILL_DIR}/reference/violation-fixes.md` and:
- **Auto-fix (Claude applies via Edit tool):** logger concatenation → `{}` placeholders, fully qualified names → import + short name, System.out → logger
- **Report only (human decision):** empty catch, unused local vars, CPD duplications
- Re-run PMD to confirm fixes

Note: Step 1 (tool) handles unused/star imports. Step 2 (Claude) handles everything else PMD catches.

### Step 3: Run CPD

```bash
source "${CLAUDE_SKILL_DIR}/scripts/run-pmd.sh"
run_cpd "$MODULE" "." "$FILELIST"
# 增量模式：CPD 仍掃全模組（跨檔案偵測需要），但輸出只保留涉及變更檔案的 duplication
```

Report duplications found. Do NOT auto-fix — these need human judgement on extraction strategy.

### Step 4: Suppression Guard (grep-based)

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-suppressions.sh" "$MODULE" "." "$FILELIST"
# 增量模式：只掃變更檔案，不比對 allowlist（避免歷史誤報）
# 全量模式：掃全模組，比對 allowlist 計數
```

This checks the items PMD XPath cannot detect (self-referential suppression):
1. `CPD-OFF` / `NOPMD` anywhere in source — PMD 6.x 不暴露 comment 節點在 XPath AST，grep 對齊 Java test 的 `line.contains()` 語意
2. `@SuppressWarnings("all")` — PMD 自指悖論：框架層在 XPath 評估前就隱藏了 scope
3. `@SuppressWarnings("PMD")` — 同上悖論（壓全部 PMD 規則，XPath 也被壓）

Note: `@Generated` 由 Step 2 的 PMD `NoGeneratedAnnotation` 規則覆蓋。
`@SuppressWarnings("PMD.SpecificRule")` 由 Step 2 的 `NoSuppressWarningsPmd` 覆蓋（只壓特定規則，不影響 XPath）。

If violations found, report the mismatch. Do NOT auto-fix suppressions — this is a security guard.

### Phase 1 Summary

Report all results in a table:

| Check | Status | Auto-fixed | Remaining |
|-------|--------|------------|-----------|
| Imports | ... | N files | ... |
| PMD | ... | N fixes | ... |
| CPD | ... | — | N duplications |
| Suppressions | ... | — | N mismatches |

### Cleanup

```bash
[[ -n "$FILELIST" && -f "$FILELIST" ]] && rm -f "$FILELIST"
```

## Phase 2 — ArchUnit (optional, needs Maven)

Only offer Phase 2 if Phase 1 passes clean. Ask user before proceeding.

Requires: Maven + Java 8

```bash
export JAVA_HOME="/c/Developer/AmazonCorretto1.8.0_452"
export PATH="$JAVA_HOME/bin:$PATH"
mvn test -pl "$MODULE" -Dtest=com.acer.ArchRuleTest,com.acer.LintSuppressionGuardTest
```

If Maven is not installed, suggest:
1. Install Maven wrapper: `mvn wrapper:wrapper` (if another machine has mvn)
2. Download Maven manually from https://maven.apache.org/download.cgi
3. Skip Phase 2 (Phase 1 already covers most issues)

Report ArchUnit results:
- Unused private methods/fields
- Controller → Repository violations
- LintSuppressionGuard (JUnit version, cross-validates with Phase 1 Step 4)
