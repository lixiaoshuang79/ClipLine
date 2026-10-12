import AppKit
import XCTest
@testable import ClipLine

/// 屏幕取字的纯逻辑：选区几何、定格画面裁切换算、读数摆位、确认卡预览、去换行。
final class ScreenTextTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

    func testSelectionNormalizesDragDirection() {
        let rect = SelectionGeometry.rect(from: NSPoint(x: 300, y: 100), to: NSPoint(x: 100, y: 250),
                                          within: screen, scale: 2)
        XCTAssertEqual(rect, NSRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testSelectionClampsToScreen() {
        let rect = SelectionGeometry.rect(from: NSPoint(x: -40, y: 900), to: NSPoint(x: 80, y: 1200),
                                          within: screen, scale: 2)
        XCTAssertEqual(rect, NSRect(x: 0, y: 900, width: 80, height: 82))
    }

    func testSelectionSnapsToDevicePixels() {
        let rect = SelectionGeometry.rect(from: NSPoint(x: 10.3, y: 10.8), to: NSPoint(x: 20.1, y: 30.2),
                                          within: screen, scale: 2)
        XCTAssertEqual(rect, NSRect(x: 10.5, y: 11, width: 9.5, height: 19))
    }

    /// 视图是左下原点、单位点；定格画面是左上原点、单位像素。
    func testPixelRectFlipsAndScales() {
        let pixel = SelectionGeometry.pixelRect(for: NSRect(x: 100, y: 800, width: 200, height: 82),
                                                viewSize: screen.size, imageSize: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(pixel, CGRect(x: 200, y: 200, width: 400, height: 164))
    }

    func testPixelRectOnOneXDisplay() {
        let pixel = SelectionGeometry.pixelRect(for: NSRect(x: 10, y: 20, width: 30, height: 40),
                                                viewSize: NSSize(width: 1920, height: 1080),
                                                imageSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(pixel, CGRect(x: 10, y: 1020, width: 30, height: 40))
    }

    func testPixelRectClipsToImage() {
        let pixel = SelectionGeometry.pixelRect(for: NSRect(x: 1500, y: 0, width: 50, height: 10),
                                                viewSize: screen.size, imageSize: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(pixel, CGRect(x: 3000, y: 1944, width: 24, height: 20))
    }

    func testReadoutSitsBottomRightOfPointer() {
        let origin = SelectionGeometry.readoutOrigin(pointer: NSPoint(x: 500, y: 500),
                                                     size: NSSize(width: 30, height: 28), bounds: screen)
        XCTAssertEqual(origin, NSPoint(x: 510, y: 462))
    }

    func testReadoutFlipsNearRightAndBottomEdges() {
        let origin = SelectionGeometry.readoutOrigin(pointer: NSPoint(x: 1505, y: 8),
                                                     size: NSSize(width: 30, height: 28), bounds: screen)
        XCTAssertEqual(origin, NSPoint(x: 1465, y: 18))
    }

    func testCardPreviewFlattensLines() {
        XCTAssertEqual(OcrResultPanel.preview("  第一行 \n\n second line\n第三行  "), "第一行 second line 第三行")
        XCTAssertEqual(OcrResultPanel.preview(String(repeating: "字", count: 500)).count, 200)
    }

    func testJoinLinesCutsEveryBreak() {
        XCTAssertEqual(Ocr.joinLines("温柔地生成\n一段文字"), "温柔地生成一段文字")
        XCTAssertEqual(Ocr.joinLines("一段文字\nShottr style"), "一段文字 Shottr style")
        XCTAssertEqual(Ocr.joinLines("这是一句话。\n下一句"), "这是一句话。下一句")
        XCTAssertEqual(Ocr.joinLines("self-\ntest done.\nNext line"), "selftest done. Next line")
        XCTAssertEqual(Ocr.joinLines("a\n\n  \nb"), "a b")
        XCTAssertEqual(Ocr.joinLines("单行"), "单行")
    }
}
