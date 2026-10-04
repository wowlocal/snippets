//! Bounded control-plane reads and atomic first-key installation. The transport
//! sees only public authority bytes and opaque ciphertext, never library material.
use super::*;
use crate::bootstrap::{self, RECOVERY_ALGORITHM};
use base64::{Engine, engine::general_purpose::STANDARD};

pub struct AuthorityState {
    epoch: u64,
    public: Option<[u8; 32]>,
}
impl AuthorityState {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn public_key(&self) -> Option<&[u8; 32]> {
        self.public.as_ref()
    }
}
pub struct RemoteRecovery {
    version: u64,
    epoch: u64,
    ciphertext: Vec<u8>,
}
impl RemoteRecovery {
    pub fn version(&self) -> u64 {
        self.version
    }
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn ciphertext(&self) -> &[u8] {
        &self.ciphertext
    }
}
pub struct RecoveryState {
    epoch: u64,
    recovery: Option<RemoteRecovery>,
}
impl RecoveryState {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn recovery(&self) -> Option<&RemoteRecovery> {
        self.recovery.as_ref()
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AuthorityDTO {
    scope: Scope,
    key_epoch: u64,
    #[serde(deserialize_with = "required_optional")]
    public_key: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RecoveryDTO {
    scope: Scope,
    key_epoch: u64,
    #[serde(deserialize_with = "required_optional")]
    recovery: Option<EnvelopeDTO>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EnvelopeDTO {
    purpose: String,
    version: u64,
    key_epoch: u64,
    algorithm: String,
    ciphertext: String,
    created_at: String,
}
fn required_optional<'de, D: serde::Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error> {
    Option::<T>::deserialize(deserializer)
}

impl BoundTransport {
    pub(crate) fn key_binding(&self) -> Result<crate::key_store::KeyBinding> {
        crate::key_store::KeyBinding::new(
            self.client.server.clone(),
            self.client.instance,
            self.scope.space_id,
            self.scope.identities(&self.client.server),
            self.key_epoch,
        )
        .map_err(|_| Failure::InvalidResponse)
    }
    pub(crate) fn key_role(&self) -> Role {
        self.role
    }
    pub fn authority_context(&self) -> Result<bootstrap::AuthorityContext> {
        bootstrap::AuthorityContext::new(
            self.client.server.clone(),
            self.client.instance,
            self.scope.space_id,
        )
        .map_err(|_| Failure::InvalidResponse)
    }
    fn admit_key_response(&mut self, scope: Scope, epoch: u64) -> Result<()> {
        self.adopt_feed(scope)?;
        if epoch == 0 || epoch > i64::MAX as u64 {
            return Err(Failure::InvalidResponse);
        }
        if epoch != self.key_epoch {
            return self.remember(Err(Failure::DatasetReview));
        }
        Ok(())
    }
    pub fn key_authority(&mut self) -> Result<AuthorityState> {
        self.preflight()?;
        let result: Result<AuthorityDTO> = self.client.json(
            Method::GET,
            &format!("/v2/spaces/{}/key-authority", self.scope.space_id),
            Some(&self.token),
            None,
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.admit_key_response(response.scope, response.key_epoch)?;
        let public = response
            .public_key
            .map(|text| decode_public(&text))
            .transpose()?;
        Ok(AuthorityState {
            epoch: response.key_epoch,
            public,
        })
    }
    pub fn recovery_state(&mut self) -> Result<RecoveryState> {
        self.preflight()?;
        let result: Result<RecoveryDTO> = self.client.json(
            Method::GET,
            &format!("/v2/spaces/{}/recovery-envelope", self.scope.space_id),
            Some(&self.token),
            None,
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.admit_key_response(response.scope, response.key_epoch)?;
        let recovery = response
            .recovery
            .map(|value| decode_envelope(value, self.key_epoch))
            .transpose()?;
        Ok(RecoveryState {
            epoch: response.key_epoch,
            recovery,
        })
    }
    /// The caller journals its candidate bundle, recovery kit and exact envelope
    /// before this POST. The server's atomic empty-library guard resolves races;
    /// success is admitted only when the complete receipt matches those bytes.
    /// A lost response requires authority/envelope reconciliation by that owner,
    /// not a new candidate key or a new recovery nonce.
    pub fn bootstrap_library_key(
        &mut self,
        public: &[u8; 32],
        ciphertext: &[u8],
    ) -> Result<RemoteRecovery> {
        validate_public(public)?;
        if !(28..=bootstrap::MAX_ENVELOPE_BYTES).contains(&ciphertext.len()) {
            return Err(Failure::InvalidResponse);
        }
        self.preflight()?;
        if self.role != Role::Owner {
            return Err(Failure::ReadOnly);
        }
        let body = encode(&serde_json::json!({
            "expectedScope":self.scope,"publicKey":STANDARD.encode(public),
            "recovery":{"expectedVersion":null,"keyEpoch":self.key_epoch,
                "algorithm":RECOVERY_ALGORITHM,"ciphertext":STANDARD.encode(ciphertext)}
        }))?;
        let result: Result<RecoveryDTO> = self.client.json(
            Method::POST,
            &format!("/v2/spaces/{}/key-bootstrap", self.scope.space_id),
            Some(&self.token),
            Some(&body),
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.admit_key_response(response.scope, response.key_epoch)?;
        let envelope = decode_envelope(
            response.recovery.ok_or(Failure::InvalidResponse)?,
            self.key_epoch,
        )?;
        if envelope.version != 1 || envelope.ciphertext != ciphertext {
            return Err(Failure::InvalidResponse);
        }
        Ok(envelope)
    }
}
fn decode_envelope(value: EnvelopeDTO, epoch: u64) -> Result<RemoteRecovery> {
    if value.purpose != "recovery"
        || parse_date(&value.created_at).is_err()
        || value.version == 0
        || value.version > i64::MAX as u64
        || value.key_epoch != epoch
        || value.algorithm != RECOVERY_ALGORITHM
    {
        return Err(Failure::InvalidResponse);
    }
    let ciphertext = decode_bytes(&value.ciphertext, bootstrap::MAX_ENVELOPE_BYTES)?;
    if ciphertext.len() < 28 {
        return Err(Failure::InvalidResponse);
    }
    Ok(RemoteRecovery {
        version: value.version,
        epoch,
        ciphertext,
    })
}
fn validate_public(bytes: &[u8; 32]) -> Result<()> {
    let key =
        ed25519_dalek::VerifyingKey::from_bytes(bytes).map_err(|_| Failure::InvalidResponse)?;
    if key.is_weak() {
        return Err(Failure::InvalidResponse);
    }
    Ok(())
}
fn decode_public(text: &str) -> Result<[u8; 32]> {
    let bytes = decode_bytes(text, 32)?;
    let result = bytes
        .as_slice()
        .try_into()
        .map_err(|_| Failure::InvalidResponse)?;
    validate_public(&result)?;
    Ok(result)
}
fn decode_bytes(text: &str, limit: usize) -> Result<Vec<u8>> {
    if text.len() > limit.div_ceil(3) * 4 {
        return Err(Failure::InvalidResponse);
    }
    let bytes = STANDARD
        .decode(text)
        .map_err(|_| Failure::InvalidResponse)?;
    if bytes.len() > limit || STANDARD.encode(&bytes) != text {
        return Err(Failure::InvalidResponse);
    }
    Ok(bytes)
}

fn parse_date(text: &str) -> Result<chrono::DateTime<chrono::Utc>> {
    if !bounded(text, 20, 64) {
        return Err(Failure::InvalidResponse);
    }
    let value = chrono::DateTime::parse_from_rfc3339(text)
        .map_err(|_| Failure::InvalidResponse)?
        .with_timezone(&chrono::Utc);
    if value.timestamp() < 0 || value.timestamp_subsec_nanos() >= 1_000_000_000 {
        return Err(Failure::InvalidResponse);
    }
    Ok(value)
}

#[path = "cloud_actions.rs"]
mod actions;
pub use actions::{ActionChallenge, Mutation, Pairing, PairingState, SignedAction};
