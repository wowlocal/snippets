//! Durable library-key onboarding. Blocking operations run on an owner worker;
//! no key, account, network connection or disclosure is initialized at startup.
use crate::{
    bootstrap::{self, Authority, AuthorityContext, Bundle, RecoveryKit},
    canonical::{self, Value},
    cloud::{self, Binding, BoundTransport, Role, ServerURL},
    crypto::RootKey,
    secret_store::{self, Backend, Locked, Slot, Store},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use uuid::Uuid;
use zeroize::Zeroizing;

#[path = "pairing_store.rs"]
pub mod recipient;

#[path = "recovery_disclosure.rs"]
pub mod disclosure;

#[path = "key_mutation.rs"]
pub mod mutations;

#[path = "account_handover.rs"]
pub mod handover;

#[path = "pairing_candidate.rs"]
pub mod candidate;

#[path = "bootstrap_candidate.rs"]
pub mod initial_candidate;

#[path = "key_history.rs"]
pub mod history;

#[path = "history_capacity.rs"]
pub mod capacity;

#[path = "history_restore.rs"]
pub mod restoration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Secret(secret_store::Failure),
    Cloud(cloud::Failure),
    Crypto(bootstrap::Failure),
    Authentication(crate::local_auth::Failure),
    InvalidState,
    ReviewRequired,
    KeyConflict,
    RecoveryUnavailable,
    VerificationMismatch,
    Busy,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<secret_store::Failure> for Failure {
    fn from(v: secret_store::Failure) -> Self {
        Self::Secret(v)
    }
}
impl From<cloud::Failure> for Failure {
    fn from(v: cloud::Failure) -> Self {
        Self::Cloud(v)
    }
}
impl From<bootstrap::Failure> for Failure {
    fn from(v: bootstrap::Failure) -> Self {
        Self::Crypto(v)
    }
}
impl From<crate::local_auth::Failure> for Failure {
    fn from(v: crate::local_auth::Failure) -> Self {
        Self::Authentication(v)
    }
}
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::InvalidState
    }
}

