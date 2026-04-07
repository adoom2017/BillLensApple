import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppPage: String {
    case entry
    case ledger

    var title: String {
        switch self {
        case .entry: "账单录入"
        case .ledger: "账单一览"
        }
    }
}

private enum LayoutMetrics {
    static let pagePadding: CGFloat = 16
    static let pageTopPadding: CGFloat = 18
    static let panelGap: CGFloat = 20
    static let panelPadding: CGFloat = 18
    static let panelRadius: CGFloat = 22
    static let fieldRadius: CGFloat = 16
    static let compactRadius: CGFloat = 14
    static let formHeight: CGFloat = 52
    static let noteHeight: CGFloat = 72
    static let inputBarHeight: CGFloat = 48
    static let iconButtonSize: CGFloat = 36
    static let actionButtonHeight: CGFloat = 40
    static let messageGap: CGFloat = 14
    static let headerSpacing: CGFloat = 14
}

public struct RootView: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var selectedPage: AppPage = .entry
    @State private var isImportingImage = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: LayoutMetrics.headerSpacing) {
                appHeader

                Group {
                    switch selectedPage {
                    case .entry:
                        EntryShell(
                            isImportingImage: $isImportingImage,
                            availableWidth: proxy.size.width - LayoutMetrics.pagePadding * 2,
                            availableHeight: max(proxy.size.height - 82, 640)
                        )
                    case .ledger:
                        LedgerShell(availableHeight: max(proxy.size.height - 82, 640))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, LayoutMetrics.pagePadding)
            .padding(.top, LayoutMetrics.pageTopPadding)
            .padding(.bottom, LayoutMetrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.985, green: 0.992, blue: 0.989),
                        Color(red: 0.958, green: 0.979, blue: 0.972),
                        Color(red: 0.946, green: 0.969, blue: 0.959),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(Color(red: 0.885, green: 0.944, blue: 0.915).opacity(0.65))
                    .frame(width: 480, height: 480)
                    .blur(radius: 30)
                    .offset(x: -440, y: -340)
                Circle()
                    .fill(Color(red: 0.907, green: 0.949, blue: 0.939).opacity(0.7))
                    .frame(width: 360, height: 360)
                    .blur(radius: 18)
                    .offset(x: 480, y: 300)
            }
            .ignoresSafeArea()
        )
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importReceipt(url: url)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText = store.errorText {
                Text(errorText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.56, green: 0.22, blue: 0.19))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                    .padding(.bottom, 18)
            }
        }
    }

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.929, green: 0.974, blue: 0.958), Color.white,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(Color(red: 0.85, green: 0.914, blue: 0.889), lineWidth: 1)
                        )
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.172, green: 0.431, blue: 0.381))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("BillLens")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.09, green: 0.20, blue: 0.23))
                    Text("账单助手")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                headerTab(.entry)
                headerTab(.ledger)
            }
            .padding(5)
            .background(.white.opacity(0.82))
            .overlay(
                Capsule()
                    .stroke(Color(red: 0.865, green: 0.914, blue: 0.893), lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(
                color: Color(red: 0.54, green: 0.69, blue: 0.64).opacity(0.08), radius: 12, y: 4)
        }
    }

    private func headerTab(_ page: AppPage) -> some View {
        Button {
            selectedPage = page
        } label: {
            Text(page.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    selectedPage == page
                        ? Color(red: 0.165, green: 0.426, blue: 0.384)
                        : Color(red: 0.42, green: 0.51, blue: 0.54)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            selectedPage == page
                                ? Color(red: 0.885, green: 0.949, blue: 0.922) : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct EntryShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat

    var body: some View {
        let rightWidth = min(max(340, availableWidth * 0.31), 360)
        let leftWidth = max(availableWidth - rightWidth - LayoutMetrics.panelGap, 0)

        HStack(alignment: .top, spacing: LayoutMetrics.panelGap) {
            ChatPanel(isImportingImage: $isImportingImage)
                .frame(width: leftWidth, height: availableHeight)

            ReviewPanel()
                .frame(width: rightWidth, height: availableHeight)
        }
        .frame(width: availableWidth, height: availableHeight, alignment: .topLeading)
    }
}

private struct ChatPanel: View {
    @EnvironmentObject private var store: BillLensStore
    @Binding var isImportingImage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("账单录入")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
                    .textCase(.uppercase)
                Text("账单录入")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(red: 0.09, green: 0.20, blue: 0.23))
                Text("输入或语音记账，如\"打车花了30块\"，我会先解析，再帮你确认入库。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                    .frame(maxWidth: 480, alignment: .leading)
            }

            ChatScrollView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ComposerPanel(
                composerText: $store.composerText,
                autoConfirm: $store.autoConfirm,
                isRecording: store.speechService.isRecording,
                statusText: store.statusText,
                onImage: { isImportingImage = true },
                onVoice: { store.toggleRecording() },
                onSubmit: { store.submitText() }
            )
        }
        .padding(LayoutMetrics.panelPadding)
        .background(PanelCardStyle())
    }
}

