import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = QuoteStore()
    private var panel: WidgetPanel!
    private var statusItem: NSStatusItem!
    private var editorWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = WidgetActions(
            edit: { [weak self] in self?.showEditor() },
            hide: { [weak self] in self?.panel.orderOut(nil) },
            quit: { NSApp.terminate(nil) },
            drag: { _ in },
            sizeChanged: { _ in }
        )
        panel = WidgetPanel(store: store, actions: actions)
        store.$windowLayer
            .sink { [weak self] layer in self?.panel.apply(layer: layer) }
            .store(in: &cancellables)
        panel.orderFrontRegardless()

        setUpStatusItem()

        store.startTimer()
        Task { await store.refresh(force: true) }
    }

    /// 已在執行時再次打開 App（例如從 Finder 雙擊）→ 顯示 Widget 並打開設定
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        showEditor()
        return true
    }

    // MARK: - 選單列

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "股票 Widget")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = panel.isVisible
        menu.addItem(item(visible ? "隱藏 Widget" : "顯示 Widget", #selector(toggleWidget), "w"))
        menu.addItem(item("編輯自選股…", #selector(openEditor), ","))
        menu.addItem(item("立即更新", #selector(refreshNow), "r"))
        menu.addItem(.separator())
        for layer in WindowLayer.allCases {
            let it = item(layer.label, #selector(setLayer(_:)), "")
            it.representedObject = layer.rawValue
            it.state = store.windowLayer == layer ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("結束", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func openEditor() { showEditor() }

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }

    @objc private func setLayer(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let layer = WindowLayer(rawValue: raw) {
            store.windowLayer = layer
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 編輯視窗

    func showEditor() {
        if editorWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(store: store)))
            window.title = "股票 Widget 設定"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 480, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            editorWindow = window
        }
        NSApp.activate()
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}
