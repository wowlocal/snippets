import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// SSH for iOS, which has no ssh client or agent: SwiftNIO SSH, authenticated with this
/// device's own key, accepting only host keys the user confirmed.
///
/// One authenticated connection per host is kept open for a while and each git
/// exchange runs on its own exec channel over it, so a poll does not pay a full SSH
/// handshake. Everything that touches a connection runs on its event loop. Nothing a
/// server sends is logged; failures leave as closed `GitRemoteFailure` codes.
nonisolated final class GitNIOSSHConnector: GitSSHConnector, @unchecked Sendable {
    let identity: GitSSHDeviceIdentity
    /// Fails an exchange that makes no progress (nothing read, no send window opened)
    /// for this long; a slow but moving transfer is never cut off.
    private let idleTimeout: TimeAmount
    /// How long an unused connection stays open: a little longer than the 60-second poll.
    private let keepAlive: TimeAmount
    private let lock = NSLock()
    private var connections: [String: Task<SharedSSHConnection, any Error>] = [:]
    /// What each key's task resolved to, so an old connection closing late never
    /// removes its replacement.
    private var resolved: [String: SharedSSHConnection] = [:]

    init(identity: GitSSHDeviceIdentity, timeout: TimeAmount = .seconds(120), keepAlive: TimeAmount = .seconds(90)) {
        self.identity = identity
        idleTimeout = timeout
        self.keepAlive = keepAlive
    }

    /// Connections currently open, for tests.
    var openConnectionCount: Int { lock.withLock { connections.count } }

    func exchange(
        command: String, location: GitSSHLocation, maximumBytes: Int,
        request: @escaping @Sendable ([UInt8]) throws -> Data?
    ) async throws -> GitSSHExchange {
        try Task.checkCancellation()
        // Keyed by everything that decides who we are to whom.
        let key = "\(location.user ?? "git")@\(GitSSHHostKeyStore.hostID(location))"
        for attempt in 0..<2 {
            let connection = try await connection(for: location, key: key)
            do {
                return try await connection.run(
                    command: command, maximumBytes: maximumBytes, request: request, idleTimeout: idleTimeout)
            } catch SharedSSHConnection.Unusable.closed where attempt == 0 {
                // It closed before the exec channel opened, so nothing was sent: safe to
                // try once more on a fresh connection.
                forget(key, connection)
            } catch SharedSSHConnection.Unusable.closed {
                throw GitRemoteFailure.unreachable("ssh_connection")
            }
        }
        throw GitRemoteFailure.unreachable("ssh_connection")
    }

    /// Closes every shared connection now.
    func closeAll() {
        let tasks = lock.withLock {
            defer {
                connections.removeAll()
                resolved.removeAll()
            }
            return Array(connections.values)
        }
        for task in tasks {
            Task { (try? await task.value)?.close() }
        }
    }

    private func connection(for location: GitSSHLocation, key: String) async throws -> SharedSSHConnection {
        for _ in 0..<2 {
            // Concurrent exchanges wait for one connection attempt instead of racing.
            let task: Task<SharedSSHConnection, any Error> = lock.withLock {
                if let existing = connections[key] { return existing }
                let created = Task { [identity, keepAlive] in
                    try await SharedSSHConnection.open(location: location, identity: identity, keepAlive: keepAlive)
                }
                connections[key] = created
                resolved[key] = nil
                return created
            }
            let connection: SharedSSHConnection
            do {
                connection = try await task.value
            } catch {
                lock.withLock {
                    if connections[key] == task {
                        connections[key] = nil
                        resolved[key] = nil
                    }
                }
                throw error
            }
            let current = lock.withLock {
                guard connections[key] == task else { return false }
                resolved[key] = connection
                return true
            }
            if connection.isUsable {
                if current { connection.onClose { [weak self] in self?.forget(key, connection) } }
                return connection
            }
            forget(key, connection)
        }
        throw GitRemoteFailure.unreachable("ssh_connection")
    }

    private func forget(_ key: String, _ connection: SharedSSHConnection) {
        lock.withLock {
            if resolved[key] === connection {
                connections[key] = nil
                resolved[key] = nil
            }
        }
        connection.close()
    }
}

/// One authenticated SSH connection that git exchanges share, one exec channel each.
private final class SharedSSHConnection: @unchecked Sendable {
    enum Unusable: Error { case closed }

