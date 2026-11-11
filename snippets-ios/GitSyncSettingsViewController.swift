import LocalAuthentication
import UIKit
import UniformTypeIdentifiers

/// Settings → Sync → Git: connect this device to a Snippets library in a git repository.
///
/// Presentation only. `GitSyncSetup` performs every repository and key step, and the
/// provider switch stays the shared, explicit Switch and Sync in the Sync pane.
@MainActor
final class GitSyncSettingsViewController: UITableViewController, UITextFieldDelegate {
    private enum Section: Hashable { case intro, connected, repository, sshKey, connect }
    private enum SSHKeyRow: Hashable { case steps, key, copy, addDeployKey, share }
    private enum ConnectRow: Hashable { case createToken, connect }
    private enum Field: Int, CaseIterable {
        case url, branch, username, token

        var title: String {
            switch self {
            case .url: "Repository"
            case .branch: "Branch"
            case .username: "User Name"
            case .token: "Access Token"
            }
        }

        var identifier: String {
            switch self {
            case .url: "git-repository-url"
            case .branch: "git-branch"
            case .username: "git-username"
            case .token: "git-token"
            }
        }
    }
    private enum ConnectedRow: Hashable {
        case summary, reconnect, secureSnippets, switchProvider, syncNow, newRecoveryCode, replaceKeys,
             changeConnection, remove
    }

