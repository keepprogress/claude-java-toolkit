# code-gate 第二輪多方專家審查報告（v0.2.0）

> **日期**: 2026-03-25
> **專案**: claude-java-toolkit v0.2.0
> **審查範圍**: DX、環境配置、錯誤 UX、產品策略、軟體架構
> **模型**: Claude Opus 4.6 (1M context) × 5 agents, max thinking effort
> **語言**: 繁體中文

---

## 審查團隊

| 代號 | 角色 | 關注焦點 |
|------|------|----------|
| **Expert A** | DX 架構師 | 首次體驗、認知負擔、文件品質、feedback loop |
| **Expert B** | 環境與配置專家 | 跨平台、供應鏈安全、cache 管理、CI 整合 |
| **Expert C** | 錯誤解析與除錯 UX | 錯誤路徑分析、failure mode、recovery path |
| **Expert D** | 產品與可用性策略 | 使用者旅程、功能可發現性、漸進揭露、競品定位 |
| **Expert E** | 軟體架構與可攜性 | 模組化、SRP、介面契約、可擴充性、測試策略 |

---

## 第一部分：跨團隊交叉驗證矩陣

以下為 **多位專家獨立提出相同或高度相關的發現**，依共識強度排序：

### 5/5 共識（所有專家均獨立提出）

| 議題 | Expert A | Expert B | Expert C | Expert D | Expert E | 共識優先度 |
|------|----------|----------|----------|----------|----------|-----------|
| **`--include-tests` 模式 `-d` 檢查失效** | DX-07 | ENV-07 | ERR-02 | — | — | **P0** |
| **detect-env.sh 缺少 trap 清理** | DX-02 | ENV-05 | ERR-08 | — | — | **P1** |
| **md5sum macOS 不可用導致 cache 碰撞** | DX-07 | ENV-03 | ERR-11 | — | ARCH-08 | **P1** |

### 4/5 共識

| 議題 | 提出者 | 共識優先度 |
|------|--------|-----------|
| **二進位下載無 checksum 驗證** | B(ENV-01), C(間接), D(間接), E(間接) | **P0** |
| **SKILL.md 過長/inline bash 不可測試** | A(DX-01), D(PROD-02), E(ARCH-04) | **P1** |
| **手動安裝流程摩擦力過高** | A(DX-04), D(PROD-05) | **P0** |
| **錯誤訊息缺乏可操作修復指引** | A(DX-05), C(ERR-05/06), D(PROD-03) | **P1** |
| **JSON 輸出協定脆弱（手工拼接）** | C(ERR-01), E(ARCH-01) | **P1** |
| **無測試基礎設施** | E(ARCH-02), 全員間接依賴 | **P1** |

### 3/5 共識

| 議題 | 提出者 | 共識優先度 |
|------|--------|-----------|
| **缺少 `.gitattributes` CRLF 防護** | B(ENV-04), A(DX-07 間接) | **P1** |
| **resolve-pmd-version.sh 靜默降級** | C(ERR-09), B(ENV-10 間接) | **P2** |
| **Marketplace 描述未凸顯價值** | D(PROD-12) | **P1** |
| **缺少配置自訂機制** | D(PROD-10), E(ARCH-06 間接) | **P1** |
| **輸出協定無版本號** | E(ARCH-10), C(ERR-10 間接) | **P2** |

---

## 第二部分：統一發現列表（去重合併後 35 項）

### P0 — 功能性阻斷或安全風險（5 項）

