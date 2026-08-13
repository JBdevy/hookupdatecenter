const crypto = require('crypto')
const dgram = require('dgram')
const fs = require('fs')
const http = require('http')
const os = require('os')
const pathUtil = require('path')

const DISCOVERY_PORT = 47833
const DISCOVER_MAGIC = 'VSHOOK_TIMECODE_DISCOVER_V1'
const OFFER_MAGIC = 'VSHOOK_TIMECODE_OFFER_V1'
const PROJECT_SYNC_PROTOCOL_VERSION = 2
const MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024
const LOCAL_STATUS_INTERVAL_MS = 18
const TRANSMIT_INTERVAL_MS = 20
const DISCOVERY_INTERVAL_MS = 650
const DIRECT_DISCOVERY_INTERVAL_MS = 3000
const DIRECT_DISCOVERY_TIMEOUT_MS = 260
const DIRECT_DISCOVERY_BATCH_SIZE = 24
const RECEIVER_TIMEOUT_MS = 3000
const IDLE_LINK_HEARTBEAT_MS = 400
const PROJECT_SYNC_PREFLIGHT_TIMEOUT_MS = 6500
const PROJECT_SYNC_PREFLIGHT_POLL_MS = 80
const PROJECT_SYNC_PREFLIGHT_TTL_MS = 15000
const PROJECT_SYNC_APPLY_TTL_MS = 30 * 60 * 1000
const PROJECT_SYNC_BUNDLE_CHUNK_BYTES = 1024 * 1024
const PROJECT_SYNC_BUNDLE_MANIFEST_BYTES = 8 * 1024 * 1024
const PROJECT_SYNC_BUNDLE_MAX_FILES = 16384
const PROJECT_SYNC_BUNDLE_MAX_FILE_BYTES = 64 * 1024 * 1024 * 1024
const PROJECT_SYNC_BUNDLE_MAX_TOTAL_BYTES = 256 * 1024 * 1024 * 1024
const PROJECT_SYNC_BUNDLE_PROGRESS_INTERVAL_MS = 120
const PROJECT_SYNC_STAGING_TTL_MS = 24 * 60 * 60 * 1000
const PROJECT_SYNC_STAGING_CLEANUP_INTERVAL_MS = 60 * 60 * 1000
const PROJECT_SYNC_STAGING_QUOTA_BYTES = 64 * 1024 * 1024 * 1024
const PROJECT_SYNC_MIN_FREE_BYTES = 1024 * 1024 * 1024

// A ponta LAN e um servidor Node e aceita conexao persistente. Reutilizar o
// socket remove o custo de um novo TCP handshake em cada pulso do Project Sync.
const lanHttpAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 1000,
  maxSockets: 32,
  maxFreeSockets: 8,
})

function isPairCode(value) {
  return /^\d{6}$/.test(String(value || '').trim())
}

function safeName(value, fallback) {
  const normalized = String(value || '').trim().replace(/[\u0000-\u001f\u007f]/g, '')
  return normalized.slice(0, 80) || fallback
}

function safeSequence(value, fallback = 0) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0
    ? number
    : fallback
}

function safeBundleId(value) {
  const id = String(value || '').trim()
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id) ? id : ''
}

function safeSha256(value) {
  const digest = String(value || '').trim().toLowerCase()
  return /^[a-f0-9]{64}$/.test(digest) ? digest : ''
}

function safeBundleRelativePath(value) {
  const raw = String(value || '').trim().replace(/\\/g, '/')
  if (!raw || raw.length > 1024 || raw.includes('\u0000') ||
      raw.startsWith('/') || raw.startsWith('//') ||
      /^[A-Za-z]:/.test(raw)) return ''
  const parts = raw.split('/')
  const windowsReserved = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i
  if (parts.some((part) => !part || part === '.' || part === '..' ||
      part.length > 255 || /[\u0000-\u001f<>:"|?*]/.test(part) ||
      /[. ]$/.test(part) || windowsReserved.test(part))) return ''
  return parts.join('/')
}

function normalizePeerAddress(value) {
  return String(value || '').trim().replace(/^::ffff:/, '')
}

function resolveInside(root, relativePath) {
  const safeRelative = safeBundleRelativePath(relativePath)
  if (!safeRelative) return ''
  const absoluteRoot = pathUtil.resolve(root)
  const resolved = pathUtil.resolve(absoluteRoot,
    ...safeRelative.split('/'))
  const rootPrefix = absoluteRoot.endsWith(pathUtil.sep)
    ? absoluteRoot
    : `${absoluteRoot}${pathUtil.sep}`
  const caseFold = process.platform === 'win32'
    ? (text) => text.toLowerCase()
    : (text) => text
  return caseFold(resolved).startsWith(caseFold(rootPrefix)) ? resolved : ''
}

async function readLimitedJsonFile(filename, maxBytes) {
  const stat = await fs.promises.stat(filename)
  if (!stat.isFile() || stat.size <= 0 || stat.size > maxBytes) {
    throw new Error('Descritor do pacote Project Sync inválido.')
  }
  const raw = await fs.promises.readFile(filename, 'utf8')
  try {
    return JSON.parse(raw)
  } catch (_) {
    throw new Error('Descritor do pacote Project Sync corrompido.')
  }
}

async function sha256File(filename) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256')
    const stream = fs.createReadStream(filename)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('error', reject)
    stream.on('end', () => resolve(hash.digest('hex')))
  })
}

async function assertRegularFileInside(root, filename) {
  const absoluteRoot = pathUtil.resolve(root)
  const resolved = pathUtil.resolve(filename)
  const relative = pathUtil.relative(absoluteRoot, resolved)
  if (!relative || relative.startsWith('..') || pathUtil.isAbsolute(relative)) {
    throw new Error('Arquivo fora do pacote Project Sync.')
  }
  let cursor = absoluteRoot
  for (const component of relative.split(pathUtil.sep)) {
    cursor = pathUtil.join(cursor, component)
    const stat = await fs.promises.lstat(cursor)
    if (stat.isSymbolicLink()) {
      throw new Error('Links não são permitidos no pacote Project Sync.')
    }
  }
  const stat = await fs.promises.stat(resolved)
  if (!stat.isFile()) throw new Error('Arquivo inválido no pacote Project Sync.')
  return stat
}

async function directorySizeNoFollow(root, limitBytes = Number.MAX_SAFE_INTEGER) {
  let total = 0
  const pending = [pathUtil.resolve(root)]
  while (pending.length > 0) {
    const directory = pending.pop()
    let entries = []
    try {
      entries = await fs.promises.readdir(directory, { withFileTypes: true })
    } catch (error) {
      if (error?.code === 'ENOENT') continue
      throw error
    }
    for (const entry of entries) {
      const filename = pathUtil.join(directory, entry.name)
      if (entry.isSymbolicLink()) continue
      if (entry.isDirectory()) pending.push(filename)
      else if (entry.isFile()) {
        const stat = await fs.promises.lstat(filename)
        total += stat.size
        if (total > limitBytes) return total
      }
    }
  }
  return total
}

async function removeTreeNoFollow(root, target) {
  const absoluteRoot = pathUtil.resolve(root)
  const absoluteTarget = pathUtil.resolve(target)
  const relative = pathUtil.relative(absoluteRoot, absoluteTarget)
  if (!relative || relative.startsWith('..') || pathUtil.isAbsolute(relative)) {
    throw new Error('Limpeza fora do staging recusada.')
  }
  let stat
  try { stat = await fs.promises.lstat(absoluteTarget) } catch (error) {
    if (error?.code === 'ENOENT') return
    throw error
  }
  if (stat.isSymbolicLink() || stat.isFile()) {
    await fs.promises.unlink(absoluteTarget)
    return
  }
  if (!stat.isDirectory()) {
    await fs.promises.unlink(absoluteTarget)
    return
  }
  const entries = await fs.promises.readdir(absoluteTarget)
  for (const entry of entries) {
    await removeTreeNoFollow(absoluteRoot,
      pathUtil.join(absoluteTarget, entry))
  }
  await fs.promises.rmdir(absoluteTarget)
}

function descriptorContainsAbsolutePath(value, key = '', depth = 0) {
  if (depth > 20) return true
  if (typeof value === 'string') {
    if (/^(?:[A-Za-z]:[\\/]|\\\\|\/)/.test(value)) return true
    if (/^(?:descriptorPath|sourcePath|absolutePath|stagingRoot)$/i.test(key)) {
      return true
    }
    return false
  }
  if (Array.isArray(value)) {
    return value.some((entry) =>
      descriptorContainsAbsolutePath(entry, key, depth + 1))
  }
  if (value && typeof value === 'object') {
    return Object.entries(value).some(([childKey, childValue]) =>
      /^(?:__proto__|prototype|constructor)$/i.test(childKey) ||
      descriptorContainsAbsolutePath(childValue, childKey, depth + 1))
  }
  return false
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

function requestJson({ hostname, port, path, method = 'GET', payload = null,
  timeoutMs = 900, maxResponseBytes = MAX_HTTP_BODY_BYTES }) {
  const body = payload == null ? '' : JSON.stringify(payload)
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname,
      port,
      path,
      method,
      agent: hostname === '127.0.0.1' || hostname === 'localhost'
        ? undefined
        : lanHttpAgent,
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
        if (size <= maxResponseBytes) chunks.push(chunk)
      })
      res.on('end', () => {
        if (size > maxResponseBytes) {
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

function requestBinary({ hostname, port, path, payload = null,
  timeoutMs = 30000, maxResponseBytes = PROJECT_SYNC_BUNDLE_CHUNK_BYTES }) {
  const body = payload == null ? '' : JSON.stringify(payload)
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname,
      port,
      path,
      method: 'POST',
      agent: hostname === '127.0.0.1' || hostname === 'localhost'
        ? undefined
        : lanHttpAgent,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      const chunks = []
      let size = 0
      res.on('data', (chunk) => {
        size += chunk.length
        if (size <= maxResponseBytes) chunks.push(chunk)
      })
      res.on('end', () => {
        if (size > maxResponseBytes) {
          reject(new Error('Bloco do pacote Project Sync excedeu o limite.'))
          return
        }
        const data = Buffer.concat(chunks)
        if ((res.statusCode || 500) < 200 || (res.statusCode || 500) >= 300) {
          let message = 'Falha ao transferir arquivo do Project Sync.'
          try {
            message = JSON.parse(data.toString('utf8')).error || message
          } catch (_) {}
          const error = new Error(message)
          error.status = res.statusCode || 500
          reject(error)
          return
        }
        resolve({
          ok: true,
          status: res.statusCode || 200,
          headers: res.headers || {},
          data,
        })
      })
    })
    req.setTimeout(timeoutMs, () => req.destroy(
      new Error('Tempo limite ao transferir o pacote Project Sync.')))
    req.on('error', reject)
    if (body) req.write(body)
    req.end()
  })
}

function sendBinary(res, status, data, headers = {}) {
  const body = Buffer.isBuffer(data) ? data : Buffer.from(data || '')
  res.writeHead(status, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    ...headers,
  })
  res.end(body)
}

