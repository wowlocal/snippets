//! Closed configuration commands; no snippet or credential payloads.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExpansionCommand {
    Status,
    Enable,
    Disable,
    EnableSuggestions,
    DisableSuggestions,
    Retry,
}
impl ExpansionCommand {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Status => "expansion-status",
            Self::Enable => "expansion-enable",
            Self::Disable => "expansion-disable",
            Self::EnableSuggestions => "suggestions-enable",
            Self::DisableSuggestions => "suggestions-disable",
            Self::Retry => "expansion-retry",
        }
    }
    pub(crate) fn from_wire(value: &str) -> Option<Self> {
        match value {
            "expansion-status" => Some(Self::Status),
            "expansion-enable" => Some(Self::Enable),
            "expansion-disable" => Some(Self::Disable),
            "suggestions-enable" => Some(Self::EnableSuggestions),
            "suggestions-disable" => Some(Self::DisableSuggestions),
            "expansion-retry" => Some(Self::Retry),
            _ => None,
        }
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ExpansionState {
    Disabled,
    Starting,
    WaitingForUnlock,
    WaitingForField,
    Listening,
    Stopped,
    Unavailable,
    WaitingForFcitx,
    UnsupportedDesktop,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ExpansionSettings {
    pub enabled: bool,
    pub suggestions: bool,
    pub state: ExpansionState,
}
impl ExpansionSettings {
    pub(crate) fn valid(&self) -> bool {
        self.enabled != (self.state == ExpansionState::Disabled)
    }
}
