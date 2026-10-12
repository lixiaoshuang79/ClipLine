import AppKit
import Carbon
import Combine

/// 用户偏好：落 UserDefaults，改动即时生效（热键重注册、容量立即复评）。
final class Settings: ObservableObject {
    static let shared = Settings()

    /// 唤出/收起剪贴板绳，默认 ⌃⌥V。
    @Published var revealHotKey: HotKey.Spec { didSet { save(revealHotKey, "revealHotKey") } }
    /// 屏幕取字，默认 ⌃⌥O。
    @Published var screenTextHotKey: HotKey.Spec { didSet { save(screenTextHotKey, "screenTextHotKey") } }
    /// 点卡片后是否自动合成 ⌘V（关掉 = 只复制到剪贴板）。
    @Published var pasteAutomatically: Bool { didSet { defaults.set(pasteAutomatically, forKey: "pasteAutomatically") } }
    /// OCR 主语言（对齐 Shottr 的做法：主语言在前、英语兜底）。
    @Published var ocrPrimaryLanguage: String { didSet { defaults.set(ocrPrimaryLanguage, forKey: "ocrPrimaryLanguage") } }
    /// OCR 结果去掉换行（把被排版折行的句子接回去）。
    @Published var ocrRemoveBreaks: Bool { didSet { defaults.set(ocrRemoveBreaks, forKey: "ocrRemoveBreaks") } }
    /// 历史上限条数。
    @Published var maxItems: Int { didSet { defaults.set(maxItems, forKey: "maxItems") } }
    /// 图片总预算（MB）。
    @Published var imageBudgetMB: Int { didSet { defaults.set(imageBudgetMB, forKey: "imageBudgetMB") } }

    static let defaultReveal = HotKey.Spec(keyCode: 9, modifiers: controlKey | optionKey)    // ⌃⌥V
    static let defaultScreenText = HotKey.Spec(keyCode: 31, modifiers: controlKey | optionKey) // ⌃⌥O

    /// OCR 主语言选项（对齐 Shottr 的选择面）。
    static let ocrLanguageOptions: [(id: String, label: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en-US", "English"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("ru-RU", "Русский"),
        ("de-DE", "Deutsch"), ("fr-FR", "Français"), ("es-ES", "Español"),
        ("it-IT", "Italiano"), ("pt-BR", "Português"), ("vi-VT", "Tiếng Việt"),
        ("th-TH", "ไทย"), ("tr-TR", "Türkçe"), ("uk-UA", "Українська"),
        ("ar-SA", "العربية"),
    ]

    /// 交给 Vision 的语言列表：主语言在前，英语兜底。
    var ocrLanguages: [String] {
        var list = [ocrPrimaryLanguage]
        if ocrPrimaryLanguage != "en-US" { list.append("en-US") }
        return list
    }

    /// 当前容量策略（条数/图片预算即时生效）。
    var retention: Retention {
        Retention(maxItems: maxItems, imageBudget: imageBudgetMB << 20, maxStoredBytes: 64 << 20)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        revealHotKey = Self.load(defaults, "revealHotKey") ?? Self.defaultReveal
        screenTextHotKey = Self.load(defaults, "screenTextHotKey") ?? Self.defaultScreenText
        pasteAutomatically = defaults.object(forKey: "pasteAutomatically") as? Bool ?? true
        ocrPrimaryLanguage = defaults.string(forKey: "ocrPrimaryLanguage") ?? "zh-Hans"
        ocrRemoveBreaks = defaults.object(forKey: "ocrRemoveBreaks") as? Bool ?? true
        maxItems = defaults.object(forKey: "maxItems") as? Int ?? 500
        imageBudgetMB = defaults.object(forKey: "imageBudgetMB") as? Int ?? 256
    }

    private func save(_ spec: HotKey.Spec, _ key: String) {
        defaults.set(["keyCode": spec.keyCode, "modifiers": spec.modifiers], forKey: key)
    }

    private static func load(_ defaults: UserDefaults, _ key: String) -> HotKey.Spec? {
        guard let dict = defaults.dictionary(forKey: key),
              let code = dict["keyCode"] as? Int, let modifiers = dict["modifiers"] as? Int else { return nil }
        return HotKey.Spec(keyCode: code, modifiers: modifiers)
    }
}
