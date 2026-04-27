import SwiftUI

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
                Text("LLM 连接配置")
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
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(IMColors.pageBgTop)
        .task {
            if store.llmConfig == nil {
                try? await store.loadLlmConfig()
            }
            if let cfg = store.llmConfig {
                populate(cfg)
            }
        }
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
                    .background(IMColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(IMColors.divider, lineWidth: 1)
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
                    .background(IMColors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                try? await Task.sleep(nanoseconds: 800_000_000)
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
        .background(IMColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IMColors.divider, lineWidth: 1)
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
