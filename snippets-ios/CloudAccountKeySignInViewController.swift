import CoreImage.CIFilterBuiltins
import UIKit
import UniformTypeIdentifiers

/// The native account sheet. It opens on **Create Account** and **Sign In with
/// Account Key**, plus **Sign In with Another Device** when the pinned server advertises
/// ADR 0007; credential work starts only after one of them is chosen. A created
/// account's key is shown for saving and the sheet finishes only after the explicit
/// **I’ve Saved It** acknowledgement.
@MainActor
final class CloudAccountKeySignInViewController: UIViewController, UITextFieldDelegate {
    enum PresentationFailure: Error, LocalizedError {
        case windowUnavailable
        var errorDescription: String? {
            "The sign-in window is no longer available. Reopen Settings and try again."
        }
    }

    enum Step: Equatable { case choose, signIn, saveKey, deviceSignIn }

    /// ADR 0007 new-device operations, wired to `SnippetsCloudAccountKeySignInFlow`.
    struct DeviceSignInActions {
        let isAvailable: () async -> Bool
        let begin: () async throws -> SnippetsCloudDeviceSignInPresentation
        let waitForApproval: (Date) async throws -> Void
        let discard: () -> Void
    }

    let keyField = UITextField()
    let deviceButton = UIButton(type: .system)
    let deviceQRView = UIImageView()
    let deviceCodeLabel = UILabel()
    let deviceStatusLabel = UILabel()
    let copyRequestButton = UIButton(type: .system)
    let primaryButton = UIButton(type: .system)
    let secondaryButton = UIButton(type: .system)
    let errorLabel = UILabel()
    let keyDisplay = CloudAccountKeyDisplayView()
    private let heading = UILabel()
    private let instructions = UILabel()
    private let retryLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let createAccount: () async throws -> SnippetsCloudAccountKey
    private let signIn: (String) async throws -> Void
    private let copyKey: @MainActor (SnippetsCloudAccountKey) -> Void
    private let deviceSignIn: DeviceSignInActions?
    private let now: () -> Date
    private let automaticallyFocusInput: Bool
    private let completed: (Result<Void, Error>) -> Void
    private var operation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var retryAvailableAt: Date?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private(set) var step: Step = .choose
    private(set) var isBusy = false
    private(set) var deviceSignInAvailable = false
    private(set) var devicePresentation: SnippetsCloudDeviceSignInPresentation?
    private var availabilityProbe: Task<Void, Never>?
    private var deviceWait: Task<Void, Never>?
    private var finished = false

