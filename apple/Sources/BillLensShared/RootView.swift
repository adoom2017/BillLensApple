import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppPage: String {
    case entry
    case ledger

    var title: String {
        switch self {
        case .entry: "账单录入"
        case .ledger: "账单一览"
        }
    }
}

private enum LayoutMetrics {
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

private enum IMColors {
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

public struct RootView: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var selectedPage: AppPage = .entry
    @State private var isImportingImage = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: LayoutMetrics.headerSpacing) {
                appHeader

                Group {
                    switch selectedPage {
                    case .entry:
                        EntryShell(
                            isImportingImage: $isImportingImage,
                            availableWidth: proxy.size.width - LayoutMetrics.pagePadding * 2,
                            availableHeight: max(proxy.size.height - 82, 640)
                        )
                    case .ledger:
                        LedgerShell(availableHeight: max(proxy.size.height - 82, 640))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, LayoutMetrics.pagePadding)
            .padding(.top, LayoutMetrics.pageTopPadding)
            .padding(.bottom, LayoutMetrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        IMColors.pageBgTop,
                        IMColors.pageBgMid,
                        IMColors.pageBgBottom,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(IMColors.pageBlobA.opacity(0.65))
                    .frame(width: 480, height: 480)
                    .blur(radius: 30)
                    .offset(x: -440, y: -340)
                Circle()
                    .fill(IMColors.pageBlobB.opacity(0.7))
                    .frame(width: 360, height: 360)
                    .blur(radius: 18)
                    .offset(x: 480, y: 300)
            }
            .ignoresSafeArea()
        )
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
                Text(errorText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(IMColors.dangerBg)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                    .padding(.bottom, 18)
            }
        }
    }

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    IMColors.logoBgTop, Color.white,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(IMColors.logoBorder, lineWidth: 1)
                        )
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColors.accentAlt)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("BillLens")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Text("账单助手")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                headerTab(.entry)
                headerTab(.ledger)
            }
            .padding(5)
            .background(.white.opacity(0.82))
            .overlay(
                Capsule()
                    .stroke(IMColors.headerTabBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(
                color: IMColors.headerShadow.opacity(0.08), radius: 12, y: 4)
        }
    }

    private func headerTab(_ page: AppPage) -> some View {
        Button {
            selectedPage = page
        } label: {
            Text(page.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    selectedPage == page
                        ? IMColors.accent
                        : IMColors.textMuted
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            selectedPage == page
                                ? IMColors.accentBgActive : .clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct EntryShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat

    private var reviewWidth: CGFloat {
        let w = availableWidth * 0.38
        return min(max(360, w), 440)
    }

    var body: some View {
        HStack(spacing: 0) {
            chatSide
            groovedDivider
            reviewSide
        }
        .frame(width: availableWidth, height: availableHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var chatWidth: CGFloat {
        availableWidth - reviewWidth - 1
    }

    private var chatSide: some View {
        ChatPanel(isImportingImage: $isImportingImage)
            .frame(width: chatWidth)
            .frame(maxHeight: .infinity)
            .background(IMColors.chatBg)
            .clipShape(Rectangle())
    }

    private var groovedDivider: some View {
        IMColors.divider
            .frame(width: 1)
    }

    private var reviewSide: some View {
        ReviewPanel()
            .frame(width: reviewWidth)
            .frame(maxHeight: .infinity)
            .background(Color.white)
            .clipShape(Rectangle())
    }
}

private struct ChatPanel: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatScrollView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .clipShape(Rectangle())

            ComposerPanel(
                composerText: $store.composerText,
                autoConfirm: $store.autoConfirm,
                isRecording: store.speechService.isRecording,
                statusText: store.statusText,
                onImage: { isImportingImage = true },
                onVoice: { store.toggleRecording() },
                onSubmit: { store.submitText() }
            )
        }
    }
}

private struct ChatScrollView: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        GeometryReader { scrollProxy in
            ScrollViewReader { reader in
                ScrollView {
                    chatContent(width: max(scrollProxy.size.width - 10, 0))
                        .padding(.trailing, 10)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    reader.scrollTo("chatBottom")
                }
                .onChange(of: store.messages.count) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.drafts.count) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.latestRecord?.id) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.transientProgressMessage?.id) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.speechService.liveTranscript) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.speechService.isRecording) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
            }
        }
    }

    private func chatContent(width: CGFloat) -> some View {
        LazyVStack(spacing: LayoutMetrics.messageGap) {
            WelcomeBubble()

            ForEach(store.messages) { message in
                MessageBubble(message: message)
            }

            if store.speechService.isRecording {
                SpeechLiveBubble(transcript: store.speechService.liveTranscript)
            }

            if let progress = store.transientProgressMessage {
                ProgressBubble(message: progress.content)
            }

            if !store.drafts.isEmpty {
                let draftCount = store.drafts.count
                ForEach(Array(store.drafts.enumerated()), id: \.element.id) { index, draft in
                    DraftConversationCard(
                        title: draftCount > 1
                            ? "[\(index + 1)/\(draftCount)] \(draft.merchant ?? draft.note ?? "待确认账单")"
                            : (draft.note ?? draft.merchant ?? "待确认账单"),
                        direction: draft.direction ?? "expense",
                        amount: draft.amount,
                        currency: draft.currency,
                        category: draft.category ?? "未分类",
                        merchant: draft.merchant ?? "未填写商户",
                        transactionAt: draft.transactionAt,
                        status: "待确认",
                        copy: draftCount > 1
                            ? "共 \(draftCount) 笔待确认账单，点击可切换编辑。"
                            : "已为你解析出一张待确认账单。若要修改，可以继续说\"改成300元\"，右侧表单也支持直接手动编辑。"
                    )
                    .opacity(index == store.activeDraftIndex ? 1.0 : 0.7)
                    .onTapGesture { store.selectDraft(at: index) }
                }
            } else if let record = store.latestRecord {
                DraftConversationCard(
                    title: record.note ?? record.merchant ?? "最近入库账单",
                    direction: record.direction,
                    amount: record.amount,
                    currency: record.currency,
                    category: record.category,
                    merchant: record.merchant ?? "未填写商户",
                    transactionAt: record.transactionAt,
                    status: "已入库",
                    copy: "最近确认入库的一笔账单如下。"
                )
            }

            Color.clear.frame(height: 1).id("chatBottom")
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct ReviewPanel: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("核对确认")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                    StatusPill(title: store.drafts.isEmpty ? "等待解析" : "待确认 (\(store.drafts.count))", warning: !store.drafts.isEmpty)
                }
                Text("左侧发送后自动更新，也可直接手动修改。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColors.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            IMColors.divider.frame(height: 1)

            // Amount summary — flat, no border
            ReviewSummaryCard(
                direction: store.draftForm.direction,
                amount: store.currentDraft?.amount,
                currency: store.currentDraft?.currency ?? store.draftForm.currency,
                meta: reviewSummaryMeta
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            IMColors.divider.frame(height: 1)

            if store.currentDraft == nil {
                EmptyReviewState(latestRecord: store.latestRecord)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                GeometryReader { scrollProxy in
                    ScrollView {
                        reviewFields
                            .frame(width: max(scrollProxy.size.width - 2, 0), alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                IMColors.divider.frame(height: 1)

                reviewActions
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private var reviewSummaryMeta: String {
        if let draft = store.currentDraft {
            let indexLabel = store.drafts.count > 1 ? "第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔 · " : ""
            return
                "\(indexLabel)\(draft.category ?? "未分类") · \(draft.merchant ?? "未填写商户") · \(BillLensFormatters.displayDateTime(draft.transactionAt))"
        }
        return "等待新的账单解析结果"
    }

    private var reviewFields: some View {
        VStack(spacing: 8) {
            ReviewField(title: "类型") {
                Picker(
                    "",
                    selection: Binding(
                        get: { store.draftForm.direction },
                        set: { store.setDraftDirection($0) }
                    )
                ) {
                    Text("支出").tag("expense")
                    Text("收入").tag("income")
                }
                .pickerStyle(.segmented)
            }

            ReviewField(title: "金额") {
                TextField("0.00", text: $store.draftForm.amount)
                    .textFieldStyle(.plain)
            }

            ReviewField(title: "币种") {
                TextField(
                    "例如：CNY / USD / EUR",
                    text: Binding(
                        get: { store.draftForm.currency },
                        set: { store.draftForm.currency = $0.uppercased() }
                    )
                )
                .textFieldStyle(.plain)
            }

            ReviewField(title: "分类") {
                Picker("", selection: $store.draftForm.category) {
                    ForEach(store.availableCategories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ReviewField(title: "商户") {
                TextField("例如：牛肉馆", text: $store.draftForm.merchant)
                    .textFieldStyle(.plain)
            }

            ReviewField(title: "时间") {
                DatePicker("", selection: $store.draftForm.transactionAt)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ReviewField(title: "备注", minimumHeight: LayoutMetrics.noteHeight, alignTop: true) {
                TextEditor(text: $store.draftForm.note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 44)
            }
        }
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.drafts.count > 1 {
                HStack(spacing: 8) {
                    Button(action: { store.selectDraft(at: store.activeDraftIndex - 1) }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(store.activeDraftIndex <= 0)

                    Text("第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textSecondary)

                    Button(action: { store.selectDraft(at: store.activeDraftIndex + 1) }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(store.activeDraftIndex >= store.drafts.count - 1)

                    Spacer()
                }
            }

            Text("确认后将写入数据库，并同步出现在账单一览中。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ActionButton(title: "删除", kind: .dangerGhost, minWidth: 56) {
                    store.discardDraft()
                }
                ActionButton(title: "保存", kind: .ghost, minWidth: 56) {
                    store.saveDraft()
                }
                ActionButton(title: "确认入库", kind: .primary, minWidth: 76) {
                    store.confirmDraft()
                }
                if store.drafts.count > 1 {
                    ActionButton(title: "全部确认", kind: .primary, minWidth: 76) {
                        store.confirmAllDrafts()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }
}

private struct LedgerShell: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var ledgerMode: LedgerViewMode = .calendar
    @State private var selectedLedgerDate: String?
    @State private var cachedCalendarCells: [LedgerCalendarCell] = []
    @State private var cachedCalendarKey: String = ""
    @State private var selectedCategoryFilter: String? = nil
    @State private var recordToDelete: RecordItem? = nil
    let availableHeight: CGFloat

    private let masterWidth: CGFloat = 340

    var body: some View {
        Group {
            if let ledger = store.ledger {
                HStack(spacing: 0) {
                    // MARK: - Left Master Panel
                    VStack(alignment: .leading, spacing: 16) {
                        // Time preset tabs
                        HStack(spacing: 4) {
                            ForEach(LedgerPreset.allCases) { preset in
                                Button {
                                    store.applyPreset(preset)
                                } label: {
                                    Text(preset.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(
                                            store.selectedPreset == preset
                                                ? IMColors.textPrimary
                                                : IMColors.textSecondary
                                        )
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(
                                                    store.selectedPreset == preset
                                                        ? IMColors.controlBg
                                                        : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if store.selectedPreset == .custom {
                            HStack(spacing: 6) {
                                DatePicker("", selection: $store.customStart, displayedComponents: .date)
                                    .labelsHidden()
                                    .frame(width: 100)
                                Text("–")
                                    .foregroundStyle(IMColors.textMuted)
                                    .font(.system(size: 12))
                                DatePicker("", selection: $store.customEnd, displayedComponents: .date)
                                    .labelsHidden()
                                    .frame(width: 100)
                                ActionButton(title: "应用", kind: .ghost) {
                                    store.applyPreset(.custom)
                                }
                            }
                        }

                        // Stat bar with inset shadow
                        statBar(ledger)

                        // Calendar or monthly aggregation
                        if store.selectedPreset == .year {
                            monthlyAggregationGrid(ledger)
                        } else {
                            calendarPanel(ledger)
                        }

                        // Quick category filters
                        quickCategoryFilters(ledger)
                    }
                    .frame(width: masterWidth)
                    .padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(IMColors.panelBg)

                    // MARK: - Grooved Divider
                    ZStack {
                        IMColors.dividerLegacy
                            .frame(width: 1)
                        Color.white.opacity(0.5)
                            .frame(width: 1)
                            .offset(x: 1)
                    }
                    .frame(width: 2)

                    // MARK: - Right Detail Panel
                    VStack(alignment: .leading, spacing: 0) {
                        // Mode tabs at top of detail (hide "按日" in year mode)
                        if store.selectedPreset != .year {
                            HStack(spacing: 4) {
                                ledgerModeButton(.calendar, title: "按日")
                                ledgerModeButton(.detail, title: "全部明细")
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                            Divider().opacity(0.2)
                        }

                        Group {
                            if store.selectedPreset == .year {
                                detailLedgerView(ledger)
                            } else {
                                switch ledgerMode {
                                case .calendar:
                                    rightPanelCalendarDetail(ledger)
                                case .detail:
                                    detailLedgerView(ledger)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                }
                .onAppear {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: ledgerSignature(ledger)) {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: selectedLedgerDate) {
                    updateCalendarCellSelection()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在加载账单视图")
                        .font(.system(size: 16, weight: .semibold))
                    Text("首次启动后会自动读取本地账本数据。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxHeight: availableHeight)
        .alert(
            "确认删除",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { recordToDelete = nil }
            Button("删除", role: .destructive) {
                if let record = recordToDelete {
                    store.deleteRecord(record.id)
                    recordToDelete = nil
                }
            }
        } message: {
            if let record = recordToDelete {
                Text("确定要删除「\(record.merchant ?? record.category) \(BillLensFormatters.currencyString(record.amount, currencyCode: record.currency))」吗？")
            }
        }
    }

    private func statBar(_ ledger: LedgerSnapshot) -> some View {
        let billCount = ledger.byDay.reduce(0) { $0 + $1.records.count }
        let statBg = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                LedgerSummaryCard(
                    title: "支出",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.expenseAmount,
                        currencyCode: ledger.statsCurrency
                    ),
                    accent: .expense
                )
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(
                    title: "收入",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.incomeAmount,
                        currencyCode: ledger.statsCurrency
                    ),
                    accent: .income
                )
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(title: "笔数", value: "\(billCount)", accent: .neutral)
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(title: "同步", value: "\(ledger.pendingSyncCount)", accent: .neutral)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                statBg
                    .fill(IMColors.statBg)
                    .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
                    .overlay(statBg.stroke(Color.black.opacity(0.04), lineWidth: 0.5))
            )

            if let warning = ledger.fxWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColors.ledgerStatGoldBold)
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.ledgerStatGold)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(IMColors.warningBg)
                )
            }
        }
    }

    private func ledgerModeButton(_ mode: LedgerViewMode, title: String) -> some View {
        Button {
            ledgerMode = mode
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    ledgerMode == mode
                        ? IMColors.textPrimary
                        : IMColors.textSecondary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            ledgerMode == mode
                                ? IMColors.controlBg
                                : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func rightPanelCalendarDetail(_ ledger: LedgerSnapshot) -> some View {
        Group {
            if let selectedGroup = selectedLedgerGroup(in: ledger) {
                ScrollView {
                    ledgerDayDetail(selectedGroup, statsCurrency: ledger.statsCurrency)
                }
                .scrollIndicators(.automatic)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(IMColors.textPlaceholder)
                    Text("请在月历中选择一天查看明细")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IMColors.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func quickCategoryFilters(_ ledger: LedgerSnapshot) -> some View {
        let allCategories = Array(Set(ledger.byDay.flatMap { $0.records.map(\.category) })).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text("筛选分类")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IMColors.textSecondary)
            WrappingHStack(alignment: .leading, spacing: 6) {
                categoryPill(title: "全部", isSelected: selectedCategoryFilter == nil) {
                    selectedCategoryFilter = nil
                }
                ForEach(allCategories, id: \.self) { cat in
                    categoryPill(title: cat, isSelected: selectedCategoryFilter == cat) {
                        selectedCategoryFilter = (selectedCategoryFilter == cat) ? nil : cat
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundStyle(
                    isSelected
                        ? IMColors.textPrimary
                        : IMColors.filterMuted
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white)
                        .shadow(
                            color: isSelected ? Color.clear : Color.black.opacity(0.06),
                            radius: isSelected ? 0 : 2, x: 0, y: 1
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.black.opacity(isSelected ? 0.08 : 0.03), lineWidth: 0.5)
                )
                .overlay(
                    isSelected
                        ? Capsule()
                            .fill(Color.black.opacity(0.03))
                        : nil
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func calendarPanel(_ ledger: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.shiftLedgerMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.selectedYear)年\(store.selectedMonth)月")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(calendarMetaText(ledger))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }

                Spacer()

                Button {
                    store.shiftLedgerMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4
            ) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4
            ) {
                ForEach(cachedCalendarCells) { cell in
                    if let day = cell.dayNumber, let date = cell.date {
                        CalendarDayCellButton(
                            day: day,
                            date: date,
                            amountText: cell.amountText,
                            isSelected: cell.isSelected,
                            isHot: cell.isHot,
                            isToday: cell.isToday,
                            backgroundStyle: calendarCellBackground(for: cell)
                        ) {
                            selectedLedgerDate = date
                        }
                    } else {
                        Color.clear
                            .frame(minHeight: 54)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func monthlyAggregationGrid(_ ledger: LedgerSnapshot) -> some View {
        let monthlyData = buildMonthlyAggregation(from: ledger)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.shiftLedgerYear(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.selectedYear)年")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Text("按月聚合 · \(monthlyData.filter { $0.hasData }.count) 个月有账单")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }

                Spacer()

                Button {
                    store.shiftLedgerYear(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
            ) {
                ForEach(monthlyData) { item in
                    MonthAggregationCard(item: item)
                }
            }
        }
    }

    fileprivate struct MonthlyAggregationItem: Identifiable {
        let id: Int
        let month: Int
        let expenseAmount: Double
        let incomeAmount: Double
        let recordCount: Int
        let statsCurrency: String
        var hasData: Bool { recordCount > 0 }
    }

    private func buildMonthlyAggregation(from ledger: LedgerSnapshot) -> [MonthlyAggregationItem] {
        var byMonth: [Int: (expense: Double, income: Double, count: Int)] = [:]
        for m in 1...12 { byMonth[m] = (0, 0, 0) }

        for day in ledger.byDay {
            let parts = day.day.split(separator: "-")
            guard parts.count >= 2, let month = Int(parts[1]) else { continue }
            let existing = byMonth[month] ?? (0, 0, 0)
            byMonth[month] = (
                existing.expense + day.expenseAmount,
                existing.income + day.incomeAmount,
                existing.count + day.records.count
            )
        }

        return (1...12).map { m in
            let data = byMonth[m]!
            return MonthlyAggregationItem(
                id: m,
                month: m,
                expenseAmount: data.expense,
                incomeAmount: data.income,
                recordCount: data.count,
                statsCurrency: ledger.statsCurrency
            )
        }
    }

    private func detailLedgerView(_ ledger: LedgerSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ledger.byDay) { day in
                    let records = filteredRecords(day.records)
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(BillLensFormatters.displayDay(day.day))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(IMColors.textPrimary)
                                Spacer()
                                Text(
                                    "净额 \(BillLensFormatters.currencyString(day.netAmount, currencyCode: ledger.statsCurrency))"
                                )
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(
                                        day.netAmount >= 0
                                            ? IMColors.income
                                            : IMColors.accentDark)
                            }
                            ForEach(records) { record in
                                RecordRowView(record: record) { recordToDelete = record }
                                    .padding(.vertical, 6)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        Divider().opacity(0.15).padding(.horizontal, 16)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func filteredRecords(_ records: [RecordItem]) -> [RecordItem] {
        guard let filter = selectedCategoryFilter else { return records }
        return records.filter { $0.category == filter }
    }

    private func ledgerDayDetail(_ day: LedgerDayGroup, statsCurrency: String) -> some View {
        let records = filteredRecords(day.records)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(BillLensFormatters.displayDay(day.day))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                    Text(
                        "支出 \(BillLensFormatters.currencyString(day.expenseAmount, currencyCode: statsCurrency))"
                    )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }
            }

            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    Divider().opacity(0.4)
                }
                RecordRowView(record: record) { recordToDelete = record }
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
    }

    private func syncCalendarState(for ledger: LedgerSnapshot) {
        let validDates = Set(ledger.byDay.map(\.day))
        if selectedLedgerDate == nil || !validDates.contains(selectedLedgerDate!) {
            selectedLedgerDate = ledger.byDay.last?.day
        }
    }

    private func ledgerSignature(_ ledger: LedgerSnapshot) -> String {
        ledger.byDay.map(\.day).joined(separator: "|")
    }

    private func calendarMetaText(_ ledger: LedgerSnapshot) -> String {
        let daysWithData = ledger.byDay.count
        return daysWithData == 0 ? "暂无账单" : "按天聚合 · \(daysWithData) 天"
    }

    private func selectedLedgerGroup(in ledger: LedgerSnapshot) -> LedgerDayGroup? {
        guard let selectedLedgerDate else { return nil }
        return ledger.byDay.first(where: { $0.day == selectedLedgerDate })
    }

    private func rebuildCalendarCellsIfNeeded(for ledger: LedgerSnapshot) {
        let key = "\(store.selectedYear)-\(store.selectedMonth)|\(ledgerSignature(ledger))"
        guard key != cachedCalendarKey else { return }
        cachedCalendarKey = key
        cachedCalendarCells = buildCalendarCells(for: ledger)
    }

    private func updateCalendarCellSelection() {
        cachedCalendarCells = cachedCalendarCells.map { cell in
            guard cell.dayNumber != nil else { return cell }
            let selected = cell.date == selectedLedgerDate
            guard selected != cell.isSelected else { return cell }
            return LedgerCalendarCell(
                id: cell.id,
                date: cell.date,
                dayNumber: cell.dayNumber,
                amountText: cell.amountText,
                isSelected: selected,
                isHot: cell.isHot,
                isToday: cell.isToday
            )
        }
    }

    private func buildCalendarCells(for ledger: LedgerSnapshot) -> [LedgerCalendarCell] {
        let year = store.selectedYear
        let month = store.selectedMonth

        let hottestDate = ledger.byDay.max(by: { $0.expenseAmount < $1.expenseAmount })?.day
        let groupMap = Dictionary(uniqueKeysWithValues: ledger.byDay.map { ($0.day, $0) })
        let todayString: String = {
            let now = Date()
            let y = Calendar.current.component(.year, from: now)
            let m = Calendar.current.component(.month, from: now)
            let d = Calendar.current.component(.day, from: now)
            return String(format: "%04d-%02d-%02d", y, m, d)
        }()
        let firstWeekday =
            Calendar.current.component(.weekday, from: dateFrom(year: year, month: month, day: 1))
            - 1
        let daysInMonth =
            Calendar.current.range(
                of: .day, in: .month, for: dateFrom(year: year, month: month, day: 1))?.count ?? 0

        var cells: [LedgerCalendarCell] = []
        for i in 0..<firstWeekday {
            cells.append(LedgerCalendarCell(
                id: i, date: nil, dayNumber: nil, amountText: "", isSelected: false, isHot: false, isToday: false
            ))
        }
        for day in 1...daysInMonth {
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let group = groupMap[date]
            let amount = group.map {
                $0.expenseAmount > 0 ? $0.expenseAmount : max($0.incomeAmount, abs($0.netAmount))
            }
            cells.append(
                LedgerCalendarCell(
                    id: firstWeekday + day - 1,
                    date: date,
                    dayNumber: day,
                    amountText: amount.map { compactAmount($0, currencyCode: ledger.statsCurrency) } ?? "",
                    isSelected: date == selectedLedgerDate,
                    isHot: date == hottestDate && amount != nil,
                    isToday: date == todayString
                )
            )
        }
        while cells.count % 7 != 0 {
            let idx = cells.count
            cells.append(LedgerCalendarCell(
                id: idx, date: nil, dayNumber: nil, amountText: "", isSelected: false, isHot: false, isToday: false
            ))
        }
        return cells
    }

    private func calendarCellBackground(for cell: LedgerCalendarCell) -> some ShapeStyle {
        if cell.isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        IMColors.calendarSelectedTop,
                        IMColors.calendarSelectedBottom,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(Color.clear)
    }

    private func compactAmount(_ amount: Double, currencyCode: String) -> String {
        let code = BillLensFormatters.normalizedCurrencyCode(currencyCode) ?? "CNY"
        let prefix = code == "CNY" ? "¥" : "\(code) "
        if amount >= 1000 {
            return prefix + String(format: "%.1fk", amount / 1000)
        }
        return "\(prefix)\(Int(amount.rounded()))"
    }

    private func dateFrom(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return Calendar.current.date(from: components) ?? .now
    }
}

private enum LedgerViewMode {
    case calendar
    case detail
}

private struct LedgerCalendarCell: Identifiable {
    let id: Int
    let date: String?
    let dayNumber: Int?
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool
}

private struct CalendarCellLabel: View {
    let day: Int
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 1) {
            ZStack(alignment: .top) {
                Text("\(day)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(dayTextColor)
                if isToday && !isSelected {
                    Circle()
                        .fill(IMColors.calendarToday)
                        .frame(width: 4, height: 4)
                        .offset(y: -2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text(amountText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(amountTextColor)
                .lineLimit(1)
        }
    }

    private var dayTextColor: Color {
        isSelected ? .white : IMColors.textPrimary
    }

    private var amountTextColor: Color {
        if isSelected {
            return Color.white.opacity(0.9)
        }
        if isHot {
            return IMColors.income
        }
        return IMColors.textMuted
    }
}

private struct CalendarDayCellButton<Background: ShapeStyle>: View {
    let day: Int
    let date: String
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool
    let backgroundStyle: Background
    let action: () -> Void

    var body: some View {
        let cellShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        Button(action: action) {
            CalendarCellLabel(day: day, amountText: amountText, isSelected: isSelected, isHot: isHot, isToday: isToday)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(cellShape.fill(backgroundStyle))
                .overlay {
                    if isSelected {
                        cellShape
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                            .clipShape(cellShape)
                    } else if isToday {
                        cellShape.stroke(IMColors.calendarToday, lineWidth: 1.5)
                    } else {
                        cellShape.stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                }
                .contentShape(cellShape)
        }
        .buttonStyle(.plain)
    }
}

private struct MonthAggregationCard: View {
    let item: LedgerShell.MonthlyAggregationItem

    private static let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    private var titleColor: Color { item.hasData ? IMColors.textPrimary : IMColors.textPlaceholder }
    private var bgColor: Color { item.hasData ? Color.white : IMColors.statBg }
    private var borderColor: Color { item.hasData ? Color.black.opacity(0.08) : Color.black.opacity(0.04) }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        cardContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(cardShape.fill(bgColor))
            .overlay(cardShape.stroke(borderColor, lineWidth: 1))
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.monthNames[item.month - 1])
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(titleColor)

            if item.hasData {
                expenseRow
                incomeRow
                Text("\(item.recordCount) 笔")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IMColors.textMuted)
            } else {
                Text("暂无")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textPlaceholder)
            }
        }
    }

    private var expenseRow: some View {
        HStack(spacing: 2) {
            Text("支")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IMColors.accent)
            Text(BillLensFormatters.currencyString(item.expenseAmount, currencyCode: item.statsCurrency))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
        }
    }

    private var incomeRow: some View {
        HStack(spacing: 2) {
            Text("收")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IMColors.income)
            Text(BillLensFormatters.currencyString(item.incomeAmount, currencyCode: item.statsCurrency))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct WelcomeBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text("账单助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColors.textSecondary)
                Text("输入一句账单描述，或上传图片、语音记账，我会先生成待确认记录。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                Text("刚刚")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                    .fill(IMColors.botBubble)
            )
            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                        .fill(IMColors.userBubble)
                )
                UserAvatar()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 8) {
                AssistantAvatar()
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                        .fill(IMColors.botBubble)
                )
                Spacer(minLength: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SpeechLiveBubble: View {
    let transcript: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if transcript.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在聆听...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(IMColors.textTertiary)
                    }
                } else {
                    Text(transcript)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("录音中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                    .fill(IMColors.userBubble)
            )
            UserAvatar()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ProgressBubble: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(IMColors.systemMsgBg)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct DraftConversationCard: View {
    let title: String
    let direction: String
    let amount: Double?
    let currency: String?
    let category: String
    let merchant: String
    let transactionAt: String?
    let status: String
    let copy: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 8) {
                Text(copy)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                            .fill(IMColors.botBubble)
                    )

                draftCardContent
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                            .fill(IMColors.botBubble)
                    )
                    .frame(maxWidth: 520, alignment: .leading)

                Text("刚刚")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textTertiary)
            }
            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var draftCardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DirectionBadge(direction: direction)
                    Text(
                        amount.map { BillLensFormatters.currencyString($0, currencyCode: currency) }
                            ?? "¥0.00"
                    )
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                }
                Spacer()
                StatusPill(title: status, warning: status != "已入库")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IMColors.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(category) · \(merchant) · \(BillLensFormatters.displayDateTime(transactionAt))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
            }
        }
    }
}

private struct ComposerPanel: View {
    @Binding var composerText: String
    @Binding var autoConfirm: Bool
    @State private var focusToken = UUID()
    let isRecording: Bool
    let statusText: String
    let onImage: () -> Void
    let onVoice: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1px separator line
            IMColors.divider.frame(height: 1)

            // Toolbar row
            HStack(spacing: 12) {
                ComposerIconButton(systemImage: "photo") { onImage() }
                ComposerIconButton(
                    systemImage: isRecording ? "stop.circle.fill" : "mic.fill",
                    tint: isRecording ? Color.red : IMColors.textSecondary
                ) {
                    onVoice()
                }

                Divider().frame(height: 16).opacity(0.3)

                Toggle("自动保存", isOn: $autoConfirm)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IMColors.textSecondary)

                Spacer()

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Text input area — borderless, transparent
            composerEditor
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                .padding(.horizontal, 12)

            // Bottom bar with send button
            HStack {
                Spacer()
                Text("Enter 发送")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textTertiary)
                Button(action: onSubmit) {
                    Text("发送")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(IMColors.sendButton)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(IMColors.chatBg)
    }

    private var composerEditor: some View {
        ComposerInputField(
            text: $composerText,
            placeholder: "输入账单，如\"打车花了30块\"…",
            focusToken: focusToken,
            onSubmit: onSubmit
        )
        .onAppear {
            focusToken = UUID()
        }
    }
}

private struct ComposerInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: UUID
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = NSColor(IMColors.textPrimary)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerInputField
        var lastFocusToken: UUID?

        init(_ parent: ComposerInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

private struct ComposerIconButton: View {
    let systemImage: String
    var tint: Color = IMColors.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .overlay(Circle().stroke(Color.black.opacity(0.05), lineWidth: 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewSummaryCard: View {
    let direction: String
    let amount: Double?
    let currency: String?
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DirectionBadge(direction: direction)
                Text(
                    amount.map { BillLensFormatters.currencyString($0, currencyCode: currency) }
                        ?? "¥0.00"
                )
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
            }
            Text(meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }
}

private struct EmptyReviewState: View {
    let latestRecord: RecordItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("等待解析结果")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IMColors.textPrimary)
            Text("左侧发送账单内容后，这里会显示可编辑的结构化字段。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
            if let latestRecord {
                Text(
                    "最近入库：\(latestRecord.category) · \(BillLensFormatters.currencyString(latestRecord.amount, currencyCode: latestRecord.currency))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewField<Content: View>: View {
    let title: String
    var minimumHeight: CGFloat = 44
    var alignTop = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColors.textSecondary)
            content
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IMColors.textPrimary)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: alignTop ? .topLeading : .leading)
        }
        .padding(.vertical, 8)
        .frame(
            maxWidth: .infinity, minHeight: minimumHeight,
            alignment: alignTop ? .topLeading : .center
        )
        .overlay(alignment: .bottom) {
            IMColors.divider.frame(height: 1).opacity(0.5)
        }
    }
}

private struct RecordRowView: View {
    let record: RecordItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.merchant ?? record.category)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IMColors.textPrimary)
                Text(
                    "\(record.category) · \(BillLensFormatters.displayDateTime(record.transactionAt))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
            }
            Spacer()
            Text(BillLensFormatters.currencyString(record.amount, currencyCode: record.currency))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(
                    record.direction == "income"
                        ? IMColors.income
                        : IMColors.textPrimary)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColors.dangerSubtle)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(IMColors.dangerBgLight)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LedgerSummaryCard: View {
    enum Accent {
        case expense
        case income
        case neutral
    }

    let title: String
    let value: String
    let accent: Accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueColor: Color {
        switch accent {
        case .expense:
            return IMColors.textPrimary
        case .income:
            return IMColors.income
        case .neutral:
            return IMColors.textPrimary
        }
    }
}

private struct UserAvatar: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            IMColors.sendButton,
                            IMColors.sendButtonDark,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: LayoutMetrics.avatarSize, height: LayoutMetrics.avatarSize)
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct AssistantAvatar: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            IMColors.assistantAvatarTop,
                            IMColors.assistantAvatarBottom,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: LayoutMetrics.avatarSize, height: LayoutMetrics.avatarSize)
            Image(systemName: "cpu")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IMColors.accent)
        }
    }
}

private struct DirectionBadge: View {
    let direction: String

    var body: some View {
        Text(direction == "income" ? "收入" : "支出")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(
                direction == "income"
                    ? IMColors.income
                    : IMColors.accentDark
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        direction == "income"
                            ? IMColors.incomeBgLight
                            : IMColors.accentBgLight)
            )
    }
}

private struct StatusPill: View {
    let title: String
    let warning: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(
                warning
                    ? IMColors.warningText
                    : IMColors.accentDark
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        warning
                            ? IMColors.warningBg
                            : IMColors.accentBgLight)
            )
    }
}

private struct ActionButton: View {
    enum Kind {
        case primary
        case ghost
        case dangerGhost
    }

    let title: String
    let kind: Kind
    var minWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(minWidth: minWidth, minHeight: LayoutMetrics.actionButtonHeight)
                .padding(.horizontal, 14)
                .background(background)
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: kind == .primary ? 0 : 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .ghost:
            return IMColors.textMuted
        case .dangerGhost:
            return IMColors.danger
        }
    }

    private var background: some View {
        Capsule()
            .fill(
                kind == .primary
                    ? IMColors.buttonPrimary
                    : Color.clear
            )
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return .clear
        case .ghost:
            return IMColors.ghostBorder
        case .dangerGhost:
            return IMColors.dangerBorder
        }
    }
}

private struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.sizeThatFits(.unspecified)
                item.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [LayoutSubview] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = currentWidth > 0 ? size.width + spacing : size.width
            if currentWidth + needed > maxWidth && currentWidth > 0 {
                rows.append(Row())
                currentWidth = 0
            }
            rows[rows.count - 1].items.append(subview)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            currentWidth += (currentWidth > 0 ? spacing : 0) + size.width
        }
        return rows
    }
}
