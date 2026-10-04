//! Temporary roots and fictional protected owners only.
use super::*;

#[test]
fn removal_preserves_other_entries_and_the_last_generation() {
    let entries = vec![
        Value::text("Public first saved entry"),
        Value::text("Public second saved entry"),
    ];
    let snapshot = object([
        ("schema", Value::Int(2)),
        ("generation", Value::Int(17)),
        ("entries", Value::Array(entries.clone())),
    ])
    .encode()
    .unwrap();
    let selection = Selection::new(Section::Pairing, 0, &snapshot);
    let doc = Document::validated(
        Some(snapshot),
        17,
        vec![
            Row {
                libraries: Vec::new(),
                eligible: true,
                images: None,
            },
            Row {
                libraries: Vec::new(),
                eligible: true,
                images: None,
            },
        ],
    )
    .unwrap();
    let after = doc.removed(&selection).unwrap();
    let value = canonical::parse(&after).unwrap();
    assert_eq!(
        value.as_object().unwrap()["generation"].as_int().unwrap(),
        18
    );
    assert!(value.as_object().unwrap()["entries"].as_array().unwrap() == &entries[1..]);
    assert!(matches!(
        doc.removed(&Selection {
            hash: [0; 32],
            ..selection
        }),
        Err(Failure::ReviewRequired)
    ));
    let selection = Selection::new(Section::Pairing, 0, &after);
    let doc = Document::validated(
        Some(after),
        18,
        vec![Row {
            libraries: Vec::new(),
            eligible: true,
            images: None,
        }],
    )
    .unwrap();
    let empty = canonical::parse(&doc.removed(&selection).unwrap()).unwrap();
    assert!(
        empty.as_object().unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        empty.as_object().unwrap()["generation"].as_int().unwrap(),
        19
    );
}
#[test]
fn protected_pending_removal_fences_other_processes_without_initializing_slots() {
    let temp = tempfile::tempdir().unwrap();
    let backend = crate::secret_store::tests::Memory::default();
    let mut store = Store::initialize(temp.path(), backend.clone()).unwrap();
    store
        .history_transaction_with(|owner| {
            owner.replace(
                Slot::HistoryMaintenance,
                None,
                Some(b"Public malformed pending removal"),
            )
        })
        .unwrap();
    let mut other = Store::load(temp.path(), backend).unwrap();
    assert!(matches!(
        other.transaction(|owner| owner.replace(
            Slot::LibraryKey,
            None,
            Some(b"Public replacement key")
        )),
        Err(secret_store::Failure::HistoryMaintenanceRequired)
    ));
    other
        .history_transaction_with(|owner| {
            assert!(owner.read(Slot::LibraryKey)?.is_none());
            assert!(pending_locked(owner).is_err());
            Ok::<_, secret_store::Failure>(())
        })
        .unwrap();
    other
        .clipboard_transaction(|owner| {
            owner.replace(
                Slot::ClipboardHistory,
                None,
                Some(b"Public independent clipboard key"),
            )?;
            assert!(matches!(
                owner.read(Slot::HistoryMaintenance),
                Err(secret_store::Failure::InvalidValue)
            ));
            assert!(matches!(
                owner.replace(Slot::LibraryKey, None, Some(b"Public forbidden key")),
                Err(secret_store::Failure::InvalidValue)
            ));
            Ok(())
        })
        .unwrap();
}

#[test]
fn receipt_schema_rejects_unknown_or_unbounded_authority() {
    let binding =
        crate::key_store::tests::FakeRemote::new(crate::key_store::tests::Memory::default()).pin;
    let intent = Intent {
        libraries: vec![binding.clone()],
        binding: binding.clone(),
        frame: [1; 32],
        nonce: [2; 16],
        selection: Selection {
            section: Section::FirstKeys,
            index: 0,
            hash: [3; 32],
        },
        generation: 7,
        after: [4; 32],
        proofs: Vec::new(),
        summary: Summary {
            libraries: vec![history::SavedLibrary::new(&binding)],
            section: Section::FirstKeys,
            entry: 1,
            protected_bytes: 100,
            encrypted_images: 0,
            encrypted_bytes: 0,
        },
    };
    let original = intent.value().unwrap();
    assert!(Intent::parse(&original.encode().unwrap()).is_ok());
    for kind in 0..9 {
        let mut value = original.clone();
        let Value::Object(ref mut fields) = value else {
            unreachable!()
        };
        match kind {
            0 => {
                fields.insert("unexpected".into(), Value::Bool(true));
            }
            1 => {
                fields.insert("schema".into(), Value::Int(2));
            }
            2 => {
                fields.insert("index".into(), Value::Int(8));
            }
            3 => {
                fields.insert("generation".into(), Value::Int(i64::MAX));
            }
            4 => {
                fields.insert("nonce".into(), Value::text(STANDARD.encode([0; 16])));
            }
            5 => {
                fields.insert(
                    "protectedBytes".into(),
                    Value::Int(secret_store::MAX_SECRET_BYTES as i64 + 1),
                );
            }
            6 => {
                fields.insert("libraries".into(), Value::Array(Vec::new()));
            }
            7 => {
                fields.insert("section".into(), Value::text("switches"));
            }
            8 => {
                fields.insert(
                    "images".into(),
                    Value::Array(vec![Value::text("public malformed proof")]),
                );
            }
            _ => unreachable!(),
        }
        assert!(Intent::parse(&value.encode().unwrap()).is_err());
    }
    assert!(
        intent.target(Purpose::RemoveSavedHistory).unwrap()
            != intent.target(Purpose::ResumeHistoryRemoval).unwrap()
    );
}
