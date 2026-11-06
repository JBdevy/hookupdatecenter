const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const source = fs.readFileSync(path.join(__dirname, '../src/timecode-lan.js'), 'utf8');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function harness(stalled = false) {
  const requests = [], broadcasts = [], pending = new Set();
  let cableIp = '192.168.77.113', timeOffset = 0;
  const status = { ok: true, mode: 'project_sync', code: '123456',
    projectSyncRole: 'primary', sessionId: 'test', eventSequence: 0 };
  const fakeHttp = {
    Agent: class {},
    request(options, callback) {
      requests.push(options);
      const request = new EventEmitter();
      pending.add(request);
      request.setTimeout = () => request; // A socket stuck in connect never starts this timeout.
      request.write = () => {};
      request.destroy = error => { pending.delete(request); request.emit('error', error); };
      request.end = () => {
        if (stalled) return;
        queueMicrotask(() => {
          const response = new EventEmitter(); response.statusCode = 200;
          callback(response);
          response.emit('data', Buffer.from(JSON.stringify(options.path === '/timecode/status'
            ? status : { ok: true, available: false })));
          response.emit('end'); pending.delete(request);
        });
      };
      return request;
    },
  };
  const socket = new EventEmitter();
  socket.bind = (port, host, callback) => queueMicrotask(callback);
  socket.setBroadcast = () => {};
  socket.send = (data, offset, length, port, address, callback) => {
    broadcasts.push(address); callback();
  };
  socket.close = callback => callback();
  const fakeOs = { hostname: () => 'test', networkInterfaces: () => ({
    wifi: [{ internal: false, family: 'IPv4', address: '10.0.0.101', netmask: '255.255.255.0' }],
    cable: [{ internal: false, family: 'IPv4', address: cableIp, netmask: '255.255.255.0' }],
  }) };
  const sandbox = { module: { exports: {} }, Buffer, setTimeout, clearTimeout,
    Date: class extends Date { static now() { return Date.now() + timeOffset; } },
    require: name => name === 'http' ? fakeHttp : name === 'os' ? fakeOs :
      name === 'dgram' ? { createSocket: () => socket } : require(name) };
  vm.runInNewContext(source + '\nmodule.exports.requestJson = requestJson;', sandbox);
  return { ...sandbox.module.exports, requests, broadcasts, pending,
    getCableIp: () => cableIp,
    changeCable() { cableIp = '192.168.88.113'; timeOffset += 4000; } };
}

(async () => {
  const stalled = harness(true);
  try {
    const result = await Promise.race([
      stalled.requestJson({ hostname: '192.168.77.250', port: 47831, path: '/availability', timeoutMs: 50 })
        .then(() => 'response', () => 'timed out'),
      delay(500).then(() => 'still connecting'),
    ]);
    assert.equal(result, 'timed out', 'discovery must bound the TCP connect phase too');
    assert.equal(stalled.pending.size, 0, 'deadline must destroy the stalled request');
  } finally {
    for (const request of stalled.pending) request.destroy(new Error('test cleanup'));
  }
  const network = harness();
  const relay = network.createTimecodeLanRelay({ getDirectCableIp: network.getCableIp });
  try {
    await relay.start(); await delay(180);
    const scans = () => network.requests.filter(request => request.path.endsWith('/availability'));
    assert(scans().length > 0);
    assert(scans().every(request => request.hostname.startsWith('192.168.77.')),
      'selected cable must be searched without waiting for Wi-Fi or other adapters');
    assert.deepEqual(network.broadcasts, ['192.168.77.255']);
    network.requests.length = 0; network.broadcasts.length = 0;
    network.changeCable(); await delay(180);
    assert(scans().length > 0, 'network change must trigger discovery on the new subnet');
    assert(scans().every(request => request.hostname.startsWith('192.168.88.')));
    assert.deepEqual(network.broadcasts, ['192.168.88.255']);
  } finally { await relay.stop(); }
  console.log('TIMECODE_DISCOVERY_OK: bounded TCP connect, selected cable only, live adapter IP changes');
})().catch(error => { console.error(error); process.exitCode = 1; });
