const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, shell, dialog, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const Store = require('electron-store');
const { spawn, execFile, execFileSync } = require('child_process');
const { pathToFileURL } = require('url');
const http = require('http');
const { createBridgeServer, getLanIp, getAllLanIps, ensureJsonFile } = require('./bridge-server');
const { createQrSvg } = require('./qr-svg');

const store = new Store({
  defaults: {
    currentVersion: app.getVersion(),
    hookCenterLatest: null,
    hookCenterUpdateAvailable: false,
    downloadedHookCenterUpdate: null,
    bridgeAppLatest: null,
    bridgeAppUpdateAvailable: false,
    bridgeAppInstalled: null,
    lastCheck: null,
    updateAvailable: false,
    latestUpdate: null,
    lastNotifiedUpdateId: null,
    downloadedFiles: null,
    installedManifest: null,
    license: {
      cpf: '',
      cnpj: '',
      document: '',
      email: '',
      machineId: '',
      active: false,
      devicesUsed: 0,
      maxDevices: 0,
      devices: [],
      lastStatusAt: null
    },
    deviceName: '',
    deviceLoginEmail: '',
    deviceLoginAt: null,
    autoStart: true,
    bridge: {
      scriptsDir: '',
      directorPort: 47831,
      musiciansPort: 47832,
      autoStart: true
    },
    lyrics: {
      textColor: '#ffea00',
      clockColor: '#00ff55',
      textCase: 'uppercase',
      fontFamily: 'Arial',
      clockEnabled: true
    }
  }
});

let mainWindow = null;
let tray = null;
let checkTimer = null;
let updateReminderTimer = null;
let bridgeServers = [];
let bridgeInfos = [];
let bridgeConfig = null;
let bridgeLastError = '';
let bridgeWatchTimer = null;
const lyricsWindows = new Map();

const BACKEND_URL = (process.env.BACKEND_URL || 'https://hookupdate7.up.railway.app').replace(/\/+$/, '');
const UPDATE_API_URL_BASE = `${BACKEND_URL}/api/v3/latest`;
const TEST_UPDATE_API_URL_BASE = `${BACKEND_URL}/api/latest`;
const HOOK_CENTER_API_URL = `${BACKEND_URL}/api/hookcenter/latest?platform=${getHookCenterPlatformKey()}`;
const BRIDGE_APP_API_URL = `${BACKEND_URL}/api/bridge-app/latest?platform=${getPlatformKey()}`;
const UPDATES_HISTORY_API_URL = `${BACKEND_URL}/api/updates?limit=50&platform=${getPlatformKey()}`;
const SUPPORT_API_URL = `${BACKEND_URL}/api/support`;
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const UPDATE_REMINDER_INTERVAL_MS = 20 * 60 * 1000;
const LICENSE_OFFLINE_GRACE_MS = 14 * 24 * 60 * 60 * 1000;
const LICENSE_OFFLINE_WARNING_MS = 3 * 24 * 60 * 60 * 1000;
const LICENSE_CLOCK_ROLLBACK_TOLERANCE_MS = 2 * 24 * 60 * 60 * 1000;

const LICENSE_PRODUCT = 'VSLIVE';
const LICENSE_SECRET_A = 'JBKeys_VSLIVE_CORE';
const LICENSE_SECRET_B = 'VSLIVE_2026_ONLINE';
const LICENSE_SECRET_C = 'JBK_ADMIN_OFFLINE';

function getAppIconPath() {
  const iconName = process.platform === 'win32' ? 'icon.ico' : 'icon.png';
  return path.join(__dirname, '..', 'assets', iconName);
}

if (process.platform === 'win32') {
  app.setAppUserModelId('com.hookdeveloper.hookcenter');
}

const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (app.isReady()) {
      showMainWindow();
    } else {
      app.whenReady().then(showMainWindow).catch(() => {});
    }
  });
}

function isValidWindow(win) {
  return !!win && !win.isDestroyed();
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 660,
    minWidth: 1180,
    minHeight: 620,
    show: false,
    backgroundColor: '#0b0b10',
    title: 'Hook Center',
    icon: getAppIconPath(),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      webviewTag: true
    }
  });

  Menu.setApplicationMenu(null);
  mainWindow.setMenuBarVisibility(false);
  mainWindow.loadFile(path.join(__dirname, 'index.html'));

  const win = mainWindow;

  win.on('close', (event) => {
    if (!app.isQuiting) {
      event.preventDefault();
      if (!win.isDestroyed()) win.hide();
    }
  });

  win.on('closed', () => {
    if (mainWindow === win) {
      mainWindow = null;
    }
  });
}


function getTrayIconImage() {
  const iconPath = path.join(__dirname, '..', 'assets', 'tray.png');
  let image = nativeImage.createFromPath(iconPath);

  if (image.isEmpty()) {
    image = nativeImage.createFromPath(getAppIconPath());
  }

  if (process.platform === 'darwin') {
    // No macOS, arquivo *Template.png pode virar silhueta/quadrado branco na menu bar.
    // Usa o icone real do Hook Center, pequeno e colorido.
    image = image.resize({ width: 18, height: 18 });
    image.setTemplateImage(false);
  }

  return image;
}

function createTray() {
  tray = new Tray(getTrayIconImage());
  tray.setToolTip('Hook Center');
  rebuildTrayMenu();

  tray.on('click', () => {
    showMainWindow();
  });
}

function rebuildTrayMenu() {
  const latest = store.get('latestUpdate');
  const updateText = latest?.version ? `Última publicação: ${latest.version}` : 'Atualizações: aguardando';
  const license = store.get('license') || {};
  const licenseText = license.active ? 'Licença: ativa' : 'Licença: pendente';
  const bridgeText = bridgeServers.length > 0 ? 'Conexão via app: ativa' : 'Conexão via app: parada';

  const menu = Menu.buildFromTemplate([
    { label: 'Hook Center', enabled: false },
    { label: updateText, enabled: false },
    { label: licenseText, enabled: false },
    { label: bridgeText, enabled: false },
    { type: 'separator' },
    { label: 'Abrir Central', click: showMainWindow },
    { label: 'Conferir atualização agora', click: () => checkForUpdates(true) },
    { label: 'Verificar licença agora', click: () => checkLicenseStatus(true) },
    { type: 'separator' },
    { label: 'Sair', click: () => { app.isQuiting = true; app.quit(); } }
  ]);
  tray.setContextMenu(menu);
}

function showMainWindow() {
  if (!app.isReady()) {
    app.whenReady().then(showMainWindow).catch(() => {});
    return;
  }

  if (!isValidWindow(mainWindow)) {
    mainWindow = null;
    createWindow();
  }

  if (!isValidWindow(mainWindow)) return;

  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}


function compareVersions(a, b) {
  const pa = String(a || '0').split(/[.-]/).map((n) => parseInt(n, 10) || 0);
  const pb = String(b || '0').split(/[.-]/).map((n) => parseInt(n, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i += 1) {
    if ((pa[i] || 0) > (pb[i] || 0)) return 1;
    if ((pa[i] || 0) < (pb[i] || 0)) return -1;
  }
  return 0;
}

async function getLatestUpdateApiUrl(options = {}) {
  const params = new URLSearchParams({ platform: getPlatformKey() });

  // Por padrão a aba Atualização consulta SOMENTE a publicação oficial.
  // Atualização direcionada de cliente teste só entra quando for consulta de Status.
  if (options.includeTestClient === true) {
    try {
      const machineId = await getMachineId();
      if (machineId) params.set('machineId', machineId);
    } catch (_) {}
    params.set('includeTest', '1');
    params.set('scope', 'status');
  } else {
    params.set('includeTest', '0');
    params.set('scope', 'official');
  }

  const baseUrl = options.includeTestClient === true ? TEST_UPDATE_API_URL_BASE : UPDATE_API_URL_BASE;
  return `${baseUrl}?${params.toString()}`;
}

function getInstalledVsHookVersion() {
  const installed = store.get('installedManifest') || {};
  if (installed.version) return installed.version;
  if (installed.updateId && store.get('currentVersion') && store.get('currentVersion') !== app.getVersion()) return store.get('currentVersion');
  return '';
}

function isUpdateInstalled(update) {
  const updateId = getPlatformUpdateId(update);
  const installed = store.get('installedManifest') || {};
  return !!updateId && installed.platform === getPlatformKey() && installed.updateId === updateId;
}

function hasPendingInstallableUpdate(update) {
  return !!(update && hasInstallableFiles(update) && !isUpdateInstalled(update));
}

function notifyPendingUpdate(force = false) {
  const update = store.get('latestUpdate');
  if (!hasPendingInstallableUpdate(update)) return false;
  const lastAt = Date.parse(store.get('lastUpdateReminderAt') || '');
  if (!force && Number.isFinite(lastAt) && Date.now() - lastAt < UPDATE_REMINDER_INTERVAL_MS) return false;
  notifyUpdate(update);
  store.set('lastUpdateReminderAt', new Date().toISOString());
  return true;
}

function notifyHookCenterUpdate(update) {
  if (!Notification.isSupported()) return;
  const n = new Notification({
    title: 'Nova versão do Hook Center disponível',
    body: `Versão ${update.version || ''} disponível. Clique para atualizar.`,
    silent: false
  });
  n.on('click', showMainWindow);
  n.show();
}

function notifyUpdate(update) {

  if (!Notification.isSupported()) return;
  const n = new Notification({
    title: update.title || 'Nova atualização do VS Hook disponível',
    body: `Versão ${update.version || ''} disponível. Clique para conferir.`,
    silent: false
  });
  n.on('click', showMainWindow);
  n.show();
}

function notifyLicense(message) {
  if (!Notification.isSupported()) return;
  new Notification({
    title: 'VS Hook',
    body: message,
    silent: false
  }).show();
}

function normalizeDocument(value) {
  return String(value || '').replace(/\D+/g, '');
}

function splitDocument(value) {
  const document = normalizeDocument(value);
  return {
    document,
    cpf: document.length === 11 ? document : '',
    cnpj: document.length === 14 ? document : ''
  };
}

function normalizeCpf(value) {
  return normalizeDocument(value);
}

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

function normalizeMachineId(value) {
  return String(value || '').trim().toUpperCase().replace(/\s+/g, '');
}

function simpleHash(str) {
  str = String(str || '');
  let h1 = 0x45D9;
  let h2 = 0x2710;

  for (let i = 1; i <= str.length; i += 1) {
    const b = str.charCodeAt(i - 1);
    h1 = (h1 ^ (b * i + 17)) & 0xFFFFFF;
    h2 = (h2 + ((b + (i - 1)) * 131)) & 0xFFFFFF;
    h1 = (h1 * 33 + h2) & 0xFFFFFF;
    h2 = (h2 * 17 + h1) & 0xFFFFFF;
  }

  const n = (((h1 << 12) >>> 0) + h2) >>> 0;
  return n.toString(16).toUpperCase().padStart(8, '0');
}

function generateExpectedLicense(machineId) {
  const normalized = normalizeMachineId(machineId);
  const a = simpleHash(`${normalized}|${LICENSE_PRODUCT}|${LICENSE_SECRET_A}`);
  const b = simpleHash(`${LICENSE_SECRET_B}|${normalized}|${a}`);
  const c = simpleHash(`${a}|${LICENSE_SECRET_C}|${normalized}|${b}`);
  return `${LICENSE_PRODUCT}-${a.slice(0, 4)}-${a.slice(4, 8)}-${b.slice(0, 4)}-${c.slice(0, 4)}`;
}

function runCapture(command, args = []) {
  return new Promise((resolve) => {
    execFile(command, args, { windowsHide: true, timeout: 8000 }, (error, stdout) => {
      if (error) return resolve('');
      resolve(String(stdout || '').replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim());
    });
  });
}

function getSharedMachineIdPath() {
  if (process.platform === 'win32') {
    const publicDir = process.env.PUBLIC || process.env.ALLUSERSPROFILE || 'C:\\Users\\Public';
    return path.join(publicDir, 'vslive_machine_id.dat');
  }
  if (process.platform === 'darwin') {
    return '/Users/Shared/.vslive_machine_id';
  }
  return path.join(os.homedir(), '.vslive_machine_id');
}

function getSharedLicensePath() {
  if (process.platform === 'win32') {
    const programData = process.env.PROGRAMDATA || process.env.ProgramData || 'C:\\ProgramData';
    return path.join(programData, 'HookDeveloper', 'VSCore', 'sys_runtime.dat');
  }
  if (process.platform === 'darwin') {
    return '/Library/Application Support/HookDeveloper/VSCore/sys_runtime.dat';
  }
  return path.join(os.homedir(), '.hookdeveloper', 'vscore', 'sys_runtime.dat');
}

function getLegacyLicensePaths() {
  const paths = [
    path.join(os.homedir(), '.vshook_license.json')
  ];

  if (process.platform === 'win32') {
    const publicDir = process.env.PUBLIC || process.env.ALLUSERSPROFILE || 'C:\\Users\\Public';
    paths.push(path.join(publicDir, 'vshook_license.json'));
  } else if (process.platform === 'darwin') {
    paths.push('/Users/Shared/.vshook_license.json');
  }

  return paths;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function writeFileWithPrivilegeIfNeeded(filePath, content) {
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, content, 'utf8');
    return;
  } catch (error) {
    if (process.platform !== 'darwin') throw error;
  }

  const encoded = Buffer.from(content, 'utf8').toString('base64');
  const dir = path.dirname(filePath);
  const command = [
    'mkdir -p', shellQuote(dir),
    '&&',
    'printf', shellQuote(encoded),
    '| base64 -D >', shellQuote(filePath),
    '&& chmod 644', shellQuote(filePath)
  ].join(' ');

  try {
    execFileSync('osascript', [
      '-e',
      `do shell script ${JSON.stringify(command)} with administrator privileges`
    ], { stdio: 'ignore' });
  } catch (_) {
    throw new Error('Não foi possível concluir a operação. Tente novamente.');
  }
}

function removeFileWithPrivilegeIfNeeded(filePath) {
  try {
    fs.rmSync(filePath, { force: true });
    if (!fs.existsSync(filePath)) return;
  } catch (_) {}

  if (process.platform === 'darwin') {
    try {
      const command = `rm -f ${shellQuote(filePath)}`;
      execFileSync('osascript', [
        '-e',
        `do shell script ${JSON.stringify(command)} with administrator privileges`
      ], { stdio: 'ignore' });
    } catch (_) {}
  }
}

async function getWindowsAnchor() {
  const probes = [
    ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "(Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' -Name MachineGuid).MachineGuid"]],
    ['reg.exe', ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid']],
    ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', '(Get-CimInstance Win32_ComputerSystemProduct).UUID']],
    ['wmic.exe', ['csproduct', 'get', 'uuid']]
  ];

  for (const [cmd, args] of probes) {
    const raw = await runCapture(cmd, args);
    const guid = raw.match(/([0-9A-Fa-f-][0-9A-Fa-f-]+)/);
    if (guid?.[1]) return normalizeMachineId(guid[1]);
  }
  return '';
}

async function getMacAnchor() {
  const probes = [
    ['/bin/sh', ['-c', `ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/ {print $(NF-1)}'`]],
    ['/bin/sh', ['-c', `system_profiler SPHardwareDataType | awk -F': ' '/Hardware UUID/ {print $2}'`]]
  ];

  for (const [cmd, args] of probes) {
    const raw = await runCapture(cmd, args);
    const guid = raw.match(/([0-9A-Fa-f-][0-9A-Fa-f-]+)/);
    if (guid?.[1]) return normalizeMachineId(guid[1]);
  }
  return '';
}

async function getMachineId() {
  const machinePath = getSharedMachineIdPath();
  try {
    const cached = normalizeMachineId(fs.readFileSync(machinePath, 'utf8'));
    if (/^[0-9A-F]+$/.test(cached)) return cached;
  } catch (_) {}

  let anchor = '';
  if (process.platform === 'win32') anchor = await getWindowsAnchor();
  if (process.platform === 'darwin') anchor = await getMacAnchor();
  if (!anchor) anchor = normalizeMachineId(os.hostname() || 'UNKNOWNHOST');

  const machineId = simpleHash(`${LICENSE_PRODUCT}|${anchor}`);
  try {
    fs.mkdirSync(path.dirname(machinePath), { recursive: true });
    fs.writeFileSync(machinePath, machineId, 'utf8');
  } catch (_) {}

  return machineId;
}


function getStoredDeviceName() {
  return String(store.get('deviceName') || '').trim()
}

function saveStoredDeviceName(name) {
  const value = String(name || '').trim().replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ')
  if (!value) throw new Error('Escolha um nome para este dispositivo.')
  store.set('deviceName', value)
  return value
}

async function loginLicenseDevices(email) {
  const license = store.get('license') || {}
  const machineId = normalizeMachineId(license.machineId || await getMachineId())
  const cleanEmail = normalizeEmail(email || license.email || store.get('deviceLoginEmail'))
  if (!cleanEmail || !cleanEmail.includes('@')) throw new Error('Digite o e-mail usado na compra.')
  const result = await fetchJson(`${BACKEND_URL}/api/license/login`, {
    method: 'POST',
    body: JSON.stringify({ email: cleanEmail, machineId, platform: process.platform, computerName: getStoredDeviceName() })
  })
  const nextLicense = {
    ...license,
    email: result.email || cleanEmail,
    machineId,
    active: !!result.active,
    devicesUsed: result.devicesUsed ?? license.devicesUsed ?? 0,
    maxDevices: result.maxDevices ?? license.maxDevices ?? 0,
    devices: Array.isArray(result.devices) ? result.devices : [],
    message: result.message || '',
    warning: result.warning || '',
    reason: result.reason || '',
    lastStatusAt: new Date().toISOString()
  }
  store.set('deviceLoginEmail', result.email || cleanEmail)
  store.set('deviceLoginAt', new Date().toISOString())
  store.set('license', nextLicense)
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState())
  return { ok:true, result, state:getAppState() }
}

