//! Cross-platform encrypted snippets-wire-v1 records. Vault ciphertext remains
//! ciphertext inside this independent sync-key layer; it is never decrypted here.
use crate::{
    canonical::{self, Value},
    clock::Hlc,
    crypto::{self, RootKey},
    model::{Error, Result, Snippet},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use uuid::Uuid;
use zeroize::Zeroizing;

const INVALID: Error = Error("The encrypted synchronization record could not be verified.");
pub const MAX_BLOB_BYTES: usize = 900_000;
const KEYS: &[&str] = &[
    "schemaVersion",
    "id",
    "hlc",
    "origin",
    "secure",
    "deleted",
    "hash",
    "contentHash",
    "fields",
    "x",
];
const FIELD_KEYS: &[&str] = &[
    "name",
    "keyword",
    "content",
    "tags",
    "isEnabled",
    "isPinned",
    "createdAt",
    "updatedAt",
];
pub fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn exact_keys(values: &BTreeMap<String, Value>, keys: &[&str]) -> Result<()> {
    if values.len() == keys.len() && keys.iter().all(|key| values.contains_key(*key)) {
        Ok(())
    } else {
        Err(INVALID)
    }
}
fn get<'a>(values: &'a BTreeMap<String, Value>, key: &str) -> Result<&'a Value> {
    values.get(key).ok_or(INVALID)
}
pub(crate) fn device(text: &str) -> bool {
    text.len() == 8
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn is_hash(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[derive(Clone, PartialEq)]
pub struct Fields {
    pub name: String,
    pub keyword: String,
    pub content: Zeroizing<Vec<u8>>,
    pub tags: Vec<String>,
    pub is_enabled: bool,
    pub is_pinned: bool,
    pub created_at: f64,
    pub updated_at: f64,
}
impl Fields {
    pub fn from_snippet(snippet: &Snippet) -> Self {
        Self {
            name: snippet.name.clone(),
            keyword: snippet.keyword.clone(),
            content: Zeroizing::new(snippet.content.as_bytes().to_vec()),
            tags: snippet.tags.clone(),
            is_enabled: snippet.is_enabled,
            is_pinned: snippet.is_pinned,
            created_at: snippet.created_at,
            updated_at: snippet.updated_at,
        }
    }
    pub(crate) fn value(&self) -> Result<Value> {
        if !self.created_at.is_finite() || !self.updated_at.is_finite() {
            return Err(INVALID);
        }
        Ok(Value::Object(BTreeMap::from([
            ("name".into(), Value::text(self.name.clone())),
            ("keyword".into(), Value::text(self.keyword.clone())),
            (
                "content".into(),
                Value::text(std::str::from_utf8(&self.content).map_err(|_| INVALID)?),
            ),
            (
                "tags".into(),
                Value::Array(self.tags.iter().map(|t| Value::text(t.clone())).collect()),
            ),
            ("isEnabled".into(), Value::Bool(self.is_enabled)),
            ("isPinned".into(), Value::Bool(self.is_pinned)),
            ("createdAt".into(), Value::Float(self.created_at)),
            ("updatedAt".into(), Value::Float(self.updated_at)),
        ])))
    }
    pub(crate) fn parse(value: &Value) -> Result<Self> {
        let values = value.as_object()?;
        exact_keys(values, FIELD_KEYS)?;
        Ok(Self {
            name: get(values, "name")?.as_text()?.into(),
            keyword: get(values, "keyword")?.as_text()?.into(),
            content: Zeroizing::new(get(values, "content")?.as_text()?.as_bytes().to_vec()),
            tags: get(values, "tags")?
                .as_array()?
                .iter()
                .map(|v| v.as_text().map(String::from))
                .collect::<Result<_>>()?,
            is_enabled: get(values, "isEnabled")?.as_bool()?,
            is_pinned: get(values, "isPinned")?.as_bool()?,
            created_at: get(values, "createdAt")?.as_float()?,
            updated_at: get(values, "updatedAt")?.as_float()?,
        })
    }
}
#[derive(Clone, PartialEq)]
pub struct Envelope {
    pub id: Uuid,
    pub hlc: Hlc,
    pub origin: String,
    pub secure: bool,
    pub deleted: bool,
    pub fields: Option<Fields>,
    pub extensions: BTreeMap<String, Value>,
}
impl Envelope {
    fn value(&self, including_hash: bool) -> Result<Value> {
        if !device(&self.origin) || self.deleted != self.fields.is_none() {
            return Err(INVALID);
        }
        self.validate_deletion()?;
        let content_hash = self
            .fields
            .as_ref()
            .map(|f| Value::text(sha256(&f.content)))
            .unwrap_or(Value::Null);
        let mut values = BTreeMap::from([
            ("schemaVersion".into(), Value::Int(1)),
            ("id".into(), Value::text(self.id.to_string())),
            ("hlc".into(), Value::text(self.hlc.text())),
            ("origin".into(), Value::text(self.origin.clone())),
            ("secure".into(), Value::Bool(self.secure)),
            ("deleted".into(), Value::Bool(self.deleted)),
            ("contentHash".into(), content_hash),
            (
                "fields".into(),
                self.fields
                    .as_ref()
                    .map(Fields::value)
                    .transpose()?
                    .unwrap_or(Value::Null),
            ),
            ("x".into(), Value::Object(self.extensions.clone())),
        ]);
        if including_hash {
            values.insert("hash".into(), Value::text(self.hash()?));
        }
        Ok(Value::Object(values))
    }
    pub fn hash(&self) -> Result<String> {
        Ok(sha256(&self.value(false)?.encode()?))
    }
    pub fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        self.value(true)?.encode()
    }
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let value = canonical::parse(bytes)?;
        let values = value.as_object()?;
        let version = get(values, "schemaVersion")?.as_int()?;
        if version != 1 {
            return Err(Error(
                "This synchronization record needs a newer or different app version.",
            ));
        }
        exact_keys(values, KEYS)?;
        let deleted = get(values, "deleted")?.as_bool()?;
        let fields = match get(values, "fields")? {
            Value::Null => None,
            value => Some(Fields::parse(value)?),
        };
        let envelope = Self {
            id: Uuid::parse_str(get(values, "id")?.as_text()?).map_err(|_| INVALID)?,
            hlc: Hlc::parse(get(values, "hlc")?.as_text()?)?,
            origin: get(values, "origin")?.as_text()?.into(),
            secure: get(values, "secure")?.as_bool()?,
            deleted,
            fields,
            extensions: get(values, "x")?.as_object()?.clone(),
        };
        if get(values, "hash")?.as_text()? != envelope.hash()? {
            return Err(INVALID);
        }
        match (&envelope.fields, get(values, "contentHash")?) {
            (None, Value::Null) => (),
            (Some(fields), value) if value.as_text()? == sha256(&fields.content) => (),
            _ => return Err(INVALID),
        }
        Ok(envelope)
    }
    fn validate_deletion(&self) -> Result<()> {
        if let Some(value) = self.extensions.get("userDeletion.v1") {
            let hashes = value.as_array()?;
            if !self.deleted || !(1..=8).contains(&hashes.len()) {
                return Err(INVALID);
            }
            let mut seen = std::collections::HashSet::new();
            for value in hashes {
                let text = value.as_text()?;
                if !is_hash(text) || !seen.insert(text) {
                    return Err(INVALID);
                }
            }
        }
        Ok(())
    }
    pub fn plain(snippet: &Snippet, hlc: Hlc, origin: String) -> Result<Self> {
        let envelope = Self {
            id: snippet.id,
            hlc,
            origin,
            secure: false,
            deleted: false,
            fields: Some(Fields::from_snippet(snippet)),
            extensions: BTreeMap::new(),
        };
        envelope.encode()?;
        Ok(envelope)
    }
    pub fn tombstone(&self, hlc: Hlc, origin: String, explicit: bool) -> Result<Self> {
        if crate::merge::has_unresolved(Some(self)) {
            return Err(Error(
                "Preserve the unresolved content conflicts before deleting this record.",
            ));
        }
        // The Swift contract discards extensions that could carry old content;
        // a secure tombstone retains only its vault routing identity.
        let mut extensions = BTreeMap::new();
        if self.secure
            && let Some(kid) = self.extensions.get("vaultKID")
        {
            extensions.insert("vaultKID".into(), kid.clone());
        }
        if explicit {
            extensions.insert(
                "userDeletion.v1".into(),
                Value::Array(vec![Value::text(self.hash()?)]),
            );
        } else {
            extensions.remove("userDeletion.v1");
        }
        let envelope = Self {
            id: self.id,
            hlc,
            origin,
            secure: self.secure,
            deleted: true,
            fields: None,
            extensions,
        };
        envelope.encode()?;
        Ok(envelope)
    }
    pub fn snippet(&self) -> Result<Option<Snippet>> {
        if self.secure || self.deleted {
            return Ok(None);
        }
        let fields = self.fields.as_ref().ok_or(INVALID)?;
        Ok(Some(
            Snippet {
                id: self.id,
                name: fields.name.clone(),
                keyword: fields.keyword.clone(),
                content: std::str::from_utf8(&fields.content)
                    .map_err(|_| INVALID)?
                    .into(),
                tags: fields.tags.clone(),
                is_enabled: fields.is_enabled,
                is_pinned: fields.is_pinned,
                created_at: fields.created_at,
                updated_at: fields.updated_at,
            }
            .validate()?,
        ))
    }
}

