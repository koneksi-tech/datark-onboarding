#!/usr/bin/env bash
# Tests for the shared ingress-nginx settings (NGINX2Root interim fix):
#   1. the chart version is pinned in install.sh
#   2. the rendered controller ConfigMap has use-http2: "false"
# Needs helm and the ingress-nginx chart repo. Run: bash k8s-setup/ingress-nginx/test.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }

# rendered manifests -> 0 if the controller ConfigMap sets use-http2 "false"
http2_off() { awk '/^kind: ConfigMap/{cm=1} /^---/{cm=0} cm && /use-http2:/{print}' "$1" | grep -q 'use-http2: "false"'; }

grep -qE -- '--version "\$INGRESS_NGINX_CHART_VERSION"' "$DIR/install.sh" && grep -qE 'INGRESS_NGINX_CHART_VERSION:=[0-9]+\.[0-9]+\.[0-9]+' "$DIR/install.sh" \
  && ok "install.sh pins the chart version" || bad "install.sh does not pin the chart version"
ver="$(sed -n -E 's/.*INGRESS_NGINX_CHART_VERSION:=([0-9.]+).*/\1/p' "$DIR/install.sh")"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null 2>&1 || true
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
helm template ingress-nginx ingress-nginx/ingress-nginx --version "$ver" -n ingress-nginx -f "$DIR/values.yaml" >"$t/on.yaml" \
  || { bad "helm template failed"; exit 1; }
http2_off "$t/on.yaml" && ok "rendered ConfigMap: use-http2 \"false\" (chart $ver)" || bad "rendered ConfigMap lacks use-http2 \"false\""
# negative: the check must catch a values file that turns HTTP/2 back on
helm template ingress-nginx ingress-nginx/ingress-nginx --version "$ver" -n ingress-nginx -f "$DIR/values.yaml" \
  --set-string controller.config.use-http2=true >"$t/off.yaml"
http2_off "$t/off.yaml" && bad "check missed use-http2=true" || ok "check flags use-http2=true"
exit $fail
