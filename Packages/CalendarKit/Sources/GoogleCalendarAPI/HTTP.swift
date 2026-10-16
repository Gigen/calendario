import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// An `application/x-www-form-urlencoded` POST, as OAuth token endpoints expect.
    public static func form(_ url: URL, _ fields: [(String, String)]) -> HTTPRequest {
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The network seam: URLSession in the app, a fake in tests.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}

public enum GoogleAPIError: Error, Equatable, Sendable {
    /// No client ID configured in the build.
    case notConfigured
    case userCancelled
    /// The OAuth redirect didn't match the request (possible forgery).
    case stateMismatch
    case authorizationFailed(String)
    /// The user unchecked calendar access on Google's consent screen.
    case missingScopes
    /// The refresh token stopped working; the user must connect the account again.
    case needsReauthentication(email: String)
    case accountNotConnected(email: String)
    case http(status: Int, message: String)
    case invalidResponse
    /// The event created through Google couldn't be found again to update it.
    case eventNotFound
}

extension GoogleAPIError {
    /// Google's error payload: `{"error": {"message": "..."}}` or OAuth's
    /// `{"error": "invalid_grant", "error_description": "..."}`.
    static func from(_ response: HTTPResponse) -> GoogleAPIError {
        struct APIError: Decodable { struct Body: Decodable { let message: String? }; let error: Body }
        struct OAuthError: Decodable { let error: String; let error_description: String? }
        if let api = try? JSONDecoder().decode(APIError.self, from: response.body), let message = api.error.message {
            return .http(status: response.status, message: message)
        }
        if let oauth = try? JSONDecoder().decode(OAuthError.self, from: response.body) {
            return .http(status: response.status, message: oauth.error_description ?? oauth.error)
        }
        return .http(status: response.status, message: String(decoding: response.body.prefix(300), as: UTF8.self))
    }
}
