import CryptoKit
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SecureRemediationTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureRemediationTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(previousSyncPreference, forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testPreparedVaultCreationWritesNothingUntilAcknowledgedAndCancelIsFinal() throws {
        let components = makeComponents()

        let cancelled = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))

        cancelled.cancel()
        XCTAssertThrowsError(try components.secureStore.commitVaultCreation(cancelled))
        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))

        let acknowledged = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        let document = try components.secureStore.commitVaultCreation(acknowledged)

        XCTAssertTrue(components.secureStore.hasVault)
        XCTAssertTrue(components.secureStore.hasRecoveryKey)
        XCTAssertTrue(components.keychain.hasKey(keyID: document.kid))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))
    }

    func testPromoteAndDemoteReloadBothStoresWithoutPlaintextResurrection() async throws {
        let components = makeComponents()
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let original = components.store.addSnippet(
            name: "Transition Test",
            content: "stale body")
        var latest = original
        latest.keyword = "transition-test"
        latest.content = "LATEST-PENDING-PLAINTEXT-SENTINEL"
        components.store.update(latest) // Deliberately leave the debounce pending.

        _ = try await components.session.unlock(reason: "Test promotion")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: original.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertNil(components.store.snippet(id: original.id))
        XCTAssertTrue(components.secureStore.isSecure(original.id))
        XCTAssertFalse(components.store.enabledSnippetsSorted().contains { $0.id == original.id })

        let ordinaryBytesAfterPromotion = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let ordinaryTextAfterPromotion = String(decoding: ordinaryBytesAfterPromotion, as: UTF8.self)
        XCTAssertFalse(ordinaryTextAfterPromotion.contains("LATEST-PENDING-PLAINTEXT-SENTINEL"))
        XCTAssertFalse(ordinaryTextAfterPromotion.contains(original.id.uuidString))

        let exportURL = rootURL.appendingPathComponent("ordinary-export.json")
        XCTAssertEqual(try components.store.exportSnippets(to: exportURL), 0)
        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(exportText.contains("LATEST-PENDING-PLAINTEXT-SENTINEL"))
        XCTAssertFalse(exportText.contains(original.id.uuidString))

        _ = try await components.session.unlock(reason: "Test secure content")
        XCTAssertEqual(
            try components.secureStore.content(for: original.id),
            "LATEST-PENDING-PLAINTEXT-SENTINEL")
        try components.secureStore.setContent(
            "LATEST-SECURE-EDIT-SENTINEL",
            for: original.id)

        try SecureSnippetTransitionCoordinator.demote(
            recordID: original.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertFalse(components.secureStore.isSecure(original.id))
        XCTAssertEqual(
            components.store.snippet(id: original.id)?.content,
            "LATEST-SECURE-EDIT-SENTINEL")
        XCTAssertFalse(components.secureStore.document?.records.contains {
            $0.id == original.id
        } == true)
    }

    func testCoordinatedMovesPublishOnceOnlyAfterBothCachesAgreeOnOwnership() async throws {
        let components = makeComponents()
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)
        let snippet = components.store.addSnippet(
            name: "Atomic transition",
            content: "body")
        components.store.flushPendingWrites()
        _ = try await components.session.unlock(reason: "Test atomic transition")

        var observedOwnership: [(ordinary: Bool, secure: Bool)] = []
        var syncChangeCount = 0
        components.store.onChange = { _ in
            observedOwnership.append((
                ordinary: components.store.snippet(id: snippet.id) != nil,
                secure: components.secureStore.isSecure(snippet.id)))
        }
        // Match AppEnvironment's production wiring: one secure structural change
        // refreshes the merged library and requests one sync round.
        components.secureStore.onChange = {
            components.store.onChange?(.init(source: .local))
            syncChangeCount += 1
        }

        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertEqual(observedOwnership.count, 1)
        XCTAssertEqual(observedOwnership.first?.ordinary, false)
        XCTAssertEqual(observedOwnership.first?.secure, true)
        XCTAssertEqual(syncChangeCount, 1)

        observedOwnership.removeAll()
        syncChangeCount = 0
        _ = try await components.session.unlock(reason: "Test atomic demotion")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertEqual(observedOwnership.count, 1)
        XCTAssertEqual(observedOwnership.first?.ordinary, true)
        XCTAssertEqual(observedOwnership.first?.secure, false)
        XCTAssertFalse(observedOwnership.contains { !$0.ordinary && !$0.secure })
        XCTAssertEqual(syncChangeCount, 1)
    }

    func testRecoveryAdditionIsFreshlyAuthenticatedButNotCommittedBeforeAcknowledgement() async throws {
        var authenticationCount = 0
        let components = try makeComponentsWithVaultMissingRecovery(
            authenticationEvaluator: { _ in
                authenticationCount += 1
                return true
            })

        let cancelledOptional = try await components.session.withOneUseAuthentication(
            reason: "Test recovery preparation"
        ) {
            try components.secureStore.prepareRecoveryKeyAddition()
        }
        let cancelled = try XCTUnwrap(cancelledOptional)
        XCTAssertFalse(components.secureStore.hasRecoveryKey)
        XCTAssertEqual(components.session.state, .locked)

        cancelled.cancel()
        XCTAssertThrowsError(
            try components.secureStore.commitRecoveryKeyAddition(cancelled))
        XCTAssertFalse(components.secureStore.hasRecoveryKey)

        let acknowledgedOptional = try await components.session.withOneUseAuthentication(
            reason: "Test recovery acknowledgement"
        ) {
            try components.secureStore.prepareRecoveryKeyAddition()
        }
        let acknowledged = try XCTUnwrap(acknowledgedOptional)
        XCTAssertFalse(components.secureStore.hasRecoveryKey)
        XCTAssertTrue(try components.secureStore.commitRecoveryKeyAddition(acknowledged))

        XCTAssertEqual(authenticationCount, 2)
        XCTAssertTrue(components.secureStore.hasRecoveryKey)
        XCTAssertThrowsError(
            try components.secureStore.commitRecoveryKeyAddition(acknowledged))
    }

    func testVaultWillLockHookCanUseKeyAfterDeadlineBeforeKeyIsDestroyed() async throws {
        let components = makeComponents(duration: 1)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)
        let snippet = components.store.addSnippet(name: "Pre-lock", content: "initial")
        let start = Date(timeIntervalSince1970: 10_000)
        var currentTime = start
        components.session.now = { currentTime }
        _ = try await components.session.unlock(reason: "Test promotion")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)
        _ = try await components.session.unlock(reason: "Test pre-lock ordering")
        currentTime = start.addingTimeInterval(2)

        let probe = PreLockProbe()
        let token = NotificationCenter.default.addObserver(
            forName: .snippetsVaultWillLock,
            object: components.session,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                probe.deliveryCount += 1
                probe.keyWasReadable = (try? components.session.currentKey()) != nil
                do {
                    try components.secureStore.setContent(
                        "PRELOCK-FLUSH-SENTINEL",
                        for: snippet.id)
                    probe.flushSucceeded = true
                } catch {
                    probe.flushSucceeded = false
                }
            }
        }
        let stateToken = NotificationCenter.default.addObserver(
            forName: .snippetsVaultStateChanged,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard !components.session.state.isUnlocked else { return }
                probe.postLockDeliveryCount += 1
                probe.keyWasGoneAtPostLock = (try? components.session.currentKey()) == nil
                probe.revealedText = ""
            }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            NotificationCenter.default.removeObserver(stateToken)
        }

        probe.revealedText = "PRELOCK-FLUSH-SENTINEL"

        components.session.lock()

        XCTAssertEqual(probe.deliveryCount, 1)
        XCTAssertTrue(probe.keyWasReadable)
        XCTAssertTrue(probe.flushSucceeded)
        XCTAssertEqual(probe.postLockDeliveryCount, 1)
        XCTAssertTrue(probe.keyWasGoneAtPostLock)
        XCTAssertEqual(probe.revealedText, "")
        XCTAssertEqual(components.session.state, .locked)
        XCTAssertThrowsError(try components.session.currentKey())

        _ = try await components.session.unlock(reason: "Verify pre-lock flush")
        XCTAssertEqual(
            try components.secureStore.content(for: snippet.id),
            "PRELOCK-FLUSH-SENTINEL")
    }

    func testVaultUseSlidesFiveMinuteIdleDeadlineButNeverPastAuthenticationCap() async throws {
        var authenticationCount = 0
        let components = makeComponents(
            duration: VaultSession.defaultDuration,
            authenticationEvaluator: { _ in
                authenticationCount += 1
                return true
            })
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let authenticatedAt = Date(timeIntervalSince1970: 20_000)
        var currentTime = authenticatedAt
        components.session.now = { currentTime }

        var unlockedTransitionCount = 0
        var unlockedCallbackCount = 0
        components.session.onStateChange = { state in
            if state.isUnlocked { unlockedCallbackCount += 1 }
        }
        let token = NotificationCenter.default.addObserver(
            forName: .snippetsVaultStateChanged,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if components.session.state.isUnlocked {
                    unlockedTransitionCount += 1
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await components.session.unlock(reason: "Test sliding idle deadline")
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(
            unlockedDeadline(components.session.state),
            authenticatedAt.addingTimeInterval(VaultSession.defaultDuration))
        XCTAssertEqual(unlockedTransitionCount, 1)
        XCTAssertEqual(unlockedCallbackCount, 1)

        // Each access occurs before the current five-minute idle deadline. It must
        // slide that deadline without turning a deadline detail into another public
        // lock-state transition (which would recursively make the editor read again).
        for elapsedMinutes in stride(from: 4, through: 28, by: 4) {
            currentTime = authenticatedAt.addingTimeInterval(TimeInterval(elapsedMinutes * 60))
            _ = try components.session.currentKey()
            XCTAssertEqual(
                unlockedDeadline(components.session.state),
                min(
                    currentTime.addingTimeInterval(VaultSession.defaultDuration),
                    authenticatedAt.addingTimeInterval(VaultSession.maximumWindow)))
        }

        currentTime = authenticatedAt.addingTimeInterval(VaultSession.maximumWindow - 1)
        _ = try components.session.currentKey()
        XCTAssertEqual(
            unlockedDeadline(components.session.state),
            authenticatedAt.addingTimeInterval(VaultSession.maximumWindow))
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(unlockedTransitionCount, 1)
        XCTAssertEqual(unlockedCallbackCount, 1)

        currentTime = authenticatedAt.addingTimeInterval(VaultSession.maximumWindow)
        XCTAssertThrowsError(try components.session.currentKey())
        XCTAssertEqual(components.session.state, .locked)
    }

    func testBackgroundKeyReadChecksButDoesNotSlideIdleDeadline() async throws {
        let components = makeComponents(duration: VaultSession.defaultDuration)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let authenticatedAt = Date(timeIntervalSince1970: 25_000)
        var currentTime = authenticatedAt
        components.session.now = { currentTime }
        _ = try await components.session.unlock(reason: "Test non-extending key read")
        let originalDeadline = unlockedDeadline(components.session.state)

        currentTime = authenticatedAt.addingTimeInterval(4 * 60)
        _ = try components.session.currentKeyWithoutExtendingSession()
        XCTAssertEqual(unlockedDeadline(components.session.state), originalDeadline)

        currentTime = originalDeadline
        XCTAssertThrowsError(try components.session.currentKeyWithoutExtendingSession())
        XCTAssertEqual(components.session.state, .locked)
    }

    func testExpiredDeadlineIsAuthoritativeWhenTimerDeliveryIsDelayed() async throws {
        let components = makeComponents(duration: 60)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let start = Date(timeIntervalSince1970: 30_000)
        var currentTime = start
        components.session.now = { currentTime }
        _ = try await components.session.unlock(reason: "Test delayed expiry timer")

        // Do not run the run loop or wait for the Timer. Advancing the injected clock
        // models a delayed callback; the stored deadline must still reject the key.
        currentTime = start.addingTimeInterval(60)
        XCTAssertThrowsError(try components.session.currentKey())
        XCTAssertEqual(components.session.state, .locked)
    }

    func testIOSResignActiveKeepsExpansionWindowButBackgroundLocksImmediately() async throws {
        let lifecycleCenter = NotificationCenter()
        let components = makeComponents(lifecycleNotificationCenter: lifecycleCenter)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)
        _ = try await components.session.unlock(reason: "Test iOS lifecycle locking")

        lifecycleCenter.post(
            name: UIApplication.willResignActiveNotification,
            object: nil)
        XCTAssertTrue(components.session.state.isUnlocked)
        XCTAssertNoThrow(try components.session.currentKey())

        lifecycleCenter.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        XCTAssertEqual(components.session.state, .locked)
        XCTAssertThrowsError(try components.session.currentKey())
    }

    func testSameVaultForegroundReloadPreservesAuthenticationAndUnlockedSession() async throws {
        let gate = AuthenticationGate()
        let evaluatorStarted = expectation(description: "authentication evaluator started")
        let components = makeComponents(authenticationEvaluator: { _ in
            evaluatorStarted.fulfill()
            return await gate.waitForDecision()
        })
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let unlockTask = Task { @MainActor in
            try await components.session.unlock(reason: "Test Face ID foreground reload")
        }
        await fulfillment(of: [evaluatorStarted], timeout: 1)

        // Models sceneDidBecomeActive racing the tail of LocalAuthentication.
        components.secureStore.reload(notifyChange: false)
        gate.finish(with: true)
        _ = try await unlockTask.value
        XCTAssertTrue(components.session.state.isUnlocked)
        XCTAssertNoThrow(try components.session.currentKey())

        // A second foreground reload immediately after the prompt must not destroy
        // the just-opened session either.
        components.secureStore.reload(notifyChange: false)
        XCTAssertTrue(components.session.state.isUnlocked)
        XCTAssertNoThrow(try components.session.currentKey())
    }

    func testBackgroundLockCancelsAuthenticationInFlightWithoutKeyResurrection() async throws {
        let gate = AuthenticationGate()
        let evaluatorStarted = expectation(description: "authentication evaluator started")
        let lifecycleCenter = NotificationCenter()
        let components = makeComponents(
            authenticationEvaluator: { _ in
                evaluatorStarted.fulfill()
                return await gate.waitForDecision()
            },
            lifecycleNotificationCenter: lifecycleCenter)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let unlockTask = Task { @MainActor in
            try await components.session.unlock(reason: "Test cancelled authentication")
        }
        await fulfillment(of: [evaluatorStarted], timeout: 1)

        lifecycleCenter.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        XCTAssertEqual(components.session.state, .locked)

        gate.finish(with: true)
        do {
            _ = try await unlockTask.value
            XCTFail("a completed prompt must not reopen a session after lifecycle lock")
        } catch VaultSession.Failure.locked {
            // Expected: lock invalidated the exact LAContext owned by this attempt.
        } catch {
            XCTFail("expected a locked failure, got \(error)")
        }
        XCTAssertEqual(components.session.state, .locked)
        XCTAssertThrowsError(try components.session.currentKey())
    }

    func testSecureTextViewBlocksAmbientDisclosureAndRecoveryClipboardIsLocalAndExpiring() {
        let textView = SecureSnippetTextView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let ordinaryIsAccessibilityElement = textView.isAccessibilityElement
        let ordinaryAccessibilityElementsHidden = textView.accessibilityElementsHidden
        textView.accessibilityLabel = "Ordinary snippet content"
        textView.accessibilityUserInputLabels = ["Ordinary body input"]
        textView.accessibilityIdentifier = "ordinary-snippet-content"
        let forwardingTextInput = UITextView()
        textView.accessibilityValueBlock = { "SECURE-BODY-AX-SENTINEL" }
        textView.accessibilityAttributedValueBlock = {
            NSAttributedString(string: "SECURE-BODY-AX-SENTINEL")
        }
        textView.accessibilityUserInputLabelsBlock = { ["SECURE-BODY-AX-SENTINEL"] }
        textView.accessibilityTextualContextBlock = { .sourceCode }
        textView.accessibilityElementsBlock = { [forwardingTextInput] }
        textView.automationElementsBlock = { [forwardingTextInput] }
        textView.accessibilityTextInputResponder = forwardingTextInput
        textView.accessibilityTextInputResponderBlock = { forwardingTextInput }
        textView.accessibilityPreviousTextNavigationElement = forwardingTextInput
        textView.accessibilityNextTextNavigationElement = forwardingTextInput
        textView.accessibilityPreviousTextNavigationElementBlock = { forwardingTextInput }
        textView.accessibilityNextTextNavigationElementBlock = { forwardingTextInput }
        textView.setSceneCaptureStateForTesting(.inactive)
        textView.setSecureForegroundActiveForTesting(true)
        XCTAssertTrue(textView.bindSecureRedacted())
        textView.setSecurePlaintextAcceptanceAuthorized(true)
        textView.setSecureRevealSessionAuthorized(true)
        XCTAssertTrue(textView.displaySecurePlaintext("SECURE-BODY-AX-SENTINEL"))

        // A visual reveal must not make the UIKit text storage queryable through
        // accessibility. Later assignments are redacted as well as the transition.
        textView.isAccessibilityElement = true
        textView.accessibilityElementsHidden = false
        textView.accessibilityLabel = "SECURE-BODY-AX-SENTINEL"
        textView.accessibilityValue = "SECURE-BODY-AX-SENTINEL"
        textView.accessibilityHint = "SECURE-BODY-AX-SENTINEL"
        textView.accessibilityAttributedLabel = NSAttributedString(
            string: "SECURE-BODY-AX-SENTINEL")
        textView.accessibilityAttributedValue = NSAttributedString(
            string: "SECURE-BODY-AX-SENTINEL")
        textView.accessibilityAttributedHint = NSAttributedString(
            string: "SECURE-BODY-AX-SENTINEL")
        textView.accessibilityUserInputLabels = ["SECURE-BODY-AX-SENTINEL"]
        textView.accessibilityAttributedUserInputLabels = [NSAttributedString(
            string: "SECURE-BODY-AX-SENTINEL")]
        textView.accessibilityTextualContext = .sourceCode

        XCTAssertFalse(textView.isAccessibilityElement)
        XCTAssertTrue(textView.accessibilityElementsHidden)
        XCTAssertNil(textView.accessibilityLabel)
        XCTAssertNil(textView.accessibilityValue)
        XCTAssertNil(textView.accessibilityHint)
        XCTAssertNil(textView.accessibilityIdentifier)
        XCTAssertNil(textView.accessibilityAttributedLabel)
        XCTAssertNil(textView.accessibilityAttributedValue)
        XCTAssertNil(textView.accessibilityAttributedHint)
        XCTAssertEqual(textView.accessibilityUserInputLabels ?? [], [])
        XCTAssertEqual(textView.accessibilityAttributedUserInputLabels ?? [], [])
        XCTAssertNil(textView.accessibilityTextualContext)
        XCTAssertFalse(textView.isAccessibilityElementBlock?() ?? true)
        XCTAssertNil(textView.accessibilityLabelBlock?())
        XCTAssertNil(textView.accessibilityValueBlock?())
        XCTAssertNil(textView.accessibilityHintBlock?())
        XCTAssertNil(textView.accessibilityIdentifierBlock?())
        XCTAssertNil(textView.accessibilityAttributedLabelBlock?())
        XCTAssertNil(textView.accessibilityAttributedValueBlock?())
        XCTAssertNil(textView.accessibilityAttributedHintBlock?())
        XCTAssertNil(textView.accessibilityTextualContextBlock?())
        XCTAssertEqual(textView.accessibilityUserInputLabelsBlock?() ?? [], [])
        XCTAssertEqual(textView.accessibilityAttributedUserInputLabelsBlock?() ?? [], [])
        XCTAssertTrue(textView.accessibilityElementsHiddenBlock?() ?? false)
        XCTAssertTrue((textView.accessibilityElementsBlock?() ?? []).isEmpty)
        XCTAssertTrue((textView.automationElementsBlock?() ?? []).isEmpty)
        XCTAssertTrue((textView.accessibilityElements ?? []).isEmpty)
        XCTAssertTrue((textView.automationElements ?? []).isEmpty)
        XCTAssertEqual(textView.accessibilityElementCount(), 0)
        XCTAssertNil(textView.accessibilityElement(at: 0))
        XCTAssertEqual(
            textView.index(ofAccessibilityElement: forwardingTextInput),
            NSNotFound)
        XCTAssertNil(textView.accessibilityPreviousTextNavigationElement)
        XCTAssertNil(textView.accessibilityNextTextNavigationElement)
        XCTAssertNil(textView.accessibilityPreviousTextNavigationElementBlock?())
        XCTAssertNil(textView.accessibilityNextTextNavigationElementBlock?())
        XCTAssertNil(textView.accessibilityTextInputResponder)
        XCTAssertNil(textView.accessibilityTextInputResponderBlock?())
        XCTAssertNil(textView.accessibilityHitTest(.zero, event: nil))

        for selectorName in [
            "copy:", "cut:", "undo:", "redo:", "_share:", "_define:", "translate:"
        ] {
            XCTAssertFalse(textView.canPerformAction(
                NSSelectorFromString(selectorName),
                withSender: nil))
        }
        XCTAssertEqual(textView.autocorrectionType, .no)
        XCTAssertEqual(textView.spellCheckingType, .no)
        XCTAssertEqual(textView.smartInsertDeleteType, .no)
        XCTAssertEqual(textView.textContentType, .password)
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        XCTAssertFalse(textView.isFindInteractionEnabled)
        XCTAssertFalse(AppDelegate.allowsExtensionPoint(.keyboard))

        textView.bindOrdinaryText("")
        XCTAssertEqual(
            textView.text,
            "",
            "secure text storage must be cleared before ordinary accessibility returns")
        XCTAssertEqual(textView.isAccessibilityElement, ordinaryIsAccessibilityElement)
        XCTAssertEqual(
            textView.accessibilityElementsHidden,
            ordinaryAccessibilityElementsHidden)
        XCTAssertEqual(textView.accessibilityIdentifier, "ordinary-snippet-content")
        textView.text = "ordinary body"
        textView.accessibilityLabel = "Snippet content"
        XCTAssertEqual(textView.text, "ordinary body")
        XCTAssertEqual(textView.accessibilityLabel, "Snippet content")
        XCTAssertEqual(textView.autocorrectionType, .default)
        XCTAssertEqual(textView.spellCheckingType, .default)
        XCTAssertEqual(textView.writingToolsBehavior, .default)
        XCTAssertTrue(textView.isFindInteractionEnabled)

        let instant = Date(timeIntervalSince1970: 20_000)
        let options = RecoveryKeyPasteboard.options(now: instant)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(
            options[.expirationDate] as? Date,
            instant.addingTimeInterval(RecoveryKeyPasteboard.lifetime))
    }

    func testSecureBodyAccessibilityNoticeContainsOnlyFixedSafeCopy() {
        let notice = SecureBodyAccessibilityNoticeView()
        let privateSentinels = [
            "BODY-PRIVATE-SENTINEL",
            "NAME-PRIVATE-SENTINEL",
            "KEYWORD-PRIVATE-SENTINEL",
            "TAG-PRIVATE-SENTINEL",
        ]

        notice.state = .locked
        XCTAssertTrue(notice.isAccessibilityElement)
        XCTAssertFalse(notice.accessibilityElementsHidden)
        XCTAssertEqual(
            notice.accessibilityLabel,
            SecureBodyAccessibilityNoticeView.protectedLabel)
        XCTAssertEqual(
            notice.accessibilityValue,
            SecureBodyAccessibilityNoticeView.lockedValue)

        notice.state = .authenticatedRedacted
        XCTAssertEqual(
            notice.accessibilityValue,
            SecureBodyAccessibilityNoticeView.authenticatedValue)

        notice.state = .visuallyRevealed
        XCTAssertEqual(
            notice.accessibilityValue,
            SecureBodyAccessibilityNoticeView.revealedValue)
        let exposedCopy = [
            notice.accessibilityLabel,
            notice.accessibilityValue,
            notice.accessibilityHint,
        ].compactMap { $0 }.joined(separator: " ")
        for sentinel in privateSentinels {
            XCTAssertFalse(exposedCopy.contains(sentinel))
        }

        notice.state = .hidden
        XCTAssertFalse(notice.isAccessibilityElement)
        XCTAssertTrue(notice.accessibilityElementsHidden)
        XCTAssertNil(notice.accessibilityLabel)
        XCTAssertNil(notice.accessibilityValue)
    }

    func testEncryptedBackupKDFYieldsMainActorAndStillRoundTrips() async throws {
        let components = makeComponents()
        _ = components.store.addSnippet(name: "Backup", content: "body")
        let probe = MainActorHeartbeat()
        Task { @MainActor in probe.didRun = true }

        let result = try await components.secureStore.makeEncryptedBackup(
            store: components.store,
            passphrase: "test passphrase",
            iterations: 1)

        XCTAssertTrue(probe.didRun)
        let opened = try EncryptedSnippetBackup.open(
            result.data,
            passphrase: "test passphrase")
        XCTAssertEqual(opened.snippets.count, 1)
        XCTAssertEqual(result.ordinaryCount, 1)
    }

    func testForgetEverythingPreservesOrdinarySyncStateAcrossRestart() async throws {
        SnippetStorageLocations.createAllDirectories()
        let components = makeComponents()
        let pendingVault = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pendingVault)

        let ordinary = components.store.addSnippet(
            name: "Ordinary survivor", content: "confirmed ordinary body")
        let toSecure = components.store.addSnippet(
            name: "Secure removal", content: "secure body")
        components.store.flushPendingWrites()
        _ = try await components.session.unlock(reason: "Prepare secure forget regression")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: toSecure.id,
            store: components.store,
            secureStore: components.secureStore)

        let vault = try XCTUnwrap(components.secureStore.document)
        let confirmedProjection = SyncLibraryProjection.currentEnvelopes(
            snippets: components.store.snippets,
            records: vault.records,
            deviceID: components.store.deviceID,
            metadata: SyncBase(),
            vaultKID: vault.kid)
        let ordinaryConfirmed = try XCTUnwrap(confirmedProjection[ordinary.id])
        let secureConfirmed = try XCTUnwrap(confirmedProjection[toSecure.id])
        XCTAssertFalse(ordinaryConfirmed.secure)
        XCTAssertTrue(secureConfirmed.secure)

        let ordinaryVersion = SyncRecordVersion(Data("ordinary-system-fields".utf8))
        let secureVersion = SyncRecordVersion(Data("secure-system-fields".utf8))
        let accountIdentity = SyncAccountIdentity(Data(repeating: 0x73, count: 32))
        var confirmedBase = SyncBase(
            cursor: SyncCursor("73"),
            cursorKind: .cloudKitSyncEngine,
            accountIdentity: accountIdentity)
        confirmedBase.recordConfirmed(
            ordinaryConfirmed, recordVersion: ordinaryVersion)
        confirmedBase.recordConfirmed(
            secureConfirmed, recordVersion: secureVersion)

        var editedOrdinary = ordinary
        editedOrdinary.content = "ordinary pending edit"
        editedOrdinary.updatedAt = ordinary.updatedAt.addingTimeInterval(10)
        components.store.update(editedOrdinary)
        components.store.flushPendingWrites()
        let desiredProjection = SyncLibraryProjection.currentEnvelopes(
            snippets: components.store.snippets,
            records: vault.records,
            deviceID: components.store.deviceID,
            metadata: confirmedBase,
            agreedBase: confirmedBase,
            vaultKID: vault.kid)
        let ordinaryDesired = try XCTUnwrap(desiredProjection[ordinary.id])
        XCTAssertNotEqual(ordinaryDesired, ordinaryConfirmed)

        let ordinaryEntry = SyncJournal.Entry(
            desired: ordinaryDesired,
            offered: nil,
            generation: 2,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20))
        let secureEntry = SyncJournal.Entry(
            desired: secureConfirmed,
            offered: SyncJournal.Offered(
                envelope: secureConfirmed,
                generation: 1,
                recordVersion: secureVersion),
            generation: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10))
        let journal = SyncJournal(entries: [
            SyncBase.key(ordinary.id): ordinaryEntry,
            SyncBase.key(toSecure.id): secureEntry,
        ])
        try SyncBaseFile.write(confirmedBase)
        try SyncJournalFile.write(journal)

        try components.secureStore.forgetEverything(syncIsQuiescent: true)

        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path),
            "forget must rewrite base.json, not remove the ordinary confirmation fence")

        let retainedBase: SyncBase
        switch SyncBaseFile.load() {
        case .loaded(let loaded): retainedBase = loaded
        default:
            XCTFail("expected retained base.json to remain readable")
            return
        }
        XCTAssertEqual(retainedBase.envelope(ordinary.id), ordinaryConfirmed)
        XCTAssertNil(retainedBase.envelope(toSecure.id))
        XCTAssertEqual(retainedBase.recordVersion(ordinary.id), ordinaryVersion,
                       "forget must retain ordinary CloudKit replacement authority")
        XCTAssertNil(retainedBase.recordVersion(toSecure.id),
                     "forgotten secure ciphertext must not leave replacement authority behind")
        XCTAssertEqual(retainedBase.accountIdentity, accountIdentity,
                       "secure forget must keep ordinary ancestry bound to its iCloud account")
        XCTAssertNil(retainedBase.cursor,
                     "the next opt-in must fetch remote secure state from the beginning")
        XCTAssertNil(retainedBase.cursorKind,
                     "forgetting a cursor must also forget which transport issued it")
        let retainedBaseBytes = try Data(
            contentsOf: SnippetStorageLocations.syncBaseFileURL)
        let retainedBaseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: retainedBaseBytes) as? [String: Any])
        XCTAssertEqual(retainedBaseObject["schemaVersion"] as? Int, 3,
                       "secure forget must persist the current schema fence")
        XCTAssertNil(retainedBaseObject["cursor"])
        XCTAssertNil(retainedBaseObject["cursorKind"])

        let retainedJournal: SyncJournal
        switch SyncJournalFile.load() {
        case .loaded(let loaded): retainedJournal = loaded
        default:
            XCTFail("expected retained journal.json to remain readable")
            return
        }
        XCTAssertEqual(retainedJournal.entry(ordinary.id), ordinaryEntry)
        XCTAssertNil(retainedJournal.entry(toSecure.id))
        XCTAssertEqual(retainedJournal.pending(confirmed: retainedBase), [ordinaryDesired])

        // Recreate both stores as a process restart would. Overlaying the retained
        // journal onto the retained base must recover the exact pending ordinary edit,
        // while the forgotten secure id no longer blocks projection or becomes a delete.
        let restartedSession = VaultSession(
            keychain: components.keychain,
            authenticationEvaluator: { _ in true })
        let restartedStore = SnippetStore(configuration: .iOS)
        let restartedSecureStore = SecureSnippetStore(
            session: restartedSession,
            keychain: components.keychain,
            deviceID: restartedStore.deviceID)
        restartedStore.secureProvider = restartedSecureStore
        XCTAssertFalse(restartedSecureStore.hasVault)
        let restartedBridge = SnippetLibraryBridge(
            store: restartedStore,
            secureStore: restartedSecureStore)
        let restartedProjection = try restartedBridge.currentEnvelopes(
            agreedBase: retainedJournal.projectionKnowledge(over: retainedBase))
        XCTAssertEqual(restartedProjection[ordinary.id], ordinaryDesired)
        XCTAssertNil(restartedProjection[toSecure.id])
    }

    func testForgetEverythingRefusesMissingBaseWhenJournalExists() throws {
        SnippetStorageLocations.createAllDirectories()
        let components = makeComponents()
        let pendingVault = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        let vault = try components.secureStore.commitVaultCreation(pendingVault)
        try SyncJournalFile.write(SyncJournal())
        let vaultBytes = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let journalBytes = try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))

        XCTAssertThrowsError(
            try components.secureStore.forgetEverything(syncIsQuiescent: true)
        ) { error in
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected fail-closed sync transaction error, got \(error)")
            }
            XCTAssertTrue(detail.contains("confirmed sync state is missing"))
        }

        XCTAssertTrue(components.secureStore.hasVault)
        XCTAssertTrue(components.keychain.hasKey(keyID: vault.kid))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBytes)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL), journalBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
    }

    func testForgetEverythingRefusesMarkedBaseWhenJournalIsMissing() throws {
        SnippetStorageLocations.createAllDirectories()
        let components = makeComponents()
        let pendingVault = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        let vault = try components.secureStore.commitVaultCreation(pendingVault)
        try SyncBaseFile.write(SyncBase(journalEstablished: true))
        let vaultBytes = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let baseBytes = try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))

        XCTAssertThrowsError(
            try components.secureStore.forgetEverything(syncIsQuiescent: true)
        ) { error in
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected fail-closed sync transaction error, got \(error)")
            }
            XCTAssertTrue(detail.contains("pending sync state is missing"))
        }

        XCTAssertTrue(components.secureStore.hasVault)
        XCTAssertTrue(components.keychain.hasKey(keyID: vault.kid))
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBytes)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL), baseBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
    }

    func testForgetEverythingOnFreshSyncDoesNotManufactureProtocolFiles() throws {
        SnippetStorageLocations.createAllDirectories()
        let components = makeComponents()
        let pendingVault = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        let vault = try components.secureStore.commitVaultCreation(pendingVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))

        try components.secureStore.forgetEverything(syncIsQuiescent: true)

        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(components.keychain.hasKey(keyID: vault.kid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
    }

    func testForgetRollbackAfterKeychainRefusalRestoresExactVaultBaseAndJournal() async throws {
        var removalAttempts = 0
        let components = makeComponents(vaultKeyRemover: { _ in
            removalAttempts += 1
            throw InjectedForgetFailure.keychainDelete
        })
        let snapshot = try await prepareForgetRollbackSnapshot(components)

        XCTAssertThrowsError(
            try components.secureStore.forgetEverything(syncIsQuiescent: true)
        ) { error in
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected rollback transaction error, got \(error)")
            }
            XCTAssertTrue(detail.contains("keychain kept the vault key"))
            XCTAssertTrue(detail.contains("original state was restored"))
        }

        XCTAssertEqual(removalAttempts, 1)
        try assertForgetSnapshotRestored(snapshot, components: components)
    }

    func testForgetRollbackAfterJournalPostRenameFailureRestoresExactProtocolState() async throws {
        var journalWriteCount = 0
        let components = makeComponents(syncJournalWriter: { journal, url, temporary in
            journalWriteCount += 1
            try SyncJournalFile.write(journal, to: url, temporaryDirectory: temporary)
            if journalWriteCount == 1 {
                throw InjectedForgetFailure.journalDirectoryFence
            }
        })
        let snapshot = try await prepareForgetRollbackSnapshot(components)

        XCTAssertThrowsError(
            try components.secureStore.forgetEverything(syncIsQuiescent: true)
        ) { error in
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected rollback transaction error, got \(error)")
            }
            XCTAssertTrue(detail.contains("could not durably preserve ordinary sync state"))
            XCTAssertTrue(detail.contains("original state was restored"))
        }

        XCTAssertEqual(journalWriteCount, 2,
                       "first write publishes pruned state; rollback rewrites the original journal")
        try assertForgetSnapshotRestored(snapshot, components: components)
    }

    func testForgetRollbackAfterPostUnlinkFailureRestoresExactVaultAndProtocolState() async throws {
        var removalCount = 0
        var observedVaultAbsentAfterUnlink = false
        let components = makeComponents(durableFileRemover: { url in
            removalCount += 1
            try AtomicFileWriter.removeDurablyIfPresent(url)
            if removalCount == 1 {
                observedVaultAbsentAfterUnlink = !FileManager.default.fileExists(atPath: url.path)
                throw InjectedForgetFailure.vaultDirectoryFence
            }
        })
        let snapshot = try await prepareForgetRollbackSnapshot(components)

        XCTAssertThrowsError(
            try components.secureStore.forgetEverything(syncIsQuiescent: true)
        ) { error in
            guard case SecureSnippetStore.Failure.transaction(let detail) = error else {
                return XCTFail("expected rollback transaction error, got \(error)")
            }
            XCTAssertTrue(detail.contains("could not durably delete the vault"))
            XCTAssertTrue(detail.contains("original state was restored"))
        }

        XCTAssertEqual(removalCount, 1)
        XCTAssertTrue(observedVaultAbsentAfterUnlink,
                      "the injected failure must occur after unlink became visible")
        try assertForgetSnapshotRestored(snapshot, components: components)
    }

    func testNotificationObserversDoNotRetainEditors() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Lifecycle", content: "body")
        weak var phoneEditor: PhoneSnippetEditorViewController?
        weak var tabletEditor: SnippetEditorViewController?

        autoreleasepool {
            let phone = PhoneSnippetEditorViewController(
                environment: environment,
                snippetID: snippet.id)
            phone.loadViewIfNeeded()
            phoneEditor = phone

            let tablet = SnippetEditorViewController(environment: environment)
            tablet.loadViewIfNeeded()
            tablet.bind(to: snippet.id)
            tabletEditor = tablet
        }

        XCTAssertNil(phoneEditor)
        XCTAssertNil(tabletEditor)
    }

    private func makeComponents(
        duration: TimeInterval = VaultSession.defaultDuration,
        authenticationEvaluator: @escaping VaultSession.AuthenticationEvaluator = { _ in true },
        lifecycleNotificationCenter: NotificationCenter = .default,
        syncBaseWriter: @escaping (SyncBase, URL, URL) throws -> Void = {
            try SyncBaseFile.write($0, to: $1, temporaryDirectory: $2)
        },
        syncJournalWriter: @escaping (SyncJournal, URL, URL) throws -> Void = {
            try SyncJournalFile.write($0, to: $1, temporaryDirectory: $2)
        },
        durableFileRemover: @escaping (URL) throws -> Void = {
            try AtomicFileWriter.removeDurablyIfPresent($0)
        },
        vaultKeyRemover: ((String) throws -> Void)? = nil
    ) -> Components {
        let keychain = makeKeychain()
        let session = VaultSession(
            keychain: keychain,
            duration: duration,
            authenticationEvaluator: authenticationEvaluator,
            lifecycleNotificationCenter: lifecycleNotificationCenter)
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID,
            syncBaseWriter: syncBaseWriter,
            syncJournalWriter: syncJournalWriter,
            durableFileRemover: durableFileRemover,
            vaultKeyRemover: vaultKeyRemover)
        store.secureProvider = secureStore
        return Components(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: keychain)
    }

    private func unlockedDeadline(
        _ state: VaultSession.State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Date {
        guard case .unlocked(let deadline) = state else {
            XCTFail("expected an unlocked vault state, got \(state)", file: file, line: line)
            return .distantPast
        }
        return deadline
    }

    private func prepareForgetRollbackSnapshot(
        _ components: Components
    ) async throws -> ForgetRollbackSnapshot {
        SnippetStorageLocations.createAllDirectories()
        let pendingVault = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pendingVault)
        let snippet = components.store.addSnippet(
            name: "Rollback secure", content: "confirmed secure content")
        components.store.flushPendingWrites()
        _ = try await components.session.unlock(reason: "Prepare forget rollback")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)

        func projectedSecure() throws -> SyncEnvelope {
            let vault = try XCTUnwrap(components.secureStore.document)
            let projection = SyncLibraryProjection.currentEnvelopes(
                snippets: components.store.snippets,
                records: vault.records,
                deviceID: components.store.deviceID,
                metadata: SyncBase(),
                vaultKID: vault.kid)
            return try XCTUnwrap(projection[snippet.id])
        }

        let confirmed = try projectedSecure()
        _ = try await components.session.unlock(reason: "Prepare offered secure state")
        try components.secureStore.setContent("offered secure content", for: snippet.id)
        let offered = try projectedSecure()
        _ = try await components.session.unlock(reason: "Prepare desired secure state")
        try components.secureStore.setContent("newer desired secure content", for: snippet.id)
        let desired = try projectedSecure()
        XCTAssertNotEqual(confirmed, offered)
        XCTAssertNotEqual(offered, desired)

        let rollbackVersion = SyncRecordVersion(Data("rollback-system-fields".utf8))
        let rollbackAccountIdentity = SyncAccountIdentity(Data(repeating: 0x11, count: 32))
        var base = SyncBase(
            cursor: SyncCursor("111"),
            journalEstablished: true,
            accountIdentity: rollbackAccountIdentity)
        base.recordConfirmed(
            confirmed,
            recordVersion: rollbackVersion)
        let journal = SyncJournal(entries: [
            SyncBase.key(snippet.id): SyncJournal.Entry(
                desired: desired,
                offered: SyncJournal.Offered(
                    envelope: offered,
                    generation: 1,
                    recordVersion: rollbackVersion),
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 123.456)),
        ])
        try SyncBaseFile.write(base)
        try SyncJournalFile.write(journal)
        let vault = try XCTUnwrap(components.secureStore.document)

        return ForgetRollbackSnapshot(
            keyID: vault.kid,
            snippetID: snippet.id,
            base: base,
            journal: journal,
            vaultBytes: try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            baseBytes: try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            journalBytes: try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL))
    }

    private func assertForgetSnapshotRestored(
        _ snapshot: ForgetRollbackSnapshot,
        components: Components,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(components.secureStore.hasVault, file: file, line: line)
        XCTAssertTrue(components.keychain.hasKey(keyID: snapshot.keyID), file: file, line: line)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
            snapshot.vaultBytes,
            file: file,
            line: line)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncBaseFileURL),
            snapshot.baseBytes,
            file: file,
            line: line)
        XCTAssertEqual(
            try Data(contentsOf: SnippetStorageLocations.syncJournalFileURL),
            snapshot.journalBytes,
            file: file,
            line: line)

        guard case .loaded(let base) = SyncBaseFile.load() else {
            return XCTFail("restored base is unreadable", file: file, line: line)
        }
        guard case .loaded(let journal) = SyncJournalFile.load() else {
            return XCTFail("restored journal is unreadable", file: file, line: line)
        }
        XCTAssertEqual(base, snapshot.base, file: file, line: line)
        XCTAssertEqual(
            base.accountIdentity,
            snapshot.base.accountIdentity,
            "rollback must restore the exact account binding",
            file: file,
            line: line)
        XCTAssertEqual(journal, snapshot.journal, file: file, line: line)
        XCTAssertEqual(
            journal.entry(snapshot.snippetID)?.offered,
            snapshot.journal.entry(snapshot.snippetID)?.offered,
            file: file,
            line: line)
        XCTAssertEqual(
            journal.entry(snapshot.snippetID)?.desired,
            snapshot.journal.entry(snapshot.snippetID)?.desired,
            file: file,
            line: line)
    }

    private func makeComponentsWithVaultMissingRecovery(
        authenticationEvaluator: @escaping VaultSession.AuthenticationEvaluator
    ) throws -> Components {
        let keychain = makeKeychain()
        let keyring = SnippetCrypto.Keyring.generate()
        let keyID = "test-vault-\(UUID().uuidString.lowercased())"
        try keychain.store(
            keyring.libraryKey.withUnsafeBytes { Data($0) },
            keyID: keyID)
        let document = VaultDocument(
            kid: keyID,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(SnippetCrypto.randomBytes(16))))
        try VaultFile.write(document)

        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: authenticationEvaluator)
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return Components(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: keychain)
    }

    private func makeKeychain() -> KeychainSecretStore {
        KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
    }
}

@MainActor
private struct Components {
    let store: SnippetStore
    let secureStore: SecureSnippetStore
    let session: VaultSession
    let keychain: KeychainSecretStore
}

private struct ForgetRollbackSnapshot {
    let keyID: String
    let snippetID: UUID
    let base: SyncBase
    let journal: SyncJournal
    let vaultBytes: Data
    let baseBytes: Data
    let journalBytes: Data
}

private enum InjectedForgetFailure: Error {
    case keychainDelete
    case journalDirectoryFence
    case vaultDirectoryFence
}

@MainActor
private final class PreLockProbe {
    var deliveryCount = 0
    var keyWasReadable = false
    var flushSucceeded = false
    var postLockDeliveryCount = 0
    var keyWasGoneAtPostLock = false
    var revealedText = ""
}

@MainActor
private final class AuthenticationGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func waitForDecision() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish(with result: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private final class MainActorHeartbeat {
    var didRun = false
}
