'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { createUpdateOperationGuard } = require('../src/update-operation-guard');
const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
function extract(name) {
  const match = source.match(new RegExp('^(?:async )?function ' + name + '\\([\\s\\S]*?^}', 'm'));
  assert(match, name);
  return match[0];
}
const functions = ['getWindowsReaperUserPluginsDir', 'getWindowsReaperUserPluginsDirs',
  'hasCompleteWindowsFfmpegRoot', 'hasInstalledFfmpegRuntime', 'ensureWindowsFfmpegRuntime',
  'installWindowsFfmpegRuntime', 'removeLegacyWindowsVshookExtensions',
  'validateExtensionBinaryFile', 'copyFileEnsured', 'installWindowsPayload',
  'hasInstalledVshookExtension', 'pendingCenterInstallerWasCompleted',
  'completePendingPostCenterUpdateInstall', 'schedulePendingExtensionInstall'];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-windows-install-'));
const appData = path.join(root, 'Users', 'current', 'AppData', 'Roaming');
const plugins = path.join(appData, 'REAPER', 'UserPlugins');
const destination = path.join(plugins, 'reaper_VSHookExt.dll');
const dll = path.join(root, 'download.dll');
const binary = Buffer.alloc(8192, 42); binary.write('MZ'); fs.writeFileSync(dll, binary);
let reaper = false, failRename = false, installs = 0, receipt = Date.now(), answer = 1;
const pending = { files: { vshookDll: dll }, targetCenterVersion: '1.0.2',
  queuedAt: new Date(receipt - 1000).toISOString(), previousReceiptMtimeMs: receipt - 2000,
  update: { version: '1.0.2' }, manifest: { files: { vshookDll: {} } } };
