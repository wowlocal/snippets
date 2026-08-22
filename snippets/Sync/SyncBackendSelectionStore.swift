import Foundation
import AuthenticationServices
import CryptoKit
import Security

/// Build-time dark-launch gate for the first-party Snippets Cloud service.
///
/// Shipping builds leave `SNIPPETS_CLOUD_ENABLED` at `NO`. Supplying endpoints alone
/// is deliberately insufficient: an internal build must opt in to both the feature and
/// its pinned OAuth coordinates before any account UI or HTTP data plane can run.
nonisolated enum SnippetsCloudFeature {
    static let infoDictionaryKey = "SnippetsCloudEnabled"

    static var isEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) {
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["1", "true", "yes"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }
}

struct SnippetsCloudLibraryChoice: Equatable {
    let spaceID: UUID
    let serverInstanceID: UUID
    let role: String
    let scopeBinding: String?

    init(
        spaceID: UUID,
        serverInstanceID: UUID,
        role: String,
        scopeBinding: String? = nil
    ) {
        self.spaceID = spaceID
        self.serverInstanceID = serverInstanceID
        self.role = role
        self.scopeBinding = scopeBinding
    }

    var canWrite: Bool { role == "owner" || role == "writer" }

    var libraryID: String {
        let source = "\(serverInstanceID.uuidString.lowercased()):\(spaceID.uuidString.lowercased())"
        return SHA256.hash(data: Data(source.utf8)).prefix(4)
            .map { String(format: "%02X", $0) }.joined()
    }
}

func automaticSnippetsCloudLibraryChoice(
    _ choices: [SnippetsCloudLibraryChoice],
    existingSpaceID: UUID?
) -> UUID? {
    let writable = choices.filter(\.canWrite)
    if let existingSpaceID, writable.contains(where: { $0.spaceID == existingSpaceID }) {
        return existingSpaceID
    }
    if writable.count == 1 { return writable[0].spaceID }
    return nil
}

struct SnippetsCloudStepUpBinding: Equatable {
    let serverURL: URL
    let serverInstanceID: UUID
    let spaceID: UUID
    let scopeBinding: String

    func matches(
        serverURL: URL,
        serverInstanceID: UUID,
        spaceID: UUID,
        scopeBinding: String,
        role: String
    ) -> Bool {
        self.serverURL == serverURL
            && self.serverInstanceID == serverInstanceID
            && self.spaceID == spaceID
            && self.scopeBinding == scopeBinding
            && ["owner", "writer"].contains(role)
    }
}

struct SnippetsCloudPostAuthorizationTarget: Equatable {
    let serverURL: URL
    let serverInstanceID: UUID
    let protocolMajor: Int
    let spaceID: UUID
    let scopeBinding: String
}

private struct SnippetsCloudStepUpTarget: Equatable {
    let serverURL: URL
    let serverInstanceID: UUID
    let protocolMajor: Int
    let spaceID: UUID
}

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

/// Distinguishes the two crash sides of a journal-first credential replacement.
/// A later-than-current refresh token was minted but never committed and must be
/// revoked. After commit, refresh rotation relies on mandatory reuse protection, while
/// an interactive replacement is a separate grant whose older refresh stays tracked
/// and is explicitly revoked.
struct SnippetsCloudCredentialReplacementCleanupPlan: Equatable {
    let accessTokensToRetire: [String]
    let abandonedRefreshTokens: [String]

    init?(
        currentAccessToken: String?,
        currentRefreshToken: String?,
        journalAccessTokens: [String],
        journalRefreshTokens: [String],
        replacementKind: SnippetsCloudCredentialReplacementKind
    ) {
        guard !journalAccessTokens.isEmpty, !journalRefreshTokens.isEmpty,
              (currentAccessToken == nil) == (currentRefreshToken == nil) else { return nil }
        accessTokensToRetire = journalAccessTokens.filter { $0 != currentAccessToken }
        guard let currentAccessToken, let currentRefreshToken else {
            abandonedRefreshTokens = journalRefreshTokens
            return
        }
        guard let accessIndex = journalAccessTokens.firstIndex(of: currentAccessToken),
              let refreshIndex = journalRefreshTokens.firstIndex(of: currentRefreshToken)
        else { return nil }
        let currentIsCommittedNewest =
            accessIndex == journalAccessTokens.index(before: journalAccessTokens.endIndex)
            && refreshIndex == journalRefreshTokens.index(before: journalRefreshTokens.endIndex)
        if currentIsCommittedNewest {
            abandonedRefreshTokens = replacementKind == .interactiveReplacement
                ? journalRefreshTokens.filter { $0 != currentRefreshToken }
                : []
        } else {
            abandonedRefreshTokens = Array(
                journalRefreshTokens.suffix(from: refreshIndex + 1))
        }
    }
}

enum SnippetsCloudCredentialReplacementKind: String, Codable {
    case refreshRotation
    case interactiveReplacement
}

