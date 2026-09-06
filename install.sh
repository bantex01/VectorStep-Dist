#!/usr/bin/env bash
# VectorStep installer.
#
#   curl -sSL https://raw.githubusercontent.com/bantex01/VectorStep-Dist/main/install.sh | bash
#
# Installs the VectorStep orchestration service and, by default, the Gateway
# agent runtime, as Docker containers. Nothing is compiled and no source is
# cloned — the images come from ghcr.io.
#
# Safe to run more than once: existing config.yaml and .env files are never
# overwritten, so re-running upgrades images without touching your settings.
#
# Options:
#   --service-only   Skip the Gateway. Use this if you drive VectorStep with
#                    OpenClaw, or with webhook/human/notify-only pipelines, or
#                    if the Gateway already runs elsewhere.
#   --dir PATH       Install somewhere other than ~/.vectorstep.
#   --version TAG    Image tag to run (default: latest).

set -euo pipefail

INSTALL_DIR="${VECTORSTEP_HOME:-$HOME/.vectorstep}"
DIST_BASE="${VECTORSTEP_DIST_BASE:-https://raw.githubusercontent.com/bantex01/VectorStep-Dist/main}"
WITH_GATEWAY=1
WITH_POSTGRES=0
VERSION_TAG=""

log()  { printf '==> %s\n' "$1"; }
skip() { printf '==> skip: %s\n' "$1"; }
warn() { printf '==> warning: %s\n' "$1" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- Arguments -------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --service-only) WITH_GATEWAY=0; shift ;;
    --postgres)     WITH_POSTGRES=1; shift ;;
    --dir)          INSTALL_DIR="${2:?--dir needs a path}"; shift 2 ;;
    --version)      VERSION_TAG="${2:?--version needs a tag}"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
VectorStep installer.

  --service-only   Skip the Gateway. Use this if you drive VectorStep with
                   OpenClaw, with webhook/human/notify-only pipelines, or if
                   the Gateway already runs elsewhere.
  --postgres       Run PostgreSQL instead of SQLite, in its own container,
                   with a generated password. Choose this at FIRST install —
                   switching later does not migrate existing data.
  --dir PATH       Install somewhere other than ~/.vectorstep.
  --version TAG    Image tag to run (default: latest).

Docs: https://vectorstep.io/docs/getting-started/quick-start/
USAGE
      exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

# --- Preflight -------------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl not found on PATH."
command -v docker >/dev/null 2>&1 || die "Docker not found. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux) and re-run."
docker info </dev/null >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and re-run."
docker compose version </dev/null >/dev/null 2>&1 || die "Docker Compose v2 not found. It ships with current Docker; if you only have the old 'docker-compose' binary, upgrade Docker."

log "preflight ok (docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), compose $(docker compose version --short 2>/dev/null || echo '?'))"

# --- Fetch stack files -----------------------------------------------------

mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/pipelines" "$INSTALL_DIR/steps"
[ "$WITH_GATEWAY" = 1 ] && mkdir -p "$INSTALL_DIR/agents"
cd "$INSTALL_DIR"

fetch() { # fetch <remote-path> <local-path> <overwrite:yes|no>
  if [ "$3" = "no" ] && [ -f "$2" ]; then
    skip "$2 already exists, keeping yours"
    return
  fi
  curl -fsSL "$DIST_BASE/$1" -o "$2" || die "could not download $1 from $DIST_BASE"
  log "wrote $2"
}

# The compose file is ours to manage, so it is always refreshed. Config files
# belong to the user and are only ever written once.
fetch docker-compose.yaml     docker-compose.yaml     yes
FRESH_CONFIG=0
[ -f config/vectorstep.yaml ] || FRESH_CONFIG=1
fetch config/vectorstep.yaml  config/vectorstep.yaml  no
[ "$WITH_GATEWAY" = 1 ] && fetch config/gateway.yaml config/gateway.yaml no

if [ -f .env ]; then
  skip ".env already exists, keeping yours"
else
  fetch .env.example .env yes
  # Seed the API key from the environment if the user exported one; otherwise
  # leave it blank and say so at the end. Prompting is not an option here —
  # under `curl | bash` stdin is the script itself, not the terminal.
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    sed -i.bak "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY|" .env && rm -f .env.bak
    log "took ANTHROPIC_API_KEY from your environment"
  fi
fi

