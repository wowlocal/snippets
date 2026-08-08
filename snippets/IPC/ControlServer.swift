import AppKit
import Darwin
import Security

/// Answers `snippets-cli` over a local socket, and brokers access to secrets.
///
/// The CLI cannot decrypt anything: the vault key is only ever in this process. So
/// `reveal` is a *request*, and what satisfies it is a human clicking Allow in a prompt
/// that names the program asking.
///
/// ## The honest security model
///
/// This server verifies the caller's audit token and code signature, so it knows the
/// connection came from our own signed binary rather than an impostor. **That proves
/// which binary is calling and nothing about who told it to.** Any script running as
/// this user can execute the genuine `snippets-cli`; that is not a hole to be closed,
/// it is what "running as the user" means. The signature check exists to stop a
/// *different* program dressing up as ours. The consent prompt is the real control.
///
/// Which is why the prompt is not suppressible, names the process, and is rate-limited:
/// a prompt that appears often enough becomes a prompt people dismiss without reading,
/// and at that point the control is gone.
@MainActor
final class ControlServer {

    private let session: VaultSession
    private let secureStore: SecureSnippetStore
    private let socketURL: URL
    private let auditURL: URL

    private var listenerDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.khm.snippets.ipc", qos: .userInitiated)

    /// At most this many reveal prompts per window, across all callers.
    ///
    /// A script that loops is the case this defends against: without a ceiling it could
    /// raise prompts faster than they can be read, and the tenth identical dialog gets
    /// approved by reflex. Refusing outright is better than training that reflex.
    private static let revealBudget = 5
    private static let revealWindow: TimeInterval = 60
    private var recentReveals: [Date] = []

    init(session: VaultSession, secureStore: SecureSnippetStore,
         socketURL: URL = SnippetsIPC.socketURL(), auditURL: URL = SnippetStorageLocations.vaultAuditFileURL) {
        self.session = session
        self.secureStore = secureStore
        self.socketURL = socketURL
        self.auditURL = auditURL
    }

    deinit {
        acceptSource?.cancel()
        if listenerDescriptor >= 0 { close(listenerDescriptor) }
    }

    // MARK: - Lifecycle

    /// Starts listening. Safe to call when there is no vault — the socket exists so the
    /// CLI can report status either way, and `reveal` simply answers `notFound`.
    func start() {
        guard listenerDescriptor < 0 else { return }
        do {
            listenerDescriptor = try UnixSocket.listen(at: socketURL)
        } catch {
            // Not fatal. The app is fully usable without the CLI channel, and the most
            // likely cause is a support directory that cannot be written to — which the
            // user has much bigger problems about.
            NSLog("Snippets: could not start the CLI control socket: \(error)")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenerDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let descriptor = accept(self.listenerDescriptor, nil, nil)
            guard descriptor >= 0 else { return }
            self.serve(descriptor)
        }
        source.setCancelHandler { [socketURL] in
            unlink(socketURL.path)
        }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenerDescriptor >= 0 {
            close(listenerDescriptor)
            listenerDescriptor = -1
        }
        unlink(socketURL.path)
    }

    // MARK: - Serving

