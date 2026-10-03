//! Portable library-key pairing, recovery and control-plane authority.
//! Secrets have no Debug/Clone/Serde escape. Secret encodings are explicit,
//! zeroizing values for Secret Service, never primary files or diagnostics.
use crate::{
    canonical::{self, Value},
    cloud::ServerURL,
    crypto,
};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::AeadInOut};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ed25519_dalek::{Signer, SigningKey};
use hkdf::Hkdf;
use p256::{PublicKey, SecretKey, elliptic_curve::sec1::ToSec1Point};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const PAIRING_ALGORITHM: &str = "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1";
pub const RECOVERY_ALGORITHM: &str = "snippets-recovery-hkdf-sha256-aes256gcm-v1";
pub const MAX_ENVELOPE_BYTES: usize = 4096;
pub const DEFAULT_PAIRING_SECONDS: u32 = 300;
const ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidFormat,
    Expired,
    Authentication,
    Randomness,
    WrongBinding,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::InvalidFormat
    }
}

/// The unchanged cross-platform sync-v1 root + salt. It is independent of the
/// per-install checkpoint key and of a secure-snippet vault's root key.
pub struct Bundle {
    material: Zeroizing<[u8; 64]>,
}
impl Bundle {
    pub fn generate() -> Result<Self> {
        Ok(Self {
            material: Zeroizing::new(crypto::random().map_err(|_| Failure::Randomness)?),
        })
    }
    pub fn from_material(material: &[u8]) -> Result<Self> {
        Ok(Self {
            material: Zeroizing::new(material.try_into().map_err(|_| Failure::InvalidFormat)?),
        })
    }
    pub fn for_secure_storage(&self) -> &[u8; 64] {
        &self.material
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let value = parse(bytes, 2048)?;
        let v = exact(&value, &["schemaVersion", "scopeID", "key", "salt"])?;
        if v["schemaVersion"].as_int()? != 1 || v["scopeID"].as_text()? != "sync-v1" {
            return Err(Failure::InvalidFormat);
        }
        let key = decode64(v["key"].as_text()?, false, 32)?;
        let salt = decode64(v["salt"].as_text()?, false, 32)?;
        if key.len() != 32 || salt.len() != 32 {
            return Err(Failure::InvalidFormat);
        }
        let mut material = Zeroizing::new([0; 64]);
        material[..32].copy_from_slice(&key);
        material[32..].copy_from_slice(&salt);
        Ok(Self { material })
    }
    pub fn encode_secret(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(
            &object([
                ("schemaVersion", Value::Int(1)),
                ("scopeID", Value::text("sync-v1")),
                ("key", Value::text(STANDARD.encode(&self.material[..32]))),
                ("salt", Value::text(STANDARD.encode(&self.material[32..]))),
            ]),
            2048,
        )
    }
}

