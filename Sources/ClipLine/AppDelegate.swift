import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipStore()
    private var panel: LinePanel!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var outsideMonitor: Any?
    private var orderOutWork: DispatchWorkItem?
    /// 唤出前的前台 App；粘贴时若我们自己成了前台就把它请回来。
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = NSHostingView(rootView: LineView(store: store))
        panel = LinePanel(content: view)
        panel.placeOnScreen()

        store.onRequestTuck = { [weak self] in self?.tuck() }
        store.onRequestPaste = { [weak self] item in self?.pasteAndTuck(item) }

        panel.onEscape = { [weak self] in self?.tuck() }
        panel.onEnter = { [weak self] in
            guard let self, let item = self.store.selectedItem else { return }
            self.pasteAndTuck(item)
        }
        panel.onLeft = { [weak self] in self?.store.select(offset: -1) }
        panel.onRight = { [weak self] in self?.store.select(offset: 1) }

        // ⌃⌥V（keyCode 9 = V）
        hotKey = HotKey(keyCode: 9, modifiers: controlKey | optionKey) { [weak self] in
            guard let self else { return }
            self.store.revealed ? self.tuck() : self.reveal()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipLine")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.start()

        let env = ProcessInfo.processInfo.environment
        if env["CLIPLINE_DEMO"] == "1" { store.seedDemo() }
        if env["CLIPLINE_DEMO"] == "1" || env["CLIPLINE_SHOW"] == "1" { reveal() }
        FileHandle.standardError.write("ClipLine started, items=\(store.items.count)\n".data(using: .utf8)!)
        snapshotIfRequested()
    }

    /// 调试：CLIPLINE_SNAPSHOT=<png 路径> 时，把面板窗口自身抓成图片后退出（自窗口捕获，无需屏幕录制权限）。
    private func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLIPLINE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["CLIPLINE_SNAPSHOT_DELAY"] ?? "") ?? 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let windowID = CGWindowID(self.panel.windowNumber)
            guard windowID > 0,
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                       [.boundsIgnoreFraming, .bestResolution]) else {
                FileHandle.standardError.write("snapshot: capture failed (windowID=\(windowID))\n".data(using: .utf8)!)
                NSApp.terminate(nil)
                return
            }
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write("snapshot: wrote \(path) \(data.count) bytes\n".data(using: .utf8)!)
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: 面板显隐

    private func reveal() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == getpid()) ? nil : front
        panel.placeOnScreen()
        if store.selectedItem == nil { store.selectedID = store.items.first?.id }
        store.revealed = true
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        installOutsideMonitor()
    }

    private func tuck(immediate: Bool = false) {
        guard store.revealed else { return }
        store.revealed = false
        removeOutsideMonitor()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.store.revealed else { return }
            self.panel.ignoresMouseEvents = true
            self.panel.orderOut(nil)
        }
        orderOutWork?.cancel()
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.34), execute: work)
    }

    private func pasteAndTuck(_ item: ClipItem) {
        store.writeToPasteboard(item)
        tuck(immediate: true)
        if let previousApp,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp.activate(options: [])
        }
        Paster.synthesizePaste()
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.tuck()
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    // MARK: 状态栏菜单

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            store.revealed ? tuck() : reveal()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示 / 隐藏剪贴板绳（⌃⌥V）",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let ax = NSMenuItem(title: "辅助功能权限…", action: #selector(openAccessibilityPane), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 ClipLine",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleFromMenu() {
        store.revealed ? tuck() : reveal()
    }

    @objc private func openAccessibilityPane() {
        Paster.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
