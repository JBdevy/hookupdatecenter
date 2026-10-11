const fs = require('fs')

function fileIdentity(filename) {
  try {
    const value = fs.statSync(filename, { bigint: true })
    return [value.dev, value.ino, value.size, value.mtimeNs, value.ctimeNs].join(':')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

function freezeSnapshot(value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) return value
  for (const child of Object.values(value)) freezeSnapshot(child)
  return Object.freeze(value)
}

// Conf/electron-store reads and parses its entire JSON file on every get().
// Relay callbacks need a few settings many times per second. Reuse only an
// unchanged, immutable snapshot; no TTL delays license or device changes.
function createStoreSnapshotReader(store) {
  let identity = null
  let snapshot = null
  const invalidate = () => { identity = null; snapshot = null }
  const unsubscribe = store.onDidAnyChange(invalidate)
  const read = () => {
    const before = fileIdentity(store.path)
    if (before !== null && before === identity && snapshot !== null) return snapshot
    // Clear before decoding: a deleted/corrupt/inaccessible file must never
    // retain previously active licensing or previous network settings.
    invalidate()
    const value = freezeSnapshot(store.store)
    const after = fileIdentity(store.path)
    if (before !== null && before === after) { identity = after; snapshot = value }
    return value
  }
  read.dispose = () => { unsubscribe(); invalidate() }
  return read
}

module.exports = { createStoreSnapshotReader }
