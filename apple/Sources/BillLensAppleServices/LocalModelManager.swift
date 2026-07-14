import Combine
import CryptoKit
import Darwin
import Foundation

public enum LocalModelMode: String, Codable, CaseIterable, Sendable {
    case localFirst = "local_first"
    case cloudOnly = "cloud_only"
}

public struct LocalModelDescriptor: Codable, Identifiable, Hashable, Sendable {
    public let modelId: String
    public let displayName: String
    public let revision: String
    public let fileName: String
    public let downloadURL: URL
    public let byteCount: Int64
    public let sha256: String
    public let license: String
    public let contextTokens: UInt32
    public let maxOutputTokens: UInt32
    public let minimumAvailableMemory: UInt64
    public let experimentalOnIPhone: Bool

    public var id: String { modelId }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case displayName = "display_name"
        case revision
        case fileName = "file_name"
        case downloadURL = "download_url"
        case byteCount = "byte_count"
        case sha256
        case license
        case contextTokens = "context_tokens"
        case maxOutputTokens = "max_output_tokens"
        case minimumAvailableMemory = "minimum_available_memory"
        case experimentalOnIPhone = "experimental_on_iphone"
    }
}

public enum LocalModelDownloadPhase: String, Codable, Sendable {
    case idle
    case waitingForWiFi = "waiting_for_wifi"
    case downloading
    case verifying
    case installed
    case failed

    public var isActive: Bool {
        switch self {
        case .waitingForWiFi, .downloading, .verifying:
            true
        case .idle, .installed, .failed:
            false
        }
    }
}

public struct LocalModelDownloadState: Codable, Sendable {
    public var phase: LocalModelDownloadPhase
    public var receivedBytes: Int64
    public var expectedBytes: Int64
    public var error: String?
    public var revision: String?
    public var sourceURL: String?

    public static let idle = LocalModelDownloadState(
        phase: .idle,
        receivedBytes: 0,
        expectedBytes: 0,
        error: nil,
        revision: nil,
        sourceURL: nil
    )
}

public struct LocalModelInstalledState: Codable, Sendable {
    public let revision: String
    public let fileName: String
    public let byteCount: Int64
    public let sha256: String
    public let verifiedAt: Date
}

private struct LocalModelCatalog: Decodable {
    let schemaVersion: Int
    let models: [LocalModelDescriptor]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case models
    }
}

private struct LocalModelPersistentState: Codable {
    var schemaVersion = 1
    var mode: LocalModelMode = .cloudOnly
    var selectedModelId: String?
    var installed: [String: LocalModelInstalledState] = [:]
    var downloads: [String: LocalModelDownloadState] = [:]
}

public enum LocalModelManagerError: LocalizedError {
    case initialization(String)
    case unknownModel(String)
    case invalidManifest(String)
    case insufficientDisk(required: Int64, available: Int64)
    case insufficientMemory(required: UInt64, available: UInt64)
    case invalidDownloadSize(expected: Int64, actual: Int64)
    case checksumMismatch(modelId: String)
    case modelNotInstalled(String)
    case taskStateMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .initialization(let message), .invalidManifest(let message):
            return message
        case .unknownModel(let id):
            return "模型清单中不存在模型：\(id)"
        case .insufficientDisk(let required, let available):
            return "磁盘空间不足，需要 \(required) 字节，当前可用 \(available) 字节。"
        case .insufficientMemory(let required, let available):
            return "可用内存不足，需要 \(required) 字节，当前可用 \(available) 字节。"
        case .invalidDownloadSize(let expected, let actual):
            return "模型文件大小不匹配，预期 \(expected) 字节，实际 \(actual) 字节。"
        case .checksumMismatch(let modelId):
            return "模型 \(modelId) 的 SHA-256 校验失败。"
        case .modelNotInstalled(let id):
            return "模型尚未安装：\(id)"
        case .taskStateMismatch(let message):
            return "后台下载状态不一致：\(message)"
        }
    }
}