private struct ChatScrollView: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        GeometryReader { scrollProxy in
            ScrollViewReader { reader in
                ScrollView {
                    chatContent(width: max(scrollProxy.size.width - 10, 0))
                        .padding(.trailing, 10)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    reader.scrollTo("chatBottom")
                }
                .onChange(of: store.messages.count) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.draft?.id) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.latestRecord?.id) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
                .onChange(of: store.transientProgressMessage?.id) {
                    withAnimation { reader.scrollTo("chatBottom", anchor: .bottom) }
                }
            }
        }
    }

    private func chatContent(width: CGFloat) -> some View {
        LazyVStack(spacing: LayoutMetrics.messageGap) {
            WelcomeBubble()

            ForEach(store.messages) { message in
                MessageBubble(message: message)
            }

            if let progress = store.transientProgressMessage {
                ProgressBubble(message: progress.content)
            }

            if let draft = store.draft {
                DraftConversationCard(
                    title: draft.note ?? draft.merchant ?? "待确认账单",
                    direction: draft.direction ?? "expense",
                    amount: draft.amount,
                    category: draft.category ?? "未分类",
                    merchant: draft.merchant ?? "未填写商户",
                    transactionAt: draft.transactionAt,
                    status: "待确认",
                    copy: "已为你解析出一张待确认账单。若要修改，可以继续说\"改成300元\"，右侧表单也支持直接手动编辑。"
                )
            } else if let record = store.latestRecord {
                DraftConversationCard(
                    title: record.note ?? record.merchant ?? "最近入库账单",
                    direction: record.direction,
                    amount: record.amount,
                    category: record.category,
                    merchant: record.merchant ?? "未填写商户",
                    transactionAt: record.transactionAt,
                    status: "已入库",
                    copy: "最近确认入库的一笔账单如下。"
                )
            }

            Color.clear.frame(height: 1).id("chatBottom")
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct ReviewPanel: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("待确认记录")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
                        .textCase(.uppercase)
                    Text("核对后确认入库")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.09, green: 0.20, blue: 0.23))
                    Text("左侧继续补充会自动更新这里；你也可以直接手动修改结构化字段。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                }

                Spacer(minLength: 8)

                StatusPill(title: store.draft == nil ? "等待解析" : "待确认", warning: store.draft != nil)
            }

            ReviewSummaryCard(
                direction: store.draftForm.direction,
                amount: store.draft?.amount,
                meta: reviewSummaryMeta
            )

            if store.draft == nil {
                EmptyReviewState(latestRecord: store.latestRecord)
                Spacer(minLength: 0)
            } else {
                GeometryReader { scrollProxy in
                    ScrollView {
                        reviewFields
                            .frame(width: max(scrollProxy.size.width - 2, 0), alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                reviewActions
            }
        }
        .padding(LayoutMetrics.panelPadding)
        .background(PanelCardStyle())
    }

    private var reviewSummaryMeta: String {
        if let draft = store.draft {
            return
                "\(draft.category ?? "未分类") · \(draft.merchant ?? "未填写商户") · \(BillLensFormatters.displayDateTime(draft.transactionAt))"
        }
        return "等待新的账单解析结果"
    }

    private var reviewFields: some View {
        VStack(spacing: 8) {
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

            ReviewField(title: "分类") {
                Picker("", selection: $store.draftForm.category) {
                    ForEach(store.availableCategories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ReviewField(title: "商户") {
                TextField("例如：牛肉馆", text: $store.draftForm.merchant)
                    .textFieldStyle(.plain)
            }

            ReviewField(title: "时间") {
                DatePicker("", selection: $store.draftForm.transactionAt)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ReviewField(title: "备注", minimumHeight: LayoutMetrics.noteHeight, alignTop: true) {
                TextEditor(text: $store.draftForm.note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 44)
            }
        }
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("确认后将写入数据库，并同步出现在账单一览中。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                ActionButton(title: "删除账单", kind: .dangerGhost, minWidth: 84) {
                    store.discardDraft()
                }
                ActionButton(title: "保存修改", kind: .ghost, minWidth: 84) {
                    store.saveDraft()
                }
                ActionButton(title: "确认入库", kind: .primary, minWidth: 96) {
                    store.confirmDraft()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }
}

private struct LedgerShell: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var ledgerMode: LedgerViewMode = .calendar
    @State private var calendarMonthKey: String?
    @State private var selectedLedgerDate: String?
    @State private var cachedCalendarCells: [LedgerCalendarCell] = []
    @State private var cachedCalendarKey: String = ""
    let availableHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("账单概览")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
                    .textCase(.uppercase)
                Text("账单一览")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(red: 0.09, green: 0.20, blue: 0.23))
                Text("统一查看统计摘要，并用月历或明细方式浏览账单。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            }

            HStack(spacing: 10) {
                ForEach(LedgerPreset.allCases) { preset in
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        Text(preset.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                store.selectedPreset == preset
                                    ? Color(red: 0.165, green: 0.426, blue: 0.384)
                                    : Color(red: 0.40, green: 0.49, blue: 0.52)
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(
                                        store.selectedPreset == preset
                                            ? Color(red: 0.885, green: 0.949, blue: 0.922)
                                            : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.white.opacity(0.72))
            .overlay(
                Capsule()
                    .stroke(Color(red: 0.865, green: 0.914, blue: 0.893), lineWidth: 1)
            )
            .clipShape(Capsule())

            if store.selectedPreset == .custom {
                HStack(spacing: 10) {
                    ReviewField(title: "开始") {
                        DatePicker("", selection: $store.customStart)
                            .labelsHidden()
                    }
                    ReviewField(title: "结束") {
                        DatePicker("", selection: $store.customEnd)
                            .labelsHidden()
                    }
                    ActionButton(title: "应用", kind: .ghost) {
                        store.applyPreset(.custom)
                    }
                }
            }

            if let ledger = store.ledger {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    LedgerSummaryCard(
                        title: "总支出",
                        value: BillLensFormatters.currencyString(
                            ledger.summary.summary.expenseAmount), note: "按所选范围统计",
                        accent: .expense, primary: true)
                    LedgerSummaryCard(
                        title: "总收入",
                        value: BillLensFormatters.currencyString(
                            ledger.summary.summary.incomeAmount), note: "按所选范围统计", accent: .income,
                        primary: true)
                    LedgerSummaryCard(
                        title: "覆盖账单", value: "\(ledger.byDay.reduce(0) { $0 + $1.records.count })",
                        note: "总记录数", accent: .neutral, primary: false)
                    LedgerSummaryCard(
                        title: "待同步变更", value: "\(ledger.pendingSyncCount)",
                        note: "sync_outbox 中待同步项目", accent: .neutral, primary: false)
                }

                HStack(spacing: 8) {
                    ledgerModeButton(.calendar, title: "月历")
                    ledgerModeButton(.detail, title: "明细")
                }
                .padding(6)
                .background(.white.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(Color(red: 0.865, green: 0.914, blue: 0.893), lineWidth: 1)
                )
                .clipShape(Capsule())

                Group {
                    switch ledgerMode {
                    case .calendar:
                        calendarLedgerView(ledger)
                    case .detail:
                        detailLedgerView(ledger)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: ledgerSignature(ledger)) {
                    syncCalendarState(for: ledger)
                    rebuildCalendarCellsIfNeeded(for: ledger)
                }
                .onChange(of: calendarMonthKey) {
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
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(LayoutMetrics.panelPadding)
        .frame(maxHeight: availableHeight)
        .background(PanelCardStyle())
    }

    private func ledgerModeButton(_ mode: LedgerViewMode, title: String) -> some View {
        Button {
            ledgerMode = mode
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    ledgerMode == mode
                        ? Color(red: 0.165, green: 0.426, blue: 0.384)
                        : Color(red: 0.40, green: 0.49, blue: 0.52)
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            ledgerMode == mode
                                ? Color(red: 0.885, green: 0.949, blue: 0.922) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func calendarLedgerView(_ ledger: LedgerSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                calendarPanel(ledger)

                if let selectedGroup = selectedLedgerGroup(in: ledger) {
                    ledgerDayDetail(selectedGroup)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func calendarPanel(_ ledger: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    shiftCalendarMonth(in: ledger, direction: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .fill(Color(red: 0.969, green: 0.981, blue: 0.976))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
                )
                .disabled(!canShiftMonth(in: ledger, direction: -1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentCalendarTitle(in: ledger))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    Text(currentCalendarMeta(in: ledger))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                }

                Spacer()

                Button {
                    shiftCalendarMonth(in: ledger, direction: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .fill(Color(red: 0.969, green: 0.981, blue: 0.976))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
                )
                .disabled(!canShiftMonth(in: ledger, direction: 1))
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8
            ) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8
            ) {
                ForEach(cachedCalendarCells) { cell in
                    if let day = cell.dayNumber, let date = cell.date {
                        Button {
                            selectedLedgerDate = date
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(day)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(
                                        cell.isSelected
                                            ? .white : Color(red: 0.10, green: 0.21, blue: 0.24))
                                Text(cell.amountText)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(
                                        cell.isSelected
                                            ? Color.white.opacity(0.9)
                                            : (cell.isHot
                                                ? Color(red: 0.84, green: 0.38, blue: 0.29)
                                                : Color(red: 0.40, green: 0.49, blue: 0.52))
                                    )
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                            .background(calendarCellBackground(for: cell))
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: LayoutMetrics.fieldRadius, style: .continuous
                                )
                                .stroke(
                                    cell.isSelected
                                        ? Color(red: 0.16, green: 0.42, blue: 0.35)
                                        : Color(red: 0.89, green: 0.937, blue: 0.918),
                                    lineWidth: cell.isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(
                            cornerRadius: LayoutMetrics.fieldRadius, style: .continuous
                        )
                        .fill(Color.clear)
                        .frame(minHeight: 82)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .fill(Color.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .stroke(Color(red: 0.886, green: 0.929, blue: 0.912), lineWidth: 1)
        )
    }

    private func detailLedgerView(_ ledger: LedgerSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(ledger.byDay) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(BillLensFormatters.displayDay(day.day))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                                Text(
                                    "收入 \(BillLensFormatters.currencyString(day.incomeAmount)) · 支出 \(BillLensFormatters.currencyString(day.expenseAmount))"
                                )
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                            }
                            Spacer()
                            Text("净额 \(BillLensFormatters.currencyString(day.netAmount))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(
                                    day.netAmount >= 0
                                        ? Color(red: 0.84, green: 0.38, blue: 0.29)
                                        : Color(red: 0.16, green: 0.42, blue: 0.35))
                        }

                        ForEach(day.records) { record in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.merchant ?? record.category)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                                    Text(
                                        "\(record.category) · \(BillLensFormatters.displayDateTime(record.transactionAt))"
                                    )
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    DirectionBadge(direction: record.direction)
                                    Text(BillLensFormatters.currencyString(record.amount))
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(
                                            record.direction == "income"
                                                ? Color(red: 0.84, green: 0.38, blue: 0.29)
                                                : Color(red: 0.10, green: 0.21, blue: 0.24))
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white.opacity(0.84))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(red: 0.886, green: 0.929, blue: 0.912), lineWidth: 1)
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func ledgerDayDetail(_ day: LedgerDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("当日消费详情")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                Text(BillLensFormatters.displayDay(day.day))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            }

            ForEach(day.records) { record in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.merchant ?? record.category)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                        Text(
                            "\(record.category) · \(BillLensFormatters.displayDateTime(record.transactionAt))"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                    }
                    Spacer()
                    Text(BillLensFormatters.currencyString(record.amount))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(
                            record.direction == "income"
                                ? Color(red: 0.84, green: 0.38, blue: 0.29)
                                : Color(red: 0.10, green: 0.21, blue: 0.24))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                        .fill(Color(red: 0.977, green: 0.987, blue: 0.982))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                        .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .fill(Color.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .stroke(Color(red: 0.886, green: 0.929, blue: 0.912), lineWidth: 1)
        )
    }

    private func syncCalendarState(for ledger: LedgerSnapshot) {
        let monthKeys = availableMonthKeys(in: ledger)
        guard !monthKeys.isEmpty else {
            calendarMonthKey = nil
            selectedLedgerDate = nil
            return
        }
        if calendarMonthKey == nil || !monthKeys.contains(calendarMonthKey!) {
            calendarMonthKey = monthKeys.last
        }
        let currentGroups = groupsForSelectedMonth(in: ledger)
        let validDates = Set(currentGroups.map(\.day))
        if selectedLedgerDate == nil || !validDates.contains(selectedLedgerDate!) {
            selectedLedgerDate = currentGroups.last?.day
        }
    }

    private func ledgerSignature(_ ledger: LedgerSnapshot) -> String {
        ledger.byDay.map(\.day).joined(separator: "|")
    }

    private func availableMonthKeys(in ledger: LedgerSnapshot) -> [String] {
        Array(Set(ledger.byDay.map { String($0.day.prefix(7)) })).sorted()
    }

    private func groupsForSelectedMonth(in ledger: LedgerSnapshot) -> [LedgerDayGroup] {
        guard let key = calendarMonthKey else { return [] }
        return ledger.byDay.filter { $0.day.hasPrefix(key) }
    }

    private func currentCalendarTitle(in ledger: LedgerSnapshot) -> String {
        guard let key = calendarMonthKey else { return "账单月历" }
        let parts = key.split(separator: "-")
        guard parts.count == 2 else { return "账单月历" }
        return "\(parts[0])年\(Int(parts[1]) ?? 0)月"
    }

    private func currentCalendarMeta(in ledger: LedgerSnapshot) -> String {
        let currentGroups = groupsForSelectedMonth(in: ledger)
        return currentGroups.isEmpty ? "暂无账单" : "按天聚合 · \(currentGroups.count) 天"
    }

    private func canShiftMonth(in ledger: LedgerSnapshot, direction: Int) -> Bool {
        guard let current = calendarMonthKey else { return false }
        let keys = availableMonthKeys(in: ledger)
        guard let index = keys.firstIndex(of: current) else { return false }
        let next = index + direction
        return keys.indices.contains(next)
    }

    private func shiftCalendarMonth(in ledger: LedgerSnapshot, direction: Int) {
        let keys = availableMonthKeys(in: ledger)
        guard let current = calendarMonthKey, let index = keys.firstIndex(of: current) else {
            return
        }
        let next = index + direction
        guard keys.indices.contains(next) else { return }
        calendarMonthKey = keys[next]
        selectedLedgerDate = groupsForSelectedMonth(in: ledger).last?.day
    }

    private func selectedLedgerGroup(in ledger: LedgerSnapshot) -> LedgerDayGroup? {
        guard let selectedLedgerDate else { return nil }
        return ledger.byDay.first(where: { $0.day == selectedLedgerDate })
    }

    private func rebuildCalendarCellsIfNeeded(for ledger: LedgerSnapshot) {
        let key = (calendarMonthKey ?? "") + "|" + ledgerSignature(ledger)
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
                date: cell.date,
                dayNumber: cell.dayNumber,
                amountText: cell.amountText,
                isSelected: selected,
                isHot: cell.isHot
            )
        }
    }

    private func buildCalendarCells(for ledger: LedgerSnapshot) -> [LedgerCalendarCell] {
        let currentGroups = groupsForSelectedMonth(in: ledger)
        guard let monthKey = calendarMonthKey else { return [] }
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
            return []
        }

        let hottestDate = currentGroups.max(by: { $0.expenseAmount < $1.expenseAmount })?.day
        let groupMap = Dictionary(uniqueKeysWithValues: currentGroups.map { ($0.day, $0) })
        let firstWeekday =
            Calendar.current.component(.weekday, from: dateFrom(year: year, month: month, day: 1))
            - 1
        let daysInMonth =
            Calendar.current.range(
                of: .day, in: .month, for: dateFrom(year: year, month: month, day: 1))?.count ?? 0

        var cells = Array(repeating: LedgerCalendarCell.empty, count: firstWeekday)
        for day in 1...daysInMonth {
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let group = groupMap[date]
            let amount = group.map {
                $0.expenseAmount > 0 ? $0.expenseAmount : max($0.incomeAmount, abs($0.netAmount))
            }
            cells.append(
                LedgerCalendarCell(
                    date: date,
                    dayNumber: day,
                    amountText: amount.map(compactAmount) ?? "",
                    isSelected: date == selectedLedgerDate,
                    isHot: date == hottestDate && amount != nil
                )
            )
        }
        while cells.count % 7 != 0 {
            cells.append(.empty)
        }
        return cells
    }

    private func calendarCellBackground(for cell: LedgerCalendarCell) -> some ShapeStyle {
        if cell.isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.27, green: 0.54, blue: 0.46),
                        Color(red: 0.19, green: 0.45, blue: 0.39),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if cell.isHot {
            return AnyShapeStyle(Color(red: 0.994, green: 0.948, blue: 0.915))
        }
        return AnyShapeStyle(Color(red: 0.977, green: 0.987, blue: 0.982))
    }

    private func compactAmount(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "¥%.1fk", amount / 1000)
        }
        return "¥\(Int(amount.rounded()))"
    }

    private func dateFrom(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return Calendar.current.date(from: components) ?? .now
    }
}

private enum LedgerViewMode {
    case calendar
    case detail
}

private struct LedgerCalendarCell: Identifiable {
    let id = UUID()
    let date: String?
    let dayNumber: Int?
    let amountText: String
    let isSelected: Bool
    let isHot: Bool

    static let empty = LedgerCalendarCell(
        date: nil, dayNumber: nil, amountText: "", isSelected: false, isHot: false)
}

private struct WelcomeBubble: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 6) {
                Text("账单助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                Text("输入一句账单描述，或上传图片、语音记账，我会先生成待确认记录。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                Text("刚刚")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 0.65))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                    .stroke(Color(red: 0.90, green: 0.937, blue: 0.921), lineWidth: 1)
            )
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        if message.role == "user" {
            HStack(alignment: .bottom, spacing: 10) {
                Spacer(minLength: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 0.65))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.882, green: 0.949, blue: 0.922),
                                    Color(red: 0.836, green: 0.921, blue: 0.890),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .stroke(Color(red: 0.84, green: 0.914, blue: 0.885), lineWidth: 1)
                )
                UserAvatar()
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                AssistantAvatar()
                VStack(alignment: .leading, spacing: 6) {
                    Text("账单助手")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 0.65))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .stroke(Color(red: 0.90, green: 0.937, blue: 0.921), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProgressBubble: View {
    let message: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 6) {
                Text("账单助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    .lineSpacing(4)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("处理中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 0.65))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                    .fill(Color(red: 0.978, green: 0.988, blue: 0.983))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color(red: 0.83, green: 0.90, blue: 0.87))
            )
            .frame(maxWidth: 540, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DraftConversationCard: View {
    let title: String
    let direction: String
    let amount: Double?
    let category: String
    let merchant: String
    let transactionAt: String?
    let status: String
    let copy: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 8) {
                Text("账单助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                Text(copy)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            DirectionBadge(direction: direction)
                            Text(amount.map(BillLensFormatters.currencyString) ?? "¥0.00")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                        }
                        Spacer()
                        StatusPill(title: status, warning: status != "已入库")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                            .lineLimit(1)
                        Text(
                            "\(category) · \(merchant) · \(BillLensFormatters.displayDateTime(transactionAt))"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                        .lineLimit(1)
                    }
                }
                .padding(13)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                        .fill(Color(red: 0.973, green: 0.985, blue: 0.979))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                        .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
                )
                .frame(maxWidth: 540, alignment: .leading)

                Text("刚刚")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 0.65))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ComposerPanel: View {
    @Binding var composerText: String
    @Binding var autoConfirm: Bool
    @State private var focusToken = UUID()
    let isRecording: Bool
    let statusText: String
    let onImage: () -> Void
    let onVoice: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Toggle("解析后自动保存", isOn: $autoConfirm)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                Spacer()
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    composerEditor

                    HStack(spacing: 8) {
                        ComposerIconButton(systemImage: "photo") { onImage() }
                        ComposerIconButton(
                            systemImage: isRecording ? "stop.circle.fill" : "mic.fill",
                            tint: isRecording
                                ? Color(red: 0.82, green: 0.33, blue: 0.28)
                                : Color(red: 0.16, green: 0.42, blue: 0.35)
                        ) {
                            onVoice()
                        }
                        Button(action: onSubmit) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(
                                    width: LayoutMetrics.iconButtonSize,
                                    height: LayoutMetrics.iconButtonSize
                                )
                                .background(Color(red: 0.10, green: 0.22, blue: 0.24))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: LayoutMetrics.inputBarHeight)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                        .stroke(Color(red: 0.88, green: 0.929, blue: 0.910), lineWidth: 1)
                )
            }
        }
    }

    private var composerEditor: some View {
        ComposerInputField(
            text: $composerText,
            placeholder: "输入或语音记账，如\"打车花了30块\"…",
            focusToken: focusToken,
            onSubmit: onSubmit
        )
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
        .onAppear {
            focusToken = UUID()
        }
    }
}

