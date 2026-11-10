import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {createManifestServer} from './server.mjs';

test('portable server serves the same manifest over a real HTTP connection', async t => {
  const server = createManifestServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const payload = 'http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa';
  const params = new URLSearchParams({bundleid: 'com.example.app', name: '测试 + & <App>', version: '123', fetchurl: payload});
  const response = await fetch(origin + '/manifest.plist?' + params);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('content-type'), /application\/xml/);
  const xml = await response.text();
  assert.ok(xml.includes('<string>' + payload + '</string>'));
  assert.ok(xml.includes('测试 + &amp; &lt;App&gt;'));
  assert.equal((await fetch(origin + '/manifest.plist?' + params, {method: 'POST'})).status, 405);
  params.set('fetchurl', 'https://other.example/file.ipa');
  assert.equal((await fetch(origin + '/manifest.plist?' + params)).status, 400);
  assert.equal((await fetch(origin + '/healthz')).status, 200);
});
