#!/usr/bin/env bash
# Builds and publishes the arm64 native tarballs for a release — the manual
# counterpart to each private repo's native.yml amd64 CI leg
# (SPEC-native-linux-install.md §12.1). Built locally rather than in CI to
# avoid paying for a GitHub arm64 runner; viable because Apple Silicon runs
# linux/arm64 containers natively, not under QEMU.
#
# Run this after CI has already published the amd64 assets for <version> to
# this repo's release (native.yml does that on a `v*` tag push in both
# VectorStep and VectorStep-Gateway) — this script adds the arm64 assets to
# that same release.
#
#   scripts/publish-native-arm64.sh 0.1.0
#
set -euo pipefail

VERSION="${1:?usage: scripts/publish-native-arm64.sh <version>, e.g. 0.1.0}"
TAG="v$VERSION"
DIST_REPO="bantex01/VectorStep-Dist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="$(dirname "$SCRIPT_DIR")"
GITHUB_ROOT="$(dirname "$DIST_ROOT")"  # assumes sibling checkouts, as in this project's own layout

VS_REPO="$GITHUB_ROOT/VectorStep"
GW_REPO="$GITHUB_ROOT/VectorStep-Gateway"

[ -d "$VS_REPO" ] || { echo "error: $VS_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
[ -d "$GW_REPO" ] || { echo "error: $GW_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found on PATH." >&2; exit 1; }

echo "==> building vectorstep $VERSION for linux/arm64"
"$VS_REPO/service/native/build.sh" --arch arm64 --version "$VERSION"

echo "==> building vectorstep-gateway $VERSION for linux/arm64"
"$GW_REPO/native/build.sh" --arch arm64 --version "$VERSION"

echo "==> confirming release $TAG exists on $DIST_REPO"
gh release view "$TAG" --repo "$DIST_REPO" >/dev/null 2>&1 || {
  echo "error: release $TAG doesn't exist yet on $DIST_REPO. The amd64 CI leg publishes it first (push tag $TAG in VectorStep and VectorStep-Gateway) — or create it yourself: gh release create $TAG --repo $DIST_REPO" >&2
  exit 1
}

echo "==> uploading arm64 assets to $TAG"
gh release upload "$TAG" \
  "$VS_REPO/native-dist/vectorstep-$VERSION-linux-arm64.tar.gz" \
  "$VS_REPO/native-dist/vectorstep-$VERSION-linux-arm64.tar.gz.sha256" \
  "$GW_REPO/native-dist/vectorstep-gateway-$VERSION-linux-arm64.tar.gz" \
  "$GW_REPO/native-dist/vectorstep-gateway-$VERSION-linux-arm64.tar.gz.sha256" \
  --repo "$DIST_REPO" --clobber

echo "==> done — $TAG on $DIST_REPO now has both amd64 (CI) and arm64 (this) assets"