private struct ComposerInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: UUID
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = NSColor(Color(red: 0.10, green: 0.21, blue: 0.24))
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerInputField
        var lastFocusToken: UUID?

        init(_ parent: ComposerInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

private struct ComposerIconButton: View {
    let systemImage: String
    var tint: Color = Color(red: 0.40, green: 0.49, blue: 0.52)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: LayoutMetrics.iconButtonSize, height: LayoutMetrics.iconButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .fill(Color(red: 0.964, green: 0.979, blue: 0.973))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutMetrics.compactRadius, style: .continuous)
                        .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewSummaryCard: View {
    let direction: String
    let amount: Double?
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前金额")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DirectionBadge(direction: direction)
                Text(amount.map(BillLensFormatters.currencyString) ?? "¥0.00")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
            }
            Text(meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.955, green: 0.984, blue: 0.972),
                            Color(red: 0.930, green: 0.968, blue: 0.952),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                .stroke(Color(red: 0.878, green: 0.929, blue: 0.908), lineWidth: 1)
        )
    }
}

private struct EmptyReviewState: View {
    let latestRecord: RecordItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("等待解析结果")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.14, green: 0.26, blue: 0.29))
            Text("左侧发送一条账单内容后，这里会显示结构化字段，可继续修改并确认入库。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            if let latestRecord {
                Text(
                    "最近入库：\(latestRecord.category) · \(BillLensFormatters.currencyString(latestRecord.amount))"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.988, green: 0.994, blue: 0.991))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color(red: 0.84, green: 0.90, blue: 0.88))
        )
    }
}

