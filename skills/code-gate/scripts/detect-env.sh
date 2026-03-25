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

# Trap-based cleanup for interrupted downloads
_detect_env_tmpfiles=()
_detect_env_cleanup() { rm -f "${_detect_env_tmpfiles[@]}" 2>/dev/null; }
trap _detect_env_cleanup EXIT INT TERM

# SHA-256 checksum verification for supply chain security
declare -A KNOWN_CHECKSUMS=(
    # PMD 6.x
    ["pmd-bin-6.55.0.zip"]="21acf96d43cb40d591cacccc1c20a66fc796eaddf69ea61812594447bac7a11d"
    # PMD 7.x
    ["pmd-dist-7.0.0-bin.zip"]="24be4bde2846cabea84e75e790ede1b86183f85f386cb120a41372f2b4844a54"
    ["pmd-dist-7.8.0-bin.zip"]="d16077bb9aa471f78cda7a4f7ad84f163514b561316538e04d85157fee1fba10"
    ["pmd-dist-7.9.0-bin.zip"]="dcb363fe20c2cc6faa700f3bf49034ef29b9a18f8892530d425a3f3b15eeea0d"
    # google-java-format
    ["google-java-format-1.24.0-all-deps.jar"]="812f805f58112460edf01bf202a8e61d0fd1f35c0d4fabd54220640776ec57a1"
)

_verify_checksum() {
    local file="$1" filename="$2"
    local expected="${KNOWN_CHECKSUMS[$filename]:-}"

    if [[ "${CODE_GATE_SKIP_CHECKSUM:-false}" == "true" ]]; then
        return 0
    fi
    if [[ -z "$expected" ]]; then
        warn "No known checksum for $filename — skipping verification"
        return 0
    fi

    local actual=""
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        warn "No sha256sum/shasum found — skipping checksum verification"
        return 0
    fi

    if [[ "$actual" != "$expected" ]]; then
        fail "Checksum mismatch for $filename"
        fail "  Expected: $expected"
        fail "  Got:      $actual"
        fail "  The file may be corrupted or tampered with."
        fail "  Set CODE_GATE_SKIP_CHECKSUM=true to bypass (not recommended)."
        rm -f "$file"
        return 1
    fi
    log "  Checksum verified: $filename"
    return 0
}

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
    _detect_env_tmpfiles+=("${local_zip}.tmp" "$local_zip")
    curl -fSL --connect-timeout 15 --retry 2 -o "${local_zip}.tmp" "$PMD_ZIP_URL" \
        && mv "${local_zip}.tmp" "$local_zip" || {
        fail "Failed to download PMD CLI from: $PMD_ZIP_URL"
        fail "Possible causes: network issue, corporate proxy, or GitHub rate limit."
        fail "Manual fix: download the ZIP and extract to $PMD_DIR"
        rm -f "${local_zip}.tmp" "$local_zip"
        errors=$((errors + 1))
    }

    if [[ -f "$local_zip" ]]; then
        _verify_checksum "$local_zip" "$PMD_ZIP_NAME" || {
            errors=$((errors + 1))
        }
    fi

    if [[ -f "$local_zip" ]]; then
        if command -v unzip &>/dev/null; then
            unzip -q -o "$local_zip" -d "$TOOLS_DIR" || {
                fail "Failed to extract PMD ZIP (unzip exit code: $?)"
                fail "The downloaded file may be corrupted. Try: rm -rf $TOOLS_DIR/pmd-bin-*"
                errors=$((errors + 1))
            }
        else
            (cd "$TOOLS_DIR" && jar xf "$local_zip") || {
                fail "Failed to extract PMD ZIP via jar (exit code: $?)"
                fail "Try: rm -rf $TOOLS_DIR/pmd-bin-*"
                errors=$((errors + 1))
            }
        fi
        rm -f "$local_zip"

        if [[ $errors -eq 0 && -f "$PMD_RUN" ]]; then
            chmod +x "$PMD_RUN" 2>/dev/null || true
            ok "PMD CLI installed: $PMD_DIR (major=$PMD_MAJOR)"
        elif [[ $errors -eq 0 ]]; then
            fail "PMD CLI extraction incomplete — expected $PMD_RUN"
            fail "Try: rm -rf $PMD_DIR && re-run"
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
    _detect_env_tmpfiles+=("${GJF_JAR}.tmp")
    curl -fSL --connect-timeout 15 --retry 2 -o "${GJF_JAR}.tmp" "$GJF_URL" \
        && mv "${GJF_JAR}.tmp" "$GJF_JAR" || {
        fail "Failed to download google-java-format from: $GJF_URL"
        fail "Possible causes: network issue, corporate proxy, or GitHub rate limit."
        fail "Manual fix: download the JAR and place at $GJF_JAR"
        rm -f "${GJF_JAR}.tmp" "$GJF_JAR"
        errors=$((errors + 1))
    }

    if [[ -f "$GJF_JAR" ]]; then
        _verify_checksum "$GJF_JAR" "google-java-format-${GJF_VERSION}-all-deps.jar" || {
            errors=$((errors + 1))
        }
    fi
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
    chmod 600 "$ENV_FILE" 2>/dev/null || true
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
