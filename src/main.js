const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, shell, dialog, nativeImage, screen, powerMonitor } = require('electron');
const path = require('path');
const fs = require('fs');
// O Electron intercepta caminhos terminados em .asar no módulo fs comum.
// O companion contém o próprio resources/app.asar e precisa ser tratado como
// arquivo físico durante a instalação.
const physicalFs = (() => {
  try {
    return require('original-fs');
  } catch (_) {
    return fs;
  }
})();
const os = require('os');
const crypto = require('crypto');
const Store = require('electron-store');
const { spawn, execFile, execFileSync } = require('child_process');
const { pathToFileURL } = require('url');
const http = require('http');
const {
  createBridgeServer,
  getLanIp,
  getAllLanIps,
  ensureJsonFile,
  getNativeBridgeStateSnapshot
} = require('./bridge-server');
const { createTimecodeLanRelay } = require('./timecode-lan');
const { createQrSvg } = require('./qr-svg');
const appPackage = require('../package.json');

const store = new Store({
  defaults: {
    currentVersion: app.getVersion(),
    hookCenterLatest: null,
    hookCenterUpdateAvailable: false,
    downloadedHookCenterUpdate: null,
    bridgeAppLatest: null,
    bridgeAppUpdateAvailable: false,
    bridgeAppInstalled: null,
    pendingPostCenterUpdateInstall: null,
    bundledReaperAssetsIdentity: '',
    lastCheck: null,
    updateAvailable: false,
    latestUpdate: null,
    lastNotifiedUpdateId: null,
    downloadedFiles: null,
    installedManifest: null,
    installedPackages: {},
    activeInstalledPackageIdentity: '',
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
    hookMidi: {
      ports: []
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
let appIsQuitting = false;
let quitCleanupStarted = false;
let updateInstallerQuitWatchdog = null;
let checkTimer = null;
let updateReminderTimer = null;
let bridgeServers = [];
let bridgeInfos = [];
let bridgeConfig = null;
let bridgeLastError = '';
let bridgeWatchTimer = null;
let bridgeRestartPromise = null;
let timecodeLanRelay = null;
let parallelTimecodeLanRelay = null;
const timecodeRelayPeerAddresses = { main: '', parallel: '' };
const lyricsWindows = new Map();
const legacyWindowDragSessions = new Map();

const BACKEND_URL = (process.env.BACKEND_URL || 'https://hookupdate7.up.railway.app').replace(/\/+$/, '');
const UPDATE_API_URL_BASE = `${BACKEND_URL}/api/v3/latest`;
const TEST_UPDATE_API_URL_BASE = `${BACKEND_URL}/api/latest`;
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
const SIGNED_LICENSE_FILE = process.platform === 'win32'
  ? 'vshook_license_v3.token'
  : '.vshook_license_v3.token';

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
      nodeIntegration: false
    }
  });

  Menu.setApplicationMenu(null);
  mainWindow.setMenuBarVisibility(false);
  mainWindow.loadFile(path.join(__dirname, 'index.html'));

  const win = mainWindow;

  win.on('close', (event) => {
    if (!appIsQuitting) {
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
    { label: 'Sair', click: () => { appIsQuitting = true; app.quit(); } }
  ]);
  tray.setContextMenu(menu);
}

function showMainWindow() {
  if (appIsQuitting) return;
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
    return '/Users/Shared/vslive_machine_id.dat';
  }
  return path.join(os.homedir(), '.vslive_machine_id');
}

function getLegacySharedMachineIdPaths() {
  if (process.platform === 'darwin') {
    return ['/Users/Shared/.vslive_machine_id'];
  }
  return [];
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

function applyLicenseFileChanges({ writes = [], removes = [] } = {}) {
  const pendingWrites = [];
  const pendingRemoves = [];

  for (const entry of writes) {
    const filePath = String(entry?.filePath || '');
    if (!filePath) continue;
    try {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
      fs.writeFileSync(filePath, String(entry?.content ?? ''), 'utf8');
    } catch (error) {
      if (process.platform !== 'darwin') throw error;
      pendingWrites.push({ filePath, content: String(entry?.content ?? '') });
    }
  }

  for (const value of removes) {
    const filePath = String(value || '');
    if (!filePath) continue;
    try {
      fs.rmSync(filePath, { force: true });
      if (fs.existsSync(filePath)) pendingRemoves.push(filePath);
    } catch (_) {
      if (process.platform === 'darwin') pendingRemoves.push(filePath);
    }
  }

  if (process.platform !== 'darwin' || (!pendingWrites.length && !pendingRemoves.length)) return;

  const commands = ['set -e'];
  const directories = [...new Set(pendingWrites.map((entry) => path.dirname(entry.filePath)))];
  for (const dir of directories) {
    commands.push(`/bin/mkdir -p ${shellQuote(dir)}`);
  }
  for (const entry of pendingWrites) {
    const encoded = Buffer.from(entry.content, 'utf8').toString('base64');
    commands.push(`/usr/bin/printf %s ${shellQuote(encoded)} | /usr/bin/base64 -D > ${shellQuote(entry.filePath)}`);
    commands.push(`/bin/chmod 644 ${shellQuote(entry.filePath)}`);
  }
  for (const filePath of [...new Set(pendingRemoves)]) {
    commands.push(`/bin/rm -f ${shellQuote(filePath)}`);
  }

  try {
    execFileSync('osascript', [
      '-e',
      `do shell script ${JSON.stringify(commands.join('\n'))} with administrator privileges`
    ], { stdio: 'ignore' });
  } catch (_) {
    throw new Error('Não foi possível concluir a operação. Tente novamente.');
  }
}

async function getWindowsAnchor() {
  const probes = [
    ['reg.exe', ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid', '/reg:64']],
    ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "(Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' -Name MachineGuid).MachineGuid"]],
    ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', '(Get-CimInstance Win32_ComputerSystemProduct).UUID']],
    ['wmic.exe', ['csproduct', 'get', 'uuid']]
  ];

  for (const [cmd, args] of probes) {
    const raw = await runCapture(cmd, args);
    const guid = raw.match(/\b([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32})\b/);
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
    const guid = raw.match(/\b([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b/);
    if (guid?.[1]) return normalizeMachineId(guid[1]);
  }
  return '';
}

async function getMachineId() {
  const machinePath = getSharedMachineIdPath();
  const cachedPaths = [machinePath, ...getLegacySharedMachineIdPaths()];
  for (const cachedPath of cachedPaths) {
    try {
      const cached = normalizeMachineId(fs.readFileSync(cachedPath, 'utf8'));
      if (!/^[0-9A-F]+$/.test(cached)) continue;
      if (cachedPath !== machinePath) {
        try {
          fs.mkdirSync(path.dirname(machinePath), { recursive: true });
          fs.writeFileSync(machinePath, cached, 'utf8');
        } catch (_) {}
      }
      return cached;
    } catch (_) {}
  }

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

let cachedDeviceFingerprint = '';
async function getDeviceFingerprint() {
  if (cachedDeviceFingerprint) return cachedDeviceFingerprint;
  let anchor = '';
  if (process.platform === 'win32') anchor = await getWindowsAnchor();
  if (process.platform === 'darwin') anchor = await getMacAnchor();
  if (!anchor) anchor = normalizeMachineId(os.hostname() || 'UNKNOWNHOST');
  cachedDeviceFingerprint = crypto.createHash('sha256')
    .update(`VSHOOK_DEVICE_V1|${process.platform}|${normalizeMachineId(anchor)}`)
    .digest('hex')
    .toUpperCase();
  return cachedDeviceFingerprint;
}

function getSharedSignedLicensePath() {
  return path.join(path.dirname(getSharedMachineIdPath()), SIGNED_LICENSE_FILE);
}

function saveSignedLicenseToken(token, { required = false } = {}) {
  const clean = String(token || '').trim();
  if (!clean) {
    if (required) {
      throw new Error('O backend ainda não forneceu a nova licença assinada. Configure a chave privada de assinatura antes de distribuir esta versão.');
    }
    return false;
  }
  if (clean.length > 16384 || clean.split('.').length !== 3) {
    throw new Error('A licença assinada recebida é inválida.');
  }
  const target = getSharedSignedLicensePath();
  const temp = `${target}.tmp-${process.pid}`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(temp, `${clean}\n`, { encoding: 'utf8', mode: 0o600 });
  if (process.platform === 'win32' && fs.existsSync(target)) {
    try {
      execFileSync('attrib.exe', ['-h', target], {
        windowsHide: true,
        stdio: 'ignore'
      });
    } catch (_) {}
  }
  try { fs.rmSync(target, { force: true }); } catch (_) {}
  fs.renameSync(temp, target);
  hideLicenseShardOnWindows(target);
  return true;
}

function removeSignedLicenseToken() {
  const target = getSharedSignedLicensePath();
  if (process.platform === 'win32' && fs.existsSync(target)) {
    try {
      execFileSync('attrib.exe', ['-h', target], {
        windowsHide: true,
        stdio: 'ignore'
      });
    } catch (_) {}
  }
  try { fs.rmSync(target, { force: true }); } catch (_) {}
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
  const deviceFingerprint = await getDeviceFingerprint()
  const result = await fetchJson(`${BACKEND_URL}/api/license/login`, {
    method: 'POST',
    body: JSON.stringify({ email: cleanEmail, machineId, deviceFingerprint, platform: process.platform, computerName: getStoredDeviceName() })
  })
  if (result.active) saveSignedLicenseToken(result.licenseToken)
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
  const deviceFingerprint = await getDeviceFingerprint()
  const result = await fetchJson(`${BACKEND_URL}/api/license/remove-device`, {
    method: 'POST',
    body: JSON.stringify({ email: cleanEmail, machineId, removeMachineId, deviceFingerprint, platform: process.platform, computerName: getStoredDeviceName() })
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
  } else if (nextLicense.active) {
    saveSignedLicenseToken(result.licenseToken);
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
  const shardWrites = LICENSE_SHARD_FILES.map((fileName, index) => ({
    filePath: path.join(licenseDir, fileName),
    content: `${parts[index]}\n`
  }));
  applyLicenseFileChanges({
    writes: shardWrites,
    // Remove os formatos antigos junto com os três fragmentos. No macOS, toda
    // a operação usa uma única autorização administrativa do osascript.
    removes: [getSharedLicensePath(), ...getLegacyLicensePaths()]
  });

  for (const entry of shardWrites) {
    hideLicenseShardOnWindows(entry.filePath);
  }

  return licenseDir;
}

function removeLocalLicense() {
  const licenseDir = getSharedLicenseDir();
  applyLicenseFileChanges({
    removes: [
      getSharedLicensePath(),
      ...LICENSE_SHARD_FILES.map((fileName) => path.join(licenseDir, fileName)),
      ...getLegacyLicensePaths()
    ]
  });
  removeSignedLicenseToken();

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
    const error = new Error(message);
    error.status = response.status;
    error.retryAfter = Number(data?.retryAfter) || 0;
    error.data = data;
    throw error;
  }

  return data;
}

async function getChatAuthPayload() {
  const license = store.get('license') || {};
  if (license.active !== true) throw new Error('Ative sua licença para acessar o Chat Hook.');
  const document = normalizeDocument(license.document || license.cpf || license.cnpj || '');
  const parts = splitDocument(document);
  const email = normalizeEmail(license.email || store.get('deviceLoginEmail') || '');
  const machineId = normalizeMachineId(license.machineId || await getMachineId());
  if ((!parts.cpf && !parts.cnpj && !email) || !machineId) {
    throw new Error('Ative sua licença para acessar o Chat Hook.');
  }
  return {
    document,
    cpf: parts.cpf,
    cnpj: parts.cnpj,
    email,
    machineId,
    deviceFingerprint: await getDeviceFingerprint(),
    platform: process.platform,
    computerName: getStoredDeviceName()
  };
}

async function getChatState(afterId = 0) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/state`, {
    method: 'POST',
    cache: 'no-store',
    body: JSON.stringify({ ...auth, afterId: Math.max(0, Number(afterId) || 0) })
  });
}

async function sendChatMessage(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/messages`, {
    method: 'POST',
    body: JSON.stringify({
      ...auth,
      text: String(payload.text || '').slice(0, 1000),
      image: payload.image && typeof payload.image === 'object' ? payload.image : null,
      video: payload.video && typeof payload.video === 'object' ? payload.video : null
    })
  });
}

async function setChatPinnedMessage(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/pin`, {
    method: 'POST',
    body: JSON.stringify({
      ...auth,
      messageId: Math.max(0, Math.floor(Number(payload.messageId) || 0))
    })
  });
}

async function deleteChatMessage(payload = {}) {
  const auth = await getChatAuthPayload();
  const messageId = Math.floor(Number(payload.messageId));
  if (!Number.isInteger(messageId) || messageId < 1) {
    throw new Error('Mensagem inválida.');
  }
  return fetchJson(`${BACKEND_URL}/api/chat/delete`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, messageId })
  });
}

async function createChatMobileSession() {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/mobile/session`, {
    method: 'POST',
    cache: 'no-store',
    body: JSON.stringify(auth)
  });
}

async function updateChatProfile(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/profile`, {
    method: 'POST',
    body: JSON.stringify({
      ...auth,
      name: String(payload.name || '').slice(0, 80)
    })
  });
}

async function uploadChatAvatar(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/avatar`, {
    method: 'POST',
    body: JSON.stringify({
      ...auth,
      image: payload.image && typeof payload.image === 'object' ? payload.image : null
    })
  });
}

async function getHookTutorials() {
  return fetchJson(`${BACKEND_URL}/api/tutorials`, { cache: 'no-store' });
}

async function updateChatAdminSettings(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/admin/settings`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, ...payload })
  });
}

async function clearChatAsAdmin(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/admin/clear`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, adminPassword: String(payload.adminPassword || '') })
  });
}

async function unlockChatAdmin(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/admin/unlock`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, adminPassword: String(payload.adminPassword || '') })
  });
}

async function saveChatReleaseNotes(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/admin/release-notes`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, adminPassword: String(payload.adminPassword || ''), releaseNotes: String(payload.releaseNotes || '') })
  });
}