private struct ReviewField<Content: View>: View {
    let title: String
    var minimumHeight: CGFloat = LayoutMetrics.formHeight
    var alignTop = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.54))
            content
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.10, green: 0.21, blue: 0.24))
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: alignTop ? .topLeading : .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(
            maxWidth: .infinity, minHeight: minimumHeight,
            alignment: alignTop ? .topLeading : .center
        )
        .background(
            RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                .fill(Color(red: 0.974, green: 0.985, blue: 0.980))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.fieldRadius, style: .continuous)
                .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
        )
    }
}

private struct LedgerSummaryCard: View {
    enum Accent {
        case expense
        case income
        case neutral
    }

    let title: String
    let value: String
    let note: String
    let accent: Accent
    let primary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
            Text(value)
                .font(.system(size: primary ? 30 : 24, weight: .bold))
                .foregroundStyle(valueColor)
            Text(note)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.40, green: 0.49, blue: 0.52))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .fill(primary ? Color(red: 0.974, green: 0.989, blue: 0.982) : .white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                .stroke(Color(red: 0.89, green: 0.937, blue: 0.918), lineWidth: 1)
        )
    }

    private var valueColor: Color {
        switch accent {
        case .expense:
            return Color(red: 0.10, green: 0.21, blue: 0.24)
        case .income:
            return Color(red: 0.84, green: 0.38, blue: 0.29)
        case .neutral:
            return Color(red: 0.10, green: 0.21, blue: 0.24)
        }
    }
}

