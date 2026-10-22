import SwiftUI

struct EntryShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    @State private var isReviewPresented = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var autoPresentsReview: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        ChatPanel(isImportingImage: $isImportingImage) { index in
            store.selectDraft(at: index)
            isReviewPresented = true
        }
        .inspector(isPresented: $isReviewPresented) {
            ReviewPanel()
                .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isReviewPresented.toggle()
                } label: {
                    Label("草稿", systemImage: "sidebar.trailing")
                }
                .help("显示或隐藏草稿审核")
                .badge(store.drafts.count)
            }
        }
        .onChange(of: store.drafts.count) { oldCount, newCount in
            if newCount == 0 {
                isReviewPresented = false
            } else if newCount > oldCount && autoPresentsReview {
                isReviewPresented = true
            }
        }
    }
}

struct ChatPanel: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    let onReviewDraft: (Int) -> Void

    var body: some View {
        ChatScrollView(onReviewDraft: onReviewDraft)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerPanel(
                    composerText: $store.composerText,
                    isRecording: store.speechService.isRecording,
                    onImage: { isImportingImage = true },
                    onVoice: { store.toggleRecording() },
                    onSubmit: { store.submitText() }
                )
                .frame(maxWidth: 760)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }
            .background(AppColors.contentBackground)
    }
}

