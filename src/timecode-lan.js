const crypto = require('crypto')
const dgram = require('dgram')
const http = require('http')
const os = require('os')

const DISCOVERY_PORT = 47833
const DISCOVER_MAGIC = 'VSHOOK_TIMECODE_DISCOVER_V1'
const OFFER_MAGIC = 'VSHOOK_TIMECODE_OFFER_V1'
const MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024
const LOCAL_STATUS_INTERVAL_MS = 180
const TRANSMIT_INTERVAL_MS = 45
const DISCOVERY_INTERVAL_MS = 650
const DIRECT_DISCOVERY_INTERVAL_MS = 3000
const DIRECT_DISCOVERY_TIMEOUT_MS = 260
const DIRECT_DISCOVERY_BATCH_SIZE = 24
const RECEIVER_TIMEOUT_MS = 3000

function isPairCode(value) {
  return /^\d{6}$/.test(String(value || '').trim())
}

function safeName(value, fallback) {
  const normalized = String(value || '').trim().replace(/[\u0000-\u001f\u007f]/g, '')
  return normalized.slice(0, 80) || fallback
}

function sendJson(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload || {}), 'utf8')
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

function readJsonBody(req, maxBytes = MAX_HTTP_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let finished = false

    req.on('data', (chunk) => {
      if (finished) return
      size += chunk.length
      if (size > maxBytes) {
        finished = true
        const error = new Error('Pacote de sincronização muito grande.')
        error.status = 413
        reject(error)
        req.resume()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (finished) return
      try {
        const raw = Buffer.concat(chunks).toString('utf8')
        resolve(raw ? JSON.parse(raw) : {})
      } catch (_) {
        const error = new Error('Pacote de sincronização inválido.')
        error.status = 400
        reject(error)
      }
    })
    req.on('error', (error) => {
      if (finished) return
      finished = true
      reject(error)
    })
  })
}

function requestJson({ hostname, port, path, method = 'GET', payload = null, timeoutMs = 900 }) {
  const body = payload == null ? '' : JSON.stringify(payload)
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname,
      port,
      path,
      method,
      headers: body
        ? {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': Buffer.byteLength(body),
          }
        : {},
    }, (res) => {
      const chunks = []
      let size = 0
      res.on('data', (chunk) => {
        size += chunk.length
        if (size <= MAX_HTTP_BODY_BYTES) chunks.push(chunk)
      })
      res.on('end', () => {
        if (size > MAX_HTTP_BODY_BYTES) {
          reject(new Error('Resposta de sincronização muito grande.'))
          return
        }
        const raw = Buffer.concat(chunks).toString('utf8')
        let data = {}
        try { data = raw ? JSON.parse(raw) : {} } catch (_) {}
        resolve({
          ok: (res.statusCode || 500) >= 200 && (res.statusCode || 500) < 300,
          status: res.statusCode || 500,
          data,
        })
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error('Tempo limite da sincronização esgotado.')))
    req.on('error', reject)
    if (body) req.write(body)
    req.end()
  })
}

function requestRaw({ hostname, port, path, body = '', timeoutMs = 900 }) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname,
      port,
      path,
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-ndjson; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      const chunks = []
      res.on('data', (chunk) => chunks.push(chunk))
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8')
        let data = {}
        try { data = raw ? JSON.parse(raw) : {} } catch (_) {}
        resolve({
          ok: (res.statusCode || 500) >= 200 && (res.statusCode || 500) < 300,
          status: res.statusCode || 500,
          data,
        })
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(new Error('Extensão VS Hook não respondeu.')))
    req.on('error', reject)
    if (body) req.write(body)
    req.end()
  })
}

function getBroadcastAddresses() {
  const addresses = new Set(['255.255.255.255'])
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (!entry || entry.internal || entry.family !== 'IPv4') continue
      const address = String(entry.address || '').split('.').map(Number)
      const mask = String(entry.netmask || '').split('.').map(Number)
      if (address.length !== 4 || mask.length !== 4 ||
          address.some((part) => !Number.isInteger(part)) ||
          mask.some((part) => !Number.isInteger(part))) continue
      const broadcast = address.map((part, index) => ((part & mask[index]) | (255 ^ mask[index])) & 255)
      addresses.add(broadcast.join('.'))
    }
  }
  return [...addresses]
}

