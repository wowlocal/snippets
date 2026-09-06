import Foundation
import CryptoKit
import Security

/// One trace spans UI preflight, native email sign-in and library setup. Nested owners borrow it;
/// the outermost operation emits the sole terminal result. Cleanup cannot overwrite
/// the first failure with the generic error eventually presented to the user.
@MainActor
final class SnippetsCloudSignInDiagnostics {
    private let started = ProcessInfo.processInfo.systemUptime
    private let record: (DiagnosticEvent) -> Void
    private var running = false
    private(set) var stage: DiagnosticCloudSignInStage = .preflight
    var storedSessionPresent: Bool?
    var reason: DiagnosticCloudSignInReason?
    private var captured: (DiagnosticCloudSignInStage, DiagnosticCloudSignInReason, DiagnosticFailure)?

    init(record: @escaping (DiagnosticEvent) -> Void = { Diagnostics.record($0) }) {
        self.record = record
    }

    func enter(_ stage: DiagnosticCloudSignInStage) {
        self.stage = stage
        reason = nil
        emit(stage: stage, outcome: .entered)
    }

    func capture(_ error: any Error) {
        guard captured == nil else { return }
        captured = (stage, reason ?? Self.classify(error), DiagnosticFailure(error))
    }

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        let ownsResult = !running
        if ownsResult {
            running = true
            enter(.preflight)
        }
        defer { if ownsResult { running = false } }
        do {
            let result = try await operation()
            if ownsResult { emit(stage: stage, outcome: .succeeded) }
            return result
        } catch {
            capture(error)
            if ownsResult, let (stage, reason, failure) = captured {
                emit(stage: stage,
                     outcome: reason == .authorizationCancelled ? .cancelled : .failed,
                     reason: reason, failure: failure)
            }
            throw error
        }
    }

    private func emit(
        stage: DiagnosticCloudSignInStage, outcome: DiagnosticCloudSignInOutcome,
        reason: DiagnosticCloudSignInReason? = nil, failure: DiagnosticFailure? = nil
    ) {
        record(.cloudSignIn(stage: stage, outcome: outcome,
            durationMilliseconds: Int64(max(0, ProcessInfo.processInfo.systemUptime - started) * 1_000),
            storedSessionPresent: storedSessionPresent, reason: reason, failure: failure))
    }

    private static func classify(_ error: any Error) -> DiagnosticCloudSignInReason {
        if error is CancellationError { return .authorizationCancelled }
        if let failure = error as? SnippetsCloudEmailSignInFailure {
            return switch failure {
            case .invalidEmail: .invalidEmail
            case .invalidCode: .invalidCode
            case .codeExpired: .codeExpired
            case .tooManyAttempts: .tooManyAttempts
            case .rateLimited: .rateLimited
            case .unavailable: .requestFailed
            case .invalidResponse: .invalidJSON
            case .cancelled: .authorizationCancelled
            }
        }
        if let failure = error as? SnippetsCloudNativeAuthClient.Failure {
            return switch failure {
            case .invalidServerURL: .invalidConfiguration
            case .insecureServerProfile: .insecureServerProfile
            case .discoveryUnavailable: .discoveryUnavailable
            case .identityProviderUnavailable: .identityProviderUnavailable
            case .authorizationCancelled: .authorizationCancelled
            case .authorizationMismatch: .authorizationMismatch
            case .tokenExchangeFailed: .tokenExchangeFailed
            case .backgroundAccessMissing: .backgroundAccessMissing
            case .spaceSelectionRequired, .readOnlyLibraryUnavailable: .librarySelectionRequired
            case .stepUpAccountMismatch: .accountMismatch
            case .invalidStoredSession: .invalidStoredSession
            }
        }
        if let failure = error as? SyncBackendSelectionStore.Failure {
            switch failure {
            case .featureDisabled, .missingConfiguration: return .invalidConfiguration
            default: return .localState
            }
        }
        return .other
    }
}

/// Build-time dark-launch gate for the first-party Snippets Cloud service.
///
/// Shipping builds leave `SNIPPETS_CLOUD_ENABLED` at `NO`. Supplying endpoints alone
/// is deliberately insufficient: an internal build must opt in to both the feature and
/// its pinned server coordinates before any account UI or HTTP data plane can run.
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

