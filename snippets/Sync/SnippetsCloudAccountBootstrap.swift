import AuthenticationServices
import CryptoKit
import Foundation

enum SnippetsCloudPairingApprovalCopy {
    static func message(code: String, localAuthentication: String) -> String {
        "Confirmation code: \(code)\n\nConfirm that the same code is shown on the new device. \(localAuthentication) and a fresh passkey check are required before this device releases the encrypted library key."
    }

    static func approveButtonTitle(code: String) -> String { "Approve \(code)" }
}

/// Process-local disclosure authority for a durably pending recovery kit. A new
/// process always starts locked even though the encrypted presentation survives a
/// crash so the user cannot accidentally lose the only recovery capability.
struct SnippetsCloudRecoveryPresentationGate {
    private(set) var isAuthorized = false

    mutating func authorize() { isAuthorized = true }
    mutating func reset() { isAuthorized = false }

    /// Disclosure authority is deliberately single-use. The caller that receives
    /// the value owns that one presentation; another read requires new user presence.
    mutating func consumeAuthorization() -> Bool {
        defer { isAuthorized = false }
        return isAuthorized
    }
}

enum SnippetsCloudRecoveryVerification {
    static let suffixLength = 8

    static func normalized(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }.uppercased()
    }

    static func matches(longCode: String, enteredSuffix: String) -> Bool {
        let expected = String(normalized(longCode).suffix(suffixLength))
        return expected.count == suffixLength && normalized(enteredSuffix) == expected
    }
}

/// Coordinates passkey-first account sign-in with zero-knowledge key onboarding.
/// Secret intermediate state lives only in this device's Keychain, so an app restart
/// cannot turn a half-finished pairing or recovery replacement into a key-loss event.
@MainActor
final class SnippetsCloudAccountBootstrap {
    enum RecoveryKitStatus: Equatable {
        case verifiedCurrent
        case knownReplaced
        case statusUnconfirmed
        case neverVerified
        case replacementInProgress
    }

    enum StrongAction: String, Equatable {
        case createInitialRecovery
        case approveDevice
        case replaceRecovery
    }

    enum State: Equatable {
        case signedOut
        case ready
        case needsTrustedDeviceOrRecovery
        case waitingForApproval(
            qrPayload: String,
            confirmationCode: String,
            expiresAt: Date)
        case approvalReady(confirmationCode: String)
        case strongAuthenticationRequired(StrongAction)
        case recoveryKitAuthenticationRequired
        case recoveryKitReady(qrPayload: String, longCode: String)
    }

    enum Failure: Error, CustomStringConvertible, LocalizedError {
        case invalidState
        case invalidInvitation
        case pairingExpired
        case recoveryUnavailable
        case recoveryKitReplaced
        case recoveryStatusUnconfirmed
        case accountMismatch
        case service(String)

        var description: String {
            switch self {
            case .invalidState: "secure cloud setup is not in the expected state"
            case .invalidInvitation: "this device invitation is invalid"
            case .pairingExpired: "this device invitation expired"
            case .recoveryUnavailable: "this library has no usable recovery envelope"
            case .recoveryKitReplaced: "the previously verified recovery kit was replaced"
            case .recoveryStatusUnconfirmed: "the current recovery envelope could not be confirmed"
            case .accountMismatch: "this code belongs to a different Snippets Cloud library"
            case .service(let code): code
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidState:
                "Snippets Cloud setup could not continue from its saved step. Your local snippets are safe; open Snippets Cloud and try again."
            case .invalidInvitation:
                "This device invitation could not be verified. Nothing changed; create a new invitation and compare the confirmation code on both devices."
            case .pairingExpired:
                "This device invitation expired. Nothing changed; create a new invitation to continue."
            case .recoveryUnavailable:
                "This library has no usable recovery kit. Use a device that already opens the library."
            case .recoveryKitReplaced:
                "Your previously saved recovery kit was replaced and can no longer unlock this library. Verify the current kit before disconnecting this device."
            case .recoveryStatusUnconfirmed:
                "Snippets Cloud could not confirm the current recovery envelope. This device was not disconnected; try again when the service is reachable."
            case .accountMismatch:
                "This code belongs to a different Snippets Cloud account or library. Your existing data is unchanged."
            case .service(let code):
                Self.userFacingServiceFailure(code)
            }
        }

        private static func userFacingServiceFailure(_ code: String) -> String {
            switch code {
            case "sign_in_required", "authentication_required", "refresh_token_missing":
                "Sign-in needs to be completed again. Your local snippets are safe; continue sign-in from Snippets Cloud settings."
            case "reauthentication_required":
                "Confirm this security-sensitive change with a fresh passkey sign-in."
            case "library_key_required":
                "This account is connected, but the library is still locked. Use an approved device or your recovery kit."
            case "pairing_expired", "pairing_missing":
                "The device invitation is no longer available. Create a new invitation and approve it within five minutes."
            case "space_selection_required":
                "This account has more than one library. Choose one in the library selector shown during sign-in."
            case "scope_review_required":
                "The connected account or library changed. Review the account before sync resumes; your local snippets are safe."
            case "server_auth_insecure":
                "The server does not meet Snippets Cloud’s secure sign-in requirements. No data was sent."
            default:
                "Snippets Cloud could not complete the request. Your local snippets are unchanged; try again."
            }
        }
    }