function ipv4ToNumber(value) {
  const parts = String(value || '').split('.').map(Number)
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null
  return (((parts[0] << 24) >>> 0) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}

function numberToIpv4(value) {
  const number = Number(value) >>> 0
  return [number >>> 24, (number >>> 16) & 255, (number >>> 8) & 255, number & 255].join('.')
}

// Alternativa ao broadcast UDP para redes e firewalls que o bloqueiam. A
// busca continua inteiramente na LAN e tenta somente o /24 de cada interface
// local, usando a mesma porta TCP já utilizada pelo aplicativo do Diretor.
function getDirectDiscoveryAddresses() {
  const ownAddresses = new Set()
  const candidates = new Set()
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (!entry || entry.internal || entry.family !== 'IPv4') continue
      const own = ipv4ToNumber(entry.address)
      if (own == null) continue
      ownAddresses.add(numberToIpv4(own))
      const prefix = own & 0xffffff00
      for (let host = 1; host <= 254; host += 1) {
        candidates.add(numberToIpv4((prefix | host) >>> 0))
      }
    }
  }
  for (const own of ownAddresses) candidates.delete(own)
  return [...candidates]
}

function createTimecodeLanRelay(options = {}) {
  const nativeBridgePort = Number(options.nativeBridgePort) || 47830
  const discoveryPort = Math.max(1, Math.min(65535,
    Number(options.discoveryPort) || DISCOVERY_PORT))
  const discoveryTargetPort = Math.max(1, Math.min(65535,
    Number(options.discoveryTargetPort) || discoveryPort))
  const getDirectorPort = typeof options.getDirectorPort === 'function'
    ? options.getDirectorPort
    : () => 47831
  const getDeviceName = typeof options.getDeviceName === 'function'
    ? options.getDeviceName
    : () => os.hostname()
  const isLicenseActive = typeof options.isLicenseActive === 'function'
    ? options.isLicenseActive
    : () => true
  const listDirectDiscoveryAddresses = typeof options.getDirectDiscoveryAddresses === 'function'
    ? options.getDirectDiscoveryAddresses
    : getDirectDiscoveryAddresses
  const getDirectCableIp = typeof options.getDirectCableIp === 'function'
    ? options.getDirectCableIp
    : () => ''
  const instanceId = crypto.randomBytes(16).toString('hex')

  let socket = null
  let tickTimer = null
  let localStatus = null
  let localStatusAt = 0
  let lastStatusPollAt = 0
  let lastDiscoveryAt = 0
  let lastDirectDiscoveryAt = 0
  let directDiscoveryRunning = false
  let transmitterPeer = null
  let receiverSession = null
  let tickRunning = false
  let stopped = true
  let lastNotifiedPeer = ''
  let lastLocalActivityAt = 0

  function deviceName() {
    let value = ''
    try { value = getDeviceName() } catch (_) {}
    return safeName(value, os.hostname() || 'VS Hook')
  }

  function licenseIsActive() {
    try { return isLicenseActive() === true } catch (_) { return false }
  }

  function preferredCablePrefix() {
    let ip = ''
    try { ip = String(getDirectCableIp() || '').trim() } catch (_) {}
    const match = ip.match(/^(\d+\.\d+\.\d+)\.\d+$/)
    return match ? `${match[1]}.` : ''
  }

  function peerAddressAllowed(address) {
    const prefix = preferredCablePrefix()
    return !prefix || String(address || '').replace(/^::ffff:/, '').startsWith(prefix)
  }

  async function readLocalStatus(force = false) {
    const now = Date.now()
    if (!force && localStatus && now - localStatusAt < LOCAL_STATUS_INTERVAL_MS) return localStatus
    if (!force && now - lastStatusPollAt < 70) return localStatus
    lastStatusPollAt = now
    try {
      const result = await requestJson({
        hostname: '127.0.0.1',
        port: nativeBridgePort,
        path: '/timecode/status',
        timeoutMs: 500,
      })
      localStatus = result.ok && result.data && result.data.ok ? result.data : null
    } catch (_) {
      localStatus = null
    }
    localStatusAt = Date.now()
    return localStatus
  }

  async function sendLocalCommand(command) {
    try {
      const result = await requestJson({
        hostname: '127.0.0.1',
        port: nativeBridgePort,
        path: '/command',
        method: 'POST',
        payload: command,
        timeoutMs: 550,
      })
      return result.ok
    } catch (_) {
      return false
    }
  }

  async function notifyLocalPeer(connected, peerName = '') {
    const marker = connected ? `1:${safeName(peerName, 'VS Hook')}` : '0:'
    if (marker === lastNotifiedPeer) return
    if (await sendLocalCommand({
      type: 'timecode_peer_status',
      connected: !!connected,
      peerName: connected ? safeName(peerName, 'VS Hook') : '',
    })) {
      lastNotifiedPeer = marker
    }
  }

  function resetTransmitterPeer(notify = true) {
    transmitterPeer = null
    if (notify) notifyLocalPeer(false).catch(() => {})
  }

  function resetReceiverSession(notify = true) {
    receiverSession = null
    if (notify) notifyLocalPeer(false).catch(() => {})
  }

  function sendUdp(payload, address) {
    if (!socket) return
    const data = Buffer.from(JSON.stringify(payload), 'utf8')
    socket.send(data, 0, data.length, discoveryTargetPort, address, () => {})
  }

  function broadcastDiscovery(status) {
    const payload = {
      magic: DISCOVER_MAGIC,
      version: 1,
      code: String(status.code || ''),
      transmitterId: instanceId,
      transmitterName: deviceName(),
      mode: status.mode,
    }
    for (const address of getBroadcastAddresses()) sendUdp(payload, address)
  }

  async function pairWithReceiver(status, address, remotePort, receiver = {}) {
    if (!status || !['transmitter', 'project_sync'].includes(status.mode) || !isPairCode(status.code) ||
        transmitterPeer?.connected || stopped || !peerAddressAllowed(address)) return false
    try {
      const result = await requestJson({
        hostname: address,
        port: remotePort,
        path: '/timecode-link/pair',
        method: 'POST',
        payload: {
          code: status.code,
          transmitterId: instanceId,
          transmitterName: deviceName(),
          transmitterPort: Number(getDirectorPort()) || 47831,
          mode: status.mode,
        },
        timeoutMs: Number(receiver.timeoutMs) || 1000,
      })
      if (!result.ok || !result.data?.ok || !result.data?.token || transmitterPeer?.connected || stopped) return false
      transmitterPeer = {
        address,
        port: remotePort,
        receiverId: String(result.data.receiverId || receiver.id || ''),
        name: safeName(result.data.receiverName || receiver.name, 'Receiver'),
        token: String(result.data.token),
        lastSequence: 0,
        failures: 0,
        connected: true,
      }
      if (status.mode === 'project_sync') {
        receiverSession = {
          token: String(result.data.token),
          code: String(status.code),
          transmitterId: String(result.data.receiverId || receiver.id || ''),
          name: safeName(result.data.receiverName || receiver.name, 'VS Hook'),
          lastSequence: 0,
          lastSeenAt: Date.now(),
        }
      }
      await notifyLocalPeer(true, transmitterPeer.name)
      return true
    } catch (_) {
      return false
    }
  }

  async function acceptOffer(message, rinfo) {
    const status = await readLocalStatus()
    if (!status || !['transmitter', 'project_sync'].includes(status.mode) || !isPairCode(status.code)) return
    if (String(message.code || '') !== String(status.code)) return
    if (String(message.transmitterId || '') !== instanceId) return
    const remotePort = Math.max(1, Math.min(65535, Number(message.port) || 47831))
    await pairWithReceiver(status, rinfo.address, remotePort, {
      id: String(message.receiverId || ''),
      name: message.receiverName,
    })
  }

  async function discoverReceiverOverTcp(status) {
    let addresses = []
    try { addresses = [...new Set(listDirectDiscoveryAddresses())] } catch (_) {}
    const ports = [...new Set([
      Math.max(1, Math.min(65535, Number(getDirectorPort()) || 47831)),
      47831,
    ])]
    for (let offset = 0; offset < addresses.length && !transmitterPeer?.connected && !stopped; offset += DIRECT_DISCOVERY_BATCH_SIZE) {
      const batch = addresses.slice(offset, offset + DIRECT_DISCOVERY_BATCH_SIZE)
      await Promise.allSettled(batch.flatMap((address) => ports.map((port) =>
        pairWithReceiver(status, address, port, { timeoutMs: DIRECT_DISCOVERY_TIMEOUT_MS })
      )))
    }
  }

  async function handleUdpMessage(buffer, rinfo) {
    let message = null
    try { message = JSON.parse(buffer.toString('utf8')) } catch (_) { return }
    if (!message || typeof message !== 'object') return

    if (message.magic === DISCOVER_MAGIC) {
      if (String(message.transmitterId || '') === instanceId || !licenseIsActive()) return
      const status = await readLocalStatus()
      if (!status || !['receive', 'project_sync'].includes(status.mode) || !isPairCode(status.code)) return
      if (String(message.code || '') !== String(status.code)) return
      if (status.mode === 'project_sync' &&
          String(message.transmitterId || '').localeCompare(instanceId) >= 0) return
      sendUdp({
        magic: OFFER_MAGIC,
        version: 1,
        code: status.code,
        transmitterId: String(message.transmitterId || ''),
        receiverId: instanceId,
        receiverName: deviceName(),
        port: Number(getDirectorPort()) || 47831,
      }, rinfo.address)
      return
    }

    if (message.magic === OFFER_MAGIC) {
      if (String(message.receiverId || '') === instanceId || !licenseIsActive()) return
      await acceptOffer(message, rinfo)
    }
  }

  async function transmitTick(status) {
    const now = Date.now()
    if (!transmitterPeer || !transmitterPeer.connected) {
      if (now - lastDiscoveryAt >= DISCOVERY_INTERVAL_MS) {
        lastDiscoveryAt = now
        broadcastDiscovery(status)
      }
      if (!directDiscoveryRunning && now - lastDirectDiscoveryAt >= DIRECT_DISCOVERY_INTERVAL_MS) {
        lastDirectDiscoveryAt = now
        directDiscoveryRunning = true
        discoverReceiverOverTcp(status)
          .catch(() => {})
          .finally(() => { directDiscoveryRunning = false })
      }
      return
    }

    try {
      const outboxResult = await requestJson({
        hostname: '127.0.0.1',
        port: nativeBridgePort,
        path: '/timecode/outbox',
        method: 'POST',
        payload: { after: transmitterPeer.lastSequence },
        timeoutMs: 500,
      })
      if (!outboxResult.ok || !outboxResult.data?.ok) throw new Error('Outbox indisponível.')
      const packet = outboxResult.data
      const events = Array.isArray(packet.events) ? packet.events.slice(0, 256) : []
      if (events.length > 0) lastLocalActivityAt = Date.now()
      const remoteResult = await requestJson({
        hostname: transmitterPeer.address,
        port: transmitterPeer.port,
        path: '/timecode-link/events',
        method: 'POST',
        payload: {
          token: transmitterPeer.token,
          code: status.code,
          transmitterId: instanceId,
          transmitterName: deviceName(),
          events,
          transport: packet.transport || status.transport || {},
        },
        timeoutMs: 800,
      })
      if (!remoteResult.ok || !remoteResult.data?.ok) throw new Error('Receiver indisponível.')
      const acknowledged = Number(remoteResult.data.acceptedSequence)
      if (Number.isFinite(acknowledged) && acknowledged >= transmitterPeer.lastSequence) {
        transmitterPeer.lastSequence = acknowledged
      }
      transmitterPeer.failures = 0
    } catch (_) {
      if (!transmitterPeer) return
      transmitterPeer.failures += 1
      if (transmitterPeer.failures >= 3) resetTransmitterPeer(true)
    }
  }

  async function tick() {
    if (stopped || tickRunning) return
    tickRunning = true
    try {
      const status = await readLocalStatus()
      if (!licenseIsActive() || !status || !isPairCode(status.code)) {
        if (transmitterPeer) resetTransmitterPeer(true)
        if (receiverSession) resetReceiverSession(true)
        return
      }

      if (status.mode === 'transmitter') {
        if (receiverSession) resetReceiverSession(false)
        await transmitTick(status)
      } else if (status.mode === 'receive') {
        if (transmitterPeer) resetTransmitterPeer(false)
        if (receiverSession && Date.now() - receiverSession.lastSeenAt > RECEIVER_TIMEOUT_MS) {
          resetReceiverSession(true)
        }
      } else if (status.mode === 'project_sync') {
        await transmitTick(status)
        if (receiverSession && Date.now() - receiverSession.lastSeenAt > RECEIVER_TIMEOUT_MS) {
          resetReceiverSession(true)
        }
      } else {
        if (transmitterPeer) resetTransmitterPeer(true)
        if (receiverSession) resetReceiverSession(true)
      }
    } finally {
      tickRunning = false
    }
  }

  async function handlePair(req, res) {
    if (!licenseIsActive()) {
      sendJson(res, 403, { ok: false, error: 'Licença VS Hook inativa.' })
      return
    }
    const payload = await readJsonBody(req, 64 * 1024)
    if (!peerAddressAllowed(req.socket?.remoteAddress)) {
      sendJson(res, 409, { ok: false, error: 'A conexão redundante deve usar o cabo configurado.' })
      return
    }
    const status = await readLocalStatus(true)
    const code = String(payload.code || '').trim()
    if (!status || !['receive', 'project_sync'].includes(status.mode) ||
        !isPairCode(status.code) || code !== String(status.code)) {
      sendJson(res, 403, { ok: false, error: 'Código de pareamento inválido.' })
      return
    }
    const transmitterId = String(payload.transmitterId || '').trim()
    if (!transmitterId || transmitterId === instanceId) {
      sendJson(res, 400, { ok: false, error: 'Transmissor inválido.' })
      return
    }
    if (status.mode === 'project_sync' && transmitterId.localeCompare(instanceId) >= 0) {
      sendJson(res, 409, { ok: false, error: 'O outro computador iniciará o pareamento.' })
      return
    }
    const sameTransmitter = receiverSession &&
      receiverSession.code === code &&
      receiverSession.transmitterId === transmitterId
    const token = sameTransmitter
      ? receiverSession.token
      : crypto.randomBytes(32).toString('hex')
    receiverSession = {
      token,
      code,
      transmitterId,
      name: safeName(payload.transmitterName, 'Transmitter'),
      lastSequence: sameTransmitter ? receiverSession.lastSequence : 0,
      lastSeenAt: Date.now(),
    }
    if (status.mode === 'project_sync') {
      const remoteAddress = String(req.socket?.remoteAddress || '').replace(/^::ffff:/, '')
      const remotePort = Math.max(1, Math.min(65535,
        Number(payload.transmitterPort) || 47831))
      transmitterPeer = {
        address: remoteAddress,
        port: remotePort,
        receiverId: transmitterId,
        name: receiverSession.name,
        token,
        lastSequence: 0,
        failures: 0,
        connected: true,
      }
    }
    await notifyLocalPeer(true, receiverSession.name)
    sendJson(res, 200, {
      ok: true,
      token,
      receiverId: instanceId,
      receiverName: deviceName(),
    })
  }

  function tokenMatches(left, right) {
    const a = Buffer.from(String(left || ''), 'utf8')
    const b = Buffer.from(String(right || ''), 'utf8')
    return a.length > 0 && a.length === b.length && crypto.timingSafeEqual(a, b)
  }

  async function handleEvents(req, res) {
    const payload = await readJsonBody(req)
    const status = await readLocalStatus(true)
    if (!licenseIsActive() || !status || !['receive', 'project_sync'].includes(status.mode) ||
        !receiverSession || String(payload.code || '') !== String(status.code) ||
        String(payload.transmitterId || '') !== receiverSession.transmitterId ||
        !tokenMatches(payload.token, receiverSession.token)) {
      sendJson(res, 403, { ok: false, error: 'Pareamento expirado.' })
      return
    }

    const incoming = Array.isArray(payload.events) ? payload.events.slice(0, 256) : []
    const commands = []
    let acceptedSequence = receiverSession.lastSequence
    for (const event of incoming) {
      const sequence = Math.max(0, Math.trunc(Number(event?.sequence) || 0))
      if (sequence <= receiverSession.lastSequence || !event?.command || typeof event.command !== 'object') continue
      commands.push(JSON.stringify({
        ...event.command,
        __vshookLanRemote: true,
      }))
      acceptedSequence = Math.max(acceptedSequence, sequence)
    }
    const transport = payload.transport && typeof payload.transport === 'object'
      ? payload.transport
      : {}
    const localActionHasPriority = status.mode === 'project_sync' &&
      commands.length === 0 && Date.now() - lastLocalActivityAt < 700
    if (!localActionHasPriority) {
      commands.push(JSON.stringify({
        type: 'timecode_transport_sync',
        playState: Math.max(0, Math.trunc(Number(transport.playState) || 0)),
        position: Math.max(0, Number(transport.position) || 0),
        sequence: Math.max(0, Math.trunc(Number(transport.sequence) || 0)),
        sampledAtMs: Math.trunc(Number(transport.sampledAtMs) || 0),
        __vshookLanRemote: true,
      }))
    }

    const localResult = await requestRaw({
      hostname: '127.0.0.1',
      port: nativeBridgePort,
      path: '/timecode/inbox',
      body: commands.join('\n'),
      timeoutMs: 700,
    })
    if (!localResult.ok || !localResult.data?.ok) {
      sendJson(res, 503, { ok: false, error: 'Extensão VS Hook local indisponível.' })
      return
    }
    receiverSession.lastSequence = acceptedSequence
    receiverSession.lastSeenAt = Date.now()
    sendJson(res, 200, { ok: true, acceptedSequence })
  }

  async function handleHttp(req, res, parsedUrl) {
    const pathname = String(parsedUrl?.pathname || '')
    if (!pathname.startsWith('/timecode-link/')) return false
    try {
      if (req.method === 'POST' && pathname === '/timecode-link/pair') {
        await handlePair(req, res)
      } else if (req.method === 'POST' && pathname === '/timecode-link/events') {
        await handleEvents(req, res)
      } else {
        sendJson(res, 404, { ok: false, error: 'Rota Timecode LAN não encontrada.' })
      }
    } catch (error) {
      sendJson(res, Math.max(400, Math.min(599, Number(error?.status) || 500)), {
        ok: false,
        error: error?.message || 'Falha na sincronização Timecode LAN.',
      })
    }
    return true
  }

  async function start() {
    if (!stopped) return
    stopped = false
    socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    socket.on('message', (message, rinfo) => {
      handleUdpMessage(message, rinfo).catch(() => {})
    })
    socket.on('error', () => {})
    await new Promise((resolve) => {
      let resolved = false
      const finish = () => {
        if (resolved) return
        resolved = true
        resolve()
      }
      socket.once('error', finish)
      socket.bind(discoveryPort, '0.0.0.0', () => {
        try { socket.setBroadcast(true) } catch (_) {}
        finish()
      })
    })
    tickTimer = setInterval(() => tick().catch(() => {}), TRANSMIT_INTERVAL_MS)
    tick().catch(() => {})
  }

  async function stop() {
    stopped = true
    if (tickTimer) clearInterval(tickTimer)
    tickTimer = null
    resetTransmitterPeer(false)
    resetReceiverSession(false)
    localStatus = null
    lastNotifiedPeer = ''
    directDiscoveryRunning = false
    const currentSocket = socket
    socket = null
    if (!currentSocket) return
    await new Promise((resolve) => {
      try { currentSocket.close(() => resolve()) } catch (_) { resolve() }
    })
  }

  return { start, stop, handleHttp }
}

module.exports = { createTimecodeLanRelay }
