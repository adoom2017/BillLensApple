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
    @Published public var assets: [AssetItem] = []
    @Published public var selectedAssetId: String?
    @Published public var llmConfig: LlmConfigItem?

    public let speechService = SpeechCaptureService.shared

    private let bridge = RustBridge()
    private let ocrService: ReceiptTextRecognizing
    private let profileID = "local-default"
    private let deviceID: String

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
        Task {
            do {
                let dbURL = try databaseURL()
                AppLogger.log("bootstrap", "database_path=\(dbURL.path)")
                let _: [String: String] = try await bridge.sendAsync([
                    "action": "bootstrap",
                    "database_path": dbURL.path,
                    "profile_id": profileID,
                    "device_id": deviceID,
                    "llm": try self.llmBootstrapConfig(),
                    "log_file_path": AppLogger.defaultLogFilePath
                ])
                statusText = "已连接本地账本"
                AppLogger.log("bootstrap", "engine bootstrapped successfully")
                await Self.loadCategoriesFromRust(bridge: bridge)
                async let pullOK = CloudKitSyncService.shared.pullSync(bridge: bridge, profileID: profileID)
                async let home: Void = refreshHome()
                async let ledger: Void = refreshLedger()
                async let subs: Void = loadSubscriptions()
                async let assetsLoad: Void = loadAssets()
                _ = try await (home, ledger, subs, assetsLoad)

                // Pull must succeed before charging to avoid double-charges on multi-device setups.
                if await pullOK {
                    let _: [String: Int] = try await bridge.sendAsync([
                        "action": "process_due_subscriptions",
                        "profile_id": profileID
                    ])
                    try await refreshLedger()
                    try await loadSubscriptions()
                }
                CloudKitSyncService.shared.schedulePush()
            } catch {
                AppLogger.log("bootstrap.error", error.localizedDescription)
                errorText = error.localizedDescription
                statusText = "初始化失败"
            }
        }
    }

    public func submitText() {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        composerText = ""
        appendLocalUserMessage(content)
        perform("正在解析账单") {
            AppLogger.log("entry.text", "characters=\(content.count)")
            self.startProgress("已接收文本，准备调用大模型。")
            self.advanceProgress("正在发送文本到 LLM…")
            let result: SubmitTextResult = try await self.bridge.sendAsync([
                "action": "submit_text",
                "profile_id": self.profileID,
                "content": content,
                "auto_confirm": self.autoConfirm,
                "source": "text",
                "local_routing": try LocalModelManager.shared.routingDictionary()
            ])
            self.advanceProgress("LLM 已返回，正在更新草稿与账本…")
            self.apply(home: result.home)
            self.statusText = result.autoConfirmed ? "已自动入库" : "已生成待确认草稿"
            if result.parserSource == "local" {
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
            }
            if let acks = result.assetAcks, !acks.isEmpty {
                try await self.loadAssets()
            }
            AppLogger.log("entry.text.result", "route=\(result.parserSource) auto_confirmed=\(result.autoConfirmed) count=\(result.parsed.count) subscription=\(result.subscriptionCreated) asset_acks=\(result.assetAcks?.count ?? 0)")
            try await self.refreshLedger()
            self.finishProgress()
            if result.autoConfirmed { CloudKitSyncService.shared.schedulePush() }
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
            try await self.refreshLedger()
            self.finishProgress()
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
            self.statusText = "已批量入库"
            AppLogger.log("draft.confirm_all", "count=\(self.drafts.count)")
            CloudKitSyncService.shared.schedulePush()
        }
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

    // MARK: - Subscription Management

    public func loadSubscriptions() async throws {
        let response: SubscriptionListResponse = try await bridge.sendAsync([
            "action": "list_subscriptions",
            "profile_id": profileID
        ])
        subscriptions = response.subscriptions
        AppLogger.log("subscriptions.load", "count=\(response.subscriptions.count)")
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
        let _: [String: String] = try await bridge.sendAsync([
            "action": "update_llm_config",
            "base_url": cfg.baseUrl,
            "api_key": cfg.apiKey,
            "model": cfg.model,
            "provider": cfg.provider
        ])
        llmConfig = cfg
        AppLogger.log("llm_config.update", "model=\(cfg.model) provider=\(cfg.provider)")
        CloudKitSyncService.shared.schedulePush()
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
