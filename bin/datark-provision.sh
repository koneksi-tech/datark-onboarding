#!/usr/bin/env bash
# =============================================================================
# datark-provision.sh — provision one isolated DatArk tenant onto the shared
# Kubernetes cluster, with secrets sourced from this environment's Vault.
#
#   ./datark-provision.sh --tenant <id> --tier <starter|pro|enterprise>
#
# Requires (fed via .env or environment): VAULT_ADDR, VAULT_TOKEN, kube access.
# Idempotent: safe to re-run (upgrade). Rolls back a failed FRESH create.
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
source "$DIR/lib/validate.sh"
source "$DIR/lib/preflight.sh"
source "$DIR/lib/vault.sh"
source "$DIR/lib/secret-sync.sh"
source "$DIR/lib/tls.sh"
source "$DIR/lib/verify.sh"

TENANT=""; TIER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) TENANT="$2"; shift 2;;
    --tier)   TIER="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done
[[ -n "$TENANT" ]] || die "--tenant is required"
[[ -n "$TIER" ]] || die "--tier is required"

validate_tenant_id "$TENANT"
validate_tier "$TIER"
preflight

NS="$(ns_for "$TENANT")"
REL="$(rel_for "$TENANT")"
FRESH=false
helmc -n "$NS" status "$REL" >/dev/null 2>&1 || FRESH=true
$FRESH && log "provisioning NEW tenant '$TENANT' (tier=$TIER, ns=$NS)" \
        || log "upgrading existing tenant '$TENANT' (tier=$TIER, ns=$NS)"

rollback() {
  warn "provisioning failed — rolling back"
  if $FRESH; then
    helmc -n "$NS" uninstall "$REL" >/dev/null 2>&1 || true
    kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  else
    helmc -n "$NS" rollback "$REL" >/dev/null 2>&1 || true
  fi
  die "rolled back tenant '$TENANT'"
}
trap 'rollback' ERR

# 1) namespace + pull secret
kc get ns "$NS" >/dev/null 2>&1 || kc create ns "$NS" >/dev/null
kc label ns "$NS" datark.koneksi.co.kr/tenant="$TENANT" --overwrite >/dev/null
[[ -f "$REPO_DIR/.ncr-dockerconfig.json" ]] && kc create secret generic "$IMAGE_PULL_SECRET" -n "$NS" \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$REPO_DIR/.ncr-dockerconfig.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null || warn "no .ncr-dockerconfig.json — assuming pull secret exists"

# 2) wildcard TLS secret into the tenant namespace (Ingress needs it namespaced)
ensure_tls_secret "$TENANT"

# 3) Vault: per-tenant objects (generate-once)
vault_ensure_engines
vault_provision_tenant "$TENANT"

# 4) materialize the K8s Secret from Vault
secret_sync "$TENANT"

# 5) deploy the stack
helmc upgrade --install "$REL" "$CHART_DIR" \
  -n "$NS" --create-namespace \
  -f "$TIERS_DIR/$TIER.yaml" \
  --set tenant.id="$TENANT" \
  --set domain="$DOMAIN" \
  --set vault.addr="$VAULT_ADDR" \
  --set imagePullSecret="$IMAGE_PULL_SECRET" \
  --wait --timeout 10m

# 6) verify
verify_tenant "$TENANT"

trap - ERR
echo
ok "TENANT PROVISIONED"
cat <<EOF
{
  "tenant": "$TENANT",
  "tier": "$TIER",
  "namespace": "$NS",
  "url": "https://${TENANT}.${DOMAIN}",
  "vault_kv": "${VAULT_KV_MOUNT}/datark/tenants/${TENANT}",
  "transit_key": "datark-${TENANT}"
}
EOF