    private struct PendingRecovery: Codable {
        let schemaVersion: Int
        let kitPayload: String
        let ciphertext: Data
        let expectedVersion: Int?
        let newLibraryMaterial: Data?
    }

    struct RecoveryVerificationRecord: Codable, Equatable {
        let serverURL: URL
        let serverInstanceID: UUID
        let protocolMajor: Int
        let spaceID: UUID
        let scopeBinding: String
        let keyEpoch: Int
        let envelopeVersion: Int
        let envelopeCiphertextFingerprint: String
        let kitFingerprint: String

        func matches(
            coordinates: SyncBackendSelectionStore.CloudCoordinates,
            remote: SnippetsCloudBootstrapClient.RecoveryState
        ) -> Bool {
            guard let envelope = remote.recovery else { return false }
            return serverURL == coordinates.serverURL
                && serverInstanceID == coordinates.serverInstanceID
                && protocolMajor == coordinates.protocolMajor
                && spaceID == coordinates.spaceID
                && serverInstanceID == remote.scope.serverInstanceID
                && spaceID == remote.scope.spaceID
                && scopeBinding == remote.scope.scopeBinding
                && keyEpoch == remote.keyEpoch
                && keyEpoch == envelope.keyEpoch
                && envelopeVersion == envelope.version
                && envelopeCiphertextFingerprint == Self.fingerprint(envelope.ciphertext)
        }

        static func fingerprint(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct StoredRecoveryVerification: Codable {
        enum Status: String, Codable {
            case verifiedCurrent
            case knownReplaced
            case statusUnconfirmed
            case neverVerified
            case replacementInProgress
        }

        let schemaVersion: Int
        let status: Status
        let record: RecoveryVerificationRecord?
    }

    static let pairingAccount = "pairing-recipient-v2"
    static let approvalAccount = "pairing-approval-v2"
    static let pendingRecoveryAccount = "recovery-upload-v1"
    static let recoveryPresentationAccount = "recovery-display-v1"
    static let recoveryVerifiedAccount = "recovery-verified-v1"
    static let bootstrapService = "com.khm.snippets.cloud-bootstrap"
    static let bootstrapSecretAccounts = [
        pairingAccount,
        approvalAccount,
        pendingRecoveryAccount,
        recoveryPresentationAccount,
        recoveryVerifiedAccount,
    ]

    let selection: SyncBackendSelectionStore
    private let secrets: KeychainSecretStore
    private var recoveryPresentationGate = SnippetsCloudRecoveryPresentationGate()
    private var processConfirmedRecovery: RecoveryVerificationRecord?

    init(
        selection: SyncBackendSelectionStore? = nil,
        secrets: KeychainSecretStore? = nil
    ) {
        self.selection = selection ?? SyncBackendSelectionStore()
        self.secrets = secrets ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: Self.bootstrapService,
            itemAccessibility: .afterFirstUnlock)
    }

    var libraryID: String? {
        guard selection.hasCloudSession, let coordinates = selection.cloudCoordinates else {
            return nil
        }
        let source = "\(coordinates.serverInstanceID?.uuidString.lowercased() ?? ""):\(coordinates.spaceID.uuidString.lowercased())"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined()
    }

    var recoveryKitStatus: RecoveryKitStatus {
        if (try? secrets.loadItem(account: Self.recoveryPresentationAccount)) != nil
            || (try? secrets.loadItem(account: Self.pendingRecoveryAccount)) != nil {
            return .replacementInProgress
        }
        let stored: StoredRecoveryVerification?
        do {
            stored = try storedRecoveryVerification()
        } catch {
            return .statusUnconfirmed
        }
        guard let stored else { return .neverVerified }
        switch stored.status {
        case .verifiedCurrent:
            return stored.record == processConfirmedRecovery
                ? .verifiedCurrent : .statusUnconfirmed
        case .knownReplaced: return .knownReplaced
        case .statusUnconfirmed: return .statusUnconfirmed
        case .neverVerified: return .neverVerified
        case .replacementInProgress: return .replacementInProgress
        }
    }

