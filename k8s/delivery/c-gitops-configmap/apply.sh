#!/usr/bin/env bash
# Route C — turn a directory of config into the ConfigMaps the sidecars watch.
#
#   apply.sh <config-dir> [namespace]
#
# Layout (any may be absent; an absent one becomes an empty ConfigMap):
#   <config-dir>/pipelines/*.yaml          -> ConfigMap vectorstep-pipelines
#   <config-dir>/steps/*.yaml              -> ConfigMap vectorstep-steps
#   <config-dir>/agents/<name>/{agent.yaml,soul.md}
#                                          -> ConfigMap vectorstep-agents (flat keys <name>.agent.yaml, <name>.soul.md)
#   <config-dir>/skills/<name>/SKILL.md (+ any nested files, scripts keep +x)
#                                          -> ConfigMap vectorstep-skills (one <name>.tar.gz per skill)
# plus ConfigMap vectorstep-reloader from reloader.py (kept in step with this repo).
#
# Skills are directories, and ConfigMap keys cannot contain '/', so each skill is
# packed into one tarball. The packing is deterministic (sorted, fixed timestamps),
# so an unchanged skill produces an identical ConfigMap and nothing reloads.
# Needs python3 on the machine running this, only when a skills/ directory exists.
# All skills share one ConfigMap, which Kubernetes caps at 1 MiB (binary data is
# base64-encoded, so about 750 KB of tarballs); this fails early, with sizes, if
# you go over.
#
# Idempotent: re-running with no changes touches nothing. Kubernetes then syncs
# the changed ConfigMap into the pods (typically 1-2 minutes) and the
# config-reloader sidecar reloads the service within INTERVAL seconds of that.
#
# WAIT=1 (default) blocks until the sidecar reports a reload, so the CI job
# fails if the reload is rejected. WAIT_TIMEOUT seconds (default 300). Set
# WAIT=0 to return as soon as the ConfigMaps are applied.
#
# Needs kubectl access to create/patch ConfigMaps and read pod logs.
set -euo pipefail

src="${1:-}"; ns="${2:-${NAMESPACE:-vectorstep}}"
[[ -d "$src" ]] || { sed -n '2,8p' "$0"; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
k() { kubectl -n "$ns" "$@"; }
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
changed_vectorstep=0; changed_gateway=0; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

apply_cm() {  # apply_cm <name> <dir-with-files> [vectorstep|gateway]  (3rd arg: which service must reload on change)
  local out; out="$(k create configmap "$1" --from-file="$2" --dry-run=client -o yaml | k apply -f -)"
  echo "$out"
  if [[ "$out" != *unchanged* ]]; then
    case "${3:-}" in vectorstep) changed_vectorstep=1 ;; gateway) changed_gateway=1 ;; esac
  fi
}

mkdir -p "$stage/pipelines" "$stage/steps" "$stage/agents" "$stage/skills"
[[ -d "$src/pipelines" ]] && cp "$src"/pipelines/*.yaml "$stage/pipelines/" 2>/dev/null || true
[[ -d "$src/steps" ]]     && cp "$src"/steps/*.yaml     "$stage/steps/"     2>/dev/null || true
if [[ -d "$src/agents" ]]; then
  for d in "$src"/agents/*/; do
    [[ -f "$d/agent.yaml" ]] || continue; n="$(basename "$d")"
    cp "$d/agent.yaml" "$stage/agents/$n.agent.yaml"
    [[ -f "$d/soul.md" ]] && cp "$d/soul.md" "$stage/agents/$n.soul.md"
  done
fi
pack_skills() {  # pack_skills <skills-dir> <out-dir>: one deterministic <name>.tar.gz per skill
  command -v python3 >/dev/null || { echo "skills/ needs python3 on this machine to pack them" >&2; exit 2; }
  python3 "$here/pack-skills.py" "$1" "$2"
}
[[ -d "$src/skills" ]] && pack_skills "$src/skills" "$stage/skills"
# kubectl refuses an empty --from-file directory; a placeholder keeps the
# ConfigMap valid and is ignored by the loaders (not .yaml / .agent.yaml).
for d in pipelines steps agents skills; do
  [[ -n "$(ls -A "$stage/$d")" ]] || echo "# placeholder — no $d in git" > "$stage/$d/.placeholder"
done

mkdir -p "$stage/reloader"; cp "$here/reloader.py" "$stage/reloader/"
apply_cm vectorstep-reloader  "$stage/reloader"
apply_cm vectorstep-pipelines "$stage/pipelines" vectorstep
apply_cm vectorstep-steps     "$stage/steps"     vectorstep
apply_cm vectorstep-agents    "$stage/agents"    gateway
apply_cm vectorstep-skills    "$stage/skills"    gateway

if [[ "$changed_vectorstep$changed_gateway" == 00 ]]; then echo "no changes — nothing to reload"; exit 0; fi
[[ "${WAIT:-1}" == 1 ]] || { echo "applied; the sidecars will reload after the ConfigMaps sync (typically 1-2 min)"; exit 0; }

# Block until each affected sidecar reports a reload after $started.
deadline=$(( $(date +%s) + ${WAIT_TIMEOUT:-300} ))
status=0
for dep in vectorstep vectorstep-gateway; do
  # only wait on a service whose own ConfigMaps changed — an unchanged one never reloads
  if [[ "$dep" == vectorstep && "$changed_vectorstep" == 0 ]] || [[ "$dep" == vectorstep-gateway && "$changed_gateway" == 0 ]]; then continue; fi
  k get deploy "$dep" >/dev/null 2>&1 || continue
  k get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -qw config-reloader || continue
  echo "waiting for $dep to reload (up to ${WAIT_TIMEOUT:-300}s)"
  while :; do
    line="$(k logs deploy/"$dep" -c config-reloader --since-time="$started" 2>/dev/null | grep 'change detected' | tail -1 || true)"
    if [[ -n "$line" ]]; then
      echo "  $line"; [[ "$line" == *REJECTED* ]] && status=1; break
    fi
    (( $(date +%s) > deadline )) && { echo "  timed out waiting for $dep" >&2; status=1; break; }
    sleep 10
  done
done
exit $status
