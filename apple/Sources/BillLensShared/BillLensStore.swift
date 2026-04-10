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
        public var direction = "expense"
        public var amount = ""
        public var category = "其他"
        public var merchant = ""
        public var note = ""
        public var transactionAt = Date()
    }

    @Published public var messages: [ConversationMessage] = []
    @Published public var draft: RecordDraft?
    @Published public var latestRecord: RecordItem?
    @Published public var ledger: LedgerSnapshot?
    @Published public var transientProgressMessage: TransientProgressMessage?
    @Published public var composerText = ""
    @Published public var autoConfirm = false
    @Published public var statusText = "正在初始化"
    @Published public var errorText: String?
    @Published public var isBusy = false
    @Published public var selectedPreset: LedgerPreset = .month
    @Published public var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date.now) ?? Date.now
    @Published public var customEnd = Date.now
    @Published public var draftForm = DraftFormState()

    public let speechService = SpeechCaptureService.shared

    private let bridge = RustBridge()
    private let ocrService: ReceiptTextRecognizing
    private let profileID = "local-default"
    private let deviceID = Host.current().localizedName ?? UUID().uuidString

    public init(ocrService: ReceiptTextRecognizing = ReceiptOCRService()) {
        self.ocrService = ocrService
        bootstrap()
    }

    public var availableCategories: [String] {
        draftForm.direction == "income"
            ? ["工资收入", "投资收益", "报销", "退款", "其他"]
            : ["餐饮", "交通", "日用", "购物", "住房", "医疗", "娱乐", "教育", "通讯", "人情", "订阅", "其他"]
    }

    /// 切换收支方向，并将分类重置为新方向下的第一个合法值
    public func setDraftDirection(_ direction: String) {
        draftForm.direction = direction
        let categories = availableCategories
        if !categories.contains(draftForm.category) {
            draftForm.category = categories.first ?? "其他"
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
                    "llm": self.llmConfigDictionary,
                    "log_file_path": AppLogger.defaultLogFilePath
                ])
                statusText = "已连接本地账本"
                AppLogger.log("bootstrap", "engine bootstrapped successfully")
                try await refreshHome()
                try await refreshLedger()
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
            AppLogger.log("entry.text", content)
            self.startProgress("已接收文本，准备调用大模型。")
            self.advanceProgress("正在发送文本到 LLM…")
            let result: SubmitTextResult = try await self.bridge.sendAsync([
                "action": "submit_text",
                "profile_id": self.profileID,
                "content": content,
                "auto_confirm": self.autoConfirm,
                "source": "text"
            ])
            self.advanceProgress("LLM 已返回，正在更新草稿与账本…")
            self.apply(home: result.home)
            self.statusText = result.autoConfirmed ? "已自动入库" : "已生成待确认草稿"
            AppLogger.log("entry.text.result", "auto_confirmed=\(result.autoConfirmed) parsed=\(String(describing: result.parsed))")
            try await self.refreshLedger()
            self.finishProgress()
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
                "source": "ocr"
            ])
            self.advanceProgress("大模型已返回，正在整理结构化账单…")
            self.apply(home: result.home)
            self.statusText = "图片已解析"
            AppLogger.log("entry.ocr.result", "auto_confirmed=\(result.autoConfirmed) parsed=\(String(describing: result.parsed))")
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
                    AppLogger.log("speech.transcript", "session=\(response.sessionId) text=\(response.transcript)")
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
                AppLogger.log("speech.error", error.localizedDescription)
                errorText = error.localizedDescription
                statusText = "语音识别失败"
                // Best-effort cleanup: tell Rust to drop any stale session
                let _: EmptyResponse? = try? await bridge.sendAsync([
                    "action": "stt_cancel",
                    "profile_id": profileID
                ])
            }
        }
    }

    public func saveDraft() {
        guard let draft else { return }
        perform("正在保存草稿") {
            let payload = self.currentDraftPayload()
            let result: SaveDraftResult = try await self.bridge.sendAsync([
                "action": "save_draft",
                "profile_id": self.profileID,
                "draft_id": draft.id,
                "draft": payload.dictionary
            ])
            self.apply(home: result.home)
            self.statusText = "草稿已保存"
            AppLogger.log("draft.save", "draft_id=\(draft.id)")
        }
    }

    public func confirmDraft() {
        guard let draft else { return }
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
        }
    }

    public func discardDraft() {
        guard let draft else { return }
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
        }
    }

    public func refreshLedger() async throws {
        let payload = ledgerPayload()
        let snapshot: LedgerSnapshot = try await bridge.sendAsync(payload)
        ledger = snapshot
        AppLogger.log("ledger.refresh", "preset=\(selectedPreset.rawValue) groups=\(snapshot.byDay.count) pending_sync=\(snapshot.pendingSyncCount)")
    }

    public func refreshHome() async throws {
        let snapshot: HomeSnapshot = try await bridge.sendAsync([
            "action": "home",
            "profile_id": profileID
        ])
        apply(home: snapshot)
        AppLogger.log("home.refresh", "messages=\(snapshot.messages.count) has_draft=\(snapshot.draft != nil)")
    }

    public func applyPreset(_ preset: LedgerPreset) {
        selectedPreset = preset
        perform("正在刷新账单") {
            try await self.refreshLedger()
            self.statusText = "账单视图已更新"
        }
    }

    private func apply(home: HomeSnapshot) {
        messages = home.messages
        draft = home.draft
        latestRecord = home.latestRecord
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
        guard let draft else {
            draftForm = DraftFormState()
            return
        }
        let direction = draft.direction ?? "expense"
        let categories = direction == "income"
            ? ["工资收入", "投资收益", "报销", "退款", "其他"]
            : ["餐饮", "交通", "日用", "购物", "住房", "医疗", "娱乐", "教育", "通讯", "人情", "订阅", "其他"]
        let rawCategory = draft.category ?? "其他"
        let category = categories.contains(rawCategory) ? rawCategory : categories.last!
        draftForm = DraftFormState(
            direction: direction,
            amount: draft.amount.map { String(format: "%.2f", $0) } ?? "",
            category: category,
            merchant: draft.merchant ?? "",
            note: draft.note ?? "",
            transactionAt: BillLensFormatters.parseISO(draft.transactionAt) ?? .now
        )
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

    private func currentDraftPayload() -> DraftInputPayload {
        DraftInputPayload(
            direction: draftForm.direction,
            amount: Double(draftForm.amount),
            currency: "CNY",
            category: draftForm.category,
            merchant: draftForm.merchant,
            transactionAt: BillLensFormatters.timestampFallback.string(from: draftForm.transactionAt),
            note: draftForm.note
        )
    }

    private func ledgerPayload() -> [String: Any] {
        let formatter = BillLensFormatters.timestampFallback
        var payload: [String: Any] = [
            "action": "ledger",
            "profile_id": profileID,
            "preset": selectedPreset.rawValue
        ]
        if selectedPreset == .custom {
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

    private var llmConfigDictionary: [String: String] {
        let env = ProcessInfo.processInfo.environment
        return [
            "base_url": env["LLM_BASE_URL"] ?? "http://127.0.0.1:8080/v1",
            "api_key":  env["LLM_API_KEY"]  ?? "",
            "model":    env["LLM_MODEL"]    ?? "qwen-local",
            "provider": env["LLM_PROVIDER"] ?? "llamacpp"
        ]
    }
}

private struct DraftInputPayload {
    let direction: String?
    let amount: Double?
    let currency: String?
    let category: String?
    let merchant: String?
    let transactionAt: String?
    let note: String?

    var dictionary: [String: Any] {
        [
            "direction": direction ?? NSNull(),
            "amount": amount ?? NSNull(),
            "currency": currency ?? NSNull(),
            "category": category ?? NSNull(),
            "merchant": merchant ?? NSNull(),
            "transaction_at": transactionAt ?? NSNull(),
            "note": note ?? NSNull()
        ]
    }
}
