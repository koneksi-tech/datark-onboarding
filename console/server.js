// DatArk Console API — reads tenant namespaces from the Kubernetes API and
// serves the dashboard. Runs in-cluster with a read-scoped ServiceAccount.
const express = require('express');
const path = require('path');
const k8s = require('@kubernetes/client-node');

const app = express();
const PORT = process.env.PORT || 3000;

// in-cluster config (falls back to local kubeconfig for dev)
const kc = new k8s.KubeConfig();
try { kc.loadFromCluster(); } catch (_) { kc.loadFromDefault(); }
const core = kc.makeApiClient(k8s.CoreV1Api);
const net = kc.makeApiClient(k8s.NetworkingV1Api);

const TENANT_PREFIX = process.env.NS_PREFIX || 'tenant-';

function podReady(p) {
  const cs = p.status && p.status.containerStatuses;
  return Array.isArray(cs) && cs.length > 0 && cs.every(c => c.ready);
}

// GET /api/tenants — list tenants with pod status + ingress endpoint
app.get('/api/tenants', async (_req, res) => {
  try {
    const nsList = (await core.listNamespace()).body.items
      .filter(n => (n.metadata.name || '').startsWith(TENANT_PREFIX));

    const tenants = await Promise.all(nsList.map(async (n) => {
      const ns = n.metadata.name;
      const labels = n.metadata.labels || {};
      let ready = 0, total = 0, host = null;
      try {
        const pods = (await core.listNamespacedPod(ns)).body.items;
        total = pods.length;
        ready = pods.filter(podReady).length;
      } catch (_) {}
      try {
        const ings = (await net.listNamespacedIngress(ns)).body.items;
        host = ings[0] && ings[0].spec.rules && ings[0].spec.rules[0] && ings[0].spec.rules[0].host;
      } catch (_) {}
      const status = total === 0 ? 'unknown' : (ready === total ? 'healthy' : 'degraded');
      return {
        name: labels['datark.koneksi.co.kr/tenant'] || ns.replace(TENANT_PREFIX, ''),
        namespace: ns,
        tier: labels['datark.koneksi.co.kr/tier'] || '—',
        pods: `${ready}/${total}`,
        status,
        endpoint: host ? `https://${host}` : null,
      };
    }));

    tenants.sort((a, b) => a.name.localeCompare(b.name));
    res.json({ tenants });
  } catch (err) {
    res.status(500).json({ error: String(err && err.message || err) });
  }
});

app.get('/healthz', (_req, res) => res.json({ ok: true }));
app.use(express.static(path.join(__dirname, 'public')));

app.listen(PORT, () => console.log(`DatArk Console listening on :${PORT}`));
