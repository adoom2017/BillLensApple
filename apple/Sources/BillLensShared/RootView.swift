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
            .fileImporter(
                isPresented: $isImportingImage,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        store.importReceipt(url: url)
                    }
                case .failure(let error):
                    store.errorText = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsShell()
                    .environmentObject(store)
            }
            .overlay(alignment: .bottom) {
                errorBanner
            }
            .animation(.snappy, value: store.errorText)
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
            ForEach(AppPage.allCases) { page in
                NavigationStack {
                    pageContent(page)
                        .navigationTitle(page.title)
                        .navigationBarTitleDisplayMode(page == .entry ? .inline : .large)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                settingsButton
                            }
                        }
                }
                .tabItem { Label(page.title, systemImage: page.icon) }
                .tag(page)
                .badge(page == .entry ? store.drafts.count : 0)
            }
        }
    }
    #else
    private var macRoot: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.icon)
                    .badge(page == .entry ? store.drafts.count : 0)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                settingsButton
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        } detail: {
            NavigationStack {
                pageContent(selectedPage)
                    .navigationTitle(selectedPage.title)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
    #endif

    @ViewBuilder
    private func pageContent(_ page: AppPage) -> some View {
        switch page {
        case .entry:
            EntryShell(isImportingImage: $isImportingImage)
        case .ledger:
            LedgerShell()
        case .subscriptions:
            SubscriptionShell()
        case .assets:
            AssetShell()
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("设置", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
        .help("设置（⌘,）")
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorText = store.errorText {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text(errorText)
                    .font(.callout)
                    .lineLimit(3)
                Button {
                    store.errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭错误提示")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .floatingGlass(in: Capsule())
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.bottom, errorBottomPadding)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: errorText) {
                try? await Task.sleep(for: .seconds(5))
                if store.errorText == errorText {
                    store.errorText = nil
                }
            }
        }
    }

    private var errorBottomPadding: CGFloat {
        #if os(iOS)
        // 避开底部 Tab 栏与输入栏。
        120
        #else
        80
        #endif
    }
}
