#!/usr/bin/env bash
set -euo pipefail

TASK_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TASK_INSTALL_PREFIX=$HOME/.local
TASK_BUILD=true
TASK_DESKTOP=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 && -n $2 ]] || { echo '--prefix requires a path' >&2; exit 2; }; TASK_INSTALL_PREFIX=$2; shift 2 ;;
    --no-build) TASK_BUILD=false; shift ;;
    --desktop) [[ $# -ge 2 ]] || { echo '--desktop requires auto, hyprland or gnome' >&2; exit 2; }; TASK_DESKTOP=$2; shift 2 ;;
    --help|-h)
      echo 'Usage: ./scripts/install-linux.sh [--prefix PATH] [--no-build] [--desktop auto|hyprland|gnome]'
      echo 'Builds and installs native Rust executables under ~/.local. Preserves library data.'
      exit 0 ;;
    *) echo 'Unknown option. Use --help.' >&2; exit 2 ;;
  esac
done
if [[ $TASK_DESKTOP == auto ]]; then
  case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:GNOME:*|*:gnome:*) TASK_DESKTOP=gnome ;;
    *) TASK_DESKTOP=hyprland ;;
  esac
fi
case "$TASK_DESKTOP" in gnome|hyprland) ;; *) echo '--desktop requires auto, hyprland or gnome' >&2; exit 2 ;; esac
cd -- "$TASK_REPO_ROOT"
command -v python3 >/dev/null || { echo 'Python 3 is required to generate installation metadata.' >&2; exit 1; }

if ! pkg-config --atleast-version=4.12 gtk4 || ! pkg-config --atleast-version=1.5 libadwaita-1 || ! pkg-config --exists icu-i18n || ! pkg-config --atleast-version=0.21 libsecret-1 || ! pkg-config --exists pam || ! pkg-config --atleast-version=4.1 libqrencode || ! pkg-config --exists wayland-client wayland-protocols xkbcommon json-c pangocairo || ! command -v wayland-scanner >/dev/null; then
  echo 'Requires GTK >= 4.12, libadwaita >= 1.5, ICU, libsecret >= 0.21, Linux-PAM, libqrencode >= 4.1, Wayland, xkbcommon, Cairo/Pango, json-c, and wayland-protocols.' >&2
  if [[ $TASK_DESKTOP == gnome ]]; then
    echo 'On Ubuntu: sudo apt install build-essential cargo pkg-config python3 libgtk-4-dev libadwaita-1-dev libicu-dev libsecret-1-dev libpam0g-dev libaudit-dev libcap-ng-dev libqrencode-dev libwayland-dev wayland-protocols libxkbcommon-dev libjson-c-dev libibus-1.0-dev' >&2
  else
    echo 'On Omarchy: omarchy pkg add rust gtk4 libadwaita icu libsecret pam qrencode fcitx5 wayland wayland-protocols json-c pkgconf base-devel' >&2
  fi
  exit 1
fi
TASK_FEATURES=(--no-default-features --features desktop,ibus)
TASK_BINARIES=(snippets snippets-cli snippets-owner-auth snippets-ibus)
TASK_DEFAULT_TARGET=$TASK_REPO_ROOT/snippets-linux/target/gnome
if [[ $TASK_DESKTOP == hyprland ]]; then
  pkg-config --atleast-version=5.1 Fcitx5Core && pkg-config --exists Fcitx5Module || { echo 'The Hyprland build requires Fcitx5 >= 5.1 development files.' >&2; exit 1; }
  TASK_FEATURES=(--no-default-features --features desktop,fcitx)
  TASK_BINARIES=(snippets snippets-cli snippets-owner-auth)
  TASK_DEFAULT_TARGET=$TASK_REPO_ROOT/snippets-linux/target
else
  pkg-config --atleast-version=1.5.20 ibus-1.0 || { echo 'The GNOME build requires IBus >= 1.5.20 development files (libibus-1.0-dev on Ubuntu).' >&2; exit 1; }
