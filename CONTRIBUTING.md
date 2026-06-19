# Contributing to aegis-core-deploy

`aegis-core-deploy` is the GitOps deploy repository for [aegis-core](https://github.com/BinHsu/aegis-core) — the gateway and inference-engine services that form the Aegis AI platform. This repo holds Kubernetes manifests managed by ArgoCD; changes here flow directly to the cluster.

## Repository layout

```
k8s/
  base/          # shared manifests (Deployment, Service, …)
  overlays/
    staging/     # staging-specific patches and config
    prod/        # production-specific patches and config
```

## Local validation

Before opening a PR, verify that Kustomize can render the overlay cleanly:

```bash
kustomize build k8s/overlays/staging
kustomize build k8s/overlays/prod
```

The `validate` CI workflow runs these same commands on every PR. Fix any render error locally first.

## Adding a workload

1. Create a `base/` directory for the new service (Deployment, Service, and any required CRDs).
2. Add an overlay under each target environment with environment-specific patches (replica count, image digest, resource limits).
3. Run `kustomize build` for each overlay and confirm clean output.
4. Open a PR against `main` with the checklist below completed.

## Patching a base

1. Make the minimal change needed in `k8s/base/`.
2. Run `kustomize build` for all overlays that inherit the base.
3. If a patch in an overlay must change as a result, update it in the same PR.

## PR checklist

- [ ] `kustomize build k8s/overlays/staging` exits 0
- [ ] `kustomize build k8s/overlays/prod` exits 0
- [ ] Image references use a digest (`sha256:…`), not a mutable tag
- [ ] No secrets or credentials committed
- [ ] PR description explains *why* the change is needed, not just *what* changed

## Branch naming

| Type | Pattern | Example |
|---|---|---|
| Digest promotion | `chore/promote-<service>-<short-sha>` | `chore/promote-engine-a1b2c3d` |
| New workload | `feat/<workload-name>` | `feat/summariser` |
| Bug fix | `fix/<short-description>` | `fix/engine-probe-path` |
| Docs / chore | `chore/<short-description>` | `chore/community-health` |

## Code of conduct

This project follows the [Contributor Covenant v2.1](.github/CODE_OF_CONDUCT.md). By participating you agree to its terms.
