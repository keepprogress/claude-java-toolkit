# code-gate Skill 多方專家審查報告

> **日期**: 2026-03-25
> **專案**: claude-java-toolkit v0.1.0
> **審查範圍**: skills/code-gate 全部檔案（SKILL.md、4 腳本、reference、plugin manifest）
> **模型**: Claude Opus 4.6 (1M context) × 6 agents, max effort
> **語言**: 繁體中文

---

## 審查團隊

| 代號 | 角色 | 關注焦點 |
|------|------|----------|
| **DX** | 開發者體驗專家 | 首次體驗、錯誤訊息、文件品質、工作流整合 |
| **JAVA** | Java / PMD 資深專家 | PMD 版本、規則集、auto-fix 正確性、Java 生態 |
| **ARCH** | 軟體架構師 | 可擴充性、耦合度、輸出協定、關注點分離 |
| **SEC** | 安全與可靠性工程師 | 供應鏈安全、命令注入、錯誤處理、快取投毒 |
| **USER** | Java 開發者 / 終端使用者 | 安裝體驗、誤報、信任度、團隊導入門檻 |
| **OPS** | DevOps / CI-CD 工程師 | 跨平台、CI 整合、快取策略、可重現性 |

---

## 第一部分：跨團隊共識（多位專家獨立提出相同發現）

### 🔴 共識 #1：PMD 7.x 完全不相容 — 功能性阻斷缺陷

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| DX, JAVA, ARCH, USER, OPS | 🟢高 (92-95%) | **P0** |

**問題**: `run-pmd.sh` 使用 PMD 6.x CLI 語法（`run.sh pmd -d ...`），但 `resolve-pmd-version.sh` 可能解析出 PMD 7.x 版本號（當專案使用 `maven-pmd-plugin ≥ 3.22.0` 時）。PMD 7.0 已於 2024 年 3 月正式發布，與 6.x 有以下**不可相容的差異**：

- CLI 語法: `run.sh pmd -d` → `pmd check -d`
- Main class: `net.sourceforge.pmd.PMD` 已被**刪除**
- 下載檔名: `pmd-bin-{ver}.zip` → `pmd-dist-{ver}-bin.zip`
- Exit code: 新增 code 5 (recoverable errors)
- CPD: 獨立指令 → `pmd cpd` 子命令

**辯論紀錄**:
- **JAVA** 主張應實作完整的 PMD 7 支援（版本分流）
- **ARCH** 建議至少在 `resolve-pmd-version.sh` 中加入上限檢查，偵測到 7.x 即 fallback + warn
- **DX** 認為應 fail fast with clear message，而非靜默降級
- **共識**: 短期→偵測 7.x 並 fail fast + 明確錯誤訊息；中期→實作完整版本分流

**行動項目**:
1. `_exec_pmd()` 加入 major version 檢查，PMD 7.x 時輸出明確錯誤
2. `detect-env.sh` 下載邏輯根據 major version 切換 URL 模板
3. `run-pmd.sh` 根據 major version 分流 CLI 語法

---

### 🔴 共識 #2：`detect-env.sh` 中 `local` 在函式外使用

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| DX, JAVA, ARCH, SEC, USER, OPS | 🟢高 (90-95%) | **P0** |

**問題**: `detect-env.sh` 第 156 行 `local first_run=false` 位於腳本頂層，不在任何函式內。`local` 僅在函式內有效，屬 undefined behavior。

**辯論紀錄**:
- **全員一致** — 這是明確的 bug，無爭議
- **OPS** 額外指出 Alpine Linux 的 `ash` 會直接報錯
- **DX** 指出搭配 `set -e` 可能導致腳本靜默中斷

**行動項目**: 將 `local first_run=false` 改為 `first_run=false`

---

### 🔴 共識 #3：增量模式硬編碼 `master` 分支

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| DX, ARCH, USER, OPS | 🟢高 (95-96%) | **P0-P1** |

**問題**: SKILL.md 中 `git merge-base master HEAD` 硬編碼 `master`。GitHub 自 2020 年起預設使用 `main`。

**辯論紀錄**:
- **DX** 主張 P0（影響所有非 master 專案）
- **ARCH** 主張 P1（SKILL.md 中的指令，Claude 可能自行適應）
- **共識**: P0 — 不應依賴 LLM 自行判斷基準分支

