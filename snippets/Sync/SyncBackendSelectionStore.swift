import Foundation
import AuthenticationServices
import CryptoKit
import Security

/// The durable revocation journal is authoritative when a refresh rotated credentials
/// but process death happened before the primary session could be replaced.
struct SnippetsCloudCredentialRevocationPlan: Equatable {
    let accessTokens: [String]
    let refreshTokens: [String]

    init(
        sessionAccessToken: String?,
        sessionRefreshToken: String?,
        journalAccessTokens: [String],
        journalRefreshTokens: [String]
    ) {
        accessTokens = Self.orderedUnique(
            journalAccessTokens + [sessionAccessToken].compactMap { $0 })
        refreshTokens = Self.orderedUnique(
            journalRefreshTokens + [sessionRefreshToken].compactMap { $0 })
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Shares one refresh exchange across every transport/UI OAuth client in this process.
/// MainActor alone does not serialize across an awaited token request, so an explicit
/// single-flight gate prevents two rotations from producing an untracked credential.
@MainActor
final class SnippetsCloudRefreshSingleFlight {
    private struct Flight {
        let id: UUID
        let task: Task<String, Error>
    }

    private var flight: Flight?
    var isActive: Bool { flight != nil }

    func run(
        _ operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        if let flight { return try await flight.task.value }
        let id = UUID()
        let task = Task { @MainActor in try await operation() }
        flight = Flight(id: id, task: task)
        defer {
            if flight?.id == id { flight = nil }
        }
        return try await task.value
    }

    func drain() async {
        guard let flight else { return }
        _ = await flight.task.result
    }
}

/// Stores the active sync provider without coupling either transport to Settings UI.
///
/// Non-secret coordinates live in UserDefaults. OIDC access/refresh tokens are
/// device-only Keychain data: they are not synchronized through iCloud Keychain and
/// are never written to diagnostics. Changing this selection does not delete either
/// provider's data.
@MainActor
final class SyncBackendSelectionStore {
    enum Provider: String, CaseIterable {
        case iCloud = "icloud"
        case snippetsCloud = "snippets-cloud"

        var displayName: String {
            switch self {
            case .iCloud: "iCloud"
            case .snippetsCloud: "Snippets Cloud"
            }
        }
    }

    struct CloudCoordinates: Equatable {
        var serverURL: URL
        var spaceID: UUID
    }

    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case missingConfiguration
        case missingCredential
        case invalidCredential

        var description: String {
            switch self {
            case .missingConfiguration: "Snippets Cloud is not configured"
            case .missingCredential: "Snippets Cloud needs sign-in"
            case .invalidCredential: "the stored Snippets Cloud credential is invalid"
            }
        }

        var errorDescription: String? { description }
    }

    static let providerDefaultsKey = "SnippetsSyncProvider"
    static let pendingSwitchDefaultsKey = "SnippetsSyncProviderSwitchPending"
    private static let serverDefaultsKey = "SnippetsCloudServerURL"
    private static let spaceDefaultsKey = "SnippetsCloudSpaceID"
    private static let tokenAccount = "oidc-access-token-v1"
    static let oauthSessionAccount = "oidc-session-v1"
    static let oauthRevocationAccount = "oidc-revocation-journal-v1"
    static let pendingLocalEraseAccount = "cloud-local-erase-v1"
    fileprivate static let credentialService = "com.khm.snippets.sync-http"

    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore
    private let bootstrapSecretsForRecovery: KeychainSecretStore
    let cloudKeys: SnippetsCloudKeyStore

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainSecretStore? = nil,
        cloudKeys: SnippetsCloudKeyStore? = nil,
        bootstrapSecrets: KeychainSecretStore? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: Self.credentialService,
            itemAccessibility: .afterFirstUnlock)
        self.bootstrapSecretsForRecovery = bootstrapSecrets ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: SnippetsCloudAccountBootstrap.bootstrapService,
            itemAccessibility: .afterFirstUnlock)
        self.cloudKeys = cloudKeys ?? SnippetsCloudKeyStore(coordinates: {
            Self.cloudCoordinates(in: defaults)
        })
        // A successful remote logout writes this journal before deleting any local
        // secret. Finishing it during normal app construction makes process death at
        // every subsequent deletion boundary recoverable and fail-closed.
        try? resumePendingLocalErase()
        if hasPendingRemoteRevocation {
            // The remote intent journal is written before the first logout request and
            // retained through provider success. A crash in the network/local handoff
            // therefore resumes idempotently instead of leaving a usable local root.
            Task { @MainActor [weak self] in
                try? await self?.resumeInterruptedSignOut()
            }
        }
    }

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: Self.providerDefaultsKey) ?? "") ?? .iCloud }
        set { defaults.set(newValue.rawValue, forKey: Self.providerDefaultsKey) }
    }

    var cloudCoordinates: CloudCoordinates? {
        guard !hasPendingLocalErase else { return nil }
        return Self.cloudCoordinates(in: defaults)
    }

    var hasPendingLocalErase: Bool {
        keychain.hasItem(account: Self.pendingLocalEraseAccount)
    }

    var hasPendingRemoteRevocation: Bool {
        keychain.hasItem(account: Self.oauthRevocationAccount)
    }

    private static func cloudCoordinates(in defaults: UserDefaults) -> CloudCoordinates? {
        guard let rawURL = defaults.string(forKey: Self.serverDefaultsKey),
              let url = URL(string: rawURL),
              let rawSpace = defaults.string(forKey: Self.spaceDefaultsKey),
              let spaceID = UUID(uuidString: rawSpace) else { return nil }
        return CloudCoordinates(serverURL: url, spaceID: spaceID)
    }

    var hasPendingProviderSwitch: Bool {
        defaults.bool(forKey: Self.pendingSwitchDefaultsKey)
    }

    func selectICloud() {
        markSwitch(to: .iCloud)
    }

    func selectSnippetsCloud(
        serverURL: URL,
        spaceID: UUID,
        accessToken: String
    ) throws {
        guard !hasPendingLocalErase, !hasPendingRemoteRevocation else {
            throw Failure.missingCredential
        }
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: serverURL,
            spaceID: spaceID,
            accessToken: accessToken)
        try keychain.storeItem(Data(configuration.accessToken.utf8), account: Self.tokenAccount)
        defaults.set(configuration.baseURL.absoluteString, forKey: Self.serverDefaultsKey)
        defaults.set(configuration.spaceID.uuidString.lowercased(), forKey: Self.spaceDefaultsKey)
        markSwitch(to: .snippetsCloud)
    }

    func signIn(
        serverURL: URL,
        requiresStrongAuthentication: Bool = false,
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws {
        try resumePendingLocalErase()
        guard let pinnedServerURL = Self.bundledServerURL,
              let redirectURL = Self.bundledOAuthRedirectURL,
              serverURL == pinnedServerURL else {
            throw Failure.missingConfiguration
        }
        let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
        let result = try await oauth.signIn(
            serverURL: pinnedServerURL,
            existingSpaceID: cloudCoordinates?.serverURL == serverURL
                ? cloudCoordinates?.spaceID
                : nil,
            requiresStrongAuthentication: requiresStrongAuthentication,
            presentationContext: presentationContext)
        defaults.set(result.serverURL.absoluteString, forKey: Self.serverDefaultsKey)
        defaults.set(result.spaceID.uuidString.lowercased(), forKey: Self.spaceDefaultsKey)
        try? keychain.deleteItem(account: Self.tokenAccount)
    }

    func signOutSnippetsCloud() async throws {
        if hasPendingLocalErase {
            try resumePendingLocalErase()
            return
        }
        try await revokeSnippetsCloudSession()
        try forgetSnippetsCloudLocally()
    }

    func resumeInterruptedSignOut() async throws {
        if hasPendingLocalErase {
            try resumePendingLocalErase()
            return
        }
        guard hasPendingRemoteRevocation else { return }
        try await revokeSnippetsCloudSession()
        try forgetSnippetsCloudLocally()
    }

    /// Revokes both access and refresh credentials before any local account state is
    /// removed. Keeping this separate lets the bootstrap coordinator erase its own
    /// device-only journals only after the server-side credential is no longer usable.
    func revokeSnippetsCloudSession() async throws {
        guard let coordinates = cloudCoordinates,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingConfiguration
        }
        try await SnippetsCloudOAuthClient(
            keychain: keychain,
            redirectURL: redirectURL
        ).revokeCurrentSession(expectedServerURL: coordinates.serverURL)
    }

    /// Writes a durable boundary after remote revocation, then erases the library root
    /// and bootstrap state before credentials and visible account coordinates. The
    /// marker is removed last; startup retries every idempotent step after a crash.
    func forgetSnippetsCloudLocally(
        bootstrapSecrets: KeychainSecretStore? = nil
    ) throws {
        try keychain.storeItem(
            Data("pending".utf8),
            account: Self.pendingLocalEraseAccount)
        try resumePendingLocalErase(bootstrapSecrets: bootstrapSecrets)
    }

    func resumePendingLocalErase(
        bootstrapSecrets: KeychainSecretStore? = nil
    ) throws {
        guard try keychain.loadItem(account: Self.pendingLocalEraseAccount) != nil else {
            return
        }

        // K_sync is the capability that opens the remote library and must disappear
        // before any UI/account state can make this device look signed out.
        try cloudKeys.forget()

        let bootstrap = bootstrapSecrets ?? bootstrapSecretsForRecovery
        var firstFailure: Error?
        for account in SnippetsCloudAccountBootstrap.bootstrapSecretAccounts {
            do { try bootstrap.deleteItem(account: account) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }

        for account in [
            Self.tokenAccount,
            Self.oauthSessionAccount,
            Self.oauthRevocationAccount,
        ] {
            do { try keychain.deleteItem(account: account) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }

        defaults.removeObject(forKey: Self.serverDefaultsKey)
        defaults.removeObject(forKey: Self.spaceDefaultsKey)
        markSwitch(to: .iCloud)
        try keychain.deleteItem(account: Self.pendingLocalEraseAccount)
    }

    func freshCloudAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard !hasPendingLocalErase, !hasPendingRemoteRevocation else {
            throw Failure.missingCredential
        }
        guard let coordinates = cloudCoordinates,
              coordinates.serverURL == Self.bundledServerURL,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingConfiguration
        }
        return try await SnippetsCloudOAuthClient(
            keychain: keychain,
            redirectURL: redirectURL
        ).freshAccessToken(
            expectedServerURL: coordinates.serverURL,
            forceRefresh: forceRefresh)
    }

    func activateSnippetsCloud() {
        guard !hasPendingLocalErase, !hasPendingRemoteRevocation else { return }
        markSwitch(to: .snippetsCloud)
    }

    func parkSnippetsCloudUntilKeyReady() {
        if provider == .snippetsCloud { markSwitch(to: .iCloud) }
    }

    var hasCloudSession: Bool {
        !hasPendingLocalErase && keychain.hasItem(account: Self.oauthSessionAccount)
    }

    static var bundledServerURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SnippetsCloudBaseURL") as? String,
              !raw.isEmpty, !raw.contains("$("), let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)
        else { return nil }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return components.url
    }

    /// The callback host must be associated with the signed app through the
    /// `webcredentials:` entitlement and its apple-app-site-association file.
    /// A reserved `.invalid` default keeps unconfigured builds fail-closed.
    static var bundledOAuthRedirectURL: URL? {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: "SnippetsCloudOAuthCallbackHost") as? String else { return nil }
        let host = raw.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.hasSuffix(".invalid"), host != "invalid",
              host.contains("."),
              host.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
                      .contains($0)
              }) else { return nil }
        return URL(string: "https://\(host)/oauth2redirect/apple")
    }

    func makeTransport() throws -> any SyncTransport {
        guard !hasPendingLocalErase, !hasPendingRemoteRevocation else {
            throw Failure.missingCredential
        }
        switch provider {
        case .iCloud:
            return CloudKitTransport()
        case .snippetsCloud:
            guard let coordinates = cloudCoordinates else { throw Failure.missingConfiguration }
            guard coordinates.serverURL == Self.bundledServerURL,
                  let redirectURL = Self.bundledOAuthRedirectURL else {
                throw Failure.missingConfiguration
            }
            let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
            if let token = try oauth.currentAccessToken(expectedServerURL: coordinates.serverURL) {
                return SnippetsCloudTransport(
                    configuration: try .init(
                        baseURL: coordinates.serverURL,
                        spaceID: coordinates.spaceID,
                        accessToken: token),
                    accessTokenProvider: { forceRefresh in
                        try await oauth.freshAccessToken(
                            expectedServerURL: coordinates.serverURL,
                            forceRefresh: forceRefresh)
                    })
            }
            guard let tokenData = try keychain.loadItem(account: Self.tokenAccount) else {
                throw Failure.missingCredential
            }
            guard let token = String(data: tokenData, encoding: .utf8) else {
                throw Failure.invalidCredential
            }
            return SnippetsCloudTransport(configuration: try .init(
                baseURL: coordinates.serverURL,
                spaceID: coordinates.spaceID,
                accessToken: token))
        }
    }

    func clearPendingProviderSwitch() {
        defaults.set(false, forKey: Self.pendingSwitchDefaultsKey)
    }

    private func markSwitch(to selected: Provider) {
        // Setting the same provider after changing its endpoint/token can still be an
        // account-scope transition and needs the exact same journal-first handoff.
        provider = selected
        defaults.set(true, forKey: Self.pendingSwitchDefaultsKey)
    }
}

