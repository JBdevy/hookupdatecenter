const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { pipeline } = require('stream/promises');
const { Readable } = require('stream');

const FILE_NAME = 'Windows-MIDI-Services-Runtime-and-Tools-x64.exe';
const DOWNLOAD_URL = 'https://github.com/microsoft/MIDI/releases/download/rc-4/Windows.MIDI.Services.SDK.Runtime.and.Tools.1.0.17-rc.4.25-x64.exe';
const EXPECTED_SIZE = 219603123;
const EXPECTED_SHA256 = '5d241b52669a69795b7503f53eb082f83a1860e5ebc50849427b79f15c1a2546';
const DEFAULT_OUTPUT_DIR = path.resolve(__dirname, '..', 'vendor', 'windows-midi-services');
const PART_FILES = Array.from({ length: 5 }, (_, index) => `runtime-x64.exe.part${String(index + 1).padStart(2, '0')}`);

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

async function prepareWindowsMidi({ outputDir = DEFAULT_OUTPUT_DIR, fetchImpl = fetch } = {}) {
  const outputPath = path.join(outputDir, FILE_NAME);
  const partialPath = `${outputPath}.partial`;
  if (process.argv.includes('--if-windows') && process.platform !== 'win32') {
    console.log('Windows MIDI Services ignorado neste sistema.');
    return;
  }
  await fs.promises.mkdir(outputDir, { recursive: true });
  if (await fileIsValid(outputPath)) {
    console.log(`Windows MIDI Services já preparado: ${outputPath}`);
    return;
  }
  await fs.promises.rm(partialPath, { force: true });
  const parts = PART_FILES.map(name => path.join(outputDir, 'parts', name));
  try {
    if (parts.every(filename => fs.existsSync(filename))) {
      console.log('Preparando Windows MIDI Services RC4 a partir da cópia verificada do repositório...');
      async function* bundledBytes() {
        for (const filename of parts) {
          for await (const chunk of fs.createReadStream(filename)) yield chunk;
        }
      }
      await pipeline(Readable.from(bundledBytes()), fs.createWriteStream(partialPath, { flags: 'wx' }));
    } else {
      console.log('Baixando o instalador oficial do Windows MIDI Services RC4...');
      const response = await fetchImpl(DOWNLOAD_URL, {
        redirect: 'follow',
        headers: { 'User-Agent': 'VS-Hook-Build/1.0.2', Accept: 'application/octet-stream' }
      });
      if (!response.ok || !response.body) {
        throw new Error(`Falha ao baixar Windows MIDI Services: HTTP ${response.status}. Inclua os cinco arquivos de vendor/windows-midi-services/parts no checkout do build.`);
      }
      await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(partialPath, { flags: 'wx' }));
    }
  if (!await fileIsValid(partialPath)) {
    const actualSize = (await fs.promises.stat(partialPath)).size;
    const actualHash = await sha256File(partialPath);
    await fs.promises.rm(partialPath, { force: true });
    throw new Error(`O instalador do Windows MIDI Services não corresponde ao oficial esperado (bytes=${actualSize}, sha256=${actualHash}).`);
  }
  await fs.promises.rm(outputPath, { force: true });
  await fs.promises.rename(partialPath, outputPath);
  console.log(`Windows MIDI Services preparado: ${outputPath}`);
  } finally {
    await fs.promises.rm(partialPath, { force: true });
  }
}

if (require.main === module) {
  prepareWindowsMidi().catch(error => {
    console.error(error?.stack || error?.message || error);
    process.exitCode = 1;
  });
}
module.exports = { prepareWindowsMidi, fileIsValid, FILE_NAME, PART_FILES };