async function publishUpdateFromHookCenter(payload = {}) {
  const auth = await getChatAuthPayload();
  return fetchJson(`${BACKEND_URL}/api/chat/admin/publish-update`, {
    method: 'POST',
    body: JSON.stringify({ ...auth, adminPassword: String(payload.adminPassword || ''), update: payload.update || {} })
  });
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
  if (source.published === false) return null;

  const files = source.files || {};
  const windows = source.windows || files.windows || files.win32 || {};
  const macos = source.macos || source.mac || files.macos || files.mac || files.darwin || {};
  const macIntel = macos.intel || macos.x64 || macos.macIntel || files.macIntel || files.macosIntel || {};
  const macArm = macos.arm || macos.arm64 || macos.appleSilicon || macos.macArm || files.macArm || files.macosArm || files.appleSilicon || files.macosAppleSilicon || {};
  const platforms = source.platforms || files.platforms || files._platforms || {};
  const currentPlatformKey = getPlatformKey();
  const platformMeta = platforms?.[currentPlatformKey] || {};

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
    // `version` pode continuar igual entre duas builds (principalmente nas
    // atualizacoes direcionadas). Preserve uma revisao de publicacao separada
    // para que o cache identifique o artefato, e nao apenas o numero exibido.
    artifactRevision: platformMeta.artifactRevision || platformMeta.revision || platformMeta.buildId ||
      source.artifactRevision || source.revision || source.buildId || source.build ||
      platformMeta.changedAt || source.updatedAt || source.publishedAt || source.createdAt || '',
    product: source.product || 'vs-hook',
    source: updateSource,
    testClient: testClientFlag,
    isTestClient: testClientFlag,
    targetMachineId: platformMeta.machineId || source.machineId || source.targetMachineId || '',
    platformKey: platformMeta.platformKey || source.platformKey || '',
    version: platformMeta.version || source.version || '',
    title: platformMeta.title || source.title || 'Atualização do VS Hook disponível',
    description: platformMeta.description || source.description || '',
    releaseNotes: platformMeta.releaseNotes || source.releaseNotes || platformMeta.description || source.description || '',
    youtubeUrl: platformMeta.youtubeUrl || source.youtubeUrl || source.videoUrl || source.video || '',
    changelog: Array.isArray(source.changelog)
      ? source.changelog
      : String(source.description || '').split('\n').map((line) => line.trim()).filter(Boolean),
    publishedAt: platformMeta.changedAt || source.publishedAt || source.createdAt || null,
    current: source.current === true,
    platforms,
    changed: source.changed || files.changed || {},
    files: {
      windows: {
        betaLua: pickFirst(windows.betaLua, windows.betaLuaUrl, windows.vsHookBetaLua, windows.vsHookBetaLuaUrl, windows.beta, windows.betaUrl, windows.proLua, windows.proLuaUrl, windows.vsHookProLua, windows.vsHookProLuaUrl, windows.pro, windows.proUrl, source.betaLua, source.betaLuaUrl, source.vsHookBetaLua, source.vsHookBetaLuaUrl, source.proLua, source.proLuaUrl, source.vsHookProLua, source.vsHookProLuaUrl),
        estableLua: pickFirst(windows.estableLua, windows.estableLuaUrl, windows.stableLua, windows.stableLuaUrl, windows.vsHookEstableLua, windows.vsHookEstableLuaUrl, windows.estable, windows.stable, windows.estableUrl, windows.stableUrl, windows.basicLua, windows.basicLuaUrl, windows.vsHookBasicLua, windows.vsHookBasicLuaUrl, windows.basic, windows.basicUrl, source.estableLua, source.estableLuaUrl, source.stableLua, source.stableLuaUrl, source.vsHookEstableLua, source.vsHookEstableLuaUrl, source.basicLua, source.basicLuaUrl, source.vsHookBasicLua, source.vsHookBasicLuaUrl),
        lua: pickFirst(windows.lua, windows.luaUrl, windows.vsHookLua, windows.vsHookLuaUrl, windows.script, windows.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(windows.hookLyricsLua, windows.hookLyricsLuaUrl, windows.lyricsLua, windows.lyricsLuaUrl, windows.hookLyrics, windows.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDll: pickFirst(windows.vshookDll, windows.vshookExtDll, windows.vshookDllUrl, windows.reaperVshookDll, windows.reaperVshookDllUrl, windows.vshook, windows.vshookUrl, windows.reaper_vshook, windows.reaper_vshook_url),
        installer: pickFirst(
          windows.installer,
          windows.exe,
          windows.url,
          source.windowsHookCenterUrl,
          source.windowsInstallerUrl,
          source.windowsUrl,
          currentPlatformKey === 'windows' ? source.installerUrl : '',
          currentPlatformKey === 'windows' ? source.downloadUrl : ''
        ),
        jsApiDll: pickFirst(windows.jsApiDll, windows.jsApiDllUrl, windows.reaperJsApiDll, windows.reaperJsApiDllUrl, windows.jsapi, windows.jsapiUrl, windows.reaper_js_ReaScriptAPI64, windows.reaper_js_ReaScriptAPI64_url),
        logoPng: pickFirst(windows.logoPng, windows.logoPngUrl, windows.loadingLogo, windows.loadingLogoUrl, windows.logohookPng, windows.logohookPngUrl, windows.logo, windows.logoUrl, source.logoPng, source.logoPngUrl)
      },
      macos: {
        betaLua: pickFirst(macos.betaLua, macos.betaLuaUrl, macos.vsHookBetaLua, macos.vsHookBetaLuaUrl, macos.beta, macos.betaUrl, macos.proLua, macos.proLuaUrl, macos.vsHookProLua, macos.vsHookProLuaUrl, macos.pro, macos.proUrl, source.betaLua, source.betaLuaUrl, source.vsHookBetaLua, source.vsHookBetaLuaUrl, source.proLua, source.proLuaUrl, source.vsHookProLua, source.vsHookProLuaUrl),
        estableLua: pickFirst(macos.estableLua, macos.estableLuaUrl, macos.stableLua, macos.stableLuaUrl, macos.vsHookEstableLua, macos.vsHookEstableLuaUrl, macos.estable, macos.stable, macos.estableUrl, macos.stableUrl, macos.basicLua, macos.basicLuaUrl, macos.vsHookBasicLua, macos.vsHookBasicLuaUrl, macos.basic, macos.basicUrl, source.estableLua, source.estableLuaUrl, source.stableLua, source.stableLuaUrl, source.vsHookEstableLua, source.vsHookEstableLuaUrl, source.basicLua, source.basicLuaUrl, source.vsHookBasicLua, source.vsHookBasicLuaUrl),
        lua: pickFirst(macos.lua, macos.luaUrl, macos.vsHookLua, macos.vsHookLuaUrl, macos.script, macos.scriptUrl, source.lua, source.luaUrl),
        hookLyricsLua: pickFirst(macos.hookLyricsLua, macos.hookLyricsLuaUrl, macos.lyricsLua, macos.lyricsLuaUrl, macos.hookLyrics, macos.hookLyricsUrl, source.hookLyricsLua, source.hookLyricsLuaUrl, source.lyricsLua, source.lyricsLuaUrl),
        vshookDylib: pickFirst(macos.vshookDylib, macos.vshookExtDylib, macos.vshookDylibUrl, macos.reaperVshookDylib, macos.reaperVshookDylibUrl, macos.vshook, macos.vshookUrl, macos.reaper_vshook, macos.reaper_vshook_url),
        installer: pickFirst(
          macos.installer,
          macos.dmg,
          macos.url,
          source.macosHookCenterUrl,
          source.macosInstallerUrl,
          source.macosUrl,
          currentPlatformKey === 'macos' ? source.installerUrl : '',
          currentPlatformKey === 'macos' ? source.downloadUrl : ''
        ),
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
  // Registros antigos podem declarar changed=true mesmo trazendo a extensão
  // anterior (reaper_vshook). Eles não são compatíveis com a Hook Center 1.0,
  // que instala exclusivamente reaper_VSHookExt.
  const installable = hasInstallableFiles(update);
  if (!installable) return false;
  if (Object.prototype.hasOwnProperty.call(changed, platformKey)) {
    return Boolean(changed[platformKey]) && installable;
  }
  return installable;
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
    if (currentUpdate && isSameCurrentUpdate(update, currentUpdate)) update.current = true;

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

  const cachedUpdates = listCachedUpdateManifests().map(cachedManifestToUpdate).filter(Boolean);
  let lastError = null;
  const currentUpdate = cachedUpdates.length > 0
    ? normalizeUpdate(store.get('latestUpdate'))
    : await getCurrentPublishedUpdateForHistory();
  const endpointsToTry = cachedUpdates.length > 0 ? endpoints.slice(0, 1) : endpoints;

  for (const url of endpointsToTry) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const raw = await fetchJson(url, { cache: 'no-store', signal: controller.signal });
      const remoteUpdates = normalizeUpdatesList(raw);
      if (currentUpdate && !remoteUpdates.some((update) => isSameCurrentUpdate(update, currentUpdate))) {
        remoteUpdates.unshift({ ...currentUpdate, current: true });
      }
      const updates = decorateUpdatesWithCache(filterPreviousUpdates([...remoteUpdates, ...cachedUpdates], currentUpdate));
      return { ok: true, updates, offline: false };
    } catch (error) {
      lastError = error;
    } finally {
      clearTimeout(timeout);
    }
  }

  return {
    ok: cachedUpdates.length > 0,
    error: lastError?.message || 'Não foi possível carregar as atualizações anteriores.',
    offline: true,
    updates: decorateUpdatesWithCache(filterPreviousUpdates(cachedUpdates, currentUpdate))
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
  // O link específico da variante tem prioridade sobre o campo genérico.
  // Assim, mesmo que uma resposta antiga traga downloadUrl do macOS normal,
  // a build Legacy continua usando macosLegacyUrl.
  const downloadUrl = ensureAbsoluteUrl(platformUrls[platformKey] || raw.downloadUrl || '');
  return {
    product: 'hook-center',
    platformKey,
    updateId: raw.updateId || raw.version || null,
    artifactRevision: raw.artifactRevision || raw.revision || raw.buildId || raw.build ||
      raw.updatedAt || raw.publishedAt || '',
    version: raw.version || '',
    title: raw.title || 'Nova versão do Hook Center disponível',
    notes: raw.notes || raw.description || '',
    releaseNotes: raw.releaseNotes || raw.notes || raw.description || '',
    tutorialUrl: ensureAbsoluteUrl(raw.tutorialUrl || raw.learnUrl || raw.videoUrl || ''),
    downloadUrl,
    installerSha256: String(
      raw.installerSha256 || raw.sha256 ||
      (platformKey === 'windows' ? raw.windowsSha256 : raw.macosSha256) || ''
    ).trim().toLowerCase(),
    windowsUrl: ensureAbsoluteUrl(raw.windowsUrl),
    macosUrl: ensureAbsoluteUrl(raw.macosUrl),
    macosLegacyUrl: ensureAbsoluteUrl(raw.macosLegacyUrl || raw.legacyMacosUrl || raw.macos10Url),
    publishedAt: raw.publishedAt || null
  };
}

function getHookCenterArtifactIdentity(update) {
  const normalized = normalizeHookCenterUpdate(update) || update || {};
  const descriptor = {
    schema: 2,
    product: 'hook-center',
    platform: String(normalized.platformKey || getHookCenterPlatformKey()),
    updateId: String(normalized.updateId || ''),
    version: String(normalized.version || ''),
    revision: String(normalized.artifactRevision || normalized.publishedAt || ''),
    url: normalizeArtifactUrl(normalized.downloadUrl || ''),
    expectedSha256: String(normalized.installerSha256 || '').trim().toLowerCase()
  };
  return crypto.createHash('sha256')
    .update(JSON.stringify(descriptor), 'utf8')
    .digest('hex');
}

async function checkHookCenterUpdates(manual = false) {
  const raw = await fetchJsonForUpdateSoft(getHookCenterApiUrl(), { cache: 'no-store' });
  const fetchedUpdate = normalizeHookCenterUpdate(raw);
  const platformKey = getHookCenterPlatformKey();
  const cachedCandidate = store.get('hookCenterLatest') || null;
  // Versões anteriores podiam salvar no cache da Legacy o instalador normal.
  // Não reutiliza cache sem variante conhecida ou de outra plataforma.
  const cachedUpdate = cachedCandidate?.platformKey === platformKey ? cachedCandidate : null;
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
  if (!update.version) {
    throw new Error('A atualização da Hook Center não informou uma versão válida.');
  }
  // Um download novo invalida imediatamente o ponteiro anterior. Se a rede
  // falhar, o botão Instalar não pode cair silenciosamente no DMG/EXE velho.
  store.set('downloadedHookCenterUpdate', null);

  const ext = process.platform === 'darwin' ? '.dmg' : '.exe';
  const artifactIdentity = getHookCenterArtifactIdentity(update);
  const artifactSuffix = artifactIdentity.slice(0, 12);
  const baseName = process.platform === 'darwin'
    ? (getHookCenterPlatformKey() === 'macos-legacy' ? `Hook-Center-Legacy-${update.version}-${artifactSuffix}-macOS10${ext}` : `Hook-Center-${update.version}-${artifactSuffix}-macOS${ext}`)
    : `Hook-Center-${update.version}-${artifactSuffix}-Windows${ext}`;
  const dest = path.join(app.getPath('downloads'), baseName);
  const partial = `${dest}.part-${process.pid}-${Date.now()}`;
  await fs.promises.rm(partial, { force: true }).catch(() => {});
  try {
    await downloadFile(update.downloadUrl, partial, (progress) => {
      if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', progress);
    }, { cacheBust: true, timeoutMs: 120000 });
    validateUpdateInstallerFile(partial);
    const integrity = getFileIntegrity(partial);
    const expectedHash = String(update.installerSha256 || '').trim().toLowerCase();
    if (expectedHash && integrity.sha256 !== expectedHash) {
      throw new Error('O instalador baixado não corresponde ao hash publicado.');
    }
    await fs.promises.rm(dest, { force: true }).catch(() => {});
    await fs.promises.rename(partial, dest);
    fileIntegrityCache.delete(path.resolve(dest));
  } catch (error) {
    await fs.promises.rm(partial, { force: true }).catch(() => {});
    throw error;
  }

  const integrity = getFileIntegrity(dest);

  const downloaded = {
    version: update.version,
    updateId: update.updateId || update.version,
    path: dest,
    platform: process.platform,
    platformKey: getHookCenterPlatformKey(),
    sourceUrl: update.downloadUrl,
    artifactIdentity,
    sha256: integrity.sha256,
    size: integrity.size,
    downloadedAt: new Date().toISOString()
  };
  store.set('downloadedHookCenterUpdate', downloaded);
  return { ok: true, downloaded };
}

function launchWindowsUpdateInstaller(installerPath) {
  const requestedInstaller = String(installerPath || '').trim();
  const resolvedInstaller = requestedInstaller ? path.resolve(requestedInstaller) : '';
  if (
    !resolvedInstaller ||
    !fs.existsSync(resolvedInstaller) ||
    !fs.statSync(resolvedInstaller).isFile()
  ) {
    throw new Error('O instalador da atualização da Hook Center não foi encontrado.');
  }

  // O NSIS do electron-builder entende --updated: ele aguarda/encerra a
  // instância anterior antes de substituir os arquivos. O processo precisa
  // nascer diretamente; um PowerShell intermediário pode morrer junto com o
  // Electron antes de conseguir abrir o instalador.
  const launcher = spawn(resolvedInstaller, ['--updated'], {
    cwd: path.dirname(resolvedInstaller),
    detached: true,
    stdio: 'ignore',
    windowsHide: false
  });
  if (!launcher.pid) {
    throw new Error('Não foi possível abrir o instalador da Hook Center.');
  }
  launcher.unref();
}

function quitAfterWindowsInstallerIsQueued() {
  appIsQuitting = true;
  setTimeout(() => app.quit(), 80);
}

function quitAfterMacDmgIsOpened() {
  // O Electron usa instância única. Se a central antiga continuar aberta,
  // clicar na nova cópia instalada apenas reativa o processo antigo e dá a
  // impressão de que o DMG não trouxe as mudanças. shell.openPath() só retorna
  // depois que o LaunchServices aceitou abrir o DMG, portanto não precisamos
  // manter o processo antigo vivo depois desse ponto.
  appIsQuitting = true;
  if (isValidWindow(mainWindow)) mainWindow.hide();
  prepareForAppQuit();
  // Fecha também o ícone da barra e todas as janelas auxiliares já no próximo
  // ciclo. A resposta do IPC atual ainda consegue ser concluída, mas não fica
  // nenhuma janela antiga visível enquanto o usuário instala o DMG novo.
  setImmediate(() => {
    try {
      for (const win of BrowserWindow.getAllWindows()) {
        if (win && !win.isDestroyed()) win.destroy();
      }
    } catch (_) {}
    try {
      if (tray) tray.destroy();
    } catch (_) {}
    tray = null;
    app.quit();
  });

  // Em algumas versões antigas do macOS/Electron, app.quit() pode ficar
  // aguardando o loop nativo mesmo depois de todas as janelas terem fechado.
  // O watchdog encerra somente essa instância antiga; o DMG já foi entregue ao
  // LaunchServices e o estado pendente da instalação já foi salvo no Store.
  if (updateInstallerQuitWatchdog) {
    clearTimeout(updateInstallerQuitWatchdog);
  }
  updateInstallerQuitWatchdog = setTimeout(() => {
    try {
      app.exit(0);
    } catch (_) {
      process.exit(0);
    }
  }, 750);
}

async function installDownloadedHookCenterUpdate() {
  const downloaded = store.get('downloadedHookCenterUpdate') || {};
  const dest = String(downloaded.path || '');
  if (!dest || !fs.existsSync(dest)) {
    throw new Error('O instalador da atualização do Hook Center não foi encontrado. Baixe novamente.');
  }
  if (downloaded.platform && downloaded.platform !== process.platform) {
    throw new Error('O instalador baixado pertence a outro sistema operacional. Baixe novamente.');
  }
  validateUpdateInstallerFile(dest);
  const integrity = getFileIntegrity(dest);
  const expectedHash = String(downloaded.sha256 || '').trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(expectedHash) || integrity.sha256 !== expectedHash) {
    throw new Error('O instalador local mudou ou não possui hash válido. Baixe novamente.');
  }

  if (process.platform === 'win32') {
    launchWindowsUpdateInstaller(dest);
    quitAfterWindowsInstallerIsQueued();
    return { ok: true, action: 'installer-started' };
  }

  const openError = await shell.openPath(dest);
  if (openError) throw new Error(openError);
  // O DMG já foi entregue ao LaunchServices. Esconda/encerre a instância
  // antiga imediatamente; não abra Finder nem aguarde outra interação.
  quitAfterMacDmgIsOpened();
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

function psSingleQuoted(value) {
  return `'${String(value || '').replace(/'/g, "''")}'`;
}

async function listWindowsDirectCableAdapters() {
  const script = [
    "$ErrorActionPreference='Stop'",
    "$items = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.HardwareInterface -eq $true -and $_.Name -notmatch '(?i)wi-?fi|wlan|wireless|bluetooth' } | ForEach-Object {",
    "  $ip = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress",
    "  [pscustomobject]@{ id=$_.Name; name=$_.Name; description=$_.InterfaceDescription; device=$_.Name; status=$_.Status.ToString(); linkSpeed=$_.LinkSpeed; ipv4=([string]$ip) }",
    "}",
    "@($items) | ConvertTo-Json -Compress"
  ].join('; ');
  const output = await runProcess('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-Command', script
  ], { timeout: 12000 });
  let parsed = [];
  try { parsed = JSON.parse(output || '[]'); } catch (_) {}
  return (Array.isArray(parsed) ? parsed : [parsed]).filter((item) => item?.id).map((item) => ({
    id: String(item.id),
    name: String(item.name || item.id),
    description: String(item.description || ''),
    device: String(item.device || item.id),
    service: String(item.name || item.id),
    connected: /up/i.test(String(item.status || '')),
    status: String(item.status || ''),
    linkSpeed: String(item.linkSpeed || ''),
    ipv4: String(item.ipv4 || '')
  }));
}

async function listMacDirectCableAdapters() {
  const output = await runProcess('/usr/sbin/networksetup', ['-listnetworkserviceorder'], { timeout: 12000 });
  const lines = String(output || '').split(/\r?\n/);
  const adapters = [];
  let service = '';
  for (const rawLine of lines) {
    const serviceMatch = rawLine.match(/^\(\d+\)\s+(.+)$/);
    if (serviceMatch) {
      service = serviceMatch[1].replace(/^\*/, '').trim();
      continue;
    }
    const deviceMatch = rawLine.match(/Hardware Port:\s*([^,]+),\s*Device:\s*([^\)]+)/i);
    if (!deviceMatch || !service) continue;
    const hardwarePort = deviceMatch[1].trim();
    const device = deviceMatch[2].trim();
    if (/wi-?fi|airport|bluetooth/i.test(`${service} ${hardwarePort}`)) continue;
    let ifconfig = '';
    try { ifconfig = await runProcess('/sbin/ifconfig', [device], { timeout: 4000 }); } catch (_) {}
    const ipMatch = ifconfig.match(/\binet\s+(\d+\.\d+\.\d+\.\d+)/);
    adapters.push({
      id: device,
      name: service,
      description: hardwarePort,
      device,
      service,
      connected: /status:\s*active/i.test(ifconfig),
      status: /status:\s*active/i.test(ifconfig) ? 'Up' : 'Down',
      linkSpeed: '',
      ipv4: ipMatch ? ipMatch[1] : ''
    });
    service = '';
  }
  return adapters;
}

async function getDirectCableState() {
  if (process.platform !== 'win32' && process.platform !== 'darwin') {
    return { ok: false, supported: false, platform: process.platform, adapters: [], error: 'Disponível apenas no Windows e macOS.' };
  }
  try {
    const adapters = process.platform === 'win32'
      ? await listWindowsDirectCableAdapters()
      : await listMacDirectCableAdapters();
    return {
      ok: true,
      supported: true,
      platform: process.platform,
      adapters,
      configuredAdapterId: String(store.get('directCable.adapterId') || ''),
      configuredIp: String(store.get('directCable.ip') || '')
    };
  } catch (error) {
    return { ok: false, supported: true, platform: process.platform, adapters: [], error: error?.message || 'Não foi possível detectar os adaptadores de rede.' };
  }
}

async function runWindowsElevatedPowerShell(script) {
  const encoded = Buffer.from(String(script || ''), 'utf16le').toString('base64');
  const launcher = `$p=Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','${encoded}'); exit $p.ExitCode`;
  return runProcess('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-Command', launcher
  ], { timeout: 120000 });
}