async function removeLicenseDevice(removeMachineId, emailOverride = '') {
  const license = store.get('license') || {}
  const machineId = normalizeMachineId(license.machineId || await getMachineId())
  const cleanEmail = normalizeEmail(emailOverride || license.email || store.get('deviceLoginEmail'))
  if (!cleanEmail) throw new Error('Digite o e-mail usado na compra.')
  const result = await fetchJson(`${BACKEND_URL}/api/license/remove-device`, {
    method: 'POST',
    body: JSON.stringify({ email: cleanEmail, machineId, removeMachineId, platform: process.platform, computerName: getStoredDeviceName() })
  })
  const nextLicense = {
    ...license,
    email: result.email || cleanEmail,
    machineId,
    active: !!result.active,
    devicesUsed: result.devicesUsed ?? license.devicesUsed ?? 0,
    maxDevices: result.maxDevices ?? license.maxDevices ?? 0,
    devices: Array.isArray(result.devices) ? result.devices : [],
    message: result.message || '',
    warning: result.warning || '',
    reason: result.reason || '',
    lastStatusAt: new Date().toISOString()
  }
  const removedCurrentDevice = normalizeMachineId(removeMachineId) === machineId || !nextLicense.active;
  if (removedCurrentDevice) {
    nextLicense.active = false;
    nextLicense.message = result.message || 'Este computador foi removido da licença.';
    removeLocalLicense();
  }
  store.set('license', nextLicense)
  rebuildTrayMenu();
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState())
  return { ok:true, result, state:getAppState() }
}


const LICENSE_SHARD_FILES = [
  'rdp_7C4A19.tmp',
  '.hcx_91f0b2.cache',
  'msidx_0E31C4.bin'
];

function getSharedLicenseDir() {
  return path.dirname(getSharedLicensePath());
}

function normalizeLicenseKeyForFile(value) {
  return String(value || '').trim().toUpperCase().replace(/\s+/g, '');
}

function licenseStreamByte(machineId, index) {
  const mid = normalizeMachineId(machineId);
  const h = simpleHash(`${LICENSE_SECRET_A}|${mid}|${LICENSE_SECRET_B}|${index}|${LICENSE_SECRET_C}`);
  return h.charCodeAt((index - 1) % h.length);
}

function encryptedLicenseHex(plainText, machineId) {
  const input = Buffer.from(String(plainText || ''), 'utf8');
  let out = '';
  for (let i = 0; i < input.length; i += 1) {
    const value = (input[i] ^ licenseStreamByte(machineId, i + 1)) & 0xFF;
    out += value.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

function splitEncryptedLicense(hexText) {
  const parts = ['', '', ''];
  const clean = String(hexText || '').replace(/[^0-9A-F]/gi, '').toUpperCase();
  for (let i = 0; i < clean.length; i += 1) {
    parts[i % 3] += clean[i];
  }
  return parts;
}

function protectedLicenseShardsExist() {
  try {
    const licenseDir = getSharedLicenseDir();
    return LICENSE_SHARD_FILES.every((fileName) => {
      const shardPath = path.join(licenseDir, fileName);
      return fs.existsSync(shardPath) && String(fs.readFileSync(shardPath, 'utf8') || '').trim().length > 0;
    });
  } catch (_) {
    return false;
  }
}

function hideLicenseShardOnWindows(filePath) {
  if (process.platform !== 'win32') return;
  try {
    execFileSync('attrib.exe', ['+h', filePath], { stdio: 'ignore', windowsHide: true });
  } catch (_) {}
}

function buildProtectedLicensePayload({ cpf, cnpj, document, email, machineId, licenseKey, payload }) {
  const mid = normalizeMachineId(machineId);
  const sig = normalizeLicenseKeyForFile(licenseKey);
  const doc = normalizeDocument(document || cpf || cnpj);
  const mail = normalizeEmail(email);
  return {
    v: 2,
    p: LICENSE_PRODUCT,
    m: mid,
    s: sig,
    g: simpleHash(`${mid}|${sig}|${LICENSE_SECRET_C}|${LICENSE_SECRET_B}`),
    h: simpleHash(`${doc}|${mail}|${LICENSE_PRODUCT}`),
    t: Date.now().toString(36),
    a: payload?.active === false ? '0' : '1'
  };
}

function saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload }) {
  const licenseDir = getSharedLicenseDir();
  const mid = normalizeMachineId(machineId);
  const sig = normalizeLicenseKeyForFile(licenseKey);
  const data = buildProtectedLicensePayload({ cpf, cnpj, document, email, machineId: mid, licenseKey: sig, payload });
  const cipherHex = encryptedLicenseHex(JSON.stringify(data), mid);
  const parts = splitEncryptedLicense(cipherHex);

  try {
    fs.mkdirSync(licenseDir, { recursive: true });
  } catch (error) {
    if (process.platform !== 'darwin') throw error;
  }
  for (let i = 0; i < LICENSE_SHARD_FILES.length; i += 1) {
    const shardPath = path.join(licenseDir, LICENSE_SHARD_FILES[i]);
    writeFileWithPrivilegeIfNeeded(shardPath, `${parts[i]}\n`);
    hideLicenseShardOnWindows(shardPath);
  }

  // Remove o arquivo antigo em texto simples para não manter duas licenças no computador.
  removeFileWithPrivilegeIfNeeded(getSharedLicensePath());

  for (const legacyPath of getLegacyLicensePaths()) {
    try { fs.rmSync(legacyPath, { force: true }); } catch (_) {}
  }

  return licenseDir;
}

function removeLocalLicense() {
  const licenseDir = getSharedLicenseDir();
  removeFileWithPrivilegeIfNeeded(getSharedLicensePath());

  for (const fileName of LICENSE_SHARD_FILES) {
    removeFileWithPrivilegeIfNeeded(path.join(licenseDir, fileName));
  }

  for (const legacyPath of getLegacyLicensePaths()) {
    try { fs.rmSync(legacyPath, { force: true }); } catch (_) {}
  }

  return licenseDir;
}

async function persistActiveLocalLicenseFromStore(extraPayload = null, options = {}) {
  const license = store.get('license') || {};
  if (!license.active) return false;
  const machineId = normalizeMachineId(license.machineId || await getMachineId());
  const email = normalizeEmail(license.email || store.get('deviceLoginEmail'));
  if (!machineId || !email) return false;

  const protectedLicenseAlreadySaved = protectedLicenseShardsExist();
  const forceWrite = !!options.forceWrite;

  // macOS: não peça senha administrativa só por abrir o Hook Center ou por checagem automática.
  // A licença protegida só é gravada na ativação, ou em ação manual/forçada quando ainda não existir.
  if (process.platform === 'darwin' && protectedLicenseAlreadySaved && !forceWrite) {
    store.set('license', { ...license, machineId, email, active: true });
    return true;
  }
  if (process.platform === 'darwin' && extraPayload?.source === 'startup-migration' && !forceWrite) {
    store.set('license', { ...license, machineId, email, active: true });
    return protectedLicenseAlreadySaved;
  }

  const docParts = splitDocument(license.document || license.cpf || license.cnpj);
  const licenseKey = generateExpectedLicense(machineId);
  try {
    saveLocalLicense({
      cpf: docParts.cpf,
      cnpj: docParts.cnpj,
      document: docParts.document,
      email,
      machineId,
      licenseKey,
      payload: extraPayload || { active: true, source: 'local-store' }
    });
  } catch (_) {
    if (!protectedLicenseShardsExist()) return false;
  }
  store.set('license', { ...license, machineId, email, active: true });
  return true;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });

  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = { raw: text }; }

  if (!response.ok) {
    const message = data?.message || data?.error || `HTTP ${response.status}`;
    throw new Error(message);
  }

  return data;
}


function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchJsonForUpdate(url, options = {}) {
  const attempts = Number(options.attempts || 3);
  const delayMs = Number(options.delayMs || 700);
  let lastError = null;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await fetchJson(url, options);
    } catch (error) {
      lastError = error;
      if (attempt === 1) {
        // Acorda backend/health sem transformar instabilidade temporária em erro de atualização.
        fetchJson(`${BACKEND_URL}/api/health`, { cache: 'no-store' }).catch(() => null);
      }
      if (attempt < attempts) await sleep(delayMs * attempt);
    }
  }

  const err = new Error(lastError?.message || 'Backend temporariamente indisponível');
  err.cause = lastError;
  throw err;
}

async function fetchJsonForUpdateSoft(url, options = {}) {
  try {
    return await fetchJsonForUpdate(url, options);
  } catch (error) {
    console.warn('[Hook Center] Verificação de atualização ignorada:', error?.message || error);
    return null;
  }
}

function pickFirst(...values) {
  return values.find((value) => String(value || '').trim()) || '';
}

