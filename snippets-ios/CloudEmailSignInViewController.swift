import UIKit

/// A native email/code sheet. Network requests start only after an explicit submit.
@MainActor
final class CloudEmailSignInViewController: UIViewController, UITextFieldDelegate {
    enum PresentationFailure: Error, LocalizedError {
        case windowUnavailable
        var errorDescription: String? {
            "The sign-in window is no longer available. Reopen Settings and try again."
        }
    }

    let emailField = UITextField()
    let codeField = UITextField()
    let primaryButton = UIButton(type: .system)
    let resendButton = UIButton(type: .system)
    let editEmailButton = UIButton(type: .system)
    let errorLabel = UILabel()
    private let heading = UILabel()
    private let instructions = UILabel()
    private let expiryLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let sendCode: (String) async throws -> SnippetsCloudEmailChallenge
    private let verifyCode: (String) async throws -> Void
    private let now: () -> Date
    private let automaticallyFocusInput: Bool
    private let completed: (Result<Void, Error>) -> Void
    private var operation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var retryAvailableAt: Date?
    private(set) var challenge: SnippetsCloudEmailChallenge?
    private(set) var isBusy = false
    private var finished = false
    private var codeNeedsReplacement = false
    private var sendingCode = false

    init(
        sendCode: @escaping (String) async throws -> SnippetsCloudEmailChallenge,
        verifyCode: @escaping (String) async throws -> Void,
        now: @escaping () -> Date = Date.init,
        automaticallyFocusInput: Bool = true,
        completed: @escaping (Result<Void, Error>) -> Void
    ) {
        self.sendCode = sendCode
        self.verifyCode = verifyCode
        self.now = now
        self.automaticallyFocusInput = automaticallyFocusInput
        self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func authenticate(
        flow: SnippetsCloudEmailSignInFlow,
        presenting presenter: UIViewController
    ) async throws {
        let visible = try visiblePresenter(for: presenter)
        try await withCheckedThrowingContinuation { continuation in
            let controller = CloudEmailSignInViewController(
                sendCode: { try await flow.sendCode(to: $0) },
                verifyCode: { try await flow.verify(code: $0) }
            ) { result in
                if case .failure = result { flow.cancel() }
                continuation.resume(with: result)
            }
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .formSheet
            navigation.preferredContentSize = CGSize(width: 480, height: 560)
            navigation.isModalInPresentation = true
            visible.present(navigation, animated: true)
        }
    }

    /// The Sync pane can be behind the account page. Resolve within its own window,
    /// then present from the visible controller, without consulting another scene.
    static func visiblePresenter(for presenter: UIViewController) throws -> UIViewController {
        var ancestor: UIViewController? = presenter
        var window: UIWindow?
        while let controller = ancestor {
            if let candidate = controller.viewIfLoaded?.window, !candidate.isHidden {
                window = candidate
                break
            }
            ancestor = controller.parent
        }
        guard var visible = window?.rootViewController else {
            throw PresentationFailure.windowUnavailable
        }
        while true {
            if let presented = visible.presentedViewController, !presented.isBeingDismissed {
                visible = presented
            } else if let navigation = visible as? UINavigationController,
                      let child = navigation.visibleViewController {
                visible = child
            } else if let split = visible as? UISplitViewController,
                      let child = split.viewControllers.last(where: { $0.viewIfLoaded?.window === window }) {
                visible = child
            } else {
                return visible
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign In"
        navigationItem.largeTitleDisplayMode = .never
        if let navigationBar = navigationController?.navigationBar {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .systemGroupedBackground
            appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
            navigationBar.tintColor = .systemIndigo
        }
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "cloudSignInCancel"

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        heading.font = .preferredFont(forTextStyle: .title1)
        heading.numberOfLines = 0
        heading.adjustsFontForContentSizeCategory = true
        heading.accessibilityTraits = .header
        instructions.font = .preferredFont(forTextStyle: .body)
        instructions.numberOfLines = 0
        instructions.adjustsFontForContentSizeCategory = true
        instructions.textColor = .secondaryLabel
        for field in [emailField, codeField] {
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        }
        emailField.placeholder = "you@example.com"
        emailField.accessibilityLabel = "Email address"
        emailField.accessibilityIdentifier = "cloudSignInEmail"
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .continue
        codeField.placeholder = "6-digit code"
        codeField.accessibilityLabel = "Verification code"
        codeField.accessibilityIdentifier = "cloudSignInCode"
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.returnKeyType = .go
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "cloudSignInError"
        expiryLabel.font = .preferredFont(forTextStyle: .footnote)
        expiryLabel.adjustsFontForContentSizeCategory = true
        expiryLabel.textColor = .secondaryLabel
        expiryLabel.numberOfLines = 0
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.cornerStyle = .medium
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        primaryButton.configuration = buttonConfiguration
        primaryButton.accessibilityIdentifier = "cloudSignInSubmit"
        primaryButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        resendButton.accessibilityIdentifier = "cloudSignInResend"
        resendButton.addTarget(self, action: #selector(resend), for: .touchUpInside)
        editEmailButton.setTitle("Use a different email", for: .normal)
        editEmailButton.accessibilityIdentifier = "cloudSignInEditEmail"
        editEmailButton.addTarget(self, action: #selector(editEmail), for: .touchUpInside)
        for button in [resendButton, editEmailButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        spinner.hidesWhenStopped = true
        for item in [heading, instructions, emailField, codeField, errorLabel, primaryButton,
                     spinner, expiryLabel, resendButton, editEmailButton] {
            stack.addArrangedSubview(item)
        }
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if challenge == nil { focusInput(emailField) }
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.cancel()
        clock = nil
        if navigationController?.isBeingDismissed == true || isBeingDismissed {
            cancel()
        }
    }

    private func focusInput(_ field: UITextField) {
        if automaticallyFocusInput { field.becomeFirstResponder() }
    }

    @objc func submit() {
        guard !finished, !isBusy, primaryButton.isEnabled else { return }
        if challenge == nil { requestCode() }
        else { verify() }
    }

    @objc func resend() {
        guard !finished, !isBusy, resendButton.isEnabled else { return }
        requestCode()
    }

    @objc func editEmail() {
        guard !finished, !isBusy else { return }
        challenge = nil
        codeNeedsReplacement = false
        codeField.text = nil
        errorLabel.text = nil
        refresh()
        focusInput(emailField)
    }

    @objc func cancel() {
        finish(.failure(CancellationError()))
    }

    private func requestCode() {
        let email = challenge?.email ?? (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sendingCode = true
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let challenge = try await sendCode(email)
                guard !Task.isCancelled, !finished else { return }
                self.challenge = challenge
                codeNeedsReplacement = false
                emailField.text = challenge.email
                codeField.text = nil
                retryAvailableAt = nil
                setBusy(false)
                focusInput(codeField)
                UIAccessibility.post(notification: .announcement, argument: "Verification code sent. Enter the code from your email.")
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func verify() {
        let code = codeField.text ?? ""
        sendingCode = false
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await verifyCode(code)
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
            retryAvailableAt = now().addingTimeInterval(delay)
        }
        errorLabel.text = (error as? LocalizedError)?.errorDescription
            ?? "Couldn’t connect to Snippets Cloud. Try again."
        setBusy(false, clearError: false)
        UIAccessibility.post(notification: .announcement, argument: errorLabel.text)
    }

    private func setBusy(_ busy: Bool, clearError: Bool = true) {
        isBusy = busy
        if clearError { errorLabel.text = nil }
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        refresh()
    }

    @objc private func inputChanged() { refresh() }

    func refresh() {
        guard isViewLoaded else { return }
        let current = now()
        let retrySeconds = max(0, Int(ceil((retryAvailableAt ?? current).timeIntervalSince(current))))
        heading.text = challenge == nil ? "Sign in to Snippets Cloud" : "Check your email"
        instructions.text = challenge.map { "Enter the \($0.codeLength)-digit code sent to \($0.email)." }
            ?? "Enter your email to sign in or create an account. We’ll send you a verification code."
        emailField.isHidden = challenge != nil
        codeField.isHidden = challenge == nil
        emailField.isEnabled = !isBusy
        codeField.isEnabled = !isBusy
        errorLabel.isHidden = errorLabel.text?.isEmpty != false
        editEmailButton.isHidden = challenge == nil
        editEmailButton.isEnabled = !isBusy
        resendButton.isHidden = challenge == nil
        expiryLabel.isHidden = challenge == nil && retrySeconds == 0
        if let challenge {
            let expired = codeNeedsReplacement || challenge.expiresAt <= current
            let resendSeconds = max(retrySeconds, max(0, Int(ceil(challenge.resendAvailableAt.timeIntervalSince(current)))))
            codeField.placeholder = "\(challenge.codeLength)-digit code"
            primaryButton.setTitle(isBusy ? (sendingCode ? "Sending code…" : "Signing in…") : "Sign In", for: .normal)
            primaryButton.isEnabled = !isBusy && !expired && retrySeconds == 0
                && (codeField.text ?? "").count == challenge.codeLength
            resendButton.setTitle(resendSeconds > 0 ? "Send another code in \(resendSeconds)s" : "Send another code", for: .normal)
            resendButton.isEnabled = !isBusy && resendSeconds == 0
            expiryLabel.text = expired ? "Request a new code to continue."
                : "The code expires in \(max(1, Int(ceil(challenge.expiresAt.timeIntervalSince(current) / 60)))) minutes."
        } else {
            let email = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            let valid = parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
                && !email.contains(where: \.isWhitespace)
            primaryButton.setTitle(isBusy ? "Sending code…" : "Continue", for: .normal)
            primaryButton.isEnabled = !isBusy && valid && retrySeconds == 0
            expiryLabel.text = retrySeconds > 0 ? "Try again in \(retrySeconds) seconds." : nil
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField === codeField, let current = textField.text,
              let swiftRange = Range(range, in: current) else { return true }
        let proposed = current.replacingCharacters(in: swiftRange, with: string)
        codeField.text = String(proposed.filter { $0 >= "0" && $0 <= "9" }.prefix(challenge?.codeLength ?? 6))
        refresh()
        return false
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        operation?.cancel()
        operation = nil
        clock?.cancel()
        clock = nil
        view.endEditing(true)
        if let navigationController, navigationController.presentingViewController != nil {
            navigationController.dismiss(animated: true) { [completed] in completed(result) }
        } else {
            completed(result)
        }
    }
}
