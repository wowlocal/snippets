import Foundation
import Testing
@testable import SnippetsCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Server ADR 0007 `snippets-device-sign-in` payload and its device-local state.
struct DeviceSignInCodecTests {
    private let server = URL(string: "https://sync.example")!
    private let requestID = UUID(uuidString: "6A1D2C3B-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let now: Int64 = 1_800_000_000

    private func request(
        draft: LibraryKeyBootstrap.PairingDraft = .init(),
        expiresAt: Int64? = nil,
        at instant: Int64? = nil
    ) throws -> LibraryKeyBootstrap.DeviceSignInRequest {
        try .init(serverURL: server, requestID: requestID, nonce: draft.nonce,
                  recipientPublicKey: draft.recipientPublicKey,
                  expiresAtEpochSeconds: expiresAt ?? now + 600, nowEpochSeconds: instant ?? now)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @Test func payloadRoundTripsWithCanonicalSortedEncoding() throws {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let value = try request(draft: draft)
        let payload = try value.qrPayload()
        let expected = "{\"expiresAt\":\(now + 600),\"kind\":\"snippets-device-sign-in\","
            + "\"nonce\":\"\(base64URL(draft.nonce))\","
            + "\"recipientPublicKey\":\"\(base64URL(draft.recipientPublicKey))\","
            + "\"requestId\":\"6a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d\",\"schemaVersion\":1,"
            + "\"server\":\"https://sync.example\"}"
        #expect(payload == expected)
        #expect(!payload.contains("\\/"))
        #expect(!payload.contains("="))
        let parsed = try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: payload, nowEpochSeconds: now)
        #expect(parsed == value)
        #expect(LibraryKeyBootstrap.DeviceSignInRequest.isDeviceSignInPayload(payload))
        #expect(!"\(parsed)".contains(base64URL(draft.nonce)))
    }

    @Test func confirmationCodeEqualsThePairingTagDerivation() throws {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let value = try request(draft: draft)
        let invitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: server, spaceID: UUID(), pairingID: UUID(), nonce: draft.nonce,
            recipientPublicKey: draft.recipientPublicKey, expiresAtEpochSeconds: now + 300,
            nowEpochSeconds: now)
        // Independent server-equivalent derivation (server/internal/domain pairingAuthenticationTag).
        var material = Data("snippets-pairing-confirm-v1".utf8)
        material.append(draft.nonce)
        material.append(draft.recipientPublicKey)
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let tag = SHA256.hash(data: material).prefix(8).map { String(alphabet[Int($0) & 31]) }.joined()
        #expect(value.confirmationCode == tag)
        #expect(value.confirmationCode == invitation.confirmationCode)
    }

