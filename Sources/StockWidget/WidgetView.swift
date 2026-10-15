import SwiftUI

struct WidgetActions {
    var edit: () -> Void
    var hide: () -> Void
    var quit: () -> Void
    var drag: (_ ended: Bool) -> Void
    var sizeChanged: (CGSize) -> Void
}

enum Fmt {
    private static let formatters: [Int: NumberFormatter] = {
        var d: [Int: NumberFormatter] = [:]
        for digits in 0...4 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.usesGroupingSeparator = true
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
            d[digits] = f
        }
        return d
    }()

    static func digits(for price: Double) -> Int { abs(price) < 1 ? 4 : 2 }

    static func price(_ v: Double) -> String {
        formatters[digits(for: v)]!.string(from: NSNumber(value: v)) ?? "—"
    }

    static func change(_ v: Double, reference: Double) -> String {
        let s = formatters[digits(for: reference)]!.string(from: NSNumber(value: abs(v))) ?? "—"
        return (v > 0 ? "+" : v < 0 ? "-" : "") + s
    }

    static func percent(_ v: Double) -> String {
        (v > 0 ? "+" : v < 0 ? "-" : "") + String(format: "%.2f%%", abs(v))
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let nyTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f
    }()

    static let twTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }()
}

struct Palette {
    var redUp: Bool
    func color(for change: Double) -> Color {
        if abs(change) < 0.000001 { return .secondary }
        return (change > 0) == redUp ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
    }
}

struct WidgetView: View {
    @ObservedObject var store: QuoteStore
    var actions: WidgetActions

