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
}

enum LayoutMetrics {
    static let pagePadding: CGFloat = 16
    static let pageTopPadding: CGFloat = 18
    static let noteHeight: CGFloat = 72
    static let iconButtonSize: CGFloat = 28
    static let actionButtonHeight: CGFloat = 40
    static let messageGap: CGFloat = 14
    static let headerSpacing: CGFloat = 14
    static let bubbleRadius: CGFloat = 6
    static let avatarSize: CGFloat = 32
}

enum IMColors {
    // Text hierarchy
    static let textPrimary = Color(red: 0.10, green: 0.21, blue: 0.24)
    static let textSecondary = Color(red: 0.50, green: 0.56, blue: 0.58)
    static let textMuted = Color(red: 0.42, green: 0.51, blue: 0.54)
    static let textTertiary = Color(red: 0.55, green: 0.63, blue: 0.65)
    static let textPlaceholder = Color(red: 0.82, green: 0.84, blue: 0.84)

    // Accent / brand
    static let accent = Color(red: 0.165, green: 0.426, blue: 0.384)
    static let accentAlt = Color(red: 0.172, green: 0.431, blue: 0.381)
    static let accentDark = Color(red: 0.16, green: 0.42, blue: 0.35)

    // Semantic
    static let income = Color(red: 0.84, green: 0.38, blue: 0.29)
    static let danger = Color(red: 0.71, green: 0.25, blue: 0.23)
    static let dangerBg = Color(red: 0.56, green: 0.22, blue: 0.19)
    static let dangerSubtle = Color(red: 0.65, green: 0.30, blue: 0.27)
    static let dangerBorder = Color(red: 0.95, green: 0.84, blue: 0.82)
    static let dangerBgLight = Color(red: 0.98, green: 0.95, blue: 0.95)
    static let warningText = Color(red: 0.58, green: 0.39, blue: 0.10)

    // Chat
    static let chatBg = Color(red: 0.953, green: 0.957, blue: 0.961)
    static let userBubble = Color(red: 0.859, green: 0.918, blue: 0.996)
    static let botBubble = Color.white
    static let sendButton = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let sendButtonDark = Color(red: 0.18, green: 0.42, blue: 0.85)
    static let systemMsgBg = Color(red: 0.92, green: 0.93, blue: 0.94)

    // Surfaces & borders
    static let divider = Color(red: 0.894, green: 0.906, blue: 0.922)
    static let dividerLegacy = Color(red: 0.88, green: 0.88, blue: 0.88)
    static let panelBg = Color(red: 0.975, green: 0.975, blue: 0.975)
    static let controlBg = Color(red: 0.93, green: 0.94, blue: 0.94)
    static let statBg = Color(red: 0.965, green: 0.97, blue: 0.97)

    // Tag backgrounds
    static let accentBgLight = Color(red: 0.914, green: 0.964, blue: 0.940)
    static let accentBgActive = Color(red: 0.885, green: 0.949, blue: 0.922)
    static let incomeBgLight = Color(red: 0.980, green: 0.925, blue: 0.905)
    static let warningBg = Color(red: 1.0, green: 0.963, blue: 0.902)

    // Global background gradient
    static let pageBgTop = Color(red: 0.985, green: 0.992, blue: 0.989)
    static let pageBgMid = Color(red: 0.958, green: 0.979, blue: 0.972)
    static let pageBgBottom = Color(red: 0.946, green: 0.969, blue: 0.959)
    static let pageBlobA = Color(red: 0.885, green: 0.944, blue: 0.915)
    static let pageBlobB = Color(red: 0.907, green: 0.949, blue: 0.939)

    // Header / logo
    static let logoBgTop = Color(red: 0.929, green: 0.974, blue: 0.958)
    static let logoBorder = Color(red: 0.85, green: 0.914, blue: 0.889)
    static let headerTabBorder = Color(red: 0.865, green: 0.914, blue: 0.893)
    static let headerShadow = Color(red: 0.54, green: 0.69, blue: 0.64)
    static let ghostBorder = Color(red: 0.89, green: 0.937, blue: 0.918)

    // Avatar gradients
    static let assistantAvatarTop = Color(red: 0.938, green: 0.978, blue: 0.962)
    static let assistantAvatarBottom = Color(red: 0.864, green: 0.928, blue: 0.903)

    // Calendar selected cell gradient
    static let calendarSelectedTop = Color(red: 0.27, green: 0.54, blue: 0.46)
    static let calendarSelectedBottom = Color(red: 0.19, green: 0.45, blue: 0.39)

    // Calendar today marker
    static let calendarToday = Color(red: 0.165, green: 0.426, blue: 0.384)

    // Button primary background (dark)
    static let buttonPrimary = Color(red: 0.10, green: 0.22, blue: 0.24)

    // Ledger category filter pills
    static let filterMuted = Color(red: 0.45, green: 0.52, blue: 0.55)

    // Ledger special stat colors
    static let ledgerStatGoldBold = Color(red: 0.72, green: 0.46, blue: 0.10)
    static let ledgerStatGold = Color(red: 0.52, green: 0.37, blue: 0.12)
}
