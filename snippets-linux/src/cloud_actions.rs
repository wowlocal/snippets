//! Bound pairing and signed key mutations. A retry retains its original scope,
//! nonce, signature, CAS and ciphertext; it never silently creates a new proof.
use super::*;
use crate::bootstrap::{Invitation, PAIRING_ALGORITHM, PairingDraft, Proof};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    ReplaceRecovery,
    ApprovePairing,
}
enum Payload {
    Recovery {
        version: Option<u64>,
        ciphertext: Vec<u8>,
    },
    Approval {
        invitation: Invitation,
        ciphertext: Vec<u8>,
    },
}
pub struct Mutation {
    epoch: u64,
    payload: Payload,
}
impl Mutation {
    fn same(&self, other: &Self) -> bool {
        self.epoch == other.epoch
            && match (&self.payload, &other.payload) {
                (
                    Payload::Recovery {
                        version: a,
                        ciphertext: b,
                    },
                    Payload::Recovery {
                        version: c,
                        ciphertext: d,
                    },
                ) => a == c && b == d,
                (
                    Payload::Approval {
                        invitation: a,
                        ciphertext: b,
                    },
                    Payload::Approval {
                        invitation: c,
                        ciphertext: d,
                    },
                ) => a == c && b == d,
                _ => false,
            }
    }
    pub fn recovery(epoch: u64, expected_version: Option<u64>, ciphertext: &[u8]) -> Result<Self> {
        validate_cipher(epoch, ciphertext)?;
        if expected_version.is_some_and(|v| v == 0 || v >= i64::MAX as u64) {
            return Err(Failure::InvalidResponse);
        }
        Self::new(
            epoch,
            Payload::Recovery {
                version: expected_version,
                ciphertext: ciphertext.into(),
            },
        )
    }
    pub fn approval(epoch: u64, invitation: Invitation, ciphertext: &[u8]) -> Result<Self> {
        validate_cipher(epoch, ciphertext)?;
        Self::new(
            epoch,
            Payload::Approval {
                invitation,
                ciphertext: ciphertext.into(),
            },
        )
    }
    fn new(epoch: u64, payload: Payload) -> Result<Self> {
        let value = Self { epoch, payload };
        validate_cipher(epoch, value.ciphertext())?;
        Ok(value)
    }
    fn action(&self) -> Action {
        match self.payload {
            Payload::Recovery { .. } => Action::ReplaceRecovery,
            Payload::Approval { .. } => Action::ApprovePairing,
        }
    }
    fn ciphertext(&self) -> &[u8] {
        match &self.payload {
            Payload::Recovery { ciphertext, .. } | Payload::Approval { ciphertext, .. } => {
                ciphertext
            }
        }
    }
    fn hash(&self) -> Result<[u8; 32]> {
        match &self.payload {
            Payload::Recovery {
                version,
                ciphertext,
            } => bootstrap::recovery_request_hash(
                self.epoch as i64,
                version.map(|v| v as i64),
                ciphertext,
            ),
            Payload::Approval {
                invitation,
                ciphertext,
            } => bootstrap::pairing_request_hash(
                invitation.pairing(),
                invitation.public_key(),
                ciphertext,
            ),
        }
        .map_err(|_| Failure::InvalidResponse)
    }
    fn validate_binding(&self, server: &ServerURL, space: Uuid) -> Result<()> {
        if let Payload::Approval { invitation, .. } = &self.payload {
            validate_invitation(invitation, server, space)?;
        }
        Ok(())
    }
    fn body(&self, proof: &ProofDTO) -> Result<Zeroizing<Vec<u8>>> {
        match &self.payload {
            Payload::Recovery {
                version,
                ciphertext,
            } => encode(&serde_json::json!({
                "expectedVersion":version,"keyEpoch":self.epoch,"algorithm":RECOVERY_ALGORITHM,
                "ciphertext":STANDARD.encode(ciphertext),"proof":proof
            })),
            Payload::Approval {
                invitation,
                ciphertext,
            } => encode(&serde_json::json!({
                "recipientKeyHash":STANDARD.encode(bootstrap::recipient_key_hash(invitation.public_key()).map_err(|_| Failure::InvalidResponse)?),
                "algorithm":PAIRING_ALGORITHM,"ciphertext":STANDARD.encode(ciphertext),"proof":proof
            })),
        }
    }
}
fn validate_cipher(epoch: u64, ciphertext: &[u8]) -> Result<()> {
    if epoch == 0
        || epoch > i64::MAX as u64
        || !(28..=bootstrap::MAX_ENVELOPE_BYTES).contains(&ciphertext.len())
    {
        return Err(Failure::InvalidResponse);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PairingState {
    Pending,
    Approved,
}
pub struct Pairing {
    invitation: Invitation,
    state: PairingState,
}
impl Pairing {
    #[cfg(test)]
    pub(crate) fn test(invitation: Invitation, state: PairingState) -> Self {
        Self { invitation, state }
    }
    pub fn invitation(&self) -> &Invitation {
        &self.invitation
    }
    pub fn state(&self) -> PairingState {
        self.state
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingDTO {
    pairing_id: Uuid,
    recipient_public_key: String,
    nonce: String,
    authentication_tag: String,
    state: PairingState,
    #[serde(default, deserialize_with = "non_null")]
    algorithm: Option<String>,
    expires_at: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PairingResponse {
    scope: Scope,
    pairing: PairingDTO,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ClaimDTO {
    scope: Scope,
    pairing_id: Uuid,
    algorithm: String,
    ciphertext: String,
}

struct Deadline {
    wall: SystemTime,
    monotonic: Duration,
}
impl Deadline {
    fn restore(expiry: &str) -> Result<Self> {
        let date = parse_date(expiry)?;
        let wall = UNIX_EPOCH
            .checked_add(Duration::new(
                date.timestamp() as u64,
                date.timestamp_subsec_nanos(),
            ))
            .ok_or(Failure::InvalidResponse)?;
        let now = SystemTime::now();
        if wall <= now {
            return Ok(Self {
                wall,
                monotonic: Duration::ZERO,
            });
        }
        Self::admit(
            expiry,
            now,
            crate::clock::uptime().ok_or(Failure::InvalidResponse)?,
        )
    }
    fn admit(expiry: &str, wall: SystemTime, monotonic: Duration) -> Result<Self> {
        let date = parse_date(expiry)?;
        let expiry = UNIX_EPOCH
            .checked_add(Duration::new(
                date.timestamp() as u64,
                date.timestamp_subsec_nanos(),
            ))
            .ok_or(Failure::InvalidResponse)?;
        let remaining = expiry
            .duration_since(wall)
            .map_err(|_| Failure::InvalidResponse)?;
        if remaining.is_zero() || remaining > Duration::from_secs(330) {
            return Err(Failure::InvalidResponse);
        }
        Ok(Self {
            wall: expiry,
            monotonic: monotonic
                .checked_add(remaining)
                .ok_or(Failure::InvalidResponse)?,
        })
    }
    fn check(&self) -> Result<()> {
        let now = crate::clock::uptime().ok_or(Failure::InvalidResponse)?;
        if now >= self.monotonic || SystemTime::now() >= self.wall {
            return Err(Failure::InvalidResponse);
        }
        Ok(())
    }
}
pub struct ActionChallenge {
    server: ServerURL,
    scope: Scope,
    mutation: Mutation,
    public: [u8; 32],
    id: Uuid,
    nonce: [u8; 32],
    expires: String,
    deadline: Deadline,
}
impl ActionChallenge {
    #[cfg(test)]
    pub(crate) fn fixture(
        server: ServerURL,
        scope: Scope,
        mutation: Mutation,
        public: [u8; 32],
    ) -> Self {
        let expires = (chrono::Utc::now() + chrono::Duration::seconds(300)).to_rfc3339();
        Self {
            server,
            scope,
            mutation,
            public,
            id: Uuid::new_v4(),
            nonce: crate::crypto::random().unwrap(),
            deadline: Deadline::admit(&expires, SystemTime::now(), crate::clock::uptime().unwrap())
                .unwrap(),
            expires,
        }
    }
    pub(crate) fn matches_owner(
        &self,
        binding: &crate::key_store::KeyBinding,
        public: &[u8; 32],
        mutation: &Mutation,
    ) -> bool {
        self.public == *public
            && self.mutation.same(mutation)
            && self.binding().as_ref() == Some(binding)
    }
    fn binding(&self) -> Option<crate::key_store::KeyBinding> {
        crate::key_store::KeyBinding::new(
            self.server.clone(),
            self.scope.server_instance_id,
            self.scope.space_id,
            self.scope.identities(&self.server),
            self.mutation.epoch,
        )
        .ok()
    }
    pub fn id(&self) -> Uuid {
        self.id
    }
    pub fn nonce(&self) -> &[u8; 32] {
        &self.nonce
    }
    /// The owning UI must obtain fresh local authorization before signing. The
    /// transport checks the resulting signature but cannot establish user presence.
    pub fn authorize(self, proof: Proof) -> Result<SignedAction> {
        self.deadline.check()?;
        if proof.challenge() != self.id {
            return Err(Failure::InvalidResponse);
        }
        let signature = *proof.signature();
        verify_signature(&self.public, &self.nonce, &signature)?;
        Ok(SignedAction {
            challenge: self,
            signature,
        })
    }
}
pub struct SignedAction {
    challenge: ActionChallenge,
    signature: [u8; 64],
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProofDTO {
    challenge_id: Uuid,
    signature: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ChallengeDTO {
    challenge_id: Uuid,
    action: Action,
    key_epoch: u64,
    request_hash: String,
    nonce: String,
    expires_at: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChallengeResponse {
    scope: Scope,
    challenge: ChallengeDTO,
}

#[derive(Serialize, Deserialize)]
#[serde(
    tag = "action",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum MutationDTO {
    ReplaceRecovery {
        #[serde(deserialize_with = "required_optional")]
        expected_version: Option<u64>,
        ciphertext: String,
    },
    ApprovePairing {
        invitation: String,
        ciphertext: String,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JournalDTO {
    schema_version: u8,
    server: String,
    scope: Scope,
    key_epoch: u64,
    public_key: String,
    challenge_id: Uuid,
    nonce: String,
    expires_at: String,
    request_hash: String,
    mutation: MutationDTO,
    signature: String,
}
impl SignedAction {
    pub(crate) fn matches_owner(
        &self,
        binding: &crate::key_store::KeyBinding,
        public: &[u8; 32],
        mutation: &Mutation,
    ) -> bool {
        self.challenge.matches_owner(binding, public, mutation)
    }
    pub fn replay_allowed(&self) -> bool {
        self.challenge.deadline.check().is_ok()
            && self
                .challenge
                .mutation
                .validate_binding(&self.challenge.server, self.challenge.scope.space_id)
                .is_ok()
    }
    /// Inspect the original desired state for read-only reconciliation after the
    /// proof has expired. This never authorizes replay or a replacement challenge.
    pub fn expected_recovery(&self) -> Option<(u64, Option<u64>, &[u8])> {
        match &self.challenge.mutation.payload {
            Payload::Recovery {
                version,
                ciphertext,
            } => Some((self.challenge.mutation.epoch, *version, ciphertext)),
            _ => None,
        }
    }
    pub fn expected_pairing(&self) -> Option<&Invitation> {
        match &self.challenge.mutation.payload {
            Payload::Approval { invitation, .. } => Some(invitation),
            _ => None,
        }
    }
    fn proof(&self) -> ProofDTO {
        ProofDTO {
            challenge_id: self.challenge.id,
            signature: STANDARD.encode(self.signature),
        }
    }
    /// Persist in the authenticated secure store before sending a mutation. It is
    /// not a primary-library file, diagnostic record or export format.
    pub fn encode_secret(&self) -> Result<Zeroizing<Vec<u8>>> {
        let c = &self.challenge;
        let mutation = match &c.mutation.payload {
            Payload::Recovery {
                version,
                ciphertext,
            } => MutationDTO::ReplaceRecovery {
                expected_version: *version,
                ciphertext: STANDARD.encode(ciphertext),
            },
            Payload::Approval {
                invitation,
                ciphertext,
            } => MutationDTO::ApprovePairing {
                invitation: String::from_utf8(
                    invitation
                        .encode_qr()
                        .map_err(|_| Failure::InvalidResponse)?
                        .to_vec(),
                )
                .map_err(|_| Failure::InvalidResponse)?,
                ciphertext: STANDARD.encode(ciphertext),
            },
        };
        encode(&JournalDTO {
            schema_version: 1,
            server: c.server.for_secure_storage().into(),
            scope: c.scope.clone(),
            key_epoch: c.mutation.epoch,
            public_key: STANDARD.encode(c.public),
            challenge_id: c.id,
            nonce: STANDARD.encode(c.nonce),
            expires_at: c.expires.clone(),
            request_hash: STANDARD.encode(c.mutation.hash()?),
            mutation,
            signature: STANDARD.encode(self.signature),
        })
    }
    /// Reloading preserves the original proof. The server remains the authority
    /// for expiry after a restart; this method never obtains a replacement nonce.
    pub fn decode_secret(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_AUTH {
            return Err(Failure::MessageTooLarge);
        }
        let v: JournalDTO = decode(bytes)?;
        if v.schema_version != 1 || v.challenge_id.is_nil() || v.scope.server_instance_id.is_nil() {
            return Err(Failure::InvalidResponse);
        }
        let server = ServerURL::parse(&v.server)?;
        if server.for_secure_storage() != v.server {
            return Err(Failure::InvalidResponse);
        }
        v.scope.validate(v.scope.server_instance_id)?;
        let mutation = match v.mutation {
            MutationDTO::ReplaceRecovery {
                expected_version,
                ciphertext,
            } => Mutation::recovery(
                v.key_epoch,
                expected_version,
                &decode_bytes(&ciphertext, bootstrap::MAX_ENVELOPE_BYTES)?,
            )?,
            MutationDTO::ApprovePairing {
                invitation,
                ciphertext,
            } => Mutation::approval(
                v.key_epoch,
                Invitation::decode_retained_qr(invitation.as_bytes())
                    .map_err(|_| Failure::InvalidResponse)?,
                &decode_bytes(&ciphertext, bootstrap::MAX_ENVELOPE_BYTES)?,
            )?,
        };
        if let Payload::Approval { invitation, .. } = &mutation.payload
            && (invitation.server() != &server || invitation.space() != v.scope.space_id)
        {
            return Err(Failure::InvalidResponse);
        }
        if decode_array::<32>(&v.request_hash)? != mutation.hash()? {
            return Err(Failure::InvalidResponse);
        }
        let public = decode_public(&v.public_key)?;
        let nonce = decode_array::<32>(&v.nonce)?;
        let signature = decode_array::<64>(&v.signature)?;
        verify_signature(&public, &nonce, &signature)?;
        let deadline = Deadline::restore(&v.expires_at)?;
        Ok(Self {
            challenge: ActionChallenge {
                server,
                scope: v.scope,
                mutation,
                public,
                id: v.challenge_id,
                nonce,
                expires: v.expires_at,
                deadline,
            },
            signature,
        })
    }
}

impl BoundTransport {
    pub fn create_pairing(&mut self, draft: &PairingDraft) -> Result<Pairing> {
        self.preflight()?;
        if self.role == Role::Reader {
            return Err(Failure::ReadOnly);
        }
        let body = encode(
            &serde_json::json!({"recipientPublicKey":STANDARD.encode(draft.public_key()),"nonce":STANDARD.encode(draft.nonce()),"expiresInSeconds":bootstrap::DEFAULT_PAIRING_SECONDS}),
        )?;
        let result: Result<PairingResponse> = self.client.json(
            Method::POST,
            &format!("/v2/spaces/{}/pairings", self.scope.space_id),
            Some(&self.token),
            Some(&body),
            201,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.adopt_feed(response.scope)?;
        let pairing =
            self.decode_pairing(response.pairing, draft.public_key(), draft.nonce(), None)?;
        if pairing.state != PairingState::Pending {
            return Err(Failure::InvalidResponse);
        }
        Ok(pairing)
    }
    pub fn pairing(&mut self, invitation: &Invitation) -> Result<Pairing> {
        validate_invitation(invitation, &self.client.server, self.scope.space_id)?;
        self.preflight()?;
        let result: Result<PairingResponse> = self.client.json(
            Method::GET,
            &format!(
                "/v2/spaces/{}/pairings/{}",
                self.scope.space_id,
                invitation.pairing()
            ),
            Some(&self.token),
            None,
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.adopt_feed(response.scope)?;
        self.decode_pairing(
            response.pairing,
            invitation.public_key(),
            invitation.nonce(),
            Some(invitation),
        )
    }
    pub fn claim_pairing(&mut self, expected: &Pairing) -> Result<Vec<u8>> {
        if expected.state != PairingState::Approved {
            return Err(Failure::InvalidResponse);
        }
        let invitation = &expected.invitation;
        validate_invitation(invitation, &self.client.server, self.scope.space_id)?;
        self.preflight()?;
        let result: Result<ClaimDTO> = self.client.json(
            Method::POST,
            &format!(
                "/v2/spaces/{}/pairings/{}/claim",
                self.scope.space_id,
                invitation.pairing()
            ),
            Some(&self.token),
            None,
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.adopt_feed(response.scope)?;
        if response.pairing_id != invitation.pairing() || response.algorithm != PAIRING_ALGORITHM {
            return Err(Failure::InvalidResponse);
        }
        let ciphertext = decode_bytes(&response.ciphertext, bootstrap::MAX_ENVELOPE_BYTES)?;
        if ciphertext.len() < 28 {
            return Err(Failure::InvalidResponse);
        }
        Ok(ciphertext)
    }
    pub fn cancel_pairing(&mut self, invitation: &Invitation) -> Result<()> {
        // Allow explicit cleanup of an expired invitation, with its original server/space.
        if invitation.server() != &self.client.server || invitation.space() != self.scope.space_id {
            return Err(Failure::InvalidResponse);
        }
        self.preflight()?;
        let path = format!(
            "/v2/spaces/{}/pairings/{}",
            self.scope.space_id,
            invitation.pairing()
        );
        if self.role == Role::Reader {
            return Err(Failure::ReadOnly);
        }
        let result = self.client.exchange(
            Method::DELETE,
            self.client.server.endpoint(&path)?,
            Some(&self.token),
            None,
            Reply::new(204, MAX_AUTH),
        );
        self.remember(result)?;
        Ok(())
    }
    fn decode_pairing(
        &self,
        value: PairingDTO,
        public: &[u8; 65],
        nonce: &[u8; 32],
        expected: Option<&Invitation>,
    ) -> Result<Pairing> {
        if value.algorithm.is_some()
            || decode_array::<65>(&value.recipient_public_key)? != *public
            || decode_array::<32>(&value.nonce)? != *nonce
        {
            return Err(Failure::InvalidResponse);
        }
        let expiry = parse_date(&value.expires_at)?.timestamp();
        let invitation = Invitation::new(
            self.client.server.clone(),
            self.scope.space_id,
            value.pairing_id,
            *nonce,
            *public,
            expiry,
            unix_now()?,
        )
        .map_err(|_| Failure::InvalidResponse)?;
        if invitation.confirmation_code() != value.authentication_tag
            || expected.is_some_and(|v| v != &invitation)
        {
            return Err(Failure::InvalidResponse);
        }
        Ok(Pairing {
            invitation,
            state: value.state,
        })
    }
    /// Candidate material must already be journaled by the key owner. No private
    /// key enters this transport; the expected public key is checked before asking
    /// for a challenge. A returned challenge is bound to the exact mutation/scope.
    pub fn request_key_challenge(
        &mut self,
        mutation: Mutation,
        public: &[u8; 32],
    ) -> Result<ActionChallenge> {
        validate_public(public)?;
        if mutation.epoch != self.key_epoch {
            return Err(Failure::InvalidResponse);
        }
        mutation.validate_binding(&self.client.server, self.scope.space_id)?;
        let hash = mutation.hash()?;
        let authority = self.key_authority()?;
        if !can_mutate(self.role, mutation.action()) {
            return Err(Failure::ReadOnly);
        }
        if authority.public_key() != Some(public) {
            return Err(Failure::InvalidResponse);
        }
        let expected_scope = self.scope.clone();
        let body = encode(
            &serde_json::json!({"expectedScope":expected_scope,"action":mutation.action(),"keyEpoch":mutation.epoch,"requestHash":STANDARD.encode(hash)}),
        )?;
        let wall = SystemTime::now();
        let monotonic = crate::clock::uptime().ok_or(Failure::InvalidResponse)?;
        let result: Result<ChallengeResponse> = self.client.json(
            Method::POST,
            &format!("/v2/spaces/{}/key-challenges", self.scope.space_id),
            Some(&self.token),
            Some(&body),
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        let c = response.challenge;
        self.admit_key_response(response.scope.clone(), c.key_epoch)?;
        if response.scope != expected_scope
            || c.challenge_id.is_nil()
            || c.action != mutation.action()
            || decode_array::<32>(&c.request_hash)? != hash
        {
            return Err(Failure::InvalidResponse);
        }
        let nonce = decode_array::<32>(&c.nonce)?;
        let deadline = Deadline::admit(&c.expires_at, wall, monotonic)?;
        deadline.check()?;
        Ok(ActionChallenge {
            server: self.client.server.clone(),
            scope: expected_scope,
            mutation,
            public: *public,
            id: c.challenge_id,
            nonce,
            expires: c.expires_at,
            deadline,
        })
    }
    fn validate_signed(&mut self, signed: &SignedAction) -> Result<()> {
        let c = &signed.challenge;
        c.deadline.check()?;
        if c.server != self.client.server || c.mutation.epoch != self.key_epoch {
            return Err(Failure::InvalidResponse);
        }
        c.mutation
            .validate_binding(&self.client.server, self.scope.space_id)?;
        self.preflight()?;
        let result = self.validate_feed(&c.scope);
        self.remember(result)?;
        if self.scope != c.scope {
            return Err(Failure::InvalidResponse);
        }
        if !can_mutate(self.role, c.mutation.action()) {
            return Err(Failure::ReadOnly);
        }
        c.deadline.check()
    }
    /// Journal the SignedAction before this call. On ambiguity, reuse it verbatim;
    /// creating a fresh challenge could turn a lost receipt into another mutation.
    pub fn replace_recovery(&mut self, signed: &SignedAction) -> Result<RemoteRecovery> {
        self.replace_recovery_guarded(signed, &mut || Ok(()))
    }
    pub(crate) fn replace_recovery_guarded(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> Result<()>,
    ) -> Result<RemoteRecovery> {
        let Payload::Recovery {
            version,
            ciphertext,
        } = &signed.challenge.mutation.payload
        else {
            return Err(Failure::InvalidResponse);
        };
        self.validate_signed(signed)?;
        let body = signed.challenge.mutation.body(&signed.proof())?;
        guard()?;
        let result: Result<RecoveryDTO> = self.client.json(
            Method::PUT,
            &format!("/v2/spaces/{}/recovery-envelope", self.scope.space_id),
            Some(&self.token),
            Some(&body),
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.admit_key_response(response.scope.clone(), response.key_epoch)?;
        if response.scope != signed.challenge.scope {
            return Err(Failure::InvalidResponse);
        }
        let receipt = decode_envelope(
            response.recovery.ok_or(Failure::InvalidResponse)?,
            self.key_epoch,
        )?;
        if receipt.version != version.unwrap_or(0) + 1 || receipt.ciphertext != *ciphertext {
            return Err(Failure::InvalidResponse);
        }
        Ok(receipt)
    }
    pub fn approve_pairing(&mut self, signed: &SignedAction) -> Result<Pairing> {
        self.approve_pairing_guarded(signed, &mut || Ok(()))
    }
    pub(crate) fn approve_pairing_guarded(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> Result<()>,
    ) -> Result<Pairing> {
        let Payload::Approval { invitation, .. } = &signed.challenge.mutation.payload else {
            return Err(Failure::InvalidResponse);
        };
        self.validate_signed(signed)?;
        let body = signed.challenge.mutation.body(&signed.proof())?;
        guard()?;
        let result: Result<PairingResponse> = self.client.json(
            Method::PUT,
            &format!(
                "/v2/spaces/{}/pairings/{}/approval",
                self.scope.space_id,
                invitation.pairing()
            ),
            Some(&self.token),
            Some(&body),
            200,
            MAX_AUTH,
        );
        let response = self.remember(result)?;
        self.adopt_feed(response.scope.clone())?;
        if response.scope != signed.challenge.scope {
            return Err(Failure::InvalidResponse);
        }
        let pairing = self.decode_pairing(
            response.pairing,
            invitation.public_key(),
            invitation.nonce(),
            Some(invitation),
        )?;
        if pairing.state != PairingState::Approved {
            return Err(Failure::InvalidResponse);
        }
        Ok(pairing)
    }
}
fn can_mutate(role: Role, action: Action) -> bool {
    role != Role::Reader && (action != Action::ReplaceRecovery || role == Role::Owner)
}
fn unix_now() -> Result<i64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|v| i64::try_from(v.as_secs()).ok())
        .ok_or(Failure::InvalidResponse)
}
fn validate_invitation(invitation: &Invitation, server: &ServerURL, space: Uuid) -> Result<()> {
    if invitation.server() != server || invitation.space() != space {
        return Err(Failure::InvalidResponse);
    }
    invitation
        .validate_time(unix_now()?)
        .map_err(|_| Failure::InvalidResponse)
}
fn decode_array<const N: usize>(text: &str) -> Result<[u8; N]> {
    decode_bytes(text, N)?
        .as_slice()
        .try_into()
        .map_err(|_| Failure::InvalidResponse)
}
fn verify_signature(public: &[u8; 32], nonce: &[u8; 32], signature: &[u8; 64]) -> Result<()> {
    let mut message = b"snippets-library-action-proof-v1\n".to_vec();
    message.extend_from_slice(nonce);
    ed25519_dalek::VerifyingKey::from_bytes(public)
        .map_err(|_| Failure::InvalidResponse)?
        .verify_strict(&message, &ed25519_dalek::Signature::from_bytes(signature))
        .map_err(|_| Failure::InvalidResponse)
}

#[cfg(test)]
#[path = "cloud_action_journal_tests.rs"]
mod journal_tests;
