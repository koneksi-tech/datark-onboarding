#!/usr/bin/env bash
# Environment pre-flight checks. Sourced. Fails fast on missing prerequisites.

preflight() {
  log "pre-flight checks"
  for bin in kubectl helm vault openssl; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH"
  done

  # kube reachable + admin-ish
  kc auth can-i create namespace >/dev/null 2>&1 \
    || die "cannot reach cluster or lack permission to create namespaces (check KUBE_CONTEXT / kubeconfig)"
  ok "kubernetes reachable"

  # default StorageClass present (hard blocker for stateful pods)
  if ! kc get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -q true; then
    warn "no default StorageClass detected — kripfs/mongo/postgres PVCs will not bind unless you set storageClassName"
  else
    ok "default StorageClass present"
  fi

  # ingress-nginx present
  kc get ns ingress-nginx >/dev/null 2>&1 && ok "ingress-nginx namespace present" \
    || warn "ingress-nginx namespace not found — per-tenant Ingress may not route"

  # vault reachable
  [[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is empty — set it in .env (this env's Vault, not prod)"
  [[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN (provisioner) is empty — set it in .env"
  vault status >/dev/null 2>&1 || die "cannot reach Vault at $VAULT_ADDR (or it is sealed)"
  ok "vault reachable at $VAULT_ADDR"
}