async function configureDirectCable(payload = {}) {
  const adapterId = String(payload.adapterId || '').trim();
  if (!adapterId) throw new Error('Escolha o adaptador USB/Ethernet que está ligado ao cabo.');
  const current = await getDirectCableState();
  const adapter = current.adapters.find((item) => item.id === adapterId);
  if (!adapter) throw new Error('O adaptador selecionado não está mais disponível. Reconecte-o e tente novamente.');
  // Cada computador recebe um endereço estável derivado do próprio ID. Não há
  // papel mestre/escravo na rede e nenhum usuário precisa escolher PC 1/PC 2.
  const machineId = await getMachineId();
  const hostHash = crypto.createHash('sha256').update(`direct-cable|${machineId}`).digest();
  const host = 10 + (hostHash.readUInt32BE(0) % 240);
  const ip = `192.168.77.${host}`;
  if (process.platform === 'win32') {
    const alias = psSingleQuoted(adapter.name);
    const script = [
      "$ErrorActionPreference='Stop'",
      `$alias=${alias}`,
      "Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop",
      "Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue",
      `New-NetIPAddress -InterfaceAlias $alias -IPAddress '${ip}' -PrefixLength 24 -ErrorAction Stop | Out-Null`
    ].join('; ');
    await runWindowsElevatedPowerShell(script);
  } else if (process.platform === 'darwin') {
    const script = `/sbin/ifconfig ${JSON.stringify(adapter.device)} inet ${ip} netmask 255.255.255.0 up`;
    await runProcess('/usr/bin/osascript', [
      '-e', `do shell script ${JSON.stringify(script)} with administrator privileges`
    ], { timeout: 120000 });
  } else {
    throw new Error('Conexão redundante disponível apenas no Windows e macOS.');
  }
  store.set('directCable', { adapterId, ip, configuredAt: new Date().toISOString() });
  try { await startBridgeServers(); } catch (_) {}
  return { ok: true, ip, state: await getDirectCableState() };
}

async function restoreDirectCableDhcp(payload = {}) {
  const adapterId = String(payload.adapterId || store.get('directCable.adapterId') || '').trim();
  if (!adapterId) throw new Error('Escolha o adaptador que será restaurado para DHCP.');
  const current = await getDirectCableState();
  const adapter = current.adapters.find((item) => item.id === adapterId);
  if (!adapter) throw new Error('O adaptador selecionado não está disponível.');
  if (process.platform === 'win32') {
    const alias = psSingleQuoted(adapter.name);
    await runWindowsElevatedPowerShell([
      "$ErrorActionPreference='Stop'",
      `$alias=${alias}`,
      "Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop",
      "Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue",
      "ipconfig.exe /renew $alias | Out-Null"
    ].join('; '));
  } else if (process.platform === 'darwin') {
    const command = `/usr/sbin/networksetup -setdhcp ${JSON.stringify(adapter.service)}`;
    await runProcess('/usr/bin/osascript', [
      '-e', `do shell script ${JSON.stringify(command)} with administrator privileges`
    ], { timeout: 120000 });
  } else {
    throw new Error('Restauração automática disponível apenas no Windows e macOS.');
  }
  store.delete('directCable');
  try { await startBridgeServers(); } catch (_) {}
  return { ok: true, state: await getDirectCableState() };
}

const HOOK_MIDI_DOWNLOAD_URL = 'https://aka.ms/midi';
const HOOK_MIDI_LOOPMIDI_URL = 'https://www.tobias-erichsen.de/software/loopmidi.html';
const HOOK_MIDI_INSTALLER_NAME = 'Windows-MIDI-Services-Runtime-and-Tools-x64.exe';
const HOOK_MIDI_INSTALLER_SIZE = 219603123;
const HOOK_MIDI_INSTALLER_SHA256 = '5d241b52669a69795b7503f53eb082f83a1860e5ebc50849427b79f15c1a2546';
let hookMidiOperationInProgress = false;

function hookMidiWindowsBuild() {
  if (process.platform !== 'win32') return 0;
  const parts = String(os.release() || '').split('.');
  return Number.parseInt(parts[2] || '0', 10) || 0;
}

function hookMidiIsWindows11() {
  return process.platform === 'win32' && hookMidiWindowsBuild() >= 22000;
}

function hookMidiCleanProcessMessage(value) {
  return String(value || '')
    .replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, '')
    .replace(/\r/g, '')
    .trim();
}

function hookMidiStoredPorts() {
  const ports = store.get('hookMidi.ports');
  if (!Array.isArray(ports)) return [];
  return ports.filter((port) => port && /^[0-9a-f-]{36}$/i.test(String(port.associationId || ''))).map((port) => ({
    associationId: String(port.associationId),
    rootName: String(port.rootName || 'Hook MIDI'),
    endpointA: String(port.endpointA || `${port.rootName || 'Hook MIDI'} (A)`),
    endpointB: String(port.endpointB || `${port.rootName || 'Hook MIDI'} (B)`),
    uniqueIdentifier: String(port.uniqueIdentifier || ''),
    createdAt: String(port.createdAt || ''),
    servicePid: Number(port.servicePid || 0)
  }));
}

function hookMidiSavePorts(ports) {
  store.set('hookMidi.ports', Array.isArray(ports) ? ports.slice(0, 16) : []);
}

function hookMidiFindConsole() {
  if (process.platform !== 'win32') return '';
  const candidates = [];
  const add = (candidate) => {
    const resolved = String(candidate || '').trim().replace(/^"|"$/g, '');
    if (resolved && !candidates.some((item) => item.toLowerCase() === resolved.toLowerCase())) candidates.push(resolved);
  };
  try {
    const output = execFileSync('reg.exe', [
      'query',
      'HKLM\\Software\\Microsoft\\Windows MIDI Services\\Desktop App SDK Runtime',
      '/v', 'MidiConsole'
    ], { windowsHide: true, encoding: 'utf8', timeout: 3000 });
    const match = String(output || '').match(/MidiConsole\s+REG_\w+\s+(.+?midi\.exe)\s*$/im);
    if (match) add(match[1]);
  } catch (_) {}
  for (const root of [process.env.ProgramW6432, process.env.ProgramFiles]) {
    if (!root) continue;
    add(path.join(root, 'Windows MIDI Services', 'Tools', 'Console', 'midi.exe'));
    add(path.join(root, 'Windows MIDI Services', 'Tools', 'midi.exe'));
  }
  try {
    const output = execFileSync('where.exe', ['midi.exe'], {
      windowsHide: true,
      encoding: 'utf8',
      timeout: 3000
    });
    String(output || '').split(/\r?\n/).forEach(add);
  } catch (_) {}
  return candidates.find((candidate) => {
    try { return fs.statSync(candidate).isFile(); } catch (_) { return false; }
  }) || '';
}

function hookMidiBundledInstallerPath() {
  return app.isPackaged
    ? path.join(process.resourcesPath, 'windows-midi-services', HOOK_MIDI_INSTALLER_NAME)
    : path.join(__dirname, '..', 'vendor', 'windows-midi-services', HOOK_MIDI_INSTALLER_NAME);
}

function hookMidiSha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = physicalFs.createReadStream(filePath);
    input.on('error', reject);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex').toLowerCase()));
  });
}

async function installHookMidiComponents() {
  if (!hookMidiIsWindows11()) throw new Error('Os componentes do Hook MIDI são exclusivos do Windows 11.');
  if (hookMidiFindConsole()) return { ok: true, alreadyInstalled: true };
  const installerPath = hookMidiBundledInstallerPath();
  let stats = null;
  try { stats = physicalFs.statSync(installerPath); } catch (_) {}
  if (!stats?.isFile()) {
    await shell.openExternal(HOOK_MIDI_DOWNLOAD_URL);
    return { ok: true, external: true };
  }
  if (stats.size !== HOOK_MIDI_INSTALLER_SIZE ||
      await hookMidiSha256File(installerPath) !== HOOK_MIDI_INSTALLER_SHA256) {
    throw new Error('O instalador interno do Windows MIDI Services está incompleto ou foi alterado. Reinstale a Hook Center.');
  }
  await new Promise((resolve, reject) => {
    const child = spawn(installerPath, [], {
      detached: true,
      windowsHide: false,
      stdio: 'ignore'
    });
    child.once('error', reject);
    child.once('spawn', () => {
      child.unref();
      resolve();
    });
  });
  return { ok: true, installerStarted: true };
}

async function hookMidiServiceState() {
  if (process.platform !== 'win32') return { running: false, pid: 0 };
  try {
    const output = await runProcess('sc.exe', ['queryex', 'MidiSrv'], { timeout: 5000 });
    const pidMatch = output.match(/\bPID\s*:\s*(\d+)/i);
    return {
      running: /\bRUNNING\b/i.test(output),
      pid: Number.parseInt(pidMatch?.[1] || '0', 10) || 0
    };
  } catch (_) {
    return { running: false, pid: 0 };
  }
}

async function getHookMidiState() {
  const build = hookMidiWindowsBuild();
  const windows11 = hookMidiIsWindows11();
  const windows10 = process.platform === 'win32' && build > 0 && build < 22000;
  const consolePath = windows11 ? hookMidiFindConsole() : '';
  const service = windows11 ? await hookMidiServiceState() : { running: false, pid: 0 };
  const bootedAt = Date.now() - Math.max(0, Number(os.uptime() || 0) * 1000) - 60000;
  const stored = hookMidiStoredPorts();
  const ports = stored.filter((port) => {
    const createdAt = Date.parse(port.createdAt || '') || 0;
    if (createdAt && createdAt < bootedAt) return false;
    if (port.servicePid && service.pid && port.servicePid !== service.pid) return false;
    return true;
  });
  if (ports.length !== stored.length) hookMidiSavePorts(ports);
  return {
    ok: true,
    platform: process.platform,
    osRelease: os.release(),
    build,
    supported: windows11,
    windows10,
    consoleInstalled: Boolean(consolePath),
    serviceRunning: service.running,
    busy: hookMidiOperationInProgress,
    ports,
    downloadUrl: HOOK_MIDI_DOWNLOAD_URL,
    loopMidiUrl: HOOK_MIDI_LOOPMIDI_URL
  };
}

