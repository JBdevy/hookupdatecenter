const crypto = require('crypto')
const dgram = require('dgram')
const http = require('http')
const os = require('os')

const DISCOVERY_PORT = 47833
const DISCOVER_MAGIC = 'VSHOOK_TIMECODE_DISCOVER_V1'
const OFFER_MAGIC = 'VSHOOK_TIMECODE_OFFER_V1'
const MTC_REDUNDANT_MAGIC = 'VSHOOK_MTC_REDUNDANT_V1'
const MTC_REDUNDANT_ACK_MAGIC = 'VSHOOK_MTC_REDUNDANT_ACK_V1'
const MTC_SOURCE_TIMEOUT_MS = 280
const PROJECT_SYNC_PROTOCOL_VERSION = 3
const MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024
const LOCAL_STATUS_INTERVAL_MS = 18
const TRANSMIT_INTERVAL_MS = 20
const CONNECTED_IDLE_INTERVAL_MS = 40
const RECEIVER_IDLE_INTERVAL_MS = 80
const PAIRING_IDLE_INTERVAL_MS = 100
const DISABLED_IDLE_INTERVAL_MS = 500
const DISCOVERY_INTERVAL_MS = 650
const DIRECT_DISCOVERY_INTERVAL_MS = 3000
const DIRECT_DISCOVERY_TIMEOUT_MS = 260
const DIRECT_DISCOVERY_BATCH_SIZE = 24
const RECEIVER_TIMEOUT_MS = 8000
const IDLE_LINK_HEARTBEAT_MS = 400
// A ponta LAN e um servidor Node e aceita conexao persistente. Reutilizar o
// socket remove o custo de um novo TCP handshake em cada pulso do Project Sync.
const lanHttpAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 1000,
  maxSockets: 32,
  maxFreeSockets: 8,
})

// Explicit control protocol shared with the native extension. Legacy project,
// media, playlist and configuration snapshots never enter the LAN or REAPER.
const PROJECT_SYNC_CONTROL_TYPES = new Set([
  "app_list_scroll", "at_bl_set", "at_bl_toggle",
  "atbl_toggle", "auto1_set", "auto1_toggle",
  "auto2_set", "auto2_toggle", "auto_bloco_set",
  "auto_bloco_toggle", "auto_set", "auto_stop",
  "auto_stop_set", "auto_stop_toggle", "auto_toggle",
  "autoplay1_set", "autoplay1_toggle", "autoplay2_set",
  "autoplay2_toggle", "autoplay_set", "autoplay_toggle",
  "autostop", "autostop_set", "autostop_toggle",
  "bpm_adjust", "bpm_focus", "bpm_set",
  "clear_queue", "clear_queued_song", "clear_selected_song",
  "clear_selection", "director_at_bl_toggle", "director_auto2_toggle",
  "director_auto_stop_toggle", "director_auto_toggle", "director_drawers_sync",
  "director_family_drawers_sync", "director_family_view_set", "director_family_view_toggle",
  "director_list_scroll", "director_live_reset_item", "director_live_set",
  "director_live_toggle", "director_loop_toggle", "director_pause",
  "director_play_button", "director_play_no_seek", "director_stop_break",
  "director_stop_no_seek", "edit_mode_stop_pause_set",
  "edit_cursor_move", "esc", "escape_key", "faderout_set",
  "key_escape", "live_reset_item", "live_set",
  "live_toggle", "loop_set", "loop_toggle",
  "lyrics_settings", "manual_stop_fadeout_set", "manual_stop_fadeout_set_all_tracks",
  "manual_stop_fadeout_set_duration", "manual_stop_fadeout_set_enabled", "manual_stop_fadeout_toggle_track",
  "marker_cancel", "marker_go", "marker_select",
  "mixer_bulk_unmute", "mixer_bulk_unsolo", "mixer_focus",
  "mixer_reset_volume", "mixer_route", "mixer_select_track",
  "mixer_set_route", "mixer_set_volume", "mixer_toggle_mute",
  "mixer_toggle_solo", "multi_loop_bypass_set",
  "multi_loop_bypass_toggle", "multi_loop_close", "multi_loop_focus",
  "multi_loop_ms_toggle", "multi_loop_open", "multi_loop_slot_toggle",
  "multi_loop_track_limit_set", "multi_loop_track_set", "multi_loop_track_toggle",
  "multi_project_playlists_set", "multiloop_bypass_set", "multiloop_bypass_toggle",
  "multiloop_close", "multiloop_fade_adjust", "multiloop_fade_set",
  "multiloop_focus", "multiloop_loop_toggle", "multiloop_ms_set",
  "multiloop_ms_toggle", "multiloop_open", "multiloop_slot_set",
  "multiloop_slot_toggle", "multiloop_track_limit_set", "multiloop_track_set",
  "multiloop_track_toggle", "parts_visibility_set", "play",
  "play_button", "play_protection_set", "play_protection_toggle",
  "play_start", "play_stop", "play_stop_no_seek",
  "play_toggle", "playlist_multi_set", "playlist_multi_toggle",
  "playlist_select", "premix_close", "premix_focus_song",
  "premix_item_open", "premix_item_set_track_solo", "premix_item_set_unique_solo",
  "premix_item_set_volume", "premix_item_toggle_mute", "premix_open",
  "premix_open_song", "premix_refresh", "premix_screen_close",
  "premix_set_volume", "premix_toggle_mute", "preview_clear",
  "preview_set", "preview_toggle", "project_sync_track_state",
  "queue_playlist_song", "queue_region_song",
  "recados_settings", "save_technical_notice_settings", "save_teleprompt_settings",
  "select_marker", "select_playlist", "select_playlist_song",
  "select_region", "set_active_playlist", "set_auto_stop",
  "set_autostop", "set_bpm_visibility", "set_page",
  "set_playlist", "set_tuner_visibility", "smart_search_activate",
  "smart_search_close", "smart_search_open", "smart_search_query",
  "stop", "stop_break", "stop_pause_mode_set",
  "stop_pause_mode_toggle", "technical_notice_settings", "teleprompt_settings",
  "teleprompt_window", "timer_config",
  "timer_init_auto_toggle", "timer_reset", "timer_set_init_auto",
  "timer_set_mode", "timer_set_target", "timer_start",
  "timer_stop", "timer_stop_reset", "timer_toggle",
  "toggle_auto_stop", "toggle_autostop", "transport_stop_no_seek",
  "trigger_marker", "tuner_adjust", "tuner_focus",
  "tuner_reset", "tuner_set", "ui_music_selection_snapshot",
])

// Traditional Timecode keeps continuous transport/cursor following. Project
// Sync shares stopped edit-cursor gestures; playback, Auto and queue run independently.
const TIMECODE_CONTROL_TYPES = new Set([...PROJECT_SYNC_CONTROL_TYPES,
  'project_sync_viewport_v1', 'mixer_viewport_set', 'timecode_transport_sync'])

function isRelayControlCommand(command, mode) {
  const types = mode === 'project_sync' ? PROJECT_SYNC_CONTROL_TYPES : TIMECODE_CONTROL_TYPES
  return !!command && typeof command === 'object' && !Array.isArray(command) &&
    types.has(String(command.type || '').trim().toLowerCase())
}

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

