const assert = require('node:assert/strict')
const http = require('node:http')
const { performance } = require('node:perf_hooks')

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms))
const sockets = new Set()
const timers = new Set()
const requests = []
let mode = 'full'
const fullState = {
  connected: true, projectName: 'HTTP fixture', currentPage: 'regions',
  regions: [{ id: 'fixture-song', name: 'Fixture song' }],
}
const native = http.createServer((req, res) => {
  let body = ''
  req.setEncoding('utf8')
  req.on('data', chunk => { body += chunk })
  req.on('end', () => {
    requests.push({ method: req.method, path: req.url, body })
    if (mode === 'truncated') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': 1000 })
      res.write('{"connected":true,')
      setTimeout(() => res.destroy(), 20)
    } else if (mode === 'trickle') {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.write('{"ok":true,"padding":"')
      const timer = setInterval(() => res.write('x'), 50)
      timers.add(timer)
      res.once('close', () => { clearInterval(timer); timers.delete(timer) })
    } else if (mode === 'silent') {
      // Keep the socket open without headers until the absolute deadline.
    } else if (mode === 'malformed') {
      res.writeHead(200); res.end('{broken')
    } else if (mode === 'unavailable') {
      res.writeHead(503); res.end('{"ok":false}')
    } else {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify(req.url.startsWith('/state')
        ? { ...fullState, regions: mode === 'empty' ? [] : fullState.regions }
        : { ok: true, mode: 'disabled' }))
    }
  })
})
native.on('connection', socket => {
  sockets.add(socket)
  socket.once('close', () => sockets.delete(socket))
})

;(async () => {
  await new Promise(resolve => native.listen(0, '127.0.0.1', resolve))
  process.env.VSHOOK_NATIVE_BRIDGE_PORT = String(native.address().port)
  const { getNativeBridgeStateSnapshot, getNativeTimecodeStatusSnapshot,
    postNativeBridgeCommand } = require('../src/bridge-server')
  mode = 'empty'
  assert.equal((await getNativeBridgeStateSnapshot(0, { force: true })).regions.length, 0)
  mode = 'full'
  assert.equal((await getNativeBridgeStateSnapshot(0, { force: true })).regions.length, 1)

  await sleep(5)
  mode = 'truncated'
  const before = requests.length
  let started = performance.now()
  const failed = await Promise.race([
    Promise.all([getNativeBridgeStateSnapshot(0, { force: true }),
      getNativeBridgeStateSnapshot(0, { force: true })]),
    sleep(1200).then(() => { throw new Error('Partial response left native refresh in flight') }),
  ])
  assert.deepEqual(failed, [null, null])
  assert.equal(requests.length - before, 1, 'concurrent readers share one refresh')
  assert(performance.now() - started < 1200)
  mode = 'full'
  const recovered = await getNativeBridgeStateSnapshot(0, { force: true })
  assert.equal(recovered.regions.length, 1, 'new request recovers after an interrupted response')
  assert.equal(requests.length - before, 2)
  console.log('NATIVE_PARTIAL_RESPONSE_RELEASES_ALL_WAITERS_AND_RECOVERS_OK')

  for (const failure of ['trickle', 'silent']) {
    mode = failure
    started = performance.now()
    assert.equal(await getNativeTimecodeStatusSnapshot(), null)
    const elapsed = performance.now() - started
    assert(elapsed >= 650 && elapsed < 1500,
      `${failure} response must obey the 750ms total deadline; took ${elapsed}ms`)
    mode = 'full'
    assert.equal((await getNativeTimecodeStatusSnapshot()).ok, true)
  }
  console.log('NATIVE_ABSOLUTE_DEADLINE_COVERS_PARTIAL_PROGRESS_AND_SILENT_SOCKET_OK')

  for (const failure of ['malformed', 'unavailable']) {
    mode = failure
    assert.equal(await getNativeTimecodeStatusSnapshot(), null)
  }
  mode = 'full'
  const command = { type: 'fixture_only', payload: { value: 7 } }
  assert.equal(await postNativeBridgeCommand(command), true)
  assert.deepEqual(requests.at(-1), { method: 'POST', path: '/command', body: JSON.stringify(command) })
  console.log('NATIVE_JSON_HTTP_ERRORS_AND_COMMAND_BODY_PRESERVED_OK')
})().catch(error => { console.error(error); process.exitCode = 1 }).finally(async () => {
  for (const timer of timers) clearInterval(timer)
  for (const socket of sockets) socket.destroy()
  await new Promise(resolve => native.close(resolve))
})