function normalizeUpdate(raw) {
  if (!raw) return null;
  const source = raw.update || raw.latest || raw;

  const files = source.files || {};
  const windows = source.windows || files.windows || files.win32 || {};
  const macos = source.macos || source.mac || files.macos || files.mac || files.darwin || {};
  const macIntel = macos.intel || macos.x64 || macos.macIntel || files.macIntel || files.macosIntel || {};
  const macArm = macos.arm || macos.arm64 || macos.appleSilicon || macos.macArm || files.macArm || files.macosArm || files.appleSilicon || files.macosAppleSilicon || {};
  const platforms = source.platforms || files.platforms || files._platforms || {};
  const platformMeta = platforms?.[getPlatformKey()] || {};

  const updateSource = String(platformMeta.source || source.source || source.origin || '').trim();
  const testClientFlag = Boolean(
    platformMeta.testClient ||
    platformMeta.isTestClient ||
    source.testClient ||
    source.isTestClient ||
    source.clientTest ||
    source.test_client ||
    updateSource === 'test-client' ||
    updateSource === 'cliente-teste'
  );

  return {
    updateId: platformMeta.updateId || source.updateId || source.id || source.publishedAt || source.version || null,
    product: source.product || 'vs-hook',
    source: updateSource,
    testClient: testClientFlag,
    isTestClient: testClientFlag,
    targetMachineId: platformMeta.machineId || source.machineId || source.targetMachineId || '',
    platformKey: platformMeta.platformKey || source.platformKey || '',
    version: platformMeta.version || source.version || '',
    title: platformMeta.title || source.title || 'Atualização do VS Hook disponível',
    description: platformMeta.description || source.description || '',
    youtubeUrl: platformMeta.youtubeUrl || source.youtubeUrl || source.videoUrl || source.video || '',
    changelog: Array.isArray(source.changelog)
      ? source.changelog
      : String(source.description || '').split('\n').map((line) => line.trim()).filter(Boolean),
    publishedAt: platformMeta.changedAt || source.publishedAt || source.createdAt || null,
    platforms,
    changed: source.changed || files.changed || {},
    files: {
      windows: {
        betaLua: pickFirst(windows.betaLua, windows.betaLuaUrl, windows.vsHookBetaLua, windows.vsHookBetaLuaUrl, windows.beta, windows.betaUrl, windows.proLua, windows.proLuaUrl, windows.vsHookProLua, windows.vsHookProLuaUrl, windows.pro, windows.proUrl, source.betaLua, source.betaLuaUrl, source.vsHookBetaLua, source.vsHookBetaLuaUrl, source.proLua, source.proLuaUrl, source.vsHookProLua, source.vsHookProLuaUrl),
        estableLua: pickFirst(windows.estableLua, windows.estableLuaUrl, windows.stableLua, windows.stableLuaUrl, windows.vsHookEstableLua, windows.vsHookEstableLuaUrl, windows.estable, windows.stable, windows.estableUrl, windows.stableUrl, windows.basicLua, windows.basicLuaUrl, windows.vsHookBasicLua, windows.vsHookBasicLuaUrl, windows.basic, windows.basicUrl, source.estableLua, source.estableLuaUrl, source.stableLua, source.stableLuaUrl, source.vsHookEstableLua, source.vsHookEstableLuaUrl, source.basicLua, source.basicLuaUrl, source.vsHookBasicLua, source.vsHookBasicLuaUrl),
        lua: pickFirst(windows.lua, windows.luaUrl, windows.vsHookLua, windows.vsHookLuaUrl, windows.script, windows.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(windows.hookLyricsLua, windows.hookLyricsLuaUrl, windows.lyricsLua, windows.lyricsLuaUrl, windows.hookLyrics, windows.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDll: pickFirst(windows.vshookDll, windows.vshookDllUrl, windows.reaperVshookDll, windows.reaperVshookDllUrl, windows.vshook, windows.vshookUrl, windows.reaper_vshook, windows.reaper_vshook_url),
        jsApiDll: pickFirst(windows.jsApiDll, windows.jsApiDllUrl, windows.reaperJsApiDll, windows.reaperJsApiDllUrl, windows.jsapi, windows.jsapiUrl, windows.reaper_js_ReaScriptAPI64, windows.reaper_js_ReaScriptAPI64_url),
        logoPng: pickFirst(windows.logoPng, windows.logoPngUrl, windows.loadingLogo, windows.loadingLogoUrl, windows.logohookPng, windows.logohookPngUrl, windows.logo, windows.logoUrl, source.logoPng, source.logoPngUrl)
      },
      macos: {
        betaLua: pickFirst(macos.betaLua, macos.betaLuaUrl, macos.vsHookBetaLua, macos.vsHookBetaLuaUrl, macos.beta, macos.betaUrl, macos.proLua, macos.proLuaUrl, macos.vsHookProLua, macos.vsHookProLuaUrl, macos.pro, macos.proUrl, source.betaLua, source.betaLuaUrl, source.vsHookBetaLua, source.vsHookBetaLuaUrl, source.proLua, source.proLuaUrl, source.vsHookProLua, source.vsHookProLuaUrl),
        estableLua: pickFirst(macos.estableLua, macos.estableLuaUrl, macos.stableLua, macos.stableLuaUrl, macos.vsHookEstableLua, macos.vsHookEstableLuaUrl, macos.estable, macos.stable, macos.estableUrl, macos.stableUrl, macos.basicLua, macos.basicLuaUrl, macos.vsHookBasicLua, macos.vsHookBasicLuaUrl, macos.basic, macos.basicUrl, source.estableLua, source.estableLuaUrl, source.stableLua, source.stableLuaUrl, source.vsHookEstableLua, source.vsHookEstableLuaUrl, source.basicLua, source.basicLuaUrl, source.vsHookBasicLua, source.vsHookBasicLuaUrl),
        lua: pickFirst(macos.lua, macos.luaUrl, macos.vsHookLua, macos.vsHookLuaUrl, macos.script, macos.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(macos.hookLyricsLua, macos.hookLyricsLuaUrl, macos.lyricsLua, macos.lyricsLuaUrl, macos.hookLyrics, macos.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDylib: pickFirst(macos.vshookDylib, macos.vshookDylibUrl, macos.reaperVshookDylib, macos.reaperVshookDylibUrl, macos.vshook, macos.vshookUrl, macos.reaper_vshook, macos.reaper_vshook_url),
        jsApiDylib: pickFirst(macos.jsApiDylib, macos.jsApiDylibUrl, macos.reaperJsApiDylib, macos.reaperJsApiDylibUrl, macos.jsapi, macos.jsapiUrl, macos.universalJsApiDylib, macos.universalJsApiDylibUrl),
        jsApiArmDylib: pickFirst(macArm.jsApiDylib, macArm.jsApiDylibUrl, macArm.reaperJsApiDylib, macArm.reaperJsApiDylibUrl, macArm.jsapi, macArm.jsapiUrl, macos.armJsApiDylib, macos.armJsApiDylibUrl, macos.jsApiArmDylib, macos.jsApiArmDylibUrl, macos.jsApiAppleSiliconDylib, macos.jsApiAppleSiliconDylibUrl, macos.reaperJsApiArmDylib, macos.reaperJsApiArmDylibUrl, macos.reaperJsApiAppleSiliconDylib, macos.reaperJsApiAppleSiliconDylibUrl, macos.reaper_js_ReaScriptAPI64ARM, macos.reaper_js_ReaScriptAPI64ARM_url),
        jsApiIntelDylib: pickFirst(macIntel.jsApiDylib, macIntel.jsApiDylibUrl, macIntel.reaperJsApiDylib, macIntel.reaperJsApiDylibUrl, macIntel.jsapi, macIntel.jsapiUrl, macos.intelJsApiDylib, macos.intelJsApiDylibUrl, macos.jsApiIntelDylib, macos.jsApiIntelDylibUrl, macos.reaperJsApiIntelDylib, macos.reaperJsApiIntelDylibUrl, macos.reaper_js_ReaScriptAPI64, macos.reaper_js_ReaScriptAPI64_url),
        logoPng: pickFirst(macos.logoPng, macos.logoPngUrl, macos.loadingLogo, macos.loadingLogoUrl, macos.logohookPng, macos.logohookPngUrl, macos.logo, macos.logoUrl, source.logoPng, source.logoPngUrl)
      }
    }
  };
}


function updateMatchesCurrentPlatform(update) {
  const platformKey = getPlatformKey();
  const changed = update?.changed || update?.files?.changed || {};
  if (Object.prototype.hasOwnProperty.call(changed, platformKey)) {
    return Boolean(changed[platformKey]);
  }
  return hasInstallableFiles(update);
}

function normalizeUpdatesList(raw) {
  const list = Array.isArray(raw)
    ? raw
    : (
      Array.isArray(raw?.updates) ? raw.updates :
      Array.isArray(raw?.history) ? raw.history :
      Array.isArray(raw?.items) ? raw.items :
      Array.isArray(raw?.data) ? raw.data :
      []
    );

  return list
    .map(normalizeUpdate)
    .filter((update) => update && (update.version || update.updateId || hasInstallableFiles(update)) && updateMatchesCurrentPlatform(update));
}

function normalizeUpdateIdentityValue(value) {
  return String(value || '').trim().toLowerCase();
}

function collectUpdateFileUrlsForCurrentPlatform(update) {
  const files = getPlatformFiles(update) || {};
  return buildPayloadEntries(files)
    .map((entry) => normalizeUpdateIdentityValue(entry.url))
    .filter(Boolean)
    .sort();
}

function isSameCurrentUpdate(historyUpdate, currentUpdate) {
  if (!historyUpdate || !currentUpdate) return false;

  const historyPlatformId = normalizeUpdateIdentityValue(getPlatformUpdateId(historyUpdate));
  const currentPlatformId = normalizeUpdateIdentityValue(getPlatformUpdateId(currentUpdate));
  if (historyPlatformId && currentPlatformId && historyPlatformId === currentPlatformId) return true;

  const historyUpdateId = normalizeUpdateIdentityValue(historyUpdate.updateId);
  const currentUpdateId = normalizeUpdateIdentityValue(currentUpdate.updateId);
  if (historyUpdateId && currentUpdateId && historyUpdateId === currentUpdateId) return true;

  const historyVersion = normalizeUpdateIdentityValue(historyUpdate.version);
  const currentVersion = normalizeUpdateIdentityValue(currentUpdate.version);
  if (historyVersion && currentVersion && historyVersion === currentVersion) return true;

  const historyUrls = collectUpdateFileUrlsForCurrentPlatform(historyUpdate);
  const currentUrls = collectUpdateFileUrlsForCurrentPlatform(currentUpdate);
  if (historyUrls.length > 0 && currentUrls.length > 0 && historyUrls.join('|') === currentUrls.join('|')) return true;

  return false;
}

async function getCurrentPublishedUpdateForHistory() {
  const raw = await fetchJsonForUpdateSoft(await getLatestUpdateApiUrl({ includeTestClient: false }), { cache: 'no-store' });
  const update = normalizeUpdate(raw);
  if (update && updateMatchesCurrentPlatform(update)) return update;

  const cached = normalizeUpdate(store.get('latestUpdate'));
  if (cached && updateMatchesCurrentPlatform(cached)) return cached;

  return null;
}

function filterPreviousUpdates(updates, currentUpdate) {
  const seen = new Set();
  return (updates || []).filter((update) => {
    if (!update) return false;
    if (currentUpdate && isSameCurrentUpdate(update, currentUpdate)) return false;

    const identity = [
      normalizeUpdateIdentityValue(getPlatformUpdateId(update)),
      normalizeUpdateIdentityValue(update.updateId),
      normalizeUpdateIdentityValue(update.version),
      collectUpdateFileUrlsForCurrentPlatform(update).join('|')
    ].filter(Boolean).join('::');

    if (identity && seen.has(identity)) return false;
    if (identity) seen.add(identity);
    return true;
  });
}

async function getPreviousUpdates() {
  const endpoints = [
    UPDATES_HISTORY_API_URL,
    `${BACKEND_URL}/api/updates/history?limit=50&platform=${getPlatformKey()}`,
    `${BACKEND_URL}/api/updates/history?limit=50`,
    `${BACKEND_URL}/api/public/updates?limit=50&platform=${getPlatformKey()}`
  ];

  let lastError = null;
  const currentUpdate = await getCurrentPublishedUpdateForHistory();

  for (const url of endpoints) {
    try {
      const raw = await fetchJson(url, { cache: 'no-store' });
      const updates = filterPreviousUpdates(normalizeUpdatesList(raw), currentUpdate);
      return { ok: true, updates };
    } catch (error) {
      lastError = error;
    }
  }

  return {
    ok: false,
    error: lastError?.message || 'Não foi possível carregar as atualizações anteriores.',
    updates: []
  };
}


async function checkTestClientUpdate() {
  const raw = await fetchJsonForUpdateSoft(await getLatestUpdateApiUrl({ includeTestClient: true }), { cache: 'no-store' });
  const update = normalizeUpdate(raw);
  const testUpdate = update && updateMatchesCurrentPlatform(update) && (update.testClient || update.isTestClient)
    ? update
    : null;
  store.set('testClientUpdate', testUpdate);
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
  return { ok: true, update: testUpdate, state: getAppState() };
}

async function checkForUpdates(manual = false) {
  const now = new Date().toISOString();
  store.set('lastCheck', now);

  const raw = await fetchJsonForUpdateSoft(await getLatestUpdateApiUrl({ includeTestClient: false }), { cache: 'no-store' });
  const fetchedUpdate = normalizeUpdate(raw);
  const cachedUpdate = normalizeUpdate(store.get('latestUpdate'));
  const update = fetchedUpdate || cachedUpdate || null;

  const shouldNotify = hasPendingInstallableUpdate(update);

  if (fetchedUpdate || !store.get('latestUpdate')) {
    store.set('latestUpdate', update);
  }
  store.set('updateAvailable', shouldNotify);
  rebuildTrayMenu();

  await checkTestClientUpdate();

  if (isValidWindow(mainWindow)) {
    mainWindow.webContents.send('update-status', getAppState());
  }

  if (shouldNotify && !manual) {
    notifyPendingUpdate(true);
  }

  if (manual) showMainWindow();

  return { ok: true, hasUpdate: shouldNotify, update, offline: !fetchedUpdate, state: getAppState() };
}


function normalizeHookCenterUpdate(raw) {
  if (!raw) return null;
  const hasTutorialOnly = !!(raw.tutorialUrl || raw.learnUrl || raw.videoUrl);
  if (raw.published === false && !hasTutorialOnly) return null;
  const platformKey = getHookCenterPlatformKey();
  const platformUrls = {
    windows: raw.windowsUrl || raw.windowsInstallerUrl || raw.exeUrl,
    macos: raw.macosUrl || raw.macosInstallerUrl || raw.macUrl || raw.dmgUrl,
    'macos-legacy': raw.macosLegacyUrl || raw.legacyMacosUrl || raw.macos10Url || raw.macosLegacyInstallerUrl
  };
  const downloadUrl = ensureAbsoluteUrl(raw.downloadUrl || platformUrls[platformKey] || '');
  return {
    product: 'hook-center',
    updateId: raw.updateId || raw.version || null,
    version: raw.version || '',
    title: raw.title || 'Nova versão do Hook Center disponível',
    notes: raw.notes || raw.description || '',
    tutorialUrl: ensureAbsoluteUrl(raw.tutorialUrl || raw.learnUrl || raw.videoUrl || ''),
    downloadUrl,
    windowsUrl: ensureAbsoluteUrl(raw.windowsUrl),
    macosUrl: ensureAbsoluteUrl(raw.macosUrl),
    macosLegacyUrl: ensureAbsoluteUrl(raw.macosLegacyUrl || raw.legacyMacosUrl || raw.macos10Url),
    publishedAt: raw.publishedAt || null
  };
}

async function checkHookCenterUpdates(manual = false) {
  const raw = await fetchJsonForUpdateSoft(HOOK_CENTER_API_URL, { cache: 'no-store' });
  const fetchedUpdate = normalizeHookCenterUpdate(raw);
  const cachedUpdate = store.get('hookCenterLatest') || null;
  const update = fetchedUpdate || cachedUpdate || null;
  const currentVersion = app.getVersion();
  const hasUpdate = !!(update?.version && update.downloadUrl && compareVersions(update.version, currentVersion) > 0);
  if (fetchedUpdate || !store.get('hookCenterLatest')) store.set('hookCenterLatest', update);
  store.set('hookCenterUpdateAvailable', hasUpdate);
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
  if (hasUpdate && !manual) notifyHookCenterUpdate(update);
  if (manual) showMainWindow();
  return { ok: true, hasUpdate, update, offline: !fetchedUpdate, state: getAppState() };
}

async function downloadHookCenterUpdateInstaller() {
  const checked = await checkHookCenterUpdates(true);
  const update = checked.update || store.get('hookCenterLatest');
  if (!update?.downloadUrl) throw new Error('Atualização do Hook Center indisponível para este sistema.');
  if (!update.version || compareVersions(update.version, app.getVersion()) <= 0) {
    throw new Error('O Hook Center já está atualizado.');
  }

  const ext = process.platform === 'darwin' ? '.dmg' : '.exe';
  const baseName = process.platform === 'darwin'
    ? (getHookCenterPlatformKey() === 'macos-legacy' ? `Hook-Center-Legacy-${update.version}-macOS10${ext}` : `Hook-Center-${update.version}-macOS${ext}`)
    : `Hook-Center-${update.version}-Windows${ext}`;
  const dest = path.join(app.getPath('downloads'), baseName);
  await downloadFile(update.downloadUrl, dest, (progress) => {
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', progress);
  });

  const downloaded = {
    version: update.version,
    updateId: update.updateId || update.version,
    path: dest,
    platform: process.platform,
    downloadedAt: new Date().toISOString()
  };
  store.set('downloadedHookCenterUpdate', downloaded);
  return { ok: true, downloaded };
}

async function installDownloadedHookCenterUpdate() {
  const downloaded = store.get('downloadedHookCenterUpdate') || {};
  const dest = String(downloaded.path || '');
  if (!dest || !fs.existsSync(dest)) {
    throw new Error('O instalador da atualização do Hook Center não foi encontrado. Baixe novamente.');
  }

  if (process.platform === 'win32') {
    spawn(dest, [], { detached: true, stdio: 'ignore', windowsHide: false }).unref();
    app.isQuiting = true;
    app.quit();
    return { ok: true, action: 'installer-started' };
  }

  await shell.openPath(dest);
  shell.showItemInFolder(dest);
  return { ok: true, action: 'dmg-opened' };
}

async function downloadAndInstallHookCenterUpdate() {
  await downloadHookCenterUpdateInstaller();
  return installDownloadedHookCenterUpdate();
}


function normalizeBridgeAppUpdate(raw) {
  if (!raw || raw.published === false) return null;
  const downloadUrl = ensureAbsoluteUrl(raw.downloadUrl || raw.zipUrl || raw.url);
  return {
    product: 'bridge-app',
    updateId: raw.updateId || raw.version || null,
    version: raw.version || '',
    title: raw.title || 'Atualização do app QR disponível',
    notes: raw.notes || raw.description || '',
    downloadUrl,
    zipUrl: ensureAbsoluteUrl(raw.zipUrl || raw.downloadUrl || raw.url),
    sha256: String(raw.sha256 || '').trim().toLowerCase(),
    publishedAt: raw.publishedAt || null
  };
}

function bridgeAppNeedsUpdate(update) {
  if (!update?.downloadUrl) return false;
  const installed = store.get('bridgeAppInstalled') || {};
  if (!installed.version && !installed.updateId) return true;
  if (update.updateId && installed.updateId && update.updateId !== installed.updateId) return true;
  if (update.version && installed.version && compareVersions(update.version, installed.version) > 0) return true;
  if (update.version && !installed.version) return true;
  return false;
}

async function checkBridgeAppUpdates(manual = false) {
  // App QR não é mais atualizado pelo backend.
  // A versão servida pelo QR agora vem sempre de qr-app/.
  const installedPath = getBridgeWebAppDir();
  store.set('bridgeAppLatest', null);
  store.set('bridgeAppUpdateAvailable', false);
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
  if (manual) showMainWindow();
  return {
    ok: true,
    hasUpdate: false,
    update: null,
    skipped: true,
    reason: 'bridge-app-bundled-in-hook-center',
    installedPath,
    state: getAppState()
  };
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex').toLowerCase();
}

function runProcess(command, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { windowsHide: true, ...options }, (error, stdout, stderr) => {
      if (error) {
        const message = String(stderr || stdout || error.message || 'Erro ao executar processo').trim();
        reject(new Error(message));
        return;
      }
      resolve(String(stdout || '').trim());
    });
  });
}

async function downloadAndInstallBridgeAppUpdate(updateOverride = null) {
  // Mantido apenas para compatibilidade com IPC/renderer antigo.
  // Não baixa mais ZIP do App QR: o QR Code usa diretamente o qr-app embutido no Hook Center.
  const installedPath = getBridgeWebAppDir();
  store.set('bridgeAppLatest', null);
  store.set('bridgeAppUpdateAvailable', false);
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
  return {
    ok: true,
    skipped: true,
    reason: 'bridge-app-bundled-in-hook-center',
    installedPath,
    update: null
  };
}

async function checkAndInstallBridgeAppUpdate() {
  return checkBridgeAppUpdates(false);
}

async function checkLicenseStatus(manual = false) {
  const license = store.get('license') || {};
  const now = Date.now();
  const lastClockAt = Date.parse(license.lastLocalClockAt || '') || 0;
  if (license.active === true && lastClockAt > 0 && (now + LICENSE_CLOCK_ROLLBACK_TOLERANCE_MS) < lastClockAt) {
    removeLocalLicense();
    const revoked = {
      ...license,
      active: false,
      message: 'Licença removida porque a data ou hora deste computador foi retrocedida.',
      reason: 'clock_rollback',
      offlineWarningStartedAt: ''
    };
    store.set('license', revoked);
    publishLicenseOfflineStatus(revoked);
    notifyLicense(revoked.message);
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState());
    return { ok: false, active: false, error: 'clock_rollback', state: getAppState() };
  }
  if (license.active === true && (!lastClockAt || now > lastClockAt)) {
    store.set('license', { ...license, lastLocalClockAt: new Date(now).toISOString() });
  }
  const docParts = splitDocument(license.document || license.cpf || license.cnpj);
  const cpf = docParts.cpf;
  const cnpj = docParts.cnpj;
  const document = docParts.document;
  const email = normalizeEmail(license.email);
  const machineId = normalizeMachineId(license.machineId || await getMachineId());

  if (!email || !machineId) {
    return { ok: false, message: 'Licença ainda não ativada.', state: getAppState() };
  }

  try {
    const result = await fetchJson(`${BACKEND_URL}/api/license/status`, {
      method: 'POST',
      body: JSON.stringify({ cpf, cnpj, document, email, machineId, platform: process.platform, computerName: getStoredDeviceName() })
    });

    const active = result.active !== false && result.ok !== false;
    const nextLicense = {
      ...license,
      cpf,
      cnpj,
      document,
      email,
      machineId,
      active,
      devicesUsed: result.devicesUsed ?? license.devicesUsed ?? 0,
      maxDevices: result.maxDevices ?? license.maxDevices ?? 0,
      devices: Array.isArray(result.devices) ? result.devices : (license.devices || []),
      message: result.message || result.warning || '',
      warning: result.warning || '',
      reason: result.reason || '',
      lastStatusAt: new Date().toISOString(),
      lastOnlineValidationAt: new Date().toISOString(),
      offlineWarningStartedAt: '',
      lastLocalClockAt: new Date().toISOString()
    };

    store.set('license', nextLicense);
    publishLicenseOfflineStatus(nextLicense);

    if (active) {
      const licenseAlreadySaved = protectedLicenseShardsExist();
      const shouldPersistProtectedLicense = process.platform !== 'darwin' || (manual && !licenseAlreadySaved);

      if (shouldPersistProtectedLicense) {
        const licenseKey = result.licenseKey || result.license || generateExpectedLicense(machineId);
        try {
          saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload: result });
        } catch (_) {
          if (manual && !protectedLicenseShardsExist()) {
            throw new Error('Não foi possível concluir a ativação. Tente novamente.');
          }
        }
      }
    } else {
      if (manual || process.platform !== 'darwin') {
        removeLocalLicense();
      }
      notifyLicense(result.message || 'Este computador foi desvinculado da licença do VS Hook.');
    }

    rebuildTrayMenu();
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState());

    return { ok: true, active, result, state: getAppState() };
  } catch (error) {
    const currentLicense = store.get('license') || {};
    if (currentLicense.active === true) {
      const lastOnlineAt = Date.parse(currentLicense.lastOnlineValidationAt || currentLicense.lastStatusAt || '') || Date.now();
      const warningStartedAt = Date.parse(currentLicense.offlineWarningStartedAt || '') || 0;
      let nextLicense = currentLicense;
      if ((Date.now() - lastOnlineAt) >= LICENSE_OFFLINE_GRACE_MS && !warningStartedAt) {
        nextLicense = { ...currentLicense, offlineWarningStartedAt: new Date().toISOString() };
        store.set('license', nextLicense);
        notifyLicense('Conecte-se à internet para verificar a licença. Sem validação, o acesso ao VS Hook será removido em 3 dias.');
      }
      const status = publishLicenseOfflineStatus(nextLicense);
      if (status.expired) {
        removeLocalLicense();
        const revoked = { ...nextLicense, active: false, message: 'Licença removida após 3 dias sem validação online.', offlineWarningStartedAt: '' };
        store.set('license', revoked);
        publishLicenseOfflineStatus(revoked);
        notifyLicense('A licença foi removida porque não houve validação online no prazo. Conecte-se à internet e ative novamente.');
      }
    }
    if (manual) dialog.showErrorBox('Erro ao verificar licença', error.message);
    return { ok: false, error: error.message, state: getAppState() };
  }
}


function getDefaultReaperScriptsDir() {
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
    return path.join(appData, 'REAPER', 'Scripts');
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'REAPER', 'Scripts');
  }
  return path.join(os.homedir(), '.config', 'REAPER', 'Scripts');
}

function readBridgeConfig() {
  const stored = store.get('bridge') || {};
  const defaults = {
    scriptsDir: getDefaultReaperScriptsDir(),
    directorPort: 47831,
    musiciansPort: 47832,
    autoStart: true
  };
  return { ...defaults, ...stored, scriptsDir: stored.scriptsDir || defaults.scriptsDir };
}

function saveBridgeConfig(config) {
  store.set('bridge', { ...readBridgeConfig(), ...config });
}

function resolveBridgeScriptsDir(config) {
  const envDir = process.env.VSHOOK_SCRIPTS_DIR;
  const candidates = [envDir, config?.scriptsDir, getDefaultReaperScriptsDir()].filter(Boolean);
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return path.resolve(candidate);
    } catch (_) {}
  }
  const fallback = path.resolve(getDefaultReaperScriptsDir());
  fs.mkdirSync(fallback, { recursive: true });
  return fallback;
}

