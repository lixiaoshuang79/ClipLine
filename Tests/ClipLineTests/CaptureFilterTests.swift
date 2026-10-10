import AppKit
import XCTest
@testable import ClipLine

/// 用私有命名剪贴板测试捕获，不碰系统剪贴板。
final class CaptureFilterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ashuang.clipline.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func write(_ types: [NSPasteboard.PasteboardType: Data]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
    }

    func testConcealedAndTransientAreDropped() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            write([.string: Data("hunter2".utf8), NSPasteboard.PasteboardType(marker): Data()])
            XCTAssertNil(ClipItem.capture(from: pasteboard), marker)
        }
    }

    func testPlainTextIsCapturedWithSnapshot() throws {
        write([.string: Data("hello".utf8)])
        let item = try XCTUnwrap(ClipItem.capture(from: pasteboard))
        XCTAssertEqual(item.fingerprint, "t:hello")
        XCTAssertEqual(item.snapshot?.first?[.string], Data("hello".utf8))
        XCTAssertEqual(item.bytes, 5)
    }
}
