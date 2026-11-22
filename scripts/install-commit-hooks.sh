#!/usr/bin/env bash
# Install a commit-msg hook in every sibling repo that removes Claude attribution lines
# (Co-Authored-By: Claude..., Claude-Session: ..., "Generated with Claude Code") from commit
# messages, so a commit made during a session always reads as yours. cut-release.sh also refuses to
# release if any such line is present, so this is a second layer, not the only one.
#
#   scripts/install-commit-hooks.sh
set -euo pipefail
ROOT="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"
for r in VectorStep VectorStep-Gateway VectorStep-Service-MCP VectorStep-Gateway-MCP VectorStep-Dist VectorStep-Website VectorStep-DevDocs; do
  [ -d "$ROOT/$r/.git" ] || { echo "skip $r (not found)"; continue; }
  hook="$ROOT/$r/.git/hooks/commit-msg"
  cat > "$hook" <<'HOOK'
#!/bin/sh
# Strip Claude attribution lines from the commit message.
f="$1"
grep -viE '^(co-authored-by:.*(claude|anthropic)|claude-session:|.*generated with \[?claude)' "$f" > "$f.tmp" || true
# drop trailing blank lines left behind
sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$f.tmp" > "$f" && rm -f "$f.tmp"
exit 0
HOOK
  chmod +x "$hook"
  echo "installed: $r"
done