fi
TASK_TARGET_ROOT=${CARGO_TARGET_DIR:-$TASK_DEFAULT_TARGET}
[[ $TASK_TARGET_ROOT = /* ]] || TASK_TARGET_ROOT=$TASK_REPO_ROOT/$TASK_TARGET_ROOT
if $TASK_BUILD; then
  command -v cargo >/dev/null || { echo 'Cargo is required to build. On Omarchy: omarchy pkg add rust' >&2; exit 1; }
  cargo build --locked --release --manifest-path "$TASK_REPO_ROOT/snippets-linux/Cargo.toml" --target-dir "$TASK_TARGET_ROOT" "${TASK_FEATURES[@]}" --bins
fi
if [[ $TASK_DESKTOP == hyprland ]]; then
  [[ -f "$TASK_TARGET_ROOT/release/libsnippets-fcitx.so" && ! -L "$TASK_TARGET_ROOT/release/libsnippets-fcitx.so" ]] || { echo 'Release Fcitx addon is missing; rebuild Snippets.' >&2; exit 1; }
fi
for TASK_BINARY in "${TASK_BINARIES[@]}"; do
  [[ -f "$TASK_TARGET_ROOT/release/$TASK_BINARY" && -x "$TASK_TARGET_ROOT/release/$TASK_BINARY" && ! -L "$TASK_TARGET_ROOT/release/$TASK_BINARY" ]] || { echo 'Release executables are missing or linked; run the installer without --no-build.' >&2; exit 1; }
done
command -v readelf >/dev/null || { echo 'Requires readelf from binutils to verify the native release.' >&2; exit 1; }
TASK_GTK_DYNAMIC=$(LC_ALL=C readelf --dynamic "$TASK_TARGET_ROOT/release/snippets")
TASK_GTK_RUNPATH=$(printf '%s\n' "$TASK_GTK_DYNAMIC" | sed -n 's/.*(RUNPATH).*Library runpath: \[\(.*\)\]$/\1/p')
TASK_GTK_RUNTIME=
TASK_GTK_BASE_FILES=(BUILD-INFO.json COPYING REBUILD.txt gtk-4.22.4-pathbar-cancel.patch gtk-4.22.4.tar.xz libgtk-4.so.1)
TASK_GTK_FILES=("${TASK_GTK_BASE_FILES[@]}")
verify_gtk_runtime() {
  local TASK_DIRECTORY=$1 TASK_NAME=$2 TASK_ENTRY TASK_COUNT=0 TASK_SUMS TASK_DIGEST TASK_EXPECTED_COUNT=7
  [[ -d $TASK_DIRECTORY && ! -L $TASK_DIRECTORY ]] || { echo 'The release GTK runtime directory is missing or linked.' >&2; return 1; }
  TASK_GTK_FILES=("${TASK_GTK_BASE_FILES[@]}")
  if [[ -e $TASK_DIRECTORY/libadwaita-1.so.0 || -L $TASK_DIRECTORY/libadwaita-1.so.0 ]]; then
    TASK_GTK_FILES+=(COPYING.libadwaita libadwaita-1.9.3-alert-heading.patch libadwaita-1.9.3.tar.xz libadwaita-1.so.0)
    TASK_EXPECTED_COUNT=11
  fi
  for TASK_ENTRY in "$TASK_DIRECTORY"/* "$TASK_DIRECTORY"/.[!.]* "$TASK_DIRECTORY"/..?*; do
    [[ -e $TASK_ENTRY || -L $TASK_ENTRY ]] || continue
    [[ -f $TASK_ENTRY && ! -L $TASK_ENTRY ]] || { echo 'GTK runtime inputs must be regular files.' >&2; return 1; }
    case "${TASK_ENTRY##*/}" in
      BUILD-INFO.json|COPYING|REBUILD.txt|SHA256SUMS|gtk-4.22.4-pathbar-cancel.patch|gtk-4.22.4.tar.xz|libgtk-4.so.1|COPYING.libadwaita|libadwaita-1.9.3-alert-heading.patch|libadwaita-1.9.3.tar.xz|libadwaita-1.so.0) ;;
      *) echo 'Unexpected GTK runtime input.' >&2; return 1 ;;
    esac
    TASK_COUNT=$((TASK_COUNT + 1))
  done
  [[ $TASK_COUNT == "$TASK_EXPECTED_COUNT" ]] || { echo 'The GTK runtime payload is incomplete.' >&2; return 1; }
  TASK_DIGEST=$(sha256sum -- "$TASK_DIRECTORY/SHA256SUMS"); TASK_DIGEST=${TASK_DIGEST%% *}
  [[ $TASK_NAME == gtk-runtime-"$TASK_DIGEST" ]] || { echo 'GTK runtime manifest does not match the GUI loader path.' >&2; return 1; }
  TASK_SUMS=$(cd -- "$TASK_DIRECTORY" && sha256sum -- "${TASK_GTK_FILES[@]}")
  [[ $(cat -- "$TASK_DIRECTORY/SHA256SUMS") == "$TASK_SUMS" ]] || { echo 'GTK runtime content does not match its manifest.' >&2; return 1; }
  LC_ALL=C readelf --dynamic "$TASK_DIRECTORY/libgtk-4.so.1" | rg 'Library soname: \[libgtk-4\.so\.1\]' >/dev/null || { echo 'GTK runtime SONAME is incorrect.' >&2; return 1; }
  if [[ $TASK_EXPECTED_COUNT == 11 ]]; then
    LC_ALL=C readelf --dynamic "$TASK_DIRECTORY/libadwaita-1.so.0" | rg 'Library soname: \[libadwaita-1\.so\.0\]' >/dev/null || { echo 'libadwaita runtime SONAME is incorrect.' >&2; return 1; }
  fi
}
if [[ -n $TASK_GTK_RUNPATH ]]; then
  TASK_GTK_RUNTIME=${TASK_GTK_RUNPATH#'$ORIGIN/'}
  [[ $TASK_GTK_RUNPATH == '$ORIGIN/'"$TASK_GTK_RUNTIME" && $TASK_GTK_RUNTIME =~ ^gtk-runtime-[0-9a-f]{64}$ ]] || { echo 'Unsupported GUI library path.' >&2; exit 1; }
  verify_gtk_runtime "$TASK_TARGET_ROOT/release/$TASK_GTK_RUNTIME" "$TASK_GTK_RUNTIME"
fi
mkdir -p -- "$TASK_INSTALL_PREFIX"
TASK_INSTALL_PREFIX=$(realpath -- "$TASK_INSTALL_PREFIX")
TASK_DESTINATION=$TASK_INSTALL_PREFIX/share/snippets-linux
TASK_METADATA=$(mktemp -d)
trap 'rm -rf -- "$TASK_METADATA"' EXIT
TASK_METADATA_OPTIONS=()
if [[ $TASK_DESKTOP == gnome ]]; then TASK_METADATA_OPTIONS=(--gnome); fi
python3 "$TASK_REPO_ROOT/scripts/linux-install-metadata.py" \
  --destination "$TASK_DESTINATION" \
  --template "$TASK_REPO_ROOT/snippets-linux/data/com.khm.snippets.linux.desktop" \
  --output "$TASK_METADATA" "${TASK_METADATA_OPTIONS[@]}"
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
if [[ -n $TASK_GTK_RUNTIME ]]; then
  TASK_GTK_DESTINATION=$TASK_DESTINATION/$TASK_GTK_RUNTIME
  [[ ! -L $TASK_GTK_DESTINATION ]] || { echo 'The installed GTK runtime directory is linked.' >&2; exit 1; }
  # Complete and verify the immutable version before switching the GUI binary.
  for TASK_GTK_FILE in "${TASK_GTK_FILES[@]}" SHA256SUMS; do
    TASK_GTK_MODE=644
    case "$TASK_GTK_FILE" in libgtk-4.so.1|libadwaita-1.so.0) TASK_GTK_MODE=755 ;; esac
    install_atomic "$TASK_TARGET_ROOT/release/$TASK_GTK_RUNTIME/$TASK_GTK_FILE" "$TASK_GTK_DESTINATION/$TASK_GTK_FILE" "$TASK_GTK_MODE"
  done
  verify_gtk_runtime "$TASK_GTK_DESTINATION" "$TASK_GTK_RUNTIME"
