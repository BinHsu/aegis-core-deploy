## Summary

<!-- One or two sentences: what does this PR do and why? -->

## Change

<!-- Bullet list of the specific files or manifest sections modified. -->

-

## Validation

- [ ] `kustomize build k8s/overlays/staging` exits 0
- [ ] `kustomize build k8s/overlays/prod` exits 0
- [ ] Image references use a digest (`sha256:…`), not a mutable tag
- [ ] No secrets or credentials committed
- [ ] CI `validate` workflow passes