function normalizePeerAddress(value) {
  return String(value || '').trim().replace(/^::ffff:/, '')
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
  let deadlineTimer
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
    // Socket inactivity timeouts do not bound TCP connection establishment.
    // An unreachable discovery address must not hold an entire scan batch
    // until the operating system gives up (potentially minutes later).
    deadlineTimer = setTimeout(() => req.destroy(
      new Error('Tempo limite da sincronização esgotado.')), timeoutMs)
    if (body) req.write(body)
    req.end()
  }).finally(() => clearTimeout(deadlineTimer))
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
  const relayChannel = String(options.channel || 'main') === 'parallel'
    ? 'parallel' : 'main'
  const nativeStatusPath = relayChannel === 'parallel'
    ? '/timecode-parallel/status' : '/timecode/status'
  const nativeOutboxPath = relayChannel === 'parallel'
    ? '/timecode-parallel/outbox' : '/timecode/outbox'
  const nativeInboxPath = relayChannel === 'parallel'
    ? '/timecode-parallel/inbox' : '/timecode/inbox'
  const linkPrefix = relayChannel === 'parallel'
    ? '/timecode-parallel-link' : '/timecode-link'
  // Na rede, o canal paralelo conversa com um Receive comum no PC C. Só os
  // endpoints localhost da extensão A são separados; o protocolo remoto de
  // Timecode continua sendo o mesmo para não exigir uma opção especial em C.
  const outboundLinkPrefix = relayChannel === 'parallel'
    ? '/timecode-link' : linkPrefix
  const discoverMagic = DISCOVER_MAGIC
  const offerMagic = OFFER_MAGIC
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
  const canUsePeerAddress =
    typeof options.canUsePeerAddress === 'function'
      ? options.canUsePeerAddress
      : () => true
  const onPeerConnectionChanged =
    typeof options.onPeerConnectionChanged === 'function'
      ? options.onPeerConnectionChanged
      : () => {}
  const onMtcSwitchChanged =
    typeof options.onMtcSwitchChanged === 'function'
      ? options.onMtcSwitchChanged
      : () => {}
  // Os dois canais da mesma Hook Center recebem a mesma identidade persistente
  // de main.js. Assim o mesmo computador nao pode ocupar simultaneamente os
  // papeis PC B (Project Sync) e PC C (Timecode), mesmo por placas/IPs distintos.
  const suppliedInstanceId = String(options.instanceId || '').trim().toLowerCase()
  const instanceId = /^[a-f0-9]{32,128}$/.test(suppliedInstanceId)
    ? suppliedInstanceId
    : crypto.randomBytes(16).toString('hex')

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
  let projectSyncRoleHandoverPromise = null
  let lastProjectSyncRoleHandoverKey = ''
  let pairingInProgress = false
  let relayLifecycleSequence = 0
  const pairingCandidateNotices = new Set()
  const mtcRedundantSources = new Map()
  let mtcActiveRole = ''
  let mtcBackupLatched = false
  let mtcPrimaryStableSince = 0
  let lastMtcRedundantAckAt = 0
  let mtcManualRole = ''
  function projectSyncRole(status) {
    const role = String(status?.projectSyncRole || '').trim().toLowerCase()
    return role === 'primary' || role === 'secondary' ? role : ''
  }

  function selectedPeerId(status) {
    return String(status?.selectedPeerId || '').trim().toLowerCase()
  }

  function rejectedPeerId(status) {
    return String(status?.rejectedPeerId || '').trim().toLowerCase()
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

  async function projectSyncCapabilities(status, address, port) {
    try {
      const result = await requestJson({
        hostname: address, port,
        path: `${outboundLinkPrefix}/capabilities`, method: 'POST',
        payload: { mode: 'project_sync', protocolVersion: PROJECT_SYNC_PROTOCOL_VERSION },
        timeoutMs: 1200,
      })
      return result.ok && result.data?.ok === true &&
        Number(result.data.projectSyncProtocolVersion) === PROJECT_SYNC_PROTOCOL_VERSION &&
        result.data.projectSyncControlsOnly === true
    } catch (_) { return false }
  }

  function safeRequestId(value) {
    const requestId = String(value || '').trim().toLowerCase()
    return /^[a-f0-9]{16,128}$/.test(requestId) ? requestId : ''
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
      audioHealthy: transport.audioHealthy !== false,
      frameRate: Math.max(20, Math.min(60,
        Number(transport.frameRate) || 30)),
      dropFrame: transport.dropFrame === true,
    }
  }

  function timecodeTransportForSend(status, peer, transport) {
    if (status?.mode === 'project_sync') return null
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
    // Traditional Timecode protects the receiver from physical device loss;
    // Project Sync never sends these samples, even when explicitly flagged.
    const healthy = transportAudioHealthy(status, transport)
    if (!healthy) {
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
      // A primeira ordem humana depois da falha e autoritativa. Sem este caso,
      // um Play feito quando o driver acabou de reabrir podia ser confundido
      // com a recuperacao tecnica e ficar bloqueado ate a proxima acao.
      if (explicitControl) {
        peer.resumeControlSequenceFloor = null
        peer.lastHealthyTransport = snapshot
        return {
          ...transport,
          explicitControl: true,
        }
      }
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
    return explicitControl
      ? { ...transport, explicitControl: true }
      : transport
  }

  function timecodeTransportForReceive(session, status, payload, transport) {
    if (status?.mode === 'project_sync' || !transport) return null
    const healthy = transportAudioHealthy(payload, transport)
    const explicitControl = transport.explicitControl === true
    if (!healthy && !explicitControl) {
      session.audioHealthy = false
      return null
    }
    session.audioHealthy = healthy
    // Traditional transmitters apply the driver-failure gate before sending.
    // Older transmitters remain supported, except explicitly unhealthy samples.
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
    try { ip = String(getDirectCableIp(localStatus, relayChannel) || '').trim() } catch (_) {}
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
    if (!force && now - lastStatusPollAt < 12) return localStatus
    // Serializa leituras concorrentes para não publicar status fora de ordem.
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
          path: nativeStatusPath,
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
        payload: relayChannel === 'parallel'
          ? { ...command, channel: 'parallel' }
          : command,
        timeoutMs: 550,
      })
      return result.ok
    } catch (_) {
      return false
    }
  }

  function projectSyncRoleHandoverRequest(status) {
    const handover = status?.projectSyncRoleHandover
    if (!handover || typeof handover !== 'object' ||
        String(handover.state || '').trim().toLowerCase() !== 'requested') return null
    const requestId = safeRequestId(handover.requestId)
    return requestId ? { requestId } : null
  }

  async function notifyLocalPeer(connected, peerName = '') {
    const marker = connected ? `1:${safeName(peerName, 'VS Hook')}` : '0:'
    if (marker === lastNotifiedPeer) return
    if (await sendLocalCommand({
      type: 'timecode_peer_status',
      connected: !!connected,
      peerName: connected ? safeName(peerName, 'VS Hook') : '',
      ...(relayChannel === 'parallel' ? { channel: 'parallel' } : {}),
    })) {
      lastNotifiedPeer = marker
    }
  }

  function clearProjectSyncTransientState() {
    lastProjectSyncRoleHandoverKey = ''
  }

  function resetTransmitterPeer(notify = true) {
    const previousAddress = normalizePeerAddress(transmitterPeer?.address)
    const previousPeerId = String(transmitterPeer?.receiverId || '').trim()
    transmitterPeer = null
    if (previousAddress) {
      try {
        onPeerConnectionChanged(
          relayChannel, previousAddress, false, previousPeerId)
      } catch (_) {}
    }
    if (notify) notifyLocalPeer(false).catch(() => {})
  }

  function resetReceiverSession(notify = true) {
    const previousAddress = normalizePeerAddress(receiverSession?.address)
    const previousPeerId = String(receiverSession?.transmitterId || '').trim()
    receiverSession = null
    if (previousAddress) {
      try {
        onPeerConnectionChanged(
          relayChannel, previousAddress, false, previousPeerId)
      } catch (_) {}
    }
    if (notify) notifyLocalPeer(false).catch(() => {})
  }

  async function publishProjectSyncRoleHandoverState(requestId, state, error = '') {
    await sendLocalCommand({
      type: 'project_sync_role_handover_state',
      requestId,
      state,
      error: String(error || '').slice(0, 1000),
    })
  }

  async function maybeHandoverProjectSyncRole(status) {
    const request = projectSyncRoleHandoverRequest(status)
    const connectedPeer = transmitterPeer?.connected &&
      transmitterPeer?.token && transmitterPeer?.remoteSessionId &&
      transmitterPeer?.localSessionId
      ? transmitterPeer
      : null
    const handoverPeer = connectedPeer
    if (!request || status?.mode !== 'project_sync' ||
        projectSyncRole(status) !== 'primary' ||
        !handoverPeer) {
      return false
    }
    const key = `${request.requestId}|${handoverPeer.receiverId}|${handoverPeer.remoteSessionId}`
    if (key === lastProjectSyncRoleHandoverKey || projectSyncRoleHandoverPromise) return true
    lastProjectSyncRoleHandoverKey = key
    projectSyncRoleHandoverPromise = (async () => {
      try {
        const result = await requestJson({
          hostname: handoverPeer.address,
          port: handoverPeer.port,
          path: `${outboundLinkPrefix}/project-sync/handover`,
          method: 'POST',
          payload: {
            code: String(status.code || ''),
            requestId: request.requestId,
            transmitterId: instanceId,
            sourceSessionId: handoverPeer.localSessionId,
            receiverSessionId: handoverPeer.remoteSessionId,
            token: handoverPeer.token,
            projectSyncRole: 'primary',
          },
          timeoutMs: 1400,
        })
        if (!result.ok || result.data?.ok !== true) {
          throw new Error(result.data?.error || 'O PC B não confirmou a troca de mestre.')
        }
        const localQueued = await sendLocalCommand({
          type: 'project_sync_role_handover',
          role: 'secondary',
          requestId: request.requestId,
        })
        if (!localQueued) {
          throw new Error('Não foi possível alterar este computador para PC B.')
        }
        // A extensão consome o comando no próximo ciclo principal. Encerrar o
        // peer antigo evita que um último pacote A -> B atravesse a troca.
        if (connectedPeer) resetTransmitterPeer(true)
        await publishProjectSyncRoleHandoverState(request.requestId, 'completed')
      } catch (error) {
        lastProjectSyncRoleHandoverKey = ''
        await publishProjectSyncRoleHandoverState(
          request.requestId, 'error', error?.message || 'Falha ao transferir mestre.')
      } finally {
        projectSyncRoleHandoverPromise = null
      }
    })()
    await projectSyncRoleHandoverPromise
    return true
  }

  function sendUdp(payload, address, port = discoveryTargetPort) {
    if (!socket) return
    const data = Buffer.from(JSON.stringify(payload), 'utf8')
    socket.send(data, 0, data.length,
      Math.max(1, Math.min(65535, Number(port) || discoveryTargetPort)),
      address, () => {})
  }

  function broadcastDiscovery(status) {
    const payload = {
      magic: discoverMagic,
      version: status?.mode === 'project_sync'
        ? PROJECT_SYNC_PROTOCOL_VERSION
        : 1,
      code: String(status.code || ''),
      transmitterId: instanceId,
      transmitterName: deviceName(),
      replyPort: discoveryPort,
      mode: status.mode,
      projectSyncRole: projectSyncRole(status),
    }
    for (const address of getBroadcastAddresses().filter(peerAddressAllowed)) {
      sendUdp(payload, address)
    }
  }

  function redundantMtcRole(status) {
    const role = String(status?.redundancyRole ||
      status?.projectSyncRole || '').trim().toLowerCase()
    return role === 'primary' ? 'a' : role === 'secondary' ? 'b' : ''
  }

  function broadcastRedundantMtc(status) {
    if (relayChannel !== 'parallel' || status?.mode !== 'transmitter') return
    const sourceRole = redundantMtcRole(status)
    const transport = transportSnapshot(status.transport)
    if (!sourceRole || !transport || !isPairCode(status.code)) return
    const payload = {
      magic: MTC_REDUNDANT_MAGIC,
      version: 1,
      code: String(status.code || ''),
      sourceId: instanceId,
      sourceName: deviceName(),
      sourceRole,
      replyPort: discoveryPort,
      sentAtMs: Date.now(),
      transport,
    }
    for (const address of getBroadcastAddresses()) {
      // O receptor PC C usa a porta principal 47833. Os transmissores
      // paralelos A/B escutam em 47834 e nao consomem o proprio anuncio.
      sendUdp(payload, address, DISCOVERY_PORT)
    }
  }

  function chooseRedundantMtcSource(now) {
    const primary = mtcRedundantSources.get('a')
    const backup = mtcRedundantSources.get('b')
    const primaryPlaying = Number(primary?.transport?.playState) !== 0
    const backupPlaying = Number(backup?.transport?.playState) !== 0
    // Parado, alguns drivers fecham o dispositivo por preferencia do REAPER;
    // isso nao e falha. Durante playback, se A perde audio enquanto B continua,
    // A deixa imediatamente de ser uma fonte valida mesmo com rede ativa.
    const primaryOperational = primary?.transport?.audioHealthy !== false ||
      (!primaryPlaying && !backupPlaying)
    const backupOperational = backup?.transport?.audioHealthy !== false
    const primaryFresh = !!primary &&
      now - primary.receivedAt <= MTC_SOURCE_TIMEOUT_MS &&
      primaryOperational
    const backupFresh = !!backup &&
      now - backup.receivedAt <= MTC_SOURCE_TIMEOUT_MS &&
      backupOperational
    if (mtcManualRole === 'a' && primaryFresh) return primary
    if (mtcManualRole === 'b' && backupFresh) return backup
    if (primaryFresh) {
      if (!mtcPrimaryStableSince) mtcPrimaryStableSince = now
    } else {
      mtcPrimaryStableSince = 0
    }

    if (mtcBackupLatched) {
      // Durante o show nunca retorna sozinho para A. O retorno automatico so
      // acontece parado e depois de A permanecer estavel por dois segundos.
      if (primaryFresh && !backupPlaying && !primaryPlaying &&
          now - mtcPrimaryStableSince >= 2000) {
        mtcBackupLatched = false
      } else if (backupFresh) {
        return backup
      } else if (primaryFresh) {
        // Se a propria reserva cair, A volta a ser melhor que perder o MTC.
        mtcBackupLatched = false
        return primary
      }
    }
    if (primaryFresh) return primary
    if (backupFresh) {
      mtcBackupLatched = true
      return backup
    }
    return null
  }

  async function handleRedundantMtc(message, rinfo) {
    if (relayChannel !== 'main' || !licenseIsActive()) return
    const status = await readLocalStatus()
    if (status?.mode !== 'receive' || !isPairCode(status.code) ||
        String(message.code || '') !== String(status.code)) return
    const sourceRole = String(message.sourceRole || '').trim().toLowerCase()
    const sourceId = String(message.sourceId || '').trim().toLowerCase()
    const transport = transportSnapshot(message.transport)
    if ((sourceRole !== 'a' && sourceRole !== 'b') ||
        !/^[a-f0-9]{32,128}$/.test(sourceId) || !transport) return
    const now = Date.now()
    mtcRedundantSources.set(sourceRole, {
      sourceRole,
      sourceId,
      sourceName: safeName(message.sourceName,
        sourceRole === 'a' ? 'PC A' : 'PC B'),
      transport,
      receivedAt: now,
    })
    sendUdp({
      magic: MTC_REDUNDANT_ACK_MAGIC,
      version: 1,
      receiverId: instanceId,
      sourceId,
      activeRole: mtcActiveRole,
    }, normalizePeerAddress(rinfo?.address),
    Math.max(1, Math.min(65535,
      Number(message.replyPort) || 47834)))
    const active = chooseRedundantMtcSource(now)
    if (!active || active.sourceRole !== sourceRole) return
    const sourceChanged = mtcActiveRole !== active.sourceRole
    mtcActiveRole = active.sourceRole
    if (sourceChanged) {
      try {
        onMtcSwitchChanged({
          activeSource: active.sourceRole === 'a' ? 'PC A' : 'PC B',
          activeRole: active.sourceRole,
          automatic: !mtcManualRole,
          changedAt: new Date().toISOString(),
        })
      } catch (_) {}
    }
    await sendLocalCommand({
      type: 'timecode_transport_sync',
      playState: active.transport.playState,
      position: active.transport.position,
      sequence: active.transport.sequence,
      controlSequence: active.transport.controlSequence,
      sampledAtMs: active.transport.sampledAtMs,
      audioHealthy: true,
      frameRate: active.transport.frameRate,
      dropFrame: active.transport.dropFrame,
      mtcTransport: true,
      mtcSource: active.sourceRole === 'a' ? 'PC A' : 'PC B',
      mtcSourceChanged: sourceChanged,
      __vshookLanRemote: true,
    })
  }

  async function pairWithReceiver(status, address, remotePort, receiver = {}) {
    const offeredReceiverId = String(receiver.id || '').trim().toLowerCase()
    if (!statusCanTransmit(status) || !isPairCode(status.code) ||
        !offeredReceiverId || selectedPeerId(status) !== offeredReceiverId ||
        transmitterPeer?.connected || pairingInProgress || stopped || !peerAddressAllowed(address) ||
        !canUsePeerAddress(relayChannel, normalizePeerAddress(address), offeredReceiverId)) return false
    const lifecycle = relayLifecycleSequence
    pairingInProgress = true
    try {
      const projectSync = status.mode === 'project_sync'
      if (projectSync && !await projectSyncCapabilities(status, address, remotePort)) return false
      const localEventBaseline = safeSequence(status.eventSequence)
      const localSessionId = String(status.sessionId || '').trim()
      if (projectSync && !localSessionId) return false
      const result = await requestJson({
        hostname: address, port: remotePort,
        path: `${outboundLinkPrefix}/pair`, method: 'POST',
        payload: {
          code: status.code, transmitterId: instanceId, transmitterName: deviceName(),
          mode: status.mode, protocolVersion: projectSync ? PROJECT_SYNC_PROTOCOL_VERSION : 1,
          projectSyncRole: projectSyncRole(status), eventSequence: localEventBaseline,
          sessionId: localSessionId,
        },
        timeoutMs: Math.max(projectSync ? 1800 : 0, Number(receiver.timeoutMs) || 1000),
      })
      if (!result.ok || result.data?.ok !== true || !result.data.token ||
          transmitterPeer?.connected || stopped || lifecycle !== relayLifecycleSequence) return false
      if (projectSync && (Number(result.data.projectSyncProtocolVersion) !== PROJECT_SYNC_PROTOCOL_VERSION ||
          result.data.projectSyncControlsOnly !== true || result.data.ready !== true ||
          !projectSyncRolesMatch(projectSyncRole(status), result.data.projectSyncRole) ||
          !String(result.data.receiverSessionId || '').trim())) return false
      const confirmed = await readLocalStatus(true)
      if (!statusCanTransmit(confirmed) || confirmed.mode !== status.mode ||
          String(confirmed.code || '') !== String(status.code || '') ||
          String(confirmed.sessionId || '').trim() !== localSessionId ||
          selectedPeerId(confirmed) !== offeredReceiverId || stopped || lifecycle !== relayLifecycleSequence) return false
      const remoteId = String(result.data.receiverId || '').trim().toLowerCase()
      if (remoteId !== offeredReceiverId || !canUsePeerAddress(
        relayChannel, normalizePeerAddress(address), remoteId)) return false
      transmitterPeer = {
        address, port: remotePort, receiverId: remoteId,
        name: safeName(result.data.receiverName || receiver.name, 'Receiver'),
        token: String(result.data.token), code: String(status.code || ''), mode: status.mode,
        lastSequence: localEventBaseline, lastTransportSequence: 0, lastPacketAt: 0,
        audioHealthy: true, lastHealthyTransport: null,
        lastObservedControlSequence: safeSequence(confirmed?.transport?.controlSequence),
        resumeControlSequenceFloor: null, localSessionId,
        remoteSessionId: projectSync ? String(result.data.receiverSessionId).trim() : '',
        failures: 0, connected: true,
      }
      try { onPeerConnectionChanged(relayChannel, normalizePeerAddress(address), true, remoteId) } catch (_) {}
      if (projectSync) receiverSession = null
      await notifyLocalPeer(true, transmitterPeer.name)
      return true
    } catch (_) { return false }
    finally { pairingInProgress = false }
  }

  async function considerReceiverCandidate(status, address, remotePort,
    receiver = {}) {
    const receiverId = String(receiver.id || '').trim().toLowerCase()
    if (!receiverId || receiverId === instanceId ||
        !statusCanTransmit(status) || transmitterPeer?.connected || stopped ||
        !peerAddressAllowed(address) || !canUsePeerAddress(
          relayChannel, normalizePeerAddress(address), receiverId)) return false
    if (status.mode === 'project_sync' &&
        !projectSyncRolesMatch(
          projectSyncRole(status), receiver.projectSyncRole)) return false

    const selected = selectedPeerId(status)
    if (selected) {
      if (selected !== receiverId) return false
      return pairWithReceiver(status, address, remotePort, receiver)
    }
    if (rejectedPeerId(status) === receiverId) return false

    const noticeKey = [relayChannel, status.mode,
      projectSyncRole(status), receiverId].join('|')
    if (!pairingCandidateNotices.has(noticeKey)) {
      pairingCandidateNotices.add(noticeKey)
      const accepted = await sendLocalCommand({
        type: 'timecode_pair_candidate',
        peerId: receiverId,
        peerName: safeName(receiver.name,
          status.mode === 'project_sync' ? 'PC B' : 'Receiver'),
      })
      if (!accepted) pairingCandidateNotices.delete(noticeKey)
    }
    return false
  }

  async function acceptOffer(message, rinfo) {
    const status = await readLocalStatus()
    if (!statusCanTransmit(status) || !isPairCode(status.code)) return
    if (String(message.code || '') !== String(status.code)) return
    if (String(message.transmitterId || '') !== instanceId) return
    if (status.mode === 'project_sync' &&
        Number(message.version) !== PROJECT_SYNC_PROTOCOL_VERSION) {
      return
    }
    if (status.mode === 'project_sync' &&
        !projectSyncRolesMatch(
          projectSyncRole(status), message.projectSyncRole)) return
    const remotePort = Math.max(1, Math.min(65535, Number(message.port) || 47831))
    await considerReceiverCandidate(status, rinfo.address, remotePort, {
      id: String(message.receiverId || '').trim().toLowerCase(),
      name: message.receiverName,
      projectSyncRole: message.projectSyncRole,
    })
  }

  async function discoverReceiverOverTcp(status) {
    let addresses = []
    const cablePrefix = preferredCablePrefix()
    try {
      addresses = [...new Set(listDirectDiscoveryAddresses())].filter(peerAddressAllowed)
    } catch (_) {}
    const ports = [...new Set([
      Math.max(1, Math.min(65535, Number(getDirectorPort()) || 47831)),
      47831,
    ])]
    for (let offset = 0; offset < addresses.length && !transmitterPeer?.connected && !stopped; offset += DIRECT_DISCOVERY_BATCH_SIZE) {
      if (cablePrefix !== preferredCablePrefix()) break
      const batch = addresses.slice(offset, offset + DIRECT_DISCOVERY_BATCH_SIZE)
      await Promise.allSettled(batch.flatMap((address) => ports.map(
        async (port) => {
          const result = await requestJson({
            hostname: address,
            port,
            path: `${outboundLinkPrefix}/availability`,
            method: 'POST',
            payload: {
              transmitterId: instanceId,
              mode: status.mode,
              projectSyncRole: projectSyncRole(status),
            },
            timeoutMs: DIRECT_DISCOVERY_TIMEOUT_MS,
          })
          if (!result.ok || !result.data?.ok ||
              result.data.available !== true) return false
          return considerReceiverCandidate(status, address,
            Number(result.data.port) || port, {
              id: String(result.data.receiverId || '').trim().toLowerCase(),
              name: result.data.receiverName,
              projectSyncRole: result.data.projectSyncRole,
              timeoutMs: DIRECT_DISCOVERY_TIMEOUT_MS,
            })
        }
      )))
    }
  }

  async function handleUdpMessage(buffer, rinfo) {
    let message = null
    try { message = JSON.parse(buffer.toString('utf8')) } catch (_) { return }
    if (!message || typeof message !== 'object') return

    if (message.magic === MTC_REDUNDANT_MAGIC) {
      await handleRedundantMtc(message, rinfo)
      return
    }
    if (message.magic === MTC_REDUNDANT_ACK_MAGIC) {
      if (relayChannel !== 'parallel' ||
          String(message.sourceId || '').trim().toLowerCase() !== instanceId) {
        return
      }
      lastMtcRedundantAckAt = Date.now()
      await notifyLocalPeer(true, 'PC C (MTC redundante)')
      return
    }

    if (message.magic === discoverMagic) {
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
        magic: offerMagic,
        version: status.mode === 'project_sync'
          ? PROJECT_SYNC_PROTOCOL_VERSION
          : 1,
        code: status.code,
        transmitterId: String(message.transmitterId || ''),
        receiverId: instanceId,
        receiverName: deviceName(),
        port: Number(getDirectorPort()) || 47831,
        projectSyncRole: projectSyncRole(status),
      }, rinfo.address, Math.max(1, Math.min(65535,
        Number(message.replyPort) || discoveryTargetPort)))
      return
    }

    if (message.magic === offerMagic) {
      if (String(message.receiverId || '') === instanceId || !licenseIsActive()) return
      await acceptOffer(message, rinfo)
    }
  }

  async function transmitTick(status) {
    const now = Date.now()
    if (!transmitterPeer?.connected) {
      if (now - lastDiscoveryAt >= DISCOVERY_INTERVAL_MS) {
        lastDiscoveryAt = now
        broadcastDiscovery(status)
      }
      if (!directDiscoveryRunning && now - lastDirectDiscoveryAt >= DIRECT_DISCOVERY_INTERVAL_MS) {
        lastDirectDiscoveryAt = now
        directDiscoveryRunning = true
        discoverReceiverOverTcp(status).catch(() => {})
          .finally(() => { directDiscoveryRunning = false })
      }
      return
    }
    const peer = transmitterPeer
    const currentLocalSessionId = String(status.sessionId || '').trim()
    if (!peerAddressAllowed(peer.address) || peer.localSessionId !== currentLocalSessionId ||
        peer.code !== String(status.code || '') || peer.mode !== status.mode ||
        selectedPeerId(status) !== peer.receiverId) {
      resetTransmitterPeer(true)
      return
    }
    try {
      let packet = { events: [], transport: status.transport || {} }
      if (!Number.isFinite(Number(status.eventSequence)) ||
          safeSequence(status.eventSequence) > peer.lastSequence) {
        const outbox = await requestJson({
          hostname: '127.0.0.1', port: nativeBridgePort,
          path: nativeOutboxPath, method: 'POST',
          payload: { after: peer.lastSequence }, timeoutMs: 500,
        })
        if (!outbox.ok || !outbox.data?.ok) throw new Error('Outbox indisponível.')
        packet = outbox.data
      }
      const events = Array.isArray(packet.events) ? packet.events.slice(0, 256) : []
      const eventsForSend = events.filter(event =>
        safeSequence(event?.sequence, -1) >= 0 && isRelayControlCommand(event?.command, status.mode))
        .map(event => ({ sequence: event.sequence, command: event.command }))
      const rawTransport = packet.transport || status.transport || {}
      const audioHealthy = transportAudioHealthy(status, rawTransport)
      const mtcRole = relayChannel === 'parallel' ? redundantMtcRole(status) : ''
      const transportState = { ...peer }
      const transport = mtcRole ? null : timecodeTransportForSend(status, transportState, rawTransport)
      const transportSequence = transport ? safeSequence(transport.sequence) : peer.lastTransportSequence
      if (!events.length && (!transport || transportSequence === peer.lastTransportSequence) &&
          now - peer.lastPacketAt < IDLE_LINK_HEARTBEAT_MS) return
      const result = await requestJson({
        hostname: peer.address, port: peer.port,
        path: `${outboundLinkPrefix}/events`, method: 'POST',
        payload: {
          token: peer.token, code: status.code, transmitterId: instanceId,
          transmitterName: deviceName(), sessionId: currentLocalSessionId,
          projectSyncRole: projectSyncRole(status), events: eventsForSend,
          ...(transport ? { transport } : {}), audioHealthy,
        }, timeoutMs: 1800,
      })
      if (transmitterPeer !== peer || stopped) return
      if (!result.ok || !result.data?.ok) throw new Error('Receiver indisponível.')
      if (status.mode === 'project_sync' &&
          String(result.data.receiverSessionId || '').trim() !== peer.remoteSessionId) {
        resetTransmitterPeer(true)
        return
      }
      const acknowledged = safeSequence(result.data.acceptedSequence, -1)
      const highestSent = eventsForSend.reduce((highest,event) => Math.max(highest,
        safeSequence(event.sequence)), peer.lastSequence)
      if (acknowledged >= peer.lastSequence && acknowledged <= highestSent) {
        peer.lastSequence = acknowledged
        // Disallowed legacy mutations must not pin the local outbox forever.
        // Advance past them only after every allowed command was acknowledged.
        if (acknowledged === highestSent) peer.lastSequence = events.reduce((highest,event) =>
          Math.max(highest,safeSequence(event?.sequence)), peer.lastSequence)
      }
      peer.audioHealthy = transportState.audioHealthy
      peer.lastObservedControlSequence = transportState.lastObservedControlSequence
      peer.lastHealthyTransport = transportState.lastHealthyTransport
      peer.resumeControlSequenceFloor = transportState.resumeControlSequenceFloor
      if (transport) peer.lastTransportSequence = transportSequence
      peer.lastPacketAt = Date.now()
      peer.failures = 0
    } catch (_) {
      if (transmitterPeer !== peer) return
      peer.failures += 1
      if (peer.failures >= 5) resetTransmitterPeer(true)
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
        clearProjectSyncTransientState()
        pairingCandidateNotices.clear()
        return
      }
      broadcastRedundantMtc(status)
      if (relayChannel === 'parallel' && lastMtcRedundantAckAt &&
          Date.now() - lastMtcRedundantAckAt > RECEIVER_TIMEOUT_MS && !transmitterPeer?.connected) {
        lastMtcRedundantAckAt = 0
        await notifyLocalPeer(false)
      }
      if (relayChannel === 'parallel' && status.mode === 'transmitter' && redundantMtcRole(status) === 'b') {
        if (transmitterPeer) resetTransmitterPeer(false)
        if (receiverSession) resetReceiverSession(false)
        return
      }
      if (statusCanTransmit(status)) {
        if (status.mode === 'project_sync' && await maybeHandoverProjectSyncRole(status)) return
        if (receiverSession) resetReceiverSession(false)
        await transmitTick(status)
      } else if (statusCanReceive(status)) {
        if (transmitterPeer) resetTransmitterPeer(false)
        if (receiverSession && (receiverSession.code !== String(status.code || '') ||
            receiverSession.mode !== status.mode ||
            receiverSession.localSessionId !== String(status.sessionId || '').trim() ||
            Date.now() - receiverSession.lastSeenAt > RECEIVER_TIMEOUT_MS)) {
          // Losing the link never injects Stop: the redundant PC keeps playing.
          resetReceiverSession(true)
        }
      } else {
        if (transmitterPeer) resetTransmitterPeer(true)
        if (receiverSession) resetReceiverSession(true)
        clearProjectSyncTransientState()
      }
    } finally { tickRunning = false }
  }

  function nextTickIntervalMs() {
    const status = localStatus
    // Playback alone does not activate a disabled relay. Both relay instances
    // used to poll at 50 Hz with no pairing code, needlessly waking REAPER.
    // Incoming HTTP/UDP requests still wake the receiver independently of UI.
    if (!licenseIsActive() || !status || !isPairCode(status.code) ||
        (!statusCanTransmit(status) && !statusCanReceive(status))) {
      return DISABLED_IDLE_INTERVAL_MS
    }
    const playState = Math.max(0,
      Math.trunc(Number(status?.transport?.playState) || 0))
    const transportActive = playState !== 0 && (playState & 2) !== 2
    if (transportActive || projectSyncRoleHandoverPromise) return TRANSMIT_INTERVAL_MS
    if (transmitterPeer?.connected) return CONNECTED_IDLE_INTERVAL_MS
    // O receptor recebe pacotes pelo servidor HTTP, sem depender deste tick.
    // Aqui basta manter timeout/estado com uma cadencia leve quando parado.
    if (receiverSession) return RECEIVER_IDLE_INTERVAL_MS
    if (status && isPairCode(status.code) &&
        (statusCanTransmit(status) || statusCanReceive(status))) {
      return PAIRING_IDLE_INTERVAL_MS
    }
    return DISABLED_IDLE_INTERVAL_MS
  }

  function scheduleNextTick(delayMs = nextTickIntervalMs()) {
    if (stopped) return
    if (tickTimer) clearTimeout(tickTimer)
    tickTimer = setTimeout(async () => {
      tickTimer = null
      try { await tick() } catch (_) {}
      scheduleNextTick()
    }, Math.max(1, Number(delayMs) || TRANSMIT_INTERVAL_MS))
    tickTimer.unref?.()
  }

  async function handleAvailability(req, res) {
    const payload = await readJsonBody(req, 32 * 1024)
    const status = await readLocalStatus(true)
    const transmitterId = String(
      payload.transmitterId || '').trim().toLowerCase()
    const senderMode = String(payload.mode || '').trim().toLowerCase()
    const address = normalizePeerAddress(req.socket?.remoteAddress)
    const rolesCompatible = senderMode !== 'project_sync' ||
      projectSyncRolesMatch(payload.projectSyncRole,
        projectSyncRole(status))
    const modesCompatible =
      (senderMode === 'transmitter' && status?.mode === 'receive') ||
      (senderMode === 'project_sync' &&
        status?.mode === 'project_sync' && rolesCompatible)
    const occupiedByAnother = !!receiverSession &&
      receiverSession.transmitterId !== transmitterId
    const available = licenseIsActive() && statusCanReceive(status) &&
      isPairCode(status?.code) && modesCompatible && !!transmitterId &&
      transmitterId !== instanceId && !occupiedByAnother &&
      peerAddressAllowed(address) && canUsePeerAddress(
        relayChannel, address, transmitterId)
    sendJson(res, 200, {
      ok: true,
      available,
      receiverId: available ? instanceId : '',
      receiverName: available ? deviceName() : '',
      port: available ? (Number(getDirectorPort()) || 47831) : 0,
      projectSyncRole: available ? projectSyncRole(status) : '',
    })
  }

  async function handlePair(req, res) {
    const payload = await readJsonBody(req, 32 * 1024)
    const status = await readLocalStatus(true)
    const address = normalizePeerAddress(req.socket?.remoteAddress)
    const transmitterId = String(payload.transmitterId || '').trim().toLowerCase()
    const code = String(payload.code || '').trim()
    const projectSync = payload.mode === 'project_sync'
    if (stopped || !licenseIsActive() || !statusCanReceive(status) || !isPairCode(status?.code) ||
        code !== String(status.code)) {
      sendJson(res, 403, { ok: false, error: 'Código de pareamento inválido.' }); return
    }
    if (!transmitterId || transmitterId === instanceId || !peerAddressAllowed(address) ||
        !canUsePeerAddress(relayChannel, address, transmitterId)) {
      sendJson(res, 409, { ok: false, error: 'Computador indisponível para este canal.' }); return
    }
    if ((projectSync && (status.mode !== 'project_sync' ||
        !projectSyncRolesMatch(payload.projectSyncRole, projectSyncRole(status)))) ||
        (!projectSync && (payload.mode !== 'transmitter' || status.mode !== 'receive'))) {
      sendJson(res, 409, { ok: false, error: 'Papéis de pareamento incompatíveis.' }); return
    }
    if (projectSync && Number(payload.protocolVersion) !== PROJECT_SYNC_PROTOCOL_VERSION) {
      sendJson(res, 426, { ok: false, projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
        error: 'Atualize a Hook Center nos dois PCs para sincronizar somente controles.' }); return
    }
    const remoteSessionId = String(payload.sessionId || '').trim()
    const localSessionId = String(status.sessionId || '').trim()
    if (projectSync && (!remoteSessionId || !localSessionId)) {
      sendJson(res, 409, { ok: false, error: 'Sessão VS Hook indisponível.' }); return
    }
    if (receiverSession && Date.now()-receiverSession.lastSeenAt <= RECEIVER_TIMEOUT_MS &&
        (receiverSession.transmitterId !== transmitterId || receiverSession.address !== address)) {
      sendJson(res, 409, { ok: false, error: 'Este computador já está pareado.' }); return
    }
    if (receiverSession?.deliveryInFlight) {
      sendJson(res, 503, { ok: false, error: 'Aguardando confirmação dos controles anteriores.' }); return
    }
    const same = receiverSession && receiverSession.code === code &&
      receiverSession.transmitterId === transmitterId && receiverSession.address === address &&
      receiverSession.remoteSessionId === remoteSessionId && receiverSession.localSessionId === localSessionId
    const baseline = safeSequence(payload.eventSequence)
    const token = same ? receiverSession.token : crypto.randomBytes(32).toString('hex')
    receiverSession = {
      token, code, transmitterId, remoteSessionId, localSessionId,
      name: safeName(payload.transmitterName, 'Transmitter'), address, mode: status.mode,
      lastSequence: same ? Math.max(receiverSession.lastSequence, baseline) : baseline,
      lastTransportSequence: same ? receiverSession.lastTransportSequence : 0,
      lastControlSequence: same ? receiverSession.lastControlSequence : -1,
      lastSourceTransport: same ? receiverSession.lastSourceTransport : null,
      audioHealthy: same ? receiverSession.audioHealthy : true, lastSeenAt: Date.now(),
    }
    if (projectSync) transmitterPeer = null
    try { onPeerConnectionChanged(relayChannel, address, true, transmitterId) } catch (_) {}
    await notifyLocalPeer(true, receiverSession.name)
    sendJson(res, 200, {
      ok: true, token, receiverId: instanceId, receiverName: deviceName(),
      receiverSessionId: localSessionId, projectSyncRole: projectSyncRole(status), ready: true,
      ...(projectSync ? { projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
        projectSyncControlsOnly: true } : {}),
    })
  }

  function tokenMatches(left, right) {
    const a = Buffer.from(String(left || ''), 'utf8')
    const b = Buffer.from(String(right || ''), 'utf8')
    return a.length > 0 && a.length === b.length && crypto.timingSafeEqual(a, b)
  }

  async function handleProjectSyncRoleHandover(req, res) {
    const payload = await readJsonBody(req)
    const status = await readLocalStatus(false)
    const requestId = safeRequestId(payload.requestId)
    const handoverSession = receiverSession
    if (stopped || !licenseIsActive() || !requestId ||
        status?.mode !== 'project_sync' ||
        projectSyncRole(status) !== 'secondary' ||
        !handoverSession ||
        String(payload.code || '') !== String(status.code || '') ||
        String(payload.transmitterId || '') !== handoverSession.transmitterId ||
        String(payload.sourceSessionId || '') !== handoverSession.remoteSessionId ||
        String(payload.receiverSessionId || '') !== handoverSession.localSessionId ||
        String(status.sessionId || '').trim() !== handoverSession.localSessionId ||
        normalizePeerAddress(req.socket?.remoteAddress) !== handoverSession.address ||
        !peerAddressAllowed(handoverSession.address) ||
        String(payload.projectSyncRole || '') !== 'primary' ||
        !tokenMatches(payload.token, handoverSession.token)) {
      sendJson(res, 403, { ok: false, error: 'Troca de mestre não autorizada.' })
      return
    }
    if (handoverSession.deliveryInFlight) {
      sendJson(res, 503, { ok: false, error: 'Aguardando confirmação dos controles anteriores.' }); return
    }
    const queued = await sendLocalCommand({
      type: 'project_sync_role_handover',
      role: 'primary',
      requestId,
    })
    if (!queued) {
      sendJson(res, 503, { ok: false, error: 'A extensão VS Hook do PC B não respondeu.' })
      return
    }
    // Impede que o relay B aceite mais um pacote A -> B enquanto a extensão
    // troca o papel. A próxima descoberta nasce automaticamente como novo A.
    resetReceiverSession(true)
    sendJson(res, 200, { ok: true, requestId })
  }

  async function handleEvents(req, res) {
    const payload = await readJsonBody(req)
    const status = await readLocalStatus(false)
    if (stopped || !licenseIsActive() || !statusCanReceive(status) ||
        !receiverSession || String(payload.code || '') !== String(status.code) ||
        receiverSession.code !== String(status.code || '') ||
        receiverSession.mode !== status.mode ||
        normalizePeerAddress(req.socket?.remoteAddress) !== receiverSession.address ||
        !peerAddressAllowed(receiverSession.address) ||
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
    if (status.mode === 'project_sync' &&
        String(status.sessionId || '').trim() !== receiverSession.localSessionId) {
      resetReceiverSession(true)
      sendJson(res, 403, { ok: false, error: 'Pareamento expirado.' })
      return
    }
    const session = receiverSession
    if (session.deliveryInFlight) {
      sendJson(res, 503, { ok: false, error: 'Aguardando confirmação dos controles anteriores.' })
      return
    }
    session.deliveryInFlight = true
    // Commit transport intent only after the native inbox accepts the batch.
    // Otherwise a retry could lose an explicit Stop/Play during audio failure.
    const transportState = { ...session }
    try {
      const commands = []
      const incoming = Array.isArray(payload.events) ? payload.events.slice(0, 256) : []
      let acceptedSequence = session.lastSequence
      for (const event of incoming) {
        const sequence = safeSequence(event?.sequence, -1)
        if (sequence < 0) continue
        if (sequence <= acceptedSequence || !event?.command || typeof event.command !== 'object') continue
        if (!isRelayControlCommand(event.command, status.mode)) {
          acceptedSequence = Math.max(acceptedSequence, sequence)
          continue
        }
        commands.push(JSON.stringify({
          ...event.command,
          ...(relayChannel === 'parallel' ? { channel: 'parallel' } : {}),
          __vshookLanRemote: true,
        }))
        acceptedSequence = Math.max(acceptedSequence, sequence)
      }
      const rawTransport = status.mode !== 'project_sync' &&
          payload.transport && typeof payload.transport === 'object'
        ? payload.transport
        : null
      // Mesmo quando A omite completamente o transporte congelado, conserva o
      // estado de falha na sessao receptora. Assim um pacote atrasado nao pode
      // reativar correcoes enquanto o link ainda declara audio indisponivel.
      if (!transportAudioHealthy(payload, rawTransport)) {
        transportState.audioHealthy = false
      }
      const transportSequence = safeSequence(rawTransport?.sequence)
      const lastTransportSequence = safeSequence(
        session.lastTransportSequence)
      const transportIsFresh = !!rawTransport &&
        (transportSequence > lastTransportSequence ||
         status.mode !== 'project_sync' && transportSequence === 0)
      const transport = transportIsFresh
        ? timecodeTransportForReceive(
            transportState, status, payload, rawTransport)
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
          frameRate: Math.max(20, Math.min(60,
            Number(transport.frameRate) || 30)),
          dropFrame: transport.dropFrame === true,
          mtcTransport: true,
          mtcSource: 'PC A',
          ...(relayChannel === 'parallel' ? { channel: 'parallel' } : {}),
          __vshookLanRemote: true,
        }))
      }

      if (commands.length > 0) {
        const localResult = await requestRaw({
          hostname: '127.0.0.1',
          port: nativeBridgePort,
          path: nativeInboxPath,
          body: commands.join('\n'),
          timeoutMs: 700,
        })
        if (!localResult.ok || !localResult.data?.ok ||
            Number(localResult.data?.queued) !== commands.length) {
          sendJson(res, 503, { ok: false, error: 'Extensão VS Hook local indisponível.' })
          return
        }
      }
      if (receiverSession !== session || stopped) {
        sendJson(res, 403, { ok: false, error: 'Pareamento expirado.' })
        return
      }
      session.audioHealthy = transportState.audioHealthy
      session.lastControlSequence = transportState.lastControlSequence
      session.lastSourceTransport = transportState.lastSourceTransport
      session.lastSequence = acceptedSequence
      if (acceptTransport) {
        session.lastTransportSequence = transportSequence
      }
      session.lastSeenAt = Date.now()
      sendJson(res, 200, {
        ok: true,
        acceptedSequence,
        receiverSessionId: status.mode === 'project_sync'
          ? String(status.sessionId || '').trim() : undefined,
        projectSyncControlsOnly: status.mode === 'project_sync' ? true : undefined,
      })
    } finally { session.deliveryInFlight = false }
  }

  async function handleHttp(req, res, parsedUrl) {
    const pathname = String(parsedUrl?.pathname || '')
    if (!pathname.startsWith(`${linkPrefix}/`)) return false
    try {
      if (req.method === 'POST' &&
          pathname === `${linkPrefix}/capabilities`) {
        // Somente leitura: permite ao PC A rejeitar uma Central antiga antes
        // que /pair altere qualquer estado no PC B.
        sendJson(res, 200, {
          ok: true,
          projectSyncProtocolVersion: PROJECT_SYNC_PROTOCOL_VERSION,
          projectSyncPreflight: false,
          projectSyncControlsOnly: true,
          projectSyncFileTransfer: false,
          projectSyncDirection: 'primary_to_secondary',
        })
      } else if (req.method === 'POST' &&
          pathname === `${linkPrefix}/availability`) {
        await handleAvailability(req, res)
      } else if (req.method === 'POST' && pathname === `${linkPrefix}/pair`) {
        await handlePair(req, res)
      } else if (pathname === `${linkPrefix}/preflight` ||
          pathname.startsWith(`${linkPrefix}/project-sync/bundle/`)) {
        req.resume()
        sendJson(res, 410, { ok: false, error: 'Project Sync sincroniza somente controles. Transferência de arquivos desativada.' })
      } else if (req.method === 'POST' &&
          pathname === `${linkPrefix}/project-sync/handover`) {
        await handleProjectSyncRoleHandover(req, res)
      } else if (req.method === 'POST' && pathname === `${linkPrefix}/events`) {
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
    // Limpa um indicador que possa ter ficado preso na extensão se a Hook
    // Center anterior foi encerrada à força. A extensão só avisa quando o
    // estado anterior era realmente conectado, portanto o primeiro start não
    // cria um falso alerta.
    await notifyLocalPeer(false).catch(() => {})
    scheduleNextTick(1)
  }

  async function stop() {
    stopped = true
    relayLifecycleSequence += 1
    if (tickTimer) clearTimeout(tickTimer)
    tickTimer = null
    const hadConnectedPeer = !!transmitterPeer?.connected || !!receiverSession
    // Reiniciar/fechar a Hook Center também precisa limpar o indicador da
    // extensão. Sem isso, A/B/C continuavam aparecendo como pareados até a
    // próxima conexão, mesmo com o relay já encerrado.
    if (hadConnectedPeer) {
      try { await notifyLocalPeer(false) } catch (_) {}
    }
    resetTransmitterPeer(false)
    resetReceiverSession(false)
    clearProjectSyncTransientState()
    localStatus = null
    lastNotifiedPeer = ''
    mtcRedundantSources.clear()
    mtcActiveRole = ''
    mtcBackupLatched = false
    mtcPrimaryStableSince = 0
    mtcManualRole = ''
    directDiscoveryRunning = false
    const currentSocket = socket
    socket = null
    if (!currentSocket) return
    await new Promise((resolve) => {
      try { currentSocket.close(() => resolve()) } catch (_) { resolve() }
    })
  }

  function getMtcSwitchState() {
    const now = Date.now()
    const sourceState = (role) => {
      const source = mtcRedundantSources.get(role)
      return {
        connected: !!source && now - source.receivedAt <=
          MTC_SOURCE_TIMEOUT_MS * 4,
        name: source?.sourceName || '',
        lastSeenMs: source ? Math.max(0, now - source.receivedAt) : 0,
      }
    }
    return {
      activeSource: mtcActiveRole === 'a' ? 'PC A' :
        mtcActiveRole === 'b' ? 'PC B' : '',
      activeRole: mtcActiveRole,
      manualRole: mtcManualRole,
      backupLatched: mtcBackupLatched,
      primary: sourceState('a'),
      backup: sourceState('b'),
    }
  }

  function setMtcSwitchSource(value) {
    const role = String(value || '').trim().toLowerCase()
    mtcManualRole = role === 'a' || role === 'b' ? role : ''
    if (!mtcManualRole) mtcBackupLatched = false
    return getMtcSwitchState()
  }

  return { start, stop, handleHttp, getMtcSwitchState, setMtcSwitchSource }
}

module.exports = { createTimecodeLanRelay }
