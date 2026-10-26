import AppKit
import Foundation
import ImageIO
import Vision

/// 独立 OCR 进程的客户端。主进程的 ANE 会话会随运行时长失效（e5rt 建流失败），
/// 失效后重试与熔断都救不回来，只有换进程能恢复——所以把识别交给随 App 打包的
/// ClipLineOCRHelper（新进程，ANE 会话干净），helper 常驻复用，失败或超时就杀掉重开。
final class OcrHelperClient {
    static let shared = OcrHelperClient()

    private let queue = DispatchQueue(label: "com.ashuang.clipline.ocr-helper")
    private let readQueue = DispatchQueue(label: "com.ashuang.clipline.ocr-helper-read", attributes: .concurrent)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextID = 1
    private var consecutiveFailures = 0
    private var cooldownUntil = Date.distantPast
    private var freshSpawn = false
    private(set) var lastError: String?

    private init() {}

    var isAvailable: Bool { helperURL != nil }

    private var helperURL: URL? {
        if let path = ProcessInfo.processInfo.environment["CLIPLINE_OCR_HELPER_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("ClipLineOCRHelper")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// 同步识别（调用方在后台队列）；nil = 失败，空串 = 识别过但没有文字。
    func recognize(_ image: CGImage, minimumTextHeightPixels: CGFloat, languages: [String]) -> String? {
        queue.sync {
            if Date() < cooldownUntil { return nil }
            guard let png = Self.pngData(image) else { return fail("图片编码失败") }
            return request(png: png, minimumTextHeightPixels: minimumTextHeightPixels, languages: languages)
        }
    }

    private func request(png: Data, minimumTextHeightPixels: CGFloat, languages: [String]) -> String? {
        if process == nil { spawn() }
        guard let process, process.isRunning, let input, let output else {
            return fail("独立识别进程未启动")
        }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = [
            "id": id,
            "png": png.base64EncodedString(),
            "minTextHeightPixels": Double(minimumTextHeightPixels),
            "languages": languages,
        ]
        if let latest = VNRecognizeTextRequest.supportedRevisions.max() { payload["revision"] = latest }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return fail("请求编码失败")
        }

        // 新进程第一次识别要加载语言模型，给足时间；之后就是几十到几百毫秒。
        let timeout: TimeInterval = freshSpawn ? 120 : 20
        freshSpawn = false

        var line: String?
        let done = DispatchSemaphore(value: 0)
        readQueue.async {
            line = Self.readLine(from: output)
            done.signal()
        }
        do {
            try input.write(contentsOf: body + Data([0x0A]))
        } catch {
            killProcess()
            return fail("写入请求失败：\(error)")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            killProcess()
            return fail("识别超时")
        }
        guard let line, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? Int) == id else {
            killProcess()
            return fail("响应无法解析")
        }
        switch object["status"] as? String {
        case "text", "empty":
            consecutiveFailures = 0
            cooldownUntil = .distantPast
            lastError = nil
            return object["text"] as? String ?? ""
        case "error":
            let message = object["error"] as? String ?? "未知错误"
            killProcess()   // helper 自己的引擎也坏了：换一个新进程
            return fail(message)
        default:
            killProcess()
            return fail("响应状态未知")
        }
    }

    private func spawn() {
        guard let url = helperURL else { return }
        let process = Process()
        process.executableURL = url
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleExit() }
        }
        do { try process.run() } catch { return }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        freshSpawn = true
    }

    private func killProcess() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }

    private func handleExit() {
        process = nil
        input = nil
        output = nil
    }

    private func fail(_ message: String) -> String? {
        lastError = message
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            cooldownUntil = Date().addingTimeInterval(consecutiveFailures >= 4 ? 60 : 15)
        }
        return nil
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            if let index = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<index])
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}
