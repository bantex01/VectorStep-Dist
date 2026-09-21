# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Use GitHub's private vulnerability reporting instead: go to the **Security** tab
of this repository and choose **Report a vulnerability**. That opens a private
channel visible only to the maintainers.

Please include:

- A description of the issue and why you believe it is a security problem
- Steps to reproduce, or a proof of concept
- The version or commit you were running
- Any deployment details that seem relevant

## What to expect

VectorStep is proprietary software, maintained by a small team. There is no
SLA and no bug bounty.

That said: reports are acknowledged as promptly as is realistically possible,
triaged with a stated fix intent, and you will be told whether the issue is
accepted and what the fix timeline looks like. You will be credited in the
release notes when a fix ships — unless you would prefer not to be.

Please allow a reasonable period for a fix before disclosing publicly.

## Scope

This repository holds only the install artifacts — `install.sh`, the compose
stack, default config, and third-party licence notices. It contains no
VectorStep source code; the software itself ships as container images from
`ghcr.io` and standalone Linux tarballs published to this repo's Releases.
Reports in scope here include:

- A problem in `install.sh` itself: unsafe handling of downloaded content,
  an injection risk in how it parses arguments or config, or a place it
  should verify a download and doesn't. The native-install path already
  checksum-verifies (`sha256sum -c`) every tarball it downloads before use —
  a report that this check is missing or bypassable for some path is very
  much in scope; a report that `curl | bash` is inherently risky is a known,
  general tradeoff of that install pattern and not actionable here on its
  own.
- A problem in the shipped `docker-compose.yaml` or `k8s/` manifests: an
  insecure default, a missing isolation boundary, secrets handled unsafely.
- A signature or checksum published against a release asset in this repo
  (or in `VectorStep`'s / `VectorStep-Gateway`'s own releases) that doesn't
  actually verify — see [Verifying a
  release](https://vectorstep.io/docs/about/status-and-support/#verifying-a-release).

Reports about the VectorStep **product itself** — its API, its execution
model, authentication, TLS, or anything else that isn't specific to how this
repo installs or packages it — should go to the `VectorStep` or
`VectorStep-Gateway` repo's own private vulnerability reporting channel
instead, since those repos' maintainers are the ones who can act on them.

## Supported versions

Only the latest released version receives security fixes. There are no
long-term support branches. Pin production deployments to a released tag —
not `:latest` or `:edge` — so you control exactly when a fix lands rather
than inheriting whatever the default branch happens to contain that day.
