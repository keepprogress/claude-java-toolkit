---
name: code-gate
description: >
  Use when checking code quality before committing, when CI lint fails,
  when reviewing PMD/CPD/suppression violations, or when detecting AI-generated
  code quality issues (slop) on Java modules.
  Works on any Java project — with or without Maven/pom.xml.
disable-model-invocation: true
---

# Code Gate Skill

Pre-commit code quality gate with auto-fix capability. Two-phase progressive approach:
fast standalone checks first, optional Maven-based ArchUnit second.

Works on any Java project. If `pom.xml` exists, automatically aligns PMD version with CI.
If not, uses PMD built-in rulesets for quick vulnerability scanning.

## Output Protocol

All scripts follow a unified output convention:
- **stderr**: Debug and progress messages (informational only, not for parsing)
- **stdout**: Violation details (if any) followed by a `---CODE_GATE_RESULT---` marker and a single-line JSON summary

When running scripts, parse the JSON after `---CODE_GATE_RESULT---` to get structured results.
Violation details above the marker are for auto-fix analysis.

> **Note**: `--fix-imports-only` also reorders imports to Google style. This may differ from the team's IntelliJ/IDE import order settings.

### Status values per tool

| Tool | `status` values | Key fields |
|------|----------------|------------|
| `detect-env` | `ready`, `failed` | `java`, `maven`, `pmd_engine`, `first_run` |
| `pmd` | `skip`, `pass`, `fail`, `error` | `violations`, `files_checked`, `engine` |
| `cpd` | `skip`, `pass`, `fail`, `error` | `duplications`, `mode` |
| `suppressions` | `skip`, `pass`, `fail`, `error` | `violations` |

## Arguments

`$ARGUMENTS` = `[module] [--full] [--report-only] [--include-tests] [--all]`

- **module** (optional): Module directory name, or `.` for single-module projects. Default: auto-detect.
- **--full** (optional): Scan entire module instead of only branch-changed files.
- **--report-only** (optional): Only report violations, do NOT auto-fix anything.
- **--include-tests** (optional): Also scan `src/test/java` in addition to `src/main/java`.
- **--all** (optional): Run on all modules with changed files (multi-module projects).

When `--include-tests` is specified, set env var before calling scripts:
```bash
export CODE_GATE_INCLUDE_TESTS=true
```

### Mode Matrix

| Mode | Scope | Auto-fix | Use Case |
|------|-------|----------|----------|
| **Incremental** (default) | Branch-changed files | Import + PMD safe fixes | Commit 前自檢 |
| **Full** (`--full`) | Entire `src/main/java` | Import + PMD safe fixes | 全模組健檢 |
| **Report-only** (`--report-only`) | Branch-changed files | None | 只想看問題 |
| **Full + Report-only** | Entire `src/main/java` | None | CI gate / audit |
| **Include tests** (`--include-tests`) | + `src/test/java` | Same as mode | 測試程式碼也要掃 |

## Phase 0 — Environment Setup + Module Detection

### Step 1: Environment check

If this is the first run (no `~/.claude/tools/code-gate-env.sh` exists), tell the user before running:
> "首次執行需要下載 PMD CLI (~35MB) 和 google-java-format (~5MB)，大約需要 30 秒。"

Run `${CLAUDE_SKILL_DIR}/scripts/detect-env.sh` to verify environment.

Parse the JSON result. If `status` is `"failed"`, report what's missing and stop.
If `first_run` is `true`, briefly note that tools were downloaded successfully.

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
# Auto-detect default branch (supports main, master, develop, etc.)
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || BASE_BRANCH="master"

CHANGED_MODULES=$(git diff --name-only "$(git merge-base "$BASE_BRANCH" HEAD)" -- '*/src/main/java/**/*.java' \
  | cut -d/ -f1 | sort -u)
```

If `--all` is specified, run Phase 1 on **each module** in `CHANGED_MODULES` sequentially,
collecting results into a combined summary table.

If multiple modules detected (without `--all`), list them and ask the user which one to check.
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

FILELIST=$(mktemp /tmp/code-gate-filelist-XXXXXX.txt)
# Reuse BASE_BRANCH from Step 2 (auto-detected)
{
  git diff --name-only --diff-filter=ACMR "$(git merge-base "$BASE_BRANCH" HEAD)" -- "$SRC_PREFIX"
  git ls-files --others --exclude-standard -- "$SRC_PREFIX"
} | grep '\.java$' | sort -u > "$FILELIST"

FILE_COUNT=$(wc -l < "$FILELIST")
```

