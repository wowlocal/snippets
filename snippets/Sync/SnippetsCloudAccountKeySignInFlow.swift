import Foundation

nonisolated enum SnippetsCloudAccountKeySignInFailure: Error, LocalizedError, Equatable {
    /// The typed key failed local normalization or its check symbols. It was not sent.
    case invalidAccountKey
    /// The server answered `invalid_account_key` for a locally valid key.
    case accountKeyNotAccepted
    case rateLimited(TimeInterval)
    case unavailable
    case invalidResponse
    case cancelled
    /// The pinned server does not advertise `native-device-sign-in-v1`.
    case deviceSignInUnavailable
    /// The ten-minute device sign-in request expired before it was approved.
    case deviceSignInExpired
    /// The server no longer recognizes the request (unknown, replaced, or over-claimed).
    case deviceSignInRejected

    var retryAfter: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidAccountKey: "This isn’t a valid account key. Check it for typos."
        case .accountKeyNotAccepted: "That account key wasn’t accepted. Check it and try again."
        case .rateLimited: "Please wait before trying again."
        case .unavailable: "Couldn’t reach Snippets Cloud. Check your connection and try again."
        case .invalidResponse: "This server could not complete native sign-in. Try again later."
        case .cancelled: "Sign-in was cancelled."
        case .deviceSignInUnavailable: "This server doesn’t support signing in with another device. Use your account key instead."
        case .deviceSignInExpired: "This sign-in request expired. Start again to show a new code."
        case .deviceSignInRejected: "This sign-in request is no longer valid. Start again to show a new code."
        }
    }
}

/// User-facing copy shared by the native Mac and iPhone/iPad sheets (server ADR 0006).
nonisolated enum SnippetsCloudAccountKeyCopy {
    static let saveTitle = "Save Your Account Key"
    static let saveMessage = "This key is the only way to sign in to this account on another device. Snippets can’t recover it or send it to you. Store it in your password manager."
    static let acknowledgeButtonTitle = "I’ve Saved It"
    static let signOutReminder = "You’ll need your account key to sign in again."
    /// ADR 0007: shown instead of the key on a device that another device signed in.
    static let signedInByAnotherDevice = "This device was signed in by another device. View the account key on a device that has it."
    static let deviceSignInInstructions = "On a device that already has your library, open Snippets Cloud, choose to scan a new device invitation, and scan this code or paste the copied text. Continue there only if it shows the same confirmation code."
}

/// What a signed-out device shows while another device approves it (ADR 0007). The
/// payload carries no poll token; the token stays in device-only Keychain.
nonisolated struct SnippetsCloudDeviceSignInPresentation: Equatable, Sendable {
    let qrPayload: String
    let confirmationCode: String
    let expiresAt: Date
}

nonisolated enum SnippetsCloudDeviceSignInClaim: Equatable, Sendable {
    case pending
    case approved
}

/// Owns the requests launched by a native sheet. Cancelling a sheet must drain an
/// in-flight create or sign-in request before the credential owner retires a
/// journaled candidate.
@MainActor
final class SnippetsCloudAccountKeySignInFlow {
    /// Creates an account. The returned key was issued exactly once; the sheet must
    /// show it for saving and wait for an explicit acknowledgement before finishing.
    typealias CreateAccount = @MainActor () async throws -> SnippetsCloudAccountKey
    /// Exchanges a locally validated key for a session.
    typealias SignIn = @MainActor (SnippetsCloudAccountKey) async throws -> Void

    /// ADR 0007 new-device operations, supplied only where a signed-out device may
    /// be signed in by another device.
    struct DeviceSignIn {
        /// Discovery only: whether the pinned server advertises the capability.
        let isAvailable: @MainActor () async -> Bool
        /// Opens (or resumes) a request and stores its material and poll token.
        let begin: @MainActor () async throws -> SnippetsCloudDeviceSignInPresentation
        /// One claim; an approved claim is journaled exactly like any other grant.
        let claim: @MainActor () async throws -> SnippetsCloudDeviceSignInClaim
        /// Cancel discards local state; the server request simply expires.
        let discard: @MainActor () -> Void
    }

    private let create: CreateAccount
    private let submit: SignIn
    private let device: DeviceSignIn?
    private var inFlight: (cancel: () -> Void, drain: () async -> Void)?
    private var cancelled = false

    init(createAccount: @escaping CreateAccount, signIn: @escaping SignIn, deviceSignIn: DeviceSignIn? = nil) {
        create = createAccount
        submit = signIn
        device = deviceSignIn
    }

    func createAccount() async throws -> SnippetsCloudAccountKey {
        try await run { [create] in try await create() }
    }

    /// Local normalization happens here, before any request: a key that fails its
    /// check symbols is a typing error and is never sent.
    func signIn(accountKey input: String) async throws {
        guard !cancelled else { throw CancellationError() }
        guard inFlight == nil else { throw SnippetsCloudAccountKeySignInFailure.rateLimited(1) }
        guard let key = SnippetsCloudAccountKey(normalizing: input) else {
            throw SnippetsCloudAccountKeySignInFailure.invalidAccountKey
        }
        try await run { [submit] in try await submit(key) }
    }

    /// A discovery read only; it never touches credentials, so the sheet may call it
    /// after appearing to decide whether to offer **Sign In with Another Device**.
    func isDeviceSignInAvailable() async -> Bool {
        guard let device, !cancelled else { return false }
        return await device.isAvailable()
    }

    func beginDeviceSignIn() async throws -> SnippetsCloudDeviceSignInPresentation {
        guard let device else { throw SnippetsCloudAccountKeySignInFailure.deviceSignInUnavailable }
        return try await run { try await device.begin() }
    }

    /// Polls the claim about every two seconds until approval, honoring `Retry-After`
    /// and backing off after transport failures. Returns once an approved grant has been
    /// journaled; throws on expiry or a final server answer, after discarding local state.
    func waitForDeviceApproval(
        expiresAt: Date,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws {
        guard let device else { throw SnippetsCloudAccountKeySignInFailure.deviceSignInUnavailable }
        var backoff: TimeInterval = 2
        while true {
            guard !cancelled, !Task.isCancelled else { throw CancellationError() }
            guard now() < expiresAt else {
                device.discard()
                throw SnippetsCloudAccountKeySignInFailure.deviceSignInExpired
            }
            let delay: TimeInterval
            do {
                switch try await run({ try await device.claim() }) {
                case .approved:
                    return
                case .pending:
                    backoff = 2
                    delay = 2
                }
            } catch let failure as SnippetsCloudAccountKeySignInFailure {
                switch failure {
                case .rateLimited(let seconds):
                    delay = min(max(2, seconds), 300)
                case .unavailable:
                    backoff = min(backoff * 2, 30)
                    delay = backoff
                case .deviceSignInExpired, .deviceSignInRejected:
                    device.discard()
                    throw failure
                default:
                    throw failure
                }
            }
            try await sleep(delay)
        }
    }

    func discardDeviceSignIn() {
        device?.discard()
    }

    func cancel() {
        cancelled = true
        inFlight?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        if let inFlight { await inFlight.drain() }
    }

    @discardableResult
    private func run<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !cancelled else { throw CancellationError() }
        guard inFlight == nil else { throw SnippetsCloudAccountKeySignInFailure.rateLimited(1) }
        let task = Task<T, Error> { try await body() }
        inFlight = (cancel: { task.cancel() }, drain: { _ = try? await task.value })
        defer { inFlight = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        return result
    }
}
