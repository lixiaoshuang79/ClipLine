import XCTest
import Carbon
@testable import ClipLine

final class SettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "clipline-tests-\(UUID().uuidString)")!
    }

    func testDefaultsWhenEmpty() {
        let settings = Settings(defaults: freshDefaults())
        XCTAssertEqual(settings.revealHotKey, Settings.defaultReveal)
        XCTAssertEqual(settings.screenTextHotKey, Settings.defaultScreenText)
        XCTAssertTrue(settings.pasteAutomatically)
        XCTAssertEqual(settings.ocrPrimaryLanguage, "zh-Hans")
        XCTAssertTrue(settings.ocrRemoveBreaks)
        XCTAssertEqual(settings.maxItems, 500)
        XCTAssertEqual(settings.imageBudgetMB, 256)
        XCTAssertEqual(settings.panelStyle, .rope)
    }

    func testRoundTrip() {
        let defaults = freshDefaults()
        let settings = Settings(defaults: defaults)
        settings.revealHotKey = HotKey.Spec(keyCode: 15, modifiers: cmdKey | shiftKey)
        settings.maxItems = 1000
        settings.ocrRemoveBreaks = false
        settings.ocrPrimaryLanguage = "ja-JP"
        settings.panelStyle = .paste

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.panelStyle, .paste)
        XCTAssertEqual(reloaded.revealHotKey, HotKey.Spec(keyCode: 15, modifiers: cmdKey | shiftKey))
        XCTAssertEqual(reloaded.maxItems, 1000)
        XCTAssertFalse(reloaded.ocrRemoveBreaks)
        XCTAssertEqual(reloaded.ocrPrimaryLanguage, "ja-JP")
    }

    func testHotKeyDisplay() {
        XCTAssertEqual(HotKey.Spec(keyCode: 9, modifiers: controlKey | optionKey).display, "⌃⌥V")
        XCTAssertEqual(HotKey.Spec(keyCode: 31, modifiers: controlKey | optionKey).display, "⌃⌥O")
        XCTAssertEqual(HotKey.Spec(keyCode: 15, modifiers: cmdKey | shiftKey).display, "⇧⌘R")
        XCTAssertEqual(HotKey.Spec(keyCode: 49, modifiers: optionKey).display, "⌥空格")
    }

    func testOcrLanguagesPutPrimaryFirst() {
        let settings = Settings(defaults: freshDefaults())
        settings.ocrPrimaryLanguage = "ja-JP"
        XCTAssertEqual(settings.ocrLanguages, ["ja-JP", "en-US"])
        settings.ocrPrimaryLanguage = "en-US"
        XCTAssertEqual(settings.ocrLanguages, ["en-US"])
    }

    func testRetentionFollowsSettings() {
        let settings = Settings(defaults: freshDefaults())
        settings.maxItems = 100
        settings.imageBudgetMB = 128
        XCTAssertEqual(settings.retention.maxItems, 100)
        XCTAssertEqual(settings.retention.imageBudget, 128 << 20)
    }

    func testRemoveBreaksJoinsCJK() {
        XCTAssertEqual(Ocr.removeBreaks("这是一句被排版\n折行的中文。"), "这是一句被排版折行的中文。")
    }

    func testRemoveBreaksKeepsParagraphs() {
        XCTAssertEqual(Ocr.removeBreaks("第一段。\n\n第二段。"), "第一段。\n\n第二段。")
    }

    func testRemoveBreaksJoinsLowercaseLatin() {
        XCTAssertEqual(Ocr.removeBreaks("the quick brown\nfox jumps"), "the quick brown fox jumps")
    }

    func testRemoveBreaksKeepsSentenceStarts() {
        XCTAssertEqual(Ocr.removeBreaks("done.\nNext one"), "done.\nNext one")
    }

    func testRemoveBreaksHyphenJoin() {
        XCTAssertEqual(Ocr.removeBreaks("inter-\nnational"), "international")
    }

    func testScreenTextSourceRoundTrip() {
        XCTAssertEqual(ClipSource.screenText.storageKind, "screenText")
        let restored = ClipSource.restore(kind: "screenText", bundleID: nil, name: "")
        XCTAssertEqual(restored.kind, .screenText)
        XCTAssertEqual(restored.footnote, "屏幕取字")
    }
}
