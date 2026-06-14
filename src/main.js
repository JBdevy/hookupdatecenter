const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const Store = require('electron-store');
const { spawn, execFile, execFileSync } = require('child_process');

const store = new Store({
  defaults: {
    currentVersion: '1.0.0',
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
    autoStart: true
  }
});

let mainWindow = null;
let tray = null;
let checkTimer = null;

const BACKEND_URL = (process.env.BACKEND_URL || 'https://hookupdate7.up.railway.app').replace(/\/+$/, '');
const UPDATE_API_URL = `${BACKEND_URL}/api/latest`;
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
  app.setAppUserModelId('com.hookdeveloper.updatecenter');
}


function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1040,
    height: 720,
    minWidth: 920,
    minHeight: 620,
    show: false,
    backgroundColor: '#0b0b10',
    title: 'Hook Update Center',
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
  tray.setToolTip('Hook Update Center');
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

  const menu = Menu.buildFromTemplate([
    { label: 'Hook Update Center', enabled: false },
    { label: updateText, enabled: false },
    { label: licenseText, enabled: false },
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

  return {
    updateId: source.updateId || source.id || source.publishedAt || source.version || null,
    product: source.product || 'vs-hook',
    version: source.version || '',
    title: source.title || 'Atualização do VS Hook disponível',
    description: source.description || '',
    youtubeUrl: source.youtubeUrl || source.videoUrl || source.video || '',
    changelog: Array.isArray(source.changelog)
      ? source.changelog
      : String(source.description || '').split('\n').map((line) => line.trim()).filter(Boolean),
    publishedAt: source.publishedAt || source.createdAt || null,
    platforms: source.platforms || files.platforms || files._platforms || {},
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

function getAppState() {
  return {
    currentVersion: store.get('currentVersion'),
    lastCheck: store.get('lastCheck'),
    updateAvailable: store.get('updateAvailable'),
    latestUpdate: store.get('latestUpdate'),
    lastNotifiedUpdateId: store.get('lastNotifiedUpdateId'),
    downloadedFiles: store.get('downloadedFiles'),
    installedManifest: store.get('installedManifest'),
    license: store.get('license'),
    
    platform: process.platform,
    arch: process.arch,
    machineIdPath: getSharedMachineIdPath(),
    licensePath: getSharedLicensePath()
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

ipcMain.handle('check-updates', () => checkForUpdates(true));
ipcMain.handle('check-license-status', () => checkLicenseStatus(true));
ipcMain.handle('open-external', (_event, url) => shell.openExternal(url));
ipcMain.handle('open-support', () => openSupport());
ipcMain.handle('get-previous-updates', () => getPreviousUpdates());
ipcMain.handle('download-update', (_event, payload) => downloadLatestUpdate(payload?.update || null));
ipcMain.handle('install-update', () => installDownloadedUpdate());

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

  const license = store.get('license') || {};
  if (!license.machineId) {
    store.set('license', { ...license, machineId: await getMachineId() });
  }

  await checkForUpdates(false);
  await checkLicenseStatus(false);

  checkTimer = setInterval(async () => {
    await checkForUpdates(false);
    await checkLicenseStatus(false);
  }, CHECK_INTERVAL_MS);
});

app.on('window-all-closed', (event) => {
  event.preventDefault();
});

app.on('before-quit', () => {
  if (checkTimer) clearInterval(checkTimer);
});
