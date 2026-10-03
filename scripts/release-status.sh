#!/usr/bin/env bash
# Read-only health check across the whole VectorStep family of repos —
# answers "what do I need to push before I walk away from this session" as
# well as "is the last release actually complete" and "is it safe to run
# publish-native-arm64.sh right now," without running any git/gh mutation
# commands. Everything here is a read: git fetch (read-only against the
# remote), git status/rev-list, gh release/run list, docker manifest inspect.
#
# The release/tag checks were born from the 2026-09-22 incident where
# VectorStep and VectorStep-Gateway drifted out of the lockstep-tag rule
# (RELEASING.md, cutting-a-release.md) because auto-version.yml bumps each
# repo's patch version independently on every push to main, with no
# awareness that the two repos must always carry the same tag. That let
# publish-native-arm64.sh upload a Gateway arm64 tarball labelled with a
# version Gateway had never actually been tagged at. See
# architecture/distribution.md's Gotchas section for the full story.
#
# The working-tree sweep (§1) exists because "the owner commits their own
# work" (every repo's CLAUDE.md/ROADMAP.md convention) means an implementing
# session routinely finishes with edits sitting uncommitted, or committed but
# unpushed, across several of these repos at once — this answers "which ones,
# and exactly what's outstanding" in one pass instead of a manual `git status`
# per repo.
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

# Every repo in the product, swept for uncommitted/unpushed work in §1.
# Order matches how a session usually touches them: engine, gateway, the two
# MCP servers, this repo, then the two docs sites.
ALL_REPOS=(
  VectorStep
  VectorStep-Gateway
  VectorStep-Service-MCP
  VectorStep-Gateway-MCP
  VectorStep-Dist
  VectorStep-Website
  VectorStep-DevDocs
)