/// Cloud credentials and bootstrap state belong to one app's local connection.
/// The shared Keychain access group is for iCloud keys; it must not make Debug
/// consume Release's Cloud session while using a separate UserDefaults domain.
nonisolated enum SnippetsCloudKeychainScope {
    enum Store: String, CaseIterable {
        case credentials = "com.khm.snippets.sync-http"
        case bootstrap = "com.khm.snippets.cloud-bootstrap"
        case libraryKey = "com.khm.snippets.cloud-library-key"
    }

    static func service(
        for store: Store,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        // The unshipped API used unscoped services. Do not import their sessions
        // into an app that has no matching local connection or verified profile.
        "\(store.rawValue).\(bundleIdentifier ?? "unbundled")"
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

struct SnippetsCloudStepUpTarget: Equatable {
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
/// awaits. MainActor alone is reentrant, so without this gate code verification could
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
/// Non-secret coordinates live in UserDefaults. Native access/refresh tokens are
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
    fileprivate static let credentialService = SnippetsCloudKeychainScope.service(for: .credentials)

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
    private let nativeAuthSessionConfiguration: URLSessionConfiguration
    let snippetsCloudEnabled: Bool
    let cloudKeys: SnippetsCloudKeyStore
    private(set) var providerSelectionFailure: Failure?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainSecretStore? = nil,
        cloudKeys: SnippetsCloudKeyStore? = nil,
        bootstrapSecrets: KeychainSecretStore? = nil,
        snippetsCloudEnabled: Bool = SnippetsCloudFeature.isEnabled,
        defersCredentialRecovery: Bool = false,
        nativeAuthSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.defaults = defaults
        self.snippetsCloudEnabled = snippetsCloudEnabled
        self.nativeAuthSessionConfiguration = nativeAuthSessionConfiguration
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
        if defersCredentialRecovery {
            Task { @MainActor [weak self, keychain = self.keychain] in
                // Even an absent marker is synchronous Security.framework IPC. The
                // common iCloud launch must not pay its unbounded latency on MainActor.
                let pending = try? await keychain.loadItemInBackground(
                    account: Self.pendingLocalEraseAccount)
                guard let self else { return }
                if pending != nil { try? self.resumePendingLocalErase() }
                self.resumeCredentialLineageIfNeeded()
            }
        } else {
            try? resumePendingLocalErase()
            resumeCredentialLineageIfNeeded()
        }
    }

    private func resumeCredentialLineageIfNeeded() {
        // Shipping builds expose only iCloud. Credential replacement/revocation state
        // belongs exclusively to the dark-launched Snippets Cloud data plane, and that
        // plane revalidates the same lineage before constructing a transport. Avoid
        // making every ordinary iCloud launch synchronously read three unrelated
        // Keychain items. The local-erase journal remains above this gate because it is
        // the crash-safe tail of an already-authorized destructive operation and must
        // finish even if a later build disables Snippets Cloud.
        guard snippetsCloudEnabled else { return }
        let startupLineage = try? SnippetsCloudNativeAuthClient(
            keychain: self.keychain
        ).inspectCredentialLineage()
        if startupLineage?.hasRevocation == true {
            // The remote intent journal is written before the first logout request and
            // retained through provider success. A crash in the network/local handoff
            // therefore resumes idempotently instead of leaving a usable local root.
            Task { @MainActor [weak self] in
                try? await self?.resumeInterruptedSignOut()
            }
        } else if startupLineage?.hasReplacement == true {
            // This also covers a crash after a first token exchange journaled its
            // credentials but before AUTH_SESSION was committed. With no current
            // session every journal token is superseded and is remotely revoked.
            Task { @MainActor [credentialStore = self.keychain] in
                try? await SnippetsCloudNativeAuthClient(
                    keychain: credentialStore
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
        do {
            let lineage = try SnippetsCloudNativeAuthClient(
                keychain: keychain
            ).inspectCredentialLineage()
            return lineage.hasReplacement || lineage.hasRevocation
                ? .credentialCleanupRequired : nil
        } catch SnippetsCloudNativeAuthClient.Failure.invalidStoredSession {
            return .credentialResetRequired
        } catch {
            return .credentialStoreUnavailable
        }
    }

    private func schedulePendingCredentialCleanup() {
        guard hasPendingCredentialCleanup,
              !hasPendingRemoteRevocation else { return }
        Task { @MainActor [credentialStore = keychain] in
            // Success removes the durable boundary. Failure deliberately leaves it in
            // place; makeTransport and every token provider keep the data plane closed,
            // while Try Again/startup can schedule another awaited cleanup attempt.
            try? await SnippetsCloudNativeAuthClient(
                keychain: credentialStore
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

    var cloudAccountDisplayName: String {
        return SnippetsCloudNativeAuthClient(keychain: keychain).verifiedProfile()?.displayName
            ?? "Snippets Cloud account"
    }


    func signIn(
        serverURL: URL,
        diagnostics: SnippetsCloudSignInDiagnostics,
        requiresStrongAuthentication: Bool = false,
        chooseAccount: Bool = false,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        authenticate: @escaping @MainActor (SnippetsCloudEmailSignInFlow) async throws -> Void,
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
                // The native flow owns serialized cleanup before sending an email code.
                break
            default:
                throw failure
            }
        }
        guard let pinnedServerURL = Self.bundledServerURL,
              serverURL == pinnedServerURL else {
            throw Failure.missingConfiguration
        }
        let oauth = SnippetsCloudNativeAuthClient(keychain: keychain)
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
            diagnostics: diagnostics,
            existingSpaceID: cloudCoordinates?.serverURL == serverURL
                ? cloudCoordinates?.spaceID
                : nil,
            requiresStrongAuthentication: requiresStrongAuthentication,
            chooseAccount: chooseAccount,
            expectedStepUpTarget: expectedStepUpTarget,
            expectedPostAuthorizationTarget: nil,
            chooseLibrary: chooseLibrary,
            authenticate: authenticate,
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
              coordinates.protocolMajor == 2 else {
            throw Failure.missingCredential
        }
        try requireNoPendingPostAuthorization()
        let oauth = SnippetsCloudNativeAuthClient(keychain: keychain)
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
              target.protocolMajor == 2 else {
            throw Failure.missingCredential
        }
        let oauth = SnippetsCloudNativeAuthClient(keychain: keychain)
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
        } catch SnippetsCloudNativeAuthClient.Failure.stepUpAccountMismatch {
            throw Failure.postAuthorizationMembershipMismatch
        } catch SnippetsCloudNativeAuthClient.Failure.invalidStoredSession,
                SnippetsCloudNativeAuthClient.Failure.tokenExchangeFailed {
            throw Failure.missingCredential
        }
    }

    func reauthenticateSnippetsCloudPostAuthorization(
        _ target: SnippetsCloudPostAuthorizationTarget,
        authenticate: @escaping @MainActor (SnippetsCloudEmailSignInFlow) async throws -> Void
    ) async throws {
        guard snippetsCloudEnabled,
              target.serverURL == Self.bundledServerURL,
              target.protocolMajor == 2 else {
            throw Failure.missingConfiguration
        }
        let oauth = SnippetsCloudNativeAuthClient(keychain: keychain)
        do {
            _ = try await oauth.signIn(
                serverURL: target.serverURL,
                existingSpaceID: target.spaceID,
                requiresStrongAuthentication: false,
                chooseAccount: true,
                expectedStepUpTarget: nil,
                expectedPostAuthorizationTarget: target,
                chooseLibrary: { _ in throw Failure.postAuthorizationMembershipMismatch },
                authenticate: authenticate,
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
        } catch SnippetsCloudNativeAuthClient.Failure.stepUpAccountMismatch {
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
        guard let coordinates = cloudCoordinates else {
            throw Failure.missingConfiguration
        }
        try await SnippetsCloudNativeAuthClient(
            keychain: keychain,
            sessionConfiguration: nativeAuthSessionConfiguration
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

    /// Explicit escape hatch for a structurally unreadable credential lineage. Remote
    /// revocation cannot be reconstructed from corrupt bytes, so Settings must first
    /// warn that remote sessions can remain active until expiry. The local half still
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
              protocolMajor == 2 else {
            throw Failure.missingConfiguration
        }
        return try await SnippetsCloudNativeAuthClient(
            keychain: keychain
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
              protocolMajor == 2 else { return false }
        return (try? SnippetsCloudNativeAuthClient(
            keychain: keychain
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
                  coordinates.apiBaseURL == coordinates.serverURL.appending(path: "v2") else {
                throw Failure.missingConfiguration
            }
            let oauth = SnippetsCloudNativeAuthClient(keychain: keychain)
            guard let expectedServerInstanceID = coordinates.serverInstanceID,
                  let expectedProtocolMajor = coordinates.protocolMajor,
                  expectedProtocolMajor == 2 else {
                throw Failure.missingConfiguration
            }
            let credential: SnippetsCloudNativeAuthClient.TransportCredential?
            do {
                credential = try oauth.currentTransportCredential(
                    expectedServerURL: coordinates.serverURL,
                    expectedServerInstanceID: expectedServerInstanceID,
                    expectedProtocolMajor: expectedProtocolMajor)
            } catch SnippetsCloudNativeAuthClient.Failure.invalidStoredSession {
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
final class SnippetsCloudNativeAuthClient {
    /// All native auth client instances, including transport-owned instances, share this
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
            case .insecureServerProfile: "This server does not support native email sign-in for Snippets Cloud."
            case .discoveryUnavailable: "Snippets Cloud discovery is temporarily unavailable."
            case .identityProviderUnavailable: "The identity provider is temporarily unavailable."
            case .authorizationCancelled: "Sign-in was cancelled. Nothing changed."
            case .authorizationMismatch: "The sign-in response did not match this request."
            case .tokenExchangeFailed: "Snippets Cloud could not complete sign-in. Please sign in again."
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
        struct NativeAuth: Decodable {
            let flow: String
            let startEndpoint: URL
            let verifyEndpoint: URL
            let refreshEndpoint: URL
            let revokeEndpoint: URL
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
        let nativeAuth: NativeAuth
        let limits: Limits
        let recordProfile: String
        let capabilities: [String]
    }

    struct TokenResponse: Decodable {
        struct Account: Decodable { let id: String; let email: String }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String
        let account: Account

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case account
        }
    }

    private struct EmailCodeResponse: Decodable {
        let challengeId: String
        let expiresIn: Int
        let resendAfter: Int
        let codeLength: Int
    }

    struct StoredSession: Codable {
        var profile: SnippetsCloudVerifiedProfile? = nil
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
    private let session: URLSession

    init(keychain: KeychainSecretStore, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.keychain = keychain
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        session = URLSession(configuration: sessionConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func signIn(
        serverURL: URL,
        diagnostics suppliedDiagnostics: SnippetsCloudSignInDiagnostics? = nil,
        existingSpaceID: UUID?,
        requiresStrongAuthentication: Bool,
        chooseAccount: Bool,
        expectedStepUpTarget: SnippetsCloudStepUpTarget?,
        expectedPostAuthorizationTarget: SnippetsCloudPostAuthorizationTarget?,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        authenticate: @escaping @MainActor (SnippetsCloudEmailSignInFlow) async throws -> Void,
        validateStepUpTarget: @escaping () throws -> Void,
        prepareCoordinatesCommit: @escaping (SignInResult) throws -> Void,
        commitCoordinates: @escaping (SignInResult) throws -> Void
    ) async throws -> SignInResult {
        let diagnostics = suppliedDiagnostics ?? SnippetsCloudSignInDiagnostics()
        return try await diagnostics.run {
            // Email proves account ownership, never phishing-resistant step-up.
            guard !requiresStrongAuthentication, expectedStepUpTarget == nil else {
                throw Failure.invalidStoredSession
            }
            return try await Self.credentialMutationGate.run { [self] in
                do {
                    let result = try await performSignIn(
                        serverURL: serverURL, diagnostics: diagnostics,
                        existingSpaceID: existingSpaceID, chooseAccount: chooseAccount,
                        expectedPostAuthorizationTarget: expectedPostAuthorizationTarget,
                        chooseLibrary: chooseLibrary, authenticate: authenticate,
                        prepareCoordinatesCommit: prepareCoordinatesCommit)
                    diagnostics.enter(.coordinateCommit)
                    try commitCoordinates(result)
                    return result
                } catch {
                    diagnostics.capture(error)
                    do { try await retireSupersededInteractiveSessionsWithoutGate() }
                    catch { throw Failure.invalidStoredSession }
                    throw error
                }
            }
        }
    }

    private func performSignIn(
        serverURL: URL,
        diagnostics: SnippetsCloudSignInDiagnostics,
        existingSpaceID: UUID?,
        chooseAccount: Bool,
        expectedPostAuthorizationTarget: SnippetsCloudPostAuthorizationTarget?,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        authenticate: @escaping @MainActor (SnippetsCloudEmailSignInFlow) async throws -> Void,
        prepareCoordinatesCommit: @escaping (SignInResult) throws -> Void
    ) async throws -> SignInResult {
        let serverURL = try validatedBaseURL(serverURL)
        var sessionAtStart: StoredSession?
        var preparedDiscovery: Discovery?
        var challengeID: String?
        var requestedEmail: String?
        var candidate: StoredSession?
        var issuedToken: TokenResponse?
        let flow = SnippetsCloudEmailSignInFlow(sendCode: { [self] email in
            if preparedDiscovery == nil {
                diagnostics.enter(.credentialCleanup)
                try await retireSupersededInteractiveSessionsWithoutGate()
                diagnostics.enter(.storedSession)
                guard try keychain.loadItem(account: SyncBackendSelectionStore.oauthRevocationAccount) == nil else {
                    throw Failure.invalidStoredSession
                }
                sessionAtStart = try loadSession()
                diagnostics.storedSessionPresent = sessionAtStart != nil
                diagnostics.enter(.serverDiscovery)
                let discovery = try await nativeDiscovery(serverURL: serverURL)
                diagnostics.enter(.sessionBinding)
                if let sessionAtStart {
                    try validateServerBinding(sessionAtStart, expectedServerURL: serverURL,
                        expectedServerInstanceID: discovery.serverInstanceId, expectedProtocolMajor: 2)
                }
                preparedDiscovery = discovery
            }
            guard let discovery = preparedDiscovery else { throw Failure.invalidStoredSession }
            diagnostics.enter(.emailCodeSend)
            let response: EmailCodeResponse = try await nativeRequest(
                endpoint: discovery.nativeAuth.startEndpoint, values: ["email": email], diagnosticEndpoint: .emailCodeSend)
            guard (32...256).contains(response.challengeId.utf8.count),
                  response.challengeId.utf8.allSatisfy({ (33...126).contains($0) }),
                  (1...1_800).contains(response.expiresIn), (0...600).contains(response.resendAfter),
                  response.codeLength == 6 else { throw SnippetsCloudEmailSignInFailure.invalidResponse }
            challengeID = response.challengeId
            requestedEmail = email
            return SnippetsCloudEmailChallenge(email: email,
                expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
                resendAvailableAt: Date().addingTimeInterval(TimeInterval(response.resendAfter)),
                codeLength: response.codeLength)
        }, verifyCode: { [self] code in
            guard let discovery = preparedDiscovery, let challengeID, candidate == nil else {
                throw SnippetsCloudEmailSignInFailure.codeExpired
            }
            diagnostics.enter(.emailCodeVerify)
            let token: TokenResponse = try await nativeRequest(
                endpoint: discovery.nativeAuth.verifyEndpoint,
                values: ["challengeId": challengeID, "code": code], diagnosticEndpoint: .emailCodeVerify)
            // A bounded token pair grants revocation authority even if the server's
            // account/expiry metadata is rejected below.
            try validateNativeTokenPair(token)
            let stored = StoredSession(
                profile: .init(issuer: serverURL.absoluteString, subject: token.account.id, name: nil, email: token.account.email),
                schemaVersion: 6, serverURL: serverURL, apiBase: discovery.apiBase,
                serverInstanceID: discovery.serverInstanceId, protocolMajor: 2,
                issuer: serverURL, resource: serverURL,
                tokenEndpoint: discovery.nativeAuth.refreshEndpoint,
                revocationEndpoint: discovery.nativeAuth.revokeEndpoint,
                clientID: "native-email-code-v1", maximumAccessTokenAgeSeconds: 300,
                accessToken: token.accessToken, refreshToken: token.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(min(max(token.expiresIn, 1), 300))))
            // No await between receiving credentials and recording their revocation authority.
            // Even cancellation of the native sheet must retire this candidate safely.
            diagnostics.enter(.credentialJournal)
            try storeSessionReplacementJournal(sessions: [sessionAtStart, stored].compactMap { $0 }, kind: .interactiveReplacement)
            try validateNativeToken(token)
            guard token.account.email.lowercased() == requestedEmail else { throw Failure.authorizationMismatch }
            candidate = stored
            issuedToken = token
        })
        do {
            // The native sheet appears before any discovery/cleanup network request.
            try await authenticate(flow)
        } catch {
            await flow.cancelAndWait()
            throw error
        }
        await flow.cancelAndWait()
        guard let discovery = preparedDiscovery, let stored = candidate, let token = issuedToken else {
            throw Failure.authorizationCancelled
        }
        try Task.checkCancellation()
        diagnostics.enter(.librarySelection)
        let selectedMembership: SnippetsCloudLibraryChoice
        if let expectedPostAuthorizationTarget {
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
        diagnostics.enter(.credentialCommit)
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
        let token: TokenResponse = try await nativeRequest(
            endpoint: stored.tokenEndpoint, values: ["refreshToken": stored.refreshToken])
        try validateNativeTokenPair(token)
        let refreshToken = token.refreshToken
        let updated = StoredSession(
            profile: .init(issuer: stored.serverURL.absoluteString, subject: token.account.id,
                           name: nil, email: token.account.email),
            schemaVersion: 6,
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
        // Journal before validating account metadata or publishing the new session.
        // A crash before commit revokes the uncommitted rotated family and requires
        // sign-in again. After commit only the obsolete access token is retired;
        // revoking its refresh token would also invalidate the new generation.
        try storeSessionReplacementJournal(
            sessions: [stored, updated],
            kind: .refreshRotation)
        try validateNativeToken(token)
        guard refreshToken != stored.refreshToken, token.accessToken != stored.accessToken,
              token.account.id == stored.profile?.subject else { throw Failure.tokenExchangeFailed }
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

    func verifiedProfile() -> SnippetsCloudVerifiedProfile? { try? loadSession()?.profile }

    private func loadSession() throws -> StoredSession? {
        guard let data = try keychain.loadItem(
            account: SyncBackendSelectionStore.oauthSessionAccount) else { return nil }
        guard data.count <= 128 * 1_024,
              let value = try? JSONDecoder().decode(StoredSession.self, from: data),
              value.schemaVersion == 6,
              value.serverInstanceID != nil, value.protocolMajor == 2,
              value.apiBase == value.serverURL.appending(path: "v2"),
              value.clientID == "native-email-code-v1",
              value.issuer == value.serverURL,
              value.tokenEndpoint == value.serverURL.appending(path: "v2/auth/refresh"),
              value.revocationEndpoint == value.serverURL.appending(path: "v2/auth/revoke"),
              value.profile?.issuer == value.serverURL.absoluteString,
              value.profile?.subject.isEmpty == false,
              !value.clientID.isEmpty, value.clientID.utf8.count <= 256,
              value.maximumAccessTokenAgeSeconds == 300,
              validToken(value.accessToken), validToken(value.refreshToken),
              value.accessToken != value.refreshToken,
              value.profile.map({ (1...256).contains($0.subject.utf8.count)
                  && !$0.subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  && SnippetsCloudEmailSignInFlow.isValidEmail($0.email ?? "") }) == true,
              value.expiresAt.timeIntervalSince1970.isFinite,
              value.expiresAt.timeIntervalSinceNow <= 360,
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
        // If the process dies here, startup repeats these idempotent native/resource
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
            var request = URLRequest(url: authority.revocationEndpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(["token": token, "tokenTypeHint": hint])
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await boundedResponse(
                request,
                maximumBytes: 256 * 1_024)
            guard let http = response as? HTTPURLResponse,
                  response.url == request.url, http.statusCode == 204 else { throw Failure.tokenExchangeFailed }
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
              journal.schemaVersion == 2,
              journal.issuer == journal.serverURL,
              journal.clientID == "native-email-code-v1",
              journal.revocationEndpoint == journal.serverURL.appending(path: "v2/auth/revoke"),
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

    /// Records every interactive sign-in generation before replacing the active
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
            schemaVersion: 2,
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
            schemaVersion: 2,
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
            schemaVersion: 2,
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
            schemaVersion: 2,
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
        (32...512).contains(token.utf8.count)
            && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
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

    private func nativeDiscovery(serverURL: URL) async throws -> Discovery {
        let discovery: Discovery = try await getJSON(
            serverURL.appending(path: ".well-known/snippets-sync"), maximumBytes: 256 * 1_024,
            failure: .discoveryUnavailable, diagnosticEndpoint: .serverDiscovery)
        guard discovery.protocolMajor == 2, discovery.serverInstanceId != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              discovery.recordProfile == "snippets-wire-v1",
              discovery.apiBase == serverURL.appending(path: "v2"),
              discovery.limits.maxBlobBytes == 900_000, discovery.limits.maxRevisionBytes == 256,
              discovery.limits.maxBatchRecords == 50, discovery.limits.maxPageRecords == 50,
              discovery.limits.maxRequestBytes == 16 * 1_024 * 1_024,
              discovery.limits.maxResponseBytes == 64 * 1_024 * 1_024,
              discovery.limits.maxKeyEnvelopeBytes == 4_096, discovery.limits.maxPairingSeconds == 600,
              (1...16).contains(discovery.capabilities.count),
              Set(discovery.capabilities).count == discovery.capabilities.count,
              discovery.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              ["native-email-code-v1", "library-action-proof-v1", "pairing-v2", "offline-recovery-v1", "resource-session-revocation"]
                .allSatisfy(discovery.capabilities.contains),
              discovery.nativeAuth.flow == "email_code",
              discovery.nativeAuth.startEndpoint == serverURL.appending(path: "v2/auth/email/start"),
              discovery.nativeAuth.verifyEndpoint == serverURL.appending(path: "v2/auth/email/verify"),
              discovery.nativeAuth.refreshEndpoint == serverURL.appending(path: "v2/auth/refresh"),
              discovery.nativeAuth.revokeEndpoint == serverURL.appending(path: "v2/auth/revoke") else {
            throw Failure.insecureServerProfile
        }
        return discovery
    }

    private func validateNativeTokenPair(_ token: TokenResponse) throws {
        guard validToken(token.accessToken), validToken(token.refreshToken),
              token.accessToken != token.refreshToken else { throw Failure.tokenExchangeFailed }
    }

    private func validateNativeToken(_ token: TokenResponse) throws {
        try validateNativeTokenPair(token)
        guard token.tokenType == "Bearer", (1...300).contains(token.expiresIn),
              (1...256).contains(token.account.id.utf8.count),
              !token.account.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              SnippetsCloudEmailSignInFlow.isValidEmail(token.account.email) else {
            throw Failure.tokenExchangeFailed
        }
    }

    private func nativeRequest<Response: Decodable>(
        endpoint: URL, values: [String: String],
        diagnosticEndpoint: DiagnosticCloudSignInEndpoint? = nil
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(values)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let started = ProcessInfo.processInfo.systemUptime
        var status: Int?
        var reason: DiagnosticCloudSignInReason = .requestFailed
        func record(_ outcome: DiagnosticCloudSignInRequestOutcome, error: (any Error)? = nil) {
            guard let diagnosticEndpoint else { return }
            Diagnostics.record(.cloudSignInRequest(endpoint: diagnosticEndpoint, outcome: outcome,
                durationMilliseconds: Int64(max(0, ProcessInfo.processInfo.systemUptime - started) * 1_000),
                httpStatus: status, reason: error == nil ? nil : reason,
                failure: error.map { DiagnosticFailure($0) }))
        }
        do {
            let (data, response) = try await boundedResponse(request, maximumBytes: 256 * 1_024)
            reason = .unexpectedResponse
            guard let http = response as? HTTPURLResponse, response.url == request.url else {
                throw SnippetsCloudEmailSignInFailure.invalidResponse
            }
            status = http.statusCode
            reason = .httpStatus
            guard http.statusCode == 200 else {
                let code = (try? JSONDecoder().decode(HTTPError.self, from: data))?.code
                switch code {
                case "invalid_email": reason = .invalidEmail; throw SnippetsCloudEmailSignInFailure.invalidEmail
                case "invalid_code": reason = .invalidCode; throw SnippetsCloudEmailSignInFailure.invalidCode
                case "code_expired": reason = .codeExpired; throw SnippetsCloudEmailSignInFailure.codeExpired
                case "too_many_attempts": reason = .tooManyAttempts; throw SnippetsCloudEmailSignInFailure.tooManyAttempts
                case "rate_limited":
                    let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                    reason = .rateLimited
                    throw SnippetsCloudEmailSignInFailure.rateLimited(delay.isFinite ? min(max(1, delay), 86_400) : 60)
                case "authentication_required": throw Failure.tokenExchangeFailed
                default: throw SnippetsCloudEmailSignInFailure.unavailable
                }
            }
            reason = .invalidJSON
            let responseValue = try JSONDecoder().decode(Response.self, from: data)
            record(.succeeded)
            return responseValue
        } catch {
            record(.failed, error: error)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error is SnippetsCloudEmailSignInFailure || error is Failure { throw error }
            throw SnippetsCloudEmailSignInFailure.unavailable
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
        failure: Failure,
        diagnosticEndpoint: DiagnosticCloudSignInEndpoint
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await responseJSON(request, maximumBytes: maximumBytes, failure: failure,
                                      diagnosticEndpoint: diagnosticEndpoint)
    }

    private func responseJSON<Response: Decodable>(
        _ request: URLRequest,
        maximumBytes: Int,
        failure: Failure,
        diagnosticEndpoint: DiagnosticCloudSignInEndpoint? = nil
    ) async throws -> Response {
        let started = ProcessInfo.processInfo.systemUptime
        var status: Int?
        var reason: DiagnosticCloudSignInReason = .requestFailed
        func record(_ outcome: DiagnosticCloudSignInRequestOutcome, error: (any Error)? = nil) {
            guard let diagnosticEndpoint else { return }
            Diagnostics.record(.cloudSignInRequest(
                endpoint: diagnosticEndpoint, outcome: outcome,
                durationMilliseconds: Int64(max(0, ProcessInfo.processInfo.systemUptime - started) * 1_000),
                httpStatus: status, reason: error == nil ? nil : reason,
                failure: error.map { DiagnosticFailure($0) }))
        }
        do {
            let (data, response) = try await boundedResponse(request, maximumBytes: maximumBytes)
            reason = .unexpectedResponse
            guard let http = response as? HTTPURLResponse else { throw failure }
            status = http.statusCode
            reason = .httpStatus
            guard http.statusCode == 200 else { throw failure }
            reason = .redirectRejected
            guard response.url == request.url else { throw failure }
            reason = .invalidJSON
            let result = try JSONDecoder().decode(Response.self, from: data)
            record(.succeeded)
            return result
        } catch {
            // Retain only the classified cause and numeric error before the UI's
            // intentionally broad error mapping discards the transport/decoder error.
            record(.failed, error: error)
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

/// Minimal display data from a verified ID token, bound to the resource token's
/// issuer and subject. Stored only with device-only credentials, never diagnostics.
nonisolated struct SnippetsCloudVerifiedProfile: Codable, Equatable, Sendable {
    let issuer: String
    let subject: String
    let name: String?
    let email: String?
    var displayName: String { name ?? email ?? "Snippets Cloud account" }

    struct Keys: Decodable {
        struct Key: Decodable {
            let kid: String?; let kty: String; let alg: String?; let use: String?
            let n: String?; let e: String?; let crv: String?; let x: String?; let y: String?
        }
        let keys: [Key]
    }
    enum Failure: Error { case invalidIdentity }

    static func verify(idToken: String, accessToken: String, keys: Keys, issuer: String,
                       clientID: String, resource: String, nonce: String, now: Date = Date()) throws -> Self {
        let identity = try claims(idToken, keys: keys, issuer: issuer, audience: clientID, now: now)
        let access = try claims(accessToken, keys: keys, issuer: issuer, audience: resource, now: now)
        guard identity["nonce"] as? String == nonce,
              let subject = identity["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 256,
              access["sub"] as? String == subject else { throw Failure.invalidIdentity }
        func display(_ key: String, limit: Int) -> String? {
            guard let value = identity[key] as? String, !value.isEmpty, value.utf8.count <= limit,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        return .init(issuer: issuer, subject: subject, name: display("name", limit: 256),
                     email: identity["email_verified"] as? Bool == true ? display("email", limit: 320) : nil)
    }

    private static func claims(_ token: String, keys: Keys, issuer: String, audience: String,
                               now: Date) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16_384, parts.count == 3, (1...16).contains(keys.keys.count),
              let header = try JSONSerialization.jsonObject(with: decode(String(parts[0]))) as? [String: Any],
              let alg = header["alg"] as? String, ["RS256", "ES256"].contains(alg),
              header["crit"] == nil, header["b64"] == nil,
              let kid = header["kid"] as? String else { throw Failure.invalidIdentity }
        let candidates = keys.keys.filter { $0.kid == kid && ($0.use == nil || $0.use == "sig") && ($0.alg == nil || $0.alg == alg) }
        guard candidates.count == 1 else { throw Failure.invalidIdentity }
        let key = candidates[0]
        let signature = try decode(String(parts[2]))
        let message = Data("\(parts[0]).\(parts[1])".utf8)
        if alg == "ES256" {
            guard key.kty == "EC", key.crv == "P-256", let x = key.x, let y = key.y else { throw Failure.invalidIdentity }
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + decode(x) + decode(y))
            guard try publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: message) else { throw Failure.invalidIdentity }
        } else {
            guard key.kty == "RSA", let n = key.n, let e = key.e else { throw Failure.invalidIdentity }
            let modulus = try decode(n), exponent = try decode(e)
            guard (256...512).contains(modulus.count), (1...4).contains(exponent.count) else { throw Failure.invalidIdentity }
            let encoded = der(0x30, integer(modulus) + integer(exponent))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            guard let publicKey = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else { throw Failure.invalidIdentity }
        }
        guard let value = try JSONSerialization.jsonObject(with: decode(String(parts[1]))) as? [String: Any],
              value["iss"] as? String == issuer, let expiry = value["exp"] as? Double,
              let issued = value["iat"] as? Double, expiry > now.timeIntervalSince1970,
              issued <= now.timeIntervalSince1970 + 60,
              (value["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60 else { throw Failure.invalidIdentity }
        let audiences = (value["aud"] as? [String]) ?? (value["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(audience), audiences.count == 1 || value["azp"] as? String == audience else { throw Failure.invalidIdentity }
        return value
    }
    private static func decode(_ value: String) throws -> Data {
        guard !value.contains("="), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)),
              data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value else { throw Failure.invalidIdentity }
        return data
    }
    private static func integer(_ value: Data) -> Data { der(2, (value.first! >= 128 ? Data([0]) : Data()) + value) }
    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        let length = value.count
        let encoded: [UInt8] = length < 128 ? [UInt8(length)] : length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)]
        return Data([tag] + encoded) + value
    }
}