    func state() throws -> State {
        guard selection.hasCloudSession, let coordinates = selection.cloudCoordinates else {
            return .signedOut
        }
        if let raw = try secrets.loadItem(account: Self.recoveryPresentationAccount) {
            guard let payload = String(data: raw, encoding: .utf8),
                  let kit = try? LibraryKeyBootstrap.RecoveryKit(qrPayload: payload),
                  kit.serverURL == coordinates.serverURL,
                  kit.spaceID == coordinates.spaceID else {
                recoveryPresentationGate.reset()
                try secrets.deleteItem(account: Self.recoveryPresentationAccount)
                throw Failure.invalidState
            }
            guard recoveryPresentationGate.consumeAuthorization() else {
                return .recoveryKitAuthenticationRequired
            }
            return .recoveryKitReady(qrPayload: payload, longCode: kit.longCode)
        }
        if let pending = try pendingRecovery() {
            return .strongAuthenticationRequired(
                pending.newLibraryMaterial == nil ? .replaceRecovery : .createInitialRecovery)
        }
        if let raw = try secrets.loadItem(account: Self.approvalAccount),
           let payload = String(data: raw, encoding: .utf8),
           let invitation = try? LibraryKeyBootstrap.PairingInvitation(qrPayload: payload),
           invitation.serverURL == coordinates.serverURL,
           invitation.spaceID == coordinates.spaceID {
            return .approvalReady(confirmationCode: invitation.confirmationCode)
        }
        if let raw = try secrets.loadItem(account: Self.pairingAccount),
           let pending = try? LibraryKeyBootstrap.PendingPairing(jsonData: raw),
           let invitation = try? pending.invitation,
           invitation.serverURL == coordinates.serverURL,
           invitation.spaceID == coordinates.spaceID {
            return .waitingForApproval(
                qrPayload: try invitation.qrPayload(),
                confirmationCode: invitation.confirmationCode,
                expiresAt: Date(timeIntervalSince1970:
                    TimeInterval(invitation.expiresAtEpochSeconds)))
        }
        if try installedMaterial(for: coordinates) != nil {
            return .ready
        }
        return .needsTrustedDeviceOrRecovery
    }

    /// The UI calls this only after a zero-reuse device-owner authentication. The
    /// authority is consumed by this call, so every later presentation (including in
    /// the same process) requires fresh local user presence.
    func revealRecoveryKitAfterLocalAuthentication() throws -> State {
        guard try secrets.loadItem(account: Self.recoveryPresentationAccount) != nil else {
            throw Failure.invalidState
        }
        recoveryPresentationGate.authorize()
        do {
            let result = try state()
            guard case .recoveryKitReady = result else {
                recoveryPresentationGate.reset()
                throw Failure.invalidState
            }
            return result
        } catch {
            recoveryPresentationGate.reset()
            throw error
        }
    }

    @discardableResult
    func signIn(
        serverURL: URL,
        strong: Bool = false,
        changeAccount: Bool = false,
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID,
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> State {
        let previousCoordinates = selection.cloudCoordinates
        try await selection.signIn(
            serverURL: serverURL,
            requiresStrongAuthentication: strong,
            chooseAccount: changeAccount,
            chooseLibrary: chooseLibrary,
            presentationContext: presentationContext)
        if let previousCoordinates,
           let currentCoordinates = selection.cloudCoordinates,
           currentCoordinates != previousCoordinates {
            // Pending approvals and recovery replacements were prepared for the old
            // deployment/account. Never replay them merely because OAuth succeeded at
            // the same URL; ordinary sync now owns the explicit account review.
            try discardBootstrapIntentAfterScopeChange()
        }
        if try await syncCheckpointRequiresReviewBeforeBootstrap() {
            try discardBootstrapIntentAfterScopeChange()
        }
        return try await finishPostAuthorization()
    }

    @discardableResult
    func changeLibrary(
        chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID
    ) async throws -> State {
        guard let previousCoordinates = selection.cloudCoordinates else {
            throw Failure.invalidState
        }
        try await selection.changeSnippetsCloudLibrary(chooseLibrary: chooseLibrary)
        guard let currentCoordinates = selection.cloudCoordinates else {
            throw Failure.invalidState
        }
        if currentCoordinates != previousCoordinates {
            try discardBootstrapIntentAfterScopeChange()
        }
        if try await syncCheckpointRequiresReviewBeforeBootstrap() {
            try discardBootstrapIntentAfterScopeChange()
        }
        return try await finishPostAuthorization()
    }

    @discardableResult
    func beginPairing() async throws -> State {
        let (coordinates, client) = try client()
        guard try installedMaterial(for: coordinates) == nil else {
            throw Failure.invalidState
        }
        let draft = LibraryKeyBootstrap.PairingDraft()
        let pairing = try await mapService { try await client.createPairing(draft) }
        guard pairing.state == "pending" else { throw Failure.invalidInvitation }
        let invitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            pairingID: pairing.pairingID,
            nonce: pairing.nonce,
            recipientPublicKey: pairing.recipientPublicKey,
            expiresAtEpochSeconds: Int64(pairing.expiresAt.timeIntervalSince1970))
        guard pairing.authenticationTag == invitation.confirmationCode else {
            throw Failure.invalidInvitation
        }
        let pending = try LibraryKeyBootstrap.PendingPairing(draft: draft, invitation: invitation)
        try secrets.storeItem(try pending.jsonData, account: Self.pairingAccount)
        return .waitingForApproval(
            qrPayload: try invitation.qrPayload(),
            confirmationCode: invitation.confirmationCode,
            expiresAt: pairing.expiresAt)
    }