/// Opaque account/dataset pin. Feed rotation does not replace a library key.
/// A changed membership, deployment, dataset or key epoch requires review.
#[derive(Clone, PartialEq, Eq)]
pub struct KeyBinding {
    server: ServerURL,
    instance: Uuid,
    space: Uuid,
    membership: Binding,
    dataset: Binding,
    epoch: u64,
}
impl KeyBinding {
    #[cfg(feature = "desktop")]
    pub(crate) fn key_epoch(&self) -> u64 {
        self.epoch
    }
    pub(crate) fn space(&self) -> Uuid {
        self.space
    }
    pub(crate) fn matches_deployment(&self, deployment: &crate::auth_store::Deployment) -> bool {
        self.server == *deployment.server() && self.instance == deployment.instance()
    }
    /// Only explicit library review may reuse an owned capability across account,
    /// membership, dataset or epoch changes. Ordinary admission uses full equality.
    pub(crate) fn same_library(&self, other: &Self) -> bool {
        self.server == other.server && self.instance == other.instance && self.space == other.space
    }
    pub(crate) fn new(
        server: ServerURL,
        instance: Uuid,
        space: Uuid,
        identities: (Binding, Binding),
        epoch: u64,
    ) -> Result<Self> {
        AuthorityContext::new(server.clone(), instance, space)?;
        if epoch == 0 || epoch > i64::MAX as u64 {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            server,
            instance,
            space,
            membership: identities.0,
            dataset: identities.1,
            epoch,
        })
    }
    pub fn checkpoint_scope(&self) -> crate::journal::Scope {
        crate::journal::Scope {
            membership: self.membership.clone(),
            dataset: self.dataset.clone(),
        }
    }
    fn context(&self) -> Result<AuthorityContext> {
        Ok(AuthorityContext::new(
            self.server.clone(),
            self.instance,
            self.space,
        )?)
    }
    pub(crate) fn value(&self) -> Value {
        object([
            ("server", Value::text(self.server.for_secure_storage())),
            ("instance", Value::text(self.instance.to_string())),
            ("space", Value::text(self.space.to_string())),
            (
                "membership",
                Value::text(STANDARD.encode(self.membership.bytes_for_checkpoint())),
            ),
            (
                "dataset",
                Value::text(STANDARD.encode(self.dataset.bytes_for_checkpoint())),
            ),
            ("epoch", Value::Int(self.epoch as i64)),
        ])
    }
    pub(crate) fn parse(value: &Value) -> Result<Self> {
        let v = exact(
            value,
            &[
                "server",
                "instance",
                "space",
                "membership",
                "dataset",
                "epoch",
            ],
        )?;
        let text = v["server"].as_text()?;
        let server = ServerURL::parse(text)?;
        if server.for_secure_storage() != text {
            return Err(Failure::InvalidState);
        }
        let instance = uuid(v["instance"].as_text()?)?;
        let space = uuid(v["space"].as_text()?)?;
        Self::new(
            server,
            instance,
            space,
            (
                Binding::from_checkpoint(array(v["membership"].as_text()?)?),
                Binding::from_checkpoint(array(v["dataset"].as_text()?)?),
            ),
            u64::try_from(v["epoch"].as_int()?).map_err(|_| Failure::InvalidState)?,
        )
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KitStatus {
    None,
    AwaitingPresentation,
    VerifiedCurrent,
    Replaced,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Ready { kit: KitStatus },
    NeedsTrustedDeviceOrRecovery,
}

pub struct VerifiedKey {
    binding: KeyBinding,
    bundle: Bundle,
}
impl VerifiedKey {
    #[cfg(feature = "desktop")]
    pub(crate) fn validate_owner<B: Backend>(&self, owner: &mut Locked<'_, B>) -> Result<()> {
        recipient::require_idle(owner, &self.binding)?;
        mutations::require_idle(owner, &self.binding)?;
        let archive = Archive::load(owner)?;
        archive.check_binding(&self.binding)?;
        if archive.pending.is_some() {
            return Err(Failure::Busy);
        }
        let installed = read_installed(owner, &self.binding)?.ok_or(Failure::KeyConflict)?;
        if installed.bundle.for_secure_storage() != self.bundle.for_secure_storage() {
            return Err(Failure::KeyConflict);
        }
        validate_presentation(&archive, &installed)
    }
    pub fn binding(&self) -> &KeyBinding {
        &self.binding
    }
    pub fn with_wire_key<T>(&self, action: impl FnOnce(&RootKey, &[u8; 32]) -> T) -> T {
        let material = self.bundle.for_secure_storage();
        let root = RootKey::from_bytes(&material[..32]).expect("validated 64-byte bundle");
        let salt = material[32..].try_into().expect("validated 32-byte salt");
        action(&root, salt)
    }
}
struct Installed {
    binding: KeyBinding,
    bundle: Bundle,
}
/// A locally owned capability proposed for explicit review, not a data-plane key.
type ReviewKey = (Installed, Option<Presentation>);
impl Installed {
    fn value(&self) -> Result<Value> {
        Ok(object([
            ("schema", Value::Int(1)),
            ("binding", self.binding.value()),
            ("bundle", canonical::parse(&self.bundle.encode_secret()?)?),
        ]))
    }
    fn decode(bytes: &[u8]) -> Result<Self> {
        let value = canonical::parse(bytes)?;
        let v = exact(&value, &["schema", "binding", "bundle"])?;
        if v["schema"].as_int()? != 1 {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            binding: KeyBinding::parse(&v["binding"])?,
            bundle: Bundle::decode(&v["bundle"].encode()?)?,
        })
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Initial,
    Recovery,
}
struct Pending {
    kind: Kind,
    binding: KeyBinding,
    bundle: Bundle,
    kit: RecoveryKit,
    version: u64,
    ciphertext: Vec<u8>,
}
impl Pending {
    fn validate(&self) -> Result<()> {
        validate_kit(&self.kit, &self.binding)?;
        if self.version == 0
            || self.version > i64::MAX as u64
            || (self.kind == Kind::Initial && self.version != 1)
        {
            return Err(Failure::InvalidState);
        }
        let opened = bootstrap::open_recovery(&self.ciphertext, &self.kit)?;
        if opened.for_secure_storage() != self.bundle.for_secure_storage() {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
    fn value(&self) -> Result<Value> {
        Ok(object([
            (
                "kind",
                Value::text(if self.kind == Kind::Initial {
                    "initial"
                } else {
                    "recovery"
                }),
            ),
            ("binding", self.binding.value()),
            ("bundle", canonical::parse(&self.bundle.encode_secret()?)?),
            ("kit", canonical::parse(&self.kit.encode_secret_qr()?)?),
            ("version", Value::Int(self.version as i64)),
            ("ciphertext", Value::text(STANDARD.encode(&self.ciphertext))),
        ]))
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = exact(
            value,
            &["kind", "binding", "bundle", "kit", "version", "ciphertext"],
        )?;
        let kind = match v["kind"].as_text()? {
            "initial" => Kind::Initial,
            "recovery" => Kind::Recovery,
            _ => return Err(Failure::InvalidState),
        };
        let pending = Self {
            kind,
            binding: KeyBinding::parse(&v["binding"])?,
            bundle: Bundle::decode(&v["bundle"].encode()?)?,
            kit: RecoveryKit::decode_secret_qr(&v["kit"].encode()?)?,
            version: u64::try_from(v["version"].as_int()?).map_err(|_| Failure::InvalidState)?,
            ciphertext: decode64(v["ciphertext"].as_text()?, bootstrap::MAX_ENVELOPE_BYTES)?
                .to_vec(),
        };
        pending.validate()?;
        Ok(pending)
    }
}
struct Presentation {
    binding: KeyBinding,
    version: u64,
    status: KitStatus,
    material: PresentationMaterial,
}
enum PresentationMaterial {
    Retained {
        kit: RecoveryKit,
        ciphertext: Vec<u8>,
    },
    Verification {
        ciphertext_hash: [u8; 32],
        kit_hash: [u8; 32],
        authority: [u8; 32],
    },
}
impl Presentation {
    fn for_review(&self, binding: &KeyBinding) -> Result<Option<Self>> {
        self.validate()?;
        if !self.binding.same_library(binding) || self.binding.epoch != binding.epoch {
            return Ok(None);
        }
        let mut presentation = Self::parse(&self.value()?)?;
        presentation.binding = binding.clone();
        presentation.validate()?;
        Ok(Some(presentation))
    }
    fn value(&self) -> Result<Value> {
        self.validate()?;
        let mut fields = object([
            ("binding", self.binding.value()),
            ("version", Value::Int(self.version as i64)),
            (
                "status",
                Value::text(match self.status {
                    KitStatus::AwaitingPresentation => "awaiting_presentation",
                    KitStatus::VerifiedCurrent => "verified_current",
                    KitStatus::Replaced => "replaced",
                    KitStatus::None => return Err(Failure::InvalidState),
                }),
            ),
        ]);
        let Value::Object(ref mut values) = fields else {
            return Err(Failure::InvalidState);
        };
        match &self.material {
            PresentationMaterial::Retained { kit, ciphertext } => {
                values.insert("kind".into(), Value::text("retained"));
                values.insert("kit".into(), canonical::parse(&kit.encode_secret_qr()?)?);
                values.insert(
                    "ciphertext".into(),
                    Value::text(STANDARD.encode(ciphertext)),
                );
            }
            PresentationMaterial::Verification {
                ciphertext_hash,
                kit_hash,
                authority,
            } => {
                values.insert("kind".into(), Value::text("verification"));
                values.insert(
                    "ciphertextHash".into(),
                    Value::text(STANDARD.encode(ciphertext_hash)),
                );
                values.insert("kitHash".into(), Value::text(STANDARD.encode(kit_hash)));
                values.insert("authority".into(), Value::text(STANDARD.encode(authority)));
            }
        }
        Ok(fields)
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = value.as_object()?;
        let kind = v.get("kind").ok_or(Failure::InvalidState)?.as_text()?;
        let material = match kind {
            "retained" => {
                let v = exact(
                    value,
                    &["kind", "binding", "version", "status", "kit", "ciphertext"],
                )?;
                PresentationMaterial::Retained {
                    kit: RecoveryKit::decode_secret_qr(&v["kit"].encode()?)?,
                    ciphertext: decode64(
                        v["ciphertext"].as_text()?,
                        bootstrap::MAX_ENVELOPE_BYTES,
                    )?
                    .to_vec(),
                }
            }
            "verification" => {
                let v = exact(
                    value,
                    &[
                        "kind",
                        "binding",
                        "version",
                        "status",
                        "ciphertextHash",
                        "kitHash",
                        "authority",
                    ],
                )?;
                PresentationMaterial::Verification {
                    ciphertext_hash: array(v["ciphertextHash"].as_text()?)?,
                    kit_hash: array(v["kitHash"].as_text()?)?,
                    authority: array(v["authority"].as_text()?)?,
                }
            }
            _ => return Err(Failure::InvalidState),
        };
        let p = Self {
            binding: KeyBinding::parse(&v["binding"])?,
            version: u64::try_from(v["version"].as_int()?).map_err(|_| Failure::InvalidState)?,
            status: match v["status"].as_text()? {
                "awaiting_presentation" => KitStatus::AwaitingPresentation,
                "verified_current" => KitStatus::VerifiedCurrent,
                "replaced" => KitStatus::Replaced,
                _ => return Err(Failure::InvalidState),
            },
            material,
        };
        p.validate()?;
        Ok(p)
    }
    /// Schema 1's verified status came only from authenticated recovery input.
    /// Convert it in memory after checking its AEAD; publication persists schema 2
    /// only after matching the installed key and the fresh remote authority.
    fn parse_legacy(value: &Value) -> Result<Self> {
        let v = exact(
            value,
            &["binding", "kit", "version", "ciphertext", "status"],
        )?;
        let binding = KeyBinding::parse(&v["binding"])?;
        let kit = RecoveryKit::decode_secret_qr(&v["kit"].encode()?)?;
        let version = u64::try_from(v["version"].as_int()?).map_err(|_| Failure::InvalidState)?;
        let ciphertext =
            decode64(v["ciphertext"].as_text()?, bootstrap::MAX_ENVELOPE_BYTES)?.to_vec();
        let status = match v["status"].as_text()? {
            "awaiting_presentation" => KitStatus::AwaitingPresentation,
            "verified_current" => KitStatus::VerifiedCurrent,
            "replaced" => KitStatus::Replaced,
            _ => return Err(Failure::InvalidState),
        };
        validate_kit(&kit, &binding)?;
        let bundle = bootstrap::open_recovery(&ciphertext, &kit)?;
        let material = if status == KitStatus::VerifiedCurrent {
            Self::verification_material(&binding, &kit, &ciphertext, &bundle)?
        } else {
            PresentationMaterial::Retained { kit, ciphertext }
        };
        let p = Self {
            binding,
            version,
            status,
            material,
        };
        p.validate()?;
        Ok(p)
    }
    fn verification_material(
        binding: &KeyBinding,
        kit: &RecoveryKit,
        ciphertext: &[u8],
        bundle: &Bundle,
    ) -> Result<PresentationMaterial> {
        Ok(PresentationMaterial::Verification {
            ciphertext_hash: Sha256::digest(ciphertext).into(),
            kit_hash: Sha256::digest(kit.encode_secret_qr()?.as_slice()).into(),
            authority: Authority::new(bundle, &binding.context()?).public_key(),
        })
    }
    fn retained(&self) -> Result<(&RecoveryKit, &[u8])> {
        match &self.material {
            PresentationMaterial::Retained { kit, ciphertext } => Ok((kit, ciphertext)),
            PresentationMaterial::Verification { .. } => Err(Failure::RecoveryUnavailable),
        }
    }
    fn matches_bundle(&self, bundle: &Bundle) -> Result<bool> {
        match &self.material {
            PresentationMaterial::Retained { kit, ciphertext } => Ok(bootstrap::open_recovery(
                ciphertext, kit,
            )?
            .for_secure_storage()
                == bundle.for_secure_storage()),
            PresentationMaterial::Verification { authority, .. } => {
                Ok(*authority == Authority::new(bundle, &self.binding.context()?).public_key())
            }
        }
    }
    fn matches_evidence(&self, evidence: &Evidence) -> bool {
        self.version == evidence.version
            && match &self.material {
                PresentationMaterial::Retained { ciphertext, .. } => {
                    *ciphertext == evidence.ciphertext
                }
                PresentationMaterial::Verification {
                    ciphertext_hash, ..
                } => *ciphertext_hash == <[u8; 32]>::from(Sha256::digest(&evidence.ciphertext)),
            }
    }
    fn confirm_saved(&mut self) -> Result<()> {
        if self.status != KitStatus::AwaitingPresentation {
            return Err(Failure::RecoveryUnavailable);
        }
        let (kit, ciphertext) = self.retained()?;
        let bundle = bootstrap::open_recovery(ciphertext, kit)?;
        self.material = Self::verification_material(&self.binding, kit, ciphertext, &bundle)?;
        self.status = KitStatus::VerifiedCurrent;
        Ok(())
    }
    /// Retire an exact promoted duplicate while retaining its library key. The
    /// current presentation remains the redo source until all copies are retired.
    fn retire_matching(&mut self, shown: &Self) -> Result<bool> {
        if self.status != KitStatus::AwaitingPresentation
            || !self.binding.same_library(&shown.binding)
            || self.binding.epoch != shown.binding.epoch
            || self.version != shown.version
        {
            return Ok(false);
        }
        let (kit, ciphertext) = self.retained()?;
        let matching = match &shown.material {
            PresentationMaterial::Retained {
                kit: other,
                ciphertext: cipher,
            } => {
                kit.encode_secret_qr()? == other.encode_secret_qr()?
                    && ciphertext == cipher.as_slice()
            }
            PresentationMaterial::Verification {
                ciphertext_hash,
                kit_hash,
                authority,
            } => {
                let bundle = bootstrap::open_recovery(ciphertext, kit)?;
                *ciphertext_hash == <[u8; 32]>::from(Sha256::digest(ciphertext))
                    && *kit_hash
                        == <[u8; 32]>::from(Sha256::digest(kit.encode_secret_qr()?.as_slice()))
                    && *authority == Authority::new(&bundle, &self.binding.context()?).public_key()
            }
        };
        if matching {
            self.confirm_saved()?;
        }
        Ok(matching)
    }
    fn validate(&self) -> Result<()> {
        if self.version == 0 || self.version > i64::MAX as u64 || self.status == KitStatus::None {
            return Err(Failure::InvalidState);
        }
        match &self.material {
            PresentationMaterial::Retained { kit, ciphertext } => {
                if self.status == KitStatus::VerifiedCurrent {
                    return Err(Failure::InvalidState);
                }
                validate_kit(kit, &self.binding)?;
                bootstrap::open_recovery(ciphertext, kit)?;
            }
            PresentationMaterial::Verification { .. } => {
                if self.status == KitStatus::AwaitingPresentation {
                    return Err(Failure::InvalidState);
                }
            }
        }
        Ok(())
    }
    fn status(&self) -> KitStatus {
        self.status
    }
}
struct Archive {
    generation: i64,
    pending: Option<Pending>,
    presentation: Option<Presentation>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
    needs_upgrade: bool,
}
impl Archive {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let snapshot = owner.read(Slot::Bootstrap)?;
        Self::from_snapshot(snapshot)
    }
    fn from_snapshot(snapshot: Option<Zeroizing<Vec<u8>>>) -> Result<Self> {
        let (generation, pending, presentation, needs_upgrade) = if let Some(bytes) = &snapshot {
            let value = canonical::parse(bytes)?;
            let v = exact(&value, &["schema", "generation", "pending", "presentation"])?;
            let generation = v["generation"].as_int()?;
            let schema = v["schema"].as_int()?;
            if !matches!(schema, 1 | 2) || generation < 1 {
                return Err(Failure::InvalidState);
            }
            (
                generation,
                optional(&v["pending"], Pending::parse)?,
                optional(
                    &v["presentation"],
                    if schema == 1 {
                        Presentation::parse_legacy
                    } else {
                        Presentation::parse
                    },
                )?,
                schema == 1,
            )
        } else {
            (0, None, None, false)
        };
        let archive = Self {
            generation,
            pending,
            presentation,
            snapshot,
            needs_upgrade,
        };
        archive.validate()?;
        Ok(archive)
    }
    fn validate(&self) -> Result<()> {
        if let Some(p) = &self.pending {
            p.validate()?;
        }
        if let Some(p) = &self.presentation {
            p.validate()?;
            if let Some(pending) = &self.pending
                && (p.binding != pending.binding || !p.matches_bundle(&pending.bundle)?)
            {
                return Err(Failure::KeyConflict);
            }
        }
        Ok(())
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        self.validate()?;
        let next = self
            .generation
            .checked_add(1)
            .ok_or(Failure::InvalidState)?;
        let value = object([
            ("schema", Value::Int(2)),
            ("generation", Value::Int(next)),
            (
                "pending",
                self.pending
                    .as_ref()
                    .map(Pending::value)
                    .transpose()?
                    .unwrap_or(Value::Null),
            ),
            (
                "presentation",
                self.presentation
                    .as_ref()
                    .map(Presentation::value)
                    .transpose()?
                    .unwrap_or(Value::Null),
            ),
        ]);
        let bytes = value.encode()?;
        owner.replace(
            Slot::Bootstrap,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation = next;
        self.needs_upgrade = false;
        Ok(())
    }
    fn check_binding(&self, binding: &KeyBinding) -> Result<()> {
        if self.pending.as_ref().is_some_and(|p| &p.binding != binding)
            || self
                .presentation
                .as_ref()
                .is_some_and(|p| &p.binding != binding)
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
    fn outcome(&self) -> Outcome {
        Outcome::Ready {
            kit: self
                .presentation
                .as_ref()
                .map_or(KitStatus::None, Presentation::status),
        }
    }
}

struct Evidence {
    version: u64,
    ciphertext: Vec<u8>,
}
trait Remote {
    fn preflight(&mut self) -> Result<()>;
    fn binding(&self) -> Result<KeyBinding>;
    fn role(&self) -> Role;
    fn authority(&mut self) -> Result<Option<[u8; 32]>>;
    fn recovery(&mut self) -> Result<Option<Evidence>>;
    fn has_records(&mut self) -> Result<bool>;
    fn bootstrap(&mut self, public: &[u8; 32], ciphertext: &[u8]) -> Result<Evidence>;
}
impl Remote for BoundTransport {
    fn preflight(&mut self) -> Result<()> {
        Ok(BoundTransport::preflight(self)?)
    }
    fn binding(&self) -> Result<KeyBinding> {
        Ok(self.key_binding()?)
    }
    fn role(&self) -> Role {
        self.key_role()
    }
    fn authority(&mut self) -> Result<Option<[u8; 32]>> {
        Ok(self.key_authority()?.public_key().copied())
    }
    fn recovery(&mut self) -> Result<Option<Evidence>> {
        Ok(self.recovery_state()?.recovery().map(|v| Evidence {
            version: v.version(),
            ciphertext: v.ciphertext().into(),
        }))
    }
    fn has_records(&mut self) -> Result<bool> {
        let page = self.fetch_page(None)?;
        Ok(!page.records.is_empty() || page.has_more)
    }
    fn bootstrap(&mut self, public: &[u8; 32], ciphertext: &[u8]) -> Result<Evidence> {
        let v = self.bootstrap_library_key(public, ciphertext)?;
        Ok(Evidence {
            version: v.version(),
            ciphertext: v.ciphertext().into(),
        })
    }
}
fn check_remote(remote: &impl Remote, binding: &KeyBinding) -> Result<()> {
    if remote.binding()? != *binding {
        return Err(Failure::ReviewRequired);
    }
    Ok(())
}
fn read_installed<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<Option<Installed>> {
    let installed = owner
        .read(Slot::LibraryKey)?
        .as_deref()
        .map(|b| Installed::decode(b))
        .transpose()?;
    if installed.as_ref().is_some_and(|v| &v.binding != binding) {
        return Err(Failure::ReviewRequired);
    }
    Ok(installed)
}
/// Metadata-only creation may retain a separate server library beside these
/// capabilities. It never adopts a key, reads primary records or admits sync.
pub(crate) fn creation_source_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> Result<Option<KeyBinding>> {
    handover::require_idle(owner)?;
    crate::primary::require_ready(owner.root())?;
    crate::backup::import::require_clear(owner.root()).map_err(|_| Failure::ReviewRequired)?;
    let Some(bytes) = owner.read(Slot::LibraryKey)? else {
        for slot in [
            Slot::Bootstrap,
            Slot::PairingRecipient,
            Slot::CheckpointKey,
            Slot::KeyMutation,
        ] {
            if owner.read(slot)?.is_some() {
                return Err(Failure::ReviewRequired);
            }
        }
        owner.require_checkpoint_absent()?;
        return Ok(None);
    };
    let installed = Installed::decode(&bytes)?;
    let archive = Archive::load(owner)?;
    archive.check_binding(&installed.binding)?;
    validate_presentation(&archive, &installed)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    recipient::require_idle(owner, &installed.binding)?;
    mutations::require_idle(owner, &installed.binding)?;
    Ok(Some(installed.binding))
}
pub(crate) fn installed_binding_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> Result<Option<KeyBinding>> {
    owner
        .read(Slot::LibraryKey)?
        .as_deref()
        .map(|bytes| Installed::decode(bytes))
        .transpose()
        .map(|installed| installed.map(|installed| installed.binding))
}

/// Opening an already-created library is read-only control-plane work. An
/// initial key draft may resume through that exact target, without making it
/// usable or allowing creation of another library beside unfinished setup.
pub(crate) fn creation_open_source_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    target: &KeyBinding,
) -> Result<Option<KeyBinding>> {
    match creation_source_locked(owner) {
        Ok(source) => return Ok(source),
        Err(Failure::ReviewRequired) => (),
        Err(error) => return Err(error),
    }
    handover::require_idle(owner)?;
    crate::primary::require_ready(owner.root())?;
    crate::backup::import::require_clear(owner.root()).map_err(|_| Failure::ReviewRequired)?;
    if owner.read(Slot::LibraryKey)?.is_some() {
        return Err(Failure::ReviewRequired);
    }
    let archive = Archive::load(owner)?;
    archive.check_binding(target)?;
    let pending = archive.pending.as_ref().ok_or(Failure::ReviewRequired)?;
    if pending.kind != Kind::Initial || pending.binding != *target || archive.presentation.is_some()
    {
        return Err(Failure::ReviewRequired);
    }
    for slot in [
        Slot::PairingRecipient,
        Slot::CheckpointKey,
        Slot::KeyMutation,
    ] {
        if owner.read(slot)?.is_some() {
            return Err(Failure::ReviewRequired);
        }
    }
    owner.require_checkpoint_absent()?;
    Ok(None)
}
/// Control-plane admission checks only. A different account/library cannot use
/// retained key or pairing state; checkpoint review does not prevent recovery
/// presentation. No primary records, cursors or checkpoint material are read.
pub fn check_admission<B: Backend>(store: &mut Store<B>, binding: &KeyBinding) -> Result<()> {
    store.transaction_with(|owner| check_admission_locked(owner, binding))
}
pub(crate) fn check_admission_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<()> {
    handover::require_idle(owner)?;
    mutations::check_admission(owner, binding)?;
    crate::auth_store::creation::check_target(owner, binding)?;
    let archive = Archive::load(owner)?;
    archive.check_binding(binding)?;
    recipient::check_admission(owner, binding)?;
    if let Some(installed) = read_installed(owner, binding)? {
        validate_presentation(&archive, &installed)?;
    }
    Ok(())
}
fn validate_presentation(archive: &Archive, installed: &Installed) -> Result<()> {
    if let Some(p) = &archive.presentation
        && (p.binding != installed.binding || !p.matches_bundle(&installed.bundle)?)
    {
        return Err(Failure::KeyConflict);
    }
    Ok(())
}
fn verify_remote(remote: &mut impl Remote, binding: &KeyBinding, bundle: &Bundle) -> Result<()> {
    let public = Authority::new(bundle, &binding.context()?).public_key();
    let actual = remote.authority()?;
    check_remote(remote, binding)?;
    if actual != Some(public) {
        return Err(Failure::KeyConflict);
    }
    Ok(())
}

/// Explicit onboarding only. A pending candidate is resumed before any key can
/// be generated. The independent secret mutex spans the entire HTTP transaction.
pub fn initialize<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
) -> Result<Outcome> {
    store.transaction_with(|owner| initialize_locked(owner, remote))
}
fn initialize_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    remote.preflight()?;
    let binding = remote.binding()?;
    recipient::require_idle(owner, &binding)?;
    mutations::require_idle(owner, &binding)?;
    let mut archive = Archive::load(owner)?;
    archive.check_binding(&binding)?;
    let installed = read_installed(owner, &binding)?;
    if archive.pending.is_some() {
        return resume_locked(owner, remote, archive);
    }
    if let Some(installed) = installed {
        owner.check_checkpoint_scope(binding.checkpoint_scope(), true)?;
        verify_remote(remote, &binding, &installed.bundle)?;
        validate_presentation(&archive, &installed)?;
        refresh_presentation(owner, remote, &mut archive, &binding)?;
        return Ok(archive.outcome());
    }
    if archive.presentation.is_some() {
        return Err(Failure::KeyConflict);
    }
    owner.check_checkpoint_scope(binding.checkpoint_scope(), false)?;
    let authority = remote.authority()?;
    check_remote(remote, &binding)?;
    let recovery = remote.recovery()?;
    check_remote(remote, &binding)?;
    let records = remote.has_records()?;
    check_remote(remote, &binding)?;
    if authority.is_some() || recovery.is_some() || records || remote.role() != Role::Owner {
        return Ok(Outcome::NeedsTrustedDeviceOrRecovery);
    }
    let bundle = Bundle::generate()?;
    let envelope = bootstrap::create_recovery(
        &bundle,
        binding.server.clone(),
        binding.space,
        binding.epoch as i64,
    )?;
    archive.pending = Some(Pending {
        kind: Kind::Initial,
        binding,
        bundle,
        kit: envelope.kit,
        version: 1,
        ciphertext: envelope.ciphertext,
    });
    archive.save(owner)?;
    resume_locked(owner, remote, archive)
}

/// Verifies possession through recovery AEAD and immutable authority, then
/// journals the recovered material before installation. Existing keys are never
/// replaced; a wrong or foreign kit changes no local state.
pub fn recover<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    kit: RecoveryKit,
) -> Result<Outcome> {
    store.transaction_with(|owner| recover_locked(owner, remote, kit))
}
fn recover_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    kit: RecoveryKit,
) -> Result<Outcome> {
    remote.preflight()?;
    let binding = remote.binding()?;
    validate_kit(&kit, &binding)?;
    recipient::require_idle(owner, &binding)?;
    mutations::require_idle(owner, &binding)?;
    let mut archive = Archive::load(owner)?;
    archive.check_binding(&binding)?;
    let installed = read_installed(owner, &binding)?;
    owner.check_checkpoint_scope(binding.checkpoint_scope(), true)?;
    let evidence = remote.recovery()?;
    check_remote(remote, &binding)?;
    let evidence = evidence.ok_or(Failure::RecoveryUnavailable)?;
    let bundle = bootstrap::open_recovery(&evidence.ciphertext, &kit)?;
    verify_remote(remote, &binding, &bundle)?;
    if let Some(installed) = &installed {
        if installed.bundle.for_secure_storage() != bundle.for_secure_storage() {
            return Err(Failure::KeyConflict);
        }
        validate_presentation(&archive, installed)?;
    }
    if let Some(p) = &archive.presentation
        && !p.matches_bundle(&bundle)?
    {
        return Err(Failure::KeyConflict);
    }
    if let Some(pending) = &archive.pending
        && pending.bundle.for_secure_storage() != bundle.for_secure_storage()
        && (pending.kind == Kind::Recovery || installed.is_some())
    {
        return Err(Failure::Busy);
    }
    // A different immutable authority proves an initial candidate never won.
    // No installed key or checkpoint is removed when this candidate is retired.
    archive.pending = Some(Pending {
        kind: Kind::Recovery,
        binding,
        bundle,
        kit,
        version: evidence.version,
        ciphertext: evidence.ciphertext,
    });
    archive.save(owner)?;
    resume_locked(owner, remote, archive)
}