fi
install_atomic "$TASK_TARGET_ROOT/release/snippets-owner-auth" "$TASK_DESTINATION/snippets-owner-auth" 755
if [[ $TASK_DESKTOP == gnome ]]; then
  install_atomic "$TASK_TARGET_ROOT/release/snippets-ibus" "$TASK_DESTINATION/snippets-ibus" 755
  install_atomic "$TASK_METADATA/snippets.xml" "$TASK_INSTALL_PREFIX/share/ibus/component/snippets.xml" 644
  TASK_EXTENSION=snippets@wowlocal.github.io
  for TASK_EXTENSION_FILE in metadata.json extension.js; do
    install_atomic "$TASK_REPO_ROOT/snippets-linux/gnome/$TASK_EXTENSION/$TASK_EXTENSION_FILE" \
      "$TASK_INSTALL_PREFIX/share/gnome-shell/extensions/$TASK_EXTENSION/$TASK_EXTENSION_FILE" 644
  done
fi
if [[ $TASK_DESKTOP == hyprland ]]; then
  install_atomic "$TASK_TARGET_ROOT/release/libsnippets-fcitx.so" "$TASK_DESTINATION/libsnippets-fcitx.so" 755
  for TASK_FCITX_INTERFACE_FILE in COPYING SOURCE.json waylandim_public.h zwp_input_method_v2.h wl_surface.h; do
    install_atomic "$TASK_REPO_ROOT/snippets-linux/src/fcitx-5.1.22/$TASK_FCITX_INTERFACE_FILE" "$TASK_DESTINATION/fcitx-5.1.22/$TASK_FCITX_INTERFACE_FILE" 644
  done
