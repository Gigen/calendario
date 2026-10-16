import Foundation
#if canImport(Security)
import Security
#endif

/// What's kept per connected Google account.
public struct StoredCredential: Codable, Sendable, Equatable {
    public var email: String
    public var refreshToken: String
    public var accessToken: String?
    public var accessTokenExpiry: Date?
    /// Set when Google rejected the refresh token; the user must connect again.
    public var needsReauthentication: Bool
    /// What the user allowed. `nil` for credentials saved before this was recorded.
    public var grantedScopes: [String]?

    public init(
        email: String, refreshToken: String, accessToken: String? = nil, accessTokenExpiry: Date? = nil,
        needsReauthentication: Bool = false, grantedScopes: [String]? = nil
    ) {
        self.email = email
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.needsReauthentication = needsReauthentication
        self.grantedScopes = grantedScopes
    }
}

public protocol TokenStore: Sendable {
    func loadAll() throws -> [StoredCredential]
    func save(_ credential: StoredCredential) throws
    func delete(email: String) throws
}

/// For tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: StoredCredential] = [:]

    public init(_ initial: [StoredCredential] = []) {
        for credential in initial { credentials[credential.email] = credential }
    }

    public func loadAll() throws -> [StoredCredential] {
        lock.withLock { Array(credentials.values).sorted { $0.email < $1.email } }
    }

    public func save(_ credential: StoredCredential) throws {
        lock.withLock { credentials[credential.email] = credential }
    }

    public func delete(email: String) throws {
        lock.withLock { credentials[email] = nil }
    }
}

#if canImport(Security)
/// One generic-password Keychain item per Google account, keyed by email.
///
/// Uses the classic file-based keychain: the data-protection keychain needs a
/// keychain-access-groups entitlement and therefore a provisioning profile, which
/// a free Personal Team can't rely on. Items are only readable by this app's
/// signing identity.
public struct KeychainTokenStore: TokenStore {
    public let service: String

    /// `service` names the Keychain items, e.g. "<bundle ID>.google-oauth".
    public init(service: String) {
        self.service = service
    }

    public func loadAll() throws -> [StoredCredential] {
        // The file-based keychain can't return data for many items at once, so list
        // the accounts first, then read each one.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw KeychainError(status: status) }
        let emails = items.compactMap { $0[kSecAttrAccount as String] as? String }
        return try emails.compactMap(load(email:)).sorted { $0.email < $1.email }
    }

    func load(email: String) throws -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    public func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.email,
        ]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Calendario: Google account \(credential.email)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(email: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}
#endif
