import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const configURL = new URL('../src/config.js', import.meta.url).href;
function load(secret, mode = 'production', extra = {}) {
  return spawnSync(process.execPath, ['--input-type=module', '-e',
    `import { config } from ${JSON.stringify(configURL)}; console.log(JSON.stringify({host:config.host,corsOrigin:config.corsOrigin}));`], {
    env: { ...process.env, JWT_SECRET: secret, NODE_ENV: mode, HOST: '', CORS_ORIGIN: '', ...extra },
    encoding: 'utf8'
  });
}

for (const mode of ['development', 'production']) {
  test(`reject missing, weak, and example secrets in ${mode}`, () => {
    for (const secret of ['', 'dev-only-secret-change-me', 'replace-with-a-long-random-secret', 'a'.repeat(32)]) {
      const result = load(secret, mode);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /JWT_SECRET must be a generated secret/);
    }
  });
}
test('generated secret uses local-only defaults', () => {
  const result = load(randomBytes(32).toString('hex'));
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { host: '127.0.0.1', corsOrigin: 'http://localhost:3000' });
});
test('explicit container listener overrides local default', () => {
  const result = load(randomBytes(32).toString('hex'), 'production', { HOST: '0.0.0.0', CORS_ORIGIN: 'https://example.com' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { host: '0.0.0.0', corsOrigin: 'https://example.com' });
});
