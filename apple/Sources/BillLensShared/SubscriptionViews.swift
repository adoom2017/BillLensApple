import SwiftUI

// MARK: - Subscription Management Shell

struct SubscriptionShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var subscriptionToDelete: SubscriptionItem? = nil
    @State private var isEditing = false
    @State private var editForm = SubscriptionEditFormState()
    @State private var isDetailPresented = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactBody
            } else {
                splitBody
            }
        }
        .onAppear {
            Task { try? await store.loadSubscriptions() }
        }
        .alert("确认删除", isPresented: .init(
            get: { subscriptionToDelete != nil },
            set: { if !$0 { subscriptionToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { subscriptionToDelete = nil }
            Button("删除", role: .destructive) {
                if let sub = subscriptionToDelete {
                    store.deleteSubscription(sub.id)
                    subscriptionToDelete = nil
                    isDetailPresented = false
                }
            }
        } message: {
            Text("删除后将停止自动记账，已生成的账单不会受影响。")
        }
        .onChange(of: store.selectedSubscriptionId) {
            isEditing = false
        }
    }

    // MARK: Compact (iPhone): full-width list + sheet detail

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("订阅列表")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Spacer()
                Text("\(store.subscriptions.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(IMColors.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().opacity(0.3)

            if store.subscriptions.isEmpty {
                subscriptionEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.subscriptions) { sub in
                            SubscriptionCard(
                                subscription: sub,
                                isSelected: store.selectedSubscriptionId == sub.id,
                                onSelect: {
                                    store.selectedSubscriptionId = sub.id
                                    isDetailPresented = true
                                },
                                onPause: { store.pauseSubscription(sub.id) },
                                onResume: { store.resumeSubscription(sub.id) },
                                onDelete: { subscriptionToDelete = sub }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IMColors.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(IMColors.divider, lineWidth: 1)
        )
        .sheet(isPresented: $isDetailPresented, onDismiss: { store.selectedSubscriptionId = nil }) {
            compactDetailSheet
        }
    }

    @ViewBuilder
    private var compactDetailSheet: some View {
        if let sub = store.selectedSubscription {
            if isEditing {
                SubscriptionEditPanel(
                    subscription: sub,
                    form: $editForm,
                    onSave: {
                        let update = SubscriptionUpdateInput(
                            direction: editForm.direction,
                            amount: Double(editForm.amount),
                            currency: editForm.currency.isEmpty ? nil : editForm.currency,
                            category: editForm.category.isEmpty ? nil : editForm.category,
                            merchant: editForm.merchant.isEmpty ? nil : editForm.merchant,
                            note: editForm.note.isEmpty ? nil : editForm.note,
                            cycle: editForm.cycle,
                            anchorDay: Int(editForm.anchorDay),
                            anchorMonth: editForm.cycle == "yearly" ? Int(editForm.anchorMonth) : nil
                        )
                        store.updateSubscription(sub.id, update: update)
                        isEditing = false
                    },
                    onCancel: { isEditing = false }
                )
                .environmentObject(store)
            } else {
                SubscriptionDetailPanel(
                    subscription: sub,
                    onEdit: {
                        hydrateEditForm(from: sub)
                        isEditing = true
                    },
                    onPause: { store.pauseSubscription(sub.id) },
                    onResume: { store.resumeSubscription(sub.id) },
                    onDelete: { subscriptionToDelete = sub }
                )
                .environmentObject(store)
            }
        }
    }

    // MARK: Regular (iPad/macOS): side-by-side split

    private var splitBody: some View {
        HStack(spacing: 0) {
            // Left: Subscription list
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("订阅列表")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                    Text("\(store.subscriptions.count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(IMColors.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().opacity(0.3)

                if store.subscriptions.isEmpty {
                    subscriptionEmptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.subscriptions) { sub in
                                SubscriptionCard(
                                    subscription: sub,
                                    isSelected: store.selectedSubscriptionId == sub.id,
                                    onSelect: { store.selectedSubscriptionId = sub.id },
                                    onPause: { store.pauseSubscription(sub.id) },
                                    onResume: { store.resumeSubscription(sub.id) },
                                    onDelete: { subscriptionToDelete = sub }
                                )
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(IMColors.panelBg)

            // Divider
            ZStack {
                IMColors.dividerLegacy.frame(width: 1)
                IMColors.surface.opacity(0.72).frame(width: 1).offset(x: 1)
            }
            .frame(width: 2)

            // Right: Detail / Edit panel
            VStack {
                if let sub = store.selectedSubscription {
                    if isEditing {
                        SubscriptionEditPanel(
                            subscription: sub,
                            form: $editForm,
                            onSave: {
                                let update = SubscriptionUpdateInput(
                                    direction: editForm.direction,
                                    amount: Double(editForm.amount),
                                    currency: editForm.currency.isEmpty ? nil : editForm.currency,
                                    category: editForm.category.isEmpty ? nil : editForm.category,
                                    merchant: editForm.merchant.isEmpty ? nil : editForm.merchant,
                                    note: editForm.note.isEmpty ? nil : editForm.note,
                                    cycle: editForm.cycle,
                                    anchorDay: Int(editForm.anchorDay),
                                    anchorMonth: editForm.cycle == "yearly" ? Int(editForm.anchorMonth) : nil
                                )
                                store.updateSubscription(sub.id, update: update)
                                isEditing = false
                            },
                            onCancel: { isEditing = false }
                        )
                    } else {
                        SubscriptionDetailPanel(
                            subscription: sub,
                            onEdit: {
                                hydrateEditForm(from: sub)
                                isEditing = true
                            },
                            onPause: { store.pauseSubscription(sub.id) },
                            onResume: { store.resumeSubscription(sub.id) },
                            onDelete: { subscriptionToDelete = sub }
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 28))
                            .foregroundStyle(IMColors.textPlaceholder)
                        Text("从左侧选择一个订阅查看详情")
                            .font(.system(size: 14))
                            .foregroundStyle(IMColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IMColors.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(IMColors.divider, lineWidth: 1)
        )
    }

    private var subscriptionEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "repeat.circle")
                .font(.system(size: 44))
                .foregroundStyle(IMColors.textPlaceholder)
            Text("暂无订阅")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IMColors.textSecondary)
            Text("在「账单录入」中输入类似\n「订阅了 Netflix 每月 15.99 美元」\n即可自动创建订阅任务")
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hydrateEditForm(from sub: SubscriptionItem) {
        editForm = SubscriptionEditFormState(
            direction: sub.direction,
            amount: String(format: "%.2f", sub.amount),
            currency: sub.currency,
            category: sub.category,
            merchant: sub.merchant ?? "",
            note: sub.note ?? "",
            cycle: sub.cycle,
            anchorDay: String(sub.anchorDay),
            anchorMonth: String(sub.anchorMonth ?? 1)
        )
    }
}

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
}

// MARK: - Subscription Card

struct SubscriptionCard: View {
    let subscription: SubscriptionItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(subscription.isActive ? IMColors.accentBgLight : IMColors.controlBg)
                            .frame(width: 36, height: 36)
                        Image(systemName: "repeat.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(subscription.isActive ? IMColors.accent : IMColors.textMuted)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.merchant ?? subscription.category)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(IMColors.textPrimary)
                            .lineLimit(1)
                        Text("\(subscription.cycleDisplayText) · \(subscription.category)")
                            .font(.system(size: 11))
                            .foregroundStyle(IMColors.textMuted)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(BillLensFormatters.currencyString(subscription.amount, currencyCode: subscription.currency))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(IMColors.textPrimary)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(subscription.isActive ? IMColors.textPrimary : IMColors.textPlaceholder)
                                .frame(width: 6, height: 6)
                            Text(subscription.statusDisplayText)
                                .font(.system(size: 10))
                                .foregroundStyle(IMColors.textMuted)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Label("下次: \(subscription.nextDueAt)", systemImage: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(IMColors.textTertiary)

                    Spacer()

                    // Quick action buttons
                    if subscription.isActive {
                        smallActionButton("暂停", icon: "pause.circle", action: onPause)
                    } else {
                        smallActionButton("恢复", icon: "play.circle", action: onResume)
                    }
                    smallActionButton("删除", icon: "trash", color: IMColors.dangerSubtle, action: onDelete)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? IMColors.accentBgActive : IMColors.surfaceStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? IMColors.accent.opacity(0.4) : IMColors.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func smallActionButton(_ title: String, icon: String, color: Color = IMColors.textMuted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Subscription Detail Panel

struct SubscriptionDetailPanel: View {
    let subscription: SubscriptionItem
    let onEdit: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(subscription.isActive ? IMColors.accentBgLight : IMColors.controlBg)
                                .frame(width: 48, height: 48)
                            Image(systemName: "repeat.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(subscription.isActive ? IMColors.accent : IMColors.textMuted)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscription.merchant ?? subscription.category)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(IMColors.textPrimary)
                            HStack(spacing: 6) {
                                Text(subscription.cycleDisplayText)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IMColors.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(IMColors.accentBgLight)
                                    .clipShape(Capsule())
                                Text(subscription.isActive ? "活跃" : "已暂停")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(subscription.isActive ? IMColors.textPrimary : IMColors.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(IMColors.controlBg)
                                    .clipShape(Capsule())
                            }
                        }
                        Spacer()
                    }

                    // Amount display
                    Text(BillLensFormatters.currencyString(subscription.amount, currencyCode: subscription.currency))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(IMColors.textPrimary)
                        .padding(.top, 4)
                }
                .padding(20)

                Divider().opacity(0.2).padding(.horizontal, 16)

                // Detail fields
                VStack(spacing: 0) {
                    detailRow("类型", value: subscription.direction == "income" ? "收入" : "支出")
                    detailRow("分类", value: subscription.category)
                    detailRow("币种", value: subscription.currency)
                    if let merchant = subscription.merchant, !merchant.isEmpty {
                        detailRow("商户", value: merchant)
                    }
                    if let note = subscription.note, !note.isEmpty {
                        detailRow("备注", value: note)
                    }
                    detailRow("周期", value: subscription.cycleDisplayText)
                    detailRow("扣费日", value: subscription.cycle == "monthly"
                        ? "每月 \(subscription.anchorDay) 日"
                        : "\(subscription.anchorMonth ?? 1) 月 \(subscription.anchorDay) 日")
                    detailRow("下次扣费", value: subscription.nextDueAt)
                    if let last = subscription.lastChargedAt {
                        detailRow("上次记账", value: last)
                    }
                }
                .padding(.vertical, 8)

                Divider().opacity(0.2).padding(.horizontal, 16)

                // Action buttons
                HStack(spacing: 10) {
                    ActionButton(title: "编辑", kind: .ghost, action: onEdit)
                    if subscription.isActive {
                        ActionButton(title: "暂停", kind: .ghost, action: onPause)
                    } else {
                        ActionButton(title: "恢复", kind: .primary, action: onResume)
                    }
                    ActionButton(title: "删除", kind: .dangerGhost, action: onDelete)
                }
                .padding(20)
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textMuted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}

// MARK: - Subscription Edit Panel

struct SubscriptionEditPanel: View {
    let subscription: SubscriptionItem
    @Binding var form: SubscriptionEditFormState
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("编辑订阅")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                }
                .padding(20)

                Divider().opacity(0.2).padding(.horizontal, 16)

                VStack(spacing: 14) {
                    // Direction picker
                    editFieldRow("类型") {
                        Picker("", selection: $form.direction) {
                            Text("支出").tag("expense")
                            Text("收入").tag("income")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }

                    // Amount
                    editFieldRow("金额") {
                        TextField("0.00", text: $form.amount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }

                    // Currency
                    editFieldRow("币种") {
                        TextField("CNY", text: $form.currency)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }

                    // Category
                    editFieldRow("分类") {
                        let categories = form.direction == "income"
                            ? BillLensStore.incomeCategories
                            : BillLensStore.expenseCategories
                        Picker("", selection: $form.category) {
                            ForEach(categories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                        .frame(width: 140)
                    }

                    // Merchant
                    editFieldRow("商户") {
                        TextField("可选", text: $form.merchant)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    // Note
                    editFieldRow("备注") {
                        TextField("可选", text: $form.note)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    // Cycle
                    editFieldRow("周期") {
                        Picker("", selection: $form.cycle) {
                            Text("每月").tag("monthly")
                            Text("每年").tag("yearly")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }

                    // Anchor day
                    editFieldRow("扣费日") {
                        TextField("1", text: $form.anchorDay)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("日")
                            .font(.system(size: 13))
                            .foregroundStyle(IMColors.textMuted)
                    }

                    if form.cycle == "yearly" {
                        editFieldRow("扣费月") {
                            TextField("1", text: $form.anchorMonth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("月")
                                .font(.system(size: 13))
                                .foregroundStyle(IMColors.textMuted)
                        }
                    }
                }
                .padding(20)

                Divider().opacity(0.2).padding(.horizontal, 16)

                HStack(spacing: 10) {
                    ActionButton(title: "取消", kind: .ghost, action: onCancel)
                    ActionButton(title: "保存", kind: .primary, action: onSave)
                }
                .padding(20)
            }
        }
    }

    private func editFieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textMuted)
                .frame(width: 60, alignment: .leading)
            content()
            Spacer()
        }
    }
}
