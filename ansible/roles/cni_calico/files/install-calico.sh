#!/usr/bin/env bash
# install-calico.sh — apply Project Calico CNI to the current cluster.
#
# Idempotent: re-running with the same Calico version is safe.
#
# Pre-requisites verified by the script:
#   - kubectl reachable
#   - Cluster API server responding
#   - kubectl --dry-run=server works (RBAC sufficient)
#
# Post-conditions:
#   - calico-system namespace exists
#   - tigera-operator Deployment Available
#   - calico-node DaemonSet rolled out on every node
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
TIGERA_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
CUSTOM_RESOURCE="$(dirname "$0")/calico-custom.yaml"

err()  { printf "\e[31m[err]\e[0m  %s\n" "$*" >&2; exit 1; }
log()  { printf "\e[34m[step]\e[0m %s\n" "$*"; }
ok()   { printf "\e[32m[ok]\e[0m   %s\n" "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || err "missing required tool: $1"; }

require kubectl
require curl

[[ -f "$CUSTOM_RESOURCE" ]] || err "missing $CUSTOM_RESOURCE"

log "checking kubectl context"
ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$ctx" ]] || err "no kubectl context — set KUBECONFIG and try again"
ok "context: $ctx"

log "checking API server reachability"
kubectl get --raw=/healthz >/dev/null || err "API server unreachable"
ok "API server healthy"

log "applying tigera-operator manifest ($CALICO_VERSION)"
# server-side apply: idempotent, handles CRDs >262KiB safely (kubectl client-side
# apply hits the annotation size limit on large CRDs). Replaces the older
# `create || replace --force` pattern, which was destructive on re-runs
# (delete entire namespace + CRDs → orphan stuck Terminating ns).
kubectl apply --server-side=true --force-conflicts -f "$TIGERA_OPERATOR_URL"
ok "tigera-operator manifest applied"

log "waiting for tigera-operator Deployment to become Available (≤2m)"
kubectl -n tigera-operator wait deploy/tigera-operator \
    --for=condition=Available --timeout=120s

log "applying Calico Installation custom resource"
kubectl apply -f "$CUSTOM_RESOURCE"
ok "Installation resource applied"

log "waiting for calico-system namespace (operator creates it ≤1m)"
for _ in $(seq 1 60); do
    if kubectl get ns calico-system >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
kubectl get ns calico-system >/dev/null 2>&1 || err "calico-system not created within 60s"

log "waiting for calico-node DaemonSet rollout (≤5m)"
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s

log "summary"
kubectl -n calico-system get pods -o wide
echo
kubectl get nodes -o wide

ok "Calico ${CALICO_VERSION} installed."
