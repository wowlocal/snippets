fn main() {
    println!("cargo:rerun-if-env-changed=SNIPPETS_GTK_RUNTIME_DIR");
    if std::env::var_os("CARGO_FEATURE_DESKTOP").is_some() {
        let fcitx = pkg_config::Config::new()
            .cargo_metadata(false)
            .atleast_version("5.1")
            .probe("Fcitx5Core")
            .expect("Fcitx5 development files are required for inline expansion");
        let addon_output =
            std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output directory"));
        let addon_library = addon_output.join("libsnippets-fcitx.so");
        let module = pkg_config::Config::new()
            .cargo_metadata(false)
            .probe("Fcitx5Module")
            .expect("Fcitx5 module development files are required");
        let wayland_panel = pkg_config::Config::new()
            .cargo_metadata(false)
            .probe("wayland-client")
            .expect("Wayland client development files are required");
        let pango_panel = pkg_config::Config::new()
            .cargo_metadata(false)
            .probe("pangocairo")
            .expect("Pango/Cairo development files are required");
        let json_panel = pkg_config::Config::new()
            .cargo_metadata(false)
            .atleast_version("0.14")
            .probe("json-c")
            .expect("json-c development files are required");
        for (mode, name) in [
            (
                "client-header",
                "wayland-input-method-unstable-v2-client-protocol.h",
            ),
            ("private-code", "snippets-fcitx-popup-protocol.c"),
        ] {
            assert!(
                std::process::Command::new("wayland-scanner")
                    .arg(mode)
                    .arg("data/input-method-v2.xml")
                    .arg(addon_output.join(name))
                    .status()
                    .expect("wayland-scanner is required")
                    .success()
            );
        }
        let panel_protocol = addon_output.join("snippets-fcitx-popup-protocol.o");
        assert!(
            cc::Build::new()
                .get_compiler()
                .to_command()
                .args([
                    "-c",
                    "-fPIC",
                    "-fvisibility=hidden",
                    "-Wall",
                    "-Wextra",
                    "-Werror"
                ])
                .arg(addon_output.join("snippets-fcitx-popup-protocol.c"))
                .arg("-o")
                .arg(&panel_protocol)
                .status()
                .expect("C compiler required")
                .success()
        );
        let mut fallback_protocols = Vec::new();
        for (xml, stem) in [
            ("wlr-layer-shell-v1.xml", "snippets-fcitx-layer"),
            ("xdg-shell.xml", "snippets-fcitx-xdg"),
        ] {
            for (mode, suffix) in [
                ("client-header", "protocol.h"),
                ("private-code", "protocol.c"),
            ] {
                assert!(
                    std::process::Command::new("wayland-scanner")
                        .arg(mode)
                        .arg(format!("data/{xml}"))
                        .arg(addon_output.join(format!("{stem}-{suffix}")))
                        .status()
                        .expect("wayland-scanner required")
                        .success()
                );
            }
            let object = addon_output.join(format!("{stem}.o"));
            assert!(
                cc::Build::new()
                    .get_compiler()
                    .to_command()
                    .args([
                        "-c",
                        "-fPIC",
                        "-fvisibility=hidden",
                        "-Wall",
                        "-Wextra",
                        "-Werror"
                    ])
                    .arg(addon_output.join(format!("{stem}-protocol.c")))
                    .arg("-o")
                    .arg(&object)
                    .status()
                    .expect("C compiler required")
                    .success()
            );
            fallback_protocols.push(object);
            println!("cargo:rerun-if-changed=data/{xml}");
        }
        let mut addon = cc::Build::new().cpp(true).get_compiler().to_command();
        addon
            .args([
                "-std=c++20",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fPIC",
                "-shared",
                "src/inline_fcitx.cpp",
                "-o",
            ])
            .arg(&addon_library);
        addon
            .arg(&panel_protocol)
            .args(&fallback_protocols)
            .arg("-I")
            .arg(&addon_output);
        addon.arg(format!(
            "-DSNIPPETS_FCITX_INTERFACE_SDK=\"{}\"",
            fcitx.version
        ));
        for include in fcitx
            .include_paths
            .iter()
            .chain(&module.include_paths)
            .chain(&wayland_panel.include_paths)
            .chain(&pango_panel.include_paths)
            .chain(&json_panel.include_paths)
        {
            addon.arg("-I").arg(include);
        }
        for directory in fcitx
            .link_paths
            .iter()
            .chain(&wayland_panel.link_paths)
            .chain(&pango_panel.link_paths)
            .chain(&json_panel.link_paths)
        {
            addon.arg("-L").arg(directory);
        }
        for library in fcitx
            .libs
            .iter()
            .chain(&wayland_panel.libs)
            .chain(&pango_panel.libs)
            .chain(&json_panel.libs)
        {
            addon.arg(format!("-l{library}"));
        }
        addon.arg("-ldl");
        assert!(
            addon.status().expect("C++ compiler required").success(),
            "Fcitx addon build failed"
        );
        // Installable transport sits next to the GUI it authenticates by inode.
        std::fs::copy(
            &addon_library,
            addon_output
                .ancestors()
                .nth(3)
                .expect("Cargo profile directory")
                .join("libsnippets-fcitx.so"),
        )
        .expect("Copy installable Fcitx addon");
        println!("cargo:rerun-if-changed=src/inline_fcitx.cpp");
        println!("cargo:rerun-if-changed=src/inline_fcitx_channel.h");
        println!("cargo:rerun-if-changed=src/inline_fcitx_popup.h");
        println!("cargo:rerun-if-changed=src/inline_fcitx_surface.h");
        println!("cargo:rerun-if-changed=src/inline_fcitx_anchor.h");
        println!("cargo:rerun-if-changed=src/fcitx-5.1.22/waylandim_public.h");
        println!("cargo:rerun-if-changed=src/fcitx-5.1.22/zwp_input_method_v2.h");
        println!("cargo:rerun-if-changed=src/fcitx-5.1.22/wl_surface.h");
        println!("cargo:rerun-if-changed=data/input-method-v2.xml");
        let state_fixture = addon_output.join("snippets-fcitx-state-fixture");
        let mut fixture = cc::Build::new().cpp(true).get_compiler().to_command();
        fixture
            .args([
                "-std=c++20",
                "-O2",
                "-UNDEBUG",
                "-Wall",
                "-Wextra",
                "-Werror",
                "tests/reference/fcitx-state.cpp",
                "-o",
            ])
            .arg(&state_fixture);
        fixture
            .arg(&panel_protocol)
            .args(&fallback_protocols)
            .arg("-I")
            .arg(&addon_output);
        fixture.arg(format!(
            "-DSNIPPETS_FCITX_INTERFACE_SDK=\"{}\"",
            fcitx.version
        ));
        for include in fcitx
            .include_paths
            .iter()
            .chain(&module.include_paths)
            .chain(&wayland_panel.include_paths)
            .chain(&pango_panel.include_paths)
            .chain(&json_panel.include_paths)
        {
            fixture.arg("-I").arg(include);
        }
        for directory in fcitx
            .link_paths
            .iter()
            .chain(&wayland_panel.link_paths)
            .chain(&pango_panel.link_paths)
            .chain(&json_panel.link_paths)
        {
            fixture.arg("-L").arg(directory);
        }
        for library in fcitx
            .libs
            .iter()
            .chain(&wayland_panel.libs)
            .chain(&pango_panel.libs)
            .chain(&json_panel.libs)
        {
            fixture.arg(format!("-l{library}"));
        }
        fixture.arg("-ldl");
        assert!(
            fixture.status().expect("C++ compiler required").success(),
            "Native Fcitx state fixture build failed"
        );
        println!(
            "cargo:rustc-env=SNIPPETS_FCITX_STATE_FIXTURE={}",
            state_fixture.display()
        );
        println!("cargo:rerun-if-changed=tests/reference/fcitx-state.cpp");
        if let Some(directory) = std::env::var_os("SNIPPETS_GTK_RUNTIME_DIR") {
            let directory = directory
                .to_str()
                .expect("GTK runtime directory must be UTF-8");
            let digest = directory
                .strip_prefix("gtk-runtime-")
                .expect("GTK runtime directory must be content-addressed");
            assert!(
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
                "GTK runtime directory must contain a SHA-256 digest"
            );
            // Only the GUI uses the optional app-local GTK. A versioned relative
            // RUNPATH keeps later system-linked builds independent of old bundles.
            println!(
                "cargo:rustc-link-arg-bin=snippets=-Wl,--enable-new-dtags,-rpath,$ORIGIN/{directory}"
            );
        }
        pkg_config::Config::new()
            .atleast_version("4.1")
            .probe("libqrencode")
            .expect("libqrencode development files are required");
        let wayland = pkg_config::Config::new()
            .probe("wayland-client")
            .expect("Wayland client development files are required");
        let directory = pkg_config::get_variable("wayland-protocols", "pkgdatadir")
            .expect("wayland-protocols development files are required");
        let protocol = std::path::PathBuf::from(directory)
            .join("staging/ext-data-control/ext-data-control-v1.xml");
        let output =
            std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output directory"));
        for (mode, file) in [
            ("client-header", "snippets-data-control.h"),
            ("private-code", "snippets-data-control.c"),
        ] {
            assert!(
                std::process::Command::new("wayland-scanner")
                    .arg(mode)
                    .arg(&protocol)
                    .arg(output.join(file))
                    .status()
                    .expect("wayland-scanner is required")
                    .success(),
                "ext-data-control-v1 protocol generation failed"
            );
        }
        let mut compiler = cc::Build::new();
        compiler
            .file("src/clipboard_wayland.c")
            .file(output.join("snippets-data-control.c"))
            .include(&output)
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror");
        for include in wayland.include_paths {
            compiler.include(include);
        }
        compiler.compile("snippets_clipboard_wayland");
        println!("cargo:rerun-if-changed=src/clipboard_wayland.c");
        println!("cargo:rerun-if-changed={}", protocol.display());
        let input_protocol = "data/virtual-keyboard-v1.xml";
        for (mode, file) in [
            ("client-header", "snippets-input.h"),
            ("private-code", "snippets-input-protocol.c"),
        ] {
            assert!(
                std::process::Command::new("wayland-scanner")
                    .arg(mode)
                    .arg(input_protocol)
                    .arg(output.join(file))
                    .status()
                    .expect("wayland-scanner is required")
                    .success()
            );
        }
        let input_wayland = pkg_config::Config::new()
            .probe("wayland-client")
            .expect("Wayland client development files are required");
        let input_xkb = pkg_config::Config::new()
            .probe("xkbcommon")
            .expect("xkbcommon development files are required");
        let mut input = cc::Build::new();
        input
            .file("src/input_wayland.c")
            .file(output.join("snippets-input-protocol.c"))
            .include(&output)
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror");
        for include in input_wayland.include_paths {
            input.include(include);
        }
        for include in input_xkb.include_paths {
            input.include(include);
        }
        input.compile("snippets_input_wayland");
        println!("cargo:rerun-if-changed=src/input_wayland.c");
        println!("cargo:rerun-if-changed={input_protocol}");
        let ime_protocol = "data/input-method-v2.xml";
        for (mode, file) in [
            ("client-header", "snippets-ime.h"),
            ("private-code", "snippets-ime-protocol.c"),
        ] {
            assert!(
                std::process::Command::new("wayland-scanner")
                    .arg(mode)
                    .arg(ime_protocol)
                    .arg(output.join(file))
                    .status()
                    .expect("wayland-scanner is required")
                    .success()
            );
        }
        let ime_wayland = pkg_config::Config::new()
            .probe("wayland-client")
            .expect("Wayland client development files are required");
        let mut ime = cc::Build::new();
        let popup = pkg_config::Config::new()
            .probe("pangocairo")
            .expect("Pango/Cairo development files are required");
        let keyboard = pkg_config::Config::new()
            .probe("xkbcommon")
            .expect("XKB development files are required");
        ime.file("src/inline_wayland.c")
            .file(output.join("snippets-ime-protocol.c"))
            .include(&output)
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror");
        for include in ime_wayland.include_paths {
            ime.include(include);
        }
        for include in popup
            .include_paths
            .into_iter()
            .chain(keyboard.include_paths)
        {
            ime.include(include);
        }
        ime.compile("snippets_ime_wayland");
        println!("cargo:rerun-if-changed=src/inline_wayland.c");
        println!("cargo:rerun-if-changed=src/inline_popup.c");
        println!("cargo:rerun-if-changed=src/inline_popup_wayland.c");
        println!("cargo:rerun-if-changed={ime_protocol}");
        let shortcuts_protocol = "data/hyprland-global-shortcuts-v1.xml";
        for (mode, file) in [
            ("client-header", "snippets-shortcuts.h"),
            ("private-code", "snippets-shortcuts-protocol.c"),
        ] {
            assert!(
                std::process::Command::new("wayland-scanner")
                    .arg(mode)
                    .arg(shortcuts_protocol)
                    .arg(output.join(file))
                    .status()
                    .expect("wayland-scanner is required")
                    .success()
            );
        }
        let shortcuts_wayland = pkg_config::Config::new()
            .probe("wayland-client")
            .expect("Wayland client development files are required");
        let mut shortcuts = cc::Build::new();
        shortcuts
            .file("src/shortcuts_wayland.c")
            .file(output.join("snippets-shortcuts-protocol.c"))
            .include(&output)
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror");
        for include in shortcuts_wayland.include_paths {
            shortcuts.include(include);
        }
        shortcuts.compile("snippets_shortcuts_wayland");
        println!("cargo:rerun-if-changed=src/shortcuts_wayland.c");
        println!("cargo:rerun-if-changed={shortcuts_protocol}");
    }
    let icu = pkg_config::Config::new()
        .cargo_metadata(false)
        .probe("icu-i18n")
        .expect("ICU development files are required");
    let mut compiler = cc::Build::new();
    compiler.file("src/icu.c");
    for include in icu.include_paths {
        compiler.include(include);
    }
    compiler.compile("snippets_icu");
    // With --as-needed, system libraries must follow the C archive that uses
    // them. Unit-test executables expose this ordering on GNU ld.
    pkg_config::Config::new().probe("icu-i18n").unwrap();
    println!("cargo:rerun-if-changed=src/icu.c");
    if std::env::var_os("CARGO_FEATURE_LOCAL_AUTH").is_some() {
        let pam = pkg_config::Config::new()
            .cargo_metadata(false)
            .probe("pam")
            .expect("Linux-PAM development files are required");
        let mut compiler = cc::Build::new();
        compiler
            .file("src/owner_auth.c")
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra");
        for include in pam.include_paths {
            compiler.include(include);
        }
        compiler.compile("snippets_owner_auth");
        pkg_config::Config::new().probe("pam").unwrap();
        println!("cargo:rerun-if-changed=src/owner_auth.c");
    }
    if std::env::var_os("CARGO_FEATURE_SECRET_SERVICE").is_some() {
        let secret = pkg_config::Config::new()
            .cargo_metadata(false)
            .atleast_version("0.21")
            .probe("libsecret-1")
            .expect("libsecret development files are required");
        let mut compiler = cc::Build::new();
        compiler
            .file("src/secrets.c")
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra");
        for include in secret.include_paths {
            compiler.include(include);
        }
        compiler.compile("snippets_secrets");
        pkg_config::Config::new().probe("libsecret-1").unwrap();
        println!("cargo:rerun-if-changed=src/secrets.c");
    }
}