function hookMidiNormalizeRootName(value) {
  const cleaned = String(value || '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!cleaned) throw new Error('Digite um nome para as portas Hook MIDI.');
  // O console acrescenta " (A)" e " (B)" e limita os nomes WinMM a 31 caracteres.
  return cleaned.slice(0, 27);
}

async function hookMidiRunConsole(args) {
  const consolePath = hookMidiFindConsole();
  if (!consolePath) {
    throw new Error('O Windows MIDI Services Runtime & Tools não está instalado. Use o botão Instalar componentes oficiais e abra novamente a Hook Center após a instalação.');
  }
  try {
    return await runProcess(consolePath, args, {
      timeout: 30000,
      maxBuffer: 2 * 1024 * 1024,
      env: { ...process.env, NO_COLOR: '1', TERM: 'dumb' }
    });
  } catch (error) {
    const detail = hookMidiCleanProcessMessage(error?.message || '');
    throw new Error(detail || 'O Windows MIDI Services não conseguiu concluir a operação.');
  }
}

async function createHookMidiPort(payload = {}) {
  if (!hookMidiIsWindows11()) throw new Error('O Hook MIDI está disponível apenas no Windows 11.');
  if (hookMidiOperationInProgress) throw new Error('Aguarde a operação atual do Hook MIDI terminar.');
  const rootName = hookMidiNormalizeRootName(payload.rootName || 'Hook MIDI');
  const current = await getHookMidiState();
  if (!current.consoleInstalled) {
    throw new Error('Instale primeiro os componentes oficiais do Windows MIDI Services.');
  }
  if (current.ports.length >= 16) throw new Error('O limite de 16 pares criados pela Hook Center foi atingido.');
  if (current.ports.some((port) => port.rootName.toLocaleLowerCase() === rootName.toLocaleLowerCase())) {
    throw new Error('Já existe um par Hook MIDI com esse nome.');
  }
  hookMidiOperationInProgress = true;
  const associationId = crypto.randomUUID();
  const uniqueIdentifier = `HookMidi${associationId.replace(/-/g, '').slice(0, 20)}`;
  let created = null;
  try {
    await hookMidiRunConsole([
      'loopback', 'create',
      '--root-name', rootName,
      '--association-id', associationId,
      '--unique-identifier', uniqueIdentifier
    ]);
    const service = await hookMidiServiceState();
    const ports = hookMidiStoredPorts();
    created = {
      associationId,
      rootName,
      endpointA: `${rootName} (A)`,
      endpointB: `${rootName} (B)`,
      uniqueIdentifier,
      createdAt: new Date().toISOString(),
      servicePid: service.pid
    };
    ports.push(created);
    hookMidiSavePorts(ports);
  } finally {
    hookMidiOperationInProgress = false;
  }
  return { ok: true, created, state: await getHookMidiState() };
}

async function removeHookMidiPort(payload = {}) {
  if (!hookMidiIsWindows11()) throw new Error('O Hook MIDI está disponível apenas no Windows 11.');
  if (hookMidiOperationInProgress) throw new Error('Aguarde a operação atual do Hook MIDI terminar.');
  const associationId = String(payload.associationId || '').trim().toLowerCase();
  const ports = hookMidiStoredPorts();
  const target = ports.find((port) => port.associationId.toLowerCase() === associationId);
  if (!target) throw new Error('Essa porta não foi criada pela Hook Center ou já não existe.');
  hookMidiOperationInProgress = true;
  try {
    await hookMidiRunConsole(['loopback', 'remove', '--association-id', target.associationId]);
    hookMidiSavePorts(ports.filter((port) => port.associationId !== target.associationId));
  } finally {
    hookMidiOperationInProgress = false;
  }
  return { ok: true, removed: target, state: await getHookMidiState() };
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
  const deviceFingerprint = await getDeviceFingerprint();

  if (!email || !machineId) {
    return { ok: false, message: 'Licença ainda não ativada.', state: getAppState() };
  }

  try {
    const result = await fetchJson(`${BACKEND_URL}/api/license/status`, {
      method: 'POST',
      body: JSON.stringify({ cpf, cnpj, document, email, machineId, deviceFingerprint, platform: process.platform, computerName: getStoredDeviceName() })
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
      saveSignedLicenseToken(result.licenseToken, { required: manual });
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
    preferredNetworkIp: '',
    preferredNetworkName: '',
    autoStart: true
  };
  return { ...defaults, ...stored, scriptsDir: stored.scriptsDir || defaults.scriptsDir };
}

function saveBridgeConfig(config) {
  store.set('bridge', { ...readBridgeConfig(), ...config });
}

function getSelectedBridgeNetwork(config = readBridgeConfig()) {
  const networks = typeof getAllLanIps === 'function' ? getAllLanIps() : [];
  const directCableIp = String(store.get('directCable.ip') || '').trim();
  // O cabo fica reservado para redundancia. O QR Code e o app continuam
  // anunciando Wi-Fi/LAN normal para o celular.
  const appNetworks = networks.filter((item) => !directCableIp || item.ip !== directCableIp);
  const preferredIp = String(config?.preferredNetworkIp || '').trim();
  const preferredName = String(config?.preferredNetworkName || '').trim();
  const selected = appNetworks.find((item) => preferredIp && item.ip === preferredIp)
    || appNetworks.find((item) => preferredName && item.name === preferredName)
    || appNetworks[0]
    || networks[0]
    || { name: 'Local', ip: '127.0.0.1', score: 0 };
  return { selected, networks };
}

async function selectBridgeNetwork(payload = {}) {
  const requestedIp = String(payload.ip || payload.preferredNetworkIp || '').trim();
  const networks = typeof getAllLanIps === 'function' ? getAllLanIps() : [];
  const selected = networks.find((item) => item.ip === requestedIp);
  if (!selected) {
    throw new Error('A rede escolhida não está mais disponível neste computador.');
  }
  saveBridgeConfig({
    preferredNetworkIp: selected.ip,
    preferredNetworkName: selected.name
  });
  return startBridgeServers();
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

function getChatMobileBootstrapSecret() {
  const current = String(store.get('chatMobileBootstrapSecret') || '').trim();
  if (/^[a-f0-9]{64}$/i.test(current)) return current.toLowerCase();
  const created = crypto.randomBytes(32).toString('hex');
  store.set('chatMobileBootstrapSecret', created);
  return created;
}

function buildBridgeServers(config) {
  const sharedDir = resolveBridgeScriptsDir(config);
  const bridgeWebAppDir = getBridgeWebAppDir();
  const { selected } = getSelectedBridgeNetwork(config);

  return [
    createBridgeServer({
      appName: 'Diretor',
      host: '0.0.0.0',
      port: Number(config.directorPort) || 47831,
      publicBridgeHost: selected.ip,
      appDir: bridgeWebAppDir,
      sharedDir,
      getTechnicalNoticeSettings,
      saveTechnicalNoticeSettings,
      chatApi: {
        getState: ({ afterId } = {}) => getChatState(afterId),
        sendMessage: (payload = {}) => sendChatMessage(payload),
        setPinnedMessage: (payload = {}) => setChatPinnedMessage(payload),
        deleteMessage: (payload = {}) => deleteChatMessage(payload),
        createMobileSession: () => createChatMobileSession()
      },
      chatBootstrapSecret: getChatMobileBootstrapSecret(),
      timecodeLanApi: {
        handleHttp: async (req, res, parsedUrl) => {
          if (timecodeLanRelay &&
              await timecodeLanRelay.handleHttp(req, res, parsedUrl)) {
            return true;
          }
          return !!parallelTimecodeLanRelay &&
            parallelTimecodeLanRelay.handleHttp(req, res, parsedUrl);
        },
      },
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
      publicBridgeHost: selected.ip,
      appDir: bridgeWebAppDir,
      sharedDir,
      getTechnicalNoticeSettings,
      saveTechnicalNoticeSettings,
      chatApi: {
        getState: ({ afterId } = {}) => getChatState(afterId),
        sendMessage: (payload = {}) => sendChatMessage(payload),
        setPinnedMessage: (payload = {}) => setChatPinnedMessage(payload),
        deleteMessage: (payload = {}) => deleteChatMessage(payload),
        createMobileSession: () => createChatMobileSession()
      },
      chatBootstrapSecret: getChatMobileBootstrapSecret(),
      isLicenseActive: isVsHookLicenseActiveForBridge,
      fallbackState: getBridgeFallbackState(),
      routes: [{ url: '/', file: 'index.html', contentType: 'text/html; charset=utf-8' }]
    })
  ];
}

async function stopBridgeServers() {
  const running = [...bridgeServers];
  const runningTimecodeRelay = timecodeLanRelay;
  const runningParallelTimecodeRelay = parallelTimecodeLanRelay;
  bridgeServers = [];
  bridgeInfos = [];
  timecodeLanRelay = null;
  parallelTimecodeLanRelay = null;
  timecodeRelayPeerAddresses.main = '';
  timecodeRelayPeerAddresses.parallel = '';
  await Promise.allSettled([
    ...running.map((server) => server.stop()),
    ...(runningTimecodeRelay ? [runningTimecodeRelay.stop()] : []),
    ...(runningParallelTimecodeRelay
      ? [runningParallelTimecodeRelay.stop()] : []),
  ]);
}

async function restartBridgeServersNow() {
  await stopBridgeServers();
  bridgeConfig = readBridgeConfig();
  fs.mkdirSync(resolveBridgeScriptsDir(bridgeConfig), { recursive: true });
  const relayCanUsePeerAddress = (channel, address) => {
    const normalized = String(address || '').replace(/^::ffff:/, '').trim();
    if (!normalized) return false;
    const other = channel === 'parallel' ? 'main' : 'parallel';
    return !timecodeRelayPeerAddresses[other] ||
      timecodeRelayPeerAddresses[other] !== normalized;
  };
  const relayPeerConnectionChanged = (channel, address, connected) => {
    if (channel !== 'main' && channel !== 'parallel') return;
    const normalized = String(address || '').replace(/^::ffff:/, '').trim();
    if (connected) {
      timecodeRelayPeerAddresses[channel] = normalized;
    } else if (!normalized ||
        timecodeRelayPeerAddresses[channel] === normalized) {
      timecodeRelayPeerAddresses[channel] = '';
    }
  };
  timecodeLanRelay = createTimecodeLanRelay({
    nativeBridgePort: 47830,
    getDirectorPort: () => Number(bridgeConfig?.directorPort) || 47831,
    getDeviceName: getStoredDeviceName,
    getDirectCableIp: () => String(store.get('directCable.ip') || ''),
    // A raiz é definida somente pela Hook Center. Nenhum caminho recebido da
    // LAN pode escolher onde o bundle Project Sync será gravado.
    getProjectSyncStagingDir: () => path.join(
      app.getPath('userData'), 'project-sync-staging'),
    isLicenseActive: isVsHookLicenseActiveForBridge,
    canUsePeerAddress: relayCanUsePeerAddress,
    onPeerConnectionChanged: relayPeerConnectionChanged,
  });
  parallelTimecodeLanRelay = createTimecodeLanRelay({
    channel: 'parallel',
    nativeBridgePort: 47830,
    discoveryPort: 47834,
    discoveryTargetPort: 47833,
    getDirectorPort: () => Number(bridgeConfig?.directorPort) || 47831,
    getDeviceName: getStoredDeviceName,
    getDirectCableIp: () => String(store.get('directCable.ip') || ''),
    getProjectSyncStagingDir: () => path.join(
      app.getPath('userData'), 'project-sync-staging'),
    isLicenseActive: isVsHookLicenseActiveForBridge,
    canUsePeerAddress: relayCanUsePeerAddress,
    onPeerConnectionChanged: relayPeerConnectionChanged,
  });
  const nextServers = buildBridgeServers(bridgeConfig);
  const nextInfos = [];

  try {
    for (const server of nextServers) {
      const info = await server.start();
      nextInfos.push(info);
    }
    await timecodeLanRelay.start();
    await parallelTimecodeLanRelay.start();
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
    if (timecodeLanRelay) {
      try { await timecodeLanRelay.stop(); } catch (_) {}
      timecodeLanRelay = null;
    }
    if (parallelTimecodeLanRelay) {
      try { await parallelTimecodeLanRelay.stop(); } catch (_) {}
      parallelTimecodeLanRelay = null;
    }
    bridgeServers = [];
    bridgeInfos = [];
    rebuildTrayMenu();
    if (isValidWindow(mainWindow)) mainWindow.webContents.send('bridge-status', getBridgeState());
    throw error;
  }
}

async function startBridgeServers() {
  // O monitor automático, a troca de rede e o botão manual podem disparar no
  // mesmo instante. Todos aguardam o mesmo reinício para não disputar portas.
  if (bridgeRestartPromise) return bridgeRestartPromise;
  const restart = restartBridgeServersNow();
  bridgeRestartPromise = restart;
  try {
    return await restart;
  } finally {
    if (bridgeRestartPromise === restart) bridgeRestartPromise = null;
  }
}

async function ensureBridgeServersRunning() {
  if (bridgeServers.length > 0) return getBridgeState();
  return startBridgeServers();
}

function getBridgeState() {
  const config = bridgeConfig || readBridgeConfig();
  const { selected, networks: allLanIps } = getSelectedBridgeNetwork(config);
  const lanIp = selected.ip;
  const directorPort = Number(config.directorPort) || 47831;
  const musiciansPort = Number(config.musiciansPort) || 47832;
  const chatBootstrapSecret = getChatMobileBootstrapSecret();
  const bridgeAppUrl = `http://${lanIp}:${directorPort}/?qr=1&v=${getBridgeAppCacheVersion()}&chatKey=${encodeURIComponent(chatBootstrapSecret)}`;
  return {
    running: bridgeServers.length > 0,
    lanIp,
    lanIps: allLanIps,
    selectedNetwork: selected,
    selectedNetworkIp: selected.ip,
    selectedNetworkName: selected.name,
    scriptsDir: resolveBridgeScriptsDir(config),
    directorPort,
    musiciansPort,
    directorUrl: `http://${lanIp}:${directorPort}`,
    musiciansUrl: `http://${lanIp}:${musiciansPort}`,
    browserUrl: bridgeAppUrl,
    qrCodeUrl: `http://${lanIp}:${directorPort}/qr.svg?url=${encodeURIComponent(bridgeAppUrl)}`,
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

function requestNativeBridgeStateForLyrics() {
  // TP1, TP2, QR e app compartilham o mesmo cache e a mesma requisição.
  // Isso impede que um Mac antigo receba várias cópias simultâneas do
  // snapshot completo.
  return getNativeBridgeStateSnapshot(3000);
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
    root.timerCountdownExpired || nested.expired || nested.overrun || nested.negative || nested.countdownExpired ||
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
  const lyricsStatePath = getLyricsStatePath(id);
  const data = readJsonFileSafe(lyricsStatePath, {});
  const nativeState = await requestNativeBridgeStateForLyrics();
  const nativeTpState = normalizeNativeTelepromptState(nativeState, id);
  if (nativeTpState) {
    // Com a extensao disponivel, inclusive no macOS, todo o estado do TP e do
    // cronometro vem da mesma fonte nativa. Isso evita misturar snapshots com
    // tempos de atualizacao diferentes.
    return nativeTpState;
  }

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

  const isMac = process.platform === 'darwin';
  const isLegacyMac = isHookCenterLegacyBuild();
  const isStandardMac = isMac && !isLegacyMac;
  const win = new BrowserWindow({
    width: 980,
    height: 560,
    // Janela do Teleprompt precisa aceitar formatos extremos, inclusive 9:16 vertical.
    minWidth: 180,
    minHeight: 180,
    // O conteúdo do Teleprompt já possui fundo preto. Mantê-lo opaco evita a
    // camada transparente do Chromium, que pode desaparecer em monitores
    // externos com drivers gráficos modificados pelo OpenCore.
    backgroundColor: '#000000',
    opacity: 1,
    title: 'Teleprompt',
    icon: getAppIconPath(),
    // Somente a Legacy usa a moldura nativa completa para compatibilidade com
    // AppKit antigo. Normal macOS e Windows mantêm a janela sem moldura.
    frame: isLegacyMac,
    // Mantem handles nativos de redimensionamento em janela sem moldura, especialmente no Windows.
    thickFrame: true,
    transparent: false,
    roundedCorners: isLegacyMac,
    focusable: true,
    movable: true,
    resizable: true,
    maximizable: true,
    // O Teleprompt precisa ocupar inclusive a barra de menus no macOS.
    fullscreenable: true,
    useContentSize: true,
    hasShadow: isLegacyMac,
    acceptFirstMouse: true,
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: false,
      // Somente o Legacy desativa a suspensão de quadros durante a troca de
      // monitor. A versão normal preserva o comportamento anterior.
      ...(isLegacyMac ? { backgroundThrottling: false } : {})
    }
  });

  lyricsWindows.set(id, win);
  const lyricsWebContentsId = win.webContents.id;
  const enforceOpaqueWindow = () => {
    if (win.isDestroyed()) return;
    if (isLegacyMac) {
      // Preserve a NSWindow Legacy com os padrões nativos. Alterar alpha,
      // sombra ou botões durante o movimento pode recriar sua camada Cocoa.
      try { win.webContents.invalidate(); } catch (_) {}
      return;
    }
    // A versão normal do macOS volta ao comportamento anterior, sem mutações
    // de opacidade, fundo, sombra ou botões nativos.
    if (isStandardMac) return;
    try { win.setOpacity(1); } catch (_) {}
    try { win.setBackgroundColor('#000000'); } catch (_) {}
  };
  enforceOpaqueWindow();
  applyLyricsWindowPinState(id, getLyricsSettings(id).alwaysOnTop === true);
  try { win.setResizable(true); } catch (_) {}
  try { win.setMinimumSize(180, 180); } catch (_) {}
  try { win.setIgnoreMouseEvents(false); } catch (_) {}
  win.loadFile(path.join(__dirname, 'lyrics.html'), {
    query: { slot: String(id), legacy: isLegacyMac ? '1' : '0' }
  });
  win.once('ready-to-show', () => {
    enforceOpaqueWindow();
    try { win.setIgnoreMouseEvents(false); } catch (_) {}
    win.show();
    try { win.focus(); } catch (_) {}
    broadcastLyricsWindowsState();
  });
  // No Legacy, deixa a NSWindow nativa intacta e solicita apenas uma nova
  // pintura depois do movimento. A versão normal não recebe esse listener.
  let legacyRepaintTimer = null;
  if (isLegacyMac) {
    win.on('move', () => {
      if (legacyRepaintTimer) clearTimeout(legacyRepaintTimer);
      legacyRepaintTimer = setTimeout(() => {
        if (win.isDestroyed()) return;
        try { win.webContents.invalidate(); } catch (_) {}
      }, 80);
    });
  } else if (!isStandardMac) {
    win.on('move', enforceOpaqueWindow);
  }
  win.webContents.on('did-finish-load', enforceOpaqueWindow);
  win.webContents.once('destroyed', () => legacyWindowDragSessions.delete(lyricsWebContentsId));
  win.on('maximize', () => { win.__vshookMaximized = true; });
  win.on('unmaximize', () => { win.__vshookMaximized = false; });
  win.on('enter-full-screen', () => { win.__vshookFullScreen = true; });
  win.on('leave-full-screen', () => { win.__vshookFullScreen = false; });
  win.on('closed', () => {
    if (legacyRepaintTimer) clearTimeout(legacyRepaintTimer);
    legacyWindowDragSessions.delete(lyricsWebContentsId);
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

function isLyricsWindowMaximized(win) {
  if (!win || win.isDestroyed()) return false;
  try {
    if (win.isMaximized()) return true;
  } catch (_) {}
  return win.__vshookMaximized === true;
}

function restoreMaximizedLyricsWindowForDrag(win, cursorPoint = null) {
  if (!win || win.isDestroyed()) return { restored: false, bounds: null };

  let currentBounds = null;
  try { currentBounds = win.getBounds(); } catch (_) {}
  if (process.platform !== 'darwin' || !isLyricsWindowMaximized(win)) {
    return { restored: false, bounds: currentBounds };
  }
  if (!currentBounds) {
    win.__vshookMaximized = false;
    try { win.unmaximize(); } catch (_) {}
    try { currentBounds = win.getBounds(); } catch (_) {}
    return { restored: true, bounds: currentBounds };
  }

  let normalBounds = currentBounds;
  try { normalBounds = win.getNormalBounds(); } catch (_) {}
  let cursor = cursorPoint;
  try { cursor = cursor || screen.getCursorScreenPoint(); } catch (_) {}

  const currentWidth = Math.max(1, Number(currentBounds?.width) || 1);
  const currentHeight = Math.max(1, Number(currentBounds?.height) || 1);
  const relativeX = Math.max(0, Math.min(1, (Number(cursor?.x) - Number(currentBounds?.x)) / currentWidth));
  const relativeY = Math.max(0, Math.min(1, (Number(cursor?.y) - Number(currentBounds?.y)) / currentHeight));
  const restoredBounds = {
    width: Math.max(1, Number(normalBounds?.width) || currentWidth),
    height: Math.max(1, Number(normalBounds?.height) || currentHeight),
    x: Number(normalBounds?.x) || 0,
    y: Number(normalBounds?.y) || 0
  };
  if (Number.isFinite(relativeX) && Number.isFinite(relativeY)) {
    restoredBounds.x = Math.round(Number(cursor.x) - (restoredBounds.width * relativeX));
    restoredBounds.y = Math.round(Number(cursor.y) - (restoredBounds.height * relativeY));
  }
  win.__vshookMaximized = false;
  try { win.unmaximize(); } catch (_) {}
  try { win.setBounds(restoredBounds, false); } catch (_) {}
  try { currentBounds = win.getBounds(); } catch (_) { currentBounds = restoredBounds; }
  return { restored: true, bounds: currentBounds };
}

function toggleLyricsWindowFullscreen(win) {
  if (!win || win.isDestroyed()) return { ok: false };

  const isReallyFullScreen = (() => {
    try { return win.isFullScreen(); } catch (_) { return false; }
  })();
  const isSimpleFullScreen = (() => {
    if (process.platform !== 'darwin' || typeof win.isSimpleFullScreen !== 'function') return false;
    try { return win.isSimpleFullScreen(); } catch (_) { return false; }
  })();
  const isFullScreen = isReallyFullScreen || isSimpleFullScreen || win.__vshookFullScreen === true;

  if (process.platform === 'darwin') {
    if (isFullScreen) {
      win.__vshookFullScreen = false;
      try { if (win.setSimpleFullScreen) win.setSimpleFullScreen(false); } catch (_) {}
      try { win.setFullScreen(false); } catch (_) {}
      const restoreBounds = win.__vshookBeforeFullScreenBounds || null;
      if (restoreBounds) {
        setTimeout(() => {
          if (!win || win.isDestroyed()) return;
          try { win.setBounds(restoreBounds, false); } catch (_) {}
        }, 80);
      }
      return { ok: true, fullScreen: false, maximized: false };
    }

    try { win.__vshookBeforeFullScreenBounds = win.getBounds(); } catch (_) { win.__vshookBeforeFullScreenBounds = null; }
    win.__vshookFullScreen = true;
    try {
      if (typeof win.setSimpleFullScreen === 'function') win.setSimpleFullScreen(true);
      else win.setFullScreen(true);
    } catch (_) {
      win.__vshookFullScreen = false;
      return { ok: false };
    }
    return { ok: true, fullScreen: true, maximized: false };
  }

  if (isFullScreen) {
    win.__vshookFullScreen = false;
    try { win.setFullScreen(false); } catch (_) {}

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
    // A versão da Central pertence ao próprio executável. A versão publicada
    // pelo backend identifica o pacote do VS Hook e não altera este campo.
    statusDisplayVersion: hookCenterBinaryVersion,
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
    installedPackages: store.get('installedPackages') || {},
    installedVsHookVersion,
    currentPackageInstalled: isUpdatePackageInstalled(getCurrentUpdatePackage()),
    currentPackageCached: Boolean(findCachedUpdateManifest(getCurrentUpdatePackage())),
    updateCacheDirectory: getOfflineUpdateCacheRoot(),
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
  if (process.platform !== 'darwin') return false;
  const legacyMarkerPath = path.join(process.resourcesPath || '', 'hook-center-legacy.marker');
  if (legacyMarkerPath && fs.existsSync(legacyMarkerPath)) return true;
  const configuredVariant = String(appPackage.hookCenterVariant || '').trim().toLowerCase();
  if (configuredVariant === 'legacy') return true;
  // Compatibilidade com builds antigas que ainda não possuem o marcador físico.
  return /legacy/i.test(`${app.getName() || ''} ${process.execPath || ''}`);
}

function getHookCenterPlatformKey() {
  if (isHookCenterLegacyBuild()) return 'macos-legacy';
  return getPlatformKey();
}

function getHookCenterApiUrl() {
  return `${BACKEND_URL}/api/hookcenter/latest?platform=${encodeURIComponent(getHookCenterPlatformKey())}`;
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
  const isCurrentExtensionUrl = (value, expectedName) => {
    const url = ensureAbsoluteUrl(value);
    if (!url) return '';
    try {
      const filename = decodeURIComponent(new URL(url).pathname.split('/').pop() || '').toLowerCase();
      return filename === expectedName.toLowerCase() ? url : '';
    } catch (_) {
      return '';
    }
  };

  if (process.platform === 'win32') {
    return [
      { key: 'vshookDll', url: isCurrentExtensionUrl(files.vshookDll || files.vshookExtDll, 'reaper_VSHookExt.dll'), filename: 'reaper_VSHookExt.dll' }
    ].filter((entry) => !!entry.url);
  }

  if (process.platform === 'darwin') {
    return [
      { key: 'vshookDylib', url: isCurrentExtensionUrl(files.vshookDylib || files.vshookExtDylib, 'reaper_VSHookExt.dylib'), filename: 'reaper_VSHookExt.dylib' }
    ].filter((entry) => !!entry.url);
  }

  return [];
}

function appendDownloadCacheBust(url) {
  try {
    const parsed = new URL(url);
    parsed.searchParams.set(
      'vshook_download',
      `${Date.now()}-${crypto.randomBytes(6).toString('hex')}`
    );
    return parsed.href;
  } catch (_) {
    return url;
  }
}

const fileIntegrityCache = new Map();

function getFileIntegrity(filePath) {
  const stat = fs.statSync(filePath);
  const cacheKey = path.resolve(filePath);
  const cached = fileIntegrityCache.get(cacheKey);
  if (cached &&
      cached.size === stat.size &&
      cached.mtimeMs === stat.mtimeMs) {
    return { size: cached.size, sha256: cached.sha256 };
  }
  const integrity = {
    size: stat.size,
    sha256: crypto.createHash('sha256')
      .update(fs.readFileSync(filePath))
      .digest('hex')
  };
  if (fileIntegrityCache.size >= 128) fileIntegrityCache.clear();
  fileIntegrityCache.set(cacheKey, {
    ...integrity,
    mtimeMs: stat.mtimeMs
  });
  return integrity;
}

function validateExtensionBinaryFile(filePath, key = '') {
  if (!filePath || !fs.existsSync(filePath)) {
    throw new Error('O arquivo da extensão não foi encontrado.');
  }
  const stat = fs.statSync(filePath);
  if (!stat.isFile() || stat.size < 4096) {
    throw new Error('O arquivo baixado da extensão está vazio ou incompleto.');
  }
  const handle = fs.openSync(filePath, 'r');
  const header = Buffer.alloc(4);
  try {
    const bytesRead = fs.readSync(handle, header, 0, header.length, 0);
    if (bytesRead !== header.length) {
      throw new Error('Não foi possível validar o arquivo da extensão.');
    }
  } finally {
    fs.closeSync(handle);
  }
  const normalizedKey = String(key || '').toLowerCase();
  if (normalizedKey.includes('dll') ||
      path.extname(filePath).toLowerCase() === '.dll') {
    if (header[0] !== 0x4d || header[1] !== 0x5a) {
      throw new Error('A DLL baixada não é um binário válido do Windows.');
    }
    return true;
  }
  if (normalizedKey.includes('dylib') ||
      path.extname(filePath).toLowerCase() === '.dylib') {
    const magic = header.toString('hex').toLowerCase();
    const validMachOMagic = new Set([
      'cafebabe',
      'bebafeca',
      'feedface',
      'cefaedfe',
      'feedfacf',
      'cffaedfe'
    ]);
    if (!validMachOMagic.has(magic)) {
      throw new Error('A dylib baixada não é um binário válido do macOS.');
    }
    return true;
  }
  throw new Error('O tipo do arquivo da extensão não pôde ser validado.');
}

function validateUpdateInstallerFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) {
    throw new Error('O instalador baixado não foi encontrado.');
  }
  const stat = fs.statSync(filePath);
  if (!stat.isFile() || stat.size < 4096) {
    throw new Error('O instalador baixado está vazio ou incompleto.');
  }

  const handle = fs.openSync(filePath, 'r');
  try {
    if (process.platform === 'win32') {
      const header = Buffer.alloc(2);
      if (fs.readSync(handle, header, 0, header.length, 0) !== header.length ||
          header[0] !== 0x4d || header[1] !== 0x5a) {
        throw new Error('O instalador baixado não é um executável válido do Windows.');
      }
    } else if (process.platform === 'darwin') {
      // Imagens UDIF/DMG terminam com um trailer de 512 bytes iniciado por
      // "koly". Isso impede que uma página HTML HTTP 200 substitua o cache.
      const signature = Buffer.alloc(4);
      const trailerOffset = stat.size - 512;
      if (fs.readSync(handle, signature, 0, signature.length, trailerOffset) !== signature.length ||
          signature.toString('ascii') !== 'koly') {
        throw new Error('O instalador baixado não é uma imagem DMG válida do macOS.');
      }
    }
  } finally {
    fs.closeSync(handle);
  }
  return true;
}

async function downloadFile(url, destPath, onProgress, options = {}) {
  const requestUrl = options.cacheBust === true
    ? appendDownloadCacheBust(url)
    : url;
  const controller = new AbortController();
  const inactivityTimeoutMs = Math.max(
    5000,
    Number(options.timeoutMs) || 120000
  );
  let timeoutHandle = null;
  const armTimeout = () => {
    if (timeoutHandle) clearTimeout(timeoutHandle);
    timeoutHandle = setTimeout(() => controller.abort(), inactivityTimeoutMs);
  };
  armTimeout();
  try {
    const response = await fetch(requestUrl, {
      headers: {
        'Cache-Control': 'no-cache, no-store, max-age=0',
        Pragma: 'no-cache'
      },
      signal: controller.signal
    });
    if (!response.ok) {
      throw new Error(`Falha ao baixar ${url}: HTTP ${response.status}`);
    }

    const total = Number(response.headers.get('content-length')) || 0;
    fs.mkdirSync(path.dirname(destPath), { recursive: true });

    const file = fs.createWriteStream(destPath);
    let downloaded = 0;

    if (!response.body || typeof response.body.getReader !== 'function') {
      const buffer = Buffer.from(await response.arrayBuffer());
      downloaded = buffer.length;
      file.write(buffer);
      file.end();
      await new Promise((resolve, reject) => {
        file.on('finish', resolve);
        file.on('error', reject);
      });
    } else {
      const reader = response.body.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          armTimeout();
          const chunk = Buffer.from(value);
          downloaded += chunk.length;
          if (!file.write(chunk)) {
            await new Promise((resolve) => file.once('drain', resolve));
          }
          if (total > 0) {
            onProgress(Math.round((downloaded / total) * 100));
          }
        }
      } finally {
        file.end();
      }
      await new Promise((resolve, reject) => {
        file.on('finish', resolve);
        file.on('error', reject);
      });
    }

    if (downloaded <= 0 ||
        (total > 0 &&
         !response.headers.get('content-encoding') &&
         downloaded !== total)) {
      throw new Error('O download terminou incompleto.');
    }

    onProgress(100);
    return { downloaded, total };
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw new Error('O download ficou sem resposta e foi interrompido.');
    }
    throw error;
  } finally {
    if (timeoutHandle) clearTimeout(timeoutHandle);
  }
}

let offlineUpdateCacheRecoveryComplete = false;

function recoverInterruptedUpdateCacheTransactions(root) {
  if (offlineUpdateCacheRecoveryComplete) return;
  offlineUpdateCacheRecoveryComplete = true;

  const refreshRoot = path.join(root, '.refresh');
  try {
    if (!fs.existsSync(refreshRoot)) return;
    const entries = fs.readdirSync(refreshRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory());
    const transactionPattern = /^(.+)-\d+-\d+-[0-9a-f]{12}\.(old|new)$/i;

    // Primeiro restaura o pacote anterior quando a troca foi interrompida
    // entre os dois renames. Se o destino já existe, a cópia nova venceu.
    for (const entry of entries) {
      const match = entry.name.match(transactionPattern);
      if (!match || match[2].toLowerCase() !== 'old') continue;
      const backupDir = path.join(refreshRoot, entry.name);
      const cacheDir = path.join(root, match[1]);
      try {
        if (fs.existsSync(cacheDir)) {
          fs.rmSync(backupDir, { recursive: true, force: true });
        } else {
          fs.renameSync(backupDir, cacheDir);
        }
      } catch (_) {}
    }

    // Um staging restante nunca foi ativado por completo e pode ser descartado.
    for (const entry of entries) {
      const match = entry.name.match(transactionPattern);
      if (!match || match[2].toLowerCase() !== 'new') continue;
      try {
        fs.rmSync(path.join(refreshRoot, entry.name), {
          recursive: true,
          force: true
        });
      } catch (_) {}
    }
    try { fs.rmdirSync(refreshRoot); } catch (_) {}
  } catch (_) {}
}

function getOfflineUpdateCacheRoot() {
  const root = path.join(app.getPath('userData'), 'offline-updates', getPlatformKey());
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  if (process.platform !== 'win32') {
    try { fs.chmodSync(root, 0o700); } catch (_) {}
  }
  recoverInterruptedUpdateCacheTransactions(root);
  return root;
}

function safeUpdateCacheSegment(value, fallback = 'update') {
  const safe = String(value || '')
    .trim()
    .replace(/^v/i, '')
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 72);
  return safe || fallback;
}

function getUpdatePackageIdentity(update) {
  const normalized = normalizeUpdate(update) || update || {};
  return String(getPlatformUpdateId(normalized) || normalized.updateId || normalized.version || '').trim();
}

function normalizeArtifactUrl(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    const parsed = new URL(raw);
    parsed.hash = '';
    return parsed.href;
  } catch (_) {
    return raw;
  }
}

function getUpdateArtifactIdentity(update) {
  const normalized = normalizeUpdate(update) || update || {};
  const entries = buildUpdatePackageEntries(normalized)
    .map((entry) => ({
      key: String(entry.key || ''),
      url: normalizeArtifactUrl(entry.url)
    }))
    .filter((entry) => entry.key && entry.url)
    .sort((a, b) => a.key.localeCompare(b.key));
  const descriptor = {
    schema: 2,
    product: String(normalized.product || 'vs-hook'),
    platform: getPlatformKey(),
    source: String(normalized.source || ''),
    testClient: Boolean(normalized.testClient || normalized.isTestClient),
    targetMachineId: String(normalized.targetMachineId || ''),
    updateId: String(getPlatformUpdateId(normalized) || normalized.updateId || ''),
    version: String(normalized.version || ''),
    revision: String(normalized.artifactRevision || normalized.revision || normalized.publishedAt || ''),
    entries
  };
  return crypto.createHash('sha256')
    .update(JSON.stringify(descriptor), 'utf8')
    .digest('hex');
}

function getUpdateCacheKey(update) {
  const normalized = normalizeUpdate(update) || update || {};
  const version = safeUpdateCacheSegment(normalized.version || 'sem-versao');
  // O sufixo inclui URL do instalador/extensao, updateId e revisao. Duas
  // publicacoes 1.0.1 diferentes nunca mais caem na mesma pasta por engano.
  const suffix = getUpdateArtifactIdentity(normalized).slice(0, 16);
  return `${version}-${suffix}`;
}

function getCachedManifestPath(cacheKey) {
  return path.join(getOfflineUpdateCacheRoot(), safeUpdateCacheSegment(cacheKey), 'manifest.json');
}

function readCachedManifestFile(manifestPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (!parsed || parsed.platform !== getPlatformKey() || !parsed.cacheKey) return null;
    const cacheDir = path.dirname(manifestPath);
    const files = parsed.files || {};
    if (files.installer &&
        (Number(parsed.schemaVersion) < 2 || !/^[a-f0-9]{64}$/.test(String(parsed.artifactIdentity || '')))) {
      return null;
    }
    const allFilesExist = Object.entries(files).every(([key, entry]) => {
      const filename = String(entry?.filename || '');
      if (!filename || path.basename(filename) !== filename) return false;
      const localPath = path.join(cacheDir, filename);
      if (!fs.existsSync(localPath)) return false;
      const expectedSize = Number(entry?.size);
      if (Number.isFinite(expectedSize) &&
          expectedSize > 0 &&
          fs.statSync(localPath).size !== expectedSize) {
        return false;
      }
      const expectedHash = String(entry?.sha256 || '').trim().toLowerCase();
      // Manifests antigos nao registravam o hash do DMG/EXE. Eles nao podem
      // ser usados para instalar a Central, pois um arquivo diferente podia
      // conservar versao, nome e URL.
      if (key === 'installer' && !/^[a-f0-9]{64}$/.test(expectedHash)) {
        return false;
      }
      if (expectedHash &&
          getFileIntegrity(localPath).sha256 !== expectedHash) {
        return false;
      }
      return true;
    });
    if (!allFilesExist || Object.keys(files).length === 0) return null;
    return { ...parsed, cacheDir, manifestPath };
  } catch (_) {
    return null;
  }
}

function listCachedUpdateManifests() {
  const root = getOfflineUpdateCacheRoot();
  try {
    if (!fs.existsSync(root)) return [];
    return fs.readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => readCachedManifestFile(path.join(root, entry.name, 'manifest.json')))
      .filter(Boolean)
      .sort((a, b) => String(b.cachedAt || '').localeCompare(String(a.cachedAt || '')));
  } catch (_) {
    return [];
  }
}

