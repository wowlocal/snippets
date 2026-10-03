//! New-device side of device-approved sign-in (server ADR 0007). One closed
//! Secret Service document keeps the pairing recipient material, request ID and
//! poll token. The poll token is a credential: it has no Debug, Display or
//! serialization escape and leaves only in the claim body. An approved claim is
//! committed by the ordinary credential journal; the recipient material then
//! moves into the existing recipient pairing journal for the returned library.
use super::*;
use crate::{
    bootstrap::{DeviceSignIn, PairingDraft},
    cloud::{DeviceApproval, DeviceClaim, PollToken},
};

/// Last durable step only. `Waiting` carries the public payload for display.
pub enum Status {
    Waiting(DeviceSignIn),
    /// The session is committed; the library key still has to be claimed.
    Approved,
}
/// One poll. An approved grant leaves this owner only to be journaled at once.
pub enum Claim {
    Pending(DeviceSignIn),
    Approved(Box<cloud::IssuedGrant>),
}
struct Request {
    id: Uuid,
    poll: PollToken,
    expires_at: i64,
}
struct Document {
    deployment: Deployment,
    draft: PairingDraft,
    request: Option<Request>,
    approval: Option<DeviceApproval>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Document {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Option<Self>> {
        let Some(bytes) = owner.read(Slot::DeviceSignIn)? else {
            return Ok(None);
        };
        let value = canonical::parse(&bytes)?;
        let v = exact(
            &value,
            &["schema", "deployment", "draft", "request", "approval"],
        )?;
        if v["schema"].as_int()? != 1 {
            return Err(Failure::InvalidState);
        }
        let draft = PairingDraft::decode_secret(&v["draft"].encode()?)
            .map_err(|_| Failure::InvalidState)?;
        let request = parse_optional(&v["request"], |value| {
            let r = exact(value, &["id", "pollToken", "expiresAt"])?;
            let id = uuid_text(r["id"].as_text()?)?;
            let poll = PollToken::new(Zeroizing::new(r["pollToken"].as_text()?.to_owned()))
                .map_err(|_| Failure::InvalidState)?;
            let expires_at = r["expiresAt"].as_int()?;
            if expires_at < 0 {
                return Err(Failure::InvalidState);
            }
            Ok(Request {
                id,
                poll,
                expires_at,
            })
        })?;
        let approval = parse_optional(&v["approval"], |value| {
            let a = exact(value, &["spaceId", "pairingId"])?;
            Ok(DeviceApproval {
                space: uuid_text(a["spaceId"].as_text()?)?,
                pairing: uuid_text(a["pairingId"].as_text()?)?,
            })
        })?;
        // Exactly one phase: a pending request, or an approved library pairing.
        if request.is_some() == approval.is_some() {
            return Err(Failure::InvalidState);
        }
        Ok(Some(Self {
            deployment: Deployment::parse(&v["deployment"])?,
            draft,
            request,
            approval,
            snapshot: Some(bytes),
        }))
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        if self.request.is_some() == self.approval.is_some() {
            return Err(Failure::InvalidState);
        }
        let bytes = object([
            ("schema", Value::Int(1)),
            ("deployment", self.deployment.value()),
            (
                "draft",
                canonical::parse(
                    &self
                        .draft
                        .encode_secret()
                        .map_err(|_| Failure::InvalidState)?,
                )?,
            ),
            (
                "request",
                optional(self.request.as_ref().map(|r| {
                    object([
                        ("id", Value::text(r.id.to_string())),
                        ("pollToken", Value::text(r.poll.for_secure_storage())),
                        ("expiresAt", Value::Int(r.expires_at)),
                    ])
                })),
            ),
            (
                "approval",
                optional(self.approval.map(|a| {
                    object([
                        ("spaceId", Value::text(a.space.to_string())),
                        ("pairingId", Value::text(a.pairing.to_string())),
                    ])
                })),
            ),
        ])
        .encode()?;
        owner.replace(
            Slot::DeviceSignIn,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        Ok(())
    }
    fn payload(&self) -> Result<DeviceSignIn> {
        let request = self.request.as_ref().ok_or(Failure::InvalidState)?;
        DeviceSignIn::retained(
            self.deployment.server().clone(),
            request.id,
            &self.draft,
            request.expires_at,
        )
        .map_err(|_| Failure::InvalidState)
    }
    fn status(&self) -> Result<Status> {
        if self.approval.is_some() {
            return Ok(Status::Approved);
        }
        Ok(Status::Waiting(self.payload()?))
    }
}
fn uuid_text(text: &str) -> Result<Uuid> {
    Uuid::parse_str(text)
        .ok()
        .filter(|id| !id.is_nil() && id.to_string() == text)
        .ok_or(Failure::InvalidState)
}
fn now() -> Result<i64> {
    i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| Failure::InvalidClock)?
            .as_secs(),
    )
    .map_err(|_| Failure::InvalidClock)
}

