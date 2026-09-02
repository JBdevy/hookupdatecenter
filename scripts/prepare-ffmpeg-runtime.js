'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const VERSION = '8.1.2';
const ROOT = path.resolve(__dirname, '..');
const OUTPUT_DIR = path.join(ROOT, 'vendor', 'ffmpeg');
const WINDOWS_FILE = `ffmpeg-${VERSION}-win64-lgpl-shared.zip`;
const WINDOWS_URL =
  'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/' +
  'ffmpeg-n8.1-latest-win64-lgpl-shared-8.1.zip';

function selectedPlatform() {
  const args = new Set(process.argv.slice(2));
  if (args.has('--windows')) return 'windows';
  if (args.has('--current')) {
    if (process.platform === 'win32') return 'windows';
    return 'skip';
  }
  throw new Error('Informe --windows ou --current. O FFmpeg é preparado somente para Windows.');
}

function validZip(filename, minimumBytes) {
  if (!fs.existsSync(filename)) return false;
  const stat = fs.statSync(filename);
  if (!stat.isFile() || stat.size < minimumBytes) return false;
  const handle = fs.openSync(filename, 'r');
  try {
    const header = Buffer.alloc(4);
    fs.readSync(handle, header, 0, header.length, 0);
    return header[0] === 0x50 && header[1] === 0x4b;
  } finally {
    fs.closeSync(handle);
  }
}

function download(url, destination, redirects = 0) {
  if (redirects > 8) {
    return Promise.reject(new Error('Redirecionamentos demais ao baixar o FFmpeg.'));
  }
  const client = url.startsWith('https:') ? https : http;
  return new Promise((resolve, reject) => {
    const request = client.get(url, {
      headers: { 'User-Agent': `Hook-Center-Build/${VERSION}` }
    }, (response) => {
      const status = Number(response.statusCode || 0);
      if ([301, 302, 303, 307, 308].includes(status) && response.headers.location) {
        response.resume();
        resolve(download(new URL(response.headers.location, url).toString(), destination, redirects + 1));
        return;
      }
      if (status !== 200) {
        response.resume();
        reject(new Error(`O servidor do FFmpeg respondeu HTTP ${status}.`));
        return;
      }
      const output = fs.createWriteStream(destination, { flags: 'w', mode: 0o600 });
      let received = 0;
      let nextReport = 10;
      response.on('data', (chunk) => {
        received += chunk.length;
        const total = Number(response.headers['content-length'] || 0);
        if (total > 0) {
          const percent = Math.floor((received / total) * 100);
          if (percent >= nextReport) {
            process.stdout.write(`FFmpeg ${percent}%\n`);
            nextReport += 10;
          }
        }
      });
      response.pipe(output);
      output.on('finish', () => output.close(resolve));
      output.on('error', reject);
      response.on('error', reject);
    });
    request.setTimeout(180000, () =>
      request.destroy(new Error('Tempo esgotado ao baixar o FFmpeg.')));
    request.on('error', reject);
  });
}

async function prepareWindows() {
  const destination = path.join(OUTPUT_DIR, WINDOWS_FILE);
  if (validZip(destination, 50 * 1024 * 1024)) {
    console.log(`Runtime FFmpeg já preparado: ${destination}`);
    return;
  }
  const partial = `${destination}.partial`;
  fs.rmSync(partial, { force: true });
  console.log(`Baixando FFmpeg ${VERSION} LGPL compartilhado para Windows...`);
  try {
    await download(WINDOWS_URL, partial);
    if (!validZip(partial, 50 * 1024 * 1024)) {
      throw new Error('O pacote FFmpeg para Windows está incompleto ou inválido.');
    }
    fs.rmSync(destination, { force: true });
    fs.renameSync(partial, destination);
  } catch (error) {
    fs.rmSync(partial, { force: true });
    throw error;
  }
  console.log(`Runtime FFmpeg incluído no build: ${destination}`);
}

async function main() {
  const platform = selectedPlatform();
  if (platform === 'skip') {
    console.log('FFmpeg não é necessário nesta plataforma.');
    return;
  }
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  await prepareWindows();
}

main().catch((error) => {
  console.error(error?.message || error);
  process.exitCode = 1;
});
