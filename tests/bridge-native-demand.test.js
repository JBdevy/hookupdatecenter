const assert = require('node:assert/strict')
const fs = require('node:fs')
const http = require('node:http')
const os = require('node:os')
const path = require('node:path')
const { performance } = require('node:perf_hooks')

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function until(predicate, description, timeout = 4000) {
  const deadline = performance.now() + timeout
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(`Timed out: ${description}`)
    await sleep(5)
  }
}

async function fixture({ licensed = true, holdDiscovery = false, readerDelay = 0 } = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'hook-native-demand-'))
  const requests = []
  const sockets = new Set()
  const pendingDiscovery = []
  const pendingResponses = new Set()
  const timers = new Set()
  const empty = {
    connected: true, projectName: 'Demand fixture', projectId: 'fixture-project',
    currentPage: 'regions', regions: [], playlists: [], markers: [],
  }
  const full = { ...empty, regions: [{ id: 'fixture-song', name: 'Fixture song', start: 0, end: 30 }] }
  let cached = empty
  let readerState = full
  const send = (res, state) => {
    if (res.destroyed) return
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(state))
  }
  const native = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    assert.equal(url.pathname, '/state', 'fixture must never reach a real native route')
    const discovery = url.searchParams.get('discovery') === '1'
    requests.push({ discovery, path: req.url, at: performance.now() })
    pendingResponses.add(res)
    res.once('close', () => pendingResponses.delete(res))
    if (discovery) {
      if (holdDiscovery) pendingDiscovery.push(res)
      else send(res, cached)
    } else {
      const state = readerState
      if (readerDelay) {
        const timer = setTimeout(() => { timers.delete(timer); cached = state; send(res, state) }, readerDelay)
        timers.add(timer)
      } else { cached = state; send(res, state) }
    }
  })
  native.on('connection', socket => {
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
  })
  await new Promise(resolve => native.listen(0, '127.0.0.1', resolve))
  const oldPort = process.env.VSHOOK_NATIVE_BRIDGE_PORT
  process.env.VSHOOK_NATIVE_BRIDGE_PORT = String(native.address().port)
  const modulePath = require.resolve('../src/bridge-server')
  delete require.cache[modulePath]
  const { createBridgeServer } = require(modulePath)
  // The production API does not expose server.address(). Capture the instance
  // only while constructing this isolated server, so both listeners use port0.
  const originalCreateServer = http.createServer
  let publicServer
  let bridge
  http.createServer = (...args) => { publicServer = originalCreateServer(...args); return publicServer }
  try {
    bridge = createBridgeServer({ host: '127.0.0.1', port: 0,
      publicBridgeHost: '192.0.2.10', appName: 'Demand fixture',
      sharedDir: temporary, appDir: temporary, isLicenseActive: () => licensed })
  } finally { http.createServer = originalCreateServer }
  await bridge.start()
  const request = route => new Promise((resolve, reject) => {
    const started = performance.now()
    const req = http.get({ host: '127.0.0.1', port: publicServer.address().port,
      path: route, agent: false }, res => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', chunk => { body += chunk })
      res.on('error', reject)
      res.on('end', () => {
        clearTimeout(deadline)
        try { resolve({ status: res.statusCode, data: JSON.parse(body), elapsed: performance.now() - started }) }
        catch (error) { reject(error) }
      })
    })
    const deadline = setTimeout(() => req.destroy(new Error('Public fixture request exceeded deadline')), 4000)
    req.on('error', error => { clearTimeout(deadline); reject(error) })
  })
  return {
    requests, request,
    readers: () => requests.filter(item => !item.discovery).length,
    discoveries: () => requests.filter(item => item.discovery).length,
    releaseDiscovery() {
      holdDiscovery = false
      for (const res of pendingDiscovery.splice(0)) send(res, cached)
    },
    disconnect() { cached = readerState = { ...empty, connected: false, projectName: '' } },
    async close() {
      await bridge.stop()
      for (const timer of timers) clearTimeout(timer)
      for (const socket of sockets) socket.destroy()
      await new Promise(resolve => native.close(resolve))
      delete require.cache[modulePath]
      if (oldPort === undefined) delete process.env.VSHOOK_NATIVE_BRIDGE_PORT
      else process.env.VSHOOK_NATIVE_BRIDGE_PORT = oldPort
      assert.equal(path.dirname(temporary), path.resolve(os.tmpdir()))
      assert(path.basename(temporary).startsWith('hook-native-demand-'))
      fs.rmSync(temporary, { recursive: true, force: true })
    },
  }
}

