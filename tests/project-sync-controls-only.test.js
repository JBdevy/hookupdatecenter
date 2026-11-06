const assert = require('node:assert/strict');
const http = require('node:http');
const dgram = require('node:dgram');
const { performance } = require('node:perf_hooks');
const { createTimecodeLanRelay } = require('../src/timecode-lan');

const A = 'a'.repeat(32), B = 'b'.repeat(32);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, message, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return;
    await delay(25);
  }
  assert.fail(message);
}
async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return server.address().port;
}
async function close(server) {
  server.closeIdleConnections?.();
  await new Promise(resolve => server.close(resolve));
}
async function udpPort() {
  const probe = dgram.createSocket('udp4');
  await new Promise(resolve => probe.bind(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  return port;
}
function post(port, route, payload = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request({ hostname: '127.0.0.1', port, path: route,
      method: 'POST', headers: { 'Content-Type': 'application/json' } }, response => {
      let body = '';
      response.on('data', chunk => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, data: JSON.parse(body) }));
    });
    request.on('error', reject);
    request.end(JSON.stringify(payload));
  });
}
async function peer(id, role, mode = 'project_sync') {
  const state = {
    ok: true, mode, code: '123456', sessionId: `session-${id}`,
    projectSyncRole: role, selectedPeerId: role === 'primary' ? B : '',
    eventSequence: 0, projectSyncReady: false,
    manifest: `different-project-${id}`, manifestRevision: `different-${id}`,
    structuralManifestRevision: `structure-${id}`,
    transport: { sequence: 1, controlSequence: 0, playState: 1,
      position: 10, sampledAtMs: 1000, audioHealthy: true },
  };
  const commands = [], inbox = [], events = [], wire = [], requests = [], receipts = [];
  let inboxAvailable = true, connected = false, relay, nativeHealth = 'online';
  const native = http.createServer((request, response) => {
    let body = '';
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => {
      requests.push(request.url);
      if (nativeHealth === 'hung') return;
      if (nativeHealth === 'crashed') { request.socket.destroy(); return; }
      if (nativeHealth === 'closed') { response.writeHead(503); response.end('{}'); return; }
      let result = { ok: true };
      if (request.url === '/timecode/status') result = state;
      else if (request.url === '/timecode/outbox') {
        const after = JSON.parse(body).after;
        result = { ok: true, events: events.filter(event => event.sequence > after), transport: state.transport };
      } else if (request.url === '/command') {
        const command = JSON.parse(body); commands.push(command);
        if (command.type === 'timecode_peer_status') connected = command.connected;
        if (command.type === 'project_sync_role_handover') state.projectSyncRole = command.role;
      } else if (request.url === '/timecode/inbox') {
        const batch = body.split('\n').filter(Boolean).map(JSON.parse);
        if (inboxAvailable) {
          inbox.push(...batch);
          receipts.push(...batch.map(command => ({ command, at: performance.now() })));
        }
        result = { ok: inboxAvailable, queued: inboxAvailable ? batch.length : 0 };
      } else { response.statusCode = 404; result = { ok: false }; }
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify(result));
    });
  });
  const nativePort = await listen(native);
  const lan = http.createServer((request, response) => {
    let body = '';
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => { wire.push({ path: request.url, body: body ? JSON.parse(body) : {} }); });
    relay.handleHttp(request, response, new URL(request.url, 'http://localhost')).then(handled => {
      if (!handled) { response.statusCode = 404; response.end('{}'); }
    }).catch(error => { response.statusCode = 500; response.end(JSON.stringify({ error: error.message })); });
  });
  const port = await listen(lan), discoveryPort = await udpPort();
  relay = createTimecodeLanRelay({ nativeBridgePort: nativePort, discoveryPort,
    instanceId: id, getDirectorPort: () => port, getDirectDiscoveryAddresses: () => [],
    getDeviceName: () => id === A ? 'PC A' : 'PC B',
    getProjectSyncStagingDir: () => { throw new Error('Controls-only relay must not request disk access'); },
  });
  await relay.start();
  return { state, commands, inbox, events, wire, requests, receipts, port, discoveryPort,
    get connected() { return connected; },
    set inboxAvailable(value) { inboxAvailable = value; },
    set nativeHealth(value) { nativeHealth = value; },
    stopRelay() { return relay.stop(); },
    async stop() { await relay.stop(); await close(lan); await close(native); },
  };
}