    let channel: Channel
    private let state: ConnectionState
    private let keepAlive: TimeAmount
    /// Event-loop confined.
    private var running = 0
    private var idleClose: Scheduled<Void>?
    private var closeObserved = false
    /// Set when an exchange on this connection stalled or a channel could not open: no
    /// new exchange starts on it, and it closes once the running ones end.
    private let retiredLock = NSLock()
    private var retiredFlag = false

    private init(channel: Channel, state: ConnectionState, keepAlive: TimeAmount) {
        self.channel = channel
        self.state = state
        self.keepAlive = keepAlive
    }

    var isUsable: Bool { channel.isActive && !retiredLock.withLock { retiredFlag } }

    private func retire() {
        retiredLock.withLock { retiredFlag = true }
        channel.eventLoop.execute { [self] in if running == 0 { channel.close(promise: nil) } }
    }

    static func open(
        location: GitSSHLocation, identity: GitSSHDeviceIdentity, keepAlive: TimeAmount
    ) async throws -> SharedSSHConnection {
        let privateKey: NIOSSHPrivateKey
        do {
            switch try identity.signingKey() {
            case .secureEnclave(let key): privateKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
            case .software(let key): privateKey = NIOSSHPrivateKey(p256Key: key)
            }
        } catch {
            throw GitRemoteFailure.unreachable("ssh_device_key_unavailable")
        }
        let state = ConnectionState()
        let hostCheck = HostKeyCheck(
            store: identity.hostKeys, hostID: GitSSHHostKeyStore.hostID(location), state: state)
        let authentication = DeviceKeyAuthentication(
            username: location.user ?? "git", key: privateKey, state: state)
        let authenticated = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: authenticated.futureResult.eventLoop)
            .connectTimeout(.seconds(20))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: hostCheck)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(
                        HandshakeWatcher(state: state, authenticated: authenticated))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: location.host, port: location.port ?? 22).get()
        } catch {
            throw GitRemoteFailure.unreachable("ssh_connection")
        }
        // Not shared until the host key and the device key were both accepted; a refusal
        // closes the connection with the reason in `state`.
        channel.closeFuture.whenComplete { _ in
            authenticated.fail(state.failure ?? GitRemoteFailure.unreachable("ssh_connection"))
        }
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(30)) {
            authenticated.fail(GitRemoteFailure.unreachable("ssh_timeout"))
            channel.close(promise: nil)
        }
        do {
            try await authenticated.futureResult.get()
            timeout.cancel()
        } catch {
            timeout.cancel()
            channel.close(promise: nil)
            throw error
        }
        let connection = SharedSSHConnection(channel: channel, state: state, keepAlive: keepAlive)
        channel.eventLoop.execute { connection.scheduleIdleClose() }
        return connection
    }

    func onClose(_ action: @escaping @Sendable () -> Void) {
        channel.eventLoop.execute { [self] in
            guard !closeObserved else { return }
            closeObserved = true
            channel.closeFuture.whenComplete { _ in action() }
        }
    }

    /// Closes now if idle, otherwise as soon as the running exchanges end.
    func close() { retire() }

    /// Runs one git service on a new exec channel.
    func run(
        command: String, maximumBytes: Int, request: @escaping @Sendable ([UInt8]) throws -> Data?,
        idleTimeout: TimeAmount
    ) async throws -> GitSSHExchange {
        let channel = self.channel
        let completion = channel.eventLoop.makePromise(of: GitSSHExchange.self)
        let once = Once(completion)
        let activity = Activity(channel.eventLoop)
        let exec = GitExecHandler(
            command: command, maximumBytes: maximumBytes, request: request, finish: once, activity: activity,
            connectionFailure: { [state] in state.failure })
        let child = ChildBox()
        let timeoutTask = channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5)) {
            [self] _ in
            if NIODeadline.now() - activity.last > idleTimeout {
                once.fail(GitRemoteFailure.unreachable("ssh_timeout"))
                // Only this exchange's channel; others on the connection finish, and a
                // possibly wedged connection takes no new ones.
                child.channel?.close(promise: nil)
                retire()
            }
        }
        // A connection that went silently dead (network change, suspension) never
        // answers the channel open. Nothing has been sent yet, so it is safe to give up
        // quickly and retry on a fresh connection.
        let openDeadline = channel.eventLoop.scheduleTask(in: .seconds(15)) { [self] in
            if child.channel == nil {
                once.fail(Unusable.closed)
                retire()
            }
        }
        channel.eventLoop.execute { [self] in
            begin()
            guard channel.isActive else {
                once.fail(Unusable.closed)
                return
            }
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let opened = channel.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(opened, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(GitRemoteFailure.protocolViolation("ssh_channel"))
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(exec)
                    }
                }
                opened.futureResult.whenComplete { [self] result in
                    openDeadline.cancel()
                    switch result {
                    case .success(let opened):
                        child.channel = opened
                        // Cancelled while it opened: do not start the service.
                        if once.isDone { opened.close(promise: nil) }
                    case .failure:
                        // Refused before anything was sent: retry once on a fresh
                        // connection, and keep this one from taking new exchanges.
                        once.fail(Unusable.closed)
                        retire()
                    }
                }
            } catch {
                once.fail(Unusable.closed)
            }
        }
        defer {
            timeoutTask.cancel()
            openDeadline.cancel()
            channel.eventLoop.execute { [self] in end() }
        }
        return try await withTaskCancellationHandler {
            try await completion.futureResult.get()
        } onCancel: {
            once.fail(CancellationError())
            channel.eventLoop.execute { child.channel?.close(promise: nil) }
        }
    }

    private func begin() {
        running += 1
        idleClose?.cancel()
        idleClose = nil
    }

    private func end() {
        running -= 1
        guard running == 0 else { return }
        if retiredLock.withLock({ retiredFlag }) {
            channel.close(promise: nil)
        } else {
            scheduleIdleClose()
        }
    }

    private func scheduleIdleClose() {
        idleClose?.cancel()
        idleClose = channel.eventLoop.scheduleTask(in: keepAlive) { [self] in
            if running == 0 { channel.close(promise: nil) }
        }
    }
}

