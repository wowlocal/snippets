//! Bounded Linux-only binary schema. Explicit tags distinguish absent, reviewed
//! absent and unknown; no permissive JSON defaults or unbounded plaintext copies.
use super::*;
use zeroize::Zeroizing;
const INVALID: Failure = Failure::InvalidState;

struct Writer(Zeroizing<Vec<u8>>);
impl Writer {
    fn put(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() > crypto::MAX_CHECKPOINT_BYTES.saturating_sub(self.0.len()) {
            return Err(INVALID);
        }
        if bytes.len() > self.0.capacity() - self.0.len() {
            // Grow into a new owner, then clear the old allocation. Vec::reserve
            // can otherwise leave freed plaintext journal memory untouched.
            let capacity = (self.0.capacity() * 2)
                .max(self.0.len() + bytes.len())
                .min(crypto::MAX_CHECKPOINT_BYTES);
            let mut larger = Zeroizing::new(Vec::with_capacity(capacity));
            larger.extend_from_slice(&self.0);
            self.0 = larger;
        }
        self.0.extend_from_slice(bytes);
        Ok(())
    }
    fn count(&mut self, count: usize) -> Result<()> {
        if count > model::MAX_SNIPPETS {
            return Err(INVALID);
        }
        self.put(&(count as u32).to_be_bytes())
    }
    fn bytes(&mut self, bytes: &[u8]) -> Result<()> {
        let n = u32::try_from(bytes.len()).map_err(|_| INVALID)?;
        self.put(&n.to_be_bytes())?;
        self.put(bytes)
    }
    fn envelope(&mut self, e: &Envelope) -> Result<()> {
        self.bytes(&e.encode()?)
    }
    fn option<T>(
        &mut self,
        value: Option<&T>,
        emit: impl FnOnce(&mut Self, &T) -> Result<()>,
    ) -> Result<()> {
        self.put(&[u8::from(value.is_some())])?;
        if let Some(value) = value {
            emit(self, value)?;
        }
        Ok(())
    }
    fn version(&mut self, v: &RecordVersion) -> Result<()> {
        self.bytes(v.for_checkpoint().as_bytes())
    }
    fn cursor(&mut self, c: &crate::cloud::Cursor) -> Result<()> {
        self.bytes(c.for_checkpoint().as_bytes())
    }
    fn offered(&mut self, o: &Offered) -> Result<()> {
        self.envelope(&o.envelope)?;
        self.put(&o.generation.to_be_bytes())?;
        self.option(o.record_version.as_ref(), Self::version)
    }
    fn wire(&mut self, wire: &crate::wire::WireRecord) -> Result<()> {
        self.put(wire.id.as_bytes())?;
        self.bytes(wire.rev.as_bytes())?;
        self.put(&[u8::from(wire.deleted)])?;
        self.bytes(&wire.blob)
    }
}
struct Reader<'a>(&'a [u8]);
impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        if count > self.0.len() {
            return Err(INVALID);
        }
        let (bytes, rest) = self.0.split_at(count);
        self.0 = rest;
        Ok(bytes)
    }
    fn number(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(
            self.take(8)?.try_into().map_err(|_| INVALID)?,
        ))
    }
    fn count(&mut self) -> Result<usize> {
        let n = u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| INVALID)?) as usize;
        if n > model::MAX_SNIPPETS || n > self.0.len() {
            return Err(INVALID);
        }
        Ok(n)
    }
    fn bytes(&mut self, max: usize) -> Result<&'a [u8]> {
        let n = u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| INVALID)?) as usize;
        if n > max {
            return Err(INVALID);
        }
        self.take(n)
    }
    fn text(&mut self, max: usize) -> Result<String> {
        Ok(std::str::from_utf8(self.bytes(max)?)
            .map_err(|_| INVALID)?
            .into())
    }
    fn id(&mut self) -> Result<Uuid> {
        Uuid::from_slice(self.take(16)?).map_err(|_| INVALID)
    }
    fn option<T>(&mut self, parse: impl FnOnce(&mut Self) -> Result<T>) -> Result<Option<T>> {
        match self.take(1)?[0] {
            0 => Ok(None),
            1 => Ok(Some(parse(self)?)),
            _ => Err(INVALID),
        }
    }
    fn version(&mut self) -> Result<RecordVersion> {
        RecordVersion::from_checkpoint(self.text(2048)?).map_err(|_| INVALID)
    }
    fn cursor(&mut self) -> Result<crate::cloud::Cursor> {
        crate::cloud::Cursor::from_checkpoint(self.text(4096)?).map_err(|_| INVALID)
    }
    fn boolean(&mut self) -> Result<bool> {
        match self.take(1)?[0] {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(INVALID),
        }
    }
    fn envelope(&mut self) -> Result<Envelope> {
        let bytes = self.bytes(crate::canonical::MAX_BYTES)?;
        let e = Envelope::parse(bytes)?;
        merge::validate(&e)?;
        if e.encode()?.as_slice() != bytes {
            return Err(INVALID);
        }
        Ok(e)
    }
    fn offered(&mut self) -> Result<Offered> {
        Ok(Offered {
            envelope: self.envelope()?,
            generation: self.number()?,
            record_version: self.option(Self::version)?,
        })
    }
    fn wire(&mut self) -> Result<crate::wire::WireRecord> {
        let wire = crate::wire::WireRecord {
            id: self.id()?,
            rev: self.text(256)?,
            deleted: self.boolean()?,
            blob: self.bytes(crate::wire::MAX_BLOB_BYTES)?.to_vec(),
        };
        wire.validate().map_err(|_| INVALID)?;
        Ok(wire)
    }
}
fn validate_offer(offer: &Offered, id: Uuid, generation: u64) -> Result<()> {
    merge::validate(&offer.envelope)?;
    if offer.envelope.id != id || offer.generation == 0 || offer.generation > generation {
        return Err(INVALID);
    }
    if let Some(v) = &offer.record_version {
        v.validate().map_err(|_| INVALID)?;
    }
    Ok(())
}
pub(super) fn validate(journal: &Journal) -> Result<()> {
    if journal.deletion_approvals.len() > model::MAX_SNIPPETS
        || (!journal.deletion_approvals.is_empty() && journal.key_epoch.is_none())
    {
        return Err(INVALID);
    }
    for (id, approval) in &journal.deletion_approvals {
        if !crate::wire::is_hash(&approval.hash) {
            return Err(INVALID);
        }
        if let Some(ancestor) = &approval.ancestor {
            merge::validate(ancestor)?;
            if ancestor.id != *id || ancestor.deleted {
                return Err(INVALID);
            }
        }
        if !journal
            .entry(*id)
            .map(|e| &e.desired)
            .into_iter()
            .chain(journal.projected.get(id))
            .chain(journal.confirmed(*id).map(|c| &c.envelope))
            // Original delivery can temporarily own the primary/confirmed
            // image while this separately reviewed exact deletion waits in
            // an ordered frame. The frame represents intent, never consent.
            .chain(journal.delivery.get(id))
            .chain(journal.generations.iter().filter_map(|g| g.targets.get(id)))
            .any(|e| e.deleted && e.hash().is_ok_and(|hash| hash == approval.hash))
        {
            return Err(INVALID);
        }
    }
    if let Some(epoch) = journal.key_epoch
        && (epoch == 0
            || epoch > i64::MAX as u64
            || journal
                .inbox
                .feed
                .as_ref()
                .is_some_and(|f| f.key_epoch != epoch)
            || journal
                .outbound
                .as_ref()
                .is_some_and(|p| p.key_epoch != epoch))
    {
        return Err(INVALID);
    }
    journal.inbox.validate()?;
    if let Some(packet) = &journal.outbound {
        packet.validate()?;
    }
    for (id, e) in &journal.projected {
        if *id != e.id {
            return Err(INVALID);
        }
        merge::validate(e)?;
    }
    if journal.projected.len() > model::MAX_SNIPPETS {
        return Err(INVALID);
    }
    if let Some(intent) = &journal.primary_intent {
        intent.validate()?;
        if journal.primary_epoch != Some(intent.nonce) {
            return Err(INVALID);
        }
    }
    if [
        journal.entries.len(),
        journal.confirmed.len(),
        journal.dependencies.len(),
    ]
    .into_iter()
    .any(|n| n > model::MAX_SNIPPETS)
    {
        return Err(INVALID);
    }
    for (id, entry) in &journal.entries {
        merge::validate(&entry.desired)?;
        if entry.desired.id != *id || entry.generation == 0 {
            return Err(INVALID);
        }
        if let Some(o) = &entry.offered {
            validate_offer(o, *id, entry.generation)?;
        }
        if let ReviewAncestor::Reviewed {
            primary,
            previous_merge,
        } = &entry.review
        {
            for e in primary.iter().chain(previous_merge) {
                merge::validate(e)?;
                if e.id != *id {
                    return Err(INVALID);
                }
            }
        }
    }
    for (id, confirmed) in &journal.confirmed {
        merge::validate(&confirmed.envelope)?;
        if confirmed.envelope.id != *id {
            return Err(INVALID);
        }
        confirmed.record_version.validate().map_err(|_| INVALID)?;
    }
    validate_graph(&journal.dependencies)?;
    if journal.delivery.len() > model::MAX_SNIPPETS
        || journal.generations.len() > MAX_PRESERVATION_GENERATIONS
    {
        return Err(INVALID);
    }
    validate_targets(&journal.delivery)?;
    let mut nonces = BTreeSet::new();
    for g in &journal.generations {
        if g.nonce == [0; 16]
            || !nonces.insert(g.nonce)
            || g.targets.is_empty()
            || g.targets.len() > model::MAX_SNIPPETS
            || g.dependencies.len() > model::MAX_SNIPPETS
        {
            return Err(INVALID);
        }
        validate_targets(&g.targets)?;
        validate_graph(&g.dependencies)?;
        for (id, edge) in &g.dependencies {
            if !g.targets.contains_key(id)
                || edge.source_offered.is_some()
                || edge.source_accepted_version.is_some()
                || edge.requirements.values().any(|r| {
                    r.offered.is_some()
                        || r.accepted_version.is_some()
                        || !g.targets.contains_key(&r.copy_id)
                })
            {
                return Err(INVALID);
            }
        }
    }
    Ok(())
}
fn validate_targets(targets: &BTreeMap<Uuid, Envelope>) -> Result<()> {
    for (id, target) in targets {
        merge::validate(target)?;
        if *id != target.id
            || (target.extensions.contains_key(merge::COPY_PROVENANCE)
                && !merge::valid_copy_identity(target))
        {
            return Err(INVALID);
        }
    }
    Ok(())
}
fn validate_graph(dependencies: &BTreeMap<Uuid, Dependency>) -> Result<()> {
    let mut occupied = BTreeSet::new();
    for (id, edge) in dependencies {
        merge::validate(&edge.source)?;
        if edge.source.id != *id
            || edge.requirements.is_empty()
            || edge.requirements.len() > merge::MAX_VARIANTS
        {
            return Err(INVALID);
        }
        let variants: BTreeMap<_, _> = merge::secure_variants(&edge.source)?
            .into_iter()
            .map(|v| (v.fingerprint.clone(), v))
            .collect();
        if let Some(o) = &edge.source_offered {
            validate_offer(o, *id, u64::MAX)?;
            if merge::has_unresolved(Some(&o.envelope)) || !Journal::prerequisites_accepted(edge) {
                return Err(INVALID);
            }
        }
        if let Some(v) = &edge.source_accepted_version {
            v.validate().map_err(|_| INVALID)?;
            if edge.source_offered.is_none() {
                return Err(INVALID);
            }
        }
        for (fingerprint, r) in &edge.requirements {
            if fingerprint != &r.fingerprint
                || !crate::wire::is_hash(fingerprint)
                || r.copy_id != merge::copy_id(*id, fingerprint)
                || !occupied.insert(r.copy_id)
            {
                return Err(INVALID);
            }
            if let Some(child) = dependencies.get(&r.copy_id)
                && !merge::matching_provenance(&child.source, *id, fingerprint)
            {
                return Err(INVALID);
            }
            if let Some((key, value)) = &r.carrier {
                let v = variants.get(fingerprint).ok_or(INVALID)?;
                if v.copy_id != r.copy_id
                    || &v.extension_key != key
                    || edge.source.extensions.get(key) != Some(value)
                {
                    return Err(INVALID);
                }
            }
            if let Some(snapshot) = &r.snapshot {
                merge::validate(snapshot)?;
                if snapshot.id != r.copy_id
                    || snapshot.deleted
                    || !merge::matching_provenance(snapshot, *id, fingerprint)
                {
                    return Err(INVALID);
                }
            }
            if let Some(o) = &r.offered {
                validate_offer(o, r.copy_id, u64::MAX)?;
                if !r
                    .snapshot
                    .as_ref()
                    .map(|s| same(s, &o.envelope))
                    .transpose()?
                    .unwrap_or(false)
                {
                    return Err(INVALID);
                }
            }
            if let Some(v) = &r.accepted_version {
                if r.snapshot.is_none() {
                    return Err(INVALID);
                }
                v.validate().map_err(|_| INVALID)?;
            }
        }
    }
    Journal::preservation_order_for(dependencies)?;
    Ok(())
}
pub(super) fn encode(journal: &Journal) -> Result<Zeroizing<Vec<u8>>> {
    encode_schema(journal, 6)
}
#[cfg(test)]
pub(super) fn encode_legacy_four(journal: &Journal) -> Result<Zeroizing<Vec<u8>>> {
    encode_schema(journal, 4)
}
#[cfg(test)]
pub(super) fn encode_legacy_five(journal: &Journal) -> Result<Zeroizing<Vec<u8>>> {
    encode_schema(journal, 5)
}
fn encode_schema(journal: &Journal, schema: u8) -> Result<Zeroizing<Vec<u8>>> {
    validate(journal)?;
    if schema < 6 && (!journal.delivery.is_empty() || !journal.generations.is_empty()) {
        return Err(INVALID);
    }
    let current = schema >= 5;
    if !current
        && (!journal.deletion_approvals.is_empty()
            || journal
                .outbound
                .as_ref()
                .is_some_and(|p| p.offers.iter().any(|o| o.deletion_authorized)))
    {
        return Err(INVALID);
    }
    // A single bounded allocation avoids reallocating plaintext journal bodies.
    let mut w = Writer(Zeroizing::new(Vec::with_capacity(4096)));
    w.put(match schema {
        6 => b"JNL6",
        5 => b"JNL5",
        _ => b"JNL4",
    })?;
    w.put(journal.scope.membership.bytes_for_checkpoint())?;
    w.put(journal.scope.dataset.bytes_for_checkpoint())?;
    w.count(journal.entries.len())?;
    for (id, e) in &journal.entries {
        w.put(id.as_bytes())?;
        w.envelope(&e.desired)?;
        w.put(&e.generation.to_be_bytes())?;
        w.option(e.offered.as_ref(), Writer::offered)?;
        match &e.review {
            ReviewAncestor::Unknown => w.put(&[0])?,
            ReviewAncestor::Reviewed {
                primary,
                previous_merge,
            } => {
                w.put(&[1])?;
                w.option(primary.as_deref(), Writer::envelope)?;
                w.option(previous_merge.as_deref(), Writer::envelope)?;
            }
        }
    }
    w.count(journal.confirmed.len())?;
    for (id, c) in &journal.confirmed {
        w.put(id.as_bytes())?;
        w.envelope(&c.envelope)?;
        w.version(&c.record_version)?;
    }
    w.count(journal.dependencies.len())?;
    for (id, edge) in &journal.dependencies {
        w.put(id.as_bytes())?;
        w.envelope(&edge.source)?;
        w.option(edge.source_offered.as_ref(), Writer::offered)?;
        w.option(edge.source_accepted_version.as_ref(), Writer::version)?;
        w.count(edge.requirements.len())?;
        for (fingerprint, r) in &edge.requirements {
            w.bytes(fingerprint.as_bytes())?;
            w.put(r.copy_id.as_bytes())?;
            w.option(r.carrier.as_ref(), |w, (key, value)| {
                w.bytes(key.as_bytes())?;
                w.bytes(&value.encode()?)
            })?;
            w.option(r.snapshot.as_ref(), Writer::envelope)?;
            w.option(r.offered.as_ref(), Writer::offered)?;
            w.option(r.accepted_version.as_ref(), Writer::version)?;
        }
    }
    w.count(journal.projected.len())?;
    for (id, e) in &journal.projected {
        w.put(id.as_bytes())?;
        w.envelope(e)?;
    }
    w.option(journal.primary_intent.as_ref(), |w, intent| {
        w.put(&intent.nonce)?;
        for image in [
            &intent.before_plain,
            &intent.before_vault,
            &intent.after_plain,
            &intent.after_vault,
        ] {
            w.option(image.as_ref(), |w, bytes| w.bytes(bytes))?;
        }
        Ok(())
    })?;
    w.option(journal.primary_epoch.as_ref(), |w, nonce| w.put(nonce))?;
    let inbox = &journal.inbox;
    w.option(inbox.feed.as_ref(), |w, feed| {
        w.put(feed.epoch.as_bytes())?;
        w.put(&feed.key_epoch.to_be_bytes())
    })?;
    w.put(&inbox.received.to_be_bytes())?;
    w.put(&inbox.completed.to_be_bytes())?;
    w.option(inbox.fetched_cursor.as_ref(), Writer::cursor)?;
    w.option(inbox.applied_cursor.as_ref(), Writer::cursor)?;
    w.option(inbox.pending.as_ref(), |w, page| {
        w.put(&page.generation.to_be_bytes())?;
        w.count(page.position)?;
        w.cursor(&page.cursor)?;
        w.put(&[u8::from(page.full_snapshot), u8::from(page.has_more)])?;
        w.count(page.records.len())?;
        for record in &page.records {
            w.envelope(&record.envelope)?;
            w.version(&record.record_version)?;
        }
        Ok(())
    })?;
    w.option(inbox.snapshot.as_ref(), |w, snapshot| {
        w.put(&[u8::from(snapshot.open)])?;
        w.count(snapshot.seen.len())?;
        for id in &snapshot.seen {
            w.put(id.as_bytes())?;
        }
        Ok(())
    })?;
    w.put(&[u8::from(inbox.review)])?;
    w.option(journal.outbound.as_ref(), |w, packet| {
        use crate::outbound::Receipt;
        w.put(&packet.key_epoch.to_be_bytes())?;
        w.count(packet.position)?;
        w.count(packet.offers.len())?;
        for offer in &packet.offers {
            w.offered(&offer.offered)?;
            w.wire(&offer.wire)?;
            if current {
                w.put(&[u8::from(offer.deletion_authorized)])?;
            }
        }
        w.option(packet.receipts.as_ref(), |w, receipts| {
            w.count(receipts.len())?;
            for receipt in receipts {
                match receipt {
                    Receipt::Accepted(version) => {
                        w.put(&[0])?;
                        w.version(version)?;
                    }
                    Receipt::Conflict { wire, version } => {
                        w.put(&[1])?;
                        w.wire(wire)?;
                        w.version(version)?;
                    }
                    Receipt::Rejected { code, retry_after } => {
                        w.put(&[2])?;
                        w.bytes(&serde_json::to_vec(code).map_err(|_| INVALID)?)?;
                        w.option(retry_after.as_ref(), |w, value| {
                            w.put(&u64::from(*value).to_be_bytes())
                        })?;
                    }
                }
            }
            Ok(())
        })?;
        w.option(packet.received_at.as_ref(), |w, value| {
            w.put(&value.to_be_bytes())
        })
    })?;
    w.option(journal.key_epoch.as_ref(), |w, epoch| {
        w.put(&epoch.to_be_bytes())
    })?;
    if current {
        w.count(journal.deletion_approvals.len())?;
        for (id, approval) in &journal.deletion_approvals {
            w.put(id.as_bytes())?;
            w.bytes(approval.hash.as_bytes())?;
            w.option(approval.ancestor.as_ref(), Writer::envelope)?;
        }
    }
    if schema >= 6 {
        w.count(journal.delivery.len())?;
        for (id, target) in &journal.delivery {
            w.put(id.as_bytes())?;
            w.envelope(target)?;
        }
        w.count(journal.generations.len())?;
        for generation in &journal.generations {
            w.put(&generation.nonce)?;
            let mut data = Journal::new(journal.scope.clone());
            data.delivery = generation.targets.clone();
            data.dependencies = generation.dependencies.clone();
            w.bytes(&encode(&data)?)?;
        }
    }
    Ok(w.0)
}
pub(super) fn decode(bytes: &[u8], scope: Scope) -> Result<Journal> {
    decode_level(bytes, scope, true)
}
fn decode_level(bytes: &[u8], scope: Scope, allow_generations: bool) -> Result<Journal> {
    if bytes.len() > crypto::MAX_CHECKPOINT_BYTES {
        return Err(INVALID);
    }
    let mut r = Reader(bytes);
    let schema = r.take(4)?;
    let supported: [&[u8]; 6] = [b"JNL1", b"JNL2", b"JNL3", b"JNL4", b"JNL5", b"JNL6"];
    if !supported.contains(&schema) {
        return Err(INVALID);
    }
    // Resolve the binding before touching envelopes or the local primary library.
    if r.take(32)? != scope.membership.bytes_for_checkpoint()
        || r.take(32)? != scope.dataset.bytes_for_checkpoint()
    {
        return Err(Failure::ScopeReview);
    }
    let mut journal = Journal::new(scope);
    for _ in 0..r.count()? {
        let id = r.id()?;
        let desired = r.envelope()?;
        let generation = r.number()?;
        let offered = r.option(Reader::offered)?;
        let review = match r.take(1)?[0] {
            0 => ReviewAncestor::Unknown,
            1 => ReviewAncestor::Reviewed {
                primary: r.option(Reader::envelope)?.map(Box::new),
                previous_merge: r.option(Reader::envelope)?.map(Box::new),
            },
            _ => return Err(INVALID),
        };
        if journal
            .entries
            .insert(
                id,
                Entry {
                    desired,
                    generation,
                    offered,
                    review,
                },
            )
            .is_some()
        {
            return Err(INVALID);
        }
    }
    for _ in 0..r.count()? {
        let id = r.id()?;
        let c = Confirmed {
            envelope: r.envelope()?,
            record_version: r.version()?,
        };
        if journal.confirmed.insert(id, c).is_some() {
            return Err(INVALID);
        }
    }
    for _ in 0..r.count()? {
        let id = r.id()?;
        let source = r.envelope()?;
        let source_offered = r.option(Reader::offered)?;
        let source_accepted_version = r.option(Reader::version)?;
        let mut requirements = BTreeMap::new();
        let count = r.count()?;
        if count > merge::MAX_VARIANTS {
            return Err(INVALID);
        }
        for _ in 0..count {
            let fingerprint = r.text(64)?;
            let copy_id = r.id()?;
            let carrier = r.option(|r| {
                Ok((
                    r.text(128)?,
                    crate::canonical::parse(r.bytes(crate::canonical::MAX_BYTES)?)?,
                ))
            })?;
            let snapshot = r.option(Reader::envelope)?;
            let offered = r.option(Reader::offered)?;
            let accepted_version = r.option(Reader::version)?;
            let requirement = Requirement {
                copy_id,
                fingerprint: fingerprint.clone(),
                carrier,
                snapshot,
                offered,
                accepted_version,
            };
            if requirements.insert(fingerprint, requirement).is_some() {
                return Err(INVALID);
            }
        }
        if journal
            .dependencies
            .insert(
                id,
                Dependency {
                    source,
                    source_offered,
                    source_accepted_version,
                    requirements,
                },
            )
            .is_some()
        {
            return Err(INVALID);
        }
    }
    if schema != b"JNL1" {
        for _ in 0..r.count()? {
            let id = r.id()?;
            let e = r.envelope()?;
            if journal.projected.insert(id, e).is_some() {
                return Err(INVALID);
            }
        }
        journal.primary_intent = r.option(|r| {
            let nonce = r.take(16)?.try_into().map_err(|_| INVALID)?;
            let image = |r: &mut Reader<'_>| {
                r.option(|r| Ok(Zeroizing::new(r.bytes(model::MAX_FILE_BYTES)?.to_vec())))
            };
            Ok(crate::primary::Intent {
                nonce,
                before_plain: image(r)?,
                before_vault: image(r)?,
                after_plain: image(r)?,
                after_vault: image(r)?,
            })
        })?;
        journal.primary_epoch = r.option(|r| r.take(16)?.try_into().map_err(|_| INVALID))?;
    }
    if matches!(schema, b"JNL3" | b"JNL4" | b"JNL5" | b"JNL6") {
        use crate::inbound::{Feed, Inbox, PAGE_LIMIT, Page, Snapshot};
        let feed = r.option(|r| Feed::new(r.id()?, r.number()?))?;
        let received = r.number()?;
        let completed = r.number()?;
        let fetched_cursor = r.option(Reader::cursor)?;
        let applied_cursor = r.option(Reader::cursor)?;
        let pending = r.option(|r| {
            let generation = r.number()?;
            let position = r.count()?;
            let cursor = r.cursor()?;
            let full_snapshot = r.boolean()?;
            let has_more = r.boolean()?;
            let count = r.count()?;
            if count > PAGE_LIMIT {
                return Err(INVALID);
            }
            let mut records = Vec::with_capacity(count);
            for _ in 0..count {
                records.push(Confirmed {
                    envelope: r.envelope()?,
                    record_version: r.version()?,
                });
            }
            Ok(Page {
                generation,
                records,
                position,
                cursor,
                full_snapshot,
                has_more,
            })
        })?;
        let snapshot = r.option(|r| {
            let open = r.boolean()?;
            let mut seen = BTreeSet::new();
            for _ in 0..r.count()? {
                if !seen.insert(r.id()?) {
                    return Err(INVALID);
                }
            }
            Ok(Snapshot { open, seen })
        })?;
        let review = r.boolean()?;
        journal.inbox = Inbox {
            feed,
            received,
            completed,
            fetched_cursor,
            applied_cursor,
            pending,
            snapshot,
            review,
        };
    }
    if matches!(schema, b"JNL4" | b"JNL5" | b"JNL6") {
        use crate::outbound::{Packet, Receipt, Transmission};
        journal.outbound = r.option(|r| {
            let key_epoch = r.number()?;
            let position = r.count()?;
            let count = r.count()?;
            if count == 0 || count > crate::inbound::PAGE_LIMIT {
                return Err(INVALID);
            }
            let mut offers = Vec::with_capacity(count);
            for _ in 0..count {
                offers.push(Transmission {
                    offered: r.offered()?,
                    wire: r.wire()?,
                    deletion_authorized: if matches!(schema, b"JNL5" | b"JNL6") {
                        r.boolean()?
                    } else {
                        false
                    },
                });
            }
            let receipts = r.option(|r| {
                let count = r.count()?;
                if count > crate::inbound::PAGE_LIMIT {
                    return Err(INVALID);
                }
                let mut receipts = Vec::with_capacity(count);
                for _ in 0..count {
                    receipts.push(match r.take(1)?[0] {
                        0 => Receipt::Accepted(r.version()?),
                        1 => Receipt::Conflict {
                            wire: r.wire()?,
                            version: r.version()?,
                        },
                        2 => Receipt::Rejected {
                            code: serde_json::from_slice(r.bytes(64)?).map_err(|_| INVALID)?,
                            retry_after: r
                                .option(|r| u32::try_from(r.number()?).map_err(|_| INVALID))?,
                        },
                        _ => return Err(INVALID),
                    });
                }
                Ok(receipts)
            })?;
            let received_at = r.option(Reader::number)?;
            Ok(Packet {
                key_epoch,
                offers,
                receipts,
                received_at,
                position,
            })
        })?;
    }
    if matches!(schema, b"JNL4" | b"JNL5" | b"JNL6") {
        journal.key_epoch = r.option(Reader::number)?;
    }
    if matches!(schema, b"JNL5" | b"JNL6") {
        for _ in 0..r.count()? {
            let id = r.id()?;
            let approval = DeletionApproval {
                hash: r.text(64)?,
                ancestor: r.option(Reader::envelope)?,
            };
            if journal.deletion_approvals.insert(id, approval).is_some() {
                return Err(INVALID);
            }
        }
    }
    if schema == b"JNL6" {
        for _ in 0..r.count()? {
            let id = r.id()?;
            let target = r.envelope()?;
            if journal.delivery.insert(id, target).is_some() {
                return Err(INVALID);
            }
        }
        let count = r.count()?;
        if count > MAX_PRESERVATION_GENERATIONS || (!allow_generations && count != 0) {
            return Err(INVALID);
        }
        for _ in 0..count {
            let nonce = r.take(16)?.try_into().map_err(|_| INVALID)?;
            let data = decode_level(
                r.bytes(crypto::MAX_CHECKPOINT_BYTES)?,
                journal.scope.clone(),
                false,
            )?;
            if !data.entries.is_empty()
                || !data.confirmed.is_empty()
                || !data.projected.is_empty()
                || data.primary_intent.is_some()
                || data.primary_epoch.is_some()
                || data.inbox != crate::inbound::Inbox::default()
                || data.outbound.is_some()
                || data.key_epoch.is_some()
                || !data.deletion_approvals.is_empty()
            {
                return Err(INVALID);
            }
            journal.generations.push(PreservationGeneration {
                nonce,
                targets: data.delivery,
                dependencies: data.dependencies,
            });
        }
    }
    if !r.0.is_empty() {
        return Err(INVALID);
    }
    validate(&journal)?;
    Ok(journal)
}