    init(
        createAccount: @escaping () async throws -> SnippetsCloudAccountKey,
        signIn: @escaping (String) async throws -> Void,
        copyKey: @escaping @MainActor (SnippetsCloudAccountKey) -> Void = { CloudSecretPasteboard.copy($0.displayForm) },
        deviceSignIn: DeviceSignInActions? = nil,
        now: @escaping () -> Date = Date.init,
        automaticallyFocusInput: Bool = true,
        completed: @escaping (Result<Void, Error>) -> Void
    ) {
        self.createAccount = createAccount
        self.signIn = signIn
        self.copyKey = copyKey
        self.deviceSignIn = deviceSignIn
        self.now = now
        self.automaticallyFocusInput = automaticallyFocusInput
        self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func authenticate(
        flow: SnippetsCloudAccountKeySignInFlow,
        presenting presenter: UIViewController
    ) async throws {
        let visible = try visiblePresenter(for: presenter)
        try await withCheckedThrowingContinuation { continuation in
            let controller = CloudAccountKeySignInViewController(
                createAccount: { try await flow.createAccount() },
                signIn: { try await flow.signIn(accountKey: $0) },
                deviceSignIn: .init(
                    isAvailable: { await flow.isDeviceSignInAvailable() },
                    begin: { try await flow.beginDeviceSignIn() },
                    waitForApproval: { try await flow.waitForDeviceApproval(expiresAt: $0) },
                    discard: { flow.discardDeviceSignIn() })
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
        title = "Snippets Cloud"
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
        keyField.borderStyle = .roundedRect
        keyField.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        keyField.adjustsFontForContentSizeCategory = true
        keyField.autocorrectionType = .no
        keyField.spellCheckingType = .no
        keyField.autocapitalizationType = .allCharacters
        keyField.smartDashesType = .no
        keyField.smartQuotesType = .no
        keyField.smartInsertDeleteType = .no
        keyField.keyboardType = .asciiCapable
        keyField.textContentType = .password
        keyField.clearButtonMode = .whileEditing
        keyField.returnKeyType = .go
        keyField.placeholder = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
        keyField.accessibilityLabel = "Account key"
        keyField.accessibilityIdentifier = "cloudSignInAccountKey"
        keyField.delegate = self
        keyField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        keyField.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        keyDisplay.onCopy = { [weak self] in
            guard let self, let key = keyDisplay.key else { return }
            copyKey(key)
        }
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "cloudSignInError"
        retryLabel.font = .preferredFont(forTextStyle: .footnote)
        retryLabel.adjustsFontForContentSizeCategory = true
        retryLabel.textColor = .secondaryLabel
        retryLabel.numberOfLines = 0
        var primaryConfiguration = UIButton.Configuration.filled()
        primaryConfiguration.cornerStyle = .medium
        primaryConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        primaryButton.configuration = primaryConfiguration
        primaryButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        var secondaryConfiguration = UIButton.Configuration.gray()
        secondaryConfiguration.cornerStyle = .medium
        secondaryConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        secondaryButton.configuration = secondaryConfiguration
        secondaryButton.addTarget(self, action: #selector(secondaryAction), for: .touchUpInside)
        for button in [primaryButton, secondaryButton] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        deviceButton.setTitle("Sign In with Another Device", for: .normal)
        deviceButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        deviceButton.titleLabel?.adjustsFontForContentSizeCategory = true
        deviceButton.titleLabel?.numberOfLines = 0
        deviceButton.accessibilityIdentifier = "cloudSignInUseAnotherDevice"
        deviceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        deviceButton.addTarget(self, action: #selector(startDeviceSignIn), for: .touchUpInside)
        deviceQRView.contentMode = .scaleAspectFit
        deviceQRView.layer.magnificationFilter = .nearest
        deviceQRView.accessibilityLabel = "Sign-in request QR code"
        deviceQRView.accessibilityIdentifier = "cloudDeviceSignInQR"
        deviceQRView.isAccessibilityElement = true
        deviceQRView.heightAnchor.constraint(equalTo: deviceQRView.widthAnchor).isActive = true
        deviceQRView.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        deviceCodeLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .monospacedSystemFont(ofSize: 22, weight: .semibold))
        deviceCodeLabel.adjustsFontForContentSizeCategory = true
        deviceCodeLabel.textAlignment = .center
        deviceCodeLabel.numberOfLines = 0
        deviceCodeLabel.accessibilityIdentifier = "cloudDeviceSignInCode"
        deviceStatusLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        deviceStatusLabel.textColor = .secondaryLabel
        deviceStatusLabel.textAlignment = .center
        deviceStatusLabel.numberOfLines = 0
        deviceStatusLabel.accessibilityIdentifier = "cloudDeviceSignInStatus"
        copyRequestButton.setTitle("Copy Request Text", for: .normal)
        copyRequestButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        copyRequestButton.titleLabel?.adjustsFontForContentSizeCategory = true
        copyRequestButton.accessibilityIdentifier = "cloudDeviceSignInCopy"
        copyRequestButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copyRequestButton.addTarget(self, action: #selector(copyRequestText), for: .touchUpInside)
        spinner.hidesWhenStopped = true
        for item in [heading, instructions, deviceQRView, deviceCodeLabel, deviceStatusLabel,
                     copyRequestButton, keyField, keyDisplay, errorLabel, primaryButton,
                     spinner, retryLabel, secondaryButton, deviceButton] {
            stack.addArrangedSubview(item)
        }
        refresh()
    }

    /// Offers **Sign In with Another Device** only after discovery shows the server
    /// supports it. This is a read of the public discovery document, after the sheet is
    /// visible; it touches no credential.
    func probeDeviceSignInAvailability() {
        guard let deviceSignIn, availabilityProbe == nil, !deviceSignInAvailable else { return }
        availabilityProbe = Task { @MainActor [weak self] in
            let available = await deviceSignIn.isAvailable()
            guard let self, !Task.isCancelled, !finished else { return }
            deviceSignInAvailable = available
            availabilityProbe = nil
            refresh()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        probeDeviceSignInAvailability()
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
        guard lifecycleObservers.isEmpty else { return }
        // Keep the newly issued key out of the app-switcher snapshot without ending the
        // flow: the user may be switching to a password manager to save it.
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyDisplay.isConcealed = true }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyDisplay.isConcealed = false }
            },
        ]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.cancel()
        clock = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        if navigationController?.isBeingDismissed == true || isBeingDismissed {
            finish(.failure(CancellationError()))
        }
    }

    private func focusInput(_ field: UITextField) {
        if automaticallyFocusInput { field.becomeFirstResponder() }
    }

    @objc func submit() {
        guard !finished, !isBusy, primaryButton.isEnabled else { return }
        switch step {
        case .choose: performCreateAccount()
        case .signIn: performSignIn()
        case .saveKey: acknowledgeSavedKey()
        case .deviceSignIn: break
        }
    }

    /// Choose → key entry, or key entry → back to the choice.
    @objc func secondaryAction() {
        guard !finished, !isBusy else { return }
        errorLabel.text = nil
        switch step {
        case .choose:
            step = .signIn
            refresh()
            focusInput(keyField)
        case .signIn:
            keyField.text = nil
            step = .choose
            view.endEditing(true)
            refresh()
        case .deviceSignIn:
            stopDeviceSignIn()
            step = .choose
            refresh()
        case .saveKey:
            break
        }
    }

    @objc func startDeviceSignIn() {
        guard !finished, !isBusy, step == .choose, deviceSignInAvailable, let deviceSignIn else { return }
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let presentation = try await deviceSignIn.begin()
                guard !Task.isCancelled, !finished else { return }
                devicePresentation = presentation
                deviceQRView.image = CloudQRCodeImage.image(for: presentation.qrPayload)
                step = .deviceSignIn
                setBusy(false)
                UIAccessibility.post(notification: .screenChanged, argument: heading)
                waitForDeviceApproval(presentation)
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func waitForDeviceApproval(_ presentation: SnippetsCloudDeviceSignInPresentation) {
        guard let deviceSignIn else { return }
        deviceWait?.cancel()
        deviceWait = Task { @MainActor [weak self] in
            do {
                try await deviceSignIn.waitForApproval(presentation.expiresAt)
                guard let self, !Task.isCancelled, !finished else { return }
                finish(.success(()))
            } catch {
                guard let self, !Task.isCancelled, !finished else { return }
                // Expired or rejected requests end here; return to the choice.
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
        deviceSignIn?.discard()
    }

    /// The payload is not a credential (it carries no poll token), so it may reach the
    /// other device through Universal Clipboard; it expires with the request.
    @objc func copyRequestText() {
        guard let devicePresentation else { return }
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: devicePresentation.qrPayload]],
            options: [.expirationDate: devicePresentation.expiresAt])
        UIAccessibility.post(notification: .announcement, argument: "Request text copied.")
    }

    /// Cancellation is unavailable once a created key is on screen: only the explicit
    /// acknowledgement continues, so a user never leaves without seeing the key.
    @objc func cancel() {
        guard step != .saveKey else { return }
        if step == .deviceSignIn { stopDeviceSignIn() }
        finish(.failure(CancellationError()))
    }

    func acknowledgeSavedKey() {
        guard step == .saveKey, !finished else { return }
        finish(.success(()))
    }

    private func performCreateAccount() {
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let key = try await createAccount()
                guard !Task.isCancelled, !finished else { return }
                keyDisplay.key = key
                step = .saveKey
                setBusy(false)
                UIAccessibility.post(notification: .screenChanged, argument: heading)
            } catch {
                guard !Task.isCancelled, !finished else { return }
                showFailure(error)
            }
        }
    }