async function pairPeers(a, b, socket) {
  const offer = Buffer.from(JSON.stringify({ magic: 'VSHOOK_TIMECODE_OFFER_V1', version: 3,
    code: '123456', transmitterId: A, receiverId: B, receiverName: 'PC B',
    port: b.port, projectSyncRole: 'secondary' }));
  // Discovery repeats on the real LAN; a single UDP offer can precede the
  // relay's first status poll and is not guaranteed to be consumed.
  const send = () => socket.send(offer, a.discoveryPort, '127.0.0.1');
  const timer = setInterval(send, 250);
  try {
    send();
    await until(() => a.connected && b.connected, 'v3 peers did not pair');
  } finally { clearInterval(timer); }
}

async function receiverCases() {
  const b = await peer(B, 'secondary');
  const pairing = { mode: 'project_sync', protocolVersion: 3, projectSyncRole: 'primary',
    code: '123456', transmitterId: A, sessionId: `session-${A}`, eventSequence: 0 };
  try {
    const capabilities = await post(b.port, '/timecode-link/capabilities');
    assert.equal(capabilities.data.projectSyncProtocolVersion, 3);
    assert.equal(capabilities.data.projectSyncControlsOnly, true);
    assert.equal(capabilities.data.projectSyncPreflight, false);
    assert.equal(capabilities.data.projectSyncFileTransfer, false);
    assert.equal((await post(b.port, '/timecode-link/pair', { ...pairing, code: '999999' })).status, 403);
    assert.equal((await post(b.port, '/timecode-link/pair', { ...pairing, protocolVersion: 2 })).status, 426);
    assert.equal((await post(b.port, '/timecode-link/pair', { ...pairing, projectSyncRole: 'secondary' })).status, 409);
    const paired = await post(b.port, '/timecode-link/pair', pairing);
    assert.equal(paired.status, 200);
    assert.equal(paired.data.ready, true, 'different or missing projects must not gate pairing');
    assert.equal(paired.data.applyToken, undefined);
    assert(!b.commands.some(command => command.type === 'project_sync_preflight'));
    assert.equal(b.inbox.length, 0, 'pairing while A plays must not start or seek B');
    const token = paired.data.token;
    const envelope = { ...pairing, token };
    const forbidden = [ 'project_sync_live_item_upsert', 'project_sync_live_item_state',
      'project_sync_live_track_upsert', 'project_sync_live_timeline', 'project_sync_live_resync',
      'project_sync_manifest_snapshot', 'project_sync_prepare_bundle', 'project_sync_apply_bundle',
      'project_sync_config_snapshot', 'playlist_snapshot_sync', 'project_select',
      'teleprompt_create_chord_item', 'teleprompt_create_cifra_item', 'teleprompt_cf', 'unknown_future_mutation',
      'project_sync_viewport_v1', 'mixer_viewport_set', 'timecode_transport_sync' ];
    const incoming = forbidden.map((type, index) => ({ sequence: index+1,
      command: { type, path: '/secret/new.wav', contents: 'must-not-cross' } }));
    incoming.push({ sequence: 20, command: { type: 'play_start' } });
    const received = await post(b.port, '/timecode-link/events', { ...envelope, events: incoming,
      manifestSnapshot: { manifest: 'must-not-apply', manifestRevision: 'new' } });
    assert.equal(received.data.acceptedSequence, 20);
    assert.deepEqual(b.inbox.map(command => command.type), ['play_start']);
    assert.equal((await post(b.port, '/timecode-link/events', { ...envelope, token: 'invalid' })).status, 403);
    b.state.manifest = ''; b.state.manifestRevision = ''; b.state.structuralManifestRevision = 'changed';
    await delay(30);
    const selection = await post(b.port, '/timecode-link/events', { ...envelope,
      events: [{ sequence: 21, command: { type: 'select_region', index: 3 } }] });
    assert.equal(selection.status, 200, 'project edits must not unpair controls');
    assert.equal(b.inbox.at(-1).type, 'select_region');
    for (const route of ['preflight', 'project-sync/bundle/manifest', 'project-sync/bundle/file',
      'project-sync/bundle/consumed', 'project-sync/bundle/unknown']) {
      assert.equal((await post(b.port, `/timecode-link/${route}`, envelope)).status, 410);
    }
    assert(!b.requests.some(route => /project-sync|preflight|bundle/.test(route)), 'no local transfer/preflight requests');
    const transport = { sequence: 1, controlSequence: 0, playState: 1, position: 10,
      sampledAtMs: 1000, audioHealthy: true };
    const beforeFailure = b.inbox.length;
    await post(b.port, '/timecode-link/events', { ...envelope, transport });
    assert.equal(b.inbox.length, beforeFailure, 'healthy transport samples must not move or restart B');
    await post(b.port, '/timecode-link/events', { ...envelope, audioHealthy: false,
      transport: { ...transport, sequence: 2, playState: 0, audioHealthy: false } });
    assert.equal(b.inbox.length, beforeFailure, 'device failure must not stop backup');
    await post(b.port, '/timecode-link/events', { ...envelope, audioHealthy: false,
      transport: { ...transport, sequence: 3, controlSequence: 1, playState: 0,
        audioHealthy: false, explicitControl: true } });
    assert.equal(b.inbox.length, beforeFailure, 'even explicit snapshot flags cannot bypass commands-only sync');
    await post(b.port, '/timecode-link/events', { ...envelope, audioHealthy: false,
      events: [{ sequence: 22, command: { type: 'play_stop' } }] });
    assert.equal(b.inbox.at(-1).type, 'play_stop', 'manual Stop command still crosses a device failure');
    b.inboxAvailable = false;
    const retryPlay = { ...envelope, events: [{ sequence: 23, command: { type: 'play_start' } }] };
    assert.equal((await post(b.port, '/timecode-link/events', retryPlay)).status, 503);
    b.inboxAvailable = true;
    assert.equal((await post(b.port, '/timecode-link/events', retryPlay)).status, 200);
    assert.equal(b.inbox.at(-1).type, 'play_start', 'failed native delivery must not consume manual Play');
    const explicitParts = { ...envelope,
      events: [{ sequence: 24, command: { type: 'marker_go', markerId: 'm7', markerLabel: 'Chorus' } }] };
    await post(b.port, '/timecode-link/events', explicitParts);
    await post(b.port, '/timecode-link/events', explicitParts);
    assert.equal(b.inbox.filter(command => command.type === 'marker_go').length, 1,
      'explicit Parts must cross exactly once, including packet retry');
    const beforeHandover = b.inbox.length;
    const requestId = 'c'.repeat(32);
    const handover = await post(b.port, '/timecode-link/project-sync/handover', { ...envelope,
      requestId, sourceSessionId: pairing.sessionId, receiverSessionId: b.state.sessionId });
    assert.equal(handover.status, 200);
    assert(b.commands.some(command => command.type === 'project_sync_role_handover' && command.role === 'primary'));
    assert.equal(b.inbox.length, beforeHandover, 'handover must not inject transport');
    assert.equal((await post(b.port, '/timecode-link/events', envelope)).status, 403);
    console.log('PROJECT_SYNC_CONTROLS_RECEIVER_OK: no project/cursor/transport snapshots, manual Play/Stop/Parts, retry and handover');
  } finally { await b.stop(); }
}