/// Serializes interactive credential replacement, orphan cleanup, and logout across
/// awaits. MainActor alone is reentrant, so without this gate a browser callback could
/// publish a new token generation while logout was already revoking an older plan.
@MainActor
final class SnippetsCloudCredentialMutationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held = false
    private var waiters: [Waiter] = []

    func run<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !held {
            held = true
            return
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id)
            }
        }
        guard acquired else { throw CancellationError() }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
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
    enum Provider: String, CaseIterable, Codable, Sendable {
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
        var apiBaseURL: URL? = nil
        var spaceID: UUID
        var serverInstanceID: UUID? = nil
        var protocolMajor: Int? = nil
    }

    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case featureDisabled
        case missingConfiguration
        case missingCredential
        case invalidCredential
        case credentialCleanupRequired
        case credentialResetRequired
        case credentialStoreUnavailable
        case postAuthorizationMembershipMismatch
        case postAuthorizationSetupRequired
        case postAuthorizationStateUnavailable
        case preferenceStoreUnavailable
        case invalidProviderSelection
        case switchStateUnreadable

        var description: String {
            switch self {
            case .featureDisabled: "Snippets Cloud is disabled in this build"
            case .missingConfiguration: "Snippets Cloud is not configured"
            case .missingCredential: "Snippets Cloud needs sign-in"
            case .invalidCredential: "the stored Snippets Cloud credential is invalid"
            case .credentialCleanupRequired:
                "a previous Snippets Cloud sign-in is still retiring old credentials"
            case .credentialResetRequired:
                "the saved Snippets Cloud credential history cannot be verified"
            case .credentialStoreUnavailable: "the credential store is temporarily unavailable"
            case .postAuthorizationMembershipMismatch:
                "the committed cloud credential does not match the pending library setup"
            case .postAuthorizationSetupRequired:
                "the interrupted cloud library setup must finish before sync starts"
            case .postAuthorizationStateUnavailable:
                "the interrupted cloud library setup state could not be verified"
            case .preferenceStoreUnavailable: "the sync preference store is unavailable"
            case .invalidProviderSelection:
                "the saved sync provider was written by an unsupported version"
            case .switchStateUnreadable:
                "the interrupted provider switch could not be verified"
            }
        }

        var errorDescription: String? { description }

        var requiresTargetBoundPostAuthorizationReauthentication: Bool {
            switch self {
            case .missingCredential, .postAuthorizationMembershipMismatch: true
            default: false
            }
        }
    }

    static let providerDefaultsKey = "SnippetsSyncProvider"
    /// New builds use this for the provider-independent on/off choice. The old key is
    /// mirrored only for downgrade compatibility and therefore means iCloud specifically.
    static let syncEnabledDefaultsKey = "SnippetsSyncEnabled"
    static let legacyICloudEnabledDefaultsKey = "SnippetsICloudSyncEnabled"
    /// Removed one-bit provider-switch authority. Older builds could leave this true
    /// across an offline attempt and accidentally authorize a later unrelated account.
    private static let legacyPendingSwitchDefaultsKey = "SnippetsSyncProviderSwitchPending"
    private static let serverDefaultsKey = "SnippetsCloudServerURL"
    private static let apiBaseDefaultsKey = "SnippetsCloudAPIBaseURL"
    private static let spaceDefaultsKey = "SnippetsCloudSpaceID"
    private static let serverInstanceDefaultsKey = "SnippetsCloudServerInstanceID"
    private static let protocolMajorDefaultsKey = "SnippetsCloudProtocolMajor"
    private static let tokenAccount = "oidc-access-token-v1"
    static let oauthSessionAccount = "oidc-session-v1"
    static let oauthSessionReplacementAccount = "oidc-session-replacement-journal-v1"
    static let oauthRevocationAccount = "oidc-revocation-journal-v1"
    static let pendingLocalEraseAccount = "cloud-local-erase-v1"
    fileprivate static let credentialService = "com.khm.snippets.sync-http"

    struct ProviderSwitchReceipt: Codable, Equatable {
        enum Phase: String, Codable { case prepared, targetSelected }

        static let currentSchemaVersion = 1
        var schemaVersion = currentSchemaVersion
        var id: UUID
        var source: Provider
        var target: Provider
        var sourceLocationID: String
        var targetLocationID: String
        var phase: Phase
    }

    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore
    private let bootstrapSecretsForRecovery: KeychainSecretStore
    let snippetsCloudEnabled: Bool
    let cloudKeys: SnippetsCloudKeyStore
    private(set) var providerSelectionFailure: Failure?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainSecretStore? = nil,
        cloudKeys: SnippetsCloudKeyStore? = nil,
        bootstrapSecrets: KeychainSecretStore? = nil,
        snippetsCloudEnabled: Bool = SnippetsCloudFeature.isEnabled
    ) {
        self.defaults = defaults
        self.snippetsCloudEnabled = snippetsCloudEnabled
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
        // A provider choice is not authority to clear an account safety boundary. Drop
        // the legacy Boolean on every launch; an account/dataset change now always uses
        // the explicit reason-specific confirmation shown by Sync settings.
        defaults.removeObject(forKey: Self.legacyPendingSwitchDefaultsKey)
        migrateSyncPreferenceIfNeeded()
        recoverInterruptedProviderSwitch()
        mirrorLegacyICloudPreference()
        // A successful remote logout writes this journal before deleting any local
        // secret. Finishing it during normal app construction makes process death at
        // every subsequent deletion boundary recoverable and fail-closed.
        try? resumePendingLocalErase()
        // Shipping builds expose only iCloud. Credential replacement/revocation state
        // belongs exclusively to the dark-launched Snippets Cloud data plane, and that
        // plane revalidates the same lineage before constructing a transport. Avoid
        // making every ordinary iCloud launch synchronously read three unrelated
        // Keychain items. The local-erase journal remains above this gate because it is
        // the crash-safe tail of an already-authorized destructive operation and must
        // finish even if a later build disables Snippets Cloud.
        guard snippetsCloudEnabled else { return }
        let startupLineage = try? SnippetsCloudOAuthClient(
            keychain: self.keychain,
            redirectURL: Self.bundledOAuthRedirectURL
                ?? URL(string: "https://credentials.invalid/oauth2redirect/apple")!
        ).inspectCredentialLineage()
        if startupLineage?.hasRevocation == true {
            // The remote intent journal is written before the first logout request and
            // retained through provider success. A crash in the network/local handoff
            // therefore resumes idempotently instead of leaving a usable local root.
            Task { @MainActor [weak self] in
                try? await self?.resumeInterruptedSignOut()
            }
        } else if startupLineage?.hasReplacement == true,
                  let redirectURL = Self.bundledOAuthRedirectURL {
            // This also covers a crash after a first token exchange journaled its
            // credentials but before AUTH_SESSION was committed. With no current
            // session every journal token is superseded and is remotely revoked.
            Task { @MainActor [credentialStore = self.keychain] in
                try? await SnippetsCloudOAuthClient(
                    keychain: credentialStore,
                    redirectURL: redirectURL
                ).retireSupersededInteractiveSessions()
            }
        }
    }

    var provider: Provider {
        guard let raw = defaults.string(forKey: Self.providerDefaultsKey) else {
            return .iCloud
        }
        return Provider(rawValue: raw) ?? .iCloud
    }

    var syncEnabled: Bool {
        if let stored = defaults.object(forKey: Self.syncEnabledDefaultsKey) as? NSNumber {
            return stored.boolValue
        }
        return defaults.bool(forKey: Self.legacyICloudEnabledDefaultsKey)
    }

    func setSyncEnabled(_ enabled: Bool) {
        // When stopping, retire the downgrade capability before changing new state. When
        // starting iCloud, publish the new state first so no crash can leave an older
        // build enabled while this build still considers sync off.
        if !enabled || provider != .iCloud {
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
        }
        defaults.set(enabled, forKey: Self.syncEnabledDefaultsKey)
        if enabled, provider == .iCloud, providerSelectionFailure == nil {
            defaults.set(true, forKey: Self.legacyICloudEnabledDefaultsKey)
        }
        _ = defaults.synchronize()
    }

    var availableProviders: [Provider] {
        snippetsCloudEnabled ? Provider.allCases : [.iCloud]
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

    var hasPendingCredentialCleanup: Bool {
        keychain.hasItem(account: Self.oauthSessionReplacementAccount)
    }

    var hasPendingPostAuthorization: Bool {
        bootstrapSecretsForRecovery.hasItem(
            account: SnippetsCloudAccountBootstrap.pendingPostAuthorizationAccount)
    }

    func pendingLocalEraseExists() throws -> Bool {
        try keychain.loadItem(account: Self.pendingLocalEraseAccount) != nil
    }

    func pendingRemoteRevocationExists() throws -> Bool {
        try keychain.loadItem(account: Self.oauthRevocationAccount) != nil
    }

    var cloudCredentialResetRequired: Bool {
        guard let failure = credentialLineageFailure() else { return false }
        if case .credentialResetRequired = failure { return true }
        return false
    }

    private func credentialLineageFailure() -> Failure? {
        // Parsing the journal does not use the callback, but keeping construction on
        // the same validated client avoids a second, weaker credential schema path.
        let inspectionRedirect = Self.bundledOAuthRedirectURL
            ?? URL(string: "https://credentials.invalid/oauth2redirect/apple")!
        do {
            let lineage = try SnippetsCloudOAuthClient(
                keychain: keychain,
                redirectURL: inspectionRedirect
            ).inspectCredentialLineage()
            return lineage.hasReplacement || lineage.hasRevocation
                ? .credentialCleanupRequired : nil
        } catch SnippetsCloudOAuthClient.Failure.invalidStoredSession {
            return .credentialResetRequired
        } catch {
            return .credentialStoreUnavailable
        }
    }

    private func schedulePendingCredentialCleanup() {
        guard hasPendingCredentialCleanup,
              !hasPendingRemoteRevocation,
              let redirectURL = Self.bundledOAuthRedirectURL else { return }
        Task { @MainActor [credentialStore = keychain] in
            // Success removes the durable boundary. Failure deliberately leaves it in
            // place; makeTransport and every token provider keep the data plane closed,
            // while Try Again/startup can schedule another awaited cleanup attempt.
            try? await SnippetsCloudOAuthClient(
                keychain: credentialStore,
                redirectURL: redirectURL
            ).retireSupersededInteractiveSessions()
        }
    }

    private static func cloudCoordinates(in defaults: UserDefaults) -> CloudCoordinates? {
        guard let rawURL = defaults.string(forKey: Self.serverDefaultsKey),
              let url = URL(string: rawURL),
              let rawSpace = defaults.string(forKey: Self.spaceDefaultsKey),
              let spaceID = UUID(uuidString: rawSpace) else { return nil }
        let serverInstanceID = defaults.string(forKey: Self.serverInstanceDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let apiBaseURL = defaults.string(forKey: Self.apiBaseDefaultsKey)
            .flatMap(URL.init(string:))
        let storedProtocol = defaults.object(forKey: Self.protocolMajorDefaultsKey) as? NSNumber
        return CloudCoordinates(
            serverURL: url,
            apiBaseURL: apiBaseURL,
            spaceID: spaceID,
            serverInstanceID: serverInstanceID,
            protocolMajor: storedProtocol?.intValue)
    }

    func selectICloud() throws {
        try commitProvider(.iCloud)
    }

    func selectSnippetsCloud(
        serverURL: URL,
        spaceID: UUID,
        serverInstanceID: UUID,
        protocolMajor: Int = 2,
        accessToken: String
    ) throws {
        guard snippetsCloudEnabled else { throw Failure.featureDisabled }
        if let failure = credentialLineageFailure() { throw failure }
        let localErasePending: Bool
        let remoteRevocationPending: Bool
        do {
            localErasePending = try pendingLocalEraseExists()
            remoteRevocationPending = try pendingRemoteRevocationExists()
        } catch {
            throw Failure.credentialStoreUnavailable
        }
        guard !localErasePending, !remoteRevocationPending,
              !hasPendingCredentialCleanup else {
            throw Failure.missingCredential
        }
        let configuration = try SnippetsCloudTransport.Configuration(
            baseURL: serverURL,
            spaceID: spaceID,
            serverInstanceID: serverInstanceID,
            protocolMajor: protocolMajor,
            accessToken: accessToken)
        try keychain.storeItem(Data(configuration.accessToken.utf8), account: Self.tokenAccount)
        defaults.set(configuration.baseURL.absoluteString, forKey: Self.serverDefaultsKey)
        defaults.set(
            configuration.baseURL.appending(path: "v2").absoluteString,
            forKey: Self.apiBaseDefaultsKey)
        defaults.set(configuration.spaceID.uuidString.lowercased(), forKey: Self.spaceDefaultsKey)
        defaults.set(
            configuration.serverInstanceID.uuidString.lowercased(),
            forKey: Self.serverInstanceDefaultsKey)
        defaults.set(configuration.protocolMajor, forKey: Self.protocolMajorDefaultsKey)
        try commitProvider(.snippetsCloud)
    }

    func signIn(
        serverURL: URL,
        requiresStrongAuthentication: Bool = false,
        chooseAccount: Bool = false,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        presentationContext: any ASWebAuthenticationPresentationContextProviding,
        preparePostAuthorization: @escaping (
            SnippetsCloudPostAuthorizationTarget
        ) throws -> Void = { _ in }
    ) async throws {
        guard snippetsCloudEnabled else { throw Failure.featureDisabled }
        try requireNoPendingPostAuthorization()
        try resumePendingLocalErase()
        if let failure = credentialLineageFailure() {
            switch failure {
            case .credentialCleanupRequired:
                // signIn() owns the awaited, serialized cleanup before opening a browser.
                break
            default:
                throw failure
            }
        }
        guard let pinnedServerURL = Self.bundledServerURL,
              let redirectURL = Self.bundledOAuthRedirectURL,
              serverURL == pinnedServerURL else {
            throw Failure.missingConfiguration
        }
        let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
        let expectedStepUpTarget: SnippetsCloudStepUpTarget?
        if requiresStrongAuthentication {
            guard let coordinates = cloudCoordinates,
                  coordinates.serverURL == serverURL,
                  let serverInstanceID = coordinates.serverInstanceID,
                  coordinates.protocolMajor == 2 else {
                throw Failure.missingCredential
            }
            expectedStepUpTarget = SnippetsCloudStepUpTarget(
                serverURL: coordinates.serverURL,
                serverInstanceID: serverInstanceID,
                protocolMajor: 2,
                spaceID: coordinates.spaceID)
        } else {
            expectedStepUpTarget = nil
        }
        _ = try await oauth.signIn(
            serverURL: pinnedServerURL,
            existingSpaceID: cloudCoordinates?.serverURL == serverURL
                ? cloudCoordinates?.spaceID
                : nil,
            requiresStrongAuthentication: requiresStrongAuthentication,
            chooseAccount: chooseAccount,
            expectedStepUpTarget: expectedStepUpTarget,
            expectedPostAuthorizationTarget: nil,
            chooseLibrary: chooseLibrary,
            presentationContext: presentationContext,
            validateStepUpTarget: { [weak self] in
                guard let expectedStepUpTarget else { return }
                guard let current = self?.cloudCoordinates,
                      current.serverURL == expectedStepUpTarget.serverURL,
                      current.serverInstanceID == expectedStepUpTarget.serverInstanceID,
                      current.protocolMajor == expectedStepUpTarget.protocolMajor,
                      current.spaceID == expectedStepUpTarget.spaceID else {
                    throw Failure.missingCredential
                }
            },
            prepareCoordinatesCommit: { result in
                try preparePostAuthorization(.init(
                    serverURL: result.serverURL,
                    serverInstanceID: result.serverInstanceID,
                    protocolMajor: result.protocolMajor,
                    spaceID: result.spaceID,
                    scopeBinding: result.scopeBinding))
            },
            commitCoordinates: { [defaults, keychain] result in
                defaults.set(result.serverURL.absoluteString, forKey: Self.serverDefaultsKey)
                defaults.set(result.apiBaseURL.absoluteString, forKey: Self.apiBaseDefaultsKey)
                defaults.set(
                    result.spaceID.uuidString.lowercased(),
                    forKey: Self.spaceDefaultsKey)
                defaults.set(
                    result.serverInstanceID.uuidString.lowercased(),
                    forKey: Self.serverInstanceDefaultsKey)
                defaults.set(result.protocolMajor, forKey: Self.protocolMajorDefaultsKey)
                try? keychain.deleteItem(account: Self.tokenAccount)
            })
    }

    func changeSnippetsCloudLibrary(
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        preparePostAuthorization: @escaping (
            SnippetsCloudPostAuthorizationTarget
        ) throws -> Void = { _ in }
    ) async throws {
        guard snippetsCloudEnabled,
              let coordinates = cloudCoordinates,
              let serverInstanceID = coordinates.serverInstanceID,
              coordinates.protocolMajor == 2,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingCredential
        }
        try requireNoPendingPostAuthorization()
        let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
        _ = try await oauth.selectExistingLibrary(
            serverURL: coordinates.serverURL,
            serverInstanceID: serverInstanceID,
            protocolMajor: 2,
            chooseLibrary: chooseLibrary,
            prepareSelectionCommit: { selected in
                guard let scopeBinding = selected.scopeBinding else {
                    throw Failure.postAuthorizationMembershipMismatch
                }
                try preparePostAuthorization(.init(
                    serverURL: coordinates.serverURL,
                    serverInstanceID: serverInstanceID,
                    protocolMajor: 2,
                    spaceID: selected.spaceID,
                    scopeBinding: scopeBinding))
            },
            commitSelection: { [defaults, keychain] selected in
                defaults.set(
                    coordinates.serverURL.absoluteString,
                    forKey: Self.serverDefaultsKey)
                defaults.set(
                    coordinates.serverURL.appending(path: "v2").absoluteString,
                    forKey: Self.apiBaseDefaultsKey)
                defaults.set(
                    selected.spaceID.uuidString.lowercased(),
                    forKey: Self.spaceDefaultsKey)
                defaults.set(
                    serverInstanceID.uuidString.lowercased(),
                    forKey: Self.serverInstanceDefaultsKey)
                defaults.set(2, forKey: Self.protocolMajorDefaultsKey)
                try? keychain.deleteItem(account: Self.tokenAccount)
            })
    }

    func resumeSnippetsCloudPostAuthorization(
        _ target: SnippetsCloudPostAuthorizationTarget
    ) async throws {
        guard snippetsCloudEnabled,
              target.protocolMajor == 2,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingCredential
        }
        let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
        do {
            try await oauth.validateExistingMembership(target) { [defaults, keychain] in
                defaults.set(target.serverURL.absoluteString, forKey: Self.serverDefaultsKey)
                defaults.set(
                    target.serverURL.appending(path: "v2").absoluteString,
                    forKey: Self.apiBaseDefaultsKey)
                defaults.set(target.spaceID.uuidString.lowercased(), forKey: Self.spaceDefaultsKey)
                defaults.set(
                    target.serverInstanceID.uuidString.lowercased(),
                    forKey: Self.serverInstanceDefaultsKey)
                defaults.set(target.protocolMajor, forKey: Self.protocolMajorDefaultsKey)
                try? keychain.deleteItem(account: Self.tokenAccount)
            }
        } catch SnippetsCloudOAuthClient.Failure.stepUpAccountMismatch {
            throw Failure.postAuthorizationMembershipMismatch
        } catch SnippetsCloudOAuthClient.Failure.invalidStoredSession,
                SnippetsCloudOAuthClient.Failure.tokenExchangeFailed {
            throw Failure.missingCredential
        }
    }

    func reauthenticateSnippetsCloudPostAuthorization(
        _ target: SnippetsCloudPostAuthorizationTarget,
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws {
        guard snippetsCloudEnabled,
              target.serverURL == Self.bundledServerURL,
              target.protocolMajor == 2,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingConfiguration
        }
        let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
        do {
            _ = try await oauth.signIn(
                serverURL: target.serverURL,
                existingSpaceID: target.spaceID,
                requiresStrongAuthentication: false,
                chooseAccount: true,
                expectedStepUpTarget: nil,
                expectedPostAuthorizationTarget: target,
                chooseLibrary: { _ in throw Failure.postAuthorizationMembershipMismatch },
                presentationContext: presentationContext,
                validateStepUpTarget: {},
                prepareCoordinatesCommit: { _ in },
                commitCoordinates: { [defaults, keychain] result in
                    defaults.set(result.serverURL.absoluteString, forKey: Self.serverDefaultsKey)
                    defaults.set(result.apiBaseURL.absoluteString, forKey: Self.apiBaseDefaultsKey)
                    defaults.set(
                        result.spaceID.uuidString.lowercased(),
                        forKey: Self.spaceDefaultsKey)
                    defaults.set(
                        result.serverInstanceID.uuidString.lowercased(),
                        forKey: Self.serverInstanceDefaultsKey)
                    defaults.set(result.protocolMajor, forKey: Self.protocolMajorDefaultsKey)
                    try? keychain.deleteItem(account: Self.tokenAccount)
                })
        } catch SnippetsCloudOAuthClient.Failure.stepUpAccountMismatch {
            throw Failure.postAuthorizationMembershipMismatch
        }
    }

    func signOutSnippetsCloud() async throws {
        if try pendingLocalEraseExists() {
            try resumePendingLocalErase()
            return
        }
        try await revokeSnippetsCloudSession()
        try forgetSnippetsCloudLocally()
    }

    func resumeInterruptedSignOut() async throws {
        if try pendingLocalEraseExists() {
            try resumePendingLocalErase()
            return
        }
        guard try pendingRemoteRevocationExists() else {
            return
        }
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

    /// Explicit escape hatch for a structurally unreadable OAuth lineage. Remote
    /// revocation cannot be reconstructed from corrupt bytes, so Settings must first
    /// warn the user to revoke Snippets in the identity provider. The local half still
    /// uses the normal journal-first erase and removes the library root before tokens.
    func resetUnreadableCloudCredentialsLocally(
        bootstrapSecrets: KeychainSecretStore? = nil
    ) throws {
        guard cloudCredentialResetRequired else {
            throw Failure.credentialCleanupRequired
        }
        try forgetSnippetsCloudLocally(bootstrapSecrets: bootstrapSecrets)
    }

    func resumePendingLocalErase(
        bootstrapSecrets: KeychainSecretStore? = nil
    ) throws {
        guard try keychain.loadItem(account: Self.pendingLocalEraseAccount) != nil else {
            return
        }

        let cloudLocations = try? protocolLocations(for: .snippetsCloud)

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
            Self.oauthSessionReplacementAccount,
            Self.oauthRevocationAccount,
        ] {
            do { try keychain.deleteItem(account: account) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }

        if let cloudLocations, FileManager.default.fileExists(
            atPath: cloudLocations.switchReceiptURL.path) {
            try AtomicFileWriter.removeDurablyIfPresent(cloudLocations.switchReceiptURL)
        }
        if FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncProviderSwitchFileURL.path) {
            try AtomicFileWriter.removeDurablyIfPresent(
                SnippetStorageLocations.syncProviderSwitchFileURL)
        }

        defaults.removeObject(forKey: Self.serverDefaultsKey)
        defaults.removeObject(forKey: Self.apiBaseDefaultsKey)
        defaults.removeObject(forKey: Self.spaceDefaultsKey)
        defaults.removeObject(forKey: Self.serverInstanceDefaultsKey)
        defaults.removeObject(forKey: Self.protocolMajorDefaultsKey)
        try commitProvider(.iCloud)
        try keychain.deleteItem(account: Self.pendingLocalEraseAccount)
    }

    func freshCloudAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard snippetsCloudEnabled else { throw Failure.featureDisabled }
        try requireNoPendingPostAuthorization()
        return try await freshCloudControlPlaneAccessToken(forceRefresh: forceRefresh)
    }

    /// Bootstrap and recovery calls are part of the account control plane. They must
    /// be able to finish the durable post-authorization transaction that intentionally
    /// fences the record-sync data plane.
    func freshCloudControlPlaneAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard snippetsCloudEnabled else { throw Failure.featureDisabled }
        if let failure = credentialLineageFailure() {
            switch failure {
            case .credentialCleanupRequired:
                // The token provider performs and awaits the same serialized cleanup.
                break
            default:
                throw failure
            }
        }
        guard !hasPendingLocalErase, !hasPendingRemoteRevocation else {
            throw Failure.missingCredential
        }
        guard let coordinates = cloudCoordinates,
              coordinates.serverURL == Self.bundledServerURL,
              coordinates.apiBaseURL == coordinates.serverURL.appending(path: "v2"),
              let serverInstanceID = coordinates.serverInstanceID,
              let protocolMajor = coordinates.protocolMajor,
              protocolMajor == 2,
              let redirectURL = Self.bundledOAuthRedirectURL else {
            throw Failure.missingConfiguration
        }
        return try await SnippetsCloudOAuthClient(
            keychain: keychain,
            redirectURL: redirectURL
        ).freshAccessToken(
            expectedServerURL: coordinates.serverURL,
            expectedServerInstanceID: serverInstanceID,
            expectedProtocolMajor: protocolMajor,
            forceRefresh: forceRefresh)
    }

    var hasCloudSession: Bool {
        guard snippetsCloudEnabled,
              !hasPendingLocalErase,
              !hasPendingRemoteRevocation,
              !hasPendingCredentialCleanup,
              let coordinates = cloudCoordinates,
              coordinates.apiBaseURL == coordinates.serverURL.appending(path: "v2"),
              let serverInstanceID = coordinates.serverInstanceID,
              let protocolMajor = coordinates.protocolMajor,
              protocolMajor == 2,
              let redirectURL = Self.bundledOAuthRedirectURL else { return false }
        return (try? SnippetsCloudOAuthClient(
            keychain: keychain,
            redirectURL: redirectURL
        ).currentTransportCredential(
            expectedServerURL: coordinates.serverURL,
            expectedServerInstanceID: serverInstanceID,
            expectedProtocolMajor: protocolMajor)) != nil
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
        if let providerSelectionFailure { throw providerSelectionFailure }
        switch provider {
        case .iCloud:
            // Snippets Cloud journals authorize and fence only that provider's local
            // root and credentials. `resumePendingLocalErase()` already attempts their
            // crash recovery during construction; neither a remaining marker nor a
            // temporarily unavailable credential Keychain may hold up the independent
            // iCloud/CloudKit data plane.
            return CloudKitTransport()
        case .snippetsCloud:
            guard snippetsCloudEnabled else { throw Failure.featureDisabled }
            try requireNoPendingPostAuthorization()
            do {
                guard try !pendingLocalEraseExists() else {
                    throw Failure.missingCredential
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.credentialStoreUnavailable
            }
            if let cleanupFailure = credentialLineageFailure() {
                if case .credentialCleanupRequired = cleanupFailure {
                    schedulePendingCredentialCleanup()
                }
                throw cleanupFailure
            }
            do {
                guard try !pendingRemoteRevocationExists() else {
                    throw Failure.missingCredential
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.credentialStoreUnavailable
            }
            guard let coordinates = Self.cloudCoordinates(in: defaults) else {
                throw Failure.missingConfiguration
            }
            guard coordinates.serverURL == Self.bundledServerURL,
                  coordinates.apiBaseURL == coordinates.serverURL.appending(path: "v2"),
                  let redirectURL = Self.bundledOAuthRedirectURL else {
                throw Failure.missingConfiguration
            }
            let oauth = SnippetsCloudOAuthClient(keychain: keychain, redirectURL: redirectURL)
            guard let expectedServerInstanceID = coordinates.serverInstanceID,
                  let expectedProtocolMajor = coordinates.protocolMajor,
                  expectedProtocolMajor == 2 else {
                throw Failure.missingConfiguration
            }
            let credential: SnippetsCloudOAuthClient.TransportCredential?
            do {
                credential = try oauth.currentTransportCredential(
                    expectedServerURL: coordinates.serverURL,
                    expectedServerInstanceID: expectedServerInstanceID,
                    expectedProtocolMajor: expectedProtocolMajor)
            } catch SnippetsCloudOAuthClient.Failure.invalidStoredSession {
                throw Failure.invalidCredential
            } catch {
                throw Failure.credentialStoreUnavailable
            }
            if let credential {
                return SnippetsCloudTransport(
                    configuration: try .init(
                        baseURL: coordinates.serverURL,
                        spaceID: coordinates.spaceID,
                        serverInstanceID: credential.serverInstanceID,
                        protocolMajor: credential.protocolMajor,
                        accessToken: credential.accessToken),
                    accessTokenProvider: { forceRefresh in
                        try await oauth.freshAccessToken(
                            expectedServerURL: coordinates.serverURL,
                            expectedServerInstanceID: expectedServerInstanceID,
                            expectedProtocolMajor: expectedProtocolMajor,
                            forceRefresh: forceRefresh)
                    })
            }
            let tokenData: Data
            do {
                guard let stored = try keychain.loadItem(account: Self.tokenAccount) else {
                    throw Failure.missingCredential
                }
                tokenData = stored
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.credentialStoreUnavailable
            }
            guard let token = String(data: tokenData, encoding: .utf8) else {
                throw Failure.invalidCredential
            }
            guard let serverInstanceID = coordinates.serverInstanceID,
                  let protocolMajor = coordinates.protocolMajor else {
                throw Failure.missingConfiguration
            }
            return SnippetsCloudTransport(configuration: try .init(
                baseURL: coordinates.serverURL,
                spaceID: coordinates.spaceID,
                serverInstanceID: serverInstanceID,
                protocolMajor: protocolMajor,
                accessToken: token))
        }
    }

    private func requireNoPendingPostAuthorization() throws {
        do {
            guard try bootstrapSecretsForRecovery.loadItem(
                account: SnippetsCloudAccountBootstrap.pendingPostAuthorizationAccount
            ) == nil else {
                throw Failure.postAuthorizationSetupRequired
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.postAuthorizationStateUnavailable
        }
    }

    func protocolLocations(
        for requestedProvider: Provider? = nil
    ) throws -> SyncProtocolLocations {
        if let providerSelectionFailure { throw providerSelectionFailure }
        let requestedProvider = requestedProvider ?? provider
        switch requestedProvider {
        case .iCloud:
            return .legacyICloud
        case .snippetsCloud:
            guard let coordinates = Self.cloudCoordinates(in: defaults),
                  let serverInstanceID = coordinates.serverInstanceID,
                  let protocolMajor = coordinates.protocolMajor,
                  protocolMajor == 2 else { throw Failure.missingConfiguration }
            let canonicalOrigin = coordinates.serverURL.absoluteString.lowercased()
            let material = [
                "snippets.sync.provider.v1", "http", canonicalOrigin,
                serverInstanceID.uuidString.lowercased(),
                coordinates.spaceID.uuidString.lowercased(), String(protocolMajor),
            ].joined(separator: "\u{0}")
            let opaqueKey = SHA256.hash(data: Data(material.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            guard let locations = SyncProtocolLocations.http(opaqueProviderKey: opaqueKey) else {
                throw Failure.missingConfiguration
            }
            return locations
        }
    }

    var interruptedProviderSwitch: ProviderSwitchReceipt? {
        guard case .loaded(let receipt) = loadProviderSwitchReceipt() else { return nil }
        return receipt
    }

    func prepareProviderSwitch(to target: Provider) throws -> ProviderSwitchReceipt {
        guard providerSelectionFailure == nil else {
            throw providerSelectionFailure ?? Failure.invalidProviderSelection
        }
        let source = provider
        guard source != target else { throw Failure.invalidProviderSelection }
        let sourceLocations = try protocolLocations(for: source)
        let targetLocations = try protocolLocations(for: target)
        try targetLocations.createDirectories()
        let receipt = ProviderSwitchReceipt(
            id: UUID(),
            source: source,
            target: target,
            sourceLocationID: sourceLocations.identifier,
            targetLocationID: targetLocations.identifier,
            phase: .prepared)
        try writeProviderSwitchReceipt(receipt)
        return receipt
    }

    func commitPreparedProviderSwitch(_ prepared: ProviderSwitchReceipt) throws {
        guard case .loaded(let current) = loadProviderSwitchReceipt(),
              current == prepared,
              current.phase == .prepared,
              provider == current.source else { throw Failure.switchStateUnreadable }
        var selected = current
        selected.phase = .targetSelected
        // The intent becomes durable before provider selection. Startup can therefore
        // finish this exact transition if the process dies at either following write.
        try writeProviderSwitchReceipt(selected)
        let targetLocations = try protocolLocations(for: selected.target)
        try AtomicFileWriter.write(
            try encodeProviderSwitchReceipt(selected),
            to: targetLocations.switchReceiptURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try commitProvider(selected.target)
    }

    func completeProviderSwitch() throws {
        guard case .loaded(let receipt) = loadProviderSwitchReceipt(),
              receipt.phase == .targetSelected,
              provider == receipt.target else { return }
        if let locations = try? protocolLocations(for: receipt.target) {
            try AtomicFileWriter.removeDurablyIfPresent(locations.switchReceiptURL)
        }
        try AtomicFileWriter.removeDurablyIfPresent(
            SnippetStorageLocations.syncProviderSwitchFileURL)
    }

    private enum SwitchReceiptLoad {
        case missing, loaded(ProviderSwitchReceipt), unreadable
    }

    private func migrateSyncPreferenceIfNeeded() {
        guard defaults.object(forKey: Self.syncEnabledDefaultsKey) == nil else { return }
        defaults.set(
            defaults.bool(forKey: Self.legacyICloudEnabledDefaultsKey),
            forKey: Self.syncEnabledDefaultsKey)
    }

    private func commitProvider(_ newValue: Provider) throws {
        // HTTP must disable the legacy CloudKit capability before it can become active.
        // Persist that downgrade fence as its own boundary: if the process dies after
        // this synchronize but before the provider preference is committed, an older
        // build still sees CloudKit disabled. The inverse transition selects iCloud
        // before enabling the legacy capability.
        if newValue != .iCloud {
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
            guard defaults.synchronize() else {
                providerSelectionFailure = .preferenceStoreUnavailable
                throw Failure.preferenceStoreUnavailable
            }
        }
        defaults.set(newValue.rawValue, forKey: Self.providerDefaultsKey)
        if newValue == .iCloud, syncEnabled {
            defaults.set(true, forKey: Self.legacyICloudEnabledDefaultsKey)
        }
        guard defaults.synchronize() else {
            providerSelectionFailure = .preferenceStoreUnavailable
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
            _ = defaults.synchronize()
            throw Failure.preferenceStoreUnavailable
        }
        providerSelectionFailure = nil
    }

    private func mirrorLegacyICloudPreference() {
        let raw = defaults.string(forKey: Self.providerDefaultsKey)
        let recognized = raw == nil || Provider(rawValue: raw ?? "") != nil
        if providerSelectionFailure != nil || !recognized || provider != .iCloud || !syncEnabled {
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
        } else {
            defaults.set(true, forKey: Self.legacyICloudEnabledDefaultsKey)
        }
        _ = defaults.synchronize()
    }

    private func recoverInterruptedProviderSwitch() {
        let rawProvider = defaults.string(forKey: Self.providerDefaultsKey)
        if let rawProvider, Provider(rawValue: rawProvider) == nil {
            providerSelectionFailure = .invalidProviderSelection
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
            return
        }
        switch loadProviderSwitchReceipt() {
        case .missing:
            break
        case .unreadable:
            providerSelectionFailure = .switchStateUnreadable
            defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
        case .loaded(let receipt):
            guard let source = try? protocolLocations(for: receipt.source),
                  let target = try? protocolLocations(for: receipt.target),
                  source.identifier == receipt.sourceLocationID,
                  target.identifier == receipt.targetLocationID else {
                providerSelectionFailure = .switchStateUnreadable
                defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
                return
            }
            switch receipt.phase {
            case .prepared:
                if provider == receipt.source {
                    try? AtomicFileWriter.removeDurablyIfPresent(
                        SnippetStorageLocations.syncProviderSwitchFileURL)
                } else if provider == receipt.target {
                    var selected = receipt
                    selected.phase = .targetSelected
                    try? writeProviderSwitchReceipt(selected)
                } else {
                    providerSelectionFailure = .switchStateUnreadable
                }
            case .targetSelected:
                do {
                    try commitProvider(receipt.target)
                } catch {
                    providerSelectionFailure = .preferenceStoreUnavailable
                    defaults.set(false, forKey: Self.legacyICloudEnabledDefaultsKey)
                    _ = defaults.synchronize()
                }
            }
        }
    }

    private func loadProviderSwitchReceipt() -> SwitchReceiptLoad {
        let url = SnippetStorageLocations.syncProviderSwitchFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                  "schemaVersion", "id", "source", "target", "sourceLocationID",
                  "targetLocationID", "phase",
              ],
              let receipt = try? JSONDecoder().decode(ProviderSwitchReceipt.self, from: data),
              receipt.schemaVersion == ProviderSwitchReceipt.currentSchemaVersion,
              receipt.source != receipt.target,
              !receipt.sourceLocationID.isEmpty,
              !receipt.targetLocationID.isEmpty else { return .unreadable }
        return .loaded(receipt)
    }

    private func writeProviderSwitchReceipt(_ receipt: ProviderSwitchReceipt) throws {
        try FileManager.default.createDirectory(
            at: SnippetStorageLocations.syncFolderURL, withIntermediateDirectories: true)
        try AtomicFileWriter.write(
            try encodeProviderSwitchReceipt(receipt),
            to: SnippetStorageLocations.syncProviderSwitchFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
    }

    private func encodeProviderSwitchReceipt(_ receipt: ProviderSwitchReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(receipt)
    }

}

@MainActor
private final class SnippetsCloudOAuthClient {
    /// All OAuth client instances, including transport-owned instances, share this
    /// process-wide mutation gate.
    private static let credentialMutationGate = SnippetsCloudCredentialMutationGate()

    struct SignInResult {
        let serverURL: URL
        let apiBaseURL: URL
        let spaceID: UUID
        let serverInstanceID: UUID
        let protocolMajor: Int
        let scopeBinding: String
    }

    struct TransportCredential {
        let accessToken: String
        let serverInstanceID: UUID
        let protocolMajor: Int
    }

    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case invalidServerURL
        case insecureServerProfile
        case discoveryUnavailable
        case identityProviderUnavailable
        case authorizationCancelled
        case authorizationMismatch
        case tokenExchangeFailed
        case backgroundAccessMissing
        case spaceSelectionRequired
        case readOnlyLibraryUnavailable
        case stepUpAccountMismatch
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
            case .readOnlyLibraryUnavailable: "This account has no writable Snippets library. Reader access cannot be used as active sync storage."
            case .stepUpAccountMismatch: "Sign in with the same account that owns the currently connected Snippets library. Nothing changed."
            case .invalidStoredSession: "The saved Snippets Cloud session is invalid. Sign in again."
            }
        }

        var errorDescription: String? { description }
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
        struct Limits: Decodable {
            let maxBlobBytes: Int
            let maxRevisionBytes: Int
            let maxBatchRecords: Int
            let maxPageRecords: Int
            let maxRequestBytes: Int
            let maxResponseBytes: Int
            let maxKeyEnvelopeBytes: Int
            let maxPairingSeconds: Int
        }
        let protocolMajor: Int
        let serverInstanceId: UUID
        let apiBase: URL
        let oidc: OIDC
        let limits: Limits
        let recordProfile: String
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
        let apiBase: URL?
        let serverInstanceID: UUID?
        let protocolMajor: Int?
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
        let replacementKind: SnippetsCloudCredentialReplacementKind?
    }

    struct SpacesResponse: Decodable { let spaces: [Space] }
    struct Space: Decodable {
        struct Scope: Decodable {
            let serverInstanceId: UUID
            let spaceId: UUID
            let scopeBinding: String
            let datasetGeneration: UUID
            let feedEpoch: UUID
        }
        let scope: Scope
        let role: String

        var spaceId: UUID { scope.spaceId }
    }

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
        chooseAccount: Bool,
        expectedStepUpTarget: SnippetsCloudStepUpTarget?,
        expectedPostAuthorizationTarget: SnippetsCloudPostAuthorizationTarget?,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        presentationContext: any ASWebAuthenticationPresentationContextProviding,
        validateStepUpTarget: @escaping () throws -> Void,
        prepareCoordinatesCommit: @escaping (SignInResult) throws -> Void,
        commitCoordinates: @escaping (SignInResult) throws -> Void
    ) async throws -> SignInResult {
        guard requiresStrongAuthentication == (expectedStepUpTarget != nil),
              expectedStepUpTarget == nil || expectedPostAuthorizationTarget == nil,
              expectedPostAuthorizationTarget == nil ||
                (!requiresStrongAuthentication && chooseAccount),
              !(requiresStrongAuthentication && chooseAccount) else {
            throw Failure.invalidStoredSession
        }
        return try await Self.credentialMutationGate.run { [self] in
            try await retireSupersededInteractiveSessionsWithoutGate()
            if expectedStepUpTarget != nil {
                try validateStepUpTarget()
            }
            let expectedStepUpBinding: SnippetsCloudStepUpBinding?
            if let expectedStepUpTarget {
                guard expectedStepUpTarget.serverURL == serverURL,
                      expectedStepUpTarget.protocolMajor == 2 else {
                    throw Failure.invalidStoredSession
                }
                let currentToken = try await freshAccessTokenWithoutGate(
                    expectedServerURL: expectedStepUpTarget.serverURL,
                    expectedServerInstanceID: expectedStepUpTarget.serverInstanceID,
                    expectedProtocolMajor: expectedStepUpTarget.protocolMajor,
                    forceRefresh: false)
                let current: Space = try await authorizedJSON(
                    url: serverURL.appending(
                        path: "v2/spaces/\(expectedStepUpTarget.spaceID.uuidString.lowercased())"),
                    method: "GET",
                    accessToken: currentToken)
                guard current.scope.serverInstanceId == expectedStepUpTarget.serverInstanceID,
                      current.scope.spaceId == expectedStepUpTarget.spaceID,
                      (32...256).contains(current.scope.scopeBinding.utf8.count),
                      ["owner", "writer"].contains(current.role) else {
                    throw Failure.invalidStoredSession
                }
                expectedStepUpBinding = SnippetsCloudStepUpBinding(
                    serverURL: serverURL,
                    serverInstanceID: current.scope.serverInstanceId,
                    spaceID: current.scope.spaceId,
                    scopeBinding: current.scope.scopeBinding)
            } else {
                expectedStepUpBinding = nil
            }
            do {
                let result = try await performSignIn(
                    serverURL: serverURL,
                    existingSpaceID: existingSpaceID,
                    requiresStrongAuthentication: requiresStrongAuthentication,
                    chooseAccount: chooseAccount,
                    expectedStepUpBinding: expectedStepUpBinding,
                    expectedPostAuthorizationTarget: expectedPostAuthorizationTarget,
                    chooseLibrary: chooseLibrary,
                    presentationContext: presentationContext,
                    prepareCoordinatesCommit: prepareCoordinatesCommit)
                try commitCoordinates(result)
                return result
            } catch {
                // If token exchange already journaled a candidate, revoke it before
                // returning. Failure leaves the journal as a fail-closed retry boundary.
                do {
                    try await retireSupersededInteractiveSessionsWithoutGate()
                } catch {
                    throw Failure.invalidStoredSession
                }
                throw error
            }
        }
    }

    private func performSignIn(
        serverURL: URL,
        existingSpaceID: UUID?,
        requiresStrongAuthentication: Bool,
        chooseAccount: Bool,
        expectedStepUpBinding: SnippetsCloudStepUpBinding?,
        expectedPostAuthorizationTarget: SnippetsCloudPostAuthorizationTarget?,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        presentationContext: any ASWebAuthenticationPresentationContextProviding,
        prepareCoordinatesCommit: @escaping (SignInResult) throws -> Void
    ) async throws -> SignInResult {
        guard !(requiresStrongAuthentication && chooseAccount) else {
            throw Failure.invalidStoredSession
        }
        guard try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthRevocationAccount) == nil
        else { throw Failure.invalidStoredSession }
        // Capture the active generation before the first await. At commit we verify
        // that logout or another interactive sign-in did not replace it while the
        // browser was open. Every observed/new generation is journaled first.
        let sessionAtStart = try loadSession()
        if let sessionAtStart,
           let replacements = try loadSessionReplacementJournal(boundTo: sessionAtStart) {
            guard replacements.accessTokens.count < 16,
                  replacements.refreshTokens.count < 16 else {
                throw Failure.invalidStoredSession
            }
        }
        let serverURL = try validatedBaseURL(serverURL)
        let discoveryURL = serverURL.appending(path: ".well-known/snippets-sync")
        let discovery: Discovery = try await getJSON(
            discoveryURL,
            maximumBytes: 256 * 1_024,
            failure: .discoveryUnavailable)
        guard discovery.protocolMajor == 2,
              discovery.recordProfile == "snippets-wire-v1",
              discovery.limits.maxBlobBytes == 900_000,
              discovery.limits.maxRevisionBytes == 256,
              discovery.limits.maxBatchRecords == 50,
              discovery.limits.maxPageRecords == 50,
              discovery.limits.maxRequestBytes == 16 * 1_024 * 1_024,
              discovery.limits.maxResponseBytes == 64 * 1_024 * 1_024,
              discovery.limits.maxKeyEnvelopeBytes == 4_096,
              discovery.limits.maxPairingSeconds == 600,
              discovery.apiBase == serverURL.appending(path: "v2"),
              try validatedBaseURL(discovery.oidc.resource) == serverURL,
              discovery.oidc.authorizationFlow == "authorization_code_pkce",
              discovery.capabilities.contains("oidc-pkce"),
              discovery.capabilities.contains("oauth-resource-indicators"),
              discovery.capabilities.contains("oauth-token-revocation"),
              discovery.capabilities.contains("oauth-refresh-token-rotation"),
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
        if let sessionAtStart {
            // A grant can only be journaled and later revoked by the authority that
            // minted it. Reject a changed issuer/client/revocation endpoint before
            // opening the browser or exchanging a code, never after a new refresh
            // token already exists.
            guard sessionAtStart.serverURL == serverURL,
                  sessionAtStart.issuer == issuer,
                  sessionAtStart.resource == discovery.oidc.resource,
                  sessionAtStart.revocationEndpoint == provider.revocationEndpoint,
                  sessionAtStart.clientID == discovery.oidc.clientId else {
                throw Failure.invalidStoredSession
            }
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
        } else if chooseAccount {
            requestItems.append(URLQueryItem(name: "prompt", value: "select_account"))
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

        let stored = StoredSession(
            schemaVersion: 5,
            serverURL: serverURL,
            apiBase: discovery.apiBase,
            serverInstanceID: discovery.serverInstanceId,
            protocolMajor: discovery.protocolMajor,
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
        // Persist the newly minted grant before any further await. If space lookup,
        // selection, or process lifetime fails, startup sees B as an abandoned
        // generation and revokes both its resource session and refresh token.
        try storeSessionReplacementJournal(
            sessions: [sessionAtStart, stored].compactMap { $0 },
            kind: .interactiveReplacement)
        let selectedMembership: SnippetsCloudLibraryChoice
        if let expectedStepUpBinding {
            let candidate: Space
            do {
                candidate = try await authorizedJSON(
                    url: serverURL.appending(
                        path: "v2/spaces/\(expectedStepUpBinding.spaceID.uuidString.lowercased())"),
                    method: "GET",
                    accessToken: token.accessToken)
            } catch let failure as HTTPFailure where [
                "not_found", "forbidden", "authentication_required"
            ].contains(failure.code) {
                throw Failure.stepUpAccountMismatch
            }
            guard expectedStepUpBinding.matches(
                serverURL: serverURL,
                serverInstanceID: candidate.scope.serverInstanceId,
                spaceID: candidate.scope.spaceId,
                scopeBinding: candidate.scope.scopeBinding,
                role: candidate.role) else {
                throw Failure.stepUpAccountMismatch
            }
            selectedMembership = SnippetsCloudLibraryChoice(
                spaceID: candidate.scope.spaceId,
                serverInstanceID: candidate.scope.serverInstanceId,
                role: candidate.role,
                scopeBinding: candidate.scope.scopeBinding)
        } else if let expectedPostAuthorizationTarget {
            let candidate: Space
            do {
                candidate = try await authorizedJSON(
                    url: serverURL.appending(
                        path: "v2/spaces/\(expectedPostAuthorizationTarget.spaceID.uuidString.lowercased())"),
                    method: "GET",
                    accessToken: token.accessToken)
            } catch let failure as HTTPFailure where [
                "not_found", "forbidden", "authentication_required"
            ].contains(failure.code) {
                throw Failure.stepUpAccountMismatch
            }
            guard expectedPostAuthorizationTarget.serverURL == serverURL,
                  expectedPostAuthorizationTarget.serverInstanceID
                    == candidate.scope.serverInstanceId,
                  expectedPostAuthorizationTarget.protocolMajor == 2,
                  expectedPostAuthorizationTarget.spaceID == candidate.scope.spaceId,
                  expectedPostAuthorizationTarget.scopeBinding
                    == candidate.scope.scopeBinding,
                  ["owner", "writer"].contains(candidate.role) else {
                throw Failure.stepUpAccountMismatch
            }
            selectedMembership = SnippetsCloudLibraryChoice(
                spaceID: candidate.scope.spaceId,
                serverInstanceID: candidate.scope.serverInstanceId,
                role: candidate.role,
                scopeBinding: candidate.scope.scopeBinding)
        } else {
            selectedMembership = try await resolvePersonalSpace(
                serverURL: serverURL,
                serverInstanceID: discovery.serverInstanceId,
                accessToken: token.accessToken,
                existingSpaceID: existingSpaceID,
                confirmAccountChange: chooseAccount,
                chooseLibrary: chooseLibrary)
        }
        let sessionAtCommit = try loadSession()
        try storeSessionReplacementJournal(
            sessions: [sessionAtStart, sessionAtCommit, stored].compactMap { $0 },
            kind: .interactiveReplacement)
        guard sameTokenGeneration(sessionAtStart, sessionAtCommit),
              try keychain.loadItem(
                account: SyncBackendSelectionStore.oauthRevocationAccount) == nil,
              try keychain.loadItem(
                account: SyncBackendSelectionStore.pendingLocalEraseAccount) == nil
        else { throw Failure.invalidStoredSession }
        let result = SignInResult(
            serverURL: serverURL,
            apiBaseURL: discovery.apiBase,
            spaceID: selectedMembership.spaceID,
            serverInstanceID: discovery.serverInstanceId,
            protocolMajor: discovery.protocolMajor,
            scopeBinding: selectedMembership.scopeBinding ?? "")
        guard (32...256).contains(result.scopeBinding.utf8.count) else {
            throw Failure.spaceSelectionRequired
        }
        // Bootstrap intent precedes publication of the candidate credential. On a
        // restart it can complete or reject the exact membership without guessing
        // whether the selected library is new.
        try prepareCoordinatesCommit(result)
        try keychain.storeItem(
            try JSONEncoder().encode(stored),
            account: SyncBackendSelectionStore.oauthSessionAccount)
        try await retireSupersededInteractiveSessionsWithoutGate()
        return result
    }

    func selectExistingLibrary(
        serverURL: URL,
        serverInstanceID: UUID,
        protocolMajor: Int,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        prepareSelectionCommit: @escaping (SnippetsCloudLibraryChoice) throws -> Void,
        commitSelection: @escaping (SnippetsCloudLibraryChoice) throws -> Void
    ) async throws -> UUID {
        return try await Self.credentialMutationGate.run { [self] in
            try await retireSupersededInteractiveSessionsWithoutGate()
            let serverURL = try validatedBaseURL(serverURL)
            let accessToken = try await freshAccessTokenWithoutGate(
                expectedServerURL: serverURL,
                expectedServerInstanceID: serverInstanceID,
                expectedProtocolMajor: protocolMajor,
                forceRefresh: false)
            let selected = try await selectExistingLibraryWithoutGate(
                serverURL: serverURL,
                serverInstanceID: serverInstanceID,
                accessToken: accessToken,
                chooseLibrary: chooseLibrary)
            try prepareSelectionCommit(selected)
            try commitSelection(selected)
            return selected.spaceID
        }
    }

    func validateExistingMembership(
        _ target: SnippetsCloudPostAuthorizationTarget,
        commitCoordinates: @escaping () throws -> Void
    ) async throws {
        try await Self.credentialMutationGate.run { [self] in
            try await retireSupersededInteractiveSessionsWithoutGate()
            let serverURL = try validatedBaseURL(target.serverURL)
            let accessToken = try await freshAccessTokenWithoutGate(
                expectedServerURL: serverURL,
                expectedServerInstanceID: target.serverInstanceID,
                expectedProtocolMajor: target.protocolMajor,
                forceRefresh: false)
            let current: Space = try await authorizedJSON(
                url: serverURL.appending(
                    path: "v2/spaces/\(target.spaceID.uuidString.lowercased())"),
                method: "GET",
                accessToken: accessToken)
            guard current.scope.serverInstanceId == target.serverInstanceID,
                  current.scope.spaceId == target.spaceID,
                  current.scope.scopeBinding == target.scopeBinding,
                  ["owner", "writer"].contains(current.role) else {
                throw Failure.stepUpAccountMismatch
            }
            try commitCoordinates()
        }
    }

    private func selectExistingLibraryWithoutGate(
        serverURL: URL,
        serverInstanceID: UUID,
        accessToken: String,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID
    ) async throws -> SnippetsCloudLibraryChoice {
        let response: SpacesResponse = try await authorizedJSON(
            url: serverURL.appending(path: "v2/spaces"),
            method: "GET",
            accessToken: accessToken)
        guard response.spaces.allSatisfy({ space in
            space.scope.serverInstanceId == serverInstanceID
                && (32...256).contains(space.scope.scopeBinding.utf8.count)
                && ["owner", "writer", "reader"].contains(space.role)
        }) else { throw Failure.insecureServerProfile }
        let choices = response.spaces.map { space in
            SnippetsCloudLibraryChoice(
                spaceID: space.spaceId,
                serverInstanceID: space.scope.serverInstanceId,
                role: space.role,
                scopeBinding: space.scope.scopeBinding)
        }.filter(\.canWrite)
        guard !choices.isEmpty else { throw Failure.readOnlyLibraryUnavailable }
        let selectedID = try await chooseLibrary(choices)
        guard let selected = choices.first(where: { $0.spaceID == selectedID }),
              let expectedBinding = selected.scopeBinding else {
            throw Failure.spaceSelectionRequired
        }
        let current: Space = try await authorizedJSON(
            url: serverURL.appending(
                path: "v2/spaces/\(selectedID.uuidString.lowercased())"),
            method: "GET",
            accessToken: accessToken)
        guard current.scope.serverInstanceId == serverInstanceID,
              current.scope.spaceId == selectedID,
              current.scope.scopeBinding == expectedBinding,
              ["owner", "writer"].contains(current.role) else {
            throw Failure.spaceSelectionRequired
        }
        return SnippetsCloudLibraryChoice(
            spaceID: current.scope.spaceId,
            serverInstanceID: current.scope.serverInstanceId,
            role: current.role,
            scopeBinding: current.scope.scopeBinding)
    }

    func currentTransportCredential(
        expectedServerURL: URL,
        expectedServerInstanceID: UUID,
        expectedProtocolMajor: Int
    ) throws -> TransportCredential? {
        guard try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount) == nil
        else { throw Failure.invalidStoredSession }
        guard let stored = try loadSession() else { return nil }
        try validateServerBinding(
            stored,
            expectedServerURL: expectedServerURL,
            expectedServerInstanceID: expectedServerInstanceID,
            expectedProtocolMajor: expectedProtocolMajor)
        guard let serverInstanceID = stored.serverInstanceID,
              let protocolMajor = stored.protocolMajor,
              protocolMajor == 2 else {
            throw Failure.invalidStoredSession
        }
        return TransportCredential(
            accessToken: stored.accessToken,
            serverInstanceID: serverInstanceID,
            protocolMajor: protocolMajor)
    }

    func freshAccessToken(
        expectedServerURL: URL,
        expectedServerInstanceID: UUID,
        expectedProtocolMajor: Int,
        forceRefresh: Bool = false
    ) async throws -> String {
        try await Self.credentialMutationGate.run { [self] in
            try await freshAccessTokenWithoutGate(
                expectedServerURL: expectedServerURL,
                expectedServerInstanceID: expectedServerInstanceID,
                expectedProtocolMajor: expectedProtocolMajor,
                forceRefresh: forceRefresh)
        }
    }

    private func freshAccessTokenWithoutGate(
        expectedServerURL: URL,
        expectedServerInstanceID: UUID,
        expectedProtocolMajor: Int,
        forceRefresh: Bool
    ) async throws -> String {
        // A transport that was constructed before interactive replacement still has
        // to cross the durable cleanup boundary on every request. Never hand out B
        // while an older A from its journal may remain remotely usable.
        try await retireSupersededInteractiveSessionsWithoutGate()
        guard try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthRevocationAccount) == nil
        else { throw Failure.invalidStoredSession }
        guard let stored = try loadSession() else { throw Failure.invalidStoredSession }
        try validateServerBinding(
            stored,
            expectedServerURL: expectedServerURL,
            expectedServerInstanceID: expectedServerInstanceID,
            expectedProtocolMajor: expectedProtocolMajor)
        guard stored.serverInstanceID != nil, stored.protocolMajor == 2 else {
            throw Failure.invalidStoredSession
        }
        if !forceRefresh, stored.expiresAt.timeIntervalSinceNow > 60 {
            return stored.accessToken
        }
        return try await performRefresh(stored)
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
        guard let refreshToken = token.refreshToken,
              refreshToken != stored.refreshToken,
              token.accessToken != stored.accessToken,
              token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (8...16_384).contains(token.accessToken.utf8.count),
              !token.accessToken.contains(where: \.isWhitespace),
              (8...16_384).contains(refreshToken.utf8.count),
              !refreshToken.contains(where: \.isWhitespace),
              (60...86_400).contains(token.expiresIn) else {
            throw Failure.tokenExchangeFailed
        }
        try validateResourceAudience(accessToken: token.accessToken, resource: stored.resource)
        let updated = StoredSession(
            schemaVersion: 5,
            serverURL: stored.serverURL,
            apiBase: stored.apiBase,
            serverInstanceID: stored.serverInstanceID,
            protocolMajor: stored.protocolMajor,
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
        // During logout, retain every issued token family member and abort before
        // replacing the stored session. The logout transaction owns the lineage.
        let joinedRevocation = try extendRevocationJournalIfPresent(with: [stored, updated])
        if joinedRevocation {
            throw Failure.invalidStoredSession
        }
        // Ordinary refresh is also a credential-replacement transaction. Journal A/B
        // before publishing B, then revoke A and clear the journal. A crash before the
        // session write retires B while keeping A; a crash after it retires A while
        // keeping B. No token generation can disappear from durable lineage.
        try storeSessionReplacementJournal(
            sessions: [stored, updated],
            kind: .refreshRotation)
        try keychain.storeItem(
            try JSONEncoder().encode(updated),
            account: SyncBackendSelectionStore.oauthSessionAccount)
        try await retireSupersededInteractiveSessionsWithoutGate()
        guard try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount) == nil
        else { throw Failure.invalidStoredSession }
        return updated.accessToken
    }

    private func validateServerBinding(
        _ stored: StoredSession,
        expectedServerURL: URL,
        expectedServerInstanceID: UUID? = nil,
        expectedProtocolMajor: Int? = nil
    ) throws {
        guard (try? validatedBaseURL(expectedServerURL)) == stored.serverURL,
              expectedServerInstanceID == nil
                || stored.serverInstanceID == expectedServerInstanceID,
              expectedProtocolMajor == nil
                || stored.protocolMajor == expectedProtocolMajor else {
            throw Failure.invalidStoredSession
        }
    }

    private func loadSession() throws -> StoredSession? {
        guard let data = try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthSessionAccount) else { return nil }
        guard data.count <= 128 * 1_024,
              let value = try? JSONDecoder().decode(StoredSession.self, from: data),
              (value.schemaVersion == 4 || value.schemaVersion == 5),
              (value.schemaVersion == 4
                ? value.serverInstanceID == nil
                    && value.protocolMajor == nil
                    && value.apiBase == nil
                : value.protocolMajor == 2
                    && value.apiBase == value.serverURL.appending(path: "v2")),
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
        try await Self.credentialMutationGate.run { [self] in
            try await revokeCurrentSessionWithoutGate(
                expectedServerURL: expectedServerURL)
        }
    }

    private func revokeCurrentSessionWithoutGate(expectedServerURL: URL) async throws {
        let expectedServerURL = try validatedBaseURL(expectedServerURL)
        var stored = try loadSession()
        if let stored {
            try validateServerBinding(stored, expectedServerURL: expectedServerURL)
        }
        var replacement = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount,
            expectedServerURL: expectedServerURL,
            boundTo: stored)
        var revocationJournal = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthRevocationAccount,
            expectedServerURL: expectedServerURL,
            boundTo: stored)
        guard revocationJournal != nil || replacement != nil || stored != nil else { return }
        let initialAuthority = revocationJournal
            ?? replacement
            ?? makeRevocationJournal(sessions: [stored!])
        revocationJournal = try mergedCredentialJournal(
            authority: initialAuthority,
            journals: [revocationJournal, replacement].compactMap { $0 },
            sessions: [stored].compactMap { $0 })
        try storeRevocationJournal(revocationJournal!)

        // Refresh, interactive replacement, cleanup, and logout all hold the same
        // process-wide gate, so no newer generation can appear after this merge.
        stored = try loadSession()
        if let stored {
            try validateServerBinding(stored, expectedServerURL: expectedServerURL)
        }
        replacement = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount,
            expectedServerURL: expectedServerURL,
            boundTo: stored)
        guard let durableJournal = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthRevocationAccount,
            expectedServerURL: expectedServerURL,
            boundTo: stored) else { throw Failure.invalidStoredSession }
        revocationJournal = try mergedCredentialJournal(
            authority: durableJournal,
            journals: [durableJournal, replacement].compactMap { $0 },
            sessions: [stored].compactMap { $0 })
        try storeRevocationJournal(revocationJournal!)
        guard let revocationJournal else { throw Failure.invalidStoredSession }
        let plan = SnippetsCloudCredentialRevocationPlan(
            sessionAccessToken: stored?.accessToken,
            sessionRefreshToken: stored?.refreshToken,
            journalAccessTokens: revocationJournal.accessTokens,
            journalRefreshTokens: revocationJournal.refreshTokens)

        // Revoke every access-token generation from the journal. In particular, do
        // not try to refresh merely because the old primary session gets 401: after
        // a crash the next, still-valid generation may exist only in this journal.
        // A 401 is terminally safe for that credential because it cannot authorize
        // the data plane; provider revocation below closes every refresh generation.
        try await revokeCredentialPlan(plan, authority: revocationJournal)
        // Keep the remote-intent journal until the caller durably records local erase.
        // If the process dies here, startup repeats these idempotent RFC 7009/resource
        // revocations and then removes the root key.
    }

    func retireSupersededInteractiveSessions() async throws {
        try await Self.credentialMutationGate.run { [self] in
            try await retireSupersededInteractiveSessionsWithoutGate()
        }
    }

    struct CredentialLineageInspection {
        let hasSession: Bool
        let hasReplacement: Bool
        let hasRevocation: Bool
    }

    func inspectCredentialLineage() throws -> CredentialLineageInspection {
        let current = try loadSession()
        let replacement = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount,
            boundTo: current)
        let revocation = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthRevocationAccount,
            boundTo: current)
        if let replacement, let revocation,
           !credentialAuthorityMatches(replacement, revocation) {
            throw Failure.invalidStoredSession
        }
        return CredentialLineageInspection(
            hasSession: current != nil,
            hasReplacement: replacement != nil,
            hasRevocation: revocation != nil)
    }

    private func retireSupersededInteractiveSessionsWithoutGate() async throws {
        let current = try loadSession()
        let replacement = try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount,
            boundTo: current)
        guard let replacement else { return }
        guard let cleanup = SnippetsCloudCredentialReplacementCleanupPlan(
            currentAccessToken: current?.accessToken,
            currentRefreshToken: current?.refreshToken,
            journalAccessTokens: replacement.accessTokens,
            journalRefreshTokens: replacement.refreshTokens,
            replacementKind: replacement.replacementKind ?? .interactiveReplacement)
        else { throw Failure.invalidStoredSession }
        try await revokeResourceAccessTokens(
            cleanup.accessTokensToRetire,
            authority: replacement)
        // Before AUTH_SESSION commits, later journal entries are abandoned newly
        // minted grants and must be revoked. After it commits, earlier refresh tokens
        // belong to the same rotated family; revoking them may kill the new session,
        // so rotation/reuse protection is the authority that makes them unusable.
        if !cleanup.abandonedRefreshTokens.isEmpty {
            try await revokeProviderCredentials(
                SnippetsCloudCredentialRevocationPlan(
                    sessionAccessToken: nil,
                    sessionRefreshToken: nil,
                    journalAccessTokens: [],
                    journalRefreshTokens: cleanup.abandonedRefreshTokens),
                authority: replacement)
        }
        try keychain.deleteItem(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)
    }

    private func revokeCredentialPlan(
        _ plan: SnippetsCloudCredentialRevocationPlan,
        authority: RevocationJournal
    ) async throws {
        try await revokeResourceAccessTokens(plan.accessTokens, authority: authority)
        try await revokeProviderCredentials(plan, authority: authority)
    }

    private func revokeProviderCredentials(
        _ plan: SnippetsCloudCredentialRevocationPlan,
        authority: RevocationJournal
    ) async throws {
        func revokeAtProvider(_ token: String, hint: String) async throws {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "client_id", value: authority.clientID),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "token_type_hint", value: hint),
            ]
            guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
                throw Failure.tokenExchangeFailed
            }
            var request = URLRequest(url: authority.revocationEndpoint)
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
        for token in plan.accessTokens {
            try await revokeAtProvider(token, hint: "access_token")
        }
        for token in plan.refreshTokens {
            try await revokeAtProvider(token, hint: "refresh_token")
        }
    }

    private func revokeResourceAccessTokens(
        _ tokens: [String],
        authority: RevocationJournal
    ) async throws {
        for token in tokens {
            var request = URLRequest(
                url: authority.serverURL.appending(path: "v2/session"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization")
            let (body, response) = try await boundedResponse(
                request,
                maximumBytes: 256 * 1_024)
            guard let http = response as? HTTPURLResponse,
                  response.url == request.url,
                  http.statusCode != 204 || body.isEmpty,
                  http.statusCode == 204 || http.statusCode == 401 else {
                throw Failure.tokenExchangeFailed
            }
        }
    }

    private func loadRevocationJournal(
        boundTo stored: StoredSession
    ) throws -> RevocationJournal? {
        try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthRevocationAccount,
            boundTo: stored)
    }

    private func loadSessionReplacementJournal(
        boundTo stored: StoredSession
    ) throws -> RevocationJournal? {
        try loadCredentialJournal(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount,
            boundTo: stored)
    }

    private func loadCredentialJournal(
        account: String,
        expectedServerURL: URL? = nil,
        boundTo stored: StoredSession? = nil
    ) throws -> RevocationJournal? {
        guard let data = try keychain.loadItem(
            account: account) else { return nil }
        guard data.count <= 256 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.invalidStoredSession }
        let baseKeys: Set<String> = [
            "schemaVersion", "serverURL", "issuer", "resource",
            "revocationEndpoint", "clientID", "accessTokens", "refreshTokens",
        ]
        let keys = Set(object.keys)
        guard keys == baseKeys
                || (account == SyncBackendSelectionStore.oauthSessionReplacementAccount
                    && keys == baseKeys.union(["replacementKind"])),
              let journal = try? JSONDecoder().decode(RevocationJournal.self, from: data),
              journal.schemaVersion == 1,
              journal.replacementKind == nil
                || account == SyncBackendSelectionStore.oauthSessionReplacementAccount,
              (try? validatedBaseURL(journal.serverURL)) == journal.serverURL,
              (try? validatedBaseURL(journal.resource)) == journal.serverURL,
              (try? validatedIssuer(journal.issuer)) == journal.issuer,
              (try? secureEndpoint(journal.revocationEndpoint)) == journal.revocationEndpoint,
              !journal.clientID.isEmpty, journal.clientID.utf8.count <= 256,
              expectedServerURL == nil || journal.serverURL == expectedServerURL,
              stored == nil || credentialAuthorityMatches(journal, stored!),
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

    /// Records every interactive OAuth generation before replacing the active
    /// session. This is deliberately separate from the logout-intent journal: its
    /// presence must not disable a valid newly authenticated session, while a later
    /// logout still has durable authority to revoke every older token family.
    private func storeSessionReplacementJournal(
        sessions: [StoredSession],
        kind: SnippetsCloudCredentialReplacementKind
    ) throws {
        guard let first = sessions.first,
              sessions.allSatisfy({ credentialAuthorityMatches($0, first) }) else {
            throw Failure.invalidStoredSession
        }
        let existing = try loadSessionReplacementJournal(boundTo: first)
        guard existing?.replacementKind == nil || existing?.replacementKind == kind else {
            throw Failure.invalidStoredSession
        }
        let journal = RevocationJournal(
            schemaVersion: 1,
            serverURL: first.serverURL,
            issuer: first.issuer,
            resource: first.resource,
            revocationEndpoint: first.revocationEndpoint,
            clientID: first.clientID,
            accessTokens: orderedUnique(
                (existing?.accessTokens ?? []) + sessions.map(\.accessToken)),
            refreshTokens: orderedUnique(
                (existing?.refreshTokens ?? []) + sessions.map(\.refreshToken)),
            replacementKind: kind)
        try storeCredentialJournal(
            journal,
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)
    }

    private func mergedCredentialJournal(
        authority: RevocationJournal,
        journals: [RevocationJournal],
        sessions: [StoredSession]
    ) throws -> RevocationJournal {
        guard journals.allSatisfy({ credentialAuthorityMatches($0, authority) }),
              sessions.allSatisfy({ credentialAuthorityMatches(authority, $0) }) else {
            throw Failure.invalidStoredSession
        }
        return RevocationJournal(
            schemaVersion: 1,
            serverURL: authority.serverURL,
            issuer: authority.issuer,
            resource: authority.resource,
            revocationEndpoint: authority.revocationEndpoint,
            clientID: authority.clientID,
            accessTokens: orderedUnique(
                journals.flatMap(\.accessTokens) + sessions.map(\.accessToken)),
            refreshTokens: orderedUnique(
                journals.flatMap(\.refreshTokens) + sessions.map(\.refreshToken)),
            replacementKind: nil)
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
                existing.refreshTokens + sessions.map(\.refreshToken)),
            replacementKind: nil)
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
            refreshTokens: orderedUnique(sessions.map(\.refreshToken)),
            replacementKind: nil)
    }

    private func storeRevocationJournal(_ journal: RevocationJournal) throws {
        try storeCredentialJournal(
            journal,
            account: SyncBackendSelectionStore.oauthRevocationAccount)
    }

    private func storeCredentialJournal(
        _ journal: RevocationJournal,
        account: String
    ) throws {
        guard journal.accessTokens.count <= 16, journal.refreshTokens.count <= 16 else {
            throw Failure.invalidStoredSession
        }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 256 * 1_024 else { throw Failure.invalidStoredSession }
        try keychain.storeItem(
            data,
            account: account)
    }

    private func credentialAuthorityMatches(
        _ lhs: StoredSession,
        _ rhs: StoredSession
    ) -> Bool {
        lhs.serverURL == rhs.serverURL
            && lhs.issuer == rhs.issuer
            && lhs.resource == rhs.resource
            && lhs.revocationEndpoint == rhs.revocationEndpoint
            && lhs.clientID == rhs.clientID
    }

    private func credentialAuthorityMatches(
        _ lhs: RevocationJournal,
        _ rhs: StoredSession
    ) -> Bool {
        lhs.serverURL == rhs.serverURL
            && lhs.issuer == rhs.issuer
            && lhs.resource == rhs.resource
            && lhs.revocationEndpoint == rhs.revocationEndpoint
            && lhs.clientID == rhs.clientID
    }

    private func credentialAuthorityMatches(
        _ lhs: RevocationJournal,
        _ rhs: RevocationJournal
    ) -> Bool {
        lhs.serverURL == rhs.serverURL
            && lhs.issuer == rhs.issuer
            && lhs.resource == rhs.resource
            && lhs.revocationEndpoint == rhs.revocationEndpoint
            && lhs.clientID == rhs.clientID
    }

    private func sameTokenGeneration(
        _ lhs: StoredSession?,
        _ rhs: StoredSession?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            credentialAuthorityMatches(lhs, rhs)
                && lhs.accessToken == rhs.accessToken
                && lhs.refreshToken == rhs.refreshToken
        default: false
        }
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
        serverInstanceID: UUID,
        accessToken: String,
        existingSpaceID: UUID?,
        confirmAccountChange: Bool,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID
    ) async throws -> SnippetsCloudLibraryChoice {
        let response: SpacesResponse = try await authorizedJSON(
            url: serverURL.appending(path: "v2/spaces"),
            method: "GET",
            accessToken: accessToken)
        guard response.spaces.allSatisfy({
            $0.scope.serverInstanceId == serverInstanceID
                && (32...256).contains($0.scope.scopeBinding.utf8.count)
        }) else { throw Failure.insecureServerProfile }
        guard response.spaces.allSatisfy({ ["owner", "writer", "reader"].contains($0.role) })
        else { throw Failure.insecureServerProfile }
        let discoveredChoices = response.spaces.map {
            SnippetsCloudLibraryChoice(
                spaceID: $0.spaceId,
                serverInstanceID: $0.scope.serverInstanceId,
                role: $0.role,
                scopeBinding: $0.scope.scopeBinding)
        }
        let choices = discoveredChoices.filter(\.canWrite)
        if choices.isEmpty && !discoveredChoices.isEmpty {
            throw Failure.readOnlyLibraryUnavailable
        }
        func validateCurrentMembership(
            _ choice: SnippetsCloudLibraryChoice
        ) async throws -> SnippetsCloudLibraryChoice {
            guard let expectedBinding = choice.scopeBinding else {
                throw Failure.spaceSelectionRequired
            }
            let current: Space = try await authorizedJSON(
                url: serverURL.appending(
                    path: "v2/spaces/\(choice.spaceID.uuidString.lowercased())"),
                method: "GET",
                accessToken: accessToken)
            guard current.scope.serverInstanceId == choice.serverInstanceID,
                  current.scope.spaceId == choice.spaceID,
                  current.scope.scopeBinding == expectedBinding else {
                throw Failure.spaceSelectionRequired
            }
            guard ["owner", "writer"].contains(current.role) else {
                throw Failure.readOnlyLibraryUnavailable
            }
            return SnippetsCloudLibraryChoice(
                spaceID: current.scope.spaceId,
                serverInstanceID: current.scope.serverInstanceId,
                role: current.role,
                scopeBinding: current.scope.scopeBinding)
        }
        if let automatic = automaticSnippetsCloudLibraryChoice(
            choices,
            existingSpaceID: existingSpaceID
        ) {
            guard let choice = choices.first(where: { $0.spaceID == automatic }) else {
                throw Failure.spaceSelectionRequired
            }
            if confirmAccountChange, existingSpaceID != automatic {
                let selected = try await chooseLibrary([choice])
                guard selected == automatic else { throw Failure.spaceSelectionRequired }
            }
            return try await validateCurrentMembership(choice)
        }
        if !choices.isEmpty {
            let selected = try await chooseLibrary(choices)
            guard let choice = choices.first(where: { $0.spaceID == selected }) else {
                throw Failure.spaceSelectionRequired
            }
            return try await validateCurrentMembership(choice)
        }
        let idempotencyKey = UUID(uuidString: "7b28d156-77fd-4f7f-bdf3-234f7d97ac91")!
        let created: Space = try await authorizedJSON(
            url: serverURL.appending(path: "v2/spaces"),
            method: "POST",
            accessToken: accessToken,
            additionalHeaders: [
                "Idempotency-Key": idempotencyKey.uuidString.lowercased()
            ])
        guard created.scope.serverInstanceId == serverInstanceID,
              (32...256).contains(created.scope.scopeBinding.utf8.count),
              ["owner", "writer"].contains(created.role) else {
            throw Failure.insecureServerProfile
        }
        if confirmAccountChange, existingSpaceID != nil {
            let choice = SnippetsCloudLibraryChoice(
                spaceID: created.spaceId,
                serverInstanceID: created.scope.serverInstanceId,
                role: created.role,
                scopeBinding: created.scope.scopeBinding)
            let selected = try await chooseLibrary([choice])
            guard selected == created.spaceId else { throw Failure.spaceSelectionRequired }
            return try await validateCurrentMembership(choice)
        }
        return try await validateCurrentMembership(.init(
            spaceID: created.spaceId,
            serverInstanceID: created.scope.serverInstanceId,
            role: created.role,
            scopeBinding: created.scope.scopeBinding))
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
        body: Data? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
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