**行動項目**:
```bash
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^refs/remotes/origin/@@') || BASE_BRANCH="master"
```

---

### 🟡 共識 #4：二進位下載無 checksum 驗證

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| SEC, ARCH, OPS | 🟢高 (90-95%) | **P0 (SEC) / P2 (ARCH, OPS)** |

**問題**: PMD CLI (~35MB) 和 google-java-format (~5MB) 從 GitHub Releases 下載後直接使用，無 SHA-256 checksum 驗證。

**辯論紀錄**:
- **SEC** 堅持 P0 — 供應鏈安全是 2024-2026 年的最大威脅向量，google-java-format 使用 `--replace` 直接修改原始碼，被汙染的 jar 可注入後門
- **ARCH** 認為 P2 — HTTPS 已提供傳輸層安全，且攻擊面需要先入侵 GitHub Releases
- **OPS** 認為 P2 — 但同意企業環境有 TLS inspection proxy 的風險
- **共識**: **P1** — 折衷方案：下載後做 SHA-256 checksum 驗證

**行動項目**:
1. 維護已知版本的 SHA-256 hash map
2. 下載後執行 `sha256sum` 比對
3. 不匹配即刪除檔案並報錯

---

### 🟡 共識 #5：`pom.xml` 解析不支援 Maven properties

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| JAVA, ARCH, USER, OPS | 🟢高 (90-92%) | **P1-P2** |

**問題**: `resolve-pmd-version.sh` 用 `grep + sed` 解析 XML，無法處理 `${pom.version}` 佔位符、parent POM 繼承、`<pluginManagement>` 等常見模式。

**辯論紀錄**:
- **USER** 主張 P1 — 「我們團隊就是用 properties 定義版本的，這是標準做法」
- **JAVA** 認為 P2 — fallback 到預設版本是安全的，只是失去了版本對齊功能
- **ARCH** 建議長期方案用 `mvn help:evaluate`
- **共識**: **P2** — 短期偵測 `${}` 並嘗試從 `<properties>` 二次查找；長期改用 Maven evaluate

---

### 🟡 共識 #6：macOS Bash 3.2 不支援 `declare -A`

| 提出者 | 信心 | 優先度 |
|--------|------|--------|
| OPS, DX | 🟢高 (90-95%) | **P0 (OPS) / P2 (DX)** |

**問題**: `run-pmd.sh` 和 `check-suppressions.sh` 使用 `declare -A`（關聯陣列），macOS 預設 Bash 3.2 不支援。`check-suppressions.sh` 有版本檢查但 `run-pmd.sh` 沒有。

**辯論紀錄**:
- **OPS** 主張 P0 — macOS 是 Java 開發者的主要平台，且 macOS CI runner 也受影響
- **DX** 認為 P2 — `run-pmd.sh` 第一行用 `#!/usr/bin/env bash`，`brew install bash` 後 `/usr/local/bin/bash` 會被優先使用
- **共識**: **P1** — `run-pmd.sh` 必須加入 Bash 4+ 版本檢查，README 需明確標註 macOS 需求

---

## 第二部分：單方獨特觀點（僅由一位專家提出的高價值發現）

### 來自 JAVA：預設 ruleset 缺少 multithreading / performance / security

| 信心 | 優先度 |
|------|--------|
| 🟢高 (90%) | **P1** |

**發現**: 預設只啟用 `bestpractices`、`errorprone`、`codestyle` 三個 PMD category，遺漏了：
- `multithreading` — race condition、double-checked locking
- `performance` — String concatenation in loop
- `security` — hardcoded crypto key

**USER 反駁**: 規則越多噪音越大，應該提供精選 ruleset 而非全開
**JAVA 回應**: 同意應精選，但 multithreading 和 performance 幾乎沒有誤報

**最終判定**: **P1** — 加入 `multithreading` 和 `performance`，`security` 可選

---

### 來自 SEC：google-java-format `--replace` 攻擊鏈

| 信心 | 優先度 |
|------|--------|
| 🟢高 (90%) | **P1** |

**發現**: 汙染 jar → `--replace` 自動覆寫所有 Java 檔案 → 注入後門。這是整個工具鏈影響最大的攻擊面。

**ARCH 回應**: 同意這是 checksum 驗證的最強理由
**最終判定**: **P1** — 隨共識 #4 的 checksum 驗證一併解決

---

