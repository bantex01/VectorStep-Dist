# VectorStep — install

This repository holds the published install artifacts for **VectorStep**: the
installer, the compose stack, default configuration, and third-party licence
notices. It contains no VectorStep source code — the software is distributed as
container images from `ghcr.io`.

## Install

```sh
curl -sSL https://raw.githubusercontent.com/bantex01/VectorStep-Dist/main/install.sh | bash
```

That installs the orchestration service and the Gateway agent runtime into
`~/.vectorstep` and starts them. When it finishes, the UI is at
<http://localhost:8000>.

Requires Docker with Compose v2 — nothing else. No Python, no git, no
compilation, no source checkout.

### Options

```sh
# Service only — for OpenClaw, webhook/human/notify-only pipelines, or a
# Gateway that already runs elsewhere.
curl -sSL .../install.sh | bash -s -- --service-only

# Pin a version, or track the default branch.
curl -sSL .../install.sh | bash -s -- --version v0.1.0
curl -sSL .../install.sh | bash -s -- --version edge

# Install somewhere else.
curl -sSL .../install.sh | bash -s -- --dir /opt/vectorstep
```

Set `ANTHROPIC_API_KEY` in your environment before running and the installer
will pick it up; otherwise add it to `~/.vectorstep/.env` afterwards and re-run.

## Standalone Linux install (no Docker)

For a host with no Docker, no Python, and no source — a plain VM or an
environment where containers aren't an option — `--native` installs
standalone binaries under systemd instead:

```sh
curl -sSL .../install.sh | sudo bash -s -- --native
```

Docker stays the recommended path; native is for hosts that genuinely can't
run it. It uses a fixed FHS layout (`/opt`, `/etc`, `/var/lib`,
`/var/log/vectorstep`) rather than `~/.vectorstep`, must run as root, and
`--dir`/`--postgres` don't apply. Linux only — `x86_64` (`amd64`) and
`aarch64` (`arm64`) are both supported, though **`arm64` releases are built
and published by hand, separately from the CI-built `amd64` leg, so an arm64
build may lag a fresh release by a bit** (`SPEC-native-linux-install.md`
§12.1) — if a given version has no arm64 asset yet, the installer says so and
suggests the container path instead.

```sh
# Upgrade: re-run the same command. Binaries are replaced; config, state, and
# the Gateway token are left alone.
curl -sSL .../install.sh | sudo bash -s -- --native

# Remove the units and /opt, /etc — keeps the database and authored
# pipelines/agents under /var/lib, printing where they are.
curl -sSL .../install.sh | sudo bash -s -- --native --uninstall

# Also remove /var/lib, /var/log, and the vectorstep user. Irreversible —
# --yes is required (there's no interactive prompt under curl | bash).
curl -sSL .../install.sh | sudo bash -s -- --native --uninstall --purge --yes
```

Full details: `installation/linux.md` on the docs site, and
`SPEC-native-linux-install.md`.

## Upgrading

Container install: re-run the installer. It refreshes the compose file, pulls
new images, and restarts — while leaving `.env` and everything under
`config/` exactly as you left them. Native install: see above.

## Managing the stack

```sh
cd ~/.vectorstep
docker compose ps
docker compose logs -f vectorstep
docker compose down          # stop; data volumes are kept
docker compose down -v       # stop and delete all data
```

Configuration lives in `~/.vectorstep/config/vectorstep.yaml` and
`config/gateway.yaml`. Edit, then `docker compose up -d` to apply.

## What the installer does

1. Checks Docker is installed and running.
2. Writes `docker-compose.yaml`, `config/*.yaml`, and `.env` into
   `~/.vectorstep`, never overwriting config or `.env` that already exist.
3. Pulls the images.
4. Starts the Gateway alone, reads the operator token it mints on first boot,
   and writes it into `.env` — so the service starts already authenticated
   rather than needing a manual copy-paste and restart.
5. Starts the full stack and seeds the sample pipelines on a first install.

## Licence

VectorStep is proprietary software, free to download and use — see
[`LICENSE`](LICENSE). Redistribution and derivative works are not permitted.

Bundled open source components are listed with their full licence texts in
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt).

Documentation: <https://vectorstep.io>. Questions and bug reports:
**contact@vectorstep.io**.
