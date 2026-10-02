//! Exact encrypted offers and positional receipts, owned by the checkpoint.
use crate::{
    cloud::{ErrorCode, RecordVersion},
    journal::{Failure, Offered, Result},
    merge,
    wire::WireRecord,
};
#[derive(Clone, PartialEq)]
pub(crate) struct Transmission {
    pub offered: Offered,
    pub wire: WireRecord,
    pub deletion_authorized: bool,
}
#[derive(Clone, PartialEq)]
pub(crate) enum Receipt {
    Accepted(RecordVersion),
    Conflict {
        wire: WireRecord,
        version: RecordVersion,
    },
    Rejected {
        code: ErrorCode,
        retry_after: Option<u32>,
    },
}
#[derive(Clone, PartialEq)]
pub(crate) struct Packet {
    pub key_epoch: u64,
    pub offers: Vec<Transmission>,
    pub receipts: Option<Vec<Receipt>>,
    pub received_at: Option<u64>,
    pub position: usize,
}
impl Packet {
    pub fn validate(&self) -> Result<()> {
        if self.key_epoch == 0
            || self.key_epoch > i64::MAX as u64
            || self.offers.is_empty()
            || self.offers.len() > crate::inbound::PAGE_LIMIT
            || self.position > self.offers.len()
            || self.receipts.is_none() && self.position != 0
            || self.receipts.is_some() != self.received_at.is_some()
            || self.received_at == Some(0)
        {
            return Err(Failure::InvalidState);
        }
        let mut ids = std::collections::BTreeSet::new();
        for offer in &self.offers {
            merge::validate(&offer.offered.envelope)?;
            offer.wire.validate().map_err(|_| Failure::InvalidState)?;
            if !ids.insert(offer.wire.id)
                || offer.offered.generation == 0
                || offer.wire.id != offer.offered.envelope.id
                || offer.wire.deleted != offer.offered.envelope.deleted
                || offer.wire.rev != offer.offered.envelope.hash()?[..32]
                || (offer.deletion_authorized && !offer.offered.envelope.deleted)
            {
                return Err(Failure::InvalidState);
            }
            if let Some(version) = &offer.offered.record_version {
                version.validate().map_err(|_| Failure::InvalidState)?;
            }
        }
        if let Some(receipts) = &self.receipts {
            if receipts.len() != self.offers.len() {
                return Err(Failure::InvalidState);
            }
            for (offer, receipt) in self.offers.iter().zip(receipts) {
                match receipt {
                    Receipt::Accepted(version) => {
                        version.validate().map_err(|_| Failure::InvalidState)?
                    }
                    Receipt::Conflict { wire, version } => {
                        wire.validate().map_err(|_| Failure::InvalidState)?;
                        version.validate().map_err(|_| Failure::InvalidState)?;
                        if wire.id != offer.wire.id {
                            return Err(Failure::InvalidState);
                        }
                    }
                    Receipt::Rejected { retry_after, .. } => {
                        if retry_after.is_some_and(|s| !(1..=86400).contains(&s)) {
                            return Err(Failure::InvalidState);
                        }
                    }
                }
            }
        }
        Ok(())
    }
    pub fn cooldown(&self, now: u64) -> Result<Option<(ErrorCode, u32)>> {
        let Some(receipts) = &self.receipts else {
            return Ok(None);
        };
        let received = self.received_at.ok_or(Failure::InvalidState)?;
        let delay = receipts
            .iter()
            .filter_map(|receipt| match receipt {
                Receipt::Rejected {
                    code,
                    retry_after: Some(seconds),
                } => Some((*code, *seconds)),
                _ => None,
            })
            .max_by_key(|(_, seconds)| *seconds);
        if let Some((code, seconds)) = delay {
            let deadline = received
                .checked_add(u64::from(seconds) * 1000)
                .ok_or(Failure::InvalidState)?;
            if now < deadline {
                return Ok(Some((
                    code,
                    u32::try_from((deadline - now).div_ceil(1000).min(86400))
                        .map_err(|_| Failure::InvalidState)?,
                )));
            }
        }
        Ok(None)
    }
    pub fn acknowledged(&self) -> bool {
        self.receipts.is_some() && self.position == self.offers.len()
    }
}
