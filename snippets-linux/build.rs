fn main() {
    if std::env::var_os("CARGO_FEATURE_DESKTOP").is_some() {
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
    }
    let icu = pkg_config::Config::new()
        .probe("icu-i18n")
        .expect("ICU development files are required");
    let mut compiler = cc::Build::new();
    compiler.file("src/icu.c");
    for include in icu.include_paths {
        compiler.include(include);
    }
    compiler.compile("snippets_icu");
    println!("cargo:rerun-if-changed=src/icu.c");
    if std::env::var_os("CARGO_FEATURE_LOCAL_AUTH").is_some() {
        let pam = pkg_config::Config::new()
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
        println!("cargo:rerun-if-changed=src/owner_auth.c");
    }
    if std::env::var_os("CARGO_FEATURE_SECRET_SERVICE").is_some() {
        let secret = pkg_config::Config::new()
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
        println!("cargo:rerun-if-changed=src/secrets.c");
    }
}
