import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';
import {readFileSync} from 'node:fs';
import {createPrivateManifestService} from './private-service.mjs';

// Run behind a trusted HTTPS reverse proxy. Reuses the public Worker's pure
// XML generator, with authenticated issuance and expiring capability URLs.
export function createManifestServer(options) {
  const service = createPrivateManifestService(options);
  const server = createServer({maxHeaderSize: 8192}, async (request, response) => {
    try {
      const url = new URL(request.url ?? '/', 'http://127.0.0.1');
      if (url.pathname === '/healthz' && request.method === 'GET') {
        response.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'});
        response.end('ok\n');
        return;
      }
      if (request.method === 'POST' && !service.authorized(request.headers.authorization)) {
        const rejected = await service.fetch(new Request(url, {method: 'POST', headers: request.headers}));
        response.writeHead(rejected.status, {...Object.fromEntries(rejected.headers), Connection: 'close'});
        response.end(Buffer.from(await rejected.arrayBuffer()), () => request.destroy());
        return;
      }
      let body;
      if (request.method === 'POST') {
        if (Number(request.headers['content-length'] ?? 0) > 8192) {
          response.writeHead(413, {'Connection': 'close', 'Cache-Control': 'no-store'});
          response.end('Request too large', () => request.destroy());
          return;
        }
        // Also enforce the limit on chunked bodies without buffering excess data.
        body = await new Promise((resolve, reject) => {
          const chunks = []; let size = 0;
          request.on('data', chunk => {
            size += chunk.length;
            if (size > 8192) {
              request.pause();
              reject(Object.assign(new Error('Body too large'), {status: 413}));
            } else { chunks.push(chunk); }
          });
          request.on('end', () => resolve(Buffer.concat(chunks)));
          request.on('error', reject);
          request.on('aborted', () => reject(new Error('Request aborted')));
        });
      }
      const result = await service.fetch(new Request(url, {method: request.method, headers: request.headers, body}));
      response.writeHead(result.status, Object.fromEntries(result.headers));
      response.end(Buffer.from(await result.arrayBuffer()));
    } catch (error) {
      // Do not reflect or log application metadata from the query string.
      if (!response.headersSent) response.writeHead(error.status === 413 ? 413 : 400, {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'Connection': 'close'});
      response.end('Invalid request', () => request.destroy());
    }
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 15_000;
  server.maxHeadersCount = 50;
  server.maxRequestsPerSocket = 30;
  server.maxConnections = 64;
  server.keepAliveTimeout = 5000;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.MANIFEST_HTTP_PORT ?? 8080);
  const host = process.env.MANIFEST_BIND_HOST ?? '127.0.0.1';
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid MANIFEST_HTTP_PORT');
  const tokenFile = process.env.MANIFEST_API_TOKEN_FILE;
  if (!tokenFile) throw new Error('MANIFEST_API_TOKEN_FILE is required; anonymous mode is disabled');
  const apiToken = readFileSync(tokenFile, 'utf8').trim();
  createManifestServer({apiToken}).listen(port, host, () => {
    console.log(`Manifest origin listening on ${host}:${port}; configure public HTTPS at the reverse proxy.`);
  });
}
