#!/usr/bin/env bash
# Materialize the wildcard TLS secret into a tenant namespace. Sourced.
# The chart's Ingress references TLS_SECRET_NAME (default datark-wildcard-tls),
# which must exist IN the tenant namespace (Ingress TLS secrets are namespaced).

ensure_tls_secret() {
  local id="$1" ns
  ns="$(ns_for "$id")"

  [[ -f "$TLS_CERT" ]] || die "TLS cert not found: $TLS_CERT (put fullchain.pem in certs/)"
  [[ -f "$TLS_KEY"  ]] || die "TLS key not found: $TLS_KEY (put private.key in certs/)"

  # sanity: key matches cert (fail early rather than serve a broken cert)
  local cm km
  cm="$(openssl x509 -in "$TLS_CERT" -noout -modulus 2>/dev/null | openssl md5)"
  km="$(openssl rsa  -in "$TLS_KEY"  -noout -modulus 2>/dev/null | openssl md5)"
  [[ "$cm" == "$km" ]] || die "TLS cert/key mismatch — $TLS_CERT does not match $TLS_KEY"

  # warn if the cert won't cover <id>.<DOMAIN>
  local host="${id}.${DOMAIN}"
  if ! openssl x509 -in "$TLS_CERT" -noout -checkhost "$host" >/dev/null 2>&1; then
    warn "cert does NOT cover $host — TLS will fail for this tenant (need a *.$DOMAIN cert)"
  fi

  kc create secret tls "$TLS_SECRET_NAME" -n "$ns" \
    --cert="$TLS_CERT" --key="$TLS_KEY" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "tls secret $TLS_SECRET_NAME synced into $ns (host $host)"
}
