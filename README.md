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

## Upgrading

Re-run the installer. It refreshes the compose file, pulls new images, and
restarts — while leaving `.env` and everything under `config/` exactly as you
left them.

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
**alex@vectorstep.io**.