@MainActor
private final class SnippetsCloudOAuthClient {
    /// All OAuth client instances, including transport-owned instances, share this
    /// process-wide rotation gate.
    private static let refreshGate = SnippetsCloudRefreshSingleFlight()

    struct SignInResult {
        let serverURL: URL
        let spaceID: UUID
    }

    enum Failure: Error, CustomStringConvertible {
        case invalidServerURL
        case insecureServerProfile
        case discoveryUnavailable
        case identityProviderUnavailable
        case authorizationCancelled
        case authorizationMismatch
        case tokenExchangeFailed
        case backgroundAccessMissing
        case spaceSelectionRequired
        case invalidStoredSession

        var description: String {
            switch self {
            case .invalidServerURL: "Enter a valid HTTPS Snippets Cloud server."
            case .insecureServerProfile: "This server does not advertise the required secure sign-in profile."
            case .discoveryUnavailable: "Snippets Cloud discovery is temporarily unavailable."
            case .identityProviderUnavailable: "The identity provider is temporarily unavailable."
            case .authorizationCancelled: "Sign-in was cancelled. Nothing changed."
            case .authorizationMismatch: "The sign-in response did not match this request."
            case .tokenExchangeFailed: "The identity provider could not complete sign-in."
            case .backgroundAccessMissing: "The identity provider did not grant background access."
            case .spaceSelectionRequired: "This account has multiple libraries; explicit selection is required."
            case .invalidStoredSession: "The saved Snippets Cloud session is invalid. Sign in again."
            }
        }
    }

