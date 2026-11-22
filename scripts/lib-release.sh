#!/usr/bin/env bash
# Helpers shared by resume-release.sh and publish-docs.sh. Source it; it runs nothing itself.
# (cut-release.sh carries its own copies of these.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"      # the directory holding all the sibling repos
OWNER="bantex01"
ENGINE=(VectorStep VectorStep-Gateway)
DOCS=(VectorStep-Website VectorStep-DevDocs)
MCP=(VectorStep-Service-MCP VectorStep-Gateway-MCP)

ERRORS=()
info() { echo "==> $*"; }
ok()   { echo "  OK:   $*"; }
warn() { echo "  WARN: $*"; }
bad()  { echo "  FAIL: $*"; ERRORS+=("$*"); }
die()  { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || die "gh (GitHub CLI) not found"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"

repo_path() { echo "$ROOT/$1"; }
git_() { local r="$1"; shift; git -C "$(repo_path "$r")" "$@"; }
branch_of() { git_ "$1" rev-parse --abbrev-ref HEAD; }
ahead_of() { git_ "$1" rev-list --count origin/main..HEAD; }

# commits ahead of origin/main must be authored as you and carry no Claude attribution
check_attribution() {  # repo
  local r="$1" want bad_authors trailers
  want="$(git config --global user.email)"
  bad_authors="$(git_ "$r" log origin/main..HEAD --format='%ae' | grep -vxF "$want" | sort -u | head -3 || true)"
  trailers="$(git_ "$r" log origin/main..HEAD --format=%B | grep -iE '^(co-authored-by:.*(claude|anthropic)|claude-session:)|generated with \[?claude' | head -3 || true)"
  [ -z "$bad_authors" ] && ok "$r: all commits authored as $want" || bad "$r: commits authored by someone else: $bad_authors"
  [ -z "$trailers" ] && true || bad "$r: Claude attribution in a commit message; run scripts/install-commit-hooks.sh and reword"
}

checks_then_merge_prepare() {  # repo title -> prints PR number; pushes branch, opens/reuses PR, waits for CI
  local r="$1" title="$2" b pr
  b="$(branch_of "$r")"
  git_ "$r" push -q -u origin "$b"
  pr="$(gh pr list --repo "$OWNER/$r" --head "$b" --state open --json number --jq '.[0].number // empty')"
  if [ -z "$pr" ]; then
    pr="$(gh pr create --repo "$OWNER/$r" --base main --head "$b" --title "$title" \
          --body "$(printf '%s\n\nCommits:\n%s\n' "$title" "$(git_ "$r" log origin/main..HEAD --format='- %s')")")"
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
    gh api "repos/$OWNER/$1/git/ref/tags/$2" >/dev/null 2>&1 && return 0
    sleep 30
  done
  return 1
}
tag_exists() { gh api "repos/$OWNER/$1/git/ref/tags/$2" >/dev/null 2>&1; }
watch_workflow() {  # repo workflow ref
  local id i
  for i in $(seq 1 20); do
    id="$(gh run list --repo "$OWNER/$1" --workflow "$2" --branch "$3" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    [ -n "$id" ] && break; sleep 30
  done
  [ -n "${id:-}" ] || die "$1: no $2 run found for $3"
  gh run watch "$id" --repo "$OWNER/$1" --exit-status >/dev/null || die "$1: $2 failed for $3"
}
