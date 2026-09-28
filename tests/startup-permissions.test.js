const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const scriptsDir = '/fixture/REAPER/Scripts';
let directoryWrites = 0;
const denied = Object.assign(new Error('permission denied'), { code: 'EACCES' });
const context = vm.createContext({
  fs: { existsSync: () => false, mkdirSync: () => { directoryWrites++; throw denied; } },
  path, process: { env: {}, platform: 'darwin' },
  getDefaultReaperScriptsDir: () => scriptsDir,
  bridgeConfig: { scriptsDir }, readBridgeConfig: () => ({ scriptsDir }),
  refreshBridgeNetwork: () => ({ selected: { ip: '127.0.0.1', name: '' }, networks: [] }),
  bridgeServers: [], bridgeInfos: [], bridgeLastError: '',
  applePeerBridgeProcess: null, applePeerBridgeReady: false, applePeerBridgeLastError: '',
  getChatMobileBootstrapSecret: () => 'fixture', getBridgeAppCacheVersion: () => 'fixture'
});
for (const [start, end] of [
  ['function resolveBridgeScriptsDir(', 'function getLicenseOfflineStatus('],
  ['function getBridgeState(', 'function getLyricsDefaults(']
]) vm.runInContext(source.slice(source.indexOf(start), source.indexOf(end)), context);
assert.equal(context.getBridgeState().scriptsDir, scriptsDir);
assert.equal(directoryWrites, 0, 'Status used before login must not create the REAPER directory');
assert.throws(() => context.resolveBridgeScriptsDir({}), /permission denied/);
assert.equal(directoryWrites, 1, 'Operations needing Scripts must still report permission failures');

if (process.platform === 'darwin') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-startup-permissions-'));
  try {
    const resources = path.join(root, 'Applications/Hook Center.app/Contents/Resources');
    const companion = path.join(resources, 'vshook-companion/VS Hook Teleprompt Settings.app/Contents');
    fs.mkdirSync(path.join(companion, 'MacOS'), { recursive: true });
    fs.mkdirSync(path.join(companion, 'Resources'), { recursive: true });
    fs.writeFileSync(path.join(companion, 'MacOS/VS Hook Teleprompt Settings'), 'fixture');
    fs.writeFileSync(path.join(companion, 'Resources/app.asar'), 'fixture');
    fs.mkdirSync(path.join(resources, 'vshook-themes'));
    fs.writeFileSync(path.join(resources, 'vshook-themes/fixture.ReaperTheme'), 'fixture');
    const reaper = path.join(root, 'Users/fixture-user/Library/Application Support/REAPER');
    fs.mkdirSync(reaper, { recursive: true }); // Existing directory from an older installer.
    fs.mkdirSync(path.join(root, 'Users/not-an-account'));
    const bin = path.join(root, 'test-bin');
    fs.mkdirSync(bin);
    const owners = path.join(root, 'owners.log');
    fs.writeFileSync(path.join(bin, 'id'), '#!/bin/sh\n[ "$1" = "-u" ] && [ "$2" = "fixture-user" ]\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'chown'), '#!/bin/sh\nprintf "%s\\n" "$@" >> "$HOOK_TEST_OWNERS"\n', { mode: 0o755 });
    const result = spawnSync('/bin/bash', [path.join(__dirname, '../build/pkg-scripts/postinstall'), 'fixture.pkg', '/Applications', root], {
      env: { ...process.env, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`, HOOK_TEST_OWNERS: owners },
      encoding: 'utf8'
    });
    assert.equal(result.status, 0, result.stderr);
    const ownerLog = fs.readFileSync(owners, 'utf8').split('\n');
    for (const directory of [reaper, ...['Scripts', 'UserPlugins', 'ColorThemes'].map(name => path.join(reaper, name))]) {
      assert(fs.statSync(directory).isDirectory());
      assert(ownerLog.includes(directory), `Installer must return directory ownership: ${directory}`);
      assert.equal(fs.statSync(directory).mode & 0o700, 0o700);
    }
    assert(ownerLog.includes('fixture-user:staff'));
    assert(!fs.existsSync(path.join(root, 'Users/not-an-account/Library')));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
console.log('Hook Center startup permission regressions passed.');
