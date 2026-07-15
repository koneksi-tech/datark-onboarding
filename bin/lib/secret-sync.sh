#!/usr/bin/env bash
# Materialize the per-tenant K8s Secret from Vault. Sourced.
# Secret name = <id>-secret ; consumed via envFrom by the chart workloads.

secret_sync() {
  local id="$1" ns rid sid
  ns="$(ns_for "$id")"
  read -r rid sid < <(vault_approle_creds "$id")

  local cluster_secret bearer mongo_pass redis_pass pg_pass app_key jwt mongo_uri admin_email admin_pass
  cluster_secret="$(vault_kv_field "$id" kripfs_cluster_secret)"
  bearer="$(vault_kv_field "$id" kripfs_static_bearer)"
  mongo_pass="$(vault_kv_field "$id" mongo_pass)"
  redis_pass="$(vault_kv_field "$id" redis_pass)"
  pg_pass="$(vault_kv_field "$id" postgres_pass)"
  app_key="$(vault_kv_field "$id" app_key)"
  jwt="$(vault_kv_field "$id" jwt_secret)"
  # tenant admin creds — surfaced in the console UI (backend ignores these keys)
  admin_email="$(vault_kv_field "$id" admin_email 2>/dev/null || true)"
  admin_pass="$(vault_kv_field "$id" admin_password 2>/dev/null || true)"

  # backend connection string -> in-namespace mongo (root/authSource=admin)
  mongo_uri="mongodb://root:${mongo_pass}@${id}-mongo.${ns}.svc.cluster.local:27017/koneksi?authSource=admin"

  # Build the Secret. Keys match what the chart + backend expect.
  # backend<->kripfs contract: the backend sends IPFS_AUTHORIZATION *verbatim* as the
  # Authorization header, and kripfs does `strip_prefix("Bearer ")` before comparing to
  # its koneksi_static_bearer. So IPFS_AUTHORIZATION MUST carry the "Bearer " prefix,
  # while KIPFS_STATIC_BEARER (kripfs config + kripfs-db) stays the raw token.
  kc create secret generic "${id}-secret" -n "$ns" \
    --from-literal=KIPFS_CLUSTER_SECRET="$cluster_secret" \
    --from-literal=KIPFS_STATIC_BEARER="$bearer" \
    --from-literal=IPFS_AUTHORIZATION="Bearer $bearer" \
    --from-literal=MONGO_PASSWORD="$mongo_pass" \
    --from-literal=MONGO_CONNECTION_STRING="$mongo_uri" \
    --from-literal=REDIS_PASSWORD="$redis_pass" \
    --from-literal=POSTGRES_PASSWORD="$pg_pass" \
    --from-literal=APP_KEY="$app_key" \
    --from-literal=JWT_SECRET="$jwt" \
    --from-literal=VAULT_ROLE_ID="$rid" \
    --from-literal=VAULT_SECRET_ID="$sid" \
    --from-literal=ADMIN_EMAIL="$admin_email" \
    --from-literal=ADMIN_PASSWORD="$admin_pass" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  # Merge ALL shared platform secrets (spaces/portone/postmark/provenance) if present.
  # Dynamic: syncs whatever keys exist under secret/datark/shared — no hardcoded list.
  if vault kv get "${VAULT_KV_MOUNT}/datark/shared" >/dev/null 2>&1; then
    local shared_json k v n=0
    shared_json="$(vault kv get -format=json "${VAULT_KV_MOUNT}/datark/shared")"
    for k in $(echo "$shared_json" | jq -r '.data.data | keys[]'); do
      v="$(echo "$shared_json" | jq -r --arg k "$k" '.data.data[$k]')"
      [[ -n "$v" && "$v" != "null" ]] && kc patch secret "${id}-secret" -n "$ns" --type=merge \
        -p "$(jq -n --arg k "$k" --arg v "$v" '{stringData:{($k):$v}}')" >/dev/null 2>&1 && n=$((n+1)) || true
    done
    ok "shared platform secrets merged ($n keys) into ${id}-secret"
  fi
  ok "k8s secret ${id}-secret synced from vault into $ns"
}
