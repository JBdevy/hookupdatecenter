const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const workflow = read('.github/workflows/catlive-macos-pkg.yml');
let yaml;
try { yaml = require('js-yaml'); } catch { /* The standalone publisher needs only Node; actionlint also validates this file. */ }
if (yaml) {
    const data = yaml.load(workflow);
    assert.equal(data.name, 'CatLive Desktop - macOS and Windows');
    assert.equal(data.jobs.windows['runs-on'], 'windows-2022');
    assert.equal(data.jobs['macos-pkg']['runs-on'], 'macos-26');
    assert.equal(data.jobs['macos-pkg'].needs, undefined, 'Mac build must start independently of Windows.');
    assert.equal(data.jobs.windows.needs, undefined);
    assert.equal(data.jobs['macos-compatibility'].needs, 'windows');
    assert.deepEqual(data.jobs.compatibility.needs, ['windows', 'macos-compatibility']);
    assert.deepEqual(data.jobs.release.needs, ['windows', 'macos-pkg', 'compatibility']);
    const publication = data.jobs.release.steps.find(step => step.uses?.startsWith('softprops/action-gh-release@'));
    assert.deepEqual(publication.with.files.trim().split(/\s+/), ['dist/Catlive-*.pkg', 'dist/Catlive-*.exe'], 'Publish only the two installers; checksums remain internal CI artifacts.');
    assert.equal(publication.with.target_commitish, '${{ github.sha }}');
    const tests = data.jobs['macos-compatibility'].steps.find(step => step.name === 'Validate Windows projects and Remote with the Mac implementation');
    assert(tests.env.CATLIVE_COMPATIBILITY_INPUT && tests.env.CATLIVE_COMPATIBILITY_OUTPUT);
    assert(tests.run.includes('testCrossPlatformReleaseFixtures') && tests.run.includes('test-daw-remote.sh'));
    assert(data.jobs['macos-pkg'].steps.some(step => step.run?.includes('build-catlive-pkg.py')));
    console.log('Release YAML parsed; parallel builds, exchange gate and installer-only publication validated.');
}
for (const required of ['needs: [windows, macos-pkg, compatibility]', 'CatLive-Mac-Fixtures', 'CatLive-Windows-Fixtures', 'verify-mac-roundtrip.cjs', '-Installer', 'bash scripts/test-audio.sh']) assert(workflow.includes(required), required);
assert(workflow.includes('build-catlive-pkg.py'));
assert(read('JarasLive/scripts/sign-catlive-pkg.py').includes('/usr/bin/productsign'));
const model = read('JarasLive/Application/Project/ProjectModels.swift');
assert(model.includes('public var windowsLighting: PortableProjectJSON? = nil'));
const tests = read('JarasLive/Tests/Application/ProjectEncryptionTests.swift');
assert(tests.includes('testWindowsLightingSurvivesMacEditingAndEncryptedSave'));
assert(tests.includes('testCrossPlatformReleaseFixtures'));
const publisher = read('scripts/publish-catlive-desktop.ps1');
assert(publisher.includes("$workflow='catlive-macos-pkg.yml'"));
for (const file of ['build catlive.bat','build catlive windows.bat','scripts/publish-catlive-desktop.ps1','scripts/test-catlive-desktop-release.cjs','JarasLive/Windows/installer/CatLive.iss']) assert(fs.existsSync(path.join(root,file)), file);
assert(!publisher.includes('git add -A\n'), 'Publisher must restrict staging to CatLive files.');
console.log('Mac metadata preservation, interoperability fixtures and desktop release entry points validated.');