    private let environment: AppEnvironment
    private let setup: GitSyncSetup
    private let requestProviderSwitch: () -> Void
    /// Created once, so reloading rows never discards what the user is typing.
    private var fields: [Field: UITextField] = [:]
    private var status = "" {
        didSet {
            guard status != oldValue, !status.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: status)
        }
    }
    private var isBusy = false
    private var stateObservation: UUID?
    /// The address is an SSH one: no user name or token, and this device's key applies.
    private var usesSSH = false
    /// The form rows on screen. Kept, not derived, so typing can animate from the rows
    /// that are there to the rows the new address needs.
    private var visibleFields: [Field] = []
    /// A connected library folds its address and token away until the user asks.
    private var isEditingConnection = false
    private var devicePublicKey: String?
    /// The host-specific links last shown, so typing reloads their rows only on change.
    private var shownLinks: (token: URL?, deployKey: URL?) = (nil, nil)
    private var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    init(environment: AppEnvironment, requestProviderSwitch: @escaping () -> Void) {
        self.environment = environment
        setup = GitSyncSetup(selection: environment.backendSelection, coordinator: environment.syncCoordinator)
        self.requestProviderSwitch = requestProviderSwitch
        super.init(style: .insetGrouped)
        let saved = setup.savedForm
        for field in Field.allCases {
            let text = makeTextField(field)
            switch field {
            case .url: text.text = saved?.repositoryURL
            case .branch: text.text = saved?.branch ?? "main"
            case .username: text.text = saved?.username
            case .token: break
            }
            fields[field] = text
        }
        usesSSH = GitSyncSetup.looksLikeSSH(saved?.repositoryURL ?? "")
        visibleFields = fields(ssh: usesSSH)
        fields[.url]?.addTarget(self, action: #selector(repositoryChanged), for: .editingChanged)
        shownLinks = currentLinks
    }

    /// The form is the whole screen until something is connected. After that it shows
    /// when asked for, or when the token it holds is what is missing.
    private var showsForm: Bool {
        selection.gitCoordinates == nil || isEditingConnection || setup.connectionFormIsRequired
    }

    /// When connected, what is connected comes first; the form below changes it.
    private var sections: [Section] {
        var list: [Section] = [selection.gitCoordinates != nil ? .connected : .intro]
        guard showsForm else { return list }
        list.append(.repository)
        if usesSSH, selection.gitSSH?.device != nil { list.append(.sshKey) }
        list.append(.connect)
        return list
    }

    private var repositoryText: String { fields[.url]?.text ?? "" }

    private var currentLinks: (token: URL?, deployKey: URL?) {
        if usesSSH { return (nil, GitSyncSetup.deployKeyLink(for: repositoryText)) }
        return (setup.showsTokenHelp(for: repositoryText) ? GitSyncSetup.tokenHelp(for: repositoryText).link : nil, nil)
    }

    private var sshKeyRows: [SSHKeyRow] {
        [.steps, .key, .copy] + (shownLinks.deployKey != nil ? [.addDeployKey] : []) + [.share]
    }

    private var connectRows: [ConnectRow] {
        (shownLinks.token != nil ? [.createToken] : []) + [.connect]
    }

    private var hostName: String { GitSyncSetup.hostDisplayName(of: repositoryText) ?? "the host" }

    /// The fields an address needs. SSH takes neither name nor token. GitHub and GitLab
    /// accept any user name with a token, so that field shows there only when a name
    /// was entered before.
    private func fields(ssh: Bool) -> [Field] {
        if ssh { return [.url, .branch] }
        let nameIsImplied = GitSyncSetup.defaultUsername(for: repositoryText) != nil
            && (fields[.username]?.text ?? "").isEmpty
        return nameIsImplied ? [.url, .branch, .token] : Field.allCases
    }

    /// Shows or hides the name and token rows and the device key as the address changes,
    /// without reloading (and so defocusing) the address field itself.
    @objc private func repositoryChanged() {
        let now = GitSyncSetup.looksLikeSSH(repositoryText)
        let fieldsNow = fields(ssh: now)
        guard isViewLoaded else {
            usesSSH = now
            visibleFields = fieldsNow
            return
        }
        guard now != usesSSH || fieldsNow != visibleFields else {
            refreshHostGuidance()
            return
        }
        let before = sections
        guard let repository = before.firstIndex(of: .repository) else {
            usesSSH = now
            visibleFields = fieldsNow
            return
        }
        // Batch updates require the table's cached counts to match the model before the
        // change. If something else changed it unannounced (a key arriving through iCloud
        // Keychain, say), reload instead and keep typing in the same field.
        let consistent = tableMatchesModel()
        let fieldsBefore = visibleFields
        usesSSH = now
        visibleFields = fieldsNow
        guard consistent else {
            shownLinks = currentLinks
            reloadKeepingFocus()
            return
        }
        let after = sections
        // Deletions name rows as they were, insertions rows as they will be.
        let removedRows = fieldsBefore.enumerated().filter { !fieldsNow.contains($0.element) }
            .map { IndexPath(row: $0.offset, section: repository) }
        let addedRows = fieldsNow.enumerated().filter { !fieldsBefore.contains($0.element) }
            .map { IndexPath(row: $0.offset, section: repository) }
        let oldConnectRows = connectRows.count
        shownLinks = currentLinks
        tableView.performBatchUpdates {
            tableView.deleteRows(at: removedRows, with: .fade)
            tableView.insertRows(at: addedRows, with: .fade)
            if let removed = before.firstIndex(of: .sshKey), !after.contains(.sshKey) {
                tableView.deleteSections(IndexSet(integer: removed), with: .fade)
            }
            if let added = after.firstIndex(of: .sshKey), !before.contains(.sshKey) {
                tableView.insertSections(IndexSet(integer: added), with: .fade)
            }
            // Deletions name pre-update indexes, insertions post-update ones; the SSH key
            // section between them may have just gone or arrived.
            if oldConnectRows > connectRows.count, let connect = before.firstIndex(of: .connect) {
                tableView.deleteRows(at: [IndexPath(row: 0, section: connect)], with: .fade)
            } else if oldConnectRows < connectRows.count, let connect = after.firstIndex(of: .connect) {
                tableView.insertRows(at: [IndexPath(row: 0, section: connect)], with: .fade)
            }
        }
        updateRepositoryFooter()
    }

    /// The token or deploy-key link and help follow the host as it is typed. Only
    /// sections without the address field reload, so typing keeps its focus.
    private func refreshHostGuidance() {
        guard tableMatchesModel() else {
            shownLinks = currentLinks
            reloadKeepingFocus()
            return
        }
        updateRepositoryFooter()
        let links = currentLinks
        guard links.token != shownLinks.token || links.deployKey != shownLinks.deployKey else { return }
        shownLinks = links
        let reload = IndexSet([sections.firstIndex(of: .sshKey), sections.firstIndex(of: .connect)].compactMap { $0 })
        tableView.reloadSections(reload, with: .none)
    }

    /// The repository section's footer. Its text follows the address as it is typed, so
    /// the view is owned here, not taken from the table's pool: a pooled view that was
    /// given this text came back after a reload as another section's footer, still
    /// showing it.
    private let repositoryFooterView = UITableViewHeaderFooterView(reuseIdentifier: nil)

    private func configureRepositoryFooter() {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = repositoryFooter
        repositoryFooterView.contentConfiguration = content
    }

    /// Batch updates leave section footers alone; this one depends on the address.
    private func updateRepositoryFooter() {
        guard tableMatchesModel() else { return reloadKeepingFocus() }
        guard sections.contains(.repository) else { return }
        configureRepositoryFooter()
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil)
        }
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard sections[section] == .repository else { return nil }
        configureRepositoryFooter()
        return repositoryFooterView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selection: SyncBackendSelectionStore { environment.backendSelection }

    /// Whether the table's cached section and row counts match the model, which partial
    /// updates (batch updates, section reloads) require.
    private func tableMatchesModel() -> Bool {
        let list = sections
        guard tableView.numberOfSections == list.count else { return false }
        return list.indices.allSatisfy {
            tableView.numberOfRows(inSection: $0) == self.tableView(tableView, numberOfRowsInSection: $0)
        }
    }

    private func reloadKeepingFocus() {
        let focused = fields.values.first { $0.isFirstResponder }
        tableView.reloadData()
        focused?.becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Git Repository"
        navigationItem.largeTitleDisplayMode = .never
        tableView.keyboardDismissMode = .interactive
        stateObservation = environment.syncCoordinator.addStateObserver { [weak self] _ in
            self?.reloadConnectedSection()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Settings search (on iPad, beside this screen) may still hold the keyboard.
        if !fields.values.contains(where: \.isFirstResponder) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let leaving = isMovingFromParent || navigationController?.isBeingDismissed == true
            || navigationController == nil
        guard leaving, !isBusy else { return }
        if let stateObservation { environment.syncCoordinator.removeStateObserver(stateObservation) }
        stateObservation = nil
        setup.finish()
    }

    private var form: GitSyncSetup.Form {
        GitSyncSetup.Form(
            repositoryURL: fields[.url]?.text ?? "", branch: fields[.branch]?.text ?? "",
            username: fields[.username]?.text ?? "", token: fields[.token]?.text ?? "")
    }

    /// Puts the saved connection back into the fields.
    private func restoreSavedForm() {
        guard let saved = setup.savedForm else { return }
        fields[.url]?.text = saved.repositoryURL
        fields[.branch]?.text = saved.branch
        fields[.username]?.text = saved.username
        fields[.token]?.text = ""
        usesSSH = GitSyncSetup.looksLikeSSH(saved.repositoryURL)
    }

    private var connectedRows: [ConnectedRow] {
        guard selection.gitCoordinates != nil else { return [] }
        let ready = selection.gitIsReady
        let active = selection.provider == .git
        var rows: [ConnectedRow] = [.summary]
        // What needs the user comes first.
        if setup.needsReconnect { rows.append(.reconnect) }
        // Only while secure snippets do not work here for this library.
        switch setup.secureSnippetsStatus {
        case .needsSetup, .needsRecoveryCode: rows.append(.secureSnippets)
        case .ready, .unavailable: break
        }
        if ready { rows.append(active ? .syncNow : .switchProvider) }
        if ready { rows.append(.newRecoveryCode) }
        // Replacing the keys re-uploads the library, so it needs Git to be syncing it.
        if ready, active { rows.append(.replaceKeys) }
        // Nothing to fold away while the form has to be on screen.
        if !setup.connectionFormIsRequired { rows.append(.changeConnection) }
        // Shown while Git is active too, disabled with the reason.
        rows.append(.remove)
        return rows
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .intro: 0
        case .repository: visibleFields.count
        case .sshKey: sshKeyRows.count
        case .connect: connectRows.count
        case .connected: connectedRows.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .intro: nil
        // Before connecting, the first field is already labeled Repository.
        case .repository: selection.gitCoordinates != nil ? "Change Connection" : nil
        case .sshKey: "This \(deviceName)’s SSH Key"
        case .connect: nil
        case .connected: "Connected Library"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .intro:
            GitSyncSetup.beforeYouStart
        case .repository:
            // `repositoryFooterView` shows it.
            nil
        case .sshKey:
            "Each device has its own key. The private half never leaves this \(deviceName)."
        case .connect:
            status.isEmpty ? nil : status
        case .connected:
            // With the form folded away this is where an action reports its result.
            showsForm || status.isEmpty ? nil : status
        }
    }

    /// What kind of token the host wants, while that is still useful.
    private var repositoryFooter: String? {
        guard !usesSSH, setup.showsTokenHelp(for: repositoryText) else { return nil }
        let help = GitSyncSetup.tokenHelp(for: repositoryText).text
        return help.isEmpty ? nil : help
    }

    private func actionCell(_ title: String, identifier: String? = nil) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.textLabel?.textColor = AppTheme.tint
        cell.textLabel?.numberOfLines = 0
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = identifier
        return cell
    }

    private func sshKeyCell(_ row: SSHKeyRow) -> UITableViewCell {
        switch row {
        case .steps:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Add this key to the repository as a deploy key with write access, "
                + "then tap Connect."
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "git-ssh-steps"
            return cell
        case .key:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            if devicePublicKey == nil { devicePublicKey = try? setup.devicePublicKey() }
            cell.textLabel?.text = devicePublicKey ?? "The device key is unavailable. Unlock the device and try again."
            cell.textLabel?.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            // Nobody reads a key: one line shows which it is, and Copy takes all of it.
            cell.textLabel?.numberOfLines = devicePublicKey == nil ? 0 : 1
            cell.textLabel?.lineBreakMode = devicePublicKey == nil ? .byWordWrapping : .byTruncatingMiddle
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "git-ssh-public-key"
            if let key = devicePublicKey {
                let encoded = key.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                cell.accessibilityLabel = "SSH public key, ending in \(encoded.suffix(6)). Use Copy Public Key to add it."
            }
            return cell
        case .copy:
            return actionCell("Copy Public Key", identifier: "git-ssh-copy-key")
        case .addDeployKey:
            return actionCell("Add Deploy Key on \(hostName)…", identifier: "git-ssh-add-deploy-key")
        case .share:
            return actionCell("Share Public Key…", identifier: "git-ssh-share-key")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .intro:
            return UITableViewCell()
        case .repository:
            return fieldCell(visibleFields[indexPath.row])
        case .sshKey:
            return sshKeyCell(sshKeyRows[indexPath.row])
        case .connect:
            if connectRows[indexPath.row] == .createToken {
                return actionCell("Create a Token on \(hostName)…", identifier: "git-create-token")
            }
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = isBusy ? "Working…" : (selection.gitCoordinates != nil ? "Update" : "Connect")
            cell.textLabel?.textColor = isBusy ? .secondaryLabel : AppTheme.tint
            cell.accessibilityIdentifier = "git-connect"
            cell.accessibilityTraits = isBusy ? [.button, .notEnabled] : .button
            if isBusy {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            return cell
        case .connected:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.numberOfLines = 0
            cell.detailTextLabel?.numberOfLines = 0
            cell.detailTextLabel?.textColor = .secondaryLabel
            switch connectedRows[indexPath.row] {
            case .summary:
                let coordinates = selection.gitCoordinates
                cell.textLabel?.text = coordinates.map { "\($0.displayLocation) · \($0.branch)" }
                cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
                cell.detailTextLabel?.text = setup.connectedSummary(deviceName: deviceName).joined(separator: "\n")
                cell.selectionStyle = .none
                cell.accessibilityIdentifier = "git-connected"
            case .reconnect:
                cell.textLabel?.text = "Reconnect…"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "git-reconnect"
            case .secureSnippets:
                cell.textLabel?.text = "Set Up Secure Snippets…"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "git-secure-snippets"
            case .switchProvider:
                cell.textLabel?.text = "Switch and Sync"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "git-switch"
            case .syncNow:
                cell.textLabel?.text = "Sync Now"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
            case .newRecoveryCode:
                cell.textLabel?.text = "New Recovery Code…"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.detailTextLabel?.text = GitSyncSetup.newCodeHint
            case .replaceKeys:
                cell.textLabel?.text = "Replace Keys…"
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "git-replace-keys"
                cell.detailTextLabel?.text = GitSyncSetup.replaceKeysHint
            case .changeConnection:
                cell.textLabel?.text = isEditingConnection
                    ? "Hide Connection Details"
                    : (selection.gitCoordinates?.usesSSH == true ? "Change Address…" : "Change Address or Token…")
                cell.textLabel?.textColor = AppTheme.tint
                cell.accessibilityTraits = .button
                cell.accessibilityIdentifier = "git-change-connection"
            case .remove:
                let active = selection.provider == .git
                cell.textLabel?.text = "Remove from This \(deviceName)…"
                cell.textLabel?.textColor = active ? .secondaryLabel : .systemRed
                cell.accessibilityTraits = active ? [.button, .notEnabled] : .button
                cell.selectionStyle = active ? .none : .default
                cell.detailTextLabel?.text = active ? "Switch sync away from Git first." : nil
            }
            return cell
        }
    }

    private func makeTextField(_ field: Field) -> UITextField {
        let text = UITextField()
        text.tag = field.rawValue + 1
        text.delegate = self
        text.accessibilityIdentifier = field.identifier
        text.accessibilityLabel = field.title
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.autocapitalizationType = .none
        text.autocorrectionType = .no
        text.spellCheckingType = .no
        text.clearButtonMode = .whileEditing
        text.textAlignment = .natural
        switch field {
        case .url:
            text.placeholder = "https://… or git@…"
            text.keyboardType = .URL
            text.textContentType = .URL
            text.returnKeyType = .next
        case .branch:
            text.placeholder = "main"
            text.returnKeyType = .next
        case .username:
            text.placeholder = "Your account name"
            text.textContentType = .username
            text.returnKeyType = .next
        case .token:
            text.isSecureTextEntry = true
            text.textContentType = .password
            text.returnKeyType = .go
        }
        return text
    }

    private func fieldCell(_ field: Field) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        guard let text = fields[field] else { return cell }
        text.isEnabled = !isBusy
        if field == .token {
            text.placeholder = selection.hasStoredGitToken
                ? "Saved. Leave empty to keep it." : "Personal access token"
        }
        let label = UILabel()
        label.text = field.title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        text.removeFromSuperview()
        let stack = UIStackView(arrangedSubviews: [label, text])
        // Large accessibility sizes stack the label above the field instead of
        // squeezing the field to nothing.
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stack.axis = large ? .vertical : .horizontal
        stack.alignment = large ? .fill : .center
        stack.spacing = large ? 4 : 12
        label.setContentHuggingPriority(.required, for: .horizontal)
        // The label keeps its width while a long value is typed; the field scrolls.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        return cell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let current = Field(rawValue: textField.tag - 1),
           let index = visibleFields.firstIndex(of: current), index + 1 < visibleFields.count,
           let nextField = fields[visibleFields[index + 1]] {
            nextField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            Task { await connect() }
        }
        return true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isBusy else { return }
        switch sections[indexPath.section] {
        case .intro, .repository:
            break
        case .sshKey:
            guard let key = devicePublicKey else { break }
            switch sshKeyRows[indexPath.row] {
            case .steps, .key:
                break
            case .addDeployKey:
                if let link = shownLinks.deployKey { UIApplication.shared.open(link) }
            case .copy:
                UIPasteboard.general.string = key
                status = "Public key copied."
                reloadConnectSection()
            case .share:
                let share = UIActivityViewController(activityItems: [key], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                present(share, animated: true)
            }
        case .connect:
            if connectRows[indexPath.row] == .createToken {
                if let link = shownLinks.token { UIApplication.shared.open(link) }
                break
            }
            view.endEditing(true)
            Task { await connect() }
        case .connected:
            switch connectedRows[indexPath.row] {
            case .summary: break
            case .remove where selection.provider == .git: break
            case .reconnect:
                Task { await connect() }
            case .changeConnection:
                isEditingConnection.toggle()
                status = ""
                view.endEditing(true)
                // Folding the form away abandons what was typed into it: Reconnect
                // must use the connection that is saved, not a half-edited one.
                if !isEditingConnection { restoreSavedForm() }
                visibleFields = fields(ssh: usesSSH)
                shownLinks = currentLinks
                tableView.reloadData()
                if isEditingConnection, let form = sections.firstIndex(of: .repository) {
                    tableView.scrollToRow(at: IndexPath(row: 0, section: form), at: .top, animated: true)
                }
            case .secureSnippets:
                Task { await setUpSecureSnippets() }
            case .switchProvider:
                popThenRequestSwitch()
            case .syncNow:
                environment.syncCoordinator.syncNow()
                reloadConnectedSection()
            case .newRecoveryCode:
                Task { await replaceRecoveryCode() }
            case .replaceKeys:
                Task { await rotateKeys() }
            case .remove:
                Task { await remove() }
            }
        }
    }

    private func reloadConnectSection() {
        guard isViewLoaded, let index = sections.firstIndex(of: .connect),
              tableView.numberOfSections == sections.count else { return }
        tableView.reloadSections(IndexSet(integer: index), with: .none)
    }

    private func reloadConnectedSection() {
        guard isViewLoaded, !isBusy, tableView.numberOfSections == numberOfSections(in: tableView) else {
            tableView.reloadData()
            return
        }
        if let connected = sections.firstIndex(of: .connected),
           tableView.numberOfRows(inSection: connected) == connectedRows.count {
            tableView.reloadSections(IndexSet(integer: connected), with: .none)
        } else {
            tableView.reloadData()
        }
    }

    // MARK: - Flows

    private func connect() async {
        guard !isBusy else { return }
        var form = form
        setBusy(true, "Checking the repository…")
        defer { setBusy(false, nil) }
        // An SSH host this device has not trusted yet stops the first attempt; once the
        // user confirms its fingerprint, the same steps run again. A branch holding other
        // files can be swapped for Snippets' own branch the same way.
        for attempt in 0..<3 {
            do {
                try await connectSteps(form)
                return
            } catch let failure as GitSyncSetup.Failure where attempt < 2 && failure.isUntrustedSSHHostKey {
                guard await trustHostKey(form) else {
                    status = "Not connected."
                    return
                }
                setBusy(true, "Checking the repository…")
            } catch GitSyncSetup.Failure.foreignBranch
                        where attempt < 2 && form.branch != GitSyncSetup.suggestedBranch {
                guard await confirm(
                    title: GitSyncSetup.foreignBranchTitle,
                    message: GitSyncSetup.Failure.foreignBranch.errorDescription ?? "",
                    action: "Use Branch “\(GitSyncSetup.suggestedBranch)”") else {
                    status = "Not connected."
                    return
                }
                form.branch = GitSyncSetup.suggestedBranch
                fields[.branch]?.text = GitSyncSetup.suggestedBranch
                setBusy(true, "Checking the repository…")
            } catch {
                status = ""
                await showError(title: "Couldn’t Connect the Repository", message: Self.message(for: error))
                return
            }
        }
    }

    private func trustHostKey(_ form: GitSyncSetup.Form) async -> Bool {
        guard let presented = setup.presentedHostKey(form) else { return false }
        // The parsed endpoint, exactly as the key is stored for it: `[host]:port` for a
        // non-standard port. Never derived from the raw text, whose path may contain `@`.
        guard let host = setup.sshHost(form)?.label else { return false }
        let trusted: Bool
        if presented.replacesTrustedKey {
            trusted = await confirm(
                title: "SSH Host Key Changed",
                message: "\(host) presented a different key than the one this device trusted:\n\n"
                    + "\(presented.fingerprint)\n\nThis happens when a host replaces its key, but it can "
                    + "also mean someone is intercepting the connection. Continue only if the host "
                    + "announced a new key with this fingerprint.",
                action: "Trust New Key", destructive: true)
        } else if let publisher = presented.publishedBy {
            trusted = await confirm(
                title: "Trust This SSH Host?",
                message: "This device hasn’t connected to \(host) before. Its host key matches the one "
                    + "\(publisher) publishes:\n\n\(presented.fingerprint)",
                action: "Trust")
        } else {
            trusted = await confirm(
                title: "Trust This SSH Host?",
                message: "This device hasn’t connected to \(host) before. Its host key fingerprint is:\n\n"
                    + "\(presented.fingerprint)\n\nTrust it only if it matches the fingerprint the host "
                    + "publishes.",
                action: "Trust")
        }
        return trusted && setup.trustPresentedHostKey(form, fingerprint: presented.fingerprint)
    }

    private func connectSteps(_ form: GitSyncSetup.Form) async throws {
        do {
            var inspection = try await setup.inspect(form)
            while true {
                switch inspection {
                case .foreign:
                    throw GitSyncSetup.Failure.foreignBranch
                case .empty:
                    guard let mode = await chooseLibraryMode() else {
                        status = "Nothing was created."
                        return
                    }
                    var confirmedPrivate = false
                    if mode == .plainText {
                        setBusy(true, "Checking that the repository is private…")
                        switch try await setup.repositoryVisibility(form) {
                        case .isPublic:
                            await showError(
                                title: "This Repository Is Public",
                                message: GitSyncSetup.Failure.publicRepository.errorDescription ?? "")
                            continue
                        case .unknown:
                            guard await confirm(
                                title: GitSyncSetup.visibilityUnknownTitle,
                                message: GitSyncSetup.visibilityUnknownMessage,
                                action: "It’s Private", destructive: true) else {
                                status = "Nothing was created."
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
                            await presentRecoveryCode(code)
                        }
                    } catch GitSyncSetup.Failure.libraryExists {
                        inspection = try await setup.inspect(form)
                        continue
                    } catch GitSyncSetup.Failure.publicRepository {
                        // Nothing was created: explain, then offer the choice again.
                        await showError(
                            title: "This Repository Is Public",
                            message: GitSyncSetup.Failure.publicRepository.errorDescription ?? "")
                        continue
                    } catch let failure as GitSyncSetup.Failure {
                        switch failure {
                        case .createdButNotSaved(let code), .creationUncertain(let code):
                            await presentRecoveryCode(code)
                        default:
                            break
                        }
                        throw failure
                    }
                case .library(let datasetID, let keyAvailable, let recoveryAvailable, let mode):
                    if setup.needsPlainTextConsent(datasetID: datasetID, mode: mode, form: form) {
                        guard await confirm(
                            title: "Join a Plain-Text Library?",
                            message: GitSyncSetup.plainTextJoinMessage(deviceName: deviceName),
                            action: "Join") else {
                            status = "Not connected."
                            return
                        }
                    }
                    if setup.replacesActiveLibrary(form, datasetID: datasetID) {
                        guard await confirm(
                            title: GitSyncSetup.replacementTitle,
                            message: GitSyncSetup.replacementMessage(deviceName: deviceName),
                            action: GitSyncSetup.replacementAction) else {
                            status = "Not connected."
                            return
                        }
                    }
                    if keyAvailable {
                        setBusy(true, "Connecting…")
                        do {
                            _ = try await setup.connect(form, datasetID: datasetID, mode: mode)
                        } catch GitSyncSetup.Failure.recoveryCodeRequired {
                            // The library key is here (iCloud Keychain); moving this device's
                            // secure snippets to the library's new key takes the code.
                            guard try await joinWithRecoveryCode(form, datasetID: datasetID, mode: mode) else {
                                status = "Not connected. This device needs the library’s recovery code."
                                return
                            }
                        }
                    } else {
                        guard recoveryAvailable else { throw GitSyncSetup.Failure.recoveryUnavailable }
                        guard try await joinWithRecoveryCode(form, datasetID: datasetID, mode: mode) else {
                            status = "Not connected. This device needs the library’s recovery code."
                            return
                        }
                    }
                }
                break
            }
            fields[.token]?.text = ""
            // The connection is as the form says now; fold the form away again.
            isEditingConnection = false
            visibleFields = fields(ssh: usesSSH)
            shownLinks = currentLinks
            status = setup.secureSnippetsStatus == .needsRecoveryCode
                ? "Connected. Secure snippets still need the recovery code: tap Set Up Secure Snippets."
                : "Connected."
            if selection.provider == .git {
                _ = await environment.syncCoordinator.requestSync(trigger: .manual)
            } else {
                setup.finish()
                popThenRequestSwitch()
            }
        }
    }

    private func joinWithRecoveryCode(
        _ form: GitSyncSetup.Form, datasetID: UUID, mode: GitLibraryMode
    ) async throws -> Bool {
        var problem: String?
        while let code = await promptForRecoveryCode(problem: problem) {
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

    private func replaceRecoveryCode() async {
        guard await confirm(
            title: "Create a New Recovery Code?", message: setup.newCodeExplanation,
            action: "Create Code") else { return }
        setBusy(true, "Creating a new recovery code…")
        defer { setBusy(false, nil) }
        do {
            // A vault on this device is unlocked to wrap its key under the new code,
            // which is the owner check; the setup asks through this only when it is not.
            await presentRecoveryCode(try await setup.replaceRecoveryCode(
                authenticateOwner: { try await requireDeviceOwnerAuthentication(reason: $0) }))
        } catch where Self.isAuthenticationCancel(error) {
            status = ""
        } catch {
            await showError(title: "Couldn’t Create a Recovery Code", message: Self.message(for: error))
        }
    }

    /// Replaces the library's keys and shows the new recovery code.
    private func rotateKeys() async {
        guard !isBusy else { return }
        guard await confirm(
            title: "Replace This Library’s Keys?", message: GitSyncSetup.keyRotationExplanation,
            action: "Replace Keys", destructive: true) else { return }
        setBusy(true, "Replacing the library’s keys…")
        defer { setBusy(false, nil) }
        do {
            // Re-sealing the secure snippets unlocks the vault, which is the owner check.
            // A device with none to re-seal is asked through this instead.
            await presentRecoveryCode(try await setup.rotateKeys(
                authenticateOwner: { try await requireDeviceOwnerAuthentication(reason: $0) }))
            status = "Keys replaced. Reconnect your other devices with the new recovery code."
            _ = await environment.syncCoordinator.requestSync(trigger: .manual)
        } catch where Self.isAuthenticationCancel(error) {
            status = ""
        } catch {
            status = ""
            if let failure = error as? GitSyncSetup.Failure {
                switch failure {
                case .rotatedButNotSaved(let code), .rotationUncertain(let code):
                    await presentRecoveryCode(code)
                    await showError(title: "Couldn’t Replace the Keys", message: Self.message(for: error))
                    // A round shows whether the repository took the new keys, and with
                    // that whether this screen should offer Reconnect.
                    _ = await environment.syncCoordinator.requestSync(trigger: .manual)
                    return
                default:
                    break
                }
            }
            await showError(title: "Couldn’t Replace the Keys", message: Self.message(for: error))
        }
    }

    /// Makes secure snippets work on this device for the connected library: with the
    /// recovery code when the library has a vault, or with a new vault and a new code
    /// when it was created before libraries had one.
    private func setUpSecureSnippets() async {
        guard !isBusy else { return }
        setBusy(true, "Checking the library…")
        defer { setBusy(false, nil) }
        var code: String?
        var problem: String?
        do {
            while true {
                do {
                    if case .created(let newCode) = try await setup.setUpSecureSnippets(
                        recoveryCode: code,
                        authenticateOwner: { try await requireDeviceOwnerAuthentication(reason: $0) }) {
                        await presentRecoveryCode(newCode)
                    }
                    break
                } catch let failure as GitSyncSetup.Failure
                            where [.recoveryCodeRequired, .invalidRecoveryCode, .incorrectVaultRecoveryCode]
                                .contains(failure) {
                    if code != nil { problem = failure.errorDescription }
                    guard let entered = await promptForRecoveryCode(problem: problem) else {
                        status = "Secure snippets are still locked on this \(deviceName)."
                        return
                    }
                    code = entered
                    setBusy(true, "Opening secure snippets…")
                }
            }
            status = "Secure snippets are ready on this \(deviceName)."
            if selection.provider == .git {
                _ = await environment.syncCoordinator.requestSync(trigger: .manual)
            }
        } catch where Self.isAuthenticationCancel(error) {
            status = ""
        } catch {
            await showError(title: "Couldn’t Set Up Secure Snippets", message: Self.message(for: error))
        }
    }

    private func remove() async {
        guard await confirm(
            title: "Remove the Repository from This \(deviceName)?", message: GitSyncSetup.removeMessage,
            action: "Remove", destructive: true) else { return }
        do {
            try setup.disconnect()
            fields[.url]?.text = ""
            usesSSH = false
            fields[.branch]?.text = "main"
            fields[.username]?.text = ""
            fields[.token]?.text = ""
            isEditingConnection = false
            visibleFields = fields(ssh: false)
            shownLinks = currentLinks
            status = "Removed from this \(deviceName)."
        } catch {
            await showError(title: "Couldn’t Remove the Repository", message: Self.message(for: error))
        }
        tableView.reloadData()
    }

    /// The Switch and Sync confirmation belongs to the Sync pane, which can present
    /// only once it is back on screen; presenting during the pop is silently refused.
    private func popThenRequestSwitch() {
        let request = requestProviderSwitch
        guard let navigationController else { return request() }
        navigationController.popViewController(animated: true)
        if let transition = navigationController.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { context in
                if !context.isCancelled { request() }
            }
        } else {
            request()
        }
    }

    /// While a flow runs the screen cannot be left: its alerts present from it, and a
    /// recovery code must never be created without being shown.
    private func setBusy(_ busy: Bool, _ message: String?) {
        isBusy = busy
        navigationItem.hidesBackButton = busy
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !busy
        // The sheet (its outermost container) cannot be swiped away, and on iPad the
        // sidebar, with its Done button, cannot replace this screen mid-flow.
        var root: UIViewController = self
        while let parent = root.parent { root = parent }
        root.isModalInPresentation = busy
        if let split = splitViewController, let primary = split.viewController(for: .primary),
           !(navigationController.map { primary === $0 } ?? false) {
            primary.view.isUserInteractionEnabled = !busy
        }
        if let message { status = message }
        for field in fields.values { field.isEnabled = !busy }
        tableView.reloadData()
    }

    static func message(for error: any Error) -> String {
        if let failure = error as? GitSyncSetup.Failure, let text = failure.errorDescription { return text }
        return GitSyncSetup.fallbackMessage
    }

    private static func isAuthenticationCancel(_ error: any Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return [.userCancel, .appCancel, .systemCancel].contains(error.code)
    }

    // MARK: - Alerts

    /// Presents `alert` and waits for one of its actions. If the screen cannot present
    /// (not in a window, or already presenting), it returns `fallback` immediately
    /// rather than waiting on an alert UIKit refused to show.
    private func run<T>(_ build: (@escaping (T) -> Void) -> UIAlertController, fallback: T) async -> T {
        // An alert that is still animating away is not a reason to give up.
        for _ in 0..<20 where presentedViewController?.isBeingDismissed == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return fallback }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (T) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let alert = build(finish)
            let host = DisappearanceObserver()
            // Action handlers run after the alert is gone; if none did (another part of
            // the app dismissed the whole stack), resume with the fallback.
            host.onDisappear = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(fallback) }
            }
            alert.addChild(host)
            alert.view.addSubview(host.view)
            host.didMove(toParent: alert)
            present(alert, animated: true)
        }
    }

    private func confirm(
        title: String, message: String, action: String, destructive: Bool = false, cancel: String = "Cancel"
    ) async -> Bool {
        await run({ finish in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in
                finish(true)
            })
            return alert
        }, fallback: false)
    }

    /// Encrypted unless the user asks for plain text, whose cost is explained only then.
    private func chooseLibraryMode() async -> GitLibraryMode? {
        enum Choice { case encrypted, plainText, cancel }
        while true {
            let choice: Choice = await run({ finish in
                let alert = UIAlertController(
                    title: GitSyncSetup.createLibraryTitle, message: GitSyncSetup.createLibraryMessage(),
                    preferredStyle: .alert)
                let encrypted = UIAlertAction(title: GitSyncSetup.createLibraryAction, style: .default) { _ in
                    finish(.encrypted)
                }
                alert.addAction(encrypted)
                alert.addAction(UIAlertAction(title: GitSyncSetup.plainTextInsteadAction, style: .default) { _ in
                    finish(.plainText)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(.cancel) })
                alert.preferredAction = encrypted
                return alert
            }, fallback: .cancel)
            switch choice {
            case .encrypted: return .encrypted
            case .cancel: return nil
            case .plainText:
                // Back returns to the first question instead of abandoning the setup.
                if await confirm(
                    title: GitSyncSetup.plainTextLibraryTitle, message: GitSyncSetup.plainTextLibraryMessage,
                    action: GitSyncSetup.plainTextLibraryAction, cancel: "Back") {
                    return .plainText
                }
            }
        }
    }

    private func promptForRecoveryCode(problem: String?) async -> String? {
        await run({ finish in
            let alert = UIAlertController(
                title: "Enter the Recovery Code",
                message: (problem.map { $0 + "\n\n" } ?? "") + GitSyncSetup.recoveryCodePrompt,
                preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = "XXXX-XXXX-XXXX-…"
                field.autocapitalizationType = .allCharacters
                field.autocorrectionType = .no
                field.accessibilityIdentifier = "git-recovery-input"
                field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(nil) })
            alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak alert] _ in
                finish(alert?.textFields?.first?.text ?? "")
            })
            return alert
        }, fallback: nil)
    }

    /// Shows a new recovery code on its own sheet: large, grouped, monospaced, with a
    /// copy that stays on this device and expires. It is shown only this once.
    private func presentRecoveryCode(_ code: String) async {
        for _ in 0..<20 where presentedViewController?.isBeingDismissed == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else {
            status = "The recovery code could not be shown. Create a new one from this screen."
            return
        }
        await withCheckedContinuation { continuation in
            let sheet = RecoveryCodeViewController(
                code: code, syncsThroughICloud: selection.gitKeys.syncsBetweenDevices)
            sheet.onFinish = { continuation.resume() }
            present(sheet, animated: true)
        }
    }

    /// An invisible child whose disappearance tracks its alert's.
    private final class DisappearanceObserver: UIViewController {
        var onDisappear: (() -> Void)?

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            onDisappear?()
            onDisappear = nil
        }
    }

    private func showError(title: String, message: String) async {
        await run({ finish in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in finish(()) })
            return alert
        }, fallback: ())
    }
}

