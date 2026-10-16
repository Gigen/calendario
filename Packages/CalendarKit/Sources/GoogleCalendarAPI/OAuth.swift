import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The app's Google OAuth client: an "iOS" client ID, used with PKCE and no secret.
public struct GoogleOAuthConfig: Sendable, Equatable {
    public let clientID: String

    public init?(clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(".apps.googleusercontent.com") else { return nil }
        self.clientID = trimmed
    }

    /// `123-abc.apps.googleusercontent.com` -> `com.googleusercontent.apps.123-abc`,
    /// the redirect scheme Google assigns to iOS clients.
    public var reversedClientID: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    public var redirectURI: String { "\(reversedClientID):/oauth2redirect" }
    public var callbackScheme: String { reversedClientID }

    public static let eventsScope = "https://www.googleapis.com/auth/calendar.events.owned"
    public static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    /// Optional: search the Workspace directory for coworkers when adding invitees.
    public static let directoryScope = "https://www.googleapis.com/auth/directory.readonly"

    /// The narrowest scopes that work: create and change events on calendars the user
    /// owns, and read the calendar list (to match Google calendars to the Mac's).
    /// `openid email` identify the account.
    /// `directory.readonly` is optional: personal accounts have no directory, and the
    /// user may uncheck it; everything except coworker suggestions works without it.
    public static let scopes = ["openid", "email", eventsScope, calendarListScope, directoryScope]
    public static let requiredScopes: Set<String> = [eventsScope, calendarListScope]

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
}

/// Proof Key for Code Exchange (RFC 7636), S256.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// A random 64-character verifier from the unreserved character set.
    public static func generate() -> PKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        return PKCE(verifier: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
        #else
        #error("A SHA-256 implementation is needed on this platform (e.g. swift-crypto).")
        #endif
    }
}

/// One sign-in attempt: the URL to open, and validation of the redirect it ends in.
public struct AuthorizationRequest: Sendable {
    public let config: GoogleOAuthConfig
    public let pkce: PKCE
    public let state: String
    public let loginHint: String?

    public init(config: GoogleOAuthConfig, pkce: PKCE = .generate(), state: String = UUID().uuidString, loginHint: String? = nil) {
        self.config = config
        self.pkce = pkce
        self.state = state
        self.loginHint = loginHint
    }

    public var url: URL {
        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Let the user pick among signed-in accounts, and always return a refresh token.
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        if let loginHint {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        return components.url!
    }

    /// The authorization code from the redirect, after checking `state`.
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? GoogleAPIError.userCancelled : GoogleAPIError.authorizationFailed(error)
        }
        guard value("state") == state else { throw GoogleAPIError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAPIError.invalidResponse }
        return code
    }

    public func tokenRequest(code: String) -> HTTPRequest {
        .form(GoogleOAuthConfig.tokenEndpoint, [
            ("client_id", config.clientID),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", config.redirectURI),
        ])
    }
}

/// The token endpoint's reply.
public struct TokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let scope: String?
    public let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
    }

    public var grantedScopes: Set<String> {
        Set((scope ?? "").split(separator: " ").map(String.init))
    }

    /// The account email from the ID token. The token came straight from Google's
    /// token endpoint over TLS, so reading the payload without verifying the
    /// signature is fine (Google's guidance for this case).
    public var email: String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        struct Claims: Decodable { let email: String? }
        return (try? JSONDecoder().decode(Claims.self, from: payload))?.email?.lowercased()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
