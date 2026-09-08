#!/usr/bin/env bash
# Cut a bilan release — GATED on the test suite. Nothing ships if tests are red or the
# tag doesn't match version_str(). Usage:
#   ./release.sh v0.1.1            # gate -> build -> GitHub release with the prebuilt asset
#   ./release.sh v0.1.0 --dry-run  # gate -> build, but don't create the release
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:-}"; DRY="${2:-}"
REPO="javimosch/bilan"
[ -n "$TAG" ] || { echo "usage: ./release.sh vX.Y.Z [--dry-run]" >&2; exit 2; }
VER="${TAG#v}"

# 1. version lockstep — version_str() must equal the tag (a binary that lies about
#    itself breaks `bilan update` and every agent that trusts the guide).
SRCVER=$(grep -oE 'v = "[0-9]+\.[0-9]+\.[0-9]+"' src/core.src | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[ "$SRCVER" = "$VER" ] || { echo "✗ version mismatch: src/core.src is $SRCVER, tag is $VER — bump version_str() first" >&2; exit 1; }

# 2. THE GATE — tests must pass
echo "→ gate: running the test suite…"
./test.sh || { echo "✗ tests failed — release blocked" >&2; exit 1; }

# 3. build + verify the binary reports the right version
echo "→ building…"
./build.sh >/dev/null
GOT=$(./bilan version | grep -oE '"version":"[^"]+"' | cut -d'"' -f4)
[ "$GOT" = "$VER" ] || { echo "✗ built binary reports $GOT, expected $VER" >&2; exit 1; }

# 4. asset + checksum
cp bilan bilan-linux-amd64
SHA=$(sha256sum bilan-linux-amd64 | cut -d' ' -f1)
echo "✓ gate green · bilan-linux-amd64 $(du -h bilan-linux-amd64 | cut -f1) · sha256 $SHA"

if [ "$DRY" = "--dry-run" ]; then echo "(dry-run — no release created)"; rm -f bilan-linux-amd64; exit 0; fi

# 5. cut the release
gh release create "$TAG" bilan-linux-amd64 -R "$REPO" \
  --title "bilan $TAG" \
  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/$REPO/master/install.sh | sh\` · update: \`bilan update\`.

Prebuilt \`bilan-linux-amd64\` (glibc ≥ 2.35, libsqlite3); other platforms auto-fall-back to source.

\`sha256(bilan-linux-amd64) = $SHA\`"
rm -f bilan-linux-amd64
echo "✓ released $TAG"
