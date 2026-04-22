import SwiftUI

enum AppPage: String {
    case entry
    case ledger
    case subscriptions
    case assets

    var title: String {
        switch self {
        case .entry: "账单录入"
        case .ledger: "账单一览"
        case .subscriptions: "订阅管理"
        case .assets: "资产管理"
        }
    }

    var icon: String {
        switch self {
        case .entry: "square.and.pencil"
        case .ledger: "list.bullet.rectangle"
        case .subscriptions: "repeat.circle"
        case .assets: "chart.pie"
        }
    }
}

enum LayoutMetrics {
    static let pagePadding: CGFloat = 14
    static let pageTopPadding: CGFloat = 12
    static let noteHeight: CGFloat = 72
    static let iconButtonSize: CGFloat = 28
    static let actionButtonHeight: CGFloat = 40
    static let messageGap: CGFloat = 14
    static let headerSpacing: CGFloat = 12
    static let bubbleRadius: CGFloat = 8
    static let avatarSize: CGFloat = 32
}

enum IMColors {
    // Text hierarchy
    static let textPrimary = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let textSecondary = Color(red: 0.32, green: 0.32, blue: 0.34)
    static let textMuted = Color(red: 0.49, green: 0.49, blue: 0.52)
    static let textTertiary = Color(red: 0.525, green: 0.525, blue: 0.545)
    static let textPlaceholder = Color(red: 0.824, green: 0.824, blue: 0.843)

    // Accent / brand
    static let accent = Color(red: 0.0, green: 0.443, blue: 0.890)
    static let accentAlt = Color(red: 0.0, green: 0.400, blue: 0.800)
    static let accentDark = Color(red: 0.0, green: 0.314, blue: 0.659)
    static let accentBright = Color(red: 0.161, green: 0.592, blue: 1.0)

    // Semantic
    static let income = textPrimary
    static let danger = Color(red: 0.847, green: 0.0, blue: 0.082)
    static let dangerBg = Color(red: 0.72, green: 0.05, blue: 0.08)
    static let dangerSubtle = Color(red: 0.847, green: 0.0, blue: 0.082)
    static let dangerBorder = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let dangerBgLight = Color(red: 0.965, green: 0.965, blue: 0.973)
    static let warningText = textSecondary

    // Chat
    static let chatBg = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let userBubble = Color(red: 0.929, green: 0.929, blue: 0.949)
    static let botBubble = Color.white
    static let sendButton = accent
    static let sendButtonDark = accentAlt
    static let systemMsgBg = Color(red: 0.929, green: 0.929, blue: 0.949)

    // Surfaces & borders
    static let divider = Color(red: 0.824, green: 0.824, blue: 0.843).opacity(0.62)
    static let dividerLegacy = Color(red: 0.824, green: 0.824, blue: 0.843).opacity(0.62)
    static let panelBg = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let controlBg = Color(red: 0.929, green: 0.929, blue: 0.949)
    static let statBg = Color(red: 0.980, green: 0.980, blue: 0.988)
    static let surface = Color.white
    static let darkSurface = Color(red: 0.153, green: 0.153, blue: 0.161)
    static let navGlass = Color.black.opacity(0.80)
    static let navText = Color.white
    static let navTextSecondary = Color.white.opacity(0.72)
    static let cardShadow = Color.black.opacity(0.14)

    // Tag backgrounds
    static let accentBgLight = Color(red: 0.902, green: 0.949, blue: 1.0)
    static let accentBgActive = Color(red: 0.902, green: 0.949, blue: 1.0)
    static let incomeBgLight = Color(red: 0.929, green: 0.929, blue: 0.949)
    static let warningBg = Color(red: 0.929, green: 0.929, blue: 0.949)

    // Global background
    static let pageBgTop = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let pageBgMid = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let pageBgBottom = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let pageBlobA = Color.clear
    static let pageBlobB = Color.clear

    // Header / logo
    static let logoBgTop = Color.white.opacity(0.18)
    static let logoBorder = Color.white.opacity(0.16)
    static let headerTabBorder = Color.white.opacity(0.12)
    static let headerShadow = Color.black
    static let ghostBorder = Color(red: 0.824, green: 0.824, blue: 0.843).opacity(0.64)

    // Avatars
    static let assistantAvatarTop = darkSurface
    static let assistantAvatarBottom = darkSurface

    // Calendar selected cell
    static let calendarSelectedTop = accent
    static let calendarSelectedBottom = accent

    // Calendar today marker
    static let calendarToday = accent

    // Button primary background (dark)
    static let buttonPrimary = accent

    // Ledger category filter pills
    static let filterMuted = textMuted

    // Ledger special stat colors
    static let ledgerStatGoldBold = textPrimary
    static let ledgerStatGold = textSecondary
}
