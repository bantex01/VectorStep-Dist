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
#
# For a Docker-free install (no Python, no source, standalone Linux binaries
# under systemd), see --native below — SPEC-native-linux-install.md.

set -euo pipefail

INSTALL_DIR="${VECTORSTEP_HOME:-$HOME/.vectorstep}"
DIST_BASE="${VECTORSTEP_DIST_BASE:-https://raw.githubusercontent.com/bantex01/VectorStep-Dist/main}"
DIST_REPO="bantex01/VectorStep-Dist"
WITH_GATEWAY=1
WITH_POSTGRES=0
VERSION_TAG=""
NATIVE=0
NATIVE_UNINSTALL=0
NATIVE_PURGE=0
NATIVE_YES=0

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
    --native)       NATIVE=1; shift ;;
    --uninstall)    NATIVE_UNINSTALL=1; shift ;;
    --purge)        NATIVE_PURGE=1; shift ;;
    --yes)          NATIVE_YES=1; shift ;;
    -h|--help)
      cat <<'USAGE'
VectorStep installer.

  --service-only   Skip the Gateway. Use this if you drive VectorStep with
                   OpenClaw, with webhook/human/notify-only pipelines, or if
                   the Gateway already runs elsewhere.
  --postgres       Run PostgreSQL instead of SQLite, in its own container,
                   with a generated password. Choose this at FIRST install —
                   switching later does not migrate existing data. Container
                   install only, not valid with --native.
  --dir PATH       Install somewhere other than ~/.vectorstep. Container
                   install only, not valid with --native (native follows a
                   fixed FHS layout under /opt, /etc, /var — see
                   SPEC-native-linux-install.md §7).
  --version TAG    Image tag (container) or release tag (--native) to
                   install (default: latest release/image).
  --native         Install standalone Linux binaries under systemd instead of
                   Docker containers. No Python, no source, no Docker needed
                   on the host. Linux only; must be run as root.
  --uninstall      With --native: stop and remove the systemd units and
                   /opt, /etc. Config/state under /var/lib and /var/log are
                   kept and their path is printed — add --purge to remove
                   those too.
  --purge          With --native --uninstall: also remove /var/lib, /var/log,
                   and the vectorstep system user. Destructive and
                   irreversible — requires --yes under `curl | bash` (no
                   usable stdin for a prompt there).
  --yes            Skip the --purge confirmation prompt.

Docs: https://vectorstep.io/docs/getting-started/quick-start/
USAGE
      exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

if [ "$NATIVE_UNINSTALL" = 1 ] || [ "$NATIVE_PURGE" = 1 ]; then
  NATIVE=1
fi

# --- Native (standalone Linux binaries, systemd) ---------------------------
# Entirely separate from the container path below: no Docker, no ~/.vectorstep,
# a fixed FHS layout instead. See SPEC-native-linux-install.md.

