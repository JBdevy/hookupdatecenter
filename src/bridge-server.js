const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { URL } = require('url')
const { createQrSvg } = require('./qr-svg')

let electronNativeImage = null
try {
  electronNativeImage = require('electron').nativeImage || null
} catch (_) {}

const PROJECT_STALE_MS = 20000
const MAX_LAST_GOOD_STATE_AGE_MS = 5 * 60 * 1000

function parseDateMs(value) {
  if (!value) return 0
  if (typeof value === 'number' && Number.isFinite(value)) return value
  const ms = Date.parse(String(value))
  return Number.isFinite(ms) ? ms : 0
}

function isStateFresh(state) {
  const lastMs = Math.max(
    parseDateMs(state?.heartbeatAt),
    parseDateMs(state?.lastHeartbeatAt),
    parseDateMs(state?.updatedAt),
    parseDateMs(state?.stateUpdatedAt)
  )

  if (!lastMs) {
    // Se o state tem conteúdo real mas veio sem timestamp por algum motivo,
    // não derruba a descoberta imediatamente.
    if (state && (Array.isArray(state.projects) || Array.isArray(state.projectTabs) || state.projectName || state.currentProjectName)) {
      return true
    }
    return false
  }

  return Date.now() - lastMs <= PROJECT_STALE_MS
}

function getProjectId(project, index) {
  const raw = project && typeof project === 'object'
    ? (project.id ?? project.projectId ?? project.guid ?? project.path ?? project.projectPath ?? project.name ?? project.projectName)
    : project
  const value = String(raw ?? '').trim()
  return value || `project-${index + 1}`
}

function getProjectName(project, index) {
  const raw = project && typeof project === 'object'
    ? (project.name ?? project.projectName ?? project.title ?? project.label)
    : project
  const value = String(raw ?? '').trim()
  if (value) return value

  const projectPath = getProjectPath(project)
  if (projectPath) {
    const baseName = path.basename(projectPath).replace(/\.rpp$/i, '').trim()
    if (baseName) return baseName
  }

  return ''
}

function getProjectPath(project) {
  if (!project || typeof project !== 'object') return ''
  return String(project.path ?? project.projectPath ?? '').trim()
}

function isFakeProjectName(name) {
  const value = String(name || '').trim().toLowerCase().replace(/\s+/g, ' ')
  return !value
    || value === 'projeto vs hook'
    || value === 'vs hook'
    || value === 'demo'
    || value === 'projeto demo'
}