function cachedManifestToUpdate(manifest) {
  const normalized = normalizeUpdate(manifest?.update);
  if (!normalized) return null;
  return {
    ...normalized,
    cached: true,
    cacheKey: manifest.cacheKey,
    cachedAt: manifest.cachedAt || null,
    localOnly: true
  };
}

function findCachedUpdateManifest(update) {
  if (!update) return null;
  const normalized = normalizeUpdate(update) || update;
  const artifactIdentity = getUpdateArtifactIdentity(normalized);
  const identity = getUpdatePackageIdentity(normalized);
  const version = String(normalized.version || '').trim();
  const manifests = listCachedUpdateManifests();
  return manifests.find((manifest) => {
    if (artifactIdentity && manifest.artifactIdentity) {
      return artifactIdentity === manifest.artifactIdentity;
    }
    // Compatibilidade apenas para pacotes sem instalador. Um pacote completo
    // legado sem identidade de artefato/hash deve ser baixado de novo.
    if (manifest.files?.installer) return false;
    if (identity && manifest.identity && identity === manifest.identity) return true;
    return !identity && version && version === String(manifest.version || '').trim();
  }) || null;
}

function findCachedUpdateManifestByKey(cacheKey) {
  const requested = String(cacheKey || '').trim();
  if (!requested || safeUpdateCacheSegment(requested, '') !== requested) return null;
  return readCachedManifestFile(getCachedManifestPath(requested));
}

function decorateUpdatesWithCache(updates) {
  return (updates || []).map((update) => {
    const cached = findCachedUpdateManifest(update);
    return {
      ...update,
      cached: Boolean(cached),
      cacheKey: cached?.cacheKey || '',
      cachedAt: cached?.cachedAt || null,
      installed: isUpdatePackageInstalled(update)
    };
  });
}

function getInstallerFilename(update) {
  const version = safeUpdateCacheSegment(update?.version || 'versao');
  return process.platform === 'darwin'
    ? `Hook-Center-${version}-macOS.dmg`
    : `Hook-Center-${version}-Windows.exe`;
}

function buildUpdatePackageEntries(update) {
  const normalized = normalizeUpdate(update) || update;
  const files = getPlatformFiles(normalized);
  const entries = buildPayloadEntries(files);
  const directedTestUpdate = Boolean(
    normalized?.testClient ||
    normalized?.isTestClient ||
    normalized?.clientTest ||
    normalized?.test_client ||
    ['test-client', 'cliente-teste'].includes(String(normalized?.source || normalized?.origin || '').trim().toLowerCase())
  );
  const matchingHookCenter = normalizeHookCenterUpdate(store.get('hookCenterLatest'));
  const matchingCurrentInstaller = !directedTestUpdate &&
    normalized.current === true &&
    matchingHookCenter?.version &&
    String(matchingHookCenter.version) === String(normalized.version || '')
      ? matchingHookCenter.downloadUrl
      : '';
  const installerUrl = ensureAbsoluteUrl(
    files.installer ||
    files.exe ||
    files.dmg ||
    normalized.installerUrl ||
    normalized.downloadUrl ||
    matchingCurrentInstaller
  );
  if (installerUrl) {
    entries.push({ key: 'installer', url: installerUrl, filename: getInstallerFilename(normalized) });
  }
  return entries;
}

function getCurrentUpdatePackage() {
  const update = normalizeUpdate(store.get('latestUpdate'));
  const hookCenter = normalizeHookCenterUpdate(store.get('hookCenterLatest'));
  if (!update && !hookCenter) return null;

  const base = update || normalizeUpdate({
    published: true,
    product: 'vs-hook',
    updateId: hookCenter?.updateId,
    version: hookCenter?.version,
    title: hookCenter?.title,
    description: hookCenter?.notes,
    publishedAt: hookCenter?.publishedAt,
    files: { windows: {}, macos: {} }
  });
  if (!base) return null;

  const platformKey = getPlatformKey();
  const platformFiles = { ...(base.files?.[platformKey] || {}) };
  if (!platformFiles.installer && hookCenter?.downloadUrl) platformFiles.installer = hookCenter.downloadUrl;

  return {
    ...base,
    current: true,
    version: base.version || hookCenter?.version || '',
    files: {
      ...(base.files || {}),
      [platformKey]: platformFiles
    }
  };
}

