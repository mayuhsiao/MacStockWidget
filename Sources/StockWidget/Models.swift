import Foundation

enum Market: String, Codable, CaseIterable, Identifiable {
    case tw, us
    var id: String { rawValue }
    var label: String { self == .tw ? "台股" : "美股" }
}

/// 自選股清單中的一檔
struct WatchItem: Codable, Hashable, Identifiable {
    var market: Market
    /// 台股：股票代號（2330、0050、t00=加權指數、o00=櫃買指數）
    /// 美股：Yahoo Finance 代號（AAPL、^GSPC、NQ=F…）
    var symbol: String
    var name: String
    /// 台股上市 tse / 上櫃 otc，第一次查到後記住
    var exchange: String?

    var id: String { "\(market.rawValue):\(symbol)" }

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
        switch market {
        case .tw: return URL(string: "https://tw.stock.yahoo.com/quote/\(yahooSymbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? yahooSymbol)")
        case .us: return URL(string: "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)")
        }
    }
}

enum Session: String {
    case pre, regular, post, closed
}

struct SparkPoint: Equatable {
    /// 0...1，交易時段內的時間位置
    var x: Double
    var y: Double
}

/// 盤前 / 盤後報價
struct ExtendedQuote: Equatable {
    var isPre: Bool
    var price: Double
    var change: Double
    var changePercent: Double
    var time: Date?
    var label: String { isPre ? "盤前" : "盤後" }
}

struct Quote: Equatable {
    var price: Double
    var previousClose: Double
    var name: String?
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
    ]

    /// 編輯畫面的快速加入
    static let suggestions: [WatchItem] = [
        WatchItem(market: .tw, symbol: "t00", name: "加權指數", exchange: "tse"),
        WatchItem(market: .tw, symbol: "o00", name: "櫃買指數", exchange: "otc"),
        WatchItem(market: .us, symbol: "^GSPC", name: "S&P 500"),
        WatchItem(market: .us, symbol: "^IXIC", name: "那斯達克"),
        WatchItem(market: .us, symbol: "^DJI", name: "道瓊"),
        WatchItem(market: .us, symbol: "^SOX", name: "費城半導體"),
        WatchItem(market: .us, symbol: "NQ=F", name: "那指期貨"),
        WatchItem(market: .us, symbol: "ES=F", name: "標普期貨"),
    ]
}
