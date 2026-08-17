import Foundation
import XCTest

/// Build-time coverage for the silent-push half of CKSyncEngine adoption.
///
/// These checks inspect the actual plist/entitlement inputs and the artifact-validation
/// scripts instead of registering for user-visible notifications. CKSyncEngine owns its
/// CloudKit subscription and needs silent-push capability without alert consent.
final class CloudKitSyncCapabilityTests: XCTestCase {
    func testBothAppsDeclareAPSEntitlement() throws {
        for (relativePath, key) in [
            ("snippets/Snippets.entitlements", "com.apple.developer.aps-environment"),
            ("snippets-ios/Snippets-iOS.entitlements", "aps-environment"),
        ] {
            let entitlements = try propertyList(at: repositoryRoot.appendingPathComponent(relativePath))
            let environment = entitlements[key] as? String
            XCTAssertFalse(
                environment?.isEmpty ?? true,
                "\(relativePath) must opt into CloudKit silent pushes")
        }
    }

    func testIOSBuildDeclaresRemoteNotificationBackgroundMode() throws {
        let info = try propertyList(
            at: repositoryRoot.appendingPathComponent("snippets-ios/Info-iOS.plist"))
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])

        XCTAssertTrue(
            modes.contains("remote-notification"),
            "the real iOS Info.plist input must permit silent remote-notification wakes")
    }

    func testDeviceInstallerValidatesSignedAPSProfileAndBuiltBackgroundMode() throws {
        let source = try source(at: "scripts/install-ios.sh")

        for required in [
            #"codesign -d --entitlements :- "$APP_PATH""#,
            #"security cms -D -i "$APP_PATH/embedded.mobileprovision""#,
            #"actual_aps_environment="$(plist_value "$WORK_DIR/app-entitlements.plist""#,
            #"aps-environment || true)"#,
            #"actual_background_modes="$(plist_value "$APP_PATH/Info.plist""#,
            #"UIBackgroundModes || true)"#,
            #"*"remote-notification"*"#,
            #"profile_aps_environment="$(plist_value "$WORK_DIR/profile.plist""#,
            #"Entitlements:aps-environment || true)"#,
            #"[ "$profile_aps_environment" = "$actual_aps_environment" ]"#,
        ] {
            XCTAssertTrue(
                source.contains(required),
                "install-ios.sh must retain artifact/profile validation: \(required)")
        }
    }

    func testMacDistributionValidatesSignedAPSAgainstEmbeddedProfile() throws {
        let source = try source(at: "Distribution/common.sh")

        for required in [
            #"local profile="$app_path/Contents/embedded.provisionprofile""#,
            #"security cms -D -i "$profile""#,
            #"Print :com.apple.developer.aps-environment"#,
            #"Print :Entitlements:com.apple.developer.aps-environment"#,
            #"[ -z "$claimed_aps" ] || [ "$claimed_aps" != "$profile_aps" ]"#,
        ] {
            XCTAssertTrue(
                source.contains(required),
                "Distribution/common.sh must retain APS/profile validation: \(required)")
        }
    }

    func testAppDelegatesDoNotRequestAlertAuthorizationForSilentSync() throws {
        for relativePath in [
            "snippets/AppDelegate.swift",
            "snippets-ios/AppDelegate.swift",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8)
            XCTAssertFalse(
                source.contains("requestAuthorization("),
                "silent CloudKit sync must not prompt for alert authorization")
        }
    }

    func testIOSStartsProcessOwnedSyncBeforeSceneConstruction() throws {
        let source = try source(at: "snippets-ios/AppDelegate.swift")
        let launchStart = try XCTUnwrap(source.range(
            of: "func application(\n        _ application: UIApplication,\n        didFinishLaunchingWithOptions"))
        let launchEnd = try XCTUnwrap(
            source.range(of: "nonisolated static func allowsExtensionPoint", range: launchStart.upperBound..<source.endIndex))
        let launchBody = source[launchStart.lowerBound..<launchEnd.lowerBound]
        XCTAssertTrue(launchBody.contains("environment.start()"),
                      "silent CloudKit wakes must not depend on creating a scene")

        let sceneStart = try XCTUnwrap(source.range(of: "func scene(\n        _ scene: UIScene,\n        willConnectTo"))
        let sceneEnd = try XCTUnwrap(
            source.range(of: "func scene(_ scene: UIScene, openURLContexts", range: sceneStart.upperBound..<source.endIndex))
        let sceneBody = source[sceneStart.lowerBound..<sceneEnd.lowerBound]
        XCTAssertFalse(sceneBody.contains("environment.start()"),
                       "each scene must reuse the process environment instead of starting sync")
    }

    func testMacForegroundActivationRequestsACoalescedSyncRound() throws {
        let source = try source(at: "snippets/AppDelegate.swift")
        let callbackStart = try XCTUnwrap(
            source.range(of: "func applicationDidBecomeActive(_ notification: Notification)"))
        let callbackEnd = try XCTUnwrap(source.range(
            of: "func applicationWillTerminate(_ notification: Notification)",
            range: callbackStart.upperBound..<source.endIndex))
        let body = source[callbackStart.lowerBound..<callbackEnd.lowerBound]

        XCTAssertTrue(body.contains("syncCoordinator.syncNow(trigger: .becameActive)"),
                      "foreground activation must use the coordinator's coalescing request path")
        XCTAssertFalse(body.contains("syncEngine?.sync()"),
                       "AppDelegate must not bypass coordinator request coalescing")
    }

    func testSettingsExposeReasonSpecificRecoveryActions() throws {
        let ios = try source(at: "snippets-ios/SettingsViewController.swift")
        let mac = try source(at: "snippets/SettingsWindowController.swift")

        XCTAssertTrue(
            ios.contains("environment.syncCoordinator.recoveryAction != nil"),
            "iPhone and iPad must derive recovery from the exact durable halt context")
        XCTAssertFalse(
            ios.contains("Resume After Review"),
            "a generic Resume label hides the action being authorized")
        XCTAssertTrue(
            mac.contains("if let action = coordinator.recoveryAction"),
            "macOS must use the same context-bound recovery-action model")
    }

    func testProductionCheckpointKeyAndFilePolicyAreLocalAndBackgroundReadable() throws {
        let source = try checkpointImplementationSource()

        XCTAssertNotNil(
            source.range(
                of: #"kSecAttrSynchronizable[^\n]{0,160}(?:false|kCFBooleanFalse)"#,
                options: .regularExpression),
            "the checkpoint key must explicitly opt out of iCloud Keychain")
        XCTAssertTrue(
            source.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"),
            "silent background sync needs its local key after the first unlock")
        XCTAssertFalse(
            source.contains("KeychainSecretStore("),
            "the shared sync/vault key store may choose a synchronizable tier")
        XCTAssertTrue(source.contains("completeUntilFirstUserAuthentication"))
        XCTAssertTrue(source.contains("isExcludedFromBackup"))
    }

    func testDriverUsesAwaitedPreFetchBootstrapSeamRatherThanPendingEngineState() throws {
        let adapter = try source(at: "snippets/Sync/CloudKitSyncEngineAdapter.swift")
        let driver = try source(at: "snippets/Sync/CloudKitSyncEngineDriver.swift")

        XCTAssertTrue(
            adapter.contains("func prepareForFirstFetch() async throws"),
            "the neutral driver boundary must expose an awaited bootstrap fence")
        XCTAssertTrue(
            adapter.contains("try await driver.prepareForFirstFetch()"),
            "the adapter must finish bootstrap before its first fetchChanges call")
        XCTAssertTrue(
            adapter.contains("try checkpointStore.markZoneEstablished(for: accountIdentity)"),
            "successful zone creation must consume its authority in the encrypted checkpoint")
        XCTAssertTrue(
            adapter.contains("try driver.completeFirstFetchPreparation()"),
            "the automatically scheduling engine must start only after that durable write")
        let prepare = try XCTUnwrap(
            adapter.range(of: "try await driver.prepareForFirstFetch()")?.lowerBound)
        let mark = try XCTUnwrap(
            adapter.range(
                of: "try checkpointStore.markZoneEstablished(for: accountIdentity)")?.lowerBound)
        let complete = try XCTUnwrap(
            adapter.range(of: "try driver.completeFirstFetchPreparation()")?.lowerBound)
        XCTAssertLessThan(prepare, mark)
        XCTAssertLessThan(mark, complete)
        XCTAssertTrue(
            driver.contains("func completeFirstFetchPreparation() throws"),
            "the production driver needs a distinct post-persistence engine-start seam")
        XCTAssertFalse(
            driver.contains("state.add(pendingDatabaseChanges:"),
            "zone creation after CKSyncEngine construction can race its automatic first fetch")
    }

    func testOpaqueCheckpointBytesHaveNoRawLoggingOrDiagnosticsExportPath() throws {
        let source = try checkpointImplementationSource()
        for forbidden in [
            "String(decoding:",
            "String(data:",
            "localizedDescription",
            "debugDescription",
            "print(",
            "NSLog(",
            "os_log(",
            "Logger(",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "checkpoint code must not turn opaque state/ciphertext into loggable text")
        }

        let diagnosticsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "snippets/Diagnostics/DiagnosticsService.swift"),
            encoding: .utf8)
        XCTAssertFalse(diagnosticsSource.contains("CloudKitSyncCheckpoint"))
        XCTAssertFalse(diagnosticsSource.contains("cksync-checkpoint"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func checkpointImplementationSource() throws -> String {
        let syncDirectory = repositoryRoot.appendingPathComponent("snippets/Sync", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: syncDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let relevantSources = try sourceURLs.compactMap { url -> String? in
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.contains("CloudKitSyncCheckpointStore")
                    || source.contains("CloudKitSyncCheckpointCrypting")
            else { return nil }
            return source
        }
        guard !relevantSources.isEmpty else {
            XCTFail("missing production CKSyncEngine checkpoint implementation")
            throw CapabilityTestFailure.missingCheckpointImplementation
        }
        return relevantSources.joined(separator: "\n")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

private enum CapabilityTestFailure: Error {
    case missingCheckpointImplementation
}
