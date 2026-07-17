// DatArk Console API — reads tenant namespaces + nodes from the Kubernetes API,
// simple session login, serves the dashboard. In-cluster read-scoped ServiceAccount.
const express = require('express');
const path = require('path');
const crypto = require('crypto');
const k8s = require('@kubernetes/client-node');

const app = express();
const PORT = process.env.PORT || 3000;
const USER = process.env.CONSOLE_USER || 'superadmin';
const PASS = process.env.CONSOLE_PASS || 'ar@dm1n';
const NS_PREFIX = process.env.NS_PREFIX || 'tenant-';

const kc = new k8s.KubeConfig();
try { kc.loadFromCluster(); } catch (_) { kc.loadFromDefault(); }
const core = kc.makeApiClient(k8s.CoreV1Api);
const apps = kc.makeApiClient(k8s.AppsV1Api);
const net = kc.makeApiClient(k8s.NetworkingV1Api);

// ---- simple session auth ----
const sessions = new Set();
function cookies(req) {
  return Object.fromEntries((req.headers.cookie || '').split(';').map(c => {
    const i = c.indexOf('='); return [c.slice(0, i).trim(), decodeURIComponent(c.slice(i + 1))];
  }).filter(p => p[0]));
}
function requireAuth(req, res, next) {
  if (sessions.has(cookies(req).datark_session)) return next();
  res.status(401).json({ error: 'unauthorized' });
}
app.use(express.json());
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  if (username === USER && password === PASS) {
    const tok = crypto.randomBytes(24).toString('hex');
    sessions.add(tok);
    res.setHeader('Set-Cookie', `datark_session=${tok}; HttpOnly; Path=/; SameSite=Lax`);
    return res.json({ ok: true, user: username });
  }
  res.status(401).json({ error: 'invalid credentials' });
});
app.get('/api/me', (req, res) => sessions.has(cookies(req).datark_session)
  ? res.json({ user: USER }) : res.status(401).json({ error: 'unauthorized' }));
app.post('/api/logout', (req, res) => {
  sessions.delete(cookies(req).datark_session);
  res.setHeader('Set-Cookie', 'datark_session=; HttpOnly; Path=/; Max-Age=0');
  res.json({ ok: true });
});

// ---- helpers ----
const podReady = p => { const cs = p.status && p.status.containerStatuses; return Array.isArray(cs) && cs.length > 0 && cs.every(c => c.ready); };
const health = (r, t) => t === 0 ? 'unknown' : (r === t ? 'healthy' : 'degraded');

