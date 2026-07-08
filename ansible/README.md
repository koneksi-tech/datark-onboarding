# DatArk PoC — Ansible

All server setup/configuration for the DatArk KIPFS PoC. **Every change to the servers goes
through here** — edit a template/var and re-run; don't SSH-and-edit by hand.

## What it manages
- **KIPFS storage nodes** (kipfs-1/2/3): ships the `kipfs` binary, inits the repo, templates
  `config.json` (cluster peers auto-derived from inventory), installs a systemd unit, starts it,
  and fronts it with **nginx HTTPS** (`poc-kipfs-cluster-{1,2,3}.koneksi.co.kr`).
- **Gateway / load balancer** (datark-gateway): nginx LB over the 3 nodes with health-check
  failover (`poc-kipfs-cluster.koneksi.co.kr`).
- **Agent host**: base only (the DatArk Agent is Dev-owned — add a role when ready).

## Prerequisites (control machine)
```bash
brew install ansible           # or pipx install ansible
```
- SSH key at `~/Documents/poc-nhn-key.pem` (path set in inventory).
- TLS cert at `../../certs/{fullchain.pem,private.key}` (relative to this dir).
- Prebuilt binary at `files/kipfs` (already included; see "Rebuild binary" to refresh).
- Secrets in `group_vars/vault.yml` (copy from `vault.example.yml`; **git-ignored**).

## Run it
```bash
cd ansible
ansible-playbook site.yml --check      # dry-run (shows what would change)
ansible-playbook site.yml              # apply everything

# scoped runs:
ansible-playbook site.yml --tags kipfs           # only the daemon + config
ansible-playbook site.yml --tags nginx,lb        # only the web tier
ansible-playbook site.yml --limit datark-kipfs-2 # one host
ansible -i inventory/hosts.ini kipfs_nodes -m ping   # connectivity test
```
It's **idempotent** — a second run reports no changes. Config/cert/unit changes trigger the
right reload/restart via handlers.

## Make a change (the workflow your team lead wants)
| To change… | Edit… | Then |
|------------|-------|------|
| Cluster ports / replication | `group_vars/all.yml` | `ansible-playbook site.yml --tags kipfs` |
| A daemon config field | `roles/kipfs_node/templates/config.json.j2` | `--tags kipfs` (restarts kipfs) |
| Add/remove a node | `inventory/hosts.ini` (peers auto-update) | `ansible-playbook site.yml` |
| LB rules / health checks | `roles/kipfs_lb/templates/kipfs-lb.conf.j2` | `--tags lb` |
| Node nginx | `roles/kipfs_nginx/templates/kipfs-node.conf.j2` | `--tags nginx` |
| Secrets | `group_vars/vault.yml` | `--tags kipfs` |

## Secrets (ansible-vault)
```bash
cp group_vars/vault.example.yml group_vars/vault.yml   # fill values (from poc-secrets.local.md)
ansible-vault encrypt group_vars/vault.yml             # encrypt
ansible-playbook site.yml --ask-vault-pass             # run with the vault password
```

## Rebuild the binary (fresh from source)
```bash
# on an Ubuntu 22.04 builder (matches glibc 2.35):
cd kripfs && git checkout nhn-main
cargo build --release --bin kipfs
cp target/release/kipfs <this-dir>/files/kipfs
ansible-playbook site.yml --tags kipfs   # ships + restarts
```

## Layout
```
ansible.cfg
inventory/hosts.ini
group_vars/{all.yml, vault.yml (secrets, git-ignored), vault.example.yml}
files/kipfs                          # prebuilt binary
site.yml                             # main playbook
roles/
  common/                            # apt update + base pkgs
  kipfs_node/  (config.json.j2, kipfs.service.j2)
  kipfs_nginx/ (per-node HTTPS vhost)
  kipfs_lb/    (LB vhost with health checks)
```