    @Test func parsingRequiresExactKeysAndCanonicalValues() throws {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let payload = try request(draft: draft).qrPayload()
        func mutated(_ change: (inout [String: Any]) -> Void) throws -> String {
            var object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            change(&object)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let rejected: [String] = [
            try mutated { $0["pollToken"] = "sn_d_" + String(repeating: "A", count: 43) },
            try mutated { $0.removeValue(forKey: "requestId") },
            try mutated { $0["kind"] = "snippets-pairing" },
            try mutated { $0["schemaVersion"] = 2 },
            try mutated { $0["requestId"] = "6A1D2C3B-4E5F-4A6B-8C7D-9E0F1A2B3C4D" },
            try mutated { $0["server"] = "https://sync.example/" },
            try mutated { $0["server"] = "http://sync.example" },
            try mutated { $0["server"] = "https://sync.example?x=1" },
            try mutated { $0["nonce"] = draft.nonce.base64EncodedString() },
            try mutated { $0["nonce"] = base64URL(draft.nonce.prefix(31)) },
            try mutated { $0["recipientPublicKey"] = base64URL(Data([4]) + Data(repeating: 1, count: 64)) },
            try mutated { $0["expiresAt"] = 1.5 },
            try mutated { $0["expiresAt"] = "\(now + 600)" },
            "[]", "not json",
        ]
        for value in rejected {
            #expect(throws: (any Error).self) {
                try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: value, nowEpochSeconds: now)
            }
        }
    }

    @Test func oversizedPayloadIsRejectedBeforeParsing() {
        let oversized = "{\"kind\":\"snippets-device-sign-in\",\"pad\":\"" + String(repeating: "a", count: 4_100) + "\"}"
        #expect(Data(oversized.utf8).count > 4_096)
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: oversized, nowEpochSeconds: now)
        }
        #expect(!LibraryKeyBootstrap.DeviceSignInRequest.isDeviceSignInPayload(oversized))
    }

    @Test func expiryWindowIsEnforced() throws {
        #expect(throws: LibraryKeyBootstrap.Failure.expired) { try request(expiresAt: now - 31) }
        #expect(throws: LibraryKeyBootstrap.Failure.expired) { try request(expiresAt: now + 631) }
        let payload = try request(expiresAt: now + 600).qrPayload()
        _ = try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: payload, nowEpochSeconds: now + 620)
        #expect(throws: LibraryKeyBootstrap.Failure.expired) {
            try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: payload, nowEpochSeconds: now + 631)
        }
    }

    @Test func pairingSecondsClampFollowsTheADR() {
        let seconds = { LibraryKeyBootstrap.deviceSignInPairingSeconds(
            requestExpiresAtEpochSeconds: self.now + $0, nowEpochSeconds: self.now) }
        #expect(seconds(600) == 595)
        #expect(seconds(605) == 600)
        #expect(seconds(900) == 600)
        #expect(seconds(65) == 60)
        #expect(seconds(30) == 60)
        #expect(seconds(-100) == 60)
        #expect(seconds(300) == 295)
    }

    @Test func pollTokenFormatIsExact() {
        let valid = "sn_d_" + base64URL(Data(repeating: 0xAB, count: 32))
        #expect(valid.utf8.count == 48)
        #expect(LibraryKeyBootstrap.isDevicePollToken(valid))
        #expect(!LibraryKeyBootstrap.isDevicePollToken(String(valid.dropLast())))
        #expect(!LibraryKeyBootstrap.isDevicePollToken("sn_x_" + valid.dropFirst(5)))
        #expect(!LibraryKeyBootstrap.isDevicePollToken(valid.replacingOccurrences(of: "q", with: "+")))
        #expect(!LibraryKeyBootstrap.isDevicePollToken("sn_d_" + String(repeating: "A", count: 42) + "B"))
    }

    @Test func pendingSignInRoundTripsStrictlyAndOpensTheApprovedPairing() throws {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let current = Int64(Date().timeIntervalSince1970)
        let value = try request(draft: draft, expiresAt: current + 500, at: current)
        let token = "sn_d_" + base64URL(Data(repeating: 7, count: 32))
        let pending = try LibraryKeyBootstrap.PendingDeviceSignIn(draft: draft, request: value, pollToken: token)
        #expect(!"\(pending)".contains(token))
        let restored = try LibraryKeyBootstrap.PendingDeviceSignIn(jsonData: pending.jsonData)
        #expect(restored == pending)
        #expect(try restored.request == value)

        var object = try #require(JSONSerialization.jsonObject(with: pending.jsonData) as? [String: Any])
        object["extra"] = true
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.PendingDeviceSignIn(jsonData: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.PendingDeviceSignIn(draft: .init(), request: value, pollToken: token)
        }
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.PendingDeviceSignIn(draft: draft, request: value, pollToken: "sn_d_short")
        }

        // The approving device seals for the pairing it created for exactly this key and
        // nonce; the new device opens it with its stored recipient material.
        let space = UUID(), pairing = UUID()
        let recipient = try restored.pendingPairing(
            spaceID: space, pairingID: pairing,
            pairingExpiresAtEpochSeconds: Int64(Date().timeIntervalSince1970) + 300)
        let approverView = try recipient.invitation
        #expect(approverView.confirmationCode == value.confirmationCode)
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: Data((0..<64).map(UInt8.init)))
        let ciphertext = try LibraryKeyBootstrap.seal(bundle, for: approverView)
        #expect(try LibraryKeyBootstrap.open(ciphertext, pending: recipient) == bundle)
    }

    @Test func pendingApprovalRecordsThePairingAndRejectsAForeignOne() throws {
        let draft = LibraryKeyBootstrap.PairingDraft()
        let current = Int64(Date().timeIntervalSince1970)
        let value = try request(draft: draft, expiresAt: current + 500, at: current)
        let initial = try LibraryKeyBootstrap.PendingDeviceApproval(request: value, pairing: nil)
        let initialJSON = String(decoding: try initial.jsonData, as: UTF8.self)
        #expect(initialJSON.contains("\"pairingPayload\":null"))
        let restoredInitial = try LibraryKeyBootstrap.PendingDeviceApproval(jsonData: initial.jsonData)
        #expect(try restoredInitial.pairing == nil)
        #expect(try restoredInitial.request == value)

        let invitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: server, spaceID: UUID(), pairingID: UUID(), nonce: draft.nonce,
            recipientPublicKey: draft.recipientPublicKey, expiresAtEpochSeconds: current + 300)
        let recorded = try LibraryKeyBootstrap.PendingDeviceApproval(request: value, pairing: invitation)
        #expect(try LibraryKeyBootstrap.PendingDeviceApproval(jsonData: recorded.jsonData).pairing == invitation)

        let foreign = LibraryKeyBootstrap.PairingDraft()
        let other = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: server, spaceID: UUID(), pairingID: UUID(), nonce: foreign.nonce,
            recipientPublicKey: foreign.recipientPublicKey, expiresAtEpochSeconds: current + 300)
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.PendingDeviceApproval(request: value, pairing: other)
        }
        var object = try #require(JSONSerialization.jsonObject(with: initial.jsonData) as? [String: Any])
        object.removeValue(forKey: "pairingPayload")
        #expect(throws: (any Error).self) {
            try LibraryKeyBootstrap.PendingDeviceApproval(jsonData: JSONSerialization.data(withJSONObject: object))
        }
    }
}