function getLicenseOfflineStatus(license = store.get('license') || {}) {
  const now = Date.now();
  const active = license.active === true;
  const lastOnlineAt = Date.parse(license.lastOnlineValidationAt || license.lastStatusAt || '') || 0;
  const warningStartedAt = Date.parse(license.offlineWarningStartedAt || '') || 0;
  const graceElapsed = active && lastOnlineAt > 0 && (now - lastOnlineAt) >= LICENSE_OFFLINE_GRACE_MS;
  const deadlineAt = warningStartedAt ? warningStartedAt + LICENSE_OFFLINE_WARNING_MS : 0;
  return {
    active,
    warning: active && graceElapsed,
    expired: active && warningStartedAt > 0 && now >= deadlineAt,
    lastOnlineValidationAt: lastOnlineAt ? new Date(lastOnlineAt).toISOString() : null,
    warningStartedAt: warningStartedAt ? new Date(warningStartedAt).toISOString() : null,
    deadlineAt: deadlineAt ? new Date(deadlineAt).toISOString() : null,
    message: 'Conecte-se à internet para verificar a licença. Sem validação, o acesso ao VS Hook será removido em 3 dias.'
  };
}

function publishLicenseOfflineStatus(license = store.get('license') || {}) {
  const payload = { ...getLicenseOfflineStatus(license), updatedAt: new Date().toISOString() };
  try {
    const config = bridgeConfig || readBridgeConfig();
    const target = path.join(resolveBridgeScriptsDir(config), 'vshook_license_status.json');
    fs.writeFileSync(target, JSON.stringify(payload, null, 2), 'utf8');
  } catch (_) {}
  return payload;
}

function getBridgeFallbackState(extra = {}) {
  return {
    bridgeVersion: 1,
    projectName: '',
    projectPath: '',
    connected: false,
    updatedAt: null,
    currentPage: 'regions',
    markerMode: false,
    currentPlaylistName: '',
    activePlaylistId: null,
    autoplayEnabled: false,
    playing: false,
    playingId: null,
    selectedRegionId: null,
    selectedRegionIds: [],
    selectedPlaylistSongId: null,
    selectedPlaylistSongIds: [],
    selectedMarkerId: null,
    regions: [],
    playlists: [],
    markers: [],
    ...extra
  };
}


function getEditableBridgeWebAppDir() {
  // Fonte única do App QR, usada no desenvolvimento e no build empacotado.
  // Assim o QR Code sempre lê Hook center/qr-app/ sem depender de cópias em src/.
  return path.join(__dirname, '..', 'qr-app');
}

function getBundledBridgeWebAppDir() {
  return getEditableBridgeWebAppDir();
}

function getFallbackBridgeWebAppDir() {
  const fallbackDir = app.isPackaged
    ? path.join(app.getPath('userData'), 'bridge-empty-app')
    : path.join(__dirname, 'bridge-empty-app');
  fs.mkdirSync(fallbackDir, { recursive: true });
  const fallbackIndex = path.join(fallbackDir, 'index.html');
  if (!fs.existsSync(fallbackIndex)) {
    fs.writeFileSync(fallbackIndex, '<!doctype html><meta charset="utf-8"><title>VS Hook</title><body>VS Hook Bridge</body>', 'utf8');
  }
  return fallbackDir;
}

function isBridgeWebAppDirValid(dir) {
  try {
    if (!dir) return false;
    const indexPath = path.join(dir, 'index.html');
    return fs.existsSync(indexPath) && fs.statSync(indexPath).isFile();
  } catch (_) {
    return false;
  }
}

function readBridgeWebAppVersion(dir) {
  try {
    const versionPath = path.join(dir, 'version.json');
    if (!fs.existsSync(versionPath)) return '';
    const raw = JSON.parse(fs.readFileSync(versionPath, 'utf8'));
    return String(raw.updateId || raw.version || raw.build || raw.cache || '').trim();
  } catch (_) {
    return '';
  }
}

function getBridgeWebAppDir() {
  // O QR Code serve sempre a fonte única qr-app/.
  // No desenvolvimento isso aponta para Hook center/qr-app; no app empacotado,
  // aponta para o qr-app embutido no pacote.
  const appDir = getBundledBridgeWebAppDir();
  if (isBridgeWebAppDirValid(appDir)) return appDir;
  return getFallbackBridgeWebAppDir();
}

function getBridgeAppCacheVersion() {
  return encodeURIComponent(readBridgeWebAppVersion(getBridgeWebAppDir()) || app.getVersion() || Date.now());
}

function isVsHookLicenseActiveForBridge() {
  const license = store.get('license') || {};
  return license.active === true;
}

function buildBridgeServers(config) {
  const sharedDir = resolveBridgeScriptsDir(config);
  const bridgeWebAppDir = getBridgeWebAppDir();

  return [
    createBridgeServer({
      appName: 'Diretor',
      host: '0.0.0.0',
      port: Number(config.directorPort) || 47831,
      publicBridgeHost: getLanIp(),
      appDir: bridgeWebAppDir,
      sharedDir,
      getTechnicalNoticeSettings,
      saveTechnicalNoticeSettings,
      isLicenseActive: isVsHookLicenseActiveForBridge,
      fallbackState: getBridgeFallbackState({
        selectedPlaylistSongIds: [],
        clearButtonSide: 'right',
        appActive: false,
        timerRunning: false,
        timerStartedAt: 0,
        timerAccumulatedSec: 0
      }),
      routes: [{ url: '/', file: 'index.html', contentType: 'text/html; charset=utf-8' }]
    }),
    createBridgeServer({
      appName: 'Músicos',
      host: '0.0.0.0',
      port: Number(config.musiciansPort) || 47832,
      publicBridgeHost: getLanIp(),
      appDir: bridgeWebAppDir,
      sharedDir,
      getTechnicalNoticeSettings,
      saveTechnicalNoticeSettings,
      isLicenseActive: isVsHookLicenseActiveForBridge,
      fallbackState: getBridgeFallbackState(),
      routes: [{ url: '/', file: 'index.html', contentType: 'text/html; charset=utf-8' }]
    })
  ];
}

async function stopBridgeServers() {
  const running = [...bridgeServers];
  bridgeServers = [];
  bridgeInfos = [];
  for (const server of running) {
    try { await server.stop(); } catch (_) {}
  }
}

async function startBridgeServers() {
  await stopBridgeServers();
  bridgeConfig = readBridgeConfig();
  fs.mkdirSync(resolveBridgeScriptsDir(bridgeConfig), { recursive: true });
  const nextServers = buildBridgeServers(bridgeConfig);
  const nextInfos = [];

  try {
    for (const server of nextServers) {
      const info = await server.start();
      nextInfos.push(info);
    }
    bridgeServers = nextServers;
    bridgeInfos = nextInfos;
    bridgeLastError = '';
    rebuildTrayMenu();
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('bridge-status', getBridgeState());
    return getBridgeState();
  } catch (error) {
    bridgeLastError = error?.message || String(error || 'Erro desconhecido ao iniciar a conexão via app.');
    for (const server of nextServers) {
      try { await server.stop(); } catch (_) {}
    }
    bridgeServers = [];
    bridgeInfos = [];
    rebuildTrayMenu();
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('bridge-status', getBridgeState());
    throw error;
  }
}

async function ensureBridgeServersRunning() {
  if (bridgeServers.length > 0) return getBridgeState();
  return startBridgeServers();
}

function getBridgeState() {
  const config = bridgeConfig || readBridgeConfig();
  const lanIp = getLanIp();
  const allLanIps = typeof getAllLanIps === 'function' ? getAllLanIps() : [];
  const directorPort = Number(config.directorPort) || 47831;
  const musiciansPort = Number(config.musiciansPort) || 47832;
  return {
    running: bridgeServers.length > 0,
    lanIp,
    lanIps: allLanIps,
    scriptsDir: resolveBridgeScriptsDir(config),
    directorPort,
    musiciansPort,
    directorUrl: `http://${lanIp}:${directorPort}`,
    musiciansUrl: `http://${lanIp}:${musiciansPort}`,
    browserUrl: `http://${lanIp}:${directorPort}/?qr=1&v=${getBridgeAppCacheVersion()}`,
    qrCodeUrl: `http://${lanIp}:${directorPort}/qr.svg?url=${encodeURIComponent(`http://${lanIp}:${directorPort}/?qr=1&v=${getBridgeAppCacheVersion()}`)}`,
    directorUrls: allLanIps.map((item) => `http://${item.ip}:${directorPort}`),
    musiciansUrls: allLanIps.map((item) => `http://${item.ip}:${musiciansPort}`),
    infos: bridgeInfos,
    error: bridgeLastError
  };
}


function getLyricsDefaults() {
  return {
    preset: 'night',
    textColor: '#ffea00',
    textBoxColor: '#ffea00',
    clockColor: '#00ff55',
    borderColor: '#00ff55',
    rgbBorderEnabled: false,
    rgbWindowBorderEnabled: false,
    rgbClockBorderEnabled: false,
    rgbTextBoxBorderEnabled: false,
    textCase: 'uppercase',
    fontFamily: 'Arial',
    textScale: 1,
    borderEnabled: true,
    windowBorderEnabled: true,
    clockBorderEnabled: true,
    textBoxEnabled: true,
    clockEnabled: true,
    songNameEnabled: false,
    songNameColor: '#00ff55',
    queueNameColor: '#ffea00',
    queueNameEnabled: true,
    queueNamePosition: 'top',
    queueNameDepth: 80,
    queueNameFontFamily: 'Arial',
    songNameFontFamily: 'Arial',
    songNameScale: 1,
    songNamePosition: 'top',
    progressEnabled: false,
    progressPosition: 'bottom',
    progressColor: '#ffea00',
    clockPosition: 'top',
    clockScale: 1,
    mediaScale: 1,
    previewEnabled: true,
    previewScale: 1,
    alwaysOnTop: false,
    clearMode: false
  };
}

function simpleNoticeHash(str) {
  let h1 = 0x45D9;
  let h2 = 0x2710;
  const text = String(str || '');
  for (let i = 0; i < text.length; i += 1) {
    const b = text.charCodeAt(i) & 0xff;
    h1 = (h1 ^ (b * (i + 1) + 17)) & 0xffffff;
    h2 = (h2 + ((b + i) * 131)) & 0xffffff;
    h1 = (h1 * 33 + h2) & 0xffffff;
    h2 = (h2 * 17 + h1) & 0xffffff;
  }
  const n = (((h1 << 12) >>> 0) + h2) >>> 0;
  return n.toString(16).toUpperCase().padStart(8, '0');
}

function getTechnicalNoticeDefaults() {
  return {
    textColor: '#ffea00',
    flashColor: '#ff0000',
    fontFamily: 'Arial',
    window1Enabled: true,
    window2Enabled: true,
    emojiEnabled: true,
    emoji: '⚠️',
    recadosPassword: '',
    recadosAuthEnabled: false,
    recadosAuthHash: '',
    technicalNoticeAuthEnabled: false,
    technicalNoticeAuthHash: '',
    recadosTemplates: ['', '', '']
  };
}

function getTechnicalNoticeSettings() {
  const saved = store.get('technicalNoticeSettings') || {};
  return { ...getTechnicalNoticeDefaults(), ...saved };
}

function saveTechnicalNoticeSettings(settings = {}) {
  const allowedFonts = ['Arial', 'Segoe UI', 'Verdana', 'Tahoma', 'Georgia', 'Trebuchet MS', 'Impact'];
  const next = { ...getTechnicalNoticeSettings() };
  if (typeof settings.textColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textColor)) next.textColor = settings.textColor;
  if (typeof settings.flashColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.flashColor)) next.flashColor = settings.flashColor;
  if (allowedFonts.includes(settings.fontFamily)) next.fontFamily = settings.fontFamily;
  if (typeof settings.window1Enabled === 'boolean') next.window1Enabled = settings.window1Enabled;
  if (typeof settings.window2Enabled === 'boolean') next.window2Enabled = settings.window2Enabled;
  if (typeof settings.emojiEnabled === 'boolean') next.emojiEnabled = settings.emojiEnabled;
  if (typeof settings.emoji === 'string') {
    const cleanEmoji = settings.emoji.trim().replace(/[\r\n\t]+/g, '').slice(0, 8);
    next.emoji = cleanEmoji || '⚠️';
  }
  if (Array.isArray(settings.recadosTemplates)) {
    next.recadosTemplates = [0, 1, 2].map((index) => String(settings.recadosTemplates[index] || '').trim().slice(0, 500));
  }
  store.set('technicalNoticeSettings', next);
  for (const win of lyricsWindows.values()) {
    if (win && !win.isDestroyed()) win.webContents.send('technical-notice-settings-updated', next);
  }
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('technical-notice-settings-updated', next);
  return next;
}

function getTechnicalNoticeFilePath() {
  return path.join(resolveBridgeScriptsDir(readBridgeConfig()), 'vshook_technical_notice.json');
}

function getStoredTechnicalNotice() {
  try {
    const raw = JSON.parse(fs.readFileSync(getTechnicalNoticeFilePath(), 'utf8'));
    const expiresAt = Number(raw?.expiresAt || 0);
    if (!raw?.text || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) return null;
    return raw;
  } catch (_) {
    return null;
  }
}

function sendRecadosNotice(payload = {}) {
  const text = String(payload.text || '').trim().slice(0, 500);
  if (!text) throw new Error('Digite um recado antes de enviar.');
  const active = getStoredTechnicalNotice();
  if (active && Number(active.priority || 0) > 4) return { ok: true, ignoredDuePriority: true, notice: active };
  const now = Date.now();
  const pinned = payload.pinned === true;
  const durationMs = 20000;
  const expiresAt = pinned ? now + (3650 * 24 * 60 * 60 * 1000) : now + durationMs;
  const notice = {
    id: `${now}-${Math.random().toString(16).slice(2, 8)}`,
    text,
    message: text,
    source: 'recados',
    priority: 4,
    createdAt: new Date(now).toISOString(),
    updatedAt: new Date(now).toISOString(),
    durationMs,
    pausedRemainingMs: pinned ? durationMs : 0,
    expiresAt,
    expiresAtIso: new Date(expiresAt).toISOString(),
    pinned
  };
  fs.mkdirSync(path.dirname(getTechnicalNoticeFilePath()), { recursive: true });
  fs.writeFileSync(getTechnicalNoticeFilePath(), JSON.stringify(notice, null, 2), 'utf8');
  return { ok: true, notice };
}

function cancelRecadosNotice() {
  const active = getStoredTechnicalNotice();
  if (active && Number(active.priority || 0) > 4) return { ok: true, ignoredDuePriority: true, notice: active };
  fs.mkdirSync(path.dirname(getTechnicalNoticeFilePath()), { recursive: true });
  fs.writeFileSync(getTechnicalNoticeFilePath(), JSON.stringify({ id: '', text: '', message: '', source: '', priority: 0, cancelledAt: new Date().toISOString(), expiresAt: 0 }, null, 2), 'utf8');
  return { ok: true, cancelled: true };
}

function setRecadosNoticePinned(payload = {}) {
  const active = getStoredTechnicalNotice();
  if (!active) throw new Error('Nenhum recado ativo.');
  if (Number(active.priority || 0) > 4) return { ok: true, ignoredDuePriority: true, notice: active };
  const now = Date.now();
  const pinned = payload.pinned === true;
  const configuredDurationMs = Math.max(1000, Math.floor(Number(active.durationMs || 0)) || 20000);
  const pausedRemainingMs = pinned
    ? Math.max(0, Math.floor(Number(active.expiresAt || now) - now))
    : Math.max(0, Math.floor(Number(active.pausedRemainingMs || 0)) || configuredDurationMs);
  const durationMs = pinned ? configuredDurationMs : pausedRemainingMs;
  const expiresAt = pinned ? now + (3650 * 24 * 60 * 60 * 1000) : now + pausedRemainingMs;
  const notice = { ...active, pinned, durationMs, pausedRemainingMs: pinned ? pausedRemainingMs : 0, updatedAt: new Date(now).toISOString(), expiresAt, expiresAtIso: new Date(expiresAt).toISOString() };
  fs.writeFileSync(getTechnicalNoticeFilePath(), JSON.stringify(notice, null, 2), 'utf8');
  return { ok: true, notice };
}

function normalizeLyricsSlot(slot = 1) {
  return Number(slot) === 2 ? 2 : 1;
}

function getLyricsAllSettings() {
  const saved = store.get('lyrics') || {};
  const defaults = getLyricsDefaults();
  return {
    1: { ...defaults, ...(saved[1] || saved.one || saved.window1 || saved || {}) },
    2: { ...defaults, ...(saved[2] || saved.two || saved.window2 || saved || {}) }
  };
}

function getLyricsSettings(slot = 1) {
  const id = normalizeLyricsSlot(slot);
  return getLyricsAllSettings()[id];
}

function applyLyricsWindowPinState(slot = 1, alwaysOnTop = false) {
  const id = normalizeLyricsSlot(slot);
  const win = lyricsWindows.get(id);
  if (!win || win.isDestroyed()) return false;
  const enabled = alwaysOnTop === true;
  try {
    win.setAlwaysOnTop(enabled, enabled ? 'screen-saver' : 'normal');
  } catch (_) {
    try { win.setAlwaysOnTop(enabled); } catch (__) {}
  }
  try {
    if (process.platform === 'darwin' && typeof win.setVisibleOnAllWorkspaces === 'function') {
      win.setVisibleOnAllWorkspaces(enabled, { visibleOnFullScreen: enabled });
    }
  } catch (_) {}
  return enabled;
}


function normalizeLyricsScreenPosition(value, fallback = 'top') {
  const v = String(value || '').trim().toLowerCase();
  if (v === 'bottom' || v === 'below' || v === 'baixo' || v === 'down') return 'bottom';
  if (v === 'top' || v === 'above' || v === 'cima' || v === 'up') return 'top';
  return fallback;
}

function clampLyricsScale(value, fallback = 1, max = 1.25) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(0.35, Math.min(max, n));
}

