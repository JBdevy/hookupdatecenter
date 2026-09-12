const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
const net = require('node:net');
const { selectAppNetwork, appNetworkSignature } = require('../src/bridge-network');

const wifi = (ip, name = 'Wi-Fi') => ({ name, ip, score: 100 });
const ethernet = { name: 'Ethernet', ip: '192.168.1.10', score: 70 };
let config = { preferredNetworkName: 'Wi-Fi', preferredNetworkIp: '192.168.1.10' };
let networks = [wifi('10.0.0.20'), ethernet];
assert.equal(selectAppNetwork(networks, config).selected.ip, '10.0.0.20');
assert.equal(selectAppNetwork([ethernet], config).selected.waitingForConnection, true);
assert.equal(selectAppNetwork([], config).selected.name, 'Wi-Fi');
assert.equal(selectAppNetwork([], config).selected.ip, '127.0.0.1');
assert.equal(selectAppNetwork([ethernet], {}).selected.name, 'Ethernet');
assert.equal(selectAppNetwork([ethernet], {}, [ethernet.ip]).networks.length, 0);
assert.equal(selectAppNetwork([wifi('10.1.2.3', 'en0')],
  { preferredNetworkName: 'en0', preferredNetworkIp: '192.168.3.2' }).selected.ip, '10.1.2.3');
assert.equal(appNetworkSignature(selectAppNetwork(networks, config)),
  appNetworkSignature(selectAppNetwork([...networks].reverse(), config)));

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const notifications = [];
let setters = 0;
let restarts = 0;
let writes = 0;
const server = { publicBridgeHost: '192.168.1.10',
  setPublicBridgeHost(ip) { this.publicBridgeHost = ip; setters += 1; } };
const context = vm.createContext({
  selectAppNetwork, appNetworkSignature,
  readBridgeConfig: () => ({ ...config }),
  saveBridgeConfig: (next) => { config = { ...config, ...next }; writes += 1; },
  getAllLanIps: () => networks,
  getDirectCableChannelIp: () => '',
  isValidWindow: () => true,
  mainWindow: { webContents: { send: (name, payload) => notifications.push({ name, payload }) } },
  getChatMobileBootstrapSecret: () => 'fixture-only', getBridgeAppCacheVersion: () => 'fixture',
  resolveBridgeScriptsDir: () => 'fixture-only',
  startBridgeServers: async () => { restarts += 1; },
  bridgeConfig: null, bridgeNetworkSignature: '', bridgeServers: [server],
  bridgeInfos: [{ port: 47831 }], bridgeLastError: ''
});
vm.runInContext(source.slice(source.indexOf('function getSelectedBridgeNetwork('),
  source.indexOf('function resolveBridgeScriptsDir(')), context);
vm.runInContext(source.slice(source.indexOf('async function ensureBridgeServersRunning('),
  source.indexOf('function getLyricsDefaults(')), context);

async function testCoordinator() {
  // Opening a status view before the watcher must not swallow the event.
  const state = context.getBridgeState();
  assert.equal(state.lanIp, '10.0.0.20');
  assert.equal(server.publicBridgeHost, '10.0.0.20');
  context.refreshBridgeNetwork();
  assert.equal(notifications.length, 1);
  const firstSetterCount = setters;
  for (let i = 0; i < 100; i += 1) context.refreshBridgeNetwork();
  assert.equal(notifications.length, 1);
  assert.equal(setters, firstSetterCount);
  assert.equal(writes, 0);
  networks = [ethernet];
  context.refreshBridgeNetwork();
  const offline = notifications.at(-1).payload;
  assert.equal(offline.waitingForSelectedNetwork, true);
  assert.equal(offline.networkAvailable, false);
  assert.equal(offline.selectedNetworkName, 'Wi-Fi');
  assert.equal(config.preferredNetworkName, 'Wi-Fi');
  assert.equal(server.publicBridgeHost, '127.0.0.1');
  networks = [wifi('172.16.2.9'), ethernet];
  context.refreshBridgeNetwork();
  assert.equal(server.publicBridgeHost, '172.16.2.9');
  assert.equal(notifications.at(-1).payload.networkAvailable, true);
  await context.selectBridgeNetwork({ ip: ethernet.ip });
  assert.equal(config.preferredNetworkName, 'Ethernet');
  assert.equal(server.publicBridgeHost, ethernet.ip);
  assert.equal(restarts, 0);
  assert.equal(writes, 1);
  await assert.rejects(context.selectBridgeNetwork({ ip: '10.99.99.99' }), /disponível/);
  // A newly-created server after an explicit restart receives current choice.
  server.publicBridgeHost = 'stale-startup-address';
  context.getBridgeState();
  assert.equal(server.publicBridgeHost, ethernet.ip);
}