pub struct PairingDraft {
    private: SecretKey,
    public: [u8; 65],
    nonce: [u8; 32],
}
impl PairingDraft {
    pub fn generate() -> Result<Self> {
        let private = random_private()?;
        let public = public_bytes(&private);
        let nonce = crypto::random().map_err(|_| Failure::Randomness)?;
        Ok(Self {
            private,
            public,
            nonce,
        })
    }
    pub fn public_key(&self) -> &[u8; 65] {
        &self.public
    }
    pub fn nonce(&self) -> &[u8; 32] {
        &self.nonce
    }
    fn value(&self) -> Value {
        let private = Zeroizing::new(self.private.to_bytes());
        object([
            (
                "recipientPublicKey",
                Value::text(STANDARD.encode(self.public)),
            ),
            ("nonce", Value::text(STANDARD.encode(self.nonce))),
            (
                "privateKey",
                Value::text(STANDARD.encode(private.as_slice())),
            ),
        ])
    }
    fn from_value(value: &Value) -> Result<Self> {
        let v = exact(value, &["recipientPublicKey", "nonce", "privateKey"])?;
        let public = array64::<65>(v["recipientPublicKey"].as_text()?, false)?;
        let nonce = array64::<32>(v["nonce"].as_text()?, false)?;
        let private_bytes = decode64(v["privateKey"].as_text()?, false, 32)?;
        if private_bytes.len() != 32 {
            return Err(Failure::InvalidFormat);
        }
        let private = SecretKey::from_slice(&private_bytes).map_err(|_| Failure::InvalidFormat)?;
        if public_bytes(&private) != public {
            return Err(Failure::WrongBinding);
        }
        Ok(Self {
            private,
            public,
            nonce,
        })
    }
    pub fn encode_secret(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(&self.value(), MAX_ENVELOPE_BYTES)
    }
    pub fn decode_secret(bytes: &[u8]) -> Result<Self> {
        Self::from_value(&parse(bytes, MAX_ENVELOPE_BYTES)?)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Invitation {
    server: ServerURL,
    space: Uuid,
    pairing: Uuid,
    nonce: [u8; 32],
    recipient: [u8; 65],
    expires_at: i64,
}
impl Invitation {
    pub fn new(
        server: ServerURL,
        space: Uuid,
        pairing: Uuid,
        nonce: [u8; 32],
        recipient: [u8; 65],
        expires_at: i64,
        now: i64,
    ) -> Result<Self> {
        if space.is_nil() || pairing.is_nil() {
            return Err(Failure::InvalidFormat);
        }
        parse_public(&recipient)?;
        let result = Self {
            server,
            space,
            pairing,
            nonce,
            recipient,
            expires_at,
        };
        result.validate_time(now)?;
        Ok(result)
    }
    pub(crate) fn validate_time(&self, now: i64) -> Result<()> {
        validate_expiry(self.expires_at, now)
    }
    pub fn server(&self) -> &ServerURL {
        &self.server
    }
    pub fn space(&self) -> Uuid {
        self.space
    }
    pub fn pairing(&self) -> Uuid {
        self.pairing
    }
    pub fn nonce(&self) -> &[u8; 32] {
        &self.nonce
    }
    pub fn public_key(&self) -> &[u8; 65] {
        &self.recipient
    }
    pub fn expires_at(&self) -> i64 {
        self.expires_at
    }
    pub fn confirmation_code(&self) -> String {
        confirmation_code(&self.nonce, &self.recipient)
    }
    pub fn encode_qr(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(
            &object([
                ("schemaVersion", Value::Int(2)),
                ("kind", Value::text("snippets-pairing")),
                ("server", Value::text(self.server.for_secure_storage())),
                ("spaceId", Value::text(self.space.to_string())),
                ("pairingId", Value::text(self.pairing.to_string())),
                ("nonce", Value::text(URL_SAFE_NO_PAD.encode(self.nonce))),
                (
                    "recipientPublicKey",
                    Value::text(URL_SAFE_NO_PAD.encode(self.recipient)),
                ),
                ("expiresAt", Value::Int(self.expires_at)),
            ]),
            MAX_ENVELOPE_BYTES,
        )
    }
    pub fn decode_qr(bytes: &[u8], now: i64) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let v = exact(
            &value,
            &[
                "schemaVersion",
                "kind",
                "server",
                "spaceId",
                "pairingId",
                "nonce",
                "recipientPublicKey",
                "expiresAt",
            ],
        )?;
        if v["schemaVersion"].as_int()? != 2 || v["kind"].as_text()? != "snippets-pairing" {
            return Err(Failure::InvalidFormat);
        }
        Self::new(
            parse_server(v["server"].as_text()?)?,
            parse_uuid(v["spaceId"].as_text()?)?,
            parse_uuid(v["pairingId"].as_text()?)?,
            array64(v["nonce"].as_text()?, true)?,
            array64(v["recipientPublicKey"].as_text()?, true)?,
            v["expiresAt"].as_int()?,
            now,
        )
    }
    /// Retained journals remain inspectable after expiry. This validates the
    /// complete format; every live operation still calls validate_time separately.
    pub(crate) fn decode_retained_qr(bytes: &[u8]) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let expiry = value
            .as_object()?
            .get("expiresAt")
            .ok_or(Failure::InvalidFormat)?
            .as_int()?;
        Self::decode_qr(bytes, expiry.saturating_sub(300).max(0))
    }
    fn aad(&self) -> Vec<u8> {
        [
            "snippets-pairing-v2".into(),
            self.server.for_secure_storage().into(),
            self.space.to_string(),
            self.pairing.to_string(),
            URL_SAFE_NO_PAD.encode(self.nonce),
            URL_SAFE_NO_PAD.encode(self.recipient),
        ]
        .join("\0")
        .into_bytes()
    }
}
pub struct PendingPairing {
    draft: PairingDraft,
    invitation: Invitation,
}
impl PendingPairing {
    pub fn new(draft: PairingDraft, invitation: Invitation) -> Result<Self> {
        if draft.nonce != invitation.nonce || draft.public != invitation.recipient {
            return Err(Failure::WrongBinding);
        }
        Ok(Self { draft, invitation })
    }
    pub fn invitation(&self) -> &Invitation {
        &self.invitation
    }
    pub fn encode_secret(&self) -> Result<Zeroizing<Vec<u8>>> {
        let invitation = self.invitation.encode_qr()?;
        let invitation = std::str::from_utf8(&invitation).map_err(|_| Failure::InvalidFormat)?;
        encode(
            &object([
                ("draft", self.draft.value()),
                ("invitationPayload", Value::text(invitation)),
            ]),
            MAX_ENVELOPE_BYTES,
        )
    }
    pub fn decode_secret(bytes: &[u8], now: i64) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let v = exact(&value, &["draft", "invitationPayload"])?;
        Self::new(
            PairingDraft::from_value(&v["draft"])?,
            Invitation::decode_qr(v["invitationPayload"].as_text()?.as_bytes(), now)?,
        )
    }
    /// A durably received envelope can finish activation after invitation expiry.
    /// This validates the private/public/nonce binding but grants no HTTP replay.
    pub(crate) fn decode_retained_secret(bytes: &[u8]) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let v = exact(&value, &["draft", "invitationPayload"])?;
        Self::new(
            PairingDraft::from_value(&v["draft"])?,
            Invitation::decode_retained_qr(v["invitationPayload"].as_text()?.as_bytes())?,
        )
    }
}

