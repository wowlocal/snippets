//! Runs on a worker thread; no service restart and no input-source replacement.
use super::*;
use gtk::{gio, glib, prelude::*};
const SYSTEMD: &str = "org.freedesktop.systemd1";
const MANAGER: &str = "/org/freedesktop/systemd1";
const UNAVAILABLE: Error =
    Error("GNOME's user input service could not be inspected. No setup files were changed.");
fn call(
    bus: &gio::DBusConnection,
    destination: &str,
    path: &str,
    interface: &str,
    method: &str,
    args: Option<&glib::Variant>,
) -> Result<glib::Variant> {
    bus.call_sync(
        Some(destination),
        path,
        interface,
        method,
        args,
        None,
        if destination == "org.gnome.Shell.Extensions" {
            gio::DBusCallFlags::NONE
        } else {
            gio::DBusCallFlags::NO_AUTO_START
        },
        3000,
        None::<&gio::Cancellable>,
    )
    .map_err(|_| UNAVAILABLE)
}
fn property(
    bus: &gio::DBusConnection,
    path: &str,
    interface: &str,
    name: &str,
) -> Result<glib::Variant> {
    let reply = call(
        bus,
        SYSTEMD,
        path,
        "org.freedesktop.DBus.Properties",
        "Get",
        Some(&(interface, name).to_variant()),
    )?;
    if reply.size() > 1024 * 1024 {
        return Err(UNAVAILABLE);
    }
    reply
        .get::<(glib::Variant,)>()
        .map(|v| v.0)
        .ok_or(UNAVAILABLE)
}
fn component_path(values: Vec<String>) -> Option<String> {
    values
        .into_iter()
        .rev()
        .find_map(|v| v.strip_prefix("IBUS_COMPONENT_PATH=").map(str::to_owned))
}
pub(crate) fn prepare() -> Result<()> {
    let bus = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|_| UNAVAILABLE)?;
    let reply = call(
        &bus,
        SYSTEMD,
        MANAGER,
        "org.freedesktop.systemd1.Manager",
        "LoadUnit",
        Some(&(UNIT,).to_variant()),
    )?;
    let (path,) = reply
        .get::<(glib::variant::ObjectPath,)>()
        .ok_or(UNAVAILABLE)?;
    let path = path.as_str();
    let files = property(
        &bus,
        path,
        "org.freedesktop.systemd1.Service",
        "EnvironmentFiles",
    )?
    .get::<Vec<(String, bool)>>()
    .ok_or(UNAVAILABLE)?;
    let unset = property(
        &bus,
        path,
        "org.freedesktop.systemd1.Service",
        "UnsetEnvironment",
    )?
    .get::<Vec<String>>()
    .ok_or(UNAVAILABLE)?;
    let stale = property(
        &bus,
        path,
        "org.freedesktop.systemd1.Unit",
        "NeedDaemonReload",
    )?
    .get::<bool>()
    .ok_or(UNAVAILABLE)?;
    if !files.is_empty()
        || unset
            .iter()
            .any(|v| v.split('=').next() == Some("IBUS_COMPONENT_PATH"))
        || stale
    {
        return Err(Error(
            "IBus has custom or unapplied service settings. Review them before configuring Snippets; existing settings were preserved.",
        ));
    }
    let service = component_path(
        property(
            &bus,
            path,
            "org.freedesktop.systemd1.Service",
            "Environment",
        )?
        .get()
        .ok_or(UNAVAILABLE)?,
    );
    let inherited = if service.is_some() {
        service
    } else {
        component_path(
            property(
                &bus,
                MANAGER,
                "org.freedesktop.systemd1.Manager",
                "Environment",
            )?
            .get()
            .ok_or(UNAVAILABLE)?,
        )
    };
    let home = std::env::var_os("HOME");
    let config = crate::desktop_settings::config_home(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        home.as_deref(),
    )?;
    let data = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.map(|v| PathBuf::from(v).join(".local/share")))
        .ok_or(INSTALLED)?;
    let executable = std::env::current_exe().map_err(|_| INSTALLED)?;
    Plan::prepare(
        &executable,
        &config,
        &data,
        &inherited.into_iter().collect::<Vec<_>>(),
    )?
    .apply()?;
    // Re-read the drop-in for the NEXT login. Never stop or replace live IBus.
    call(&bus, SYSTEMD, MANAGER, "org.freedesktop.systemd1.Manager", "Reload", None)
        .map_err(|_| Error("Setup files are saved. The user service manager could not reload them; restart the computer before continuing."))?;
    Ok(())
}
pub(crate) fn activate() -> Result<()> {
    let bus = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|_| Error("The GNOME session is unavailable."))?;
    let schema = gio::SettingsSchemaSource::default()
        .and_then(|s| s.lookup("org.gnome.shell", true))
        .ok_or(Error("GNOME settings are unavailable."))?;
    let settings = gio::Settings::new_full(&schema, None::<&gio::SettingsBackend>, None);
    if settings.boolean("disable-user-extensions") {
        return Err(Error(
            "GNOME user extensions are disabled. Enable them in Extensions before continuing.",
        ));
    }
    let reply = call(
        &bus,
        "org.gnome.Shell.Extensions",
        "/org/gnome/Shell/Extensions",
        "org.gnome.Shell.Extensions",
        "EnableExtension",
        Some(&(UUID,).to_variant()),
    )
    .map_err(|_| Error("Sign out and back in to load the Snippets companion, then try again."))?;
    if reply.get::<(bool,)>() != Some((true,)) {
        return Err(Error(
            "GNOME could not enable the Snippets companion. Check Extensions for compatibility or errors.",
        ));
    }
    // Shared Gio session connection is the connection holding the primary app name.
    for _ in 0..5 {
        let reply = call(
            &bus,
            "org.gnome.Shell",
            "/com/khm/Snippets/Gnome",
            "com.khm.Snippets.Gnome1",
            "EnableInput",
            None,
        );
        // Enabling the companion starts an asynchronous primary-owner watch.
        // Retry briefly; each request repeats the full Shell authorization.
        if reply.ok().and_then(|v| v.get::<(bool,)>()) == Some((true,)) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Err(Error(
        "Snippets input is not available yet. Sign out and back in, then try again.",
    ))
}
