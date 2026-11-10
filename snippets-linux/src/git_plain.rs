//! Plain-text Git libraries (`snippets-plain-v1`): one ordinary snippet as a
//! readable Markdown file, byte for byte the Apple `GitPlainSnippetFile`:
//!
//! ```text
//! ---
//! name: "Greeting"
//! keyword: "hi"
//! tags: ["work"]
//! enabled: true
//! pinned: false
//! id: 617a0002-0000-4000-8000-000000000002
//! sync: eyJjcmVhdGVkQXQiOjgwM…
//! ---
//! Hello there!
//! ```
//!
//! The body is everything after the closing `---` line, minus the one newline
//! that ends the file. `sync` is unpadded base64url of canonical JSON
//! `{createdAt, hash, hlc, origin, schemaVersion, updatedAt, x}`: what people
//! never edit, and the envelope hash the file was written with. Reading
//! rebuilds the envelope; if its hash still matches, the file is exactly what
//! a device wrote. Otherwise every device derives the same revision from the
//! bytes alone: the `sync` clock plus one tick on the foreign device.
//!
//! The parser follows the Apple one where people can type anything: Swift
//! `Character` (grapheme) comparisons for `#`, `:`, quotes and brackets,
//! Foundation's `.whitespaces` set for trimming, and Foundation's base64 and
//! tag folding rules. Secure snippets and tombstones are never rendered.
use crate::{
    canonical::{self, Value},
    clock::Hlc,
    wire::{self, Envelope, Fields},
};
use base64::{
    Engine, alphabet,
    engine::{
        DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig, general_purpose::URL_SAFE_NO_PAD,
    },
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const DIRECTORY: &str = "snippets";
pub const EXTENSION: &str = ".md";
pub const MAX_FILE_BYTES: usize = 1_100_000;
pub const FOREIGN_DEVICE: &str = "00000000";
const BOM: &[u8] = &[0xef, 0xbb, 0xbf];
const SYNC_KEYS: [&str; 8] = [
    "createdAt",
    "hash",
    "hlc",
    "id",
    "origin",
    "schemaVersion",
    "updatedAt",
    "x",
];

/// The file cannot be read or written as a plain snippet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Malformed;
type Result<T> = std::result::Result<T, Malformed>;

/// Whether an envelope can be a readable file. Secure records, deletions,
/// anything carrying extension data (a secure loser's conflict snapshot, or a
/// future field meant to stay encrypted) and anything that would not read
/// back exactly stay ciphertext.
pub fn can_render(envelope: &Envelope) -> bool {
    render(envelope).is_ok()
}

/// The file for `envelope`, verified to read back as exactly that envelope.
pub fn render(envelope: &Envelope) -> Result<Vec<u8>> {
    let fields = envelope.fields.as_ref().ok_or(Malformed)?;
    if envelope.deleted
        || envelope.secure
        || !envelope.extensions.is_empty()
        || fields.content.len() >= MAX_FILE_BYTES - 4_096
        || std::str::from_utf8(&fields.content).is_err()
    {
        return Err(Malformed);
    }
    let data = unverified_render(envelope, fields)?;
    let path = format!(
        "{DIRECTORY}/{}{EXTENSION}",
        envelope.id.hyphenated().to_string().to_uppercase()
    );
    match read(&data, &path, None) {
        Ok((back, false)) if back == *envelope => Ok(data),
        _ => Err(Malformed),
    }
}
fn unverified_render(envelope: &Envelope, fields: &Fields) -> Result<Vec<u8>> {
    let meta = Value::Object(BTreeMap::from([
        ("createdAt".into(), Value::Float(fields.created_at)),
        (
            "hash".into(),
            Value::text(envelope.hash().map_err(|_| Malformed)?),
        ),
        ("hlc".into(), Value::text(envelope.hlc.text())),
        (
            "id".into(),
            Value::text(envelope.id.hyphenated().to_string()),
        ),
        ("origin".into(), Value::text(envelope.origin.clone())),
        ("schemaVersion".into(), Value::Int(1)),
        ("updatedAt".into(), Value::Float(fields.updated_at)),
        ("x".into(), Value::Object(envelope.extensions.clone())),
    ]));
    let json =
        |value: Value| -> Result<Zeroizing<Vec<u8>>> { value.encode().map_err(|_| Malformed) };
    let mut out = Vec::with_capacity(fields.content.len() + 512);
    out.extend_from_slice(b"---\nname: ");
    out.extend_from_slice(&json(Value::text(fields.name.clone()))?);
    out.extend_from_slice(b"\nkeyword: ");
    out.extend_from_slice(&json(Value::text(fields.keyword.clone()))?);
    out.extend_from_slice(b"\ntags: ");
    out.extend_from_slice(&json(Value::Array(
        fields.tags.iter().map(|t| Value::text(t.clone())).collect(),
    ))?);
    out.extend_from_slice(format!("\nenabled: {}", fields.is_enabled).as_bytes());
    out.extend_from_slice(format!("\npinned: {}", fields.is_pinned).as_bytes());
    out.extend_from_slice(format!("\nid: {}", envelope.id.hyphenated()).as_bytes());
    out.extend_from_slice(b"\nsync: ");
    out.extend_from_slice(URL_SAFE_NO_PAD.encode(json(meta)?.as_slice()).as_bytes());
    out.extend_from_slice(b"\n---\n");
    out.extend_from_slice(&fields.content);
    out.push(b'\n');
    Ok(out)
}

/// `greeting-617a0002.md`: readable, sorted by name, and unique enough that
/// two snippets with one name do not collide.
pub fn file_name(name: &str, id: Uuid) -> String {
    format!(
        "{}-{}{EXTENSION}",
        slug(name),
        &id.hyphenated().to_string()[..8]
    )
}

/// Lowercase ASCII letters and digits joined by single hyphens, at most 48
/// long; an empty result is `snippet`. ASCII names match Apple exactly. Apple
/// also transliterates other scripts (`Привет` becomes `privet`); here only
/// diacritics are removed, and other letters are dropped. Paths are cosmetic
/// and an existing file keeps its path until the snippet is renamed.
pub fn slug(text: &str) -> String {
    let source: String = text.nfd().filter(|c| !is_combining_mark(*c)).collect();
    let mut slug = String::new();
    let mut pending_hyphen = false;
    for character in source.to_lowercase().chars() {
        if character.is_ascii_alphanumeric() {
            if pending_hyphen && !slug.is_empty() {
                slug.push('-');
            }
            pending_hyphen = false;
            slug.push(character);
            if slug.len() >= 48 {
                break;
            }
        } else {
            pending_hyphen = true;
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        "snippet".into()
    } else {
        slug
    }
}

/// The id a file declares: its `sync` metadata's, else its first valid `id`
/// line's, else (a file added by hand without either) one derived from its
/// path, the same on every device. A file whose front matter does not parse
/// is still matched by a scan for those lines.
pub fn declared_id(data: &[u8], path: &str) -> Uuid {
    parse(data)
        .and_then(|parsed| parsed.meta.map(|meta| meta.id).or(parsed.id))
        .or_else(|| scan_id(data))
        .unwrap_or_else(|| derived_id(path))
}

/// Whether the file starts with a front-matter line (`---`, after an optional
/// BOM). Such a file that fails to parse is a mistake, never a new snippet.
pub fn has_front_matter(data: &[u8]) -> bool {
    let bytes = data.strip_prefix(BOM).unwrap_or(data);
    bytes.strip_prefix(b"---").is_some_and(|rest| {
        rest.iter()
            .take_while(|b| **b != b'\n')
            .all(|b| matches!(b, b' ' | b'\t' | b'\r'))
    })
}

/// The id of a file whose front matter does not parse: its `sync`
/// metadata's, else its first valid `id` line's. Lines are split on bytes, so
/// CRLF files scan too.
fn scan_id(data: &[u8]) -> Option<Uuid> {
    if !has_front_matter(data) {
        return None;
    }
    let mut line_id = None;
    for raw in data[..data.len().min(16_384)]
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .skip(1)
    {
        let line = String::from_utf8_lossy(raw);
        let text = line.trim_matches(is_whitespace_or_newline);
        if text == "---" {
            break;
        }
        let lowered = text.to_lowercase();
        let starts = |prefix: &[&str]| {
            lowered
                .graphemes(true)
                .take(prefix.len())
                .eq(prefix.iter().copied())
        };
        if starts(&["s", "y", "n", "c", ":"]) {
            let rest: String = text.graphemes(true).skip(5).collect();
            if let Some(meta) = meta(trim(&rest)) {
                return Some(meta.id);
            }
        }
        if line_id.is_none() && starts(&["i", "d", ":"]) {
            let rest: String = text.graphemes(true).skip(3).collect();
            line_id = foundation_uuid(&string(trim(&rest)));
        }
    }
    line_id
}

/// The first 16 bytes of `SHA256("snippets-git-plain-file-v1\n<path>")` with
/// version 8 and RFC 4122 variant bits.
pub fn derived_id(path: &str) -> Uuid {
    let digest = Sha256::digest(format!("snippets-git-plain-file-v1\n{path}"));
    let mut bytes: [u8; 16] = digest[..16].try_into().expect("16 of 32 bytes");
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

/// The envelope a file describes, and whether it was edited since a device
/// wrote it. `assigned` gives the file another id than it declares (a copy
/// that kept the original's id becomes its own snippet); that is always an
/// edit, because the id is part of the hash.
pub fn read(data: &[u8], path: &str, assigned: Option<Uuid>) -> Result<(Envelope, bool)> {
    if data.len() > MAX_FILE_BYTES {
        return Err(Malformed);
    }
    let parsed = if has_front_matter(data) {
        // A mistake in front matter makes the file unreadable; it never turns
        // the file into a different snippet. So does a newer Snippets' format,
        // which is never rewritten, so an older build cannot downgrade it.
        let parsed = parse(data).ok_or(Malformed)?;
        if parsed.newer_sync {
            return Err(Malformed);
        }
        parsed
    } else {
        // A plain Markdown file added by hand: its name is the file name.
        let stem = path.rsplit('/').next().unwrap_or(path);
        Parsed {
            name: Some(stem.strip_suffix(EXTENSION).unwrap_or(stem).to_owned()),
            body: strip_final_newline(data, false).to_vec(),
            ..Parsed::default()
        }
    };
    let id = assigned
        .or(parsed.meta.as_ref().map(|meta| meta.id))
        .or(parsed.id)
        .unwrap_or_else(|| derived_id(path));
    let created_at = parsed.meta.as_ref().map_or(0.0, |m| m.created_at);
    let updated_at = parsed.meta.as_ref().map_or(0.0, |m| m.updated_at);
    let x = parsed
        .meta
        .as_ref()
        .map(|m| m.x.clone())
        .unwrap_or_default();
    let name = parsed.name.clone().unwrap_or_default();
    let keyword = parsed.keyword.clone().unwrap_or_default();
    let enabled = parsed.enabled.unwrap_or(true);
    let pinned = parsed.pinned.unwrap_or(false);

    // Exact only as a device wrote it: the current schema, the id its `sync`
    // names (as read, assigned or not), and an `id` line saying the same. Any
    // other file is an edit, so normalizing rewrites its `id` line.
    if let Some(meta) = parsed.meta.as_ref().filter(|m| m.schema_version == 1)
        && meta.id == id
        && parsed.id == Some(meta.id)
        && let Ok(exact) = envelope(Draft {
            id,
            hlc: &meta.hlc,
            origin: &meta.origin,
            name: name.clone(),
            keyword: keyword.clone(),
            body: &parsed.body,
            tags: parsed.tags.clone().unwrap_or_default(),
            enabled,
            pinned,
            created_at,
            updated_at,
            x: x.clone(),
        })
        && exact.hash().is_ok_and(|hash| hash == meta.hash)
    {
        return Ok((exact, false));
    }

    // Edited (or added) by hand. Deterministic from the file alone, so every
    // device derives the same revision and none pushes it back and forth.
    let hlc = parsed
        .meta
        .as_ref()
        .and_then(|m| Hlc::parse(&m.hlc).ok())
        .map_or_else(|| Hlc::foreign(0), |previous| previous.bumped_foreign());
    let edited = envelope(Draft {
        id,
        hlc: &hlc.text(),
        origin: FOREIGN_DEVICE,
        name,
        keyword,
        body: &parsed.body,
        tags: normalized_tags(&parsed.tags.unwrap_or_default()),
        enabled,
        pinned,
        created_at,
        updated_at,
        x,
    })?;
    Ok((edited, true))
}

/// A Markdown file deleted by hand: one tick after the file's clock, on the
/// foreign device, without the in-app deletion marker (Apple `tombstoned`).
pub fn tombstone(previous: &Envelope) -> Result<Envelope> {
    let tombstone = Envelope {
        id: previous.id,
        hlc: previous.hlc.bumped_foreign(),
        origin: FOREIGN_DEVICE.into(),
        secure: false,
        deleted: true,
        fields: None,
        extensions: BTreeMap::new(),
    };
    tombstone.encode().map_err(|_| Malformed)?;
    Ok(tombstone)
}

/// The deletion of a Markdown file this device no longer holds (a lost
/// cache): the lowest clock, so an edit made since outranks it.
pub fn lowest_tombstone(id: Uuid) -> Envelope {
    Envelope {
        id,
        hlc: Hlc::foreign(0),
        origin: FOREIGN_DEVICE.into(),
        secure: false,
        deleted: true,
        fields: None,
        extensions: BTreeMap::new(),
    }
}

/// Whether the snippet in `previous` (a file's bytes) had another name: then
/// its file is renamed. Names compare as Swift strings do, by canonical
/// equivalence.
pub fn renamed(previous: &[u8], name: &str) -> bool {
    let Some(old) = parse(previous).and_then(|p| p.name) else {
        return false;
    };
    !old.nfd().eq(name.nfd())
}

struct Draft<'a> {
    id: Uuid,
    hlc: &'a str,
    origin: &'a str,
    name: String,
    keyword: String,
    body: &'a [u8],
    tags: Vec<String>,
    enabled: bool,
    pinned: bool,
    created_at: f64,
    updated_at: f64,
    x: BTreeMap<String, Value>,
}
/// The ten-key envelope, validated exactly as the wire layer would.
fn envelope(draft: Draft<'_>) -> Result<Envelope> {
    std::str::from_utf8(draft.body).map_err(|_| Malformed)?;
    if !wire::device(draft.origin) {
        return Err(Malformed);
    }
    let envelope = Envelope {
        id: draft.id,
        hlc: Hlc::parse(draft.hlc).map_err(|_| Malformed)?,
        origin: draft.origin.into(),
        secure: false,
        deleted: false,
        fields: Some(Fields {
            name: draft.name,
            keyword: draft.keyword,
            content: Zeroizing::new(draft.body.to_vec()),
            tags: draft.tags,
            is_enabled: draft.enabled,
            is_pinned: draft.pinned,
            created_at: draft.created_at,
            updated_at: draft.updated_at,
        }),
        extensions: draft.x,
    };
    envelope.encode().map_err(|_| Malformed)?;
    Ok(envelope)
}

// MARK: - Parsing

/// The `sync` line. Deliberately not `Debug`: canonical values never are.
#[derive(Clone, PartialEq)]
pub struct Meta {
    /// The snippet's id, covered by `hash`. It, not the editable `id` line,
    /// decides which snippet a file is.
    pub id: Uuid,
    pub hlc: String,
    pub origin: String,
    pub schema_version: i64,
    pub created_at: f64,
    pub updated_at: f64,
    pub x: BTreeMap<String, Value>,
    pub hash: String,
}
#[derive(Clone, Default, PartialEq)]
pub struct Parsed {
    pub name: Option<String>,
    pub keyword: Option<String>,
    pub tags: Option<Vec<String>>,
    pub enabled: Option<bool>,
    pub pinned: Option<bool>,
    pub id: Option<Uuid>,
    pub meta: Option<Meta>,
    /// The last `sync` line came from a newer format (see `is_newer_sync`).
    pub newer_sync: bool,
    pub body: Vec<u8>,
}

/// Front matter between `---` lines, then the body. Lenient about what people
/// type: a leading BOM, quoted or bare strings, JSON, bare or YAML block
/// (`- item`) tag lists, `yes`/`no`/`1`/`0`, CRLF, blank lines, `#` comments
/// and lines without a key. Unknown keys are ignored. None when the file has
/// no well-formed front matter.
pub fn parse(data: &[u8]) -> Option<Parsed> {
    let data = data.strip_prefix(BOM).unwrap_or(data);
    let line = |start: usize| -> Option<(String, usize)> {
        if start >= data.len() {
            return None;
        }
        let end = data[start..]
            .iter()
            .position(|b| *b == b'\n')
            .map_or(data.len(), |offset| start + offset);
        let mut bytes = &data[start..end];
        if let [rest @ .., b'\r'] = bytes {
            bytes = rest;
        }
        Some((
            String::from_utf8_lossy(bytes).into_owned(),
            (end + 1).min(data.len()),
        ))
    };
    let (opening, mut cursor) = line(0)?;
    if trim(&opening) != "---" {
        return None;
    }
    let mut parsed = Parsed::default();
    let mut closed = false;
    let mut closing_was_crlf = false;
    let mut collecting_tags = false;
    while let Some((current, next)) = line(cursor) {
        let raw = &data[cursor..next];
        cursor = next;
        let text = trim(&current);
        if text == "---" {
            closed = true;
            closing_was_crlf = raw.ends_with(b"\r\n");
            break;
        }
        if collecting_tags && let Some(dash) = first_grapheme(text).filter(|g| *g == "-") {
            let item = string(trim(&text[dash.len()..]));
            if !item.is_empty() {
                parsed.tags.get_or_insert_with(Vec::new).push(item);
            }
            continue;
        }
        collecting_tags = false;
        if text.is_empty() || first_grapheme(text) == Some("#") {
            continue;
        }
        let Some(colon) = text
            .grapheme_indices(true)
            .find(|(_, g)| *g == ":")
            .map(|(index, _)| index)
        else {
            continue;
        };
        let key = trim(&text[..colon]).to_lowercase();
        let value = trim(&text[colon + 1..]);
        match key.as_str() {
            "name" => parsed.name = Some(string(value)),
            "keyword" => parsed.keyword = Some(string(value)),
            "tags" => {
                parsed.tags = Some(tags(value));
                collecting_tags = value.is_empty();
            }
            "enabled" => parsed.enabled = Some(boolean(value)?),
            "pinned" => parsed.pinned = Some(boolean(value)?),
            // A mangled id is ignored (the file keeps the snippet at its
            // path), and the first valid `id` line wins over any later one.
            "id" if parsed.id.is_none() => parsed.id = foundation_uuid(&string(value)),
            "sync" => {
                parsed.meta = meta(value);
                parsed.newer_sync = is_newer_sync(value);
            }
            _ => (),
        }
    }
    if !closed {
        return None;
    }
    parsed.body = strip_final_newline(&data[cursor..], closing_was_crlf).to_vec();
    Some(parsed)
}

/// The file ends with one newline that is not part of the body: writers add
/// `\n`, and an editor that saved the file with CRLF line endings adds `\r\n`.
fn strip_final_newline(body: &[u8], crlf: bool) -> &[u8] {
    match body {
        [rest @ .., b'\r', b'\n'] if crlf => rest,
        [rest @ .., b'\n'] => rest,
        _ => body,
    }
}

/// Foundation `CharacterSet.whitespaces`: General Category Zs, tab, and the
/// zero-width space Foundation still counts (U+180E is not included).
fn is_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{09}' | '\u{20}' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
/// Foundation `CharacterSet.whitespacesAndNewlines`.
fn is_whitespace_or_newline(c: char) -> bool {
    is_whitespace(c) || matches!(c, '\u{0a}'..='\u{0d}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
fn trim(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}
fn first_grapheme(text: &str) -> Option<&str> {
    text.graphemes(true).next()
}

/// Swift `string(_:)`: a JSON string, a single-quoted string with `''`
/// escapes, or the bare text.
fn string(value: &str) -> String {
    if first_grapheme(value) == Some("\"")
        && let Ok(Value::Text(text)) = canonical::parse(value.as_bytes())
    {
        return text.to_string();
    }
    let graphemes: Vec<&str> = value.graphemes(true).collect();
    if graphemes.len() >= 2 && graphemes[0] == "'" && graphemes[graphemes.len() - 1] == "'" {
        let inner = &graphemes[1..graphemes.len() - 1];
        let mut text = String::new();
        let mut index = 0;
        while index < inner.len() {
            text.push_str(inner[index]);
            index += if inner[index] == "'" && inner.get(index + 1) == Some(&"'") {
                2
            } else {
                1
            };
        }
        return text;
    }
    value.to_owned()
}
fn tags(value: &str) -> Vec<String> {
    if first_grapheme(value) == Some("[")
        && let Ok(Value::Array(values)) = canonical::parse(value.as_bytes())
    {
        let texts: Vec<String> = values
            .iter()
            .filter_map(|v| v.as_text().ok().map(str::to_owned))
            .collect();
        if texts.len() == values.len() {
            return texts;
        }
    }
    let graphemes: Vec<&str> = value.graphemes(true).collect();
    let inner =
        if graphemes.len() >= 2 && graphemes[0] == "[" && graphemes[graphemes.len() - 1] == "]" {
            &graphemes[1..graphemes.len() - 1]
        } else {
            &graphemes[..]
        };
    inner
        .split(|g| *g == ",")
        .map(|part| string(trim(&part.concat())))
        .filter(|tag| !tag.is_empty())
        .collect()
}
fn boolean(value: &str) -> Option<bool> {
    match value.to_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" => Some(false),
        _ => None,
    }
}
/// Foundation `UUID(uuidString:)`: exactly 8-4-4-4-12 hex digits, any case.
fn foundation_uuid(text: &str) -> Option<Uuid> {
    let bytes = text.as_bytes();
    let shaped = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        });
    shaped.then(|| Uuid::parse_str(text).ok()).flatten()
}
/// Unpadded base64url, decoded as Apple does: `-`/`_` mapped to `+`/`/`,
/// padding optional, unused trailing bits ignored.
fn base64url(text: &str) -> Option<Vec<u8>> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_allow_trailing_bits(true)
            .with_decode_padding_mode(DecodePaddingMode::RequireNone),
    );
    let standard = text.replace('-', "+").replace('_', "/");
    let unpadded = standard.trim_end_matches('=');
    if unpadded.contains('=') {
        return None;
    }
    LENIENT.decode(unpadded).ok()
}
/// A well-formed `sync` object from a later schema, or with keys beyond the
/// ones this build writes. A malformed or partial one is a hand edit, not a
/// newer format.
fn is_newer_sync(value: &str) -> bool {
    let Some(bytes) = base64url(value) else {
        return false;
    };
    let Ok(Value::Object(object)) = canonical::parse_lenient_numbers(&bytes) else {
        return false;
    };
    if object
        .get("schemaVersion")
        .and_then(|version| version.as_int().ok())
        .is_some_and(|version| version > 1)
    {
        return true;
    }
    object.len() > SYNC_KEYS.len() && SYNC_KEYS.iter().all(|key| object.contains_key(*key))
}

