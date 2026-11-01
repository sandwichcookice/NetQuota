# NetQuota

Mac 選單列網路流量監測工具。宿舍網路一天（上傳＋下載合計）超過 12GB 會被鎖卡，NetQuota 即時顯示今日用量、剩餘額度、峰值速率、各程式用量，並在接近上限前通知。

## 安裝與執行

本專案只提供原始碼，不提供編譯好的 App，請自行打包：

```bash
git clone https://github.com/sandwichcookice/NetQuota.git
cd NetQuota
scripts/build-app.sh --bundle-id com.example.NetQuota             # 產生 build/NetQuota.app
scripts/build-app.sh --bundle-id com.example.NetQuota --install   # 另外複製到 /Applications 並啟動
swift test                                                        # 單元測試
```

`--bundle-id` 是必填的，請換成你自己的反向網域 ID（例如 `io.github.<你的帳號>.NetQuota`）。之後每次打包都要用同一個 ID，系統才會沿用定位與通知權限、讀到同一份設定。不想每次輸入的話，可以在 `~/.zshrc` 加上：

```bash
export NETQUOTA_BUNDLE_ID=com.example.NetQuota
```

App 的版本號會自動取自最近的 git tag（例如 `v1.1` → 1.1），下載 zip 等沒有 git 資訊的原始碼會顯示 0.0。

需求：macOS 15 以上、Xcode（Swift 6）。不需要 root 權限，也沒有第三方依賴。

打包時用 ad-hoc 簽章（不需要 Apple 開發者帳號），在自己的電腦上編譯就能直接執行，不會被 Gatekeeper 擋下。

第一次啟動會詢問通知權限，請按「允許」。想開機自動執行，先用 `--install` 裝到「應用程式」，再到 設定 → 系統 → 登入時自動啟動。

### 找不到選單列圖示？

選單列項目太多時，新圖示會被瀏海或 App 選單擋住。可以：

- 再次打開 NetQuota.app（Spotlight／Finder），會直接開啟儀表板。
- 到 系統設定 → 選單列，把不需要的項目關掉。
- 在 NetQuota 設定裡把選單列改成「百分比」，可以縮短寬度。

## 功能

- **依網路分開計算**：用路由器的硬體位址分辨網路（不需權限），有定位權限時顯示 Wi-Fi 名稱。每個網路可各自設定每日上限（例如宿舍 12GB、另一個網路 16GB），沒設上限的只記錄。選單列、圓環、預測、通知都針對目前所在的網路；面板會列出今天其他網路的用量與全部合計。

- **選單列**：今日已用／上限（或剩餘、百分比），可選擇加上即時速率。圖示會隨用量變化（70%、90%、100%）。
- **面板**：用量圓環、上傳／下載、剩餘、即時速率曲線、今日峰值、用量預測、今日前 5 名程式。
- **儀表板**
  - 今日：累積用量曲線（含上限線與預測虛線）、每 15 分鐘用量。
  - 歷史：7 天／30 天／90 天／1 年，可依日／週／月彙總，標出超過額度的日子。
  - 程式：今日／昨日／7 天／30 天／全部的程式排行。
  - 設定：額度、GB／GiB、每日歸零時間、手動校正、通知、選單列樣式、開機啟動、CSV 匯出。
- **通知**：有上限的網路用量達 70%／90%／100%（各網路分開）；預測目前網路今天會超標（已用 30% 以上才提醒）；單一程式短時間大量使用（預設 10 分鐘內 1GB）。
- **三種風格**（設定 → 外觀，或面板底部的「風格」選單）：
  - **預設**：原本的系統樣式。系統支援時（macOS 26 且沒開「減少透明度」）自動照 Apple〈Adopting Liquid Glass〉的規範套用 Liquid Glass：系統玻璃分頁、標題列右側的玻璃狀態膠囊、玻璃按鈕，內容卡片保持一般背景；不支援時維持原樣。
  - **Glass**：透明玻璃面板外觀——視窗後方模糊透出、卡片／圖表／分頁切換／狀態列都是 Clear Liquid Glass（需要 macOS 26，舊系統退回毛玻璃）。
  - **Hack**：黑底網格、數位雨、掃描光帶、雷達用量環、數字解碼、標題故障特效、開機畫面、切頁雜訊；分頁（⌘1–⌘4）放在標題列那一行。系統開啟「減少動態效果」時自動停用動畫。