function saveLyricsSettings(settings = {}, slot = 1) {
  const id = normalizeLyricsSlot(slot || settings.slot);
  const allowedFonts = ['Arial', 'Segoe UI', 'Verdana', 'Tahoma', 'Georgia', 'Trebuchet MS', 'Impact'];
  const all = getLyricsAllSettings();
  const next = { ...all[id] };
  if (settings.preset === 'day' || settings.preset === 'night') next.preset = settings.preset;
  if (typeof settings.textColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textColor)) next.textColor = settings.textColor;
  if (typeof settings.clockColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.clockColor)) next.clockColor = settings.clockColor;
  if (typeof settings.textBoxColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textBoxColor)) next.textBoxColor = settings.textBoxColor;
  if (typeof settings.borderColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.borderColor)) next.borderColor = settings.borderColor;
  if (settings.textCase === 'uppercase' || settings.textCase === 'lowercase' || settings.textCase === 'original') next.textCase = settings.textCase;
  if (allowedFonts.includes(settings.fontFamily)) next.fontFamily = settings.fontFamily;
  if (settings.textScale !== undefined) next.textScale = clampLyricsScale(settings.textScale, next.textScale || 1);
  if (typeof settings.rgbBorderEnabled === 'boolean') next.rgbBorderEnabled = settings.rgbBorderEnabled;
  if (typeof settings.rgbWindowBorderEnabled === 'boolean') next.rgbWindowBorderEnabled = settings.rgbWindowBorderEnabled;
  if (typeof settings.rgbClockBorderEnabled === 'boolean') next.rgbClockBorderEnabled = settings.rgbClockBorderEnabled;
  if (typeof settings.rgbTextBoxBorderEnabled === 'boolean') next.rgbTextBoxBorderEnabled = settings.rgbTextBoxBorderEnabled;
  if (typeof settings.borderEnabled === 'boolean') next.borderEnabled = settings.borderEnabled;
  if (typeof settings.windowBorderEnabled === 'boolean') next.windowBorderEnabled = settings.windowBorderEnabled;
  if (typeof settings.clockBorderEnabled === 'boolean') next.clockBorderEnabled = settings.clockBorderEnabled;
  if (typeof settings.textBoxEnabled === 'boolean') next.textBoxEnabled = settings.textBoxEnabled;
  if (typeof settings.clockEnabled === 'boolean') next.clockEnabled = settings.clockEnabled;
  if (typeof settings.songNameEnabled === 'boolean') next.songNameEnabled = settings.songNameEnabled;
  if (typeof settings.songNameColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.songNameColor)) next.songNameColor = settings.songNameColor;
  if (typeof settings.queueNameColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.queueNameColor)) next.queueNameColor = settings.queueNameColor;
  if (typeof settings.queueNameEnabled === 'boolean') next.queueNameEnabled = settings.queueNameEnabled;
  if (settings.queueNamePosition !== undefined) next.queueNamePosition = normalizeLyricsScreenPosition(settings.queueNamePosition, next.queueNamePosition || 'top');
  if (settings.queueNameDepth !== undefined) {
    const depth = Math.round(Number(settings.queueNameDepth));
    if (Number.isFinite(depth)) next.queueNameDepth = Math.max(0, Math.min(240, depth));
  }
  if (allowedFonts.includes(settings.queueNameFontFamily)) next.queueNameFontFamily = settings.queueNameFontFamily;
  if (allowedFonts.includes(settings.songNameFontFamily)) next.songNameFontFamily = settings.songNameFontFamily;
  if (settings.songNameScale !== undefined) next.songNameScale = clampLyricsScale(settings.songNameScale, next.songNameScale || 1, 3);
  if (settings.songNamePosition !== undefined) next.songNamePosition = normalizeLyricsScreenPosition(settings.songNamePosition, next.songNamePosition || 'top');
  if (typeof settings.progressEnabled === 'boolean') next.progressEnabled = settings.progressEnabled;
  if (settings.progressPosition !== undefined) next.progressPosition = normalizeLyricsScreenPosition(settings.progressPosition, next.progressPosition || 'bottom');
  if (typeof settings.progressColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.progressColor)) next.progressColor = settings.progressColor;
  if (settings.clockPosition === 'top' || settings.clockPosition === 'bottom') next.clockPosition = settings.clockPosition;
  if (settings.clockScale !== undefined) next.clockScale = clampLyricsScale(settings.clockScale, next.clockScale || 1, 2.5);
  if (settings.mediaScale !== undefined) next.mediaScale = clampLyricsScale(settings.mediaScale, next.mediaScale || 1, 1);
  if (typeof settings.previewEnabled === 'boolean') next.previewEnabled = settings.previewEnabled;
  if (settings.previewScale !== undefined) next.previewScale = clampLyricsScale(settings.previewScale, next.previewScale || 1, 1);
  if (typeof settings.alwaysOnTop === 'boolean') next.alwaysOnTop = settings.alwaysOnTop;
  if (typeof settings.clearMode === 'boolean') next.clearMode = settings.clearMode;
  all[id] = next;
  applyLyricsWindowPinState(id, next.alwaysOnTop === true);
  store.set('lyrics', all);
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) win.webContents.send('lyrics-settings-updated', { slot: id, settings: next });
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('lyrics-settings-updated', getLyricsAllSettings());
  return next;
}

function getTelepromptBackupPayload() {
  return {
    type: 'vshook-teleprompt-backup',
    version: 1,
    exportedAt: new Date().toISOString(),
    appVersion: app.getVersion(),
    lyrics: getLyricsAllSettings(),
    technicalNoticeSettings: getTechnicalNoticeSettings()
  };
}

function getBackupDialogWindow() {
  return isValidWindow(mainWindow) ? mainWindow : undefined;
}

function sanitizeBackupDeviceName(name) {
  const fallback = os.hostname() || 'Dispositivo';
  const raw = String(name || fallback || 'Dispositivo').trim();
  const normalized = raw.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  const compact = normalized.replace(/[^a-zA-Z0-9_-]+/g, '');
  return compact || 'Dispositivo';
}

function getBackupDefaultFileName() {
  const deviceName = sanitizeBackupDeviceName(getStoredDeviceName() || os.hostname());
  return `${deviceName}backupteleprompt.json`;
}

function getBackupDefaultPath() {
  const fileName = getBackupDefaultFileName();
  try {
    const documentsDir = app && app.getPath ? app.getPath('documents') : '';
    if (documentsDir) return path.join(documentsDir, fileName);
  } catch (_) {}
  return fileName;
}

async function exportLyricsBackup() {
  const options = {
    title: 'Exportar backup do Teleprompt',
    defaultPath: getBackupDefaultPath(),
    filters: [
      { name: 'Backup do Teleprompt', extensions: ['json'] },
      { name: 'Todos os arquivos', extensions: ['*'] }
    ]
  };
  const owner = getBackupDialogWindow();
  const result = owner ? await dialog.showSaveDialog(owner, options) : await dialog.showSaveDialog(options);
  if (result.canceled || !result.filePath) return { ok: false, cancelled: true };

  const payload = getTelepromptBackupPayload();
  fs.writeFileSync(result.filePath, JSON.stringify(payload, null, 2), 'utf8');
  return { ok: true, filePath: result.filePath, payload };
}

function pickImportedSlotSettings(source = {}, slot = 1) {
  if (!source || typeof source !== 'object') return null;
  const id = normalizeLyricsSlot(slot);
  return source[id] || source[String(id)] || source[`window${id}`] || (id === 1 ? source.one : source.two) || null;
}

function sourceLooksLikeSingleLyricsSettings(source = {}) {
  if (!source || typeof source !== 'object') return false;
  return ['textColor', 'clockColor', 'fontFamily', 'textScale', 'songNameEnabled', 'progressEnabled', 'progressPosition', 'progressColor', 'clearMode'].some((key) => Object.prototype.hasOwnProperty.call(source, key));
}

async function importLyricsBackup() {
  const options = {
    title: 'Importar backup do Teleprompt',
    properties: ['openFile'],
    filters: [
      { name: 'Backup do Teleprompt', extensions: ['json'] },
      { name: 'Todos os arquivos', extensions: ['*'] }
    ]
  };
  const owner = getBackupDialogWindow();
  const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
  if (result.canceled || !result.filePaths || !result.filePaths[0]) return { ok: false, cancelled: true };

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(result.filePaths[0], 'utf8'));
  } catch (_) {
    throw new Error('Arquivo de backup inválido. Selecione um JSON exportado pelo Teleprompt.');
  }

  const lyricsSource = parsed.lyrics || parsed.lyricsSettings || parsed.teleprompt || parsed.windows || parsed;
  const technicalSource = parsed.technicalNoticeSettings || parsed.technicalNotice || parsed.notices || null;
  let importedAny = false;

  if (sourceLooksLikeSingleLyricsSettings(lyricsSource)) {
    saveLyricsSettings(lyricsSource, 1);
    saveLyricsSettings(lyricsSource, 2);
    importedAny = true;
  } else {
    const slot1 = pickImportedSlotSettings(lyricsSource, 1);
    const slot2 = pickImportedSlotSettings(lyricsSource, 2);
    if (slot1 && typeof slot1 === 'object') {
      saveLyricsSettings(slot1, 1);
      importedAny = true;
    }
    if (slot2 && typeof slot2 === 'object') {
      saveLyricsSettings(slot2, 2);
      importedAny = true;
    }
  }

  if (technicalSource && typeof technicalSource === 'object') {
    saveTechnicalNoticeSettings(technicalSource);
    importedAny = true;
  }

  if (!importedAny) {
    throw new Error('Esse arquivo não possui configurações válidas do Teleprompt.');
  }

  return {
    ok: true,
    filePath: result.filePaths[0],
    lyrics: getLyricsAllSettings(),
    technicalNoticeSettings: getTechnicalNoticeSettings()
  };
}


function getBridgeScriptsDirCandidates(config) {
  const values = [
    process.env.VSHOOK_SCRIPTS_DIR,
    config?.scriptsDir,
    getDefaultReaperScriptsDir(),
    resolveBridgeScriptsDir(config)
  ].filter(Boolean);
  const seen = new Set();
  return values.map((value) => {
    try { return path.resolve(value); } catch (_) { return ''; }
  }).filter((value) => {
    if (!value || seen.has(value)) return false;
    seen.add(value);
    return true;
  });
}

function getLyricsStatePath(slot = 1) {
  const id = normalizeLyricsSlot(slot);
  const config = bridgeConfig || readBridgeConfig();
  const sharedDir = resolveBridgeScriptsDir(config);
  const fileName = `vshook_lyrics_state_${id}.json`;
  const candidates = getBridgeScriptsDirCandidates(config);
  for (const dir of candidates) {
    const slotPath = path.join(dir, fileName);
    if (fs.existsSync(slotPath)) return slotPath;
  }
  if (id === 1) {
    for (const dir of candidates) {
      const legacyPath = path.join(dir, 'vshook_lyrics_state.json');
      if (fs.existsSync(legacyPath)) return legacyPath;
    }
  }
  return path.join(sharedDir, fileName);
}

function getBridgeStatePath() {
  const config = bridgeConfig || readBridgeConfig();
  const sharedDir = resolveBridgeScriptsDir(config);
  return path.join(sharedDir, 'vshook_state.json');
}

function readJsonFileSafe(filePath, fallback = {}) {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    const raw = fs.readFileSync(filePath, 'utf8');
    if (!String(raw || '').trim()) return fallback;
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function getTechnicalNoticeStatePath() {
  const config = bridgeConfig || readBridgeConfig();
  const sharedDir = resolveBridgeScriptsDir(config);
  const fileName = 'vshook_technical_notice.json';
  for (const dir of getBridgeScriptsDirCandidates(config)) {
    const noticePath = path.join(dir, fileName);
    if (fs.existsSync(noticePath)) return noticePath;
  }
  return path.join(sharedDir, fileName);
}

function getActiveTechnicalNotice() {
  const data = readJsonFileSafe(getTechnicalNoticeStatePath(), null);
  if (!data || typeof data !== 'object') return null;
  const text = String(data.text || data.message || '').trim();
  const expiresAt = Number(data.expiresAt || 0);
  if (!text || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) return null;
  const sourceText = String(data.source || 'recados').trim().toLowerCase();
  const source = (sourceText === 'director' || sourceText === 'diretor')
    ? 'director'
    : ((sourceText === 'hooklyrics' || sourceText === 'hook-lyrics' || sourceText === 'lyrics') ? 'hooklyrics' : 'recados');
  const priority = source === 'director' ? 3 : (source === 'recados' ? 2 : 1);
  return {
    id: String(data.id || ''),
    text,
    message: text,
    source,
    priority,
    expiresAt,
    expiresAtIso: data.expiresAtIso || new Date(expiresAt).toISOString(),
    updatedAt: data.updatedAt || data.createdAt || null
  };
}

function normalizeLyricsMediaType(value) {
  const type = String(value || '').trim().toLowerCase();
  if (type === 'image' || type === 'img' || type === 'picture') return 'image';
  if (type === 'video' || type === 'movie') return 'video';
  if (type === 'empty' || type === 'none') return 'empty';
  return 'text';
}

function getFileUrlSafe(filePath) {
  const value = String(filePath || '').trim();
  if (!value) return '';
  if (/^(file|https?):\/\//i.test(value)) return value;
  try {
    return pathToFileURL(path.resolve(value)).toString();
  } catch (_) {
    return '';
  }
}

function inferLyricsMediaTypeFromPath(filePath) {
  const ext = path.extname(String(filePath || '').split('?')[0]).replace(/^\./, '').toLowerCase();
  if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'svg'].includes(ext)) return 'image';
  if (['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'].includes(ext)) return 'video';
  return 'text';
}

function getNativeTelepromptMediaUrl(rawUrl, filePath) {
  // FIX108: nas janelas locais do Teleprompt do Hook Center, o caminho real
  // do arquivo e a verdade principal. Isso evita proxy HTTP para video local
  // e deixa o <video> tocar o mesmo arquivo do item do grid, sincronizado por
  // mediaCurrentTime/mediaOffset/mediaPlayrate. App Diretor continua texto.
  const rawPath = String(filePath || '').trim();
  if (rawPath) return getFileUrlSafe(rawPath);
  const value = String(rawUrl || '').trim();
  if (!value) return '';
  return getFileUrlSafe(value);
}

function requestNativeBridgeStateForLyrics(timeoutMs = 220) {
  return new Promise((resolve) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: Number(process.env.VSHOOK_NATIVE_BRIDGE_PORT || 47830),
      path: '/state',
      method: 'GET',
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; if (body.length > 1024 * 1024 * 2) req.destroy(); });
      res.on('end', () => {
        try {
          const data = body ? JSON.parse(body) : null;
          resolve(data && data.connected ? data : null);
        } catch (_) {
          resolve(null);
        }
      });
    });
    req.on('timeout', () => { try { req.destroy(); } catch (_) {} resolve(null); });
    req.on('error', () => resolve(null));
    req.end();
  });
}


function normalizePreviewText(value) {
  return String(value || '').trim();
}

function normalizePreviewBlockName(value, fallback = '') {
  const raw = normalizePreviewText(value || fallback);
  return raw
    .replace(/^\s*[:：]+\s*/g, '')
    .replace(/\s*[:：]+\s*$/g, '')
    .trim();
}

function nativeItemIdCandidates(item = {}) {
  return [item.playlistEntryId, item.id, item.songId, item.regionId, item.sourceNumber, item.number]
    .map((v) => String(v ?? '').trim())
    .filter(Boolean);
}

function nativeItemMatchesIdOrRange(item = {}, idValue = '', startValue = 0, endValue = 0) {
  // FIX TP QUEUE LUA: a fila vinda do Lua precisa casar primeiro por posição.
  // Em repertórios com blocos/índices visuais, o id/sourceNumber pode bater na
  // música de baixo antes de o TP olhar o start/end correto.
  const start = Number(startValue || 0);
  const end = Number(endValue || 0);
  if (Number.isFinite(start) && Number.isFinite(end) && end > start) {
    const itemStart = Number(item.start ?? item.startPos ?? item.selectedStartPos ?? item.queuedStartPos ?? 0);
    const itemEnd = Number(item.end ?? item.endPos ?? item.selectedEndPos ?? item.queuedEndPos ?? 0);
    if (Math.abs(itemStart - start) <= 0.01 && Math.abs(itemEnd - end) <= 0.01) return true;
  }
  const id = String(idValue || '').trim();
  if (id && nativeItemIdCandidates(item).includes(id)) return true;
  return false;
}

function findActivePreviewPlaylist(nativeState = {}) {
  const playlists = Array.isArray(nativeState.playlists) ? nativeState.playlists : [];
  if (!playlists.length) return null;
  const activeIndex = Number(nativeState.currentPlaylistIndex || nativeState.activePlaylistIndex || nativeState.activePlaylistId || 0);
  const activeName = String(nativeState.currentPlaylistName || nativeState.activePlaylistName || '').trim();
  return playlists.find((p) => p && (p.active === true || p.current === true)) ||
    playlists.find((p) => Number(p.id || p.index || 0) === activeIndex) ||
    playlists.find((p) => String(p.name || '').trim() === activeName) || playlists[0];
}

function getPreviewQueueTarget(nativeState = {}) {
  const id = String(
    nativeState.queuedPlaylistSongId ??
    nativeState.queuedSongId ??
    nativeState.queuedRegionId ??
    nativeState.queuedRegionNumber ??
    nativeState.queueSongId ??
    ''
  ).trim();
  const start = Number(
    nativeState.queuedStartPos ??
    nativeState.queuedRegionStart ??
    nativeState.queueStartPos ??
    nativeState.queuedStart ??
    0
  );
  const end = Number(
    nativeState.queuedEndPos ??
    nativeState.queuedRegionEnd ??
    nativeState.queueEndPos ??
    nativeState.queuedEnd ??
    0
  );
  const name = normalizePreviewText(
    nativeState.queuedSongName ||
    nativeState.queueSongName ||
    nativeState.queuedName ||
    nativeState.queueName ||
    ''
  );
  return { id, start, end, name };
}

