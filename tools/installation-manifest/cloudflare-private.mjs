import {createHash, randomBytes, timingSafeEqual} from 'node:crypto';
import {manifest} from './worker.mjs';
import {validAPIToken} from './private-service.mjs';

const schema = [
  'CREATE TABLE IF NOT EXISTS manifest_tickets (id TEXT PRIMARY KEY, scope TEXT NOT NULL, xml TEXT NOT NULL, expires INTEGER NOT NULL, reads INTEGER NOT NULL DEFAULT 0)',
  'CREATE INDEX IF NOT EXISTS manifest_tickets_expiry ON manifest_tickets(expires)',
  'CREATE TABLE IF NOT EXISTS manifest_limits (scope TEXT NOT NULL, minute INTEGER NOT NULL, used INTEGER NOT NULL, PRIMARY KEY(scope, minute))',
];

function response(status, body, extra = {}) {
  return new Response(body, {status, headers: {'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Content-Type': 'text/plain; charset=utf-8', ...extra}});
}

async function limitedBody(request) {
  if (Number(request.headers.get('Content-Length') ?? 0) > 8192) throw new Error('size');
  const reader = request.body?.getReader();
  if (!reader) return '';
  const chunks = []; let length = 0;
  try {
    while (true) {
      const {value, done} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 8192) { await reader.cancel(); throw new Error('size'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
}

export function createCloudflareManifestService({clock = Date.now} = {}) {
  const ready = new WeakMap();
  async function initialize(db) {
    if (!ready.has(db)) {
      const initialization = db.batch(schema.map(sql => db.prepare(sql))).catch(error => { ready.delete(db); throw error; });
      ready.set(db, initialization);
    }
    await ready.get(db);
  }
  async function cleanup(db, now) {
    await db.batch([
      db.prepare('DELETE FROM manifest_tickets WHERE expires <= ?').bind(now),
      db.prepare('DELETE FROM manifest_limits WHERE minute < ?').bind(Math.floor(now / 60000) - 2),
    ]);
  }
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      if (!validAPIToken(env.MANIFEST_API_TOKEN) || !env.DB || !env.PUBLIC_LIMITER) {
        return response(503, 'Private manifest service is not configured');
      }
      if (request.method === 'GET' && ['/', '/healthz'].includes(url.pathname)) return response(200, 'ssstore private manifest service: ok\n');
      if (url.search) return response(400, 'Query parameters are not accepted');
      const ticket = url.pathname.match(/^\/tickets\/([a-f0-9]{64})\.plist$/);
      if (!ticket && url.pathname !== '/manifest.plist') return response(404, 'Not found');
      const {success} = await env.PUBLIC_LIMITER.limit({key: 'ssstore-manifest:' + (request.headers.get('CF-Connecting-IP') ?? 'local')});
      if (!success) return response(429, 'Too many requests', {'Retry-After': '60'});
      const digest = value => createHash('sha256').update(value).digest();
      const expected = digest(env.MANIFEST_API_TOKEN);
      const scope = expected.toString('hex');
      if (!ticket) {
        const header = request.headers.get('Authorization') ?? '';
        const token = header.startsWith('Bearer ') ? header.slice(7) : '';
        if (!validAPIToken(token) || !timingSafeEqual(digest(token), expected)) return response(401, 'Unauthorized');
        if (request.method !== 'POST') return response(405, 'Use authenticated POST', {Allow: 'POST'});
        if (!request.headers.get('Content-Type')?.startsWith('application/json')) return response(415, 'Use application/json');
      } else if (!['GET', 'HEAD'].includes(request.method)) return response(405, 'Method not allowed', {Allow: 'GET, HEAD'});

      try {
        const db = env.DB;
        await initialize(db);
        const now = clock();
        if (ticket) {
          // A single SQLite statement enforces expiry/read count across all
          // Worker instances and locations, including simultaneous readers.
          const row = await db.prepare('UPDATE manifest_tickets SET reads = reads + 1 WHERE id = ? AND scope = ? AND expires > ? AND reads < 8 RETURNING xml')
            .bind(ticket[1], scope, now).first();
          if (!row) return response(404, 'Ticket unavailable');
          return response(200, request.method === 'HEAD' ? null : row.xml, {'Content-Type': 'application/xml; charset=utf-8'});
        }
        await cleanup(db, now);
        const quota = await db.prepare('INSERT INTO manifest_limits (scope, minute, used) VALUES (?, ?, 1) ON CONFLICT(scope, minute) DO UPDATE SET used = used + 1 RETURNING used')
          .bind(scope, Math.floor(now / 60000)).first();
        if (quota.used > 30) return response(429, 'Issuance limit exceeded', {'Retry-After': '60'});
        let body;
        try { body = await limitedBody(request); }
        catch (error) { return response(error.message === 'size' ? 413 : 400, 'Invalid request body'); }
        let xml;
        try {
          const data = JSON.parse(body);
          if (!data || Array.isArray(data) || Object.keys(data).length !== 4 || !Object.values(data).every(value => typeof value === 'string')) throw new Error('fields');
          xml = manifest(new URLSearchParams(data));
        } catch { return response(400, 'Invalid manifest parameters'); }
        const id = randomBytes(32).toString('hex');
        const inserted = await db.prepare('INSERT INTO manifest_tickets (id, scope, xml, expires, reads) SELECT ?, ?, ?, ?, 0 WHERE (SELECT COUNT(*) FROM manifest_tickets WHERE scope = ? AND expires > ?) < 150')
          .bind(id, scope, xml, now + 300000, scope, now).run();
        if (!inserted.meta.changes) return response(503, 'Ticket capacity reached', {'Retry-After': '60'});
        return response(201, JSON.stringify({path: `tickets/${id}.plist`}), {'Content-Type': 'application/json; charset=utf-8'});
      } catch {
        // Do not reflect SQL errors, metadata, tokens or ticket URLs into logs.
        return response(503, 'Manifest storage temporarily unavailable');
      }
    },
    async scheduled(_event, env) {
      if (!env.DB) return;
      await initialize(env.DB);
      await cleanup(env.DB, clock());
    },
  };
}

export default createCloudflareManifestService();
