# aegis-core_deploy

GitOps deploy repository for [`aegis-core`](https://github.com/BinHsu/aegis-core),
per aegis-core **ADR-0036** (three-tier topology: application repo →
deploy repo → platform tier).

## What this repo is

This repo holds the Kubernetes manifests for the Cloud-mode staging
deployment of Aegis Core (gateway + engine + policies). It is a pure
GitOps source of truth — no application code, no CI build, just the
declarative desired state.

```
k8s/
  base/
    aegis-core-gateway/    Rollout · Service · Ingress · ServiceAccount · NetworkPolicy · ServiceMonitor
    aegis-core-engine/     Rollout · Service (headless) · ServiceAccount (IRSA) · NetworkPolicy · ServiceMonitor · seed Job
    aegis-core-policies/   Kyverno ClusterPolicy (audio-namespace no-PVC / no-hostPath)
    kustomization.yaml     aggregates the three component dirs
  overlays/
    prod/
      kustomization.yaml   resources: [../../base] + the registry `images:` block
```

## Who reconciles it

**ArgoCD** — owned by the `aegis-platform` tier — points its
Application CR at `k8s/overlays/prod`, renders the kustomization, and
syncs the result into the `aegis` namespace.

## Image tags

The three image-bearing manifests (`aegis-core-gateway/rollout.yaml`,
`aegis-core-engine/rollout.yaml`, `aegis-core-engine/seed-job.yaml`)
reference a bare `aegis-core:<tag>` image. Two moving parts:

- **Registry path** — the full ECR URL (with the AWS account ID) is
  de-hardcoded into `k8s/overlays/prod/kustomization.yaml` via the
  kustomize `newName` mechanism. One place, all three images.
- **Image tag** — stays in the base rollout / seed-job manifests.
  aegis-core CI (`release-staging-image.yml` `bump-image-tag` job,
  ADR-0032) rewrites it after each release build and opens an
  auto-merge PR.

`main` has **no human-review gate on the tag-bump path** by design —
the bump is a mechanical, CI-authored change and gating it would only
add latency between a green release build and the cluster reconcile.
