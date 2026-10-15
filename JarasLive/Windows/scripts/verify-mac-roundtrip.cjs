const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const [executable, windowsDirectory, macDirectory, outputDirectory] = process.argv.slice(2);
assert(outputDirectory, 'Expected executable, Windows fixtures, Mac fixtures and output directory.');
const swift = fs.readFileSync(path.resolve(__dirname, '../../Application/Project/ProjectDocumentCodec.swift'), 'utf8');
const bytes = value => Buffer.from(value.split(',').map(s => Number.parseInt(s.trim(), 16)));
const header = bytes(swift.match(/header = Data\(\[([^\]]+)\]/)[1]);
const key = bytes(swift.match(/key = SymmetricKey\(data: Data\(\[([^\]]+)\]/)[1]);
function read(file) {
    const sealed = fs.readFileSync(file);
    assert.deepEqual(sealed.subarray(0, header.length), header, file);
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, sealed.subarray(header.length, header.length + 12));
    decipher.setAAD(header);
    decipher.setAuthTag(sealed.subarray(-16));
    return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(header.length + 12, -16)), decipher.final()]).toString('utf8'));
}
function contains(actual, expected, location = '$') {
    if (expected !== null && typeof expected === 'object') {
        assert(actual !== null && typeof actual === 'object', location);
        if (Array.isArray(expected)) assert.equal(actual.length, expected.length, location);
        for (const key of Object.keys(expected)) contains(actual[key], expected[key], `${location}.${key}`);
    } else assert.deepEqual(actual, expected, location);
}
const original = JSON.parse(fs.readFileSync(path.join(windowsDirectory, 'fixture.json'), 'utf8'));
const returned = read(path.join(macDirectory, 'WindowsReturn/Show.jl'));
assert.deepEqual(returned.windowsLighting, original.windowsLighting, 'Mac save changed the grandMA2 map.');
assert.equal(returned.name, 'Edited on Mac');
const results = [];
for (const [folder, expectedName] of [['WindowsReturn', 'windows-returned.json'], ['MacOrigin', 'mac-origin.json']]) {
    const input = path.resolve(macDirectory, folder, 'Show.jl');
    const output = path.resolve(outputDirectory, folder, 'Show.jl');
    fs.mkdirSync(path.dirname(output), { recursive: true });
    const result = spawnSync(path.resolve(executable), ['--roundtrip-project', input, output], { timeout: 30000, encoding: 'utf8' });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `Windows rejected ${folder}: ${result.stderr}`);
    const expected = JSON.parse(fs.readFileSync(path.join(macDirectory, expectedName), 'utf8'));
    contains(read(output), expected);
    results.push(folder);
}
fs.mkdirSync(outputDirectory, { recursive: true });
fs.writeFileSync(path.join(outputDirectory, 'compatibility-results.json'), JSON.stringify({ success: true, tested: results }, null, 2));
console.log('Real Windows → Mac → Windows and Mac → Windows encrypted document tests passed.');
