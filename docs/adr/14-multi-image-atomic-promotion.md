# ADR-14: Multi-image atomic promotion — two digests move as one unit

## Status

Accepted (operator 2026-06-12). Deploy-repo enforcement note added 2026-06-20
(single-image exemption). The authoritative ADR text lives in
[aegis-platform-aws/docs/adr/14-multi-image-atomic-promotion.md](https://github.com/BinHsu/aegis-platform-aws/blob/main/docs/adr/14-multi-image-atomic-promotion.md);
this file documents the `validate.yml` enforcement details and the exemption path
that is only relevant to this deploy repo.

## Summary

A prod promotion PR must change **both** the gateway and engine digests, or
**neither**. A PR that bumps one digest and leaves the other stale fails Guard D
in `validate.yml`. This enforces the "build-once, promote-as-a-pair" model: the
gateway and engine share a wire contract, and a half-promoted pair is an invalid
deployment.

See the authoritative ADR for full context: decision rationale, alternatives
considered, and consequences.

## Single-image exemption (added 2026-06-20)

An **intentional** single-image promotion is legitimate — for example, a
gateway-only security patch when the engine is unchanged. Before this exemption
existed, these PRs required a `--admin` bypass of the branch protection rule,
which left no auditable record of the deliberate decision.

### When to use

Add the `single-image-promotion` label to the PR when **all** of the following
are true:

1. Exactly one image digest is intentionally changing in the prod overlay.
2. The held image (the unchanged one) is already a valid, CI-verified pin — its
   base-branch state passed a prior CI run.
3. The changed image has been pushed to GHCR and is reachable by digest.

### What the guard does with the label

When Guard D detects that exactly one digest changed **and** the PR carries the
`single-image-promotion` label, it:

1. Determines which image moved (gateway or engine) and which was held.
2. Runs `docker manifest inspect <moved-digest>` to confirm the new digest
   exists in the public GHCR registry — a typo'd or unpushed pin fails here.
3. Emits a `::warning::` line naming the moved and held digests.
4. Exits 0 (allows the PR to merge).

Without the label, Guard D still exits 1 with a message directing the author to
add the label if the single-image promotion is intentional.

### What does NOT change

- The default path: two digests must move together, or Guard D blocks.
- The seed-equals-engine guard (Guard C): the engine seed Job must always carry
  the same digest as the engine Rollout, regardless of label.
- The digest-presence guard (Guard A) and registry guard (Guard B): every image
  line must still be `<full-ref>@sha256:<64-hex>` and resolve to GHCR.

### Why not `--admin` bypass

`--admin` bypasses **all** branch protection checks silently. The label approach:

- Requires an explicit, reviewer-visible decision on the PR.
- Is scoped to Guard D only — all other guards still run.
- Verifies the moved digest actually exists in GHCR (catches a typo that
  `--admin` would let through).
- Leaves a permanent audit trail in the PR labels and CI log.

## Related

[ADR-10](https://github.com/BinHsu/aegis-platform-aws/blob/main/docs/adr/10-release-model-build-once-promote-by-digest.md) ·
[ADR-12](https://github.com/BinHsu/aegis-platform-aws/blob/main/docs/adr/12-registry-injection-vs-digest-pin-field-ownership.md) ·
[ADR-23](https://github.com/BinHsu/aegis-platform-aws/blob/main/docs/adr/23-ghcr-graviton-image-distribution.md) (public GHCR — enables unauthenticated `docker manifest inspect` in Guard D)