async function cacheUpdatePackage(updateOverride = null, options = {}) {
  const normalized = normalizeUpdate(updateOverride) || getCurrentUpdatePackage();
  if (!normalized) throw new Error('Nenhuma atualização disponível para guardar.');

  const entries = buildUpdatePackageEntries(normalized);
  const requireInstaller = options.requireInstaller !== false;
  const hasInstaller = entries.some((entry) => entry.key === 'installer');
  const hasExtension = entries.some((entry) => entry.key === 'vshookDll' || entry.key === 'vshookDylib');
  if (!hasExtension) throw new Error('A extensão desta versão não está disponível para este sistema.');
  if (requireInstaller && !hasInstaller) throw new Error('O instalador da Hook Center não está disponível para esta versão.');

  // O registro selecionado pelo botão Instalar só volta a existir depois que
  // todos os arquivos e hashes forem validados e o manifesto for gravado.
  store.set('downloadedFiles', null);
  if (hasInstaller) store.set('downloadedHookCenterUpdate', null);

  const cacheKey = getUpdateCacheKey(normalized);
  const cacheRoot = getOfflineUpdateCacheRoot();
  const cacheDir = path.join(cacheRoot, cacheKey);
  const forceRedownload = options.forceRedownload === true;
  const refreshToken = forceRedownload
    ? `${process.pid}-${Date.now()}-${crypto.randomBytes(6).toString('hex')}`
    : '';
  const refreshRoot = forceRedownload ? path.join(cacheRoot, '.refresh') : '';
  const stagingDir = forceRedownload
    ? path.join(refreshRoot, `${cacheKey}-${refreshToken}.new`)
    : cacheDir;
  const backupDir = forceRedownload
    ? path.join(refreshRoot, `${cacheKey}-${refreshToken}.old`)
    : '';
  fs.mkdirSync(stagingDir, { recursive: true });
  const previousManifest = readCachedManifestFile(path.join(cacheDir, 'manifest.json'));
  const output = {};
  const manifestFiles = {};
  let manifest;

  try {
    for (let index = 0; index < entries.length; index += 1) {
      const entry = entries[index];
      const finalDest = path.join(cacheDir, entry.filename);
      const dest = path.join(stagingDir, entry.filename);
      const previousEntry = previousManifest?.files?.[entry.key];
      const isExtensionEntry =
        entry.key === 'vshookDll' || entry.key === 'vshookDylib';
      const isCenterInstallerEntry = entry.key === 'installer';
      const mustRefreshBinaryEntry =
        isExtensionEntry || isCenterInstallerEntry;
      // A DLL/dylib e o instalador da Central podem ser substituidos no
      // servidor mantendo versao, nome e URL (principalmente nas builds de
      // teste 1.0.1). Reaproveitar por URL instalava indefinidamente o binario
      // ou o DMG anterior e mantinha o protocolo antigo do Project Sync.
      const canReuse =
        !forceRedownload &&
        !mustRefreshBinaryEntry &&
        previousEntry?.url === entry.url &&
        fs.existsSync(dest);
      if (!canReuse) {
        const partial = `${dest}.part`;
        await fs.promises.rm(partial, { force: true }).catch(() => {});
        try {
          await downloadFile(entry.url, partial, (fileProgress) => {
            const totalProgress = Math.round(((index * 100) + fileProgress) / entries.length);
            if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', totalProgress);
          }, {
            cacheBust: forceRedownload || mustRefreshBinaryEntry,
            timeoutMs: isExtensionEntry ? 30000 : 120000
          });
          if (isExtensionEntry) {
            validateExtensionBinaryFile(partial, entry.key);
          } else if (entry.key === 'installer') {
            validateUpdateInstallerFile(partial);
          }
          await fs.promises.rm(dest, { force: true }).catch(() => {});
          await fs.promises.rename(partial, dest);
          fileIntegrityCache.delete(path.resolve(dest));
        } catch (error) {
          await fs.promises.rm(partial, { force: true }).catch(() => {});
          throw error;
        }
      } else if (isValidWindow(mainWindow)) {
        mainWindow.webContents.send('download-progress', Math.round(((index + 1) * 100) / entries.length));
      }
      output[entry.key] = finalDest;
      // O instalador tambem recebe hash. Validar somente extensao deixava um
      // DMG/EXE antigo passar quando a versao e a URL eram reutilizadas.
      const integrity = getFileIntegrity(dest);
      manifestFiles[entry.key] = {
        url: entry.url,
        filename: entry.filename,
        size: integrity.size,
        sha256: integrity.sha256
      };
    }

    manifest = {
      schemaVersion: 2,
      cacheKey,
      identity: getUpdatePackageIdentity(normalized),
      artifactIdentity: getUpdateArtifactIdentity(normalized),
      platform: getPlatformKey(),
      version: normalized.version || '',
      updateId: normalized.updateId || '',
      title: normalized.title || '',
      description: normalized.description || '',
      publishedAt: normalized.publishedAt || null,
      cachedAt: new Date().toISOString(),
      files: manifestFiles,
      update: normalized
    };
    const manifestPath = path.join(stagingDir, 'manifest.json');
    const tempManifestPath = `${manifestPath}.tmp`;
    fs.writeFileSync(tempManifestPath, JSON.stringify(manifest, null, 2), 'utf8');
    fs.rmSync(manifestPath, { force: true });
    fs.renameSync(tempManifestPath, manifestPath);

    if (forceRedownload) {
      const hadPreviousCache = fs.existsSync(cacheDir);
      fs.mkdirSync(refreshRoot, { recursive: true });
      fs.rmSync(backupDir, { recursive: true, force: true });
      if (hadPreviousCache) fs.renameSync(cacheDir, backupDir);
      try {
        fs.renameSync(stagingDir, cacheDir);
      } catch (error) {
        if (hadPreviousCache && fs.existsSync(backupDir) && !fs.existsSync(cacheDir)) {
          fs.renameSync(backupDir, cacheDir);
        }
        throw error;
      }
      // A cópia nova já está ativa. Uma eventual falha ao limpar o backup da
      // transação não deve transformar a reinstalação concluída em erro.
      try { fs.rmSync(backupDir, { recursive: true, force: true }); } catch (_) {}
      try { fs.rmdirSync(refreshRoot); } catch (_) {}
    }
  } catch (error) {
    if (forceRedownload) {
      try { fs.rmSync(stagingDir, { recursive: true, force: true }); } catch (_) {}
      try { fs.rmdirSync(refreshRoot); } catch (_) {}
    }
    throw error;
  }

  const extensionFiles = Object.fromEntries(
    Object.entries(output).filter(([key]) => key !== 'installer')
  );
  store.set('downloadedFiles', {
    updateId: getPlatformUpdateId(normalized),
    globalUpdateId: normalized.updateId,
    version: normalized.version,
    platform: getPlatformKey(),
    cacheKey,
    artifactIdentity: manifest.artifactIdentity,
    update: normalized,
    completePackage: Boolean(output.installer),
    files: extensionFiles,
    manifest: {
      platform: getPlatformKey(),
      updateId: getPlatformUpdateId(normalized),
      version: normalized.version || '',
      files: Object.fromEntries(entries.filter((entry) => entry.key !== 'installer').map((entry) => [entry.key, { url: entry.url, filename: entry.filename }]))
    }
  });
  if (output.installer) {
    store.set('downloadedHookCenterUpdate', {
      version: normalized.version,
      updateId: normalized.updateId || normalized.version,
      path: output.installer,
      platform: process.platform,
      sourceUrl: manifest.files?.installer?.url || '',
      sha256: manifest.files?.installer?.sha256 || '',
      artifactIdentity: manifest.artifactIdentity,
      downloadedAt: manifest.cachedAt,
      cacheKey
    });
  }
  if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', 100);
  return { ok: true, cached: true, cacheKey, version: normalized.version, files: output };
}

function removeCachedUpdatePackage(update) {
  const manifest = findCachedUpdateManifest(update);
  if (!manifest) return { ok: true, removed: false };
  const root = path.resolve(getOfflineUpdateCacheRoot());
  const target = path.resolve(manifest.cacheDir);
  const relative = path.relative(root, target);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error('A pasta local desta atualização é inválida.');
  }
  fs.rmSync(target, { recursive: true, force: true });
  return { ok: true, removed: true, cacheKey: manifest.cacheKey };
}

function isUpdatePackageInstalled(update) {
  if (!update) return false;
  const identity = getUpdatePackageIdentity(update);
  const activeIdentity = String(store.get('activeInstalledPackageIdentity') || '').trim();
  if (identity && activeIdentity) return identity === activeIdentity;
  const installed = store.get('installedManifest') || {};
  return Boolean(
    identity &&
    (installed.updateId === identity || installed.globalUpdateId === identity)
  );
}

function markUpdatePackageInstalled(update, manifest) {
  const identity = getUpdatePackageIdentity(update);
  if (!identity) return;
  const installedPackages = store.get('installedPackages') || {};
  installedPackages[identity] = {
    version: update.version || '',
    updateId: update.updateId || '',
    cacheKey: manifest?.cacheKey || '',
    installedAt: new Date().toISOString()
  };
  store.set('installedPackages', installedPackages);
  store.set('activeInstalledPackageIdentity', identity);
}

async function installCachedUpdatePackage(updateOverride = null, options = {}) {
  const requestedSource = String(options.source || 'auto').trim().toLowerCase();
  const source = ['auto', 'internet', 'computer'].includes(requestedSource)
    ? requestedSource
    : 'auto';
  const requestedCacheKey = String(options.cacheKey || '').trim();
  let manifest = requestedCacheKey
    ? findCachedUpdateManifestByKey(requestedCacheKey)
    : null;
  // Havendo cacheKey, o manifesto baixado e soberano. Um estado remoto novo
  // nunca pode trocar os metadados/arquivos durante o clique Instalar.
  let update = normalizeUpdate(manifest?.update) ||
    normalizeUpdate(updateOverride) ||
    getCurrentUpdatePackage();
  if (!update) throw new Error('Atualização não encontrada.');
  if (requestedCacheKey && !manifest && source !== 'internet') {
    throw new Error('O pacote que foi baixado não está mais íntegro. Baixe novamente.');
  }
  if (!manifest) manifest = findCachedUpdateManifest(update);

  if (source === 'internet') {
    // A escolha pela internet sempre renova o pacote inteiro. A troca do cache
    // só acontece depois que extensão e instalador terminarem de baixar.
    await cacheUpdatePackage(update, {
      requireInstaller: true,
      forceRedownload: true
    });
    manifest = findCachedUpdateManifest(update);
  } else if (source === 'computer') {
    // Este caminho é deliberadamente offline: nunca tenta completar ou atualizar
    // o pacote pela rede quando o usuário escolhe os arquivos do computador.
    if (!manifest) {
      throw new Error('Os arquivos completos desta versão não estão salvos neste computador. Escolha baixar da internet.');
    }
  } else if (!requestedCacheKey) {
    const cachedAtMs = Date.parse(String(manifest?.cachedAt || ''));
    const cacheWasJustDownloaded = Number.isFinite(cachedAtMs) &&
      Date.now() - cachedAtMs <= 2 * 60 * 1000;
    if (manifest && !updateOverride && !cacheWasJustDownloaded) {
      // Mantém o comportamento das instalações antigas que ainda não informam
      // explicitamente se devem usar a internet ou o cache local.
      try {
        await cacheUpdatePackage(update, { requireInstaller: true });
        manifest = findCachedUpdateManifest(update);
      } catch (_) {}
    }
    if (!manifest) {
      await cacheUpdatePackage(update, { requireInstaller: true });
      manifest = findCachedUpdateManifest(update);
    }
  }
  if (!manifest) throw new Error('Não foi possível preparar os arquivos locais desta versão.');

  const cachedFiles = {};
  for (const [key, entry] of Object.entries(manifest.files || {})) {
    cachedFiles[key] = path.join(manifest.cacheDir, entry.filename);
  }
  if (!cachedFiles.installer || !fs.existsSync(cachedFiles.installer)) {
    throw new Error('O instalador local da Hook Center não foi encontrado.');
  }
  validateUpdateInstallerFile(cachedFiles.installer);
  const installerExpectedHash = String(manifest.files?.installer?.sha256 || '').trim().toLowerCase();
  const installerIntegrity = getFileIntegrity(cachedFiles.installer);
  if (!/^[a-f0-9]{64}$/.test(installerExpectedHash) ||
      installerIntegrity.sha256 !== installerExpectedHash) {
    throw new Error('O instalador local da Hook Center não corresponde ao pacote baixado. Baixe novamente.');
  }
  const extensionKey = process.platform === 'win32'
    ? 'vshookDll'
    : process.platform === 'darwin'
      ? 'vshookDylib'
      : '';
  const extensionPath = extensionKey ? cachedFiles[extensionKey] : '';
  if (!extensionPath || !fs.existsSync(extensionPath)) {
    throw new Error('A extensão deste sistema não foi encontrada no pacote.');
  }
  validateExtensionBinaryFile(extensionPath, extensionKey);

  // A Hook Center do pacote precisa entrar sempre primeiro, mesmo quando o
  // número da versão não mudou. Builds de teste podem manter a versão pública
  // e ainda assim trazer um companion, tema ou interface mais recente.
  // Os caminhos do cache ficam no userData e sobrevivem à troca do aplicativo;
  // ao abrir, a central nova conclui a instalação usando o companion e os temas
  // que vieram dentro dela, nunca os arquivos da central antiga.
  store.set('pendingPostCenterUpdateInstall', {
    targetCenterVersion: update.version,
    update,
    manifest: {
      cacheKey: manifest.cacheKey || '',
      artifactIdentity: manifest.artifactIdentity || '',
      platform: manifest.platform || getPlatformKey(),
      files: manifest.files || {}
    },
    files: Object.fromEntries(
      Object.entries(cachedFiles).filter(([key]) => key !== 'installer')
    ),
    queuedAt: new Date().toISOString()
  });
  if (process.platform === 'win32') {
    launchWindowsUpdateInstaller(cachedFiles.installer);
    quitAfterWindowsInstallerIsQueued();
    return {
      ok: true,
      action: 'center-first-installer-started',
      version: update.version
    };
  }
  const openError = await shell.openPath(cachedFiles.installer);
  if (openError) throw new Error(openError);
  quitAfterMacDmgIsOpened();
  return {
    ok: true,
    action: 'center-first-dmg-opened',
    version: update.version
  };
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
    const isExtensionEntry =
      entry.key === 'vshookDll' || entry.key === 'vshookDylib';
    await downloadFile(entry.url, dest, (fileProgress) => {
      const totalProgress = Math.round(((i * 100) + fileProgress) / entries.length);
      if (isValidWindow(mainWindow)) mainWindow.webContents.send('download-progress', totalProgress);
    }, {
      cacheBust: isExtensionEntry,
      timeoutMs: isExtensionEntry ? 30000 : 120000
    });
    if (isExtensionEntry) {
      validateExtensionBinaryFile(dest, entry.key);
    }
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
  if (!source || !fs.existsSync(source)) {
    throw new Error('O arquivo da extensão baixada não foi encontrado.');
  }
  validateExtensionBinaryFile(source, 'vshookDll');
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const expected = getFileIntegrity(source);
  const temporary = `${destination}.tmp-${process.pid}-${Date.now()}`;
  const backup = `${destination}.backup-${process.pid}-${Date.now()}`;
  const hadExistingDestination = fs.existsSync(destination);
  let movedPreviousToBackup = false;
  try {
    fs.copyFileSync(source, temporary);
    const copied = getFileIntegrity(temporary);
    if (copied.size !== expected.size || copied.sha256 !== expected.sha256) {
      throw new Error('A verificação da DLL copiada falhou.');
    }
    if (hadExistingDestination) {
      fs.renameSync(destination, backup);
      movedPreviousToBackup = true;
    }
    fs.renameSync(temporary, destination);
    fileIntegrityCache.delete(path.resolve(destination));
    const installed = getFileIntegrity(destination);
    if (installed.size !== expected.size ||
        installed.sha256 !== expected.sha256) {
      throw new Error('A DLL instalada não corresponde ao arquivo baixado.');
    }
    if (movedPreviousToBackup) {
      fs.rmSync(backup, { force: true });
      movedPreviousToBackup = false;
    }
    return installed;
  } catch (error) {
    if (movedPreviousToBackup || !hadExistingDestination) {
      try { fs.rmSync(destination, { force: true }); } catch (_) {}
    }
    if (movedPreviousToBackup && fs.existsSync(backup)) {
      try {
        fs.renameSync(backup, destination);
        fileIntegrityCache.delete(path.resolve(destination));
        movedPreviousToBackup = false;
      } catch (_) {}
    }
    throw error;
  } finally {
    try { fs.rmSync(temporary, { force: true }); } catch (_) {}
    if (!movedPreviousToBackup) {
      try { fs.rmSync(backup, { force: true }); } catch (_) {}
    }
  }
}

function getBundledVshookCompanionDir() {
  return path.join(process.resourcesPath || '', 'vshook-companion');
}

function getBundledVshookThemePaths() {
  const directories = [
    path.join(process.resourcesPath || '', 'vshook-themes'),
    path.join(__dirname, '..', 'themes')
  ];
  for (const directory of directories) {
    if (!directory || !physicalFs.existsSync(directory)) continue;
    const themes = physicalFs.readdirSync(directory, { withFileTypes: true })
      .filter((entry) => (
        entry.isFile() && /\.(?:ReaperTheme|ReaperThemeZip)$/i.test(entry.name)
      ))
      .map((entry) => path.join(directory, entry.name))
      .sort((left, right) => path.basename(left).localeCompare(path.basename(right)));
    if (themes.length > 0) return themes;
  }
  throw new Error(
    'Nenhum arquivo .ReaperTheme ou .ReaperThemeZip veio dentro desta versão da Hook Center.'
  );
}

