const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const script = path.resolve(__dirname, '../build/notarize-artifacts.sh');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-notarize-test-'));
const bin = path.join(root, 'bin');
fs.mkdirSync(bin);
const mock = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const command = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const action = command === 'xcrun' ? args.slice(0, 2).join(' ') : command;
const log = process.env.HOOK_TEST_CALLS;
const previous = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\\n') : [];
fs.appendFileSync(log, action + '\\n');
const count = previous.filter(value => value === action).length + 1;
if (action === 'notarytool submit') console.log(JSON.stringify({id: 'fixture-submission'}));
else if (action === 'notarytool info') console.log(JSON.stringify({status: process.env.HOOK_TEST_REJECT ? 'Rejected' : 'Accepted'}));
else if (action === process.env.HOOK_TEST_FAIL_ACTION && count <= Number(process.env.HOOK_TEST_FAIL_COUNT)) {
  if (process.env.HOOK_TEST_NETWORK === '1') console.error('Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."');
  else console.error('Invalid artifact or ticket.');
  process.exit(Number(process.env.HOOK_TEST_FAIL_CODE));
}
`;
for (const command of ['xcrun', 'spctl', 'sleep']) {
  fs.writeFileSync(path.join(bin, command), mock, { mode: 0o755 });
}

function run(name, action, failures, code, network, expectedStatus, extra = {}) {
  const cwd = path.join(root, name);
  fs.mkdirSync(path.join(cwd, 'dist'), { recursive: true });
  fs.writeFileSync(path.join(cwd, 'dist/Hook-Center-fixture-macOS.pkg'), 'fixture');
  const log = path.join(cwd, 'calls.log');
  const result = spawnSync('bash', [script], {
    cwd, encoding: 'utf8',
    env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH,
      HOOK_NOTARY_APPLE_ID: 'fixture@example.invalid', HOOK_NOTARY_PASSWORD: 'fixture',
      HOOK_NOTARY_TEAM_ID: 'FIXTURE', HOOK_TEST_CALLS: log,
      HOOK_TEST_FAIL_ACTION: action, HOOK_TEST_FAIL_COUNT: String(failures),
      HOOK_TEST_FAIL_CODE: String(code), HOOK_TEST_NETWORK: network ? '1' : '0',
      HOOK_TEST_REJECT: '', ...extra },
  });
  if (result.error) throw result.error;
  assert.equal(result.status, expectedStatus, name + '\n' + result.stdout + result.stderr);
  const calls = fs.readFileSync(log, 'utf8').trim().split('\n');
  const count = action => calls.filter(value => value === action).length;
  assert.equal(count('notarytool submit'), 1, name + ': do not resubmit accepted package');
  assert.equal(count('notarytool info'), 1);
  assert.equal(count('spctl'), expectedStatus === 0 ? 1 : 0,
    name + ': never publish an unvalidated package');
  assert.equal(result.stdout.includes('Artefato pronto para cliente'), expectedStatus === 0);
  return count;
}

try {
  let count = run('staple-recovers', 'stapler staple', 2, 68, true, 0);
  assert.equal(count('stapler staple'), 3); assert.equal(count('stapler validate'), 1);
  assert.equal(count('sleep'), 2);
  count = run('validate-recovers', 'stapler validate', 2, 68, true, 0);
  assert.equal(count('stapler staple'), 1); assert.equal(count('stapler validate'), 3);
  assert.equal(count('sleep'), 2);
  count = run('retry-exhausted', 'stapler validate', 99, 68, true, 68);
  assert.equal(count('stapler staple'), 1); assert.equal(count('stapler validate'), 5);
  assert.equal(count('sleep'), 4);
  count = run('invalid-artifact', 'stapler staple', 99, 65, false, 65);
  assert.equal(count('stapler staple'), 1); assert.equal(count('stapler validate'), 0);
  assert.equal(count('sleep'), 0);
  count = run('non-network-ticket-error', 'stapler validate', 99, 68, false, 68);
  assert.equal(count('stapler validate'), 1); assert.equal(count('sleep'), 0);
  count = run('apple-rejected', '', 0, 0, false, 1, { HOOK_TEST_REJECT: '1' });
  assert.equal(count('stapler staple'), 0); assert.equal(count('stapler validate'), 0);
  console.log('NOTARIZE_NETWORK_RETRY_OK: accepted once, bounded staple/validate retries, rejection and invalid tickets still fail');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
