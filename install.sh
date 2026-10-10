#!/bin/bash
# Installs or updates Chilk from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/all0b0y/Chilk/main/install.sh | bash
#
# It downloads the release's DMG and SHA256SUMS.txt, checks the checksum and that Chilk.app is signed with Chilk's own
# certificate, copies Chilk.app into /Applications (a running Chilk is asked to quit first; his data stays where it is)
# and opens it. Chilk is not notarized by Apple (that needs a paid Apple developer account), so a copy downloaded by a
# browser makes macOS show "Apple could not verify…" on the first launch. Files downloaded by curl carry no "downloaded
# from the internet" mark, so after this script there is no such window. The script is short so that you can read it
# before running it.
#
# For testing: CHILK_VERSION=0.1.0, CHILK_BASE_URL=<folder with the DMG and SHA256SUMS.txt>,
# CHILK_INSTALL_DIR=<folder instead of /Applications>, CHILK_NO_OPEN=1.
set -euo pipefail

REPO="all0b0y/Chilk"
BUNDLE_ID="dev.all0b0y.chilk"
CERT_SHA1="242e853cf7e592d74eb797bf1f83988d8ed9b504"   # the «Chilk» code-signing certificate

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mChilk: %s\033[0m\n' "$*" >&2; exit 1; }

main() {
  [ "$(uname -s)" = Darwin ] || die "Chilk runs on macOS only."
  [ "$(uname -m)" = arm64 ] || die "Chilk needs a Mac with Apple silicon."
  local os; os=$(sw_vers -productVersion)
  [ "${os%%.*}" -ge 26 ] || die "Chilk needs macOS 26 or later; this Mac has macOS $os."

  local tag
  if [ -n "${CHILK_VERSION:-}" ]; then
    tag="v${CHILK_VERSION#v}"
  else
    tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
      || die "could not reach github.com/$REPO."
    tag=${tag##*/}
  fi
  case $tag in v[0-9]*) ;; *) die "no release found at github.com/$REPO/releases." ;; esac
  local version=${tag#v}
  local base=${CHILK_BASE_URL:-https://github.com/$REPO/releases/download/$tag}
  local dest=${CHILK_INSTALL_DIR:-/Applications}
  if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi

  tmp=$(mktemp -d -t chilk-install)
  trap 'hdiutil detach "$tmp/mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

  bold "Downloading Chilk ${version}…"
  local dmg="$tmp/Chilk-$version.dmg"
  curl -fL --progress-bar -o "$dmg" "$base/Chilk-$version.dmg" || die "download failed: $base/Chilk-$version.dmg"
  curl -fsSL -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || die "download failed: $base/SHA256SUMS.txt"
  local expected actual
  expected=$(awk -v f="Chilk-$version.dmg" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS.txt")
  actual=$(shasum -a 256 "$dmg" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "the checksum does not match SHA256SUMS.txt; not installing."

  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$tmp/mnt" "$dmg" </dev/null >/dev/null \
    || die "could not open the DMG."
  codesign --verify --deep --strict -R="certificate leaf = H\"$CERT_SHA1\"" "$tmp/mnt/Chilk.app" 2>/dev/null \
    || die "Chilk.app is not signed with Chilk's certificate; not installing."

  local running="$dest/Chilk.app/Contents/MacOS/Chilk"
  if pgrep -f "$running" >/dev/null; then
    bold "Asking the running Chilk to quit…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" </dev/null >/dev/null 2>&1 || true
    local i; for i in $(seq 1 30); do pgrep -f "$running" >/dev/null || break; sleep 0.5; done
    pkill -f "$running" 2>/dev/null || true
    sleep 1
  fi

  bold "Installing into ${dest}…"
  rm -rf "$dest/.Chilk.app.new"
  ditto "$tmp/mnt/Chilk.app" "$dest/.Chilk.app.new"
  rm -rf "$dest/Chilk.app"
  mv "$dest/.Chilk.app.new" "$dest/Chilk.app"
  [ -n "${CHILK_NO_OPEN:-}" ] || open "$dest/Chilk.app"

  bold "Chilk $version is installed: $dest/Chilk.app"
  echo "He lives at the edge of the screen; his remote is the leaf in the menu bar."
  if command -v codex >/dev/null 2>&1; then
    echo "Codex is installed; if he asks, click the leaf → «Войти в Codex» and sign in with your ChatGPT account."
  else
    echo "Next, give him a brain: install Codex — brew install --cask codex (or: npm install -g @openai/codex) —"
    echo "then click the leaf → «Войти в Codex» and sign in with your ChatGPT account."
  fi
}

main "$@"