### 來自 ARCH：SKILL.md 嵌入大量 inline bash 無法被測試

| 信心 | 優先度 |
|------|--------|
| 🟢高 (88%) | **P1** |

**發現**: SKILL.md 中的模組偵測、filelist 產生、import 修復都是 inline bash，由 Claude 在 runtime 解釋執行，無法被 lint/test/版本控制 diff。

**DX 回應**: 同意，但 SKILL.md 本質上是 LLM 的 prompt，inline code 是常見模式
**ARCH 回應**: 正因如此更危險 — 出錯時無法用傳統手段 debug

**最終判定**: **P2** — v0.2.0 提取為獨立腳本（`detect-module.sh`、`generate-filelist.sh`、`fix-imports.sh`）

---

### 來自 USER：google-java-format 會重排 imports 順序

| 信心 | 優先度 |
|------|--------|
| 🟢高 (90%) | **P1** |

**發現**: `--fix-imports-only` 不僅移除 unused imports，還會按 Google style 重排順序。與 IntelliJ 預設排序不同，會產生大量 git diff 噪音。

**JAVA 回應**: 這確實是一個重要的副作用，但 google-java-format 的 `--fix-imports-only` 就是這樣設計的
**最終判定**: **P1** — 在文件中明確標註此行為，提供 `--skip-imports` 選項

---

### 來自 OPS：TOOLS_DIR 硬編碼無法透過環境變數覆寫

| 信心 | 優先度 |
|------|--------|
| 🟢高 (95%) | **P1** |

**發現**: 所有腳本 `TOOLS_DIR="$HOME/.claude/tools"` 硬編碼，CI 環境無法指定快取友善路徑。

**DX 回應**: 同意，這對企業環境也很重要（home 目錄可能在網路磁碟上）
**最終判定**: **P1** — 改為 `TOOLS_DIR="${CODE_GATE_TOOLS_DIR:-$HOME/.claude/tools}"`

---

### 來自 DX：`LINT_GATE_RESULT` marker 未隨 `code-gate` 重命名同步

| 信心 | 優先度 |
|------|--------|
| 🟢高 (97%) | **P1** |

**發現**: 目錄已從 `lint-gate` 改名為 `code-gate`，但 `---LINT_GATE_RESULT---` marker 未同步更新。

**ARCH 回應**: 這也應與協定版本號一起更新（改為 `---CODE_GATE_RESULT_V1---`）
**最終判定**: **P1** — 統一更名為 `---CODE_GATE_RESULT---` 或帶版本號

---

## 第三部分：正面共識（多位專家獨立肯定的設計）

| 設計 | 肯定者 | 評價 |
|------|--------|------|
| **Dual-channel 輸出協定** (stderr debug + stdout violations + JSON) | DX, JAVA, ARCH | 生產等級的 LLM 工具通訊設計，值得推廣 |
| **Phase 漸進式架構** (Phase 1 無需編譯 / Phase 2 可選) | ARCH, USER, OPS | 正確的 progressive disclosure，降低進入門檻 |
| **Auto-fix 邊界劃分** (3 safe fixes + 4 report-only) | JAVA, DX, USER | 安全性判斷正確，展現對 Java 語義的深入理解 |
| **增量模式預設** (git diff-based) | DX, USER, OPS | 直接解決「pre-commit 速度」痛點 |
| **PMD 版本對齊** (從 pom.xml 解析) | JAVA, OPS | 核心價值主張，解決 CI/local drift |
| **Bash 嚴格模式** (`set -euo pipefail`) | SEC, OPS | 安全基礎做對了 |
| **原子寫入** (先寫 `.tmp` 再 `mv`) | SEC | 正確的檔案操作模式 |

---

## 第四部分：優先行動方案

### P0 — 必須修復（阻擋使用）

| # | 項目 | 信心 | 投票 | 工作量估計 |
|---|------|------|------|-----------|
| 1 | PMD 7.x 偵測 + fail fast（短期）/ 版本分流（中期） | 🟢95% | 5/6 | 中 |
| 2 | `local first_run=false` 語法錯誤 | 🟢95% | 6/6 | 極小 |
| 3 | 硬編碼 `master` → 自動偵測預設分支 | 🟢96% | 4/6 | 小 |

### P1 — 重要（顯著影響體驗或安全）

