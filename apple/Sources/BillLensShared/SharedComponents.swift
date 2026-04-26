#if os(macOS)
import AppKit
#endif
import SwiftUI

struct WelcomeBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text("账单助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColors.textSecondary)
                Text("输入一句账单描述，或上传图片、语音记账，我会先生成待确认记录。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                Text("刚刚")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                    .fill(IMColors.botBubble)
            )
            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                        .fill(IMColors.userBubble)
                )
                UserAvatar()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 8) {
                AssistantAvatar()
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                    Text(BillLensFormatters.displayDateTime(message.createdAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                        .fill(IMColors.botBubble)
                )
                Spacer(minLength: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SpeechLiveBubble: View {
    let transcript: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if transcript.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在聆听...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(IMColors.textTertiary)
                    }
                } else {
                    Text(transcript)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IMColors.textPrimary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("录音中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IMColors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                    .fill(IMColors.userBubble)
            )
            UserAvatar()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ProgressBubble: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(IMColors.systemMsgBg)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct DraftConversationCard: View {
    struct Actions {
        let review: () -> Void
        let confirm: () -> Void
    }

    let title: String
    let direction: String
    let amount: Double?
    let currency: String?
    let category: String
    let merchant: String
    let transactionAt: String?
    let status: String
    let copy: String
    let actions: Actions?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 8) {
                Text(copy)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IMColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                            .fill(IMColors.botBubble)
                    )

                draftCardContent
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous)
                            .fill(IMColors.botBubble)
                    )
                    .frame(maxWidth: 520, alignment: .leading)

                Text("刚刚")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IMColors.textTertiary)
            }
            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var draftCardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DirectionBadge(direction: direction)
                    Text(
                        amount.map { BillLensFormatters.currencyString($0, currencyCode: currency) }
                            ?? "¥0.00"
                    )
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(IMColors.textPrimary)
                }
                Spacer()
                StatusPill(title: status, warning: status != "已入库")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IMColors.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(category) · \(merchant) · \(BillLensFormatters.displayDateTime(transactionAt))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .lineLimit(1)
            }

            if let actions {
                HStack(spacing: 8) {
                    ActionButton(title: "审核", kind: .ghost, minWidth: 56) {
                        actions.review()
                    }
                    ActionButton(title: "确认", kind: .primary, minWidth: 56) {
                        actions.confirm()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }
}

struct ComposerPanel: View {
    @Binding var composerText: String
    @State private var focusToken = UUID()
    let isRecording: Bool
    let onImage: () -> Void
    let onVoice: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IMColors.divider.frame(height: 1)


            HStack(spacing: 8) {
                ComposerIconButton(systemImage: "photo") { onImage() }

                composerEditor
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(IMColors.surfaceStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(IMColors.divider, lineWidth: 1)
                    )

                ComposerIconButton(
                    systemImage: isRecording ? "stop.circle.fill" : "mic.fill",
                    tint: isRecording ? Color.red : IMColors.textSecondary
                ) {
                    onVoice()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(IMColors.chatBg)
    }

    private var composerEditor: some View {
        ComposerInputField(
            text: $composerText,
            placeholder: "输入账单，如\"打车花了30块\"…",
            focusToken: focusToken,
            onSubmit: onSubmit
        )
        .onAppear {
            focusToken = UUID()
        }
    }
}

#if os(macOS)
struct ComposerInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: UUID
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = NSColor(IMColors.textPrimary)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerInputField
        var lastFocusToken: UUID?

        init(_ parent: ComposerInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
#else
struct ComposerInputField: View {
    @Binding var text: String
    let placeholder: String
    let focusToken: UUID
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool
    @State private var lastFocusToken: UUID?

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(IMColors.textPrimary)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { onSubmit() }
            .onChange(of: focusToken) { _, newToken in
                if lastFocusToken != newToken {
                    lastFocusToken = newToken
                    isFocused = true
                }
            }
    }
}
#endif

struct ComposerIconButton: View {
    let systemImage: String
    var tint: Color = IMColors.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(IMColors.surfaceStrong)
                        .overlay(Circle().stroke(IMColors.divider, lineWidth: 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ReviewSummaryCard: View {
    let direction: String
    let amount: Double?
    let currency: String?
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DirectionBadge(direction: direction)
                Text(
                    amount.map { BillLensFormatters.currencyString($0, currencyCode: currency) }
                        ?? "¥0.00"
                )
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(IMColors.textPrimary)
            }
            Text(meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }
}

struct EmptyReviewState: View {
    let latestRecord: RecordItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("等待解析结果")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IMColors.textPrimary)
            Text("左侧输入账单内容并按 Enter 后，这里会显示可编辑的结构化字段。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
            if let latestRecord {
                Text(
                    "最近入库：\(latestRecord.category) · \(BillLensFormatters.currencyString(latestRecord.amount, currencyCode: latestRecord.currency))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewField<Content: View>: View {
    let title: String
    var minimumHeight: CGFloat = 44
    var alignTop = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColors.textSecondary)
            content
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IMColors.textPrimary)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: alignTop ? .topLeading : .leading)
        }
        .padding(.vertical, 8)
        .frame(
            maxWidth: .infinity, minHeight: minimumHeight,
            alignment: alignTop ? .topLeading : .center
        )
        .overlay(alignment: .bottom) {
            IMColors.divider.frame(height: 1).opacity(0.5)
        }
    }
}

struct RecordRowView: View {
    let record: RecordItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.merchant ?? record.category)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IMColors.textPrimary)
                Text(
                    "\(record.category) · \(BillLensFormatters.displayDateTime(record.transactionAt))"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColors.textSecondary)
            }
            Spacer()
            Text(BillLensFormatters.currencyString(record.amount, currencyCode: record.currency))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(IMColors.textPrimary)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColors.dangerSubtle)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(IMColors.dangerBgLight)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct LedgerSummaryCard: View {
    enum Accent {
        case expense
        case income
        case neutral
    }

    let title: String
    let value: String
    let accent: Accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IMColors.textMuted)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueColor: Color {
        switch accent {
        case .expense:
            return IMColors.textPrimary
        case .income:
            return IMColors.income
        case .neutral:
            return IMColors.textPrimary
        }
    }
}

