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
        HStack(spacing: 14) {
            chatSide
            reviewSide
        }
        .frame(width: availableWidth, height: availableHeight, alignment: .topLeading)
    }

    #if os(iOS)
    private var compactLayout: some View {
        ChatPanel(isImportingImage: $isImportingImage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .appRoundedGlass(
                cornerRadius: 34,
                prominence: .prominent,
                tint: IMColors.accentBright.opacity(0.08),
                fallbackFill: IMColors.chatBg.opacity(0.95)
            )
    }

    private var reviewSide: some View {
        ReviewPanel()
            .frame(width: reviewWidth)
            .frame(maxHeight: .infinity)
            .appRoundedGlass(
                cornerRadius: 34,
                prominence: .prominent,
                tint: IMColors.accentBright.opacity(0.05),
                fallbackFill: IMColors.surface.opacity(0.98)
            )
    }
}

struct ChatPanel: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChatScrollView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .clipShape(Rectangle())

            ComposerPanel(
                composerText: $store.composerText,
                isRecording: store.speechService.isRecording,
                onImage: { isImportingImage = true },
                onVoice: { store.toggleRecording() },
                onSubmit: { store.submitText() }
            )
            .padding(.horizontal, 16)
            #if os(macOS)
            .padding(.bottom, 14)
            #endif
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
            }

            ReviewSummaryCard(
                direction: store.draftForm.direction,
                amount: store.currentDraft?.amount,
                currency: store.currentDraft?.currency ?? store.draftForm.currency,
                meta: reviewSummaryMeta
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if store.currentDraft == nil {
                EmptyReviewState(latestRecord: store.latestRecord)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                GeometryReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            draftSourceCard
                            reviewFields
                        }
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

                reviewActions
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                StatusPill(title: store.drafts.isEmpty ? "等待解析" : "待确认 (\(store.drafts.count))", warning: !store.drafts.isEmpty)
                Spacer()
                if store.drafts.count > 1 {
                    Text("多笔")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColors.accentDark)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(IMColors.accentBgLight)
                        )
                }
            }

            Text("草稿编辑")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(IMColors.textPrimary)
            Text("先看识别结果，再改字段；确认后会直接写入账单。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
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
        VStack(spacing: 12) {
            ReviewFieldGroup(
                title: "核心字段",
                subtitle: "把金额、方向、分类先修准。"
            ) {
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
            }

            ReviewFieldGroup(
                title: "补充信息",
                subtitle: "商户、时间和备注决定后续检索体验。"
            ) {
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
                        .frame(minHeight: 44, maxHeight: 60)
                }
            }
        }
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style == .sidebar && store.drafts.count > 1 {
                reviewNavigator
            }

            Text("确认后会写入数据库，并出现在账单一览里。")
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
        .padding(14)
        .appRoundedGlass(
            cornerRadius: 24,
            prominence: .regular,
            tint: IMColors.accentBright.opacity(0.06),
            fallbackFill: IMColors.surface.opacity(0.96)
        )
    }

    private var draftSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AssistantAvatar()

                VStack(alignment: .leading, spacing: 4) {
                    Text("识别草稿")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textSecondary)
                    Text(draftSourceText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                    Text(reviewSummaryMeta)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .appRoundedGlass(
            cornerRadius: 24,
            prominence: .regular,
            tint: IMColors.accentBright.opacity(0.06),
            fallbackFill: IMColors.surface.opacity(0.96)
        )
    }

    private var draftSourceText: String {
        if let content = store.currentDraft?.content, !content.isEmpty {
            return content
        }
        return "等待新的账单输入。"
    }

    private var reviewNavigator: some View {
        HStack(spacing: 8) {
            ReviewPagerButton(systemImage: "chevron.left") {
                store.selectDraft(at: store.activeDraftIndex - 1)
            }
            .disabled(store.activeDraftIndex <= 0)

            Text("第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)

            ReviewPagerButton(systemImage: "chevron.right") {
                store.selectDraft(at: store.activeDraftIndex + 1)
            }
            .disabled(store.activeDraftIndex >= store.drafts.count - 1)

            Spacer()
        }
    }
}

private struct ReviewFieldGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IMColors.textSecondary)
            }

            content
        }
        .padding(14)
        .appRoundedGlass(
            cornerRadius: 24,
            prominence: .regular,
            tint: IMColors.accentBright.opacity(0.05),
            fallbackFill: IMColors.surface.opacity(0.94)
        )
    }
}

private struct ReviewPagerButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColors.accentDark)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.7))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.82), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct EntryOverviewStrip: View {
    @EnvironmentObject private var store: BillLensStore
    let isRecording: Bool
    let onImage: () -> Void
    let onVoice: () -> Void

    var body: some View {
        Group {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 12) {
                compactHeadline
                compactMetrics
                quickActionsRow
            }
            #else
            HStack(spacing: 14) {
                compactHeadline
                Spacer(minLength: 0)
                compactMetrics
                quickActionsRow
                    .frame(width: 208)
            }
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRoundedGlass(
            cornerRadius: 24,
            prominence: .regular,
            tint: IMColors.accentBright.opacity(0.08),
            fallbackFill: IMColors.surfaceStrong.opacity(0.94)
        )
    }

    private var compactHeadline: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(IMColors.accentBgLight)
                    .frame(width: 36, height: 36)
                Image(systemName: isRecording ? "waveform.circle.fill" : "ellipsis.message.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IMColors.accentDark)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Text(headlineSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColors.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var heroTitle: String {
        if isRecording {
            return "正在聆听"
        }
        if !store.drafts.isEmpty {
            return "还有 \(store.drafts.count) 笔待确认"
        }
        return "准备录入新账单"
    }

    private var headlineSubtitle: String {
        if let draft = store.currentDraft {
            return draft.note ?? draft.merchant ?? "已有草稿，继续在对话里补充。"
        }
        return "先说一句，下面的对话区直接接住。"
    }

    private var compactMetrics: some View {
        HStack(spacing: 8) {
            compactMetric(title: "待确认", value: "\(store.drafts.count)")
            compactMetric(title: "对话", value: "\(store.messages.count)")
            compactMetric(title: "最近", value: latestRecordValue)
        }
    }

    private var quickActionsRow: some View {
        HStack(spacing: 10) {
            EntryStripAction(
                title: "票据",
                systemImage: "photo",
                primary: false,
                action: onImage
            )
            EntryStripAction(
                title: isRecording ? "停止" : "语音",
                systemImage: isRecording ? "stop.fill" : "waveform",
                primary: true,
                action: onVoice
            )
        }
    }

    private var latestRecordValue: String {
        if let latest = store.latestRecord {
            return BillLensFormatters.currencyString(latest.amount, currencyCode: latest.currency)
        }
        return "暂无"
    }

    private func compactMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.52))
        )
    }
}

private struct EntryStripAction: View {
    let title: String
    let systemImage: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(primary ? IMColors.accent : Color.white.opacity(0.68))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(primary ? Color.white : IMColors.accentDark)
                    )
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(primary ? Color.white.opacity(0.62) : Color.white.opacity(0.42))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.78), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