| # | 項目 | 信心 | 投票 | 工作量估計 |
|---|------|------|------|-----------|
| 4 | 二進位下載加入 SHA-256 checksum 驗證 | 🟢92% | 3/6 | 小 |
| 5 | `LINT_GATE_RESULT` → `CODE_GATE_RESULT` 統一命名 | 🟢97% | 2/6 | 小 |
| 6 | `run-pmd.sh` 加入 Bash 4+ 版本檢查 | 🟢92% | 2/6 | 極小 |
| 7 | 預設 ruleset 加入 `multithreading` + `performance` | 🟢90% | 1/6 | 極小 |
| 8 | `TOOLS_DIR` 支援環境變數覆寫 | 🟢95% | 2/6 | 極小 |
| 9 | google-java-format import 重排副作用說明 + `--skip-imports` 選項 | 🟢90% | 1/6 | 小 |
| 10 | 下載失敗錯誤訊息改善（URL、原因、修復建議） | 🟢92% | 1/6 | 小 |
| 11 | GJF 版本條件選擇（Java 21+ → 2.x / Java 17-20 → 1.24.0） | 🟢90% | 1/6 | 小 |
| 12 | 狀態檔合併（env.sh + versions.txt → 單一來源） | 🟢90% | 1/6 | 中 |
| 13 | 提供 GitHub Actions workflow 範本 + 快取策略 | 🟢93% | 1/6 | 中 |

### P2 — 建議（改善品質但非阻擋）

| # | 項目 | 信心 | 投票 | 工作量估計 |
|---|------|------|------|-----------|
| 14 | SKILL.md inline bash 提取為獨立腳本 | 🟢88% | 1/6 | 大 |
| 15 | pom.xml 解析支援 Maven properties `${}` | 🟢90% | 4/6 | 中 |
| 16 | PMD cache key 加入 project root hash | 🟡75% | 1/6 | 小 |
| 17 | Exit code 語義統一（所有腳本） | 🟢90% | 1/6 | 中 |
| 18 | 暫存檔加入 `trap EXIT` 清理機制 | 🟢90% | 2/6 | 小 |
| 19 | Suppression guard grep pattern 加強 | 🟡80% | 1/6 | 小 |
| 20 | ArchUnit 測試發現模式擴充 | 🟡80% | 2/6 | 小 |
| 21 | CPD 行為透明化（說明全量掃描原因） | 🟢92% | 3/6 | 極小 |
| 22 | 腳本參數驗證（usage message） | 🟢91% | 1/6 | 小 |
| 23 | 並行執行鎖機制（flock） | 🟡70% | 1/6 | 小 |
| 24 | 手動安裝腳本 `install.sh` | 🟢95% | 2/6 | 中 |
| 25 | README 加入範例輸出 | 🟢90% | 2/6 | 小 |
| 26 | 輸出協定加入 `protocol_version` 欄位 | 🟡75% | 1/6 | 極小 |
| 27 | PMD 報告支援 SARIF/XML CI 格式 | 🟢90% | 1/6 | 中 |
| 28 | `rm -rf` 路徑防護 | 🟡65% | 1/6 | 小 |
| 29 | 版本白名單防止降級攻擊 | 🟡75% | 1/6 | 小 |
| 30 | 與 IntelliJ / SonarQube 定位說明 | 🟢90% | 1/6 | 極小 |

### P3 — 可選（長期改善）

| # | 項目 | 信心 | 投票 |
|---|------|------|------|
| 31 | Tool registry 抽象（支援 Checkstyle、SpotBugs） | 🟡80% | 1/6 |
| 32 | violation-fixes.md 結構化為 YAML + 貢獻指南 | 🟢88% | 1/6 |
| 33 | `src/test/java` 掃描支援 | 🟡70% | 2/6 |
| 34 | 多模組並行處理 | 🟢88% | 1/6 |
| 35 | plugin.json 補充 license/keywords/runtime | 🟡70% | 2/6 |
| 36 | SKILL.md 統一使用英文 | 🟡65% | 1/6 |
| 37 | Suppression allowlist 自動生成工具 | 🟢85% | 1/6 |

---

## 第五部分：建議的實施路線

### v0.1.1 — 緊急修補（預計 1-2 天）
- [ ] P0 #2: 修復 `local` 語法錯誤
- [ ] P0 #3: 自動偵測預設分支
- [ ] P0 #1 短期: PMD 7.x 偵測 + fail fast + 錯誤訊息
- [ ] P1 #5: `LINT_GATE_RESULT` → `CODE_GATE_RESULT`
- [ ] P1 #6: `run-pmd.sh` Bash 4+ 版本檢查

