# Kubernetes manifests

Plain, copy-and-adapt YAML — deliberately not a Helm chart. The images come
from GHCR; nothing here needs source access.

- [`service/`](service/) — the VectorStep orchestration service
- [`gateway/`](gateway/) — the Gateway agent runtime

**Deploy both.** The service's config points at the Gateway's Service
(`vectorstep-gateway:18780`), and they deploy as a **matched pair** — there is
no wire-version negotiation between them yet, so run matching image tags.

## Apply order

The Gateway's tokens are an **input**, not an output — generate both up front
so the sequencing below needs no round trip through a running pod:

```sh
GATEWAY_ADMIN_TOKEN="$(openssl rand -hex 24)"
GATEWAY_INVOKE_TOKEN="$(openssl rand -hex 24)"

kubectl create secret generic vectorstep-gateway-secrets \
  --from-literal=VECTORSTEP_GATEWAY_ADMIN_TOKEN="$GATEWAY_ADMIN_TOKEN" \
  --from-literal=VECTORSTEP_GATEWAY_INVOKE_TOKEN="$GATEWAY_INVOKE_TOKEN" \
  --from-literal=ANTHROPIC_API_KEY=...
kubectl apply -f gateway/pvc.yaml
kubectl apply -f gateway/configmap.example.yaml   # copy + edit first
kubectl apply -f gateway/deployment.yaml
kubectl apply -f gateway/service.yaml
```

Then the service, reusing the **invoke** token you already generated (never
the Gateway's admin one, since the service only ever reads agents and runs
them, never writes them) — plus VectorStep's own two tokens, distinct from
the Gateway's, for logging into the UI and authenticating `POST /webhook`:

```sh
VECTORSTEP_ADMIN_TOKEN="$(openssl rand -hex 24)"
VECTORSTEP_WEBHOOK_TOKEN="$(openssl rand -hex 24)"

kubectl create secret generic vectorstep-secrets \
  --from-literal=VECTORSTEP_GATEWAY_TOKEN="$GATEWAY_INVOKE_TOKEN" \
  --from-literal=VECTORSTEP_ADMIN_TOKEN="$VECTORSTEP_ADMIN_TOKEN" \
  --from-literal=VECTORSTEP_WEBHOOK_TOKEN="$VECTORSTEP_WEBHOOK_TOKEN"
kubectl apply -f service/pvc.yaml
kubectl apply -f service/configmap.example.yaml   # copy + edit first
kubectl apply -f service/deployment.yaml
kubectl apply -f service/service.yaml
```

`VECTORSTEP_ADMIN_TOKEN` is what you log into the UI with, and is required
for `/reload` and most read endpoints — `auth.tokens` in
`configmap.example.yaml` wires both into the service; VectorStep refuses to
start without at least one configured token (or
`auth.allow_unauthenticated: true`), same as every other install path.

Deploy the Gateway first if you're applying by hand rather than scripting
both secrets up front — the service's config points at the Gateway's Service
(`vectorstep-gateway:18780`), and they deploy as a **matched pair** with no
wire-version negotiation between them yet, so run matching image tags.

## Changing config after install

Pipelines, steps and agents hot-reload — no restart. [`delivery/`](delivery/)
has three documented routes with copy-and-tweak templates (API push from CI,
`kubectl` copy + reload, and a GitOps ConfigMap route with a reload sidecar);
start with [`delivery/README.md`](delivery/README.md).

## The Gateway's two tokens

`VECTORSTEP_GATEWAY_ADMIN_TOKEN` and `VECTORSTEP_GATEWAY_INVOKE_TOKEN` in
`vectorstep-gateway-secrets` — both, or neither — make the Gateway's identity
declarative: supply both and it uses them directly, skips minting entirely,
and never writes `device-auth.json` (there's nothing to persist under
`readOnlyRootFilesystem`, and nothing that should be). Supplying only one
fails startup naming the other; a token under 32 characters is rejected too,
so a placeholder like `changeme` can't reach production. The apply order
above already does this correctly — generate both up front, put
`admin` in the Gateway's secret, put **only the invoke token** (never admin)
in the service's `VECTORSTEP_GATEWAY_TOKEN`.

The **admin** token is for whoever authors agents (a Gateway MCP client, or
`curl` against the write endpoints directly) — it is deliberately not one of
the service's own secrets, since nothing in this stack's own pods needs it.
Retrieve it however your secrets tooling retrieves values you set yourself
(it's the value you generated above, not something to extract from the pod).

**If you don't supply either token** (an evaluation deployment, or migrating
an existing install that already has a `device-auth.json` on its PVC), the
Gateway falls back to its original behaviour — load what's on disk, or mint
fresh tokens on first boot and print them to its own logs:

```sh
kubectl logs deploy/vectorstep-gateway | grep -A2 "Two tokens were minted"
# or, after the fact:
kubectl exec deploy/vectorstep-gateway -- \
  python -c "import json;print(json.load(open('/data/identity/device-auth.json'))['tokens']['invoke']['token'])"
```

