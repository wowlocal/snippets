import CryptoKit
import Foundation

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// The git wire protocol (v0/v1) over some byte transport. Smart HTTP and SSH carry
/// identical upload-pack and receive-pack requests; only the framing around them differs.
nonisolated protocol GitWireClient: Sendable {
    func discover(_ service: GitSmartHTTPClient.Service) async throws -> GitRefAdvertisement
    func fetchPack(
        want: GitObjectID, haves: [GitObjectID], advertisement: GitRefAdvertisement
    ) async throws -> Data
    func push(
        old: GitObjectID, new: GitObjectID, pack: Data, advertisement: GitRefAdvertisement
    ) async throws -> GitPushResult
}

extension GitSmartHTTPClient: GitWireClient {}

/// What one SSH exec channel produced.
nonisolated struct GitSSHExchange: Sendable, Equatable {
    /// The ref advertisement, through its terminating flush packet.
    var advertisement: [UInt8]
    /// Everything the service wrote after the advertisement.
    var response: [UInt8]
}

/// Runs one git service over SSH.
///
/// The service speaks first: it writes the ref advertisement, then reads the client's
/// request. A connector reads through the advertisement's flush packet, writes what
/// `request` returns for it (a lone flush packet when it returns nil, which ends the
/// service politely), closes the channel's input, and reads the rest until the service
/// exits. Failures are `GitRemoteFailure`s; nothing a server writes to stderr is ever
/// returned or logged.
nonisolated protocol GitSSHConnector: Sendable {
    func exchange(
        command: String,
        location: GitSSHLocation,
        maximumBytes: Int,
        request: @escaping @Sendable ([UInt8]) throws -> Data?
    ) async throws -> GitSSHExchange
}

/// Used where SSH has no connector (an iOS build without device-key support).
nonisolated struct GitUnavailableSSHConnector: GitSSHConnector {
    func exchange(
        command: String, location: GitSSHLocation, maximumBytes: Int,
        request: @escaping @Sendable ([UInt8]) throws -> Data?
    ) async throws -> GitSSHExchange {
        throw GitRemoteFailure.unsupportedServer("ssh")
    }
}

nonisolated struct GitSSHClient: GitWireClient {
    let remote: GitRemote
    let location: GitSSHLocation
    let connector: any GitSSHConnector

    init(remote: GitRemote, location: GitSSHLocation, connector: any GitSSHConnector) {
        self.remote = remote
        self.location = location
        self.connector = connector
    }

    /// What git itself runs: the service name and the single-quoted path. The path's
    /// character set was validated, so it needs no further escaping.
    static func remoteCommand(_ service: GitSmartHTTPClient.Service, location: GitSSHLocation) -> String {
        var path = location.path
        // `ssh://host/~user/repo` names a home-relative path, as in git.
        if !location.scpStyle, path.hasPrefix("/~") { path.removeFirst() }
        return "\(service.rawValue) '\(path)'"
    }

    func discover(_ service: GitSmartHTTPClient.Service) async throws -> GitRefAdvertisement {
        let exchange = try await connector.exchange(
            command: Self.remoteCommand(service, location: location), location: location,
            maximumBytes: GitSmartHTTPClient.maximumAdvertisementBytes, request: { _ in nil })
        return try GitSmartHTTPClient.parseAdvertisement(Data(exchange.advertisement), service: service)
    }

    func fetchPack(
        want: GitObjectID, haves: [GitObjectID], advertisement: GitRefAdvertisement
    ) async throws -> Data {
        // A stateful SSH upload-pack only serves advertised tips. The caller only asks
        // for tips, so a missing one means the branch moved since discovery: a race.
        let exchange = try await connector.exchange(
            command: Self.remoteCommand(.uploadPack, location: location), location: location,
            maximumBytes: GitSmartHTTPClient.maximumPackBytes
        ) { bytes in
            let live = try GitSmartHTTPClient.parseAdvertisement(Data(bytes), service: .uploadPack)
            guard live.refs.values.contains(want) else { return nil }
            return try GitSmartHTTPClient.uploadRequest(want: want, haves: haves, advertisement: live).body
        }
        let live = try GitSmartHTTPClient.parseAdvertisement(Data(exchange.advertisement), service: .uploadPack)
        guard live.refs.values.contains(want) else { throw GitRemoteFailure.unreachable("ref_moved") }
        let (_, shallow, sideBand) = try GitSmartHTTPClient.uploadRequest(
            want: want, haves: haves, advertisement: live)
        return try GitSmartHTTPClient.extractPack(
            from: exchange.response, expectsShallowInfo: shallow, sideBand: sideBand)
    }

    func push(
        old: GitObjectID, new: GitObjectID, pack: Data, advertisement: GitRefAdvertisement
    ) async throws -> GitPushResult {
        let refName = remote.refName
        @Sendable func current(_ live: GitRefAdvertisement) -> GitObjectID { live.refs[refName] ?? .zero }
        let exchange = try await connector.exchange(
            command: Self.remoteCommand(.receivePack, location: location), location: location,
            maximumBytes: GitSmartHTTPClient.maximumAdvertisementBytes
        ) { bytes in
            let live = try GitSmartHTTPClient.parseAdvertisement(Data(bytes), service: .receivePack)
            // The server would refuse the stale update anyway; don't upload the pack.
            guard current(live) == old else { return nil }
            return try GitSmartHTTPClient.pushRequest(
                old: old, new: new, refName: refName, pack: pack, advertisement: live).body
        }
        let live = try GitSmartHTTPClient.parseAdvertisement(Data(exchange.advertisement), service: .receivePack)
        guard current(live) == old else { return .rejected }
        let sideBand = live.supports("side-band-64k")
        return try GitSmartHTTPClient.parseReportStatus(exchange.response, refName: refName, sideBand: sideBand)
    }
}