fi
for TASK_WAYLAND_SOURCE in wlr-layer-shell-v1.xml wlr-layer-shell-v1.source.json xdg-shell.xml xdg-shell.source.json; do
  install_atomic "$TASK_REPO_ROOT/snippets-linux/data/$TASK_WAYLAND_SOURCE" "$TASK_DESTINATION/wayland-protocols/$TASK_WAYLAND_SOURCE" 644
done
for TASK_BINARY in snippets snippets-cli; do
  install_atomic "$TASK_TARGET_ROOT/release/$TASK_BINARY" "$TASK_DESTINATION/$TASK_BINARY" 755
  mkdir -p -- "$TASK_INSTALL_PREFIX/bin"
  TASK_LINK=$(mktemp -d "$TASK_INSTALL_PREFIX/bin/.snippets-link-XXXXXX")
  ln -s -- "$TASK_DESTINATION/$TASK_BINARY" "$TASK_LINK/$TASK_BINARY"
  mv -fT -- "$TASK_LINK/$TASK_BINARY" "$TASK_INSTALL_PREFIX/bin/$TASK_BINARY"
  rmdir -- "$TASK_LINK"
done
if [[ $TASK_DESKTOP == hyprland ]]; then
  TASK_ADDON_METADATA=$TASK_METADATA/snippets.conf
  cat > "$TASK_ADDON_METADATA" <<EOF
[Addon]
Name=Snippets
Type=SharedLibrary
Library=$TASK_DESTINATION/libsnippets-fcitx
Category=Module
Version=0.1.0
OnDemand=False
Configurable=False
[Addon/Dependencies]
0=core:5.1.0
[Addon/OptionalDependencies]
0=wayland
1=waylandim
EOF
  install_atomic "$TASK_ADDON_METADATA" "$TASK_INSTALL_PREFIX/share/fcitx5/addon/snippets.conf" 644
fi
install_atomic "$TASK_METADATA/com.khm.snippets.linux.desktop" "$TASK_INSTALL_PREFIX/share/applications/com.khm.snippets.linux.desktop" 644
install_atomic "$TASK_REPO_ROOT/snippets-linux/data/com.khm.snippets.linux.metainfo.xml" "$TASK_INSTALL_PREFIX/share/metainfo/com.khm.snippets.linux.metainfo.xml" 644
install_atomic "$TASK_REPO_ROOT/snippets-linux/data/snippets-icon.png" "$TASK_INSTALL_PREFIX/share/icons/hicolor/256x256/apps/com.khm.snippets.linux.png" 644
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$TASK_INSTALL_PREFIX/share/applications"
fi
printf 'Installed Snippets. Run: %q\n' "$TASK_INSTALL_PREFIX/bin/snippets"
if [[ $TASK_DESKTOP == hyprland ]]; then
  echo 'Restart Fcitx once after installation to load the Snippets addon. Expansion remains opt-in in Snippets Settings.'
else
  echo 'Experimental GNOME components installed. Desktop preferences and input sources were preserved.'
  echo 'IBus registration and Shell companion activation are separate steps; see docs/linux/GNOME.md.'
fi