# --- PostgreSQL ------------------------------------------------------------
# The service reads database.url from config/vectorstep.yaml, which is only
# written on a fresh install — so this can only rewire a config we just created.
# Pointing an existing SQLite install at Postgres would silently start from an
# empty schema, so refuse and say so instead.

if [ "$WITH_POSTGRES" = 1 ]; then
  # Validate before writing anything, so a refusal leaves the install exactly
  # as it was rather than half-modified.
  if [ "$FRESH_CONFIG" != 1 ] && grep -q '^  url: sqlite' config/vectorstep.yaml; then
    die "config/vectorstep.yaml already exists and still uses SQLite. Switching an existing install to PostgreSQL does not migrate your data — it would start from an empty schema. To move deliberately: back up, then either edit database.url yourself, or reinstall to a clean --dir."
  fi

  if grep -q '^POSTGRES_PASSWORD=vectorstep$' .env; then
    PGPW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PGPW|" .env && rm -f .env.bak
    log "generated a PostgreSQL password into .env"
  else
    PGPW="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2)"
    skip "keeping the PostgreSQL password already in .env"
  fi

  if grep -q '^  url: sqlite' config/vectorstep.yaml; then
    sed -i.bak "s|^  url: sqlite.*|  url: postgresql+asyncpg://vectorstep:$PGPW@postgres:5432/vectorstep|" config/vectorstep.yaml && rm -f config/vectorstep.yaml.bak
    log "config/vectorstep.yaml pointed at PostgreSQL"
  else
    skip "config/vectorstep.yaml already points somewhere other than SQLite"
  fi
fi

if [ -n "$VERSION_TAG" ]; then
  sed -i.bak "s|^VECTORSTEP_VERSION=.*|VECTORSTEP_VERSION=$VERSION_TAG|" .env && rm -f .env.bak
  log "pinned images to $VERSION_TAG"
fi

COMPOSE=(docker compose)
[ "$WITH_GATEWAY" = 1 ] && COMPOSE+=(--profile gateway)
[ "$WITH_POSTGRES" = 1 ] && COMPOSE+=(--profile postgres)

# --- Pull ------------------------------------------------------------------

TAG="$(grep -E '^VECTORSTEP_VERSION=' .env | cut -d= -f2)"; TAG="${TAG:-latest}"
PULL_ERR="$(mktemp)"; trap 'rm -f "$PULL_ERR"' EXIT

log "pulling images (tag: $TAG)"
if ! "${COMPOSE[@]}" pull </dev/null 2>"$PULL_ERR"; then
  # `latest` only exists once a vX.Y.Z release has been tagged. Until then fall
  # back to `edge`, which every push to the default branch publishes, rather
  # than failing an install for a reason the user can do nothing about. An
  # explicitly pinned tag is never silently swapped.
  if [ "$TAG" = "latest" ] && grep -qiE 'manifest unknown|not found|denied' "$PULL_ERR"; then
    warn "no :latest images are published yet — falling back to :edge (latest default-branch build)."
    sed -i.bak "s|^VECTORSTEP_VERSION=.*|VECTORSTEP_VERSION=edge|" .env && rm -f .env.bak
    "${COMPOSE[@]}" pull </dev/null || { cat "$PULL_ERR" >&2; die "image pull failed for :edge as well."; }
  else
    cat "$PULL_ERR" >&2
    die "image pull failed for tag '$TAG'. Check the tag exists, or re-run with --version edge."
  fi
fi

# --- Seed samples (first install only) ------------------------------------
# Copied out of the image with `docker cp`, which runs as the host user, so the
# files land owned by you and editable — unlike `docker compose exec cp`, which
# would write as the container's uid 1000 and can leave root-owned files on
# Linux hosts.

seed_from_image() { # seed_from_image <image> <path-in-image> <host-dir> <label>
  [ -n "$(ls -A "$3" 2>/dev/null)" ] && { skip "$3 not empty, leaving your files alone"; return; }
  local cid
  cid="$(docker create "$1" </dev/null 2>/dev/null)" || return 0
  if docker cp "$cid:$2/." "$3/" </dev/null >/dev/null 2>&1; then
    log "seeded sample $4 into $3"
  fi
  docker rm -f "$cid" </dev/null >/dev/null 2>&1 || true
}

