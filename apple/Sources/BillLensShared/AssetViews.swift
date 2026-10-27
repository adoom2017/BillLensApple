import Charts
import SwiftUI

// MARK: - Asset Management Shell

struct AssetShell: View {
    static let categories = ["存款", "现金", "股票", "基金", "加密货币", "房产", "其他"]

    @EnvironmentObject private var store: BillLensStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var assetToDelete: AssetItem?
    @State private var editingAsset: AssetItem?
    @State private var assetForm: AssetFormMode?

    private var usesCompactLayout: Bool {
        sizeClass == .compact
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                assetList
                    .navigationDestination(item: $store.selectedAssetId) { _ in
                        detail
                    }
            } else {
                HStack(spacing: 0) {
                    assetList
                        .frame(width: 340)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            do {
                try await store.loadAssets()
            } catch {
                store.errorText = error.localizedDescription
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    assetForm = .create
                } label: {
                    Label("添加资产", systemImage: "plus")
                }
                .help("手动添加资产")
            }
        }
        .sheet(item: $assetForm) { mode in
            AssetFormSheet(mode: mode)
                .environmentObject(store)
        }
        .sheet(item: $editingAsset) { asset in
            AssetEditSheet(asset: asset) { update in
                store.updateAsset(asset.id, update: update)
            }
        }
        .alert(
            "删除这个资产？",
            isPresented: Binding(
                get: { assetToDelete != nil },
                set: { if !$0 { assetToDelete = nil } }
            ),
            presenting: assetToDelete
        ) { asset in
            Button("删除", role: .destructive) {
                store.deleteAsset(asset.id)
                assetToDelete = nil
            }
            Button("取消", role: .cancel) { assetToDelete = nil }
        } message: { _ in
            Text("所有历史余额快照将一并移除，操作不可撤销。")
        }
    }

    // MARK: List

    private var assetList: some View {
        List(selection: usesCompactLayout ? nil : $store.selectedAssetId) {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("资产合计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalValueText)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("\(store.assets.count) 个账户")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .selectionDisabled()

            Section("资产账户") {
                if store.assets.isEmpty {
                    ContentUnavailableView {
                        Label("暂无资产", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("在「记账」中输入「招商银行存款还有 54000 元」即可自动创建资产。")
                    }
                    .frame(maxWidth: .infinity)
                    .selectionDisabled()
                } else {
                    ForEach(store.assets) { asset in
                        row(asset)
                            .tag(asset.id)
                    }
                }
            }
        }
        .appListStyle()
    }

    @ViewBuilder
    private func row(_ asset: AssetItem) -> some View {
        let content = AssetRow(asset: asset)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    assetToDelete = asset
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    editingAsset = asset
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    assetToDelete = asset
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        if usesCompactLayout {
            Button {
                store.selectedAssetId = asset.id
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

    /// 多币种无法直接相加时只显示有余额的账户数，不做隐式换算。
    private var totalValueText: String {
        let valued = store.assets.compactMap { asset -> (Double, String)? in
            guard let amount = asset.latestAmount else { return nil }
            return (amount, asset.currency)
        }
        guard let currency = valued.first?.1 else { return "暂无余额" }
        guard valued.allSatisfy({ $0.1 == currency }) else {
            return "\(valued.count) 项有余额"
        }
        return BillLensFormatters.currencyString(valued.reduce(0) { $0 + $1.0 }, currencyCode: currency)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let asset = store.selectedAsset {
            AssetDetailView(
                asset: asset,
                onEdit: { editingAsset = asset },
                onUpdateValuation: { assetForm = .valuation(asset) },
                onDelete: { assetToDelete = asset },
                onDeleteSnapshot: { store.deleteAssetSnapshot($0) }
            )
        } else {
            ContentUnavailableView("选择一个资产", systemImage: "chart.line.uptrend.xyaxis", description: Text("在左侧列表中选择资产查看趋势。"))
        }
    }
}

// MARK: - Row

struct AssetRow: View {
    let asset: AssetItem

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(
                systemImage: CategoryStyle.assetIcon(for: asset.category),
                color: CategoryStyle.assetColor(for: asset.category)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .lineLimit(1)
                Text("\(asset.category) · \(asset.snapshots.count) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(asset.latestAmount.map { BillLensFormatters.currencyString($0, currencyCode: asset.currency) } ?? "—")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                if let day = asset.latestRecordedOn {
                    Text(BillLensFormatters.displayDay(day))
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

struct AssetDetailView: View {
    let asset: AssetItem
    let onEdit: () -> Void
    let onUpdateValuation: () -> Void
    let onDelete: () -> Void
    let onDeleteSnapshot: (String) -> Void
    @State private var snapshotToDelete: AssetSnapshotItem?

    private var sortedSnapshots: [AssetSnapshotItem] {
        asset.snapshots.sorted { $0.recordedOn < $1.recordedOn }
    }

    var body: some View {
        Form {
            Section {
                DetailHeader(
                    icon: CategoryStyle.assetIcon(for: asset.category),
                    color: CategoryStyle.assetColor(for: asset.category),
                    title: asset.name,
                    amount: asset.latestAmount.map { BillLensFormatters.currencyString($0, currencyCode: asset.currency) },
                    caption: asset.latestRecordedOn.map { "截至 \(BillLensFormatters.displayDay($0))" }
                ) {
                    StatusTag(title: asset.category, color: .accentColor)
                    StatusTag(title: asset.currency, color: .secondary)
                }
            }

            Section("余额趋势") {
                trendChart
            }

            Section("历史记录") {
                if sortedSnapshots.isEmpty {
                    Text("暂无快照")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedSnapshots.reversed()) { snapshot in
                    snapshotRow(snapshot)
                }
            }

            Section {
                Button("更新估值", action: onUpdateValuation)
                Button("编辑资产", action: onEdit)
                Button("删除资产", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(asset.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            "删除这条快照？",
            isPresented: Binding(
                get: { snapshotToDelete != nil },
                set: { if !$0 { snapshotToDelete = nil } }
            ),
            presenting: snapshotToDelete
        ) { snapshot in
            Button("删除", role: .destructive) {
                onDeleteSnapshot(snapshot.id)
                snapshotToDelete = nil
            }
            Button("取消", role: .cancel) { snapshotToDelete = nil }
        } message: { _ in
            Text("删除后该日期的余额记录将消失，趋势图将相应更新。")
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        if sortedSnapshots.count < 2 {
            Text(sortedSnapshots.isEmpty ? "暂无快照数据" : "至少需要两条快照才能显示趋势")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(sortedSnapshots) { snapshot in
                AreaMark(
                    x: .value("日期", snapshot.recordedOn),
                    y: .value("金额", snapshot.amount)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("日期", snapshot.recordedOn),
                    y: .value("金额", snapshot.amount)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("日期", snapshot.recordedOn),
                    y: .value("金额", snapshot.amount)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(30)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: 200)
            .padding(.vertical, 8)
        }
    }

    private func snapshotRow(_ snapshot: AssetSnapshotItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(BillLensFormatters.displayDay(snapshot.recordedOn))
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(BillLensFormatters.currencyString(snapshot.amount, currencyCode: asset.currency))
                .monospacedDigit()
            #if os(macOS)
            Button {
                snapshotToDelete = snapshot
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除快照")
            .accessibilityLabel("删除快照")
            #endif
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                snapshotToDelete = snapshot
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                snapshotToDelete = snapshot
            } label: {
                Label("删除快照", systemImage: "trash")
            }
        }
    }
}

// MARK: - Edit

struct AssetEditFormState {
    var name: String
    var category: String
    var currency: String
    var note: String

    init(asset: AssetItem) {
        name = asset.name
        category = asset.category
        currency = asset.currency
        note = asset.note ?? ""
    }

    var updateInput: AssetUpdateInput {
        AssetUpdateInput(
            name: name.isEmpty ? nil : name,
            category: category,
            currency: currency.isEmpty ? nil : currency,
            note: note.isEmpty ? nil : note
        )
    }
}

struct AssetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form: AssetEditFormState
    let onSave: (AssetUpdateInput) -> Void

    init(asset: AssetItem, onSave: @escaping (AssetUpdateInput) -> Void) {
        _form = State(initialValue: AssetEditFormState(asset: asset))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("名称") {
                    TextField("名称", text: $form.name, prompt: Text("资产名称"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                Picker("类别", selection: $form.category) {
                    ForEach(AssetShell.categories, id: \.self) { category in
                        Label(category, systemImage: CategoryStyle.assetIcon(for: category)).tag(category)
                    }
                }
                LabeledContent("币种") {
                    TextField("币种", text: $form.currency, prompt: Text("CNY"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                TextField("备注", text: $form.note, prompt: Text("备注"), axis: .vertical)
                    .lineLimit(1...4)
            }
            .formStyle(.grouped)
            .navigationTitle("编辑资产")
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
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
