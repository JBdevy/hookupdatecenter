/**
 * VS Hook Bridge Server - Musicos
 * Serve a interface web local + estado + comandos
 * Execute com: node bridge-server-musicos.js
 */

const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { URL } = require('url')

const PORT = 47832
const HOST = '0.0.0.0'
const PUBLIC_BRIDGE_HOST = 'vshook.musicos'

const BASE_DIR = __dirname
const SHARED_DIR = path.resolve(BASE_DIR, '..')
const STATE_FILE = path.join(SHARED_DIR, 'vshook_state.json')
const COMMANDS_FILE = path.join(SHARED_DIR, 'vshook_commands.json')
const INDEX_FILE = fs.existsSync(path.join(BASE_DIR, 'index.html'))
  ? path.join(BASE_DIR, 'index.html')
  : path.join(BASE_DIR, 'musicos.html')
const APP_FILE = path.join(BASE_DIR, 'vsmusicos.js')
const CSS_FILE = path.join(BASE_DIR, 'musicos.css')
const LOGO_FILE = path.join(BASE_DIR, 'vsmusicos-icon-512.png')
const ICON_192_FILE = path.join(BASE_DIR, 'vsmusicos-icon-192.png')
const ICON_180_FILE = path.join(BASE_DIR, 'vsmusicos-icon-180.png')
const ICON_512_FILE = path.join(BASE_DIR, 'vsmusicos-icon-512.png')
const MANIFEST_FILE = path.join(BASE_DIR, 'musicos.webmanifest')
const SERVICE_WORKER_FILE = path.join(BASE_DIR, 'service-worker.js')

function ensureFile(filePath, fallbackObject) {
  try {
    if (!fs.existsSync(filePath)) {
      fs.writeFileSync(filePath, JSON.stringify(fallbackObject, null, 2), 'utf8')
    }
  } catch (error) {
    console.error(`Erro ao criar arquivo ${filePath}:`, error.message)
  }
}

ensureFile(STATE_FILE, {
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
})

ensureFile(COMMANDS_FILE, {
  bridgeVersion: 1,
  updatedAt: null,
  commands: [],
})

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'))
  } catch (error) {
    return fallback
  }
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8')
}

function normalizeCommandPage(value) {
  const page = String(value || '').trim().toLowerCase()
  if (page === 'regions' || page === 'musicas' || page === 'músicas') return 'regions'
  if (page === 'playlist' || page === 'repertorios' || page === 'repertórios') return 'playlist'
  if (page === 'markers' || page === 'parts') return 'markers'
  return ''
}

function applyLiveCommandToState(type, payload = {}) {
  try {
    const current = readJson(STATE_FILE, {})
    const next = current && typeof current === 'object' ? { ...current } : {}
    const now = new Date().toISOString()
    let changed = false
    if (type === 'set_page') {
      const page = normalizeCommandPage(payload.page || payload.currentPage || payload.targetPage)
      if (page) { next.currentPage = page; changed = true }
    }
    if (type === 'clear_queue') {
      next.queuedSongId = null
      changed = true
    } else if (type === 'queue_playlist_song') {
      const id = payload.id ?? payload.selectedRegionId ?? payload.songId ?? payload.regionId ?? null
      next.queuedSongId = id === undefined || id === null ? null : String(id)
      changed = true
    } else if (type === 'play_toggle') {
      next.queuedSongId = null
      changed = true
    }
    if (changed) {
      next.updatedAt = current.updatedAt || now
      next.bridgeOverlayUpdatedAt = now
      writeJson(STATE_FILE, next)
    }
  } catch (error) {}
}

function isPrivateIPv4(ip) {
  if (!ip || typeof ip !== 'string') return false

  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false
  }

  const [a, b] = parts

  // Redes locais validas para roteador/hotspot:
  // 10.x.x.x, 172.16.x.x ate 172.31.x.x, 192.168.x.x
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
}

function isBadNetworkInterfaceName(name) {
  const normalized = String(name || '').toLowerCase()
  const blocked = [
    'loopback',
    'km-test',
    'topaz',
    'virtual',
    'vmware',
    'virtualbox',
    'hamachi',
    'tailscale',
    'tap',
    'vpn',
    'docker',
    'hyper-v',
    'wsl',
  ]

  return blocked.some((word) => normalized.includes(word))
}