    @discardableResult
    func checkPairing() async throws -> State {
        guard let raw = try secrets.loadItem(account: Self.pairingAccount) else {
            throw Failure.invalidState
        }
        let pending = try LibraryKeyBootstrap.PendingPairing(jsonData: raw)
        let invitation = try pending.invitation
        let (coordinates, client) = try client()
        guard invitation.serverURL == coordinates.serverURL,
              invitation.spaceID == coordinates.spaceID else { throw Failure.accountMismatch }
        let status = try await mapService {
            try await client.pairing(
                invitation.pairingID,
                publicKey: invitation.recipientPublicKey,
                nonce: invitation.nonce)
        }
        guard status.pairingID == invitation.pairingID,
              status.authenticationTag == invitation.confirmationCode else {
            throw Failure.invalidInvitation
        }
        guard status.state == "approved" else {
            return .waitingForApproval(
                qrPayload: try invitation.qrPayload(),
                confirmationCode: invitation.confirmationCode,
                expiresAt: status.expiresAt)
        }
        let taken = try await mapService {
            try await client.takeApprovedPairing(
                invitation.pairingID,
                publicKey: invitation.recipientPublicKey,
                nonce: invitation.nonce,
                expected: status)
        }
        guard taken.pairingID == invitation.pairingID,
              taken.authenticationTag == invitation.confirmationCode,
              let ciphertext = taken.ciphertext else { throw Failure.invalidInvitation }
        let bundle = try LibraryKeyBootstrap.open(ciphertext, pending: pending)
        try install(bundle, coordinates: coordinates)
        try secrets.deleteItem(account: Self.pairingAccount)
        return .ready
    }

    func cancelPairing() async throws {
        guard let raw = try secrets.loadItem(account: Self.pairingAccount),
              let pending = try? LibraryKeyBootstrap.PendingPairing(jsonData: raw),
              let invitation = try? pending.invitation else {
            try secrets.deleteItem(account: Self.pairingAccount)
            return
        }
        if let (_, client) = try? client() {
            try? await client.cancelPairing(invitation.pairingID)
        }
        try secrets.deleteItem(account: Self.pairingAccount)
    }

    /// Checks the invitation against authenticated server state before the UI asks
    /// the user to compare the short code and approve with Face ID / Touch ID.
    @discardableResult
    func prepareApproval(qrPayload: String) async throws -> State {
        let invitation = try LibraryKeyBootstrap.PairingInvitation(qrPayload: qrPayload)
        let (coordinates, client) = try client()
        guard invitation.serverURL == coordinates.serverURL,
              invitation.spaceID == coordinates.spaceID,
              try installedMaterial(for: coordinates) != nil else {
            throw Failure.accountMismatch
        }
        let pairing = try await mapService {
            try await client.pairing(
                invitation.pairingID,
                publicKey: invitation.recipientPublicKey,
                nonce: invitation.nonce)
        }
        guard pairing.pairingID == invitation.pairingID,
              pairing.state == "pending",
              pairing.authenticationTag == invitation.confirmationCode,
              Int64(pairing.expiresAt.timeIntervalSince1970) == invitation.expiresAtEpochSeconds else {
            throw Failure.invalidInvitation
        }
        try secrets.storeItem(Data(qrPayload.utf8), account: Self.approvalAccount)
        return .approvalReady(confirmationCode: invitation.confirmationCode)
    }

    func cancelApproval() throws {
        try secrets.deleteItem(account: Self.approvalAccount)
    }

    @discardableResult
    func restore(recoveryCodeOrQR value: String) async throws -> State {
        let (coordinates, client) = try client()
        let remote = try await mapService { try await client.recoveryState() }
        guard let envelope = remote.recovery else { throw Failure.recoveryUnavailable }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let kit: LibraryKeyBootstrap.RecoveryKit
        if trimmed.hasPrefix("{") {
            kit = try .init(qrPayload: trimmed)
        } else {
            kit = try .init(
                longCode: trimmed,
                serverURL: coordinates.serverURL,
                spaceID: coordinates.spaceID,
                keyEpoch: envelope.keyEpoch)
        }
        guard kit.serverURL == coordinates.serverURL,
              kit.spaceID == coordinates.spaceID,
              kit.keyEpoch == remote.keyEpoch,
              kit.keyEpoch == envelope.keyEpoch else { throw Failure.accountMismatch }
        let bundle = try LibraryKeyBootstrap.openRecoveryEnvelope(envelope.ciphertext, kit: kit)
        try install(bundle, coordinates: coordinates)
        return .ready
    }

