import AppKit

/// AppKit owns the complete email/code flow; no browser session is created.
@MainActor
final class CloudEmailSignInViewController: NSViewController, NSTextFieldDelegate {
    private let emailField = NSTextField(string: "")
    private let codeField = NSTextField(string: "")
    private let heading = NSTextField(labelWithString: "")
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let expiryLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Continue", target: nil, action: nil)
    private let resendButton = NSButton(title: "Send another code", target: nil, action: nil)
    private let editEmailButton = NSButton(title: "Use a different email", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let contentStack = NSStackView()
    private let flow: SnippetsCloudEmailSignInFlow
    private let completed: (Result<Void, Error>) -> Void
    private var challenge: SnippetsCloudEmailChallenge?
    private var retryAvailableAt: Date?
    private var operation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var busy = false
    private var finished = false
    private var codeNeedsReplacement = false
    private var sendingCode = false

    init(flow: SnippetsCloudEmailSignInFlow, completed: @escaping (Result<Void, Error>) -> Void) {
        self.flow = flow
        self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func authenticate(flow: SnippetsCloudEmailSignInFlow, presenting presenter: NSViewController) async throws {
        guard let parent = presenter.viewIfLoaded?.window else {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            let controller = CloudEmailSignInViewController(flow: flow) { result in
                if case .failure = result { flow.cancel() }
                continuation.resume(with: result)
            }
            let sheet = NSWindow(contentViewController: controller)
            sheet.title = "Sign In to Snippets Cloud"
            sheet.styleMask = [.titled]
            sheet.isReleasedWhenClosed = false
            parent.beginSheet(sheet)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = CloudEmailDocumentView()
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
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        instructions.textColor = .secondaryLabelColor
        instructions.font = .systemFont(ofSize: 14)
        for field in [emailField, codeField] {
            field.font = .systemFont(ofSize: 17)
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.target = self
            field.action = #selector(submit)
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        }
        emailField.placeholderString = "you@example.com"
        emailField.setAccessibilityLabel("Email address")
        emailField.setAccessibilityIdentifier("cloudSignInEmail")
        codeField.placeholderString = "6-digit code"
        codeField.setAccessibilityLabel("Verification code")
        codeField.setAccessibilityIdentifier("cloudSignInCode")
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityIdentifier("cloudSignInError")
        expiryLabel.textColor = .secondaryLabelColor
        for button in [primaryButton, resendButton, editEmailButton, cancelButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        primaryButton.action = #selector(submit)
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("cloudSignInSubmit")
        resendButton.action = #selector(resend)
        resendButton.setAccessibilityIdentifier("cloudSignInResend")
        editEmailButton.action = #selector(editEmail)
        editEmailButton.setAccessibilityIdentifier("cloudSignInEditEmail")
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [cancelButton, spinner, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        for item in [heading, instructions, emailField, codeField, errorLabel, expiryLabel, resendButton, editEmailButton, buttons] {
            stack.addArrangedSubview(item)
            if item !== heading && item !== buttons {
                item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(emailField)
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
        editor.contentType = field === codeField ? .oneTimeCode : .emailAddress
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === codeField {
            let filtered = String(codeField.stringValue.filter { $0 >= "0" && $0 <= "9" }.prefix(challenge?.codeLength ?? 6))
            if filtered != codeField.stringValue { codeField.stringValue = filtered }
        }
        refresh()
    }

    @objc private func submit() {
        guard !finished, !busy, primaryButton.isEnabled else { return }
        if challenge == nil { requestCode() }
        else { verify() }
    }

    @objc private func resend() {
        guard !finished, !busy, resendButton.isEnabled else { return }
        requestCode()
    }

    @objc private func editEmail() {
        guard !finished, !busy else { return }
        challenge = nil
        codeNeedsReplacement = false
        codeField.stringValue = ""
        errorLabel.stringValue = ""
        refresh()
        view.window?.makeFirstResponder(emailField)
    }

    @objc private func cancel() { finish(.failure(CancellationError())) }

    private func requestCode() {
        let email = challenge?.email ?? emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        sendingCode = true
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let challenge = try await flow.sendCode(to: email)
                guard !Task.isCancelled, !finished else { return }
                self.challenge = challenge
                codeNeedsReplacement = false
                emailField.stringValue = challenge.email
                codeField.stringValue = ""
                retryAvailableAt = nil
                setBusy(false)
                view.window?.makeFirstResponder(codeField)
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func verify() {
        let code = codeField.stringValue
        sendingCode = false
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await flow.verify(code: code)
                guard !Task.isCancelled, !finished else { return }
                finish(.success(()))
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        if error is CancellationError || (error as? SnippetsCloudEmailSignInFailure) == .cancelled {
            finish(.failure(CancellationError()))
            return
        }
        if let failure = error as? SnippetsCloudEmailSignInFailure,
           failure == .codeExpired || failure == .tooManyAttempts {
            codeNeedsReplacement = true
        }
        if let delay = (error as? SnippetsCloudEmailSignInFailure)?.retryAfter {
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
        heading.stringValue = challenge == nil ? "Sign in to Snippets Cloud" : "Check your email"
        instructions.stringValue = challenge.map { "Enter the \($0.codeLength)-digit code sent to \($0.email)." }
            ?? "Enter your email to sign in or create an account. We’ll send you a verification code."
        emailField.isHidden = challenge != nil
        codeField.isHidden = challenge == nil
        emailField.isEnabled = !busy
        codeField.isEnabled = !busy
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        editEmailButton.isHidden = challenge == nil
        editEmailButton.isEnabled = !busy
        resendButton.isHidden = challenge == nil
        expiryLabel.isHidden = challenge == nil && retrySeconds == 0
        if let challenge {
            let expired = codeNeedsReplacement || challenge.expiresAt <= current
            let resendSeconds = max(retrySeconds, max(0, Int(ceil(challenge.resendAvailableAt.timeIntervalSince(current)))))
            codeField.placeholderString = "\(challenge.codeLength)-digit code"
            primaryButton.title = busy ? (sendingCode ? "Sending code…" : "Signing in…") : "Sign In"
            primaryButton.isEnabled = !busy && !expired && retrySeconds == 0
                && codeField.stringValue.count == challenge.codeLength
            resendButton.title = resendSeconds > 0 ? "Send another code in \(resendSeconds)s" : "Send another code"
            resendButton.isEnabled = !busy && resendSeconds == 0
            expiryLabel.stringValue = expired ? "Request a new code to continue."
                : "The code expires in \(max(1, Int(ceil(challenge.expiresAt.timeIntervalSince(current) / 60)))) minutes."
        } else {
            let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            let valid = parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
                && !email.contains(where: \.isWhitespace)
            primaryButton.title = busy ? "Sending code…" : "Continue"
            primaryButton.isEnabled = !busy && valid && retrySeconds == 0
            expiryLabel.stringValue = retrySeconds > 0 ? "Try again in \(retrySeconds) seconds." : ""
        }
        updateSheetSize()
    }

    private func updateSheetSize() {
        view.layoutSubtreeIfNeeded()
        let availableHeight = max(260, min(600, (view.window?.screen?.visibleFrame.height ?? 720) - 120))
        let minimumHeight: CGFloat = challenge == nil ? 260 : 390
        let height = min(availableHeight, max(minimumHeight, ceil(contentStack.fittingSize.height) + 56))
        let size = NSSize(width: 460, height: height)
        guard abs(view.frame.height - height) > 1 else { return }
        if let window = view.window { window.setContentSize(size) }
        else { view.setFrameSize(size) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        operation?.cancel()
        operation = nil
        clock?.cancel()
        clock = nil
        if let sheet = viewIfLoaded?.window {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(nil)
        }
        completed(result)
    }
}

@MainActor
private final class CloudEmailDocumentView: NSView {
    override var isFlipped: Bool { true }
}
