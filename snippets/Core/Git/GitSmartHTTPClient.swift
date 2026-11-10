import Foundation

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// One SSH destination, as git understands it.
///
/// `scpStyle` keeps `user@host:path` (a path relative to the server account) distinct
/// from `ssh://user@host[:port]/path` (an absolute path); hosted services accept both,
/// but a plain sshd does not treat them the same.
nonisolated struct GitSSHLocation: Sendable, Equatable {
    let user: String?
    /// Host name, `~/.ssh/config` alias, or IP literal (no brackets).
    let host: String
    let port: Int?
    let path: String
    let scpStyle: Bool

    /// Conservative character sets: these values reach an ssh command line and a
    /// remote shell, so nothing that could become an option or a metacharacter passes.
    init(user: String?, host: String, port: Int?, path: String, scpStyle: Bool) throws {
        func allowed(_ text: String, extra: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || extra.unicodeScalars.contains($0)
            }
        }
        guard user.map({ allowed($0, extra: "._-") && !$0.hasPrefix("-") }) ?? true,
              allowed(host, extra: ".-_:"), !host.hasPrefix("-"), !host.hasPrefix("."),
              port.map({ (1...65_535).contains($0) }) ?? true,
              (1...1_024).contains(path.utf8.count), !path.hasPrefix("-"),
              path.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7f
                  && !"'\\\"`$;&|<>(){}*?[]!#%".unicodeScalars.contains($0) }),
              !path.split(separator: "/").contains("..") else {
            throw GitRemote.Failure.invalidURL
        }
        self.user = user
        self.host = host
        self.port = port
        self.path = path
        self.scpStyle = scpStyle
    }

    /// `user@host` or `host`, for the ssh command line and NIO.
    var destination: String { user.map { "\($0)@\(host)" } ?? host }

    var spec: String {
        if scpStyle { return "\(destination):\(path)" }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let userPart = user.map { "\($0)@" } ?? ""
        return "ssh://\(userPart)\(hostPart)\(port.map { ":\($0)" } ?? "")\(path)"
    }
}

/// Where a repository lives: an HTTPS URL or an SSH destination.
nonisolated enum GitRepositoryLocation: Sendable, Equatable {
    case https(URL)
    case ssh(GitSSHLocation)

    var isSSH: Bool { if case .ssh = self { true } else { false } }

    /// The normalized text stored in preferences and shown in forms.
    var spec: String {
        switch self {
        case .https(let url): url.absoluteString
        case .ssh(let location): location.spec
        }
    }

    /// `host/path`: lowercase host; no scheme, user, port, leading `/` or `.git`.
    /// `git@github.com:me/lib.git` and `https://github.com/me/lib` are one repository,
    /// so one library key and one local sync state serve both access methods.
    var canonicalIdentity: String {
        let host: String
        var path: String
        switch self {
        case .https(let url):
            host = url.host?.lowercased() ?? ""
            path = url.path
        case .ssh(let location):
            host = location.host.lowercased()
            path = location.path
        }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        return "\(host)/\(path)"
    }

    /// Accepts `https://…`, `ssh://[user@]host[:port]/path` and scp-like
    /// `[user@]host:path`. A bare `host/path` is read as HTTPS.
    static func parse(_ raw: String, allowsInsecureLoopback: Bool = false) throws -> GitRepositoryLocation {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7f }) else {
            throw GitRemote.Failure.invalidURL
        }
        if text.lowercased().hasPrefix("ssh://") || text.lowercased().hasPrefix("git+ssh://") {
            guard let components = URLComponents(string: text.replacingOccurrences(of: "git+ssh://", with: "ssh://")),
                  let host = components.host, components.password == nil,
                  components.query == nil, components.fragment == nil else {
                throw GitRemote.Failure.invalidURL
            }
            let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
            guard path.hasPrefix("/") else { throw GitRemote.Failure.invalidURL }
            return .ssh(try GitSSHLocation(
                user: components.user, host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                port: components.port, path: path, scpStyle: false))
        }
        if text.contains("://") {
            guard let url = URL(string: text) else { throw GitRemote.Failure.invalidURL }
            return .https(try GitRemote.normalizedURL(url, allowsInsecureLoopback: allowsInsecureLoopback))
        }
        // scp-like: the first ':' comes before any '/'.
        if let colon = text.firstIndex(of: ":"),
           !text[..<colon].contains("/") {
            let destination = String(text[..<colon])
            let path = String(text[text.index(after: colon)...])
            let user: String?
            let host: String
            if let at = destination.lastIndex(of: "@") {
                user = String(destination[..<at])
                host = String(destination[destination.index(after: at)...])
            } else {
                user = nil
                host = destination
            }
            return .ssh(try GitSSHLocation(user: user, host: host, port: nil, path: path, scpStyle: true))
        }
        guard let url = URL(string: "https://" + text) else { throw GitRemote.Failure.invalidURL }
        return .https(try GitRemote.normalizedURL(url, allowsInsecureLoopback: allowsInsecureLoopback))
    }
}

