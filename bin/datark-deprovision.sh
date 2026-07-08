#!/usr/bin/env bash
# =============================================================================
# datark-deprovision.sh — tear down a DatArk tenant (K8s + Vault).
#
#   ./datark-deprovision.sh --tenant <id> [--force] [--delete-transit]
#
# Deletes the namespace (pods, PVCs, secrets, ingress) and revokes the tenant's
# Vault AppRole/policy/KV. Transit key is KEPT unless --delete-transit.
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
source "$DIR/lib/validate.sh"
source "$DIR/lib/vault.sh"

TENANT=""; FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) TENANT="$2"; shift 2;;
    --force) FORCE=true; shift;;
    --delete-transit) export DELETE_TRANSIT=true; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done
[[ -n "$TENANT" ]] || die "--tenant is required"
validate_tenant_id "$TENANT"

NS="$(ns_for "$TENANT")"
REL="$(rel_for "$TENANT")"

if ! $FORCE; then
  read -r -p "Delete tenant '$TENANT' (namespace $NS + Vault objects)? Type the tenant id to confirm: " ans
  [[ "$ans" == "$TENANT" ]] || die "confirmation mismatch — aborted"
fi

log "deprovisioning tenant '$TENANT'"

# 1) K8s teardown
helmc -n "$NS" uninstall "$REL" >/dev/null 2>&1 || warn "helm release $REL not found"
kc delete ns "$NS" --ignore-not-found >/dev/null 2>&1 && ok "namespace $NS deleted" || warn "namespace $NS already gone"

# 2) Vault revoke
[[ -n "$VAULT_ADDR" && -n "$VAULT_TOKEN" ]] && vault_revoke_tenant "$TENANT" \
  || warn "VAULT_ADDR/TOKEN not set — skipped Vault revoke (do it manually)"

ok "TENANT DEPROVISIONED: $TENANT"
