'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
function section(first, next) {
  const start = source.indexOf(first), end = source.indexOf(next, start + first.length);
  assert(start >= 0 && end > start);
  return source.slice(start, end);
}
const normalizer = section('function normalizeMachineId(', '\nfunction simpleHash(');
const anchors = section('async function getWindowsAnchor()', '\nasync function getMacAnchor()');
const fingerprint = section("let cachedDeviceFingerprint = '';", '\nfunction getSharedSignedLicensePath()');
async function identity(registry, fallback, env = { COMPUTERNAME: 'CLIENT-PC' }) {
  const calls = [];
  const context = { crypto, os: { hostname: () => 'DIFFERENT-HOST' }, process: { platform: 'win32', env },
    runCapture: async (command, args) => { calls.push([command, args]); return command === 'reg.exe' ? registry : fallback; } };
  vm.createContext(context); vm.runInContext(normalizer + anchors + fingerprint, context);
  return { anchor: await context.getWindowsAnchor(), fingerprint: await context.getDeviceFingerprint(), calls };
}
(async () => {
  for (const raw of ['abcdef01-2345-6789-abcd-0123456789ab', '{ABCDEF01-2345-6789-ABCD-0123456789AB}', 'OEM-MACHINE-42']) {
    const actual = await identity('HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography MachineGuid REG_SZ ' + raw, '');
    const nativeAnchor = raw.toUpperCase().replace(/\s+/g, '');
    assert.equal(actual.anchor, nativeAnchor);
    assert.equal(actual.fingerprint, crypto.createHash('sha256').update('VSHOOK_DEVICE_V1|win32|' + nativeAnchor).digest('hex').toUpperCase());
    assert(actual.calls.every(([command]) => command === 'reg.exe'));
  }
  const fallback = await identity('', '  {00112233-4455-6677-8899-AABBCCDDEEFF}  ');
  assert.equal(fallback.anchor, '{00112233-4455-6677-8899-AABBCCDDEEFF}');
  assert(fallback.calls.some(([, args]) => args.join(' ').includes('Registry64')));
  const unavailable = await identity('', '');
  assert.equal(unavailable.fingerprint, crypto.createHash('sha256').update('VSHOOK_DEVICE_V1|win32|CLIENT-PC').digest('hex').toUpperCase());
  assert(unavailable.calls.every(([, args]) => !/CimInstance|wmic|csproduct/.test(args.join(' '))));

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-license-identity-'));
  try {
    const target = path.join(temp, 'license.token'), machine = path.join(temp, 'machine.dat');
    const context = { fs, path, process: { platform: 'win32', pid: process.pid }, Buffer,
      getSharedSignedLicensePath: () => target, getSharedMachineIdPath: () => machine,
      writeSignedLicenseClockState() {}, hideLicenseShardOnWindows() {}, execFileSync() {}, cachedDeviceFingerprint: 'LOCAL-FINGERPRINT' };
    vm.createContext(context);
    vm.runInContext(normalizer + section('function readSignedLicenseToken()', '\nfunction writeSignedLicenseClockState(') + section('function saveSignedLicenseToken(', '\nfunction removeSignedLicenseToken()'), context);
    const token = (m, f) => 'header.' + Buffer.from(JSON.stringify({ m, f })).toString('base64url') + '.signature';
    const expected = token('LOCAL', 'LOCAL-FINGERPRINT');
    fs.writeFileSync(machine, 'LOCAL');
    assert.equal(context.saveSignedLicenseToken(expected, { required: true, machineId: 'LOCAL', deviceFingerprint: 'LOCAL-FINGERPRINT' }), true);
    assert.equal(fs.readFileSync(target, 'utf8').trim(), expected);
    assert.equal(context.localLicenseIdentityIssue(), '');
    assert.throws(() => context.saveSignedLicenseToken(token('OTHER', 'LOCAL-FINGERPRINT'), { required: true, machineId: 'LOCAL' }), /não corresponde/);
    assert.throws(() => context.saveSignedLicenseToken(token('LOCAL', 'OTHER'), { required: true, deviceFingerprint: 'LOCAL-FINGERPRINT' }), /não corresponde/);
    assert.equal(fs.readFileSync(target, 'utf8').trim(), expected, 'identity mismatch must preserve the current token');
    fs.writeFileSync(machine, 'OTHER');
    assert.match(context.localLicenseIdentityIssue(), /não corresponde/);
    fs.unlinkSync(target);
    assert.match(context.localLicenseIdentityIssue(), /não foi encontrada/);
    assert.throws(() => context.saveSignedLicenseToken('', { required: true }), /não forneceu/);
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  console.log('LICENSE_DEVICE_IDENTITY_OK: native Windows identity, registry fallback, local token binding and readback');
})().catch(error => { console.error(error); process.exitCode = 1; });
