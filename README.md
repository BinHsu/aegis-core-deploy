# aegis-core-deploy

GitOps deploy repository for [`aegis-core`](https://github.com/BinHsu/aegis-core).
No application code, no CI build — declarative desired state only.

## Where this fits: the 4-repo model

```
aegis-platform-aws          shared platform: ArgoCD · Crossplane · Terraform (EKS, ACM, Cognito, Route 53)
├── aegis-core              service app: gateway (Go) + engine (Whisper gRPC) source + CI
└── aegis-core-deploy       THIS REPO — GitOps manifests; ArgoCD Application points here
    (aegis-greeter-deploy   same pattern, separate workload)
```

**Platform tier** owns the cluster and injects account-bound values (ECR registry URL,
ACM cert ARN, Cognito endpoints, AWS region) at ArgoCD sync time. **This repo** owns
the manifests and image digest pins. The app developer touches only this repo; no
Terraform, no cluster access required.

## Repository layout

```
k8s/
  base/
    aegis-core-gateway/     Rollout · Service · ServiceAccount · NetworkPolicy
    aegis-core-engine/      Rollout · Service (headless) · ServiceAccount · NetworkPolicy · seed Job
    aegis-core-policies/    Kyverno Policy (audio-namespace isolation)
    kustomization.yaml      aggregates the three base dirs; provider-neutral, no AWS coupling
  components/
    aws-binding/            additive layer that makes the base an EKS target (see below)
    onprem-binding/         additive layer for on-prem targets: MinIO (object store) + SPIRE (identity)
  overlays/
    staging/                EKS staging — base + aws-binding; 1 replica each; ArgoCD reconciles here
    prod/                   EKS prod   — base + aws-binding; prod hostname; digest-promoted from staging
    talos/                  on-prem     — base + onprem-binding; Gateway API HTTPRoute instead of ALB
    talos-standalone/       on-prem (no ArgoCD) — talos overlay + kustomize images: for direct kubectl apply
```

### The base

Provider-neutral. No ALB Ingress, no cloud identity markers, no prometheus-operator
CRDs. The engine `ServiceAccount` carries no IRSA annotation in the base — that
marker lives in `aws-binding` and only reaches EKS targets.

### The aws-binding component

`components/aws-binding` is the additive layer that makes the neutral base an EKS
target (ADR-16). Included by `overlays/staging` and `overlays/prod`; the Talos
overlays omit it entirely.

What it adds:

| Resource | Purpose |
|---|---|
| `gateway-ingress.yaml` | ALB Ingress (aws-load-balancer-controller); HTTPS 443; external-dns latency routing for dual-region |
| `gateway-oidc-configmap.yaml` | Cognito issuer / audience / JWKS URL — platform-injected placeholders |
| `model-store-configmap.yaml` | S3 bucket name — platform-injected placeholder |
| `iam/aegis-core-engine-identity.yaml` | `WorkloadIdentity` XR (Crossplane) → IAM role with S3 read on the model bucket |
| SA patch | Adds `aegis.binhsu.org/irsa-role-arn: platform-injected` annotation to the engine `ServiceAccount` |
| Engine Rollout patch | Adds `model-fetch` init-container: `aws s3 sync` from the model bucket into `/models` CAS |
| Gateway Rollout patch | Sets `DEPLOY_MODE=cloud` + injects Cognito env vars from the OIDC ConfigMap |
| Seed Job patch | Same `model-fetch` init-container as the engine Rollout |

The ALB Ingress component default is the staging hostname; the prod overlay patches
it to `aegis-api.prod.aws.binhsu.org`. Each overlay's `replacements` block rewrites
the external-dns `set-identifier` and `aws-region` from the platform-injected
`aegis.binhsu.org/region` annotation — so dual-region latency routing is automatic
with no per-region manifest edits.

> **Workload identity: IRSA today, EKS Pod Identity forward.** The current code uses
> IRSA (the engine SA annotation + OIDC token projection via the EKS pod-identity
> webhook). EKS Pod Identity (no SA annotation, `PodIdentityAssociation` on the
> platform side) is the target state for WS4 — it removes the cross-namespace trust
> footgun and the Crossplane `WorkloadIdentity` XR. Until that migration lands, IRSA
> is live and verified (WS3 staging E2E 2026-06-18).

### The onprem-binding component

`components/onprem-binding` substitutes the AWS services for on-prem targets:

- **MinIO** — object store replacing S3; a `minio-bootstrap` Job seeds the model
  bucket and auto-populates the STS Role ARN.
- **SPIRE** — issues JWT-SVIDs; the engine exchanges them at MinIO STS
  (`AssumeRoleWithWebIdentity`) for scoped temp credentials — the on-prem mirror of
  IRSA. Verified end-to-end on local Talos (WS2-3, 2026-06-16).

## How the platform consumes this repo

`aegis-platform-aws` runs an ArgoCD `ApplicationSet` (SCM-provider generator). It
discovers repos carrying the `aegis-workload` GitHub topic **and** the
`argocd/application.yaml` file in this repo. For each discovered repo the
ApplicationSet renders an `Application` that:

1. points `source.path` at `k8s/overlays/prod` (or `staging` — one Application per env)
2. injects account-bound values as `kustomize.commonAnnotations` at sync time:
   - `aegis.binhsu.org/ecr-repository` — full ECR URL (no account ID committed here)
   - `aegis.binhsu.org/region` — AWS region (drives external-dns latency routing)
   - ACM cert ARN, OIDC config, S3 bucket name

The `argocd/application.yaml` in this repo is the canonical declaration of intent —
it is **not** applied directly; the ApplicationSet renders the effective Application
from it.

## Image delivery (registry + digest)

All three image-bearing resources (gateway Rollout, engine Rollout, seed Job) share
one ECR repository `aegis-core`, distinguished by digest. Two channels, separate
owners:

| Channel | Owner | Mechanism |
|---|---|---|
| **Registry URL** | Platform (injected at sync) | `aegis.binhsu.org/ecr-repository` annotation + `replacements` splices it in front of the `@sha256` digest; `@` delimiter preserves the digest |
| **Image digest** | Deploy repo (committed here) | Per-resource JSON6902 patch files (`digest-*.yaml`); staging digests set by `aegis-core` CI (`release-staging-image.yml`); prod digests promoted from staging in an atomic commit (ADR-14) |

> `kustomize.images newName` is deliberately avoided: on kustomize v5.8.1 it
> overwrites the tag/digest field, rendering `:latest` (ADR-12).

Standalone `kustomize build` (no ArgoCD injection) falls back to the bare
`aegis-core@sha256:…` form — valid for local inspection; unreachable without a
real registry prefix.

## Running on-prem (no AWS, no platform tier)

The `overlays/talos-standalone` overlay runs the full stack on a local Talos cluster
with MinIO + SPIRE substituting for S3 + IRSA. No AWS account, no static credentials
in the engine path.

```sh
./quickstart.sh                              # default: ghcr.io/binhsu/aegis-core
REGISTRY=ghcr.io/<you>/aegis-core ./quickstart.sh   # your mirror
```

See **[docs/runbooks/ws2r-onprem-quickstart.md](docs/runbooks/ws2r-onprem-quickstart.md)**
for the end-to-end walkthrough (Talos-on-Docker default, kind/k3d adaptation),
the one image prerequisite, and troubleshooting.

## Observability

The platform cluster runs Grafana Alloy — no `prometheus-operator` CRD is
installed. `ServiceMonitor` resources were removed from this repo in WS3 (they
caused ArgoCD sync failures on the staging cluster). Alloy scrapes pods via
`discovery.kubernetes` and label relabeling — no `ServiceMonitor` required.