    struct Discovery: Decodable {
        struct OIDC: Decodable {
            let issuer: String
            let resource: URL
            let clientId: String
            let scopes: [String]
            let authorizationFlow: String
            let maxAccessTokenAgeSeconds: Int
            let stepUpMaxAgeSeconds: Int
            let stepUpACRValues: [String]
        }
        let protocolMajor: Int
        let apiBase: URL
        let oidc: OIDC
        let capabilities: [String]
    }

    struct ProviderDiscovery: Decodable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let revocationEndpoint: URL
        let codeChallengeMethodsSupported: [String]?

        private enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case revocationEndpoint = "revocation_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    struct StoredSession: Codable {
        let schemaVersion: Int
        let serverURL: URL
        let issuer: URL
        let resource: URL
        let tokenEndpoint: URL
        let revocationEndpoint: URL
        let clientID: String
        let maximumAccessTokenAgeSeconds: Int
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private struct RevocationJournal: Codable {
        let schemaVersion: Int
        let serverURL: URL
        let issuer: URL
        let resource: URL
        let revocationEndpoint: URL
        let clientID: String
        let accessTokens: [String]
        let refreshTokens: [String]
    }

    struct SpacesResponse: Decodable { let spaces: [Space] }
    struct Space: Decodable { let spaceId: UUID; let role: String }

