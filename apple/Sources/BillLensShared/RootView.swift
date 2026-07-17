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
        platformRoot
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
        .sheet(isPresented: $showSettings) {
            SettingsShell()
                .environmentObject(store)
        }
        .overlay(alignment: .bottom) {
            errorBanner
        }
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(iOS)
        iosRoot
        #else
        macRoot
        #endif
    }

    #if os(iOS)
    private var iosRoot: some View {
        TabView(selection: $selectedPage) {
            iosPage(.entry)
                .tabItem { Label(AppPage.entry.tabTitle, systemImage: AppPage.entry.icon) }
                .tag(AppPage.entry)
                .badge(store.drafts.count)

            iosPage(.ledger)
                .tabItem { Label(AppPage.ledger.tabTitle, systemImage: AppPage.ledger.icon) }
                .tag(AppPage.ledger)

            iosPage(.subscriptions)
                .tabItem { Label(AppPage.subscriptions.tabTitle, systemImage: AppPage.subscriptions.icon) }
                .tag(AppPage.subscriptions)

            iosPage(.assets)
                .tabItem { Label(AppPage.assets.tabTitle, systemImage: AppPage.assets.icon) }
                .tag(AppPage.assets)
        }
        .tint(IMColors.accent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(IMColors.surfaceStrong, for: .tabBar)
    }

    private func iosPage(_ page: AppPage) -> some View {
        NavigationStack {
            GeometryReader { proxy in
                pageContent(
                    page,
                    availableWidth: proxy.size.width,
                    availableHeight: proxy.size.height
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .navigationTitle(page.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    settingsButton
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(IMColors.pageBgTop.opacity(0.96), for: .navigationBar)
        }
    }
    #else
    private var macRoot: some View {
        NavigationSplitView {
            macSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            GeometryReader { proxy in
                pageContent(
                    selectedPage,
                    availableWidth: proxy.size.width,
                    availableHeight: proxy.size.height
                )
                .padding(16)
            }
            .navigationTitle(selectedPage.navigationTitle)
            .toolbar { macToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1120, minHeight: 720)
    }

    private var macSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IMColors.accent)
                Text("BillLens")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(AppPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.icon)
                    .font(.system(size: 14, weight: .medium))
                    .tag(page)
                    .accessibilityLabel(page.title)
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .accessibilityLabel("设置")
        }
        .background(.thinMaterial)
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !store.drafts.isEmpty {
                Label("待确认 \(store.drafts.count)", systemImage: "checklist")
                    .foregroundStyle(IMColors.accent)
            }
            if selectedPage == .entry {
                Button {
                    isImportingImage = true
                } label: {
                    Label("导入账单", systemImage: "doc.badge.plus")
                }
                .help("导入账单图片")
            }
        }
    }

    #endif

    @ViewBuilder
    private func pageContent(
        _ page: AppPage,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        switch page {
        case .entry:
            EntryShell(
                isImportingImage: $isImportingImage,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )
        case .ledger:
            LedgerShell(availableHeight: availableHeight)
        case .subscriptions:
            SubscriptionShell()
        case .assets:
            AssetShell()
        }
    }

    #if os(iOS)
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("设置")
    }
    #endif

    @ViewBuilder
    private var errorBanner: some View {
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
                .accessibilityLabel("关闭错误提示")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(IMColors.dangerBg, in: Capsule(style: .continuous))
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
            .padding(.bottom, errorBottomPadding)
        }
    }

    private var errorBottomPadding: CGFloat {
        #if os(iOS)
        64
        #else
        18
        #endif
    }
}

private struct AppBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.975, green: 0.980, blue: 0.986),
                Color(red: 0.955, green: 0.965, blue: 0.975)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
