#!/usr/bin/env bash
# Read-only health check across VectorStep, VectorStep-Gateway, and this repo
# — answers "is the last release actually complete" and "is it safe to run
# publish-native-arm64.sh right now," without running any git/gh mutation
# commands. Everything here is a read: git fetch (read-only against the
# remote), gh release/run list, docker manifest inspect.
#
# Born from the 2026-09-22 incident where VectorStep and VectorStep-Gateway
# drifted out of the lockstep-tag rule (RELEASING.md, cutting-a-release.md)
# because auto-version.yml bumps each repo's patch version independently on
# every push to main, with no awareness that the two repos must always carry
# the same tag. That let publish-native-arm64.sh upload a Gateway arm64
# tarball labelled with a version Gateway had never actually been tagged at.
# See architecture/distribution.md's Gotchas section for the full story.
#
#   scripts/release-status.sh
#
set -euo pipefail

DIST_REPO="bantex01/VectorStep-Dist"
VS_GH_REPO="bantex01/VectorStep"
GW_GH_REPO="bantex01/VectorStep-Gateway"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="$(dirname "$SCRIPT_DIR")"
GITHUB_ROOT="$(dirname "$DIST_ROOT")"  # assumes sibling checkouts, as in this project's own layout

VS_REPO="$GITHUB_ROOT/VectorStep"
GW_REPO="$GITHUB_ROOT/VectorStep-Gateway"

[ -d "$VS_REPO" ] || { echo "error: $VS_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
[ -d "$GW_REPO" ] || { echo "error: $GW_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found on PATH." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH." >&2; exit 1; }

PASS=true
warn() { echo "  WARN: $*"; PASS=false; }
ok()   { echo "  OK:   $*"; }

echo "==> fetching tags"
git -C "$VS_REPO" fetch --tags --quiet \
  || warn "VectorStep: git fetch --tags reported an error (e.g. a local tag has diverged from origin — 'would clobber existing tag'). Tag check below may be reading a stale local tag; run 'git fetch --tags --force' by hand once you've confirmed which side is correct."
git -C "$GW_REPO" fetch --tags --quiet \
  || warn "VectorStep-Gateway: git fetch --tags reported an error (e.g. a local tag has diverged from origin — 'would clobber existing tag'). Tag check below may be reading a stale local tag; run 'git fetch --tags --force' by hand once you've confirmed which side is correct."

VS_TAG="$(git -C "$VS_REPO" tag --list 'v*' --sort=-v:refname | head -1)"
GW_TAG="$(git -C "$GW_REPO" tag --list 'v*' --sort=-v:refname | head -1)"

echo
echo "==> 1. lockstep tag check (VectorStep and VectorStep-Gateway MUST always match — no exceptions)"
echo "  VectorStep:         $VS_TAG"
echo "  VectorStep-Gateway: $GW_TAG"
if [ "$VS_TAG" = "$GW_TAG" ]; then
  ok "tags match"
else
  warn "tags DO NOT match. Per RELEASING.md / cutting-a-release.md, these two repos have a hard wire-protocol coupling with no version negotiation — they must always carry the same tag, even for a one-line fix in only one of them. Tag the trailing repo (even with an empty diff) to catch up before running publish-native-arm64.sh or trusting 'latest' images to be compatible with each other."
fi

# Use the higher of the two (by version sort) as the target for the checks
# below, so a mismatch still gets a useful completeness readout rather than
# just stopping here.
TARGET_TAG="$(printf '%s\n%s\n' "$VS_TAG" "$GW_TAG" | sort -V | tail -1)"
TARGET_VERSION="${TARGET_TAG#v}"
echo
echo "==> checking release/CI/image state at $TARGET_TAG"

echo
echo "==> 2. Dist release asset completeness ($DIST_REPO @ $TARGET_TAG)"
if ! gh release view "$TARGET_TAG" --repo "$DIST_REPO" >/dev/null 2>&1; then
  warn "no release exists yet at $TARGET_TAG in $DIST_REPO"
else
  ASSETS="$(gh release view "$TARGET_TAG" --repo "$DIST_REPO" --json assets --jq '.assets[].name')"
  for svc in vectorstep vectorstep-gateway; do
    for f in \
      "$svc-$TARGET_VERSION-linux-amd64.tar.gz" \
      "$svc-$TARGET_VERSION-linux-amd64.tar.gz.bundle" \
      "$svc-$TARGET_VERSION-linux-amd64.tar.gz.sig" \
      "$svc-$TARGET_VERSION-linux-amd64.tar.gz.sha256" \
      "$svc-$TARGET_VERSION-linux-arm64.tar.gz" \
      "$svc-$TARGET_VERSION-linux-arm64.tar.gz.sha256"
    do
      if echo "$ASSETS" | grep -qx "$f"; then
        ok "$f"
      else
        warn "missing asset: $f"
      fi
    done
  done
fi

echo
echo "==> 3. in-flight CI runs at $TARGET_TAG (wait for these before trusting the above as final)"
for repo in "$VS_GH_REPO" "$GW_GH_REPO"; do
  RUNS="$(gh run list --repo "$repo" --branch "$TARGET_TAG" --limit 10 --json workflowName,status,conclusion 2>/dev/null || echo '[]')"
  INFLIGHT="$(echo "$RUNS" | jq -r '.[] | select(.status != "completed") | .workflowName')"
  if [ -n "$INFLIGHT" ]; then
    warn "$repo has runs still in flight at $TARGET_TAG: $(echo "$INFLIGHT" | paste -sd, -)"
  else
    FAILED="$(echo "$RUNS" | jq -r '.[] | select(.conclusion != "success" and .conclusion != null) | .workflowName + " (" + .conclusion + ")"')"
    if [ -n "$FAILED" ]; then
      warn "$repo has completed-but-not-successful runs at $TARGET_TAG: $(echo "$FAILED" | paste -sd, -)"
    else
      ok "$repo: no in-flight runs, none failed at $TARGET_TAG"
    fi
  fi
done

echo
echo "==> 4. GHCR image is genuinely multi-arch at $TARGET_TAG"
for image in vectorstep vectorstep-gateway; do
  REF="ghcr.io/bantex01/$image:$TARGET_VERSION"
  if ! MANIFEST="$(docker manifest inspect "$REF" 2>/dev/null)"; then
    warn "$REF: manifest not found (image.yml may not have run/published yet)"
    continue
  fi
  ARCHES="$(echo "$MANIFEST" | jq -r '[.manifests[].platform | select(.architecture != "unknown") | .architecture] | sort | join(",")')"
  if echo "$ARCHES" | grep -q "amd64" && echo "$ARCHES" | grep -q "arm64"; then
    ok "$REF: $ARCHES"
  else
    warn "$REF: only found [$ARCHES] — expected both amd64 and arm64"
  fi
done

echo
if $PASS; then
  echo "==> all clear at $TARGET_TAG"
else
  echo "==> issues found above — see WARN lines"
  exit 1
fi
