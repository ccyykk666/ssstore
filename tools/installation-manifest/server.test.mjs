import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {randomBytes} from 'node:crypto';
import {createManifestServer} from './server.mjs';
import {createPrivateManifestService} from './private-service.mjs';

const apiToken = randomBytes(32).toString('hex');
const payload = 'http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa';
const metadata = {bundleid: 'com.example.app', name: '测试 + & <App>', version: '123', fetchurl: payload};
function issue(service, body = metadata, token = apiToken) {
  return service.fetch(new Request('https://install.example/manifest.plist', {method: 'POST',
    headers: {Authorization: 'Bearer ' + token, 'Content-Type': 'application/json'}, body: JSON.stringify(body)}));
}

test('private service requires a strong configured token and never exposes raw generation', async () => {
  assert.throws(() => createManifestServer());
  assert.throws(() => createPrivateManifestService({apiToken: 'short'}));
  const service = createPrivateManifestService({apiToken});
  assert.equal((await issue(service, metadata, randomBytes(32).toString('hex'))).status, 401);
  assert.equal((await service.fetch(new Request('https://install.example/manifest.plist?bundleid=example.app'))).status, 401);
  assert.equal((await issue(service, {...metadata, fetchurl: 'https://other.example/file.ipa'})).status, 400);
});

test('opaque links reveal no app metadata or API token and expire; HEAD and GET can both be used', async () => {
  let now = 100_000;
  const service = createPrivateManifestService({apiToken, clock: () => now, ticketLifetime: 300_000});
  const created = await issue(service);
  assert.equal(created.status, 201);
  const body = await created.text();
  assert.ok(!body.includes(apiToken) && !body.includes(metadata.bundleid) && !body.includes(metadata.name));
  const {path} = JSON.parse(body);
  assert.match(path, /^tickets\/[a-f0-9]{64}\.plist$/);
  const url = new URL(path, 'https://install.example/manifest.plist');
  assert.equal((await service.fetch(new Request(url, {method: 'HEAD'}))).status, 200);
  const response = await service.fetch(new Request(url));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const xml = await response.text();
  assert.ok(xml.includes('测试 + &amp; &lt;App&gt;') && xml.includes(payload));
  now += 300_000;
  assert.equal((await service.fetch(new Request(url))).status, 404);
});

test('limits ticket reuse, authorized issuance and storage without anonymous requests exhausting owner budget', async () => {
  const service = createPrivateManifestService({apiToken, ticketsPerMinute: 2, ticketReads: 2, maxTickets: 1});
  for (let i=0; i<65; i++) await issue(service, metadata, 'x'.repeat(64));
  const created = await issue(service);
  assert.equal(created.status, 201);
  const url = new URL((await created.json()).path, 'https://install.example/manifest.plist');
  assert.equal((await service.fetch(new Request(url))).status, 200);
  assert.equal((await service.fetch(new Request(url))).status, 200);
  assert.equal((await service.fetch(new Request(url))).status, 429);
  assert.equal((await issue(service)).status, 503);
  assert.equal((await issue(service)).status, 429);
});

test('portable private server handles the complete flow over real HTTP, with size and credential checks', async t => {
  const server = createManifestServer({apiToken}).listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const origin = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(origin+'/manifest.plist')).status, 401);
  assert.equal((await fetch(origin+'/manifest.plist', {method: 'POST', body: 'x'.repeat(9000)})).status, 401);
  const headers = {Authorization: 'Bearer '+apiToken, 'Content-Type': 'application/json'};
  assert.equal((await fetch(origin+'/manifest.plist', {method: 'POST', headers, body: 'x'.repeat(9000)})).status, 413);
  const created = await fetch(origin+'/manifest.plist', {method: 'POST', headers, body: JSON.stringify(metadata)});
  assert.equal(created.status, 201);
  const url = new URL((await created.json()).path, origin+'/manifest.plist');
  const response = await fetch(url);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /application\/xml/);
  assert.ok((await response.text()).includes(payload));
  assert.equal((await fetch(origin+'/healthz')).status, 200);
});
