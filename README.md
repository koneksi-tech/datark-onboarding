# DatArk Onboarding — per-tenant provisioning

On-demand provisioning of an isolated **DatArk** stack (kripfs + backend + redis +
mongodb + postgres) onto a shared Kubernetes cluster, one **namespace per tenant**,
with secrets sourced from this environment's **HashiCorp Vault**.

Approach **B** (bash wrapper around a Helm chart). Full design + diagrams:
[`datark-tenant-provisioning.html`](datark-tenant-provisioning.html).

## Layout
```
bin/
  datark-provision.sh      # provision/upgrade a tenant
  datark-deprovision.sh    # tear down a tenant (K8s + Vault)
  lib/                     # common, validate, preflight, vault, secret-sync, verify
chart/datark-tenant/       # the Helm chart (kripfs/backend/redis/mongo/postgres/ingress/policy)
  tiers/                   # starter | pro | enterprise values
vault/provisioner-policy.hcl   # policy for the provisioner token
ansible/                   # (alt model) VM-based DatArk PoC provisioner — see below
.env.example               # fill in when clusters exist
```

> **Two provisioning models live here.** The `chart/` + `bin/` path is the **Kubernetes,
> per-tenant, pod-based** model (the primary design). `ansible/` is the **VM-based** PoC
> provisioner copied from the NHN onboarding work — it installs `kipfs` as a binary +
> nginx on VMs via SSH, a different footprint than the K8s stack. Its plaintext
> `group_vars/all/vault.yml` was intentionally **not** copied (gitignored secrets);
> use `vault.example.yml` as the template.

## What you provide (once, per environment)
1. **A Kubernetes cluster** — kube-admin context. Needs a default StorageClass,
   ingress-nginx, and a wildcard `*.<DOMAIN>` DNS + TLS secret.
2. **A Vault cluster** — with `transit`, `approle`, KV v2 enabled, and a provisioner
   token (policy in `vault/provisioner-policy.hcl`). Put its address + token in `.env`.

> This is a **separate environment** from prod Koneksi. It never references the prod
> `nhn-hash-vault.koneksi.co.kr` Vault.

## Vault setup & automation

### One-time bootstrap (manual, per environment)
Do this **once** against your fresh Vault. Everything after is automated.
```bash
export VAULT_ADDR=https://vault.datark.example
export VAULT_TOKEN=<root-or-admin-token>

# enable engines (skip any already enabled)
vault secrets enable -path=secret kv-v2
vault secrets enable transit
vault auth enable approle

# provisioner policy + token used by the scripts
vault policy write datark-provisioner vault/provisioner-policy.hcl
vault token create -policy=datark-provisioner -period=24h
# -> put the generated token in .env as VAULT_TOKEN
```
Mount paths are overridable in `.env` (`VAULT_KV_MOUNT`, `VAULT_TRANSIT_MOUNT`) if your
Vault uses non-default paths.

### Per-tenant (fully automated by `datark-provision.sh`)
You never touch Vault by hand again. Each provision:
1. creates transit key `datark-<id>` (PII encryption);
2. generate-once KV secrets at `secret/datark/tenants/<id>` (cluster secret, bearer,
   mongo/redis/postgres passwords, app_key, jwt) — existing values are preserved;
3. writes a least-privilege policy + AppRole `datark-<id>`;
4. materializes the K8s Secret `<id>-secret` from Vault.

### How the backend connects to Vault (automated, no manual config)
```
vault.sh  ─ create AppRole datark-<id> ─► role_id + secret_id
secret-sync.sh ─ read them ─► K8s Secret: VAULT_ROLE_ID, VAULT_SECRET_ID
chart backend-config ─► ConfigMap: VAULT_ADDR, VAULT_TRANSIT_KEY=datark-<id>
backend-deploy envFrom (ConfigMap + Secret) ─► pod authenticates to Vault via AppRole
```
The backend authenticates with **AppRole** (matches the existing backend's
`VAULT_ROLE_ID`/`VAULT_SECRET_ID` env). kripfs does **not** connect to Vault directly —
its two secrets are delivered via the K8s Secret. Etcd-free delivery (Vault Agent
Injector / Kubernetes auth) is a later hardening step (design doc O9).

## Usage
```bash
cp .env.example .env    # fill VAULT_ADDR, VAULT_TOKEN, DOMAIN, ...

# provision
./bin/datark-provision.sh --tenant acme --tier pro

# upgrade (e.g. change tier) — same command, idempotent
./bin/datark-provision.sh --tenant acme --tier enterprise

# tear down
./bin/datark-deprovision.sh --tenant acme            # keeps transit key
./bin/datark-deprovision.sh --tenant acme --force --delete-transit
```

## Before it can actually run (open prep items)
- **kripfs image** pushed to NCR (`images.kripfs` in `values.yaml` is a placeholder).
- **backend image** tag pinned (`images.backend`).
- Cluster **StorageClass** confirmed (five stateful PVCs per tenant).
- Wildcard **DNS + TLS** secret (`ingress.tlsSecretName`) present.
- Shared platform secrets (spaces/portone/postmark/provenance) written to
  `secret/datark/shared` if the backend needs them.

## Validate without clusters
```bash
helm template acme chart/datark-tenant \
  -f chart/datark-tenant/tiers/pro.yaml \
  --set tenant.id=acme --set vault.addr=https://vault.example
bash -n bin/*.sh bin/lib/*.sh    # shell syntax check
```