struct ChatScrollView: View {
    @EnvironmentObject private var store: BillLensStore
    let onReviewDraft: (Int) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                if isConversationEmpty {
                    ContentUnavailableView {
                        Label("今天花了什么？", systemImage: "text.bubble")
                    } description: {
                        Text("用一句话描述账单，或导入账单截图、使用语音输入。")
                    }
                    .padding(.top, 80)
                } else {
                    conversation
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chatScrollSignature) {
                withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
            }
        }
    }

    private var conversation: some View {
        LazyVStack(spacing: 12) {
            ForEach(store.messages) { message in
                MessageBubble(message: message)
            }

            if store.speechService.isRecording {
                SpeechLiveBubble(transcript: store.speechService.liveTranscript)
            }

            if let progress = store.transientProgressMessage {
                ProgressBubble(message: progress.content)
            }

            let draftCount = store.drafts.count
            ForEach(Array(store.drafts.enumerated()), id: \.element.id) { index, draft in
                DraftConversationCard(
                    draft: draft,
                    title: draftCount > 1
                        ? "\(index + 1)/\(draftCount) · \(draft.merchant ?? draft.note ?? "待确认账单")"
                        : (draft.note ?? draft.merchant ?? "待确认账单"),
                    isActive: draftCount > 1 && index == store.activeDraftIndex,
                    onReview: { onReviewDraft(index) },
                    onConfirm: {
                        store.selectDraft(at: index)
                        store.confirmDraft()
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { store.selectDraft(at: index) }
            }

            Color.clear.frame(height: 1).id("chatBottom")
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var isConversationEmpty: Bool {
        store.messages.isEmpty
            && store.drafts.isEmpty
            && store.transientProgressMessage == nil
            && !store.speechService.isRecording
    }

    private var chatScrollSignature: String {
        "\(store.messages.count)|\(store.drafts.count)|\(store.latestRecord?.id ?? "")|\(store.transientProgressMessage?.id.uuidString ?? "")|\(store.speechService.isRecording)"
    }
}

// MARK: - Draft review

struct ReviewPanel: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        Group {
            if let draft = store.currentDraft {
                Form {
                    Section {
                        summaryHeader(draft)
                    }

                    Section {
                        Text(draft.content.isEmpty ? "无原始输入" : draft.content)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    } header: {
                        Text(draftSourceLabel(draft))
                    }

                    if draft.kind == "asset" {
                        assetSections(draftID: draft.id)
                    } else {
                        recordSections(draft)
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionBar
                }
            } else {
                ContentUnavailableView {
                    Label("没有待确认的草稿", systemImage: "tray")
                } description: {
                    if let latest = store.latestRecord {
                        Text("最近入库：\(latest.category) · \(BillLensFormatters.currencyString(latest.amount, currencyCode: latest.currency))")
                    } else {
                        Text("输入账单内容后，这里会显示可编辑的字段。")
                    }
                }
            }
        }
        .navigationTitle("审核草稿")
    }

    private func summaryHeader(_ draft: RecordDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DirectionTag(direction: store.draftForm.direction)
                if store.drafts.count > 1 {
                    StatusTag(title: "第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔", color: .accentColor)
                }
            }
            AmountText(
                amount: draft.amount,
                currency: draft.currency ?? store.draftForm.currency,
                direction: store.draftForm.direction
            )
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text(summaryMeta(draft))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func summaryMeta(_ draft: RecordDraft) -> String {
        if draft.kind == "asset", let asset = draft.assetInfo {
            return "资产 · \(asset.name) · \(asset.category ?? "未分类")"
        }
        if draft.kind == "subscription" {
            return "订阅 · \(draft.merchant ?? "未填写商户") · \(draft.subscriptionCycle ?? "未设置周期")"
        }
        return "\(draft.category ?? "未分类") · \(draft.merchant ?? "未填写商户") · \(BillLensFormatters.displayDateTime(draft.transactionAt))"
    }

    private func draftSourceLabel(_ draft: RecordDraft) -> String {
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

    @ViewBuilder
    private func recordSections(_ draft: RecordDraft) -> some View {
        Section("金额与分类") {
            Picker(
                "类型",
                selection: Binding(
                    get: { store.draftForm.direction },
                    set: { store.setDraftDirection($0) }
                )
            ) {
                Text("支出").tag("expense")
                Text("收入").tag("income")
            }
            .pickerStyle(.segmented)

            LabeledContent("金额") {
                TextField("金额", text: $store.draftForm.amount, prompt: Text("0.00"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }

            LabeledContent("币种") {
                TextField(
                    "币种",
                    text: Binding(
                        get: { store.draftForm.currency },
                        set: { store.draftForm.currency = $0.uppercased() }
                    ),
                    prompt: Text("CNY")
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            }

            Picker("分类", selection: $store.draftForm.category) {
                ForEach(store.availableCategories, id: \.self) { category in
                    Label(category, systemImage: CategoryStyle.icon(for: category)).tag(category)
                }
            }
        }

        Section("详情") {
            LabeledContent("商户") {
                TextField("商户", text: $store.draftForm.merchant, prompt: Text("可选"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }

            if let transactionAt = store.draftForm.transactionAt {
                DatePicker(
                    "时间",
                    selection: draftDateBinding(
                        draftID: draft.id,
                        visibleValue: transactionAt,
                        fieldName: "transactionAt",
                        currentValue: { store.draftForm.transactionAt },
                        setValue: { store.draftForm.transactionAt = $0 }
                    )
                )
            } else {
                LabeledContent("时间") {
                    Button("设为现在") {
                        store.draftForm.transactionAt = .now
                    }
                }
            }

            TextField("备注", text: $store.draftForm.note, prompt: Text("备注"), axis: .vertical)
                .lineLimit(2...5)
        }

        if draft.kind == "subscription" {
            Section {
                Picker("周期", selection: $store.subscriptionCycle) {
                    Text("每月").tag("monthly")
                    Text("每年").tag("yearly")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("订阅周期")
            } footer: {
                Text("确认后将同时创建订阅和对应账单。")
            }
        }
    }

    @ViewBuilder
    private func assetSections(draftID: String) -> some View {
        Section {
            LabeledContent("名称") {
                TextField("名称", text: $store.assetDraftForm.name, prompt: Text("机构或资产名称"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("金额") {
                TextField("金额", text: $store.assetDraftForm.amount, prompt: Text("0.00"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            LabeledContent("币种") {
                TextField("币种", text: $store.assetDraftForm.currency, prompt: Text("CNY"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            Picker("分类", selection: $store.assetDraftForm.category) {
                ForEach(AssetShell.categories, id: \.self) { category in
                    Label(category, systemImage: CategoryStyle.assetIcon(for: category)).tag(category)
                }
            }
            if let recordedOn = store.assetDraftForm.recordedOn {
                DatePicker(
                    "记录日期",
                    selection: draftDateBinding(
                        draftID: draftID,
                        visibleValue: recordedOn,
                        fieldName: "recordedOn",
                        currentValue: { store.assetDraftForm.recordedOn },
                        setValue: { store.assetDraftForm.recordedOn = $0 }
                    ),
                    displayedComponents: .date
                )
            } else {
                LabeledContent("记录日期") {
                    Button("设为今天") {
                        store.assetDraftForm.recordedOn = .now
                    }
                }
            }
            TextField("备注", text: $store.assetDraftForm.note, prompt: Text("备注"), axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("资产")
        } footer: {
            Text("确认后才会新增或更新资产快照。")
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

    private var actionBar: some View {
        VStack(spacing: 10) {
            if store.drafts.count > 1 {
                HStack {
                    Button {
                        store.selectDraft(at: store.activeDraftIndex - 1)
                    } label: {
                        Label("上一笔", systemImage: "chevron.left")
                    }
                    .disabled(store.activeDraftIndex <= 0)

                    Spacer()
                    Text("第 \(store.activeDraftIndex + 1)/\(store.drafts.count) 笔")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()

                    Button {
                        store.selectDraft(at: store.activeDraftIndex + 1)
                    } label: {
                        Label("下一笔", systemImage: "chevron.right")
                    }
                    .disabled(store.activeDraftIndex >= store.drafts.count - 1)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                Button("删除", role: .destructive) {
                    store.discardDraft()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer(minLength: 0)

                Button("保存") {
                    store.saveDraft()
                }
                .buttonStyle(.bordered)

                if store.drafts.count > 1 {
                    Button("全部确认") {
                        store.confirmAllDrafts()
                    }
                    .buttonStyle(.bordered)
                }

                Button("确认入库") {
                    store.confirmDraft()
                }
                .buttonStyle(.borderedProminent)
            }
            #if os(iOS)
            .controlSize(.large)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
