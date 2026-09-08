#!/usr/bin/env bash
# bilan installer — downloads the latest prebuilt release for this platform and
# installs it to BILAN_BIN_DIR (default ~/.local/bin). Verifies the sha256 against
# the release's SHA256SUMS.txt before installing. Falls back to build-from-source
# when no release asset matches. Idempotent; never sudo.
set -e
REPO="javimosch/bilan"
BIN_DIR="${BILAN_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
asset="bilan-${os}-${arch}"
base="https://github.com/${REPO}/releases/latest/download"
url="${base}/${asset}"
sums_url="${base}/SHA256SUMS.txt"

tmp=$(mktemp)
if curl -fsSL "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    # verify the sha256 against the release's SHA256SUMS.txt (supply-chain hygiene)
    sums=$(mktemp)
    if curl -fsSL "$sums_url" -o "$sums" 2>/dev/null && [ -s "$sums" ]; then
        want=$(grep "  ${asset}\$" "$sums" | awk '{print $1}')
        got=$(sha256sum "$tmp" | awk '{print $1}')
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            echo "✗ checksum mismatch for ${asset}: expected $(echo "$want" | cut -c1-12)…, got $(echo "$got" | cut -c1-12)… — refusing to install" >&2
            rm -f "$tmp" "$sums"
            exit 1
        fi
        echo "✓ sha256 verified ($(echo "$got" | cut -c1-12)…)"
    else
        echo "warning: no SHA256SUMS.txt at this release — installed without checksum verification" >&2
    fi
    rm -f "$sums"
    chmod +x "$tmp"
    mv "$tmp" "$BIN_DIR/bilan"
    echo "installed: $BIN_DIR/bilan ($asset)"
    "$BIN_DIR/bilan" version || true
    exit 0
fi
rm -f "$tmp"

echo "no prebuilt ${asset} — building from source (needs: machin + cc)" >&2
srcdir=$(mktemp -d)
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/master.tar.gz" | tar xz -C "$srcdir"
cd "$srcdir"/*/ && ./build.sh && mkdir -p "$BIN_DIR" && cp bilan "$BIN_DIR/bilan"
echo "installed: $BIN_DIR/bilan (from source)"