| # | 標題 | 來源 | 信心 | 辯論紀錄摘要 |
|---|------|------|------|-------------|
| 1 | **`--include-tests` 模式完全不可用** — `_resolve_src_dir` 返回逗號分隔路徑，`-d` 檢查永遠失敗 | ENV-07, ERR-02 | **High** | 無爭議。PMD CLI 接受逗號分隔 `-d`，但 bash `[[ -d ]]` 不接受。修復成本極低（改為只驗第一段或逐一驗證）。 |
| 2 | **二進位下載無 SHA-256 checksum** — PMD ZIP + GJF JAR 從 GitHub 下載後直接使用 | ENV-01 | **High** | 反方：HTTPS 已提供傳輸層保護。正方：企業 TLS inspection proxy 打破此保護；GJF 以 `--replace` 直接覆寫原始碼，被汙染 = 任意代碼執行。PMD 已提供 GPG 簽名。共識：至少做 SHA-256 驗證。 |
| 3 | **手動安裝需 5 步手動 JSON 編輯** — 任何 typo 導致靜默失敗 | DX-04, PROD-05 | **High** | 反方：Marketplace 已夠簡單。正方：企業防火牆可能擋 Marketplace，方法二變唯一選項。共識：提供 `install.sh` 自動化腳本。 |
| 4 | **`unzip`/`jar xf` 失敗 + `set -e` 導致無 JSON 輸出** — 違反輸出協定 | ERR-01 | **High** | 無爭議。`set -e` 與「保證輸出 JSON」矛盾，需為可失敗指令加顯式捕捉。 |
| 5 | **首次體驗缺乏即時價值呈現** — 下載 40MB 後看到的第一個東西不是專案健康快照 | PROD-01 | **High** | 反方：下載是一次性成本。正方：首次印象決定留存率，Time to First Value 需 <60 秒。共識：首次預設 `--full --report-only` 模式。 |

### P1 — 高影響改善（14 項）

| # | 標題 | 來源 | 信心 | 辯論紀錄摘要 |
|---|------|------|------|-------------|
| 6 | **SKILL.md 超過 250 行** — 超出官方建議的 40-100 行 | DX-01, ARCH-04 | High | 反方：集中管理更方便。正方：Claude 的 context window 是有限資源，inline bash 不可測試。共識：瘦身至 80 行，邏輯移至 reference/ 或獨立腳本。 |
| 7 | **SKILL.md inline bash 提取為獨立腳本** — 模組偵測、filelist 產生、import 修復 | ARCH-04 | High | 與 #6 配合。共識：提取 detect-module.sh、generate-filelist.sh、fix-imports.sh。 |
| 8 | **detect-env.sh 缺少 trap 清理** — 下載中斷留下 `.tmp` 殘檔 | ENV-05, ERR-08 | High | 無爭議。run-pmd.sh 已有 trap 模式，detect-env.sh 遺漏。 |
| 9 | **md5sum macOS fallback** — cache key 退化為 "default" 造成跨專案碰撞 | ENV-03, ERR-11 | High | 共識：加入 `md5`（macOS）→ `shasum` → `cksum`（POSIX）fallback 鏈。 |
| 10 | **缺少 `.gitattributes`** — Windows CRLF 破壞 shell 腳本 | ENV-04 | High | 無爭議。零成本修復，一次設定永久防護。 |
| 11 | **JSON 輸出函式抽象** — 18 處手工字串拼接，脆弱且不一致 | ARCH-01 | High | 反方：引入 jq 太重。共識：純 bash helper function `_emit_result()`，不依賴外部工具。 |
| 12 | **建立 BATS 測試框架** — 4 個腳本零測試 | ARCH-02 | High | 反方：手動測試即可。正方：REVIEW-REPORT v1 就抓出 5 個 bug，說明手動不可靠。共識：先為 resolve-pmd-version.sh 和 JSON 輸出寫測試。 |
| 13 | **錯誤訊息加入分類與修復建議** — PMD 崩潰時只說 "exit code N" | ERR-05, ERR-06, DX-05 | Medium | 反方：Claude 會解釋。正方：確定性腳本 > 非確定性 LLM。共識：至少對已知 exit code 提供 hint。 |
| 14 | **首次執行增加 dry-run / preview 機制** — 直接下載 + 修改檔案缺乏信任建立 | DX-02 | High | 反方：Claude 有工具權限確認。正方：語義層預覽 > 指令層確認。共識：`detect-env.sh --check` 模式。 |
| 15 | **Windows Git Bash 相容性驗證** — README 宣稱支援但多處未驗證 | DX-07, ARCH-08 | Medium | 共識：修復已知問題（md5sum、mktemp），其餘等使用者回報。 |
| 16 | **versions cache 損壞時連鎖崩潰** — 空變數 → integer expression expected | ERR-03 | High | 無爭議。加入 cache 檔案完整性驗證。 |
| 17 | **Marketplace 元資料優化** — 當前描述未凸顯 AI auto-fix 差異化 | PROD-12 | High | 無爭議。改幾行字的 ROI 最高。 |
| 18 | **缺少配置自訂機制（.code-gate.yml）** — 無法禁用規則或調整 auto-fix 範圍 | PROD-10 | High | 反方：零配置是賣點。正方：遇到 false positive 就會被棄用。共識：零配置預設 + 漸進式 YAML 覆蓋。 |
| 19 | **check-suppressions.sh `cd` 失敗時無 JSON 輸出** | ERR-04 | High | 同 #4 的根因。 |

