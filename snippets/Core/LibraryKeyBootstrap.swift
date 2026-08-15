import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Zero-knowledge transfer and offline recovery for the portable `sync-v1` key.
///
/// Pairing QR payloads contain only a short-lived binding, a nonce and the new
/// device's ephemeral public key. Recovery kits contain a random recovery secret.
/// Neither format contains the library key; the service stores only AEAD envelopes.
nonisolated enum LibraryKeyBootstrap {
    static let pairingAlgorithm = "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1"
    static let recoveryAlgorithm = "snippets-recovery-hkdf-sha256-aes256gcm-v1"
    static let defaultPairingSeconds = 300

    private static let pairingSchema = 2
    private static let recoverySchema = 1
    private static let maximumQRBytes = 4_096
    private static let maximumEnvelopeBytes = 4_096
    private static let p256PublicKeyBytes = 65
    private static let pairingNonceBytes = 32
    private static let recoverySecretBytes = 32
    private static let gcmNonceBytes = 12

    enum Failure: Error, Equatable {
        case invalidFormat
        case expired
        case cryptographicFailure
    }

    struct PortableKeyBundle: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let scopeID: String
        let key: String
        let salt: String

        init(material: Data, scopeID: String = "sync-v1") throws {
            guard material.count == 64, scopeID == "sync-v1" else { throw Failure.invalidFormat }
            schemaVersion = 1
            self.scopeID = scopeID
            key = material.prefix(32).base64EncodedString()
            salt = material.suffix(32).base64EncodedString()
        }

        init(jsonData: Data) throws {
            guard jsonData.count <= 2_048 else { throw Failure.invalidFormat }
            let decoded = try Self.strictDecode(jsonData)
            guard decoded.schemaVersion == 1,
                  decoded.scopeID == "sync-v1",
                  let keyData = Self.canonicalBase64(decoded.key), keyData.count == 32,
                  let saltData = Self.canonicalBase64(decoded.salt), saltData.count == 32 else {
                throw Failure.invalidFormat
            }
            self = decoded
        }

        var material: Data {
            var result = Data(base64Encoded: key)!
            result.append(Data(base64Encoded: salt)!)
            return result
        }

        var jsonData: Data {
            get throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return try encoder.encode(self)
            }
        }

        private static func strictDecode(_ data: Data) throws -> PortableKeyBundle {
            try requireKeys(data, ["schemaVersion", "scopeID", "key", "salt"])
            return try JSONDecoder().decode(PortableKeyBundle.self, from: data)
        }

        private static func canonicalBase64(_ value: String) -> Data? {
            guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
                return nil
            }
            return data
        }
    }

    struct PairingDraft: Codable, Equatable, Sendable {
        let recipientPublicKey: Data
        let nonce: Data
        let privateKey: Data

        init() {
            let key = P256.KeyAgreement.PrivateKey()
            recipientPublicKey = key.publicKey.x963Representation
            nonce = randomBytes(pairingNonceBytes)
            privateKey = key.rawRepresentation
        }

        init(jsonData: Data) throws {
            guard jsonData.count <= maximumEnvelopeBytes else { throw Failure.invalidFormat }
            try requireKeys(jsonData, ["recipientPublicKey", "nonce", "privateKey"])
            let decoded = try JSONDecoder().decode(PairingDraft.self, from: jsonData)
            guard decoded.recipientPublicKey.count == p256PublicKeyBytes,
                  decoded.recipientPublicKey.first == 0x04,
                  decoded.nonce.count == pairingNonceBytes,
                  let privateKey = try? P256.KeyAgreement.PrivateKey(
                    rawRepresentation: decoded.privateKey),
                  privateKey.publicKey.x963Representation == decoded.recipientPublicKey else {
                throw Failure.invalidFormat
            }
            self = decoded
        }

        var jsonData: Data {
            get throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(self)
            }
        }
    }

    struct PairingInvitation: Equatable, Sendable {
        let serverURL: URL
        let spaceID: UUID
        let pairingID: UUID
        let nonce: Data
        let recipientPublicKey: Data
        let expiresAtEpochSeconds: Int64

        var confirmationCode: String {
            var material = Data("snippets-pairing-confirm-v1".utf8)
            material.append(nonce)
            material.append(recipientPublicKey)
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            return SHA256.hash(data: material).prefix(8)
                .map { String(alphabet[Int($0) & 31]) }.joined()
        }

        func qrPayload() throws -> String {
            let payload = PairingQR(
                schemaVersion: pairingSchema,
                kind: "snippets-pairing",
                server: serverURL.absoluteString,
                spaceId: spaceID.uuidString.lowercased(),
                pairingId: pairingID.uuidString.lowercased(),
                nonce: nonce.base64URL,
                recipientPublicKey: recipientPublicKey.base64URL,
                expiresAt: expiresAtEpochSeconds)
            return try encodedJSONString(payload)
        }

        init(
            serverURL: URL,
            spaceID: UUID,
            pairingID: UUID,
            nonce: Data,
            recipientPublicKey: Data,
            expiresAtEpochSeconds: Int64,
            nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)
        ) throws {
            self.serverURL = try canonicalServerURL(serverURL)
            self.spaceID = spaceID
            self.pairingID = pairingID
            guard nonce.count == pairingNonceBytes,
                  recipientPublicKey.count == p256PublicKeyBytes,
                  recipientPublicKey.first == 0x04,
                  (try? P256.KeyAgreement.PublicKey(
                    x963Representation: recipientPublicKey)) != nil else {
                throw Failure.invalidFormat
            }
            guard expiresAtEpochSeconds > nowEpochSeconds - 30,
                  expiresAtEpochSeconds <= nowEpochSeconds + 630 else { throw Failure.expired }
            self.nonce = nonce
            self.recipientPublicKey = recipientPublicKey
            self.expiresAtEpochSeconds = expiresAtEpochSeconds
        }

        init(qrPayload: String, nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970)) throws {
            let data = Data(qrPayload.utf8)
            guard data.count <= maximumQRBytes else { throw Failure.invalidFormat }
            try requireKeys(data, [
                "schemaVersion", "kind", "server", "spaceId", "pairingId",
                "nonce", "recipientPublicKey", "expiresAt",
            ])
            let payload = try JSONDecoder().decode(PairingQR.self, from: data)
            guard payload.schemaVersion == pairingSchema,
                  payload.kind == "snippets-pairing",
                  let server = URL(string: payload.server),
                  let space = UUID(uuidString: payload.spaceId),
                  let pairing = UUID(uuidString: payload.pairingId),
                  let nonce = Data(base64URL: payload.nonce),
                  let publicKey = Data(base64URL: payload.recipientPublicKey),
                  space.uuidString.lowercased() == payload.spaceId.lowercased(),
                  pairing.uuidString.lowercased() == payload.pairingId.lowercased() else {
                throw Failure.invalidFormat
            }
            try self.init(
                serverURL: server,
                spaceID: space,
                pairingID: pairing,
                nonce: nonce,
                recipientPublicKey: publicKey,
                expiresAtEpochSeconds: payload.expiresAt,
                nowEpochSeconds: nowEpochSeconds)
        }
    }

    struct PendingPairing: Codable, Equatable, Sendable {
        let draft: PairingDraft
        let invitationPayload: String

        var invitation: PairingInvitation { get throws { try PairingInvitation(qrPayload: invitationPayload) } }

        init(draft: PairingDraft, invitation: PairingInvitation) throws {
            guard draft.nonce == invitation.nonce,
                  draft.recipientPublicKey == invitation.recipientPublicKey else {
                throw Failure.invalidFormat
            }
            self.draft = draft
            invitationPayload = try invitation.qrPayload()
        }

        init(jsonData: Data) throws {
            guard jsonData.count <= maximumEnvelopeBytes else { throw Failure.invalidFormat }
            try requireKeys(jsonData, ["draft", "invitationPayload"])
            let decoded = try JSONDecoder().decode(PendingPairing.self, from: jsonData)
            let invitation = try PairingInvitation(qrPayload: decoded.invitationPayload)
            guard decoded.draft.nonce == invitation.nonce,
                  decoded.draft.recipientPublicKey == invitation.recipientPublicKey,
                  let privateKey = try? P256.KeyAgreement.PrivateKey(
                    rawRepresentation: decoded.draft.privateKey),
                  privateKey.publicKey.x963Representation == decoded.draft.recipientPublicKey else {
                throw Failure.invalidFormat
            }
            self = decoded
        }

        var jsonData: Data {
            get throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return try encoder.encode(self)
            }
        }
    }

    struct RecoveryKit: Equatable, Sendable {
        let serverURL: URL
        let spaceID: UUID
        let keyEpoch: Int
        let secret: Data

        var longCode: String { base32Encode(secret).chunked(every: 4).joined(separator: "-") }

        init(serverURL: URL, spaceID: UUID, keyEpoch: Int, secret: Data = randomBytes(recoverySecretBytes)) throws {
            self.serverURL = try canonicalServerURL(serverURL)
            self.spaceID = spaceID
            guard keyEpoch > 0, secret.count == recoverySecretBytes else { throw Failure.invalidFormat }
            self.keyEpoch = keyEpoch
            self.secret = secret
        }

        init(qrPayload: String) throws {
            let data = Data(qrPayload.utf8)
            guard data.count <= maximumQRBytes else { throw Failure.invalidFormat }
            try requireKeys(data, ["schemaVersion", "kind", "server", "spaceId", "keyEpoch", "secret"])
            let payload = try JSONDecoder().decode(RecoveryQR.self, from: data)
            guard payload.schemaVersion == recoverySchema,
                  payload.kind == "snippets-recovery",
                  let server = URL(string: payload.server),
                  let space = UUID(uuidString: payload.spaceId),
                  let secret = Data(base64URL: payload.secret),
                  space.uuidString.lowercased() == payload.spaceId.lowercased() else {
                throw Failure.invalidFormat
            }
            try self.init(serverURL: server, spaceID: space, keyEpoch: payload.keyEpoch, secret: secret)
        }

        init(longCode: String, serverURL: URL, spaceID: UUID, keyEpoch: Int) throws {
            guard let secret = base32Decode(longCode), secret.count == recoverySecretBytes else {
                throw Failure.invalidFormat
            }
            try self.init(serverURL: serverURL, spaceID: spaceID, keyEpoch: keyEpoch, secret: secret)
        }

        func qrPayload() throws -> String {
            try encodedJSONString(RecoveryQR(
                schemaVersion: recoverySchema,
                kind: "snippets-recovery",
                server: serverURL.absoluteString,
                spaceId: spaceID.uuidString.lowercased(),
                keyEpoch: keyEpoch,
                secret: secret.base64URL))
        }
    }

    struct RecoveryEnvelope: Equatable, Sendable {
        let kit: RecoveryKit
        let ciphertext: Data
    }

    static func seal(_ bundle: PortableKeyBundle, for invitation: PairingInvitation) throws -> Data {
        let recipient: P256.KeyAgreement.PublicKey
        do { recipient = try .init(x963Representation: invitation.recipientPublicKey) }
        catch { throw Failure.invalidFormat }
        let sender = P256.KeyAgreement.PrivateKey()
        let shared: SharedSecret
        do { shared = try sender.sharedSecretFromKeyAgreement(with: recipient) }
        catch { throw Failure.cryptographicFailure }
        let aad = pairingAAD(invitation)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: invitation.nonce,
            sharedInfo: aad,
            outputByteCount: 32)
        let nonce = AES.GCM.Nonce()
        let plaintext = try bundle.jsonData
        let sealed: AES.GCM.SealedBox
        do { sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad) }
        catch { throw Failure.cryptographicFailure }
        var encrypted = sealed.ciphertext
        encrypted.append(sealed.tag)
        let envelope = PairingEnvelope(
            schemaVersion: 1,
            senderPublicKey: sender.publicKey.x963Representation.base64URL,
            nonce: Data(nonce).base64URL,
            sealed: encrypted.base64URL)
        let result = try encodedJSONData(envelope)
        guard result.count <= maximumEnvelopeBytes else { throw Failure.invalidFormat }
        return result
    }

    static func open(_ ciphertext: Data, pending: PendingPairing) throws -> PortableKeyBundle {
        guard ciphertext.count <= maximumEnvelopeBytes else { throw Failure.invalidFormat }
        try requireKeys(ciphertext, ["schemaVersion", "senderPublicKey", "nonce", "sealed"])
        let envelope = try JSONDecoder().decode(PairingEnvelope.self, from: ciphertext)
        guard envelope.schemaVersion == 1,
              let senderBytes = Data(base64URL: envelope.senderPublicKey),
              senderBytes.count == p256PublicKeyBytes,
              let nonceData = Data(base64URL: envelope.nonce), nonceData.count == gcmNonceBytes,
              let sealedData = Data(base64URL: envelope.sealed), sealedData.count >= 16,
              let sender = try? P256.KeyAgreement.PublicKey(x963Representation: senderBytes),
              let recipient = try? P256.KeyAgreement.PrivateKey(rawRepresentation: pending.draft.privateKey),
              recipient.publicKey.x963Representation == pending.draft.recipientPublicKey else {
            throw Failure.invalidFormat
        }
        let invitation = try pending.invitation
        let shared = try recipient.sharedSecretFromKeyAgreement(with: sender)
        let aad = pairingAAD(invitation)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: invitation.nonce,
            sharedInfo: aad,
            outputByteCount: 32)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let tagStart = sealedData.index(sealedData.endIndex, offsetBy: -16)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedData[..<tagStart],
            tag: sealedData[tagStart...])
        do {
            return try PortableKeyBundle(jsonData: AES.GCM.open(box, using: key, authenticating: aad))
        } catch { throw Failure.cryptographicFailure }
    }

    static func createRecoveryEnvelope(
        for bundle: PortableKeyBundle,
        serverURL: URL,
        spaceID: UUID,
        keyEpoch: Int
    ) throws -> RecoveryEnvelope {
        let kit = try RecoveryKit(serverURL: serverURL, spaceID: spaceID, keyEpoch: keyEpoch)
        let aad = recoveryAAD(kit)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: kit.secret),
            salt: Data("snippets-recovery-salt-v1".utf8),
            info: aad,
            outputByteCount: 32)
        let sealed = try AES.GCM.seal(try bundle.jsonData, using: key, authenticating: aad)
        guard let combined = sealed.combined, combined.count <= maximumEnvelopeBytes else {
            throw Failure.cryptographicFailure
        }
        return RecoveryEnvelope(kit: kit, ciphertext: combined)
    }

    static func openRecoveryEnvelope(_ ciphertext: Data, kit: RecoveryKit) throws -> PortableKeyBundle {
        guard ciphertext.count >= gcmNonceBytes + 16,
              ciphertext.count <= maximumEnvelopeBytes else { throw Failure.invalidFormat }
        let aad = recoveryAAD(kit)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: kit.secret),
            salt: Data("snippets-recovery-salt-v1".utf8),
            info: aad,
            outputByteCount: 32)
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try PortableKeyBundle(jsonData: AES.GCM.open(box, using: key, authenticating: aad))
        } catch { throw Failure.cryptographicFailure }
    }

    static func recipientKeyHash(_ publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey)) }

    private struct PairingQR: Codable {
        let schemaVersion: Int
        let kind: String
        let server: String
        let spaceId: String
        let pairingId: String
        let nonce: String
        let recipientPublicKey: String
        let expiresAt: Int64
    }

    private struct RecoveryQR: Codable {
        let schemaVersion: Int
        let kind: String
        let server: String
        let spaceId: String
        let keyEpoch: Int
        let secret: String
    }

    private struct PairingEnvelope: Codable {
        let schemaVersion: Int
        let senderPublicKey: String
        let nonce: String
        let sealed: String
    }

    private static func pairingAAD(_ invitation: PairingInvitation) -> Data {
        Data([
            "snippets-pairing-v2",
            invitation.serverURL.absoluteString,
            invitation.spaceID.uuidString.lowercased(),
            invitation.pairingID.uuidString.lowercased(),
            invitation.nonce.base64URL,
            invitation.recipientPublicKey.base64URL,
        ].joined(separator: "\0").utf8)
    }

    private static func recoveryAAD(_ kit: RecoveryKit) -> Data {
        Data([
            "snippets-recovery-v1",
            kit.serverURL.absoluteString,
            kit.spaceID.uuidString.lowercased(),
            String(kit.keyEpoch),
        ].joined(separator: "\0").utf8)
    }

    private static func canonicalServerURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.absoluteString.hasSuffix("/") else { throw Failure.invalidFormat }
        return url
    }

    private static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encodedJSONData(value)
        guard data.count <= maximumQRBytes, let result = String(data: data, encoding: .utf8) else {
            throw Failure.invalidFormat
        }
        return result
    }

    private static func encodedJSONData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func requireKeys(_ data: Data, _ expected: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expected else { throw Failure.invalidFormat }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes)
    }

    private static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var buffer: UInt32 = 0
        var bits = 0
        var result = ""
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 { result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return result
    }

    private static func base32Decode(_ value: String) -> Data? {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let normalized = value.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard normalized.count == 52 else { return nil }
        var buffer: UInt32 = 0
        var bits = 0
        var result = Data()
        for character in normalized {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        guard result.count == recoverySecretBytes,
              base32Encode(result) == normalized else { return nil }
        return result
    }
}

private nonisolated extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                  (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                      || (0x30...0x39).contains($0) || $0 == 0x2d || $0 == 0x5f
              }) else { return nil }
        var padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded.append(String(repeating: "=", count: (4 - padded.count % 4) % 4))
        guard let decoded = Data(base64Encoded: padded), decoded.base64URL == value else { return nil }
        self = decoded
    }
}

private nonisolated extension String {
    func chunked(every count: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: count, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