[ -d "$VS_REPO" ] || { echo "error: $VS_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
[ -d "$GW_REPO" ] || { echo "error: $GW_REPO not found (expected as a sibling directory of VectorStep-Dist)." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found on PATH." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH." >&2; exit 1; }

PASS=true
ACTIONS=()  # each entry: one blank-line-separated block, printed verbatim in the final summary
warn()   { echo "  WARN: $*"; PASS=false; }
ok()     { echo "  OK:   $*"; }
action() { ACTIONS+=("$1"); }  # call alongside warn() when the fix is a concrete command

echo "==> 1. local working tree — uncommitted or unpushed changes, every repo"
for name in "${ALL_REPOS[@]}"; do
  repo="$GITHUB_ROOT/$name"
  if [ ! -d "$repo/.git" ]; then
    warn "$name: not found at $repo (expected as a sibling checkout) — skipped"
    continue
  fi

  git -C "$repo" fetch --quiet 2>/dev/null \
    || warn "$name: git fetch failed — ahead/behind counts below may be stale"

  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  dirty="$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')"

  upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -z "$upstream" ]; then
    ahead="?"; behind="?"; upstream_note=" — no upstream tracking branch"
  else
    ahead="$(git -C "$repo" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo '?')"
    behind="$(git -C "$repo" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo '?')"
    upstream_note=""
  fi

  if [ "$dirty" = "0" ] && [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
    ok "$name (branch $branch): clean, up to date"
  else
    detail="branch=$branch"
    [ "$dirty" != "0" ] && detail="$detail, $dirty uncommitted file(s)"
    [ "$ahead" != "0" ] && [ "$ahead" != "?" ] && detail="$detail, $ahead commit(s) to push"
    [ "$behind" != "0" ] && [ "$behind" != "?" ] && detail="$detail, $behind commit(s) behind origin (pull before you push)"
    warn "$name: $detail$upstream_note"

    if [ "$dirty" != "0" ]; then
      action "$name: $dirty uncommitted file(s) — review, then commit:"$'\n'"    git -C \"$repo\" status"
    fi
    if [ -z "$upstream" ]; then
      action "$name: branch \"$branch\" has no upstream — set one on first push:"$'\n'"    git -C \"$repo\" push -u origin $branch"
    else
      if [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
        action "$name: $ahead commit(s) to push:"$'\n'"    git -C \"$repo\" push"
      fi
      if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
        action "$name: $behind commit(s) behind origin — pull before pushing:"$'\n'"    git -C \"$repo\" pull"
      fi
    fi
  fi
done

echo
echo "==> fetching tags"
git -C "$VS_REPO" fetch --tags --quiet \
  || warn "VectorStep: git fetch --tags reported an error (e.g. a local tag has diverged from origin — 'would clobber existing tag'). Tag check below may be reading a stale local tag; run 'git fetch --tags --force' by hand once you've confirmed which side is correct."
git -C "$GW_REPO" fetch --tags --quiet \
  || warn "VectorStep-Gateway: git fetch --tags reported an error (e.g. a local tag has diverged from origin — 'would clobber existing tag'). Tag check below may be reading a stale local tag; run 'git fetch --tags --force' by hand once you've confirmed which side is correct."

VS_TAG="$(git -C "$VS_REPO" tag --list 'v*' --sort=-v:refname | head -1)"
GW_TAG="$(git -C "$GW_REPO" tag --list 'v*' --sort=-v:refname | head -1)"

echo
echo "==> 2. lockstep tag check (VectorStep and VectorStep-Gateway MUST always match — no exceptions)"
echo "  VectorStep:         $VS_TAG"
echo "  VectorStep-Gateway: $GW_TAG"
if [ "$VS_TAG" = "$GW_TAG" ]; then
  ok "tags match"
else
  warn "tags DO NOT match. Per RELEASING.md / cutting-a-release.md, these two repos have a hard wire-protocol coupling with no version negotiation — they must always carry the same tag, even for a one-line fix in only one of them. Tag the trailing repo (even with an empty diff) to catch up before running publish-native-arm64.sh or trusting 'latest' images to be compatible with each other."

  HIGHER_TAG="$(printf '%s\n%s\n' "$VS_TAG" "$GW_TAG" | sort -V | tail -1)"
  if [ "$HIGHER_TAG" = "$VS_TAG" ]; then
    LAG_NAME="VectorStep-Gateway"; LAG_REPO="$GW_REPO"
  else
    LAG_NAME="VectorStep"; LAG_REPO="$VS_REPO"
  fi
  action "Tag mismatch — $LAG_NAME needs to catch up to $HIGHER_TAG (an empty-diff tag is fine if there's nothing else to release):"$'\n'"    git -C \"$LAG_REPO\" tag $HIGHER_TAG"$'\n'"    git -C \"$LAG_REPO\" push origin $HIGHER_TAG"
fi

# Use the higher of the two (by version sort) as the target for the checks
# below, so a mismatch still gets a useful completeness readout rather than
# just stopping here.
TARGET_TAG="$(printf '%s\n%s\n' "$VS_TAG" "$GW_TAG" | sort -V | tail -1)"
TARGET_VERSION="${TARGET_TAG#v}"
echo
echo "==> checking release/CI/image state at $TARGET_TAG"

echo
echo "==> 3. Dist release asset completeness ($DIST_REPO @ $TARGET_TAG)"
if ! gh release view "$TARGET_TAG" --repo "$DIST_REPO" >/dev/null 2>&1; then
  warn "no release exists yet at $TARGET_TAG in $DIST_REPO"
  action "No $DIST_REPO release exists yet at $TARGET_TAG — check whether $VS_GH_REPO/$GW_GH_REPO's tag push actually ran their release workflows:"$'\n'"    gh run list --repo $VS_GH_REPO --branch $TARGET_TAG"$'\n'"    gh run list --repo $GW_GH_REPO --branch $TARGET_TAG"
else
  ASSETS="$(gh release view "$TARGET_TAG" --repo "$DIST_REPO" --json assets --jq '.assets[].name')"
  MISSING_AMD64=false
  MISSING_ARM64=false
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
        case "$f" in
          *linux-arm64*) MISSING_ARM64=true ;;
          *)              MISSING_AMD64=true ;;
        esac
      fi
    done
  done
  if $MISSING_AMD64; then
    action "amd64 tarball asset(s) missing from the $TARGET_TAG release — that's native.yml's CI leg, check its run:"$'\n'"    gh run list --repo $VS_GH_REPO --branch $TARGET_TAG --workflow native.yml"$'\n'"    gh run list --repo $GW_GH_REPO --branch $TARGET_TAG --workflow native.yml"
  fi
  if $MISSING_ARM64; then
    action "arm64 tarball asset(s) missing from the $TARGET_TAG release — that's the manual leg (no arm64 GitHub runner). Once amd64 assets exist for this release, run:"$'\n'"    ./scripts/publish-native-arm64.sh $TARGET_VERSION"
  fi
fi

