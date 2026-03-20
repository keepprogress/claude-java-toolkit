#!/usr/bin/env bash
# resolve-pmd-version.sh — 從 pom.xml 解析 PMD 版本，自動對齊 CI
# 用法: source resolve-pmd-version.sh && resolve_versions [project_root]
# 輸出: 設定 PMD_ENGINE_VERSION, MINIMUM_TOKENS, TARGET_JDK, RULESET_PATH 環境變數
# 依賴: grep, sed, curl（僅首次或版本變更時需要網路）

set -euo pipefail

TOOLS_DIR="$HOME/.claude/tools"
VERSIONS_FILE="$TOOLS_DIR/lint-gate-versions.txt"

resolve_versions() {
    local project_root="${1:-.}"
    local root_pom="$project_root/pom.xml"

    if [[ ! -f "$root_pom" ]]; then
        echo "ERROR: $root_pom not found" >&2
        return 1
    fi

    # --- Extract from root pom.xml ---

    # maven-pmd-plugin version: look in <pluginManagement> section
    # [R3#3] -A5 for robustness — tolerates comments or blank lines between artifactId and version
    local plugin_version
    plugin_version=$(grep -A5 'maven-pmd-plugin' "$root_pom" \
        | grep '<version>' \
        | sed 's/.*<version>\([^<]*\)<\/version>.*/\1/' \
        | head -1)

    if [[ -z "$plugin_version" ]]; then
        echo "ERROR: maven-pmd-plugin version not found in $root_pom" >&2
        return 1
    fi

    # minimumTokens
    local min_tokens
    min_tokens=$(grep '<minimumTokens>' "$root_pom" \
        | sed 's/.*<minimumTokens>\([^<]*\)<\/minimumTokens>.*/\1/' \
        | head -1)
    min_tokens="${min_tokens:-100}"

    # targetJdk
    local target_jdk
    target_jdk=$(grep '<targetJdk>' "$root_pom" \
        | sed 's/.*<targetJdk>\([^<]*\)<\/targetJdk>.*/\1/' \
        | head -1)
    target_jdk="${target_jdk:-1.8}"

    # ruleset path
    local ruleset
    ruleset=$(grep '<ruleset>' "$root_pom" \
        | sed 's/.*<ruleset>\([^<]*\)<\/ruleset>.*/\1/' \
        | head -1)
    ruleset="${ruleset:-pmd-rules.xml}"

    # --- Check if cached version matches ---

    if [[ -f "$VERSIONS_FILE" ]]; then
        local cached_plugin
        cached_plugin=$(grep '^pmd-plugin=' "$VERSIONS_FILE" | cut -d= -f2)
        if [[ "$cached_plugin" == "$plugin_version" ]]; then
            # Version unchanged — load from cache
            PMD_PLUGIN_VERSION="$plugin_version"
            PMD_ENGINE_VERSION=$(grep '^pmd-engine=' "$VERSIONS_FILE" | cut -d= -f2)
            MINIMUM_TOKENS="$min_tokens"
            TARGET_JDK="$target_jdk"
            RULESET_PATH="$ruleset"
            export PMD_PLUGIN_VERSION PMD_ENGINE_VERSION MINIMUM_TOKENS TARGET_JDK RULESET_PATH
            echo "OK: PMD versions cached (plugin=$PMD_PLUGIN_VERSION, engine=$PMD_ENGINE_VERSION)"
            return 0
        fi
    fi

    # --- Resolve PMD engine version from Maven Central ---

    echo "Resolving PMD engine version for maven-pmd-plugin $plugin_version..."

    local plugin_pom_url="https://repo1.maven.org/maven2/org/apache/maven/plugins/maven-pmd-plugin/${plugin_version}/maven-pmd-plugin-${plugin_version}.pom"
    local plugin_pom
    plugin_pom=$(curl -fsSL "$plugin_pom_url" 2>/dev/null) || {
        echo "ERROR: Failed to fetch plugin POM from Maven Central" >&2
        echo "URL: $plugin_pom_url" >&2
        return 1
    }

    local engine_version
    engine_version=$(echo "$plugin_pom" \
        | grep '<pmdVersion>' \
        | sed 's/.*<pmdVersion>\([^<]*\)<\/pmdVersion>.*/\1/' \
        | head -1)

    if [[ -z "$engine_version" ]]; then
        echo "ERROR: Could not extract pmdVersion from plugin POM" >&2
        return 1
    fi

    # --- Save to cache ---

    mkdir -p "$TOOLS_DIR"
    cat > "$VERSIONS_FILE" <<VEOF
pmd-plugin=$plugin_version
pmd-engine=$engine_version
VEOF
    # Note: minimumTokens/targetJdk/ruleset are always read fresh from pom.xml,
    # not cached — they may change independently of plugin version.
    # google-java-format version is managed in detect-env.sh (GJF_VERSION).

    PMD_PLUGIN_VERSION="$plugin_version"
    PMD_ENGINE_VERSION="$engine_version"
    MINIMUM_TOKENS="$min_tokens"
    TARGET_JDK="$target_jdk"
    RULESET_PATH="$ruleset"
    export PMD_PLUGIN_VERSION PMD_ENGINE_VERSION MINIMUM_TOKENS TARGET_JDK RULESET_PATH

    echo "OK: Resolved PMD engine=$engine_version for plugin=$plugin_version"
}
