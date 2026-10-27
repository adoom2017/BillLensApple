import Foundation
import XCTest
@testable import BillLensShared

/// 通过真实 Rust FFI 锁定手动新增 / 编辑的 Swift DTO 合同。
@MainActor
final class ManualEntryContractsTests: XCTestCase {
    private let profile = "swift-manual-test"
    private let bridge = RustBridge()

    override func setUp() async throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("billlens-manual-\(UUID().uuidString).sqlite")
        let _: EmptyResponse = try bridge.send([
            "action": "bootstrap",
            "database_path": database.path,
            "profile_id": profile,
            "device_id": "swift-test",
            "llm": NSNull(),
            "log_file_path": NSNull(),
            "time_zone": "Asia/Shanghai"
        ])
    }

    func testCreateAndUpdateRecordRoundTrip() throws {
        var input = ManualRecordInput(
            direction: "expense",
            amount: 18.8,
            currency: "CNY",
            category: "餐饮",
            merchant: "面馆",
            transactionAt: "2026-10-27T04:30:00Z",
            note: nil
        )
        let created: RecordItem = try bridge.send([
            "action": "create_record",
            "profile_id": profile,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        XCTAssertEqual(created.amount, 18.8)
        XCTAssertEqual(created.merchant, "面馆")

        input.direction = "income"
        input.category = "退款"
        let updated: RecordItem = try bridge.send([
            "action": "update_record",
            "profile_id": profile,
            "record_id": created.id,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.direction, "income")
        XCTAssertEqual(updated.syncVersion, created.syncVersion + 1)

        input.category = "工资收入"
        input.direction = "expense"
        XCTAssertThrowsError(try bridge.send([
            "action": "create_record",
            "profile_id": profile,
            "input": try ManualEntryEncoding.dictionary(input)
        ]) as RecordItem)
    }

    func testSubscriptionAndAssetValuationRoundTrip() throws {
        let future = ManualSubscriptionInput(
            direction: "expense",
            amount: 25,
            currency: "CNY",
            category: "订阅",
            merchant: "视频会员",
            note: nil,
            cycle: "monthly",
            firstChargeOn: "2099-01-15"
        )
        let subscription: ManualSubscriptionResult = try bridge.send([
            "action": "create_subscription",
            "profile_id": profile,
            "input": try ManualEntryEncoding.dictionary(future)
        ])
        XCTAssertEqual(subscription.charged, 0)
        XCTAssertEqual(subscription.subscription.nextDueAt, "2099-01-15")

        func valuation(_ amount: Double, _ day: String) throws -> ManualAssetResult {
            try bridge.send([
                "action": "create_asset",
                "profile_id": profile,
                "input": try ManualEntryEncoding.dictionary(ParsedAssetInfo(
                    name: "招商银行",
                    category: "存款",
                    amount: amount,
                    currency: "CNY",
                    recordedOn: day,
                    note: nil
                ))
            ])
        }
        let created = try valuation(1000, "2026-10-01")
        let updated = try valuation(1200, "2026-10-27")
        XCTAssertEqual(created.assetId, updated.assetId)
        XCTAssertNotEqual(created.assetSnapshotId, updated.assetSnapshotId)
    }
}
