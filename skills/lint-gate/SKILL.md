---
name: lint-gate
description: >
  Use when checking code quality before committing, when CI lint fails,
  or when reviewing PMD/CPD/suppression violations on Java modules.
  Works on any Java project — with or without Maven/pom.xml.
disable-model-invocation: true
---

# Lint Gate Skill

Run project lint checks with auto-fix capability. Two-phase progressive approach:
fast standalone checks first, optional Maven-based ArchUnit second.

Works on any Java project. If `pom.xml` exists, automatically aligns PMD version with CI.
If not, uses PMD built-in rulesets for quick vulnerability scanning.

## Arguments

`$ARGUMENTS` = `[module] [--full] [--report-only]`

- **module** (optional): Module directory name, or `.` for single-module projects. Default: auto-detect.
- **--full** (optional): Scan entire module instead of only branch-changed files.
- **--report-only** (optional): Only report violations, do NOT auto-fix anything.

### Mode Matrix

| Mode | Scope | Auto-fix | Use Case |
|------|-------|----------|----------|
| **Incremental** (default) | Branch-changed files | Import + PMD safe fixes | Commit 前自檢 |
| **Full** (`--full`) | Entire `src/main/java` | Import + PMD safe fixes | 全模組健檢 |
| **Report-only** (`--report-only`) | Branch-changed files | None | 只想看問題 |
| **Full + Report-only** | Entire `src/main/java` | None | CI gate / audit |

## Phase 0 — Environment Setup + Module Detection

### Step 1: Environment check

Run `${CLAUDE_SKILL_DIR}/scripts/detect-env.sh` to verify environment.

The script will:
1. Verify Java 17+ exists (required for PMD CLI + google-java-format)
2. Resolve PMD version from `pom.xml` if available, otherwise use defaults
3. Download PMD CLI and google-java-format to `~/.claude/tools/` if missing

If any required step fails, report what's missing and stop.

### Step 2: Detect module

If no module argument provided, auto-detect:

```bash
# Multi-module: find subdirectories with src/main/java
VALID_MODULES=$(find . -maxdepth 2 -path '*/src/main/java' -not -path './src/main/java' \
  | sed 's|/src/main/java||; s|^\./||' | sort)

# Single-module: src/main/java at project root
if [[ -z "$VALID_MODULES" && -d "src/main/java" ]]; then
    MODULE="."
fi
```

If git changes are available, narrow to changed modules:
```bash
CHANGED_MODULES=$(git diff --name-only "$(git merge-base master HEAD)" -- '*/src/main/java/**/*.java' \
  | cut -d/ -f1 | sort -u)
```

If multiple modules detected, list them and ask the user which one to check.
If a single module is found, use it automatically.

### Step 3: Generate changed file list (incremental mode)

Unless `--full` is specified:

```bash
MODULE=$1  # e.g. MyModule or "."
if [[ "$MODULE" == "." ]]; then
    SRC_PREFIX="src/main/java/"
else
    SRC_PREFIX="$MODULE/src/main/java/"
fi

FILELIST=$(mktemp /tmp/lint-gate-filelist-XXXXXX.txt)
{
  git diff --name-only --diff-filter=ACMR "$(git merge-base master HEAD)" -- "$SRC_PREFIX"
  git ls-files --others --exclude-standard -- "$SRC_PREFIX"
} | grep '\.java$' | sort -u > "$FILELIST"

FILE_COUNT=$(wc -l < "$FILELIST")
echo "Incremental mode: $FILE_COUNT changed file(s) to check."
```

If `$FILE_COUNT` is 0, report "No changed Java files — nothing to lint." and stop.
If `--full`, set `FILELIST=""` (empty string) for full-scan mode.

## Phase 1 — Standalone Checks (no compilation needed)

### Step 1: Auto-fix imports

**If `--report-only`: SKIP this step entirely.**

```bash
source "$HOME/.claude/tools/lint-gate-env.sh"

if [[ -n "$FILELIST" && -s "$FILELIST" ]]; then
    xargs -r "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace < "$FILELIST"
else
    if [[ "$MODULE" == "." ]]; then
        find "src/main/java" -name '*.java' | \
            xargs -r "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace
    else
        find "$MODULE/src/main/java" -name '*.java' | \
            xargs -r "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace
    fi
fi
```

Report how many files were modified.

### Step 2: Run PMD + Claude auto-fix

```bash
source "${CLAUDE_SKILL_DIR}/scripts/run-pmd.sh"
run_pmd "$MODULE" "." "$FILELIST"
```

PMD uses the project's ruleset if found (`pmd-rules.xml`, `pmd-ruleset.xml`, or as specified in `pom.xml`).
If no project ruleset exists, uses PMD built-in categories: `bestpractices`, `errorprone`, `codestyle`.

If violations found:

**Normal mode:** Claude reads `${CLAUDE_SKILL_DIR}/reference/violation-fixes.md` and:
- **Auto-fix:** logger concatenation, fully qualified names, System.out
- **Report only:** empty catch, unused local vars, CPD duplications
- Re-run PMD to confirm fixes

**`--report-only` mode:** List all violations. Do NOT fix. Do NOT read violation-fixes.md.

### Step 3: Run CPD

```bash
source "${CLAUDE_SKILL_DIR}/scripts/run-pmd.sh"
run_cpd "$MODULE" "." "$FILELIST"
```

Report duplications. Do NOT auto-fix.

### Step 4: Suppression Guard (grep-based)

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-suppressions.sh" "$MODULE" "." "$FILELIST"
```

Checks what PMD XPath cannot:
1. `CPD-OFF` / `NOPMD` comments
2. `@SuppressWarnings("all")`
3. `@SuppressWarnings("PMD")`

Do NOT auto-fix suppressions.

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

Requires: Maven + project compilable

```bash
# Auto-discover ArchUnit test classes
ARCH_TESTS=$(find "$MODULE/src/test/java" -name '*ArchRule*Test*.java' -o -name '*LintSuppression*Test*.java' 2>/dev/null \
  | sed 's|.*/src/test/java/||; s|\.java$||; s|/|.|g' \
  | paste -sd,)

if [[ -n "$ARCH_TESTS" ]]; then
    mvn test -pl "$MODULE" -Dtest="$ARCH_TESTS"
else
    echo "No ArchUnit test classes found — skipping Phase 2."
fi
```

Report ArchUnit results if test classes found.
