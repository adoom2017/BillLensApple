import SwiftUI

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

    private let providers = ["openai", "anthropic"]

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
                        fieldRow(label: "Base URL", hint: "http://127.0.0.1:8080/v1") {
                            TextField("http://127.0.0.1:8080/v1", text: $baseUrl)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(IMColors.textPrimary)
                        }

                        Divider().opacity(0.25)

                        fieldRow(label: "API Key", hint: "留空则不鉴权") {
                            HStack(spacing: 6) {
                                if showApiKey {
                                    TextField("留空则不鉴权", text: $apiKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundStyle(IMColors.textPrimary)
                                } else {
                                    SecureField("留空则不鉴权", text: $apiKey)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundStyle(IMColors.textPrimary)
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

                        fieldRow(label: "模型名称", hint: "qwen-local") {
                            TextField("qwen-local", text: $model)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(IMColors.textPrimary)
                        }

                        Divider().opacity(0.25)

                        HStack(alignment: .center) {
                            Text("Provider")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(IMColors.textMuted)
                                .frame(width: 90, alignment: .leading)

                            Picker("", selection: $provider) {
                                ForEach(providers, id: \.self) { p in
                                    Text(p).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(.white.opacity(0.6))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(IMColors.headerTabBorder, lineWidth: 1))
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(IMColors.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(
            LinearGradient(
                colors: [IMColors.pageBgTop, IMColors.pageBgMid],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        baseUrl = cfg.baseUrl
        apiKey = cfg.apiKey
        model = cfg.model
        provider = cfg.provider
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
        .background(.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(IMColors.headerTabBorder, lineWidth: 1))
        .shadow(color: IMColors.headerShadow.opacity(0.06), radius: 8, y: 2)
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
