import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// The local control channel between `snippets-cli` and the running app.
///
/// It exists for exactly one reason: the CLI must be able to *ask for* a secret without
/// being able to *take* one. The vault key is reachable only by the app, so `reveal`
/// is a request that a human approves in the app's own UI, not a decryption the CLI
/// performs.
///
/// ## What peer verification does and does not prove
///
/// The server checks the caller's audit token and code signature, so it knows the
/// connection came from our own signed binary rather than something impersonating it.
/// **That proves which binary is calling. It proves nothing about who told it to.** Any
/// script running as this user can execute the real `snippets-cli`, and no amount of
/// signature checking changes that. The signature check is there to stop a *different*
/// program dressing up as ours; the human consent prompt is the actual control, which
/// is why it names the calling process and why it is not suppressible.
nonisolated enum SnippetsIPC {

    /// Bumped only for incompatible changes. A mismatch is reported rather than guessed
    /// at, because a stale `/usr/local/bin/snippets-cli` symlink is the normal state of
    /// the world, not an exceptional one.
    static let protocolVersion = 1

    /// How long the app leaves its human-consent prompt unanswered before denying it.
    /// The CLI's receive timeout must be longer than this or it will give up before the
    /// app can send the documented `.denied` response.
    static let revealConsentTimeout: TimeInterval = 30
    /// Must cover the consent prompt **and** the Touch ID sheet that follows it, which
    /// LocalAuthentication does not bound. The old `consent + 10` budgeted for neither:
    /// approve at 29s, fumble the sensor for 12s, and the CLI abandoned a request the
    /// user had already approved.
    static let revealAuthenticationTimeout: TimeInterval = 60
    static let revealSocketTimeout: TimeInterval =
        revealConsentTimeout + revealAuthenticationTimeout + 10

    // MARK: - Wire types
    //
    // Flat structs with a string `command`, not an enum with associated values. An
    // unknown command then decodes fine and is answered with `.unsupported`, whereas a
    // Codable enum would fail to decode entirely and the peer would see a parse error
    // instead of "this build does not know that command".

    struct Request: Codable, Sendable {
        var v: Int = SnippetsIPC.protocolVersion
        var command: String
        /// For `reveal`: which snippet, by keyword.
        var keyword: String?
        /// Purely informational, shown in the consent prompt so the user can recognise
        /// what they are approving. Never trusted for any decision.
        var invocation: String?
    }

    struct Response: Codable, Sendable {
        var v: Int = SnippetsIPC.protocolVersion
        var status: Status
        var content: String?
        var message: String?
        var secureCount: Int?
        var unlocked: Bool?

        enum Status: String, Codable, Sendable {
            case ok
            /// The user said no, or the prompt timed out.
            case denied
            /// The vault exists but nothing could unlock it.
            case locked
            case notFound
            /// Known command, refused by policy — e.g. too many requests.
            case refused
            /// This build does not implement the command.
            case unsupported
            case error
        }

        static func failure(_ status: Status, _ message: String) -> Response {
            Response(status: status, message: message)
        }
    }

    enum Command {
        static let ping = "ping"
        static let status = "status"
        static let reveal = "reveal"
    }

    /// Exit codes the CLI reports. Distinct values so a script can tell "you said no"
    /// from "the app is not running" without parsing prose.
    enum ExitCode: Int32, Sendable {
        case ok = 0
        case generic = 1
        case appNotRunning = 3
        case denied = 4
        case locked = 5
        case notFound = 6
        case protocolMismatch = 7
    }

    // MARK: - Where the socket lives

    /// The socket path, kept inside the sync directory unless it will not fit.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes on macOS — a hard limit, not a guideline, and
    /// one that a long home directory or a redirected support directory can genuinely
    /// exceed. Rather than fail at bind time with a confusing `EINVAL`, fall back to a
    /// short, deterministic name in the system temp directory derived from the real
    /// path, so both sides independently agree on it without any handshake.
    static func socketURL(supportFolder: URL = SnippetStorageLocations.syncFolderURL) -> URL {
        let preferred = supportFolder.appendingPathComponent("ipc.sock", isDirectory: false)
        if preferred.path.utf8.count < 100 { return preferred }

        let digest = SHA256.hash(data: Data(preferred.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("snippets-\(digest).sock", isDirectory: false)
    }
}

/// Minimal `AF_UNIX` plumbing, newline-delimited JSON.
///
/// One request and one response per connection, then close. A long-lived channel would
/// need framing, heartbeats, and reconnection logic to buy nothing: the CLI runs for
/// milliseconds and asks one question.
nonisolated enum UnixSocket {

    enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String)
        case cannotCreate(errno: Int32)
        case cannotBind(path: String, errno: Int32)
        case cannotConnect(path: String, errno: Int32)
        case io(errno: Int32)
        case closed
        case malformed

        var description: String {
            switch self {
            case .pathTooLong(let path):
                return "socket path is too long for sockaddr_un (104 bytes): \(path)"
            case .cannotCreate(let code):
                return "could not create a socket: \(String(cString: strerror(code)))"
            case .cannotBind(let path, let code):
                return "could not bind \(path): \(String(cString: strerror(code)))"
            case .cannotConnect(let path, let code):
                return "could not connect to \(path): \(String(cString: strerror(code)))"
            case .io(let code):
                return "socket I/O failed: \(String(cString: strerror(code)))"
            case .closed:
                return "the connection closed before a complete message arrived"
            case .malformed:
                return "the peer sent something that was not a JSON message"
            }
        }
    }

    /// Fills a `sockaddr_un`, refusing rather than silently truncating.
    ///
    /// A truncated path would bind or connect to a *different* socket — one whose name
    /// happens to be a prefix of the intended one. Failing loudly is the only safe
    /// behaviour.
    private static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }

        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Creates a listening socket, replacing any stale one at the same path.
    ///
    /// The unlink is safe and necessary: a socket file left behind by a crashed process
    /// is not connectable but does occupy the name, so `bind` would fail forever until
    /// someone deleted it by hand.
    static func listen(at url: URL, backlog: Int32 = 8) throws -> Int32 {
        let path = url.path
        var addr = try address(for: path)

        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.cannotCreate(errno: errno) }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.cannotBind(path: path, errno: code)
        }

        // 0600 before anyone can connect. The directory is already user-only, but the
        // socket is the thing that brokers access to secrets and should not rely on its
        // parent for that.
        chmod(path, 0o600)

        guard Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw Failure.cannotBind(path: path, errno: code)
        }
        return descriptor
    }

    static func connect(to url: URL, timeout: TimeInterval = 5) throws -> Int32 {
        var addr = try address(for: url.path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.cannotCreate(errno: errno) }

        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.cannotConnect(path: url.path, errno: code)
        }
        return descriptor
    }

    /// Writes one JSON value followed by a newline.
    static func send<T: Encodable>(_ value: T, on descriptor: Int32) throws {
        var payload = try JSONEncoder().encode(value)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                // `send` with MSG_NOSIGNAL, not `write`: a peer that connects and hangs
                // up leaves this writing to a closed socket, and the default SIGPIPE
                // disposition kills the process. Nothing in the app installs a handler —
                // Sparkle's SIG_IGN lives in its updater helper, not the host — so any
                // same-uid process could terminate Snippets on demand, taking the queued
                // secure edit, the pasteboard restore and the pending library write with
                // it. The honest version of the same bug is a slow Touch ID: the CLI's
                // read deadline expires, it closes, and the app dies answering it.
                //
                // SO_NOSIGPIPE is not a substitute — once the peer has hung up, setting
                // it returns EINVAL and the write still kills you, and the attacker
                // chooses that ordering.
                let written = Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, MSG_NOSIGNAL)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.io(errno: errno)
                }
                if written == 0 { throw Failure.closed }
                offset += written
            }
        }
    }

    /// Reads one newline-terminated JSON value.
    ///
    /// - Parameter limit: a hard ceiling on how much a peer can make us buffer. Without
    ///   it, anything that connects and streams could exhaust memory in the app that
    ///   holds the vault key — a denial of service with an unusually bad blast radius.
    static func receive<T: Decodable>(
        _ type: T.Type, on descriptor: Int32, limit: Int = 1 << 20
    ) throws -> T {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(descriptor, &scratch, scratch.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io(errno: errno)
            }
            if count == 0 { throw Failure.closed }

            if let newline = scratch[0..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: scratch[0..<newline])
                break
            }
            buffer.append(contentsOf: scratch[0..<count])
            guard buffer.count <= limit else { throw Failure.malformed }
        }

        guard let value = try? JSONDecoder().decode(type, from: buffer) else {
            throw Failure.malformed
        }
        return value
    }
}
