import Foundation
import CloudKit
#if os(macOS)
import Security
#endif
import BillLensAppleServices

/// Handles bidirectional CloudKit sync for all entity types.
/// Rust owns data/conflict logic; this service owns transport only.
@MainActor
public final class CloudKitSyncService {
    public static let shared = CloudKitSyncService()

    private let zoneName = "BillLensZone"
    private let containerIdentifier = "iCloud.com.shendongchun.BillLensApple"
    private var container: CKContainer?
    private var isPushScheduled = false
    private var isPushing = false
    private var pullTask: Task<Bool, Never>?
    private var didEnsureZoneAndSubscription = false
    /// 最近一次拉取或初始化失败的具体原因，供界面展示。
    public private(set) var lastFailureReason: String?
    private var didLogUnavailable = false
    private var bridge: RustBridge?
    private var profileID: String = "local-default"

    private init() {}

    // MARK: - Entry Points

    public func configure(bridge: RustBridge, profileID: String) {
        self.bridge = bridge
        self.profileID = profileID
    }

    public var isEnabledForCurrentProcess: Bool {
        cloudKitIsEnabledForProcess()
    }

    /// Pull and wait for completion. Returns true only when remote state was fully applied.
    /// Used by bootstrap to gate subscription processing on confirmed remote state.
    public func pullSync(bridge: RustBridge, profileID: String) async -> Bool {
        configure(bridge: bridge, profileID: profileID)
        guard await ensureZoneAndSubscription() else { return false }
        return await pull()
    }

    public func schedulePush() {
        guard !isPushScheduled else { return }
        isPushScheduled = true
        Task(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.isPushScheduled = false
            await self?.push()
        }
    }

    public func handleRemoteNotification() {
        Task(priority: .background) { [weak self] in
            guard await self?.ensureZoneAndSubscription() == true else { return }
            await self?.pull()
        }
    }

    /// Pulls and returns when fully applied. Use from the iOS background-fetch delegate so the
    /// completion handler is called only after the pull has actually run.
    public func handleRemoteNotificationAsync() async -> Bool {
        guard await ensureZoneAndSubscription() else { return false }
        return await pull()
    }

    // MARK: - Zone & Subscription Setup

