'use strict';
// Independent OpenSSL implementation of the Mac DAWRemoteCipher wire contract.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const fixture = JSON.parse(fs.readFileSync(path.join(process.argv[2], 'remote-cipher.json'), 'utf8'));
const bytes = name => Buffer.from(fixture[name], 'hex');
const hostHello = bytes('hostHello'), clientHello = bytes('clientHello');
const privateKey = start => crypto.createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(Array.from({length: 32}, (_, i) => start + i))]),
  format: 'der', type: 'pkcs8',
});
const hostPrivate = privateKey(1), clientPrivate = privateKey(100);
const rawPublic = privateKey => crypto.createPublicKey(privateKey).export({format: 'der', type: 'spki'}).subarray(-32);
assert.deepEqual(hostHello.subarray(0, 5), Buffer.from([0x4a, 0x44, 1, 2, 1]));
assert.deepEqual(clientHello.subarray(0, 5), Buffer.from([0x4a, 0x44, 1, 2, 2]));
assert.deepEqual(hostHello.subarray(5, 37), rawPublic(hostPrivate));
assert.deepEqual(clientHello.subarray(5, 37), rawPublic(clientPrivate));
const secret = crypto.diffieHellman({privateKey: hostPrivate, publicKey: crypto.createPublicKey(clientPrivate)});
assert.deepEqual(secret, crypto.diffieHellman({privateKey: clientPrivate, publicKey: crypto.createPublicKey(hostPrivate)}));
const salt = crypto.createHash('sha256').update(Buffer.concat([Buffer.from('Jaras Live Direct 1'), hostHello, clientHello])).digest();
const derive = direction => Buffer.from(crypto.hkdfSync('sha256', secret, salt, Buffer.from(direction), 32));
const toClient = derive('host-to-client'), toHost = derive('client-to-host');
function verify(name, key, counter, plain) {
  const envelope = bytes(name);
  const aad = Buffer.alloc(9); aad[0] = 2; aad.writeBigUInt64BE(BigInt(counter), 1);
  const nonce = Buffer.alloc(12); nonce.writeBigUInt64BE(BigInt(counter), 4);
  assert.deepEqual(envelope.subarray(0, 9), aad);
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, {authTagLength: 16});
  cipher.setAAD(aad);
  const encrypted = Buffer.concat([cipher.update(plain), cipher.final()]);
  assert.deepEqual(envelope, Buffer.concat([aad, encrypted, cipher.getAuthTag()]));
  const decipher = crypto.createDecipheriv('chacha20-poly1305', key, nonce, {authTagLength: 16});
  decipher.setAAD(aad); decipher.setAuthTag(envelope.subarray(-16));
  assert.deepEqual(Buffer.concat([decipher.update(envelope.subarray(9, -16)), decipher.final()]), plain);
}
verify('hostReady', toClient, 1, Buffer.from([0]));
verify('clientReady', toHost, 1, Buffer.from([0]));
verify('hostPacket', toClient, 2, bytes('hostPlain'));
verify('clientPacket', toHost, 2, bytes('clientPlain'));
assert.deepEqual(bytes('hostPlain').subarray(0, 5), Buffer.from([1, 0x4a, 0x4c, 2, 6]));
assert.deepEqual(bytes('clientPlain').subarray(0, 5), Buffer.from([1, 0x4a, 0x4c, 2, 5]));
console.log('Independent Remote X25519 / HKDF-SHA256 / ChaCha20-Poly1305 contract verified.');
