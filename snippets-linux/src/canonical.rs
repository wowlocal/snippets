//! Frozen snippets-wire-v1 JSON: UTF-8 key order, exact integer/double distinction,
//! minimal escaping, duplicate rejection and bounded parsing. No value has Debug.
use crate::model::{Error, Result};
use std::collections::{BTreeMap, HashSet};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

const INVALID: Error = Error("The synchronized record contains invalid canonical JSON.");
pub const MAX_BYTES: usize = crate::crypto::MAX_WIRE_PLAINTEXT;
fn append(output: &mut Vec<u8>, bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_BYTES.saturating_sub(output.len()) {
        return Err(INVALID);
    }
    let required = output.len() + bytes.len();
    if required > output.capacity() {
        let capacity = required
            .max(output.capacity().saturating_mul(2))
            .min(MAX_BYTES);
        // Never let Vec reallocate an existing plaintext buffer: resize by
        // copying into a new owner, then zero the old capacity before freeing it.
        let mut resized = Zeroizing::new(Vec::new());
        resized.try_reserve_exact(capacity).map_err(|_| INVALID)?;
        resized.extend_from_slice(output);
        std::mem::swap(output, &mut resized);
    }
    output.extend_from_slice(bytes);
    Ok(())
}
fn push(output: &mut Vec<u8>, byte: u8) -> Result<()> {
    append(output, &[byte])
}
#[derive(Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(Zeroizing<String>),
    Array(Vec<Value>),
    Object(BTreeMap<String, Value>),
}
impl Value {
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text(Zeroizing::new(text.into()))
    }
    pub fn as_text(&self) -> Result<&str> {
        if let Self::Text(text) = self {
            Ok(text)
        } else {
            Err(INVALID)
        }
    }
    pub fn as_bool(&self) -> Result<bool> {
        if let Self::Bool(value) = self {
            Ok(*value)
        } else {
            Err(INVALID)
        }
    }
    pub fn as_int(&self) -> Result<i64> {
        match self {
            Self::Int(value) => Ok(*value),
            _ => Err(INVALID),
        }
    }
    pub fn as_float(&self) -> Result<f64> {
        match self {
            Self::Int(value) => Ok(*value as f64),
            Self::Float(value) => Ok(*value),
            _ => Err(INVALID),
        }
    }
    pub fn as_array(&self) -> Result<&[Self]> {
        if let Self::Array(value) = self {
            Ok(value)
        } else {
            Err(INVALID)
        }
    }
    pub fn as_object(&self) -> Result<&BTreeMap<String, Self>> {
        if let Self::Object(value) = self {
            Ok(value)
        } else {
            Err(INVALID)
        }
    }
    pub fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        let mut output = Zeroizing::new(Vec::with_capacity(256));
        self.emit(&mut output, 0, &mut 0)?;
        Ok(output)
    }
    fn emit(&self, output: &mut Vec<u8>, depth: usize, nodes: &mut usize) -> Result<()> {
        *nodes += 1;
        if depth > 32 || *nodes > 100_000 {
            return Err(INVALID);
        }
        match self {
            Self::Null => append(output, b"null")?,
            Self::Bool(value) => append(output, if *value { b"true" } else { b"false" })?,
            Self::Int(value) => append(output, value.to_string().as_bytes())?,
            Self::Float(value) => append(output, swift_float(*value)?.as_bytes())?,
            Self::Text(text) => emit_string(text, output)?,
            Self::Array(values) => {
                push(output, b'[')?;
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        push(output, b',')?;
                    }
                    value.emit(output, depth + 1, nodes)?;
                }
                push(output, b']')?;
            }
            Self::Object(values) => {
                let mut normalized = HashSet::new();
                push(output, b'{')?;
                for (index, (key, value)) in values.iter().enumerate() {
                    if !normalized.insert(key.nfc().collect::<String>()) {
                        return Err(INVALID);
                    }
                    if index > 0 {
                        push(output, b',')?;
                    }
                    emit_string(key, output)?;
                    push(output, b':')?;
                    value.emit(output, depth + 1, nodes)?;
                }
                push(output, b'}')?;
            }
        }
        if output.len() > MAX_BYTES {
            return Err(INVALID);
        }
        Ok(())
    }
}
fn emit_string(text: &str, output: &mut Vec<u8>) -> Result<()> {
    const HEX: &[u8] = b"0123456789abcdef";
    push(output, b'"')?;
    for byte in text.bytes() {
        match byte {
            b'"' => append(output, b"\\\"")?,
            b'\\' => append(output, b"\\\\")?,
            8 => append(output, b"\\b")?,
            9 => append(output, b"\\t")?,
            10 => append(output, b"\\n")?,
            12 => append(output, b"\\f")?,
            13 => append(output, b"\\r")?,
            0..=31 => {
                append(output, b"\\u00")?;
                push(output, HEX[(byte / 16) as usize])?;
                push(output, HEX[(byte % 16) as usize])?;
            }
            byte => push(output, byte)?,
        }
        if output.len() > MAX_BYTES {
            return Err(INVALID);
        }
    }
    push(output, b'"')?;
    Ok(())
}
/// Swift's shortest round-trip digits, with its fixed/scientific thresholds and
/// signed, minimum-two-digit exponent. Ryu supplies the nearest shortest digits.
fn swift_float(value: f64) -> Result<String> {
    if !value.is_finite() {
        return Err(INVALID);
    }
    let mut buffer = ryu::Buffer::new();
    let printed = buffer.format_finite(value);
    let (sign, magnitude) = printed
        .strip_prefix('-')
        .map_or(("", printed), |v| ("-", v));
    let (mantissa, exponent) = magnitude.split_once('e').map_or((magnitude, 0), |(m, e)| {
        (m, e.parse::<i32>().expect("Ryu exponent"))
    });
    let point = mantissa.find('.').unwrap_or(mantissa.len()) as i32;
    let mut digits = mantissa.replace('.', "");
    let leading = digits.bytes().take_while(|b| *b == b'0').count();
    if leading == digits.len() {
        return Ok(format!("{sign}0.0"));
    }
    digits.drain(..leading);
    while digits.ends_with('0') {
        digits.pop();
    }
    let order = point + exponent - leading as i32 - 1;
    if order < -4 || value.abs() > 9_007_199_254_740_992.0 {
        let fraction = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        return Ok(format!(
            "{sign}{}{fraction}e{}{:02}",
            &digits[..1],
            if order < 0 { "-" } else { "+" },
            order.unsigned_abs()
        ));
    }
    let point = order + 1;
    Ok(if point <= 0 {
        format!("{sign}0.{}{}", "0".repeat((-point) as usize), digits)
    } else if point as usize >= digits.len() {
        format!(
            "{sign}{}{}.0",
            digits,
            "0".repeat(point as usize - digits.len())
        )
    } else {
        format!(
            "{sign}{}.{}",
            &digits[..point as usize],
            &digits[point as usize..]
        )
    })
}
pub fn parse(bytes: &[u8]) -> Result<Value> {
    if bytes.len() > MAX_BYTES || std::str::from_utf8(bytes).is_err() {
        return Err(INVALID);
    }
    let mut parser = Parser {
        bytes,
        position: 0,
        nodes: 0,
    };
    let value = parser.value(0)?;
    parser.whitespace();
    if parser.position != bytes.len() {
        return Err(INVALID);
    }
    Ok(value)
}
// Parse number lexemes directly: serde_json deliberately treats integer "-0"
// as floating-point negative zero; Swift's frozen codec treats it as Int64(0).
// Strings are decoded into zeroizing buffers without a nonzeroizing scratch copy.
struct Parser<'a> {
    bytes: &'a [u8],
    position: usize,
    nodes: usize,
}
impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.position).copied()
    }
    fn whitespace(&mut self) {
        while self.peek().is_some_and(|b| b" \t\r\n".contains(&b)) {
            self.position += 1;
        }
    }
    fn consume(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.position += 1;
            true
        } else {
            false
        }
    }
    fn require(&mut self, byte: u8) -> Result<()> {
        if self.consume(byte) {
            Ok(())
        } else {
            Err(INVALID)
        }
    }
    fn literal(&mut self, text: &[u8], value: Value) -> Result<Value> {
        if !self.bytes[self.position..].starts_with(text) {
            return Err(INVALID);
        }
        self.position += text.len();
        Ok(value)
    }
    fn value(&mut self, depth: usize) -> Result<Value> {
        self.nodes += 1;
        if depth > 32 || self.nodes > 100_000 {
            return Err(INVALID);
        }
        self.whitespace();
        match self.peek().ok_or(INVALID)? {
            b'n' => self.literal(b"null", Value::Null),
            b't' => self.literal(b"true", Value::Bool(true)),
            b'f' => self.literal(b"false", Value::Bool(false)),
            b'"' => self.string().map(Value::Text),
            b'[' => {
                self.position += 1;
                self.whitespace();
                let mut values = Vec::new();
                if !self.consume(b']') {
                    loop {
                        values.push(self.value(depth + 1)?);
                        self.whitespace();
                        if self.consume(b']') {
                            break;
                        }
                        self.require(b',')?;
                    }
                }
                Ok(Value::Array(values))
            }
            b'{' => {
                self.position += 1;
                self.whitespace();
                let mut values = BTreeMap::new();
                let mut normalized = HashSet::new();
                if !self.consume(b'}') {
                    loop {
                        self.whitespace();
                        let mut key = self.string()?;
                        if !normalized.insert(key.nfc().collect::<String>()) {
                            return Err(INVALID);
                        }
                        self.whitespace();
                        self.require(b':')?;
                        let value = self.value(depth + 1)?;
                        values.insert(std::mem::take(&mut *key), value);
                        self.whitespace();
                        if self.consume(b'}') {
                            break;
                        }
                        self.require(b',')?;
                    }
                }
                Ok(Value::Object(values))
            }
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(INVALID),
        }
    }
    fn number(&mut self) -> Result<Value> {
        let start = self.position;
        self.consume(b'-');
        if !self.consume(b'0') {
            if !self.peek().is_some_and(|b| (b'1'..=b'9').contains(&b)) {
                return Err(INVALID);
            }
            while self.peek().is_some_and(|b| b.is_ascii_digit()) {
                self.position += 1;
            }
        }
        let mut float = false;
        if self.consume(b'.') {
            float = true;
            if !self.peek().is_some_and(|b| b.is_ascii_digit()) {
                return Err(INVALID);
            }
            while self.peek().is_some_and(|b| b.is_ascii_digit()) {
                self.position += 1;
            }
        }
        if self.consume(b'e') || self.consume(b'E') {
            float = true;
            if !self.consume(b'+') {
                self.consume(b'-');
            }
            if !self.peek().is_some_and(|b| b.is_ascii_digit()) {
                return Err(INVALID);
            }
            while self.peek().is_some_and(|b| b.is_ascii_digit()) {
                self.position += 1;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.position]).map_err(|_| INVALID)?;
        if float {
            let value = text.parse::<f64>().map_err(|_| INVALID)?;
            if !value.is_finite() {
                return Err(INVALID);
            }
            Ok(Value::Float(value))
        } else {
            text.parse::<i64>().map(Value::Int).map_err(|_| INVALID)
        }
    }
    fn hex4(&mut self) -> Result<u32> {
        let mut value = 0;
        for _ in 0..4 {
            let byte = self.peek().ok_or(INVALID)?;
            self.position += 1;
            let digit = match byte {
                b'0'..=b'9' => byte - b'0',
                b'a'..=b'f' => byte - b'a' + 10,
                b'A'..=b'F' => byte - b'A' + 10,
                _ => return Err(INVALID),
            };
            value = (value << 4) | u32::from(digit);
        }
        Ok(value)
    }
    fn string(&mut self) -> Result<Zeroizing<String>> {
        self.require(b'"')?;
        let mut end = self.position;
        loop {
            match self.bytes.get(end).ok_or(INVALID)? {
                b'"' => break,
                b'\\' => end += 2,
                _ => end += 1,
            }
        }
        let mut output = Zeroizing::new(String::with_capacity(end - self.position));
        while self.position < end {
            let byte = self.peek().ok_or(INVALID)?;
            if byte == b'\\' {
                self.position += 1;
                let escape = self.peek().ok_or(INVALID)?;
                self.position += 1;
                let scalar = match escape {
                    b'"' => '"',
                    b'\\' => '\\',
                    b'/' => '/',
                    b'b' => '\u{08}',
                    b'f' => '\u{0c}',
                    b'n' => '\n',
                    b'r' => '\r',
                    b't' => '\t',
                    b'u' => {
                        let mut scalar = self.hex4()?;
                        if (0xd800..=0xdbff).contains(&scalar) {
                            self.require(b'\\')?;
                            self.require(b'u')?;
                            let low = self.hex4()?;
                            if !(0xdc00..=0xdfff).contains(&low) {
                                return Err(INVALID);
                            }
                            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
                        }
                        char::from_u32(scalar).ok_or(INVALID)?
                    }
                    _ => return Err(INVALID),
                };
                output.push(scalar);
            } else {
                let start = self.position;
                while self.position < end && self.bytes[self.position] != b'\\' {
                    if self.bytes[self.position] < 32 {
                        return Err(INVALID);
                    }
                    self.position += 1;
                }
                output.push_str(
                    std::str::from_utf8(&self.bytes[start..self.position]).map_err(|_| INVALID)?,
                );
            }
        }
        self.require(b'"')?;
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn small_wire_json_does_not_allocate_or_erase_a_maximum_size_buffer() {
        let input = Value::Object(BTreeMap::from([
            (
                "content".into(),
                Value::text("Public small canonical fixture"),
            ),
            ("escaped".into(), Value::text("\n".repeat(300))),
        ]));
        let encoded = input.encode().unwrap();
        assert!(encoded.capacity() <= 4096);
        assert!(encoded.capacity() >= encoded.len());
        assert!(parse(&encoded).unwrap() == input);
        assert!(
            encoded
                .starts_with(b"{\"content\":\"Public small canonical fixture\",\"escaped\":\"\\n")
        );
    }
    #[test]
    fn resized_output_keeps_the_exact_wire_ceiling_including_escape_expansion() {
        let input = Value::text("x".repeat(MAX_BYTES - 2));
        let encoded = input.encode().unwrap();
        assert_eq!(encoded.len(), MAX_BYTES);
        assert!(parse(&encoded).unwrap() == input);
        assert!(Value::text("x".repeat(MAX_BYTES - 1)).encode().is_err());
        assert!(
            Value::text("\0".repeat(MAX_BYTES / 6 + 1))
                .encode()
                .is_err()
        );
    }
    #[test]
    fn escaping_key_order_duplicates_and_depth_match_the_contract() {
        let raw = "{\"𐀀\":1,\"\u{e000}\":2,\"ascii\":\"a/β\\u0001\\n\\t\\b\\f\\r\\\\\\\"\"}";
        let encoded = parse(raw.as_bytes()).unwrap().encode().unwrap();
        assert!(encoded.starts_with(b"{\"ascii\":"));
        let text = std::str::from_utf8(&encoded).unwrap();
        assert!(
            text.find('\u{e000}').unwrap() < text.find('𐀀').unwrap() && text.contains("a/β\\u0001")
        );
        for raw in [
            "{\"a\":1,\"a\":2}",
            "{\"é\":1,\"é\":2}",
            "{\"a\":1} null",
            "\"\\ud800\"",
            "9223372036854775808",
            "184467440737095516160",
            "1e400",
        ] {
            assert!(parse(raw.as_bytes()).is_err());
        }
        assert!(parse(format!("{}0{}", "[".repeat(33), "]".repeat(33)).as_bytes()).is_err());
    }
    #[test]
    fn float_spelling_preserves_negative_zero_and_swift_thresholds() {
        for (value, text) in [
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (1.0, "1.0"),
            (1e-4, "0.0001"),
            (1e-5, "1e-05"),
            (1e15, "1000000000000000.0"),
            (1e16, "1e+16"),
            (f64::from_bits(1), "5e-324"),
        ] {
            assert!(swift_float(value).unwrap() == text);
        }
        let mut bits = 0x1234_5678_9abc_def0_u64;
        for _ in 0..10_000 {
            bits ^= bits << 13;
            bits ^= bits >> 7;
            bits ^= bits << 17;
            let value = f64::from_bits(bits);
            if value.is_finite() {
                let encoded = swift_float(value).unwrap();
                let parsed = parse(encoded.as_bytes()).unwrap().as_float().unwrap();
                assert!(value.to_bits() == parsed.to_bits());
            }
        }
        assert!(Value::Float(f64::NAN).encode().is_err());
    }
    #[test]
    fn independent_swift_runtime_reference_matches_every_float_byte() {
        // Public numeric values generated by the Swift 6.2 runtime's C99 formatter,
        // not by this implementation. Provenance is in tests/fixtures/README.md.
        for line in include_str!("../tests/fixtures/swift-double-v1.tsv").lines() {
            let (bits, expected) = line.split_once('\t').unwrap();
            let value = f64::from_bits(u64::from_str_radix(bits, 16).unwrap());
            assert_eq!(swift_float(value).unwrap(), expected, "public bits {bits}");
            assert_eq!(
                parse(expected.as_bytes())
                    .unwrap()
                    .as_float()
                    .unwrap()
                    .to_bits(),
                value.to_bits()
            );
        }
    }
    #[test]
    fn integer_negative_zero_unicode_and_hostile_lexemes_keep_the_frozen_grammar() {
        assert!(matches!(parse(b"-0").unwrap(), Value::Int(0)));
        assert!(
            matches!(parse(b"-0.0").unwrap(),Value::Float(f) if f.to_bits()==(-0.0_f64).to_bits())
        );
        assert!(parse(b"-9223372036854775808").unwrap().as_int().unwrap() == i64::MIN);
        assert!(parse(b"9223372036854775807").unwrap().as_int().unwrap() == i64::MAX);
        for escaped in [
            r#""\ud800\udc00""#,
            r#""\udbff\udfff""#,
            r#""\u0065\u0301""#,
            r#""\/\b\f\n\r\t\u0000\u001f""#,
        ] {
            let reference: String = serde_json::from_str(escaped).unwrap();
            assert!(parse(escaped.as_bytes()).unwrap().as_text().unwrap() == reference);
        }
        for raw in [
            "[null,]",
            "{\"a\":1,}",
            "[01]",
            "[1.e0]",
            "1e+-1",
            "-.1",
            "+1",
            "[truefalse]",
            "\"unterminated\\",
            r#""\udc00""#,
            r#""\ud800\u0041""#,
            r#""\u12""#,
            r#""\x00""#,
            "-9223372036854775809",
        ] {
            assert!(parse(raw.as_bytes()).is_err());
        }
        for raw in [
            &b"\"\xc0\xaf\""[..],
            &b"\"\xed\xa0\x80\""[..],
            &b"\"\0\""[..],
            &b"\xff"[..],
        ] {
            assert!(parse(raw).is_err());
        }
        assert!(parse(format!("{}0{}", "[".repeat(32), "]".repeat(32)).as_bytes()).is_ok());
        assert!(parse(format!("[{}null]", "null,".repeat(100_000)).as_bytes()).is_err());
        assert!(
            Value::text("\u{0001}".repeat(MAX_BYTES / 2))
                .encode()
                .is_err()
        );
    }
}
