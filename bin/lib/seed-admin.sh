#!/usr/bin/env bash
# =============================================================================
# seed-admin.sh — create the per-tenant system_admin the developer uses to
# approve end-users. Sourced by datark-provision.sh.
#
# The backend gates new signups behind admin approval + email verification, and
# it seeds roles but NO admin user. So each tenant needs one bootstrapped admin:
#   1) register it through the backend API (so the backend does the Vault-transit
#      PII encryption + profile/root-dir creation correctly),
#   2) promote it in MongoDB: approve + verify, and point its user_role at the
#      system_admin role.
# Credentials are generate-once in the tenant's Vault KV (admin_email/admin_password).
#
# Idempotent and NON-FATAL: a seed hiccup must never roll back an otherwise-good
# tenant — callers invoke it as `seed_admin "$TENANT" || true`.
# =============================================================================

seed_admin() {
  local id="$1" ns url email pass code i mpass
  ns="$(ns_for "$id")"
  url="https://${id}.${DOMAIN}"
  email="$(vault_kv_field "$id" admin_email 2>/dev/null || true)"
  pass="$(vault_kv_field "$id" admin_password 2>/dev/null || true)"
  [[ -n "$email" && -n "$pass" ]] || { warn "admin creds not in vault — skipping admin seed"; return 0; }

  # backend must be Ready first (its initContainer waits for the datastores, so
  # this can take a couple of minutes on a fresh provision).
  log "seeding tenant admin ($email) — waiting for backend to be ready"
  if ! kc -n "$ns" rollout status deploy/"${id}-backend" --timeout=300s >/dev/null 2>&1; then
    warn "backend not ready in time — admin NOT seeded; re-run provisioning to seed it"
    return 0
  fi

  # 1) register through the public endpoint (retry: ingress/routes may lag briefly).
  #    201 = created, 4xx = already exists / validation → stop retrying and continue.
  code=000
  for i in $(seq 1 24); do
    code="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' -X POST "$url/users/register" \
      -H 'Content-Type: application/json' \
      -d "{\"first_name\":\"Tenant\",\"last_name\":\"Admin\",\"email\":\"${email}\",\"password\":\"${pass}\",\"confirm_password\":\"${pass}\"}" 2>/dev/null || echo 000)"
    case "$code" in 201|200|400|409|422) break;; esac
    sleep 5
  done
  log "  admin register HTTP $code"

  # 2) promote in Mongo (idempotent). approve + verify + assign system_admin role.
  mpass="$(kc -n "$ns" get secret "${id}-secret" -o jsonpath='{.data.MONGO_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$mpass" ]]; then
    kc -n "$ns" exec "${id}-mongo-0" -- mongosh --quiet -u root -p "$mpass" \
      --authenticationDatabase admin koneksi --eval "
        var u = db.users.findOne({email: '${email}'});
        if (u) {
          db.users.updateOne({_id: u._id}, {\$set: {approval_status:'approved', is_verified:true, is_locked:false, can_retrieve:true, can_delete:true}});
          var ar = db.roles.findOne({name: 'system_admin'});
          if (ar) db.user_role.updateOne({user_id: u._id}, {\$set: {role_id: ar._id, updated_at: new Date()}});
          print('promoted');
        } else { print('user-not-found'); }
      " >/dev/null 2>&1 || warn "admin promotion step failed (backend may still be migrating) — re-run provisioning"
  fi
  ok "tenant admin ready: ${email} (password in vault: $(vault_tenant_path "$id") key admin_password)"
}
