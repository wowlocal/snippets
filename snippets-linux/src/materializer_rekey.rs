//! Data-only graph re-encryption. Original and edited copy roles stay distinct.
//! Neither keys nor plaintext can enter the returned translation table.
use super::*;
use std::collections::VecDeque;

pub(crate) struct Rekey {
    records: BTreeMap<String, Envelope>,
    ids: BTreeMap<Uuid, Uuid>,
}
struct Body {
    sealed: Sealed,
    hash: String,
}
struct Translator<'a, 'b> {
    old: ArchivedKeys<'a, 'b>,
    new: &'a Keyring<'b>,
    archived: bool,
    // Only ciphertext and keyed hashes are retained. Metadata changes do not
    // introduce different nonces for the same original body/record identity.
    bodies: BTreeMap<(Uuid, String, String, usize), Body>,
}
impl Translator<'_, '_> {
    fn body(&mut self, source: &Envelope, id: Uuid) -> Result<Envelope> {
        let mut target = source.clone();
        target.id = id;
        if source.secure {
            let (index, body) = if self.archived {
                self.old.body(source)?
            } else {
                (0, authenticated_body(source, self.old.keys[0], true)?)
            };
            let fields = source.fields.as_ref().ok_or(Failure::MalformedVariant)?;
            let sealed = std::str::from_utf8(&fields.content)
                .map_err(|_| Failure::MalformedVariant)?
                .to_owned();
            let hash = match source.extensions.get("vaultContentHash") {
                Some(hash) => hash.as_text()?.to_owned(),
                None if self.archived => self.old.hash(index, &body),
                None => return Err(Failure::IncompatibleVault),
            };
            let entry = self.bodies.entry((id, sealed, hash, index));
            let converted = match entry {
                std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
                std::collections::btree_map::Entry::Vacant(entry) => entry.insert(Body {
                    sealed: crypto::seal_record(
                        &body,
                        self.new.key,
                        &self.new.salt,
                        self.new.kid(),
                        id,
                        false,
                    )?,
                    hash: crypto::content_hash(&body, self.new.key, &self.new.salt),
                }),
            };
            target
                .fields
                .as_mut()
                .ok_or(Failure::MalformedVariant)?
                .content = Zeroizing::new(converted.sealed.text().as_bytes().to_vec());
            target
                .extensions
                .insert("vaultContentHash".into(), Value::text(&converted.hash));
            target
                .extensions
                .insert("vaultKID".into(), Value::text(self.new.kid()));
        }
        Ok(target)
    }
}
impl Rekey {
    #[cfg(test)]
    pub(crate) fn prepare(
        records: &[&Envelope],
        old: &Keyring<'_>,
        new: &Keyring<'_>,
    ) -> Result<Self> {
        Self::prepare_inner(records, &[old], new, false)
    }
    #[cfg(test)]
    pub(crate) fn prepare_archived(
        records: &[&Envelope],
        old: &Keyring<'_>,
        new: &Keyring<'_>,
    ) -> Result<Self> {
        Self::prepare_archived_many(records, &[old], new)
    }
    pub(crate) fn prepare_archived_many(
        records: &[&Envelope],
        old: &[&Keyring<'_>],
        new: &Keyring<'_>,
    ) -> Result<Self> {
        Self::prepare_inner(records, old, new, true)
    }
    fn prepare_inner(
        records: &[&Envelope],
        old: &[&Keyring<'_>],
        new: &Keyring<'_>,
        archived: bool,
    ) -> Result<Self> {
        let old = ArchivedKeys::new(old)?;
        let mut roles = BTreeMap::<Uuid, Option<merge::Provenance>>::new();
        let mut variants = BTreeMap::<Uuid, SecureVariant>::new();
        for record in records {
            merge::validate(record)?;
            if record.deleted
                || merge::has_unknown_version(record)
                || record
                    .extensions
                    .keys()
                    .any(|key| key.starts_with(merge::OPAQUE_CARRIER_PREFIX))
            {
                return Err(Failure::MalformedVariant);
            }
            let provenance = merge::provenance(record);
            if record.extensions.contains_key(merge::COPY_PROVENANCE)
                && !merge::valid_copy_identity(record)
            {
                return Err(Failure::IdentifierCollision);
            }
            if roles.get(&record.id).is_some_and(|old| old != &provenance) {
                return Err(Failure::IdentifierCollision);
            }
            roles.insert(record.id, provenance);
            if record.secure {
                if archived {
                    old.body(record)?;
                } else {
                    authenticate(record, old.keys[0], true)?;
                }
            }
            for variant in merge::secure_variants(record)? {
                old.variant(&variant)?;
                if variants
                    .get(&variant.copy_id)
                    .is_some_and(|old| old != &variant)
                {
                    return Err(Failure::IdentifierCollision);
                }
                variants.insert(variant.copy_id, variant);
            }
        }
        for variant in variants.values() {
            let role = Some(merge::Provenance {
                source_id: variant.source_id,
                fingerprint: variant.fingerprint.clone(),
            });
            if roles.get(&variant.copy_id).is_some_and(|old| old != &role) {
                return Err(Failure::IdentifierCollision);
            }
            roles.insert(variant.copy_id, role);
        }
        // Historical plain/orphan copies have no raw snapshot to fingerprint
        // again. Their retained historical fingerprint stays intact; their
        // parent identity and derived copy UUID must still change together.
        let parents: Vec<_> = roles.values().flatten().map(|p| p.source_id).collect();
        for parent in parents {
            roles.entry(parent).or_insert(None);
        }
        let mut children = BTreeMap::<Uuid, BTreeSet<Uuid>>::new();
        let mut ready = VecDeque::new();
        for (id, role) in &roles {
            if let Some(role) = role {
                children.entry(role.source_id).or_default().insert(*id);
            } else {
                ready.push_back(*id);
            }
        }
        let mut by_source = BTreeMap::<Uuid, Vec<&SecureVariant>>::new();
        for variant in variants.values() {
            by_source
                .entry(variant.source_id)
                .or_default()
                .push(variant);
        }
        let mut translator = Translator {
            old,
            new,
            archived,
            bodies: BTreeMap::new(),
        };
        let mut converted_variants = BTreeMap::<Uuid, (String, Value, merge::Provenance)>::new();
        let mut ids = BTreeMap::new();
        let mut owners = BTreeMap::new();
        while let Some(id) = ready.pop_front() {
            let mapped = if let Some(role) = &roles[&id] {
                let parent = *ids.get(&role.source_id).ok_or(Failure::MalformedVariant)?;
                let fingerprint = converted_variants
                    .get(&id)
                    .map(|(_, _, p)| p.fingerprint.as_str())
                    .unwrap_or(&role.fingerprint);
                merge::copy_id(parent, fingerprint)
            } else {
                id
            };
            if owners.insert(mapped, id).is_some() {
                return Err(Failure::IdentifierCollision);
            }
            ids.insert(id, mapped);
            for variant in by_source.get(&id).into_iter().flatten() {
                let source = Envelope {
                    id: variant.source_id,
                    hlc: variant.source_hlc.clone(),
                    origin: variant.source_origin.clone(),
                    secure: true,
                    deleted: false,
                    fields: Some(variant.fields.clone()),
                    extensions: variant.source_extensions.clone(),
                };
                let target = translator.body(&source, mapped)?;
                let (key, value) = merge::secure_variant(&target)?;
                let fingerprint = key
                    .strip_prefix(merge::CONFLICT_V1_PREFIX)
                    .ok_or(Failure::MalformedVariant)?
                    .to_owned();
                converted_variants.insert(
                    variant.copy_id,
                    (
                        key,
                        value,
                        merge::Provenance {
                            source_id: mapped,
                            fingerprint,
                        },
                    ),
                );
            }
            ready.extend(children.get(&id).into_iter().flatten().copied());
        }
        if ids.len() != roles.len() {
            return Err(Failure::MalformedVariant);
        }
        let mut converted = BTreeMap::new();
        for record in records {
            let mut target = translator.body(record, ids[&record.id])?;
            if let Some(role) = &roles[&record.id] {
                let role = converted_variants
                    .get(&record.id)
                    .map(|(_, _, role)| role.clone())
                    .unwrap_or_else(|| merge::Provenance {
                        source_id: ids[&role.source_id],
                        fingerprint: role.fingerprint.clone(),
                    });
                target.extensions.insert(
                    merge::COPY_PROVENANCE.into(),
                    merge::provenance_value(role.source_id, &role.fingerprint),
                );
            }
            for variant in merge::secure_variants(record)? {
                target.extensions.remove(&variant.extension_key);
                let (key, value, _) = &converted_variants[&variant.copy_id];
                if target
                    .extensions
                    .insert(key.clone(), value.clone())
                    .is_some()
                {
                    return Err(Failure::IdentifierCollision);
                }
            }
            merge::validate(&target)?;
            if target.secure {
                authenticate(&target, new, true)?;
            }
            let hash = record.hash()?;
            if converted.get(&hash).is_some_and(|old| old != &target) {
                return Err(Failure::IdentifierCollision);
            }
            converted.insert(hash, target);
        }
        Ok(Self {
            records: converted,
            ids,
        })
    }
    pub(crate) fn record(&self, source: &Envelope) -> Result<Envelope> {
        self.records
            .get(&source.hash()?)
            .cloned()
            .ok_or(Failure::MalformedVariant)
    }
    pub(crate) fn id(&self, id: Uuid) -> Uuid {
        self.ids.get(&id).copied().unwrap_or(id)
    }
}

#[cfg(test)]
#[path = "materializer_rekey_tests.rs"]
mod tests;
