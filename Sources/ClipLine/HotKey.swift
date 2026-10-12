import AppKit
import Carbon

/// 全局快捷键（Carbon hot key API，注册不需要辅助功能权限）。
/// 支持多实例（各自独立回调）与随时改键：改键 = 注销旧的、注册新的。
final class HotKey {
    /// 键位 + 修饰键（Carbon 掩码：controlKey / optionKey / shiftKey / cmdKey）。
    struct Spec: Equatable {
        var keyCode: Int
        var modifiers: Int

        /// "⌃⌥V" 样式的展示串。
        var display: String { Spec.modifierSymbols(modifiers) + Spec.keyName(keyCode) }

        static func modifierSymbols(_ modifiers: Int) -> String {
            var out = ""
            if modifiers & controlKey != 0 { out += "⌃" }
            if modifiers & optionKey != 0 { out += "⌥" }
            if modifiers & shiftKey != 0 { out += "⇧" }
            if modifiers & cmdKey != 0 { out += "⌘" }
            return out
        }

        /// 常见按键的显示名（macOS 虚拟键码）。
        static let keyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 43: ",", 44: "/", 42: "\\", 47: ".", 50: "`",
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]

        static func keyName(_ keyCode: Int) -> String {
            keyNames[keyCode] ?? "键\(keyCode)"
        }
    }

    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private let id: UInt32

    /// 注册失败（组合无效/被系统或其他 App 占用）时返回 nil。
    init?(spec: Spec, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: id)   // "CLIP"
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        Self.handlers[id] = action
        self.id = id
        self.ref = ref
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        Self.handlers[id] = nil
    }

    deinit { unregister() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &eventSpec, nil, nil)
    }
}
