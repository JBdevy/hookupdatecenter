'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { prepareWindowsMidi, fileIsValid, FILE_NAME, PART_FILES } = require('../scripts/prepare-windows-midi');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-midi-build-test-'));
const noNetwork = async () => { throw new Error('Unexpected network request'); };
(async () => {
  try {
    const clean = path.join(temp, 'clean');
    fs.mkdirSync(path.join(clean, 'parts'), { recursive: true });
    for (const part of PART_FILES) {
      const original = path.join(__dirname, '../vendor/windows-midi-services/parts', part);
      assert(fs.statSync(original).size <= 48 * 1024 * 1024);
      fs.copyFileSync(original, path.join(clean, 'parts', part));
    }
    await prepareWindowsMidi({ outputDir: clean, fetchImpl: noNetwork });
    assert(await fileIsValid(path.join(clean, FILE_NAME)), 'fresh checkout reconstructs the exact approved installer');
    fs.rmSync(path.join(clean, 'parts'), { recursive: true });
    await prepareWindowsMidi({ outputDir: clean, fetchImpl: noNetwork });
    const corrupt = path.join(temp, 'corrupt');
    fs.mkdirSync(path.join(corrupt, 'parts'), { recursive: true });
    for (const part of PART_FILES) fs.writeFileSync(path.join(corrupt, 'parts', part), 'corrupt');
    await assert.rejects(prepareWindowsMidi({ outputDir: corrupt, fetchImpl: noNetwork }), /não corresponde ao oficial/);
    assert(!fs.existsSync(path.join(corrupt, FILE_NAME)));
    assert(!fs.existsSync(path.join(corrupt, FILE_NAME + '.partial')));
    const missing = path.join(temp, 'missing');
    await assert.rejects(prepareWindowsMidi({ outputDir: missing, fetchImpl: async () => ({ ok: false, status: 404 }) }), /cinco arquivos/);
    assert(!fs.existsSync(path.join(missing, FILE_NAME + '.partial')));
    console.log('WINDOWS_MIDI_CLEAN_CHECKOUT_OFFLINE_HASH_CACHE_CORRUPTION_AND_MISSING_PARTS_OK');
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
})().catch(error => { console.error(error); process.exitCode = 1; });
