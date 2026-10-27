import AppKit
import ApplicationServices
import Carbon

enum Paster {
    /// 把快照按原始类型写回剪贴板。
    static func copyToPasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard = .general) {
        pb.clearContents()
        let objects: [NSPasteboardItem] = snapshot.map { map in
            let object = NSPasteboardItem()
            for (type, data) in map { object.setData(data, forType: type) }
            return object
        }
        pb.writeObjects(objects)
    }

    /// 面板收起后调用：让当前前台 App 粘贴一次。
    ///
    /// 密码框（NSSecureTextField、浏览器密码输入、HTTP 认证弹窗）会打开系统的「安全输入」，
    /// 此时会话级合成按键和按进程投递的按键都会被系统丢弃，唯一能走通的是用辅助功能
    /// 去按目标 App 的「编辑 › 粘贴」菜单项——它不是按键，不受安全输入影响。
    static func synthesizePaste(targetPID: pid_t? = nil) {
        guard AXIsProcessTrusted() else {
            requestTrust()
            return
        }
        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let secureInput = IsSecureEventInputEnabled()
        debugLog("paste: secureInput=\(secureInput) target=\(pid) name=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if secureInput, pressPasteMenuItem(pid: pid) {
                debugLog("paste: menu press ok pid=\(pid)")
                return
            }
            debugLog("paste: post ⌘V (secureInput=\(secureInput))")
            postCommandV()
        }
    }

    private static func debugLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["CLIPLINE_DEBUG"] == "1" else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        let path = "/tmp/clipline-paste-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 抑制期里只放行鼠标与系统事件，免得这次合成被自己的进程吃掉（Maccy 的做法）。
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        // 0x000008 是“修饰键已被按下”的设备位，部分 App 靠它才认合成快捷键（Flycut PR#18 / Maccy）。
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),   // 9 = V
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: 辅助功能「粘贴」菜单项

    /// 按目标 App 的「编辑 › 粘贴」菜单项；按到了返回 true。
    static func pressPasteMenuItem(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let barRaw = copyAttribute(app, kAXMenuBarAttribute),
              let topRaw = copyAttribute(barRaw as! AXUIElement, kAXChildrenAttribute),
              let menus = topRaw as? [AXUIElement] else { return false }
        // 「编辑」菜单优先；语言不认识时全扫一遍，靠 ⌘V 快捷键属性认。
        let editTitles: Set<String> = ["edit", "编辑", "編輯", "bearbeiten", "edition", "edición",
                                       "modifica", "編集", "편집", "bewerken"]
        let preferred = menus.filter { editTitles.contains((copyAttribute($0, kAXTitleAttribute) as? String ?? "").lowercased()) }
        let preferredIDs = Set(preferred.map(ObjectIdentifier.init))
        let ordered = preferred + menus.filter { !preferredIDs.contains(ObjectIdentifier($0)) }
        for menu in ordered {
            guard let itemsRaw = copyAttribute(menu, kAXChildrenAttribute),
                  let submenu = (itemsRaw as? [AXUIElement])?.first,
                  let entriesRaw = copyAttribute(submenu, kAXChildrenAttribute) else { continue }
            for item in (entriesRaw as? [AXUIElement]) ?? [] {
                guard isPasteMenuItem(
                    cmdChar: copyAttribute(item, kAXMenuItemCmdCharAttribute) as? String,
                    cmdModifiers: copyAttribute(item, kAXMenuItemCmdModifiersAttribute) as? Int,
                    title: copyAttribute(item, kAXTitleAttribute) as? String) else { continue }
                if let enabled = copyAttribute(item, kAXEnabledAttribute) as? Bool, !enabled { continue }
                if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return true }
            }
        }
        return false
    }

    /// 菜单项是不是「粘贴」。快捷键属性与界面语言无关，是首选依据；有的 App 不暴露快捷键，
    /// 此时退回标题精确匹配（「粘贴并匹配样式」这类复合项不能被误认）。
    static func isPasteMenuItem(cmdChar: String?, cmdModifiers: Int?, title: String?) -> Bool {
        if let cmdChar, !cmdChar.isEmpty, let cmdModifiers {
            return cmdChar.lowercased() == "v" && cmdModifiers == 0
        }
        guard let title else { return false }
        return pasteTitles.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static let pasteTitles: Set<String> = [
        "paste", "粘贴", "粘貼", "貼上", "einfügen", "coller", "pegar", "incolla",
        "貼り付け", "붙여넣기", "plakken", "klistra in",
    ]

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