private struct UserAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.165, green: 0.426, blue: 0.384),
                            Color(red: 0.12, green: 0.34, blue: 0.30),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.12, green: 0.38, blue: 0.33), lineWidth: 1)
                )
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct AssistantAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.938, green: 0.978, blue: 0.962),
                            Color(red: 0.864, green: 0.928, blue: 0.903),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.85, green: 0.914, blue: 0.889), lineWidth: 1)
                )
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.165, green: 0.426, blue: 0.384))
        }
    }
}

private struct DirectionBadge: View {
    let direction: String

    var body: some View {
        Text(direction == "income" ? "收入" : "支出")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(
                direction == "income"
                    ? Color(red: 0.84, green: 0.38, blue: 0.29)
                    : Color(red: 0.16, green: 0.42, blue: 0.35)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        direction == "income"
                            ? Color(red: 0.980, green: 0.925, blue: 0.905)
                            : Color(red: 0.914, green: 0.964, blue: 0.940))
            )
    }
}

private struct StatusPill: View {
    let title: String
    let warning: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(
                warning
                    ? Color(red: 0.58, green: 0.39, blue: 0.10)
                    : Color(red: 0.16, green: 0.42, blue: 0.35)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        warning
                            ? Color(red: 1.0, green: 0.963, blue: 0.902)
                            : Color(red: 0.914, green: 0.964, blue: 0.940))
            )
    }
}

