#!/usr/bin/env bash
# Input validation. Sourced.

validate_tenant_id() {
  local id="$1"
  [[ "$id" =~ ^[a-z0-9]([a-z0-9-]{1,28}[a-z0-9])$ ]] \
    || die "invalid tenant id '$id' — must be 3-30 chars, lowercase alphanumeric + hyphens, no leading/trailing hyphen"
}

validate_tier() {
  local tier="$1"
  [[ -f "$TIERS_DIR/$tier.yaml" ]] \
    || die "unknown tier '$tier' — expected one of: $(cd "$TIERS_DIR" && ls *.yaml | sed 's/.yaml//' | tr '\n' ' ')"
}
