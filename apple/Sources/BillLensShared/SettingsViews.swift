import SwiftUI
import BillLensAppleServices
#if os(iOS)
import UIKit
#endif

private let openAICompatibleProviderID = "openai_compatible"

private enum CloudThinkingMode: String, CaseIterable, Identifiable {
    case providerDefault = "provider_default"
    case disabled
    case enabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault: "服务商默认"
        case .disabled: "关闭（结构化解析推荐）"
        case .enabled: "开启"
        }
    }

    var requestValue: Bool? {
        switch self {
        case .providerDefault: nil
        case .disabled: false
        case .enabled: true
        }
    }

    init(requestValue: Bool?) {
        switch requestValue {
        case nil: self = .providerDefault
        case false: self = .disabled
        case true: self = .enabled
        }
    }
}

// MARK: - Provider definitions

private struct ProviderOption: Identifiable {
    let id: String
    let displayName: String
    let fixedUrl: String?
    let modelHint: String
}

private let knownProviders: [ProviderOption] = [
    ProviderOption(id: "openai",             displayName: "OpenAI",          fixedUrl: "https://api.openai.com/v1",                         modelHint: "gpt-4o"),
    ProviderOption(id: "anthropic",          displayName: "Anthropic",       fixedUrl: "https://api.anthropic.com/v1",                      modelHint: "claude-sonnet-4-6"),
    ProviderOption(id: "deepseek",           displayName: "DeepSeek",        fixedUrl: "https://api.deepseek.com/v1",                       modelHint: "deepseek-chat"),
    ProviderOption(id: "moonshot",           displayName: "月之暗面 (Kimi)", fixedUrl: "https://api.moonshot.cn/v1",                        modelHint: "moonshot-v1-8k"),
    ProviderOption(id: "zhipu",              displayName: "智谱 (GLM)",      fixedUrl: "https://open.bigmodel.cn/api/paas/v4",              modelHint: "glm-4-flash"),
    ProviderOption(id: "qwen",               displayName: "通义千问",         fixedUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", modelHint: "qwen-plus"),
    ProviderOption(id: "groq",               displayName: "Groq",            fixedUrl: "https://api.groq.com/openai/v1",                    modelHint: "llama-3.3-70b-versatile"),
    ProviderOption(id: "xai",                displayName: "xAI",             fixedUrl: "https://api.x.ai/v1",                               modelHint: "grok-3-mini"),
    ProviderOption(id: "siliconflow",        displayName: "SiliconFlow",     fixedUrl: "https://api.siliconflow.com/v1",                    modelHint: "Qwen/Qwen3-32B"),
    ProviderOption(id: "volcengine_ark",     displayName: "火山方舟",         fixedUrl: "https://ark.cn-beijing.volces.com/api/v3",          modelHint: "doubao-1-5-pro-32k"),
    ProviderOption(id: openAICompatibleProviderID, displayName: "OpenAI 兼容", fixedUrl: nil,                                                modelHint: "model-name"),
]

// MARK: - Settings Sheet

struct SettingsShell: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var provider = "openai"
    @State private var cloudThinkingMode: CloudThinkingMode = .providerDefault
    @State private var showApiKey = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var fetchedModels: [LlmModelItem] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var hasLoadedModels = false
    @ObservedObject private var localModels = LocalModelManager.shared
    @State private var localModelError: String?
    @State private var cellularDownloadModel: LocalModelDescriptor?

    private var selectedProvider: ProviderOption {
        knownProviders.first { $0.id == provider } ?? knownProviders.last!
    }

    private var urlIsEditable: Bool {
        selectedProvider.fixedUrl == nil
    }

    private var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedBaseUrl: String {
        baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                localModelSection
                cloudModelSection
                MailboxSettingsSection()

                Section {
                    Toggle(isOn: $store.autoConfirm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动入库")
                            Text("解析完成后跳过草稿审核直接入库")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("记账")
                }

                if let saveError {
                    Section {
                        statusLabel(saveError, systemImage: "exclamationmark.triangle.fill", color: AppColors.destructive)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("保存") { saveConfig() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 620, idealHeight: 720)
        #endif
        .task {
            do {
                if store.llmConfig == nil {
                    try await store.loadLlmConfig()
                }
                if let cfg = store.llmConfig {
                    populate(cfg)
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
        .alert("允许蜂窝网络下载？", isPresented: Binding(
            get: { cellularDownloadModel != nil },
            set: { if !$0 { cellularDownloadModel = nil } }
        )) {
            Button("取消", role: .cancel) {
                cellularDownloadModel = nil
            }
            Button("仅本次允许") {
                guard let descriptor = cellularDownloadModel else { return }
                cellularDownloadModel = nil
                startLocalDownload(descriptor, allowCellular: true)
            }
        } message: {
            Text("本次将下载 \(formattedBytes(cellularDownloadModel?.byteCount ?? 0))。授权只对当前下载任务有效。")
        }
    }

    // MARK: Local model

    private var localModelSection: some View {
        Section {
            Picker("解析模式", selection: Binding(
                get: { localModels.mode },
                set: { mode in
                    do {
                        try localModels.setMode(mode)
                        localModelError = nil
                    } catch {
                        localModelError = error.localizedDescription
                    }
                }
            )) {
                Text("本地优先").tag(LocalModelMode.localFirst)
                Text("仅云端").tag(LocalModelMode.cloudOnly)
            }
            .pickerStyle(.segmented)

            ForEach(localModels.models) { descriptor in
                localModelRow(descriptor)
            }

            if let error = localModelError ?? localModels.lastError {
                statusLabel(error, systemImage: "exclamationmark.triangle.fill", color: AppColors.destructive)
            }
        } header: {
            Text("本地模型")
        } footer: {
            Text(
                (localModels.mode == .localFirst ? "优先使用已选择的本地模型，失败时交给云端。" : "不加载或调用本地模型。")
                    + "\n模型来源：Hugging Face 固定 revision（Apache-2.0）· 推理运行时：llama.cpp b9632（MIT）"
            )
        }
    }

    private func localModelRow(_ descriptor: LocalModelDescriptor) -> some View {
        let download = localModels.downloads[descriptor.modelId] ?? .idle
        let installedState = localModels.installed[descriptor.modelId]
        let isInstalled = installedState != nil
        let isUpdate = isInstalled && installedState?.revision != descriptor.revision
        let isSelected = localModels.selectedModelId == descriptor.modelId
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(descriptor.displayName)
                            .font(.body.weight(.medium))
                        #if os(iOS)
                        if descriptor.experimentalOnIPhone && UIDevice.current.userInterfaceIdiom == .phone {
                            StatusTag(title: "实验性", color: .orange)
                        }
                        #endif
                    }
                    Text("\(formattedBytes(descriptor.byteCount)) · \(descriptor.license) · \(descriptor.revision.prefix(8))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("需要可用内存 \(formattedBytes(Int64(descriptor.minimumAvailableMemory)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let installedState, isUpdate {
                        Text("已安装 \(installedState.revision.prefix(8))，可更新")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("当前模型")
                }
            }

            if download.phase.isActive {
                if download.phase == .waitingForWiFi {
                    ProgressView()
                        .accessibilityLabel("等待 Wi-Fi 或非低数据模式网络")
                } else {
                    ProgressView(
                        value: Double(download.receivedBytes),
                        total: Double(max(download.expectedBytes, descriptor.byteCount))
                    )
                    .accessibilityLabel("模型下载进度")
                    .accessibilityValue(
                        "已下载 \(formattedBytes(download.receivedBytes))，共 \(formattedBytes(max(download.expectedBytes, descriptor.byteCount)))"
                    )
                }
                Text(downloadStatusText(download))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if download.phase.isActive {
                    Button("取消下载") {
                        Task {
                            do {
                                try await localModels.cancelDownload(modelId: descriptor.modelId)
                                localModelError = nil
                            } catch {
                                localModelError = error.localizedDescription
                            }
                        }
                    }
                } else {
                    if isInstalled {
                        if !isSelected {
                            Button("使用") { selectLocalModel(descriptor) }
                        }
                        Button("删除", role: .destructive) { deleteLocalModel(descriptor) }
                    }
                    if !isInstalled || isUpdate {
                        #if os(iOS)
                        Button(isUpdate ? "Wi-Fi 更新" : "Wi-Fi 下载") {
                            startLocalDownload(descriptor, allowCellular: false)
                        }
                        Button(isUpdate ? "蜂窝更新" : "使用蜂窝") {
                            cellularDownloadModel = descriptor
                        }
                        #else
                        Button(isUpdate ? "更新" : "下载") {
                            startLocalDownload(descriptor, allowCellular: false)
                        }
                        #endif
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let error = download.visibleError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppColors.destructive)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(descriptor.displayName)
    }

    private func downloadStatusText(_ download: LocalModelDownloadState) -> String {
        switch download.phase {
        case .waitingForWiFi:
            "等待 Wi-Fi；低数据模式下不会下载。"
        case .downloading:
            "已下载 \(formattedBytes(download.receivedBytes))"
        case .verifying:
            "正在校验 SHA-256…"
        case .idle, .installed, .failed:
            preconditionFailure("非活动下载状态不应生成进度文案：\(download.phase.rawValue)")
        }
    }

    private func startLocalDownload(_ descriptor: LocalModelDescriptor, allowCellular: Bool) {
        do {
            try localModels.startDownload(
                modelId: descriptor.modelId,
                allowCellularOnce: allowCellular
            )
            localModelError = nil
        } catch {
            localModelError = error.localizedDescription
        }
    }

    private func selectLocalModel(_ descriptor: LocalModelDescriptor) {
        Task {
            do {
                try localModels.selectModel(descriptor.modelId)
                localModelError = nil
            } catch {
                localModelError = error.localizedDescription
            }
        }
    }

    private func deleteLocalModel(_ descriptor: LocalModelDescriptor) {
        Task {
            do {
                try localModels.deleteModel(modelId: descriptor.modelId)
                localModelError = nil
            } catch {
                localModelError = error.localizedDescription
            }
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    // MARK: Cloud model

    private var cloudModelSection: some View {
        Section {
            Picker("服务商", selection: Binding(
                get: { provider },
                set: { newValue in
                    provider = newValue
                    applyProviderDefaults()
                    clearModelFetchState()
                    saveError = nil
                }
            )) {
                ForEach(knownProviders) { item in
                    Text(item.displayName).tag(item.id)
                }
            }

            LabeledContent("Base URL") {
                TextField("Base URL", text: $baseUrl, prompt: Text("https://api.openai.com/v1"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(urlIsEditable ? .primary : .secondary)
                    .disabled(!urlIsEditable)
                    .urlFieldTraits()
            }

            LabeledContent("API Key") {
                HStack(spacing: 6) {
                    Group {
                        if showApiKey {
                            TextField("API Key", text: $apiKey, prompt: Text("留空则不鉴权"))
                        } else {
                            SecureField("API Key", text: $apiKey, prompt: Text("留空则不鉴权"))
                        }
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .urlFieldTraits()
                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(showApiKey ? "隐藏 API Key" : "显示 API Key")
                }
            }

            LabeledContent("模型 ID") {
                TextField("模型 ID", text: $model, prompt: Text(selectedProvider.modelHint))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .urlFieldTraits()
            }

            LabeledContent("可用模型") {
                HStack(spacing: 8) {
                    if !fetchedModels.isEmpty {
                        Menu {
                            ForEach(fetchedModels) { item in
                                Button {
                                    model = item.id
                                } label: {
                                    if let subtitle = modelMenuSubtitle(for: item) {
                                        Text(modelMenuLabel(for: item))
                                        Text(subtitle)
                                    } else {
                                        Text(modelMenuLabel(for: item))
                                    }
                                }
                            }
                        } label: {
                            Text("选择…")
                        }
                        .fixedSize()
                    }
                    Button {
                        fetchModelList()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(hasLoadedModels ? "重新获取" : "获取列表")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoadingModels || isSaving)
                }
            }

            Picker("思考模式", selection: $cloudThinkingMode) {
                ForEach(CloudThinkingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityLabel("云端模型思考模式")
        } header: {
            Text("云端模型")
        } footer: {
            if let modelLoadError {
                statusLabel(modelLoadError, systemImage: "exclamationmark.triangle.fill", color: AppColors.destructive)
            } else if hasLoadedModels {
                Text(fetchedModels.isEmpty
                    ? "接口没有返回可选模型，可直接填写模型 ID。"
                    : "已获取 \(fetchedModels.count) 个模型，可从列表选择或直接填写模型 ID。")
            } else {
                Text("配置只保存在本机，不会通过 iCloud 同步。")
            }
        }
    }

    private func populate(_ cfg: LlmConfigItem) {
        let matched = knownProviders.first { $0.id == cfg.provider }
        provider = matched?.id ?? openAICompatibleProviderID
        apiKey = cfg.apiKey
        model = cfg.model
        cloudThinkingMode = CloudThinkingMode(requestValue: cfg.enableThinking)
        if let fixedUrl = selectedProvider.fixedUrl {
            baseUrl = fixedUrl
        } else {
            baseUrl = cfg.baseUrl
        }
        clearModelFetchState()
        saveError = nil
    }

    private func applyProviderDefaults() {
        if let fixedUrl = selectedProvider.fixedUrl {
            baseUrl = fixedUrl
        } else {
            baseUrl = ""
        }
    }

    private func clearModelFetchState() {
        fetchedModels = []
        isLoadingModels = false
        modelLoadError = nil
        hasLoadedModels = false
    }

    private func fetchModelList() {
        guard !isLoadingModels else { return }
        guard !normalizedBaseUrl.isEmpty else {
            modelLoadError = "Base URL 不能为空。"
            hasLoadedModels = false
            fetchedModels = []
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        Task {
            defer { isLoadingModels = false }
            do {
                let models = try await store.listLlmModels(
                    baseUrl: normalizedBaseUrl,
                    apiKey: apiKey,
                    provider: provider
                )
                fetchedModels = models
                hasLoadedModels = true
            } catch {
                fetchedModels = []
                hasLoadedModels = false
                modelLoadError = error.localizedDescription
            }
        }
    }

    private func saveConfig() {
        let cfg = LlmConfigItem(
            baseUrl: normalizedBaseUrl,
            apiKey: apiKey,
            model: normalizedModel,
            provider: provider,
            enableThinking: cloudThinkingMode.requestValue
        )
        isSaving = true
        saveError = nil
        Task {
            do {
                try await store.updateLlmConfig(cfg)
                isSaving = false
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func modelMenuLabel(for item: LlmModelItem) -> String {
        item.displayName ?? item.id
    }

    private func modelMenuSubtitle(for item: LlmModelItem) -> String? {
        if let displayName = item.displayName, displayName != item.id {
            return item.id
        }
        return item.ownedBy
    }

    private func statusLabel(_ message: String, systemImage: String, color: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
    }
}

private extension View {
    /// URL / Key / 模型 ID 字段不做自动大写和纠错。
    func urlFieldTraits() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