    private let keychain: KeychainSecretStore
    private let redirectURL: URL
    private var webSession: ASWebAuthenticationSession?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    init(keychain: KeychainSecretStore, redirectURL: URL) {
        self.keychain = keychain
        self.redirectURL = redirectURL
    }

    func signIn(
        serverURL: URL,
        existingSpaceID: UUID?,
        requiresStrongAuthentication: Bool,
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> SignInResult {
        guard !keychain.hasItem(account: SyncBackendSelectionStore.oauthRevocationAccount)
        else { throw Failure.invalidStoredSession }
        let serverURL = try validatedBaseURL(serverURL)
        let discoveryURL = serverURL.appending(path: ".well-known/snippets-sync")
        let discovery: Discovery = try await getJSON(
            discoveryURL,
            maximumBytes: 256 * 1_024,
            failure: .discoveryUnavailable)
        guard discovery.protocolMajor == 1,
              try validatedBaseURL(discovery.apiBase) == serverURL,
              try validatedBaseURL(discovery.oidc.resource) == serverURL,
              discovery.oidc.authorizationFlow == "authorization_code_pkce",
              discovery.capabilities.contains("oidc-pkce"),
              discovery.capabilities.contains("oauth-resource-indicators"),
              discovery.capabilities.contains("oauth-token-revocation"),
              discovery.capabilities.contains("resource-session-revocation"),
              discovery.capabilities.contains("account-without-required-email"),
              discovery.capabilities.contains("phishing-resistant-step-up"),
              discovery.capabilities.contains("pairing-v2"),
              discovery.capabilities.contains("offline-recovery-v1"),
              (1...16).contains(discovery.capabilities.count),
              Set(discovery.capabilities).count == discovery.capabilities.count,
              discovery.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              (1...16).contains(discovery.oidc.scopes.count),
              Set(discovery.oidc.scopes).count == discovery.oidc.scopes.count,
              discovery.oidc.scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              discovery.oidc.stepUpACRValues.count <= 16,
              Set(discovery.oidc.stepUpACRValues).count == discovery.oidc.stepUpACRValues.count,
              discovery.oidc.stepUpACRValues.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 256
              }),
              discovery.oidc.scopes.contains("openid"),
              discovery.oidc.scopes.contains("offline_access"),
              (60...86_400).contains(discovery.oidc.maxAccessTokenAgeSeconds),
              (60...3_600).contains(discovery.oidc.stepUpMaxAgeSeconds),
              !discovery.oidc.clientId.isEmpty,
              discovery.oidc.clientId.utf8.count <= 256 else {
            throw Failure.insecureServerProfile
        }

        let issuerValue = discovery.oidc.issuer
        let issuer = try validatedIssuer(issuerValue)
        let providerURL = issuer.appending(path: ".well-known/openid-configuration")
        let provider: ProviderDiscovery = try await getJSON(
            providerURL,
            maximumBytes: 256 * 1_024,
            failure: .identityProviderUnavailable)
        guard provider.issuer == issuerValue,
              try secureEndpoint(provider.authorizationEndpoint) == provider.authorizationEndpoint,
              try secureEndpoint(provider.tokenEndpoint) == provider.tokenEndpoint,
              try secureEndpoint(provider.revocationEndpoint) == provider.revocationEndpoint,
              provider.codeChallengeMethodsSupported?.contains("S256") == true else {
            throw Failure.identityProviderUnavailable
        }