async function testDiscoveryOnly() {
  const f = await fixture()
  try {
    await until(() => f.discoveries() === 1, 'initial passive discovery')
    await f.request('/projects')
    await f.request('/discovery')
    await f.request('/health')
    await sleep(1350)
    assert(f.discoveries() >= 2, 'background polling must continue discovering without a consumer')
    assert.equal(f.readers(), 0, 'startup, background, projects and discovery must not activate a state reader')
  } finally { await f.close() }
  console.log('NATIVE_BACKGROUND_AND_PROJECT_DISCOVERY_NEVER_ACTIVATE_READER_OK')
}

async function testReaderDuringDiscovery() {
  const f = await fixture({ holdDiscovery: true })
  try {
    await until(() => f.discoveries() === 1, 'held startup discovery')
    const readers = [f.request('/state'), f.request('/state.json'), f.request('/state')]
    await sleep(30)
    assert.equal(f.readers(), 0, 'real readers wait for the existing discovery instead of duplicating requests')
    f.releaseDiscovery()
    const results = await Promise.all(readers)
    assert(results.every(result => result.data.regions.length === 1 && result.data.connected))
    assert.equal(f.readers(), 1, 'all waiting consumers coalesce into one real reader after discovery')
  } finally { await f.close() }
  console.log('NATIVE_INFLIGHT_DISCOVERY_PROMOTES_ONE_READER_FOR_CONCURRENT_CONSUMERS_OK')
}

async function testFreshDiscoveryCache() {
  const f = await fixture()
  try {
    await f.request('/projects')
    assert.equal(f.readers(), 0)
    const state = await f.request('/state')
    assert.equal(state.data.regions.length, 1, 'fresh discovery-only cache must not hide first reader demand')
    assert.equal(f.readers(), 1)
    await Promise.all([f.request('/state'), f.request('/state')])
    assert.equal(f.readers(), 1, 'fresh real-reader cache still coalesces subsequent polls')
  } finally { await f.close() }
  console.log('NATIVE_FRESH_DISCOVERY_CACHE_PRESERVES_FIRST_REAL_DEMAND_OK')
}

async function testSlowNativeResponse() {
  const f = await fixture({ readerDelay: 2500 })
  try {
    await f.request('/projects')
    const first = await f.request('/state')
    assert.equal(first.status, 200)
    assert(first.elapsed >= 1600 && first.elapsed < 2200,
      `public state must finish before the client 2200ms deadline: ${first.elapsed.toFixed(1)}ms`)
    assert.equal(first.data.regions.length, 0, 'an unfinished first snapshot must not invent music')
    const second = await f.request('/state')
    assert(second.elapsed < 2200, 'next poll remains inside the client deadline')
    assert.equal(second.data.regions.length, 1, 'slow native response finishes and warms the waiting next poll')
    assert.equal(f.readers(), 1, 'public deadline must not cancel and restart the underlying native request')
    console.log(`NATIVE_SLOW_2500MS_SNAPSHOT_PUBLIC_RESPONSE_MS=${first.elapsed.toFixed(1)} NEXT_POLL_RECOVERS_OK`)
  } finally { await f.close() }
}

async function testLicenseAndDisconnect() {
  let f = await fixture({ licensed: false })
  try {
    for (const route of ['/state', '/projects', '/discovery']) {
      const result = await f.request(route)
      assert.equal(result.data.connected, false)
    }
    await sleep(1300)
    assert.equal(f.requests.length, 0, 'inactive license must not activate a reader or background discovery')
  } finally { await f.close() }
  f = await fixture()
  try {
    assert.equal((await f.request('/state')).data.regions.length, 1)
    f.disconnect()
    // Preserve the existing one-failure grace period. Once both probes failed,
    // the last valid project must no longer appear connected with old songs.
    await sleep(350)
    await f.request('/state')
    const disconnected = await f.request('/state')
    assert.equal(disconnected.data.connected, false)
    assert.deepEqual(disconnected.data.regions, [])
    assert.equal((await f.request('/projects')).data.projectCount, 0)
  } finally { await f.close() }
  console.log('NATIVE_LICENSE_LOCK_AND_CONFIRMED_DISCONNECT_DO_NOT_INVENT_SONGS_OK')
}

;(async () => {
  await testDiscoveryOnly()
  await testReaderDuringDiscovery()
  await testFreshDiscoveryCache()
  await testSlowNativeResponse()
  await testLicenseAndDisconnect()
})().catch(error => { console.error(error); process.exitCode = 1 })
