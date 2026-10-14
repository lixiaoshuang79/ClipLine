import AppKit
import Carbon
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppDelegate.makeStore()
    private let settings = Settings.shared
    private var panel: LinePanel!
    private var pastePanel: PastePanel!
    private var revealHotKey: HotKey?
    private var screenTextHotKey: HotKey?
    /// 自检（CLIPLINE_OCR_RUN_DEBUG=script）走私有剪贴板，不动用户的剪贴板。
    private lazy var screenText = ScreenTextCapture(
        store: store,
        pasteboard: AppDelegate.selfTestDirectory == nil ? .general : NSPasteboard(name: .init("com.ashuang.clipline.selftest")))
    private static let selfTestDirectory: String? = {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPLINE_OCR_RUN_DEBUG"] == "script" else { return nil }
        return env["CLIPLINE_OCR_RUN_DIR"] ?? "/tmp/clipline-ocr-selftest"
    }()
    private let settingsWindow = SettingsWindowController()
    private var settingsObserver: AnyCancellable?
    private var styleObserver: AnyCancellable?
    private var openSettingsObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem!
    private var outsideMonitor: Any?
    private var orderOutWork: DispatchWorkItem?
    /// 唤出前的前台 App；粘贴时若我们自己成了前台就把它请回来。
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if OcrResultPanel.snapshotDemoIfRequested() { return }   // CLIPLINE_OCR_RESULT_SNAPSHOT=<目录>：确认卡各状态自截图
        panel = LinePanel(content: NSHostingView(rootView: LineView(store: store)))
        panel.placeOnScreen()
        pastePanel = PastePanel(content: NSHostingView(rootView: PastePanelView(store: store)))
        pastePanel.placeOnScreen()

        store.onRequestTuck = { [weak self] in self?.tuck() }
        store.onRequestPaste = { [weak self] item in self?.pasteAndTuck(item) }

        for board in [panel as ClipPanel, pastePanel as ClipPanel] {
            board.onEscape = { [weak self] in self?.store.escape() }
            board.onEnter = { [weak self] in self?.store.pasteSelected() }
            board.onLeft = { [weak self] in self?.store.select(offset: -1) }
            board.onRight = { [weak self] in self?.store.select(offset: 1) }
        }

        // 自检实例不抢全局热键（正在用的那份 ClipLine 还要用）。
        if Self.selfTestDirectory == nil { installHotKeys() }
        // 容量设置变化即时复评（立刻淘汰超出新上限的条目）。
        settingsObserver = settings.$maxItems.merge(with: settings.$imageBudgetMB)
            .dropFirst(2)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.updateRetention(self.settings.retention)
            }
        // 换面板样式：先把当前面板收起，下次唤出用新样式。
        styleObserver = settings.$panelStyle.dropFirst().sink { [weak self] _ in
            self?.store.activeBoardID = nil
            self?.tuck(immediate: true)
        }
        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .clipLineOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettings()
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
        store.updateRetention(settings.retention)
        Ocr.warmUp()
        ScreenTextCapture.warmUp()

        let env = ProcessInfo.processInfo.environment
        if env["CLIPLINE_DEMO"] == "1" { store.seedDemo() }
        // 调试：CLIPLINE_QUERY=<文字> 预填搜索词，便于不打字就目测搜索态。
        if let query = env["CLIPLINE_QUERY"], !query.isEmpty { store.replaceQuery(query) }
        if env["CLIPLINE_DEMO"] == "1" || env["CLIPLINE_SHOW"] == "1" { reveal() }
        // 调试：CLIPLINE_PANEL_PROBE=1（配 CLIPLINE_DEMO=1）跑一次面板交互回归，见 PanelProbe。
        if env["CLIPLINE_PANEL_PROBE"] == "1" {
            PanelProbe(store: store,
                       reveal: { [weak self] in self?.reveal() },
                       panel: { [weak self] in self?.activePanel }).run()
        }
        // 调试：CLIPLINE_SETTINGS=1 直接开设置窗口（截图/自查用）。
        if env["CLIPLINE_SETTINGS"] == "1" { openSettings() }
        // 调试：CLIPLINE_OCR_RUN_DEBUG=preflight 静默体检屏幕录制/辅助功能权限与抓屏尺寸链（不弹任何窗），
        // 结果写 /tmp/clipline-preflight.txt（只记数量与长度，不落屏上内容）。
        if env["CLIPLINE_OCR_RUN_DEBUG"] == "preflight" {
            let preflight = CGPreflightScreenCaptureAccess()
            let accessibility = AXIsProcessTrusted()
            Task {
                var report = "screenRecording=\(preflight) accessibility=\(accessibility)\n"
                if preflight {
                    report += await ScreenTextCapture.probe()
                } else {
                    report += "capture=未尝试（预检为假）\n"
                }
                try? report.write(to: URL(fileURLWithPath: "/tmp/clipline-preflight.txt"),
                                  atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        // 调试：CLIPLINE_OCR_RUN_DEBUG=script 无人值守走一遍屏幕取字全流程、逐状态截图
        // （存 CLIPLINE_OCR_RUN_DIR，默认 /tmp/clipline-ocr-selftest），结论见其中 report.txt。
        if let directory = Self.selfTestDirectory {
            let test = ScreenTextSelfTest(capture: screenText, store: store, directory: directory)
            Task { @MainActor in await test.run() }
        }
        FileHandle.standardError.write("ClipLine started, items=\(store.items.count)\n".data(using: .utf8)!)
        snapshotIfRequested()
    }

    // MARK: 热键

    private func installHotKeys() {
        revealHotKey = HotKey(spec: settings.revealHotKey) { [weak self] in
            guard let self else { return }
            self.store.revealed ? self.tuck() : self.reveal()
        }
        screenTextHotKey = HotKey(spec: settings.screenTextHotKey) { [weak self] in
            self?.screenText.begin()
        }
    }

    /// 换键：先注销旧的，注册失败就装回旧的并返回 false。
    private func applyHotKey(_ target: HotKeyTarget, _ spec: HotKey.Spec) -> Bool {
        switch target {
        case .reveal:
            let old = settings.revealHotKey
            revealHotKey?.unregister()
            if let hot = HotKey(spec: spec, action: { [weak self] in
                guard let self else { return }
                self.store.revealed ? self.tuck() : self.reveal()
            }) {
                revealHotKey = hot
                settings.revealHotKey = spec
                return true
            }
            revealHotKey = HotKey(spec: old, action: { [weak self] in
                guard let self else { return }
                self.store.revealed ? self.tuck() : self.reveal()
            })
            return false
        case .screenText:
            let old = settings.screenTextHotKey
            screenTextHotKey?.unregister()
            if let hot = HotKey(spec: spec, action: { [weak self] in self?.screenText.begin() }) {
                screenTextHotKey = hot
                settings.screenTextHotKey = spec
                return true
            }
            screenTextHotKey = HotKey(spec: old, action: { [weak self] in self?.screenText.begin() })
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let openSettingsObserver {
            NotificationCenter.default.removeObserver(openSettingsObserver)
        }
        store.close()
    }

    /// 演示模式只在内存里，绝不碰真实历史；CLIPLINE_STORE_DIR 可把存储指到别的目录（测试持久化用）。
    private static func makeStore() -> ClipStore {
        let env = ProcessInfo.processInfo.environment
        if env["CLIPLINE_DEMO"] == "1" { return ClipStore(archive: nil, note: "demo: memory only") }
        let directory = env["CLIPLINE_STORE_DIR"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? ClipArchive.defaultDirectory
        do {
            return ClipStore(archive: try ClipArchive(directory: directory))
        } catch {
            ClipStore.log("store unavailable at \(directory.path): \(error)")
            return ClipStore(archive: nil, note: "store unavailable, memory only")
        }
    }

    /// 调试：CLIPLINE_SNAPSHOT=<png 路径> 时，把面板窗口自身抓成图片后退出（自窗口捕获，无需屏幕录制权限）。
    private func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLIPLINE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["CLIPLINE_SNAPSHOT_DELAY"] ?? "") ?? 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let windowID = CGWindowID(self.activePanel.windowNumber)
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

    /// 当前生效的面板（设置里「面板样式」二选一；CLIPLINE_PANEL_STYLE 可临时覆盖）。
    private var activePanel: ClipPanel {
        settings.effectivePanelStyle == .paste ? pastePanel : panel
    }

    private func reveal() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == getpid()) ? nil : front
        // 绳式默认「全部」（含已归标签的条目，用搜索框旁的切换控件筛选）；底部面板默认剪贴板历史。
        store.defaultViewIncludesBoarded = settings.effectivePanelStyle != .paste
        let board = activePanel
        board.placeOnScreen()
        if store.selectedItem == nil { store.selectedID = store.shown.first?.id }
        store.revealed = true
        board.ignoresMouseEvents = false
        board.orderFrontRegardless()
        // 自截图调试时不抢键盘：否则前台 App 里正在打的字会落进搜索框。
        if ProcessInfo.processInfo.environment["CLIPLINE_SNAPSHOT"] == nil {
            board.makeKey()
            board.focusSearch()
        }
        installOutsideMonitor()
    }

    private func tuck(immediate: Bool = false) {
        guard store.revealed else { return }
        store.revealed = false
        removeOutsideMonitor()
        let board = activePanel   // 记住收起哪一块：等待期间换样式也把这块收干净
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.store.revealed else { return }
            board.ignoresMouseEvents = true
            board.orderOut(nil)
            // 每次展开都从完整列表开始；等滑出后再清，免得收起途中卡片重排。
            if self.store.fieldHasText || !self.store.query.isEmpty { self.store.replaceQuery("") }
        }
        orderOutWork?.cancel()
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.34), execute: work)
    }

    private func pasteAndTuck(_ item: ClipItem) {
        guard store.writeToPasteboard(item) else {
            tuck()
            return
        }
        tuck(immediate: true)
        guard settings.pasteAutomatically else { return }   // 只复制模式：不合成 ⌘V
        if let previousApp,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            previousApp.activate(options: [])
        }
        // 没有「辅助功能」权限时合成不了 ⌘V：第一次先说清原因（内容已在剪贴板，可手动 ⌘V），
        // 之后不再打扰——避免"点了卡片只弹一个看不懂的系统窗"。
        if !AXIsProcessTrusted(), !Self.explainedAccessibility {
            Self.explainedAccessibility = true
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "让 ClipLine 直接粘贴，需要「辅助功能」权限"
            alert.informativeText = """
            内容已经复制到剪贴板了，现在手动按 ⌘V 也能粘贴。

            想要"点卡片就自动粘贴"：打开 系统设置 → 隐私与安全性，向下滚动找到「辅助功能」（在「录屏与系统录音」下面几行，别开错），把 ClipLine 打开，然后重启本应用。
            """
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "知道了")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Paster.synthesizePaste()
    }

    /// 辅助功能说明弹窗每次启动只弹一次。
    private static var explainedAccessibility = false

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
        let toggle = NSMenuItem(title: "显示 / 隐藏剪贴板绳（\(settings.revealHotKey.display)）",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let ocr = NSMenuItem(title: "屏幕取字…（\(settings.screenTextHotKey.display)）",
                             action: #selector(screenTextFromMenu), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)
        menu.addItem(.separator())
        menu.autoenablesItems = false
        let clear = NSMenuItem(title: "清空历史…", action: #selector(confirmClearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = store.clearableCount > 0
        menu.addItem(clear)
        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

    @objc private func screenTextFromMenu() {
        screenText.begin()
    }

    @objc private func openSettings() {
        // 面板浮在普通窗口之上（底部样式在 Dock 层之上），不收起会压住居中的设置窗口。
        tuck(immediate: true)
        settingsWindow.show(settings: settings) { [weak self] target, spec in
            self?.applyHotKey(target, spec) ?? false
        }
    }

    @objc private func toggleFromMenu() {
        store.revealed ? tuck() : reveal()
    }

    @objc private func confirmClearHistory() {
        tuck(immediate: true)
        NSApp.activate()
        let doomedCount = store.clearableCount
        let keptCount = store.items.count - doomedCount
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空剪贴板历史？"
        if keptCount > 0 {
            alert.informativeText = "将删除 \(doomedCount) 条记录（含本机磁盘上的内容）；\(keptCount) 条已置顶或已归入标签的会保留。此操作无法撤销。"
        } else {
            alert.informativeText = "将删除全部 \(doomedCount) 条记录，包括保存在本机磁盘上的内容。此操作无法撤销。"
        }
        alert.addButton(withTitle: "清空").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if LaunchAtLogin.isEnabled {
                LaunchAtLogin.disable()
            } else {
                try LaunchAtLogin.enable()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "设置「登录时启动」失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func openAccessibilityPane() {
        Paster.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
