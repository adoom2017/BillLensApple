import SwiftUI

/// 信用卡账单导入预览：勾选、改分类，确认后一次性写入。
struct StatementImportView: View {
    @EnvironmentObject private var store: BillLensStore
    let session: StatementImportSession

    @State private var selected: Set<String>
    @State private var categories: [String: String] = [:]
    @State private var showsExcluded = false

    init(session: StatementImportSession) {
        self.session = session
        _selected = State(initialValue: Set(session.preview.lines.filter(\.defaultSelected).map(\.lineId)))
    }

    private var preview: StatementPreview { session.preview }

    private var importableSections: [(StatementSection, [StatementLine])] {
        StatementSection.allCases.compactMap { section in
            let lines = preview.lines.filter { $0.section == section && $0.direction != nil }
            return lines.isEmpty ? nil : (section, lines)
        }
    }

    private var excludedLines: [StatementLine] {
        preview.lines.filter { $0.direction == nil }
    }

    private var selectedTotal: Double {
        preview.lines
            .filter { selected.contains($0.lineId) }
            .reduce(0) { $0 + ($1.direction == "income" ? -$1.amount : $1.amount) }
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                ForEach(importableSections, id: \.0) { section, lines in
                    Section {
                        ForEach(lines) { line in
                            StatementLineRow(
                                line: line,
                                isSelected: binding(for: line),
                                category: categoryBinding(for: line)
                            )
                        }
                    } header: {
                        Text("\(section.title) · \(lines.count) 笔")
                    }
                }
                if session.mailMessageId != nil {
                    Section {
                        Button("忽略这封账单的剩余条目", role: .destructive) {
                            store.ignoreMailStatement()
                        }
                        .disabled(store.isBusy)
                    } footer: {
                        Text("已自动记账的条目不受影响；剩余条目不入账，也不再提醒。")
                    }
                }
                if !excludedLines.isEmpty {
                    Section {
                        DisclosureGroup("还款等不计入收支的 \(excludedLines.count) 笔", isExpanded: $showsExcluded) {
                            ForEach(excludedLines) { line in
                                HStack {
                                    Text(line.merchant)
                                    Spacer()
                                    Text(BillLensFormatters.currencyString(line.amount, currencyCode: "CNY"))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .appListStyle()
            .navigationTitle("导入信用卡账单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 邮箱账单取消后仍保留在待确认中，下次可继续处理。
                    Button(session.mailMessageId == nil ? "取消" : "稍后") { store.cancelStatementImport() }
                        .disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入 \(selected.count) 笔") {
                        store.confirmStatementImport(
                            selectedLineIds: Array(selected),
                            categoryOverrides: categories.filter { selected.contains($0.key) }
                        )
                    }
                    .disabled(selected.isEmpty || store.isBusy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 600, idealHeight: 720)
        #endif
        .interactiveDismissDisabled(store.isBusy)
    }

    private var summarySection: some View {
        Section {
            LabeledContent(preview.bank, value: "尾号 \(preview.cardLast4.joined(separator: " / "))")
            LabeledContent("账单周期", value: "\(preview.periodStart) – \(preview.periodEnd)")
            if let dueOn = preview.dueOn {
                LabeledContent("到期还款日", value: dueOn)
            }
            if let amountDue = preview.amountDue {
                LabeledContent("本期应还", value: BillLensFormatters.currencyString(amountDue, currencyCode: "CNY"))
            }
            reconciliationRow
            LabeledContent("已选合计", value: BillLensFormatters.currencyString(selectedTotal, currencyCode: "CNY"))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var reconciliationRow: some View {
        let failed = preview.reconciliation.filter { !$0.ok }
        if preview.reconciliation.isEmpty {
            Label("账单中没有汇总栏，无法核对合计", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        } else if failed.isEmpty {
            Label("明细与账单汇总一致", systemImage: "checkmark.seal.fill")
                .foregroundStyle(AppColors.income)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("明细与账单汇总不一致，请核对", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                ForEach(failed, id: \.name) { check in
                    Text("\(check.name)：账单 \(money(check.expected))，明细 \(money(check.actual))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func money(_ value: Double) -> String {
        BillLensFormatters.currencyString(value, currencyCode: "CNY")
    }

    private func binding(for line: StatementLine) -> Binding<Bool> {
        Binding(
            get: { selected.contains(line.lineId) },
            set: { isOn in
                if isOn { selected.insert(line.lineId) } else { selected.remove(line.lineId) }
            }
        )
    }

    private func categoryBinding(for line: StatementLine) -> Binding<String> {
        Binding(
            get: { categories[line.lineId] ?? line.category },
            set: { value in
                categories[line.lineId] = value == line.category ? nil : value
            }
        )
    }
}

private struct StatementLineRow: View {
    let line: StatementLine
    @Binding var isSelected: Bool
    @Binding var category: String

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .opacity(line.isImportable ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 3) {
                Text(line.merchant)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(day)
                    Menu {
                        Picker("分类", selection: $category) {
                            ForEach(BillLensStore.categories(for: line.direction ?? ""), id: \.self) { name in
                                Label(name, systemImage: CategoryStyle.icon(for: name)).tag(name)
                            }
                        }
                    } label: {
                        Label(category, systemImage: CategoryStyle.icon(for: category))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(!line.isImportable)
                    statusBadge
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let match = line.matchedRecord {
                    Text("可能与已有记录重复：\(match.merchant ?? match.category) · \(BillLensFormatters.displayDateTime(match.transactionAt))")
                        .font(.caption2)
                        .foregroundStyle(AppColors.warning)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            AmountText(amount: line.amount, currency: "CNY", direction: line.direction ?? "expense")
                .font(.body.weight(.medium))
        }
        .opacity(line.status == .imported ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if line.isImportable { isSelected.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var day: String {
        BillLensFormatters.parseISO(line.transactionAt).map(Self.dayFormatter.string(from:)) ?? ""
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch line.status {
        case .imported:
            Text("已导入")
        case .suspectedDuplicate:
            Text("疑似重复").foregroundStyle(AppColors.warning)
        case .new, .excluded:
            EmptyView()
        }
    }
}
