#!/usr/bin/env bash
# install.sh — One-line installer for claude-java-toolkit
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/keepprogress/claude-java-toolkit/master/install.sh | bash
#   bash install.sh              # if already cloned
#   bash install.sh --uninstall  # remove plugin
#
# What it does:
#   1. Clones the repo (if not already present)
#   2. Creates the cache copy Claude Code expects
#   3. Registers in installed_plugins.json
#   4. Enables in settings.json
#   5. Verifies the installation

set -euo pipefail

# ── Constants ─────────────────────────────────────────────
PLUGIN_NAME="claude-java-toolkit"
PLUGIN_KEY="${PLUGIN_NAME}@${PLUGIN_NAME}"
REPO_URL="https://github.com/keepprogress/${PLUGIN_NAME}.git"

CLAUDE_DIR="$HOME/.claude"
PLUGINS_DIR="$CLAUDE_DIR/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_NAME"
INSTALLED_JSON="$PLUGINS_DIR/installed_plugins.json"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"

# ── Helpers ───────────────────────────────────────────────
info()  { echo "  [INFO] $1"; }
ok()    { echo "  [OK]   $1"; }
warn()  { echo "  [WARN] $1"; }
fail()  { echo "  [FAIL] $1" >&2; }

# ── Uninstall ─────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling $PLUGIN_NAME..."

    # Remove cache
    rm -rf "$PLUGINS_DIR/cache/$PLUGIN_NAME" 2>/dev/null && ok "Removed cache" || true

    # Remove from installed_plugins.json
    if [[ -f "$INSTALLED_JSON" ]] && command -v python3 &>/dev/null; then
        CJT_INSTALLED_JSON="$INSTALLED_JSON" \
        CJT_PLUGIN_KEY="$PLUGIN_KEY" \
        python3 -c "
import json, os, sys
try:
    path = os.environ['CJT_INSTALLED_JSON']
    key = os.environ['CJT_PLUGIN_KEY']
    with open(path, 'r') as f: data = json.load(f)
    plugins = data.get('plugins', data)
    if isinstance(plugins, dict):
        plugins.pop(key, None)
    with open(path, 'w') as f: json.dump(data, f, indent=2)
    print('  [OK]   Removed from installed_plugins.json')
except Exception as e:
    print(f'  [WARN] Could not update installed_plugins.json: {e}', file=sys.stderr)
" 2>/dev/null || warn "Could not update installed_plugins.json"
    fi

    # Remove from settings.json
    if [[ -f "$SETTINGS_JSON" ]] && command -v python3 &>/dev/null; then
        CJT_SETTINGS_JSON="$SETTINGS_JSON" \
        CJT_PLUGIN_KEY="$PLUGIN_KEY" \
        python3 -c "
import json, os, sys
try:
    path = os.environ['CJT_SETTINGS_JSON']
    key = os.environ['CJT_PLUGIN_KEY']
    with open(path, 'r') as f: data = json.load(f)
    data.pop(key, None)
    with open(path, 'w') as f: json.dump(data, f, indent=2)
    print('  [OK]   Removed from settings.json')
except Exception as e:
    print(f'  [WARN] Could not update settings.json: {e}', file=sys.stderr)
" 2>/dev/null || warn "Could not update settings.json"
    fi

    # Optionally remove the cloned repo
    if [[ -d "$PLUGIN_DIR" ]]; then
        if [[ -t 0 ]]; then
            read -rp "  Remove $PLUGIN_DIR? [y/N] " answer
        else
            warn "Non-interactive mode — skipping directory removal"
            answer="n"
        fi
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            rm -rf "$PLUGIN_DIR"
            ok "Removed $PLUGIN_DIR"
        fi
    fi

    echo ""
    echo "Done. Restart Claude Code to apply."
    exit 0
fi

# ── Install ───────────────────────────────────────────────
echo ""
echo "Installing $PLUGIN_NAME..."
echo ""

# Prerequisites
if ! command -v git &>/dev/null; then
    fail "git is required but not found. Install git and try again."
    exit 1
fi

# Step 1: Clone or update
if [[ -d "$PLUGIN_DIR/.git" ]]; then
    info "Plugin directory exists — pulling latest..."
    (cd "$PLUGIN_DIR" && git pull --ff-only 2>/dev/null) && ok "Updated to latest" \
        || warn "Could not pull (offline or dirty state) — using existing"
elif [[ -d "$PLUGIN_DIR" ]]; then
    info "Plugin directory exists (not a git repo) — using as-is"
else
    mkdir -p "$PLUGINS_DIR"
    info "Cloning from $REPO_URL..."
    git clone --depth 1 "$REPO_URL" "$PLUGIN_DIR" 2>/dev/null \
        && ok "Cloned to $PLUGIN_DIR" \
        || { fail "Failed to clone. Check network and try again."; exit 1; }
fi

