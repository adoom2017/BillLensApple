import SwiftUI

// MARK: - 账单（新增 / 编辑）

enum RecordFormMode: Identifiable {
    case create
    case edit(RecordItem)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let record): record.id
        }
    }
}

struct RecordFormSheet: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss
    let mode: RecordFormMode

    @State private var direction: String
    @State private var amount: String
    @State private var currency: String
    @State private var category: String
    @State private var merchant: String
    @State private var transactionAt: Date
    @State private var note: String
    @State private var errorText: String?
    @State private var isSaving = false

    init(mode: RecordFormMode) {
        self.mode = mode
        switch mode {
        case .create:
            _direction = State(initialValue: "expense")
            _amount = State(initialValue: "")
            _currency = State(initialValue: "CNY")
            _category = State(initialValue: BillLensStore.categories(for: "expense").first ?? "其他")
            _merchant = State(initialValue: "")
            _transactionAt = State(initialValue: .now)
            _note = State(initialValue: "")
        case .edit(let record):
            _direction = State(initialValue: record.direction)
            _amount = State(initialValue: ManualFormat.amount(record.amount))
            _currency = State(initialValue: record.currency)
            _category = State(initialValue: record.category)
            _merchant = State(initialValue: record.merchant ?? "")
            let parsedTime = BillLensFormatters.parseISO(record.transactionAt)
            _transactionAt = State(initialValue: parsedTime ?? .now)
            _note = State(initialValue: record.note ?? "")
            if parsedTime == nil {
                // 不静默改写原时间：明确提示，由用户确认表单中显示的时间后再保存。
                _errorText = State(initialValue: "无法解析原账单时间「\(record.transactionAt)」，请确认时间后再保存。")
            }
        }
    }

    var body: some View {
        ManualFormContainer(
            title: isEditing ? "编辑账单" : "添加账单",
            errorText: errorText,
            isSaving: isSaving,
            onSave: save
        ) {
            Section {
                DirectionPicker(direction: $direction, category: $category)
                AmountField(amount: $amount)
                CurrencyField(currency: $currency)
                CategoryPicker(direction: direction, category: $category)
            }
            Section {
                LabeledContent("商户") {
                    TextField("商户", text: $merchant, prompt: Text("可选"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                DatePicker("时间", selection: $transactionAt)
                TextField("备注", text: $note, prompt: Text("备注"), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func save() {
        guard let value = ManualFormat.parseAmount(amount) else {
            errorText = "金额必须是大于 0 的数字。"
            return
        }
        let input = ManualRecordInput(
            direction: direction,
            amount: value,
            currency: currency,
            category: category,
            merchant: ManualFormat.optional(merchant),
            transactionAt: BillLensFormatters.timestampFallback.string(from: transactionAt),
            note: ManualFormat.optional(note)
        )
        run {
            switch mode {
            case .create: try await store.createRecord(input)
            case .edit(let record): try await store.updateRecord(record.id, input: input)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        ManualFormat.run(isSaving: $isSaving, errorText: $errorText, dismiss: dismiss, operation)
    }
}

// MARK: - 订阅（新增）

struct SubscriptionCreateSheet: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss

    @State private var direction = "expense"
    @State private var amount = ""
    @State private var currency = "CNY"
    @State private var category = "订阅"
    @State private var merchant = ""
    @State private var note = ""
    @State private var cycle = "monthly"
    @State private var firstChargeOn = Date.now
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        ManualFormContainer(title: "添加订阅", errorText: errorText, isSaving: isSaving, onSave: save) {
            Section {
                DirectionPicker(direction: $direction, category: $category)
                AmountField(amount: $amount)
                CurrencyField(currency: $currency)
                CategoryPicker(direction: direction, category: $category)
            }
            Section {
                LabeledContent("商户") {
                    TextField("商户", text: $merchant, prompt: Text("如：视频会员"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                TextField("备注", text: $note, prompt: Text("备注"), axis: .vertical)
                    .lineLimit(1...4)
            }
            Section {
                Picker("周期", selection: $cycle) {
                    Text("每月").tag("monthly")
                    Text("每年").tag("yearly")
                }
                .pickerStyle(.segmented)
                DatePicker("首次扣费", selection: $firstChargeOn, displayedComponents: .date)
            } header: {
                Text("扣费周期")
            } footer: {
                Text(chargeHint)
            }
        }
    }

    private var chargeHint: String {
        Calendar.current.startOfDay(for: firstChargeOn) <= Calendar.current.startOfDay(for: .now)
            ? "首次扣费日不晚于今天：保存后立即记录到今天为止的每期扣费。"
            : "首次扣费日在将来：到期后自动记账。"
    }

    private func save() {
        guard let value = ManualFormat.parseAmount(amount) else {
            errorText = "金额必须是大于 0 的数字。"
            return
        }
        let input = ManualSubscriptionInput(
            direction: direction,
            amount: value,
            currency: currency,
            category: category,
            merchant: ManualFormat.optional(merchant),
            note: ManualFormat.optional(note),
            cycle: cycle,
            firstChargeOn: ManualFormat.localDay(firstChargeOn)
        )
        ManualFormat.run(isSaving: $isSaving, errorText: $errorText, dismiss: dismiss) {
            try await store.createSubscription(input)
        }
    }
}

// MARK: - 资产（新增 / 更新估值）

enum AssetFormMode: Identifiable {
    case create
    case valuation(AssetItem)

    var id: String {
        switch self {
        case .create: "create"
        case .valuation(let asset): asset.id
        }
    }
}

struct AssetFormSheet: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss
    let mode: AssetFormMode

    @State private var name = ""
    @State private var category = AssetShell.categories.first ?? "其他"
    @State private var currency = "CNY"
    @State private var amount = ""
    @State private var recordedOn = Date.now
    @State private var note = ""
    @State private var errorText: String?
    @State private var isSaving = false

    init(mode: AssetFormMode) {
        self.mode = mode
        if case .valuation(let asset) = mode {
            _amount = State(initialValue: asset.latestAmount.map(ManualFormat.amount) ?? "")
        }
    }

    var body: some View {
        ManualFormContainer(title: title, errorText: errorText, isSaving: isSaving, onSave: save) {
            switch mode {
            case .create:
                Section {
                    LabeledContent("名称") {
                        TextField("名称", text: $name, prompt: Text("如：招商银行"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("类别", selection: $category) {
                        ForEach(AssetShell.categories, id: \.self) { category in
                            Label(category, systemImage: CategoryStyle.assetIcon(for: category)).tag(category)
                        }
                    }
                    CurrencyField(currency: $currency)
                }
            case .valuation(let asset):
                Section {
                    LabeledContent("资产", value: asset.name)
                    if let latest = asset.latestAmount {
                        LabeledContent(
                            "上次估值",
                            value: BillLensFormatters.currencyString(latest, currencyCode: asset.currency)
                        )
                    }
                }
            }
            Section {
                AmountField(amount: $amount, title: "当前金额")
                DatePicker("估值日期", selection: $recordedOn, displayedComponents: .date)
                TextField("备注", text: $note, prompt: Text("备注"), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("同一天再次保存会覆盖当天的估值。")
            }
        }
    }

    private var title: String {
        if case .valuation = mode { return "更新估值" }
        return "添加资产"
    }

    private func save() {
        guard let value = ManualFormat.parseAmount(amount) else {
            errorText = "金额必须是大于 0 的数字。"
            return
        }
        let info: ParsedAssetInfo
        switch mode {
        case .create:
            info = ParsedAssetInfo(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category,
                amount: value,
                currency: currency,
                recordedOn: ManualFormat.localDay(recordedOn),
                note: ManualFormat.optional(note)
            )
        case .valuation(let asset):
            // 沿用资产当前的名称、类别、币种：按名称合并到同一资产，只新增或覆盖该日估值。
            info = ParsedAssetInfo(
                name: asset.name,
                category: asset.category,
                amount: value,
                currency: asset.currency,
                recordedOn: ManualFormat.localDay(recordedOn),
                note: ManualFormat.optional(note)
            )
        }
        ManualFormat.run(isSaving: $isSaving, errorText: $errorText, dismiss: dismiss) {
            try await store.saveAssetValuation(info)
        }
    }
}

// MARK: - 共用组件

private struct ManualFormContainer<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let errorText: String?
    let isSaving: Bool
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            Form {
                content()
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.destructive)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}

private struct DirectionPicker: View {
    @Binding var direction: String
    @Binding var category: String

    var body: some View {
        Picker("类型", selection: $direction) {
            Text("支出").tag("expense")
            Text("收入").tag("income")
        }
        .pickerStyle(.segmented)
        .onChange(of: direction) { _, newValue in
            let categories = BillLensStore.categories(for: newValue)
            if !categories.contains(category) {
                category = categories.first ?? "其他"
            }
        }
    }
}

private struct CategoryPicker: View {
    let direction: String
    @Binding var category: String

    var body: some View {
        Picker("分类", selection: $category) {
            ForEach(BillLensStore.categories(for: direction), id: \.self) { name in
                Label(name, systemImage: CategoryStyle.icon(for: name)).tag(name)
            }
        }
    }
}

private struct AmountField: View {
    @Binding var amount: String
    var title = "金额"

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $amount, prompt: Text("0.00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }
}

private struct CurrencyField: View {
    @Binding var currency: String

    var body: some View {
        LabeledContent("币种") {
            TextField("币种", text: $currency, prompt: Text("CNY"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
        }
    }
}

@MainActor
enum ManualFormat {
    static func parseAmount(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }

    static func amount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 设备时区的本地日期，供 Rust 按本地日历解释。
    static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 保存中禁用按钮；失败时错误留在表单内，sheet 不关闭，便于就地修改。
    static func run(
        isSaving: Binding<Bool>,
        errorText: Binding<String?>,
        dismiss: DismissAction,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        isSaving.wrappedValue = true
        errorText.wrappedValue = nil
        Task { @MainActor in
            defer { isSaving.wrappedValue = false }
            do {
                try await operation()
                dismiss()
            } catch {
                errorText.wrappedValue = error.localizedDescription
            }
        }
    }
}
