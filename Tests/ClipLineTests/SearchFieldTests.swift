import AppKit
import XCTest
@testable import ClipLine

/// 用真实的 NSTextField + 字段编辑器模拟输入法组字（不显示窗口、不发系统按键）。
final class SearchFieldTests: XCTestCase {
    private var window: NSWindow!
    private var field: ClipSearchField!
    private var coordinator: SearchField.Coordinator!
    private var store: ClipStore!

    override func setUp() {
        store = ClipStore(archive: nil)
        store.ingest(ClipArchiveTests.text("拼音 ni hao", ago: 2))
        store.ingest(ClipArchiveTests.text("你好世界", ago: 1))
        coordinator = SearchField.Coordinator(store: store)
        field = ClipSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        field.delegate = coordinator
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
    }

    override func tearDown() {
        window.close()
    }

    private var editor: NSTextView { field.currentEditor() as! NSTextView }

    func testMarkedTextDoesNotFilterUntilCommitted() {
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(store.query, "", "拼音组字中不参与过滤")
        XCTAssertEqual(store.shown.count, 2)

        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(store.query, "你好")
        XCTAssertEqual(store.shown.count, 1)
        XCTAssertTrue(store.fieldHasText)
    }

    func testArrowKeysGoToInputMethodWhileComposing() {
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        editor.unmarkText()
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor,
                                           doCommandBy: #selector(NSResponder.moveLeftAndModifySelection(_:))),
                       "⇧← 照常扩选")
    }

    func testExternalClearKeepsEditing() {
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(store.shown.count, 1)
        store.escape()
        coordinator.sync(field, revision: store.fieldRevision)
        XCTAssertNotNil(field.currentEditor(), "清除后焦点仍在搜索框")
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(store.shown.count, 2)
    }
}