// ---- tenants list ----
app.get('/api/tenants', requireAuth, async (_req, res) => {
  try {
    const nsList = (await core.listNamespace()).body.items.filter(n => (n.metadata.name || '').startsWith(NS_PREFIX));
    const tenants = await Promise.all(nsList.map(async n => {
      const ns = n.metadata.name, labels = n.metadata.labels || {};
      let ready = 0, total = 0, host = null;
      try { const pods = (await core.listNamespacedPod(ns)).body.items; total = pods.length; ready = pods.filter(podReady).length; } catch (_) {}
      try { const ings = (await net.listNamespacedIngress(ns)).body.items; host = ings[0] && ings[0].spec.rules[0].host; } catch (_) {}
      return { name: labels['datark.koneksi.co.kr/tenant'] || ns.replace(NS_PREFIX, ''), namespace: ns,
        tier: labels['datark.koneksi.co.kr/tier'] || '—', pods: `${ready}/${total}`, status: health(ready, total),
        endpoint: host ? `https://${host}` : null };
    }));
    tenants.sort((a, b) => a.name.localeCompare(b.name));
    res.json({ tenants });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
});

// ---- tenant detail (workloads inside the namespace) ----
app.get('/api/tenants/:name', requireAuth, async (req, res) => {
  const ns = NS_PREFIX + req.params.name;
  try {
    const workloads = [];
    for (const d of (await apps.listNamespacedDeployment(ns)).body.items)
      workloads.push({ name: d.metadata.name, kind: 'Deployment', ready: `${d.status.readyReplicas || 0}/${d.spec.replicas || 0}`,
        ok: (d.status.readyReplicas || 0) === (d.spec.replicas || 0) });
    for (const s of (await apps.listNamespacedStatefulSet(ns)).body.items)
      workloads.push({ name: s.metadata.name, kind: 'StatefulSet', ready: `${s.status.readyReplicas || 0}/${s.spec.replicas || 0}`,
        ok: (s.status.readyReplicas || 0) === (s.spec.replicas || 0) });
    let host = null, clusterHost = null;
    try {
      const ings = (await net.listNamespacedIngress(ns)).body.items;
      for (const ing of ings) {
        const h = ing.spec && ing.spec.rules && ing.spec.rules[0] && ing.spec.rules[0].host;
        if (!h) continue;
        // kripfs public endpoint = <id>-cluster.<domain> (ingress name ends -kripfs-public)
        if ((ing.metadata.name || '').includes('kripfs') || h.includes('-cluster.')) clusterHost = h;
        else if (!host) host = h;
      }
    } catch (_) {}
    let tier = '—';
    try { const nsObj = (await core.readNamespace(ns)).body; tier = (nsObj.metadata.labels || {})['datark.koneksi.co.kr/tier'] || '—'; } catch (_) {}
    let bearer = null, adminEmail = null, adminPassword = null;
    try {
      const s = (await core.readNamespacedSecret(`${req.params.name}-secret`, ns)).body;
      const dec = k => (s.data && s.data[k]) ? Buffer.from(s.data[k], 'base64').toString('utf8') : null;
      bearer = dec('KIPFS_STATIC_BEARER');
      adminEmail = dec('ADMIN_EMAIL');
      adminPassword = dec('ADMIN_PASSWORD');
    } catch (_) {}
    workloads.sort((a, b) => a.name.localeCompare(b.name));
    res.json({ name: req.params.name, namespace: ns, tier, endpoint: host ? `https://${host}` : null,
      clusterEndpoint: clusterHost ? `https://${clusterHost}` : null,
      bearer, adminEmail, adminPassword, workloads });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
});

// ---- onboard a tenant (trigger the provisioning pipeline) ----
const GH_TOKEN = process.env.GITHUB_TOKEN;
const GH_REPO = process.env.GITHUB_REPO || 'koneksi-tech/datark-onboarding';
const GH_WORKFLOW = process.env.GITHUB_WORKFLOW || 'provision-tenant.yml';
const TIERS = ['free', 'starter', 'pro', 'enterprise'];

app.post('/api/tenants', requireAuth, async (req, res) => {
  const client = (req.body && req.body.client || '').trim();
  const tier = (req.body && req.body.tier || '').trim();
  if (!/^[a-z0-9]([a-z0-9-]{1,28}[a-z0-9])$/.test(client))
    return res.status(400).json({ error: 'client name must be lowercase a-z 0-9 -, 3–30 chars' });
  if (!TIERS.includes(tier)) return res.status(400).json({ error: 'invalid tier' });
  if (!GH_TOKEN) return res.status(500).json({ error: 'GITHUB_TOKEN not configured on the console' });
  try {
    const r = await fetch(`https://api.github.com/repos/${GH_REPO}/actions/workflows/${GH_WORKFLOW}/dispatches`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${GH_TOKEN}`, Accept: 'application/vnd.github+json',
        'Content-Type': 'application/json', 'User-Agent': 'datark-console' },
      body: JSON.stringify({ ref: 'main', inputs: { client_name: client, tier } }),
    });
    if (r.status === 204) return res.json({ ok: true, message: `Provisioning "${client}" (${tier}) started.` });
    const t = await r.text();
    res.status(502).json({ error: `pipeline dispatch failed (${r.status}): ${t.slice(0, 180)}` });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
});

// ---- destroy a tenant (delete its namespace) ----
app.delete('/api/tenants/:name', requireAuth, async (req, res) => {
  const ns = NS_PREFIX + req.params.name;
  if (!ns.startsWith(NS_PREFIX) || ns === NS_PREFIX) return res.status(400).json({ error: 'invalid tenant' });
  try {
    await core.deleteNamespace(ns);
    res.json({ ok: true, namespace: ns });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
});

// ---- cluster nodes ----
app.get('/api/nodes', requireAuth, async (_req, res) => {
  try {
    const nodes = (await core.listNode()).body.items.map(n => {
      const cond = (n.status.conditions || []).find(c => c.type === 'Ready');
      return { name: n.metadata.name, status: cond && cond.status === 'True' ? 'Ready' : 'NotReady',
        cpu: n.status.capacity.cpu, memory: n.status.capacity.memory,
        version: n.status.nodeInfo.kubeletVersion, os: n.status.nodeInfo.osImage };
    });
    res.json({ nodes });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
});

app.get('/healthz', (_req, res) => res.json({ ok: true }));
app.use(express.static(path.join(__dirname, 'public')));
app.listen(PORT, () => console.log(`DatArk Console listening on :${PORT}`));
