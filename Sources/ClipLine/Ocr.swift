import AppKit
import Vision

/// 图片条目的离线 OCR：Vision 框架，简体中文 + 英文，全程在本机完成、不联网。
enum Ocr {
    /// 单条最多存这么多字符：够搜索，又不让库膨胀。
    static let maxCharacters = 20_000

    /// 识别一张图的文字；没有文字或识别失败时返回 nil。CPU 密集，调用方放到后台队列。
    static func recognize(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxCharacters))
    }
}
