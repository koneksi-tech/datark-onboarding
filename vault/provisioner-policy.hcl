# Vault policy for the DATARK PROVISIONER token/AppRole used by the scripts.
# Attach to the token you put in .env as VAULT_TOKEN.
# Scope: manage per-tenant KV, transit keys, policies, and AppRoles under datark/*.

# KV v2 — per-tenant + shared secret data + metadata
path "secret/data/datark/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/datark/*" { capabilities = ["create", "read", "update", "delete", "list"] }

# Transit — create/manage per-tenant keys
path "transit/keys/datark-*"    { capabilities = ["create", "read", "update", "delete"] }
path "transit/keys"             { capabilities = ["list"] }

# Policies — manage per-tenant tenant policies
path "sys/policies/acl/datark-tenant-*" { capabilities = ["create", "read", "update", "delete"] }

# AppRole — manage per-tenant roles + mint role-id/secret-id
path "auth/approle/role/datark-*"           { capabilities = ["create", "read", "update", "delete"] }
path "auth/approle/role/datark-*/role-id"   { capabilities = ["read"] }
path "auth/approle/role/datark-*/secret-id" { capabilities = ["create", "update"] }

# Enable engines on a fresh Vault (optional; can be pre-done by an operator)
path "sys/mounts/secret"   { capabilities = ["create", "read", "update"] }
path "sys/mounts/transit"  { capabilities = ["create", "read", "update"] }
path "sys/auth/approle"    { capabilities = ["create", "read", "update"] }
path "sys/mounts"          { capabilities = ["read"] }
path "sys/auth"            { capabilities = ["read"] }
