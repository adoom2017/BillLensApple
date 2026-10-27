import Foundation
import XCTest
import BillLensAppleServices
@testable import BillLensShared

/// 通过真实 Rust FFI 锁定账单导入的 Swift DTO 合同。fixture 为脱敏合成数据。
@MainActor
final class StatementImportContractsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../rust/crates/core/src/statement/fixtures")
        .standardized

    func testPreviewAndConfirmRoundTripThroughRustEngine() throws {
        let bridge = RustBridge()
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("billlens-statement-\(UUID().uuidString).sqlite")
        let _: EmptyResponse = try bridge.send([
            "action": "bootstrap",
            "database_path": database.path,
            "profile_id": "swift-statement-test",
            "device_id": "swift-test",
            "llm": NSNull(),
            "log_file_path": NSNull(),
            "time_zone": "Asia/Shanghai"
        ])

        let source = try StatementImportService.load(
            from: Self.fixtures.appendingPathComponent("cmb_statement.eml")
        )
        XCTAssertEqual(source.kind, .eml)
        let preview: StatementPreview = try bridge.send([
            "action": "parse_statement",
            "profile_id": "swift-statement-test",
            "source": source.dictionary
        ])
        XCTAssertEqual(preview.cardLast4, ["0000"])
        XCTAssertEqual(preview.periodStart, "2026-09-26")
        XCTAssertEqual(preview.dueOn, "2026-11-13")
        XCTAssertTrue(preview.reconciliation.allSatisfy(\.ok))
        XCTAssertEqual(preview.lines.count, 13)
        XCTAssertEqual(preview.lines.first?.section, .repayment)
        XCTAssertNil(preview.lines.first?.direction)
        XCTAssertNotNil(BillLensFormatters.parseISO(preview.lines[1].transactionAt))

        let selected = preview.lines.filter(\.defaultSelected)
        XCTAssertEqual(selected.count, 12)
        let result: StatementImportResult = try bridge.send([
            "action": "confirm_statement_import",
            "profile_id": "swift-statement-test",
            "source": source.dictionary,
            "selected_line_ids": selected.map(\.lineId),
            "category_overrides": [selected[0].lineId: "其他"]
        ])
        XCTAssertEqual(result.inserted, 12)
        XCTAssertEqual(result.skippedExisting, 0)

        let again: StatementPreview = try bridge.send([
            "action": "parse_statement",
            "profile_id": "swift-statement-test",
            "source": source.dictionary
        ])
        XCTAssertTrue(again.lines.allSatisfy { $0.status == .imported || $0.status == .excluded })
        XCTAssertFalse(again.lines.contains(where: \.isImportable))
    }

    func testUnsupportedFilesAreRejectedBeforeReachingRust() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statement.docx")
        XCTAssertThrowsError(try StatementImportService.load(from: url)) { error in
            XCTAssertEqual(error as? StatementImportError, .unsupportedFile("statement.docx"))
        }
    }
}
