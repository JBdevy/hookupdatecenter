const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { URL } = require('url')
const { createQrSvg } = require('./qr-svg')

const PROJECT_STALE_MS = 8000
const MAX_LAST_GOOD_STATE_AGE_MS = 5 * 60 * 1000
const TECHNICAL_NOTICE_DURATION_MS = 20000
const DIRECTOR_NOTICE_DURATION_MS = 15000
const TECHNICAL_NOTICE_MAX_LEN = 500

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
    || value === 'projeto 1'
    || value === 'project 1'
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

function getTechnicalNoticePriority(source) {
  const normalized = normalizeNoticeSource(source)
  if (normalized === 'director') return 3
  if (normalized === 'recados') return 2
  return 1
}

function getTechnicalNoticeDurationMs(source, raw = {}) {
  const normalized = normalizeNoticeSource(source)
  const requested = Math.floor(Number(raw.durationMs || raw.duration || raw.ttlMs || 0))
  if (requested > 0) return Math.min(Math.max(requested, 1000), 60000)
  return normalized === 'director' ? DIRECTOR_NOTICE_DURATION_MS : TECHNICAL_NOTICE_DURATION_MS
}

function normalizeTechnicalNotice(raw) {
  if (!raw || typeof raw !== 'object') return null
  const text = String(raw.text || raw.message || '').trim()
  const expiresAt = Number(raw.expiresAt || 0)
  if (!text || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) return null
  const source = normalizeNoticeSource(raw.source || 'recados')
  const priority = Math.max(getTechnicalNoticePriority(source), Math.floor(Number(raw.priority) || 0))
  return {
    id: String(raw.id || ''),
    text,
    message: text,
    source,
    priority,
    createdAt: raw.createdAt || null,
    updatedAt: raw.updatedAt || raw.createdAt || null,
    expiresAt,
    expiresAtIso: raw.expiresAtIso || new Date(expiresAt).toISOString(),
  }
}

function readActiveTechnicalNotice(noticeFile) {
  return normalizeTechnicalNotice(readJson(noticeFile, null))
}

function clearTechnicalNotice(noticeFile) {
  writeJson(noticeFile, {
    id: '',
    text: '',
    message: '',
    source: '',
    priority: 0,
    cancelledAt: new Date().toISOString(),
    expiresAt: 0,
  })
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
    'Access-Control-Allow-Headers': 'Content-Type',
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

const lastDirectorPlaybackCommandBySignature = new Map()

function shouldDropDuplicateDirectorPlaybackCommand(type, payload = {}) {
  const commandType = String(type || '')
  if (!['play_start', 'play_stop', 'play_toggle', 'director_play_button', 'play_button'].includes(commandType)) return false
  const source = String(payload.role || payload.clientRole || payload.appRole || payload.source || payload.mode || '').toLowerCase()
  if (source && !source.includes('director') && !source.includes('diretor')) return false
  const target = String(payload.selectedPlaylistSongId || payload.selectedRegionId || payload.songId || payload.targetId || payload.id || '')
  const desired = String(payload.desiredState || payload.desiredPlaying || payload.forcePlay || payload.forceStop || '')
  const signature = `${commandType}:${desired}:${payload.activeTab || payload.page || ''}:${target}`
  const now = Date.now()
  const last = Number(lastDirectorPlaybackCommandBySignature.get(signature) || 0)
  lastDirectorPlaybackCommandBySignature.set(signature, now)
  return last > 0 && (now - last) < 900
}

function enqueueCommand(commandsFile, type, payload = {}) {
  if (shouldDropDuplicateDirectorPlaybackCommand(type, payload)) {
    return { id: `dedup-${Date.now()}`, type, payload, deduped: true, createdAt: new Date().toISOString() }
  }

  const commandsDb = readJson(commandsFile, {
    bridgeVersion: 1,
    updatedAt: null,
    commands: [],
  })

  const command = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    type,
    payload,
    createdAt: new Date().toISOString(),
  }

  commandsDb.updatedAt = new Date().toISOString()
  commandsDb.commands = Array.isArray(commandsDb.commands) ? commandsDb.commands : []
  commandsDb.commands.push(command)

  writeJson(commandsFile, commandsDb)
  return command
}

function normalizeCommandPage(value) {
  const page = String(value || '').trim().toLowerCase()
  if (page === 'regions' || page === 'musicas' || page === 'músicas') return 'regions'
  if (page === 'playlist' || page === 'repertorios' || page === 'repertórios') return 'playlist'
  if (page === 'markers' || page === 'parts') return 'markers'
  return ''
}

