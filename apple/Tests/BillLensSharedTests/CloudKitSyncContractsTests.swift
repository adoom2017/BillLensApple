import CloudKit
import XCTest
@testable import BillLensShared

final class CloudKitSyncContractsTests: XCTestCase {
    @MainActor
    func testMissingOrInvalidPayloadRejectsEntirePage() async throws {
        let valid = CKRecord(recordType: "asset")
        valid["payload"] = "{}" as CKRecordValue
        let missing = CKRecord(recordType: "record")
        XCTAssertThrowsError(try CloudKitSyncService.remoteEntries(from: [valid, missing]))
        missing["payload"] = 123 as CKRecordValue
        XCTAssertThrowsError(try CloudKitSyncService.remoteEntries(from: [missing]))
    }

    @MainActor
    func testUnknownRecordTypeIsRejected() async {
        let record = CKRecord(recordType: "unexpected")
        record["payload"] = "{}" as CKRecordValue
        XCTAssertThrowsError(try CloudKitSyncService.remoteEntries(from: [record]))
    }

    @MainActor
    func testAssetsAreAppliedBeforeTheirSnapshots() async throws {
        let snapshot = CKRecord(recordType: "asset_snapshot")
        snapshot["payload"] = "snapshot" as CKRecordValue
        let asset = CKRecord(recordType: "asset")
        asset["payload"] = "asset" as CKRecordValue
        let entries = try CloudKitSyncService.remoteEntries(from: [snapshot, asset])
        XCTAssertEqual(entries.compactMap { $0["entity_type"] as? String }, ["asset", "asset_snapshot"])
        XCTAssertEqual(entries.compactMap { $0["payload"] as? String }, ["asset", "snapshot"])
    }

    @MainActor
    func testInvalidPersistedCursorFailsInsteadOfRestartingSync() async throws {
        XCTAssertNil(try CloudKitSyncService.decodeServerToken(nil))
        XCTAssertThrowsError(try CloudKitSyncService.decodeServerToken("not base64!"))
        let wrongType = try NSKeyedArchiver.archivedData(
            withRootObject: "not a token" as NSString,
            requiringSecureCoding: true
        )
        XCTAssertThrowsError(try CloudKitSyncService.decodeServerToken(wrongType.base64EncodedString()))
    }
}
