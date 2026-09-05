# Kubernetes manifests

Plain, copy-and-adapt YAML — deliberately not a Helm chart. The images come
from GHCR; nothing here needs source access.

- [`service/`](service/) — the VectorStep orchestration service
- [`gateway/`](gateway/) — the Gateway agent runtime

**Deploy both.** The service's config points at the Gateway's Service
(`vectorstep-gateway:18780`), and they deploy as a **matched pair** — there is
no wire-version negotiation between them yet, so run matching image tags.

## Apply order

Gateway first, since the service calls out to it:

```sh
kubectl create secret generic vectorstep-gateway-secrets \
  --from-literal=ANTHROPIC_API_KEY=...
kubectl apply -f gateway/pvc.yaml
kubectl apply -f gateway/configmap.example.yaml   # copy + edit first
kubectl apply -f gateway/deployment.yaml
kubectl apply -f gateway/service.yaml
```

Then the service:

```sh
kubectl create secret generic vectorstep-secrets \
  --from-literal=VECTORSTEP_GATEWAY_TOKEN=... \
  --from-literal=VECTORSTEP_WEBHOOK_TOKEN=...
kubectl apply -f service/pvc.yaml
kubectl apply -f service/configmap.example.yaml   # copy + edit first
kubectl apply -f service/deployment.yaml
kubectl apply -f service/service.yaml
```

## The Gateway operator token

The Gateway mints an operator token for itself on first boot; there is no way
to pre-supply one. So `vectorstep-secrets` above needs a value you can only get
*after* the Gateway pod is running:

```sh
kubectl exec deploy/vectorstep-gateway -- \
  python -c "import json;print(json.load(open('/data/identity/device-auth.json'))['tokens']['operator']['token'])"
```

Create the secret with that value, then apply the service manifests. The
`docker compose` installer automates this step; on Kubernetes it stays manual.

## Two things worth knowing

**Single replica.** `deployment.yaml` sets `replicas: 1` with
`strategy: Recreate`, required today regardless of database backend — the
scheduler (APScheduler) and the dedup/event state are in-process. A second
replica would double-fire scheduled pipelines and desync dedup windows.
`Recreate` also guarantees the old pod is fully gone before the new one starts,
which is what makes the in-process Alembic migration on boot safe with no init
container.

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
