const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { downloadArtifact } = require('../src/artifact-download');

const currentBody = Buffer.from('PUBLICACAO-NOVA-COMPLETA');
let invalidRangeRequests = 0;

const server = http.createServer((request, response) => {
  const etag = '"publicacao-nova"';
  if (request.url === '/valid' && request.headers.range === 'bytes=6-' &&
      request.headers['if-range'] === etag) {
    response.writeHead(206, {
      ETag: etag,
      'Content-Length': currentBody.length - 6,
      'Content-Range': `bytes 6-${currentBody.length - 1}/${currentBody.length}`
    });
    response.end(currentBody.subarray(6));
    return;
  }
  if (request.url === '/changed' && request.headers.range) {
    // If-Range antigo: um servidor correto devolve o objeto inteiro atual.
    response.writeHead(200, {
      ETag: etag,
      'Content-Length': currentBody.length
    });
    response.end(currentBody);
    return;
  }
  if (request.url === '/invalid' && request.headers.range) {
    invalidRangeRequests += 1;
    response.writeHead(206, {
      ETag: '"etag-diferente"',
      'Content-Length': currentBody.length - 6,
      'Content-Range': `bytes 6-${currentBody.length - 1}/${currentBody.length}`
    });
    response.end(currentBody.subarray(6));
    return;
  }
  response.writeHead(200, {
    ETag: etag,
    'Content-Length': currentBody.length
  });
  response.end(currentBody);
});

async function listen() {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function seedPartial(filename, url, etag) {
  fs.writeFileSync(filename, currentBody.subarray(0, 6));
  fs.writeFileSync(`${filename}.resume.json`, JSON.stringify({
    url,
    etag,
    total: currentBody.length
  }));
}

async function run() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vshook-download-test-'));
  const baseUrl = await listen();
  try {
    const validFile = path.join(root, 'valid.bin');
    await seedPartial(validFile, `${baseUrl}/valid`, '"publicacao-nova"');
    await downloadArtifact(`${baseUrl}/valid`, validFile, () => {}, {
      resume: true,
      timeoutMs: 5000
    });
    assert.deepEqual(fs.readFileSync(validFile), currentBody);

    const changedFile = path.join(root, 'changed.bin');
    await seedPartial(changedFile, `${baseUrl}/changed`, '"publicacao-antiga"');
    await downloadArtifact(`${baseUrl}/changed`, changedFile, () => {}, {
      resume: true,
      timeoutMs: 5000
    });
    assert.deepEqual(fs.readFileSync(changedFile), currentBody,
      'Uma publicacao nova deve sobrescrever os bytes parciais antigos.');

    const invalidFile = path.join(root, 'invalid.bin');
    await seedPartial(invalidFile, `${baseUrl}/invalid`, '"publicacao-nova"');
    await downloadArtifact(`${baseUrl}/invalid`, invalidFile, () => {}, {
      resume: true,
      timeoutMs: 5000
    });
    assert.equal(invalidRangeRequests, 1);
    assert.deepEqual(fs.readFileSync(invalidFile), currentBody,
      'Uma faixa 206 incompatível deve reiniciar, nunca formar um arquivo hibrido.');
    assert.equal(fs.existsSync(`${invalidFile}.resume.json`), false);

    console.log('ARTIFACT_DOWNLOAD_RESUME_OK');
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
