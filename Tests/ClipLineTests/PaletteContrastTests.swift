import SwiftUI
import XCTest
@testable import ClipLine

/// §3.5 对比度自检：h = 0…350（步长 10）× 彩度上下限与中值 × 浅色/深色。
final class PaletteContrastTests: XCTestCase {
    private let schemes: [ColorScheme] = [.light, .dark]
    private let chromas = [0.07, 0.115, 0.16]

    func testChromaticPalettesMeetContrast() {
        for hue in stride(from: 0.0, through: 350, by: 10) {
            for chroma in chromas {
                assertContrast(SourceTint.normalized(h: hue, c: chroma, h2: nil), label: "h=\(hue) c=\(chroma)")
            }
        }
    }

    func testFallbackPalettesMeetContrast() {
        assertContrast(.graphite, label: "graphite")
        assertContrast(.continuity, label: "continuity")
        for scheme in schemes {
            let t = SourceTint.unknown.tones(for: scheme)
            XCTAssertNil(t.cuffTop)
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.ink, on: t.bodyBottom), 7, "unknown \(scheme)")
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.ink2, on: t.bodyBottom), 4.5, "unknown \(scheme)")
        }
    }

    func testYellowBandUsesDarkInk() {
        let tint = SourceTint.normalized(h: 95, c: 0.14, h2: nil)
        XCTAssertEqual(tint.style, .yellow)
        let t = tint.tones(for: .light)
        XCTAssertLessThan(t.cuffInk.luminance, t.cuffBottom!.luminance)
    }

    func testOKLCHRoundTrip() {
        let original = OKLCH(0.62, 0.12, 250)
        let s = original.swatch()
        let back = OKLCH(linearRed: s.r, green: s.g, blue: s.b)
        XCTAssertEqual(back.l, original.l, accuracy: 0.001)
        XCTAssertEqual(back.c, original.c, accuracy: 0.001)
        XCTAssertEqual(back.h, original.h, accuracy: 0.1)
    }

    func testClassifier() {
        let unknown = ClipSource.unknown
        guard case .color = ClipClassifier.kind(for: "#1A73E8", source: unknown, title: nil) else { return XCTFail("hex") }
        guard case .color = ClipClassifier.kind(for: "rgba(10, 20, 30, 0.5)", source: unknown, title: nil) else { return XCTFail("rgba") }
        guard case .color = ClipClassifier.kind(for: "hsl(210 50% 40%)", source: unknown, title: nil) else { return XCTFail("hsl") }
        guard case .color = ClipClassifier.kind(for: "oklch(0.7 0.1 250)", source: unknown, title: nil) else { return XCTFail("oklch") }
        guard case .link = ClipClassifier.kind(for: " https://example.com/a?b=1 ", source: unknown, title: nil) else { return XCTFail("link") }
        guard case .code = ClipClassifier.kind(for: "if (a) {\n  b();\n}", source: unknown, title: nil) else { return XCTFail("code") }
        guard case .text = ClipClassifier.kind(for: "看看 https://example.com 这个", source: unknown, title: nil) else { return XCTFail("text") }
        guard case .text = ClipClassifier.kind(for: "第一行\n第二行", source: unknown, title: nil) else { return XCTFail("prose") }
    }

    private func assertContrast(_ tint: SourceTint, label: String) {
        for scheme in schemes {
            let t = tint.tones(for: scheme)
            guard let top = t.cuffTop, let bottom = t.cuffBottom else { return XCTFail("\(label) 缺色头") }
            let where_ = "\(label) \(scheme)"
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.cuffInk, on: bottom), 4.5, "cuffInk/cuffBottom \(where_)")
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.cuffInk, on: top), 3.0, "cuffInk/cuffTop \(where_)")
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.ink, on: t.bodyBottom), 7, "ink/bodyBottom \(where_)")
            XCTAssertGreaterThanOrEqual(Swatch.contrast(t.ink2, on: t.bodyBottom), 4.5, "ink2/bodyBottom \(where_)")
        }
    }
}
