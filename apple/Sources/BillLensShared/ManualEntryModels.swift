import Foundation

/// Rust `manual::ManualRecordInput`：新增与编辑账单共用。
public struct ManualRecordInput: Encodable, Sendable {
    public var direction: String
    public var amount: Double
    public var currency: String
    public var category: String
    public var merchant: String?
    /// RFC3339（UTC）。
    public var transactionAt: String
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case direction, amount, currency, category, merchant
        case transactionAt = "transaction_at"
        case note
    }
}

/// Rust `manual::ManualSubscriptionInput`。
public struct ManualSubscriptionInput: Encodable, Sendable {
    public var direction: String
    public var amount: Double
    public var currency: String
    public var category: String
    public var merchant: String?
    public var note: String?
    public var cycle: String
    /// 设备时区的本地日期 YYYY-MM-DD。
    public var firstChargeOn: String

    enum CodingKeys: String, CodingKey {
        case direction, amount, currency, category, merchant, note, cycle
        case firstChargeOn = "first_charge_on"
    }
}

public struct ManualSubscriptionResult: Decodable, Sendable {
    public let subscription: SubscriptionItem
    public let charged: Int
}

public struct ManualAssetResult: Decodable, Sendable {
    public let assetId: String
    public let assetSnapshotId: String?

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case assetSnapshotId = "asset_snapshot_id"
    }
}

enum ManualEntryEncoding {
    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RustBridgeError.invalidResponse
        }
        return object
    }
}