async function outboundCases() {
  const a = await peer(A, 'primary'), b = await peer(B, 'secondary');
  const socket = dgram.createSocket('udp4');
  try {
    await pairPeers(a, b, socket);
    await delay(60);
    assert.equal(b.inbox.length, 0, 'pairing with running transport must leave B untouched');
    const pairRequest = b.wire.find(packet => packet.path.endsWith('/pair'));
    assert(pairRequest);
    for (const key of ['manifest', 'manifestRevision', 'structuralManifestRevision', 'requestId']) {
      assert.equal(pairRequest.body[key], undefined, `${key} leaked into controls-only handshake`);
    }
    a.events.push({ sequence: 1, command: { type: 'project_sync_live_item_upsert', path: '/added.wav' } },
      { sequence: 2, command: { type: 'play_start' } },
      { sequence: 3, command: { type: 'project_sync_config_snapshot', project: 'do not transfer' } });
    a.state.eventSequence = 3;
    await until(() => b.inbox.some(command => command.type === 'play_start'), 'play control did not cross');
    a.state.manifest = 'changed by adding audio on PC A'; a.state.manifestRevision = 'new';
    a.state.structuralManifestRevision = 'new-structure';
    a.events.push({ sequence: 4, command: { type: 'select_region', index: 4 } });
    a.state.eventSequence = 4;
    await until(() => b.inbox.some(command => command.type === 'select_region'), 'legacy discarded events pinned outbox');
    a.events.push({ sequence: 5, command: { type: 'project_sync_live_item_upsert', path: '/another.wav' } });
    a.state.eventSequence = 5;
    await delay(100);
    a.events.push({ sequence: 6, command: { type: 'play_stop' } });
    a.state.eventSequence = 6;
    await until(() => b.inbox.some(command => command.type === 'play_stop'), 'fully discarded batch pinned outbox');
    a.events.push({ sequence: 7, command: { type: 'auto_set', enabled: true } },
      { sequence: 8, command: { type: 'queue_region_song', targetId: 'r2' } },
      { sequence: 9, command: { type: 'marker_go', markerId: 'm9', markerLabel: 'Bridge' } },
      { sequence: 10, command: { type: 'edit_cursor_move', position: 120 } },
      { sequence: 11, command: { type: 'project_sync_viewport_v1', arrangeStart: 120 } },
      { sequence: 12, command: { type: 'timecode_transport_sync', playState: 1, position: 120 } },
      { sequence: 13, command: { type: 'mixer_viewport_set', arrangeStart: 120, arrangeEnd: 240 } });
    a.state.eventSequence = 13;
    await until(() => b.inbox.some(command => command.type === 'marker_go'), 'explicit Parts must cross A to B');
    assert(b.inbox.some(command => command.type === 'auto_set'));
    assert(b.inbox.some(command => command.type === 'queue_region_song'));
    await until(() => b.inbox.some(command => command.type === 'edit_cursor_move'), 'stopped grid cursor must cross');
    assert.equal(b.inbox.find(command => command.type === 'edit_cursor_move').position, 120);
    const beforeAutoJump = b.inbox.length;
    const beforeHeartbeat = b.wire.filter(packet => packet.path.endsWith('/events')).length;
    // A reaches its queued song first. B may still be finishing its own region;
    // neither the Auto transition nor later cursor samples can issue another Play.
    a.state.transport = { ...a.state.transport, sequence: 2, controlSequence: 1,
      playState: 1, position: 360, sampledAtMs: 2000 };
    await until(() => b.wire.filter(packet => packet.path.endsWith('/events')).length > beforeHeartbeat,
      'controls-only heartbeat did not arrive');
    assert.equal(b.inbox.length, beforeAutoJump, 'Auto/queue jump on A must not replay or seek B');
    a.state.transport = { ...a.state.transport, sequence: 3, controlSequence: 2,
      playState: 0, position: 0, audioHealthy: false };
    await delay(450);
    assert.equal(b.inbox.length, beforeAutoJump, 'device Stop/cursor movement must not affect B');
    b.inboxAvailable = false;
    const previousInboxRequests = b.requests.filter(route => route === '/timecode/inbox').length;
    a.events.push({ sequence: 14, command: { type: 'play_stop', manualTestId: 'retry-stop' } });
    a.state.eventSequence = 14;
    await until(() => b.requests.filter(route => route === '/timecode/inbox').length > previousInboxRequests,
      'explicit stop was not attempted while device was unavailable');
    b.inboxAvailable = true;
    await until(() => b.inbox.some(command => command.type === 'play_stop' &&
      command.manualTestId === 'retry-stop'), 'sender lost manual stop after retry');
    assert(a.connected && b.connected, 'editing PC A must not invalidate the pair');
    const packets = b.wire.filter(packet => packet.path.endsWith('/events'));
    assert(packets.length > 0);
    for (const packet of packets) {
      assert.equal(packet.body.manifestSnapshot, undefined);
      assert.equal(packet.body.manifestRevision, undefined);
      assert.equal(packet.body.transport, undefined, 'Project Sync must not send cursor or transport snapshots');
      assert(packet.body.events.every(event => ['play_start', 'select_region', 'play_stop',
        'auto_set', 'queue_region_song', 'marker_go', 'edit_cursor_move'].includes(event.command.type)));
    }
    assert(!b.wire.some(packet => /preflight|bundle/.test(packet.path)));
    assert(!b.inbox.some(command => /upsert|snapshot|viewport|transport_sync/.test(command.type)));
    assert.equal(b.inbox.filter(command => command.type === 'play_start').length, 1);
    assert.equal(b.inbox.filter(command => command.type === 'marker_go').length, 1);
    console.log('PROJECT_SYNC_CONTROLS_OUTBOUND_OK: independent queue/Auto, manual Parts, stopped cursor selection, no pulse sync, reliable command ACK');
  } finally {
    socket.close(); await a.stop(); await b.stop();
  }
}