### v0.2.0 — 品質提升（預計 1-2 週）
- [ ] P0 #1 中期: PMD 7.x 完整支援（版本分流）
- [ ] P1 #4: SHA-256 checksum 驗證
- [ ] P1 #7: 擴充預設 ruleset
- [ ] P1 #8: `TOOLS_DIR` 環境變數
- [ ] P1 #9: import 重排說明 + skip 選項
- [ ] P1 #10: 錯誤訊息改善
- [ ] P1 #11: GJF 條件版本選擇
- [ ] P2 #15: pom.xml properties 支援
- [ ] P2 #18: trap 清理機制

### v0.3.0 — CI 整合（預計 2-4 週）
- [ ] P1 #13: GitHub Actions workflow 範本
- [ ] P1 #12: 狀態檔合併
- [ ] P2 #14: inline bash 提取為獨立腳本
- [ ] P2 #17: exit code 統一
- [ ] P2 #27: SARIF/XML 輸出格式

### v1.0.0 — 成熟期
- [ ] P3 #31: Tool registry 抽象
- [ ] P3 #32: violation-fixes.md 結構化
- [ ] P3 #34: 多模組並行

---

## 附錄：團隊辯論摘要

### 辯論 A：供應鏈安全的優先度

**SEC（強硬派）**: 「無 checksum = P0。google-java-format `--replace` 可以注入後門到原始碼。」

**ARCH（務實派）**: 「HTTPS 已夠用。真正的風險是 PMD 7 crash，不是 supply chain attack。P2。」

**OPS（折衷派）**: 「企業有 TLS inspection proxy。加 checksum 很便宜，何樂不為？P2 但 ROI 很高。」

**裁決**: **P1** — checksum 成本極低但安全收益顯著。SEC 的攻擊鏈分析（汙染 jar → `--replace` → 注入後門）具說服力。

---

### 辯論 B：預設 PMD 規則集寬度

**JAVA**: 「必須加 multithreading 和 performance。企業生產事故的主要來源就是這兩類。」

**USER**: 「規則越多噪音越大。首次掃描 200 個 violation 會讓新使用者放棄。」

**DX**: 「應該提供精選 ruleset 而非全開 category。Progressive disclosure。」

**裁決**: 加入 `multithreading`（低噪音高價值）和 `performance`（中噪音高價值），**不加** `design` 和 `documentation`（高噪音）。長期提供 `--level=strict|balanced|minimal`。

---

### 辯論 C：SKILL.md 中的 inline bash 是否應提取

**ARCH**: 「必須提取。inline bash 無法 lint、無法測試、出錯時無法 debug。」

**DX**: 「SKILL.md 本質是 LLM prompt，inline code 是正常模式。提取反而增加檔案數和認知負擔。」

**JAVA**: 「如果腳本穩定就不需要提取。但模組偵測和 filelist 產生這類邏輯確實容易出錯。」

**裁決**: **P2** — v0.2.0 提取高風險邏輯（模組偵測、filelist 產生），但簡單的一行指令保留在 SKILL.md。

---

### 辯論 D：是否支援 PMD 7.x vs 只用 6.x

**JAVA**: 「PMD 6 已停止維護超過 3 年。不支援 7.x 等於把大量現代專案排除在外。」

**OPS**: 「PMD 7 是生態系的方向。maven-pmd-plugin 最新版預設就是 PMD 7。」

**DX**: 「v0.1.x 先 fail fast 就好。完整支援 7.x 是 v0.2.0 的事。」

**裁決**: 分階段實施。v0.1.1 偵測 + fail fast；v0.2.0 完整支援。

---

## 附錄：信心程度定義

| 等級 | 範圍 | 含義 |
|------|------|------|
| 🟢高 | 90%+ | 基於實際程式碼分析、官方文件、或已驗證的事實 |
| 🟡中 | 60-89% | 基於合理推斷、經驗判斷、或部分驗證 |
| 🔴低 | <60% | 基於假設、未驗證的推測 |

---

*報告由 6 個 Claude Opus 4.6 agents 平行審查後彙整產出。每位 agent 獨立閱讀全部原始碼並可上網搜尋最新資訊。*
