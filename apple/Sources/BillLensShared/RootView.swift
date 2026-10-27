import SwiftUI
import UniformTypeIdentifiers
import BillLensAppleServices

public struct RootView: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPage: AppPage = .entry
    @State private var isImportingImage = false
    @State private var isImportingStatement = false
    /// 文件选择器的用途在触发时记录，关闭时不复位：isPresented 先于 onCompletion 置 false 时
    /// 仍能走正确的处理路径（否则账单文件会被当作图片识别）。
    @State private var importerTarget: ImporterTarget = .receiptImage
    @State private var statementPassword = ""
    @State private var showSettings = false
    @State private var showStatementDropSheet = false

    public init() {}

    public var body: some View {
        platformRoot
            // 同一视图上只能可靠挂一个 fileImporter，图片与账单共用，按触发来源切换类型。
            .fileImporter(
                isPresented: Binding(
                    get: { isImportingImage || isImportingStatement },
                    set: { if !$0 { isImportingImage = false; isImportingStatement = false } }
                ),
                allowedContentTypes: isImportingStatement ? StatementImportService.supportedTypes : [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        switch importerTarget {
                        case .statement:
                            store.importStatement(url: url)
                        case .receiptImage:
                            store.importReceipt(url: url)
                        }
                    }
                case .failure(let error):
                    store.errorText = error.localizedDescription
                }
            }
            .onChange(of: isImportingImage) { _, isOn in
                if isOn { importerTarget = .receiptImage }
            }
            .onChange(of: isImportingStatement) { _, isOn in
                if isOn { importerTarget = .statement }
            }
            .onDrop(of: [StatementImportService.emailType, .fileURL], isTargeted: nil, perform: handleDrop)
            // 下滑等系统关闭与「取消」相同：收件箱文件删除，不会在下次回到前台时再次弹出。
            .sheet(item: Binding(
                get: { store.statementImport },
                set: { if $0 == nil, store.statementImport != nil { store.cancelStatementImport() } }
            )) { session in
                StatementImportView(session: session)
                    .environmentObject(store)
            }
            .alert(
                store.statementPasswordRequest?.isRetry == true ? "密码不正确，请重新输入" : "PDF 已加密",
                isPresented: Binding(
                    get: { store.statementPasswordRequest != nil },
                    // 按钮动作负责清空密码与请求；关闭回调可能早于按钮动作执行，这里不能清空。
                    set: { _ in }
                ),
                presenting: store.statementPasswordRequest
            ) { request in
                SecureField("密码", text: $statementPassword)
                Button("取消", role: .cancel) {
                    statementPassword = ""
                    store.cancelStatementPassword()
                }
                Button("打开") {
                    let password = statementPassword
                    statementPassword = ""
                    store.statementPasswordRequest = nil
                    store.importStatement(url: request.fileURL, password: password, inboxFile: request.inboxFile)
                }
            } message: { _ in
                Text("招商银行账单 PDF 的密码通常与证件号相关，密码不会被保存。")
            }
            #if os(macOS)
            .sheet(isPresented: $showStatementDropSheet) {
                StatementDropSheet()
                    .environmentObject(store)
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsShell()
                    .environmentObject(store)
            }
            .overlay(alignment: .bottom) {
                errorBanner
            }
            .animation(.snappy, value: store.errorText)
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    store.checkStatementInbox()
                    Task { await store.syncMailbox(trigger: "foreground") }
                }
            }
    }

    /// macOS 打开带 AppKit 拖放区的导入面板（Mail 邮件只能这样接收）；iOS 直接打开文件选择器。
    private var statementImportTrigger: Binding<Bool> {
        #if os(macOS)
        $showStatementDropSheet
        #else
        $isImportingStatement
        #endif
    }

    private enum ImporterTarget {
        case receiptImage
        case statement
    }

    /// macOS 可把 Mail 中的邮件直接拖进窗口（Mail 提供 file promise，按邮件类型读取），
    /// 也可拖入 Finder 中的 .eml / .html / .pdf 文件。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        AppLogger.log(
            "statement.drop.window",
            "types=\(providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ","))"
        )
        let emailType = StatementImportService.emailType.identifier
        // NSItemProvider 回调在后台队列执行，闭包必须是 @Sendable（不继承 View 的 MainActor 隔离），
        // 只捕获 MainActor 类型的 store，界面更新切回主线程。
        let store = store
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(emailType) }) {
            _ = provider.loadFileRepresentation(forTypeIdentifier: emailType) { @Sendable url, error in
                // 回调返回后系统即删除该临时文件，先复制出来。
                let copy = url.flatMap { url -> URL? in
                    let target = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString).eml")
                    return (try? FileManager.default.copyItem(at: url, to: target)) == nil ? nil : target
                }
                let failure = error?.localizedDescription
                Task { @MainActor in
                    if let copy {
                        store.importStatement(url: copy)
                    } else {
                        store.errorText = failure ?? StatementImportError.unreadable.localizedDescription
                    }
                }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
            guard let url else { return }
            Task { @MainActor in
                if ["eml", "html", "htm", "pdf"].contains(url.pathExtension.lowercased()) {
                    store.importStatement(url: url)
                } else {
                    store.errorText = StatementImportError.unsupportedFile(url.lastPathComponent).localizedDescription
                }
            }
        }
        return true
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
            EntryShell(isImportingImage: $isImportingImage, isImportingStatement: statementImportTrigger)
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
