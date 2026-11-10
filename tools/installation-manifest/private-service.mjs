import {createHash, randomBytes, timingSafeEqual} from 'node:crypto';
import {manifest} from './worker.mjs';

const tokenPattern = /^[A-Za-z0-9._~+\/-]{32,512}={0,2}$/;
export function validAPIToken(value) { return typeof value === 'string' && !/\s/.test(value) && tokenPattern.test(value); }

function result(status, text, headers = {}) {
  return new Response(text, {status, headers: {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers}});
}

export function createPrivateManifestService({apiToken, clock = Date.now, ticketsPerMinute = 30, maxTickets = 150,
  ticketLifetime = 300_000, ticketReads = 8, randomID = () => randomBytes(32).toString('hex')} = {}) {
  if (!validAPIToken(apiToken)) throw new Error('Configure a private API token (32–512 token characters) before starting');
  const digest = value => createHash('sha256').update(value).digest();
  const expected = digest(apiToken);
  const authorized = header => {
    const supplied = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : '';
    return validAPIToken(supplied) && timingSafeEqual(digest(supplied), expected);
  };
  const tickets = new Map();
  let issueWindow = -1, issued = 0, rejectedWindow = -1, rejected = 0;
  return {
    authorized,
    async fetch(request) {
      const now = clock();
      const url = new URL(request.url);
      for (const [id, item] of tickets) if (item.expires <= now) tickets.delete(id);
      const ticket = url.pathname.match(/^\/tickets\/([a-f0-9]{64})\.plist$/);
      if (ticket) {
        if (!['GET', 'HEAD'].includes(request.method)) return result(405, 'Method not allowed', {Allow: 'GET, HEAD'});
        const item = tickets.get(ticket[1]);
        if (!item) return result(404, 'Ticket unavailable');
        if (item.reads >= ticketReads) return result(429, 'Ticket read limit exceeded', {'Retry-After': '300'});
        item.reads++;
        return result(200, request.method === 'HEAD' ? null : item.xml, {'Content-Type': 'application/xml; charset=utf-8'});
      }
      if (url.pathname !== '/manifest.plist') return result(404, 'Not found');
      if (!authorized(request.headers.get('Authorization'))) {
        const window = Math.floor(now / 60_000);
        if (window !== rejectedWindow) { rejectedWindow = window; rejected = 0; }
        rejected++;
        return rejected > 60 ? result(429, 'Too many unauthorized requests', {'Retry-After': '60'}) : result(401, 'Unauthorized');
      }
      if (request.method !== 'POST') return result(405, 'Use authenticated POST', {Allow: 'POST'});
      if (!request.headers.get('Content-Type')?.startsWith('application/json')) return result(415, 'Use application/json');
      if (url.search) return result(400, 'Use a JSON request body');
      const window = Math.floor(now / 60_000);
      if (window !== issueWindow) { issueWindow = window; issued = 0; }
      if (issued >= ticketsPerMinute) return result(429, 'Issuance limit exceeded', {'Retry-After': '60'});
      // Invalid authorized requests consume the same bounded issuance budget.
      issued++;
      if (tickets.size >= maxTickets) return result(503, 'Ticket capacity reached', {'Retry-After': '60'});
      try {
        const bytes = await request.arrayBuffer();
        if (bytes.byteLength > 8192) return result(413, 'Request too large');
        const data = JSON.parse(new TextDecoder().decode(bytes));
        if (!data || Array.isArray(data) || Object.keys(data).length !== 4 ||
            !Object.values(data).every(value => typeof value === 'string')) return result(400, 'Invalid request');
        const xml = manifest(new URLSearchParams(data));
        const id = randomID();
        if (!/^[a-f0-9]{64}$/.test(id) || tickets.has(id)) return result(503, 'Ticket creation failed');
        tickets.set(id, {xml, expires: now + ticketLifetime, reads: 0});
        return result(201, JSON.stringify({path: `tickets/${id}.plist`}), {'Content-Type': 'application/json; charset=utf-8'});
      } catch { return result(400, 'Invalid request'); }
    }
  };
}