/// Shared invitation/device-request lifetime window: never already expired by
/// more than 30 seconds of skew, and never longer than a ten-minute offer.
fn validate_expiry(expires_at: i64, now: i64) -> Result<()> {
    if now < 0 {
        return Err(Failure::InvalidFormat);
    }
    let latest = now.checked_add(630).ok_or(Failure::InvalidFormat)?;
    if expires_at <= now - 30 || expires_at > latest {
        return Err(Failure::Expired);
    }
    Ok(())
}
/// The unchanged pairing confirmation code. The server derives the same value as
/// a pairing's `authenticationTag` from its recipient key and nonce.
fn confirmation_code(nonce: &[u8; 32], recipient: &[u8; 65]) -> String {
    let mut digest = Sha256::new();
    digest.update(b"snippets-pairing-confirm-v1");
    digest.update(nonce);
    digest.update(recipient);
    digest.finalize()[..8]
        .iter()
        .map(|b| ALPHABET[(b & 31) as usize] as char)
        .collect()
}

/// Public device sign-in request (server ADR 0007). It carries only the new
/// device's pairing recipient key and nonce; never its private key, poll token
/// or any account credential. Encoding follows the pairing invitation exactly.
#[derive(Clone, PartialEq, Eq)]
pub struct DeviceSignIn {
    server: ServerURL,
    request: Uuid,
    nonce: [u8; 32],
    recipient: [u8; 65],
    expires_at: i64,
}
pub const DEVICE_SIGN_IN_KIND: &str = "snippets-device-sign-in";
impl DeviceSignIn {
    pub fn new(
        server: ServerURL,
        request: Uuid,
        nonce: [u8; 32],
        recipient: [u8; 65],
        expires_at: i64,
        now: i64,
    ) -> Result<Self> {
        if request.is_nil() {
            return Err(Failure::InvalidFormat);
        }
        parse_public(&recipient)?;
        validate_expiry(expires_at, now)?;
        Ok(Self {
            server,
            request,
            nonce,
            recipient,
            expires_at,
        })
    }
    /// A request saved by this device stays displayable after expiry so the owner
    /// sees it ended; live operations check the server's own expiry.
    pub(crate) fn retained(
        server: ServerURL,
        request: Uuid,
        draft: &PairingDraft,
        expires_at: i64,
    ) -> Result<Self> {
        Self::new(
            server,
            request,
            draft.nonce,
            draft.public,
            expires_at,
            expires_at.saturating_sub(300).max(0),
        )
    }
    pub fn server(&self) -> &ServerURL {
        &self.server
    }
    pub fn request(&self) -> Uuid {
        self.request
    }
    pub fn nonce(&self) -> &[u8; 32] {
        &self.nonce
    }
    pub fn public_key(&self) -> &[u8; 65] {
        &self.recipient
    }
    pub fn expires_at(&self) -> i64 {
        self.expires_at
    }
    pub fn confirmation_code(&self) -> String {
        confirmation_code(&self.nonce, &self.recipient)
    }
    /// Sorted keys, unescaped slashes, unpadded Base64url, lowercase UUID and the
    /// canonical origin without a trailing slash, bounded like an invitation.
    pub fn encode_qr(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(
            &object([
                ("expiresAt", Value::Int(self.expires_at)),
                ("kind", Value::text(DEVICE_SIGN_IN_KIND)),
                ("nonce", Value::text(URL_SAFE_NO_PAD.encode(self.nonce))),
                (
                    "recipientPublicKey",
                    Value::text(URL_SAFE_NO_PAD.encode(self.recipient)),
                ),
                ("requestId", Value::text(self.request.to_string())),
                ("schemaVersion", Value::Int(1)),
                ("server", Value::text(self.server.for_secure_storage())),
            ]),
            MAX_ENVELOPE_BYTES,
        )
    }
    pub fn decode_qr(bytes: &[u8], now: i64) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let v = exact(
            &value,
            &[
                "expiresAt",
                "kind",
                "nonce",
                "recipientPublicKey",
                "requestId",
                "schemaVersion",
                "server",
            ],
        )?;
        if v["schemaVersion"].as_int()? != 1 || v["kind"].as_text()? != DEVICE_SIGN_IN_KIND {
            return Err(Failure::InvalidFormat);
        }
        Self::new(
            parse_server(v["server"].as_text()?)?,
            parse_uuid(v["requestId"].as_text()?)?,
            array64(v["nonce"].as_text()?, true)?,
            array64(v["recipientPublicKey"].as_text()?, true)?,
            v["expiresAt"].as_int()?,
            now,
        )
    }
}
/// What the existing add-device entry accepts: a pairing invitation for this
/// library, or a new device's sign-in request for this account.
pub enum AddDevice {
    Pairing(Invitation),
    SignIn(DeviceSignIn),
}
impl AddDevice {
    pub fn decode_qr(bytes: &[u8], now: i64) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let kind = value
            .as_object()?
            .get("kind")
            .ok_or(Failure::InvalidFormat)?
            .as_text()?;
        match kind {
            "snippets-pairing" => Ok(Self::Pairing(Invitation::decode_qr(bytes, now)?)),
            DEVICE_SIGN_IN_KIND => Ok(Self::SignIn(DeviceSignIn::decode_qr(bytes, now)?)),
            _ => Err(Failure::InvalidFormat),
        }
    }
}