pub(crate) mod blob_base64 {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        bytes: &[u8],
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&STANDARD.encode(bytes))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        if text.len() > 1_200_000 {
            return Err(serde::de::Error::custom("Blob too large"));
        }
        let bytes = STANDARD
            .decode(text)
            .map_err(|_| serde::de::Error::custom("Invalid canonical Base64"))?;
        if bytes.is_empty() || bytes.len() > MAX_BLOB_BYTES {
            return Err(serde::de::Error::custom("Blob too large"));
        }
        Ok(bytes)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireRecord {
    pub id: Uuid,
    pub rev: String,
    pub deleted: bool,
    #[serde(with = "blob_base64")]
    pub blob: Vec<u8>,
}
impl WireRecord {
    pub fn validate(&self) -> Result<()> {
        if self.rev.is_empty()
            || self.rev.len() > 256
            || self.rev.contains('\0')
            || self.blob.is_empty()
            || self.blob.len() > MAX_BLOB_BYTES
        {
            Err(INVALID)
        } else {
            Ok(())
        }
    }
    pub fn seal(envelope: &Envelope, root: &RootKey, salt: &[u8; 32]) -> Result<Self> {
        let value = Self {
            id: envelope.id,
            rev: envelope.hash()?[..32].into(),
            deleted: envelope.deleted,
            blob: crypto::seal_wire(
                &envelope.encode()?,
                root,
                salt,
                envelope.id,
                envelope.deleted,
            )?,
        };
        value.validate()?;
        Ok(value)
    }
    pub fn open(&self, root: &RootKey, salt: &[u8; 32]) -> Result<Envelope> {
        self.validate()?;
        let bytes = crypto::open_wire(&self.blob, root, salt, self.id, self.deleted)?;
        let envelope = Envelope::parse(&bytes)?;
        if envelope.id != self.id
            || envelope.deleted != self.deleted
            || self.rev != envelope.hash()?[..32]
        {
            return Err(INVALID);
        }
        Ok(envelope)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn envelope() -> Envelope {
        let mut snippet = Snippet::new("Public fixture", "Fictional 🦀\n");
        snippet.id = Uuid::from_u128(1);
        snippet.created_at = -0.0;
        snippet.updated_at = 812_578_800.123456;
        Envelope::plain(
            &snippet,
            Hlc::parse("019f1a3d4880-0000-1234abcd").unwrap(),
            "1234abcd".into(),
        )
        .unwrap()
    }
    #[test]
    fn ciphertext_authenticates_identity_revision_deletion_and_key_without_exposing_vault() {
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let salt = [0x22; 32];
        let envelope = envelope();
        let wire = WireRecord::seal(&envelope, &root, &salt).unwrap();
        let opened = wire.open(&root, &salt).unwrap();
        assert!(opened.encode().unwrap() == envelope.encode().unwrap());
        assert!(opened.fields.unwrap().created_at.to_bits() == (-0.0_f64).to_bits());
        for which in 0..4 {
            let mut changed = wire.clone();
            match which {
                0 => changed.id = Uuid::from_u128(2),
                1 => changed.rev = "f".repeat(32),
                2 => changed.deleted = true,
                _ => {
                    let last = changed.blob.len() - 2;
                    changed.blob[last] ^= 1;
                }
            }
            assert!(changed.open(&root, &salt).is_err());
        }
        assert!(
            wire.open(&RootKey::from_bytes(&[0x33; 32]).unwrap(), &salt)
                .is_err()
        );
        assert!(wire.open(&root, &[0x44; 32]).is_err());
    }
    #[test]
    fn deletion_removes_fields_and_hash_and_unknown_extensions_round_trip() {
        let mut envelope = envelope();
        envelope.extensions.insert(
            "future".into(),
            canonical::parse(r#"{"v":[1,1.0,"é"]}"#.as_bytes()).unwrap(),
        );
        let bytes = envelope.encode().unwrap();
        assert!(Envelope::parse(&bytes).unwrap().encode().unwrap() == bytes);
        let deleted = envelope
            .tombstone(envelope.hlc.clone(), "1234abcd".into(), true)
            .unwrap();
        let bytes = deleted.encode().unwrap();
        let value = canonical::parse(&bytes).unwrap();
        let object = value.as_object().unwrap();
        assert!(
            matches!(object.get("fields"), Some(Value::Null))
                && matches!(object.get("contentHash"), Some(Value::Null))
        );
        assert!(Envelope::parse(&bytes).unwrap().deleted);
        let mut bad = deleted.clone();
        bad.fields = envelope.fields.clone();
        assert!(bad.encode().is_err());
        let mut value = value.as_object().unwrap().clone();
        value.insert("unexpected".into(), Value::Bool(true));
        assert!(Envelope::parse(&Value::Object(value).encode().unwrap()).is_err());
    }
    #[test]
    fn wire_budget_supports_secure_ciphertext_and_rejects_the_next_padding_block() {
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let salt = [0x22; 32];
        let id = Uuid::from_u128(1);
        let bytes = vec![b'x'; crypto::MAX_WIRE_PLAINTEXT];
        let sealed = crypto::seal_wire(&bytes, &root, &salt, id, false).unwrap();
        assert!(sealed.len() == 899_796);
        assert!(*crypto::open_wire(&sealed, &root, &salt, id, false).unwrap() == bytes);
        assert!(
            crypto::seal_wire(
                &vec![b'x'; crypto::MAX_WIRE_PLAINTEXT + 1],
                &root,
                &salt,
                id,
                false
            )
            .is_err()
        );
        let vault =
            crypto::seal_record(b"Fictional secret", &root, &salt, "public-vault", id, false)
                .unwrap();
        assert!(crypto::open_wire(vault.text().as_bytes(), &root, &salt, id, false).is_err());
    }
    #[test]
    fn independent_openssl_and_swift_formatter_fixture_matches_both_layers() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/sync-wire-v1.json")).unwrap();
        let root = RootKey::from_bytes(&[0x99; 32]).unwrap();
        let salt = [0xaa; 32];
        for record in fixture["records"].as_array().unwrap() {
            let wire: WireRecord = serde_json::from_value(record["wire"].clone()).unwrap();
            let envelope = wire.open(&root, &salt).unwrap();
            assert!(
                envelope.encode().unwrap().as_slice()
                    == record["canonical"].as_str().unwrap().as_bytes()
            );
            assert!(envelope.hash().unwrap() == record["hash"].as_str().unwrap());
            if envelope.secure {
                assert!(envelope.snippet().unwrap().is_none());
                let vault: serde_json::Value =
                    serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
                assert!(
                    envelope.fields.as_ref().unwrap().content.as_slice()
                        == vault["document"]["records"][0]["sealed"]
                            .as_str()
                            .unwrap()
                            .as_bytes()
                );
                let sealed = crypto::Sealed::parse(
                    std::str::from_utf8(&envelope.fields.as_ref().unwrap().content)
                        .unwrap()
                        .into(),
                )
                .unwrap();
                let body = crypto::open_record(
                    &sealed,
                    &RootKey::from_bytes(&[0x11; 32]).unwrap(),
                    &[0x22; 32],
                    "public-interop-fixture",
                    envelope.id,
                    false,
                )
                .unwrap();
                assert!(body.as_slice() == vault["plaintext"].as_str().unwrap().as_bytes());
                let deleted = envelope
                    .tombstone(envelope.hlc.clone(), "1234abcd".into(), true)
                    .unwrap();
                assert!(
                    deleted.extensions.len() == 2
                        && deleted.extensions.contains_key("vaultKID")
                        && deleted.extensions.contains_key("userDeletion.v1")
                );
            }
        }
    }
}
