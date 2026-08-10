# 研究: 接國泰證券 (台股) 與 Bitget

Branch: `research/tw-broker-bitget-integration`
日期: 2026-08-10
前提: 只在 local 用, 不回貢獻上游 (we-promise/sure)

---

## 0. 結論 (TL;DR)

| 項目 | 結論 | 成本 |
| --- | --- | --- |
| 國泰證券 | 沒有個人可用的 REST API. 走「集保 e 存摺匯出 PDF -> PdfImport」或手動 CSV -> TradeImport | 0 行新 provider 程式; 需補台股行情 3 行 |
| Bitget | 有完整 read-only REST API (v3 UTA / v2 classic), 完全對得上現有 Kraken provider 骨架 | 抄 Kraken, 約 1.5k 行, 其中只有 ~130 行碰到上游檔案 |
| 不被上游蓋掉 | 用 `fork-main` 長期分支 + rebase, 並把碰上游的 7 個檔案改成「一行註冊」形式 | 每次 rebase 衝突面從 7 檔縮到 2 檔 |

---

## 1. 國泰證券 (台股)

### 1.1 有沒有 API

沒有. 查證結果:

- **國泰綜合證券 (cathaysec.com.tw)** 對個人只提供 GUI 下單工具: 新樹精靈 AP (Windows 桌機)、隨身證券 App、網頁下單。官網沒有任何開發者 / API 專區。
- **國泰期貨** 有「大戶下單 API」, 但只涵蓋期貨/選擇權, 不含台股現股, 且需向營業員個別申請。
- **CaaS (caas.cathayholdings.com)** 是國泰金控的 B2B 生態圈平台, 申請對象是「企業帳號」, 個人拿不到。
- **國泰世華銀行** 走的是台灣 Open Banking, 但第三方存取要先到財金公司登記成 TSP 業者, 個人不適用。

補充: 台股有 Python API 的券商只有 **永豐 (Shioaji)**、**群益 (Capital)**、**富邦 (neo)**、少數幾家。這些 API 只能讀「該券商自家帳戶」, 所以除非你把股票轉倉過去, 否則對國泰帳戶沒幫助。

### 1.2 可行的三條路 (依推薦順序)

**A. 集保 e 存摺 (集保 e 手掌握) 匯出 PDF -> `PdfImport`  <-- 推薦**

- TDCC 官方 App, 一個帳號涵蓋你所有券商 (國泰 + 其他), 不只國泰。
- 路徑: 我的資產 > 證券資產 > 查看證券庫存分佈 > 證券存摺 > 選帳戶 > 交易明細 > 匯出明細。
- 匯出 PDF 含三塊: 存摺封面 / 庫存 / 交易明細。
- Sure 已經有 `app/models/pdf_import.rb`, 用 `Provider::Registry.preferred_llm_provider` (Anthropic 或 OpenAI) 抽表格。
- **零上游改動**。缺點: 手動、每月一次、要付 LLM token。

**B. 國泰證券電子對帳單 / 網頁下載 CSV -> `TradeImport`**

- 國泰網頁的「交割明細 / 庫存查詢」可以另存。整理成 CSV 後走既有 `TradeImport` (欄位: date, ticker, qty, price, currency, exchange_operating_mic)。
- **零上游改動**, 也不用 LLM。缺點: 純手動整理。

**C. 自己爬國泰網頁 (不建議)**

- 需要登入 + 憑證 + OTP, 網站改版就壞, 而且踩使用條款。真要做就寫成獨立的 local script 產 CSV 餵路徑 B, 不要塞進 Rails app。

### 1.3 台股行情的真實缺口

不管走哪條路, **台股價格抓不到**, 這是要動的地方:

- `config/exchanges.yml:253` 只有 `XTAI` (台灣證交所), **沒有 `ROCO`** (櫃買中心 TPEx)。
- `app/models/provider/yahoo_finance.rb:569` 的 `EXCHANGE_CONFIG` 只有 `XNSE` / `XBOM` / `XBOG`, **沒有 XTAI**。所以 `2330` 不會被轉成 Yahoo 要的 `2330.TW`, 價格會抓空。

修法 (共 3-4 行):

```ruby
# app/models/provider/yahoo_finance.rb EXCHANGE_CONFIG
"XTAI" => { yahoo_suffix: ".TW",  default_currency: "TWD" },
"ROCO" => { yahoo_suffix: ".TWO", default_currency: "TWD" },
```

```yaml
# config/exchanges.yml
ROCO:
  name: Taipei Exchange
  country: TW
```

