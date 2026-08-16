import AuthenticationServices
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

/// Coordinates passkey-first account sign-in with zero-knowledge key onboarding.
/// Secret intermediate state lives only in this device's Keychain, so an app restart
/// cannot turn a half-finished pairing or recovery replacement into a key-loss event.
@MainActor
final class SnippetsCloudAccountBootstrap {
    enum StrongAction: String, Equatable {
        case createInitialRecovery
        case approveDevice
        case replaceRecovery
    }

    enum State: Equatable {
        case signedOut
        case ready
        case needsTrustedDeviceOrRecovery
        case waitingForApproval(qrPayload: String, confirmationCode: String)
        case approvalReady(confirmationCode: String)
        case strongAuthenticationRequired(StrongAction)
        case recoveryKitAuthenticationRequired
        case recoveryKitReady(qrPayload: String, longCode: String)
    }

    enum Failure: Error, CustomStringConvertible {
        case invalidState
        case invalidInvitation
        case pairingExpired
        case recoveryUnavailable
        case accountMismatch
        case service(String)

        var description: String {
            switch self {
            case .invalidState: "secure cloud setup is not in the expected state"
            case .invalidInvitation: "this device invitation is invalid"
            case .pairingExpired: "this device invitation expired"
            case .recoveryUnavailable: "this library has no usable recovery envelope"
            case .accountMismatch: "this code belongs to a different Snippets Cloud library"
            case .service(let code): code
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

    static let pairingAccount = "pairing-recipient-v2"
    static let approvalAccount = "pairing-approval-v2"
    static let pendingRecoveryAccount = "recovery-upload-v1"
    static let recoveryPresentationAccount = "recovery-display-v1"
    static let bootstrapService = "com.khm.snippets.cloud-bootstrap"
    static let bootstrapSecretAccounts = [
        pairingAccount,
        approvalAccount,
        pendingRecoveryAccount,
        recoveryPresentationAccount,
    ]

    let selection: SyncBackendSelectionStore
    private let secrets: KeychainSecretStore
    private var recoveryPresentationGate = SnippetsCloudRecoveryPresentationGate()

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
                confirmationCode: invitation.confirmationCode)
        }
        if try selection.cloudKeys.material(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID) != nil {
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
        presentationContext: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> State {
        try await selection.signIn(
            serverURL: serverURL,
            requiresStrongAuthentication: strong,
            presentationContext: presentationContext)
        return try await finishPostAuthorization()
    }

    @discardableResult
    func beginPairing() async throws -> State {
        let (coordinates, client) = try client()
        guard try selection.cloudKeys.material(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID) == nil else {
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
            confirmationCode: invitation.confirmationCode)
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
                confirmationCode: invitation.confirmationCode)
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
              try selection.cloudKeys.material(
                serverURL: coordinates.serverURL,
                spaceID: coordinates.spaceID) != nil else {
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
        guard let material = try selection.cloudKeys.material(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID) else { throw Failure.invalidState }
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
        return .strongAuthenticationRequired(.replaceRecovery)
    }

    func acknowledgeRecoveryKitSaved() throws {
        recoveryPresentationGate.reset()
        try secrets.deleteItem(account: Self.recoveryPresentationAccount)
        // If the app was interrupted between persisting the presentation and removing
        // the upload journal, acknowledging the saved kit completes that same journal.
        try secrets.deleteItem(account: Self.pendingRecoveryAccount)
    }

    func signOutThisDevice() async throws {
        if selection.hasPendingLocalErase {
            try selection.resumePendingLocalErase(bootstrapSecrets: secrets)
            return
        }
        // Do not destroy retry state until both the resource server and identity
        // provider confirm revocation. The selection layer then journals local erase,
        // removes the root first, and removes credentials/coordinates last.
        try await selection.revokeSnippetsCloudSession()
        try selection.forgetSnippetsCloudLocally(bootstrapSecrets: secrets)
    }

    private func finishPostAuthorization() async throws -> State {
        let (coordinates, client) = try client()
        if let raw = try secrets.loadItem(account: Self.approvalAccount),
           let payload = String(data: raw, encoding: .utf8) {
            let invitation = try LibraryKeyBootstrap.PairingInvitation(qrPayload: payload)
            guard invitation.serverURL == coordinates.serverURL,
                  invitation.spaceID == coordinates.spaceID,
                  let material = try selection.cloudKeys.material(
                    serverURL: coordinates.serverURL,
                    spaceID: coordinates.spaceID) else { throw Failure.accountMismatch }
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
                selection.activateSnippetsCloud()
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
            selection.activateSnippetsCloud()
            return .ready
        }

        if let pending = try pendingRecovery() {
            return try await uploadPendingRecovery(pending, coordinates: coordinates, client: client)
        }

        if try selection.cloudKeys.material(
            serverURL: coordinates.serverURL,
            spaceID: coordinates.spaceID) != nil {
            selection.activateSnippetsCloud()
            return .ready
        }

        let remote = try await mapService { try await client.recoveryState() }
        async let containsRecords = mapService { try await client.hasRemoteRecords() }
        let hasRemoteRecords = try await containsRecords
        if remote.recovery != nil || hasRemoteRecords {
            selection.parkSnippetsCloudUntilKeyReady()
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
            selection.parkSnippetsCloudUntilKeyReady()
            return .strongAuthenticationRequired(.createInitialRecovery)
        } catch Failure.service(let code) where code == "conflict" {
            try secrets.deleteItem(account: Self.pendingRecoveryAccount)
            selection.parkSnippetsCloudUntilKeyReady()
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
                spaceID: coordinates.spaceID)
        }
        try secrets.storeItem(
            Data(pending.kitPayload.utf8),
            account: Self.recoveryPresentationAccount)
        try secrets.deleteItem(account: Self.pendingRecoveryAccount)
        selection.activateSnippetsCloud()
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
            spaceID: coordinates.spaceID)
        selection.activateSnippetsCloud()
    }

    private func client() throws -> (
        SyncBackendSelectionStore.CloudCoordinates,
        SnippetsCloudBootstrapClient
    ) {
        guard let coordinates = selection.cloudCoordinates,
              selection.hasCloudSession else { throw Failure.invalidState }
        let client = try SnippetsCloudBootstrapClient(
            baseURL: coordinates.serverURL,
            spaceID: coordinates.spaceID,
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