    /// Prepares a replacement envelope but does not upload it. The caller must first
    /// obtain local user presence, then call `signIn(strong: true, ...)`.
    @discardableResult
    func prepareRecoveryReplacement() async throws -> State {
        let (coordinates, client) = try client()
        guard let material = try installedMaterial(for: coordinates) else {
            throw Failure.invalidState
        }
        let remote = try await mapService { try await client.recoveryState() }
        let recovery = try LibraryKeyBootstrap.createRecoveryEnvelope(
            for: LibraryKeyBootstrap.PortableKeyBundle(material: material),
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            keyEpoch: remote.keyEpoch)
        try storePendingRecovery(.init(
            schemaVersion: 1,
            kitPayload: recovery.kit.qrPayload(),
            ciphertext: recovery.ciphertext,
            expectedVersion: remote.recovery?.version,
            newLibraryMaterial: nil))
        try storeRecoveryVerification(.init(
            schemaVersion: 2,
            status: .replacementInProgress,
            record: nil))
        processConfirmedRecovery = nil
        return .strongAuthenticationRequired(.replaceRecovery)
    }

    func acknowledgeRecoveryKitSaved() async throws {
        recoveryPresentationGate.reset()
        // If the app was interrupted between persisting the presentation and removing
        // the upload journal, finish durable provider activation before consuming the
        // journal or presentation. Every crash point remains idempotently resumable.
        if try pendingRecovery() != nil {
            guard case .ready = try stateIgnoringRecoveryPresentation() else {
                throw Failure.invalidState
            }
        }
        guard let payloadData = try secrets.loadItem(
            account: Self.recoveryPresentationAccount),
              let payload = String(data: payloadData, encoding: .utf8) else {
            throw Failure.invalidState
        }
        let kit = try LibraryKeyBootstrap.RecoveryKit(qrPayload: payload)
        let (coordinates, client) = try client()
        guard kit.serverURL == coordinates.serverURL,
              kit.spaceID == coordinates.spaceID,
              let installed = try installedMaterial(for: coordinates) else {
            throw Failure.accountMismatch
        }
        let remote = try await mapService { try await client.recoveryState() }
        guard let envelope = remote.recovery,
              remote.keyEpoch == kit.keyEpoch,
              envelope.keyEpoch == kit.keyEpoch else {
            throw Failure.recoveryKitReplaced
        }
        let opened = try LibraryKeyBootstrap.openRecoveryEnvelope(
            envelope.ciphertext,
            kit: kit)
        guard opened.material == installed else { throw Failure.recoveryKitReplaced }
        let record = RecoveryVerificationRecord(
            serverURL: coordinates.serverURL,
            serverInstanceID: try requiredServerInstanceID(in: coordinates),
            protocolMajor: try requiredProtocolMajor(in: coordinates),
            spaceID: coordinates.spaceID,
            scopeBinding: remote.scope.scopeBinding,
            keyEpoch: remote.keyEpoch,
            envelopeVersion: envelope.version,
            envelopeCiphertextFingerprint: RecoveryVerificationRecord.fingerprint(
                envelope.ciphertext),
            kitFingerprint: RecoveryVerificationRecord.fingerprint(payloadData))
        try storeRecoveryVerification(.init(
            schemaVersion: 2,
            status: .verifiedCurrent,
            record: record))
        processConfirmedRecovery = record
        try secrets.deleteItem(account: Self.pendingRecoveryAccount)
        try secrets.deleteItem(account: Self.recoveryPresentationAccount)
    }

    @discardableResult
    func refreshRecoveryKitStatus() async throws -> RecoveryKitStatus {
        if (try? secrets.loadItem(account: Self.recoveryPresentationAccount)) != nil
            || (try? secrets.loadItem(account: Self.pendingRecoveryAccount)) != nil {
            processConfirmedRecovery = nil
            return .replacementInProgress
        }
        guard let stored = try storedRecoveryVerification() else {
            processConfirmedRecovery = nil
            return .neverVerified
        }
        guard let record = stored.record else {
            processConfirmedRecovery = nil
            return stored.status == .replacementInProgress
                ? .replacementInProgress : .statusUnconfirmed
        }
        let (coordinates, client) = try client()
        guard record.serverURL == coordinates.serverURL,
              record.serverInstanceID == coordinates.serverInstanceID,
              record.protocolMajor == coordinates.protocolMajor,
              record.spaceID == coordinates.spaceID else {
            processConfirmedRecovery = nil
            try secrets.deleteItem(account: Self.recoveryVerifiedAccount)
            return .neverVerified
        }
        do {
            let remote = try await mapService { try await client.recoveryState() }
            if record.matches(coordinates: coordinates, remote: remote) {
                try storeRecoveryVerification(.init(
                    schemaVersion: 2,
                    status: .verifiedCurrent,
                    record: record))
                processConfirmedRecovery = record
                return .verifiedCurrent
            }
            try storeRecoveryVerification(.init(
                schemaVersion: 2,
                status: .knownReplaced,
                record: record))
            processConfirmedRecovery = nil
            return .knownReplaced
        } catch {
            try? storeRecoveryVerification(.init(
                schemaVersion: 2,
                status: .statusUnconfirmed,
                record: record))
            processConfirmedRecovery = nil
            throw error
        }
    }

