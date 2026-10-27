import Foundation

/// iCloud 邮箱（IMAP）的连接信息：邮箱地址 + App 专用密码，只存本机钥匙串。
public struct ICloudMailCredentialStore: Sendable {
    public struct Stored: Codable, Equatable, Sendable {
        public var accountAddress: String
        public var appPassword: String

        public init(accountAddress: String, appPassword: String) {
            self.accountAddress = accountAddress
            self.appPassword = appPassword
        }
    }

    public static let shared = ICloudMailCredentialStore()

    private let item: KeychainJSONItem<Stored>

    public init(service: String = "com.shendongchun.BillLensApple.icloud-mail") {
        item = KeychainJSONItem(service: service, account: "icloud")
    }

    public var connectedAddress: String? { load()?.accountAddress }

    public func load() -> Stored? { item.load() }
    public func save(_ stored: Stored) throws { try item.save(stored) }
    public func delete() { item.delete() }
}