extension GitPktLine {
    /// The index just past the first top-level flush packet, nil while incomplete.
    nonisolated static func advertisementEnd(in bytes: [UInt8]) throws -> Int? {
        var offset = 0
        while offset + 4 <= bytes.count {
            let header = bytes[offset..<(offset + 4)]
            guard header.allSatisfy({
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
            }), let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
                throw GitFormatError.invalidPktLine
            }
            if length == 0 { return offset + 4 }
            guard length >= 4 else { throw GitFormatError.invalidPktLine }
            offset += length
        }
        return nil
    }
}

/// Maps what `ssh` and a remote git service print on failure to closed codes. The text
/// itself is never kept.
///
/// Exit status 255 is ssh's own failure, so only ssh's own messages count there: a
/// login script's "command not found" or "No such file or directory" must not turn a
/// dropped connection into a permanent stop. Anything else is the remote git's status.
nonisolated enum GitSSHDiagnosis {
    static func failure(stderr: [UInt8], exitStatus: Int32) -> GitRemoteFailure {
        let text = String(decoding: stderr.prefix(65_536), as: UTF8.self).lowercased()
        func has(_ needle: String) -> Bool { text.contains(needle) }
        if exitStatus == 255 {
            if has("remote host identification has changed") || has("host key for") && has("has changed") {
                return .sshHostKeyChanged
            }
            if has("host key verification failed") || has("no ed25519 host key is known")
                || has("no ecdsa host key is known") || has("host key is not trusted") {
                return .sshHostKeyUnknown
            }
            if has("could not resolve hostname") || has("connection refused") || has("timed out")
                || has("network is unreachable") || has("no route to host") || has("connection closed")
                || has("connection reset") || has("broken pipe") || has("closed by remote host") {
                return .unreachable("ssh_connection")
            }
            if has("no matching host key type") || has("no matching key exchange")
                || has("no matching cipher") || has("no matching mac") {
                return .unsupportedServer("ssh_algorithms")
            }
            if has("permission denied (") || has("too many authentication failures") {
                return .sshPermissionDenied
            }
            return .unreachable("ssh_failed")
        }
        if has("temporarily") || has("try again later") || has("maintenance") {
            return .unreachable("ssh_remote_temporary")
        }
        if exitStatus == 127 && (has("command not found") || has("not found")) {
            return .unsupportedServer("ssh_no_git")
        }
        if has("repository not found") || has("does not appear to be a git repository")
            || has("could not be found") || has("not a git repository") || has("project not found") {
            return .repositoryNotFound
        }
        if has("permission denied") || has("not allowed to push") || has("denied to deploy key")
            || has("you are not allowed") || has("access denied") || has("write access")
            || has("marked as read only") || has("read-only key") || has("deploy key is read") {
            return .sshPermissionDenied
        }
        return .unreachable("ssh_remote_failed")
    }
}

