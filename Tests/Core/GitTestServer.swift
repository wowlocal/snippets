import Foundation
@testable import SnippetsCore

/// Serves smart HTTP from a real bare repository by running `git http-backend` as a
/// CGI program for every request. Tests therefore exercise the server-side
/// upload-pack/receive-pack implementation every host is derived from, with no
/// listening socket and no network access.
final class GitHTTPBackendProtocol: URLProtocol, @unchecked Sendable {
    struct Repository {
        var projectRoot: URL
        var username: String
        var password: String
        /// Runs once, immediately before the next receive-pack request is handled.
        var beforeNextReceivePack: (() throws -> Void)?
        var requests: [String] = []
        /// Answers every request for a path outside `redirectPrefix` with a 301 to
        /// `redirectBase` + the same suffix, like a host that canonicalizes `.git`.
        var redirect: (prefix: String, base: String)?
        var authorizationHeaders: [String] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var repositories: [String: Repository] = [:]

    static func register(host: String, _ repository: Repository) {
        lock.withLock { repositories[host] = repository }
    }

    static func unregister(host: String) {
        lock.withLock { repositories[host] = nil }
    }

    static func update(host: String, _ mutate: (inout Repository) -> Void) {
        lock.withLock {
            guard var repository = repositories[host] else { return }
            mutate(&repository)
            repositories[host] = repository
        }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { repositories[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { repositories[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// CFNetwork runs every custom protocol on one shared thread. Running the CGI there
    /// would serialize all parallel tests behind each other's git processes.
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            if let target = redirectTarget() {
                var next = request
                next.url = target
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 301, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            do {
                let (status, headers, body) = try respond()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private func redirectTarget() -> URL? {
        let url = request.url!
        let host = url.host!
        return Self.lock.withLock { () -> URL? in
            Self.repositories[host]?.authorizationHeaders.append(
                request.value(forHTTPHeaderField: "Authorization") ?? "")
            guard let redirect = Self.repositories[host]?.redirect,
                  !url.path.hasPrefix(redirect.prefix) else { return nil }
            Self.repositories[host]?.requests.append("REDIRECT \(request.httpMethod ?? "GET") \(url.path)")
            let suffix = url.path.split(separator: "/").dropFirst().joined(separator: "/")
            var components = URLComponents(string: redirect.base + "/" + suffix)!
            components.percentEncodedQuery = url.query
            return components.url
        }
    }

    static func authorizationHeaders(host: String) -> [String] {
        lock.withLock { repositories[host]?.authorizationHeaders ?? [] }
    }

    private func respond() throws -> (Int, [String: String], Data) {
        let url = request.url!
        let host = url.host!
        var hook: (() throws -> Void)?
        let repository: Repository = Self.lock.withLock {
            var repository = Self.repositories[host]!
            let service = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "service" }?.value
            repository.requests.append("\(request.httpMethod ?? "GET") \(url.lastPathComponent)"
                + (service.map { "?\($0)" } ?? ""))
            if request.httpMethod == "POST", url.lastPathComponent == "git-receive-pack" {
                hook = repository.beforeNextReceivePack
                repository.beforeNextReceivePack = nil
            }
            Self.repositories[host] = repository
            return repository
        }

        let expected = "Basic " + Data("\(repository.username):\(repository.password)".utf8)
            .base64EncodedString()
        guard request.value(forHTTPHeaderField: "Authorization") == expected else {
            return (401, ["WWW-Authenticate": "Basic realm=\"test\"", "Content-Type": "text/plain"],
                    Data("unauthorized".utf8))
        }
        try hook?()

        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "git-cgi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appending(path: "stdin")
        try body.write(to: input)

        var environment = GitFixture.isolatedEnvironment(home: scratch)
        environment["GIT_PROJECT_ROOT"] = repository.projectRoot.path
        environment["GIT_HTTP_EXPORT_ALL"] = "1"
        environment["PATH_INFO"] = url.path
        environment["QUERY_STRING"] = url.query ?? ""
        environment["REQUEST_METHOD"] = request.httpMethod ?? "GET"
        environment["REMOTE_USER"] = repository.username
        environment["REMOTE_ADDR"] = "127.0.0.1"
        if let type = request.value(forHTTPHeaderField: "Content-Type") {
            environment["CONTENT_TYPE"] = type
        }
        if request.httpMethod == "POST" { environment["CONTENT_LENGTH"] = String(body.count) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["http-backend"]
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: input)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let separator = raw.range(of: Data("\r\n\r\n".utf8)) ?? raw.range(of: Data("\n\n".utf8))
        guard let separator else { return (500, [:], Data()) }
        var status = 200
        var headers: [String: String] = [:]
        for line in String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
            .components(separatedBy: .newlines) where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.lowercased() == "status" {
                status = Int(value.prefix(3)) ?? 500
            } else {
                headers[name] = value
            }
        }
        return (status, headers, Data(raw[separator.upperBound...]))
    }
}

/// A bare repository served through `GitHTTPBackendProtocol`, plus a git CLI for
/// playing the part of another writer.
final class GitFixture: @unchecked Sendable {
    let root: URL
    let bare: URL
    let host: String
    let url: URL
    let username = "tester"
    let password = "test-token-\(UUID().uuidString)"
    let session: URLSession

    init(branch: String = "main") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "git-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bare = root.appending(path: "repo.git", directoryHint: .isDirectory)
        host = "repo-\(UUID().uuidString.lowercased()).localhost"
        url = URL(string: "http://\(host)/repo.git")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHTTPBackendProtocol.self]
        session = URLSession(configuration: configuration)
        try git(["init", "--bare", "--quiet", "--initial-branch=\(branch)", bare.path])
        GitHTTPBackendProtocol.register(host: host, .init(
            projectRoot: root, username: username, password: password))
    }

    deinit {
        GitHTTPBackendProtocol.unregister(host: host)
        try? FileManager.default.removeItem(at: root)
    }

    func remote(branch: String = "main", password: String? = nil) throws -> GitRemote {
        try GitRemote(
            url: url, branch: branch, username: username, password: password ?? self.password,
            allowsInsecureLoopback: true)
    }

    func transport(
        _ name: String = UUID().uuidString, branch: String = "main", password: String? = nil,
        plainText: GitPlainCodec? = nil, expectedMode: GitLibraryMode? = nil
    ) throws -> GitSyncTransport {
        GitSyncTransport(
            configuration: .init(
                remote: try remote(branch: branch, password: password),
                cacheDirectory: cacheDirectory(name), plainText: plainText, expectedMode: expectedMode),
            session: session)
    }

    func cacheDirectory(_ name: String) -> URL {
        root.appending(path: "cache-\(name)", directoryHint: .isDirectory)
    }

    func beforeNextReceivePack(_ hook: @escaping () throws -> Void) {
        GitHTTPBackendProtocol.update(host: host) { $0.beforeNextReceivePack = hook }
    }

    var requests: [String] { GitHTTPBackendProtocol.requests(host: host) }

    /// Clones the branch, lets `body` edit the working tree, then commits and pushes.
    func commitAsAnotherWriter(
        branch: String = "main", message: String = "external edit",
        force: Bool = false, _ body: (URL) throws -> Void
    ) throws {
        let work = root.appending(path: "work-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        try git(["clone", "--quiet", "--branch", branch, bare.path, work.path])
        try body(work)
        try git(["-C", work.path, "add", "-A"])
        try git(["-C", work.path, "commit", "--quiet", "-m", message])
        try git(["-C", work.path, "push", "--quiet"] + (force ? ["--force"] : [])
                + ["origin", "HEAD:refs/heads/\(branch)"])
    }

    @discardableResult
    func git(_ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Other", "-c", "user.email=other@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.environment = Self.isolatedEnvironment(home: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.commandFailed(arguments.joined(separator: " ") + ": " + text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isolatedEnvironment(home: URL) -> [String: String] {
        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developer
        }
        return environment
    }
}

enum GitFixtureError: Error, CustomStringConvertible {
    case commandFailed(String)
    var description: String {
        switch self { case .commandFailed(let detail): detail }
    }
}

// MARK: - SSH

extension GitFixture {
    /// A stand-in `ssh` that runs the remote command locally in the fixture root, so
    /// `git@host:repo.git` reaches `bare`. It logs its arguments, and fails like ssh
    /// when `ssh-fail` exists (stderr text, then the exit status on the first line).
    func fakeSSH() throws -> URL {
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let script = bin.appending(path: "ssh")
        guard !FileManager.default.fileExists(atPath: script.path) else { return script }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")/.." || exit 255
        printf '%s\\n' "$*" >> ssh.log
        if [ -f ssh-fail ]; then
          status=$(head -n 1 ssh-fail)
          tail -n +2 ssh-fail >&2
          exit "$status"
        fi
        if [ -f ssh-linger ]; then
          # Like a ControlPersist master: a background child that keeps stderr open.
          sleep 8 </dev/null >/dev/null &
        fi
        for last; do :; done
        export HOME="$PWD" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        exec /bin/sh -c "$last"

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func sshRemote(branch: String = "main") throws -> GitRemote {
        try GitRemote(
            ssh: GitSSHLocation(user: "git", host: "ssh.fixture.invalid", port: nil, path: "repo.git", scpStyle: true),
            branch: branch)
    }

    func sshTransport(_ name: String = UUID().uuidString, branch: String = "main") throws -> GitSyncTransport {
        var connector = GitSystemSSHConnector()
        connector.executable = try fakeSSH()
        return GitSyncTransport(configuration: .init(
            remote: try sshRemote(branch: branch), cacheDirectory: cacheDirectory(name),
            sshConnector: connector))
    }

    func failSSH(status: Int32, stderr: String) throws {
        try Data("\(status)\n\(stderr)\n".utf8).write(to: root.appending(path: "ssh-fail"))
    }

    func clearSSHFailure() {
        try? FileManager.default.removeItem(at: root.appending(path: "ssh-fail"))
    }

    var sshInvocations: [String] {
        (try? String(contentsOf: root.appending(path: "ssh.log"), encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
    }
}

/// A real, unprivileged `sshd` on loopback serving the current user's files, with a
/// private ssh-agent holding the only client key. The client is pinned to a private
/// configuration (`-F`), `known_hosts` and agent socket: the user's own keys, agent and
/// configuration are never read or changed.
final class GitSSHServer: @unchecked Sendable {
    let directory: URL
    let port: Int
    let agentSocket: String
    let clientConfig: URL
    let knownHosts: URL
    private let sshd: Process
    private let agent: Process

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-agent")
    }

    init(in root: URL) throws {
        directory = root.appending(path: "sshd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.path
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "host", "-f", "\(path)/host_key"])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "client", "-f", "\(path)/client_key"])
        let clientPublic = try String(contentsOfFile: "\(path)/client_key.pub", encoding: .utf8)
        try Data("restrict \(clientPublic)".utf8).write(to: directory.appending(path: "authorized_keys"))
        port = try Self.freePort()

        // Unix socket paths are limited to about 104 bytes; temporaryDirectory is too deep.
        let socketPath = "/tmp/snx-\(UUID().uuidString.prefix(8)).sock"
        agentSocket = socketPath
        agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", agentSocket]
        agent.environment = ["PATH": "/usr/bin:/bin"]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        try Self.wait("agent") { FileManager.default.fileExists(atPath: socketPath) }
        // Explicit socket and no inherited environment: this can only reach our agent.
        try Self.run("/usr/bin/ssh-add", ["-q", "\(path)/client_key"], environment: ["SSH_AUTH_SOCK": agentSocket])
        let listed = try Self.run("/usr/bin/ssh-add", ["-l"], environment: ["SSH_AUTH_SOCK": agentSocket])
        guard listed.split(separator: "\n").count == 1 else { throw GitFixtureError.commandFailed("agent keys") }
        // From here on only the agent holds the private key.
        try FileManager.default.removeItem(atPath: "\(path)/client_key")

        try Data("""
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(path)/host_key
        PidFile \(path)/sshd.pid
        AuthorizedKeysFile \(path)/authorized_keys
        AllowUsers \(NSUserName())
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        LogLevel ERROR

        """.utf8).write(to: directory.appending(path: "sshd_config"))
        sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-e", "-f", "\(path)/sshd_config"]
        FileManager.default.createFile(atPath: "\(path)/sshd.log", contents: nil)
        sshd.standardError = try FileHandle(forWritingTo: directory.appending(path: "sshd.log"))
        sshd.standardOutput = FileHandle.nullDevice
        try sshd.run()
        let listening = port
        try Self.wait("sshd") { Self.accepts(port: listening) }

        let hostPublic = try String(contentsOfFile: "\(path)/host_key.pub", encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        knownHosts = directory.appending(path: "known_hosts")
        try Data("[127.0.0.1]:\(port) \(hostPublic)\n".utf8).write(to: knownHosts)
        clientConfig = directory.appending(path: "ssh_config")
        try Data("""
        Host *
          UserKnownHostsFile \(knownHosts.path)
          GlobalKnownHostsFile /dev/null
          StrictHostKeyChecking yes
          UpdateHostKeys no
          IdentitiesOnly yes
          IdentityFile \(path)/client_key.pub
          IdentityAgent \(agentSocket)

        """.utf8).write(to: clientConfig)
    }

    deinit {
        if sshd.isRunning { sshd.terminate() }
        if agent.isRunning { agent.terminate() }
        try? FileManager.default.removeItem(atPath: agentSocket)
    }

    var connector: GitSystemSSHConnector {
        // Not shared by default: these tests change trust between connections.
        GitSystemSSHConnector(options: ["-F", clientConfig.path], agentSocket: agentSocket, timeout: 60,
                              sharesConnections: false)
    }

    func location(of repository: URL) throws -> GitSSHLocation {
        try GitSSHLocation(user: NSUserName(), host: "127.0.0.1", port: port, path: repository.path, scpStyle: false)
    }

    /// Replaces the trusted host key with an unrelated one.
    func distrustHostKey() throws {
        let other = directory.appending(path: "other_host_key")
        try? FileManager.default.removeItem(at: other)
        try? FileManager.default.removeItem(atPath: other.path + ".pub")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", other.path])
        let key = try String(contentsOfFile: other.path + ".pub", encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        try Data("[127.0.0.1]:\(port) \(key)\n".utf8).write(to: knownHosts)
    }

    func forgetHostKey() throws { try Data().write(to: knownHosts) }

    func removeAgentKeys() throws {
        try Self.run("/usr/bin/ssh-add", ["-D"], environment: ["SSH_AUTH_SOCK": agentSocket])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.commandFailed("\(tool): \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func wait(_ what: String, until ready: () -> Bool) throws {
        for _ in 0..<100 {
            if ready() { return }
            usleep(50_000)
        }
        throw GitFixtureError.commandFailed("\(what) did not start")
    }

    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw GitFixtureError.commandFailed("socket") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw GitFixtureError.commandFailed("bind") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func accepts(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
