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
        .background(IMColors.pageBgTop.ignoresSafeArea())
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
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            store.errorText = nil
                        }
                    }
                }
            }
        }
    }

    private var appHeader: some View {
        #if os(iOS)
        let outerSpacing: CGFloat = 6
        let brandSpacing: CGFloat = 6
        let logoSize: CGFloat = 28
        let headerHorizontalPadding: CGFloat = 4
        let tabSpacing: CGFloat = 2
        let settingsButtonSize: CGFloat = 30
        #else
        let outerSpacing: CGFloat = 14
        let brandSpacing: CGFloat = 10
        let logoSize: CGFloat = 32
        let headerHorizontalPadding: CGFloat = 10
        let tabSpacing: CGFloat = 8
        let settingsButtonSize: CGFloat = 32
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
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColors.navText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("BillLens")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IMColors.navText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("账单助手")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(IMColors.navTextSecondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(2)

            Spacer(minLength: 4)

            HStack(spacing: tabSpacing) {
                headerTab(.entry)
                headerTab(.ledger)
                headerTab(.subscriptions)
                headerTab(.assets)
            }
            .padding(3)
            .background(.white.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(IMColors.headerTabBorder, lineWidth: 1)
            )
            .clipShape(Capsule())

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IMColors.navTextSecondary)
                    .frame(width: settingsButtonSize, height: settingsButtonSize)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(IMColors.headerTabBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSettings) {
                SettingsShell().environmentObject(store)
            }
        }
        .padding(.horizontal, headerHorizontalPadding)
        .frame(height: 48)
        .background(IMColors.navGlass)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: IMColors.headerShadow.opacity(0.18), radius: 30, x: 3, y: 5)
    }

    private func headerTab(_ page: AppPage) -> some View {
        #if os(iOS)
        let tabButtonSize: CGFloat = 32
        #endif

        return Button {
            selectedPage = page
        } label: {
            #if os(iOS)
            Image(systemName: page.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    selectedPage == page ? IMColors.navText : IMColors.navTextSecondary
                )
                .frame(width: tabButtonSize, height: tabButtonSize)
                .background(
                    Circle().fill(selectedPage == page ? Color.white.opacity(0.18) : .clear)
                )
                .contentShape(Circle())
            #else
            Text(page.title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(
                    selectedPage == page ? IMColors.navText : IMColors.navTextSecondary
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selectedPage == page ? Color.white.opacity(0.18) : .clear)
                )
                .contentShape(Capsule())
            #endif
        }
        .buttonStyle(.plain)
    }
}
