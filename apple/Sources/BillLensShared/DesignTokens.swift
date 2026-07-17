import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case entry
    case ledger
    case subscriptions
    case assets

    var id: Self { self }

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
        case .subscriptions: "calendar.badge.clock"
        case .assets: "chart.line.uptrend.xyaxis"
        }
    }

    var tabTitle: String {
        switch self {
        case .entry: "记账"
        case .ledger: "账单"
        case .subscriptions: "订阅"
        case .assets: "资产"
        }
    }

    var navigationTitle: String {
        #if os(iOS)
        switch self {
        case .entry: "记一笔"
        case .ledger: "账单"
        case .subscriptions: "订阅"
        case .assets: "资产"
        }
        #else
        title
        #endif
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
    static let bubbleRadius: CGFloat = 22
    static let avatarSize: CGFloat = 32
}

enum LayoutRadii {
    static let shell: CGFloat = 30
    static let section: CGFloat = 24
    static let card: CGFloat = 16
    static let field: CGFloat = 14
    static let compactField: CGFloat = 12
    static let chip: CGFloat = 14
    static let small: CGFloat = 10
    static let micro: CGFloat = 8
    static let tiny: CGFloat = 5
}

enum IMColors {
    // Text hierarchy
    static let textPrimary = Color(red: 0.055, green: 0.086, blue: 0.145)
    static let textSecondary = Color(red: 0.153, green: 0.212, blue: 0.306)
    static let textMuted = Color(red: 0.306, green: 0.369, blue: 0.463)
    static let textTertiary = Color(red: 0.447, green: 0.510, blue: 0.600)
    static let textPlaceholder = Color(red: 0.612, green: 0.671, blue: 0.749)
    static let textTitle = textPrimary
    static let textBody = textSecondary
    static let textLabel = textMuted
    static let textMeta = textTertiary
    static let textHint = textPlaceholder

    // Accent / brand
    static let accent = Color(red: 0.137, green: 0.357, blue: 0.545)
    static let accentAlt = Color(red: 0.196, green: 0.467, blue: 0.655)
    static let accentDark = Color(red: 0.082, green: 0.212, blue: 0.337)
    static let accentBright = Color(red: 0.560, green: 0.804, blue: 0.910)
    static let premiumGold = Color(red: 0.741, green: 0.612, blue: 0.243)
    static let premiumGoldSoft = Color(red: 0.914, green: 0.861, blue: 0.660)

    // Semantic
    static let income = Color(red: 0.102, green: 0.251, blue: 0.216)
    static let danger = Color(red: 0.765, green: 0.286, blue: 0.306)
    static let dangerBg = Color(red: 0.804, green: 0.349, blue: 0.361)
    static let dangerSubtle = Color(red: 0.706, green: 0.235, blue: 0.259)
    static let dangerBorder = Color(red: 0.900, green: 0.827, blue: 0.835)
    static let dangerBgLight = Color(red: 0.988, green: 0.944, blue: 0.949)
    static let warningText = textSecondary

    // Chat
    static let chatBg = Color.white.opacity(0.70)
    static let userBubble = Color(red: 0.899, green: 0.947, blue: 0.981).opacity(0.82)
    static let botBubble = Color.white.opacity(0.76)
    static let sendButton = accent
    static let sendButtonDark = accentAlt
    static let systemMsgBg = Color.white.opacity(0.78)

    // Surfaces & borders
    static let divider = Color.white.opacity(0.44)
    static let panelBg = Color.white.opacity(0.62)
    static let controlBg = Color.white.opacity(0.78)
    static let statBg = Color.white.opacity(0.66)
    static let surface = Color.white.opacity(0.82)
    static let surfaceStrong = Color.white.opacity(0.92)
    static let darkSurface = Color(red: 0.153, green: 0.153, blue: 0.161)
    static let navGlass = Color.white.opacity(0.68)
    static let navText = textPrimary
    static let navTextSecondary = textSecondary
    static let cardShadow = accentDark.opacity(0.18)
    static let glassStroke = Color.white.opacity(0.44)
    static let glassStrokeStrong = Color.white.opacity(0.70)
    static let glassHighlight = Color.white.opacity(0.10)
    static let glassHighlightStrong = Color.white.opacity(0.18)
    static let glassCoolTint = accentBright.opacity(0.10)
    static let glassWarmTint = premiumGoldSoft.opacity(0.12)

    // Tag backgrounds
    static let accentBgLight = Color(red: 0.884, green: 0.942, blue: 0.974).opacity(0.82)
    static let accentBgActive = Color(red: 0.848, green: 0.917, blue: 0.965).opacity(0.88)
    static let incomeBgLight = Color(red: 0.925, green: 0.951, blue: 0.972).opacity(0.82)
    static let warningBg = premiumGoldSoft.opacity(0.42)

    // Global background
    static let pageBgTop = Color(red: 0.979, green: 0.988, blue: 0.998)
    static let pageBgMid = Color(red: 0.922, green: 0.948, blue: 0.975)
    static let pageBgBottom = Color(red: 0.872, green: 0.909, blue: 0.956)
    static let pageBlobA = Color(red: 0.706, green: 0.878, blue: 0.948).opacity(0.56)
    static let pageBlobB = Color(red: 0.954, green: 0.878, blue: 0.702).opacity(0.42)
    static let pageBlobC = Color(red: 0.745, green: 0.816, blue: 0.980).opacity(0.34)

    // Header / logo
    static let logoBgTop = Color.white.opacity(0.66)
    static let logoBorder = Color.white.opacity(0.72)
    static let headerTabBorder = Color.white.opacity(0.58)
    static let headerShadow = accentDark.opacity(0.28)
    static let ghostBorder = Color.white.opacity(0.66)

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
    static let ledgerStatGold = Color(red: 0.431, green: 0.337, blue: 0.118)
}