pub fn seal_pairing(bundle: &Bundle, invitation: &Invitation, now: i64) -> Result<Vec<u8>> {
    seal_pairing_with(
        bundle,
        invitation,
        now,
        &random_private()?,
        crypto::random().map_err(|_| Failure::Randomness)?,
    )
}
fn seal_pairing_with(
    bundle: &Bundle,
    invitation: &Invitation,
    now: i64,
    sender: &SecretKey,
    nonce: [u8; 12],
) -> Result<Vec<u8>> {
    invitation.validate_time(now)?;
    let public = parse_public(&invitation.recipient)?;
    let shared = sender.diffie_hellman(&public);
    let aad = invitation.aad();
    let key = derive(shared.raw_secret_bytes().as_ref(), &invitation.nonce, &aad);
    let plaintext = bundle.encode_secret()?;
    let sealed = encrypt(&plaintext, &key, nonce, &aad)?;
    let encoded = encode(
        &object([
            ("schemaVersion", Value::Int(1)),
            (
                "senderPublicKey",
                Value::text(URL_SAFE_NO_PAD.encode(public_bytes(sender))),
            ),
            ("nonce", Value::text(URL_SAFE_NO_PAD.encode(nonce))),
            ("sealed", Value::text(URL_SAFE_NO_PAD.encode(sealed))),
        ]),
        MAX_ENVELOPE_BYTES,
    )?;
    Ok(encoded.to_vec())
}
pub fn open_pairing(ciphertext: &[u8], pending: &PendingPairing, now: i64) -> Result<Bundle> {
    pending.invitation.validate_time(now)?;
    open_retained_pairing(ciphertext, pending)
}
/// Only the recipient owner uses this after a claim has been durably retained.
/// Installation still requires a fresh scope and immutable authority match.
pub(crate) fn open_retained_pairing(ciphertext: &[u8], pending: &PendingPairing) -> Result<Bundle> {
    let value = parse(ciphertext, MAX_ENVELOPE_BYTES)?;
    let v = exact(
        &value,
        &["schemaVersion", "senderPublicKey", "nonce", "sealed"],
    )?;
    if v["schemaVersion"].as_int()? != 1 {
        return Err(Failure::InvalidFormat);
    }
    let public = parse_public(&array64::<65>(v["senderPublicKey"].as_text()?, true)?)?;
    let nonce = array64::<12>(v["nonce"].as_text()?, true)?;
    let sealed = decode64(v["sealed"].as_text()?, true, MAX_ENVELOPE_BYTES)?;
    let shared = pending.draft.private.diffie_hellman(&public);
    let aad = pending.invitation.aad();
    let key = derive(
        shared.raw_secret_bytes().as_ref(),
        &pending.invitation.nonce,
        &aad,
    );
    let plaintext = decrypt(&sealed, &key, nonce, &aad)?;
    Bundle::decode(&plaintext).map_err(|_| Failure::Authentication)
}

