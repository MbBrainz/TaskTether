
//
//  GoogleAuthManager.swift
//  TaskTether
//
//  Created by Hazim Sami on 10/03/2026.
//

import Foundation
import Combine
import AppKit
import CryptoKit

class GoogleAuthManager: ObservableObject {

    @Published var isAuthenticated = false
    @Published var isAuthenticating = false
    @Published var errorMessage: String? = nil

    private var clientId: String = ""
    private var clientSecret: String = ""
    private var accessToken: String? = nil
    private var refreshToken: String? = nil

    // Built per sign-in attempt from the ephemeral port the local listener
    // reports — see LocalHTTPServer.start. Also used by the token exchange,
    // which must send the exact redirect_uri the auth request used.
    private var redirectURI = ""
    private let scope = "https://www.googleapis.com/auth/tasks"
    private let server = LocalHTTPServer()

    // CSRF/PKCE material for the in-flight sign-in attempt only. Set at the
    // start of signIn(), consumed exactly once by handleCallback(), and
    // cleared immediately after — a captured or replayed redirect can't be
    // used to exchange a code a second time.
    private var pendingState: String?
    private var pendingCodeVerifier: String?

    init() {
        loadCredentials()
        loadTokensFromKeychain()
    }

    // MARK: - Setup

    private func loadCredentials() {
        guard let credentialsURL = Bundle.main.url(forResource: "GoogleCredentials", withExtension: "json"),
              let data = try? Data(contentsOf: credentialsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              let secret = installed["client_secret"] as? String else {
            errorMessage = String(localized: "error.credentials")
            return
        }
        clientId = id
        clientSecret = secret
    }

    // MARK: - Sign In

    func signIn() {
        isAuthenticating = true
        errorMessage = nil

        // Tear down any stale listener from a previous abandoned attempt
        // before starting a new one — otherwise the port stays locked.
        server.stop()

        let state = randomBase64URLToken()
        let verifier = randomBase64URLToken()
        pendingState = state
        pendingCodeVerifier = verifier
        let challenge = codeChallenge(for: verifier)

        // Start the local listener on an ephemeral port. The browser is only
        // opened AFTER the listener reports it is ready — opening it earlier
        // (as the old fixed-port code did) let the user approve access while
        // nothing of ours was listening, silently losing the auth code.
        server.start(
            onResult: { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleCallback(result)
                }
            },
            onReady: { [weak self] port in
                DispatchQueue.main.async {
                    self?.openAuthURL(port: port, state: state, codeChallenge: challenge)
                }
            }
        )
    }

    private func openAuthURL(port: UInt16?, state: String, codeChallenge: String) {
        guard let port else {
            errorMessage = String(localized: "error.auth.port")
            isAuthenticating = false
            server.stop()
            clearPendingAuthState()
            return
        }

        // 127.0.0.1, not "localhost" — the listener binds the loopback
        // IPv4 address only, and some browsers resolve "localhost" to ::1
        // first, which would never reach it. Google's desktop OAuth clients
        // explicitly support (and recommend) a literal loopback IP here.
        redirectURI = "http://127.0.0.1:\(port)"

        // Build the Google auth URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            errorMessage = String(localized: "error.auth.url")
            isAuthenticating = false
            server.stop()
            clearPendingAuthState()
            return
        }

