import CryptoKit
import Foundation
import Testing
@testable import SnippetsCore

@Suite("Terminal reveal authorization")
struct TerminalRevealAuthorizationTests {
    private let keyring = SnippetCrypto.Keyring(
        libraryKey: SymmetricKey(data: Data(repeating: 7, count: 32)),
        salt: Data(repeating: 9, count: 16))
    private let binding = TerminalRevealAuthorization.Binding(
        vaultKID: "kid-fixture", userID: 501, deviceID: "DEVICE-FIXTURE")

    @Test func issuedRecordVerifiesOnlyUnderItsKeyAndBinding() {
        let record = TerminalRevealAuthorization.issue(keyring: keyring, binding: binding)
        #expect(record.isValid(keyring: keyring, binding: binding))

        var other = binding
        other.vaultKID = "kid-other"
        #expect(!record.isValid(keyring: keyring, binding: other))
        other = binding
        other.userID = 502
        #expect(!record.isValid(keyring: keyring, binding: other))
        other = binding
        other.deviceID = "DEVICE-OTHER"
        #expect(!record.isValid(keyring: keyring, binding: other))

        let otherKey = SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 8, count: 32)), salt: keyring.salt)
        #expect(!record.isValid(keyring: otherKey, binding: binding))
        let otherSalt = SnippetCrypto.Keyring(
            libraryKey: keyring.libraryKey, salt: Data(repeating: 1, count: 16))
        #expect(!record.isValid(keyring: otherSalt, binding: binding))
    }

    @Test func fieldsAreLengthPrefixedSoBoundariesCannotShift() {
        let record = TerminalRevealAuthorization.issue(
            keyring: keyring,
            binding: .init(vaultKID: "ab", userID: 501, deviceID: "c"))
        #expect(!record.isValid(
            keyring: keyring, binding: .init(vaultKID: "a", userID: 501, deviceID: "bc")))
    }

    @Test func tamperedOrMalformedRecordsAreRejected() throws {
        let record = TerminalRevealAuthorization.issue(keyring: keyring, binding: binding)

        var tampered = record
        tampered.tag[0] ^= 1
        #expect(!tampered.isValid(keyring: keyring, binding: binding))

        tampered = record
        tampered.nonce[0] ^= 1
        #expect(!tampered.isValid(keyring: keyring, binding: binding))

        tampered = record
        tampered.v = 2
        #expect(!tampered.isValid(keyring: keyring, binding: binding))

        tampered = record
        tampered.tag = Data()
        #expect(!tampered.isValid(keyring: keyring, binding: binding))

        // An empty binding never verifies, even for a record "issued" for it.
        let empty = TerminalRevealAuthorization.Binding(vaultKID: "", userID: 501, deviceID: "")
        let forEmpty = TerminalRevealAuthorization.issue(keyring: keyring, binding: empty)
        #expect(!forEmpty.isValid(keyring: keyring, binding: empty))

        #expect(TerminalRevealAuthorization.decode(Data("not json".utf8)) == nil)
        let decoded = try #require(TerminalRevealAuthorization.decode(try record.encoded()))
        #expect(decoded == record)
        #expect(decoded.isValid(keyring: keyring, binding: binding))
    }

    @Test func everyEnablementIsFresh() {
        let first = TerminalRevealAuthorization.issue(keyring: keyring, binding: binding)
        let second = TerminalRevealAuthorization.issue(keyring: keyring, binding: binding)
        #expect(first.nonce != second.nonce)
        #expect(first.tag != second.tag)
        #expect(first.nonce.count == TerminalRevealAuthorization.nonceByteCount)
    }

    @Test func encodedRecordCarriesNoBindingValues() throws {
        let record = TerminalRevealAuthorization.issue(keyring: keyring, binding: binding)
        let object = try #require(
            JSONSerialization.jsonObject(with: try record.encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["v", "nonce", "tag"])
        let text = try #require(String(data: try record.encoded(), encoding: .utf8))
        #expect(!text.contains("DEVICE-FIXTURE"))
        #expect(!text.contains("kid-fixture"))
    }
}

@Suite("Terminal reveal protocol")
struct TerminalRevealProtocolTests {
    @Test func passwordRequestRoundTripsAndIsAbsentFromOtherRequests() throws {
        let password = Data("fictional-password".utf8)
        let request = SnippetsIPC.Request(
            command: SnippetsIPC.Command.revealWithPassword, keyword: "demo", password: password)
        let decoded = try JSONDecoder().decode(
            SnippetsIPC.Request.self, from: JSONEncoder().encode(request))
        #expect(decoded.command == "reveal-password")
        #expect(decoded.password == password)
        #expect(decoded.invocation == nil)

        let plain = SnippetsIPC.Request(command: SnippetsIPC.Command.reveal, keyword: "demo")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(object["password"] == nil)
    }

    @Test func statusCarriesTheSwitchAndOlderAppsDecodeAsUnknown() throws {
        let status = SnippetsIPC.Response(status: .ok, secureCount: 2, unlocked: false, terminalReveal: true)
        let decoded = try JSONDecoder().decode(
            SnippetsIPC.Response.self, from: JSONEncoder().encode(status))
        #expect(decoded.terminalReveal == true)

        // What an app predating the feature sends: the CLI must see "unknown", not "off".
        let legacy = Data(#"{"v":1,"status":"ok","secureCount":2,"unlocked":false}"#.utf8)
        #expect(try JSONDecoder().decode(SnippetsIPC.Response.self, from: legacy).terminalReveal == nil)
    }

    @Test func disabledStatusHasItsOwnExitCode() throws {
        let response = SnippetsIPC.Response.failure(.disabled, "off")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["status"] as? String == "disabled")
        #expect(SnippetsIPC.ExitCode.terminalRevealDisabled.rawValue == 8)
    }
}
