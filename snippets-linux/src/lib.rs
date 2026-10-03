pub mod account_key;
pub mod account_review;
#[cfg(feature = "desktop")]
mod account_ui;
#[cfg(feature = "desktop")]
mod account_worker;
pub mod auth_store;
pub mod auto_sync;
pub mod backup;
#[cfg(feature = "desktop")]
mod backup_ui;
pub mod bootstrap;
pub mod canonical;
pub mod clipboard_history;
pub mod clock;
pub mod cloud;
pub mod control;
#[cfg(feature = "desktop")]
mod control_ui;
pub mod crypto;
pub mod deletion_review;
pub mod desktop;
pub mod desktop_settings;
pub mod diagnostics;
#[cfg(feature = "desktop")]
mod diagnostics_service;
pub mod editor_assistance;
pub mod global_shortcuts;
pub mod inbound;
#[cfg(any(test, feature = "desktop"))]
pub mod inline_expansion;
pub mod journal;
pub mod key_store;
pub mod local_auth;
pub mod materializer;
pub mod merge;
pub mod model;
mod outbound;
#[cfg(feature = "desktop")]
mod pairing_ui_state;
pub mod placeholders;
pub mod primary;
pub mod projection;
#[cfg(any(test, feature = "desktop"))]
mod protected_edit;
#[cfg(feature = "desktop")]
mod protected_editor;
pub mod receiver;
#[cfg(feature = "desktop")]
mod recovery_qr;
pub mod secret_store;
pub mod secure_input;
#[cfg(any(test, feature = "desktop"))]
pub mod secure_insertion;
#[cfg(feature = "desktop")]
mod secure_ui;
pub mod sender;
#[cfg(feature = "desktop")]
mod sensitive_clipboard;
pub mod snapshot_review;
pub mod sync;
#[cfg(feature = "desktop")]
mod tray;
#[cfg(feature = "desktop")]
pub mod ui;
pub mod usage;
pub mod usage_store;
pub mod vault;
pub mod wire;