/// Where and as whom to talk to a hosted repository.
///
/// HTTPS uses an HTTP Basic pair: every mainstream host (GitHub, GitLab, Gitea/Forgejo,
/// GitVerse, Bitbucket) accepts a personal access token as the password for its
/// smart-HTTP endpoint. SSH authenticates outside this type: on macOS the system `ssh`
/// with the user's agent and configuration, on iOS a per-device key.
nonisolated struct GitRemote: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    nonisolated enum Failure: Error, Equatable, Sendable {
        case invalidURL
        case invalidBranch
        case invalidCredential
    }

    let location: GitRepositoryLocation
    let branch: String
    /// HTTPS only; empty for SSH.
    let username: String
    /// HTTPS only; empty for SSH.
    let password: String

    /// The HTTPS endpoint. SSH remotes have none; nothing on the SSH path reads it.
    var url: URL {
        if case .https(let url) = location { return url }
        return URL(string: "about:blank")!
    }

    var refName: String { "refs/heads/\(branch)" }

    /// Never prints the token, including through `dump`, `print` or a debugger summary.
    var description: String { "GitRemote(\(location.spec), \(refName))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["location": location.spec, "branch": branch, "password": "<redacted>"])
    }

    /// Scheme-independent repository identity; see `GitRepositoryLocation.canonicalIdentity`.
    var canonicalLocation: String { location.canonicalIdentity }

    static func canonicalLocation(of normalizedURL: URL) -> String {
        GitRepositoryLocation.https(normalizedURL).canonicalIdentity
    }

    /// An HTTPS remote with a token.
    init(
        url: URL, branch: String, username: String, password: String,
        allowsInsecureLoopback: Bool = false
    ) throws {
        let normalized = try Self.normalizedURL(url, allowsInsecureLoopback: allowsInsecureLoopback)
        guard Self.isValidBranch(branch) else { throw Failure.invalidBranch }
        guard Self.isValidUsername(username), Self.isValidToken(password) else {
            throw Failure.invalidCredential
        }
        location = .https(normalized)
        self.branch = branch
        self.username = username
        self.password = password
    }

    /// An SSH remote; authentication is the connection's business.
    init(ssh: GitSSHLocation, branch: String) throws {
        guard Self.isValidBranch(branch) else { throw Failure.invalidBranch }
        location = .ssh(ssh)
        self.branch = branch
        username = ""
        password = ""
    }

    /// Lowercase scheme and host, no credentials, query, fragment or trailing slash.
    /// HTTPS only; plain HTTP is accepted solely for loopback hosts when a test opts in.
    static func normalizedURL(_ url: URL, allowsInsecureLoopback: Bool = false) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw Failure.invalidURL
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host.hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && allowsInsecureLoopback && loopback) else {
            throw Failure.invalidURL
        }
        components.scheme = scheme
        components.host = host
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard !components.percentEncodedPath.isEmpty, let normalized = components.url else {
            throw Failure.invalidURL
        }
        return normalized
    }

    static func isValidUsername(_ username: String) -> Bool {
        (1...256).contains(username.utf8.count) && !username.contains(":")
            && username.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    static func isValidToken(_ token: String) -> Bool {
        (1...4_096).contains(token.utf8.count)
            && token.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    /// A conservative subset of `git check-ref-format`.
    static func isValidBranch(_ branch: String) -> Bool {
        guard (1...200).contains(branch.utf8.count),
              branch.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte)
                      || (0x61...0x7a).contains(byte)
                      || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
                      || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "/")
              }) else { return false }
        if branch.hasPrefix("-") || branch.hasPrefix("/") || branch.hasSuffix("/")
            || branch.hasSuffix(".") || branch.hasSuffix(".lock")
            || branch.contains("..") || branch.contains("//") || branch == "HEAD" {
            return false
        }
        return !branch.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// A failure talking to the host. Cases carry only status codes and fixed reasons;
