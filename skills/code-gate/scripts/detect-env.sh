#!/usr/bin/env bash
# detect-env.sh — 偵測環境並安裝 code-gate 工具
# 用法: bash detect-env.sh [project_root]
# 結束碼: 0=ready, 1=missing components
# 依賴: bash, curl, unzip, java 17+
#
# 輸出協定:
#   stderr → debug / progress 訊息（不進 Claude context）
#   stdout → 結尾一行 ---CODE_GATE_RESULT--- + JSON summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${CODE_GATE_TOOLS_DIR:-$HOME/.claude/tools}"
PROJECT_ROOT="${1:-$(pwd)}"

# All informational output → stderr (keeps Claude context clean)
log()  { echo "$1" >&2; }
ok()   { echo "[OK] $1" >&2; }
warn() { echo "[WARN] $1" >&2; }
fail() { echo "[FAIL] $1" >&2; }

errors=0
JAVA_VERSION=""
HAS_MAVEN=false
FIRST_RUN_PMD=false
FIRST_RUN_GJF=false

# ==================================================================
# 1. Java 17+ (required — runs PMD CLI + google-java-format)
# ==================================================================
JAVA_BIN=$(command -v java 2>/dev/null || true)
if [[ -n "$JAVA_BIN" ]]; then
    java_ver=$("$JAVA_BIN" -version 2>&1 | head -1)
    major=$(echo "$java_ver" | sed -E 's/.*"([0-9]+)[."$].*/\1/')
    if [[ "$major" -ge 17 ]]; then
        ok "Java 17+: $java_ver"
        JAVA_VERSION="$major"
    else
        fail "System Java is $java_ver — needs 17+"
        errors=$((errors + 1))
    fi
else
    fail "No java found in PATH"
    errors=$((errors + 1))
fi

# ==================================================================
# 2. Maven (optional — Phase 2 only)
# ==================================================================
if command -v mvn &>/dev/null; then
    ok "Maven: $(mvn --version 2>&1 | head -1)"
    HAS_MAVEN=true
else
    warn "Maven not found — Phase 2 will be unavailable"
fi

# ==================================================================
# 3. PMD version (from pom.xml or default)
# ==================================================================
source "$SCRIPT_DIR/resolve-pmd-version.sh"
resolve_versions "$PROJECT_ROOT" >&2
ok "PMD: engine=$PMD_ENGINE_VERSION tokens=$MINIMUM_TOKENS ruleset=${RULESET_PATH:-(built-in)}"

# ==================================================================
# 4. PMD CLI download
# ==================================================================
PMD_MAJOR="${PMD_ENGINE_VERSION%%.*}"

# PMD 7.x uses different directory layout and CLI syntax
if [[ "$PMD_MAJOR" -ge 7 ]]; then
    PMD_DIR="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}"
    PMD_RUN="$PMD_DIR/bin/pmd"
    PMD_ZIP_NAME="pmd-dist-${PMD_ENGINE_VERSION}-bin.zip"
    PMD_ZIP_URL="https://github.com/pmd/pmd/releases/download/pmd_releases%2F${PMD_ENGINE_VERSION}/${PMD_ZIP_NAME}"
else
    PMD_DIR="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}"
    PMD_RUN="$PMD_DIR/bin/run.sh"
    PMD_ZIP_NAME="pmd-bin-${PMD_ENGINE_VERSION}.zip"
    PMD_ZIP_URL="https://github.com/pmd/pmd/releases/download/pmd_releases%2F${PMD_ENGINE_VERSION}/${PMD_ZIP_NAME}"
fi

if [[ -f "$PMD_RUN" ]]; then
    ok "PMD CLI: $PMD_DIR"