pub struct RecoveryKit {
    server: ServerURL,
    space: Uuid,
    epoch: i64,
    secret: Zeroizing<[u8; 32]>,
}
impl RecoveryKit {
    pub fn generate(server: ServerURL, space: Uuid, epoch: i64) -> Result<Self> {
        Self::from_secret(
            server,
            space,
            epoch,
            Zeroizing::new(crypto::random().map_err(|_| Failure::Randomness)?),
        )
    }
    fn from_secret(
        server: ServerURL,
        space: Uuid,
        epoch: i64,
        secret: Zeroizing<[u8; 32]>,
    ) -> Result<Self> {
        if space.is_nil() || epoch < 1 {
            return Err(Failure::InvalidFormat);
        }
        Ok(Self {
            server,
            space,
            epoch,
            secret,
        })
    }
    pub fn server(&self) -> &ServerURL {
        &self.server
    }
    pub fn space(&self) -> Uuid {
        self.space
    }
    pub fn epoch(&self) -> i64 {
        self.epoch
    }
    pub fn encode_secret_qr(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(
            &object([
                ("schemaVersion", Value::Int(1)),
                ("kind", Value::text("snippets-recovery")),
                ("server", Value::text(self.server.for_secure_storage())),
                ("spaceId", Value::text(self.space.to_string())),
                ("keyEpoch", Value::Int(self.epoch)),
                (
                    "secret",
                    Value::text(URL_SAFE_NO_PAD.encode(self.secret.as_slice())),
                ),
            ]),
            MAX_ENVELOPE_BYTES,
        )
    }
    pub fn decode_secret_qr(bytes: &[u8]) -> Result<Self> {
        let value = parse(bytes, MAX_ENVELOPE_BYTES)?;
        let v = exact(
            &value,
            &[
                "schemaVersion",
                "kind",
                "server",
                "spaceId",
                "keyEpoch",
                "secret",
            ],
        )?;
        if v["schemaVersion"].as_int()? != 1 || v["kind"].as_text()? != "snippets-recovery" {
            return Err(Failure::InvalidFormat);
        }
        let secret = decode64(v["secret"].as_text()?, true, 32)?;
        Self::from_secret(
            parse_server(v["server"].as_text()?)?,
            parse_uuid(v["spaceId"].as_text()?)?,
            v["keyEpoch"].as_int()?,
            Zeroizing::new(
                secret
                    .as_slice()
                    .try_into()
                    .map_err(|_| Failure::InvalidFormat)?,
            ),
        )
    }
    pub fn encode_secret_code(&self) -> Zeroizing<String> {
        let mut output = Zeroizing::new(String::with_capacity(64));
        let mut buffer = 0u32;
        let mut bits = 0;
        let mut count = 0;
        let mut push = |index: usize| {
            if count != 0 && count % 4 == 0 {
                output.push('-');
            }
            output.push(ALPHABET[index] as char);
            count += 1;
        };
        for byte in self.secret.iter() {
            buffer = (buffer << 8) | *byte as u32;
            bits += 8;
            while bits >= 5 {
                bits -= 5;
                push(((buffer >> bits) & 31) as usize);
            }
        }
        if bits > 0 {
            push(((buffer << (5 - bits)) & 31) as usize);
        }
        output
    }
    pub fn decode_secret_code(
        code: &str,
        server: ServerURL,
        space: Uuid,
        epoch: i64,
    ) -> Result<Self> {
        if code.len() > 1024 {
            return Err(Failure::InvalidFormat);
        }
        let mut normalized = Zeroizing::new(String::with_capacity(code.len()));
        for c in code.chars().filter(|c| *c != '-' && !c.is_whitespace()) {
            normalized.push(c.to_ascii_uppercase());
        }
        if normalized.len() != 52 {
            return Err(Failure::InvalidFormat);
        }
        let mut secret = Zeroizing::new([0; 32]);
        let mut buffer = 0u32;
        let mut bits = 0;
        let mut offset = 0;
        for c in normalized.bytes() {
            let index = ALPHABET
                .iter()
                .position(|b| *b == c)
                .ok_or(Failure::InvalidFormat)?;
            buffer = (buffer << 5) | index as u32;
            bits += 5;
            if bits >= 8 {
                bits -= 8;
                if offset >= 32 {
                    return Err(Failure::InvalidFormat);
                }
                secret[offset] = ((buffer >> bits) & 255) as u8;
                offset += 1;
            }
        }
        if offset != 32 || buffer & ((1 << bits) - 1) != 0 {
            return Err(Failure::InvalidFormat);
        }
        Self::from_secret(server, space, epoch, secret)
    }
    fn aad(&self) -> Vec<u8> {
        [
            "snippets-recovery-v1".into(),
            self.server.for_secure_storage().into(),
            self.space.to_string(),
            self.epoch.to_string(),
        ]
        .join("\0")
        .into_bytes()
    }
}
pub struct RecoveryEnvelope {
    pub kit: RecoveryKit,
    pub ciphertext: Vec<u8>,
}
pub fn create_recovery(
    bundle: &Bundle,
    server: ServerURL,
    space: Uuid,
    epoch: i64,
) -> Result<RecoveryEnvelope> {
    let kit = RecoveryKit::generate(server, space, epoch)?;
    let nonce = crypto::random().map_err(|_| Failure::Randomness)?;
    let ciphertext = seal_recovery_with(bundle, &kit, nonce)?;
    Ok(RecoveryEnvelope { kit, ciphertext })
}
fn seal_recovery_with(bundle: &Bundle, kit: &RecoveryKit, nonce: [u8; 12]) -> Result<Vec<u8>> {
    let aad = kit.aad();
    let key = derive(&*kit.secret, b"snippets-recovery-salt-v1", &aad);
    let plaintext = bundle.encode_secret()?;
    let sealed = encrypt(&plaintext, &key, nonce, &aad)?;
    let mut combined = Vec::with_capacity(12 + sealed.len());
    combined.extend_from_slice(&nonce);
    combined.extend_from_slice(&sealed);
    if combined.len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::InvalidFormat);
    }
    Ok(combined)
}
pub fn open_recovery(ciphertext: &[u8], kit: &RecoveryKit) -> Result<Bundle> {
    if !(28..=MAX_ENVELOPE_BYTES).contains(&ciphertext.len()) {
        return Err(Failure::InvalidFormat);
    }
    let aad = kit.aad();
    let key = derive(&*kit.secret, b"snippets-recovery-salt-v1", &aad);
    let nonce = ciphertext[..12]
        .try_into()
        .map_err(|_| Failure::InvalidFormat)?;
    let plaintext = decrypt(&ciphertext[12..], &key, nonce, &aad)?;
    Bundle::decode(&plaintext).map_err(|_| Failure::Authentication)
}
pub fn recipient_key_hash(public: &[u8; 65]) -> Result<[u8; 32]> {
    parse_public(public)?;
    Ok(Sha256::digest(public).into())
}