#if os(macOS)
import Darwin

/// SSH through the system `/usr/bin/ssh`, exactly as `git` uses it: the user's
/// `~/.ssh/config`, `known_hosts` and ssh-agent (including `IdentityAgent` agents such
/// as 1Password or Secretive) decide how to connect and authenticate.
///
/// `BatchMode=yes` means ssh never prompts: an unknown host key, a passphrase-protected
/// key that is not in an agent, or a password login fails with a closed code instead.
/// The few session options a user configuration could set that would break a git
/// exchange (a `RemoteCommand`, `SessionType none`, `StdinNull`, backgrounding) are
/// reset; identity, proxy and host-key choices are left to the user's configuration.
nonisolated struct GitSystemSSHConnector: GitSSHConnector {
    var executable = URL(fileURLWithPath: "/usr/bin/ssh")
    /// Options placed before the destination. Tests point ssh at a private config.
    var options: [String] = []
    /// Replaces the inherited environment's `SSH_AUTH_SOCK` when set (tests only).
    var agentSocket: String?
    /// Fails an exchange that makes no progress (no byte read or written) this long.
    var idleTimeout: TimeInterval = 120
    /// Reuses one authenticated connection per host for a while (OpenSSH connection
    /// sharing), so a poll does not pay a full SSH handshake each time.
    var sharesConnections = true

    init(options: [String] = [], agentSocket: String? = nil, timeout: TimeInterval = 120,
         sharesConnections: Bool = true) {
        self.options = options
        self.agentSocket = agentSocket
        self.idleTimeout = timeout
        self.sharesConnections = sharesConnections
    }

    /// Kept a little longer than the 60-second poll, so the connection stays warm while
    /// the app runs and closes itself soon after it stops.
    static let connectionPersistSeconds = 90

    /// A private directory for connection-sharing sockets. Unix socket paths are limited
    /// to about 104 bytes and ssh adds a random suffix while creating one, so it lives
    /// in /tmp, owned by this user with mode 0700. If that cannot be established safely
    /// (someone else owns the name, or it is a link), connections are not shared.
    static func controlDirectory() -> String? {
        let path = "/tmp/snippets-ssh-\(getuid())"
        if mkdir(path, 0o700) != 0, errno != EEXIST { return nil }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else { return nil }
        return path
    }

    func arguments(command: String, location: GitSSHLocation) -> [String] {
        var arguments = [
            "-T", "-x", "-a",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "RemoteCommand=none",
            "-o", "SessionType=default",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
        ]
        if sharesConnections, let directory = Self.controlDirectory() {
            // `%C` hashes the resolved host, user and port, not the alias, so two
            // `~/.ssh/config` aliases for one host (one deploy key each) would share a
            // connection and authenticate with the wrong key. The tag keeps them apart.
            let tag = SHA256.hash(data: Data("\(location.destination)\n\(location.port ?? 0)".utf8))
                .prefix(4).map { String(format: "%02x", $0) }.joined()
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(directory)/%C-\(tag)",
                "-o", "ControlPersist=\(Self.connectionPersistSeconds)",
            ]
        }
        arguments += options
        if let port = location.port { arguments += ["-p", String(port)] }
        arguments += ["--", location.destination, command]
        return arguments
    }

    func exchange(
        command: String, location: GitSSHLocation, maximumBytes: Int,
        request: @escaping @Sendable ([UInt8]) throws -> Data?
    ) async throws -> GitSSHExchange {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(command: command, location: location)
        var environment = ProcessInfo.processInfo.environment
        // English diagnostics for classification; `SendEnv LANG LC_*` in the stock
        // client configuration carries this to the remote git as well.
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        for key in ["GIT_PROTOCOL", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY"] {
            environment.removeValue(forKey: key)
        }
        if let agentSocket { environment["SSH_AUTH_SOCK"] = agentSocket }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // The writer owns its own descriptor and is the only one that closes it, so no
        // other close can race a write or hand the number to an unrelated file. Writing
        // to a dead ssh fails with EPIPE instead of raising SIGPIPE in the app.
        let writer = dup(input.fileHandleForWriting.fileDescriptor)
        guard writer >= 0 else { throw GitRemoteFailure.unreachable("ssh_spawn") }
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.close()

        let run = SSHProcessRun(maximumBytes: maximumBytes, request: request, inputDescriptor: writer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.begin(continuation) { [weak process] in
                    if let process, process.isRunning { process.terminate() }
                }
                process.terminationHandler = { finished in
                    run.processExited(status: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    // Only a missing or non-executable ssh is permanent; a failed spawn
                    // (no memory, too many processes) is worth another try later.
                    let missing = !FileManager.default.isExecutableFile(atPath: executable.path)
                    run.fail(GitRemoteFailure.unsupportedServer(missing ? "ssh_unavailable" : "ssh_spawn"),
                             permanent: true)
                    run.processExited(status: -1)
                    run.stdoutClosed()
                    run.stderrClosed()
                    return
                }
                // A cancel or timeout that came while launching still stops it.
                run.launched()
                let stdout = output.fileHandleForReading
                let stderr = errors.fileHandleForReading
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let chunk = stdout.availableData
                        if chunk.isEmpty { break }
                        run.received(stdout: chunk)
                    }
                    run.stdoutClosed()
                }
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let chunk = stderr.availableData
                        if chunk.isEmpty { break }
                        run.received(stderr: chunk)
                    }
                    run.stderrClosed()
                }
                run.startIdleTimer(limit: idleTimeout)
            }
        } onCancel: {
            run.abort(CancellationError())
        }
    }
}

