# k8s-setup — one-time datark-cluster preparation

Cluster-level infrastructure that must exist **before** any tenant is provisioned.
Run once per cluster. Not per-tenant (that's `../bin/datark-provision.sh`).

> All actions pin the datark kube-context so prod koneksi is never touched:
> `nks_datark-cluster_5ee750d9-5cbc-461e-a072-b9950527a71c`

## Contents
```
ingress-nginx/     shared ingress controller (fronts *.datark.koneksi.co.kr)
  values.yaml      helm values (default "nginx" IngressClass, LoadBalancer)
  install.sh       context-pinned installer
storageclass/
  nhn-block-ssd.yaml   default StorageClass (Cinder CSI) — replicated from prod
```

## What's already applied (2026-07-08)
| Component | Status | Detail |
|-----------|--------|--------|
| ingress-nginx | ✅ installed | ns `ingress-nginx`, 2 controller pods, IngressClass `nginx` (default) |
| LoadBalancer  | ✅ public IP | **133.186.214.160** — point `*.datark.koneksi.co.kr` here |
| StorageClass  | ✅ default | `nhn-block-ssd` (cinder.csi.openstack.org, General SSD) — PVC bind verified |

## Re-apply / bootstrap a fresh cluster
```bash
# ingress-nginx
bash ingress-nginx/install.sh

# storage class
kubectl --context nks_datark-cluster_5ee750d9-5cbc-461e-a072-b9950527a71c \
  apply -f storageclass/nhn-block-ssd.yaml
```

## Still pending (not yet applied)
- **Wildcard DNS**: `*.datark.koneksi.co.kr` A-record → `133.186.214.160`.
- **Wildcard TLS secret**: chart references `datark-wildcard-tls`. Provide a
  `*.datark.koneksi.co.kr` cert as a TLS secret (or install cert-manager).
- **NCR pull secret**: `.ncr-dockerconfig.json` for the registry the images live in.
