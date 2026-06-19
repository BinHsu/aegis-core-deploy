# Changelog

All notable changes to this project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)  
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added
- Community health files: CODE_OF_CONDUCT, CONTRIBUTING, SECURITY, issue templates, PR template, CODEOWNERS, CHANGELOG
- README badges: CI validate, MIT license, OpenSSF Scorecard
- OpenSSF Scorecard workflow (`.github/workflows/scorecard.yml`)

## [0.2.0] — 2026-06-18

### Added
- AWS dual-region staging bring-up: gateway + engine Rollouts with Cognito OIDC, IRSA→S3 model pull, and external-dns latency routing for two regions (`feat/ws3-r` series, PRs #13–#16)
- On-prem quickstart (`quickstart.sh`, `overlays/talos-standalone`, runbook) for reviewer/forker workflow with no AWS account required (PR #10)
- `onprem-image-mirror.yml` CI workflow: single-repo image source for on-prem forkers, no PAT required (PR #11)
- SPIRE hardening: STS POST-body correctness, info-gated policy creation, scoped RBAC for `spire-bundle` (PR #12)
- Gateway per-env subdomain (`aegis-api.<env>.aws.binhsu.org`) and external-dns latency routing (PRs #14–#15)
- Digest promotion: staging digests pinned and promoted to prod overlay atomically (PRs #16, #21)

### Fixed
- Drop redundant `ServiceMonitor` resources from `aws-binding` component (PR #17)
- Mark `qdrant-credentials` secretKeyRef optional so engine pod starts without the secret (PR #19)
- Make audio-isolation a namespaced `Policy`, not a `ClusterPolicy` (PR #18)

### Changed
- `overlays/prod`: atomic gateway+engine digest promote from staging (PR #21)

## [0.1.0] — 2026-06-17

### Added
- MIT LICENSE (PR #24)
- README standardized to portfolio skeleton: nav table, C4-level context diagram, GitOps sequence diagram, architecture flowchart (PR #23)
- CodeRabbit quality gate: request-changes + pre-merge checks (PR #3)
- `validate.yml` CI workflow: Kustomize render + four guards (digest-pinned images, registry splice, seed Job digest parity, atomic prod promotion) (PR #4)
- Provider-neutral `k8s/base` with `aws-binding` and `onprem-binding` components; `overlays/staging` and `overlays/prod` (PRs #4–#5)
- Engine IAM via Crossplane `WorkloadIdentity` XR (ADR-09, PRs #1–#2)
- SPIRE identity: IRSA→SPIFFE→MinIO-STS, live-verified on Talos (PR #8)
- MinIO object-store substitute (`components/onprem-binding`, ADR-18, PR #7)
- Initial Kustomize manifests relocated from `aegis-core` (initial commit)
