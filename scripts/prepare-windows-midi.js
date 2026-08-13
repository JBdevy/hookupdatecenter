const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { pipeline } = require('stream/promises');
const { Readable } = require('stream');

const FILE_NAME = 'Windows-MIDI-Services-Runtime-and-Tools-x64.exe';
const DOWNLOAD_URL = 'https://github.com/microsoft/MIDI/releases/download/rc-4/Windows.MIDI.Services.SDK.Runtime.and.Tools.1.0.17-rc.4.25-x64.exe';
const EXPECTED_SIZE = 219603123;
const EXPECTED_SHA256 = '5d241b52669a69795b7503f53eb082f83a1860e5ebc50849427b79f15c1a2546';
const outputDir = path.resolve(__dirname, '..', 'vendor', 'windows-midi-services');
const outputPath = path.join(outputDir, FILE_NAME);
const partialPath = `${outputPath}.partial`;

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = fs.createReadStream(filePath);
    input.on('error', reject);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex').toLowerCase()));
  });
}

async function fileIsValid(filePath) {
  try {
    const stats = await fs.promises.stat(filePath);
    if (!stats.isFile() || stats.size !== EXPECTED_SIZE) return false;
    return await sha256File(filePath) === EXPECTED_SHA256;
  } catch (_) {
    return false;
  }
}

async function main() {
  if (process.argv.includes('--if-windows') && process.platform !== 'win32') {
    console.log('Windows MIDI Services ignorado neste sistema.');
    return;
  }
  await fs.promises.mkdir(outputDir, { recursive: true });
  if (await fileIsValid(outputPath)) {
    console.log(`Windows MIDI Services já preparado: ${outputPath}`);
    return;
  }
  await fs.promises.rm(outputPath, { force: true });
  await fs.promises.rm(partialPath, { force: true });
  console.log('Baixando o instalador oficial do Windows MIDI Services RC4...');
  const response = await fetch(DOWNLOAD_URL, {
    redirect: 'follow',
    headers: { 'User-Agent': 'VS-Hook-Build/1.0.1', Accept: 'application/octet-stream' }
  });
  if (!response.ok || !response.body) {
    throw new Error(`Falha ao baixar Windows MIDI Services: HTTP ${response.status}`);
  }
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(partialPath, { flags: 'wx' }));
  if (!await fileIsValid(partialPath)) {
    const actualSize = (await fs.promises.stat(partialPath)).size;
    const actualHash = await sha256File(partialPath);
    await fs.promises.rm(partialPath, { force: true });
    throw new Error(`O instalador do Windows MIDI Services não corresponde ao oficial esperado (bytes=${actualSize}, sha256=${actualHash}).`);
  }
  await fs.promises.rename(partialPath, outputPath);
  console.log(`Windows MIDI Services preparado: ${outputPath}`);
}

main().catch(async (error) => {
  try { await fs.promises.rm(partialPath, { force: true }); } catch (_) {}
  console.error(error?.stack || error?.message || error);
  process.exitCode = 1;
});