if [ "$NATIVE" = 1 ]; then
  [ "$WITH_POSTGRES" = 0 ] || die "--postgres is not valid with --native (no bundled Postgres container in this mode)."
  [ "$INSTALL_DIR" = "${VECTORSTEP_HOME:-$HOME/.vectorstep}" ] || die "--dir is not valid with --native (fixed FHS layout — see SPEC-native-linux-install.md §7)."

  NATIVE_USER=vectorstep
  OPT=/opt/vectorstep
  ETC=/etc/vectorstep
  VARLIB=/var/lib/vectorstep
  VARLOG=/var/log/vectorstep

  [ "$(uname -s)" = "Linux" ] || die "--native is Linux-only (no systemd equivalent on macOS). Use the default container install with Docker Desktop instead."
  case "$(uname -m)" in
    x86_64)          NATIVE_ARCH=amd64 ;;
    aarch64|arm64)   NATIVE_ARCH=arm64 ;;
    *)               die "unsupported architecture: $(uname -m)." ;;
  esac
  [ "$(id -u)" = "0" ] || die "--native must be run as root, e.g.: curl -sSL ... | sudo bash -s -- --native"
  for c in curl tar systemctl; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found on PATH — required for --native."
  done
  log "native preflight ok (linux/$NATIVE_ARCH)"

  # --- Uninstall -------------------------------------------------------
  if [ "$NATIVE_UNINSTALL" = 1 ]; then
    log "stopping and removing units"
    systemctl disable --now vectorstep vectorstep-gateway </dev/null >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/vectorstep.service /etc/systemd/system/vectorstep-gateway.service
    systemctl daemon-reload </dev/null

    log "removing $OPT and $ETC"
    rm -rf "$OPT" "$ETC"

    if [ "$NATIVE_PURGE" = 1 ]; then
      if [ "$NATIVE_YES" != 1 ]; then
        die "--purge permanently deletes $VARLIB and $VARLOG (database, artifacts, authored pipelines/agents) and removes the $NATIVE_USER user. Re-run with --yes to confirm — there is no interactive prompt under curl | bash."
      fi
      log "purging $VARLIB and $VARLOG"
      rm -rf "$VARLIB" "$VARLOG"
      userdel "$NATIVE_USER" </dev/null >/dev/null 2>&1 || true
      groupdel "$NATIVE_USER" </dev/null >/dev/null 2>&1 || true
      log "purge complete — nothing of VectorStep's remains on this host"
    else
      log "kept: $VARLIB and $VARLOG (database, artifacts, authored pipelines/agents) — re-run with --uninstall --purge --yes to remove those too"
    fi
    exit 0
  fi

  # --- Resolve release ---------------------------------------------------
  if [ -n "$VERSION_TAG" ]; then
    NATIVE_REL_TAG="$VERSION_TAG"
    case "$NATIVE_REL_TAG" in v*) ;; *) NATIVE_REL_TAG="v$NATIVE_REL_TAG" ;; esac
  else
    # `|| true`: a 404 (no releases published yet) makes curl -f exit nonzero,
    # which under pipefail would otherwise abort the script here via set -e
    # instead of reaching the friendlier die() message on the next line.
    NATIVE_REL_TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$DIST_REPO/releases/latest" </dev/null | sed -n 's#.*/tag/##p')" || NATIVE_REL_TAG=""
    [ -n "$NATIVE_REL_TAG" ] || die "could not resolve the latest release from $DIST_REPO — none published yet? Pass --version explicitly."
  fi
  log "resolved release: $NATIVE_REL_TAG"

  # Override for testing against locally-built tarballs (e.g. a
  # native-smoke-test CI job, or manual verification) instead of a real
  # published release — same idea as the container path's VECTORSTEP_DIST_BASE.
  NATIVE_REL_BASE="${VECTORSTEP_NATIVE_ASSET_BASE:-https://github.com/$DIST_REPO/releases/download/$NATIVE_REL_TAG}"
  VS_TARBALL="vectorstep-${NATIVE_REL_TAG#v}-linux-${NATIVE_ARCH}.tar.gz"
  GW_TARBALL="vectorstep-gateway-${NATIVE_REL_TAG#v}-linux-${NATIVE_ARCH}.tar.gz"

  NATIVE_TMP="$(mktemp -d)"
  trap 'rm -rf "$NATIVE_TMP"' EXIT

  native_fetch() { # native_fetch <asset-filename>
    local asset="$1"
    curl -fsSL "$NATIVE_REL_BASE/$asset" -o "$NATIVE_TMP/$asset" </dev/null \
      || die "could not download $asset from release $NATIVE_REL_TAG. If this is an arm64 host, that release's arm64 build may not be published yet (it ships by hand, separately from amd64) — try a different --version, or use the default container install."
  }
  native_verify() { # native_verify <asset-filename>
    ( cd "$NATIVE_TMP" && { command -v sha256sum >/dev/null 2>&1 && sha256sum -c "$1.sha256" || shasum -a 256 -c "$1.sha256"; } ) </dev/null \
      || die "checksum verification failed for $1 — refusing to install a corrupted or tampered download."
  }

  log "downloading $VS_TARBALL"
  native_fetch "$VS_TARBALL"; native_fetch "$VS_TARBALL.sha256"; native_verify "$VS_TARBALL"
  if [ "$WITH_GATEWAY" = 1 ]; then
    log "downloading $GW_TARBALL"
    native_fetch "$GW_TARBALL"; native_fetch "$GW_TARBALL.sha256"; native_verify "$GW_TARBALL"
  fi

  # --- System user and FHS layout ----------------------------------------
  id -u "$NATIVE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$NATIVE_USER"

  mkdir -p "$OPT" "$ETC/vectorstep" \
    "$VARLIB/vectorstep"/{db,artifacts,pipelines,steps,webhooks} \
    "$VARLOG/vectorstep"
  [ "$WITH_GATEWAY" = 1 ] && mkdir -p "$ETC/vectorstep-gateway" "$VARLIB/vectorstep-gateway"/{identity,agents} "$VARLOG/vectorstep-gateway"
  chown -R "$NATIVE_USER:$NATIVE_USER" "$VARLIB" "$VARLOG"
  chown -R "root:$NATIVE_USER" "$ETC"

  # native_install_service <tarball> <install-root> <unit-name>
  # Returns (echoes) the extracted top-level dir — the caller still needs it
  # afterward (config.yaml.example, samples/), so it's nested under NATIVE_TMP
  # and left for that single EXIT trap to clean up, not removed here.
  native_install_service() {
    local tarball="$1" root="$2" unit="$3"
    local stage; stage="$(mktemp -d "$NATIVE_TMP/stage.XXXXXX")"
    tar -xzf "$NATIVE_TMP/$tarball" -C "$stage"
    local top; top="$(find "$stage" -mindepth 1 -maxdepth 1 -type d)"

    mkdir -p "${root:?}/bin"
    rm -rf "${root:?}/bin.new" && cp -a "$top/bin" "$root/bin.new"
    rm -rf "${root:?}/bin" && mv "$root/bin.new" "$root/bin"
    # VectorStep only: migrations/ and alembic.ini as siblings of bin/, not
    # inside it — deliberately outside the PyInstaller bundle (see
    # src/paths.py's install_root_resource_path() in the VectorStep repo).
    # Gateway's tarball has neither, hence the guard.
    if [ -d "$top/migrations" ]; then
      rm -rf "${root:?}/migrations" && cp -a "$top/migrations" "$root/migrations"
      cp "$top/alembic.ini" "$root/alembic.ini"
    fi
    chown -R "$NATIVE_USER:$NATIVE_USER" "$root"

    cp "$top/systemd/$unit" "/etc/systemd/system/$unit"

    # VECTORSTEP_VERSION into the env file, without disturbing any secrets a
    # prior install (or the operator) already put there.
    local env_file
    env_file="$ETC/$(basename "$root")/env"
    local ver
    ver="$(cat "$top/VERSION")"
    touch "$env_file"
    if grep -q '^VECTORSTEP_VERSION=' "$env_file"; then
      sed -i.bak "s|^VECTORSTEP_VERSION=.*|VECTORSTEP_VERSION=$ver|" "$env_file" && rm -f "$env_file.bak"
    else
      printf 'VECTORSTEP_VERSION=%s\n' "$ver" >> "$env_file"
    fi
    chown "root:$NATIVE_USER" "$env_file"; chmod 640 "$env_file"

    echo "$top"
  }

  # Stop before replacing binaries, not after — an already-running process
  # keeps using its old (now-unlinked) binary via its open file descriptor
  # either way, but restarting explicitly, in this order, is what §12.2
  # actually specifies and what "upgrade" is supposed to mean rather than
  # "new binaries on disk that nothing is running yet." Harmless no-ops on a
  # first install, where neither unit exists yet.
  systemctl stop vectorstep vectorstep-gateway </dev/null >/dev/null 2>&1 || true

  log "installing vectorstep"
  VS_STAGE="$(native_install_service "$VS_TARBALL" "$OPT/vectorstep" vectorstep.service)"
  FRESH_CONFIG=0
  if [ ! -f "$ETC/vectorstep/config.yaml" ]; then
    FRESH_CONFIG=1
    cp "$VS_STAGE/config.yaml.example" "$ETC/vectorstep/config.yaml"
    # The template's relative defaults (./pipelines, ./runs.db, ./logs,
    # ./artifacts) resolve against WorkingDirectory=/opt/vectorstep/vectorstep,
    # which ProtectSystem=strict makes read-only — confirmed by testing this
    # for real, it crashes on first write otherwise. Point them at the FHS
    # dirs that actually are writable (same substitution install.md has
    # always told a by-hand installer to make).
    sed -i \
      -e "s|^pipeline_config_dir: \./pipelines|pipeline_config_dir: $VARLIB/vectorstep/pipelines|" \
      -e "s|^step_library_dir: \./steps|step_library_dir: $VARLIB/vectorstep/steps|" \
      -e "s|:///\./runs\.db|:///$VARLIB/vectorstep/db/runs.db|" \
      -e "s|^  dir: \./logs|  dir: $VARLOG/vectorstep|" \
      -e "s|^  dir: \./artifacts|  dir: $VARLIB/vectorstep/artifacts|" \
      "$ETC/vectorstep/config.yaml"
    chown "root:$NATIVE_USER" "$ETC/vectorstep/config.yaml"
    log "wrote $ETC/vectorstep/config.yaml"
  else
    skip "$ETC/vectorstep/config.yaml already exists, keeping yours"
  fi
  # Seed samples on first install only — parity with the container path's
  # seed_from_image, which always populates these on a fresh install.
  if [ "$FRESH_CONFIG" = 1 ]; then
    for d in pipelines steps webhooks; do
      if [ -d "$VS_STAGE/samples/$d" ] && [ -z "$(ls -A "$VARLIB/vectorstep/$d" 2>/dev/null)" ]; then
        cp -a "$VS_STAGE/samples/$d/." "$VARLIB/vectorstep/$d/" 2>/dev/null || true
        chown -R "$NATIVE_USER:$NATIVE_USER" "$VARLIB/vectorstep/$d"
      fi
    done
    # Seed the API key from the environment if the caller exported one —
    # parity with the container path. Only on a fresh install; never touch an
    # env file that's already there.
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      touch "$ETC/vectorstep/env"
      printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" >> "$ETC/vectorstep/env"
      chown "root:$NATIVE_USER" "$ETC/vectorstep/env"; chmod 640 "$ETC/vectorstep/env"
      log "took ANTHROPIC_API_KEY from your environment"
    fi
  fi

  if [ "$WITH_GATEWAY" = 1 ]; then
    log "installing vectorstep-gateway"
    GW_STAGE="$(native_install_service "$GW_TARBALL" "$OPT/vectorstep-gateway" vectorstep-gateway.service)"
    if [ ! -f "$ETC/vectorstep-gateway/config.yaml" ]; then
      cp "$GW_STAGE/config.yaml.example" "$ETC/vectorstep-gateway/config.yaml"
      # Same reasoning as VectorStep's config above — ProtectHome=true breaks
      # the default identity.path, and ProtectSystem=strict breaks the
      # default relative agents_dir/logging.dir the same way; confirmed by
      # testing this for real.
      sed -i \
        -e "s|^agents_dir: \./agents|agents_dir: $VARLIB/vectorstep-gateway/agents|" \
        -e "s|^  path: ~/\.vectorstep-gateway/identity|  path: $VARLIB/vectorstep-gateway/identity|" \
        -e "s|^  dir: \./logs|  dir: $VARLOG/vectorstep-gateway|" \
        "$ETC/vectorstep-gateway/config.yaml"
      chown "root:$NATIVE_USER" "$ETC/vectorstep-gateway/config.yaml"
      log "wrote $ETC/vectorstep-gateway/config.yaml"
    else
      skip "$ETC/vectorstep-gateway/config.yaml already exists, keeping yours"
    fi
    if [ -d "$GW_STAGE/samples/agents" ] && [ -z "$(ls -A "$VARLIB/vectorstep-gateway/agents" 2>/dev/null)" ]; then
      cp -a "$GW_STAGE/samples/agents/." "$VARLIB/vectorstep-gateway/agents/" 2>/dev/null || true
      chown -R "$NATIVE_USER:$NATIVE_USER" "$VARLIB/vectorstep-gateway/agents"
    fi
  fi

  systemctl daemon-reload </dev/null

  # --- Start the gateway (always — this is also the post-upgrade restart,
  # not just first boot), bootstrap its token if not already known, then
  # start the service. No Python assumed on the host, so the token is pulled
  # out of device-auth.json with grep/sed instead of the container path's
  # `python -c`.
  if [ "$WITH_GATEWAY" = 1 ]; then
    log "starting gateway"
    systemctl enable --now vectorstep-gateway </dev/null

    if grep -q '^VECTORSTEP_GATEWAY_TOKEN=.\+' "$ETC/vectorstep/env" 2>/dev/null; then
      skip "gateway token already in $ETC/vectorstep/env"
    else
      log "minting the gateway's operator token"
      TOKEN=""
      DEVICE_AUTH="$VARLIB/vectorstep-gateway/identity/device-auth.json"
      for _ in $(seq 1 30); do
        if [ -f "$DEVICE_AUTH" ]; then
          # device-auth.json is pretty-printed (one key per line), so "token"
          # and its value are never on the same line as "operator" — matching
          # both on one line (as an earlier version of this did) never matches
          # at all. "token": is unique to the operator entry (the sibling key
          # is "tokens", which this pattern doesn't match). `|| true` matters:
          # under pipefail, a plain no-match grep here — the normal case on
          # every iteration but the last — would otherwise abort the whole
          # script via set -e, not just this loop.
          TOKEN="$(grep '"token":' "$DEVICE_AUTH" 2>/dev/null | head -1 \
            | sed -E 's/.*"token":[[:space:]]*"([^"]*)".*/\1/')" || TOKEN=""
        fi
        [ -n "$TOKEN" ] && break
        sleep 2
      done

      touch "$ETC/vectorstep/env"
      if [ -n "$TOKEN" ]; then
        if grep -q '^VECTORSTEP_GATEWAY_TOKEN=' "$ETC/vectorstep/env"; then
          sed -i.bak "s|^VECTORSTEP_GATEWAY_TOKEN=.*|VECTORSTEP_GATEWAY_TOKEN=$TOKEN|" "$ETC/vectorstep/env" && rm -f "$ETC/vectorstep/env.bak"
        else
          printf 'VECTORSTEP_GATEWAY_TOKEN=%s\n' "$TOKEN" >> "$ETC/vectorstep/env"
        fi
        chown "root:$NATIVE_USER" "$ETC/vectorstep/env"; chmod 640 "$ETC/vectorstep/env"
        log "gateway operator token written to $ETC/vectorstep/env"
      else
        warn "could not read the gateway's operator token after 60s. VectorStep will still start, but its gateway executor will be unauthenticated. Recover with:"
        warn "  cat $DEVICE_AUTH   (look for .tokens.operator.token)"
        warn "  then put it in VECTORSTEP_GATEWAY_TOKEN= in $ETC/vectorstep/env and: systemctl restart vectorstep"
      fi
    fi
  fi

  log "starting vectorstep"
  systemctl enable --now vectorstep </dev/null

  echo
  log "VectorStep is running — UI at http://$(hostname -f 2>/dev/null || hostname):8000/ui"
  echo
  echo "    Config       : $ETC/vectorstep/config.yaml"
  [ "$WITH_GATEWAY" = 1 ] && echo "    Gateway config: $ETC/vectorstep-gateway/config.yaml"
  echo "    Pipelines    : $VARLIB/vectorstep/pipelines"
  echo "    Steps        : $VARLIB/vectorstep/steps"
  [ "$WITH_GATEWAY" = 1 ] && echo "    Agents       : $VARLIB/vectorstep-gateway/agents"
  echo "    Manage with  : systemctl status|restart|stop vectorstep vectorstep-gateway"
  echo "    Logs         : journalctl -u vectorstep -f"
  echo "    Upgrade with : re-run this installer with --native"
  echo "    Uninstall    : re-run with --native --uninstall (add --purge --yes to also remove state)"
  echo

  if ! grep -q '^ANTHROPIC_API_KEY=.\+' "$ETC/vectorstep/env" 2>/dev/null; then
    warn "ANTHROPIC_API_KEY is not set in $ETC/vectorstep/env — agent steps will fail until you add it and: systemctl restart vectorstep"
  fi

  exit 0
fi

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