    private var palette: Palette { Palette(redUp: store.redUp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                ForEach(Market.allCases) { market in
                    let list = store.items(in: market)
                    if !list.isEmpty {
                        SectionHeader(market: market, session: market == .tw ? store.twSession : store.usSession,
                                      time: sectionTime(market))
                        ForEach(list) { item in
                            StockRow(item: item, quote: store.quotes[item.id], palette: palette,
                                     showSparkline: store.showSparkline)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: store.showSparkline ? 312 : 262)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in actions.drag(false) }
                .onEnded { _ in actions.drag(true) }
        )
        .contextMenu { menu }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { actions.sizeChanged($0) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("自選股")
                .font(.system(size: 15, weight: .bold))
            Spacer(minLength: 4)
            if let err = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(err)
            }
            if let t = store.lastUpdated {
                Text(Fmt.time.string(from: t))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            IconButton(systemName: "arrow.clockwise", help: "立即更新", spinning: store.isRefreshing) {
                Task { await store.refresh(force: true) }
            }
            IconButton(systemName: "slider.horizontal.3", help: "編輯自選股") { actions.edit() }
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("還沒有自選股").foregroundStyle(.secondary)
            Button("新增股票…") { actions.edit() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder private var menu: some View {
        Button("編輯自選股…") { actions.edit() }
        Button("立即更新") { Task { await store.refresh(force: true) } }
        Divider()
        Picker("視窗位置", selection: $store.windowLayer) {
            ForEach(WindowLayer.allCases) { Text($0.label).tag($0) }
        }
        Toggle("顯示走勢圖", isOn: $store.showSparkline)
        Picker("漲跌顏色", selection: $store.redUp) {
            Text("紅漲綠跌").tag(true)
            Text("綠漲紅跌").tag(false)
        }
        Divider()
        Button("隱藏 Widget") { actions.hide() }
        Button("結束") { actions.quit() }
    }

    private func sectionTime(_ market: Market) -> String? {
        let times = store.items(in: market).compactMap { store.quotes[$0.id]?.extended?.time ?? store.quotes[$0.id]?.time }
        guard let latest = times.max() else { return nil }
        return market == .tw ? Fmt.twTime.string(from: latest) : "美東 " + Fmt.nyTime.string(from: latest)
    }
}

private struct IconButton: View {
    var systemName: String
    var help: String
    var spinning = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct SectionHeader: View {
    var market: Market
    var session: Session
    var time: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(market.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SessionBadge(market: market, session: session)
            Spacer()
            if let time {
                Text(time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct SessionBadge: View {
    var market: Market
    var session: Session

    private var info: (String, Color) {
        switch session {
        case .regular: return ("盤中", .blue)
        case .pre: return (market == .tw ? "試撮" : "盤前", .orange)
        case .post: return ("盤後", .purple)
        case .closed: return ("收盤", .gray)
        }
    }

    var body: some View {
        let (text, color) = info
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

struct StockRow: View {
    var item: WatchItem
    var quote: Quote?
    var palette: Palette
    var showSparkline: Bool
    @State private var hovering = false

    /// 美股主標題用代號、副標題用名稱；台股與指數相反
    private var titles: (String, String) {
        switch item.market {
        case .tw:
            return (item.name, item.displaySymbol)
        case .us:
            if item.symbol.hasPrefix("^") || item.symbol.contains("=") { return (item.name, item.symbol) }
            return (item.symbol, item.name)
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(titles.0)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(titles.1)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showSparkline {
                    Sparkline(points: quote?.spark ?? [], baseline: quote?.sparkBaseline, palette: palette)
                        .frame(width: 56, height: 24)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    priceText
                    HStack(spacing: 4) {
                        if let q = quote {
                            Text(Fmt.change(q.change, reference: q.price))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(palette.color(for: q.change))
                        }
                        ChangePill(quote: quote, palette: palette)
                    }
                }
                .frame(minWidth: 112, alignment: .trailing)
            }

            if let ext = quote?.extended {
                ExtendedLine(ext: ext, palette: palette)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = item.webURL { NSWorkspace.shared.open(url) }
        }
        .help("點一下開啟 Yahoo 股市")
    }

    @ViewBuilder private var priceText: some View {
        if let q = quote {
            let limit = q.isLimitUp || q.isLimitDown
            Text(Fmt.price(q.price))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(limit ? Color.white : Color.primary)
                .padding(.horizontal, limit ? 4 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(limit ? palette.color(for: q.change) : .clear)
                )
        } else {
            Text("—").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

private struct ChangePill: View {
    var quote: Quote?
    var palette: Palette

    var body: some View {
        let text: String
        let color: Color
        if let q = quote {
            text = q.isLimitUp ? "漲停" : q.isLimitDown ? "跌停" : Fmt.percent(q.changePercent)
            color = palette.color(for: q.change)
        } else {
            text = "—"
            color = .secondary
        }
        return Text(text)
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 56)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(quote == nil ? 0.3 : 0.9)))
    }
}

private struct ExtendedLine: View {
    var ext: ExtendedQuote
    var palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ext.isPre ? "sunrise.fill" : "moon.fill")
                .font(.system(size: 9))
                .foregroundStyle(ext.isPre ? .orange : .purple)
            Text(ext.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if let t = ext.time {
                Text(Fmt.nyTime.string(from: t))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Text(Fmt.price(ext.price))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(Fmt.change(ext.change, reference: ext.price))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(palette.color(for: ext.change))
            Text(Fmt.percent(ext.changePercent))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.color(for: ext.change))
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }
}

struct Sparkline: View {
    var points: [SparkPoint]
    var baseline: Double?
    var palette: Palette

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            var lo = points.map(\.y).min()!, hi = points.map(\.y).max()!
            if let b = baseline { lo = min(lo, b); hi = max(hi, b) }
            // 最小振幅 ±1%：避免冷門股在一兩檔之間跳動被放大成鋸齒
            let minSpan = abs(baseline ?? points[0].y) * 0.02
            if hi - lo < minSpan {
                let mid = (hi + lo) / 2
                hi = mid + minSpan / 2; lo = mid - minSpan / 2
            }
            if hi - lo < 1e-9 { hi += 1; lo -= 1 }
            let pad: CGFloat = 1.5
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: CGFloat(min(max(x, 0), 1)) * size.width,
                        y: pad + CGFloat((hi - y) / (hi - lo)) * (size.height - 2 * pad))
            }
            let last = points.last!.y
            let color = palette.color(for: last - (baseline ?? points.first!.y))

            if let b = baseline {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: pt(0, b).y))
                base.addLine(to: CGPoint(x: size.width, y: pt(0, b).y))
                ctx.stroke(base, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
            }

            var line = Path()
            line.move(to: pt(points[0].x, points[0].y))
            for p in points.dropFirst() { line.addLine(to: pt(p.x, p.y)) }

            var fill = line
            let bottomY = baseline.map { pt(0, $0).y } ?? size.height
            fill.addLine(to: CGPoint(x: pt(points.last!.x, 0).x, y: bottomY))
            fill.addLine(to: CGPoint(x: pt(points[0].x, 0).x, y: bottomY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.15)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}
