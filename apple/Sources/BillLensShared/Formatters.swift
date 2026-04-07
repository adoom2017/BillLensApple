import Foundation

@MainActor
enum BillLensFormatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let timestampInput: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let timestampFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let mediumDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        return timestampInput.date(from: value) ?? timestampFallback.date(from: value)
    }

    static func displayDateTime(_ value: String?) -> String {
        guard let date = parseISO(value) else { return "未设置" }
        return mediumDateTime.string(from: date)
    }

    static func displayDay(_ value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        return day.string(from: date)
    }

    static func currencyString(_ amount: Double) -> String {
        currency.string(from: NSNumber(value: amount)) ?? "¥\(amount)"
    }
}
