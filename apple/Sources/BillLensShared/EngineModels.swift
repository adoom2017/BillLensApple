import Foundation

public struct LlmConfigItem: Codable, Sendable {
    public var baseUrl: String
    public var apiKey: String
    public var model: String
    public var provider: String
    public var enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case model
        case provider
        case enableThinking = "enable_thinking"
    }
}

public struct LlmModelItem: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String?
    public let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }
}

public struct EngineEnvelope<T: Decodable>: Decodable {
    public let ok: Bool
    public let data: T?
    public let error: String?
}

public struct DraftInput: Codable {
    public var direction: String?
    public var amount: Double?
    public var currency: String?
    public var category: String?
    public var merchant: String?
    public var transactionAt: String?
    public var note: String?
    public var subscriptionCycle: String? = nil
    public var assetInfo: ParsedAssetInfo? = nil

    enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
        case subscriptionCycle = "subscription_cycle"
        case assetInfo = "asset_info"
    }
}

public struct ConversationMessage: Codable, Identifiable {
    public let id: String
    public let profileId: String
    public let role: String
    public let content: String
    public let draftId: String?
    public let recordId: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case role
        case content
        case draftId = "draft_id"
        case recordId = "record_id"
        case createdAt = "created_at"
    }
}

public struct RecordDraft: Codable, Identifiable {
    public let id: String
    public let batchId: String
    public let profileId: String
    public let content: String
    public let autoConfirm: Bool
    public let kind: String
    public let parserSource: String
    public let fallbackReason: String?
    public let status: String
    public let confirmedRecordId: String?
    public var direction: String?
    public var amount: Double?
    public var currency: String?
    public var category: String?
    public var merchant: String?
    public var transactionAt: String?
    public var note: String?
    public let subscriptionCycle: String?
    public var assetInfo: ParsedAssetInfo?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case batchId = "batch_id"
        case profileId = "profile_id"
        case content
        case autoConfirm = "auto_confirm"
        case kind
        case parserSource = "parser_source"
        case fallbackReason = "fallback_reason"
        case status
        case confirmedRecordId = "confirmed_record_id"
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
        case subscriptionCycle = "subscription_cycle"
        case assetInfo = "asset_info"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct RecordItem: Codable, Identifiable {
    public let id: String
    public let profileId: String
    public let direction: String
    public let amount: Double
    public let currency: String
    public let category: String
    public let merchant: String?
    public let transactionAt: String
    public let note: String?
    public let deviceId: String
    public let syncVersion: Int
    public let syncedVersion: Int
    public let deletedAt: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
        case deviceId = "device_id"
        case syncVersion = "sync_version"
        case syncedVersion = "synced_version"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct HomeSnapshot: Codable {
    public let messages: [ConversationMessage]
    public let drafts: [RecordDraft]
    public let latestRecord: RecordItem?

    enum CodingKeys: String, CodingKey {
        case messages
        case drafts
        case latestRecord = "latest_record"
    }
}

public struct ParsedRecordPayload: Codable {
    public let direction: String?
    public let amount: Double?
    public let currency: String?
    public let category: String?
    public let merchant: String?
    public let transactionAt: String?
    public let note: String?
    public let subscriptionCycle: String?
    public let assetInfo: ParsedAssetInfo?

    enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
        case subscriptionCycle = "subscription_cycle"
        case assetInfo = "asset_info"
    }
}

public struct ParsedAssetInfo: Codable {
    public var name: String
    public var category: String?
    public var amount: Double
    public var currency: String?
    public var recordedOn: String?
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case name
        case category
        case amount
        case currency
        case recordedOn = "recorded_on"
        case note
    }
}

public struct LocalFailureInfo: Codable {
    public let code: String
    public let message: String
}

public struct SubmitTextResult: Codable {
    public let home: HomeSnapshot
    public let autoConfirmed: Bool
    public let parsed: [ParsedRecordPayload]
    public let subscriptionCreated: Bool
    public let assetAcks: [AssetAck]?
    public let parserSource: String
    public let localModelId: String?
    public let localFailure: LocalFailureInfo?

    enum CodingKeys: String, CodingKey {
        case home
        case autoConfirmed = "auto_confirmed"
        case parsed
        case subscriptionCreated = "subscription_created"
        case assetAcks = "asset_acks"
        case parserSource = "parser_source"
        case localModelId = "local_model_id"
        case localFailure = "local_failure"
    }
}

public struct SaveDraftResult: Codable {
    public let home: HomeSnapshot
    public let record: RecordItem?
}

public struct LedgerRangeSelection: Codable {
    public let preset: String
    public let startAt: String
    public let endAt: String

    enum CodingKeys: String, CodingKey {
        case preset
        case startAt = "start_at"
        case endAt = "end_at"
    }
}

