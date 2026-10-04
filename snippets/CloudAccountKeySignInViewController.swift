import AppKit
import CoreImage.CIFilterBuiltins

/// AppKit owns the complete native account flow; no browser session is created.
///
/// The sheet opens on a choice between **Create Account** and **Sign In with Account
/// Key**, plus **Sign In with Another Device** once discovery shows the pinned server
/// supports ADR 0007. No credential work starts until one of them is chosen. After a
/// successful create, the sheet shows **Save Your Account Key** and finishes only after
/// the explicit **I’ve Saved It** acknowledgement.
@MainActor
final class CloudAccountKeySignInViewController: NSViewController, NSTextFieldDelegate {
    enum Step: Equatable { case choose, signIn, saveKey, deviceSignIn }

    private let keyField = NSTextField(string: "")
    private let heading = NSTextField(labelWithString: "")
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let retryLabel = NSTextField(wrappingLabelWithString: "")
    private let keyDisplay = CloudAccountKeyDisplayView()
    private let primaryButton = NSButton(title: "Create Account", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "Sign In with Account Key…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deviceButton = NSButton(title: "Sign In with Another Device…", target: nil, action: nil)
    private let deviceQRView = NSImageView()
    private let deviceCodeLabel = NSTextField(labelWithString: "")
    private let deviceStatusLabel = NSTextField(labelWithString: "")
    private let copyRequestButton = NSButton(title: "Copy Request Text", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let contentStack = NSStackView()
    private let flow: SnippetsCloudAccountKeySignInFlow
    private let completed: (Result<Void, Error>) -> Void
    private(set) var step: Step = .choose
    private var createdKey: SnippetsCloudAccountKey?
    private var retryAvailableAt: Date?
    private var operation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var busy = false
    private var finished = false
    private var deviceSignInAvailable = false
    private var devicePresentation: SnippetsCloudDeviceSignInPresentation?
    private var availabilityProbe: Task<Void, Never>?
    private var deviceWait: Task<Void, Never>?

    init(flow: SnippetsCloudAccountKeySignInFlow, completed: @escaping (Result<Void, Error>) -> Void) {
        self.flow = flow
        self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func authenticate(flow: SnippetsCloudAccountKeySignInFlow, presenting presenter: NSViewController) async throws {
        guard let parent = presenter.viewIfLoaded?.window else {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            let controller = CloudAccountKeySignInViewController(flow: flow) { result in
                if case .failure = result { flow.cancel() }
                continuation.resume(with: result)
            }
            let sheet = NSWindow(contentViewController: controller)
            sheet.title = "Snippets Cloud Account"
            sheet.styleMask = [.titled]
            sheet.isReleasedWhenClosed = false
            parent.beginSheet(sheet)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = CloudAccountKeyDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)
        let stack = contentStack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -28),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        instructions.textColor = .secondaryLabelColor
        instructions.font = .systemFont(ofSize: 14)
        keyField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        keyField.bezelStyle = .roundedBezel
        keyField.delegate = self
        keyField.target = self
        keyField.action = #selector(submit)
        keyField.contentType = .password
        keyField.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
        keyField.setAccessibilityLabel("Account key")
        keyField.setAccessibilityIdentifier("cloudSignInAccountKey")
        keyField.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityIdentifier("cloudSignInError")
        retryLabel.textColor = .secondaryLabelColor
        for button in [primaryButton, secondaryButton, cancelButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        primaryButton.action = #selector(submit)
        primaryButton.setAccessibilityIdentifier("cloudSignInSubmit")
        secondaryButton.action = #selector(secondaryAction)
        secondaryButton.setAccessibilityIdentifier("cloudSignInSecondary")
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        keyDisplay.onCopy = { [weak self] in
            guard let key = self?.createdKey else { return }
            MacCloudSecretPasteboard.copy(key.displayForm)
        }
        deviceButton.target = self
        deviceButton.action = #selector(startDeviceSignIn)
        deviceButton.bezelStyle = .rounded
        deviceButton.setAccessibilityIdentifier("cloudSignInUseAnotherDevice")
        deviceQRView.imageScaling = .scaleProportionallyUpOrDown
        deviceQRView.setAccessibilityLabel("Sign-in request QR code")
        deviceQRView.translatesAutoresizingMaskIntoConstraints = false
        deviceQRView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        deviceQRView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        deviceCodeLabel.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        deviceCodeLabel.isSelectable = true
        deviceStatusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        deviceStatusLabel.textColor = .secondaryLabelColor
        copyRequestButton.target = self
        copyRequestButton.action = #selector(copyRequestText)
        copyRequestButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [cancelButton, spinner, secondaryButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        for item in [heading, instructions, deviceQRView, deviceCodeLabel, deviceStatusLabel,
                     copyRequestButton, keyField, keyDisplay, errorLabel, retryLabel,
                     deviceButton, buttons] {
            stack.addArrangedSubview(item)
            if [instructions, keyField, keyDisplay, errorLabel, retryLabel].contains(where: { $0 === item }) {
                item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        refresh()
    }

    /// Discovery read only, after the sheet is visible; it touches no credential.
    private func probeDeviceSignInAvailability() {
        guard availabilityProbe == nil, !deviceSignInAvailable else { return }
        availabilityProbe = Task { @MainActor [weak self, flow] in
            let available = await flow.isDeviceSignInAvailable()
            guard let self, !Task.isCancelled, !finished else { return }
            deviceSignInAvailable = available
            availabilityProbe = nil
            refresh()
        }
    }

    @objc private func startDeviceSignIn() {
        guard !finished, !busy, step == .choose, deviceSignInAvailable else { return }
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let presentation = try await flow.beginDeviceSignIn()
                guard !Task.isCancelled, !finished else { return }
                devicePresentation = presentation
                deviceQRView.image = MacCloudQRCodeImage.image(for: presentation.qrPayload, side: 200)
                step = .deviceSignIn
                setBusy(false)
                waitForDeviceApproval(presentation)
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func waitForDeviceApproval(_ presentation: SnippetsCloudDeviceSignInPresentation) {
        deviceWait?.cancel()
        deviceWait = Task { @MainActor [weak self, flow] in
            do {
                try await flow.waitForDeviceApproval(expiresAt: presentation.expiresAt)
                guard let self, !Task.isCancelled, !finished else { return }
                finish(.success(()))
            } catch {
                guard let self, !Task.isCancelled, !finished else { return }
                stopDeviceSignIn()
                step = .choose
                showFailure(error)
            }
        }
    }

    /// Back or Cancel discards local state; the server request simply expires.
    private func stopDeviceSignIn() {
        deviceWait?.cancel()
        deviceWait = nil
        devicePresentation = nil
        deviceQRView.image = nil
        flow.discardDeviceSignIn()
    }

    /// The payload carries no poll token, so an ordinary copy is safe; it lets a Mac
    /// without a camera paste the request into the approving device.
    @objc private func copyRequestText() {
        guard let devicePresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(devicePresentation.qrPayload, forType: .string)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
        probeDeviceSignInAvailability()
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        clock?.cancel()
        clock = nil
        if !finished { finish(.failure(CancellationError())) }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let editor = field.currentEditor() as? NSTextView else { return }
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
    }

    func controlTextDidChange(_ notification: Notification) {
        errorLabel.stringValue = ""
        refresh()
    }

    @objc private func submit() {
        guard !finished, !busy, primaryButton.isEnabled else { return }
        switch step {
        case .choose: createAccount()
        case .signIn: signIn()
        case .saveKey: finish(.success(()))
        case .deviceSignIn: break
        }
    }

    @objc private func secondaryAction() {
        guard !finished, !busy else { return }
        errorLabel.stringValue = ""
        switch step {
        case .choose:
            step = .signIn
            refresh()
            view.window?.makeFirstResponder(keyField)
        case .signIn:
            keyField.stringValue = ""
            step = .choose
            refresh()
        case .deviceSignIn:
            stopDeviceSignIn()
            step = .choose
            refresh()
        case .saveKey:
            break
        }
    }

    @objc private func cancel() {
        // The created account's key is on screen; leaving now would discard a session
        // the user has not acknowledged. Only the acknowledgement finishes this step.
        guard step != .saveKey else { return }
        if step == .deviceSignIn { stopDeviceSignIn() }
        finish(.failure(CancellationError()))
    }

    private func createAccount() {
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let key = try await flow.createAccount()
                guard !Task.isCancelled, !finished else { return }
                createdKey = key
                keyDisplay.key = key
                step = .saveKey
                setBusy(false)
                NSAccessibility.post(element: heading, notification: .announcementRequested,
                    userInfo: [.announcement: SnippetsCloudAccountKeyCopy.saveTitle,
                               .priority: NSAccessibilityPriorityLevel.high.rawValue])
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func signIn() {
        let input = keyField.stringValue
        // Validate before any request so a mistyped key is never sent.
        guard SnippetsCloudAccountKey(normalizing: input) != nil else {
            showFailure(SnippetsCloudAccountKeySignInFailure.invalidAccountKey)
            return
        }
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await flow.signIn(accountKey: input)
                guard !Task.isCancelled, !finished else { return }
                finish(.success(()))
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        if error is CancellationError || (error as? SnippetsCloudAccountKeySignInFailure) == .cancelled {
            finish(.failure(CancellationError()))
            return
        }
        if let delay = (error as? SnippetsCloudAccountKeySignInFailure)?.retryAfter {
            retryAvailableAt = Date().addingTimeInterval(delay)
        }
        errorLabel.stringValue = (error as? LocalizedError)?.errorDescription
            ?? "Couldn’t connect to Snippets Cloud. Try again."
        setBusy(false, clearError: false)
        NSAccessibility.post(element: errorLabel, notification: .announcementRequested,
            userInfo: [.announcement: errorLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func setBusy(_ value: Bool, clearError: Bool = true) {
        busy = value
        if clearError { errorLabel.stringValue = "" }
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refresh()
    }

    private func refresh() {
        let current = Date()
        let retrySeconds = max(0, Int(ceil((retryAvailableAt ?? current).timeIntervalSince(current))))
        keyField.isHidden = step != .signIn
        keyField.isEnabled = !busy
        keyDisplay.isHidden = step != .saveKey
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        retryLabel.isHidden = retrySeconds == 0 || step == .saveKey
        retryLabel.stringValue = retrySeconds > 0 ? "Try again in \(retrySeconds) seconds." : ""
        cancelButton.isHidden = step == .saveKey
        cancelButton.isEnabled = !finished
        secondaryButton.isHidden = step == .saveKey
        secondaryButton.isEnabled = !busy
        deviceButton.isHidden = step != .choose || !deviceSignInAvailable
        deviceButton.isEnabled = !busy && retrySeconds == 0
        for item in [deviceQRView, deviceCodeLabel, deviceStatusLabel, copyRequestButton] as [NSView] {
            item.isHidden = step != .deviceSignIn
        }
        primaryButton.isHidden = step == .deviceSignIn
        switch step {
        case .choose:
            heading.stringValue = "Snippets Cloud Account"
            instructions.stringValue = "Create a new account, or sign in with the account key you saved when you created it."
            primaryButton.title = busy ? "Creating Account…" : "Create Account"
            primaryButton.keyEquivalent = ""
            primaryButton.setAccessibilityIdentifier("cloudSignInCreateAccount")
            primaryButton.isEnabled = !busy && retrySeconds == 0
            secondaryButton.title = "Sign In with Account Key…"
            secondaryButton.setAccessibilityIdentifier("cloudSignInUseAccountKey")
        case .signIn:
            heading.stringValue = "Sign In with Account Key"
            instructions.stringValue = "Enter or paste the account key you saved. Spaces and hyphens are optional."
            primaryButton.title = busy ? "Signing In…" : "Sign In"
            primaryButton.keyEquivalent = "\r"
            primaryButton.setAccessibilityIdentifier("cloudSignInSubmit")
            primaryButton.isEnabled = !busy && retrySeconds == 0
                && !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            secondaryButton.title = "Back"
            secondaryButton.setAccessibilityIdentifier("cloudSignInBack")
        case .saveKey:
            heading.stringValue = SnippetsCloudAccountKeyCopy.saveTitle
            instructions.stringValue = SnippetsCloudAccountKeyCopy.saveMessage
            primaryButton.title = SnippetsCloudAccountKeyCopy.acknowledgeButtonTitle
            primaryButton.keyEquivalent = "\r"
            primaryButton.setAccessibilityIdentifier("cloudAccountKeySaved")
            primaryButton.isEnabled = !busy
        case .deviceSignIn:
            heading.stringValue = "Sign In with Another Device"
            instructions.stringValue = SnippetsCloudAccountKeyCopy.deviceSignInInstructions
            deviceCodeLabel.stringValue = devicePresentation.map { "Confirmation code: \($0.confirmationCode)" } ?? ""
            let seconds = max(0, Int(ceil((devicePresentation?.expiresAt ?? current).timeIntervalSince(current))))
            deviceStatusLabel.stringValue = String(format: "Waiting for approval… %02d:%02d", seconds / 60, seconds % 60)
            primaryButton.keyEquivalent = ""
            secondaryButton.title = "Back"
            secondaryButton.setAccessibilityIdentifier("cloudSignInBack")
        }
        updateSheetSize()
    }

    private func updateSheetSize() {
        view.layoutSubtreeIfNeeded()
        let availableHeight = max(260, min(600, (view.window?.screen?.visibleFrame.height ?? 720) - 120))
        let height = min(availableHeight, max(260, ceil(contentStack.fittingSize.height) + 56))
        let size = NSSize(width: 480, height: height)
        guard abs(view.frame.height - height) > 1 else { return }
        if let window = view.window { window.setContentSize(size) }
        else { view.setFrameSize(size) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        operation?.cancel()
        operation = nil
        deviceWait?.cancel()
        deviceWait = nil
        availabilityProbe?.cancel()
        availabilityProbe = nil
        clock?.cancel()
        clock = nil
        keyField.stringValue = ""
        keyDisplay.key = nil
        createdKey = nil
        if let sheet = viewIfLoaded?.window {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(nil)
        }
        completed(result)
    }
}

/// The monospaced, selectable display form plus **Copy**, shared by the post-create
/// save step and the signed-in **Show Account Key** sheet.
@MainActor
final class CloudAccountKeyDisplayView: NSStackView {
    var onCopy: (() -> Void)?
    var key: SnippetsCloudAccountKey? {
        didSet {
            keyLabel.string = key?.displayForm ?? ""
            keyLabel.setAccessibilityValue(key?.displayForm)
            keyLabel.invalidateIntrinsicContentSize()
            copiedLabel.isHidden = true
        }
    }

    private let keyLabel = MacCloudSecretTextView(usingTextLayoutManager: false)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let copiedLabel = NSTextField(labelWithString: "Copied. The clipboard clears in 2 minutes.")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        keyLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        keyLabel.isEditable = false
        keyLabel.isSelectable = true
        keyLabel.isRichText = false
        keyLabel.allowsUndo = false
        keyLabel.drawsBackground = false
        keyLabel.isAutomaticDataDetectionEnabled = false
        keyLabel.isAutomaticLinkDetectionEnabled = false
        keyLabel.isHorizontallyResizable = false
        keyLabel.isVerticallyResizable = false
        keyLabel.textContainerInset = NSSize(width: 0, height: 4)
        keyLabel.textContainer?.lineFragmentPadding = 0
        keyLabel.textContainer?.widthTracksTextView = true
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setAccessibilityLabel("Account key")
        keyLabel.setAccessibilityIdentifier("cloudAccountKeyValue")
        keyLabel.copySecret = { [weak self] in self?.copyKey() }
        copyButton.target = self
        copyButton.action = #selector(copyKey)
        copyButton.bezelStyle = .rounded
        copyButton.setAccessibilityIdentifier("cloudAccountKeyCopy")
        copiedLabel.textColor = .secondaryLabelColor
        copiedLabel.isHidden = true
        let row = NSStackView(views: [copyButton, copiedLabel])
        row.orientation = .horizontal
        row.spacing = 10
        addArrangedSubview(keyLabel)
        addArrangedSubview(row)
        keyLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyKey() {
        guard key != nil else { return }
        onCopy?()
        copiedLabel.isHidden = false
    }
}

/// Selection is allowed, but every copy goes through the marker-guarded expiring
/// pasteboard; drag and Services receive nothing, so the key cannot leave through a
/// path without the recovery-kit clipboard rule.
@MainActor
final class MacCloudSecretTextView: NSTextView {
    var copySecret: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 17))
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(max(used.height, lineHeight) + textContainerInset.height * 2))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copySecret?()
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        false
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }
}

/// **Show Account Key** for a signed-in account. The caller presents it only after a
/// fresh device-owner authentication, and it closes when the app becomes inactive,
/// like the recovery kit.
@MainActor
final class CloudAccountKeyRevealViewController: NSViewController {
    private let key: SnippetsCloudAccountKey
    private let display = CloudAccountKeyDisplayView()
    private var inactivityObserver: NSObjectProtocol?
    var close: (() -> Void)?

    init(key: SnippetsCloudAccountKey) {
        self.key = key
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        let heading = NSTextField(labelWithString: "Account Key")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: SnippetsCloudAccountKeyCopy.saveMessage)
        message.textColor = .secondaryLabelColor
        display.key = key
        display.onCopy = { [key] in MacCloudSecretPasteboard.copy(key.displayForm) }
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        let stack = NSStackView(views: [heading, message, display, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            display.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard inactivityObserver == nil else { return }
        inactivityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.view.isHidden = true
                self?.close?()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        display.key = nil
        if let inactivityObserver {
            NotificationCenter.default.removeObserver(inactivityObserver)
            self.inactivityObserver = nil
        }
    }

    @objc private func closeSheet() { close?() }
}

/// QR rendering for native cloud sheets.
@MainActor
enum MacCloudQRCodeImage {
    static func image(for value: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}

/// Recovery-kit clipboard rule, shared with the account key: the copy carries a private
/// marker and is cleared after two minutes only if it is still the clipboard owner.
@MainActor
enum MacCloudSecretPasteboard {
    static let lifetime: TimeInterval = 120
    private static let markerType = NSPasteboard.PasteboardType("com.khm.snippets.recovery-marker")

    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) {
        let marker = UUID().uuidString
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString(marker, forType: markerType)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            guard pasteboard.string(forType: markerType) == marker else { return }
            pasteboard.clearContents()
        }
    }
}

@MainActor
private final class CloudAccountKeyDocumentView: NSView {
    override var isFlipped: Bool { true }
}
