#!/usr/bin/env bash
# resolve-pmd-version.sh — 從 pom.xml 解析 PMD 版本，或用預設值
# 用法: source resolve-pmd-version.sh && resolve_versions [project_root]
# 輸出: PMD_ENGINE_VERSION, MINIMUM_TOKENS, RULESET_PATH 環境變數

set -euo pipefail

TOOLS_DIR="$HOME/.claude/tools"
VERSIONS_FILE="$TOOLS_DIR/code-gate-versions.txt"

# Defaults (PMD 6.55.0 = last stable 6.x)
DEFAULT_PMD_ENGINE="6.55.0"
DEFAULT_TOKENS="100"

resolve_versions() {
    local project_root="${1:-.}"
    local root_pom="$project_root/pom.xml"

    # ----------------------------------------------------------
    # No pom.xml → use defaults
    # ----------------------------------------------------------
    if [[ ! -f "$root_pom" ]]; then
        PMD_ENGINE_VERSION="$DEFAULT_PMD_ENGINE"
        MINIMUM_TOKENS="$DEFAULT_TOKENS"
        RULESET_PATH=""
        export PMD_ENGINE_VERSION MINIMUM_TOKENS RULESET_PATH

        mkdir -p "$TOOLS_DIR"
        cat > "$VERSIONS_FILE" <<VEOF
pmd-plugin=standalone
pmd-engine=$PMD_ENGINE_VERSION
minimumTokens=$MINIMUM_TOKENS
ruleset=
VEOF
        echo "No pom.xml — using PMD $PMD_ENGINE_VERSION defaults"
        return 0
    fi

    # ----------------------------------------------------------
    # Has pom.xml → try to read maven-pmd-plugin version
    # ----------------------------------------------------------
    local plugin_version
    plugin_version=$(grep -A5 'maven-pmd-plugin' "$root_pom" \
        | grep '<version>' \
        | sed 's/.*<version>\([^<]*\)<\/version>.*/\1/' \
        | head -1 || true)

    local min_tokens
    min_tokens=$(grep '<minimumTokens>' "$root_pom" \
        | sed 's/.*<minimumTokens>\([^<]*\)<\/minimumTokens>.*/\1/' \
        | head -1 || true)
    min_tokens="${min_tokens:-$DEFAULT_TOKENS}"

    local ruleset
    ruleset=$(grep '<ruleset>' "$root_pom" \
        | sed 's/.*<ruleset>\([^<]*\)<\/ruleset>.*/\1/' \
        | head -1 || true)
    # Also check for common ruleset files if pom doesn't specify
    if [[ -z "$ruleset" ]]; then
        for f in pmd-rules.xml pmd-ruleset.xml; do
            [[ -f "$project_root/$f" ]] && ruleset="$f" && break
        done
    fi

    # No maven-pmd-plugin → use defaults but keep discovered ruleset
    if [[ -z "$plugin_version" ]]; then
        PMD_ENGINE_VERSION="$DEFAULT_PMD_ENGINE"
        MINIMUM_TOKENS="$min_tokens"
        RULESET_PATH="${ruleset:-}"
        export PMD_ENGINE_VERSION MINIMUM_TOKENS RULESET_PATH

        mkdir -p "$TOOLS_DIR"
        cat > "$VERSIONS_FILE" <<VEOF
pmd-plugin=standalone
pmd-engine=$PMD_ENGINE_VERSION
minimumTokens=$MINIMUM_TOKENS
ruleset=${RULESET_PATH:-}
VEOF
        echo "pom.xml found but no maven-pmd-plugin — using PMD $PMD_ENGINE_VERSION"
        return 0
    fi

    # ----------------------------------------------------------
    # Has maven-pmd-plugin → resolve engine version (with cache)
    # ----------------------------------------------------------
    if [[ -f "$VERSIONS_FILE" ]]; then
        local cached_plugin
        cached_plugin=$(grep '^pmd-plugin=' "$VERSIONS_FILE" | cut -d= -f2)
        if [[ "$cached_plugin" == "$plugin_version" ]]; then
            PMD_ENGINE_VERSION=$(grep '^pmd-engine=' "$VERSIONS_FILE" | cut -d= -f2)
            MINIMUM_TOKENS="$min_tokens"
            RULESET_PATH="${ruleset:-}"
            export PMD_ENGINE_VERSION MINIMUM_TOKENS RULESET_PATH
            echo "PMD versions cached (plugin=$plugin_version, engine=$PMD_ENGINE_VERSION)"
            return 0
        fi
    fi

    echo "Resolving PMD engine version for maven-pmd-plugin $plugin_version..."

    local plugin_pom_url="https://repo1.maven.org/maven2/org/apache/maven/plugins/maven-pmd-plugin/${plugin_version}/maven-pmd-plugin-${plugin_version}.pom"
    local plugin_pom
    plugin_pom=$(curl -fsSL "$plugin_pom_url" 2>/dev/null) || {
        echo "WARN: Failed to fetch plugin POM — using default PMD $DEFAULT_PMD_ENGINE" >&2
        PMD_ENGINE_VERSION="$DEFAULT_PMD_ENGINE"
        MINIMUM_TOKENS="$min_tokens"
        RULESET_PATH="${ruleset:-}"
        export PMD_ENGINE_VERSION MINIMUM_TOKENS RULESET_PATH
        return 0
    }

    local engine_version
    engine_version=$(echo "$plugin_pom" \
        | grep '<pmdVersion>' \
        | sed 's/.*<pmdVersion>\([^<]*\)<\/pmdVersion>.*/\1/' \
        | head -1 || true)
    engine_version="${engine_version:-$DEFAULT_PMD_ENGINE}"

    mkdir -p "$TOOLS_DIR"
    cat > "$VERSIONS_FILE" <<VEOF
pmd-plugin=$plugin_version
pmd-engine=$engine_version
minimumTokens=$min_tokens
ruleset=${ruleset:-}
VEOF

    PMD_ENGINE_VERSION="$engine_version"
    MINIMUM_TOKENS="$min_tokens"
    RULESET_PATH="${ruleset:-}"
    export PMD_ENGINE_VERSION MINIMUM_TOKENS RULESET_PATH

    echo "Resolved PMD engine=$engine_version for plugin=$plugin_version"
}
