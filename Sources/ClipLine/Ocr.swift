import AppKit
import Vision

/// 图片与屏幕选区的离线 OCR：Vision 框架，全程本机完成、不联网。
/// 参数对齐 Shottr 的实践：显式钉住 revision、主语言可配、可选去掉换行、启动后台预热。
enum Ocr {
    /// 单条最多存这么多字符：够搜索，又不让库膨胀。
    static let maxCharacters = 20_000

    /// 识别一张 CGImage；没有文字或识别失败时返回 nil。CPU 密集，调用方放到后台队列。
    /// - Parameter minimumTextHeightPixels: 最小文字高度（像素）。屏幕抓图按显示缩放传 6×scale（对齐 Shottr，
    ///   2x 屏即 12px，滤掉半视力的噪点级小字）；其他来源维持 6 的旧行为。
    enum Outcome { case text(String), empty, failed }

    /// 最近一次失败的详情（诊断日志用）。
    private(set) static var lastErrorDescription: String?
    /// 引擎"熔断"：失败后短暂停用识别——失败尝试本身也要占用 ANE 资源，连环重试只会让状态更糟。
    private static var cooldownUntil = Date.distantPast
    private static var consecutiveFailures = 0
    private static let stateLock = NSLock()

    /// 是否在熔断冷却中（冷却期内直接判失败，不再喂引擎）。
    static var inCooldown: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return Date() < cooldownUntil
    }

    private static func noteSuccess() {
        stateLock.lock(); defer { stateLock.unlock() }
        consecutiveFailures = 0
        cooldownUntil = .distantPast
    }

    private static func noteFailure() {
        stateLock.lock(); defer { stateLock.unlock() }
        consecutiveFailures += 1
        cooldownUntil = Date().addingTimeInterval(consecutiveFailures >= 3 ? 300 : 60)
    }

    static func recognize(_ image: CGImage, minimumTextHeightPixels: CGFloat = 6) -> String? {
        if case .text(let text) = outcome(image, minimumTextHeightPixels: minimumTextHeightPixels) { return text }
        return nil
    }

    /// 带失败区分与重试的识别：perform 抛错（如 ANE/e5rt 资源类错误）时等一拍重试一次；
    /// 仍失败返回 .failed——调用方要把它和「真的没有文字」(.empty) 分开呈现。
    /// 没有文字或识别失败时返回 nil。
    /// - Parameter minimumTextHeightPixels: 最小文字高度（像素）。屏幕抓图按显示缩放传 6×scale（对齐 Shottr，
    ///   2x 屏即 12px，滤掉半视力噪点级小字）；其他来源维持 6 的旧行为。
    static func outcome(_ image: CGImage, minimumTextHeightPixels: CGFloat = 6) -> Outcome {
        if inCooldown { return .failed }
        var lastError: Error?
        let attempts = languageAttempts()
        for (index, languages) in attempts.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 0.8) }
            let request = makeRequest(minimumTextHeightPixels: minimumTextHeightPixels,
                                      imageHeight: CGFloat(image.height), languages: languages)
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                lastError = error
                continue
            }
            let raw = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            noteSuccess()
            guard !raw.isEmpty else { return .empty }
            let text = Settings.shared.ocrRemoveBreaks ? removeBreaks(raw) : raw
            return .text(String(text.prefix(maxCharacters)))
        }
        lastErrorDescription = lastError.map { String(describing: $0) }
        noteFailure()
        return .failed
    }

    /// 重试时依次尝试的语言集：用户设置 → 纯中文路径（不同的模型选择在引擎部分故障时可绕行）。
    private static func languageAttempts() -> [[String]] {
        let settings = Settings.shared.ocrLanguages
        var attempts = [settings]
        if settings != ["zh-Hans"] { attempts.append(["zh-Hans"]) }
        if settings != ["en-US"], attempts.count < 2 { attempts.append(["en-US"]) }
        return attempts.prefix(2).map { $0 }
    }

    /// 组一个识别请求（钉 revision 保持跨系统版本稳定；minimumTextHeight 是相对图高的比例）。
    static func makeRequest(minimumTextHeightPixels: CGFloat, imageHeight: CGFloat,
                            languages: [String]? = nil, pinRevision: Bool = true) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages ?? Settings.shared.ocrLanguages
        request.usesLanguageCorrection = true
        request.minimumTextHeight = Float(minimumTextHeightPixels / max(imageHeight, 1))
        if pinRevision, let latest = VNRecognizeTextRequest.supportedRevisions.max() {
            request.revision = latest
        }
        return request
    }

    /// 便捷入口：直接从图片数据识别。
    static func recognize(_ data: Data) -> String? {
        if case .text(let text) = outcome(data) { return text }
        return nil
    }

    /// 数据版三态识别（解码失败也算 .failed）。
    static func outcome(_ data: Data) -> Outcome {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failed }
        return outcome(image)
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

    /// 「去换行」按钮（同 Shottr 的 Cut Breaks）：用户明确要一行，所有换行都拿掉。
    /// 两侧都是 CJK、或挨着全角标点时直接接；行尾连字符接小写去掉连字符；其余补一个空格（中英文之间同样留空格）。
    static func joinLines(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out = ""
        for line in lines {
            guard let prev = out.unicodeScalars.last, let next = line.unicodeScalars.first else {
                out = line
                continue
            }
            if (isCJK(prev) && isCJK(next)) || isFullwidthPunctuation(prev) || isFullwidthPunctuation(next) {
                out += line
            } else if prev == "-", let first = line.first, first.isLowercase {
                out = String(out.dropLast()) + line
            } else {
                out += " " + line
            }
        }
        return out
    }

    private static func isFullwidthPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFF0F).contains(scalar.value)
            || (0xFF1A...0xFF20).contains(scalar.value) || (0xFF3B...0xFF40).contains(scalar.value)
            || (0xFF5B...0xFF65).contains(scalar.value)
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
