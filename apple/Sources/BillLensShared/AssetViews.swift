import Charts
import SwiftUI

private let assetCategories = ["存款", "现金", "股票", "基金", "加密货币", "房产", "其他"]

// MARK: - Asset Management Shell

struct AssetShell: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var assetToDelete: AssetItem? = nil
    @State private var isEditing = false
    @State private var editForm = AssetEditFormState()

    var body: some View {
        HStack(spacing: 0) {
            // Left: Asset list
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("资产列表")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                    Text("\(store.assets.count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(IMColors.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().opacity(0.3)

                if store.assets.isEmpty {
                    assetEmptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.assets) { asset in
                                AssetCard(
                                    asset: asset,
                                    isSelected: store.selectedAssetId == asset.id,
                                    onSelect: { store.selectedAssetId = asset.id },
                                    onDelete: { assetToDelete = asset }
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
                Color.white.opacity(0.5).frame(width: 1).offset(x: 1)
            }
            .frame(width: 2)

            // Right: Detail / Edit panel
            VStack {
                if let asset = store.selectedAsset {
                    if isEditing {
                        AssetEditPanel(
                            asset: asset,
                            form: $editForm,
                            onSave: {
                                let update = AssetUpdateInput(
                                    name: editForm.name.isEmpty ? nil : editForm.name,
                                    category: editForm.category,
                                    currency: editForm.currency.isEmpty ? nil : editForm.currency,
                                    note: editForm.note.isEmpty ? nil : editForm.note
                                )
                                store.updateAsset(asset.id, update: update)
                                isEditing = false
                            },
                            onCancel: { isEditing = false }
                        )
                    } else {
                        AssetDetailPanel(
                            asset: asset,
                            onEdit: {
                                editForm = AssetEditFormState(
                                    name: asset.name,
                                    category: asset.category,
                                    currency: asset.currency,
                                    note: asset.note ?? ""
                                )
                                isEditing = true
                            },
                            onDelete: { assetToDelete = asset },
                            onDeleteSnapshot: { store.deleteAssetSnapshot($0) }
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 28))
                            .foregroundStyle(IMColors.textPlaceholder)
                        Text("从左侧选择一个资产查看详情")
                            .font(.system(size: 14))
                            .foregroundStyle(IMColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(IMColors.divider, lineWidth: 1)
        )
        .onAppear {
            Task { try? await store.loadAssets() }
        }
        .alert("确认删除资产", isPresented: .init(
            get: { assetToDelete != nil },
            set: { if !$0 { assetToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { assetToDelete = nil }
            Button("删除", role: .destructive) {
                if let asset = assetToDelete {
                    store.deleteAsset(asset.id)
                    assetToDelete = nil
                }
            }
        } message: {
            Text("删除资产将同时移除所有历史余额快照，操作不可撤销。")
        }
        .onChange(of: store.selectedAssetId) {
            isEditing = false
        }
    }

    private var assetEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44))
                .foregroundStyle(IMColors.textPlaceholder)
            Text("暂无资产记录")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IMColors.textSecondary)
            Text("在「账单录入」中输入类似\n「招商银行存款还有 54000 元」\n即可自动创建资产项")
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AssetEditFormState {
    var name = ""
    var category = "存款"
    var currency = "CNY"
    var note = ""
}

// MARK: - Asset Card

struct AssetCard: View {
    let asset: AssetItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(IMColors.accentBgLight)
                            .frame(width: 36, height: 36)
                        Image(systemName: assetIcon(for: asset.category))
                            .font(.system(size: 17))
                            .foregroundStyle(IMColors.accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(IMColors.textPrimary)
                            .lineLimit(1)
                        Text("\(asset.category) · \(asset.snapshots.count) 条记录")
                            .font(.system(size: 11))
                            .foregroundStyle(IMColors.textMuted)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if let amount = asset.latestAmount {
                            Text(BillLensFormatters.currencyString(amount, currencyCode: asset.currency))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(IMColors.textPrimary)
                        } else {
                            Text("—")
                                .font(.system(size: 14))
                                .foregroundStyle(IMColors.textMuted)
                        }
                        if let day = asset.latestRecordedOn {
                            Text(BillLensFormatters.displayDay(day))
                                .font(.system(size: 10))
                                .foregroundStyle(IMColors.textTertiary)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Label(asset.currency, systemImage: "banknote")
                        .font(.system(size: 11))
                        .foregroundStyle(IMColors.textTertiary)
                    Spacer()
                    smallDeleteButton(action: onDelete)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? IMColors.accentBgActive : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? IMColors.accent.opacity(0.4) : IMColors.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func smallDeleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                Text("删除")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(IMColors.dangerSubtle)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(IMColors.dangerSubtle.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

private func assetIcon(for category: String) -> String {
    switch category {
    case "存款": return "building.columns.fill"
    case "现金": return "banknote.fill"
    case "股票": return "chart.bar.fill"
    case "基金": return "chart.pie.fill"
    case "加密货币": return "bitcoinsign.circle.fill"
    case "房产": return "house.fill"
    default: return "creditcard.fill"
    }
}

// MARK: - Asset Detail Panel

struct AssetDetailPanel: View {
    let asset: AssetItem
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDeleteSnapshot: (String) -> Void
    @State private var snapshotToDelete: AssetSnapshotItem? = nil

    private var sortedSnapshots: [AssetSnapshotItem] {
        asset.snapshots.sorted { $0.recordedOn < $1.recordedOn }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(IMColors.accentBgLight)
                                .frame(width: 48, height: 48)
                            Image(systemName: assetIcon(for: asset.category))
                                .font(.system(size: 24))
                                .foregroundStyle(IMColors.accent)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(IMColors.textPrimary)
                            HStack(spacing: 6) {
                                categoryPill(asset.category)
                                categoryPill(asset.currency)
                            }
                        }
                        Spacer()
                    }

                    if let amount = asset.latestAmount {
                        Text(BillLensFormatters.currencyString(amount, currencyCode: asset.currency))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(IMColors.textPrimary)
                            .padding(.top, 4)
                        if let day = asset.latestRecordedOn {
                            Text("截至 \(BillLensFormatters.displayDay(day))")
                                .font(.system(size: 12))
                                .foregroundStyle(IMColors.textMuted)
                        }
                    }
                }
                .padding(20)

                Divider().opacity(0.2).padding(.horizontal, 16)

                // Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("余额趋势")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColors.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    if sortedSnapshots.isEmpty {
                        Text("暂无快照数据")
                            .font(.system(size: 13))
                            .foregroundStyle(IMColors.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if sortedSnapshots.count == 1 {
                        let snap = sortedSnapshots[0]
                        VStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(IMColors.accent)
                            Text(BillLensFormatters.currencyString(snap.amount, currencyCode: asset.currency))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(IMColors.textPrimary)
                            Text(BillLensFormatters.displayDay(snap.recordedOn))
                                .font(.system(size: 11))
                                .foregroundStyle(IMColors.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        Chart(sortedSnapshots) { snap in
                            AreaMark(
                                x: .value("日期", snap.recordedOn),
                                y: .value("金额", snap.amount)
                            )
                            .foregroundStyle(IMColors.accent.opacity(0.12))
                            .interpolationMethod(.monotone)

                            LineMark(
                                x: .value("日期", snap.recordedOn),
                                y: .value("金额", snap.amount)
                            )
                            .foregroundStyle(IMColors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)

                            PointMark(
                                x: .value("日期", snap.recordedOn),
                                y: .value("金额", snap.amount)
                            )
                            .foregroundStyle(IMColors.accent)
                            .symbolSize(36)
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic) { _ in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                    .foregroundStyle(IMColors.divider)
                                AxisTick(length: 0)
                                AxisValueLabel()
                                    .font(.system(size: 10))
                                    .foregroundStyle(IMColors.textMuted)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: .automatic) { _ in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                    .foregroundStyle(IMColors.divider)
                                AxisTick(length: 0)
                                AxisValueLabel()
                                    .font(.system(size: 10))
                                    .foregroundStyle(IMColors.textMuted)
                            }
                        }
                        .frame(height: 180)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                }

                Divider().opacity(0.2).padding(.horizontal, 16)

                // Snapshot list
                VStack(alignment: .leading, spacing: 0) {
                    Text("历史记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColors.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    ForEach(sortedSnapshots.reversed()) { snap in
                        snapshotRow(snap)
                        if snap.id != sortedSnapshots.reversed().last?.id {
                            Divider().opacity(0.15).padding(.horizontal, 20)
                        }
                    }
                }

                Divider().opacity(0.2).padding(.horizontal, 16).padding(.top, 8)

                // Action buttons
                HStack(spacing: 10) {
                    ActionButton(title: "编辑", kind: .ghost, action: onEdit)
                    ActionButton(title: "删除资产", kind: .dangerGhost, action: onDelete)
                }
                .padding(20)
            }
        }
        .alert("删除快照", isPresented: .init(
            get: { snapshotToDelete != nil },
            set: { if !$0 { snapshotToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { snapshotToDelete = nil }
            Button("删除", role: .destructive) {
                if let snap = snapshotToDelete {
                    onDeleteSnapshot(snap.id)
                    snapshotToDelete = nil
                }
            }
        } message: {
            Text("删除后该日期的余额记录将消失，折线图将相应更新。")
        }
    }

    private func snapshotRow(_ snap: AssetSnapshotItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(BillLensFormatters.displayDay(snap.recordedOn))
                    .font(.system(size: 13))
                    .foregroundStyle(IMColors.textPrimary)
                if let note = snap.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(IMColors.textMuted)
                }
            }
            Spacer()
            Text(BillLensFormatters.currencyString(snap.amount, currencyCode: asset.currency))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(IMColors.textPrimary)
            Button {
                snapshotToDelete = snap
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(IMColors.dangerSubtle)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    private func categoryPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(IMColors.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(IMColors.accentBgLight)
            .clipShape(Capsule())
    }
}

// MARK: - Asset Edit Panel

struct AssetEditPanel: View {
    let asset: AssetItem
    @Binding var form: AssetEditFormState
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("编辑资产")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                }
                .padding(20)

                Divider().opacity(0.2).padding(.horizontal, 16)

                VStack(spacing: 14) {
                    editFieldRow("名称") {
                        TextField("资产名称", text: $form.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    editFieldRow("类别") {
                        Picker("", selection: $form.category) {
                            ForEach(assetCategories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                        .frame(width: 140)
                    }

                    editFieldRow("币种") {
                        TextField("CNY", text: $form.currency)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }

                    editFieldRow("备注") {
                        TextField("可选", text: $form.note)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
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
