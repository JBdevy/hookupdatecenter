const assert = require('node:assert/strict');
const http = require('node:http');
const dgram = require('node:dgram');
const { createTimecodeLanRelay } = require('../src/timecode-lan');
(async () => {
  let polls = 0;
  const server = http.createServer((req, res) => {
    if (req.url === '/timecode/status') polls++;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ ok: true, mode: 'disabled', code: '', transport: { playState: 1, position: 50 } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const probe = dgram.createSocket('udp4');
  await new Promise(resolve => probe.bind(0, '127.0.0.1', resolve));
  const discoveryPort = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const relay = createTimecodeLanRelay({ nativeBridgePort: server.address().port, discoveryPort, getDirectDiscoveryAddresses: () => [] });
  try {
    await relay.start();
    await new Promise(resolve => setTimeout(resolve, 2200));
    assert(polls > 0 && polls <= 8, `disabled playback generated ${polls} state polls`);
    console.log(`RELAY_IDLE_INTEGRATION_OK: ${polls} polls, real scheduler and HTTP, without a UI window`);
  } finally {
    await relay.stop();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
