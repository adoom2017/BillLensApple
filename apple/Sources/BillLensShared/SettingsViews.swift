import SwiftUI

// MARK: - Provider definitions

private struct ProviderOption: Identifiable {
    let id: String
    let displayName: String
    let fixedUrl: String?
    let modelHint: String
}

private let knownProviders: [ProviderOption] = [
    ProviderOption(id: "openai",             displayName: "OpenAI",          fixedUrl: "https://api.openai.com/v1",                              modelHint: "gpt-4o"),
    ProviderOption(id: "anthropic",          displayName: "Anthropic",       fixedUrl: "https://api.anthropic.com/v1",                           modelHint: "claude-sonnet-4-6"),
    ProviderOption(id: "deepseek",           displayName: "DeepSeek",        fixedUrl: "https://api.deepseek.com/v1",                            modelHint: "deepseek-chat"),
    ProviderOption(id: "moonshot",           displayName: "月之暗面 (Kimi)", fixedUrl: "https://api.moonshot.cn/v1",                             modelHint: "moonshot-v1-8k"),
    ProviderOption(id: "zhipu",             displayName: "智谱 (GLM)",      fixedUrl: "https://open.bigmodel.cn/api/paas/v4",                   modelHint: "glm-4-flash"),
    ProviderOption(id: "qwen",              displayName: "通义千问",         fixedUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",      modelHint: "qwen-plus"),
    ProviderOption(id: "openai_compatible", displayName: "OpenAI 兼容",     fixedUrl: nil,                                                      modelHint: ""),
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
    #if os(iOS)
    @FocusState private var focusedField: Field?
    private enum Field { case baseUrl, apiKey, model }
    #endif

    private var selectedProvider: ProviderOption {
        knownProviders.first { $0.id == provider } ?? knownProviders.last!
    }

    private var urlIsEditable: Bool { selectedProvider.fixedUrl == nil }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
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
                        // Provider picker
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
                                }
                            )) {
                                ForEach(knownProviders) { p in
                                    Text(p.displayName).tag(p.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider().opacity(0.25)

                        // Base URL (locked for official providers)
                        fieldRow(label: "Base URL", hint: "https://api.openai.com/v1") {
                            TextField("", text: $baseUrl)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(urlIsEditable ? IMColors.textPrimary : IMColors.textMuted)
                                .disabled(!urlIsEditable)
                                #if os(iOS)
                                .focused($focusedField, equals: .baseUrl)
                                #endif
                        }

                        Divider().opacity(0.25)

                        fieldRow(label: "API Key", hint: "留空则不鉴权") {
                            HStack(spacing: 6) {
                                if showApiKey {
                                    TextField("留空则不鉴权", text: $apiKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundStyle(IMColors.textPrimary)
                                        #if os(iOS)
                                        .focused($focusedField, equals: .apiKey)
                                        #endif
                                } else {
                                    SecureField("留空则不鉴权", text: $apiKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundStyle(IMColors.textPrimary)
                                        #if os(iOS)
                                        .focused($focusedField, equals: .apiKey)
                                        #endif
                                }
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

                        Divider().opacity(0.25)

                        fieldRow(label: "模型名称", hint: selectedProvider.modelHint.isEmpty ? "model-name" : selectedProvider.modelHint) {
                            TextField(selectedProvider.modelHint.isEmpty ? "model-name" : selectedProvider.modelHint, text: $model)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(IMColors.textPrimary)
                                #if os(iOS)
                                .focused($focusedField, equals: .model)
                                #endif
                        }
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

                    if let errMsg = saveError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(IMColors.danger)
                            Text(errMsg)
                                .font(.system(size: 12))
                                .foregroundStyle(IMColors.danger)
                        }
                        .padding(.horizontal, 4)
                    }

                    if saveSuccess {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(IMColors.accent)
                            Text("配置已保存并立即生效")
                                .font(.system(size: 12))
                                .foregroundStyle(IMColors.accent)
                        }
                        .padding(.horizontal, 4)
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
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(IMColors.accentAlt, lineWidth: 1))
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
        .frame(width: 460)
        #else
        .presentationDetents(focusedField == nil ? [.height(420)] : [.large])
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

    private func populate(_ cfg: LlmConfigItem) {
        // Match saved provider id; fall back to openai_compatible if unknown
        let matched = knownProviders.first { $0.id == cfg.provider }
        provider = matched?.id ?? "openai_compatible"
        apiKey = cfg.apiKey
        model = cfg.model
        // For official providers, always show the fixed URL
        if let fixedUrl = selectedProvider.fixedUrl {
            baseUrl = fixedUrl
        } else {
            baseUrl = cfg.baseUrl
        }
    }

    private func applyProviderDefaults() {
        if let fixedUrl = selectedProvider.fixedUrl {
            baseUrl = fixedUrl
        } else {
            baseUrl = ""
        }
    }

    private func saveConfig() {
        let cfg = LlmConfigItem(
            baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
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

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(IMColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(IMColors.divider, lineWidth: 1))
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        hint: String,
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
}
