import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import worker, {manifest} from './worker.mjs';

const payload = 'http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa';
function query(overrides = {}) {
  return new URLSearchParams({bundleid: 'com.example.application', name: '应用 & <Test> 🐱', version: '123', fetchurl: payload, ...overrides});
}
function request(params = query(), method = 'GET', path = '/manifest.plist') {
  return new Request('https://install.example' + path + '?' + params, {method});
}

test('emits a real, UTF-8 Apple plist with the unchanged local payload address', async () => {
  const response = await worker.fetch(request());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(response.headers.get('Content-Type'), /application\/xml; charset=utf-8/);
  const decoded = spawnSync('python3', ['-c', 'import json,plistlib,sys; print(json.dumps(plistlib.loads(sys.stdin.buffer.read())))'], {input: await response.text(), encoding: 'utf8'});
  assert.equal(decoded.status, 0, decoded.stderr);
  const item = JSON.parse(decoded.stdout).items[0];
  assert.deepEqual(item.assets, [{kind: 'software-package', url: payload}]);
  assert.equal(item.metadata.title, '应用 & <Test> 🐱');
  assert.equal(item.metadata['bundle-identifier'], 'com.example.application');
  assert.equal(item.metadata['bundle-version'], '123');
});

test('rejects non-loopback or ambiguous package URLs', () => {
  for (const url of [payload.replace('127.0.0.1', 'example.com'), payload.replace('127.0.0.1', '127.0.0.1.example.com'),
    payload.replace('127.0.0.1', 'user@127.0.0.1'), payload + '?token=secret', payload + '#fragment',
    payload.replace('http:', 'file:'), payload.replace(/[^/]+\.ipa$/, 'profile.mobileconfig')]) {
    assert.throws(() => manifest(query({fetchurl: url})), url);
  }
});

test('rejects duplicate, missing, unsafe and oversized metadata without reflecting it', async () => {
  const duplicate = query(); duplicate.append('fetchurl', payload);
  const missing = query(); missing.delete('version');
  const unknown = query(); unknown.append('password', 'do-not-echo');
  for (const params of [duplicate, missing, unknown, query({name: '\u0000'}), query({name: 'x'.repeat(257)}), query({bundleid: '<bad>'})]) {
    const response = await worker.fetch(request(params));
    assert.equal(response.status, 400);
    assert.equal(await response.text(), 'Invalid manifest parameters');
  }
});

test('requires the manifest route and GET; rejects oversized queries', async () => {
  assert.equal((await worker.fetch(request(query(), 'POST'))).status, 405);
  assert.equal((await worker.fetch(request(query(), 'GET', '/'))).status, 404);
  assert.equal((await worker.fetch(request(new URLSearchParams({name: 'x'.repeat(2049)})))).status, 414);
});
