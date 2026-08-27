'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');

const VERSION = '3.0.23';
const ROOT = path.resolve(__dirname, '..');
const OUTPUT_DIR = path.join(ROOT, 'vendor', 'vlc');
const PACKAGES = Object.freeze({
  windows: {
    filename: `vlc-${VERSION}-win64.zip`,
    url: `https://mirror.turbozoneinternet.net.br/videolan/vlc/${VERSION}/win64/vlc-${VERSION}-win64.zip`,
    minimumBytes: 50 * 1024 * 1024,
    kind: 'zip'
  },
  macos: {
    filename: `vlc-${VERSION}-universal.dmg`,
    url: `https://mirror.turbozoneinternet.net.br/videolan/vlc/${VERSION}/macosx/vlc-${VERSION}-universal.dmg`,
    minimumBytes: 50 * 1024 * 1024,
    kind: 'dmg'
  }
});

function selectedPackage() {
  const args = new Set(process.argv.slice(2));
  if (args.has('--windows')) return PACKAGES.windows;
  if (args.has('--macos')) return PACKAGES.macos;
  if (args.has('--current')) {
    if (process.platform === 'win32') return PACKAGES.windows;
    if (process.platform === 'darwin') return PACKAGES.macos;
  }
  throw new Error('Informe --windows, --macos ou --current em Windows/macOS.');
}

function validateArchive(filename, spec) {
  if (!fs.existsSync(filename)) return false;
  const stat = fs.statSync(filename);
  if (!stat.isFile() || stat.size < spec.minimumBytes) return false;
  const handle = fs.openSync(filename, 'r');
  try {
    if (spec.kind === 'zip') {
      const header = Buffer.alloc(4);
      fs.readSync(handle, header, 0, header.length, 0);
      return header[0] === 0x50 && header[1] === 0x4b;
    }
    const trailer = Buffer.alloc(512);
    fs.readSync(handle, trailer, 0, trailer.length, stat.size - trailer.length);
    return trailer.subarray(0, 4).toString('ascii') === 'koly';
  } finally {
    fs.closeSync(handle);
  }
}

function download(url, destination, redirects = 0) {
  if (redirects > 8) return Promise.reject(new Error('Redirecionamentos demais ao baixar o VLC.'));
  const client = url.startsWith('https:') ? https : http;
  return new Promise((resolve, reject) => {
    const request = client.get(url, {
      headers: { 'User-Agent': `Hook-Center-Build/${VERSION}` }
    }, (response) => {
      const status = Number(response.statusCode || 0);
      if ([301, 302, 303, 307, 308].includes(status) && response.headers.location) {
        response.resume();
        const nextUrl = new URL(response.headers.location, url).toString();
        resolve(download(nextUrl, destination, redirects + 1));
        return;
      }
      if (status !== 200) {
        response.resume();
        reject(new Error(`O servidor do VLC respondeu HTTP ${status}.`));
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
            process.stdout.write(`VLC ${percent}%\n`);
            nextReport += 10;
          }
        }
      });
      response.pipe(output);
      output.on('finish', () => output.close(resolve));
      output.on('error', reject);
      response.on('error', reject);
    });
    request.setTimeout(120000, () => request.destroy(new Error('Tempo esgotado ao baixar o VLC.')));
    request.on('error', reject);
  });
}

async function main() {
  const spec = selectedPackage();
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const destination = path.join(OUTPUT_DIR, spec.filename);
  if (validateArchive(destination, spec)) {
    console.log(`Runtime VLC já preparado: ${destination}`);
    return;
  }
  const partial = `${destination}.partial`;
  fs.rmSync(partial, { force: true });
  console.log(`Preparando o runtime VLC ${VERSION} para o instalador da Hook Center...`);
  try {
    await download(spec.url, partial);
    if (!validateArchive(partial, spec)) {
      throw new Error('O pacote VLC baixado está incompleto ou inválido.');
    }
    fs.rmSync(destination, { force: true });
    fs.renameSync(partial, destination);
    console.log(`Runtime VLC incluído no build: ${destination}`);
  } catch (error) {
    fs.rmSync(partial, { force: true });
    throw error;
  }
}

main().catch((error) => {
  console.error(error?.message || error);
  process.exitCode = 1;
});
