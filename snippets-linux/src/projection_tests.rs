//! Public fictional records only; no filesystem or vault session access.
use super::*;
use crate::crypto::RootKey;
fn plain() -> Envelope {
    let mut snippet = Snippet::new("Public projection fixture", "Fictional body");
    snippet.id = Uuid::from_u128(1);
    snippet.created_at = 10.0;
    snippet.updated_at = 20.0;
    let mut e = Envelope::plain(
        &snippet,
        Hlc::parse("000000015f90-0007-22222222").unwrap(),
        "22222222".into(),
    )
    .unwrap();
    e.extensions.insert(
        "future".into(),
        Value::Array(vec![Value::Int(1), Value::Float(1.0)]),
    );
    e
}
fn vault() -> Document {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap()
}
fn secure() -> (Envelope, Document) {
    let mut document = vault();
    let record = &document.records[0];
    let mut e = plain();
    e.id = record.metadata.id;
    e.secure = true;
    e.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(record.sealed.text().as_bytes().to_vec());
    e.fields.as_mut().unwrap().created_at = 10.123456;
    e.fields.as_mut().unwrap().updated_at = 20.456789;
    e.extensions
        .insert("vaultKID".into(), Value::text(document.kid.clone()));
    e.extensions.insert(
        "vaultContentHash".into(),
        Value::text(record.content_hash.clone()),
    );
    document.records = vec![
        vault_record(&e, Some(record), &document.kid)
            .unwrap()
            .unwrap(),
    ];
    document = Document::decode(&document.encode().unwrap()).unwrap();
    (e, document)
}
fn map(e: &Envelope) -> BTreeMap<Uuid, Envelope> {
    BTreeMap::from([(e.id, e.clone())])
}

