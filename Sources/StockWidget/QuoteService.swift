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
        try await send(URLRequest(url: url))
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        var req = request
        // Yahoo 對「完整瀏覽器 UA 但沒有 cookie」的請求會回 429，簡短 UA 反而正常
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw QuoteError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { throw QuoteError.notFound(req.url?.lastPathComponent ?? "") }
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
            extended = ExtendedQuote(kind: isPre ? .pre : .post, price: extPrice, change: change,
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

    // MARK: - 台指期（Yahoo 奇摩股市）

    /// 台指期近月報價，一次抓全部商品。Yahoo 把「夜盤 15:00 + 隔日日盤到 13:45」當作同一個交易日，
    /// 參考價都是最近一次的結算價，跟期交所的漲跌算法一致。
    static func twFutures(_ products: [String], now: Date = Date()) async throws -> [String: Quote] {
        let symbols = products.compactMap { TaifexProduct.yahooSymbols[$0] }
        guard !symbols.isEmpty else { return [:] }
        let list = "[" + symbols.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let encoded = list.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? list
        guard let url = URL(string: "https://tw.stock.yahoo.com/_td-stock/api/resource/FinanceChartService.ApacLibraCharts;autoRefresh=1;symbols=\(encoded);type=tick") else {
            throw QuoteError.badResponse
        }
        let items = try JSONDecoder().decode([YahooTWChart].self, from: try await get(url))
        let session = taifexSession(now: now)

        var out: [String: Quote] = [:]
        for item in items {
            guard let product = TaifexProduct.yahooSymbols.first(where: { $0.value == item.symbol })?.key,
                  let m = item.chart?.meta, let price = m.regularMarketPrice,
                  let prev = m.previousClose ?? m.chartPreviousClose else { continue }
            let ts = item.chart?.timestamp ?? []
            let closes = item.chart?.indicators?.quote?.first?.close ?? []
            var spark: [SparkPoint] = []
            if let reg = m.currentTradingPeriod?.regular, reg.end > reg.start {
                spark = zip(ts, closes).compactMap { t, c in
                    c.map { SparkPoint(x: (t - reg.start) / (reg.end - reg.start), y: $0) }
                }
            }
            // 沒有夜盤的商品（金融期）交易日從隔天 08:45 才開始
            var itemSession = session
            if let reg = m.currentTradingPeriod?.regular, now.timeIntervalSince1970 < reg.start { itemSession = .closed }
            let sessionName: String
            switch itemSession {
            case .regular: sessionName = "日盤"
            case .night: sessionName = "夜盤"
            default: sessionName = "近月"
            }
            out[product] = Quote(
                price: price,
                previousClose: prev,
                name: m.name,
                contract: "\(product) · \(sessionName)",
                limitUp: m.limitUpPrice,
                limitDown: m.limitDownPrice,
                time: m.regularMarketTime.map { Date(timeIntervalSince1970: $0) },
                session: itemSession,
                spark: spark,
                sparkBaseline: prev
            )
        }
        return out
    }

    private static func taipeiClock(_ now: Date) -> (weekday: Int, minutes: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        return (c.weekday ?? 1, (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// 日盤 08:45–13:45；夜盤 15:00–隔日 05:00（週一到週五開盤）
    static func taifexSession(now: Date) -> Session {
        let (wd, m) = taipeiClock(now)
        let weekday = (2...6).contains(wd)
        if weekday && m >= 8 * 60 + 45 && m < 13 * 60 + 45 { return .regular }
        if weekday && m >= 15 * 60 { return .night }
        if (3...7).contains(wd) && m < 5 * 60 { return .night }
        return .closed
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
            let market: Market = q.quoteType == "FUTURE" ? .futures : .us
            return SearchResult(market: market, symbol: sym, name: name, exchange: nil, detail: detail)
        }
    }

    /// 期交所商品與中文關鍵字（台指期、黃金…），不需連網
    static func searchLocal(_ query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [WatchItem] = []
        if let code = TaifexProduct.code(from: q), let name = TaifexProduct.names[code] {
            out.append(WatchItem(market: .futures, symbol: code, name: name))
        }
        for (keywords, item) in WatchItem.aliases
        where keywords.contains(where: { $0.contains(q) || ($0.count >= 2 && q.contains($0)) }) {
            out.append(item)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.map {
            SearchResult(market: $0.market, symbol: $0.symbol, name: $0.name, exchange: nil,
                         detail: $0.isTaifex ? "台灣期貨 · 近月" : "\($0.symbol) · 期貨")
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
        if let code = TaifexProduct.code(from: upper), let name = TaifexProduct.names[code] {
            guard try await twFutures([code])[code] != nil else { throw QuoteError.notFound(raw) }
            return WatchItem(market: .futures, symbol: code, name: name)
        }
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
        return WatchItem(market: upper.hasSuffix("=F") ? .futures : .us, symbol: upper, name: q.name ?? upper)
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

/// Yahoo 奇摩股市 FinanceChartService.ApacLibraCharts
struct YahooTWChart: Decodable {
    struct Meta: Decodable {
        let name: String?
        let regularMarketPrice: Double?
        let regularMarketTime: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let limitUpPrice: Double?
        let limitDownPrice: Double?
        let currentTradingPeriod: YahooChart.Periods?
    }
    struct Chart: Decodable {
        let meta: Meta?
        let timestamp: [Double]?
        let indicators: YahooChart.Indicators?
    }
    let symbol: String
    let chart: Chart?
}

struct MISNames: Decodable {
    struct Item: Decodable { let c: String?; let n: String?; let key: String? }
    let datas: [Item]?
}
