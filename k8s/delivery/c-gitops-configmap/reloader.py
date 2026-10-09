#!/usr/bin/env python3
"""Config reloader sidecar for the GitOps-ConfigMap route (delivery/c-*).

Watches ConfigMap-mounted directories and calls the service's POST /reload when
their contents change — so `kubectl apply` of a ConfigMap becomes a hot reload
with no pod restart. Optionally assembles Gateway agent directories from a flat
ConfigMap first (ConfigMap keys cannot contain '/', so `sre.agent.yaml` and
`sre.soul.md` become agents/sre/agent.yaml and agents/sre/soul.md). Skills are
nested directories, so they arrive as one tarball per skill
(`incident-triage.tar.gz`) and are unpacked the same way, with the nesting and
the execute bit on their scripts preserved.

Runs inside the VectorStep image (python is already there) so there is no extra
image to pull or vet. Configuration, all via environment variables:

  MODE              loop (default) | once     once = assemble and exit (init container)
  WATCH_DIRS        comma-separated directories to watch for changes
  RELOAD_URL        e.g. http://localhost:8000/reload
  ADMIN_TOKEN       admin-role bearer token for that service
  INTERVAL          seconds between checks (default 10)
  AGENTS_SRC        flat ConfigMap mount to assemble agents from (optional)
  AGENTS_DST        directory to assemble them into, e.g. /data/agents
  SKILLS_SRC        ConfigMap mount holding <skill>.tar.gz keys (optional)
  SKILLS_DST        directory to unpack them into, e.g. /data/skills
"""
import hashlib
import os
import re
import shutil
import sys
import tarfile
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


# Same rule as the Gateway's NAME_PATTERN for agent and skill names.
_SKILL_NAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$")
_MAX_SKILL_BYTES = 64 * 1024 * 1024   # unpacked size cap per skill (the ConfigMap itself caps the packed size at 1 MiB)
_MAX_SKILL_FILES = 2000


def _safe_members(tf, name):
    """Yield (member, relative_path) for each entry worth extracting; raise
    ValueError on anything that could write outside the skill's directory or
    isn't a plain file/directory. The tarball comes from git, but this is the
    one place file contents become filesystem paths, so it is checked anyway."""
    total, count = 0, 0
    for m in tf.getmembers():
        rel = os.path.normpath(m.name)
        if rel in (".", ""):
            continue
        if os.path.isabs(m.name) or rel == ".." or rel.startswith("../") or "\\" in m.name:
            raise ValueError(f"unsafe path {m.name!r}")
        if not (m.isfile() or m.isdir()):
            raise ValueError(f"{m.name!r} is a {'symlink' if m.issym() else 'link' if m.islnk() else 'special file'}, not a plain file")
        count += 1
        total += m.size
        if count > _MAX_SKILL_FILES or total > _MAX_SKILL_BYTES:
            raise ValueError("skill is too large to unpack")
        yield m, rel


def unpack_skill(tarball, dst_dir, name):
    """Unpack one skill tarball into dst_dir/<name>, replacing any previous
    version. Directories are 0755, files 0644, and 0755 if the owner-execute bit
    was set (so skill scripts stay runnable). Raises ValueError, leaving the
    existing skill untouched, if the tarball is unsafe or has no SKILL.md."""
    final = os.path.join(dst_dir, name)
    work = os.path.join(dst_dir, "." + name + ".tmp")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    try:
        with tarfile.open(tarball, "r:gz") as tf:
            for m, rel in _safe_members(tf, name):
                target = os.path.join(work, rel)
                if m.isdir():
                    os.makedirs(target, exist_ok=True)
                    os.chmod(target, 0o755)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with tf.extractfile(m) as src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out)
                os.chmod(target, 0o755 if m.mode & 0o100 else 0o644)
        if not os.path.isfile(os.path.join(work, "SKILL.md")):
            raise ValueError("no SKILL.md at the top level of the tarball")
        old = final + ".old"
        shutil.rmtree(old, ignore_errors=True)
        if os.path.exists(final):
            os.rename(final, old)
        os.rename(work, final)
        shutil.rmtree(old, ignore_errors=True)
    except (tarfile.TarError, OSError, EOFError) as e:
        raise ValueError(f"cannot read tarball: {e}") from e
    finally:
        shutil.rmtree(work, ignore_errors=True)


def assemble_skills(src, dst):
    """Make dst mirror the skills declared in the ConfigMap src. Returns
    (names, errors). A skill that fails to unpack is reported in errors and keeps
    its previous version; skills no longer in git are removed."""
    want = {}
    for key in sorted(os.listdir(src)):
        if key.startswith(".") or not key.endswith(".tar.gz"):
            continue
        want[key[: -len(".tar.gz")]] = os.path.join(src, key)
    os.makedirs(dst, exist_ok=True)
    ok, errors = [], []
    for name, path in want.items():
        if not _SKILL_NAME.match(name):
            errors.append(f"{name}: not a valid skill name")
            continue
        try:
            unpack_skill(path, dst, name)
            ok.append(name)
        except ValueError as e:
            errors.append(f"{name}: {e}")
    for existing in os.listdir(dst):
        if existing.startswith(".") or existing in want:
            continue
        shutil.rmtree(os.path.join(dst, existing), ignore_errors=True)
    return ok, errors


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
    sk_src, sk_dst = os.environ.get("SKILLS_SRC"), os.environ.get("SKILLS_DST")
    interval = float(os.environ.get("INTERVAL", "10"))
    url, token = os.environ.get("RELOAD_URL", ""), os.environ.get("ADMIN_TOKEN", "")

    if src and dst:
        log(f"assembled agents {assemble_agents(src, dst)} into {dst}")
        dirs = dirs or [src]
    if sk_src and sk_dst:
        names, errs = assemble_skills(sk_src, sk_dst)
        log(f"assembled skills {names} into {sk_dst}" + (f"; SKILLS REJECTED: {'; '.join(errs)}" if errs else ""))
        if sk_src not in dirs:
            dirs = dirs + [sk_src]
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
            skill_errs = []
            if sk_src and sk_dst:
                _, skill_errs = assemble_skills(sk_src, sk_dst)
            ok, detail = reload(url, token)
            if skill_errs:   # the rest still reloaded; the CI job must still fail
                detail += f" | SKILLS REJECTED (previous version kept): {'; '.join(skill_errs)}"
            log(f"change detected ({last[:12]} -> {cur[:12]}); reload {'ok' if ok and not skill_errs else 'REJECTED'}: {detail}")
            last = cur  # a rejected reload is retried only when the files change again
        except Exception as e:  # never let a transient error kill the sidecar
            log(f"error: {e}")


if __name__ == "__main__":
    sys.exit(main())