function normalizeProjectsFromState(state) {
  const candidateLists = [
    state?.projects,
    state?.openProjects,
    state?.projectTabs,
    state?.tabs,
    state?.reaperProjects,
    state?.availableProjects,
  ]

  let source = []
  for (const list of candidateLists) {
    if (Array.isArray(list) && list.length) {
      source = list
      break
    }
  }

  if (!source.length) {
    const projectName = String(state?.projectName || state?.currentProjectName || state?.project || '').trim()
    const projectPath = String(state?.projectPath || '').trim()
    if (projectName || projectPath) {
      source = [{
        id: state?.projectId || state?.activeProjectId || projectPath || projectName,
        name: projectName,
        path: projectPath,
      }]
    }
  }

  const activeRaw = String(state?.activeProjectId ?? state?.currentProjectId ?? state?.selectedProjectId ?? state?.projectId ?? '').trim()
  const seen = new Set()
  return source.map((item, index) => {
    const id = getProjectId(item, index)
    const name = getProjectName(item, index)
    const projectPath = getProjectPath(item)
    const active = Boolean(
      (item && typeof item === 'object' && (item.active || item.isActive || item.selected)) ||
      (activeRaw && id === activeRaw)
    )
    return { id, name, projectName: name, projectPath, active }
  }).filter((project) => {
    if (!project.name) return false
    if (isFakeProjectName(project.name)) return false
    const key = `${project.id}|${project.projectPath}|${project.name}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

function stateLooksConnected(state) {
  if (!state) return false
  if (Array.isArray(state.projects) && state.projects.length) return true
  if (Array.isArray(state.projectTabs) && state.projectTabs.length) return true

  const projectName = String(state.projectName || state.currentProjectName || '').trim()
  const projectPath = String(state.projectPath || '').trim()
  if (projectPath) return true
  if (projectName && !isFakeProjectName(projectName)) return true

  return false
}


function buildProjectPayload(state) {
  const fresh = isStateFresh(state)
  const looksConnected = stateLooksConnected(state)

  // Não some com os projetos imediatamente quando o heartbeat atrasa.
  // O app precisa conseguir reencontrar o projeto depois de ficar aberto por muito tempo.
  const projects = looksConnected ? normalizeProjectsFromState(state) : []
  const connected = looksConnected && projects.length > 0 && (fresh || projects.length > 0)

  const activeProject = projects.find((project) => project.active) || projects[0] || null

  return {
    connected,
    projects,
    projectCount: projects.length,
    activeProject,
    projectName: activeProject ? activeProject.name : '',
    projectPath: activeProject ? activeProject.projectPath : '',
    stale: !fresh,
    staleAfterMs: PROJECT_STALE_MS,
  }
}


function stripProjectPathsForPublicApp(value) {
  if (Array.isArray(value)) return value.map((item) => stripProjectPathsForPublicApp(item))
  if (!value || typeof value !== 'object') return value

  const out = {}
  for (const [key, entry] of Object.entries(value)) {
    if (/^(path|projectPath|filePath|fullPath|absolutePath|folder|directory)$/i.test(key)) continue
    out[key] = stripProjectPathsForPublicApp(entry)
  }
  return out
}

function buildPublicProjectPayload(state) {
  const payload = buildProjectPayload(state)
  const projects = Array.isArray(payload.projects)
    ? payload.projects.map((project) => stripProjectPathsForPublicApp(project))
    : []
  const activeProject = payload.activeProject ? stripProjectPathsForPublicApp(payload.activeProject) : null
  return {
    ...payload,
    projects,
    activeProject,
    projectPath: '',
  }
}

function buildPublicStatePayload(state) {
  const publicState = stripProjectPathsForPublicApp(state || {}) || {}
  delete publicState.projectPath
  delete publicState.path
  const projectPayload = buildPublicProjectPayload(state || {})
  return {
    ...publicState,
    connected: projectPayload.connected,
    stale: projectPayload.stale,
    projects: projectPayload.projects,
    openProjects: projectPayload.projects,
    projectTabs: projectPayload.projects,
    activeProject: projectPayload.activeProject,
    projectName: projectPayload.projectName,
    currentProjectName: projectPayload.projectName || publicState.currentProjectName || '',
    projectPath: '',
  }
}

function applyCorsHeaders(res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization')
  res.setHeader('Access-Control-Max-Age', '86400')
}

function handleCorsPreflight(req, res) {
  if (req.method === 'OPTIONS') {
    applyCorsHeaders(res)
    res.writeHead(204)
    res.end()
    return true
  }
  return false
}

function ensureJsonFile(filePath, fallbackObject) {
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true })
    if (!fs.existsSync(filePath)) {
      fs.writeFileSync(filePath, JSON.stringify(fallbackObject, null, 2), 'utf8')
    }
  } catch (error) {
    console.error(`[VS Hook Bridge] Erro ao garantir arquivo ${filePath}: ${error.message}`)
  }
}

const lastGoodJsonByFile = new Map()
const readJsonShortCacheByFile = new Map()
const READ_JSON_CACHE_TTL_MS = 60

const NATIVE_BRIDGE_PORT = Number(process.env.VSHOOK_NATIVE_BRIDGE_PORT || 47830)
const NATIVE_BRIDGE_CACHE_TTL_MS =
  process.platform === 'darwin' ? 300 : 180
const NATIVE_BRIDGE_MIN_REFRESH_INTERVAL_MS =
  process.platform === 'darwin' ? 300 : 180
const NATIVE_BRIDGE_BACKGROUND_POLL_MS =
  process.platform === 'darwin' ? 400 : 250
let nativeBridgeStateCache = null
let nativeBridgeStateCacheAt = 0
let nativeBridgeRefreshInFlight = null
let nativeBridgeBackgroundPollTimer = null
const nativeBridgeLicenseChecks = new Set()
const optimizedTelepromptImageCache = new Map()

function trySendOptimizedTelepromptImage(req, res, targetPath) {
  if (!electronNativeImage) return false
  let mediaPath = ''
  try {
    const parsed = new URL(targetPath, 'http://127.0.0.1')
    if (String(parsed.searchParams.get('preview') || '').toLowerCase() !== 'low') return false
    mediaPath = String(parsed.searchParams.get('path') || parsed.searchParams.get('file') || '').trim()
  } catch (_) {
    return false
  }
  if (!mediaPath) return false

  const extension = path.extname(mediaPath).slice(1).toLowerCase()
  if (!['png', 'jpg', 'jpeg', 'webp', 'bmp'].includes(extension)) return false

  try {
    const stat = fs.statSync(mediaPath)
    const cacheKey = `${mediaPath}|${stat.size}|${Math.floor(stat.mtimeMs)}`
    let jpeg = optimizedTelepromptImageCache.get(cacheKey)
    if (!jpeg) {
      const original = electronNativeImage.createFromPath(mediaPath)
      if (!original || original.isEmpty()) return false
      const size = original.getSize()
      const scale = Math.min(
        1,
        720 / Math.max(1, Number(size.width) || 1),
        405 / Math.max(1, Number(size.height) || 1)
      )
      const width = Math.max(1, Math.round(size.width * scale))
      const height = Math.max(1, Math.round(size.height * scale))
      const reduced = scale < 0.999
        ? original.resize({ width, height, quality: 'good' })
        : original
      jpeg = reduced.toJPEG(32)
      if (!jpeg || !jpeg.length) return false
      optimizedTelepromptImageCache.set(cacheKey, jpeg)
      while (optimizedTelepromptImageCache.size > 6) {
        optimizedTelepromptImageCache.delete(
          optimizedTelepromptImageCache.keys().next().value
        )
      }
    }
    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Content-Length': jpeg.length,
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,Range',
      'Cache-Control': 'private, max-age=120',
    })
    if (req.method !== 'HEAD') res.end(jpeg)
    else res.end()
    return true
  } catch (_) {
    return false
  }
}

function getTelepromptMediaContentType(mediaPath) {
  const extension = path.extname(String(mediaPath || '')).toLowerCase()
  return {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.bmp': 'image/bmp',
    '.svg': 'image/svg+xml',
    '.mp4': 'video/mp4',
    '.m4v': 'video/mp4',
    '.mov': 'video/quicktime',
    '.webm': 'video/webm',
    '.mkv': 'video/x-matroska',
    '.avi': 'video/x-msvideo',
  }[extension] || 'application/octet-stream'
}

function parseTelepromptByteRange(headerValue, totalSize) {
  const value = String(headerValue || '').trim()
  if (!value) return null
  const match = /^bytes=(\d*)-(\d*)/i.exec(value)
  if (!match || (!match[1] && !match[2]) || totalSize <= 0) {
    return { invalid: true }
  }

  let start = 0
  let end = totalSize - 1
  if (!match[1]) {
    const suffixLength = Number(match[2])
    if (!Number.isFinite(suffixLength) || suffixLength <= 0) {
      return { invalid: true }
    }
    start = Math.max(0, totalSize - Math.floor(suffixLength))
  } else {
    start = Number(match[1])
    if (match[2]) end = Number(match[2])
  }

  if (!Number.isFinite(start) || !Number.isFinite(end) ||
      start < 0 || start >= totalSize || end < start) {
    return { invalid: true }
  }
  return {
    invalid: false,
    start: Math.floor(start),
    end: Math.min(totalSize - 1, Math.floor(end)),
  }
}

function tryStreamLocalTelepromptMedia(req, res, targetPath) {
  let mediaPath = ''
  try {
    const parsed = new URL(targetPath, 'http://127.0.0.1')
    mediaPath = String(
      parsed.searchParams.get('path') ||
      parsed.searchParams.get('file') || ''
    ).trim()
  } catch (_) {
    return false
  }
  if (!mediaPath) return false

  let stat = null
  try {
    stat = fs.statSync(mediaPath)
  } catch (_) {
    return false
  }
  if (!stat?.isFile()) return false

  const totalSize = Number(stat.size) || 0
  const range = parseTelepromptByteRange(
    req.headers.range, totalSize)
  if (range?.invalid) {
    res.writeHead(416, {
      'Content-Range': `bytes */${totalSize}`,
      'Accept-Ranges': 'bytes',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,Range',
      'Cache-Control': 'private, max-age=120',
    })
    res.end()
    return true
  }

  const start = range ? range.start : 0
  const end = range ? range.end : Math.max(0, totalSize - 1)
  const contentLength = totalSize > 0 ? end - start + 1 : 0
  const headers = {
    'Content-Type': getTelepromptMediaContentType(mediaPath),
    'Content-Length': contentLength,
    'Accept-Ranges': 'bytes',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Range',
    'Cache-Control': 'private, max-age=120',
    'Last-Modified': stat.mtime.toUTCString(),
    'ETag': `W/"${totalSize}-${Math.floor(stat.mtimeMs)}"`,
  }
  if (range) {
    headers['Content-Range'] =
      `bytes ${start}-${end}/${totalSize}`
  }
  res.writeHead(range ? 206 : 200, headers)
  if (req.method === 'HEAD' || totalSize === 0) {
    res.end()
    return true
  }

  const stream = fs.createReadStream(mediaPath, { start, end })
  stream.on('error', () => {
    if (!res.headersSent) {
      sendJson(res, 500, {
        ok: false,
        error: 'Não foi possível ler a mídia do Teleprompt.',
      })
      return
    }
    try { res.destroy() } catch (_) {}
  })
  res.on('close', () => {
    if (!stream.destroyed) stream.destroy()
  })
  stream.pipe(res)
  return true
}


function proxyNativeBridgeMedia(req, res, targetPath) {
  if (trySendOptimizedTelepromptImage(req, res, targetPath)) return
  // A Hook Center está na mesma máquina dos arquivos do REAPER. Servir o
  // vídeo diretamente permite que cada app mantenha um stream contínuo e
  // impede que os pedaços do vídeo disputem a fila de estado da extensão.
  if (tryStreamLocalTelepromptMedia(req, res, targetPath)) return
  const headers = {}
  if (req.headers.range) headers.Range = req.headers.range
  if (req.headers['user-agent']) headers['User-Agent'] = req.headers['user-agent']
  const nativeReq = http.request({
    hostname: '127.0.0.1',
    port: NATIVE_BRIDGE_PORT,
    path: targetPath,
    method: 'GET',
    headers,
    timeout: 30000,
  }, (nativeRes) => {
    const responseHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,HEAD,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,Range',
      // Permite reutilizar a mesma mídia na troca TP1/TP2. O cache é curto
      // para refletir rapidamente qualquer arquivo alterado no projeto.
      'Cache-Control': 'private, max-age=120',
    }
    for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'last-modified', 'etag']) {
      const value = nativeRes.headers[name]
      if (value !== undefined) responseHeaders[name] = value
    }
    res.writeHead(nativeRes.statusCode || 502, responseHeaders)
    nativeRes.pipe(res)
  })
  nativeReq.on('timeout', () => nativeReq.destroy(new Error('native_media_timeout')))
  nativeReq.on('error', () => {
    if (res.headersSent) {
      try { res.end() } catch (_) {}
      return
    }
    sendJson(res, 502, { ok: false, error: 'Mídia do Teleprompt indisponível.', nativeBridge: false })
  })
  res.on('close', () => {
    if (!nativeReq.destroyed) nativeReq.destroy()
  })
  nativeReq.end()
}

function requestNativeBridgeJson(pathname, options = {}) {
  const method = options.method || 'GET'
  const body = options.body ? String(options.body) : ''
  const timeoutMs = Number(options.timeoutMs || 220)
  return new Promise((resolve) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: NATIVE_BRIDGE_PORT,
      path: pathname,
      method,
      headers: body ? {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      } : undefined,
      timeout: timeoutMs,
    }, (res) => {
      let raw = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { raw += chunk })
      res.on('end', () => {
        try {
          const parsed = raw ? JSON.parse(raw) : {}
          resolve({
            ok: res.statusCode >= 200 && res.statusCode < 300,
            status: Number(res.statusCode || 0),
            data: parsed,
          })
        } catch (_) {
          resolve({ ok: false, status: Number(res.statusCode || 0), data: null })
        }
      })
    })
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, status: 0, data: null }) })
    req.on('error', () => resolve({ ok: false, status: 0, data: null }))
    if (body) req.write(body)
    req.end()
  })
}


async function refreshNativeBridgeState() {
  if (nativeBridgeStateCache &&
      (Date.now() - nativeBridgeStateCacheAt) <
        NATIVE_BRIDGE_MIN_REFRESH_INTERVAL_MS) {
    return nativeBridgeStateCache
  }
  if (nativeBridgeRefreshInFlight) return nativeBridgeRefreshInFlight
  const refreshPromise = (async () => {
    // O snapshot pode ser grande e o macOS 10.13 possui buffers/CPU bem mais
    // lentos. Como a conexão é somente localhost, dois segundos evitam tratar
    // uma resposta válida ainda em trânsito como "REAPER fechado".
    const result = await requestNativeBridgeJson(
      '/state', { timeoutMs: 3000 })
    if (result.ok && result.data && result.data.connected) {
      nativeBridgeStateCache = result.data
      nativeBridgeStateCacheAt = Date.now()
      return nativeBridgeStateCache
    }
    return null
  })()
  nativeBridgeRefreshInFlight = refreshPromise
  try {
    return await refreshPromise
  } finally {
    if (nativeBridgeRefreshInFlight === refreshPromise) {
      nativeBridgeRefreshInFlight = null
    }
  }
}

async function getNativeBridgeStateSnapshot(maxStaleMs = 3000) {
  const refreshed = await refreshNativeBridgeState()
  if (refreshed) return refreshed
  if (nativeBridgeStateCache &&
      Date.now() - nativeBridgeStateCacheAt <=
        Math.max(0, Number(maxStaleMs) || 0)) {
    return nativeBridgeStateCache
  }
  return null
}

function retainNativeBridgeBackgroundPolling(licenseCheck) {
  if (typeof licenseCheck === 'function') {
    nativeBridgeLicenseChecks.add(licenseCheck)
  }
  if (!nativeBridgeBackgroundPollTimer) {
    nativeBridgeBackgroundPollTimer = setInterval(() => {
      const enabled = Array.from(nativeBridgeLicenseChecks)
        .some((check) => {
          try { return check() === true } catch (_) { return false }
        })
      if (enabled) refreshNativeBridgeState().catch(() => {})
    }, NATIVE_BRIDGE_BACKGROUND_POLL_MS)
    if (nativeBridgeBackgroundPollTimer.unref) {
      nativeBridgeBackgroundPollTimer.unref()
    }
  }
  let released = false
  return () => {
    if (released) return
    released = true
    if (typeof licenseCheck === 'function') {
      nativeBridgeLicenseChecks.delete(licenseCheck)
    }
    if (!nativeBridgeLicenseChecks.size &&
        nativeBridgeBackgroundPollTimer) {
      clearInterval(nativeBridgeBackgroundPollTimer)
      nativeBridgeBackgroundPollTimer = null
    }
  }
}

function getFreshNativeBridgeState() {
  if (nativeBridgeStateCache && (Date.now() - nativeBridgeStateCacheAt) <= NATIVE_BRIDGE_CACHE_TTL_MS) {
    return nativeBridgeStateCache
  }
  return null
}

async function postNativeBridgeCommand(command) {
  const result = await requestNativeBridgeJson('/command', {
    method: 'POST',
    body: JSON.stringify(command || {}),
    timeoutMs: 850,
  })
  return !!(result.ok && result.data && result.data.ok)
}

function readJson(filePath, fallback) {
  const now = Date.now()
  const shortCached = readJsonShortCacheByFile.get(filePath)
  if (shortCached && (now - shortCached.readAt) <= READ_JSON_CACHE_TTL_MS) {
    return shortCached.value
  }

  try {
    const raw = fs.readFileSync(filePath, 'utf8')
    const parsed = JSON.parse(raw)
    lastGoodJsonByFile.set(filePath, {
      value: parsed,
      readAt: now,
    })
    readJsonShortCacheByFile.set(filePath, {
      value: parsed,
      readAt: now,
    })
    return parsed
  } catch (error) {
    const cached = lastGoodJsonByFile.get(filePath)
    if (cached && (Date.now() - cached.readAt) <= MAX_LAST_GOOD_STATE_AGE_MS) {
      return cached.value
    }
    return fallback
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8')
  readJsonShortCacheByFile.set(filePath, {
    value,
    readAt: Date.now(),
  })
}

function simpleHash(str) {
  const input = String(str ?? '')
  let h1 = 0x45D9
  let h2 = 0x2710

  for (let i = 0; i < input.length; i += 1) {
    const b = input.charCodeAt(i)
    const pos = i + 1
    h1 = (h1 ^ (b * pos + 17)) & 0xFFFFFF
    h2 = (h2 + ((b + i) * 131)) & 0xFFFFFF
    h1 = (h1 * 33 + h2) & 0xFFFFFF
    h2 = (h2 * 17 + h1) & 0xFFFFFF
  }

  const n = (((h1 << 12) >>> 0) + h2) >>> 0
  return n.toString(16).toUpperCase().padStart(8, '0')
}

function normalizeNoticeSource(value) {
  const source = String(value || '').trim().toLowerCase()
  if (source === 'director' || source === 'diretor') return 'director'
  if (source === 'hooklyrics' || source === 'hook-lyrics' || source === 'lyrics') return 'hooklyrics'
  if (source === 'recados' || source === 'recado') return 'recados'
  return 'recados'
}

function firstString(...values) {
  for (const value of values) {
    const text = String(value ?? '').trim()
    if (text) return text
  }
  return ''
}

function isTechnicalNoticeAuthorized(parsed, state, source) {
  const sourceName = normalizeNoticeSource(source)
  const password = String(parsed.password || parsed.pass || '').trim()
  const passwordHash = String(parsed.passwordHash || parsed.authHash || '').trim()

  if (sourceName === 'director') {
    const directorHash = String(state?.authHash || '').trim()
    const sessionHash = String(parsed.sessionHash || parsed.directorHash || '').trim()
    if (!state?.authEnabled || !directorHash || (sessionHash && sessionHash === directorHash)) return true
  }

  const configuredHash = firstString(
    state?.recadosAuthHash,
    state?.recadosPasswordHash,
    state?.technicalNoticeAuthHash,
    state?.technicalNoticePasswordHash,
    state?.noticeAuthHash,
    state?.noticePasswordHash
  )
  const configuredPassword = firstString(
    state?.recadosPassword,
    state?.technicalNoticePassword,
    state?.noticePassword
  )
  const authRequired = Boolean(
    state?.recadosAuthEnabled === true ||
    state?.technicalNoticeAuthEnabled === true ||
    state?.noticeAuthEnabled === true ||
    configuredHash ||
    configuredPassword
  )

  if (!authRequired) return true
  if (configuredHash && passwordHash && passwordHash === configuredHash) return true
  if (configuredHash && password && simpleHash(password) === configuredHash) return true
  if (configuredPassword && password && password === configuredPassword) return true
  return false
}

function getLanIp() {
  const nets = os.networkInterfaces()
  const ignored = ['loopback','topaz','km-test','virtual','vmware','virtualbox','hamachi','tailscale','tap','docker','hyper-v','vpn']

  function isPrivateIp(ip) {
    if (/^192\.168\./.test(ip)) return true
    if (/^10\./.test(ip)) return true
    const m = ip.match(/^172\.(\d+)\./)
    if (m) {
      const n = Number(m[1])
      return n >= 16 && n <= 31
    }
    return false
  }

  const preferred = []
  const fallback = []

  for (const name of Object.keys(nets)) {
    const lname = name.toLowerCase()

    if (ignored.some(x => lname.includes(x))) continue

    const items = nets[name] || []

    for (const item of items) {
      const familyV4Value = typeof item.family === 'string' ? 'IPv4' : 4

      if (item.family !== familyV4Value || item.internal) continue
      if (!isPrivateIp(item.address)) continue

      const score =
        /(wi-fi|wifi|wireless|wlan)/i.test(name) ? 100 :
        /(ethernet|realtek|intel)/i.test(name) ? 50 : 10

      ;(score >= 100 ? preferred : fallback).push({
        score,
        ip: item.address
      })
    }
  }

  const all = [...preferred, ...fallback].sort((a,b)=>b.score-a.score)

  return all.length ? all[0].ip : '127.0.0.1'
}

function getAllLanIps() {
  const nets = os.networkInterfaces()
  const ignored = ['loopback','topaz','km-test','virtual','vmware','virtualbox','hamachi','tailscale','tap','docker','hyper-v','vpn']
  const out = []

  function isPrivateIp(ip) {
    if (/^192\.168\./.test(ip)) return true
    if (/^10\./.test(ip)) return true
    const m = ip.match(/^172\.(\d+)\./)
    if (m) {
      const n = Number(m[1])
      return n >= 16 && n <= 31
    }
    return false
  }

  for (const name of Object.keys(nets)) {
    const lname = name.toLowerCase()
    if (ignored.some(x => lname.includes(x))) continue

    for (const item of nets[name] || []) {
      const familyV4Value = typeof item.family === 'string' ? 'IPv4' : 4
      if (item.family !== familyV4Value || item.internal) continue
      if (!isPrivateIp(item.address)) continue

      const score =
        /(wi-fi|wifi|wireless|wlan)/i.test(name) ? 100 :
        /(ethernet|realtek|intel)/i.test(name) ? 70 :
        /(usb|rndis|iphone|android|mobile|hotspot)/i.test(name) ? 60 : 10

      out.push({ name, ip: item.address, score })
    }
  }

  return out.sort((a, b) => b.score - a.score)
}

function sendJson(res, statusCode, data) {
  
  applyCorsHeaders(res)
res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Connection': 'keep-alive',
    'Keep-Alive': 'timeout=120, max=1000',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Range',
  })
  res.end(JSON.stringify(data))
}

function sendFile(res, filePath, contentType) {
  
  applyCorsHeaders(res)
try {
    const content = fs.readFileSync(filePath)
    res.writeHead(200, {
      'Content-Type': contentType,
      'Cache-Control': 'no-store',
    })
    res.end(content)
  } catch (error) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('Ocorreu um erro. Contate o suporte.')
  }
}

function getContentTypeByPath(filePath) {
  const ext = path.extname(String(filePath || '')).toLowerCase()
  return {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.webmanifest': 'application/manifest+json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml; charset=utf-8',
    '.ico': 'image/x-icon',
    '.txt': 'text/plain; charset=utf-8',
  }[ext] || 'application/octet-stream'
}

function resolveSafeStaticFile(baseDir, urlPath) {
  const rawPath = String(urlPath || '/')
  let relPath = rawPath === '/' ? '/index.html' : rawPath
  try {
    relPath = decodeURIComponent(relPath)
  } catch (error) {
    return ''
  }

  relPath = relPath.replace(/^\/+/, '')
  if (!relPath || relPath.endsWith('/')) relPath += 'index.html'

  const normalized = path.normalize(relPath)
  if (normalized.startsWith('..') || path.isAbsolute(normalized)) return ''

  const fullPath = path.join(baseDir, normalized)
  const relative = path.relative(baseDir, fullPath)
  if (relative.startsWith('..') || path.isAbsolute(relative)) return ''

  try {
    const stat = fs.statSync(fullPath)
    return stat.isFile() ? fullPath : ''
  } catch (error) {
    return ''
  }
}

function sendText(res, statusCode, body, contentType) {
  applyCorsHeaders(res)
  res.writeHead(statusCode, {
    'Content-Type': contentType || 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

function isQueueCommandTypeNoTransport(type) {
  const t = String(type || '').toLowerCase()
  return t === 'queue_playlist_song' || t === 'queue_region_song' || t === 'clear_queue'
}

function sanitizeNativeCommandForTransportSafety(type, payload = {}) {
  const commandType = String(type || '')
  const out = payload && typeof payload === 'object' ? { ...payload } : {}
  if (isQueueCommandTypeNoTransport(commandType)) {
    delete out.desiredPlaying
    delete out.desiredState
    delete out.forceStop
    delete out.forcePlay
    delete out.transportOnly
    delete out.selectedStartPos
    delete out.selectedEndPos
    delete out.stopSelectionStartPos
    delete out.stopSelectionEndPos
    delete out.stopSelectionPlaylistIndex
    out.queueOnly = commandType !== 'clear_queue'
    out.noTransport = true
    out.keepPlaying = true
    out.noSeek = true
    out.preserveCursor = true
  }
  return out
}

function isDirectorTransportStopCommand(type, payload = {}) {
  const commandType = String(type || '').toLowerCase()
  if (isQueueCommandTypeNoTransport(commandType)) return false
  const source = String(payload.role || payload.clientRole || payload.appRole || payload.source || payload.mode || '').toLowerCase()
  const isDirector = !source || source.includes('director') || source.includes('diretor') || commandType.startsWith('director_') || commandType.startsWith('transport_')
  // Somente ordens reais de transporte entram aqui. Reconhecer qualquer nome
  // contendo "stop" tambem capturava controles como stop_pause_mode_set e
  // manual_stop_fadeout_set_enabled, impedindo que os estados fossem salvos.
  const explicitStopType = commandType === 'transport_stop_no_seek' ||
    commandType === 'director_stop_no_seek' ||
    commandType === 'play_stop_no_seek' ||
    commandType === 'director_stop_break' ||
    commandType === 'stop_break' ||
    commandType === 'play_stop' ||
    commandType === 'stop'
  return isDirector && explicitStopType
}

function makeNativeTransportOnlyStopCommand(type, payload = {}) {
  const commandType = String(type || '').toLowerCase()
  const stopBreak = commandType === 'director_stop_break' || commandType === 'stop_break' || payload.stopBreak === true || payload.ignoreFadeout === true
  const nativeStopType = stopBreak ? 'director_stop_break' : 'director_stop_no_seek'
  const stopBreakFields = stopBreak ? { stopBreak: true, ignoreFadeout: true } : {}
  return {
    id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    type: nativeStopType,
    payload: {
      ...stopBreakFields,
      role: 'director',
      clientRole: 'director',
      appRole: 'director',
      source: 'director',
      mode: 'director',
      activeTab: payload.activeTab || payload.page || 'playlist',
      desiredPlaying: false,
      desiredState: 'stopped',
      forcePlay: false,
      forceStop: true,
      noSeek: true,
      preserveCursor: true,
      transportOnly: true,
      stopTransportOnly: true,
      ignoreSelection: true,
      ignoreTarget: true,
      noPosition: true,
      preventFallbackZero: true,
      clientCommandId: payload.clientCommandId || `director-stop-transport-only-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
      issuedAtMs: Date.now(),
    },
    ...stopBreakFields,
    role: 'director',
    clientRole: 'director',
    appRole: 'director',
    source: 'director',
    mode: 'director',
    desiredPlaying: false,
    desiredState: 'stopped',
    forcePlay: false,
    forceStop: true,
    noSeek: true,
    preserveCursor: true,
    transportOnly: true,
    stopTransportOnly: true,
    ignoreSelection: true,
    ignoreTarget: true,
    noPosition: true,
    preventFallbackZero: true,
    activeTab: payload.activeTab || payload.page || 'playlist',
    desiredPlaying: false,
    desiredState: 'stopped',
    forcePlay: false,
    forceStop: true,
    noSeek: true,
    preserveCursor: true,
    transportOnly: true,
    stopTransportOnly: true,
    ignoreSelection: true,
    ignoreTarget: true,
    createdAt: new Date().toISOString(),
    fromHookCenter: true,
  }
}

