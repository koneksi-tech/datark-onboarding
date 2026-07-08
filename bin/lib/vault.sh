#!/usr/bin/env bash
# Per-tenant Vault provisioning (idempotent). Sourced.
# Creates: KV secrets (generate-once), transit key, policy, AppRole.

vault_tenant_path() { echo "${VAULT_KV_MOUNT}/datark/tenants/$1"; }
vault_transit_key() { echo "datark-$1"; }
vault_policy_name() { echo "datark-tenant-$1"; }
vault_approle_name(){ echo "datark-$1"; }

# Ensure engines exist (safe to call repeatedly).
vault_ensure_engines() {
  vault secrets list -format=json 2>/dev/null | grep -q "\"${VAULT_KV_MOUNT}/\"" \
    || vault secrets enable -path="${VAULT_KV_MOUNT}" kv-v2 >/dev/null 2>&1 || true
  vault secrets list -format=json 2>/dev/null | grep -q "\"${VAULT_TRANSIT_MOUNT}/\"" \
    || vault secrets enable -path="${VAULT_TRANSIT_MOUNT}" transit >/dev/null 2>&1 || true
  vault auth list -format=json 2>/dev/null | grep -q '"approle/"' \
    || vault auth enable approle >/dev/null 2>&1 || true
}

# Generate-once secrets: reuse existing KV values, only fill missing keys.
vault_provision_tenant() {
  local id="$1" kvpath tk
  kvpath="$(vault_tenant_path "$id")"
  tk="$(vault_transit_key "$id")"

  # transit key (idempotent)
  vault read "transit/keys/$tk" >/dev/null 2>&1 || vault write -f "transit/keys/$tk" >/dev/null
  ok "transit key $tk ready"

  # KV secrets — read existing, generate any that are missing
  local existing cluster_secret bearer mongo_pass redis_pass pg_pass app_key jwt
  existing="$(vault kv get -format=json "$kvpath" 2>/dev/null || echo '{}')"
  _get() { echo "$existing" | (grep -o "\"$1\"[^,]*" || true) | sed -E 's/.*: *"?([^"]*)"?/\1/' | head -1; }

  cluster_secret="$(_get kripfs_cluster_secret)"; [[ -n "$cluster_secret" ]] || cluster_secret="$(gen_secret)"
  bearer="$(_get kripfs_static_bearer)";          [[ -n "$bearer" ]] || bearer="$(gen_secret)"
  mongo_pass="$(_get mongo_pass)";                 [[ -n "$mongo_pass" ]] || mongo_pass="$(gen_secret)"
  redis_pass="$(_get redis_pass)";                 [[ -n "$redis_pass" ]] || redis_pass="$(gen_secret)"
  pg_pass="$(_get postgres_pass)";                 [[ -n "$pg_pass" ]] || pg_pass="$(gen_secret)"
  app_key="$(_get app_key)";                       [[ -n "$app_key" ]] || app_key="$(gen_secret)"
  jwt="$(_get jwt_secret)";                         [[ -n "$jwt" ]] || jwt="$(gen_secret)"

  vault kv put "$kvpath" \
    kripfs_cluster_secret="$cluster_secret" \
    kripfs_static_bearer="$bearer" \
    mongo_pass="$mongo_pass" \
    redis_pass="$redis_pass" \
    postgres_pass="$pg_pass" \
    app_key="$app_key" \
    jwt_secret="$jwt" >/dev/null
  ok "kv secrets written to $kvpath (existing values preserved)"

  # policy: read own KV + encrypt/decrypt on own transit key only
  vault policy write "$(vault_policy_name "$id")" - >/dev/null <<EOF
path "${kvpath}"        { capabilities = ["read"] }
path "${VAULT_KV_MOUNT}/data/datark/tenants/${id}" { capabilities = ["read"] }
path "${VAULT_KV_MOUNT}/data/datark/shared"        { capabilities = ["read"] }
path "${VAULT_TRANSIT_MOUNT}/encrypt/${tk}" { capabilities = ["update"] }
path "${VAULT_TRANSIT_MOUNT}/decrypt/${tk}" { capabilities = ["update"] }
EOF
  ok "policy $(vault_policy_name "$id") written"

  # AppRole bound to the policy
  vault write "auth/approle/role/$(vault_approle_name "$id")" \
    token_policies="$(vault_policy_name "$id")" \
    token_ttl=1h token_max_ttl=4h secret_id_ttl=0 >/dev/null
  ok "approle $(vault_approle_name "$id") ready"
}

# Echo "role_id secret_id" for the tenant AppRole (fresh secret_id each run).
vault_approle_creds() {
  local id="$1" rid sid
  rid="$(vault read -field=role_id "auth/approle/role/$(vault_approle_name "$id")/role-id")"
  sid="$(vault write -f -field=secret_id "auth/approle/role/$(vault_approle_name "$id")/secret-id")"
  echo "$rid $sid"
}

# Read a KV field for the tenant.
vault_kv_field() { vault kv get -field="$2" "$(vault_tenant_path "$1")"; }

# Teardown all tenant Vault objects.
vault_revoke_tenant() {
  local id="$1"
  vault delete "auth/approle/role/$(vault_approle_name "$id")" >/dev/null 2>&1 || true
  vault policy delete "$(vault_policy_name "$id")" >/dev/null 2>&1 || true
  vault kv metadata delete "$(vault_tenant_path "$id")" >/dev/null 2>&1 || true
  ok "vault approle/policy/kv removed for $id"
  if [[ "${DELETE_TRANSIT:-false}" == "true" ]]; then
    vault delete "transit/keys/$(vault_transit_key "$id")" >/dev/null 2>&1 || true
    warn "transit key $(vault_transit_key "$id") deleted — retained ciphertext is now undecryptable"
  else
    warn "transit key $(vault_transit_key "$id") KEPT (set DELETE_TRANSIT=true to crypto-shred)"
  fi
}
