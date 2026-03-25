# claude-java-toolkit

Java 專案的 Claude Code 開發工具 Plugin。

快速掃描專案的 code quality 弱點，自動修復常見問題，幫助你決定要導入什麼工具。

**不需要 `pom.xml`** — 丟進任何 Java 專案就能跑。如果有 `pom.xml`，會自動對齊 CI 的 PMD 版本和規則。

## 功能

### code-gate

Pre-commit 程式碼品質關卡，兩階段漸進式檢查：

| 階段 | 內容 | 需要 Maven？ |
|------|------|-------------|
| **Phase 1** | PMD + CPD + import 修復 + suppression guard | 不需要 |
| **Phase 2** | ArchUnit（自動搜尋測試類別） | 需要 |

**核心特色：**
- 有 `pom.xml` → PMD 版本自動對齊 CI，零 drift
- 沒有 `pom.xml` → 使用 PMD 內建規則快速掃描
- 支援單模組 (`src/main/java`) 和多模組 (`module/src/main/java`) 專案
- google-java-format 自動修復 unused imports
- Claude 自動修復 logger 串接、fully qualified name、System.out
- 純 bash，跨平台（Git Bash / Linux / macOS）

---

## 系統需求

| 項目 | 版本 | 必要？ |
|------|------|--------|
| [Claude Code](https://claude.ai/code) | 最新版 | 必要 |
| Java 17+ | 系統預設 | 必要（PMD CLI + google-java-format） |
| Git Bash / bash | 4.0+ | 必要（macOS 需 `brew install bash`） |
| curl + unzip | 任意 | 必要（首次下載工具） |
| Maven | 3.x | 選用（Phase 2） |

> 首次執行時自動下載 PMD CLI (~35MB) 和 google-java-format (~5MB) 到 `~/.claude/tools/`。
> 可透過環境變數 `CODE_GATE_TOOLS_DIR` 自訂安裝路徑。

**注意事項：**
- macOS 預設 Bash 為 3.2，需透過 `brew install bash` 升級至 4.0+
- `--fix-imports-only` 會同時重新排序 imports 為 Google style，可能與 IntelliJ 預設排序不同。如需跳過，使用 `--report-only` 模式
- 支援 PMD 6.x 和 PMD 7.x（自動偵測版本並切換 CLI 語法）
- 需存取的外部 URL：`github.com`（PMD/GJF 下載）、`repo1.maven.org`（版本解析）

---

## 安裝

### 方法一：Plugin marketplace（推薦）

```
/plugin marketplace add keepprogress/claude-java-toolkit
/plugin install claude-java-toolkit@claude-java-toolkit --scope user
```

重啟 Claude Code。

### 方法二：手動安裝

**1. Clone**
```bash
cd ~/.claude/plugins
git clone https://github.com/keepprogress/claude-java-toolkit.git
```

**2. 建立 cache 副本**
```bash
mkdir -p ~/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0
cp -r ~/.claude/plugins/claude-java-toolkit/.claude-plugin \
      ~/.claude/plugins/claude-java-toolkit/skills \
      ~/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0/
```

**3. 註冊到 `installed_plugins.json`**

編輯 `~/.claude/plugins/installed_plugins.json`，在 `"plugins"` 內加入：

```json
"claude-java-toolkit@claude-java-toolkit": [
  {
    "scope": "user",
    "installPath": "YOUR_HOME/.claude/plugins/cache/claude-java-toolkit/claude-java-toolkit/0.1.0",
    "version": "0.1.0",
    "installedAt": "2026-03-25T00:00:00.000Z",
    "lastUpdated": "2026-03-25T00:00:00.000Z",
    "gitCommitSha": "0000000"
  }
]
```

> `YOUR_HOME` 替換為家目錄完整路徑。

**4. 啟用**

編輯 `~/.claude/settings.json`，加入：
```json
"claude-java-toolkit@claude-java-toolkit": true
```

**5. 重啟 Claude Code**

---

## 使用方式

```
# 自動偵測模組，增量掃描 branch 變更
/claude-java-toolkit:code-gate

# 指定模組
/claude-java-toolkit:code-gate MyModule

# 全量掃描
/claude-java-toolkit:code-gate MyModule --full

# 只報告不修復
/claude-java-toolkit:code-gate --report-only

# 包含測試程式碼
/claude-java-toolkit:code-gate --include-tests

# 掃描所有有變更的模組
/claude-java-toolkit:code-gate --all

# 生成 suppression allowlist（用於舊專案 baseline）
bash ~/.claude/plugins/claude-java-toolkit/skills/code-gate/scripts/check-suppressions.sh \
  --generate-allowlist . > src/test/resources/lint-suppression-allowlist.txt
```

### 適用場景

- **Commit 前自檢** — 預設增量模式，秒級完成
- **新專案評估** — `--full --report-only` 快速看弱點，決定導入什麼工具
- **CI gate 對齊** — 有 `pom.xml` 時自動對齊 CI 的 PMD 版本和規則
- **舊專案導入** — `--generate-allowlist` 建立 baseline，逐步改善

---

## 目錄結構

```
claude-java-toolkit/
├── .claude-plugin/
│   ├── plugin.json          ← Plugin manifest
│   └── marketplace.json     ← Marketplace index
├── skills/
│   └── code-gate/
│       ├── SKILL.md             ← Skill 定義
│       ├── scripts/
│       │   ├── detect-env.sh        ← 環境偵測 + 工具下載
│       │   ├── resolve-pmd-version.sh ← PMD 版本解析（pom.xml or defaults）
│       │   ├── run-pmd.sh           ← PMD / CPD runner
│       │   └── check-suppressions.sh ← Suppression guard
│       └── reference/
│           └── violation-fixes.md   ← 自動修復規則參考
└── README.md
```

## 授權

MIT