const inno = read('JarasLive/Windows/installer/CatLive.iss');
assert(inno.includes('PrivilegesRequired=admin'));
assert(inno.includes('DefaultDirName={commonpf64}\\CatLive'));
assert(inno.includes('DisableDirPage=yes') && inno.includes('UsePreviousAppDir=no'));
assert(!inno.includes('Root: HKCU;'));
const pkg = read('JarasLive/scripts/build-catlive-pkg.py');
assert(pkg.includes('options.set("rootVolumeOnly", "true")'));
assert(pkg.includes('"--install-location", "/Applications"'));
assert(!pkg.includes('ET.SubElement(document, "welcome"') && !pkg.includes('ET.SubElement(document, "conclusion"'));
assert(workflow.includes('deleteReleaseAsset') && workflow.includes('!installers.has(asset.name)'));
const publication = workflow.slice(workflow.indexOf('      - name: Publish both desktop installers together'));
assert(publication.includes('token: ${{ secrets.CATLIVE_RELEASE_TOKEN }}') &&
       publication.includes('github-token: ${{ secrets.CATLIVE_RELEASE_TOKEN }}'),
       'Release replacement and tag updates must use the publication credential with workflow permission.');
assert(publisher.includes("$Version='1.16'") && read('build catlive macos.command').includes('${VERSION:-1.16}'));
for (const entry of [publisher, read('build catlive macos.command')]) {
    for (const file of ['scripts/codesign-with-retry.py', 'scripts/test-codesign-retry.py'])
        assert(entry.includes(file) && fs.existsSync(path.join(root, file)), 'Release entry points must include signing helpers.');
}
for (const entry of [publisher, read('build catlive macos.command')])
    assert(entry.includes('space-before-tab,cr-at-eol diff --cached --check'), 'Preserved CRLF must not block source validation.');
console.log('All-user destinations, minimal native Mac UI and obsolete checksum cleanup validated.');

if (yaml) {
    const step = yaml.load(workflow).jobs.release.steps.find(step => step.name === 'Finalize release installers and source tag');
    const execute = new (Object.getPrototypeOf(async function(){}).constructor)('github', 'context', 'core', 'process', step.with.script);
    (async () => {
        const sha = 'a'.repeat(40), changes = [];
        const context = {repo: {owner: 'fixture', repo: 'catlive'}, sha};
        let assets = [{id: 1, name: 'Catlive-1.07.pkg', state: 'uploaded', size: 100},
                      {id: 2, name: 'Catlive-1.07.exe', state: 'uploaded', size: 100},
                      {id: 3, name: 'Catlive-1.07.pkg.sha256', state: 'uploaded', size: 64},
                      {id: 4, name: 'old-preview.zip', state: 'uploaded', size: 200}];
        const github = {rest: {repos: {
            getReleaseByTag: async ({tag}) => {assert.equal(tag, 'catlive-v1.07');return {data: {id: 7, target_commitish: 'old'}};},
            listReleaseAssets: () => {},
            deleteReleaseAsset: async ({asset_id}) => {changes.push(['delete', asset_id]);},
            updateRelease: async ({target_commitish}) => {changes.push(['release', target_commitish]);}
        }, git: {
            getRef: async () => ({data: {object: {sha: 'old'}}}),
            updateRef: async ({ref, sha, force}) => {changes.push(['tag', ref, sha, force]);}
        }}, paginate: async () => assets};
        const environment = {env: {CATLIVE_RELEASE_VERSION: '1.07'}};
        await execute(github, context, {info: () => {}}, environment);
        assert.deepEqual(changes, [['delete', 3], ['delete', 4], ['tag', 'tags/catlive-v1.07', sha, true], ['release', sha]]);
        changes.length = 0;assets = assets.filter(asset => asset.id !== 2);
        await assert.rejects(() => execute(github, context, {info: () => {}}, environment), /installer missing or incomplete/);
        assert.deepEqual(changes, [], 'Incomplete uploads must not remove existing assets or move the release tag.');
        await assert.rejects(() => execute(github, context, {info: () => {}}, {env: {CATLIVE_RELEASE_VERSION: '../main'}}), /Invalid release version/);
        assert.deepEqual(changes, [], 'Invalid release input must not mutate GitHub.');
        console.log('Existing-version release cleanup and source tag update validated with incomplete-upload protection.');
    })().catch(error => { console.error(error);process.exitCode = 1; });
}