The `docker compose` installer automates this same mint-and-extract path,
which is why it stays relevant there even though Kubernetes should generally
prefer the declarative path above.

## Reaching the Gateway from outside the cluster

`gateway/service.yaml` is `ClusterIP` — reachable in-cluster only, which is
all the service itself needs. If you're pointing a Gateway MCP client (or
anything else outside the cluster) at the Gateway, don't change the Service's
`type:`; use a port-forward instead:

```sh
kubectl port-forward deploy/vectorstep-gateway 18780:18780
```

and point `GATEWAY_BASE_URL` at `http://127.0.0.1:18780`. If you need
something longer-lived than a port-forward, put TLS and authentication (an
`Ingress` with the admin scope, not the invoke one) in front of it rather
than exposing the Service directly — the Gateway's admin token can rewrite
agent definitions. See `service/` for the equivalent `ingress.example.yaml`
pattern.

## Security hardening

Both deployments pass Pod Security Admission at `restricted` unmodified —
verified against a real cluster, not just read off the baseline: `runAsNonRoot`,
a dropped capability set, no privilege escalation, `seccompProfile:
RuntimeDefault`, and `readOnlyRootFilesystem: true` (the last one isn't a
strict PSA requirement, but it's in every Kyverno/Gatekeeper baseline that
usually accompanies `restricted`, and the images are close to compliant
already). Two consequences worth knowing before you apply them:

- **A fresh PVC needs an init container.** Unlike a Docker named volume
  (which gets the image's existing `/data` content copied in automatically
  the first time it's used), a Kubernetes PVC is provisioned genuinely empty
  — mounting it over `/data` hides the image's own `mkdir -p`. The service's
  `deployment.yaml` now runs a small `init-data-dirs` init container
  (`mkdir -p` the same paths the Dockerfile creates) before the main
  container starts; without it, the pod crash-loops on first boot with
  `Pipeline config directory not found: /data/pipelines` or a SQLite
  `unable to open database file` (the latter is now also self-healing at the
  application level — see `service/src/db/database.py` — but pipelines/steps
  intentionally still fail loudly on a missing directory, since that's the
  only signal that catches a typo'd `pipeline_config_dir`).
- **The Gateway's read-only root breaks `npx`/`uvx`-based MCP servers unless
  their caches are redirected.** Both download packages at runtime and write
  under `$HOME`, which is read-only under this setting. `deployment.yaml` now
  sets `HOME`/`NPM_CONFIG_CACHE`/`XDG_CACHE_HOME` to paths under the existing
  `/data` PVC — verified end-to-end against a real `npx`-based MCP server
  (`@modelcontextprotocol/server-filesystem`): it starts, `/health` reports it
  running, and a pod restart reuses the cache instead of re-downloading.

`k8s/networkpolicy.example.yaml` (copy, edit, apply — not applied by
default) adds two ingress-only policies: the Gateway accepts port 18780 only
from pods labelled `app: vectorstep` (the highest-value policy here — the
Gateway's admin token can rewrite agent definitions), and the service accepts
port 8000 only from your ingress controller's namespace and whatever
namespace your webhook senders live in (edit both placeholder
`namespaceSelector` labels — they match nothing until you do, so the policy
fails closed rather than open). Whether either policy does anything depends
on your cluster's CNI actually enforcing `NetworkPolicy` — Calico and Cilium
do, kind's and minikube's default CNIs don't. Egress is deliberately not
included: both services need to reach arbitrary LLM provider endpoints and
whatever your pipelines query, so a useful egress policy is entirely
deployment-specific.

## Two things worth knowing

**Single replica.** `deployment.yaml` sets `replicas: 1` with
`strategy: Recreate`, required today regardless of database backend — the
scheduler (APScheduler) and the dedup/event state are in-process. A second
replica would double-fire scheduled pipelines and desync dedup windows.
`Recreate` also guarantees the old pod is fully gone before the new one starts,
which is what makes the in-process Alembic migration on boot safe with no
*migration-specific* init container. (The service does have one init
container as of this hardening pass — see below — but it's a plain `mkdir -p`,
unrelated to migrations.)

**Pin your image tags in production.** `latest` tracks the most recent release
and `edge` tracks the default branch; a GitOps controller (Argo CD, Flux) would
watch a pinned tag. See
[Versions and releases](https://vectorstep.io/docs/about/status-and-support/#versions-and-releases).

**Why no Helm chart.** These manifests are the ground truth a chart would
template. Templating before there is a second real user to justify the
abstraction is premature — a deliberate deferral, not an oversight.

## Config reference

Every field in the ConfigMaps is documented at
[Deployment](https://vectorstep.io/docs/operations/deployment/). Secrets arrive
as environment variables consumed by the config's `${VAR}` substitution — no
secret value is ever baked into a ConfigMap or an image.