function getLanIp() {
  const nets = os.networkInterfaces()
  const candidates = []

  for (const name of Object.keys(nets)) {
    if (isBadNetworkInterfaceName(name)) continue

    const items = nets[name] || []
    for (const item of items) {
      const familyV4Value = typeof item.family === 'string' ? 'IPv4' : 4
      if (item.family !== familyV4Value || item.internal) continue
      if (!isPrivateIPv4(item.address)) continue

      const lowerName = name.toLowerCase()
      let priority = 50

      // Prioriza Wi-Fi, depois cabo Ethernet. Ambos precisam ser IP privado.
      if (lowerName.includes('wi-fi') || lowerName.includes('wifi') || lowerName.includes('wireless') || lowerName.includes('wlan')) {
        priority = 10
      } else if (lowerName.includes('ethernet') || lowerName.includes('realtek') || lowerName.includes('intel')) {
        priority = 20
      }

      candidates.push({ address: item.address, priority })
    }
  }

  candidates.sort((a, b) => a.priority - b.priority)

  if (candidates.length > 0) {
    return candidates[0].address
  }

  return '127.0.0.1'
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  })
  res.end(JSON.stringify(data))
}

function sendFile(res, filePath, contentType) {
  try {
    const content = fs.readFileSync(filePath)
    res.writeHead(200, {
      'Content-Type': contentType,
      'Cache-Control': 'no-store',
    })
    res.end(content)
  } catch (error) {
    res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end(`Erro ao ler arquivo: ${path.basename(filePath)}`)
  }
}

function enqueueCommand(type, payload = {}) {
  const commandsDb = readJson(COMMANDS_FILE, {
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
  writeJson(COMMANDS_FILE, commandsDb)
  applyLiveCommandToState(type, payload)
  return command
}

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

  const parsedUrl = new URL(req.url, `http://${req.headers.host}`)

  if (req.method === 'GET' && parsedUrl.pathname === '/') {
    sendFile(res, INDEX_FILE, 'text/html; charset=utf-8')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos.js') {
    sendFile(res, APP_FILE, 'application/javascript; charset=utf-8')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/musicos.css') {
    sendFile(res, CSS_FILE, 'text/css; charset=utf-8')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos.png') {
    sendFile(res, LOGO_FILE, 'image/png')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos-icon.png') {
    sendFile(res, ICON_512_FILE, 'image/png')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos-icon-192.png') {
    sendFile(res, ICON_192_FILE, 'image/png')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos-icon-180.png') {
    sendFile(res, ICON_180_FILE, 'image/png')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/vsmusicos-icon-512.png') {
    sendFile(res, ICON_512_FILE, 'image/png')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/musicos.webmanifest') {
    sendFile(res, MANIFEST_FILE, 'application/manifest+json; charset=utf-8')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/service-worker.js') {
    sendFile(res, SERVICE_WORKER_FILE, 'application/javascript; charset=utf-8')
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/state') {
    const state = readJson(STATE_FILE, {
      bridgeVersion: 1,
      connected: false,
      updatedAt: null,
      currentPage: 'regions',
      markerMode: false,
      currentPlaylistName: '',
      activePlaylistId: null,
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
    })
    sendJson(res, 200, state)
    return
  }
  if (req.method === 'POST' && parsedUrl.pathname === '/command') {
    let body = ''
    req.on('data', (chunk) => {
      body += chunk.toString('utf8')
      if (body.length > 1024 * 100) req.destroy()
    })
    req.on('end', () => {
      try {
        const parsed = body ? JSON.parse(body) : {}
        const type = typeof parsed.type === 'string' ? parsed.type : 'unknown'
        const payload = parsed.payload && typeof parsed.payload === 'object' ? parsed.payload : {}
        const command = enqueueCommand(type, payload)
        sendJson(res, 200, { ok: true, command })
      } catch (error) {
        sendJson(res, 400, { ok: false, error: 'JSON inválido' })
      }
    })
    return
  }
  if (req.method === 'GET' && parsedUrl.pathname === '/bridge-info') {
    sendJson(res, 200, {
      ok: true,
      host: PUBLIC_BRIDGE_HOST,
      lanHost: getLanIp(),
      port: PORT,
      publicUrl: `http://${PUBLIC_BRIDGE_HOST}:${PORT}`,
      stateFile: STATE_FILE,
      commandsFile: COMMANDS_FILE,
    })
    return
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
  res.end('404')
})

server.listen(PORT, HOST, () => {
  const ip = getLanIp()
  console.log('')
  console.log('===========================================')
  console.log('VS Hook Musicos Bridge ligado')
  console.log(`PC:       http://127.0.0.1:${PORT}`)
  console.log(`Celular:  http://${PUBLIC_BRIDGE_HOST}:${PORT}`)
  console.log(`LAN:      http://${ip}:${PORT}`)
  console.log(`STATE(shared):    ${STATE_FILE}`)
  console.log(`COMMANDS(shared): ${COMMANDS_FILE}`)
  console.log('===========================================')
  console.log('')
})