function normalizeLyricsText(value) {
  return String(value ?? '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .replace(/\\n/g, '\n')
    .slice(0, 4000)
}

function normalizeLyricsId(value) {
  const text = String(value ?? '').trim()
  return text || ''
}

function readLyricsDb(lyricsFile) {
  const data = readJson(lyricsFile, {
    bridgeVersion: 1,
    updatedAt: null,
    lyricsById: {},
  })
  const lyricsById = data && typeof data.lyricsById === 'object' && data.lyricsById && !Array.isArray(data.lyricsById)
    ? data.lyricsById
    : {}
  return {
    bridgeVersion: 1,
    updatedAt: data?.updatedAt || null,
    lyricsById,
  }
}

function getLyricsIdCandidates(raw = {}) {
  const payload = raw && typeof raw === 'object' ? raw : {}
  const candidates = []
  const directFields = [
    'id', 'targetId', 'selectedRegionId', 'songId', 'regionId', 'playlistSongId',
    'source_number', 'sourceNumber', 'number', 'uid', 'regionUid', 'songUid'
  ]
  for (const field of directFields) {
    const value = normalizeLyricsId(payload[field])
    if (value) candidates.push(value)
  }
  const aliases = Array.isArray(payload.aliases) ? payload.aliases : []
  for (const value of aliases) {
    const key = normalizeLyricsId(value)
    if (key) candidates.push(key)
  }
  return [...new Set(candidates)]
}

function buildLyricsEntry(payload = {}) {
  const text = normalizeLyricsText(
    payload.lyricsText ?? payload.lyrics ?? payload.text ?? payload.value ?? ''
  )
  const now = new Date().toISOString()
  return {
    text,
    lyrics: text,
    lyricsText: text,
    hasLyrics: text.trim().length > 0,
    name: String(payload.name || payload.title || payload.songName || '').trim(),
    updatedAt: now,
  }
}

function saveLyricsPayload(lyricsFile, payload = {}) {
  const ids = getLyricsIdCandidates(payload)
  if (!ids.length) {
    return { ok: false, error: 'Música sem ID para salvar letra.' }
  }

  const db = readLyricsDb(lyricsFile)
  const entry = buildLyricsEntry(payload)
  db.lyricsById = db.lyricsById && typeof db.lyricsById === 'object' ? db.lyricsById : {}

  for (const id of ids) {
    db.lyricsById[id] = entry
  }

  db.updatedAt = entry.updatedAt
  writeJson(lyricsFile, db)
  return { ok: true, ids, entry, updatedAt: db.updatedAt }
}

function deleteLyricsPayload(lyricsFile, payload = {}) {
  const ids = getLyricsIdCandidates(payload)
  if (!ids.length) return { ok: false, error: 'Música sem ID para apagar letra.' }
  const db = readLyricsDb(lyricsFile)
  let changed = false
  for (const id of ids) {
    if (Object.prototype.hasOwnProperty.call(db.lyricsById, id)) {
      delete db.lyricsById[id]
      changed = true
    }
  }
  if (changed) {
    db.updatedAt = new Date().toISOString()
    writeJson(lyricsFile, db)
  }
  return { ok: true, ids, deleted: changed, updatedAt: db.updatedAt }
}

function pickLyricsForItem(item, lyricsById) {
  if (!item || typeof item !== 'object' || !lyricsById || typeof lyricsById !== 'object') return null
  const ids = getLyricsIdCandidates(item)
  for (const id of ids) {
    if (Object.prototype.hasOwnProperty.call(lyricsById, id)) {
      const entry = lyricsById[id]
      if (entry && typeof entry === 'object') return entry
      return { text: normalizeLyricsText(entry) }
    }
  }
  return null
}

function applyLyricsToItem(item, lyricsById) {
  if (!item || typeof item !== 'object') return item
  const out = { ...item }
  const entry = pickLyricsForItem(out, lyricsById)
  if (entry) {
    const text = normalizeLyricsText(entry.lyricsText ?? entry.lyrics ?? entry.text ?? '')
    out.lyrics = text
    out.lyricsText = text
    out.hasLyrics = text.trim().length > 0
    out.lyricsUpdatedAt = entry.updatedAt || null
  }
  return out
}

function applyLyricsToState(state, lyricsFile) {
  if (!state || typeof state !== 'object') return state
  const db = readLyricsDb(lyricsFile)
  const lyricsById = db.lyricsById || {}
  if (!Object.keys(lyricsById).length) return state

  const next = { ...state }
  if (Array.isArray(state.regions)) {
    next.regions = state.regions.map((item) => applyLyricsToItem(item, lyricsById))
  }
  if (Array.isArray(state.playlists)) {
    next.playlists = state.playlists.map((playlist) => {
      if (!playlist || typeof playlist !== 'object') return playlist
      const out = { ...playlist }
      if (Array.isArray(playlist.songs)) {
        out.songs = playlist.songs.map((item) => applyLyricsToItem(item, lyricsById))
      }
      return out
    })
  }
  next.lyricsUpdatedAt = db.updatedAt || null
  return next
}


function readTelepromptTp1State(sharedDir) {
  const candidates = [
    path.join(sharedDir, 'vshook_lyrics_state_1.json'),
    path.join(sharedDir, 'vshook_lyrics_state.json'),
  ]
  for (const file of candidates) {
    const data = readJson(file, null)
    if (data && typeof data === 'object') {
      const rawText = String(data.lyricsText ?? data.lyrics ?? data.text ?? '').trim()
      const song = String(data.songName ?? data.song ?? data.currentSongName ?? data.musicName ?? '').trim()
      const mediaType = String(data.telepromptType || data.mediaType || data.type || 'text').trim().toLowerCase()
      // App dos Músicos recebe somente o texto do TP1/empty item. Imagem e vídeo não são repassados.
      const isTextTp1 = !mediaType || mediaType === 'text' || mediaType === 'lyrics' || mediaType === 'empty' || mediaType === 'empty_item' || mediaType === 'emptyitem' || mediaType === 'text/plain'
      const text = isTextTp1 ? rawText : ''
      return {
        tp1: data,
        tp1LyricsText: text,
        tp1Lyrics: text,
        telepromptTp1Lyrics: text,
        tp1SongName: song,
        telepromptTp1SongName: song,
        tp1MediaType: isTextTp1 ? mediaType : 'media',
        telepromptTp1MediaType: isTextTp1 ? mediaType : 'media',
        tp1UpdatedAt: data.updatedAt || null,
      }
    }
  }
  return {
    tp1: null,
    tp1LyricsText: '',
    tp1Lyrics: '',
    telepromptTp1Lyrics: '',
    tp1SongName: '',
    telepromptTp1SongName: '',
    tp1MediaType: 'text',
    telepromptTp1MediaType: 'text',
    tp1UpdatedAt: null,
  }
}

function mergeTelepromptTp1State(state, sharedDir) {
  const base = state || {}
  const nativeHasTp1 = base.tp1 || base.tp1LyricsText || base.tp1Lyrics || base.telepromptTp1Lyrics || base.telepromptTp1Text
  if (nativeHasTp1) return base
  return {
    ...base,
    ...readTelepromptTp1State(sharedDir),
  }
}

function normalizeRoutes(extraRoutes) {
  const out = new Map()
  for (const route of extraRoutes || []) {
    if (!route || !route.url || !route.file) continue
    out.set(route.url, route)
  }
  return out
}

function createBridgeServer(options) {
  const host = options.host || '0.0.0.0'
  const port = Number(options.port)
  const appDir = options.appDir
  const appName = options.appName
  const publicBridgeHost = options.publicBridgeHost
  const sharedDir = options.sharedDir
  const stateFile = path.join(sharedDir, 'vshook_state.json')
  const commandsFile = path.join(sharedDir, 'vshook_commands.json')
  const lyricsFile = path.join(sharedDir, 'vshook_song_lyrics.json')
  const recadosImagesDir = path.join(sharedDir, 'recados-images')
  const routes = normalizeRoutes(options.routes)
  const getLicenseActive = typeof options.isLicenseActive === 'function' ? options.isLicenseActive : () => true

  function isBridgeLicenseActive() {
    try {
      return getLicenseActive() === true
    } catch (_) {
      return false
    }
  }

  function decodeRecadosImageDataUrl(value) {
    const match = String(value || '').match(
      /^data:(image\/(?:png|jpeg|webp|gif|bmp));base64,([a-z0-9+/=\r\n]+)$/i)
    if (!match) throw new Error('Formato de imagem não aceito.')
    const extensions = {
      'image/png': 'png',
      'image/jpeg': 'jpg',
      'image/webp': 'webp',
      'image/gif': 'gif',
      'image/bmp': 'bmp',
    }
    const mime = String(match[1] || '').toLowerCase()
    const extension = extensions[mime]
    const buffer = Buffer.from(match[2].replace(/\s+/g, ''), 'base64')
    if (!extension || !buffer.length) throw new Error('Imagem inválida.')
    if (buffer.length > 10 * 1024 * 1024) {
      throw new Error('A imagem deve ter no máximo 10 MB.')
    }
    return { buffer, extension }
  }

  async function saveRecadosUploadedImage(dataUrl, slot) {
    const safeSlot = Math.max(0, Math.min(2, Math.trunc(Number(slot))))
    const decoded = decodeRecadosImageDataUrl(dataUrl)
    await fs.promises.mkdir(recadosImagesDir, { recursive: true })
    const filePath = path.join(
      recadosImagesDir,
      `recado-${safeSlot + 1}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}.${decoded.extension}`)
    await fs.promises.writeFile(filePath, decoded.buffer)
    return filePath
  }

  async function cleanupRecadosUploadedImages(slot, keepPath = '') {
    const safeSlot = Math.max(0, Math.min(2, Math.trunc(Number(slot))))
    const prefix = `recado-${safeSlot + 1}-`
    let entries = []
    try {
      entries = await fs.promises.readdir(recadosImagesDir, {
        withFileTypes: true,
      })
    } catch (_) {
      return
    }
    const keep = keepPath ? path.resolve(keepPath) : ''
    await Promise.all(entries.map(async (entry) => {
      if (!entry.isFile() || !entry.name.startsWith(prefix)) return
      const candidate = path.resolve(recadosImagesDir, entry.name)
      if (keep && candidate === keep) return
      try { await fs.promises.unlink(candidate) } catch (_) {}
    }))
  }

  async function proxyNativeJson(pathname, method = 'GET', payload = null, timeoutMs = 1600) {
    const result = await requestNativeBridgeJson(pathname, {
      method,
      body: payload == null ? '' : JSON.stringify(payload),
      timeoutMs,
    })
    return {
      status: result.status || (result.ok ? 200 : 503),
      data: result.data && typeof result.data === 'object'
        ? result.data
        : { ok: false, error: 'Extensão VS Hook indisponível.' },
    }
  }

  function readRequestJson(req, maxBytes = 1024 * 512) {
    return new Promise((resolve, reject) => {
      let body = ''
      let bytes = 0
      let tooLarge = false
      req.on('data', (chunk) => {
        bytes += Buffer.byteLength(chunk)
        if (bytes > maxBytes) {
          tooLarge = true
          return
        }
        body += chunk.toString('utf8')
      })
      req.on('end', () => {
        if (tooLarge) {
          const error = new Error('Conteúdo muito grande.')
          error.status = 413
          reject(error)
          return
        }
        try {
          resolve(body ? JSON.parse(body) : {})
        } catch (_) {
          const error = new Error('JSON inválido.')
          error.status = 400
          reject(error)
        }
      })
      req.on('error', reject)
    })
  }

  function mergeHookCenterRecadosAuth(state) {
    // A extensão nova é a fonte única dos Recados, inclusive senha, modelos,
    // imagens e aparência. A Hook Center apenas transporta o snapshot.
    return { ...(state || {}) }
  }

  const fallbackState = options.fallbackState || {
    bridgeVersion: 1,
    connected: false,
    updatedAt: null,
    currentPage: 'regions',
    markerMode: false,
    currentPlaylistName: '',
    activePlaylistId: null,
    autoplayEnabled: false,
    playing: false,
    playingId: null,
    selectedRegionId: null,
    selectedRegionIds: [],
    selectedPlaylistSongId: null,
    selectedPlaylistSongIds: [],
    selectedMarkerId: null,
    regions: [],
    playlists: [],
    markers: [],
  }

  function buildLicenseLockedState() {
    return mergeTelepromptTp1State({
      ...fallbackState,
      connected: false,
      nativeBridge: false,
      nativeBridgeRequired: true,
      licenseRequired: true,
      licenseActive: false,
      bridgeMode: 'license_required',
      updatedAt: new Date().toISOString(),
      currentPlaylistName: '',
      activePlaylistId: null,
      playing: false,
      playingId: null,
      queuedSongId: null,
      selectedRegionId: null,
      selectedRegionIds: [],
      selectedPlaylistSongId: null,
      selectedPlaylistSongIds: [],
      selectedMarkerId: null,
      regions: [],
      playlists: [],
      markers: [],
    }, sharedDir)
  }

  function readEffectiveState() {
    if (!isBridgeLicenseActive()) return buildLicenseLockedState()

    // Native Bridge EXT ONLY: a Hook Center nao monta nem le repertorio do JSON antigo.
    // A extensao reaper_vshook e a unica fonte de repertorios/blocos/musicas/markers/playback.
    const nativeState = getFreshNativeBridgeState()
    if (nativeState && nativeState.connected) {
      return mergeTelepromptTp1State(nativeState, sharedDir)
    }

    // Não some com repertório/app enquanto uma leitura do /state estoura timeout.
    // Mantém o último snapshot bom por alguns minutos e marca como stale,
    // evitando lista piscando/sumindo no Diretor e Músicos.
    if (nativeBridgeStateCache && (Date.now() - nativeBridgeStateCacheAt) <= MAX_LAST_GOOD_STATE_AGE_MS) {
      return mergeTelepromptTp1State({
        ...nativeBridgeStateCache,
        connected: true,
        nativeBridge: true,
        stale: true,
        staleReason: 'using_last_good_native_state',
      }, sharedDir)
    }

    return mergeTelepromptTp1State({
      ...fallbackState,
      connected: false,
      nativeBridge: false,
      nativeBridgeRequired: true,
      bridgeMode: 'native_unavailable',
      updatedAt: new Date().toISOString(),
      regions: [],
      playlists: [],
      markers: [],
    }, sharedDir)
  }

  function buildDiscoveryPayload() {
    if (!isBridgeLicenseActive()) {
      const ip = publicBridgeHost || getLanIp()
      return {
        ok: false,
        app: 'VS Hook',
        appName,
        bridgeVersion: 1,
        connected: false,
        nativeBridge: false,
        nativeBridgeRequired: true,
        licenseRequired: true,
        licenseActive: false,
        bridgeMode: 'license_required',
        projects: [],
        openProjects: [],
        activeProject: null,
        projectName: '',
        projectPath: '',
        host: ip,
        publicBridgeHost,
        lanHost: ip,
        hosts: getAllLanIps().map(item => item.ip),
        networkInterfaces: getAllLanIps(),
        port,
        localUrl: `http://127.0.0.1:${port}`,
        lanUrl: `http://${ip}:${port}`,
        lanUrls: getAllLanIps().map(item => `http://${item.ip}:${port}`),
        publicUrl: `http://${publicBridgeHost}:${port}`,
        browserUrl: `http://${ip}:${port}/`,
        browserUrls: getAllLanIps().map(item => `http://${item.ip}:${port}/`),
        playing: false,
        updatedAt: new Date().toISOString(),
        stateUpdatedAt: new Date().toISOString(),
      }
    }

    const state = readEffectiveState()
    const ip = publicBridgeHost || getLanIp()
    const projectPayload = buildProjectPayload(state)

    return {
      ok: true,
      app: 'VS Hook',
      bridgeVersion: Number(state.bridgeVersion || 1),
      appName,
      ...projectPayload,
      host: ip,
      publicBridgeHost,
      lanHost: ip,
      hosts: getAllLanIps().map(item => item.ip),
      networkInterfaces: getAllLanIps(),
      port,
      localUrl: `http://127.0.0.1:${port}`,
      lanUrl: `http://${ip}:${port}`,
      lanUrls: getAllLanIps().map(item => `http://${item.ip}:${port}`),
      publicUrl: `http://${publicBridgeHost}:${port}`,
      browserUrl: `http://${ip}:${port}/`,
      browserUrls: getAllLanIps().map(item => `http://${item.ip}:${port}/`),
      playing: projectPayload.connected && !!state.playing,
      updatedAt: state.updatedAt || null,
      stateUpdatedAt: state.updatedAt || null,
    }
  }

  // Native Bridge EXT ONLY: nao cria/limpa vshook_state.json nem vshook_commands.json.
  // Repertorio e comandos passam pela extensao reaper_vshook.
  // Mantemos apenas o arquivo de letras/TP1, que continua sendo fonte do teleprompt.
  ensureJsonFile(lyricsFile, {
    bridgeVersion: 1,
    updatedAt: null,
    lyricsById: {},
  })

  const server = http.createServer((req, res) => {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type,Range',
      })
      res.end()
      return
    }

    const parsedUrl = new URL(req.url, `http://${req.headers.host || `127.0.0.1:${port}`}`)

    if (req.method === 'GET' && parsedUrl.pathname === '/') {
      const route = routes.get('/')
      if (route) {
        sendFile(res, path.join(appDir, route.file), route.contentType)
      } else {
        const staticFile = resolveSafeStaticFile(appDir, '/')
        if (staticFile) sendFile(res, staticFile, getContentTypeByPath(staticFile))
        else sendText(res, 404, 'Arquivo inicial do app não encontrado.', 'text/plain; charset=utf-8')
      }
      return
    }


    if (req.method === 'GET' && (parsedUrl.pathname === '/qr.svg' || parsedUrl.pathname === '/app-qr.svg')) {
      const stateIp = publicBridgeHost || getLanIp()
      const targetUrl = String(parsedUrl.searchParams.get('url') || `http://${stateIp}:${port}/`).trim()
      sendText(res, 200, createQrSvg(targetUrl), 'image/svg+xml; charset=utf-8')
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/health' || parsedUrl.pathname === '/ping')) {
      sendJson(res, 200, {
        ok: true,
        app: 'VS Hook',
        appName,
        port,
        now: new Date().toISOString(),
        uptimeSec: Math.floor(process.uptime()),
      })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/discovery' || parsedUrl.pathname === '/discovery.json')) {
      sendJson(res, 200, buildDiscoveryPayload())
      return
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && (parsedUrl.pathname === '/media' || parsedUrl.pathname === '/tp-media' || parsedUrl.pathname === '/teleprompt-media')) {
      proxyNativeBridgeMedia(req, res, `${parsedUrl.pathname}${parsedUrl.search || ''}`)
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/meters' || parsedUrl.pathname === '/meters.json')) {
      if (!isBridgeLicenseActive()) {
        sendJson(res, 200, { ok: false, active: false, licenseRequired: true, tracks: [], master: null })
        return
      }
      requestNativeBridgeJson('/meters', { timeoutMs: 450 }).then((result) => {
        if (result.ok && result.data && typeof result.data === 'object') {
          sendJson(res, 200, result.data)
          return
        }
        sendJson(res, 503, { ok: false, active: false, tracks: [], master: null })
      }).catch(() => {
        sendJson(res, 503, { ok: false, active: false, tracks: [], master: null })
      })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/state' || parsedUrl.pathname === '/state.json')) {
      if (!isBridgeLicenseActive()) {
        const state = mergeHookCenterRecadosAuth(readEffectiveState())
        sendJson(res, 200, buildPublicStatePayload(state))
        return
      }
      refreshNativeBridgeState().catch(() => {}).finally(() => {
        const rawState = mergeHookCenterRecadosAuth(readEffectiveState())
        const state = applyLyricsToState(rawState, lyricsFile)
        sendJson(res, 200, buildPublicStatePayload(state))
      })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/projects' || parsedUrl.pathname === '/projects.json')) {
      if (!isBridgeLicenseActive()) {
        const state = mergeHookCenterRecadosAuth(readEffectiveState())
        sendJson(res, 200, {
        ok: false,
        appName,
        licenseRequired: true,
        licenseActive: false,
        ...buildPublicProjectPayload(state),
        updatedAt: state.updatedAt || null,
        })
        return
      }
      refreshNativeBridgeState().catch(() => {}).finally(() => {
        const state = mergeHookCenterRecadosAuth(readEffectiveState())
        sendJson(res, 200, {
        ok: true,
        appName,
        ...buildPublicProjectPayload(state),
        updatedAt: state.updatedAt || null,
        })
      })
      return
    }

    if (req.method === 'GET' && parsedUrl.pathname === '/recados-templates') {
      proxyNativeJson('/recados-templates')
        .then((result) => sendJson(res, result.status, result.data))
        .catch(() => sendJson(res, 503, {
          ok: false,
          error: 'Extensão VS Hook indisponível.',
        }))
      return
    }

    if (req.method === 'POST' && parsedUrl.pathname === '/recados-templates') {
      readRequestJson(req, 16 * 1024 * 1024)
        .then(async (parsed) => {
          const state = mergeHookCenterRecadosAuth(readEffectiveState())
          const source = normalizeNoticeSource(parsed.source || 'recados')
          if (!isTechnicalNoticeAuthorized(parsed, state, source)) {
            sendJson(res, 401, { ok: false, error: 'Senha inválida.' })
            return
          }
          const index = Math.trunc(Number(parsed.index))
          if (!Number.isFinite(index) || index < 0 || index > 2) {
            sendJson(res, 400, { ok: false, error: 'Recado inválido.' })
            return
          }

          const nativePayload = {
            ...parsed,
            source,
            index,
          }
          delete nativePayload.imageDataUrl
          delete nativePayload.imageName

          let uploadedPath = ''
          if (parsed.updateImage === true &&
              String(parsed.imageDataUrl || '').trim()) {
            uploadedPath = await saveRecadosUploadedImage(
              parsed.imageDataUrl, index)
            nativePayload.imagePath = uploadedPath
          }

          const result = await proxyNativeJson(
            '/recados-templates', 'POST', nativePayload, 3000)
          if (result.status >= 200 && result.status < 300 &&
              result.data?.ok !== false) {
            const keepPath = String(
              result.data?.images?.[index] ||
              nativePayload.imagePath || '')
            await cleanupRecadosUploadedImages(index, keepPath)
          } else if (uploadedPath) {
            try { await fs.promises.unlink(uploadedPath) } catch (_) {}
          }
          sendJson(res, result.status, result.data)
        })
        .catch((error) => {
          sendJson(res, Number(error?.status || 400), {
            ok: false,
            error: String(error?.message || 'Não foi possível salvar o recado.'),
          })
        })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      proxyNativeJson('/technical-notice')
        .then((result) => sendJson(res, result.status, result.data))
        .catch(() => sendJson(res, 503, {
          ok: false,
          error: 'Extensão VS Hook indisponível.',
        }))
      return
    }

    if (req.method === 'POST' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      readRequestJson(req)
        .then((parsed) => proxyNativeJson(
          '/technical-notice',
          'POST',
          {
            ...parsed,
            source: normalizeNoticeSource(parsed.source || 'recados'),
          },
          3000))
        .then((result) => sendJson(res, result.status, result.data))
        .catch((error) => {
          sendJson(res, Number(error?.status || 400), {
            ok: false,
            error: String(error?.message || 'Não foi possível enviar o recado.'),
          })
        })
      return
    }

    if (req.method === 'DELETE' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      proxyNativeJson('/technical-notice', 'POST', {
        action: 'cancel',
        source: normalizeNoticeSource(
          parsedUrl.searchParams.get('source') || 'recados'),
        password: parsedUrl.searchParams.get('password') || '',
        passwordHash: parsedUrl.searchParams.get('passwordHash') || '',
        sessionHash: parsedUrl.searchParams.get('sessionHash') || '',
      }, 3000)
        .then((result) => sendJson(res, result.status, result.data))
        .catch(() => sendJson(res, 503, {
          ok: false,
          error: 'Extensão VS Hook indisponível.',
        }))
      return
    }


    if (req.method === 'GET' && (parsedUrl.pathname === '/lyrics' || parsedUrl.pathname === '/lyrics.json')) {
      const db = readLyricsDb(lyricsFile)
      const id = normalizeLyricsId(parsedUrl.searchParams.get('id'))
      if (id) {
        sendJson(res, 200, {
          ok: true,
          id,
          entry: db.lyricsById[id] || null,
          lyrics: db.lyricsById[id]?.lyricsText || db.lyricsById[id]?.lyrics || db.lyricsById[id]?.text || '',
          updatedAt: db.updatedAt || null,
        })
      } else {
        sendJson(res, 200, { ok: true, ...db })
      }
      return
    }

    if (req.method === 'POST' && (parsedUrl.pathname === '/lyrics' || parsedUrl.pathname === '/lyrics.json')) {
      let body = ''
      let tooLarge = false
      req.on('data', (chunk) => {
        body += chunk.toString('utf8')
        if (body.length > 1024 * 256) {
          tooLarge = true
          req.pause()
        }
      })
      req.on('end', () => {
        if (tooLarge) {
          sendJson(res, 413, { ok: false, error: 'Letra muito grande' })
          return
        }
        try {
          const parsed = body ? JSON.parse(body) : {}
          const result = saveLyricsPayload(lyricsFile, parsed)
          sendJson(res, result.ok ? 200 : 400, result)
        } catch (error) {
          sendJson(res, 400, { ok: false, error: 'JSON inválido' })
        }
      })
      return
    }

    if (req.method === 'DELETE' && (parsedUrl.pathname === '/lyrics' || parsedUrl.pathname === '/lyrics.json')) {
      const payload = {
        id: parsedUrl.searchParams.get('id'),
        targetId: parsedUrl.searchParams.get('targetId'),
        songId: parsedUrl.searchParams.get('songId'),
      }
      const result = deleteLyricsPayload(lyricsFile, payload)
      sendJson(res, result.ok ? 200 : 400, result)
      return
    }

    if (req.method === 'POST' && parsedUrl.pathname === '/command') {
      if (!isBridgeLicenseActive()) {
        sendJson(res, 403, {
          ok: false,
          error: 'VS Hook sem licença ativa.',
          licenseRequired: true,
          licenseActive: false,
          nativeBridge: false,
          nativeBridgeRequired: true,
        })
        return
      }

      let body = ''
      let tooLarge = false
      req.on('data', (chunk) => {
        body += chunk.toString('utf8')
        if (body.length > 1024 * 512) {
          tooLarge = true
          req.pause()
        }
      })
      req.on('end', async () => {
        if (tooLarge) {
          sendJson(res, 413, { ok: false, error: 'Comando muito grande' })
          return
        }
        try {
          const parsed = body ? JSON.parse(body) : {}
          const type = typeof parsed.type === 'string' ? parsed.type : 'unknown'
          let payload = parsed.payload && typeof parsed.payload === 'object' ? parsed.payload : {}
          let lyricsResult = null
          if (type === 'update_lyrics' || type === 'save_lyrics') {
            lyricsResult = saveLyricsPayload(lyricsFile, payload)
          }
          payload = sanitizeNativeCommandForTransportSafety(type, payload)
          // Compatibilidade entre versões da extensão: envia campos no topo
          // e dentro de payload, sem criar um segundo motor no bridge.
          let nativeCommandPayload = {
            id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
            type,
            payload,
            ...(payload && typeof payload === 'object' ? payload : {}),
            createdAt: new Date().toISOString(),
            fromHookCenter: true,
          }
          if (isDirectorTransportStopCommand(type, payload)) {
            nativeCommandPayload = makeNativeTransportOnlyStopCommand(type, payload)
          }
          if (nativeCommandPayload && String(nativeCommandPayload.type || '') === 'transport_stop_no_seek') {
            nativeCommandPayload.type = 'director_stop_no_seek'
            if (nativeCommandPayload.payload && typeof nativeCommandPayload.payload === 'object') nativeCommandPayload.payload.type = 'director_stop_no_seek'
          }
          // VS_HOOK_FIX_NATIVE_STOP_TYPE_RECOGNIZED
          const nativeOk = await postNativeBridgeCommand(nativeCommandPayload)
          nativeBridgeStateCacheAt = 0
          // Native Bridge EXT ONLY: comandos nao caem mais no vshook_commands.json.
          // Se a extensao nao estiver respondendo, o app recebe erro em vez de usar ponte antiga por arquivo.
          if (!nativeOk) {
            sendJson(res, 503, { ok: false, nativeBridge: false, nativeBridgeRequired: true, error: 'Native Bridge indisponivel' })
            return
          }
          const command = { id: `native-${Date.now()}`, type, payload, nativeBridge: true, createdAt: new Date().toISOString() }
          sendJson(res, 200, { ok: true, command, nativeBridge: true, lyricsSaved: lyricsResult ? !!lyricsResult.ok : undefined, lyrics: lyricsResult || undefined })
        } catch (error) {
          sendJson(res, 400, { ok: false, error: 'JSON inválido' })
        }
      })
      return
    }

    if (req.method === 'GET' && parsedUrl.pathname === '/bridge-info') {
      const info = buildDiscoveryPayload()
      sendJson(res, 200, {
        ...info,
        stateFile,
        commandsFile,
        lyricsFile,
      })
      return
    }

    if (req.method === 'GET' && routes.has(parsedUrl.pathname)) {
      const route = routes.get(parsedUrl.pathname)
      sendFile(res, path.join(appDir, route.file), route.contentType)
      return
    }

    if (req.method === 'GET') {
      const staticFile = resolveSafeStaticFile(appDir, parsedUrl.pathname)
      if (staticFile) {
        sendFile(res, staticFile, getContentTypeByPath(staticFile))
        return
      }
    }

    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('404')
  })

  // O app mantém conexões HTTP keep-alive e pode estar transmitindo mídia.
  // server.close() sozinho espera essas conexões terminarem, o que deixava o
  // botão "Reiniciar conexão" preso por até minutos. Guarde os sockets para
  // encerrar somente o Bridge imediatamente durante um reinício.
  const openSockets = new Set()
  server.on('connection', (socket) => {
    openSockets.add(socket)
    socket.once('close', () => openSockets.delete(socket))
  })

  let releaseNativeBridgePolling = null
  let stoppingPromise = null

  // Evita queda por inatividade em conexões longas do APK.
  server.keepAliveTimeout = 120000
  server.headersTimeout = 125000
  server.requestTimeout = 0
  server.timeout = 0

  server.on('error', (error) => {
    console.error(`[VS Hook Bridge] ${appName} falhou na porta ${port}: ${error.message}`)
  })

  return {
    port,
    appName,
    host,
    stateFile,
    commandsFile,
    publicBridgeHost,
    start() {
      return new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, host, () => {
          server.removeListener('error', reject)
          if (!releaseNativeBridgePolling) {
            releaseNativeBridgePolling =
              retainNativeBridgeBackgroundPolling(
                isBridgeLicenseActive)
          }
          if (isBridgeLicenseActive()) {
            refreshNativeBridgeState().catch(() => {})
          }
          const ip = getLanIp()
          resolve({
            appName,
            port,
            localUrl: `http://127.0.0.1:${port}`,
            lanUrl: `http://${ip}:${port}`,
            publicUrl: `http://${publicBridgeHost}:${port}`,
            stateFile,
            commandsFile,
          })
        })
      })
    },
    stop() {
      if (stoppingPromise) return stoppingPromise
      stoppingPromise = new Promise((resolve) => {
        if (releaseNativeBridgePolling) {
          releaseNativeBridgePolling()
          releaseNativeBridgePolling = null
        }

        let finished = false
        let fallbackTimer = null
        const finish = () => {
          if (finished) return
          finished = true
          if (fallbackTimer) clearTimeout(fallbackTimer)
          resolve()
        }
        const destroyOpenSockets = () => {
          for (const socket of [...openSockets]) {
            try { socket.destroy() } catch (_) {}
          }
        }

        if (!server.listening) {
          destroyOpenSockets()
          finish()
          return
        }

        // Defesa para versões antigas do Node/Electron: nunca deixa o IPC da
        // interface esperando indefinidamente por um callback de close.
        fallbackTimer = setTimeout(() => {
          destroyOpenSockets()
          finish()
        }, 1200)
        if (typeof fallbackTimer.unref === 'function') fallbackTimer.unref()

        try {
          // Primeiro para de aceitar novas conexões; em seguida derruba apenas
          // os clientes conectados ao Bridge. A janela da Hook Center continua
          // intacta e as portas podem ser abertas de novo imediatamente.
          server.close(finish)
          if (typeof server.closeIdleConnections === 'function') {
            server.closeIdleConnections()
          }
          if (typeof server.closeAllConnections === 'function') {
            server.closeAllConnections()
          }
          destroyOpenSockets()
        } catch (_) {
          destroyOpenSockets()
          finish()
          return
        }
      })
      return stoppingPromise
    },
  }
}

