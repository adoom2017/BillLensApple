import SwiftUI
import BillLensAppleServices
#if os(iOS)
import UIKit
#endif

private let openAICompatibleProviderID = "openai_compatible"

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
    @State private var showApiKey = false
    @State private var isSaving = false
    @State private var saveSuccess = false
    @State private var saveError: String?
    @State private var fetchedModels: [LlmModelItem] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var hasLoadedModels = false
    @ObservedObject private var localModels = LocalModelManager.shared
    @State private var localModelError: String?
    @State private var cellularDownloadModel: LocalModelDescriptor?

    #if os(iOS)
    @FocusState private var focusedField: Field?
    private enum Field { case baseUrl, apiKey, model }
    #endif

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

    private var selectedFetchedModel: LlmModelItem? {
        fetchedModels.first { $0.id == normalizedModel }
    }

    private var modelMenuTitle: String {
        if let selectedFetchedModel {
            return modelMenuLabel(for: selectedFetchedModel)
        }
        if isLoadingModels {
            return "加载中…"
        }
        if hasLoadedModels && fetchedModels.isEmpty {
            return "未返回可选模型"
        }
        return "从列表选择"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("模型与解析设置")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(IMColors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: 16) {
                    settingsCard {
                        localModeRow
                        ForEach(localModels.models) { descriptor in
                            Divider().opacity(0.25)
                            localModelRow(descriptor)
                        }
                        Divider().opacity(0.25)
                        Text("模型来源：Hugging Face 固定 revision（Apache-2.0）· 推理运行时：llama.cpp b9632（MIT）")
                            .font(.system(size: 10))
                            .foregroundStyle(IMColors.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let error = localModelError ?? localModels.lastError {
                        statusRow(
                            icon: "exclamationmark.triangle.fill",
                            color: IMColors.danger,
                            message: error
                        )
                    }

                    settingsCard {
                        providerPickerRow
                        Divider().opacity(0.25)
                        baseURLRow
                        Divider().opacity(0.25)
                        apiKeyRow
                        Divider().opacity(0.25)
                        modelFieldRow
                        Divider().opacity(0.25)
                        modelPickerRow
                    }

                    settingsCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动保存")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(IMColors.textPrimary)
                                Text("解析完成后跳过草稿直接入库")
                                    .font(.system(size: 11))
                                    .foregroundStyle(IMColors.textMuted)
                            }
                            Spacer()
                            Toggle("", isOn: $store.autoConfirm)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    if let modelLoadError {
                        statusRow(
                            icon: "exclamationmark.triangle.fill",
                            color: IMColors.danger,
                            message: modelLoadError
                        )
                    } else if hasLoadedModels {
                        statusRow(
                            icon: fetchedModels.isEmpty ? "tray" : "checkmark.circle.fill",
                            color: fetchedModels.isEmpty ? IMColors.textMuted : IMColors.accent,
                            message: fetchedModels.isEmpty
                                ? "当前接口没有返回可选模型，可直接手填模型 ID。"
                                : "已拉取 \(fetchedModels.count) 个模型，可下拉选择，也可继续手填模型 ID。"
                        )
                    }

                    if let saveError {
                        statusRow(
                            icon: "exclamationmark.triangle.fill",
                            color: IMColors.danger,
                            message: saveError
                        )
                    }

                    if saveSuccess {
                        statusRow(
                            icon: "checkmark.circle.fill",
                            color: IMColors.accent,
                            message: "配置已保存并立即生效"
                        )
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(IMColors.accentAlt)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutRadii.micro, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: LayoutRadii.micro, style: .continuous)
                                .stroke(IMColors.accentAlt, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    saveConfig()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSaving ? "保存中…" : "保存")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(IMColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutRadii.micro, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        #if os(macOS)
        .frame(width: 540)
        #else
        .presentationDetents(focusedField == nil ? [.height(520)] : [.large])
        .presentationDragIndicator(.visible)
        #endif
        .appRoundedGlass(
            cornerRadius: LayoutRadii.shell,
            prominence: .prominent,
            tint: IMColors.glassCoolTint,
            fallbackFill: IMColors.surface
        )
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

    private var localModeRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("解析模式")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                Text(localModels.mode == .localFirst ? "优先使用已选择的本地模型" : "不加载或调用本地模型")
                    .font(.system(size: 11))
                    .foregroundStyle(IMColors.textMuted)
            }
            Spacer()
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
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func localModelRow(_ descriptor: LocalModelDescriptor) -> some View {
        let download = localModels.downloads[descriptor.modelId] ?? .idle
        let installedState = localModels.installed[descriptor.modelId]
        let isInstalled = installedState != nil
        let isUpdate = isInstalled && installedState?.revision != descriptor.revision
        let isSelected = localModels.selectedModelId == descriptor.modelId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(descriptor.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColors.textPrimary)
                        #if os(iOS)
                        if descriptor.experimentalOnIPhone && UIDevice.current.userInterfaceIdiom == .phone {
                            Text("实验性")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(IMColors.danger)
                        }
                        #endif
                    }
                    Text("\(formattedBytes(descriptor.byteCount)) · \(descriptor.license) · \(descriptor.revision.prefix(8))")
                        .font(.system(size: 10))
                        .foregroundStyle(IMColors.textMuted)
                    Text("加载要求：当前可用内存至少 \(formattedBytes(Int64(descriptor.minimumAvailableMemory)))")
                        .font(.system(size: 10))
                        .foregroundStyle(IMColors.textMuted)
                    if let installedState, isUpdate {
                        Text("已安装版本 \(installedState.revision.prefix(8))，可手动更新")
                            .font(.system(size: 10))
                            .foregroundStyle(IMColors.warningText)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if isSelected {
                    Text("当前")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(IMColors.accent)
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
                    .font(.system(size: 10))
                    .foregroundStyle(IMColors.textMuted)
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
                            Button("选择") { selectLocalModel(descriptor) }
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

            if let error = download.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(IMColors.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private var providerPickerRow: some View {
        HStack(alignment: .center) {
            Text("服务商")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
                .frame(width: 90, alignment: .leading)

            Picker("", selection: Binding(
                get: { provider },
                set: { newValue in
                    provider = newValue
                    applyProviderDefaults()
                    clearModelFetchState()
                    saveSuccess = false
                    saveError = nil
                }
            )) {
                ForEach(knownProviders) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var baseURLRow: some View {
        fieldRow(label: "Base URL") {
            TextField("https://api.openai.com/v1", text: $baseUrl)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(urlIsEditable ? IMColors.textPrimary : IMColors.textMuted)
                .disabled(!urlIsEditable)
                #if os(iOS)
                .focused($focusedField, equals: .baseUrl)
                #endif
        }
    }

    @ViewBuilder private var apiKeyFieldContent: some View {
        if showApiKey {
            TextField("留空则不鉴权", text: $apiKey)
        } else {
            SecureField("留空则不鉴权", text: $apiKey)
        }
    }

    private var apiKeyRow: some View {
        fieldRow(label: "API Key") {
            HStack(spacing: 6) {
                apiKeyFieldContent
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(IMColors.textPrimary)
                    #if os(iOS)
                    .focused($focusedField, equals: .apiKey)
                    #endif
                Button {
                    showApiKey.toggle()
                } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(IMColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modelFieldRow: some View {
        fieldRow(label: "模型 ID") {
            TextField(selectedProvider.modelHint, text: $model)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(IMColors.textPrimary)
                #if os(iOS)
                .focused($focusedField, equals: .model)
                #endif
        }
    }

    private var modelPickerRow: some View {
        fieldRow(label: "模型列表") {
            HStack(spacing: 10) {
                Menu {
                    if isLoadingModels {
                        Text("加载中…")
                    } else if fetchedModels.isEmpty {
                        Text(hasLoadedModels ? "未返回可选模型" : "先获取模型列表")
                    } else {
                        ForEach(fetchedModels) { item in
                            Button {
                                model = item.id
                                saveSuccess = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(modelMenuLabel(for: item))
                                    if let subtitle = modelMenuSubtitle(for: item) {
                                        Text(subtitle)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(modelMenuTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(fetchedModels.isEmpty ? IMColors.textMuted : IMColors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IMColors.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .appRoundedGlass(
                        cornerRadius: LayoutRadii.compactField,
                        prominence: .regular,
                        interactive: true,
                        tint: IMColors.glassCoolTint.opacity(0.72),
                        fallbackFill: IMColors.surface
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button {
                    fetchModelList()
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        }
                        Text(isLoadingModels ? "拉取中…" : "获取模型列表")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(IMColors.accentAlt)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .appRoundedGlass(
                        cornerRadius: LayoutRadii.compactField,
                        prominence: .regular,
                        interactive: true,
                        tint: IMColors.accent.opacity(0.22),
                        fallbackFill: IMColors.accent.opacity(0.10)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoadingModels || isSaving)
            }
        }
    }

    private func populate(_ cfg: LlmConfigItem) {
        let matched = knownProviders.first { $0.id == cfg.provider }
        provider = matched?.id ?? openAICompatibleProviderID
        apiKey = cfg.apiKey
        model = cfg.model
        if let fixedUrl = selectedProvider.fixedUrl {
            baseUrl = fixedUrl
        } else {
            baseUrl = cfg.baseUrl
        }
        clearModelFetchState()
        saveError = nil
        saveSuccess = false
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
        saveSuccess = false

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
            provider: provider
        )
        isSaving = true
        saveError = nil
        saveSuccess = false
        Task {
            do {
                try await store.updateLlmConfig(cfg)
                saveSuccess = true
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

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .appRoundedGlass(
            cornerRadius: LayoutRadii.field,
            prominence: .regular,
            tint: IMColors.glassCoolTint.opacity(0.80),
            fallbackFill: IMColors.surface
        )
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder field: () -> Content
    ) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
                .frame(width: 90, alignment: .leading)
            field()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusRow(icon: String, color: Color, message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
