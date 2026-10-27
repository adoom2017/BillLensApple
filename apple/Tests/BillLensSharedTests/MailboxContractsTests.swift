import Foundation
import XCTest
@testable import BillLensShared

/// 通过真实 Rust FFI 锁定邮箱同步状态 DTO 合同（不访问网络）。
@MainActor
final class MailboxContractsTests: XCTestCase {
    func testStatusSourceAndDisconnectContracts() throws {
        let bridge = RustBridge()
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("billlens-mailbox-\(UUID().uuidString).sqlite")
        let _: EmptyResponse = try bridge.send([
            "action": "bootstrap",
            "database_path": database.path,
            "profile_id": "swift-mailbox-test",
            "device_id": "swift-test",
            "llm": NSNull(),
            "log_file_path": NSNull(),
            "time_zone": "Asia/Shanghai"
        ])

        let status: MailboxStatus = try bridge.send([
            "action": "mail_status",
            "profile_id": "swift-mailbox-test"
        ])
        XCTAssertNil(status.state)
        XCTAssertTrue(status.pending.isEmpty)

        XCTAssertThrowsError(try bridge.send([
            "action": "mail_statement_source",
            "profile_id": "swift-mailbox-test",
            "message_id": "missing"
        ]) as StatementSourceDTO)

        let _: EmptyResponse = try bridge.send([
            "action": "mail_disconnect",
            "profile_id": "swift-mailbox-test"
        ])
    }
}
