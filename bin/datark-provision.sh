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
source "$DIR/lib/seed-admin.sh"

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

# -----------------------------------------------------------------------------
# expand_kripfs_pvcs — grow-only online storage expansion for kripfs (UPGRADE).
#
# A StatefulSet's volumeClaimTemplates size is immutable, so `helm upgrade` cannot
# resize it. Instead we grow the underlying Cinder volumes out-of-band (the SC has
# allowVolumeExpansion=true) and let helm recreate the STS at the matching size:
#   1) delete the STS with --cascade=orphan  (pods + PVCs stay bound: no downtime,
#      no data movement)
#   2) patch each kripfs PVC to the new size (Cinder expands the block device +
#      filesystem online)
#   3) return — the caller's `helm upgrade` recreates the STS with the larger
#      volumeClaimTemplate, adopts the orphaned pods, and scales up new ones.
# Shrink is refused (Cinder can't shrink) — that is why downgrade is unsupported.
expand_kripfs_pvcs() {
  local kn desired_raw desired_gi pvc cur need=false
  kn="${TENANT}-kripfs"
  # authoritative desired size = kripfs.storage from the tier file
  desired_raw="$(awk '/^kripfs:/{f=1;next} /^[^[:space:]#]/{f=0} f&&$1=="storage:"{gsub(/"/,"",$2);print $2;exit}' "$TIERS_DIR/$TIER.yaml")"
  [[ -n "$desired_raw" ]] || return 0
  desired_gi="${desired_raw%Gi}"
  local pvcs=()
  while IFS= read -r p; do [[ -n "$p" ]] && pvcs+=("$p"); done \
    < <(kc -n "$NS" get pvc -o name 2>/dev/null | grep -E "/data-${kn}-[0-9]+$" || true)
  [[ ${#pvcs[@]} -gt 0 ]] || { log "no existing kripfs PVCs — nothing to expand"; return 0; }
  for pvc in "${pvcs[@]}"; do
    cur="$(kc -n "$NS" get "$pvc" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)"
    cur="${cur%Gi}"
    [[ -n "$cur" ]] || continue
    if (( desired_gi < cur )); then
      die "cannot shrink kripfs $pvc (${cur}Gi -> ${desired_gi}Gi). Downgrade is not supported."
    fi
    (( desired_gi > cur )) && need=true
  done
  $need || { log "kripfs storage already ${desired_gi}Gi — no expansion needed"; return 0; }
  log "growing kripfs storage to ${desired_gi}Gi (online, data-safe): orphan STS + patch ${#pvcs[@]} PVC(s)"
  # Raise the storage quota FIRST — the PVC patch below counts against requests.storage,
  # and helm only reconciles the quota later (step 5). Without this the patch is rejected
  # by the still-lower current-tier quota. Set it to the target tier's quota value.
  local q_storage
  q_storage="$(awk '/^quota:/{f=1;next} /^[^[:space:]#]/{f=0} f&&$1=="storage:"{gsub(/"/,"",$2);print $2;exit}' "$TIERS_DIR/$TIER.yaml")"
  if [[ -n "$q_storage" ]]; then
    kc -n "$NS" patch resourcequota "${TENANT}-quota" --type merge \
      -p "{\"spec\":{\"hard\":{\"requests.storage\":\"${q_storage}\"}}}" >/dev/null 2>&1 \
      && log "  raised storage quota -> ${q_storage}"
  fi
  kc -n "$NS" delete statefulset "$kn" --cascade=orphan >/dev/null 2>&1 || true
  for pvc in "${pvcs[@]}"; do
    kc -n "$NS" patch "$pvc" --type merge \
      -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${desired_gi}Gi\"}}}}" >/dev/null
    log "  patched $pvc -> ${desired_gi}Gi"
  done
}

