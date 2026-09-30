'use strict';
const assert = require('node:assert/strict');
const { createUpdateOperationGuard } = require('../src/update-operation-guard');

(async () => {
  const run = createUpdateOperationGuard();
  let release;
  let duplicateStarted = false;
  const first = run(() => new Promise(resolve => { release = resolve; }));
  await assert.rejects(run(() => { duplicateStarted = true; }), /em andamento/);
  assert.equal(duplicateStarted, false);
  release('downloaded');
  assert.equal(await first, 'downloaded');
  assert.equal(await run(() => 'next'), 'next');
  await assert.rejects(run(() => { throw new Error('network failed'); }), /network failed/);
  assert.equal(await run(() => 'retry'), 'retry');
  console.log('Update operation concurrency and failure recovery passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