async function traditionalReceiverCase() {
  const b = await peer(B, 'secondary', 'receive');
  try {
    const payload = { code: '123456', mode: 'transmitter', protocolVersion: 1,
      transmitterId: A, sessionId: `session-${A}`, eventSequence: 0 };
    const paired = await post(b.port, '/timecode-link/pair', payload);
    assert.equal(paired.status, 200, 'traditional Timecode v1 pairing must remain available');
    const result = await post(b.port, '/timecode-link/events', { ...payload, token: paired.data.token,
      events: [{ sequence: 1, command: { type: 'mixer_set_volume', trackIndex: 1, volume: 0.5 } },
        { sequence: 2, command: { type: 'project_sync_live_item_upsert', path: '/not-allowed.wav' } },
        { sequence: 3, command: { type: 'edit_cursor_move', position: 20 } }],
      transport: { sequence: 1, playState: 1, position: 20, sampledAtMs: 1000 } });
    assert.equal(result.status, 200);
    assert.deepEqual(b.inbox.map(command => command.type), ['mixer_set_volume', 'edit_cursor_move', 'timecode_transport_sync']);
    assert.equal(result.data.acceptedSequence, 3);
    console.log('TIMECODE_V1_CONTROLS_COMPATIBILITY_OK: mixer, transport and blocked legacy file mutation');
  } finally { await b.stop(); }
}

