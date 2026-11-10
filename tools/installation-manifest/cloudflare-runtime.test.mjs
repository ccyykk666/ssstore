import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {getPlatformProxy} from 'wrangler';
import worker from './cloudflare-private.mjs';

test('Cloudflare local D1 and Rate Limit bindings serve an authenticated manifest', async t => {
  const platform = await getPlatformProxy({configPath: new URL('./wrangler.toml', import.meta.url).pathname, persist: false});
  t.after(() => platform.dispose());
  const env = {...platform.env, MANIFEST_API_TOKEN: randomBytes(32).toString('hex')};
  const issued = await worker.fetch(new Request('https://install.example/manifest.plist', {
    method: 'POST', headers: {Authorization: 'Bearer ' + env.MANIFEST_API_TOKEN, 'Content-Type': 'application/json'},
    body: JSON.stringify({bundleid: 'com.example.app', name: '运行时测试', version: '1',
      fetchurl: 'http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa'}),
  }), env);
  assert.equal(issued.status, 201);
  const {path} = await issued.json();
  const result = await worker.fetch(new Request(new URL(path, 'https://install.example/manifest.plist')), env);
  assert.equal(result.status, 200);
  assert.match(await result.text(), /运行时测试/);
});