    private func ensureZoneAndSubscription() async -> Bool {
        if didEnsureZoneAndSubscription { return true }
        guard let privateDB = privateDatabase(), let container else {
            return recordFailure("sync.setup", "CloudKit 未启用：当前构建未配置或未签名 \(containerIdentifier)")
        }

        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                return recordFailure("sync.setup", "iCloud 账户不可用（\(Self.describe(status))），请在系统设置中登录 iCloud 并允许本 App 使用 iCloud")
            }
        } catch {
            return recordFailure("sync.setup", "无法获取 iCloud 账户状态：\(Self.describe(error))")
        }

        // 先查询再创建：只有明确“不存在”时才保存，其余错误都视为失败。
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await privateDB.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            do {
                _ = try await privateDB.save(CKRecordZone(zoneID: zoneID))
                AppLogger.log("sync.setup", "Created zone \(zoneName)")
            } catch {
                return recordFailure("sync.zone", "创建 CloudKit 数据区失败：\(Self.describe(error))")
            }
        } catch {
            return recordFailure("sync.zone", "读取 CloudKit 数据区失败：\(Self.describe(error))")
        }

        let subID = CKSubscription.ID("billlens-db-changes")
        do {
            _ = try await privateDB.subscription(for: subID)
        } catch let error as CKError where error.code == .unknownItem {
            let sub = CKDatabaseSubscription(subscriptionID: subID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            sub.notificationInfo = notificationInfo
            do {
                _ = try await privateDB.save(sub)
                AppLogger.log("sync.setup", "Created database subscription")
            } catch {
                return recordFailure("sync.subscription", "创建 CloudKit 变更订阅失败：\(Self.describe(error))")
            }
        } catch {
            return recordFailure("sync.subscription", "读取 CloudKit 变更订阅失败：\(Self.describe(error))")
        }
        didEnsureZoneAndSubscription = true
        return true
    }

    /// 记录失败原因并返回 false，便于 `guard ... else { return recordFailure(...) }`。
    private func recordFailure(_ stage: String, _ reason: String) -> Bool {
        AppLogger.log(stage, reason)
        lastFailureReason = reason
        return false
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        return "CKError \(ckError.code.rawValue)：\(ckError.localizedDescription)"
    }

    nonisolated static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "可用"
        case .noAccount: "未登录 iCloud"
        case .restricted: "受限"
        case .couldNotDetermine: "无法确定"
        case .temporarilyUnavailable: "暂时不可用"
        @unknown default: "未知状态 \(status.rawValue)"
        }
    }

    // MARK: - Push (local → CloudKit)

    private func push() async {
        guard !isPushing else { return }
        isPushing = true
        defer { isPushing = false }
        guard let bridge else { return }
        guard await ensureZoneAndSubscription() else { return }
        guard let privateDB = privateDatabase() else { return }
        // app_setting excluded: llm_config payload contains api_key; keep credentials local-only.
        let entityTypes = ["record", "subscription", "asset", "asset_snapshot"]
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        while true {
            let dirtyBatch: SyncDirtyBatch
            do {
                dirtyBatch = try await bridge.sendAsync([
                    "action": "sync_list_dirty",
                    "profile_id": profileID,
                    "entity_types": entityTypes,
                    "limit": 200
                ])
            } catch {
                AppLogger.log("sync.push.error", "Cannot load dirty rows: \(error)")
                return
            }

            let allItems = dirtyBatch.records + dirtyBatch.subscriptions + dirtyBatch.assets +
                           dirtyBatch.assetSnapshots + dirtyBatch.appSettings
            guard !allItems.isEmpty else { break }

            var ckRecords: [CKRecord] = []
            var itemsByID: [String: SyncDirtyItem] = [:]

            for item in allItems {
                let recordID = CKRecord.ID(recordName: "\(item.entityType):\(item.id)", zoneID: zone)
                let record = CKRecord(recordType: item.entityType, recordID: recordID)
                record["payload"] = item.payload as CKRecordValue
                record["sync_version"] = item.syncVersion as CKRecordValue
                ckRecords.append(record)
                itemsByID[recordID.recordName] = item
            }

            let chunks = stride(from: 0, to: ckRecords.count, by: 400).map {
                Array(ckRecords[$0..<min($0 + 400, ckRecords.count)])
            }
            var chunkFailed = false
            for chunk in chunks {
                let ok = await pushChunk(chunk, itemsByID: itemsByID, bridge: bridge, database: privateDB)
                if !ok { chunkFailed = true; break }
            }
            if chunkFailed { break }
        }
    }

    private func pushChunk(_ records: [CKRecord], itemsByID: [String: SyncDirtyItem], bridge: RustBridge, database: CKDatabase) async -> Bool {
        if let error = await Self.saveRecords(records, database: database) {
            AppLogger.log("sync.push", "Push failed: \(error)")
            return false
        }
        let entries: [[String: Any]] = records.compactMap { record in
            guard let item = itemsByID[record.recordID.recordName] else { return nil }
            return [
                "entity_type": item.entityType,
                "id": item.id,
                "synced_version": item.syncVersion
            ]
        }
        do {
            let _: [String: Int] = try await bridge.sendAsync([
                "action": "sync_mark_synced",
                "entries": entries
            ])
            return true
        } catch {
            AppLogger.log("sync.push.error", "Cannot acknowledge saved rows: \(error)")
            return false
        }
    }

    /// CloudKit 在自己的操作队列上调用回调，因此操作必须在非隔离上下文中创建，
    /// 否则闭包会被推断为 MainActor 隔离却在后台线程执行。
    nonisolated private static func saveRecords(_ records: [CKRecord], database: CKDatabase) async -> (any Error)? {
        await withCheckedContinuation { continuation in
            let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            // .allKeys unconditionally overwrites each field — correct for a LWW opaque payload
            // where we always hold the full entity state and never partial-update individual keys.
            op.savePolicy = .allKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(returning: error)
                }
            }
            database.add(op)
        }
    }

    // MARK: - Pull (CloudKit → local)

    /// Returns true only when remote state was fully fetched and applied to the local DB.
    @discardableResult
    private func pull() async -> Bool {
        if let pullTask { return await pullTask.value }
        let task = Task { await pullPages() }
        pullTask = task
        let result = await task.value
        pullTask = nil
        if result { lastFailureReason = nil }
        return result
    }

    private func pullPages() async -> Bool {
        guard let bridge else { return recordFailure("sync.pull.error", "同步服务尚未配置") }
        guard let privateDB = privateDatabase() else {
            return recordFailure("sync.pull.error", "CloudKit 未启用")
        }
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        struct CursorResponse: Decodable { let token: String? }

        var didClearOnExpiry = false
        while true {
            let serverToken: CKServerChangeToken?
            do {
                let cursor: CursorResponse = try await bridge.sendAsync([
                    "action": "sync_get_cursor",
                    "profile_id": profileID,
                    "zone": zoneName
                ])
                serverToken = try Self.decodeServerToken(cursor.token)
            } catch {
                return recordFailure("sync.pull.error", "Cannot load cursor: \(Self.describe(error))")
            }

            let outcome = await Self.fetchPage(database: privateDB, zone: zone, token: serverToken)

            if outcome.tokenExpired {
                if didClearOnExpiry {
                    return recordFailure("sync.pull.error", "CloudKit 同步游标连续过期")
                }
                didClearOnExpiry = true
                do {
                    let _: [String: String] = try await bridge.sendAsync([
                        "action": "sync_set_cursor",
                        "profile_id": profileID,
                        "zone": zoneName,
                        "token": NSNull()
                    ])
                } catch {
                    return recordFailure("sync.pull.error", "Cannot clear expired cursor: \(Self.describe(error))")
                }
                continue
            }
            if outcome.fetchFailed {
                return recordFailure("sync.pull.error", outcome.failureReason ?? "CloudKit 拉取失败")
            }

            do {
                let entries = try Self.remoteEntries(from: outcome.records)
                if !entries.isEmpty {
                    let _: SyncApplyResult = try await bridge.sendAsync([
                        "action": "sync_apply_remote",
                        "entries": entries
                    ])
                }
                guard let token = outcome.newToken else {
                    throw RustBridgeError.engineError("CloudKit 拉取成功但没有返回同步游标。")
                }
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: token,
                    requiringSecureCoding: true
                )
                let _: [String: String] = try await bridge.sendAsync([
                    "action": "sync_set_cursor",
                    "profile_id": profileID,
                    "zone": zoneName,
                    "token": data.base64EncodedString()
                ])
            } catch {
                return recordFailure("sync.pull.error", "Page not committed: \(Self.describe(error))")
            }

            if !outcome.moreComing { return true }
        }
    }

    /// 单页拉取结果。只在操作完成后整体交回调用方，此后不再有并发修改。
    struct FetchOutcome: @unchecked Sendable {
        var records: [CKRecord] = []
        var newToken: CKServerChangeToken?
        var tokenExpired = false
        var fetchFailed = false
        var failureReason: String?
        var moreComing = false
    }

    /// CloudKit 回调在其操作队列上并发执行，结果写入加锁的容器。
    private final class FetchOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome = FetchOutcome()

        func update(_ body: (inout FetchOutcome) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&outcome)
        }

        func value() -> FetchOutcome {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    /// 拉取一页变更；见 `saveRecords` 关于非隔离的说明。
    nonisolated private static func fetchPage(
        database: CKDatabase,
        zone: CKRecordZone.ID,
        token: CKServerChangeToken?
    ) async -> FetchOutcome {
        await withCheckedContinuation { continuation in
            let box = FetchOutcomeBox()
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: config])
            op.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    box.update { $0.records.append(record) }
                case .failure(let error):
                    AppLogger.log("sync.pull.error", "Record fetch failed: \(error)")
                    box.update {
                        $0.fetchFailed = true
                        $0.failureReason = "读取 CloudKit 记录失败：\(describe(error))"
                    }
                }
            }
            // App 只做软删除（tombstone 随记录同步），硬删除只可能来自 CloudKit 控制台或数据区重置。
            // 跳过该条并保留本地数据，不让一条外部删除永久阻塞同步游标。
            op.recordWithIDWasDeletedBlock = { recordID, recordType in
                AppLogger.log(
                    "sync.pull.skip",
                    "Skipped remote hard deletion: type=\(recordType) id=\(recordID.recordName); local row kept"
                )
            }
            op.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (token, _, more)):
                    box.update {
                        $0.newToken = token
                        $0.moreComing = more
                    }
                case .failure(let error as CKError) where error.code == .changeTokenExpired:
                    box.update { $0.tokenExpired = true }
                case .failure(let error):
                    AppLogger.log("sync.pull", "Zone fetch error: \(error)")
                    box.update {
                        $0.fetchFailed = true
                        $0.failureReason = "拉取 CloudKit 数据区失败：\(describe(error))"
                    }
                }
            }
            // Process one page per operation; the cursor is committed before the next page.
            op.fetchAllChanges = false
            op.fetchRecordZoneChangesResultBlock = { result in
                if case .failure(let error) = result {
                    if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                        box.update { $0.tokenExpired = true }
                    } else {
                        AppLogger.log("sync.pull.error", "Fetch operation failed: \(error)")
                        box.update {
                            $0.fetchFailed = true
                            $0.failureReason = "CloudKit 拉取操作失败：\(describe(error))"
                        }
                    }
                }
                continuation.resume(returning: box.value())
            }
            database.add(op)
        }
    }

    static func decodeServerToken(_ encoded: String?) throws -> CKServerChangeToken? {
        guard let encoded else { return nil }
        guard let data = Data(base64Encoded: encoded),
              let token = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: data
              ) else {
            throw RustBridgeError.engineError("CloudKit 同步游标损坏。")
        }
        return token
    }

    static func remoteEntries(from records: [CKRecord]) throws -> [[String: Any]] {
        let typeOrder = ["record": 0, "subscription": 1, "asset": 2, "asset_snapshot": 3]
        // Validate the entire page before applying anything or advancing its cursor.
        let entries = try records.map { record -> (Int, [String: Any]) in
            guard let order = typeOrder[record.recordType] else {
                throw RustBridgeError.engineError("CloudKit 包含未知数据类型：\(record.recordType)")
            }
            guard let payload = record["payload"] as? String else {
                throw RustBridgeError.engineError("CloudKit 记录缺少 payload：\(record.recordID.recordName)")
            }
            return (order, ["entity_type": record.recordType, "payload": payload])
        }
        return entries.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func privateDatabase() -> CKDatabase? {
        if let container {
            return container.privateCloudDatabase
        }

        guard cloudKitIsEnabledForProcess() else {
            logUnavailableOnce(
                "CloudKit disabled: this build is not configured and signed for \(containerIdentifier)."
            )
            return nil
        }

        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        return container.privateCloudDatabase
    }

    private func cloudKitIsEnabledForProcess() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        let containerEntitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil as UnsafeMutablePointer<Unmanaged<CFError>?>?
        )
        let serviceEntitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil as UnsafeMutablePointer<Unmanaged<CFError>?>?
        )
        guard let containers = containerEntitlement as? [String],
              let services = serviceEntitlement as? [String] else {
            return false
        }
        return containers.contains(containerIdentifier)
            && (services.contains("CloudKit") || services.contains("CloudKit-Anonymous"))
        #else
        guard let configured = Bundle.main.object(
            forInfoDictionaryKey: "BillLensCloudKitEnabled"
        ) as? String else {
            preconditionFailure("BillLensCloudKitEnabled is missing from the iOS Info.plist")
        }
        switch configured {
        case "YES":
            return true
        case "NO":
            return false
        default:
            preconditionFailure("BillLensCloudKitEnabled must be YES or NO, got \(configured)")
        }
        #endif
    }

    private func logUnavailableOnce(_ message: String) {
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        AppLogger.log("sync.cloudkit", message)
    }
}

// MARK: - Decodable DTOs for FFI responses

public struct SyncDirtyItem: Codable, Sendable {
    public let entityType: String
    public let id: String
    public let payload: String
    public let syncVersion: Int

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case id
        case payload
        case syncVersion = "sync_version"
    }
}

public struct SyncDirtyBatch: Codable, Sendable {
    public let records: [SyncDirtyItem]
    public let subscriptions: [SyncDirtyItem]
    public let assets: [SyncDirtyItem]
    public let assetSnapshots: [SyncDirtyItem]
    public let appSettings: [SyncDirtyItem]

    enum CodingKeys: String, CodingKey {
        case records
        case subscriptions
        case assets
        case assetSnapshots = "asset_snapshots"
        case appSettings = "app_settings"
    }
}

public struct SyncApplyResult: Codable, Sendable {
    public let applied: Int
    public let skipped: Int
}
