import AppKit
import ServiceManagement
import SwiftUI

enum WindowLayer: String, CaseIterable, Identifiable {
    case desktop, floating
    var id: String { rawValue }
    var label: String { self == .desktop ? "桌面（在其他視窗下方）" : "最上層（永遠置頂）" }
}

@MainActor
final class QuoteStore: ObservableObject {
    private enum Keys {
        static let items = "watchlist"
        static let redUp = "redUp"
        static let interval = "refreshInterval"
        static let sparkline = "showSparkline"
        static let layer = "windowLayer"
    }

    private let defaults = UserDefaults.standard

    @Published var items: [WatchItem] {
        didSet { if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Keys.items) } }
    }
    /// key 為 WatchItem.id
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    /// 紅漲綠跌（台灣習慣）；false 為綠漲紅跌
    @Published var redUp: Bool { didSet { defaults.set(redUp, forKey: Keys.redUp) } }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.interval); startTimer() }
    }
    @Published var showSparkline: Bool { didSet { defaults.set(showSparkline, forKey: Keys.sparkline) } }
    @Published var windowLayer: WindowLayer { didSet { defaults.set(windowLayer.rawValue, forKey: Keys.layer) } }

    private var timer: Timer?
    private var lastTWFetch = Date.distantPast
    private var lastUSFetch = Date.distantPast
    private var lastSparkFetch = Date.distantPast
    private var lastFuturesFetch = Date.distantPast
    /// 目前用 Yahoo 備援報價的台股（證交所恢復後要換回來）
    private var twFallback: Set<String> = []
    /// 依來源記錄的錯誤（"台股" 或個股代號），成功後清除
    private var errors: [String: String] = [:]

    init() {
        if let data = defaults.data(forKey: Keys.items),
           let saved = try? JSONDecoder().decode([WatchItem].self, from: data) {
            items = saved.map(\.migrated)
        } else {
            items = WatchItem.defaults
        }
        redUp = defaults.object(forKey: Keys.redUp) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Keys.interval) as? Double ?? 15
        showSparkline = defaults.object(forKey: Keys.sparkline) as? Bool ?? true
        windowLayer = WindowLayer(rawValue: defaults.string(forKey: Keys.layer) ?? "") ?? .desktop

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
    }

    func items(in market: Market) -> [WatchItem] { items.filter { $0.market == market } }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 1
    }

    // MARK: - 自選股編輯

    func contains(market: Market, symbol: String) -> Bool {
        items.contains { $0.market == market && $0.symbol == symbol }
    }

    func add(_ item: WatchItem) {
        guard !contains(market: item.market, symbol: item.symbol) else { return }
        items.append(item)
        Task { await refresh(force: true) }
    }

    func remove(_ item: WatchItem) {
        items.removeAll { $0.id == item.id }
        quotes[item.id] = nil
    }

    func move(in market: Market, from source: IndexSet, to destination: Int) {
        items = Market.allCases.flatMap { m -> [WatchItem] in
            var list = items(in: m)
            if m == market { list.move(fromOffsets: source, toOffset: destination) }
            return list
        }
    }

    // MARK: - 開機自動啟動

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
            return nil
        } catch {
            return "無法設定開機啟動：\(error.localizedDescription)"
        }
    }

    // MARK: - 更新報價

    private enum FetchResult {
        case tw([String: Quote])
        case yahoo(id: String, Quote)
        case twFutures([String: Quote])
        case failure(String, Error)
    }

    func session(of market: Market) -> Session {
        switch market {
        case .tw:
            return items(in: .tw).compactMap { quotes[$0.id]?.session }.first
                ?? QuoteService.twSession(now: Date(), dataDate: nil)
        case .us, .futures:
            let sessions = items(in: market).compactMap { quotes[$0.id]?.session }
            for s in [Session.regular, .pre, .post, .night] where sessions.contains(s) { return s }
            return .closed
        }
    }

    /// 美東 04:00–20:00 的平日（盤前到盤後）
    private func usExtendedHoursNow(_ now: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let c = cal.dateComponents([.weekday, .hour], from: now)
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour else { return false }
        return h >= 4 && h < 20
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let tw = items(in: .tw)
        let us = items(in: .us)
        let idle: TimeInterval = 300

        // 收盤時段降低頻率，避免整晚一直打 API
        let twOpen = QuoteService.twSession(now: now, dataDate: nil) != .closed
        let twDue = !tw.isEmpty && (force || twOpen || now.timeIntervalSince(lastTWFetch) > idle
            || tw.contains { quotes[$0.id] == nil || twFallback.contains($0.id) })
        let sparkDue = !tw.isEmpty && showSparkline
            && (force || now.timeIntervalSince(lastSparkFetch) > (twOpen ? 60 : 600))
        let usActive = usExtendedHoursNow(now) || us.contains { (quotes[$0.id]?.session ?? .closed) != .closed }
        let usDue = !us.isEmpty && (force || usActive || now.timeIntervalSince(lastUSFetch) > idle
            || us.contains { quotes[$0.id] == nil })
        let futures = items(in: .futures)
        let futuresActive = (futures.contains(where: \.isTaifex) && QuoteService.taifexSession(now: now) != .closed)
            || futures.contains { (quotes[$0.id]?.session ?? .closed) != .closed }
        let futuresDue = !futures.isEmpty && (force || futuresActive || now.timeIntervalSince(lastFuturesFetch) > idle
            || futures.contains { quotes[$0.id] == nil })

        guard twDue || sparkDue || usDue || futuresDue else { return }
        let missing = Set(tw.filter { quotes[$0.id] == nil }.map(\.id))

        let twFutures = futures.filter(\.isTaifex)

        var results: [FetchResult] = []
        await withTaskGroup(of: [FetchResult].self) { group in
            if twDue {
                group.addTask {
                    do { return [.tw(try await QuoteService.twse(tw))] } catch { return [.failure("台股", error)] }
                }
            }
            if sparkDue || twDue {
                // 台股走勢圖用 Yahoo；證交所失敗時也拿它當備援報價
                for item in tw where sparkDue || missing.contains(item.id) {
                    group.addTask {
                        do { return [.yahoo(id: item.id, try await QuoteService.yahooChart(item.yahooSymbol))] }
                        catch { return [.failure(item.symbol, error)] }
                    }
                }
            }
            let yahooItems = (usDue ? us : []) + (futuresDue ? futures.filter { !$0.isTaifex } : [])
            for item in yahooItems {
                group.addTask {
                    do { return [.yahoo(id: item.id, try await QuoteService.yahooChart(item.symbol))] }
                    catch { return [.failure(item.symbol, error)] }
                }
            }
            if futuresDue && !twFutures.isEmpty {
                // 台指期等一次請求全部抓回來
                group.addTask {
                    do { return [.twFutures(try await QuoteService.twFutures(twFutures.map(\.symbol), now: now))] }
                    catch { return [.failure("台指期", error)] }
                }
            }
            for await r in group { results += r }
        }

        if sparkDue { lastSparkFetch = now }
        if usDue { lastUSFetch = now }
        if futuresDue { lastFuturesFetch = now }

        var twFromMIS: Set<String> = []

        // 先套用證交所報價，再套用走勢圖
        for case .tw(let dict) in results {
            lastTWFetch = now
            errors["台股"] = nil
            for (idx, item) in items.enumerated() where item.market == .tw {
                guard var q = dict[item.symbol] else { continue }
                q.spark = quotes[item.id]?.spark ?? []
                q.sparkBaseline = q.previousClose
                quotes[item.id] = q
                twFromMIS.insert(item.id)
                twFallback.remove(item.id)
                if item.exchange == nil, let ex = q.exchange { items[idx].exchange = ex }
            }
        }
        for r in results {
            switch r {
            case .tw:
                break
            case .twFutures(let dict):
                errors["台指期"] = nil
                for item in twFutures {
                    if let q = dict[item.symbol] { quotes[item.id] = q }
                }
            case .yahoo(let id, let yq):
                guard let item = items.first(where: { $0.id == id }) else { continue }
                errors[item.symbol] = nil
                if item.market != .tw {
                    quotes[id] = yq
                } else if var q = quotes[id], twFromMIS.contains(id) || (!twDue && !twFallback.contains(id)) {
                    // 價格以證交所為準，Yahoo 只補走勢圖
                    q.spark = yq.spark
                    q.sparkBaseline = q.previousClose
                    quotes[id] = q
                } else {
                    // 證交所這次失敗 → 先用 Yahoo 報價頂著，下一輪再試證交所
                    var q = yq
                    q.session = QuoteService.twSession(now: now, dataDate: nil)
                    quotes[id] = q
                    twFallback.insert(id)
                }
            case .failure(let source, let error):
                NSLog("StockWidget fetch failed [%@]: %@", source, String(describing: error))
                // 台股走勢圖抓不到不算錯（價格來自證交所）
                if let item = items.first(where: { $0.symbol == source }), item.market == .tw, quotes[item.id] != nil {
                    continue
                }
                errors[source] = "\(source)：\(error.localizedDescription)"
            }
        }

        // 移除已經不在清單內的錯誤
        let valid = Set(items.map(\.symbol)).union(["台股", "台指期"])
        errors = errors.filter { valid.contains($0.key) }
        lastError = errors.isEmpty ? nil : errors.values.sorted().prefix(3).joined(separator: "\n")
        if results.contains(where: { if case .failure = $0 { return false } else { return true } }) {
            lastUpdated = now
        }
    }
}
