import Foundation
import CloudKit
#if os(macOS)
import Security
#endif
import BillLensAppleServices

/// Handles bidirectional CloudKit sync for all entity types.
/// Rust owns data/conflict logic; this service owns transport only.
public final class CloudKitSyncService: @unchecked Sendable {
    public static let shared = CloudKitSyncService()

    private let zoneName = "BillLensZone"
    private let containerIdentifier = "iCloud.com.shendongchun.BillLensApple"
    private var container: CKContainer?
    private var isPushScheduled = false
    private var didEnsureZoneAndSubscription = false
    private var didLogUnavailable = false
    private var bridge: RustBridge?
    private var profileID: String = "local-default"

    private init() {}

    // MARK: - Entry Points

    public func configure(bridge: RustBridge, profileID: String) {
        self.bridge = bridge
        self.profileID = profileID
    }

    public func pullThenPush(bridge: RustBridge, profileID: String) {
        configure(bridge: bridge, profileID: profileID)
        Task.detached(priority: .background) { [weak self] in
            guard await self?.ensureZoneAndSubscription() == true else { return }
            await self?.pull()
            await self?.push()
        }
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
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.resetScheduleFlag()
            await self?.push()
        }
    }

    public func handleRemoteNotification() {
        Task.detached(priority: .background) { [weak self] in
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
        guard let privateDB = privateDatabase() else { return false }

        let zone = CKRecordZone(zoneName: zoneName)
        do {
            try await privateDB.save(zone)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // zone already exists
        } catch {
            AppLogger.log("sync.zone", "Failed to create zone: \(error)")
            return false
        }

        let subID = CKSubscription.ID("billlens-db-changes")
        let sub = CKDatabaseSubscription(subscriptionID: subID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        sub.notificationInfo = notificationInfo
        do {
            try await privateDB.save(sub)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // subscription already exists
        } catch {
            AppLogger.log("sync.subscription", "Failed to create subscription: \(error)")
            return false
        }
        didEnsureZoneAndSubscription = true
        return true
    }

    // MARK: - Push (local → CloudKit)

    private func push() async {
        guard let bridge else { return }
        guard await ensureZoneAndSubscription() else { return }
        guard let privateDB = privateDatabase() else { return }
        // app_setting excluded: llm_config payload contains api_key; keep credentials local-only.
        let entityTypes = ["record", "subscription", "asset", "asset_snapshot"]
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        while true {
            guard let dirtyBatch: SyncDirtyBatch = try? await bridge.sendAsync([
                "action": "sync_list_dirty",
                "profile_id": profileID,
                "entity_types": entityTypes,
                "limit": 200
            ]) else { break }

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
        return await withCheckedContinuation { continuation in
            let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            // .allKeys unconditionally overwrites each field — correct for a LWW opaque payload
            // where we always hold the full entity state and never partial-update individual keys.
            op.savePolicy = .allKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    var entries: [[String: Any]] = []
                    for record in records {
                        if let item = itemsByID[record.recordID.recordName] {
                            entries.append([
                                "entity_type": item.entityType,
                                "id": item.id,
                                "synced_version": item.syncVersion
                            ])
                        }
                    }
                    Task {
                        let _: [String: Int] = (try? await bridge.sendAsync([
                            "action": "sync_mark_synced",
                            "entries": entries
                        ])) ?? [:]
                        continuation.resume(returning: true)
                    }
                case .failure(let error):
                    AppLogger.log("sync.push", "Push failed: \(error)")
                    continuation.resume(returning: false)
                }
            }
            database.add(op)
        }
    }

    // MARK: - Pull (CloudKit → local)

    /// Returns true only when remote state was fully fetched and applied to the local DB.
    @discardableResult
    private func pull() async -> Bool {
        guard let bridge else { return false }
        guard let privateDB = privateDatabase() else { return false }
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        struct CursorResponse: Decodable { let token: String? }
        struct FetchOutcome {
            var records: [CKRecord] = []
            var newToken: CKServerChangeToken?
            var tokenExpired = false
            var fetchFailed = false
            var moreComing = false
        }

        var didClearOnExpiry = false
        while true {
            let cursorResp: CursorResponse? = try? await bridge.sendAsync([
                "action": "sync_get_cursor",
                "profile_id": profileID,
                "zone": zoneName
            ])
            var serverToken: CKServerChangeToken? = nil
            if let tokenStr = cursorResp?.token, let data = Data(base64Encoded: tokenStr) {
                serverToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            }

            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<FetchOutcome, Never>) in
                var out = FetchOutcome()
                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                config.previousServerChangeToken = serverToken
                let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: config])
                op.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result { out.records.append(record) }
                }
                op.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let (token, _, more)):
                        out.newToken = token
                        out.moreComing = more
                    case .failure(let error as CKError) where error.code == .changeTokenExpired:
                        out.tokenExpired = true
                    case .failure(let error):
                        AppLogger.log("sync.pull", "Zone fetch error: \(error)")
                        out.fetchFailed = true
                    }
                }
                op.fetchRecordZoneChangesResultBlock = { _ in continuation.resume(returning: out) }
                privateDB.add(op)
            }

            if outcome.tokenExpired {
                if didClearOnExpiry { return false }
                didClearOnExpiry = true
                let _: [String: String] = (try? await bridge.sendAsync([
                    "action": "sync_set_cursor",
                    "profile_id": profileID,
                    "zone": zoneName,
                    "token": NSNull()
                ])) ?? [:]
                continue
            }
            if outcome.fetchFailed { return false }

            if !outcome.records.isEmpty {
                // Apply parent entities (assets) before children (asset_snapshots) to satisfy FK ordering.
                let typeOrder: [String: Int] = ["record": 0, "subscription": 1, "asset": 2, "asset_snapshot": 3]
                let entries: [[String: Any]] = outcome.records
                    .sorted { (typeOrder[$0.recordType] ?? 99) < (typeOrder[$1.recordType] ?? 99) }
                    .compactMap { record in
                        guard let payload = record["payload"] as? String else { return nil }
                        return ["entity_type": record.recordType, "payload": payload]
                    }
                let result: SyncApplyResult? = try? await bridge.sendAsync([
                    "action": "sync_apply_remote",
                    "entries": entries
                ])
                if result == nil {
                    AppLogger.log("sync.pull", "sync_apply_remote failed; cursor not advanced")
                    return false
                }
            }

            if let token = outcome.newToken,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                let tokenStr = data.base64EncodedString()
                let _: [String: String] = (try? await bridge.sendAsync([
                    "action": "sync_set_cursor",
                    "profile_id": profileID,
                    "zone": zoneName,
                    "token": tokenStr
                ])) ?? [:]
            }

            if !outcome.moreComing { return true }
        }
    }

    @MainActor
    private func resetScheduleFlag() {
        isPushScheduled = false
    }

    private func privateDatabase() -> CKDatabase? {
        if let container {
            return container.privateCloudDatabase
        }

        guard processHasCloudKitEntitlement() else {
            logUnavailableOnce(
                "CloudKit disabled: missing entitlement for \(containerIdentifier). Use the signed Xcode/package build with BillLensMacApp.entitlements or BillLensIOSApp.entitlements."
            )
            return nil
        }

        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        return container.privateCloudDatabase
    }

    private func processHasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil as UnsafeMutablePointer<Unmanaged<CFError>?>?
        )
        guard let containers = entitlement as? [String] else { return false }
        return containers.contains(containerIdentifier)
        #else
        // SecTask entitlement inspection is macOS-only. iOS builds get their CloudKit
        // capability from the generated Xcode project entitlements.
        return true
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
