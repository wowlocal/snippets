import AppKit
import Darwin
import QuartzCore
import Security

/// The CLI consent prompt is intentionally not an `NSAlert`. On macOS 26 an alert with
/// a long, security-relevant caller path is reformatted into an oversized title, clipped
/// copy, and empty-looking button rows. A small owned window gives each piece of identity
/// a stable place while retaining normal keyboard and VoiceOver behaviour.
private final class RevealConsentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the shape the window server cannot: a persistent rounded rim and a rounded
/// shadow around a transparent, borderless window. The inactive state is deliberately
/// a little more opaque and more strongly outlined so the prompt stays distinct from a
/// dark terminal after the user clicks away from it.
private final class RevealConsentChromeView: NSView {
    private let chromeCornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        chromeCornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateChanged),
                name: NSWindow.didResignKeyNotification,
                object: window)
        }
        updateChrome()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: chromeCornerRadius,
            cornerHeight: chromeCornerRadius,
            transform: nil)
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        updateChrome()
    }

    private func updateChrome() {
        guard let layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isInactive = window?.isKeyWindow == false

        if isDark {
            layer.backgroundColor = NSColor(
                white: 0.08, alpha: isInactive ? 0.72 : 0.52).cgColor
            layer.borderColor = NSColor(
                white: 1, alpha: isInactive ? 0.28 : 0.20).cgColor
        } else {
            layer.backgroundColor = NSColor(
                white: 1, alpha: isInactive ? 0.78 : 0.62).cgColor
            layer.borderColor = NSColor(
                white: 0, alpha: isInactive ? 0.24 : 0.16).cgColor
        }

        layer.shadowOpacity = isInactive ? 0.46 : 0.36
        layer.shadowRadius = 14
        layer.shadowOffset = NSSize(width: 0, height: -4)
    }
}

/// Answers `snippets-cli` over a local socket, and brokers access to secrets.
///
/// The CLI cannot decrypt anything: the vault key is only ever in this process. So
/// `reveal` is a *request*, and what satisfies it is a human clicking Reveal in a prompt
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
final class ControlServer: NSObject {

    private let session: VaultSession
    private let secureStore: SecureSnippetStore
    private let socketURL: URL
    private let auditURL: URL

    private var listenerDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.khm.snippets.ipc.accept", qos: .userInitiated)
    /// A stalled or slow client must occupy only its own worker, never the serial queue
    /// which accepts every other CLI connection.
    nonisolated private static let connectionQueue = DispatchQueue(
        label: "com.khm.snippets.ipc.connections",
        qos: .userInitiated,
        attributes: .concurrent)

    /// At most this many reveal prompts per window, across all callers.
    ///
    /// A script that loops is the case this defends against: without a ceiling it could
    /// raise prompts faster than they can be read, and the tenth identical dialog gets
    /// approved by reflex. Refusing outright is better than training that reflex.
    private static let revealBudget = 5
    private static let revealWindow: TimeInterval = 60
    private var recentReveals: [Date] = []

    private enum RevealConsent {
        case approved
        case denied
        case timedOut
    }

    private struct ActiveRevealPrompt {
        let window: NSWindow
        let continuation: CheckedContinuation<RevealConsent, Never>
        var timeoutTask: Task<Void, Never>?
    }

    /// Covers both our consent panel and the subsequent system authentication. This
    /// prevents a second reveal from putting another prompt on top of either one while
    /// still allowing ping and status to be served through actor reentrancy.
    private var revealInFlight = false
    private var activeRevealPrompt: ActiveRevealPrompt?

