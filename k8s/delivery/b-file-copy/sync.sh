#!/usr/bin/env bash
# Route B — copy config files into the running pod and hot-reload, with
# automatic rollback if the reload is rejected.
#
#   sync.sh <service|gateway> <local-dir> [namespace]
#
#   service  <local-dir> holds   pipelines/  steps/            -> /data/pipelines, /data/steps
#   gateway  <local-dir> holds   agents/<name>/{agent.yaml,soul.md}  skills/<name>/...
#                                                              -> /data/agents,   /data/skills
#
# Needs only kubectl access (RBAC: see ci-rbac.example.yaml) — no VectorStep
# tokens leave the cluster: the reload is made from inside the pod using the
# admin token it already has in its environment.
#
# Safety: files are validated only by the reload itself, and a bad file left on
# disk would be skipped at the next restart (or, on v0.1.10 and earlier, stop the
# pod starting at all). So this script snapshots the target directories first, and if the reload is rejected it
# restores the snapshot, reloads again, and exits non-zero (failing the CI job).
#
# Copies add and overwrite files; files deleted from git are NOT removed from
# the pod. Use REMOVE_MISSING=1 to make the target directories exactly match
# <local-dir> (deletes anything not in git — only for fully git-managed config).
set -euo pipefail
export COPYFILE_DISABLE=1   # macOS tar: no ._* AppleDouble junk files in the pod

target="${1:-}"; src="${2:-}"; ns="${3:-${NAMESPACE:-vectorstep}}"
case "$target" in
  service) deploy=deploy/vectorstep;         container=vectorstep;         port=8000;  tokenvar=VECTORSTEP_ADMIN_TOKEN;         dirs="pipelines steps" ;;
  gateway) deploy=deploy/vectorstep-gateway; container=vectorstep-gateway; port=18780; tokenvar=VECTORSTEP_GATEWAY_ADMIN_TOKEN; dirs="agents skills" ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
[[ -d "$src" ]] || { echo "no such directory: $src" >&2; exit 2; }
# Override these if you renamed the Deployments/containers or use TLS.
deploy="${DEPLOYMENT:-$deploy}"; container="${CONTAINER:-$container}"
scheme="${RELOAD_SCHEME:-http}"
k() { kubectl -n "$ns" "$@"; }
kx() { k exec "$deploy" -c "$container" -- "$@"; }

# Reload from inside the pod. urllib raises on a non-2xx, so a rejected reload
# makes this exit non-zero and prints the server's explanation.
reload() {
  kx python -c "
import os, sys, urllib.request as u, urllib.error as e
r = u.Request('${scheme}://localhost:${port}/reload', method='POST',
              headers={'Authorization': 'Bearer ' + os.environ['${tokenvar}']})
try: print(u.urlopen(r, timeout=30).read().decode())
except e.HTTPError as x: print('reload rejected (HTTP %s): %s' % (x.code, x.read().decode()[:1500])); sys.exit(1)
"
}

present=""
for d in $dirs; do [[ -d "$src/$d" ]] && present="$present $d"; done
[[ -n "$present" ]] || { echo "nothing to do: $src has none of: $dirs" >&2; exit 0; }

snap=/tmp/vs-sync-snapshot.tar
echo "snapshotting current /data/{${present# }} in the pod"
# shellcheck disable=SC2086
kx sh -c "cd /data && tar cf $snap $(for d in $present; do printf '%s ' "$d"; done)"

echo "copying files"
for d in $present; do
  if [[ "${REMOVE_MISSING:-0}" == "1" ]]; then
    kx sh -c "find /data/$d -mindepth 1 -delete"
  fi
  tar -C "$src/$d" -cf - . | k exec -i "$deploy" -c "$container" -- tar -C "/data/$d" -xf -
done

echo "reloading"
if reload; then
  echo "done"
else
  echo "rolling back to the snapshot" >&2
  # shellcheck disable=SC2086
  kx sh -c "cd /data && for d in $present; do find \"/data/\$d\" -mindepth 1 -delete; done; tar xf $snap"
  reload >/dev/null || echo "WARNING: reload after rollback also failed — inspect the pod" >&2
  exit 1
fi
