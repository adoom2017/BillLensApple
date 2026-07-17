#if os(macOS)
import AppKit
#endif
import SwiftUI

struct EntryShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    private let reviewTrailingInset: CGFloat = 12

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var reviewWidth: CGFloat {
        let w = availableWidth * 0.38
        return min(max(360, w), 440)
    }

    var body: some View {
        #if os(macOS)
        macLayout
        #else
        if sizeClass == .regular {
            desktopLayout
        } else {
            compactLayout
        }
        #endif
    }

    #if os(macOS)
    private var macLayout: some View {
        HStack(spacing: 0) {
            ChatPanel(isImportingImage: $isImportingImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ReviewPanel()
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .background(IMColors.surfaceStrong)
        }
        .background(IMColors.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: LayoutRadii.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LayoutRadii.card, style: .continuous)
                .strokeBorder(IMColors.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }
    #endif

    private var desktopLayout: some View {
        HStack(spacing: 14) {
            chatSide
            reviewSide
        }
        .padding(.trailing, reviewTrailingInset)
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
        availableWidth - reviewWidth - reviewTrailingInset - 1
    }

    private var chatSide: some View {
        ChatPanel(isImportingImage: $isImportingImage)
            .frame(width: chatWidth)
            .frame(maxHeight: .infinity)
            .appRoundedGlass(
                cornerRadius: LayoutRadii.shell,
                prominence: .prominent,
                tint: IMColors.glassCoolTint,
                fallbackFill: IMColors.chatBg.opacity(0.95)
            )
    }

    private var reviewSide: some View {
        ReviewPanel()
            .frame(width: reviewWidth)
            .frame(maxHeight: .infinity)
            .appRoundedGlass(
                cornerRadius: LayoutRadii.shell,
                prominence: .prominent,
                tint: IMColors.glassWarmTint.opacity(0.78),
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
                .padding(.top, 12)
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
                .onChange(of: chatScrollSignature) {
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

    private var chatScrollSignature: String {
        "\(store.messages.count)|\(store.drafts.count)|\(store.latestRecord?.id ?? "")|\(store.transientProgressMessage?.id.uuidString ?? "")|\(store.speechService.isRecording)"
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
                            : "已为你解析出一张待确认账单。请在草稿编辑区检查并修改字段。",
                        actions: draftActions(for: index, draft: draft)
                    )
                    .opacity(draftCardOpacity(for: index))
                    .onTapGesture { store.selectDraft(at: index) }
                }
            }

            Color.clear.frame(height: 1).id("chatBottom")
        }
        .frame(
            minWidth: width,
            maxWidth: width,
            minHeight: minHeight,
            alignment: usesEmptyConversationLayout ? .center : .bottomLeading
        )
    }

    private var usesEmptyConversationLayout: Bool {
        store.messages.isEmpty
            && store.drafts.isEmpty
            && store.transientProgressMessage == nil
            && !store.speechService.isRecording
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
                        .foregroundStyle(IMColors.textBody)
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
                .foregroundStyle(IMColors.textTitle)
            Text("先检查识别结果，再修改字段；确认前不会写入业务数据。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textBody)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var reviewSummaryMeta: String {
        if let draft = store.currentDraft {
            let indexLabel = store.drafts.count > 1 ? "第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔 · " : ""
            if draft.kind == "asset", let asset = draft.assetInfo {
                return "\(indexLabel)资产 · \(asset.name) · \(asset.category ?? "未分类")"
            }
            if draft.kind == "subscription" {
                return "\(indexLabel)订阅 · \(draft.merchant ?? "未填写商户") · \(draft.subscriptionCycle ?? "未设置周期")"
            }
            return
                "\(indexLabel)\(draft.category ?? "未分类") · \(draft.merchant ?? "未填写商户") · \(BillLensFormatters.displayDateTime(draft.transactionAt))"
        }
        return "等待新的账单解析结果"
    }

    @ViewBuilder private var reviewFields: some View {
        if store.currentDraft?.kind == "asset" {
            assetReviewFields
        } else {
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
                    if let draftID = store.currentDraft?.id,
                       let transactionAt = store.draftForm.transactionAt {
                        DatePicker(
                            "",
                            selection: draftDateBinding(
                                draftID: draftID,
                                visibleValue: transactionAt,
                                fieldName: "transactionAt",
                                currentValue: { store.draftForm.transactionAt },
                                setValue: { store.draftForm.transactionAt = $0 }
                            )
                        )
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button("设置当前时间") {
                            store.draftForm.transactionAt = .now
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IMColors.accent)
                    }
                }

                ReviewField(title: "备注", minimumHeight: LayoutMetrics.noteHeight, alignTop: true) {
                    TextEditor(text: $store.draftForm.note)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textBody)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 60)
                }
            }

            if store.currentDraft?.kind == "subscription" {
                ReviewFieldGroup(
                    title: "订阅周期",
                    subtitle: "确认后将同时创建订阅和对应账单。"
                ) {
                    ReviewField(title: "周期") {
                        Picker("", selection: $store.subscriptionCycle) {
                            Text("每月").tag("monthly")
                            Text("每年").tag("yearly")
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            }
        }
    }

    private func draftDateBinding(
        draftID: String,
        visibleValue: Date,
        fieldName: String,
        currentValue: @escaping () -> Date?,
        setValue: @escaping (Date) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                // SwiftUI can read a disappearing DatePicker after confirmation advances
                // or removes its draft. The binding remains valid for that old view only.
                guard store.currentDraft?.id == draftID else { return visibleValue }
                guard let value = currentValue() else {
                    preconditionFailure("\(fieldName) became nil for the active draft")
                }
                return value
            },
            set: { value in
                guard store.currentDraft?.id == draftID else { return }
                guard currentValue() != nil else {
                    preconditionFailure("\(fieldName) became nil for the active draft")
                }
                setValue(value)
            }
        )
    }

    private var assetReviewFields: some View {
        VStack(spacing: 12) {
            ReviewFieldGroup(
                title: "资产字段",
                subtitle: "确认后才会新增或更新资产快照。"
            ) {
                ReviewField(title: "名称") {
                    TextField("机构或资产名称", text: $store.assetDraftForm.name)
                        .textFieldStyle(.plain)
                }
                ReviewField(title: "金额") {
                    TextField("0.00", text: $store.assetDraftForm.amount)
                        .textFieldStyle(.plain)
                }
                ReviewField(title: "币种") {
                    TextField("CNY", text: $store.assetDraftForm.currency)
                        .textFieldStyle(.plain)
                }
                ReviewField(title: "分类") {
                    Picker("", selection: $store.assetDraftForm.category) {
                        ForEach(["存款", "现金", "股票", "基金", "加密货币", "房产", "其他"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ReviewField(title: "记录日期") {
                    if let draftID = store.currentDraft?.id,
                       let recordedOn = store.assetDraftForm.recordedOn {
                        DatePicker(
                            "",
                            selection: draftDateBinding(
                                draftID: draftID,
                                visibleValue: recordedOn,
                                fieldName: "recordedOn",
                                currentValue: { store.assetDraftForm.recordedOn },
                                setValue: { store.assetDraftForm.recordedOn = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    } else {
                        Button("设置今天") {
                            store.assetDraftForm.recordedOn = .now
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IMColors.accent)
                    }
                }
                ReviewField(title: "备注", minimumHeight: LayoutMetrics.noteHeight, alignTop: true) {
                    TextEditor(text: $store.assetDraftForm.note)
                        .font(.system(size: 14, weight: .medium))
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

            Text("确认动作由 Rust 单事务写入；失败时草稿和业务数据保持原状。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textBody)
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
        .appFlatCardSurface(
            cornerRadius: LayoutRadii.section,
            fill: IMColors.surface
        )
    }

    private var draftSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AssistantAvatar()

                VStack(alignment: .leading, spacing: 4) {
                    Text(draftSourceLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textLabel)
                    Text(draftSourceText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textBody)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                    Text(reviewSummaryMeta)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.textMeta)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .appFlatCardSurface(
            cornerRadius: LayoutRadii.section,
            fill: IMColors.surface
        )
    }

    private var draftSourceText: String {
        if let content = store.currentDraft?.content, !content.isEmpty {
            return content
        }
        return "等待新的账单输入。"
    }

    private var draftSourceLabel: String {
        guard let draft = store.currentDraft else { return "识别草稿" }
        let type = switch draft.kind {
        case "asset": "资产"
        case "subscription": "订阅"
        default: "账单"
        }
        let source = switch draft.parserSource {
        case "local": "本地模型"
        case "cloud_after_local_failure": "本地失败后云端"
        default: "云端模型"
        }
        return "\(type)草稿 · \(source)"
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
                    .foregroundStyle(IMColors.textTitle)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IMColors.textBody)
            }

            content
        }
        .padding(14)
        .appFlatCardSurface(
            cornerRadius: LayoutRadii.section,
            fill: IMColors.surface
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
                .foregroundStyle(IMColors.textBody)
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