/// The mutable state of one ssh process, shared by its reader, writer and timer.
private final nonisolated class SSHProcessRun: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    /// Released once used: for a push it holds the pack.
    private var request: (@Sendable ([UInt8]) throws -> Data?)?
    private var inputDescriptor: Int32
    private var writing = false
    private var continuation: CheckedContinuation<GitSSHExchange, any Error>?
    private var terminate: (() -> Void)?
    private var isLaunched = false
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    private var advertisementEnd: Int?
    private var failure: (any Error)?
    private var exitStatus: Int32?
    private var stdoutDone = false
    private var stderrDone = false
    private var lastProgress = Date()
    private var timer: DispatchSourceTimer?

    init(maximumBytes: Int, request: @escaping @Sendable ([UInt8]) throws -> Data?, inputDescriptor: Int32) {
        self.maximumBytes = maximumBytes
        self.request = request
        self.inputDescriptor = inputDescriptor
    }

    func begin(_ continuation: CheckedContinuation<GitSSHExchange, any Error>, terminate: @escaping () -> Void) {
        lock.withLock {
            self.continuation = continuation
            self.terminate = terminate
        }
    }

    func launched() {
        let stop: Bool = lock.withLock {
            isLaunched = true
            return failure != nil
        }
        if stop { terminateProcess() }
    }

    func fail(_ error: any Error, permanent: Bool = false) {
        lock.withLock { if failure == nil { failure = error } }
    }

    /// Records `error` (cancellation, a timeout, an oversized response) and stops ssh.
    func abort(_ error: any Error) {
        let running: Bool = lock.withLock {
            guard continuation != nil else { return false }
            if failure == nil { failure = error }
            return isLaunched
        }
        if running { terminateProcess() }
        closeInput()
    }

    private func terminateProcess() {
        let handler = lock.withLock { terminate }
        handler?()
    }

    func startIdleTimer(limit: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { Date().timeIntervalSince(self.lastProgress) }
            if idle > limit { self.abort(GitRemoteFailure.unreachable("ssh_timeout")) }
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    private func progressed() { lastProgress = Date() }

    func received(stdout chunk: Data) {
        var body: Data?
        var overflow = false
        lock.withLock {
            progressed()
            stdout.append(contentsOf: chunk)
            if stdout.count > maximumBytes + GitSmartHTTPClient.maximumAdvertisementBytes {
                overflow = true
                return
            }
            guard advertisementEnd == nil else { return }
            do {
                guard let end = try GitPktLine.advertisementEnd(in: stdout) else {
                    if stdout.count > GitSmartHTTPClient.maximumAdvertisementBytes {
                        overflow = true
                    }
                    return
                }
                advertisementEnd = end
                let respond = request
                request = nil
                body = try respond?(Array(stdout[..<end])) ?? GitPktLine.flush
            } catch {
                if failure == nil { failure = error }
                body = GitPktLine.flush
            }
            if body != nil, inputDescriptor >= 0 { writing = true } else { body = nil }
        }
        if overflow {
            abort(GitRemoteFailure.responseTooLarge)
            return
        }
        if let body {
            // Written off the reader thread: a large pack must not stall reading.
            DispatchQueue.global(qos: .utility).async { [self] in
                write(body)
            }
        }
    }

    func received(stderr chunk: Data) {
        lock.withLock {
            progressed()
            if stderr.count < 65_536 { stderr.append(contentsOf: chunk.prefix(65_536 - stderr.count)) }
        }
    }

    func stdoutClosed() {
        lock.withLock { stdoutDone = true }
        closeInput()
        finishIfDone()
        scheduleStderrGrace()
    }

    func stderrClosed() {
        lock.withLock { stderrDone = true }
        finishIfDone()
    }

    func processExited(status: Int32) {
        lock.withLock { exitStatus = status }
        finishIfDone()
        scheduleStderrGrace()
    }

    /// A `ControlPersist` master that ssh leaves running can hold stderr open long after
    /// this exchange is over. Once ssh has exited and stdout is closed, whatever stderr
    /// has said within a moment is enough to classify a failure.
    private func scheduleStderrGrace() {
        let ready = lock.withLock { stdoutDone && exitStatus != nil && !stderrDone }
        guard ready else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.withLock { stderrDone = true }
            finishIfDone()
        }
    }

    /// Closes ssh's input unless the writer still owns it; the writer closes it itself.
    private func closeInput() {
        let descriptor: Int32 = lock.withLock {
            guard !writing, inputDescriptor >= 0 else { return -1 }
            defer { inputDescriptor = -1 }
            return inputDescriptor
        }
        if descriptor >= 0 { close(descriptor) }
    }

    private func write(_ data: Data) {
        let descriptor = lock.withLock { inputDescriptor }
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, min(remaining, 65_536))
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                pointer += written
                lock.withLock { progressed() }
            }
        }
        lock.withLock {
            writing = false
            inputDescriptor = -1
        }
        close(descriptor)
    }

    private func finishIfDone() {
        let outcome: (CheckedContinuation<GitSSHExchange, any Error>, Result<GitSSHExchange, any Error>)? =
            lock.withLock {
                guard stdoutDone, stderrDone, let exitStatus, let continuation else { return nil }
                self.continuation = nil
                terminate = nil
                request = nil
                timer?.cancel()
                timer = nil
                var output = stdout
                stdout = []
                if let failure { return (continuation, .failure(failure)) }
                guard let end = advertisementEnd, exitStatus == 0 else {
                    return (continuation, .failure(GitSSHDiagnosis.failure(stderr: stderr, exitStatus: exitStatus)))
                }
                let advertisement = Array(output[..<end])
                output.removeFirst(end)
                return (continuation, .success(GitSSHExchange(advertisement: advertisement, response: output)))
            }
        if let (continuation, result) = outcome {
            closeInput()
            continuation.resume(with: result)
        }
    }
}
#endif
