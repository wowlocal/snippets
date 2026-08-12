import Darwin
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SnippetsIOSTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetsIOSTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey
        )
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(
                previousSyncPreference,
                forKey: SyncCoordinator.enabledDefaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testBuiltAppAllowsProMotionFrameRatesOnIPhone() {
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone"
            ) as? Bool,
            true
        )
    }

    func testFreshIOSLibraryStartsEmptyAndPersistsCRUD() throws {
        var store: SnippetStore? = SnippetStore(configuration: .iOS)
        XCTAssertTrue(store?.snippets.isEmpty == true)

        let created = store!.addSnippet(name: "Greeting", content: "Hello", tags: ["Work"])
        var updated = created
        updated.keyword = "hello"
        updated.content = "Hello from iPad"
        store!.update(updated)
        store!.flushPendingWrites()
        store = nil

        let reloaded = SnippetStore(configuration: .iOS)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(reloaded.snippets.first?.name, "Greeting")
        XCTAssertEqual(reloaded.snippets.first?.content, "Hello from iPad")
        XCTAssertEqual(reloaded.snippets.first?.normalizedKeyword, "hello")
    }

    func testExportStructurallyExcludesSecureShells() throws {
        let store = SnippetStore(configuration: .iOS)
        _ = store.addSnippet(name: "Ordinary", content: "visible")
        let secureID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(id: secureID, name: "Encrypted", keyword: "secret", content: "")
        )
        store.secureProvider = secureProvider

        let exportURL = rootURL.appendingPathComponent("export.json")
        XCTAssertEqual(try store.exportSnippets(to: exportURL), 1)
        let export = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(export.contains("Ordinary"))
        XCTAssertFalse(export.contains("Encrypted"))
        XCTAssertFalse(export.contains(secureID.uuidString))
    }

    func testImportingTheSameNativeExportTwiceDoesNotCreateDuplicates() throws {
        let store = SnippetStore(configuration: .iOS)
        let snippet = Snippet(
            id: UUID(),
            name: "Imported Once",
            keyword: "once",
            content: "The same file can be imported repeatedly.")
        let importURL = rootURL.appendingPathComponent("same-export.json")
        try JSONEncoder().encode([snippet]).write(to: importURL, options: .atomic)

        XCTAssertEqual(try store.importSnippets(from: importURL), 1)
        XCTAssertEqual(try store.importSnippets(from: importURL), 1)

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets.first?.id, snippet.id)
        XCTAssertEqual(store.snippets.first?.content, snippet.content)
    }

    func testImportingTheSameEncryptedBackupTwiceDoesNotCreateDuplicates() async throws {
        let defaultsKey = SyncCoordinator.enabledDefaultsKey
        let previousSyncValue = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.set(false, forKey: defaultsKey)
        defer {
            if let previousSyncValue {
                UserDefaults.standard.set(previousSyncValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let snippet = Snippet(
            id: UUID(),
            name: "Encrypted Import",
            keyword: "encrypted-once",
            content: "Still only one copy.")
        let data = try EncryptedSnippetBackup.seal(
            snippets: [snippet],
            vault: nil,
            vaultKey: nil,
            passphrase: "correct horse battery staple",
            iterations: 1)
        let environment = AppEnvironment()

        let first = try await environment.secureStore.importEncryptedBackup(
            data,
            passphrase: "correct horse battery staple",
            into: environment.store)
        let second = try await environment.secureStore.importEncryptedBackup(
            data,
            passphrase: "correct horse battery staple",
            into: environment.store)

        XCTAssertEqual(first.ordinaryCount, 1)
        XCTAssertEqual(second.ordinaryCount, 1)
        XCTAssertEqual(environment.store.snippets.count, 1)
        XCTAssertEqual(environment.store.snippets.first?.id, snippet.id)
    }

    func testIOSConfigurationDoesNotSeedStarterContentAfterCorruptFileRecovery() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: rootURL.appendingPathComponent("snippets.json"))
        let store = SnippetStore(configuration: .iOS)
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
                .contains { $0.hasPrefix("snippets.json.corrupt-") }
        )
    }

    func testPhoneQueryBuildsPinnedAndSnippetSectionsWithANDTagFiltering() {
        let pinned = Snippet(
            name: "Café Reply",
            keyword: "reply",
            content: "Bonjour",
            tags: ["Work", "Urgent"],
            isPinned: true
        )
        let workOnly = Snippet(
            name: "Status",
            keyword: "status",
            content: "Weekly status",
            tags: ["Work"]
        )
        let personal = Snippet(
            name: "Café List",
            keyword: "coffee",
            content: "Beans",
            tags: ["Personal"]
        )

        let unfiltered = SnippetLibraryQuery.results(
            in: [pinned, workOnly, personal],
            searchText: "",
            activeTagKeys: []
        )
        XCTAssertEqual(unfiltered.pinned.map(\.id), [pinned.id])
        XCTAssertEqual(unfiltered.snippets.map(\.id), [workOnly.id, personal.id])

        let filtered = SnippetLibraryQuery.results(
            in: [pinned, workOnly, personal],
            searchText: "cafe",
            activeTagKeys: ["work", "urgent"]
        )
        XCTAssertEqual(filtered.all.map(\.id), [pinned.id])
    }

    func testPhoneOrdinaryCopyResolvesClipboardAndNeverClearsItForEmptyContent() async throws {
        let environment = AppEnvironment()
        let pasteboard = TestSnippetPasteboard(string: "source")
        let service = SnippetActionService(
            store: environment.store,
            vaultSession: environment.vaultSession,
            secureStore: environment.secureStore,
            pasteboard: pasteboard
        )
        let snippet = environment.store.addSnippet(
            name: "Greeting",
            content: "Hello {clipboard}"
        )

        let copied = try await service.copy(id: snippet.id)
        XCTAssertEqual(copied, .copied(name: "Greeting", secure: false))
        XCTAssertEqual(pasteboard.string, "Hello source")

        let empty = environment.store.addSnippet(name: "Empty", content: "")
        pasteboard.string = "keep me"
        let emptyResult = try await service.copy(id: empty.id)
        XCTAssertEqual(emptyResult, .empty(name: "Empty"))
        XCTAssertEqual(pasteboard.string, "keep me")
    }

    func testPhoneSecureCopyAuthenticatesEveryUseAndUsesLocalExpiringPasteboard() async throws {
        let environment = AppEnvironment()
        let secureID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(
                id: secureID,
                name: "Token",
                keyword: "token",
                content: ""
            )
        )
        environment.store.secureProvider = secureProvider
        let instant = Date(timeIntervalSince1970: 1_000)
        let pasteboard = TestSnippetPasteboard(string: "clipboard")
        var requestedID: UUID?
        var requestedReason: String?
        var authenticationRequestCount = 0
        let service = SnippetActionService(
            store: environment.store,
            vaultSession: environment.vaultSession,
            secureStore: environment.secureStore,
            pasteboard: pasteboard,
            now: { instant },
            secureContentLoader: { id, reason in
                authenticationRequestCount += 1
                requestedID = id
                requestedReason = reason
                var plaintext = Data("secret-{clipboard}".utf8)
                return SecurePlaintextLease(consuming: &plaintext)
            }
        )

        let result = try await service.copy(id: secureID)
        XCTAssertEqual(result, .copied(name: "Token", secure: true))
        XCTAssertEqual(requestedID, secureID)
        XCTAssertEqual(requestedReason, "Copy Token")
        XCTAssertEqual(pasteboard.string, "secret-clipboard")
        XCTAssertEqual(
            pasteboard.secureExpiration,
            instant.addingTimeInterval(SnippetActionService.secureClipboardLifetime)
        )
        XCTAssertEqual(pasteboard.secureWriteCount, 1)
        XCTAssertEqual(pasteboard.ordinaryWriteCount, 0)

        _ = try await service.copy(id: secureID)
        XCTAssertEqual(authenticationRequestCount, 2)
        XCTAssertEqual(pasteboard.secureWriteCount, 2)
    }

    func testPhoneNavigationPushesTouchEditorWithContentAndDetailsModes() throws {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Phone", content: "Touch first")
        let root = PhoneRootViewController(environment: environment)
        root.loadViewIfNeeded()
        let library = try XCTUnwrap(root.viewControllers.first as? PhoneLibraryViewController)
        library.loadViewIfNeeded()

        root.phoneLibrary(library, requestedEdit: snippet.id)

        let editor = try XCTUnwrap(root.topViewController as? PhoneSnippetEditorViewController)
        editor.loadViewIfNeeded()
        XCTAssertNil(editor.navigationItem.titleView)
        let mode = try XCTUnwrap(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-mode")
                as? UISegmentedControl
        )
        XCTAssertEqual(mode.numberOfSegments, 2)
        XCTAssertEqual(mode.titleForSegment(at: 0), "Content")
        XCTAssertEqual(mode.titleForSegment(at: 1), "Details")
        XCTAssertTrue(mode.superview === editor.view)
        XCTAssertTrue(editor.view.subviews.last === mode)
        XCTAssertNil(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-mode-glass")
        )
        XCTAssertNil(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-mode-selection-glass")
        )
        XCTAssertNil(mode.backgroundImage(for: .normal, barMetrics: .default))
        XCTAssertNil(mode.backgroundImage(for: .selected, barMetrics: .default))
        XCTAssertNil(mode.selectedSegmentTintColor)
        XCTAssertNil(mode.titleTextAttributes(for: .normal))
        XCTAssertNil(mode.titleTextAttributes(for: .selected))
        editor.view.layoutIfNeeded()
        XCTAssertEqual(mode.bounds.height, mode.intrinsicContentSize.height, accuracy: 1.5)
        mode.selectedSegmentIndex = 1
        mode.sendActions(for: .valueChanged)
        XCTAssertEqual(mode.selectedSegmentIndex, 1)
        let modeContainer = try XCTUnwrap(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-mode-container")
        )
        let contentPane = try XCTUnwrap(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-content-pane")
        )
        let detailsPane = try XCTUnwrap(
            editor.view.descendant(withAccessibilityIdentifier: "phone-editor-details-pane")
        )
        XCTAssertTrue(contentPane.superview === modeContainer)
        XCTAssertTrue(detailsPane.superview === modeContainer)
        XCTAssertFalse(modeContainer is UIStackView)
        XCTAssertTrue(modeContainer.clipsToBounds)
        XCTAssertNotNil(editor.view.descendant(withAccessibilityIdentifier: "snippet-content"))
        XCTAssertNotNil(editor.view.descendant(withAccessibilityIdentifier: "snippet-keyword"))
    }

    func testPhoneAndIPadSecureEditorsExposeSafeSiblingInsteadOfBodyToAccessibility() throws {
        let environment = AppEnvironment()
        let secureID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(
                id: secureID,
                name: "NAME-PRIVATE-SENTINEL",
                keyword: "KEYWORD-PRIVATE-SENTINEL",
                content: ""
            )
        )
        environment.store.secureProvider = secureProvider

        let phone = PhoneSnippetEditorViewController(
            environment: environment,
            snippetID: secureID)
        phone.loadViewIfNeeded()
        let tablet = SnippetEditorViewController(environment: environment)
        tablet.loadViewIfNeeded()
        tablet.bind(to: secureID)

        for editorView in [phone.view!, tablet.view!] {
            let body = try XCTUnwrap(editorView.firstDescendant(
                ofType: SecureSnippetTextView.self))
            let notice = try XCTUnwrap(
                editorView.descendant(
                    withAccessibilityIdentifier: "secure-body-protection")
                    as? SecureBodyAccessibilityNoticeView)

            XCTAssertTrue(body.isSecureContentMode)
            XCTAssertFalse(body.isAccessibilityElement)
            XCTAssertTrue(body.accessibilityElementsHidden)
            XCTAssertNil(body.accessibilityLabel)
            XCTAssertNil(body.accessibilityValue)
            XCTAssertTrue(notice.isAccessibilityElement)
            XCTAssertEqual(
                notice.accessibilityLabel,
                SecureBodyAccessibilityNoticeView.protectedLabel)
            XCTAssertEqual(
                notice.accessibilityValue,
                SecureBodyAccessibilityNoticeView.lockedValue)

            let externallyVisible = editorView.accessibilityElementViews()
            XCTAssertFalse(externallyVisible.contains { $0 === body })
            XCTAssertTrue(externallyVisible.contains { $0 === notice })

            let safeCopy = [
                notice.accessibilityLabel,
                notice.accessibilityValue,
                notice.accessibilityHint,
            ].compactMap { $0 }.joined(separator: " ")
            XCTAssertFalse(safeCopy.contains("NAME-PRIVATE-SENTINEL"))
            XCTAssertFalse(safeCopy.contains("KEYWORD-PRIVATE-SENTINEL"))
        }
    }

    func testSecureBodyNeverEntersOrdinaryPreviewLabels() throws {
        let environment = AppEnvironment()
        let secureID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(id: secureID, name: "Secure", keyword: "secure", content: ""))
        environment.store.secureProvider = secureProvider
        let sentinel = "SECURE-PREVIEW-{date:yyyy}-SENTINEL"

        let phone = PhoneSnippetEditorViewController(
            environment: environment,
            snippetID: secureID)
        phone.loadViewIfNeeded()
        let tablet = SnippetEditorViewController(environment: environment)
        tablet.loadViewIfNeeded()
        tablet.bind(to: secureID)

        for (editor, editorView) in [
            (phone as any UITextViewDelegate, phone.view!),
            (tablet as any UITextViewDelegate, tablet.view!),
        ] {
            let body = try XCTUnwrap(editorView.firstDescendant(
                ofType: SecureSnippetTextView.self))
            let preview = try XCTUnwrap(
                editorView.descendant(withAccessibilityIdentifier: "snippet-preview")
                    as? UILabel)
            body.setSceneCaptureStateForTesting(.inactive)
            body.setSecureForegroundActiveForTesting(true)
            XCTAssertTrue(body.bindSecureRedacted())
            body.setSecurePlaintextAcceptanceAuthorized(true)
            body.text = sentinel

            editor.textViewDidChange?(body)
            XCTAssertNil(preview.text)
            XCTAssertNil(preview.attributedText)

            _ = body.redactAndClearSecurePlaintext()
            editor.textViewDidChange?(body)
            XCTAssertNil(preview.text)
            XCTAssertNil(preview.attributedText)
        }
    }

    func testMakeOrdinaryModalSynchronouslyRedactsSecureBodyOnPhoneAndIPad() throws {
        let environment = AppEnvironment()
        let secureID = UUID()
        let secureProvider = SecureProviderStub(shell: Snippet(
            id: secureID,
            name: "Secure",
            keyword: "secure",
            content: ""))
        environment.store.secureProvider = secureProvider

        let phone = PhoneSnippetEditorViewController(
            environment: environment,
            snippetID: secureID)
        let phoneNavigation = UINavigationController(rootViewController: phone)
        let phoneWindow = testWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        phoneWindow.rootViewController = phoneNavigation
        phoneWindow.makeKeyAndVisible()
        phone.loadViewIfNeeded()
        phone.view.layoutIfNeeded()
        addTeardownBlock {
            phoneWindow.isHidden = true
            phoneWindow.rootViewController = nil
        }

        let phoneBody = try XCTUnwrap(
            phone.view.firstDescendant(ofType: SecureSnippetTextView.self))
        try loadPendingSecurePlaintext("PHONE-MODAL-SENTINEL", into: phoneBody)
        let phoneSecureSwitch = try XCTUnwrap(
            phone.view.descendant(withAccessibilityIdentifier: "snippet-secure")
                as? UISwitch)
        phoneSecureSwitch.sendActions(for: .valueChanged)
        XCTAssertEqual(phoneBody.text, "")
        XCTAssertEqual(phoneBody.secureCapturePhase, .protectedRedaction)
        XCTAssertTrue(phoneBody.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(phone.presentedViewController is UIAlertController)
        phone.dismiss(animated: false)

        let tablet = SnippetEditorViewController(environment: environment)
        let tabletNavigation = UINavigationController(rootViewController: tablet)
        let tabletWindow = testWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        tabletWindow.rootViewController = tabletNavigation
        tabletWindow.makeKeyAndVisible()
        tablet.loadViewIfNeeded()
        tablet.bind(to: secureID)
        tablet.view.layoutIfNeeded()
        addTeardownBlock {
            tabletWindow.isHidden = true
            tabletWindow.rootViewController = nil
        }

        let tabletBody = try XCTUnwrap(
            tablet.view.firstDescendant(ofType: SecureSnippetTextView.self))
        try loadPendingSecurePlaintext("IPAD-MODAL-SENTINEL", into: tabletBody)
        let tabletSecureButton = try XCTUnwrap(
            tablet.view.descendant(withAccessibilityIdentifier: "snippet-secure")
                as? UIButton)
        tabletSecureButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(tabletBody.text, "")
        XCTAssertEqual(tabletBody.secureCapturePhase, .protectedRedaction)
        XCTAssertTrue(tabletBody.secureCaptureDisplayLayerHiddenForInspection)
        XCTAssertTrue(tablet.presentedViewController is UIAlertController)
        withExtendedLifetime(secureProvider) {}
    }

    func testPhoneAndIPadOrdinaryEditorsRetainTextViewAccessibility() throws {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(
            name: "Ordinary",
            content: "ORDINARY-BODY-AX-SENTINEL")

        let phone = PhoneSnippetEditorViewController(
            environment: environment,
            snippetID: snippet.id)
        phone.loadViewIfNeeded()
        let tablet = SnippetEditorViewController(environment: environment)
        tablet.loadViewIfNeeded()
        tablet.bind(to: snippet.id)

        for editorView in [phone.view!, tablet.view!] {
            let body = try XCTUnwrap(
                editorView.descendant(withAccessibilityIdentifier: "snippet-content")
                    as? SecureSnippetTextView)
            let notice = try XCTUnwrap(
                editorView.descendant(
                    withAccessibilityIdentifier: "secure-body-protection")
                    as? SecureBodyAccessibilityNoticeView)

            XCTAssertFalse(body.isSecureContentMode)
            XCTAssertFalse(body.accessibilityElementsHidden)
            XCTAssertEqual(body.accessibilityLabel, "Snippet content")
            XCTAssertEqual(body.text, "ORDINARY-BODY-AX-SENTINEL")
            XCTAssertFalse(notice.isAccessibilityElement)
            XCTAssertTrue(notice.accessibilityElementsHidden)
        }
    }

    func testSecureToOrdinaryControllerRebindRestoresStoreBodyAfterSecureClear() throws {
        let environment = AppEnvironment()
        let snippetID = UUID()
        let secureProvider = SecureProviderStub(
            shell: Snippet(
                id: snippetID,
                name: "Secure shell",
                keyword: "secure-shell",
                content: ""))
        environment.store.secureProvider = secureProvider

        let phone = PhoneSnippetEditorViewController(
            environment: environment,
            snippetID: snippetID)
        phone.loadViewIfNeeded()
        let tablet = SnippetEditorViewController(environment: environment)
        tablet.loadViewIfNeeded()
        tablet.bind(to: snippetID)

        let ordinarySentinel = "ORDINARY-AFTER-SECURE-REBIND"
        secureProvider.isActive = false
        _ = try environment.store.importSharedSnippet(Snippet(
            id: snippetID,
            name: "Ordinary",
            keyword: "ordinary",
            content: ordinarySentinel))
        phone.refreshFromStore(change: .init(source: .external))
        tablet.bind(to: snippetID)

        for editorView in [phone.view!, tablet.view!] {
            let body = try XCTUnwrap(editorView.firstDescendant(
                ofType: SecureSnippetTextView.self))
            XCTAssertFalse(body.isSecureContentMode)
            XCTAssertEqual(body.secureCapturePhase, .ordinary)
            XCTAssertEqual(body.text, ordinarySentinel)
        }
    }

    func testSyncStateObserversDoNotReplaceEachOther() {
        let environment = AppEnvironment()
        var firstStates: [SyncEngine.State] = []
        var secondStates: [SyncEngine.State] = []
        let first = environment.syncCoordinator.addStateObserver { firstStates.append($0) }
        let second = environment.syncCoordinator.addStateObserver { secondStates.append($0) }

        environment.syncCoordinator.setEnabled(false)
        XCTAssertEqual(firstStates.count, 2)
        XCTAssertEqual(secondStates.count, 2)

        environment.syncCoordinator.removeStateObserver(first)
        environment.syncCoordinator.setEnabled(false)
        XCTAssertEqual(firstStates.count, 2)
        XCTAssertEqual(secondStates.count, 3)
        environment.syncCoordinator.removeStateObserver(second)
    }

    func testCopySnippetShortcutUsesUnmodifiedReturnWithSystemPriority() {
        let command = MainSplitViewController.copySnippetKeyCommand()

        XCTAssertEqual(command.input, "\r")
        XCTAssertEqual(command.modifierFlags, [])
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
    }

    func testCopySnippetCommandCopiesSelection() {
        let pasteboard = TestSnippetPasteboard(string: nil)
        let environment = AppEnvironment(pasteboard: pasteboard)
        let snippet = environment.store.addSnippet(name: "Greeting", content: "Hello from iPad")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        hosted.list.focusFilteredList()

        let command = MainSplitViewController.copySnippetKeyCommand()
        hosted.controller.copySnippetCommand(command)
        XCTAssertEqual(pasteboard.string, "Hello from iPad")
    }

    func testReturnHandlerCopiesOnlyWhenSnippetListOwnsFocus() {
        let pasteboard = TestSnippetPasteboard(string: nil)
        let environment = AppEnvironment(pasteboard: pasteboard)
        let snippet = environment.store.addSnippet(name: "Greeting", content: "Hello from iPad")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)

        hosted.list.focusFilteredList()
        XCTAssertTrue(hosted.controller.handleReturnBeforeSystemBehavior())
        XCTAssertEqual(pasteboard.string, "Hello from iPad")

        pasteboard.string = nil
        hosted.controller.searchCommand()
        XCTAssertTrue(waitUntil { hosted.list.isSearchFocused })
        XCTAssertFalse(hosted.controller.handleReturnBeforeSystemBehavior())
        XCTAssertNil(pasteboard.string)
    }

    func testKeyboardCommandsUseMacBindingsAndDeclareSystemPriority() {
        let commands: [(UIKeyCommand, String, UIKeyModifierFlags)] = [
            (MainSplitViewController.searchKeyCommand(), "f", .command),
            (MainSplitViewController.toggleSidebarKeyCommand(), "b", .command),
            (MainSplitViewController.editSnippetKeyCommand(), "e", .command),
            (MainSplitViewController.deleteSnippetKeyCommand(), UIKeyCommand.inputDelete, .command),
            (MainSplitViewController.nextFieldKeyCommand(), "\t", []),
            (MainSplitViewController.previousFieldKeyCommand(), "\t", .shift),
            (MainSplitViewController.shortcutsKeyCommand(), "k", .command),
            (MainSplitViewController.nextSnippetKeyCommand(), "n", .control),
            (MainSplitViewController.previousSnippetKeyCommand(), "p", .control),
            (MainSplitViewController.nextSnippetArrowKeyCommand(), UIKeyCommand.inputDownArrow, []),
            (MainSplitViewController.previousSnippetArrowKeyCommand(), UIKeyCommand.inputUpArrow, []),
            (MainSplitViewController.escapeKeyCommand(), UIKeyCommand.inputEscape, []),
        ]

        for (command, input, modifiers) in commands {
            XCTAssertEqual(command.input, input)
            XCTAssertEqual(command.modifierFlags, modifiers)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        }
    }

    func testSearchShortcutRevealsHiddenSidebarAndFocusesSearch() {
        UIView.setAnimationsEnabled(false)
        addTeardownBlock { UIView.setAnimationsEnabled(true) }
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Search me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)

        hosted.controller.hide(.primary)
        hosted.controller.view.layoutIfNeeded()
        XCTAssertFalse(hosted.controller.isSidebarVisible)

        hosted.controller.searchCommand()
        hosted.controller.view.layoutIfNeeded()

        XCTAssertTrue(hosted.controller.isSidebarVisible)
        XCTAssertTrue(waitUntil { hosted.list.isSearchFocused })
    }

    func testEditAndTabShortcutsFollowMacEditorFocusOrder() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Edit me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView
        let keyword = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-keyword"
        ) as? UITextField
        let name = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-name"
        ) as? UITextField
        let tags = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "tags-input"
        ) as? UITextField

        hosted.list.focusFilteredList()
        hosted.controller.editSnippetCommand()
        XCTAssertTrue(body?.isFirstResponder == true)
        for command in [
            MainSplitViewController.searchKeyCommand(),
            MainSplitViewController.toggleSidebarKeyCommand(),
            MainSplitViewController.nextFieldKeyCommand(),
            MainSplitViewController.shortcutsKeyCommand(),
        ] {
            guard let action = command.action else {
                return XCTFail("\(command.title) should have an action")
            }
            let target = body?.target(forAction: action, withSender: command)
            XCTAssertTrue(
                target as AnyObject? === hosted.controller,
                "\(command.title) should route from the editor to the split controller"
            )
        }
        let listOnlyCommands = [
            MainSplitViewController.copySnippetKeyCommand(),
            MainSplitViewController.editSnippetKeyCommand(),
            MainSplitViewController.deleteSnippetKeyCommand(),
            MainSplitViewController.nextSnippetKeyCommand(),
            MainSplitViewController.previousSnippetKeyCommand(),
            MainSplitViewController.nextSnippetArrowKeyCommand(),
            MainSplitViewController.previousSnippetArrowKeyCommand(),
            MainSplitViewController.undoKeyCommand(),
            MainSplitViewController.redoKeyCommand(),
        ]
        for field in [body, keyword, name, tags].compactMap({ $0 }) {
            XCTAssertTrue(field.becomeFirstResponder())
            for command in listOnlyCommands {
                guard let action = command.action else {
                    return XCTFail("\(command.title) should have an action")
                }
                let target = field.target(forAction: action, withSender: command)
                XCTAssertFalse(
                    target as AnyObject? === hosted.controller,
                    "\(command.title) must stay out of every editor field's responder chain"
                )
            }
        }

        XCTAssertTrue(body?.becomeFirstResponder() == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(keyword?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(name?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(tags?.isFirstResponder == true)
        hosted.controller.nextFieldCommand()
        XCTAssertTrue(body?.isFirstResponder == true)

        hosted.controller.previousFieldCommand()
        XCTAssertTrue(hosted.controller.isSidebarVisible)
        XCTAssertTrue(hosted.list.ownsFirstResponder)
    }

    func testEscapeLeavesEveryEditorFieldForSnippetList() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Edit me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        let fields = [
            hosted.editor.view.descendant(withAccessibilityIdentifier: "snippet-content"),
            hosted.editor.view.descendant(withAccessibilityIdentifier: "snippet-keyword"),
            hosted.editor.view.descendant(withAccessibilityIdentifier: "snippet-name"),
            hosted.editor.view.descendant(withAccessibilityIdentifier: "tags-input"),
        ].compactMap { $0 }

        XCTAssertEqual(fields.count, 4)
        for field in fields {
            XCTAssertTrue(field.becomeFirstResponder())
            XCTAssertTrue(hosted.editor.isEditorFocused)

            XCTAssertTrue(hosted.controller.handleEscapeBeforeSystemBehavior())

            XCTAssertFalse(field.isFirstResponder)
            XCTAssertFalse(hosted.editor.isEditorFocused)
            XCTAssertTrue(hosted.list.isListFocused)
        }
    }

    func testDeleteShortcutIsTextEditingSafeAndOnlyRunsFromList() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Delete me", content: "Still here")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView
        let command = MainSplitViewController.deleteSnippetKeyCommand()

        hosted.list.focusFilteredList()
        hosted.controller.editSnippetCommand()
        XCTAssertTrue(body?.isFirstResponder == true)
        XCTAssertFalse(
            body?.target(forAction: command.action!, withSender: command) as AnyObject?
                === hosted.controller,
            "Command-Delete must remain a text-editing command while an editor owns focus"
        )

        hosted.controller.deleteSnippetCommand()
        XCTAssertNil(hosted.controller.presentedViewController)
        XCTAssertNotNil(environment.store.snippet(id: snippet.id))

        XCTAssertTrue(hosted.controller.handleEscapeBeforeSystemBehavior())
        XCTAssertTrue(hosted.list.isListFocused)
        XCTAssertTrue(
            hosted.list.view.target(forAction: command.action!, withSender: command) as AnyObject?
                === hosted.controller
        )
        hosted.controller.deleteSnippetCommand()

        let alert = hosted.controller.presentedViewController as? UIAlertController
        XCTAssertEqual(alert?.title, "Delete “Delete me” ?")
        XCTAssertNotNil(environment.store.snippet(id: snippet.id))
    }

    func testIPadLeavingBlankDraftForListDiscardsItAndSelectsExistingSnippet() {
        let environment = AppEnvironment()
        let existing = environment.store.addSnippet(name: "Existing", content: "Keep me")
        let draft = environment.store.addSnippet()
        let hosted = hostMainSplit(environment: environment, selecting: draft.id)
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView

        hosted.list.focusFilteredList()
        hosted.controller.editSnippetCommand()
        XCTAssertTrue(body?.isFirstResponder == true)
        XCTAssertTrue(hosted.controller.handleEscapeBeforeSystemBehavior())

        XCTAssertTrue(waitUntil { environment.store.snippet(id: draft.id) == nil })
        XCTAssertEqual(hosted.list.selectedSnippetID, existing.id)
        XCTAssertTrue(hosted.list.isListFocused)
    }

    func testIPadSelectionChangeKeepsDraftAfterPendingTextIsCommitted() {
        let environment = AppEnvironment()
        let existing = environment.store.addSnippet(name: "Existing", content: "Keep me")
        let draft = environment.store.addSnippet()
        let hosted = hostMainSplit(environment: environment, selecting: draft.id)
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView

        hosted.list.focusFilteredList()
        hosted.controller.editSnippetCommand()
        body?.text = "Started"
        hosted.controller.snippetList(hosted.list, selected: existing.id)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(environment.store.snippet(id: draft.id)?.content, "Started")
    }

    func testTappingAnotherSnippetLeavesEditorFocusInTheList() {
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(name: "First", content: "One")
        _ = environment.store.addSnippet(name: "Second", content: "Two")
        let hosted = hostMainSplit(environment: environment)
        let tableView = hosted.list.view.descendant(
            withAccessibilityIdentifier: "snippet-list"
        ) as? UITableView
        let firstID = hosted.list.firstVisibleSnippetID

        XCTAssertNotNil(tableView)
        XCTAssertNotNil(firstID)
        hosted.list.focusFilteredList()
        hosted.controller.snippetList(hosted.list, selected: firstID!)
        let secondID = hosted.list.adjacentSnippetID(forward: true)
        hosted.controller.editSnippetCommand()
        XCTAssertTrue(hosted.editor.isEditorFocused)

        hosted.list.tableView(tableView!, didSelectRowAt: IndexPath(row: 1, section: 0))

        XCTAssertEqual(hosted.list.selectedSnippetID, secondID)
        XCTAssertFalse(hosted.editor.isEditorFocused)
        XCTAssertTrue(hosted.list.isListFocused)
    }

    func testCommandBTogglesSidebarAndMovesSidebarFocusIntoEditor() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Edit me")
        let hosted = hostMainSplit(environment: environment, selecting: snippet.id)
        hosted.list.focusSearch()

        hosted.controller.toggleSidebarCommand()
        hosted.controller.view.layoutIfNeeded()
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView
        XCTAssertFalse(hosted.controller.isSidebarVisible)
        XCTAssertTrue(body?.isFirstResponder == true)

        hosted.controller.toggleSidebarCommand()
        hosted.controller.view.layoutIfNeeded()
        XCTAssertTrue(hosted.controller.isSidebarVisible)
    }

    func testCommandKTogglesMacStyleShortcutPanelAndOptionHint() {
        let environment = AppEnvironment()
        let hosted = hostMainSplit(environment: environment)
        UIView.setAnimationsEnabled(false)
        addTeardownBlock { UIView.setAnimationsEnabled(true) }

        hosted.controller.shortcutsCommand()
        let panel = hosted.controller.view.descendant(
            withAccessibilityIdentifier: "shortcut-panel"
        ) as? ShortcutPanelView
        let tip = panel?.descendant(
            withAccessibilityIdentifier: "shortcut-panel-tip"
        ) as? UILabel
        XCTAssertTrue(panel?.isPresented == true)
        XCTAssertEqual(tip?.text, "Hold ⌥ for all shortcuts.")

        panel?.setShowsAllShortcuts(true, animated: false)
        XCTAssertTrue(panel?.showsAllShortcuts == true)
        XCTAssertEqual(tip?.text, "Release ⌥ for essentials.")

        hosted.controller.shortcutsCommand()
        XCTAssertFalse(panel?.isPresented == true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertTrue(panel?.isHidden == true)
    }

    func testControlNAndControlPOnlyNavigateWhenSnippetListOwnsFocus() {
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(name: "First", content: "One")
        _ = environment.store.addSnippet(name: "Second", content: "Two")
        let hosted = hostMainSplit(environment: environment)
        let firstID = hosted.list.firstVisibleSnippetID!
        hosted.list.focusFilteredList()
        hosted.controller.snippetList(hosted.list, selected: firstID)
        hosted.controller.editSnippetCommand()
        let body = hosted.editor.view.descendant(
            withAccessibilityIdentifier: "snippet-content"
        ) as? UITextView

        hosted.controller.nextSnippetCommand()
        hosted.controller.previousSnippetCommand()
        XCTAssertEqual(hosted.list.selectedSnippetID, firstID)
        XCTAssertTrue(body?.isFirstResponder == true)

        XCTAssertTrue(hosted.controller.handleEscapeBeforeSystemBehavior())
        XCTAssertTrue(hosted.list.isListFocused)
        hosted.controller.nextSnippetCommand()
        let nextID = hosted.list.selectedSnippetID
        XCTAssertNotEqual(nextID, firstID)

        hosted.controller.previousSnippetCommand()
        XCTAssertEqual(hosted.list.selectedSnippetID, firstID)
        XCTAssertTrue(hosted.list.isListFocused)
    }

    func testEscapeMovesFromSearchToFilteredListForArrowAndControlNavigation() {
        let environment = AppEnvironment()
        _ = environment.store.addSnippet(name: "Match One", content: "One")
        _ = environment.store.addSnippet(name: "Match Two", content: "Two")
        _ = environment.store.addSnippet(name: "Different", content: "Three")
        let hosted = hostMainSplit(environment: environment)
        let searchField = hosted.list.searchTextField

        hosted.controller.searchCommand()
        XCTAssertTrue(waitUntil { hosted.list.isSearchFocused })
        searchField.text = "Match"
        hosted.list.reload(keepingSelection: false)

        let selectionBeforeNavigation = hosted.list.selectedSnippetID
        let listOnlyCommands = [
            MainSplitViewController.copySnippetKeyCommand(),
            MainSplitViewController.editSnippetKeyCommand(),
            MainSplitViewController.deleteSnippetKeyCommand(),
            MainSplitViewController.nextSnippetKeyCommand(),
            MainSplitViewController.previousSnippetKeyCommand(),
            MainSplitViewController.nextSnippetArrowKeyCommand(),
            MainSplitViewController.previousSnippetArrowKeyCommand(),
            MainSplitViewController.undoKeyCommand(),
            MainSplitViewController.redoKeyCommand(),
        ]
        for command in listOnlyCommands {
            XCTAssertFalse(
                searchField.target(forAction: command.action!, withSender: command) as AnyObject?
                    === hosted.controller,
                "\(command.title) must stay out of the search field's responder chain"
            )
        }
        let controlN = MainSplitViewController.nextSnippetKeyCommand()
        hosted.controller.nextSnippetCommand()
        hosted.controller.previousSnippetCommand()
        hosted.controller.editSnippetCommand()
        hosted.controller.deleteSnippetCommand()
        XCTAssertEqual(hosted.list.selectedSnippetID, selectionBeforeNavigation)
        XCTAssertNil(hosted.controller.presentedViewController)
        XCTAssertTrue(hosted.list.isSearchFocused)

        let escape = MainSplitViewController.escapeKeyCommand()
        XCTAssertNotNil(escape.action)
        XCTAssertTrue(hosted.controller.handleEscapeBeforeSystemBehavior())

        XCTAssertEqual(searchField.text, "Match")
        XCTAssertFalse(hosted.list.isSearchFocused)
        XCTAssertTrue(hosted.list.isListFocused)

        let firstMatch = hosted.list.firstVisibleSnippetID
        let down = MainSplitViewController.nextSnippetArrowKeyCommand()
        XCTAssertTrue(
            UIApplication.shared.sendAction(down.action!, to: nil, from: down, for: nil)
        )
        XCTAssertEqual(hosted.list.selectedSnippetID, firstMatch)

        let secondMatch = hosted.list.adjacentSnippetID(forward: true)
        XCTAssertTrue(
            UIApplication.shared.sendAction(controlN.action!, to: nil, from: controlN, for: nil)
        )
        XCTAssertEqual(hosted.list.selectedSnippetID, secondMatch)

        let up = MainSplitViewController.previousSnippetArrowKeyCommand()
        XCTAssertTrue(
            UIApplication.shared.sendAction(up.action!, to: nil, from: up, for: nil)
        )
        XCTAssertEqual(hosted.list.selectedSnippetID, firstMatch)
        XCTAssertTrue(hosted.list.isListFocused)
    }

    func testSidebarKeepsProgrammaticSelectionVisibleAcrossReload() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Selected", content: "Visible selection")
        let controller = SnippetListViewController(environment: environment)
        let previousKeyWindow = currentKeyWindow()
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        controller.loadViewIfNeeded()
        controller.select(id: snippet.id)
        controller.reload(keepingSelection: true)
        controller.view.layoutIfNeeded()

        let tableView = controller.view.descendant(
            withAccessibilityIdentifier: "snippet-list"
        ) as? UITableView
        XCTAssertEqual(tableView?.indexPathForSelectedRow, IndexPath(row: 0, section: 0))
        XCTAssertTrue(tableView?.cellForRow(at: IndexPath(row: 0, section: 0))?.isSelected == true)
        XCTAssertTrue(
            tableView?.cellForRow(at: IndexPath(row: 0, section: 0))?
                .accessibilityTraits.contains(.selected) == true
        )
        XCTAssertNil(
            controller.view.descendant(withAccessibilityIdentifier: "delete-snippet"),
            "Deletion is available from the row context menu and swipe action"
        )
    }

    func testIPadMoreMenuOffersCloudSyncWithStatusSubtitle() throws {
        let environment = AppEnvironment()
        let disconnected = SnippetListViewController(environment: environment)
        disconnected.loadViewIfNeeded()

        let disconnectedMenu = try XCTUnwrap(
            disconnected.navigationItem.rightBarButtonItems?.last?.menu
        )
        let connect = try XCTUnwrap(
            disconnectedMenu.children
                .compactMap { $0 as? UIAction }
                .first { $0.title == "Connect iCloud" }
        )
        XCTAssertEqual(connect.subtitle, "Off. Your snippets stay on this device.")
        let generalTitles = disconnectedMenu.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(generalTitles.contains("Keyboard Shortcuts"))
        XCTAssertTrue(generalTitles.contains("Settings"))

        // Change only the preference after constructing the environment so this UI
        // test can exercise the enabled presentation without starting CloudKit.
        UserDefaults.standard.set(true, forKey: SyncCoordinator.enabledDefaultsKey)
        let connected = SnippetListViewController(environment: environment)
        connected.loadViewIfNeeded()

        let connectedMenu = try XCTUnwrap(
            connected.navigationItem.rightBarButtonItems?.last?.menu
        )
        let syncNow = try XCTUnwrap(
            connectedMenu.children
                .compactMap { $0 as? UIAction }
                .first { $0.title == "Sync Now" }
        )
        XCTAssertEqual(syncNow.subtitle, "Starting\u{2026}")
    }

    func testIPadEditorMoreMenuContainsOnlyCurrentSnippetActions() throws {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Menu", content: "Snippet actions")
        let editor = SnippetEditorViewController(environment: environment)
        editor.loadViewIfNeeded()
        editor.bind(to: snippet.id)

        let menu = try XCTUnwrap(editor.navigationItem.rightBarButtonItems?.first?.menu)
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(titles, ["Pin", "Copy Share Link", "Share", "Duplicate", "Delete"])
        XCTAssertFalse(titles.contains("Keyboard Shortcuts"))
        XCTAssertFalse(titles.contains("Settings"))
    }

    func testIPadRowContextMenuOffersMatchingSecurityTransition() {
        let environment = AppEnvironment()
        let ordinary = environment.store.addSnippet(name: "Ordinary", content: "Visible")
        let list = SnippetListViewController(environment: environment)

        let ordinaryTitles = list.contextMenu(for: ordinary).children
            .compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(ordinaryTitles.contains("Make Secure"))
        XCTAssertFalse(ordinaryTitles.contains("Make Ordinary"))

        let secureID = UUID()
        let secure = Snippet(id: secureID, name: "Secure", keyword: "", content: "")
        let secureProvider = SecureProviderStub(shell: secure)
        environment.store.secureProvider = secureProvider
        withExtendedLifetime(secureProvider) {
            let secureTitles = list.contextMenu(for: secure).children
                .compactMap { ($0 as? UIAction)?.title }
            XCTAssertTrue(secureTitles.contains("Make Ordinary"))
            XCTAssertFalse(secureTitles.contains("Make Secure"))
        }
    }

    func testSidebarTagFiltersWrapAndExpandWithoutHorizontalScrolling() {
        let filter = SidebarTagFilterView()
        let tags = [
            "Engineering", "Personal", "Meetings", "Support", "Email",
            "Planning", "Design", "Finance", "Documentation", "Research",
        ]
        let items = tags.enumerated().map {
            SidebarTagFilterView.Item(tag: $0.element, count: $0.offset + 1)
        }
        filter.update(
            items: items,
            activeKeys: []
        )

        let width: CGFloat = 300
        let collapsedHeight = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        filter.frame = CGRect(x: 0, y: 0, width: width, height: collapsedHeight)
        filter.layoutIfNeeded()

        XCTAssertGreaterThan(collapsedHeight, 38, "Several tags should wrap instead of scrolling sideways")
        XCTAssertFalse(filter.containsDescendant(ofType: UIScrollView.self))

        var toggledTag: String?
        filter.onToggleTag = { toggledTag = $0 }
        let engineering = filter.descendant(
            withAccessibilityIdentifier: "tag-filter-engineering"
        ) as? UIButton
        engineering?.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggledTag, "Engineering")

        filter.update(items: items, activeKeys: ["engineering"])
        filter.frame.size.height = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        filter.layoutIfNeeded()
        XCTAssertEqual(
            filter.descendant(withAccessibilityIdentifier: "tag-filter-engineering")?
                .accessibilityValue,
            "Selected"
        )

        var didClear = false
        filter.onClearFilters = { didClear = true }
        let clear = filter.descendant(
            withAccessibilityIdentifier: "clear-tag-filters"
        ) as? UIButton
        clear?.sendActions(for: .touchUpInside)
        XCTAssertTrue(didClear)

        let disclosure = filter.descendant(
            withAccessibilityIdentifier: "tag-filters-disclosure"
        ) as? UIButton
        XCTAssertNotNil(disclosure)
        XCTAssertFalse(disclosure?.isHidden == true)
        disclosure?.sendActions(for: .touchUpInside)

        let expandedHeight = filter.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
    }

    func testScrollFadeTracksOnlyEdgesWithHiddenContent() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = ScrollFadeContainerView(containing: scrollView)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        scrollView.contentSize = CGSize(width: 300, height: 600)

        scrollView.contentOffset = .zero
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 0, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 1, accuracy: 0.001)

        scrollView.contentOffset.y = 200
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 1, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 1, accuracy: 0.001)

        scrollView.contentOffset.y = 400
        container.updateFade()
        XCTAssertEqual(container.topFadeIntensity, 1, accuracy: 0.001)
        XCTAssertEqual(container.bottomFadeIntensity, 0, accuracy: 0.001)
    }

    func testDiagnosticsRotateRetainExportAndDeleteWithoutLeakingErrors() async throws {
        SnippetStorageLocations.createAllDirectories()

        let oldURL = SnippetStorageLocations.diagnosticsLogsFolderURL
            .appendingPathComponent("snippets-old.jsonl")
        let oldRecord = DiagnosticRecord(
            event: .lifecycle(.started),
            timestamp: "2026-01-01T00:00:00.000Z",
            elapsedMilliseconds: 0,
            sessionIdentifier: "old-test-session",
            sequence: 1)
        try oldRecord.jsonLine().write(to: oldURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -20 * 24 * 60 * 60)],
            ofItemAtPath: oldURL.path)

        var service: DiagnosticsService? = DiagnosticsService(
            retentionDays: 14,
            maximumFileSize: 1_024,
            maximumFileCount: 16,
            diskQuota: 64 * 1_024,
            registerGlobally: false,
            mirrorToOSLog: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))

        for _ in 0..<80 {
            service?.emit(.syncTriggered(.poll), level: .info, synchronous: false)
        }
        // Put the privacy assertions in the newest archive so a deliberately
        // tiny test quota does not evict them while exercising rotation.
        let forbiddenDescription = "PRIVATE-BODY-SENTINEL at /private/person/snippets.json"
        service?.emit(
            .storageFailure(
                area: .library,
                operation: .read,
                failure: DiagnosticFailure(NSError(
                    domain: "Private.SecretDomain",
                    code: 917,
                    userInfo: [NSLocalizedDescriptionKey: forbiddenDescription])),
                attempt: nil),
            level: .error,
            synchronous: true)
        service?.emit(
            .secureReveal(
                keyword: DiagnosticKeyword("approved keyword"),
                outcome: .revealed,
                caller: .trusted),
            level: .info,
            synchronous: true)
        service?.emit(
            .secureEditorTransition(
                surface: .phone,
                from: .protectedPlaintext,
                to: .locked,
                reason: .storeRefreshRemoteSync,
                vaultState: .unlocked),
            level: .info,
            synchronous: true)
        service?.flush()

        let summary = try XCTUnwrap(service?.summary())
        XCTAssertGreaterThan(summary.fileCount, 1)
        XCTAssertLessThanOrEqual(summary.byteCount, 64 * 1_024)

        let exportURL = rootURL.appendingPathComponent("diagnostics-export.jsonl")
        let result = try await service!.export(to: exportURL)
        XCTAssertGreaterThan(result.recordCount, 2)

        let export = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(export.contains("\"event\":\"diagnostics_manifest\""))
        XCTAssertTrue(export.contains("approved-keyword"))
        XCTAssertTrue(export.contains("\"event\":\"secure_editor_transition\""))
        XCTAssertTrue(export.contains("\"reason\":\"store_refresh_remote_sync\""))
        XCTAssertTrue(export.contains("\"vault_state\":\"unlocked\""))
        XCTAssertTrue(export.contains("\"error_code\":917"))
        XCTAssertFalse(export.contains("PRIVATE-BODY-SENTINEL"))
        XCTAssertFalse(export.contains("/private/person"))
        XCTAssertFalse(export.contains("Private.SecretDomain"))
        for line in export.split(separator: "\n") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }

        let logURLs = try FileManager.default.contentsOfDirectory(
            at: SnippetStorageLocations.diagnosticsLogsFolderURL,
            includingPropertiesForKeys: nil)
        for fileURL in logURLs where fileURL.pathExtension == "jsonl" {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }

        await service!.deleteStoredLogs()
        XCTAssertEqual(service?.summary().fileCount, 0)
        service = nil
    }

    func testLegacyRevealAuditMigrationDropsCallerPathAndPID() async throws {
        try FileManager.default.createDirectory(
            at: SnippetStorageLocations.vaultFolderURL,
            withIntermediateDirectories: true)
        let legacyDate = ISO8601DateFormatter().string(from: Date())
        let legacy = [[
            "at": legacyDate,
            "outcome": "revealed",
            "keyword": " legacy keyword ",
            "caller": "LEGACY-CALLER-SENTINEL /private/Caller.app",
            "pid": 8_675_309,
        ] as [String: Any]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try legacyData.write(to: SnippetStorageLocations.vaultAuditFileURL)

        let service = DiagnosticsService(
            registerGlobally: false,
            mirrorToOSLog: false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultAuditFileURL.path))

        let exportURL = rootURL.appendingPathComponent("legacy-diagnostics.jsonl")
        _ = try await service.export(to: exportURL)
        let export = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(export.contains("LEGACY-CALLER-SENTINEL"))
        XCTAssertFalse(export.contains("/private/Caller.app"))
        XCTAssertFalse(export.contains("\"pid\""))

        let objects = try export.split(separator: "\n").map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let migrated = try XCTUnwrap(objects.first { $0["event"] as? String == "secure_reveal" })
        let fields = try XCTUnwrap(migrated["fields"] as? [String: Any])
        XCTAssertEqual(fields["keyword"] as? String, "legacy-keyword")
        XCTAssertEqual(fields["outcome"] as? String, "revealed")
        XCTAssertEqual(fields["caller"] as? String, "unknown")
    }

    func testDiagnosticsExportRejectsFieldsOutsideClosedPrivacySchema() async throws {
        let service = DiagnosticsService(
            registerGlobally: false,
            mirrorToOSLog: false)
        let injectedURL = SnippetStorageLocations.diagnosticsLogsFolderURL
            .appendingPathComponent("snippets-injected.jsonl")
        let validRecord = DiagnosticRecord(
            event: .lifecycle(.becameActive),
            timestamp: "2026-08-09T09:00:00.000Z",
            elapsedMilliseconds: 1,
            sessionIdentifier: UUID().uuidString.lowercased(),
            sequence: 1)
        var injected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validRecord.jsonLine()) as? [String: Any])
        var fields = try XCTUnwrap(injected["fields"] as? [String: Any])
        fields["body"] = "PRIVATE-BODY-SENTINEL"
        injected["fields"] = fields
        var injectedData = try JSONSerialization.data(withJSONObject: injected)
        injectedData.append(0x0A)
        try injectedData.write(to: injectedURL)

        do {
            _ = try await service.export(to: rootURL.appendingPathComponent("unsafe.jsonl"))
            XCTFail("Export must reject fields that the typed event schema cannot create")
        } catch DiagnosticsExportError.corruptLog {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("unsafe.jsonl").path))
        } catch {
            XCTFail("Expected corruptLog, got \(error)")
        }
    }

    func testDeletingDiagnosticsRemovesAnUnmigratableLegacyAudit() async throws {
        try FileManager.default.createDirectory(
            at: SnippetStorageLocations.vaultFolderURL,
            withIntermediateDirectories: true)
        try Data("not a legacy audit".utf8).write(
            to: SnippetStorageLocations.vaultAuditFileURL)
        let service = DiagnosticsService(
            registerGlobally: false,
            mirrorToOSLog: false)

        XCTAssertTrue(service.summary().privacyCleanupNeeded)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultAuditFileURL.path))

        await service.deleteStoredLogs()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultAuditFileURL.path))
        XCTAssertFalse(service.summary().privacyCleanupNeeded)
    }

    private func hostMainSplit(
        environment: AppEnvironment,
        selecting snippetID: UUID? = nil
    ) -> (
        controller: MainSplitViewController,
        list: SnippetListViewController,
        editor: SnippetEditorViewController
    ) {
        let controller = MainSplitViewController(environment: environment)
        let previousKeyWindow = currentKeyWindow()
        let window = testWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let listNavigation = controller.viewController(for: .primary) as! UINavigationController
        let editorNavigation = controller.viewController(for: .secondary) as! UINavigationController
        let list = listNavigation.topViewController as! SnippetListViewController
        let editor = editorNavigation.topViewController as! SnippetEditorViewController
        list.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        if let snippetID {
            controller.snippetList(list, selected: snippetID)
        }
        controller.view.layoutIfNeeded()
        // Let the normal appearance callback establish the root responder before
        // a test invokes a shortcut that intentionally moves focus elsewhere.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        return (controller, list, editor)
    }

    private func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func testWindow(frame: CGRect) -> UIWindow {
        let scene = currentKeyWindow()?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    private func loadPendingSecurePlaintext(
        _ plaintext: String,
        into textView: SecureSnippetTextView
    ) throws {
        textView.setSceneCaptureStateForTesting(.inactive)
        textView.setSecureForegroundActiveForTesting(true)
        textView.setSecurePlaintextAcceptanceAuthorized(true)
        textView.setSecureRevealSessionAuthorized(true)
        var pendingCompletion: (() -> Void)?
        textView.setSecureCaptureFlushCompletionOverrideForTesting {
            pendingCompletion = $0
        }
        XCTAssertTrue(textView.displaySecurePlaintext(plaintext))
        XCTAssertNotNil(pendingCompletion)
        XCTAssertEqual(textView.text, plaintext)
    }
}