function requestRaw({ hostname, port, path, body = '', timeoutMs = 900 }) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname,
      port,
      path,
      method: 'POST',
      agent: hostname === '127.0.0.1' || hostname === 'localhost'
        ? undefined
        : lanHttpAgent,
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
  // main.js deve devolver uma pasta privada e persistente da Hook Center,
  // atualmente app.getPath('userData')/project-sync-staging. O relay nunca
  // aceita uma raiz de staging vinda da rede.
  const getProjectSyncStagingDir =
    typeof options.getProjectSyncStagingDir === 'function'
      ? options.getProjectSyncStagingDir
      : () => ''
  const instanceId = crypto.randomBytes(16).toString('hex')

  let socket = null
  let tickTimer = null
  let localStatus = null
  let localStatusAt = 0
  let lastStatusPollAt = 0
  let localStatusRequest = null
  let lastDiscoveryAt = 0
  let lastDirectDiscoveryAt = 0
  let directDiscoveryRunning = false
  let transmitterPeer = null
  let receiverSession = null
  let tickRunning = false
  let stopped = true
  let lastNotifiedPeer = ''
  let pendingProjectSyncPreflight = null
  let projectSyncPairAttempt = null
  let projectSyncApplyPeer = null
  let projectSyncApplySession = null
  let projectSyncExportBundle = null
  let projectSyncBundlePullPromise = null
  let lastProjectSyncApplyKey = ''
  let relayLifecycleSequence = 0
  let lastProjectSyncStagingCleanupAt = 0
  let projectSyncStagingCleanupPromise = null
  const projectSyncProtocolNotices = new Set()
  function projectSyncRole(status) {
    const role = String(status?.projectSyncRole || '').trim().toLowerCase()
    return role === 'primary' || role === 'secondary' ? role : ''
  }

  function statusCanTransmit(status) {
    return status?.mode === 'transmitter' ||
      (status?.mode === 'project_sync' &&
       projectSyncRole(status) === 'primary')
  }

  function statusCanReceive(status) {
    return status?.mode === 'receive' ||
      (status?.mode === 'project_sync' &&
       projectSyncRole(status) === 'secondary')
  }

  function projectSyncRolesMatch(senderRole, receiverRole) {
    return String(senderRole || '').trim().toLowerCase() === 'primary' &&
      String(receiverRole || '').trim().toLowerCase() === 'secondary'
  }

  function projectSyncManifestRevision(status) {
    return String(status?.manifestRevision || '').trim().slice(0, 256)
  }

  function projectSyncStructuralRevision(status) {
    // Builds novas separam estrutura de configuracao. O fallback conserva o
    // pareamento com a build de transicao, embora nela uma mudanca visual ainda
    // exija novo preflight por nao existir uma revisao estrutural separada.
    return String(
      status?.structuralManifestRevision ||
      status?.projectStructuralRevision ||
      status?.manifestRevision || '').trim().slice(0, 256)
  }

  function projectSyncManifestChangedDiff(side, previousRevision,
    currentRevision) {
    return {
      schemaVersion: 1,
      ready: false,
      differences: [{
        category: 'project',
        severity: 'blocking',
        kind: 'manifest_changed',
        side: side === 'primary' ? 'primary' : 'secondary',
        previousRevision: String(previousRevision || ''),
        currentRevision: String(currentRevision || ''),
        message: side === 'primary'
          ? 'O projeto do PC A mudou. Faça o preflight novamente.'
          : 'O projeto do PC B mudou. Faça o preflight novamente.',
      }],
    }
  }

  function projectSyncProtocolMismatchDiff(detail = '') {
    const suffix = String(detail || '').trim()
    return {
      schemaVersion: 1,
      ready: false,
      configApplied: false,
      differenceCount: 1,
      structuralDifferenceCount: 1,
      configDifferenceCount: 0,
      truncated: false,
      summary: { project: 1 },
      message: 'A Hook Center do outro computador esta desatualizada. ' +
        'Atualize e reinicie a Hook Center nos dois PCs.' +
        (suffix ? ` ${suffix}` : ''),
      differences: [{
        category: 'project',
        severity: 'blocking',
        kind: 'incompatible_hook_center_protocol',
        id: 'hook_center_protocol',
        primary: `Project Sync v${PROJECT_SYNC_PROTOCOL_VERSION}`,
        secondary: 'Protocolo antigo ou incompleto',
      }],
    }
  }

  async function notifyProjectSyncProtocolMismatch(status, address, detail = '') {
    if (status?.mode !== 'project_sync' ||
        projectSyncRole(status) !== 'primary') return
    const key = [
      String(status.sessionId || ''),
      projectSyncStructuralRevision(status),
      normalizePeerAddress(address),
    ].join('|')
    if (projectSyncProtocolNotices.has(key)) return
    projectSyncProtocolNotices.add(key)
    const requestId = projectSyncPairRequestId(status) ||
      newPreflightRequestId()
    await sendLocalCommand({
      type: 'project_sync_preflight',
      role: 'primary',
      requestId,
      ready: false,
      diff: projectSyncProtocolMismatchDiff(detail),
    })
  }

  function isRecognizableLegacyRelayResponse(result) {
    const error = String(result?.data?.error || '').toLowerCase()
    return result?.status === 413 ||
      error.includes('timecode lan') ||
      error.includes('pacote de sincroniza') ||
      error.includes('pareamento')
  }

  async function projectSyncCapabilities(
    status, address, port, reportMismatch = false) {
    let result = null
    try {
      result = await requestJson({
        hostname: address,
        port,
        path: '/timecode-link/capabilities',
        method: 'POST',
        payload: {
          mode: 'project_sync',
          protocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
        },
        timeoutMs: 500,
      })
    } catch (_) {
      return false
    }
    const compatible = result.ok && result.data?.ok === true &&
      Number(result.data.projectSyncProtocolVersion) ===
        PROJECT_SYNC_PROTOCOL_VERSION &&
      result.data.projectSyncPreflight === true
    if (!compatible && reportMismatch &&
        isRecognizableLegacyRelayResponse(result)) {
      await notifyProjectSyncProtocolMismatch(status, address)
    }
    return compatible
  }

  function wait(delayMs) {
    return new Promise((resolve) => setTimeout(resolve, delayMs))
  }

  function newPreflightRequestId() {
    return crypto.randomBytes(16).toString('hex')
  }

  function projectSyncPairRequestId(status) {
    const sessionId = String(status?.sessionId || '').trim()
    const structuralRevision = projectSyncStructuralRevision(status)
    if (!projectSyncPairAttempt ||
        projectSyncPairAttempt.sessionId !== sessionId ||
        projectSyncPairAttempt.structuralRevision !== structuralRevision ||
        Date.now() - projectSyncPairAttempt.createdAt >
          PROJECT_SYNC_PREFLIGHT_TIMEOUT_MS + 1000) {
      projectSyncPairAttempt = {
        requestId: newPreflightRequestId(),
        sessionId,
        structuralRevision,
        createdAt: Date.now(),
      }
    }
    return projectSyncPairAttempt.requestId
  }

  function finishProjectSyncPairAttempt(requestId) {
    if (projectSyncPairAttempt?.requestId === requestId) {
      projectSyncPairAttempt = null
    }
  }

  function safePreflightRequestId(value) {
    const requestId = String(value || '').trim().toLowerCase()
    return /^[a-f0-9]{16,128}$/.test(requestId) ? requestId : ''
  }

  function statusPreflightRequestId(status) {
    // projectSyncPreflightRequestId e o nome atual. O segundo nome permite que
    // uma build de transicao da extensao converse com a mesma Hook Center.
    return safePreflightRequestId(
      status?.projectSyncPreflightRequestId || status?.projectSyncRequestId)
  }

  function preflightResultFromStatus(status, requestId) {
    if (!status || statusPreflightRequestId(status) !== requestId ||
        typeof status.projectSyncReady !== 'boolean') return null
    return {
      ready: status.projectSyncReady === true,
      diff: status.projectSyncDiff || null,
      manifestRevision: String(status.manifestRevision || ''),
    }
  }

  function transportAudioHealthy(status, transport = null) {
    const candidates = [
      transport?.audioHealthy,
      status?.audioHealthy,
      status?.audioDeviceAvailable,
    ]
    for (const value of candidates) {
      if (typeof value === 'boolean') return value
    }
    // Compatibilidade com builds anteriores da extensao, que nao publicavam o
    // diagnostico da placa. Nelas o comportamento tradicional continua igual.
    return true
  }

  function transportSnapshot(transport) {
    if (!transport || typeof transport !== 'object') return null
    return {
      sequence: safeSequence(transport.sequence),
      controlSequence: safeSequence(transport.controlSequence),
      playState: Math.max(0,
        Math.trunc(Number(transport.playState) || 0)),
      position: Math.max(0, Number(transport.position) || 0),
      sampledAtMs: Math.trunc(Number(transport.sampledAtMs) || 0),
    }
  }

  function projectSyncTransportForSend(status, peer, transport) {
    if (status?.mode !== 'project_sync') return transport
    const healthy = transportAudioHealthy(status, transport)
    const snapshot = transportSnapshot(transport)
    if (!snapshot) return null
    const observedControlSequence = Number.isFinite(
      peer.lastObservedControlSequence)
      ? peer.lastObservedControlSequence
      : snapshot.controlSequence
    const explicitControl =
      snapshot.controlSequence > observedControlSequence
    peer.lastObservedControlSequence = Math.max(
      observedControlSequence, snapshot.controlSequence)
    if (!healthy) {
      const previous = peer.lastHealthyTransport
      // Contrato com a extensão: controlSequence sobe no hook da ação local,
      // antes que um Stop possa fechar a placa. Assim um Stop intencional ainda
      // atravessa uma única vez; queda física sem gesto mantém a revisão e é
      // bloqueada para o PC B/SW8.
      peer.audioHealthy = false
      if (!explicitControl) return null
      peer.lastHealthyTransport = snapshot
      peer.resumeControlSequenceFloor = null
      return {
        ...transport,
        explicitControl: true,
      }
    }

    if (peer.audioHealthy === false) {
      peer.audioHealthy = true
      const previous = peer.lastHealthyTransport
      // Se a placa derrubou o transporte no PC A, nao propaga esse Stop quando
      // ela volta. O B permanece tocando ate uma nova acao explicita do usuario.
      const previousActive = previous && previous.playState !== 0 &&
        (previous.playState & 2) !== 2
      const elapsedSec = previous && previous.sampledAtMs > 0 &&
          snapshot.sampledAtMs > 0
        ? Math.max(0, Math.min(30,
            (snapshot.sampledAtMs - previous.sampledAtMs) / 1000))
        : 0
      const expectedPosition = previous
        ? previous.position + (previousActive ? elapsedSec : 0)
        : snapshot.position
      const resumedContinuously = !!previous &&
        previous.playState === snapshot.playState &&
        Math.abs(snapshot.position - expectedPosition) <= 0.20
      if (!resumedContinuously) {
        peer.resumeControlSequenceFloor = snapshot.controlSequence
        return null
      }
    }
    if (Number.isFinite(peer.resumeControlSequenceFloor)) {
      if (snapshot.controlSequence <= peer.resumeControlSequenceFloor) {
        return null
      }
      peer.resumeControlSequenceFloor = null
    }
    peer.lastHealthyTransport = snapshot
    return transport
  }

  function projectSyncTransportForReceive(session, status, payload, transport) {
    if (status?.mode !== 'project_sync') return transport
    if (!transport) return null
    const healthy = transportAudioHealthy(payload, transport)
    const explicitControl = transport.explicitControl === true
    if (!healthy && !explicitControl) return null
    const current = transportSnapshot(transport)
    if (!current) return null
    const previous = session.lastSourceTransport
    if (!previous) {
      session.lastSourceTransport = current
      session.lastControlSequence = current.controlSequence
      return transport
    }
    if (current.controlSequence < session.lastControlSequence) return null
    if (explicitControl &&
        current.controlSequence <= session.lastControlSequence) return null
    if (current.controlSequence === session.lastControlSequence) {
      // O controlSequence e a prova de intencao. Sem ele, uma mudanca de
      // play/pause/stop ou um salto brusco pode ser apenas falha da placa A.
      if (current.playState !== previous.playState) return null
      const previousActive = previous.playState !== 0 &&
        (previous.playState & 2) !== 2
      const elapsedSec = previous.sampledAtMs > 0 && current.sampledAtMs > 0
        ? Math.max(0, Math.min(5,
            (current.sampledAtMs - previous.sampledAtMs) / 1000))
        : 0
      const expectedPosition = previous.position +
        (previousActive ? elapsedSec : 0)
      if (Math.abs(current.position - expectedPosition) > 0.20) return null
    }
    session.lastSourceTransport = current
    session.lastControlSequence = current.controlSequence
    return transport
  }

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

  function projectSyncBundlePeerAllowed(address) {
    const prefix = preferredCablePrefix()
    return !!prefix && normalizePeerAddress(address).startsWith(prefix)
  }

  async function readLocalStatus(force = false) {
    const now = Date.now()
    if (!force && localStatus && now - localStatusAt < LOCAL_STATUS_INTERVAL_MS) return localStatus
    if (!force && now - lastStatusPollAt < 12) return localStatus
    // Serializa leituras concorrentes. Em especial, o poll de preflight nao
    // pode ser sobrescrito depois por uma requisicao antiga iniciada pelo tick.
    if (localStatusRequest) {
      try { await localStatusRequest } catch (_) {}
      if (!force && localStatus &&
          Date.now() - localStatusAt < LOCAL_STATUS_INTERVAL_MS) {
        return localStatus
      }
    }
    lastStatusPollAt = Date.now()
    const statusRequest = (async () => {
      try {
        const result = await requestJson({
          hostname: '127.0.0.1',
          port: nativeBridgePort,
          path: '/timecode/status',
          timeoutMs: 500,
        })
        localStatus = result.ok && result.data && result.data.ok
          ? result.data
          : null
      } catch (_) {
        localStatus = null
      }
      localStatusAt = Date.now()
      return localStatus
    })()
    localStatusRequest = statusRequest
    try {
      return await statusRequest
    } finally {
      if (localStatusRequest === statusRequest) localStatusRequest = null
    }
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

  function projectSyncApplyRequest(status) {
    const apply = status?.projectSyncApply &&
      typeof status.projectSyncApply === 'object'
      ? status.projectSyncApply
      : null
    const requested = apply
      ? String(apply.state || '').trim().toLowerCase() === 'requested'
      : status?.projectSyncApplyRequested === true
    if (!requested) return null
    const requestId = safePreflightRequestId(
      apply?.requestId || status?.projectSyncApplyRequestId)
    if (!requestId) return null
    return {
      requestId,
      sequence: safeSequence(
        apply?.sequence ?? status?.projectSyncApplySequence),
    }
  }

  function projectSyncApplyIsActive(status, requestId) {
    const apply = status?.projectSyncApply
    if (!apply || typeof apply !== 'object' ||
        safePreflightRequestId(apply.requestId) !== requestId) return false
    return new Set([
      'requested', 'requesting', 'downloading', 'verifying',
      'validating', 'applying', 'apply_started',
    ]).has(String(apply.state || '').trim().toLowerCase())
  }

  function projectSyncBundleAuthCanonical(payload) {
    return [
      'VSHOOK_PROJECT_SYNC_BUNDLE_AUTH_V1',
      String(payload.requestId || ''),
      String(payload.transmitterId || ''),
      String(payload.receiverId || ''),
      String(payload.sourceSessionId || ''),
      String(payload.receiverSessionId || ''),
      String(payload.bundleId || ''),
      String(payload.fileId || ''),
      String(payload.offset ?? ''),
      String(payload.length ?? ''),
      String(payload.authTimestamp || ''),
      String(payload.authNonce || ''),
    ].join('\n')
  }

  function projectSyncBundleMac(token, purpose, fields) {
    const values = Array.isArray(fields) ? fields : [fields]
    return crypto.createHmac('sha256', String(token || ''))
      .update(['VSHOOK_PROJECT_SYNC_BUNDLE_MAC_V1', purpose,
        ...values.map((value) => String(value ?? ''))].join('\n'), 'utf8')
      .digest('hex')
  }

  function projectSyncAuthPayload(session, status, extra = {}) {
    const payload = {
      code: String(session.code || status?.code || ''),
      requestId: session.requestId,
      transmitterId: session.transmitterId,
      receiverId: instanceId,
      sourceSessionId: session.remoteSessionId,
      receiverSessionId: session.localSessionId,
      projectSyncRole: 'secondary',
      ...extra,
    }
    payload.authTimestamp = Date.now()
    payload.authNonce = crypto.randomBytes(16).toString('hex')
    payload.authMac = crypto.createHmac('sha256', String(session.token || ''))
      .update(projectSyncBundleAuthCanonical(payload), 'utf8')
      .digest('hex')
    return payload
  }

  async function notifyProjectSyncBundleProgress(payload) {
    return sendLocalCommand({
      type: 'project_sync_bundle_progress',
      requestId: String(payload.requestId || ''),
      bundleId: String(payload.bundleId || ''),
      state: String(payload.state || ''),
      bytesDone: Math.max(0, Number(payload.bytesDone) || 0),
      totalBytes: Math.max(0, Number(payload.totalBytes) || 0),
      fileIndex: Math.max(0, Math.trunc(Number(payload.fileIndex) || 0)),
      fileCount: Math.max(0, Math.trunc(Number(payload.fileCount) || 0)),
      error: String(payload.error || '').slice(0, 1000),
    })
  }

  async function projectSyncStagingRoot() {
    let configured = ''
    try { configured = String(getProjectSyncStagingDir() || '').trim() } catch (_) {}
    if (!configured || !pathUtil.isAbsolute(configured)) {
      throw new Error('Pasta segura de preparação do Project Sync indisponível.')
    }
    const root = pathUtil.resolve(configured)
    await fs.promises.mkdir(root, { recursive: true })
    const stat = await fs.promises.lstat(root)
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('Pasta de preparação do Project Sync inválida.')
    }
    return root
  }

  async function cleanupProjectSyncStaging(force = false) {
    const now = Date.now()
    if (!force && now - lastProjectSyncStagingCleanupAt <
        PROJECT_SYNC_STAGING_CLEANUP_INTERVAL_MS) return
    if (projectSyncStagingCleanupPromise) {
      await projectSyncStagingCleanupPromise
      return
    }
    lastProjectSyncStagingCleanupAt = now
    const cleanup = (async () => {
      const root = await projectSyncStagingRoot()
      const entries = await fs.promises.readdir(root, { withFileTypes: true })
      for (const entry of entries) {
        const target = pathUtil.join(root, entry.name)
        let stat
        try { stat = await fs.promises.lstat(target) } catch (_) { continue }
        // Links nunca são seguidos. Entradas antigas (incluindo .partial) são
        // removidas somente se forem filhas diretas da raiz privada.
        if (stat.isSymbolicLink() ||
            now - stat.mtimeMs >
              PROJECT_SYNC_STAGING_TTL_MS) {
          try { await removeTreeNoFollow(root, target) } catch (_) {}
        }
      }
    })()
    projectSyncStagingCleanupPromise = cleanup
    try { await cleanup } finally {
      if (projectSyncStagingCleanupPromise === cleanup) {
        projectSyncStagingCleanupPromise = null
      }
    }
  }

  async function assertProjectSyncStagingCapacity(root, requiredBytes) {
    const stagingBytes = await directorySizeNoFollow(
      root, PROJECT_SYNC_STAGING_QUOTA_BYTES + 1)
    if (stagingBytes + requiredBytes > PROJECT_SYNC_STAGING_QUOTA_BYTES) {
      throw new Error('O staging do Project Sync atingiu o limite de 64 GB.')
    }
    if (typeof fs.promises.statfs === 'function') {
      try {
        const disk = await fs.promises.statfs(root)
        const availableBytes = Number(disk.bavail) * Number(disk.bsize)
        if (Number.isFinite(availableBytes) &&
            availableBytes < requiredBytes + PROJECT_SYNC_MIN_FREE_BYTES) {
          throw new Error('Espaço livre insuficiente para aplicar o projeto.')
        }
      } catch (error) {
        if (String(error?.message || '').includes('Espaço livre')) throw error
        // Node/Electron antigo ou filesystem sem statfs: a quota continua
        // sendo aplicada; a própria gravação ainda reportará falta de espaço.
      }
    }
  }

  async function ensureSafeDestinationDirectory(root, directory) {
    const relative = pathUtil.relative(pathUtil.resolve(root),
      pathUtil.resolve(directory))
    if (relative.startsWith('..') || pathUtil.isAbsolute(relative)) {
      throw new Error('Destino fora da pasta segura do Project Sync.')
    }
    let cursor = pathUtil.resolve(root)
    for (const component of relative.split(pathUtil.sep).filter(Boolean)) {
      cursor = pathUtil.join(cursor, component)
      try {
        const stat = await fs.promises.lstat(cursor)
        if (!stat.isDirectory() || stat.isSymbolicLink()) {
          throw new Error('Destino inseguro no pacote Project Sync.')
        }
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error
        await fs.promises.mkdir(cursor)
      }
    }
  }

  function validateBundleManifest(raw, expectedRequestId = '') {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw) ||
        Number(raw.schemaVersion) !== 1) {
      throw new Error('Manifesto do pacote Project Sync inválido.')
    }
    const serialized = JSON.stringify(raw)
    if (Buffer.byteLength(serialized) > PROJECT_SYNC_BUNDLE_MANIFEST_BYTES ||
        descriptorContainsAbsolutePath(raw)) {
      throw new Error('Manifesto do pacote Project Sync contém dados inseguros.')
    }
    const bundleId = safeBundleId(raw.bundleId)
    const requestId = safePreflightRequestId(raw.requestId)
    if (!bundleId || !requestId ||
        (expectedRequestId && requestId !== expectedRequestId)) {
      throw new Error('Identificação do pacote Project Sync inválida.')
    }
    const sourceSessionId = String(raw.sourceSessionId || '').trim().slice(0, 512)
    const sourceManifestRevision = String(
      raw.sourceManifestRevision || '').trim().slice(0, 256)
    const sourceStructuralRevision = String(
      raw.sourceStructuralRevision || '').trim().slice(0, 256)
    if (!sourceSessionId || !sourceManifestRevision ||
        !sourceStructuralRevision) {
      throw new Error('Revisão do pacote Project Sync ausente.')
    }
    const files = Array.isArray(raw.files) ? raw.files : []
    if (files.length < 1 || files.length > PROJECT_SYNC_BUNDLE_MAX_FILES) {
      throw new Error('Quantidade de arquivos do pacote Project Sync inválida.')
    }
    const ids = new Set()
    const paths = new Set()
    let totalBytes = 0
    const normalizedFiles = files.map((file) => {
      const id = safeBundleId(file?.id)
      const relativePath = safeBundleRelativePath(file?.relativePath)
      const size = Number(file?.size)
      const sha256 = safeSha256(file?.sha256)
      // Também bloqueia colisões apenas por caixa no macOS, cuja instalação
      // normal usa volume case-insensitive.
      const normalizedKey = relativePath.toLowerCase()
      if (!id || !relativePath || !sha256 ||
          !Number.isSafeInteger(size) || size < 0 ||
          size > PROJECT_SYNC_BUNDLE_MAX_FILE_BYTES ||
          ids.has(id) || paths.has(normalizedKey) ||
          /^bundle(?:\.descriptor)?\.json(?:\.partial)?$/i.test(relativePath)) {
        throw new Error('Entrada de arquivo inválida no pacote Project Sync.')
      }
      ids.add(id)
      paths.add(normalizedKey)
      totalBytes += size
      if (!Number.isSafeInteger(totalBytes) ||
          totalBytes > PROJECT_SYNC_BUNDLE_MAX_TOTAL_BYTES) {
        throw new Error('Pacote Project Sync excede o limite permitido.')
      }
      return {
        id,
        relativePath,
        size,
        sha256,
        kind: safeName(file?.kind, 'media'),
      }
    })
    const projectFileObject = raw.projectFile &&
      typeof raw.projectFile === 'object' && !Array.isArray(raw.projectFile)
      ? raw.projectFile
      : null
    const projectFileRelative = safeBundleRelativePath(
      projectFileObject?.relativePath || raw.projectFile)
    if (!projectFileRelative ||
        !paths.has(projectFileRelative.toLowerCase())) {
      throw new Error('Projeto principal ausente no pacote Project Sync.')
    }
    const projectEntry = normalizedFiles.find((file) =>
      file.kind.toLowerCase() === 'project' &&
      file.relativePath.toLowerCase() === projectFileRelative.toLowerCase())
    if (!projectEntry || (projectFileObject &&
        ((projectFileObject.size != null &&
          Number(projectFileObject.size) !== projectEntry.size) ||
         (projectFileObject.sha256 != null &&
          safeSha256(projectFileObject.sha256) !== projectEntry.sha256)))) {
      throw new Error('Metadados do projeto principal são inválidos.')
    }
    return {
      ...raw,
      schemaVersion: 1,
      bundleId,
      requestId,
      sourceSessionId,
      sourceManifestRevision,
      sourceStructuralRevision,
      // Sempre grava o objeto assinado esperado pela extensão B. Se uma build
      // de transição do PC A publicou somente a string, o relay completa os
      // metadados a partir da entrada validada em files.
      projectFile: {
        ...(projectFileObject || {}),
        relativePath: projectFileRelative,
        size: projectEntry.size,
        sha256: projectEntry.sha256,
      },
      files: normalizedFiles,
      totalBytes,
    }
  }

  function applyPeerIsCurrent(peer) {
    return !!peer && Date.now() - peer.createdAt < PROJECT_SYNC_APPLY_TTL_MS
  }

  async function authorizeProjectSyncBundleRequest(req, payload) {
    const peer = projectSyncApplyPeer
    const status = await readLocalStatus(true)
    const remoteAddress = normalizePeerAddress(req.socket?.remoteAddress)
    const authTimestamp = Number(payload?.authTimestamp)
    const authNonce = String(payload?.authNonce || '').trim().toLowerCase()
    const authMac = safeSha256(payload?.authMac)
    const expectedMac = peer
      ? crypto.createHmac('sha256', String(peer.token || ''))
        .update(projectSyncBundleAuthCanonical(payload), 'utf8')
        .digest('hex')
      : ''
    if (!licenseIsActive() || !statusCanTransmit(status) ||
        status?.mode !== 'project_sync' ||
        projectSyncRole(status) !== 'primary' ||
        !applyPeerIsCurrent(peer) ||
        !projectSyncBundlePeerAllowed(remoteAddress) ||
        remoteAddress !== normalizePeerAddress(peer.address) ||
        !projectSyncRolesMatch('primary', payload?.projectSyncRole) ||
        String(payload?.code || '') !== String(peer.code || '') ||
        safePreflightRequestId(payload?.requestId) !== peer.requestId ||
        String(payload?.transmitterId || '') !== instanceId ||
        String(payload?.receiverId || '') !== peer.receiverId ||
        String(payload?.sourceSessionId || '') !== peer.localSessionId ||
        String(payload?.receiverSessionId || '') !== peer.remoteSessionId ||
        String(status.sessionId || '').trim() !== peer.localSessionId ||
        projectSyncStructuralRevision(status) !== peer.localStructuralRevision ||
        !Number.isSafeInteger(authTimestamp) ||
        Math.abs(Date.now() - authTimestamp) > 30000 ||
        !/^[a-f0-9]{32}$/.test(authNonce) || !authMac ||
        !tokenMatches(authMac, expectedMac)) {
      const error = new Error('Pedido de aplicação do Project Sync não autorizado.')
      if (!preferredCablePrefix()) {
        error.message = 'Configure a Conexão redundante por cabo antes de transferir o projeto.'
      }
      error.status = 403
      throw error
    }
    if (!peer.authNonces) peer.authNonces = new Map()
    for (const [nonce, createdAt] of peer.authNonces) {
      if (Date.now() - createdAt > 60000) peer.authNonces.delete(nonce)
    }
    if (peer.authNonces.size >= 4096) {
      const error = new Error('Muitos pedidos Project Sync em andamento.')
      error.status = 429
      throw error
    }
    if (peer.authNonces.has(authNonce)) {
      const error = new Error('Pedido Project Sync repetido.')
      error.status = 409
      throw error
    }
    peer.authNonces.set(authNonce, Date.now())
    peer.createdAt = Date.now()
    return { peer, status }
  }

  async function prepareProjectSyncExport(peer, status) {
    const cached = projectSyncExportBundle
    if (cached && cached.requestId === peer.requestId &&
        cached.sourceSessionId === peer.localSessionId &&
        cached.sourceStructuralRevision === peer.localStructuralRevision &&
        Date.now() - cached.createdAt < PROJECT_SYNC_APPLY_TTL_MS) {
      return cached
    }
    const accepted = await sendLocalCommand({
      type: 'project_sync_prepare_bundle',
      requestId: peer.requestId,
      expectedRevision: peer.localStructuralRevision,
      receiverSessionId: peer.remoteSessionId,
      peerName: peer.name || 'PC B',
    })
    if (!accepted) {
      throw new Error('A extensão do PC A não iniciou a preparação do projeto.')
    }
    const deadline = Date.now() + 60000
    let bundleStatus = null
    while (!stopped && Date.now() < deadline) {
      const current = await readLocalStatus(true)
      if (!statusCanTransmit(current) ||
          projectSyncRole(current) !== 'primary' ||
          String(current.sessionId || '').trim() !== peer.localSessionId ||
          projectSyncStructuralRevision(current) !== peer.localStructuralRevision) {
        throw new Error('O projeto do PC A mudou durante a preparação.')
      }
      const candidate = current?.projectSyncBundle
      if (candidate && safePreflightRequestId(candidate.requestId) ===
          peer.requestId) {
        const state = String(candidate.state || '').trim().toLowerCase()
        if (state === 'error') {
          throw new Error(String(candidate.error ||
            'Falha ao preparar o projeto no PC A.').slice(0, 1000))
        }
        if (state === 'ready') {
          bundleStatus = candidate
          break
        }
      }
      await wait(80)
    }
    if (!bundleStatus) {
      throw new Error('Tempo limite ao preparar o projeto no PC A.')
    }
    const descriptorPath = String(bundleStatus.descriptorPath || '').trim()
    if (!descriptorPath || !pathUtil.isAbsolute(descriptorPath)) {
      throw new Error('Descritor local do PC A não foi encontrado.')
    }
    const exportRoot = pathUtil.dirname(pathUtil.resolve(descriptorPath))
    const rootStat = await fs.promises.lstat(exportRoot)
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
      throw new Error('Diretório de exportação do PC A é inválido.')
    }
    await assertRegularFileInside(exportRoot, descriptorPath)
    const descriptor = await readLimitedJsonFile(
      descriptorPath, PROJECT_SYNC_BUNDLE_MANIFEST_BYTES)
    const manifest = validateBundleManifest(descriptor, peer.requestId)
    if (manifest.sourceSessionId !== peer.localSessionId ||
        manifest.sourceStructuralRevision !== peer.localStructuralRevision ||
        (bundleStatus.bundleId &&
          safeBundleId(bundleStatus.bundleId) !== manifest.bundleId)) {
      throw new Error('O pacote preparado não corresponde ao projeto do PC A.')
    }
    const filesById = new Map()
    for (const file of manifest.files) {
      const sourcePath = resolveInside(exportRoot, file.relativePath)
      if (!sourcePath) throw new Error('Arquivo inseguro no pacote do PC A.')
      const stat = await assertRegularFileInside(exportRoot, sourcePath)
      if (stat.size !== file.size) {
        throw new Error(`O arquivo ${file.relativePath} mudou durante a preparação.`)
      }
      filesById.set(file.id, {
        ...file,
        sourcePath,
        mtimeMs: stat.mtimeMs,
      })
    }
    const manifestText = JSON.stringify(manifest)
    projectSyncExportBundle = {
      requestId: peer.requestId,
      bundleId: manifest.bundleId,
      sourceSessionId: peer.localSessionId,
      sourceStructuralRevision: peer.localStructuralRevision,
      manifest,
      manifestSha256: crypto.createHash('sha256')
        .update(manifestText, 'utf8').digest('hex'),
      filesById,
      createdAt: Date.now(),
    }
    return projectSyncExportBundle
  }

  async function handleProjectSyncBundleManifest(req, res) {
    const payload = await readJsonBody(req, 64 * 1024)
    const { peer, status } = await authorizeProjectSyncBundleRequest(req, payload)
    const bundle = await prepareProjectSyncExport(peer, status)
    sendJson(res, 200, {
      ok: true,
      manifest: bundle.manifest,
      manifestSha256: bundle.manifestSha256,
      manifestMac: projectSyncBundleMac(peer.token, 'manifest', [
        peer.requestId, bundle.bundleId, bundle.manifestSha256,
      ]),
    })
  }

  async function handleProjectSyncBundleFile(req, res) {
    const payload = await readJsonBody(req, 64 * 1024)
    const { peer } = await authorizeProjectSyncBundleRequest(req, payload)
    const bundle = projectSyncExportBundle
    const bundleId = safeBundleId(payload.bundleId)
    const fileId = safeBundleId(payload.fileId)
    const offset = Number(payload.offset)
    const requestedLength = Number(payload.length)
    if (!bundle || bundle.bundleId !== bundleId ||
        bundle.requestId !== safePreflightRequestId(payload.requestId)) {
      const error = new Error('Pacote Project Sync expirado.')
      error.status = 410
      throw error
    }
    const file = bundle.filesById.get(fileId)
    if (!file || !Number.isSafeInteger(offset) || offset < 0 ||
        offset > file.size || !Number.isSafeInteger(requestedLength) ||
        requestedLength < 1 || requestedLength > PROJECT_SYNC_BUNDLE_CHUNK_BYTES) {
      const error = new Error('Trecho de arquivo Project Sync inválido.')
      error.status = 400
      throw error
    }
    const pathStat = await fs.promises.lstat(file.sourcePath)
    if (!pathStat.isFile() || pathStat.isSymbolicLink() ||
        pathStat.size !== file.size ||
        Math.abs(pathStat.mtimeMs - file.mtimeMs) > 1) {
      const error = new Error('Arquivo do PC A mudou durante a transferência.')
      error.status = 409
      throw error
    }
    const length = Math.min(requestedLength, file.size - offset)
    const data = Buffer.alloc(length)
    if (length > 0) {
      const openFlags = fs.constants.O_RDONLY |
        (fs.constants.O_NOFOLLOW || 0)
      const handle = await fs.promises.open(file.sourcePath, openFlags)
      try {
        const openedStat = await handle.stat()
        if (!openedStat.isFile() || openedStat.size !== file.size ||
            Math.abs(openedStat.mtimeMs - file.mtimeMs) > 1) {
          throw new Error('Arquivo do PC A mudou durante a transferência.')
        }
        const result = await handle.read(data, 0, length, offset)
        if (result.bytesRead !== length) {
          throw new Error('Leitura incompleta do arquivo no PC A.')
        }
        const finalStat = await handle.stat()
        if (finalStat.size !== openedStat.size ||
            Math.abs(finalStat.mtimeMs - openedStat.mtimeMs) > 1) {
          throw new Error('Arquivo do PC A mudou durante a transferência.')
        }
      } finally {
        await handle.close()
      }
    }
    sendBinary(res, 200, data, {
      'X-VSHook-Bundle-Id': bundle.bundleId,
      'X-VSHook-File-Id': file.id,
      'X-VSHook-Offset': String(offset),
      'X-VSHook-File-Size': String(file.size),
      'X-VSHook-Chunk-SHA256': crypto.createHash('sha256')
        .update(data).digest('hex'),
      'X-VSHook-Chunk-MAC': projectSyncBundleMac(peer.token, 'chunk', [
        bundle.requestId, bundle.bundleId, file.id, offset,
        crypto.createHash('sha256').update(data).digest('hex'),
      ]),
    })
  }

  async function handleProjectSyncBundleConsumed(req, res) {
    const payload = await readJsonBody(req, 64 * 1024)
    const { peer } = await authorizeProjectSyncBundleRequest(req, payload)
    const bundleId = safeBundleId(payload.bundleId)
    const bundle = projectSyncExportBundle
    if (!bundle || !bundleId || bundle.bundleId !== bundleId ||
        bundle.requestId !== peer.requestId) {
      sendJson(res, 410, { ok: false, error: 'Pacote Project Sync expirado.' })
      return
    }
    const accepted = await sendLocalCommand({
      type: 'project_sync_bundle_consumed',
      requestId: peer.requestId,
      bundleId,
    })
    if (!accepted) {
      sendJson(res, 503, {
        ok: false,
        error: 'A extensão do PC A não confirmou a limpeza do bundle.',
      })
      return
    }
    projectSyncExportBundle = null
    sendJson(res, 200, { ok: true })
  }

  function bundleProgressReporter(base) {
    let lastSentAt = 0
    let lastState = ''
    return async (update, force = false) => {
      const now = Date.now()
      if (!force && update.state === lastState &&
          now - lastSentAt < PROJECT_SYNC_BUNDLE_PROGRESS_INTERVAL_MS) return
      lastSentAt = now
      lastState = update.state
      await notifyProjectSyncBundleProgress({ ...base, ...update })
    }
  }

  async function downloadProjectSyncBundle(status, session) {
    const lifecycleSequence = relayLifecycleSequence
    const ensureActive = () => {
      if (stopped || lifecycleSequence !== relayLifecycleSequence) {
        throw new Error('Transferência Project Sync cancelada.')
      }
    }
    const report = bundleProgressReporter({ requestId: session.requestId })
    let bundleId = ''
    try {
      await report({ state: 'requesting' }, true)
      const remoteManifest = await requestJson({
        hostname: session.address,
        port: session.port,
        path: '/timecode-link/project-sync/bundle/manifest',
        method: 'POST',
        payload: projectSyncAuthPayload(session, status),
        timeoutMs: 65000,
        maxResponseBytes: PROJECT_SYNC_BUNDLE_MANIFEST_BYTES + 64 * 1024,
      })
      if (!remoteManifest.ok || !remoteManifest.data?.ok ||
          !remoteManifest.data?.manifest) {
        throw new Error(remoteManifest.data?.error ||
          'O PC A não preparou o pacote Project Sync.')
      }
      const manifestText = JSON.stringify(remoteManifest.data.manifest)
      const receivedManifestHash = safeSha256(
        remoteManifest.data.manifestSha256)
      const computedManifestHash = crypto.createHash('sha256')
        .update(manifestText, 'utf8').digest('hex')
      if (!receivedManifestHash ||
          !tokenMatches(receivedManifestHash, computedManifestHash)) {
        throw new Error('Manifesto do pacote Project Sync foi alterado na rede.')
      }
      const manifest = validateBundleManifest(
        remoteManifest.data.manifest, session.requestId)
      const receivedManifestMac = safeSha256(
        remoteManifest.data.manifestMac)
      const expectedManifestMac = projectSyncBundleMac(
        session.token, 'manifest', [session.requestId,
          manifest.bundleId, receivedManifestHash])
      if (!receivedManifestMac ||
          !tokenMatches(receivedManifestMac, expectedManifestMac)) {
        throw new Error('Assinatura do manifesto Project Sync é inválida.')
      }
      ensureActive()
      bundleId = manifest.bundleId
      if (manifest.sourceSessionId !== session.remoteSessionId ||
          manifest.sourceStructuralRevision !== session.remoteStructuralRevision) {
        throw new Error('O projeto do PC A mudou antes da transferência.')
      }
      const stagingRoot = await projectSyncStagingRoot()
      const transferRoot = resolveInside(stagingRoot, bundleId)
      if (!transferRoot) throw new Error('Identificação de staging inválida.')
      await cleanupProjectSyncStaging(false)
      const existingTransferBytes = await directorySizeNoFollow(
        transferRoot, manifest.totalBytes)
      await assertProjectSyncStagingCapacity(stagingRoot,
        Math.max(0, manifest.totalBytes - existingTransferBytes))
      await ensureSafeDestinationDirectory(stagingRoot, transferRoot)
      try {
        const markerPath = pathUtil.join(transferRoot, '.vshook-staging.json')
        const markerPartial = `${markerPath}.partial`
        await fs.promises.writeFile(markerPartial, JSON.stringify({
          schemaVersion: 1,
          bundleId,
          requestId: session.requestId,
          createdAt: Date.now(),
        }), { encoding: 'utf8', mode: 0o600 })
        try { await fs.promises.unlink(markerPath) } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
        await fs.promises.rename(markerPartial, markerPath)
      } catch (error) {
        throw new Error(`Não foi possível preparar o staging: ${error?.message || error}`)
      }

      let bytesDone = 0
      for (let index = 0; index < manifest.files.length; index += 1) {
        ensureActive()
        const file = manifest.files[index]
        const destination = resolveInside(transferRoot, file.relativePath)
        if (!destination) throw new Error('Destino de arquivo inválido.')
        await ensureSafeDestinationDirectory(
          transferRoot, pathUtil.dirname(destination))
        const partial = `${destination}.partial`
        let complete = false
        try {
          const stat = await fs.promises.lstat(destination)
          if (!stat.isFile() || stat.isSymbolicLink()) {
            throw new Error('Arquivo de staging inseguro.')
          }
          if (stat.size === file.size &&
              await sha256File(destination) === file.sha256) {
            complete = true
            bytesDone += file.size
          } else {
            await fs.promises.unlink(destination)
          }
        } catch (error) {
          if (error?.code !== 'ENOENT' &&
              error?.message !== 'Arquivo de staging inseguro.') throw error
          if (error?.message === 'Arquivo de staging inseguro.') throw error
        }
        if (complete) {
          await report({
            state: 'downloading',
            bundleId,
            bytesDone,
            totalBytes: manifest.totalBytes,
            fileIndex: index + 1,
            fileCount: manifest.files.length,
          })
          continue
        }

        let offset = 0
        try {
          const partialStat = await fs.promises.lstat(partial)
          if (!partialStat.isFile() || partialStat.isSymbolicLink()) {
            throw new Error('Arquivo parcial de staging inseguro.')
          }
          offset = partialStat.size <= file.size ? partialStat.size : 0
          if (partialStat.size > file.size) {
            await fs.promises.truncate(partial, 0)
          }
        } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
        bytesDone += offset
        if (offset === 0) {
          const handle = await fs.promises.open(partial, 'w')
          await handle.close()
        }
        while (offset < file.size) {
          ensureActive()
          const length = Math.min(
            PROJECT_SYNC_BUNDLE_CHUNK_BYTES, file.size - offset)
          const chunk = await requestBinary({
            hostname: session.address,
            port: session.port,
            path: '/timecode-link/project-sync/bundle/file',
            payload: projectSyncAuthPayload(session, status, {
              bundleId,
              fileId: file.id,
              offset,
              length,
            }),
            timeoutMs: 30000,
            maxResponseBytes: PROJECT_SYNC_BUNDLE_CHUNK_BYTES,
          })
          ensureActive()
          const responseOffset = Number(chunk.headers['x-vshook-offset'])
          const responseSize = Number(chunk.headers['x-vshook-file-size'])
          const responseChunkHash = safeSha256(
            chunk.headers['x-vshook-chunk-sha256'])
          const responseChunkMac = safeSha256(
            chunk.headers['x-vshook-chunk-mac'])
          const computedChunkHash = crypto.createHash('sha256')
            .update(chunk.data).digest('hex')
          const expectedChunkMac = projectSyncBundleMac(
            session.token, 'chunk', [session.requestId, bundleId,
              file.id, offset, computedChunkHash])
          if (responseOffset !== offset || responseSize !== file.size ||
              chunk.data.length !== length || !responseChunkHash ||
              !tokenMatches(responseChunkHash, computedChunkHash) ||
              !responseChunkMac ||
              !tokenMatches(responseChunkMac, expectedChunkMac)) {
            throw new Error(`Bloco corrompido: ${file.relativePath}`)
          }
          const handle = await fs.promises.open(partial, 'r+')
          try {
            const written = await handle.write(
              chunk.data, 0, chunk.data.length, offset)
            if (written.bytesWritten !== chunk.data.length) {
              throw new Error('Gravação incompleta no staging Project Sync.')
            }
          } finally {
            await handle.close()
          }
          offset += chunk.data.length
          bytesDone += chunk.data.length
          await report({
            state: 'downloading',
            bundleId,
            bytesDone,
            totalBytes: manifest.totalBytes,
            fileIndex: index + 1,
            fileCount: manifest.files.length,
          })
        }
        await report({
          state: 'verifying',
          bundleId,
          bytesDone,
          totalBytes: manifest.totalBytes,
          fileIndex: index + 1,
          fileCount: manifest.files.length,
        }, true)
        if (await sha256File(partial) !== file.sha256) {
          try { await fs.promises.unlink(partial) } catch (_) {}
          throw new Error(`SHA-256 inválido: ${file.relativePath}`)
        }
        try { await fs.promises.unlink(destination) } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
        await fs.promises.rename(partial, destination)
      }

      // Validação de commit: confirma novamente o snapshot no PC A e o estado
      // original do PC B antes de entregar qualquer caminho para a extensão.
      // Assim uma edição feita durante o download não aplica um pacote sobre
      // um projeto B que já mudou nem mistura duas revisões do PC A.
      const sourceValidation = await requestJson({
        hostname: session.address,
        port: session.port,
        path: '/timecode-link/project-sync/bundle/manifest',
        method: 'POST',
        payload: projectSyncAuthPayload(session, status),
        timeoutMs: 65000,
        maxResponseBytes: PROJECT_SYNC_BUNDLE_MANIFEST_BYTES + 64 * 1024,
      })
      ensureActive()
      const validationManifestHash = sourceValidation.data?.manifest
        ? crypto.createHash('sha256')
          .update(JSON.stringify(sourceValidation.data.manifest), 'utf8')
          .digest('hex')
        : ''
      const validationManifestMac = safeSha256(
        sourceValidation.data?.manifestMac)
      if (!sourceValidation.ok || !sourceValidation.data?.ok ||
          safeSha256(sourceValidation.data.manifestSha256) !==
            receivedManifestHash ||
          validationManifestHash !== receivedManifestHash ||
          !validationManifestMac ||
          !tokenMatches(validationManifestMac, expectedManifestMac)) {
        throw new Error('O projeto do PC A mudou durante a transferência.')
      }
      const currentLocalStatus = await readLocalStatus(true)
      const applyStillActive = projectSyncApplyIsActive(
        currentLocalStatus, session.requestId)
      if (!statusCanReceive(currentLocalStatus) ||
          projectSyncRole(currentLocalStatus) !== 'secondary' ||
          String(currentLocalStatus.sessionId || '').trim() !==
            session.localSessionId ||
          projectSyncStructuralRevision(currentLocalStatus) !==
            session.localStructuralRevision ||
          !applyStillActive) {
        throw new Error('O projeto mudou ou a aplicação foi cancelada no PC B.')
      }

      const descriptorPath = pathUtil.join(
        transferRoot, 'bundle.descriptor.json')
      const descriptorPartial = `${descriptorPath}.partial`
      await fs.promises.writeFile(descriptorPartial,
        `${JSON.stringify(manifest, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
      try { await fs.promises.unlink(descriptorPath) } catch (error) {
        if (error?.code !== 'ENOENT') throw error
      }
      await fs.promises.rename(descriptorPartial, descriptorPath)
      // O pacote local B já está íntegro; avisa A para limpar somente a raiz
      // de exportação que a própria extensão A criou. Uma falha de ACK não
      // invalida o staging B nem impede a aplicação já verificada.
      try {
        await requestJson({
          hostname: session.address,
          port: session.port,
          path: '/timecode-link/project-sync/bundle/consumed',
          method: 'POST',
          payload: projectSyncAuthPayload(session, status, { bundleId }),
          timeoutMs: 3000,
        })
      } catch (_) {}
      await report({
        state: 'applying',
        bundleId,
        bytesDone: manifest.totalBytes,
        totalBytes: manifest.totalBytes,
        fileIndex: manifest.files.length,
        fileCount: manifest.files.length,
      }, true)
      const accepted = await sendLocalCommand({
        type: 'project_sync_apply_bundle',
        requestId: session.requestId,
        bundleId,
        descriptorPath,
        stagingRoot: transferRoot,
      })
      if (!accepted) {
        throw new Error('A extensão do PC B não aceitou o pacote Project Sync.')
      }
      await report({
        state: 'apply_started',
        bundleId,
        bytesDone: manifest.totalBytes,
        totalBytes: manifest.totalBytes,
        fileIndex: manifest.files.length,
        fileCount: manifest.files.length,
      }, true)
    } catch (error) {
      if (!stopped && lifecycleSequence === relayLifecycleSequence) {
        await report({
          state: 'error',
          bundleId,
          error: error?.message || 'Falha ao aplicar modificações do PC A.',
        }, true)
      }
    }
  }

  function maybeStartProjectSyncBundlePull(status) {
    const apply = projectSyncApplyRequest(status)
    if (!apply) {
      if (!projectSyncBundlePullPromise) lastProjectSyncApplyKey = ''
      return
    }
    if (projectSyncBundlePullPromise || status?.mode !== 'project_sync' ||
        projectSyncRole(status) !== 'secondary' ||
        !projectSyncApplySession ||
        Date.now() - projectSyncApplySession.createdAt >=
          PROJECT_SYNC_APPLY_TTL_MS) return
    if (!apply || apply.requestId !== projectSyncApplySession.requestId) return
    // O clique deve pertencer ao resultado bloqueado que ainda está exposto
    // pela extensão B; não basta alguém fabricar state=requested no status.
    if (statusPreflightRequestId(status) !== apply.requestId ||
        status.projectSyncReady === true) return
    const key = `${apply.requestId}:${apply.sequence}`
    if (key === lastProjectSyncApplyKey) return
    if (String(status.sessionId || '').trim() !==
          projectSyncApplySession.localSessionId ||
        projectSyncStructuralRevision(status) !==
          projectSyncApplySession.localStructuralRevision) return
    lastProjectSyncApplyKey = key
    projectSyncBundlePullPromise = downloadProjectSyncBundle(
      status, projectSyncApplySession)
      .catch(() => {})
      .finally(() => { projectSyncBundlePullPromise = null })
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
      version: status?.mode === 'project_sync'
        ? PROJECT_SYNC_PROTOCOL_VERSION
        : 1,
      code: String(status.code || ''),
      transmitterId: instanceId,
      transmitterName: deviceName(),
      mode: status.mode,
      projectSyncRole: projectSyncRole(status),
    }
    for (const address of getBroadcastAddresses()) sendUdp(payload, address)
  }

  async function pollRemoteProjectSyncPreflight({
    address,
    port,
    status,
    requestId,
  }) {
    const deadline = Date.now() + PROJECT_SYNC_PREFLIGHT_TIMEOUT_MS
    while (!stopped && Date.now() < deadline) {
      const currentStatus = await readLocalStatus(false)
      if (!statusCanTransmit(currentStatus) ||
          projectSyncRole(currentStatus) !== 'primary' ||
          String(currentStatus.code || '') !== String(status.code || '') ||
          String(currentStatus.sessionId || '') !==
            String(status.sessionId || '')) {
        return null
      }
      try {
        const result = await requestJson({
          hostname: address,
          port,
          path: '/timecode-link/preflight',
          method: 'POST',
          payload: {
            requestId,
            code: status.code,
            transmitterId: instanceId,
            sessionId: String(status.sessionId || ''),
            projectSyncRole: 'primary',
          },
          timeoutMs: 900,
        })
        if (!result.ok && result.status !== 202) return null
        if (result.data?.pending === true) {
          await wait(PROJECT_SYNC_PREFLIGHT_POLL_MS)
          continue
        }
        if (result.data?.ok && result.data?.completed === true) {
          return result.data
        }
      } catch (_) {
        // Uma perda curta de pacote durante a comparacao nao reinicia nem troca
        // o requestId. Continua consultando ate o limite total do preflight.
      }
      await wait(PROJECT_SYNC_PREFLIGHT_POLL_MS)
    }
    return null
  }

  async function pairWithReceiver(status, address, remotePort, receiver = {}) {
    if (!statusCanTransmit(status) || !isPairCode(status.code) ||
        transmitterPeer?.connected || stopped || !peerAddressAllowed(address)) return false
    if (status.mode === 'project_sync' &&
        applyPeerIsCurrent(projectSyncApplyPeer) &&
        normalizePeerAddress(address) !==
          normalizePeerAddress(projectSyncApplyPeer.address)) return false
    try {
      // Verifica o contrato antes de enviar o manifesto. Uma Hook Center antiga
      // aceitava /pair e se marcava como conectada, mas nao possuia preflight;
      // isso criava uma conexao unilateral falsa no PC B.
      if (status.mode === 'project_sync' &&
          !await projectSyncCapabilities(
            status, address, remotePort,
            !!String(receiver.id || '').trim() ||
              (!!preferredCablePrefix() && peerAddressAllowed(address)))) {
        return false
      }
      const localEventBaseline = Math.max(0,
        safeSequence(status.eventSequence))
      const localSessionId = String(status.sessionId || '').trim()
      const localStructuralRevision =
        projectSyncStructuralRevision(status)
      if (status.mode === 'project_sync' && !localSessionId) return false
      const proposedRequestId = status.mode === 'project_sync'
        ? projectSyncPairRequestId(status)
        : ''
      let result = await requestJson({
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
          protocolVersion: status.mode === 'project_sync'
            ? PROJECT_SYNC_PROTOCOL_VERSION
            : 1,
          projectSyncRole: projectSyncRole(status),
          eventSequence: localEventBaseline,
          sessionId: localSessionId,
          // A extensao monta o manifesto sem caminhos absolutos. O relay apenas
          // o encaminha para que B possa comparar projeto e configuracoes.
          manifest: status.mode === 'project_sync'
            ? (status.manifest || null)
            : undefined,
          manifestRevision: status.mode === 'project_sync'
            ? String(status.manifestRevision || '')
            : undefined,
          structuralManifestRevision: status.mode === 'project_sync'
            ? localStructuralRevision
            : undefined,
          requestId: status.mode === 'project_sync'
            ? proposedRequestId
            : undefined,
        },
        timeoutMs: Math.max(
          status.mode === 'project_sync' ? 900 : 0,
          Number(receiver.timeoutMs) || 1000),
      })
      if (!result.ok || !result.data?.ok || transmitterPeer?.connected || stopped) {
        if (status.mode === 'project_sync' &&
            isRecognizableLegacyRelayResponse(result)) {
          await notifyProjectSyncProtocolMismatch(status, address)
        }
        return false
      }
      if (status.mode === 'project_sync' &&
          !projectSyncRolesMatch(
            projectSyncRole(status), result.data.projectSyncRole)) {
        await notifyProjectSyncProtocolMismatch(status, address)
        return false
      }
      if (status.mode === 'project_sync' && result.data.pending === true) {
        const requestId = safePreflightRequestId(result.data.requestId)
        if (!requestId) return false
        const completed = await pollRemoteProjectSyncPreflight({
          address,
          port: remotePort,
          status,
          requestId,
        })
        if (!completed) {
          await sendLocalCommand({
            type: 'project_sync_preflight',
            role: 'primary',
            requestId,
            ready: false,
            timedOut: true,
          })
          return false
        }
        result = { ok: true, data: completed }
      }
      if (status.mode === 'project_sync') {
        const confirmedStatus = await readLocalStatus(true)
        const confirmedSessionId = String(
          confirmedStatus?.sessionId || '').trim()
        const confirmedStructuralRevision =
          projectSyncStructuralRevision(confirmedStatus)
        if (!statusCanTransmit(confirmedStatus) ||
            projectSyncRole(confirmedStatus) !== 'primary' ||
            String(confirmedStatus.code || '') !== String(status.code || '') ||
            confirmedSessionId !== localSessionId ||
            confirmedStructuralRevision !== localStructuralRevision) {
          await sendLocalCommand({
            type: 'project_sync_preflight',
            role: 'primary',
            requestId: safePreflightRequestId(result.data.requestId) ||
              proposedRequestId,
            ready: false,
            diff: projectSyncManifestChangedDiff(
              'primary', localStructuralRevision,
              confirmedStructuralRevision),
          })
          finishProjectSyncPairAttempt(
            safePreflightRequestId(result.data.requestId) ||
              proposedRequestId)
          return false
        }
        status = confirmedStatus
      }
      if (status.mode === 'project_sync' && result.data.ready !== true) {
        // Mantem o diagnostico local disponivel no status da extensao, mas nao
        // abre o fluxo A -> B enquanto o preflight apontar divergencias.
        await sendLocalCommand({
          type: 'project_sync_preflight',
          role: 'primary',
          requestId: safePreflightRequestId(result.data.requestId) ||
            proposedRequestId,
          ready: false,
          diff: result.data.diff || null,
          remoteManifestRevision: String(
            result.data.manifestRevision || ''),
        })
        const applyToken = String(result.data.applyToken || '')
        const receiverId = String(result.data.receiverId || receiver.id || '')
        const receiverSessionId = String(
          result.data.receiverSessionId || '').trim()
        const remoteStructuralRevision = String(
          result.data.structuralManifestRevision ||
          result.data.manifestRevision || '').trim().slice(0, 256)
        if (/^[a-f0-9]{64}$/i.test(applyToken) && receiverId &&
            receiverSessionId && remoteStructuralRevision) {
          projectSyncApplyPeer = {
            requestId: safePreflightRequestId(result.data.requestId) ||
              proposedRequestId,
            token: applyToken,
            code: String(status.code || ''),
            address: normalizePeerAddress(address),
            port: remotePort,
            receiverId,
            name: safeName(result.data.receiverName || receiver.name, 'PC B'),
            localSessionId,
            localManifestRevision: projectSyncManifestRevision(status),
            localStructuralRevision,
            remoteSessionId: receiverSessionId,
            remoteManifestRevision: String(
              result.data.manifestRevision || '').trim().slice(0, 256),
            remoteStructuralRevision,
            createdAt: Date.now(),
          }
          // Mantém o mesmo requestId nas novas sondagens enquanto a janela de
          // diferenças aguarda a decisão do usuário no PC B.
          if (projectSyncPairAttempt?.requestId === proposedRequestId) {
            projectSyncPairAttempt.createdAt = Date.now()
          }
        }
        return false
      }
      if (status.mode === 'project_sync') {
        await sendLocalCommand({
          type: 'project_sync_preflight',
          role: 'primary',
          requestId: safePreflightRequestId(result.data.requestId) ||
            proposedRequestId,
          ready: true,
          diff: result.data.diff || null,
          remoteManifestRevision: String(
            result.data.manifestRevision || ''),
        })
      }
      if (status.mode === 'project_sync' &&
          (!String(result.data.receiverSessionId || '').trim() ||
           !String(result.data.manifestRevision || '').trim())) {
        return false
      }
      if (!result.data?.token || transmitterPeer?.connected || stopped) return false
      projectSyncApplyPeer = null
      projectSyncExportBundle = null
      const remoteId = String(result.data.receiverId || receiver.id || '')
      transmitterPeer = {
        address,
        port: remotePort,
        receiverId: remoteId,
        name: safeName(result.data.receiverName || receiver.name, 'Receiver'),
        token: String(result.data.token),
        lastSequence: localEventBaseline,
        lastTransportSequence: 0,
        lastPacketAt: 0,
        audioHealthy: true,
        lastHealthyTransport: null,
        lastObservedControlSequence: safeSequence(
          status?.transport?.controlSequence),
        resumeControlSequenceFloor: null,
        localSessionId,
        localManifestRevision: status.mode === 'project_sync'
          ? projectSyncManifestRevision(status)
          : '',
        localStructuralRevision: status.mode === 'project_sync'
          ? localStructuralRevision
          : '',
        remoteSessionId: status.mode === 'project_sync'
          ? String(result.data.receiverSessionId || '').trim()
          : '',
        remoteManifestRevision: status.mode === 'project_sync'
          ? String(result.data.manifestRevision || '').trim().slice(0, 256)
          : '',
        remoteStructuralRevision: status.mode === 'project_sync'
          ? String(result.data.structuralManifestRevision ||
              result.data.manifestRevision || '').trim().slice(0, 256)
          : '',
        failures: 0,
        connected: true,
      }
      // Project Sync e estritamente A -> B. O PC A nunca cria uma sessao de
      // recepcao reversa e, portanto, o escravo nao pode devolver comandos.
      if (status.mode === 'project_sync') receiverSession = null
      if (status.mode === 'project_sync') {
        finishProjectSyncPairAttempt(
          safePreflightRequestId(result.data.requestId) ||
            proposedRequestId)
      }
      await notifyLocalPeer(true, transmitterPeer.name)
      return true
    } catch (_) {
      return false
    }
  }

  async function acceptOffer(message, rinfo) {
    const status = await readLocalStatus()
    if (!statusCanTransmit(status) || !isPairCode(status.code)) return
    if (String(message.code || '') !== String(status.code)) return
    if (String(message.transmitterId || '') !== instanceId) return
    if (status.mode === 'project_sync' &&
        Number(message.version) !== PROJECT_SYNC_PROTOCOL_VERSION) {
      await notifyProjectSyncProtocolMismatch(status, rinfo.address)
      return
    }
    if (status.mode === 'project_sync' &&
        !projectSyncRolesMatch(
          projectSyncRole(status), message.projectSyncRole)) return
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
      if (!statusCanReceive(status) || !isPairCode(status.code)) return
      if (String(message.code || '') !== String(status.code)) return
      if (status.mode === 'project_sync' &&
          Number(message.version) !== PROJECT_SYNC_PROTOCOL_VERSION) return
      if (status.mode === 'project_sync' &&
          !projectSyncRolesMatch(
            message.projectSyncRole, projectSyncRole(status))) return
      sendUdp({
        magic: OFFER_MAGIC,
        version: status.mode === 'project_sync'
          ? PROJECT_SYNC_PROTOCOL_VERSION
          : 1,
        code: status.code,
        transmitterId: String(message.transmitterId || ''),
        receiverId: instanceId,
        receiverName: deviceName(),
        port: Number(getDirectorPort()) || 47831,
        projectSyncRole: projectSyncRole(status),
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

    const currentLocalSessionId = String(status.sessionId || '').trim()
    const currentLocalManifestRevision = projectSyncManifestRevision(status)
    const currentLocalStructuralRevision =
      projectSyncStructuralRevision(status)
    const localProjectChanged = status.mode === 'project_sync' &&
      transmitterPeer.localStructuralRevision !==
        currentLocalStructuralRevision
    if (transmitterPeer.localSessionId !== currentLocalSessionId ||
        localProjectChanged) {
      if (localProjectChanged) {
        await sendLocalCommand({
          type: 'project_sync_preflight',
          role: 'primary',
          ready: false,
          diff: projectSyncManifestChangedDiff(
            'primary', transmitterPeer.localStructuralRevision,
            currentLocalStructuralRevision),
        })
      }
      resetTransmitterPeer(true)
      resetReceiverSession(false)
      return
    }
    if (status.mode === 'project_sync') {
      // A revisao completa inclui configuracoes e pode mudar legitimamente sem
      // derrubar o link. Mantem o retrato da sessao atual para diagnostico; a
      // decisao de novo preflight continua baseada somente na parte estrutural.
      transmitterPeer.localManifestRevision = currentLocalManifestRevision
    }

    try {
      let packet = {
        events: [],
        transport: status.transport || {},
        latestSequence: safeSequence(status.eventSequence),
      }
      const statusPublishesEventSequence =
        Number.isFinite(Number(status.eventSequence))
      if (!statusPublishesEventSequence ||
          packet.latestSequence > transmitterPeer.lastSequence) {
        const outboxResult = await requestJson({
          hostname: '127.0.0.1',
          port: nativeBridgePort,
          path: '/timecode/outbox',
          method: 'POST',
          payload: { after: transmitterPeer.lastSequence },
          timeoutMs: 500,
        })
        if (!outboxResult.ok || !outboxResult.data?.ok) {
          throw new Error('Outbox indisponível.')
        }
        packet = outboxResult.data
      }
      const events = Array.isArray(packet.events)
        ? packet.events.slice(0, 256)
        : []
      // Eventos de configuracao usam o mesmo envelope confiavel dos demais.
      // Nao filtre project_sync_config_snapshot/patch aqui: a extensao e quem
      // produz e aplica o payload generico (cores, Teleprompt e demais ajustes).
      const rawTransport = packet.transport || status.transport || {}
      const audioHealthy = transportAudioHealthy(status, rawTransport)
      const transport = projectSyncTransportForSend(
        status, transmitterPeer, rawTransport)
      const transportSequence = transport
        ? safeSequence(transport.sequence)
        : (transmitterPeer.lastTransportSequence || 0)
      const shouldSend = events.length > 0 ||
        (!!transport && transportSequence !==
          (transmitterPeer.lastTransportSequence || 0)) ||
        now - (transmitterPeer.lastPacketAt || 0) >=
          IDLE_LINK_HEARTBEAT_MS
      if (!shouldSend) {
        transmitterPeer.failures = 0
        return
      }
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
          sessionId: currentLocalSessionId,
          projectSyncRole: projectSyncRole(status),
          manifestRevision: status.mode === 'project_sync'
            ? projectSyncManifestRevision(status)
            : undefined,
          structuralRevision: status.mode === 'project_sync'
            ? currentLocalStructuralRevision
            : undefined,
          events,
          transport,
          audioHealthy,
        },
        timeoutMs: 800,
      })
      if (status.mode === 'project_sync' &&
          remoteResult.data?.preflightRequired === true) {
        await sendLocalCommand({
          type: 'project_sync_preflight',
          role: 'primary',
          ready: false,
          diff: remoteResult.data.diff ||
            projectSyncManifestChangedDiff(
              'secondary', transmitterPeer.remoteStructuralRevision,
              remoteResult.data?.structuralManifestRevision ||
                remoteResult.data?.manifestRevision),
          remoteManifestRevision: String(
            remoteResult.data?.manifestRevision || ''),
        })
        resetTransmitterPeer(true)
        return
      }
      if (!remoteResult.ok || !remoteResult.data?.ok) throw new Error('Receiver indisponível.')
      if (status.mode === 'project_sync') {
        const remoteSessionId = String(
          remoteResult.data.receiverSessionId || '').trim()
        const remoteManifestRevision = String(
          remoteResult.data.manifestRevision || '').trim().slice(0, 256)
        const remoteStructuralRevision = String(
          remoteResult.data.structuralManifestRevision ||
          remoteResult.data.manifestRevision || '').trim().slice(0, 256)
        if (!remoteSessionId || !remoteManifestRevision ||
            !remoteStructuralRevision ||
            remoteSessionId !== transmitterPeer.remoteSessionId ||
            remoteStructuralRevision !==
              transmitterPeer.remoteStructuralRevision) {
          await sendLocalCommand({
            type: 'project_sync_preflight',
            role: 'primary',
            ready: false,
            diff: projectSyncManifestChangedDiff(
              'secondary', transmitterPeer.remoteStructuralRevision,
              remoteStructuralRevision),
            remoteManifestRevision,
          })
          resetTransmitterPeer(true)
          return
        }
        transmitterPeer.remoteManifestRevision = remoteManifestRevision
      }
      const acknowledged = Number(remoteResult.data.acceptedSequence)
      const highestSentSequence = events.reduce((highest, event) => {
        const sequence = Number(event?.sequence)
        return Number.isSafeInteger(sequence) && sequence >= 0
          ? Math.max(highest, sequence)
          : highest
      }, transmitterPeer.lastSequence)
      if (Number.isSafeInteger(acknowledged) &&
          acknowledged >= transmitterPeer.lastSequence &&
          acknowledged <= highestSentSequence) {
        transmitterPeer.lastSequence = acknowledged
      }
      if (transport) {
        transmitterPeer.lastTransportSequence = transportSequence
      }
      transmitterPeer.lastPacketAt = Date.now()
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
      cleanupProjectSyncStaging(false).catch(() => {})
      const status = await readLocalStatus()
      if (!licenseIsActive() || !status || !isPairCode(status.code)) {
        if (transmitterPeer) resetTransmitterPeer(true)
        if (receiverSession) resetReceiverSession(true)
        pendingProjectSyncPreflight = null
        projectSyncPairAttempt = null
        projectSyncApplyPeer = null
        projectSyncApplySession = null
        projectSyncExportBundle = null
        return
      }

      if (status.mode === 'transmitter') {
        projectSyncApplyPeer = null
        projectSyncApplySession = null
        projectSyncExportBundle = null
        if (receiverSession) resetReceiverSession(false)
        await transmitTick(status)
      } else if (status.mode === 'receive') {
        projectSyncApplyPeer = null
        projectSyncApplySession = null
        projectSyncExportBundle = null
        if (transmitterPeer) resetTransmitterPeer(false)
        if (receiverSession && Date.now() - receiverSession.lastSeenAt > RECEIVER_TIMEOUT_MS) {
          resetReceiverSession(true)
        }
      } else if (status.mode === 'project_sync') {
        if (projectSyncRole(status) === 'primary') {
          pendingProjectSyncPreflight = null
          projectSyncApplySession = null
          if (receiverSession) resetReceiverSession(false)
          await transmitTick(status)
        } else if (projectSyncRole(status) === 'secondary') {
          projectSyncPairAttempt = null
          projectSyncApplyPeer = null
          projectSyncExportBundle = null
          if (transmitterPeer) resetTransmitterPeer(false)
          if (receiverSession &&
              (String(status.sessionId || '').trim() !==
                 receiverSession.localSessionId ||
               projectSyncStructuralRevision(status) !==
                 receiverSession.localStructuralRevision)) {
            // O projeto B mudou enquanto o vínculo estava ativo. Derruba apenas
            // a autorização LAN; o transporte do REAPER B continua intacto.
            resetReceiverSession(true)
          }
          if (receiverSession && Date.now() - receiverSession.lastSeenAt > RECEIVER_TIMEOUT_MS) {
            // Perder heartbeat apenas desfaz o link visual. Nao injeta Stop no
            // REAPER B: ele segue tocando para o chaveamento redundante/SW8.
            resetReceiverSession(true)
          }
          if (pendingProjectSyncPreflight &&
              !pendingProjectSyncPreflight.completedResponse &&
              Date.now() - pendingProjectSyncPreflight.createdAt >
                PROJECT_SYNC_PREFLIGHT_TTL_MS) {
            pendingProjectSyncPreflight = null
          }
          maybeStartProjectSyncBundlePull(status)
        } else {
          // Versoes anteriores nao gravavam o papel A/B. Obriga o usuario a
          // reabrir Project Sync e gerar/digitar o codigo uma unica vez.
          if (transmitterPeer) resetTransmitterPeer(true)
          if (receiverSession) resetReceiverSession(true)
          pendingProjectSyncPreflight = null
          projectSyncPairAttempt = null
          projectSyncApplyPeer = null
          projectSyncApplySession = null
          projectSyncExportBundle = null
        }
      } else {
        if (transmitterPeer) resetTransmitterPeer(true)
        if (receiverSession) resetReceiverSession(true)
        pendingProjectSyncPreflight = null
        projectSyncPairAttempt = null
        projectSyncApplyPeer = null
        projectSyncApplySession = null
        projectSyncExportBundle = null
      }
    } finally {
      tickRunning = false
    }
  }

  function pendingPreflightMatches(pending, payload, transmitterId,
    remoteSessionId, manifestRevision, localSessionId,
    remoteStructuralRevision,
    localStructuralRevision) {
    return !!pending &&
      Date.now() - pending.createdAt < PROJECT_SYNC_PREFLIGHT_TTL_MS &&
      pending.requestId === safePreflightRequestId(payload.requestId) &&
      pending.code === String(payload.code || '') &&
      pending.transmitterId === transmitterId &&
      pending.remoteSessionId === remoteSessionId &&
      pending.manifestRevision === manifestRevision &&
      pending.localSessionId === localSessionId &&
      pending.remoteStructuralRevision === remoteStructuralRevision &&
      pending.localStructuralRevision === localStructuralRevision
  }

  async function completePendingProjectSyncPreflight(status, pending, result) {
    const response = {
      ok: true,
      projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
      completed: true,
      pending: false,
      requestId: pending.requestId,
      receiverId: instanceId,
      receiverName: deviceName(),
      receiverSessionId: String(status.sessionId || '').trim(),
      projectSyncRole: 'secondary',
      ready: result.ready === true,
      diff: result.diff || null,
      manifestRevision: result.manifestRevision ||
        String(status.manifestRevision || ''),
      structuralManifestRevision:
        projectSyncStructuralRevision(status),
    }
    if (response.ready) {
      projectSyncApplySession = null
      lastProjectSyncApplyKey = ''
      pending.completedResponse = null
      receiverSession = {
        token: pending.token,
        code: pending.code,
        transmitterId: pending.transmitterId,
        remoteSessionId: pending.remoteSessionId,
        remoteManifestRevision: pending.manifestRevision,
        remoteStructuralRevision: pending.remoteStructuralRevision,
        localSessionId: pending.localSessionId,
        localManifestRevision: projectSyncManifestRevision(status),
        localStructuralRevision: pending.localStructuralRevision,
        name: pending.name,
        lastSequence: pending.remoteEventBaseline,
        lastTransportSequence: 0,
        lastControlSequence: -1,
        lastSourceTransport: null,
        lastSeenAt: Date.now(),
      }
      // Project Sync e estritamente A -> B. B jamais cria o canal reverso.
      transmitterPeer = null
      response.token = pending.token
      await notifyLocalPeer(true, pending.name)
    } else {
      // O preflight bloqueado continua autorizado apenas para o fluxo de
      // "Aplicar modificações". Este token forte não autoriza eventos nem
      // transporte; serve exclusivamente para puxar o bundle A -> B.
      response.applyToken = pending.token
      projectSyncApplySession = {
        requestId: pending.requestId,
        token: pending.token,
        code: pending.code,
        transmitterId: pending.transmitterId,
        remoteSessionId: pending.remoteSessionId,
        remoteManifestRevision: pending.manifestRevision,
        remoteStructuralRevision: pending.remoteStructuralRevision,
        localSessionId: pending.localSessionId,
        localManifestRevision: projectSyncManifestRevision(status),
        localStructuralRevision: pending.localStructuralRevision,
        address: pending.address,
        port: pending.port,
        name: pending.name,
        createdAt: Date.now(),
      }
      // O resultado permanece consultável enquanto o modal está aberto; a
      // autorização de transferência tem TTL próprio de 30 minutos.
    }
    if (!response.ready) {
      pending.completedResponse = response
      pending.completedAt = Date.now()
    }
    return response
  }

  async function currentPendingPreflightResult(pending) {
    const status = await readLocalStatus(true)
    if (!statusCanReceive(status) ||
        projectSyncRole(status) !== 'secondary') return null
    const currentLocalSessionId = String(status.sessionId || '').trim()
    const currentLocalStructuralRevision =
      projectSyncStructuralRevision(status)
    if (currentLocalSessionId !== pending.localSessionId ||
        currentLocalStructuralRevision !== pending.localStructuralRevision) {
      // Mesmo uma resposta ja concluida deixa de ser valida se B mudou antes
      // de A terminar o handshake. Sem esta checagem, o cache poderia anunciar
      // "ready" por alguns milissegundos para um projeto estruturalmente novo.
      if (receiverSession) resetReceiverSession(true)
      return completePendingProjectSyncPreflight(status, pending, {
        ready: false,
        diff: projectSyncManifestChangedDiff(
          'secondary', pending.localStructuralRevision,
          currentLocalStructuralRevision),
        manifestRevision: projectSyncManifestRevision(status),
      })
    }
    if (pending.completedResponse) {
      // Configuracoes podem ter sido aplicadas depois que o resultado ficou
      // pronto. Atualiza somente a revisao completa; a estrutural ja foi
      // validada acima e permanece sendo o gate do pareamento.
      pending.completedResponse.manifestRevision =
        projectSyncManifestRevision(status)
      pending.completedResponse.structuralManifestRevision =
        currentLocalStructuralRevision
      return pending.completedResponse
    }
    const result = preflightResultFromStatus(status, pending.requestId)
    if (!result) return null
    return completePendingProjectSyncPreflight(status, pending, result)
  }

  async function handlePair(req, res) {
    if (!licenseIsActive()) {
      sendJson(res, 403, { ok: false, error: 'Licença VS Hook inativa.' })
      return
    }
    // O pareamento Project Sync tambem pode carregar o manifesto sanitizado do
    // projeto. Usa o mesmo limite defensivo dos demais pacotes LAN.
    const payload = await readJsonBody(req)
    if (!peerAddressAllowed(req.socket?.remoteAddress)) {
      sendJson(res, 409, { ok: false, error: 'A conexão redundante deve usar o cabo configurado.' })
      return
    }
    let status = await readLocalStatus(true)
    if (String(payload.mode || '') === 'project_sync' &&
        Number(payload.protocolVersion) !== PROJECT_SYNC_PROTOCOL_VERSION) {
      sendJson(res, 426, {
        ok: false,
        error: 'Hook Center incompatível. Atualize a Hook Center nos dois PCs.',
        projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
      })
      return
    }
    const code = String(payload.code || '').trim()
    if (!statusCanReceive(status) ||
        !isPairCode(status.code) || code !== String(status.code)) {
      sendJson(res, 403, { ok: false, error: 'Código de pareamento inválido.' })
      return
    }
    const transmitterId = String(payload.transmitterId || '').trim()
    if (!transmitterId || transmitterId === instanceId) {
      sendJson(res, 400, { ok: false, error: 'Transmissor inválido.' })
      return
    }
    if (status.mode === 'project_sync' &&
        !projectSyncRolesMatch(
          payload.projectSyncRole, projectSyncRole(status))) {
      sendJson(res, 409, { ok: false, error: 'Somente o PC A pode iniciar o Project Sync.' })
      return
    }
    const remoteSessionId = String(payload.sessionId || '').trim()
    if (status.mode === 'project_sync' && !remoteSessionId) {
      sendJson(res, 409, {
        ok: false,
        error: 'A sessão do PC A é inválida. Atualize a extensão VS Hook.',
      })
      return
    }
    if (status.mode === 'project_sync') {
      const proposedRequestId = safePreflightRequestId(payload.requestId)
      if (!proposedRequestId) {
        sendJson(res, 400, {
          ok: false,
          ready: false,
          error: 'Identificador de preflight inválido.',
        })
        return
      }
      const manifestRevision = String(
        payload.manifestRevision || '').trim().slice(0, 256)
      const localSessionId = String(status.sessionId || '').trim()
      const localManifestRevision = projectSyncManifestRevision(status)
      const remoteStructuralRevision = String(
        payload.structuralManifestRevision ||
        payload.manifestRevision || '').trim().slice(0, 256)
      const localStructuralRevision =
        projectSyncStructuralRevision(status)
      const incomingAddress = normalizePeerAddress(req.socket?.remoteAddress)
      if (projectSyncApplySession &&
          Date.now() - projectSyncApplySession.createdAt <
            PROJECT_SYNC_APPLY_TTL_MS &&
          (projectSyncApplySession.transmitterId !== transmitterId ||
           normalizePeerAddress(projectSyncApplySession.address) !==
             incomingAddress)) {
        sendJson(res, 409, {
          ok: false,
          ready: false,
          error: 'O PC B já aguarda aplicação do PC A pareado.',
        })
        return
      }
      if (pendingProjectSyncPreflight &&
          Date.now() - pendingProjectSyncPreflight.createdAt <
            PROJECT_SYNC_PREFLIGHT_TTL_MS &&
          (pendingProjectSyncPreflight.transmitterId !== transmitterId ||
           normalizePeerAddress(pendingProjectSyncPreflight.address) !==
             incomingAddress)) {
        sendJson(res, 409, {
          ok: false,
          ready: false,
          error: 'Já existe um preflight Project Sync em andamento.',
        })
        return
      }
      if (!localSessionId || !localManifestRevision || !manifestRevision ||
          !remoteStructuralRevision || !localStructuralRevision) {
        sendJson(res, 409, {
          ok: false,
          ready: false,
          error: 'O manifesto estrutural do projeto ainda não está disponível.',
        })
        return
      }
      if (!pendingPreflightMatches(
        pendingProjectSyncPreflight, payload, transmitterId,
        remoteSessionId, manifestRevision, localSessionId,
        remoteStructuralRevision,
        localStructuralRevision)) {
        pendingProjectSyncPreflight = {
          requestId: proposedRequestId,
          token: crypto.randomBytes(32).toString('hex'),
          code,
          transmitterId,
          remoteSessionId,
          manifestRevision,
          remoteStructuralRevision,
          localSessionId,
          localManifestRevision,
          localStructuralRevision,
          name: safeName(payload.transmitterName, 'Transmitter'),
          address: normalizePeerAddress(req.socket?.remoteAddress),
          port: Math.max(1, Math.min(65535,
            Number(payload.transmitterPort) || 47831)),
          remoteEventBaseline: Math.max(0,
            safeSequence(payload.eventSequence)),
          createdAt: Date.now(),
          completedResponse: null,
        }
        const preflightAccepted = await sendLocalCommand({
          type: 'project_sync_preflight',
          role: 'secondary',
          requestId: pendingProjectSyncPreflight.requestId,
          manifest: payload.manifest || null,
          manifestRevision,
          transmitterId,
        })
        if (!preflightAccepted) {
          if (pendingProjectSyncPreflight?.requestId === proposedRequestId) {
            pendingProjectSyncPreflight = null
          }
          sendJson(res, 503, {
            ok: false,
            ready: false,
            error: 'A extensão VS Hook não aceitou o manifesto do PC A.',
          })
          return
        }
      } else {
        // Enquanto a janela de diferenças está aberta, as sondagens do mesmo
        // PC A mantêm a autorização de aplicação viva sem trocar token.
        pendingProjectSyncPreflight.createdAt = Date.now()
      }

      // Nao le projectSyncReady sem antes conferir o requestId. A extensao
      // processa o comando na thread principal e normalmente termina depois
      // desta requisicao HTTP; o PC A continuara pela rota /preflight.
      const completed = await currentPendingPreflightResult(
        pendingProjectSyncPreflight)
      if (completed) {
        sendJson(res, 200, completed)
      } else {
        sendJson(res, 202, {
          ok: true,
          projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
          completed: false,
          pending: true,
          requestId: pendingProjectSyncPreflight.requestId,
          receiverId: instanceId,
          receiverName: deviceName(),
          projectSyncRole: 'secondary',
        })
      }
      return
    }
    const projectSyncReady = status.mode !== 'project_sync' ||
      status.projectSyncReady === true
    const sameTransmitter = receiverSession &&
      receiverSession.code === code &&
      receiverSession.transmitterId === transmitterId &&
      receiverSession.remoteSessionId === remoteSessionId
    const remoteEventBaseline = safeSequence(payload.eventSequence)
    const localEventBaseline = safeSequence(status.eventSequence)
    const token = sameTransmitter
      ? receiverSession.token
      : crypto.randomBytes(32).toString('hex')
    receiverSession = {
      token,
      code,
      transmitterId,
      remoteSessionId,
      name: safeName(payload.transmitterName, 'Transmitter'),
      lastSequence: sameTransmitter
        ? Math.max(receiverSession.lastSequence, remoteEventBaseline)
        : remoteEventBaseline,
      lastTransportSequence: sameTransmitter
        ? Math.max(0, Math.trunc(Number(
            receiverSession.lastTransportSequence) || 0))
        : 0,
      lastControlSequence: sameTransmitter
        ? Math.max(-1, Math.trunc(Number(
            receiverSession.lastControlSequence) || 0))
        : -1,
      lastSourceTransport: sameTransmitter
        ? (receiverSession.lastSourceTransport || null)
        : null,
      lastSeenAt: Date.now(),
    }
    if (projectSyncReady) {
      await notifyLocalPeer(true, receiverSession.name)
    }
    sendJson(res, 200, {
      ok: true,
      token,
      receiverId: instanceId,
      receiverName: deviceName(),
      receiverSessionId: String(status.sessionId || '').trim(),
      projectSyncRole: projectSyncRole(status),
      ready: projectSyncReady,
      diff: status.mode === 'project_sync'
        ? (status.projectSyncDiff || null)
        : undefined,
      manifestRevision: status.mode === 'project_sync'
        ? String(status.manifestRevision || '')
        : undefined,
    })
  }

  async function handleProjectSyncPreflight(req, res) {
    if (!licenseIsActive()) {
      sendJson(res, 403, { ok: false, error: 'Licença VS Hook inativa.' })
      return
    }
    const payload = await readJsonBody(req, 64 * 1024)
    if (!peerAddressAllowed(req.socket?.remoteAddress)) {
      sendJson(res, 409, {
        ok: false,
        error: 'A conexão redundante deve usar o cabo configurado.',
      })
      return
    }
    const status = await readLocalStatus(false)
    const requestId = safePreflightRequestId(payload.requestId)
    const pending = pendingProjectSyncPreflight
    if (!statusCanReceive(status) ||
        projectSyncRole(status) !== 'secondary' ||
        !projectSyncRolesMatch(payload.projectSyncRole, 'secondary')) {
      sendJson(res, 409, {
        ok: false,
        error: 'O PC B não está disponível como receptor do Project Sync.',
      })
      return
    }
    if (!pending || !requestId || pending.requestId !== requestId ||
        pending.code !== String(payload.code || '') ||
        pending.transmitterId !== String(payload.transmitterId || '') ||
        pending.remoteSessionId !== String(payload.sessionId || '')) {
      sendJson(res, 404, {
        ok: false,
        error: 'Preflight não encontrado.',
      })
      return
    }
    if (Date.now() - pending.createdAt > PROJECT_SYNC_PREFLIGHT_TTL_MS) {
      pendingProjectSyncPreflight = null
      sendJson(res, 410, {
        ok: false,
        error: 'O preflight expirou.',
      })
      return
    }
    const completed = await currentPendingPreflightResult(pending)
    if (completed) {
      sendJson(res, 200, completed)
      return
    }
    sendJson(res, 202, {
      ok: true,
      projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
      completed: false,
      pending: true,
      requestId,
      receiverId: instanceId,
      receiverName: deviceName(),
      projectSyncRole: 'secondary',
    })
  }

function tokenMatches(left, right) {
    const a = Buffer.from(String(left || ''), 'utf8')
    const b = Buffer.from(String(right || ''), 'utf8')
    return a.length > 0 && a.length === b.length && crypto.timingSafeEqual(a, b)
  }

  async function handleEvents(req, res) {
    const payload = await readJsonBody(req)
    const status = await readLocalStatus(false)
    if (!licenseIsActive() || !statusCanReceive(status) ||
        !receiverSession || String(payload.code || '') !== String(status.code) ||
        String(payload.transmitterId || '') !== receiverSession.transmitterId ||
        String(payload.sessionId || '') !== receiverSession.remoteSessionId ||
        !tokenMatches(payload.token, receiverSession.token)) {
      sendJson(res, 403, { ok: false, error: 'Pareamento expirado.' })
      return
    }
    if (status.mode === 'project_sync' &&
        !projectSyncRolesMatch(
          payload.projectSyncRole, projectSyncRole(status))) {
      sendJson(res, 409, {
        ok: false,
        error: 'O PC B aceita somente eventos enviados pelo PC A.',
      })
      return
    }
    if (status.mode === 'project_sync') {
      const currentLocalSessionId = String(status.sessionId || '').trim()
      const currentLocalStructuralRevision =
        projectSyncStructuralRevision(status)
      const currentRemoteStructuralRevision = String(
        payload.structuralRevision ||
        payload.manifestRevision || '').trim().slice(0, 256)
      const localProjectChanged =
        currentLocalSessionId !== receiverSession.localSessionId ||
        currentLocalStructuralRevision !==
          receiverSession.localStructuralRevision
      const remoteProjectChanged =
        !currentRemoteStructuralRevision ||
        currentRemoteStructuralRevision !==
          receiverSession.remoteStructuralRevision
      if (localProjectChanged || remoteProjectChanged) {
        const previousLocalStructuralRevision =
          receiverSession.localStructuralRevision
        const previousRemoteStructuralRevision =
          receiverSession.remoteStructuralRevision
        resetReceiverSession(true)
        sendJson(res, 409, {
          ok: false,
          preflightRequired: true,
          receiverSessionId: currentLocalSessionId,
          manifestRevision: projectSyncManifestRevision(status),
          structuralManifestRevision:
            currentLocalStructuralRevision,
          diff: projectSyncManifestChangedDiff(
            localProjectChanged ? 'secondary' : 'primary',
            localProjectChanged
              ? previousLocalStructuralRevision
              : previousRemoteStructuralRevision,
            localProjectChanged
              ? currentLocalStructuralRevision
              : currentRemoteStructuralRevision),
          error: 'O projeto mudou depois do pareamento. Novo preflight obrigatório.',
        })
        return
      }
      receiverSession.localManifestRevision =
        projectSyncManifestRevision(status)
      const currentRemoteManifestRevision = String(
        payload.manifestRevision || '').trim().slice(0, 256)
      if (currentRemoteManifestRevision) {
        receiverSession.remoteManifestRevision = currentRemoteManifestRevision
      }
    }

    const incoming = Array.isArray(payload.events) ? payload.events.slice(0, 256) : []
    const commands = []
    let acceptedSequence = receiverSession.lastSequence
    for (const event of incoming) {
      const sequence = safeSequence(event?.sequence, -1)
      if (sequence < 0) continue
      if (sequence <= acceptedSequence || !event?.command || typeof event.command !== 'object') continue
      commands.push(JSON.stringify({
        ...event.command,
        __vshookLanRemote: true,
      }))
      acceptedSequence = Math.max(acceptedSequence, sequence)
    }
    const rawTransport = payload.transport && typeof payload.transport === 'object'
      ? payload.transport
      : null
    const transportSequence = safeSequence(rawTransport?.sequence)
    const lastTransportSequence = safeSequence(
      receiverSession.lastTransportSequence)
    const transportIsFresh = !!rawTransport &&
      (transportSequence > lastTransportSequence ||
       status.mode !== 'project_sync' && transportSequence === 0)
    const transport = transportIsFresh
      ? projectSyncTransportForReceive(
          receiverSession, status, payload, rawTransport)
      : null
    const acceptTransport = !!transport
    if (acceptTransport) {
      commands.push(JSON.stringify({
        type: 'timecode_transport_sync',
        playState: Math.max(0, Math.trunc(Number(transport.playState) || 0)),
        position: Math.max(0, Number(transport.position) || 0),
        sequence: safeSequence(transport.sequence),
        controlSequence: safeSequence(transport.controlSequence),
        sampledAtMs: Math.trunc(Number(transport.sampledAtMs) || 0),
        audioHealthy: transportAudioHealthy(payload, transport),
        explicitControl: transport.explicitControl === true,
        __vshookLanRemote: true,
      }))
    }

    if (commands.length > 0) {
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
    }
    receiverSession.lastSequence = acceptedSequence
    if (acceptTransport) {
      receiverSession.lastTransportSequence = transportSequence
    }
    receiverSession.lastSeenAt = Date.now()
    sendJson(res, 200, {
      ok: true,
      acceptedSequence,
      receiverSessionId: status.mode === 'project_sync'
        ? String(status.sessionId || '').trim()
        : undefined,
      manifestRevision: status.mode === 'project_sync'
        ? projectSyncManifestRevision(status)
        : undefined,
      structuralManifestRevision: status.mode === 'project_sync'
        ? projectSyncStructuralRevision(status)
        : undefined,
    })
  }

  async function handleHttp(req, res, parsedUrl) {
    const pathname = String(parsedUrl?.pathname || '')
    if (!pathname.startsWith('/timecode-link/')) return false
    try {
      if (req.method === 'POST' &&
          pathname === '/timecode-link/capabilities') {
        // Somente leitura: permite ao PC A rejeitar uma Central antiga antes
        // que /pair altere qualquer estado no PC B.
        sendJson(res, 200, {
          ok: true,
          projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
          projectSyncPreflight: true,
          projectSyncDirection: 'primary_to_secondary',
        })
      } else if (req.method === 'POST' && pathname === '/timecode-link/pair') {
        await handlePair(req, res)
      } else if (req.method === 'POST' && pathname === '/timecode-link/preflight') {
        await handleProjectSyncPreflight(req, res)
      } else if (req.method === 'POST' &&
          pathname === '/timecode-link/project-sync/bundle/manifest') {
        await handleProjectSyncBundleManifest(req, res)
      } else if (req.method === 'POST' &&
          pathname === '/timecode-link/project-sync/bundle/file') {
        await handleProjectSyncBundleFile(req, res)
      } else if (req.method === 'POST' &&
          pathname === '/timecode-link/project-sync/bundle/consumed') {
        await handleProjectSyncBundleConsumed(req, res)
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
    cleanupProjectSyncStaging(true).catch(() => {})
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
    relayLifecycleSequence += 1
    if (tickTimer) clearInterval(tickTimer)
    tickTimer = null
    resetTransmitterPeer(false)
    resetReceiverSession(false)
    pendingProjectSyncPreflight = null
    projectSyncPairAttempt = null
    projectSyncApplyPeer = null
    projectSyncApplySession = null
    projectSyncExportBundle = null
    lastProjectSyncApplyKey = ''
    projectSyncProtocolNotices.clear()
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
