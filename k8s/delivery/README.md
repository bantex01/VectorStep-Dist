# Changing config after install — three routes

Once VectorStep is running you'll want to change pipelines, steps and agents
**without restarting anything** — from a CI pipeline (GitLab, GitHub Actions,
Jenkins) or by hand. Both services hot-reload; the question on Kubernetes is
only *how the files get into the pod*. Pick one route per deployment. Full
explanation: https://vectorstep.io/docs/operations/changing-config-on-kubernetes/

|  | **A — API push** | **B — copy files** | **C — GitOps ConfigMap** |
|---|---|---|---|
| How | HTTPS calls to the write API | `kubectl exec`/tar into the pod, then reload | ConfigMaps + a reload sidecar |
| Validated *before* it goes live | **Yes** — a bad change is rejected | No — rolled back automatically if the reload is rejected | No — reload rejected, bad file stays (fix forward) |
| CI needs | the two admin tokens + network reach | `kubectl` access (RBAC provided) | `kubectl` access (RBAC provided) |
| Nothing exposed outside the cluster | No — Ingress or in-cluster runner | **Yes** | **Yes** |
| Time to live | seconds | seconds | ~1–2 min (Kubernetes ConfigMap sync) |
| Pipelines & steps | ✅ | ✅ | ✅ |
| Agents | ✅ | ✅ | ✅ (assembled by the sidecar) |
| Skills | ✅ | ✅ | ✅ (packed as tarballs) |
| Works with Argo CD / Flux | no | no | **yes** (C2) |
| UI/API edits | allowed | allowed | **blocked** (`writes_enabled: false`) |

**Not sure? Start with A** — it's the only route that checks a change before it
touches the running system. Choose **C** if your platform team mandates that
everything in the cluster is declared in git: either applied by a pipeline running
`apply.sh` (C1) or reconciled by Argo CD / Flux (C2).
Choose **B** when CI can reach the cluster with `kubectl` but you can't expose
VectorStep's APIs.

Whichever you choose, **git is the source of truth** and the pod's volume is a
deployed copy. VectorStep never writes to git, and the UI's pipeline pages are
read-only previews ("copy the YAML and ship it through git").

## What each folder contains

| | |
|---|---|
| [`a-api-push/`](a-api-push/) | `push.sh` (validate / apply from any CI), `gitlab-ci.example.yml`, `gateway-ingress.example.yaml` |
| [`b-file-copy/`](b-file-copy/) | `sync.sh` (copy + reload + automatic rollback), `ci-rbac.example.yaml` (least-privilege CI identity), `gitlab-ci.example.yml` |
| [`c-gitops-configmap/`](c-gitops-configmap/) | `apply.sh` (config dir → ConfigMaps, waits for the reload), `reloader.py` (sidecar), `pack-skills.py` (skills → tarballs), `service-patch.yaml`, `gateway-patch.yaml`, `gitlab-ci.example.yml` |
| [`shell-scripts.sh`](shell-scripts.sh) | for `executor: shell` steps, on any route: print the `sha256` pins, check them on a merge request, and apply the scripts ConfigMap (with a restart). Scripts are never part of routes A–C — see the docs page |

`push.sh`, `sync.sh` and `apply.sh` are plain bash that you copy into your
config repo and call from any CI. The `gitlab-ci.example.yml` files are thin
wrappers around them and are templates to adapt, not something we run for you.

## Route C setup (one time)

This is the setup for C1 (`apply.sh`). For C2 (Argo CD / Flux) the same patches go
in your GitOps repo and the ConfigMaps come from a kustomize `configMapGenerator`
— see the docs page linked above.

```sh
# 1. In each service's config.yaml ConfigMap, set (see the commented lines in
#    service/configmap.example.yaml and gateway/configmap.example.yaml):
#      writes_enabled: false
# 2. Create the ConfigMaps from your config directory
./delivery/c-gitops-configmap/apply.sh config <namespace>
# 3. Patch the Deployments once to mount them and add the reload sidecar
kubectl -n <ns> patch deploy/vectorstep         --patch-file delivery/c-gitops-configmap/service-patch.yaml
kubectl -n <ns> patch deploy/vectorstep-gateway --patch-file delivery/c-gitops-configmap/gateway-patch.yaml
```

From then on, every change is just `apply.sh config <namespace>`. Pin the
sidecar `image:` in both patches to the same tag as the main container.

## Things worth knowing

- **A bad file is rejected on reload, and skipped on restart.** A pipeline that
  fails validation and sits on disk (routes B and C) makes a reload fail with the
  file named; after a pod restart (releases after v0.1.10) the service skips it
  and starts, but **that pipeline handles no alerts** until fixed — check
  `config_errors` on `/health` and the UI banner. On v0.1.10 and earlier it
  refuses to start (CrashLoopBackOff). Route A rejects bad files up front;
  `sync.sh` rolls back; for route C validate in CI first (`push.sh validate`) and
  fix forward quickly. Details and recovery:
  https://vectorstep.io/docs/operations/changing-config-on-kubernetes/#recovering-from-a-bad-file
- **Files deleted from git** are not deleted from the cluster by route A. Route C
  mirrors git exactly (the ConfigMaps are rebuilt every run). Route B can mirror
  with `REMOVE_MISSING=1`.
- **Service and Gateway reload separately** — an agent change needs the Gateway
  reloaded, a pipeline change the service.
- **Apple-silicon M4 VMs:** if pods crash with exit code 132, see
  https://vectorstep.io/docs/troubleshooting/illegal-instruction-apple-m4/
