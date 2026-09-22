import Testing
@testable import SnippetsAX

@Suite("Paste focus handoff")
@MainActor
struct SecurePasteFocusHandoffTests {
    @Test("a ready unauthenticated destination does not sleep")
    func readyDestination() async {
        var attempts = 0
        let report = await SecurePasteFocusHandoff.run(mode: .withoutAuthentication,
            sleep: { _ in Issue.record("Ready destination unnecessarily waited") },
            attempt: { attempts += 1; return .valid })
        #expect(report.validation == .valid)
        #expect(attempts == 1)
    }

    @Test("a ready unauthenticated container does not rewrite focus")
    func readyContainer() async {
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .withoutAuthentication,
            sleep: { _ in Issue.record("Ready container unnecessarily waited") },
            observe: { .valid },
            restoreFocus: { Issue.record("Ready container unnecessarily rewrote focus") })
        #expect(report.validation == .valid)
        #expect(report.attempts == 1)
    }

    @Test("an unauthenticated container revalidates the field after restoring its focus",
          arguments: [SecurePasteTargetResolver.Validation.valid, .focusChanged])
    func restoredContainer(validationAfterRestore: SecurePasteTargetResolver.Validation) async {
        var restored = false
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .withoutAuthentication,
            sleep: { _ in Issue.record("A conclusive field observation does not need a retry") },
            observe: { restored ? validationAfterRestore : .fieldFocusPending },
            restoreFocus: { restored = true })
        #expect(restored)
        #expect(report.validation == validationAfterRestore)
        #expect(report.firstTransient == .fieldFocusPending)
    }

    @Test("an unauthenticated destination waits only while keyboard ownership is pending")
    func delayedDestination() async {
        var elapsed = Duration.zero
        var observations: [Duration] = []
        let report = await SecurePasteFocusHandoff.run(mode: .withoutAuthentication,
            sleep: { elapsed += $0 }, attempt: {
                observations.append(elapsed)
                return elapsed < .milliseconds(50) ? .keyboardOwnerPending : .valid
            })
        #expect(report.validation == .valid)
        #expect(report.firstTransient == .keyboardOwnerPending)
        #expect(observations.first == .zero)
        #expect(elapsed == .milliseconds(50))
    }

    @Test("authentication requires two successful checks separated by a short wait")
    func authenticationSettles() async {
        var elapsed = Duration.zero
        var observations: [Duration] = []
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { elapsed += $0 }, attempt: {
                observations.append(elapsed)
                return .valid
            })
        #expect(report.validation == .valid)
        #expect(observations.count == 2)
        #expect(observations.first == .zero)
        #expect(elapsed > .zero)
        #expect(elapsed <= .milliseconds(50))
    }

    @Test("Keychain keyboard ownership must return even after secure input clears")
    func keychainDialogHandoff() async {
        var samples: [SecurePasteTargetResolver.Validation] = [
            .secureInputPending, .keyboardOwnerPending, .keyboardOwnerPending,
            .valid, .valid,
        ]
        var attempts = 0
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { _ in }, attempt: { attempts += 1; return samples.removeFirst() })
        #expect(report.validation == .valid)
        #expect(report.firstTransient == .secureInputPending)
        #expect(attempts == 5)
    }

    @Test("every transient interruption resets authentication focus confirmations",
          arguments: SecurePasteTargetResolver.Validation.allCases.filter { $0.canRetryHandoff && $0 != .valid })
    func interruptedAuthentication(interruption: SecurePasteTargetResolver.Validation) async {
        var samples: [SecurePasteTargetResolver.Validation] = [.valid, interruption, .valid, .valid]
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { _ in }, attempt: { samples.removeFirst() })
        #expect(report.validation == .valid)
        #expect(report.firstTransient == interruption)
        #expect(report.attempts == 4)
    }

    @Test("a late successful check is confirmed promptly instead of paying the retry backoff")
    func lateAuthenticationRecovery() async {
        var samples = Array(repeating: SecurePasteTargetResolver.Validation.keyboardOwnerPending, count: 6)
            + [.valid, .valid]
        var sleeps: [Duration] = []
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { sleeps.append($0) }, attempt: { samples.removeFirst() })
        #expect(report.validation == .valid)
        #expect(sleeps.last == .milliseconds(25))
    }

    @Test("a password destination still requires stable focus when secure input is allowed",
          arguments: [true, false])
    func passwordDestination(targetIsSecure: Bool) async {
        let waitForSecureInput = SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: targetIsSecure, secureInputWasEnabledAtCapture: !targetIsSecure)
        var elapsed = Duration.zero
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { elapsed += $0 }, attempt: {
                SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
                    waitForAuthenticationSecureInputToClear: waitForSecureInput,
                    secureEventInputEnabled: true) ? .secureInputPending : .valid
            })
        #expect(report.validation == .valid)
        #expect(report.attempts == 2)
        #expect(elapsed > .zero)
    }

    @Test("changed destinations abort before any retry", arguments: SecurePasteFocusHandoff.Mode.allCases)
    func changedDestination(mode: SecurePasteFocusHandoff.Mode) async {
        let report = await SecurePasteFocusHandoff.run(mode: mode,
            sleep: { _ in Issue.record("Retried a changed destination") }, attempt: { .fieldUnavailable })
        #expect(report.validation == .fieldUnavailable)
        #expect(report.attempts == 1)
    }

    @Test("a single successful check at timeout cannot authorize an authenticated paste")
    func finalSampleIsNotEnough() async {
        var elapsed = Duration.zero
        let report = await SecurePasteFocusHandoff.run(mode: .afterAuthentication,
            sleep: { elapsed += $0 }, attempt: {
                elapsed >= .milliseconds(1_500) ? .valid : .keyboardOwnerPending
            })
        #expect(report.validation == .focusUnavailable)
        #expect(elapsed <= .milliseconds(1_640))
    }

    @Test("cancellation during recovery prevents a later successful check",
          arguments: SecurePasteFocusHandoff.Mode.allCases)
    func cancelledRecovery(mode: SecurePasteFocusHandoff.Mode) async {
        var attempts = 0
        let task = Task { @MainActor in
            await SecurePasteFocusHandoff.run(mode: mode,
                sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } }, attempt: {
                    attempts += 1
                    return attempts == 1 ? .keyboardOwnerPending : .valid
                })
        }
        let report = await task.value
        #expect(report.validation == .cancelled)
        #expect(attempts == 1)
    }
}
