#!/usr/bin/env bash
# Route A — push config to a running VectorStep over its write API.
#
#   push.sh validate [config-dir]   dry-run every file; changes nothing
#   push.sh apply    [config-dir]   create-or-update every file, then it is live
#
# Each write is validated first, written atomically and followed by a reload in
# the same call, so a bad change is rejected and the running config stays
# untouched. Works from any CI (GitLab, GitHub Actions, Jenkins) or a laptop.
#
# Layout (any of the three directories may be absent):
#   <config-dir>/steps/*.yaml
#   <config-dir>/pipelines/*.yaml
#   <config-dir>/agents/<name>/agent.yaml + soul.md        (needs GATEWAY_URL)
#
# Environment:
#   VECTORSTEP_URL            e.g. https://vectorstep.example.com   (steps, pipelines)
#   VECTORSTEP_ADMIN_TOKEN    admin-role token for the service
#   GATEWAY_URL               e.g. https://gateway.example.com      (agents; optional)
#   GATEWAY_ADMIN_TOKEN       the Gateway's admin token             (agents; optional)
#   CURL_OPTS                 extra curl flags, e.g. "--cacert ca.pem"
#
# Order matters and is handled: steps, then agents, then pipelines (pipelines
# reference both). Note that `validate` checks against what is *already live*,
# so a pipeline that uses a step added in the same change fails validation until
# the step is applied — validate on the merge request, apply on merge.
#
# Files deleted from git are NOT deleted from the cluster; remove them with
# DELETE /pipelines/{name} (etc.) — see the docs.
set -euo pipefail

mode="${1:-}"; dir="${2:-config}"
[[ "$mode" == "validate" || "$mode" == "apply" ]] || { sed -n '2,12p' "$0"; exit 2; }
command -v jq >/dev/null   || { echo "push.sh needs jq" >&2; exit 2; }
command -v curl >/dev/null || { echo "push.sh needs curl" >&2; exit 2; }

failures=0
# call <base-url> <token> <path> <json-body-file> <label>
call() {
  local base="$1" token="$2" path="$3" body="$4" label="$5" out code
  out="$(mktemp)"
  # shellcheck disable=SC2086
  code="$(curl -sS ${CURL_OPTS:-} -o "$out" -w '%{http_code}' -X POST "${base%/}${path}" \
          -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
          --data @"$body")" || { echo "FAIL  $label (could not reach ${base})" >&2; failures=$((failures+1)); rm -f "$out"; return; }
  if [[ "$mode" == "validate" ]]; then
    if [[ "$code" == 200 && "$(jq -r '.valid' "$out")" == "true" ]]; then echo "ok    $label"
    else echo "FAIL  $label"; jq -r '.errors[]? | "        " + (.loc|map(tostring)|join(".")) + ": " + .msg' "$out" 2>/dev/null || cat "$out"; failures=$((failures+1)); fi
  else
    if [[ "$code" == 200 ]]; then echo "ok    $label"
    else echo "FAIL  $label (HTTP $code)"; jq -r '.detail | if type=="object" then .message // . else . end' "$out" 2>/dev/null || cat "$out"; failures=$((failures+1)); fi
  fi
  rm -f "$out"
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
suffix=""; [[ "$mode" == "validate" ]] && suffix="/validate"

if compgen -G "$dir/steps/*.yaml" >/dev/null; then
  : "${VECTORSTEP_URL:?set VECTORSTEP_URL}" "${VECTORSTEP_ADMIN_TOKEN:?set VECTORSTEP_ADMIN_TOKEN}"
  for f in "$dir"/steps/*.yaml; do
    jq -Rs '{yaml: ., overwrite: true}' "$f" > "$tmp"
    call "$VECTORSTEP_URL" "$VECTORSTEP_ADMIN_TOKEN" "/steps${suffix}" "$tmp" "step      $(basename "$f")"
  done
fi

if compgen -G "$dir/agents/*/agent.yaml" >/dev/null; then
  : "${GATEWAY_URL:?agents found — set GATEWAY_URL}" "${GATEWAY_ADMIN_TOKEN:?agents found — set GATEWAY_ADMIN_TOKEN}"
  for d in "$dir"/agents/*/; do
    name="$(basename "$d")"; [[ -f "$d/agent.yaml" ]] || continue
    soul=/dev/null; [[ -f "$d/soul.md" ]] && soul="$d/soul.md"
    jq -n --arg n "$name" --rawfile a "$d/agent.yaml" --rawfile s "$soul" \
      '{name: $n, agent_yaml: $a, soul_md: $s, overwrite: true}' > "$tmp"
    call "$GATEWAY_URL" "$GATEWAY_ADMIN_TOKEN" "/agents${suffix}" "$tmp" "agent     $name"
  done
fi

if compgen -G "$dir/pipelines/*.yaml" >/dev/null; then
  : "${VECTORSTEP_URL:?set VECTORSTEP_URL}" "${VECTORSTEP_ADMIN_TOKEN:?set VECTORSTEP_ADMIN_TOKEN}"
  for f in "$dir"/pipelines/*.yaml; do
    jq -Rs '{yaml: ., overwrite: true}' "$f" > "$tmp"
    call "$VECTORSTEP_URL" "$VECTORSTEP_ADMIN_TOKEN" "/pipelines${suffix}" "$tmp" "pipeline  $(basename "$f")"
  done
fi

if (( failures > 0 )); then
  echo "$failures file(s) failed" >&2
  if [[ "$mode" == "validate" ]] && compgen -G "$dir/steps/*.yaml" >/dev/null; then
    echo "hint: validate checks against what is already live. A pipeline that uses a step added in this" >&2
    echo "      same change will fail here until the step is applied — that is expected, not a bad file." >&2
  fi
  exit 1
fi
echo "done"
