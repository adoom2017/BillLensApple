import Foundation

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

    enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
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
    public let profileId: String
    public let content: String
    public let autoConfirm: Bool
    public let status: String
    public let confirmedRecordId: String?
    public var direction: String?
    public var amount: Double?
    public var currency: String?
    public var category: String?
    public var merchant: String?
    public var transactionAt: String?
    public var note: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case content
        case autoConfirm = "auto_confirm"
        case status
        case confirmedRecordId = "confirmed_record_id"
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
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
    public let deletedAt: String?
    public let needsSync: Bool
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
        case deletedAt = "deleted_at"
        case needsSync = "needs_sync"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct HomeSnapshot: Codable {
    public let messages: [ConversationMessage]
    public let draft: RecordDraft?
    public let latestRecord: RecordItem?

    enum CodingKeys: String, CodingKey {
        case messages
        case draft
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

    enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case currency
        case category
        case merchant
        case transactionAt = "transaction_at"
        case note
    }
}

public struct SubmitTextResult: Codable {
    public let home: HomeSnapshot
    public let autoConfirmed: Bool
    public let parsed: ParsedRecordPayload

    enum CodingKeys: String, CodingKey {
        case home
        case autoConfirmed = "auto_confirmed"
        case parsed
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

    enum CodingKeys: String, CodingKey {
        case range
        case summary
        case byDay = "by_day"
        case pendingSyncCount = "pending_sync_count"
    }
}

public enum LedgerPreset: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        case .year: "本年"
        case .custom: "自定义"
        }
    }
}

