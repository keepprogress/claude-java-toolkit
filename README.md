# claude-java-toolkit

Java / Spring Boot / Maven 專案的 Claude Code 開發工具 Plugin。

目前包含 `lint-gate` skill，未來將擴充更多 skill。

## 功能總覽

### lint-gate

兩階段漸進式 lint 檢查，與 CI 自動對齊：

| 階段 | 內容 | 需要 Maven？ |
|------|------|-------------|
| **Phase 1** | PMD + CPD + import 修復 + suppression guard | 不需要 |
| **Phase 2** | ArchUnit（架構規則 + LintSuppressionGuard） | 需要 |

**核心特色：**
- PMD CLI 版本自動從 `pom.xml` 的 `maven-pmd-plugin` 解析，與 CI 零 drift
- 規則檔讀取專案的 `pmd-rules.xml`，skill 本身不攜帶任何規則
- google-java-format 自動修復 unused imports
- Claude 自動修復 logger 串接、fully qualified name、System.out 等常見 violation
- 純 bash 腳本，零 PowerShell / WSL 依賴

---

## 系統需求

| 項目 | 版本 | 用途 | 必要？ |
|------|------|------|--------|
| [Claude Code](https://claude.ai/code) | 最新版 | 執行環境 | 必要 |
| Git Bash (MINGW64) | 4.0+ | 腳本執行 | 必要 |
| Java 8 | Amazon Corretto 8 或相容版本 | Maven / ArchUnit | 必要 |
| Java 17+ | 系統預設 Java | google-java-format | 必要 |
| Maven | 3.x | Phase 2 ArchUnit（選用） | 選用 |
| curl | 任意版本 | 首次下載工具 | 必要 |
| unzip | 任意版本 | 解壓 PMD CLI | 必要（或 `jar` 替代） |

> **自動下載的工具**（首次執行時由 `detect-env.sh` 安裝到 `~/.claude/tools/`）：
> - PMD CLI（~35MB）— 版本自動對齊 `pom.xml`
> - google-java-format（~5MB）— 版本 1.24.0

---

## 安裝方式

### 方法一：透過 Claude Code Plugin 系統安裝（推薦）

在 Claude Code 中執行：

```
/plugin marketplace add keepprogress/claude-java-toolkit
/plugin install claude-java-toolkit@claude-java-toolkit --scope user
```

安裝完成後重啟 Claude Code。

### 方法二：手動安裝

如果 Plugin 系統安裝失敗，依以下步驟手動設定：

**步驟 1：Clone repo**

```bash
cd ~/.claude/plugins
git clone https://github.com/keepprogress/claude-java-toolkit.git
```

**步驟 2：建立 cache 副本**

```bash
mkdir -p ~/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0
cp -r ~/.claude/plugins/claude-java-toolkit/.claude-plugin \
      ~/.claude/plugins/claude-java-toolkit/skills \
      ~/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0/
```

**步驟 3：註冊到 `installed_plugins.json`**

編輯 `~/.claude/plugins/installed_plugins.json`，在 `"plugins"` 物件內加入：

```json
"claude-java-toolkit@claude-java-toolkit": [
  {
    "scope": "user",
    "installPath": "YOUR_HOME/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0",
    "version": "0.1.0",
    "installedAt": "2026-03-20T00:00:00.000Z",
    "lastUpdated": "2026-03-20T00:00:00.000Z",
    "gitCommitSha": "0000000"
  }
]
```

> 把 `YOUR_HOME` 替換為你的家目錄完整路徑（Windows 用 `\\` 分隔）。

**步驟 4：啟用 plugin**

編輯 `~/.claude/settings.json`，在 `"enabledPlugins"` 內加入：

```json
"claude-java-toolkit@claude-java-toolkit": true
```

**步驟 5：重啟 Claude Code**

---

## 使用方式

在 Claude Code 中執行：

```
/claude-java-toolkit:lint-gate TlwCrpFrontendApi
```

或不指定模組（自動偵測 git 變更的模組）：

```
/claude-java-toolkit:lint-gate
```

### 執行流程

```
Phase 0: 環境偵測
  ├─ 檢查 Java 8 / Java 17+
  ├─ 從 pom.xml 解析 PMD 版本
  └─ 自動下載 PMD CLI + google-java-format（首次）

Phase 1: 獨立檢查（不需 Maven）
  ├─ Step 1: google-java-format 修復 import（自動）
  ├─ Step 2: PMD 檢查 + Claude 自動修復 violation
  ├─ Step 3: CPD 重複程式碼檢查（僅報告）
  └─ Step 4: Suppression guard（僅報告）

Phase 2: ArchUnit（選用，需 Maven）
  ├─ 架構規則檢查
  └─ LintSuppressionGuard 交叉驗證
```

### Phase 1 結果範例

```
| Check       | Status | Auto-fixed | Remaining     |
|-------------|--------|------------|---------------|
| Imports     | PASS   | 3 files    | —             |
| PMD         | FIXED  | 5 fixes    | 2 (manual)    |
| CPD         | WARN   | —          | 1 duplication |
| Suppressions| PASS   | —          | —             |
```

---

## 疑難排解

### 問題 1：`/claude-java-toolkit:lint-gate` 找不到

**原因：** Plugin 未正確載入。

**檢查步驟：**

```bash
# 1. 確認 cache 目錄存在
ls ~/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0/skills/lint-gate/SKILL.md

# 2. 確認 installed_plugins.json 有條目
grep "claude-java-toolkit" ~/.claude/plugins/installed_plugins.json

# 3. 確認 settings.json 已啟用
grep "claude-java-toolkit" ~/.claude/settings.json
```

如果缺少任一項，回到「手動安裝」步驟補上，然後重啟 Claude Code。

### 問題 2：Phase 0 detect-env.sh 失敗

**常見錯誤與解法：**

```
[FAIL] Java 8 not found at /c/Developer/AmazonCorretto1.8.0_452
```
→ 安裝 [Amazon Corretto 8](https://docs.aws.amazon.com/corretto/latest/corretto-8-ug/downloads-list.html)，安裝後修改 `detect-env.sh` 第 29 行的 `JAVA8_HOME` 路徑。

```
[FAIL] System Java is "1.8.0_452" — google-java-format needs 17+
```
→ 安裝 Java 17+（如 [Amazon Corretto 21](https://docs.aws.amazon.com/corretto/latest/corretto-21-ug/downloads-list.html)），並確保 `java -version` 顯示 17 以上。

```
[FAIL] Failed to download PMD CLI
```
→ 檢查網路連線。手動下載：
```bash
PMD_VERSION="6.55.0"  # 依你的 pom.xml 版本調整
curl -fSL -o /tmp/pmd.zip \
  "https://github.com/pmd/pmd/releases/download/pmd_releases%2F${PMD_VERSION}/pmd-bin-${PMD_VERSION}.zip"
mkdir -p ~/.claude/tools
unzip -q -o /tmp/pmd.zip -d ~/.claude/tools
rm /tmp/pmd.zip
```

```
[FAIL] Failed to download google-java-format
```
→ 手動下載：
```bash
curl -fSL -o ~/.claude/tools/google-java-format-1.24.0.jar \
  "https://github.com/google/google-java-format/releases/download/v1.24.0/google-java-format-1.24.0-all-deps.jar"
```

### 問題 3：PMD 結果與 CI 不一致

**排查步驟：**

```bash
# 確認 PMD 版本對齊
cat ~/.claude/tools/lint-gate-versions.txt
# 預期看到 pmd-engine=6.55.0（或你的 CI 版本）

# 強制重新解析版本（刪除快取）
rm ~/.claude/tools/lint-gate-versions.txt
# 重新執行 /claude-java-toolkit:lint-gate

# 比對 standalone 與 Maven 結果
export JAVA_HOME="/c/Developer/AmazonCorretto1.8.0_452"
export PATH="$JAVA_HOME/bin:$PATH"
mvn pmd:check -pl YOUR_MODULE 2>&1 | tail -10
```

### 問題 4：run.sh 執行失敗（Git Bash readlink 問題）

PMD 的 `run.sh` 使用 `readlink -f`，Git Bash 不支援。`run-pmd.sh` 內建自動 fallback 到 `java -cp`，正常不需介入。如果 fallback 也失敗：

```bash
# 手動測試 PMD CLI
java -cp "$HOME/.claude/tools/pmd-bin-6.55.0/lib/*" \
  net.sourceforge.pmd.PMD \
  -d YOUR_MODULE/src/main/java \
  -R pmd-rules.xml \
  -f text
```

### 問題 5：手動安裝前置工具腳本

如果 `detect-env.sh` 的自動下載全部失敗，可用以下腳本一次手動安裝：

```bash
#!/usr/bin/env bash
# manual-install-tools.sh — 手動安裝 lint-gate 前置工具
set -euo pipefail

TOOLS_DIR="$HOME/.claude/tools"
mkdir -p "$TOOLS_DIR"

# --- 1. 確認 Java ---
echo "=== Java 檢查 ==="
java -version 2>&1 | head -1
echo ""

# --- 2. 安裝 PMD CLI ---
PMD_VERSION="${1:-6.55.0}"
PMD_DIR="$TOOLS_DIR/pmd-bin-${PMD_VERSION}"

if [[ -f "$PMD_DIR/bin/run.sh" ]]; then
    echo "[OK] PMD CLI $PMD_VERSION 已安裝"
else
    echo "下載 PMD CLI $PMD_VERSION..."
    curl -fSL -o "$TOOLS_DIR/pmd.zip" \
        "https://github.com/pmd/pmd/releases/download/pmd_releases%2F${PMD_VERSION}/pmd-bin-${PMD_VERSION}.zip"
    unzip -q -o "$TOOLS_DIR/pmd.zip" -d "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/pmd.zip"
    chmod +x "$PMD_DIR/bin/run.sh" 2>/dev/null || true
    echo "[OK] PMD CLI 安裝完成: $PMD_DIR"
fi

# --- 3. 安裝 google-java-format ---
GJF_VERSION="1.24.0"
GJF_JAR="$TOOLS_DIR/google-java-format-${GJF_VERSION}.jar"

if [[ -f "$GJF_JAR" ]]; then
    echo "[OK] google-java-format $GJF_VERSION 已安裝"
else
    echo "下載 google-java-format $GJF_VERSION..."
    curl -fSL -o "$GJF_JAR" \
        "https://github.com/google/google-java-format/releases/download/v${GJF_VERSION}/google-java-format-${GJF_VERSION}-all-deps.jar"
    echo "[OK] google-java-format 安裝完成: $GJF_JAR"
fi

# --- 4. 建立 env 檔 ---
JAVA_GJF=$(command -v java 2>/dev/null || true)
cat > "$TOOLS_DIR/lint-gate-env.sh" <<ENVEOF
# Auto-generated by manual-install-tools.sh
export JAVA_GJF="$JAVA_GJF"
export GJF_JAR="$GJF_JAR"
export PMD_RUN="$PMD_DIR/bin/run.sh"
export PMD_DIR="$PMD_DIR"
ENVEOF

echo ""
echo "=== 安裝完成 ==="
echo "工具目錄: $TOOLS_DIR"
echo "Env 檔案: $TOOLS_DIR/lint-gate-env.sh"
ls -lh "$PMD_DIR/bin/run.sh" "$GJF_JAR" "$TOOLS_DIR/lint-gate-env.sh"
```

使用方式：
```bash
# 使用預設 PMD 版本 (6.55.0)
bash manual-install-tools.sh

# 指定特定 PMD 版本
bash manual-install-tools.sh 6.55.0
```

---

## 目錄結構

```
claude-java-toolkit/
├── .claude-plugin/
│   └── plugin.json              ← Plugin manifest
├── skills/
│   └── lint-gate/
│       ├── SKILL.md             ← Skill 定義（Claude 讀取執行）
│       ├── scripts/
│       │   ├── detect-env.sh        ← 環境偵測 + 工具自動安裝
│       │   ├── resolve-pmd-version.sh ← pom.xml → PMD engine 版本對齊
│       │   ├── run-pmd.sh           ← PMD / CPD 獨立執行器
│       │   └── check-suppressions.sh ← grep 版 suppression guard
│       └── reference/
│           └── violation-fixes.md   ← 自動修復規則參考
├── README.md
└── (未來擴充更多 skills)
```

## 設計原則

- **規則在專案、腳本在 skill** — Skill 不攜帶任何規則檔，全部從專案的 `pmd-rules.xml` 和 `lint-suppression-allowlist.txt` 讀取，與 CI 自動對齊
- **漸進式執行** — Phase 1 秒級完成（獨立 CLI），Phase 2 選用（需 Maven 編譯）
- **純 bash** — 零 PowerShell / WSL 依賴，Git Bash (MINGW64) 原生執行

## 授權

MIT
