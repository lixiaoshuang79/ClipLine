import AppKit
import XCTest
@testable import ClipLine

final class SearchTests: XCTestCase {
    private let wechat = ClipSource(bundleID: "com.tencent.xinWeChat", name: "微信", icon: nil, kind: .app,
                                    aliases: ["WeChat"])

    private func item(_ kind: ClipItem.Kind, source: ClipSource = .unknown) -> ClipItem {
        ClipItem(kind: kind, source: source, copiedAt: Date(), snapshot: [[:]], fingerprint: UUID().uuidString)
    }

    func testCaseAndWidthInsensitiveSubstring() {
        let clip = item(.text("git log --oneline | grep -i FIX"))
        XCTAssertTrue(SearchQuery("GIT").matches(clip))
        XCTAssertTrue(SearchQuery("fix").matches(clip))
        XCTAssertTrue(SearchQuery("ｇｒｅｐ").matches(clip), "全角字母也算")
        XCTAssertTrue(SearchQuery("oneline |").matches(clip))
        XCTAssertFalse(SearchQuery("rebase").matches(clip))
    }

    func testChineseAndMultipleTerms() {
        let clip = item(.text("周三 14:00 牙医复诊"))
        XCTAssertTrue(SearchQuery("牙医").matches(clip))
        XCTAssertTrue(SearchQuery("复诊 周三").matches(clip), "空格分开的词都命中才算")
        XCTAssertFalse(SearchQuery("复诊 周四").matches(clip))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SearchQuery("   ").isEmpty)
        XCTAssertTrue(SearchQuery("").matches(item(.text("x"))))
    }

    func testLinkMatchesTitleAndDecodedPath() {
        let clip = item(.link(URL(string: "https://example.com/%E4%B8%AD%E6%96%87/page")!, title: "Layout | Apple"))
        XCTAssertTrue(SearchQuery("中文").matches(clip))
        XCTAssertTrue(SearchQuery("layout").matches(clip))
        XCTAssertTrue(SearchQuery("EXAMPLE.com").matches(clip))
    }

    func testFileNamesAndSourceApp() {
        let files = item(.files(["/Users/me/Downloads/季度报告-final.pdf", "/tmp/notes.txt"]))
        XCTAssertTrue(SearchQuery("报告").matches(files))
        XCTAssertTrue(SearchQuery("NOTES.TXT").matches(files))
        XCTAssertFalse(SearchQuery("Downloads").matches(files), "只匹配文件名，不匹配目录")

        let image = item(.image(NSImage(), pixelSize: CGSize(width: 10, height: 10)), source: wechat)
        XCTAssertTrue(SearchQuery("微信").matches(image), "图片只能靠来源 App 命中")
        XCTAssertTrue(SearchQuery("wechat").matches(image), "英文名也算")
        XCTAssertFalse(SearchQuery("图").matches(image), "图片本轮不做 OCR")
        XCTAssertFalse(SearchQuery("未知").matches(item(.text("x"))), "未知来源不参与匹配")
    }

    func testColorLiteral() {
        XCTAssertTrue(SearchQuery("ff7a").matches(item(.color(.red, literal: "#FF7A59"))))
    }

    func testRangesForHighlighting() {
        let query = SearchQuery("ab 中")
        let ranges = query.ranges(in: "xABxab 中文")
        XCTAssertEqual(ranges.map(\.location).sorted(), [1, 4, 7])
        XCTAssertTrue(query.ranges(in: "").isEmpty)
        XCTAssertTrue(SearchQuery("").ranges(in: "abc").isEmpty)
    }

    func testSnippetAroundDeepHit() throws {
        let text = String(repeating: "填充文字 ", count: 120) + "关键句在这里\n\n然后继续"
        let snippet = try XCTUnwrap(SearchQuery("关键句").snippet(in: text))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.contains("关键句在这里 然后继续"), "换行折叠成空格")
        XCTAssertEqual(SearchQuery("开头").snippet(in: "开头就命中"), "开头就命中")
    }

    func testTextCardSwitchesToSnippetOnlyWhenHitIsHidden() {
        let longRest = String(repeating: "正文正文正文正文正文\n", count: 12) + "藏在后面的命中"
        let text = "导语一行\n" + longRest
        let (lead, rest) = TextBody.split(TextBody.tidy(text))
        let rewritten = TextBody.searchRest(text: text, lead: lead, rest: rest, query: SearchQuery("命中"))
        XCTAssertEqual(rewritten.map { $0.contains("藏在后面的命中") }, true)
        XCTAssertNil(TextBody.searchRest(text: text, lead: lead, rest: rest, query: SearchQuery("导语")))
        XCTAssertNil(TextBody.searchRest(text: text, lead: lead, rest: rest, query: SearchQuery("正文")))
    }

    func testCodeWindowFollowsHit() {
        let lines = (1...20).map { "line \($0)" }
        XCTAssertEqual(CodeBody.firstVisibleLine(lines, query: SearchQuery("line 3")), 0)
        XCTAssertEqual(CodeBody.firstVisibleLine(lines, query: SearchQuery("line 12")), 10)
        XCTAssertEqual(CodeBody.firstVisibleLine(lines, query: SearchQuery("line 20")), 14, "窗口不越过末尾")
        XCTAssertEqual(CodeBody.firstVisibleLine(lines, query: SearchQuery("")), 0)
    }

    func testStoreFiltersSelectsAndRestores() {
        let store = ClipStore(archive: nil)
        let a = ClipArchiveTests.text("alpha one", ago: 3)
        let b = ClipArchiveTests.text("beta", ago: 2)
        let c = ClipArchiveTests.text("alpha two", ago: 1)
        [a, b, c].forEach(store.ingest)
        store.selectedID = b.id

        store.fieldChanged(committed: "ALPHA", hasText: true)
        XCTAssertEqual(store.shown.map(\.id), [c.id, a.id])
        XCTAssertEqual(store.selectedID, c.id, "换搜索词后选中第一张命中")
        store.select(offset: 1)
        XCTAssertEqual(store.selectedID, a.id)
        store.select(offset: 1)
        XCTAssertEqual(store.selectedID, a.id, "停在末尾")

        store.fieldChanged(committed: "alpha ", hasText: true)
        XCTAssertEqual(store.selectedID, a.id, "只多了空格，不重新过滤")

        store.escape()
        XCTAssertEqual(store.query, "")
        XCTAssertEqual(store.shown.count, 3)
        XCTAssertEqual(store.selectedID, a.id, "清除后保留选中")

        store.fieldChanged(committed: "zzz", hasText: true)
        XCTAssertTrue(store.shown.isEmpty)
        XCTAssertNil(store.selectedItem)
    }

    func testEscapeTucksOnlyWhenFieldIsEmpty() {
        let store = ClipStore(archive: nil)
        var tucked = 0
        store.onRequestTuck = { tucked += 1 }
        store.fieldChanged(committed: "", hasText: true)   // 只有未上屏的拼音
        store.escape()
        XCTAssertEqual(tucked, 0)
        XCTAssertFalse(store.fieldHasText)
        store.escape()
        XCTAssertEqual(tucked, 1)
    }

    func testPerformanceOfFilteringFiveHundredItems() {
        let store = ClipStore(archive: nil)
        for index in 0..<500 {
            store.ingest(ClipArchiveTests.text("第 \(index) 条 " + String(repeating: "lorem ipsum 剪贴板 ", count: 40), ago: Double(500 - index)))
        }
        measure {
            for query in ["l", "lo", "lor", "lore", "lorem", "剪", "剪贴", "第 42", ""] {
                store.fieldChanged(committed: query, hasText: !query.isEmpty)
            }
        }
    }
}