function normalizeCommandId(value) {
  if (value === undefined || value === null) return null
  const text = String(value).trim()
  return text || null
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
  const noticeFile = path.join(sharedDir, 'vshook_technical_notice.json')
  const lyricsFile = path.join(sharedDir, 'vshook_song_lyrics.json')
  const routes = normalizeRoutes(options.routes)
  const getHookCenterTechnicalNoticeSettings = typeof options.getTechnicalNoticeSettings === 'function' ? options.getTechnicalNoticeSettings : null

  function getHookCenterRecadosAuthState() {
    if (!getHookCenterTechnicalNoticeSettings) return {}
    try {
      const settings = getHookCenterTechnicalNoticeSettings() || {}
      const password = String(settings.recadosPassword || '').trim()
      const hash = String(settings.recadosAuthHash || settings.technicalNoticeAuthHash || '').trim()
      const enabled = settings.recadosAuthEnabled === true || settings.technicalNoticeAuthEnabled === true || !!password || !!hash
      return {
        recadosAuthEnabled: enabled,
        technicalNoticeAuthEnabled: enabled,
        recadosAuthHash: hash || (password ? simpleHash(password) : ''),
        technicalNoticeAuthHash: hash || (password ? simpleHash(password) : ''),
      }
    } catch (_) {
      return {}
    }
  }

  function mergeHookCenterRecadosAuth(state) {
    const auth = getHookCenterRecadosAuthState()
    if (!auth || !auth.recadosAuthEnabled) return state || {}
    return {
      ...(state || {}),
      recadosAuthEnabled: true,
      technicalNoticeAuthEnabled: true,
      recadosAuthHash: auth.recadosAuthHash || '',
      technicalNoticeAuthHash: auth.technicalNoticeAuthHash || auth.recadosAuthHash || '',
    }
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

  const liveCommandOverlay = {
    currentPage: null,
    currentPageUntil: 0,
    queuedSongId: undefined,
    queuedSongUntil: 0,
  }

  function updateLiveCommandOverlay(type, payload = {}) {
    const now = Date.now()
    const commandType = String(type || '')
    if (commandType === 'set_page') {
      const page = normalizeCommandPage(payload.page || payload.currentPage || payload.targetPage)
      if (page) {
        liveCommandOverlay.currentPage = page
        liveCommandOverlay.currentPageUntil = now + 6000
      }
    }

    if (commandType === 'clear_queue') {
      liveCommandOverlay.queuedSongId = null
      liveCommandOverlay.queuedSongUntil = now + 5000
    } else if (commandType === 'queue_playlist_song' || commandType === 'queue_region_song') {
      const id = normalizeCommandId(payload.id || payload.selectedRegionId || payload.songId || payload.regionId)
      liveCommandOverlay.queuedSongId = id
      liveCommandOverlay.queuedSongUntil = now + 5000
    } else if (commandType === 'play_toggle' || commandType === 'play_start' || commandType === 'play_stop') {
      // Depois de Play/Stop pelo Diretor, não deixa uma fila velha voltar no app
      // dos músicos enquanto o Lua ainda está escrevendo o próximo JSON.
      liveCommandOverlay.queuedSongId = null
      liveCommandOverlay.queuedSongUntil = now + 1800
    }
  }

  function applyLiveCommandOverlay(state) {
    const now = Date.now()
    const out = { ...(state || {}) }
    if (liveCommandOverlay.currentPage && now < Number(liveCommandOverlay.currentPageUntil || 0)) {
      out.currentPage = liveCommandOverlay.currentPage
    }
    if (now < Number(liveCommandOverlay.queuedSongUntil || 0)) {
      out.queuedSongId = liveCommandOverlay.queuedSongId === undefined ? out.queuedSongId : liveCommandOverlay.queuedSongId
    }
    return out
  }


  function buildDiscoveryPayload() {
    const state = applyLiveCommandOverlay(readJson(stateFile, fallbackState))
    const ip = getLanIp()
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

  ensureJsonFile(stateFile, fallbackState)
  ensureJsonFile(commandsFile, {
    bridgeVersion: 1,
    updatedAt: null,
    commands: [],
  })
  // Comandos sao efemeros. Ao iniciar o Hook Center, limpa fila antiga para evitar
  // primeiro Play do app executar um comando pendurado de sessao anterior.
  writeJson(commandsFile, {
    bridgeVersion: 1,
    updatedAt: null,
    commands: [],
  })
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
        'Access-Control-Allow-Headers': 'Content-Type',
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
      const stateIp = getLanIp()
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

    if (req.method === 'GET' && (parsedUrl.pathname === '/state' || parsedUrl.pathname === '/state.json')) {
      const rawState = mergeHookCenterRecadosAuth(readJson(stateFile, fallbackState))
      const state = applyLiveCommandOverlay(applyLyricsToState(rawState, lyricsFile))
      sendJson(res, 200, buildPublicStatePayload(state))
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/projects' || parsedUrl.pathname === '/projects.json')) {
      const state = applyLiveCommandOverlay(mergeHookCenterRecadosAuth(readJson(stateFile, fallbackState)))
      sendJson(res, 200, {
        ok: true,
        appName,
        ...buildPublicProjectPayload(state),
        updatedAt: state.updatedAt || null,
      })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      sendJson(res, 200, { ok: true, notice: readActiveTechnicalNotice(noticeFile), now: Date.now() })
      return
    }

    if (req.method === 'POST' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      let body = ''
      let tooLarge = false
      req.on('data', (chunk) => {
        body += chunk.toString('utf8')
        if (body.length > 1024 * 64) {
          tooLarge = true
          req.pause()
        }
      })
      req.on('end', () => {
        if (tooLarge) {
          sendJson(res, 413, { ok: false, error: 'Recado muito grande' })
          return
        }
        try {
          const parsed = body ? JSON.parse(body) : {}
          const action = String(parsed.action || parsed.command || '').toLowerCase()
          const source = normalizeNoticeSource(parsed.source || 'recados')
          const priority = getTechnicalNoticePriority(source)
          const state = mergeHookCenterRecadosAuth(readJson(stateFile, fallbackState))

          if (action === 'cancel' || action === 'clear' || action === 'remove') {
            if (!isTechnicalNoticeAuthorized(parsed, state, source)) {
              sendJson(res, 401, { ok: false, error: 'Senha inválida.' })
              return
            }
            const activeNotice = readActiveTechnicalNotice(noticeFile)
            if (activeNotice && activeNotice.priority > priority) {
              sendJson(res, 200, { ok: true, ignoredDuePriority: true, notice: activeNotice, now: Date.now() })
              return
            }
            clearTechnicalNotice(noticeFile)
            sendJson(res, 200, { ok: true, cancelled: true, notice: null, now: Date.now() })
            return
          }

          const text = String(parsed.text || parsed.message || '').trim().slice(0, TECHNICAL_NOTICE_MAX_LEN)

          if (!text) {
            sendJson(res, 400, { ok: false, error: 'Digite um recado antes de enviar.' })
            return
          }
          if (!isTechnicalNoticeAuthorized(parsed, state, source)) {
            sendJson(res, 401, { ok: false, error: 'Senha inválida.' })
            return
          }

          const activeNotice = readActiveTechnicalNotice(noticeFile)
          if (activeNotice && activeNotice.priority > priority) {
            sendJson(res, 200, { ok: true, ignoredDuePriority: true, notice: activeNotice, now: Date.now() })
            return
          }

          const now = Date.now()
          const durationMs = getTechnicalNoticeDurationMs(source, parsed)
          const notice = {
            id: `${now}-${Math.random().toString(16).slice(2, 8)}`,
            text,
            message: text,
            source,
            priority,
            createdAt: new Date(now).toISOString(),
            updatedAt: new Date(now).toISOString(),
            durationMs,
            expiresAt: now + durationMs,
            expiresAtIso: new Date(now + durationMs).toISOString(),
          }
          writeJson(noticeFile, notice)
          sendJson(res, 200, { ok: true, notice, now })
        } catch (error) {
          sendJson(res, 400, { ok: false, error: 'JSON inválido' })
        }
      })
      return
    }

    if (req.method === 'DELETE' && (parsedUrl.pathname === '/technical-notice' || parsedUrl.pathname === '/recados-notice')) {
      const source = normalizeNoticeSource(parsedUrl.searchParams.get('source') || 'recados')
      const priority = getTechnicalNoticePriority(source)
      const activeNotice = readActiveTechnicalNotice(noticeFile)
      if (activeNotice && activeNotice.priority > priority) {
        sendJson(res, 200, { ok: true, ignoredDuePriority: true, notice: activeNotice, now: Date.now() })
        return
      }
      clearTechnicalNotice(noticeFile)
      sendJson(res, 200, { ok: true, cancelled: true, notice: null, now: Date.now() })
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
      let body = ''
      let tooLarge = false
      req.on('data', (chunk) => {
        body += chunk.toString('utf8')
        if (body.length > 1024 * 512) {
          tooLarge = true
          req.pause()
        }
      })
      req.on('end', () => {
        if (tooLarge) {
          sendJson(res, 413, { ok: false, error: 'Comando muito grande' })
          return
        }
        try {
          const parsed = body ? JSON.parse(body) : {}
          const type = typeof parsed.type === 'string' ? parsed.type : 'unknown'
          const payload = parsed.payload && typeof parsed.payload === 'object' ? parsed.payload : {}
          let lyricsResult = null
          if (type === 'update_lyrics' || type === 'save_lyrics') {
            lyricsResult = saveLyricsPayload(lyricsFile, payload)
          }
          updateLiveCommandOverlay(type, payload)
          const command = enqueueCommand(commandsFile, type, payload)
          sendJson(res, 200, { ok: true, command, lyricsSaved: lyricsResult ? !!lyricsResult.ok : undefined, lyrics: lyricsResult || undefined })
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
      res.end('Host não configurado no VS Hook Bridge.')
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
}