/// The one-time display of a Git library's recovery code.
@MainActor
private final class RecoveryCodeViewController: UIViewController {
    private let code: String
    private let syncsThroughICloud: Bool
    var onFinish: (() -> Void)?
    private let content = UIStackView()
    private let copied = UILabel()
    private var observers: [NSObjectProtocol] = []

    init(code: String, syncsThroughICloud: Bool) {
        self.code = code
        self.syncsThroughICloud = syncsThroughICloud
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "git-recovery-code"

        let title = label("Save Your Recovery Code", style: .title2, weight: .bold)
        title.accessibilityTraits = .header
        let body = label(GitSyncSetup.recoveryCodeExplanation(keychainSyncs: syncsThroughICloud), style: .body)
        body.textColor = .secondaryLabel

        let codeLabel = UILabel()
        // Break only between groups.
        codeLabel.text = code.replacingOccurrences(of: "-", with: "-\u{200B}")
        codeLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .monospacedSystemFont(ofSize: 24, weight: .semibold))
        codeLabel.adjustsFontForContentSizeCategory = true
        codeLabel.numberOfLines = 0
        codeLabel.lineBreakMode = .byWordWrapping
        codeLabel.textAlignment = .center
        codeLabel.accessibilityIdentifier = "git-recovery-code-text"
        codeLabel.accessibilityAttributedLabel = NSAttributedString(
            string: code, attributes: [.accessibilitySpeechSpellOut: true])
        let codeBox = UIView()
        codeBox.backgroundColor = .secondarySystemBackground
        codeBox.layer.cornerRadius = 12
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeBox.addSubview(codeLabel)
        NSLayoutConstraint.activate([
            codeLabel.leadingAnchor.constraint(equalTo: codeBox.leadingAnchor, constant: 16),
            codeLabel.trailingAnchor.constraint(equalTo: codeBox.trailingAnchor, constant: -16),
            codeLabel.topAnchor.constraint(equalTo: codeBox.topAnchor, constant: 16),
            codeLabel.bottomAnchor.constraint(equalTo: codeBox.bottomAnchor, constant: -16),
        ])

