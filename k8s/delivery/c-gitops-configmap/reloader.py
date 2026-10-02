#!/usr/bin/env python3
"""Config reloader sidecar for the GitOps-ConfigMap route (delivery/c-*).

Watches ConfigMap-mounted directories and calls the service's POST /reload when
their contents change — so `kubectl apply` of a ConfigMap becomes a hot reload
with no pod restart. Optionally assembles Gateway agent directories from a flat
ConfigMap first (ConfigMap keys cannot contain '/', so `sre.agent.yaml` and
`sre.soul.md` become agents/sre/agent.yaml and agents/sre/soul.md).

Runs inside the VectorStep image (python is already there) so there is no extra
image to pull or vet. Configuration, all via environment variables:

  MODE              loop (default) | once     once = assemble and exit (init container)
  WATCH_DIRS        comma-separated directories to watch for changes
  RELOAD_URL        e.g. http://localhost:8000/reload
  ADMIN_TOKEN       admin-role bearer token for that service
  INTERVAL          seconds between checks (default 10)
  AGENTS_SRC        flat ConfigMap mount to assemble agents from (optional)
  AGENTS_DST        directory to assemble them into, e.g. /data/agents
"""
import hashlib
import os
import shutil
import sys
import time
import urllib.error
import urllib.request


def log(msg):
    print(f"config-reloader: {msg}", flush=True)


def digest(dirs):
    """Hash of every file's relative path and content under dirs. Skips the
    '..data' / '..<timestamp>' bookkeeping entries Kubernetes uses to swap a
    ConfigMap atomically, and follows the symlinks it uses for the real files."""
    h = hashlib.sha256()
    for d in dirs:
        for root, subdirs, files in os.walk(d, followlinks=True):
            subdirs[:] = sorted(s for s in subdirs if not s.startswith(".."))
            for f in sorted(files):
                if f.startswith(".."):
                    continue
                p = os.path.join(root, f)
                h.update(os.path.relpath(p, d).encode())
                with open(p, "rb") as fh:
                    h.update(fh.read())
    return h.hexdigest()


_SUFFIXES = ((".agent.yaml", "agent.yaml"), (".soul.md", "soul.md"))


def assemble_agents(src, dst):
    """Make dst exactly mirror the agents declared in the flat ConfigMap src."""
    want = {}
    for key in sorted(os.listdir(src)):
        if key.startswith("."):
            continue
        for suffix, target in _SUFFIXES:
            if key.endswith(suffix):
                want.setdefault(key[: -len(suffix)], {})[target] = os.path.join(src, key)
    os.makedirs(dst, exist_ok=True)
    for name, files in want.items():
        agent_dir = os.path.join(dst, name)
        os.makedirs(agent_dir, exist_ok=True)
        for target, path in files.items():
            tmp = os.path.join(agent_dir, "." + target + ".tmp")
            shutil.copyfile(path, tmp)
            os.replace(tmp, os.path.join(agent_dir, target))
    for existing in os.listdir(dst):
        if existing not in want:
            shutil.rmtree(os.path.join(dst, existing), ignore_errors=True)
    return sorted(want)


def reload(url, token):
    req = urllib.request.Request(url, method="POST", headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return True, r.read().decode()[:300]
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read().decode()[:600]}"
    except Exception as e:  # service not up yet, connection refused, etc.
        return False, str(e)


def main():
    mode = os.environ.get("MODE", "loop")
    dirs = [d for d in os.environ.get("WATCH_DIRS", "").split(",") if d]
    src, dst = os.environ.get("AGENTS_SRC"), os.environ.get("AGENTS_DST")
    interval = float(os.environ.get("INTERVAL", "10"))
    url, token = os.environ.get("RELOAD_URL", ""), os.environ.get("ADMIN_TOKEN", "")

    if src and dst:
        log(f"assembled agents {assemble_agents(src, dst)} into {dst}")
        dirs = dirs or [src]
    if mode == "once":
        return 0
    if not (dirs and url and token):
        log("WATCH_DIRS, RELOAD_URL and ADMIN_TOKEN are required in loop mode")
        return 2

    last = digest(dirs)
    log(f"watching {dirs} every {interval:g}s (baseline {last[:12]})")
    while True:
        time.sleep(interval)
        try:
            cur = digest(dirs)
            if cur == last:
                continue
            time.sleep(2)  # let a multi-file ConfigMap update finish landing
            cur = digest(dirs)
            if src and dst:
                assemble_agents(src, dst)
            ok, detail = reload(url, token)
            log(f"change detected ({last[:12]} -> {cur[:12]}); reload {'ok' if ok else 'REJECTED'}: {detail}")
            last = cur  # a rejected reload is retried only when the files change again
        except Exception as e:  # never let a transient error kill the sidecar
            log(f"error: {e}")


if __name__ == "__main__":
    sys.exit(main())