    func signOutThisDevice() async throws {
        if try selection.pendingLocalEraseExists() {
            try selection.resumePendingLocalErase(bootstrapSecrets: secrets)
            return
        }
        let recoveryStatus: RecoveryKitStatus
        do {
            recoveryStatus = try await refreshRecoveryKitStatus()
        } catch {
            throw Failure.recoveryStatusUnconfirmed
        }
        switch recoveryStatus {
        case .verifiedCurrent, .neverVerified:
            break
        case .knownReplaced:
            throw Failure.recoveryKitReplaced
        case .statusUnconfirmed:
            throw Failure.recoveryStatusUnconfirmed
        case .replacementInProgress:
            throw Failure.invalidState
        }
        // Do not destroy retry state until both the resource server and identity
        // provider confirm revocation. The selection layer then journals local erase,
        // removes the root first, and removes credentials/coordinates last.
        try await selection.revokeSnippetsCloudSession()
        try selection.forgetSnippetsCloudLocally(bootstrapSecrets: secrets)
    }

    func resetUnreadableCredentialsOnThisDevice() throws {
        try selection.resetUnreadableCloudCredentialsLocally(
            bootstrapSecrets: secrets)
    }

    private func finishPostAuthorization() async throws -> State {
        let (coordinates, client) = try client()
        if let raw = try secrets.loadItem(account: Self.approvalAccount),
           let payload = String(data: raw, encoding: .utf8) {
            let invitation = try LibraryKeyBootstrap.PairingInvitation(qrPayload: payload)
            guard invitation.serverURL == coordinates.serverURL,
                  invitation.spaceID == coordinates.spaceID,
                  let material = try installedMaterial(for: coordinates) else {
                throw Failure.accountMismatch
            }
            let serverPairing = try await mapService {
                try await client.pairing(
                    invitation.pairingID,
                    publicKey: invitation.recipientPublicKey,
                    nonce: invitation.nonce)
            }
            guard serverPairing.pairingID == invitation.pairingID,
                  serverPairing.authenticationTag == invitation.confirmationCode else {
                throw Failure.invalidInvitation
            }
            if serverPairing.state == "approved" {
                // The prior approval may have committed while its response was lost.
                // Poll responses are redacted; the recipient still owns the only
                // operation that can atomically take the stored envelope.
                try secrets.deleteItem(account: Self.approvalAccount)
                return .ready
            }
            guard serverPairing.state == "pending" else { throw Failure.invalidInvitation }
            let ciphertext = try LibraryKeyBootstrap.seal(
                LibraryKeyBootstrap.PortableKeyBundle(material: material),
                for: invitation)
            let approved = try await mapService {
                try await client.approvePairing(
                    invitation.pairingID,
                    publicKey: invitation.recipientPublicKey,
                    nonce: invitation.nonce,
                    ciphertext: ciphertext)
            }
            guard approved.pairingID == invitation.pairingID,
                  approved.state == "approved" else { throw Failure.invalidInvitation }
            try secrets.deleteItem(account: Self.approvalAccount)
            return .ready
        }

        if let pending = try pendingRecovery() {
            return try await uploadPendingRecovery(pending, coordinates: coordinates, client: client)
        }

        if try installedMaterial(for: coordinates) != nil {
            return .ready
        }

        let remote = try await mapService { try await client.recoveryState() }
        async let containsRecords = mapService { try await client.hasRemoteRecords() }
        let hasRemoteRecords = try await containsRecords
        if remote.recovery != nil || hasRemoteRecords {
            return .needsTrustedDeviceOrRecovery
        }

        var material = Data(capacity: 64)
        material.append(SnippetCrypto.randomBytes(32))
        material.append(SnippetCrypto.randomBytes(32))
        let recovery = try LibraryKeyBootstrap.createRecoveryEnvelope(
            for: LibraryKeyBootstrap.PortableKeyBundle(material: material),
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            keyEpoch: remote.keyEpoch)
        let pending = PendingRecovery(
            schemaVersion: 1,
            kitPayload: try recovery.kit.qrPayload(),
            ciphertext: recovery.ciphertext,
            expectedVersion: nil,
            newLibraryMaterial: material)
        try storePendingRecovery(pending)
        do {
            return try await uploadPendingRecovery(pending, coordinates: coordinates, client: client)
        } catch Failure.service(let code) where code == "reauthentication_required" {
            return .strongAuthenticationRequired(.createInitialRecovery)
        } catch Failure.service(let code) where code == "conflict" {
            try secrets.deleteItem(account: Self.pendingRecoveryAccount)
            return .needsTrustedDeviceOrRecovery
        }
    }

