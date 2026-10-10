import XCTest
@testable import ClipLine

final class RetentionTests: XCTestCase {
    private func entries(_ specs: [(bytes: Int, image: Bool)]) -> [Retention.Entry] {
        specs.map { Retention.Entry(id: UUID(), bytes: $0.bytes, isImage: $0.image) }
    }

    func testCountCapDropsOldest() {
        let list = entries(Array(repeating: (10, false), count: 7))
        let evicted = Retention(maxItems: 5, imageBudget: .max, maxStoredBytes: .max).evictions(list)
        XCTAssertEqual(evicted, Set(list.suffix(2).map(\.id)))
    }

    func testImageBudgetEvictsOldestImagesOnly() {
        // 新→旧：图 40、文、图 40、文、图 40；预算 90 → 只淘汰最旧的那张图。
        let list = entries([(40, true), (5, false), (40, true), (5, false), (40, true)])
        let evicted = Retention(maxItems: 100, imageBudget: 90, maxStoredBytes: .max).evictions(list)
        XCTAssertEqual(evicted, [list[4].id])
    }

    func testImageBudgetKeepsEvictingUntilUnderBudget() {
        let list = entries([(50, true), (50, true), (50, true), (50, true)])
        let evicted = Retention(maxItems: 100, imageBudget: 100, maxStoredBytes: .max).evictions(list)
        XCTAssertEqual(evicted, [list[2].id, list[3].id])
    }

    func testNewestIsNeverEvicted() {
        let list = entries([(500, true), (10, true)])
        let evicted = Retention(maxItems: 100, imageBudget: 100, maxStoredBytes: .max).evictions(list)
        XCTAssertEqual(evicted, [list[1].id])
    }

    func testWithinLimitsEvictsNothing() {
        let list = entries([(10, true), (10, false), (10, true)])
        XCTAssertTrue(Retention.standard.evictions(list).isEmpty)
    }
}
