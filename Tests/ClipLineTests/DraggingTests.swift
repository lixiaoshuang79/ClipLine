import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipLine

final class DraggingTests: XCTestCase {
    private func store(with item: ClipItem) -> ClipStore {
        let store = ClipStore(archive: nil)
        store.ingest(item)
        return store
    }

    func testTextProviderCarriesPlainText() {
        let item = ClipItem(kind: .text("hello 世界"), source: .unknown, copiedAt: Date(),
                            snapshot: [[.string: Data("hello 世界".utf8)]], fingerprint: "t:hello")
        let store = store(with: item)
        let provider = Dragging.provider(for: store.shown[0], store: store)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))

        let loaded = expectation(description: "load string")
        _ = provider.loadObject(ofClass: String.self) { string, _ in
            XCTAssertEqual(string, "hello 世界")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    func testFileProviderCarriesFileURLData() {
        let item = ClipItem(kind: .files(["/tmp"]), source: .unknown, copiedAt: Date(),
                            snapshot: [[.fileURL: Data("file:///tmp".utf8)]], fingerprint: "f:/tmp")
        let store = store(with: item)
        let provider = Dragging.provider(for: store.shown[0], store: store)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

        let loaded = expectation(description: "load data")
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            XCTAssertEqual((item as? Data).flatMap { String(data: $0, encoding: .utf8) }, "file:///tmp",
                           "载荷: \(String(describing: item)) 错误: \(String(describing: error))")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    func testFileProviderLoadsURLObject() {
        // 接收方用 loadObject(URL.self) 的那条通道也要拿得到文件 URL。
        let item = ClipItem(kind: .files(["/tmp"]), source: .unknown, copiedAt: Date(),
                            snapshot: [[.fileURL: Data("file:///tmp".utf8)]], fingerprint: "f:/tmp2")
        let store = store(with: item)
        let provider = Dragging.provider(for: store.shown[0], store: store)

        let loaded = expectation(description: "load url")
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            XCTAssertEqual(url?.path, "/tmp")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    func testImageProviderCarriesPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let item = ClipItem(kind: .image(NSImage(), pixelSize: CGSize(width: 4, height: 4)), source: .unknown,
                            copiedAt: Date(), snapshot: [[.png: png]], fingerprint: "i:png")
        let store = store(with: item)
        let provider = Dragging.provider(for: store.shown[0], store: store)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
    }

    /// 拖放进绳：一个纯文本 provider 应该被收成一条新历史。
    func testAcceptDropAddsItem() {
        let store = ClipStore(archive: nil)
        let provider = NSItemProvider(object: "drop 进来的文字" as NSString)
        store.acceptDrop([provider])
        let deadline = Date().addingTimeInterval(3)
        while store.items.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.fingerprint, "t:drop 进来的文字")
    }
}
