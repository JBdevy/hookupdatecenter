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
    assert.equal(data.jobs['macos-pkg'].needs, 'windows');
    assert.deepEqual(data.jobs.compatibility.needs, ['windows', 'macos-pkg']);
    assert.deepEqual(data.jobs.release.needs, ['windows', 'macos-pkg', 'compatibility']);
    const publication = data.jobs.release.steps.find(step => step.uses?.startsWith('softprops/action-gh-release@'));
    for (const extension of ['.pkg', '.exe', '.zip']) assert(publication.with.files.includes(extension));
    assert.equal(publication.with.target_commitish, '${{ github.sha }}');
    const tests = data.jobs['macos-pkg'].steps.find(step => step.name === 'Validate project and transport regressions');
    assert(tests.env.CATLIVE_COMPATIBILITY_INPUT && tests.env.CATLIVE_COMPATIBILITY_OUTPUT);
    console.log('Release YAML parsed; dependency graph and paired assets validated.');
}
for (const required of ['needs: [windows, macos-pkg, compatibility]', 'CatLive-Mac-Fixtures', 'CatLive-Windows-Fixtures', 'verify-mac-roundtrip.cjs', '-Installer', 'bash scripts/test-audio.sh']) assert(workflow.includes(required), required);
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
