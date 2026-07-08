#!/usr/bin/env bash
# Shared helpers, config, logging. Sourced by every script.
set -euo pipefail

# --- paths ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/../.." && pwd)"
CHART_DIR="$REPO_DIR/chart/datark-tenant"
TIERS_DIR="$CHART_DIR/tiers"

# --- load .env if present (VAULT_ADDR, VAULT_TOKEN, DOMAIN, ...) ---
if [[ -f "$REPO_DIR/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$REPO_DIR/.env"; set +a
fi

# --- config (env-overridable; fed later when clusters exist) ---
: "${DOMAIN:=datark.koneksi.co.kr}"
: "${VAULT_ADDR:=}"                 # this env's Vault, e.g. https://vault.datark...
: "${VAULT_TOKEN:=}"                # provisioner token (never committed)
: "${VAULT_KV_MOUNT:=secret}"       # KV v2 mount
: "${VAULT_TRANSIT_MOUNT:=transit}"
: "${KUBE_CONTEXT:=}"               # optional kube context
: "${NS_PREFIX:=tenant-}"           # namespace = <NS_PREFIX><tenant-id>
: "${IMAGE_PULL_SECRET:=ncr-regcred}"

# TLS: wildcard cert materialized into each tenant namespace as a tls Secret.
: "${TLS_CERT:=$REPO_DIR/certs/fullchain.pem}"
: "${TLS_KEY:=$REPO_DIR/certs/private.key}"
: "${TLS_SECRET_NAME:=datark-wildcard-tls}"   # must match chart ingress.tlsSecretName

export VAULT_ADDR VAULT_TOKEN

# --- logging ---
_c() { printf '\033[%sm' "$1"; }
log()   { printf '%s %s\n' "$(_c '1;34')[datark]$(_c 0)" "$*"; }
ok()    { printf '%s %s\n' "$(_c '1;32')  [ok]$(_c 0)" "$*"; }
warn()  { printf '%s %s\n' "$(_c '1;33')[warn]$(_c 0)" "$*" >&2; }
die()   { printf '%s %s\n' "$(_c '1;31') [err]$(_c 0)" "$*" >&2; exit 1; }

# kubectl / helm / vault wrappers honoring KUBE_CONTEXT
kc()  { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
helmc() { if [[ -n "$KUBE_CONTEXT" ]]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi; }

ns_for()  { echo "${NS_PREFIX}${1}"; }        # tenant-id -> namespace
rel_for() { echo "${NS_PREFIX}${1}"; }        # helm release name == namespace
gen_secret() { openssl rand -hex 24; }        # 48-char hex secret
