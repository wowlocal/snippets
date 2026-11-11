import AppKit
import LocalAuthentication

/// Settings → Sync → Git: connect this Mac to a Snippets library in a git repository.
///
/// The sheet owns only presentation. `GitSyncSetup` performs every repository and key
/// step; the provider switch itself stays the shared, explicit Switch and Sync.
@MainActor
final class MacGitSyncViewController: NSViewController, NSTextFieldDelegate {
    private let selection: SyncBackendSelectionStore
    private weak var coordinator: SyncCoordinator?
    private let setup: GitSyncSetup
    /// Asks the Sync pane to run its Switch and Sync confirmation for Git.
    private let requestProviderSwitch: () -> Void
    var close: (() -> Void)?

    let urlField = NSTextField()
    let branchField = NSTextField()
    let usernameField = NSTextField()
    let tokenField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let beforeYouStartLabel = NSTextField(wrappingLabelWithString: "")
    /// The connected summary: the first line bold, the details below it regular.
    private let connectedTitle = NSTextField(wrappingLabelWithString: "")
    private let connectedDetail = NSTextField(wrappingLabelWithString: "")
    private let changeHeading = NSTextField(labelWithString: "Change Connection")
    private let separator = NSBox()
    private let progress = NSProgressIndicator()
    private let switchButton = NSButton(title: "Switch and Sync", target: nil, action: nil)
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let recoveryButton = NSButton(title: "New Recovery Code…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove from This Mac…", target: nil, action: nil)
    private let removeNote = NSTextField(labelWithString: "Switch sync away from Git first.")
    private let rotateButton = NSButton(title: "Replace Keys…", target: nil, action: nil)
    private lazy var connectedActions = NSStackView(views: [
        removeButton, removeNote, NSView(), syncNowButton, switchButton,
    ])
    /// Unfolds the address and token form of a connected library.
    private let changeButton = NSButton(title: "Change Address or Token…", target: nil, action: nil)
    /// What protects the library: its recovery code and its keys.
    private lazy var keyActions = NSStackView(views: [changeButton, NSView(), rotateButton, recoveryButton])
    /// Shown only while secure snippets do not work on this Mac for the library.
    private let secureButton = NSButton(title: "Set Up Secure Snippets…", target: nil, action: nil)
    /// Shown only while sync is stopped on something reconnecting fixes.
    private let reconnectButton = NSButton(title: "Reconnect…", target: nil, action: nil)
    /// What needs the user before sync or secure snippets work.
    private lazy var secureActions = NSStackView(views: [reconnectButton, secureButton, NSView()])
    private var isEditingConnection = false
    private let tokenLinkButton = NSButton(title: "Create a Token…", target: nil, action: nil)
    private let deployKeyButton = NSButton(title: "Add Deploy Key…", target: nil, action: nil)
    private lazy var linkRow = NSStackView(views: [tokenLinkButton, deployKeyButton, NSView()])
    private var tokenLink: URL?
    private var deployKeyLink: URL?
    private var isBusy = false
    private var stateObservation: UUID?
    private var grid = NSGridView()
    private let hint = NSTextField(wrappingLabelWithString: "")

    /// Test seams: alerts are modal, so integration tests answer them directly.
    /// Nil cancels; otherwise the library mode the user chose.
    var confirmCreation: (String) -> GitLibraryMode? = MacGitSyncViewController.runCreationAlert
    var confirmReplacement: () -> Bool = MacGitSyncViewController.runReplacementAlert
    var confirmKeyRotation: () -> Bool = MacGitSyncViewController.runKeyRotationAlert
    /// Where replacing the keys records its outcome.
    var recordDiagnostic: (DiagnosticEvent) -> Void {
        get { setup.recordDiagnostic }
        set { setup.recordDiagnostic = newValue }
    }
    /// Asked when a plain-text library's repository could not be checked for privacy.
    var confirmPrivateRepository: () -> Bool = MacGitSyncViewController.runConfirmPrivateAlert
    var confirmPlainTextJoin: () -> Bool = MacGitSyncViewController.runPlainTextJoinAlert
    /// Given the explanation, whether to retry on `GitSyncSetup.suggestedBranch`.
    var offerSuggestedBranch: (String) -> Bool = MacGitSyncViewController.runSuggestedBranchAlert
    var promptForRecoveryCode: (String?) -> String? = MacGitSyncViewController.runRecoveryCodeAlert
    var presentRecoveryCode: (String, Bool) -> Void = MacGitSyncViewController.runRecoveryCodePresentation
    var presentError: (String, String) -> Void = MacGitSyncViewController.runErrorAlert
    var authenticateOwner: (String) async throws -> Void = { try await requireMacOwnerAuthentication(reason: $0) }

