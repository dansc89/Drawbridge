import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import multer from 'multer';

async function fixture(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'drawbridge-upload-test-'));
  const app = express();
  const upload = multer({ dest: dir, limits: { fileSize: 32 } });
  app.post('/upload', upload.single('file'), async (req, res, next) => {
    try {
      if (!req.file) return res.sendStatus(400);
      const bytes = await fs.readFile(req.file.path);
      await fs.unlink(req.file.path);
      res.json({ size: req.file.size, text: bytes.toString() });
    } catch (error) { next(error); }
  });
  app.get('/health', (_, res) => res.sendStatus(200));
  app.use((error, _req, res, _next) => res.sendStatus(error.code === 'LIMIT_FILE_SIZE' ? 413 : 400));
  const server = await new Promise(resolve => { const server = app.listen(0, '127.0.0.1', () => resolve(server)); });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await fs.rm(dir, { recursive: true, force: true });
  });
  return { url: `http://127.0.0.1:${server.address().port}`, dir };
}
function form(name, text) {
  const body = new FormData(); body.append(name, new Blob([text], { type: 'application/pdf' }), 'synthetic.pdf'); return body;
}
test('single upload retains bytes and field API', async t => {
  const f = await fixture(t);
  const result = await fetch(f.url + '/upload', { method: 'POST', body: form('file', '%PDF-test') });
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { size: 9, text: '%PDF-test' });
  assert.deepEqual(await fs.readdir(f.dir), []);
});
test('oversized upload is rejected and temporary file removed', async t => {
  const f = await fixture(t);
  const result = await fetch(f.url + '/upload', { method: 'POST', body: form('file', 'x'.repeat(64)) });
  assert.equal(result.status, 413); await result.text();
  assert.deepEqual(await fs.readdir(f.dir), []);
  assert.equal((await fetch(f.url + '/health')).status, 200);
});
test('unexpected file field is rejected without storing a file', async t => {
  const f = await fixture(t);
  const result = await fetch(f.url + '/upload', { method: 'POST', body: form('wrong', 'test') });
  assert.equal(result.status, 400); await result.text();
  assert.deepEqual(await fs.readdir(f.dir), []);
});
test('truncated multipart request fails without killing the server', async t => {
  const f = await fixture(t);
  const result = await fetch(f.url + '/upload', { method: 'POST', headers: { 'content-type': 'multipart/form-data; boundary=test-boundary' }, body: '--test-boundary\r\nContent-Disposition: form-data; name="field"\r\n\r\nincomplete' });
  assert.equal(result.status, 400); await result.text();
  assert.equal((await fetch(f.url + '/health')).status, 200);
});