@MainActor
public final class LocalModelManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = LocalModelManager()
    #if os(iOS)
    nonisolated public static let backgroundSessionIdentifier =
        "com.shendongchun.BillLensApple.ios.local-model-downloads"
    #endif

    @Published public private(set) var models: [LocalModelDescriptor] = []
    @Published public private(set) var mode: LocalModelMode = .cloudOnly
    @Published public private(set) var selectedModelId: String?
    @Published public private(set) var installed: [String: LocalModelInstalledState] = [:]
    @Published public private(set) var downloads: [String: LocalModelDownloadState] = [:]
    @Published public private(set) var lastError: String?

    private var persistent = LocalModelPersistentState()
    private var initializationError: Error?
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let downloadsURL: URL
    private let installedURL: URL
    private let stateURL: URL
    private var backgroundCompletionHandler: (() -> Void)?
    private var userCancelledModelIds: Set<String> = []

    private lazy var session: URLSession = {
        let configuration = Self.makeDownloadSessionConfiguration()
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support
            .appendingPathComponent("BillLensApple", isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
        downloadsURL = rootURL.appendingPathComponent("downloads", isDirectory: true)
        installedURL = rootURL.appendingPathComponent("installed", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("catalog-state.json")
        super.init()

        do {
            try prepareDirectories()
            models = try Self.loadCatalog()
            persistent = try loadPersistentState()
            try validatePersistentState()
            publishPersistentState()
            reconcileBackgroundTasks()
        } catch {
            initializationError = error
            lastError = error.localizedDescription
        }
    }

    public func setMode(_ newMode: LocalModelMode) throws {
        try requireInitialized()
        if newMode == .cloudOnly {
            LocalLlmRuntime.shared.unload()
        }
        persistent.mode = newMode
        try persistAndPublish()
        AppLogger.log("local_model.mode", "mode=\(newMode.rawValue)")
    }

    public func selectModel(_ modelId: String) throws {
        try requireInitialized()
        guard installed[modelId] != nil else {
            throw LocalModelManagerError.modelNotInstalled(modelId)
        }
        if persistent.selectedModelId != modelId {
            LocalLlmRuntime.shared.unload()
        }
        persistent.selectedModelId = modelId
        try persistAndPublish()
        AppLogger.log("local_model.select", "model_id=\(modelId)")
    }

    public func routingDictionary() throws -> [String: Any] {
        try requireInitialized()
        var result: [String: Any] = ["mode": mode.rawValue]
        result["model_id"] = selectedModelId ?? NSNull()
        return result
    }

    public func descriptor(for modelId: String) throws -> LocalModelDescriptor {
        try requireInitialized()
        guard let model = models.first(where: { $0.modelId == modelId }) else {
            throw LocalModelManagerError.unknownModel(modelId)
        }
        return model
    }

    public func selectedModelFileURL() throws -> (LocalModelDescriptor, URL) {
        try requireInitialized()
        guard let selectedModelId else {
            throw LocalModelManagerError.modelNotInstalled("未选择模型")
        }
        let descriptor = try descriptor(for: selectedModelId)
        guard let state = installed[selectedModelId] else {
            throw LocalModelManagerError.modelNotInstalled(selectedModelId)
        }
        let url = installedFileURL(modelId: selectedModelId, state: state)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value
        guard actualSize == state.byteCount else {
            throw LocalModelManagerError.invalidDownloadSize(
                expected: state.byteCount,
                actual: actualSize ?? -1
            )
        }
        return (descriptor, url)
    }

    public func startDownload(modelId: String, allowCellularOnce: Bool = false) throws {
        try requireInitialized()
        let descriptor = try descriptor(for: modelId)
        try checkResources(for: descriptor)
        guard downloads[modelId]?.phase.isActive != true else {
            throw LocalModelManagerError.taskStateMismatch("模型 \(modelId) 已在下载中")
        }

        var request = URLRequest(url: descriptor.downloadURL)
        #if os(iOS)
        request.allowsExpensiveNetworkAccess = allowCellularOnce
        request.allowsConstrainedNetworkAccess = false
        #else
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        #endif
        let resumeURL = resumeDataURL(modelId: modelId)
        let existing = persistent.downloads[modelId]
        let canResume = !allowCellularOnce
            && existing?.revision == descriptor.revision
            && existing?.sourceURL == descriptor.downloadURL.absoluteString
            && fileManager.fileExists(atPath: resumeURL.path)
        let task: URLSessionDownloadTask
        if canResume {
            task = session.downloadTask(withResumeData: try Data(contentsOf: resumeURL))
        } else {
            if fileManager.fileExists(atPath: resumeURL.path) {
                try fileManager.removeItem(at: resumeURL)
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = modelId
        userCancelledModelIds.remove(modelId)
        persistent.downloads[modelId] = LocalModelDownloadState(
            phase: .downloading,
            receivedBytes: 0,
            expectedBytes: descriptor.byteCount,
            error: nil,
            revision: descriptor.revision,
            sourceURL: descriptor.downloadURL.absoluteString
        )
        try persistAndPublish()
        task.resume()
        AppLogger.log(
            "local_model.download.start",
            "model_id=\(modelId) cellular_once=\(allowCellularOnce)"
        )
    }

    public func cancelDownload(modelId: String) async throws {
        try requireInitialized()
        let tasks = await session.allTasks
        userCancelledModelIds.insert(modelId)
        for task in tasks where task.taskDescription == modelId {
            task.cancel()
        }
        try removeDownloadArtifacts(modelId: modelId)
        persistent.downloads[modelId] = .idle
        try persistAndPublish()
        AppLogger.log("local_model.download.cancel", "model_id=\(modelId)")
    }

    public func deleteModel(modelId: String) throws {
        try requireInitialized()
        guard downloads[modelId]?.phase.isActive != true else {
            throw LocalModelManagerError.taskStateMismatch("下载中不能删除模型")
        }
        if persistent.selectedModelId == modelId {
            LocalLlmRuntime.shared.unload()
        }
        let modelRoot = installedURL.appendingPathComponent(modelId, isDirectory: true)
        let deletionStaging = installedURL.appendingPathComponent(
            ".deleting-\(modelId)-\(UUID().uuidString)",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: modelRoot.path) {
            try fileManager.moveItem(at: modelRoot, to: deletionStaging)
        }
        persistent.installed.removeValue(forKey: modelId)
        if persistent.selectedModelId == modelId {
            persistent.selectedModelId = nil
        }
        persistent.downloads[modelId] = .idle
        do {
            try persistAndPublish()
        } catch let persistenceError {
            if fileManager.fileExists(atPath: deletionStaging.path) {
                do {
                    try fileManager.moveItem(at: deletionStaging, to: modelRoot)
                } catch let rollbackError {
                    throw LocalModelManagerError.initialization(
                        "保存模型删除状态失败：\(persistenceError.localizedDescription)；恢复模型目录也失败：\(rollbackError.localizedDescription)"
                    )
                }
            }
            throw persistenceError
        }
        if fileManager.fileExists(atPath: deletionStaging.path) {
            do {
                try fileManager.removeItem(at: deletionStaging)
            } catch {
                throw LocalModelManagerError.initialization(
                    "模型已从安装状态移除，但清理模型文件失败：\(error.localizedDescription)"
                )
            }
        }
        AppLogger.log("local_model.delete", "model_id=\(modelId)")
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    nonisolated public static func availableMemory() throws -> UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw LocalModelManagerError.initialization(
                "读取当前可用内存失败，Mach 返回码：\(result)"
            )
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            throw LocalModelManagerError.initialization("读取系统内存页大小失败。")
        }
        let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        return availablePages * UInt64(pageSize)
        #endif
    }

    nonisolated static func makeDownloadSessionConfiguration() -> URLSessionConfiguration {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: backgroundSessionIdentifier
        )
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        #else
        // The macOS target is a Swift Package executable. A background session requires
        // an application-bundle host, so retain a regular session at app scope instead.
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        #endif
        configuration.waitsForConnectivity = true
        return configuration
    }

    nonisolated static func diagnosticDescription(_ error: Error) -> String {
        diagnosticDescription(error as NSError, depth: 0)
    }

    nonisolated private static func diagnosticDescription(
        _ error: NSError,
        depth: Int
    ) -> String {
        var fields = [
            "domain=\(error.domain)",
            "code=\(error.code)",
            "description=\(error.localizedDescription)",
        ]
        if let failureReason = error.localizedFailureReason, !failureReason.isEmpty {
            fields.append("reason=\(failureReason)")
        }
        if depth == 0, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields.append("underlying={\(diagnosticDescription(underlying, depth: depth + 1))}")
        }
        return fields.joined(separator: " ")
    }

    nonisolated public static func resolvedSelectedModel() throws -> (LocalModelDescriptor, URL) {
        let models = try loadCatalog()
        let root = localModelsRootURL()
        let stateURL = root.appendingPathComponent("catalog-state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw LocalModelManagerError.modelNotInstalled("未选择模型")
        }
        let state = try JSONDecoder().decode(
            LocalModelPersistentState.self,
            from: Data(contentsOf: stateURL)
        )
        guard state.schemaVersion == 1 else {
            throw LocalModelManagerError.initialization(
                "不支持的本地模型状态版本：\(state.schemaVersion)"
            )
        }
        guard let selected = state.selectedModelId,
              let installed = state.installed[selected],
              let descriptor = models.first(where: { $0.modelId == selected }) else {
            throw LocalModelManagerError.modelNotInstalled(state.selectedModelId ?? "未选择模型")
        }
        try validateInstalledState(installed, modelId: selected, descriptor: descriptor)
        let url = root
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent(descriptor.modelId, isDirectory: true)
            .appendingPathComponent(installed.revision, isDirectory: true)
            .appendingPathComponent(installed.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == installed.byteCount else {
            throw LocalModelManagerError.invalidDownloadSize(
                expected: installed.byteCount,
                actual: size
            )
        }
        return (descriptor, url)
    }

    nonisolated static func bundledCatalog() throws -> [LocalModelDescriptor] {
        guard let url = Bundle.module.url(forResource: "local-models", withExtension: "json") else {
            throw LocalModelManagerError.invalidManifest("本地模型清单未随 App 发布。")
        }
        let data = try Data(contentsOf: url)
        return try decodeCatalog(data)
    }

    nonisolated static func decodeCatalog(_ data: Data) throws -> [LocalModelDescriptor] {
        guard let rawCatalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(rawCatalog.keys) == ["schema_version", "models"],
              let rawModels = rawCatalog["models"] as? [[String: Any]] else {
            throw LocalModelManagerError.invalidManifest("本地模型清单根结构或字段无效。")
        }
        let expectedModelKeys: Set<String> = [
            "model_id", "display_name", "revision", "file_name", "download_url",
            "byte_count", "sha256", "license", "context_tokens", "max_output_tokens",
            "minimum_available_memory", "experimental_on_iphone"
        ]
        guard rawModels.allSatisfy({ Set($0.keys) == expectedModelKeys }) else {
            throw LocalModelManagerError.invalidManifest("本地模型清单条目字段与协议不一致。")
        }
        let catalog = try JSONDecoder().decode(LocalModelCatalog.self, from: data)
        guard catalog.schemaVersion == 1 else {
            throw LocalModelManagerError.invalidManifest(
                "不支持的本地模型清单版本：\(catalog.schemaVersion)"
            )
        }
        guard Set(catalog.models.map(\.modelId)).count == catalog.models.count else {
            throw LocalModelManagerError.invalidManifest("本地模型清单包含重复 model_id。")
        }
        for model in catalog.models {
            guard model.downloadURL.scheme == "https",
                  model.downloadURL.host == "huggingface.co",
                  model.downloadURL.path.contains("/resolve/\(model.revision)/"),
                  model.byteCount > 0,
                  model.sha256.count == 64,
                  model.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw LocalModelManagerError.invalidManifest(
                    "本地模型清单条目无效：\(model.modelId)"
                )
            }
        }
        return catalog.models
    }

    nonisolated private static func loadCatalog() throws -> [LocalModelDescriptor] {
        try bundledCatalog()
    }

    nonisolated private static func localModelsRootURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BillLensApple", isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
    }

    nonisolated private static func downloadPartialURL(modelId: String) -> URL {
        localModelsRootURL()
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("\(modelId).partial")
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installedURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try mutableRoot.setResourceValues(values)
    }

    private func loadPersistentState() throws -> LocalModelPersistentState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return LocalModelPersistentState()
        }
        let state = try JSONDecoder().decode(
            LocalModelPersistentState.self,
            from: Data(contentsOf: stateURL)
        )
        guard state.schemaVersion == 1 else {
            throw LocalModelManagerError.initialization(
                "不支持的本地模型状态版本：\(state.schemaVersion)"
            )
        }
        return state
    }

    private func validatePersistentState() throws {
        for (modelId, state) in persistent.installed {
            let descriptor = try descriptorFromLoadedCatalog(modelId)
            try Self.validateInstalledState(state, modelId: modelId, descriptor: descriptor)
            let recordedFile = installedURL
                .appendingPathComponent(modelId, isDirectory: true)
                .appendingPathComponent(state.revision, isDirectory: true)
                .appendingPathComponent(state.fileName)
            guard fileManager.fileExists(atPath: recordedFile.path) else {
                throw LocalModelManagerError.taskStateMismatch(
                    "模型 \(modelId) 标记为已安装，但文件不存在"
                )
            }
            let attributes = try fileManager.attributesOfItem(atPath: recordedFile.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == state.byteCount else {
                throw LocalModelManagerError.taskStateMismatch(
                    "模型 \(modelId) 的安装文件大小与安装记录不一致"
                )
            }
        }
        if let selected = persistent.selectedModelId, persistent.installed[selected] == nil {
            throw LocalModelManagerError.taskStateMismatch("选择的模型没有有效安装记录")
        }
    }

    nonisolated static func validateInstalledState(
        _ state: LocalModelInstalledState,
        modelId: String,
        descriptor: LocalModelDescriptor
    ) throws {
        guard !state.revision.isEmpty,
              state.revision == URL(fileURLWithPath: state.revision).lastPathComponent,
              state.fileName == URL(fileURLWithPath: state.fileName).lastPathComponent,
              state.byteCount > 0,
              state.sha256.count == 64,
              state.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw LocalModelManagerError.taskStateMismatch(
                "模型 \(modelId) 的安装记录字段无效"
            )
        }
        if state.revision == descriptor.revision,
           (state.fileName != descriptor.fileName
            || state.sha256 != descriptor.sha256
            || state.byteCount != descriptor.byteCount) {
            throw LocalModelManagerError.taskStateMismatch(
                "模型 \(modelId) 的安装记录与随 App 清单不一致"
            )
        }
    }

    private func checkResources(for descriptor: LocalModelDescriptor) throws {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableDisk = values.volumeAvailableCapacityForImportantUsage ?? -1
        let requiredDisk = descriptor.byteCount * 2 + 512 * 1024 * 1024
        guard availableDisk >= requiredDisk else {
            throw LocalModelManagerError.insufficientDisk(
                required: requiredDisk,
                available: availableDisk
            )
        }
        #if os(iOS)
        let availableMemory = try Self.availableMemory()
        guard availableMemory >= descriptor.minimumAvailableMemory else {
            throw LocalModelManagerError.insufficientMemory(
                required: descriptor.minimumAvailableMemory,
                available: availableMemory
            )
        }
        #endif
    }

    private func installDownloadedFile(_ temporaryURL: URL, modelId: String) throws {
        let descriptor = try descriptor(for: modelId)
        let previousInstallation = persistent.installed[modelId]
        persistent.downloads[modelId] = LocalModelDownloadState(
            phase: .verifying,
            receivedBytes: descriptor.byteCount,
            expectedBytes: descriptor.byteCount,
            error: nil,
            revision: descriptor.revision,
            sourceURL: descriptor.downloadURL.absoluteString
        )
        try persistAndPublish()

        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == descriptor.byteCount else {
            throw LocalModelManagerError.invalidDownloadSize(
                expected: descriptor.byteCount,
                actual: actualSize
            )
        }
        let digest = try sha256(url: temporaryURL)
        guard constantTimeEqual(digest, descriptor.sha256.lowercased()) else {
            throw LocalModelManagerError.checksumMismatch(modelId: modelId)
        }
        if persistent.selectedModelId == modelId {
            LocalLlmRuntime.shared.unload()
        }

        let revisionDirectory = installedURL
            .appendingPathComponent(modelId, isDirectory: true)
            .appendingPathComponent(descriptor.revision, isDirectory: true)
        try fileManager.createDirectory(at: revisionDirectory, withIntermediateDirectories: true)
        let destination = revisionDirectory.appendingPathComponent(descriptor.fileName)
        let staging = revisionDirectory.appendingPathComponent(".\(descriptor.fileName).staging")
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.moveItem(at: temporaryURL, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try mutableDestination.setResourceValues(values)

        persistent.installed[modelId] = LocalModelInstalledState(
            revision: descriptor.revision,
            fileName: descriptor.fileName,
            byteCount: descriptor.byteCount,
            sha256: descriptor.sha256,
            verifiedAt: Date()
        )
        persistent.downloads[modelId] = LocalModelDownloadState(
            phase: .installed,
            receivedBytes: descriptor.byteCount,
            expectedBytes: descriptor.byteCount,
            error: nil,
            revision: descriptor.revision,
            sourceURL: descriptor.downloadURL.absoluteString
        )
        if persistent.selectedModelId == nil {
            persistent.selectedModelId = modelId
            persistent.mode = .localFirst
        }
        let resumeURL = resumeDataURL(modelId: modelId)
        if fileManager.fileExists(atPath: resumeURL.path) {
            try fileManager.removeItem(at: resumeURL)
        }
        do {
            try persistAndPublish()
        } catch let persistenceError {
            if previousInstallation?.revision != descriptor.revision,
               fileManager.fileExists(atPath: revisionDirectory.path) {
                do {
                    try fileManager.removeItem(at: revisionDirectory)
                } catch let cleanupError {
                    throw LocalModelManagerError.initialization(
                        "保存模型安装状态失败：\(persistenceError.localizedDescription)；清理新版本目录也失败：\(cleanupError.localizedDescription)"
                    )
                }
            }
            throw persistenceError
        }
        AppLogger.log(
            "local_model.install",
            "model_id=\(modelId) revision=\(descriptor.revision) bytes=\(descriptor.byteCount)"
        )
        if let previousInstallation,
           previousInstallation.revision != descriptor.revision {
            let previousRevisionDirectory = installedURL
                .appendingPathComponent(modelId, isDirectory: true)
                .appendingPathComponent(previousInstallation.revision, isDirectory: true)
            if fileManager.fileExists(atPath: previousRevisionDirectory.path) {
                do {
                    try fileManager.removeItem(at: previousRevisionDirectory)
                } catch {
                    lastError = "新模型已安装，但删除旧版本失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func reconcileBackgroundTasks() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                let activeIds = Set(tasks.compactMap(\.taskDescription))
                for (modelId, state) in self.persistent.downloads
                where state.phase == .downloading && !activeIds.contains(modelId) {
                    self.recordDownloadFailure(
                        modelId: modelId,
                        error: LocalModelManagerError.taskStateMismatch(
                            "模型 \(modelId) 标记为下载中，但系统任务不存在"
                        ),
                        receivedBytes: state.receivedBytes,
                        removeArtifacts: false
                    )
                }
                for task in tasks {
                    guard let modelId = task.taskDescription else {
                        task.cancel()
                        self.lastError = "后台下载任务缺少 model_id，任务已终止。"
                        continue
                    }
                    do {
                        _ = try self.descriptor(for: modelId)
                    } catch {
                        task.cancel()
                        self.recordDownloadFailure(
                            modelId: modelId,
                            error: error,
                            receivedBytes: task.countOfBytesReceived,
                            removeArtifacts: true
                        )
                    }
                }
            }
        }
    }

    private func persistAndPublish() throws {
        do {
            let data = try JSONEncoder().encode(persistent)
            try data.write(to: stateURL, options: [.atomic])
            publishPersistentState()
            lastError = nil
        } catch let persistenceError {
            do {
                persistent = try loadPersistentState()
                try validatePersistentState()
                publishPersistentState()
            } catch let reloadError {
                throw LocalModelManagerError.initialization(
                    "保存本地模型状态失败：\(persistenceError.localizedDescription)；恢复磁盘状态也失败：\(reloadError.localizedDescription)"
                )
            }
            throw persistenceError
        }
    }

    private func publishPersistentState() {
        mode = persistent.mode
        selectedModelId = persistent.selectedModelId
        installed = persistent.installed
        downloads = persistent.downloads
    }

    private func requireInitialized() throws {
        if let initializationError {
            throw LocalModelManagerError.initialization(initializationError.localizedDescription)
        }
    }

    private func descriptorFromLoadedCatalog(_ modelId: String) throws -> LocalModelDescriptor {
        guard let model = models.first(where: { $0.modelId == modelId }) else {
            throw LocalModelManagerError.unknownModel(modelId)
        }
        return model
    }

    private func installedFileURL(
        modelId: String,
        state: LocalModelInstalledState
    ) -> URL {
        installedURL
            .appendingPathComponent(modelId, isDirectory: true)
            .appendingPathComponent(state.revision, isDirectory: true)
            .appendingPathComponent(state.fileName)
    }

    private func downloadFileURL(modelId: String) -> URL {
        downloadsURL.appendingPathComponent("\(modelId).partial")
    }

    private func resumeDataURL(modelId: String) -> URL {
        downloadsURL.appendingPathComponent("\(modelId).resume")
    }

    private func removeDownloadArtifacts(modelId: String) throws {
        let url = downloadFileURL(modelId: modelId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let resumeURL = resumeDataURL(modelId: modelId)
        if fileManager.fileExists(atPath: resumeURL.path) {
            try fileManager.removeItem(at: resumeURL)
        }
    }

    private func recordDownloadFailure(
        modelId: String,
        error: Error,
        receivedBytes: Int64,
        removeArtifacts: Bool
    ) {
        var visibleError = Self.diagnosticDescription(error)
        if removeArtifacts {
            do {
                try removeDownloadArtifacts(modelId: modelId)
            } catch let cleanupError {
                visibleError += "；清理下载文件失败：\(cleanupError.localizedDescription)"
            }
        }
        guard let descriptor = models.first(where: { $0.modelId == modelId }) else {
            lastError = visibleError + "；模型清单中不存在模型：\(modelId)"
            return
        }
        guard persistent.downloads[modelId] != nil else {
            lastError = visibleError + "；模型 \(modelId) 没有下载状态记录"
            return
        }
        persistent.downloads[modelId] = LocalModelDownloadState(
            phase: .failed,
            receivedBytes: receivedBytes,
            expectedBytes: descriptor.byteCount,
            error: visibleError,
            revision: descriptor.revision,
            sourceURL: descriptor.downloadURL.absoluteString
        )
        do {
            try persistAndPublish()
        } catch let persistError {
            visibleError += "；保存错误状态失败：\(persistError.localizedDescription)"
        }
        lastError = visibleError
        AppLogger.log(
            "local_model.download.failure",
            "model_id=\(modelId) error=\(visibleError)"
        )
    }

    private func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            try handle.close()
        } catch {
            do {
                try handle.close()
            } catch let closeError {
                throw LocalModelManagerError.initialization(
                    "读取模型文件失败：\(error.localizedDescription)；关闭文件也失败：\(closeError.localizedDescription)"
                )
            }
            throw error
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

extension LocalModelManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    #if os(iOS)
    nonisolated public func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        guard let modelId = task.taskDescription else {
            Task { @MainActor in
                self.lastError = "等待网络的后台下载任务缺少 model_id，任务已终止。"
                task.cancel()
            }
            return
        }
        Task { @MainActor in
            guard var state = self.persistent.downloads[modelId], state.phase.isActive else {
                self.lastError = "模型 \(modelId) 没有活动下载状态，等待网络的任务已终止。"
                task.cancel()
                return
            }
            state.phase = .waitingForWiFi
            self.persistent.downloads[modelId] = state
            do {
                try self.persistAndPublish()
            } catch {
                self.lastError = error.localizedDescription
                task.cancel()
            }
        }
    }
    #endif

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelId = downloadTask.taskDescription else {
            Task { @MainActor in
                self.lastError = "后台下载任务缺少 model_id，无法更新进度。"
                downloadTask.cancel()
            }
            return
        }
        Task { @MainActor in
            guard var state = self.persistent.downloads[modelId] else {
                self.lastError = "模型 \(modelId) 没有下载状态记录，无法更新进度。"
                downloadTask.cancel()
                return
            }
            state.phase = .downloading
            state.receivedBytes = totalBytesWritten
            state.expectedBytes = totalBytesExpectedToWrite
            self.persistent.downloads[modelId] = state
            do {
                try self.persistAndPublish()
            } catch {
                self.lastError = error.localizedDescription
                downloadTask.cancel()
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelId = downloadTask.taskDescription else {
            Task { @MainActor in
                self.lastError = "后台下载任务缺少 model_id，无法安装模型。"
            }
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200 || response.statusCode == 206 else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                self.recordDownloadFailure(
                    modelId: modelId,
                    error: LocalModelManagerError.taskStateMismatch(
                        "模型下载 HTTP 状态无效：\(status.map(String.init) ?? "非 HTTP 响应")"
                    ),
                    receivedBytes: downloadTask.countOfBytesReceived,
                    removeArtifacts: true
                )
            }
            return
        }
        let destination = LocalModelManager.downloadPartialURL(modelId: modelId)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                do {
                    try self.installDownloadedFile(destination, modelId: modelId)
                } catch {
                    self.recordDownloadFailure(
                        modelId: modelId,
                        error: error,
                        receivedBytes: 0,
                        removeArtifacts: true
                    )
                }
            }
        } catch {
            Task { @MainActor in
                self.recordDownloadFailure(
                    modelId: modelId,
                    error: error,
                    receivedBytes: downloadTask.countOfBytesReceived,
                    removeArtifacts: true
                )
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        guard let modelId = task.taskDescription else {
            Task { @MainActor in
                self.lastError = "后台下载失败，且任务缺少 model_id：\(Self.diagnosticDescription(error))"
            }
            return
        }
        Task { @MainActor in
            if self.userCancelledModelIds.contains(modelId) {
                return
            }
            guard self.persistent.downloads[modelId]?.phase.isActive == true else {
                self.lastError = "模型 \(modelId) 下载失败，但没有活动下载状态：\(Self.diagnosticDescription(error))"
                return
            }
            let nsError = error as NSError
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                do {
                    try resumeData.write(to: self.resumeDataURL(modelId: modelId), options: [.atomic])
                } catch let resumeError {
                    self.recordDownloadFailure(
                        modelId: modelId,
                        error: LocalModelManagerError.taskStateMismatch(
                            "下载失败：\(Self.diagnosticDescription(error))；保存恢复数据失败：\(Self.diagnosticDescription(resumeError))"
                        ),
                        receivedBytes: task.countOfBytesReceived,
                        removeArtifacts: true
                    )
                    return
                }
            }
            self.recordDownloadFailure(
                modelId: modelId,
                error: error,
                receivedBytes: task.countOfBytesReceived,
                removeArtifacts: false
            )
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
