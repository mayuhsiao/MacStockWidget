import Foundation

enum QuoteError: LocalizedError {
    case http(Int)
    case notFound(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return code == 429 ? "請求太頻繁（HTTP 429）" : "伺服器錯誤（HTTP \(code)）"
        case .notFound(let s): return "找不到「\(s)」"
        case .badResponse: return "回應格式錯誤"
        }
    }
}

/// 報價來源：
/// - 台股即時價：證交所基本市況報導 (mis.twse.com.tw)，上市/上櫃/指數都有
/// - 美股（含盤前/盤後）與台股走勢圖：Yahoo Finance chart API
enum QuoteService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        // Yahoo 對「完整瀏覽器 UA 但沒有 cookie」的請求會回 429，簡短 UA 反而正常
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw QuoteError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { throw QuoteError.notFound(url.lastPathComponent) }
            throw QuoteError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Yahoo chart

    static func yahooChart(_ symbol: String, now: Date = Date()) async throws -> Quote {
        let path = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(path)?interval=5m&range=1d&includePrePost=true") else {
            throw QuoteError.notFound(symbol)
        }
        let data: Data
        do {
            data = try await get(url)
        } catch QuoteError.notFound {
            throw QuoteError.notFound(symbol)
        }
        let resp = try JSONDecoder().decode(YahooChart.self, from: data)
        guard let result = resp.chart.result?.first else { throw QuoteError.notFound(symbol) }
        return try parse(result, now: now)
    }

    static func parse(_ r: YahooChart.Result, now: Date) throws -> Quote {
        let m = r.meta
        let ts = r.timestamp ?? []
        let closes = r.indicators.quote?.first?.close ?? []
        let points: [(t: Double, v: Double)] = zip(ts, closes).compactMap { t, c in c.map { (t, $0) } }
        guard let price = m.regularMarketPrice ?? points.last?.v else { throw QuoteError.notFound(m.symbol) }
        // previousClose 是 regularMarketTime 那個交易日的前一日收盤（盤前時段也成立）
        let prev = m.previousClose ?? m.chartPreviousClose ?? price
        let nowT = now.timeIntervalSince1970
        let cur = m.currentTradingPeriod

        var session = Session.closed
        if cur?.regular?.contains(nowT) == true { session = .regular }
        else if cur?.pre?.contains(nowT) == true { session = .pre }
        else if cur?.post?.contains(nowT) == true { session = .post }

        // 圖表那一天的交易時段（週末/半夜時可能跟 currentTradingPeriod 不同天）
        let regWin = m.tradingPeriods?.regular?.first?.first ?? cur?.regular
        let preWin = m.tradingPeriods?.pre?.first?.first ?? cur?.pre

        // 盤前 / 盤後：最後一筆成交晚於正規盤最後成交時間
        var extended: ExtendedQuote?
        if m.hasPrePostMarketData == true, session != .regular,
           let last = points.last, let rmt = m.regularMarketTime, last.t > rmt + 60 {
            let extPrice = m.fulldayPrice ?? last.v
            let isPre = regWin.map { last.t < $0.start } ?? false
            let change = extPrice - price
            extended = ExtendedQuote(isPre: isPre, price: extPrice, change: change,
                                     changePercent: price == 0 ? 0 : change / price * 100,
                                     time: Date(timeIntervalSince1970: last.t))
        }

        var spark: [SparkPoint] = []
        var baseline = prev
        if let reg = regWin, reg.end > reg.start {
            let regPts = points.filter { $0.t >= reg.start && $0.t <= reg.end }
            if !regPts.isEmpty {
                spark = regPts.map { SparkPoint(x: ($0.t - reg.start) / (reg.end - reg.start), y: $0.v) }
            } else if let pre = preWin, pre.end > pre.start {
                // 還沒開盤：畫今天的盤前走勢，基準是昨收（regularMarketPrice）
                let prePts = points.filter { $0.t >= pre.start && $0.t < pre.end }
                spark = prePts.map { SparkPoint(x: ($0.t - pre.start) / (pre.end - pre.start), y: $0.v) }
                baseline = price
            }
        } else if points.count > 1 {
            spark = points.enumerated().map { SparkPoint(x: Double($0.offset) / Double(points.count - 1), y: $0.element.v) }
        }

        return Quote(
            price: price,
            previousClose: prev,
            name: m.shortName ?? m.longName,
            high: m.regularMarketDayHigh,
            low: m.regularMarketDayLow,
            time: m.regularMarketTime.map { Date(timeIntervalSince1970: $0) },
            session: session,
            extended: extended,
            spark: spark,
            sparkBaseline: baseline
        )
    }

    // MARK: - 證交所 MIS

    /// 回傳以股票代號為 key 的報價
    static func twse(_ items: [WatchItem], now: Date = Date()) async throws -> [String: Quote] {
        guard !items.isEmpty else { return [:] }
        let channels = items.flatMap { item -> [String] in
            if let ex = item.exchange { return ["\(ex)_\(item.symbol).tw"] }
            return ["tse_\(item.symbol).tw", "otc_\(item.symbol).tw"]
        }
        var comps = URLComponents(string: "https://mis.twse.com.tw/stock/api/getStockInfo.jsp")!
        comps.queryItems = [
            URLQueryItem(name: "ex_ch", value: channels.joined(separator: "|")),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "delay", value: "0"),
            URLQueryItem(name: "_", value: String(Int(now.timeIntervalSince1970 * 1000))),
        ]
        let data = try await get(comps.url!)
        let resp = try JSONDecoder().decode(MISResponse.self, from: data)

        var out: [String: Quote] = [:]
        for it in resp.msgArray ?? [] {
            guard let code = it.c, !code.isEmpty, let prev = num(it.y) else { continue }
            // z 是最新成交價；這一盤剛好沒成交時是 "-"，改用最佳買價/賣價
            let price = num(it.z) ?? num(it.pz) ?? firstLevel(it.b) ?? firstLevel(it.a) ?? prev
            out[code] = Quote(
                price: price,
                previousClose: prev,
                name: it.n,
                high: num(it.h),
                low: num(it.l),
                limitUp: num(it.u),
                limitDown: num(it.w),
                time: misTime(date: it.d, time: it.t),
                session: twSession(now: now, dataDate: it.d),
                exchange: it.ex
            )
        }
        return out
    }

    static func twSession(now: Date, dataDate: String?) -> Session {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: now)
        guard let wd = c.weekday, (2...6).contains(wd) else { return .closed }
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if mins >= 8 * 60 + 30 && mins < 9 * 60 { return .pre }
        guard mins >= 9 * 60 && mins < 13 * 60 + 30 else { return .closed }
        // 盤中時間但資料日期不是今天 → 休市
        let today = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if let d = dataDate, !d.isEmpty, d != today { return .closed }
        return .regular
    }

    private static let misTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// d + t 是最後成交時間（tlong 收盤後會變成盤後定價的 14:30）
    private static func misTime(date: String?, time: String?) -> Date? {
        guard let date, let time else { return nil }
        return misTimeFormatter.date(from: "\(date) \(time)")
    }

    private static func num(_ s: String?) -> Double? {
        guard let s, let v = Double(s), v > 0 else { return nil }
        return v
    }

    private static func firstLevel(_ s: String?) -> Double? {
        num(s?.split(separator: "_").first.map(String.init))
    }

    // MARK: - 搜尋

    static func searchTW(_ query: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://mis.twse.com.tw/stock/api/getStockNames.jsp")!
        comps.queryItems = [
            URLQueryItem(name: "n", value: query),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        let data = try await get(comps.url!)
        let resp = try JSONDecoder().decode(MISNames.self, from: data)
        return (resp.datas ?? []).compactMap { d -> SearchResult? in
            guard let code = d.c, let name = d.n else { return nil }
            // 6 碼且不是 00 開頭的多半是權證，略過
            guard code.count <= 5 || code.hasPrefix("00") else { return nil }
            let ex = d.key?.split(separator: "_").first.map(String.init)
            return SearchResult(market: .tw, symbol: code, name: name, exchange: ex,
                                detail: ex == "otc" ? "上櫃" : "上市")
        }
        .prefix(12)
        .map { $0 }
    }

    static func searchYahoo(_ query: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "10"),
            URLQueryItem(name: "newsCount", value: "0"),
            URLQueryItem(name: "listsCount", value: "0"),
        ]
        let data = try await get(comps.url!)
        let resp = try JSONDecoder().decode(YahooSearch.self, from: data)
        let allowed: Set<String> = ["EQUITY", "ETF", "INDEX", "FUTURE", "MUTUALFUND", "CRYPTOCURRENCY", "CURRENCY"]
        return (resp.quotes ?? []).compactMap { q -> SearchResult? in
            guard let sym = q.symbol, allowed.contains(q.quoteType ?? "") else { return nil }
            let name = (q.shortname ?? q.longname ?? sym).trimmingCharacters(in: .whitespaces)
            let detail = [q.exchDisp, q.typeDisp].compactMap { $0 }.joined(separator: " · ")
            if let tw = taiwanCode(fromYahoo: sym) {
                return SearchResult(market: .tw, symbol: tw.code, name: name, exchange: tw.exchange, detail: detail)
            }
            // 有 .XX 後綴的是其他國家的掛牌（.TO、.DE、.T…），搜尋結果先略過；直接輸入代號仍可加入
            guard !sym.contains(".") else { return nil }
            return SearchResult(market: .us, symbol: sym, name: name, exchange: nil, detail: detail)
        }
    }

    static func taiwanCode(fromYahoo sym: String) -> (code: String, exchange: String)? {
        let s = sym.uppercased()
        if s.hasSuffix(".TWO") { return (String(s.dropLast(4)), "otc") }
        if s.hasSuffix(".TW") { return (String(s.dropLast(3)), "tse") }
        return nil
    }

    static func looksLikeTaiwanCode(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{4,6}[A-Z]?$"#, options: .regularExpression) != nil
    }

    /// 把使用者直接輸入的代號解析成一檔自選股（會實際查一次確認存在）
    static func resolve(_ input: String) async throws -> WatchItem {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = raw.uppercased()
        var twCode: String?
        var twExchange: String?
        if ["T00", "O00"].contains(upper) {
            twCode = upper.lowercased()
        } else if let tw = taiwanCode(fromYahoo: upper) {
            twCode = tw.code; twExchange = tw.exchange
        } else if looksLikeTaiwanCode(upper) {
            twCode = upper
        }
        if let code = twCode {
            let probe = WatchItem(market: .tw, symbol: code, name: code, exchange: twExchange)
            guard let q = try await twse([probe])[code] else { throw QuoteError.notFound(raw) }
            return WatchItem(market: .tw, symbol: code, name: q.name ?? code, exchange: q.exchange)
        }
        let q = try await yahooChart(upper)
        return WatchItem(market: .us, symbol: upper, name: q.name ?? upper)
    }
}