/// Offline: no network, token or key is read for display.
pub fn inspect<B: Backend>(store: &mut secret_store::Store<B>) -> Result<Option<Status>> {
    store.transaction_with(|owner| Document::load(owner)?.map(|d| d.status()).transpose())
}
/// The deployment a saved request or approval belongs to; offline.
pub fn saved_deployment<B: Backend>(
    store: &mut secret_store::Store<B>,
) -> Result<Option<Deployment>> {
    store.transaction_with(|owner| Ok(Document::load(owner)?.map(|d| d.deployment)))
}
/// The approved library pairing, once the session has been committed; offline.
pub fn saved_approval<B: Backend>(
    store: &mut secret_store::Store<B>,
) -> Result<Option<DeviceApproval>> {
    store.transaction_with(|owner| Ok(Document::load(owner)?.and_then(|d| d.approval)))
}
/// A signed-out device opens one request. An unexpired saved request for the
/// same deployment is shown again instead of opening another.
pub fn begin<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
) -> Result<DeviceSignIn> {
    store.transaction_with(|owner| {
        begin_locked(
            owner,
            client,
            &|| client.preflight_credentials(),
            &|draft| client.create_device_request(draft),
        )
    })
}
type Create<'a> =
    dyn Fn(&PairingDraft) -> std::result::Result<cloud::DeviceRequestReceipt, cloud::Failure> + 'a;
fn begin_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    client: &CloudClient,
    preflight: &dyn Fn() -> std::result::Result<(), cloud::Failure>,
    create: &Create<'_>,
) -> Result<DeviceSignIn> {
    let archive = Archive::load(owner)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    if archive.current.is_some() {
        return Err(Failure::InvalidState);
    }
    let deployment = client.credential_deployment();
    let existing = Document::load(owner)?;
    if let Some(document) = &existing {
        if document.approval.is_some() {
            return Err(Failure::Busy);
        }
        let expires_at = document.request.as_ref().map_or(0, |r| r.expires_at);
        if document.deployment == deployment && expires_at > now()? + 30 {
            return document.payload();
        }
    }
    if !client.supports_device_sign_in() {
        return Err(Failure::Cloud(cloud::Failure::IncompatibleServer));
    }
    preflight()?;
    let draft = PairingDraft::generate().map_err(|_| Failure::InvalidState)?;
    let receipt = create(&draft)?;
    let mut document = Document {
        deployment,
        draft,
        request: Some(Request {
            id: receipt.request,
            poll: receipt.poll_token,
            expires_at: receipt.expires_at,
        }),
        approval: None,
        snapshot: existing.and_then(|d| d.snapshot),
    };
    let payload = document.payload()?;
    document.save(owner)?;
    Ok(payload)
}
/// Polls with the retained token. Only the exact discovered deployment that
/// issued the request ever receives it.
pub fn claim<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
) -> Result<Claim> {
    store.transaction_with(|owner| {
        claim_locked(
            owner,
            client,
            &|| client.preflight_credentials(),
            &|id, poll| client.claim_device_request(id, poll),
        )
    })
}
type ClaimRequest<'a> =
    dyn Fn(Uuid, &PollToken) -> std::result::Result<DeviceClaim, cloud::Failure> + 'a;
fn claim_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    client: &CloudClient,
    preflight: &dyn Fn() -> std::result::Result<(), cloud::Failure>,
    request: &ClaimRequest<'_>,
) -> Result<Claim> {
    let document = Document::load(owner)?.ok_or(Failure::InvalidState)?;
    let pending = document.request.as_ref().ok_or(Failure::Busy)?;
    if document.deployment != client.credential_deployment() {
        return Err(Failure::WrongDeployment);
    }
    preflight()?;
    match request(pending.id, &pending.poll)? {
        DeviceClaim::Pending { expires_at } => {
            if expires_at != pending.expires_at {
                return Err(Failure::Cloud(cloud::Failure::InvalidResponse));
            }
            Ok(Claim::Pending(document.payload()?))
        }
        DeviceClaim::Approved(grant) => Ok(Claim::Approved(grant)),
    }
}
/// After the claimed session is committed, the poll token is discarded and only
/// the recipient material and the returned library pairing remain.
pub fn record_approval<B: Backend>(
    store: &mut secret_store::Store<B>,
    deployment: &Deployment,
    approval: DeviceApproval,
) -> Result<()> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        if archive.saved_deployment()?.as_ref() != Some(deployment) {
            return Err(Failure::Stale);
        }
        let mut document = Document::load(owner)?.ok_or(Failure::InvalidState)?;
        if document.deployment != *deployment {
            return Err(Failure::WrongDeployment);
        }
        if document.approval == Some(approval) {
            return Ok(());
        }
        if document.request.is_none() {
            return Err(Failure::Busy);
        }
        document.request = None;
        document.approval = Some(approval);
        document.save(owner)
    })
}
/// The library pairing to claim with this device's own recipient material. The
/// caller moves the draft into the recipient journal, then calls retire().
pub(crate) type Approved = (Deployment, PairingDraft, DeviceApproval, Zeroizing<Vec<u8>>);
pub(crate) fn approved_draft<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Option<Approved>> {
    let Some(document) = Document::load(owner)? else {
        return Ok(None);
    };
    let Some(approval) = document.approval else {
        return Ok(None);
    };
    Ok(Some((
        document.deployment,
        document.draft,
        approval,
        document.snapshot.ok_or(Failure::InvalidState)?,
    )))
}
pub(crate) fn retire<B: Backend>(owner: &mut Locked<'_, B>, snapshot: &[u8]) -> Result<()> {
    Ok(owner.replace(Slot::DeviceSignIn, Some(snapshot), None)?)
}
/// Cancel discards local state; an open server request simply expires.
pub fn cancel<B: Backend>(store: &mut secret_store::Store<B>) -> Result<()> {
    store.transaction_with(|owner| {
        let Some(document) = Document::load(owner)? else {
            return Ok(());
        };
        retire(
            owner,
            document.snapshot.as_deref().ok_or(Failure::InvalidState)?,
        )
    })
}

#[cfg(test)]
#[path = "device_sign_in_tests.rs"]
mod tests;