- **一鍵更新**（設定 → 更新）：每天檢查原始碼 repo 有沒有新的版本 tag，有就通知（修 bug 的 `vX.Y.Z` 會標成「修正版」）。按「更新」會在原始碼資料夾抓取新版本、重新編譯、安裝並自動重新啟動；任何一步失敗都保留目前的版本，原始碼資料夾有尚未 commit 的修改時不會更新。需要用 `git clone` 下載原始碼並以 `scripts/build-app.sh` 打包，過程紀錄在 `~/Library/Application Support/NetQuota/update.log`。
- **CSV 匯出**：每日摘要、各程式每日用量（UTF-8 含 BOM，Excel 可直接開啟）。

## 運作方式

| 資料 | 來源 |
|---|---|
| 總用量 | `sysctl NET_RT_IFLIST2` 的 64-bit 介面計數器，只算實體介面 `en*`（排除 loopback、VPN `utun`、AirDrop `awdl` 等，避免重複計算） |
| 各程式用量 | 長駐 `nettop -P -d -t external`（透過 `script` 提供 pty，避免輸出被緩衝）。XPC 服務（例如 WebKit Networking）歸到負責的 App，Chrome Helper 等歸到外層 .app |
| App 關閉期間 | 每分鐘記錄計數器快照；重新啟動時補回差額，依時間比例分配到各天（這段期間無法區分程式） |

- 每日額度以**介面總量**為準；各程式加總與總量可能略有差異。
- 預設 12GB = 12×10⁹ bytes（比 GiB 保守）。
- 預測：有 3 天以上歷史時，接下來 30 分鐘用最近的速度，之後每小時用過去 14 天同時段的平均用量；資料不足時用最近 30 分鐘的速度直線延伸。今日頁會標示用的是哪種方法。
- 第一次安裝當天，安裝前用掉的流量無法得知，可以在 設定 → 網路 裡用宿舍系統的數字「校正今日已用」。
- 讀 Wi-Fi 名稱需要定位權限（只讀名稱，不記錄位置）。App 是 ad-hoc 簽章，重新打包後系統可能會再問一次權限。

## 資料保存與機器學習

資料存放在 `~/Library/Application Support/NetQuota/netquota.sqlite`（SQLite），**永久保留、不會自動刪除**：

| 資料表 | 內容 |
|---|---|
| `minute_total` | 每分鐘：下載／上傳位元組、分鐘內峰值速率、實際監測秒數 `observed_sec`、是否為補算 `recovered`、主要介面 `iface` |
| `minute_app` | 每分鐘、每個程式的下載／上傳 |
| `sample_total` | 每次取樣的原始資料（約每 2 秒）：時間（毫秒）、實際間隔、下載／上傳、是否跨睡眠、網路、各介面增量 |
| `sample_app` | 每個 nettop 區塊（約每 3 秒）裡有流量的程序：時間、程式、pid、下載／上傳、網路 |
| `minute_network` | 每分鐘、每個網路的下載／上傳（同一分鐘換網路會分開） |
| `networks` | 網路清單：路由器位址、Wi-Fi 名稱、自訂名稱、每日上限 |
| `hour_app` | 每小時、每個程式（給介面查詢用） |
| `peak`、`network_calibration` | 每日峰值、各網路每日的手動校正量 |

- `observed_sec = 0` 代表那分鐘沒在監測（睡眠或 App 未執行），**不是**沒用網路；`-1` 是 schema v1 之前的舊資料。
- 每天自動備份到 `backups/`（`VACUUM INTO`，保留 14 份），設定頁可以手動備份。
- 原始樣本約每年 2–2.5GB；記憶體中緩衝，每分鐘批次寫入一次。
- 匯出 → 「機器學習資料集」會輸出原始樣本 `samples.csv`、`app_samples.csv`，完整分鐘網格 `minutes.csv`，以及 `app_minutes.csv`、`network_minutes.csv`、`networks.csv`、`days.csv` 與欄位說明 `SCHEMA.md`，可直接用 pandas 讀取。也可以直接讀 SQLite：

```python
import sqlite3, pandas as pd
con = sqlite3.connect("~/Library/Application Support/NetQuota/netquota.sqlite".replace("~", __import__("os").path.expanduser("~")))
m = pd.read_sql("SELECT * FROM minute_total", con)
```

## 專案結構

```
Sources/NetQuotaCore/   計數器、nettop 解析、程式辨識、額度與預測、SQLite 存取、資料集匯出（有單元測試）
Sources/NetQuota/       SwiftUI 選單列 App：收集器、通知、設定、各頁 UI、CSV 匯出
Tests/NetQuotaTests/    單元測試
Resources/AppIcon.icns  App 圖示（由 scripts/make-icon.swift 繪製，改設計後刪掉此檔再打包即可重新產生）
scripts/build-app.sh    打包成 .app（ad-hoc 簽章、繁體中文在地化）
```

## 授權

[MIT](LICENSE)：可自由使用、修改、商用與再發布，只需保留版權聲明。
