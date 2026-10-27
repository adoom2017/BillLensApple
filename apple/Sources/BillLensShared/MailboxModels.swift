import Foundation
import BillLensAppleServices

public enum MailboxProvider: Sendable, Equatable {
    case hotmail
    case icloud

    public var title: String {
        switch self {
        case .hotmail: "Hotmail"
        case .icloud: "iCloud 邮箱"
        }
    }
}

/// Rust `db::MailSyncState`。
public struct MailSyncState: Decodable, Sendable, Equatable {
    public let accountAddress: String
    public let cursor: String?
    public let lastSyncedAt: String?
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case accountAddress = "account_address"
        case cursor
        case lastSyncedAt = "last_synced_at"
        case lastError = "last_error"
    }
}

/// Rust `db::PendingMailStatement`：自动同步后仍有行等待确认的账单邮件。
public struct PendingMailStatement: Decodable, Sendable, Identifiable, Equatable {
    public let messageId: String
    public let receivedAt: String
    public let periodLabel: String?
    public let importedCount: Int
    public let pendingCount: Int

    public var id: String { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case receivedAt = "received_at"
        case periodLabel = "period_label"
        case importedCount = "imported_count"
        case pendingCount = "pending_count"
    }
}

/// Rust `mailbox::MailSyncProgress`：正在进行的同步进度。
public struct MailSyncProgress: Decodable, Sendable, Equatable {
    public let total: Int?
    public let processed: Int
    public let currentReceivedAt: String?

    enum CodingKeys: String, CodingKey {
        case total, processed
        case currentReceivedAt = "current_received_at"
    }

    /// 例如「正在下载第 3 / 12 封账单（2025 年 12 月）」。
    @MainActor
    public var text: String {
        guard let total else { return "正在连接邮箱…" }
        guard total > 0 else { return "正在检查…" }
        var text = "正在下载第 \(min(processed + 1, total)) / \(total) 封账单"
        if let date = currentReceivedAt.flatMap(BillLensFormatters.parseISO) {
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            if let year = components.year, let month = components.month {
                text += "（\(year) 年 \(month) 月）"
            }
        }
        return text
    }
}

public struct MailboxStatus: Decodable, Sendable, Equatable {
    public let state: MailSyncState?
    public let pending: [PendingMailStatement]
}

public struct MailboxSyncResult: Decodable {
    public let imported: Int
    public let newPendingStatements: Int
    public let skipped: Int
    public let scanned: Int
    public let needsReauth: Bool
    public let error: String?
    public let state: MailSyncState?
    public let pending: [PendingMailStatement]
    public let home: HomeSnapshot

    enum CodingKeys: String, CodingKey {
        case imported
        case newPendingStatements = "new_pending_statements"
        case skipped, scanned
        case needsReauth = "needs_reauth"
        case error, state, pending, home
    }
}

extension MailboxSyncResult {
    /// 设置页展示的本次检查结果，让「立即检查」没有新账单时也有明确反馈。
    func summary(lookbackMonths: Int) -> String {
        if error != nil { return "检查未完成，下次会从中断处继续。" }
        if imported > 0 || newPendingStatements > 0 {
            var parts: [String] = []
            if imported > 0 { parts.append("新记账 \(imported) 笔") }
            if newPendingStatements > 0 { parts.append("\(newPendingStatements) 封账单待确认") }
            return parts.joined(separator: "，") + "。"
        }
        if scanned > 0 { return "检查了 \(scanned) 封招行邮件，没有新的账单。" }
        if state?.cursor == nil {
            return "最近 \(lookbackMonths) 个月内，这个邮箱里没有找到招商银行信用卡账单邮件（发件人 ccsvc@message.cmbchina.com）。"
        }
        return "没有新的账单邮件。"
    }
}

/// Rust `statement::StatementSourceInput`（待确认账单的原始邮件）。
struct StatementSourceDTO: Decodable {
    let kind: String
    let content: String

    var payload: StatementSourcePayload {
        get throws {
            guard let kind = StatementSourcePayload.Kind(rawValue: kind) else {
                throw RustBridgeError.invalidResponse
            }
            return StatementSourcePayload(kind: kind, content: content)
        }
    }
}