function copyBundledThemeEnsured(source, destination) {
  const expected = getFileIntegrity(source);
  const temporary = `${destination}.tmp-${process.pid}-${Date.now()}`;
  const backup = `${destination}.backup-${process.pid}-${Date.now()}`;
  const hadExistingDestination = physicalFs.existsSync(destination);
  let movedPreviousToBackup = false;
  physicalFs.mkdirSync(path.dirname(destination), { recursive: true });
  try {
    physicalFs.copyFileSync(source, temporary);
    const copied = getFileIntegrity(temporary);
    if (copied.size !== expected.size || copied.sha256 !== expected.sha256) {
      throw new Error('A verificação do tema copiado falhou.');
    }
    if (hadExistingDestination) {
      physicalFs.renameSync(destination, backup);
      movedPreviousToBackup = true;
    }
    physicalFs.renameSync(temporary, destination);
    fileIntegrityCache.delete(path.resolve(destination));
    const installed = getFileIntegrity(destination);
    if (installed.size !== expected.size || installed.sha256 !== expected.sha256) {
      throw new Error('O tema instalado não corresponde ao arquivo da Hook Center.');
    }
    if (movedPreviousToBackup) {
      physicalFs.rmSync(backup, { force: true });
      movedPreviousToBackup = false;
    }
  } catch (error) {
    if (movedPreviousToBackup || !hadExistingDestination) {
      try { physicalFs.rmSync(destination, { force: true }); } catch (_) {}
    }
    if (movedPreviousToBackup && physicalFs.existsSync(backup)) {
      try {
        physicalFs.renameSync(backup, destination);
        fileIntegrityCache.delete(path.resolve(destination));
        movedPreviousToBackup = false;
      } catch (_) {}
    }
    throw error;
  } finally {
    try { physicalFs.rmSync(temporary, { force: true }); } catch (_) {}
    if (!movedPreviousToBackup) {
      try { physicalFs.rmSync(backup, { force: true }); } catch (_) {}
    }
  }
}

function installWindowsVshookTheme() {
  const reaperRoot = path.dirname(getWindowsReaperUserPluginsDir());
  const themeSources = getBundledVshookThemePaths();
  const installedThemeDir = path.join(reaperRoot, 'ColorThemes');
  // Instala ou atualiza apenas arquivos com o mesmo nome. Temas antigos do
  // usuario, inclusive versoes anteriores do ReiVS, nunca sao removidos.
  for (const source of themeSources) {
    copyBundledThemeEnsured(
      source,
      path.join(installedThemeDir, path.basename(source))
    );
  }
}

function windowsVshookCompanionCopyIsComplete(source, destination) {
  const pending = [[source, destination]];

  while (pending.length > 0) {
    const [sourceDir, destinationDir] = pending.pop();
    if (!physicalFs.existsSync(destinationDir)) return false;

    for (const entry of physicalFs.readdirSync(sourceDir, { withFileTypes: true })) {
      const sourceEntry = path.join(sourceDir, entry.name);
      const destinationEntry = path.join(destinationDir, entry.name);

      if (entry.isDirectory()) {
        if (
          !physicalFs.existsSync(destinationEntry) ||
          !physicalFs.statSync(destinationEntry).isDirectory()
        ) {
          return false;
        }
        pending.push([sourceEntry, destinationEntry]);
        continue;
      }

      if (!entry.isFile()) continue;
      if (!physicalFs.existsSync(destinationEntry)) return false;
      const sourceStat = physicalFs.statSync(sourceEntry);
      const destinationStat = physicalFs.statSync(destinationEntry);
      if (!destinationStat.isFile() || sourceStat.size !== destinationStat.size) return false;
    }
  }

  return true;
}

function installWindowsVshookCompanion() {
  const source = getBundledVshookCompanionDir();
  const sourceExecutable = path.join(
    source,
    'VS Hook Teleprompt Settings.exe'
  );
  if (!source || !physicalFs.existsSync(sourceExecutable)) {
    throw new Error(
      'O aplicativo de configurações do TP não veio completo nesta versão da Hook Center.'
    );
  }
  const destination = path.join(
    getWindowsReaperUserPluginsDir(),
    'VSHookTelepromptSettings'
  );
  // Nunca apaga a instalação anterior antes da nova cópia terminar. Uma nova
  // tentativa completa/substitui somente os arquivos necessários.
  physicalFs.mkdirSync(destination, { recursive: true });
  try {
    physicalFs.cpSync(source, destination, {
      recursive: true,
      force: true
    });
  } catch (error) {
    if (['EBUSY', 'EPERM', 'EACCES'].includes(String(error?.code || ''))) {
      throw new Error(
        'Feche as Configurações do TP e tente instalar novamente.'
      );
    }
    throw error;
  }
  if (!windowsVshookCompanionCopyIsComplete(source, destination)) {
    throw new Error(
      'A cópia das Configurações do TP não foi concluída. Tente instalar novamente.'
    );
  }
  const installedExecutable = path.join(
    destination,
    'VS Hook Teleprompt Settings.exe'
  );
  if (!physicalFs.existsSync(installedExecutable)) {
    throw new Error(
      'A cópia das Configurações do TP não foi concluída. Tente instalar novamente.'
    );
  }
}

function getWindowsPublicVsHookDir() {
  const publicDir = process.env.PUBLIC || process.env.ALLUSERSPROFILE || 'C:\\Users\\Public';
  return path.join(publicDir, 'VS Hook APP');
}

function removeWindowsPublicVsHookDir() {
  const publicDir = path.resolve(
    process.env.PUBLIC || process.env.ALLUSERSPROFILE || 'C:\\Users\\Public'
  );
  const target = path.resolve(getWindowsPublicVsHookDir());
  if (path.dirname(target).toLowerCase() !== publicDir.toLowerCase() ||
      path.basename(target).toLowerCase() !== 'vs hook app') {
    throw new Error('A pasta antiga do VS Hook não pôde ser validada.');
  }
  try {
    physicalFs.rmSync(target, { recursive: true, force: true });
  } catch (_) {
    throw new Error(
      'Não foi possível apagar a pasta antiga VS Hook APP. ' +
      'Feche o REAPER e tente novamente.'
    );
  }
}

function getWindowsReaperUserPluginsDir() {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'REAPER', 'UserPlugins');
}

function getWindowsReaperUserPluginsDirs() {
  const candidates = [getWindowsReaperUserPluginsDir()];
  const profilesRoot = path.dirname(os.homedir());
  try {
    for (const entry of physicalFs.readdirSync(profilesRoot, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      candidates.push(path.join(
        profilesRoot, entry.name, 'AppData', 'Roaming', 'REAPER', 'UserPlugins'
      ));
    }
  } catch (_) {}
  const programData = process.env.PROGRAMDATA || process.env.ProgramData;
  if (programData) candidates.push(path.join(programData, 'REAPER', 'UserPlugins'));

  const seen = new Set();
  return candidates.filter((dir) => {
    const key = path.resolve(dir).toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return physicalFs.existsSync(dir);
  });
}

function removeLegacyWindowsVshookExtensions() {
  const failures = [];
  for (const pluginsDir of getWindowsReaperUserPluginsDirs()) {
    // Nome exato e diretório UserPlugins conhecido: não remove outros plugins.
    const resolvedPluginsDir = path.resolve(pluginsDir);
    const legacyFile = path.resolve(
      resolvedPluginsDir, 'reaper_vshook.dll'
    );
    const isExpectedTarget =
      path.basename(resolvedPluginsDir).toLowerCase() === 'userplugins' &&
      path.basename(path.dirname(resolvedPluginsDir)).toLowerCase() === 'reaper' &&
      path.dirname(legacyFile).toLowerCase() ===
        resolvedPluginsDir.toLowerCase() &&
      path.basename(legacyFile).toLowerCase() === 'reaper_vshook.dll';
    if (!isExpectedTarget) continue;
    try {
      physicalFs.rmSync(legacyFile, { force: true });
      if (physicalFs.existsSync(legacyFile)) failures.push(legacyFile);
    } catch (_) {
      failures.push(legacyFile);
    }
  }
  if (failures.length) {
    throw new Error(
      'Não foi possível remover a extensão antiga reaper_vshook.dll. ' +
      'Feche o REAPER e execute a Hook Center como administrador.'
    );
  }
}

function removeLegacyVsHookLuaFiles(dir) {
  if (!dir) return;
  for (const filename of ['VS Hook Pro.lua', 'VS Hook Basic.lua', 'VS Hook.lua', 'Hook Lyrics.lua', 'Hook lyrics.lua']) {
    try { fs.rmSync(path.join(dir, filename), { force: true }); } catch (_) {}
  }
}

function isWindowsReaperRunning() {
  if (process.platform !== 'win32') return false;
  try {
    const output = execFileSync(
      'tasklist.exe',
      ['/FI', 'IMAGENAME eq reaper.exe', '/FO', 'CSV', '/NH'],
      { encoding: 'utf8', windowsHide: true, timeout: 3000 }
    );
    return /(^|[",\s])reaper\.exe([",\s]|$)/i.test(output);
  } catch (_) {}
  try {
    execFileSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'if (Get-Process -Name reaper -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }'
      ],
      { stdio: 'ignore', windowsHide: true, timeout: 3000 }
    );
    return true;
  } catch (_) {}
  return false;
}