const values = new Map([['pendingPostCenterUpdateInstall', pending]]);
const timers = [], notices = [];
const io = new Proxy(fs, { get(target, prop) {
  if (prop === 'renameSync') return (from, to) => {
    if (failRename && to === destination && from.includes('.tmp-')) throw new Error('EACCES locked DLL');
    return fs.renameSync(from, to);
  };
  if (prop === 'rmSync') return (file, options) => {
    if (String(file).includes('other-user') || String(file).endsWith('/VLC')) throw new Error('EACCES');
    return fs.rmSync(file, options);
  };
  return target[prop];
} });
const ctx = vm.createContext({ fs: io, physicalFs: io, path, os, Buffer, Date,
  process: { platform: 'win32', env: { APPDATA: appData }, pid: process.pid },
  console: { warn() {}, error() {} }, fileIntegrityCache: new Map(),
  getFileIntegrity: file => ({ size: fs.statSync(file).size,
    sha256: crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') }),
  isWindowsReaperRunning: () => reaper,
  getBundledFfmpegRuntimeArchive: () => { throw new Error('ZIP missing'); },
  validateFfmpegRuntimeArchive: () => { throw new Error('ZIP missing'); },
  removeWindowsPublicVsHookDir: () => { throw new Error('EACCES public cleanup'); },
  installWindowsVshookCompanion() {}, installWindowsVshookTheme() {},
  store: { get: key => values.get(key), set: (key, value) => values.set(key, value) },
  getCenterInstallReceiptMtimeMs: () => receipt,
  app: { getVersion: () => '1.0.2' }, compareVersions: (a,b) => a.localeCompare(b),
  normalizeUpdate: x => x, getPlatformKey: () => 'windows', getPlatformUpdateId: () => 'test',
  persistActiveLocalLicenseFromStore: async () => true,
  markUpdatePackageInstalled: () => { installs++; }, markBundledReaperAssetsInstalled() {},
  runUpdateOperation: createUpdateOperationGuard(), appIsQuitting: false,
  pendingExtensionInstallTimer: null, pendingExtensionInstallNoticeShown: false,
  setTimeout: callback => { timers.push(callback); return callback; },
  isValidWindow: () => false, mainWindow: null,
  dialog: { showMessageBox: async options => { notices.push(options); return { response: answer }; } }
});
vm.runInContext(functions.map(extract).join('\n'), ctx);
async function tick() { const callback = timers.shift(); assert(callback, 'retry scheduled'); await callback(); }
(async () => {
  // A DLL in another account does not mean this REAPER installation is ready.
  const other = path.join(root, 'Users', 'other-user', 'AppData', 'Roaming', 'REAPER', 'UserPlugins');
  fs.mkdirSync(other, { recursive: true }); fs.writeFileSync(path.join(other, 'reaper_VSHookExt.dll'), binary);
  assert.equal(ctx.hasInstalledVshookExtension(), false);
  fs.mkdirSync(plugins, { recursive: true });
  const runtime = path.join(plugins, 'VSHookRuntime', 'FFmpeg');
  fs.mkdirSync(runtime, { recursive: true });
  for (const file of ['avutil-60.dll','avcodec-62.dll','avformat-62.dll','swscale-9.dll','avfilter-11.dll','ffmpeg.exe']) fs.writeFileSync(path.join(runtime, file), 'fixture');
  fs.writeFileSync(path.join(plugins, 'reaper_vshook.dll'), binary);
  ctx.installWindowsPayload({ vshookDll: dll }, { installBundledAssets: false });
  assert.deepEqual(fs.readFileSync(destination), binary);
  assert(!fs.existsSync(path.join(plugins, 'reaper_vshook.dll')));
  assert(fs.existsSync(path.join(other, 'reaper_VSHookExt.dll')));
  assert.equal(ctx.hasInstalledVshookExtension(), true);
  // Failed replacement restores the existing DLL instead of leaving no extension.
  const previous = Buffer.from(binary); previous[100] = 77; fs.writeFileSync(destination, previous);
  failRename = true;
  assert.throws(() => ctx.installWindowsPayload({ vshookDll: dll }), /EACCES locked DLL/);
  assert.deepEqual(fs.readFileSync(destination), previous);
  failRename = false;
  // Reject a bad download before removing the working legacy extension.
  const legacy = path.join(plugins, 'reaper_vshook.dll');
  fs.writeFileSync(legacy, previous);
  const invalid = path.join(root, 'invalid.dll'); fs.writeFileSync(invalid, '<html>failed download</html>');
  assert.throws(() => ctx.installWindowsPayload({ vshookDll: invalid }), /incompleto/);
  assert.deepEqual(fs.readFileSync(legacy), previous);
  // A canceled installer must never install the queued payload.
  receipt = pending.previousReceiptMtimeMs;
  assert.equal((await ctx.completePendingPostCenterUpdateInstall()).skipped, 'center-installer-not-confirmed');
  assert.equal(installs, 0);
  receipt += 2000;
  pending.targetCenterVersion = '9.0';
  assert.equal((await ctx.completePendingPostCenterUpdateInstall()).skipped, 'center-installer-version-mismatch');
  pending.targetCenterVersion = '1.0.2';
  // Wait for REAPER without dropping pending state; notify once and retry.
  reaper = true; ctx.schedulePendingExtensionInstall(); await tick(); await tick();
  assert.equal(notices.length, 1); assert.equal(installs, 0);
  reaper = false; await tick();
  assert.equal(installs, 1); assert.equal(values.get('pendingPostCenterUpdateInstall'), null);
  assert.deepEqual(fs.readFileSync(destination), binary); assert.equal(notices.length, 2);
  // Copy failure remains pending, is visible, and explicit retry completes.
  values.set('pendingPostCenterUpdateInstall', pending); failRename = true; answer = 0;
  ctx.schedulePendingExtensionInstall(); await tick();
  assert.equal(notices.at(-1).type, 'error'); assert(values.get('pendingPostCenterUpdateInstall'));
  failRename = false; await tick(); assert.equal(installs, 2);
  // A running updater defers this background install rather than prompting/fighting it.
  values.set('pendingPostCenterUpdateInstall', pending);
  let release; const updating = ctx.runUpdateOperation(() => new Promise(resolve => { release = resolve; }));
  const count = notices.length; ctx.schedulePendingExtensionInstall(); await tick();
  assert.equal(notices.length, count); release(); await updating; await tick();
  assert.equal(installs, 3);
  // Missing runtime is an error; never claim installation completed.
  fs.rmSync(runtime, { recursive: true }); fs.writeFileSync(legacy, previous);
  values.set('pendingPostCenterUpdateInstall', pending); answer = 1;
  ctx.schedulePendingExtensionInstall(); await tick();
  assert.match(notices.at(-1).detail, /ZIP missing/); assert.equal(installs, 3);
  assert(values.get('pendingPostCenterUpdateInstall')); assert.equal(timers.length, 0);
  assert.deepEqual(fs.readFileSync(legacy), previous);
  console.log('WINDOWS_EXTENSION_INSTALL_OK: profile isolation, runtime reuse, verified copy, rollback, receipt, wait, visible failure and retry.');
})().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(root, { recursive: true, force: true }));
