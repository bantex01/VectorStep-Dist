#!/usr/bin/env bash
# Shell-step scripts (executor: shell) on Kubernetes — works with any delivery route.
#
#   shell-scripts.sh sha256 <scripts-dir>                 print the `allowed:` entries (name, path, sha256)
#   shell-scripts.sh check  <scripts-dir> <config.yaml>   fail unless every script's sha256 is pinned in config.yaml
#   shell-scripts.sh apply  <scripts-dir> [namespace]     create/update ConfigMap vectorstep-shell-scripts, then restart
#
# Why a restart and not a reload: the service reads security.shell_steps (the
# allowlist and its sha256 pins) once at startup, on purpose, so a script change
# only takes effect when the pod restarts. `apply` does that for you with a
# rolling restart (RESTART=0 to skip it, for example when your GitOps controller
# restarts the pod).
#
# The scripts reach the pod as a read-only ConfigMap volume at
# /etc/vectorstep/scripts — never the /data volume, which the write API can
# reach. See the commented "scripts" volume in service/deployment.yaml; it must
# set defaultMode: 0555 or the service rejects the scripts as not executable.
#
# Order for a change: edit the script, run `sha256`, paste the new sha256 into
# config.yaml's security.shell_steps.allowed, then `apply` BOTH the script and
# the config ConfigMap before the restart. `check` is the guard for your merge
# request: it catches a script whose pin was forgotten.
#
# Needs sha256sum or shasum. `apply` needs kubectl access to create/patch
# ConfigMaps and patch the Deployment.
set -euo pipefail

cmd="${1:-}"; dir="${2:-}"
[[ -n "$cmd" && -d "$dir" ]] || { sed -n '2,6p' "$0"; exit 2; }

hash_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

scripts() { find "$dir" -maxdepth 1 -type f ! -name '.*' | sort; }

case "$cmd" in
  sha256)
    echo "# paste under security.shell_steps in config.yaml"
    echo "allowed:"
    while read -r f; do
      n="$(basename "$f")"
      printf '  - name: %s\n    path: %s\n    sha256: %s\n' "${n%.*}" "$n" "$(hash_file "$f")"
    done < <(scripts)
    ;;
  check)
    cfg="${3:-}"; [[ -f "$cfg" ]] || { echo "usage: $0 check <scripts-dir> <config.yaml>" >&2; exit 2; }
    bad=0
    while read -r f; do
      h="$(hash_file "$f")"
      if grep -q "$h" "$cfg"; then echo "ok    $(basename "$f")"
      else echo "FAIL  $(basename "$f"): sha256 $h is not pinned in $cfg" >&2; bad=1; fi
    done < <(scripts)
    exit $bad
    ;;
  apply)
    ns="${3:-${NAMESPACE:-vectorstep}}"
    k() { kubectl -n "$ns" "$@"; }
    out="$(k create configmap vectorstep-shell-scripts --from-file="$dir" --dry-run=client -o yaml | k apply -f -)"
    echo "$out"
    if [[ "$out" == *unchanged* ]]; then echo "no change to the scripts — nothing to restart"; exit 0; fi
    [[ "${RESTART:-1}" == 1 ]] || { echo "applied; restart the service for it to take effect"; exit 0; }
    k rollout restart deploy/vectorstep
    k rollout status deploy/vectorstep --timeout="${ROLLOUT_TIMEOUT:-300s}"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
