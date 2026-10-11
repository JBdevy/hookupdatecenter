'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const Conf = require('conf')
const { createStoreSnapshotReader } = require('../src/store-snapshot')

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-store-snapshot-'))
const store = new Conf({ cwd: root, projectName: 'snapshot-test', clearInvalidConfig: false })
store.set({ license: { active: true }, deviceName: 'PC A', directCable: { projectSync: { ip: '192.168.77.1' } }, unrelatedLargeSettings: 'x'.repeat(43000) })
const read = createStoreSnapshotReader(store)
const originalRead = fs.readFileSync
let reads = 0
fs.readFileSync = function (filename, ...args) {
  if (filename === store.path) reads++
  return originalRead.call(this, filename, ...args)
}
try {
  assert.equal(read().license.active, true)
  const warmReads = reads
  for (let i = 0; i < 1000; i++) {
    assert.equal(read().deviceName, 'PC A')
    assert.equal(read().license.active, true)
    assert.equal(read().directCable.projectSync.ip, '192.168.77.1')
  }
  assert.equal(reads, warmReads, 'Unchanged settings must not reread or reparse JSON in relay callbacks')
  assert.throws(() => { read().license.active = false }, TypeError, 'A caller cannot modify the cached license')

  store.set('license.active', false)
  assert.equal(read().license.active, false, 'Revocation is visible synchronously, without a TTL')
  store.set('deviceName', 'PC B')
  assert.equal(read().deviceName, 'PC B')
  store.set('directCable.projectSync.ip', '192.168.77.2')
  assert.equal(read().directCable.projectSync.ip, '192.168.77.2')

  // Atomic external replacement has the same byte length and restored mtime.
  // Inode/ctime identity must still expose the change immediately.
  let oldStat = fs.statSync(store.path)
  let serialized = originalRead(store.path, 'utf8').replace('PC B', 'PC C')
  const temporary = path.join(root, 'replacement.json')
  fs.writeFileSync(temporary, serialized)
  fs.utimesSync(temporary, oldStat.atime, oldStat.mtime)
  fs.renameSync(temporary, store.path)
  assert.equal(read().deviceName, 'PC C')
  // The in-place equivalent preserves the inode as well; ctime detects it.
  oldStat = fs.statSync(store.path)
  fs.writeFileSync(store.path, serialized.replace('PC C', 'PC D'))
  fs.utimesSync(store.path, oldStat.atime, oldStat.mtime)
  assert.equal(read().deviceName, 'PC D')

  fs.writeFileSync(store.path, '{invalid JSON')
  assert.throws(read, SyntaxError, 'Corrupt settings must never return a stale active license')
  fs.unlinkSync(store.path)
  assert.equal(read().license, undefined, 'Deleted settings must not retain a prior license')
  fs.mkdirSync(store.path)
  assert.throws(read, /directory|EISDIR/i, 'Filesystem failures must not reuse the old snapshot')
  fs.rmdirSync(store.path)
  store.set({ license: { active: true }, deviceName: 'Restored', directCable: { adapterId: 'legacy', ip: '192.168.77.3' } })

  const source = originalRead(path.join(__dirname, '../src/main.js'), 'utf8')
  const scope = vm.createContext({ store, readRuntimeSettings: read, normalizeDirectCableChannel: value => value })
  for (const [start, end] of [
    ['function getStoredDeviceName()', 'function saveStoredDeviceName('],
    ['function isVsHookLicenseActiveForBridge()', 'function getChatMobileBootstrapSecret('],
    ['function migrateLegacyDirectCableConfiguration()', 'function matchConfiguredDirectCableAdapter('],
  ]) {
    const begin = source.indexOf(start), finish = source.indexOf(end, begin)
    assert(begin >= 0 && finish > begin)
    vm.runInContext(source.slice(begin, finish), scope)
  }
  assert.equal(scope.isVsHookLicenseActiveForBridge(), true)
  store.set('license.active', false)
  assert.equal(scope.isVsHookLicenseActiveForBridge(), false)
  assert.equal(scope.getStoredDeviceName(), 'Restored')
  assert.equal(scope.getStoredDirectCableChannel('projectSync').ip, '192.168.77.3')
  assert.equal(scope.getStoredDirectCableChannel('timecode').ip, '192.168.77.3')
  assert.equal(scope.getStoredDirectCableChannel('timecodeBackup').ip, '', 'Legacy migration must not configure the backup cable')
  assert.equal(store.get('directCable.adapterId'), undefined)
  store.set('directCable.projectSync.ip', '192.168.77.9')
  assert.equal(scope.getStoredDirectCableChannel('projectSync').ip, '192.168.77.9')
  const stableReads = reads
  for (let i = 0; i < 1000; i++) {
    scope.isVsHookLicenseActiveForBridge()
    scope.getStoredDeviceName()
    scope.getStoredDirectCableChannel('projectSync')
  }
  assert.equal(reads, stableReads, 'The real relay settings callbacks and legacy migration check must reuse an unchanged snapshot')

  store.set('unrelatedLargeSettings', 'x'.repeat(43000))
  read()
  const startDisk = performance.now()
  for (let i = 0; i < 2000; i++) store.get('license')
  const diskMs = performance.now() - startDisk
  const startCached = performance.now()
  for (let i = 0; i < 2000; i++) read().license
  const cacheMs = performance.now() - startCached
  console.log('STORE_SNAPSHOT_CONFIG_READ_MS', { direct: diskMs / 2000, snapshot: cacheMs / 2000 })
  console.log('STORE_SNAPSHOT_OK: zero repeated JSON reads, synchronous revocation, external edits/replacement, missing/corrupt files, real relay callbacks and legacy cable migration')
} finally {
  read.dispose()
  fs.readFileSync = originalRead
  fs.rmSync(root, { recursive: true, force: true })
}
