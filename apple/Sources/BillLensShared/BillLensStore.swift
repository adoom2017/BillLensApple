import Foundation
import SwiftUI
import BillLensAppleServices

@MainActor
public final class BillLensStore: ObservableObject {
    public struct TransientProgressMessage: Identifiable {
        public let id = UUID()
        public var content: String
    }

    public struct DraftFormState {
        public var direction = ""
        public var amount = ""
        public var currency = ""
        public var category = ""
        public var merchant = ""
        public var note = ""
        public var transactionAt: Date?
    }

    public struct AssetDraftFormState {
        public var name = ""
        public var category = ""
        public var amount = ""
        public var currency = ""
        public var recordedOn: Date?
        public var note = ""
    }

    @Published public var messages: [ConversationMessage] = []
    @Published public var drafts: [RecordDraft] = []
    @Published public var activeDraftIndex: Int = 0
    @Published public var latestRecord: RecordItem?
    @Published public var ledger: LedgerSnapshot?
    @Published public var transientProgressMessage: TransientProgressMessage?
    @Published public var composerText = ""
    @Published public var autoConfirm = UserDefaults.standard.bool(forKey: "autoConfirm") {
        didSet { UserDefaults.standard.set(autoConfirm, forKey: "autoConfirm") }
    }
    @Published public var statusText = "正在初始化"
    @Published public var errorText: String?
    @Published public var isBusy = false
    @Published public var selectedPreset: LedgerPreset = .month
    @Published public var selectedYear: Int = Calendar.current.component(.year, from: Date.now)
    @Published public var selectedMonth: Int = Calendar.current.component(.month, from: Date.now)
    @Published public var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date.now) ?? Date.now
    @Published public var customEnd = Date.now
    @Published public var draftForm = DraftFormState()
    @Published public var assetDraftForm = AssetDraftFormState()
    @Published public var subscriptionCycle = ""
    @Published public var subscriptions: [SubscriptionItem] = []
    @Published public var selectedSubscriptionId: String?
    @Published public private(set) var subscriptionRemindersEnabled = UserDefaults.standard.bool(
        forKey: "subscriptionRemindersEnabled"
    )
    @Published public var assets: [AssetItem] = []
    @Published public var selectedAssetId: String?
    @Published public var llmConfig: LlmConfigItem?
    @Published public var statementImport: StatementImportSession?
    /// 加密 PDF 等待用户输入密码。
    @Published public var statementPasswordRequest: StatementPasswordRequest?

    public let speechService = SpeechCaptureService.shared

    private let bridge = RustBridge()
    private let ocrService: ReceiptTextRecognizing
    private let profileID = "local-default"
    private let deviceID: String
    private var bootstrapTask: Task<Void, Error>?
    private var timeZoneObserver: NSObjectProtocol?

    public init(ocrService: ReceiptTextRecognizing = ReceiptOCRService()) {
        self.ocrService = ocrService
        let key = "BillLens_DeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) {
            self.deviceID = saved
        } else {
            let id = stableDeviceIdentifier()
            UserDefaults.standard.set(id, forKey: key)
            self.deviceID = id
        }
        bootstrap()
    }

    static var incomeCategories: [String] = ["工资收入", "投资收益", "报销", "退款", "其他"]
    static var expenseCategories: [String] = ["餐饮", "交通", "日用", "购物", "住房", "医疗", "娱乐", "教育", "通讯", "人情", "订阅", "其他"]

    public static func categories(for direction: String) -> [String] {
        switch direction {
        case "income": incomeCategories
        case "expense": expenseCategories
        default: []
        }
    }

    public var availableCategories: [String] {
        Self.categories(for: draftForm.direction)
    }

    public var currentDraft: RecordDraft? {
        guard !drafts.isEmpty, activeDraftIndex >= 0, activeDraftIndex < drafts.count else { return nil }
        return drafts[activeDraftIndex]
    }

    public var selectedSubscription: SubscriptionItem? {
        guard let id = selectedSubscriptionId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    public var selectedAsset: AssetItem? {
        guard let id = selectedAssetId else { return nil }
        return assets.first { $0.id == id }
    }

    /// 切换收支方向；不为缺失分类填入默认值。
    public func setDraftDirection(_ direction: String) {
        draftForm.direction = direction
        let categories = availableCategories
        if !categories.contains(draftForm.category) {
            draftForm.category = ""
        }
    }

    public func bootstrap() {
        guard bootstrapTask == nil else { return }
        let task = Task {
            try await bootstrapEngine()
        }
        bootstrapTask = task
        Task {
            do {
                try await task.value
            } catch {
                AppLogger.log("bootstrap.error", error.localizedDescription)
                errorText = error.localizedDescription
                statusText = "初始化失败"
            }
        }
    }

    private func bootstrapEngine() async throws {
        let dbURL = try databaseURL()
        AppLogger.log("bootstrap", "database_path=\(dbURL.path)")
        let _: [String: String] = try await bridge.sendAsync([
            "action": "bootstrap",
            "database_path": dbURL.path,
            "profile_id": profileID,
            "device_id": deviceID,
            "llm": try llmBootstrapConfig(),
            "log_file_path": AppLogger.defaultLogFilePath,
            "time_zone": TimeZone.current.identifier
        ])
        observeSystemTimeZoneChanges()
        statusText = "已连接本地账本"
        AppLogger.log("bootstrap", "engine bootstrapped successfully")
        await Self.loadCategoriesFromRust(bridge: bridge)

        async let home: Void = refreshHome()
        async let ledger: Void = refreshLedger()
        async let subs: Void = loadSubscriptions()
        async let assetsLoad: Void = loadAssets()
        _ = try await (home, ledger, subs, assetsLoad)

        _ = try await processDueSubscriptionsAfterRemoteSync(trigger: "bootstrap")
        if CloudKitSyncService.shared.isEnabledForCurrentProcess {
            CloudKitSyncService.shared.schedulePush()
        }
    }

    @discardableResult
    public func processDueSubscriptions(trigger: String) async throws -> Int {
        guard let bootstrapTask else {
            preconditionFailure("processDueSubscriptions called before bootstrap started")
        }
        try await bootstrapTask.value
        return try await processDueSubscriptionsAfterRemoteSync(trigger: trigger)
    }

    public func processDueSubscriptionsReportingErrors(trigger: String) {
        Task {
            do {
                _ = try await processDueSubscriptions(trigger: trigger)
            } catch {
                AppLogger.log("subscription.maintenance.error", "trigger=\(trigger) error=\(error.localizedDescription)")
                errorText = error.localizedDescription
                statusText = "订阅检查失败"
            }
        }
    }

    private func processDueSubscriptionsAfterRemoteSync(trigger: String) async throws -> Int {
        if CloudKitSyncService.shared.isEnabledForCurrentProcess {
            let pulled = await CloudKitSyncService.shared.pullSync(bridge: bridge, profileID: profileID)
            guard pulled else {
                let reason = CloudKitSyncService.shared.lastFailureReason ?? "未知原因"
                throw RustBridgeError.engineError("CloudKit 拉取失败（\(reason)），已停止订阅补算，避免多设备重复记账。")
            }
        }

        let result: SubscriptionChargeResult = try await bridge.sendAsync([
            "action": "process_due_subscriptions",
            "profile_id": profileID
        ])
        try await refreshLedger()
        try await loadSubscriptions()
        try await refreshSubscriptionRemindersIfEnabled()
        AppLogger.log("subscription.maintenance", "trigger=\(trigger) charged=\(result.charged)")
        if result.charged > 0, CloudKitSyncService.shared.isEnabledForCurrentProcess {
            CloudKitSyncService.shared.schedulePush()
        }
        return result.charged
    }

    public func submitText() {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        composerText = ""
        appendLocalUserMessage(content)
        perform("正在解析账单") {
            AppLogger.log("entry.text", "characters=\(content.count)")
            self.startProgress("已接收文本，正在解析…")
            let result: SubmitTextResult = try await self.bridge.sendAsync([
                "action": "submit_text",
                "profile_id": self.profileID,
                "content": content,
                "auto_confirm": self.autoConfirm,
                "source": "text",
                "local_routing": try LocalModelManager.shared.routingDictionary()
            ])
            self.advanceProgress("解析完成，正在更新草稿与账本…")
            self.apply(home: result.home)
            self.statusText = result.autoConfirmed ? "已自动入库" : "已生成待确认草稿"
            if result.parserSource == "rule" {
                self.statusText += "（规则解析）"
            } else if result.parserSource == "local" {
                self.statusText += "（本地模型）"
            } else if result.parserSource == "cloud_after_local_failure" {
                guard let localFailure = result.localFailure else {
                    throw RustBridgeError.invalidResponse
                }
                self.statusText += "（本地失败：\(localFailure.code)，已使用云端）"
                AppLogger.log(
                    "entry.local.failure",
                    "code=\(localFailure.code) message=\(localFailure.message)"
                )
            } else if result.parserSource == "cloud" {
                self.statusText += "（云端模型）"
            } else {
                throw RustBridgeError.engineError("未知解析来源：\(result.parserSource)")
            }
            if result.subscriptionCreated {
                self.statusText += "（已创建订阅）"
                try await self.loadSubscriptions()
                try await self.refreshSubscriptionRemindersIfEnabled()
            }
            if let acks = result.assetAcks, !acks.isEmpty {
                try await self.loadAssets()
            }
            AppLogger.log("entry.text.result", "route=\(result.parserSource) auto_confirmed=\(result.autoConfirmed) count=\(result.parsed.count) subscription=\(result.subscriptionCreated) asset_acks=\(result.assetAcks?.count ?? 0)")
            try await self.refreshLedger()
            self.finishProgress()
            if result.autoConfirmed || result.subscriptionCreated || !(result.assetAcks?.isEmpty ?? true) {
                CloudKitSyncService.shared.schedulePush()
            }
        }
    }

    public func importReceipt(url: URL) {
        perform("正在识别图片") {
            AppLogger.log("entry.ocr.file", url.path)
            self.startProgress("已接收图片，准备执行 OCR。")
            self.advanceProgress("正在识别票据文字…")
            let text = try await self.ocrService.recognizeText(from: url)
            self.advanceProgress("OCR 完成，正在调用大模型解析…")
            let result: SubmitTextResult = try await self.bridge.sendAsync([
                "action": "submit_text",
                "profile_id": self.profileID,
                "content": text,
                "auto_confirm": self.autoConfirm,
                "source": "ocr",
                "local_routing": try LocalModelManager.shared.routingDictionary()
            ])
            self.advanceProgress("大模型已返回，正在整理结构化账单…")
            self.apply(home: result.home)
            switch result.parserSource {
            case "local":
                self.statusText = "图片已由本地模型解析，等待确认"
            case "cloud":
                self.statusText = "图片已由云端模型解析"
            case "cloud_after_local_failure":
                guard let localFailure = result.localFailure else {
                    throw RustBridgeError.invalidResponse
                }
                self.statusText = "本地失败（\(localFailure.code)），图片已由云端模型解析"
                AppLogger.log(
                    "entry.local.failure",
                    "code=\(localFailure.code) message=\(localFailure.message)"
                )
            default:
                throw RustBridgeError.engineError("未知解析来源：\(result.parserSource)")
            }
            AppLogger.log(
                "entry.ocr.result",
                "route=\(result.parserSource) auto_confirmed=\(result.autoConfirmed) count=\(result.parsed.count)"
            )
            if result.subscriptionCreated {
                try await self.loadSubscriptions()
                try await self.refreshSubscriptionRemindersIfEnabled()
            }
            if !(result.assetAcks?.isEmpty ?? true) {
                try await self.loadAssets()
            }
            try await self.refreshLedger()
            self.finishProgress()
            if result.autoConfirmed || result.subscriptionCreated || !(result.assetAcks?.isEmpty ?? true) {
                CloudKitSyncService.shared.schedulePush()
            }
        }
    }

    public func toggleRecording() {
        Task {
            do {
                if speechService.isRecording {
                    let response: SttStopResponse = try await bridge.sendAsync([
                        "action": "stt_stop",
                        "profile_id": profileID
                    ])
                    composerText = response.transcript
                    AppLogger.log(
                        "speech.transcript",
                        "session=\(response.sessionId) characters=\(response.transcript.count)"
                    )
                    statusText = "语音已转写，可直接发送"
                } else {
                    let response: SttStartResponse = try await bridge.sendAsync([
                        "action": "stt_start",
                        "profile_id": profileID
                    ])
                    AppLogger.log("speech.start", "session=\(response.sessionId)")
                    statusText = "录音中..."
                }
            } catch {
                var visibleError = error.localizedDescription
                statusText = "语音识别失败"
                do {
                    let _: EmptyResponse = try await bridge.sendAsync([
                        "action": "stt_cancel",
                        "profile_id": profileID
                    ])
                } catch let cancelError {
                    visibleError += "；清理语音会话失败：\(cancelError.localizedDescription)"
                }
                AppLogger.log("speech.error", visibleError)
                errorText = visibleError
            }
        }
    }

    public func saveDraft() {
        guard let draft = currentDraft else { return }
        perform("正在保存草稿") {
            let draftDict = try self.currentDraftPayload()
            let result: SaveDraftResult = try await self.bridge.sendAsync([
                "action": "save_draft",
                "profile_id": self.profileID,
                "draft_id": draft.id,
                "draft": draftDict
            ])
            self.apply(home: result.home)
            self.statusText = "草稿已保存"
            AppLogger.log("draft.save", "draft_id=\(draft.id)")
        }
    }

    public func confirmDraft() {
        guard let draft = currentDraft else { return }
        perform("正在确认账单") {
            let _: SaveDraftResult = try await self.bridge.sendAsync([
                "action": "confirm_draft",
                "profile_id": self.profileID,
                "draft_id": draft.id
            ])
            try await self.refreshHome()
            try await self.refreshLedger()
            if draft.kind == "asset" {
                try await self.loadAssets()
            }
            if draft.kind == "subscription" {
                try await self.loadSubscriptions()
                try await self.refreshSubscriptionRemindersIfEnabled()
            }
            self.statusText = "账单已入库"
            AppLogger.log("draft.confirm", "draft_id=\(draft.id)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func confirmAllDrafts() {
        guard !drafts.isEmpty else { return }
        perform("正在批量确认账单") {
            let result: SaveDraftResult = try await self.bridge.sendAsync([
                "action": "confirm_all_drafts",
                "profile_id": self.profileID
            ])
            self.apply(home: result.home)
            try await self.refreshLedger()
            try await self.loadAssets()
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "已批量入库"
            AppLogger.log("draft.confirm_all", "count=\(self.drafts.count)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    // MARK: Statement import

    public func importStatement(url: URL, password: String? = nil, inboxFile: URL? = nil) {
        perform("正在解析信用卡账单") {
            // 冷启动时收件箱检查早于引擎初始化完成；先等待，避免把未就绪错误当作坏文件删除。
            try await self.bootstrapTask?.value
            let source: StatementSourcePayload
            do {
                source = try await Task.detached(priority: .userInitiated) {
                    try StatementImportService.load(from: url, password: password)
                }.value
            } catch StatementImportError.passwordRequired, StatementImportError.wrongPassword {
                self.statementPasswordRequest = StatementPasswordRequest(
                    fileURL: url,
                    inboxFile: inboxFile,
                    isRetry: password != nil
                )
                self.statusText = "等待输入 PDF 密码"
                return
            } catch {
                if let inboxFile { StatementInbox.remove(inboxFile) }
                throw error
            }
            let preview: StatementPreview
            do {
                preview = try await self.bridge.sendAsync([
                    "action": "parse_statement",
                    "profile_id": self.profileID,
                    "source": source.dictionary
                ])
            } catch {
                // 收件箱里无法解析的文件不会自行变好，删除以免每次回到前台都报错。
                if let inboxFile { StatementInbox.remove(inboxFile) }
                throw error
            }
            self.statementImport = StatementImportSession(source: source, preview: preview, inboxFile: inboxFile)
            self.statusText = "账单已解析，等待确认"
            AppLogger.log("statement.preview", "source=\(source.kind.rawValue) lines=\(preview.lines.count)")
        }
    }

    public func confirmStatementImport(selectedLineIds: [String], categoryOverrides: [String: String]) {
        guard let session = statementImport else { return }
        perform("正在导入信用卡账单") {
            let result: StatementImportResult = try await self.bridge.sendAsync([
                "action": "confirm_statement_import",
                "profile_id": self.profileID,
                "source": session.source.dictionary,
                "selected_line_ids": selectedLineIds,
                "category_overrides": categoryOverrides
            ])
            if let inboxFile = session.inboxFile { StatementInbox.remove(inboxFile) }
            self.statementImport = nil
            self.apply(home: result.home)
            try await self.refreshLedger()
            self.statusText = result.skippedExisting > 0
                ? "已导入 \(result.inserted) 笔，跳过已存在的 \(result.skippedExisting) 笔"
                : "已导入 \(result.inserted) 笔账单"
            AppLogger.log(
                "statement.confirm",
                "inserted=\(result.inserted) skipped_existing=\(result.skippedExisting)"
            )
            CloudKitSyncService.shared.schedulePush()
            // perform 结束后 isBusy 才复位，下一轮再检查收件箱。
            Task { self.checkStatementInbox() }
        }
    }

    public func cancelStatementImport() {
        if let inboxFile = statementImport?.inboxFile { StatementInbox.remove(inboxFile) }
        statementImport = nil
        checkStatementInbox()
    }

    public func cancelStatementPassword() {
        if let inboxFile = statementPasswordRequest?.inboxFile { StatementInbox.remove(inboxFile) }
        statementPasswordRequest = nil
    }

    /// 打开分享扩展放入收件箱的下一个账单；已有导入会话或密码输入时不打断。
    public func checkStatementInbox() {
        guard statementImport == nil, statementPasswordRequest == nil, !isBusy,
              let file = StatementInbox.oldestFile() else { return }
        AppLogger.log("statement.inbox", "file=\(file.pathExtension)")
        importStatement(url: file, inboxFile: file)
    }

    public func discardDraft() {
        guard let draft = currentDraft else { return }
        perform("正在丢弃草稿") {
            let home: HomeSnapshot = try await self.bridge.sendAsync([
                "action": "discard_draft",
                "profile_id": self.profileID,
                "draft_id": draft.id
            ])
            self.apply(home: home)
            self.statusText = "草稿已丢弃"
            AppLogger.log("draft.discard", "draft_id=\(draft.id)")
        }
    }

    public func selectDraft(at index: Int) {
        guard index >= 0, index < drafts.count else { return }
        activeDraftIndex = index
        hydrateDraftFields()
    }

    public func deleteRecord(_ recordId: String) {
        perform("正在删除账单") {
            let _: [String: String] = try await self.bridge.sendAsync([
                "action": "delete_record",
                "profile_id": self.profileID,
                "record_id": recordId
            ])
            try await self.refreshLedger()
            self.statusText = "账单已删除"
            AppLogger.log("record.delete", "record_id=\(recordId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    // MARK: - Manual entry
    // 表单内 await 并就地显示错误，不走 perform 的全局错误条。
    // 只有 Rust 写入失败才抛出（表单保持打开以便修改重试）；写入成功后的刷新失败
    // 报告到全局错误条并照常关闭表单，避免用户以为未保存而重复新增。

    public func createRecord(_ input: ManualRecordInput) async throws {
        let record: RecordItem = try await bridge.sendAsync([
            "action": "create_record",
            "profile_id": profileID,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        AppLogger.log("record.create", "record_id=\(record.id)")
        await finishManualWrite("账单已添加") {
            try await self.refreshAfterRecordChange()
        }
    }

    public func updateRecord(_ recordId: String, input: ManualRecordInput) async throws {
        let _: RecordItem = try await bridge.sendAsync([
            "action": "update_record",
            "profile_id": profileID,
            "record_id": recordId,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        AppLogger.log("record.update", "record_id=\(recordId)")
        await finishManualWrite("账单已更新") {
            try await self.refreshAfterRecordChange()
        }
    }

    public func createSubscription(_ input: ManualSubscriptionInput) async throws {
        let result: ManualSubscriptionResult = try await bridge.sendAsync([
            "action": "create_subscription",
            "profile_id": profileID,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        AppLogger.log("subscription.create", "id=\(result.subscription.id) charged=\(result.charged)")
        selectedSubscriptionId = result.subscription.id
        let status = result.charged > 0 ? "订阅已添加，已记录 \(result.charged) 笔扣费" : "订阅已添加"
        await finishManualWrite(status) {
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            if result.charged > 0 {
                try await self.refreshAfterRecordChange()
            }
        }
    }

    /// 新增资产与更新估值共用：同名资产合并，同日估值覆盖。
    public func saveAssetValuation(_ input: ParsedAssetInfo) async throws {
        let result: ManualAssetResult = try await bridge.sendAsync([
            "action": "create_asset",
            "profile_id": profileID,
            "input": try ManualEntryEncoding.dictionary(input)
        ])
        AppLogger.log("asset.manual", "id=\(result.assetId)")
        await finishManualWrite("资产已保存") {
            try await self.loadAssets()
            self.selectedAssetId = result.assetId
        }
    }

    /// 写入已提交：先排队同步，再刷新界面；刷新失败只报告，不让表单误判为保存失败。
    private func finishManualWrite(_ status: String, refresh: () async throws -> Void) async {
        CloudKitSyncService.shared.schedulePush()
        do {
            try await refresh()
            statusText = status
        } catch {
            AppLogger.log("manual.refresh.error", error.localizedDescription)
            errorText = "已保存，但刷新界面失败：\(error.localizedDescription)"
        }
    }

    /// 刷新账单页与首页最新记录。只更新 `latestRecord`，不重载草稿，避免冲掉记账页未保存的草稿编辑。
    private func refreshAfterRecordChange() async throws {
        try await refreshLedger()
        let snapshot: HomeSnapshot = try await bridge.sendAsync([
            "action": "home",
            "profile_id": profileID
        ])
        latestRecord = snapshot.latestRecord
    }

    // MARK: - Subscription Management

    public func loadSubscriptions() async throws {
        let response: SubscriptionListResponse = try await bridge.sendAsync([
            "action": "list_subscriptions",
            "profile_id": profileID
        ])
        subscriptions = response.subscriptions
        AppLogger.log("subscriptions.load", "count=\(response.subscriptions.count)")
    }

    public func loadSubscriptionsReportingErrors() {
        Task {
            do {
                try await loadSubscriptions()
                try await refreshSubscriptionRemindersIfEnabled()
            } catch {
                AppLogger.log("subscriptions.load.error", error.localizedDescription)
                errorText = error.localizedDescription
                statusText = "订阅加载失败"
            }
        }
    }

    public func setSubscriptionRemindersEnabled(_ enabled: Bool) {
        perform(enabled ? "正在开启订阅提醒" : "正在关闭订阅提醒") {
            if enabled {
                try await SubscriptionNotificationService.shared.requestAuthorization()
                self.subscriptionRemindersEnabled = true
                UserDefaults.standard.set(true, forKey: "subscriptionRemindersEnabled")
                try await self.refreshSubscriptionRemindersIfEnabled()
                self.statusText = "订阅提醒已开启"
            } else {
                await SubscriptionNotificationService.shared.removeAllPendingReminders()
                self.subscriptionRemindersEnabled = false
                UserDefaults.standard.set(false, forKey: "subscriptionRemindersEnabled")
                self.statusText = "订阅提醒已关闭"
            }
        }
    }

    private func refreshSubscriptionRemindersIfEnabled() async throws {
        guard subscriptionRemindersEnabled else { return }
        try await SubscriptionNotificationService.shared.replacePendingReminders(with: subscriptions)
        AppLogger.log(
            "subscription.notifications",
            "scheduled=\(subscriptions.filter(\.isActive).count)"
        )
    }

    private static func loadCategoriesFromRust(bridge: RustBridge) async {
        do {
            let response: CategoriesResponse = try await bridge.sendAsync([
                "action": "list_categories"
            ])
            Self.expenseCategories = response.expense
            Self.incomeCategories = response.income
        } catch {
            AppLogger.log("categories.load.error", error.localizedDescription)
        }
    }

    public func pauseSubscription(_ subscriptionId: String) {
        perform("正在暂停订阅") {
            let _: SubscriptionItem = try await self.bridge.sendAsync([
                "action": "pause_subscription",
                "profile_id": self.profileID,
                "subscription_id": subscriptionId
            ])
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "订阅已暂停"
            AppLogger.log("subscription.pause", "id=\(subscriptionId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func resumeSubscription(_ subscriptionId: String) {
        perform("正在恢复订阅") {
            let _: SubscriptionItem = try await self.bridge.sendAsync([
                "action": "resume_subscription",
                "profile_id": self.profileID,
                "subscription_id": subscriptionId
            ])
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "订阅已恢复"
            AppLogger.log("subscription.resume", "id=\(subscriptionId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func deleteSubscription(_ subscriptionId: String) {
        perform("正在删除订阅") {
            let _: [String: String] = try await self.bridge.sendAsync([
                "action": "delete_subscription",
                "profile_id": self.profileID,
                "subscription_id": subscriptionId
            ])
            if self.selectedSubscriptionId == subscriptionId {
                self.selectedSubscriptionId = nil
            }
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "订阅已删除"
            AppLogger.log("subscription.delete", "id=\(subscriptionId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func updateSubscription(_ subscriptionId: String, update: SubscriptionUpdateInput) {
        perform("正在更新订阅") {
            let updateDict = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(update)
            ) as? [String: Any] ?? [:]
            let _: SubscriptionItem = try await self.bridge.sendAsync([
                "action": "update_subscription",
                "profile_id": self.profileID,
                "subscription_id": subscriptionId,
                "update": updateDict
            ])
            try await self.loadSubscriptions()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "订阅已更新"
            AppLogger.log("subscription.update", "id=\(subscriptionId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    // MARK: - Asset Management

    public func loadAssets() async throws {
        let response: AssetListResponse = try await bridge.sendAsync([
            "action": "list_assets",
            "profile_id": profileID
        ])
        assets = response.assets
        AppLogger.log("assets.load", "count=\(response.assets.count)")
    }

    public func updateAsset(_ assetId: String, update: AssetUpdateInput) {
        perform("正在更新资产") {
            let updateDict = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(update)
            ) as? [String: Any] ?? [:]
            let _: AssetItem = try await self.bridge.sendAsync([
                "action": "update_asset",
                "profile_id": self.profileID,
                "asset_id": assetId,
                "update": updateDict
            ])
            try await self.loadAssets()
            // If the asset was merged into another (no longer exists), clear the selection.
            if !self.assets.contains(where: { $0.id == assetId }) {
                self.selectedAssetId = nil
                self.statusText = "资产已合并"
            } else {
                self.statusText = "资产已更新"
            }
            AppLogger.log("asset.update", "id=\(assetId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func deleteAsset(_ assetId: String) {
        perform("正在删除资产") {
            let _: [String: String] = try await self.bridge.sendAsync([
                "action": "delete_asset",
                "profile_id": self.profileID,
                "asset_id": assetId
            ])
            if self.selectedAssetId == assetId {
                self.selectedAssetId = nil
            }
            try await self.loadAssets()
            self.statusText = "资产已删除"
            AppLogger.log("asset.delete", "id=\(assetId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    public func deleteAssetSnapshot(_ snapshotId: String) {
        perform("正在删除快照") {
            let _: [String: String] = try await self.bridge.sendAsync([
                "action": "delete_asset_snapshot",
                "profile_id": self.profileID,
                "snapshot_id": snapshotId
            ])
            try await self.loadAssets()
            self.statusText = "快照已删除"
            AppLogger.log("asset_snapshot.delete", "id=\(snapshotId)")
            CloudKitSyncService.shared.schedulePush()
        }
    }

    // ── LLM config ──────────────────────────────────────────────────────

    public func loadLlmConfig() async throws {
        let cfg: LlmConfigItem? = try await bridge.sendAsync(["action": "get_llm_config"])
        llmConfig = cfg
    }

    public func updateLlmConfig(_ cfg: LlmConfigItem) async throws {
        var payload: [String: Any] = [
            "action": "update_llm_config",
            "base_url": cfg.baseUrl,
            "api_key": cfg.apiKey,
            "model": cfg.model,
            "provider": cfg.provider
        ]
        if let enableThinking = cfg.enableThinking {
            payload["enable_thinking"] = enableThinking
        }
        let _: [String: String] = try await bridge.sendAsync(payload)
        llmConfig = cfg
        let thinkingMode = cfg.enableThinking.map(String.init) ?? "provider_default"
        AppLogger.log(
            "llm_config.update",
            "model=\(cfg.model) provider=\(cfg.provider) enable_thinking=\(thinkingMode)"
        )
    }

    public func listLlmModels(
        baseUrl: String,
        apiKey: String,
        provider: String
    ) async throws -> [LlmModelItem] {
        let models: [LlmModelItem] = try await bridge.sendAsync([
            "action": "list_llm_models",
            "base_url": baseUrl,
            "api_key": apiKey,
            "provider": provider
        ])
        AppLogger.log("llm_models.list", "provider=\(provider) count=\(models.count)")
        return models
    }

    public func refreshLedger() async throws {
        let payload = ledgerPayload()
        let snapshot: LedgerSnapshot = try await bridge.sendAsync(payload)
        ledger = snapshot
        AppLogger.log(
            "ledger.refresh",
            "preset=\(selectedPreset.rawValue) groups=\(snapshot.byDay.count) pending_sync=\(snapshot.pendingSyncCount) stats_currency=\(snapshot.statsCurrency) fx_warning=\(snapshot.fxWarning ?? "")"
        )
    }

    public func refreshHome() async throws {
        let snapshot: HomeSnapshot = try await bridge.sendAsync([
            "action": "home",
            "profile_id": profileID
        ])
        apply(home: snapshot)
        AppLogger.log("home.refresh", "messages=\(snapshot.messages.count) drafts=\(snapshot.drafts.count)")
    }

    public func applyPreset(_ preset: LedgerPreset) {
        selectedPreset = preset
        if preset == .month {
            selectedYear = Calendar.current.component(.year, from: Date.now)
            selectedMonth = Calendar.current.component(.month, from: Date.now)
        } else if preset == .year {
            selectedYear = Calendar.current.component(.year, from: Date.now)
        }
        perform("正在刷新账单") {
            try await self.refreshLedger()
            self.statusText = "账单视图已更新"
        }
    }

    public func shiftLedgerMonth(by delta: Int) {
        var newMonth = selectedMonth + delta
        var newYear = selectedYear
        if newMonth < 1 { newMonth = 12; newYear -= 1 }
        if newMonth > 12 { newMonth = 1; newYear += 1 }
        selectedMonth = newMonth
        selectedYear = newYear
        perform("正在刷新账单") {
            try await self.refreshLedger()
            self.statusText = "账单视图已更新"
        }
    }

    public func shiftLedgerYear(by delta: Int) {
        selectedYear += delta
        perform("正在刷新账单") {
            try await self.refreshLedger()
            self.statusText = "账单视图已更新"
        }
    }

    private func apply(home: HomeSnapshot) {
        let previousCount = drafts.count
        messages = home.messages
        drafts = home.drafts
        latestRecord = home.latestRecord
        if drafts.count > previousCount {
            // New drafts were appended (ordered by created_at ASC, rowid ASC).
            // Jump to the first of the new batch so the review form is bound to
            // the just-parsed bill rather than an older one.
            activeDraftIndex = previousCount
        } else if activeDraftIndex >= drafts.count {
            activeDraftIndex = max(0, drafts.count - 1)
        }
        hydrateDraftFields()
    }

    private func appendLocalUserMessage(_ content: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        let local = ConversationMessage(
            id: "local-\(UUID().uuidString)",
            profileId: profileID,
            role: "user",
            content: content,
            draftId: nil,
            recordId: nil,
            createdAt: now
        )
        messages.append(local)
    }

    private func hydrateDraftFields() {
        guard let draft = currentDraft else {
            draftForm = DraftFormState()
            assetDraftForm = AssetDraftFormState()
            subscriptionCycle = ""
            return
        }
        if draft.kind == "asset" {
            guard let asset = draft.assetInfo else {
                errorText = "资产草稿缺少 asset_info。"
                assetDraftForm = AssetDraftFormState()
                return
            }
            assetDraftForm = AssetDraftFormState(
                name: asset.name,
                category: asset.category ?? "",
                amount: String(format: "%.2f", asset.amount),
                currency: asset.currency ?? "",
                recordedOn: asset.recordedOn.flatMap(BillLensFormatters.parseDate),
                note: asset.note ?? ""
            )
            if asset.recordedOn != nil, assetDraftForm.recordedOn == nil {
                errorText = "资产草稿的 recorded_on 格式无效。"
            }
            return
        }
        let direction = draft.direction ?? ""
        draftForm = DraftFormState(
            direction: direction,
            amount: draft.amount.map { String(format: "%.2f", $0) } ?? "",
            currency: draft.currency ?? "",
            category: draft.category ?? "",
            merchant: draft.merchant ?? "",
            note: draft.note ?? "",
            transactionAt: BillLensFormatters.parseISO(draft.transactionAt)
        )
        if draft.transactionAt != nil, draftForm.transactionAt == nil {
            errorText = "草稿的 transaction_at 格式无效。"
        }
        subscriptionCycle = draft.subscriptionCycle ?? ""
    }

    /// 账本按天分组、月/年范围和订阅扣费日都由 Rust 按设备时区计算；系统时区变化（如出行）时同步给引擎。
    private func observeSystemTimeZoneChanges() {
        precondition(timeZoneObserver == nil, "时区监听只能注册一次")
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applySystemTimeZone()
            }
        }
    }

    private func applySystemTimeZone() {
        NSTimeZone.resetSystemTimeZone()
        let identifier = TimeZone.current.identifier
        perform("时区已变为 \(identifier)，正在刷新账本") {
            let _: [String: String] = try await self.bridge.sendAsync([
                "action": "set_time_zone",
                "time_zone": identifier
            ])
            AppLogger.log("timezone.changed", identifier)
            try await self.refreshLedger()
            try await self.refreshSubscriptionRemindersIfEnabled()
            self.statusText = "已按时区 \(identifier) 刷新账本"
        }
    }

    private func perform(_ status: String, operation: @MainActor @escaping () async throws -> Void) {
        errorText = nil
        isBusy = true
        statusText = status
        Task {
            do {
                try await operation()
            } catch {
                AppLogger.log("operation.error", error.localizedDescription)
                errorText = error.localizedDescription
                statusText = "操作失败"
                finishProgress()
            }
            isBusy = false
        }
    }

    private func startProgress(_ text: String) {
        transientProgressMessage = TransientProgressMessage(content: "处理中：\(text)")
    }

    private func advanceProgress(_ text: String) {
        if transientProgressMessage == nil {
            startProgress(text)
            return
        }
        transientProgressMessage?.content.append("\n• \(text)")
    }

    private func finishProgress() {
        transientProgressMessage = nil
    }

    private func currentDraftPayload() throws -> [String: Any] {
        guard let currentDraft else {
            throw RustBridgeError.engineError("没有可保存的草稿。")
        }
        if currentDraft.kind == "asset" {
            let name = assetDraftForm.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw RustBridgeError.engineError("资产名称不能为空。")
            }
            guard let amount = Double(assetDraftForm.amount), amount.isFinite, amount > 0 else {
                throw RustBridgeError.engineError("资产金额必须是大于 0 的有限数字。")
            }
            guard !assetDraftForm.category.isEmpty else {
                throw RustBridgeError.engineError("资产分类不能为空。")
            }
            guard let currency = BillLensFormatters.normalizedCurrencyCode(assetDraftForm.currency) else {
                throw RustBridgeError.engineError("资产币种必须是有效的 ISO 4217 代码。")
            }
            guard let recordedOn = assetDraftForm.recordedOn else {
                throw RustBridgeError.engineError("资产记录日期不能为空。")
            }
            let asset = ParsedAssetInfo(
                name: name,
                category: assetDraftForm.category,
                amount: amount,
                currency: currency,
                recordedOn: BillLensFormatters.dateOnly.string(from: recordedOn),
                note: assetDraftForm.note
            )
            let input = DraftInput(
                direction: nil,
                amount: nil,
                currency: nil,
                category: nil,
                merchant: nil,
                transactionAt: nil,
                note: nil,
                assetInfo: asset
            )
            let data = try JSONEncoder().encode(input)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RustBridgeError.invalidResponse
            }
            return object
        }
        guard draftForm.direction == "expense" || draftForm.direction == "income" else {
            throw RustBridgeError.engineError("账单收支类型不能为空。")
        }
        guard let amount = Double(draftForm.amount), amount.isFinite, amount > 0 else {
            throw RustBridgeError.engineError("账单金额必须是大于 0 的有限数字。")
        }
        guard let currency = BillLensFormatters.normalizedCurrencyCode(draftForm.currency) else {
            throw RustBridgeError.engineError("账单币种必须是有效的 ISO 4217 代码。")
        }
        guard !draftForm.category.isEmpty else {
            throw RustBridgeError.engineError("账单分类不能为空。")
        }
        guard let transactionAt = draftForm.transactionAt else {
            throw RustBridgeError.engineError("账单时间不能为空。")
        }
        if currentDraft.kind == "subscription",
           subscriptionCycle != "monthly" && subscriptionCycle != "yearly" {
            throw RustBridgeError.engineError("订阅周期不能为空。")
        }
        let input = DraftInput(
            direction: draftForm.direction,
            amount: amount,
            currency: currency,
            category: draftForm.category,
            merchant: draftForm.merchant,
            transactionAt: BillLensFormatters.timestampFallback.string(from: transactionAt),
            note: draftForm.note,
            subscriptionCycle: currentDraft.kind == "subscription" ? subscriptionCycle : nil
        )
        let data = try JSONEncoder().encode(input)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RustBridgeError.invalidResponse
        }
        return object
    }

    private func ledgerPayload() -> [String: Any] {
        let formatter = BillLensFormatters.timestampFallback
        var payload: [String: Any] = [
            "action": "ledger",
            "profile_id": profileID,
            "preset": "custom"
        ]

        switch selectedPreset {
        case .month:
            let startComps = DateComponents(year: selectedYear, month: selectedMonth, day: 1)
            let start = Calendar.current.date(from: startComps) ?? Date.now
            var endComps = DateComponents(year: selectedYear, month: selectedMonth + 1, day: 1)
            if selectedMonth == 12 {
                endComps = DateComponents(year: selectedYear + 1, month: 1, day: 1)
            }
            let endDate = Calendar.current.date(from: endComps) ?? Date.now
            let end = Calendar.current.date(byAdding: .second, value: -1, to: endDate) ?? endDate
            payload["start_at"] = formatter.string(from: start)
            payload["end_at"] = formatter.string(from: end)
        case .year:
            let startComps = DateComponents(year: selectedYear, month: 1, day: 1)
            let start = Calendar.current.date(from: startComps) ?? Date.now
            let endComps = DateComponents(year: selectedYear + 1, month: 1, day: 1)
            let endDate = Calendar.current.date(from: endComps) ?? Date.now
            let end = Calendar.current.date(byAdding: .second, value: -1, to: endDate) ?? endDate
            payload["start_at"] = formatter.string(from: start)
            payload["end_at"] = formatter.string(from: end)
        case .custom:
            payload["start_at"] = formatter.string(from: customStart)
            payload["end_at"] = formatter.string(from: customEnd)
        }

        return payload
    }

    private func databaseURL() throws -> URL {
        let supportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportURL.appendingPathComponent("BillLensApple", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("billlens.sqlite")
    }

    private func llmBootstrapConfig() throws -> Any {
        let env = ProcessInfo.processInfo.environment
        let keys = ["LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL", "LLM_PROVIDER"]
        let present = keys.filter { env[$0] != nil }
        if present.isEmpty { return NSNull() }
        guard let baseURL = env["LLM_BASE_URL"],
              let model = env["LLM_MODEL"],
              let provider = env["LLM_PROVIDER"] else {
            throw RustBridgeError.engineError("云端模型环境变量配置不完整。")
        }
        return [
            "base_url": baseURL,
            "api_key": env["LLM_API_KEY"] ?? "",
            "model": model,
            "provider": provider
        ]
    }
}