        var copyConfiguration = UIButton.Configuration.bordered()
        copyConfiguration.title = "Copy"
        copyConfiguration.image = UIImage(systemName: "doc.on.doc")
        copyConfiguration.imagePadding = 6
        let copy = UIButton(configuration: copyConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.copyCode()
        })
        copy.accessibilityIdentifier = "git-recovery-copy"

        copied.text = GitSyncSetup.recoveryCodeCopied
        copied.font = .preferredFont(forTextStyle: .footnote)
        copied.adjustsFontForContentSizeCategory = true
        copied.textColor = .secondaryLabel
        copied.numberOfLines = 0
        copied.textAlignment = .center
        copied.isHidden = true
        copied.accessibilityIdentifier = "git-recovery-copied"

        var doneConfiguration = UIButton.Configuration.borderedProminent()
        doneConfiguration.title = "Done, I’ve Saved It"
        doneConfiguration.buttonSize = .large
        let done = UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        done.accessibilityIdentifier = "git-recovery-done"

        for view in [title, body, codeBox, copy, copied, done] as [UIView] { content.addArrangedSubview(view) }
        content.axis = .vertical
        content.spacing = 16
        content.setCustomSpacing(28, after: copied)
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Comfortable margins on iPhone; a readable column on iPad.
            content.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
                .withPriority(.defaultHigh),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            content.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])

        // Hide before the app-switcher snapshot: this is the only time the code is shown.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.content.isHidden = true } })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.content.isHidden = false } })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        onFinish?()
        onFinish = nil
    }

    private func copyCode() {
        // Local only, and gone in two minutes: a recovery code must not ride Universal
        // Clipboard to another device or linger.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: code]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: copied.text)
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> UILabel {
        let label = UILabel()
        label.text = text
        if let weight {
            let base = UIFont.preferredFont(forTextStyle: style)
            label.font = UIFontMetrics(forTextStyle: style).scaledFont(
                for: .systemFont(ofSize: base.pointSize, weight: weight))
        } else {
            label.font = .preferredFont(forTextStyle: style)
        }
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
