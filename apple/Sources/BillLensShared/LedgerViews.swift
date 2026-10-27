import SwiftUI

enum LedgerViewMode: Hashable {
    case calendar
    case detail
}

struct LedgerShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var ledgerMode: LedgerViewMode = .calendar
    @State private var selectedLedgerDate: String?
    @State private var selectedCategoryFilter: String?
    @State private var recordToDelete: RecordItem?

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if let ledger = store.ledger {
                ledgerContent(ledger)
                    .onAppear { syncSelectedDate(for: ledger) }
                    .onChange(of: ledgerSignature(ledger)) { syncSelectedDate(for: ledger) }
                    .toolbar { toolbarContent(ledger) }
            } else {
                ProgressView("正在加载账单…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(
            "删除这笔账单？",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            ),
            presenting: recordToDelete
        ) { record in
            Button("删除", role: .destructive) {
                store.deleteRecord(record.id)
                recordToDelete = nil
            }
            Button("取消", role: .cancel) { recordToDelete = nil }
        } message: { record in
            Text("「\(record.merchant ?? record.category) \(BillLensFormatters.currencyString(record.amount, currencyCode: record.currency))」将被删除。")
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private func ledgerContent(_ ledger: LedgerSnapshot) -> some View {
        if usesCompactLayout {
            List {
                Section {
                    periodControls
                }
                Section {
                    summary(ledger)
                }
                Section {
                    periodNavigator(ledger)
                        .buttonStyle(.plain)
                }
                if store.selectedPreset != .year {
                    Section {
                        modePicker
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                recordSections(ledger)
            }
            .appListStyle()
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        periodControls
                        card { summary(ledger) }
                        card { periodNavigator(ledger) }
                    }
                    .padding(16)
                }
                .frame(width: 344)
                .background(AppColors.groupedBackground)

                Divider()

                List {
                    recordSections(ledger)
                }
                .appListStyle()
                .overlay {
                    if visibleDays(in: ledger).isEmpty {
                        emptyRecordsView
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ ledger: LedgerSnapshot) -> some ToolbarContent {
        if !usesCompactLayout && store.selectedPreset != .year {
            ToolbarItem(placement: .principal) {
                modePicker
                    .fixedSize()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            categoryFilterMenu(ledger)
        }
    }

    // MARK: Controls

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "统计周期",
                selection: Binding(
                    get: { store.selectedPreset },
                    set: { store.applyPreset($0) }
                )
            ) {
                ForEach(LedgerPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if store.selectedPreset == .custom {
                HStack(spacing: 8) {
                    DatePicker("开始", selection: $store.customStart, displayedComponents: .date)
                        .labelsHidden()
                    Text("至")
                        .foregroundStyle(.secondary)
                    DatePicker("结束", selection: $store.customEnd, displayedComponents: .date)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    Button("应用") {
                        store.applyPreset(.custom)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("视图", selection: $ledgerMode) {
            Text("按日").tag(LedgerViewMode.calendar)
            Text("全部明细").tag(LedgerViewMode.detail)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func categoryFilterMenu(_ ledger: LedgerSnapshot) -> some View {
        let categories = Array(Set(ledger.byDay.flatMap { $0.records.map(\.category) })).sorted()
        return Menu {
            Picker("分类", selection: $selectedCategoryFilter) {
                Text("全部分类").tag(String?.none)
                ForEach(categories, id: \.self) { category in
                    Label(category, systemImage: CategoryStyle.icon(for: category)).tag(String?.some(category))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                selectedCategoryFilter ?? "筛选",
                systemImage: selectedCategoryFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .help("按分类筛选")
    }

    private func summary(_ ledger: LedgerSnapshot) -> some View {
        let billCount = ledger.byDay.reduce(0) { $0 + $1.records.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SummaryStat(
                    title: "支出",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.expenseAmount,
                        currencyCode: ledger.statsCurrency
                    )
                )
                SummaryStat(
                    title: "收入",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.incomeAmount,
                        currencyCode: ledger.statsCurrency
                    ),
                    tint: AppColors.income
                )
                SummaryStat(title: "笔数", value: "\(billCount)")
            }

            if ledger.pendingSyncCount > 0 {
                Label("\(ledger.pendingSyncCount) 条待同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let warning = ledger.fxWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
            }
        }
    }

    @ViewBuilder
    private func periodNavigator(_ ledger: LedgerSnapshot) -> some View {
        if store.selectedPreset == .year {
            LedgerYearGrid(
                year: store.selectedYear,
                items: monthlyAggregation(from: ledger),
                onShift: { store.shiftLedgerYear(by: $0) }
            )
        } else {
            LedgerCalendarView(
                year: store.selectedYear,
                month: store.selectedMonth,
                ledger: ledger,
                selectedDate: $selectedLedgerDate,
                onShift: { store.shiftLedgerMonth(by: $0) }
            )
        }
    }

    // MARK: Records

    @ViewBuilder
    private func recordSections(_ ledger: LedgerSnapshot) -> some View {
        let days = visibleDays(in: ledger)
        if usesCompactLayout && days.isEmpty {
            Section {
                emptyRecordsView
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        ForEach(days) { day in
            Section {
                ForEach(filteredRecords(day.records)) { record in
                    RecordRowView(record: record)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                recordToDelete = record
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                recordToDelete = record
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(BillLensFormatters.displayDay(day.day))
                    Spacer()
                    Text(dayTotals(day, currency: ledger.statsCurrency))
                        .monospacedDigit()
                }
            }
        }
    }

    private var emptyRecordsView: some View {
        let isCalendarDay = store.selectedPreset != .year && ledgerMode == .calendar
        return ContentUnavailableView {
            Label(
                isCalendarDay ? "这一天没有账单" : "暂无账单",
                systemImage: isCalendarDay ? "calendar" : "list.bullet.rectangle"
            )
        } description: {
            Text(selectedCategoryFilter.map { "当前仅显示「\($0)」分类。" } ?? (isCalendarDay ? "在月历中选择有金额的日期查看明细。" : "在「记账」中添加第一笔账单。"))
        }
    }

    private func visibleDays(in ledger: LedgerSnapshot) -> [LedgerDayGroup] {
        let days: [LedgerDayGroup]
        if store.selectedPreset == .year || ledgerMode == .detail {
            days = Array(ledger.byDay.reversed())
        } else {
            days = ledger.byDay.filter { $0.day == selectedLedgerDate }
        }
        return days.filter { !filteredRecords($0.records).isEmpty }
    }

    private func filteredRecords(_ records: [RecordItem]) -> [RecordItem] {
        guard let filter = selectedCategoryFilter else { return records }
        return records.filter { $0.category == filter }
    }

    private func dayTotals(_ day: LedgerDayGroup, currency: String) -> String {
        var parts: [String] = []
        if day.expenseAmount > 0 {
            parts.append("支出 \(BillLensFormatters.currencyString(day.expenseAmount, currencyCode: currency))")
        }
        if day.incomeAmount > 0 {
            parts.append("收入 \(BillLensFormatters.currencyString(day.incomeAmount, currencyCode: currency))")
        }
        return parts.joined(separator: " · ")
    }

    private func syncSelectedDate(for ledger: LedgerSnapshot) {
        let validDates = Set(ledger.byDay.map(\.day))
        if let selectedLedgerDate, validDates.contains(selectedLedgerDate) {
            return
        }
        selectedLedgerDate = ledger.byDay.last?.day
    }

    private func ledgerSignature(_ ledger: LedgerSnapshot) -> String {
        ledger.byDay.map(\.day).joined(separator: "|")
    }

    private func monthlyAggregation(from ledger: LedgerSnapshot) -> [LedgerMonthItem] {
        var byMonth: [Int: (expense: Double, income: Double, count: Int)] = [:]
        for day in ledger.byDay {
            let parts = day.day.split(separator: "-")
            guard parts.count >= 2, let month = Int(parts[1]) else {
                preconditionFailure("账单日期格式错误：\(day.day)")
            }
            let existing = byMonth[month] ?? (0, 0, 0)
            byMonth[month] = (
                existing.expense + day.expenseAmount,
                existing.income + day.incomeAmount,
                existing.count + day.records.count
            )
        }
        return (1...12).map { month in
            let data = byMonth[month] ?? (0, 0, 0)
            return LedgerMonthItem(
                month: month,
                expenseAmount: data.expense,
                incomeAmount: data.income,
                recordCount: data.count,
                statsCurrency: ledger.statsCurrency
            )
        }
    }
}

extension View {
    @ViewBuilder
    func appListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}

// MARK: - Calendar

struct LedgerCalendarView: View {
    let year: Int
    let month: Int
    let ledger: LedgerSnapshot
    @Binding var selectedDate: String?
    let onShift: (Int) -> Void

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(spacing: 12) {
            PeriodHeader(
                title: "\(year)年\(month)月",
                subtitle: ledger.byDay.isEmpty ? "暂无账单" : "\(ledger.byDay.count) 天有账单",
                onShift: onShift
            )

            // 嵌在 List 行里时不能用 LazyVGrid：惰性网格的高度在滚动中反复重算，
            // 会让行高抖动，按钮也会被重建导致点击丢失。
            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(Self.weekdays, id: \.self) { label in
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week) { cell in
                            dayCell(cell)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: Cell) -> some View {
        if let day = cell.dayNumber, let date = cell.date {
            Button {
                selectedDate = date
            } label: {
                CalendarDayCell(
                    day: day,
                    amountText: cell.amountText,
                    isSelected: date == selectedDate,
                    isHot: cell.isHot,
                    isToday: cell.isToday
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(month)月\(day)日 \(cell.amountText)")
            .accessibilityAddTraits(date == selectedDate ? .isSelected : [])
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 46)
        }
    }

    private var weeks: [[Cell]] {
        var cells = cells
        while cells.count % 7 != 0 {
            cells.append(Cell(id: cells.count, date: nil, dayNumber: nil, amountText: "", isHot: false, isToday: false))
        }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private struct Cell: Identifiable {
        let id: Int
        let date: String?
        let dayNumber: Int?
        let amountText: String
        let isHot: Bool
        let isToday: Bool
    }

    private var cells: [Cell] {
        let calendar = Calendar.current
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstDay) else {
            preconditionFailure("无效的年月：\(year)-\(month)")
        }
        let leading = calendar.component(.weekday, from: firstDay) - 1
        let groups = Dictionary(uniqueKeysWithValues: ledger.byDay.map { ($0.day, $0) })
        let hottest = ledger.byDay.max(by: { $0.expenseAmount < $1.expenseAmount })?.day
        let now = Date.now
        let today = String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: now),
            calendar.component(.month, from: now),
            calendar.component(.day, from: now)
        )

        var result = (0..<leading).map {
            Cell(id: $0, date: nil, dayNumber: nil, amountText: "", isHot: false, isToday: false)
        }
        for day in dayRange {
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let amount = groups[date].map {
                $0.expenseAmount > 0 ? $0.expenseAmount : max($0.incomeAmount, abs($0.netAmount))
            }
            result.append(Cell(
                id: leading + day - 1,
                date: date,
                dayNumber: day,
                amountText: amount.map { compactAmount($0) } ?? "",
                isHot: date == hottest && amount != nil,
                isToday: date == today
            ))
        }
        return result
    }

    private func compactAmount(_ amount: Double) -> String {
        let code = BillLensFormatters.normalizedCurrencyCode(ledger.statsCurrency) ?? "CNY"
        let prefix = code == "CNY" ? "¥" : "\(code) "
        if amount >= 1000 {
            return prefix + String(format: "%.1fk", amount / 1000)
        }
        return "\(prefix)\(Int(amount.rounded()))"
    }
}

private struct CalendarDayCell: View {
    let day: Int
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text("\(day)")
                .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(dayColor)
                .frame(width: 30, height: 30)
                .background {
                    if isSelected {
                        Circle().fill(isToday ? AppColors.today : Color.accentColor)
                    }
                }
            Text(amountText.isEmpty ? " " : amountText)
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isHot ? AnyShapeStyle(AppColors.warning) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .contentShape(Rectangle())
    }

    private var dayColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(AppColors.today) }
        return AnyShapeStyle(.primary)
    }
}

private struct PeriodHeader: View {
    let title: String
    let subtitle: String
    let onShift: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 18) {
                Button { onShift(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("上一页")
                Button { onShift(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("下一页")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Year grid

struct LedgerMonthItem: Identifiable {
    var id: Int { month }
    let month: Int
    let expenseAmount: Double
    let incomeAmount: Double
    let recordCount: Int
    let statsCurrency: String
    var hasData: Bool { recordCount > 0 }
}

private struct LedgerYearGrid: View {
    let year: Int
    let items: [LedgerMonthItem]
    let onShift: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            PeriodHeader(
                title: "\(year)年",
                subtitle: "\(items.filter(\.hasData).count) 个月有账单",
                onShift: onShift
            )
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(items[start..<min(start + 3, items.count)]) { item in
                            monthCell(item)
                        }
                    }
                }
            }
        }
    }

    private func monthCell(_ item: LedgerMonthItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(item.month)月")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.hasData ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            if item.hasData {
                Text(BillLensFormatters.currencyString(item.expenseAmount, currencyCode: item.statsCurrency))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if item.incomeAmount > 0 {
                    Text("+" + BillLensFormatters.currencyString(item.incomeAmount, currencyCode: item.statsCurrency))
                        .font(.caption2)
                        .foregroundStyle(AppColors.income)
                }
                Text("\(item.recordCount) 笔")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("暂无")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
