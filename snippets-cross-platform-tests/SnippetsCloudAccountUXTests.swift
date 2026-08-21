import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

final class SnippetsCloudAccountUXTests: XCTestCase {
    func testRecoveryVerificationRequiresSavedSuffixAndNormalizesSeparators() {
        let code = "ABCD-EFGH-IJKL-MNPQ-RSTU-VWXY-2345-6789-ABCD-EFGH-IJKL-MNPQ-QRST"

        XCTAssertTrue(SnippetsCloudRecoveryVerification.matches(
            longCode: code,
            enteredSuffix: "MNPQ QRST"))
        XCTAssertFalse(SnippetsCloudRecoveryVerification.matches(
            longCode: code,
            enteredSuffix: "00000000"))
        XCTAssertFalse(SnippetsCloudRecoveryVerification.matches(
            longCode: code,
            enteredSuffix: "QRST"))
    }

    func testPairingStateCarriesExactExpiryForCountdownAndAutomaticPolling() {
        let expiry = Date(timeIntervalSince1970: 1_788_000_000)
        let state = SnippetsCloudAccountBootstrap.State.waitingForApproval(
            qrPayload: "invitation",
            confirmationCode: "482 193",
            expiresAt: expiry)

        guard case .waitingForApproval(_, _, let actualExpiry) = state else {
            return XCTFail("expected waiting state")
        }
        XCTAssertEqual(actualExpiry, expiry)
    }
}
