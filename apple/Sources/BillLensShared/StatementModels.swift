import Foundation
import BillLensAppleServices

/// Rust `statement::StatementSection`。
public enum StatementSection: String, Codable, Sendable, CaseIterable {
    case repayment, installment, refund, purchase, cash, fee, interest, other

    public var title: String {
        switch self {
        case .repayment: return "还款"
        case .installment: return "分期"
        case .refund: return "退款"
        case .purchase: return "消费"
        case .cash: return "取现"
        case .fee: return "费用"
        case .interest: return "利息"
        case .other: return "其他"
        }
    }
}

public enum StatementLineStatus: String, Codable, Sendable {
    case new
    case imported
    case suspectedDuplicate = "suspected_duplicate"
    case excluded
}

public struct StatementMatchedRecord: Codable, Sendable, Hashable {
    public let id: String
    public let merchant: String?
    public let category: String
    public let transactionAt: String

    enum CodingKeys: String, CodingKey {
        case id, merchant, category
        case transactionAt = "transaction_at"
    }
}

public struct StatementLine: Codable, Sendable, Identifiable, Hashable {
    public let lineId: String
    public let section: StatementSection
    /// nil 表示不入账（还款、取现本金）。
    public let direction: String?
    public let amount: Double
    public let transactionAt: String
    public let description: String
    public let merchant: String
    public let cardLast4: String
    public let category: String
    public let note: String
    public let status: StatementLineStatus
    public let matchedRecord: StatementMatchedRecord?
    public let defaultSelected: Bool

    public var id: String { lineId }
    public var isImportable: Bool { direction != nil && status != .imported }

    enum CodingKeys: String, CodingKey {
        case lineId = "line_id"
        case section, direction, amount
        case transactionAt = "transaction_at"
        case description, merchant
        case cardLast4 = "card_last4"
        case category, note, status
        case matchedRecord = "matched_record"
        case defaultSelected = "default_selected"
    }
}

public struct ReconciliationCheck: Codable, Sendable, Hashable {
    public let name: String
    public let expected: Double
    public let actual: Double
    public let ok: Bool
}

public struct StatementPreview: Codable, Sendable {
    public let bank: String
    public let cardLast4: [String]
    public let periodStart: String
    public let periodEnd: String
    public let dueOn: String?
    public let amountDue: Double?
    public let reconciliation: [ReconciliationCheck]
    public let lines: [StatementLine]

    enum CodingKeys: String, CodingKey {
        case bank
        case cardLast4 = "card_last4"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case dueOn = "due_on"
        case amountDue = "amount_due"
        case reconciliation, lines
    }
}

public struct StatementImportResult: Decodable {
    public let inserted: Int
    public let skippedExisting: Int
    public let home: HomeSnapshot

    enum CodingKeys: String, CodingKey {
        case inserted
        case skippedExisting = "skipped_existing"
        case home
    }
}

/// 一次导入会话：保留原始来源，确认时交给 Rust 重新解析，不回传行内容。
public struct StatementImportSession: Identifiable {
    public let id = UUID()
    public let source: StatementSourcePayload
    public let preview: StatementPreview
    /// 来自 iOS 分享扩展收件箱的文件，导入完成或取消后删除。
    public let inboxFile: URL?
    /// 来自邮箱同步的待确认账单：确认或忽略后通知 Rust 清除原始邮件；取消则保留待下次处理。
    public var mailMessageId: String? = nil
}

public struct StatementPasswordRequest: Identifiable {
    public let id = UUID()
    public let fileURL: URL
    public let inboxFile: URL?
    public let isRetry: Bool
}

extension StatementSourcePayload {
    var dictionary: [String: Any] {
        ["kind": kind.rawValue, "content": content]
    }
}