echo
echo "==> 4. in-flight CI runs at $TARGET_TAG (wait for these before trusting the above as final)"
for repo in "$VS_GH_REPO" "$GW_GH_REPO"; do
  RUNS="$(gh run list --repo "$repo" --branch "$TARGET_TAG" --limit 10 --json workflowName,status,conclusion 2>/dev/null || echo '[]')"
  INFLIGHT="$(echo "$RUNS" | jq -r '.[] | select(.status != "completed") | .workflowName')"
  if [ -n "$INFLIGHT" ]; then
    warn "$repo has runs still in flight at $TARGET_TAG: $(echo "$INFLIGHT" | paste -sd, -)"
    action "$repo: workflow(s) still running at $TARGET_TAG — wait, then re-run this script. To watch instead:"$'\n'"    gh run list --repo $repo --branch $TARGET_TAG"
  else
    FAILED="$(echo "$RUNS" | jq -r '.[] | select(.conclusion != "success" and .conclusion != null) | .workflowName + " (" + .conclusion + ")"')"
    if [ -n "$FAILED" ]; then
      warn "$repo has completed-but-not-successful runs at $TARGET_TAG: $(echo "$FAILED" | paste -sd, -)"
      action "$repo: failed workflow(s) at $TARGET_TAG ($(echo "$FAILED" | paste -sd, -)) — inspect, then re-run:"$'\n'"    gh run list --repo $repo --branch $TARGET_TAG"$'\n'"    gh run rerun <run-id> --repo $repo --failed"
    else
      ok "$repo: no in-flight runs, none failed at $TARGET_TAG"
    fi
  fi
done

echo
echo "==> 5. GHCR image is genuinely multi-arch at $TARGET_TAG"
for image in vectorstep vectorstep-gateway; do
  REF="ghcr.io/bantex01/$image:$TARGET_VERSION"
  IMAGE_GH_REPO="$VS_GH_REPO"
  [ "$image" = "vectorstep-gateway" ] && IMAGE_GH_REPO="$GW_GH_REPO"

  if ! MANIFEST="$(docker manifest inspect "$REF" 2>/dev/null)"; then
    warn "$REF: manifest not found (image.yml may not have run/published yet)"
    action "$REF: no manifest published — check image.yml:"$'\n'"    gh run list --repo $IMAGE_GH_REPO --branch $TARGET_TAG --workflow image.yml"
    continue
  fi
  ARCHES="$(echo "$MANIFEST" | jq -r '[.manifests[].platform | select(.architecture != "unknown") | .architecture] | sort | join(",")')"
  if echo "$ARCHES" | grep -q "amd64" && echo "$ARCHES" | grep -q "arm64"; then
    ok "$REF: $ARCHES"
  else
    warn "$REF: only found [$ARCHES] — expected both amd64 and arm64"
    action "$REF: only [$ARCHES] published, missing an architecture — check image.yml (it builds both via buildx in one multi-platform push, so a partial manifest usually means the job failed partway):"$'\n'"    gh run list --repo $IMAGE_GH_REPO --branch $TARGET_TAG --workflow image.yml"
  fi
done

echo
echo "==> 6. public release notes published for $TARGET_TAG"
NOTES_URL="https://vectorstep.io/docs/about/release-notes/"
NOTES_ANCHOR="${TARGET_TAG//./}"   # v0.1.13 -> v0113, the id Starlight gives "## v0.1.13"
NOTES_BASELINE="0.1.12"             # release notes start after this version; earlier ones aren't itemised
if [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$NOTES_BASELINE" | sort -V | tail -1)" = "$NOTES_BASELINE" ]; then
  ok "$TARGET_TAG predates the release notes (they start after v$NOTES_BASELINE) — nothing to check"
elif curl -fsS --max-time 20 "$NOTES_URL" 2>/dev/null | grep -q "id=\"$NOTES_ANCHOR\""; then
  ok "$NOTES_URL has an entry for $TARGET_TAG"
else
  warn "no release-notes entry for $TARGET_TAG at $NOTES_URL"
  action "Write the $TARGET_TAG entry in VectorStep-Website (src/content/docs/docs/about/release-notes.md, newest first, '## $TARGET_TAG' then 'Released YYYY-MM-DD'), commit and push so the site deploys, then re-run this script. See the 'Release notes' step in the release runbook."
fi

echo
if $PASS; then
  echo "==> all clear at $TARGET_TAG"
else
  echo "==> issues found above — see WARN lines"
fi

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo
  echo "==> outstanding actions (${#ACTIONS[@]})"
  n=1
  for item in "${ACTIONS[@]}"; do
    echo
    printf '%d. %s\n' "$n" "$item"
    n=$((n + 1))
  done
fi

$PASS || exit 1
