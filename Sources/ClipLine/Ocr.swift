import AppKit
import Vision

/// 图片与屏幕选区的离线 OCR：Vision 框架，全程本机完成、不联网。
/// 参数对齐 Shottr 的实践：显式钉住 revision、主语言可配、可选去掉换行、启动后台预热。
enum Ocr {
    /// 单条最多存这么多字符：够搜索，又不让库膨胀。
    static let maxCharacters = 20_000

    /// 识别一张 CGImage；没有文字或识别失败时返回 nil。CPU 密集，调用方放到后台队列。
    static func recognize(_ image: CGImage) -> String? {
        let settings = Settings.shared
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = settings.ocrLanguages
        request.usesLanguageCorrection = true
        // 最小文字高度 ≈ 6px：滤掉噪点级的小字（对齐 Shottr 的实际做法，深反汇编 FUN_100003eac 所得）。
        request.minimumTextHeight = 6.0 / CGFloat(max(image.height, 1))
        // 显式钉住 revision：跨系统版本结果稳定（Shottr 用 currentRevision，这里取等价的受支持最高版）。
        if let latest = VNRecognizeTextRequest.supportedRevisions.max() {
            request.revision = latest
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let raw = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let text = settings.ocrRemoveBreaks ? removeBreaks(raw) : raw
        return String(text.prefix(maxCharacters))
    }

    /// 便捷入口：直接从图片数据识别。
    static func recognize(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return recognize(image)
    }

    /// 预热：启动后在后台跑一次最小识别，把 Vision 的语言模型加载好——首次取字不再等好几秒。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            let bytes = Data(count: 8 * 32)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent) else { return }
            _ = recognize(image)
        }
    }

    /// 「去掉换行」：把被排版折行的句子接回去；空行（段落）保留。
    /// 规则保守：CJK 接 CJK 直接接；行尾连字符接小写去掉连字符；英文行接小写加空格；其余保留换行。
    static func removeBreaks(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for line in lines {
            guard let last = out.last, !last.isEmpty, !line.isEmpty else {
                out.append(line)
                continue
            }
            guard let prev = last.unicodeScalars.last, let next = line.unicodeScalars.first else {
                out.append(line)
                continue
            }
            let endsWithPunctuation = ".,;:!?。，；：！？、…".unicodeScalars.contains(prev)
            if isCJK(prev), isCJK(next), !endsWithPunctuation {
                out[out.count - 1] = last + line
            } else if prev == "-", let first = line.first, first.isLowercase {
                out[out.count - 1] = String(last.dropLast()) + line
            } else if CharacterSet.lowercaseLetters.contains(next), !endsWithPunctuation, !isCJK(prev) {
                out[out.count - 1] = last + " " + line
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)        // 基本汉字
            || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
            || (0x3000...0x303F).contains(scalar.value) // CJK 标点
            || (0xFF00...0xFFEF).contains(scalar.value) // 全角
            || (0x3040...0x30FF).contains(scalar.value) // 假名
            || (0xAC00...0xD7AF).contains(scalar.value) // 谚文
    }
}
