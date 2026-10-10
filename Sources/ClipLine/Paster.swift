import AppKit
import ApplicationServices
import Carbon

enum Paster {
    /// 把条目按原始类型写回剪贴板。
    static func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objects: [NSPasteboardItem] = item.snapshot.map { map in
            let object = NSPasteboardItem()
            for (type, data) in map { object.setData(data, forType: type) }
            return object
        }
        pb.writeObjects(objects)
    }

    /// 面板收起后调用：向当前前台 App 合成一次 ⌘V。
    static func synthesizePaste() {
        guard AXIsProcessTrusted() else {
            requestTrust()
            return
        }
        // 密码框等 secure input 场景：系统会丢弃合成事件，此时只把内容留在剪贴板里。
        guard !IsSecureEventInputEnabled() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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
    }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
