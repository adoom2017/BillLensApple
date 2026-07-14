import Foundation

@MainActor
enum BillLensFormatters {
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

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDate(_ value: String) -> Date? {
        dateOnly.date(from: value)
    }

    static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        return timestampInput.date(from: value) ?? timestampFallback.date(from: value)
    }

    static func displayDateTime(_ value: String?) -> String {
        guard let date = parseISO(value) else { return "未设置" }
        return mediumDateTime.string(from: date)
    }

    static func displayDay(_ value: String) -> String {
        guard let date = dateOnly.date(from: value) else { return value }
        return day.string(from: date)
    }

    private static var currencyFormatters: [String: NumberFormatter] = [:]

    static func currencyString(_ amount: Double, currencyCode: String? = "CNY") -> String {
        let code = normalizedCurrencyCode(currencyCode) ?? "CNY"
        let formatter: NumberFormatter
        if let cached = currencyFormatters[code] {
            formatter = cached
        } else {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.numberStyle = .currency
            f.currencyCode = code
            f.maximumFractionDigits = 2
            currencyFormatters[code] = f
            formatter = f
        }

        if let formatted = formatter.string(from: NSNumber(value: amount)) {
            return formatted
        }

        return "\(code) \(String(format: "%.2f", amount))"
    }

    static func normalizedCurrencyCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        guard upper.unicodeScalars.count == 3,
              upper.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) else {
            return nil
        }
        return upper
    }
}
