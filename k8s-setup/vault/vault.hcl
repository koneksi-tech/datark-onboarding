# /etc/vault.d/vault.hcl on the datark Vault node (125.6.39.130).
# Single-node Raft. Add peers later with `vault operator raft join`.
ui = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "datark-vault-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1          # HARDENING TODO: enable TLS or front with nginx+cert
}

api_addr     = "http://125.6.39.130:8200"
cluster_addr = "http://125.6.39.130:8201"