    init(
        selection: SyncBackendSelectionStore,
        coordinator: SyncCoordinator?,
        requestProviderSwitch: @escaping () -> Void
    ) {
        self.selection = selection
        self.coordinator = coordinator
        setup = GitSyncSetup(selection: selection, coordinator: coordinator)
        self.requestProviderSwitch = requestProviderSwitch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard stateObservation == nil else { return }
        stateObservation = coordinator?.addStateObserver { [weak self] _ in self?.reloadState() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let stateObservation { coordinator?.removeStateObserver(stateObservation) }
        stateObservation = nil
        // Done is disabled while a flow runs, so nothing still uses the scratch cache.
        if !isBusy { setup.finish() }
    }

    static let sheetWidth: CGFloat = 560

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 420))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let heading = NSTextField(labelWithString: "Git Repository")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        beforeYouStartLabel.stringValue = GitSyncSetup.beforeYouStart
        beforeYouStartLabel.font = .systemFont(ofSize: 13)
        beforeYouStartLabel.textColor = .secondaryLabelColor
        beforeYouStartLabel.setAccessibilityIdentifier("git-before-you-start")

        urlField.placeholderString = "https://github.com/you/library or git@github.com:you/library.git"
        branchField.placeholderString = "main"
        usernameField.placeholderString = "Your account name"
        tokenField.placeholderString = "Personal access token"
        urlField.setAccessibilityIdentifier("git-repository-url")
        branchField.setAccessibilityIdentifier("git-branch")
        usernameField.setAccessibilityIdentifier("git-username")
        tokenField.setAccessibilityIdentifier("git-token")
        for field in [urlField, branchField, usernameField, tokenField] as [NSTextField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        var rows: [[NSView]] = []
        for (title, field) in [("Repository:", urlField), ("Branch:", branchField),
                               ("User name:", usernameField), ("Access token:", tokenField)] as [(String, NSTextField)] {
            let label = Self.label(title)
            field.setAccessibilityTitleUIElement(label)
            rows.append([label, field])
        }
        grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.setAccessibilityIdentifier("git-hint")
        for (button, action) in [(tokenLinkButton, #selector(openTokenLink)),
                                 (deployKeyButton, #selector(openDeployKeyLink))] {
            button.target = self
            button.action = action
            // A link, not a control: it opens the host's page in the browser.
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .linkColor
        }
        Self.setLinkTitle(tokenLinkButton, "Create a Token…")
        tokenLinkButton.setAccessibilityIdentifier("git-token-link")
        deployKeyButton.setAccessibilityIdentifier("git-deploy-key-link")
        linkRow.orientation = .horizontal
        linkRow.spacing = 8

        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        connectButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        // macOS order: the default button rightmost, the dismissing one to its left.
        let buttons = NSStackView(views: [progress, NSView(), doneButton, connectButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("git-status")
        connectedTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        connectedTitle.setAccessibilityIdentifier("git-connected")
        connectedDetail.font = .systemFont(ofSize: 13)
        connectedDetail.textColor = .labelColor
        connectedDetail.setAccessibilityIdentifier("git-connected-detail")
        changeHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        removeNote.font = .systemFont(ofSize: 12)
        removeNote.textColor = .secondaryLabelColor

        for (button, action) in [(switchButton, #selector(switchPressed)),
                                 (syncNowButton, #selector(syncNowPressed)),
                                 (recoveryButton, #selector(newRecoveryCodePressed)),
                                 (rotateButton, #selector(rotateKeysPressed)),
                                 (secureButton, #selector(secureSnippetsPressed)),
                                 (reconnectButton, #selector(connectPressed)),
                                 (changeButton, #selector(changeConnectionPressed)),
                                 (removeButton, #selector(removePressed))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        // What each is for, without a line of text under every button.
        recoveryButton.toolTip = GitSyncSetup.newCodeHint
        rotateButton.toolTip = GitSyncSetup.replaceKeysHint
        reconnectButton.setAccessibilityIdentifier("git-reconnect")
        changeButton.setAccessibilityIdentifier("git-change-connection")
        removeButton.contentTintColor = .systemRed
        connectedActions.orientation = .horizontal
        connectedActions.spacing = 8
        keyActions.orientation = .horizontal
        keyActions.spacing = 8
        rotateButton.setAccessibilityIdentifier("git-replace-keys")
        secureButton.setAccessibilityIdentifier("git-secure-snippets")
        secureActions.orientation = .horizontal
        secureActions.spacing = 8

        separator.boxType = .separator
        for view in [heading, beforeYouStartLabel, connectedTitle, connectedDetail, secureActions,
                     keyActions, connectedActions, separator, changeHeading, grid, hint, linkRow, buttons,
                     statusLabel] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(4, after: connectedTitle)
        stack.setCustomSpacing(4, after: hint)
        let textWidth = Self.sheetWidth - 56
        for label in [beforeYouStartLabel, hint, statusLabel, connectedTitle, connectedDetail] {
            label.preferredMaxLayoutWidth = textWidth
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            // Equal, not less-or-equal: the sheet is as tall as what it shows.
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectedActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            secureActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            linkRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        if let saved = setup.savedForm {
            urlField.stringValue = saved.repositoryURL
            branchField.stringValue = saved.branch
            usernameField.stringValue = saved.username
        } else {
            branchField.stringValue = "main"
        }
        updateAccessMethod()
        reloadState()
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(width: Self.sheetWidth, height: view.fittingSize.height))
    }

    var showsTokenFields: Bool { !grid.row(at: 3).isHidden }
    var showsUsernameField: Bool { !grid.row(at: 2).isHidden }

    /// The form is the whole sheet until something is connected. After that it shows
    /// when asked for, or when the token it holds is what is missing.
    private var showsForm: Bool {
        selection.gitCoordinates == nil || isEditingConnection || setup.connectionFormIsRequired
    }

    /// SSH addresses use the system ssh and ssh-agent, so the name and token rows do not
    /// apply. GitHub and GitLab accept any user name with a token, so that row shows
    /// there only when a name was entered before. The guidance follows the address as it
    /// is typed: which token this host wants, or how to check the SSH host in Terminal.
    func updateAccessMethod() {
        let address = urlField.stringValue
        let ssh = GitSyncSetup.looksLikeSSH(address)
        let nameIsImplied = GitSyncSetup.defaultUsername(for: address) != nil && usernameField.stringValue.isEmpty
        grid.row(at: 2).isHidden = ssh || nameIsImplied
        grid.row(at: 3).isHidden = ssh
        let host = GitSyncSetup.hostDisplayName(of: address)
        if ssh {
            let check = setup.sshHost(form)?.testCommand ?? "ssh -T with the address’s user and host"
            hint.stringValue = "Uses this Mac’s ssh with your ssh-agent and ~/.ssh/config. If it can’t "
                + "connect, check \(check) in Terminal."
            tokenLink = nil
            deployKeyLink = GitSyncSetup.deployKeyLink(for: address)
            Self.setLinkTitle(deployKeyButton, "Add Deploy Key on \(host ?? "the Host")…")
        } else {
            // A token that is already saved needs no advice on creating one.
            let help: (text: String, link: URL?) =
                setup.showsTokenHelp(for: address) ? GitSyncSetup.tokenHelp(for: address) : ("", nil)
            hint.stringValue = help.text
            tokenLink = help.link
            deployKeyLink = nil
            Self.setLinkTitle(tokenLinkButton, "Create a Token on \(host ?? "the Host")…")
        }
        updateGuidanceVisibility()
    }

    private func updateGuidanceVisibility() {
        let shown = showsForm
        hint.isHidden = !shown || hint.stringValue.isEmpty
        tokenLinkButton.isHidden = tokenLink == nil
        deployKeyButton.isHidden = deployKeyLink == nil
        linkRow.isHidden = !shown || (tokenLink == nil && deployKeyLink == nil)
    }

    /// The link the hint offers, for tests: a token page over HTTPS, a deploy-key page
    /// over SSH.
    var guidanceLink: URL? { tokenLink ?? deployKeyLink }
    var hintText: String { hint.stringValue }

    private static func setLinkTitle(_ button: NSButton, _ title: String) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12),
        ])
        button.setAccessibilityLabel(title)
    }

    @objc private func openTokenLink() {
        if let tokenLink { NSWorkspace.shared.open(tokenLink) }
    }

    @objc private func openDeployKeyLink() {
        if let deployKeyLink { NSWorkspace.shared.open(deployKeyLink) }
    }

    var form: GitSyncSetup.Form {
        GitSyncSetup.Form(
            repositoryURL: urlField.stringValue, branch: branchField.stringValue,
            username: usernameField.stringValue, token: tokenField.stringValue)
    }

    var statusText: String { statusLabel.stringValue }
    var setupStatus: GitSyncSetup.SecureSnippetsStatus { setup.secureSnippetsStatus }
    var connectedText: String {
        connectedTitle.isHidden ? "" : [connectedTitle.stringValue, connectedDetail.stringValue].joined(separator: "\n")
    }

    func reloadState() {
        guard isViewLoaded else { return }
        let configured = selection.gitCoordinates
        let ready = selection.gitIsReady
        let active = selection.provider == .git
        let showsForm = showsForm
        for view in [connectedTitle, connectedDetail, connectedActions, keyActions] as [NSView] {
            view.isHidden = configured == nil
        }
        // A connected library folds its address and token away until asked.
        for view in [separator, changeHeading] as [NSView] { view.isHidden = configured == nil || !showsForm }
        grid.isHidden = !showsForm
        connectButton.isHidden = !showsForm
        beforeYouStartLabel.isHidden = configured != nil
        connectButton.title = configured == nil ? "Connect" : "Update"
        tokenField.placeholderString = selection.hasStoredGitToken
            ? "Saved. Leave empty to keep it." : "Personal access token"
        if let configured {
            connectedTitle.stringValue = "\(configured.displayLocation) · \(configured.branch)"
            connectedDetail.stringValue = setup.connectedSummary(deviceName: "Mac").joined(separator: "\n")
        }
        changeButton.title = isEditingConnection
            ? "Hide Connection Details"
            : (configured?.usesSSH == true ? "Change Address…" : "Change Address or Token…")
        // Nothing to fold away while the form has to be on screen.
        changeButton.isHidden = setup.connectionFormIsRequired
        switchButton.isHidden = active || !ready
        syncNowButton.isHidden = !active || !ready
        recoveryButton.isHidden = !ready
        // Replacing the keys re-uploads the library, so it needs Git to be syncing it.
        rotateButton.isHidden = !ready || !active
        let secureStatus = setup.secureSnippetsStatus
        secureButton.isHidden = !(secureStatus == .needsSetup || secureStatus == .needsRecoveryCode)
        reconnectButton.isHidden = !setup.needsReconnect
        secureActions.isHidden = configured == nil || (secureButton.isHidden && reconnectButton.isHidden)
        // Shown but disabled while Git is in use, with the reason beside it.
        removeNote.isHidden = !active
        // The next step is the default button: Switch and Sync once it is offered.
        let switchIsNext = !switchButton.isHidden && configured != nil
        switchButton.keyEquivalent = switchIsNext ? "\r" : ""
        connectButton.keyEquivalent = switchIsNext || !showsForm ? "" : "\r"
        // An empty status line takes no room in a sheet sized to its content.
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        updateGuidanceVisibility()
        let enabled = !isBusy
        for control in [connectButton, doneButton, switchButton, syncNowButton, recoveryButton, rotateButton,
                        secureButton, reconnectButton, changeButton,
                        urlField, branchField, usernameField, tokenField] as [NSControl] {
            control.isEnabled = enabled
        }
        removeButton.isEnabled = enabled && !active
    }

    /// For tests: whether the address and token form is on screen, and whether the
    /// sheet offers to reconnect.
    var showsConnectionForm: Bool { !grid.isHidden }
    var offersReconnect: Bool { !reconnectButton.isHidden && !secureActions.isHidden }
    func toggleConnectionForm() { changeConnectionPressed() }

    @objc private func changeConnectionPressed() {
        isEditingConnection.toggle()
        statusLabel.stringValue = ""
        // Folding the form away abandons what was typed into it: Reconnect must use
        // the connection that is saved, not a half-edited one.
        if !isEditingConnection, let saved = setup.savedForm {
            urlField.stringValue = saved.repositoryURL
            branchField.stringValue = saved.branch
            usernameField.stringValue = saved.username
            tokenField.stringValue = ""
        }
        updateAccessMethod()
        reloadState()
        if isEditingConnection { view.window?.makeFirstResponder(urlField) }
    }

    // MARK: - Actions

    @objc func connectPressed() {
        Task { await connect() }
    }

    /// The whole connect flow. Returns when it has finished or stopped for the user.
    func connect() async {
        guard !isBusy else { return }
        var form = form
        setBusy(true, "Checking the repository…")
        defer { setBusy(false, nil) }
        do {
            var inspection = try await setup.inspect(form)
            while true {
                switch inspection {
                case .foreign:
                    let suggested = GitSyncSetup.suggestedBranch
                    guard form.branch.trimmingCharacters(in: .whitespacesAndNewlines) != suggested else {
                        throw GitSyncSetup.Failure.foreignBranch
                    }
                    guard offerSuggestedBranch(GitSyncSetup.Failure.foreignBranch.errorDescription ?? "") else {
                        statusLabel.stringValue = "Not connected."
                        return
                    }
                    branchField.stringValue = suggested
                    form.branch = suggested
                    setBusy(true, "Checking the branch “\(suggested)”…")
                    inspection = try await setup.inspect(form)
                    continue
                case .empty:
                    guard let mode = confirmCreation(Self.displayName(of: form)) else {
                        statusLabel.stringValue = "Nothing was created."
                        return
                    }
                    var confirmedPrivate = false
                    if mode == .plainText {
                        setBusy(true, "Checking that the repository is private…")
                        switch try await setup.repositoryVisibility(form) {
                        case .isPublic:
                            presentError(
                                "This Repository Is Public",
                                GitSyncSetup.Failure.publicRepository.errorDescription ?? "")
                            setBusy(true, "Checking the repository…")
                            continue
                        case .unknown:
                            guard confirmPrivateRepository() else {
                                statusLabel.stringValue = "Nothing was created."
                                return
                            }
                            confirmedPrivate = true
                        case .isPrivate:
                            break
                        }
                    }
                    setBusy(true, "Creating the library…")
                    do {
                        if case .created(let code) = try await setup.createLibrary(
                            form, mode: mode, confirmedPrivate: confirmedPrivate) {
                            presentRecoveryCode(code, selection.gitKeys.syncsBetweenDevices)
                        }
                    } catch GitSyncSetup.Failure.libraryExists {
                        inspection = try await setup.inspect(form)
                        continue
                    } catch GitSyncSetup.Failure.publicRepository {
                        // Nothing was created: explain, then offer the choice again.
                        presentError(
                            "This Repository Is Public",
                            GitSyncSetup.Failure.publicRepository.errorDescription ?? "")
                        setBusy(true, "Checking the repository…")
                        continue
                    } catch let failure as GitSyncSetup.Failure {
                        switch failure {
                        case .createdButNotSaved(let code), .creationUncertain(let code):
                            presentRecoveryCode(code, selection.gitKeys.syncsBetweenDevices)
                        default:
                            break
                        }
                        throw failure
                    }
                case .library(let datasetID, let keyAvailable, let recoveryAvailable, let mode):
                    if setup.needsPlainTextConsent(datasetID: datasetID, mode: mode, form: form),
                       !confirmPlainTextJoin() {
                        statusLabel.stringValue = "Not connected."
                        return
                    }
                    if setup.replacesActiveLibrary(form, datasetID: datasetID) {
                        guard confirmReplacement() else {
                            statusLabel.stringValue = "Not connected."
                            return
                        }
                    }
                    if keyAvailable {
                        setBusy(true, "Connecting…")
                        do {
                            _ = try await setup.connect(form, datasetID: datasetID, mode: mode)
                        } catch GitSyncSetup.Failure.recoveryCodeRequired {
                            // The library key is here (iCloud Keychain); moving this Mac's
                            // secure snippets to the library's new key takes the code.
                            guard try await joinWithRecoveryCode(form, datasetID: datasetID, mode: mode) else {
                                statusLabel.stringValue = "Not connected. This Mac needs the library’s recovery code."
                                return
                            }
                        }
                    } else {
                        guard recoveryAvailable else { throw GitSyncSetup.Failure.recoveryUnavailable }
                        guard try await joinWithRecoveryCode(form, datasetID: datasetID, mode: mode) else {
                            statusLabel.stringValue = "Not connected. This Mac needs the library’s recovery code."
                            return
                        }
                    }
                }
                break
            }
            tokenField.stringValue = ""
            // The connection is as the form says now; fold the form away again.
            isEditingConnection = false
            updateAccessMethod()
            statusLabel.stringValue = setup.secureSnippetsStatus == .needsRecoveryCode
                ? "Connected. Secure snippets still need the recovery code: click Set Up Secure Snippets."
                : "Connected."
            await connected()
        } catch {
            statusLabel.stringValue = ""
            presentError("Couldn’t Connect the Repository", Self.message(for: error))
        }
    }

    /// User-facing text only: setup failures carry their own sentences; anything else
    /// gets a fixed fallback rather than a framework or enum description.
    static func message(for error: any Error) -> String {
        if let failure = error as? GitSyncSetup.Failure, let text = failure.errorDescription { return text }
        return GitSyncSetup.fallbackMessage
    }

    private static func isAuthenticationCancel(_ error: any Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return [.userCancel, .appCancel, .systemCancel].contains(error.code)
    }

    private func joinWithRecoveryCode(
        _ form: GitSyncSetup.Form, datasetID: UUID, mode: GitLibraryMode
    ) async throws -> Bool {
        var problem: String?
        while let code = promptForRecoveryCode(problem) {
            do {
                setBusy(true, "Opening the library…")
                _ = try await setup.connect(form, datasetID: datasetID, recoveryCode: code, mode: mode)
                return true
            } catch let failure as GitSyncSetup.Failure
                        where [.invalidRecoveryCode, .incorrectRecoveryCode, .recoveryCodeRequired,
                               .incorrectVaultRecoveryCode].contains(failure) {
                problem = failure.errorDescription
            }
        }
        return false
    }

    private func connected() async {
        reloadState()
        if selection.provider == .git {
            _ = await coordinator?.requestSync(trigger: .manual)
            reloadState()
        } else {
            setup.finish()
            close?()
            requestProviderSwitch()
        }
    }

    @objc private func switchPressed() {
        close?()
        requestProviderSwitch()
    }

    @objc private func syncNowPressed() {
        coordinator?.syncNow()
        reloadState()
    }

    @objc private func newRecoveryCodePressed() {
        let alert = NSAlert()
        alert.messageText = "Create a New Recovery Code?"
        alert.informativeText = setup.newCodeExplanation
        alert.addButton(withTitle: "Create Code")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await replaceRecoveryCode() }
    }

    func replaceRecoveryCode() async {
        setBusy(true, "Creating a new recovery code…")
        defer { setBusy(false, nil) }
        do {
            // A vault on this Mac is unlocked to wrap its key under the new code, which
            // is the owner check; the setup asks through this only when it is not.
            let code = try await setup.replaceRecoveryCode(authenticateOwner: authenticateOwner)
            presentRecoveryCode(code, selection.gitKeys.syncsBetweenDevices)
        } catch where Self.isAuthenticationCancel(error) {
            statusLabel.stringValue = ""
        } catch {
            presentError("Couldn’t Create a Recovery Code", Self.message(for: error))
        }
    }

    @objc private func rotateKeysPressed() {
        guard confirmKeyRotation() else { return }
        Task { await rotateKeys() }
    }

    /// Replaces the library's keys and shows the new recovery code.
    func rotateKeys() async {
        guard !isBusy else { return }
        setBusy(true, "Replacing the library’s keys…")
        defer { setBusy(false, nil) }
        do {
            // Re-sealing the secure snippets unlocks the vault, which is the owner check.
            // A Mac with none to re-seal is asked through this instead.
            let code = try await setup.rotateKeys(authenticateOwner: authenticateOwner)
            presentRecoveryCode(code, selection.gitKeys.syncsBetweenDevices)
            statusLabel.stringValue = "Keys replaced. Reconnect your other devices with the new recovery code."
            _ = await coordinator?.requestSync(trigger: .manual)
        } catch where Self.isAuthenticationCancel(error) {
            statusLabel.stringValue = ""
        } catch {
            statusLabel.stringValue = ""
            if let failure = error as? GitSyncSetup.Failure {
                switch failure {
                case .rotatedButNotSaved(let code), .rotationUncertain(let code):
                    presentRecoveryCode(code, selection.gitKeys.syncsBetweenDevices)
                    presentError("Couldn’t Replace the Keys", Self.message(for: error))
                    // A round shows whether the repository took the new keys, and with
                    // that whether this sheet should offer Reconnect.
                    _ = await coordinator?.requestSync(trigger: .manual)
                    return
                default:
                    break
                }
            }
            presentError("Couldn’t Replace the Keys", Self.message(for: error))
        }
    }

    @objc private func secureSnippetsPressed() {
        Task { await setUpSecureSnippets() }
    }

    /// Makes secure snippets work on this Mac for the connected library: with the
    /// recovery code when the library has a vault, or with a new vault and a new code
    /// when it was created before libraries had one.
    func setUpSecureSnippets() async {
        guard !isBusy else { return }
        setBusy(true, "Checking the library…")
        defer { setBusy(false, nil) }
        var code: String?
        var problem: String?
        do {
            while true {
                do {
                    if case .created(let newCode) = try await setup.setUpSecureSnippets(
                        recoveryCode: code, authenticateOwner: authenticateOwner) {
                        presentRecoveryCode(newCode, selection.gitKeys.syncsBetweenDevices)
                    }
                    break
                } catch let failure as GitSyncSetup.Failure
                            where [.recoveryCodeRequired, .invalidRecoveryCode, .incorrectVaultRecoveryCode]
                                .contains(failure) {
                    if code != nil { problem = failure.errorDescription }
                    guard let entered = promptForRecoveryCode(problem) else {
                        statusLabel.stringValue = "Secure snippets are still locked on this Mac."
                        return
                    }
                    code = entered
                    setBusy(true, "Opening secure snippets…")
                }
            }
            statusLabel.stringValue = "Secure snippets are ready on this Mac."
            if selection.provider == .git { _ = await coordinator?.requestSync(trigger: .manual) }
        } catch where Self.isAuthenticationCancel(error) {
            statusLabel.stringValue = ""
        } catch {
            presentError("Couldn’t Set Up Secure Snippets", Self.message(for: error))
        }
    }

    @objc private func removePressed() {
        let alert = NSAlert()
        alert.messageText = "Remove the Repository from This Mac?"
        alert.informativeText = GitSyncSetup.removeMessage
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try setup.disconnect()
            isEditingConnection = false
            urlField.stringValue = ""
            branchField.stringValue = "main"
            usernameField.stringValue = ""
            updateAccessMethod()
            tokenField.placeholderString = "Personal access token"
            statusLabel.stringValue = "Removed from this Mac."
        } catch {
            presentError("Couldn’t Remove the Repository", Self.message(for: error))
        }
        reloadState()
    }

    @objc private func donePressed() { close?() }

    func controlTextDidChange(_ notification: Notification) {
        if !isBusy {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        }
        if (notification.object as? NSTextField) === urlField { updateAccessMethod() }
    }

    private func setBusy(_ busy: Bool, _ message: String?) {
        isBusy = busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if let message { statusLabel.stringValue = message }
        reloadState()
    }

    // MARK: - Alerts

    private static func displayName(of form: GitSyncSetup.Form) -> String {
        let trimmed = form.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = form.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed) · branch \(branch.isEmpty ? "main" : branch)"
    }

    /// Encrypted unless the user asks for plain text, whose cost is explained only then.
    private static func runCreationAlert(_ repository: String) -> GitLibraryMode? {
        while true {
            let alert = NSAlert()
            alert.messageText = GitSyncSetup.createLibraryTitle
            alert.informativeText = GitSyncSetup.createLibraryMessage(repository)
            alert.addButton(withTitle: GitSyncSetup.createLibraryAction)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: GitSyncSetup.plainTextInsteadAction)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .encrypted
            case .alertThirdButtonReturn:
                let plainText = NSAlert()
                plainText.alertStyle = .warning
                plainText.messageText = GitSyncSetup.plainTextLibraryTitle
                plainText.informativeText = GitSyncSetup.plainTextLibraryMessage
                plainText.addButton(withTitle: GitSyncSetup.plainTextLibraryAction)
                // Back returns to the first question instead of abandoning the setup.
                plainText.addButton(withTitle: "Back")
                if plainText.runModal() == .alertFirstButtonReturn { return .plainText }
            default:
                return nil
            }
        }
    }

    private static func runConfirmPrivateAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = GitSyncSetup.visibilityUnknownTitle
        alert.informativeText = GitSyncSetup.visibilityUnknownMessage
        alert.addButton(withTitle: "It’s Private")
        alert.addButton(withTitle: "Cancel")
        // Return cancels: a wrong answer publishes snippets.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runPlainTextJoinAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Join a Plain-Text Library?"
        alert.informativeText = GitSyncSetup.plainTextJoinMessage(deviceName: "Mac")
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        // Return cancels: joining publishes this Mac's snippets.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runSuggestedBranchAlert(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = GitSyncSetup.foreignBranchTitle
        alert.informativeText = message
        alert.addButton(withTitle: "Use Branch “\(GitSyncSetup.suggestedBranch)”")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runReplacementAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = GitSyncSetup.replacementTitle
        alert.informativeText = GitSyncSetup.replacementMessage(deviceName: "Mac")
        alert.addButton(withTitle: GitSyncSetup.replacementAction)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runKeyRotationAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace This Library’s Keys?"
        alert.informativeText = GitSyncSetup.keyRotationExplanation
        alert.addButton(withTitle: "Replace Keys")
        alert.addButton(withTitle: "Cancel")
        // Return cancels: every other device has to be reconnected afterwards.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runRecoveryCodeAlert(_ problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter the Recovery Code"
        alert.informativeText = (problem.map { $0 + "\n\n" } ?? "") + GitSyncSetup.recoveryCodePrompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private static func runRecoveryCodePresentation(_ code: String, _ keychainSyncs: Bool) {
        let alert = NSAlert()
        alert.messageText = "Save Your Recovery Code"
        alert.informativeText = GitSyncSetup.recoveryCodeExplanation(keychainSyncs: keychainSyncs)

        let field = NSTextField(labelWithString: code)
        field.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        // Not selectable: Command-C would bypass the concealed, this-Mac-only copy.
        field.isSelectable = false
        field.setAccessibilityIdentifier("git-recovery-code")
        field.setAccessibilityLabel("Recovery code")
        // Read character by character, not as words and numbers.
        field.setAccessibilityValueDescription(code.map { $0 == "-" ? "dash" : String($0) }.joined(separator: " "))
        let copied = NSTextField(labelWithString: GitSyncSetup.recoveryCodeCopied)
        copied.font = .systemFont(ofSize: 12)
        copied.textColor = .secondaryLabelColor
        // Laid out from the start (the alert sizes its accessory once), shown on Copy.
        copied.alphaValue = 0
        copied.setAccessibilityElement(false)
        let accessory = NSStackView(views: [field, copied])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.setFrameSize(accessory.fittingSize)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Done, I’ve Saved It")
        let copyButton = alert.addButton(withTitle: "Copy")
        // Copying keeps the alert open and confirms in place.
        let copier = RecoveryCodeCopier(code: code, confirmation: copied)
        copyButton.target = copier
        copyButton.action = #selector(RecoveryCodeCopier.copy(_:))
        withExtendedLifetime(copier) { _ = alert.runModal() }
    }

    /// The Copy button's target, so copying does not end the alert.
    private final class RecoveryCodeCopier: NSObject {
        let code: String
        weak var confirmation: NSTextField?

        init(code: String, confirmation: NSTextField) {
            self.code = code
            self.confirmation = confirmation
        }

        @objc func copy(_ sender: Any?) {
            MacGitSyncViewController.copyConcealed(code)
            confirmation?.alphaValue = 1
            confirmation?.setAccessibilityElement(true)
            NSAccessibility.post(
                element: confirmation as Any, notification: .announcementRequested,
                userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Marked for clipboard managers (including this app's own history) to skip, and
    /// kept off Universal Clipboard.
    fileprivate static func copyConcealed(_ text: String) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects([item])
        // Like iOS's expiring copy: clear it after two minutes unless something newer
        // replaced it in the meantime.
        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }

    private static func runErrorAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }
}