# Step 2: Read version from plugin.json
VERSION="0.2.0"
if command -v python3 &>/dev/null && [[ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ]]; then
    VERSION=$(CJT_PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json" \
        python3 -c "
import json, os
with open(os.environ['CJT_PLUGIN_JSON']) as f:
    print(json.load(f).get('version', '0.2.0'))
" 2>/dev/null) || VERSION="0.2.0"
fi
CACHE_DIR="$PLUGINS_DIR/cache/$PLUGIN_NAME/$PLUGIN_NAME/$VERSION"

# Step 3: Create cache copy
info "Setting up cache (v$VERSION)..."
rm -rf "$PLUGINS_DIR/cache/$PLUGIN_NAME" 2>/dev/null || true
mkdir -p "$CACHE_DIR"
cp -r "$PLUGIN_DIR/.claude-plugin" "$CACHE_DIR/"
cp -r "$PLUGIN_DIR/skills" "$CACHE_DIR/"
ok "Cache created at $CACHE_DIR"

# Step 4: Register in installed_plugins.json
info "Registering plugin..."
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || echo "2026-01-01T00:00:00.000Z")
GIT_SHA=$(cd "$PLUGIN_DIR" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "0000000")

REGISTERED=false
if command -v python3 &>/dev/null; then
    CJT_INSTALLED_JSON="$INSTALLED_JSON" \
    CJT_PLUGIN_KEY="$PLUGIN_KEY" \
    CJT_CACHE_DIR="$CACHE_DIR" \
    CJT_VERSION="$VERSION" \
    CJT_TIMESTAMP="$TIMESTAMP" \
    CJT_GIT_SHA="$GIT_SHA" \
    python3 -c "
import json, os

path = os.environ['CJT_INSTALLED_JSON']
key = os.environ['CJT_PLUGIN_KEY']
data = {}

if os.path.isfile(path):
    try:
        with open(path, 'r') as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        data = {}

if 'plugins' not in data:
    data['plugins'] = {}

data['plugins'][key] = [
    {
        'scope': 'user',
        'installPath': os.environ['CJT_CACHE_DIR'],
        'version': os.environ['CJT_VERSION'],
        'installedAt': os.environ['CJT_TIMESTAMP'],
        'lastUpdated': os.environ['CJT_TIMESTAMP'],
        'gitCommitSha': os.environ['CJT_GIT_SHA']
    }
]

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print('  [OK]   Registered in installed_plugins.json')
" && REGISTERED=true || { fail "Could not update installed_plugins.json"; exit 1; }
else
    warn "python3 not found — cannot auto-register plugin."
    warn "Manually add to $INSTALLED_JSON:"
    echo ""
    echo "  \"$PLUGIN_KEY\": [{\"scope\":\"user\",\"installPath\":\"$CACHE_DIR\",\"version\":\"$VERSION\"}]"
    echo ""
fi

# Step 5: Enable in settings.json
if command -v python3 &>/dev/null; then
    CJT_SETTINGS_JSON="$SETTINGS_JSON" \
    CJT_PLUGIN_KEY="$PLUGIN_KEY" \
    python3 -c "
import json, os

path = os.environ['CJT_SETTINGS_JSON']
key = os.environ['CJT_PLUGIN_KEY']
data = {}

if os.path.isfile(path):
    try:
        with open(path, 'r') as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        data = {}

data[key] = True

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print('  [OK]   Enabled in settings.json')
" || warn "Could not update settings.json"
else
    warn "Manually add to $SETTINGS_JSON:"
    echo "  \"$PLUGIN_KEY\": true"
fi

# Step 6: Verify
echo ""
echo "── Verification ─────────────────────────────────"
PASS=true

[[ -f "$CACHE_DIR/.claude-plugin/plugin.json" ]] \
    && ok "plugin.json exists" \
    || { fail "plugin.json missing"; PASS=false; }

[[ -f "$CACHE_DIR/skills/code-gate/SKILL.md" ]] \
    && ok "SKILL.md exists" \
    || { fail "SKILL.md missing"; PASS=false; }

[[ -f "$CACHE_DIR/skills/code-gate/scripts/detect-env.sh" ]] \
    && ok "Scripts present" \
    || { fail "Scripts missing"; PASS=false; }

if [[ "$REGISTERED" != true ]]; then
    warn "Plugin not auto-registered (python3 missing) — manual steps required"
    PASS=false
fi

if command -v java &>/dev/null; then
    java_ver=$(java -version 2>&1 | head -1)
    major=$(echo "$java_ver" | sed -E 's/.*"([0-9]+)[."$].*/\1/')
    if [[ -n "$major" && "$major" -ge 17 ]] 2>/dev/null; then
        ok "Java $major detected"
    else
        warn "Java 17+ recommended (found: $java_ver)"
    fi
else
    warn "Java not found — required at runtime"
fi

echo ""
if [[ "$PASS" == true ]]; then
    echo "Installation complete (v$VERSION)."
    echo ""
    echo "Next steps:"
    echo "  1. Restart Claude Code"
    echo "  2. Run: /claude-java-toolkit:code-gate"
    echo ""
else
    fail "Installation incomplete — check warnings above."
    exit 1
fi
