const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const directory = process.argv[2];
if (!directory) throw new Error('Pass the Windows integration test results directory.');
const swift = fs.readFileSync(path.resolve(__dirname, '../../Application/Project/ProjectDocumentCodec.swift'), 'utf8');
const headerSource = swift.match(/header = Data\(\[([^\]]+)\]/)[1];
const keySource = swift.match(/key = SymmetricKey\(data: Data\(\[([^\]]+)\]/)[1];
const bytes = value => Buffer.from(value.split(',').map(s => Number.parseInt(s.trim(), 16)));
const header = bytes(headerSource), key = bytes(keySource);
const file = fs.readFileSync(path.join(directory, 'fixture.jl'));
assert.deepEqual(file.subarray(0, header.length), header);
const decrypt = crypto.createDecipheriv('aes-256-gcm', key, file.subarray(header.length, header.length + 12));
decrypt.setAAD(header);
decrypt.setAuthTag(file.subarray(-16));
const plaintext = Buffer.concat([decrypt.update(file.subarray(header.length + 12, -16)), decrypt.final()]);
const actual = JSON.parse(plaintext.toString('utf8'));
const expected = JSON.parse(fs.readFileSync(path.join(directory, 'fixture.json'), 'utf8'));
assert.deepEqual(actual, expected);
const swiftUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function verifyIDs(value) {
    if (!value || typeof value !== 'object') return;
    if (!Array.isArray(value) && typeof value.id === 'string') assert.match(value.id, swiftUUID, 'Project ID must decode as a Swift UUID');
    Object.values(value).forEach(verifyIDs);
}
verifyIDs(actual);
const nonce = crypto.randomBytes(12);
const encrypt = crypto.createCipheriv('aes-256-gcm', key, nonce);
encrypt.setAAD(header);
const ciphertext = Buffer.concat([encrypt.update(plaintext), encrypt.final()]);
fs.writeFileSync(path.join(directory, 'external-crypto.jl'), Buffer.concat([header, nonce, ciphertext, encrypt.getAuthTag()]));
if (process.argv[3]) {
    const target = path.resolve(directory, 'IndependentReturn/Show.jl');
    const result = spawnSync(process.argv[3], ['--roundtrip-project', path.resolve(directory, 'external-crypto.jl'), target], { encoding: 'utf8', timeout: 30000 });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, 'Windows rejected independently encrypted project.');
    const saved = fs.readFileSync(target);
    const verify = crypto.createDecipheriv('aes-256-gcm', key, saved.subarray(header.length, header.length + 12));
    verify.setAAD(header); verify.setAuthTag(saved.subarray(-16));
    const returned = Buffer.concat([verify.update(saved.subarray(header.length + 12, -16)), verify.final()]).toString('utf8');
    assert.deepEqual(JSON.parse(returned), expected);
    assert(returned.includes('9007199254740993'), 'Integer metadata lost precision.');
}
console.log('Independent AES-256-GCM verification against the Mac codec passed.');
