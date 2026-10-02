//! The frozen 12hex-4hex-8hex HLC, with a random installation identity.
use crate::{
    crypto,
    model::{Error, Result, atomic_write, read_regular},
};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::path::Path;
use std::time::Duration;
const LIMIT: u64 = 0xffff_ffff_ffff;

/// Linux's suspend-aware monotonic clock. Vault lifetimes must include sleep;
/// wall-clock adjustments must not prolong them.
pub(crate) fn uptime() -> Option<Duration> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut value) } != 0
        || value.tv_sec < 0
        || !(0..1_000_000_000).contains(&value.tv_nsec)
    {
        return None;
    }
    Some(Duration::new(value.tv_sec as u64, value.tv_nsec as u32))
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Hlc {
    wall: u64,
    counter: u16,
    device: String,
}
impl Hlc {
    pub fn parse(text: &str) -> Result<Self> {
        let bytes = text.as_bytes();
        if bytes.len() != 26
            || bytes[12] != b'-'
            || bytes[17] != b'-'
            || bytes.iter().enumerate().any(|(i, b)| {
                i != 12 && i != 17 && !b.is_ascii_digit() && !(b'a'..=b'f').contains(b)
            })
        {
            return Err(Error("The record has an invalid logical clock."));
        }
        Ok(Self {
            wall: u64::from_str_radix(&text[..12], 16).expect("checked hex"),
            counter: u16::from_str_radix(&text[13..17], 16).expect("checked hex"),
            device: text[18..].into(),
        })
    }
    pub fn text(&self) -> String {
        format!("{:012x}-{:04x}-{}", self.wall, self.counter, self.device)
    }
    pub(crate) fn device(&self) -> &str {
        &self.device
    }
    pub fn foreign(wall: u64) -> Self {
        Self {
            wall: wall.min(LIMIT),
            counter: 0,
            device: "00000000".into(),
        }
    }
    pub(crate) fn projected(
        wall: u64,
        stored: Option<&Self>,
        ancestor: Option<&Self>,
        device: &str,
    ) -> Result<Self> {
        if !crate::wire::device(device) || device == "00000000" || wall > LIMIT {
            return Err(Error("The installation has an invalid logical clock."));
        }
        if let Some(stored) = stored
            && stored.device == device
            && ancestor.is_none_or(|a| stored > a)
        {
            return Ok(stored.clone());
        }
        let floor = ancestor.map_or(0, |a| a.wall.saturating_add(1).min(LIMIT));
        let wall = wall.max(floor);
        let counter = if let Some(a) = ancestor.filter(|a| a.wall == wall) {
            a.counter
                .checked_add(1)
                .ok_or(Error("The installation logical clock is exhausted."))?
        } else {
            0
        };
        Ok(Self {
            wall,
            counter,
            device: device.into(),
        })
    }
}
impl Serialize for Hlc {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.text())
    }
}
impl<'de> Deserialize<'de> for Hlc {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        Self::parse(&String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Installation {
    schema_version: u8,
    #[serde(rename = "deviceID")]
    device_id: String,
    #[serde(rename = "lastHLC")]
    last_hlc: Hlc,
}
/// Caller holds the library's common process lock. Reserving a clock before the
/// data write can leave a gap after failure, but can never reissue a timestamp.
pub(crate) fn stamp(root: &Path, base: Option<&Hlc>, now: u64) -> Result<Hlc> {
    Ok(stamp_many(root, &[(base, now)])?.remove(0))
}
/// Reserve ordered clocks in one durable write before any batch primary
/// publication. Validation failure changes no high-water mark; a failed durable
/// write may leave an unused gap, never a returned clock that can be reissued.
pub(crate) fn stamp_many(root: &Path, requests: &[(Option<&Hlc>, u64)]) -> Result<Vec<Hlc>> {
    if requests.is_empty() {
        return Ok(Vec::new());
    }
    if requests.len() > crate::model::MAX_SNIPPETS {
        return Err(Error("The logical clock batch exceeds the library limit."));
    }
    let now = requests[0].1;
    let path = root.join("device.json");
    let mut installation = if let Some(data) = read_regular(&path)? {
        let value: Installation = serde_json::from_slice(&data)
            .map_err(|_| Error("The installation clock could not be read safely."))?;
        if value.schema_version != 1
            || value.device_id.len() != 8
            || value.device_id == "00000000"
            || !value
                .device_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || value.last_hlc.device != value.device_id
        {
            return Err(Error("The installation clock could not be read safely."));
        }
        value
    } else {
        let device = format!("{:08x}", u32::from_be_bytes(crypto::random()?).max(1));
        Installation {
            schema_version: 1,
            device_id: device.clone(),
            last_hlc: Hlc {
                wall: now.min(LIMIT),
                counter: 0,
                device,
            },
        }
    };
    let mut result = Vec::with_capacity(requests.len());
    for (base, now) in requests {
        let base_floor = base.map_or(0, |v| v.wall.saturating_add(1));
        let floor = (*now).max(base_floor);
        let (wall, counter) = if floor > installation.last_hlc.wall {
            (floor, 0)
        } else if installation.last_hlc.counter == u16::MAX {
            (installation.last_hlc.wall + 1, 0)
        } else {
            (
                installation.last_hlc.wall,
                installation.last_hlc.counter + 1,
            )
        };
        if wall > LIMIT {
            return Err(Error("The logical clock cannot advance safely."));
        }
        let value = Hlc {
            wall,
            counter,
            device: installation.device_id.clone(),
        };
        installation.last_hlc = value.clone();
        result.push(value);
    }
    atomic_write(
        &path,
        &serde_json::to_vec_pretty(&installation)
            .map_err(|_| Error("The installation clock could not be encoded."))?,
    )?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restarts_backwards_clocks_and_ancestor_stamps_never_reissue_a_value() {
        let directory = tempfile::tempdir().unwrap();
        let first = stamp(directory.path(), None, 1000).unwrap();
        let second = stamp(directory.path(), None, 1000).unwrap();
        assert!(second > first);
        let third = stamp(directory.path(), None, 900).unwrap();
        assert!(third > second);
        let ancestor = Hlc::parse("000000000fff-ffff-ffffffff").unwrap();
        let fourth = stamp(directory.path(), Some(&ancestor), 900).unwrap();
        assert!(fourth > ancestor);
        assert!(fourth.device == first.device && first.device != "00000000");
        assert!(Hlc::parse(&fourth.text()).unwrap() == fourth);
    }
    #[test]
    fn counter_carries_and_invalid_or_exhausted_clocks_fail_closed() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("device.json");
        std::fs::write(
            &path,
            br#"{"schemaVersion":1,"deviceID":"1234abcd","lastHLC":"000000000100-ffff-1234abcd"}"#,
        )
        .unwrap();
        let clock = stamp(directory.path(), None, 100).unwrap();
        assert!(clock.wall == 257 && clock.counter == 0);
        for raw in [
            "000000000100-FFFF-1234abcd",
            "000000000100-0000-1234ABCd",
            "bad",
            "000000000100-0000-1234abcdx",
        ] {
            assert!(Hlc::parse(raw).is_err());
        }
        std::fs::write(&path, b"{truncated").unwrap();
        assert!(stamp(directory.path(), None, 900).is_err());
        assert!(Hlc::parse("ffffffffffff-ffff-ffffffff").is_ok());
        std::fs::write(
            &path,
            br#"{"schemaVersion":1,"deviceID":"1234abcd","lastHLC":"ffffffffffff-ffff-1234abcd"}"#,
        )
        .unwrap();
        let before = std::fs::read(&path).unwrap();
        assert!(stamp(directory.path(), None, 0).is_err());
        assert!(std::fs::read(&path).unwrap() == before);
    }
    #[test]
    fn batch_reserves_ordered_carries_and_ancestor_floors_before_restart() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("device.json");
        std::fs::write(
            &path,
            br#"{"schemaVersion":1,"deviceID":"1234abcd","lastHLC":"000000000100-ffff-1234abcd"}"#,
        )
        .unwrap();
        let ancestor = Hlc::parse("000000000fff-ffff-ffffffff").unwrap();
        let values = stamp_many(
            directory.path(),
            &[(None, 100), (None, 300), (Some(&ancestor), 50), (None, 50)],
        )
        .unwrap();
        assert!(
            values.iter().map(Hlc::text).collect::<Vec<_>>()
                == [
                    "000000000101-0000-1234abcd",
                    "00000000012c-0000-1234abcd",
                    "000000001000-0000-1234abcd",
                    "000000001000-0001-1234abcd",
                ]
        );
        let stored: Installation = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert!(stored.last_hlc == *values.last().unwrap());
        assert!(stamp(directory.path(), None, 0).unwrap() > *values.last().unwrap());
    }
    #[test]
    fn batch_exhaustion_returns_no_partial_reservation_and_empty_batch_creates_nothing() {
        let directory = tempfile::tempdir().unwrap();
        assert!(stamp_many(directory.path(), &[]).unwrap().is_empty());
        let path = directory.path().join("device.json");
        assert!(!path.exists());
        stamp(directory.path(), None, 100).unwrap();
        let before = std::fs::read(&path).unwrap();
        let exhausted = Hlc::parse("ffffffffffff-ffff-ffffffff").unwrap();
        assert!(stamp_many(directory.path(), &[(None, 500), (Some(&exhausted), 0)]).is_err());
        assert!(std::fs::read(&path).unwrap() == before);
        assert!(
            stamp_many(
                directory.path(),
                &vec![(None, 0); crate::model::MAX_SNIPPETS + 1]
            )
            .is_err()
        );
        assert!(std::fs::read(&path).unwrap() == before);
    }
}
