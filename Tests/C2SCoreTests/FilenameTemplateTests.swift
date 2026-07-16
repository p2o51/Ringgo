import XCTest
@testable import C2SCore

/// F20 文件名模板(spec §6/§11):变量展开固定格式(与 locale 无关)、
/// 非法字符清洗、同名冲突追加 ` (n)`。
final class FilenameTemplateTests: XCTestCase {

    /// 固定时刻:2026-07-16 14:22:33(UTC),消除机器时区影响。
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 16
        components.hour = 14; components.minute = 22; components.second = 33
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testExpandDefaultTemplate() {
        let name = FilenameTemplate.expand("Ringgo {date} at {time}",
                                           date: fixedDate,
                                           timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "Ringgo 2026-07-16 at 14.22.33",
                       "{date}=yyyy-MM-dd、{time}=HH.mm.ss(点号避开冒号),格式是文件名契约")
    }

    func testSanitizeIllegalCharacters() {
        let name = FilenameTemplate.expand("a/b:c {date}",
                                           date: fixedDate,
                                           timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(name.contains("/"), "POSIX 分隔符必须清洗")
        XCTAssertFalse(name.contains(":"), "HFS+/APFS 冒号必须清洗")
        XCTAssertEqual(name, "a-b-c 2026-07-16")
    }

    func testEmptyTemplateFallsBack() {
        XCTAssertEqual(FilenameTemplate.expand("  ", date: fixedDate), "Ringgo",
                       "空模板回落默认名,不产出空文件名")
        XCTAssertEqual(FilenameTemplate.expand("...", date: fixedDate), "Ringgo",
                       "前导点会造成隐藏文件,必须剥掉")
    }

    func testCollisionAppendsParenN() {
        let existing: Set<String> = ["shot.png", "shot (2).png"]
        let name = FilenameTemplate.resolveCollision(base: "shot", ext: "png") { existing.contains($0) }
        XCTAssertEqual(name, "shot (3).png", "冲突序号从 (2) 起顺延到第一个空位")
    }

    func testNoCollisionKeepsName() {
        let name = FilenameTemplate.resolveCollision(base: "shot", ext: "png") { _ in false }
        XCTAssertEqual(name, "shot.png")
    }
}
