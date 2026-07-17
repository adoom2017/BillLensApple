import Foundation
import UserNotifications

public actor SubscriptionNotificationService {
    public static let shared = SubscriptionNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "billlens.subscription."
    private let calendar: Calendar

    private init() {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
            preconditionFailure("Asia/Shanghai time zone is unavailable")
        }
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func requestAuthorization() async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw SubscriptionNotificationError.authorizationDenied
        }
    }

    public func replacePendingReminders(with subscriptions: [SubscriptionItem]) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw SubscriptionNotificationError.authorizationUnavailable(settings.authorizationStatus.rawValue)
        }

        let activeSubscriptions = subscriptions.filter(\.isActive)
        var desiredIdentifiers = Set<String>()
        for subscription in activeSubscriptions {
            let identifier = identifierPrefix + subscription.id
            desiredIdentifiers.insert(identifier)
            let request = try reminderRequest(identifier: identifier, subscription: subscription)
            try await center.add(request)
        }

        let pending = await center.pendingNotificationRequests()
        let obsoleteIdentifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) && !desiredIdentifiers.contains($0) }
        if !obsoleteIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: obsoleteIdentifiers)
        }
    }

    public func removeAllPendingReminders() async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private func reminderRequest(identifier: String, subscription: SubscriptionItem) throws -> UNNotificationRequest {
        let dateParts = subscription.nextDueAt.split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]) else {
            throw SubscriptionNotificationError.invalidDueDate(subscription.nextDueAt)
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 9
        components.minute = 0
        guard let fireDate = calendar.date(from: components), fireDate > Date.now else {
            throw SubscriptionNotificationError.nonFutureDueDate(subscription.nextDueAt)
        }

        let content = UNMutableNotificationContent()
        content.title = "订阅扣款提醒"
        let name = subscription.merchant ?? subscription.category
        content.body = "\(name) 将扣款 \(subscription.currency) \(String(format: "%.2f", subscription.amount))"
        content.sound = .default
        content.userInfo = ["subscription_id": subscription.id]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }
}

public enum SubscriptionNotificationError: LocalizedError {
    case authorizationDenied
    case authorizationUnavailable(Int)
    case invalidDueDate(String)
    case nonFutureDueDate(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "通知权限未获授权。"
        case .authorizationUnavailable(let status):
            "通知权限不可用，authorization_status=\(status)。"
        case .invalidDueDate(let value):
            "订阅下次扣款日期格式无效：\(value)。"
        case .nonFutureDueDate(let value):
            "订阅下次扣款日期不是未来时间：\(value)。"
        }
    }
}
