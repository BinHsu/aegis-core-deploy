# WS2-R — on-prem quickstart (run the full aegis-core stack on your own cluster)

This runbook stands up the complete `aegis-core` on-prem stack from a clean
clone of this repo: **SPIRE** issues the engine a workload identity, the engine
exchanges it at **MinIO**'s STS endpoint for scoped credentials, pulls its model
from the MinIO object store, and serves gRPC. No AWS, no static credentials in
the engine path, no operator-only steps.

The default substrate is **Talos on Docker** — cross-platform and it survives a
restart. A [kind / k3d](#adapting-to-kind--k3d) section follows for those who
prefer them.

`./quickstart.sh` runs everything below end to end. This document explains each
step, the one image prerequisite, how to verify, and how to adapt.

---

## What you need

| Tool | Why | Install |
|---|---|---|
| Docker (or OrbStack) | hosts the Talos node containers | docker.com / orbstack.dev |
| `talosctl` | creates the Talos-on-Docker cluster | https://www.talos.dev/latest/talos-guides/install/talosctl/ |
| `kubectl` | applies manifests | kubernetes.io |
| `kustomize` | only if you override the image registry (`kubectl` has it built in for apply) | kubernetes-sigs/kustomize |
| `crane` | one-time image mirror (below) | google/go-containerregistry |

**Resources:** the single node co-schedules SPIRE (server + agent + OIDC), MinIO,
the engine, plus the Argo Rollouts and Kyverno controllers. Give Docker headroom
— the quickstart sizes the node at **6 GB** (`NODE_MEMORY_MB`). On a 16 GB host
with little free RAM the full co-resident stack may not fit; see
[Troubleshooting → RAM / disk wall](#ram--disk-wall).

---

## The one prerequisite: a single-repo image source

The engine and gateway images are published by aegis-core CI to **two** GHCR
packages — `aegis-core-engine` and `aegis-core-gateway`. The manifests use the
single-repo model (one repo, images distinguished by digest — the same shape the
AWS side uses with ECR), so mirror both digests into **one** repo once.

**Preferred — the CI mirror (no PAT):** run the `onprem-image-mirror` workflow.
It uses the built-in `GITHUB_TOKEN` (no token to paste) and, because this repo is
public, the resulting `aegis-core` package inherits public visibility — no manual
visibility change.

```sh
gh workflow run onprem-image-mirror.yml --repo <you>/aegis-core-deploy
# inputs default to the digests currently pinned in overlays/talos; override if yours differ
gh run watch --repo <you>/aegis-core-deploy "$(gh run list --repo <you>/aegis-core-deploy -w onprem-image-mirror.yml -L1 --json databaseId --jq '.[0].databaseId')"
```

**Manual alternative (no CI):** mirror locally. Copy preserves the digest, so the
pins in `overlays/talos/kustomization.yaml` stay valid. With `crane`:

```sh
crane copy ghcr.io/binhsu/aegis-core-engine@sha256:<engine-digest>   ghcr.io/<you>/aegis-core@sha256:<engine-digest>
crane copy ghcr.io/binhsu/aegis-core-gateway@sha256:<gateway-digest> ghcr.io/<you>/aegis-core@sha256:<gateway-digest>
```

…or with Docker (no install): `docker buildx imagetools create -t ghcr.io/<you>/aegis-core:onprem-engine ghcr.io/binhsu/aegis-core-engine@sha256:<engine-digest>` (repeat for gateway). A locally-pushed package starts **private** — make it public in the GitHub package settings, or the cluster needs an `imagePullSecret`.

Then point the overlay at your repo — edit `newName` in
`k8s/overlays/talos-standalone/kustomization.yaml`, or set
`REGISTRY=ghcr.io/<you>/aegis-core` when you run `quickstart.sh`. If a public
`ghcr.io/binhsu/aegis-core` already exists, the default works with no copy.

> Forking aegis-core too? Run its `release-onprem-image.yml` in your fork to
> build both images into your own GHCR, then mirror as above. The clean
> long-term fix is to push both to one repo from that release workflow directly.

---

## Default path: Talos on Docker

Run it:

```sh
./quickstart.sh                       # uses ghcr.io/binhsu/aegis-core
REGISTRY=ghcr.io/<you>/aegis-core ./quickstart.sh   # your mirror
```

What it does, step by step:

1. **Preflight** — checks `docker`, `talosctl`, `kubectl` and that the Docker
   daemon is up.
2. **Cluster** — `talosctl cluster create --provisioner docker`, one control
   plane, `--workers 0`, `allowSchedulingOnControlPlanes: true` so the single
   node runs workloads. Idempotent: an existing cluster is reused.
3. **Storage** — installs `local-path-provisioner` and marks it the **default
   StorageClass**. Talos ships none, and the SPIRE datastore + MinIO need PVCs
   to survive a restart (WS2-R gap #4).
4. **Controllers** — installs **Argo Rollouts** (the gateway + engine are
   `argoproj.io/Rollout`; without the CRD `kubectl apply` rejects them, without
   the controller they create no pods) and **Kyverno** (the base ships a
   `ClusterPolicy`; its CRD must exist for apply to pass). On the platform tier
   ArgoCD provides these; here we install them directly.
5. **Apply** — `kubectl apply -k k8s/overlays/talos-standalone`. That overlay
   rewrites the bare `aegis-core@sha256:…` images to your registry (gap #2);
   everything else is the verified `overlays/talos` stack.
6. **Converge** — waits for spire-server, MinIO, the `minio-bootstrap` Job
   (which seeds the model **and** auto-populates the STS Role ARN — gap #1), and
   the engine Rollout.
7. **Verify** — prints the populated Role ARN and the engine pod state.

---

## How to know it worked

The stack is healthy when the engine pod is `1/1 Ready`. Behind that, the WS2-3
identity chain ran end to end:

```sh
# 1. SPIRE attested the node + engine workload, issued a JWT-SVID
kubectl -n spire-system exec spire-server-0 -- \
  /opt/spire/bin/spire-server entry show -socketPath /run/spire/server-sockets/api.sock

# 2. the STS Role ARN was discovered and written (NOT the placeholder)
kubectl -n aegis-core get configmap minio-sts -o jsonpath='{.data.role_arn}{"\n"}'
# -> arn:minio:iam:::role/<hash>     (not arn:minio:iam:::role/REPLACE_WITH_...)

# 3. the engine init chain: fetch-jwt -> sts-exchange -> model-fetch
kubectl -n aegis-core logs <engine-pod> -c sts-exchange   # "STS exchange OK; scoped temporary credentials issued"
kubectl -n aegis-core logs <engine-pod> -c model-fetch    # "model CAS populated."

# 4. the engine serves gRPC
kubectl -n aegis-core logs <engine-pod> -c engine         # "listening on 0.0.0.0:50051"
```

**Survives a restart:** `docker restart`-ing the Talos node (or stopping/starting
the cluster) keeps the PVCs, so MinIO's bucket + IAM config and SPIRE's datastore
+ signing keys come back — the engine re-attests against persisted identity
state rather than a wiped one. (A full `talosctl cluster destroy` is a clean
slate, by design.)

---

## Adapting to kind / k3d

The manifests are identical; only cluster creation and two defaults change.

| Concern | Talos (default) | kind | k3d |
|---|---|---|---|
| Create | `talosctl cluster create --provisioner docker …` | `kind create cluster` | `k3d cluster create` |
| Default StorageClass | none → quickstart installs `local-path` | `standard` ships built-in — **skip step 3** | `local-path` ships built-in — **skip step 3** |
| Pod Security Admission | enforced; SPIRE ns is labelled `privileged`, workloads `restricted` (already in the manifests) | **off by default** — manifests still work; to mirror Talos, label namespaces (see below) | same as kind |
| hostPath / privileged (SPIRE agent) | allowed under the `privileged` ns label | allowed | allowed |
| Workload scheduling | single node via `allowSchedulingOnControlPlanes` | all nodes schedulable | all nodes schedulable |

To run on kind/k3d, replace step 2 of the quickstart with your cluster-create
command and **skip step 3** (storage). Steps 4–7 are unchanged. Quick manual
sequence:

```sh
kind create cluster --name aegis-ws2r      # or: k3d cluster create aegis-ws2r
# (skip local-path — your distro already has a default StorageClass)
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/download/v1.7.2/install.yaml
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
kubectl apply -k k8s/overlays/talos-standalone
```

If you want kind/k3d to enforce the same PSA posture Talos does (optional — the
manifests carry the right securityContexts regardless):

```sh
kubectl label ns spire-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns aegis-core   pod-security.kubernetes.io/enforce=restricted  --overwrite
```

---

## Troubleshooting

**`ImagePullBackOff` on engine/gateway** — the image repo isn't reachable. You
skipped the [single-repo mirror](#the-one-prerequisite-a-single-repo-image-source),
or `REGISTRY` points somewhere without the digests, or the repo is private.
Confirm: `crane manifest ghcr.io/<you>/aegis-core@sha256:<digest>`.

**`minio-sts` ARN stuck on `REPLACE_WITH_…`** — the `populate-sts-arn` step
didn't run or couldn't read MinIO's log. Check
`kubectl -n aegis-core logs job/minio-bootstrap -c populate-sts-arn`. The engine
`sts-exchange` init-container waits for a real ARN, so it will sit in Init until
this lands — that's expected, not a hang, for the first couple of minutes.

**Engine init `sts-exchange` fails after a long wait** — the JWT-SVID is
short-lived; if `sts-exchange` waited past its TTL (e.g. the ARN took minutes),
delete the engine pod so a fresh JWT is fetched. Normal first-boot ordering
fetches both close together.

**`no matches for kind "Rollout"` / `"ClusterPolicy"`** — step 4 (Argo Rollouts /
Kyverno) didn't complete before apply. Re-run it, then re-apply.

**PVCs stuck `Pending` / `ProvisioningFailed` on Talos** — two Talos-specific
local-path gotchas (handled by `quickstart.sh` step 3; do them by hand if you
deploy local-path yourself). Verified live on Talos v1.13.3 (WS2-R Phase 2):
1. local-path provisions each PVC via a short-lived **helper pod that mounts a
   hostPath**. Talos's default PSA (`baseline`) rejects hostPath, so every helper
   pod is `forbidden` and the PVC never binds. Fix: `kubectl label ns
   local-path-storage pod-security.kubernetes.io/enforce=privileged --overwrite`.
2. Talos's root fs is read-only; local-path's default `/opt/local-path-provisioner`
   is not writable. Point `cm/local-path-config`'s `nodePathMap` path at
   `/var/local-path-provisioner`, restart the provisioner; PVCs bind within a
   retry cycle.

<a id="ram--disk-wall"></a>**RAM / disk wall (the full stack won't co-reside)** —
on a tight host the controllers + SPIRE + MinIO + engine may not all fit, and a
small node's ephemeral storage hits `DiskPressure` while the engine image is
pulled/extracted — this is the ADR-16/17 substrate wall. **Observed live (WS2-R
Phase 2, apple/container, 4 GB node / ~1.45 GB allocatable ephemeral storage):**
SPIRE + MinIO + the model-seed all came up and the `minio-bootstrap` Job
completed (model seeded, `minio-sts` ARN auto-populated), but pulling the engine
image drove the node to `DiskPressure=True`, which evicted the `spire-agent`
DaemonSet pod (`Pod was rejected: node had condition [DiskPressure]`) — so the
engine/seed init chain (which needs the agent's Workload API socket) could not
complete. Options: raise `NODE_MEMORY_MB` **and** give the node more disk, free
host resources, or verify the substitutes one at a time on a fresh node (bring up
SPIRE + MinIO, prove the auto-ARN + STS chain, then the engine separately) — the
slice-verify fallback WS2 used.

**Teardown:** `talosctl cluster destroy --provisioner docker --name aegis-ws2r`
(or `kind delete cluster --name aegis-ws2r` / `k3d cluster delete aegis-ws2r`).
