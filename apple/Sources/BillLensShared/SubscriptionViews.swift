import SwiftUI

// MARK: - Subscription Management Shell

struct SubscriptionShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var subscriptionToDelete: SubscriptionItem?
    @State private var editingSubscription: SubscriptionItem?

    private var usesCompactLayout: Bool {
        sizeClass == .compact
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                subscriptionList
                    .navigationDestination(item: $store.selectedSubscriptionId) { _ in
                        detail
                    }
            } else {
                HStack(spacing: 0) {
                    subscriptionList
                        .frame(width: 340)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            store.loadSubscriptionsReportingErrors()
        }
        .sheet(item: $editingSubscription) { subscription in
            SubscriptionEditSheet(subscription: subscription) { update in
                store.updateSubscription(subscription.id, update: update)
            }
        }
        .alert(
            "删除这个订阅？",
            isPresented: Binding(
                get: { subscriptionToDelete != nil },
                set: { if !$0 { subscriptionToDelete = nil } }
            ),
            presenting: subscriptionToDelete
        ) { subscription in
            Button("删除", role: .destructive) {
                store.deleteSubscription(subscription.id)
                subscriptionToDelete = nil
            }
            Button("取消", role: .cancel) { subscriptionToDelete = nil }
        } message: { _ in
            Text("删除后将停止自动记账，已生成的账单不会受影响。")
        }
    }

    // MARK: List

    private var subscriptionList: some View {
        List(selection: usesCompactLayout ? nil : $store.selectedSubscriptionId) {
            Section {
                LabeledContent("活跃订阅", value: "\(activeSubscriptionCount) 项")
                if let next = nextRenewal {
                    LabeledContent("最近续费") {
                        Text("\(next.merchant ?? next.category) · \(BillLensFormatters.displayDay(next.nextDueAt))")
                            .lineLimit(1)
                    }
                }
                Toggle(isOn: Binding(
                    get: { store.subscriptionRemindersEnabled },
                    set: { store.setSubscriptionRemindersEnabled($0) }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扣款提醒")
                            Text("在扣款日发送本地通知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.badge")
                    }
                }
            }
            .selectionDisabled()

            Section("全部订阅") {
                if store.subscriptions.isEmpty {
                    emptyState
                        .selectionDisabled()
                } else {
                    ForEach(store.subscriptions) { subscription in
                        row(subscription)
                            .tag(subscription.id)
                    }
                }
            }
        }
        .appListStyle()
    }

    @ViewBuilder
    private func row(_ subscription: SubscriptionItem) -> some View {
        let content = SubscriptionRow(subscription: subscription)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    subscriptionToDelete = subscription
                } label: {
                    Label("删除", systemImage: "trash")
                }
                pauseResumeButton(subscription)
            }
            .contextMenu {
                pauseResumeButton(subscription)
                Button(role: .destructive) {
                    subscriptionToDelete = subscription
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        if usesCompactLayout {
            Button {
                store.selectedSubscriptionId = subscription.id
            } label: {
                HStack {
                    content
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func pauseResumeButton(_ subscription: SubscriptionItem) -> some View {
        Group {
            if subscription.isActive {
                Button {
                    store.pauseSubscription(subscription.id)
                } label: {
                    Label("暂停", systemImage: "pause.circle")
                }
                .tint(.orange)
            } else {
                Button {
                    store.resumeSubscription(subscription.id)
                } label: {
                    Label("恢复", systemImage: "play.circle")
                }
                .tint(.green)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无订阅", systemImage: "repeat.circle")
        } description: {
            Text("在「记账」中输入「订阅了 Netflix 每月 15.99 美元」即可自动创建订阅。")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let subscription = store.selectedSubscription {
            SubscriptionDetailView(
                subscription: subscription,
                onEdit: { editingSubscription = subscription },
                onPause: { store.pauseSubscription(subscription.id) },
                onResume: { store.resumeSubscription(subscription.id) },
                onDelete: { subscriptionToDelete = subscription }
            )
        } else {
            ContentUnavailableView("选择一个订阅", systemImage: "repeat", description: Text("在左侧列表中选择订阅查看详情。"))
        }
    }

    private var activeSubscriptionCount: Int {
        store.subscriptions.filter(\.isActive).count
    }

    private var nextRenewal: SubscriptionItem? {
        store.subscriptions
            .filter(\.isActive)
            .min(by: { $0.nextDueAt < $1.nextDueAt })
    }
}

// MARK: - Row

struct SubscriptionRow: View {
    let subscription: SubscriptionItem

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(
                systemImage: "repeat",
                color: subscription.isActive ? CategoryStyle.color(for: "订阅") : .gray
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.merchant ?? subscription.category)
                    .lineLimit(1)
                Text("\(subscription.cycleDisplayText) · 下次 \(BillLensFormatters.displayDay(subscription.nextDueAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(amount: subscription.amount, currency: subscription.currency, direction: subscription.direction)
                    .font(.body.weight(.medium))
                if !subscription.isActive {
                    Text(subscription.statusDisplayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct SubscriptionDetailView: View {
    let subscription: SubscriptionItem
    let onEdit: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                DetailHeader(
                    icon: "repeat",
                    color: subscription.isActive ? CategoryStyle.color(for: "订阅") : .gray,
                    title: subscription.merchant ?? subscription.category,
                    amount: BillLensFormatters.currencyString(subscription.amount, currencyCode: subscription.currency),
                    caption: "下次扣费 \(BillLensFormatters.displayDay(subscription.nextDueAt))"
                ) {
                    StatusTag(title: subscription.cycleDisplayText, color: .accentColor)
                    StatusTag(
                        title: subscription.statusDisplayText,
                        color: subscription.isActive ? AppColors.income : .secondary
                    )
                }
            }

            Section("详情") {
                LabeledContent("类型", value: subscription.direction == "income" ? "收入" : "支出")
                LabeledContent("分类", value: subscription.category)
                LabeledContent("币种", value: subscription.currency)
                if let merchant = subscription.merchant, !merchant.isEmpty {
                    LabeledContent("商户", value: merchant)
                }
                if let note = subscription.note, !note.isEmpty {
                    LabeledContent("备注", value: note)
                }
                LabeledContent("扣费日", value: subscription.cycle == "monthly"
                    ? "每月 \(subscription.anchorDay) 日"
                    : "每年 \(subscription.anchorMonth ?? 1) 月 \(subscription.anchorDay) 日")
                if let last = subscription.lastChargedAt {
                    LabeledContent("上次记账", value: BillLensFormatters.displayDay(last))
                }
            }

            Section {
                Button("编辑订阅", action: onEdit)
                if subscription.isActive {
                    Button("暂停订阅", action: onPause)
                } else {
                    Button("恢复订阅", action: onResume)
                }
                Button("删除订阅", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(subscription.merchant ?? subscription.category)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Edit

struct SubscriptionEditFormState {
    var direction = "expense"
    var amount = ""
    var currency = "CNY"
    var category = "订阅"
    var merchant = ""
    var note = ""
    var cycle = "monthly"
    var anchorDay = "1"
    var anchorMonth = "1"

    init(subscription: SubscriptionItem) {
        direction = subscription.direction
        amount = String(format: "%.2f", subscription.amount)
        currency = subscription.currency
        category = subscription.category
        merchant = subscription.merchant ?? ""
        note = subscription.note ?? ""
        cycle = subscription.cycle
        anchorDay = String(subscription.anchorDay)
        anchorMonth = String(subscription.anchorMonth ?? 1)
    }

    var updateInput: SubscriptionUpdateInput {
        SubscriptionUpdateInput(
            direction: direction,
            amount: Double(amount),
            currency: currency.isEmpty ? nil : currency,
            category: category.isEmpty ? nil : category,
            merchant: merchant.isEmpty ? nil : merchant,
            note: note.isEmpty ? nil : note,
            cycle: cycle,
            anchorDay: Int(anchorDay),
            anchorMonth: cycle == "yearly" ? Int(anchorMonth) : nil
        )
    }
}

struct SubscriptionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form: SubscriptionEditFormState
    let onSave: (SubscriptionUpdateInput) -> Void

    init(subscription: SubscriptionItem, onSave: @escaping (SubscriptionUpdateInput) -> Void) {
        _form = State(initialValue: SubscriptionEditFormState(subscription: subscription))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $form.direction) {
                        Text("支出").tag("expense")
                        Text("收入").tag("income")
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("金额") {
                        TextField("金额", text: $form.amount, prompt: Text("0.00"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    LabeledContent("币种") {
                        TextField("币种", text: $form.currency, prompt: Text("CNY"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("分类", selection: $form.category) {
                        ForEach(BillLensStore.categories(for: form.direction), id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                }

                Section {
                    LabeledContent("商户") {
                        TextField("商户", text: $form.merchant, prompt: Text("可选"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("备注", text: $form.note, prompt: Text("备注"), axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("扣费周期") {
                    Picker("周期", selection: $form.cycle) {
                        Text("每月").tag("monthly")
                        Text("每年").tag("yearly")
                    }
                    .pickerStyle(.segmented)
                    if form.cycle == "yearly" {
                        Picker("扣费月", selection: $form.anchorMonth) {
                            ForEach(1...12, id: \.self) { Text("\($0) 月").tag(String($0)) }
                        }
                    }
                    Picker("扣费日", selection: $form.anchorDay) {
                        ForEach(1...31, id: \.self) { Text("\($0) 日").tag(String($0)) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑订阅")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(form.updateInput)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}
