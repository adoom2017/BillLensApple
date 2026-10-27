import SwiftUI

// MARK: - Conversation

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            Text(message.content)
                .textSelection(.enabled)
                .bubbleSurface(isUser: isUser)
            Text(BillLensFormatters.displayDateTime(message.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(isUser ? .leading : .trailing, 56)
    }
}

struct SpeechLiveBubble: View {
    let transcript: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(transcript.isEmpty ? "正在聆听…" : transcript)
        }
        .bubbleSurface(isUser: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .accessibilityLabel(transcript.isEmpty ? "正在聆听" : "录音中：\(transcript)")
    }
}

struct ProgressBubble: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private extension View {
    func bubbleSurface(isUser: Bool) -> some View {
        self
            .font(.body)
            .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}

struct DraftConversationCard: View {
    let draft: RecordDraft
    let title: String
    let isActive: Bool
    let onReview: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let category = draft.category ?? "未分类"
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                CategoryIcon(
                    systemImage: CategoryStyle.icon(for: category),
                    color: CategoryStyle.color(for: category),
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(category) · \(draft.merchant ?? "未填写商户")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AmountText(
                    amount: draft.amount,
                    currency: draft.currency,
                    direction: draft.direction ?? "expense"
                )
                .font(.title3.weight(.semibold))
            }

            HStack(spacing: 8) {
                StatusTag(title: "待确认", color: .orange)
                Text(BillLensFormatters.displayDateTime(draft.transactionAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("审核", action: onReview)
                    .buttonStyle(.bordered)
                Button("确认", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isActive ? 2 : 1)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Composer

struct ComposerPanel: View {
    @Binding var composerText: String
    @FocusState private var isInputFocused: Bool
    let isRecording: Bool
    let onImage: () -> Void
    let onStatement: () -> Void
    let onVoice: () -> Void
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button(action: onImage) {
                    Label("账单图片", systemImage: "photo.on.rectangle")
                }
                Button(action: onStatement) {
                    Label("信用卡电子账单", systemImage: "creditcard")
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("导入账单图片或信用卡电子账单")
            .accessibilityLabel("导入")

            HStack(spacing: 6) {
                TextField("打车花了 30 块…", text: $composerText)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit(onSubmit)
                    #if os(iOS)
                    .submitLabel(.send)
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onVoice) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic")
                        .font(.body.weight(.medium))
                        .foregroundStyle(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help(isRecording ? "停止录音" : "语音输入")
                .accessibilityLabel(isRecording ? "停止录音" : "语音输入")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
            .background {
                // 点击胶囊空白处聚焦输入框；手势放在背景层，不拦截输入框自身的点击。
                Capsule()
                    .fill(.fill.tertiary)
                    .onTapGesture { isInputFocused = true }
            }

            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.multicolor)
            }
            .buttonStyle(.borderless)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .floatingGlass(in: Capsule())
        #if os(macOS)
        .onAppear { isInputFocused = true }
        #endif
    }
}

// MARK: - Rows & labels

struct RecordRowView: View {
    let record: RecordItem

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(
                systemImage: CategoryStyle.icon(for: record.category),
                color: CategoryStyle.color(for: record.category)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(record.merchant ?? record.category)
                    .font(.body)
                    .lineLimit(1)
                Text("\(record.category) · \(BillLensFormatters.displayDateTime(record.transactionAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountText(amount: record.amount, currency: record.currency, direction: record.direction)
                .font(.body.weight(.medium))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 收入带 + 号并显示绿色，支出用主文字色。
struct AmountText: View {
    let amount: Double?
    let currency: String?
    let direction: String

    var body: some View {
        let isIncome = direction == "income"
        let value = amount.map { BillLensFormatters.currencyString($0, currencyCode: currency) } ?? "—"
        Text(isIncome && amount != nil ? "+\(value)" : value)
            .monospacedDigit()
            .foregroundStyle(isIncome ? AnyShapeStyle(AppColors.income) : AnyShapeStyle(.primary))
            .lineLimit(1)
    }
}

struct StatusTag: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct DirectionTag: View {
    let direction: String

    var body: some View {
        StatusTag(
            title: direction == "income" ? "收入" : "支出",
            color: direction == "income" ? AppColors.income : .secondary
        )
    }
}

struct SummaryStat: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 详情页顶部：大图标 + 标题 + 大金额。
struct DetailHeader<Tags: View>: View {
    let icon: String
    let color: Color
    let title: String
    let amount: String?
    let caption: String?
    @ViewBuilder let tags: Tags

    var body: some View {
        VStack(spacing: 10) {
            CategoryIcon(systemImage: icon, color: color, size: 60)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 6) { tags }
            if let amount {
                Text(amount)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