function getPreviewSongNameFromQueue(nativeState = {}, songs = []) {
  const queue = getPreviewQueueTarget(nativeState);
  const found = songs.find((item) => item && nativeItemMatchesIdOrRange(item, queue.id, queue.start, queue.end));
  return normalizePreviewText(found?.name || found?.title || found?.label || queue.name || '');
}


function getNativeQueuedSongName(nativeState = {}) {
  const playlist = findActivePreviewPlaylist(nativeState);
  const items = Array.isArray(playlist?.songs) ? playlist.songs : [];
  const songItems = items.filter((item) => {
    if (!item || typeof item !== 'object') return false;
    const type = String(item.type || item.itemType || '').toLowerCase();
    const sourceNumber = Number(item.sourceNumber || 0);
    return !(item.isBlock === true || type === 'block' || sourceNumber < 0);
  });
  return getPreviewSongNameFromQueue(nativeState, songItems);
}

function isNativePreviewSongQueued(item = {}, queue = {}, resolvedQueueName = '') {
  if (!item || typeof item !== 'object') return false;
  if (nativeItemMatchesIdOrRange(item, queue.id, queue.start, queue.end)) return true;
  const itemName = normalizePreviewText(item.name || item.title || item.label || '').toLowerCase();
  const queueName = normalizePreviewText(resolvedQueueName || queue.name || '').toLowerCase();
  return !!queueName && itemName === queueName;
}

function buildNativePreviewOverlay(nativeState = {}) {
  const mode = Number(nativeState.previewMode || nativeState.previewIndex || 0);
  if (!Number.isFinite(mode) || mode < 1 || mode > 3) return null;
  const playlist = findActivePreviewPlaylist(nativeState);
  const items = Array.isArray(playlist?.songs) ? playlist.songs : [];

  const playingId = String(nativeState.playingSongId || nativeState.currentSongId || nativeState.playingId || '').trim();
  const playingStart = Number(nativeState.currentSongStart || nativeState.playbackStartPos || 0);
  const playingEnd = Number(nativeState.currentSongEnd || nativeState.playbackEndPos || 0);
  const playing = Boolean(nativeState.playing || nativeState.isPlaying || nativeState.transportPlaying);
  const queue = getPreviewQueueTarget(nativeState);
  const allSongItems = [];
  const allBlocks = [];
  let current = null;

  for (const item of items) {
    if (!item || typeof item !== 'object') continue;
    const type = String(item.type || item.itemType || '').toLowerCase();
    const sourceNumber = Number(item.sourceNumber || 0);
    const isBlock = item.isBlock === true || type === 'block' || sourceNumber < 0;
    if (isBlock) {
      current = { name: normalizePreviewBlockName(item.name || item.title, `Bloco ${allBlocks.length + 1}`), songs: [] };
      allBlocks.push(current);
      continue;
    }

    allSongItems.push(item);
    if (!current) {
      current = { name: 'Sem bloco', songs: [] };
      allBlocks.push(current);
    }

    const name = normalizePreviewText(item.name || item.title || item.label || '');
    if (!name || current.songs.length >= 18) continue;
    current.songs.push({
      id: String(item.playlistEntryId || item.id || item.songId || item.regionId || item.sourceNumber || item.number || ''),
      name,
      playing: playing && nativeItemMatchesIdOrRange(item, playingId, playingStart, playingEnd),
      queued: false
    });
  }

  const resolvedQueueName = getPreviewSongNameFromQueue(nativeState, allSongItems);
  for (const block of allBlocks) {
    for (const song of block.songs) {
      const matchingItem = allSongItems.find((item) => {
        const itemName = normalizePreviewText(item.name || item.title || item.label || '');
        return itemName === song.name && nativeItemIdCandidates(item).includes(song.id);
      }) || allSongItems.find((item) => normalizePreviewText(item.name || item.title || item.label || '') === song.name);
      song.queued = isNativePreviewSongQueued(matchingItem || { name: song.name, id: song.id }, queue, resolvedQueueName);
    }
  }

  const offset = (mode - 1) * 8;
  const pageBlocks = allBlocks.slice(offset, offset + 8);

  return {
    active: true,
    mode,
    playlistName: normalizePreviewText(playlist?.name || nativeState.currentPlaylistName || ''),
    blocks: pageBlocks,
    totalBlocks: allBlocks.length,
    noSongsMessage: 'Sem músicas',
    playingSongName: normalizePreviewText(nativeState.currentSongName || nativeState.playingSongName || ''),
    queuedSongName: resolvedQueueName
  };
}

function normalizeNativeTimerPayload(source) {
  const root = source && typeof source === 'object' ? source : {};
  const nested = root.timer && typeof root.timer === 'object' ? root.timer : {};
  const pick = (...values) => values.find((value) => value !== undefined && value !== null && value !== '');
  const displaySecRaw = pick(root.timerDisplaySec, nested.displaySec, 0);
  const displayText = String(pick(root.timerDisplayText, nested.displayText, root.timerLocalTimeText, nested.localTimeText, '') || '');
  const expired = Boolean(
    root.timerExpired || root.timerOverrun || root.timerNegative ||
    nested.expired || nested.overrun || nested.negative ||
    displayText.trim().startsWith('-') || Number(displaySecRaw) < 0
  );
  return {
    running: Boolean(pick(root.timerRunning, root.timerActive, nested.running, nested.active, false)),
    startedAt: Number(pick(root.timerStartedAt, root.timerStartedAtMs, nested.startedAt, nested.startedAtMs, 0)) || 0,
    accumulatedSec: Number(pick(root.timerAccumulatedSec, nested.accumulatedSec, 0)) || 0,
    mode: String(pick(root.timerMode, root.timerType, nested.mode, nested.type, 'progressive') || 'progressive'),
    targetSec: Number(pick(root.timerTargetSec, root.timerCountdownStartSec, nested.targetSec, 0)) || 0,
    displaySec: Number(displaySecRaw) || 0,
    expired,
    overrunSec: Number(pick(root.timerOverrunSec, nested.overrunSec, 0)) || 0,
    displayText,
    localTimeText: String(pick(root.timerLocalTimeText, nested.localTimeText, '') || '')
  };
}

function normalizeNativeTelepromptState(nativeState, slot) {
  if (!nativeState || typeof nativeState !== 'object') return null;
  const id = normalizeLyricsSlot(slot);
  const tp = id === 2 ? (nativeState.tp2 || null) : (nativeState.tp1 || null);
  const prefix = id === 2 ? 'tp2' : 'tp1';
  const telePrefix = id === 2 ? 'telepromptTp2' : 'telepromptTp1';
  const raw = tp && typeof tp === 'object' ? tp : {};
  const projectPosition = Number(raw.position ?? raw.projectPosition ?? nativeState.position ?? nativeState.playPosition ?? 0) || 0;
  const mediaPath = String(raw.mediaPath || raw.path || nativeState[`${prefix}MediaPath`] || nativeState[`${telePrefix}MediaPath`] || '');
  const nativeMediaType = normalizeLyricsMediaType(raw.telepromptType || raw.mediaType || raw.type || nativeState[`${prefix}MediaType`] || nativeState[`${telePrefix}MediaType`] || '');
  const rawMediaUrl = String(raw.mediaUrl || raw.url || nativeState[`${prefix}MediaUrl`] || nativeState[`${telePrefix}MediaUrl`] || '');
  const inferredMediaType = inferLyricsMediaTypeFromPath(mediaPath || rawMediaUrl);
  // FIX108: se existe caminho/extensao de mídia, ele manda no tipo.
  // mediaType separado fica só como fallback para texto/empty.
  const mediaType = inferredMediaType !== 'text' ? inferredMediaType : (nativeMediaType || 'text');
  const mediaUrl = getNativeTelepromptMediaUrl(rawMediaUrl, mediaPath);
  const previewOverlay = buildNativePreviewOverlay(nativeState);
  const nativeQueuedSongName = previewOverlay ? String(previewOverlay.queuedSongName || '') : getNativeQueuedSongName(nativeState);
  const nativeTimer = normalizeNativeTimerPayload(nativeState);
  // FIX109: se houver texto e mídia no mesmo ponto, texto fica sobreposto.
  const textValue = String(raw.overlayText || raw.text || raw.lyrics || raw.lyricsText || nativeState[`${prefix}LyricsText`] || nativeState[`${prefix}Lyrics`] || nativeState[`${telePrefix}Lyrics`] || nativeState[`${telePrefix}Text`] || '');
  const songValue = String(raw.song || raw.songName || raw.currentSongName || raw.musicName || nativeState[`${prefix}SongName`] || nativeState[`${telePrefix}SongName`] || nativeState.currentSongName || nativeState.playingSongName || nativeState.songName || '');
  const hasNativeTp = !!(tp || textValue || songValue || nativeQueuedSongName || previewOverlay || raw.trackFound === true || raw.itemFound === true || nativeState[`${prefix}UpdatedAt`]);
  if (!hasNativeTp) return null;
  const media = {
    type: mediaType,
    path: mediaPath,
    url: mediaUrl,
    ext: String(raw.mediaExt || ''),
    currentTime: Math.max(0, Number(raw.mediaCurrentTime || raw.videoCurrentTime || 0)),
    offset: Math.max(0, Number(raw.mediaOffset || 0)),
    playrate: Number(raw.mediaPlayrate || raw.playrate || 1) || 1,
    itemGuid: String(raw.itemGuid || ''),
    itemStart: Number(raw.itemStart || 0),
    itemEnd: Number(raw.itemEnd || 0),
    itemLength: Number(raw.itemLength || 0)
  };
  return {
    slot: id,
    text: textValue,
    song: songValue,
    part: String(raw.part || raw.currentPart || ''),
    telepromptType: mediaType,
    mediaType,
    mediaPath,
    mediaUrl,
    mediaCurrentTime: media.currentTime,
    mediaOffset: media.offset,
    mediaPlayrate: media.playrate,
    media,
    position: projectPosition,
    itemGuid: media.itemGuid,
    itemStart: media.itemStart,
    itemEnd: media.itemEnd,
    itemLength: media.itemLength,
    timerRunning: nativeTimer.running,
    timerStartedAt: nativeTimer.startedAt,
    timerAccumulatedSec: nativeTimer.accumulatedSec,
    timerMode: nativeTimer.mode,
    timerType: nativeTimer.mode,
    timerTargetSec: nativeTimer.targetSec,
    timerCountdownStartSec: nativeTimer.targetSec,
    timerDisplaySec: nativeTimer.displaySec,
    timerExpired: nativeTimer.expired,
    timerOverrun: nativeTimer.expired,
    timerNegative: nativeTimer.expired,
    timerOverrunSec: nativeTimer.overrunSec,
    timerDisplayText: nativeTimer.displayText,
    timerLocalTimeText: nativeTimer.localTimeText,
    playing: Boolean(raw.playing || nativeState.playing || nativeState.isPlaying),
    updatedAt: raw.updatedAt || nativeState[`${prefix}UpdatedAt`] || nativeState.updatedAt || null,
    previewOverlay,
    queuedSongName: nativeQueuedSongName,
    technicalNotice: getActiveTechnicalNotice(),
    technicalNoticeSettings: getTechnicalNoticeSettings()
  };
}

async function getLyricsState(slot = 1) {
  const id = normalizeLyricsSlot(slot);
  const nativeState = await requestNativeBridgeStateForLyrics();
  const nativeTpState = normalizeNativeTelepromptState(nativeState, id);
  if (nativeTpState) return nativeTpState;

  const data = readJsonFileSafe(getLyricsStatePath(id), {});
  const bridgeState = readJsonFileSafe(getBridgeStatePath(), {});
  const timerSource = (typeof data.timerRunning === 'boolean' || Number(data.timerStartedAt || 0) || Number(data.timerAccumulatedSec || 0)) ? data : bridgeState;
  const fallbackTimer = normalizeNativeTimerPayload(timerSource);
  const mediaPath = String(data.mediaPath || data.path || '');
  const dataMediaUrl = String(data.mediaUrl || '');
  const dataMediaType = normalizeLyricsMediaType(data.telepromptType || data.mediaType || data.type);
  const inferredDataMediaType = inferLyricsMediaTypeFromPath(mediaPath || dataMediaUrl);
  const mediaType = inferredDataMediaType !== 'text' ? inferredDataMediaType : (dataMediaType || 'text');
  const mediaUrl = mediaPath ? getFileUrlSafe(mediaPath) : getFileUrlSafe(dataMediaUrl);
  // FIX109: texto pode coexistir com imagem/video na janela local do Teleprompt.
  const textValue = String(data.overlayText || data.text || data.lyrics || data.lyricsText || '');
  const songValue = String(
    data.song || data.songName || data.currentSong || data.currentSongName || data.musicName || data.playingSongName ||
    bridgeState.songName || bridgeState.currentSongName || bridgeState.musicName || bridgeState.playingSongName || ''
  );
  const media = {
    type: mediaType,
    path: mediaPath,
    url: mediaUrl,
    ext: String(data.mediaExt || ''),
    currentTime: Math.max(0, Number(data.mediaCurrentTime || data.videoCurrentTime || 0)),
    offset: Math.max(0, Number(data.mediaOffset || 0)),
    playrate: Number(data.mediaPlayrate || data.playrate || 1) || 1,
    itemGuid: String(data.itemGuid || ''),
    itemStart: Number(data.itemStart || 0),
    itemEnd: Number(data.itemEnd || 0),
    itemLength: Number(data.itemLength || 0)
  };
  const projectPosition = Number(data.position ?? data.projectPosition ?? bridgeState.position ?? bridgeState.playPosition ?? 0) || 0;
  return {
    slot: id,
    text: textValue,
    song: songValue,
    part: String(data.part || data.currentPart || ''),
    telepromptType: mediaType,
    mediaType,
    mediaPath,
    mediaUrl,
    mediaCurrentTime: media.currentTime,
    mediaOffset: media.offset,
    mediaPlayrate: media.playrate,
    media,
    position: projectPosition,
    itemGuid: media.itemGuid,
    itemStart: media.itemStart,
    itemEnd: media.itemEnd,
    itemLength: media.itemLength,
    timerRunning: fallbackTimer.running,
    timerStartedAt: fallbackTimer.startedAt,
    timerAccumulatedSec: fallbackTimer.accumulatedSec,
    timerMode: fallbackTimer.mode,
    timerType: fallbackTimer.mode,
    timerTargetSec: fallbackTimer.targetSec,
    timerCountdownStartSec: fallbackTimer.targetSec,
    timerDisplaySec: fallbackTimer.displaySec,
    timerExpired: fallbackTimer.expired,
    timerOverrun: fallbackTimer.expired,
    timerNegative: fallbackTimer.expired,
    timerOverrunSec: fallbackTimer.overrunSec,
    timerDisplayText: fallbackTimer.displayText,
    timerLocalTimeText: fallbackTimer.localTimeText,
    playing: Boolean(data.playing || bridgeState.playing || bridgeState.isPlaying),
    updatedAt: data.updatedAt || bridgeState.updatedAt || null,
    previewOverlay: null,
    queuedSongName: '',
    technicalNotice: getActiveTechnicalNotice(),
    technicalNoticeSettings: getTechnicalNoticeSettings()
  };
}
function createLyricsWindow(slot = 1) {
  const id = Number(slot) === 2 ? 2 : 1;
  const existing = lyricsWindows.get(id);
  if (existing && !existing.isDestroyed()) {
    lyricsWindows.delete(id);
    existing.close();
    return { ok: true, slot: id, opened: false, closed: true };
  }

  const win = new BrowserWindow({
    width: 980,
    height: 560,
    // Janela do Teleprompt precisa aceitar formatos extremos, inclusive 9:16 vertical.
    minWidth: 180,
    minHeight: 180,
    // Janelas transparentes sem moldura podem falhar ao recompor entre
    // monitores. O Teleprompt usa fundo preto, então fica opaco em todas as
    // plataformas para manter a imagem estável em telas múltiplas.
    backgroundColor: '#000000',
    title: 'Teleprompt',
    icon: getAppIconPath(),
    frame: false,
    // Mantem handles nativos de redimensionamento em janela sem moldura, especialmente no Windows.
    thickFrame: true,
    transparent: false,
    roundedCorners: false,
    focusable: true,
    movable: true,
    resizable: true,
    useContentSize: true,
    hasShadow: false,
    acceptFirstMouse: true,
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: false
    }
  });

  lyricsWindows.set(id, win);
  applyLyricsWindowPinState(id, getLyricsSettings(id).alwaysOnTop === true);
  try { win.setResizable(true); } catch (_) {}
  try { win.setMinimumSize(180, 180); } catch (_) {}
  try { win.setIgnoreMouseEvents(false); } catch (_) {}
  win.loadFile(path.join(__dirname, 'lyrics.html'), { query: { slot: String(id) } });
  win.once('ready-to-show', () => {
    try { win.setIgnoreMouseEvents(false); } catch (_) {}
    win.show();
    try { win.focus(); } catch (_) {}
    broadcastLyricsWindowsState();
  });
  win.on('enter-full-screen', () => { win.__vshookFullScreen = true; });
  win.on('leave-full-screen', () => { win.__vshookFullScreen = false; });
  win.on('closed', () => {
    lyricsWindows.delete(id);
    setImmediate(() => broadcastLyricsWindowsState());
  });
  broadcastLyricsWindowsState();
  return { ok: true, slot: id, opened: true, closed: false, lyricsWindows: getLyricsWindowsState() };
}

function getLyricsWindowsState() {
  return {
    oneOpen: !!(lyricsWindows.get(1) && !lyricsWindows.get(1).isDestroyed()),
    twoOpen: !!(lyricsWindows.get(2) && !lyricsWindows.get(2).isDestroyed())
  };
}

function broadcastLyricsWindowsState() {
  const windowsState = getLyricsWindowsState();
  if (isValidWindow(mainWindow)) {
    try { mainWindow.webContents.send('lyrics-windows-state-updated', windowsState); } catch (_) {}
  }
  return windowsState;
}