fn refresh_presentation<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    archive: &mut Archive,
    binding: &KeyBinding,
) -> Result<()> {
    let Some(p) = &archive.presentation else {
        if archive.needs_upgrade {
            archive.save(owner)?;
        }
        return Ok(());
    };
    let current = remote.recovery()?;
    check_remote(remote, binding)?;
    if !current.as_ref().is_some_and(|v| p.matches_evidence(v)) && p.status != KitStatus::Replaced {
        archive
            .presentation
            .as_mut()
            .ok_or(Failure::InvalidState)?
            .status = KitStatus::Replaced;
        archive.save(owner)?;
    }
    if archive.needs_upgrade {
        archive.save(owner)?;
    }
    Ok(())
}

fn resume_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    mut archive: Archive,
) -> Result<Outcome> {
    let pending = archive.pending.as_ref().ok_or(Failure::InvalidState)?;
    check_remote(remote, &pending.binding)?;
    pending.validate()?;
    owner.check_checkpoint_scope(
        pending.binding.checkpoint_scope(),
        pending.kind == Kind::Recovery,
    )?;
    let public = Authority::new(&pending.bundle, &pending.binding.context()?).public_key();
    let mut actual = remote.authority()?;
    check_remote(remote, &pending.binding)?;
    if actual.is_none() && pending.kind == Kind::Initial {
        let current = remote.recovery()?;
        check_remote(remote, &pending.binding)?;
        let records = remote.has_records()?;
        check_remote(remote, &pending.binding)?;
        if current.is_some() || records {
            return Err(Failure::KeyConflict);
        }
        let _receipt = remote.bootstrap(&public, &pending.ciphertext)?;
        check_remote(remote, &pending.binding)?;
        actual = remote.authority()?;
        check_remote(remote, &pending.binding)?;
    }
    if actual != Some(public) {
        if actual.is_some()
            && pending.kind == Kind::Initial
            && read_installed(owner, &pending.binding)?.is_none()
        {
            archive.pending = None;
            archive.save(owner)?;
            return Ok(Outcome::NeedsTrustedDeviceOrRecovery);
        }
        return Err(Failure::KeyConflict);
    }
    let current = remote.recovery()?;
    check_remote(remote, &pending.binding)?;
    let same_recovery = current
        .as_ref()
        .is_some_and(|v| v.version == pending.version && v.ciphertext == pending.ciphertext);
    let installed = read_installed(owner, &pending.binding)?;
    if let Some(installed) = installed {
        if installed.bundle.for_secure_storage() != pending.bundle.for_secure_storage() {
            return Err(Failure::KeyConflict);
        }
    } else {
        owner.check_checkpoint_scope(
            pending.binding.checkpoint_scope(),
            pending.kind == Kind::Recovery,
        )?;
        let bytes = Installed {
            binding: pending.binding.clone(),
            bundle: Bundle::from_material(pending.bundle.for_secure_storage())?,
        }
        .value()?
        .encode()?;
        owner.replace(Slot::LibraryKey, None, Some(&bytes))?;
    }
    let material = if pending.kind == Kind::Initial {
        PresentationMaterial::Retained {
            kit: RecoveryKit::decode_secret_qr(&pending.kit.encode_secret_qr()?)?,
            ciphertext: pending.ciphertext.clone(),
        }
    } else {
        Presentation::verification_material(
            &pending.binding,
            &pending.kit,
            &pending.ciphertext,
            &pending.bundle,
        )?
    };
    archive.presentation = Some(Presentation {
        binding: pending.binding.clone(),
        version: pending.version,
        material,
        status: if !same_recovery {
            KitStatus::Replaced
        } else if pending.kind == Kind::Initial {
            KitStatus::AwaitingPresentation
        } else {
            KitStatus::VerifiedCurrent
        },
    });
    // Persist the initial recovery capability or verification metadata before
    // retiring the redo source. Authenticated recovery input is not retained.
    archive.save(owner)?;
    archive.pending = None;
    archive.save(owner)?;
    Ok(archive.outcome())
}

