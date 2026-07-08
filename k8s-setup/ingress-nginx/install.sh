#!/usr/bin/env bash
# Install/upgrade ingress-nginx on the datark-cluster (NHN NKS).
# Creates the ingress-nginx namespace and a default "nginx" IngressClass.
# SAFETY: pins the kube-context to datark so it never touches prod koneksi.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# datark-cluster context (override with DATARK_CONTEXT if it changes)
: "${DATARK_CONTEXT:=nks_datark-cluster_5ee750d9-5cbc-461e-a072-b9950527a71c}"

echo "[ingress-nginx] target context: $DATARK_CONTEXT"
kubectl --context "$DATARK_CONTEXT" cluster-info >/dev/null || { echo "context not reachable"; exit 1; }

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --kube-context "$DATARK_CONTEXT" \
  --namespace ingress-nginx --create-namespace \
  -f "$DIR/values.yaml" \
  --wait --timeout 10m

echo "[ingress-nginx] installed. LoadBalancer address:"
kubectl --context "$DATARK_CONTEXT" -n ingress-nginx get svc ingress-nginx-controller \
  -o wide