/// Identity of the existing immutable library authority, never an account identity.
#[derive(Clone, PartialEq, Eq)]
pub struct AuthorityContext {
    server: ServerURL,
    instance: Uuid,
    space: Uuid,
}
impl AuthorityContext {
    pub fn new(server: ServerURL, instance: Uuid, space: Uuid) -> Result<Self> {
        let url =
            url::Url::parse(server.for_secure_storage()).map_err(|_| Failure::InvalidFormat)?;
        if instance.is_nil() || space.is_nil() || url.scheme() != "https" || url.path() != "/" {
            return Err(Failure::InvalidFormat);
        }
        Ok(Self {
            server,
            instance,
            space,
        })
    }
}
pub struct Authority {
    signing: SigningKey,
}
pub struct Proof {
    challenge: Uuid,
    signature: [u8; 64],
}
impl Authority {
    pub fn new(bundle: &Bundle, context: &AuthorityContext) -> Self {
        let info = format!(
            "snippets-library-action-signing-v1\n{}\n{}\n{}",
            context.server.for_secure_storage(),
            context.instance,
            context.space
        );
        let seed = derive(
            &bundle.material[..32],
            &bundle.material[32..],
            info.as_bytes(),
        );
        Self {
            signing: SigningKey::from_bytes(&seed),
        }
    }
    pub fn public_key(&self) -> [u8; 32] {
        self.signing.verifying_key().to_bytes()
    }
    /// Caller validates the exact scope/action/epoch/request hash and expiry, and
    /// obtains fresh local owner authorization before signing a server nonce.
    pub fn sign(&self, challenge: Uuid, nonce: &[u8; 32]) -> Result<Proof> {
        if challenge.is_nil() {
            return Err(Failure::InvalidFormat);
        }
        let mut message = b"snippets-library-action-proof-v1\n".to_vec();
        message.extend_from_slice(nonce);
        Ok(Proof {
            challenge,
            signature: self.signing.sign(&message).to_bytes(),
        })
    }
}
impl Proof {
    pub fn challenge(&self) -> Uuid {
        self.challenge
    }
    pub fn signature(&self) -> &[u8; 64] {
        &self.signature
    }
    pub fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        encode(
            &object([
                ("challengeId", Value::text(self.challenge.to_string())),
                ("signature", Value::text(STANDARD.encode(self.signature))),
            ]),
            MAX_ENVELOPE_BYTES,
        )
    }
}
pub fn recovery_request_hash(
    epoch: i64,
    expected_version: Option<i64>,
    ciphertext: &[u8],
) -> Result<[u8; 32]> {
    if epoch < 1 || expected_version.is_some_and(|v| v < 1) || ciphertext.len() > MAX_ENVELOPE_BYTES
    {
        return Err(Failure::InvalidFormat);
    }
    let text = [
        "snippets-recovery-action-v1".into(),
        epoch.to_string(),
        expected_version.map_or("null".into(), |v| v.to_string()),
        RECOVERY_ALGORITHM.into(),
        STANDARD.encode(ciphertext),
    ]
    .join("\n");
    Ok(Sha256::digest(text.as_bytes()).into())
}
pub fn pairing_request_hash(
    pairing: Uuid,
    public: &[u8; 65],
    ciphertext: &[u8],
) -> Result<[u8; 32]> {
    if pairing.is_nil() || ciphertext.len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::InvalidFormat);
    }
    let text = [
        "snippets-pairing-action-v1".into(),
        pairing.to_string(),
        STANDARD.encode(recipient_key_hash(public)?),
        PAIRING_ALGORITHM.into(),
        STANDARD.encode(ciphertext),
    ]
    .join("\n");
    Ok(Sha256::digest(text.as_bytes()).into())
}