async function testHttp() {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-network-test-'));
  const originalInterfaces = os.networkInterfaces;
  os.networkInterfaces = () => ({ 'Wi-Fi': [{ family: 'IPv4', internal: false, address: '10.0.0.20' }] });
  const { createBridgeServer } = require('../src/bridge-server');
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  const bridge = createBridgeServer({ host: '127.0.0.1', port, appName: 'Test',
    sharedDir: temporary, appDir: temporary, publicBridgeHost: '10.0.0.20',
    getDeviceName: () => 'PC PALCO A', isLicenseActive: () => false });
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  const sockets = [];
  const request = (route) => new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: route, agent }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve(body));
    });
    req.on('socket', (socket) => sockets.push(socket));
    req.on('error', reject);
  });
  try {
    await bridge.start();
    const initialDiscovery = JSON.parse(await request('/discovery'));
    assert.equal(initialDiscovery.host, '10.0.0.20');
    assert.equal(initialDiscovery.deviceName, 'PC PALCO A');
    assert.equal(initialDiscovery.computerName, 'PC PALCO A');
    assert.equal(initialDiscovery.reaperOnline, false);
    const firstQr = await request('/qr.svg');
    os.networkInterfaces = () => ({ 'Wi-Fi': [{ family: 'IPv4', internal: false, address: '192.168.8.12' }] });
    bridge.setPublicBridgeHost('192.168.8.12');
    const moved = JSON.parse(await request('/discovery'));
    assert.equal(moved.host, '192.168.8.12');
    assert.equal(moved.publicUrl, `http://192.168.8.12:${port}`);
    assert.deepEqual(moved.hosts, ['192.168.8.12']);
    assert.notEqual(await request('/qr.svg'), firstQr);
    bridge.setPublicBridgeHost('127.0.0.1');
    const offline = JSON.parse(await request('/discovery'));
    assert.equal(offline.networkAvailable, false);
    assert.deepEqual(offline.hosts, []);
    bridge.setPublicBridgeHost('192.168.8.12');
    assert.equal(JSON.parse(await request('/discovery')).host, '192.168.8.12');
    assert(sockets.every((socket) => socket === sockets[0]), 'same HTTP socket survives every address update');
  } finally {
    agent.destroy();
    await bridge.stop();
    os.networkInterfaces = originalInterfaces;
    if (path.dirname(temporary) !== path.resolve(os.tmpdir()) || !path.basename(temporary).startsWith('hook-network-test-')) {
      throw new Error('Unsafe fixture cleanup path');
    }
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function testUi() {
  const renderer = fs.readFileSync(path.join(__dirname, '../src/renderer.js'), 'utf8');
  class Element {
    constructor() {
      this.dataset = {};
      this.children = [];
      this.classes = new Set();
      this.srcWrites = 0;
      this.classList = {
        toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
        add: (name) => this.classes.add(name), remove: (name) => this.classes.delete(name)
      };
    }
    set innerHTML(value) { this.children = []; }
    set src(value) { this.source = value; this.srcWrites += 1; }
    removeAttribute(name) { if (name === 'src') this.source = ''; }
    append(...items) { this.children.push(...items); }
    appendChild(item) { this.children.push(item); }
  }
  const elements = new Map(['bridgeRunningText', 'bridgeLanIp', 'browserQrImage',
    'bridgeDirectorPort', 'bridgeMusiciansPort', 'bridgeScriptsDir', 'bridgeNetworkOptions']
    .map((id) => ['#' + id, new Element()]));
  const ui = vm.createContext({ $: (id) => elements.get(id), currentBridgeState: null,
    document: { createElement: () => new Element() } });
  vm.runInContext(renderer.slice(renderer.indexOf('function renderBridgeState('),
    renderer.indexOf('async function openBridgeNetworkModal(')), ui);
  const active = { running: true, networkAvailable: true, lanIp: '10.0.0.20',
    selectedNetworkIp: '10.0.0.20', selectedNetworkName: 'Wi-Fi',
    directorPort: 47831, musiciansPort: 47832, lanIps: [wifi('10.0.0.20')],
    qrCodeUrl: 'http://10.0.0.20:47831/qr.svg?url=fixture' };
  ui.renderBridgeState(active);
  ui.renderBridgeState(active);
  const qr = elements.get('#browserQrImage');
  assert.equal(qr.srcWrites, 1);
  ui.renderBridgeState({ ...active, networkAvailable: false, waitingForSelectedNetwork: true,
    lanIp: '127.0.0.1', selectedNetworkIp: '127.0.0.1', lanIps: [ethernet] });
  assert(elements.get('#bridgeRunningText').textContent.includes('Wi-Fi'));
  assert(elements.get('#bridgeRunningText').textContent.includes('Sua escolha foi mantida'));
  assert.equal(elements.get('#bridgeLanIp').textContent, '--');
  assert(qr.classes.has('hidden'));
  assert.equal(qr.source, '');
  const options = elements.get('#bridgeNetworkOptions').children;
  assert.equal(options[0].children[0].textContent, 'Wi-Fi');
  assert.equal(options[0].disabled, true);
  assert.equal(options[1].children[0].textContent, 'Ethernet');
  ui.renderBridgeState(active);
  assert.equal(qr.srcWrites, 2);
  assert(!qr.classes.has('hidden'));
}

(async () => {
  await testCoordinator();
  await testHttp();
  testUi();
  assert(source.includes('bridgeNetworkWatchTimer = setInterval('));
  const renderer = fs.readFileSync(path.join(__dirname, '../src/renderer.js'), 'utf8');
  assert(renderer.includes('onBridgeStatus?.(renderBridgeState)'));
  console.log('BRIDGE_NETWORK_OK: Wi-Fi/en0 DHCP, absent adapter waits, manual choice, idle no writes/restarts/events, discovery + QR updated on same HTTP socket');
})().catch((error) => { console.error(error); process.exitCode = 1; });