function installWindowsPayload(files) {
  if (isWindowsReaperRunning()) {
    throw new Error(
      'Feche completamente o REAPER antes de instalar a extensão.'
    );
  }
  removeLegacyWindowsVshookExtensions();
  removeWindowsPublicVsHookDir();
  copyFileEnsured(files.vshookDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_VSHookExt.dll'));
  // Confere novamente o diretório antes de entregar o controle ao instalador.
  // O customInstall e a próxima inicialização repetem a mesma limpeza.
  removeLegacyWindowsVshookExtensions();
  installWindowsVshookCompanion();
  installWindowsVshookTheme();
}

function cleanupLegacyWindowsVshookOnStartup() {
  if (process.platform !== 'win32' || isWindowsReaperRunning()) return;
  const currentExtension = path.join(
    getWindowsReaperUserPluginsDir(),
    'reaper_VSHookExt.dll'
  );
  if (!physicalFs.existsSync(currentExtension)) return;
  try {
    removeLegacyWindowsVshookExtensions();
  } catch (error) {
    console.warn(
      '[Hook Center] Extensão legada não pôde ser removida:',
      error?.message || error
    );
  }
}

function isMacReaperRunning() {
  if (process.platform !== 'darwin') return false;
  try {
    execFileSync('/usr/bin/pgrep', ['-x', 'REAPER'], {
      stdio: 'ignore',
      timeout: 3000
    });
    return true;
  } catch (_) {
    return false;
  }
}

function installMacPayload(files, options = {}) {
  const installExtension = options.installExtension !== false;
  if (installExtension && isMacReaperRunning()) {
    throw new Error(
      'Encerre completamente o REAPER com Cmd+Q antes de instalar. ' +
      'Fechar somente a janela não descarrega a extensão antiga.'
    );
  }
  if (installExtension &&
      (!files?.vshookDylib || !fs.existsSync(files.vshookDylib))) {
    throw new Error('A dylib do VS Hook não foi encontrada no pacote.');
  }
  if (installExtension) {
    validateExtensionBinaryFile(files.vshookDylib, 'vshookDylib');
  }
  const commands = [];
  const vshookSource = installExtension ? files.vshookDylib : '';
  const companionSource = path.join(
    getBundledVshookCompanionDir(),
    'VS Hook Teleprompt Settings.app'
  );
  const hasCompanion = fs.existsSync(companionSource);
  const themeSources = getBundledVshookThemePaths();

  commands.push('set -e');
  commands.push('GLOBAL_REAPER="/Library/Application Support/REAPER"');
  commands.push('GLOBAL_PLUGIN_DIR="$GLOBAL_REAPER/UserPlugins"');
  commands.push('GLOBAL_THEME_DIR="$GLOBAL_REAPER/ColorThemes"');
  commands.push('GLOBAL_LEGACY_SCRIPT_DIR="$GLOBAL_REAPER/Scripts/VS Hook APP"');
  if (installExtension) {
    commands.push('rm -rf "$GLOBAL_LEGACY_SCRIPT_DIR"');
  }
  commands.push('mkdir -p "$GLOBAL_PLUGIN_DIR"');
  commands.push('mkdir -p "$GLOBAL_THEME_DIR"');
  // No macOS vale a mesma regra do Windows: somente copiar/substituir o nome
  // empacotado, sem limpar qualquer tema anterior nas pastas do REAPER.
  for (const themeSource of themeSources) {
    const filename = path.basename(themeSource);
    const temporaryName = `.${filename}.tmp`;
    commands.push(`cp -f ${shellQuote(themeSource)} "$GLOBAL_THEME_DIR"/${shellQuote(temporaryName)}`);
    commands.push(`chmod 644 "$GLOBAL_THEME_DIR"/${shellQuote(temporaryName)}`);
    commands.push(`mv -f "$GLOBAL_THEME_DIR"/${shellQuote(temporaryName)} "$GLOBAL_THEME_DIR"/${shellQuote(filename)}`);
  }
  if (installExtension) {
    commands.push('rm -f "$GLOBAL_PLUGIN_DIR/reaper_vshook.dylib"');
  }
  if (vshookSource) {
    commands.push(`VSHOOK_SOURCE=${shellQuote(vshookSource)}`);
    commands.push('cp -f "$VSHOOK_SOURCE" "$GLOBAL_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp"');
    commands.push('chmod 755 "$GLOBAL_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp"');
    commands.push('mv -f "$GLOBAL_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp" "$GLOBAL_PLUGIN_DIR/reaper_VSHookExt.dylib"');
  }
  if (hasCompanion) {
    commands.push(`COMPANION_SOURCE=${shellQuote(companionSource)}`);
    commands.push('GLOBAL_COMPANION_DIR="$GLOBAL_PLUGIN_DIR/VSHookTelepromptSettings"');
    commands.push('mkdir -p "$GLOBAL_COMPANION_DIR"');
    commands.push('rm -rf "$GLOBAL_COMPANION_DIR/VS Hook Teleprompt Settings.app"');
    commands.push('ditto "$COMPANION_SOURCE" "$GLOBAL_COMPANION_DIR/VS Hook Teleprompt Settings.app"');
  }
  if (installExtension) {
    commands.push('chmod 755 "$GLOBAL_PLUGIN_DIR/reaper_VSHookExt.dylib" 2>/dev/null || true');
  }

  commands.push('for USER_HOME in /Users/*; do');
  commands.push('  [ -d "$USER_HOME" ] || continue');
  commands.push('  USER_NAME=$(basename "$USER_HOME")');
  commands.push('  [ "$USER_NAME" = "Shared" ] && continue');
  commands.push('  USER_REAPER="$USER_HOME/Library/Application Support/REAPER"');
  commands.push('  USER_PLUGIN_DIR="$USER_REAPER/UserPlugins"');
  commands.push('  USER_THEME_DIR="$USER_REAPER/ColorThemes"');
  commands.push('  USER_LEGACY_SCRIPT_DIR="$USER_REAPER/Scripts/VS Hook APP"');
  if (installExtension) {
    commands.push('  rm -rf "$USER_LEGACY_SCRIPT_DIR"');
  }
  commands.push('  mkdir -p "$USER_PLUGIN_DIR"');
  commands.push('  mkdir -p "$USER_THEME_DIR"');
  for (const themeSource of themeSources) {
    const filename = path.basename(themeSource);
    const temporaryName = `.${filename}.tmp`;
    commands.push(`  cp -f ${shellQuote(themeSource)} "$USER_THEME_DIR"/${shellQuote(temporaryName)}`);
    commands.push(`  chmod 644 "$USER_THEME_DIR"/${shellQuote(temporaryName)}`);
    commands.push(`  mv -f "$USER_THEME_DIR"/${shellQuote(temporaryName)} "$USER_THEME_DIR"/${shellQuote(filename)}`);
    commands.push(`  chown "$USER_NAME":staff "$USER_THEME_DIR"/${shellQuote(filename)} 2>/dev/null || true`);
  }
  if (installExtension) {
    commands.push('  rm -f "$USER_PLUGIN_DIR/reaper_vshook.dylib"');
  }
  if (vshookSource) {
    commands.push('  cp -f "$VSHOOK_SOURCE" "$USER_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp"');
    commands.push('  chmod 755 "$USER_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp"');
    commands.push('  mv -f "$USER_PLUGIN_DIR/.reaper_VSHookExt.dylib.tmp" "$USER_PLUGIN_DIR/reaper_VSHookExt.dylib"');
    commands.push('  chown "$USER_NAME":staff "$USER_PLUGIN_DIR/reaper_VSHookExt.dylib" 2>/dev/null || true');
  }
  if (hasCompanion) {
    commands.push('  USER_COMPANION_DIR="$USER_PLUGIN_DIR/VSHookTelepromptSettings"');
    commands.push('  mkdir -p "$USER_COMPANION_DIR"');
    commands.push('  rm -rf "$USER_COMPANION_DIR/VS Hook Teleprompt Settings.app"');
    commands.push('  ditto "$COMPANION_SOURCE" "$USER_COMPANION_DIR/VS Hook Teleprompt Settings.app"');
    commands.push('  chown -R "$USER_NAME":staff "$USER_COMPANION_DIR" 2>/dev/null || true');
  }
  if (installExtension) {
    commands.push('  chmod 755 "$USER_PLUGIN_DIR/reaper_VSHookExt.dylib" 2>/dev/null || true');
  }
  commands.push('done');

  const script = commands.join('\n');
  execFileSync('osascript', [
    '-e',
    `do shell script ${JSON.stringify(script)} with administrator privileges`
  ], { stdio: 'ignore' });
}

function getBundledReaperAssetsIdentity() {
  const companionRoot = getBundledVshookCompanionDir();
  const candidates = process.platform === 'darwin'
    ? [
        path.join(companionRoot, 'VS Hook Teleprompt Settings.app',
          'Contents', 'MacOS', 'VS Hook Teleprompt Settings'),
        path.join(companionRoot, 'VS Hook Teleprompt Settings.app',
          'Contents', 'Resources', 'app.asar')
      ]
    : [
        path.join(companionRoot, 'VS Hook Teleprompt Settings.exe'),
        path.join(companionRoot, 'resources', 'app.asar')
      ];
  candidates.push(...getBundledVshookThemePaths());
  const hash = crypto.createHash('sha256');
  let fileCount = 0;
  for (const filename of candidates) {
    if (!physicalFs.existsSync(filename) ||
        !physicalFs.statSync(filename).isFile()) continue;
    const integrity = getFileIntegrity(filename);
    hash.update(path.basename(filename));
    hash.update(String(integrity.size));
    hash.update(integrity.sha256);
    fileCount += 1;
  }
  if (fileCount < 3) {
    throw new Error(
      'Os arquivos do Teleprompt Settings ou do tema não vieram completos nesta Hook Center.'
    );
  }
  return hash.digest('hex');
}

function hasInstalledVshookExtension() {
  if (process.platform === 'win32') {
    return getWindowsReaperUserPluginsDirs().some((directory) =>
      physicalFs.existsSync(path.join(directory, 'reaper_VSHookExt.dll'))
    );
  }
  if (process.platform === 'darwin') {
    const candidates = [
      '/Library/Application Support/REAPER/UserPlugins/reaper_VSHookExt.dylib',
      path.join(os.homedir(), 'Library', 'Application Support', 'REAPER',
        'UserPlugins', 'reaper_VSHookExt.dylib')
    ];
    return candidates.some((filename) => physicalFs.existsSync(filename));
  }
  return false;
}

function markBundledReaperAssetsInstalled() {
  store.set('bundledReaperAssetsIdentity', getBundledReaperAssetsIdentity());
}

async function syncBundledReaperAssetsOnStartup() {
  if (!hasInstalledVshookExtension()) return { ok: true, skipped: 'extension-not-installed' };
  const identity = getBundledReaperAssetsIdentity();
  if (store.get('bundledReaperAssetsIdentity') === identity) {
    return { ok: true, skipped: 'already-current' };
  }
  if ((process.platform === 'win32' && isWindowsReaperRunning()) ||
      (process.platform === 'darwin' && isMacReaperRunning())) {
    return { ok: true, skipped: 'reaper-running' };
  }
  if (process.platform === 'win32') {
    installWindowsVshookCompanion();
    installWindowsVshookTheme();
  } else if (process.platform === 'darwin') {
    installMacPayload(null, { installExtension: false });
  } else {
    return { ok: true, skipped: 'unsupported-platform' };
  }
  store.set('bundledReaperAssetsIdentity', identity);
  return { ok: true, installed: true };
}

async function completePendingPostCenterUpdateInstall() {
  const pending = store.get('pendingPostCenterUpdateInstall');
  if (!pending?.files) return { ok: true, skipped: 'none' };
  const targetVersion = String(pending.targetCenterVersion || '');
  const files = pending.files || {};
  if (process.platform === 'win32') {
    if (!files.vshookDll || !fs.existsSync(files.vshookDll)) {
      throw new Error('A DLL guardada para concluir a atualização não foi encontrada.');
    }
    validateExtensionBinaryFile(files.vshookDll, 'vshookDll');
    installWindowsPayload(files);
  } else if (process.platform === 'darwin') {
    if (!files.vshookDylib || !fs.existsSync(files.vshookDylib)) {
      throw new Error('A dylib guardada para concluir a atualização não foi encontrada.');
    }
    validateExtensionBinaryFile(files.vshookDylib, 'vshookDylib');
    installMacPayload(files);
  } else {
    return { ok: true, skipped: 'unsupported-platform' };
  }

  const update = normalizeUpdate(pending.update) || pending.update || {};
  const manifest = pending.manifest || {};
  await persistActiveLocalLicenseFromStore({
    active: true,
    source: 'post-center-update-install'
  }).catch(() => false);
  markUpdatePackageInstalled(update, manifest);
  store.set('currentVersion', update.version || targetVersion || store.get('currentVersion'));
  store.set('installedManifest', {
    platform: getPlatformKey(),
    updateId: getPlatformUpdateId(update),
    globalUpdateId: update.updateId || '',
    version: update.version || targetVersion || '',
    files: Object.fromEntries(
      Object.entries(manifest.files || {})
        .filter(([key]) => key !== 'installer')
    ),
    installedAt: new Date().toISOString()
  });
  store.set('updateAvailable', false);
  store.set('pendingPostCenterUpdateInstall', null);
  markBundledReaperAssetsInstalled();
  return { ok: true, installed: true };
}

async function installDownloadedUpdate() {
  const downloaded = store.get('downloadedFiles');
  // Quando o download trouxe extensao + Hook Center, a referencia duravel do
  // Store e a fonte da instalacao. Nao consulte novamente `testClientUpdate`:
  // ela pode mudar/desaparecer entre os cliques Baixar e Instalar.
  if (downloaded?.completePackage && downloaded?.cacheKey) {
    return installCachedUpdatePackage(downloaded.update || null, {
      source: 'computer',
      cacheKey: downloaded.cacheKey
    });
  }
  const files = downloaded?.files || {};

  if (process.platform === 'win32') {
    if (!files.vshookDll || !fs.existsSync(files.vshookDll)) {
      throw new Error('A DLL do VS Hook não foi encontrada no pacote.');
    }
    validateExtensionBinaryFile(files.vshookDll, 'vshookDll');
    installWindowsPayload(files);
  } else if (process.platform === 'darwin') {
    if (!files.vshookDylib || !fs.existsSync(files.vshookDylib)) {
      throw new Error('A dylib do VS Hook não foi encontrada no pacote.');
    }
    validateExtensionBinaryFile(files.vshookDylib, 'vshookDylib');
    installMacPayload(files);
  } else {
    throw new Error('Sistema operacional não suportado.');
  }
  markBundledReaperAssetsInstalled();

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
ipcMain.handle('direct-cable-get-state', () => getDirectCableState());
ipcMain.handle('direct-cable-configure', (_event, payload) => configureDirectCable(payload || {}));
ipcMain.handle('direct-cable-restore-dhcp', (_event, payload) => restoreDirectCableDhcp(payload || {}));
ipcMain.handle('hook-midi-get-state', () => getHookMidiState());
ipcMain.handle('hook-midi-create', (_event, payload) => createHookMidiPort(payload || {}));
ipcMain.handle('hook-midi-remove', (_event, payload) => removeHookMidiPort(payload || {}));
ipcMain.handle('hook-midi-open-components', () => installHookMidiComponents());

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
ipcMain.handle('select-bridge-network', (_event, payload) => selectBridgeNetwork(payload || {}));
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
ipcMain.handle('chat-get-state', (_event, payload) => getChatState(payload?.afterId));
ipcMain.handle('chat-send-message', (_event, payload) => sendChatMessage(payload || {}));
ipcMain.handle('chat-set-pinned-message', (_event, payload) => setChatPinnedMessage(payload || {}));
ipcMain.handle('chat-delete-message', (_event, payload) => deleteChatMessage(payload || {}));
ipcMain.handle('chat-update-profile', (_event, payload) => updateChatProfile(payload || {}));
ipcMain.handle('chat-upload-avatar', (_event, payload) => uploadChatAvatar(payload || {}));
ipcMain.handle('get-hook-tutorials', () => getHookTutorials());
ipcMain.handle('chat-admin-update-settings', (_event, payload) => updateChatAdminSettings(payload || {}));
ipcMain.handle('chat-admin-clear', (_event, payload) => clearChatAsAdmin(payload || {}));
ipcMain.handle('chat-admin-unlock', (_event, payload) => unlockChatAdmin(payload || {}));
ipcMain.handle('chat-admin-save-release-notes', (_event, payload) => saveChatReleaseNotes(payload || {}));
ipcMain.handle('chat-admin-publish-update', (_event, payload) => publishUpdateFromHookCenter(payload || {}));
ipcMain.handle('open-external', (_event, url) => shell.openExternal(url));
ipcMain.handle('open-support', () => openSupport());
ipcMain.handle('get-previous-updates', () => getPreviousUpdates());
ipcMain.handle('download-update', (_event, payload) => downloadLatestUpdate(payload?.update || null));
ipcMain.handle('install-update', () => installDownloadedUpdate());
ipcMain.handle('cache-update-package', (_event, payload) => cacheUpdatePackage(payload?.update || null, { requireInstaller: true }));
ipcMain.handle('remove-cached-update-package', (_event, payload) => removeCachedUpdatePackage(payload?.update || payload || null));
ipcMain.handle('install-cached-update-package', (_event, payload) => {
  const requestedSource = String(payload?.source || 'auto').trim().toLowerCase();
  const source = ['internet', 'computer'].includes(requestedSource)
    ? requestedSource
    : 'auto';
  const downloaded = store.get('downloadedFiles') || {};
  const cacheKey = String(
    payload?.cacheKey || (!payload?.update ? downloaded.cacheKey : '') || ''
  ).trim();
  return installCachedUpdatePackage(payload?.update || null, { source, cacheKey });
});
ipcMain.handle('get-lyrics-settings', (_event, slot) =>
  slot ? getLyricsSettings(slot) : getLyricsAllSettings());
ipcMain.handle('save-lyrics-settings', (_event, payload) =>
  saveLyricsSettings(payload || {}, payload?.slot));
ipcMain.handle('get-technical-notice-settings', () =>
  getTechnicalNoticeSettings());
ipcMain.handle('save-technical-notice-settings', (_event, payload) =>
  saveTechnicalNoticeSettings(payload || {}));
ipcMain.handle('send-recados-notice', (_event, payload) =>
  sendRecadosNotice(payload || {}));
ipcMain.handle('cancel-recados-notice', () =>
  cancelRecadosNotice());
ipcMain.handle('set-recados-notice-pinned', (_event, payload) =>
  setRecadosNoticePinned(payload || {}));
ipcMain.handle('export-lyrics-backup', () => exportLyricsBackup());
ipcMain.handle('import-lyrics-backup', () => importLyricsBackup());
ipcMain.handle('open-lyrics-window', (_event, slot) =>
  createLyricsWindow(slot));
ipcMain.handle('close-lyrics-window', (_event, slot) => {
  const id = Number(slot) === 2 ? 2 : 1;
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) {
    lyricsWindows.delete(id);
    try { win.close(); } catch (_) {}
  }
  return {
    ok: true,
    slot: id,
    lyricsWindows: broadcastLyricsWindowsState()
  };
});
ipcMain.handle('get-lyrics-state', (_event, slot) =>
  getLyricsState(slot));
ipcMain.handle('close-current-window', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win && !win.isDestroyed()) {
    for (const [slot, lyricsWin] of lyricsWindows.entries()) {
      if (lyricsWin !== win) continue;
      lyricsWindows.delete(slot);
      break;
    }
    try { win.close(); } catch (_) {}
  }
  return {
    ok: true,
    lyricsWindows: broadcastLyricsWindowsState()
  };
});
ipcMain.handle('toggle-current-window-fullscreen', (event) =>
  toggleLyricsWindowFullscreen(
    BrowserWindow.fromWebContents(event.sender)));
ipcMain.handle('get-current-window-bounds', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win || win.isDestroyed()) return { ok: false };
  return {
    ok: true,
    bounds: win.getBounds(),
    maximized:
      process.platform === 'darwin' &&
      isLyricsWindowMaximized(win)
  };
});
ipcMain.handle('prepare-current-window-drag', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win || win.isDestroyed() ||
      process.platform !== 'darwin' ||
      isHookCenterLegacyBuild()) {
    return { ok: false };
  }
  try {
    const result = restoreMaximizedLyricsWindowForDrag(
      win, screen.getCursorScreenPoint());
    return { ok: true, ...result };
  } catch (_) {
    return { ok: false };
  }
});

function finishLegacyWindowDrag(session) {
  const win = session?.win;
  if (!win || win.isDestroyed()) return;
  try {
    const cursor = screen.getCursorScreenPoint();
    const display = screen.getDisplayNearestPoint(cursor);
    const area = display?.workArea || display?.bounds;
    const bounds = win.getBounds();

    if (area) {
      // Garante que a janela não termine fora da área visível quando as telas
      // possuem origem, resolução ou escala diferentes.
      const maxX = area.x + Math.max(0, area.width - bounds.width);
      const maxY = area.y + Math.max(0, area.height - bounds.height);
      const x = Math.max(area.x, Math.min(maxX, bounds.x));
      const y = Math.max(area.y, Math.min(maxY, bounds.y));
      if (x !== bounds.x || y !== bounds.y) {
        win.setBounds({ ...bounds, x, y }, false);
      }
    }

    try { win.webContents.setBackgroundThrottling(false); } catch (_) {}
    try { win.webContents.invalidate(); } catch (_) {}
    try { win.show(); } catch (_) {}
    setTimeout(() => {
      if (win.isDestroyed()) return;
      try { win.webContents.invalidate(); } catch (_) {}
    }, 120);
  } catch (_) {}
}

ipcMain.handle('begin-current-window-cursor-drag', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win || win.isDestroyed() || process.platform !== 'darwin' || !isHookCenterLegacyBuild()) return { ok: false };
  try {
    const cursor = screen.getCursorScreenPoint();
    const display = screen.getDisplayNearestPoint(cursor);
    const [windowX, windowY] = win.getPosition();
    legacyWindowDragSessions.set(event.sender.id, {
      win,
      cursorX: cursor.x,
      cursorY: cursor.y,
      windowX,
      windowY,
      displayId: display?.id,
      maximized: isLyricsWindowMaximized(win)
    });
    return { ok: true };
  } catch (_) {
    legacyWindowDragSessions.delete(event.sender.id);
    return { ok: false };
  }
});

ipcMain.on('move-current-window-with-cursor', (event) => {
  const session = legacyWindowDragSessions.get(event.sender.id);
  if (!session || !session.win || session.win.isDestroyed()) return;
  try {
    const cursor = screen.getCursorScreenPoint();
    if (session.maximized) {
      const distanceX = cursor.x - session.cursorX;
      const distanceY = cursor.y - session.cursorY;
      // Não restaura no primeiro clique: só depois de um movimento real. Isso
      // preserva o duplo clique para maximizar/restaurar.
      if (Math.hypot(distanceX, distanceY) < 5) return;
      const restored = restoreMaximizedLyricsWindowForDrag(session.win, cursor);
      if (!restored.bounds) return;
      session.windowX = restored.bounds.x;
      session.windowY = restored.bounds.y;
      session.cursorX = cursor.x;
      session.cursorY = cursor.y;
      session.maximized = false;
      const restoredDisplay = screen.getDisplayNearestPoint(cursor);
      session.displayId = restoredDisplay?.id;
      try { session.win.webContents.invalidate(); } catch (_) {}
      return;
    }
    const x = Math.round(session.windowX + (cursor.x - session.cursorX));
    const y = Math.round(session.windowY + (cursor.y - session.cursorY));
    session.win.setPosition(x, y, false);
    const display = screen.getDisplayNearestPoint(cursor);
    if (display && display.id !== session.displayId) {
      session.displayId = display.id;
      // Avisa o Chromium que a NSWindow mudou de backing screen/DPI.
      try { session.win.webContents.invalidate(); } catch (_) {}
    }
  } catch (_) {}
});

ipcMain.on('end-current-window-cursor-drag', (event) => {
  const session = legacyWindowDragSessions.get(event.sender.id);
  legacyWindowDragSessions.delete(event.sender.id);
  finishLegacyWindowDrag(session);
});

ipcMain.on('move-current-window', (event, payload = {}) => {
  // A versão normal do macOS mantém o arraste manual original. A Legacy usa o
  // canal baseado no cursor em DIP e não deve entrar neste caminho.
  if (process.platform === 'darwin' && isHookCenterLegacyBuild()) return;
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
  const deviceFingerprint = await getDeviceFingerprint();
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
    body: JSON.stringify({ cpf, cnpj, document, email, machineId, deviceFingerprint, platform: process.platform, computerName: getStoredDeviceName() })
  });

  saveSignedLicenseToken(result.licenseToken, { required: true });
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

function prepareForAppQuit() {
  appIsQuitting = true;
  if (quitCleanupStarted) return;
  quitCleanupStarted = true;

  for (const win of lyricsWindows.values()) {
    try { if (win && !win.isDestroyed()) win.destroy(); } catch (_) {}
  }
  lyricsWindows.clear();
  stopBridgeServers();
  if (checkTimer) clearInterval(checkTimer);
  if (bridgeWatchTimer) clearInterval(bridgeWatchTimer);
  if (updateReminderTimer) clearInterval(updateReminderTimer);
  checkTimer = null;
  bridgeWatchTimer = null;
  updateReminderTimer = null;
}

app.whenReady().then(async () => {
  if (!gotSingleInstanceLock) return;

  cleanupLegacyWindowsVshookOnStartup();

  if (process.platform === 'darwin') {
    // O macOS avisa antes de desligar ou reiniciar. Marcar a saída aqui evita
    // que o handler da janela transforme o encerramento do sistema em "ocultar".
    powerMonitor.on('shutdown', () => {
      prepareForAppQuit();
      app.quit();
    });
  }

  app.setLoginItemSettings({ openAtLogin: true });
  store.set('autoStart', true);
  Menu.setApplicationMenu(null);
  if (!isValidWindow(mainWindow)) createWindow();
  if (!tray) createTray();
  await completePendingPostCenterUpdateInstall().catch((error) => {
    console.error('[Hook Center] Não concluiu a instalação após atualizar a central:',
      error?.message || error);
  });
  await syncBundledReaperAssetsOnStartup().catch((error) => {
    console.error('[Hook Center] Não sincronizou Teleprompt Settings e temas:',
      error?.message || error);
  });
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

app.on('before-quit', () => {
  prepareForAppQuit();
});