fn meta(value: &str) -> Option<Meta> {
    let bytes = base64url(value)?;
    let Value::Object(object) = canonical::parse_lenient_numbers(&bytes).ok()? else {
        return None;
    };
    if object.len() != SYNC_KEYS.len() || !SYNC_KEYS.iter().all(|k| object.contains_key(*k)) {
        return None;
    }
    let id_text = object["id"].as_text().ok()?;
    let id = foundation_uuid(id_text).filter(|id| id.hyphenated().to_string() == id_text)?;
    Some(Meta {
        id,
        hlc: object["hlc"].as_text().ok()?.to_owned(),
        origin: object["origin"].as_text().ok()?.to_owned(),
        schema_version: object["schemaVersion"].as_int().ok()?,
        created_at: object["createdAt"].as_float().ok()?,
        updated_at: object["updatedAt"].as_float().ok()?,
        x: object["x"].as_object().ok()?.clone(),
        hash: object["hash"].as_text().ok()?.to_owned(),
    })
}

// MARK: - Tags

/// Apple `SnippetTagging.normalizedTags`: whitespace runs collapsed to one
/// space, empties dropped, and duplicates removed case- and
/// diacritic-insensitively, keeping the first spelling and the input order.
pub fn normalized_tags(raw: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for tag in raw {
        let tag = tag
            .split(is_whitespace_or_newline)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if !tag.is_empty() && seen.insert(tag_key(&tag)) {
            normalized.push(tag);
        }
    }
    normalized
}
/// Foundation `folding([.caseInsensitive, .diacriticInsensitive])` as far as
/// it decides tag identity, measured against Foundation scalar by scalar:
///
/// - A character whose decomposed base folds below U+0510 (Latin, Greek,
///   Cyrillic, and Latin/Greek letters precomposed elsewhere) folds to that
///   base, and every combining mark after it is dropped.
/// - Any other character that case folding changes (an uppercase Armenian,
///   Georgian or Cherokee letter, say) folds, and keeps the marks after it.
/// - Any other character stays as written; after it only the generic
///   combining diacritics (U+0300–036F, U+0483–0489) are dropped, never a
///   script's own vowel signs or points, nor an emoji's variation selector.
///
/// Folding is full case folding, then lowercase mapping; Foundation's tables
/// leave the Cyrillic small-letter variants U+1C80–1C88 alone. Checked
/// against Foundation for every scalar and for every base with 13 kinds of
/// mark; only characters newer than either side's Unicode tables may differ.
fn tag_key(tag: &str) -> String {
    #[derive(PartialEq)]
    enum After {
        DropMarks,
        DropGeneric,
        KeepMarks,
    }
    let mut key = String::with_capacity(tag.len());
    let mut after = None;
    for character in tag.chars() {
        if after.is_some() && is_removable_mark(character) {
            let drop = match after {
                Some(After::DropMarks) => true,
                Some(After::DropGeneric) => is_generic_diacritic(character),
                _ => false,
            };
            if !drop {
                key.push_str(&fold(character));
            }
            continue;
        }
        let mut decomposed = std::iter::once(character).nfd();
        let base = decomposed.next().unwrap_or(character);
        let folded_base = fold(base);
        if folded_base.chars().next().is_some_and(|c| c < '\u{510}') {
            key.push_str(&folded_base);
            after = Some(After::DropMarks);
        } else {
            let folded = fold(character);
            if folded != character.to_string() {
                key.push_str(&folded);
                after = Some(After::KeepMarks);
            } else {
                key.push(character);
                after = Some(After::DropGeneric);
            }
        }
    }
    key.nfd().collect()
}
fn fold(character: char) -> String {
    if ('\u{1c80}'..='\u{1c88}').contains(&character) {
        return character.to_string();
    }
    character
        .to_string()
        .case_fold()
        .flat_map(char::to_lowercase)
        .collect()
}
/// Combining marks Foundation never removes: spacing vowel signs and similar
/// (General Category Mc without Grapheme_Extend), exported from Foundation.
const SPACING_MARKS: &[(u32, u32)] = &[
    (0x903, 0x903),
    (0x93b, 0x93b),
    (0x93e, 0x940),
    (0x949, 0x94c),
    (0x94e, 0x94f),
    (0x982, 0x983),
    (0x9bf, 0x9c0),
    (0x9c7, 0x9c8),
    (0x9cb, 0x9cc),
    (0xa03, 0xa03),
    (0xa3e, 0xa40),
    (0xa83, 0xa83),
    (0xabe, 0xac0),
    (0xac9, 0xac9),
    (0xacb, 0xacc),
    (0xb02, 0xb03),
    (0xb40, 0xb40),
    (0xb47, 0xb48),
    (0xb4b, 0xb4c),
    (0xbbf, 0xbbf),
    (0xbc1, 0xbc2),
    (0xbc6, 0xbc8),
    (0xbca, 0xbcc),
    (0xc01, 0xc03),
    (0xc41, 0xc44),
    (0xc82, 0xc83),
    (0xcbe, 0xcbe),
    (0xcc1, 0xcc1),
    (0xcc3, 0xcc4),
    (0xcf3, 0xcf3),
    (0xd02, 0xd03),
    (0xd3f, 0xd40),
    (0xd46, 0xd48),
    (0xd4a, 0xd4c),
    (0xd82, 0xd83),
    (0xdd0, 0xdd1),
    (0xdd8, 0xdde),
    (0xdf2, 0xdf3),
    (0xf3e, 0xf3f),
    (0xf7f, 0xf7f),
    (0x102b, 0x102c),
    (0x1031, 0x1031),
    (0x1038, 0x1038),
    (0x103b, 0x103c),
    (0x1056, 0x1057),
    (0x1062, 0x1064),
    (0x1067, 0x106d),
    (0x1083, 0x1084),
    (0x1087, 0x108c),
    (0x108f, 0x108f),
    (0x109a, 0x109c),
    (0x17b6, 0x17b6),
    (0x17be, 0x17c5),
    (0x17c7, 0x17c8),
    (0x1923, 0x1926),
    (0x1929, 0x192b),
    (0x1930, 0x1931),
    (0x1933, 0x1938),
    (0x1a19, 0x1a1a),
    (0x1a55, 0x1a55),
    (0x1a57, 0x1a57),
    (0x1a61, 0x1a61),
    (0x1a63, 0x1a64),
    (0x1a6d, 0x1a72),
    (0x1b04, 0x1b04),
    (0x1b3e, 0x1b41),
    (0x1b82, 0x1b82),
    (0x1ba1, 0x1ba1),
    (0x1ba6, 0x1ba7),
    (0x1be7, 0x1be7),
    (0x1bea, 0x1bec),
    (0x1bee, 0x1bee),
    (0x1c24, 0x1c2b),
    (0x1c34, 0x1c35),
    (0x1ce1, 0x1ce1),
    (0x1cf7, 0x1cf7),
    (0xa823, 0xa824),
    (0xa827, 0xa827),
    (0xa880, 0xa881),
    (0xa8b4, 0xa8c3),
    (0xa952, 0xa952),
    (0xa983, 0xa983),
    (0xa9b4, 0xa9b5),
    (0xa9ba, 0xa9bb),
    (0xa9be, 0xa9bf),
    (0xaa2f, 0xaa30),
    (0xaa33, 0xaa34),
    (0xaa4d, 0xaa4d),
    (0xaa7b, 0xaa7b),
    (0xaa7d, 0xaa7d),
    (0xaaeb, 0xaaeb),
    (0xaaee, 0xaaef),
    (0xaaf5, 0xaaf5),
    (0xabe3, 0xabe4),
    (0xabe6, 0xabe7),
    (0xabe9, 0xabea),
    (0xabec, 0xabec),
    (0x11000, 0x11000),
    (0x11002, 0x11002),
    (0x11082, 0x11082),
    (0x110b0, 0x110b2),
    (0x110b7, 0x110b8),
    (0x1112c, 0x1112c),
    (0x11145, 0x11146),
    (0x11182, 0x11182),
    (0x111b3, 0x111b5),
    (0x111bf, 0x111bf),
    (0x111ce, 0x111ce),
    (0x1122c, 0x1122e),
    (0x11232, 0x11233),
    (0x112e0, 0x112e2),
    (0x11302, 0x11303),
    (0x1133f, 0x1133f),
    (0x11341, 0x11344),
    (0x11347, 0x11348),
    (0x1134b, 0x1134c),
    (0x11362, 0x11363),
    (0x113b9, 0x113ba),
    (0x113ca, 0x113ca),
    (0x113cc, 0x113cd),
    (0x11435, 0x11437),
    (0x11440, 0x11441),
    (0x11445, 0x11445),
    (0x114b1, 0x114b2),
    (0x114b9, 0x114b9),
    (0x114bb, 0x114bc),
    (0x114be, 0x114be),
    (0x114c1, 0x114c1),
    (0x115b0, 0x115b1),
    (0x115b8, 0x115bb),
    (0x115be, 0x115be),
    (0x11630, 0x11632),
    (0x1163b, 0x1163c),
    (0x1163e, 0x1163e),
    (0x116ac, 0x116ac),
    (0x116ae, 0x116af),
    (0x1171e, 0x1171e),
    (0x11720, 0x11721),
    (0x11726, 0x11726),
    (0x1182c, 0x1182e),
    (0x11838, 0x11838),
    (0x11931, 0x11935),
    (0x11937, 0x11938),
    (0x11940, 0x11940),
    (0x11942, 0x11942),
    (0x119d1, 0x119d3),
    (0x119dc, 0x119df),
    (0x119e4, 0x119e4),
    (0x11a39, 0x11a39),
    (0x11a57, 0x11a58),
    (0x11a97, 0x11a97),
    (0x11b61, 0x11b61),
    (0x11b65, 0x11b65),
    (0x11b67, 0x11b67),
    (0x11c2f, 0x11c2f),
    (0x11c3e, 0x11c3e),
    (0x11ca9, 0x11ca9),
    (0x11cb1, 0x11cb1),
    (0x11cb4, 0x11cb4),
    (0x11d8a, 0x11d8e),
    (0x11d93, 0x11d94),
    (0x11d96, 0x11d96),
    (0x11ef5, 0x11ef6),
    (0x11f03, 0x11f03),
    (0x11f34, 0x11f35),
    (0x11f3e, 0x11f3f),
    (0x1612a, 0x1612c),
    (0x16f51, 0x16f87),
];
/// A mark the diacritic rules above may remove.
fn is_removable_mark(c: char) -> bool {
    is_combining_mark(c)
        && SPACING_MARKS
            .binary_search_by(|(low, high)| {
                if *high < c as u32 {
                    std::cmp::Ordering::Less
                } else if *low > c as u32 {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .is_err()
}
fn is_generic_diacritic(c: char) -> bool {
    matches!(c, '\u{0300}'..='\u{036f}' | '\u{0483}'..='\u{0489}')
}
