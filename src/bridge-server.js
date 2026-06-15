const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { URL } = require('url')

const PROJECT_STALE_MS = 120000
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
    ? (project.name ?? project.projectName ?? project.title ?? project.label ?? project.path ?? project.projectPath)
    : project
  const value = String(raw ?? '').trim()
  return value || `Projeto ${index + 1}`
}

function getProjectPath(project) {
  if (!project || typeof project !== 'object') return ''
  return String(project.path ?? project.projectPath ?? '').trim()
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
        name: projectName || 'Projeto sem nome',
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
    const key = `${project.id}|${project.projectPath}|${project.name}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

function stateLooksConnected(state) {
  if (!state) return false
  if (state.connected === true) return true
  if (Array.isArray(state.projects) && state.projects.length) return true
  if (Array.isArray(state.projectTabs) && state.projectTabs.length) return true
  if (state.projectName || state.currentProjectName || state.projectPath) return true
  return false
}

function buildProjectPayload(state) {
  const fresh = isStateFresh(state)
  const looksConnected = stateLooksConnected(state)

  // Não some com os projetos imediatamente quando o heartbeat atrasa.
  // O app precisa conseguir reencontrar o projeto depois de ficar aberto por muito tempo.
  const projects = looksConnected ? normalizeProjectsFromState(state) : []
  const connected = looksConnected && (fresh || projects.length > 0)

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

function readJson(filePath, fallback) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8')
    const parsed = JSON.parse(raw)
    lastGoodJsonByFile.set(filePath, {
      value: parsed,
      readAt: Date.now(),
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
    res.end(`Arquivo não encontrado: ${path.basename(filePath)}`)
  }
}

function enqueueCommand(commandsFile, type, payload = {}) {
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
  const routes = normalizeRoutes(options.routes)
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


  function buildDiscoveryPayload() {
    const state = readJson(stateFile, fallbackState)
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
      sendFile(res, path.join(appDir, route.file), route.contentType)
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
      const state = readJson(stateFile, fallbackState)
      const projectPayload = buildProjectPayload(state)
      sendJson(res, 200, {
        ...state,
        connected: projectPayload.connected,
        stale: projectPayload.stale,
        projects: projectPayload.projects,
        activeProject: projectPayload.activeProject,
        projectName: projectPayload.projectName,
        projectPath: projectPayload.projectPath,
      })
      return
    }

    if (req.method === 'GET' && (parsedUrl.pathname === '/projects' || parsedUrl.pathname === '/projects.json')) {
      const state = readJson(stateFile, fallbackState)
      sendJson(res, 200, {
        ok: true,
        appName,
        ...buildProjectPayload(state),
        updatedAt: state.updatedAt || null,
      })
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
          const command = enqueueCommand(commandsFile, type, payload)
          sendJson(res, 200, { ok: true, command })
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
      })
      return
    }

    if (req.method === 'GET' && routes.has(parsedUrl.pathname)) {
      const route = routes.get(parsedUrl.pathname)
      sendFile(res, path.join(appDir, route.file), route.contentType)
      return
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
}
