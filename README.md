# VectorStep — install

This repository holds the published install artifacts for **VectorStep**: the
installer, the compose stack, default configuration, and third-party licence
notices. It contains no VectorStep source code — the software is distributed as
container images from `ghcr.io`.

> **Beta.** VectorStep is in beta. Please
> [let us know](https://vectorstep.io/docs/about/status-and-support/) if
> something breaks.

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
# pipelines/agents/skills under /var/lib, printing where they are.
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

### Reaching the Gateway from the host

The Gateway publishes no host port by default — `vectorstep` reaches it on
the compose network at `ws://gateway:18780`, and that's all the default
stack needs. If you're pointing a Gateway MCP client (or anything else
running on the host, not in a container) at `localhost:18780`, add a
persistent mapping to `docker-compose.yaml`'s `gateway` service:

```yaml
  gateway:
    ports: ["127.0.0.1:18780:18780"]
```

then `docker compose up -d` to apply it. (`docker compose port` only prints
a binding that already exists — with no `ports:` entry there's nothing for
it to report, so it isn't the one-off shortcut it might look like.)

Keep it off a non-loopback interface unless it's behind TLS and
a firewall — the Gateway's admin token can rewrite agent definitions.

## What the installer does

1. Checks Docker is installed and running.
2. Writes `docker-compose.yaml`, `config/*.yaml`, and `.env` into
   `~/.vectorstep`, never overwriting config or `.env` that already exist.
3. Pulls the images.
4. Starts the Gateway alone, reads the invoke token it mints on first boot,
   and writes it into `.env` — so the service starts already authenticated
   rather than needing a manual copy-paste and restart. The Gateway also
   mints a separate admin token, printed at the end for whoever authors
   agents and skills (a Gateway MCP client) — not written to any file here.
5. Starts the full stack and seeds the sample pipelines, agents, and skills
   on a first install.

## Telemetry

VectorStep and the Gateway each send a single anonymous ping when they
start: a randomly generated installation ID, the version, and the host's
OS/architecture/install method (container, Kubernetes, or `--native`).
Nothing else — no hostnames, no IPs beyond what any request inherently
exposes to the receiving server, no config, no pipeline or agent
definitions, no data processed by either service.

Disable it before installing, or any time after (takes effect on the next
restart):

```bash
export DO_NOT_TRACK=1
# or: export VECTORSTEP_TELEMETRY=false
# or, in config.yaml:
#   telemetry:
#     enabled: false
```

See clause 10 of [`LICENSE`](LICENSE) for the full terms.

## Licence

VectorStep is proprietary software, free to download and use — see
[`LICENSE`](LICENSE). Redistribution and derivative works are not permitted.

Bundled open source components are listed with their full licence texts in
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt).

Documentation: <https://vectorstep.io>. Questions and bug reports:
**contact@vectorstep.io**.
