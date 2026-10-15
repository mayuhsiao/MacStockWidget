import SwiftUI

struct EditorView: View {
    @ObservedObject var store: QuoteStore

    var body: some View {
        TabView {
            WatchlistEditor(store: store)
                .tabItem { Label("自選股", systemImage: "list.bullet") }
            SettingsForm(store: store)
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(minWidth: 460, minHeight: 560)
    }
}

private struct WatchlistEditor: View {
    @ObservedObject var store: QuoteStore
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("輸入代號或名稱，例：2330、台積電、AAPL、台指期、黃金", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { Task { await addTyped() } }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            if !query.isEmpty {
                searchResults
            } else {
                suggestions
            }

            List {
                ForEach(Market.allCases) { market in
                    Section("\(market.label)（\(store.items(in: market).count)）") {
                        ForEach(store.items(in: market)) { item in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                Text(item.name).lineLimit(1)
                                Text(item.displaySymbol).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    store.remove(item)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("移除")
                            }
                        }
                        .onMove { store.move(in: market, from: $0, to: $1) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("拖曳可調整順序。台股來自證交所、台指期來自 Yahoo 奇摩股市，美股（含盤前/盤後）與貴金屬來自 Yahoo Finance。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .onAppear { focused = true }
        .task(id: query) { await search() }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty && !searching {
                Text("按 Enter 直接以代號「\(query.uppercased())」加入")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(results.prefix(8)) { r in
                let added = store.contains(market: r.market, symbol: r.symbol)
                HStack(spacing: 8) {
                    Text(r.market.shortLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(r.market.tint.opacity(0.15)))
                    Text(r.symbol).font(.body.monospaced()).frame(minWidth: 64, alignment: .leading)
                    Text(r.name).lineLimit(1)
                    Spacer()
                    Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button {
                        store.add(r.watchItem)
                        message = nil
                    } label: {
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                            .foregroundStyle(added ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快速加入").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(WatchItem.suggestions) { s in
                    let added = store.contains(market: s.market, symbol: s.symbol)
                    Button {
                        store.add(s)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: added ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                            Text(s.name)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(added ? 0.08 : 0.15)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(added ? .secondary : .primary)
                    .disabled(added)
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }

        let hasCJK = q.unicodeScalars.contains { $0.value >= 0x3400 && $0.value <= 0x9FFF }
        let digitsLed = q.first?.isNumber == true
        // 台指期、黃金等常用商品放最前面
        var found = QuoteService.searchLocal(q)
        if hasCJK || digitsLed {
            found += (try? await QuoteService.searchTW(q)) ?? []
        }
        if !hasCJK {
            found += (try? await QuoteService.searchYahoo(q)) ?? []
        }
        guard !Task.isCancelled else { return }
        // 去重（Yahoo 也可能回傳 .TW）
        var seen = Set<String>()
        results = found.filter { seen.insert($0.id).inserted }
    }

    private func addTyped() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let first = results.first(where: { !store.contains(market: $0.market, symbol: $0.symbol) }) {
            store.add(first.watchItem)
            query = ""
            message = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            let item = try await QuoteService.resolve(q)
            store.add(item)
            query = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension Market {
    var tint: Color {
        switch self {
        case .tw: return .red
        case .us: return .blue
        case .futures: return .orange
        }
    }
}

private struct SettingsForm: View {
    @ObservedObject var store: QuoteStore
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("外觀") {
                Picker("漲跌顏色", selection: $store.redUp) {
                    Text("紅漲綠跌（台灣）").tag(true)
                    Text("綠漲紅跌（美國）").tag(false)
                }
                Toggle("顯示當日走勢圖", isOn: $store.showSparkline)
                Picker("Widget 位置", selection: $store.windowLayer) {
                    ForEach(WindowLayer.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Picker("更新頻率", selection: $store.refreshInterval) {
                    Text("10 秒").tag(10.0)
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                    Text("1 分鐘").tag(60.0)
                }
            } header: {
                Text("報價")
            } footer: {
                Text("收盤時段會自動降到每 5 分鐘更新一次。美股盤前為美東 04:00–09:30（台灣時間夏令 16:00–21:30、冬令 17:00–22:30）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("系統") {
                Toggle("登入時自動啟動", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { loginError = store.setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 簡單的換行排版（快速加入的標籤用）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
