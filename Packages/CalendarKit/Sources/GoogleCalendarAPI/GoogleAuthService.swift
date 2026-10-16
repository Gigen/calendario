import Foundation

/// Connected Google accounts and their tokens. Hands out access tokens, refreshing
/// them silently; concurrent callers share one refresh per account.
public actor GoogleAuthService {
    public struct Account: Sendable, Equatable, Identifiable {
        public var email: String
        public var needsReauthentication: Bool
        /// The user allowed searching their Workspace directory.
        public var canSearchDirectory: Bool
        public var id: String { email }
    }

    public nonisolated let config: GoogleOAuthConfig
    private let http: any HTTPClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date
    private var credentials: [String: StoredCredential] = [:]
    private var refreshes: [String: Task<String, Error>] = [:]
    private var loaded = false

    public init(config: GoogleOAuthConfig, http: any HTTPClient, store: any TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.http = http
        self.store = store
        self.now = now
    }

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        try loadIfNeeded()
        return credentials.values
            .map { credential in
                Account(
                    email: credential.email,
                    needsReauthentication: credential.needsReauthentication,
                    canSearchDirectory: credential.grantedScopes?.contains(GoogleOAuthConfig.directoryScope) ?? false
                )
            }
            .sorted { $0.email < $1.email }
    }

    /// Finishes a sign-in: exchanges the code from the redirect for tokens and stores
    /// them. Returns the connected account's email.
    public func completeSignIn(_ request: AuthorizationRequest, callback: URL) async throws -> String {
        try loadIfNeeded()
        let code = try request.code(from: callback)
        let response = try await http.send(request.tokenRequest(code: code))
        guard response.isSuccess else { throw GoogleAPIError.from(response) }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: response.body)

        // With granular consent the user may uncheck calendar access.
        guard GoogleOAuthConfig.requiredScopes.isSubset(of: tokens.grantedScopes) else {
            throw GoogleAPIError.missingScopes
        }
        guard let email = tokens.email else { throw GoogleAPIError.invalidResponse }
        // Google normally returns a refresh token on every consent; keep the old one if not.
        guard let refreshToken = tokens.refreshToken ?? credentials[email]?.refreshToken else {
            throw GoogleAPIError.invalidResponse
        }
        let credential = StoredCredential(
            email: email,
            refreshToken: refreshToken,
            accessToken: tokens.accessToken,
            accessTokenExpiry: now().addingTimeInterval(TimeInterval(tokens.expiresIn)),
            grantedScopes: Array(tokens.grantedScopes).sorted()
        )
        try store.save(credential)
        credentials[email] = credential
        return email
    }

    /// Revokes the token at Google (best effort) and forgets the account.
    public func disconnect(email: String) async throws {
        try loadIfNeeded()
        if let token = credentials[email]?.refreshToken {
            _ = try? await http.send(.form(GoogleOAuthConfig.revokeEndpoint, [("token", token)]))
        }
        try store.delete(email: email)
        credentials[email] = nil
        refreshes[email]?.cancel()
        refreshes[email] = nil
    }

    // MARK: Tokens

    /// A valid access token, refreshed if it expires within a minute (or if `forceRefresh`).
    public func accessToken(for email: String, forceRefresh: Bool = false) async throws -> String {
        try loadIfNeeded()
        guard let credential = credentials[email] else { throw GoogleAPIError.accountNotConnected(email: email) }
        if credential.needsReauthentication { throw GoogleAPIError.needsReauthentication(email: email) }
        if !forceRefresh, let token = credential.accessToken, let expiry = credential.accessTokenExpiry,
           expiry.timeIntervalSince(now()) > 60 {
            return token
        }
        if let running = refreshes[email] {
            return try await running.value
        }
        let task = Task { try await refresh(credential) }
        refreshes[email] = task
        defer { refreshes[email] = nil }
        return try await task.value
    }

    private func refresh(_ credential: StoredCredential) async throws -> String {
        let request = HTTPRequest.form(GoogleOAuthConfig.tokenEndpoint, [
            ("client_id", config.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", credential.refreshToken),
        ])
        let response = try await http.send(request)
        guard response.isSuccess else {
            // invalid_grant: revoked, expired (e.g. 6 months unused) or password changed.
            if response.status == 400 || response.status == 401,
               String(decoding: response.body, as: UTF8.self).contains("invalid_grant") {
                var stale = credential
                stale.needsReauthentication = true
                stale.accessToken = nil
                try? store.save(stale)
                credentials[credential.email] = stale
                throw GoogleAPIError.needsReauthentication(email: credential.email)
            }
            throw GoogleAPIError.from(response)
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        var updated = credential
        updated.accessToken = tokens.accessToken
        updated.accessTokenExpiry = now().addingTimeInterval(TimeInterval(tokens.expiresIn))
        if let rotated = tokens.refreshToken { updated.refreshToken = rotated }
        if tokens.scope != nil { updated.grantedScopes = Array(tokens.grantedScopes).sorted() }
        try store.save(updated)
        credentials[credential.email] = updated
        return tokens.accessToken
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        for credential in try store.loadAll() {
            credentials[credential.email] = credential
        }
        loaded = true
    }
}
