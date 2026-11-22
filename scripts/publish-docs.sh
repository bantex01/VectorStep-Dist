#!/usr/bin/env bash
# Publish documentation changes that are NOT part of a release: commits you (via a session) made on a
# branch in VectorStep-Website and/or VectorStep-DevDocs. Pushes the branch, opens a PR, waits for its
# checks, merges it, and (for the Website) waits for the deploy. No version, tag, image or PyPI step.
#
#   scripts/publish-docs.sh --dry-run
#   scripts/publish-docs.sh
#
# Refuses if: a repo is on main or dirty, commits aren't yours or carry Claude attribution, the Website
# doesn't build (links, release notes), or the Website diff adds a "## vX.Y.Z" release-notes heading for a
# version that isn't tagged yet (that's a release; use cut-release.sh). Warns, and asks, if VectorStep or the
# Gateway have unreleased work, since the docs may describe a feature users can't have yet.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

info "0. refresh remotes"
for r in "${DOCS[@]}" "${ENGINE[@]}" "${MCP[@]}"; do
  [ -d "$(repo_path "$r")/.git" ] || die "$r not found at $(repo_path "$r")"
  git_ "$r" fetch -q --tags origin || die "git fetch failed in $r"
done

WORK=()
for r in "${DOCS[@]}"; do [ "$(ahead_of "$r")" -gt 0 ] && WORK+=("$r"); done
[ ${#WORK[@]} -gt 0 ] || die "nothing to publish: neither docs repo has commits ahead of origin/main"

info "1. repo state and attribution"
for r in "${WORK[@]}"; do
  b="$(branch_of "$r")"
  [ "$b" != main ] && ok "$r: branch $b, $(ahead_of "$r") commit(s) ahead" || bad "$r: has commits but is on main; move them to a branch (git switch -c docs/...)"
  [ -z "$(git_ "$r" status --porcelain)" ] || bad "$r: uncommitted changes"
  git_ "$r" merge-base --is-ancestor origin/main HEAD || bad "$r: not based on origin/main; rebase it"
  check_attribution "$r"
done

info "2. nothing here belongs to an unreleased version"
if printf '%s\n' "${WORK[@]}" | grep -qx VectorStep-Website; then
  W=VectorStep-Website
  for v in $(git_ $W diff origin/main -- src/content/docs/docs/about/release-notes.md | sed -n 's/^+## v\([0-9][0-9.]*\)$/\1/p'); do
    tag_exists VectorStep "v$v" && ok "release notes add v$v, which is tagged" \
      || bad "release notes add '## v$v' but VectorStep has no v$v tag: that's part of a release, use cut-release.sh"
  done
fi
PENDING=()
for r in "${ENGINE[@]}"; do [ "$(ahead_of "$r")" -gt 0 ] && PENDING+=("$r"); done
[ ${#PENDING[@]} -eq 0 ] && ok "no unreleased engine work" || warn "unreleased work in: ${PENDING[*]}; these docs may describe something users can't have yet"

info "3. website build"
if printf '%s\n' "${WORK[@]}" | grep -qx VectorStep-Website; then
  if [ -d "$(repo_path VectorStep-Website)/node_modules" ]; then
    (cd "$(repo_path VectorStep-Website)" && npm run build >/tmp/publish-docs-build.log 2>&1) \
      && ok "website builds; links and release notes check pass" || bad "website build failed (see /tmp/publish-docs-build.log)"
  else bad "VectorStep-Website has no node_modules; run npm install there"; fi
else
  echo "  (Website has no changes)"
fi

echo; info "plan"
for r in "${WORK[@]}"; do echo "  $r  ($(branch_of "$r"))"; git_ "$r" log origin/main..HEAD --format='      %h %s'; done
if [ ${#ERRORS[@]} -gt 0 ]; then echo; echo "NOT READY: ${#ERRORS[@]} problem(s):"; printf '  - %s\n' "${ERRORS[@]}"; exit 1; fi
if [ "$DRY" = 1 ]; then echo; echo "dry run: every check passed; nothing was changed or pushed."; exit 0; fi

echo
if [ ${#PENDING[@]} -gt 0 ]; then
  read -r -p "Engine work is unreleased (see the warning). Publish these docs anyway? Type 'docs' to continue: " ans
else
  read -r -p "This will push, open PRs and MERGE them (the Website redeploys). Type 'docs' to continue: " ans
fi
[ "$ans" = docs ] || die "aborted"

for r in "${WORK[@]}"; do
  info "4. $r"
  pr="$(checks_then_merge_prepare "$r" "Docs update (not a release)")"
  merge_pr "$r" "$pr"; ok "$r merged (#$pr)"
  [ "$r" = VectorStep-Website ] && { watch_workflow "$r" deploy.yml main; ok "website deployed"; }
done
echo; echo "Published. Nothing was released."
