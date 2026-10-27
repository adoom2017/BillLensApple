import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分享扩展只把账单文件放进 App Group 收件箱，解析与入库由主 App 在回到前台时完成。
/// 不链接 Rust、不打开数据库，避免扩展内存上限与数据库并发写入。
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        model.save(from: providers)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable {
        case saving
        case saved
        case failed(String)
    }

    /// 与主 App `StatementInbox` 保持一致。
    private static let appGroupIdentifier = "group.com.shendongchun.BillLensApple"
    private static let directoryName = "StatementInbox"
    private static let acceptedTypes: [(UTType, String)] = [
        (.pdf, "pdf"),
        (UTType("com.apple.mail.email") ?? .data, "eml"),
        (.html, "html"),
    ]

    @Published private(set) var state: State = .saving

    func save(from providers: [NSItemProvider]) {
        guard let (provider, type, fileExtension) = providers.lazy.compactMap({ provider in
            Self.acceptedTypes
                .first { provider.hasItemConformingToTypeIdentifier($0.0.identifier) }
                .map { (provider, $0.0, $0.1) }
        }).first else {
            state = .failed("只支持 PDF、邮件（.eml）或 HTML 账单。")
            return
        }
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent(Self.directoryName, isDirectory: true) else {
            state = .failed("当前安装的版本不支持分享导入，请在 App 内通过文件导入。")
            return
        }
        // 回调在后台队列执行：@Sendable 使其不继承 ShareModel 的 MainActor 隔离，
        // 文件写入在后台完成，只有状态更新切回主线程。
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { @Sendable [weak self] data, error in
            let result: State
            if let data {
                result = Self.write(data, extension: fileExtension, to: directory)
            } else {
                result = .failed("无法读取分享的文件：\(error?.localizedDescription ?? "未知错误")")
            }
            Task { @MainActor in self?.state = result }
        }
    }

    /// 先写 `.partial` 再原子改名，主 App 不会读到写了一半的文件。
    nonisolated private static func write(_ data: Data, extension fileExtension: String, to directory: URL) -> State {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = UUID().uuidString
            let partial = directory.appendingPathComponent("\(name).\(fileExtension).partial")
            let final = directory.appendingPathComponent("\(name).\(fileExtension)")
            try data.write(to: partial, options: .atomic)
            try FileManager.default.moveItem(at: partial, to: final)
            return .saved
        } catch {
            return .failed("保存失败：\(error.localizedDescription)")
        }
    }
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch model.state {
                case .saving:
                    ProgressView("正在保存账单…")
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("已发送到账映")
                        .font(.headline)
                    Text("打开 App 即可预览并导入这份信用卡账单。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("导入信用卡账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone)
                        .disabled(model.state == .saving)
                }
            }
        }
    }
}
