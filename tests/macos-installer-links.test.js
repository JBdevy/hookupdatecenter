const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const helper = path.join(__dirname, '../build/pkg-scripts/reaper-directories.sh');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-installer-links-'));
const quote = value => `'${value.replace(/'/g, "'\\''")}'`;
function run(root) {
  return spawnSync('/bin/bash', ['-c', `. ${quote(helper)}; hook_prepare_reaper_directories ${quote(root)}`], { encoding: 'utf8' });
}
function backupOf(directory) {
  return fs.readdirSync(path.dirname(directory)).filter(name => name.startsWith(path.basename(directory) + '.hook-link-backup.')).map(name => path.join(path.dirname(directory), name));
}
try {
  for (const kind of ['self', 'cycle', 'dangling', 'file-link', 'valid', 'regular-file', 'root-cycle']) {
    const base = path.join(temporary, kind, 'Application Support');
    const root = path.join(base, 'REAPER');
    const plugins = path.join(root, 'UserPlugins');
    fs.mkdirSync(base, { recursive: true });
    if (kind === 'root-cycle') fs.symlinkSync(root, root);
    else fs.mkdirSync(root);
    const external = path.join(base, 'existing-content');
    fs.mkdirSync(external); fs.writeFileSync(path.join(external, 'keep.dylib'), 'preserve');
    if (kind === 'self') fs.symlinkSync(plugins, plugins);
    if (kind === 'cycle') { fs.symlinkSync('../cycle-link', plugins); fs.symlinkSync('REAPER/UserPlugins', path.join(base, 'cycle-link')); }
    if (kind === 'dangling') fs.symlinkSync(path.join(base, 'missing'), plugins);
    if (kind === 'file-link') fs.symlinkSync(path.join(external, 'keep.dylib'), plugins);
    if (kind === 'valid') fs.symlinkSync(external, plugins);
    if (kind === 'regular-file') fs.writeFileSync(plugins, 'do not remove');
    const result = run(root);
    if (kind === 'regular-file') {
      assert.notEqual(result.status, 0);
      assert.equal(fs.readFileSync(plugins, 'utf8'), 'do not remove');
      continue;
    }
    assert.equal(result.status, 0, `${kind}: ${result.stderr}`);
    for (const name of ['UserPlugins', 'ColorThemes', 'Scripts']) assert(fs.statSync(path.join(root, name)).isDirectory());
    assert.equal(fs.readFileSync(path.join(external, 'keep.dylib'), 'utf8'), 'preserve');
    if (kind === 'valid') { assert(fs.lstatSync(plugins).isSymbolicLink()); assert.equal(backupOf(plugins).length, 0); }
    else assert.equal(backupOf(kind === 'root-cycle' ? root : plugins).length, 1);
    assert.equal(run(root).status, 0, 'a second run must remain safe');
    if (kind !== 'valid') assert.equal(backupOf(kind === 'root-cycle' ? root : plugins).length, 1);
  }
  if (process.platform === 'darwin') {
    const volume = path.join(temporary, 'installation');
    const resources = path.join(volume, 'Applications/Hook Center.app/Contents/Resources');
    const companion = path.join(resources, 'vshook-companion/VS Hook Teleprompt Settings.app/Contents');
    fs.mkdirSync(path.join(companion, 'MacOS'), { recursive: true });
    fs.mkdirSync(path.join(companion, 'Resources'));
    fs.writeFileSync(path.join(companion, 'MacOS/VS Hook Teleprompt Settings'), 'fixture');
    fs.writeFileSync(path.join(companion, 'Resources/app.asar'), 'fixture');
    const themes = path.join(resources, 'vshook-themes'); fs.mkdirSync(themes);
    fs.writeFileSync(path.join(themes, 'fixture.ReaperTheme'), 'theme');
    const globalRoot = path.join(volume, 'Library/Application Support/REAPER');
    fs.mkdirSync(globalRoot, { recursive: true });
    const plugins = path.join(globalRoot, 'UserPlugins'); fs.symlinkSync('UserPlugins', plugins);
    const userRoot = path.join(volume, 'Users/fixture-user/Library/Application Support/REAPER');
    fs.mkdirSync(userRoot, { recursive: true });
    fs.symlinkSync('UserPlugins', path.join(userRoot, 'UserPlugins'));
    const bin = path.join(volume, 'bin'); fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, 'id'), '#!/bin/sh\n[ "$1" = "-u" ] && [ "$2" = "fixture-user" ]\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'chown'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const env = { ...process.env, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin` };
    const result = spawnSync('/bin/bash', [path.join(__dirname, '../build/pkg-scripts/postinstall'), 'fixture.pkg', '/Applications', volume], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    for (const root of [globalRoot, userRoot]) {
      assert(fs.existsSync(path.join(root, 'UserPlugins/VSHookTelepromptSettings/VS Hook Teleprompt Settings.app/Contents/Resources/app.asar')));
      assert.equal(fs.readFileSync(path.join(root, 'ColorThemes/fixture.ReaperTheme'), 'utf8'), 'theme');
      assert.equal(backupOf(path.join(root, 'UserPlugins')).length, 1);
    }
    assert(fs.existsSync(path.join(resources, 'vshook-center-install-complete.flag')));
    // Exercise the actual elevated script generated by the in-app installer,
    // redirecting its known system roots into this fixture before execution.
    let elevated;
    const context = vm.createContext({ fs, path, app: { isPackaged: false }, process,
      __dirname: path.join(__dirname, '../src'), shellQuote: quote,
      getBundledVshookCompanionDir: () => path.join(resources, 'vshook-companion'),
      getBundledVshookThemePaths: () => [path.join(themes, 'fixture.ReaperTheme')],
      execFileSync: (_, args) => { elevated = JSON.parse(args[1].slice('do shell script '.length, -' with administrator privileges'.length)); }
    });
    const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
    vm.runInContext(source.slice(source.indexOf('function installMacPayload('), source.indexOf('function getBundledReaperAssetsIdentity(')), context);
    context.installMacPayload({}, { installExtension: false });
    const nested = path.join(plugins, 'VSHookTelepromptSettings');
    fs.renameSync(nested, nested + '.existing'); fs.symlinkSync('VSHookTelepromptSettings', nested);
    elevated = elevated.replace('GLOBAL_REAPER="/Library/Application Support/REAPER"', `GLOBAL_REAPER="${globalRoot}"`).replace('for USER_HOME in /Users/*;', `for USER_HOME in ${quote(path.join(volume, 'Users'))}/*;`);
    const repair = spawnSync('/bin/bash', ['-c', elevated], { env, encoding: 'utf8' });
    assert.equal(repair.status, 0, repair.stderr);
    assert(fs.statSync(nested).isDirectory()); assert.equal(backupOf(nested).length, 1);
    assert(fs.existsSync(nested + '.existing/VS Hook Teleprompt Settings.app/Contents/Resources/app.asar'));
  }
  console.log('HOOK_INSTALLER_LINKS_OK: PKG and in-app install; cycles, missing targets, valid links, preservation, idempotence.');
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