    /// Runs on `queue`; hops to the main actor only to touch app state or show UI.
    nonisolated private func serve(_ descriptor: Int32) {
        defer { close(descriptor) }

        let peer = PeerIdentity(descriptor: descriptor)
        guard peer.isTrusted else {
            // Deliberately terse. Telling an unverified caller *why* it failed helps it
            // iterate towards passing.
            try? UnixSocket.send(
                SnippetsIPC.Response.failure(.refused, "unrecognised caller"), on: descriptor)
            return
        }

        guard let request = try? UnixSocket.receive(SnippetsIPC.Request.self, on: descriptor) else {
            try? UnixSocket.send(
                SnippetsIPC.Response.failure(.error, "malformed request"), on: descriptor)
            return
        }

        guard request.v == SnippetsIPC.protocolVersion else {
            try? UnixSocket.send(
                SnippetsIPC.Response.failure(
                    .unsupported,
                    "this Snippets speaks protocol \(SnippetsIPC.protocolVersion), the CLI speaks \(request.v)"
                        + " — reinstall the CLI from Settings"),
                on: descriptor)
            return
        }

        let response = DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.handle(request, from: peer) }
        }
        try? UnixSocket.send(response, on: descriptor)
    }

    private func handle(_ request: SnippetsIPC.Request, from peer: PeerIdentity) -> SnippetsIPC.Response {
        switch request.command {
        case SnippetsIPC.Command.ping:
            return SnippetsIPC.Response(status: .ok)

        case SnippetsIPC.Command.status:
            return SnippetsIPC.Response(
                status: .ok,
                secureCount: secureStore.count,
                unlocked: session.state.isUnlocked)

        case SnippetsIPC.Command.reveal:
            return reveal(keyword: request.keyword ?? "", peer: peer)

        default:
            return .failure(.unsupported, "unknown command \"\(request.command)\"")
        }
    }

    // MARK: - Reveal

    private func reveal(keyword: String, peer: PeerIdentity) -> SnippetsIPC.Response {
        let lookup = Snippet.sanitizedKeyword(keyword)
        guard !lookup.isEmpty else { return .failure(.notFound, "no keyword given") }

        let key = SnippetTagging.filterKey(for: lookup)
        guard let shell = secureStore.shells.first(where: {
            SnippetTagging.filterKey(for: $0.normalizedKeyword) == key
        }) else {
            return .failure(.notFound, "no secure snippet with keyword '\(keyword)'")
        }

        guard allowanceRemains() else {
            record(audit: "rate-limited", keyword: lookup, peer: peer)
            return .failure(
                .refused,
                "too many reveal requests in the last minute; approve them one at a time from the app")
        }

        guard confirm(shell: shell, peer: peer) else {
            record(audit: "denied", keyword: lookup, peer: peer)
            return .failure(.denied, "the request was not approved")
        }

        do {
            try session.unlock(reason: "Reveal “\(shell.displayName)” for \(peer.displayName)")
            let content = try secureStore.content(for: shell.id)
            record(audit: "revealed", keyword: lookup, peer: peer)
            return SnippetsIPC.Response(status: .ok, content: content)
        } catch VaultSession.Failure.noKey {
            return .failure(.locked, "the key for this vault is not on this Mac")
        } catch {
            record(audit: "failed", keyword: lookup, peer: peer)
            return .failure(.locked, "\(error)")
        }
    }

    private func allowanceRemains() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.revealWindow)
        recentReveals.removeAll { $0 < cutoff }
        guard recentReveals.count < Self.revealBudget else { return false }
        recentReveals.append(Date())
        return true
    }

    /// The prompt. Modal on purpose, and it names the caller.
    ///
    /// "A program wants to read a secret" is a dialog people approve. "Terminal (pid
    /// 4711) wants to read AWS root password" is one they can actually evaluate, and the
    /// only version that makes consent mean anything.
    private func confirm(shell: Snippet, peer: PeerIdentity) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reveal “\(shell.displayName)” to \(peer.displayName)?"
        alert.informativeText =
            "\(peer.displayName) is asking Snippets for the text of a secure snippet.\n\n"
            + "If you did not just run a command that would need it, deny this.\n\n"
            + "The text will be printed to that program's output, where it may be logged "
            + "or saved in shell history."
        alert.addButton(withTitle: "Reveal")
        alert.addButton(withTitle: "Deny")
        // Deny is the default, so a stray Return key is the safe answer.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Appends to `Vault/audit.json`. **Never records content** — an audit log that
    /// contains the secrets is a second copy of the vault with none of the protection.
    private func record(audit outcome: String, keyword: String, peer: PeerIdentity) {
        struct Entry: Codable {
            var at: Date
            var outcome: String
            var keyword: String
            var caller: String
            var pid: Int32
        }

        var entries = (try? Data(contentsOf: auditURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries.append(Entry(
            at: Date(), outcome: outcome, keyword: keyword,
            caller: peer.displayName, pid: peer.pid))
        // Bounded: this is a diagnostic aid, not a compliance artefact, and an unbounded
        // append-only file in the support directory is its own small bug.
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? AtomicFileWriter.write(data, to: auditURL)
        }
    }
}

/// Who is on the other end of the socket.
nonisolated struct PeerIdentity {
    let pid: Int32
    let isTrusted: Bool
    let displayName: String

    init(descriptor: Int32) {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let gotToken = withUnsafeMutablePointer(to: &token) {
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &size) == 0
        }

        // The audit token, not `LOCAL_PEERPID`. A bare pid is racy — the process can
        // exit and the number be reused by something else between the check and the
        // decision — and the token is what `SecCodeCopyGuestWithAttributes` will accept.
        var reportedPID: Int32 = -1
        var pidSize = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &reportedPID) {
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, $0, &pidSize)
        }
        pid = reportedPID

        guard gotToken else {
            self.isTrusted = false
            self.displayName = "an unidentified program"
            return
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            self.isTrusted = false
            self.displayName = "an unidentified program (pid \(reportedPID))"
            return
        }

        // Same team, and either our own CLI or the app itself. Anchored to the team
        // identifier rather than to a bundle id, because the CLI is a bare Mach-O whose
        // signing identifier is its own.
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"H8QG3CBM96\""
        var requirement: SecRequirement?
        let compiled = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        if compiled == errSecSuccess, let requirement {
            self.isTrusted = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        } else {
            self.isTrusted = false
        }

        self.displayName = PeerIdentity.name(forPID: reportedPID)
    }

    /// A name the user can recognise, which usually means the *terminal* they typed
    /// into rather than `snippets-cli` itself — the CLI is what the shell ran, but the
    /// shell is what the person is looking at.
    private static func name(forPID pid: Int32) -> String {
        var parent = pid
        for _ in 0..<4 {
            if let app = NSRunningApplication(processIdentifier: parent),
               let name = app.localizedName {
                return pid == parent ? name : "\(name) (pid \(pid))"
            }
            guard let next = parentPID(of: parent), next > 1 else { break }
            parent = next
        }
        return "a command-line program (pid \(pid))"
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
