import Foundation
@testable import SnippetsCore
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class LibraryKeyBootstrapTests: XCTestCase {
    func testLibraryActionKeysAreDeterministicAndBoundToDeploymentAndSpace() throws {
        let material = Data((0..<64).map(UInt8.init))
        let server = URL(string: "https://sync.example")!
        let instance = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let space = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let first = try LibraryActionAuthorization.publicKey(material: material, serverURL: server, serverInstanceID: instance, spaceID: space)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(first.base64EncodedString(), "BpJCgx4cUQSQFyZtp9NGBSH/vu8g+LUff0Gzc60K4kc=")
        XCTAssertEqual(first, try LibraryActionAuthorization.publicKey(material: material, serverURL: server, serverInstanceID: instance, spaceID: space))
        XCTAssertNotEqual(first, try LibraryActionAuthorization.publicKey(material: material, serverURL: URL(string: "https://local.example")!, serverInstanceID: instance, spaceID: space))
        XCTAssertNotEqual(first, try LibraryActionAuthorization.publicKey(material: material, serverURL: server, serverInstanceID: UUID(), spaceID: space))
        XCTAssertNotEqual(first, try LibraryActionAuthorization.publicKey(material: material, serverURL: server, serverInstanceID: instance, spaceID: UUID()))
        XCTAssertThrowsError(try LibraryActionAuthorization.publicKey(material: material, serverURL: URL(string: "http://sync.example")!, serverInstanceID: instance, spaceID: space))
        let nonce = Data(repeating: 7, count: 32)
        let proof = try LibraryActionAuthorization.sign(nonce: nonce, challengeID: UUID(), material: material, serverURL: server, serverInstanceID: instance, spaceID: space)
        XCTAssertEqual(proof.signature.count, 64)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: first)
        let message = Data("snippets-library-action-proof-v1\n".utf8) + nonce
        XCTAssertTrue(publicKey.isValidSignature(proof.signature, for: message))
        XCTAssertTrue(publicKey.isValidSignature(Data(base64Encoded: "SpmC5BUDjmvaeUhXOjcTs6NtUfD+ncwuUbzstz3x7AqqSNwKasvgalPp0F0Ly8JKPW+qqzodsPyV8VuMniznCw==")!, for: message))
        XCTAssertNotEqual(LibraryActionAuthorization.recoveryHash(keyEpoch: 1, expectedVersion: nil, ciphertext: nonce), LibraryActionAuthorization.recoveryHash(keyEpoch: 1, expectedVersion: 1, ciphertext: nonce))
    }

    func testPairingRoundTripBindsInvitationAndNeverPlacesRootKeyInQR() throws {
        let material = Data((0..<64).map(UInt8.init))
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
        let draft = LibraryKeyBootstrap.PairingDraft()
        let now = Int64(Date().timeIntervalSince1970)
        let invitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            pairingID: UUID(),
            nonce: draft.nonce,
            recipientPublicKey: draft.recipientPublicKey,
            expiresAtEpochSeconds: now + 300,
            nowEpochSeconds: now)
        let qr = try invitation.qrPayload()
        XCTAssertFalse(qr.contains(bundle.key))
        XCTAssertFalse(qr.contains(bundle.salt))

        let parsed = try LibraryKeyBootstrap.PairingInvitation(
            qrPayload: qr,
            nowEpochSeconds: now)
        XCTAssertEqual(parsed, invitation)
        XCTAssertEqual(parsed.confirmationCode.count, 8)
        let pending = try LibraryKeyBootstrap.PendingPairing(draft: draft, invitation: parsed)
        let restoredPending = try LibraryKeyBootstrap.PendingPairing(jsonData: pending.jsonData)
        let ciphertext = try LibraryKeyBootstrap.seal(bundle, for: parsed)
        XCTAssertEqual(try LibraryKeyBootstrap.open(ciphertext, pending: restoredPending), bundle)

        var tampered = ciphertext
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try LibraryKeyBootstrap.open(tampered, pending: restoredPending))

        let wrongInvitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: parsed.serverURL,
            spaceID: parsed.spaceID,
            pairingID: UUID(),
            nonce: parsed.nonce,
            recipientPublicKey: parsed.recipientPublicKey,
            expiresAtEpochSeconds: parsed.expiresAtEpochSeconds,
            nowEpochSeconds: now)
        let wrongPending = try LibraryKeyBootstrap.PendingPairing(
            draft: draft,
            invitation: wrongInvitation)
        XCTAssertThrowsError(try LibraryKeyBootstrap.open(ciphertext, pending: wrongPending))
    }

    func testRecoveryRoundTripFromQRAndLongCode() throws {
        let material = Data((0..<64).map { UInt8(255 - $0) })
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
        let server = try XCTUnwrap(URL(string: "https://sync.example"))
        let space = UUID()
        let recovery = try LibraryKeyBootstrap.createRecoveryEnvelope(
            for: bundle,
            serverURL: server,
            spaceID: space,
            keyEpoch: 1)
        let qr = try recovery.kit.qrPayload()
        XCTAssertFalse(qr.contains(bundle.key))
        XCTAssertFalse(qr.contains(bundle.salt))

        let qrKit = try LibraryKeyBootstrap.RecoveryKit(qrPayload: qr)
        XCTAssertEqual(
            try LibraryKeyBootstrap.openRecoveryEnvelope(recovery.ciphertext, kit: qrKit),
            bundle)
        let codeKit = try LibraryKeyBootstrap.RecoveryKit(
            longCode: recovery.kit.longCode,
            serverURL: server,
            spaceID: space,
            keyEpoch: 1)
        XCTAssertEqual(codeKit.secret, recovery.kit.secret)
        XCTAssertEqual(
            try LibraryKeyBootstrap.openRecoveryEnvelope(recovery.ciphertext, kit: codeKit),
            bundle)
    }

    func testRecoveryWireVectorMatchesAndroidImplementation() throws {
        // This fixed fixture is also opened by the Android unit test. It catches
        // drift in HKDF inputs, AES-GCM combined layout, AAD, and key-bundle JSON.
        let material = Data((0..<64).map(UInt8.init))
        let secret = Data((160..<192).map(UInt8.init))
        let ciphertext = try XCTUnwrap(Data(base64Encoded:
            "4OHi4+Tl5ufo6errM76BnjJgguPvUmhNd5AgnCU/ER/39RuP1lz7aQdmGbMn6cg9UVPGUWIVUXzZEEvueXiuszpMILWrVMGyOTHKM1xJMdbfIbuiaYnIU1y9WFVuZXzja72yY7PtDhh1hzCl4wnwNSAViH5YH/x582U8C8eLuw5o9ykjjonPqIrZH8/fOsAgq4NCirT5lxn4PdAsZvNMgCIb9g6ZygGGsKp70/YP"))
        let kit = try LibraryKeyBootstrap.RecoveryKit(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: XCTUnwrap(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")),
            keyEpoch: 7,
            secret: secret)
        XCTAssertEqual(
            try LibraryKeyBootstrap.openRecoveryEnvelope(ciphertext, kit: kit).material,
            material)
    }
}