/// server-provided text (which may echo the repository path) is never retained.
nonisolated enum GitRemoteFailure: Error, Equatable, Sendable {
    case authenticationRequired(status: Int)
    case repositoryNotFound
    case rateLimited(retryAfter: TimeInterval)
    case unreachable(String)
    case unsupportedServer(String)
    case protocolViolation(String)
    case serverError(status: Int)
    case responseTooLarge
    /// SSH: the host's key is not in known_hosts (or not yet trusted on this device).
    case sshHostKeyUnknown
    /// SSH: the host presented a different key than the one trusted before.
    case sshHostKeyChanged
    /// SSH: no offered key was accepted.
    case sshPermissionDenied
    /// HTTP 413: the host or a proxy in front of it refused the request body.
    case requestTooLarge
}

nonisolated struct GitRefAdvertisement: Sendable, Equatable {
    var refs: [String: GitObjectID]
    var capabilities: [String: String?]
    /// Where the service endpoints live. Equal to the configured URL unless discovery
    /// was redirected (for example `/owner/repo` to `/owner/repo.git`); git itself
    /// rebases later requests the same way, because POSTs cannot follow redirects.
    var serviceURL: URL? = nil

    func supports(_ capability: String) -> Bool { capabilities.keys.contains(capability) }
}

nonisolated enum GitPushResult: Sendable, Equatable {
    case updated
    /// The server refused the ref update. Most often the ref moved since discovery;
    /// a protected branch or hook rejection looks the same on the wire.
    case rejected
}

