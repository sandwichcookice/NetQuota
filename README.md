# NetQuota

Mac 選單列網路流量監測工具。宿舍網路一天（上傳＋下載合計）超過 12GB 會被鎖卡，NetQuota 即時顯示今日用量、剩餘額度、峰值速率、各程式用量，並在接近上限前通知。

## 安裝與執行

```bash
scripts/build-app.sh             # 產生 build/NetQuota.app
scripts/build-app.sh --install   # 另外複製到 /Applications 並啟動
swift test                       # 單元測試
```

需求：macOS 15 以上、Xcode（Swift 6）。不需要 root 權限，也沒有第三方依賴。

第一次啟動會詢問通知權限，請按「允許」。想開機自動執行，先用 `--install` 裝到「應用程式」，再到 設定 → 系統 → 登入時自動啟動。

### 找不到選單列圖示？

選單列項目太多時，新圖示會被瀏海或 App 選單擋住。可以：

- 再次打開 NetQuota.app（Spotlight／Finder），會直接開啟儀表板。
- 到 系統設定 → 選單列，把不需要的項目關掉。
- 在 NetQuota 設定裡把選單列改成「百分比」，可以縮短寬度。

## 功能

- **選單列**：今日已用／上限（或剩餘、百分比），可選擇加上即時速率。圖示會隨用量變化（70%、90%、100%）。
- **面板**：用量圓環、上傳／下載、剩餘、即時速率曲線、今日峰值、用量預測、今日前 5 名程式。
- **儀表板**
  - 今日：累積用量曲線（含上限線與預測虛線）、每 15 分鐘用量。
  - 歷史：7 天／30 天／90 天／1 年，可依日／週／月彙總，標出超過額度的日子。
  - 程式：今日／昨日／7 天／30 天／全部的程式排行。
  - 設定：額度、GB／GiB、每日歸零時間、手動校正、通知、選單列樣式、開機啟動、CSV 匯出。
- **通知**：用量達 70%／90%／100%；預測今天會超標（已用 30% 以上才提醒）；單一程式短時間大量使用（預設 10 分鐘內 1GB）。
- **CSV 匯出**：每日摘要、各程式每日用量（UTF-8 含 BOM，Excel 可直接開啟）。

## 運作方式

| 資料 | 來源 |
|---|---|
| 總用量 | `sysctl NET_RT_IFLIST2` 的 64-bit 介面計數器，只算實體介面 `en*`（排除 loopback、VPN `utun`、AirDrop `awdl` 等，避免重複計算） |
| 各程式用量 | 長駐 `nettop -P -d -t external`（透過 `script` 提供 pty，避免輸出被緩衝）。XPC 服務（例如 WebKit Networking）歸到負責的 App，Chrome Helper 等歸到外層 .app |
| App 關閉期間 | 每分鐘記錄計數器快照；重新啟動時補回差額，依時間比例分配到各天（這段期間無法區分程式） |

- 每日額度以**介面總量**為準；各程式加總與總量可能略有差異。
- 預設 12GB = 12×10⁹ bytes（比 GiB 保守）。
- 預測 = 已用量 ＋ 最近 30 分鐘平均速率 × 今天剩餘時間。
- 第一次安裝當天，安裝前用掉的流量無法得知，可以在設定裡用宿舍系統的數字「校正今日已用量」。

## 資料保存與機器學習

資料存放在 `~/Library/Application Support/NetQuota/netquota.sqlite`（SQLite），**永久保留、不會自動刪除**：

| 資料表 | 內容 |
|---|---|
| `minute_total` | 每分鐘：下載／上傳位元組、分鐘內峰值速率、實際監測秒數 `observed_sec`、是否為補算 `recovered`、主要介面 `iface` |
| `minute_app` | 每分鐘、每個程式的下載／上傳 |
| `hour_app` | 每小時、每個程式（給介面查詢用） |
| `peak`、`calibration` | 每日峰值、手動校正量 |

- `observed_sec = 0` 代表那分鐘沒在監測（睡眠或 App 未執行），**不是**沒用網路；`-1` 是 schema v1 之前的舊資料。
- 每天自動備份到 `backups/`（`VACUUM INTO`，保留 14 份），設定頁可以手動備份。
- 匯出 → 「機器學習資料集（每分鐘）」會輸出完整分鐘網格 `minutes.csv`、`app_minutes.csv`、`days.csv` 與欄位說明 `SCHEMA.md`，可直接用 pandas 讀取。也可以直接讀 SQLite：

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