private struct ActionButton: View {
    enum Kind {
        case primary
        case ghost
        case dangerGhost
    }

    let title: String
    let kind: Kind
    var minWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(minWidth: minWidth, minHeight: LayoutMetrics.actionButtonHeight)
                .padding(.horizontal, 14)
                .background(background)
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: kind == .primary ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .ghost:
            return Color(red: 0.40, green: 0.49, blue: 0.52)
        case .dangerGhost:
            return Color(red: 0.71, green: 0.25, blue: 0.23)
        }
    }

    private var background: some View {
        Capsule()
            .fill(
                kind == .primary
                    ? Color(red: 0.10, green: 0.22, blue: 0.24)
                    : Color.clear
            )
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return .clear
        case .ghost:
            return Color(red: 0.89, green: 0.937, blue: 0.918)
        case .dangerGhost:
            return Color(red: 0.95, green: 0.84, blue: 0.82)
        }
    }
}

private struct PanelCardStyle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
            .fill(Color.white.opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: LayoutMetrics.panelRadius, style: .continuous)
                    .stroke(Color(red: 0.88, green: 0.929, blue: 0.912), lineWidth: 1)
            )
            .shadow(
                color: Color(red: 0.54, green: 0.69, blue: 0.64).opacity(0.035), radius: 10, y: 6)
    }
}