# `|| true` on both: under `set -e`, a `VAR="$(cmd | grep ...)"` assignment
# dies the whole script the instant grep finds no match — silently, with no
# error message, since grep itself prints nothing on a clean no-match. That
# would turn "couldn't resolve an image name" into an inexplicable install
# failure instead of the graceful skip the `[ -n "$VS_IMAGE" ]` checks below
# already assume. Confirmed by reproducing it directly, not just reasoning
# about it — this is what silently killed a CI smoke-test run on 2026-09-06
# with zero output after the image pull.
VS_IMAGE="$(docker compose config --images </dev/null 2>/dev/null | grep -m1 '/vectorstep:' || true)"
GW_IMAGE="$("${COMPOSE[@]}" config --images </dev/null 2>/dev/null | grep -m1 '/vectorstep-gateway:' || true)"

[ -n "$VS_IMAGE" ] && seed_from_image "$VS_IMAGE" /app/samples/pipelines "$INSTALL_DIR/pipelines" "pipelines"
[ -n "$VS_IMAGE" ] && seed_from_image "$VS_IMAGE" /app/samples/steps     "$INSTALL_DIR/steps"     "steps"
[ -n "$VS_IMAGE" ] && seed_from_image "$VS_IMAGE" /app/samples/webhooks  "$INSTALL_DIR/webhooks"  "webhooks"
if [ "$WITH_GATEWAY" = 1 ] && [ -n "$GW_IMAGE" ]; then
  seed_from_image "$GW_IMAGE" /app/samples/agents "$INSTALL_DIR/agents" "agents"
fi

# --- Gateway token bootstrap ----------------------------------------------
# The Gateway mints its own operator token on first boot; there is no way to
# pre-supply one. Bring the Gateway up alone, read the token out, write it to
# .env, and only then start the service — so the service comes up already
# authenticated instead of logging a warning and needing a restart.

if [ "$WITH_GATEWAY" = 1 ]; then
  if grep -q '^VECTORSTEP_GATEWAY_TOKEN=.\+' .env; then
    skip "gateway token already in .env"
  else
    log "starting gateway to mint its operator token"
    "${COMPOSE[@]}" up -d gateway </dev/null

    TOKEN=""
    for _ in $(seq 1 30); do
      TOKEN="$("${COMPOSE[@]}" exec -T gateway python -c \
        "import json;print(json.load(open('/data/identity/device-auth.json'))['tokens']['operator']['token'])" \
        </dev/null 2>/dev/null | tr -d '\r\n' )" || true
      [ -n "$TOKEN" ] && break
      sleep 2
    done

    if [ -n "$TOKEN" ]; then
      sed -i.bak "s|^VECTORSTEP_GATEWAY_TOKEN=.*|VECTORSTEP_GATEWAY_TOKEN=$TOKEN|" .env && rm -f .env.bak
      log "gateway operator token written to .env"
    else
      warn "could not read the gateway's operator token after 60s. The stack will still start, but VectorStep's gateway executor will be unauthenticated. Recover with:"
      warn "  cd $INSTALL_DIR && docker compose exec gateway cat /data/identity/device-auth.json"
      warn "  then put .tokens.operator.token into VECTORSTEP_GATEWAY_TOKEN in .env and re-run this installer."
    fi
  fi
fi

# --- Start -----------------------------------------------------------------

log "starting stack"
"${COMPOSE[@]}" up -d </dev/null

# --- Done ------------------------------------------------------------------

PORT="$(grep -E '^VECTORSTEP_PORT=' .env | cut -d= -f2)"; PORT="${PORT:-8000}"

echo
log "VectorStep is running — UI at http://localhost:$PORT/ui"
echo
echo "    API docs     : http://localhost:$PORT/docs"
[ "$WITH_POSTGRES" = 1 ] && echo "    Database     : PostgreSQL (container; password in .env)"
echo "    Installed in : $INSTALL_DIR"
echo "    Pipelines    : $INSTALL_DIR/pipelines   (edit on the host; the container sees them)"
echo "    Steps        : $INSTALL_DIR/steps"
[ "$WITH_GATEWAY" = 1 ] && echo "    Agents       : $INSTALL_DIR/agents"
echo "    Manage with  : cd $INSTALL_DIR && docker compose ps|logs|down"
echo "    Upgrade with : re-run this installer"
echo

if ! grep -q '^ANTHROPIC_API_KEY=.\+' .env; then
  warn "ANTHROPIC_API_KEY is not set in $INSTALL_DIR/.env — agent steps will fail until you add it and re-run this installer."
fi

exit 0
