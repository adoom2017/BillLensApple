import SwiftUI

struct LedgerShell: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var ledgerMode: LedgerViewMode = .calendar
    @State private var selectedLedgerDate: String?
    @State private var cachedCalendarCells: [LedgerCalendarCell] = []
    @State private var cachedCalendarKey: String = ""
    @State private var selectedCategoryFilter: String? = nil
    @State private var recordToDelete: RecordItem? = nil
    let availableHeight: CGFloat

    private let masterWidth: CGFloat = 340

    var body: some View {
        Group {
            if let ledger = store.ledger {
                HStack(spacing: 0) {
                    // MARK: - Left Master Panel
                    VStack(alignment: .leading, spacing: 16) {
                        // Time preset tabs
                        HStack(spacing: 4) {
                            ForEach(LedgerPreset.allCases) { preset in
                                Button {
                                    store.applyPreset(preset)
                                } label: {
                                    Text(preset.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(
                                            store.selectedPreset == preset
                                                ? IMColors.textPrimary
                                                : IMColors.textSecondary
                                        )
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(
                                                    store.selectedPreset == preset
                                                        ? IMColors.controlBg
                                                        : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if store.selectedPreset == .custom {
                            HStack(spacing: 6) {
                                DatePicker("", selection: $store.customStart, displayedComponents: .date)
                                    .labelsHidden()
                                    .frame(width: 100)
                                Text("–")
                                    .foregroundStyle(IMColors.textMuted)
                                    .font(.system(size: 12))
                                DatePicker("", selection: $store.customEnd, displayedComponents: .date)
                                    .labelsHidden()
                                    .frame(width: 100)
                                ActionButton(title: "应用", kind: .ghost) {
                                    store.applyPreset(.custom)
                                }
                            }
                        }

                        // Stat bar with inset shadow
                        statBar(ledger)

                        // Calendar or monthly aggregation
                        if store.selectedPreset == .year {
                            monthlyAggregationGrid(ledger)
                        } else {
                            calendarPanel(ledger)
                        }

                        // Quick category filters
                        quickCategoryFilters(ledger)
                    }
                    .frame(width: masterWidth)
                    .padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(IMColors.panelBg)

                    // MARK: - Grooved Divider
                    ZStack {
                        IMColors.dividerLegacy
                            .frame(width: 1)
                        Color.white.opacity(0.5)
                            .frame(width: 1)
                            .offset(x: 1)
                    }
                    .frame(width: 2)

                    // MARK: - Right Detail Panel
                    VStack(alignment: .leading, spacing: 0) {
                        // Mode tabs at top of detail (hide "按日" in year mode)
                        if store.selectedPreset != .year {
                            HStack(spacing: 4) {
                                ledgerModeButton(.calendar, title: "按日")
                                ledgerModeButton(.detail, title: "全部明细")
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                            Divider().opacity(0.2)
                        }

                        Group {
                            if store.selectedPreset == .year {
                                detailLedgerView(ledger)
                            } else {
                                switch ledgerMode {
                                case .calendar:
                                    rightPanelCalendarDetail(ledger)
                                case .detail:
                                    detailLedgerView(ledger)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                }
                .onAppear {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: ledgerSignature(ledger)) {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: selectedLedgerDate) {
                    updateCalendarCellSelection()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在加载账单视图")
                        .font(.system(size: 16, weight: .semibold))
                    Text("首次启动后会自动读取本地账本数据。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxHeight: availableHeight)
        .alert(
            "确认删除",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { recordToDelete = nil }
            Button("删除", role: .destructive) {
                if let record = recordToDelete {
                    store.deleteRecord(record.id)
                    recordToDelete = nil
                }
            }
        } message: {
            if let record = recordToDelete {
                Text("确定要删除「\(record.merchant ?? record.category) \(BillLensFormatters.currencyString(record.amount, currencyCode: record.currency))」吗？")
            }
        }
    }

    private func statBar(_ ledger: LedgerSnapshot) -> some View {
        let billCount = ledger.byDay.reduce(0) { $0 + $1.records.count }
        let statBg = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                LedgerSummaryCard(
                    title: "支出",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.expenseAmount,
                        currencyCode: ledger.statsCurrency
                    ),
                    accent: .expense
                )
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(
                    title: "收入",
                    value: BillLensFormatters.currencyString(
                        ledger.summary.summary.incomeAmount,
                        currencyCode: ledger.statsCurrency
                    ),
                    accent: .income
                )
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(title: "笔数", value: "\(billCount)", accent: .neutral)
                Divider().frame(height: 24).opacity(0.2).padding(.horizontal, 8)
                LedgerSummaryCard(title: "同步", value: "\(ledger.pendingSyncCount)", accent: .neutral)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                statBg
                    .fill(IMColors.statBg)
                    .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
                    .overlay(statBg.stroke(Color.black.opacity(0.04), lineWidth: 0.5))
            )

            if let warning = ledger.fxWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColors.ledgerStatGoldBold)
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IMColors.ledgerStatGold)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(IMColors.warningBg)
                )
            }
        }
    }

    private func ledgerModeButton(_ mode: LedgerViewMode, title: String) -> some View {
        Button {
            ledgerMode = mode
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    ledgerMode == mode
                        ? IMColors.textPrimary
                        : IMColors.textSecondary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            ledgerMode == mode
                                ? IMColors.controlBg
                                : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func rightPanelCalendarDetail(_ ledger: LedgerSnapshot) -> some View {
        Group {
            if let selectedGroup = selectedLedgerGroup(in: ledger) {
                ScrollView {
                    ledgerDayDetail(selectedGroup, statsCurrency: ledger.statsCurrency)
                }
                .scrollIndicators(.automatic)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(IMColors.textPlaceholder)
                    Text("请在月历中选择一天查看明细")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IMColors.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func quickCategoryFilters(_ ledger: LedgerSnapshot) -> some View {
        let allCategories = Array(Set(ledger.byDay.flatMap { $0.records.map(\.category) })).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text("筛选分类")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IMColors.textSecondary)
            WrappingHStack(alignment: .leading, spacing: 6) {
                categoryPill(title: "全部", isSelected: selectedCategoryFilter == nil) {
                    selectedCategoryFilter = nil
                }
                ForEach(allCategories, id: \.self) { cat in
                    categoryPill(title: cat, isSelected: selectedCategoryFilter == cat) {
                        selectedCategoryFilter = (selectedCategoryFilter == cat) ? nil : cat
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundStyle(
                    isSelected
                        ? IMColors.textPrimary
                        : IMColors.filterMuted
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white)
                        .shadow(
                            color: isSelected ? Color.clear : Color.black.opacity(0.06),
                            radius: isSelected ? 0 : 2, x: 0, y: 1
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.black.opacity(isSelected ? 0.08 : 0.03), lineWidth: 0.5)
                )
                .overlay(
                    isSelected
                        ? Capsule()
                            .fill(Color.black.opacity(0.03))
                        : nil
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func calendarPanel(_ ledger: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.shiftLedgerMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.selectedYear)年\(store.selectedMonth)月")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(calendarMetaText(ledger))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }

                Spacer()

                Button {
                    store.shiftLedgerMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4
            ) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4
            ) {
                ForEach(cachedCalendarCells) { cell in
                    if let day = cell.dayNumber, let date = cell.date {
                        CalendarDayCellButton(
                            day: day,
                            date: date,
                            amountText: cell.amountText,
                            isSelected: cell.isSelected,
                            isHot: cell.isHot,
                            isToday: cell.isToday,
                            backgroundStyle: calendarCellBackground(for: cell)
                        ) {
                            selectedLedgerDate = date
                        }
                    } else {
                        Color.clear
                            .frame(minHeight: 54)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func monthlyAggregationGrid(_ ledger: LedgerSnapshot) -> some View {
        let monthlyData = buildMonthlyAggregation(from: ledger)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.shiftLedgerYear(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.selectedYear)年")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Text("按月聚合 · \(monthlyData.filter { $0.hasData }.count) 个月有账单")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }

                Spacer()

                Button {
                    store.shiftLedgerYear(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.96))
                                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
            ) {
                ForEach(monthlyData) { item in
                    MonthAggregationCard(item: item)
                }
            }
        }
    }

    struct MonthlyAggregationItem: Identifiable {
        let id: Int
        let month: Int
        let expenseAmount: Double
        let incomeAmount: Double
        let recordCount: Int
        let statsCurrency: String
        var hasData: Bool { recordCount > 0 }
    }

    private func buildMonthlyAggregation(from ledger: LedgerSnapshot) -> [MonthlyAggregationItem] {
        var byMonth: [Int: (expense: Double, income: Double, count: Int)] = [:]
        for m in 1...12 { byMonth[m] = (0, 0, 0) }

        for day in ledger.byDay {
            let parts = day.day.split(separator: "-")
            guard parts.count >= 2, let month = Int(parts[1]) else { continue }
            let existing = byMonth[month] ?? (0, 0, 0)
            byMonth[month] = (
                existing.expense + day.expenseAmount,
                existing.income + day.incomeAmount,
                existing.count + day.records.count
            )
        }

        return (1...12).map { m in
            let data = byMonth[m]!
            return MonthlyAggregationItem(
                id: m,
                month: m,
                expenseAmount: data.expense,
                incomeAmount: data.income,
                recordCount: data.count,
                statsCurrency: ledger.statsCurrency
            )
        }
    }

    private func detailLedgerView(_ ledger: LedgerSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ledger.byDay) { day in
                    let records = filteredRecords(day.records)
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(BillLensFormatters.displayDay(day.day))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(IMColors.textPrimary)
                                Spacer()
                                Text(
                                    "净额 \(BillLensFormatters.currencyString(day.netAmount, currencyCode: ledger.statsCurrency))"
                                )
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(
                                        day.netAmount >= 0
                                            ? IMColors.income
                                            : IMColors.accentDark)
                            }
                            ForEach(records) { record in
                                RecordRowView(record: record) { recordToDelete = record }
                                    .padding(.vertical, 6)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        Divider().opacity(0.15).padding(.horizontal, 16)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func filteredRecords(_ records: [RecordItem]) -> [RecordItem] {
        guard let filter = selectedCategoryFilter else { return records }
        return records.filter { $0.category == filter }
    }

    private func ledgerDayDetail(_ day: LedgerDayGroup, statsCurrency: String) -> some View {
        let records = filteredRecords(day.records)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(BillLensFormatters.displayDay(day.day))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                    Spacer()
                    Text(
                        "支出 \(BillLensFormatters.currencyString(day.expenseAmount, currencyCode: statsCurrency))"
                    )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                }
            }

            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    Divider().opacity(0.4)
                }
                RecordRowView(record: record) { recordToDelete = record }
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
    }

    private func syncCalendarState(for ledger: LedgerSnapshot) {
        let validDates = Set(ledger.byDay.map(\.day))
        if selectedLedgerDate == nil || !validDates.contains(selectedLedgerDate!) {
            selectedLedgerDate = ledger.byDay.last?.day
        }
    }

    private func ledgerSignature(_ ledger: LedgerSnapshot) -> String {
        ledger.byDay.map(\.day).joined(separator: "|")
    }

    private func calendarMetaText(_ ledger: LedgerSnapshot) -> String {
        let daysWithData = ledger.byDay.count
        return daysWithData == 0 ? "暂无账单" : "按天聚合 · \(daysWithData) 天"
    }

    private func selectedLedgerGroup(in ledger: LedgerSnapshot) -> LedgerDayGroup? {
        guard let selectedLedgerDate else { return nil }
        return ledger.byDay.first(where: { $0.day == selectedLedgerDate })
    }

    private func rebuildCalendarCellsIfNeeded(for ledger: LedgerSnapshot) {
        let key = "\(store.selectedYear)-\(store.selectedMonth)|\(ledgerSignature(ledger))"
        guard key != cachedCalendarKey else { return }
        cachedCalendarKey = key
        cachedCalendarCells = buildCalendarCells(for: ledger)
    }

    private func updateCalendarCellSelection() {
        cachedCalendarCells = cachedCalendarCells.map { cell in
            guard cell.dayNumber != nil else { return cell }
            let selected = cell.date == selectedLedgerDate
            guard selected != cell.isSelected else { return cell }
            return LedgerCalendarCell(
                id: cell.id,
                date: cell.date,
                dayNumber: cell.dayNumber,
                amountText: cell.amountText,
                isSelected: selected,
                isHot: cell.isHot,
                isToday: cell.isToday
            )
        }
    }

    private func buildCalendarCells(for ledger: LedgerSnapshot) -> [LedgerCalendarCell] {
        let year = store.selectedYear
        let month = store.selectedMonth

        let hottestDate = ledger.byDay.max(by: { $0.expenseAmount < $1.expenseAmount })?.day
        let groupMap = Dictionary(uniqueKeysWithValues: ledger.byDay.map { ($0.day, $0) })
        let todayString: String = {
            let now = Date()
            let y = Calendar.current.component(.year, from: now)
            let m = Calendar.current.component(.month, from: now)
            let d = Calendar.current.component(.day, from: now)
            return String(format: "%04d-%02d-%02d", y, m, d)
        }()
        let firstWeekday =
            Calendar.current.component(.weekday, from: dateFrom(year: year, month: month, day: 1))
            - 1
        let daysInMonth =
            Calendar.current.range(
                of: .day, in: .month, for: dateFrom(year: year, month: month, day: 1))?.count ?? 0

        var cells: [LedgerCalendarCell] = []
        for i in 0..<firstWeekday {
            cells.append(LedgerCalendarCell(
                id: i, date: nil, dayNumber: nil, amountText: "", isSelected: false, isHot: false, isToday: false
            ))
        }
        for day in 1...daysInMonth {
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let group = groupMap[date]
            let amount = group.map {
                $0.expenseAmount > 0 ? $0.expenseAmount : max($0.incomeAmount, abs($0.netAmount))
            }
            cells.append(
                LedgerCalendarCell(
                    id: firstWeekday + day - 1,
                    date: date,
                    dayNumber: day,
                    amountText: amount.map { compactAmount($0, currencyCode: ledger.statsCurrency) } ?? "",
                    isSelected: date == selectedLedgerDate,
                    isHot: date == hottestDate && amount != nil,
                    isToday: date == todayString
                )
            )
        }
        while cells.count % 7 != 0 {
            let idx = cells.count
            cells.append(LedgerCalendarCell(
                id: idx, date: nil, dayNumber: nil, amountText: "", isSelected: false, isHot: false, isToday: false
            ))
        }
        return cells
    }

    private func calendarCellBackground(for cell: LedgerCalendarCell) -> some ShapeStyle {
        if cell.isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        IMColors.calendarSelectedTop,
                        IMColors.calendarSelectedBottom,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(Color.clear)
    }

    private func compactAmount(_ amount: Double, currencyCode: String) -> String {
        let code = BillLensFormatters.normalizedCurrencyCode(currencyCode) ?? "CNY"
        let prefix = code == "CNY" ? "¥" : "\(code) "
        if amount >= 1000 {
            return prefix + String(format: "%.1fk", amount / 1000)
        }
        return "\(prefix)\(Int(amount.rounded()))"
    }

    private func dateFrom(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return Calendar.current.date(from: components) ?? .now
    }
}

enum LedgerViewMode {
    case calendar
    case detail
}

struct LedgerCalendarCell: Identifiable {
    let id: Int
    let date: String?
    let dayNumber: Int?
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool
}

struct CalendarCellLabel: View {
    let day: Int
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 1) {
            ZStack(alignment: .top) {
                Text("\(day)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(dayTextColor)
                if isToday && !isSelected {
                    Circle()
                        .fill(IMColors.calendarToday)
                        .frame(width: 4, height: 4)
                        .offset(y: -2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text(amountText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(amountTextColor)
                .lineLimit(1)
        }
    }

    private var dayTextColor: Color {
        isSelected ? .white : IMColors.textPrimary
    }

    private var amountTextColor: Color {
        if isSelected {
            return Color.white.opacity(0.9)
        }
        if isHot {
            return IMColors.income
        }
        return IMColors.textMuted
    }
}

struct CalendarDayCellButton<Background: ShapeStyle>: View {
    let day: Int
    let date: String
    let amountText: String
    let isSelected: Bool
    let isHot: Bool
    let isToday: Bool
    let backgroundStyle: Background
    let action: () -> Void

    var body: some View {
        let cellShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        Button(action: action) {
            CalendarCellLabel(day: day, amountText: amountText, isSelected: isSelected, isHot: isHot, isToday: isToday)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(cellShape.fill(backgroundStyle))
                .overlay {
                    if isSelected {
                        cellShape
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                            .clipShape(cellShape)
                    } else if isToday {
                        cellShape.stroke(IMColors.calendarToday, lineWidth: 1.5)
                    } else {
                        cellShape.stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                }
                .contentShape(cellShape)
        }
        .buttonStyle(.plain)
    }
}

struct MonthAggregationCard: View {
    let item: LedgerShell.MonthlyAggregationItem

    private static let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    private var titleColor: Color { item.hasData ? IMColors.textPrimary : IMColors.textPlaceholder }
    private var bgColor: Color { item.hasData ? Color.white : IMColors.statBg }
    private var borderColor: Color { item.hasData ? Color.black.opacity(0.08) : Color.black.opacity(0.04) }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        cardContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(cardShape.fill(bgColor))
            .overlay(cardShape.stroke(borderColor, lineWidth: 1))
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.monthNames[item.month - 1])
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(titleColor)

            if item.hasData {
                expenseRow
                incomeRow
                Text("\(item.recordCount) 笔")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IMColors.textMuted)
            } else {
                Text("暂无")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textPlaceholder)
            }
        }
    }

    private var expenseRow: some View {
        HStack(spacing: 2) {
            Text("支")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IMColors.accent)
            Text(BillLensFormatters.currencyString(item.expenseAmount, currencyCode: item.statsCurrency))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
        }
    }

    private var incomeRow: some View {
        HStack(spacing: 2) {
            Text("收")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IMColors.income)
            Text(BillLensFormatters.currencyString(item.incomeAmount, currencyCode: item.statsCurrency))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
        }
    }
}
