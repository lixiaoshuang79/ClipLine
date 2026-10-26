import AppKit
import ImageIO
import XCTest
@testable import ClipLine

final class OcrHelperTests: XCTestCase {
    override func tearDown() {
        Ocr.helperRecognizer = nil
        unsetenv("CLIPLINE_OCR_FORCE_FAIL")
        unsetenv("CLIPLINE_OCR_FORCE_HELPER")
        unsetenv("CLIPLINE_OCR_HELPER_PATH")
        super.tearDown()
    }

    private func renderedImage(_ text: String = "ClipLine Helper 2026") -> CGImage {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 520, height: 140))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 520, height: 140).fill()
        (text as NSString).draw(at: NSPoint(x: 24, y: 44), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let source = CGImageSourceCreateWithData(tiff as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    /// 主进程引擎失败时，识别应自动交给独立进程。
    func testFallsBackToHelperWhenInProcessFails() {
        setenv("CLIPLINE_OCR_FORCE_FAIL", "1", 1)
        var calls = 0
        Ocr.helperRecognizer = { _, _, _ in
            calls += 1
            return "兜底识别结果"
        }
        guard case .text(let text) = Ocr.outcome(renderedImage(), minimumTextHeightPixels: 12) else {
            return XCTFail("应走独立进程兜底")
        }
        XCTAssertEqual(text, "兜底识别结果")
        XCTAssertEqual(calls, 1)
    }

    func testForceHelperSkipsInProcess() {
        setenv("CLIPLINE_OCR_FORCE_HELPER", "1", 1)
        Ocr.helperRecognizer = { _, _, _ in "只走独立进程" }
        guard case .text(let text) = Ocr.outcome(renderedImage(), minimumTextHeightPixels: 12) else {
            return XCTFail("应走独立进程")
        }
        XCTAssertEqual(text, "只走独立进程")
    }

    func testHelperEmptyBecomesEmpty() {
        setenv("CLIPLINE_OCR_FORCE_FAIL", "1", 1)
        Ocr.helperRecognizer = { _, _, _ in "" }
        guard case .empty = Ocr.outcome(renderedImage(), minimumTextHeightPixels: 12) else {
            return XCTFail("独立进程没识别到文字时应为 .empty")
        }
    }

    func testBothPathsFailingReportsFailed() {
        setenv("CLIPLINE_OCR_FORCE_FAIL", "1", 1)
        Ocr.helperRecognizer = { _, _, _ in nil }
        guard case .failed = Ocr.outcome(renderedImage(), minimumTextHeightPixels: 12) else {
            return XCTFail("两条路都失败时应为 .failed")
        }
    }

    /// 真跑独立进程：需要先构建出 ClipLineOCRHelper（scripts/build-app.sh 或 swift build）。
    /// 没构建时跳过，不阻塞常规测试。
    func testRealHelperProcess() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ClipLineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
        let candidates = [
            ".build/debug/ClipLineOCRHelper",
            ".build/arm64-apple-macosx/debug/ClipLineOCRHelper",
            ".build/arm64-apple-macosx14.0/debug/ClipLineOCRHelper",
            ".build/release/ClipLineOCRHelper",
            ".build/arm64-apple-macosx/release/ClipLineOCRHelper",
            ".build/arm64-apple-macosx14.0/release/ClipLineOCRHelper",
        ].map { root.appendingPathComponent($0).path }
        guard let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("未构建 ClipLineOCRHelper，跳过真实进程测试")
        }
        setenv("CLIPLINE_OCR_HELPER_PATH", helper, 1)
        setenv("CLIPLINE_OCR_FORCE_HELPER", "1", 1)
        Ocr.helperRecognizer = nil
        guard case .text(let text) = Ocr.outcome(renderedImage(), minimumTextHeightPixels: 12) else {
            return XCTFail("独立进程应识别出文字")
        }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("ClipLine"), "识别结果: \(text)")
    }
}
