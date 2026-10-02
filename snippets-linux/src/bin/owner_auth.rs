//! Private unprivileged PAM worker; credentials travel only through stdin.
fn main() {
    std::process::exit(snippets_linux::local_auth::helper_main());
}