function toggleLyricsWindowFullscreen(win) {
  if (!win || win.isDestroyed()) return { ok: false };

  const isReallyFullScreen = (() => {
    try { return win.isFullScreen(); } catch (_) { return false; }
  })();
  const isFullScreen = isReallyFullScreen || win.__vshookFullScreen === true;

  if (isFullScreen) {
    win.__vshookFullScreen = false;
    try { win.setFullScreen(false); } catch (_) {}
    try { if (win.setSimpleFullScreen) win.setSimpleFullScreen(false); } catch (_) {}

    const restoreBounds = win.__vshookBeforeFullScreenBounds || null;
    if (restoreBounds && Number.isFinite(Number(restoreBounds.width)) && Number.isFinite(Number(restoreBounds.height))) {
      setTimeout(() => {
        if (!win || win.isDestroyed()) return;
        try { win.setBounds(restoreBounds, false); } catch (_) {}
        try { win.focus(); } catch (_) {}
      }, 160);
    }

    return { ok: true, fullScreen: false };
  }

  try { win.__vshookBeforeFullScreenBounds = win.getBounds(); } catch (_) { win.__vshookBeforeFullScreenBounds = null; }
  win.__vshookFullScreen = true;
  try { win.setFullScreen(true); } catch (_) {}
  return { ok: true, fullScreen: true };
}

function getAppState() {
  const hookCenterBinaryVersion = app.getVersion();
  const installedVsHookVersion = getInstalledVsHookVersion();
  return {
    // A versão binária continua separada e é a única usada para decidir se o
    // instalador da Hook Center precisa ser baixado novamente.
    currentVersion: hookCenterBinaryVersion,
    hookCenterBinaryVersion,
    // No Status, a Central acompanha a versão do pacote VS Hook efetivamente
    // instalado a partir da publicação do backend, mesmo quando esse pacote
    // não traz um novo instalador da Hook Center.
    statusDisplayVersion: installedVsHookVersion || hookCenterBinaryVersion,
    lastCheck: store.get('lastCheck'),
    updateAvailable: store.get('updateAvailable'),
    latestUpdate: store.get('latestUpdate'),
    testClientUpdate: store.get('testClientUpdate'),
    hookCenterLatest: store.get('hookCenterLatest'),
    hookCenterUpdateAvailable: store.get('hookCenterUpdateAvailable'),
    downloadedHookCenterUpdate: store.get('downloadedHookCenterUpdate'),
    bridgeAppLatest: store.get('bridgeAppLatest'),
    bridgeAppUpdateAvailable: store.get('bridgeAppUpdateAvailable'),
    bridgeAppInstalled: store.get('bridgeAppInstalled'),
    bridgeAppPath: getBridgeWebAppDir(),
    lastNotifiedUpdateId: store.get('lastNotifiedUpdateId'),
    downloadedFiles: store.get('downloadedFiles'),
    installedManifest: store.get('installedManifest'),
    installedVsHookVersion,
    license: store.get('license'),
    machineId: (store.get('license') || {}).machineId || '',
    deviceName: getStoredDeviceName(),
    deviceLoginEmail: store.get('deviceLoginEmail') || (store.get('license') || {}).email || '',
    
    platform: process.platform,
    platformKey: getPlatformKey(),
    hookCenterPlatformKey: getHookCenterPlatformKey(),
    legacyHookCenter: isHookCenterLegacyBuild(),
    arch: process.arch,
    machineIdPath: getSharedMachineIdPath(),
    licensePath: '',
    bridge: getBridgeState(),
    lyrics: getLyricsAllSettings(),
    technicalNoticeSettings: getTechnicalNoticeSettings(),
    lyricsWindows: getLyricsWindowsState()
  };
}

function ensureAbsoluteUrl(url) {
  if (!url) return '';
  if (/^https?:\/\//i.test(url)) return url;
  return `${BACKEND_URL}${url.startsWith('/') ? '' : '/'}${url}`;
}

function getPlatformKey() {
  return process.platform === 'darwin' ? 'macos' : 'windows';
}

function isHookCenterLegacyBuild() {
  return process.platform === 'darwin' && /legacy/i.test(app.getName() || '');
}

function getHookCenterPlatformKey() {
  if (isHookCenterLegacyBuild()) return 'macos-legacy';
  return getPlatformKey();
}

function getPlatformFiles(update) {
  return update?.files?.[getPlatformKey()] || {};
}

function getPlatformUpdateId(update) {
  const platformKey = getPlatformKey();
  const platformMeta = update?.platforms?.[platformKey] || update?.files?.platforms?.[platformKey] || {};
  return platformMeta.updateId || platformMeta.version || update?.updateId || update?.version || null;
}

function hasInstallableFiles(update) {
  return buildPayloadEntries(getPlatformFiles(update)).length > 0;
}

function entriesChangedSinceLastInstall(update, entries) {
  const platformKey = getPlatformKey();
  const installed = store.get('installedManifest') || {};
  const installedFiles = installed.platform === platformKey ? (installed.files || {}) : {};
  return entries.filter((entry) => {
    const previous = installedFiles[entry.key];
    return !previous || previous.url !== entry.url;
  });
}

function buildPayloadEntries(files) {
  const betaLuaUrl = ensureAbsoluteUrl(files.betaLua || files.proLua || files.lua);
  const estableLuaUrl = ensureAbsoluteUrl(files.estableLua || files.stableLua || files.basicLua);

  if (process.platform === 'win32') {
    return [
      { key: 'betaLua', url: betaLuaUrl, filename: 'VS Hook Beta.lua' },
      { key: 'estableLua', url: estableLuaUrl, filename: 'VS Hook Estable.lua' },
      { key: 'vshookDll', url: ensureAbsoluteUrl(files.vshookDll), filename: 'reaper_vshook.dll' },
      { key: 'jsApiDll', url: ensureAbsoluteUrl(files.jsApiDll), filename: 'reaper_js_ReaScriptAPI64.dll' }
    ].filter((entry) => !!entry.url);
  }

  if (process.platform === 'darwin') {
    const isAppleSilicon = process.arch === 'arm64';
    const jsApiUrl = ensureAbsoluteUrl(
      isAppleSilicon
        ? (files.armJsApiDylib || files.jsApiArmDylib || files.jsApiDylib)
        : (files.intelJsApiDylib || files.jsApiIntelDylib || files.jsApiDylib)
    );

    return [
      { key: 'betaLua', url: betaLuaUrl, filename: 'VS Hook Beta.lua' },
      { key: 'estableLua', url: estableLuaUrl, filename: 'VS Hook Estable.lua' },
      { key: 'vshookDylib', url: ensureAbsoluteUrl(files.vshookDylib), filename: 'reaper_vshook.dylib' },
      { key: 'jsApiDylib', url: jsApiUrl, filename: 'reaper_js_ReaScriptAPI.dylib' }
    ].filter((entry) => !!entry.url);
  }

  return [];
}

async function downloadFile(url, destPath, onProgress) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Falha ao baixar ${url}: HTTP ${response.status}`);

  const total = Number(response.headers.get('content-length')) || 0;
  fs.mkdirSync(path.dirname(destPath), { recursive: true });

  const file = fs.createWriteStream(destPath);
  let downloaded = 0;

  if (!response.body || typeof response.body.getReader !== 'function') {
    const buffer = Buffer.from(await response.arrayBuffer());
    file.write(buffer);
    file.end();
    await new Promise((resolve, reject) => {
      file.on('finish', resolve);
      file.on('error', reject);
    });
    onProgress(100);
    return;
  }

  const reader = response.body.getReader();

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const chunk = Buffer.from(value);
      downloaded += chunk.length;

      if (!file.write(chunk)) {
        await new Promise((resolve) => file.once('drain', resolve));
      }

      if (total > 0) onProgress(Math.round((downloaded / total) * 100));
    }
  } finally {
    file.end();
  }

  await new Promise((resolve, reject) => {
    file.on('finish', resolve);
    file.on('error', reject);
  });

  onProgress(100);
}

async function downloadLatestUpdate(updateOverride = null) {
  let update = updateOverride || store.get('latestUpdate');
  if (!update?.files) {
    const checked = await checkForUpdates(true);
    update = checked.update || store.get('latestUpdate');
  }

  if (!update) throw new Error('Nenhuma atualização disponível no momento.');

  const files = getPlatformFiles(update);
  const allEntries = buildPayloadEntries(files);
  const changedEntries = entriesChangedSinceLastInstall(update, allEntries);
  const entries = changedEntries.length > 0 ? changedEntries : allEntries;

  if (entries.length === 0) {
    throw new Error('Atualização indisponível para este sistema no momento.');
  }

  const downloadDir = path.join(app.getPath('userData'), 'downloads', update.updateId || update.version || 'latest');
  const output = {};

  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i];
    const dest = path.join(downloadDir, entry.filename);
    await downloadFile(entry.url, dest, (fileProgress) => {
      const totalProgress = Math.round(((i * 100) + fileProgress) / entries.length);
      if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', totalProgress);
    });
    output[entry.key] = dest;
  }

  store.set('downloadedFiles', {
    updateId: getPlatformUpdateId(update),
    globalUpdateId: update.updateId,
    version: update.version,
    platform: getPlatformKey(),
    files: output,
    manifest: {
      platform: getPlatformKey(),
      updateId: getPlatformUpdateId(update),
      version: update.version || '',
      files: Object.fromEntries(entries.map((entry) => [entry.key, { url: entry.url, filename: entry.filename }]))
    }
  });

  if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', 100);
  return { ok: true, files: output };
}

function copyFileEnsured(source, destination) {
  if (!source || !fs.existsSync(source)) return;
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function getWindowsPublicVsHookDir() {
  const publicDir = process.env.PUBLIC || process.env.ALLUSERSPROFILE || 'C:\\Users\\Public';
  return path.join(publicDir, 'VS Hook APP');
}

function getWindowsReaperUserPluginsDir() {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'REAPER', 'UserPlugins');
}

function removeLegacyVsHookLuaFiles(dir) {
  if (!dir) return;
  for (const filename of ['VS Hook Pro.lua', 'VS Hook Basic.lua', 'VS Hook.lua', 'Hook Lyrics.lua', 'Hook lyrics.lua']) {
    try { fs.rmSync(path.join(dir, filename), { force: true }); } catch (_) {}
  }
}

function installWindowsPayload(files) {
  const publicVsHookDir = getWindowsPublicVsHookDir();

  removeLegacyVsHookLuaFiles(publicVsHookDir);
  removeLegacyVsHookLuaFiles(path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'REAPER', 'Scripts', 'VS Hook APP'));
  removeLegacyVsHookLuaFiles(path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'REAPER', 'Scripts'));

  copyFileEnsured(files.betaLua || files.proLua || files.lua, path.join(publicVsHookDir, 'VS Hook Beta.lua'));
  copyFileEnsured(files.estableLua || files.stableLua || files.basicLua, path.join(publicVsHookDir, 'VS Hook Estable.lua'));

  copyFileEnsured(files.vshookDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_vshook.dll'));
  copyFileEnsured(files.jsApiDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_js_ReaScriptAPI64.dll'));
}

function installMacPayload(files) {
  const commands = [];
  const betaLuaSource = files.betaLua || files.proLua || files.lua;
  const estableLuaSource = files.estableLua || files.stableLua || files.basicLua;
  const vshookSource = files.vshookDylib;
  const jsApiSource = files.jsApiDylib;

  commands.push('set -e');
  commands.push('GLOBAL_REAPER="/Library/Application Support/REAPER"');
  commands.push('GLOBAL_SCRIPT_DIR="$GLOBAL_REAPER/Scripts/VS Hook APP"');
  commands.push('GLOBAL_PLUGIN_DIR="$GLOBAL_REAPER/UserPlugins"');
  commands.push('mkdir -p "$GLOBAL_SCRIPT_DIR" "$GLOBAL_PLUGIN_DIR"');

  commands.push('rm -f "$GLOBAL_SCRIPT_DIR/VS Hook Pro.lua" "$GLOBAL_SCRIPT_DIR/VS Hook Basic.lua" "$GLOBAL_SCRIPT_DIR/VS Hook.lua" "$GLOBAL_SCRIPT_DIR/Hook Lyrics.lua" "$GLOBAL_SCRIPT_DIR/Hook lyrics.lua" 2>/dev/null || true');
  if (betaLuaSource) commands.push(`cp -f ${shellQuote(betaLuaSource)} "$GLOBAL_SCRIPT_DIR/VS Hook Beta.lua"`);
  if (estableLuaSource) commands.push(`cp -f ${shellQuote(estableLuaSource)} "$GLOBAL_SCRIPT_DIR/VS Hook Estable.lua"`);
  if (vshookSource) commands.push(`cp -f ${shellQuote(vshookSource)} "$GLOBAL_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`cp -f ${shellQuote(jsApiSource)} "$GLOBAL_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('chmod 644 "$GLOBAL_SCRIPT_DIR/VS Hook Beta.lua" "$GLOBAL_SCRIPT_DIR/VS Hook Estable.lua" 2>/dev/null || true');
  commands.push('chmod 755 "$GLOBAL_PLUGIN_DIR"/*.dylib 2>/dev/null || true');

  commands.push('for USER_HOME in /Users/*; do');
  commands.push('  [ -d "$USER_HOME" ] || continue');
  commands.push('  USER_NAME=$(basename "$USER_HOME")');
  commands.push('  [ "$USER_NAME" = "Shared" ] && continue');
  commands.push('  USER_REAPER="$USER_HOME/Library/Application Support/REAPER"');
  commands.push('  USER_SCRIPT_DIR="$USER_REAPER/Scripts/VS Hook APP"');
  commands.push('  USER_PLUGIN_DIR="$USER_REAPER/UserPlugins"');
  commands.push('  mkdir -p "$USER_SCRIPT_DIR" "$USER_PLUGIN_DIR"');
  commands.push('  rm -f "$USER_SCRIPT_DIR/VS Hook Pro.lua" "$USER_SCRIPT_DIR/VS Hook Basic.lua" "$USER_SCRIPT_DIR/VS Hook.lua" "$USER_SCRIPT_DIR/Hook Lyrics.lua" "$USER_SCRIPT_DIR/Hook lyrics.lua" 2>/dev/null || true');
  if (betaLuaSource) commands.push(`  cp -f ${shellQuote(betaLuaSource)} "$USER_SCRIPT_DIR/VS Hook Beta.lua"`);
  if (estableLuaSource) commands.push(`  cp -f ${shellQuote(estableLuaSource)} "$USER_SCRIPT_DIR/VS Hook Estable.lua"`);
  if (vshookSource) commands.push(`  cp -f ${shellQuote(vshookSource)} "$USER_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`  cp -f ${shellQuote(jsApiSource)} "$USER_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('  chown -R "$USER_NAME":staff "$USER_SCRIPT_DIR" "$USER_PLUGIN_DIR" 2>/dev/null || true');
  commands.push('  chmod 644 "$USER_SCRIPT_DIR/VS Hook Beta.lua" "$USER_SCRIPT_DIR/VS Hook Estable.lua" 2>/dev/null || true');
  commands.push('  chmod 755 "$USER_PLUGIN_DIR"/*.dylib 2>/dev/null || true');
  commands.push('done');

  const script = commands.join('\n');
  execFileSync('osascript', [
    '-e',
    `do shell script ${JSON.stringify(script)} with administrator privileges`
  ], { stdio: 'ignore' });
}

async function installDownloadedUpdate() {
  const downloaded = store.get('downloadedFiles');
  const files = downloaded?.files || {};

  if (process.platform === 'win32') {
    installWindowsPayload(files);
  } else if (process.platform === 'darwin') {
    installMacPayload(files);
  } else {
    throw new Error('Sistema operacional não suportado.');
  }

  await persistActiveLocalLicenseFromStore({ active: true, source: 'install-update' }).catch(() => false);

  if (downloaded?.manifest) {
    const previous = store.get('installedManifest') || {};
    const samePlatform = previous.platform === downloaded.manifest.platform;
    store.set('installedManifest', {
      platform: downloaded.manifest.platform,
      updateId: downloaded.manifest.updateId,
      version: downloaded.manifest.version || downloaded.version || '',
      files: { ...(samePlatform ? (previous.files || {}) : {}), ...(downloaded.manifest.files || {}) },
      installedAt: new Date().toISOString()
    });
  }

  if (downloaded?.version) {
    store.set('currentVersion', downloaded.version);
    store.set('lastNotifiedUpdateId', downloaded.updateId || downloaded.globalUpdateId || downloaded.version);
    store.set('updateAvailable', false);
    store.set('lastUpdateReminderAt', '');
    rebuildTrayMenu();
  }

  return { ok: true, installedVersion: downloaded?.version || store.get('currentVersion') };
}


function normalizeSupportUrl(data) {
  const raw =
    data?.supportUrl ||
    data?.url ||
    data?.link ||
    data?.whatsappUrl ||
    data?.whatsapp ||
    data?.phone ||
    data?.number ||
    '';

  const value = String(raw || '').trim();
  if (!value) return null;
  if (/^(https?:\/\/|mailto:|tel:|whatsapp:)/i.test(value)) return value;

  const compact = value.replace(/\s+/g, '');
  const digits = value.replace(/\D+/g, '');
  if (digits && digits.length >= 8 && digits === compact.replace(/^\+/, '')) {
    return `https://wa.me/${digits}`;
  }

  return `https://${value}`;
}


const HOOK_RENAME_AUDIO_EXTENSIONS = new Set(['.mp3', '.wav', '.aiff']);
const HOOK_RENAME_MAX_PREVIEW_ITEMS = 300;

function sanitizeHookRenameSuffix(raw) {
  const value = String(raw || '')
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, '-')
    .replace(/\s+/g, ' ')
    .trim();

  return value.replace(/[.\s]+$/g, '');
}

