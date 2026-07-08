#!/usr/bin/env bash
# Post-deploy verification. Sourced. Provisioning only "succeeds" if this passes.

verify_tenant() {
  local id="$1" ns
  ns="$(ns_for "$id")"
  log "verifying tenant $id in $ns"

  # 1. all workloads rolled out
  kc -n "$ns" rollout status "statefulset/${id}-kripfs" --timeout=300s
  kc -n "$ns" rollout status "statefulset/${id}-mongo" --timeout=300s
  kc -n "$ns" rollout status "statefulset/${id}-postgres" --timeout=300s
  kc -n "$ns" rollout status "deployment/${id}-backend" --timeout=300s
  kc -n "$ns" rollout status "deployment/${id}-redis" --timeout=180s
  ok "all workloads rolled out"

  # 2. kripfs health on each pod
  local replicas i
  replicas="$(kc -n "$ns" get statefulset "${id}-kripfs" -o jsonpath='{.spec.replicas}')"
  for (( i=0; i<replicas; i++ )); do
    kc -n "$ns" exec "${id}-kripfs-$i" -c kripfs -- \
      sh -c 'wget -qO- http://127.0.0.1:'"$(kc -n "$ns" get statefulset "${id}-kripfs" -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}')"'/health >/dev/null' \
      && ok "kripfs-$i /health OK" || die "kripfs-$i /health failed"
  done

  # 3. backend reachable through its ingress host (best-effort)
  local host; host="$(kc -n "$ns" get ingress "${id}-backend" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  [[ -n "$host" ]] && log "backend should be reachable at https://$host (verify DNS/LB externally)"
  ok "tenant $id verified"
}