If `$FILE_COUNT` is 0, report "No changed Java files — nothing to lint." and stop.
If `--full`, set `FILELIST=""` (empty string) for full-scan mode.

## Phase 1 — Standalone Checks (no compilation needed)

### Step 1: Auto-fix imports

**If `--report-only`: SKIP this step entirely.**

```bash
source "$HOME/.claude/tools/code-gate-env.sh"

# Note: xargs without -r for macOS BSD compatibility; input is pre-validated non-empty
if [[ -n "$FILELIST" && -s "$FILELIST" ]]; then
    xargs "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace < "$FILELIST"
else
    if [[ "$MODULE" == "." ]]; then
        find "src/main/java" -name '*.java' | \
            xargs "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace
    else
        find "$MODULE/src/main/java" -name '*.java' | \
            xargs "$JAVA_GJF" -jar "$GJF_JAR" --fix-imports-only --replace
    fi
fi
```

Report how many files were modified.

### Step 2: Run PMD + Claude auto-fix

```bash
source "${CLAUDE_SKILL_DIR}/scripts/run-pmd.sh"
run_pmd "$MODULE" "." "$FILELIST"
```

Parse the JSON result after `---CODE_GATE_RESULT---`.
Violation details (lines above the marker) are for auto-fix analysis.

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

Parse the JSON result. Report duplications. Do NOT auto-fix.

### Step 4: Suppression Guard (grep-based)

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-suppressions.sh" "$MODULE" "." "$FILELIST"
```

Parse the JSON result. Checks what PMD XPath cannot:
1. `CPD-OFF` / `NOPMD` comments
2. `@SuppressWarnings("all")`
3. `@SuppressWarnings("PMD")`

Do NOT auto-fix suppressions.

### Phase 1 Summary — Presenting Results

Collect JSON results from PMD, CPD, and Suppressions steps.
For imports (no JSON), count modified files from the command output.
Present a single summary table:

| Check | Status | Detail |
|-------|--------|--------|
| Imports | done/skip | N files fixed (count from command output) |
| PMD | from JSON `status` | `violations` count (M auto-fixed if applicable) |
| CPD | from JSON `status` | `duplications` count |
| Suppressions | from JSON `status` | `violations` count |

**If all checks pass:** Keep response to 2-3 lines. Do not elaborate.
**If issues remain:** Show the table, then list only actionable items the user needs to address.

### Cleanup

```bash
[[ -n "$FILELIST" && -f "$FILELIST" ]] && rm -f "$FILELIST"
```

## Phase 2 — ArchUnit (optional, needs Maven)

Only offer Phase 2 if Phase 1 passes clean AND the detect-env JSON showed `maven: true`.
Ask user before proceeding.

```bash
# Auto-discover ArchUnit test classes (common naming conventions)
ARCH_TESTS=$(find "$MODULE/src/test/java" \( \
    -name '*ArchRule*Test*.java' \
    -o -name '*ArchitectureTest*.java' \
    -o -name '*ArchTest*.java' \
    -o -name '*LayerTest*.java' \
    -o -name '*LintSuppression*Test*.java' \
  \) 2>/dev/null \
  | sed 's|.*/src/test/java/||; s|\.java$||; s|/|.|g' \
  | paste -sd,)

# Fallback: search for @ArchTest annotation or ArchUnit imports
if [[ -z "$ARCH_TESTS" ]]; then
    ARCH_TESTS=$(grep -rl 'com.tngtech.archunit\|@ArchTest' \
        "$MODULE/src/test/java" 2>/dev/null \
      | sed 's|.*/src/test/java/||; s|\.java$||; s|/|.|g' \
      | paste -sd,)
fi

if [[ -n "$ARCH_TESTS" ]]; then
    mvn test -pl "$MODULE" -Dtest="$ARCH_TESTS"
else
    echo "No ArchUnit test classes found — skipping Phase 2."
fi
```

Report ArchUnit results if test classes found.
