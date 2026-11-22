#!/usr/bin/env bash
# Cut a VectorStep release end to end: check everything, then ship it through
# pull requests that the script merges itself once CI is green.
#
#   scripts/cut-release.sh --dry-run            # run every check, print the plan, push nothing
#   scripts/cut-release.sh                      # check, ask you to type the version, then release
#   scripts/cut-release.sh --version 0.2.0      # a minor/major bump instead of the next patch
#   scripts/cut-release.sh --skip-tests         # skip the local test runs (CI still runs them on the PRs)
#   scripts/cut-release.sh --skip-arm64         # don't build/upload the arm64 native tarballs (run publish-native-arm64.sh later)
#
# The working model (see RELEASING.md, "Definition of done" and "Cutting a release"):
#   * During a session, work is committed LOCALLY on a branch (never main), as you, with the
#     CHANGELOG [Unreleased] line and the docs for each change in the same branch.
#   * You test by hand. Then you run this script.
#   * Pushing to main IS a release for VectorStep and VectorStep-Gateway (auto-version.yml tags
#     every push), so nothing is pushed to main except by this script, via a merged PR.
#
# What it gates on (all must pass before anything is pushed):
#   - every repo with work is on a non-main branch, clean, and based on origin/main
#   - no commit carries a Claude attribution line, and every author is your git identity
#   - VectorStep and VectorStep-Gateway are in lockstep (same latest tag, both have work)
#   - each releasing repo's CHANGELOG [Unreleased] is not empty
#   - the website release notes have a "## vX.Y.Z" entry, and the site builds (links + notes check)
#   - each changed MCP package has a bumped pyproject version and an "MCP X.Y.Z" notes entry
#   - local tests pass (unless --skip-tests)
#   - Docker is running, for the arm64 native build (unless --skip-arm64)
#
# What it does, in order: roll the CHANGELOGs, then for each repo push the branch, open a PR, wait for
# CI, merge (merge commit, so your descriptive commits survive). Website and DevDocs first so the
# release-notes link is live; then VectorStep + Gateway back to back; then wait for the tags to match,
# the images and native builds to finish; then build and upload the arm64 native tarballs locally
# (publish-native-arm64.sh, which needs Docker); then tag and publish each changed MCP package and wait for it
# to appear on PyPI; finally run release-status.sh.
#
# Needs: git, gh (logged in), python3, npm, curl. Sibling checkouts, as in release-status.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"      # the directory holding all the sibling repos
OWNER="bantex01"

ENGINE=(VectorStep VectorStep-Gateway)
DOCS=(VectorStep-Website VectorStep-DevDocs)
MCP=(VectorStep-Service-MCP VectorStep-Gateway-MCP)

DRY=0; SKIP_TESTS=0; SKIP_ARM64=0; VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --skip-arm64) SKIP_ARM64=1 ;;
    --version) VERSION="${2:-}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ERRORS=()
info() { echo "==> $*"; }
ok()   { echo "  OK:   $*"; }
bad()  { echo "  FAIL: $*"; ERRORS+=("$*"); }
die()  { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || die "gh (GitHub CLI) not found"
command -v python3 >/dev/null || die "python3 not found"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"

repo_path() { echo "$ROOT/$1"; }
git_() { local r="$1"; shift; git -C "$(repo_path "$r")" "$@"; }
branch_of() { git_ "$1" rev-parse --abbrev-ref HEAD; }
ahead_of() { git_ "$1" rev-list --count origin/main..HEAD; }
latest_tag() { git_ "$1" tag --list 'v*' | sort -V | tail -1; }
semver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
pyproject_version() { sed -n 's/^version *= *"\(.*\)"/\1/p' "$(repo_path "$1")/pyproject.toml" | head -1; }
pypi_name() { sed -n 's/^name *= *"\(.*\)"/\1/p' "$(repo_path "$1")/pyproject.toml" | head -1; }
mcp_label() { case "$1" in VectorStep-Service-MCP) echo "Service MCP";; *) echo "Gateway MCP";; esac; }

