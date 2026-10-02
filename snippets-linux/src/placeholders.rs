//! The established one-pass placeholder grammar, rendered by native ICU.
use chrono::{DateTime, Duration, Local, Months};
use regex::Regex;
use std::{collections::HashMap, ffi::CString, sync::OnceLock};
use zeroize::Zeroizing;

unsafe extern "C" {
    fn snippets_format_date(
        millis: f64,
        kind: i32,
        locale: *const libc::c_char,
        pattern: *const u16,
        pattern_len: i32,
        output: *mut u16,
        capacity: i32,
    ) -> i32;
}
fn render(
    now: DateTime<Local>,
    kind: &str,
    pattern: Option<&str>,
    locale: Option<&str>,
) -> Option<String> {
    let pattern = Zeroizing::new(pattern.unwrap_or("").encode_utf16().collect::<Vec<_>>());
    let locale = locale.map(CString::new).transpose().ok()?;
    let mut output = Zeroizing::new([0u16; 4096]);
    // All buffers remain alive through this synchronous C call; the shim reads
    // only the declared pattern length and writes within output's capacity.
    let length = unsafe {
        snippets_format_date(
            now.timestamp_millis() as f64,
            match kind {
                "date" => 0,
                "time" => 1,
                _ => 2,
            },
            locale.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()),
            pattern.as_ptr(),
            pattern.len() as i32,
            output.as_mut_ptr(),
            output.len() as i32,
        )
    };
    if length < 0 || length as usize >= output.len() {
        return None;
    }
    String::from_utf16(&output[..length as usize]).ok()
}
fn offset(mut now: DateTime<Local>, value: &str) -> Option<DateTime<Local>> {
    static TERM: OnceLock<Regex> = OnceLock::new();
    let regex = TERM.get_or_init(|| Regex::new(r"^([+-]\d+)([mhdMy])$").expect("static pattern"));
    let terms: Vec<_> = value.split_whitespace().collect();
    if terms.is_empty() || terms.len() > 8 {
        return None;
    }
    for term in terms {
        let capture = regex.captures(term)?;
        let amount = capture[1].parse::<i64>().ok()?;
        if amount.unsigned_abs() > 100_000 {
            return None;
        }
        now = match &capture[2] {
            "m" => now.checked_add_signed(Duration::minutes(amount))?,
            "h" => now.checked_add_signed(Duration::hours(amount))?,
            "d" => now.checked_add_signed(Duration::days(amount))?,
            unit => {
                let months =
                    Months::new((amount.unsigned_abs() * if unit == "y" { 12 } else { 1 }) as u32);
                if amount >= 0 {
                    now.checked_add_months(months)?
                } else {
                    now.checked_sub_months(months)?
                }
            }
        };
    }
    Some(now)
}
fn token(value: &str, clipboard: &str, now: DateTime<Local>) -> Option<String> {
    if value == "clipboard" {
        return Some(clipboard.into());
    }
    static TOKEN: OnceLock<Regex> = OnceLock::new();
    static ATTR: OnceLock<Regex> = OnceLock::new();
    static LOCALE: OnceLock<Regex> = OnceLock::new();
    let parsed = TOKEN
        .get_or_init(|| {
            Regex::new(r"^(date|time|datetime)(?::([A-Za-z0-9:_-]{1,512})|( .{1,1024}))?$")
                .expect("static pattern")
        })
        .captures(value)?;
    let kind = parsed.get(1)?.as_str();
    let mut pattern = parsed.get(2).map(|v| v.as_str());
    let mut locale = None;
    let mut calendar_offset = None;
    if let Some(attributes) = parsed.get(3) {
        let regex = ATTR.get_or_init(|| {
            Regex::new(r#"^(format|locale|offset)=(?:"([^"\r\n]*)"|([^ "\r\n]+))(?: +|$)"#)
                .expect("static pattern")
        });
        let mut tail = attributes.as_str().trim();
        let mut fields = HashMap::new();
        while !tail.is_empty() {
            let attr = regex.captures(tail)?;
            let key = attr.get(1)?.as_str();
            let value = attr.get(2).or_else(|| attr.get(3))?.as_str();
            if fields.insert(key, value).is_some() {
                return None;
            }
            tail = &tail[attr.get(0)?.end()..];
        }
        pattern = fields.get("format").copied();
        locale = fields.get("locale").copied();
        calendar_offset = fields.get("offset").copied();
        if pattern.is_some_and(|p| p.is_empty() || p.len() > 512)
            || pattern.is_some() && locale.is_some()
        {
            return None;
        }
        if locale.is_some_and(|v| {
            !LOCALE
                .get_or_init(|| {
                    Regex::new(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$").expect("static pattern")
                })
                .is_match(v)
        }) {
            return None;
        }
    }
    let now = if let Some(offset_value) = calendar_offset {
        offset(now, offset_value)?
    } else {
        now
    };
    render(now, kind, pattern, locale)
}
pub fn resolve_at(template: &str, clipboard: &str, now: DateTime<Local>) -> String {
    static BRACES: OnceLock<Regex> = OnceLock::new();
    BRACES
        .get_or_init(|| Regex::new(r"\{([^{}\r\n]*)\}").expect("static pattern"))
        .replace_all(template, |capture: &regex::Captures<'_>| {
            token(&capture[1], clipboard, now).unwrap_or_else(|| capture[0].into())
        })
        .into_owned()
}
pub fn resolve(template: &str, clipboard: &str) -> String {
    resolve_at(template, clipboard, Local::now())
}
/// One-pass secure resolution uses owned wipeable buffers and checks growth
/// before each append. Regex captures borrow the template; no body enters caches.
#[cfg(any(test, feature = "desktop"))]
pub(crate) fn resolve_sensitive_at(
    template: &str,
    clipboard: &str,
    now: DateTime<Local>,
) -> crate::model::Result<Zeroizing<String>> {
    let regex = Regex::new(r"\{([^{}\r\n]*)\}").expect("static pattern");
    let mut result = Zeroizing::new(String::new());
    let mut previous = 0;
    let append = |result: &mut String, value: &str| -> crate::model::Result<()> {
        if result
            .len()
            .checked_add(value.len())
            .is_none_or(|n| n > crate::model::MAX_BODY_BYTES)
        {
            return Err(crate::model::Error(
                "Resolved secure text is too large to insert.",
            ));
        }
        result.push_str(value);
        Ok(())
    };
    for capture in regex.captures_iter(template) {
        let whole = capture.get(0).expect("whole match");
        append(&mut result, &template[previous..whole.start()])?;
        if let Some(value) = token(&capture[1], clipboard, now) {
            let value = Zeroizing::new(value);
            append(&mut result, &value)?;
        } else {
            append(&mut result, whole.as_str())?;
        }
        previous = whole.end();
    }
    append(&mut result, &template[previous..])?;
    Ok(result)
}
