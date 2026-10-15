import AppKit
import SwiftUI

/// 無邊框、半透明、不會搶焦點的桌面小工具視窗
final class WidgetPanel: NSPanel {
    private static let originKey = "widgetTopLeft"
    private static let cornerRadius: CGFloat = 20

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(store: QuoteStore, actions: WidgetActions) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 312, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        var acts = actions
        acts.drag = { [weak self] ended in self?.handleDrag(ended: ended) }
        acts.sizeChanged = { [weak self] size in self?.fit(to: size) }
        let hosting = FirstMouseHostingView(rootView: WidgetView(store: store, actions: acts))
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        contentView = effect

        restorePosition()
    }

    override var canBecomeKey: Bool { true }

    func apply(layer: WindowLayer) {
        switch layer {
        case .desktop:
            // 桌面圖示之上、一般視窗之下，跟系統 Widget 一樣
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .floating:
            level = .floating
        }
    }

    // MARK: - 尺寸 / 位置

    /// 內容高度改變時保持左上角不動
    private func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let w = ceil(size.width), h = ceil(size.height)
        guard abs(frame.width - w) > 0.5 || abs(frame.height - h) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - h, width: w, height: h), display: true)
        invalidateShadow()
    }

    private func handleDrag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, frame.origin) }
        guard let start = dragStart else { return }
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                               y: start.origin.y + mouse.y - start.mouse.y))
        if ended {
            dragStart = nil
            savePosition()
        }
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey)
    }

    private func restorePosition() {
        let screens = NSScreen.screens
        if let s = UserDefaults.standard.string(forKey: Self.originKey) {
            let topLeft = NSPointFromString(s)
            // 確認存下來的位置還在某個螢幕裡（外接螢幕拔掉的情況）
            if screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(topLeft) }) {
                setFrameTopLeftPoint(topLeft)
                return
            }
        }
        if let vf = (NSScreen.main ?? screens.first)?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: vf.maxX - frame.width - 24, y: vf.maxY - 24))
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 視窗沒有焦點時第一下點擊也要有反應
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