# CHANGELOG [Unreleased] body has real content?
unreleased_nonempty() {
  python3 - "$(repo_path "$1")/CHANGELOG.md" <<'EOF'
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"## \[Unreleased\]\n(.*?)(?=\n## \[|\Z)",t,re.S)
sys.exit(0 if m and m.group(1).strip() else 1)
EOF
}

changelog_rolled() {  # repo version: already rolled (a re-run after a failed release)?
  grep -qF "## [$2]" "$(repo_path "$1")/CHANGELOG.md"
}

roll_changelog() {  # repo version
  if changelog_rolled "$1" "$2"; then info "$1: changelog already rolled for $2"; return 0; fi
  python3 - "$(repo_path "$1")/CHANGELOG.md" "$2" "$(date +%F)" <<'EOF'
import sys
p,v,d=sys.argv[1:]
t=open(p).read()
assert "## [Unreleased]\n" in t and f"## [{v}]" not in t, "changelog not in expected shape"
open(p,"w").write(t.replace("## [Unreleased]\n",f"## [Unreleased]\n\n## [{v}] - {d}\n",1))
EOF
  git_ "$1" add CHANGELOG.md
  git_ "$1" commit -q -m "Changelog: release $2"
}

# ---------------------------------------------------------------------------------------------
info "0. refresh remotes"
for r in "${ENGINE[@]}" "${DOCS[@]}" "${MCP[@]}"; do
  [ -d "$(repo_path "$r")/.git" ] || die "$r not found at $(repo_path "$r")"
  git_ "$r" fetch --quiet --tags origin || die "git fetch failed in $r"
done

# which repos have work
WORK=()
for r in "${ENGINE[@]}" "${DOCS[@]}" "${MCP[@]}"; do
  n="$(ahead_of "$r")"
  if [ "$n" -gt 0 ]; then WORK+=("$r"); fi