function createAliasServer(options) {
  const port = Number(options.port) || 80
  const host = options.host || '0.0.0.0'
  const hostToPort = {}

  for (const [name, targetPort] of Object.entries(options.routes || {})) {
    hostToPort[String(name).toLowerCase()] = Number(targetPort)
  }

  const server = http.createServer((req, res) => {
    const originalHost = String(req.headers.host || '').split(':')[0].toLowerCase()
    const targetPort = hostToPort[originalHost]

    if (!targetPort) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('O aplicativo VS Hook está temporariamente indisponível. Reinicie a conexão no Hook Center e tente novamente.')
      return
    }

    const proxyReq = http.request({
      hostname: '127.0.0.1',
      port: targetPort,
      path: req.url,
      method: req.method,
      headers: {
        ...req.headers,
        host: `127.0.0.1:${targetPort}`,
      },
    }, (proxyRes) => {
      res.writeHead(proxyRes.statusCode || 500, proxyRes.headers)
      proxyRes.pipe(res)
    })

    proxyReq.on('error', (error) => {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end(`Proxy local falhou: ${error.message}`)
    })

    req.pipe(proxyReq)
  })

  return {
    port,
    host,
    start() {
      return new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, host, () => {
          server.removeListener('error', reject)
          resolve({ port, host, routes: { ...hostToPort } })
        })
      })
    },
    stop() {
      return new Promise((resolve) => {
        if (!server.listening) {
          resolve()
          return
        }
        server.close(() => resolve())
      })
    },
  }
}

module.exports = {
  createBridgeServer,
  createAliasServer,
  ensureJsonFile,
  getLanIp,
  getAllLanIps,
  getNativeBridgeStateSnapshot,
}