async function timingCases() {
  const a = await peer(A, 'primary'), b = await peer(B, 'secondary');
  const socket = dgram.createSocket('udp4');
  try {
    await pairPeers(a, b, socket);
    const samples = { play: [], stop: [] };
    let sequence = 0;
    for (let i = 0; i < 40; ++i) {
      // Vary the phase relative to the relay timer; include cursor immediately
      // before Play, exactly as a fast grid-click/Space gesture is published.
      await delay((i * 7) % 21);
      for (const kind of ['play', 'stop']) {
        const id = `${kind}-${i}`;
        if (kind === 'play') a.events.push({ sequence: ++sequence,
          command: { type: 'edit_cursor_move', position: 123.456 + i, noSeek: true, timingId: `cursor-${i}` } });
        const sent = performance.now();
        a.events.push({ sequence: ++sequence,
          command: { type: kind === 'play' ? 'play_start' : 'play_stop', timingId: id } });
        a.state.eventSequence = sequence;
        await until(() => b.receipts.some(receipt => receipt.command.timingId === id), `${id} was lost`);
        const received = b.receipts.find(receipt => receipt.command.timingId === id);
        samples[kind].push(received.at - sent);
        if (kind === 'play') {
          const index = b.inbox.findIndex(command => command.timingId === id);
          assert.equal(b.inbox[index - 1].timingId, `cursor-${i}`, 'cursor must arrive before Play');
        }
      }
    }
    assert.equal(b.inbox.length, 120, '40 cursor/Play/Stop gestures must arrive exactly once');
    const summary = {};
    for (const [kind, values] of Object.entries(samples)) {
      const sorted = [...values].sort((a, b) => a - b);
      summary[kind] = { count: values.length, p50Ms: +sorted[19].toFixed(2),
        p95Ms: +sorted[37].toFixed(2), maxMs: +sorted.at(-1).toFixed(2) };
      assert(sorted.at(-1) < 1000, `${kind} relay stalled for over a second on loopback`);
    }
    console.log('PROJECT_SYNC_RELAY_TIMING_LOOPBACK ' + JSON.stringify(summary));
  } finally { socket.close(); await a.stop(); await b.stop(); }
}