done
[ ${#WORK[@]} -gt 0 ] || die "nothing to release: no repo has commits ahead of origin/main"
has_work() { local x; for x in "${WORK[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

info "1. repo state"
for r in "${WORK[@]}"; do
  b="$(branch_of "$r")"
  [ "$b" != "main" ] && ok "$r: branch $b, $(ahead_of "$r") commit(s) ahead" || bad "$r: has commits but is on main; move them to a branch (git switch -c release/vX.Y.Z)"
  [ -z "$(git_ "$r" status --porcelain)" ] && true || bad "$r: uncommitted changes"
  git_ "$r" merge-base --is-ancestor origin/main HEAD || bad "$r: not based on origin/main; rebase it"
done

info "2. attribution and identity"
WANT_EMAIL="$(git config --global user.email)"
for r in "${WORK[@]}"; do
  if git_ "$r" log origin/main..HEAD --format=%B | grep -Eiq 'co-authored-by|claude-session|generated with|noreply@anthropic'; then
    bad "$r: a commit message carries a Claude/co-author line"
  fi
  other="$(git_ "$r" log origin/main..HEAD --format='%ae' | grep -vxF "$WANT_EMAIL" || true)"
  [ -z "$other" ] && ok "$r: all commits authored as $WANT_EMAIL" || bad "$r: commits authored by someone other than $WANT_EMAIL"
done

info "3. version and lockstep"
VS_TAG="$(latest_tag VectorStep)"; GW_TAG="$(latest_tag VectorStep-Gateway)"
ENGINE_RELEASE=0
if has_work VectorStep || has_work VectorStep-Gateway; then
  ENGINE_RELEASE=1
  [ "$VS_TAG" = "$GW_TAG" ] || bad "VectorStep is at $VS_TAG but Gateway at $GW_TAG; fix the lockstep first (run release-status.sh)"
  if has_work VectorStep && has_work VectorStep-Gateway; then ok "both engine repos have work"
  else bad "only $(has_work VectorStep && echo VectorStep || echo VectorStep-Gateway) has work; the pair must release together, so make a real change (even a changelog line) in the other, or tag it by hand"; fi
  if [ -z "$VERSION" ]; then
    IFS=. read -r MA MI PA <<<"${VS_TAG#v}"; VERSION="$MA.$MI.$((PA+1))"
  fi
  semver_gt "$VERSION" "${VS_TAG#v}" && ok "next release: v$VERSION (latest $VS_TAG)" || bad "version $VERSION is not newer than $VS_TAG"
  PATCH_BUMP=0; [ "$VERSION" = "${VS_TAG#v}" ] || { IFS=. read -r a b c <<<"$VERSION"; IFS=. read -r x y z <<<"${VS_TAG#v}"; [ "$a.$b" = "$x.$y" ] && [ "$c" = "$((z+1))" ] && PATCH_BUMP=1; }
  [ "$PATCH_BUMP" = 1 ] || bad "v$VERSION is not the next patch of $VS_TAG; auto-version.yml would tag a different number. For a minor/major bump tag by hand (RELEASING.md) instead"
fi

info "4. changelogs"
for r in "${ENGINE[@]}" "${MCP[@]}"; do
  has_work "$r" || continue
  if [[ " ${ENGINE[*]} " == *" $r "* ]] && changelog_rolled "$r" "$VERSION"; then
    ok "$r: changelog already rolled for $VERSION (resuming)"; continue
  fi
  unreleased_nonempty "$r" && ok "$r: [Unreleased] has entries" || bad "$r: CHANGELOG [Unreleased] is empty; add what changed"
done

info "5. release notes and website build"
NOTES="$(repo_path VectorStep-Website)/src/content/docs/docs/about/release-notes.md"
if [ "$ENGINE_RELEASE" = 1 ]; then
  grep -qx "## v$VERSION" "$NOTES" && ok "release notes have ## v$VERSION" || bad "release notes have no '## v$VERSION' entry (VectorStep-Website, about/release-notes.md)"
fi
MCP_VERSIONS=()
for r in "${MCP[@]}"; do
  has_work "$r" || continue
  v="$(pyproject_version "$r")"; last="$(latest_tag "$r")"
  if semver_gt "$v" "${last#v}"; then ok "$r: pyproject $v is newer than $last"; else bad "$r: pyproject version $v is not bumped past $last"; fi
  grep -qx "## $(mcp_label "$r") $v" "$NOTES" && ok "release notes have ## $(mcp_label "$r") $v" || bad "release notes have no '## $(mcp_label "$r") $v' entry"
  MCP_VERSIONS+=("$r=$v")
done
if [ -d "$(repo_path VectorStep-Website)/node_modules" ]; then
  (cd "$(repo_path VectorStep-Website)" && npm run build >/tmp/cut-release-website-build.log 2>&1) \
    && ok "website builds; links and release notes check pass" || bad "website build failed (see /tmp/cut-release-website-build.log)"
else
  bad "VectorStep-Website has no node_modules; run npm install there"
fi

info "6. tests"
if [ "$SKIP_TESTS" = 1 ]; then echo "  skipped (--skip-tests); CI still runs them on each PR"
else
  if has_work VectorStep; then
    (cd "$(repo_path VectorStep)/service" && DO_NOT_TRACK=1 .venv/bin/python -m pytest -q >/tmp/cut-release-vs-tests.log 2>&1) \
      && ok "VectorStep tests pass" || bad "VectorStep tests failed (see /tmp/cut-release-vs-tests.log)"
  fi
  if has_work VectorStep-Gateway; then
    (cd "$(repo_path VectorStep-Gateway)" && DO_NOT_TRACK=1 python3 -m pytest -q >/tmp/cut-release-gw-tests.log 2>&1) \
      && ok "Gateway tests pass" || bad "Gateway tests failed (see /tmp/cut-release-gw-tests.log)"
  fi
fi

info "7. arm64 build prerequisites"
if [ "$ENGINE_RELEASE" = 1 ] && [ "$SKIP_ARM64" = 0 ]; then
  docker info >/dev/null 2>&1 && ok "Docker is running (arm64 native build)" || bad "Docker is not running; start it, or pass --skip-arm64 and run publish-native-arm64.sh $VERSION later"
  [ -x "$(repo_path VectorStep)/service/native/build.sh" ] && [ -x "$(repo_path VectorStep-Gateway)/native/build.sh" ] \
    && ok "native build scripts found" || bad "native/build.sh missing or not executable in VectorStep or VectorStep-Gateway"
else
  echo "  skipped"
fi

echo
info "plan"
for r in "${WORK[@]}"; do
  echo "  $r  ($(branch_of "$r"))"
  git_ "$r" log origin/main..HEAD --format='      %h %s'
done
[ "$ENGINE_RELEASE" = 1 ] && echo "  engine release: v$VERSION (VectorStep + Gateway)"
[ "$ENGINE_RELEASE" = 1 ] && [ "$SKIP_ARM64" = 0 ] && echo "  arm64 native tarballs: built locally and uploaded to VectorStep-Dist v$VERSION"
for mv in "${MCP_VERSIONS[@]:-}"; do [ -n "$mv" ] && echo "  MCP release: ${mv%%=*} v${mv#*=} (tag, then PyPI)"; done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo; echo "NOT READY: ${#ERRORS[@]} problem(s):"; printf '  - %s\n' "${ERRORS[@]}"; exit 1
fi
if [ "$DRY" = 1 ]; then echo; echo "dry run: every check passed; nothing was changed or pushed."; exit 0; fi

echo
TARGET="${VERSION:-$(for mv in "${MCP_VERSIONS[@]:-}"; do echo "${mv#*=}"; done | head -1)}"
read -r -p "This will push, open PRs and MERGE them (an engine merge is a release). Type '$TARGET' to continue: " ans
[ "$ans" = "$TARGET" ] || die "aborted"

# ---------------------------------------------------------------------------------------------
checks_then_merge_prepare() {  # repo -> prints PR number; pushes branch, opens PR, waits for CI
  local r="$1" title="$2" b pr
  b="$(branch_of "$r")"
  git_ "$r" push -q -u origin "$b"
  # reuse an open PR for this branch (a re-run after a failed release), else open one
  pr="$(gh pr list --repo "$OWNER/$r" --head "$b" --state open --json number --jq '.[0].number // empty')"
  if [ -z "$pr" ]; then
    pr="$(gh pr create --repo "$OWNER/$r" --base main --head "$b" --title "$title" \
          --body "$(printf 'Release PR for %s.\n\nCommits:\n%s\n' "$title" "$(git_ "$r" log origin/main..HEAD --format='- %s')")")"
    pr="${pr##*/}"
  else
    info "$r: reusing open PR #$pr" >&2
  fi
  sleep 15
  if [ "$(gh pr checks "$pr" --repo "$OWNER/$r" --json name --jq length 2>/dev/null || echo 0)" -gt 0 ]; then
    gh pr checks "$pr" --repo "$OWNER/$r" --watch --fail-fast >&2 || die "$r: CI failed on PR #$pr; fix it, then re-run"
  fi
  echo "$pr"
}
merge_pr() {  # repo pr
  gh pr merge "$2" --repo "$OWNER/$1" --merge --delete-branch >/dev/null
  git_ "$1" switch -q main 2>/dev/null || true
  git_ "$1" pull -q --ff-only origin main
}
wait_tag() {  # repo tag
  local i
  for i in $(seq 1 40); do
    git ls-remote --tags "https://github.com/$OWNER/$1.git" "refs/tags/$2" | grep -q "$2" && return 0
    sleep 30
  done
  return 1
}
watch_workflow() {  # repo workflow ref
  local id i
  for i in $(seq 1 20); do
    id="$(gh run list --repo "$OWNER/$1" --workflow "$2" --branch "$3" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    [ -n "$id" ] && break; sleep 30
  done
  [ -n "${id:-}" ] || die "$1: no $2 run found for $3"
  gh run watch "$id" --repo "$OWNER/$1" --exit-status >/dev/null || die "$1: $2 failed for $3"
}

info "7. roll changelogs"
for r in "${ENGINE[@]}"; do has_work "$r" && roll_changelog "$r" "$VERSION"; done
for mv in "${MCP_VERSIONS[@]:-}"; do [ -n "$mv" ] && roll_changelog "${mv%%=*}" "${mv#*=}"; done

info "8. docs: website first, so the release-notes link is live"
for r in "${DOCS[@]}"; do
  has_work "$r" || continue
  pr="$(checks_then_merge_prepare "$r" "Release notes and docs for ${VERSION:-the next release}")"
  merge_pr "$r" "$pr"; ok "$r merged (#$pr)"
done
if has_work VectorStep-Website; then watch_workflow VectorStep-Website deploy.yml main; ok "website deployed"; fi

if [ "$ENGINE_RELEASE" = 1 ]; then
  info "9. engine pair (merging is the release)"
  vs_pr="$(checks_then_merge_prepare VectorStep "Release v$VERSION")"
  gw_pr="$(checks_then_merge_prepare VectorStep-Gateway "Release v$VERSION")"
  merge_pr VectorStep "$vs_pr"; merge_pr VectorStep-Gateway "$gw_pr"
  wait_tag VectorStep "v$VERSION" && wait_tag VectorStep-Gateway "v$VERSION" || die "tag v$VERSION did not appear in both repos; run release-status.sh"
  ok "both repos tagged v$VERSION"
  for r in "${ENGINE[@]}"; do watch_workflow "$r" image.yml "v$VERSION"; watch_workflow "$r" native.yml "v$VERSION"; done
  ok "images and native builds finished"

  if [ "$SKIP_ARM64" = 0 ]; then
    info "9b. arm64 native tarballs (local Docker build, uploaded to the Dist release)"
    # The build must come from the tagged commit, not whatever a local checkout happens to hold.
    for r in "${ENGINE[@]}"; do
      [ "$(git_ "$r" rev-parse HEAD)" = "$(git_ "$r" rev-list -n1 "v$VERSION")" ] \
        || die "$r: local checkout is not at v$VERSION; pull main, then run scripts/publish-native-arm64.sh $VERSION"
    done
    "$SCRIPT_DIR/publish-native-arm64.sh" "$VERSION" || die "arm64 build/upload failed; fix it and run scripts/publish-native-arm64.sh $VERSION"
    ok "arm64 assets uploaded to VectorStep-Dist v$VERSION"
  else
    echo "  skipped (--skip-arm64); run scripts/publish-native-arm64.sh $VERSION when ready"
  fi
fi

for mv in "${MCP_VERSIONS[@]:-}"; do
  [ -n "$mv" ] || continue
  r="${mv%%=*}"; v="${mv#*=}"
  info "10. $r v$v"
  pr="$(checks_then_merge_prepare "$r" "Release v$v")"
  merge_pr "$r" "$pr"
  git_ "$r" tag "v$v"; git_ "$r" push -q origin "v$v"
  watch_workflow "$r" publish.yml "v$v"
  name="$(pypi_name "$r")"
  for i in $(seq 1 20); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "https://pypi.org/pypi/$name/$v/json")" = 200 ] && { ok "$name $v is on PyPI"; break; }
    [ "$i" = 20 ] && die "$name $v not on PyPI after publish; check the workflow"; sleep 30
  done
done

info "11. final check"
"$SCRIPT_DIR/release-status.sh" || echo "release-status.sh reported problems; read its summary above"
echo; echo "Released. Next: upgrade the cluster images, then use any new pipeline options."
