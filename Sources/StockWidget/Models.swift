import Foundation

enum Market: String, Codable, CaseIterable, Identifiable {
    case tw, us, futures
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tw: return "台股"
        case .us: return "美股"
        case .futures: return "期貨・商品"
        }
    }
    var shortLabel: String { self == .futures ? "期貨" : label }
}

/// 期交所商品（近月合約），報價來自 Yahoo 奇摩股市的「近一」
enum TaifexProduct {
    static let names: [String: String] = [
        "TXF": "台指期", "MXF": "小台指", "TMF": "微台指", "EXF": "電子期", "FXF": "金融期",
    ]
    static let yahooSymbols: [String: String] = [
        "TXF": "WTX&", "MXF": "WMT&", "TMF": "WTM&", "EXF": "WTE&", "FXF": "WTF&",
    ]

    /// 輸入 TXF、TXFF、TXFJ6… 都視為該商品的近月合約
    static func code(from input: String) -> String? {
        let s = input.uppercased()
        guard s.count <= 5 else { return nil }
        return names.keys.first { s.hasPrefix($0) }
    }
}

/// 自選股清單中的一檔
struct WatchItem: Codable, Hashable, Identifiable {
    var market: Market
    /// 台股：股票代號（2330、0050、t00=加權指數、o00=櫃買指數）
    /// 美股：Yahoo Finance 代號（AAPL、^GSPC…）
    /// 期貨・商品：期交所商品代號（TXF、MXF…）或 Yahoo 期貨代號（GC=F、NQ=F…）
    var symbol: String
    var name: String
    /// 台股上市 tse / 上櫃 otc，第一次查到後記住
    var exchange: String?

    var id: String { "\(market.rawValue):\(symbol)" }

    var isTaifex: Bool { market == .futures && TaifexProduct.names[symbol] != nil }

    var displaySymbol: String {
        switch (market, symbol) {
        case (.tw, "t00"): return "TWSE"
        case (.tw, "o00"): return "TPEx"
        case (.tw, _): return symbol + (exchange == "otc" ? " 櫃" : "")
        default: return symbol
        }
    }

    /// 用來向 Yahoo 抓走勢圖 / 報價的代號
    var yahooSymbol: String {
        guard market == .tw else { return symbol }
        switch symbol {
        case "t00": return "^TWII"
        case "o00": return "^TWOII"
        default: return symbol + (exchange == "otc" ? ".TWO" : ".TW")
        }
    }

    var webURL: URL? {
        func yahoo(_ base: String, _ s: String) -> URL? {
            URL(string: base + (s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s))
        }
        switch market {
        case .tw: return yahoo("https://tw.stock.yahoo.com/quote/", yahooSymbol)
        case .us: return yahoo("https://finance.yahoo.com/quote/", symbol)
        case .futures:
            if let tw = TaifexProduct.yahooSymbols[symbol] { return yahoo("https://tw.stock.yahoo.com/future/", tw) }
            return yahoo("https://finance.yahoo.com/quote/", symbol)
        }
    }

    /// 舊版把 Yahoo 期貨（NQ=F）放在美股，移到期貨・商品
    var migrated: WatchItem {
        guard market == .us, symbol.hasSuffix("=F") else { return self }
        var item = self
        item.market = .futures
        return item
    }
}

enum Session: String {
    case pre, regular, post, night, closed
}

struct SparkPoint: Equatable {
    /// 0...1，交易時段內的時間位置
    var x: Double
    var y: Double
}

/// 盤前 / 盤後 / 夜盤報價
struct ExtendedQuote: Equatable {
    enum Kind { case pre, post, night }
    var kind: Kind
    var price: Double
    var change: Double
    var changePercent: Double
    var time: Date?

    var label: String {
        switch kind {
        case .pre: return "盤前"
        case .post: return "盤後"
        case .night: return "夜盤"
        }
    }
}

struct Quote: Equatable {
    var price: Double
    var previousClose: Double
    var name: String?
    /// 期貨合約說明（例：TXF 10月）
    var contract: String?
    var high: Double?
    var low: Double?
    var limitUp: Double?
    var limitDown: Double?
    var time: Date?
    var session: Session = .closed
    var extended: ExtendedQuote?
    var spark: [SparkPoint] = []
    var sparkBaseline: Double?
    var exchange: String?