/// A locally installed key becomes usable only after a fresh scope preflight and
/// remote authority match. An unfinished journal cannot expose a half-installed key.
pub fn load_verified<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
) -> Result<Option<VerifiedKey>> {
    load_verified_checked(store, remote, &|| Ok(()))
}
pub fn load_verified_checked<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    check: &dyn Fn() -> Result<()>,
) -> Result<Option<VerifiedKey>> {
    store.transaction_with(|owner| load_locked_checked(owner, remote, check))
}
fn load_locked_checked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    check: &dyn Fn() -> Result<()>,
) -> Result<Option<VerifiedKey>> {
    check()?;
    let result = load_locked(owner, &mut CheckedRemote { remote, check })?;
    check()?;
    Ok(result)
}
struct CheckedRemote<'a, R> {
    remote: &'a mut R,
    check: &'a dyn Fn() -> Result<()>,
}
impl<R: Remote> CheckedRemote<'_, R> {
    fn call<T>(&mut self, operation: impl FnOnce(&mut R) -> Result<T>) -> Result<T> {
        (self.check)()?;
        let result = operation(self.remote)?;
        (self.check)()?;
        Ok(result)
    }
}
impl<R: Remote> Remote for CheckedRemote<'_, R> {
    fn preflight(&mut self) -> Result<()> {
        self.call(Remote::preflight)
    }
    fn binding(&self) -> Result<KeyBinding> {
        (self.check)()?;
        self.remote.binding()
    }
    fn role(&self) -> Role {
        self.remote.role()
    }
    fn authority(&mut self) -> Result<Option<[u8; 32]>> {
        self.call(Remote::authority)
    }
    fn recovery(&mut self) -> Result<Option<Evidence>> {
        self.call(Remote::recovery)
    }
    fn has_records(&mut self) -> Result<bool> {
        self.call(Remote::has_records)
    }
    fn bootstrap(&mut self, public: &[u8; 32], ciphertext: &[u8]) -> Result<Evidence> {
        self.call(|remote| remote.bootstrap(public, ciphertext))
    }
}
fn load_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Option<VerifiedKey>> {
    remote.preflight()?;
    let binding = remote.binding()?;
    recipient::require_idle(owner, &binding)?;
    mutations::require_idle(owner, &binding)?;
    let mut archive = Archive::load(owner)?;
    archive.check_binding(&binding)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    let Some(installed) = read_installed(owner, &binding)? else {
        if archive.presentation.is_some() {
            return Err(Failure::KeyConflict);
        }
        return Ok(None);
    };
    owner.check_checkpoint_scope(binding.checkpoint_scope(), true)?;
    verify_remote(remote, &binding, &installed.bundle)?;
    validate_presentation(&archive, &installed)?;
    if archive.needs_upgrade {
        archive.save(owner)?;
    }
    Ok(Some(VerifiedKey {
        binding,
        bundle: installed.bundle,
    }))
}

