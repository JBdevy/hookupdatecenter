const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, shell, dialog, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const Store = require('electron-store');
const { spawn, execFile, execFileSync } = require('child_process');
const { pathToFileURL } = require('url');
const { createBridgeServer, getLanIp, getAllLanIps, ensureJsonFile } = require('./bridge-server');
const { createQrSvg } = require('./qr-svg');

const store = new Store({
  defaults: {
    currentVersion: app.getVersion(),
    hookCenterLatest: null,
    hookCenterUpdateAvailable: false,
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
const UPDATE_API_URL_BASE = `${BACKEND_URL}/api/latest`;
const HOOK_CENTER_API_URL = `${BACKEND_URL}/api/hookcenter/latest?platform=${getHookCenterPlatformKey()}`;
const BRIDGE_APP_API_URL = `${BACKEND_URL}/api/bridge-app/latest?platform=${getPlatformKey()}`;
const UPDATES_HISTORY_API_URL = `${BACKEND_URL}/api/updates?limit=50&platform=${getPlatformKey()}`;
const SUPPORT_API_URL = `${BACKEND_URL}/api/support`;
const CHECK_INTERVAL_MS = 60 * 60 * 1000;
const UPDATE_REMINDER_INTERVAL_MS = 20 * 60 * 1000;

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
    width: 1040,
    height: 720,
    minWidth: 920,
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

async function getLatestUpdateApiUrl() {
  const params = new URLSearchParams({ platform: getPlatformKey() });
  try {
    const machineId = await getMachineId();
    if (machineId) params.set('machineId', machineId);
  } catch (_) {}
  return `${UPDATE_API_URL_BASE}?${params.toString()}`;
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

async function persistActiveLocalLicenseFromStore(extraPayload = null) {
  const license = store.get('license') || {};
  if (!license.active) return false;
  const machineId = normalizeMachineId(license.machineId || await getMachineId());
  const email = normalizeEmail(license.email || store.get('deviceLoginEmail'));
  if (!machineId || !email) return false;
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
        lua: pickFirst(windows.lua, windows.luaUrl, windows.vsHookLua, windows.vsHookLuaUrl, windows.script, windows.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(windows.hookLyricsLua, windows.hookLyricsLuaUrl, windows.lyricsLua, windows.lyricsLuaUrl, windows.hookLyrics, windows.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDll: pickFirst(windows.vshookDll, windows.vshookDllUrl, windows.reaperVshookDll, windows.reaperVshookDllUrl, windows.vshook, windows.vshookUrl, windows.reaper_vshook, windows.reaper_vshook_url),
        jsApiDll: pickFirst(windows.jsApiDll, windows.jsApiDllUrl, windows.reaperJsApiDll, windows.reaperJsApiDllUrl, windows.jsapi, windows.jsapiUrl, windows.reaper_js_ReaScriptAPI64, windows.reaper_js_ReaScriptAPI64_url)
      },
      macos: {
        lua: pickFirst(macos.lua, macos.luaUrl, macos.vsHookLua, macos.vsHookLuaUrl, macos.script, macos.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(macos.hookLyricsLua, macos.hookLyricsLuaUrl, macos.lyricsLua, macos.lyricsLuaUrl, macos.hookLyrics, macos.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDylib: pickFirst(macos.vshookDylib, macos.vshookDylibUrl, macos.reaperVshookDylib, macos.reaperVshookDylibUrl, macos.vshook, macos.vshookUrl, macos.reaper_vshook, macos.reaper_vshook_url),
        jsApiDylib: pickFirst(macos.jsApiDylib, macos.jsApiDylibUrl, macos.reaperJsApiDylib, macos.reaperJsApiDylibUrl, macos.jsapi, macos.jsapiUrl, macos.universalJsApiDylib, macos.universalJsApiDylibUrl),
        jsApiArmDylib: pickFirst(macArm.jsApiDylib, macArm.jsApiDylibUrl, macArm.reaperJsApiDylib, macArm.reaperJsApiDylibUrl, macArm.jsapi, macArm.jsapiUrl, macos.armJsApiDylib, macos.armJsApiDylibUrl, macos.jsApiArmDylib, macos.jsApiArmDylibUrl, macos.jsApiAppleSiliconDylib, macos.jsApiAppleSiliconDylibUrl, macos.reaperJsApiArmDylib, macos.reaperJsApiArmDylibUrl, macos.reaperJsApiAppleSiliconDylib, macos.reaperJsApiAppleSiliconDylibUrl, macos.reaper_js_ReaScriptAPI64ARM, macos.reaper_js_ReaScriptAPI64ARM_url),
        jsApiIntelDylib: pickFirst(macIntel.jsApiDylib, macIntel.jsApiDylibUrl, macIntel.reaperJsApiDylib, macIntel.reaperJsApiDylibUrl, macIntel.jsapi, macIntel.jsapiUrl, macos.intelJsApiDylib, macos.intelJsApiDylibUrl, macos.jsApiIntelDylib, macos.jsApiIntelDylibUrl, macos.reaperJsApiIntelDylib, macos.reaperJsApiIntelDylibUrl, macos.reaper_js_ReaScriptAPI64, macos.reaper_js_ReaScriptAPI64_url)
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

async function getPreviousUpdates() {
  const endpoints = [
    UPDATES_HISTORY_API_URL,
    `${BACKEND_URL}/api/updates/history?limit=50&platform=${getPlatformKey()}`,
    `${BACKEND_URL}/api/updates/history?limit=50`,
    `${BACKEND_URL}/api/public/updates?limit=50&platform=${getPlatformKey()}`
  ];

  let lastError = null;

  for (const url of endpoints) {
    try {
      const raw = await fetchJson(url, { cache: 'no-store' });
      return { ok: true, updates: normalizeUpdatesList(raw) };
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

async function checkForUpdates(manual = false) {
  const now = new Date().toISOString();
  store.set('lastCheck', now);

  try {
    const raw = await fetchJson(await getLatestUpdateApiUrl(), { cache: 'no-store' });
    const update = normalizeUpdate(raw);

    const shouldNotify = hasPendingInstallableUpdate(update);

    store.set('latestUpdate', update);
    store.set('updateAvailable', shouldNotify);
    rebuildTrayMenu();

    if (isValidWindow(mainWindow)) {
      mainWindow.webContents.send('update-status', getAppState());
    }

    if (shouldNotify && !manual) {
      notifyPendingUpdate(true);
    }

    if (manual) showMainWindow();

    return { ok: true, hasUpdate: shouldNotify, update, state: getAppState() };
  } catch (error) {
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-error', error.message);
    return { ok: false, error: error.message, state: getAppState() };
  }
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
  try {
    const raw = await fetchJson(HOOK_CENTER_API_URL, { cache: 'no-store' });
    const update = normalizeHookCenterUpdate(raw);
    const currentVersion = app.getVersion();
    const hasUpdate = !!(update?.version && update.downloadUrl && compareVersions(update.version, currentVersion) > 0);
    store.set('hookCenterLatest', update);
    store.set('hookCenterUpdateAvailable', hasUpdate);
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
    if (hasUpdate && !manual) notifyHookCenterUpdate(update);
    if (manual) showMainWindow();
    return { ok: true, hasUpdate, update, state: getAppState() };
  } catch (error) {
    return { ok: false, error: error.message, state: getAppState() };
  }
}

async function downloadAndInstallHookCenterUpdate() {
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
  try {
    const raw = await fetchJson(BRIDGE_APP_API_URL, { cache: 'no-store' });
    const update = normalizeBridgeAppUpdate(raw);
    const hasUpdate = bridgeAppNeedsUpdate(update);
    store.set('bridgeAppLatest', update);
    store.set('bridgeAppUpdateAvailable', hasUpdate);
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
    if (manual) showMainWindow();
    return { ok: true, hasUpdate, update, state: getAppState() };
  } catch (error) {
    return { ok: false, error: error.message, state: getAppState() };
  }
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

async function extractZip(zipPath, destinationDir) {
  fs.rmSync(destinationDir, { recursive: true, force: true });
  fs.mkdirSync(destinationDir, { recursive: true });

  if (process.platform === 'win32') {
    await runProcess('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-Command',
      `Expand-Archive -LiteralPath ${JSON.stringify(zipPath)} -DestinationPath ${JSON.stringify(destinationDir)} -Force`
    ]);
    return;
  }

  await runProcess('/usr/bin/unzip', ['-oq', zipPath, '-d', destinationDir]);
}

function findBridgeAppRoot(extractDir) {
  if (isBridgeWebAppDirValid(extractDir)) return extractDir;
  const entries = fs.readdirSync(extractDir, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  if (entries.length === 1) {
    const onlyDir = path.join(extractDir, entries[0].name);
    if (isBridgeWebAppDirValid(onlyDir)) return onlyDir;
  }
  for (const entry of entries) {
    const candidate = path.join(extractDir, entry.name);
    if (isBridgeWebAppDirValid(candidate)) return candidate;
  }
  return '';
}

function installExtractedBridgeApp(appRoot, update) {
  if (!isBridgeWebAppDirValid(appRoot)) throw new Error('ZIP do App QR inválido: index.html não encontrado.');

  const externalDir = getExternalBridgeWebAppDir();
  const parentDir = path.dirname(externalDir);
  const installDir = path.join(parentDir, `qr-app-installing-${Date.now()}`);
  const backupDir = path.join(parentDir, `qr-app-backup-${Date.now()}`);

  fs.mkdirSync(parentDir, { recursive: true });
  fs.rmSync(installDir, { recursive: true, force: true });
  copyDirectoryRecursive(appRoot, installDir);
  fs.writeFileSync(path.join(installDir, 'version.json'), JSON.stringify({
    product: 'bridge-app',
    version: update.version || '',
    updateId: update.updateId || update.version || '',
    title: update.title || '',
    notes: update.notes || '',
    sourceUrl: update.downloadUrl || '',
    installedAt: new Date().toISOString()
  }, null, 2), 'utf8');

  fs.rmSync(backupDir, { recursive: true, force: true });
  if (fs.existsSync(externalDir)) fs.renameSync(externalDir, backupDir);
  fs.renameSync(installDir, externalDir);
  fs.rmSync(backupDir, { recursive: true, force: true });

  return externalDir;
}

async function downloadAndInstallBridgeAppUpdate(updateOverride = null) {
  const checked = updateOverride ? { update: updateOverride, hasUpdate: bridgeAppNeedsUpdate(updateOverride) } : await checkBridgeAppUpdates(false);
  const update = checked.update || store.get('bridgeAppLatest');
  if (!update?.downloadUrl) return { ok: false, skipped: true, reason: 'bridge-app-unavailable' };
  if (!bridgeAppNeedsUpdate(update)) return { ok: true, skipped: true, reason: 'already-current' };

  const downloadDir = path.join(app.getPath('userData'), 'downloads', 'bridge-app', update.updateId || update.version || 'latest');
  const zipPath = path.join(downloadDir, 'bridge-app.zip');
  await downloadFile(update.downloadUrl, zipPath, (progress) => {
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', progress);
  });

  if (update.sha256) {
    const actualHash = sha256File(zipPath);
    if (actualHash !== update.sha256) throw new Error('Falha na validação do App QR: SHA256 diferente do backend.');
  }

  const extractDir = path.join(downloadDir, 'extract');
  await extractZip(zipPath, extractDir);
  const appRoot = findBridgeAppRoot(extractDir);
  if (!appRoot) throw new Error('ZIP do App QR inválido: index.html não encontrado.');
  const installedPath = installExtractedBridgeApp(appRoot, update);

  store.set('bridgeAppInstalled', {
    version: update.version || '',
    updateId: update.updateId || update.version || '',
    title: update.title || '',
    notes: update.notes || '',
    downloadUrl: update.downloadUrl || '',
    sha256: update.sha256 || '',
    path: installedPath,
    installedAt: new Date().toISOString()
  });
  store.set('bridgeAppUpdateAvailable', false);

  await startBridgeServers();
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-status', getAppState());
  return { ok: true, installedPath, update };
}

async function checkAndInstallBridgeAppUpdate() {
  const result = await checkBridgeAppUpdates(false);
  if (!result.ok || !result.hasUpdate || !result.update) return result;
  try {
    return await downloadAndInstallBridgeAppUpdate(result.update);
  } catch (error) {
    console.error('[Hook Center] Falha ao atualizar App QR:', error?.message || error);
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('update-error', `App QR: ${error.message}`);
    return { ok: false, error: error.message };
  }
}

async function checkLicenseStatus(manual = false) {
  const license = store.get('license') || {};
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
      lastStatusAt: new Date().toISOString()
    };

    store.set('license', nextLicense);

    if (active) {
      const licenseKey = result.licenseKey || result.license || generateExpectedLicense(machineId);
      try {
    try {
    saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload: result });
  } catch (_) {
    if (!protectedLicenseShardsExist()) {
      throw new Error('Não foi possível concluir a ativação. Tente novamente.');
    }
  }
  } catch (_) {
    throw new Error('Não foi possível concluir a ativação. Tente novamente.');
  }
    } else {
      removeLocalLicense();
      notifyLicense(result.message || 'Este computador foi desvinculado da licença do VS Hook.');
    }

    rebuildTrayMenu();
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('license-status', getAppState());

    return { ok: true, active, result, state: getAppState() };
  } catch (error) {
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
  // Pasta usada no desenvolvimento com npm start.
  // Assim você edita Hook center/qr-app/ e o celular já lê essa versão,
  // sem precisar mexer em src/bridge-web-app nem reinstalar o Hook Center.
  return path.join(__dirname, '..', 'qr-app');
}

function getBundledBridgeWebAppDir() {
  // Em build empacotado, qr-app/ também entra no pacote e vira a base
  // copiada para ProgramData/Users Shared quando a pasta externa ainda não existe.
  const editableOrBundledDir = getEditableBridgeWebAppDir();
  if (isBridgeWebAppDirValid(editableOrBundledDir)) return editableOrBundledDir;
  return path.join(__dirname, 'bridge-web-app');
}

function getExternalBridgeWebAppDir() {
  if (process.platform === 'win32') {
    const programData = process.env.PROGRAMDATA || process.env.ProgramData || 'C:\\ProgramData';
    return path.join(programData, 'HookDeveloper', 'HookCenter', 'qr-app');
  }
  if (process.platform === 'darwin') {
    return '/Users/Shared/HookDeveloper/HookCenter/qr-app';
  }
  return path.join(os.homedir(), '.hookdeveloper', 'hookcenter', 'qr-app');
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

function bridgeExternalAppNeedsBundledSync(externalDir, bundledDir) {
  if (!isBridgeWebAppDirValid(externalDir)) return true;
  const bundledVersion = readBridgeWebAppVersion(bundledDir);
  const externalVersion = readBridgeWebAppVersion(externalDir);
  if (!bundledVersion) return false;
  return bundledVersion !== externalVersion;
}

function copyDirectoryRecursive(sourceDir, targetDir) {
  const stat = fs.statSync(sourceDir);
  if (!stat.isDirectory()) throw new Error('Origem do app QR não é uma pasta.');
  fs.mkdirSync(targetDir, { recursive: true });
  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    if (entry.isDirectory()) {
      copyDirectoryRecursive(sourcePath, targetPath);
    } else if (entry.isFile()) {
      fs.mkdirSync(path.dirname(targetPath), { recursive: true });
      fs.copyFileSync(sourcePath, targetPath);
    }
  }
}

function ensureExternalBridgeWebApp() {
  const externalDir = getExternalBridgeWebAppDir();
  const bundledDir = getBundledBridgeWebAppDir();

  if (isBridgeWebAppDirValid(bundledDir) && bridgeExternalAppNeedsBundledSync(externalDir, bundledDir)) {
    try {
      fs.rmSync(externalDir, { recursive: true, force: true });
      fs.mkdirSync(path.dirname(externalDir), { recursive: true });
      copyDirectoryRecursive(bundledDir, externalDir);
      const versionFile = path.join(externalDir, 'version.json');
      if (!fs.existsSync(versionFile)) {
        fs.writeFileSync(versionFile, JSON.stringify({ version: app.getVersion(), bundled: true, installedAt: new Date().toISOString() }, null, 2), 'utf8');
      }
      store.set('bridgeAppInstalled', {
        version: readBridgeWebAppVersion(externalDir) || app.getVersion(),
        updateId: readBridgeWebAppVersion(externalDir) || app.getVersion(),
        title: 'App QR embutido no Hook Center',
        notes: 'Sincronizado automaticamente a partir do build do Hook Center.',
        path: externalDir,
        installedAt: new Date().toISOString()
      });
      return externalDir;
    } catch (error) {
      console.warn('[Hook Center] Não foi possível preparar App QR externo:', error?.message || error);
      return bundledDir;
    }
  }

  if (isBridgeWebAppDirValid(externalDir)) return externalDir;
  if (isBridgeWebAppDirValid(bundledDir)) return bundledDir;

  return getFallbackBridgeWebAppDir();
}

function getBridgeWebAppDir() {
  // Durante npm start, serve diretamente Hook center/qr-app/.
  // Isso permite testar alteração de tela/layout pelo QR sem copiar para ProgramData.
  const editableDir = getEditableBridgeWebAppDir();
  if (!app.isPackaged && isBridgeWebAppDirValid(editableDir)) {
    return editableDir;
  }

  // No app instalado, usa a pasta atualizável externa.
  return ensureExternalBridgeWebApp();
}

function getBridgeAppCacheVersion() {
  const installed = store.get('bridgeAppInstalled') || {};
  return encodeURIComponent(installed.updateId || installed.version || app.getVersion() || Date.now());
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
    textColor: '#ffea00',
    textBoxColor: '#ffea00',
    clockColor: '#00ff55',
    borderColor: '#00ff55',
    rgbBorderEnabled: false,
    rgbWindowBorderEnabled: false,
    rgbClockBorderEnabled: false,
    rgbTextBoxBorderEnabled: false,
    fontFamily: 'Arial',
    textScale: 1,
    borderEnabled: true,
    windowBorderEnabled: true,
    clockBorderEnabled: true,
    textBoxEnabled: true,
    clockEnabled: true,
    songNameEnabled: false,
    songNameColor: '#00ff55',
    songNameFontFamily: 'Arial',
    songNameScale: 1,
    songNamePosition: 'top',
    clockPosition: 'top',
    clockScale: 1,
    mediaScale: 1,
    clearMode: false
  };
}

function getTechnicalNoticeDefaults() {
  return {
    textColor: '#ffea00',
    flashColor: '#ff0000',
    fontFamily: 'Arial',
    window1Enabled: true,
    window2Enabled: true,
    emojiEnabled: true,
    emoji: '⚠️'
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
  store.set('technicalNoticeSettings', next);
  for (const win of lyricsWindows.values()) {
    if (win && !win.isDestroyed()) win.webContents.send('technical-notice-settings-updated', next);
  }
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('technical-notice-settings-updated', next);
  return next;
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
  if (typeof settings.textColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textColor)) next.textColor = settings.textColor;
  if (typeof settings.clockColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.clockColor)) next.clockColor = settings.clockColor;
  if (typeof settings.textBoxColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textBoxColor)) next.textBoxColor = settings.textBoxColor;
  if (typeof settings.borderColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.borderColor)) next.borderColor = settings.borderColor;
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
  if (allowedFonts.includes(settings.songNameFontFamily)) next.songNameFontFamily = settings.songNameFontFamily;
  if (settings.songNameScale !== undefined) next.songNameScale = clampLyricsScale(settings.songNameScale, next.songNameScale || 1, 3);
  if (settings.songNamePosition !== undefined) next.songNamePosition = normalizeLyricsScreenPosition(settings.songNamePosition, next.songNamePosition || 'top');
  if (settings.clockPosition === 'top' || settings.clockPosition === 'bottom') next.clockPosition = settings.clockPosition;
  if (settings.clockScale !== undefined) next.clockScale = clampLyricsScale(settings.clockScale, next.clockScale || 1, 2.5);
  if (settings.mediaScale !== undefined) next.mediaScale = clampLyricsScale(settings.mediaScale, next.mediaScale || 1);
  if (typeof settings.clearMode === 'boolean') next.clearMode = settings.clearMode;
  all[id] = next;
  store.set('lyrics', all);
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) win.webContents.send('lyrics-settings-updated', { slot: id, settings: next });
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('lyrics-settings-updated', getLyricsAllSettings());
  return next;
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

function getLyricsState(slot = 1) {
  const id = normalizeLyricsSlot(slot);
  const data = readJsonFileSafe(getLyricsStatePath(id), {});
  const bridgeState = readJsonFileSafe(getBridgeStatePath(), {});
  const timerSource = (typeof data.timerRunning === 'boolean' || Number(data.timerStartedAt || 0) || Number(data.timerAccumulatedSec || 0)) ? data : bridgeState;
  const mediaType = normalizeLyricsMediaType(data.telepromptType || data.mediaType || data.type);
  const mediaPath = String(data.mediaPath || data.path || '');
  const mediaUrl = getFileUrlSafe(data.mediaUrl || mediaPath);
  const textValue = (mediaType === 'image' || mediaType === 'video') ? '' : String(data.text || data.lyrics || data.lyricsText || '');
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
    itemGuid: media.itemGuid,
    itemStart: media.itemStart,
    itemEnd: media.itemEnd,
    itemLength: media.itemLength,
    timerRunning: Boolean(timerSource.timerRunning),
    timerStartedAt: Number(timerSource.timerStartedAt || timerSource.timerStartedAtMs || 0),
    timerAccumulatedSec: Number(timerSource.timerAccumulatedSec || 0),
    timerMode: String(timerSource.timerMode || timerSource.timerType || 'progressive'),
    timerType: String(timerSource.timerMode || timerSource.timerType || 'progressive'),
    timerTargetSec: Number(timerSource.timerTargetSec || timerSource.timerCountdownStartSec || 0),
    timerCountdownStartSec: Number(timerSource.timerTargetSec || timerSource.timerCountdownStartSec || 0),
    timerDisplaySec: Number(timerSource.timerDisplaySec || 0),
    playing: Boolean(data.playing || bridgeState.playing || bridgeState.isPlaying),
    updatedAt: data.updatedAt || bridgeState.updatedAt || null,
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
    minWidth: 640,
    minHeight: 360,
    backgroundColor: '#00000000',
    title: 'Teleprompt',
    icon: getAppIconPath(),
    frame: false,
    thickFrame: false,
    transparent: true,
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
  return {
    currentVersion: app.getVersion(),
    lastCheck: store.get('lastCheck'),
    updateAvailable: store.get('updateAvailable'),
    latestUpdate: store.get('latestUpdate'),
    hookCenterLatest: store.get('hookCenterLatest'),
    hookCenterUpdateAvailable: store.get('hookCenterUpdateAvailable'),
    bridgeAppLatest: store.get('bridgeAppLatest'),
    bridgeAppUpdateAvailable: store.get('bridgeAppUpdateAvailable'),
    bridgeAppInstalled: store.get('bridgeAppInstalled'),
    bridgeAppPath: getBridgeWebAppDir(),
    lastNotifiedUpdateId: store.get('lastNotifiedUpdateId'),
    downloadedFiles: store.get('downloadedFiles'),
    installedManifest: store.get('installedManifest'),
    installedVsHookVersion: getInstalledVsHookVersion(),
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
  if (process.platform === 'win32') {
    return [
      { key: 'lua', url: ensureAbsoluteUrl(files.lua), filename: 'VS Hook.lua' },
      { key: 'vshookDll', url: ensureAbsoluteUrl(files.vshookDll), filename: 'reaper_vshook.dll' },
      { key: 'jsApiDll', url: ensureAbsoluteUrl(files.jsApiDll), filename: 'reaper_js_ReaScriptAPI64.dll' }
    ].filter((entry) => !!entry.url);
  }

  if (process.platform === 'darwin') {
    const isAppleSilicon = process.arch === 'arm64';
    const jsApiUrl = ensureAbsoluteUrl(
      isAppleSilicon
        ? (files.jsApiArmDylib || files.jsApiDylib)
        : (files.jsApiIntelDylib || files.jsApiDylib)
    );

    return [
      { key: 'lua', url: ensureAbsoluteUrl(files.lua), filename: 'VS Hook.lua' },
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

function getWindowsLegacyVsHookDir() {
  const programFiles = process.env.ProgramFiles || 'C:\\Program Files';
  return path.join(programFiles, 'VS Hook APP');
}

function copyFileWithWindowsAdminFallback(source, destination) {
  if (!source || !fs.existsSync(source)) return;

  try {
    copyFileEnsured(source, destination);
    return;
  } catch (error) {
    if (process.platform !== 'win32') throw error;
  }

  const script = [
    `$source = ${JSON.stringify(source)}`,
    `$destination = ${JSON.stringify(destination)}`,
    '$directory = Split-Path -Parent $destination',
    'New-Item -ItemType Directory -Force -Path $directory | Out-Null',
    'Copy-Item -LiteralPath $source -Destination $destination -Force'
  ].join('; ');

  const encoded = Buffer.from(script, 'utf16le').toString('base64');
  const command = `Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}' -Verb RunAs -Wait`;

  execFileSync('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-Command', command
  ], { stdio: 'ignore', windowsHide: true });
}

function getWindowsReaperUserPluginsDir() {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'REAPER', 'UserPlugins');
}

function installWindowsPayload(files) {
  const luaFileName = 'VS Hook.lua';

  copyFileEnsured(files.lua, path.join(getWindowsPublicVsHookDir(), luaFileName));
  copyFileWithWindowsAdminFallback(files.lua, path.join(getWindowsLegacyVsHookDir(), luaFileName));

  try { fs.rmSync(path.join(getWindowsPublicVsHookDir(), 'Hook Lyrics.lua'), { force: true }); } catch (_) {}
  try { fs.rmSync(path.join(getWindowsLegacyVsHookDir(), 'Hook Lyrics.lua'), { force: true }); } catch (_) {}

  copyFileEnsured(files.vshookDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_vshook.dll'));
  copyFileEnsured(files.jsApiDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_js_ReaScriptAPI64.dll'));
}

function installMacPayload(files) {
  const commands = [];
  const luaSource = files.lua;
  const vshookSource = files.vshookDylib;
  const jsApiSource = files.jsApiDylib;

  commands.push('set -e');
  commands.push('GLOBAL_REAPER="/Library/Application Support/REAPER"');
  commands.push('GLOBAL_SCRIPT_DIR="$GLOBAL_REAPER/Scripts/VS Hook APP"');
  commands.push('GLOBAL_PLUGIN_DIR="$GLOBAL_REAPER/UserPlugins"');
  commands.push('mkdir -p "$GLOBAL_SCRIPT_DIR" "$GLOBAL_PLUGIN_DIR"');

  if (luaSource) commands.push(`cp -f ${shellQuote(luaSource)} "$GLOBAL_SCRIPT_DIR/VS Hook.lua"`);
  commands.push('rm -f "$GLOBAL_SCRIPT_DIR/Hook Lyrics.lua" 2>/dev/null || true');
  if (vshookSource) commands.push(`cp -f ${shellQuote(vshookSource)} "$GLOBAL_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`cp -f ${shellQuote(jsApiSource)} "$GLOBAL_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('chmod 644 "$GLOBAL_SCRIPT_DIR/VS Hook.lua" 2>/dev/null || true');
  commands.push('chmod 755 "$GLOBAL_PLUGIN_DIR"/*.dylib 2>/dev/null || true');

  commands.push('for USER_HOME in /Users/*; do');
  commands.push('  [ -d "$USER_HOME" ] || continue');
  commands.push('  USER_NAME=$(basename "$USER_HOME")');
  commands.push('  [ "$USER_NAME" = "Shared" ] && continue');
  commands.push('  USER_REAPER="$USER_HOME/Library/Application Support/REAPER"');
  commands.push('  USER_SCRIPT_DIR="$USER_REAPER/Scripts/VS Hook APP"');
  commands.push('  USER_PLUGIN_DIR="$USER_REAPER/UserPlugins"');
  commands.push('  mkdir -p "$USER_SCRIPT_DIR" "$USER_PLUGIN_DIR"');
  if (luaSource) commands.push(`  cp -f ${shellQuote(luaSource)} "$USER_SCRIPT_DIR/VS Hook.lua"`);
  commands.push('  rm -f "$USER_SCRIPT_DIR/Hook Lyrics.lua" 2>/dev/null || true');
  if (vshookSource) commands.push(`  cp -f ${shellQuote(vshookSource)} "$USER_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`  cp -f ${shellQuote(jsApiSource)} "$USER_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('  chown -R "$USER_NAME":staff "$USER_SCRIPT_DIR" "$USER_PLUGIN_DIR" 2>/dev/null || true');
  commands.push('  chmod 644 "$USER_SCRIPT_DIR/VS Hook.lua" 2>/dev/null || true');
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
  return { ...result, state: getAppState() };
});
ipcMain.handle('check-hook-center-update', () => checkHookCenterUpdates(true));
ipcMain.handle('install-hook-center-update', () => downloadAndInstallHookCenterUpdate());
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
  ensureExternalBridgeWebApp();
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
  await checkAndInstallBridgeAppUpdate();
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
    await checkAndInstallBridgeAppUpdate();
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
