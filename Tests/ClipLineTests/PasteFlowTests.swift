import AppKit
import XCTest
@testable import ClipLine

/// 粘贴链路的三条硬约束（2026-11-03「点 1 号位、贴出 3 号位」事故）：
/// 1. 唤出前强制同步剪贴板——刚复制的内容必须在第一张卡上；
/// 2. 面板开着时新复制只入账、不重排——卡片不能在指针底下挪位；
/// 3. 写回剪贴板的永远是点中那条自己的快照。
final class PasteFlowTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var store: ClipStore!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.ashuang.clipline.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        store = ClipStore(archive: nil, note: "tests", pasteboard: pasteboard)
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func text(_ item: ClipItem?) -> String? {
        guard let item, case .text(let value) = item.kind else { return nil }
        return value
    }

    func testSyncBeforeRevealSeesContentCopiedJustBeforeSummon() {
        copy("刚截好的图")
        XCTAssertTrue(store.items.isEmpty, "没有轮询前不该自己进历史")
        store.syncFromPasteboard()
        XCTAssertEqual(text(store.items.first), "刚截好的图")
        XCTAssertEqual(text(store.shown.first), "刚截好的图")
    }

    func testCopiesArrivingWhileRevealedDoNotMoveCards() {
        copy("第一条剪贴内容")
        store.syncFromPasteboard()
        store.revealed = true
        let before = store.shown.map(\.id)

        copy("面板开着时复制的内容")
        store.syncFromPasteboard()

        XCTAssertEqual(store.shown.map(\.id), before, "展开期间的卡片顺序必须原样不动")
        XCTAssertEqual(text(store.items.first), "面板开着时复制的内容", "但必须已经入账")

        store.revealed = false
        store.refreshAfterTuck()
        XCTAssertEqual(text(store.shown.first), "面板开着时复制的内容", "收起后补上屏")
    }

    /// 唤出必须重建整行：只发滚动请求时，真机上出现过滚动没归零、点击落到相邻卡
    /// （点 1 号位贴出 3 号位的图，2026-11-05）。`rowEpoch` 变化会让 SwiftUI 连同
    /// 滚动视图一起重建，画面与命中表必然同源。
    func testSummonRebuildsCardRow() {
        copy("第一张")
        store.syncFromPasteboard()
        let before = store.rowEpoch
        store.scrollToStart()
        XCTAssertEqual(store.rowEpoch, before + 1, "每次唤出重建卡片行")
        XCTAssertEqual(store.scrollRequest?.target, .start, "同时保留滚回开头的请求")
    }

    func testPasteWritesTheClickedItemsOwnSnapshot() {        copy("第一条剪贴内容")
        store.syncFromPasteboard()
        copy("第二条剪贴内容")
        store.syncFromPasteboard()

        let first = try? XCTUnwrap(store.shown.first { text($0) == "第一条剪贴内容" })
        XCTAssertNotNil(first)
        XCTAssertTrue(store.writeToPasteboard(first!))
        XCTAssertEqual(pasteboard.string(forType: .string), "第一条剪贴内容",
                       "点哪条就写回哪条的原始快照")
    }

    /// 图片走完整生产路径：捕获 → 落盘（内存快照清空）→ 点卡 → 从磁盘读回 → 写剪贴板。
    /// 写回的必须是这张图自己的原始 PNG 字节，不能是邻居的。
    func testImagePasteWritesTheClickedImagesOwnBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipline-tests-\(UUID().uuidString)", isDirectory: true)
        let archive = try ClipArchive(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(archive: archive, note: "tests", pasteboard: pasteboard)

        let red = Self.png(.systemRed)
        let blue = Self.png(.systemBlue)
        pasteboard.clearContents()
        pasteboard.setData(red, forType: .png)
        store.syncFromPasteboard()
        store.flush()
        pasteboard.clearContents()
        pasteboard.setData(blue, forType: .png)
        store.syncFromPasteboard()
        store.flush()

        let redItem = try XCTUnwrap(store.items.first { $0.fingerprint == "i:" + ClipItem.sha256(red) })
        XCTAssertTrue(store.writeToPasteboard(redItem))
        XCTAssertEqual(pasteboard.data(forType: .png), red, "写回剪贴板的必须是点中那张图的原始字节")

        let blueItem = try XCTUnwrap(store.items.first { $0.fingerprint == "i:" + ClipItem.sha256(blue) })
        XCTAssertTrue(store.writeToPasteboard(blueItem))
        XCTAssertEqual(pasteboard.data(forType: .png), blue)
        store.close()
    }

    private static func png(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 50,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 50).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// 访达复制文件常带私有动态 UTI（dyn.*）。文件不是凭据，必须能进历史；
    /// 但密码管理器那种只有 dyn 标记的内容仍然要被挡掉。
    func testFinderFileCopyWithDynamicTypeIsCapturedAndPasted() throws {
        let url = URL(fileURLWithPath: "/tmp/clipline-file-test.txt")
        let dynamic = NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8y6y4grf0gn5xbr0q3a")
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(url.absoluteString, forType: .fileURL)
        entry.setData(Data("finder-private".utf8), forType: dynamic)
        entry.setPropertyList([url.path], forType: filenames)
        pasteboard.writeObjects([entry])

        store.syncFromPasteboard()
        guard case .files(let paths)? = store.items.first?.kind else {
            return XCTFail("文件复制应被收成文件卡")
        }
        XCTAssertEqual(paths, [url.path])

        XCTAssertTrue(store.writeToPasteboard(store.items[0]))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), url.absoluteString,
                       "粘贴要把原始文件 URL 写回剪贴板")
    }

    func testDynamicTypeWithoutFileIsStillIgnored() {
        let dynamic = NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8y6y4grf0gn5xbr0q3a")
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString("秘密口令", forType: .string)
        entry.setData(Data("secret".utf8), forType: dynamic)
        pasteboard.writeObjects([entry])

        store.syncFromPasteboard()
        XCTAssertTrue(store.items.isEmpty, "没有文件 URL 的 dyn.* 仍按凭据处理，不进历史")
    }

    func testFirstTapSelectsAndSecondTapPastes() throws {
        copy("第一条剪贴内容")
        store.syncFromPasteboard()
        copy("第二条剪贴内容")
        store.syncFromPasteboard()

        var pasted: [ClipItem] = []
        store.onRequestPaste = { pasted.append($0) }
        let item = try XCTUnwrap(store.shown.first)

        store.handleTap(item)
        XCTAssertEqual(store.selectedID, item.id, "第一下只选中")
        XCTAssertTrue(pasted.isEmpty, "第一下不许粘贴")

        store.handleTap(item)
        XCTAssertEqual(pasted.map(\.id), [item.id], "同一卡片上的第二下才粘贴")

        store.handleTap(item)
        XCTAssertEqual(pasted.count, 1, "双击后的第三下重新算单击，不许再粘")
    }

    func testTapOnAnotherCardWithinIntervalOnlySelects() throws {
        copy("第一条剪贴内容")
        store.syncFromPasteboard()
        copy("第二条剪贴内容")
        store.syncFromPasteboard()

        var pasted: [ClipItem] = []
        store.onRequestPaste = { pasted.append($0) }
        let first = try XCTUnwrap(store.shown.first)
        let second = try XCTUnwrap(store.shown.dropFirst().first)

        store.handleTap(first)
        store.handleTap(second)   // 快速换卡：不算双击
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(store.selectedID, second.id)
    }

    func testRepeatedCopiesOfSameContentDoNotDuplicate() {
        copy("重复的一条剪贴内容")
        store.syncFromPasteboard()
        copy("别的剪贴内容")
        store.syncFromPasteboard()
        copy("重复的一条剪贴内容")
        store.syncFromPasteboard()
        XCTAssertEqual(store.items.filter { text($0) == "重复的一条剪贴内容" }.count, 1)
        XCTAssertEqual(text(store.items.first), "重复的一条剪贴内容", "重新复制应回到最前")
    }
}
