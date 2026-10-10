import AppKit
import XCTest
@testable import ClipLine

final class OcrTests: XCTestCase {
    private func imageItem() -> ClipItem {
        ClipItem(kind: .image(NSImage(), pixelSize: CGSize(width: 100, height: 60)), source: .unknown,
                 copiedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 snapshot: [[.png: Data([1, 2, 3])]], fingerprint: "i:ocr")
    }

    func testOcrTextJoinsSearch() {
        var item = imageItem()
        XCTAssertFalse(SearchQuery("发票").matches(item))
        item.setOcr("这是一张 2026 年 10 月的发票")
        XCTAssertTrue(SearchQuery("发票").matches(item))
        XCTAssertTrue(SearchQuery("2026 发票").matches(item))
        XCTAssertFalse(SearchQuery("发票 合同").matches(item))
    }

    func testEmptyOcrNormalizesToNil() {
        var item = imageItem()
        item.setOcr("")
        XCTAssertNil(item.ocrText)
        XCTAssertNil(item.ocrFolded)
        item.setOcr("文字")
        XCTAssertNotNil(item.ocrFolded)
        item.setOcr(nil)
        XCTAssertNil(item.ocrText)
        XCTAssertNil(item.ocrFolded)
    }

    func testOcrRoundTripThroughArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipline-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = imageItem()
        item.setOcr("发票号 12345")
        let archive = try ClipArchive(directory: directory)
        try archive.insert(XCTUnwrap(item.record))
        let records = try archive.loadRecords()
        XCTAssertEqual(records.first?.ocrText, "发票号 12345")
        let restored = ClipItem(record: records[0], image: (thumb: NSImage(), pixelSize: CGSize(width: 10, height: 10)))
        XCTAssertEqual(restored?.ocrText, "发票号 12345")
        let roundTripped = try XCTUnwrap(restored)
        XCTAssertTrue(SearchQuery("12345").matches(roundTripped))
        archive.close()
    }

    /// 真跑一次 Vision：渲染一行文字成图，识别结果应包含关键片段。
    func testVisionRecognizesRenderedText() throws {
        _ = NSApplication.shared   // 文本绘制需要一个 App 实例
        let image = NSImage(size: NSSize(width: 460, height: 140))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 460, height: 140).fill()
        let text = "ClipLine OCR 2026" as NSString
        text.draw(at: NSPoint(x: 24, y: 44), withAttributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let recognized = try XCTUnwrap(Ocr.recognize(tiff), "应识别出文字")
        XCTAssertTrue(recognized.localizedCaseInsensitiveContains("ClipLine"), "识别结果: \(recognized)")
        XCTAssertTrue(recognized.contains("2026"), "识别结果: \(recognized)")
    }
}