fn random_private() -> Result<SecretKey> {
    for _ in 0..32 {
        let bytes = Zeroizing::new(crypto::random::<32>().map_err(|_| Failure::Randomness)?);
        if let Ok(key) = SecretKey::from_slice(&*bytes) {
            return Ok(key);
        }
    }
    Err(Failure::Randomness)
}
fn public_bytes(key: &SecretKey) -> [u8; 65] {
    key.public_key()
        .to_sec1_point(false)
        .as_bytes()
        .try_into()
        .expect("uncompressed P-256 point")
}
fn parse_public(bytes: &[u8; 65]) -> Result<PublicKey> {
    if bytes[0] != 4 {
        return Err(Failure::InvalidFormat);
    }
    PublicKey::from_sec1_bytes(bytes).map_err(|_| Failure::InvalidFormat)
}
fn derive(input: &[u8], salt: &[u8], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0; 32]);
    Hkdf::<Sha256>::new(Some(salt), input)
        .expand(info, key.as_mut())
        .expect("32-byte HKDF output");
    key
}
fn encrypt(plaintext: &[u8], key: &[u8; 32], nonce: [u8; 12], aad: &[u8]) -> Result<Vec<u8>> {
    let mut buffer = Zeroizing::new(Vec::with_capacity(plaintext.len() + 16));
    buffer.extend_from_slice(plaintext);
    Aes256Gcm::new_from_slice(key)
        .expect("32-byte key")
        .encrypt_in_place(&Nonce::from(nonce), aad, &mut *buffer)
        .map_err(|_| Failure::Authentication)?;
    Ok(buffer.to_vec())
}
fn decrypt(
    sealed: &[u8],
    key: &[u8; 32],
    nonce: [u8; 12],
    aad: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    if !(16..=MAX_ENVELOPE_BYTES).contains(&sealed.len()) {
        return Err(Failure::InvalidFormat);
    }
    let mut buffer = Zeroizing::new(sealed.to_vec());
    Aes256Gcm::new_from_slice(key)
        .expect("32-byte key")
        .decrypt_in_place(&Nonce::from(nonce), aad, &mut *buffer)
        .map_err(|_| Failure::Authentication)?;
    Ok(buffer)
}
fn parse_server(text: &str) -> Result<ServerURL> {
    let server = ServerURL::parse(text).map_err(|_| Failure::InvalidFormat)?;
    // Never silently normalize a QR's AAD to another byte sequence.
    if server.for_secure_storage() != text {
        return Err(Failure::InvalidFormat);
    }
    Ok(server)
}
fn parse_uuid(text: &str) -> Result<Uuid> {
    let id = Uuid::parse_str(text).map_err(|_| Failure::InvalidFormat)?;
    if id.is_nil() || !id.to_string().eq_ignore_ascii_case(text) {
        return Err(Failure::InvalidFormat);
    }
    Ok(id)
}
fn decode64(text: &str, url: bool, limit: usize) -> Result<Zeroizing<Vec<u8>>> {
    if text.is_empty() || text.len() > limit.div_ceil(3) * 4 {
        return Err(Failure::InvalidFormat);
    }
    let engine = if url { &URL_SAFE_NO_PAD } else { &STANDARD };
    let mut bytes = Zeroizing::new(Vec::with_capacity(limit + 3));
    engine
        .decode_vec(text, &mut bytes)
        .map_err(|_| Failure::InvalidFormat)?;
    if bytes.len() > limit || Zeroizing::new(engine.encode(&*bytes)).as_str() != text {
        return Err(Failure::InvalidFormat);
    }
    Ok(bytes)
}
fn array64<const N: usize>(text: &str, url: bool) -> Result<[u8; N]> {
    decode64(text, url, N)?
        .as_slice()
        .try_into()
        .map_err(|_| Failure::InvalidFormat)
}
fn parse(bytes: &[u8], limit: usize) -> Result<Value> {
    if bytes.len() > limit {
        return Err(Failure::InvalidFormat);
    }
    Ok(canonical::parse(bytes)?)
}
fn exact<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a BTreeMap<String, Value>> {
    let v = value.as_object()?;
    if v.len() != keys.len() || !keys.iter().all(|k| v.contains_key(*k)) {
        return Err(Failure::InvalidFormat);
    }
    Ok(v)
}
fn object<const N: usize>(values: [(&str, Value); N]) -> Value {
    Value::Object(values.into_iter().map(|(k, v)| (k.into(), v)).collect())
}
fn encode(value: &Value, limit: usize) -> Result<Zeroizing<Vec<u8>>> {
    let bytes = value.encode()?;
    if bytes.len() > limit {
        return Err(Failure::InvalidFormat);
    }
    Ok(bytes)
}

#[cfg(test)]
#[path = "bootstrap_tests.rs"]
mod tests;
