import AppKit
import Carbon
import SwiftUI

/// 设置里的两把全局热键。
enum HotKeyTarget {
    case reveal
    case screenText
}

/// 设置窗口内容：快捷键、屏幕取字、粘贴、历史容量。
struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// 由 AppDelegate 注入：尝试注册新热键；失败（组合被占用）返回 false。
    let applyHotKey: (HotKeyTarget, HotKey.Spec) -> Bool
    @State private var hotKeyError: String?

    var body: some View {
        Form {
            Section("快捷键") {
                HotKeyRow(title: "唤出剪贴板绳", spec: settings.revealHotKey) { commit($0, .reveal) }
                HotKeyRow(title: "屏幕取字", spec: settings.screenTextHotKey) { commit($0, .screenText) }
                if let hotKeyError {
                    Text(hotKeyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Section("面板样式") {
                Picker("样式", selection: $settings.panelStyle) {
                    Text("晾衣绳（顶部）").tag(Settings.PanelStyle.rope)
                    Text("底部卡片（Paste 式）").tag(Settings.PanelStyle.paste)
                }
                Text(settings.panelStyle == .rope
                     ? "按 ⌃⌥V 从菜单栏下方垂下绳与卡片。"
                     : "底部悬浮面板：横向大卡、来源色头部，参照 Paste 的快捷面板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("屏幕取字") {
                Picker("识别主语言", selection: $settings.ocrPrimaryLanguage) {
                    ForEach(Settings.ocrLanguageOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Toggle("结果去掉换行", isOn: $settings.ocrRemoveBreaks)
                Text("识别用 Vision 在本机完成，不联网。放行的文字会直接进入剪贴板和历史。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("粘贴") {
                Toggle("点卡片后自动粘贴", isOn: $settings.pasteAutomatically)
                Text(settings.pasteAutomatically
                     ? "需要「辅助功能」权限；未授权时自动退回只复制。"
                     : "关：点卡片只复制到剪贴板，自己按 ⌘V。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("历史容量") {
                Picker("条数上限", selection: $settings.maxItems) {
                    ForEach([100, 300, 500, 1000, 2000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Picker("图片总预算", selection: $settings.imageBudgetMB) {
                    ForEach([128, 256, 512, 1024], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Text("超出后先淘汰最旧的；置顶条目不参与淘汰。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 500)
    }

    private func commit(_ spec: HotKey.Spec, _ target: HotKeyTarget) {
        if applyHotKey(target, spec) {
            hotKeyError = nil
        } else {
            hotKeyError = "「\(spec.display)」已被系统或其他 App 占用，换一个组合。"
        }
    }
}

private struct HotKeyRow: View {
    let title: String
    let spec: HotKey.Spec
    let onCommit: (HotKey.Spec) -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HotKeyRecorder(spec: spec, onCommit: onCommit)
        }
    }
}

/// 点一下进入录制态，按一个「修饰键 + 键」的组合即提交；Esc 取消。
struct HotKeyRecorder: NSViewRepresentable {
    let spec: HotKey.Spec
    let onCommit: (HotKey.Spec) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onCommit = onCommit
        field.spec = spec
        return field
    }

    func updateNSView(_ view: RecorderField, context: Context) {
        view.onCommit = onCommit
        view.spec = spec
    }
}

final class RecorderField: NSView {
    var onCommit: ((HotKey.Spec) -> Void)?
    var spec: HotKey.Spec = Settings.defaultReveal {
        didSet { needsDisplay = true }
    }
    private var recording = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 26) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            recording = false
            return
        }
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        guard modifiers != 0 else {   // 至少一个修饰键，免得把普通按键吞掉
            NSSound.beep()
            return
        }
        onCommit?(HotKey.Spec(keyCode: Int(event.keyCode), modifiers: modifiers))
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                   : NSColor.quaternarySystemFill).setFill()
        box.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.lineWidth = recording ? 1.5 : 1
        box.stroke()

        let text = recording ? "按下新组合…" : spec.display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.shift) { out |= shiftKey }
        if flags.contains(.command) { out |= cmdKey }
        return out
    }
}

/// 设置窗口的持有者：AppDelegate 用它开关单例窗口。
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: Settings, applyHotKey: @escaping (HotKeyTarget, HotKey.Spec) -> Bool) {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(settings: settings, applyHotKey: applyHotKey))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipLine 设置"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
