#!/bin/sh
# pkspec installer — download the prebuilt `pkspec` binaries for this host.
#
#   curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh
#
# Installs the `pkspec` CLI plus its five adapter shims
# (pkspec-adapter-{vitest,playwright,node-test,go-test,moon-test}).
#
# Options (env vars or flags):
#   PKSPEC_VERSION      / --version <v>   version to install (default: latest).
#                                         Accepts 0.4.0, v0.4.0, pkspec@0.4.0.
#   PKSPEC_INSTALL_DIR  / --dir <path>    install directory (default: ~/.local/bin)
#   PKSPEC_NO_VERIFY    / --no-verify     skip the sha256 checksum check
#
# `pkspec` also needs the Pkl CLI (`pkl`) on PATH:
#   https://pkl-lang.org/main/current/pkl-cli/
#
# Supported platforms: linux-amd64, linux-arm64, darwin-arm64.
# Intel macOS (darwin-amd64) and Windows are not supported — the MoonBit
# toolchain pkspec is built with has no x86_64 macOS / Windows target.
set -eu

REPO="mizchi/pkspec"
VERSION="${PKSPEC_VERSION:-latest}"
INSTALL_DIR="${PKSPEC_INSTALL_DIR:-$HOME/.local/bin}"
NO_VERIFY="${PKSPEC_NO_VERIFY:-}"

# The six binaries packaged in pkspec-<plat>.tar.gz.
BINARIES="pkspec pkspec-adapter-vitest pkspec-adapter-playwright pkspec-adapter-node-test pkspec-adapter-go-test pkspec-adapter-moon-test"

err() {
  echo "pkspec install: $*" >&2
  exit 1
}

usage() {
  sed -n '2,22p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    -h|--help) usage ;;
    *) err "unknown argument: $1 (try --help)" ;;
  esac
done

# --- detect platform -------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) os_part=linux ;;
  Darwin) os_part=darwin ;;
  *) err "unsupported OS: $os (supported: Linux, Darwin)" ;;
esac
case "$arch" in
  x86_64 | amd64) arch_part=amd64 ;;
  aarch64 | arm64) arch_part=arm64 ;;
  *) err "unsupported architecture: $arch" ;;
esac
plat="${os_part}-${arch_part}"
case "$plat" in
  linux-amd64 | linux-arm64 | darwin-arm64) ;;
  darwin-amd64)
    err "Intel macOS (darwin-amd64) is not supported — the MoonBit toolchain has no x86_64 macOS build. Use an Apple Silicon Mac." ;;
  *) err "unsupported platform: $plat" ;;
esac

# --- resolve download URL --------------------------------------------------
asset="pkspec-${plat}.tar.gz"
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
  pretty="latest"
else
  # Normalize 0.4.0 / v0.4.0 / pkspec@0.4.0 → the pkspec@<ver> release tag.
  ver="${VERSION#pkspec@}"
  ver="${ver#v}"
  base="https://github.com/${REPO}/releases/download/pkspec@${ver}"
  pretty="pkspec@${ver}"
fi
url="${base}/${asset}"

# --- pick a downloader -----------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "need curl or wget on PATH"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "pkspec install: downloading ${asset} (${pretty}) for ${plat}" >&2
dl "$url" "$tmp/$asset" || err "download failed: $url"

# --- verify checksum (best effort) -----------------------------------------
if [ -z "$NO_VERIFY" ]; then
  if dl "${url}.sha256" "$tmp/${asset}.sha256" 2>/dev/null; then
    expected="$(awk '{print $1}' "$tmp/${asset}.sha256")"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    else
      actual=""
    fi
    if [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
      err "checksum mismatch: expected $expected, got $actual"
    fi
    [ -n "$actual" ] && echo "pkspec install: sha256 ok" >&2
  else
    echo "pkspec install: no .sha256 published, skipping checksum" >&2
  fi
fi

# --- extract + install -----------------------------------------------------
tar -xzf "$tmp/$asset" -C "$tmp" || err "failed to extract $asset"

mkdir -p "$INSTALL_DIR"
for bin in $BINARIES; do
  [ -f "$tmp/$bin" ] || err "archive did not contain a '$bin' binary"
  install -m 0755 "$tmp/$bin" "$INSTALL_DIR/$bin" 2>/dev/null \
    || { cp "$tmp/$bin" "$INSTALL_DIR/$bin" && chmod 0755 "$INSTALL_DIR/$bin"; } \
    || err "failed to install $bin into $INSTALL_DIR (set PKSPEC_INSTALL_DIR to a writable dir)"
done

echo "pkspec install: installed pkspec + 5 adapter shims → ${INSTALL_DIR}" >&2
"${INSTALL_DIR}/pkspec" version >/dev/null 2>&1 \
  && echo "pkspec install: pkspec $("${INSTALL_DIR}/pkspec" version) ready" >&2 || true

# --- PATH + pkl guidance ---------------------------------------------------
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) echo "pkspec install: add ${INSTALL_DIR} to PATH, e.g. export PATH=\"${INSTALL_DIR}:\$PATH\"" >&2 ;;
esac
command -v pkl >/dev/null 2>&1 \
  || echo "pkspec install: also install the Pkl CLI — https://pkl-lang.org/main/current/pkl-cli/" >&2