    private func uploadPendingRecovery(
        _ pending: PendingRecovery,
        coordinates: SyncBackendSelectionStore.CloudCoordinates,
        client: SnippetsCloudBootstrapClient
    ) async throws -> State {
        let kit = try LibraryKeyBootstrap.RecoveryKit(qrPayload: pending.kitPayload)
        guard kit.serverURL == coordinates.serverURL,
              kit.spaceID == coordinates.spaceID else { throw Failure.accountMismatch }
        do {
            _ = try await mapService {
                try await client.putRecoveryEnvelope(
                    keyEpoch: kit.keyEpoch,
                    expectedVersion: pending.expectedVersion,
                    ciphertext: pending.ciphertext)
            }
        } catch Failure.service(let code) where code == "conflict" {
            // The PUT may have committed while its response was lost. Only an exact
            // opaque-envelope match is safe to treat as that interrupted success.
            let current = try await mapService { try await client.recoveryState() }
            guard current.keyEpoch == kit.keyEpoch,
                  current.recovery?.algorithm == LibraryKeyBootstrap.recoveryAlgorithm,
                  current.recovery?.ciphertext == pending.ciphertext else {
                throw Failure.service(code)
            }
        }
        if let material = pending.newLibraryMaterial {
            try selection.cloudKeys.install(
                material,
                serverURL: coordinates.serverURL,
                spaceID: coordinates.spaceID,
                serverInstanceID: try requiredServerInstanceID(in: coordinates),
                protocolMajor: try requiredProtocolMajor(in: coordinates))
        }
        try secrets.storeItem(
            Data(pending.kitPayload.utf8),
            account: Self.recoveryPresentationAccount)
        // Last write: until key installation and presentation are durable this journal
        // makes restart/ack retry the exact committed envelope instead of losing it.
        try secrets.deleteItem(account: Self.pendingRecoveryAccount)
        return .recoveryKitReady(
            qrPayload: pending.kitPayload,
            longCode: kit.longCode)
    }

    private func install(
        _ bundle: LibraryKeyBootstrap.PortableKeyBundle,
        coordinates: SyncBackendSelectionStore.CloudCoordinates
    ) throws {
        try selection.cloudKeys.install(
            bundle.material,
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            serverInstanceID: try requiredServerInstanceID(in: coordinates),
            protocolMajor: try requiredProtocolMajor(in: coordinates))
    }

    private func installedMaterial(
        for coordinates: SyncBackendSelectionStore.CloudCoordinates
    ) throws -> Data? {
        try selection.cloudKeys.material(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            serverInstanceID: try requiredServerInstanceID(in: coordinates),
            protocolMajor: try requiredProtocolMajor(in: coordinates))
    }

    private func requiredServerInstanceID(
        in coordinates: SyncBackendSelectionStore.CloudCoordinates
    ) throws -> UUID {
        guard let value = coordinates.serverInstanceID else { throw Failure.invalidState }
        return value
    }

    private func requiredProtocolMajor(
        in coordinates: SyncBackendSelectionStore.CloudCoordinates
    ) throws -> Int {
        guard coordinates.protocolMajor == 2 else { throw Failure.invalidState }
        return 2
    }

    private func client() throws -> (
        SyncBackendSelectionStore.CloudCoordinates,
        SnippetsCloudBootstrapClient
    ) {
        guard let coordinates = selection.cloudCoordinates,
              coordinates.apiBaseURL == coordinates.serverURL.appending(path: "v2"),
              let serverInstanceID = coordinates.serverInstanceID,
              let protocolMajor = coordinates.protocolMajor,
              selection.hasCloudSession else { throw Failure.invalidState }
        let client = try SnippetsCloudBootstrapClient(
            baseURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
            serverInstanceID: serverInstanceID,
            protocolMajor: protocolMajor,
            accessToken: { [selection] in
                try await selection.freshCloudAccessToken()
            })
        return (coordinates, client)
    }

    private func pendingRecovery() throws -> PendingRecovery? {
        guard let data = try secrets.loadItem(account: Self.pendingRecoveryAccount) else {
            return nil
        }
        guard data.count <= 16 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                "schemaVersion", "kitPayload", "ciphertext", "expectedVersion",
                "newLibraryMaterial",
              ],
              let value = try? JSONDecoder().decode(PendingRecovery.self, from: data),
              value.schemaVersion == 1,
              value.ciphertext.count <= 4_096,
              value.newLibraryMaterial == nil || value.newLibraryMaterial?.count == 64,
              (try? LibraryKeyBootstrap.RecoveryKit(qrPayload: value.kitPayload)) != nil else {
            try? secrets.deleteItem(account: Self.pendingRecoveryAccount)
            throw Failure.invalidState
        }
        return value
    }