async function failoverCases() {
  const a = await peer(A, 'primary'), b = await peer(B, 'secondary');
  const socket = dgram.createSocket('udp4');
  try {
    await pairPeers(a, b, socket);
    a.events.push({ sequence: 1, command: { type: 'play_start' } });
    a.state.eventSequence = 1;
    await until(() => b.inbox.some(command => command.type === 'play_start'), 'initial Play did not reach B');
    const baseline = b.inbox.length;
    // Device loss can either stop or freeze A. Neither is an operator's Stop.
    for (const playState of [0, 1]) {
      a.state.transport = { ...a.state.transport, sequence: a.state.transport.sequence + 1,
        controlSequence: 999, playState, audioHealthy: false, position: 0 };
      await delay(450);
      assert.equal(b.inbox.length, baseline, `audio loss (state ${playState}) injected a command into B`);
    }
    for (const fault of ['closed', 'crashed', 'hung']) {
      a.nativeHealth = fault;
      await until(() => !b.connected, `${fault}: B never noticed the lost peer`, 12000);
      assert.equal(b.inbox.length, baseline, `${fault}: losing A changed B's transport`);
      assert(b.commands.every(command => command.type === 'timecode_peer_status'),
        `${fault}: failure generated an operational command outside the inbox`);
      // The restarted A is stopped, with a fresh event sequence. Pairing must
      // not stop, replay or reposition the B that continued on its own.
      a.state.sessionId += '-restart';
      a.state.eventSequence = 0;
      a.events.length = 0;
      a.state.transport = { sequence: 1, controlSequence: 1, playState: 0,
        audioHealthy: true, position: 0, sampledAtMs: Date.now() };
      a.nativeHealth = 'online';
      await delay(600);
      await pairPeers(a, b, socket);
      await delay(450);
      assert.equal(b.inbox.length, baseline, `${fault}: reconnecting a stopped A changed B's transport`);
    }
    await a.stopRelay();
    await until(() => !b.connected, 'Hook Center shutdown was not noticed by B', 12000);
    assert.equal(b.inbox.length, baseline, 'closing Hook Center on A must not stop B');
    console.log('PROJECT_SYNC_FAILOVER_OK: audio loss/freeze, REAPER close/crash/hang, stopped-A reconnect and Hook Center shutdown never send Stop to B');
  } finally {
    a.nativeHealth = 'online';
    socket.close(); await a.stop(); await b.stop();
  }
}

(async () => { await receiverCases(); await outboundCases(); await traditionalReceiverCase(); await timingCases(); await failoverCases(); })().catch(error => {
  console.error(error); process.exitCode = 1;
});
