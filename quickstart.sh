#!/usr/bin/env bash
# WS2-R on-prem quickstart — stand up the full aegis-core on-prem stack
# (SPIRE identity -> MinIO object store -> engine, model delivered via the
# SPIRE->STS chain) on a local Talos-on-Docker cluster, from a clean clone.
#
# Default substrate: Talos in Docker (cross-platform, survives restart). For
# kind / k3d, see docs/runbooks/ws2r-onprem-quickstart.md — the manifests are
# the same; only the cluster-creation and a couple of defaults differ.
#
# This is the scripted form of the runbook. Read the runbook for the why and
# for troubleshooting; this script encodes the happy path.
#
# Idempotent: re-running skips a cluster that already exists and re-applies the
# manifests (kustomize apply is declarative). To start over: `talosctl cluster
# destroy --provisioner docker --name "$CLUSTER"`.
set -euo pipefail

# --- knobs (override via env) ------------------------------------------------
CLUSTER="${CLUSTER:-aegis-ws2r}"
NODE_MEMORY_MB="${NODE_MEMORY_MB:-6144}"   # SPIRE + MinIO + engine + controllers
REGISTRY="${REGISTRY:-ghcr.io/binhsu/aegis-core}"  # single-repo image source; see overlays/talos-standalone
OVERLAY="${OVERLAY:-k8s/overlays/talos-standalone}"

# Pinned add-on versions. VERIFY/bump to a current release before a real run —
# these are the controllers the platform tier normally provides (here we install
# them into the local cluster so the Rollout + ClusterPolicy manifests apply).
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.30}"
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.7.2}"
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.4}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. preflight ------------------------------------------------------------
log "1/7 preflight — required tools"
for t in docker talosctl kubectl; do
  command -v "$t" >/dev/null 2>&1 || die "missing '$t' (see the runbook for install links)"
done
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
echo "ok: docker, talosctl, kubectl present; docker daemon up"

# --- 2. Talos-on-Docker cluster ---------------------------------------------
log "2/7 Talos cluster '$CLUSTER' (docker provisioner, single schedulable node)"
if talosctl cluster show --provisioner docker --name "$CLUSTER" >/dev/null 2>&1; then
  echo "cluster '$CLUSTER' already exists — reusing it"
else
  # workers 0 + allowSchedulingOnControlPlanes => one node runs everything.
  talosctl cluster create \
    --provisioner docker \
    --name "$CLUSTER" \
    --controlplanes 1 \
    --workers 0 \
    --memory "$NODE_MEMORY_MB" \
    --config-patch '[{"op":"add","path":"/cluster/allowSchedulingOnControlPlanes","value":true}]'
fi
# talosctl merges + selects the kubeconfig context for this cluster.
kubectl config use-context "admin@${CLUSTER}" >/dev/null 2>&1 || true
echo "waiting for the node to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- 3. storage: local-path-provisioner as the default StorageClass ----------
# Talos ships no default StorageClass; the SPIRE datastore + MinIO PVCs (WS2-R
# gap #4) need one. (kind/k3d already have a default — skip this step there.)
log "3/7 local-path-provisioner ($LOCAL_PATH_VERSION) as default StorageClass"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# --- 4. controllers the manifests depend on ----------------------------------
# Argo Rollouts: the gateway + engine are argoproj.io/Rollout — without the CRD
# `kubectl apply` rejects them, and without the controller they create no pods.
# Kyverno: the base ships a ClusterPolicy; the CRD must exist for apply to pass.
log "4/7 Argo Rollouts ($ARGO_ROLLOUTS_VERSION) + Kyverno ($KYVERNO_VERSION)"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"
kubectl apply -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s

# --- 5. apply the stack ------------------------------------------------------
log "5/7 apply (registry: $REGISTRY)"
if [ "$REGISTRY" = "ghcr.io/binhsu/aegis-core" ]; then
  # Default: the committed standalone overlay (already points at this registry).
  kubectl apply -k "$OVERLAY"
else
  # Custom registry: inject it WITHOUT mutating the tracked overlay — render a
  # throwaway kustomization that layers the images transformer over talos.
  TMP_OVERLAY="$(mktemp -d)"
  trap 'rm -rf "$TMP_OVERLAY"' EXIT
  cat > "$TMP_OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $REPO_ROOT/k8s/overlays/talos
images:
  - name: aegis-core
    newName: $REGISTRY
EOF
  kubectl apply -k "$TMP_OVERLAY"
fi

# --- 6. wait for the stack ---------------------------------------------------
log "6/7 waiting for the stack to converge"
echo "spire-server..."; kubectl -n spire-system rollout status statefulset/spire-server --timeout=180s
echo "minio...";        kubectl -n aegis-core   rollout status deploy/minio --timeout=180s
echo "minio-bootstrap (seeds the model + auto-populates the STS Role ARN)..."
kubectl -n aegis-core wait --for=condition=complete job/minio-bootstrap --timeout=300s
echo "engine pod (Argo Rollouts manages it; wait on the pod so no plugin is needed)..."
ENGINE_OK=1
if ! kubectl -n aegis-core wait --for=condition=Ready pod \
       -l app.kubernetes.io/name=aegis-core-engine --timeout=300s; then
  ENGINE_OK=0
  printf '\n\033[1;33mWARNING:\033[0m engine pod not Ready within 5m — diagnostics below.\n'
fi

# --- 7. verify ---------------------------------------------------------------
log "7/7 verify"
echo "minio-sts Role ARN (should NOT be the REPLACE_WITH placeholder):"
kubectl -n aegis-core get configmap minio-sts -o jsonpath='{.data.role_arn}{"\n"}'
echo
echo "engine pod:"
kubectl -n aegis-core get pods -l app.kubernetes.io/name=aegis-core-engine

cat <<EOF

Inspect:   kubectl -n aegis-core get pods,job,cm,pvc
Engine log: kubectl -n aegis-core logs <engine-pod> -c engine
Tear down: talosctl cluster destroy --provisioner docker --name $CLUSTER
EOF

if [ "$ENGINE_OK" = 1 ]; then
  cat <<'EOF'

Done — the full chain is live (engine pod 1/1 Ready):
  SPIRE attests the engine SA -> JWT-SVID -> MinIO STS AssumeRoleWithWebIdentity
  -> scoped temp creds -> model mirrored into /models -> engine serves gRPC :50051.
EOF
else
  die "engine did not become Ready — inspect the pods/logs above (see the runbook's Troubleshooting)."
fi
