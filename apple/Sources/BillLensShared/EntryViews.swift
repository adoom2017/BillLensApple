#if os(macOS)
import AppKit
#endif
import SwiftUI

struct EntryShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var reviewWidth: CGFloat {
        let w = availableWidth * 0.38
        return min(max(360, w), 440)
    }

    var body: some View {
        #if os(macOS)
        desktopLayout
        #else
        if sizeClass == .regular {
            desktopLayout
        } else {
            compactLayout
        }
        #endif
    }

    private var desktopLayout: some View {
        HStack(spacing: 0) {
            chatSide
            groovedDivider
            reviewSide
        }
        .frame(width: availableWidth, height: availableHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    #if os(iOS)
    private var compactLayout: some View {
        ChatPanel(isImportingImage: $isImportingImage)
            .background(IMColors.chatBg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    #endif

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

struct ChatPanel: View {
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

struct ChatScrollView: View {
    @EnvironmentObject private var store: BillLensStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var reviewDraftId: String?
    #endif

    var body: some View {
        GeometryReader { scrollProxy in
            ScrollViewReader { reader in
                ScrollView {
                    chatContent(
                        width: max(scrollProxy.size.width - 10, 0),
                        minHeight: scrollProxy.size.height
                    )
                    .padding(.trailing, 10)
                }
                .scrollIndicators(.hidden)
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
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
                #if os(iOS)
                .onChange(of: draftIdSignature) {
                    closeReviewIfDraftIsGone()
                }
                .sheet(
                    isPresented: Binding(
                        get: { reviewDraftId != nil },
                        set: { if !$0 { reviewDraftId = nil } }
                    )
                ) {
                    ReviewPanel(style: .compactSheet)
                        .environmentObject(store)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                #endif
            }
        }
    }

    #if os(iOS)
    private var draftIdSignature: String {
        store.drafts.map(\.id).joined(separator: "|")
    }

    private func openReview(for index: Int, draftId: String) {
        store.selectDraft(at: index)
        reviewDraftId = draftId
    }

    private func confirmDraft(at index: Int) {
        store.selectDraft(at: index)
        store.confirmDraft()
    }

    private func closeReviewIfDraftIsGone() {
        guard let reviewDraftId else { return }
        if !store.drafts.contains(where: { $0.id == reviewDraftId }) {
            self.reviewDraftId = nil
        }
    }
    #endif

    private func chatContent(width: CGFloat, minHeight: CGFloat = 0) -> some View {
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
                            ? "共 \(draftCount) 笔待确认账单，每张卡片可单独审核或确认。"
                            : "已为你解析出一张待确认账单。若要修改，可以继续说\"改成300元\"，也可以点审核手动编辑。",
                        actions: draftActions(for: index, draft: draft)
                    )
                    .opacity(draftCardOpacity(for: index))
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
                    copy: "最近确认入库的一笔账单如下。",
                    actions: nil
                )
            }

            Color.clear.frame(height: 1).id("chatBottom")
        }
        // minHeight pins messages to the bottom when content is shorter than the chat area,
        // matching standard chat-app behaviour (WhatsApp/iMessage style).
        .frame(minWidth: width, maxWidth: width, minHeight: minHeight, alignment: .bottomLeading)
    }

    private func draftActions(for index: Int, draft: RecordDraft) -> DraftConversationCard.Actions? {
        #if os(iOS)
        guard usesCompactDraftReview else { return nil }
        return .init(
            review: { openReview(for: index, draftId: draft.id) },
            confirm: { confirmDraft(at: index) }
        )
        #else
        return nil
        #endif
    }

    private func draftCardOpacity(for index: Int) -> Double {
        #if os(iOS)
        if usesCompactDraftReview {
            return 1.0
        }
        #endif
        return index == store.activeDraftIndex ? 1.0 : 0.7
    }

    private var usesCompactDraftReview: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }
}

struct ReviewPanel: View {
    enum Style: Equatable {
        case sidebar
        case compactSheet
    }

    @EnvironmentObject private var store: BillLensStore
    let style: Style

    init(style: Style = .sidebar) {
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if style == .sidebar {
                header
                IMColors.divider.frame(height: 1)
            }

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
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("核对确认")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Spacer()
                StatusPill(title: store.drafts.isEmpty ? "等待解析" : "待确认 (\(store.drafts.count))", warning: !store.drafts.isEmpty)
            }
            Text("左侧输入后按 Enter 自动更新，也可直接手动修改。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
            if style == .sidebar && store.drafts.count > 1 {
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
                if style == .sidebar && store.drafts.count > 1 {
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
