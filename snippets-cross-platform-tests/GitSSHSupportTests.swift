import CryptoKit
import Foundation
import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

/// Host-key trust and the per-device SSH key used where there is no system ssh (iOS).
final class GitSSHSupportTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "GitSSHSupportTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // Vectors from `ssh-keygen -lf key.pub -E sha256`.
    private static let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINcK+qrvyLvjvWGMLeQtH817NSz5Q/7hEoENFHn3R0CG"
    private static let ed25519Fingerprint = "SHA256:eXl2DPkOlBDmtcG0oIvM51+Fq/TKSOW4R688ql938oM"
    private static let ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMOnD85tByW2CfzNyUYbMclZ93Rnf2S/ZGsFD4efxP2yPE08aNvy7jZJqQ7GJU69/jzDTB/v0hlGdBNa828Yrz4="
    private static let ecdsaFingerprint = "SHA256:ypOXU3HwE/8+W+ye7jYQlGS+LCKaOBtrgwra9E1jVdg"

    func testFingerprintsMatchOpenSSH() {
        XCTAssertEqual(GitSSHHostKeyStore.fingerprint(openSSHKey: Self.ed25519), Self.ed25519Fingerprint)
        XCTAssertEqual(GitSSHHostKeyStore.fingerprint(openSSHKey: Self.ecdsa + " comment"), Self.ecdsaFingerprint)
        XCTAssertNil(GitSSHHostKeyStore.fingerprint(openSSHKey: "ssh-ed25519"))
    }

    func testHostIDsFollowKnownHosts() throws {
        XCTAssertEqual(GitSSHHostKeyStore.hostID(
            try GitSSHLocation(user: "git", host: "GitHub.com", port: nil, path: "a", scpStyle: true)), "github.com")
        XCTAssertEqual(GitSSHHostKeyStore.hostID(
            try GitSSHLocation(user: "git", host: "h", port: 22, path: "/a", scpStyle: false)), "h")
        XCTAssertEqual(GitSSHHostKeyStore.hostID(
            try GitSSHLocation(user: "git", host: "h", port: 2222, path: "/a", scpStyle: false)), "[h]:2222")
    }

    /// Trust on first use needs the user's confirmation of exactly the presented key,
    /// and a different key later is never accepted silently.
    func testHostKeysAreTrustedOnlyAfterConfirmationAndChangesAreRefused() throws {
        let store = GitSSHHostKeyStore(defaults: defaults)
        let location = try GitSSHLocation(user: "git", host: "example.com", port: nil, path: "a", scpStyle: true)
        XCTAssertEqual(store.check(hostID: "example.com", openSSHKey: Self.ed25519 + " comment"), .unknown)
        let presented = try XCTUnwrap(store.presentedKey(for: location))
        XCTAssertEqual(presented.fingerprint, Self.ed25519Fingerprint)
        XCTAssertFalse(presented.replacesTrustedKey)
        XCTAssertFalse(store.trustPresentedKey(for: location, fingerprint: Self.ecdsaFingerprint))
        XCTAssertEqual(store.check(hostID: "example.com", openSSHKey: Self.ed25519), .unknown)
        XCTAssertTrue(store.trustPresentedKey(for: location, fingerprint: Self.ed25519Fingerprint))
        XCTAssertEqual(store.trustedKey(for: location), Self.ed25519)
        XCTAssertEqual(store.check(hostID: "example.com", openSSHKey: Self.ed25519), .trusted)
        XCTAssertNil(store.presentedKey(for: location))

        XCTAssertEqual(store.check(hostID: "example.com", openSSHKey: Self.ecdsa), .changed)
        XCTAssertEqual(store.trustedKey(for: location), Self.ed25519, "a changed key is not stored until confirmed")
        XCTAssertEqual(store.presentedKey(for: location)?.replacesTrustedKey, true)
        // Another store over the same preferences sees the trusted key, not the pending one.
        XCTAssertEqual(GitSSHHostKeyStore(defaults: defaults).check(hostID: "example.com", openSSHKey: Self.ed25519), .trusted)
    }

    func testDeviceKeyIsCreatedOnceAndSurvivesARelaunch() throws {
        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let identity = GitSSHDeviceIdentity(
            keychain: keychain, hostKeys: GitSSHHostKeyStore(defaults: defaults), allowsSecureEnclave: false)
        XCTAssertFalse(identity.hasKey)
        let publicKey = try identity.publicKey()
        XCTAssertTrue(identity.hasKey)
        XCTAssertEqual(try identity.publicKey(), publicKey)
        let fields = publicKey.split(separator: " ")
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0], "ecdsa-sha2-nistp256")
        XCTAssertEqual(String(fields[2]), identity.comment)
        XCTAssertNotNil(GitSSHHostKeyStore.fingerprint(openSSHKey: publicKey))

        let relaunched = GitSSHDeviceIdentity(
            keychain: keychain, hostKeys: GitSSHHostKeyStore(defaults: defaults), allowsSecureEnclave: false)
        XCTAssertEqual(try relaunched.publicKey(), publicKey)
    }

    func testPublicKeyEncodingMatchesOpenSSH() throws {
        // The ECDSA vector's public point, re-encoded, must give the same text.
        let blob = try XCTUnwrap(Data(base64Encoded: String(Self.ecdsa.split(separator: " ")[1])))
        let point = blob.suffix(65)
        let key = try P256.Signing.PublicKey(x963Representation: point)
        XCTAssertEqual(GitSSHDeviceIdentity.openSSHPublicKey(key), Self.ecdsa)
    }

    func testAnUnreadableStoredKeyIsReportedNotReplaced() throws {
        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        try keychain.storeItem(Data("not a key".utf8), account: GitSSHDeviceIdentity.keyAccount)
        let identity = GitSSHDeviceIdentity(
            keychain: keychain, hostKeys: GitSSHHostKeyStore(defaults: defaults), allowsSecureEnclave: false)
        XCTAssertThrowsError(try identity.publicKey())
        XCTAssertEqual(try keychain.loadItem(account: GitSSHDeviceIdentity.keyAccount), Data("not a key".utf8),
                       "a key the repository may already trust is never silently replaced")
    }
}