    private func performSignIn() {
        let input = keyField.text ?? ""
        // Validate before any request so a mistyped key is never sent.
        guard SnippetsCloudAccountKey(normalizing: input) != nil else {
            showFailure(SnippetsCloudAccountKeySignInFailure.invalidAccountKey)
            return
        }
        setBusy(true)
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await signIn(input)
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

    @objc private func inputChanged() {
        errorLabel.text = nil
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let current = now()
        let retrySeconds = max(0, Int(ceil((retryAvailableAt ?? current).timeIntervalSince(current))))
        keyField.isHidden = step != .signIn
        keyField.isEnabled = !isBusy
        keyDisplay.isHidden = step != .saveKey
        errorLabel.isHidden = errorLabel.text?.isEmpty != false
        retryLabel.isHidden = retrySeconds == 0 || step == .saveKey
        retryLabel.text = retrySeconds > 0 ? "Try again in \(retrySeconds) seconds." : nil
        secondaryButton.isHidden = step == .saveKey
        secondaryButton.isEnabled = !isBusy
        deviceButton.isHidden = step != .choose || !deviceSignInAvailable
        deviceButton.isEnabled = !isBusy && retrySeconds == 0
        for item in [deviceQRView, deviceCodeLabel, deviceStatusLabel, copyRequestButton] as [UIView] {
            item.isHidden = step != .deviceSignIn
        }
        navigationItem.leftBarButtonItem?.isHidden = step == .saveKey
        navigationItem.leftBarButtonItem?.isEnabled = step != .saveKey
        switch step {
        case .choose:
            heading.text = "Snippets Cloud Account"
            instructions.text = "Create a new account, or sign in with the account key you saved when you created it."
            primaryButton.setTitle(isBusy ? "Creating Account…" : "Create Account", for: .normal)
            primaryButton.accessibilityIdentifier = "cloudSignInCreateAccount"
            primaryButton.isEnabled = !isBusy && retrySeconds == 0
            secondaryButton.setTitle("Sign In with Account Key", for: .normal)
            secondaryButton.accessibilityIdentifier = "cloudSignInUseAccountKey"
        case .signIn:
            heading.text = "Sign In with Account Key"
            instructions.text = "Enter or paste the account key you saved. Spaces and hyphens are optional."
            primaryButton.setTitle(isBusy ? "Signing In…" : "Sign In", for: .normal)
            primaryButton.accessibilityIdentifier = "cloudSignInSubmit"
            primaryButton.isEnabled = !isBusy && retrySeconds == 0
                && !(keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            secondaryButton.setTitle("Back", for: .normal)
            secondaryButton.accessibilityIdentifier = "cloudSignInBack"
        case .saveKey:
            heading.text = SnippetsCloudAccountKeyCopy.saveTitle
            instructions.text = SnippetsCloudAccountKeyCopy.saveMessage
            primaryButton.setTitle(SnippetsCloudAccountKeyCopy.acknowledgeButtonTitle, for: .normal)
            primaryButton.accessibilityIdentifier = "cloudAccountKeySaved"
            primaryButton.isEnabled = !isBusy
        case .deviceSignIn:
            heading.text = "Sign In with Another Device"
            instructions.text = SnippetsCloudAccountKeyCopy.deviceSignInInstructions
            deviceCodeLabel.text = devicePresentation.map { "Confirmation code: \($0.confirmationCode)" }
            deviceCodeLabel.accessibilityValue = devicePresentation?.confirmationCode
            let seconds = max(0, Int(ceil((devicePresentation?.expiresAt ?? current).timeIntervalSince(current))))
            deviceStatusLabel.text = String(format: "Waiting for approval… %02d:%02d", seconds / 60, seconds % 60)
            secondaryButton.setTitle("Back", for: .normal)
            secondaryButton.accessibilityIdentifier = "cloudSignInBack"
        }
        primaryButton.isHidden = step == .deviceSignIn
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
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
        view.endEditing(true)
        keyField.text = nil
        keyDisplay.key = nil
        if let navigationController, navigationController.presentingViewController != nil {
            navigationController.dismiss(animated: true) { [completed] in completed(result) }
        } else {
            completed(result)
        }
    }
}

/// The monospaced, selectable display form plus **Copy**, shared by the post-create
/// save step and the signed-in **Show Account Key** screen.
@MainActor
final class CloudAccountKeyDisplayView: UIStackView {
    let keyTextView = CloudSecretTextView()
    let copyButton = UIButton(type: .system)
    let copiedLabel = UILabel()
    var onCopy: (() -> Void)?
    var key: SnippetsCloudAccountKey? {
        didSet {
            keyTextView.text = key?.displayForm
            keyTextView.accessibilityValue = key?.displayForm
            copiedLabel.isHidden = true
        }
    }
    /// Hides the key while the app is in the background snapshot.
    var isConcealed = false {
        didSet { keyTextView.alpha = isConcealed ? 0 : 1 }
    }

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 12
        keyTextView.font = UIFontMetrics(forTextStyle: .title3).scaledFont(
            for: .monospacedSystemFont(ofSize: 20, weight: .semibold))
        keyTextView.adjustsFontForContentSizeCategory = true
        keyTextView.isEditable = false
        keyTextView.isSelectable = true
        keyTextView.isScrollEnabled = false
        keyTextView.dataDetectorTypes = []
        keyTextView.textAlignment = .center
        keyTextView.backgroundColor = .secondarySystemGroupedBackground
        keyTextView.layer.cornerRadius = 10
        keyTextView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        keyTextView.accessibilityLabel = "Account key"
        keyTextView.accessibilityIdentifier = "cloudAccountKeyValue"
        keyTextView.copySecret = { [weak self] in self?.copyKey() }
        copyButton.setTitle("Copy", for: .normal)
        copyButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        copyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        copyButton.accessibilityIdentifier = "cloudAccountKeyCopy"
        copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copyButton.addTarget(self, action: #selector(copyKey), for: .touchUpInside)
        copiedLabel.text = "Copied. The clipboard clears in 2 minutes."
        copiedLabel.font = .preferredFont(forTextStyle: .footnote)
        copiedLabel.adjustsFontForContentSizeCategory = true
        copiedLabel.textColor = .secondaryLabel
        copiedLabel.numberOfLines = 0
        copiedLabel.isHidden = true
        [keyTextView, copyButton, copiedLabel].forEach(addArrangedSubview)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func copyKey() {
        guard key != nil else { return }
        onCopy?()
        copiedLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: copiedLabel.text)
    }
}

/// Selection is allowed, but every copy goes through the expiring local-only
/// pasteboard and drag, share and lookup are disabled so the key cannot leave through
/// a path without the recovery-kit clipboard rule.
@MainActor
final class CloudSecretTextView: UITextView {
    var copySecret: (() -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        textDragInteraction?.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copy(_:)) || action == #selector(select(_:))
            || action == #selector(selectAll(_:))
    }

    override func copy(_ sender: Any?) {
        copySecret?()
    }
}

/// QR rendering shared by the recovery kit, pairing invitations and device sign-in.
enum CloudQRCodeImage {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Recovery-kit clipboard rule, shared with the account key: local to this device and
/// expiring after two minutes.
enum CloudSecretPasteboard {
    static let lifetime: TimeInterval = 120

    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [
            .localOnly: true,
            .expirationDate: now.addingTimeInterval(lifetime),
        ]
    }

