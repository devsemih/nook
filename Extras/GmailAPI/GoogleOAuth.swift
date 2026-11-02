import AppKit
import AuthenticationServices
import CryptoKit

nonisolated struct GoogleTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

nonisolated enum GoogleOAuthError: LocalizedError {
    case missingClientID
    case invalidClientID
    case cancelled
    case noRefreshToken
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Önce Google client ID'sini girmen gerekiyor."
        case .invalidClientID: "Client ID “…apps.googleusercontent.com” ile bitmeli. Google Cloud'da iOS türünde oluşturduğun ID'yi kopyala."
        case .cancelled: "Giriş tamamlanmadı. Hazır olduğunda tekrar deneyebilirsin."
        case .noRefreshToken: "Google uzun süreli oturum anahtarı vermedi. Tekrar dene."
        case .server(let message): message
        }
    }
}

/// Google OAuth 2.0 + PKCE. Kendi Google Cloud projendeki "iOS" türü client ID ile çalışır;
/// client secret gerekmez, dönüş adresi ters çevrilmiş client ID şemasıdır.
@MainActor
final class GoogleOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static let clientIDKey = "googleClientID"
    nonisolated static let scope = "openid email profile https://www.googleapis.com/auth/gmail.modify"

    struct SignInResult: Sendable {
        var tokens: GoogleTokens
        var email: String
        var name: String
    }

    nonisolated static var clientID: String? {
        let value = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated static func isValidClientID(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).hasSuffix(".apps.googleusercontent.com")
    }

    /// 123-abc.apps.googleusercontent.com → com.googleusercontent.apps.123-abc
    nonisolated static func redirectScheme(for clientID: String) -> String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }

    private var session: ASWebAuthenticationSession?
    private let window: NSWindow?

    private init(window: NSWindow?) {
        self.window = window
    }

    static func signIn(loginHint: String? = nil, window: NSWindow?) async throws -> SignInResult {
        guard let clientID else { throw GoogleOAuthError.missingClientID }
        guard isValidClientID(clientID) else { throw GoogleOAuthError.invalidClientID }
        let oauth = GoogleOAuth(window: window)
        let verifier = randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let scheme = redirectScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items

        let callback = try await oauth.authenticate(url: components.url!, scheme: scheme)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            let error = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "error" })?.value
            throw error == "access_denied" ? GoogleOAuthError.cancelled : GoogleOAuthError.server(error ?? "Google bir kod döndürmedi.")
        }

        let response = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refreshToken = response.refreshToken else { throw GoogleOAuthError.noRefreshToken }
        let tokens = GoogleTokens(accessToken: response.accessToken, refreshToken: refreshToken, expiry: Date.now.addingTimeInterval(TimeInterval(response.expiresIn)))
        let claims = response.idToken.flatMap(decodeIDToken) ?? [:]
        let email = (claims["email"] as? String) ?? ""
        let name = (claims["name"] as? String) ?? (claims["given_name"] as? String) ?? ""
        return SignInResult(tokens: tokens, email: email, name: name)
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleOAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleOAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleOAuthError.server("Giriş penceresi açılamadı."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            window ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        }
    }

    // MARK: Token

    /// Süresi dolan erişim anahtarını yeniler. Google yenilemeyi reddederse hesap yeniden giriş ister.
    nonisolated static func refresh(_ tokens: GoogleTokens) async throws -> GoogleTokens {
        guard let clientID else { throw GoogleOAuthError.missingClientID }
        do {
            let response = try await tokenRequest([
                "client_id": clientID,
                "refresh_token": tokens.refreshToken,
                "grant_type": "refresh_token",
            ])
            return GoogleTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? tokens.refreshToken,
                expiry: Date.now.addingTimeInterval(TimeInterval(response.expiresIn))
            )
        } catch GoogleOAuthError.server(let message) where message.contains("invalid_grant") || message.contains("unauthorized_client") {
            throw ProviderError.authenticationRequired
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private nonisolated static func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = body?["error"] as? String ?? "bilinmeyen hata"
            let description = body?["error_description"] as? String ?? ""
            throw GoogleOAuthError.server("Google: \(error) \(description)".trimmingCharacters(in: .whitespaces))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private nonisolated static func decodeIDToken(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

nonisolated extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
