# 股票 Widget（macOS）

釘在桌面上的自選股小工具，台股、美股都能加，美股會另外顯示**盤前／盤後**價。

- **台股**：證交所「基本市況報導」即時報價（上市、上櫃、ETF、加權指數 / 櫃買指數），漲停 / 跌停會標示
- **美股**：Yahoo Finance，正規盤報價 + 盤前（☀︎）/ 盤後（☾）價格與漲跌
- 當日走勢圖、紅漲綠跌（可切換）、盤中 / 盤前 / 收盤狀態
- 不需要 Xcode，用 Command Line Tools 就能編譯

## 編譯與執行

```bash
./build.sh            # 產生 build/StockWidget.app
open build/StockWidget.app
```

```bash
./build.sh install    # 複製到 ~/Applications 並啟動
```

## 使用

| 操作 | 方式 |
| --- | --- |
| 新增 / 移除 / 排序自選股 | Widget 右上角 ⚙︎，或選單列圖示 →「編輯自選股…」 |
| 搜尋 | 代號（2330、AAPL）、中文名稱（台積電）、英文名稱（nvidia）都可以 |
| 移動 Widget | 直接拖曳 |
| 開啟個股頁面 | 點一下該列（開 Yahoo 股市） |
| 更多選項 | 在 Widget 上按右鍵 |
| 再次打開設定 | 選單列圖示，或在 Finder 再雙擊一次 App |

設定頁可以調整：漲跌顏色、走勢圖開關、更新頻率（10 秒～1 分鐘）、Widget 放在桌面層或永遠置頂、登入時自動啟動。

收盤時段會自動降到每 5 分鐘更新一次。美股盤前為美東 04:00–09:30，
台灣時間夏令 16:00–21:30、冬令 17:00–22:30。

## 除錯

```bash
build/StockWidget.app/Contents/MacOS/StockWidget --dump 2330 AAPL ^SOX
```

```bash
build/StockWidget.app/Contents/MacOS/StockWidget --search 聯發
```

## 檔案結構

```
Sources/StockWidget/
  main.swift          進入點（含 --dump / --search）
  AppDelegate.swift   選單列圖示、Widget 視窗、設定視窗
  WidgetPanel.swift   無邊框半透明桌面視窗（拖曳、記住位置）
  WidgetView.swift    Widget 畫面（每列報價、盤前/盤後列、走勢圖）
  EditorView.swift    自選股編輯與設定
  QuoteStore.swift    自選股清單、設定、定時更新
  QuoteService.swift  證交所 / Yahoo API 與解析
  Models.swift        資料結構
scripts/make_icon.swift  產生 App 圖示
```

## 注意

報價來自證交所與 Yahoo Finance 的公開網頁 API，非官方授權資料源，僅供參考；
API 格式若有變動可能需要調整 `QuoteService.swift`。