public struct RecordsSummary: Codable {
    public let incomeAmount: Double
    public let incomeCount: Int
    public let expenseAmount: Double
    public let expenseCount: Int
    public let netAmount: Double

    enum CodingKeys: String, CodingKey {
        case incomeAmount = "income_amount"
        case incomeCount = "income_count"
        case expenseAmount = "expense_amount"
        case expenseCount = "expense_count"
        case netAmount = "net_amount"
    }
}

public struct RecordsStatsResponse: Codable {
    public let summary: RecordsSummary
}

public struct LedgerDayGroup: Codable, Identifiable {
    public var id: String { day }
    public let day: String
    public let incomeAmount: Double
    public let expenseAmount: Double
    public let netAmount: Double
    public let records: [RecordItem]

    enum CodingKeys: String, CodingKey {
        case day
        case incomeAmount = "income_amount"
        case expenseAmount = "expense_amount"
        case netAmount = "net_amount"
        case records
    }
}

public struct LedgerSnapshot: Codable {
    public let range: LedgerRangeSelection
    public let summary: RecordsStatsResponse
    public let byDay: [LedgerDayGroup]
    public let pendingSyncCount: Int
    public let statsCurrency: String
    public let fxWarning: String?

    enum CodingKeys: String, CodingKey {
        case range
        case summary
        case byDay = "by_day"
        case pendingSyncCount = "pending_sync_count"
        case statsCurrency = "stats_currency"
        case fxWarning = "fx_warning"
    }
}

public enum LedgerPreset: String, CaseIterable, Identifiable {
    case month
    case year
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .month: "按月"
        case .year: "按年"
        case .custom: "自定义"
        }
    }
}

public struct SubscriptionItem: Codable, Identifiable, Sendable {
    public let id: String
    public let profileId: String
    public let direction: String
    public let amount: Double
    public let currency: String
    public let category: String
    public let merchant: String?
    public let note: String?
    public let cycle: String
    public let anchorDay: Int
    public let anchorMonth: Int?
    public let nextDueAt: String
    public let lastChargedAt: String?
    public let isActive: Bool
    public let deletedAt: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case direction
        case amount
        case currency
        case category
        case merchant
        case note
        case cycle
        case anchorDay = "anchor_day"
        case anchorMonth = "anchor_month"
        case nextDueAt = "next_due_at"
        case lastChargedAt = "last_charged_at"
        case isActive = "is_active"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public var cycleDisplayText: String {
        switch cycle {
        case "monthly": "每月"
        case "yearly": "每年"
        default: cycle
        }
    }

    public var statusDisplayText: String {
        isActive ? "活跃" : "已暂停"
    }
}

public struct SubscriptionListResponse: Codable, Sendable {
    public let subscriptions: [SubscriptionItem]
}

public struct SubscriptionChargeResult: Codable, Sendable {
    public let charged: Int
}

public struct SubscriptionUpdateInput: Codable {
    public var direction: String?
    public var amount: Double?
    public var currency: String?
    public var category: String?
    public var merchant: String?
    public var note: String?
    public var cycle: String?
    public var anchorDay: Int?
    public var anchorMonth: Int?

    enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case currency
        case category
        case merchant
        case note
        case cycle
        case anchorDay = "anchor_day"
        case anchorMonth = "anchor_month"
    }
}

public struct CategoriesResponse: Decodable, Sendable {
    public let expense: [String]
    public let income: [String]
}

// MARK: - Asset models

public struct AssetItem: Codable, Identifiable, Sendable {
    public let id: String
    public let profileId: String
    public let name: String
    public let category: String
    public let currency: String
    public let note: String?
    public let snapshots: [AssetSnapshotItem]
    public let latestAmount: Double?
    public let latestRecordedOn: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case name
        case category
        case currency
        case note
        case snapshots
        case latestAmount = "latest_amount"
        case latestRecordedOn = "latest_recorded_on"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct AssetSnapshotItem: Codable, Identifiable, Sendable {
    public let id: String
    public let assetId: String
    public let amount: Double
    public let recordedOn: String
    public let note: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case assetId = "asset_id"
        case amount
        case recordedOn = "recorded_on"
        case note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct AssetListResponse: Codable, Sendable {
    public let assets: [AssetItem]
}

public struct AssetUpdateInput: Codable, Sendable {
    public var name: String?
    public var category: String?
    public var currency: String?
    public var note: String?
}

public struct AssetAck: Codable, Sendable {
    public let assetId: String
    public let name: String
    public let category: String
    public let amount: Double
    public let currency: String
    public let recordedOn: String
    public let created: Bool

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case name
        case category
        case amount
        case currency
        case recordedOn = "recorded_on"
        case created
    }
}