這兩個檔案上游動得少, 衝突風險低, 而且這是真的 bug 等級的缺漏 — 唯一值得回貢獻上游的部分。

### 1.4 建議做法

不要為國泰寫 provider。寫一個 local-only 的匯入 preset 就好:

1. 先補上面的台股行情 3 行。
2. 用集保 e 存摺 PDF 走 `PdfImport`, 或整理 CSV 走 `TradeImport`。
3. 若嫌煩, 之後再寫一支 `lib/tasks/fork/tdcc_import.rake` 把匯出的 PDF/CSV 正規化成 Sure 的 import CSV 格式。這支 rake 檔上游永遠不會有, 不會衝突。

---

## 2. Bitget

### 2.1 API 事實 (已查證)

- Base URL: `https://api.bitget.com`
- 兩代並存: **v3 = UTA (統一帳戶)**, **v2 = classic**。看你的帳號有沒有升級 UTA, 兩邊 auth 完全一樣。
- 認證: API Key + Secret + **Passphrase** (三件套, 比 Kraken 多一個 passphrase)。建立 key 時可只給 **read-only** 權限 — 一定要這樣設。
- Headers:
  - `ACCESS-KEY`
  - `ACCESS-SIGN`
  - `ACCESS-PASSPHRASE`
  - `ACCESS-TIMESTAMP` (毫秒)
  - `locale: en-US`
  - `Content-Type: application/json`
- 簽章: `Base64(HMAC-SHA256(secret, timestamp + UPPER(method) + requestPath + queryString + body))`
  - queryString 含開頭 `?`, 空的話整段省略。
  - **GET 的 query params 必須依 key 字母升冪排序** (這點跟 Kraken 不同, 最容易寫錯)。
  - POST 的 body 是 JSON 字串, 且簽章用的字串必須跟實際送出的 body 位元組完全一致。

### 2.1.1 阻擋項: 本機 instance 的 API 金鑰目前是明文儲存

在做 Bitget 之前必須先決定怎麼處理。查證結果:

- `/home/halcyon/docker-apps/sure/.env` 的三把金鑰 (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT`) 是**註解掉的**, 沒有進到容器。
- `app/models/concerns/encryptable.rb` 的 `encryption_ready?` 用的是 `ActiveRecordEncryptionConfig.explicitly_configured?`。它是 false, 所以 `KrakenItem`/`BitgetItem` 那組 `if encryption_ready?` 包住的 `encrypts` 宣告**整組被跳過**, 欄位直接以明文寫進 Postgres。
- 注意 `config/initializers/active_record_encryption.rb:23-37`: self-hosted 沒給 env 時會從 `SECRET_KEY_BASE` 自動衍生金鑰。所以 AR 這一側其實有設定, 但 model 這一側因為 gate 在 `explicitly_configured?` 而不會加密。兩者不一致, 容易誤判成「已經有加密」。

也就是說 Bitget 的 `api_key` / `api_secret` / `passphrase` 現況下會是明文。

**要打開加密的代價**: `config/application.rb` 沒有設 `support_unencrypted_data`, 所以一旦補上 env 金鑰, 既有的 3 筆 `PlaidItem` 明文 token 會變成無法解密, 那 3 條 Plaid 連線要重接。

**建議**: 先 `bin/rails db:encryption:init` 產金鑰、填進 `.env` 取消註解、重接 3 條 Plaid, 再做 Bitget。這樣 Bitget 金鑰從第一天就是加密的。若不想動 Plaid, 至少要清楚知道交易所金鑰是明文落地 —— 那把 key 務必只開 read 權限。

需要的 read-only endpoints:

| 用途 | Endpoint | 備註 |
| --- | --- | --- |
| 帳戶資產 (含 USD 估值) | `GET /api/v3/account/assets` | 對應 Kraken `BalanceEx` |
| 資金流水 | `GET /api/v3/account/financial-records` | 分頁: `cursor`, `startTime`, `endTime`, `limit` (max 100) |
| 成交明細 | `GET /api/v3/trade/fills` | rate limit 20 req/s per UID; 需 UTA trade(read) 權限 |
| 歷史委託 | `GET /api/v3/trade/history-orders` | 通常不需要, fills 就夠 |

分頁一律: 用上一頁最小 id 當 `cursor`, 時間戳是毫秒。

### 2.2 對映到 Sure 的骨架

Kraken 是最新、最乾淨的樣板 (PR #1759, commit `be598ae`)。整包 40 個檔案 / ~2900 行, 逐一對映:

```
app/models/provider/bitget.rb                  <- provider/kraken.rb  (HTTParty + 簽章 + 錯誤分類)
app/models/provider/bitget_adapter.rb          <- provider/kraken_adapter.rb
app/models/bitget_item.rb                      <- kraken_item.rb        (加密存 key/secret/passphrase)
app/models/bitget_item/importer.rb             <- kraken_item/importer.rb
app/models/bitget_item/syncer.rb               <- kraken_item/syncer.rb
app/models/bitget_item/provided.rb
app/models/bitget_item/unlinking.rb
app/models/bitget_item/sync_complete_event.rb
app/models/bitget_account.rb                   <- kraken_account.rb
app/models/bitget_account/asset_normalizer.rb  <- Bitget 的 coin 代號比 Kraken 乾淨 (BTC 就是 BTC,
                                                  不是 XXBT), 這支大概可以整個砍掉
app/models/bitget_account/holdings_processor.rb
app/models/bitget_account/processor.rb
app/models/bitget_account/security_resolver.rb
app/models/bitget_account/usd_converter.rb
app/models/family/bitget_connectable.rb
app/controllers/bitget_items_controller.rb     <- kraken_items_controller.rb (241 行)
app/views/bitget_items/*.html.erb              (3 個 view)
app/views/settings/providers/_bitget_panel.html.erb
db/migrate/*_create_bitget_items_and_accounts.rb
config/locales/views/bitget_items/{en,zh-TW}.yml
```

跟 Kraken 的實作差異只有四點:

1. 多一個 `passphrase` 欄位 (migration + form + 加密屬性)。
2. 簽章字串不同 (見 2.1), 且 GET query 要排序。
3. 錯誤分類: Bitget 用回應 body 的 `code` 欄位 (`"00000"` 為成功), 不是 Kraken 的 `error` 陣列。
4. `usd_converter` 可以直接吃 `/account/assets` 回的 USD 估值, 不用另外打 ticker。

### 2.3 碰到上游的地方 (衝突面)

Kraken 那包只有這 7 個上游檔案被改, 加起來約 130 行:

| 檔案 | 改動 | 上游 churn |
| --- | --- | --- |
| `app/models/provider/metadata.rb:15` | +1 行 REGISTRY entry | 高 (每個新 provider 都改) |
| `app/models/provider_connection_status.rb:13` | +1 行 | 高 |
| `app/models/family.rb:4` | include 一個 concern (單行 include 列表) | **極高, 必衝突** |
| `app/models/family/financial_data_reset.rb:50` | +1 行 | 中 |
| `app/models/account.rb:373` | +1 個 `create_from_*` 方法 | 中 |
| `app/helpers/settings_helper.rb:93` | +1 個 `when` 分支 | 中 |
| `app/controllers/settings/providers_controller.rb` | 5 處 (+6 行) | 高 |
| `app/controllers/accounts_controller.rb:31,310` | 2 處 | 高 |
| `app/views/accounts/index.html.erb:13` | 那條超長 `@x_items.empty? && ...` 條件 | **極高, 必衝突** |
| `config/routes.rb:115` | +15 行 resources block | 中 |

注意 `Provider::Factory.register("KrakenAccount", self)` 是 provider 自己註冊的, factory.rb 不用改 — 上游已經留了這個 hook。

---

## 3. 不被上游蓋掉的策略

### 3.1 分支模型

```
origin/main  (we-promise/sure)      上游, 只讀
  |
  +-- fork-main                     你的長期分支 = upstream + 你的 patch
        |
        +-- feature/bitget          做完 merge 進 fork-main
        +-- feature/tw-import
```

更新流程 (每次上游有新版):

```bash
git fetch origin
git checkout fork-main
git rebase origin/main          # rebase 不是 merge: 你的 patch 永遠疊在最上面
# 解衝突 (預期只在下面 3.2 講的那幾個檔案)
bin/rails test
git push --force-with-lease fork
```

用 `rebase` 而不是 `merge` 的理由: 你的改動永遠是一疊乾淨的、可辨識的 commit 疊在 upstream HEAD 上。衝突每次都在同樣幾行, 解過一次之後 `git rerere` 會自動重放。

**一定要開 rerere:**

```bash
git config rerere.enabled true
git config rerere.autoupdate true
```

這一步是整個策略裡 CP 值最高的 — 同樣的 `accounts/index.html.erb` 那行衝突, 解一次之後永遠自動解。

### 3.2 把衝突面壓到最小

原則: **新增檔案不會衝突, 修改上游檔案才會**。所以能移到新檔案的就移。

可以完全消掉衝突的 (改成新檔案 + initializer):

- `provider/metadata.rb` 與 `provider_connection_status.rb`: 寫一支 `config/initializers/fork_providers.rb`, 在裡面用 `Provider::Metadata::REGISTRY` / `ProviderConnectionStatus` 的常數做 runtime merge, 而不是編輯原檔。這兩個常數目前是 `.freeze`, 所以要嘛改成可注入 (動 1 行, 但那 1 行永遠不衝突), 要嘛 `remove_const` + 重設 (醜但零衝突)。
- `family.rb` 的 include: 上游那行是「一行塞所有 concern」, 必衝突。改成在 initializer 裡 `Family.include(Family::BitgetConnectable)` — 完全不碰 family.rb。
- `account.rb` 的 `create_from_bitget_account`: 放進 `BitgetAccount` 自己, 或用 concern 從 initializer 注入。
- `routes.rb`: Rails 支援 `config/routes/*.rb` 分檔。把 fork 專屬路由放 `config/routes/fork.rb`, 主檔只需一行 `draw(:fork)` (上游那行永遠不變 -> 不衝突)。

無法完全消掉、只能認了的 (剩 2 個):

- `app/views/accounts/index.html.erb` 那條超長 empty 條件 — 這是上游的設計缺陷。交給 rerere。
- `app/controllers/settings/providers_controller.rb` 的 5 處 — 可以部分抽成 helper, 但不值得, 也交給 rerere。

做完之後衝突面: **7 個檔案 -> 2 個檔案**, 而且那 2 個 rerere 會自動解。

### 3.3 其他保命措施

- **`db/schema.rb` 永遠會衝突。** 解法: 衝突時直接 `git checkout --theirs db/schema.rb` 取上游版, 然後 `bin/rails db:migrate` 重新產生。不要手動解 schema.rb。
- **migration timestamp 用未來日期** (例如 `20991231_`), 讓你的 migration 永遠排在上游後面, 避免 schema 版本號來回跳。
- **不要動 locale 的 en.yml。** 新 key 放 `config/locales/views/bitget_items/en.yml` (新檔, 不衝突)。避免碰 `config/locales/views/settings/en.yml` — 若非碰不可, 加在檔案最尾端 (衝突機率最低)。
- **每個 fork commit 加固定前綴** `fork:`, 方便 `git log --grep="^fork:"` 一眼看出你疊了什麼。
- **fork 專屬文件/腳本一律放 `docs/fork/` 和 `lib/tasks/fork/`** — 上游不會有這兩個目錄, 永遠不衝突。

---

## 4. 建議執行順序

1. 台股行情 3 行 (`yahoo_finance.rb` + `exchanges.yml`) — 30 分鐘, 立刻能查台股價格。
2. 設定 fork 分支模型 + `rerere` — 15 分鐘。
3. 集保 e 存摺 PDF 走 `PdfImport` 試一次, 看 LLM 抽得準不準 — 1 小時。
4. Bitget provider: 照 Kraken 抄 — 約 1 到 2 天。
5. 做 3.2 的衝突面壓縮 (initializer 化) — 半天, 但可以等 Bitget 做完再做。

---

## 參考來源

- [國泰綜合證券 - 新樹精靈 AP](https://www.cathaysec.com.tw/cathaysec/CustomerService/Tools/TradingAP.aspx)
- [國泰綜合證券 - 數位金融](https://www.cathaysec.com.tw/cathaysec/ESG/digitalFinance.aspx)
- [CaaS 國泰生態圈服務平台 - 開發者中心](https://caas.cathayholdings.com/developerCenter/apiGuide)
- [永豐金證券 Shioaji Python API](https://ai.sinotrade.com.tw/python/Main/index.aspx)
- [富邦新一代 API](https://www.fbs.com.tw/TradeAPI/en/)
- [集保 e 手掌握 (集保 e 存摺)](https://epassbook.tdcc.com.tw/zh/c2.aspx)
- [Fugle 客服 - 如何用集保 e 手掌握匯出庫存明細](https://support.fugle.tw/trading/account-investment/10684/)
- [開放銀行 - 開放 API 平台 TSP 業者資訊揭露專區](https://www.fisc.com.tw/TSP/Vendor/ba3b9d36-f8be-4033-b13b-03a93de8bed0)
- [Bitget UTA API - Quick Start / Signature](https://www.bitget.com/api-doc/uta/guide)
- [Bitget UTA API - Get Financial Records](https://www.bitget.com/api-doc/uta/account/Get-Financial-Records)
- [Bitget UTA API - Get Order Fills](https://www.bitget.com/api-doc/uta/trade/Get-Order-Fills)
- [Bitget 官方 Python SDK](https://github.com/bitgetlimited/v3-bitget-api-sdk)