# -----------------------------------------------------------------------------
# assert_tenant_contract — verify the two things that must be true for a tenant
# to actually register users + upload to kripfs. Regressions here are silent
# (pods stay green; failures only surface at runtime), so we check at provision.
#   1) Vault policy grants transit/datakey/plaintext/<key> — the backend uses
#      envelope encryption; without it profile PII encryption 403s -> register fails.
#   2) K8s secret IPFS_AUTHORIZATION carries the "Bearer " prefix — the backend
#      sends it verbatim and kripfs strip_prefix("Bearer ")es before comparing.
assert_tenant_contract() {
  local id="$1" tk pol ipfsauth
  tk="$(vault_transit_key "$id")"
  pol="$(vault policy read "$(vault_policy_name "$id")" 2>/dev/null || true)"
  echo "$pol" | grep -q "${VAULT_TRANSIT_MOUNT}/datakey/plaintext/${tk}" \
    || die "contract check failed: vault policy '$(vault_policy_name "$id")' lacks datakey/plaintext on ${tk} (registration would 403)"
  ipfsauth="$(kc -n "$NS" get secret "${id}-secret" -o jsonpath='{.data.IPFS_AUTHORIZATION}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ "$ipfsauth" == Bearer\ * ]] \
    || die "contract check failed: secret ${id}-secret IPFS_AUTHORIZATION missing 'Bearer ' prefix (kripfs upload would 401)"
  ok "tenant contract verified (vault datakey + IPFS_AUTHORIZATION Bearer prefix)"
}

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
kc label ns "$NS" datark.koneksi.co.kr/tenant="$TENANT" datark.koneksi.co.kr/tier="$TIER" --overwrite >/dev/null
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

# 4a) contract guardrails — fail loudly on the two bugs that silently broke
# registration + upload (see commit 5d07dd1). Cheap, no running pods needed.
assert_tenant_contract "$TENANT"

# 5) deploy the stack
# KRIPFS_ENABLED=false lets you provision before the kripfs image is built.
# HELM_WAIT=false returns immediately (no --wait/rollback) for observation.
: "${KRIPFS_ENABLED:=true}"; export KRIPFS_ENABLED
: "${HELM_WAIT:=true}"

# 4.5) grow-only kripfs storage (upgrade path only). Fresh installs have no PVCs
# yet, so the volumeClaimTemplate size is applied directly by the install below.
if ! $FRESH && [[ "$KRIPFS_ENABLED" == "true" ]]; then
  expand_kripfs_pvcs
fi

if [[ "$HELM_WAIT" == "true" ]]; then WAIT_ARGS=(--wait --timeout 10m); else WAIT_ARGS=(--wait=false); fi
helmc upgrade --install "$REL" "$CHART_DIR" \
  -n "$NS" --create-namespace \
  -f "$TIERS_DIR/$TIER.yaml" \
  --set tenant.id="$TENANT" \
  --set domain="$DOMAIN" \
  --set vault.addr="$VAULT_ADDR" \
  --set imagePullSecret="$IMAGE_PULL_SECRET" \
  --set kripfs.enabled="$KRIPFS_ENABLED" \
  "${WAIT_ARGS[@]}"

# 6) verify
if [[ "$HELM_WAIT" == "true" ]]; then
  verify_tenant "$TENANT"
else
  warn "HELM_WAIT=false — skipping strict verify. Current pods:"
  kc -n "$NS" get pods 2>/dev/null || true
fi

trap - ERR

# 7) bootstrap the tenant admin the developer uses to approve end-users.
# Non-fatal: a good tenant must not roll back if this hiccups (re-run to retry).
seed_admin "$TENANT" || warn "admin seed skipped — re-run provisioning to seed it"

echo
ok "TENANT PROVISIONED"
# Two DNS A records are required (both -> the ingress-nginx LB IP):
#   <tenant>.<domain>          — backend API
#   <tenant>-cluster.<domain>  — kripfs cluster endpoint (Agent/desktop uploads)
LB_IP="$(kc -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
warn "DNS: add A records -> ${LB_IP:-<ingress-nginx LB IP>}"
echo "       ${TENANT}.${DOMAIN}"
echo "       ${TENANT}-cluster.${DOMAIN}   (kripfs cluster endpoint — required for Agent/desktop upload)"
cat <<EOF
{
  "tenant": "$TENANT",
  "tier": "$TIER",
  "namespace": "$NS",
  "url": "https://${TENANT}.${DOMAIN}",
  "cluster_endpoint": "https://${TENANT}-cluster.${DOMAIN}",
  "dns_a_records": ["${TENANT}.${DOMAIN}", "${TENANT}-cluster.${DOMAIN}"],
  "dns_target_lb": "${LB_IP:-<ingress-nginx LB IP>}",
  "admin_email": "$(vault_kv_field "$TENANT" admin_email 2>/dev/null || true)",
  "admin_password_ref": "${VAULT_KV_MOUNT}/datark/tenants/${TENANT} (key: admin_password)",
  "vault_kv": "${VAULT_KV_MOUNT}/datark/tenants/${TENANT}",
  "transit_key": "datark-${TENANT}"
}
EOF
