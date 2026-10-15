import AppKit

// StockWidget --search 關鍵字：在終端機印出搜尋結果
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--search" {
    let q = CommandLine.arguments[2]
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        for r in QuoteService.searchLocal(q) { print("[內建] \(r.market.shortLabel) \(r.symbol) \(r.name) · \(r.detail)") }
        for (label, search) in [("證交所", QuoteService.searchTW), ("Yahoo", QuoteService.searchYahoo)] {
            do {
                for r in try await search(q) { print("[\(label)] \(r.market.label) \(r.symbol) \(r.name) · \(r.detail)") }
            } catch {
                print("[\(label)] \(error.localizedDescription)")
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// StockWidget --dump [代號…]：在終端機印出報價後結束，方便除錯
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--dump" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let items: [WatchItem]
        if args.isEmpty {
            items = WatchItem.defaults
        } else {
            var resolved: [WatchItem] = []
            for a in args {
                do { resolved.append(try await QuoteService.resolve(a)) }
                catch { print("\(a): \(error.localizedDescription)") }
            }
            items = resolved
        }
        let tw = items.filter { $0.market == .tw }
        let twQuotes = (try? await QuoteService.twse(tw)) ?? [:]
        for item in items {
            let q: Quote?
            if item.market == .tw { q = twQuotes[item.symbol] }
            else if item.isTaifex { q = (try? await QuoteService.twFutures([item.symbol]))?[item.symbol] }
            else { q = try? await QuoteService.yahooChart(item.symbol) }
            guard let q else { print("\(item.symbol): 無資料"); continue }
            var line = "[\(item.market.shortLabel)] \(item.symbol) \(q.contract ?? q.name ?? item.name)  \(Fmt.price(q.price))  "
                + "\(Fmt.change(q.change, reference: q.price)) (\(Fmt.percent(q.changePercent)))  參考價 \(Fmt.price(q.previousClose))  [\(q.session.rawValue)]"
            if let e = q.extended {
                let time = e.time.map { e.kind == .night ? " @ \(Fmt.twTime.string(from: $0))" : " @ 美東 \(Fmt.nyTime.string(from: $0))" } ?? ""
                line += "\n      \(e.label) \(Fmt.price(e.price)) \(Fmt.change(e.change, reference: e.price)) (\(Fmt.percent(e.changePercent)))" + time
            }
            if item.market != .tw {
                line += "\n      走勢點數 \(q.spark.count)" + (q.spark.last.map { String(format: "，最後 x=%.2f", $0.x) } ?? "")
            }
            print(line)
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