        // Open in the user's default browser
        NSWorkspace.shared.open(authURL)
    }

    // MARK: - Callback Handling

    /// Handles the local server's result: an access-denied redirect, a
    /// malformed/CSRF-suspect one (missing or non-matching `state`), or a
    /// valid code+state pair ready for token exchange.
    private func handleCallback(_ result: Result<AuthCallback, Error>) {
        switch result {
        case .success(let callback):
            guard let verifier = pendingCodeVerifier, stateMatches(callback.state) else {
                clearPendingAuthState()
                DispatchQueue.main.async {
                    self.isAuthenticating = false
                    self.errorMessage = String(localized: "error.auth.token")
                }
                return
            }
            clearPendingAuthState()
            exchangeCodeForTokens(code: callback.code, codeVerifier: verifier)
        case .failure:
            clearPendingAuthState()
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.errorMessage = String(localized: "error.auth.token")
            }
        }
    }

    private func stateMatches(_ received: String?) -> Bool {
        guard let expected = pendingState, let received, expected == received else { return false }
        return true
    }

    private func clearPendingAuthState() {
        pendingState = nil
        pendingCodeVerifier = nil
    }

    // MARK: - PKCE / State

    /// 32 random bytes, base64url-encoded (no padding) — 43 characters,
    /// suitable for both the OAuth `state` parameter and a PKCE
    /// `code_verifier` (RFC 7636 requires 43-128 characters).
    private func randomBase64URLToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                DispatchQueue.main.async {
                    self.isAuthenticating = false
                    self.errorMessage = String(localized: "error.auth.token")
                }
                return
            }

            self.accessToken = accessToken
            self.refreshToken = json["refresh_token"] as? String
            self.saveTokensToKeychain()

            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.isAuthenticated = true
            }
        }.resume()
    }

    // MARK: - Sign Out

    func signOut() {
        accessToken  = nil
        refreshToken = nil
        clearTokensFromKeychain()
        server.stop()
        clearPendingAuthState()

        DispatchQueue.main.async {
            self.isAuthenticated = false
            // Close any open Settings window so ContentView immediately
            // shows ConnectView — without this the user has no visual
            // confirmation that sign out happened.
            NSApp.windows
                .filter { $0.title.contains("Settings") || $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
                .forEach { $0.close() }
        }
    }

    // MARK: - Token Access

    func getAccessToken() -> String? {
        return accessToken
    }

    // MARK: - Token Refresh
    // Called by SyncEngine when a request returns 401.
    // On success, updates the stored access token and calls completion(true).
    // On failure, signs the user out and calls completion(false).

    func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        guard let refresh = refreshToken else {
            DispatchQueue.main.async { self.signOut() }
            completion(false)
            return
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id":     clientId,
            "client_secret": clientSecret,
            "refresh_token": refresh,
            "grant_type":    "refresh_token"
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String else {
                DispatchQueue.main.async { self.signOut() }
                completion(false)
                return
            }
            self.accessToken = newToken
            self.saveTokensToKeychain()
            completion(true)
        }.resume()
    }

    // MARK: - Keychain

    private func saveTokensToKeychain() {
        if let access = accessToken {
            saveToKeychain(key: "tasktether_access_token", value: access)
        }
        if let refresh = refreshToken {
            saveToKeychain(key: "tasktether_refresh_token", value: refresh)
        }
    }

    private func loadTokensFromKeychain() {
        // Migrate any tokens saved without kSecAttrService (pre-fix builds).
        // Reads the old-style entry, re-saves with service key, deletes the old one.
        // Safe to call on every launch — no-op if already migrated.
        migrateKeychainEntryIfNeeded(key: "tasktether_access_token")
        migrateKeychainEntryIfNeeded(key: "tasktether_refresh_token")

        accessToken  = loadFromKeychain(key: "tasktether_access_token")
        refreshToken = loadFromKeychain(key: "tasktether_refresh_token")

        guard accessToken != nil else { return }

        if refreshToken != nil {
            // Refresh token present — proactively refresh the access token on
            // launch so we never start with an expired token.
            #if DEBUG
            print("GoogleAuthManager: refreshing access token on launch...")
            #endif
            refreshAccessToken { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.isAuthenticated = true
                        #if DEBUG
                        print("GoogleAuthManager: token refreshed ✅")
                        #endif
                    } else {
                        // Refresh failed (revoked) — clear and require re-auth.
                        #if DEBUG
                        print("GoogleAuthManager: refresh failed — clearing tokens, re-auth required")
                        #endif
                        self?.signOut()
                    }
                }
            }
        } else {
            // Access token with no refresh token — almost certainly stale.
            // Clear and require the user to connect again.
            #if DEBUG
            print("GoogleAuthManager: stale token with no refresh — clearing, re-auth required")
            #endif
            signOut()
        }
    }

    private func clearTokensFromKeychain() {
        deleteFromKeychain(key: "tasktether_access_token")
        deleteFromKeychain(key: "tasktether_refresh_token")
    }

    // Reads a token stored without kSecAttrService (pre-fix builds),
    // re-saves it with the service key, then deletes the legacy entry.
    private func migrateKeychainEntryIfNeeded(key: String) {
        // Try reading the legacy entry (no service key)
        let legacyQuery: [String: Any] = [
            kSecClass as String:      kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return }

        // Re-save with service key
        saveToKeychain(key: key, value: value)

        // Delete the legacy entry
        SecItemDelete(legacyQuery as CFDictionary)

        #if DEBUG
        print("GoogleAuthManager: migrated keychain entry '\(key)' ✅")
        #endif
    }

    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.hazim.TaskTether",
            kSecAttrAccount as String: key,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        #if DEBUG
        if status != errSecSuccess {
            print("GoogleAuthManager: keychain save failed for '\(key)' — status \(status)")
        }
        #endif
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.hazim.TaskTether",
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.hazim.TaskTether",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    /// RFC 4648 base64url, unpadded — used for the OAuth `state` value and
    /// PKCE `code_verifier`/`code_challenge`.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

