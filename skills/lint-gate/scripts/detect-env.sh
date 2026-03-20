#!/usr/bin/env bash
# detect-env.sh — 偵測環境並自動安裝 lint-gate 工具
# 用法: bash detect-env.sh [project_root]
# 結束碼: 0=ready, 1=missing components (printed to stderr)
# 依賴: bash, curl, unzip, java

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$HOME/.claude/tools"
PROJECT_ROOT="${1:-$(pwd)}"

# Color output (safe for Git Bash)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; }

errors=0

# ------------------------------------------------------------------
# 1. Java 8 (for Maven / ArchUnit in Phase 2)
# [R5#7] -f not -x — NTFS has no Unix execute bits
# ------------------------------------------------------------------
JAVA8_HOME="/c/Developer/AmazonCorretto1.8.0_452"
if [[ -f "$JAVA8_HOME/bin/java" ]] || [[ -f "$JAVA8_HOME/bin/java.exe" ]]; then
    java8_ver=$("$JAVA8_HOME/bin/java" -version 2>&1 | head -1)
    ok "Java 8: $java8_ver"
else
    fail "Java 8 not found at $JAVA8_HOME"
    echo "  Install Amazon Corretto 8:"
    echo "  https://docs.aws.amazon.com/corretto/latest/corretto-8-ug/downloads-list.html"
    echo "  After install, set path in detect-env.sh JAVA8_HOME variable"
    errors=$((errors + 1))
fi

# ------------------------------------------------------------------
# 2. Java 17+ (for google-java-format)
# ------------------------------------------------------------------
JAVA_DEFAULT=$(command -v java 2>/dev/null || true)
if [[ -n "$JAVA_DEFAULT" ]]; then
    java_ver=$("$JAVA_DEFAULT" -version 2>&1 | head -1)
    # Extract major version number
    major=$(echo "$java_ver" | sed -E 's/.*"([0-9]+)[."$].*/\1/')
    if [[ "$major" -ge 17 ]]; then
        ok "Java 17+: $java_ver (for google-java-format)"
    else
        fail "System Java is $java_ver — google-java-format needs 17+"
        errors=$((errors + 1))
    fi
else
    fail "No system java found"
    errors=$((errors + 1))
fi

# ------------------------------------------------------------------
# 3. Maven (optional — Phase 2 only)
# ------------------------------------------------------------------
if command -v mvn &>/dev/null; then
    mvn_ver=$(mvn --version 2>&1 | head -1)
    ok "Maven: $mvn_ver (for Phase 2 ArchUnit)"
else
    warn "Maven not found — Phase 2 (ArchUnit) will be unavailable"
    echo "  Phase 1 (PMD/CPD standalone) works without Maven"
    echo "  To install Maven wrapper: ask a colleague with mvn to run 'mvn wrapper:wrapper' in project root"
fi

# ------------------------------------------------------------------
# 4. Resolve PMD version from pom.xml
# ------------------------------------------------------------------
source "$SCRIPT_DIR/resolve-pmd-version.sh"
if resolve_versions "$PROJECT_ROOT"; then
    ok "Version alignment: PMD plugin=$PMD_PLUGIN_VERSION engine=$PMD_ENGINE_VERSION tokens=$MINIMUM_TOKENS"
else
    fail "Could not resolve PMD versions from pom.xml"
    errors=$((errors + 1))
fi

# ------------------------------------------------------------------
# 5. PMD CLI
# [R7#3] 版本變更時清理舊版 PMD CLI（~35MB）
# ------------------------------------------------------------------
PMD_DIR="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION:-unknown}"
PMD_RUN="$PMD_DIR/bin/run.sh"

if [[ -f "$PMD_RUN" ]]; then
    ok "PMD CLI: $PMD_DIR"
else
    echo "Downloading PMD CLI $PMD_ENGINE_VERSION..."
    mkdir -p "$TOOLS_DIR"

    # 清理舊版 PMD CLI
    for old_dir in "$TOOLS_DIR"/pmd-bin-*/; do
        [[ "$old_dir" == "$PMD_DIR/" ]] && continue
        [[ -d "$old_dir" ]] && rm -rf "$old_dir" && echo "  Removed old: $old_dir"
    done

    local_zip="$TOOLS_DIR/pmd-bin-${PMD_ENGINE_VERSION}.zip"

    curl -fSL -o "$local_zip" \
        "https://github.com/pmd/pmd/releases/download/pmd_releases%2F${PMD_ENGINE_VERSION}/pmd-bin-${PMD_ENGINE_VERSION}.zip" || {
        fail "Failed to download PMD CLI"
        rm -f "$local_zip"
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
            ok "PMD CLI installed: $PMD_DIR"
        else
            fail "PMD CLI extraction failed"
            errors=$((errors + 1))
        fi
    fi
fi

# ------------------------------------------------------------------
# 6. google-java-format
# [R7#2] 安裝新版時刪除舊 jar，避免 glob 選到舊版
# ------------------------------------------------------------------
GJF_VERSION="1.24.0"
GJF_JAR="$TOOLS_DIR/google-java-format-${GJF_VERSION}.jar"

if [[ -f "$GJF_JAR" ]]; then
    ok "google-java-format: $GJF_JAR"
else
    echo "Downloading google-java-format $GJF_VERSION..."
    mkdir -p "$TOOLS_DIR"

    # 清理舊版 GJF jar
    for old_jar in "$TOOLS_DIR"/google-java-format-*.jar; do
        [[ "$old_jar" == "$GJF_JAR" ]] && continue
        [[ -f "$old_jar" ]] && rm -f "$old_jar" && echo "  Removed old: $old_jar"
    done

    curl -fSL -o "$GJF_JAR" \
        "https://github.com/google/google-java-format/releases/download/v${GJF_VERSION}/google-java-format-${GJF_VERSION}-all-deps.jar" || {
        fail "Failed to download google-java-format"
        rm -f "$GJF_JAR"
        errors=$((errors + 1))
    }

    if [[ -f "$GJF_JAR" ]]; then
        ok "google-java-format installed: $GJF_JAR"
    fi
fi

# ------------------------------------------------------------------
# Summary + Environment persistence
# [R7#1] 持久化驗證過的路徑到 env 檔，供 SKILL.md 讀取
#        解決 JAVA_HOME=Java8 時 command -v java 拿到錯誤版本的問題
# [Review#2] 只在 errors==0 時寫入，避免下游 source 到空變數
# [Review#9] 加 export 確保子程序也能繼承
# ------------------------------------------------------------------
echo ""
if [[ $errors -eq 0 ]]; then
    ENV_FILE="$TOOLS_DIR/lint-gate-env.sh"
    cat > "$ENV_FILE" <<ENVEOF
# Auto-generated by detect-env.sh — do not edit
export JAVA_GJF="$JAVA_DEFAULT"
export GJF_JAR="$GJF_JAR"
export PMD_RUN="$PMD_RUN"
export PMD_DIR="$PMD_DIR"
ENVEOF
    ok "Environment ready. All tools installed."
    ok "Env persisted: $ENV_FILE"
    exit 0
else
    fail "$errors error(s) found. Fix above issues before running lint-gate."
    exit 1
fi
