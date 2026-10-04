//! The same bounded, revocable production owner is used by native UI and tests.
use super::*;
use restoration_task::Preparation;
use secret_store::Backend;

#[derive(Default)]
pub(crate) struct Retained {
    reviewed: Option<(uuid::Uuid, capacity::Review, Preparation)>,
}
impl Retained {
    pub(crate) fn keep_for(&mut self, command: &Command) {
        if !matches!(
            command,
            Command::CommitHistoryRemoval { .. } | Command::Authenticate { .. }
        ) {
            self.reviewed = None;
        }
    }
    pub(crate) fn prepare<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        selection: Option<capacity::Selection>,
        preparation: Preparation,
    ) -> Result<Reply> {
        self.reviewed = None;
        preparation.validate()?;
        let review = match selection {
            Some(selection) => capacity::prepare(store, selection),
            None => capacity::prepare_resume(store),
        }
        .map_err(Failure::HistoryRemoval)?;
        self.retain(review, preparation)
    }
    pub(crate) fn prepare_cleanup<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        preparation: Preparation,
    ) -> Result<Reply> {
        self.reviewed = None;
        preparation.validate()?;
        let review = capacity::prepare_cleanup(store).map_err(Failure::HistoryRemoval)?;
        preparation.validate()?;
        match review {
            Some(review) => self.retain(review, preparation),
            None => Ok(Reply::NoUnusedRecoveryFiles),
        }
    }
    fn retain(&mut self, review: capacity::Review, preparation: Preparation) -> Result<Reply> {
        preparation.validate()?;
        let summary = review.summary();
        let target = review
            .authorization_target()
            .map_err(Failure::HistoryRemoval)?;
        let token = uuid::Uuid::new_v4();
        self.reviewed = Some((token, review, preparation));
        Ok(Reply::HistoryRemovalReview {
            token,
            summary,
            target,
        })
    }
    pub(crate) fn consume(&mut self, token: uuid::Uuid) -> Result<capacity::Review> {
        let (expected, review, preparation) = self.reviewed.take().ok_or(Failure::InvalidState)?;
        preparation.validate()?;
        if token != expected {
            return Err(Failure::InvalidState);
        }
        Ok(review)
    }
}
