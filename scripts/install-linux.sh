#!/usr/bin/env bash
set -euo pipefail

TASK_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TASK_INSTALL_PREFIX=$HOME/.local
TASK_BUILD=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 && -n $2 ]] || { echo '--prefix requires a path' >&2; exit 2; }; TASK_INSTALL_PREFIX=$2; shift 2 ;;
    --no-build) TASK_BUILD=false; shift ;;
    --help|-h)
      echo 'Usage: ./scripts/install-linux.sh [--prefix PATH] [--no-build]'
      echo 'Builds and installs native Rust executables under ~/.local. Preserves library data.'
      exit 0 ;;
    *) echo 'Unknown option. Use --help.' >&2; exit 2 ;;
  esac
done
cd -- "$TASK_REPO_ROOT"

if ! pkg-config --atleast-version=4.12 gtk4 || ! pkg-config --atleast-version=1.5 libadwaita-1 || ! pkg-config --exists icu-i18n || ! pkg-config --atleast-version=0.21 libsecret-1 || ! pkg-config --exists pam || ! pkg-config --atleast-version=4.1 libqrencode || ! pkg-config --exists wayland-client wayland-protocols || ! command -v wayland-scanner >/dev/null; then
  echo 'Requires GTK >= 4.12, libadwaita >= 1.5, ICU, libsecret >= 0.21, Linux-PAM, libqrencode >= 4.1, Wayland, and wayland-protocols.' >&2
  echo 'On Omarchy: omarchy pkg add rust gtk4 libadwaita icu libsecret pam qrencode wayland wayland-protocols pkgconf base-devel' >&2
  exit 1
fi
if $TASK_BUILD; then
  command -v cargo >/dev/null || { echo 'Cargo is required to build. On Omarchy: omarchy pkg add rust' >&2; exit 1; }
  cargo build --locked --release --manifest-path "$TASK_REPO_ROOT/snippets-linux/Cargo.toml" --bins
fi
TASK_TARGET_ROOT=${CARGO_TARGET_DIR:-$TASK_REPO_ROOT/snippets-linux/target}
[[ $TASK_TARGET_ROOT = /* ]] || TASK_TARGET_ROOT=$TASK_REPO_ROOT/$TASK_TARGET_ROOT
for TASK_BINARY in snippets snippets-cli snippets-owner-auth; do
  [[ -x "$TASK_TARGET_ROOT/release/$TASK_BINARY" ]] || { echo 'Release executables are missing; run the installer without --no-build.' >&2; exit 1; }
done
mkdir -p -- "$TASK_INSTALL_PREFIX"
TASK_INSTALL_PREFIX=$(realpath -- "$TASK_INSTALL_PREFIX")
TASK_DESTINATION=$TASK_INSTALL_PREFIX/share/snippets-linux
for TASK_BINARY in snippets snippets-cli; do
  if [[ -e $TASK_INSTALL_PREFIX/bin/$TASK_BINARY && ! -L $TASK_INSTALL_PREFIX/bin/$TASK_BINARY ]]; then
    echo "An existing $TASK_BINARY executable occupies the destination; choose another --prefix." >&2
    exit 1
  fi
done
install_atomic() {
  local TASK_SOURCE=$1 TASK_TARGET=$2 TASK_MODE=$3 TASK_TEMP
  mkdir -p -- "$(dirname -- "$TASK_TARGET")"
  TASK_TEMP=$(mktemp "$(dirname -- "$TASK_TARGET")/.snippets-install-XXXXXX")
  if ! install -m "$TASK_MODE" -- "$TASK_SOURCE" "$TASK_TEMP" || ! mv -fT -- "$TASK_TEMP" "$TASK_TARGET"; then
    rm -f -- "$TASK_TEMP"
    return 1
  fi
}
install_atomic "$TASK_TARGET_ROOT/release/snippets-owner-auth" "$TASK_DESTINATION/snippets-owner-auth" 755
for TASK_BINARY in snippets snippets-cli; do
  install_atomic "$TASK_TARGET_ROOT/release/$TASK_BINARY" "$TASK_DESTINATION/$TASK_BINARY" 755
  mkdir -p -- "$TASK_INSTALL_PREFIX/bin"
  TASK_LINK=$(mktemp -d "$TASK_INSTALL_PREFIX/bin/.snippets-link-XXXXXX")
  ln -s -- "$TASK_DESTINATION/$TASK_BINARY" "$TASK_LINK/$TASK_BINARY"
  mv -fT -- "$TASK_LINK/$TASK_BINARY" "$TASK_INSTALL_PREFIX/bin/$TASK_BINARY"
  rmdir -- "$TASK_LINK"
done
install_atomic "$TASK_REPO_ROOT/snippets-linux/data/com.khm.snippets.linux.desktop" "$TASK_INSTALL_PREFIX/share/applications/com.khm.snippets.linux.desktop" 644
install_atomic "$TASK_REPO_ROOT/snippets-linux/data/com.khm.snippets.linux.metainfo.xml" "$TASK_INSTALL_PREFIX/share/metainfo/com.khm.snippets.linux.metainfo.xml" 644
install_atomic "$TASK_REPO_ROOT/snippets-linux/data/snippets-icon.png" "$TASK_INSTALL_PREFIX/share/icons/hicolor/256x256/apps/com.khm.snippets.linux.png" 644
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$TASK_INSTALL_PREFIX/share/applications"
fi
printf 'Installed Snippets. Run: %q\n' "$TASK_INSTALL_PREFIX/bin/snippets"