    static func copy(
        _ value: String,
        to pasteboard: UIPasteboard = .general,
        now: Date = Date()
    ) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: options(now: now))
    }
}

/// **Show Account Key** for a signed-in account. It is presented only after a fresh
/// device-owner authentication and dismisses itself when the app resigns active,
/// like the recovery kit.
@MainActor
final class CloudAccountKeyRevealViewController: UIViewController {
    let keyDisplay = CloudAccountKeyDisplayView()
    private let key: SnippetsCloudAccountKey
    private var inactivityObserver: NSObjectProtocol?

    init(key: SnippetsCloudAccountKey) {
        self.key = key
        super.init(nibName: nil, bundle: nil)
        title = "Account Key"
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let message = UILabel()
        message.text = SnippetsCloudAccountKeyCopy.saveMessage
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        keyDisplay.key = key
        keyDisplay.onCopy = { [key] in CloudSecretPasteboard.copy(key.displayForm) }
        let stack = UIStackView(arrangedSubviews: [message, keyDisplay])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.isHidden = false
        guard inactivityObserver == nil else { return }
        inactivityObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.view.isHidden = true
                self.dismiss(animated: false)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        keyDisplay.key = nil
        if let inactivityObserver {
            NotificationCenter.default.removeObserver(inactivityObserver)
            self.inactivityObserver = nil
        }
    }
}