fn validate_kit(kit: &RecoveryKit, binding: &KeyBinding) -> Result<()> {
    if kit.server() != &binding.server
        || kit.space() != binding.space
        || kit.epoch() != binding.epoch as i64
    {
        return Err(Failure::ReviewRequired);
    }
    Ok(())
}
fn uuid(text: &str) -> Result<Uuid> {
    let v = Uuid::parse_str(text).map_err(|_| Failure::InvalidState)?;
    if v.is_nil() || v.to_string() != text {
        return Err(Failure::InvalidState);
    }
    Ok(v)
}
fn decode64(text: &str, limit: usize) -> Result<Zeroizing<Vec<u8>>> {
    if text.is_empty() || text.len() > limit.div_ceil(3) * 4 {
        return Err(Failure::InvalidState);
    }
    let mut bytes = Zeroizing::new(Vec::with_capacity(limit + 3));
    STANDARD
        .decode_vec(text, &mut bytes)
        .map_err(|_| Failure::InvalidState)?;
    if bytes.len() > limit || Zeroizing::new(STANDARD.encode(&*bytes)).as_str() != text {
        return Err(Failure::InvalidState);
    }
    Ok(bytes)
}
fn array<const N: usize>(text: &str) -> Result<[u8; N]> {
    decode64(text, N)?
        .as_slice()
        .try_into()
        .map_err(|_| Failure::InvalidState)
}
fn exact<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a BTreeMap<String, Value>> {
    let v = value.as_object()?;
    if v.len() != keys.len() || !keys.iter().all(|k| v.contains_key(*k)) {
        return Err(Failure::InvalidState);
    }
    Ok(v)
}
fn optional<T>(v: &Value, parse: impl FnOnce(&Value) -> Result<T>) -> Result<Option<T>> {
    if matches!(v, Value::Null) {
        Ok(None)
    } else {
        parse(v).map(Some)
    }
}
fn object<const N: usize>(v: [(&str, Value); N]) -> Value {
    Value::Object(v.into_iter().map(|(k, v)| (k.into(), v)).collect())
}

#[cfg(test)]
#[path = "key_store_tests.rs"]
mod tests;
