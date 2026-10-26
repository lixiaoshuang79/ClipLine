import CoreGraphics
import Foundation
import ImageIO
import Vision

// ClipLine 的独立 OCR 进程：主进程的 ANE 会话失效后，识别交给这个新进程跑。
// 协议：stdin 逐行 JSON 请求，stdout 逐行 JSON 响应；进程常驻复用，模型只加载一次。

private struct Request: Decodable {
    let id: Int
    let png: String
    let minTextHeightPixels: Double?
    let languages: [String]?
    let revision: Int?
}

private func writeLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

private func recognize(_ request: Request) -> (status: String, text: String?, error: String?) {
    guard let data = Data(base64Encoded: request.png),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return ("error", nil, "图片解码失败")
    }
    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .accurate
    textRequest.recognitionLanguages = request.languages ?? ["zh-Hans", "en-US"]
    textRequest.usesLanguageCorrection = true
    let minimumPixels = request.minTextHeightPixels ?? 6
    textRequest.minimumTextHeight = Float(minimumPixels / Double(max(image.height, 1)))
    if let revision = request.revision {
        textRequest.revision = revision
    } else if let latest = VNRecognizeTextRequest.supportedRevisions.max() {
        textRequest.revision = latest
    }
    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([textRequest])
    } catch {
        return ("error", nil, String(describing: error))
    }
    let raw = (textRequest.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? ("empty", nil, nil) : ("text", raw, nil)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let request = try? JSONDecoder().decode(Request.self, from: data) else {
        writeLine(["id": 0, "status": "error", "error": "请求解析失败"])
        continue
    }
    let result = recognize(request)
    var payload: [String: Any] = ["id": request.id, "status": result.status]
    if let text = result.text { payload["text"] = text }
    if let error = result.error { payload["error"] = error }
    writeLine(payload)
}