@MainActor
private final class SecureProviderStub: SecureSnippetProviding {
    let shell: Snippet
    var isActive = true

    init(shell: Snippet) { self.shell = shell }
    func secureShellsForDisplay() -> [Snippet] { isActive ? [shell] : [] }
    func isSecure(_ id: UUID) -> Bool { isActive && id == shell.id }
}

@MainActor
private final class TestSnippetPasteboard: SnippetPasteboard {
    var string: String?
    private(set) var secureExpiration: Date?
    private(set) var ordinaryWriteCount = 0
    private(set) var secureWriteCount = 0

    init(string: String?) {
        self.string = string
    }

    func writeOrdinaryText(_ text: String) {
        ordinaryWriteCount += 1
        string = text
    }

    func writeSecureText(_ text: String, expiresAt: Date) {
        secureWriteCount += 1
        secureExpiration = expiresAt
        string = text
    }
}

@MainActor
private extension UIView {
    func firstDescendant<T: UIView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }

    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }

    func containsDescendant<T: UIView>(ofType type: T.Type) -> Bool {
        if self is T { return true }
        return subviews.contains { $0.containsDescendant(ofType: type) }
    }

    /// Mirrors UIKit's containment rule closely enough for a hosted hierarchy
    /// regression: hidden accessibility subtrees cannot contribute descendants.
    func accessibilityElementViews() -> [UIView] {
        guard !isHidden, alpha > 0, !accessibilityElementsHidden else { return [] }
        let ownElement = isAccessibilityElement ? [self] : []
        return ownElement + subviews.flatMap { $0.accessibilityElementViews() }
    }
}