    private func storedRecoveryVerification() throws -> StoredRecoveryVerification? {
        guard let data = try secrets.loadItem(account: Self.recoveryVerifiedAccount) else {
            return nil
        }
        // The pre-versioned literal cannot prove anything about the current server
        // envelope. Preserve only the fact that a check once happened and require the
        // user to verify a current kit before a positive status can be restored.
        if data == Data("verified".utf8) {
            return StoredRecoveryVerification(
                schemaVersion: 2,
                status: .statusUnconfirmed,
                record: nil)
        }
        guard data.count <= 16 * 1_024,
              let stored = try? JSONDecoder().decode(
                StoredRecoveryVerification.self,
                from: data),
              stored.schemaVersion == 2 else {
            throw Failure.invalidState
        }
        switch stored.status {
        case .verifiedCurrent, .knownReplaced:
            guard stored.record != nil else { throw Failure.invalidState }
        case .statusUnconfirmed:
            break
        case .neverVerified, .replacementInProgress:
            guard stored.record == nil else { throw Failure.invalidState }
        }
        if let record = stored.record {
            guard record.serverURL.scheme == "https",
                  record.serverURL.user == nil,
                  record.serverURL.password == nil,
                  record.serverURL.query == nil,
                  record.serverURL.fragment == nil,
                  !record.serverURL.absoluteString.hasSuffix("/"),
                  record.protocolMajor == 2,
                  (32...256).contains(record.scopeBinding.utf8.count),
                  record.keyEpoch > 0,
                  record.envelopeVersion > 0,
                  record.envelopeCiphertextFingerprint.wholeMatch(
                    of: /^[0-9a-f]{64}$/) != nil,
                  record.kitFingerprint.wholeMatch(of: /^[0-9a-f]{64}$/) != nil else {
                throw Failure.invalidState
            }
        }
        return stored
    }

    private func storeRecoveryVerification(
        _ stored: StoredRecoveryVerification
    ) throws {
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 16 * 1_024 else { throw Failure.invalidState }
        try secrets.storeItem(data, account: Self.recoveryVerifiedAccount)
    }

    private func stateIgnoringRecoveryPresentation() throws -> State {
        guard selection.hasCloudSession, let coordinates = selection.cloudCoordinates,
              try installedMaterial(for: coordinates) != nil else {
            return .needsTrustedDeviceOrRecovery
        }
        return .ready
    }

    private func discardBootstrapIntentAfterScopeChange() throws {
        recoveryPresentationGate.reset()
        processConfirmedRecovery = nil
        for account in Self.bootstrapSecretAccounts {
            try secrets.deleteItem(account: account)
        }
    }

    /// Detects whether previously prepared bootstrap authority belongs to a different
    /// or unreadable protocol state. The caller discards those one-shot intents, then
    /// continues clean onboarding: an empty new cloud may safely get a new encrypted
    /// root, while existing remote data still requires pairing or recovery. Record sync
    /// independently retains its explicit account/dataset review before uploading data.
    private func syncCheckpointRequiresReviewBeforeBootstrap() async throws -> Bool {
        let locations = try selection.protocolLocations(for: .snippetsCloud)
        let journalOutcome = SyncJournalFile.load(from: locations.journalURL)
        let stateFileExists = FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncStateFileURL.path)
        switch SyncStateFile.load() {
        case .tooNew:
            return true
        case .fresh where stateFileExists:
            return true
        case .loaded(let state) where state.halt != nil:
            return true
        case .loaded, .fresh:
            break
        }

        let base: SyncBase
        switch SyncBaseFile.load(from: locations.baseURL) {
        case .missing:
            if case .missing = journalOutcome { return false }
            return true
        case .loaded(let loaded):
            base = loaded
        case .tooNew, .unreadable:
            return true
        }
        switch journalOutcome {
        case .tooNew, .unreadable:
            return true
        case .missing where base.journalEstablished:
            return true
        case .missing, .loaded:
            break
        }
        let meaningful = !base.envelopes.isEmpty
            || !base.recordVersions.isEmpty
            || base.cursor != nil
            || base.journalEstablished
            || base.accountIdentity != nil
            || base.datasetIdentity != nil
        guard meaningful else { return false }

        let (coordinates, client) = try client()
        guard let serverInstanceID = coordinates.serverInstanceID,
              let protocolMajor = coordinates.protocolMajor else { return true }
        let remote = try await mapService { try await client.recoveryState() }
        let account = SnippetsCloudTransport.accountIdentity(
            baseURL: coordinates.serverURL,
            protocolMajor: protocolMajor,
            serverInstanceID: serverInstanceID,
            spaceID: coordinates.spaceID,
            scopeBinding: remote.scope.scopeBinding)
        let dataset = SnippetsCloudTransport.datasetIdentity(
            baseURL: coordinates.serverURL,
            protocolMajor: protocolMajor,
            serverInstanceID: serverInstanceID,
            spaceID: coordinates.spaceID,
            scopeBinding: remote.scope.scopeBinding,
            datasetGeneration: remote.scope.datasetGeneration)
        return base.accountIdentity != account || base.datasetIdentity != dataset
    }

    private func storePendingRecovery(_ value: PendingRecovery) throws {
        try secrets.storeItem(
            try JSONEncoder().encode(value),
            account: Self.pendingRecoveryAccount)
    }

    private func mapService<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do { return try await operation() }
        catch let failure as SnippetsCloudBootstrapClient.Failure {
            if case .service(let code) = failure { throw Failure.service(code) }
            throw failure
        }
    }
}
