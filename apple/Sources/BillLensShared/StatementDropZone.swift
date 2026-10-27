#if os(macOS)
import AppKit
import SwiftUI
import BillLensAppleServices

/// macOS 导入面板：Mail 拖出的邮件是 file promise，SwiftUI `onDrop` 收不到，
/// 必须由注册了 `NSFilePromiseReceiver.readableDraggedTypes` 的 AppKit 视图接收。
struct StatementDropSheet: View {
    @EnvironmentObject private var store: BillLensStore
    @Environment(\.dismiss) private var dismiss

    @State private var isTargeted = false
    @State private var isReceiving = false
    @State private var isChoosingFile = false

    var body: some View {
        VStack(spacing: 16) {
            Text("导入信用卡账单")
                .font(.title3.weight(.semibold))

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                VStack(spacing: 10) {
                    if isReceiving {
                        ProgressView("正在从 Mail 读取邮件…")
                    } else {
                        Image(systemName: "envelope.badge")
                            .font(.system(size: 40))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                        Text("把 Mail 中的招商银行信用卡账单邮件拖到这里")
                            .font(.callout)
                        Text("也支持 .eml、.html 和 iOS 打印生成的 PDF")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .allowsHitTesting(false)

                StatementDropTarget(
                    isTargeted: $isTargeted,
                    isReceiving: $isReceiving,
                    onFile: { url in
                        dismiss()
                        store.importStatement(url: url)
                    },
                    onError: { message in
                        store.errorText = message
                    }
                )
            }
            .frame(width: 420, height: 220)

            HStack {
                Button("选择文件…") { isChoosingFile = true }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: StatementImportService.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                dismiss()
                store.importStatement(url: url)
            case .failure(let error):
                store.errorText = error.localizedDescription
            }
        }
    }
}

/// 透明的 AppKit 拖放目标，放在拖放区最上层。
private struct StatementDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    @Binding var isReceiving: Bool
    let onFile: @MainActor (URL) -> Void
    let onError: @MainActor (String) -> Void

    func makeNSView(context: Context) -> StatementDropView {
        StatementDropView()
    }

    func updateNSView(_ view: StatementDropView, context: Context) {
        view.onTargetChange = { isTargeted = $0 }
        view.onReceiving = { isReceiving = $0 }
        view.onFile = onFile
        view.onError = onError
    }
}

final class StatementDropView: NSView {
    var onTargetChange: (@MainActor (Bool) -> Void)?
    var onReceiving: (@MainActor (Bool) -> Void)?
    var onFile: (@MainActor (URL) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ",") ?? ""
        AppLogger.log("statement.drop.enter", "types=\(types)")
        onTargetChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // Finder 文件优先；Mail 邮件只有 file promise。
        if let url = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first {
            AppLogger.log("statement.drop.file", "extension=\(url.pathExtension)")
            onFile?(url)
            return true
        }
        guard let receiver = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver])?.first else {
            AppLogger.log("statement.drop.reject", "no file url or file promise")
            onError?("无法识别拖入的内容，请从 Mail 拖入邮件，或拖入 .eml / .pdf 文件。")
            return false
        }

        let dropsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BillLensStatementDrops", isDirectory: true)
        Self.removeStaleDrops(in: dropsRoot)
        let destination = dropsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            onError?(error.localizedDescription)
            return false
        }
        AppLogger.log("statement.drop.promise", "types=\(receiver.fileTypes.joined(separator: ","))")
        onReceiving?(true)

        let delivery = PromiseDelivery(onFile: onFile, onError: onError, onReceiving: onReceiving)
        // 回调在 promiseQueue 上执行：必须是 @Sendable（非隔离）闭包，否则会继承 NSView 的
        // MainActor 隔离，在后台线程触发运行时隔离断言崩溃。
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let failure {
                    delivery.fail(failure)
                } else {
                    delivery.deliver(url, via: "callback")
                }
            }
        }
        // Mail 会立即写好 .eml，却常常不发出完成通知，回调要等 60 秒后以超时（-1001）结束。
        // 因此同时轮询目标目录：文件出现且大小连续两次不变即视为写完，先到者生效。
        Task { @MainActor in
            var lastSizes: [URL: Int] = [:]
            while !delivery.isFinished {
                try? await Task.sleep(for: .milliseconds(300))
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: destination,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in files {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 0, lastSizes[file] == size {
                        delivery.deliver(file, via: "poll")
                        return
                    }
                    lastSizes[file] = size
                }
            }
        }
        return true
    }

    /// 删除 10 分钟前的拖放副本，真实账单不长期留在临时目录。
    private static func removeStaleDrops(in root: URL) {
        let cutoff = Date.now.addingTimeInterval(-600)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// 一次 file promise 拖放的结果只交付一次：轮询与系统回调谁先到用谁，之后的回调忽略。
@MainActor
private final class PromiseDelivery {
    private let onFile: (@MainActor (URL) -> Void)?
    private let onError: (@MainActor (String) -> Void)?
    private let onReceiving: (@MainActor (Bool) -> Void)?
    private(set) var isFinished = false

    init(
        onFile: (@MainActor (URL) -> Void)?,
        onError: (@MainActor (String) -> Void)?,
        onReceiving: (@MainActor (Bool) -> Void)?
    ) {
        self.onFile = onFile
        self.onError = onError
        self.onReceiving = onReceiving
    }

    func deliver(_ url: URL, via source: String) {
        guard !isFinished else { return }
        isFinished = true
        onReceiving?(false)
        AppLogger.log("statement.drop.promise_received", "via=\(source) extension=\(url.pathExtension)")
        onFile?(url)
    }

    func fail(_ message: String) {
        guard !isFinished else { return }
        isFinished = true
        onReceiving?(false)
        AppLogger.log("statement.drop.promise_failed", message)
        onError?("从 Mail 读取邮件失败：\(message)")
    }
}
#endif