#[test]
fn plain_apply_project_is_byte_exact_and_independent_reads_do_not_mint_a_clock() {
    let e = plain();
    let snippet = e.snippet().unwrap().unwrap();
    let first = current(
        std::slice::from_ref(&snippet),
        None,
        "11111111",
        &map(&e),
        &map(&e),
    )
    .unwrap();
    assert!(first[&e.id].encode().unwrap() == e.encode().unwrap());
    let second = current(&[snippet], None, "11111111", &first, &map(&e)).unwrap();
    assert!(first == second);
}
#[test]
fn secure_apply_project_keeps_wire_dates_keyed_hash_and_sealed_bytes_without_a_key() {
    let (e, document) = secure();
    let actual = current(&[], Some(&document), "11111111", &map(&e), &map(&e)).unwrap();
    assert!(actual[&e.id].encode().unwrap() == e.encode().unwrap());
    assert!(exact_secure_echo(&e, &document.records[0], &document.kid).unwrap());
    assert_eq!(
        document.records[0].content_hash,
        e.extensions["vaultContentHash"].as_text().unwrap()
    );
    assert_ne!(
        document.records[0].content_hash,
        crate::wire::sha256(&e.fields.as_ref().unwrap().content)
    );
}
#[test]
fn local_edit_outranks_backward_dates_and_preserves_all_unknown_knowledge() {
    let e = plain();
    let mut snippet = e.snippet().unwrap().unwrap();
    snippet.updated_at = -100_000.0;
    snippet.name = "Edited locally".into();
    let mut sidecar = e.clone();
    sidecar
        .extensions
        .insert("sidecarFuture".into(), Value::Bool(true));
    let first = current(
        &[snippet.clone()],
        None,
        "11111111",
        &map(&sidecar),
        &map(&e),
    )
    .unwrap();
    let projected = &first[&e.id];
    assert!(projected.hlc > e.hlc);
    assert_eq!(projected.origin, "11111111");
    assert!(
        projected.extensions.contains_key("sidecarFuture")
            && projected.extensions.contains_key("future")
    );
    assert!(current(&[snippet], None, "11111111", &first, &map(&e)).unwrap() == first);
}
#[test]
fn secure_scope_backfill_stabilizes_once_and_body_change_never_reuses_the_old_hmac() {
    let (mut legacy, document) = secure();
    legacy.extensions.remove("vaultKID");
    let first = current(
        &[],
        Some(&document),
        "11111111",
        &map(&legacy),
        &map(&legacy),
    )
    .unwrap();
    assert_eq!(
        first[&legacy.id].extensions["vaultKID"].as_text().unwrap(),
        document.kid
    );
    assert!(current(&[], Some(&document), "11111111", &first, &map(&legacy)).unwrap() == first);
    let (e, mut document) = secure();
    document.records[0].content_hash.clear();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    document.records[0].sealed = crate::crypto::seal_record(
        b"New public fictional body",
        &root,
        &document.salt().unwrap(),
        &document.kid,
        e.id,
        false,
    )
    .unwrap();
    let edited = current(&[], Some(&document), "11111111", &map(&e), &map(&e)).unwrap();
    assert!(!edited[&e.id].extensions.contains_key("vaultContentHash"));
}
#[test]
fn representation_transition_drops_vault_routing_but_keeps_opaque_metadata() {
    let (e, _) = secure();
    let mut snippet = plain().snippet().unwrap().unwrap();
    snippet.id = e.id;
    let view = current(&[snippet], None, "11111111", &map(&e), &map(&e)).unwrap();
    assert!(!view[&e.id].secure && view[&e.id].extensions.contains_key("future"));
    assert!(!view[&e.id].extensions.contains_key("vaultKID"));
    assert!(!view[&e.id].extensions.contains_key("vaultContentHash"));
}
#[test]
fn opaque_carriers_round_trip_numeric_types_and_primary_cleanup_overrides_stale_sidecar() {
    let (mut e, mut document) = secure();
    let key = format!("contentConflict.v2.{}", "a".repeat(64));
    let value = Value::Object(BTreeMap::from([
        ("integer".into(), Value::Int(1)),
        ("float".into(), Value::Float(1.0)),
    ]));
    e.extensions.insert(key.clone(), value.clone());
    document.records[0] = vault_record(&e, Some(&document.records[0]), &document.kid)
        .unwrap()
        .unwrap();
    document = Document::decode(&document.encode().unwrap()).unwrap();
    let no_sidecar = current(
        &[],
        Some(&document),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap();
    assert!(no_sidecar[&e.id].extensions[&key] == value);
    document.records[0].extra.clear();
    let cleaned = current(&[], Some(&document), "11111111", &map(&e), &map(&e)).unwrap();
    assert!(!merge::has_unresolved(Some(&cleaned[&e.id])));
}
#[test]
fn unknown_wire_extensions_never_enter_plaintext_vault_passthrough_storage() {
    let (mut e, document) = secure();
    e.extensions.insert(
        "futurePrivate".into(),
        Value::text("Public fictional confidential extension"),
    );
    let record = vault_record(&e, Some(&document.records[0]), &document.kid)
        .unwrap()
        .unwrap();
    assert!(!record.extra.contains_key("futurePrivate"));
    let mut existing = record.clone();
    existing
        .extra
        .insert("existingPrimary".into(), serde_json::json!(1));
    let record = vault_record(&e, Some(&existing), &document.kid)
        .unwrap()
        .unwrap();
    assert!(record.extra.contains_key("existingPrimary"));
}
#[test]
fn corrupt_reserved_extensions_duplicates_and_foreign_vaults_fail_before_projection() {
    let (e, mut document) = secure();
    let id = e.id;
    document.records[0].extra.insert(
        format!("{}v1.bad", merge::OPAQUE_CARRIER_PREFIX),
        serde_json::json!("not base64"),
    );
    assert!(current(&[], Some(&document), "11111111", &map(&e), &map(&e)).is_err());
    let (e, document) = secure();
    let mut snippet = plain().snippet().unwrap().unwrap();
    snippet.id = e.id;
    assert!(current(&[snippet], Some(&document), "11111111", &map(&e), &map(&e)).is_err());
    assert!(vault_record(&e, None, "another-vault").is_err());
    let mut bad = e.clone();
    bad.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(b"not a seal".to_vec());
    assert!(vault_record(&bad, None, &document.kid).is_err());
    let mut future = e;
    future
        .extensions
        .insert(merge::COPY_PROVENANCE.into(), Value::Null);
    assert!(vault_record(&future, None, &document.kid).is_err());
    assert_eq!(future.id, id);
}
#[test]
fn equal_primary_versions_union_disjoint_extensions_but_reserved_disagreement_halts() {
    let mut a = plain();
    let mut b = a.clone();
    a.extensions.insert("a".into(), Value::Int(1));
    b.extensions.insert("b".into(), Value::Int(2));
    let snippet = a.snippet().unwrap().unwrap();
    let union = current(
        std::slice::from_ref(&snippet),
        None,
        "11111111",
        &map(&a),
        &map(&b),
    )
    .unwrap();
    assert!(union[&a.id].extensions.contains_key("a") && union[&a.id].extensions.contains_key("b"));
    let key = format!("contentConflict.v2.{}", "b".repeat(64));
    a.extensions.insert(key.clone(), Value::Int(1));
    b.extensions.insert(key, Value::Int(2));
    assert!(current(&[snippet], None, "11111111", &map(&a), &map(&b)).is_err());
}
