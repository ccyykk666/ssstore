import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';
import worker from './worker.mjs';

// Run behind a public, trusted HTTPS reverse proxy. The manifest and its
// protocol are identical to the Worker; this server never fetches IPA URLs.
export function createManifestServer() {
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? '/', 'http://127.0.0.1');
      if (url.pathname === '/healthz' && request.method === 'GET') {
        response.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
        response.end('ok\n');
        return;
      }
      const result = await worker.fetch(new Request(url, {method: request.method}));
      response.writeHead(result.status, Object.fromEntries(result.headers));
      response.end(Buffer.from(await result.arrayBuffer()));
    } catch {
      // Do not reflect or log application metadata from the query string.
      if (!response.headersSent) response.writeHead(400, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
      response.end('Invalid request');
    }
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 15_000;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.MANIFEST_HTTP_PORT ?? 8080);
  const host = process.env.MANIFEST_BIND_HOST ?? '127.0.0.1';
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid MANIFEST_HTTP_PORT');
  createManifestServer().listen(port, host, () => {
    console.log(`Manifest origin listening on ${host}:${port}; configure public HTTPS at the reverse proxy.`);
  });
}
