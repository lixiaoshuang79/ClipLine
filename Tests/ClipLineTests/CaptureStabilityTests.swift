import AppKit
import XCTest
@testable import ClipLine

/// 稳定帧抓取的"在动/没动"判定（blockDelta）：阈值语义必须锁住，
/// 否则要么把时钟跳秒当动画（每次都多等），要么放过大面积渐入（抓在坏帧上）。
final class CaptureStabilityTests: XCTestCase {
    /// 128×64 深灰底图；repaint 里用白笔刷画"变化区"。
    private func image(repaint: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        repaint(ctx)
        return ctx.makeImage()!
    }

    func testIdenticalImagesHaveZeroDelta() {
        let a = image { _ in }
        let b = image { _ in }
        XCTAssertEqual(ScreenTextCapture.blockDelta(a, b), 0, accuracy: 0.001)
    }

    func testBroadChangeIsDetected() {
        let a = image { _ in }
        let b = image { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 32))   // 半个画面在变：渐入动画同款
        }
        XCTAssertGreaterThan(ScreenTextCapture.blockDelta(a, b), 1.0)
    }

    func testTinyLocalChangeIsIgnored() {
        let a = image { _ in }
        let b = image { ctx in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))    // 一小角：像菜单栏时钟跳秒
        }
        XCTAssertLessThan(ScreenTextCapture.blockDelta(a, b), 1.0)
    }

    func testDifferentSizesDoNotCrash() {
        let a = image { _ in }
        let narrow = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        narrow.setFillColor(gray: 0.2, alpha: 1)
        narrow.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertGreaterThanOrEqual(ScreenTextCapture.blockDelta(a, narrow.makeImage()!), 0)
    }
}
