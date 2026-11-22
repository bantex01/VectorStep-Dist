#!/usr/bin/env bash
# Finish an engine release that stopped AFTER the VectorStep + Gateway PRs were merged (cut-release.sh
# can't be re-run then: nothing is ahead of origin/main any more). Safe to run more than once.
#
#   scripts/resume-release.sh 0.1.27                # waits for the CI runs, builds + uploads arm64, final check
#   scripts/resume-release.sh 0.1.27 --skip-arm64
#   scripts/resume-release.sh 0.1.27 --skip-post    # don't print the LinkedIn draft
#
# It never merges or tags anything. If either repo isn't tagged yet, it stops and says so (the release
# didn't happen; run cut-release.sh). It does not cover MCP packages or the docs PRs; check those with
# release-status.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

VERSION=""; SKIP_ARM64=0; SKIP_POST=0
for a in "$@"; do
  case "$a" in
    --skip-arm64) SKIP_ARM64=1 ;;
    --skip-post) SKIP_POST=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option: $a" ;;
    *) VERSION="$a" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/resume-release.sh X.Y.Z [--skip-arm64] [--skip-post]"

info "1. both repos tagged v$VERSION?"
for r in "${ENGINE[@]}"; do
  tag_exists "$r" "v$VERSION" && ok "$r has v$VERSION" || die "$r has no v$VERSION tag, so the release didn't happen (or auto-version is still running); run cut-release.sh, or wait and retry"
done

info "2. local checkouts at the tag"
for r in "${ENGINE[@]}"; do
  git_ "$r" fetch -q --tags origin
  [ -z "$(git_ "$r" status --porcelain)" ] || die "$r has uncommitted changes; commit or stash them first"
  git_ "$r" switch -q main && git_ "$r" pull -q --ff-only origin main
  [ "$(git_ "$r" rev-parse HEAD)" = "$(git_ "$r" rev-list -n1 "v$VERSION")" ] \
    && ok "$r is at v$VERSION" || die "$r main is not at v$VERSION (something merged after the release?); check it before building arm64"
done

info "3. image and native workflows on the tag"
for r in "${ENGINE[@]}"; do watch_workflow "$r" image.yml "v$VERSION"; watch_workflow "$r" native.yml "v$VERSION"; done
ok "images and native builds finished"

info "4. arm64 native tarballs"
if [ "$SKIP_ARM64" = 1 ]; then
  echo "  skipped (--skip-arm64)"
else
  have="$(gh release view "v$VERSION" --repo "$OWNER/VectorStep-Dist" --json assets --jq '[.assets[].name|select(test("linux-arm64.tar.gz$"))]|length' 2>/dev/null || echo 0)"
  if [ "$have" -ge 2 ]; then
    ok "arm64 tarballs already on the Dist release"
  else
    docker info >/dev/null 2>&1 || die "Docker is not running (needed for the arm64 build); start it, or pass --skip-arm64"
    "$SCRIPT_DIR/publish-native-arm64.sh" "$VERSION" || die "arm64 build/upload failed; fix it and re-run this script"
    ok "arm64 assets uploaded"
  fi
fi

info "5. final check"
"$SCRIPT_DIR/release-status.sh" || echo "release-status.sh reported problems; read its summary above"

POST="$(repo_path VectorStep-DevDocs)/src/content/docs/release-posts/v$VERSION-linkedin.md"
if [ "$SKIP_POST" = 0 ] && [ -s "$POST" ]; then
  post_text() { awk '/^---$/{buf=""; next} {buf=buf $0 "\n"} END{printf "%s", buf}' "$POST" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
  echo; echo "==> LinkedIn post (copied to the clipboard):"; echo; post_text
  command -v pbcopy >/dev/null 2>&1 && post_text | pbcopy && echo && echo "(copied)"
fi
echo; echo "Resumed release v$VERSION is complete. Next: upgrade the cluster images."