// MARK: - JSON 結構

struct YahooChart: Decodable {
    struct Chart: Decodable { let result: [Result]? }
    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Double]?
        let indicators: Indicators
    }
    struct Meta: Decodable {
        let symbol: String
        let currency: String?
        let shortName: String?
        let longName: String?
        let regularMarketPrice: Double?
        let regularMarketTime: Double?
        let regularMarketDayHigh: Double?
        let regularMarketDayLow: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let fulldayPrice: Double?
        let hasPrePostMarketData: Bool?
        let currentTradingPeriod: Periods?
        let tradingPeriods: NestedPeriods?
    }
    struct Period: Decodable {
        let start: Double
        let end: Double
        func contains(_ t: Double) -> Bool { end > start && t >= start && t < end }
    }
    struct Periods: Decodable { let pre: Period?; let regular: Period?; let post: Period? }
    struct NestedPeriods: Decodable {
        let pre: [[Period]]?, regular: [[Period]]?, post: [[Period]]?
        enum CodingKeys: String, CodingKey { case pre, regular, post }
        // 沒有盤前盤後的商品，Yahoo 有時直接給陣列而不是物件
        init(from decoder: Decoder) throws {
            if let c = try? decoder.container(keyedBy: CodingKeys.self) {
                pre = try? c.decode([[Period]].self, forKey: .pre)
                regular = try? c.decode([[Period]].self, forKey: .regular)
                post = try? c.decode([[Period]].self, forKey: .post)
            } else {
                pre = nil; post = nil
                regular = try? decoder.singleValueContainer().decode([[Period]].self)
            }
        }
    }
    struct Indicators: Decodable { let quote: [Series]? }
    struct Series: Decodable { let close: [Double?]? }
    let chart: Chart
}

struct YahooSearch: Decodable {
    struct Item: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let exchDisp: String?
        let typeDisp: String?
        let quoteType: String?
    }
    let quotes: [Item]?
}

struct MISResponse: Decodable {
    struct Item: Decodable {
        let c: String?, n: String?, ex: String?
        let z: String?, pz: String?, y: String?
        let h: String?, l: String?
        let u: String?, w: String?
        let a: String?, b: String?
        let d: String?, t: String?
    }
    let msgArray: [Item]?
}

struct MISNames: Decodable {
    struct Item: Decodable { let c: String?; let n: String?; let key: String? }
    let datas: [Item]?
}
