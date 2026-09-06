import Foundation

nonisolated struct SnippetsCloudEmailChallenge: Equatable, Sendable {
    let email: String
    let expiresAt: Date
    let resendAvailableAt: Date
    let codeLength: Int
}

nonisolated enum SnippetsCloudEmailSignInFailure: Error, LocalizedError, Equatable {
    case invalidEmail
    case invalidCode
    case codeExpired
    case tooManyAttempts
    case rateLimited(TimeInterval)
    case unavailable
    case invalidResponse
    case cancelled

    var retryAfter: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter a valid email address."
        case .invalidCode: "That code is incorrect. Check the email and try again."
        case .codeExpired: "This code has expired. Request a new code."
        case .tooManyAttempts: "Too many incorrect attempts. Request a new code."
        case .rateLimited: "Please wait before trying again."
        case .unavailable: "Couldn’t reach Snippets Cloud. Check your connection and try again."
        case .invalidResponse: "This server could not complete native sign-in. Try again later."
        case .cancelled: "Sign-in was cancelled."
        }
    }
}

/// Owns the requests launched by a native sheet. Cancelling a sheet must drain its
/// verification request before the credential owner retires a journaled candidate.
@MainActor
final class SnippetsCloudEmailSignInFlow {
    typealias SendCode = @MainActor (String) async throws -> SnippetsCloudEmailChallenge
    typealias VerifyCode = @MainActor (String) async throws -> Void

    private let send: SendCode
    private let verify: VerifyCode
    private var operation: Task<SnippetsCloudEmailChallenge?, Error>?
    private var cancelled = false
    private(set) var challenge: SnippetsCloudEmailChallenge?

    init(sendCode: @escaping SendCode, verifyCode: @escaping VerifyCode) {
        send = sendCode
        verify = verifyCode
    }

    func sendCode(to email: String) async throws -> SnippetsCloudEmailChallenge {
        guard !cancelled else { throw CancellationError() }
        guard operation == nil else { throw SnippetsCloudEmailSignInFailure.rateLimited(1) }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(normalized) else { throw SnippetsCloudEmailSignInFailure.invalidEmail }
        let task = Task<SnippetsCloudEmailChallenge?, Error> { try await send(normalized) }
        operation = task
        defer { operation = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !cancelled, !Task.isCancelled, let result else { throw CancellationError() }
        challenge = result
        return result
    }

    func verify(code: String) async throws {
        guard !cancelled else { throw CancellationError() }
        guard operation == nil else { throw SnippetsCloudEmailSignInFailure.rateLimited(1) }
        guard let challenge else { throw SnippetsCloudEmailSignInFailure.codeExpired }
        guard challenge.expiresAt > Date() else { throw SnippetsCloudEmailSignInFailure.codeExpired }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count == challenge.codeLength,
              normalized.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SnippetsCloudEmailSignInFailure.invalidCode
        }
        let task = Task<SnippetsCloudEmailChallenge?, Error> {
            try await verify(normalized)
            return nil
        }
        operation = task
        defer { operation = nil }
        _ = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
    }

    func cancel() {
        cancelled = true
        operation?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        if let operation { _ = try? await operation.value }
    }

    nonisolated static func isValidEmail(_ value: String) -> Bool {
        guard (3...254).contains(value.utf8.count), value.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~")
        guard parts[0].unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
