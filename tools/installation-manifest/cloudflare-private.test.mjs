import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {createCloudflareManifestService} from './cloudflare-private.mjs';

// Execute the real SQL against SQLite, rather than returning canned D1 rows.
class TestD1 {
  constructor(database = new DatabaseSync(':memory:')) { this.database = database; this.calls = 0; }
  prepare(sql) { return new Statement(this, sql); }
  async batch(statements) {
    this.database.exec('BEGIN');
    try {
      const results = statements.map(statement => statement.execute());
      this.database.exec('COMMIT');
      return results;
    } catch (error) { this.database.exec('ROLLBACK'); throw error; }
  }
}
class Statement {
  constructor(db, sql, values = []) { Object.assign(this, {db, sql, values}); }
  bind(...values) { return new Statement(this.db, this.sql, values); }
  execute() {
    this.db.calls++;
    const result = this.db.database.prepare(this.sql).run(...this.values);
    return {success: true, meta: {changes: result.changes}};
  }
  async run() { return this.execute(); }
  async first() {
    this.db.calls++;
    return this.db.database.prepare(this.sql).get(...this.values) ?? null;
  }
}
const metadata = {bundleid: 'com.example.app', name: '测试 + & 🐱', version: '123',
  fetchurl: 'http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa'};
function environment(t) {
  const db = new TestD1();
  t.after(() => db.database.close());
  return {DB: db, MANIFEST_API_TOKEN: randomBytes(32).toString('hex'), PUBLIC_LIMITER: {async limit() { return {success: true}; }}};
}
function issue(service, env, body = metadata, overrides = {}) {
  return service.fetch(new Request('https://install.example/manifest.plist', {method: 'POST',
    headers: {Authorization: 'Bearer ' + env.MANIFEST_API_TOKEN, 'Content-Type': 'application/json', ...overrides},
    body: JSON.stringify(body)}), env);
}

test('configuration and authentication fail closed, without anonymous SQL or reflected tokens', async t => {
  const env = environment(t), service = createCloudflareManifestService();
  assert.equal((await service.fetch(new Request('https://install.example/healthz'), {})).status, 503);
  assert.equal((await service.fetch(new Request('https://install.example/healthz'), env)).status, 200);
  assert.equal((await service.fetch(new Request('https://install.example/manifest.plist'), env)).status, 401);
  const rejected = await issue(service, env, metadata, {Authorization: 'Bearer ' + randomBytes(32).toString('hex')});
  assert.equal(rejected.status, 401);
  assert.ok(!(await rejected.text()).includes(env.MANIFEST_API_TOKEN));
  assert.equal(env.DB.calls, 0);
});

test('opaque ticket survives a different Worker/binding instance and serves exact UTF-8 XML', async t => {
  const env = environment(t), service = createCloudflareManifestService();
  const issued = await issue(service, env);
  assert.equal(issued.status, 201);
  const text = await issued.text(), {path} = JSON.parse(text);
  assert.match(path, /^tickets\/[a-f0-9]{64}\.plist$/);
  assert.ok(!text.includes(metadata.bundleid) && !text.includes(env.MANIFEST_API_TOKEN));
  const other = createCloudflareManifestService();
  const rebound = {...env, DB: new TestD1(env.DB.database)};
  const url = new URL(path, 'https://install.example/manifest.plist');
  const head = await other.fetch(new Request(url, {method: 'HEAD'}), rebound);
  assert.equal(head.status, 200); assert.equal(await head.text(), '');
  const result = await other.fetch(new Request(url), rebound);
  assert.equal(result.status, 200); assert.equal(result.headers.get('Cache-Control'), 'no-store');
  const xml = await result.text();
  assert.ok(xml.includes('测试 + &amp; 🐱') && xml.includes(metadata.fetchurl));
  assert.ok(xml.includes('<string>123</string>'));
});

test('concurrent readers share an atomic eight-read budget, and key rotation invalidates tickets', async t => {
  const env = environment(t), service = createCloudflareManifestService();
  const url = new URL((await (await issue(service, env)).json()).path, 'https://install.example/manifest.plist');
  const results = await Promise.all(Array.from({length: 20}, () => service.fetch(new Request(url), env)));
  assert.equal(results.filter(result => result.status === 200).length, 8);
  assert.equal(results.filter(result => result.status === 404).length, 12);
  const next = new URL((await (await issue(service, env)).json()).path, 'https://install.example/manifest.plist');
  assert.equal((await service.fetch(new Request(next), {...env, MANIFEST_API_TOKEN: randomBytes(32).toString('hex')})).status, 404);
});

test('expiry is enforced on reads and scheduled cleanup removes expired private records', async t => {
  let now = 100000;
  const env = environment(t), service = createCloudflareManifestService({clock: () => now});
  const url = new URL((await (await issue(service, env)).json()).path, 'https://install.example/manifest.plist');
  now += 300000;
  assert.equal((await service.fetch(new Request(url), env)).status, 404);
  await service.scheduled({}, env);
  assert.equal(env.DB.database.prepare('SELECT COUNT(*) AS count FROM manifest_tickets').get().count, 0);
  assert.equal(env.DB.database.prepare('SELECT COUNT(*) AS count FROM manifest_limits').get().count, 0);
});

test('D1 enforces global issuance and storage limits across Worker instances', async t => {
  let now = 1000000;
  const env = environment(t);
  for (let minute = 0; minute < 5; minute++) {
    const service = createCloudflareManifestService({clock: () => now});
    for (let i = 0; i < 30; i++) assert.equal((await issue(service, env)).status, 201);
    assert.equal((await issue(createCloudflareManifestService({clock: () => now}), env)).status, 429);
    now += 60000;
  }
  // At just under five minutes all 150 live entries remain; another window's
  // valid request cannot make the storage bound race with an insertion.
  const scope = env.DB.database.prepare('SELECT scope FROM manifest_tickets LIMIT 1').get().scope;
  env.DB.database.prepare('UPDATE manifest_tickets SET expires = ?').run(now + 300000);
  assert.equal((await issue(createCloudflareManifestService({clock: () => now}), env)).status, 503);
  assert.equal(env.DB.database.prepare('SELECT COUNT(*) AS count FROM manifest_tickets WHERE scope = ?').get(scope).count, 150);
});

test('rejects remote payloads, malformed fields and oversized/chunked bodies; edge limits precede SQL', async t => {
  const env = environment(t), service = createCloudflareManifestService();
  assert.equal((await issue(service, env, {...metadata, fetchurl: 'https://other.example/file.ipa'})).status, 400);
  assert.equal((await issue(service, env, {...metadata, account: 'should-not-be-sent'})).status, 400);
  assert.equal((await issue(service, env, {...metadata, name: 'x'.repeat(9000)})).status, 413);
  const before = env.DB.calls;
  const limited = {...env, PUBLIC_LIMITER: {async limit() { return {success: false}; }}};
  assert.equal((await issue(service, limited)).status, 429);
  assert.equal(env.DB.calls, before);
});