        let state = try randomBase64URL(bytes: 32)
        let nonce = try randomBase64URL(bytes: 32)
        let verifier = try randomBase64URL(bytes: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        guard var components = URLComponents(
            url: provider.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else { throw Failure.identityProviderUnavailable }
        let existingItems = components.queryItems ?? []
        var requestItems = [
            URLQueryItem(name: "client_id", value: discovery.oidc.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: discovery.oidc.scopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: discovery.oidc.resource.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if requiresStrongAuthentication {
            requestItems.append(URLQueryItem(name: "prompt", value: "login"))
            requestItems.append(URLQueryItem(name: "max_age", value: "0"))
            if !discovery.oidc.stepUpACRValues.isEmpty {
                requestItems.append(URLQueryItem(
                    name: "acr_values",
                    value: discovery.oidc.stepUpACRValues.joined(separator: " ")))
            }
        }
        guard existingItems.count <= 16,
              Set(existingItems.map(\.name)).count == existingItems.count,
              Set(existingItems.map(\.name)).isDisjoint(with: Set(requestItems.map(\.name))),
              existingItems.allSatisfy({
                  !$0.name.isEmpty && $0.name.utf8.count <= 128
                      && ($0.value?.utf8.count ?? 0) <= 1_024
              }) else { throw Failure.identityProviderUnavailable }
        components.queryItems = existingItems + requestItems
        guard let authorizationURL = components.url else { throw Failure.identityProviderUnavailable }
        let callback = try await authorize(
            url: authorizationURL,
            presentationContext: presentationContext)
        let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard callbackComponents?.scheme == redirectURL.scheme,
              callbackComponents?.path == redirectURL.path,
              callbackComponents?.host == redirectURL.host,
              callbackComponents?.user == nil,
              callbackComponents?.password == nil,
              callbackComponents?.fragment == nil,
              let items = callbackComponents?.queryItems,
              Set(items.map(\.name)).count == items.count else {
            throw Failure.authorizationMismatch
        }
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        if values["error"] != nil { throw Failure.authorizationCancelled }
        guard values["state"] == state,
              let code = values["code"],
              (8...16_384).contains(code.utf8.count),
              !code.contains(where: \.isWhitespace) else {
            throw Failure.authorizationMismatch
        }

        let token: TokenResponse = try await tokenRequest(
            endpoint: provider.tokenEndpoint,
            values: [
                "grant_type": "authorization_code",
                "client_id": discovery.oidc.clientId,
                "code": code,
                "redirect_uri": redirectURL.absoluteString,
                "code_verifier": verifier,
                "resource": discovery.oidc.resource.absoluteString,
            ])
        guard token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (8...16_384).contains(token.accessToken.utf8.count),
              !token.accessToken.contains(where: \.isWhitespace),
              let refreshToken = token.refreshToken,
              (8...16_384).contains(refreshToken.utf8.count),
              !refreshToken.contains(where: \.isWhitespace),
              (60...86_400).contains(token.expiresIn) else {
            throw Failure.backgroundAccessMissing
        }
        try validateResourceAudience(
            accessToken: token.accessToken,
            resource: discovery.oidc.resource)

        let spaceID: UUID
        spaceID = try await resolvePersonalSpace(
            serverURL: serverURL,
            accessToken: token.accessToken,
            existingSpaceID: existingSpaceID)
        let stored = StoredSession(
            schemaVersion: 4,
            serverURL: serverURL,
            issuer: issuer,
            resource: discovery.oidc.resource,
            tokenEndpoint: provider.tokenEndpoint,
            revocationEndpoint: provider.revocationEndpoint,
            clientID: discovery.oidc.clientId,
            maximumAccessTokenAgeSeconds: discovery.oidc.maxAccessTokenAgeSeconds,
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(min(
                token.expiresIn,
                discovery.oidc.maxAccessTokenAgeSeconds
            ))))
        try keychain.storeItem(
            try JSONEncoder().encode(stored),
            account: SyncBackendSelectionStore.oauthSessionAccount)
        return SignInResult(serverURL: serverURL, spaceID: spaceID)
    }

    func currentAccessToken(expectedServerURL: URL) throws -> String? {
        guard let stored = try loadSession() else { return nil }
        try validateServerBinding(stored, expectedServerURL: expectedServerURL)
        return stored.accessToken
    }

    func freshAccessToken(
        expectedServerURL: URL,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard !keychain.hasItem(account: SyncBackendSelectionStore.oauthRevocationAccount)
        else { throw Failure.invalidStoredSession }
        guard let stored = try loadSession() else { throw Failure.invalidStoredSession }
        try validateServerBinding(stored, expectedServerURL: expectedServerURL)
        if !forceRefresh,
           stored.expiresAt.timeIntervalSinceNow > 60,
           !Self.refreshGate.isActive {
            return stored.accessToken
        }
        return try await Self.refreshGate.run { [self] in
            try await performRefresh(stored)
        }
    }

    private func performRefresh(_ stored: StoredSession) async throws -> String {
        let token: TokenResponse = try await tokenRequest(
            endpoint: stored.tokenEndpoint,
            values: [
                "grant_type": "refresh_token",
                "client_id": stored.clientID,
                "refresh_token": stored.refreshToken,
                "resource": stored.resource.absoluteString,
            ])
        let refreshToken = token.refreshToken ?? stored.refreshToken
        guard token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (8...16_384).contains(token.accessToken.utf8.count),
              !token.accessToken.contains(where: \.isWhitespace),
              (8...16_384).contains(refreshToken.utf8.count),
              !refreshToken.contains(where: \.isWhitespace),
              (60...86_400).contains(token.expiresIn) else {
            throw Failure.tokenExchangeFailed
        }
        try validateResourceAudience(accessToken: token.accessToken, resource: stored.resource)
        let updated = StoredSession(
            schemaVersion: 4,
            serverURL: stored.serverURL,
            issuer: stored.issuer,
            resource: stored.resource,
            tokenEndpoint: stored.tokenEndpoint,
            revocationEndpoint: stored.revocationEndpoint,
            clientID: stored.clientID,
            maximumAccessTokenAgeSeconds: stored.maximumAccessTokenAgeSeconds,
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(min(
                token.expiresIn,
                stored.maximumAccessTokenAgeSeconds
            ))))
        // During logout, retain every issued token family member before replacing the
        // stored session. A crash after refresh can then retry revocation without
        // forgetting the provider's previous refresh token.
        let joinedRevocation = try extendRevocationJournalIfPresent(with: [stored, updated])
        try keychain.storeItem(
            try JSONEncoder().encode(updated),
            account: SyncBackendSelectionStore.oauthSessionAccount)
        if joinedRevocation {
            throw Failure.invalidStoredSession
        }
        return updated.accessToken
    }

    private func validateServerBinding(
        _ stored: StoredSession,
        expectedServerURL: URL
    ) throws {
        guard (try? validatedBaseURL(expectedServerURL)) == stored.serverURL else {
            throw Failure.invalidStoredSession
        }
    }

    private func loadSession() throws -> StoredSession? {
        guard let data = try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthSessionAccount) else { return nil }
        guard data.count <= 128 * 1_024,
              let value = try? JSONDecoder().decode(StoredSession.self, from: data),
              value.schemaVersion == 4,
              !value.clientID.isEmpty, value.clientID.utf8.count <= 256,
              (60...86_400).contains(value.maximumAccessTokenAgeSeconds),
              (8...16_384).contains(value.accessToken.utf8.count),
              !value.accessToken.contains(where: \.isWhitespace),
              (8...16_384).contains(value.refreshToken.utf8.count),
              !value.refreshToken.contains(where: \.isWhitespace),
              value.expiresAt.timeIntervalSince1970.isFinite,
              value.expiresAt.timeIntervalSinceNow <= 86_460,
              (try? validatedBaseURL(value.serverURL)) == value.serverURL,
              (try? validatedBaseURL(value.resource)) == value.serverURL,
              (try? validatedIssuer(value.issuer)) == value.issuer,
              (try? secureEndpoint(value.tokenEndpoint)) == value.tokenEndpoint,
              (try? secureEndpoint(value.revocationEndpoint)) == value.revocationEndpoint else {
            throw Failure.invalidStoredSession
        }
        return value
    }