### P2 — 中度改善（12 項）

| # | 標題 | 來源 | 信心 |
|---|------|------|------|
| 20 | **Zip Slip 路徑穿越防護** | ENV-02 | High |
| 21 | **curl 未透傳 proxy / 無 `CODE_GATE_CURL_OPTS`** | ENV-08 | Medium |
| 22 | **`code-gate-env.sh` 未設 `chmod 600`** | ENV-09 | Medium |
| 23 | **resolve-pmd-version.sh 靜默降級到 6.55.0** | ERR-09 | Medium |
| 24 | **中英混雜 log 訊息** — SKILL.md 應統一英文 | DX-03, PROD-09 | High |
| 25 | **import reorder 副作用缺乏顯著警告** | DX-08 | High |
| 26 | **run-pmd.sh 違反 SRP** — PMD + CPD 同檔 | ARCH-03 | High |
| 27 | **腳本間共用函式重複定義** | ARCH-07 | High |
| 28 | **輸出協定加入 `protocol_version`** | ARCH-10 | High |
| 29 | **與 Claude Code 高耦合** — 腳本核心層應可獨立使用 | ARCH-11, PROD-06 | Medium |
| 30 | **缺少 GitHub Actions 整合範本** | ENV-12 | High |
| 31 | **並行執行無鎖機制** | ENV-06 | Medium |

### P3 — 長期打磨（4 項）

| # | 標題 | 來源 | 信心 |
|---|------|------|------|
| 32 | **缺乏結果持久化輸出** | DX-09, PROD-08 | Medium |
| 33 | **violation-fixes.md 結構化為 YAML** | ARCH-09 | Medium |
| 34 | **PMD cache 檔從未清理** | ENV-11 | Medium |
| 35 | **check-suppressions.sh 拆分 guard 與 allowlist** | ARCH-12 | Medium |

---

## 第三部分：辯論紀錄 — 關鍵分歧點

### 辯論 1：零配置 vs 可自訂

| 立場 | 支持者 | 論點 | 信心 |
|------|--------|------|------|
| **保持零配置** | Expert A (部分) | 零配置是核心賣點，config 增加認知負擔 | Medium |
| **加入 .code-gate.yml** | Expert D, E | false positive 是工具被棄用的首因；零配置為預設，YAML 為 opt-in 漸進揭露 | High |
| **結論** | 共識採納 D/E 立場 | 零配置 + 可選 YAML 不衝突，是漸進揭露的標準模式 | |

### 辯論 2：SKILL.md 語言統一

| 立場 | 支持者 | 論點 | 信心 |
|------|--------|------|------|
| **保持中文** | (無明確支持者) | 目標受眾是繁中開發者 | Low |
| **統一英文** | Expert A, D | SKILL.md 是給 Claude 讀的，Claude 英文最強；README 可保留中文 | High |
| **結論** | 共識：SKILL.md 英文，README 雙語 | 機器讀的用機器最強的語言，人讀的用目標受眾的語言 | |

### 辯論 3：auto-fix 預設行為

| 立場 | 支持者 | 論點 | 信心 |
|------|--------|------|------|
| **保持 auto-fix 預設** | Expert A (DX-12 結論) | auto-fix 是最強賣點 / wow factor | Medium |
| **首次改為 report-only** | Expert D | 安全預設建立信任 | Medium |
| **結論** | 妥協方案 | 保持 auto-fix 預設，但首次執行前增加確認步驟 | |

### 辯論 4：Tool Registry 抽象是否過度工程