/// The two smart-HTTP services, using protocol v0/v1 framing. Every host still speaks
/// it, and `git-receive-pack` has no protocol-v2 equivalent, so one code path covers
/// both directions.
nonisolated struct GitSmartHTTPClient: Sendable {
    enum Service: String, Sendable {
        case uploadPack = "git-upload-pack"
        case receivePack = "git-receive-pack"
    }

    static let maximumAdvertisementBytes = 8 * 1024 * 1024
    #if os(iOS)
    static let maximumPackBytes = 128 * 1024 * 1024
    #else
    static let maximumPackBytes = 512 * 1024 * 1024
    #endif
    static let userAgent = "git/2.0 (Snippets)"

    let remote: GitRemote
    let session: URLSession

    init(remote: GitRemote, session: URLSession) {
        self.remote = remote
        self.session = session
    }

    // MARK: Discovery

    func discover(_ service: Service) async throws -> GitRefAdvertisement {
        var components = URLComponents(
            url: remote.url.appending(path: "info/refs"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "service=\(service.rawValue)"
        var request = makeRequest(url: components.url!, method: "GET")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, maximumBytes: Self.maximumAdvertisementBytes)
        guard response.mimeType == "application/x-\(service.rawValue)-advertisement" else {
            // A "dumb" HTTP server, a login page, or a proxy error document.
            throw GitRemoteFailure.unsupportedServer("not_smart_http")
        }
        var advertisement = try Self.parseAdvertisement(data, service: service)
        advertisement.serviceURL = Self.serviceURL(after: response.url) ?? remote.url
        return advertisement
    }

    /// The redirect guard already pinned scheme, host and port.
    static func serviceURL(after finalURL: URL?) -> URL? {
        guard let finalURL,
              var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/info/refs") else { return nil }
        components.percentEncodedPath.removeLast("/info/refs".count)
        components.percentEncodedQuery = nil
        guard !components.percentEncodedPath.isEmpty else { return nil }
        return components.url
    }

    static func parseAdvertisement(_ data: Data, service: Service) throws -> GitRefAdvertisement {
        var reader = GitPktLine.Reader([UInt8](data))
        var packet = try reader.next()
        if case .data(let first) = packet, GitPktLine.text(first).hasPrefix("# service=") {
            guard GitPktLine.text(first) == "# service=\(service.rawValue)",
                  try reader.next() == .flush else {
                throw GitRemoteFailure.protocolViolation("advertisement_header")
            }
            packet = try reader.next()
        }
        var refs: [String: GitObjectID] = [:]
        var capabilities: [String: String?] = [:]
        var first = true
        while let current = packet, case .data(let payload) = current {
            var line = payload
            if line.last == UInt8(ascii: "\n") { line.removeLast() }
            if first, let nul = line.firstIndex(of: 0) {
                let capabilityText = String(decoding: line[(nul + 1)...], as: UTF8.self)
                for token in capabilityText.split(separator: " ") {
                    if let equals = token.firstIndex(of: "=") {
                        capabilities[String(token[..<equals])] = String(token[token.index(after: equals)...])
                    } else {
                        capabilities[String(token)] = .some(nil)
                    }
                }
                line = Array(line[..<nul])
            }
            first = false
            let text = String(decoding: line, as: UTF8.self)
            guard let space = text.firstIndex(of: " "),
                  let id = GitObjectID(hex: text[..<space]) else {
                throw GitRemoteFailure.protocolViolation("advertisement_ref")
            }
            let name = String(text[text.index(after: space)...])
            if name != "capabilities^{}" && !name.hasSuffix("^{}") {
                refs[name] = id
            }
            packet = try reader.next()
        }
        guard packet == .flush || packet == nil else {
            throw GitRemoteFailure.protocolViolation("advertisement_end")
        }
        if let format = capabilities["object-format"], format != "sha1" {
            throw GitRemoteFailure.unsupportedServer("object_format")
        }
        return GitRefAdvertisement(refs: refs, capabilities: capabilities)
    }

    // MARK: Fetch

    /// Downloads a pack containing `want` and everything it needs that is not
    /// reachable from `haves` (see `uploadRequest` for how haves and `deepen` combine).
    func fetchPack(
        want: GitObjectID,
        haves: [GitObjectID],
        advertisement: GitRefAdvertisement
    ) async throws -> Data {
        let (body, shallow, sideBand) = try Self.uploadRequest(want: want, haves: haves, advertisement: advertisement)
        var request = makeRequest(
            url: (advertisement.serviceURL ?? remote.url).appending(path: "git-upload-pack"),
            method: "POST")
        request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-upload-pack-result", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await send(request, maximumBytes: Self.maximumPackBytes)
        guard response.mimeType == "application/x-git-upload-pack-result" else {
            throw GitRemoteFailure.protocolViolation("upload_pack_content_type")
        }
        return try Self.extractPack(from: [UInt8](data), expectsShallowInfo: shallow, sideBand: sideBand)
    }

    /// The upload-pack request, identical over HTTP and SSH.
    static func uploadRequest(
        want: GitObjectID, haves: [GitObjectID], advertisement: GitRefAdvertisement
    ) throws -> (body: Data, shallow: Bool, sideBand: String?) {
        // A device with nothing cached asks for the tip alone (`deepen 1`): history would
        // only add superseded ciphertext. A device holding snapshots names them as plain
        // haves, so the server sends just what changed since. (Declaring them shallow
        // instead makes servers resend the whole snapshot.) If the server then leaves out
        // an object it assumed came with history this device never kept, the snapshot
        // install fails and the caller refetches with no haves.
        let shallow = haves.isEmpty && advertisement.supports("shallow")
        let sideBand = advertisement.supports("side-band-64k")
            ? "side-band-64k" : (advertisement.supports("side-band") ? "side-band" : nil)
        var capabilities = ["ofs-delta", "no-progress", "agent=snippets/1"]
        if let sideBand { capabilities.append(sideBand) }
        if shallow { capabilities.append("shallow") }
        capabilities = capabilities.filter { name in
            name.hasPrefix("agent=") || advertisement.supports(name)
        }
        var body = Data()
        body.append(try GitPktLine.line("want \(want.hex) \(capabilities.joined(separator: " "))"))
        if shallow {
            body.append(try GitPktLine.line("deepen 1"))
        }
        body.append(GitPktLine.flush)
        for have in haves { body.append(try GitPktLine.line("have \(have.hex)")) }
        body.append(try GitPktLine.line("done"))
        return (body, shallow, sideBand)
    }

    static func extractPack(
        from bytes: [UInt8], expectsShallowInfo: Bool, sideBand: String?
    ) throws -> Data {
        var reader = GitPktLine.Reader(bytes)
        if expectsShallowInfo {
            while true {
                guard let packet = try reader.next() else {
                    throw GitRemoteFailure.protocolViolation("shallow_info")
                }
                if packet == .flush { break }
                guard case .data(let payload) = packet else {
                    throw GitRemoteFailure.protocolViolation("shallow_info")
                }
                let text = GitPktLine.text(payload)
                if text.hasPrefix("ERR ") { throw GitRemoteFailure.protocolViolation("upload_pack_error") }
                guard text.hasPrefix("shallow ") || text.hasPrefix("unshallow ") else {
                    // Some servers skip the section when nothing is shallow; rewind.
                    reader = GitPktLine.Reader(bytes)
                    break
                }
            }
        }
        // Without multi_ack git sends one NAK or "ACK <id>"; GitHub acknowledges every
        // common have. Skip any further acknowledgements before the pack.
        guard case .data(let ack) = try reader.next() else {
            throw GitRemoteFailure.protocolViolation("acknowledgement")
        }
        let ackText = GitPktLine.text(ack)
        if ackText.hasPrefix("ERR ") { throw GitRemoteFailure.protocolViolation("upload_pack_error") }
        guard ackText == "NAK" || ackText.hasPrefix("ACK ") else {
            throw GitRemoteFailure.protocolViolation("acknowledgement")
        }
        while sideBand != nil {
            // Without side-band the pack follows raw, and is not a pkt-line.
            var probe = reader
            guard case .data(let next)? = try? probe.next() else { break }
            let text = GitPktLine.text(next)
            guard text == "NAK" || text.hasPrefix("ACK ") else { break }
            reader = probe
        }
        guard sideBand != nil else { return Data(reader.remainder) }
        return try demultiplex(&reader)
    }

    /// Band 1 is payload, band 2 progress, band 3 a fatal error from the server.
    static func demultiplex(_ reader: inout GitPktLine.Reader) throws -> Data {
        var output = Data()
        while let packet = try reader.next() {
            switch packet {
            case .flush:
                return output
            case .data(let payload):
                guard let band = payload.first else {
                    throw GitRemoteFailure.protocolViolation("side_band")
                }
                switch band {
                case 1: output.append(contentsOf: payload.dropFirst())
                case 2: continue
                case 3: throw GitRemoteFailure.protocolViolation("remote_error")
                default: throw GitRemoteFailure.protocolViolation("side_band")
                }
            case .delimiter, .responseEnd:
                throw GitRemoteFailure.protocolViolation("side_band")
            }
        }
        return output
    }

    // MARK: Push

    /// Atomically moves `refName` from `old` to `new`. The server checks `old` under
    /// its ref lock, which makes this the compare-and-swap for the whole library.
    ///
    /// `new == .zero` deletes the ref; git then requires that no pack follows.
    func push(
        old: GitObjectID, new: GitObjectID, pack: Data, advertisement: GitRefAdvertisement
    ) async throws -> GitPushResult {
        let (body, sideBand) = try Self.pushRequest(
            old: old, new: new, refName: remote.refName, pack: pack, advertisement: advertisement)
        var request = makeRequest(
            url: (advertisement.serviceURL ?? remote.url).appending(path: "git-receive-pack"),
            method: "POST")
        request.setValue("application/x-git-receive-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-receive-pack-result", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await send(request, maximumBytes: Self.maximumAdvertisementBytes)
        guard response.mimeType == "application/x-git-receive-pack-result" else {
            throw GitRemoteFailure.protocolViolation("receive_pack_content_type")
        }
        return try Self.parseReportStatus([UInt8](data), refName: remote.refName, sideBand: sideBand)
    }

    /// The receive-pack request, identical over HTTP and SSH.
    static func pushRequest(
        old: GitObjectID, new: GitObjectID, refName: String, pack: Data, advertisement: GitRefAdvertisement
    ) throws -> (body: Data, sideBand: Bool) {
        guard advertisement.supports("report-status") else {
            throw GitRemoteFailure.unsupportedServer("report_status")
        }
        if new.isZero {
            guard pack.isEmpty, advertisement.supports("delete-refs") else {
                throw GitRemoteFailure.unsupportedServer("delete_refs")
            }
        }
        let sideBand = advertisement.supports("side-band-64k")
        var capabilities = ["report-status", "agent=snippets/1"]
        if sideBand { capabilities.append("side-band-64k") }
        if advertisement.supports("quiet") { capabilities.append("quiet") }
        var commandBytes = Array("\(old.hex) \(new.hex) \(refName)".utf8)
        commandBytes.append(0)
        commandBytes.append(contentsOf: Array((capabilities.joined(separator: " ") + "\n").utf8))
        var body = try GitPktLine.encode(commandBytes)
        body.append(GitPktLine.flush)
        body.append(pack)
        return (body, sideBand)
    }

    static func parseReportStatus(_ bytes: [UInt8], refName: String, sideBand: Bool) throws -> GitPushResult {
        var status = bytes
        if sideBand {
            var reader = GitPktLine.Reader(bytes)
            status = [UInt8](try demultiplex(&reader))
        }
        var reader = GitPktLine.Reader(status)
        guard case .data(let unpack) = try reader.next() else {
            throw GitRemoteFailure.protocolViolation("report_status")
        }
        let unpackText = GitPktLine.text(unpack)
        guard unpackText.hasPrefix("unpack ") else {
            throw GitRemoteFailure.protocolViolation("report_status")
        }
        guard unpackText == "unpack ok" else {
            throw GitRemoteFailure.protocolViolation("remote_unpack_failed")
        }
        var result: GitPushResult?
        while let packet = try reader.next(), case .data(let payload) = packet {
            let text = GitPktLine.text(payload)
            if text == "ok \(refName)" {
                result = .updated
            } else if text.hasPrefix("ng \(refName) ") {
                result = .rejected
            }
        }
        guard let result else { throw GitRemoteFailure.protocolViolation("report_status") }
        return result
    }

    // MARK: HTTP

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = method
        let credential = Data("\(remote.username):\(remote.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func send(
        _ request: URLRequest, maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        func mapped(_ error: any Error) -> any Error {
            switch error {
            case let error as URLError:
                switch error.code {
                case .userAuthenticationRequired: GitRemoteFailure.authenticationRequired(status: 401)
                case .cancelled: CancellationError()
                default: GitRemoteFailure.unreachable("network_\(error.code.rawValue)")
                }
            case is CancellationError, is GitRemoteFailure: error
            default: GitRemoteFailure.unreachable("network")
            }
        }
        // Streamed so the size limit holds while the body arrives, not after a hostile
        // server has made the app buffer all of it.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: GitRedirectGuard.shared)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw GitRemoteFailure.protocolViolation("not_http")
        }
        switch http.statusCode {
        case 200:
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                bytes.task.cancel()
                throw GitRemoteFailure.responseTooLarge
            }
            var body = [UInt8]()
            body.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maximumBytes)))))
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > maximumBytes {
                        bytes.task.cancel()
                        throw GitRemoteFailure.responseTooLarge
                    }
                }
            } catch {
                throw mapped(error)
            }
            return (Data(body), http)
        case 401, 403:
            bytes.task.cancel()
            throw GitRemoteFailure.authenticationRequired(status: http.statusCode)
        case 404:
            bytes.task.cancel()
            // GitHub and GitLab answer 404 for a private repository the token cannot see.
            throw GitRemoteFailure.repositoryNotFound
        case 413:
            bytes.task.cancel()
            throw GitRemoteFailure.requestTooLarge
        case 429, 503:
            bytes.task.cancel()
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                .flatMap { $0.isFinite ? $0 : nil } ?? 30
            throw GitRemoteFailure.rateLimited(retryAfter: min(max(retry, 1), 3_600))
        case 500...599:
            bytes.task.cancel()
            throw GitRemoteFailure.serverError(status: http.statusCode)
        default:
            bytes.task.cancel()
            throw GitRemoteFailure.protocolViolation("http_\(http.statusCode)")
        }
    }
}

/// Follows a redirect only to the same scheme and host. URLSession would otherwise
/// carry the explicit `Authorization` header to wherever a compromised or misconfigured
/// server points it.
nonisolated final class GitRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GitRedirectGuard()

    // The completion-handler form on purpose: the async form's Objective-C thunk
    // crashes the compiler under the app target's MainActor default isolation.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.permits(from: task.originalRequest, to: request) ? request : nil)
    }

    static func permits(from original: URLRequest?, to redirected: URLRequest) -> Bool {
        guard let source = original?.url, let target = redirected.url,
              original?.httpMethod ?? "GET" == "GET" else { return false }
        return target.scheme?.lowercased() == source.scheme?.lowercased()
            && target.host?.lowercased() == source.host?.lowercased()
            && target.port == source.port
    }
}