/// The exec channel, once open; used only on its event loop.
private final class ChildBox: @unchecked Sendable {
    var channel: Channel?
}

/// Completes a promise at most once; used only on its event loop.
private final class Once: @unchecked Sendable {
    private let promise: EventLoopPromise<GitSSHExchange>
    private var done = false

    init(_ promise: EventLoopPromise<GitSSHExchange>) { self.promise = promise }

    /// Whether the exchange already ended (finished, failed or cancelled). Event loop only.
    var isDone: Bool { done }

    func succeed(_ value: GitSSHExchange) {
        promise.futureResult.eventLoop.execute { [self] in
            guard !done else { return }
            done = true
            promise.succeed(value)
        }
    }

    func fail(_ error: any Error) {
        promise.futureResult.eventLoop.execute { [self] in
            guard !done else { return }
            done = true
            promise.fail(error)
        }
    }
}

/// When the exchange last made progress; read and written only on its event loop.
private final class Activity: @unchecked Sendable {
    private(set) var last = NIODeadline.now()
    private let eventLoop: EventLoop

    init(_ eventLoop: EventLoop) { self.eventLoop = eventLoop }

    func touch() {
        eventLoop.assertInEventLoop()
        last = .now()
    }
}

/// What the handshake learned, for classifying a dropped connection.
private final class ConnectionState: @unchecked Sendable {
    var failure: GitRemoteFailure?
}

private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private struct Rejected: Error {}
    private let store: GitSSHHostKeyStore
    private let hostID: String
    private let state: ConnectionState

    init(store: GitSSHHostKeyStore, hostID: String, state: ConnectionState) {
        self.store = store
        self.hostID = hostID
        self.state = state
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch store.check(hostID: hostID, openSSHKey: String(openSSHPublicKey: hostKey)) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .unknown:
            state.failure = .sshHostKeyUnknown
            validationCompletePromise.fail(Rejected())
        case .changed:
            state.failure = .sshHostKeyChanged
            validationCompletePromise.fail(Rejected())
        }
    }
}

