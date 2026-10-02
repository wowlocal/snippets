//! Fixed, protected file receipts. Exact identity and ciphertext hashes remain
//! inside the owner; no pathname, body or vault key is serialized.
use super::*;
use std::{
    fs::{File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::PathBuf,
};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Proof {
    pub nonce: [u8; 16],
    pub kind: u8,
    identity: [u64; 7],
    hash: [u8; 32],
}
fn identity(metadata: &std::fs::Metadata) -> Result<[u64; 7]> {
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.len() > (crate::crypto::MAX_CHECKPOINT_BYTES + 32) as u64
    {
        return Err(Failure::InvalidState);
    }
    Ok([
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime() as u64,
        metadata.mtime_nsec() as u64,
        metadata.ctime() as u64,
        metadata.ctime_nsec() as u64,
    ])
}
impl Proof {
    fn path(&self, library: &Library) -> Result<PathBuf> {
        let directory = crate::account_review::archive_directory(library, false)
            .map_err(|_| Failure::InvalidState)?;
        Ok(crate::account_review::image_path(
            &directory,
            &self.nonce,
            if self.kind == 0 { "source" } else { "target" },
        ))
    }
    pub(super) fn length(&self) -> u64 {
        self.identity[2]
    }
    pub(super) fn hash(&self) -> [u8; 32] {
        self.hash
    }
    pub(super) fn value(&self) -> Value {
        let mut bytes = Vec::with_capacity(105);
        bytes.extend_from_slice(&self.nonce);
        bytes.push(self.kind);
        for n in self.identity {
            bytes.extend_from_slice(&n.to_be_bytes());
        }
        bytes.extend_from_slice(&self.hash);
        Value::text(STANDARD.encode(bytes))
    }
    pub(super) fn parse(value: &Value) -> Result<Self> {
        let bytes = decode64(value.as_text()?, 105)?;
        let nonce = bytes[..16].try_into().map_err(|_| Failure::InvalidState)?;
        let kind = bytes[16];
        let mut identity = [0; 7];
        for (n, bytes) in identity.iter_mut().zip(bytes[17..73].as_chunks::<8>().0) {
            *n = u64::from_be_bytes(*bytes);
        }
        if nonce == [0; 16]
            || kind > 1
            || identity[2] == 0
            || identity[2] > (crate::crypto::MAX_CHECKPOINT_BYTES + 32) as u64
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            nonce,
            kind,
            identity,
            hash: bytes[73..].try_into().map_err(|_| Failure::InvalidState)?,
        })
    }
    fn check(&self, library: &Library, missing: bool) -> Result<bool> {
        match read(&self.path(library)?)? {
            Some((identity, hash)) if identity == self.identity && hash == self.hash => Ok(true),
            None if missing => Ok(false),
            _ => Err(Failure::ReviewRequired),
        }
    }
}
fn read(path: &std::path::Path) -> Result<Option<([u64; 7], [u8; 32])>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        _ => return Err(Failure::InvalidState),
    };
    let before = identity(&file.metadata().map_err(|_| Failure::InvalidState)?)?;
    let mut bytes = Vec::new();
    (&file)
        .take((crate::crypto::MAX_CHECKPOINT_BYTES + 33) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::InvalidState)?;
    if bytes.len() as u64 != before[2]
        || identity(&file.metadata().map_err(|_| Failure::InvalidState)?)? != before
        || identity(&std::fs::symlink_metadata(path).map_err(|_| Failure::InvalidState)?)? != before
    {
        return Err(Failure::ReviewRequired);
    }
    Ok(Some((before, Sha256::digest(bytes).into())))
}
pub(super) fn prove(library: &Library, images: &Images) -> Result<Vec<Proof>> {
    let mut proofs = Vec::new();
    for kind in 0..2 {
        let mut proof = Proof {
            nonce: images.nonce,
            kind,
            identity: [0; 7],
            hash: images.hashes[kind as usize],
        };
        let (identity, hash) = read(&proof.path(library)?)?.ok_or(Failure::RecoveryUnavailable)?;
        if hash != proof.hash {
            return Err(Failure::ReviewRequired);
        }
        proof.identity = identity;
        proofs.push(proof);
    }
    Ok(proofs)
}
pub(super) fn verify(library: &Library, proofs: &[Proof], missing: bool) -> Result<()> {
    for proof in proofs {
        proof.check(library, missing)?;
    }
    Ok(())
}
pub(super) fn remove(
    library: &Library,
    proofs: &[Proof],
    lease: &AuthorizationLease,
    fault: Option<u8>,
) -> Result<()> {
    verify(library, proofs, true)?;
    for (index, proof) in proofs.iter().enumerate() {
        lease.check()?;
        if proof.check(library, true)? {
            std::fs::remove_file(proof.path(library)?).map_err(|_| Failure::InvalidState)?;
        }
        fail(fault, 3 + index as u8)?;
    }
    if !proofs.is_empty() {
        File::open(
            crate::account_review::archive_directory(library, false)
                .map_err(|_| Failure::InvalidState)?,
        )
        .and_then(|file| file.sync_all())
        .map_err(|_| Failure::InvalidState)?;
    }
    fail(fault, 5)
}