| 立場 | 支持者 | 論點 | 信心 |
|------|--------|------|------|
| **YAGNI — 等需要時再說** | Expert A (間接) | 目前 4 個工具還能手動管理 | Medium |
| **建立最小抽象** | Expert E | 已有 18 處 JSON 拼接 + 3 處重複 log()，「已經需要」非「可能需要」 | High |
| **結論** | 先建立 `lib/` 共用層，Tool Registry 介面延後 | 消除重複是確定收益，registry 是未來收益 | |

### 辯論 5：Checksum 驗證的必要性

| 立場 | 支持者 | 論點 | 信心 |
|------|--------|------|------|
| **HTTPS 已夠安全** | (Devil's advocate) | GitHub Releases 被入侵機率極低 | Low |
| **必須加 SHA-256** | Expert B, C | 企業 TLS inspection proxy 打破傳輸層保護；GJF `--replace` = 任意代碼執行路徑 | High |
| **結論** | 實施 checksum + `CODE_GATE_SKIP_CHECKSUM` escape hatch | 成本極低（~20 行），風險消除效果顯著 | |

---

## 第四部分：建議實施順序

### Sprint 1：Critical Fixes（1 週）

| # | 項目 | 工作量 | 來源 |
|---|------|--------|------|
| 1 | 修復 `--include-tests` `-d` 檢查 | 極小 | P0 #1 |
| 2 | `unzip`/`cd` 失敗的顯式錯誤捕捉 | 小 | P0 #4, P1 #19 |
| 3 | 新增 `.gitattributes` | 極小 | P1 #10 |
| 4 | `detect-env.sh` 加入 trap 清理 | 小 | P1 #8 |
| 5 | `md5sum` 跨平台 fallback | 小 | P1 #9 |
| 6 | versions cache 完整性驗證 | 小 | P1 #16 |

### Sprint 2：Foundation（1-2 週）

| # | 項目 | 工作量 | 來源 |
|---|------|--------|------|
| 7 | 建立 `scripts/lib/common.sh` + `output.sh` | 中 | P1 #11, P2 #27 |
| 8 | SHA-256 checksum 驗證 | 中 | P0 #2 |
| 9 | BATS 測試框架 + 核心測試 | 中 | P1 #12 |
| 10 | Marketplace 描述優化 | 極小 | P1 #17 |
| 11 | Zip Slip 防護 | 小 | P2 #20 |
| 12 | curl timeout 一致化 | 極小 | ENV-10 |

### Sprint 3：DX & Architecture（2-3 週）

| # | 項目 | 工作量 | 來源 |
|---|------|--------|------|
| 13 | SKILL.md 瘦身 + inline bash 提取 | 中 | P1 #6, #7 |
| 14 | 首次體驗流程重設計 | 中 | P0 #5, P1 #14 |
| 15 | 錯誤訊息分類 + 修復建議 | 中 | P1 #13 |
| 16 | `install.sh` 自動化安裝 | 中 | P0 #3 |
| 17 | run-pmd.sh 拆分 PMD/CPD | 小 | P2 #26 |
| 18 | `.code-gate.yml` 配置機制 | 中 | P1 #18 |

### Sprint 4：Polish & Extend（2-3 週）

| # | 項目 | 工作量 | 來源 |
|---|------|--------|------|
| 19 | SKILL.md 語言統一（英文） | 小 | P2 #24 |
| 20 | import reorder 警告強化 | 小 | P2 #25 |
| 21 | `protocol_version` 加入 JSON | 極小 | P2 #28 |
| 22 | 腳本核心層與 Claude 解耦 | 中 | P2 #29 |
| 23 | GitHub Actions 整合範本 | 中 | P2 #30 |
| 24 | PMD 版本降級可見性 | 小 | P2 #23 |

---

## 第五部分：正面觀察

以下設計獲得多位專家一致肯定：

| 設計 | 肯定者 | 評價 |
|------|--------|------|
| **原子寫入模式** (`.tmp` + `mv`) | B, C | 防止不完整檔案被使用 |
| **PMD 6/7 雙版本分流** | A, B, E | 完整處理 CLI 語法、URL、exit code 差異 |
| **`set -euo pipefail` 全腳本** | B, C | 正確的防禦性程式設計 |
| **CI PMD 版本自動對齊** | D, E | 消除本地 / CI 不一致的根因 |
| **結構化 JSON 輸出協定** | A, E | 雖有改善空間但方向正確 |
| **`CODE_GATE_TOOLS_DIR` 可覆寫** | B | 前次審查建議已落實 |
| **版本格式 regex 驗證** | B | 防止路徑穿越 / 注入 |
| **增量掃描模式** | D | 大型專案的 key enabler |
| **Suppression allowlist** | D | 遺留專案導入的關鍵機制 |

---

## 第六部分：與 v1 審查報告對比

| v1 報告項目 | v2 狀態 | 說明 |
|------------|---------|------|
| #1 PMD 7.x 不相容 | **已修復** (e5a05b5) | PMD 6/7 雙版本完整支援 |
| #2 local bug | **已修復** (b1a382a) | |
| #3 master 硬編碼 | **已修復** (e5a05b5) | 改用 `git symbolic-ref` |
| #4 checksum 缺失 | **未修復** → 本報告 P0 #2 | 優先度提升 |
| #5 marker 重命名 | **已修復** (e5a05b5) | |
| #13 CI 整合範本 | **未修復** → 本報告 P2 #30 | |
| #26 協定版本號 | **未修復** → 本報告 P2 #28 | |
| #31 Tool Registry | **未修復** → 本報告 P2 ARCH-06 | 降為長期目標 |

---

## 引用來源

### Expert A (DX)
- [Skill authoring best practices - Claude API Docs](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [ESLint CLI Reference](https://eslint.org/docs/latest/use/command-line-interface)
- [Oxlint Automatic Fixes](https://oxc.rs/docs/guide/usage/linter/automatic-fixes)
- [Error-Message Guidelines - NN/g](https://www.nngroup.com/articles/error-message-guidelines/)
- [Feedback Loops in DX](https://ee-handbook.io/feedback-loops/developer-experience/)

### Expert B (Environment)
- [Signed Releases | PMD](https://docs.pmd-code.org/latest/pmd_userdocs_signed_releases.html)
- [Zip Slip Vulnerability | Snyk](https://security.snyk.io/research/zip-slip-vulnerability)
- [Cross-platform scripting - Azure Pipelines](https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/cross-platform-scripting)
- [GitHub - pmd/pmd-github-action](https://github.com/pmd/pmd-github-action)

### Expert C (Error UX)
- [Rust Compiler Diagnostics Guide](https://rustc-dev-guide.rust-lang.org/diagnostics.html)
- [Elm Error Messages Style Discussion](https://discourse.elm-lang.org/t/error-messages-style/7828)
- [UX Patterns for CLI Tools](https://www.lucasfcosta.com/blog/ux-patterns-cli-tools)
- [3 Bash Error-Handling Patterns](https://www.howtogeek.com/bash-error-handling-patterns-i-use-in-every-script/)

### Expert D (Product)
- [Biome: The ESLint and Prettier Alternative](https://biomejs.dev/)
- [SonarQube Cloud Features](https://www.sonarsource.com/products/sonarqube/cloud/features/)
- [Best Claude Code Plugins (2026)](https://buildtolaunch.substack.com/p/best-claude-code-plugins-tested-review)
- [Progressive Disclosure - NN/g](https://www.nngroup.com/articles/progressive-disclosure/)
- [Java Code Quality Tools - DZone](https://dzone.com/articles/java-code-quality-tools-recommended-by-developers)

### Expert E (Architecture)
- [BATS Core - Writing Tests](https://bats-core.readthedocs.io/en/stable/writing-tests.html)
- [Command Line Interface Guidelines (clig.dev)](https://clig.dev/)
- [Unix Philosophy - CUPID](https://cupid.dev/properties/unix-philosophy/)
- [ESLint Plugin Migration](https://eslint.org/docs/latest/extend/plugin-migration-flat-config)
- [Claude Code Extensibility Guide](https://happysathya.github.io/claude-code-extensibility-guide.html)

---

*報告由 5 位 Claude Opus 4.6 專家獨立審查後合成。每位專家均進行了完整程式碼閱讀與網路資料佐證。*
