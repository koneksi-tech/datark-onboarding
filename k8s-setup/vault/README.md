# datark Vault — setup record

Single-node HashiCorp Vault (Raft) for the datark environment. Separate from prod
koneksi Vault. Backs the per-tenant secrets used by `../../bin/datark-provision.sh`.

## Node
| | |
|---|---|
| Host | `125.6.39.130` (NHN, Ubuntu 22.04) |
| SSH | `ssh -i ~/Documents/datark-k8s-key.pem ubuntu@125.6.39.130` |
| Vault version | 2.0.3 |
| API | `http://125.6.39.130:8200` (reachable externally — SG allows 8200) |
| Storage | Raft at `/opt/vault/data`, node_id `datark-vault-1` |
| Config | `/etc/vault.d/vault.hcl` (copy here as `vault.hcl`) |

## What was configured
- Engines: `secret/` (kv-v2), `transit/`, `auth/approle/`.
- Policy `datark-provisioner` (see `../../vault/provisioner-policy.hcl`).
- Provisioner token (768h period) — wired into `../../.env` as `VAULT_TOKEN`.
- **Auto-unseal**: `/root/script/auto-unseal.sh` via root cron every minute
  (reads `/root/vault-init.json`). Survives reboots.

## Where the secrets live (NOT in git)
| File | Location |
|---|---|
| Unseal keys + root token | `~/Documents/datark-vault-init.json` (600) **and** server `/root/vault-init.json` |
| Provisioner token | `~/Documents/datark-vault-provisioner-token.json` (600) |
| `.env` (addr + provisioner token) | `../../.env` (gitignored) |

## Ports (NHN Security Group)
| Port | Purpose | Source |
|---|---|---|
| 8200 | API/UI | K8s node subnet + admin IP |
| 8201 | Raft cluster (when >1 node) | other Vault nodes only |

## Rebuild / bootstrap notes
```bash
# install (apt), then:
sudo cp vault.hcl /etc/vault.d/vault.hcl
sudo systemctl enable --now vault
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -key-shares=5 -key-threshold=3 -format=json | sudo tee /root/vault-init.json
# unseal x3, then enable engines + write provisioner policy + token (see repo history)
```

## Hardening TODO
- **TLS**: listener is `tls_disable=1` (plaintext over public IP). Enable TLS on
  8200 or front with nginx + cert; then set backend `VAULT_TLS_SKIP_VERIFY=false`.
- **Auto-unseal via transit/KMS** instead of keys-on-disk.
- **Expand to 3 nodes** (`vault operator raft join`) for HA — use private IPs for
  `cluster_addr` when you do.