    init(session: VaultSession, secureStore: SecureSnippetStore,
         socketURL: URL = SnippetsIPC.socketURL(), auditURL: URL = SnippetStorageLocations.vaultAuditFileURL) {
        self.session = session
        self.secureStore = secureStore
        self.socketURL = socketURL
        self.auditURL = auditURL
        super.init()
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

        let listener = listenerDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            Self.connectionQueue.async { [weak self] in
                guard let self else {
                    close(descriptor)
                    return
                }
                self.serve(descriptor)
            }
        }
        source.setCancelHandler { [socketURL] in
            unlink(socketURL.path)
        }
        acceptSource = source
        source.resume()
    }

    func stop() {
        if activeRevealPrompt != nil {
            finishRevealPrompt(with: .denied)
        }
        acceptSource?.cancel()
        acceptSource = nil
        if listenerDescriptor >= 0 {
            close(listenerDescriptor)
            listenerDescriptor = -1
        }
        unlink(socketURL.path)
    }

    // MARK: - Serving

    /// Runs on the concurrent connection pool; hops to the main actor only to touch app
    /// state or show UI. In particular, waiting for consent never occupies the serial
    /// accept queue, so a second client can still ask for `ping` or `status`.
    nonisolated private func serve(_ descriptor: Int32) {
        let peer = PeerIdentity(descriptor: descriptor)
        guard peer.isTrusted else {
            // Deliberately terse. Telling an unverified caller *why* it failed helps it
            // iterate towards passing.
            Self.respond(
                .failure(.refused, "unrecognised caller"), on: descriptor)
            return
        }

        guard let request = try? UnixSocket.receive(SnippetsIPC.Request.self, on: descriptor) else {
            Self.respond(.failure(.error, "malformed request"), on: descriptor)
            return
        }

        guard request.v == SnippetsIPC.protocolVersion else {
            Self.respond(
                .failure(
                    .unsupported,
                    "this Snippets speaks protocol \(SnippetsIPC.protocolVersion), the CLI speaks \(request.v)"
                        + " — reinstall the CLI from Settings"),
                on: descriptor)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                Self.respond(.failure(.error, "Snippets is shutting down"), on: descriptor)
                return
            }
            let response = await self.handle(request, from: peer)
            Self.respond(response, on: descriptor)
        }
    }

    /// Sends off the main actor and owns the descriptor's one and only close.
    nonisolated private static func respond(
        _ response: SnippetsIPC.Response, on descriptor: Int32
    ) {
        connectionQueue.async {
            defer { close(descriptor) }
            try? UnixSocket.send(response, on: descriptor)
        }
    }

    private func handle(
        _ request: SnippetsIPC.Request, from peer: PeerIdentity
    ) async -> SnippetsIPC.Response {
        switch request.command {
        case SnippetsIPC.Command.ping:
            return SnippetsIPC.Response(status: .ok)

        case SnippetsIPC.Command.status:
            return SnippetsIPC.Response(
                status: .ok,
                secureCount: secureStore.count,
                unlocked: session.state.isUnlocked)

        case SnippetsIPC.Command.reveal:
            return await reveal(
                keyword: request.keyword ?? "",
                invocation: request.invocation,
                peer: peer)

        default:
            return .failure(.unsupported, "unknown command \"\(request.command)\"")
        }
    }

    // MARK: - Reveal

    private func reveal(
        keyword: String,
        invocation: String?,
        peer: PeerIdentity
    ) async -> SnippetsIPC.Response {
        let lookup = Snippet.sanitizedKeyword(keyword)
        guard !lookup.isEmpty else { return .failure(.notFound, "no keyword given") }

        let key = SnippetTagging.filterKey(for: lookup)
        guard let shell = secureStore.shells.first(where: {
            SnippetTagging.filterKey(for: $0.normalizedKeyword) == key
        }) else {
            return .failure(.notFound, "no secure snippet with keyword '\(keyword)'")
        }

        guard !revealInFlight else {
            record(audit: "busy", keyword: lookup, peer: peer)
            return .failure(
                .refused,
                "another reveal request is already awaiting approval; approve or deny it in Snippets")
        }

        guard allowanceRemains() else {
            record(audit: "rate-limited", keyword: lookup, peer: peer)
            return .failure(
                .refused,
                "too many reveal requests in the last minute; approve them one at a time from the app")
        }

        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        revealInFlight = true
        defer {
            revealInFlight = false
            restoreForegroundApplication(previouslyFrontmostApplication)
        }

        switch await confirm(shell: shell, invocation: invocation, peer: peer) {
        case .denied:
            record(audit: "denied", keyword: lookup, peer: peer)
            return .failure(.denied, "the request was not approved")
        case .timedOut:
            record(audit: "timed-out", keyword: lookup, peer: peer)
            return .failure(
                .denied,
                "the request was not approved within \(Int(SnippetsIPC.revealConsentTimeout)) seconds")
        case .approved:
            break
        }

        do {
            // `withOneUseAuthentication`, not `unlock`: otherwise a reveal arriving while
            // an in-app window happens to be open would be satisfied by the consent click
            // alone, and the person at the keyboard would never be asked to prove they
            // are there. The side effect is deliberate — a remote reveal ends any in-app
            // unlock window, because the requester is provably not the person typing.
            let content = try await session.withOneUseAuthentication(
                reason: "Reveal “\(shell.displayName)” for \(peer.applicationName)"
            ) { try secureStore.content(for: shell.id) }
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

    /// Once consent/authentication is over, return focus to the application the user
    /// invoked the CLI from. Do not steal it back if they deliberately switched to some
    /// third application while the prompt was waiting.
    private func restoreForegroundApplication(_ application: NSRunningApplication?) {
        guard NSApp.isActive,
              let application,
              !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        _ = application.activate()
    }

    /// A modeless consent window which names the caller. `runModal` is forbidden here:
    /// it would occupy the app's only server queue until somebody clicked, wedging even
    /// unrelated `ping` and `status` requests. The continuation suspends only this
    /// reveal task, and the bounded timer turns silence into the documented denial.
    private func confirm(
        shell: Snippet,
        invocation: String?,
        peer: PeerIdentity
    ) async -> RevealConsent {
        return await withCheckedContinuation { continuation in
            let window = makeRevealConsentWindow(
                shell: shell, invocation: invocation, peer: peer)

            activeRevealPrompt = ActiveRevealPrompt(
                window: window, continuation: continuation, timeoutTask: nil)
            activeRevealPrompt?.timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(
                        for: .seconds(SnippetsIPC.revealConsentTimeout))
                } catch {
                    return
                }
                self?.finishRevealPrompt(with: .timedOut)
            }

            window.center()
            // Make the prompt visible before activating Snippets. AppKit's reopen
            // callback otherwise observes zero visible windows and opens the main
            // library window; once this window is already ordered, activation raises
            // only the consent UI.
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
    }

    private func makeRevealConsentWindow(
        shell: Snippet,
        invocation: String?,
        peer: PeerIdentity
    ) -> NSWindow {
        let surfaceSize = NSSize(width: 480, height: 320)
        let shadowInset: CGFloat = 18
        let windowSize = NSSize(
            width: surfaceSize.width + shadowInset * 2,
            height: surfaceSize.height + shadowInset * 2)
        let window = RevealConsentWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        window.title = "Reveal secure snippet?"
        window.level = .modalPanel
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        // The window server shadows the rectangular backing window, not the rounded
        // glass surface. That leaves a visible square outline at the corners whenever
        // this window is key; the glass surface supplies its own rim, so disable it.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow

        let title = makePromptLabel(
            "Reveal secure snippet?", font: .systemFont(ofSize: 20, weight: .semibold))
        let subtitle = makePromptLabel(
            "Requested by \(peer.applicationName)",
            font: .systemFont(ofSize: 13, weight: .regular),
            color: .secondaryLabelColor)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.toolTip = peer.displayName

        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        let shield = NSImageView(image: LiquidGlassDesign.symbol(
            "lock.shield.fill", pointSize: 27, weight: .medium) ?? NSImage())
        shield.translatesAutoresizingMaskIntoConstraints = false
        shield.contentTintColor = .systemOrange
        shield.setAccessibilityElement(false)

        let header = NSStackView(views: [shield, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 13
        NSLayoutConstraint.activate([
            shield.widthAnchor.constraint(equalToConstant: 38),
            shield.heightAnchor.constraint(equalToConstant: 38)
        ])

        let snippetCard = NSView()
        snippetCard.translatesAutoresizingMaskIntoConstraints = false
        LiquidGlassDesign.configureRoundedLayer(
            snippetCard,
            cornerRadius: LiquidGlassDesign.Metrics.contentCornerRadius,
            borderColor: NSColor.separatorColor.withAlphaComponent(0.18),
            backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.52))

        let cardCaption = makePromptLabel(
            "SECURE SNIPPET", font: .systemFont(ofSize: 10, weight: .semibold),
            color: .secondaryLabelColor)
        let snippetName = makePromptLabel(
            shell.displayName, font: .systemFont(ofSize: 14, weight: .medium))
        snippetName.lineBreakMode = .byTruncatingTail
        snippetName.toolTip = shell.displayName

        let safeInvocation = promptSingleLine(
            invocation, fallback: "snippets-cli reveal \(shell.normalizedKeyword)")
        let command = makePromptLabel(
            safeInvocation,
            font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
            color: .secondaryLabelColor)
        command.lineBreakMode = .byTruncatingMiddle
        command.toolTip = safeInvocation

        let snippetText = NSStackView(views: [cardCaption, snippetName, command])
        snippetText.translatesAutoresizingMaskIntoConstraints = false
        snippetText.orientation = .vertical
        snippetText.alignment = .leading
        snippetText.spacing = 3
        snippetCard.addSubview(snippetText)
        NSLayoutConstraint.activate([
            snippetText.leadingAnchor.constraint(equalTo: snippetCard.leadingAnchor, constant: 14),
            snippetText.trailingAnchor.constraint(equalTo: snippetCard.trailingAnchor, constant: -14),
            snippetText.centerYAnchor.constraint(equalTo: snippetCard.centerYAnchor),
            snippetCard.heightAnchor.constraint(equalToConstant: 76)
        ])

        let callerIcon: NSImage
        if let path = peer.applicationPath {
            callerIcon = NSWorkspace.shared.icon(forFile: path)
        } else {
            callerIcon = LiquidGlassDesign.symbol(
                "terminal", pointSize: 18, weight: .regular) ?? NSImage()
        }
        let callerImage = NSImageView(image: callerIcon)
        callerImage.translatesAutoresizingMaskIntoConstraints = false
        callerImage.imageScaling = .scaleProportionallyUpOrDown
        callerImage.setAccessibilityElement(false)

        let callerCaption = makePromptLabel(
            "CALLER", font: .systemFont(ofSize: 10, weight: .semibold),
            color: .secondaryLabelColor)
        let callerPath = promptSingleLine(
            peer.applicationPath, fallback: "Process \(peer.pid)")
        let callerLocation = makePromptLabel(
            callerPath, font: .systemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor)
        callerLocation.lineBreakMode = .byTruncatingMiddle
        callerLocation.toolTip = callerPath
        let callerText = NSStackView(views: [callerCaption, callerLocation])
        callerText.orientation = .vertical
        callerText.alignment = .leading
        callerText.spacing = 2

        let caller = NSStackView(views: [callerImage, callerText])
        caller.orientation = .horizontal
        caller.alignment = .centerY
        caller.spacing = 10
        NSLayoutConstraint.activate([
            callerImage.widthAnchor.constraint(equalToConstant: 28),
            callerImage.heightAnchor.constraint(equalToConstant: 28)
        ])

        let warningIcon = NSImageView(image: LiquidGlassDesign.symbol(
            "exclamationmark.triangle.fill", pointSize: 15, weight: .medium) ?? NSImage())
        warningIcon.translatesAutoresizingMaskIntoConstraints = false
        warningIcon.contentTintColor = .systemOrange
        warningIcon.setAccessibilityElement(false)
        let warningText = makePromptLabel(
            "The command will receive the plaintext. Touch ID or your Mac password is required next; logs or other tools may capture the result.",
            font: .systemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor,
            wrapping: true)
        let warning = NSStackView(views: [warningIcon, warningText])
        warning.orientation = .horizontal
        warning.alignment = .top
        warning.spacing = 9
        NSLayoutConstraint.activate([
            warningIcon.widthAnchor.constraint(equalToConstant: 18),
            warningIcon.heightAnchor.constraint(equalToConstant: 18)
        ])

        let denyButton = NSButton(
            title: "Deny", target: self, action: #selector(denyRevealPrompt(_:)))
        LiquidGlassDesign.configureActionButton(denyButton, symbolName: "xmark")
        denyButton.keyEquivalent = "\u{1b}"
        denyButton.toolTip = "Deny the request (Escape)"

        let revealButton = NSButton(
            title: "Reveal", target: self, action: #selector(approveRevealPrompt(_:)))
        LiquidGlassDesign.configureActionButton(revealButton, symbolName: "lock.open.fill")
        // Deliberately no Return equivalent: disclosure always requires selecting the
        // affirmative control, while Escape remains a quick safe answer.
        revealButton.keyEquivalent = ""
        revealButton.toolTip = "Approve, then authenticate"
        if #available(macOS 26.0, *) {
            revealButton.tintProminence = .primary
            denyButton.tintProminence = .secondary
        } else {
            revealButton.bezelColor = .controlAccentColor
        }
        NSLayoutConstraint.activate([
            denyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            revealButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            denyButton.heightAnchor.constraint(equalToConstant: 32),
            revealButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        let actions = NSStackView(views: [NSView(), denyButton, revealButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [header, snippetCard, caller, warning, actions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: body.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            snippetCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caller.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let surface = LiquidGlassDesign.makeFloatingPanelSurface(
            containing: body,
            cornerRadius: 22,
            fallbackMaterial: .popover)
        let chrome = RevealConsentChromeView(cornerRadius: 22)
        chrome.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            surface.topAnchor.constraint(equalTo: chrome.topAnchor),
            surface.bottomAnchor.constraint(equalTo: chrome.bottomAnchor)
        ])
        guard let windowContent = window.contentView else { return window }
        windowContent.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(
                equalTo: windowContent.leadingAnchor, constant: shadowInset),
            chrome.trailingAnchor.constraint(
                equalTo: windowContent.trailingAnchor, constant: -shadowInset),
            chrome.topAnchor.constraint(
                equalTo: windowContent.topAnchor, constant: shadowInset),
            chrome.bottomAnchor.constraint(
                equalTo: windowContent.bottomAnchor, constant: -shadowInset)
        ])
        window.initialFirstResponder = denyButton
        return window
    }

    private func makePromptLabel(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor,
        wrapping: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = wrapping ? 3 : 1
        label.lineBreakMode = wrapping ? .byWordWrapping : .byClipping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func promptSingleLine(_ text: String?, fallback: String) -> String {
        let collapsed = (text ?? fallback)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = collapsed.isEmpty ? fallback : collapsed
        return value.count > 300 ? String(value.prefix(299)) + "…" : value
    }

    @objc private func approveRevealPrompt(_ sender: Any?) {
        finishRevealPrompt(with: .approved)
    }

    @objc private func denyRevealPrompt(_ sender: Any?) {
        finishRevealPrompt(with: .denied)
    }

    private func finishRevealPrompt(with result: RevealConsent) {
        guard let prompt = activeRevealPrompt else { return }
        activeRevealPrompt = nil
        prompt.timeoutTask?.cancel()
        prompt.window.orderOut(nil)
        prompt.continuation.resume(returning: result)
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
nonisolated struct PeerIdentity: Sendable {
    let pid: Int32
    let isTrusted: Bool
    /// Short, human-facing name used where the verified path has its own UI row.
    let applicationName: String
    /// The application bundle or executable path. This is the unforgeable part of the
    /// displayed identity; `applicationName` alone is merely Info.plist text.
    let applicationPath: String?
    /// Full identity retained for audit records and diagnostic text.
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
            self.applicationName = "Unidentified program"
            self.applicationPath = nil
            self.displayName = "an unidentified program"
            return
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            self.isTrusted = false
            self.applicationName = "Unidentified program"
            self.applicationPath = nil
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

        let identity = PeerIdentity.identity(forPID: reportedPID)
        self.applicationName = identity.applicationName
        self.applicationPath = identity.applicationPath
        self.displayName = identity.displayName
    }

    /// A name the user can recognise, which usually means the *terminal* they typed
    /// into rather than `snippets-cli` itself — the CLI is what the shell ran, but the
    /// shell is what the person is looking at.
    private static func identity(
        forPID pid: Int32
    ) -> (applicationName: String, applicationPath: String?, displayName: String) {
        var parent = pid
        for _ in 0..<4 {
            if let app = NSRunningApplication(processIdentifier: parent) {
                // `localizedName` is CFBundleName from that process's OWN Info.plist, so
                // anything this user can launch may call itself "Snippets" or
                // "1Password" — and a forged name reads as MORE trustworthy than the
                // honest "a command-line program (pid N)". This string is shown in the
                // consent panel and written to the audit log. Since the prompt naming
                // the requester IS the control, the name has to be shown alongside
                // something unforgeable: the path, which cannot be moved into /System or
                // /Applications. Checking the ancestor's signature is not a substitute —
                // a notarized app can still claim any CFBundleName it likes.
                let claimed = singleLineName(app.localizedName ?? "an application")
                guard let path = (app.bundleURL ?? app.executableURL)?.path else { break }
                let displayName = pid == parent
                    ? "\(claimed) — \(path)"
                    : "\(claimed) — \(path), which started pid \(pid)"
                return (claimed, path, displayName)
            }
            guard let next = parentPID(of: parent), next > 1 else { break }
            parent = next
        }
        let name = "Command-line program"
        return (name, nil, "a command-line program (pid \(pid))")
    }

    private static func singleLineName(_ name: String) -> String {
        let collapsed = name
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = collapsed.isEmpty ? "an application" : collapsed
        return value.count > 80 ? String(value.prefix(79)) + "…" : value
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
