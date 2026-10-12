import AppKit
import SwiftUI

/// 绳下方的搜索胶囊：面板展开后直接打字就过滤。平时是一枚安静的提示，有字后加宽并显示命中条数与清除钮。
struct SearchCapsule: View {
    @ObservedObject var store: ClipStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = CardPalette.of(.unknown, scheme: scheme)
        let typing = store.fieldHasText
        let searching = !store.search.isEmpty
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(typing ? p.ink2 : p.ink3)
            SearchField(store: store, ink: p.ink, placeholder: p.ink3)
                .frame(height: 17)
            if searching {
                Text(store.shown.isEmpty ? "无结果" : "\(store.shown.count) 条")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(p.ink3)
                    .fixedSize()
                    .transition(.opacity)
            }
            if typing {
                Button { store.replaceQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(p.ink3)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("清除搜索（Esc）")
                .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, typing ? 8 : 12)
        .frame(width: typing ? Layout.searchWidth : Layout.searchIdleWidth, height: Layout.searchHeight)
        .background {
            // 点胶囊空白处不该穿透到底下的"点空白收起"。
            Capsule().fill(Color.clear).contentShape(Capsule()).onTapGesture {}
        }
        .glassFrame(capsule: true, material: .regularMaterial)
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 10, y: 4)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: typing)
        .animation(.easeOut(duration: 0.15), value: searching)
    }
}

/// 真正的 `NSTextField`：拼音等输入法的组字、候选窗都走系统文本输入，不自己拼按键。
/// 只在没有组字时接管 ← → / 回车 / Esc；组字期间这些键归输入法（选候选、上屏、取消）。
struct SearchField: NSViewRepresentable {
    @ObservedObject var store: ClipStore
    let ink: Color
    let placeholder: Color
    /// 占位文案；底部面板的顶栏只要图标不要文字时传空串。
    var placeholderText: String = "输入即可搜索"

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> ClipSearchField {
        let field = ClipSearchField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: ClipSearchField, context: Context) {
        field.textColor = NSColor(ink)
        field.placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: [
            .foregroundColor: NSColor(placeholder),
            .font: field.font ?? .systemFont(ofSize: 13),
        ])
        context.coordinator.sync(field, revision: store.fieldRevision)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let store: ClipStore
        private var revision = 0

        init(store: ClipStore) {
            self.store = store
        }

        /// 搜索词被外部改写（Esc 清除、收起后复位）时，把文字推回输入框，并丢掉未上屏的组字。
        func sync(_ field: NSTextField, revision: Int) {
            guard revision != self.revision else { return }
            self.revision = revision
            guard let editor = field.currentEditor() as? NSTextView else {
                field.stringValue = store.query
                return
            }
            // 正在编辑时改字段编辑器本身：改 stringValue 会中止编辑、丢掉焦点。
            if editor.hasMarkedText() {
                editor.inputContext?.discardMarkedText()
                editor.unmarkText()
            }
            editor.string = store.query
            editor.selectedRange = NSRange(location: (store.query as NSString).length, length: 0)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            let text = editor.string as NSString
            var committed = text as String
            if editor.hasMarkedText() {
                let marked = editor.markedRange()
                if marked.location != NSNotFound, NSMaxRange(marked) <= text.length {
                    committed = text.replacingCharacters(in: marked, with: "")
                }
            }
            store.fieldChanged(committed: committed, hasText: text.length > 0)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveLeft(_:)): store.select(offset: -1)
            case #selector(NSResponder.moveRight(_:)): store.select(offset: 1)
            case #selector(NSResponder.insertNewline(_:)): store.pasteSelected()
            case #selector(NSResponder.cancelOperation(_:)): store.escape()
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                break   // 焦点不离开搜索框
            default:
                return false   // ⇧← / ⌥← / ⌘← 等照常移动光标、扩选
            }
            return true
        }
    }
}

final class ClipSearchField: NSTextField {
    /// 文字用具体颜色，不跟材质做 vibrancy 混合（同卡面规则）。
    override var allowsVibrancy: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ClipPanel)?.adopt(searchField: self)
    }
}
