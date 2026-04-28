import SwiftUI

enum AppPage: String, CaseIterable {
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
    static let bubbleRadius: CGFloat = 22
    static let avatarSize: CGFloat = 32
}

enum IMColors {
    // Text hierarchy
    static let textPrimary = Color(red: 0.118, green: 0.157, blue: 0.192)
    static let textSecondary = Color(red: 0.330, green: 0.384, blue: 0.431)
    static let textMuted = Color(red: 0.486, green: 0.541, blue: 0.588)
    static let textTertiary = Color(red: 0.566, green: 0.620, blue: 0.663)
    static let textPlaceholder = Color(red: 0.776, green: 0.816, blue: 0.855)

    // Accent / brand
    static let accent = Color(red: 0.161, green: 0.447, blue: 0.584)
    static let accentAlt = Color(red: 0.207, green: 0.525, blue: 0.666)
    static let accentDark = Color(red: 0.120, green: 0.318, blue: 0.412)
    static let accentBright = Color(red: 0.430, green: 0.784, blue: 0.878)

    // Semantic
    static let income = textPrimary
    static let danger = Color(red: 0.765, green: 0.286, blue: 0.306)
    static let dangerBg = Color(red: 0.804, green: 0.349, blue: 0.361)
    static let dangerSubtle = Color(red: 0.706, green: 0.235, blue: 0.259)
    static let dangerBorder = Color(red: 0.900, green: 0.827, blue: 0.835)
    static let dangerBgLight = Color(red: 0.988, green: 0.944, blue: 0.949)
    static let warningText = textSecondary

    // Chat
    static let chatBg = Color(red: 0.950, green: 0.956, blue: 0.964)
    static let userBubble = Color(red: 0.930, green: 0.951, blue: 0.970)
    static let botBubble = Color(red: 0.989, green: 0.992, blue: 0.996)
    static let sendButton = accent
    static let sendButtonDark = accentAlt
    static let systemMsgBg = Color(red: 0.938, green: 0.949, blue: 0.959)

    // Surfaces & borders
    static let divider = Color(red: 0.803, green: 0.850, blue: 0.886).opacity(0.72)
    static let panelBg = Color(red: 0.948, green: 0.955, blue: 0.964).opacity(0.94)
    static let controlBg = Color(red: 0.969, green: 0.977, blue: 0.984)
    static let statBg = Color(red: 0.982, green: 0.986, blue: 0.990)
    static let surface = Color(red: 0.992, green: 0.994, blue: 0.998).opacity(0.96)
    static let surfaceStrong = Color(red: 0.985, green: 0.989, blue: 0.994)
    static let darkSurface = Color(red: 0.153, green: 0.153, blue: 0.161)
    static let navGlass = Color(red: 0.985, green: 0.990, blue: 0.995).opacity(0.82)
    static let navText = textPrimary
    static let navTextSecondary = textMuted
    static let cardShadow = Color(red: 0.227, green: 0.364, blue: 0.455).opacity(0.12)

    // Tag backgrounds
    static let accentBgLight = Color(red: 0.895, green: 0.951, blue: 0.977)
    static let accentBgActive = Color(red: 0.862, green: 0.930, blue: 0.965)
    static let incomeBgLight = Color(red: 0.930, green: 0.951, blue: 0.970)
    static let warningBg = Color(red: 0.953, green: 0.956, blue: 0.965)

    // Global background
    static let pageBgTop = Color(red: 0.976, green: 0.979, blue: 0.971)
    static let pageBgMid = Color(red: 0.946, green: 0.954, blue: 0.962)
    static let pageBgBottom = Color(red: 0.935, green: 0.944, blue: 0.955)
    static let pageBlobA = Color(red: 0.859, green: 0.928, blue: 0.950).opacity(0.65)
    static let pageBlobB = Color(red: 0.951, green: 0.944, blue: 0.892).opacity(0.62)

    // Header / logo
    static let logoBgTop = Color.white.opacity(0.82)
    static let logoBorder = Color.white.opacity(0.56)
    static let headerTabBorder = Color(red: 0.788, green: 0.848, blue: 0.892).opacity(0.68)
    static let headerShadow = Color(red: 0.337, green: 0.447, blue: 0.525)
    static let ghostBorder = Color(red: 0.764, green: 0.830, blue: 0.878).opacity(0.74)

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
