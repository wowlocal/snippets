//! A public invitation's display/poll lifetime. Repeated status replies cannot
//! extend it, including when wall time moves backwards or the machine suspends.
use crate::bootstrap::Invitation;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub(crate) struct Countdown {
    pairing: Uuid,
    wall: SystemTime,
    uptime: Duration,
    next_poll: Duration,
}
impl Countdown {
    pub(crate) fn new(invitation: &Invitation) -> Option<Self> {
        Self::at(invitation, SystemTime::now(), crate::clock::uptime()?)
    }
    fn at(invitation: &Invitation, wall: SystemTime, uptime: Duration) -> Option<Self> {
        let expiry = UNIX_EPOCH.checked_add(Duration::from_secs(
            invitation.expires_at().try_into().ok()?,
        ))?;
        let remaining = expiry
            .duration_since(wall)
            .unwrap_or_default()
            .min(Duration::from_secs(630));
        Some(Self {
            pairing: invitation.pairing(),
            wall: expiry,
            uptime: uptime.checked_add(remaining)?,
            next_poll: uptime.checked_add(Duration::from_secs(2))?,
        })
    }
    pub(crate) fn matches(&self, invitation: &Invitation) -> bool {
        self.pairing == invitation.pairing()
    }
    fn remaining_at(&self, wall: SystemTime, uptime: Duration) -> Duration {
        self.wall
            .duration_since(wall)
            .unwrap_or_default()
            .min(self.uptime.saturating_sub(uptime))
    }
    pub(crate) fn remaining(&self) -> Duration {
        crate::clock::uptime().map_or(Duration::ZERO, |u| self.remaining_at(SystemTime::now(), u))
    }
    pub(crate) fn poll_due(&mut self) -> bool {
        let Some(uptime) = crate::clock::uptime() else {
            return false;
        };
        self.poll_at(SystemTime::now(), uptime)
    }
    pub(crate) fn checked(&mut self) {
        self.checked_at(crate::clock::uptime());
    }
    fn checked_at(&mut self, uptime: Option<Duration>) {
        self.next_poll = uptime
            .and_then(|u| u.checked_add(Duration::from_secs(2)))
            .unwrap_or(Duration::MAX);
    }
    fn poll_at(&mut self, wall: SystemTime, uptime: Duration) -> bool {
        if self.remaining_at(wall, uptime).is_zero() || uptime < self.next_poll {
            return false;
        }
        let Some(next) = uptime.checked_add(Duration::from_secs(2)) else {
            return false;
        };
        self.next_poll = next;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{bootstrap::PairingDraft, cloud::ServerURL};
    fn invitation() -> Invitation {
        let draft = PairingDraft::generate().unwrap();
        Invitation::new(
            ServerURL::parse("https://public.example.test").unwrap(),
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            *draft.nonce(),
            *draft.public_key(),
            1700000300,
            1700000000,
        )
        .unwrap()
    }
    #[test]
    fn wall_or_suspend_expiry_closes_display_and_polling_without_resetting_a_same_invitation() {
        let invitation = invitation();
        let wall = UNIX_EPOCH + Duration::from_secs(1700000000);
        let uptime = Duration::from_secs(50);
        let mut countdown = Countdown::at(&invitation, wall, uptime).unwrap();
        assert!(countdown.matches(&invitation));
        assert_eq!(countdown.remaining_at(wall, uptime).as_secs(), 300);
        assert!(!countdown.poll_at(wall, uptime));
        assert!(countdown.poll_at(
            wall + Duration::from_secs(2),
            uptime + Duration::from_secs(2)
        ));
        assert!(!countdown.poll_at(wall, uptime + Duration::from_secs(2)));
        assert_eq!(
            countdown
                .remaining_at(
                    wall - Duration::from_secs(100),
                    uptime + Duration::from_secs(10)
                )
                .as_secs(),
            290
        );
        assert!(!countdown.poll_at(
            wall - Duration::from_secs(100),
            uptime + Duration::from_secs(300)
        ));
        assert!(!countdown.poll_at(
            wall + Duration::from_secs(300),
            uptime + Duration::from_secs(4)
        ));
        assert_eq!(
            countdown.remaining_at(wall + Duration::from_secs(300), uptime),
            Duration::ZERO
        );
        countdown.checked_at(Some(uptime + Duration::from_secs(15)));
        assert!(!countdown.poll_at(
            wall + Duration::from_secs(16),
            uptime + Duration::from_secs(16)
        ));
        assert!(countdown.poll_at(
            wall + Duration::from_secs(17),
            uptime + Duration::from_secs(17)
        ));
        countdown.checked_at(None);
        assert!(!countdown.poll_at(
            wall + Duration::from_secs(20),
            uptime + Duration::from_secs(20)
        ));
    }
    #[test]
    fn expired_restored_invitation_and_clock_overflow_never_enable_polling() {
        let invitation = invitation();
        let wall = UNIX_EPOCH + Duration::from_secs(1700000301);
        let mut countdown = Countdown::at(&invitation, wall, Duration::from_secs(1)).unwrap();
        assert!(!countdown.poll_at(wall, Duration::from_secs(100)));
        assert!(Countdown::at(&invitation, wall, Duration::MAX).is_none());
    }
}