function getHookRenameFolderName(folderPath) {
  return sanitizeHookRenameSuffix(path.basename(String(folderPath || '').replace(/[\\/]+$/g, '')) || 'pasta');
}

function getHookRenameSuggestedSuffix(folderPath) {
  const folderName = getHookRenameFolderName(folderPath);
  return folderName ? `_${folderName}` : '';
}

function normalizeHookRenameSuffix(raw, { fallbackFolderPath = '' } = {}) {
  const value = sanitizeHookRenameSuffix(raw || '');
  if (value) return value;
  if (fallbackFolderPath) return getHookRenameSuggestedSuffix(fallbackFolderPath);
  return '';
}

function isHookRenameAudioFile(filePath) {
  return HOOK_RENAME_AUDIO_EXTENSIONS.has(path.extname(filePath || '').toLowerCase());
}

function isPathInside(parentPath, childPath) {
  const parent = path.resolve(parentPath);
  const child = path.resolve(childPath);
  const relative = path.relative(parent, child);
  return relative === '' || (!!relative && !relative.startsWith('..') && !path.isAbsolute(relative));
}

async function listHookRenameDirectFiles(folderPath, { audioOnly = false } = {}) {
  const entries = await fs.promises.readdir(folderPath, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(folderPath, entry.name))
    .filter((filePath) => !audioOnly || isHookRenameAudioFile(filePath));
}

function normalizeHookRenameFolderPaths(payload = {}) {
  const rawList = Array.isArray(payload.folderPaths)
    ? payload.folderPaths
    : (payload.folderPath ? [payload.folderPath] : []);

  const unique = [];
  const seen = new Set();

  for (const rawFolderPath of rawList) {
    const value = String(rawFolderPath || '').trim();
    if (!value) continue;
    const resolved = path.resolve(value);
    const key = process.platform === 'win32' ? resolved.toLowerCase() : resolved;
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(resolved);
  }

  return unique;
}

async function assertHookRenameFolder(folderPath) {
  let stat = null;
  try {
    stat = await fs.promises.stat(folderPath);
  } catch (_) {
    throw new Error(`A pasta selecionada não foi encontrada: ${path.basename(folderPath) || folderPath}`);
  }
  if (!stat.isDirectory()) throw new Error(`O caminho selecionado não é uma pasta: ${folderPath}`);
  return folderPath;
}

async function buildHookRenameOperations(payload = {}) {
  const bulkMode = payload.bulkMode === true;
  const useFolderSuffix = payload.useFolderSuffix === true;
  const folderPaths = normalizeHookRenameFolderPaths(payload);

  if (!folderPaths.length) throw new Error(bulkMode ? 'Escolha as pastas primeiro.' : 'Escolha uma pasta primeiro.');

  if (!bulkMode && folderPaths.length > 1) {
    throw new Error('Para várias pastas, ative o modo Renomear em massa.');
  }

  if (bulkMode && !useFolderSuffix) {
    throw new Error('O modo em massa só funciona usando o nome da pasta como sufixo.');
  }

  const checkedFolders = [];
  for (const folderPath of folderPaths) {
    checkedFolders.push(await assertHookRenameFolder(folderPath));
  }

  const filesByRoot = [];
  for (const folderPath of checkedFolders) {
    const files = await listHookRenameDirectFiles(folderPath, { audioOnly: bulkMode });
    for (const filePath of files) {
      filesByRoot.push({ sourcePath: filePath, rootFolderPath: folderPath });
    }
  }

  const operations = [];
  const skipped = [];

  for (const item of filesByRoot) {
    const sourcePath = item.sourcePath;
    const rootFolderPath = item.rootFolderPath;
    if (!isPathInside(rootFolderPath, sourcePath)) continue;

    const parsed = path.parse(sourcePath);
    const suffix = useFolderSuffix
      ? getHookRenameSuggestedSuffix(parsed.dir)
      : normalizeHookRenameSuffix(payload.suffix || '', { fallbackFolderPath: '' });

    if (!suffix) {
      skipped.push({ sourcePath, reason: 'suffix_empty' });
      continue;
    }

    if (parsed.name.toLowerCase().endsWith(suffix.toLowerCase())) {
      skipped.push({ sourcePath, reason: 'already_has_suffix', suffix });
      continue;
    }

    const nextName = `${parsed.name}${suffix}${parsed.ext}`;
    const targetPath = path.join(parsed.dir, nextName);

    if (path.resolve(targetPath) === path.resolve(sourcePath)) {
      skipped.push({ sourcePath, reason: 'same_name', suffix });
      continue;
    }

    let targetExists = false;
    try {
      await fs.promises.access(targetPath, fs.constants.F_OK);
      targetExists = true;
    } catch (_) {
      targetExists = false;
    }

    if (targetExists) {
      skipped.push({ sourcePath, targetPath, reason: 'target_exists', suffix });
      continue;
    }

    operations.push({
      sourcePath,
      targetPath,
      fromName: path.basename(sourcePath),
      toName: nextName,
      folderName: path.basename(parsed.dir),
      relativeFolder: bulkMode ? path.basename(rootFolderPath) : '.',
      rootFolderPath,
      suffix
    });
  }

  const firstFolder = checkedFolders[0] || '';
  return {
    ok: true,
    folderPath: firstFolder,
    folderPaths: checkedFolders,
    folderName: checkedFolders.length > 1 ? `${checkedFolders.length} pastas selecionadas` : path.basename(firstFolder),
    suggestedSuffix: checkedFolders.length > 1 ? 'Nome de cada pasta' : getHookRenameSuggestedSuffix(firstFolder),
    bulkMode,
    useFolderSuffix,
    audioOnly: bulkMode,
    totalFolders: checkedFolders.length,
    totalScanned: filesByRoot.length,
    totalOperations: operations.length,
    totalSkipped: skipped.length,
    operations,
    skipped
  };
}

function summarizeHookRenameSkipped(skipped = []) {
  return skipped.reduce((acc, item) => {
    const key = item.reason || 'unknown';
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
}

ipcMain.handle('hook-rename-select-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow || undefined, {
    title: 'Escolher pasta para o Hook Rename',
    properties: ['openDirectory']
  });

  if (result.canceled || !result.filePaths?.[0]) {
    return { ok: false, cancelled: true };
  }

  const folderPath = result.filePaths[0];
  return {
    ok: true,
    multiple: false,
    folderPath,
    folderPaths: [folderPath],
    folderName: path.basename(folderPath),
    suggestedSuffix: getHookRenameSuggestedSuffix(folderPath)
  };
});

ipcMain.handle('hook-rename-select-many-folders', async () => {
  const result = await dialog.showOpenDialog(mainWindow || undefined, {
    title: 'Escolher multipastas para o Hook Rename',
    properties: ['openDirectory', 'multiSelections']
  });

  if (result.canceled || !result.filePaths?.length) {
    return { ok: false, cancelled: true };
  }

  const folderPaths = normalizeHookRenameFolderPaths({ folderPaths: result.filePaths });
  return {
    ok: true,
    multiple: true,
    folderPath: folderPaths[0] || '',
    folderPaths,
    folderName: `${folderPaths.length} pasta(s) selecionada(s)`,
    folderNames: folderPaths.map((folderPath) => path.basename(folderPath)),
    suggestedSuffix: 'Nome de cada pasta'
  };
});

ipcMain.handle('hook-rename-preview', async (_event, payload = {}) => {
  const result = await buildHookRenameOperations(payload);
  return {
    ...result,
    operations: result.operations.slice(0, HOOK_RENAME_MAX_PREVIEW_ITEMS),
    skippedSummary: summarizeHookRenameSkipped(result.skipped),
    skipped: result.skipped.slice(0, HOOK_RENAME_MAX_PREVIEW_ITEMS),
    previewLimit: HOOK_RENAME_MAX_PREVIEW_ITEMS
  };
});

ipcMain.handle('hook-rename-run', async (event, payload = {}) => {
  const result = await buildHookRenameOperations(payload);
  const total = result.operations.length;
  let renamed = 0;
  let failed = 0;
  const errors = [];

  event.sender.send('hook-rename-progress', {
    ok: true,
    phase: 'start',
    current: 0,
    total,
    percent: total > 0 ? 0 : 100,
    renamed: 0,
    failed: 0
  });

  for (const operation of result.operations) {
    try {
      await fs.promises.rename(operation.sourcePath, operation.targetPath);
      renamed += 1;
    } catch (error) {
      failed += 1;
      errors.push({
        fromName: operation.fromName,
        toName: operation.toName,
        message: error?.message || 'Erro ao renomear.'
      });
    }

    const current = renamed + failed;
    event.sender.send('hook-rename-progress', {
      ok: true,
      phase: 'running',
      current,
      total,
      percent: total > 0 ? Math.round((current / total) * 100) : 100,
      renamed,
      failed,
      currentFile: operation.fromName
    });
  }

  event.sender.send('hook-rename-progress', {
    ok: true,
    phase: 'done',
    current: total,
    total,
    percent: 100,
    renamed,
    failed
  });

  return {
    ok: failed === 0,
    totalScanned: result.totalScanned,
    totalOperations: total,
    renamed,
    failed,
    totalSkipped: result.totalSkipped,
    skippedSummary: summarizeHookRenameSkipped(result.skipped),
    errors: errors.slice(0, 20)
  };
});

async function openSupport() {
  const data = await fetchJson(SUPPORT_API_URL, { cache: 'no-store' });
  const supportUrl = normalizeSupportUrl(data);

  if (!supportUrl) {
    throw new Error('SUPPORT_UNAVAILABLE');
  }

  const qrSvg = createQrSvg(supportUrl, { margin: 2, scale: 8 });
  return { ok: true, url: supportUrl, qrSvg };
}

ipcMain.handle('get-state', async () => {
  const license = store.get('license') || {};
  if (!license.machineId) {
    store.set('license', { ...license, machineId: await getMachineId() });
  }
  return getAppState();
});

ipcMain.handle('get-bridge-state', () => getBridgeState());
ipcMain.handle('restart-bridge', () => startBridgeServers());
ipcMain.handle('check-updates', async () => {
  const result = await checkForUpdates(true);
  await checkHookCenterUpdates(true);
  return { ...result, ok: true, state: getAppState() };
});
ipcMain.handle('check-hook-center-update', () => checkHookCenterUpdates(true));
ipcMain.handle('install-hook-center-update', () => downloadAndInstallHookCenterUpdate());
ipcMain.handle('download-hook-center-update', () => downloadHookCenterUpdateInstaller());
ipcMain.handle('install-downloaded-hook-center-update', () => installDownloadedHookCenterUpdate());
ipcMain.handle('check-bridge-app-update', () => checkBridgeAppUpdates(true));
ipcMain.handle('install-bridge-app-update', () => downloadAndInstallBridgeAppUpdate());
ipcMain.handle('check-license-status', () => checkLicenseStatus(true));
ipcMain.handle('open-external', (_event, url) => shell.openExternal(url));
ipcMain.handle('open-support', () => openSupport());
ipcMain.handle('get-previous-updates', () => getPreviousUpdates());
ipcMain.handle('download-update', (_event, payload) => downloadLatestUpdate(payload?.update || null));
ipcMain.handle('install-update', () => installDownloadedUpdate());
ipcMain.handle('get-lyrics-settings', (_event, slot) => slot ? getLyricsSettings(slot) : getLyricsAllSettings());
ipcMain.handle('save-lyrics-settings', (_event, payload) => saveLyricsSettings(payload || {}, payload?.slot));
ipcMain.handle('get-technical-notice-settings', () => getTechnicalNoticeSettings());
ipcMain.handle('save-technical-notice-settings', (_event, payload) => saveTechnicalNoticeSettings(payload || {}));
ipcMain.handle('send-recados-notice', (_event, payload) => sendRecadosNotice(payload || {}));
ipcMain.handle('cancel-recados-notice', () => cancelRecadosNotice());
ipcMain.handle('set-recados-notice-pinned', (_event, payload) => setRecadosNoticePinned(payload || {}));
ipcMain.handle('export-lyrics-backup', () => exportLyricsBackup());
ipcMain.handle('import-lyrics-backup', () => importLyricsBackup());
ipcMain.handle('open-lyrics-window', (_event, slot) => createLyricsWindow(slot));
ipcMain.handle('close-lyrics-window', (_event, slot) => {
  const id = Number(slot) === 2 ? 2 : 1;
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) {
    lyricsWindows.delete(id);
    try { win.close(); } catch (_) {}
  }
  return { ok: true, slot: id, lyricsWindows: broadcastLyricsWindowsState() };
});
ipcMain.handle('get-lyrics-state', (_event, slot) => getLyricsState(slot));
ipcMain.handle('close-current-window', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win && !win.isDestroyed()) {
    for (const [slot, lyricsWin] of lyricsWindows.entries()) {
      if (lyricsWin === win) {
        lyricsWindows.delete(slot);
        break;
      }
    }
    try { win.close(); } catch (_) {}
  }
  return { ok: true, lyricsWindows: broadcastLyricsWindowsState() };
});

ipcMain.handle('toggle-current-window-fullscreen', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  return toggleLyricsWindowFullscreen(win);
});

ipcMain.handle('get-current-window-bounds', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win || win.isDestroyed()) return { ok: false };
  return { ok: true, bounds: win.getBounds() };
});

ipcMain.on('move-current-window', (event, payload = {}) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win || win.isDestroyed()) return;
  const x = Math.round(Number(payload.x));
  const y = Math.round(Number(payload.y));
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  try { win.setPosition(x, y, false); } catch (_) {}
});


ipcMain.handle('get-device-name', () => ({ ok: true, deviceName: getStoredDeviceName() }));
ipcMain.handle('set-device-name', (_event, payload) => {
  const deviceName = saveStoredDeviceName(payload?.deviceName || payload?.name || '')
  return { ok: true, deviceName, state: getAppState() }
});
ipcMain.handle('login-license-devices', async (_event, payload) => loginLicenseDevices(payload?.email || ''));
ipcMain.handle('remove-license-device', async (_event, payload) => removeLicenseDevice(payload?.machineId || payload?.deviceId || payload?.removeMachineId || '', payload?.email || ''));
ipcMain.handle('activate-license', async (_event, payload) => {
  const docParts = splitDocument(payload?.cpf || payload?.document || payload?.cnpj);
  const cpf = docParts.cpf;
  const cnpj = docParts.cnpj;
  const document = docParts.document;
  const email = normalizeEmail(payload?.email);
  const machineId = await getMachineId();
  const computerName = getStoredDeviceName();

  if (document && document.length !== 11 && document.length !== 14) {
    throw new Error('Digite um CPF ou CNPJ válido.');
  }
  if (!email || !email.includes('@')) {
    throw new Error('Digite o e-mail usado na compra.');
  }
  if (!computerName) {
    throw new Error('Digite o nome deste dispositivo antes de ativar a licença.');
  }

  const result = await fetchJson(`${BACKEND_URL}/api/license/activate`, {
    method: 'POST',
    body: JSON.stringify({ cpf, cnpj, document, email, machineId, platform: process.platform, computerName: getStoredDeviceName() })
  });

  const licenseKey = result.licenseKey || result.license || generateExpectedLicense(machineId);
  let activationPersistenceWarning = '';
  try {
    saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload: result });
  } catch (_) {
    activationPersistenceWarning = 'Licença ativada. Finalize e abra novamente se necessário.';
  }

  const nextLicense = {
    cpf,
    cnpj,
    document,
    email,
    machineId,
    active: true,
    devicesUsed: result.devicesUsed ?? result.usedDevices ?? 1,
    maxDevices: result.maxDevices ?? 0,
    devices: Array.isArray(result.devices) ? result.devices : [],
    message: result.message || result.warning || activationPersistenceWarning || 'Licença ativada com sucesso.',
    warning: result.warning || '',
    reason: result.reason || 'active',
    lastStatusAt: new Date().toISOString()
  };

  store.set('license', nextLicense);
  publishLicenseOfflineStatus({ ...nextLicense, lastOnlineValidationAt: new Date().toISOString(), offlineWarningStartedAt: '' });
  rebuildTrayMenu();

  if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState());

  return { ok: true, license: nextLicense, result, state: getAppState() };
});

app.whenReady().then(async () => {
  if (!gotSingleInstanceLock) return;

  app.setLoginItemSettings({ openAtLogin: true });
  store.set('autoStart', true);
  Menu.setApplicationMenu(null);
  if (!isValidWindow(mainWindow)) createWindow();
  if (!tray) createTray();
  await ensureBridgeServersRunning().catch((error) => {
    console.error('[Hook Center] Conexão via app não iniciou:', error?.message || error);
  });

  const license = store.get('license') || {};
  if (!license.machineId) {
    store.set('license', { ...license, machineId: await getMachineId() });
  }
  await persistActiveLocalLicenseFromStore({ active: true, source: 'startup-migration' }).catch(() => false);

  await checkForUpdates(false);
  await checkHookCenterUpdates(false);
  await checkLicenseStatus(false);

  bridgeWatchTimer = setInterval(() => {
    ensureBridgeServersRunning().catch((error) => {
      console.error('[Hook Center] Tentativa de religar conexão via app falhou:', error?.message || error);
    });
  }, 30000);

  checkTimer = setInterval(async () => {
    await ensureBridgeServersRunning().catch(() => {});
    await checkForUpdates(false);
    await checkHookCenterUpdates(false);
    await checkLicenseStatus(false);
  }, CHECK_INTERVAL_MS);

  updateReminderTimer = setInterval(() => {
    notifyPendingUpdate(false);
  }, UPDATE_REMINDER_INTERVAL_MS);
});

app.on('activate', () => {
  showMainWindow();
});

app.on('window-all-closed', (event) => {
  event.preventDefault();
});

app.on('before-quit', () => {
  for (const win of lyricsWindows.values()) { try { if (win && !win.isDestroyed()) win.close(); } catch (_) {} }
  stopBridgeServers();
  if (checkTimer) clearInterval(checkTimer);
  if (bridgeWatchTimer) clearInterval(bridgeWatchTimer);
});