else
    FIRST_RUN_PMD=true
    log "Downloading PMD CLI $PMD_ENGINE_VERSION (~35MB, usually 10-30s)..."
    mkdir -p "$TOOLS_DIR"

    # Clean old versions (safety: verify TOOLS_DIR is sane)
    if [[ -n "$TOOLS_DIR" && "$TOOLS_DIR" != "/" ]]; then
        for old_dir in "$TOOLS_DIR"/pmd-bin-*/; do
            [[ "$old_dir" == "$PMD_DIR/" ]] && continue
            [[ -d "$old_dir" ]] && rm -rf "$old_dir" && log "  Removed old: $old_dir"
        done
    fi

    local_zip="$TOOLS_DIR/${PMD_ZIP_NAME}"
    curl -fSL --connect-timeout 15 --retry 2 -o "${local_zip}.tmp" "$PMD_ZIP_URL" \
        && mv "${local_zip}.tmp" "$local_zip" || {
        fail "Failed to download PMD CLI from: $PMD_ZIP_URL"
        fail "Possible causes: network issue, corporate proxy, or GitHub rate limit."
        fail "Manual fix: download the ZIP and extract to $PMD_DIR"
        rm -f "${local_zip}.tmp" "$local_zip"
        errors=$((errors + 1))
    }

    if [[ -f "$local_zip" ]]; then
        if command -v unzip &>/dev/null; then
            unzip -q -o "$local_zip" -d "$TOOLS_DIR"
        else
            (cd "$TOOLS_DIR" && jar xf "$local_zip")
        fi
        rm -f "$local_zip"

        if [[ -f "$PMD_RUN" ]]; then
            chmod +x "$PMD_RUN" 2>/dev/null || true
            ok "PMD CLI installed: $PMD_DIR (major=$PMD_MAJOR)"
        else
            fail "PMD CLI extraction failed — expected $PMD_RUN"
            errors=$((errors + 1))
        fi
    fi
fi

# ==================================================================
# 5. google-java-format download
# ==================================================================
# google-java-format version: 1.24.0 is the last version supporting Java 17+
# (2.x requires Java 21+ to run — future enhancement when Java 21 is widespread)
GJF_VERSION="${CODE_GATE_GJF_VERSION:-1.24.0}"
GJF_JAR="$TOOLS_DIR/google-java-format-${GJF_VERSION}.jar"

if [[ -f "$GJF_JAR" ]]; then
    ok "google-java-format: $GJF_JAR"
else
    FIRST_RUN_GJF=true
    log "Downloading google-java-format $GJF_VERSION (~5MB)..."
    mkdir -p "$TOOLS_DIR"

    for old_jar in "$TOOLS_DIR"/google-java-format-*.jar; do
        [[ "$old_jar" == "$GJF_JAR" ]] && continue
        [[ -f "$old_jar" ]] && rm -f "$old_jar" && log "  Removed old: $old_jar"
    done

    GJF_URL="https://github.com/google/google-java-format/releases/download/v${GJF_VERSION}/google-java-format-${GJF_VERSION}-all-deps.jar"
    curl -fSL --connect-timeout 15 --retry 2 -o "${GJF_JAR}.tmp" "$GJF_URL" \
        && mv "${GJF_JAR}.tmp" "$GJF_JAR" || {
        fail "Failed to download google-java-format from: $GJF_URL"
        fail "Possible causes: network issue, corporate proxy, or GitHub rate limit."
        fail "Manual fix: download the JAR and place at $GJF_JAR"
        rm -f "${GJF_JAR}.tmp" "$GJF_JAR"
        errors=$((errors + 1))
    }

    [[ -f "$GJF_JAR" ]] && ok "google-java-format installed: $GJF_JAR"
fi

# ==================================================================
# 6. Persist environment + JSON summary
# ==================================================================
if [[ $errors -eq 0 ]]; then
    ENV_FILE="$TOOLS_DIR/code-gate-env.sh"
    cat > "$ENV_FILE" <<ENVEOF
# Auto-generated by detect-env.sh — do not edit
export JAVA_GJF="$JAVA_BIN"
export GJF_JAR="$GJF_JAR"
export PMD_RUN="$PMD_RUN"
export PMD_DIR="$PMD_DIR"
export PMD_MAJOR="$PMD_MAJOR"
ENVEOF
    ok "Environment ready."

    # Structured output for Claude
    echo "---CODE_GATE_RESULT---"
    first_run=false
    [[ "$FIRST_RUN_PMD" == true || "$FIRST_RUN_GJF" == true ]] && first_run=true
    echo "{\"tool\":\"detect-env\",\"status\":\"ready\",\"java\":\"$JAVA_VERSION\",\"maven\":$HAS_MAVEN,\"pmd_engine\":\"$PMD_ENGINE_VERSION\",\"pmd_major\":$PMD_MAJOR,\"first_run\":$first_run}"
    exit 0
else
    fail "$errors error(s) — fix above issues before running code-gate."

    echo "---CODE_GATE_RESULT---"
    echo "{\"tool\":\"detect-env\",\"status\":\"failed\",\"errors\":$errors,\"java\":\"$JAVA_VERSION\",\"maven\":$HAS_MAVEN}"
    exit 1
fi
