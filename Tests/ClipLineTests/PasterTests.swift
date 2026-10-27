import XCTest
@testable import ClipLine

final class PasterTests: XCTestCase {
    func testRecognizesPasteByShortcutRegardlessOfLanguage() {
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: "V", cmdModifiers: 0, title: "粘贴"))
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: "v", cmdModifiers: 0, title: "Paste"))
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: "V", cmdModifiers: 0, title: "Einfügen"))
    }

    func testRejectsPasteVariantsWithExtraModifiers() {
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: "V", cmdModifiers: 3, title: "粘贴并匹配样式"))
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: "V", cmdModifiers: 1, title: "Paste and Match Style"))
    }

    func testRejectsOtherEditItems() {
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: "Z", cmdModifiers: 0, title: "撤销"))
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: "C", cmdModifiers: 0, title: "复制"))
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: "A", cmdModifiers: 0, title: "全选"))
    }

    func testFallsBackToTitleWhenShortcutMissing() {
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: "", cmdModifiers: nil, title: "Paste"))
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: nil, cmdModifiers: nil, title: " 粘贴 "))
        XCTAssertTrue(Paster.isPasteMenuItem(cmdChar: nil, cmdModifiers: 0, title: "貼上"))
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: nil, cmdModifiers: nil, title: "粘贴并匹配样式"))
        XCTAssertFalse(Paster.isPasteMenuItem(cmdChar: nil, cmdModifiers: nil, title: nil))
    }
}
