#!/usr/bin/env bash
# Materialize the per-tenant K8s Secret from Vault. Sourced.
# Secret name = <id>-secret ; consumed via envFrom by the chart workloads.

secret_sync() {
  local id="$1" ns rid sid
  ns="$(ns_for "$id")"
  read -r rid sid < <(vault_approle_creds "$id")

  local cluster_secret bearer mongo_pass redis_pass pg_pass app_key jwt mongo_uri
  cluster_secret="$(vault_kv_field "$id" kripfs_cluster_secret)"
  bearer="$(vault_kv_field "$id" kripfs_static_bearer)"
  mongo_pass="$(vault_kv_field "$id" mongo_pass)"
  redis_pass="$(vault_kv_field "$id" redis_pass)"
  pg_pass="$(vault_kv_field "$id" postgres_pass)"
  app_key="$(vault_kv_field "$id" app_key)"
  jwt="$(vault_kv_field "$id" jwt_secret)"

  # backend connection string -> in-namespace mongo (root/authSource=admin)
  mongo_uri="mongodb://root:${mongo_pass}@${id}-mongo.${ns}.svc.cluster.local:27017/koneksi?authSource=admin"

  # Build the Secret. Keys match what the chart + backend expect.
  #   IPFS_AUTHORIZATION == KIPFS_STATIC_BEARER  (the backend<->kripfs contract)
  kc create secret generic "${id}-secret" -n "$ns" \
    --from-literal=KIPFS_CLUSTER_SECRET="$cluster_secret" \
    --from-literal=KIPFS_STATIC_BEARER="$bearer" \
    --from-literal=IPFS_AUTHORIZATION="$bearer" \
    --from-literal=MONGO_PASSWORD="$mongo_pass" \
    --from-literal=MONGO_CONNECTION_STRING="$mongo_uri" \
    --from-literal=REDIS_PASSWORD="$redis_pass" \
    --from-literal=POSTGRES_PASSWORD="$pg_pass" \
    --from-literal=APP_KEY="$app_key" \
    --from-literal=JWT_SECRET="$jwt" \
    --from-literal=VAULT_ROLE_ID="$rid" \
    --from-literal=VAULT_SECRET_ID="$sid" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  # Merge shared platform secrets if present (spaces/portone/postmark/provenance).
  if vault kv get "${VAULT_KV_MOUNT}/datark/shared" >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    vault kv get -format=json "${VAULT_KV_MOUNT}/datark/shared" \
      | sed -n 's/.*"data": {\(.*\)}.*/\1/p' >/dev/null 2>&1 || true
    # patch each shared key onto the secret
    for k in SPACES_KEY SPACES_SECRET SPACES_REGION SPACES_BUCKET SPACES_ENDPOINT \
             PORTONE_SECRET_KEY PORTONE_WEBHOOK_SECRET \
             PORTONE_INICIS_MONTHLY_CHANNEL_KEY PORTONE_INICIS_YEARLY_CHANNEL_KEY PORTONE_PAYPAL_CHANNEL_KEY \
             POSTMARK_API_KEY PROVENANCE_SERVICE_TOKEN; do
      v="$(vault kv get -field="$k" "${VAULT_KV_MOUNT}/datark/shared" 2>/dev/null || true)"
      [[ -n "$v" ]] && kc patch secret "${id}-secret" -n "$ns" --type=merge \
        -p "{\"stringData\":{\"$k\":\"$v\"}}" >/dev/null 2>&1 || true
    done
    rm -f "$tmp"
  fi
  ok "k8s secret ${id}-secret synced from vault into $ns"
}
