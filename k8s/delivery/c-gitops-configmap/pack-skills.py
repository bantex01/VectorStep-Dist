#!/usr/bin/env python3
"""Pack Gateway skills into deterministic tarballs for the route C ConfigMap.

  pack-skills.py <skills-dir> <out-dir>

Writes <out-dir>/<skill>.tar.gz for every <skills-dir>/<skill>/ that contains a
SKILL.md. Skills are directories and ConfigMap keys cannot contain '/', so each
skill travels as one tarball that the config-reloader sidecar unpacks (nesting
and the execute bit on scripts are kept). The output is byte-for-byte
reproducible - sorted entries, fixed timestamps and ownership, no gzip header
time - so an unchanged skill produces an unchanged ConfigMap.

apply.sh calls this. With Argo CD / Flux, run it in CI and render the ConfigMap:

  python3 pack-skills.py config/skills build/skills
  kubectl create configmap vectorstep-skills --from-file=build/skills \\
      --dry-run=client -o yaml > gitops/vectorstep-skills.yaml

Exits non-zero on a symlink, or if the skills would not fit in one ConfigMap
(1 MiB; binary data is base64-encoded, so about 750 KB of tarballs).
"""
import gzip, io, os, sys, tarfile
if len(sys.argv) != 3:
    sys.exit(__doc__)
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
SKIP = {".git", ".DS_Store", "__pycache__"}
total, sizes, bad = 0, [], False
for name in sorted(os.listdir(src)):
    d = os.path.join(src, name)
    if name.startswith(".") or not os.path.isdir(d):
        continue
    if not os.path.isfile(os.path.join(d, "SKILL.md")):
        print(f"skills/{name}: no SKILL.md - skipped", file=sys.stderr); continue
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, compresslevel=9) as gz, \
         tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for root, dirs, files in os.walk(d):
            dirs[:] = sorted(x for x in dirs if x not in SKIP and not x.startswith("._"))
            for f in sorted(files):
                if f in SKIP or f.startswith("._"):
                    continue
                p = os.path.join(root, f)
                if os.path.islink(p):
                    print(f"skills/{name}: {os.path.relpath(p, d)} is a symlink; symlinks are not supported", file=sys.stderr)
                    bad = True; continue
                ti = tarfile.TarInfo(os.path.relpath(p, d))
                ti.size = os.path.getsize(p)
                ti.mode = 0o755 if os.stat(p).st_mode & 0o100 else 0o644
                ti.mtime = 0; ti.uid = ti.gid = 0; ti.uname = ti.gname = ""
                with open(p, "rb") as fh:
                    tf.addfile(ti, fh)
    data = buf.getvalue()
    open(os.path.join(out, name + ".tar.gz"), "wb").write(data)
    sizes.append((name, len(data))); total += len(data)
if bad:
    sys.exit(1)
# base64 inflates binaryData by 4/3; the ConfigMap limit is 1 MiB for everything.
if total * 4 // 3 > 1_000_000:
    print("skills do not fit in one ConfigMap (1 MiB limit, ~750 KB of tarballs):", file=sys.stderr)
    for n, sz in sorted(sizes, key=lambda x: -x[1]):
        print(f"  {n}: {sz:,} bytes packed", file=sys.stderr)
    print("shrink the largest skills, or deliver skills with route A or B instead", file=sys.stderr)
    sys.exit(1)
