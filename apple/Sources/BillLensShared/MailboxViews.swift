import SwiftUI
import UserNotifications
import BillLensAppleServices

/// 邮箱同步结果通知。只在用户已授权通知时发送，不主动申请权限。
enum MailboxNotifier {
    static func notify(imported: Int, newPending: Int) async {
        guard imported > 0 || newPending > 0 else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "信用卡账单已同步"
        var parts: [String] = []
        if imported > 0 { parts.append("已自动记账 \(imported) 笔") }
        if newPending > 0 { parts.append("\(newPending) 封账单有条目待确认") }
        content.body = parts.joined(separator: "，")
        let request = UNNotificationRequest(identifier: "mailbox.sync.\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLogger.log("mailbox.notify.error", error.localizedDescription)
        }
    }
}

/// 设置页「邮箱账单」分区。
struct MailboxSettingsSection: View {
    @EnvironmentObject private var store: BillLensStore
    @State private var errorText: String?
    @State private var confirmDisconnect = false
    @State private var showICloudSheet = false
    @State private var icloudSheetAddress = ""

    var body: some View {
        Section {
            if let connected {
                LabeledContent(connected.provider.title, value: connected.address)
                if store.mailboxNeedsReauth {
                    Label(
                        connected.provider == .icloud
                            ? "iCloud 邮箱登录失败，App 专用密码可能已被撤销，请重新连接。"
                            : "邮箱授权已失效，请重新连接。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(AppColors.warning)
                    if connected.provider == .icloud {
                        icloudButton(title: "重新连接", address: connected.address)
                    } else {
                        hotmailButton(title: "重新连接")
                    }
                }
                if let state = store.mailboxStatus?.state {
                    LabeledContent("上次检查", value: BillLensFormatters.displayDateTime(state.lastSyncedAt))
                    if let summary = store.mailboxLastSyncSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mailbox.lastSyncSummary")
                    }
                    if let lastError = state.lastError {
                        Label(lastError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let pending = store.mailboxStatus?.pending, !pending.isEmpty {
                    LabeledContent("待确认账单", value: "\(pending.count) 封")
                }
                Button {
                    Task { await store.syncMailbox(trigger: "manual", force: true) }
                } label: {
                    HStack {
                        Text(store.isMailboxBusy ? (store.mailboxSyncProgress?.text ?? "正在检查…") : "立即检查")
                        if store.isMailboxBusy {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(store.isMailboxBusy || store.mailboxNeedsReauth)
                Button("断开连接", role: .destructive) { confirmDisconnect = true }
                    .disabled(store.isMailboxBusy)
            } else {
                icloudButton(title: "连接 iCloud 邮箱", address: "")
                if store.isMailboxConfigured {
                    hotmailButton(title: "连接 Hotmail")
                }
            }
            Stepper(value: $store.mailboxLookbackMonths, in: BillLensStore.mailboxLookbackMonthsRange) {
                LabeledContent("同步范围", value: "最近 \(store.mailboxLookbackMonths) 个月")
            }
            .accessibilityIdentifier("mailbox.lookbackMonths")
            // sheet 挂在始终存在的行上：List 中挂在 Section 上的修饰符会分摊到各行，弹出不可靠；
            // 挂在连接按钮上则连接成功后按钮所在行被替换，sheet 会在同步途中被强行收起。
            .sheet(isPresented: $showICloudSheet) {
                ICloudMailConnectSheet(initialAddress: icloudSheetAddress)
                    .environmentObject(store)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
            }
        } header: {
            Text("邮箱账单")
        } footer: {
            Text("只读取收件箱里的招商银行信用卡账单邮件，不改动任何邮件。正常交易自动记账，疑似重复或合计对不上的留待确认。调大同步范围会补查更早的账单，已记过的不会重复。授权与密码仅保存在本机钥匙串。")
        }
        .task { await store.loadMailboxStatus() }
        .confirmationDialog("断开邮箱？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                Task {
                    do {
                        try await store.disconnectMailbox()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("将删除本机保存的授权和同步记录，已记账的账单不受影响。")
        }
    }

    private var connected: (provider: MailboxProvider, address: String)? {
        if let address = ICloudMailCredentialStore.shared.connectedAddress { return (.icloud, address) }
        if let address = MicrosoftAuthService.shared.connectedAddress { return (.hotmail, address) }
        // Hotmail 刷新令牌失效时钥匙串已删除；仍显示原邮箱与「重新连接」，而不是回到未连接状态。
        if store.mailboxNeedsReauth, let address = store.mailboxStatus?.state?.accountAddress {
            return (.hotmail, address)
        }
        return nil
    }

    private func icloudButton(title: String, address: String) -> some View {
        Button {
            errorText = nil
            icloudSheetAddress = address
            showICloudSheet = true
        } label: {
            Label(title, systemImage: "icloud")
        }
        .disabled(store.isMailboxBusy)
    }

    private func hotmailButton(title: String) -> some View {
        Button {
            errorText = nil
            Task {
                do {
                    try await store.connectMailbox()
                } catch MicrosoftAuthError.cancelled {
                    // 用户取消，不提示。
                } catch {
                    errorText = error.localizedDescription
                }
            }
        } label: {
            HStack {
                Label(title, systemImage: "envelope.badge")
                if store.isMailboxBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(store.isMailboxBusy)
    }
}

/// iCloud 邮箱连接表单：邮箱地址 + App 专用密码，校验登录成功后保存。
struct ICloudMailConnectSheet: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var password = ""
    @State private var errorText: String?

    init(initialAddress: String) {
        _address = State(initialValue: initialAddress)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("iCloud 邮箱地址", text: $address, prompt: Text("name@icloud.com"))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("icloud.address")
                    SecureField("App 专用密码", text: $password, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
                        .textContentType(.password)
                        .accessibilityIdentifier("icloud.password")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("请使用 App 专用密码，不是 Apple 账户密码：在 account.apple.com →「登录与安全」→「App 专用密码」中生成。地址填账单的收件邮箱（@icloud.com / @me.com）。")
                        Link("如何生成 App 专用密码", destination: URL(string: "https://support.apple.com/zh-cn/102654")!)
                    }
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.destructive)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("连接 iCloud 邮箱")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isMailboxBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("连接") { connect() }
                            .disabled(!canConnect)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var canConnect: Bool {
        address.contains("@") && password.filter { !$0.isWhitespace }.count >= 16
    }

    private func connect() {
        errorText = nil
        Task {
            do {
                try await store.connectICloudMailbox(address: address, appPassword: password)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// 记账页顶部：有待确认的邮箱账单时显示。
struct PendingMailStatementsBanner: View {
    @EnvironmentObject private var store: BillLensStore

    var body: some View {
        if let first = store.mailboxStatus?.pending.first {
            let count = store.mailboxStatus?.pending.count ?? 0
            Button {
                store.openPendingMailStatement(first.messageId)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(AppColors.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count > 1 ? "\(count) 封信用卡账单待确认" : "信用卡账单待确认")
                            .font(.callout.weight(.semibold))
                        Text("\(first.periodLabel ?? "邮箱账单") · \(first.pendingCount) 笔待确认")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .floatingGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityHint("打开账单预览确认剩余条目")
        }
    }
}