private final class DeviceKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let state: ConnectionState
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey, state: ConnectionState) {
        self.username = username
        self.key = key
        self.state = state
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            // The one key this device has was refused (or keys are not accepted at all).
            // Failing, not answering nil, ends the connection now: NIOSSH would otherwise
            // wait for the server's login grace time.
            state.failure = .sshPermissionDenied
            nextChallengePromise.fail(GitRemoteFailure.sshPermissionDenied)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Reports when user authentication succeeded, and closes the connection on any error.
private final class HandshakeWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let state: ConnectionState
    private let authenticated: EventLoopPromise<Void>

    init(state: ConnectionState, authenticated: EventLoopPromise<Void>) {
        self.state = state
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if state.failure == nil, error is NIOSSHError {
            state.failure = .unsupportedServer("ssh_handshake")
        }
        context.close(promise: nil)
    }
}

/// One git service on one exec channel: read the advertisement, answer it, read the rest.
private final class GitExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let maximumBytes: Int
    private var request: (@Sendable ([UInt8]) throws -> Data?)?
    private let finish: Once
    private let activity: Activity
    /// Why the shared connection closed, if it did: a child channel that ends because its
    /// connection died reports that instead of a remote failure.
    private let connectionFailure: () -> GitRemoteFailure?
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    private var advertisementEnd: Int?
    private var exitStatus: Int?
    private var failure: (any Error)?

    init(
        command: String, maximumBytes: Int, request: @escaping @Sendable ([UInt8]) throws -> Data?,
        finish: Once, activity: Activity, connectionFailure: @escaping () -> GitRemoteFailure?
    ) {
        self.command = command
        self.maximumBytes = maximumBytes
        self.request = request
        self.finish = finish
        self.activity = activity
        self.connectionFailure = connectionFailure
    }

    /// The send window opening again means the peer consumed what was written.
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        activity.touch()
        context.fireChannelWritabilityChanged()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [finish] _ in
            finish.fail(GitRemoteFailure.unreachable("ssh_channel"))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Cancelled (or timed out) before the channel opened: nothing may be sent.
        guard !finish.isDone else {
            context.close(promise: nil)
            return
        }
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec).whenFailure { [finish] _ in
            finish.fail(GitRemoteFailure.unsupportedServer("ssh_exec"))
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        case is ChannelFailureEvent:
            fail(context, GitRemoteFailure.unsupportedServer("ssh_exec"))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        activity.touch()
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = buffer.readableBytesView
        switch message.type {
        case .channel:
            stdout.append(contentsOf: bytes)
            if stdout.count > maximumBytes + GitSmartHTTPClient.maximumAdvertisementBytes {
                fail(context, GitRemoteFailure.responseTooLarge)
                return
            }
            answerAdvertisementIfComplete(context)
        case .stdErr:
            if stderr.count < 65_536 { stderr.append(contentsOf: bytes.prefix(65_536 - stderr.count)) }
        default:
            break
        }
    }

    private func answerAdvertisementIfComplete(_ context: ChannelHandlerContext) {
        guard advertisementEnd == nil else { return }
        let body: Data
        do {
            guard let end = try GitPktLine.advertisementEnd(in: stdout) else {
                if stdout.count > GitSmartHTTPClient.maximumAdvertisementBytes {
                    fail(context, GitRemoteFailure.responseTooLarge)
                }
                return
            }
            advertisementEnd = end
            let respond = request
            request = nil
            body = try respond?(Array(stdout[..<end])) ?? GitPktLine.flush
        } catch {
            failure = error
            advertisementEnd = advertisementEnd ?? stdout.count
            body = GitPktLine.flush
        }
        guard !finish.isDone else {
            context.close(promise: nil)
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        // End of input: the service then answers and exits.
        context.close(mode: .output, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        request = nil
        if let failure {
            finish.fail(failure)
        } else if let end = advertisementEnd, exitStatus ?? 0 == 0 {
            var output = stdout
            stdout = []
            let advertisement = Array(output[..<end])
            output.removeFirst(end)
            finish.succeed(GitSSHExchange(advertisement: advertisement, response: output))
        } else if exitStatus == nil, stderr.isEmpty {
            // No exit status and nothing said: the connection went away under us.
            finish.fail(connectionFailure() ?? GitRemoteFailure.unreachable("ssh_connection"))
        } else {
            finish.fail(GitSSHDiagnosis.failure(stderr: stderr, exitStatus: Int32(clamping: exitStatus ?? 1)))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(context, GitRemoteFailure.unreachable("ssh_channel"))
    }

    private func fail(_ context: ChannelHandlerContext, _ error: any Error) {
        if failure == nil { failure = error }
        context.close(promise: nil)
    }
}