    func revokeCurrentSession(expectedServerURL: URL) async throws {
        guard var stored = try loadSession() else {
            guard !keychain.hasItem(account: SyncBackendSelectionStore.oauthRevocationAccount)
            else { throw Failure.invalidStoredSession }
            return
        }
        try validateServerBinding(stored, expectedServerURL: expectedServerURL)
        var revocationJournal = try loadRevocationJournal(boundTo: stored)
        if revocationJournal == nil {
            revocationJournal = makeRevocationJournal(sessions: [stored])
            try storeRevocationJournal(revocationJournal!)
        }

        // A refresh that began before the journal existed is allowed to finish only
        // after adding both generations to that journal. No later ordinary refresh can
        // start while the journal exists.
        await Self.refreshGate.drain()
        guard let latest = try loadSession() else { throw Failure.invalidStoredSession }
        try validateServerBinding(latest, expectedServerURL: expectedServerURL)
        stored = latest
        revocationJournal = try loadRevocationJournal(boundTo: stored)

        func revokeAtResource(serverURL: URL, accessToken: String) async throws -> Int {
            var request = URLRequest(
                url: serverURL.appending(path: "v1/session"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "X-Snippets-Protocol")
            let (body, response) = try await boundedResponse(
                request,
                maximumBytes: 256 * 1_024)
            guard let http = response as? HTTPURLResponse,
                  response.url == request.url,
                  http.statusCode != 204 || body.isEmpty else {
                throw Failure.tokenExchangeFailed
            }
            return http.statusCode
        }

        func revoke(_ token: String, hint: String) async throws {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "client_id", value: stored.clientID),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "token_type_hint", value: hint),
            ]
            guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
                throw Failure.tokenExchangeFailed
            }
            var request = URLRequest(url: stored.revocationEndpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type")
            let (_, response) = try await boundedResponse(
                request,
                maximumBytes: 256 * 1_024)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { throw Failure.tokenExchangeFailed }
        }
        revocationJournal = try loadRevocationJournal(boundTo: stored)
        guard let revocationJournal else { throw Failure.invalidStoredSession }
        let plan = SnippetsCloudCredentialRevocationPlan(
            sessionAccessToken: stored.accessToken,
            sessionRefreshToken: stored.refreshToken,
            journalAccessTokens: revocationJournal.accessTokens,
            journalRefreshTokens: revocationJournal.refreshTokens)

        // Revoke every access-token generation from the journal. In particular, do
        // not try to refresh merely because the old primary session gets 401: after
        // a crash the next, still-valid generation may exist only in this journal.
        // A 401 is terminally safe for that credential because it cannot authorize
        // the data plane; provider revocation below closes every refresh generation.
        for token in plan.accessTokens {
            let status = try await revokeAtResource(
                serverURL: stored.serverURL,
                accessToken: token)
            guard status == 204 || status == 401 else {
                throw Failure.tokenExchangeFailed
            }
        }
        for token in plan.accessTokens {
            try await revoke(token, hint: "access_token")
        }
        for token in plan.refreshTokens {
            try await revoke(token, hint: "refresh_token")
        }
        // Keep the remote-intent journal until the caller durably records local erase.
        // If the process dies here, startup repeats these idempotent RFC 7009/resource
        // revocations and then removes the root key.
    }

    private func loadRevocationJournal(
        boundTo stored: StoredSession
    ) throws -> RevocationJournal? {
        guard let data = try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthRevocationAccount) else { return nil }
        guard data.count <= 256 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                "schemaVersion", "serverURL", "issuer", "resource",
                "revocationEndpoint", "clientID", "accessTokens", "refreshTokens",
              ],
              let journal = try? JSONDecoder().decode(RevocationJournal.self, from: data),
              journal.schemaVersion == 1,
              journal.serverURL == stored.serverURL,
              journal.issuer == stored.issuer,
              journal.resource == stored.resource,
              journal.revocationEndpoint == stored.revocationEndpoint,
              journal.clientID == stored.clientID,
              (1...16).contains(journal.accessTokens.count),
              (1...16).contains(journal.refreshTokens.count),
              Set(journal.accessTokens).count == journal.accessTokens.count,
              Set(journal.refreshTokens).count == journal.refreshTokens.count,
              journal.accessTokens.allSatisfy(validToken),
              journal.refreshTokens.allSatisfy(validToken) else {
            throw Failure.invalidStoredSession
        }
        return journal
    }

    private func extendRevocationJournalIfPresent(
        with sessions: [StoredSession]
    ) throws -> Bool {
        guard let first = sessions.first,
              let existing = try loadRevocationJournal(boundTo: first) else { return false }
        let merged = RevocationJournal(
            schemaVersion: 1,
            serverURL: existing.serverURL,
            issuer: existing.issuer,
            resource: existing.resource,
            revocationEndpoint: existing.revocationEndpoint,
            clientID: existing.clientID,
            accessTokens: orderedUnique(
                existing.accessTokens + sessions.map(\.accessToken)),
            refreshTokens: orderedUnique(
                existing.refreshTokens + sessions.map(\.refreshToken)))
        try storeRevocationJournal(merged)
        return true
    }

    private func makeRevocationJournal(
        sessions: [StoredSession]
    ) -> RevocationJournal {
        let first = sessions[0]
        return RevocationJournal(
            schemaVersion: 1,
            serverURL: first.serverURL,
            issuer: first.issuer,
            resource: first.resource,
            revocationEndpoint: first.revocationEndpoint,
            clientID: first.clientID,
            accessTokens: orderedUnique(sessions.map(\.accessToken)),
            refreshTokens: orderedUnique(sessions.map(\.refreshToken)))
    }

    private func storeRevocationJournal(_ journal: RevocationJournal) throws {
        guard journal.accessTokens.count <= 16, journal.refreshTokens.count <= 16 else {
            throw Failure.invalidStoredSession
        }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 256 * 1_024 else { throw Failure.invalidStoredSession }
        try keychain.storeItem(
            data,
            account: SyncBackendSelectionStore.oauthRevocationAccount)
    }

    private func validToken(_ token: String) -> Bool {
        (8...16_384).contains(token.utf8.count)
            && !token.contains(where: \.isWhitespace)
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func authorize(
        url: URL,
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        guard let callbackHost = redirectURL.host else {
            throw Failure.invalidStoredSession
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: callbackHost, path: redirectURL.path)
            ) { [weak self] callback, error in
                self?.webSession = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    _ = error
                    continuation.resume(throwing: Failure.authorizationCancelled)
                }
            }
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            guard session.start() else {
                webSession = nil
                continuation.resume(throwing: Failure.authorizationCancelled)
                return
            }
        }
    }

    private func resolvePersonalSpace(
        serverURL: URL,
        accessToken: String,
        existingSpaceID: UUID?
    ) async throws -> UUID {
        let response: SpacesResponse = try await authorizedJSON(
            url: serverURL.appending(path: "v1/spaces"),
            method: "GET",
            accessToken: accessToken)
        if let existingSpaceID, response.spaces.contains(where: { $0.spaceId == existingSpaceID }) {
            return existingSpaceID
        }
        if response.spaces.count == 1 { return response.spaces[0].spaceId }
        let owned = response.spaces.filter { $0.role == "owner" }
        if owned.count == 1 { return owned[0].spaceId }
        guard response.spaces.isEmpty else { throw Failure.spaceSelectionRequired }
        struct CreatedSpace: Decodable { let spaceId: UUID }
        struct Request: Encodable { let idempotencyKey: UUID }
        let created: CreatedSpace = try await authorizedJSON(
            url: serverURL.appending(path: "v1/spaces"),
            method: "POST",
            accessToken: accessToken,
            body: try JSONEncoder().encode(Request(
                idempotencyKey: UUID(uuidString: "7b28d156-77fd-4f7f-bdf3-234f7d97ac91")!)))
        return created.spaceId
    }

    private func tokenRequest(endpoint: URL, values: [String: String]) async throws -> TokenResponse {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw Failure.tokenExchangeFailed
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            return try await responseJSON(
                request,
                maximumBytes: 256 * 1_024,
                failure: .tokenExchangeFailed)
        } catch {
            throw Failure.tokenExchangeFailed
        }
    }

    private func authorizedJSON<Response: Decodable>(
        url: URL,
        method: String,
        accessToken: String,
        body: Data? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Snippets-Protocol")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await boundedResponse(request, maximumBytes: 1 * 1_024 * 1_024)
        guard let http = response as? HTTPURLResponse else { throw Failure.discoveryUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(HTTPError.self, from: data).code)
                ?? "http_\(http.statusCode)"
            throw HTTPFailure(code: code)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func getJSON<Response: Decodable>(
        _ url: URL,
        maximumBytes: Int,
        failure: Failure
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await responseJSON(request, maximumBytes: maximumBytes, failure: failure)
    }

    private func responseJSON<Response: Decodable>(
        _ request: URLRequest,
        maximumBytes: Int,
        failure: Failure
    ) async throws -> Response {
        do {
            let (data, response) = try await boundedResponse(request, maximumBytes: maximumBytes)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.url == request.url else { throw failure }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw failure
        }
    }

    private func boundedResponse(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let length = response.expectedContentLength
        if length > Int64(maximumBytes) { throw Failure.discoveryUnavailable }
        var data = Data()
        if length > 0 { data.reserveCapacity(Int(length)) }
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw Failure.discoveryUnavailable }
            data.append(byte)
        }
        return (data, response)
    }

    private func validatedBaseURL(_ value: URL) throws -> URL {
        guard value.absoluteString.utf8.count <= 2_048,
              value.scheme?.lowercased() == "https", value.host != nil,
              value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil else { throw Failure.invalidServerURL }
        guard var components = URLComponents(url: value.absoluteURL, resolvingAgainstBaseURL: false)
        else { throw Failure.invalidServerURL }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let normalized = components.url else { throw Failure.invalidServerURL }
        return normalized
    }

    private func validatedIssuer(_ value: String) throws -> URL {
        guard !value.isEmpty, value.utf8.count <= 2_048,
              let url = URL(string: value) else {
            throw Failure.identityProviderUnavailable
        }
        return try validatedIssuer(url)
    }

    private func validatedIssuer(_ value: URL) throws -> URL {
        guard value.scheme?.lowercased() == "https", value.host != nil,
              value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil else {
            throw Failure.identityProviderUnavailable
        }
        return value
    }

    private func secureEndpoint(_ value: URL) throws -> URL {
        guard value.scheme?.lowercased() == "https", value.host != nil,
              value.user == nil, value.password == nil,
              value.absoluteString.utf8.count <= 2_048,
              value.fragment == nil else { throw Failure.identityProviderUnavailable }
        return value
    }

    /// This is an audience leak-prevention check, not a replacement for the
    /// server's signature verification. The token came directly from the
    /// issuer's HTTPS token endpoint and must name only this exact RFC 8707
    /// resource before it is ever sent to a sync origin.
    private func validateResourceAudience(accessToken: String, resource: URL) throws {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              segments[1].utf8.count <= 32 * 1_024,
              let payload = Data(base64URL: String(segments[1])),
              payload.count <= 24 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw Failure.tokenExchangeFailed }
        let audiences: [String]
        if let value = object["aud"] as? String {
            audiences = [value]
        } else if let values = object["aud"] as? [String] {
            audiences = values
        } else {
            throw Failure.tokenExchangeFailed
        }
        guard audiences == [resource.absoluteString] else {
            throw Failure.tokenExchangeFailed
        }
    }

    private func randomBase64URL(bytes: Int) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.authorizationMismatch }
        return data.base64URL
    }

    private struct HTTPError: Decodable { let code: String }
    private struct HTTPFailure: Error { let code: String }

}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }
}

private extension Data {
    init?(base64URL value: String) {
        guard value.utf8.count <= 32 * 1_024,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
                      .contains($0)
              }) else { return nil }
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 { encoded.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        self = data
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