    var change: Double { price - previousClose }
    var changePercent: Double { previousClose == 0 ? 0 : change / previousClose * 100 }
    var isLimitUp: Bool { limitUp.map { price >= $0 - 0.0001 } ?? false }
    var isLimitDown: Bool { limitDown.map { price <= $0 + 0.0001 } ?? false }
}

/// 搜尋結果
struct SearchResult: Identifiable, Hashable {
    var market: Market
    var symbol: String
    var name: String
    var exchange: String?
    var detail: String
    var id: String { "\(market.rawValue):\(symbol)" }

    var watchItem: WatchItem { WatchItem(market: market, symbol: symbol, name: name, exchange: exchange) }
}

extension WatchItem {
    static let defaults: [WatchItem] = [
        WatchItem(market: .tw, symbol: "t00", name: "加權指數", exchange: "tse"),
        WatchItem(market: .tw, symbol: "2330", name: "台積電", exchange: "tse"),
        WatchItem(market: .tw, symbol: "0050", name: "元大台灣50", exchange: "tse"),
        WatchItem(market: .us, symbol: "NVDA", name: "NVIDIA"),
        WatchItem(market: .us, symbol: "AAPL", name: "Apple"),
        WatchItem(market: .us, symbol: "TSM", name: "台積電 ADR"),
        WatchItem(market: .futures, symbol: "TXF", name: "台指期"),
        WatchItem(market: .futures, symbol: "GC=F", name: "黃金"),
    ]

    /// 編輯畫面的快速加入
    static let suggestions: [WatchItem] = [
        WatchItem(market: .tw, symbol: "t00", name: "加權指數", exchange: "tse"),
        WatchItem(market: .tw, symbol: "o00", name: "櫃買指數", exchange: "otc"),
        WatchItem(market: .futures, symbol: "TXF", name: "台指期"),
        WatchItem(market: .futures, symbol: "MXF", name: "小台指"),
        WatchItem(market: .us, symbol: "^GSPC", name: "S&P 500"),
        WatchItem(market: .us, symbol: "^IXIC", name: "那斯達克"),
        WatchItem(market: .us, symbol: "^DJI", name: "道瓊"),
        WatchItem(market: .us, symbol: "^SOX", name: "費城半導體"),
        WatchItem(market: .futures, symbol: "NQ=F", name: "那指期貨"),
        WatchItem(market: .futures, symbol: "ES=F", name: "標普期貨"),
        WatchItem(market: .futures, symbol: "GC=F", name: "黃金"),
        WatchItem(market: .futures, symbol: "SI=F", name: "白銀"),
        WatchItem(market: .futures, symbol: "PL=F", name: "白金"),
        WatchItem(market: .futures, symbol: "PA=F", name: "鈀金"),
    ]

    /// 中文關鍵字搜尋（Yahoo 不支援中文查詢）
    static let aliases: [(keywords: [String], item: WatchItem)] = [
        (["台指期", "台指", "臺指", "大台", "期貨"], WatchItem(market: .futures, symbol: "TXF", name: "台指期")),
        (["小台", "小台指", "小型台指", "期貨"], WatchItem(market: .futures, symbol: "MXF", name: "小台指")),
        (["微台", "微台指", "微型台指", "期貨"], WatchItem(market: .futures, symbol: "TMF", name: "微台指")),
        (["電子期", "期貨"], WatchItem(market: .futures, symbol: "EXF", name: "電子期")),
        (["金融期", "期貨"], WatchItem(market: .futures, symbol: "FXF", name: "金融期")),
        (["黃金", "金價", "貴金屬"], WatchItem(market: .futures, symbol: "GC=F", name: "黃金")),
        (["白銀", "銀價", "貴金屬"], WatchItem(market: .futures, symbol: "SI=F", name: "白銀")),
        (["白金", "鉑金", "鉑", "貴金屬"], WatchItem(market: .futures, symbol: "PL=F", name: "白金")),
        (["鈀金", "鈀", "貴金屬"], WatchItem(market: .futures, symbol: "PA=F", name: "鈀金")),
        (["那指期", "那斯達克期貨"], WatchItem(market: .futures, symbol: "NQ=F", name: "那指期貨")),
        (["標普期", "標普期貨"], WatchItem(market: .futures, symbol: "ES=F", name: "標普期貨")),
        (["道瓊期", "道瓊期貨"], WatchItem(market: .futures, symbol: "YM=F", name: "道瓊期貨")),
    ]
}