struct UserAvatar: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(IMColors.accent)
                .frame(width: LayoutMetrics.avatarSize, height: LayoutMetrics.avatarSize)
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct AssistantAvatar: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(IMColors.accentDark)
                .frame(width: LayoutMetrics.avatarSize, height: LayoutMetrics.avatarSize)
            Image(systemName: "cpu")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct DirectionBadge: View {
    let direction: String

    var body: some View {
        Text(direction == "income" ? "收入" : "支出")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(IMColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(IMColors.controlBg)
            )
    }
}

struct StatusPill: View {
    let title: String
    let warning: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(IMColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(warning ? IMColors.warningBg : IMColors.controlBg)
            )
    }
}

struct ActionButton: View {
    enum Kind {
        case primary
        case ghost
        case dangerGhost
    }

    let title: String
    let kind: Kind
    var minWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(foreground)
                .frame(minWidth: minWidth, minHeight: LayoutMetrics.actionButtonHeight)
                .padding(.horizontal, 14)
                .background(shape.fill(backgroundFill))
                .overlay(
                    shape
                        .stroke(borderColor, lineWidth: kind == .primary ? 0 : 1)
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .ghost:
            return IMColors.accentAlt
        case .dangerGhost:
            return IMColors.danger
        }
    }

    private var backgroundFill: Color {
        kind == .primary ? IMColors.buttonPrimary : .clear
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return .clear
        case .ghost:
            return IMColors.accentAlt
        case .dangerGhost:
            return IMColors.dangerBorder
        }
    }
}

struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.sizeThatFits(.unspecified)
                item.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row {
        var items: [LayoutSubview] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = currentWidth > 0 ? size.width + spacing : size.width
            if currentWidth + needed > maxWidth && currentWidth > 0 {
                rows.append(Row())
                currentWidth = 0
            }
            rows[rows.count - 1].items.append(subview)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            currentWidth += (currentWidth > 0 ? spacing : 0) + size.width
        }
        return rows
    }
}
