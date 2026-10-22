import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppPage: String, CaseIterable, Identifiable {
    case entry
    case ledger
    case subscriptions
    case assets

    var id: Self { self }

    var title: String {
        switch self {
        case .entry: "记账"
        case .ledger: "账单"
        case .subscriptions: "订阅"
        case .assets: "资产"
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
}

/// 只使用系统语义色，自动适配浅色 / 深色 / 高对比度。
enum AppColors {
    static let income = Color.green
    static let destructive = Color.red
    static let warning = Color.orange
    static let today = Color.red

    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var contentBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }

    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

/// 设置 App 风格的圆角方块图标。
struct CategoryIcon: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum CategoryStyle {
    static func icon(for category: String) -> String {
        switch category {
        case "餐饮": "fork.knife"
        case "交通": "car.fill"
        case "日用": "basket.fill"
        case "购物": "bag.fill"
        case "住房": "house.fill"
        case "医疗": "cross.case.fill"
        case "娱乐": "gamecontroller.fill"
        case "教育": "book.fill"
        case "通讯": "phone.fill"
        case "人情": "gift.fill"
        case "订阅": "repeat"
        case "工资收入": "briefcase.fill"
        case "投资收益": "chart.line.uptrend.xyaxis"
        case "报销": "doc.text.fill"
        case "退款": "arrow.uturn.backward"
        default: "tag.fill"
        }
    }

    static func color(for category: String) -> Color {
        switch category {
        case "餐饮": .orange
        case "交通": .blue
        case "日用": .teal
        case "购物": .pink
        case "住房": .brown
        case "医疗": .red
        case "娱乐": .purple
        case "教育": .indigo
        case "通讯": .green
        case "人情": .red
        case "订阅": .cyan
        case "工资收入", "投资收益": .green
        case "报销": .mint
        case "退款": .yellow
        default: .gray
        }
    }

    static func assetIcon(for category: String) -> String {
        switch category {
        case "存款": "building.columns.fill"
        case "现金": "banknote.fill"
        case "股票": "chart.bar.fill"
        case "基金": "chart.pie.fill"
        case "加密货币": "bitcoinsign.circle.fill"
        case "房产": "house.fill"
        default: "creditcard.fill"
        }
    }

    static func assetColor(for category: String) -> Color {
        switch category {
        case "存款": .blue
        case "现金": .green
        case "股票": .red
        case "基金": .orange
        case "加密货币": .yellow
        case "房产": .brown
        default: .gray
        }
    }
}

extension View {
    /// 浮动控件（输入栏、提示条）使用 Liquid Glass；旧系统退回系统材质。
    @ViewBuilder
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }
}
