const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const Store = require('electron-store');
const { spawn, execFile, execFileSync } = require('child_process');
const { createBridgeServer, getLanIp, ensureJsonFile } = require('./bridge-server');

const store = new Store({
  defaults: {
    currentVersion: app.getVersion(),
    hookCenterLatest: null,
    hookCenterUpdateAvailable: false,
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
      lastStatusAt: null
    },
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
let bridgeServers = [];
let bridgeInfos = [];
let bridgeConfig = null;
let bridgeLastError = '';
let bridgeWatchTimer = null;
const lyricsWindows = new Map();

const BACKEND_URL = (process.env.BACKEND_URL || 'https://hookupdate7.up.railway.app').replace(/\/+$/, '');
const UPDATE_API_URL = `${BACKEND_URL}/api/latest?platform=${getPlatformKey()}`;
const HOOK_CENTER_API_URL = `${BACKEND_URL}/api/hookcenter/latest?platform=${getPlatformKey()}`;
const UPDATES_HISTORY_API_URL = `${BACKEND_URL}/api/updates?limit=50&platform=${getPlatformKey()}`;
const SUPPORT_API_URL = `${BACKEND_URL}/api/support`;
const CHECK_INTERVAL_MS = 60 * 60 * 1000;

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

  mainWindow.on('close', (event) => {
    if (!app.isQuiting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
}

function createTray() {
  const iconPath = path.join(__dirname, '..', 'assets', process.platform === 'darwin' ? 'trayTemplate.png' : 'tray.png');
  tray = new Tray(iconPath);
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
  if (!mainWindow) createWindow();
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

  execFileSync('osascript', [
    '-e',
    `do shell script ${JSON.stringify(command)} with administrator privileges`
  ], { stdio: 'ignore' });
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

function saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload }) {
  const licensePath = getSharedLicensePath();
  const data = {
    v: 1,
    product: LICENSE_PRODUCT,
    mid: normalizeMachineId(machineId),
    sig: normalizeLicenseKeyForFile(licenseKey),
    cpf: normalizeDocument(cpf),
    cnpj: normalizeDocument(cnpj),
    document: normalizeDocument(document || cpf || cnpj),
    email: normalizeEmail(email),
    ts: new Date().toISOString(),
    
    payload: payload || null
  };

  writeFileWithPrivilegeIfNeeded(licensePath, JSON.stringify(data));
  return licensePath;
}

function normalizeLicenseKeyForFile(value) {
  return String(value || '').trim().toUpperCase().replace(/\s+/g, '');
}

function removeLocalLicense() {
  const licensePath = getSharedLicensePath();
  removeFileWithPrivilegeIfNeeded(licensePath);

  for (const legacyPath of getLegacyLicensePaths()) {
    try { fs.rmSync(legacyPath, { force: true }); } catch (_) {}
  }

  return licensePath;
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

  return {
    updateId: platformMeta.updateId || source.updateId || source.id || source.publishedAt || source.version || null,
    product: source.product || 'vs-hook',
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
    const raw = await fetchJson(UPDATE_API_URL, { cache: 'no-store' });
    const update = normalizeUpdate(raw);

    const updateId = getPlatformUpdateId(update);
    const lastNotified = store.get('lastNotifiedUpdateId');
    const shouldNotify = !!updateId && updateId !== lastNotified && hasInstallableFiles(update);

    store.set('latestUpdate', update);
    store.set('updateAvailable', shouldNotify);
    rebuildTrayMenu();

    if (mainWindow) {
      mainWindow.webContents.send('update-status', getAppState());
    }

    if (shouldNotify && !manual) {
      notifyUpdate(update);
      store.set('lastNotifiedUpdateId', updateId);
    }

    if (manual) showMainWindow();

    return { ok: true, hasUpdate: shouldNotify, update, state: getAppState() };
  } catch (error) {
    if (mainWindow) mainWindow.webContents.send('update-error', error.message);
    return { ok: false, error: error.message, state: getAppState() };
  }
}


function normalizeHookCenterUpdate(raw) {
  if (!raw || raw.published === false) return null;
  const downloadUrl = ensureAbsoluteUrl(raw.downloadUrl || (getPlatformKey() === 'macos' ? raw.macosUrl : raw.windowsUrl));
  return {
    product: 'hook-center',
    updateId: raw.updateId || raw.version || null,
    version: raw.version || '',
    title: raw.title || 'Nova versão do Hook Center disponível',
    notes: raw.notes || raw.description || '',
    downloadUrl,
    windowsUrl: ensureAbsoluteUrl(raw.windowsUrl),
    macosUrl: ensureAbsoluteUrl(raw.macosUrl),
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
    if (mainWindow) mainWindow.webContents.send('update-status', getAppState());
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
  const baseName = process.platform === 'darwin' ? `Hook-Center-${update.version}-macOS${ext}` : `Hook-Center-${update.version}-Windows${ext}`;
  const dest = path.join(app.getPath('downloads'), baseName);
  await downloadFile(update.downloadUrl, dest, (progress) => {
    if (mainWindow) mainWindow.webContents.send('download-progress', progress);
  });

  if (process.platform === 'win32') {
    spawn(dest, [], { detached: true, stdio: 'ignore', windowsHide: false }).unref();
    app.isQuiting = true;
    app.quit();
    return { ok: true, action: 'installer-started', path: dest };
  }

  await shell.openPath(dest);
  shell.showItemInFolder(dest);
  return { ok: true, action: 'dmg-opened', path: dest };
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
      body: JSON.stringify({ cpf, cnpj, document, email, machineId, platform: process.platform })
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
      lastStatusAt: new Date().toISOString()
    };

    store.set('license', nextLicense);

    if (!active) {
      removeLocalLicense();
      notifyLicense('Este computador foi desvinculado da licença do VS Hook.');
    }

    rebuildTrayMenu();
    if (mainWindow) mainWindow.webContents.send('license-status', getAppState());

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
    projectName: 'Projeto sem nome',
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

function getBridgeEmptyAppDir() {
  // No app empacotado, __dirname fica dentro do app.asar.
  // app.asar é arquivo, não pasta gravável. Por isso usamos userData.
  if (app.isPackaged) {
    return path.join(app.getPath('userData'), 'bridge-empty-app');
  }
  return path.join(__dirname, 'bridge-empty-app');
}

function buildBridgeServers(config) {
  const sharedDir = resolveBridgeScriptsDir(config);
  const emptyAppDir = getBridgeEmptyAppDir();
  fs.mkdirSync(emptyAppDir, { recursive: true });
  const emptyIndex = path.join(emptyAppDir, 'index.html');
  if (!fs.existsSync(emptyIndex)) {
    fs.writeFileSync(emptyIndex, '<!doctype html><meta charset="utf-8"><title>VS Hook</title><body>VS Hook Bridge</body>', 'utf8');
  }

  return [
    createBridgeServer({
      appName: 'Diretor',
      host: '0.0.0.0',
      port: Number(config.directorPort) || 47831,
      publicBridgeHost: getLanIp(),
      appDir: emptyAppDir,
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
      appDir: emptyAppDir,
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
    if (mainWindow) mainWindow.webContents.send('bridge-status', getBridgeState());
    return getBridgeState();
  } catch (error) {
    bridgeLastError = error?.message || String(error || 'Erro desconhecido ao iniciar a conexão via app.');
    for (const server of nextServers) {
      try { await server.stop(); } catch (_) {}
    }
    bridgeServers = [];
    bridgeInfos = [];
    rebuildTrayMenu();
    if (mainWindow) mainWindow.webContents.send('bridge-status', getBridgeState());
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
  return {
    running: bridgeServers.length > 0,
    lanIp,
    scriptsDir: resolveBridgeScriptsDir(config),
    directorPort: Number(config.directorPort) || 47831,
    musiciansPort: Number(config.musiciansPort) || 47832,
    directorUrl: `http://${lanIp}:${Number(config.directorPort) || 47831}`,
    musiciansUrl: `http://${lanIp}:${Number(config.musiciansPort) || 47832}`,
    infos: bridgeInfos,
    error: bridgeLastError
  };
}


function getLyricsDefaults() {
  return {
    textColor: '#ffea00',
    clockColor: '#00ff55',
    fontFamily: 'Arial',
    clockEnabled: true
  };
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

function saveLyricsSettings(settings = {}, slot = 1) {
  const id = normalizeLyricsSlot(slot || settings.slot);
  const allowedFonts = ['Arial', 'Segoe UI', 'Verdana', 'Tahoma', 'Georgia', 'Trebuchet MS', 'Impact'];
  const all = getLyricsAllSettings();
  const next = { ...all[id] };
  if (typeof settings.textColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.textColor)) next.textColor = settings.textColor;
  if (typeof settings.clockColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(settings.clockColor)) next.clockColor = settings.clockColor;
  if (allowedFonts.includes(settings.fontFamily)) next.fontFamily = settings.fontFamily;
  if (typeof settings.clockEnabled === 'boolean') next.clockEnabled = settings.clockEnabled;
  all[id] = next;
  store.set('lyrics', all);
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) win.webContents.send('lyrics-settings-updated', { slot: id, settings: next });
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('lyrics-settings-updated', getLyricsAllSettings());
  return next;
}

function getLyricsStatePath() {
  const config = bridgeConfig || readBridgeConfig();
  const sharedDir = resolveBridgeScriptsDir(config);
  return path.join(sharedDir, 'vshook_lyrics_state.json');
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

function getLyricsState() {
  const data = readJsonFileSafe(getLyricsStatePath(), {});
  return {
    text: String(data.text || data.lyrics || ''),
    song: String(data.song || data.currentSong || ''),
    part: String(data.part || data.currentPart || ''),
    timerRunning: Boolean(data.timerRunning),
    timerStartedAt: Number(data.timerStartedAt || 0),
    timerAccumulatedSec: Number(data.timerAccumulatedSec || 0),
    playing: Boolean(data.playing),
    updatedAt: data.updatedAt || null
  };
}

function createLyricsWindow(slot = 1) {
  const id = Number(slot) === 2 ? 2 : 1;
  const existing = lyricsWindows.get(id);
  if (existing && !existing.isDestroyed()) {
    existing.show();
    existing.focus();
    return { ok: true, alreadyOpen: true, slot: id };
  }

  const win = new BrowserWindow({
    width: 980,
    height: 560,
    minWidth: 640,
    minHeight: 360,
    backgroundColor: '#000000',
    title: 'Hook Lyrics',
    icon: getAppIconPath(),
    frame: false,
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  lyricsWindows.set(id, win);
  win.loadFile(path.join(__dirname, 'lyrics.html'), { query: { slot: String(id) } });
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => lyricsWindows.delete(id));
  return { ok: true, slot: id };
}

function getLyricsWindowsState() {
  return {
    oneOpen: !!(lyricsWindows.get(1) && !lyricsWindows.get(1).isDestroyed()),
    twoOpen: !!(lyricsWindows.get(2) && !lyricsWindows.get(2).isDestroyed())
  };
}

function getAppState() {
  return {
    currentVersion: app.getVersion(),
    lastCheck: store.get('lastCheck'),
    updateAvailable: store.get('updateAvailable'),
    latestUpdate: store.get('latestUpdate'),
    hookCenterLatest: store.get('hookCenterLatest'),
    hookCenterUpdateAvailable: store.get('hookCenterUpdateAvailable'),
    lastNotifiedUpdateId: store.get('lastNotifiedUpdateId'),
    downloadedFiles: store.get('downloadedFiles'),
    installedManifest: store.get('installedManifest'),
    license: store.get('license'),
    
    platform: process.platform,
    arch: process.arch,
    machineIdPath: getSharedMachineIdPath(),
    licensePath: getSharedLicensePath(),
    bridge: getBridgeState(),
    lyrics: getLyricsSettings(),
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
      { key: 'hookLyricsLua', url: ensureAbsoluteUrl(files.hookLyricsLua || files.lyricsLua), filename: 'Hook Lyrics.lua' },
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
      { key: 'hookLyricsLua', url: ensureAbsoluteUrl(files.hookLyricsLua || files.lyricsLua), filename: 'Hook Lyrics.lua' },
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

  if (process.platform === 'darwin') {
    const hasJsApi = entries.some((entry) => entry.key === 'jsApiDylib');
    if (!hasJsApi) {
      throw new Error(process.arch === 'arm64'
        ? 'Arquivo macOS Apple Silicon não disponível nesta atualização.'
        : 'Arquivo macOS Intel não disponível nesta atualização.');
    }
  }

  const downloadDir = path.join(app.getPath('userData'), 'downloads', update.updateId || update.version || 'latest');
  const output = {};

  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i];
    const dest = path.join(downloadDir, entry.filename);
    await downloadFile(entry.url, dest, (fileProgress) => {
      const totalProgress = Math.round(((i * 100) + fileProgress) / entries.length);
      if (mainWindow) mainWindow.webContents.send('download-progress', totalProgress);
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
      files: Object.fromEntries(entries.map((entry) => [entry.key, { url: entry.url, filename: entry.filename }]))
    }
  });

  if (mainWindow) mainWindow.webContents.send('download-progress', 100);
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
  const lyricsLuaFileName = 'Hook Lyrics.lua';

  copyFileEnsured(files.lua, path.join(getWindowsPublicVsHookDir(), luaFileName));
  copyFileWithWindowsAdminFallback(files.lua, path.join(getWindowsLegacyVsHookDir(), luaFileName));

  copyFileEnsured(files.hookLyricsLua, path.join(getWindowsPublicVsHookDir(), lyricsLuaFileName));
  copyFileWithWindowsAdminFallback(files.hookLyricsLua, path.join(getWindowsLegacyVsHookDir(), lyricsLuaFileName));

  copyFileEnsured(files.vshookDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_vshook.dll'));
  copyFileEnsured(files.jsApiDll, path.join(getWindowsReaperUserPluginsDir(), 'reaper_js_ReaScriptAPI64.dll'));
}

function installMacPayload(files) {
  const commands = [];
  const luaSource = files.lua;
  const hookLyricsLuaSource = files.hookLyricsLua;
  const vshookSource = files.vshookDylib;
  const jsApiSource = files.jsApiDylib;

  commands.push('set -e');
  commands.push('GLOBAL_REAPER="/Library/Application Support/REAPER"');
  commands.push('GLOBAL_SCRIPT_DIR="$GLOBAL_REAPER/Scripts/VS Hook APP"');
  commands.push('GLOBAL_PLUGIN_DIR="$GLOBAL_REAPER/UserPlugins"');
  commands.push('mkdir -p "$GLOBAL_SCRIPT_DIR" "$GLOBAL_PLUGIN_DIR"');

  if (luaSource) commands.push(`cp -f ${shellQuote(luaSource)} "$GLOBAL_SCRIPT_DIR/VS Hook.lua"`);
  if (hookLyricsLuaSource) commands.push(`cp -f ${shellQuote(hookLyricsLuaSource)} "$GLOBAL_SCRIPT_DIR/Hook Lyrics.lua"`);
  if (vshookSource) commands.push(`cp -f ${shellQuote(vshookSource)} "$GLOBAL_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`cp -f ${shellQuote(jsApiSource)} "$GLOBAL_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('chmod 644 "$GLOBAL_SCRIPT_DIR/VS Hook.lua" 2>/dev/null || true');
  commands.push('chmod 644 "$GLOBAL_SCRIPT_DIR/Hook Lyrics.lua" 2>/dev/null || true');
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
  if (hookLyricsLuaSource) commands.push(`  cp -f ${shellQuote(hookLyricsLuaSource)} "$USER_SCRIPT_DIR/Hook Lyrics.lua"`);
  if (vshookSource) commands.push(`  cp -f ${shellQuote(vshookSource)} "$USER_PLUGIN_DIR/reaper_vshook.dylib"`);
  if (jsApiSource) commands.push(`  cp -f ${shellQuote(jsApiSource)} "$USER_PLUGIN_DIR/reaper_js_ReaScriptAPI.dylib"`);
  commands.push('  chown -R "$USER_NAME":staff "$USER_SCRIPT_DIR" "$USER_PLUGIN_DIR" 2>/dev/null || true');
  commands.push('  chmod 644 "$USER_SCRIPT_DIR/VS Hook.lua" 2>/dev/null || true');
  commands.push('  chmod 644 "$USER_SCRIPT_DIR/Hook Lyrics.lua" 2>/dev/null || true');
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

  if (downloaded?.manifest) {
    const previous = store.get('installedManifest') || {};
    const samePlatform = previous.platform === downloaded.manifest.platform;
    store.set('installedManifest', {
      platform: downloaded.manifest.platform,
      updateId: downloaded.manifest.updateId,
      files: { ...(samePlatform ? (previous.files || {}) : {}), ...(downloaded.manifest.files || {}) },
      installedAt: new Date().toISOString()
    });
  }

  if (downloaded?.version) {
    store.set('currentVersion', downloaded.version);
    store.set('lastNotifiedUpdateId', downloaded.updateId || downloaded.globalUpdateId || downloaded.version);
    store.set('updateAvailable', false);
    rebuildTrayMenu();
  }

  return { ok: true, installedVersion: downloaded?.version || store.get('currentVersion') };
}


function normalizeSupportUrl(data) {
  const raw =
    data?.whatsappUrl ||
    data?.supportUrl ||
    data?.url ||
    data?.whatsapp ||
    data?.phone ||
    data?.number ||
    '';

  const value = String(raw || '').trim();
  if (!value) return null;
  if (/^https?:\/\//i.test(value)) return value;

  const digits = value.replace(/\D+/g, '');
  if (!digits) return null;
  return `https://wa.me/${digits}`;
}

async function openSupport() {
  const data = await fetchJson(SUPPORT_API_URL, { cache: 'no-store' });
  const supportUrl = normalizeSupportUrl(data);

  if (!supportUrl) {
    throw new Error('SUPPORT_UNAVAILABLE');
  }

  await shell.openExternal(supportUrl);
  return { ok: true, url: supportUrl };
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
ipcMain.handle('check-license-status', () => checkLicenseStatus(true));
ipcMain.handle('open-external', (_event, url) => shell.openExternal(url));
ipcMain.handle('open-support', () => openSupport());
ipcMain.handle('get-previous-updates', () => getPreviousUpdates());
ipcMain.handle('download-update', (_event, payload) => downloadLatestUpdate(payload?.update || null));
ipcMain.handle('install-update', () => installDownloadedUpdate());
ipcMain.handle('get-lyrics-settings', (_event, slot) => slot ? getLyricsSettings(slot) : getLyricsAllSettings());
ipcMain.handle('save-lyrics-settings', (_event, payload) => saveLyricsSettings(payload || {}, payload?.slot));
ipcMain.handle('open-lyrics-window', (_event, slot) => createLyricsWindow(slot));
ipcMain.handle('close-lyrics-window', (_event, slot) => {
  const id = Number(slot) === 2 ? 2 : 1;
  const win = lyricsWindows.get(id);
  if (win && !win.isDestroyed()) win.close();
  return { ok: true, slot: id };
});
ipcMain.handle('get-lyrics-state', () => getLyricsState());
ipcMain.handle('close-current-window', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win) win.close();
  return { ok: true };
});

ipcMain.handle('activate-license', async (_event, payload) => {
  const docParts = splitDocument(payload?.cpf || payload?.document || payload?.cnpj);
  const cpf = docParts.cpf;
  const cnpj = docParts.cnpj;
  const document = docParts.document;
  const email = normalizeEmail(payload?.email);
  const machineId = await getMachineId();

  if (document && document.length !== 11 && document.length !== 14) {
    throw new Error('Digite um CPF ou CNPJ válido.');
  }
  if (!email || !email.includes('@')) {
    throw new Error('Digite o e-mail usado na compra.');
  }

  const result = await fetchJson(`${BACKEND_URL}/api/license/activate`, {
    method: 'POST',
    body: JSON.stringify({ cpf, cnpj, document, email, machineId, platform: process.platform })
  });

  const licenseKey = result.licenseKey || result.license || generateExpectedLicense(machineId);
  saveLocalLicense({ cpf, cnpj, document, email, machineId, licenseKey, payload: result });

  const nextLicense = {
    cpf,
    cnpj,
    document,
    email,
    machineId,
    active: true,
    devicesUsed: result.devicesUsed ?? result.usedDevices ?? 1,
    maxDevices: result.maxDevices ?? 2,
    lastStatusAt: new Date().toISOString()
  };

  store.set('license', nextLicense);
  rebuildTrayMenu();

  if (mainWindow) mainWindow.webContents.send('license-status', getAppState());

  return { ok: true, license: nextLicense, result, state: getAppState() };
});

app.whenReady().then(async () => {
  app.setLoginItemSettings({ openAtLogin: true });
  store.set('autoStart', true);
  Menu.setApplicationMenu(null);
  createWindow();
  createTray();
  await ensureBridgeServersRunning().catch((error) => {
    console.error('[Hook Center] Conexão via app não iniciou:', error?.message || error);
  });

  const license = store.get('license') || {};
  if (!license.machineId) {
    store.set('license', { ...license, machineId: await getMachineId() });
  }

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
