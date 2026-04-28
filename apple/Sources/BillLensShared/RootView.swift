#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers


public struct RootView: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var selectedPage: AppPage = .entry
    @State private var isImportingImage = false
    @State private var showSettings = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init() {}

    public var body: some View {
        VStack(spacing: LayoutMetrics.headerSpacing) {
            appHeader

            GeometryReader { proxy in
                Group {
                    switch selectedPage {
                    case .entry:
                        EntryShell(
                            isImportingImage: $isImportingImage,
                            availableWidth: proxy.size.width,
                            availableHeight: max(proxy.size.height, 640)
                        )
                    case .ledger:
                        LedgerShell(availableHeight: max(proxy.size.height, 640))
                    case .subscriptions:
                        SubscriptionShell()
                    case .assets:
                        AssetShell()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, LayoutMetrics.pagePadding)
        .padding(.top, LayoutMetrics.pageTopPadding)
        .padding(.bottom, LayoutMetrics.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .frame(minWidth: 1120, minHeight: 720)
        #endif
        .background(AppBackdrop().ignoresSafeArea())
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importReceipt(url: url)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText = store.errorText {
                HStack(spacing: 8) {
                    Text(errorText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Button {
                        store.errorText = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(IMColors.dangerBg)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    let snapshot = store.errorText
                    try? await Task.sleep(for: .seconds(5))
                    if store.errorText == snapshot {
                        withAnimation(.easeOut(duration: 0.3)) {
                            store.errorText = nil
                        }
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private var appHeader: some View {
        #if os(iOS)
        let outerSpacing: CGFloat = 6
        let brandSpacing: CGFloat = 6
        let logoSize: CGFloat = 24
        let headerHorizontalPadding: CGFloat = 4
        let settingsButtonSize: CGFloat = 28
        #else
        let outerSpacing: CGFloat = 12
        let brandSpacing: CGFloat = 8
        let logoSize: CGFloat = 26
        let headerHorizontalPadding: CGFloat = 10
        let settingsButtonSize: CGFloat = 30
        #endif

        return HStack(alignment: .center, spacing: outerSpacing) {
            HStack(spacing: brandSpacing) {
                ZStack {
                    Circle()
                        .fill(IMColors.logoBgTop)
                        .frame(width: logoSize, height: logoSize)
                        .overlay(
                            Circle()
                                .stroke(IMColors.logoBorder, lineWidth: 1)
                        )
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColors.navText)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("BillLens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColors.navText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("账单助手")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(IMColors.navTextSecondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(2)

            Spacer(minLength: 8)

            mergedNavBar
                .layoutPriority(1)

            Spacer(minLength: 8)

            if showsHeaderStats {
                headerStatusPanel
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.navTextSecondary)
                    .frame(width: settingsButtonSize, height: settingsButtonSize)
                    .appCircleGlass(
                        prominence: .regular,
                        interactive: true,
                        tint: IMColors.accentBright.opacity(0.10),
                        fallbackFill: IMColors.surfaceStrong
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSettings) {
                SettingsShell().environmentObject(store)
            }
        }
        .padding(.horizontal, headerHorizontalPadding)
        .padding(.vertical, 8)
        .appRoundedGlass(
            cornerRadius: 18,
            prominence: .prominent,
            tint: IMColors.accentBright.opacity(0.10),
            fallbackFill: IMColors.navGlass
        )
    }

    private var headerStatusPanel: some View {
        HStack(spacing: 10) {
            HeaderStatusChip(
                title: "待确认",
                value: "\(store.drafts.count)",
                highlight: store.drafts.isEmpty ? IMColors.textSecondary : IMColors.accentDark
            )
            HeaderStatusChip(
                title: "最近入库",
                value: store.latestRecord.map { BillLensFormatters.currencyString($0.amount, currencyCode: $0.currency) } ?? "暂无",
                highlight: IMColors.textPrimary
            )
        }
    }

    private var mergedNavBar: some View {
        HStack(spacing: 8) {
            ForEach(AppPage.allCases, id: \.rawValue) { page in
                bottomDockItem(page)
            }
        }
        .padding(.horizontal, compactDock ? 2 : 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.40), lineWidth: 1)
        )
    }

    private func bottomDockItem(_ page: AppPage) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) {
                selectedPage = page
            }
        } label: {
            HStack(spacing: compactDock ? 0 : 8) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selectedPage == page ? .white : IMColors.navTextSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(selectedPage == page ? IMColors.accent : Color.white.opacity(0.44))
                    )

                if !compactDock {
                    Text(page.title)
                        .font(.system(size: 12, weight: selectedPage == page ? .semibold : .medium))
                        .foregroundStyle(selectedPage == page ? IMColors.navText : IMColors.navTextSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compactDock ? 6 : 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedPage == page ? Color.white.opacity(0.52) : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(selectedPage == page ? 0.72 : 0.0), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(selectedPage == page ? IMColors.accent.opacity(0.92) : .clear)
                    .frame(width: compactDock ? 16 : 24, height: 3)
                    .offset(y: 6)
            }
            .scaleEffect(selectedPage == page ? 1.0 : 0.97)
            .shadow(
                color: selectedPage == page
                    ? IMColors.accent.opacity(0.16)
                    : .clear,
                radius: 10,
                y: 6
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var showsHeaderStats: Bool {
        #if os(iOS)
        return sizeClass != .compact
        #else
        return true
        #endif
    }

    private var compactDock: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }
}

private struct HeaderStatusChip: View {
    let title: String
    let value: String
    let highlight: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlight)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.38))
        )
    }
}

private struct AppBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [IMColors.pageBgTop, IMColors.pageBgMid, IMColors.pageBgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(IMColors.pageBlobA)
                .frame(width: 320, height: 320)
                .blur(radius: 18)
                .offset(x: -280, y: -220)

            Circle()
                .fill(IMColors.pageBlobB)
                .frame(width: 260, height: 260)
                .blur(radius: 16)
                .offset(x: 300, y: -170)

            Circle()
                .fill(IMColors.pageBlobA.opacity(0.45))
                .frame(width: 360, height: 360)
                .blur(radius: 20)
                .offset(x: 360, y: 300)
        }
    }
}
