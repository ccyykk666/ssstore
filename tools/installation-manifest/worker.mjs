// Optional, self-hosted HTTPS manifest generator. It never fetches an IPA URL.
// Not connected to the iOS client until a service has been chosen and deployed.
const keys = new Set(['bundleid', 'name', 'version', 'fetchurl']);
const invalidXML = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\ud800-\udfff\ufffe\uffff]/u;
const ipaPath = /^\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.ipa$/i;

function escapeXML(value) {
  return value.replace(/[&<>"']/g, char => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;'}[char]));
}

function text(query, key, limit) {
  const value = query.get(key);
  if (!value || value.length > limit || invalidXML.test(value)) throw new Error('Invalid field');
  return value;
}

export function manifest(query) {
  for (const key of query.keys()) {
    if (!keys.has(key) || query.getAll(key).length !== 1) throw new Error('Invalid query');
  }
  const bundleID = text(query, 'bundleid', 255);
  const name = text(query, 'name', 256);
  const version = text(query, 'version', 64);
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(bundleID)) throw new Error('Invalid bundle ID');
  const payload = new URL(text(query, 'fetchurl', 512));
  if (!['http:', 'https:'].includes(payload.protocol) || payload.hostname !== '127.0.0.1' ||
      !payload.port || payload.username || payload.password || payload.search || payload.hash ||
      !ipaPath.test(payload.pathname)) throw new Error('Expected local IPA URL');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${escapeXML(payload.href)}</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>${escapeXML(bundleID)}</string><key>bundle-version</key><string>${escapeXML(version)}</string><key>kind</key><string>software</string><key>title</key><string>${escapeXML(name)}</string></dict>
</dict></array></dict></plist>`;
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const headers = {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'};
    if (url.pathname !== '/manifest.plist') return new Response('Not found', {status: 404, headers});
    if (request.method !== 'GET') return new Response('Method not allowed', {status: 405, headers: {...headers, Allow: 'GET'}});
    if (url.search.length > 2048) return new Response('Query too long', {status: 414, headers});
    try {
      return new Response(manifest(url.searchParams), {headers: {...headers, 'Content-Type': 'application/xml; charset=utf-8'}});
    } catch {
      // Do not echo query values into errors or logs.
      return new Response('Invalid manifest parameters', {status: 400, headers});
    }
  }
};
