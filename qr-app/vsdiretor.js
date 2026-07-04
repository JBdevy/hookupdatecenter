
function flattenBridgeHashChildrenFromSongList(songs) {
  const out = []
  // FIX23: não deduplicar músicas/filhos pelo id. O repertório pode ter a mesma música
  // repetida ou filhos com identidade parecida; dedupe aqui mudava a ordem visual no Diretor.
  const push = (item) => {
    if (!item || typeof item !== 'object') return
    out.push(item)
  }
  for (const song of Array.isArray(songs) ? songs : []) {
    push(song)
    const children = Array.isArray(song?.hashChildren) ? song.hashChildren
      : Array.isArray(song?.children) ? song.children
      : Array.isArray(song?.visibleChildren) ? song.visibleChildren
      : []
    for (const child of children) {
      push({
        ...child,
        isHashChild: true,
        isFamilyItem: true,
        familyRole: child?.familyRole || 'child',
        itemType: child?.itemType || 'hash_child',
        type: child?.type || 'hash_child',
        parentId: child?.parentId ?? song?.id,
        parentSourceNumber: child?.parentSourceNumber ?? song?.source_number ?? song?.sourceNumber,
        familyGroupId: child?.familyGroupId ?? song?.familyGroupId,
      })
    }
  }
  return out
}

function normalizeBridgePlaylistsWithHashChildren(playlists) {
  return (Array.isArray(playlists) ? playlists : []).map((playlist) => {
    const songs = flattenBridgeHashChildrenFromSongList(playlist?.songs || [])
      .map((song, index) => ({
        ...song,
        playlistOrder: Number.isFinite(Number(song?.playlistOrder)) ? Number(song.playlistOrder) : index + 1,
        order: Number.isFinite(Number(song?.order)) ? Number(song.order) : index + 1,
      }))
    return { ...playlist, songs }
  })
}


function flattenBridgeHashChildrenFromSongListForMusicosTotal(songs) {
  const out = []
  const seen = new Set()
  const push = (item) => {
    if (!item || typeof item !== 'object') return
    const key = String(item.id ?? item.source_number ?? item.sourceNumber ?? `${out.length}`)
    const role = String(item.familyRole || item.itemType || item.type || '')
    const dedupeKey = `${key}|${role}|${String(item.parentId || item.parentSourceNumber || '')}`
    if (seen.has(dedupeKey)) return
    seen.add(dedupeKey)
    out.push(item)
  }
  for (const song of Array.isArray(songs) ? songs : []) {
    push(song)
    const children = Array.isArray(song?.hashChildren) ? song.hashChildren
      : Array.isArray(song?.children) ? song.children
      : Array.isArray(song?.visibleChildren) ? song.visibleChildren
      : []
    for (const child of children) {
      push({
        ...child,
        isHashChild: true,
        isFamilyItem: true,
        familyRole: child?.familyRole || 'child',
        itemType: child?.itemType || 'hash_child',
        type: child?.type || 'hash_child',
        parentId: child?.parentId ?? song?.id,
        parentSourceNumber: child?.parentSourceNumber ?? song?.source_number ?? song?.sourceNumber,
        familyGroupId: child?.familyGroupId ?? song?.familyGroupId,
      })
    }
  }
  return out
}

function normalizeMusicosCompatiblePlaylistsForTotal(playlists) {
  return (Array.isArray(playlists) ? playlists : []).map((playlist) => ({
    ...playlist,
    songs: flattenBridgeHashChildrenFromSongListForMusicosTotal(playlist?.songs || []),
  }))
}

function getDirectorMusicosCompatiblePlaylistForTotal(fallbackPlaylist) {
  const playlists = Array.isArray(state.musicosCompatiblePlaylistsForTotal) ? state.musicosCompatiblePlaylistsForTotal : []
  if (!playlists.length) return fallbackPlaylist || null
  const activeId = String(state.activePlaylistId || '')
  const byId = playlists.find((item) => String(item?.id || '') === activeId)
  if (byId) return byId
  const currentName = String(state.currentPlaylistName || fallbackPlaylist?.name || '')
  const byName = playlists.find((item) => String(item?.name || '') === currentName)
  if (byName) return byName
  if (fallbackPlaylist?.id != null) {
    const byFallbackId = playlists.find((item) => String(item?.id || '') === String(fallbackPlaylist.id))
    if (byFallbackId) return byFallbackId
  }
  return playlists[0] || fallbackPlaylist || null
}



// Front local dos filhos R/P no Diretor.
// O bridge continua sendo a fonte oficial, mas o front usa cache local para abrir/fechar a gaveta imediatamente.
function vshookHashClean(value) {
  const text = String(value ?? '').trim()
  return text || ''
}

function vshookHashChildScope(type, playlistId) {
  if (type === 'song') return `playlist:${vshookHashClean(playlistId || state.activePlaylistId || '')}`
  if (type === 'region') return 'regions'
  return String(type || 'list')
}

function vshookHashFamilyIdentity(item) {
  if (!item || typeof item !== 'object') return ''
  try {
    const familyKey = typeof getHashFamilyKeyForAppItem === 'function' ? getHashFamilyKeyForAppItem(item) : ''
    if (vshookHashClean(familyKey)) return vshookHashClean(familyKey)
  } catch (_) {}
  return vshookHashClean(item.familyGroupId)
    || vshookHashClean(item.parentFamilyGroupId)
    || vshookHashClean(item.parentId)
    || vshookHashClean(item.parentSourceNumber)
    || vshookHashClean(item.source_number)
    || vshookHashClean(item.sourceNumber)
    || vshookHashClean(item.id)
    || vshookHashClean(item.songId)
}

function vshookHashParentIdentity(item) {
  if (!item || typeof item !== 'object') return ''
  try {
    const familyKey = typeof getHashFamilyKeyForAppItem === 'function' ? getHashFamilyKeyForAppItem(item) : ''
    if (vshookHashClean(familyKey)) return vshookHashClean(familyKey)
  } catch (_) {}
  return vshookHashClean(item.familyGroupId)
    || vshookHashClean(item.id)
    || vshookHashClean(item.songId)
    || vshookHashClean(item.source_number)
    || vshookHashClean(item.sourceNumber)
}

function vshookHashKeyForItem(item, type, playlistId) {
  const identity = isHashChildItem(item) ? vshookHashFamilyIdentity(item) : vshookHashParentIdentity(item)
  if (!identity) return ''
  return `${vshookHashChildScope(type, playlistId)}|${identity}`
}

function vshookHashKeyFromElement(el, type) {
  if (!el) return ''
  const playlistId = state.activePlaylistId || ''
  const scope = vshookHashChildScope(type === 'song' ? 'song' : 'region', playlistId)
  const id = type === 'region' ? el.getAttribute('data-region-id') : el.getAttribute('data-song-id')
  const sourceNumber = vshookHashClean(el.getAttribute('data-source-number'))
  const sourceStart = vshookHashClean(el.getAttribute('data-source-start'))
  const sourceIdentity = sourceNumber || sourceStart ? `${sourceNumber}|${sourceStart}` : ''
  const identity = vshookHashClean(el.getAttribute('data-family-group-id'))
    || sourceIdentity
    || vshookHashClean(el.getAttribute('data-parent-id'))
    || vshookHashClean(id)
  return identity ? `${scope}|${identity}` : ''
}

function vshookEnsureHashFrontState() {
  state.hashChildLocalOpenByKey = state.hashChildLocalOpenByKey || {}
  state.hashChildCacheByParentKey = state.hashChildCacheByParentKey || {}
  state.hashChildOpeningUntilByKey = state.hashChildOpeningUntilByKey || {}
  state.hashChildClosingUntilByKey = state.hashChildClosingUntilByKey || {}
}

function vshookHashAddCandidateKey(list, seen, type, playlistId, identity) {
  const clean = vshookHashClean(identity)
  if (!clean) return
  const key = `${vshookHashChildScope(type, playlistId)}|${clean}`
  if (seen.has(key)) return
  seen.add(key)
  list.push(key)
}

function vshookHashItemCandidateKeys(item, type, playlistId, role) {
  const keys = []
  const seen = new Set()
  if (!item || typeof item !== 'object') return keys

  const add = (value) => vshookHashAddCandidateKey(keys, seen, type, playlistId, value)

  const familyKey = (() => {
    try { return typeof getHashFamilyKeyForAppItem === 'function' ? getHashFamilyKeyForAppItem(item) : '' } catch (_) { return '' }
  })()

  add(familyKey)
  add(item.familyGroupId)
  add(item.family_group_id)
  add(item.familyKey)
  add(item.family_key)
  add(item.parentFamilyGroupId)
  add(item.parent_family_group_id)

  if (role === 'child') {
    add(item.parentId)
    add(item.parent_id)
    add(item.parentSongId)
    add(item.parent_song_id)
    add(item.parentSourceNumber)
    add(item.parent_source_number)
    add(item.parent_region_number)

    const parentNumber = vshookHashClean(item.parentSourceNumber ?? item.parent_source_number ?? item.parent_region_number ?? '')
    const parentStart = vshookHashClean(item.parentStartPos ?? item.parent_start_pos ?? item.parent_region_start_pos ?? '')
    if (parentNumber || parentStart) add(`${parentNumber}|${parentStart}`)

    // Alguns bridges antigos mandam somente source_number/id no filho.
    // Mantém estes candidatos como fallback, sem depender do Lua abrir/fechar filhos.
    add(item.source_number)
    add(item.sourceNumber)
    add(item.number)
    add(item.id)
    add(item.songId)
  } else {
    add(item.id)
    add(item.songId)
    add(item.regionId)
    add(item.source_number)
    add(item.sourceNumber)
    add(item.number)

    const number = vshookHashClean(item.source_number ?? item.sourceNumber ?? item.number ?? '')
    const start = vshookHashClean(item.startPos ?? item.start_pos ?? item.pos ?? item.rgnstart ?? item.regionStart ?? item.region_start ?? '')
    if (number || start) add(`${number}|${start}`)
  }

  return keys
}

function vshookHashParentCandidateKeys(item, type, playlistId) {
  return vshookHashItemCandidateKeys(item, type, playlistId, 'parent')
}

function vshookHashChildCandidateKeys(item, type, playlistId) {
  return vshookHashItemCandidateKeys(item, type, playlistId, 'child')
}

function vshookHashKeysFromElementAndItem(el, type, item) {
  const playlistId = state.activePlaylistId || ''
  const keys = []
  const seen = new Set()
  const addKey = (key) => {
    const clean = vshookHashClean(key)
    if (!clean || seen.has(clean)) return
    seen.add(clean)
    keys.push(clean)
  }

  addKey(vshookHashKeyFromElement(el, type))
  for (const key of vshookHashParentCandidateKeys(item || {}, type === 'song' ? 'song' : 'region', playlistId)) addKey(key)

  if (el) {
    const scope = vshookHashChildScope(type === 'song' ? 'song' : 'region', playlistId)
    const id = type === 'region' ? el.getAttribute('data-region-id') : el.getAttribute('data-song-id')
    const sourceNumber = vshookHashClean(el.getAttribute('data-source-number'))
    const sourceStart = vshookHashClean(el.getAttribute('data-source-start'))
    const familyGroupId = vshookHashClean(el.getAttribute('data-family-group-id'))
    const parentId = vshookHashClean(el.getAttribute('data-parent-id'))
    const addIdentity = (value) => {
      const clean = vshookHashClean(value)
      if (clean) addKey(`${scope}|${clean}`)
    }
    addIdentity(familyGroupId)
    if (sourceNumber || sourceStart) addIdentity(`${sourceNumber}|${sourceStart}`)
    addIdentity(sourceNumber)
    addIdentity(parentId)
    addIdentity(id)
  }

  return keys
}

function vshookPushChildIntoMap(map, key, child) {
  if (!key || !child) return
  if (!map.has(key)) map.set(key, [])
  const list = map.get(key)
  const childId = String(child?.id ?? child?.songId ?? child?.source_number ?? child?.sourceNumber ?? child?.name ?? '')
  const exists = list.some((entry) => String(entry?.id ?? entry?.songId ?? entry?.source_number ?? entry?.sourceNumber ?? entry?.name ?? '') === childId && childId)
  if (!exists) list.push(child)
}

function vshookCacheHashChildrenFromItems(items, type, playlistId) {
  vshookEnsureHashFrontState()
  const incoming = new Map()
  for (const item of Array.isArray(items) ? items : []) {
    if (!isHashChildItem(item)) continue
    for (const key of vshookHashChildCandidateKeys(item, type, playlistId)) {
      if (!key) continue
      if (!incoming.has(key)) incoming.set(key, [])
      incoming.get(key).push({ ...item })
    }
  }
  incoming.forEach((children, key) => {
    if (children.length) state.hashChildCacheByParentKey[key] = children
  })
}

function vshookCacheHashChildrenFromBridgeState() {
  vshookEnsureHashFrontState()
  vshookCacheHashChildrenFromItems(state.regions || [], 'region', '')
  for (const playlist of Array.isArray(state.playlists) ? state.playlists : []) {
    vshookCacheHashChildrenFromItems(playlist?.songs || [], 'song', playlist?.id)
  }
}

function vshookBuildHashChildMap(items, type, playlistId) {
  const map = new Map()
  for (const item of Array.isArray(items) ? items : []) {
    if (!isHashChildItem(item)) continue
    for (const key of vshookHashChildCandidateKeys(item, type, playlistId)) {
      vshookPushChildIntoMap(map, key, item)
    }
  }
  return map
}

function vshookGetHashVisibleChildren(key, bridgeChildMap) {
  vshookEnsureHashFrontState()
  const fromBridge = bridgeChildMap && bridgeChildMap.get(key)
  if (Array.isArray(fromBridge) && fromBridge.length) return fromBridge
  const fromCache = state.hashChildCacheByParentKey[key]
  return Array.isArray(fromCache) ? fromCache : []
}

function vshookIsHashDrawerClosing(key) {
  vshookEnsureHashFrontState()
  return !!(key && Date.now() < Number(state.hashChildClosingUntilByKey[key] || 0))
}

function vshookShouldShowHashChildren(key, bridgeChildMap) {
  vshookEnsureHashFrontState()
  if (!key) return false
  if (vshookIsHashDrawerClosing(key)) return true
  // R/P no App Diretor é local e independente do Lua.
  // Se o Lua estiver aberto/fechado com filhos visíveis, isso não manda no app.
  if (Object.prototype.hasOwnProperty.call(state.hashChildLocalOpenByKey, key)) {
    return state.hashChildLocalOpenByKey[key] === true
  }
  return false
}

function vshookAnyHashKeyOpen(keys, bridgeChildMap) {
  for (const key of Array.isArray(keys) ? keys : []) {
    if (vshookShouldShowHashChildren(key, bridgeChildMap)) return true
  }
  return false
}

function vshookGetChildrenForAnyHashKey(keys, bridgeChildMap) {
  const out = []
  const seen = new Set()
  for (const key of Array.isArray(keys) ? keys : []) {
    const children = vshookGetHashVisibleChildren(key, bridgeChildMap)
    for (const child of Array.isArray(children) ? children : []) {
      const childId = String(child?.id ?? child?.songId ?? child?.source_number ?? child?.sourceNumber ?? child?.name ?? out.length)
      const dedupe = `${key}|${childId}`
      if (seen.has(dedupe)) continue
      seen.add(dedupe)
      out.push(child)
    }
  }
  return out
}

function vshookGetDisplayItemsWithFrontHashChildren(items, type, playlistId) {
  // Long press/RP local removido do App Diretor.
  // O Diretor não expande filhos localmente; mantém apenas itens raiz na lista.
  const source = Array.isArray(items) ? items : []
  return source.filter((item) => !isHashChildItem(item))
}


function vshookToggleHashChildrenFront(el, type) {
  // Desativado por decisão de interface: App Diretor não abre/fecha filhos por toque longo.
  return false
}

function vshookHashChildAnimationClasses(item, type) {
  if (!isHashChildItem(item)) return ''
  vshookEnsureHashFrontState()
  const keys = vshookHashChildCandidateKeys(item, type, state.activePlaylistId || '')
  const now = Date.now()
  const classes = []
  for (const key of keys) {
    if (now < Number(state.hashChildOpeningUntilByKey[key] || 0)) classes.push('hashChildExpandIn')
    if (now < Number(state.hashChildClosingUntilByKey[key] || 0)) classes.push('hashChildCollapseOut')
  }
  return Array.from(new Set(classes)).join(' ')
}

function getVSHookBridgeBaseUrl() {
  try {
    const mode = localStorage.getItem('vshook_selected_mode') || 'director'
    const raw = localStorage.getItem(mode === 'musician' ? 'vshook_musicians_url' : 'vshook_director_url')
    if (raw) return String(raw).replace(/\/+$/, '')
  } catch (error) {}
  return ''
}

function vshookBridgeUrl(path) {
  const base = getVSHookBridgeBaseUrl()
  const cleanPath = String(path || '').startsWith('/') ? String(path || '') : '/' + String(path || '')
  return base ? base + cleanPath : cleanPath
}

function backToVSHookProjectSelector() {
  try {
    localStorage.removeItem('vshook_selected_project')
    localStorage.removeItem('vshook_selected_mode')
    localStorage.removeItem('vshook_director_url')
    localStorage.removeItem('vshook_musicians_url')
  } catch (error) {}
  window.location.reload()
}


function normalizeDirectorLogoutTarget(value) {
  return String(value || '').trim().toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
}

function getDirectorLogoutToken(data) {
  if (!data || typeof data !== 'object') return ''
  const parts = [
    data.directorLogoutToken,
    data.directorLogoutAt,
    data.appLogoutTarget,
    data.logoutTarget,
  ].filter((item) => item !== undefined && item !== null && String(item).trim() !== '')
  if (parts.length) return parts.map((item) => String(item)).join('|')
  return String(data.appLogoutToken || data.logoutToken || data.appLogoutAt || '')
}

function wasDirectorLogoutTokenHandled(token) {
  const value = String(token || '')
  if (!value) return false
  try {
    return localStorage.getItem('vshook_last_director_logout_token') === value
  } catch (error) {
    return false
  }
}

function markDirectorLogoutTokenHandled(token) {
  const value = String(token || '')
  if (!value) return
  try {
    localStorage.setItem('vshook_last_director_logout_token', value)
  } catch (error) {}
}

function bridgeRequestsDirectorLogout(data) {
  if (!data || typeof data !== 'object') return false
  const target = normalizeDirectorLogoutTarget(data.appLogoutTarget || data.logoutTarget || data.target)
  const targetedToDirector = !target || target === 'director' || target === 'diretor'
  if (!targetedToDirector) return false

  return !!(
    data.forceDirectorLogout === true ||
    data.directorLogoutRequested === true ||
    data.logoutDirector === true ||
    ((data.forceAppLogout === true || data.logoutApp === true || data.appLogoutRequested === true) && (target === 'director' || target === 'diretor'))
  )
}

function logoutDirectorToModeSelection(data) {
  if (window.__vshookDirectorLogoutInProgress && (Date.now() - Number(window.__vshookDirectorLogoutStartedAt || 0)) < 1000) return true
  window.__vshookDirectorLogoutStartedAt = Date.now()
  const token = getDirectorLogoutToken(data) || String(Date.now())
  if (token && wasDirectorLogoutTokenHandled(token)) return true
  window.__vshookDirectorLogoutInProgress = true
  markDirectorLogoutTokenHandled(token)

  try { clearAccessSession() } catch (error) {}
  try {
    localStorage.removeItem('vshook_access_session')
    localStorage.setItem('vshook_last_director_logout_at', new Date().toISOString())
  } catch (error) {}

  try {
    state.authAuthenticated = false
    state.authPassInput = ''
    state.authError = ''
    state.authShowPassword = false
  } catch (error) {}

  if (typeof window.vshookExitToProjectSelector === 'function') {
    window.vshookExitToProjectSelector()
  } else {
    window.location.reload()
  }
  return true
}

function registerPwaServiceWorker() {
  if (!('serviceWorker' in navigator)) return
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service-worker.js').catch(() => {})
  }, { once: true })
}


function formatTime(totalSeconds) {
  const safe = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  if (h > 0) return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function formatTotalTime(totalSeconds) {
  const raw = Number(totalSeconds) || 0
  // Mesmo arredondamento do Lua: total bruto correto e arredondamento só no final.
  const safe = Math.max(0, Math.floor(raw + 0.5))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function formatDirectorPlaylistTotalSameAsMusicos(totalSeconds) {
  const raw = Number(totalSeconds) || 0
  const safe = Math.max(0, Math.floor(raw > 1 ? raw - 1 : raw))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}




const BRIDGE_OFFLINE_GRACE_MS = 4500
let bridgePollInFlight = false
let bridgePollSeq = 0
let lastAppliedBridgePollSeq = 0
const playbackLiveState = { id: null, remaining: null }
const DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS = 1800

function parseBridgeStateUpdatedMs(data) {
  if (!data || typeof data !== 'object') return 0
  const candidates = [
    data.heartbeatAt,
    data.lastHeartbeatAt,
    data.updatedAt,
    data.stateUpdatedAt,
    data.serverUpdatedAt,
  ]
  for (const value of candidates) {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    if (value != null && String(value).trim() !== '') {
      const parsed = Date.parse(String(value))
      if (Number.isFinite(parsed)) return parsed
    }
  }
  return 0
}

function getOptimisticPlaybackAgeMs() {
  const started = Number(optimisticPlaybackState?.startedAtMs || 0)
  return started > 0 ? Math.max(0, Date.now() - started) : Number.POSITIVE_INFINITY
}

function shouldHoldDirectorFrontPlayingId(bridgePlayingId) {
  const optimisticId = optimisticPlaybackState?.id ? String(optimisticPlaybackState.id) : ''
  if (!optimisticId || !isOptimisticPlaybackActiveFor?.(optimisticId)) return false
  if (!bridgePlayingId || String(bridgePlayingId) === optimisticId) return true
  return getOptimisticPlaybackAgeMs() < DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS
}


function upperText(value) {
  return String(value ?? '').toLocaleUpperCase('pt-BR')
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function escapeHtmlPreserveSpaces(value) {
  return escapeHtml(value).replace(/ {2,}/g, (match) => '&nbsp;'.repeat(match.length))
}

function safeCssEscape(value) {
  const raw = String(value ?? '')
  if (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') return CSS.escape(raw)
  return raw.replace(/(["\\.#:[\]()=,>+~*^$| ])/g, '\\$1')
}

function buildMarqueeText(text, textClass = '', extraClass = '') {
  const normalized = upperText(text ?? '')
  const source = encodeURIComponent(normalized)
  const safeText = escapeHtml(normalized)
  const safeTextClass = escapeHtml(textClass || '')
  const safeExtraClass = escapeHtml(extraClass || '')
  // Não força letreiro por tamanho de texto.
  // O JS mede a largura real do texto e só duplica/anima quando realmente não couber.
  const shouldForceMarquee = false
  return `<span class="marqueeViewport ${safeExtraClass}" data-marquee data-marquee-source="${source}" data-marquee-text-class="${safeTextClass}" data-marquee-force="${shouldForceMarquee ? '1' : '0'}"><span class="marqueeStatic ${safeTextClass}">${safeText}</span></span>`
}

function buildRowLabelText(text, textClass = '', extraClass = '') {
  const safeText = escapeHtml(upperText(text ?? ''))
  const cls = [textClass, 'rowLabelText', extraClass].filter(Boolean).join(' ')
  return `<span class="${cls}">${safeText}</span>`
}
const TITLE_TICKER_CYCLE_MS = 9000
const PLAYLIST_OPTION_TICKER_CYCLE_MS = 9000

function getTickerPhaseStyle(durationMs) {
  const duration = Math.max(1000, Number(durationMs) || 9000)
  const phase = ((Date.now() - appBootStartedAt) % duration + duration) % duration
  return ` style="animation-delay:-${phase}ms"`
}
function buildTitleTicker(text) {
  const normalized = upperText(text ?? '')
  const safeText = escapeHtml(normalized)
  const needsTicker = normalized.length >= 20
  if (!needsTicker) {
    return `<span class="titleTicker titleTickerStatic"><span class="titleTickerText">${safeText}</span></span>`
  }
  return `<span class="titleTicker titleTickerAnimated"><span class="titleTickerTrack"${getTickerPhaseStyle(TITLE_TICKER_CYCLE_MS)}><span class="titleTickerSegment">${safeText}</span><span class="titleTickerGap">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="titleTickerSegment">${safeText}</span></span></span>`
}


function buildPlaylistOptionTicker(text) {
  const normalized = upperText(text ?? '')
  const safeText = escapeHtml(normalized)
  const needsTicker = normalized.length >= 18
  if (!needsTicker) {
    return `<span class="playlistOptionTicker playlistOptionTickerStatic"><span class="playlistOptionTickerText">${safeText}</span></span>`
  }
  return `<span class="playlistOptionTicker playlistOptionTickerAnimated"><span class="playlistOptionTickerTrack"${getTickerPhaseStyle(PLAYLIST_OPTION_TICKER_CYCLE_MS)}><span class="playlistOptionTickerSegment">${safeText}</span><span class="playlistOptionTickerGap">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="playlistOptionTickerSegment">${safeText}</span></span></span>`
}


function applyMarqueeBehavior() {
  document.querySelectorAll('[data-marquee]').forEach((viewport) => {
    const rawText = decodeURIComponent(viewport.getAttribute('data-marquee-source') || '')
    const textClass = viewport.getAttribute('data-marquee-text-class') || ''
    const safeText = escapeHtml(rawText)
    const classAttr = textClass.trim()

    viewport.classList.remove('is-marquee')
    viewport.innerHTML = `<span class="marqueeStatic ${classAttr}">${safeText}</span><span class="marqueeMeasure ${classAttr}">${safeText}</span>`

    const measure = viewport.querySelector('.marqueeMeasure')
    if (!measure) return

    const viewportWidth = Math.ceil(viewport.clientWidth || viewport.getBoundingClientRect().width || 0)
    if (viewportWidth <= 0) {
      viewport.innerHTML = `<span class="marqueeStatic ${classAttr}">${safeText}</span>`
      return
    }

    const textWidth = Math.ceil(measure.scrollWidth || measure.getBoundingClientRect().width || 0)
    const force = viewport.getAttribute('data-marquee-force') === '1'
    const needs = force || textWidth > viewportWidth + 8

    if (needs) {
      viewport.classList.add('is-marquee')
      const duration = Math.max(8, Math.min(22, Math.round((textWidth / Math.max(1, viewportWidth)) * 7)))
      viewport.style.setProperty('--marquee-duration', `${duration}s`)
      // Mantém um texto invisível para reservar altura, e só duplica o texto quando precisa rolar.
      viewport.innerHTML = `<span class="marqueeStatic ${classAttr}" aria-hidden="true">${safeText}</span><span class="marqueeMeasure ${classAttr}">${safeText}</span><span class="marqueeTrack ${classAttr}"><span class="marqueeSegment">${safeText}</span><span class="marqueeSpacer">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="marqueeSegment">${safeText}</span></span>`
    } else {
      viewport.style.removeProperty('--marquee-duration')
      viewport.innerHTML = `<span class="marqueeStatic ${classAttr}">${safeText}</span>`
    }
  })
}

function scheduleMarqueeBehavior() {
  requestAnimationFrame(() => {
    applyMarqueeBehavior()
    requestAnimationFrame(() => {
      applyMarqueeBehavior()
    })
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

function buildAccessHash(pass) {
  return simpleHash(String(pass ?? '').trim())
}

function getSavedAccessSession() {
  try {
    return localStorage.getItem('vshook_access_session') || ''
  } catch (error) {
    return ''
  }
}

function saveAccessSession(hash) {
  try {
    localStorage.setItem('vshook_access_session', String(hash || ''))
  } catch (error) {}
}

function clearAccessSession() {
  try {
    localStorage.removeItem('vshook_access_session')
  } catch (error) {}
}

function syncAuthStateFromBridge() {
  if (!state.authEnabled || !state.authHash) {
    state.authAuthenticated = true
    state.authError = ''
    state.authShowPassword = false
    return
  }

  const saved = getSavedAccessSession()
  if (saved && saved === state.authHash) {
    state.authAuthenticated = true
    state.authError = ''
  } else {
    state.authAuthenticated = false
    state.authShowPassword = false
    if (saved && saved !== state.authHash) {
      clearAccessSession()
    }
  }
}

function bridgeLooksOffline() {
  // Native Bridge ativo não deve aparecer como OFF só porque o payload veio sem updatedAt legado.
  if (state.nativeBridgeConnected === true) return false
  const updatedAtMs = Number(state.lastBridgeUpdatedAtMs) || 0
  if (!updatedAtMs) return state.bridgeStatus !== 'online'
  return (Date.now() - updatedAtMs) > BRIDGE_OFFLINE_GRACE_MS
}

function needsAuthGate() {
  if (appLoadingVisible) return false
  if (bridgeLooksOffline()) return true
  return !!state.authEnabled && !!state.authHash && !state.authAuthenticated
}


function syncAccessAuthDom(options = {}) {
  const errorEl = document.getElementById('accessAuthError')
  if (errorEl) {
    const message = String(state.authError || '')
    errorEl.textContent = message
    errorEl.style.display = message ? 'block' : 'none'
  }

  const input = document.getElementById('accessPassInput')
  if (input && input.value !== String(state.authPassInput || '')) {
    input.value = String(state.authPassInput || '')
  }

  if (options && options.focus && input) {
    holdAuthBridgeRender(1400)
    window.requestAnimationFrame(() => {
      try { input.focus({ preventScroll: true }) } catch (error) { try { input.focus() } catch (_) {} }
      try {
        const len = String(input.value || '').length
        input.setSelectionRange(len, len)
      } catch (error) {}
    })
  }
}

function focusAccessPassInputSoon() {
  holdAuthBridgeRender(1200)
  window.setTimeout(() => {
    const input = document.getElementById('accessPassInput')
    if (!input) return
    try { input.focus({ preventScroll: true }) } catch (error) { try { input.focus() } catch (_) {} }
  }, 20)
}

function handleAccessLoginSubmit(event) {
  if (event) event.preventDefault()
  const input = document.getElementById('accessPassInput')
  if (input) state.authPassInput = input.value
  const pass = String(state.authPassInput || '').trim()
  const hash = buildAccessHash(pass)

  if (pass && hash === String(state.authHash || '')) {
    state.authAuthenticated = true
    state.authError = ''
    saveAccessSession(hash)
    requestWakeLock(true)
    render()
    return
  }

  state.authAuthenticated = false
  state.authError = 'SENHA INVALIDA'
  // Não re-renderiza a tela de senha no erro. Recriar o input no Android/iOS
  // fecha o teclado e pode fazer ele abrir/fechar a cada caractere.
  syncAccessAuthDom({ focus: true })
}

function handleAccessInputChange() {
  const passEl = document.getElementById('accessPassInput')
  state.authPassInput = passEl ? passEl.value : state.authPassInput
  if (state.authError) {
    state.authError = ''
    syncAccessAuthDom({ focus: false })
  }
}

function toggleAccessPasswordVisibility(event) {
  if (event) {
    event.preventDefault()
    event.stopPropagation()
  }
  state.authShowPassword = false
}


function getLiveRemainingSec(baseRemainingSec) {
  const remaining = Number(baseRemainingSec)
  if (!Number.isFinite(remaining)) return null
  const updatedAtMs = Number(state.lastBridgeUpdatedAtMs) || Date.now()
  const deltaSec = Math.max(0, (Date.now() - updatedAtMs) / 1000)
  return Math.max(0, remaining - deltaSec)
}

function resetPlaybackLiveState(force = false) {
  const currentId = state.playingId != null ? String(state.playingId) : null
  if (force || !currentId) {
    playbackLiveState.id = null
    playbackLiveState.remaining = null
    playbackLiveState.duration = null
    playbackLiveState.anchorAtMs = 0
    playbackLiveState.baseRemaining = null
    return
  }
  if (playbackLiveState.id !== currentId) {
    playbackLiveState.id = currentId
    playbackLiveState.remaining = null
    playbackLiveState.duration = null
    playbackLiveState.anchorAtMs = 0
    playbackLiveState.baseRemaining = null
  }
}

function stabilizeLiveRemaining(itemId, remainingSec, durationSec) {
  const safeRemainingRaw = Number(remainingSec)
  if (!Number.isFinite(safeRemainingRaw)) return remainingSec
  const safeDuration = Math.max(0, Number(durationSec) || 0)
  const currentId = state.playingId != null ? String(state.playingId) : null
  const targetId = itemId != null ? String(itemId) : null
  if (!currentId || targetId !== currentId) return safeRemainingRaw

  let safeRemaining = Math.max(0, safeRemainingRaw)
  const nearStart = safeDuration > 0 && (safeDuration - safeRemaining) <= 0.85

  if (playbackLiveState.id !== currentId || !Number.isFinite(playbackLiveState.baseRemaining)) {
    playbackLiveState.id = currentId
    playbackLiveState.duration = safeDuration > 0 ? safeDuration : null
    playbackLiveState.anchorAtMs = Date.now()
    playbackLiveState.baseRemaining = nearStart && safeDuration > 0 ? safeDuration : safeRemaining
    playbackLiveState.remaining = playbackLiveState.baseRemaining
    return playbackLiveState.remaining
  }

  if (safeDuration > 0) playbackLiveState.duration = safeDuration
  const elapsedSec = Math.max(0, (Date.now() - (Number(playbackLiveState.anchorAtMs) || Date.now())) / 1000)
  const predictedRemaining = Math.max(0, Number(playbackLiveState.baseRemaining) - elapsedSec)
  let stableRemaining = Math.min(
    Number.isFinite(playbackLiveState.remaining) ? playbackLiveState.remaining : safeRemaining,
    safeRemaining,
    predictedRemaining
  )

  if (nearStart && elapsedSec <= 0.35 && safeDuration > 0) {
    stableRemaining = safeDuration
  }

  playbackLiveState.remaining = Math.max(0, stableRemaining)
  return playbackLiveState.remaining
}

function getBridgePlaybackSyncForItem(item) {
  if (!item || typeof item !== 'object') return null
  const playingId = state.playingId != null ? String(state.playingId) : ''
  const itemId = String(item?.id ?? item?.songId ?? item?.source_number ?? item?.sourceNumber ?? '')
  if (!playingId || !itemId || itemId !== playingId) return null

  // Se o Play acabou de sair do front, não aceite remainingSec antigo/zerado
  // do Bridge. Isso era o que fazia a barra abrir cheia e o tempo em 00:00
  // antes do sync real chegar.
  if (isOptimisticPlaybackActiveFor(itemId)) {
    const optimisticStarted = Number(optimisticPlaybackState.startedAtMs) || 0
    const bridgeSyncAt = Number(state.playbackSyncedAtMs) || 0
    if (!bridgeSyncAt || bridgeSyncAt < optimisticStarted) return null
  }

  const duration = Math.max(0, Number(state.playbackDurationSec) || Number(item?.durationSec) || 0)
  const remainingRaw = Number(state.playbackRemainingSec)
  if (!duration || !Number.isFinite(remainingRaw)) return null

  const anchorMs = Number(state.playbackSyncedAtMs) || Number(state.lastBridgeUpdatedAtMs) || Date.now()
  const elapsedSinceBridge = Math.max(0, (Date.now() - anchorMs) / 1000)
  const remaining = Math.max(0, Math.min(duration, remainingRaw - elapsedSinceBridge))
  return { durationSec: duration, remainingSec: remaining }
}

function getPlaybackAwareItem(item, type, isPlaying, isBlock) {
  if (!item || !isPlaying || isBlock || type === 'marker') return item
  const bridgeSync = getBridgePlaybackSyncForItem(item)
  if (bridgeSync) {
    return {
      ...item,
      durationSec: bridgeSync.durationSec,
      remainingSec: bridgeSync.remainingSec,
    }
  }

  const duration = Number(item?.durationSec) || 0
  const remaining = Number(item?.remainingSec)
  const region = findPlayingRegionById(item?.id)
  const sourceDuration = Number(region?.durationSec) || duration || 0

  if (isOptimisticPlaybackActiveFor(item?.id)) {
    const optimisticRemaining = getOptimisticRemainingSec(item?.id, sourceDuration)
    if (Number.isFinite(optimisticRemaining)) {
      return {
        ...item,
        durationSec: sourceDuration || Number(optimisticPlaybackState.durationSec) || duration || 1,
        remainingSec: optimisticRemaining,
      }
    }
  }

  const sourceRemaining = Number.isFinite(remaining)
    ? remaining
    : (Number.isFinite(Number(region?.remainingSec)) ? Number(region.remainingSec) : remaining)
  return {
    ...item,
    durationSec: sourceDuration,
    remainingSec: stabilizeLiveRemaining(item?.id, sourceRemaining, sourceDuration),
  }
}

function getRowProgressRatio(item, isPlaying, isBlock) {
  if (!isPlaying || isBlock) return 0
  const duration = Number(item?.durationSec) || 0
  const remaining = Number(item?.remainingSec)
  if (!duration || !Number.isFinite(remaining)) return 0
  const elapsed = Math.max(0, Math.min(duration, duration - remaining))
  return Math.max(0, Math.min(1, elapsed / duration))
}

function getTimerElapsedSec() {
  const max = 99 * 3600 + 59 * 60 + 59
  const remoteDisplay = Number(state.timerDisplaySec)
  if (Number.isFinite(remoteDisplay) && (state.timerMode === 'countdown' || !state.timerRunning)) {
    return Math.max(0, Math.min(max, Math.floor(remoteDisplay)))
  }
  const base = Math.max(0, Number(state.timerAccumulatedSec) || 0)
  if (!state.timerRunning) return Math.min(base, max)
  const startedAt = Number(state.timerStartedAt) || 0
  const live = startedAt > 0 ? Math.floor((Date.now() - startedAt) / 1000) : 0
  const elapsed = Math.min(base + Math.max(0, live), max)
  if (state.timerMode === 'countdown') {
    const target = Math.max(0, Math.min(max, Number(state.timerTargetSec) || 0))
    return Math.max(0, target - elapsed)
  }
  return elapsed
}

function formatChronoTime(totalSeconds) {
  const safe = Math.max(0, Math.min(99 * 3600 + 59 * 60 + 59, Math.floor(Number(totalSeconds) || 0)))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function syncChronoDisplays() {
  const timerText = formatChronoTime(getTimerElapsedSec())
  document.querySelectorAll('[data-chrono-display]').forEach((node) => {
    if (node.textContent !== timerText) {
      node.textContent = timerText
    }
  })
}

function openTimerModal() {
  // FIX76: cronômetro bloqueado temporariamente para lançamento.
  // O botão continua exibindo o tempo, mas clicar não abre modal nem envia comando.
  state.showTimerModal = false
  return false
}

function closeTimerModal() {
  state.showTimerModal = false
  render()
}

function confirmTimerModal() {
  if (state.timerMode === 'countdown') {
    state.timerTargetSec = readTimerTargetSecondsFromModal()
  }
  const wasRunning = !!state.timerRunning
  const nowMs = Date.now()
  state.timerLocalOwnerUntil = nowMs + 3600000
  postCommand('timer_set_mode', {
    timerMode: state.timerMode,
    mode: state.timerMode,
    timerTargetSec: state.timerTargetSec || 0,
    targetSec: state.timerTargetSec || 0,
    seconds: state.timerTargetSec || 0,
  })
  // FIX6: atualização local imediata. O Lua confirma depois pelo Native Bridge,
  // mas o cronômetro do app não fica parado esperando o próximo state.
  if (wasRunning) {
    state.timerAccumulatedSec = getTimerElapsedSec()
    state.timerDisplaySec = state.timerAccumulatedSec
    state.timerRunning = false
    state.timerStartedAt = 0
    state.timerStartedAtMs = 0
  } else {
    state.timerRunning = true
    state.timerStartedAt = nowMs
    state.timerStartedAtMs = nowMs
    state.timerDisplaySec = state.timerMode === 'countdown' ? (state.timerTargetSec || 0) : (state.timerAccumulatedSec || 0)
  }
  state.showTimerModal = false
  refreshChronoRenderLoop()
  render()
  postCommand('timer_toggle')
}


function setTimerModeFromApp(mode) {
  const next = normalizeDirectorTimerMode(mode)
  if (state.timerMode === 'countdown') {
    state.timerTargetSec = readTimerTargetSecondsFromModal()
  }
  state.timerMode = next
  postCommand('timer_set_mode', {
    timerMode: next,
    mode: next,
    timerTargetSec: state.timerTargetSec || 0,
    targetSec: state.timerTargetSec || 0,
    seconds: state.timerTargetSec || 0,
  })
  render()
}



function getTimerTargetPartsFromSeconds(totalSeconds) {
  const safe = Math.max(0, Math.min(99 * 3600 + 59 * 60 + 59, Math.floor(Number(totalSeconds) || 0)))
  return {
    h: Math.floor(safe / 3600),
    m: Math.floor((safe % 3600) / 60),
    s: safe % 60,
  }
}

function clampTimerPart(value, max) {
  const n = Math.floor(Number(value) || 0)
  return Math.max(0, Math.min(max, n))
}

function readTimerTargetSecondsFromModal() {
  const h = clampTimerPart(document.querySelector('[data-timer-part="h"]')?.value, 99)
  const m = clampTimerPart(document.querySelector('[data-timer-part="m"]')?.value, 59)
  const sec = clampTimerPart(document.querySelector('[data-timer-part="s"]')?.value, 59)
  return Math.max(0, Math.min(99 * 3600 + 59 * 60 + 59, h * 3600 + m * 60 + sec))
}

function syncTimerTargetPreviewFromInputs() {
  if (state.timerMode !== 'countdown') return
  const target = readTimerTargetSecondsFromModal()
  state.timerTargetSec = target
  try {
    if (window.localStorage) window.localStorage.setItem('vshook.director.timer.countdownSec.v1', String(target))
  } catch (error) {}
  const preview = document.querySelector('.timerModalPreview')
  if (preview) preview.textContent = formatChronoTime(target)
}

function handleLiveToggleFromMenu() {
  state.settingsMenuOpen = false
  if (state.liveModeEnabled) {
    state.showLiveOffConfirmModal = true
    render()
    return
  }
  state.liveModeEnabled = true
  postCommand('live_set', { enabled: true, live: true })
  showAppPopup('LIVE LIGADO', 'success', 1200)
  render()
}

function confirmLiveOffFromMenu() {
  state.showLiveOffConfirmModal = false
  state.liveModeEnabled = false
  postCommand('live_set', { enabled: false, live: false })
  showAppPopup('LIVE DESLIGADO', 'marker', 1400)
  render()
}

function cancelLiveOffFromMenu() {
  state.showLiveOffConfirmModal = false
  render()
}

function refreshChronoRenderLoop() {
  try {
    clearInterval(chronoRenderTimer)
  } catch (error) {}
  chronoRenderTimer = null

  if (!state.timerRunning) return

  syncChronoDisplays()
  chronoRenderTimer = setInterval(() => {
    if (!state.timerRunning) {
      try {
        clearInterval(chronoRenderTimer)
      } catch (error) {}
      chronoRenderTimer = null
      syncChronoDisplays()
      return
    }
    syncChronoDisplays()
  }, 250)
}

function detectBlockItem(item) {
  if (!item) return false
  // Bloco precisa vir marcado pelos dados do Lua/bridge.
  // Não usar o nome/label para detectar bloco, porque uma música pode se chamar "Bloco".
  if (item.isBlock === true || item.block === true) return true
  const itemType = String(item.itemType || item.type || item.kind || item.role || '').toLowerCase()
  if (itemType === 'block' || itemType === 'bloco' || itemType === 'song_block' || itemType === 'playlist_block') return true
  const sourceNumber = Number(item.source_number ?? item.sourceNumber)
  if (Number.isFinite(sourceNumber) && sourceNumber < 0) return true
  return false
}

function getBlockFallbackSuffix(item) {
  const numericId = Math.abs(Number(item?.source_number ?? item?.id ?? 1)) || 1
  return String(numericId).padStart(2, '0')
}

function extractBlockSuffix(rawLabel, fallbackSuffix = '01') {
  let text = upperText(rawLabel).trim()
  text = text.replace(/^[=:\-\s]+/, '').replace(/[=:\-\s]+$/, '')
  const match = text.match(/^BLOCO(?:\s+(.*?))?$/i) || text.match(/BLOCO\s+(.+)/i)
  let suffix = (match && match[1] ? match[1] : '').trim()
  if (!suffix) suffix = fallbackSuffix
  return upperText(suffix)
}

function isFormattedAppBlockName(rawLabel) {
  const text = String(rawLabel ?? '').trim()
  if (!text) return false
  return /^[=:]+\s*BLOCO\s+.+\s*[=:]+$/i.test(text) || /^BLOCO\s+.+/i.test(text)
}

function formatAppBlockLabel(item) {
  const rawCandidate = String(item?.blockDisplayName || item?.blockName || item?.name || item?.label || '').trim()
  const customCandidate = String(item?.blockCustomName || '').trim()
  const raw = customCandidate || rawCandidate
  if (customCandidate || item?.isBlockCustomName === true || (raw && !isFormattedAppBlockName(raw))) {
    return upperText(raw)
  }
  const suffix = extractBlockSuffix(raw, getBlockFallbackSuffix(item))
  return `BLOCO ${suffix}`
}

function isHashChildItem(item) {
  return !!(item && (item.isHashChild || item.familyRole === 'child' || item.itemType === 'hash_child' || item.type === 'hash_child'))
}

function isHashParentItem(item) {
  return !!(item && (item.isHashParent || item.familyRole === 'parent' || item.itemType === 'hash_parent' || item.type === 'hash_parent'))
}

function vshookRootFamilyItems(items) {
  return (Array.isArray(items) ? items : []).filter((item) => !isHashChildItem(item))
}

function vshookRawItemDurationSec(item) {
  if (!item) return 0
  const start = Number(item.startPos ?? item.start_pos ?? item.pos ?? item.rgnstart ?? item.regionStart ?? item.region_start ?? 0)
  const end = Number(
    item.endPos
    ?? item.end_pos
    ?? item.rgnend
    ?? item.regionEnd
    ?? item.region_end
    ?? item.fullRegionEndPos
    ?? item.full_region_end_pos
    ?? item.originalRegionEndPos
    ?? item.original_region_end_pos
    ?? start
  )
  if (Number.isFinite(start) && Number.isFinite(end) && end >= start) {
    return Math.max(0, end - start)
  }
  const fallback = Number(item.durationRawSec ?? item.duration_sec_raw ?? item.durationSec ?? item.duration_sec ?? 0)
  return Number.isFinite(fallback) ? Math.max(0, fallback) : 0
}

function vshookSumRootDuration(items) {
  // Igual ao Lua: soma end-start bruto de cada item válido e arredonda só no formatTotalTime.
  // Não soma filhos que estão embaixo do pai, para não duplicar família R/P.
  const list = Array.isArray(items) ? items : []
  let total = 0
  let activeParentFamily = ''
  for (const item of list) {
    if (!item || detectBlockItem(item)) {
      activeParentFamily = ''
      continue
    }
    if (isHashParentItem(item)) {
      activeParentFamily = getHashFamilyKeyForAppItem(item)
      total += vshookRawItemDurationSec(item)
      continue
    }
    if (isHashChildItem(item)) {
      const childFamily = getHashFamilyKeyForAppItem(item)
      if (!childFamily || childFamily !== activeParentFamily) {
        activeParentFamily = ''
        total += vshookRawItemDurationSec(item)
      }
      continue
    }
    activeParentFamily = ''
    total += vshookRawItemDurationSec(item)
  }
  return total
}


function directorFirstFiniteTotalNumber(values) {
  for (const value of values) {
    const n = Number(value)
    if (Number.isFinite(n) && n >= 0) return n
  }
  return null
}

function directorFirstTotalText(values) {
  for (const value of values) {
    const raw = String(value ?? '').trim()
    if (!raw) continue
    const clean = raw.replace(/^total\s*:\s*/i, '').trim()
    if (/^\d{1,3}:\d{2}(?::\d{2})?$/.test(clean)) return clean
  }
  return ''
}

function resolveDirectorPlaylistTotalSeconds(playlist) {
  // Fallback: mesma base visual do Lua, usando start/end bruto e arredondando só no texto final.
  const sourcePlaylist = getDirectorMusicosCompatiblePlaylistForTotal(playlist)
  const songs = Array.isArray(sourcePlaylist?.songs) ? sourcePlaylist.songs : []
  return vshookSumRootDuration(songs)
}

function resolveDirectorPlaylistTotalText(playlist) {
  // Para bater exatamente com o Lua, o App Diretor prioriza o texto pronto enviado pelo Lua/Bridge.
  // Só recalcula como fallback quando o estado ainda não trouxe esse campo.
  const fromStateText = directorFirstTotalText([
    state?.activePlaylistTotalText,
    state?.currentPlaylistTotalText,
    state?.playlistTotalText,
    state?.totalPlaylistText,
    state?.repertorioTotalText,
    state?.repertoryTotalText,
    playlist?.activePlaylistTotalText,
    playlist?.currentPlaylistTotalText,
    playlist?.playlistTotalText,
    playlist?.totalPlaylistText,
    playlist?.repertorioTotalText,
    playlist?.totalText,
    playlist?.durationText,
  ])
  if (fromStateText) return fromStateText
  return formatTotalTime(resolveDirectorPlaylistTotalSeconds(playlist))
}

function resolveDirectorRegionsTotalSeconds() {
  const fromState = directorFirstFiniteTotalNumber([
    state?.regionsTotalSec,
    state?.totalRegionsSec,
    state?.musicasTotalSec,
    state?.musicTotalSec,
    state?.songsTotalSec,
    state?.totalMusicasSec,
  ])
  if (fromState != null) return fromState
  return vshookSumRegionsDuration(state.regions)
}

function resolveDirectorRegionsTotalText() {
  const fromStateText = directorFirstTotalText([
    state?.regionsTotalText,
    state?.totalRegionsText,
    state?.musicasTotalText,
    state?.musicTotalText,
    state?.songsTotalText,
    state?.totalMusicasText,
  ])
  if (fromStateText) return fromStateText
  return formatTotalTime(resolveDirectorRegionsTotalSeconds())
}

function vshookSumRegionsDuration(items) {
  // Igual ao Lua na aba Músicas: filhos R/P não entram no total.
  const list = Array.isArray(items) ? items : []
  return list.reduce((sum, item) => {
    if (!item || detectBlockItem(item) || isHashChildItem(item)) return sum
    return sum + vshookRawItemDurationSec(item)
  }, 0)
}

function vshookIsInternalMarker(item) {
  const raw = String(item?.rawName ?? item?.name ?? item?.label ?? '').trim()
  return raw === '$' || raw === '*1' || raw === '*2' || /^\*\d+$/.test(raw)
}

function getHashFamilyKeyForAppItem(item) {
  if (!item) return ''
  const raw = String(
    item.familyGroupId
    ?? item.family_group_id
    ?? item.familyKey
    ?? item.family_key
    ?? item.parentFamilyGroupId
    ?? item.parent_family_group_id
    ?? ''
  ).trim()
  if (raw) return raw
  const number = item.parentSourceNumber ?? item.parent_source_number ?? item.parent_region_number ?? item.source_number ?? item.sourceNumber ?? item.number ?? ''
  const start = item.parentStartPos ?? item.parent_start_pos ?? item.parent_region_start_pos ?? item.start_pos ?? item.startPos ?? ''
  if (String(number).trim() || String(start).trim()) return `${String(number).trim()}|${String(start).trim()}`
  return ''
}

function areAppItemsSameHashFamily(a, b) {
  const ka = getHashFamilyKeyForAppItem(a)
  const kb = getHashFamilyKeyForAppItem(b)
  return !!ka && !!kb && ka === kb
}

function shouldIgnoreHashChildClickDuringPlayback(item, id) {
  const key = String(id ?? item?.id ?? item?.songId ?? '')
  if (!key) return false
  if (!isHashChildItem(item)) return false
  // Regra nova: filho não entra mais em fila de espera em nenhuma situação.
  // Durante playback, o toque no filho é ignorado sem seleção, sem amarelo e sem popup.
  return !!state.playingId
}

function getAppBridgeBlockColor(item) {
  if (!item) return ''
  const candidates = [
    item.blockColorHex,
    item.block_color_hex,
    item.bridgeBlockColorHex,
    item.luaBlockColorHex,
    item.outlineColorHex,
    item.rowColorHex,
    item.blockColor?.hex,
    item.blockColor,
    item.block_color,
    item.colorHex,
    item.color_hex,
    item.finalTextColorHex,
    item.textColorHex,
    item.inheritedBlockColorHex,
  ]
  for (const value of candidates) {
    if (value && typeof value === 'object') {
      const nested = value.hex || value.colorHex || value.color || value.value || ''
      const nestedColor = String(nested || '').trim()
      if (/^#[0-9a-f]{3,8}$/i.test(nestedColor)) return nestedColor
      if (/^[0-9a-f]{6}$/i.test(nestedColor)) return `#${nestedColor}`
      continue
    }
    const color = String(value || '').trim()
    if (!color) continue
    if (/^#[0-9a-f]{3,8}$/i.test(color)) return color
    if (/^[0-9a-f]{6}$/i.test(color)) return `#${color}`
  }
  return ''
}

function getAppItemTextColor(item, isBlock = false) {
  if (!item) return ''
  if (isBlock) return getAppBridgeBlockColor(item) || item.blockColorHex || item.blockColor?.hex || item.textColorHex || item.finalTextColorHex || ''

  const normalizeColor = (value) => {
    const color = String(value || '').trim()
    if (!color) return ''
    // #334155 é fallback interno escuro do bridge quando não existe bloco acima.
    // Para músicas sem bloco, a cor correta é branca.
    if (color.toLowerCase() === '#334155') return ''
    return color
  }

  return normalizeColor(item.textColorHex)
    || normalizeColor(item.finalTextColorHex)
    || normalizeColor(item.inheritedBlockColorHex)
    || normalizeColor(item.blockColorHex)
    || '#ffffff'
}

function formatHashFamilyLabel(item, label) {
  const clean = upperText(label || item?.name || item?.label || '---')
  if (isHashChildItem(item)) return `├─ ${clean}`
  return clean
}


function mixerColorToCss(color) {
  if (!color) return "#334155"
  const value = String(color).trim()
  if (!value) return "#334155"
  if (value.startsWith("#")) return value
  return `#${value.replace(/^#/, "")}`
}

function getMixerItemsForView(view = state.mixerView) {
  if (view === 'groups') return Array.isArray(state.mixerGroups) ? state.mixerGroups : []
  if (view === 'master') return state.mixerMaster ? [state.mixerMaster] : []
  return Array.isArray(state.mixerTracks) ? state.mixerTracks : []
}

function findMixerItem(view, id) {
  if (view === 'premix') return findPremixTrack(id, state.premixTrackView)
  const target = String(id || '')
  const items = getMixerItemsForView(view)
  return items.find((item) => String(item?.id || '') === target || String(item?.guid || '') === target) || null
}

function normalizeMixerRatio(value, fallback = 0) {
  const num = Number(value)
  if (!Number.isFinite(num)) return fallback
  return Math.max(0, Math.min(1, num))
}

function setMixerItemLocalState(view, id, patch = {}) {
  const targetId = String(id || '')
  if (!targetId) return null
  if (view === 'master') {
    if (!state.mixerMaster) return null
    if (String(state.mixerMaster.id || '') !== targetId && String(state.mixerMaster.guid || '') !== targetId) return null
    state.mixerMaster = { ...state.mixerMaster, ...patch }
    return state.mixerMaster
  }

  const list = getMixerItemsForView(view)
  const idx = list.findIndex((item) => String(item?.id || '') === targetId || String(item?.guid || '') === targetId)
  if (idx < 0) return null
  list[idx] = { ...list[idx], ...patch }
  return list[idx]
}

function beginMixerVolumeInteraction() {
  state.mixerVolumeInteracting = true
  state.mixerVolumeInteractionUntil = Date.now() + 1200
}

function extendMixerVolumeInteraction(ms = 220) {
  state.mixerVolumeInteracting = true
  state.mixerVolumeInteractionUntil = Date.now() + Math.max(120, Number(ms) || 0)
  if (mixerVolumeReleaseTimer) {
    window.clearTimeout(mixerVolumeReleaseTimer)
    mixerVolumeReleaseTimer = 0
  }
  mixerVolumeReleaseTimer = window.setTimeout(() => {
    if (Date.now() >= (state.mixerVolumeInteractionUntil || 0)) {
      state.mixerVolumeInteracting = false
    }
  }, Math.max(140, Number(ms) || 0) + 24)
}

function endMixerVolumeInteraction() {
  state.mixerVolumeInteractionUntil = Date.now() + 160
  extendMixerVolumeInteraction(160)
}

function isMixerDisplayLikelyRatioScale(value, ratioHint = Number.NaN) {
  const num = Number(value)
  if (!Number.isFinite(num)) return false
  if (num < 0 || num > 1.5) return false

  const ratio = Number(ratioHint)
  if (Number.isFinite(ratio)) {
    if (Math.abs(num - ratio) <= 0.35) return true
    if (ratio <= 0.08 && num <= 0.12) return true
    return false
  }

  return true
}

const MIXER_FADER_MIN_DB = -90
const MIXER_FADER_MAX_DB = 12
const MIXER_FADER_ZERO_RATIO = 0.76
const MIXER_FADER_NEGATIVE_CURVE = 1.35

function getMixerZeroDbRatio() {
  return MIXER_FADER_ZERO_RATIO
}

function estimateMixerDisplayValueFromRatio(ratio, fallback = 0, displayScale = '') {
  const safeRatio = normalizeMixerRatio(ratio, Number.NaN)
  if (!Number.isFinite(safeRatio)) return Number.isFinite(Number(fallback)) ? Number(fallback) : 0

  const normalizedScale = displayScale === 'ratio' || displayScale === 'db'
    ? displayScale
    : detectMixerDisplayScale(fallback, safeRatio)

  if (normalizedScale === 'ratio') {
    return Math.round(safeRatio * 100) / 100
  }

  if (safeRatio <= 0) return Number.NEGATIVE_INFINITY

  const minDb = MIXER_FADER_MIN_DB
  const maxDb = MIXER_FADER_MAX_DB
  const zeroRatio = Math.max(0.55, Math.min(0.90, MIXER_FADER_ZERO_RATIO))
  const curve = Math.max(0.20, MIXER_FADER_NEGATIVE_CURVE)
  let db = 0

  if (safeRatio <= zeroRatio) {
    const t = Math.pow(safeRatio / Math.max(0.000001, zeroRatio), 1 / curve)
    db = minDb + (t * (0 - minDb))
  } else {
    db = ((safeRatio - zeroRatio) / Math.max(0.000001, 1 - zeroRatio)) * maxDb
  }

  if (Math.abs(db) < 0.05) db = 0
  return Math.max(minDb, Math.min(maxDb, db))
}

function formatMixerDbLabel(value, ratioHint = Number.NaN, displayScale = '') {
  const ratio = Number(ratioHint)
  const num = Number(value)

  const normalizedScale = displayScale === 'ratio' || displayScale === 'db'
    ? displayScale
    : detectMixerDisplayScale(num, ratioHint)

  if (normalizedScale === 'ratio') {
    const ratioValue = Number.isFinite(num) ? num : (Number.isFinite(ratio) ? ratio : 0)
    const rounded = Math.round(ratioValue * 100) / 100
    return rounded.toFixed(2).replace(/\.00$/, '.0').replace(/(\.\d)0$/, '$1')
  }

  if (Number.isFinite(ratio)) {
    const mappedDb = estimateMixerDisplayValueFromRatio(ratio, Number.isFinite(num) ? num : 0, 'db')
    if (!Number.isFinite(mappedDb)) return '-Inf'
    return `${mappedDb >= 0 ? '+' : ''}${mappedDb.toFixed(1)}`
  }

  if (!Number.isFinite(num)) return '+0.0'
  if (num < -139) return '-Inf'
  const clamped = Math.max(-139, Math.min(12, num))
  return `${clamped >= 0 ? '+' : ''}${clamped.toFixed(1)}`
}

function syncMixerVolumeModalUi(view, id) {
  const item = findMixerItem(view, id)
  if (!item) return
  const modal = document.querySelector('[data-mixer-volume-modal="1"]')
  if (modal) {
    const slider = modal.querySelector('[data-action="mixer-volume-slider"]')
    if (slider && document.activeElement !== slider) slider.value = String(normalizeMixerRatio(item?.volumeRatio, 0.5))
    const dbEl = modal.querySelector('.mixerVolumeDb')
    if (dbEl) dbEl.textContent = formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale)
    const meterFill = modal.querySelector('.mixerMeterFill')
    if (meterFill) meterFill.style.height = `${Math.round(normalizeMixerRatio(item?.peakRatio ?? 0) * 1000) / 10}%`
  }
  const rowDbEl = document.querySelector(`[data-mixer-row-view="${safeCssEscape(String(view || 'tracks'))}"][data-mixer-row-id="${safeCssEscape(String(id || ''))}"] .mixerRowDb`)
  if (rowDbEl) rowDbEl.textContent = formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale)
}

function openMixerModal(defaultView = 'tracks') {
  state.settingsMenuOpen = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showTunerModal = false
  state.showMixerModal = true
  state.showMixerVolumeModal = false
  state.mixerSelectedId = null
  state.mixerView = defaultView === 'groups' ? 'groups' : (defaultView === 'master' ? 'master' : 'tracks')
  armOverlayCloseGuard(650)
  render()
  postCommand('mixer_focus', { view: state.mixerView, page: getCurrentPcPageName() })
  fastPollBridge?.(5)
}

function closeMixerModal(force = false) {
  if (!force && shouldIgnoreOverlayClose()) return
  state.settingsMenuOpen = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.mixerSelectedId = null
  render()
  syncPcBaseViewFromApp()
}

function setMixerView(view) {
  const next = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  if (state.mixerView === next) return
  state.mixerView = next
  render()
  postCommand('mixer_focus', { view: state.mixerView, page: getCurrentPcPageName() })
  fastPollBridge?.(5)
}

function openMixerVolumeModal(view, id) {
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  const item = findMixerItem(normalizedView, id)
  if (!item) return
  rememberMixerDisplayScale(normalizedView, id, item?.db, item?.volumeRatio)
  state.showMixerVolumeModal = true
  state.mixerVolumeView = normalizedView
  state.mixerSelectedId = String(id)
  armOverlayCloseGuard(650)
  render()
  postCommand('mixer_focus', { view: state.mixerVolumeView, id: String(id), targetId: String(id), page: getCurrentPcPageName() })
  fastPollBridge?.(5)
}

function closeMixerVolumeModal(force = false) {
  if (!force && shouldIgnoreOverlayClose()) return
  state.showMixerVolumeModal = false
  state.mixerVolumeInteracting = false
  state.mixerVolumeInteractionUntil = 0
  render()
}

function handleMixerMuteToggle(event, view, id) {
  event.preventDefault()
  event.stopPropagation()
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  const item = findMixerItem(normalizedView, id)
  if (item) {
    const nextMute = !item.mute
    rememberMixerPendingToggle(normalizedView, id, 'mute', nextMute)
    setMixerItemLocalState(normalizedView, id, { mute: nextMute })
    render()
  }
  postCommand('mixer_toggle_mute', { view: normalizedView, id, targetId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(4)
}

function handleMixerSoloToggle(event, view, id) {
  event.preventDefault()
  event.stopPropagation()
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  const item = findMixerItem(normalizedView, id)
  if (item) {
    const nextSolo = !item.solo
    rememberMixerPendingToggle(normalizedView, id, 'solo', nextSolo)
    setMixerItemLocalState(normalizedView, id, { solo: nextSolo })
    render()
  }
  postCommand('mixer_toggle_solo', { view: normalizedView, id, targetId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(4)
}

function handleMixerVolumeInput(view, id, value) {
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  const ratio = normalizeMixerRatio(value)
  const currentItem = findMixerItem(normalizedView, id)
  const displayScale = currentItem?.displayScale || getRememberedMixerDisplayScale(normalizedView, id, currentItem?.db, currentItem?.volumeRatio)

  beginMixerVolumeInteraction()
  setMixerItemLocalState(normalizedView, id, {
    volumeRatio: ratio,
    displayScale,
  })
  syncMixerVolumeModalUi(normalizedView, id)
  extendMixerVolumeInteraction(320)
  postCommand('mixer_set_volume', { view: normalizedView, id, targetId: id, ratio, page: getCurrentPcPageName() })
}

function handleMixerVolumeReset(event, view, id) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  const currentItem = findMixerItem(normalizedView, id)
  const displayScale = currentItem?.displayScale || getRememberedMixerDisplayScale(normalizedView, id, currentItem?.db, currentItem?.volumeRatio)
  const zeroDbRatio = getMixerZeroDbRatio()

  beginMixerVolumeInteraction()
  setMixerItemLocalState(normalizedView, id, {
    volumeRatio: zeroDbRatio,
    db: displayScale === 'db' ? 0 : 1,
    displayScale,
  })
  syncMixerVolumeModalUi(normalizedView, id)
  extendMixerVolumeInteraction(420)
  postCommand('mixer_set_volume', { view: normalizedView, id, targetId: id, ratio: zeroDbRatio, page: getCurrentPcPageName() })
  fastPollBridge?.(4)
}

function buildMixerMeterHtml(ratio) {
  const safe = Math.round(normalizeMixerRatio(ratio) * 1000) / 10
  return `<div class="mixerMeter" aria-hidden="true"><div class="mixerMeterFill" style="height:${safe}%"></div></div>`
}

function renderMixerRows(items, mode) {
  const list = Array.isArray(items) ? items : []
  if (!list.length) {
    return '<div class="emptyBox">SEM ITENS NO MIXER</div>'
  }

  return list.map((item) => {
    const color = mixerColorToCss(item?.colorHex || item?.groupColorHex || item?.color || '')
    const indexText = mode === 'master' ? 'M' : String(item?.index ?? '').padStart(2, '0')
    const id = escapeHtml(String(item?.id || item?.guid || ''))
    const defaultLabel = mode === 'groups' ? `GRUPO ${indexText}` : (mode === 'master' ? 'MASTER' : `TRACK ${indexText}`)
    const name = buildMarqueeText(item?.name || defaultLabel, '', 'rowMarquee mixerNameMarquee')
    const groupName = mode === 'tracks' && item?.groupName ? `<div class="mixerRowGroupName">${buildMarqueeText(item.groupName, '', 'rowMarquee mixerGroupMarquee')}</div>` : ''
    const muteClass = item?.mute ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn'
    const soloClass = item?.solo ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn'
    return `<div class="mixerRow" style="--mixer-color:${color}" data-action="open-mixer-volume" data-mixer-view="${mode}" data-mixer-id="${id}" data-mixer-row-view="${mode}" data-mixer-row-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">${escapeHtml(indexText)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div>${groupName}</div><div class="mixerRowDb">${escapeHtml(formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale))}</div>${buildMixerMeterHtml(item?.peakRatio ?? 0)}<button class="${muteClass}" data-action="mixer-mute" data-mixer-view="${mode}" data-mixer-id="${id}">M</button><button class="${soloClass}" data-action="mixer-solo" data-mixer-view="${mode}" data-mixer-id="${id}">S</button></div>`
  }).join('')
}


function handleMixerRowOpenFromElement(el, event) {
  if (!el) return
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (event?.target?.closest && event.target.closest('[data-action="mixer-mute"], [data-action="mixer-solo"], .mixerVolumeSlider, button, input')) return
  openMixerVolumeModal(el.getAttribute('data-mixer-view'), el.getAttribute('data-mixer-id'))
}

function renderMixerVolumeModal() {
  if (!state.showMixerVolumeModal || !state.mixerSelectedId) return ''
  const item = findMixerItem(state.mixerVolumeView, state.mixerSelectedId)
  if (!item) return ''
  const color = mixerColorToCss(item?.colorHex || item?.groupColorHex || item?.color || '')
  const ratio = normalizeMixerRatio(item?.volumeRatio, 0.5)
  const meterHtml = buildMixerMeterHtml(item?.peakRatio ?? 0)
  return `<div class="modalOverlay mixerVolumeOverlay" data-close-mixer-volume style="z-index:2600"><div class="modalSpacer"></div><div class="modalBox mixerVolumeModalBox" data-stop-modal data-mixer-volume-modal="1" style="position:relative;z-index:2601;max-height:min(72vh,520px);overflow:hidden"><div class="mixerModalHeader"><div class="modalTitle">VOLUME</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-mixer-volume">FECHAR</button></div><div class="mixerVolumeTitle" style="--mixer-color:${color};display:flex;align-items:center;justify-content:space-between;gap:10px"><span style="min-width:0;overflow:hidden;white-space:nowrap;display:block;flex:1 1 auto">${buildMarqueeText(item?.name || 'MIXER', '', 'rowMarquee mixerNameMarquee')}</span><button class="modalCancelBtn" data-action="mixer-volume-reset" style="min-width:88px;height:36px;background:#facc15;color:#111827;border:1px solid #facc15;flex:0 0 auto">RESET</button></div><div class="mixerVolumeMeterWrap">${meterHtml}<div class="mixerVolumeDb">${escapeHtml(formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale))}</div></div><input class="mixerVolumeSlider" type="range" min="0" max="1" step="0.01" value="${ratio}" data-action="mixer-volume-slider" data-mixer-view="${escapeHtml(state.mixerVolumeView)}" data-mixer-id="${escapeHtml(String(state.mixerSelectedId))}" /></div><div class="modalBottomSpace"></div></div>`
}

function renderMixerModal() {
  if (!state.showMixerModal) return ''
  const isTracks = state.mixerView === 'tracks'
  const isGroups = state.mixerView === 'groups'
  const isMaster = state.mixerView === 'master'
  const title = isMaster ? 'MASTER' : (isGroups ? 'GRUPOS' : 'TRACKS')
  const rowsHtml = isMaster
    ? renderMixerRows(state.mixerMaster ? [state.mixerMaster] : [], 'master')
    : (isGroups ? renderMixerRows(state.mixerGroups, 'groups') : renderMixerRows(state.mixerTracks, 'tracks'))
  return `<div class="modalOverlay mixerOverlay" data-close-mixer style="z-index:2200;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox mixerModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;border-radius:0"><div class="mixerModalHeader"><div class="modalTitle">MIXER</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-mixer">FECHAR</button></div><div class="mixerViewTabs mixerViewTabsTriple"><button class="${isTracks ? 'btnPlayActive' : 'btn'}" data-action="mixer-view-tracks">TRACKS</button><button class="${isGroups ? 'btnPlayActive' : 'btn'}" data-action="mixer-view-groups">GRUPOS</button><button class="${isMaster ? 'btnPlayActive' : 'btn'}" data-action="mixer-view-master">MASTER</button></div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">${title}</div><div class="mixerRowsBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;touch-action:pan-y;padding-right:2px">${rowsHtml}</div></div></div></div>`
}


function getActivePlaylistSongsForPremix() {
  const playlists = Array.isArray(state.playlists) ? state.playlists : []
  if (!playlists.length) return []
  const activeId = String(state.activePlaylistId || '')
  const playlist = playlists.find((entry) => String(entry?.id || '') === activeId) || playlists[0]
  return Array.isArray(playlist?.songs) ? playlist.songs : []
}

function isPremixSelectableSong(song) {
  if (!song) return false
  if (detectBlockItem(song)) return false
  if (song.isPlayable === false) return false
  const id = String(song?.id || song?.source_number || song?.sourceNumber || '')
  return id !== ''
}

function getPremixSongs() {
  // PREMIX no Diretor lista TODAS as músicas da aba Músicas do Lua.
  const source = Array.isArray(state.premixSongs) && state.premixSongs.length ? state.premixSongs : state.regions
  if (!Array.isArray(source)) return []
  return source.filter((song) => !detectBlockItem(song))
}

function getFirstSelectablePremixSong() {
  return getPremixSongs().find((song) => isPremixSelectableSong(song)) || null
}


const PREMIX_GLOBAL_ID = '__GLOBAL_PREMIX__'

function getPremixEntityId() {
  return isPremixGlobalMode() ? PREMIX_GLOBAL_ID : String(state.premixSelectedSongId || '')
}

function isPremixGlobalMode() {
  return state.premixIsGlobal === true || String(state.premixSelectedSongId || '') === PREMIX_GLOBAL_ID
}

function getPremixOnState() {
  return isPremixGlobalMode() ? !!state.premixGlobalEnabled : !!state.premixSelectedEnabled
}

function getPremixOnLabel() {
  return isPremixGlobalMode() ? 'GLOBAL' : 'PREMIX'
}

function isUsablePlaybackId(value) {
  if (value === undefined || value === null) return false
  const key = String(value).trim()
  if (!key) return false
  if (key === 'true' || key === 'false' || key === 'undefined' || key === 'null') return false
  return true
}

function getCurrentPremixPlayingId() {
  const candidates = []
  if (isPlaybackPending && isPlaybackPending() && pendingPlaybackDesiredPlaying === true) {
    candidates.push(pendingPlaybackDesiredSourceId)
  }
  if (optimisticPlaybackState?.id && isOptimisticPlaybackActiveFor?.(optimisticPlaybackState.id)) {
    candidates.push(optimisticPlaybackState.id)
  }
  candidates.push(state.playingId)
  if (typeof lastPlaybackSelectionId !== 'undefined' && getPlaybackUiActive?.()) candidates.push(lastPlaybackSelectionId)

  for (const candidate of candidates) {
    if (isUsablePlaybackId(candidate)) return String(candidate)
  }
  return ''
}

function isPremixSongActuallyPlaying(songId = state.premixSelectedSongId) {
  if (isPremixGlobalMode()) return true
  const target = String(songId || '')
  if (!target) return false

  if (isPlaybackPending?.() && pendingPlaybackDesiredPlaying === true && String(pendingPlaybackDesiredSourceId || '') === target) return true
  if (optimisticPlaybackState?.id && String(optimisticPlaybackState.id) === target && isOptimisticPlaybackActiveFor?.(target)) return true

  const playing = getCurrentPremixPlayingId()
  const playbackActive = typeof getPlaybackUiActive === 'function' ? getPlaybackUiActive() : !!playing
  if (playbackActive && playing && String(playing) === target) return true

  // Fallback do Bridge: depois do Play pelo Premix, o JSON pode confirmar que está
  // tocando antes de normalizar o playingId. Se o Lua já marcou selectedPlaying,
  // libera o ON/OFF da própria música selecionada.
  if (String(state.premixSelectedSongId || '') === target && state.premixSelectedPlaying === true) return true
  if (String(state.premixSelectedSongId || '') === target && state.premixSelectedCanEdit === true) return true

  return false
}

function getPremixSongOpenBlockMessage(songId) {
  const target = String(songId || '')
  const playing = getCurrentPremixPlayingId()
  const playbackActive = typeof getPlaybackUiActive === 'function' ? getPlaybackUiActive() : !!playing
  if (playbackActive && isUsablePlaybackId(playing) && target && String(playing) !== target) return 'PARE A MÚSICA ATUAL PRIMEIRO'
  return 'DÊ PLAY NA MÚSICA PRIMEIRO'
}

function canEditCurrentPremix(showMessage = true) {
  if (!isPremixGlobalMode() && !isPremixSongActuallyPlaying(state.premixSelectedSongId)) {
    if (showMessage) showAppPopup(getPremixSongOpenBlockMessage(state.premixSelectedSongId), 'error', 1700)
    return false
  }

  // Igual ao Lua: o Premix individual NAO precisa estar ON para editar pistas.
  // O ON/OFF só define se o preset será aplicado no Play, não bloqueia M/S/F/fader.
  return true
}

function canOpenPremixSong(songId, showMessage = true) {
  const target = String(songId || '')
  if (!target) return false
  if (isPremixSongActuallyPlaying(target)) return true
  if (showMessage) showAppPopup(getPremixSongOpenBlockMessage(target), 'error', 1700)
  return false
}

function normalizePremixTrackItem(item, view = 'tracks') {
  return decorateMixerIncomingItem('premix', {
    ...item,
    phase: item?.phase === true,
    premixView: view === 'groups' ? 'groups' : 'tracks',
  })
}

function getPremixItemsForView(view = state.premixTrackView) {
  const normalizedView = view === 'groups' ? 'groups' : 'tracks'
  const useGlobal = isPremixGlobalMode()
  const premixSource = normalizedView === 'groups'
    ? (useGlobal ? state.premixGlobalGroups : state.premixGroups)
    : (useGlobal ? state.premixGlobalTracks : state.premixTracks)
  if (Array.isArray(premixSource) && premixSource.length) return premixSource.filter(Boolean)

  const fallbackSource = normalizedView === 'groups' ? state.mixerGroups : state.mixerTracks
  return (Array.isArray(fallbackSource) ? fallbackSource : []).filter(Boolean).map((item) => normalizePremixTrackItem(item, normalizedView))
}

function getPremixTracks() {
  return getPremixItemsForView('tracks')
}

function findPremixTrack(id, view = state.premixTrackView) {
  const wanted = String(id || '')
  if (!wanted) return null
  const views = view === 'groups' ? ['groups', 'tracks'] : ['tracks', 'groups']
  for (const currentView of views) {
    const item = getPremixItemsForView(currentView).find((entry) => String(entry?.id || entry?.guid || '') === wanted)
    if (item) return item
  }
  return null
}

function setPremixTrackLocalState(id, patch = {}, view = state.premixTrackView) {
  const wanted = String(id || '')
  if (!wanted) return
  const applyPatch = (list) => (Array.isArray(list) ? list : []).map((item) => {
    const key = String(item?.id || item?.guid || '')
    return key === wanted ? { ...item, ...patch } : item
  })

  if (isPremixGlobalMode()) {
    if (view === 'groups') {
      state.premixGlobalGroups = applyPatch(getPremixItemsForView('groups'))
    } else {
      state.premixGlobalTracks = applyPatch(getPremixItemsForView('tracks'))
    }
    state.premixGlobalTracks = applyPatch(state.premixGlobalTracks)
    state.premixGlobalGroups = applyPatch(state.premixGlobalGroups)
    return
  }

  if (view === 'groups') {
    state.premixGroups = applyPatch(getPremixItemsForView('groups'))
  } else {
    state.premixTracks = applyPatch(getPremixItemsForView('tracks'))
  }

  // Se a mesma GUID aparecer em outra lista, mantém o cache visual coerente.
  state.premixTracks = applyPatch(state.premixTracks)
  state.premixGroups = applyPatch(state.premixGroups)
}

function openPremixModal() {
  state.settingsMenuOpen = false
  state.showGearModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showPremixVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showPremixModal = true
  state.premixIsGlobal = false
  state.premixView = 'songs'
  state.premixTrackView = 'tracks'
  state.premixSelectedTrackId = null

  try {
    const songs = getPremixSongs()
    const selectedStillExists = songs.some((song) => String(song?.id || song?.source_number || song?.sourceNumber || '') === String(state.premixSelectedSongId || ''))
    if (!selectedStillExists || String(state.premixSelectedSongId || '') === PREMIX_GLOBAL_ID) state.premixSelectedSongId = null
  } catch (error) {
    state.premixSelectedSongId = null
  }

  armOverlayCloseGuard(900)
  render()
  fastPollBridge?.(8)
}

function openPremixFromMenu(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  event?.stopImmediatePropagation?.()
  openPremixModal()
  return true
}


function openPremixGlobalModal(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  event?.stopImmediatePropagation?.()
  state.settingsMenuOpen = false
  state.showGearModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showPremixVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showPremixModal = true
  state.premixIsGlobal = true
  state.premixSelectedSongId = PREMIX_GLOBAL_ID
  state.premixSelectedTrackId = null
  state.premixView = 'tracks'
  state.premixTrackView = 'tracks'
  state.premixSelectedEnabled = !!state.premixGlobalEnabled
  armOverlayCloseGuard(900)
  render()
  postCommand('premix_global_focus', { id: PREMIX_GLOBAL_ID, songId: PREMIX_GLOBAL_ID, global: true, isGlobal: true, page: getCurrentPcPageName() })
  fastPollBridge?.(12)
}

function bindPremixGlobalMenuButton(el) {
  if (!el) return
  let lastRunAt = 0
  const run = (event) => {
    const now = Date.now()
    if (now - lastRunAt < 90) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      event?.stopImmediatePropagation?.()
      return
    }
    lastRunAt = now
    openPremixGlobalModal(event)
  }
  el.addEventListener('touchend', run, { passive: false })
  el.addEventListener('click', run)
}

function bindPremixMenuButton(el) {
  if (!el) return
  let lastRunAt = 0
  const run = (event) => {
    const now = Date.now()
    if (now - lastRunAt < 90) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      event?.stopImmediatePropagation?.()
      return
    }
    lastRunAt = now
    openPremixFromMenu(event)
  }
  el.addEventListener('touchend', run, { passive: false })
  el.addEventListener('click', run)
}

function closePremixModal(force = false) {
  if (!force && shouldIgnoreOverlayClose()) return
  state.showPremixModal = false
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
  syncPcBaseViewFromApp()
}

function selectPremixSong(songId) {
  const id = String(songId || '')
  if (!id) return
  const song = getPremixSongs().find((entry) => String(entry?.id || entry?.source_number || entry?.sourceNumber || '') === id)
  if (!isPremixSelectableSong(song)) return

  // Se já existe outra música tocando, o Diretor não entra na tela de pistas
  // dessa música. Se não estiver tocando nada, pode abrir e só bloqueia ao
  // tentar mexer nas pistas, igual ficou definido.
  const currentPremixPlayingId = getCurrentPremixPlayingId()
  const playbackActiveForPremix = typeof getPlaybackUiActive === 'function' ? getPlaybackUiActive() : !!currentPremixPlayingId
  if (playbackActiveForPremix && currentPremixPlayingId && String(currentPremixPlayingId) !== id) {
    showAppPopup('PARE A MÚSICA ATUAL PRIMEIRO', 'error', 1700)
    return
  }

  state.premixIsGlobal = false
  state.premixSelectedSongId = id
  state.selectedRegionId = id
  state.selectedRegionIds = [id]
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.premixSelectedTrackId = null
  state.showPremixVolumeModal = false

  const enabled = song?.premixEnabled ?? song?.preMixEnabled ?? song?.onOff
  if (enabled !== undefined) state.premixSelectedEnabled = !!enabled

  // Igual ao Lua: escolher a música dentro do Premix só seleciona/posiciona
  // e já abre a tela de pistas. A exigência de Play acontece apenas quando
  // o usuário tenta mexer em M/S/F/fader.
  state.premixView = 'tracks'
  state.premixTrackView = 'tracks'

  const fallbackTracks = Array.isArray(state.mixerTracks) ? state.mixerTracks : []
  const fallbackGroups = Array.isArray(state.mixerGroups) ? state.mixerGroups : []
  state.premixTracks = fallbackTracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
  state.premixGroups = fallbackGroups.map((item) => normalizePremixTrackItem(item, 'groups'))

  render()
  postCommand('premix_focus_song', { id, songId: id, selectedRegionId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(12)
}

function backPremixSongList() {
  if (isPremixGlobalMode()) return closePremixModal(true)
  state.premixView = 'songs'
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
}

function setPremixTrackView(view) {
  const next = view === 'groups' ? 'groups' : 'tracks'
  if (state.premixTrackView === next) return
  state.premixTrackView = next
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
  if (isPremixGlobalMode()) {
    postCommand('premix_global_focus', { id: PREMIX_GLOBAL_ID, songId: PREMIX_GLOBAL_ID, global: true, isGlobal: true, view: next, page: getCurrentPcPageName() })
  } else {
    const songId = String(state.premixSelectedSongId || '')
    if (songId) postCommand('premix_focus_song', { id: songId, songId, selectedRegionId: songId, view: next, page: getCurrentPcPageName() })
  }
  fastPollBridge?.(8)
}

function handlePremixOnOffToggle(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()

  if (isPremixGlobalMode()) {
    const nextEnabled = !state.premixGlobalEnabled
    state.premixGlobalEnabled = nextEnabled
    state.premixSelectedEnabled = nextEnabled
    render()
    postCommand('premix_global_toggle_enabled', { id: PREMIX_GLOBAL_ID, songId: PREMIX_GLOBAL_ID, global: true, isGlobal: true, page: getCurrentPcPageName() })
    fastPollBridge?.(8)
    return
  }

  const songId = String(state.premixSelectedSongId || '')
  if (!songId) return

  // ON/OFF do Premix nao deve bloquear pelo estado de playback no app.
  // O Lua continua sendo a fonte de verdade; aqui evitamos falso aviso de "pare a musica".
  const nextEnabled = !state.premixSelectedEnabled
  state.premixSelectedEnabled = nextEnabled
  state.premixSongs = (Array.isArray(state.premixSongs) ? state.premixSongs : []).map((song) => {
    const id = String(song?.id || song?.source_number || song?.sourceNumber || '')
    return id === songId ? { ...song, premixEnabled: nextEnabled, preMixEnabled: nextEnabled, onOff: nextEnabled } : song
  })
  render()
  postCommand('premix_toggle_enabled', { id: songId, songId, selectedRegionId: songId, page: getCurrentPcPageName() })
  fastPollBridge?.(8)
}


function resetPremixGlobalLocalVolumes() {
  const resetList = (list) => (Array.isArray(list) ? list : []).map((item) => {
    const displayScale = item?.displayScale || getRememberedMixerDisplayScale('premix', item?.id || item?.guid || '', item?.db, item?.volumeRatio)
    return {
      ...item,
      volumeRatio: getMixerZeroDbRatio(),
      db: displayScale === 'linear' ? 1 : 0,
      displayScale,
    }
  })
  state.premixGlobalTracks = resetList(getPremixItemsForView('tracks'))
  state.premixGlobalGroups = resetList(getPremixItemsForView('groups'))
}

function handlePremixGlobalReset(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (!isPremixGlobalMode()) return
  const confirmed = window.confirm('Resetar todas as pistas do Global para 0 dB?')
  if (!confirmed) return
  resetPremixGlobalLocalVolumes()
  render()
  postCommand('premix_global_reset_0db', { id: PREMIX_GLOBAL_ID, songId: PREMIX_GLOBAL_ID, global: true, isGlobal: true, page: getCurrentPcPageName() })
  fastPollBridge?.(8)
}

// PREMIX_DIRECTOR_CONTROLLER_ONLY_20260627:
// O app Diretor não possui preset próprio. Ele só envia comandos unitários
// para o Lua, e o Lua é quem salva/aplica o mesmo preset usado na janela Premix.
function handlePremixTrackToggle(event, action, trackId, view = state.premixTrackView) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  if (!canEditCurrentPremix(true)) return
  const normalizedView = view === 'groups' ? 'groups' : 'tracks'
  const item = findPremixTrack(id, normalizedView)
  if (item) {
    if (action === 'mute') setPremixTrackLocalState(id, { mute: !item.mute }, normalizedView)
    if (action === 'solo') setPremixTrackLocalState(id, { solo: !item.solo }, normalizedView)
    if (action === 'phase') setPremixTrackLocalState(id, { phase: !item.phase }, normalizedView)
  }
  render()
  const prefix = isPremixGlobalMode() ? 'premix_global_' : 'premix_'
  const command = prefix + (action === 'phase' ? 'toggle_phase' : (action === 'solo' ? 'toggle_solo' : 'toggle_mute'))
  postCommand(command, { id: songId, songId, selectedRegionId: songId, targetId: id, trackId: id, view: normalizedView, trackView: normalizedView, global: isPremixGlobalMode(), isGlobal: isPremixGlobalMode(), page: getCurrentPcPageName() })
  fastPollBridge?.(8)
}

function openPremixVolumeModal(view, id) {
  if (!canEditCurrentPremix(true)) return
  const normalizedView = view === 'groups' ? 'groups' : 'tracks'
  const item = findPremixTrack(id, normalizedView)
  if (!item) return
  rememberMixerDisplayScale('premix', id, item?.db, item?.volumeRatio)
  state.showPremixVolumeModal = true
  state.premixTrackView = normalizedView
  state.premixSelectedTrackId = String(id)
  armOverlayCloseGuard(650)
  render()
}

function closePremixVolumeModal(force = false) {
  if (!force && shouldIgnoreOverlayClose()) return
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
}

function handlePremixRowOpenFromElement(el, event) {
  if (!el) return
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (event?.target?.closest && event.target.closest('[data-action="premix-mute"], [data-action="premix-solo"], [data-action="premix-phase"], button, input')) return
  openPremixVolumeModal(el.getAttribute('data-premix-view'), el.getAttribute('data-premix-track-id'))
}

function handlePremixVolumeInput(view, trackId, value) {
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  if (!canEditCurrentPremix(true)) return
  const normalizedView = view === 'groups' ? 'groups' : 'tracks'
  const ratio = normalizeMixerRatio(value, 0.5)
  const item = findPremixTrack(id, normalizedView)
  const displayScale = item?.displayScale || getRememberedMixerDisplayScale('premix', id, item?.db, item?.volumeRatio)

  beginMixerVolumeInteraction()
  setPremixTrackLocalState(id, {
    volumeRatio: ratio,
    displayScale,
  }, normalizedView)
  try { syncMixerVolumeModalUi('premix', id) } catch (error) {}
  extendMixerVolumeInteraction(320)
  const command = isPremixGlobalMode() ? 'premix_global_set_volume' : 'premix_set_volume'
  postCommand(command, { id: songId, songId, selectedRegionId: songId, targetId: id, trackId: id, ratio, view: normalizedView, trackView: normalizedView, global: isPremixGlobalMode(), isGlobal: isPremixGlobalMode(), page: getCurrentPcPageName() })
}

function handlePremixVolumeReset(event, view, trackId) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const id = String(trackId || '')
  const normalizedView = view === 'groups' ? 'groups' : 'tracks'
  const item = findPremixTrack(id, normalizedView)
  const displayScale = item?.displayScale || getRememberedMixerDisplayScale('premix', id, item?.db, item?.volumeRatio)
  beginMixerVolumeInteraction()
  setPremixTrackLocalState(id, {
    volumeRatio: getMixerZeroDbRatio(),
    db: displayScale === 'linear' ? 1 : 0,
    displayScale,
  }, normalizedView)
  try { syncMixerVolumeModalUi('premix', id) } catch (error) {}
  extendMixerVolumeInteraction(420)
  handlePremixVolumeInput(view, trackId, getMixerZeroDbRatio())
  fastPollBridge?.(4)
  render()
}


function handlePremixPlaySelected(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (isPremixGlobalMode()) return
  const songId = String(state.premixSelectedSongId || '')
  if (!songId) return

  const uiWasPlaying = getPlaybackUiActive()
  if (uiWasPlaying) {
    const stoppedId = state.playingId || songId || lastPlaybackSelectionId || pendingPlaybackDesiredSourceId
    const stopSelectionTarget = getDirectorStopSelectionTarget(stoppedId, 'regions')
    const hasRealStopSelectionTarget = !!(stopSelectionTarget && stopSelectionTarget.id && stopSelectionTarget.source && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(stoppedId || ''))
    postPlaybackToggleCommand(stoppedId, 'regions', false, hasRealStopSelectionTarget ? { stopSelectionTargetId: stopSelectionTarget.id, stopSelectionTargetTab: stopSelectionTarget.tab, stopSelectionTargetSource: stopSelectionTarget.source } : null)
    if (hasRealStopSelectionTarget) {
      applyStoppedSongSelection(stopSelectionTarget.id, stopSelectionTarget.tab)
    } else {
      // Sem fila, o Diretor seleciona imediatamente a própria música parada.
      // Não espera o Bridge devolver selectedId, evitando atraso visual no azul.
      applyStoppedSongSelection(stoppedId, 'regions')
    }
    state.pendingStopClear = false
    state.loopActive = false
    state.bridgePopupVisible = false
    state.bridgePopupText = ''
    state.bridgePopupError = false
    state.bridgePopupPersistent = false
    state.appPopupVisible = false
    state.playingId = null
    pendingPlaybackToggleAt = Date.now()
    pendingPlaybackDesiredPlaying = false
    pendingPlaybackDesiredSourceId = null
    pendingPlaybackDesiredSourceTab = 'regions'
    clearOptimisticPlayback()
    resetPlaybackLiveState(true)
    lockSelectionSync()
    render()
    if (stopSelectionTarget && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(stoppedId || '')) {
      forceStoppedSelectionDom(stopSelectionTarget.id, stopSelectionTarget.tab)
    } else if (stoppedId) {
      forceStoppedSelectionDom(stoppedId, 'regions')
    }
    return
  }

  state.selectedRegionId = songId
  state.selectedRegionIds = [songId]
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.premixIsGlobal = false
  state.premixView = 'tracks'
  state.premixTrackView = 'tracks'
  state.premixSelectedTrackId = null
  state.showPremixVolumeModal = false
  pendingPlaybackToggleAt = Date.now()
  pendingPlaybackDesiredPlaying = true
  pendingPlaybackDesiredSourceId = songId
  pendingPlaybackDesiredSourceTab = 'regions'
  showLocalPlaybackPopupForId(songId)
  postPlaybackToggleCommand(songId, 'regions', true)
  startOptimisticPlayback(songId, 'regions')
  lockSelectionSync()
  render()
  fastPollBridge?.(10)
}

function renderPremixSongRows() {
  const songs = getPremixSongs()
  if (!songs.length) return '<div class="emptyBox">SEM MÚSICAS</div>'
  return songs.map((song) => {
    const id = String(song?.id || song?.source_number || song?.sourceNumber || '')
    const isBlock = detectBlockItem(song)
    const selected = id && String(state.premixSelectedSongId || '') === id
    const playing = id && String(getCurrentPremixPlayingId() || '') === id
    const title = song?.name || song?.label || song?.title || song?.displayName || song?.sourceName || song?.source_name || song?.regionName || song?.songName || (isBlock ? 'DIVISÃO' : `MÚSICA ${id || ''}`)
    const name = buildMarqueeText(title, 'premixSongTitleText', 'rowMarquee premixSongMarquee')
    const duration = (!isBlock && song?.durationSec) ? `<span class="premixSongDuration">${escapeHtml(formatTime(song.durationSec))}</span>` : ''
    const enabled = !!(song?.premixEnabled ?? song?.preMixEnabled ?? song?.onOff)
    const status = !isBlock ? `<span class="premixSongStatus ${enabled ? 'premixSongStatusOn' : 'premixSongStatusOff'}">${enabled ? 'ON' : 'OFF'}</span>` : ''
    const color = getAppItemTextColor(song)
    const style = color ? ` style="--premix-row-color:${escapeHtml(color)}"` : ''
    if (isBlock) {
      return `<div class="itemRow blockItem premixBlockRow"${style}><div class="leftCol">${name}</div>${duration}</div>`
    }
    return `<div class="premixSongCard ${selected ? 'premixSongCardSelected selectedRow' : ''} ${playing ? 'premixSongCardPlaying' : ''}"${style} data-action="premix-song" data-premix-song-id="${escapeHtml(id)}"><div class="premixSongAccent"></div><div class="premixSongMain"><div class="premixSongTitle">${name}</div><div class="premixSongMeta">${status}${duration}</div></div><div class="premixSongPlayingBar" aria-hidden="true"></div></div>`
  }).join('')
}

function renderPremixTrackRows() {
  const view = state.premixTrackView === 'groups' ? 'groups' : 'tracks'
  const tracks = getPremixItemsForView(view)
  const canEdit = canEditCurrentPremix(false)
  if (!tracks.length) return `<div class="emptyBox">SEM ${view === 'groups' ? 'GRUPOS' : 'PISTAS'} NO PREMIX</div>`
  return tracks.map((item) => {
    const idRaw = String(item?.id || item?.guid || '')
    const id = escapeHtml(idRaw)
    const indexText = String(item?.index ?? '').padStart(2, '0')
    const rawTrackName = item?.name || item?.label || item?.trackName || item?.displayName || item?.title || item?.sourceName || item?.source_name || item?.groupName || item?.groupLabel || (view === 'groups' ? `GRUPO ${indexText}` : `PISTA ${indexText}`)
    const name = buildMarqueeText(rawTrackName, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee')
    const db = escapeHtml(formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale))
    const color = mixerColorToCss(item?.colorHex || item?.groupColorHex || item?.color || '')
    const muteClass = item?.mute ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn'
    const soloClass = item?.solo ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn'
    const phaseClass = item?.phase ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn'
    const groupLabel = item?.groupName || item?.groupLabel || item?.group || item?.folderName || ''
    const groupName = view === 'tracks' && groupLabel ? `<div class="mixerRowGroupName">${buildMarqueeText(groupLabel, '', 'rowMarquee mixerGroupMarquee')}</div>` : ''
    const disabledClass = canEdit ? '' : ' premixMixerRowDisabled'
    return `<div class="mixerRow premixMixerRow${disabledClass}" style="--mixer-color:${color}" data-action="open-premix-volume" data-premix-view="${view}" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">${escapeHtml(indexText || '')}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div>${groupName}</div><div class="mixerRowDb">${db}</div>${buildMixerMeterHtml(item?.peakRatio ?? 0)}<button class="${muteClass}" data-action="premix-mute" data-premix-view="${view}" data-premix-track-id="${id}" aria-disabled="${canEdit ? 'false' : 'true'}">M</button><button class="${soloClass}" data-action="premix-solo" data-premix-view="${view}" data-premix-track-id="${id}" aria-disabled="${canEdit ? 'false' : 'true'}">S</button><button class="${phaseClass}" data-action="premix-phase" data-premix-view="${view}" data-premix-track-id="${id}" aria-disabled="${canEdit ? 'false' : 'true'}">F</button></div>`
  }).join('')
}

function renderPremixVolumeModal() {
  if (!state.showPremixVolumeModal || !state.premixSelectedTrackId) return ''
  const view = state.premixTrackView === 'groups' ? 'groups' : 'tracks'
  const item = findPremixTrack(state.premixSelectedTrackId, view)
  if (!item) return ''
  const color = mixerColorToCss(item?.colorHex || item?.groupColorHex || item?.color || '')
  const ratio = normalizeMixerRatio(item?.volumeRatio, 0.5)
  const meterHtml = buildMixerMeterHtml(item?.peakRatio ?? 0)
  return `<div class="modalOverlay mixerVolumeOverlay premixVolumeOverlay" data-close-premix-volume style="z-index:3000;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerVolumeModalBox premixVolumeModalBoxFull" data-stop-modal data-mixer-volume-modal="1" style="position:relative;z-index:3001;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;overflow:hidden;border-radius:0;display:flex;flex-direction:column;justify-content:center"><div class="mixerModalHeader"><div class="modalTitle">VOLUME PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix-volume">FECHAR</button></div><div class="mixerVolumeTitle" style="--mixer-color:${color};display:flex;align-items:center;justify-content:space-between;gap:10px"><span style="min-width:0;overflow:hidden;white-space:nowrap;display:block;flex:1 1 auto">${buildMarqueeText(item?.name || 'PREMIX', '', 'rowMarquee mixerNameMarquee')}</span><button class="modalCancelBtn" data-action="premix-volume-reset" data-premix-view="${view}" data-premix-track-id="${escapeHtml(String(state.premixSelectedTrackId))}" style="min-width:88px;height:36px;background:#facc15;color:#111827;border:1px solid #facc15;flex:0 0 auto">RESET</button></div><div class="mixerVolumeMeterWrap">${meterHtml}<div class="mixerVolumeDb">${escapeHtml(formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale))}</div></div><input class="mixerVolumeSlider" type="range" min="0" max="1" step="0.01" value="${ratio}" data-action="premix-volume-slider" data-premix-view="${view}" data-premix-track-id="${escapeHtml(String(state.premixSelectedTrackId))}" /></div></div>`
}

function renderPremixModal() {
  if (!state.showPremixModal) return ''
  const isGlobal = isPremixGlobalMode()
  const isTracks = state.premixView === 'tracks' || isGlobal
  const selectedSong = getPremixSongs().find((song) => String(song?.id || song?.source_number || song?.sourceNumber || '') === String(state.premixSelectedSongId || ''))
  const title = isGlobal ? 'GLOBAL' : (isTracks && selectedSong ? upperText(selectedSong.name || 'PREMIX') : 'PREMIX')
  const premixOn = getPremixOnState()
  const selectedPremixPlaying = isGlobal || isPremixSongActuallyPlaying(state.premixSelectedSongId)
  const onOffClass = premixOn ? 'btnPlayActive' : 'btnDisabled'
  const onOffDisabledAttr = ''
  const isTrackView = state.premixTrackView !== 'groups'
  const tracksTitle = isTrackView ? 'PISTAS' : 'GRUPOS'
  const onLabel = getPremixOnLabel()
  const lockMessage = ''
  const playButton = (!isGlobal && isTracks) ? `<button class="${getPlayButtonClass()} premixPlayButton" data-action="premix-play">${getPlayButtonLabel()}</button>` : ''
  const hasPremixListSelection = !!(!isGlobal && !isTracks && state.premixSelectedSongId)
  const listPlayButton = (!isGlobal && !isTracks) ? `<button class="${hasPremixListSelection ? getPlayButtonClass() : 'btnDisabled'} premixPlayButton" data-action="premix-play" ${hasPremixListSelection ? '' : 'disabled'}>${getPlayButtonLabel()}</button>` : ''
  const globalResetButton = isGlobal ? `<button class="modalCancelBtn premixGlobalResetBtn" data-action="premix-global-reset">RESET 0 dB</button>` : ''
  const backButton = ''
  const closeOrBack = (!isGlobal && isTracks) ? `<button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button>` : `<button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button>`
  const titleHtml = buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee')
  const content = isTracks
    ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px">${backButton}<div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div>${closeOrBack}</div><div class="premixTopControls ${isGlobal ? 'premixTopControlsGlobal' : ''}"><button class="${onOffClass}" data-action="premix-onoff"${onOffDisabledAttr}>${onLabel} ${premixOn ? 'ON' : 'OFF'}</button>${globalResetButton}${playButton}</div>${lockMessage}<div class="mixerViewTabs"><button class="${isTrackView ? 'btnPlayActive' : 'btn'}" data-action="premix-view-tracks">PISTAS</button><button class="${!isTrackView ? 'btnPlayActive' : 'btn'}" data-action="premix-view-groups">GRUPOS</button></div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">${tracksTitle}</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
    : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button></div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div>${listPlayButton}</div><div class="mixerRowsBox premixSongListBox" style="flex:0 1 auto;min-height:0;max-height:calc(var(--app-vh,100dvh) - 150px);overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`
  return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`
}


/* VSHOOK_DIRECTOR_PREMIX_ITEM_MODE_22
   Nova lógica: Premix do Diretor controla itens/takes pelo mesmo caminho do Lua.
   Sem Global, sem ON/OFF, sem grupos e sem preset. */
const VSHOOK_DIRECTOR_PREMIX_ITEM_MODE_22 = true

function vshookPremixItemSongId(song) {
  return String(song?.id ?? song?.source_number ?? song?.sourceNumber ?? song?.number ?? '')
}

function vshookPremixIsHashParent(song) {
  return !!(song && (song.isHashParent || song.familyRole === 'parent' || song.itemType === 'hash_parent' || song.type === 'hash_parent'))
}

function vshookPremixIsHashChild(song) {
  return !!(song && (song.isHashChild || song.familyRole === 'child' || song.itemType === 'hash_child' || song.type === 'hash_child'))
}

function getPremixSongs() {
  const source = Array.isArray(state.premixSongs) && state.premixSongs.length ? state.premixSongs : state.regions
  if (!Array.isArray(source)) return []
  return source.filter((song) => {
    if (!song || detectBlockItem(song)) return false
    if (song.isPlayable === false) return false
    if (vshookPremixIsHashParent(song)) return false
    return vshookPremixItemSongId(song) !== ''
  })
}

function isPremixSelectableSong(song) {
  if (!song || detectBlockItem(song)) return false
  if (song.isPlayable === false) return false
  if (vshookPremixIsHashParent(song)) return false
  return vshookPremixItemSongId(song) !== ''
}

function isPremixGlobalMode() { return false }
function getPremixEntityId() { return String(state.premixSelectedSongId || '') }
function getPremixOnState() { return true }
function getPremixOnLabel() { return 'ITEM' }
function canEditCurrentPremix(showMessage = true) { return !!String(state.premixSelectedSongId || '') }
function canOpenPremixSong(songId, showMessage = true) { return !!String(songId || '') }

function normalizePremixTrackItem(item, view = 'tracks') {
  const src = item && typeof item === 'object' ? item : {}
  const id = String(src.id ?? src.guid ?? src.itemGuid ?? '')
  const ratio = normalizeMixerRatio(src.volumeRatio ?? src.ratio ?? src.volume_ratio, 0.5)
  const dbValue = src.db ?? src.dbValue ?? 0
  return {
    ...src,
    id,
    guid: String(src.guid ?? id),
    name: src.name || src.label || src.trackName || src.itemName || src.takeName || 'ITEM',
    volumeRatio: ratio,
    db: dbValue,
    displayScale: src.displayScale || 'db',
    mute: !!(src.mute ?? src.muted),
    fxEnabled: !!(src.fxEnabled ?? src.fxOn ?? src.fxActive),
    hasFx: !!(src.hasFx ?? src.fxCount > 0 ?? false),
    fxCount: Number(src.fxCount || 0) || 0,
    premixView: 'tracks',
  }
}

function getPremixItemsForView(view = 'tracks') {
  return (Array.isArray(state.premixTracks) ? state.premixTracks : []).filter(Boolean).map((item) => normalizePremixTrackItem(item, 'tracks'))
}

function getPremixTracks() { return getPremixItemsForView('tracks') }

function findPremixTrack(id, view = 'tracks') {
  const wanted = String(id || '')
  if (!wanted) return null
  return getPremixItemsForView('tracks').find((entry) => String(entry?.id || entry?.guid || '') === wanted) || null
}

function setPremixTrackLocalState(id, patch = {}, view = 'tracks') {
  const wanted = String(id || '')
  if (!wanted) return
  state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((item) => {
    const key = String(item?.id || item?.guid || '')
    return key === wanted ? { ...item, ...patch } : item
  })
}

function openPremixModal() {
  state.settingsMenuOpen = false
  state.showGearModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showPremixVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showPremixModal = true
  state.premixIsGlobal = false
  state.premixView = 'songs'
  state.premixTrackView = 'tracks'
  state.premixSelectedTrackId = null
  armOverlayCloseGuard(900)
  render()
  postCommand('premix_item_open', { requestFull: '1', page: getCurrentPcPageName() })
  fastPollBridge?.(10)
}

function openPremixFromMenu(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  event?.stopImmediatePropagation?.()
  openPremixModal()
  return true
}

function openPremixGlobalModal(event) {
  // Global foi removido da nova lógica do Premix.
  return openPremixFromMenu(event)
}

function selectPremixSong(songId) {
  const id = String(songId || '')
  if (!id) return
  const song = getPremixSongs().find((entry) => vshookPremixItemSongId(entry) === id)
  if (!isPremixSelectableSong(song)) return
  state.premixIsGlobal = false
  state.premixSelectedSongId = id
  state.selectedRegionId = id
  state.selectedRegionIds = [id]
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.premixSelectedTrackId = null
  state.showPremixVolumeModal = false
  state.premixView = 'tracks'
  state.premixTrackView = 'tracks'
  state.premixTracks = []
  state.premixGroups = []
  render()
  postCommand('premix_item_focus_song', { id, songId: id, selectedRegionId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(12)
}

function backPremixSongList() {
  state.premixView = 'songs'
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
  postCommand('premix_item_open', { requestFull: '1', page: getCurrentPcPageName() })
}

function setPremixTrackView(view) { state.premixTrackView = 'tracks' }
function handlePremixOnOffToggle(event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }
function handlePremixGlobalReset(event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }

function handlePremixTrackToggle(event, action, trackId, view = 'tracks') {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  const item = findPremixTrack(id, 'tracks')
  const normalizedAction = (action === 'phase' || action === 'fx') ? 'fx' : 'mute'
  if (item) {
    if (normalizedAction === 'mute') setPremixTrackLocalState(id, { mute: !item.mute }, 'tracks')
    if (normalizedAction === 'fx') setPremixTrackLocalState(id, { fxEnabled: !item.fxEnabled }, 'tracks')
  }
  render()
  const command = normalizedAction === 'fx' ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute'
  postCommand(command, { id: songId, songId, selectedRegionId: songId, targetId: id, itemId: id, trackId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(6)
}

function handlePremixVolumeInput(view, trackId, value) {
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  const ratio = normalizeMixerRatio(value, 0.5)
  setPremixTrackLocalState(id, { volumeRatio: ratio }, 'tracks')
  extendMixerVolumeInteraction(320)
  postCommand('premix_item_set_volume', { id: songId, songId, selectedRegionId: songId, targetId: id, itemId: id, trackId: id, ratio, page: getCurrentPcPageName() })
}

function handlePremixVolumeReset(event, view, trackId) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  handlePremixVolumeInput('tracks', trackId, getMixerZeroDbRatio())
  render()
}

function openPremixVolumeModal(view, id) { return false }
function closePremixVolumeModal(force = false) { state.showPremixVolumeModal = false; state.premixSelectedTrackId = null; render() }
function renderPremixVolumeModal() { return '' }
function handlePremixRowOpenFromElement(el, event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }

function renderPremixSongRows() {
  const songs = getPremixSongs()
  if (!songs.length) return '<div class="emptyBox">SEM MÚSICAS</div>'
  return songs.map((song) => {
    const id = vshookPremixItemSongId(song)
    const selected = id && String(state.premixSelectedSongId || '') === id
    const playing = id && String(getCurrentPremixPlayingId() || '') === id
    const title = song?.name || song?.label || song?.title || song?.displayName || song?.sourceName || song?.source_name || song?.regionName || song?.songName || `MÚSICA ${id || ''}`
    const name = buildMarqueeText(title, 'premixSongTitleText', 'rowMarquee premixSongMarquee')
    const duration = song?.durationSec ? `<span class="premixSongDuration">${escapeHtml(formatTime(song.durationSec))}</span>` : ''
    const color = getAppItemTextColor(song)
    const style = color ? ` style="--premix-row-color:${escapeHtml(color)}"` : ''
    const childBadge = vshookPremixIsHashChild(song) ? '<span class="premixSongStatus premixSongStatusOn">FILHO</span>' : ''
    return `<div class="premixSongCard ${selected ? 'premixSongCardSelected selectedRow' : ''} ${playing ? 'premixSongCardPlaying' : ''}"${style} data-action="premix-song" data-premix-song-id="${escapeHtml(id)}"><div class="premixSongAccent"></div><div class="premixSongMain"><div class="premixSongTitle">${name}</div><div class="premixSongMeta">${childBadge}${duration}</div></div><div class="premixSongPlayingBar" aria-hidden="true"></div></div>`
  }).join('')
}

function renderPremixTrackRows() {
  const tracks = getPremixItemsForView('tracks')
  if (!tracks.length) return '<div class="emptyBox">SEM ITENS NESSA MÚSICA</div>'
  return tracks.map((item, index) => {
    const idRaw = String(item?.id || item?.guid || '')
    const id = escapeHtml(idRaw)
    const indexText = String(item?.index ?? (index + 1)).padStart(2, '0')
    const rawName = item?.name || item?.label || item?.trackName || item?.itemName || item?.takeName || `ITEM ${indexText}`
    const name = buildMarqueeText(rawName, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee')
    const ratio = normalizeMixerRatio(item?.volumeRatio, 0.5)
    const db = escapeHtml(formatMixerDbLabel(item?.db ?? 0, item?.volumeRatio, item?.displayScale))
    const muteClass = item?.mute ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn'
    const hasFx = !!(item?.hasFx || Number(item?.fxCount || 0) > 0)
    const fxClass = !hasFx ? 'mixerMiniBtn btnDisabled' : (item?.fxEnabled ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn')
    const drawerStyle = item?.isDrawer || item?.is_drawer ? ' style="background:rgba(250,204,21,.92);color:#111827;border-color:#facc15"' : ''
    return `<div class="mixerRow premixMixerRow"${drawerStyle} data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">${escapeHtml(indexText)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div></div><div class="mixerRowDb">${db}</div><button class="${muteClass}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${id}">M</button><button class="${fxClass}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${id}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button><input class="premixInlineSlider" type="range" min="0" max="1" step="0.01" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${id}" /></div>`
  }).join('')
}

function renderPremixModal() {
  if (!state.showPremixModal) return ''
  const isTracks = state.premixView === 'tracks'
  const selectedSong = getPremixSongs().find((song) => vshookPremixItemSongId(song) === String(state.premixSelectedSongId || ''))
  const title = isTracks && selectedSong ? upperText(selectedSong.name || selectedSong.label || 'PREMIX') : 'PREMIX'
  const titleHtml = buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee')
  const closeOrBack = isTracks ? `<button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button>` : `<button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button>`
  const content = isTracks
    ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px"><div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div>${closeOrBack}</div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">ITENS</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
    : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div>${closeOrBack}</div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div></div><div class="mixerRowsBox premixSongListBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`
  return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`
}

function formatBpmDisplay(value) {
  const num = Math.max(-120, Math.min(120, Math.floor(Number(value) || 0)))
  return `${num > 0 ? '+' : ''}${num}`
}

function openBpmModal() {
  state.settingsMenuOpen = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showTunerModal = false
  state.showBpmModal = true
  armOverlayCloseGuard(650)
  render()
  postCommand('bpm_focus', { page: getCurrentPcPageName() })
  fastPollBridge?.(5)
}

function closeBpmModal() {
  if (shouldIgnoreOverlayClose()) return
  state.showBpmModal = false
  render()
  syncPcBaseViewFromApp()
}

function handleBpmAdjust(delta, event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (!state.playingId) return
  const now = Date.now()
  if ((now - lastBpmAdjustAt) < 90) return
  lastBpmAdjustAt = now
  state.bpmOffset = Math.max(-120, Math.min(120, Math.floor((Number(state.bpmOffset) || 0) + Number(delta || 0))))
  state.bpmDisplay = formatBpmDisplay(state.bpmOffset)
  render()
  postCommand(delta > 0 ? 'bpm_plus' : 'bpm_minus', { page: getCurrentPcPageName(), activeTab: state.activeTab })
}

function handleBpmReset() {
  postCommand('bpm_reset', { page: getCurrentPcPageName() })
  fastPollBridge?.(4)
}

function renderBpmModal() {
  if (!state.showBpmModal) return ''
  const bpmText = escapeHtml(String(state.bpmDisplay || formatBpmDisplay(state.bpmOffset || 0)))
  const canAdjust = !!state.playingId
  const statusText = canAdjust ? '' : '<div class="bpmMetaText">SEM REPRODUÇÃO</div>'
  return `<div class="modalOverlay bpmOverlay" data-close-bpm><div class="modalSpacer"></div><div class="modalBox bpmModalBox" data-stop-modal><div class="mixerModalHeader"><div class="modalTitle">BPM</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-bpm">FECHAR</button></div><div class="bpmValueDisplay">${bpmText}</div>${statusText}<div class="bpmControls bpmControlsSimple"><button class="${canAdjust ? 'bpmAdjustBtn' : 'btnDisabled'}" data-action="bpm-minus">-</button><button class="${canAdjust ? 'bpmAdjustBtn' : 'btnDisabled'}" data-action="bpm-plus">+</button></div></div><div class="modalBottomSpace"></div></div>`
}

function formatTunerDisplay(value) {
  const num = Math.max(-12, Math.min(12, Math.floor(Number(value) || 0)))
  return `${num > 0 ? '+' : ''}${num}`
}

function getCurrentTunerItems() {
  if (state.activeTab === 'regions') {
    return Array.isArray(state.regions) ? state.regions : []
  }
  const playlist = activePlaylist()
  return Array.isArray(playlist?.songs) ? playlist.songs : []
}

function openTunerModal() {
  state.settingsMenuOpen = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = true
  armOverlayCloseGuard(650)
  render()
  const page = getCurrentPcPageName()
  postCommand('tuner_focus', { page })
  postCommand('set_tuner_visibility', { page, visible: '1' })
  fastPollBridge?.(5)
}

function closeTunerModal() {
  if (shouldIgnoreOverlayClose()) return
  state.showTunerModal = false
  render()
  const page = getCurrentPcPageName()
  postCommand('set_tuner_visibility', { page, visible: '0' })
  syncPcBaseViewFromApp()
}

function handleTunerAdjust(itemId, delta, event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const page = getCurrentPcPageName()
  const amount = delta > 0 ? 1 : -1
  const items = getCurrentTunerItems()
  const key = String(itemId || '')
  const item = items.find((entry) => String(entry?.id) === key)
  if (!item || detectBlockItem(item)) return

  // Corrigido: o app NÃO altera o toneOffset real localmente.
  // Quem altera o valor oficial é o VS Hook pelo bridge. Aqui guardamos só
  // uma prévia visual temporária para o número aparecer na hora sem somar 2 vezes.
  const pendingValue = getPendingTunerDisplayValue(page, key)
  const current = Number.isFinite(pendingValue)
    ? pendingValue
    : Math.max(-12, Math.min(12, Math.floor(Number(item?.toneOffset) || 0)))
  const nextValue = Math.max(-12, Math.min(12, current + amount))

  rememberPendingTunerValue(page, key, nextValue)
  render()

  postCommand('tuner_adjust', { page, id: key, targetId: key, delta: amount })
  fastPollBridge?.(6)
}

function handleTunerReset(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const confirmed = window.confirm('Deseja resetar o Tuner desta tela?')
  if (!confirmed) return
  const page = getCurrentPcPageName()
  const items = getCurrentTunerItems().filter((item) => !detectBlockItem(item))
  items.forEach((item) => {
    item.toneOffset = 0
    item.toneDisplay = '0'
  })
  render()
  postCommand('tuner_reset', { page })
  fastPollBridge?.(4)
}

function renderTunerModal() {
  if (!state.showTunerModal) return ''
  const items = getCurrentTunerItems()
  const pageTitle = state.activeTab === 'regions' ? 'MÚSICAS' : 'REPERTÓRIO'
  const rows = items.length
    ? items.map((item) => {
        const isBlock = detectBlockItem(item)
        const id = escapeHtml(String(item?.id || ''))
        const name = isBlock
          ? escapeHtmlPreserveSpaces(formatAppBlockLabel(item))
          : escapeHtml(upperText(item?.name || 'ITEM'))

        if (isBlock) {
          return `<div class="tunerRow tunerBlockRow" style="justify-content:center;opacity:.95;border-color:rgba(250,204,21,.45);background:rgba(250,204,21,.10)"><div class="tunerRowName tunerBlockName" style="text-align:center;font-weight:900;color:#facc15;letter-spacing:.08em">${name}</div></div>`
        }

        const pendingTone = getPendingTunerDisplayValue(getCurrentPcPageName(), String(item?.id || ''))
        const toneOffset = Number.isFinite(pendingTone)
          ? pendingTone
          : Math.max(-12, Math.min(12, Math.floor(Number(item?.toneOffset) || 0)))
        const toneText = escapeHtml(formatTunerDisplay(toneOffset))
        return `<div class="tunerRow"><div class="tunerRowName">${name}</div><div class="tunerRowControls"><button class="tunerAdjustHitBtn" data-action="tuner-minus" data-tuner-id="${id}" aria-label="Diminuir tuner"><span class="tunerAdjustBtnFace">-</span></button><div class="tunerValueBox">${toneText}</div><button class="tunerAdjustHitBtn" data-action="tuner-plus" data-tuner-id="${id}" aria-label="Aumentar tuner"><span class="tunerAdjustBtnFace">+</span></button></div></div>`
      }).join('')
    : '<div class="emptyBox">SEM ITENS</div>'
  return `<div class="modalOverlay tunerOverlay" data-close-tuner style="align-items:stretch;justify-content:flex-end;padding:0"><div class="tunerDrawer" data-stop-modal style="margin-left:auto;margin-right:0"><div class="tunerDrawerHeader"><div><div class="modalTitle">TUNER</div><div class="tunerDrawerSub">${pageTitle}</div></div><button class="modalCancelBtn mixerCloseBtn" data-action="close-tuner">FECHAR</button></div><div class="tunerRowsBox">${rows}</div></div></div>`
}


const state = {
  regions: [],
  playlists: [],
  markers: [],
  activePlaylistId: null,
  selectedRegionId: null,
  selectedRegionIds: [],
  selectedPlaylistSongId: null,
  selectedPlaylistSongIds: [],
  selectedMarkerId: null,
  markerGoFlashId: null,
  markerGoFlashStartedAtMs: 0,
  markerGoFlashForceUntil: 0,
  multiSelectMode: false,
  multiSelectTab: null,
  playingId: null,
  autoplayEnabled: false,
  autoBlocoEnabled: false,
  activeTab: 'regions',
  playlistView: 'songs',
  localMarkersMode: false,
  pendingTabCommand: null,
  bridgeStatus: 'offline',
  nativeBridgeConnected: false,
  bridgeMode: '',
  selectionLockUntil: 0,
  showCreatePlaylistModal: false,
  showAddExistingModal: false,
  showPlaylistSwitchModal: false,
  showDeletePlaylistConfirmModal: false,
  newPlaylistName: '',
  selectedExistingPlaylistId: null,
  selectedSwitchPlaylistId: null,
  queuedSongId: null,
  localQueuedSongId: null,
  localQueuedSongAt: 0,
  localQueuedSongTab: null,
  loopActive: false,
  borderHue: 0,
  rgbMode: 'auto',
  rgbFixedIndex: 0,
  clearButtonSide: 'right',
  pendingStopClear: false,
  stoppedSelectionHoldId: null,
  stoppedSelectionHoldTab: null,
  stoppedSelectionHoldUntil: 0,
  settingsMenuOpen: false,
  showGearModal: false,
  theme: 'dark',
  editMode: false,
  deleteMode: false,
  dragType: null,
  dragSelectedIds: [],
  dragHoverId: null,
  dragActive: false,
  dragSnapshot: null,
  dragPointerId: null,
  dragPending: null,
  dragLayout: [],
  dragLastClientY: null,
  showRenameModal: false,
  renameValue: '',
  renameTargetType: null,
  renameTargetId: null,
  renameIsBlock: false,
  appPopupVisible: false,
  appPopupText: '',
  appPopupKind: 'info',
  appPopupDurationMs: 1800,
  bridgePopupVisible: false,
  bridgePopupText: '',
  bridgePopupError: false,
  bridgePopupPersistent: false,
  noticeEnabled: true,
  liveModeEnabled: false,
  showLiveOffConfirmModal: false,
  authEnabled: false,
  authHash: '',
  authAuthenticated: false,
  authUserInput: '',
  authPassInput: '',
  authError: '',
  authShowPassword: false,
  appActive: false,
  lastBridgeUpdatedAtMs: 0,
  playbackDurationSec: 0,
  playbackRemainingSec: null,
  playbackElapsedSec: null,
  playbackStartPos: null,
  playbackEndPos: null,
  playbackSyncedAtMs: 0,
  showTimerModal: false,
  timerRunning: false,
  timerStartedAt: 0,
  timerAccumulatedSec: 0,
  timerModalMode: 'start',
  timerMode: 'progressive',
  timerTargetSec: 0,
  timerDisplaySec: 0,
  timerLocalOwnerUntil: 0,
  transportProtectionEnabled: false,
  lastProtectedPlayTapAt: 0,
  regionsScrollRatio: 0,
  playlistScrollRatio: 0,
  markersScrollRatio: 0,
  markersPanelAnimateUntil: 0,
  hashChildLocalOpenByKey: {},
  hashChildCacheByParentKey: {},
  hashChildOpeningUntilByKey: {},
  hashChildClosingUntilByKey: {},
  showMixerModal: false,
  showMixerVolumeModal: false,
  mixerView: 'tracks',
  mixerVolumeView: 'tracks',
  mixerSelectedId: null,
  mixerTracks: [],
  mixerGroups: [],
  mixerMaster: null,
  showPremixModal: false,
  showPremixVolumeModal: false,
  premixView: 'songs',
  premixTrackView: 'tracks',
  premixSelectedSongId: null,
  premixSelectedTrackId: null,
  premixSelectedEnabled: false,
  premixSelectedPlaying: false,
  premixSelectedCanEdit: false,
  premixGlobalEnabled: false,
  premixIsGlobal: false,
  premixSongs: [],
  premixTracks: [],
  premixGroups: [],
  premixGlobalTracks: [],
  premixGlobalGroups: [],
  premixBypassEnabled: false,
  mixerVolumeInteracting: false,
  mixerVolumeInteractionUntil: 0,
  showBpmModal: false,
  showTunerModal: false,
  projectTabs: [],
  activeProjectTabIndex: 0,
  showProjectTabsModal: false,
  selectedProjectTabIndex: null,
  bpmOffset: 0,
  bpmDisplay: '0',
  bpmModeActive: false,
  tunerModeActive: false,
  lyricsPanelOpen: false,
  lyricsEditing: false,
  lyricsDraft: '',
  lyricsEditingSongId: null,
  showRecadosModal: false,
  recadosDraft: '',
  recadosStatus: '',
  recadosSending: false,
  recadosNoticeExpiresAt: 0,
  recadosNoticeId: '',
}

let pendingLoopToggleAt = 0
let pendingLoopToggleFromState = null
let pendingNoticeToggleAt = 0
let pendingNoticeToggleValue = null
let pendingAutoplayVisualValue = null
let pendingAutoplayVisualUntil = 0
let pendingPlaybackToggleAt = 0
let pendingPlaybackDesiredPlaying = null
let pendingPlaybackDesiredSourceId = null
let pendingPlaybackDesiredSourceTab = null
let lastPlayButtonCommandAt = 0
let playPointerUpSyntheticClickSuppressUntil = 0
let lastPlayPointerUpAt = 0
let lastPlayPointerUpHandledPlayingIntent = null
let lastPlaybackSelectionId = null
let lastPlaybackSelectionTab = null
let remoteQueuedIgnoreUntil = 0
const REMOTE_QUEUE_IGNORE_MS = 3600
const PENDING_PLAYBACK_GRACE_MS = 1600
const optimisticPlaybackState = {
  id: null,
  sourceTab: null,
  startedAtMs: 0,
  durationSec: 0,
  expiresAtMs: 0,
}
const OPTIMISTIC_PLAYBACK_MIN_BAR_SEC = 0.35
const OPTIMISTIC_PLAYBACK_MIN_GRACE_MS = 900
const OPTIMISTIC_PLAYBACK_END_EXTRA_MS = 500
const OPTIMISTIC_PLAYBACK_MAX_GRACE_MS = 1800

// DIRECTOR_VISUAL_SELECTION_SOURCE_OF_TRUTH_PATCH
// Seleção feita no front do Diretor tem prioridade temporária sobre selectedId antigo do Bridge.
// Resolve o retorno visual para a música que já parou, sem alterar Play/Stop real.
const DIRECTOR_LOCAL_SELECTION_HOLD_MS = 9000
const DIRECTOR_STOPPED_SELECTION_BLACKLIST_MS = 16000
let directorLocalSelectionHoldId = null
let directorLocalSelectionHoldTab = null
let directorLocalSelectionHoldUntil = 0
let directorRecentlyStoppedSelectionBlockId = null
let directorRecentlyStoppedSelectionBlockUntil = 0

function setDirectorLocalSelectionHold(id, tab, ms = DIRECTOR_LOCAL_SELECTION_HOLD_MS) {
  const key = String(id ?? '')
  if (!key) return
  directorLocalSelectionHoldId = key
  directorLocalSelectionHoldTab = tab || state.activeTab || 'playlist'
  directorLocalSelectionHoldUntil = Date.now() + Math.max(500, Number(ms) || DIRECTOR_LOCAL_SELECTION_HOLD_MS)
  state.selectionLockUntil = Math.max(Number(state.selectionLockUntil || 0), directorLocalSelectionHoldUntil)
}

function clearDirectorLocalSelectionHold() {
  directorLocalSelectionHoldId = null
  directorLocalSelectionHoldTab = null
  directorLocalSelectionHoldUntil = 0
}

function getActiveDirectorLocalSelectionHold() {
  const key = String(directorLocalSelectionHoldId || '')
  if (!key) return null
  if (Date.now() >= Number(directorLocalSelectionHoldUntil || 0)) {
    clearDirectorLocalSelectionHold()
    return null
  }
  return { id: key, tab: directorLocalSelectionHoldTab || state.activeTab || 'playlist' }
}

function markDirectorRecentlyStoppedSelectionBlocked(id) {
  const key = String(id ?? '')
  if (!key) return
  directorRecentlyStoppedSelectionBlockId = key
  directorRecentlyStoppedSelectionBlockUntil = Date.now() + DIRECTOR_STOPPED_SELECTION_BLACKLIST_MS
}

function isDirectorStoppedSelectionBlocked(id) {
  const key = String(id ?? '')
  if (!key || !directorRecentlyStoppedSelectionBlockId) return false
  if (Date.now() >= Number(directorRecentlyStoppedSelectionBlockUntil || 0)) {
    directorRecentlyStoppedSelectionBlockId = null
    directorRecentlyStoppedSelectionBlockUntil = 0
    return false
  }
  return key === String(directorRecentlyStoppedSelectionBlockId)
}

function getOptimisticPlaybackGraceMsForDuration(durationSec) {
  const durationMs = Math.max(0, Number(durationSec) || 0) * 1000
  // Quando o Bridge confirma transporte tocando mas ainda não manda playingId/duração,
  // não derruba o Play visual depois de poucos segundos. Mantém até Stop explícito
  // ou até o tempo da música quando houver duração conhecida.
  if (!durationMs) return OPTIMISTIC_PLAYBACK_MAX_GRACE_MS
  return Math.max(OPTIMISTIC_PLAYBACK_MIN_GRACE_MS, Math.min(OPTIMISTIC_PLAYBACK_MAX_GRACE_MS, durationMs + OPTIMISTIC_PLAYBACK_END_EXTRA_MS))
}

function getPendingPlaybackGraceMs() {
  // O comando Play/Stop continua sendo enviado uma única vez.
  // Este tempo é só a tolerância visual do front antes de aceitar o Bridge como fonte real.
  return PENDING_PLAYBACK_GRACE_MS
}

function clearOptimisticPlayback() {
  optimisticPlaybackState.id = null
  optimisticPlaybackState.sourceTab = null
  optimisticPlaybackState.startedAtMs = 0
  optimisticPlaybackState.durationSec = 0
  optimisticPlaybackState.expiresAtMs = 0
}

function clearDirectorPlaybackClockIfStopped() {
  if (state.playingId != null && String(state.playingId) !== '') return
  state.playbackRemainingSec = null
  state.playbackElapsedSec = null
  state.playbackSyncedAtMs = 0
}

function findAnyPlaybackItemById(id) {
  const key = String(id ?? '')
  if (!key) return null
  const region = findPlayingRegionById(key)
  if (region) return region
  const playlistSong = findPlaylistSongByIdEverywhere(key)
  if (playlistSong) return playlistSong
  if (Array.isArray(state.regions)) {
    const directRegion = state.regions.find((item) => String(item?.id ?? item?.songId ?? '') === key)
    if (directRegion) return directRegion
  }
  return null
}

function getItemStableId(item) {
  return item == null ? '' : String(item.id ?? item.songId ?? item.source_number ?? item.sourceNumber ?? '')
}

function findFirstPlayableIdAfterBlockInList(list, blockId) {
  const key = String(blockId ?? '')
  if (!key || !Array.isArray(list) || !list.length) return null
  const blockIndex = list.findIndex((item) => getItemStableId(item) === key)
  if (blockIndex < 0) return null
  for (let i = blockIndex + 1; i < list.length; i += 1) {
    const item = list[i]
    if (!item) continue
    if (detectBlockItem(item)) break
    const id = getItemStableId(item)
    if (id) return id
  }
  return null
}

function resolvePlaybackTargetIdForBlock(targetId, sourceTab = null) {
  const key = String(targetId ?? '')
  if (!key) return null
  const tab = sourceTab || state.activeTab || 'playlist'

  if (tab === 'playlist') {
    const playlist = activePlaylist()
    const songs = vshookRootFamilyItems(Array.isArray(playlist?.songs) ? playlist.songs : [])
    const item = songs.find((entry) => getItemStableId(entry) === key)
    if (item && detectBlockItem(item)) return findFirstPlayableIdAfterBlockInList(songs, key)
  }

  if (tab === 'regions') {
    const regions = Array.isArray(state.regions) ? state.regions : []
    const item = regions.find((entry) => getItemStableId(entry) === key)
    if (item && detectBlockItem(item)) return findFirstPlayableIdAfterBlockInList(regions, key)
  }

  return key
}

function getOptimisticDurationSec(id) {
  const item = findAnyPlaybackItemById(id)
  const itemDuration = Number(item?.durationSec)
  if (Number.isFinite(itemDuration) && itemDuration > 0) return itemDuration
  const itemRemaining = Number(item?.remainingSec)
  if (Number.isFinite(itemRemaining) && itemRemaining > 0) return itemRemaining
  return 0
}

function startOptimisticPlayback(id, sourceTab = null) {
  const key = String(id ?? '')
  if (!key) return false
  clearVisualQueueForDirector(1800)
  optimisticPlaybackState.id = key
  optimisticPlaybackState.sourceTab = sourceTab || state.activeTab || 'playlist'
  optimisticPlaybackState.startedAtMs = Date.now()
  optimisticPlaybackState.durationSec = getOptimisticDurationSec(key)
  optimisticPlaybackState.expiresAtMs = optimisticPlaybackState.startedAtMs + getOptimisticPlaybackGraceMsForDuration(optimisticPlaybackState.durationSec)
  state.playingId = key

  // Front primeiro: ao dar Play pelo Diretor, a barra/tempo começam pelo cache local
  // da própria música. O Bridge entra depois apenas para corrigir e manter sync.
  const frontDuration = Math.max(0, Number(optimisticPlaybackState.durationSec) || Number(getOptimisticDurationSec(key)) || 0)
  if (frontDuration > 0) {
    state.playbackDurationSec = frontDuration
    state.playbackRemainingSec = frontDuration
    state.playbackElapsedSec = 0
    state.playbackSyncedAtMs = optimisticPlaybackState.startedAtMs
  } else {
    state.playbackRemainingSec = null
    state.playbackElapsedSec = null
    state.playbackSyncedAtMs = 0
  }

  rememberCurrentPlaybackSelection(key, optimisticPlaybackState.sourceTab)
  clearStoppedSelectionHold()
  lockSelectionSync(DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS + 900)
  resetPlaybackLiveState(true)
  return true
}

function isOptimisticPlaybackActiveFor(id) {
  const key = String(id ?? '')
  if (!key || !optimisticPlaybackState.id || optimisticPlaybackState.id !== key) return false
  if (Date.now() > Number(optimisticPlaybackState.expiresAtMs || 0)) {
    clearOptimisticPlayback()
    return false
  }
  return true
}

function getOptimisticRemainingSec(id, fallbackDurationSec = 0) {
  if (!isOptimisticPlaybackActiveFor(id)) return Number.NaN
  const duration = Math.max(0, Number(fallbackDurationSec) || Number(optimisticPlaybackState.durationSec) || 0)
  if (!duration) return Number.NaN
  const elapsed = Math.max(OPTIMISTIC_PLAYBACK_MIN_BAR_SEC, (Date.now() - Number(optimisticPlaybackState.startedAtMs || Date.now())) / 1000)
  return Math.max(0, duration - elapsed)
}

function isPendingDirectorPlayStart() {
  return !!(pendingPlaybackToggleAt && pendingPlaybackDesiredPlaying === true && (Date.now() - pendingPlaybackToggleAt) < getPendingPlaybackGraceMs())
}

function getPlaybackCommandPayloadForTarget(targetId, sourceTab = null, desiredPlaying = true) {
  const tab = sourceTab || state.activeTab || 'playlist'
  const key = targetId != null && String(targetId) !== '' ? String(targetId) : null
  const payload = {
    activeTab: tab,
    selectedRegionId: tab === 'regions' ? key : null,
    selectedPlaylistSongId: tab === 'playlist' ? key : null,
    desiredPlaying: !!desiredPlaying,
    desiredState: desiredPlaying ? 'playing' : 'stopped',
    forcePlay: !!desiredPlaying,
    forceStop: !desiredPlaying,
  }

  // Envia o alvo absoluto da linha para o Lua. Na aba Repertórios o ID visual
  // pode bater com a música, mas o índice real da playlist tem blocos no meio.
  // Mandar index/start/end/uid elimina ambiguidade no primeiro acesso do app.
  let item = null
  if (key) {
    if (tab === 'playlist' && typeof findPlaylistSongByIdEverywhere === 'function') {
      item = findPlaylistSongByIdEverywhere(key)
    }
    if (!item && typeof findAnyPlaybackItemById === 'function') {
      item = findAnyPlaybackItemById(key)
    }
  }

  if (item && typeof item === 'object') {
    const itemIndex = Number(item.index)
    const itemStart = Number(item.startPos ?? item.start_pos)
    const itemEnd = Number(item.endPos ?? item.end_pos)
    if (Number.isFinite(itemIndex)) payload.selectedPlaylistIndex = itemIndex
    if (item.uid != null) payload.selectedPlaylistUid = String(item.uid)
    if (Number.isFinite(itemStart)) payload.selectedStartPos = itemStart
    if (Number.isFinite(itemEnd)) payload.selectedEndPos = itemEnd
    if (item.source_number != null) payload.selectedSourceNumber = String(item.source_number)
    if (item.sourceNumber != null) payload.selectedSourceNumber = String(item.sourceNumber)
    if (item.id != null && tab === 'playlist') payload.selectedPlaylistSongId = String(item.id)
    if (item.id != null && tab === 'regions') payload.selectedRegionId = String(item.id)
    if (state.activePlaylistId != null) payload.activePlaylistId = String(state.activePlaylistId)
  }

  return payload
}


function buildQueueOnlyPayload(targetId, sourceTab = 'playlist') {
  const key = targetId != null && String(targetId) !== '' ? String(targetId) : ''
  const tab = sourceTab || state.activeTab || 'playlist'
  const payload = {
    id: key,
    targetId: key,
    songId: key,
    activeTab: tab,
    queueOnly: true,
    noTransport: true,
    keepPlaying: true,
    noSeek: true,
    preserveCursor: true,
    transportOnly: false,
    role: 'director',
    clientRole: 'director',
    appRole: 'director',
    source: 'director',
    mode: 'director',
  }
  if (tab === 'regions') {
    payload.selectedRegionId = key
    payload.regionId = key
  } else {
    payload.selectedPlaylistSongId = key
    payload.playlistSongId = key
    if (state.activePlaylistId != null) payload.activePlaylistId = String(state.activePlaylistId)
  }
  return payload
}

function showLocalPlaybackPopupForId(id) {
  const item = findAnyPlaybackItemById(id)
  if (!item || detectBlockItem(item)) return false
  const label = upperText(item.name || item.label || '')
  if (!label) return false
  showAppPopup(label, 'marker', DIRECTOR_PLAYBACK_NAME_POPUP_MS || 1800)
  return true
}

let directorStopRetryTimer = null

function postPlaybackToggleCommand(targetId, sourceTab = null, desiredPlaying = true, extraPayload = null) {
  if (!desiredPlaying) {
    if (directorStopRetryTimer) {
      clearTimeout(directorStopRetryTimer)
      directorStopRetryTimer = null
    }
    const stopPayload = {
      role: 'director',
      clientRole: 'director',
      appRole: 'director',
      source: 'director',
      mode: 'director',
      activeTab: sourceTab || state.activeTab || 'playlist',
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
    }
    if (extraPayload && typeof extraPayload === 'object') {
      if (extraPayload.stopSelectionTargetId != null) stopPayload.stopSelectionTargetId = String(extraPayload.stopSelectionTargetId)
      if (extraPayload.stopSelectionTargetTab != null) stopPayload.stopSelectionTargetTab = String(extraPayload.stopSelectionTargetTab)
      if (extraPayload.stopSelectionTargetSource != null) stopPayload.stopSelectionTargetSource = String(extraPayload.stopSelectionTargetSource)
    }
    return postCommand('director_stop_no_seek', stopPayload)
  }

  const payload = getPlaybackCommandPayloadForTarget(targetId, sourceTab, true)
  if (extraPayload && typeof extraPayload === 'object') Object.assign(payload, extraPayload)
  payload.noSeek = true
  payload.preserveCursor = true
  payload.transportOnly = true
  payload.activeTab = payload.activeTab || sourceTab || state.activeTab || 'playlist'
  return postCommand('director_play_no_seek', payload)
}
const pendingMixerToggleState = new Map()
const PENDING_MIXER_TOGGLE_GRACE_MS = 1400
const mixerDisplayScaleState = new Map()
const pendingTunerState = new Map()
const PENDING_TUNER_GRACE_MS = 1600

function getTunerPendingKey(page, id) {
  return `${String(page || '')}:${String(id || '')}`
}

function rememberPendingTunerValue(page, id, value) {
  const rawId = String(id || '')
  if (!rawId) return
  pendingTunerState.set(getTunerPendingKey(page, rawId), {
    value: Math.max(-12, Math.min(12, Math.floor(Number(value) || 0))),
    expiresAt: Date.now() + PENDING_TUNER_GRACE_MS,
  })
}

function getPendingTunerDisplayValue(page, id) {
  const rawId = String(id || '')
  if (!rawId) return Number.NaN
  const key = getTunerPendingKey(page, rawId)
  const pending = pendingTunerState.get(key)
  if (!pending) return Number.NaN
  if (Date.now() > Number(pending.expiresAt || 0)) {
    pendingTunerState.delete(key)
    return Number.NaN
  }
  return Math.max(-12, Math.min(12, Math.floor(Number(pending.value) || 0)))
}

function clearConfirmedPendingTunerValue(page, item) {
  if (!item || typeof item !== 'object') return
  const rawId = String(item.id ?? '')
  if (!rawId) return
  const key = getTunerPendingKey(page, rawId)
  const pending = pendingTunerState.get(key)
  if (!pending) return
  if (Date.now() > Number(pending.expiresAt || 0)) {
    pendingTunerState.delete(key)
    return
  }
  const incoming = Math.max(-12, Math.min(12, Math.floor(Number(item.toneOffset) || 0)))
  if (incoming === Number(pending.value)) {
    pendingTunerState.delete(key)
  }
}

function applyPendingTunerState() {
  // Não sobrescreve mais state.regions/playlists com valor pendente.
  // O pendente é apenas visual no render do Tuner, evitando soma dupla.
  if (Array.isArray(state.regions)) {
    state.regions.forEach((item) => clearConfirmedPendingTunerValue('regions', item))
  }
  if (Array.isArray(state.playlists)) {
    state.playlists.forEach((playlist) => {
      if (Array.isArray(playlist?.songs)) {
        playlist.songs.forEach((item) => clearConfirmedPendingTunerValue('playlist', item))
      }
    })
  }
}

function getMixerDisplayScaleKey(view, id) {
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  return `${normalizedView}:${String(id || '')}`
}

function detectMixerDisplayScale(value, ratioHint = Number.NaN) {
  return isMixerDisplayLikelyRatioScale(value, ratioHint) ? 'ratio' : 'db'
}

function rememberMixerDisplayScale(view, id, value, ratioHint = Number.NaN) {
  const rawId = String(id || '')
  if (!rawId) return ''
  const scale = detectMixerDisplayScale(value, ratioHint)
  mixerDisplayScaleState.set(getMixerDisplayScaleKey(view, rawId), scale)
  return scale
}

function getRememberedMixerDisplayScale(view, id, fallbackValue = Number.NaN, ratioHint = Number.NaN) {
  const rawId = String(id || '')
  if (!rawId) return detectMixerDisplayScale(fallbackValue, ratioHint)
  const key = getMixerDisplayScaleKey(view, rawId)
  const remembered = mixerDisplayScaleState.get(key)
  if (remembered === 'ratio' || remembered === 'db') return remembered
  return rememberMixerDisplayScale(view, rawId, fallbackValue, ratioHint)
}

function decorateMixerIncomingItem(view, item) {
  if (!item || typeof item !== 'object') return item
  const nextItem = applyPendingMixerToggleToItem(view, item)
  const rawId = nextItem?.id ?? nextItem?.guid
  if (rawId == null) return nextItem
  const scale = rememberMixerDisplayScale(view, rawId, nextItem?.db, nextItem?.volumeRatio)
  if (nextItem?.displayScale === scale) return nextItem
  return { ...nextItem, displayScale: scale }
}

function getMixerPendingToggleKey(view, id, field) {
  const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks')
  return `${normalizedView}:${String(id || '')}:${String(field || '')}`
}

function rememberMixerPendingToggle(view, id, field, value) {
  const key = getMixerPendingToggleKey(view, id, field)
  pendingMixerToggleState.set(key, {
    value: !!value,
    expiresAt: Date.now() + PENDING_MIXER_TOGGLE_GRACE_MS,
  })
}

function applyPendingMixerToggleToItem(view, item) {
  if (!item || typeof item !== 'object') return item
  const rawId = item.id ?? item.guid
  if (rawId == null) return item

  let nextItem = item

  ;['mute', 'solo'].forEach((field) => {
    const key = getMixerPendingToggleKey(view, rawId, field)
    const pending = pendingMixerToggleState.get(key)
    if (!pending) return

    if (Date.now() > Number(pending.expiresAt || 0)) {
      pendingMixerToggleState.delete(key)
      return
    }

    const incomingValue = !!item?.[field]
    if (incomingValue === !!pending.value) {
      pendingMixerToggleState.delete(key)
      return
    }

    if (nextItem === item) nextItem = { ...item }
    nextItem[field] = !!pending.value
  })

  return nextItem
}

function mapMixerIncomingItemsWithPending(view, items) {
  return Array.isArray(items) ? items.map((item) => decorateMixerIncomingItem(view, item)) : []
}
let lastUserScrollAt = 0
let lastAppliedRemoteScrollKey = ''
let lastBpmAdjustAt = 0
let mixerVolumeReleaseTimer = 0
let overlayCloseGuardUntil = 0
let lastBridgeUiRenderAt = 0
let playbackRenderTimer = null


function getAppViewportHeightPx() {
  const vv = window.visualViewport
  const vvHeight = Number(vv?.height) || 0
  const inner = Number(window.innerHeight) || 0
  const doc = Number(document.documentElement?.clientHeight) || 0
  return Math.max(320, Math.round(vvHeight || inner || doc || 0))
}

function syncAppViewportHeight() {
  const next = getAppViewportHeightPx()
  const root = document.documentElement
  if (root) {
    root.style.setProperty('--app-vh', `${next}px`)
    root.style.height = `${next}px`
    root.style.overflow = 'hidden'
  }
  if (document.body) {
    document.body.style.height = `${next}px`
    document.body.style.minHeight = `${next}px`
    document.body.style.overflow = 'hidden'
  }
  const host = document.getElementById('app')
  if (host) {
    host.style.height = `${next}px`
    host.style.minHeight = `${next}px`
    host.style.overflow = 'hidden'
  }
}


const LOADING_ICON_DATA_URL = '/vsdiretor-icon-512.png'
const APP_LOADING_MIN_MS = 3000
let appBootStartedAt = Date.now()
let appLoadingVisible = true
let appLoadedOnce = false

let touchStartX = null
let touchStartY = null
let touchStartAt = 0
let borderTimer = null
let bridgeTimer = null
let chronoRenderTimer = null
let clearDragStartX = null
let suppressEditClickUntil = 0
let appRootClickBound = false
let lastBridgeRenderSignature = ''
let lastAppHeartbeatAt = 0
let authFocusHoldUntil = 0
let directorLocalInputHoldUntil = 0
const DIRECTOR_RECADO_DURATION_MS = 15000
let authGateWasVisible = false
let appPopupHideTimer = null
let bridgePopupFadeTimer = null
const bridgePopupDisplay = { mounted: false, text: '', error: false, persistent: false, fading: false }

// v2.0.36 - popup do nome da música no Play não pode ficar preso na tela.
// O Lua/Bridge pode continuar mandando popupVisible por alguns ciclos; o front
// reconhece quando o texto é o nome da música em execução e encerra localmente.
const DIRECTOR_PLAYBACK_NAME_POPUP_MS = 1800
let bridgePlaybackNamePopupKey = ''
let bridgePlaybackNamePopupExpireAtMs = 0
let bridgePlaybackNamePopupHideTimer = null

function normalizeDirectorPopupText(value) {
  return upperText(String(value || '')).replace(/\s+/g, ' ').trim()
}

function getDirectorPlaybackPopupCandidateIds() {
  return [
    state.playingId,
    optimisticPlaybackState && optimisticPlaybackState.id,
    pendingPlaybackDesiredSourceId,
    lastPlaybackSelectionId,
  ].filter((value) => value != null && String(value) !== '').map((value) => String(value))
}

function isDirectorPlaybackNamePopupText(text) {
  const key = normalizeDirectorPopupText(text)
  if (!key) return false
  const ids = getDirectorPlaybackPopupCandidateIds()
  for (const id of ids) {
    const item = findAnyPlaybackItemById(id)
    const label = normalizeDirectorPopupText(item?.name || item?.label || '')
    if (label && label === key) return true
  }
  return false
}

function hideExpiredDirectorPlaybackNamePopup(expectedKey = '') {
  const key = expectedKey || bridgePlaybackNamePopupKey
  if (!key) return
  if (Date.now() < Number(bridgePlaybackNamePopupExpireAtMs || 0)) return
  if (normalizeDirectorPopupText(bridgePopupDisplay.text) !== key) return
  bridgePopupDisplay.mounted = false
  bridgePopupDisplay.text = ''
  bridgePopupDisplay.error = false
  bridgePopupDisplay.persistent = false
  bridgePopupDisplay.fading = false
  state.bridgePopupVisible = false
  state.bridgePopupText = ''
  state.bridgePopupError = false
  state.bridgePopupPersistent = false
  bridgePlaybackNamePopupKey = ''
  bridgePlaybackNamePopupExpireAtMs = 0
  bridgePlaybackNamePopupHideTimer = null
  try { render() } catch (error) {}
  try { syncBridgePopupDom() } catch (error) {}
}

function markDirectorPlaybackNamePopup(text) {
  const key = normalizeDirectorPopupText(text)
  if (!key) return false
  const now = Date.now()
  if (bridgePlaybackNamePopupKey !== key || now > Number(bridgePlaybackNamePopupExpireAtMs || 0) + 600) {
    bridgePlaybackNamePopupKey = key
    bridgePlaybackNamePopupExpireAtMs = now + DIRECTOR_PLAYBACK_NAME_POPUP_MS
  }
  if (bridgePlaybackNamePopupHideTimer) clearTimeout(bridgePlaybackNamePopupHideTimer)
  bridgePlaybackNamePopupHideTimer = setTimeout(() => hideExpiredDirectorPlaybackNamePopup(key), Math.max(60, bridgePlaybackNamePopupExpireAtMs - now + 40))
  return now < bridgePlaybackNamePopupExpireAtMs
}
let wakeLockHandle = null
let wakeLockEnabled = true
let lastProximityPopupMarkerId = null
let noSleepVideoEl = null
let wakeLockRefreshTimer = 0
let noSleepKeepAliveTimer = 0
let listScrollSyncIgnoreUntil = 0
let lastScrollCommandAt = 0
let pendingScrollSyncFrame = 0
let listPointerActive = false


function ensureNoSleepVideo() {
  if (noSleepVideoEl) return noSleepVideoEl
  const video = document.createElement('video')
  video.setAttribute('playsinline', '')
  video.setAttribute('webkit-playsinline', '')
  video.setAttribute('x5-playsinline', '')
  video.setAttribute('x5-video-player-type', 'h5')
  video.setAttribute('x5-video-player-fullscreen', 'false')
  video.setAttribute('muted', '')
  video.setAttribute('disablepictureinpicture', '')
  video.setAttribute('x-webkit-airplay', 'deny')
  video.muted = true
  video.defaultMuted = true
  video.loop = true
  video.autoplay = true
  video.preload = 'auto'
  video.playsInline = true
  try { video.disablePictureInPicture = true } catch (error) {}
  video.style.position = 'fixed'
  video.style.left = '0'
  video.style.top = '0'
  video.style.width = '1px'
  video.style.height = '1px'
  video.style.opacity = '0.001'
  video.style.pointerEvents = 'none'
  video.style.zIndex = '-1'
  video.style.background = 'transparent'
  video.style.border = '0'
  const source = document.createElement('source')
  source.src = 'data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAGbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAkx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAABAAAAAQAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAAG7bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAAMgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABbm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAATZzdGJsAAAAsnN0c2QAAAAAAAAAAQAAAKJhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAABAAEASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAN/+EAGGdkAA2s2UEA8A8AAAMAAgAAAwB4HixckAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAAxAAAAHHN0dHMAAAAAAAAAAQAAAAEAAAAUAAAAFHN0c2MAAAAAAAAAAQAAAAEAAAABAAAAAQAAAAxzdHN6AAAAAAAAABQAAAABAAAAFHN0Y28AAAAAAAAAAQAAALg='
  video.appendChild(source)

  const keepAlive = () => {
    if (!wakeLockEnabled) return
    if (document.visibilityState !== 'visible') return
    try {
      if (Number.isFinite(video.currentTime) && video.currentTime > 0.45) {
        video.currentTime = 0.01
      }
    } catch (error) {}
    try {
      const playPromise = video.play?.()
      if (playPromise && typeof playPromise.catch === 'function') {
        playPromise.catch(() => {})
      }
    } catch (error) {}
  }

  video.addEventListener('pause', () => {
    window.setTimeout(keepAlive, 40)
  })
  video.addEventListener('ended', () => {
    try { video.currentTime = 0.01 } catch (error) {}
    keepAlive()
  })
  video.addEventListener('suspend', () => {
    window.setTimeout(keepAlive, 80)
  })
  video.addEventListener('stalled', () => {
    window.setTimeout(keepAlive, 80)
  })
  video.addEventListener('loadedmetadata', keepAlive)

  document.body.appendChild(video)
  noSleepVideoEl = video
  return video
}

function kickNoSleepVideo(forcePrime = false) {
  try {
    const video = ensureNoSleepVideo()
    if (!video) return
    if (forcePrime) {
      try { video.currentTime = 0.01 } catch (error) {}
    } else if (Number.isFinite(video.currentTime) && video.currentTime > 0.45) {
      try { video.currentTime = 0.01 } catch (error) {}
    }
    const playPromise = video.play?.()
    if (playPromise && typeof playPromise.catch === 'function') {
      playPromise.catch(() => {})
    }
  } catch (error) {}
}

async function requestWakeLock(forcePrime = false) {
  if (!wakeLockEnabled) return
  if (document.visibilityState !== 'visible') return

  if ('wakeLock' in navigator && navigator.wakeLock?.request) {
    try {
      if (!wakeLockHandle) {
        wakeLockHandle = await navigator.wakeLock.request('screen')
        wakeLockHandle?.addEventListener?.('release', () => {
          wakeLockHandle = null
          if (wakeLockEnabled && document.visibilityState === 'visible') {
            window.setTimeout(() => { requestWakeLock(false) }, 80)
          }
        })
      }
    } catch (error) {
      wakeLockHandle = null
    }
  }

  kickNoSleepVideo(forcePrime)
}

async function releaseWakeLock() {
  try {
    await wakeLockHandle?.release?.()
  } catch (error) {
  } finally {
    wakeLockHandle = null
  }
  try {
    noSleepVideoEl?.pause?.()
  } catch (error) {}
}

function setupWakeLock() {
  const armWakeLock = () => {
    requestWakeLock(true)
    kickNoSleepVideo(true)
  }

  armWakeLock()

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      armWakeLock()
      return
    }
    releaseWakeLock()
  })
  window.addEventListener('focus', armWakeLock)
  window.addEventListener('pageshow', armWakeLock)
  window.addEventListener('resume', armWakeLock)
  document.addEventListener('click', armWakeLock, { passive: true })
  document.addEventListener('touchstart', armWakeLock, { passive: true })
  document.addEventListener('touchend', armWakeLock, { passive: true })
  document.addEventListener('pointerdown', armWakeLock, { passive: true })
  document.addEventListener('mousedown', armWakeLock, { passive: true })
  document.addEventListener('keydown', armWakeLock, { passive: true })

  if (wakeLockRefreshTimer) window.clearInterval(wakeLockRefreshTimer)
  wakeLockRefreshTimer = window.setInterval(() => {
    if (document.visibilityState !== 'visible') return
    requestWakeLock(false)
  }, 1500)

  if (noSleepKeepAliveTimer) window.clearInterval(noSleepKeepAliveTimer)
  noSleepKeepAliveTimer = window.setInterval(() => {
    if (!wakeLockEnabled) return
    if (document.visibilityState !== 'visible') return
    kickNoSleepVideo(false)
  }, 1000)
}

function showAppPopup(text, kind = 'info', duration = 1800) {
  const message = String(text || '').trim()
  if (!message) return
  if (appPopupHideTimer) {
    clearTimeout(appPopupHideTimer)
    appPopupHideTimer = null
  }
  state.appPopupVisible = true
  state.appPopupText = message
  state.appPopupKind = kind || 'info'
  state.appPopupDurationMs = Number(duration) || 1800
  appPopupHideTimer = setTimeout(() => {
    state.appPopupVisible = false
    state.appPopupText = ''
    state.appPopupKind = 'info'
    appPopupHideTimer = null
    render()
  }, state.appPopupDurationMs)
  render()
}

async function copyTextToClipboard(text) {
  const value = String(text ?? '')
  if (!value) return false
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(value)
      return true
    }
  } catch (error) {}

  try {
    const temp = document.createElement('textarea')
    temp.value = value
    temp.setAttribute('readonly', '')
    temp.style.position = 'fixed'
    temp.style.opacity = '0'
    temp.style.pointerEvents = 'none'
    document.body.appendChild(temp)
    temp.focus()
    temp.select()
    const ok = document.execCommand('copy')
    document.body.removeChild(temp)
    return !!ok
  } catch (error) {
    return false
  }
}

function buildCurrentPlaylistCopyText() {
  const playlist = activePlaylist()
  const songs = vshookRootFamilyItems(Array.isArray(playlist?.songs) ? playlist.songs : [])
  if (!playlist || !songs.length) return ''

  const totalText = resolveDirectorPlaylistTotalText(playlist)
  const lines = []
  const playlistName = String(playlist?.name ?? '').trim()
  if (playlistName) lines.push(playlistName)
  lines.push('')
  lines.push(`Tempo total: ${totalText}`)
  lines.push('')

  for (const song of songs) {
    const name = String(song?.name ?? '').trim()
    if (name) lines.push(name)
  }

  return lines.join('\n')
}

async function handleCopyPlaylistNames(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  state.settingsMenuOpen = false
  render()
  const payload = buildCurrentPlaylistCopyText()
  if (!payload) {
    showAppPopup('PLAYLIST VAZIA', 'marker', 1800)
    return
  }
  const ok = await copyTextToClipboard(payload)
  showAppPopup(ok ? 'NOMES COPIADOS' : 'FALHA AO COPIAR', ok ? 'success' : 'marker', ok ? 1800 : 2200)
}

function findSongNameById(songId, source = null) {
  const key = String(songId ?? '')
  if (!key) return ''
  const data = source || state
  const playlists = Array.isArray(data.playlists) ? data.playlists : []
  for (const playlist of playlists) {
    const songs = vshookRootFamilyItems(Array.isArray(playlist?.songs) ? playlist.songs : [])
    const match = songs.find((song) => String(song?.id) === key)
    if (match?.name) return String(match.name)
  }
  const regions = Array.isArray(data.regions) ? data.regions : []
  const region = regions.find((item) => String(item?.id) === key)
  return region?.name ? String(region.name) : ''
}

function findMarkerLabelById(markerId, source = null) {
  const key = String(markerId ?? '')
  if (!key) return ''
  const data = source || state
  const markers = Array.isArray(data.markers) ? data.markers : []
  const marker = markers.find((item) => String(item?.id) === key)
  return marker?.label ? String(marker.label) : ''
}

function findMarkerById(markerId, source = null) {
  const key = String(markerId ?? '')
  if (!key) return null
  const data = source || state
  const markers = Array.isArray(data.markers) ? data.markers : []
  return markers.find((item) => String(item?.id) === key) || null
}

function findPlayingRegionById(songId, source = null) {
  const key = String(songId ?? '')
  if (!key) return null
  const data = source || state
  const regions = Array.isArray(data.regions) ? data.regions : []
  return regions.find((item) => String(item?.id) === key) || null
}

function getNowPlayingLabel() {
  const playingId = state.playingId != null ? String(state.playingId) : ''
  if (!playingId) return ''

  const region = findPlayingRegionById(playingId)
  if (region) {
    return upperText(region.name || region.label || '')
  }

  const playlist = activePlaylist()
  const playlistSong = Array.isArray(playlist?.songs)
    ? playlist.songs.find((item) => String(item?.id ?? item?.songId ?? '') === playingId)
    : null
  if (playlistSong) {
    return upperText(playlistSong.name || playlistSong.label || '')
  }

  for (const playlistItem of Array.isArray(state.playlists) ? state.playlists : []) {
    const found = Array.isArray(playlistItem?.songs)
      ? playlistItem.songs.find((item) => String(item?.id ?? item?.songId ?? '') === playingId)
      : null
    if (found) {
      return upperText(found.name || found.label || '')
    }
  }

  const marker = currentMarkers().find((item) => String(item?.songId ?? item?.id ?? '') === playingId)
  if (marker) {
    return upperText(marker.songName || marker.name || marker.label || '')
  }

  return ''
}

function getQueuedSongLabel() {
  const queuedId = getVisualQueuedSongId ? getVisualQueuedSongId() : (state.queuedSongId != null ? String(state.queuedSongId) : '')
  if (!queuedId) return ''
  const song = findSongByIdEverywhere(queuedId)
  if (!song || detectBlockItem(song) || isHashChildItem(song)) return ''
  return upperText(song.name || song.label || '')
}

function setLocalQueuedSong(id, tab = null) {
  const key = String(id || '')
  state.localQueuedSongId = key || null
  state.localQueuedSongAt = key ? Date.now() : 0
  state.localQueuedSongTab = key ? (tab || state.activeTab || null) : null
}

function clearLocalQueuedSong() {
  state.localQueuedSongId = null
  state.localQueuedSongAt = 0
  state.localQueuedSongTab = null
}

function clearVisualQueueForDirector(ms = REMOTE_QUEUE_IGNORE_MS) {
  clearLocalQueuedSong()
  state.queuedSongId = null
  remoteQueuedIgnoreUntil = Math.max(Number(remoteQueuedIgnoreUntil || 0), Date.now() + Math.max(400, Number(ms) || REMOTE_QUEUE_IGNORE_MS))
}

function getLocalQueuedSongIdForRows() {
  if (state.localQueuedSongId != null && String(state.localQueuedSongId) !== '') {
    const age = Date.now() - Number(state.localQueuedSongAt || 0)
    if (age >= 0 && age <= 12000) return String(state.localQueuedSongId)
    clearLocalQueuedSong()
  }
  return null
}

function renderNowPlayingBanner() {
  const playingLabel = getNowPlayingLabel() || '--'
  const queuedLabel = getQueuedSongLabel() || '--'
  return `<div class="liveQueueStatusPanel" data-live-queue-status="1">
    <div class="liveQueueStatusRow liveQueueStatusPlaying"><span class="liveQueueStatusPrefix">EM REPRODUÇÃO</span><span class="liveQueueStatusText">${escapeHtml(playingLabel)}</span></div>
    <div class="liveQueueStatusRow liveQueueStatusQueued"><span class="liveQueueStatusPrefix">FILA DE ESPERA</span><span class="liveQueueStatusText">${escapeHtml(queuedLabel)}</span></div>
  </div>`
}


function normalizeLyricsText(value) {
  return String(value ?? '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .replace(/\\n/g, '\n')
}

function lyricsTextToHtml(value) {
  return escapeHtml(normalizeLyricsText(value)).replace(/\n/g, '<br>')
}

function getItemLyricsText(item) {
  if (!item || typeof item !== 'object') return ''
  return normalizeLyricsText(item.lyricsText ?? item.lyrics ?? '')
}

function findSongByIdEverywhere(songId) {
  const key = String(songId ?? '')
  if (!key) return null

  const region = state.regions.find((item) => String(item?.id ?? item?.songId ?? '') === key)
  if (region) return region

  const active = activePlaylist()
  const activeSong = Array.isArray(active?.songs)
    ? active.songs.find((item) => String(item?.id ?? item?.songId ?? '') === key)
    : null
  if (activeSong) return activeSong

  for (const playlist of Array.isArray(state.playlists) ? state.playlists : []) {
    const song = Array.isArray(playlist?.songs)
      ? playlist.songs.find((item) => String(item?.id ?? item?.songId ?? '') === key)
      : null
    if (song) return song
  }

  return null
}


function getSelectedPlaylistSongItem() {
  const id = String(state.selectedPlaylistSongId || '')
  if (!id) return null
  const playlist = activePlaylist()
  return Array.isArray(playlist?.songs) ? playlist.songs.find((item) => String(item?.id ?? item?.songId ?? '') === id) || null : null
}

function getSelectedRegionItem() {
  const id = String(state.selectedRegionId || '')
  if (!id) return null
  return Array.isArray(state.regions) ? state.regions.find((item) => String(item?.id ?? item?.songId ?? '') === id) || null : null
}

function getCurrentLyricsProgressPercent() {
  const song = getCurrentLyricsSong()
  const progress = getLyricsProgressRatio(song)
  return Math.max(0, Math.min(100, Math.round(progress * 1000) / 10))
}

function syncLyricsPanelDom() {
  if (!state.lyricsPanelOpen) return
  const fill = document.querySelector('[data-lyrics-progress-fill]')
  if (fill) fill.style.width = `${getCurrentLyricsProgressPercent()}%`

  const titleNode = document.querySelector('[data-lyrics-title]')
  const song = getCurrentLyricsSong()
  const title = getLyricsSongTitle(song)
  if (titleNode && titleNode.textContent !== title) {
    titleNode.textContent = title
  }

  if (!state.lyricsEditing) {
    const textNode = document.querySelector('[data-lyrics-text-view]')
    if (textNode && song) {
      const nextText = getItemLyricsText(song) || 'SEM LETRA CADASTRADA'
      if (textNode.getAttribute('data-lyrics-source') !== nextText) {
        textNode.setAttribute('data-lyrics-source', nextText)
        textNode.innerHTML = lyricsTextToHtml(nextText)
      }
    }
  }
}


function getCurrentLyricsSong() {
  if (state.playingId != null && String(state.playingId) !== '') {
    const playing = findSongByIdEverywhere(state.playingId)
    if (playing) return playing
  }

  if (state.activeTab === 'playlist' && state.selectedPlaylistSongId) {
    const selected = findSongByIdEverywhere(state.selectedPlaylistSongId)
    if (selected) return selected
  }

  if (state.selectedRegionId) {
    const selected = findSongByIdEverywhere(state.selectedRegionId)
    if (selected) return selected
  }

  return null
}

function getLyricsSongTitle(song) {
  if (!song) return 'NENHUMA MÚSICA SELECIONADA'
  return upperText(song.name || song.label || 'MÚSICA')
}

function getLyricsProgressRatio(song) {
  if (!song) return 0
  const duration = Number(song.durationSec) || 0
  if (duration <= 0) return 0
  const remaining = Number(song.remainingSec)
  if (!Number.isFinite(remaining)) return 0
  return Math.max(0, Math.min(1, (duration - remaining) / duration))
}

function openLyricsPanel() {
  const selectedSong = state.activeTab === 'playlist' ? getSelectedPlaylistSongItem() : getSelectedRegionItem()
  if (selectedSong && detectBlockItem(selectedSong)) {
    showAppPopup('BLOCO NÃO TEM LETRA', 'error', 1300)
    return
  }

  const song = getCurrentLyricsSong()
  if (song && detectBlockItem(song)) {
    showAppPopup('BLOCO NÃO TEM LETRA', 'error', 1300)
    return
  }

  state.lyricsPanelOpen = true
  state.lyricsEditing = false
  state.lyricsEditingSongId = song ? String(song.id ?? song.songId ?? '') : null
  state.lyricsDraft = song ? getItemLyricsText(song) : ''
  state.settingsMenuOpen = false
  render()
}

function closeLyricsPanel() {
  state.lyricsPanelOpen = false
  state.lyricsEditing = false
  state.lyricsDraft = ''
  state.lyricsEditingSongId = null

  // Ao voltar da tela de letras, sempre retorna para a tela principal.
  // Não deixa pular direto entre Letras e Markers.
  if (state.activeTab === 'playlist' && state.playlistView === 'markers') {
    state.localMarkersMode = false
    state.playlistView = 'songs'
    postCommand('set_page', { page: 'playlist' })
    postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
  }

  render()
}

function cancelLyricsEditAndClosePanel() {
  const song = getCurrentLyricsSong()
  state.lyricsEditing = false
  state.lyricsEditingSongId = song ? String(song.id ?? song.songId ?? '') : null
  state.lyricsDraft = song ? getItemLyricsText(song) : ''
  closeLyricsPanel()
}

function startLyricsEdit() {
  const song = getCurrentLyricsSong()
  if (!song) return
  state.lyricsEditing = true
  state.lyricsEditingSongId = String(song.id ?? song.songId ?? '')
  state.lyricsDraft = getItemLyricsText(song)
  render()
}

function cancelLyricsEdit() {
  const song = getCurrentLyricsSong()
  state.lyricsEditing = false
  state.lyricsEditingSongId = song ? String(song.id ?? song.songId ?? '') : null
  state.lyricsDraft = song ? getItemLyricsText(song) : ''
  render()
}

function confirmLyricsEdit() {
  const song = getCurrentLyricsSong()
  if (!song) return
  const id = String(song.id ?? song.songId ?? '')
  if (!id) return
  const value = String(state.lyricsDraft || '').slice(0, 4000)

  // Atualização otimista local para refletir imediatamente no painel.
  song.lyrics = value
  song.lyricsText = value
  song.hasLyrics = value.trim().length > 0

  const lyricsPayload = {
    id,
    targetId: id,
    selectedRegionId: id,
    songId: id,
    uid: song.uid,
    source_number: song.source_number ?? song.sourceNumber ?? song.number,
    name: song.name || song.label || '',
    lyricsText: value,
    lyrics: value,
    aliases: [song.uid, song.source_number, song.sourceNumber, song.number].filter((item) => item !== undefined && item !== null && String(item).trim() !== ''),
  }
  saveLyricsJson(lyricsPayload)
  postCommand('update_lyrics', lyricsPayload)
  state.lyricsEditing = false
  state.lyricsEditingSongId = id
  state.lyricsDraft = value
  render()
}

function renderLyricsPanel() {
  if (!state.lyricsPanelOpen) return ''
  const song = getCurrentLyricsSong()
  const songId = song ? String(song.id ?? song.songId ?? '') : ''

  if (!state.lyricsEditing && song && state.lyricsEditingSongId !== songId) {
    state.lyricsEditingSongId = songId
    state.lyricsDraft = getItemLyricsText(song)
  }

  const title = getLyricsSongTitle(song)
  const lyricsText = state.lyricsEditing ? String(state.lyricsDraft || '') : (song ? getItemLyricsText(song) : '')
  const progress = getLyricsProgressRatio(song)
  const progressStyle = `width:${Math.round(progress * 1000) / 10}%`
  const disabledEdit = song ? '' : 'disabled'

  const leftButtonHtml = state.lyricsEditing
    ? `<button class="lyricsEditButton lyricsCancelTopButton" data-action="lyrics-cancel">Cancelar</button>`
    : `<button class="lyricsEditButton lyricsBlueButton" data-action="lyrics-edit" ${disabledEdit}>Editar</button>`
  const rightButtonHtml = state.lyricsEditing
    ? `<button class="lyricsBackButton lyricsOkTopButton" data-action="lyrics-confirm">OK</button>`
    : `<button class="lyricsBackButton lyricsBlueButton" data-action="close-lyrics-panel">&gt;&gt;</button>`

  return `<div class="lyricsScreen ${state.lyricsEditing ? 'lyricsScreenEditing' : ''}">
    <div class="lyricsTopBar">
      ${leftButtonHtml}
      <div class="lyricsNowPlaying">
        <div class="lyricsNowPlayingTitle" data-lyrics-title>${escapeHtml(title)}</div>
        <div class="lyricsProgressTrack"><div class="lyricsProgressFill" data-lyrics-progress-fill style="${progressStyle}"></div></div>
      </div>
      ${rightButtonHtml}
    </div>
    <div class="lyricsBody">
      ${state.lyricsEditing
        ? `<textarea id="lyricsEditorInput" class="lyricsEditorInput" maxlength="4000" autocomplete="off" autocorrect="off" spellcheck="false" placeholder="Digite a letra da música...">${escapeHtml(lyricsText)}</textarea><div class="lyricsCharCount">${String(lyricsText || '').length} / 4000</div><div class="lyricsEditorScrollPad" aria-hidden="true"></div>`
        : `<div class="lyricsTextView" data-lyrics-text-view data-lyrics-source="${escapeHtml(lyricsText || 'SEM LETRA CADASTRADA')}">${lyricsTextToHtml(lyricsText || 'SEM LETRA CADASTRADA')}</div>`}
    </div>
  </div>`
}


function updateLyricsEditorViewportVars() {
  const root = document.documentElement
  const vv = window.visualViewport
  const visualHeight = Math.max(360, Math.floor(Number(vv?.height || window.innerHeight || 640)))
  const layoutHeight = Math.max(visualHeight, Math.floor(Number(window.innerHeight || visualHeight)))
  const offsetTop = Math.max(0, Math.floor(Number(vv?.offsetTop || 0)))
  const rawKeyboard = Math.max(0, layoutHeight - visualHeight - offsetTop)
  const inputFocused = document.activeElement && document.activeElement.id === 'lyricsEditorInput'
  const keyboardPad = inputFocused ? Math.max(150, rawKeyboard + 118) : 80
  root.style.setProperty('--lyrics-visible-height', `${visualHeight}px`)
  root.style.setProperty('--lyrics-keyboard-pad', `${keyboardPad}px`)
}

function resizeLyricsEditorInput() {
  const input = document.getElementById('lyricsEditorInput')
  if (!input) return
  updateLyricsEditorViewportVars()

  // Não auto-expande o textarea.
  // Auto height + enter fazia o navegador empurrar o editor para cima
  // e a letra entrava por trás da barra superior.
  input.style.height = ''
  input.style.minHeight = ''
}

function scheduleLyricsEditorResizeAndScroll() {
  // Atualiza apenas a área visível quando o teclado abre/fecha.
  // O scroll fica dentro do editor de tela cheia, sem mover a tela inteira.
  window.requestAnimationFrame(() => {
    updateLyricsEditorViewportVars()
  })
}

function getPlayingElapsedSec(source = null) {
  const data = source || state
  const playingId = data?.playingId != null ? String(data.playingId) : ''
  if (!playingId) return null
  const region = findPlayingRegionById(playingId, data)
  if (!region) return null
  const duration = Number(region.durationSec)
  const remaining = Number(region.remainingSec)
  if (!Number.isFinite(duration) || !Number.isFinite(remaining)) return null
  return Math.max(0, duration - remaining)
}

function maybeShowMarkerProximityPopup(source = null) {
  const data = source || state
  const playingId = data?.playingId != null ? String(data.playingId) : ''
  if (!playingId) {
    lastProximityPopupMarkerId = null
    return
  }

  const elapsedSec = getPlayingElapsedSec(data)
  if (!Number.isFinite(elapsedSec)) {
    lastProximityPopupMarkerId = null
    return
  }

  const markers = Array.isArray(data.markers) ? data.markers : []
  const selectedMarkerId = data?.selectedMarkerId != null ? String(data.selectedMarkerId) : ''

  let candidate = null
  let candidateId = null

  if (selectedMarkerId) {
    const selectedMarker = markers.find((item) => String(item?.id) === selectedMarkerId)
    if (selectedMarker && String(selectedMarker.songId ?? '') === playingId) {
      const targetSec = Number(selectedMarker.timeSec)
      const distance = targetSec - elapsedSec
      if (Number.isFinite(distance) && distance >= 0 && distance <= 4) {
        candidate = selectedMarker
        candidateId = selectedMarkerId
      } else if (Number.isFinite(distance) && distance > 4 && lastProximityPopupMarkerId === selectedMarkerId) {
        lastProximityPopupMarkerId = null
      }
    }
  }

  if (!candidate) {
    let bestDistance = Infinity
    for (const marker of markers) {
      if (String(marker?.songId ?? '') !== playingId) continue
      const targetSec = Number(marker?.timeSec)
      const distance = targetSec - elapsedSec
      if (!Number.isFinite(distance) || distance < 0 || distance > 4) continue
      if (distance < bestDistance) {
        bestDistance = distance
        candidate = marker
        candidateId = String(marker?.id ?? '')
      }
    }
    if (!candidate && lastProximityPopupMarkerId) {
      lastProximityPopupMarkerId = null
    }
  }

  if (!candidate || !candidateId) return
  if (lastProximityPopupMarkerId === candidateId) return

  const label = upperText(candidate.label || candidate.name || 'Marker')
  showAppPopup(label, 'marker', 5000)
  lastProximityPopupMarkerId = candidateId
}



function ensureBootLoader() {
  let loader = document.getElementById('appBootLoader')
  if (loader) return loader
  loader = document.createElement('div')
  loader.id = 'appBootLoader'
  loader.className = 'appBootLoader'
  loader.innerHTML = `
    <div class="appBootLoaderInner">
      <img class="appBootLoaderIcon" alt="VS Hook" src="${LOADING_ICON_DATA_URL}" />
      <div class="appBootLoaderGlow"></div>
      <div class="appBootLoaderText">CARREGANDO</div>
      <div class="appBootLoaderSubtext">AGUARDE...</div>
    </div>
  `
  document.body.appendChild(loader)
  return loader
}

function showBootLoader() {
  appLoadingVisible = true
  const loader = ensureBootLoader()
  loader.classList.remove('appBootLoaderHidden')
  document.body.classList.add('boot-loading')
}

function hideBootLoader(force = false) {
  const loader = document.getElementById('appBootLoader')
  if (!loader) return
  const elapsed = Date.now() - appBootStartedAt
  const remaining = force ? 0 : Math.max(0, APP_LOADING_MIN_MS - elapsed)
  window.setTimeout(() => {
    loader.classList.add('appBootLoaderHidden')
    document.body.classList.remove('boot-loading')
    appLoadingVisible = false
    render()
  }, remaining)
}

function markDirectorLocalInput(ms = 700) {
  const holdMs = Math.max(240, Number(ms) || 0)
  directorLocalInputHoldUntil = Math.max(Number(directorLocalInputHoldUntil || 0), Date.now() + holdMs)
}

function installDirectorInputRenderGuard() {
  if (window.__vshookDirectorInputRenderGuard === '1') return
  window.__vshookDirectorInputRenderGuard = '1'
  const selector = 'button,[data-action],[data-region-id],[data-song-id],[data-marker-id],input,textarea,select,.mixerRow,.premixSongCard,.modalBox,.settingsMenu'
  const guard = (event) => {
    try {
      if (event?.target?.closest?.(selector)) markDirectorLocalInput(1250)
    } catch (error) {}
  }
  document.addEventListener('pointerdown', guard, true)
  document.addEventListener('touchstart', guard, { capture: true, passive: true })
}


const outgoingDirectorCommandDedupe = new Map()

function getOutgoingCommandTargetKey(payload = {}) {
  return String(
    payload.selectedPlaylistSongId ||
    payload.selectedRegionId ||
    payload.songId ||
    payload.targetId ||
    payload.id ||
    payload.familyGroupId ||
    ''
  )
}

function shouldBlockOutgoingDuplicateCommand(type, payload = {}) {
  const commandType = String(type || '')
  if (!['play_start', 'play_stop', 'play_toggle', 'director_play_button', 'play_button'].includes(commandType)) return false
  const desired = String(payload.desiredState || payload.desiredPlaying || payload.forcePlay || payload.forceStop || '')
  const key = `${commandType}:${desired}:${payload.activeTab || payload.page || ''}:${getOutgoingCommandTargetKey(payload)}`
  const now = Date.now()
  const last = Number(outgoingDirectorCommandDedupe.get(key) || 0)
  outgoingDirectorCommandDedupe.set(key, now)
  return last > 0 && (now - last) < 900
}

function makeDirectorClientCommandId(type, payload = {}) {
  return `${Date.now()}-${String(type || 'cmd')}-${getOutgoingCommandTargetKey(payload) || 'none'}-${Math.random().toString(16).slice(2, 8)}`
}


function sanitizeDirectorOutgoingCommandPayload(commandType, payload = {}) {
  const out = payload && typeof payload === 'object' ? { ...payload } : {}
  const type = String(commandType || '')
  const isQueue = type === 'queue_playlist_song' || type === 'queue_region_song' || type === 'clear_queue'
  if (isQueue) {
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
    out.queueOnly = type !== 'clear_queue'
    out.noTransport = true
    out.keepPlaying = true
    out.noSeek = true
    out.preserveCursor = true
  }
  if (type === 'transport_stop_no_seek' || type === 'director_stop_no_seek' || type === 'play_stop_no_seek') {
    const keep = {
      role: out.role || 'director',
      clientRole: out.clientRole || 'director',
      appRole: out.appRole || 'director',
      source: out.source || 'director',
      mode: out.mode || 'director',
      activeTab: out.activeTab || state.activeTab || 'playlist',
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
      stopSelectionTargetId: out.stopSelectionTargetId,
      stopSelectionTargetTab: out.stopSelectionTargetTab,
      stopSelectionTargetSource: out.stopSelectionTargetSource,
    }
    Object.keys(keep).forEach((k) => keep[k] === undefined && delete keep[k])
    return keep
  }
  return out
}

function postCommand(type, payload = {}) {
  markDirectorLocalInput(700)
  const commandType = String(type || '')
  const commandPayload = sanitizeDirectorOutgoingCommandPayload(commandType, payload)
  commandPayload.role = commandPayload.role || 'director'
  commandPayload.clientRole = commandPayload.clientRole || 'director'
  commandPayload.appRole = commandPayload.appRole || 'director'
  commandPayload.source = commandPayload.source || 'director'
  commandPayload.mode = commandPayload.mode || 'director'

  if (shouldBlockOutgoingDuplicateCommand(commandType, commandPayload)) {
    return Promise.resolve(null)
  }
  commandPayload.clientCommandId = commandPayload.clientCommandId || makeDirectorClientCommandId(commandType, commandPayload)

  const body = JSON.stringify({ type: commandType, payload: commandPayload })
  const send = (retry = false) => fetch(vshookBridgeUrl('/command'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: retry
      ? JSON.stringify({ type: commandType, payload: { ...commandPayload, appRetry: true } })
      : body,
  }).catch(() => {})

  // Envia uma única vez. Duplicar play_start/play_stop fazia o Lua receber
  // um segundo comando logo após o primeiro Play; em algumas rotas internas isso
  // era interpretado como alternância e derrubava o transporte segundos depois.
  return send(false)
}

function saveLyricsJson(payload = {}) {
  return fetch(vshookBridgeUrl('/lyrics'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(() => {})
}

const actionPressState = new Map()
const unifiedTapState = new Map()

function isDuplicatePress(actionKey, windowMs = 320) {
  const key = String(actionKey || '')
  const now = Date.now()
  const last = Number(actionPressState.get(key) || 0)
  actionPressState.set(key, now)
  return last > 0 && (now - last) < windowMs
}


const DIRECTOR_TRANSPORT_PROTECTION_KEY = 'vshook_director_transport_protection_enabled'
function isDirectorTransportProtectionEnabled() {
  try {
    const saved = localStorage.getItem(DIRECTOR_TRANSPORT_PROTECTION_KEY)
    if (saved === '1') return true
    if (saved === '0') return false
  } catch (error) {}
  return state.transportProtectionEnabled === true
}
function setDirectorTransportProtectionEnabled(enabled, notify = true) {
  const value = !!enabled
  state.transportProtectionEnabled = value
  try { localStorage.setItem(DIRECTOR_TRANSPORT_PROTECTION_KEY, value ? '1' : '0') } catch (error) {}
  if (notify) {
    postCommand('transport_protection_set', { enabled: value ? '1' : '0', desiredState: value ? 'on' : 'off' })
  }
  render()
}
function toggleDirectorTransportProtection(event = null) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  setDirectorTransportProtectionEnabled(!isDirectorTransportProtectionEnabled(), true)
}
function getDirectorProtectionSettingsHtml() {
  const active = isDirectorTransportProtectionEnabled()
  return `<div class="settingsSectionTitle">PROTECTION</div><div class="settingsGrid settingsGridSingle"><button class="settingsToggleBtn settingsToggleWide ${active ? 'settingsToggleBtnActive' : ''}" data-action="toggle-protection">PLAY/STOP DUPLO TOQUE: ${active ? 'ON' : 'OFF'}</button></div>`
}

const directorTapDedupeState = new Map()

function getDirectorTapPoint(event) {
  const touch = event?.changedTouches?.[0] || event?.touches?.[0]
  if (touch) return { x: Number(touch.clientX) || 0, y: Number(touch.clientY) || 0 }
  return { x: Number(event?.clientX) || 0, y: Number(event?.clientY) || 0 }
}

function bindDirectorTapAction(el, actionKey, handler, options = {}) {
  if (!el || typeof handler !== 'function') return
  const key = String(actionKey || Math.random())
  const holdMs = Math.max(420, Number(options.holdMs) || 650)
  const moveLimit = Math.max(8, Number(options.moveLimit) || 16)
  let startX = null
  let startY = null
  let lastPhysicalAt = 0
  let lastPhysicalSource = ''
  let suppressSyntheticClickUntil = 0

  const rememberStart = (event) => {
    const point = getDirectorTapPoint(event)
    startX = point.x
    startY = point.y
    markDirectorLocalInput(holdMs)
  }

  const movedTooMuch = (event) => {
    if (startX == null || startY == null) return false
    const point = getDirectorTapPoint(event)
    return Math.abs(point.x - startX) > moveLimit || Math.abs(point.y - startY) > moveLimit
  }

  const run = (event, source) => {
    if (options.hashGuard && Number(el.__hashLongPressJustFiredUntil || 0) > Date.now()) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      event?.stopImmediatePropagation?.()
      return
    }
    if (event?.button != null && event.button !== 0) return
    if ((source === 'pointerup' || source === 'touchend') && movedTooMuch(event)) return

    const now = Date.now()
    const isPhysical = source === 'pointerup' || source === 'touchend'

    // FIX B: a trava antiga de 320ms matava o segundo toque real.
    // Agora só descartamos o evento duplicado gerado pelo mesmo toque
    // (pointerup + touchend/click). Outro toque real, mesmo rápido, passa.
    if (isPhysical) {
      if (lastPhysicalAt > 0 && now - lastPhysicalAt < 70 && lastPhysicalSource !== source) {
        event?.preventDefault?.()
        event?.stopPropagation?.()
        event?.stopImmediatePropagation?.()
        return
      }
      lastPhysicalAt = now
      lastPhysicalSource = source
      suppressSyntheticClickUntil = now + 360
    } else if (source === 'click') {
      if (suppressSyntheticClickUntil && now < suppressSyntheticClickUntil) {
        event?.preventDefault?.()
        event?.stopPropagation?.()
        event?.stopImmediatePropagation?.()
        return
      }
    }

    directorTapDedupeState.set(key, now)
    event?.preventDefault?.()
    event?.stopPropagation?.()
    markDirectorLocalInput(holdMs)
    handler(event)
  }

  el.addEventListener('pointerdown', rememberStart, { passive: true })
  el.addEventListener('touchstart', rememberStart, { passive: true })
  el.addEventListener('pointerup', (event) => run(event, 'pointerup'), { passive: false })
  el.addEventListener('touchend', (event) => run(event, 'touchend'), { passive: false })
  el.addEventListener('click', (event) => run(event, 'click'))
}

function bindPressAction(el, actionKey, handler) {
  bindDirectorTapAction(el, actionKey, handler, { holdMs: 1100 })
}


const tunerTapSyntheticClickState = new Map()

function bindTunerRapidTapAction(el, actionKey, handler) {
  if (!el || typeof handler !== 'function') return

  const key = String(actionKey || '')
  const run = (event) => {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    handler(event)
  }

  el.addEventListener('pointerup', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return
    tunerTapSyntheticClickState.set(key, Date.now())
    run(event)
  }, { passive: false })

  el.addEventListener('click', (event) => {
    const lastPointerAt = Number(tunerTapSyntheticClickState.get(key) || 0)
    if (lastPointerAt > 0 && (Date.now() - lastPointerAt) < 260) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      return
    }
    run(event)
  })
}

function bindImmediateTapAction(el, actionKey, handler) {
  bindDirectorTapAction(el, actionKey, handler, { holdMs: 900 })
}



function bindReliableTapAction(el, actionKey, handler) {
  bindDirectorTapAction(el, actionKey, handler, { holdMs: 1050, hashGuard: true })
}



// VS_HOOK_DIRECTOR_BRUTAL_FAST_TAP_B
// Delegação em capture para responder no pointerup/touchend antes dos handlers antigos.
// Resolve o atraso de botões que ainda estavam presos no click sintético do WebView
// e impede que o segundo toque real seja confundido com duplicidade.
let __vshookFastTapStart = null
let __vshookFastTapLastSig = ''
let __vshookFastTapLastAt = 0
let __vshookFastTapSuppressClickUntil = 0
function __vshookFastTapPoint(event) {
  const touch = event?.changedTouches?.[0] || event?.touches?.[0]
  if (touch) return { x: Number(touch.clientX) || 0, y: Number(touch.clientY) || 0 }
  return { x: Number(event?.clientX) || 0, y: Number(event?.clientY) || 0 }
}
function __vshookFastTapSignature(target) {
  try {
    const action = target?.closest?.('[data-action]')?.getAttribute('data-action') || ''
    const row = target?.closest?.('[data-song-id],[data-region-id],[data-marker-id]')
    const rowId = row?.getAttribute?.('data-song-id') || row?.getAttribute?.('data-region-id') || row?.getAttribute?.('data-marker-id') || ''
    return `${action}|${rowId}`
  } catch (_) { return '' }
}
function __vshookRenderFastNow() {
  try {
    if (typeof render === 'function' && typeof render.now === 'function') return render.now()
    if (typeof render === 'function') return render()
  } catch (error) {}
}
function __vshookCallFastTapHandler(action, el, event) {
  switch (action) {
    case 'toggle-settings': return handleToggleSettingsMenu?.(event), true
    case 'open-gear': event?.preventDefault?.(); event?.stopPropagation?.(); openGearModal?.(); return true
    case 'close-gear': closeGearModal?.(); return true
    case 'open-recados': openRecadosModal?.(); return true
    case 'recados-close': closeRecadosModal?.(); return true
    case 'open-project-tabs': openProjectTabsModal?.(); return true
    case 'close-project-tabs': closeProjectTabsModal?.(); return true
    case 'confirm-project-tabs': confirmProjectTabsModal?.(); return true
    case 'go-playlist': openPlaylist?.(); return true
    case 'go-regions': openRegions?.(); return true
    case 'open-markers': openMarkersPanel?.(); return true
    case 'close-markers': closeMarkersPanel?.(); return true
    case 'open-mixer': openMixerModal?.('tracks'); return true
    case 'close-mixer': closeMixerModal?.(true); return true
    case 'close-mixer-volume': closeMixerVolumeModal?.(true); return true
    case 'open-bpm': openBpmModal?.(event); return true
    case 'close-bpm': closeBpmModal?.(true); return true
    case 'open-tuner': openTunerModal?.(event); return true
    case 'close-tuner': closeTunerModal?.(true); return true
    case 'open-lyrics-panel': openLyricsPanel?.(event); return true
    case 'close-lyrics-panel': closeLyricsPanel?.(event); return true
    case 'play': handlePlayToggle?.(event); return true
    case 'autoplay': handleAutoplayToggle?.(event); return true
    case 'auto-bloco': handleAutoBlocoToggle?.(event); return true
    case 'loop': handleLoopToggle?.(event); return true
    case 'marker-cancel': handleMarkerCancel?.(event); return true
    case 'theme-light': setTheme?.('light'); return true
    case 'theme-dark': setTheme?.('dark'); return true
    case 'toggle-protection': toggleDirectorTransportProtection?.(event); return true
    case 'cycle-rgb-mode': cycleRgbMode?.(event); return true
    case 'toggle-select': handleSelectAction?.(event); return true
    case 'copy-playlist-names': handleCopyPlaylistNames?.(event); return true
    case 'edit-done': handleEditDone?.(event); return true
    case 'delete-confirm': handleDeleteConfirm?.(event); return true
    case 'delete-cancel': handleDeleteCancel?.(event); return true
    case 'delete-selected': handleDeleteSelectedPlaylistItems?.(event); return true
    case 'all': handleSelectAll?.(event); return true
    case 'add-list': handleOpenCreatePlaylist?.(event); return true
    case 'add-exist': handleOpenAddExisting?.(event); return true
    case 'close-create': handleCloseCreatePlaylist?.(event); return true
    case 'confirm-create': handleConfirmCreatePlaylist?.(event); return true
    case 'close-existing': handleCloseAddExisting?.(event); return true
    case 'confirm-existing': handleConfirmAddExisting?.(event); return true
    case 'close-playlist-switch': closePlaylistSwitchModal?.(event); return true
    case 'confirm-playlist-switch': handleConfirmPlaylistSwitch?.(event); return true
    case 'close-rename': handleCloseRenameModal?.(event); return true
    case 'confirm-rename': handleConfirmRenameModal?.(event); return true
    case 'lyrics-edit': startLyricsEdit?.(event); return true
    case 'lyrics-confirm': confirmLyricsEdit?.(event); return true
    case 'lyrics-cancel': cancelLyricsEdit?.(event); return true
    case 'bpm-plus': handleBpmAdjust?.(1, event); return true
    case 'bpm-minus': handleBpmAdjust?.(-1, event); return true
    case 'tuner-reset': handleTunerReset?.(event); return true
    case 'mixer-view-tracks': setMixerView?.('tracks'); return true
    case 'mixer-view-groups': setMixerView?.('groups'); return true
    case 'mixer-view-master': setMixerView?.('master'); return true
    case 'mixer-volume-reset': handleMixerVolumeReset?.(event, state.mixerVolumeView, state.mixerSelectedId); return true
    case 'premix-onoff': handlePremixOnOffToggle?.(event); return true
    case 'premix-global-reset': handlePremixGlobalReset?.(event); return true
    case 'premix-play': handlePremixPlaySelected?.(event); return true
    case 'premix-back': backPremixSongList?.(event); return true
    case 'premix-view-tracks': setPremixTrackView?.('tracks'); return true
    case 'premix-view-groups': setPremixTrackView?.('groups'); return true
    case 'close-premix': closePremixModal?.(true); return true
    case 'close-premix-volume': closePremixVolumeModal?.(true); return true
    case 'premix-volume-reset': handlePremixVolumeReset?.(event, el?.getAttribute?.('data-premix-view') || state.premixTrackView, el?.getAttribute?.('data-premix-track-id') || state.premixSelectedTrackId); return true
    default: return false
  }
}
function installDirectorFastTapDelegation() {
  if (window.__vshookDirectorFastTapDelegationB === '1') return
  window.__vshookDirectorFastTapDelegationB = '1'
  const interactiveSelector = '[data-action],[data-song-id],[data-region-id],[data-marker-id],[data-project-tab-index],[data-switch-playlist-id],[data-existing-playlist-id]'
  const shouldIgnoreTarget = (target) => {
    try {
      if (!target?.closest) return true
      if (target.closest('input[type="range"],textarea,input:not([type="button"]):not([type="submit"]),select')) return true
      return false
    } catch (_) { return true }
  }
  const start = (event) => {
    const p = __vshookFastTapPoint(event)
    __vshookFastTapStart = { x: p.x, y: p.y, target: event.target }
  }
  const run = (event, source) => {
    const target = event.target
    if (shouldIgnoreTarget(target)) return
    const hit = target?.closest?.(interactiveSelector)
    if (!hit) return
    const p = __vshookFastTapPoint(event)
    const s = __vshookFastTapStart
    if (s && (Math.abs(p.x - s.x) > 18 || Math.abs(p.y - s.y) > 18)) return
    const sig = __vshookFastTapSignature(target)
    const now = Date.now()
    if (source !== 'click') {
      if (__vshookFastTapLastSig === sig && now - __vshookFastTapLastAt < 70) {
        event.preventDefault?.(); event.stopPropagation?.(); event.stopImmediatePropagation?.(); return
      }
      __vshookFastTapLastSig = sig
      __vshookFastTapLastAt = now
      __vshookFastTapSuppressClickUntil = now + 380
    } else if (__vshookFastTapLastSig === sig && now < __vshookFastTapSuppressClickUntil) {
      event.preventDefault?.(); event.stopPropagation?.(); event.stopImmediatePropagation?.(); return
    }

    const actionEl = target.closest('[data-action]')
    const action = actionEl?.getAttribute?.('data-action') || ''
    let handled = false
    if (action) handled = __vshookCallFastTapHandler(action, actionEl, event)
    if (!handled) {
      const project = target.closest('[data-project-tab-index]')
      if (project && state.showProjectTabsModal) { selectProjectTabInModal?.(project.getAttribute('data-project-tab-index')); handled = true }
    }
    if (!handled) {
      const sw = target.closest('[data-switch-playlist-id]')
      if (sw) { state.selectedSwitchPlaylistId = sw.getAttribute('data-switch-playlist-id'); __vshookRenderFastNow(); handled = true }
    }
    if (!handled) {
      const ex = target.closest('[data-existing-playlist-id]')
      if (ex) { state.selectedExistingPlaylistId = ex.getAttribute('data-existing-playlist-id'); __vshookRenderFastNow(); handled = true }
    }
    if (!handled && !state.editMode && !state.deleteMode) {
      const marker = target.closest('[data-marker-id]')
      const song = target.closest('[data-song-id]')
      const region = target.closest('[data-region-id]')
      if (marker) { selectMarker?.(marker.getAttribute('data-marker-id')); handled = true }
      else if (song) { selectPlaylistSong?.(song.getAttribute('data-song-id')); handled = true }
      else if (region) { selectRegion?.(region.getAttribute('data-region-id')); handled = true }
    }
    if (handled) {
      markDirectorLocalInput?.(650)
      event.preventDefault?.()
      event.stopPropagation?.()
      event.stopImmediatePropagation?.()
    }
  }
  document.addEventListener('pointerdown', start, { capture: true, passive: true })
  document.addEventListener('touchstart', start, { capture: true, passive: true })
  document.addEventListener('pointerup', (event) => run(event, 'pointerup'), { capture: true, passive: false })
  document.addEventListener('touchend', (event) => run(event, 'touchend'), { capture: true, passive: false })
  document.addEventListener('click', (event) => run(event, 'click'), true)
}

function bindPlayTapAction(el, handler) {
  bindDirectorTapAction(el, 'play', handler, { holdMs: 1200 })
}


function bindModalCloseAction(el, actionKey, handler) {
  bindDirectorTapAction(el, actionKey, handler, { holdMs: 900, moveLimit: 24 })
}


function getCurrentPcPageName() {
  return state.activeTab === 'regions' ? 'regions' : 'playlist'
}

function isMarkersPanelOpen() {
  return state.activeTab === 'playlist' && (state.playlistView === 'markers' || state.localMarkersMode)
}

function getDesiredPcPartsVisible() {
  return isMarkersPanelOpen()
}

function armOverlayCloseGuard(ms = 320) {
  overlayCloseGuardUntil = Date.now() + Math.max(180, Number(ms) || 0)
}

function shouldIgnoreOverlayClose() {
  return Date.now() < (overlayCloseGuardUntil || 0)
}

function syncPcBaseViewFromApp() {
  const page = getCurrentPcPageName()
  postCommand('set_page', { page })
  postCommand('set_parts_visibility', { page, visible: getDesiredPcPartsVisible() ? '1' : '0' })
}

function getActiveScrollPageKey() {
  if (state.activeTab === 'regions') return 'regions'
  if (state.playlistView === 'markers' || state.localMarkersMode) return 'markers'
  return 'playlist'
}

function getBridgeScrollRatioForPage(pageKey) {
  if (pageKey === 'markers') return Math.max(0, Math.min(1, Number(state.markersScrollRatio) || 0))
  if (pageKey === 'playlist') return Math.max(0, Math.min(1, Number(state.playlistScrollRatio) || 0))
  return Math.max(0, Math.min(1, Number(state.regionsScrollRatio) || 0))
}

function setBridgeScrollRatioForPage(pageKey, ratio) {
  const safeRatio = Math.max(0, Math.min(1, Number(ratio) || 0))
  if (pageKey === 'markers') state.markersScrollRatio = safeRatio
  else if (pageKey === 'playlist') state.playlistScrollRatio = safeRatio
  else state.regionsScrollRatio = safeRatio
}

function scheduleScrollSyncCommand(pageKey, ratio) {
  // Diretor: scroll local livre. Não envia mais scroll para o Bridge/REAPER,
  // evitando retorno remoto e engasgos enquanto a música toca.
  const safeRatio = Math.max(0, Math.min(1, Number(ratio) || 0))
  setBridgeScrollRatioForPage(pageKey, safeRatio)
}

function bindListScrollSync(listEl) {
  if (!listEl || listEl.__vsHookScrollSyncBound) return
  listEl.__vsHookScrollSyncBound = true

  const markLocalScroll = () => { lastUserScrollAt = Date.now() }
  listEl.addEventListener('touchmove', markLocalScroll, { passive: true })
  listEl.addEventListener('wheel', markLocalScroll, { passive: true })
  listEl.addEventListener('scroll', () => {
    if (Date.now() < (listScrollSyncIgnoreUntil || 0)) return
    lastUserScrollAt = Date.now()
    const maxScroll = Math.max(0, listEl.scrollHeight - listEl.clientHeight)
    const ratio = maxScroll <= 0 ? 0 : (listEl.scrollTop / maxScroll)
    scheduleScrollSyncCommand(getActiveScrollPageKey(), ratio)
  }, { passive: true })
}

function applyBridgeScrollToVisibleList() {
  // Diretor: não recebe mais scroll remoto do Bridge. A movimentação do app
  // fica sempre livre, mesmo em playback.
  return
}

function lockSelectionSync(ms = 1600) {
  state.selectionLockUntil = Date.now() + Math.max(300, Number(ms) || 1600)
}

function isMultiSelectActiveFor(tabName) {
  return state.multiSelectMode && state.multiSelectTab === tabName
}

function isLocalSelectionControlActive() {
  return !!(
    state.editMode ||
    state.deleteMode ||
    state.dragActive ||
    state.dragPending ||
    isMultiSelectActiveFor('regions') ||
    isMultiSelectActiveFor('playlist') ||
    getActiveDirectorLocalSelectionHold()
  )
}

function getSelectedRegionIdsForActions() {
  if (isMultiSelectActiveFor('regions')) {
    return state.selectedRegionIds.map(String)
  }
  return state.selectedRegionId ? [String(state.selectedRegionId)] : []
}

function activePlaylist() {
  if (!state.playlists.length) return null
  return state.playlists.find((p) => String(p.id) === String(state.activePlaylistId)) || state.playlists[0]
}

function directorMarkerNameIsPartsMarker(value) {
  const raw = String(value ?? '').trim()
  if (!raw) return false
  if (raw.startsWith('$')) return true
  // Multi Loops: no Lua os markers válidos começam com *1 ou *2.
  return /^\*\s*[12]/.test(raw)
}

function cleanDirectorPartsMarkerLabel(value) {
  const raw = String(value ?? '').trim()
  if (!raw) return 'Part'
  let cleaned = raw
  if (cleaned.startsWith('$')) {
    cleaned = cleaned.replace(/^\$+\s*/, '')
  } else {
    cleaned = cleaned.replace(/^\*\s*[12]\s*[-:|.]?\s*/, '')
  }
  cleaned = cleaned.trim()
  if (cleaned) return cleaned
  if (/^\*\s*1/.test(raw)) return 'Loop 1'
  if (/^\*\s*2/.test(raw)) return 'Loop 2'
  return 'Part'
}

function normalizeDirectorPartsMarker(marker, sourceSongId, fallbackIndex = 0) {
  if (!marker || typeof marker !== 'object') return null
  const rawLabel = String(marker.label ?? marker.name ?? marker.rawName ?? marker.title ?? marker.displayName ?? 'Marker')
  const rawName = String(marker.rawName ?? marker.name ?? marker.label ?? rawLabel)
  if (!directorMarkerNameIsPartsMarker(rawName) && !directorMarkerNameIsPartsMarker(rawLabel)) return null

  const label = cleanDirectorPartsMarkerLabel(rawName || rawLabel)
  const timeSec = Math.max(0, Number(marker.timeSec ?? marker.time ?? marker.positionSec ?? marker.relativeSec ?? 0) || 0)
  const originalIndex = marker.originalIndex ?? marker.original_index ?? marker.index ?? fallbackIndex
  const rawId = marker.id != null ? String(marker.id) : ''
  const id = rawId && !/^m\d+$/i.test(rawId)
    ? rawId
    : `playlist-marker-${sourceSongId}-m${originalIndex || fallbackIndex || Math.round(timeSec * 1000)}`
  const markerType = String(marker.markerType || marker.type || '').trim()
    || (String(rawName || rawLabel).trim().startsWith('$') ? 'part' : 'multiloop')

  return {
    id,
    label,
    name: label,
    timeSec,
    songId: String(sourceSongId || marker.songId || marker.regionId || marker.parentSongId || ''),
    rawName,
    markerType,
    originalIndex,
  }
}

function collectDirectorPartsMarkersFromSourceItem(sourceItem, sourceSongId) {
  const out = []
  const candidates = []
  if (Array.isArray(sourceItem?.markers)) candidates.push(...sourceItem.markers)
  if (Array.isArray(sourceItem?.parts)) candidates.push(...sourceItem.parts)
  if (Array.isArray(sourceItem?.partMarkers)) candidates.push(...sourceItem.partMarkers)
  candidates.forEach((marker, index) => {
    const normalized = normalizeDirectorPartsMarker(marker, sourceSongId, index + 1)
    if (normalized) out.push(normalized)
  })
  return out
}

function currentMarkers() {
  let sourceSongId = null

  if (state.playingId) {
    sourceSongId = String(state.playingId)
  } else if (state.selectedPlaylistSongId) {
    sourceSongId = String(state.selectedPlaylistSongId)
  } else if (state.selectedRegionId) {
    sourceSongId = String(state.selectedRegionId)
  } else {
    return []
  }

  const sourceItem = findSongByIdEverywhere(sourceSongId)
  const sourceName = String(sourceItem?.name ?? sourceItem?.label ?? sourceItem?.rawName ?? '').trim()
  if (isHashParentItem(sourceItem) || sourceName.startsWith('--')) return []

  const sourceStart = Number(sourceItem?.startPos ?? sourceItem?.start_pos ?? 0)
  const sourceEnd = Number(sourceItem?.endPos ?? sourceItem?.end_pos ?? 0)
  const sourceParentId = String(sourceItem?.parentSourceNumber ?? sourceItem?.parentId ?? sourceItem?.familyParentSongId ?? '')
  const sourceIsChild = isHashChildItem(sourceItem)
  const bridgeMarkers = Array.isArray(state.markers) ? state.markers : []
  const merged = []
  const seen = new Set()
  const pushMarker = (marker, index, forcedRelativeSec = null) => {
    const markerForNormalize = forcedRelativeSec == null ? marker : { ...marker, timeSec: forcedRelativeSec }
    const normalized = normalizeDirectorPartsMarker(markerForNormalize, sourceSongId, index)
    if (!normalized) return
    const key = `${normalized.id}|${normalized.timeSec}|${normalized.rawName}`
    if (seen.has(key)) return
    seen.add(key)
    merged.push(normalized)
  }

  bridgeMarkers.forEach((marker, index) => {
    const markerSongId = String(marker.songId ?? marker.regionId ?? marker.parentSongId ?? '')
    if (markerSongId === sourceSongId) {
      pushMarker(marker, index + 1)
      return
    }

    // Fallback para música-filho: se uma versão antiga do Lua ainda associar o marker ao pai,
    // usa a posição absoluta para jogar a Part dentro do filho correto.
    if (sourceIsChild && sourceParentId && markerSongId === sourceParentId) {
      const absPos = Number(marker.absoluteSec ?? marker.pos ?? marker.startPos)
      if (Number.isFinite(absPos) && Number.isFinite(sourceStart) && Number.isFinite(sourceEnd)
        && absPos >= sourceStart - 0.000001 && absPos <= sourceEnd + 0.000001) {
        pushMarker(marker, index + 1, Math.max(0, Math.round(absPos - sourceStart)))
      }
    }
  })

  collectDirectorPartsMarkersFromSourceItem(sourceItem, sourceSongId).forEach((marker, index) => pushMarker(marker, index + 1))

  merged.sort((a, b) => (Number(a.timeSec) || 0) - (Number(b.timeSec) || 0))
  return merged
}


function normalizeBridgePlaybackStateText(value) {
  return String(value || '').trim().toLowerCase()
}

function bridgeDataSaysPlaying(data) {
  if (!data || typeof data !== 'object') return false
  const stateWords = [data.playState, data.playbackState, data.transportState, data.state]
    .map(normalizeBridgePlaybackStateText)
  return !!(
    data.playing === true ||
    data.isPlaying === true ||
    data.transportPlaying === true ||
    data.scriptPlaying === true ||
    stateWords.includes('playing') ||
    stateWords.includes('play') ||
    stateWords.includes('running')
  )
}

function getPreferredDirectorChildPlayingId(incomingId) {
  const incomingKey = incomingId != null ? String(incomingId) : ''
  const optimisticKey = optimisticPlaybackState?.id != null ? String(optimisticPlaybackState.id) : ''
  const pendingKey = pendingPlaybackDesiredSourceId != null ? String(pendingPlaybackDesiredSourceId) : ''
  const candidates = [optimisticKey, pendingKey, lastPlaybackSelectionId != null ? String(lastPlaybackSelectionId) : ''].filter(Boolean)
  const incomingItem = incomingKey ? findAnyPlaybackItemById(incomingKey) : null
  for (const key of candidates) {
    if (!key || key === incomingKey) continue
    const item = findAnyPlaybackItemById(key)
    if (!item || !isHashChildItem(item)) continue
    if (!incomingItem || areAppItemsSameHashFamily(incomingItem, item)) return key
  }
  return incomingKey || null
}

function bridgeDataSaysStopped(data) {
  if (!data || typeof data !== 'object') return false
  if (bridgeDataSaysPlaying(data)) return false
  const stateWords = [data.playState, data.playbackState, data.transportState]
    .map(normalizeBridgePlaybackStateText)
  return !!(
    data.playing === false ||
    data.isPlaying === false ||
    data.transportPlaying === false ||
    stateWords.includes('stopped') ||
    stateWords.includes('stop') ||
    stateWords.includes('paused') ||
    stateWords.includes('pause')
  )
}

function getIncomingBridgePlayingId(data) {
  if (!data || typeof data !== 'object') return null
  const candidates = [
    data.playingId,
    data.playingSongId,
    data.currentSongId,
    data.currentRegionId,
    data.activeSongId,
    data.activeRegionId,
    data.musicId,
    data.songId,
    data?.currentSong?.id,
    data?.playingSong?.id,
    data?.activeSong?.id,
  ]
  for (const candidate of candidates) {
    if (isUsablePlaybackId(candidate)) return String(candidate)
  }
  // Não usa fallback local aqui. Esta função precisa representar só o que veio do Bridge,
  // para o Diretor conseguir trocar de música quando o Play vem manualmente do REAPER/timeline.
  return null
}

function syncDirectorPlaybackClockFromBridge(data) {
  if (!data || typeof data !== 'object') return
  const durationCandidates = [data.playbackDurationSec, data.durationSec, data?.currentSong?.durationSec, data?.playingSong?.durationSec, data?.activeSong?.durationSec]
  const remainingCandidates = [data.playbackRemainingSec, data.remainingSec, data?.currentSong?.remainingSec, data?.playingSong?.remainingSec, data?.activeSong?.remainingSec]
  const elapsedCandidates = [data.playbackElapsedSec, data.elapsedSec]
  const startCandidates = [data.playbackStartPos, data.startPos, data?.currentSong?.startPos, data?.playingSong?.startPos]
  const endCandidates = [data.playbackEndPos, data.endPos, data?.currentSong?.endPos, data?.playingSong?.endPos]

  const firstFinite = (items) => {
    for (const item of items) {
      const num = Number(item)
      if (Number.isFinite(num)) return num
    }
    return Number.NaN
  }

  const duration = firstFinite(durationCandidates)
  const remaining = firstFinite(remainingCandidates)
  const elapsed = firstFinite(elapsedCandidates)
  const startPos = firstFinite(startCandidates)
  const endPos = firstFinite(endCandidates)

  if (Number.isFinite(duration) && duration > 0) state.playbackDurationSec = duration
  if (Number.isFinite(remaining)) state.playbackRemainingSec = Math.max(0, remaining)
  else if (Number.isFinite(duration) && duration > 0 && Number.isFinite(elapsed)) state.playbackRemainingSec = Math.max(0, duration - elapsed)
  if (Number.isFinite(elapsed)) state.playbackElapsedSec = Math.max(0, elapsed)
  else if (Number.isFinite(state.playbackDurationSec) && Number.isFinite(state.playbackRemainingSec)) state.playbackElapsedSec = Math.max(0, state.playbackDurationSec - state.playbackRemainingSec)
  if (Number.isFinite(startPos)) state.playbackStartPos = startPos
  if (Number.isFinite(endPos)) state.playbackEndPos = endPos
  if (Number.isFinite(state.playbackRemainingSec)) state.playbackSyncedAtMs = Date.now()
}

function syncFromBridge(data) {
  if (bridgeRequestsDirectorLogout(data)) {
    logoutDirectorToModeSelection(data)
    return
  }
  const previousPlayingId = state.playingId != null ? String(state.playingId) : null
  const previousSelectedMarkerId = state.selectedMarkerId != null ? String(state.selectedMarkerId) : null
  state.bridgeStatus = 'online'
  const nativeBridgeConnected = !!(
    data.connected === true ||
    data.nativeBridge === true ||
    data.bridgeMode === 'native' ||
    data.bridgeMode === 'native_bridge' ||
    data.bridgeMode === 'native_ext'
  )
  state.nativeBridgeConnected = nativeBridgeConnected
  state.bridgeMode = String(data.bridgeMode || (nativeBridgeConnected ? 'native' : state.bridgeMode || ''))
  const bridgeStateUpdatedMs = parseBridgeStateUpdatedMs(data)
  state.lastBridgeUpdatedAtMs = bridgeStateUpdatedMs || (nativeBridgeConnected ? Date.now() : 0)
  syncDirectorPlaybackClockFromBridge(data)
  state.appActive = !!data.appActive
  state.autoBlocoEnabled = !!data.autoBlocoEnabled
  state.regions = Array.isArray(data.regions) ? data.regions : state.regions
  if (Array.isArray(data.playlists)) {
    state.musicosCompatiblePlaylistsForTotal = normalizeMusicosCompatiblePlaylistsForTotal(data.playlists)
  }
  state.playlists = normalizeBridgePlaylistsWithHashChildren(Array.isArray(data.playlists) ? data.playlists : state.playlists)
  state.activePlaylistTotalSec = directorFirstFiniteTotalNumber([data.activePlaylistTotalSec, data.currentPlaylistTotalSec, data.playlistTotalSec, data.totalPlaylistSec, data.repertorioTotalSec, data.repertoryTotalSec]) ?? state.activePlaylistTotalSec
  state.currentPlaylistTotalSec = state.activePlaylistTotalSec
  state.playlistTotalSec = state.activePlaylistTotalSec
  state.totalPlaylistSec = state.activePlaylistTotalSec
  state.activePlaylistTotalText = directorFirstTotalText([data.activePlaylistTotalText, data.currentPlaylistTotalText, data.playlistTotalText, data.totalPlaylistText, data.repertorioTotalText, data.repertoryTotalText]) || state.activePlaylistTotalText || ''
  state.currentPlaylistTotalText = state.activePlaylistTotalText
  state.playlistTotalText = state.activePlaylistTotalText
  state.totalPlaylistText = state.activePlaylistTotalText
  state.regionsTotalSec = directorFirstFiniteTotalNumber([data.regionsTotalSec, data.totalRegionsSec, data.musicasTotalSec, data.musicTotalSec, data.songsTotalSec, data.totalMusicasSec]) ?? state.regionsTotalSec
  state.totalRegionsSec = state.regionsTotalSec
  state.musicasTotalSec = state.regionsTotalSec
  state.totalMusicasSec = state.regionsTotalSec
  state.regionsTotalText = directorFirstTotalText([data.regionsTotalText, data.totalRegionsText, data.musicasTotalText, data.musicTotalText, data.songsTotalText, data.totalMusicasText]) || state.regionsTotalText || ''
  state.totalRegionsText = state.regionsTotalText
  state.musicasTotalText = state.regionsTotalText
  state.totalMusicasText = state.regionsTotalText
  vshookCacheHashChildrenFromBridgeState()
  state.projectTabs = Array.isArray(data.projectTabs) ? data.projectTabs : (Array.isArray(data.projects) ? data.projects : state.projectTabs)
  state.activeProjectTabIndex = Number.isFinite(Number(data.activeProjectTabIndex)) ? Number(data.activeProjectTabIndex) : state.activeProjectTabIndex
  if (state.selectedProjectTabIndex === null) state.selectedProjectTabIndex = state.activeProjectTabIndex
  applyPendingTunerState()
  state.markers = Array.isArray(data.markers) ? data.markers : state.markers
  syncDirectorMarkerArmedVisualWithPlayback?.()
  const mixerData = data.mixer && typeof data.mixer === 'object'
    ? data.mixer
    : {
        tracks: data.mixerTracks,
        groups: data.mixerGroups,
        master: data.mixerMaster,
      }
  if (mixerData && typeof mixerData === 'object') {
    const incomingTracks = Array.isArray(mixerData.tracks) ? mapMixerIncomingItemsWithPending('tracks', mixerData.tracks) : state.mixerTracks
    const incomingGroups = Array.isArray(mixerData.groups) ? mapMixerIncomingItemsWithPending('groups', mixerData.groups) : state.mixerGroups
    const incomingMaster = mixerData.master && typeof mixerData.master === 'object'
      ? decorateMixerIncomingItem('master', mixerData.master)
      : state.mixerMaster
    const mixerInteractionExpired = Date.now() >= (state.mixerVolumeInteractionUntil || 0)

    if (state.mixerVolumeInteracting && mixerInteractionExpired) {
      state.mixerVolumeInteracting = false
    }

    if (state.showMixerVolumeModal && state.mixerSelectedId && state.mixerVolumeInteracting) {
      const keepId = String(state.mixerSelectedId || '')
      const keepView = String(state.mixerVolumeView || 'tracks')
      const localSelected = findMixerItem(keepView, keepId)
      state.mixerTracks = incomingTracks
      state.mixerGroups = incomingGroups
      state.mixerMaster = incomingMaster
      if (localSelected) {
        setMixerItemLocalState(keepView, keepId, {
          volumeRatio: localSelected.volumeRatio,
        })
      }
      requestAnimationFrame(() => {
        try { syncMixerVolumeModalUi(state.mixerVolumeView, state.mixerSelectedId) } catch (error) {}
      })
    } else {
      state.mixerTracks = incomingTracks
      state.mixerGroups = incomingGroups
      state.mixerMaster = incomingMaster
      if (state.showMixerVolumeModal && state.mixerSelectedId) {
        requestAnimationFrame(() => {
          try { syncMixerVolumeModalUi(state.mixerVolumeView, state.mixerSelectedId) } catch (error) {}
        })
      }
    }
  }
  if (data.premix && typeof data.premix === 'object') {
    state.premixBypassEnabled = !!data.premix.bypassEnabled
    if (data.premix.globalEnabled !== undefined) state.premixGlobalEnabled = !!data.premix.globalEnabled
    else if (data.premix.globalPremixEnabled !== undefined) state.premixGlobalEnabled = !!data.premix.globalPremixEnabled
    else if (data.premix.globalPreMixEnabled !== undefined) state.premixGlobalEnabled = !!data.premix.globalPreMixEnabled
    state.premixSongs = Array.isArray(data.premix.songs) ? data.premix.songs : state.premixSongs
    if (!state.premixIsGlobal) {
      const keepPremixListLocalSelection = !!(state.showPremixModal && state.premixView === 'songs' && state.premixSelectedSongId)
      if (!keepPremixListLocalSelection && data.premix.selectedSongId !== undefined && data.premix.selectedSongId !== null && String(data.premix.selectedSongId) !== '') {
        state.premixSelectedSongId = String(data.premix.selectedSongId)
      } else if (!state.premixSelectedSongId && state.premixSongs[0]?.id != null) {
        state.premixSelectedSongId = String(state.premixSongs[0].id)
      }
      if (data.premix.selectedPremixEnabled !== undefined) {
        state.premixSelectedEnabled = !!data.premix.selectedPremixEnabled
      } else if (data.premix.selectedPreMixEnabled !== undefined) {
        state.premixSelectedEnabled = !!data.premix.selectedPreMixEnabled
      }
      if (data.premix.selectedPlaying !== undefined) state.premixSelectedPlaying = !!data.premix.selectedPlaying
      else if (data.premix.selectedPremixPlaying !== undefined) state.premixSelectedPlaying = !!data.premix.selectedPremixPlaying
      if (data.premix.selectedCanEdit !== undefined) state.premixSelectedCanEdit = !!data.premix.selectedCanEdit
      else if (data.premix.selectedPremixCanEdit !== undefined) state.premixSelectedCanEdit = !!data.premix.selectedPremixCanEdit
    } else {
      state.premixSelectedEnabled = !!state.premixGlobalEnabled
    }
    if (Array.isArray(data.premix.tracks) && data.premix.tracks.length) {
      state.premixTracks = data.premix.tracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if (Array.isArray(data.premix.groups) && data.premix.groups.length) {
      state.premixGroups = data.premix.groups.map((item) => normalizePremixTrackItem(item, 'groups'))
    }
    if (Array.isArray(data.premix.globalTracks) && data.premix.globalTracks.length) {
      state.premixGlobalTracks = data.premix.globalTracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if (Array.isArray(data.premix.globalGroups) && data.premix.globalGroups.length) {
      state.premixGlobalGroups = data.premix.globalGroups.map((item) => normalizePremixTrackItem(item, 'groups'))
    }
    if ((!Array.isArray(state.premixTracks) || !state.premixTracks.length) && Array.isArray(state.mixerTracks)) {
      state.premixTracks = state.mixerTracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if ((!Array.isArray(state.premixGroups) || !state.premixGroups.length) && Array.isArray(state.mixerGroups)) {
      state.premixGroups = state.mixerGroups.map((item) => normalizePremixTrackItem(item, 'groups'))
    }
    if ((!Array.isArray(state.premixGlobalTracks) || !state.premixGlobalTracks.length) && Array.isArray(state.mixerTracks)) {
      state.premixGlobalTracks = state.mixerTracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if ((!Array.isArray(state.premixGlobalGroups) || !state.premixGlobalGroups.length) && Array.isArray(state.mixerGroups)) {
      state.premixGlobalGroups = state.mixerGroups.map((item) => normalizePremixTrackItem(item, 'groups'))
    }
  }

  if (data.bpm && typeof data.bpm === 'object') {
    if (typeof data.bpm.offset === 'number') state.bpmOffset = Math.max(-120, Math.min(120, Math.floor(data.bpm.offset)))
    state.bpmDisplay = typeof data.bpm.display === 'string' ? data.bpm.display : formatBpmDisplay(state.bpmOffset)
    state.bpmModeActive = !!data.bpm.modeActive
  } else {
    if (typeof data.bpmOffset === 'number') state.bpmOffset = Math.max(-120, Math.min(120, Math.floor(data.bpmOffset)))
    if (typeof data.bpmDisplay === 'string') state.bpmDisplay = data.bpmDisplay
  }

  if (data.tuner && typeof data.tuner === 'object') {
    state.tunerModeActive = !!data.tuner.modeActive
  }

  const bridgeSaysPlaying = bridgeDataSaysPlaying(data)
  const bridgeSaysStopped = bridgeDataSaysStopped(data)
  const bridgePlayingId = getIncomingBridgePlayingId(data)
  const optimisticId = optimisticPlaybackState.id ? String(optimisticPlaybackState.id) : ''
  const optimisticStillActive = optimisticId && isOptimisticPlaybackActiveFor(optimisticId)
  // DIRECTOR_FRONT_PLAY_STALE_BRIDGE_GUARD_PATCH
  // Depois de Play pelo app, o primeiro JSON do Bridge pode ainda ser o estado antigo
  // da musica que acabou de parar. O front deve continuar no alvo local por um pequeno
  // atraso, e so aceitar outro playingId quando esse estado ja for novo o bastante.
  const localPlayStartedAt = Math.max(
    Number(optimisticPlaybackState.startedAtMs || 0),
    pendingPlaybackDesiredPlaying === true ? Number(pendingPlaybackToggleAt || 0) : 0
  )
  const frontPlayReturnHoldActive = !!(optimisticStillActive && optimisticId && localPlayStartedAt && (Date.now() - localPlayStartedAt) < DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS)
  const bridgeSnapshotOlderThanLocalPlay = !!(frontPlayReturnHoldActive && (!bridgeStateUpdatedMs || (bridgeStateUpdatedMs + 40) < localPlayStartedAt))
  const bridgePlayingIdConflictsWithFrontPlay = !!(frontPlayReturnHoldActive && bridgePlayingId && String(bridgePlayingId) !== optimisticId)
  const shouldDelayBridgePlayingReturn = bridgeSnapshotOlderThanLocalPlay || bridgePlayingIdConflictsWithFrontPlay
  const bridgeConfirmsPlaying = bridgeSaysPlaying || !!bridgePlayingId
  const bridgeConfirmsStopped = bridgeSaysStopped || data.playingId === null

  let incomingPlayingId = state.playingId
  if (bridgeSaysPlaying || bridgePlayingId) {
    // Front primeiro, mas só por poucos ms. Depois disso, o Bridge manda.
    // Isso evita Play duplo/Stop duplo e também corrige quando alguém toca outra música
    // manualmente pela timeline do REAPER.
    if (shouldDelayBridgePlayingReturn || (optimisticStillActive && optimisticId && shouldHoldDirectorFrontPlayingId(bridgePlayingId))) {
      incomingPlayingId = optimisticId
    } else {
      incomingPlayingId = bridgePlayingId || null
    }
  } else if (bridgeSaysStopped) {
    // Estado parado logo após Play pode ser JSON antigo; segura só o pequeno delay do front.
    if (optimisticStillActive && optimisticId && getOptimisticPlaybackAgeMs() < DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS) {
      incomingPlayingId = optimisticId
    } else {
      incomingPlayingId = null
    }
  } else if (data.playingId === null || !optimisticStillActive) {
    incomingPlayingId = null
  }

  const stoppedHoldBeforePlaybackApply = getActiveStoppedSelectionHoldTarget()
  if (stoppedHoldBeforePlaybackApply && pendingPlaybackDesiredPlaying !== true && incomingPlayingId && String(incomingPlayingId) !== String(stoppedHoldBeforePlaybackApply.id)) {
    // Depois de Stop pelo Diretor, alguns ciclos do Bridge ainda podem trazer
    // o playingId da música parada. Esse ID velho não pode derrubar a seleção
    // visual que já foi movida para a fila/Auto/AutoBloco.
    incomingPlayingId = null
  }

  if (pendingPlaybackToggleAt && pendingPlaybackDesiredPlaying !== null) {
    const elapsedPlayback = Date.now() - pendingPlaybackToggleAt

    if (pendingPlaybackDesiredPlaying === true) {
      if (bridgeConfirmsPlaying) {
        const confirmedId = incomingPlayingId || ((shouldDelayBridgePlayingReturn || shouldHoldDirectorFrontPlayingId(bridgePlayingId)) ? optimisticId : null) || null
        state.playingId = confirmedId
        if (confirmedId && optimisticPlaybackState.id && String(confirmedId) !== String(optimisticPlaybackState.id)) {
          clearOptimisticPlayback()
        }
        if (confirmedId && !optimisticPlaybackState.id && getOptimisticPlaybackAgeMs() < DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS) {
          optimisticPlaybackState.id = String(confirmedId)
          optimisticPlaybackState.sourceTab = pendingPlaybackDesiredSourceTab || lastPlaybackSelectionTab || state.activeTab || 'playlist'
          optimisticPlaybackState.startedAtMs = optimisticPlaybackState.startedAtMs || Date.now()
          optimisticPlaybackState.durationSec = getOptimisticDurationSec(confirmedId) || Number(optimisticPlaybackState.durationSec) || 0
          optimisticPlaybackState.expiresAtMs = Date.now() + getOptimisticPlaybackGraceMsForDuration(optimisticPlaybackState.durationSec)
        }
        clearPendingPlaybackToggle()
      } else if (elapsedPlayback < getPendingPlaybackGraceMs()) {
        // Ainda aguardando confirmação real do Bridge. Mantém o visual em Stop.
        state.playingId = optimisticId || pendingPlaybackDesiredSourceId || state.playingId || lastPlaybackSelectionId || null
      } else {
        state.playingId = incomingPlayingId
        if (!incomingPlayingId) clearOptimisticPlayback()
        clearPendingPlaybackToggle()
      }
    } else {
      if (bridgeConfirmsStopped || !incomingPlayingId) {
        state.playingId = null
        clearOptimisticPlayback()
        clearPendingPlaybackToggle()
      } else if (elapsedPlayback < getPendingPlaybackGraceMs()) {
        // Stop foi pedido localmente; mantém visual parado até o Bridge acompanhar.
        state.playingId = null
        clearOptimisticPlayback()
      } else {
        state.playingId = incomingPlayingId
        if (!incomingPlayingId || String(incomingPlayingId) !== String(optimisticPlaybackState.id || '')) {
          clearOptimisticPlayback()
        }
        clearPendingPlaybackToggle()
      }
    }
  } else {
    state.playingId = incomingPlayingId
    if (!incomingPlayingId) {
      clearOptimisticPlayback()
    } else if (optimisticPlaybackState.id && String(incomingPlayingId) !== String(optimisticPlaybackState.id)) {
      // O Bridge pode trocar o ID para o número real da região. Atualiza o ID otimista
      // em vez de apagar a proteção e deixar o próximo JSON antigo derrubar o botão.
      optimisticPlaybackState.id = String(incomingPlayingId)
      optimisticPlaybackState.durationSec = getOptimisticDurationSec(incomingPlayingId) || Number(optimisticPlaybackState.durationSec) || 0
      optimisticPlaybackState.expiresAtMs = Date.now() + getOptimisticPlaybackGraceMsForDuration(optimisticPlaybackState.durationSec)
    }
  }

  const incomingActivePlaylistId = (typeof data.activePlaylistId === 'string' || data.activePlaylistId === null) ? (data.activePlaylistId || null) : undefined
  if (incomingActivePlaylistId !== undefined) {
    const holdPlaylistSwitch = state.pendingPlaylistSwitchId && Date.now() < Number(state.pendingPlaylistSwitchUntilMs || 0)
    if (!holdPlaylistSwitch || String(incomingActivePlaylistId || '') === String(state.pendingPlaylistSwitchId || '')) {
      state.activePlaylistId = incomingActivePlaylistId
      if (String(incomingActivePlaylistId || '') === String(state.pendingPlaylistSwitchId || '')) {
        state.pendingPlaylistSwitchUntilMs = 0
      }
    }
  }

  const preferredPlayingId = getPreferredDirectorChildPlayingId(state.playingId)
  if (preferredPlayingId && state.playingId && String(preferredPlayingId) !== String(state.playingId)) {
    state.playingId = preferredPlayingId
    if (state.activeTab === 'playlist') {
      state.selectedPlaylistSongId = preferredPlayingId
      state.selectedPlaylistSongIds = []
    } else if (state.activeTab === 'regions') {
      state.selectedRegionId = preferredPlayingId
      state.selectedRegionIds = []
    }
    lockSelectionSync(2200)
  }

  const currentPlayingId = state.playingId != null ? String(state.playingId) : null
  if (previousPlayingId !== currentPlayingId) {
    resetPlaybackLiveState(true)
  } else {
    resetPlaybackLiveState()
  }
  if (currentPlayingId) {
    rememberCurrentPlaybackSelection(currentPlayingId, pendingPlaybackDesiredSourceTab || lastPlaybackSelectionTab || state.activeTab)
  } else {
    clearDirectorPlaybackClockIfStopped()
  }

  if (previousPlayingId && !currentPlayingId) {
    state.pendingStopClear = false
    const stoppedPreferredTab = lastPlaybackSelectionTab || state.activeTab
    const stopSelectionTarget = getDirectorStopSelectionTarget(previousPlayingId, stoppedPreferredTab)
    if (stopSelectionTarget && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(previousPlayingId || '')) {
      if (applyStoppedSongSelection(stopSelectionTarget.id, stopSelectionTarget.tab)) {
        forceStoppedSelectionDom(stopSelectionTarget.id, stopSelectionTarget.tab)
      }
    } else {
      // FIX77: quando o Bridge informa que parou sem fila, mantém a música parada selecionada.
      // Isso evita o atraso de esperar selectedPlaylistSongId/selectedRegionId remoto.
      applyStoppedSongSelection(previousPlayingId, stoppedPreferredTab)
    }
  }

  const holdActive = !!state.stoppedSelectionHoldId && Date.now() < Number(state.stoppedSelectionHoldUntil || 0)
  const localSelectionHoldTarget = getActiveDirectorLocalSelectionHold()
  const selectionLocked = Date.now() < (state.selectionLockUntil || 0)
  if (shouldDelayBridgePlayingReturn && optimisticId) {
    const optimisticTab = optimisticPlaybackState.sourceTab || pendingPlaybackDesiredSourceTab || lastPlaybackSelectionTab || state.activeTab || 'playlist'
    if (optimisticTab === 'playlist') {
      state.selectedPlaylistSongId = optimisticId
      state.selectedPlaylistSongIds = []
      state.selectedRegionId = null
      state.selectedRegionIds = []
    } else if (optimisticTab === 'regions') {
      state.selectedRegionId = optimisticId
      state.selectedRegionIds = []
      state.selectedPlaylistSongId = null
      state.selectedPlaylistSongIds = []
    }
    state.selectionLockUntil = Math.max(Number(state.selectionLockUntil || 0), Date.now() + DIRECTOR_FRONT_PLAY_SYNC_HOLD_MS)
  }
  const localSelectionControlActive = isLocalSelectionControlActive()

  if (state.pendingStopClear) {
    state.pendingStopClear = false
  }

  if (localSelectionHoldTarget && !currentPlayingId) {
    // Se o usuário acabou de selecionar pelo front, selectedId antigo do Bridge não pode voltar.
    if (localSelectionHoldTarget.tab === 'playlist') {
      state.selectedPlaylistSongId = localSelectionHoldTarget.id
      state.selectedPlaylistSongIds = []
      state.selectedRegionId = null
      state.selectedRegionIds = []
    } else {
      state.selectedRegionId = localSelectionHoldTarget.id
      state.selectedRegionIds = []
      state.selectedPlaylistSongId = null
      state.selectedPlaylistSongIds = []
    }
  } else if (holdActive && !currentPlayingId) {
    applyStoppedSongSelection(state.stoppedSelectionHoldId, state.stoppedSelectionHoldTab, { hold: false })
  } else if (holdActive && pendingPlaybackDesiredPlaying !== true) {
    // Mantém o alvo visual pós-Stop acima de qualquer selectedId atrasado vindo do Bridge.
    applyStoppedSongSelection(state.stoppedSelectionHoldId, state.stoppedSelectionHoldTab, { hold: false })
  } else if (!selectionLocked && !localSelectionControlActive) {
    const incomingSelectedRegionId = (typeof data.selectedRegionId === 'string' || typeof data.selectedRegionId === 'number') ? String(data.selectedRegionId) : null
    const incomingSelectedPlaylistSongId = (typeof data.selectedPlaylistSongId === 'string' || typeof data.selectedPlaylistSongId === 'number') ? String(data.selectedPlaylistSongId) : null
    const incomingSelectedId = incomingSelectedPlaylistSongId || incomingSelectedRegionId || ''
    const currentFrontSelectedId = String(state.selectedPlaylistSongId || state.selectedRegionId || '')
    const ignoreStoppedSelectionEcho = !!(incomingSelectedId && isDirectorStoppedSelectionBlocked(incomingSelectedId) && currentFrontSelectedId && incomingSelectedId !== currentFrontSelectedId && !currentPlayingId)
    const ignorePlayingSelectionEcho = !!(incomingSelectedId && currentPlayingId && incomingSelectedId === String(currentPlayingId))
    if (!ignoreStoppedSelectionEcho && !ignorePlayingSelectionEcho) {
      state.selectedRegionId = incomingSelectedRegionId !== null ? incomingSelectedRegionId : (data.selectedRegionId === null ? null : state.selectedRegionId)
      state.selectedRegionIds = Array.isArray(data.selectedRegionIds) ? data.selectedRegionIds.map(String) : state.selectedRegionIds
      state.selectedPlaylistSongId = incomingSelectedPlaylistSongId !== null ? incomingSelectedPlaylistSongId : (data.selectedPlaylistSongId === null ? null : state.selectedPlaylistSongId)
    } else if (ignorePlayingSelectionEcho) {
      if (state.activeTab === 'playlist' && String(state.selectedPlaylistSongId || '') === String(currentPlayingId || '')) {
        state.selectedPlaylistSongId = null
        state.selectedPlaylistSongIds = []
      }
      if (state.activeTab === 'regions' && String(state.selectedRegionId || '') === String(currentPlayingId || '')) {
        state.selectedRegionId = null
        state.selectedRegionIds = []
      }
    }
  } else if (!localSelectionControlActive) {
    if (data.selectedRegionId === null) state.selectedRegionId = null
    if (Array.isArray(data.selectedRegionIds) && data.selectedRegionIds.length === 0) state.selectedRegionIds = []
    if (data.selectedPlaylistSongId === null) state.selectedPlaylistSongId = null
  }

  const localMarkerHoldId = getActiveDirectorMarkerLocalHoldId ? getActiveDirectorMarkerLocalHoldId() : null
  if (state.markerGoFlashId) {
    state.selectedMarkerId = String(state.markerGoFlashId)
  } else if (localMarkerHoldId) {
    state.selectedMarkerId = String(localMarkerHoldId)
  } else if (!localSelectionControlActive) {
    state.selectedMarkerId = typeof data.selectedMarkerId === 'string' || typeof data.selectedMarkerId === 'number' ? String(data.selectedMarkerId) : (data.selectedMarkerId === null ? null : state.selectedMarkerId)
  }

  if (currentPlayingId) {
    if (state.activeTab === 'playlist' && String(state.selectedPlaylistSongId || '') === String(currentPlayingId)) {
      state.selectedPlaylistSongId = null
      state.selectedPlaylistSongIds = []
    }
    if (state.activeTab === 'regions' && String(state.selectedRegionId || '') === String(currentPlayingId)) {
      state.selectedRegionId = null
      state.selectedRegionIds = []
    }
  }

  // 2.0.28: Stop sem fila não mantém seleção azul da música parada.
  if (!currentPlayingId && !state.stoppedSelectionHoldId) {
    const blockedIds = Array.isArray(directorStoppedSelectionBlocked) ? directorStoppedSelectionBlocked : []
    const selectedPlaylist = String(state.selectedPlaylistSongId || '')
    const selectedRegion = String(state.selectedRegionId || '')
    if (selectedPlaylist && isDirectorStoppedSelectionBlocked(selectedPlaylist)) {
      state.selectedPlaylistSongId = null
      state.selectedPlaylistSongIds = []
    }
    if (selectedRegion && isDirectorStoppedSelectionBlocked(selectedRegion)) {
      state.selectedRegionId = null
      state.selectedRegionIds = []
    }
  }

  // Mesmo que o Bridge mande estado antigo, o Diretor nunca mantém
  // seleção de Repertórios e Músicas ao mesmo tempo.
  normalizeSingleSelectionForActiveTab()

  if (state.pendingStopClear) {
    state.selectedMarkerId = null
  }

  const nextMarkerId = state.selectedMarkerId != null ? String(state.selectedMarkerId) : null
  lastProximityPopupMarkerId = null

  if (typeof data.autoplayEnabled === 'boolean') {
    if (pendingAutoplayVisualValue !== null && Date.now() < Number(pendingAutoplayVisualUntil || 0)) {
      if (data.autoplayEnabled === pendingAutoplayVisualValue) {
        state.autoplayEnabled = data.autoplayEnabled
        pendingAutoplayVisualValue = null
        pendingAutoplayVisualUntil = 0
      } else {
        state.autoplayEnabled = !!pendingAutoplayVisualValue
      }
    } else {
      pendingAutoplayVisualValue = null
      pendingAutoplayVisualUntil = 0
      state.autoplayEnabled = data.autoplayEnabled
    }
  }
  if (Date.now() > Number(state.timerLocalOwnerUntil || 0)) {
    state.timerRunning = typeof data.timerRunning === 'boolean' ? data.timerRunning : state.timerRunning
    state.timerStartedAt = Number.isFinite(Number(data.timerStartedAt)) ? Number(data.timerStartedAt) : state.timerStartedAt
    state.timerAccumulatedSec = Number.isFinite(Number(data.timerAccumulatedSec)) ? Number(data.timerAccumulatedSec) : state.timerAccumulatedSec
    state.timerMode = normalizeDirectorTimerMode(data.timerMode || data.timerType || state.timerMode || 'progressive')
    state.timerTargetSec = Number.isFinite(Number(data.timerTargetSec)) ? Number(data.timerTargetSec) : state.timerTargetSec
    state.timerDisplaySec = Number.isFinite(Number(data.timerDisplaySec)) ? Number(data.timerDisplaySec) : state.timerDisplaySec
  }
  state.liveModeEnabled = typeof data.liveModeEnabled === 'boolean' ? data.liveModeEnabled : (typeof data.liveEnabled === 'boolean' ? data.liveEnabled : state.liveModeEnabled)
  state.authEnabled = typeof data.authEnabled === 'boolean' ? data.authEnabled : state.authEnabled
  state.authHash = typeof data.authHash === 'string' ? data.authHash : state.authHash
  syncAuthStateFromBridge()
  // Recados ficam sempre ativos no app.
  // Ignora qualquer estado antigo vindo do bridge para não voltar para OFF.
  state.noticeEnabled = true
  pendingNoticeToggleAt = 0
  pendingNoticeToggleValue = null
  state.loopActive = !!data.loopActive

  const incomingBridgePopupText = String(data.popupText || '')
  const incomingBridgePopupIsPlaybackName = !!data.popupVisible && isDirectorPlaybackNamePopupText(incomingBridgePopupText)
  const shouldShowIncomingPlaybackNamePopup = incomingBridgePopupIsPlaybackName ? markDirectorPlaybackNamePopup(incomingBridgePopupText) : false

  state.bridgePopupVisible = incomingBridgePopupIsPlaybackName ? shouldShowIncomingPlaybackNamePopup : !!data.popupVisible
  state.bridgePopupText = state.bridgePopupVisible ? incomingBridgePopupText : ''
  state.bridgePopupError = incomingBridgePopupIsPlaybackName ? false : !!data.popupError
  state.bridgePopupPersistent = incomingBridgePopupIsPlaybackName ? false : !!data.popupPersistent

  if (state.bridgePopupVisible && state.bridgePopupText) {
    if (bridgePopupFadeTimer) {
      clearTimeout(bridgePopupFadeTimer)
      bridgePopupFadeTimer = null
    }
    bridgePopupDisplay.mounted = true
    bridgePopupDisplay.text = state.bridgePopupText
    bridgePopupDisplay.error = state.bridgePopupError
    bridgePopupDisplay.persistent = state.bridgePopupPersistent
    bridgePopupDisplay.fading = false
    if (state.lyricsPanelOpen) {
      requestAnimationFrame(() => syncBridgePopupDom())
    }
  } else if (bridgePopupDisplay.mounted && !bridgePopupDisplay.fading) {
    bridgePopupDisplay.fading = true
    if (bridgePopupFadeTimer) clearTimeout(bridgePopupFadeTimer)
    bridgePopupFadeTimer = setTimeout(() => {
      bridgePopupDisplay.mounted = false
      bridgePopupDisplay.text = ''
      bridgePopupDisplay.error = false
      bridgePopupDisplay.persistent = false
      bridgePopupDisplay.fading = false
      bridgePopupFadeTimer = null
      render()
    }, 220)
  }

  if (pendingLoopToggleAt) {
    const elapsed = Date.now() - pendingLoopToggleAt
    if (pendingLoopToggleFromState === false && state.loopActive) {
      pendingLoopToggleAt = 0
      pendingLoopToggleFromState = null
    } else if (pendingLoopToggleFromState === true && !state.loopActive) {
      pendingLoopToggleAt = 0
      pendingLoopToggleFromState = null
    } else if (elapsed >= 1200) {
      pendingLoopToggleAt = 0
      pendingLoopToggleFromState = null
    }
  }

  const incomingQueuedSongId = typeof data.queuedSongId === 'string' || typeof data.queuedSongId === 'number' ? String(data.queuedSongId) : null
  state.queuedSongId = Date.now() < Number(remoteQueuedIgnoreUntil || 0) ? null : incomingQueuedSongId
  if (state.localQueuedSongId) {
    const localAge = Date.now() - Number(state.localQueuedSongAt || 0)
    if (!currentPlayingId || String(currentPlayingId) === String(state.localQueuedSongId) || localAge > 12000) {
      clearLocalQueuedSong()
    }
  }
  state.clearButtonSide = data.clearButtonSide === 'left' ? 'left' : 'right'

  let remoteBaseTab = (data.currentPage === 'playlist' || data.currentPage === 'markers') ? 'playlist' : (data.currentPage === 'regions' ? 'regions' : state.activeTab)
  if (state.forcePlaylistUntil && Date.now() < state.forcePlaylistUntil) remoteBaseTab = 'playlist'
  if (state.showMixerModal || state.showMixerVolumeModal || state.showPremixModal || state.showPremixVolumeModal || state.showBpmModal || state.showTunerModal) {
    return
  }
  const previousActiveTabForSelection = state.activeTab
  if (state.localMarkersMode) {
    if (state.activeTab !== 'playlist') clearDirectorSelectionForTabSwitch()
    state.activeTab = 'playlist'
    state.playlistView = 'markers'
  } else {
    state.playlistView = 'songs'
    if (state.pendingTabCommand) {
      if (remoteBaseTab === state.pendingTabCommand) {
        if (state.activeTab !== remoteBaseTab) clearDirectorSelectionForTabSwitch()
        state.activeTab = remoteBaseTab
        state.pendingTabCommand = null
      }
    } else {
      if (state.activeTab !== remoteBaseTab) clearDirectorSelectionForTabSwitch()
      state.activeTab = remoteBaseTab
    }
  }
}

function sendAppHeartbeat() {
  if (needsAuthGate()) return
  if (state.bridgeStatus !== 'online') return
  const now = Date.now()
  if ((now - lastAppHeartbeatAt) < 2500) return
  lastAppHeartbeatAt = now
  postCommand('app_heartbeat')
}

function isAuthInputFocused() {
  const active = document.activeElement
  if (!active) return false
  return active.id === 'accessPassInput'
}

function holdAuthBridgeRender(ms = 320) {
  authFocusHoldUntil = Math.max(authFocusHoldUntil || 0, Date.now() + Math.max(120, Number(ms) || 0))
}

function syncAccessPasswordUi() {
  const shouldShow = state.authShowPassword === true
  const input = document.getElementById('accessPassInput')
  if (input) {
    const nextType = shouldShow ? 'text' : 'password'
    try {
      input.type = nextType
    } catch (error) {
      input.setAttribute('type', nextType)
    }
    input.removeAttribute('style')
  }

  const toggleBtn = document.getElementById('accessTogglePass')
  if (toggleBtn) {
    const label = shouldShow ? 'Ocultar senha' : 'Mostrar senha'
    const icon = shouldShow
      ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18"></path><path d="M9.9 4.24A10.74 10.74 0 0112 4c5.23 0 9.27 3.11 10.9 8-.72 2.16-2.05 4.03-3.8 5.38"></path><path d="M6.23 6.23C4.54 7.5 3.2 9.12 2.1 12c1.63 4.89 5.67 8 10.9 8 1.8 0 3.48-.37 4.97-1.04"></path><path d="M10.73 10.73a2 2 0 102.54 2.54"></path></svg>'
      : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1.5 12S5.5 4 12 4s10.5 8 10.5 8-4 8-10.5 8S1.5 12 1.5 12Z"></path><circle cx="12" cy="12" r="3"></circle></svg>'
    toggleBtn.setAttribute('aria-label', label)
    toggleBtn.setAttribute('title', label)
    toggleBtn.setAttribute('aria-pressed', shouldShow ? 'true' : 'false')
    toggleBtn.innerHTML = icon
  }
}

function shouldPauseBridgeRender() {
  return !!(
    (needsAuthGate() && (isAuthInputFocused() || Date.now() < authFocusHoldUntil)) ||
    state.dragActive ||
    state.dragPending ||
    state.editMode ||
    state.deleteMode ||
    state.showRenameModal ||
    state.showCreatePlaylistModal ||
    state.showAddExistingModal ||
    state.showPlaylistSwitchModal ||
    state.showMixerModal ||
    state.showMixerVolumeModal ||
    state.showPremixModal ||
    state.showPremixVolumeModal ||
    state.showBpmModal ||
    state.showTunerModal ||
    state.showTimerModal ||
    state.showProjectTabsModal ||
    state.showRecadosModal ||
    state.lyricsPanelOpen ||
    state.mixerVolumeInteracting ||
    Date.now() < Number(directorLocalInputHoldUntil || 0) ||
    (Date.now() - Number(lastUserScrollAt || 0) < 850)
  )
}


function buildBridgeRenderSignature() {
  return JSON.stringify({
    bridgeStatus: state.bridgeStatus,
    activePlaylistId: state.activePlaylistId,
    playingId: state.playingId,
    playbackUiActive: getPlaybackUiActive(),
    pendingPlaybackDesiredPlaying,
    autoplayEnabled: getAutoplayVisualEnabled(),
    autoBlocoEnabled: state.autoBlocoEnabled,
    noticeEnabled: true,
    liveModeEnabled: state.liveModeEnabled,
    showLiveOffConfirmModal: state.showLiveOffConfirmModal,
    timerMode: state.timerMode,
    timerTargetSec: state.timerTargetSec,
    rgbMode: state.rgbMode,
    rgbFixedIndex: state.rgbFixedIndex,
    activeTab: state.activeTab,
    playlistView: state.playlistView,
    localMarkersMode: state.localMarkersMode,
    selectedRegionId: state.selectedRegionId,
    selectedRegionIds: state.selectedRegionIds,
    selectedPlaylistSongId: state.selectedPlaylistSongId,
    selectedMarkerId: state.selectedMarkerId,
    queuedSongId: state.queuedSongId,
    localQueuedSongId: state.localQueuedSongId,
    remoteQueuedIgnoreActive: Date.now() < Number(remoteQueuedIgnoreUntil || 0),
    loopActive: state.loopActive,
    clearButtonSide: state.clearButtonSide,
    authEnabled: state.authEnabled,
    authHash: state.authHash,
    appActive: state.appActive,
    bridgePopupVisible: state.bridgePopupVisible,
    bridgePopupText: state.bridgePopupText,
    bridgePopupError: state.bridgePopupError,
    bridgePopupPersistent: state.bridgePopupPersistent,
    timerRunning: state.timerRunning,
    timerStartedAt: state.timerStartedAt,
    timerStartedAtMs: state.timerStartedAtMs,
    timerAccumulatedSec: state.timerAccumulatedSec,
    timerDisplaySec: state.timerDisplaySec,
    activePlaylistTotalSec: state.activePlaylistTotalSec,
    activePlaylistTotalText: state.activePlaylistTotalText,
    regionsTotalSec: state.regionsTotalSec,
    regionsTotalText: state.regionsTotalText,
    chronoTick: state.timerRunning ? Math.floor(Date.now() / 250) : 0,
    playbackTick: (getPlaybackUiActive() && !state.lyricsPanelOpen) ? Math.floor(Date.now() / 200) : 0,
    playlists: (state.playlists || []).map((playlist) => ({
      id: String(playlist.id),
      name: playlist.name,
      songs: (playlist.songs || []).map((song) => ({
        id: String(song.id),
        name: song.name,
        durationSec: song.durationSec,
        blockColorHex: song.blockColorHex,
        inheritedBlockColorHex: song.inheritedBlockColorHex,
        familyRole: song.familyRole,
        familyGroupId: song.familyGroupId,
        depth: song.depth,
              })),
    })),
    regions: (state.regions || []).map((region) => ({
      id: String(region.id),
      name: region.name,
      durationSec: region.durationSec,
      inheritedBlockColorHex: region.inheritedBlockColorHex,
      familyRole: region.familyRole,
      familyGroupId: region.familyGroupId,
      depth: region.depth,
          })),
    markers: (state.markers || []).map((marker) => ({
      id: String(marker.id),
      label: marker.label,
      timeSec: marker.timeSec,
      songId: marker.songId,
    })),
    mixerTracks: (state.mixerTracks || []).map((item) => ({
      id: String(item.id),
      mute: !!item.mute,
      solo: !!item.solo,
    })),
    mixerGroups: (state.mixerGroups || []).map((item) => ({
      id: String(item.id),
      mute: !!item.mute,
      solo: !!item.solo,
    })),
    mixerMaster: state.mixerMaster ? {
      id: String(state.mixerMaster.id),
      mute: !!state.mixerMaster.mute,
      solo: !!state.mixerMaster.solo,
    } : null,
    showPremixModal: state.showPremixModal,
    showPremixVolumeModal: state.showPremixVolumeModal,
    premixView: state.premixView,
    premixTrackView: state.premixTrackView,
    premixSelectedSongId: state.premixSelectedSongId,
    premixSelectedTrackId: state.premixSelectedTrackId,
    premixSelectedEnabled: state.premixSelectedEnabled,
    premixGlobalEnabled: state.premixGlobalEnabled,
    premixIsGlobal: state.premixIsGlobal,
    premixBypassEnabled: state.premixBypassEnabled,
    premixSongs: (state.premixSongs || []).map((item) => ({ id: String(item.id), name: item.name, durationSec: item.durationSec, premixEnabled: !!(item.premixEnabled ?? item.preMixEnabled ?? item.onOff) })),
    premixTracks: (state.premixTracks || []).map((item) => ({ id: String(item.id || item.guid), name: item.name, mute: !!item.mute, solo: !!item.solo, phase: !!item.phase, volumeRatio: Number(item.volumeRatio) || 0, db: item.db })),
    premixGroups: (state.premixGroups || []).map((item) => ({ id: String(item.id || item.guid), name: item.name, mute: !!item.mute, solo: !!item.solo, phase: !!item.phase, volumeRatio: Number(item.volumeRatio) || 0, db: item.db })),
    premixGlobalTracks: (state.premixGlobalTracks || []).map((item) => ({ id: String(item.id || item.guid), name: item.name, mute: !!item.mute, solo: !!item.solo, phase: !!item.phase, volumeRatio: Number(item.volumeRatio) || 0, db: item.db })),
    premixGlobalGroups: (state.premixGlobalGroups || []).map((item) => ({ id: String(item.id || item.guid), name: item.name, mute: !!item.mute, solo: !!item.solo, phase: !!item.phase, volumeRatio: Number(item.volumeRatio) || 0, db: item.db })),
    bpmOffset: state.bpmOffset,
    bpmDisplay: state.bpmDisplay,
    bpmModeActive: state.bpmModeActive,
    tunerModeActive: state.tunerModeActive,
    showProjectTabsModal: state.showProjectTabsModal,
    showRecadosModal: state.showRecadosModal,
    recadosDraft: state.showRecadosModal ? state.recadosDraft : '',
    recadosStatus: state.recadosStatus,
    recadosSending: state.recadosSending,
    recadosNoticeTick: state.showRecadosModal ? Math.ceil(Math.max(0, Number(state.recadosNoticeExpiresAt || 0) - Date.now()) / 1000) : 0,
    activeProjectTabIndex: state.activeProjectTabIndex,
    selectedProjectTabIndex: state.selectedProjectTabIndex,
    projectTabs: (state.projectTabs || []).map((tab) => ({ index: Number(tab.index), name: tab.name || tab.projectName, active: !!(tab.active || tab.isCurrent) })),
    tunerRegions: (state.regions || []).map((item) => ({ id: String(item.id), toneOffset: Number(item.toneOffset) || 0 })),
    tunerSongs: (state.playlists || []).map((playlist) => ({ id: String(playlist.id), songs: (playlist.songs || []).map((song) => ({ id: String(song.id), toneOffset: Number(song.toneOffset) || 0 })) })),
  })
}

function fastPollBridge(cycles = 4) {
  const count = Math.max(1, Math.min(10, Number(cycles) || 4))
  for (let i = 0; i < count; i += 1) {
    window.setTimeout(() => {
      try { pollBridge() } catch (error) {}
    }, i * 45)
  }
}

async function pollBridge() {
  if (bridgePollInFlight) return
  bridgePollInFlight = true
  try {
  const previousSignature = buildBridgeRenderSignature()
  let bridgeOk = false
  try {
    const response = await fetch(vshookBridgeUrl('/state'), { cache: 'no-store' })
    if (!response.ok) throw new Error('offline')
    const data = await response.json()
    syncFromBridge(data)
    applyDirectorLocalStopIfMusicEnded()
    if (bridgeLooksOffline()) {
      state.bridgeStatus = 'offline'
      state.appActive = false
    } else {
      bridgeOk = true
    }
  } catch (e) {
    state.bridgeStatus = 'offline'
    state.nativeBridgeConnected = false
    state.appActive = false
  }

  if (state.bridgeStatus !== 'online') {
    state.authAuthenticated = false
    state.authShowPassword = false
  }
  const nextSignature = buildBridgeRenderSignature()
  const shouldRenderNow = !shouldPauseBridgeRender() && (nextSignature !== lastBridgeRenderSignature || nextSignature !== previousSignature)
  if (shouldRenderNow) {
    const now = Date.now()
    if ((now - lastBridgeUiRenderAt) >= 450) {
      lastBridgeUiRenderAt = now
      try { render() } catch (error) { console.error('render poll error', error) }
    }
  }
  requestAnimationFrame(() => {
    try { applyBridgeScrollToVisibleList() } catch (error) {}
  })
  refreshChronoRenderLoop()
  syncLyricsPanelDom()
  if (bridgeOk) {
    sendAppHeartbeat()
  }
  if (bridgeOk && appLoadingVisible) {
    appLoadedOnce = true
    hideBootLoader()
  }

  } finally {
    bridgePollInFlight = false
  }
}




function openRecadosModal() {
  state.settingsMenuOpen = false
  state.showRecadosModal = true
  state.recadosStatus = ''
  render()
}

function closeRecadosModal() {
  state.showRecadosModal = false
  state.recadosStatus = ''
  render()
}

function getDirectorRecadosRemainingSeconds() {
  const remainingMs = Math.max(0, Number(state.recadosNoticeExpiresAt || 0) - Date.now())
  return remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0
}

function getDirectorRecadosStatusText() {
  const remaining = getDirectorRecadosRemainingSeconds()
  if (remaining > 0) return `RECADO ATIVO: ${remaining}s`
  if (Number(state.recadosNoticeExpiresAt || 0) > 0 && state.recadosStatus === 'RECADO ATIVO') return 'RECADO EXPIRADO'
  return state.recadosStatus || ''
}

function syncDirectorRecadosDom() {
  const statusEl = document.getElementById('recadosDirectorStatus')
  if (statusEl) statusEl.textContent = getDirectorRecadosStatusText()
  const sendButton = document.querySelector('[data-action="recados-send"]')
  if (sendButton) {
    sendButton.disabled = !!state.recadosSending
    sendButton.textContent = state.recadosSending ? 'ENVIANDO...' : 'ENVIAR'
  }
}

function handleRecadosInputChange() {
  const input = document.getElementById('recadosDirectorTextarea')
  if (input) state.recadosDraft = input.value
  if (state.recadosStatus) state.recadosStatus = ''
  syncDirectorRecadosDom()
}

async function sendDirectorRecado() {
  const input = document.getElementById('recadosDirectorTextarea')
  if (input) state.recadosDraft = input.value
  const text = String(state.recadosDraft || '').trim()
  if (!text || state.recadosSending) {
    state.recadosStatus = text ? state.recadosStatus : 'DIGITE UM RECADO'
    syncDirectorRecadosDom()
    return
  }
  state.recadosSending = true
  state.recadosStatus = 'ENVIANDO...'
  syncDirectorRecadosDom()
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'director',
        text,
        durationMs: DIRECTOR_RECADO_DURATION_MS,
        sessionHash: state.authHash || '',
      }),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao enviar recado')
    state.recadosNoticeExpiresAt = Number(result?.notice?.expiresAt || 0) || (Date.now() + DIRECTOR_RECADO_DURATION_MS)
    state.recadosNoticeId = String(result?.notice?.id || '')
    state.recadosStatus = 'RECADO ATIVO'
    showAppPopup('RECADO ENVIADO', 'success', 1200)
  } catch (error) {
    state.recadosStatus = String(error?.message || 'ERRO AO ENVIAR').toLocaleUpperCase('pt-BR')
  } finally {
    state.recadosSending = false
    syncDirectorRecadosDom()
  }
}

async function cancelDirectorRecado() {
  if (state.recadosSending) return
  state.recadosSending = true
  state.recadosStatus = 'CANCELANDO...'
  syncDirectorRecadosDom()
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'cancel',
        source: 'director',
        sessionHash: state.authHash || '',
      }),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao cancelar recado')
    state.recadosNoticeExpiresAt = 0
    state.recadosNoticeId = ''
    state.recadosStatus = 'RECADO REMOVIDO'
    showAppPopup('RECADO REMOVIDO', 'info', 1000)
  } catch (error) {
    state.recadosStatus = String(error?.message || 'ERRO AO CANCELAR').toLocaleUpperCase('pt-BR')
  } finally {
    state.recadosSending = false
    syncDirectorRecadosDom()
  }
}

function renderRecadosModal() {
  if (!state.showRecadosModal) return ''
  return `<div class="modalOverlay recadosOverlay" data-close-recados><div class="modalSpacer"></div><div class="modalBox recadosModalBox" data-stop-modal><div class="recadosTopButtons"><button class="modalOkBtnWide recadosSendBtn" data-action="recados-send" ${state.recadosSending ? 'disabled' : ''}>${state.recadosSending ? 'ENVIANDO...' : 'ENVIAR'}</button><button class="modalCancelBtn recadosCancelBtn" data-action="recados-cancel">RETIRAR</button><button class="modalCancelBtn recadosCloseBtn" data-action="recados-close">FECHAR</button></div><textarea id="recadosDirectorTextarea" class="recadosTextarea" placeholder="Digite o recado técnico..." maxlength="500">${escapeHtml(state.recadosDraft || '')}</textarea><div id="recadosDirectorStatus" class="recadosStatus">${escapeHtml(getDirectorRecadosStatusText())}</div></div><div class="modalBottomSpace"></div></div>`
}

function openProjectTabsModal() {
  state.settingsMenuOpen = false
  state.showProjectTabsModal = true
  state.selectedProjectTabIndex = Number.isFinite(Number(state.activeProjectTabIndex)) ? Number(state.activeProjectTabIndex) : 0
  armOverlayCloseGuard?.()
  render()
}

function closeProjectTabsModal() {
  if (typeof shouldIgnoreOverlayClose === 'function' && shouldIgnoreOverlayClose()) return
  state.showProjectTabsModal = false
  render()
}

function selectProjectTabInModal(indexValue) {
  const idx = Number(indexValue)
  if (!Number.isFinite(idx)) return
  state.selectedProjectTabIndex = idx
  render()
}

function confirmProjectTabsModal() {
  const idx = Number(state.selectedProjectTabIndex)
  if (!Number.isFinite(idx)) {
    closeProjectTabsModal()
    return
  }
  state.showProjectTabsModal = false
  render()
  postCommand('set_project_tab', { projectTabIndex: idx, index: idx })
  fastPollBridge?.(8)
}

function renderProjectTabsModal() {
  if (!state.showProjectTabsModal) return ''
  const tabs = Array.isArray(state.projectTabs) ? state.projectTabs : []
  const rows = tabs.length
    ? tabs.map((tab, i) => {
        const idx = Number.isFinite(Number(tab.index)) ? Number(tab.index) : i
        const active = idx === Number(state.selectedProjectTabIndex)
        const current = !!(tab.active || tab.isCurrent || idx === Number(state.activeProjectTabIndex))
        const name = upperText(tab.name || tab.projectName || `PROJETO ${i + 1}`)
        return `<button class="${active ? 'projectTabOptionActive' : 'projectTabOption'}" data-project-tab-index="${escapeHtml(String(idx))}"><span class="projectTabOptionText">${escapeHtml(name)}</span>${current ? '<span class="projectTabCurrentBadge">ATUAL</span>' : ''}</button>`
      }).join('')
    : '<div class="emptyBox">Nenhum projeto em aba encontrado</div>'
  return `<div class="modalOverlay" data-close-project-tabs><div class="modalSpacer"></div><div class="modalBox projectTabsModalBox" data-stop-modal><div class="modalTitle">PROJETOS</div><div class="projectTabsList">${rows}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="close-project-tabs">Fechar</button><button class="modalOkBtnWide projectTabsOkBtn" data-action="confirm-project-tabs">OK</button></div></div><div class="modalBottomSpace"></div></div>`
}


function openGearModal() {
  state.settingsMenuOpen = false
  state.showGearModal = true
  render()
}

function closeGearModal() {
  state.showGearModal = false
  render()
}

const RGB_FIXED_HUES = [0, 96, 210, 270, 45, 330, 186, 24, 0]
const RGB_MODE_SEQUENCE = [
  { mode: 'fixed', fixedIndex: 0, label: 'FIXO VERMELHO' },
  { mode: 'fixed', fixedIndex: 1, label: 'FIXO VERDE' },
  { mode: 'fixed', fixedIndex: 2, label: 'FIXO AZUL' },
  { mode: 'fixed', fixedIndex: 3, label: 'FIXO ROXO' },
  { mode: 'fixed', fixedIndex: 4, label: 'FIXO AMARELO' },
  { mode: 'fixed', fixedIndex: 5, label: 'FIXO ROSA' },
  { mode: 'fixed', fixedIndex: 6, label: 'FIXO CIANO' },
  { mode: 'fixed', fixedIndex: 7, label: 'FIXO LARANJA' },
  { mode: 'fixed', fixedIndex: 8, label: 'FIXO BRANCO' },
  { mode: 'auto', fixedIndex: 0, label: 'AUTOMÁTICO' },
  { mode: 'off', fixedIndex: 0, label: 'DESLIGADO' },
]

function normalizeRgbModeState() {
  const allowedModes = new Set(['fixed', 'auto', 'off'])
  if (!allowedModes.has(state.rgbMode)) {
    state.rgbMode = 'auto'
  }

  state.rgbFixedIndex = Math.floor(Number(state.rgbFixedIndex) || 0)
  if (state.rgbFixedIndex < 0 || state.rgbFixedIndex >= RGB_FIXED_HUES.length) {
    state.rgbFixedIndex = 0
  }

  if (state.rgbMode === 'fixed') {
    state.borderHue = RGB_FIXED_HUES[state.rgbFixedIndex] ?? 96
  } else if (state.rgbMode === 'off') {
    state.borderHue = 0
  }
}

function getRgbModeIndex() {
  normalizeRgbModeState()
  const idx = RGB_MODE_SEQUENCE.findIndex((item) => item.mode === state.rgbMode && (item.mode !== 'fixed' || item.fixedIndex === state.rgbFixedIndex))
  return idx >= 0 ? idx : 9
}

function getRgbModeLabel() {
  normalizeRgbModeState()
  const current = RGB_MODE_SEQUENCE[getRgbModeIndex()] || RGB_MODE_SEQUENCE[9]
  return current.label
}

function getBorderColorCss() {
  normalizeRgbModeState()
  if (state.rgbMode === 'fixed' && Number(state.rgbFixedIndex) === 8) return '#f8fafc'
  return `hsl(${state.borderHue}, 100%, 55%)`
}

function getBorderGlowCss() {
  normalizeRgbModeState()
  if (state.rgbMode === 'fixed' && Number(state.rgbFixedIndex) === 8) return 'rgba(248,250,252,0.35)'
  return `hsla(${state.borderHue}, 100%, 55%, 0.35)`
}

function getBlockOutlineColorCss(item = null) {
  return getAppBridgeBlockColor(item) || 'var(--app-border-color)'
}

function getBlockOutlineGlowCss(item = null) {
  const color = getAppBridgeBlockColor(item)
  if (color) return color
  return 'var(--app-border-glow)'
}

function cycleRgbMode() {
  normalizeRgbModeState()
  const currentIndex = getRgbModeIndex()
  const next = RGB_MODE_SEQUENCE[(currentIndex + 1) % RGB_MODE_SEQUENCE.length] || RGB_MODE_SEQUENCE[3]
  state.rgbMode = next.mode
  state.rgbFixedIndex = Math.floor(Number(next.fixedIndex) || 0)
  normalizeRgbModeState()
  updateBorderEffect()
  render()
}

const APP_THEME_STORAGE_KEY = 'vs_hook_app_theme'

function loadThemePreference() {
  try {
    const saved = localStorage.getItem(APP_THEME_STORAGE_KEY)
    if (saved === 'light' || saved === 'dark') {
      state.theme = saved
    }
  } catch (e) {}
}

function saveThemePreference() {
  try {
    localStorage.setItem(APP_THEME_STORAGE_KEY, state.theme)
  } catch (e) {}
}

function setTheme(themeName) {
  state.theme = themeName === 'light' ? 'light' : 'dark'
  saveThemePreference()
  render()
}

function openPlaylist() {
  state.localMarkersMode = false
  state.showGearModal = false
  state.showPlaylistSwitchModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showRecadosModal = false
  state.playlistView = 'songs'
  state.activeTab = 'playlist'
  clearDirectorSelectionForTabSwitch()
  state.pendingTabCommand = 'playlist'
  lockSelectionSync()
  postCommand('set_page', { page: 'playlist' })
  postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
  render()
}

function openRegions() {
  state.localMarkersMode = false
  state.showGearModal = false
  state.showPlaylistSwitchModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showRecadosModal = false
  state.playlistView = 'songs'
  state.activeTab = 'regions'
  clearDirectorSelectionForTabSwitch()
  state.pendingTabCommand = 'regions'
  lockSelectionSync()
  postCommand('set_page', { page: 'regions' })
  postCommand('set_parts_visibility', { page: 'regions', visible: '0' })
  render()
}


function openMarkersPanel() {
  // FIX76: tela de markers bloqueada temporariamente para lançamento.
  // Não altera o Lua nem envia parts_visibility=1 para evitar a tela travada.
  if (state.activeTab !== 'playlist') return false
  state.localMarkersMode = false
  state.playlistView = 'songs'
  state.markersPanelAnimateUntil = 0
  state.settingsMenuOpen = false
  state.showTunerModal = false
  postCommand('set_page', { page: 'playlist' })
  postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
  render()
  return false
}

function closeMarkersPanel() {
  if (state.activeTab !== 'playlist') return
  state.localMarkersMode = false
  state.playlistView = 'songs'
  state.settingsMenuOpen = false
  state.showTunerModal = false
  postCommand('set_page', { page: 'playlist' })
  postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
  render()
}

function openPlaylistSwitchModal() {
  if (state.activeTab !== 'playlist' || !state.playlists.length) return
  state.settingsMenuOpen = false
  state.selectedSwitchPlaylistId = String(state.activePlaylistId || state.playlists[0]?.id || '')
  state.showPlaylistSwitchModal = true
  render()
}

function closePlaylistSwitchModal() {
  state.showPlaylistSwitchModal = false
  state.showDeletePlaylistConfirmModal = false
  state.selectedSwitchPlaylistId = null
  render()
}

function handlePlaylistSwitchSelect(playlistId) {
  const key = String(playlistId || '')
  if (!key) return
  state.selectedSwitchPlaylistId = key
  render()
}

function handleConfirmPlaylistSwitch() {
  const key = String(state.selectedSwitchPlaylistId || '')
  if (!key) return
  state.activePlaylistId = key
  state.pendingPlaylistSwitchId = key
  state.pendingPlaylistSwitchUntilMs = Date.now() + 9000
  state.showPlaylistSwitchModal = false
  state.settingsMenuOpen = false
  state.localMarkersMode = false
  state.playlistView = 'songs'
  state.activeTab = 'playlist'
  clearDirectorSelectionForTabSwitch()
  state.pendingTabCommand = 'playlist'
  postCommand('set_page', { page: 'playlist' })
  postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
  postCommand('set_active_playlist', { playlistId: key })
  render()
}

function handleRenamePlaylistSwitch() {
  const key = String(state.selectedSwitchPlaylistId || '')
  if (!key) return
  const playlist = state.playlists.find((entry) => String(entry.id) === key)
  if (!playlist) return
  state.showPlaylistSwitchModal = false
  state.showRenameModal = true
  state.renameTargetType = 'playlist_collection'
  state.renameTargetId = key
  state.renameIsBlock = false
  state.renameValue = String(playlist.name || '')
  render()
}

function handleDeletePlaylistSwitch() {
  const key = String(state.selectedSwitchPlaylistId || '')
  if (!key) return
  state.showDeletePlaylistConfirmModal = true
  render()
}

function closeDeletePlaylistConfirmModal() {
  state.showDeletePlaylistConfirmModal = false
  render()
}

function handleConfirmDeletePlaylist() {
  const key = String(state.selectedSwitchPlaylistId || '')
  if (!key) {
    state.showDeletePlaylistConfirmModal = false
    render()
    return
  }

  state.playlists = (state.playlists || []).filter((playlist) => String(playlist.id) !== key)

  if (String(state.activePlaylistId || '') === key) {
    const nextPlaylist = state.playlists[0] || null
    state.activePlaylistId = nextPlaylist ? String(nextPlaylist.id) : null
    if (nextPlaylist) {
      postCommand('set_active_playlist', { playlistId: String(nextPlaylist.id) })
    }
  }

  const nextSelected = state.playlists[0] ? String(state.playlists[0].id) : null
  state.selectedSwitchPlaylistId = nextSelected
  state.showDeletePlaylistConfirmModal = false
  state.showPlaylistSwitchModal = true
  postCommand('delete_playlist', { playlistId: key })
  render()
}

function enableMultiSelect(tabName, clickedId = null) {
  state.multiSelectMode = true
  state.multiSelectTab = tabName
  if (tabName === 'regions') {
    state.selectedRegionId = null
    state.selectedRegionIds = clickedId != null ? [String(clickedId)] : []
    state.selectedPlaylistSongIds = []
  } else if (tabName === 'playlist') {
    state.selectedPlaylistSongId = null
    state.selectedPlaylistSongIds = clickedId != null ? [String(clickedId)] : []
    state.selectedRegionIds = []
  }
  state.selectedMarkerId = null
  render()
}

function disableMultiSelect() {
  state.multiSelectMode = false
  state.multiSelectTab = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongIds = []
  render()
}

function disableMultiSelectAndClear() {
  state.multiSelectMode = false
  state.multiSelectTab = null
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.selectedMarkerId = null
  state.showCreatePlaylistModal = false
  state.showAddExistingModal = false
  state.showRenameModal = false
  state.renameValue = ''
  state.renameTargetType = null
  state.renameTargetId = null
  state.renameIsBlock = false
  lockSelectionSync()
  postCommand('clear_selection')
  render()
}

function toggleMultiSelectForItem(tabName, id) {
  if (isMultiSelectActiveFor(tabName)) {
    disableMultiSelect()
  } else {
    enableMultiSelect(tabName, id)
  }
}

function resetDragState() {
  state.dragType = null
  state.dragSelectedIds = []
  state.dragHoverId = null
  state.dragActive = false
  state.dragSnapshot = null
  state.dragPointerId = null
  state.dragPending = null
  state.dragLastClientY = null
  document.body.style.userSelect = ''
}

function clearSelectionState() {
  clearStoppedSelectionHold()
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.selectedMarkerId = null
}

function clearDirectorSelectionForTabSwitch() {
  clearStoppedSelectionHold()
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.selectedMarkerId = null
  state.multiSelectMode = false
  state.multiSelectTab = null
}

function clearSelectionForFreshSingleSelection(tabName) {
  clearStoppedSelectionHold()
  state.selectedMarkerId = null
  state.multiSelectMode = false
  state.multiSelectTab = null

  if (tabName === 'playlist') {
    state.selectedRegionId = null
    state.selectedRegionIds = []
  } else if (tabName === 'regions') {
    state.selectedPlaylistSongId = null
    state.selectedPlaylistSongIds = []
  }
}

function normalizeSingleSelectionForActiveTab() {
  if (state.activeTab === 'playlist') {
    state.selectedRegionId = null
    state.selectedRegionIds = []
  } else if (state.activeTab === 'regions') {
    state.selectedPlaylistSongId = null
    state.selectedPlaylistSongIds = []
  }
}

function setEditSingleSelection(tabName, key) {
  const safeKey = String(key)
  if (tabName === 'playlist') {
    state.selectedPlaylistSongId = safeKey
    state.selectedPlaylistSongIds = []
    state.selectedRegionId = null
    state.selectedRegionIds = []
  } else {
    state.selectedRegionId = safeKey
    state.selectedRegionIds = []
    state.selectedPlaylistSongId = null
    state.selectedPlaylistSongIds = []
  }
  state.multiSelectMode = false
  state.multiSelectTab = null
  state.selectedMarkerId = null
}

function exitDeleteMode(options = {}) {
  const { shouldRender = true } = options
  state.settingsMenuOpen = false
  state.deleteMode = false
  state.multiSelectMode = false
  state.multiSelectTab = null
  clearSelectionState()
  lockSelectionSync()
  postCommand('clear_selection')
  if (shouldRender) render()
}

function enterDeleteMode() {
  if (state.activeTab !== 'playlist' || state.playlistView === 'markers') return
  resetDragState()
  state.settingsMenuOpen = false
  state.editMode = false
  state.deleteMode = true
  state.multiSelectMode = true
  state.multiSelectTab = 'playlist'
  if (state.selectedPlaylistSongId && !state.selectedPlaylistSongIds.length) {
    state.selectedPlaylistSongIds = [String(state.selectedPlaylistSongId)]
  }
  state.selectedPlaylistSongId = null
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedMarkerId = null
  render()
}

function enterEditMode() {
  if (state.activeTab === 'playlist' && state.playlistView === 'markers') return
  state.settingsMenuOpen = false
  state.deleteMode = false
  state.editMode = true
  state.multiSelectMode = false
  state.multiSelectTab = null
  if (state.activeTab === 'playlist') {
    if (!state.selectedPlaylistSongId && state.selectedPlaylistSongIds.length) {
      state.selectedPlaylistSongId = String(state.selectedPlaylistSongIds[0])
    }
    state.selectedPlaylistSongIds = []
    state.selectedRegionIds = []
  } else {
    if (!state.selectedRegionId && state.selectedRegionIds.length) {
      state.selectedRegionId = String(state.selectedRegionIds[0])
    }
    state.selectedRegionIds = []
    state.selectedPlaylistSongIds = []
  }
  state.selectedMarkerId = null
  render()
}

function exitEditMode() {
  state.settingsMenuOpen = false
  state.editMode = false
  resetDragState()
  state.selectedPlaylistSongIds = []
  state.selectedRegionIds = []
  render()
}

function enterSelectMode() {
  if (state.activeTab !== 'regions') return
  state.settingsMenuOpen = false
  state.editMode = false
  state.deleteMode = false
  state.multiSelectMode = true
  state.multiSelectTab = 'regions'
  if (state.selectedRegionId && !state.selectedRegionIds.length) {
    state.selectedRegionIds = [String(state.selectedRegionId)]
  }
  state.selectedRegionId = null
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.selectedMarkerId = null
  render()
}

function exitSelectMode() {
  if (!isMultiSelectActiveFor('regions')) return
  state.settingsMenuOpen = false
  disableMultiSelectAndClear()
}

function handleToggleSettingsMenu(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (state.activeTab === 'playlist' && state.playlistView === 'markers') return
  state.settingsMenuOpen = !state.settingsMenuOpen
  render()
}

function handleEditAction(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (state.editMode) {
    exitEditMode()
  } else {
    enterEditMode()
  }
}

function handleDeleteModeAction(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (state.deleteMode) {
    exitDeleteMode()
  } else {
    enterDeleteMode()
  }
}

function handleSelectAction(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (isMultiSelectActiveFor('regions')) {
    exitSelectMode()
  } else {
    enterSelectMode()
  }
}

function handleEditDone(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  exitEditMode()
}

function handleDeleteCancel(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  exitDeleteMode()
}

function handleDeleteConfirm(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (!state.deleteMode || state.activeTab !== 'playlist' || state.playlistView === 'markers') return
  const ids = state.selectedPlaylistSongIds.map(String)
  if (!ids.length) {
    exitDeleteMode()
    return
  }
  const playlist = activePlaylist()
  if (playlist && Array.isArray(playlist.songs)) {
    const selected = new Set(ids)
    playlist.songs = playlist.songs.filter((item) => !selected.has(String(item.id)))
  }
  postCommand('delete_playlist_items', { ids })
  exitDeleteMode({ shouldRender: false })
  render()
}

function selectEditItem(tabName, key) {
  if (tabName === 'playlist') {
    if (!state.multiSelectMode || state.multiSelectTab !== 'playlist') {
      state.multiSelectMode = true
      state.multiSelectTab = 'playlist'
    }
    state.selectedPlaylistSongId = null
    if (state.selectedPlaylistSongIds.includes(key)) {
      state.selectedPlaylistSongIds = state.selectedPlaylistSongIds.filter((item) => item !== key)
    } else {
      state.selectedPlaylistSongIds = [...state.selectedPlaylistSongIds, key]
    }
    render()
    return
  }

  if (!state.multiSelectMode || state.multiSelectTab !== 'regions') {
    state.multiSelectMode = true
    state.multiSelectTab = 'regions'
  }
  state.selectedRegionId = null
  if (state.selectedRegionIds.includes(key)) {
    state.selectedRegionIds = state.selectedRegionIds.filter((item) => item !== key)
  } else {
    state.selectedRegionIds = [...state.selectedRegionIds, key]
  }
  lockSelectionSync()
  postCommand('select_regions', { ids: state.selectedRegionIds })
  render()
}

function getEditSelectedIds(tabName, fallbackId = null) {
  return fallbackId != null ? [String(fallbackId)] : []
}

function captureDragSnapshot(tabName) {
  if (tabName === 'playlist') {
    const playlist = activePlaylist()
    if (!playlist || !Array.isArray(playlist.songs)) return []
    return playlist.songs.slice()
  }
  return state.regions.slice()
}

function restoreDragSnapshot(tabName, snapshot) {
  if (!Array.isArray(snapshot)) return
  if (tabName === 'playlist') {
    const playlist = activePlaylist()
    if (!playlist || !Array.isArray(playlist.songs)) return
    playlist.songs = snapshot.slice()
    return
  }
  state.regions = snapshot.slice()
}

function applyDragPreview(tabName, selectedIds, targetId) {
  const snapshot = state.dragSnapshot
  if (!Array.isArray(snapshot)) return
  restoreDragSnapshot(tabName, snapshot)
}

function captureDragLayout(tabName, selectedIds) {
  const selector = tabName === 'playlist' ? '[data-song-id]' : '[data-region-id]'
  const attr = tabName === 'playlist' ? 'data-song-id' : 'data-region-id'
  const selectedSet = new Set((selectedIds || []).map(String))
  return Array.from(document.querySelectorAll(selector)).map((row) => {
    const id = String(row.getAttribute(attr) || '')
    if (!id || selectedSet.has(id)) return null
    const rect = row.getBoundingClientRect()
    return {
      id,
      top: rect.top,
      bottom: rect.bottom,
      mid: rect.top + (rect.height / 2),
    }
  }).filter(Boolean)
}

function reorderLocalArray(items, selectedIds, targetId) {
  const source = Array.isArray(items) ? items.slice() : []
  const wanted = selectedIds.map(String)
  if (!source.length || !wanted.length) return source
  if (wanted.includes(String(targetId))) return source
  const selectedSet = new Set(wanted)
  const selectedItems = source.filter((item) => selectedSet.has(String(item.id)))
  const unselectedItems = source.filter((item) => !selectedSet.has(String(item.id)))
  let insertPos = unselectedItems.findIndex((item) => String(item.id) === String(targetId))
  if (insertPos < 0) insertPos = unselectedItems.length
  return [...unselectedItems.slice(0, insertPos), ...selectedItems, ...unselectedItems.slice(insertPos)]
}

function applyLocalReorder(tabName, selectedIds, targetId) {
  if (tabName === 'playlist') {
    const playlist = activePlaylist()
    if (!playlist || !Array.isArray(playlist.songs)) return
    playlist.songs = reorderLocalArray(playlist.songs, selectedIds, targetId)
    state.selectedPlaylistSongIds = selectedIds.map(String)
    return
  }
  state.regions = reorderLocalArray(state.regions, selectedIds, targetId)
  state.selectedRegionIds = selectedIds.map(String)
}

function beginEditDrag(tabName, id, clientX, clientY, pointerId = null) {
  if (!state.editMode) return
  const key = String(id)
  const selectedIds = [key]
  setEditSingleSelection(tabName, key)
  state.dragType = tabName
  state.dragSelectedIds = selectedIds.map(String)
  state.dragHoverId = null
  state.dragActive = true
  state.dragSnapshot = captureDragSnapshot(tabName)
  state.dragLayout = captureDragLayout(tabName, selectedIds)
  state.dragPointerId = pointerId
  state.dragPending = null
  state.dragLastClientY = clientY
  document.body.style.userSelect = 'none'
  suppressEditClickUntil = Date.now() + 250
  render()
}

function getDragHoverCandidate(layout, clientY) {
  if (!Array.isArray(layout) || !layout.length) return null
  let nextHoverId = layout[layout.length - 1].id
  for (let i = 0; i < layout.length; i += 1) {
    const row = layout[i]
    if (clientY <= row.mid) {
      nextHoverId = row.id
      break
    }
  }
  return nextHoverId
}

function getDragStickyMargin(row) {
  const height = Math.max(1, Number(row?.bottom || 0) - Number(row?.top || 0))
  return Math.max(12, Math.min(20, height * 0.32))
}

function updateEditDrag(clientX, clientY) {
  if (!state.dragActive || !state.dragType) return
  const layout = Array.isArray(state.dragLayout) ? state.dragLayout : []
  if (!layout.length) return

  const nextHoverId = getDragHoverCandidate(layout, clientY)
  if (!nextHoverId) return

  const currentHoverId = state.dragHoverId
  if (!currentHoverId) {
    state.dragHoverId = nextHoverId
    state.dragLastClientY = clientY
    render()
    return
  }

  if (nextHoverId === currentHoverId) {
    state.dragLastClientY = clientY
    return
  }

  const currentIndex = layout.findIndex((row) => row.id === currentHoverId)
  const nextIndex = layout.findIndex((row) => row.id === nextHoverId)

  if (currentIndex >= 0 && nextIndex >= 0) {
    const currentRow = layout[currentIndex]
    const stickyMargin = getDragStickyMargin(currentRow)

    if (nextIndex > currentIndex) {
      if (clientY < currentRow.bottom - stickyMargin) {
        state.dragLastClientY = clientY
        return
      }

      for (let i = currentIndex + 1; i < nextIndex; i += 1) {
        const probeRow = layout[i]
        const probeMargin = getDragStickyMargin(probeRow)
        if (clientY < probeRow.bottom - probeMargin) {
          if (state.dragHoverId !== probeRow.id) {
            state.dragHoverId = probeRow.id
            state.dragLastClientY = clientY
            render()
          } else {
            state.dragLastClientY = clientY
          }
          return
        }
      }
    } else if (nextIndex < currentIndex) {
      if (clientY > currentRow.top + stickyMargin) {
        state.dragLastClientY = clientY
        return
      }

      for (let i = currentIndex - 1; i > nextIndex; i -= 1) {
        const probeRow = layout[i]
        const probeMargin = getDragStickyMargin(probeRow)
        if (clientY > probeRow.top + probeMargin) {
          if (state.dragHoverId !== probeRow.id) {
            state.dragHoverId = probeRow.id
            state.dragLastClientY = clientY
            render()
          } else {
            state.dragLastClientY = clientY
          }
          return
        }
      }
    }
  }

  state.dragHoverId = nextHoverId
  state.dragLastClientY = clientY
  render()
}

function endEditDrag() {
  if (!state.dragActive || !state.dragType) {
    state.dragType = null
    state.dragSelectedIds = []
    state.dragHoverId = null
    state.dragActive = false
    state.dragSnapshot = null
    state.dragPointerId = null
    state.dragLayout = []
    state.dragLastClientY = null
    return
  }
  const tabName = state.dragType
  const ids = state.dragSelectedIds.slice()
  const targetId = state.dragHoverId
  const snapshot = Array.isArray(state.dragSnapshot) ? state.dragSnapshot.slice() : null
  state.dragType = null
  state.dragSelectedIds = []
  state.dragActive = false
  state.dragHoverId = null
  state.dragSnapshot = null
  state.dragPointerId = null
  state.dragLayout = []
  state.dragLastClientY = null
  document.body.style.userSelect = ''

  if (!targetId || ids.includes(String(targetId))) {
    if (snapshot) restoreDragSnapshot(tabName, snapshot)
    render()
    return
  }

  suppressEditClickUntil = Date.now() + 250
  applyLocalReorder(tabName, ids, targetId)
  if (tabName === 'playlist') {
    postCommand('reorder_playlist_items', { ids, targetId: String(targetId) })
  } else {
    postCommand('reorder_regions', { ids, targetId: String(targetId) })
  }
  render()
}

function bindEditDragHandlers(selector, tabName) {
  const attr = tabName === 'playlist' ? 'data-song-id' : 'data-region-id'
  document.querySelectorAll(selector).forEach((row) => {
    const id = row.getAttribute(attr)
    if (!id) return

    const startPointerDrag = (event) => {
      if (!state.editMode || state.deleteMode) return
      if (event.pointerType === 'mouse' && event.button !== 0) return
      if (event.target instanceof Element) {
        if (event.target.closest('[data-action], input, button, .settingsMenu')) return
      }
      event.preventDefault()
      event.stopPropagation()
      state.dragPending = {
        tabName,
        id: String(id),
        startX: event.clientX,
        startY: event.clientY,
        pointerId: event.pointerId ?? null,
      }
      suppressEditClickUntil = Date.now() + 250
    }

    row.addEventListener('pointerdown', startPointerDrag)
    row.addEventListener('click', (event) => {
      if (!state.editMode) return
      event.preventDefault()
      event.stopPropagation()
    })
  })
}

// 2.0.30: Marker armado no Diretor fica verde/local até Cancelar/ESC.
// O Bridge parado pode demorar a confirmar selectedMarkerId; então o front mantém
// a seleção local para o segundo clique e para exibir o botão Cancelar.
const DIRECTOR_MARKER_LOCAL_HOLD_MS = 12000
const DIRECTOR_MARKER_ARMED_HOLD_MS = 7200000
let directorMarkerLocalHoldId = null
let directorMarkerLocalHoldUntil = 0
let directorMarkerArmedLocalHoldId = null
let directorMarkerArmedLocalHoldUntil = 0

function setDirectorMarkerLocalHold(id, ms = DIRECTOR_MARKER_LOCAL_HOLD_MS) {
  const key = String(id ?? '')
  if (!key) return
  directorMarkerLocalHoldId = key
  directorMarkerLocalHoldUntil = Date.now() + Math.max(800, Number(ms) || DIRECTOR_MARKER_LOCAL_HOLD_MS)
}

function clearDirectorMarkerLocalHold() {
  directorMarkerLocalHoldId = null
  directorMarkerLocalHoldUntil = 0
}

function setDirectorMarkerArmedLocalHold(id, ms = DIRECTOR_MARKER_ARMED_HOLD_MS) {
  const key = String(id ?? '')
  if (!key) return
  directorMarkerArmedLocalHoldId = key
  directorMarkerArmedLocalHoldUntil = Date.now() + Math.max(1200, Number(ms) || DIRECTOR_MARKER_ARMED_HOLD_MS)
}

function clearDirectorMarkerArmedLocalHold() {
  directorMarkerArmedLocalHoldId = null
  directorMarkerArmedLocalHoldUntil = 0
}

function getActiveDirectorMarkerArmedLocalHoldId() {
  const key = String(directorMarkerArmedLocalHoldId || '')
  if (!key) return null
  if (Date.now() >= Number(directorMarkerArmedLocalHoldUntil || 0)) {
    clearDirectorMarkerArmedLocalHold()
    return null
  }
  return key
}

function isDirectorMarkerArmedLocally(id) {
  const key = String(id ?? '')
  const armed = getActiveDirectorMarkerArmedLocalHoldId()
  return !!(key && armed && key === armed)
}

function getDirectorMarkerArmedVisualId() {
  return String(state.markerGoFlashId || '') || getActiveDirectorMarkerArmedLocalHoldId() || ''
}

function shouldShowDirectorMarkerCancelButton() {
  if (!isMarkersPanelOpen()) return false
  return !!String(getDirectorMarkerArmedVisualId?.() || '').trim()
}

function getActiveDirectorMarkerLocalHoldId() {
  const key = String(directorMarkerLocalHoldId || '')
  if (!key) return null
  if (Date.now() >= Number(directorMarkerLocalHoldUntil || 0)) {
    clearDirectorMarkerLocalHold()
    return null
  }
  return key
}

function isDirectorMarkerLocallyHeld(id) {
  const key = String(id ?? '')
  const held = getActiveDirectorMarkerLocalHoldId()
  return !!(key && held && key === held)
}

function handleMarkerCancel() {
  state.markerGoFlashId = null
  state.markerGoFlashStartedAtMs = 0
  state.markerGoFlashForceUntil = 0
  state.selectedMarkerId = null
  clearDirectorMarkerLocalHold()
  clearDirectorMarkerArmedLocalHold()
  postCommand('marker_cancel', { key: 'ESC', escapeKey: true, activeTab: 'playlist', page: 'markers' })
  showAppPopup('MARKER CANCELADO', 'error', 1200)
}

function handleDeleteSelectedPlaylistItems() {
  handleDeleteConfirm()
}


function getRenameTargetContext() {
  if (state.editMode || state.deleteMode) return null

  if (state.activeTab === 'playlist') {
    if (state.playlistView === 'markers') return null
    if (!state.selectedPlaylistSongId) return null
    const id = String(state.selectedPlaylistSongId)
    const playlist = activePlaylist()
    const item = Array.isArray(playlist?.songs) ? playlist.songs.find((entry) => String(entry.id) === id) : null
    if (!item) return null
    return { type: 'playlist', id, item, isBlock: detectBlockItem(item) }
  }

  if (state.activeTab === 'regions') {
    if (isMultiSelectActiveFor('regions')) return null
    if (!state.selectedRegionId) return null
    const id = String(state.selectedRegionId)
    const item = state.regions.find((entry) => String(entry.id) === id)
    if (!item) return null
    return { type: 'region', id, item, isBlock: false }
  }

  return null
}

function handleOpenRenameAction(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const target = getRenameTargetContext()
  if (!target) return
  state.settingsMenuOpen = false
  state.showRenameModal = true
  state.renameTargetType = target.type
  state.renameTargetId = target.id
  state.renameIsBlock = !!target.isBlock
  if (target.isBlock) {
    const suffix = extractBlockSuffix(target.item.name || target.item.label || '', getBlockFallbackSuffix(target.item))
    state.renameValue = /^\d+$/.test(suffix) ? '' : suffix
  } else {
    state.renameValue = String(target.item.name || target.item.label || '')
  }
  render()
}

function handleCloseRenameModal() {
  state.showRenameModal = false
  state.renameValue = ''
  state.renameTargetType = null
  state.renameTargetId = null
  state.renameIsBlock = false
  render()
}

function handleConfirmRenameModal() {
  if (!state.showRenameModal || !state.renameTargetType || !state.renameTargetId) return
  const rawValue = String(state.renameValue || '').trim()

  if (state.renameTargetType === 'playlist') {
    const playlist = activePlaylist()
    const item = Array.isArray(playlist?.songs) ? playlist.songs.find((entry) => String(entry.id) === String(state.renameTargetId)) : null
    if (!item) {
      handleCloseRenameModal()
      return
    }
    if (detectBlockItem(item)) {
      const suffix = rawValue ? upperText(rawValue) : getBlockFallbackSuffix(item)
      item.name = `BLOCO ${suffix}`
      postCommand('rename_playlist_item', { id: String(state.renameTargetId), name: suffix, customName: false })
    } else {
      const nextName = rawValue ? upperText(rawValue) : upperText(item.name || item.label || '')
      if (!nextName) {
        handleCloseRenameModal()
        return
      }
      item.name = nextName
      postCommand('rename_playlist_item', { id: String(state.renameTargetId), name: nextName })
    }
  } else if (state.renameTargetType === 'region') {
    const region = state.regions.find((entry) => String(entry.id) === String(state.renameTargetId))
    if (!region) {
      handleCloseRenameModal()
      return
    }
    const nextName = rawValue ? upperText(rawValue) : upperText(region.name || region.label || '')
    if (!nextName) {
      handleCloseRenameModal()
      return
    }
    region.name = nextName
    postCommand('rename_region', { id: String(state.renameTargetId), name: nextName })
  } else if (state.renameTargetType === 'playlist_collection') {
    const playlistId = String(state.renameTargetId)
    const playlistItem = state.playlists.find((entry) => String(entry.id) === playlistId)
    const nextName = rawValue ? upperText(rawValue) : upperText(playlistItem?.name || '')
    if (!playlistItem || !nextName) {
      handleCloseRenameModal()
      return
    }
    playlistItem.name = nextName
    postCommand('rename_playlist', { playlistId, name: nextName })
    state.showRenameModal = false
    state.renameValue = ''
    state.renameTargetType = null
    state.renameTargetId = null
    state.renameIsBlock = false
    state.showPlaylistSwitchModal = true
    state.selectedSwitchPlaylistId = playlistId
    render()
    return
  }

  state.showRenameModal = false
  state.renameValue = ''
  state.renameTargetType = null
  state.renameTargetId = null
  state.renameIsBlock = false
  render()
}


function isAppItemIdHashChild(id, preferredList = null) {
  const key = String(id ?? '')
  if (!key) return false
  const lists = []
  if (Array.isArray(preferredList)) lists.push(preferredList)
  const playlist = activePlaylist ? activePlaylist() : null
  if (Array.isArray(playlist?.songs)) lists.push(playlist.songs)
  if (Array.isArray(state.regions)) lists.push(state.regions)
  for (const list of lists) {
    const item = list.find((entry) => String(entry?.id ?? entry?.songId ?? '') === key)
    if (item) return isHashChildItem(item)
  }
  return false
}

function selectRegion(id) {
  clearStoppedSelectionHold()
  const key = String(id)
  const item = Array.isArray(state.regions) ? state.regions.find((entry) => String(entry?.id ?? '') === key) : null

  if (shouldIgnoreHashChildClickDuringPlayback(item, key)) {
    return
  }

  if (state.deleteMode) return

  if (state.editMode) {
    if (Date.now() < suppressEditClickUntil) return
    return
  }

  if (state.playingId && String(state.playingId) !== key) {
    // Aba MÚSICAS agora cria fila manual igual à aba Repertórios.
    // A fila é global: ao escolher uma música aqui, qualquer amarelo antigo
    // de Repertórios deixa de ser a fila visual.
    clearSelectionForFreshSingleSelection('regions')

    if (item && detectBlockItem(item)) {
      const nextPlayableId = resolvePlaybackTargetIdForBlock(key, 'regions')
      if (!nextPlayableId || String(nextPlayableId) === key) {
        showAppPopup('BLOCO SEM MÚSICA ABAIXO', 'error', 1400)
        render()
        return
      }
      if (isAppItemIdHashChild(nextPlayableId)) return
      const localQueuedSongId = getLocalQueuedSongIdForRows()
      lockSelectionSync()
      state.selectedRegionId = null
      state.selectedRegionIds = []
      if (String(localQueuedSongId || '') === String(nextPlayableId)) {
        clearQueueAndMaybeAutoplay()
      } else {
        setLocalQueuedSong(nextPlayableId, 'regions')
        postCommand('queue_region_song', buildQueueOnlyPayload(nextPlayableId, 'regions'))
        render()
      }
      return
    }

    const localQueuedSongId = getLocalQueuedSongIdForRows()
    lockSelectionSync()
    state.selectedRegionId = null
    state.selectedRegionIds = []

    if (String(localQueuedSongId || '') === key) {
      clearQueueAndMaybeAutoplay()
    } else {
      setLocalQueuedSong(key, 'regions')
      postCommand('queue_region_song', buildQueueOnlyPayload(key, 'regions'))
      render()
    }
    return
  }

  if (isMultiSelectActiveFor('regions')) {
    if (state.selectedRegionIds.includes(key)) {
      if (state.selectedRegionIds.length === 1) {
        disableMultiSelectAndClear()
        return
      }
      state.selectedRegionIds = state.selectedRegionIds.filter((item) => item !== key)
    } else {
      state.selectedRegionIds = [...state.selectedRegionIds, key]
    }
    lockSelectionSync()
    postCommand('select_regions', { ids: state.selectedRegionIds })
    render()
    return
  }

  clearSelectionForFreshSingleSelection('regions')

  if (String(state.selectedRegionId || '') === key) {
    state.selectedRegionId = null
    state.selectedRegionIds = []
    clearDirectorLocalSelectionHold()
    lockSelectionSync()
    postCommand('clear_selection', { activeTab: 'regions' })
    render()
    return
  }

  state.selectedRegionId = key
  state.selectedRegionIds = []
  setDirectorLocalSelectionHold(key, 'regions')
  lockSelectionSync(DIRECTOR_LOCAL_SELECTION_HOLD_MS)
  render()
  postCommand('select_region', { id: key, activeTab: 'regions' })
}


function getAutoplayVisualEnabled() {
  if (pendingAutoplayVisualValue !== null && Date.now() < Number(pendingAutoplayVisualUntil || 0)) {
    return !!pendingAutoplayVisualValue
  }
  pendingAutoplayVisualValue = null
  pendingAutoplayVisualUntil = 0
  return !!state.autoplayEnabled
}

function setAutoplayVisualEnabled(value, ttlMs = 2500) {
  const enabled = !!value
  pendingAutoplayVisualValue = enabled
  pendingAutoplayVisualUntil = Date.now() + Math.max(300, Number(ttlMs) || 2500)
  state.autoplayEnabled = enabled
  if (!enabled) {
    clearVisualQueueForDirector()
  }
  return enabled
}

function clearQueueAndMaybeAutoplay() {
  clearVisualQueueForDirector()
  lockSelectionSync()
  state.selectedPlaylistSongId = null
  postCommand('clear_queue')
  if (getAutoplayVisualEnabled()) {
    setAutoplayVisualEnabled(false)
    postCommand('autoplay_set', { desiredAutoplay: false, desiredState: 'off' })
  }
  render()
}

function selectPlaylistSong(id) {
  clearStoppedSelectionHold()
  const key = String(id)
  const playlist = activePlaylist()
  const item = Array.isArray(playlist?.songs) ? playlist.songs.find((entry) => String(entry?.id ?? entry?.songId ?? '') === key) : null
  state.selectedMarkerId = null

  if (shouldIgnoreHashChildClickDuringPlayback(item, key)) {
    return
  }

  if (state.deleteMode) {
    if (state.selectedPlaylistSongIds.includes(key)) {
      state.selectedPlaylistSongIds = state.selectedPlaylistSongIds.filter((item) => item !== key)
    } else {
      state.selectedPlaylistSongIds = [...state.selectedPlaylistSongIds, key]
    }
    state.selectedPlaylistSongId = null
    render()
    return
  }

  if (state.editMode) {
    if (Date.now() < suppressEditClickUntil) return
    return
  }

  if (state.playingId && String(state.playingId) !== key) {
    clearSelectionForFreshSingleSelection('playlist')

    if (item && detectBlockItem(item)) {
      const nextPlayableId = resolvePlaybackTargetIdForBlock(key, 'playlist')
      if (!nextPlayableId || String(nextPlayableId) === key) {
        showAppPopup('BLOCO SEM MÚSICA ABAIXO', 'error', 1400)
        render()
        return
      }
      if (isAppItemIdHashChild(nextPlayableId)) return
      const localQueuedSongId = getLocalQueuedSongIdForRows()
      lockSelectionSync()
      state.selectedPlaylistSongId = null
      if (String(localQueuedSongId || '') === String(nextPlayableId)) {
        clearQueueAndMaybeAutoplay()
      } else {
        setLocalQueuedSong(nextPlayableId, 'playlist')
        postCommand('queue_playlist_song', buildQueueOnlyPayload(nextPlayableId, 'playlist'))
        render()
      }
      return
    }

    const localQueuedSongId = getLocalQueuedSongIdForRows()
    lockSelectionSync()
    state.selectedPlaylistSongId = null

    if (String(localQueuedSongId || '') === key) {
      clearQueueAndMaybeAutoplay()
    } else {
      setLocalQueuedSong(key, 'playlist')
      postCommand('queue_playlist_song', buildQueueOnlyPayload(key, 'playlist'))
      render()
    }
    return
  }

  clearSelectionForFreshSingleSelection('playlist')

  if (String(state.selectedPlaylistSongId || '') === key) {
    state.selectedPlaylistSongId = null
    state.selectedPlaylistSongIds = []
    clearDirectorLocalSelectionHold()
    lockSelectionSync()
    postCommand('clear_selection', { activeTab: 'playlist' })
    render()
    return
  }

  state.selectedPlaylistSongId = key
  state.selectedPlaylistSongIds = []
  setDirectorLocalSelectionHold(key, 'playlist')
  lockSelectionSync(DIRECTOR_LOCAL_SELECTION_HOLD_MS)
  render()
  postCommand('select_playlist_song', {
    id: key,
    targetId: key,
    songId: key,
    activeTab: 'playlist',
    playlistId: state.activePlaylistId || playlist?.id || '',
    playlistName: playlist?.name || state.activePlaylistName || state.currentPlaylistName || '',
    sourceNumber: item?.sourceNumber ?? item?.source_number ?? key,
    source_number: item?.source_number ?? item?.sourceNumber ?? key,
    startPos: item?.startPos ?? item?.start_pos,
    endPos: item?.endPos ?? item?.end_pos,
    playlistOrder: item?.playlistOrder ?? item?.order ?? item?.index,
    index: item?.index,
    familyRole: item?.familyRole || item?.type || item?.itemType || '',
    isHashChild: !!item?.isHashChild,
    parentId: item?.parentId || '',
  })
  fastPollBridge(5)
}


function buildDirectorMarkerCommandPayload(key) {
  const marker = currentMarkers().find((entry) => String(entry?.id) === String(key)) || null
  const originalIndex = marker?.originalIndex ?? marker?.markerOriginalIndex ?? marker?.sourceIndex ?? marker?.index ?? key
  const commandId = originalIndex != null && String(originalIndex) !== '' ? String(originalIndex) : String(key)
  return {
    id: commandId,
    markerId: String(key),
    selectedMarkerId: String(key),
    targetId: commandId,
    markerOriginalIndex: originalIndex,
    originalIndex,
    timeSec: marker?.timeSec,
    position: marker?.timeSec,
    songId: marker?.songId,
    name: marker?.name || marker?.label || '',
    confirm: false,
  }
}

function selectMarker(id) {
  clearStoppedSelectionHold()
  const key = String(id)
  if (!key) return

  const alreadySelected = String(state.selectedMarkerId || '') === key || isDirectorMarkerLocallyHeld(key) || String(state.markerGoFlashId || '') === key
  if (alreadySelected) {
    // Segundo clique confirma/engatilha o marker: fica verde até cancelar/ESC.
    state.selectedMarkerId = key
    state.markerGoFlashId = key
    state.markerGoFlashStartedAtMs = Date.now()
    state.markerGoFlashForceUntil = Date.now() + 3600000
    try {
      const markerItem = currentMarkers().find((entry) => String(entry?.id) === key)
      state.markerGoFlashTargetSec = Number(markerItem?.timeSec)
    } catch (_) {
      state.markerGoFlashTargetSec = null
    }
    setDirectorMarkerLocalHold(key)
    setDirectorMarkerArmedLocalHold(key)
    postCommand('marker_go', { ...buildDirectorMarkerCommandPayload(key), confirm: true })
    showAppPopup('MARKER ENGATILHADO', 'marker', 1200)
  } else {
    // Primeiro clique apenas seleciona: fica amarelo.
    state.selectedMarkerId = key
    state.markerGoFlashId = null
    state.markerGoFlashStartedAtMs = 0
    state.markerGoFlashForceUntil = 0
    state.markerGoFlashTargetSec = null
    clearDirectorMarkerArmedLocalHold()
    setDirectorMarkerLocalHold(key)
    postCommand('marker_select', { ...buildDirectorMarkerCommandPayload(key), confirm: false })
  }
  render()
}

function handleSelectAll() {
  if (state.activeTab !== 'regions') return
  state.multiSelectMode = true
  state.multiSelectTab = 'regions'
  state.selectedRegionId = null
  state.selectedPlaylistSongIds = []
  state.selectedRegionIds = state.regions.map((item) => String(item.id))
  lockSelectionSync()
  postCommand('select_all_regions')
  render()
}

function handleOpenCreatePlaylist() {
  if (state.activeTab !== 'regions') return
  state.showCreatePlaylistModal = true
  state.newPlaylistName = ''
  render()
}

function handleCloseCreatePlaylist() {
  state.showCreatePlaylistModal = false
  state.newPlaylistName = ''
  render()
}

function handleConfirmCreatePlaylist() {
  const ids = getSelectedRegionIdsForActions()
  const name = String(state.newPlaylistName || '').trim()
  if (!name) return
  postCommand('create_playlist', { name, regionIds: ids })
  state.showCreatePlaylistModal = false
  state.newPlaylistName = ''
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedMarkerId = null
  lockSelectionSync()
  disableMultiSelect()
  render()
}

function handleOpenAddExisting() {
  if (state.activeTab !== 'regions') return
  const ids = getSelectedRegionIdsForActions()
  if (!ids.length || !state.playlists.length) return
  state.showAddExistingModal = true
  if (!state.selectedExistingPlaylistId) state.selectedExistingPlaylistId = String(state.playlists[0].id)
  render()
}

function handleCloseAddExisting() {
  state.showAddExistingModal = false
  render()
}

function handleConfirmAddExisting() {
  const ids = getSelectedRegionIdsForActions()
  if (!ids.length || !state.selectedExistingPlaylistId) return
  postCommand('add_existing_playlist', { playlistId: String(state.selectedExistingPlaylistId), regionIds: ids })
  state.showAddExistingModal = false
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedMarkerId = null
  lockSelectionSync()
  disableMultiSelect()
  render()
}

function isDirectorQueuedIdAllowed(id) {
  const key = String(id ?? '')
  if (!key) return false
  const song = findSongByIdEverywhere ? findSongByIdEverywhere(key) : null
  return !(song && isHashChildItem(song))
}

function getExplicitQueuedSongId() {
  if (state.localQueuedSongId != null && String(state.localQueuedSongId) !== '') {
    const age = Date.now() - Number(state.localQueuedSongAt || 0)
    if (age >= 0 && age <= 12000 && isDirectorQueuedIdAllowed(state.localQueuedSongId)) return String(state.localQueuedSongId)
    clearLocalQueuedSong()
  }
  if (Date.now() >= Number(remoteQueuedIgnoreUntil || 0) && state.queuedSongId != null && String(state.queuedSongId) !== '') {
    if (isDirectorQueuedIdAllowed(state.queuedSongId)) return String(state.queuedSongId)
  }
  return null
}

function findAutoBlocoBoundaryStopTargetFromList(list, playingKey) {
  if (!Array.isArray(list) || !playingKey) return null
  const idx = list.findIndex((item) => String(item?.id ?? item?.songId ?? '') === String(playingKey))
  if (idx < 0) return null

  let crossedBlock = false
  for (let i = idx + 1; i < list.length; i += 1) {
    const item = list[i]
    if (!item) continue
    if (isHashChildItem(item)) continue
    if (detectBlockItem(item)) {
      crossedBlock = true
      continue
    }
    const id = String(item.id ?? item.songId ?? '')
    if (!id || id === String(playingKey)) continue
    return crossedBlock ? id : null
  }
  return null
}

function getAutoBlocoStoppedSelectionTargetId(stoppedId = state.playingId, preferredTab = null) {
  if (!state.autoBlocoEnabled || !getAutoplayVisualEnabled()) return null
  const playingKey = String(stoppedId || state.playingId || '')
  if (!playingKey) return null

  const lists = []
  const playlist = activePlaylist()
  if ((preferredTab || state.activeTab) === 'playlist' && Array.isArray(playlist?.songs)) lists.push(playlist.songs)
  if ((preferredTab || state.activeTab) === 'regions' && Array.isArray(state.regions)) lists.push(state.regions)
  if (Array.isArray(playlist?.songs) && !lists.includes(playlist.songs)) lists.push(playlist.songs)
  if (Array.isArray(state.regions) && !lists.includes(state.regions)) lists.push(state.regions)

  for (const list of lists) {
    const target = findAutoBlocoBoundaryStopTargetFromList(list, playingKey)
    if (target && isDirectorQueuedIdAllowed(target)) return String(target)
  }
  return null
}

function getNextAutoQueuedSongId(options = {}) {
  if (!getAutoplayVisualEnabled() || !state.playingId) return null
  const playingKey = String(state.playingId || '')

  // Se o AutoBloco bloqueou a passagem para o próximo bloco, essa música não
  // deve aparecer como fila amarela. Ela só vira seleção quando o usuário parar.
  if (!options.allowAutoBlocoBoundary && getAutoBlocoStoppedSelectionTargetId(playingKey, state.activeTab)) {
    return null
  }

  const candidates = []
  const playlist = activePlaylist()
  if (Array.isArray(playlist?.songs) && playlist.songs.length) candidates.push(playlist.songs)
  if (Array.isArray(state.regions) && state.regions.length) candidates.push(state.regions)

  for (const list of candidates) {
    const idx = list.findIndex((item) => String(item?.id ?? item?.songId ?? '') === playingKey)
    if (idx < 0) continue
    for (let i = idx + 1; i < list.length; i += 1) {
      const item = list[i]
      if (!item || detectBlockItem(item) || isHashChildItem(item)) continue
      const id = String(item.id ?? item.songId ?? '')
      if (id && id !== playingKey && isDirectorQueuedIdAllowed(id)) return id
    }
  }
  return null
}

function getVisualQueuedSongId() {
  const explicitQueuedId = getExplicitQueuedSongId()
  if (explicitQueuedId) return explicitQueuedId
  const autoQueuedId = getNextAutoQueuedSongId({ allowAutoBlocoBoundary: false })
  if (autoQueuedId && isDirectorQueuedIdAllowed(autoQueuedId)) return String(autoQueuedId)
  return null
}

function getDirectorStopSelectionTarget(stoppedId, preferredTab = null) {
  const stoppedKey = stoppedId != null ? String(stoppedId) : ''
  const explicitQueuedKey = getExplicitQueuedSongId ? getExplicitQueuedSongId() : null

  if (explicitQueuedKey) {
    const queuedItem = findSongByIdEverywhere ? findSongByIdEverywhere(explicitQueuedKey) : null
    if (queuedItem && !detectBlockItem(queuedItem) && !isHashChildItem(queuedItem)) {
      const queuedTab = state.localQueuedSongTab || getPreferredStoppedSelectionTab(explicitQueuedKey, state.activeTab || preferredTab || null)
      return { id: String(explicitQueuedKey), tab: queuedTab || preferredTab || state.activeTab || 'playlist', fromQueue: true, source: 'manual_queue' }
    }
  }

  const autoBlocoTarget = getAutoBlocoStoppedSelectionTargetId ? getAutoBlocoStoppedSelectionTargetId(stoppedKey, preferredTab) : null
  if (autoBlocoTarget) {
    return { id: String(autoBlocoTarget), tab: getPreferredStoppedSelectionTab(autoBlocoTarget, preferredTab || state.activeTab || 'playlist'), fromQueue: false, source: 'auto_bloco' }
  }

  const autoQueuedKey = getNextAutoQueuedSongId ? getNextAutoQueuedSongId({ allowAutoBlocoBoundary: false }) : null
  if (autoQueuedKey) {
    return { id: String(autoQueuedKey), tab: getPreferredStoppedSelectionTab(autoQueuedKey, preferredTab || state.activeTab || 'playlist'), fromQueue: true, source: 'auto_queue' }
  }

  return null
}

function clearSelection() {
  clearSelectionState()
  state.multiSelectMode = false
  state.multiSelectTab = null
  state.showCreatePlaylistModal = false
  state.showAddExistingModal = false
  state.settingsMenuOpen = false
  state.editMode = false
  state.deleteMode = false
  resetDragState()
  postCommand('clear_selection')
  render()
}

function isPlaybackPending() {
  return !!(pendingPlaybackToggleAt && pendingPlaybackDesiredPlaying !== null && (Date.now() - pendingPlaybackToggleAt) < getPendingPlaybackGraceMs())
}

function getPlaybackUiActive() {
  if (isPlaybackPending()) return !!pendingPlaybackDesiredPlaying
  if (optimisticPlaybackState.id && isOptimisticPlaybackActiveFor(optimisticPlaybackState.id)) return true
  return !!state.playingId
}


function applyDirectorLocalStopIfMusicEnded() {
  const playingId = state.playingId != null ? String(state.playingId) : ''
  if (!playingId) return false

  // Depois de um Play pelo Diretor, não use remainingSec antigo do Bridge para
  // encerrar visualmente. Isso era o que fazia o botão ir para Stop e voltar
  // para Play enquanto a música seguia tocando no REAPER.
  if (isPlaybackPending() && pendingPlaybackDesiredPlaying === true) return false

  if (optimisticPlaybackState.id && String(optimisticPlaybackState.id) === playingId && isOptimisticPlaybackActiveFor(playingId)) {
    const duration = Math.max(0, Number(optimisticPlaybackState.durationSec) || Number(getOptimisticDurationSec(playingId)) || 0)
    if (!duration) return false
    const elapsed = Math.max(0, (Date.now() - Number(optimisticPlaybackState.startedAtMs || Date.now())) / 1000)
    if (elapsed < duration + 0.35) return false
  }

  const item = findAnyPlaybackItemById(playingId)
  const duration = Math.max(0, Number(item?.durationSec) || Number(playbackLiveState.duration) || 0)
  const hasReliableLiveRemaining = Number.isFinite(Number(playbackLiveState.baseRemaining))
    && Number(playbackLiveState.baseRemaining) > 0
    && Number(playbackLiveState.anchorAtMs) > 0

  if (!hasReliableLiveRemaining) return false

  const elapsed = Math.max(0, (Date.now() - Number(playbackLiveState.anchorAtMs)) / 1000)
  const remaining = Math.max(0, Number(playbackLiveState.baseRemaining) - elapsed)

  if (duration > 0 && remaining > 0.18) return false
  if (!duration && remaining > 0.05) return false

  const preferredTab = lastPlaybackSelectionTab || state.activeTab || 'playlist'
  const stopSelectionTarget = getDirectorStopSelectionTarget(playingId, preferredTab)
  if (stopSelectionTarget && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(playingId || '')) {
    applyStoppedSongSelection(stopSelectionTarget.id, stopSelectionTarget.tab)
  } else {
    // Sem fila/AutoBloco no fim da música, mantém a seleção azul na própria música que parou.
    applyStoppedSongSelection(playingId, preferredTab)
  }
  state.pendingStopClear = false
  state.loopActive = false
  state.bridgePopupVisible = false
  state.bridgePopupText = ''
  state.bridgePopupError = false
  state.bridgePopupPersistent = false
  state.appPopupVisible = false
  state.playingId = null
  lastDirectorLocalPlayStartAt = 0
  clearOptimisticPlayback()
  resetPlaybackLiveState(true)
  pendingPlaybackToggleAt = Date.now()
  pendingPlaybackDesiredPlaying = false
  pendingPlaybackDesiredSourceId = null
  pendingPlaybackDesiredSourceTab = null
  lockSelectionSync()
  try { render() } catch (error) {}
  if (stopSelectionTarget && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(playingId || '')) {
    try { forceStoppedSelectionDom(stopSelectionTarget.id, stopSelectionTarget.tab) } catch (error) {}
  } else {
    try { forceStoppedSelectionDom(playingId, preferredTab) } catch (error) {}
  }
  return true
}


function clearPendingPlaybackToggle() {
  pendingPlaybackToggleAt = 0
  pendingPlaybackDesiredPlaying = null
  pendingPlaybackDesiredSourceId = null
  pendingPlaybackDesiredSourceTab = null
}

function getPlayButtonClass() {
  return getPlaybackUiActive() ? 'btnStopActive' : 'btnPlayActive'
}

function getPlayButtonLabel() {
  return getPlaybackUiActive() ? 'Stop' : 'Play'
}

function findPlaylistSongByIdEverywhere(songId) {
  const key = String(songId ?? '')
  if (!key) return null

  const active = activePlaylist()
  const activeSong = Array.isArray(active?.songs)
    ? active.songs.find((item) => String(item?.id ?? item?.songId ?? '') === key)
    : null
  if (activeSong) return activeSong

  for (const playlist of Array.isArray(state.playlists) ? state.playlists : []) {
    const song = Array.isArray(playlist?.songs)
      ? playlist.songs.find((item) => String(item?.id ?? item?.songId ?? '') === key)
      : null
    if (song) return song
  }

  return null
}

function getPreferredStoppedSelectionTab(songId, fallbackTab = null) {
  const key = String(songId ?? '')
  if (!key) return fallbackTab || state.activeTab || 'playlist'

  if ((fallbackTab || '') === 'playlist' && findPlaylistSongByIdEverywhere(key)) return 'playlist'
  if ((fallbackTab || '') === 'regions' && findPlayingRegionById(key)) return 'regions'
  if (state.activeTab === 'playlist' && findPlaylistSongByIdEverywhere(key)) return 'playlist'
  if (state.activeTab === 'regions' && findPlayingRegionById(key)) return 'regions'
  if (findPlaylistSongByIdEverywhere(key)) return 'playlist'
  if (findPlayingRegionById(key)) return 'regions'
  return fallbackTab || state.activeTab || 'playlist'
}

function applyStoppedSongSelection(songId, preferredTab = null, options = {}) {
  const key = String(songId ?? '')
  if (!key) return false

  const tab = getPreferredStoppedSelectionTab(key, preferredTab)
  state.selectedMarkerId = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongIds = []

  if (tab === 'regions' && findPlayingRegionById(key)) {
    state.selectedRegionId = key
    state.selectedPlaylistSongId = null
  } else if (findPlaylistSongByIdEverywhere(key)) {
    state.selectedPlaylistSongId = key
    state.selectedRegionId = null
    if (state.activeTab === 'playlist') state.playlistView = 'songs'
  } else if (findPlayingRegionById(key)) {
    state.selectedRegionId = key
    state.selectedPlaylistSongId = null
  } else {
    return false
  }

  state.multiSelectMode = false
  state.multiSelectTab = null

  // Depois do Stop, o próximo Play precisa usar a música selecionada pelo Lua/Auto/Fila,
  // não a música que estava tocando antes. Mantém também a memória interna do player.
  lastPlaybackSelectionId = key
  lastPlaybackSelectionTab = tab
  pendingPlaybackDesiredSourceId = null
  pendingPlaybackDesiredSourceTab = tab

  clearDirectorLocalSelectionHold()

  if (options.hold !== false) {
    state.stoppedSelectionHoldId = key
    state.stoppedSelectionHoldTab = tab
    state.stoppedSelectionHoldUntil = Date.now() + 8000
    state.selectionLockUntil = Math.max(Number(state.selectionLockUntil || 0), Date.now() + 8000)
  }

  return true
}

function getActiveStoppedSelectionHoldTarget() {
  const key = String(state.stoppedSelectionHoldId || '')
  if (!key) return null
  if (Date.now() >= Number(state.stoppedSelectionHoldUntil || 0)) {
    clearStoppedSelectionHold()
    return null
  }
  const tab = getPreferredStoppedSelectionTab(key, state.stoppedSelectionHoldTab || state.activeTab || 'playlist')
  return { id: key, tab }
}

function forceStoppedSelectionDom(songId, preferredTab = null) {
  const key = String(songId ?? '')
  if (!key) return
  const tab = getPreferredStoppedSelectionTab(key, preferredTab)
  const attrName = tab === 'regions' ? 'data-region-id' : 'data-song-id'
  const rows = Array.from(document.querySelectorAll('[data-region-id], [data-song-id]'))
  let target = null
  rows.forEach((row) => {
    row.classList.remove('playing')
    row.classList.remove('selectedPink')
    row.classList.remove('selectedBlue')
    const rowKey = row.getAttribute(attrName)
    if (rowKey != null && String(rowKey) === key) target = row
  })
  if (target) {
    target.classList.remove('queuedYellow')
    target.classList.add(target.classList.contains('blockItem') ? 'selectedPink' : 'selectedBlue')
    target.querySelectorAll('.playingText,.playingTimeText,.queuedYellowText,.queuedYellowTimeText').forEach((el) => {
      el.classList.remove('playingText', 'playingTimeText', 'queuedYellowText', 'queuedYellowTimeText')
      if (el.classList.contains('rowLabelText')) el.classList.add(target.classList.contains('blockItem') ? 'selectedPinkText' : 'selectedBlueText')
      if (el.closest('.rightCol')) el.classList.add(target.classList.contains('blockItem') ? 'selectedPinkTimeText' : 'selectedBlueTimeText')
    })
  }
  const playBtn = document.querySelector('[data-action="play"]')
  if (playBtn) {
    playBtn.textContent = 'Play'
    playBtn.classList.remove('btnStopActive')
    playBtn.classList.add('btnPlayActive')
  }
}

function clearStoppedSelectionHold() {
  state.stoppedSelectionHoldId = null
  state.stoppedSelectionHoldTab = null
  state.stoppedSelectionHoldUntil = 0
}

function rememberCurrentPlaybackSelection(songId, preferredTab = null) {
  const key = String(songId ?? '')
  if (!key) return
  lastPlaybackSelectionId = key
  lastPlaybackSelectionTab = getPreferredStoppedSelectionTab(key, preferredTab)
  if (state.stoppedSelectionHoldId && String(state.stoppedSelectionHoldId) !== key) clearStoppedSelectionHold()
}

function handlePlayToggle(event = null) {
  if (isDirectorTransportProtectionEnabled()) {
    const nowProtectedTap = Date.now()
    const lastProtectedTap = Number(state.lastProtectedPlayTapAt || 0)
    if (!lastProtectedTap || (nowProtectedTap - lastProtectedTap) > 420) {
      state.lastProtectedPlayTapAt = nowProtectedTap
      showAppPopup('TOQUE DE NOVO PARA PLAY/STOP', 'info', 700)
      return
    }
    state.lastProtectedPlayTapAt = 0
  }

  const playCommandNow = Date.now()

  // Guarda apenas contra duplo clique real muito rápido.
  // O Play/Stop não recebe mais pointerup/touchend; somente o onclick do botão chama esta função.
  if (lastPlayButtonCommandAt && (playCommandNow - lastPlayButtonCommandAt) < 180) return
  lastPlayButtonCommandAt = playCommandNow
  // Play usa somente o modo da aba atual. Seleção velha de outra aba não entra.
  normalizeSingleSelectionForActiveTab()
  const selectedRegionId = state.activeTab === 'regions' ? state.selectedRegionId : null
  const selectedPlaylistSongId = state.activeTab === 'playlist' ? state.selectedPlaylistSongId : null


  const uiWasPlaying = getPlaybackUiActive()

  const stoppedHoldTarget = uiWasPlaying ? null : getActiveStoppedSelectionHoldTarget()
  let targetId = uiWasPlaying
    ? null
    : (stoppedHoldTarget?.id || (selectedRegionId != null ? String(selectedRegionId) : (selectedPlaylistSongId != null ? String(selectedPlaylistSongId) : null)))
  const targetTab = uiWasPlaying
    ? null
    : (stoppedHoldTarget?.tab || (selectedRegionId != null ? 'regions' : (selectedPlaylistSongId != null ? 'playlist' : state.activeTab)))

  if (!uiWasPlaying && stoppedHoldTarget?.id) {
    applyStoppedSongSelection(stoppedHoldTarget.id, stoppedHoldTarget.tab, { hold: false })
  }

  if (!uiWasPlaying && targetId) {
    const originalTargetId = String(targetId)
    const resolvedTargetId = resolvePlaybackTargetIdForBlock(targetId, targetTab)
    if (resolvedTargetId && String(resolvedTargetId) !== originalTargetId) {
      targetId = String(resolvedTargetId)
      // Se o usuário apertou Play em um BLOCO, a seleção visual precisa sair do bloco
      // imediatamente e ir para a música que realmente vai tocar, igual no Lua.
      if (targetTab === 'playlist') {
        state.selectedPlaylistSongId = targetId
        state.selectedPlaylistSongIds = []
        state.selectedRegionId = null
        state.selectedRegionIds = []
      } else if (targetTab === 'regions') {
        state.selectedRegionId = targetId
        state.selectedRegionIds = []
        state.selectedPlaylistSongId = null
        state.selectedPlaylistSongIds = []
      }
      lockSelectionSync()
    } else {
      const targetItem = findAnyPlaybackItemById(targetId)
      if (targetItem && detectBlockItem(targetItem)) {
        showAppPopup('BLOCO SEM MÚSICA ABAIXO', 'error', 1400)
        render()
        return
      }
    }
  }

  pendingPlaybackToggleAt = Date.now()
  pendingPlaybackDesiredPlaying = !uiWasPlaying
  pendingPlaybackDesiredSourceId = targetId
  pendingPlaybackDesiredSourceTab = targetTab

  if (uiWasPlaying) {
    const stoppedId = state.playingId || lastPlaybackSelectionId || pendingPlaybackDesiredSourceId
    const stoppedPreferredTab = lastPlaybackSelectionTab || pendingPlaybackDesiredSourceTab || state.activeTab
    const stopSelectionTarget = getDirectorStopSelectionTarget(stoppedId, stoppedPreferredTab)
    const hasRealStopSelectionTarget = !!(stopSelectionTarget && stopSelectionTarget.id && stopSelectionTarget.source && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(stoppedId || ''))
    postPlaybackToggleCommand(stoppedId, stoppedPreferredTab, false, hasRealStopSelectionTarget ? { stopSelectionTargetId: stopSelectionTarget.id, stopSelectionTargetTab: stopSelectionTarget.tab, stopSelectionTargetSource: stopSelectionTarget.source } : null)
    if (hasRealStopSelectionTarget) {
      applyStoppedSongSelection(stopSelectionTarget.id, stopSelectionTarget.tab)
    } else if (stoppedId) {
      // Stop sem fila: mantém o azul imediatamente na música que acabou de parar.
      // O Bridge pode demorar ou mandar selectedId antigo; o hold local vence esse atraso.
      applyStoppedSongSelection(stoppedId, stoppedPreferredTab)
    } else {
      clearStoppedSelectionHold()
      clearDirectorLocalSelectionHold()
      state.selectedRegionId = null
      state.selectedRegionIds = []
      state.selectedPlaylistSongId = null
      state.selectedPlaylistSongIds = []
      state.selectionLockUntil = 0
    }
    state.pendingStopClear = false
    state.loopActive = false
    state.bridgePopupVisible = false
    state.bridgePopupText = ''
    state.bridgePopupError = false
    state.bridgePopupPersistent = false
    state.appPopupVisible = false
    state.playingId = null
    clearVisualQueueForDirector()
    clearOptimisticPlayback()
    resetPlaybackLiveState(true)
    lockSelectionSync()
    render()
    if (stopSelectionTarget && stopSelectionTarget.source !== 'stopped' && String(stopSelectionTarget.id || '') !== String(stoppedId || '')) {
      forceStoppedSelectionDom(stopSelectionTarget.id, stopSelectionTarget.tab)
    } else if (stoppedId) {
      forceStoppedSelectionDom(stoppedId, stoppedPreferredTab)
    }
  } else {
    if (targetId) {
      showLocalPlaybackPopupForId(targetId)
      postPlaybackToggleCommand(targetId, targetTab, true)
      startOptimisticPlayback(targetId, targetTab)
    } else {
      postPlaybackToggleCommand(null, state.activeTab, true)
    }
    render()
  }
}

function handleAutoplayToggle() {
  const nextEnabled = !getAutoplayVisualEnabled()
  setAutoplayVisualEnabled(nextEnabled)
  postCommand('autoplay_set', { desiredAutoplay: nextEnabled, desiredState: nextEnabled ? 'on' : 'off' })
  render()
}

function handleAutoBlocoToggle() {
  const nextEnabled = !state.autoBlocoEnabled
  state.autoBlocoEnabled = nextEnabled
  render()
  postCommand('auto_bloco_set', { desiredAutoBloco: nextEnabled, desiredState: nextEnabled ? 'on' : 'off' })
  fastPollBridge?.(4)
}

function handleNoticeToggle() {
  // Mantido apenas por compatibilidade caso exista algum HTML antigo em cache.
  state.noticeEnabled = true
  pendingNoticeToggleAt = 0
  pendingNoticeToggleValue = null
  render()
}

function handleLoopToggle() {
  const wasActive = !!state.loopActive
  pendingLoopToggleAt = Date.now()
  pendingLoopToggleFromState = wasActive
  postCommand('loop_toggle')
}


function isEditableSwipeTarget(target) {
  const el = target && target.closest ? target.closest('textarea,input,[contenteditable="true"]') : null
  return !!el
}

function shouldIgnoreDirectorSwipe(event) {
  // A tela de Letras precisa aceitar swipe também fora do modo de edição:
  // direita abre Letras na tela principal; esquerda volta para a tela principal.
  // No editor, esquerda cancela e volta; direita confirma a letra e sai do editor.
  if (state.lyricsPanelOpen) return false
  return isEditableSwipeTarget(event?.target)
}

function handleTouchStart(e) {
  if (shouldIgnoreDirectorSwipe(e)) {
    touchStartX = null
    touchStartY = null
    touchStartAt = 0
    return
  }
  touchStartX = e.changedTouches?.[0]?.clientX ?? null
  touchStartY = e.changedTouches?.[0]?.clientY ?? null
  touchStartAt = Date.now()
}

function handleTouchEnd(e) {
  const endX = e.changedTouches?.[0]?.clientX ?? null
  const endY = e.changedTouches?.[0]?.clientY ?? null
  if (touchStartX == null || touchStartY == null || endX == null || endY == null) return
  const deltaX = endX - touchStartX
  const deltaY = endY - touchStartY
  const absX = Math.abs(deltaX)
  const absY = Math.abs(deltaY)
  const elapsed = Date.now() - touchStartAt
  if (absX < 108 || absY > 78 || absX <= (absY * 1.7) || elapsed > 760) {
    touchStartX = null
    touchStartY = null
    return
  }

  if (state.lyricsPanelOpen) {
    if (deltaX <= -108) {
      e?.preventDefault?.()
      e?.stopPropagation?.()
      if (state.lyricsEditing) {
        cancelLyricsEditAndClosePanel()
      } else {
        closeLyricsPanel()
      }
    } else if (deltaX >= 108 && state.lyricsEditing) {
      e?.preventDefault?.()
      e?.stopPropagation?.()
      confirmLyricsEdit()
    }
    touchStartX = null
    touchStartY = null
    return
  } else if (deltaX <= -108 && state.activeTab === 'playlist' && state.playlistView !== 'markers') {
    // FIX76: swipe para Markers bloqueado temporariamente para lançamento.
    // Mantém o usuário em Repertórios e não envia parts_visibility=1.
    e?.preventDefault?.()
    e?.stopPropagation?.()
    state.localMarkersMode = false
    state.playlistView = 'songs'
    state.markersPanelAnimateUntil = 0
    postCommand('set_page', { page: 'playlist' })
    postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
    render()
  } else if (deltaX <= -108 && state.activeTab === 'regions') {
    // Músicas -> primeiro força Repertórios; não abre Markers direto.
    state.activeTab = 'playlist'
    state.playlistView = 'songs'
    state.localMarkersMode = false
    state.pendingTabCommand = 'playlist'
    showAppPopup('PRIMEIRO VÁ PARA REPERTÓRIOS', 'marker', 2200)
    state.forcePlaylistUntil = Date.now() + 1800
    postCommand('set_page', { page: 'playlist' })
    postCommand('set_parts_visibility', { page: 'playlist', visible: '0' })
    render()
  } else if (deltaX >= 108 && state.activeTab === 'playlist' && state.playlistView === 'markers') {
    // Markers -> swipe para direita volta para a tela principal, não vai direto para Letras.
    closeMarkersPanel()
  } else if (deltaX >= 108) {
    // Tela principal -> swipe para direita abre Letras.
    openLyricsPanel()
  }
  touchStartX = null
  touchStartY = null
}

function getCurrentPlayingElapsedSec() {
  if (!state.playingId) return null

  // Fonte principal: sync real do Bridge/Lua. O app interpola localmente
  // para limpar o marker verde/piscando assim que a reprodução chega na Part.
  const syncedElapsed = Number(state.playbackElapsedSec)
  if (Number.isFinite(syncedElapsed)) {
    const syncedAt = Number(state.playbackSyncedAtMs || 0)
    const ageMs = syncedAt > 0 ? Math.max(0, Date.now() - syncedAt) : 0
    const localAdd = ageMs > 0 && ageMs < 8000 ? ageMs / 1000 : 0
    return Math.max(0, syncedElapsed + localAdd)
  }

  const item = findSongByIdEverywhere ? findSongByIdEverywhere(state.playingId) : null
  if (!item) return null
  const duration = Number(item.durationSec) || 0
  const remaining = Number(item.remainingSec) || 0
  if (duration > 0 && remaining >= 0) return Math.max(0, duration - remaining)
  return null
}

function isMarkerBlinking(item) {
  if (!item) return false
  const itemId = String(item.id ?? '')
  if (!itemId) return false
  const armedId = String(getDirectorMarkerArmedVisualId?.() || '')
  if (!armedId || armedId !== itemId) return false
  return true
}



function syncDirectorMarkerArmedVisualWithPlayback(markersList = null) {
  const armedId = String(getDirectorMarkerArmedVisualId?.() || '')
  if (!armedId) return false
  const markers = Array.isArray(markersList) ? markersList : currentMarkers()
  const marker = markers.find((item) => String(item?.id ?? '') === armedId)
  const target = Number(marker?.timeSec ?? marker?.pos ?? marker?.position ?? state.markerGoFlashTargetSec)
  if (!Number.isFinite(target)) return false
  const playPos = Number(state.playPosition ?? state.currentPlayPosition ?? state.transportPosition ?? state.playbackPosition ?? 0)
  const started = Number(state.markerGoFlashStartedAtMs || 0)
  if (started && Date.now() - started < 180) return false
  if (Number.isFinite(playPos) && playPos >= target - 0.02) {
    state.markerGoFlashId = null
    state.markerGoFlashStartedAtMs = 0
    state.markerGoFlashForceUntil = 0
    state.markerGoFlashTargetSec = null
    clearDirectorMarkerArmedLocalHold?.()
    return true
  }
  return false
}


function formatRowLabel(item, type) {
  const rawLabel = upperText(item.label || item.name || '---')
  if (type !== 'song') return rawLabel
  if (!detectBlockItem(item)) return rawLabel
  return upperText(formatAppBlockLabel(item))
}

function getRowNumberText(items, type, index) {
  if (type === 'song') {
    const item = items[index]
    if (detectBlockItem(item)) return '--'
    let count = 0
    for (let i = 0; i <= index; i += 1) {
      if (!detectBlockItem(items[i])) count += 1
    }
    return String(count).padStart(2, '0')
  }
  if (type === 'region') {
    let count = 0
    for (let i = 0; i <= index; i += 1) {
      if (!detectBlockItem(items[i])) count += 1
    }
    return String(count).padStart(2, '0')
  }
  return ''
}

function renderRows(items, type) {
  if (!items.length) return type === 'marker' ? `<div class="emptyBox"></div>` : `<div class="emptyBox">Sem itens</div>`
  const visualQueuedSongId = getVisualQueuedSongId()
  return items.map((item, index) => {
    const itemId = String(item.id)
    const isPlaying = type !== 'marker' && String(state.playingId || '') === itemId
    const isHashChildForVisualGuard = isHashChildItem(item)
    const isQueued = (type === 'song' || type === 'region') && !isHashChildForVisualGuard && String(visualQueuedSongId || '') === itemId
    const isBlock = detectBlockItem(item)
    const isLiveExecuted = !isPlaying && !isQueued && !isBlock && !!(item?.isLiveExecuted || item?.liveExecuted || item?.alreadyPlayed || item?.played || item?.executed)
    const blockOutlineStyle = isBlock ? ` style="--block-outline-color:${escapeHtml(getBlockOutlineColorCss(item))};--block-outline-glow:${escapeHtml(getBlockOutlineGlowCss(item))};"` : ''
    const suppressBlockedChildVisual = (type === 'song' || type === 'region')
      && isHashChildForVisualGuard
      && !!state.playingId
      && String(state.playingId || '') !== itemId
      && String(visualQueuedSongId || '') !== itemId
    const rawSelected = type === 'region'
      ? (isMultiSelectActiveFor('regions') ? state.selectedRegionIds.includes(itemId) : String(state.selectedRegionId || '') === itemId)
      : type === 'song'
      ? (isMultiSelectActiveFor('playlist') ? state.selectedPlaylistSongIds.includes(itemId) : String(state.selectedPlaylistSongId || '') === itemId)
      : (String(state.selectedMarkerId || '') === itemId || isDirectorMarkerLocallyHeld?.(itemId) || String(getDirectorMarkerArmedVisualId?.() || '') === itemId)
    // O item tocando não deve herdar azul de seleção antigo.
    // A música em reprodução já tem estado visual próprio; seleção azul é somente alvo manual/local.
    const suppressPlayingSelectedVisual = (type === 'song' || type === 'region') && isPlaying
    const isSelected = (suppressBlockedChildVisual || suppressPlayingSelectedVisual) ? false : rawSelected

    const classes = ['item']
    if (isQueued) {
      classes.push('queuedYellow')
    } else if (type === 'marker' && isSelected) {
      classes.push('markerSelectedActive')
      if (String(getDirectorMarkerArmedVisualId() || '') === itemId) classes.push('markerGoConfirmed')
      if (isMarkerBlinking(item)) classes.push('markerBlink')
    } else if (isSelected) {
      classes.push(isBlock ? 'selectedPink' : 'selectedBlue')
    }
    if (isPlaying) classes.push('playing')
    if (isLiveExecuted) classes.push('liveExecuted')

    const attr = type === 'region' ? `data-region-id="${itemId}"` : type === 'song' ? `data-song-id="${itemId}"` : `data-marker-id="${itemId}"`
    const familyGroupId = item?.familyGroupId != null ? String(item.familyGroupId) : ''
    const familyAttr = familyGroupId ? ` data-family-group-id="${escapeHtml(familyGroupId)}" data-family-role="${escapeHtml(item?.familyRole || '')}" data-parent-id="${escapeHtml(String(item?.parentId || item?.parentSourceNumber || ''))}"` : ''
    const rowSourceNumber = item?.source_number ?? item?.sourceNumber ?? item?.number ?? ''
    const rowStartPos = item?.startPos ?? item?.start_pos ?? ''
    const rowEndPos = item?.endPos ?? item?.end_pos ?? ''
    const rowMetaAttr = ` data-source-number="${escapeHtml(String(rowSourceNumber ?? ''))}" data-source-start="${escapeHtml(String(rowStartPos ?? ''))}" data-source-end="${escapeHtml(String(rowEndPos ?? ''))}"`
    const label = formatRowLabel(item, type)
    const isHashChild = isHashChildItem(item)
    const isHashParent = isHashParentItem(item)
    const inheritedItemTextColor = getAppItemTextColor(item, isBlock)
    const itemTextColor = (type === 'region' || type === 'regions')
      ? '#ffffff'
      : (inheritedItemTextColor && String(inheritedItemTextColor).trim() !== '' ? inheritedItemTextColor : '#ffffff')
    const playbackItem = getPlaybackAwareItem(item, type, isPlaying, isBlock)
    const time = type === 'marker'
      ? ''
      : isBlock
      ? ''
      : formatTime(isPlaying ? (playbackItem.remainingSec ?? playbackItem.durationSec) : playbackItem.durationSec)

    const hasNumberCol = type === 'song' || type === 'region'
    const rowNumberText = hasNumberCol ? getRowNumberText(items, type, index) : ''

    const textClass = isPlaying
      ? 'playingText'
      : isQueued
      ? 'queuedYellowText'
      : type === 'marker' && isSelected
      ? 'markerSelectedText'
      : isSelected
      ? (isBlock ? 'selectedPinkText' : 'selectedBlueText')
      : isLiveExecuted
      ? 'liveExecutedText'
      : isBlock
      ? 'blockText'
      : 'text'

    const timeClass = isPlaying
      ? 'playingTimeText'
      : isQueued
      ? 'queuedYellowTimeText'
      : type === 'marker' && isSelected
      ? 'markerSelectedTimeText'
      : isSelected
      ? (isBlock ? 'selectedPinkTimeText' : 'selectedBlueTimeText')
      : isLiveExecuted
      ? 'liveExecutedTimeText'
      : isBlock
      ? 'blockTimeText'
      : 'timeText'

    if (isBlock) classes.push('blockItem')
    if (isHashChild) {
      classes.push('hashChildItem')
      const hashAnimClass = vshookHashChildAnimationClasses(item, type === 'song' ? 'song' : 'region')
      if (hashAnimClass) classes.push(hashAnimClass)
    }
    if (isHashParent) classes.push('hashParentItem')
    if (hasNumberCol) classes.push('numberedItem')
    const showEditHandle = state.editMode && !state.deleteMode && (type === 'song' || type === 'region')
    if (showEditHandle) classes.push('editableItem')
    if (state.editMode && ((type === 'song' && state.dragType === 'playlist' && state.dragSelectedIds.includes(itemId)) || (type === 'region' && state.dragType === 'regions' && state.dragSelectedIds.includes(itemId)))) classes.push('draggingSelected')
    if (state.editMode && ((type === 'song' && state.dragType === 'playlist' && String(state.dragHoverId || '') === itemId) || (type === 'region' && state.dragType === 'regions' && String(state.dragHoverId || '') === itemId))) classes.push('dragTarget')

    const dragHandle = showEditHandle ? `<span class="editHandle" aria-hidden="true"><span class="editHandleBars"><i></i><i></i><i></i></span></span>` : ''
    const numberCol = hasNumberCol ? `<div class="numberCol ${rowNumberText === '--' ? 'numberColEmpty' : ''}"><span>${escapeHtml(rowNumberText)}</span></div>` : ''
    const labelStyle = itemTextColor && !isPlaying && !isQueued && !isSelected ? ` style="color:${escapeHtml(itemTextColor)}"` : ''
    const rowLabelClass = [textClass, 'rowLabelText', type === 'marker' ? 'markerRowLabel' : (type === 'song' ? 'songRowLabel' : 'regionRowLabel')].filter(Boolean).join(' ')
    const displayLabel = formatHashFamilyLabel(item, label)
    const labelHtml = `<span class="${rowLabelClass}"${labelStyle}>${isBlock ? escapeHtmlPreserveSpaces(displayLabel) : escapeHtml(displayLabel)}</span>`
    const progressRatio = getRowProgressRatio(playbackItem, isPlaying, isBlock)
    const progressWidthCss = hasNumberCol
      ? `left:42px;width:calc(${(progressRatio * 100).toFixed(3)}% - ${(42 * progressRatio).toFixed(3)}px);min-width:10px;`
      : `left:0;width:${Math.round(progressRatio * 1000) / 10}%;min-width:10px;`
    const progressBarHtml = progressRatio > 0
      ? `<div class="progressBar ${hasNumberCol ? 'progressBarWithNumber' : ''}" style="${progressWidthCss}"></div>`
      : ''

    const rightColHtml = time ? `<div class="rightCol"><span class="${timeClass}">${time}</span></div>` : `<div class="rightCol rightColEmpty"></div>`
    return `<div class="${classes.join(' ')}" ${attr}${familyAttr}${rowMetaAttr}${blockOutlineStyle}>${progressBarHtml}${numberCol}${dragHandle}<div class="leftCol">${labelHtml}</div>${rightColHtml}</div>`
  }).join('')
}



function installSettingsMenuFallback() {
  // Desativado: o fallback global em pointerdown/touchstart estava prendendo o menu
  // e travando a interface ao abrir PREMIX. O menu volta a usar apenas os binds
  // locais dos botoes, igual ao MIXER.
  return true
}

function installPremixOpenFallback() {
  // Mantido como no-op: o botão PREMIX agora abre direto pelo fluxo principal do menu.
  // Isso evita duplo pointer/touch/click fechando o menu sem abrir a janela.
  return true
}

function installPremixSafetyCloseFallback() {
  // Desativado: o fechamento global em capture concorria com os cliques internos
  // do PREMIX. O fechar fica nos botoes/overlay do fluxo principal.
  return true
}


function bindHashChildrenLongPress(el, type) {
  // Desativado por decisão de produto: App Diretor não usa mais apertar/segurar para filhos.
  return false
}

function bindEvents() {
  installSettingsMenuFallback()
  installPremixOpenFallback()
  installPremixSafetyCloseFallback()
  bindReliableTapAction(document.querySelector('[data-action="go-playlist"]'), 'go-playlist', openPlaylist)
  bindReliableTapAction(document.querySelector('[data-action="go-regions"]'), 'go-regions', openRegions)
  bindReliableTapAction(document.querySelector('[data-action="open-markers"]'), 'open-markers', openMarkersPanel)
  bindReliableTapAction(document.querySelector('[data-action="close-markers"]'), 'close-markers', closeMarkersPanel)
  document.querySelector('[data-action="open-playlist-switch"]')?.addEventListener('click', openPlaylistSwitchModal)
  document.querySelector('[data-action="open-timer"]')?.addEventListener('click', openTimerModal)
  document.querySelector('[data-action="close-timer"]')?.addEventListener('click', closeTimerModal)
  document.querySelector('[data-action="confirm-timer"]')?.addEventListener('click', confirmTimerModal)
  document.querySelector('[data-action="timer-mode-progressive"]')?.addEventListener('click', () => setTimerModeFromApp('progressive'))
  document.querySelector('[data-action="timer-mode-countdown"]')?.addEventListener('click', () => setTimerModeFromApp('countdown'))
  document.querySelector('[data-action="timer-mode-local"]')?.addEventListener('click', () => setTimerModeFromApp('local_time'))
  document.querySelectorAll('[data-timer-part]').forEach((input) => {
    input.addEventListener('input', syncTimerTargetPreviewFromInputs)
    input.addEventListener('change', syncTimerTargetPreviewFromInputs)
  })
  bindReliableTapAction(document.querySelector('[data-action="toggle-settings"]'), 'toggle-settings', handleToggleSettingsMenu)
  bindReliableTapAction(document.querySelector('[data-action="open-project-tabs"]'), 'open-project-tabs', openProjectTabsModal)
  bindImmediateTapAction(document.querySelector('[data-action="open-recados"]'), 'open-recados', openRecadosModal)
  bindImmediateTapAction(document.querySelector('[data-action="open-gear"]'), 'open-gear', (event) => { event.preventDefault(); event.stopPropagation(); openGearModal() })
  bindModalCloseAction(document.querySelector('[data-action="close-gear"]'), 'close-gear', closeGearModal)
  document.querySelector('[data-action="back-project-selector"]')?.addEventListener('click', backToVSHookProjectSelector)
  bindModalCloseAction(document.querySelector('[data-action="close-project-tabs"]'), 'close-project-tabs', closeProjectTabsModal)
  document.querySelector('[data-action="recados-send"]')?.addEventListener('click', sendDirectorRecado)
  document.querySelector('[data-action="recados-cancel"]')?.addEventListener('click', cancelDirectorRecado)
  bindModalCloseAction(document.querySelector('[data-action="recados-close"]'), 'recados-close', closeRecadosModal)
  document.getElementById('recadosDirectorTextarea')?.addEventListener('input', handleRecadosInputChange)
  bindImmediateTapAction(document.querySelector('[data-action="confirm-project-tabs"]'), 'confirm-project-tabs', confirmProjectTabsModal)
  document.querySelector('[data-close-project-tabs]')?.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeProjectTabsModal() })
  document.querySelector('[data-close-recados]')?.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeRecadosModal() })
  document.querySelectorAll('[data-project-tab-index]').forEach((el) => el.addEventListener('click', () => selectProjectTabInModal(el.getAttribute('data-project-tab-index'))))
  document.querySelector('[data-action="cycle-rgb-mode"]')?.addEventListener('click', cycleRgbMode)
  document.querySelector('[data-action="toggle-protection"]')?.addEventListener('click', toggleDirectorTransportProtection)
  document.querySelector('[data-action="theme-light"]')?.addEventListener('click', () => setTheme('light'))
  document.querySelector('[data-action="theme-dark"]')?.addEventListener('click', () => setTheme('dark'))
  document.querySelector('[data-action="toggle-select"]')?.addEventListener('click', handleSelectAction)
  document.querySelector('[data-action="copy-playlist-names"]')?.addEventListener('click', handleCopyPlaylistNames)
  bindPressAction(document.querySelector('[data-action="open-mixer"]'), 'open-mixer', () => openMixerModal('tracks'))
  bindPremixMenuButton(document.querySelector('[data-action="open-premix"]'))
  // Global Premix removido
  bindPressAction(document.querySelector('[data-action="open-bpm"]'), 'open-bpm', openBpmModal)
  bindPressAction(document.querySelector('[data-action="open-tuner"]'), 'open-tuner', openTunerModal)
  bindModalCloseAction(document.querySelector('[data-action="close-bpm"]'), 'close-bpm', closeBpmModal)
  bindModalCloseAction(document.querySelector('[data-action="close-tuner"]'), 'close-tuner', closeTunerModal)
  bindPressAction(document.querySelector('[data-action="bpm-plus"]'), 'bpm-plus', (event) => handleBpmAdjust(1, event))
  bindPressAction(document.querySelector('[data-action="bpm-minus"]'), 'bpm-minus', (event) => handleBpmAdjust(-1, event))
  bindPressAction(document.querySelector('[data-action="tuner-reset"]'), 'tuner-reset', handleTunerReset)
  bindModalCloseAction(document.querySelector('[data-action="close-mixer"]'), 'close-mixer', () => closeMixerModal(true))
  bindModalCloseAction(document.querySelector('[data-action="close-premix"]'), 'close-premix', () => closePremixModal(true))
  bindModalCloseAction(document.querySelector('[data-action="close-premix-volume"]'), 'close-premix-volume', () => closePremixVolumeModal(true))
  bindModalCloseAction(document.querySelector('[data-action="close-mixer-volume"]'), 'close-mixer-volume', () => closeMixerVolumeModal(true))
  bindPressAction(document.querySelector('[data-action="mixer-volume-reset"]'), 'mixer-volume-reset', (event) => handleMixerVolumeReset(event, state.mixerVolumeView, state.mixerSelectedId))
  bindPressAction(document.querySelector('[data-action="mixer-view-tracks"]'), 'mixer-view-tracks', () => setMixerView('tracks'))
  bindPressAction(document.querySelector('[data-action="mixer-view-groups"]'), 'mixer-view-groups', () => setMixerView('groups'))
  bindPressAction(document.querySelector('[data-action="mixer-view-master"]'), 'mixer-view-master', () => setMixerView('master'))
  document.querySelectorAll('[data-action="open-mixer-volume"]').forEach((el) => {
    const actionKey = `open-mixer-volume:${el.getAttribute('data-mixer-view') || 'tracks'}:${el.getAttribute('data-mixer-id') || ''}`
    bindPressAction(el, actionKey, (event) => handleMixerRowOpenFromElement(el, event))
  })
  document.querySelectorAll('[data-action="mixer-mute"]').forEach((el) => {
    const actionKey = `mixer-mute:${el.getAttribute('data-mixer-view') || 'tracks'}:${el.getAttribute('data-mixer-id') || ''}`
    bindImmediateTapAction(el, actionKey, (event) => handleMixerMuteToggle(event, el.getAttribute('data-mixer-view'), el.getAttribute('data-mixer-id')))
  })
  document.querySelectorAll('[data-action="mixer-solo"]').forEach((el) => {
    const actionKey = `mixer-solo:${el.getAttribute('data-mixer-view') || 'tracks'}:${el.getAttribute('data-mixer-id') || ''}`
    bindImmediateTapAction(el, actionKey, (event) => handleMixerSoloToggle(event, el.getAttribute('data-mixer-view'), el.getAttribute('data-mixer-id')))
  })
  document.querySelectorAll('[data-action="mixer-volume-slider"]').forEach((el) => {
    const mixerView = el.getAttribute('data-mixer-view')
    const mixerId = el.getAttribute('data-mixer-id')
    const run = () => handleMixerVolumeInput(mixerView, mixerId, el.value)
    const start = () => beginMixerVolumeInteraction()
    const end = () => endMixerVolumeInteraction()

    el.addEventListener('pointerdown', start, { passive: true })
    el.addEventListener('touchstart', start, { passive: true })
    el.addEventListener('pointerup', end, { passive: true })
    el.addEventListener('touchend', end, { passive: true })
    el.addEventListener('change', end)
    el.addEventListener('input', run)
    el.addEventListener('change', run)
  })

  bindPressAction(document.querySelector('[data-action="premix-onoff"]'), 'premix-onoff', handlePremixOnOffToggle)
  bindPressAction(document.querySelector('[data-action="premix-global-reset"]'), 'premix-global-reset', handlePremixGlobalReset)
  bindPressAction(document.querySelector('[data-action="premix-play"]'), 'premix-play', handlePremixPlaySelected)
  bindPressAction(document.querySelector('[data-action="premix-back"]'), 'premix-back', backPremixSongList)
  bindPressAction(document.querySelector('[data-action="premix-view-tracks"]'), 'premix-view-tracks', () => setPremixTrackView('tracks'))
  bindPressAction(document.querySelector('[data-action="premix-view-groups"]'), 'premix-view-groups', () => setPremixTrackView('groups'))
  document.querySelectorAll('[data-action="premix-song"]').forEach((el) => {
    const id = el.getAttribute('data-premix-song-id')
    bindReliableTapAction(el, `premix-song:${id || ''}`, () => selectPremixSong(id))
  })
  document.querySelectorAll('[data-action="open-premix-volume"]').forEach((el) => {
    const actionKey = `open-premix-volume:${el.getAttribute('data-premix-view') || 'tracks'}:${el.getAttribute('data-premix-track-id') || ''}`
    bindPressAction(el, actionKey, (event) => handlePremixRowOpenFromElement(el, event))
  })
  document.querySelectorAll('[data-action="premix-mute"]').forEach((el) => {
    const id = el.getAttribute('data-premix-track-id')
    const view = el.getAttribute('data-premix-view') || state.premixTrackView
    bindImmediateTapAction(el, `premix-mute:${view}:${id || ''}`, (event) => handlePremixTrackToggle(event, 'mute', id, view))
  })
  document.querySelectorAll('[data-action="premix-solo"]').forEach((el) => {
    const id = el.getAttribute('data-premix-track-id')
    const view = el.getAttribute('data-premix-view') || state.premixTrackView
    bindImmediateTapAction(el, `premix-solo:${view}:${id || ''}`, (event) => handlePremixTrackToggle(event, 'solo', id, view))
  })
  document.querySelectorAll('[data-action="premix-phase"]').forEach((el) => {
    const id = el.getAttribute('data-premix-track-id')
    const view = el.getAttribute('data-premix-view') || state.premixTrackView
    bindImmediateTapAction(el, `premix-phase:${view}:${id || ''}`, (event) => handlePremixTrackToggle(event, 'phase', id, view))
  })
  document.querySelectorAll('[data-action="premix-volume-slider"]').forEach((el) => {
    const id = el.getAttribute('data-premix-track-id')
    const view = el.getAttribute('data-premix-view') || state.premixTrackView
    const run = () => handlePremixVolumeInput(view, id, el.value)
    const start = () => beginMixerVolumeInteraction()
    const end = () => endMixerVolumeInteraction()

    el.addEventListener('pointerdown', start, { passive: true })
    el.addEventListener('touchstart', start, { passive: true })
    el.addEventListener('pointerup', end, { passive: true })
    el.addEventListener('touchend', end, { passive: true })
    el.addEventListener('change', end)
    el.addEventListener('input', run)
    el.addEventListener('change', run)
  })
  bindPressAction(document.querySelector('[data-action="premix-volume-reset"]'), 'premix-volume-reset', (event) => {
    const el = event?.currentTarget || document.querySelector('[data-action="premix-volume-reset"]')
    handlePremixVolumeReset(event, el?.getAttribute('data-premix-view') || state.premixTrackView, el?.getAttribute('data-premix-track-id') || state.premixSelectedTrackId)
  })
  document.querySelector('[data-action="delete-selected"]')?.addEventListener('click', handleDeleteSelectedPlaylistItems)
  document.querySelector('[data-action="edit-done"]')?.addEventListener('click', handleEditDone)
  document.querySelector('[data-action="delete-confirm"]')?.addEventListener('click', handleDeleteConfirm)
  document.querySelector('[data-action="delete-cancel"]')?.addEventListener('click', handleDeleteCancel)
  document.querySelectorAll('[data-action="marker-cancel"]').forEach((el) => bindReliableTapAction(el, 'marker-cancel', handleMarkerCancel))
  bindPlayTapAction(document.querySelector('[data-action="play"]'), handlePlayToggle)
  document.querySelector('[data-action="all"]')?.addEventListener('click', handleSelectAll)
  document.querySelector('[data-action="add-list"]')?.addEventListener('click', handleOpenCreatePlaylist)
  document.querySelector('[data-action="add-exist"]')?.addEventListener('click', handleOpenAddExisting)
  bindReliableTapAction(document.querySelector('[data-action="autoplay"]'), 'autoplay', handleAutoplayToggle)
  document.querySelector('[data-action="create-block"]')?.addEventListener('click', () => postCommand('create_block'))
  bindReliableTapAction(document.querySelector('[data-action="auto-bloco"]'), 'auto-bloco', handleAutoBlocoToggle)
  bindReliableTapAction(document.querySelector('[data-action="open-lyrics-panel"]'), 'open-lyrics-panel', openLyricsPanel)
  bindModalCloseAction(document.querySelector('[data-action="close-lyrics-panel"]'), 'close-lyrics-panel', closeLyricsPanel)
  document.querySelector('[data-action="lyrics-edit"]')?.addEventListener('click', startLyricsEdit)
  document.querySelector('[data-action="lyrics-confirm"]')?.addEventListener('click', confirmLyricsEdit)
  document.querySelector('[data-action="lyrics-cancel"]')?.addEventListener('click', cancelLyricsEdit)
  document.querySelector('[data-close-mixer]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    event.stopPropagation()
    window.setTimeout(() => {
      closeMixerModal()
    }, 0)
  })
  document.querySelector('[data-close-mixer-volume]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    event.stopPropagation()
    window.setTimeout(() => {
      closeMixerVolumeModal()
    }, 0)
  })

  document.querySelector('[data-close-premix]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    event.stopPropagation()
    window.setTimeout(() => {
      closePremixModal()
    }, 0)
  })
  document.querySelectorAll('[data-action="tuner-minus"]').forEach((el) => {
    const id = el.getAttribute('data-tuner-id')
    const actionKey = `tuner-minus:${id || ''}`
    bindTunerRapidTapAction(el, actionKey, (event) => handleTunerAdjust(id, -1, event))
  })
  document.querySelectorAll('[data-action="tuner-plus"]').forEach((el) => {
    const id = el.getAttribute('data-tuner-id')
    const actionKey = `tuner-plus:${id || ''}`
    bindTunerRapidTapAction(el, actionKey, (event) => handleTunerAdjust(id, 1, event))
  })
  document.querySelector('[data-close-bpm]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    event.stopPropagation()
    window.setTimeout(() => {
      closeBpmModal()
    }, 0)
  })
  document.querySelector('[data-close-tuner]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    event.stopPropagation()
    window.setTimeout(() => {
      closeTunerModal()
    }, 0)
  })
  bindReliableTapAction(document.querySelector('[data-action="loop"]'), 'loop', handleLoopToggle)

  document.querySelectorAll('[data-region-id]').forEach((el) => {
    const id = el.getAttribute('data-region-id')
    bindHashChildrenLongPress(el, 'region')
    bindReliableTapAction(el, `region:${id || ''}`, () => selectRegion(id))
  })

  document.querySelectorAll('[data-song-id]').forEach((el) => {
    const id = el.getAttribute('data-song-id')
    bindHashChildrenLongPress(el, 'song')
    bindReliableTapAction(el, `song:${id || ''}`, () => selectPlaylistSong(id))
  })

  document.querySelectorAll('[data-marker-id]').forEach((el) => {
    const id = el.getAttribute('data-marker-id')
    bindReliableTapAction(el, `marker:${id || ''}`, () => selectMarker(id))
  })

  if (state.editMode && !state.deleteMode) {
    bindEditDragHandlers('[data-region-id]', 'regions')
    bindEditDragHandlers('[data-song-id]', 'playlist')
  }

  document.querySelectorAll('.listBox, .lyricsScreen').forEach((swipeList) => {
    if (swipeList.dataset.directorSwipeBound === '1') return
    swipeList.dataset.directorSwipeBound = '1'
    swipeList.addEventListener('touchstart', handleTouchStart, { passive: true })
    swipeList.addEventListener('touchend', handleTouchEnd, { passive: false })
  })

  const visibleList = document.querySelector('.listBox')
  if (visibleList) {
    bindListScrollSync(visibleList)
    requestAnimationFrame(() => {
      applyBridgeScrollToVisibleList()
    })
  }

  document.querySelector('[data-action="close-create"]')?.addEventListener('click', handleCloseCreatePlaylist)
  document.querySelector('[data-action="confirm-create"]')?.addEventListener('click', handleConfirmCreatePlaylist)
  document.querySelector('[data-close-create]')?.addEventListener('click', handleCloseCreatePlaylist)
  document.querySelector('[data-action="close-existing"]')?.addEventListener('click', handleCloseAddExisting)
  document.querySelector('[data-action="close-playlist-switch"]')?.addEventListener('click', closePlaylistSwitchModal)
  document.querySelector('[data-action="confirm-playlist-switch"]')?.addEventListener('click', handleConfirmPlaylistSwitch)
  document.querySelector('[data-action="confirm-existing"]')?.addEventListener('click', handleConfirmAddExisting)
  document.querySelector('[data-close-existing]')?.addEventListener('click', handleCloseAddExisting)
  document.querySelectorAll('[data-existing-playlist-id]').forEach((el) => {
    el.addEventListener('click', () => {
      state.selectedExistingPlaylistId = el.getAttribute('data-existing-playlist-id')
      render()
    })
  })
  document.querySelectorAll('[data-switch-playlist-id]').forEach((el) => {
    el.addEventListener('click', () => {
      state.selectedSwitchPlaylistId = el.getAttribute('data-switch-playlist-id')
      render()
    })
  })
  document.querySelectorAll('[data-stop-modal]').forEach((el) => {
    el.addEventListener('click', (event) => event.stopPropagation())
  })
  document.querySelector('[data-action="close-rename"]')?.addEventListener('click', handleCloseRenameModal)
  document.querySelector('[data-action="confirm-rename"]')?.addEventListener('click', handleConfirmRenameModal)
  document.querySelector('[data-close-rename]')?.addEventListener('click', handleCloseRenameModal)
  document.querySelector('[data-settings-menu]')?.addEventListener('click', (event) => event.stopPropagation())
  const playlistNameInput = document.getElementById('playlistNameInput')
  if (playlistNameInput) {
    playlistNameInput.focus()
    playlistNameInput.addEventListener('input', (e) => {
      state.newPlaylistName = e.target.value
    })
    playlistNameInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') handleConfirmCreatePlaylist()
      if (e.key === 'Escape') handleCloseCreatePlaylist()
    })
  }

  const lyricsInput = document.getElementById('lyricsEditorInput')
  if (lyricsInput) {
    const lyricsScreen = document.querySelector('.lyricsScreen')
    try { lyricsInput.focus({ preventScroll: true }) } catch (_) { lyricsInput.focus() }
    try { lyricsInput.setSelectionRange(0, 0) } catch (_) {}
    if (lyricsScreen) lyricsScreen.scrollTop = 0
    requestAnimationFrame(() => {
      resizeLyricsEditorInput()
      if (lyricsScreen) lyricsScreen.scrollTop = 0
    })
    window.setTimeout(() => {
      resizeLyricsEditorInput()
      if (lyricsScreen) lyricsScreen.scrollTop = 0
    }, 120)
    lyricsInput.addEventListener('focus', () => window.setTimeout(scheduleLyricsEditorResizeAndScroll, 80))
    lyricsInput.addEventListener('click', scheduleLyricsEditorResizeAndScroll)
    lyricsInput.addEventListener('keyup', scheduleLyricsEditorResizeAndScroll)
    if (window.visualViewport && !window.__vshookLyricsVisualViewportBound) {
      window.__vshookLyricsVisualViewportBound = true
      window.visualViewport.addEventListener('resize', scheduleLyricsEditorResizeAndScroll)
      window.visualViewport.addEventListener('scroll', scheduleLyricsEditorResizeAndScroll)
    }
    lyricsInput.addEventListener('input', (e) => {
      state.lyricsDraft = String(e.target.value || '').slice(0, 4000)
      const count = document.querySelector('.lyricsCharCount')
      if (count) count.textContent = `${state.lyricsDraft.length} / 4000`
      scheduleLyricsEditorResizeAndScroll()
    })
  }

  const renameInput = document.getElementById('renameInput')
  if (renameInput) {
    renameInput.focus()
    renameInput.setSelectionRange(renameInput.value.length, renameInput.value.length)
    renameInput.addEventListener('input', (e) => {
      state.renameValue = e.target.value
    })
    renameInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') handleConfirmRenameModal()
      if (e.key === 'Escape') handleCloseRenameModal()
    })
  }

  document.getElementById('app')?.addEventListener('click', (event) => {
    if (!event.target.closest('[data-action=\"toggle-settings\"]') && !event.target.closest('[data-settings-menu]') && state.settingsMenuOpen) {
      state.settingsMenuOpen = false
      render()
    }
    if (!event.target.closest('[data-action="open-gear"]') && !event.target.closest('[data-stop-modal]') && state.showGearModal) {
      state.showGearModal = false
      render()
    }
  }, { once: true })

  const clear = document.getElementById('floatingClearButton')
  if (clear) {
    clear.addEventListener('click', clearSelection)
    clear.addEventListener('touchstart', (e) => { clearDragStartX = e.touches?.[0]?.clientX ?? null }, { passive: true })
    clear.addEventListener('touchend', (e) => {
      const endX = e.changedTouches?.[0]?.clientX ?? null
      if (clearDragStartX != null && endX != null) {
        const dx = endX - clearDragStartX
        if (dx >= 30) state.clearButtonSide = 'right'
        else if (dx <= -30) state.clearButtonSide = 'left'
        postCommand('clear_button_side', { side: state.clearButtonSide })
        render()
      }
    }, { passive: true })
  }
}

function installMarkerCancelHardDelegation() {
  if (window.__vshookMarkerCancelHardDelegation === '1') return
  window.__vshookMarkerCancelHardDelegation = '1'
  const run = (event) => {
    const target = event?.target?.closest?.('[data-action="marker-cancel"], .vshookMarkerCancelHardButton, .markerCancelGlobalButton')
    if (!target) return
    event.preventDefault?.()
    event.stopPropagation?.()
    handleMarkerCancel()
  }
  document.addEventListener('pointerup', run, true)
  document.addEventListener('click', run, true)
}

function renderBridgePopupHtml(extraClass = '') {
  const hasLocalPopup = state.appPopupVisible && String(state.appPopupText || '').trim()
  if (!hasLocalPopup && bridgePlaybackNamePopupKey && Date.now() >= Number(bridgePlaybackNamePopupExpireAtMs || 0) && normalizeDirectorPopupText(bridgePopupDisplay.text) === bridgePlaybackNamePopupKey) {
    hideExpiredDirectorPlaybackNamePopup(bridgePlaybackNamePopupKey)
    return ''
  }
  if (!hasLocalPopup && !bridgePopupDisplay.mounted) return ''
  const popupTextForRender = upperText(hasLocalPopup ? state.appPopupText : bridgePopupDisplay.text)
  const popupErrorForRender = hasLocalPopup ? (state.appPopupKind === 'error') : bridgePopupDisplay.error
  const popupPersistentForRender = hasLocalPopup ? false : bridgePopupDisplay.persistent
  const kind = hasLocalPopup ? String(state.appPopupKind || 'info').toLowerCase() : ''
  const bridgePopupClassSuffix = popupErrorForRender ? 'Error' : (kind === 'marker' ? 'Marker' : (/loop/i.test(String(popupTextForRender || '')) ? 'Success' : 'Marker'))
  const extra = extraClass ? ` ${extraClass}` : ''
  return `<div class="appPopup appPopup${bridgePopupClassSuffix}${extra} ${popupPersistentForRender ? 'appPopupPersistent' : 'appPopupTransient'} ${(!hasLocalPopup && bridgePopupDisplay.fading) ? 'appPopupHidden' : ''}">${escapeHtml(popupTextForRender)}</div>`
}

function syncBridgePopupDom() {
  const appShell = document.querySelector('#app > .app')
  if (!appShell) return
  const html = renderBridgePopupHtml()
  const lyricsSlot = state.lyricsPanelOpen ? document.querySelector('.lyricsScreen .lyricsPopupSlot') : null
  const rootPopup = appShell.querySelector(':scope > .appPopup')
  const slotPopup = lyricsSlot ? lyricsSlot.querySelector('.appPopup') : null

  if (!html) {
    if (rootPopup) rootPopup.remove()
    if (slotPopup) slotPopup.remove()
    return
  }

  const temp = document.createElement('div')
  temp.innerHTML = html
  const next = temp.firstElementChild
  if (!next) return

  // Na tela de letras do Diretor, o popup precisa nascer dentro do espaco reservado.
  // Antes ele ficava preso ao popup global e, quando o usuario ja estava na tela de letras,
  // as atualizacoes do DOM nao recriavam o popup no lugar certo.
  if (lyricsSlot) {
    if (rootPopup) rootPopup.remove()
    next.classList.add('lyricsInlinePopup')
    next.removeAttribute('style')
    if (slotPopup) slotPopup.replaceWith(next)
    else lyricsSlot.replaceChildren(next)
    return
  }

  if (slotPopup) slotPopup.remove()
  if (rootPopup) rootPopup.replaceWith(next)
  else appShell.insertAdjacentElement('afterbegin', next)
}

function __vshookRenderImmediate() {

  if (state.lyricsPanelOpen && document.querySelector('.lyricsScreen')) {
    const existingLyricsEditing = !!document.querySelector('.lyricsScreenEditing')
    if (existingLyricsEditing === !!state.lyricsEditing) {
      syncBridgePopupDom()
      syncLyricsPanelDom()
      bindEvents()
      return
    }
  }

  const renderScrollSnapshot = (() => {
    const listEl = document.querySelector('.listBox')
    if (!listEl) return null
    return {
      viewKey: `${state.activeTab}|${state.playlistView}|${String(state.activePlaylistId || '')}`,
      scrollTop: Number(listEl.scrollTop) || 0,
    }
  })()

  const appEl = document.getElementById('app')
  if (!appEl) return
  appEl.setAttribute('data-theme', state.theme || 'dark')

  if (needsAuthGate()) {
    if (!authGateWasVisible) {
      state.authShowPassword = false
      holdAuthBridgeRender(420)
    } else if (state.authShowPassword !== true) {
      state.authShowPassword = false
    }
    authGateWasVisible = true
    const previousFocusId = document.activeElement && document.activeElement.id ? document.activeElement.id : ''
    const previousSelectionStart = typeof document.activeElement?.selectionStart === 'number' ? document.activeElement.selectionStart : null
    const previousSelectionEnd = typeof document.activeElement?.selectionEnd === 'number' ? document.activeElement.selectionEnd : null
    state.authShowPassword = false
    const offlineLabel = bridgeLooksOffline() ? '<div class="authGateOffline">REAPER OFFLINE</div>' : ''
    const authHtml = `<div class="app authGateApp" data-theme="${escapeHtml(state.theme || 'dark')}"><div class="authGateWrap"><div class="authGateCard"><img class="authGateLogo" src="${LOADING_ICON_DATA_URL}" alt="VS Hook Diretor" /><div class="authGateTitle">VS Hook Diretor</div><div class="authGateSubtitle">ACESSO PROTEGIDO</div><form id="accessLoginForm" class="authGateForm"><input id="accessPassInput" class="authGateInput" type="password" inputmode="text" enterkeyhint="done" autocomplete="current-password" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="SENHA" value="${escapeHtml(state.authPassInput || '')}" /><button class="authGateButton" type="submit" ${bridgeLooksOffline() ? 'disabled' : ''}>ENTRAR</button><button class="authGateBackButton" type="button" data-action="back-project-selector">VOLTAR</button><div id="accessAuthError" class="authGateError" style="${state.authError ? '' : 'display:none'}">${escapeHtml(state.authError || '')}</div>${offlineLabel}</form></div></div></div>`
    appEl.innerHTML = authHtml
    document.getElementById('accessLoginForm')?.addEventListener('submit', handleAccessLoginSubmit)
    document.querySelector('[data-action="back-project-selector"]')?.addEventListener('click', backToVSHookProjectSelector)

    const accessPassInput = document.getElementById('accessPassInput')

    const authFocusHandler = () => holdAuthBridgeRender(420)
    const authBlurHandler = () => {
      holdAuthBridgeRender(260)
      window.setTimeout(() => {
        if (needsAuthGate() && !isAuthInputFocused()) {
          syncAccessPasswordUi()
        }
      }, 40)
    }

    accessPassInput?.addEventListener('input', handleAccessInputChange)
    accessPassInput?.addEventListener('focus', authFocusHandler)
    accessPassInput?.addEventListener('blur', authBlurHandler)
    accessPassInput?.addEventListener('pointerdown', focusAccessPassInputSoon, { passive: true })
    accessPassInput?.addEventListener('touchend', focusAccessPassInputSoon, { passive: true })
    accessPassInput?.addEventListener('click', focusAccessPassInputSoon)

    if (previousFocusId === 'accessPassInput') {
      const target = document.getElementById(previousFocusId)
      if (target) {
        target.focus({ preventScroll: true })
        if (previousSelectionStart !== null && previousSelectionEnd !== null && typeof target.setSelectionRange === 'function') {
          target.setSelectionRange(previousSelectionStart, previousSelectionEnd)
        }
      }
    }
    return
  }

  authGateWasVisible = false

  const app = document.getElementById('app')
  if (!app) return
  const playlist = activePlaylist()
  const markers = currentMarkers()
  syncDirectorMarkerArmedVisualWithPlayback(markers)
  const hue = getBorderColorCss()
  const glow = getBorderGlowCss()
  const topTitle = state.activeTab === 'playlist' ? upperText(playlist?.name || 'SEM REPERTÓRIO') : 'ESCOLHA SUAS MUSICAS'
  const timerText = formatChronoTime(getTimerElapsedSec())
  const topTitleHtml = state.activeTab === 'playlist' ? `<button class="playlistTitleButton" data-action="open-playlist-switch"><span class="playlistTitleContent">${buildTitleTicker(topTitle)}</span><span class="playlistTitleArrow">▾</span></button>` : `<span class="regionsTopLabel">MÚSICAS</span>`
  const topTimerHtml = `<button class="topTimerButton ${state.timerRunning || state.timerMode === 'local_time' ? 'topTimerButtonRunning' : ''}" data-action="open-timer"><span data-chrono-display>${state.timerMode === 'local_time' ? getDirectorDeviceLocalTimeText() : timerText}</span></button>`
  const topTime = state.activeTab === 'playlist'
    ? `${resolveDirectorPlaylistTotalText(playlist)}`
    : `${resolveDirectorRegionsTotalText()}`

  // 2.0.35: Cancelar de Markers aparece somente quando o marker estiver verde/engatilhado.
  // O rodapé reserva espaço fixo na tela de Markers para o botão não cobrir a lista.
  const markerCancelVisible = shouldShowDirectorMarkerCancelButton()
  const showMarkerFooterSpace = isMarkersPanelOpen()
  const markerFooterHtml = state.playlistView === 'markers'
    ? `<div class="directorMarkersCancelFooter ${markerCancelVisible ? 'directorMarkersCancelFooterActive' : 'directorMarkersCancelFooterIdle'}">${markerCancelVisible ? `<button class="directorMarkersCancelButton markerCancelGlobalButton" data-action="marker-cancel" type="button">Cancelar</button>` : ''}</div>`
    : ''
  const markerCancelGlobalButton = ''

  const content = state.activeTab === 'regions'
    ? `<div class="contentPanel"><div class="controlsStickyPanel"><div class="controlsRowPlaylist controlsRowEqual controlsRowDirectorMain"><button class="${getPlayButtonClass()}" data-action="play">${getPlayButtonLabel()}</button><button class="${getAutoplayVisualEnabled() ? 'btnAutoplayActive' : 'btn'}" data-action="autoplay">AUTO</button><button class="tab btnLyricsOpen lyricsNavButton lyricsNavButtonInline" data-action="open-lyrics-panel">&lt;&lt;</button></div>${renderNowPlayingBanner()}</div><div class="listBox">${renderRows(vshookGetDisplayItemsWithFrontHashChildren(state.regions || [], 'region', ''), 'region')}</div></div>`
    : `<div class="contentPanel ${state.playlistView === 'markers' ? `markerContentPanel ${Date.now() < Number(state.markersPanelAnimateUntil || 0) ? 'markerPanelSlideIn' : ''}` : ''}"><div class="controlsStickyPanel">${state.playlistView === 'markers'
        ? `<div class="controlsRowPlaylist controlsRowEqual controlsRowMarkers"><button class="${getPlayButtonClass()}" data-action="play">${getPlayButtonLabel()}</button><button class="${state.loopActive ? 'btnLoopActive loopBlink markerLoopButton' : 'btn markerLoopButton'}" data-action="loop">Loop</button><button class="tab btnLyricsOpen lyricsNavButton markersInlineBackButton markerBackLyricsButton" data-action="close-markers">&lt;&lt;</button></div>`
        : `<div class="controlsRowPlaylist controlsRowEqual controlsRowDirectorMain"><button class="${getPlayButtonClass()}" data-action="play">${getPlayButtonLabel()}</button><button class="${getAutoplayVisualEnabled() ? 'btnAutoplayActive' : 'btn'}" data-action="autoplay">AUTO</button><button class="tab btnLyricsOpen lyricsNavButton lyricsNavButtonInline" data-action="open-lyrics-panel">&lt;&lt;</button></div>`}
       ${state.playlistView === 'markers' ? '' : `${renderNowPlayingBanner()}`}</div>
       <div class="listBox ${state.playlistView === 'markers' ? `markerListBox ${Date.now() < Number(state.markersPanelAnimateUntil || 0) ? 'markerPanelSlideIn' : ''}` : ''}" id="playlistListBox">${state.playlistView === 'markers' ? renderRows(markers, 'marker') : renderRows(vshookGetDisplayItemsWithFrontHashChildren(playlist?.songs || [], 'song', playlist?.id), 'song')}</div>${markerFooterHtml}</div>`

  const shouldShowClearButton = !state.editMode && !state.deleteMode && isMultiSelectActiveFor('regions') && state.selectedRegionIds.length > 0
  const showSettingsButton = true
  const showEditDoneFloating = state.editMode
  const showDeleteConfirmFloating = state.deleteMode
  const showDeleteCancelFloating = state.deleteMode
  const middleLabel = state.activeTab === 'playlist' && state.playlistView === 'markers' ? '' : (state.deleteMode ? 'Deletar ativo' : (state.editMode ? 'Edit ativo' : (isMultiSelectActiveFor('regions') ? 'Select ativo' : '')))
  const renameTarget = getRenameTargetContext()
  const canRename = !!renameTarget && !state.editMode && !state.deleteMode && !isMultiSelectActiveFor('regions')
  const canDelete = state.activeTab === 'playlist' && state.playlistView !== 'markers' && !state.editMode && !state.deleteMode
  const settingsButtonActive = state.editMode || state.deleteMode || state.settingsMenuOpen
  const canCopyPlaylistNames = state.activeTab === 'playlist' && state.playlistView !== 'markers' && !!(playlist?.songs || []).length
  const settingsMenu = state.settingsMenuOpen
    ? `<div class="settingsMenu" data-settings-menu><button class="settingsAction" data-action="open-project-tabs">PROJETOS</button><button class="settingsAction" data-action="open-mixer">MIXER</button><button class="settingsAction settingsActionPremix" data-action="open-premix">PREMIX</button><button class="settingsAction settingsActionRecados" data-action="open-recados">RECADOS</button>${state.activeTab === 'playlist' && state.playlistView !== 'markers' ? `<button class="settingsAction ${state.autoBlocoEnabled ? 'settingsActionActive' : ''}" data-action="auto-bloco">AT/BL</button><button class="settingsAction settingsActionCopy" data-action="copy-playlist-names" ${canCopyPlaylistNames ? '' : 'disabled'}>COPY</button>` : ''}</div>`
    : ''
  const rightToolsHtml = showSettingsButton
    ? (state.activeTab === 'playlist' && state.playlistView === 'markers'
        ? `<div class="topRightTools"><button class="menuButton gearMenuButton" data-action="open-gear">⚙</button></div>`
        : `<div class="topRightTools"><div class="settingsWrap"><button class="${settingsButtonActive ? 'menuButtonActive' : 'menuButton'}" data-action="toggle-settings"><span class="menuBars"><i></i><i></i><i></i></span></button>${settingsMenu}</div><button class="menuButton gearMenuButton" data-action="open-gear">⚙</button></div>`)
    : `<div class="topRightSpacer"></div>`

  const createModal = state.showCreatePlaylistModal
    ? `<div class="modalOverlay" data-close-create><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">CRIAR REPERTÓRIO</div><input id="playlistNameInput" class="modalInput" value="${escapeHtml(state.newPlaylistName)}" placeholder="Nome do repertório" /><div class="modalButtons"><button class="modalCancelBtn" data-action="close-create">Cancelar</button><button class="modalOkBtnWide" data-action="confirm-create">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const addExistingModal = state.showAddExistingModal
    ? `<div class="modalOverlay" data-close-existing><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">ADICIONAR NO REPERTÓRIO</div><div class="playlistSelectList">${state.playlists.map((playlistItem) => `<button class="${String(state.selectedExistingPlaylistId || '') === String(playlistItem.id) ? 'playlistOptionActive' : 'playlistOption'}" data-existing-playlist-id="${escapeHtml(playlistItem.id)}"><span class="playlistOptionText">${escapeHtml(upperText(playlistItem.name || 'Playlist'))}</span></button>`).join('')}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="close-existing">Cancelar</button><button class="modalOkBtnWide" data-action="confirm-existing">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const projectTabsModal = renderProjectTabsModal()
  const renamePlaceholder = state.renameIsBlock ? 'Digite apenas o nome' : 'Novo nome'
  const renameTitle = state.renameTargetType === 'region' ? 'Renomear música' : 'Renomear item'
  const renameModal = state.showRenameModal
    ? `<div class="modalOverlay" data-close-rename><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">${renameTitle}</div><input id="renameInput" class="modalInput" value="${escapeHtml(state.renameValue)}" placeholder="${renamePlaceholder}" /><div class="modalButtons"><button class="modalCancelBtn" data-action="close-rename">Cancelar</button><button class="modalOkBtnWide" data-action="confirm-rename">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const playlistSwitchModal = state.showPlaylistSwitchModal
    ? `<div class="modalOverlay" data-close-playlist-switch><div class="modalSpacer"></div><div class="modalBox playlistSwitchBox" data-stop-modal><div class="modalTitle">REPERTÓRIOS</div><div class="playlistSelectList compactPlaylistSelectList">${state.playlists.map((playlistItem) => `<button class="${String(state.selectedSwitchPlaylistId || state.activePlaylistId || '') === String(playlistItem.id) ? 'playlistOptionActive' : 'playlistOption'} compactPlaylistOption" data-switch-playlist-id="${escapeHtml(playlistItem.id)}">${buildPlaylistOptionTicker(playlistItem.name || 'Playlist')}</button>`).join('')}</div><div class="modalButtons playlistSwitchButtons"><button class="modalCancelBtn" data-action="close-playlist-switch">Fechar</button><button class="modalOkBtnWide" data-action="confirm-playlist-switch">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const deletePlaylistConfirmModal = state.showDeletePlaylistConfirmModal
    ? `<div class="modalOverlay" data-close-delete-playlist><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">DESEJA APAGAR ESTE REPERTÓRIO?</div><div class="modalButtons"><button class="modalCancelBtn" data-action="close-delete-playlist">Cancelar</button><button class="modalOkBtnWide" data-action="confirm-delete-playlist">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const tunerModal = renderTunerModal()
  const recadosModal = renderRecadosModal()

  const gearModal = state.showGearModal
    ? `<div class="modalOverlay" data-close-gear><div class="modalSpacer"></div><div class="modalBox settingsModalBox" data-stop-modal><div class="modalTitle">CONFIGURAÇÕES</div><div class="bridgeStatusCard"><span class="bridgeStatusLabel">CONEXÃO</span><span class="bridgeOnline">NATIVE ON</span></div><div class="settingsSectionTitle">BORDA RGB</div><div class="settingsGrid settingsGridSingle"><button class="settingsToggleBtn settingsToggleWide" data-action="cycle-rgb-mode">RGB: ${getRgbModeLabel()}</button></div>${getDirectorProtectionSettingsHtml()}${typeof getDirectorTpSettingsHtmlFix12 === 'function' ? getDirectorTpSettingsHtmlFix12() : ''}<div class="settingsSectionTitle">TEMA</div><div class="settingsGrid settingsGridTheme"><button class="${state.theme === 'dark' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-dark">ESCURO</button><button class="${state.theme === 'light' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-light">CLARO</button></div><div class="modalButtons settingsBottomButtons"><button class="modalCancelBtn vshookExitButton" data-action="back-project-selector">SAIR</button><button class="modalOkBtnWide settingsCloseButton" data-action="close-gear">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const timerModalTitle = state.timerRunning ? 'DESEJA PARAR?' : 'DESEJA INICIAR?'
  const timerModeLabel = state.timerMode === 'local_time' ? 'HORÁRIO LOCAL' : (state.timerMode === 'countdown' ? 'REGRESSIVO' : 'PROGRESSIVO')
  const timerTargetParts = getTimerTargetPartsFromSeconds(state.timerTargetSec || 0)
  const timerTargetEditor = state.timerMode === 'countdown'
    ? `<div class="timerTargetEditor"><div class="timerTargetLabel">TEMPO REGRESSIVO</div><div class="timerTargetGrid"><label>H<input data-timer-part="h" type="number" inputmode="numeric" min="0" max="99" value="${timerTargetParts.h}"></label><label>M<input data-timer-part="m" type="number" inputmode="numeric" min="0" max="59" value="${timerTargetParts.m}"></label><label>S<input data-timer-part="s" type="number" inputmode="numeric" min="0" max="59" value="${timerTargetParts.s}"></label></div></div>`
    : ''
  const timerConfirmLabel = state.timerRunning ? 'PARAR' : 'INICIAR'
  const timerModal = state.showTimerModal
    ? `<div class="modalOverlay" data-close-timer><div class="modalSpacer"></div><div class="modalBox timerModalBox timerModalBoxWide" data-stop-modal><div class="modalTitle">CRONÔMETRO</div><div class="timerModalPreview" data-chrono-display>${state.timerMode === 'local_time' ? getDirectorDeviceLocalTimeText() : (state.timerMode === 'countdown' && !state.timerRunning ? formatChronoTime(state.timerTargetSec || 0) : timerText)}</div><div class="timerModeCurrent">MODO: ${timerModeLabel}</div><div class="timerModeGrid timerModeGrid3"><button class="${state.timerMode === 'progressive' ? 'modalOkBtnWide' : 'modalCancelBtn'}" data-action="timer-mode-progressive">PROGRESSIVO</button><button class="${state.timerMode === 'countdown' ? 'modalOkBtnWide' : 'modalCancelBtn'}" data-action="timer-mode-countdown">REGRESSIVO</button><button class="${state.timerMode === 'local_time' ? 'modalOkBtnWide' : 'modalCancelBtn'}" data-action="timer-mode-local">HORÁRIO LOCAL</button></div>${timerTargetEditor}<div class="modalTitle timerModalActionTitle">${timerModalTitle}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="close-timer">SAIR</button><button class="modalOkBtnWide" data-action="confirm-timer">${timerConfirmLabel}</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const liveOffConfirmModal = state.showLiveOffConfirmModal
    ? `<div class="modalOverlay"><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">DESLIGAR LIVE?</div><div class="modalInfoText">Ao desligar o Live, as marcações de músicas já tocadas serão limpas.</div><div class="modalButtons"><button class="modalCancelBtn" data-action="cancel-live-off">Cancelar</button><button class="modalOkBtnWide" data-action="confirm-live-off">OK</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const mixerModal = renderMixerModal()
  const mixerVolumeModal = renderMixerVolumeModal()
  const premixModal = renderPremixModal()
  const premixVolumeModal = renderPremixVolumeModal()
  const bpmModal = renderBpmModal()

  const appBorderColor = state.rgbMode === 'off' ? 'rgba(71,85,105,0.85)' : hue
  const appBorderGlow = state.rgbMode === 'off' ? 'rgba(71,85,105,0.35)' : glow
  const borderStyle = state.rgbMode === 'off'
    ? `border-color:rgba(71,85,105,0.55);box-shadow:0 0 0 1px rgba(71,85,105,0.35), inset 0 0 10px rgba(255,255,255,0.03);`
    : `border-color:${hue};box-shadow:0 0 0 1px ${hue}, 0 0 14px ${glow}, inset 0 0 10px rgba(255,255,255,0.03);`

  const markersToggleButton = state.activeTab === 'playlist' && state.playlistView !== 'markers'
    ? `<button class="tab markersNavButton markersNavButtonHeader markerOpenYellowButton" data-action="open-markers">&gt;&gt;</button>`
    : ''
  const lyricsHeaderButton = ''
  const headerNavButtons = (markersToggleButton || lyricsHeaderButton)
    ? `<span class="headerNavButtons">${markersToggleButton}${lyricsHeaderButton}</span>`
    : ''
  const lyricsPanelHtml = renderLyricsPanel()
  const appPopupHtml = renderBridgePopupHtml(isMarkersPanelOpen() ? 'appPopupMarkersPanel' : '')

  app.innerHTML = `<div class="app" data-theme="${state.theme}" style="--app-border-color:${appBorderColor};--app-border-glow:${appBorderGlow};"><style>.app{height:var(--app-vh,100dvh);min-height:var(--app-vh,100dvh);overflow:hidden}.container{height:calc(var(--app-vh,100dvh) - 16px)!important;min-height:calc(var(--app-vh,100dvh) - 16px)!important;overflow:hidden}@media (max-width:480px){.container{height:calc(var(--app-vh,100dvh) - 12px)!important;min-height:calc(var(--app-vh,100dvh) - 12px)!important}}.contentPanel{display:flex;flex-direction:column;flex:1;min-height:0;padding-bottom:2px}.controlsStickyPanel{flex:0 0 auto;position:relative;z-index:4;background:linear-gradient(180deg,#0a1018 0%,#06090f 100%)}.topTimerButton{min-width:96px;height:34px;padding:0 10px;border-radius:10px;border:1px solid #475569;background:#111827;color:#facc15;font-weight:900;font-size:14px;letter-spacing:.03em}.topTimerButtonRunning{border-color:#22c55e;background:#052e16;color:#86efac;box-shadow:0 0 0 1px rgba(34,197,94,.28),0 0 16px rgba(34,197,94,.14)}.timerModalBox{max-width:330px}.timerModalBoxWide{width:min(92vw,480px)!important;max-width:480px!important}.timerModeGrid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}.timerModeGrid3{grid-template-columns:1fr 1fr 1fr!important}.timerModeGrid3 button{font-size:11px!important;padding:0 6px!important}.timerModeGrid button{min-height:44px;border-radius:12px;font-weight:900}.timerModeCurrent{text-align:center;color:#facc15;font-weight:900;margin:-4px 0 6px}.timerTargetEditor{margin:10px 0 8px;padding:10px;border:1px solid rgba(250,204,21,.35);border-radius:12px;background:rgba(250,204,21,.08)}.timerTargetLabel{text-align:center;color:#fde68a;font-weight:900;font-size:13px;margin-bottom:8px}.timerTargetGrid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}.timerTargetGrid label{display:flex;flex-direction:column;gap:5px;text-align:center;color:#cbd5e1;font-weight:900;font-size:12px}.timerTargetGrid input{width:100%;height:42px;border-radius:10px;border:1px solid #475569;background:#020617;color:#f8fafc;text-align:center;font-weight:900;font-size:18px;box-sizing:border-box}.app[data-theme="light"] .timerTargetGrid input{background:#fff;color:#0f172a;border-color:#cbd5e1}.timerModalActionTitle{font-size:14px!important;margin-top:6px!important}.modalInfoText{color:#e5e7eb;text-align:center;font-weight:800;line-height:1.35;margin:12px 0 16px}.timerModalPreview{height:54px;display:flex;align-items:center;justify-content:center;border:1px solid #374151;border-radius:10px;background:#05070a;color:#facc15;font-size:22px;font-weight:900;margin-bottom:14px}.progressBar{position:absolute;left:0;top:0;bottom:0;opacity:1;background:linear-gradient(90deg,#22c55e 0%,#16a34a 100%);pointer-events:none;border-radius:0;box-shadow:inset 0 0 0 1px rgba(134,239,172,.28),0 0 10px rgba(34,197,94,.22)}.progressBarWithNumber{left:42px}.sectionLabelSticky{margin-bottom:8px}.listBox{flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;padding-bottom:calc(env(safe-area-inset-bottom,0px) + 118px);scroll-padding-bottom:calc(env(safe-area-inset-bottom,0px) + 118px)}.markersNavButtonWide{min-width:88px;padding:10px 24px;font-size:22px;justify-content:center}.headerTotalSpacer{flex:1 1 auto;min-width:4px}.headerNavStack{display:flex;flex-direction:column;gap:4px;align-items:stretch}.headerNavFloating{position:absolute;right:12px;top:76px;z-index:8;width:88px}.headerNavFloatingSingle{position:absolute;right:12px;top:120px;z-index:8;width:88px}.headerLyricsButton{padding-top:8px;padding-bottom:8px;font-size:20px}.markersInlineBackButton{height:46px!important;min-height:46px!important;padding:0 10px!important;font-size:18px!important;border-radius:12px!important}.markerLoopButton{height:46px!important;min-height:46px!important;border-radius:12px!important;font-size:18px!important}.markerBackLyricsButton{background:linear-gradient(180deg,#facc15 0%,#d97706 100%)!important;border-color:#fde047!important;color:#111827!important;box-shadow:0 0 0 1px rgba(250,204,21,.35),0 0 12px rgba(250,204,21,.22)!important}.settingsBottomButtons{display:grid!important;grid-template-columns:1fr 1fr!important;gap:10px!important;margin-top:26px!important}.settingsBottomButtons>*{width:100%!important;min-height:46px!important;border-radius:12px!important;font-weight:900!important}.settingsCloseButton{border:1px solid #475569!important;background:#111827!important;color:#f8fafc!important}@keyframes appPopupFade{0%{opacity:0;transform:translateX(-50%) translateY(8px)}12%{opacity:1;transform:translateX(-50%) translateY(0)}78%{opacity:1;transform:translateX(-50%) translateY(0)}100%{opacity:0;transform:translateX(-50%) translateY(10px)}}@keyframes loopBlinkPulse{0%{opacity:1;box-shadow:0 0 0 rgba(250,204,21,0)}50%{opacity:.38;box-shadow:0 0 16px rgba(250,204,21,.58)}100%{opacity:1;box-shadow:0 0 0 rgba(250,204,21,0)}}.loopBlink{animation:loopBlinkPulse .58s linear infinite}.appPopup{position:fixed;left:50%;bottom:22px;top:auto;transform:translateX(-50%) translateY(0);z-index:3000;pointer-events:none;width:min(86vw,520px);min-height:78px;padding:16px 22px;border-radius:10px;font-weight:900;font-size:22px;line-height:1.18;text-align:center;display:flex;align-items:center;justify-content:center;box-shadow:0 18px 42px rgba(0,0,0,.46);border:1px solid rgba(255,255,255,.16);backdrop-filter:blur(8px);opacity:1;transition:opacity .22s ease,transform .22s ease}.appPopupTransient{animation:none;opacity:1;transform:translateX(-50%) translateY(0)}.appPopupHidden{opacity:0;transform:translateX(-50%) translateY(10px)}.appPopupInfo{background:rgba(17,24,39,.97);color:#f8fafc}.appPopupSuccess{background:rgba(21,128,61,.97);color:#fff}.appPopupMarker{background:rgba(250,204,21,.98);color:#111827;border-color:rgba(255,255,255,.35)}.appPopupError{background:rgba(185,28,28,.97);color:#fff}.appPopupPersistent{animation:none;opacity:1;transform:translateX(-50%) translateY(0)}@media (max-width:480px){.appPopup{width:min(88vw,460px);min-height:66px;padding:12px 16px;font-size:18px}.markersNavButtonWide{min-width:82px;padding:10px 20px;font-size:20px}.headerNavFloating{right:10px;top:72px;width:82px}.headerNavFloatingSingle{right:10px;top:114px;width:82px}.topTimerButton{min-width:88px;height:32px;font-size:13px;padding:0 8px}.timerModalPreview{font-size:20px;height:50px}}.mixerOverlay{align-items:center;justify-content:flex-start}.mixerVolumeOverlay{align-items:center;justify-content:flex-start;background:rgba(0,0,0,.52)}.mixerModalBox,.mixerVolumeModalBox,.bpmModalBox{width:min(92vw,420px)}.mixerRowsBox{border:1px solid #364152;border-radius:10px;background:#0b1220}.mixerRow{display:grid;grid-template-columns:10px 34px minmax(0,1fr) 58px 10px 38px 38px;align-items:center;gap:8px;padding:10px 10px;border-bottom:1px solid #18212c;min-height:56px;touch-action:pan-y}.mixerRow:last-child{border-bottom:none}.mixerRowColor{width:8px;height:36px;border-radius:999px;background:var(--mixer-color,#334155)}.mixerRowIndex{font-weight:900;color:#cbd5e1;text-align:center}.mixerRowMain{min-width:0}.mixerRowName{font-weight:900;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowGroupName{font-size:11px;color:#94a3b8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowDb{font-weight:900;color:#e2e8f0;text-align:right}.mixerMeter{position:relative;width:10px;height:38px;border-radius:999px;background:#111827;overflow:hidden;border:1px solid #334155}.mixerMeterFill{position:absolute;left:0;right:0;bottom:0;border-radius:999px;background:linear-gradient(180deg,#22c55e 0%,#16a34a 100%)}.mixerMiniBtn{height:34px;width:34px;border-radius:8px;border:1px solid #475569;background:#111827;color:#f8fafc;font-weight:900}.mixerMiniBtnActive{background:#15803d;border-color:#22c55e;color:#fff}.mixerVolumeTitle{margin:8px 0 14px;padding:12px 14px;border-radius:10px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);box-shadow:inset 3px 0 0 var(--mixer-color,#334155);font-weight:900}.mixerVolumeMeterWrap{display:flex;align-items:center;justify-content:center;gap:14px;margin-bottom:14px}.mixerVolumeDb{font-size:28px;font-weight:900;color:#f8fafc}.mixerVolumeSlider{width:100%;height:46px;appearance:none;background:transparent;touch-action:pan-x;will-change:transform}.mixerVolumeSlider::-webkit-slider-runnable-track{height:14px;border-radius:999px;background:#1f2937;border:1px solid #475569}.mixerVolumeSlider::-webkit-slider-thumb{-webkit-appearance:none;appearance:none;width:30px;height:30px;border-radius:50%;background:#22c55e;border:2px solid #ecfdf5;box-shadow:0 0 0 3px rgba(34,197,94,.18);margin-top:-9px}.mixerVolumeSlider::-moz-range-track{height:14px;border-radius:999px;background:#1f2937;border:1px solid #475569}.mixerVolumeSlider::-moz-range-thumb{width:30px;height:30px;border-radius:50%;background:#22c55e;border:2px solid #ecfdf5;box-shadow:0 0 0 3px rgba(34,197,94,.18)}.mixerSwipeHint{margin-top:12px}.bpmModalBox{max-width:320px}.bpmValueDisplay{font-size:42px;font-weight:900;text-align:center;margin:8px 0 10px;color:#f8fafc}.bpmMetaText{text-align:center;color:#cbd5e1;font-weight:700;margin-bottom:14px}.bpmControlsSimple{display:grid;grid-template-columns:1fr 1fr;gap:10px}.bpmAdjustBtn{height:52px;border-radius:12px;border:1px solid #22c55e;background:#15803d;color:#fff;font-size:28px;font-weight:900}.settingsActionTuner{background:#102a20;border-color:#34d399;color:#a7f3d0}.tunerOverlay{z-index:1670;align-items:stretch;justify-content:flex-end;padding:0;background:rgba(0,0,0,.45)}.tunerDrawer{width:clamp(260px,52vw,430px);height:var(--app-vh,100dvh);background:#111827;border-left:1px solid #364152;box-shadow:-18px 0 42px rgba(0,0,0,.45);padding:16px 14px 20px;display:flex;flex-direction:column;gap:10px;overflow:hidden}.tunerDrawerHeader{display:flex;align-items:flex-start;justify-content:space-between;gap:8px}.tunerDrawerSub{color:#94a3b8;font-weight:700;font-size:12px;margin-top:-4px}.tunerDrawerActions{display:flex;justify-content:flex-end}.tunerResetBtn{min-height:40px;padding:0 14px;border-radius:10px;border:1px solid #facc15;background:#3b2f0b;color:#fde68a;font-weight:900}.tunerRowsBox{flex:1 1 auto;min-height:0;overflow-y:auto;border:1px solid #364152;border-radius:10px;background:#0b1220}.tunerRow{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;padding:10px;border-bottom:1px solid #18212c}.tunerRow:last-child{border-bottom:none}.tunerRowName{font-weight:900;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tunerRowBlock .tunerRowName{color:#facc15}.tunerRowControls{display:grid;grid-template-columns:58px minmax(64px,1fr) 58px;gap:4px;align-items:center}.tunerAdjustHitBtn{height:58px;width:58px;border:0;background:transparent;padding:0;margin:0;display:flex;align-items:center;justify-content:center;touch-action:manipulation;-webkit-tap-highlight-color:transparent}.tunerAdjustBtnFace{height:42px;width:42px;border-radius:10px;border:1px solid #475569;background:#111827;color:#f8fafc;font-size:24px;font-weight:900;display:flex;align-items:center;justify-content:center;box-sizing:border-box;pointer-events:none}.tunerValueBox{height:42px;border-radius:10px;border:1px solid #334155;background:#020617;color:#facc15;font-weight:900;font-size:20px;display:flex;align-items:center;justify-content:center}.app[data-theme="light"] .settingsActionTuner{background:#d1fae5;color:#065f46}.app[data-theme="light"] .tunerDrawer{background:#ffffff;border-left-color:#dbe4ee}.app[data-theme="light"] .tunerRowsBox{background:#f8fafc;border-color:#dbe4ee}.app[data-theme="light"] .tunerRowName{color:#0f172a}@media (max-width:480px){.tunerDrawer{width:calc(50vw + 26px);min-width:260px;padding:14px 12px 18px}.tunerRowControls{grid-template-columns:54px minmax(58px,1fr) 54px;gap:2px}.tunerAdjustHitBtn{height:54px;width:54px}.tunerAdjustBtnFace{height:38px;width:38px}.tunerValueBox{height:38px}}.markerFooterContainer .listBox{padding-bottom:160px!important;scroll-padding-bottom:160px!important}.vshookMarkerFooter{position:fixed;left:8px;right:8px;bottom:calc(env(safe-area-inset-bottom,0px) + 104px);z-index:2990;display:flex;justify-content:center;pointer-events:none}.vshookMarkerFooter .floatingCancelButton{position:static!important;left:auto!important;right:auto!important;bottom:auto!important;transform:none!important;width:min(62vw,280px)!important;min-width:190px!important;pointer-events:auto}.app:has(.vshookMarkerFooter) .appPopup{bottom:calc(env(safe-area-inset-bottom,0px) + 12px)!important}.app:has(.vshookMarkerFooter) .contentPanel{padding-bottom:0!important}@media(max-width:480px){.markerFooterContainer .listBox{padding-bottom:150px!important;scroll-padding-bottom:150px!important}.vshookMarkerFooter{bottom:calc(env(safe-area-inset-bottom,0px) + 98px)}}.markerGoConfirmed{background:#16a34a!important;border-color:#22c55e!important;color:#fff!important;box-shadow:inset 0 0 0 1px rgba(134,239,172,.38),0 0 16px rgba(34,197,94,.28)!important}.markerGoConfirmed .text,.markerGoConfirmed .timeText,.markerGoConfirmed .markerSelectedText,.markerGoConfirmed .markerSelectedTimeText,.markerGoConfirmed .marqueeStatic,.markerGoConfirmed .marqueeTrack,.markerGoConfirmed .marqueeSegment{color:#fff!important}.markerContentPanel{display:flex;flex-direction:column;min-height:0}.markerListBox{flex:1 1 auto;min-height:0;overflow-y:auto;padding-bottom:8px!important;scroll-padding-bottom:12px!important;border-bottom-left-radius:0;border-bottom-right-radius:0}.vshookFixedFooter{flex:0 0 155px!important;min-height:155px!important;margin-top:6px!important;padding:10px 12px calc(env(safe-area-inset-bottom,0px) + 10px)!important;border-top:1px solid rgba(148,163,184,.32);background:linear-gradient(180deg,rgba(15,23,42,.98),rgba(2,6,23,.99));display:flex;align-items:flex-start;justify-content:center;position:relative;z-index:20}.vshookFixedFooter .floatingCancelButton{position:static!important;left:auto!important;right:auto!important;bottom:auto!important;transform:none!important;width:min(62vw,280px)!important;min-width:190px!important;height:54px!important;pointer-events:auto;z-index:2}.footerButtonPlaceholder{height:54px}.app:has(.vshookFixedFooter) .appPopup{bottom:calc(env(safe-area-inset-bottom,0px) + 14px)!important;z-index:3010;min-height:54px!important;padding:9px 14px!important;font-size:17px!important;width:min(76vw,340px)!important;line-height:1.06!important}@media(max-width:480px){.vshookFixedFooter{flex-basis:148px;min-height:148px}.vshookFixedFooter .floatingCancelButton{height:52px!important}.app:has(.vshookFixedFooter) .appPopup{min-height:50px!important;padding:8px 12px!important;font-size:16px!important;width:min(74vw,320px)!important}}.controlsStickyPanel .controlsRowDirectorMain{grid-template-columns:minmax(112px,1fr) minmax(112px,1fr) minmax(112px,1fr)!important;gap:8px!important;width:100%!important;max-width:100%!important;justify-content:stretch!important}.controlsStickyPanel .controlsRowDirectorMain>*{width:100%!important;max-width:none!important;height:46px!important;min-height:46px!important;font-size:18px!important;border-radius:12px!important}.lyricsNavButtonInline{border-color:#38bdf8!important;background:linear-gradient(180deg,#0284c7 0%,#075985 100%)!important;color:#fff!important;box-shadow:0 0 0 1px rgba(56,189,248,.30),0 0 12px rgba(14,165,233,.20)!important}.tabRow{padding-right:86px!important}.tabRow .headerNavButtons{width:82px!important}.tabRow .markersNavButtonHeader{flex:0 0 82px!important;width:82px!important;min-width:82px!important}.tabRow .lyricsNavButtonHeader{display:none!important}@media(max-width:380px){.controlsStickyPanel .controlsRowDirectorMain{grid-template-columns:minmax(96px,1fr) minmax(96px,1fr) minmax(96px,1fr)!important;gap:7px!important}.controlsStickyPanel .controlsRowDirectorMain>*{height:44px!important;min-height:44px!important;font-size:17px!important}.tabRow{padding-right:78px!important}.tabRow .headerNavButtons{width:74px!important}.tabRow .markersNavButtonHeader{flex-basis:74px!important;width:74px!important;min-width:74px!important}}.controlsStickyPanel .controlsRowMarkers{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1fr)!important;gap:8px!important;width:100%!important;max-width:100%!important;justify-content:stretch!important}.controlsStickyPanel .controlsRowMarkers>*{width:100%!important;max-width:none!important;height:46px!important;min-height:46px!important;font-size:18px!important;border-radius:12px!important;padding:0 10px!important}.markerLoopButton,.markersInlineBackButton{height:46px!important;min-height:46px!important}.markerOpenYellowButton,.tabRow .markerOpenYellowButton,.tabRow .markersNavButtonHeader{background:linear-gradient(180deg,#facc15 0%,#d97706 100%)!important;border-color:#fde047!important;color:#111827!important;box-shadow:0 0 0 1px rgba(250,204,21,.35),0 0 12px rgba(250,204,21,.22)!important}.tabRow .headerNavButtons{width:92px!important}.tabRow .markersNavButtonHeader{flex:0 0 92px!important;width:92px!important;min-width:92px!important}.tabRow{padding-right:96px!important}.contentPanel .sectionLabel,.controlsStickyPanel .sectionLabelSticky{display:none!important}@media(max-width:380px){.controlsStickyPanel .controlsRowMarkers{gap:7px!important}.controlsStickyPanel .controlsRowMarkers>*{height:44px!important;min-height:44px!important;font-size:17px!important}.tabRow .headerNavButtons{width:84px!important}.tabRow .markersNavButtonHeader{flex-basis:84px!important;width:84px!important;min-width:84px!important}.tabRow{padding-right:88px!important}}/* v121 - ajustes finos Diretor: Play padronizado e contorno da aba Músicas */.controlsStickyPanel .controlsRowRegions.controlsRowEqual {  display: grid !important;  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr) !important;  gap: 8px !important;  width: 100% !important;  max-width: 100% !important;  justify-content: stretch !important;}.controlsStickyPanel .controlsRowRegions.controlsRowEqual > * {  height: 46px !important;  min-height: 46px !important;  max-height: 46px !important;  padding: 0 10px !important;  border-radius: 12px !important;  font-size: 18px !important;  line-height: 1 !important;  box-sizing: border-box !important;}.regionsTopLabel {  display: flex !important;  align-items: center !important;  min-height: 42px !important;  width: 100% !important;  min-width: 0 !important;  padding: 8px 12px !important;  border-radius: 10px !important;  border: 1px solid #374151 !important;  background: rgba(15, 23, 42, 0.9) !important;  color: #f8fafc !important;  font-weight: 900 !important;  box-sizing: border-box !important;  white-space: nowrap !important;  overflow: hidden !important;  text-overflow: ellipsis !important;}.app[data-theme="light"] .regionsTopLabel {  background: #ffffff !important;  border-color: #cbd5e1 !important;  color: #0f172a !important;}@media(max-width:380px){  .controlsStickyPanel .controlsRowRegions.controlsRowEqual > * {    height: 44px !important;    min-height: 44px !important;    max-height: 44px !important;    font-size: 17px !important;  }}.app .controlsStickyPanel .controlsRowRegions.controlsRowEqual > button[data-action="play"]{width:100%!important;font-size:15px!important;letter-spacing:0!important;padding:0 6px!important;justify-self:stretch!important;}.settingsActionPremix{background:#1f1637!important;border-color:#8b5cf6!important;color:#ddd6fe!important}.settingsActionPremixGlobal{background:#241b09!important;border-color:#f59e0b!important;color:#fde68a!important}.premixTopControls{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:10px}.premixTopControls button{height:42px;border-radius:12px;font-weight:900}.premixPlayButton{width:100%!important}.premixLockMessage{margin:-2px 0 10px;padding:10px;border:1px solid rgba(239,68,68,.65);border-radius:10px;background:rgba(127,29,29,.45);color:#fecaca;font-weight:900;text-align:center}.premixMixerRowDisabled{opacity:.58}.premixModalBoxFull,.mixerModalBoxFull{padding:14px!important}.premixRowsBoxFull{max-height:none!important}.premixVolumeModalBoxFull{padding:16px!important}.mixerModalBoxFull .mixerRowsBox{max-height:none!important}.premixSongStatus{display:inline-flex;align-items:center;justify-content:center;min-width:42px;height:24px;border-radius:999px;margin-left:8px;font-weight:900;font-size:12px;border:1px solid #475569}.premixSongStatusOn{background:#14532d;color:#bbf7d0;border-color:#22c55e}.premixSongStatusOff{background:#3f1d1d;color:#fecaca;border-color:#ef4444}.premixMixerRow{cursor:pointer}.premixVolumeOverlay{background:rgba(0,0,0,.56)}.premixBlockRow{justify-content:center!important;border-color:rgba(250,204,21,.45)!important;background:rgba(250,204,21,.10)!important;pointer-events:none!important}.premixBlockRow .songRowLabel{width:100%;text-align:center;font-weight:900;letter-spacing:.08em;color:var(--premix-row-color,#facc15)!important}.mixerCloseBtn{touch-action:manipulation!important;pointer-events:auto!important;min-width:86px!important;min-height:38px!important;position:relative!important;z-index:5!important}.app .item.playing{background:#b91c1c!important;border-color:#ef4444!important;box-shadow:inset 0 0 0 1px rgba(248,113,113,.36)!important}.app .item.playing.selectedBlue,.app .item.playing.selectedPink,.app .item.playing.queuedYellow{background:#b91c1c!important}.app .item.playing .rowLabelText,.app .item.playing .timeText,.app .item.playing .playingText,.app .item.playing .playingTimeText{color:#fff!important;font-weight:900!important}.hashChildItem{overflow:hidden;will-change:transform,opacity,max-height}.hashChildExpandIn{animation:vshookHashDrawerOpen .24s ease-out both}.hashChildCollapseOut{animation:vshookHashDrawerClose .20s ease-in both}@keyframes vshookHashDrawerOpen{0%{opacity:0;max-height:0;transform:translateY(-8px) scaleY(.86)}100%{opacity:1;max-height:64px;transform:translateY(0) scaleY(1)}}@keyframes vshookHashDrawerClose{0%{opacity:1;max-height:64px;transform:translateY(0) scaleY(1)}100%{opacity:0;max-height:0;transform:translateY(-8px) scaleY(.86)}}.vshookMarkerCancelOverlay{position:fixed!important;left:50%!important;bottom:calc(env(safe-area-inset-bottom,0px) + 18px)!important;transform:translateX(-50%)!important;z-index:9999!important;min-width:210px!important;height:56px!important;border-radius:14px!important;border:2px solid #fecaca!important;background:linear-gradient(180deg,#ef4444 0%,#991b1b 100%)!important;color:#fff!important;font-weight:1000!important;font-size:20px!important;text-transform:uppercase!important;letter-spacing:.05em!important;box-shadow:0 0 0 1px rgba(255,255,255,.18),0 0 22px rgba(239,68,68,.36)!important;pointer-events:auto!important;touch-action:manipulation!important}.vshookMarkerCancelOverlay:active{transform:translateX(-50%) scale(.97)!important}.container.markerFooterContainer .listBox.markerListBox{padding-bottom:calc(env(safe-area-inset-bottom,0px) + 160px)!important}.container.markerFooterContainer .listBox.markerListBox{padding-bottom:12px!important;scroll-padding-bottom:12px!important}.directorMarkersCancelFooter{flex:0 0 auto;min-height:calc(env(safe-area-inset-bottom,0px) + 84px);display:flex;align-items:center;justify-content:center;padding:10px 12px calc(env(safe-area-inset-bottom,0px) + 12px);box-sizing:border-box;background:linear-gradient(180deg,rgba(6,9,15,.96) 0%,rgba(2,6,23,.99) 100%);border-top:1px solid rgba(148,163,184,.18);position:relative;z-index:9}.directorMarkersCancelFooterIdle{pointer-events:none}.directorMarkersCancelButton{min-width:220px;height:56px;border-radius:14px;border:2px solid #fecaca;background:linear-gradient(180deg,#ef4444 0%,#991b1b 100%);color:#fff;font-weight:1000;font-size:20px;text-transform:uppercase;letter-spacing:.05em;box-shadow:0 0 0 1px rgba(255,255,255,.18),0 0 22px rgba(239,68,68,.38);pointer-events:auto;touch-action:manipulation}.directorMarkersCancelButton:active{transform:scale(.97)}.appPopupMarkersPanel{bottom:calc(env(safe-area-inset-bottom,0px) + 102px)!important;z-index:7000!important}.vshookNoTextSelect,.vshookNoTextSelect *,.hashChildItem,.hashParentItem,.rowLabelText,.songRowLabel,.regionRowLabel{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;}.premixInlineSlider{width:108px;min-width:88px;accent-color:#facc15}.premixMixerRow .mixerMiniBtn{flex:0 0 auto}</style>${appPopupHtml}<div class="container ${showMarkerFooterSpace ? 'markerFooterContainer' : ''}" style="${borderStyle}"><div class="topStatusRow"><div class="${state.activeTab === 'playlist' ? 'topStatusLeftPlaylist' : 'topStatusLeft'}">${topTitleHtml}</div>${topTimerHtml}${rightToolsHtml}</div><div class="headerRow"><div class="tabRow"><button class="${state.activeTab === 'playlist' ? 'activeTab' : 'tab'}" data-action="go-playlist">REPERTÓRIOS</button><button class="${state.activeTab === 'regions' ? 'activeTab' : 'tab'}" data-action="go-regions">MÚSICAS</button><span class="headerTotal">${topTime}</span>${headerNavButtons}<span class="headerTotalSpacer"></span></div><div class="middleInfo"><span class="middleInfoText">${middleLabel}</span></div></div>${content}${showEditDoneFloating ? `<button class="floatingConfirmButton floatingConfirmRight" data-action="edit-done">OK</button>` : ''}${showDeleteConfirmFloating ? `<button class="floatingDangerButton floatingDangerLeft" data-action="delete-confirm">${state.activeTab === 'regions' ? 'SAIR' : 'DEL'}</button>` : ''}${showDeleteCancelFloating ? `<button class="floatingConfirmButton floatingConfirmRight" data-action="delete-cancel">SAIR</button>` : ''}${shouldShowClearButton ? `<button class="floatingClearButton" id="floatingClearButton" style="left:${state.clearButtonSide === 'left' ? '20px' : 'calc(100vw - 92px)'};">SAIR</button>` : ''}</div>${markerCancelGlobalButton}${lyricsPanelHtml}${createModal}${addExistingModal}${renameModal}${playlistSwitchModal}${deletePlaylistConfirmModal}${projectTabsModal}${recadosModal}${gearModal}${timerModal}${liveOffConfirmModal}${mixerModal}${mixerVolumeModal}${premixModal}${premixVolumeModal}${bpmModal}${tunerModal}</div>`
  syncChronoDisplays()
  bindEvents()
  installMarkerCancelHardDelegation()
  scheduleMarqueeBehavior()

  const visibleListAfterRender = document.querySelector('.listBox')
  if (renderScrollSnapshot && visibleListAfterRender) {
    const nextViewKey = `${state.activeTab}|${state.playlistView}|${String(state.activePlaylistId || '')}`
    if (renderScrollSnapshot.viewKey === nextViewKey) {
      const maxScroll = Math.max(0, visibleListAfterRender.scrollHeight - visibleListAfterRender.clientHeight)
      const targetScroll = Math.max(0, Math.min(maxScroll, Number(renderScrollSnapshot.scrollTop) || 0))
      listScrollSyncIgnoreUntil = Math.max(Number(listScrollSyncIgnoreUntil) || 0, Date.now() + 140)
      visibleListAfterRender.scrollTop = targetScroll
      requestAnimationFrame(() => {
        visibleListAfterRender.scrollTop = targetScroll
      })
    }
  }

  lastBridgeRenderSignature = buildBridgeRenderSignature()
}

// VS_HOOK_RENDER_SCHEDULER_B_OPTIMIZATION
// Centraliza renders do App Diretor em 1 render por frame.
// O primeiro render continua síncrono para montar a tela inicial; os próximos
// render() apenas agendam atualização no requestAnimationFrame.
let __vshookDirectorRenderFirstDone = false
let __vshookDirectorRenderQueued = false
let __vshookDirectorRenderRaf = 0
let __vshookDirectorRenderInProgress = false
let __vshookDirectorRenderLastArgs = null
function __vshookDirectorFlushRender() {
  __vshookDirectorRenderRaf = 0
  if (!__vshookDirectorRenderQueued) return
  if (__vshookDirectorRenderInProgress) {
    requestRender()
    return
  }
  const args = __vshookDirectorRenderLastArgs || []
  __vshookDirectorRenderQueued = false
  __vshookDirectorRenderLastArgs = null
  __vshookDirectorRenderInProgress = true
  try {
    return __vshookRenderImmediate.apply(this, args)
  } finally {
    __vshookDirectorRenderInProgress = false
  }
}
function requestRender() {
  __vshookDirectorRenderLastArgs = Array.prototype.slice.call(arguments)
  if (!__vshookDirectorRenderFirstDone) {
    __vshookDirectorRenderFirstDone = true
    if (__vshookDirectorRenderInProgress) {
      __vshookDirectorRenderQueued = true
      return
    }
    __vshookDirectorRenderInProgress = true
    try {
      return __vshookRenderImmediate.apply(this, __vshookDirectorRenderLastArgs || [])
    } finally {
      __vshookDirectorRenderInProgress = false
      __vshookDirectorRenderLastArgs = null
    }
  }
  __vshookDirectorRenderQueued = true
  if (__vshookDirectorRenderRaf) return
  const raf = window.requestAnimationFrame || function(cb){ return window.setTimeout(cb, 16) }
  __vshookDirectorRenderRaf = raf(__vshookDirectorFlushRender)
}
requestRender.now = function() {
  __vshookDirectorRenderQueued = false
  __vshookDirectorRenderLastArgs = Array.prototype.slice.call(arguments)
  if (__vshookDirectorRenderRaf) {
    try {
      if (window.cancelAnimationFrame) window.cancelAnimationFrame(__vshookDirectorRenderRaf)
      else clearTimeout(__vshookDirectorRenderRaf)
    } catch (_) {}
    __vshookDirectorRenderRaf = 0
  }
  if (__vshookDirectorRenderInProgress) return
  __vshookDirectorRenderInProgress = true
  try {
    return __vshookRenderImmediate.apply(this, __vshookDirectorRenderLastArgs || [])
  } finally {
    __vshookDirectorRenderInProgress = false
    __vshookDirectorRenderLastArgs = null
  }
}
function render() {
  return requestRender.apply(this, arguments)
}
render.now = requestRender.now



function updateBorderEffect() {
  normalizeRgbModeState()
  const container = document.querySelector('.container')
  if (!container) return
  const appRoot = document.querySelector('.app')
  if (state.rgbMode === 'off') {
    container.style.borderColor = 'rgba(71,85,105,0.55)'
    container.style.boxShadow = '0 0 0 1px rgba(71,85,105,0.35), inset 0 0 10px rgba(255,255,255,0.03)'
    if (appRoot) {
      appRoot.style.setProperty('--app-border-color', 'rgba(71,85,105,0.85)')
      appRoot.style.setProperty('--app-border-glow', 'rgba(71,85,105,0.35)')
    }
    return
  }
  if (state.rgbMode === 'fixed') {
    state.borderHue = RGB_FIXED_HUES[state.rgbFixedIndex] ?? 96
  }
  const hue = getBorderColorCss()
  const glow = getBorderGlowCss()
  if (appRoot) {
    appRoot.style.setProperty('--app-border-color', hue)
    appRoot.style.setProperty('--app-border-glow', glow)
  }
  container.style.borderColor = hue
  container.style.boxShadow = `0 0 0 1px ${hue}, 0 0 14px ${glow}, inset 0 0 10px rgba(255,255,255,0.03)`
}

function startApp() {
  try { state.transportProtectionEnabled = localStorage.getItem(DIRECTOR_TRANSPORT_PROTECTION_KEY) === '1' } catch (error) {}
  registerPwaServiceWorker()
  syncAppViewportHeight()
  appBootStartedAt = Date.now()
  showBootLoader()

  const handleMove = (event) => {
    if (state.dragPending) {
      const pending = state.dragPending
      if (pending.pointerId != null && event.pointerId != null && event.pointerId !== pending.pointerId) return
      const dx = Math.abs((event.clientX ?? 0) - pending.startX)
      const dy = Math.abs((event.clientY ?? 0) - pending.startY)
      if (dx >= 8 || dy >= 8) {
        beginEditDrag(pending.tabName, pending.id, event.clientX, event.clientY, pending.pointerId)
      } else {
        return
      }
    }
    if (!state.dragActive) return
    if (state.dragPointerId != null && event.pointerId != null && event.pointerId !== state.dragPointerId) return
    if (event.cancelable) event.preventDefault()
    updateEditDrag(event.clientX, event.clientY)
  }

  const handleEnd = (event) => {
    if (state.dragPending) {
      const pending = state.dragPending
      if (pending.pointerId == null || event.pointerId == null || event.pointerId === pending.pointerId) {
        state.dragPending = null
      }
    }
    if (!state.dragActive) return
    if (state.dragPointerId != null && event.pointerId != null && event.pointerId !== state.dragPointerId) return
    endEditDrag()
  }

  window.addEventListener('pointermove', handleMove, { passive: false })
  window.addEventListener('pointerup', handleEnd)
  window.addEventListener('pointercancel', handleEnd)
  window.addEventListener('resize', () => { syncAppViewportHeight(); scheduleMarqueeBehavior() })
  window.addEventListener('orientationchange', syncAppViewportHeight)
  window.visualViewport?.addEventListener('resize', syncAppViewportHeight)
  window.visualViewport?.addEventListener('scroll', syncAppViewportHeight)

  // VSHOOK_NO_TEXT_SELECT_DIRECTOR_PATCH
  document.addEventListener('contextmenu', (event) => {
    if (event.target && event.target.closest && event.target.closest('.item,.rowLabelText,.songRowLabel,.regionRowLabel')) {
      event.preventDefault()
      event.stopPropagation()
    }
  }, { capture: true })
  // VSHOOK_NO_TEXT_SELECT_SELECTSTART_PATCH
  ;['selectstart', 'dragstart'].forEach((eventName) => {
    document.addEventListener(eventName, (event) => {
      if (event.target && event.target.closest && event.target.closest('.item,.rowLabelText,.songRowLabel,.regionRowLabel,.markerRowLabel')) {
        event.preventDefault()
        event.stopPropagation()
      }
    }, { capture: true })
  })
  setupWakeLock()
  installDirectorInputRenderGuard()
  try { render() } catch (error) { console.error('render start error', error) }
  updateBorderEffect()
  pollBridge()
  clearInterval(borderTimer)
  clearInterval(bridgeTimer)
  clearInterval(chronoRenderTimer)
  clearInterval(playbackRenderTimer)
  refreshChronoRenderLoop()
  borderTimer = setInterval(() => {
    if (state.rgbMode === 'auto') {
      state.borderHue = (state.borderHue + 6) % 360
      updateBorderEffect()
    }
  }, 180)
  bridgeTimer = setInterval(pollBridge, 750)
  playbackRenderTimer = setInterval(() => {
    try {
      syncDirectorChronoDom()
      if (state.showMixerVolumeModal) {
        if (!state.mixerVolumeInteracting && state.mixerSelectedId) {
          syncMixerVolumeModalUi(state.mixerVolumeView, state.mixerSelectedId)
        }
        return
      }
      if (state.showMixerModal || state.showBpmModal || state.showTunerModal || state.showGearModal || state.showTimerModal) {
        return
      }
      applyDirectorLocalStopIfMusicEnded()
      if (!state.playingId) return
      syncDirectorPlaybackDom()
    } catch (error) {
      console.error('playback render error', error)
    }
  }, 100)
  window.setTimeout(() => {
    if (appLoadingVisible) {
      hideBootLoader(true)
    }
  }, 4500)
}


setInterval(() => {
  try { syncDirectorRecadosDom() } catch (error) {}
}, 250)

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startApp, { once: true })
} else {
  startApp()
}


function syncDirectorChronoDom() {
  const timerText = formatChronoTime(getTimerElapsedSec())
  document.querySelectorAll('[data-chrono-display]').forEach((node) => {
    if (node.textContent !== timerText) node.textContent = timerText
  })
}

function syncDirectorPlaybackDom() {
  const appEl = document.getElementById('app')
  if (!appEl) return
  const keepFocused = document.activeElement
  if (!state.playingId) return
  if (Date.now() - Number(lastUserScrollAt || 0) < 850) return
  const shouldSkip = state.showMixerModal || state.showMixerVolumeModal || state.showBpmModal || state.showTunerModal || state.showGearModal || state.showTimerModal || state.showPlaylistSwitchModal || state.showCreatePlaylistModal || state.showAddExistingModal || state.showRenameModal || state.editMode || state.deleteMode || state.dragActive || state.dragPending
  if (shouldSkip) return
  const previousScrollTop = []
  document.querySelectorAll('.listBox').forEach((el, idx) => {
    previousScrollTop[idx] = el.scrollTop
  })
  const previousSignature = lastRenderSignature
  lastRenderSignature = ''
  render()
  lastRenderSignature = buildBridgeRenderSignature()
  document.querySelectorAll('.listBox').forEach((el, idx) => {
    if (typeof previousScrollTop[idx] === 'number') el.scrollTop = previousScrollTop[idx]
  })
  if (keepFocused && typeof keepFocused.focus === 'function' && document.contains(keepFocused)) {
    try { keepFocused.focus({ preventScroll: true }) } catch (error) {}
  }
}

/* VSHOOK_PATCH_LYRICS_SMART_SCROLL_V138 */

// VSHOOK_DIRECTOR_2036_STOP_POPUP_FIX


/* VS Hook Native Bridge FIX3 - Premix por Item definitivo: sem Global, sem ON/OFF, sem grupos. */
(function(){
  try {
    window.VSHOOK_PREMIX_ITEM_ONLY_FIX3 = true;
    if (typeof PREMIX_GLOBAL_ID !== 'undefined') {}
  } catch (e) {}
})();

function isPremixGlobalMode() { return false }
function getPremixEntityId() { return String(state.premixSelectedSongId || '') }
function getPremixOnState() { return true }
function getPremixOnLabel() { return 'PREMIX' }
function canEditCurrentPremix(showMessage = true) { return true }
function canOpenPremixSong(songId, showMessage = true) { return !!String(songId || '') }
function getPremixItemsForView(view = 'tracks') {
  return (Array.isArray(state.premixTracks) ? state.premixTracks : []).filter(Boolean)
}
function getPremixTracks() { return getPremixItemsForView('tracks') }
function openPremixGlobalModal(event) { event?.preventDefault?.(); event?.stopPropagation?.(); return openPremixFromMenu(event) }
function bindPremixGlobalMenuButton(el) { if (el) el.style.display = 'none' }
function handlePremixOnOffToggle(event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }
function handlePremixGlobalReset(event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }
function setPremixTrackView(view) { state.premixTrackView = 'tracks'; return true }

function openPremixModal() {
  state.settingsMenuOpen = false
  state.showGearModal = false
  state.showMixerModal = false
  state.showMixerVolumeModal = false
  state.showPremixVolumeModal = false
  state.showBpmModal = false
  state.showTunerModal = false
  state.showPremixModal = true
  state.premixIsGlobal = false
  state.premixView = 'songs'
  state.premixTrackView = 'tracks'
  state.premixSelectedTrackId = null
  state.premixTracks = []
  state.premixGroups = []
  armOverlayCloseGuard?.(900)
  render()
  postCommand('premix_item_open', { requestFull: '1', page: getCurrentPcPageName() })
  fastPollBridge?.(12)
}

function selectPremixSong(songId) {
  const id = String(songId || '')
  if (!id) return
  const song = getPremixSongs().find((entry) => vshookPremixItemSongId(entry) === id)
  if (!isPremixSelectableSong(song)) return
  state.premixIsGlobal = false
  state.premixSelectedSongId = id
  state.selectedRegionId = id
  state.selectedRegionIds = [id]
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  state.premixSelectedTrackId = null
  state.showPremixVolumeModal = false
  state.premixView = 'tracks'
  state.premixTrackView = 'tracks'
  state.premixTracks = []
  state.premixGroups = []
  render()
  postCommand('premix_item_focus_song', { id, songId: id, selectedRegionId: id, page: getCurrentPcPageName() })
  fastPollBridge?.(16)
}

function backPremixSongList() {
  state.premixView = 'songs'
  state.showPremixVolumeModal = false
  state.premixSelectedTrackId = null
  render()
  postCommand('premix_item_open', { requestFull: '1', page: getCurrentPcPageName() })
  fastPollBridge?.(8)
}

function findPremixTrack(id, view = 'tracks') {
  const wanted = String(id || '')
  if (!wanted) return null
  return getPremixItemsForView('tracks').find((entry) => String(entry?.id || entry?.guid || entry?.itemId || '') === wanted) || null
}

function setPremixTrackLocalState(id, patch = {}, view = 'tracks') {
  const wanted = String(id || '')
  if (!wanted) return
  const applyPatch = (list) => (Array.isArray(list) ? list : []).map((item) => {
    const key = String(item?.id || item?.guid || item?.itemId || '')
    return key === wanted ? { ...item, ...patch } : item
  })
  state.premixTracks = applyPatch(state.premixTracks)
}

function handlePremixTrackToggle(event, action, trackId, view = 'tracks') {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  const item = findPremixTrack(id, 'tracks')
  const normalizedAction = (action === 'phase' || action === 'fx') ? 'fx' : 'mute'
  if (item) {
    if (normalizedAction === 'mute') setPremixTrackLocalState(id, { mute: !item.mute, muted: !item.mute }, 'tracks')
    if (normalizedAction === 'fx') setPremixTrackLocalState(id, { fxEnabled: !item.fxEnabled, fxOn: !item.fxEnabled }, 'tracks')
  }
  render()
  postCommand(normalizedAction === 'fx' ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute', {
    id: songId, songId, selectedRegionId: songId, targetId: id, itemId: id, trackId: id, guid: id, page: getCurrentPcPageName()
  })
  fastPollBridge?.(10)
}

function handlePremixVolumeInput(view, trackId, value) {
  const id = String(trackId || '')
  const songId = getPremixEntityId()
  if (!id || !songId) return
  const ratio = normalizeMixerRatio(value, 0.5)
  setPremixTrackLocalState(id, { volumeRatio: ratio, liveVolumeRatio: ratio }, 'tracks')
  extendMixerVolumeInteraction?.(320)
  postCommand('premix_item_set_volume', {
    id: songId, songId, selectedRegionId: songId, targetId: id, itemId: id, trackId: id, guid: id, ratio, volumeRatio: ratio, page: getCurrentPcPageName()
  })
}

function handlePremixVolumeReset(event, view, trackId) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  handlePremixVolumeInput('tracks', trackId, getMixerZeroDbRatio())
  render()
}
function openPremixVolumeModal(view, id) { return false }
function closePremixVolumeModal(force = false) { state.showPremixVolumeModal = false; state.premixSelectedTrackId = null; render() }
function renderPremixVolumeModal() { return '' }
function handlePremixRowOpenFromElement(el, event) { event?.preventDefault?.(); event?.stopPropagation?.(); return false }

function renderPremixTrackRows() {
  const tracks = getPremixItemsForView('tracks')
  if (!tracks.length) return '<div class="emptyBox">SEM ITENS NESSA MÚSICA</div>'
  return tracks.map((item, index) => {
    const idRaw = String(item?.id || item?.guid || item?.itemId || '')
    const id = escapeHtml(idRaw)
    const indexText = String(item?.index ?? (index + 1)).padStart(2, '0')
    const rawName = item?.name || item?.label || item?.trackName || item?.itemName || item?.takeName || `ITEM ${indexText}`
    const name = buildMarqueeText(rawName, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee')
    const ratio = normalizeMixerRatio(item?.volumeRatio ?? item?.liveVolumeRatio, 0.5)
    const db = escapeHtml(formatMixerDbLabel(item?.db ?? 0, ratio, item?.displayScale))
    const isMuted = !!(item?.mute || item?.muted)
    const muteClass = isMuted ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn'
    const hasFx = !!(item?.hasFx || Number(item?.fxCount || 0) > 0)
    const fxOn = item?.fxEnabled !== false && item?.fxOn !== false
    const fxClass = !hasFx ? 'mixerMiniBtn btnDisabled' : (fxOn ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn')
    const drawerStyle = item?.isDrawer || item?.is_drawer ? ' style="background:rgba(250,204,21,.92);color:#111827;border-color:#facc15"' : ''
    return `<div class="mixerRow premixMixerRow"${drawerStyle} data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">${escapeHtml(indexText)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div></div><div class="mixerRowDb">${db}</div><button class="${muteClass}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${id}">M</button><button class="${fxClass}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${id}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button><input class="premixInlineSlider" type="range" min="0" max="1" step="0.01" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${id}" /></div>`
  }).join('')
}

function renderPremixModal() {
  if (!state.showPremixModal) return ''
  const isTracks = state.premixView === 'tracks'
  const selectedSong = getPremixSongs().find((song) => vshookPremixItemSongId(song) === String(state.premixSelectedSongId || ''))
  const title = isTracks && selectedSong ? upperText(selectedSong.name || selectedSong.label || 'PREMIX') : 'PREMIX'
  const titleHtml = buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee')
  const closeOrBack = isTracks ? `<button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button>` : `<button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button>`
  const content = isTracks
    ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px"><div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div>${closeOrBack}</div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">ITENS</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
    : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div>${closeOrBack}</div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div></div><div class="mixerRowsBox premixSongListBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`
  return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`
}


function vshookPremixIsParentSong(song) {
  if (!song) return false
  const type = String(song?.type || song?.itemType || song?.kind || '').toLowerCase()
  const role = String(song?.familyRole || song?.role || '').toLowerCase()
  const name = String(song?.name || song?.label || song?.title || '').trim()
  return song?.isHashParent === true || song?.hashParent === true || role === 'parent' || type === 'hash_parent' || type === 'parent' || name.startsWith('--')
}
function getPremixSongs() {
  const source = Array.isArray(state.premixSongs) && state.premixSongs.length ? state.premixSongs : state.regions
  if (!Array.isArray(source)) return []
  return source.filter((song) => !detectBlockItem(song) && !vshookPremixIsParentSong(song))
}


// VS Hook Native Bridge FIX5 - Diretor: aba Músicas sempre em ordem alfabética.
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX5_ALPHA_MUSICAS__) return;
  window.__VSHOOK_DIRECTOR_FIX5_ALPHA_MUSICAS__ = true;
  const collator = new Intl.Collator('pt-BR', { sensitivity: 'base', numeric: true });
  function cleanNameForSort(item) {
    return String(item?.name || item?.label || item?.title || '').replace(/^\s*--\s*/, '').trim();
  }
  function sortMusicRootItemsAlpha(list) {
    return (Array.isArray(list) ? [...list] : []).sort((a, b) => {
      const ab = (typeof detectBlockItem === 'function' && detectBlockItem(a)) ? 1 : 0;
      const bb = (typeof detectBlockItem === 'function' && detectBlockItem(b)) ? 1 : 0;
      if (ab !== bb) return ab - bb;
      const c = collator.compare(cleanNameForSort(a), cleanNameForSort(b));
      if (c !== 0) return c;
      return (Number(a?.startPos ?? a?.start_pos ?? 0) || 0) - (Number(b?.startPos ?? b?.start_pos ?? 0) || 0);
    });
  }
  if (typeof vshookRootFamilyItems === 'function') {
    const previousRootFamilyItems = vshookRootFamilyItems;
    vshookRootFamilyItems = function(items) {
      const roots = previousRootFamilyItems(items);
      if (state && state.activeTab === 'regions') return sortMusicRootItemsAlpha(roots);
      return roots;
    };
  }
})();


// VS_HOOK_NATIVE_FIX6_APP_PATCH: premix/mixer vêm da extensão; cronômetro local otimista; repertório não volta para primeiro durante hold.


/* VS_HOOK_NATIVE_FIX8: Premix por item robusto + cronômetro otimista + animação Markers/Letras. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX8_DIRECTOR__) return;
  window.__VSHOOK_NATIVE_FIX8_DIRECTOR__ = true;

  function normalizePremixMap(map) {
    if (!map || typeof map !== 'object' || Array.isArray(map)) return {};
    return map;
  }

  function getPremixTrackMap() {
    return normalizePremixMap(state.premixTracksBySongId || state.premixTracksByRegionId || state.premixItemsBySongId || {});
  }

  function getMappedPremixTracks(songId) {
    const key = String(songId || state.premixSelectedSongId || '');
    if (!key) return [];
    const map = getPremixTrackMap();
    const list = map[key] || map[String(Number(key))] || [];
    return Array.isArray(list) ? list.filter(Boolean).map((item) => normalizePremixTrackItem(item, 'tracks')) : [];
  }

  const previousSyncFromBridgeFix8 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (previousSyncFromBridgeFix8) {
    syncFromBridge = function(data) {
      const optimistic = window.__VSHOOK_TIMER_OPTIMISTIC_FIX8__ || null;
      previousSyncFromBridgeFix8(data);

      if (data && data.premix && typeof data.premix === 'object') {
        const map = data.premix.tracksBySongId || data.premix.tracksByRegionId || data.premix.itemsBySongId || data.premix.itemTracksBySongId || null;
        if (map && typeof map === 'object' && !Array.isArray(map)) {
          state.premixTracksBySongId = map;
          state.premixTracksByRegionId = map;
          if (state.showPremixModal && state.premixView === 'tracks' && state.premixSelectedSongId) {
            const mapped = getMappedPremixTracks(state.premixSelectedSongId);
            if (mapped.length) state.premixTracks = mapped;
          }
        }
      }

      if (optimistic && Date.now() < Number(optimistic.until || 0)) {
        if (optimistic.desiredRunning) {
          state.timerRunning = true;
          state.timerStartedAt = Number(optimistic.startedAt) || Date.now();
          state.timerStartedAtMs = state.timerStartedAt;
          state.timerAccumulatedSec = Number(optimistic.accumulatedSec) || 0;
          state.timerMode = optimistic.mode || state.timerMode || 'progressive';
          state.timerTargetSec = Number(optimistic.targetSec ?? state.timerTargetSec ?? 0) || 0;
        } else {
          state.timerRunning = false;
          state.timerStartedAt = 0;
          state.timerStartedAtMs = 0;
        }
        try { refreshChronoRenderLoop(); syncChronoDisplays(); } catch (error) {}
      }
    };
  }

  if (typeof confirmTimerModal === 'function') {
    const previousConfirmTimerModalFix8 = confirmTimerModal;
    confirmTimerModal = function() {
      const wasRunning = !!state.timerRunning;
      const beforeElapsed = typeof getTimerElapsedSec === 'function' ? getTimerElapsedSec() : (Number(state.timerAccumulatedSec) || 0);
      const targetSec = Number(state.timerTargetSec) || 0;
      const mode = state.timerMode || 'progressive';
      previousConfirmTimerModalFix8();
      const now = Date.now();
      window.__VSHOOK_TIMER_OPTIMISTIC_FIX8__ = {
        desiredRunning: !wasRunning,
        startedAt: !wasRunning ? now : 0,
        accumulatedSec: !wasRunning ? beforeElapsed : 0,
        mode,
        targetSec,
        until: now + 3500,
      };
      if (!wasRunning) {
        state.timerRunning = true;
        state.timerStartedAt = now;
        state.timerStartedAtMs = now;
        state.timerAccumulatedSec = beforeElapsed;
      } else {
        state.timerRunning = false;
        state.timerStartedAt = 0;
        state.timerStartedAtMs = 0;
      }
      try { refreshChronoRenderLoop(); syncChronoDisplays(); render(); } catch (error) {}
    };
  }

  getPremixItemsForView = function(view = 'tracks') {
    const mapped = getMappedPremixTracks(state.premixSelectedSongId);
    if (mapped.length) return mapped;
    return (Array.isArray(state.premixTracks) ? state.premixTracks : []).filter(Boolean).map((item) => normalizePremixTrackItem(item, 'tracks'));
  };

  selectPremixSong = function(songId) {
    const id = String(songId || '');
    if (!id) return;
    const song = getPremixSongs().find((entry) => vshookPremixItemSongId(entry) === id || String(entry?.id || '') === id || String(entry?.sourceNumber || entry?.source_number || '') === id);
    if (!isPremixSelectableSong(song)) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = id;
    state.selectedRegionId = id;
    state.selectedRegionIds = [id];
    state.selectedPlaylistSongId = null;
    state.selectedPlaylistSongIds = [];
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    const mapped = getMappedPremixTracks(id);
    state.premixTracks = mapped.length ? mapped : [];
    state.premixGroups = [];
    render();
    postCommand('premix_item_focus_song', { id, songId: id, selectedRegionId: id, page: getCurrentPcPageName() });
    fastPollBridge?.(20);
  };

  backPremixSongList = function() {
    state.premixView = 'songs';
    state.showPremixVolumeModal = false;
    state.premixSelectedTrackId = null;
    render();
    postCommand('premix_item_open', { requestFull: '1', page: getCurrentPcPageName() });
    fastPollBridge?.(10);
  };

  function installDirectorPanelAnimationFix8() {
    if (document.getElementById('vshook-native-fix8-panel-animation')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix8-panel-animation';
    style.textContent = `
      @keyframes vshookDirectorLyricsFromLeftFix8{0%{opacity:.1;transform:translateX(-26px)}100%{opacity:1;transform:translateX(0)}}
      @keyframes vshookDirectorMarkersFromRightFix8{0%{opacity:.1;transform:translateX(26px)}100%{opacity:1;transform:translateX(0)}}
      .lyricsScreen{animation:vshookDirectorLyricsFromLeftFix8 .24s cubic-bezier(.2,.7,.2,1) both!important;will-change:transform,opacity!important}
      .markerPanelSlideIn{animation:vshookDirectorMarkersFromRightFix8 .24s cubic-bezier(.2,.7,.2,1) both!important;will-change:transform,opacity!important}
    `;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installDirectorPanelAnimationFix8);
  else installDirectorPanelAnimationFix8();
})();


/* VS_HOOK_NATIVE_FIX9: comandos rápidos, Premix selecionado, timer sem fechar teclado e animação Markers reversa. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX9_DIRECTOR__) return;
  window.__VSHOOK_NATIVE_FIX9_DIRECTOR__ = true;

  const originalShouldPauseBridgeRenderFix9 = typeof shouldPauseBridgeRender === 'function' ? shouldPauseBridgeRender : null;
  if (originalShouldPauseBridgeRenderFix9) {
    shouldPauseBridgeRender = function() {
      if (state && state.showTimerModal) return true;
      return originalShouldPauseBridgeRenderFix9();
    };
  }

  const originalPollBridgeFix9 = typeof pollBridge === 'function' ? pollBridge : null;
  if (originalPollBridgeFix9) {
    pollBridge = async function() {
      const active = document.activeElement;
      const timerInputFocused = !!(state && state.showTimerModal && active && active.matches && active.matches('[data-timer-part]'));
      await originalPollBridgeFix9();
      if (timerInputFocused && document.contains(active)) {
        try { active.focus({ preventScroll: true }); } catch (error) {}
      }
    };
  }

  function normalizePremixFix9(item) {
    if (typeof normalizePremixTrackItem === 'function') return normalizePremixTrackItem(item, 'tracks');
    return item;
  }

  function currentPremixSelectedFix9() {
    return String(state?.premixSelectedSongId || '');
  }

  function premixListFromStateFix9(songId) {
    const key = String(songId || currentPremixSelectedFix9());
    const map = state?.premixTracksBySongId || state?.premixTracksByRegionId || state?.premixItemsBySongId || {};
    const fromMap = key && map && typeof map === 'object' ? (map[key] || map[String(Number(key))]) : null;
    if (Array.isArray(fromMap) && fromMap.length) return fromMap.map(normalizePremixFix9);
    if (Array.isArray(state?.premixTracks) && state.premixTracks.length) return state.premixTracks.map(normalizePremixFix9);
    return [];
  }

  const originalSyncFromBridgeFix9 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (originalSyncFromBridgeFix9) {
    syncFromBridge = function(data) {
      const selectedBefore = currentPremixSelectedFix9();
      const keepPremixScreen = !!(state && state.showPremixModal && state.premixView === 'tracks' && selectedBefore);
      originalSyncFromBridgeFix9(data);

      if (data && data.premix && typeof data.premix === 'object') {
        const selectedFromBridge = data.premix.selectedSongId != null ? String(data.premix.selectedSongId) : '';
        const tracks = Array.isArray(data.premix.tracks) ? data.premix.tracks.map(normalizePremixFix9) : [];
        const map = data.premix.tracksBySongId || data.premix.tracksByRegionId || data.premix.itemsBySongId || null;
        if (map && typeof map === 'object' && !Array.isArray(map)) {
          state.premixTracksBySongId = map;
          state.premixTracksByRegionId = map;
        }
        if (keepPremixScreen) {
          state.premixSelectedSongId = selectedBefore;
          const mapped = premixListFromStateFix9(selectedBefore);
          if (mapped.length) state.premixTracks = mapped;
          else if (selectedFromBridge === selectedBefore && tracks.length) state.premixTracks = tracks;
        } else if (tracks.length) {
          state.premixTracks = tracks;
        }
      }
    };
  }

  getPremixItemsForView = function(view = 'tracks') {
    return premixListFromStateFix9(state?.premixSelectedSongId);
  };
  getPremixTracks = function() { return getPremixItemsForView('tracks'); };

  selectPremixSong = function(songId) {
    const id = String(songId || '');
    if (!id) return;
    const song = getPremixSongs().find((entry) => {
      const sid = typeof vshookPremixItemSongId === 'function' ? vshookPremixItemSongId(entry) : String(entry?.id || '');
      return sid === id || String(entry?.id || '') === id || String(entry?.sourceNumber || entry?.source_number || '') === id;
    });
    if (typeof isPremixSelectableSong === 'function' && !isPremixSelectableSong(song)) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = id;
    state.selectedRegionId = id;
    state.selectedRegionIds = [id];
    state.selectedPlaylistSongId = null;
    state.selectedPlaylistSongIds = [];
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixGroups = [];
    state.premixTracks = premixListFromStateFix9(id);
    render();
    postCommand('premix_item_focus_song', { id, songId: id, selectedRegionId: id, regionId: id, requestTracks: '1', page: getCurrentPcPageName() });
    fastPollBridge?.(30);
  };

  // Ao parar, zera visualmente no app também. O Lua já zera do lado dele.
  if (typeof confirmTimerModal === 'function') {
    const previousConfirmTimerModalFix9 = confirmTimerModal;
    confirmTimerModal = function() {
      const wasRunning = !!state.timerRunning;
      if (state.timerMode === 'countdown') {
        try { state.timerTargetSec = readTimerTargetSecondsFromModal(); } catch (error) {}
      }
      previousConfirmTimerModalFix9();
      if (wasRunning) {
        state.timerRunning = false;
        state.timerStartedAt = 0;
        state.timerStartedAtMs = 0;
        state.timerAccumulatedSec = 0;
        state.timerElapsedSec = 0;
        state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
        window.__VSHOOK_TIMER_OPTIMISTIC_FIX8__ = {
          desiredRunning: false,
          startedAt: 0,
          accumulatedSec: 0,
          mode: state.timerMode || 'progressive',
          targetSec: Number(state.timerTargetSec) || 0,
          until: Date.now() + 2500,
        };
        try { syncChronoDisplays(); render(); } catch (error) {}
      }
    };
  }

  function installFix9Animation() {
    if (document.getElementById('vshook-native-fix9-animation')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix9-animation';
    style.textContent = `
      @keyframes vshookDirectorLyricsInFix9{0%{opacity:.05;transform:translateX(-100%)}100%{opacity:1;transform:translateX(0)}}
      @keyframes vshookDirectorMarkersInFix9{0%{opacity:.05;transform:translateX(100%)}100%{opacity:1;transform:translateX(0)}}
      .lyricsScreen{animation:vshookDirectorLyricsInFix9 .26s cubic-bezier(.18,.78,.24,1) both!important;will-change:transform,opacity!important}
      .markerContentPanel.markerPanelSlideIn,.markerListBox.markerPanelSlideIn,.markerPanelSlideIn{animation:vshookDirectorMarkersInFix9 .26s cubic-bezier(.18,.78,.24,1) both!important;will-change:transform,opacity!important}
    `;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installFix9Animation);
  else installFix9Animation();
})();


/* VS_HOOK_NATIVE_FIX10_DIRECTOR: Premix fallback real, TP1-only lyrics, timer, markers, auth, settings. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX10_DIRECTOR__) return;
  window.__VSHOOK_NATIVE_FIX10_DIRECTOR__ = true;

  const TP_COLOR_KEY = 'vshook_tp_text_color';
  const TP_FONT_KEY = 'vshook_tp_font_family';
  const TP_COLORS = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];

  function lsGet(key, fallback) { try { return localStorage.getItem(key) || fallback; } catch(e) { return fallback; } }
  function lsSet(key, value) { try { localStorage.setItem(key, String(value || '')); } catch(e) {} }
  function getTpTextColorFix10() { return lsGet(TP_COLOR_KEY, '#f8fafc'); }
  function getTpFontFix10() { return lsGet(TP_FONT_KEY, TP_FONTS[0]); }
  function setTpTextColorFix10(value) { lsSet(TP_COLOR_KEY, value); render?.(); }
  function setTpFontFix10(value) { lsSet(TP_FONT_KEY, value); render?.(); }
  window.vshookSetTpTextColorFix10 = setTpTextColorFix10;
  window.vshookSetTpFontFix10 = setTpFontFix10;

  // A primeira entrada do Diretor deve cair em Repertórios.
  try {
    if (state) {
      state.activeTab = 'playlist';
      state.playlistView = 'songs';
      state.localMarkersMode = false;
      state.pendingTabCommand = 'playlist';
      state.forcePlaylistUntil = Date.now() + 4200;
    }
  } catch(e) {}

  function mediaAllowsTextFix10(mediaType) {
    const t = String(mediaType || 'text').toLowerCase().replace(/[- ]/g, '_');
    return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain';
  }

  function syncTp1FromBridgeFix10(data) {
    if (!data || typeof data !== 'object' || !state) return;
    const mediaType = String(data.tp1MediaType || data.telepromptTp1MediaType || data?.tp1?.mediaType || data?.tp1?.type || state.tp1MediaType || 'text').toLowerCase();
    state.tp1MediaType = mediaType;
    state.tp1SongName = String(data.tp1SongName || data.telepromptTp1SongName || data.tp1Song || data?.tp1?.songName || data?.tp1?.musicName || state.tp1SongName || '');
    state.tp1LyricsText = mediaAllowsTextFix10(mediaType) ? String(data.tp1LyricsText || data.tp1Lyrics || data.telepromptTp1Lyrics || data?.tp1?.lyricsText || data?.tp1?.lyrics || data?.tp1?.text || '') : '';
    state.tp1UpdatedAt = data.tp1UpdatedAt || data?.tp1?.updatedAt || state.tp1UpdatedAt || null;
  }

  function getTp1TitleFix10() {
    const fromTp = String(state?.tp1SongName || '').trim();
    if (fromTp) return fromTp;
    const fromState = String(state?.currentSongName || state?.playingSongName || state?.songName || state?.musicName || '').trim();
    if (fromState) return fromState;
    const song = typeof getCurrentLyricsSong === 'function' ? getCurrentLyricsSong() : null;
    return String(song?.name || song?.label || 'TELEPROMPT 1');
  }

  function getTp1TextFix10() {
    const media = String(state?.tp1MediaType || 'text');
    if (!mediaAllowsTextFix10(media)) return '';
    return String(state?.tp1LyricsText || '').trim();
  }

  const originalSyncFromBridgeFix10 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (originalSyncFromBridgeFix10) {
    syncFromBridge = function(data) {
      const timerHold = window.__vshookTimerLocalHoldFix10;
      const timerHoldActive = !!(timerHold && Date.now() < Number(timerHold.until || 0));
      const savedTimer = timerHoldActive ? {
        running: !!state.timerRunning,
        startedAt: Number(state.timerStartedAt) || 0,
        startedAtMs: Number(state.timerStartedAtMs) || 0,
        accumulatedSec: Number(state.timerAccumulatedSec) || 0,
        displaySec: Number(state.timerDisplaySec) || 0,
        mode: state.timerMode,
        targetSec: Number(state.timerTargetSec) || 0,
      } : null;

      syncTp1FromBridgeFix10(data);
      originalSyncFromBridgeFix10(data);
      syncTp1FromBridgeFix10(data);

      if (timerHoldActive && savedTimer) {
        state.timerRunning = savedTimer.running;
        state.timerStartedAt = savedTimer.startedAt;
        state.timerStartedAtMs = savedTimer.startedAtMs;
        state.timerAccumulatedSec = savedTimer.accumulatedSec;
        state.timerDisplaySec = savedTimer.displaySec;
        state.timerMode = savedTimer.mode || state.timerMode;
        state.timerTargetSec = savedTimer.targetSec;
      }

      if (data && data.forceDirectorLogout === true) {
        try { clearAccessSession?.(); } catch(e) {}
        try { localStorage.removeItem('vshook_access_session'); } catch(e) {}
      }
    };
  }

  // Evita que o app volte para a senha durante Play se a sessão local já está autenticada.
  if (typeof needsAuthGate === 'function') {
    const previousNeedsAuthGateFix10 = needsAuthGate;
    needsAuthGate = function() {
      try {
        const saved = getSavedAccessSession?.() || localStorage.getItem('vshook_access_session') || '';
        if (saved && state && state.authHash && saved === state.authHash && !bridgeLooksOffline?.()) {
          state.authAuthenticated = true;
          state.authError = '';
          return false;
        }
      } catch(e) {}
      return previousNeedsAuthGateFix10();
    };
  }

  // Markers: se a extensão entregar markers globais sem songId, filtra por posição dentro da música atual.
  if (typeof currentMarkers === 'function') {
    const previousCurrentMarkersFix10 = currentMarkers;
    currentMarkers = function() {
      let list = [];
      try { list = previousCurrentMarkersFix10() || []; } catch(e) { list = []; }
      if (Array.isArray(list) && list.length) return list;

      let sourceSongId = null;
      if (state.playingId) sourceSongId = String(state.playingId);
      else if (state.selectedPlaylistSongId) sourceSongId = String(state.selectedPlaylistSongId);
      else if (state.selectedRegionId) sourceSongId = String(state.selectedRegionId);
      if (!sourceSongId) return [];

      const sourceItem = typeof findSongByIdEverywhere === 'function' ? findSongByIdEverywhere(sourceSongId) : null;
      if (!sourceItem || (typeof detectBlockItem === 'function' && detectBlockItem(sourceItem))) return [];
      const start = Number(sourceItem.startPos ?? sourceItem.start_pos ?? sourceItem.pos ?? 0);
      const end = Number(sourceItem.endPos ?? sourceItem.end_pos ?? sourceItem.end ?? 0);
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return [];

      const out = [];
      const seen = new Set();
      const markers = Array.isArray(state.markers) ? state.markers : [];
      markers.forEach((marker, index) => {
        const abs = Number(marker.absoluteSec ?? marker.pos ?? marker.position ?? marker.startPos ?? marker.time ?? marker.timeSec);
        if (!Number.isFinite(abs) || abs < start - 0.0005 || abs >= end - 0.0005) return;
        const rawName = String(marker.rawName || marker.name || marker.label || `Marker ${index + 1}`);
        if (!rawName || rawName.startsWith('!')) return;
        const id = String(marker.id || `m${marker.number || index + 1}`);
        const key = `${id}|${abs}`;
        if (seen.has(key)) return;
        seen.add(key);
        out.push({
          ...marker,
          id,
          songId: sourceSongId,
          regionId: sourceSongId,
          name: rawName,
          label: rawName,
          rawName,
          absoluteSec: abs,
          pos: abs,
          timeSec: Math.max(0, abs - start),
          relativeSec: Math.max(0, abs - start),
          index: out.length + 1,
        });
      });
      out.sort((a,b) => (Number(a.timeSec)||0) - (Number(b.timeSec)||0));
      return out;
    };
  }

  // Premix: nunca deixa vazio. Se a extensão ainda não respondeu com itens, usa as pistas do Mixer como linhas de Premix.
  function premixSongKeyFix10(songId) { return String(songId || state?.premixSelectedSongId || ''); }
  function normalizePremixRowFix10(item, view = 'tracks') {
    const row = typeof normalizePremixTrackItem === 'function' ? normalizePremixTrackItem(item, view) : { ...item };
    const id = String(row.itemId || row.id || row.guid || item?.itemId || item?.id || item?.guid || '');
    row.id = id;
    row.guid = String(row.guid || id);
    row.itemId = String(row.itemId || id);
    row.trackId = String(row.trackId || item?.trackId || item?.trackGuid || item?.guid || id);
    row.name = String(row.name || row.trackName || item?.trackName || item?.name || 'PISTA');
    row.label = String(row.label || row.name);
    row.view = 'tracks';
    return row;
  }
  function premixRowsFromMapFix10(songId) {
    const key = premixSongKeyFix10(songId);
    const maps = [state?.premixTracksBySongId, state?.premixTracksByRegionId, state?.premixItemsBySongId, state?.premixItemsByRegionId];
    for (const map of maps) {
      if (!map || typeof map !== 'object' || Array.isArray(map)) continue;
      const value = map[key] || map[String(Number(key))];
      if (Array.isArray(value) && value.length) return value.map((x) => normalizePremixRowFix10(x, 'tracks'));
    }
    return [];
  }
  function getPremixRowsFix10(songId) {
    const mapped = premixRowsFromMapFix10(songId);
    if (mapped.length) return mapped;
    if (Array.isArray(state?.premixTracks) && state.premixTracks.length) return state.premixTracks.map((x) => normalizePremixRowFix10(x, 'tracks'));
    if (Array.isArray(state?.mixerTracks) && state.mixerTracks.length) {
      return state.mixerTracks.map((x) => normalizePremixRowFix10({ ...x, itemId: x.id || x.guid, trackId: x.id || x.guid, name: x.name || x.trackName }, 'tracks'));
    }
    return [];
  }
  canEditCurrentPremix = function() { return true; };
  getPremixItemsForView = function() { return getPremixRowsFix10(state?.premixSelectedSongId); };
  getPremixTracks = function() { return getPremixItemsForView('tracks'); };
  findPremixTrack = function(id) {
    const wanted = String(id || '');
    return getPremixRowsFix10(state?.premixSelectedSongId).find((x) => [x.id, x.guid, x.itemId, x.trackId].map(String).includes(wanted)) || null;
  };
  if (typeof openPremixModal === 'function') {
    const previousOpenPremixModalFix10 = openPremixModal;
    openPremixModal = function() {
      previousOpenPremixModalFix10();
      postCommand('premix_item_open', { requestTracks: '1', selectedRegionId: state.premixSelectedSongId || state.selectedRegionId || state.selectedPlaylistSongId || state.playingId || '', page: getCurrentPcPageName?.() || 'playlist' });
      fastPollBridge?.(12);
    };
  }
  selectPremixSong = function(songId) {
    const id = String(songId || '');
    if (!id) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = id;
    state.premixSelectedTrackId = null;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.showPremixVolumeModal = false;
    state.premixGroups = [];
    state.premixTracks = getPremixRowsFix10(id);
    postCommand('premix_item_focus_song', { id, songId: id, selectedRegionId: id, regionId: id, requestTracks: '1', page: getCurrentPcPageName?.() || 'playlist' });
    fastPollBridge?.(18);
    render?.();
  };
  handlePremixTrackToggle = function(event, action, trackId) {
    event?.preventDefault?.(); event?.stopPropagation?.();
    const songId = premixSongKeyFix10();
    const item = findPremixTrack(trackId);
    const id = String(item?.itemId || item?.id || trackId || '');
    const trackGuid = String(item?.trackId || item?.trackGuid || item?.guid || id);
    if (!id) return;
    if (action === 'mute') {
      setPremixTrackLocalState?.(id, { mute: !(item?.mute || item?.muted) }, 'tracks');
      postCommand('premix_item_toggle_mute', { id: songId, songId, selectedRegionId: songId, itemId: id, targetId: id, trackId: trackGuid, guid: id, page: getCurrentPcPageName?.() || 'playlist' });
    } else if (action === 'phase' || action === 'fx') {
      postCommand('premix_item_toggle_fx', { id: songId, songId, selectedRegionId: songId, itemId: id, targetId: id, trackId: trackGuid, guid: id, page: getCurrentPcPageName?.() || 'playlist' });
    }
    fastPollBridge?.(10);
    render?.();
  };
  handlePremixVolumeInput = function(view, trackId, value) {
    const songId = premixSongKeyFix10();
    const item = findPremixTrack(trackId);
    const id = String(item?.itemId || item?.id || trackId || '');
    const trackGuid = String(item?.trackId || item?.trackGuid || item?.guid || id);
    const ratio = Math.max(0, Math.min(1, Number(value) || 0));
    if (!id) return;
    const db = typeof mixerRatioToDb === 'function' ? mixerRatioToDb(ratio) : undefined;
    setPremixTrackLocalState?.(id, { volumeRatio: ratio, liveVolumeRatio: ratio, db, displayScale: 'db' }, 'tracks');
    postCommand('premix_item_set_volume', { id: songId, songId, selectedRegionId: songId, itemId: id, targetId: id, trackId: trackGuid, guid: id, ratio, volumeRatio: ratio, page: getCurrentPcPageName?.() || 'playlist' });
    fastPollBridge?.(8);
  };

  // Timer local correto no Diretor: progressivo não usa alvo; stop zera.
  function setTimerHoldFix10(ms = 4500) {
    window.__vshookTimerLocalHoldFix10 = { until: Date.now() + ms };
  }
  if (typeof getTimerElapsedSec === 'function') {
    const previousGetTimerElapsedSecFix10 = getTimerElapsedSec;
    getTimerElapsedSec = function() {
      try {
        if (state.timerRunning) {
          const base = Math.max(0, Number(state.timerAccumulatedSec) || 0);
          const started = Number(state.timerStartedAt || state.timerStartedAtMs || 0);
          const live = started > 0 ? Math.max(0, Math.floor((Date.now() - started) / 1000)) : 0;
          if (state.timerMode === 'countdown') {
            const target = Math.max(0, Number(state.timerTargetSec) || 0);
            return Math.max(0, target - (base + live));
          }
          return base + live;
        }
      } catch(e) {}
      return previousGetTimerElapsedSecFix10();
    };
  }
  confirmTimerModal = function() {
    const wasRunning = !!state.timerRunning;
    if (wasRunning) {
      state.timerRunning = false;
      state.timerStartedAt = 0;
      state.timerStartedAtMs = 0;
      state.timerAccumulatedSec = 0;
      state.timerElapsedSec = 0;
      state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
      state.showTimerModal = false;
      setTimerHoldFix10(3000);
      postCommand('timer_stop_reset');
      postCommand('timer_stop');
      syncChronoDisplays?.();
      refreshChronoRenderLoop?.();
      render?.();
      return;
    }
    if (state.timerMode === 'countdown') state.timerTargetSec = readTimerTargetSecondsFromModal?.() || 0;
    else state.timerTargetSec = 0;
    const now = Date.now();
    state.timerRunning = true;
    state.timerStartedAt = now;
    state.timerStartedAtMs = now;
    state.timerAccumulatedSec = 0;
    state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
    state.showTimerModal = false;
    setTimerHoldFix10(5000);
    postCommand('timer_set_mode', { timerMode: state.timerMode, mode: state.timerMode, timerTargetSec: state.timerTargetSec || 0, targetSec: state.timerTargetSec || 0, seconds: state.timerTargetSec || 0 });
    postCommand('timer_start');
    postCommand('timer_toggle');
    syncChronoDisplays?.();
    refreshChronoRenderLoop?.();
    render?.();
  };
  setTimerModeFromApp = function(mode) {
    const next = normalizeDirectorTimerMode(mode);
    if (state.timerMode === 'countdown' && next !== 'countdown') {
      try { state.timerTargetSec = readTimerTargetSecondsFromModal?.() || state.timerTargetSec || 0; } catch(e) {}
    }
    state.timerMode = next;
    if (next === 'progressive' && !state.timerRunning) {
      state.timerDisplaySec = 0;
    }
    postCommand('timer_set_mode', { timerMode: next, mode: next, timerTargetSec: next === 'countdown' ? (state.timerTargetSec || 0) : 0, targetSec: next === 'countdown' ? (state.timerTargetSec || 0) : 0, seconds: next === 'countdown' ? (state.timerTargetSec || 0) : 0 });
    render?.();
  };

  // Tela de Letras do Diretor agora é visualização TP1: sem armazenamento/editar.
  openLyricsPanel = function() {
    state.lyricsPanelOpen = true;
    state.lyricsEditing = false;
    state.lyricsDraft = '';
    state.settingsMenuOpen = false;
    render?.();
  };
  closeLyricsPanel = function() {
    document.body.classList.add('vshookReturningFromLyricsFix10');
    setTimeout(() => document.body.classList.remove('vshookReturningFromLyricsFix10'), 340);
    state.lyricsPanelOpen = false;
    state.lyricsEditing = false;
    state.lyricsDraft = '';
    render?.();
  };
  cancelLyricsEditAndClosePanel = closeLyricsPanel;
  startLyricsEdit = function() {};
  cancelLyricsEdit = function() {};
  confirmLyricsEdit = function() {};
  renderLyricsPanel = function() {
    if (!state.lyricsPanelOpen) return '';
    const title = upperText?.(getTp1TitleFix10()) || getTp1TitleFix10().toUpperCase();
    const text = getTp1TextFix10() || 'SEM CONTEÚDO NO TP1';
    const song = typeof getCurrentLyricsSong === 'function' ? getCurrentLyricsSong() : null;
    const progress = typeof getLyricsProgressRatio === 'function' ? (Math.round(getLyricsProgressRatio(song) * 1000) / 10) : 0;
    return `<div class="lyricsScreen telepromptOnlyScreen directorTp1OnlyScreen" style="--tp-text-color:${escapeHtml(getTpTextColorFix10())};--tp-font:${escapeHtml(getTpFontFix10())}">
      <div class="lyricsTopBar lyricsTopBarTpFix10">
        <div class="lyricsNowPlaying lyricsNowPlayingWideFix10">
          <div class="lyricsNowPlayingTitle" data-lyrics-title>${escapeHtml(title)}</div>
          <div class="lyricsProgressTrack"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${progress}%"></div></div>
        </div>
        <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonCompactFix10" data-action="close-lyrics-panel">&gt;&gt;</button>
      </div>
      <div class="lyricsBody">
        <div class="lyricsTextView tpLyricsTextFix10" data-lyrics-text-view data-lyrics-source="${escapeHtml(text)}">${lyricsTextToHtml?.(text) || escapeHtml(text)}</div>
      </div>
    </div>`;
  };
  if (typeof syncLyricsPanelDom === 'function') {
    syncLyricsPanelDom = function() {
      if (!state.lyricsPanelOpen) return;
      const titleNode = document.querySelector('[data-lyrics-title]');
      if (titleNode) titleNode.textContent = (upperText?.(getTp1TitleFix10()) || getTp1TitleFix10().toUpperCase());
      const textNode = document.querySelector('[data-lyrics-text-view]');
      const next = getTp1TextFix10() || 'SEM CONTEÚDO NO TP1';
      if (textNode && textNode.getAttribute('data-lyrics-source') !== next) {
        textNode.setAttribute('data-lyrics-source', next);
        textNode.innerHTML = lyricsTextToHtml?.(next) || escapeHtml(next);
      }
    };
  }
  if (typeof closeMarkersPanel === 'function') {
    const previousCloseMarkersPanelFix10 = closeMarkersPanel;
    closeMarkersPanel = function() {
      document.body.classList.add('vshookReturningFromMarkersFix10');
      setTimeout(() => document.body.classList.remove('vshookReturningFromMarkersFix10'), 340);
      return previousCloseMarkersPanelFix10();
    };
  }

  // Config: cor/fonte do texto TP1.
  if (typeof renderGearModal === 'function') {
    const previousRenderGearModalFix10 = renderGearModal;
    renderGearModal = function() {
      let html = previousRenderGearModalFix10();
      if (!html || html.includes('TP1 LETRA')) return html;
      const colorButtons = TP_COLORS.map(c => `<button class="settingsToggleBtn ${getTpTextColorFix10() === c ? 'settingsToggleBtnActive' : ''}" data-action="tp-color" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
      const fontButtons = TP_FONTS.map((f,i) => `<button class="settingsToggleBtn ${getTpFontFix10() === f ? 'settingsToggleBtnActive' : ''}" data-action="tp-font" data-font="${escapeHtml(f)}" style="font-family:${escapeHtml(f)}">${TP_FONT_LABELS[i]}</button>`).join('');
      const block = `<div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix10">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix10">${fontButtons}</div>`;
      return html.replace('<div class="modalButtons settingsBottomButtons">', block + '<div class="modalButtons settingsBottomButtons">');
    };
  }
  if (typeof bindEvents === 'function') {
    const previousBindEventsFix10 = bindEvents;
    bindEvents = function() {
      previousBindEventsFix10();
      document.querySelectorAll('[data-action="tp-color"]').forEach(el => el.addEventListener('click', () => setTpTextColorFix10(el.getAttribute('data-color') || '#f8fafc')));
      document.querySelectorAll('[data-action="tp-font"]').forEach(el => el.addEventListener('click', () => setTpFontFix10(el.getAttribute('data-font') || TP_FONTS[0])));
    };
  }

  function installFix10Styles() {
    if (document.getElementById('vshook-native-fix10-director-style')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix10-director-style';
    style.textContent = `
      @keyframes vshookDirectorLyricsEnterFix10{0%{opacity:.05;transform:translateX(-100%)}100%{opacity:1;transform:translateX(0)}}
      @keyframes vshookDirectorMarkersEnterFix10{0%{opacity:.05;transform:translateX(100%)}100%{opacity:1;transform:translateX(0)}}
      @keyframes vshookDirectorMainFromLyricsFix10{0%{opacity:.4;transform:translateX(22px)}100%{opacity:1;transform:translateX(0)}}
      @keyframes vshookDirectorMainFromMarkersFix10{0%{opacity:.4;transform:translateX(-22px)}100%{opacity:1;transform:translateX(0)}}
      .directorTp1OnlyScreen,.lyricsScreen{animation:vshookDirectorLyricsEnterFix10 .26s cubic-bezier(.18,.78,.24,1) both!important;}
      .markerContentPanel.markerPanelSlideIn,.markerListBox.markerPanelSlideIn,.markerPanelSlideIn{animation:vshookDirectorMarkersEnterFix10 .26s cubic-bezier(.18,.78,.24,1) both!important;}
      body.vshookReturningFromLyricsFix10 .contentPanel{animation:vshookDirectorMainFromLyricsFix10 .24s cubic-bezier(.18,.78,.24,1) both!important;}
      body.vshookReturningFromMarkersFix10 .contentPanel{animation:vshookDirectorMainFromMarkersFix10 .24s cubic-bezier(.18,.78,.24,1) both!important;}
      .lyricsBackButtonCompactFix10{width:54px!important;min-width:54px!important;max-width:54px!important;padding-left:0!important;padding-right:0!important;flex:0 0 54px!important;}
      .lyricsNowPlayingWideFix10{min-width:0!important;flex:1 1 auto!important;}
      .tpLyricsTextFix10{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important;font-size:clamp(22px,5.6vw,38px)!important;line-height:1.28!important;text-align:center!important;white-space:pre-wrap!important;}
      .settingsGridTpFix10{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important;}
      .settingsGridFontFix10{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important;}
      .settingsGridTpFix10 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important;}
    `;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installFix10Styles); else installFix10Styles();
})();


/* VS_HOOK_NATIVE_FIX11_DIRECTOR: ajustes finais pedidos pelo Joabe.
   - Premix: lista somente pista/item; tocar na linha abre controle; slider/M/FX só dentro do controle.
   - Comandos seguem direto para o Lua pelo fluxo premix_item_*.
   - Config força status NATIVE ON e injeta cor/fonte TP1 no Diretor.
   - Markers mostram só $, *1 e *2, sem símbolos, mantendo id original para engatilhar.
   - TP1: botão >> compacto, mas área do nome realmente maior.
*/
(function(){
  if (window.__VSHOOK_NATIVE_FIX11_DIRECTOR__) return;
  window.__VSHOOK_NATIVE_FIX11_DIRECTOR__ = true;

  const TP_COLOR_KEY = 'vshook_tp_text_color';
  const TP_FONT_KEY = 'vshook_tp_font_family';
  const TP_COLORS = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];
  const getLS = (k, f) => { try { return localStorage.getItem(k) || f; } catch(e) { return f; } };
  const setLS = (k, v) => { try { localStorage.setItem(k, String(v || '')); } catch(e) {} };
  const getTpColor = () => getLS(TP_COLOR_KEY, '#f8fafc');
  const getTpFont = () => getLS(TP_FONT_KEY, TP_FONTS[0]);
  const setTpColor = (v) => { setLS(TP_COLOR_KEY, v || '#f8fafc'); render?.(); };
  const setTpFont = (v) => { setLS(TP_FONT_KEY, v || TP_FONTS[0]); render?.(); };

  function installFix11Style(){
    if (document.getElementById('vshook-native-fix11-director-style')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix11-director-style';
    style.textContent = `
      .lyricsTopBarTpFix10,.lyricsTopBarTpFix11{display:flex!important;align-items:center!important;gap:8px!important;width:100%!important;box-sizing:border-box!important;}
      .lyricsNowPlayingWideFix10,.lyricsNowPlayingWideFix11{flex:1 1 auto!important;width:auto!important;max-width:none!important;min-width:0!important;overflow:hidden!important;}
      .lyricsBackButtonCompactFix10,.lyricsBackButtonCompactFix11{width:68px!important;min-width:68px!important;max-width:68px!important;flex:0 0 68px!important;padding-left:0!important;padding-right:0!important;font-size:22px!important;}
      .tpLyricsTextFix10,.tpLyricsTextFix11{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important;}
      .settingsGridTpFix11{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important;}
      .settingsGridFontFix11{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important;}
      .settingsGridTpFix11 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important;}
      .bridgeStatusCard .bridgeOnline{color:#86efac!important;}
      .premixControlOverlayFix11{background:rgba(0,0,0,.62)!important;}
      .premixControlBoxFix11{width:100vw!important;max-width:none!important;height:var(--app-vh,100dvh)!important;max-height:none!important;border-radius:0!important;display:flex!important;flex-direction:column!important;justify-content:center!important;padding:16px!important;box-sizing:border-box!important;}
      .premixControlActionsFix11{display:grid!important;grid-template-columns:1fr 1fr!important;gap:12px!important;margin:18px 0 24px!important;}
      .premixControlActionsFix11 button{height:56px!important;border-radius:14px!important;font-size:22px!important;font-weight:1000!important;}
      .premixControlSliderFix11{width:100%!important;height:54px!important;accent-color:#facc15!important;}
      .premixTrackRowFix11{min-height:58px!important;cursor:pointer!important;}
      .premixTrackRowFix11 .mixerRowDb{margin-left:auto!important;}
    `;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installFix11Style); else installFix11Style();

  function forceNativeOnlineDom(){
    try {
      if (state) {
        state.bridgeStatus = 'online';
        state.nativeBridgeConnected = true;
        state.nativeBridge = true;
        state.bridgeMode = state.bridgeMode || 'native';
      }
      document.querySelectorAll('.bridgeStatusCard').forEach(card => {
        const value = card.querySelector('.bridgeOffline,.bridgeOnline,span:last-child');
        if (value) {
          value.classList.remove('bridgeOffline');
          value.classList.add('bridgeOnline');
          value.textContent = 'NATIVE ON';
        }
      });
    } catch(e) {}
  }

  function injectTpSettingsIntoDirector(){
    try {
      const box = document.querySelector('.settingsModalBox');
      if (!box || box.querySelector('[data-fix11-tp-settings="1"]') || box.querySelector('[data-fix12-tp-settings="1"]')) return;
      forceNativeOnlineDom();
      const wrap = document.createElement('div');
      wrap.setAttribute('data-fix11-tp-settings','1');
      const colorButtons = TP_COLORS.map(c => `<button class="settingsToggleBtn ${getTpColor() === c ? 'settingsToggleBtnActive' : ''}" data-action="tp-color-fix11" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
      const fontButtons = TP_FONTS.map((f,i) => `<button class="settingsToggleBtn ${getTpFont() === f ? 'settingsToggleBtnActive' : ''}" data-action="tp-font-fix11" data-font="${escapeHtml?.(f) || f}" style="font-family:${escapeHtml?.(f) || f}">${TP_FONT_LABELS[i]}</button>`).join('');
      wrap.innerHTML = `<div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix11">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix11">${fontButtons}</div>`;
      const bottom = box.querySelector('.settingsBottomButtons');
      box.insertBefore(wrap, bottom || null);
      wrap.querySelectorAll('[data-action="tp-color-fix11"]').forEach(el => el.addEventListener('click', () => setTpColor(el.getAttribute('data-color') || '#f8fafc')));
      wrap.querySelectorAll('[data-action="tp-font-fix11"]').forEach(el => el.addEventListener('click', () => setTpFont(el.getAttribute('data-font') || TP_FONTS[0])));
    } catch(e) {}
  }

  if (typeof bindEvents === 'function') {
    const previousBindEventsFix11 = bindEvents;
    bindEvents = function(){
      previousBindEventsFix11();
      forceNativeOnlineDom();
      injectTpSettingsIntoDirector();
    };
  }
  if (typeof bridgeLooksOffline === 'function') {
    bridgeLooksOffline = function(){ return false; };
  }

  function markerAllowedAndCleanFix11(marker){
    const raw = String(marker?.rawName || marker?.name || marker?.label || '').trim();
    let clean = '';
    if (raw.startsWith('$')) clean = raw.replace(/^\$\s*/, '');
    else if (/^\*1\s*/.test(raw)) clean = raw.replace(/^\*1\s*/, '');
    else if (/^\*2\s*/.test(raw)) clean = raw.replace(/^\*2\s*/, '');
    else return null;
    clean = clean.trim();
    if (!clean) clean = raw.replace(/^(\$|\*1|\*2)\s*/, '').trim() || 'PART';
    return { ...marker, name: clean, label: clean, displayName: clean, rawName: raw };
  }
  if (typeof currentMarkers === 'function') {
    const previousCurrentMarkersFix11 = currentMarkers;
    currentMarkers = function(){
      const list = previousCurrentMarkersFix11() || [];
      const out = [];
      const seen = new Set();
      for (const marker of list) {
        const fixed = markerAllowedAndCleanFix11(marker);
        if (!fixed) continue;
        // Mantém o id original para o Lua engatilhar corretamente.
        const key = `${fixed.id}|${fixed.timeSec}|${fixed.rawName}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push(fixed);
      }
      return out;
    };
  }

  function premixRowsFix11(){
    const list = Array.isArray(state?.premixTracks) ? state.premixTracks : [];
    return list.filter(Boolean).map((item, index) => {
      const id = String(item.itemId || item.id || item.guid || item.trackId || '');
      return {
        ...item,
        id,
        guid: String(item.guid || id),
        itemId: String(item.itemId || id),
        trackId: String(item.trackId || item.trackGuid || item.guid || id),
        index: item.index || index + 1,
        name: String(item.name || item.label || item.trackName || item.takeName || `PISTA ${index + 1}`),
        volumeRatio: normalizeMixerRatio?.(item.volumeRatio ?? item.ratio, 0.5) ?? 0.5,
        mute: !!(item.mute ?? item.muted),
        hasFx: !!(item.hasFx || Number(item.fxCount || 0) > 0),
        fxEnabled: !!(item.fxEnabled ?? item.fxOn ?? item.fxActive),
      };
    });
  }
  getPremixItemsForView = function(){ return premixRowsFix11(); };
  findPremixTrack = function(id){
    const wanted = String(id || '');
    return premixRowsFix11().find(x => String(x.id || x.guid || x.itemId || '') === wanted) || null;
  };
  setPremixTrackLocalState = function(id, patch){
    const wanted = String(id || '');
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map(item => {
      const key = String(item.itemId || item.id || item.guid || '');
      return key === wanted ? { ...item, ...patch } : item;
    });
  };

  renderPremixTrackRows = function(){
    const tracks = premixRowsFix11();
    if (!tracks.length) return '<div class="emptyBox">SEM PISTAS/ITENS NESSA MÚSICA</div>';
    return tracks.map((item, index) => {
      const idRaw = String(item.id || item.guid || item.itemId || '');
      const id = escapeHtml?.(idRaw) || idRaw;
      const indexText = String(item.index ?? (index + 1)).padStart(2, '0');
      const name = buildMarqueeText?.(item.name || `PISTA ${indexText}`, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee') || (escapeHtml?.(item.name || `PISTA ${indexText}`) || item.name || `PISTA ${indexText}`);
      const db = escapeHtml?.(formatMixerDbLabel?.(item.db ?? 0, item.volumeRatio, item.displayScale) || '') || '';
      return `<div class="mixerRow premixMixerRow premixTrackRowFix11" data-action="open-premix-volume" data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">${escapeHtml?.(indexText) || indexText}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div></div><div class="mixerRowDb">${db}</div></div>`;
    }).join('');
  };

  openPremixVolumeModal = function(view, id){
    const item = findPremixTrack(id);
    if (!item) return;
    state.showPremixVolumeModal = true;
    state.premixTrackView = 'tracks';
    state.premixSelectedTrackId = String(id || item.id || item.itemId || '');
    armOverlayCloseGuard?.(650);
    render?.();
  };
  closePremixVolumeModal = function(force = false){
    if (!force && shouldIgnoreOverlayClose?.()) return;
    state.showPremixVolumeModal = false;
    state.premixSelectedTrackId = null;
    render?.();
  };
  handlePremixRowOpenFromElement = function(el, event){
    event?.preventDefault?.();
    event?.stopPropagation?.();
    if (!el) return;
    openPremixVolumeModal('tracks', el.getAttribute('data-premix-track-id'));
  };

  function premixCommandPayloadFix11(id, extra = {}){
    const item = findPremixTrack(id) || {};
    const songId = String(state?.premixSelectedSongId || '');
    const itemId = String(item.itemId || item.id || item.guid || id || '');
    return { id: songId, songId, selectedRegionId: songId, targetId: itemId, itemId, guid: itemId, trackId: String(item.trackId || item.trackGuid || item.guid || itemId), page: getCurrentPcPageName?.() || 'premix', ...extra };
  }
  handlePremixTrackToggle = function(event, action, trackId){
    event?.preventDefault?.();
    event?.stopPropagation?.();
    const id = String(trackId || '');
    if (!id || !String(state?.premixSelectedSongId || '')) return;
    const item = findPremixTrack(id);
    const fx = action === 'phase' || action === 'fx';
    if (fx && item && !(item.hasFx || Number(item.fxCount || 0) > 0)) return;
    if (fx) setPremixTrackLocalState(id, { fxEnabled: !(item?.fxEnabled) });
    else setPremixTrackLocalState(id, { mute: !(item?.mute) });
    render?.();
    postCommand?.(fx ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute', premixCommandPayloadFix11(id));
    fastPollBridge?.(8);
  };
  handlePremixVolumeInput = function(view, trackId, value){
    const id = String(trackId || '');
    if (!id || !String(state?.premixSelectedSongId || '')) return;
    const ratio = normalizeMixerRatio?.(value, 0.5) ?? Math.max(0, Math.min(1, Number(value) || 0.5));
    setPremixTrackLocalState(id, { volumeRatio: ratio, ratio });
    try { syncMixerVolumeModalUi?.('premix', id); } catch(e) {}
    postCommand?.('premix_item_set_volume', premixCommandPayloadFix11(id, { ratio, volumeRatio: ratio, scrollRatio: ratio }));
  };
  handlePremixVolumeReset = function(event, view, trackId){
    event?.preventDefault?.();
    event?.stopPropagation?.();
    handlePremixVolumeInput('tracks', trackId, getMixerZeroDbRatio?.() ?? 0.5);
    render?.();
  };
  renderPremixVolumeModal = function(){
    if (!state.showPremixVolumeModal || !state.premixSelectedTrackId) return '';
    const item = findPremixTrack(state.premixSelectedTrackId);
    if (!item) return '';
    const id = escapeHtml?.(String(state.premixSelectedTrackId)) || String(state.premixSelectedTrackId);
    const ratio = normalizeMixerRatio?.(item.volumeRatio ?? item.ratio, 0.5) ?? 0.5;
    const title = buildMarqueeText?.(item.name || 'PREMIX', '', 'rowMarquee mixerNameMarquee') || (escapeHtml?.(item.name || 'PREMIX') || item.name || 'PREMIX');
    const muteClass = item.mute ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn';
    const hasFx = !!(item.hasFx || Number(item.fxCount || 0) > 0);
    const fxClass = !hasFx ? 'mixerMiniBtn btnDisabled' : (item.fxEnabled ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn');
    const db = escapeHtml?.(formatMixerDbLabel?.(item.db ?? 0, item.volumeRatio, item.displayScale) || '') || '';
    return `<div class="modalOverlay mixerVolumeOverlay premixVolumeOverlay premixControlOverlayFix11" data-close-premix-volume style="z-index:3000;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox premixControlBoxFix11" data-stop-modal data-mixer-volume-modal="1"><div class="mixerModalHeader"><div class="modalTitle" style="min-width:0;overflow:hidden;white-space:nowrap">${title}</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix-volume">FECHAR</button></div><div class="premixControlActionsFix11"><button class="${muteClass}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${id}">M</button><button class="${fxClass}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${id}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button></div><div class="mixerVolumeDb" style="text-align:center;margin-bottom:10px">${db}</div><input class="mixerVolumeSlider premixControlSliderFix11" type="range" min="0" max="1" step="0.01" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${id}" /><button class="modalCancelBtn" data-action="premix-volume-reset" data-premix-view="tracks" data-premix-track-id="${id}" style="margin-top:18px;min-height:42px;background:#facc15;color:#111827;border-color:#facc15">RESET</button></div></div>`;
  };

  if (typeof renderLyricsPanel === 'function') {
    const prevRenderLyricsFix11 = renderLyricsPanel;
    renderLyricsPanel = function(){
      const html = prevRenderLyricsFix11();
      if (!html) return html;
      return html
        .replace(/lyricsTopBarTpFix10/g, 'lyricsTopBarTpFix10 lyricsTopBarTpFix11')
        .replace(/lyricsNowPlayingWideFix10/g, 'lyricsNowPlayingWideFix10 lyricsNowPlayingWideFix11')
        .replace(/lyricsBackButtonCompactFix10/g, 'lyricsBackButtonCompactFix10 lyricsBackButtonCompactFix11')
        .replace(/tpLyricsTextFix10/g, 'tpLyricsTextFix10 tpLyricsTextFix11')
        .replace(/--tp-text-color:[^;]+;/, `--tp-text-color:${getTpColor()};`)
        .replace(/--tp-font:[^;]+;/, `--tp-font:${getTpFont()};`);
    };
  }
})();


/* VS_HOOK_NATIVE_FIX12_DIRECTOR: TP1 layout, native config, marker trigger, timer direct commands, premix stable control. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX12_DIRECTOR__) return;
  window.__VSHOOK_NATIVE_FIX12_DIRECTOR__ = true;

  const TP_COLOR_KEY = 'vshook_director_tp_text_color';
  const TP_FONT_KEY = 'vshook_director_tp_font_family';
  const TP_COLORS_FIX12 = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS_FIX12 = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS_FIX12 = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];
  const esc12 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const upper12 = (v) => (typeof upperText === 'function' ? upperText(v) : String(v || '').toUpperCase());
  function lsGet12(key, fallback){ try { return localStorage.getItem(key) || fallback; } catch(e) { return fallback; } }
  function lsSet12(key, value){ try { localStorage.setItem(key, String(value || '')); } catch(e) {} }
  function getTpColor12(){ return lsGet12(TP_COLOR_KEY, '#f8fafc'); }
  function getTpFont12(){ return lsGet12(TP_FONT_KEY, TP_FONTS_FIX12[0]); }
  function setTpColor12(v){ lsSet12(TP_COLOR_KEY, v || '#f8fafc'); render?.(); }
  function setTpFont12(v){ lsSet12(TP_FONT_KEY, v || TP_FONTS_FIX12[0]); render?.(); }
  window.__vshookDirectorTpColorFix12 = getTpColor12;
  window.__vshookDirectorTpFontFix12 = getTpFont12;

  function mediaAllowsTextFix12(type){
    const t = String(type || 'text').toLowerCase().replace(/[\s-]+/g, '_');
    return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain';
  }
  function readTp1TitleFix12(){
    return String(state?.tp1SongName || state?.telepromptTp1SongName || state?.tp1Song || state?.currentSongName || state?.playingSongName || state?.songName || 'TELEPROMPT 1').trim() || 'TELEPROMPT 1';
  }
  function readTp1TextFix12(){
    const media = String(state?.tp1MediaType || state?.telepromptTp1MediaType || 'text');
    if (!mediaAllowsTextFix12(media)) return '';
    return String(state?.tp1LyricsText || state?.tp1Lyrics || state?.telepromptTp1Lyrics || state?.telepromptTp1Text || '').trim();
  }

  // Sync TP1 vindo do bridge para o Diretor também.
  if (typeof syncFromBridge === 'function' && !window.__VSHOOK_NATIVE_FIX12_DIRECTOR_SYNC_WRAPPED__) {
    window.__VSHOOK_NATIVE_FIX12_DIRECTOR_SYNC_WRAPPED__ = true;
    const prevSync = syncFromBridge;
    syncFromBridge = function(data){
      prevSync(data);
      try {
        const media = String(data?.tp1MediaType || data?.telepromptTp1MediaType || state.tp1MediaType || 'text');
        state.tp1MediaType = media;
        state.tp1SongName = String(data?.tp1SongName || data?.telepromptTp1SongName || data?.tp1Song || state.tp1SongName || '');
        state.tp1LyricsText = mediaAllowsTextFix12(media) ? String(data?.tp1LyricsText || data?.tp1Lyrics || data?.telepromptTp1Lyrics || data?.telepromptTp1Text || state.tp1LyricsText || '') : '';
        state.nativeBridgeConnected = true;
        state.bridgeStatus = 'online';
        state.bridgeMode = 'native';
      } catch(e) {}
    };
  }

  // Tela Letras = visualização TP1 somente. Sem armazenamento/editar.
  openLyricsPanel = function(){
    state.lyricsPanelOpen = true;
    state.lyricsEditing = false;
    state.lyricsDraft = '';
    state.settingsMenuOpen = false;
    document.body.classList.add('vshookEnteringLyricsFix12');
    setTimeout(() => document.body.classList.remove('vshookEnteringLyricsFix12'), 360);
    render?.();
  };
  closeLyricsPanel = function(){
    document.body.classList.add('vshookLeavingLyricsFix12');
    setTimeout(() => document.body.classList.remove('vshookLeavingLyricsFix12'), 360);
    state.lyricsPanelOpen = false;
    state.lyricsEditing = false;
    state.lyricsDraft = '';
    render?.();
  };
  startLyricsEdit = function(){};
  cancelLyricsEdit = function(){};
  confirmLyricsEdit = function(){};
  cancelLyricsEditAndClosePanel = closeLyricsPanel;
  renderLyricsPanel = function(){
    if (!state.lyricsPanelOpen) return '';
    const title = upper12(readTp1TitleFix12());
    const text = readTp1TextFix12() || 'SEM CONTEÚDO NO TP1';
    const progress = (() => {
      try {
        const duration = Number(state.playbackDurationSec || state.currentSongDurationSec || 0);
        const remaining = Number(state.playbackRemainingSec || state.currentSongRemainingSec);
        if (duration > 0 && Number.isFinite(remaining)) return Math.max(0, Math.min(100, ((duration - remaining) / duration) * 100));
      } catch(e) {}
      return 0;
    })();
    return `<div class="lyricsScreen telepromptOnlyScreen directorTp1OnlyScreen" style="--tp-text-color:${esc12(getTpColor12())};--tp-font:${esc12(getTpFont12())}">
      <div class="lyricsTopBar lyricsTopBarTpFix12">
        <div class="lyricsNowPlaying lyricsNowPlayingTpFix12">
          <div class="lyricsNowPlayingTitle lyricsNowPlayingTitleFix12" data-lyrics-title>${esc12(title)}</div>
          <div class="lyricsProgressTrack lyricsProgressTrackFix12"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${Math.round(progress * 10) / 10}%"></div></div>
        </div>
        <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonFix12" data-action="close-lyrics-panel">&gt;&gt;</button>
      </div>
      <div class="lyricsBody lyricsBodyTpFix12">
        <div class="lyricsTextView tpLyricsTextFix12" data-lyrics-text-view data-lyrics-source="${esc12(text)}">${typeof lyricsTextToHtml === 'function' ? lyricsTextToHtml(text) : esc12(text)}</div>
      </div>
    </div>`;
  };

  // Config do Diretor: status sempre NATIVE ON quando vem pelo Native Bridge + cor/fonte TP1 sem depender de injeção frágil.
  window.getDirectorTpSettingsHtmlFix12 = function(){
    const colorButtons = TP_COLORS_FIX12.map(c => `<button class="settingsToggleBtn ${getTpColor12() === c ? 'settingsToggleBtnActive' : ''}" data-action="director-tp-color-fix12" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
    const fontButtons = TP_FONTS_FIX12.map((f,i) => `<button class="settingsToggleBtn ${getTpFont12() === f ? 'settingsToggleBtnActive' : ''}" data-action="director-tp-font-fix12" data-font="${esc12(f)}" style="font-family:${esc12(f)}">${TP_FONT_LABELS_FIX12[i]}</button>`).join('');
    return `<div data-fix11-tp-settings="1" data-fix12-tp-settings="1"><div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix12">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix12">${fontButtons}</div></div>`;
  };

  function forceNativeOnlineFix12(){
    try {
      state.bridgeStatus = 'online';
      state.nativeBridgeConnected = true;
      state.bridgeMode = 'native';
      document.querySelectorAll('.bridgeStatusCard span:last-child,.bridgeStatusCard .bridgeOffline,.bridgeStatusCard .bridgeOnline').forEach((el) => {
        el.classList.remove('bridgeOffline');
        el.classList.add('bridgeOnline');
        el.textContent = 'NATIVE ON';
      });
    } catch(e) {}
  }
  if (typeof bridgeLooksOffline === 'function') bridgeLooksOffline = function(){ return false; };

  // Timer: comando direto, sem toggle duplicado; progressivo não mistura target do regressivo.
  window.__vshookTimerLocalHoldFix12 = { until: 0 };
  function holdTimer12(ms){ window.__vshookTimerLocalHoldFix12.until = Date.now() + Math.max(600, Number(ms) || 0); }
  getTimerElapsedSec = function(){
    const max = 99 * 3600 + 59 * 60 + 59;
    const running = !!state.timerRunning;
    const mode = normalizeDirectorTimerMode(state.timerMode || 'progressive');
    if (!running) {
      if (mode === 'countdown') return Math.max(0, Math.min(max, Math.floor(Number(state.timerDisplaySec ?? state.timerTargetSec) || 0)));
      return Math.max(0, Math.min(max, Math.floor(Number(state.timerDisplaySec ?? state.timerAccumulatedSec) || 0)));
    }
    const base = Math.max(0, Number(state.timerAccumulatedSec) || 0);
    const started = Number(state.timerStartedAt || state.timerStartedAtMs || 0);
    const live = started > 0 ? Math.max(0, Math.floor((Date.now() - started) / 1000)) : 0;
    if (mode === 'countdown') {
      const target = Math.max(0, Number(state.timerTargetSec) || 0);
      return Math.max(0, Math.min(max, target - (base + live)));
    }
    return Math.max(0, Math.min(max, base + live));
  };
  confirmTimerModal = function(){
    const wasRunning = !!state.timerRunning;
    if (wasRunning) {
      state.timerRunning = false;
      state.timerStartedAt = 0;
      state.timerStartedAtMs = 0;
      state.timerAccumulatedSec = 0;
      state.timerElapsedSec = 0;
      state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
      state.showTimerModal = false;
      holdTimer12(3500);
      postCommand('timer_stop_reset', { timerMode: state.timerMode, mode: state.timerMode });
      syncChronoDisplays?.(); refreshChronoRenderLoop?.(); render?.();
      return;
    }
    if (state.timerMode === 'countdown') state.timerTargetSec = readTimerTargetSecondsFromModal?.() || 0;
    else state.timerTargetSec = 0;
    const now = Date.now();
    state.timerRunning = true;
    state.timerStartedAt = now;
    state.timerStartedAtMs = now;
    state.timerAccumulatedSec = 0;
    state.timerElapsedSec = 0;
    state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
    state.showTimerModal = false;
    holdTimer12(4500);
    postCommand('timer_start', { timerMode: state.timerMode, mode: state.timerMode, timerTargetSec: state.timerTargetSec || 0, targetSec: state.timerTargetSec || 0, seconds: state.timerTargetSec || 0 });
    syncChronoDisplays?.(); refreshChronoRenderLoop?.(); render?.();
  };
  setTimerModeFromApp = function(mode){
    const next = normalizeDirectorTimerMode(mode);
    if (state.timerMode === 'countdown' && next !== 'countdown') {
      try { state.timerTargetSec = readTimerTargetSecondsFromModal?.() || state.timerTargetSec || 0; } catch(e) {}
    }
    state.timerMode = next;
    if (next === 'progressive') {
      state.timerDisplaySec = state.timerRunning ? getTimerElapsedSec() : 0;
    } else if (!state.timerRunning) {
      state.timerDisplaySec = Number(state.timerTargetSec) || 0;
    }
    postCommand('timer_set_mode', { timerMode: next, mode: next, timerTargetSec: next === 'countdown' ? (state.timerTargetSec || 0) : 0, targetSec: next === 'countdown' ? (state.timerTargetSec || 0) : 0, seconds: next === 'countdown' ? (state.timerTargetSec || 0) : 0 });
    render?.();
  };

  // Premix: seleciona música no Lua, mas NÃO abre janela no Lua; controle estável do slider.
  const premixLocalOverride12 = new Map();
  function keyOfPremix12(id){ return String(id || ''); }
  function applyPremixOverride12(item){
    if (!item) return item;
    const key = keyOfPremix12(item.itemId || item.id || item.guid || item.trackId);
    const local = premixLocalOverride12.get(key);
    if (local && Date.now() < local.until) return { ...item, ...local.patch };
    if (local) premixLocalOverride12.delete(key);
    return item;
  }
  const oldFindPremixTrack12 = typeof findPremixTrack === 'function' ? findPremixTrack : null;
  findPremixTrack = function(id, view){
    const wanted = keyOfPremix12(id);
    let item = oldFindPremixTrack12 ? oldFindPremixTrack12(id, view) : null;
    if (!item && Array.isArray(state.premixTracks)) item = state.premixTracks.find(x => keyOfPremix12(x.itemId || x.id || x.guid || x.trackId) === wanted) || null;
    return applyPremixOverride12(item);
  };
  const oldGetPremixItems12 = typeof getPremixItemsForView === 'function' ? getPremixItemsForView : null;
  getPremixItemsForView = function(view){
    const normalizedView = view === 'groups' ? 'groups' : 'tracks';
    let list = oldGetPremixItems12 ? oldGetPremixItems12(normalizedView) : (Array.isArray(state.premixTracks) ? state.premixTracks : []);

    // Se o Bridge ainda retornar Premix vazio depois da seleção, mantém a tela preenchida
    // com o cache do Mixer em vez de deixar o App Diretor sem pistas.
    if (!Array.isArray(list) || !list.length) {
      const directPremix = normalizedView === 'groups' ? state.premixGroups : state.premixTracks;
      const mixerFallback = normalizedView === 'groups' ? state.mixerGroups : state.mixerTracks;
      const fallback = Array.isArray(directPremix) && directPremix.length ? directPremix : (Array.isArray(mixerFallback) ? mixerFallback : []);
      const normalize = (item) => typeof normalizePremixTrackItem === 'function' ? normalizePremixTrackItem(item, normalizedView) : item;
      list = fallback.map(normalize).filter(Boolean);
    }

    return (Array.isArray(list) ? list : []).map(applyPremixOverride12);
  };
  setPremixTrackLocalState = function(id, patch){
    const key = keyOfPremix12(id);
    if (!key) return;
    premixLocalOverride12.set(key, { until: Date.now() + 2500, patch: { ...patch } });
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map(item => {
      const itemKey = keyOfPremix12(item.itemId || item.id || item.guid || item.trackId);
      return itemKey === key ? { ...item, ...patch } : item;
    });
  };
  const oldSelectPremixSong12 = typeof selectPremixSong === 'function' ? selectPremixSong : null;
  selectPremixSong = function(id){
    const songId = String(id || '');
    if (!songId) return;
    const songs = typeof getPremixSongs === 'function' ? getPremixSongs() : (Array.isArray(state.premixSongs) ? state.premixSongs : []);
    const song = songs.find(s => String(s?.id ?? s?.source_number ?? s?.sourceNumber ?? '') === songId) || {};
    state.premixIsGlobal = false;
    state.premixSelectedSongId = songId;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    const premixTrackBackup12 = Array.isArray(state.premixTracks) ? state.premixTracks : [];
    const premixGroupBackup12 = Array.isArray(state.premixGroups) ? state.premixGroups : [];
    const premixNormalize12 = (item, view) => typeof normalizePremixTrackItem === 'function' ? normalizePremixTrackItem(item, view) : item;
    const premixFallbackTracks12 = Array.isArray(state.mixerTracks) && state.mixerTracks.length ? state.mixerTracks : premixTrackBackup12;
    const premixFallbackGroups12 = Array.isArray(state.mixerGroups) && state.mixerGroups.length ? state.mixerGroups : premixGroupBackup12;
    state.premixTracks = premixFallbackTracks12.map(item => premixNormalize12(item, 'tracks')).filter(Boolean);
    state.premixGroups = premixFallbackGroups12.map(item => premixNormalize12(item, 'groups')).filter(Boolean);
    // Seleção visual do Diretor/Lua acompanha a música escolhida no Premix.
    if (state.activeTab === 'playlist') state.selectedPlaylistSongId = songId;
    else state.selectedRegionId = songId;
    const payload = {
      id: songId,
      songId,
      selectedRegionId: songId,
      source_number: song?.source_number ?? song?.sourceNumber ?? song?.number,
      sourceNumber: song?.sourceNumber ?? song?.source_number ?? song?.number,
      startPos: song?.startPos ?? song?.start_pos ?? song?.start,
      start_pos: song?.start_pos ?? song?.startPos ?? song?.start,
      endPos: song?.endPos ?? song?.end_pos ?? song?.end,
      end_pos: song?.end_pos ?? song?.endPos ?? song?.end,
      name: song?.name ?? song?.label ?? '',
      noOpenModal: true,
      openLuaPremix: false,
      page: getCurrentPcPageName?.() || 'premix'
    };
    postCommand('premix_item_focus_song', payload);
    render?.();
    fastPollBridge?.(16);
  };
  handlePremixVolumeInput = function(view, trackId, value){
    const item = findPremixTrack(trackId) || {};
    const id = keyOfPremix12(item.itemId || item.id || trackId);
    const songId = String(state.premixSelectedSongId || '');
    if (!id || !songId) return;
    const ratio = Math.max(0, Math.min(1, Number(value) || 0));
    const db = typeof mixerRatioToDb === 'function' ? mixerRatioToDb(ratio) : undefined;
    setPremixTrackLocalState(id, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { syncMixerVolumeModalUi?.('premix', id); } catch(e) {}
    postCommand('premix_item_set_volume', { id: songId, songId, selectedRegionId: songId, itemId: id, targetId: id, trackId: String(item.trackId || item.trackGuid || item.guid || id), guid: id, ratio, volumeRatio: ratio, page: getCurrentPcPageName?.() || 'premix' });
  };

  // Markers: só $/*1/*2, sem símbolo, e engatilho manda índice original para o Lua.
  function cleanMarker12(marker){
    const raw = String(marker?.rawName || marker?.name || marker?.label || '').trim();
    let clean = '';
    if (raw.startsWith('$')) clean = raw.replace(/^\$+\s*/, '');
    else if (/^\*\s*1\s*/.test(raw)) clean = raw.replace(/^\*\s*1\s*[-:|.]?\s*/, '');
    else if (/^\*\s*2\s*/.test(raw)) clean = raw.replace(/^\*\s*2\s*[-:|.]?\s*/, '');
    else return null;
    clean = clean.trim() || 'PART';
    return { ...marker, name: clean, label: clean, displayName: clean, rawName: raw };
  }
  const oldCurrentMarkers12 = typeof currentMarkers === 'function' ? currentMarkers : null;
  currentMarkers = function(){
    const list = oldCurrentMarkers12 ? oldCurrentMarkers12() : [];
    const out = [];
    const seen = new Set();
    for (const marker of Array.isArray(list) ? list : []) {
      const fixed = cleanMarker12(marker);
      if (!fixed) continue;
      const key = `${fixed.originalIndex ?? fixed.original_index ?? fixed.index ?? fixed.id}|${fixed.timeSec}|${fixed.rawName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(fixed);
    }
    return out;
  };
  selectMarker = function(id){
    clearStoppedSelectionHold?.();
    const key = String(id || '');
    if (!key) return;
    const marker = (currentMarkers?.() || []).find(m => String(m?.id ?? '') === key) || {};
    const originalIndex = marker.originalIndex ?? marker.original_index ?? marker.index ?? key;
    const commandId = originalIndex != null && String(originalIndex) !== '' ? String(originalIndex) : key;
    const payload = { id: commandId, markerId: key, selectedMarkerId: key, markerOriginalIndex: originalIndex, originalIndex, timeSec: marker.timeSec, songId: marker.songId, name: marker.name || marker.label || '' };
    const alreadySelected = String(state.selectedMarkerId || '') === key || isDirectorMarkerLocallyHeld?.(key) || String(state.markerGoFlashId || '') === key;
    if (alreadySelected) {
      state.selectedMarkerId = key;
      state.markerGoFlashId = key;
      setDirectorMarkerLocalHold?.(key);
      setDirectorMarkerArmedLocalHold?.(key);
      postCommand('marker_go', { ...payload, confirm: true });
      showAppPopup?.('MARKER ENGATILHADO', 'marker', 1200);
    } else {
      state.selectedMarkerId = key;
      state.markerGoFlashId = null;
      clearDirectorMarkerArmedLocalHold?.();
      setDirectorMarkerLocalHold?.(key);
      postCommand('marker_select', { ...payload, confirm: false });
    }
    render?.();
  };

  // Heartbeat mais frequente para manter aviso permanente no Lua enquanto o app Diretor está autenticado.
  if (typeof sendAppHeartbeat === 'function') {
    const previousHeartbeat12 = sendAppHeartbeat;
    sendAppHeartbeat = function(){
      if (needsAuthGate?.()) return;
      if (state.bridgeStatus !== 'online' && !state.nativeBridgeConnected) return;
      const now = Date.now();
      if ((now - (lastAppHeartbeatAt || 0)) < 950) return;
      lastAppHeartbeatAt = now;
      postCommand('app_heartbeat', { heartbeat: true, role: 'director', clientRole: 'director', appRole: 'director' });
    };
  }

  if (typeof bindEvents === 'function') {
    const previousBind12 = bindEvents;
    bindEvents = function(){
      previousBind12();
      forceNativeOnlineFix12();
      document.querySelectorAll('[data-action="director-tp-color-fix12"]').forEach(el => el.addEventListener('click', () => setTpColor12(el.getAttribute('data-color') || '#f8fafc')));
      document.querySelectorAll('[data-action="director-tp-font-fix12"]').forEach(el => el.addEventListener('click', () => setTpFont12(el.getAttribute('data-font') || TP_FONTS_FIX12[0])));
    };
  }

  function installStyle12(){
    if (document.getElementById('vshook-native-fix12-director-style')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix12-director-style';
    style.textContent = `
      .lyricsTopBarTpFix12{display:flex!important;align-items:center!important;gap:10px!important;width:100%!important;box-sizing:border-box!important;padding:10px 10px 8px!important;min-height:74px!important;}
      .lyricsNowPlayingTpFix12{flex:1 1 auto!important;min-width:0!important;width:auto!important;max-width:none!important;display:flex!important;flex-direction:column!important;gap:7px!important;overflow:hidden!important;}
      .lyricsNowPlayingTitleFix12{display:block!important;min-width:0!important;max-width:100%!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;font-size:clamp(15px,4.2vw,24px)!important;font-weight:1000!important;line-height:1.05!important;}
      .lyricsProgressTrackFix12{width:100%!important;min-width:0!important;flex:0 0 8px!important;height:8px!important;}
      .lyricsBackButtonFix12{width:82px!important;min-width:82px!important;max-width:82px!important;flex:0 0 82px!important;padding-left:0!important;padding-right:0!important;font-size:23px!important;font-weight:1000!important;display:flex!important;align-items:center!important;justify-content:center!important;}
      .tpLyricsTextFix12{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important;font-size:clamp(22px,5.8vw,40px)!important;line-height:1.26!important;text-align:center!important;white-space:pre-wrap!important;}
      .settingsGridTpFix12{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important}.settingsGridTpFix12 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important}.settingsGridFontFix12{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}
      .bridgeStatusCard .bridgeOnline{color:#86efac!important;}
      .premixControlSliderFix11,.premixControlSliderFix12{width:100%!important;touch-action:none!important;}
      .markerGoConfirmed{background:#14532d!important;border-color:#22c55e!important;box-shadow:0 0 16px rgba(34,197,94,.42)!important;}
      .markerGoConfirmed.markerBlink{animation:markerBlinkPulseFix12 .45s linear infinite!important;}
      @keyframes markerBlinkPulseFix12{0%{filter:brightness(1)}50%{filter:brightness(1.45)}100%{filter:brightness(1)}}
      .vshookLeavingLyricsFix12 .lyricsScreen{animation:vshookLyricsLeaveFix12 .28s ease-in both}.vshookEnteringLyricsFix12 .lyricsScreen{animation:vshookLyricsEnterFix12 .28s ease-out both}
      @keyframes vshookLyricsEnterFix12{from{transform:translateX(-28px);opacity:.2}to{transform:translateX(0);opacity:1}}@keyframes vshookLyricsLeaveFix12{from{transform:translateX(0);opacity:1}to{transform:translateX(28px);opacity:.2}}
    `;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installStyle12); else installStyle12();
})();

/* VS_HOOK_DIRECTOR_FIX13_REFLEXO_LUA
   Premix do Diretor = reflexo do Lua: sem Global/cache/fallback de Mixer.
   Mixer continua espelhando o Mixer do Lua. Ordem da aba Músicas segue a ordem do Lua.
   Heartbeat do Diretor só vale com sessão autenticada e para após logout pelo botão Acessar no Lua.
*/
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX13_REFLEXO_LUA__) return;
  window.__VSHOOK_DIRECTOR_FIX13_REFLEXO_LUA__ = true;

  const esc13 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const key13 = (v) => String(v ?? '').trim();
  const normPremix13 = (item) => {
    if (!item || typeof item !== 'object') return null;
    const id = key13(item.itemId || item.id || item.guid || item.trackId);
    if (!id) return null;
    const row = typeof normalizePremixTrackItem === 'function' ? normalizePremixTrackItem(item, 'tracks') : { ...item };
    row.id = key13(row.id || id);
    row.guid = key13(row.guid || id);
    row.itemId = key13(row.itemId || id);
    row.trackId = key13(row.trackId || item.trackId || item.trackGuid || id);
    row.name = String(row.name || row.label || row.trackName || item.name || item.label || item.trackName || 'ITEM');
    row.label = String(row.label || row.name);
    row.view = 'tracks';
    row.itemMode = true;
    return row;
  };

  // Volta a ordem original entregue pelo Lua/extensão. O patch alfa antigo bagunçava a aba Músicas.
  if (typeof vshookRootFamilyItems === 'function') {
    vshookRootFamilyItems = function(items) {
      return (Array.isArray(items) ? items : []).filter((item) => !(typeof isHashChildItem === 'function' && isHashChildItem(item)));
    };
  }

  isPremixGlobalMode = function(){ return false; };
  getPremixOnState = function(){ return true; };
  getPremixOnLabel = function(){ return 'PREMIX'; };
  canEditCurrentPremix = function(){ return !!key13(state?.premixSelectedSongId); };
  setPremixTrackView = function(){ state.premixTrackView = 'tracks'; return true; };

  getPremixSongs = function(){
    const source = Array.isArray(state?.premixSongs) && state.premixSongs.length ? state.premixSongs : (Array.isArray(state?.regions) ? state.regions : []);
    return (Array.isArray(source) ? source : []).filter((song) => {
      if (typeof detectBlockItem === 'function' && detectBlockItem(song)) return false;
      if (typeof vshookPremixIsParentSong === 'function' && vshookPremixIsParentSong(song)) return false;
      return true;
    });
  };

  getPremixItemsForView = function(){
    return (Array.isArray(state?.premixTracks) ? state.premixTracks : []).map(normPremix13).filter(Boolean);
  };
  getPremixTracks = function(){ return getPremixItemsForView('tracks'); };
  findPremixTrack = function(id){
    const wanted = key13(id);
    if (!wanted) return null;
    return getPremixItemsForView('tracks').find((item) => [item.id, item.guid, item.itemId, item.trackId].map(key13).includes(wanted)) || null;
  };
  setPremixTrackLocalState = function(id, patch = {}){
    const wanted = key13(id);
    if (!wanted) return;
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((item) => {
      const row = normPremix13(item);
      if (!row) return item;
      return [row.id, row.guid, row.itemId, row.trackId].map(key13).includes(wanted) ? { ...item, ...patch } : item;
    });
  };

  if (typeof syncFromBridge === 'function' && !window.__VSHOOK_DIRECTOR_FIX13_SYNC_WRAPPED__) {
    window.__VSHOOK_DIRECTOR_FIX13_SYNC_WRAPPED__ = true;
    const prevSync13 = syncFromBridge;
    syncFromBridge = function(data){
      if (data && typeof data === 'object' && (data.forceDirectorLogout === true || data.directorLogoutRequested === true)) {
        window.__vshookDirectorLogoutInProgress = true;
        window.__vshookDirectorHeartbeatBlockedUntil = Date.now() + 20000;
      }
      prevSync13(data);
      try {
        if (data && data.premix && typeof data.premix === 'object') {
          state.premixIsGlobal = false;
          state.premixGlobalEnabled = false;
          state.premixBypassEnabled = false;
          state.premixGroups = [];
          state.premixGlobalTracks = [];
          state.premixGlobalGroups = [];
          if (Array.isArray(data.premix.songs)) state.premixSongs = data.premix.songs;
          if (data.premix.selectedSongId != null && String(data.premix.selectedSongId) !== '') {
            state.premixSelectedSongId = String(data.premix.selectedSongId);
          }
          if (Array.isArray(data.premix.tracks)) {
            state.premixTracks = data.premix.tracks.map(normPremix13).filter(Boolean);
          }
          state.premixSelectedEnabled = true;
          state.premixSelectedCanEdit = !!key13(state.premixSelectedSongId);
        }
      } catch(e) {}
    };
  }

  openPremixModal = function(){
    state.settingsMenuOpen = false;
    state.showGearModal = false;
    state.showMixerModal = false;
    state.showMixerVolumeModal = false;
    state.showPremixVolumeModal = false;
    state.showBpmModal = false;
    state.showTunerModal = false;
    state.showPremixModal = true;
    state.premixIsGlobal = false;
    state.premixView = 'songs';
    state.premixTrackView = 'tracks';
    state.premixSelectedTrackId = null;
    state.premixGroups = [];
    if (typeof armOverlayCloseGuard === 'function') armOverlayCloseGuard(900);
    postCommand('premix_item_open', { requestTracks: '1', requestFull: '1', page: (typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'playlist') });
    if (typeof fastPollBridge === 'function') fastPollBridge(12);
    render?.();
  };

  selectPremixSong = function(id){
    const songId = key13(id);
    if (!songId) return;
    const song = getPremixSongs().find((entry) => [entry?.id, entry?.source_number, entry?.sourceNumber, entry?.number].map(key13).includes(songId)) || {};
    state.premixIsGlobal = false;
    state.premixSelectedSongId = songId;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixTracks = [];
    state.premixGroups = [];
    if (state.activeTab === 'playlist') {
      state.selectedPlaylistSongId = songId;
      state.selectedPlaylistSongIds = [songId];
    } else {
      state.selectedRegionId = songId;
      state.selectedRegionIds = [songId];
    }
    postCommand('premix_item_focus_song', {
      id: songId,
      songId,
      selectedRegionId: songId,
      regionId: songId,
      requestTracks: '1',
      noOpenModal: true,
      openLuaPremix: false,
      source_number: song?.source_number ?? song?.sourceNumber ?? song?.number,
      sourceNumber: song?.sourceNumber ?? song?.source_number ?? song?.number,
      startPos: song?.startPos ?? song?.start_pos ?? song?.start,
      start_pos: song?.start_pos ?? song?.startPos ?? song?.start,
      endPos: song?.endPos ?? song?.end_pos ?? song?.end,
      end_pos: song?.end_pos ?? song?.endPos ?? song?.end,
      name: song?.name ?? song?.label ?? '',
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    });
    if (typeof fastPollBridge === 'function') fastPollBridge(18);
    render?.();
  };

  handlePremixTrackToggle = function(event, action, trackId){
    event?.preventDefault?.();
    event?.stopPropagation?.();
    const item = findPremixTrack(trackId) || {};
    const itemId = key13(item.itemId || item.id || item.guid || trackId);
    const songId = key13(state.premixSelectedSongId);
    if (!itemId || !songId) return;
    const isFx = action === 'phase' || action === 'fx';
    if (isFx) setPremixTrackLocalState(itemId, { fxEnabled: !(item.fxEnabled !== false && item.fxOn !== false), fxOn: !(item.fxEnabled !== false && item.fxOn !== false) });
    else setPremixTrackLocalState(itemId, { mute: !(item.mute || item.muted), muted: !(item.mute || item.muted) });
    postCommand(isFx ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute', {
      id: songId, songId, selectedRegionId: songId,
      itemId, targetId: itemId, guid: itemId, trackId: key13(item.trackId || item.trackGuid || item.guid || itemId),
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    });
    if (typeof fastPollBridge === 'function') fastPollBridge(10);
    render?.();
  };

  handlePremixVolumeInput = function(view, trackId, value){
    const item = findPremixTrack(trackId) || {};
    const itemId = key13(item.itemId || item.id || item.guid || trackId);
    const songId = key13(state.premixSelectedSongId);
    if (!itemId || !songId) return;
    const ratio = Math.max(0, Math.min(1, Number(value) || 0));
    const db = typeof mixerRatioToDb === 'function' ? mixerRatioToDb(ratio) : undefined;
    setPremixTrackLocalState(itemId, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    postCommand('premix_item_set_volume', {
      id: songId, songId, selectedRegionId: songId,
      itemId, targetId: itemId, guid: itemId, trackId: key13(item.trackId || item.trackGuid || item.guid || itemId),
      ratio, volumeRatio: ratio,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    });
  };

  if (typeof sendAppHeartbeat === 'function') {
    sendAppHeartbeat = function(){
      if (window.__vshookDirectorLogoutInProgress || Date.now() < Number(window.__vshookDirectorHeartbeatBlockedUntil || 0)) return;
      if (typeof needsAuthGate === 'function' && needsAuthGate()) return;
      if (state.authEnabled && !state.authAuthenticated) return;
      if (state.bridgeStatus !== 'online' && !state.nativeBridgeConnected) return;
      const now = Date.now();
      if ((now - (lastAppHeartbeatAt || 0)) < 900) return;
      lastAppHeartbeatAt = now;
      postCommand('app_heartbeat', {
        heartbeat: true,
        role: 'director', clientRole: 'director', appRole: 'director',
        desiredState: 'authenticated',
        authAuthenticated: '1',
        sessionHash: state.authHash || ''
      });
    };
  }

  if (typeof logoutDirectorToModeSelection === 'function') {
    const prevLogout13 = logoutDirectorToModeSelection;
    logoutDirectorToModeSelection = function(data){
      window.__vshookDirectorLogoutInProgress = true;
      window.__vshookDirectorHeartbeatBlockedUntil = Date.now() + 20000;
      try { postCommand('director_logout_ack', { desiredState: 'logout', role: 'director', clientRole: 'director', appRole: 'director' }); } catch(e) {}
      try { clearAccessSession?.(); localStorage.removeItem('vshook_access_session'); } catch(e) {}
      return prevLogout13(data);
    };
  }

  if (typeof bindEvents === 'function') {
    const prevBind13 = bindEvents;
    bindEvents = function(){
      prevBind13();
      document.querySelectorAll('[data-action="premix-view-groups"], [data-action="premix-onoff"], [data-action="premix-global-reset"]').forEach((el) => {
        el.style.display = 'none';
      });
    };
  }
})();



/* VS_HOOK_DIRECTOR_FIX14_LUA_REFLECT_MIXER_PREMIX
   Mixer/Premix no App Diretor agora sao reflexo do Lua:
   - preserva ordem recebida;
   - separa grupo de pista;
   - slider envia ratio/volumeRatio/scrollRatio para o Lua;
   - Premix nao usa fallback do Mixer; espera a lista do Lua. */
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX14_LUA_REFLECT_MIXER_PREMIX__) return;
  window.__VSHOOK_DIRECTOR_FIX14_LUA_REFLECT_MIXER_PREMIX__ = true;

  const esc14 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const key14 = (v) => String(v ?? '').trim();
  const num14 = (v, f = 0) => { const n = Number(v); return Number.isFinite(n) ? n : f; };
  const ratio14 = (v, f = 0.5) => Math.max(0, Math.min(1, num14(v, f)));
  const isMaster14 = (item) => {
    const id = key14(item?.id || item?.guid || item?.trackId).toUpperCase();
    const type = key14(item?.type || item?.view || item?.kind || item?.role).toLowerCase();
    return id === 'MASTER' || id === 'MASTER_TRACK' || type === 'master' || item?.isMaster === true || item?.master === true;
  };
  const isGroup14 = (item) => {
    if (!item || isMaster14(item)) return false;
    const type = key14(item.type || item.view || item.kind || item.category || item.role).toLowerCase();
    if (item.isGroup === true || item.is_group === true || item.group === true || item.folder === true || item.isFolder === true || item.folderTrack === true) return true;
    if (type === 'group' || type === 'groups' || type === 'folder' || type === 'bus') return true;
    const fd = Number(item.folderDepth ?? item.folder_depth ?? item.i_folderdepth ?? item.I_FOLDERDEPTH);
    return Number.isFinite(fd) && fd > 0;
  };
  const mixerId14 = (item, fallback = '') => key14(item?.id || item?.guid || item?.trackId || item?.itemId || item?.targetId || fallback);
  const mixerName14 = (item, fallback) => key14(item?.name || item?.label || item?.trackName || item?.displayName || item?.title || fallback);

  function normMixer14(item, view, index) {
    if (!item || typeof item !== 'object') return null;
    const mode = view === 'master' ? 'master' : (isGroup14(item) || view === 'groups' ? 'groups' : 'tracks');
    const id = mixerId14(item, `${mode}-${index || 0}`);
    const name = mixerName14(item, mode === 'groups' ? `GRUPO ${index || ''}` : (mode === 'master' ? 'MASTER' : `TRACK ${index || ''}`));
    const volumeRatio = ratio14(item.volumeRatio ?? item.liveVolumeRatio ?? item.ratio, 0.5);
    return {
      ...item,
      id,
      guid: key14(item.guid || id),
      trackId: key14(item.trackId || item.guid || id),
      targetId: key14(item.targetId || item.guid || id),
      name,
      label: key14(item.label || name),
      index: Number.isFinite(Number(item.index)) ? Number(item.index) : index,
      orderIndex: Number.isFinite(Number(item.orderIndex ?? item.order_index)) ? Number(item.orderIndex ?? item.order_index) : index,
      view: mode,
      type: mode === 'groups' ? 'group' : mode,
      isGroup: mode === 'groups',
      is_group: mode === 'groups',
      isMaster: mode === 'master',
      volumeRatio,
      liveVolumeRatio: volumeRatio,
      muted: !!(item.muted ?? item.mute),
      mute: !!(item.mute ?? item.muted),
      solo: !!item.solo,
      displayScale: item.displayScale || 'db'
    };
  }

  function splitMixer14(data) {
    const mixer = data?.mixer && typeof data.mixer === 'object' ? data.mixer : {};
    const rawTracks = Array.isArray(mixer.tracks) ? mixer.tracks : (Array.isArray(data?.mixerTracks) ? data.mixerTracks : state.mixerTracks || []);
    const rawGroups = Array.isArray(mixer.groups) ? mixer.groups : (Array.isArray(data?.mixerGroups) ? data.mixerGroups : state.mixerGroups || []);
    const rawMaster = mixer.master && typeof mixer.master === 'object' ? mixer.master : (data?.mixerMaster && typeof data.mixerMaster === 'object' ? data.mixerMaster : state.mixerMaster);

    const tracks = [];
    const groups = [];
    const groupSeen = new Set();
    const trackSeen = new Set();

    rawGroups.forEach((item, idx) => {
      const row = normMixer14(item, 'groups', idx + 1);
      if (!row) return;
      const id = mixerId14(row);
      if (id && groupSeen.has(id)) return;
      if (id) groupSeen.add(id);
      groups.push(row);
    });

    rawTracks.forEach((item, idx) => {
      if (isMaster14(item)) return;
      if (isGroup14(item)) {
        const row = normMixer14(item, 'groups', groups.length + 1);
        const id = mixerId14(row);
        if (id && !groupSeen.has(id)) { groupSeen.add(id); groups.push(row); }
        return;
      }
      const row = normMixer14(item, 'tracks', idx + 1);
      if (!row) return;
      const id = mixerId14(row);
      if (id && trackSeen.has(id)) return;
      if (id) trackSeen.add(id);
      tracks.push(row);
    });

    const master = rawMaster && typeof rawMaster === 'object' ? normMixer14(rawMaster, 'master', 0) : null;
    return { tracks, groups, master };
  }

  function premixSource14(data) {
    const p = data?.premix && typeof data.premix === 'object' ? data.premix : {};
    const selected = key14(p.selectedSongId || p.selectedRegionId || p.songId || data?.premixSelectedSongId || state.premixSelectedSongId);
    const rows = Array.isArray(p.tracks) ? p.tracks
      : Array.isArray(p.items) ? p.items
      : Array.isArray(p.itemTracks) ? p.itemTracks
      : Array.isArray(p.rows) ? p.rows
      : Array.isArray(data?.premixTracks) ? data.premixTracks
      : [];
    return { selected, rows };
  }

  function normPremix14(item, index) {
    const base = typeof normPremix13 === 'function' ? normPremix13(item) : (typeof normalizePremixTrackItem === 'function' ? normalizePremixTrackItem(item, 'tracks') : item);
    if (!base || typeof base !== 'object') return null;
    const id = key14(base.itemId || base.id || base.guid || base.trackId || base.targetId || `item-${index || 0}`);
    const volumeRatio = ratio14(base.volumeRatio ?? base.liveVolumeRatio ?? base.ratio, 0.5);
    return {
      ...base,
      id,
      guid: key14(base.guid || id),
      itemId: key14(base.itemId || id),
      targetId: key14(base.targetId || id),
      trackId: key14(base.trackId || base.trackGuid || base.guid || id),
      name: key14(base.name || base.label || base.trackName || base.displayName || `ITEM ${index || ''}`),
      label: key14(base.label || base.name || base.trackName || `ITEM ${index || ''}`),
      index: Number.isFinite(Number(base.index)) ? Number(base.index) : index,
      view: 'tracks',
      itemMode: true,
      volumeRatio,
      liveVolumeRatio: volumeRatio,
      ratio: volumeRatio,
      mute: !!(base.mute ?? base.muted),
      muted: !!(base.muted ?? base.mute),
      fxEnabled: base.fxEnabled !== undefined ? !!base.fxEnabled : (base.fxOn !== undefined ? !!base.fxOn : true),
      fxOn: base.fxOn !== undefined ? !!base.fxOn : (base.fxEnabled !== undefined ? !!base.fxEnabled : true),
      displayScale: base.displayScale || 'db'
    };
  }

  const prevSync14 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync14) {
    syncFromBridge = function(data) {
      prevSync14(data);
      try {
        if (data && typeof data === 'object') {
          const mx = splitMixer14(data);
          state.mixerTracks = mx.tracks;
          state.mixerGroups = mx.groups;
          state.mixerMaster = mx.master;

          const premix = premixSource14(data);
          if (premix.selected) state.premixSelectedSongId = premix.selected;
          state.premixIsGlobal = false;
          state.premixGlobalEnabled = false;
          state.premixGroups = [];
          state.premixGlobalTracks = [];
          state.premixGlobalGroups = [];
          if (data.premix && Array.isArray(data.premix.songs)) state.premixSongs = data.premix.songs;
          if (premix.rows.length) {
            const mapped = premix.rows.map(normPremix14).filter(Boolean);
            state.premixTracks = mapped;
            if (premix.selected) {
              state.premixTracksBySongId = state.premixTracksBySongId || {};
              state.premixTracksByRegionId = state.premixTracksByRegionId || {};
              state.premixTracksBySongId[premix.selected] = mapped;
              state.premixTracksByRegionId[premix.selected] = mapped;
            }
          } else if (premix.selected) {
            const cached = state.premixTracksBySongId?.[premix.selected] || state.premixTracksByRegionId?.[premix.selected];
            state.premixTracks = Array.isArray(cached) ? cached.map(normPremix14).filter(Boolean) : [];
          }
          state.premixSelectedEnabled = true;
          state.premixSelectedCanEdit = !!key14(state.premixSelectedSongId);
        }
      } catch(e) {}
    };
  }

  getMixerItemsForView = function(view = state.mixerView) {
    if (view === 'groups') return Array.isArray(state.mixerGroups) ? state.mixerGroups : [];
    if (view === 'master') return state.mixerMaster ? [state.mixerMaster] : [];
    return Array.isArray(state.mixerTracks) ? state.mixerTracks : [];
  };

  const prevFindMixer14 = typeof findMixerItem === 'function' ? findMixerItem : null;
  findMixerItem = function(view, id) {
    const wanted = key14(id);
    const list = getMixerItemsForView(view);
    return list.find(item => [item?.id, item?.guid, item?.trackId, item?.targetId].map(key14).includes(wanted)) || (prevFindMixer14 ? prevFindMixer14(view, id) : null);
  };

  function mixerPayload14(view, id, ratioValue) {
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const item = findMixerItem(normalizedView, id) || {};
    const target = mixerId14(item, id);
    const ratio = ratio14(ratioValue, 0.5);
    return {
      view: normalizedView,
      id: target,
      targetId: target,
      trackId: key14(item.trackId || item.guid || target),
      guid: key14(item.guid || target),
      ratio,
      volumeRatio: ratio,
      scrollRatio: ratio,
      routeToLua: true,
      luaControl: true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'mixer'
    };
  }

  handleMixerVolumeInput = function(view, id, value) {
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const ratio = ratio14(value, 0.5);
    const item = findMixerItem(normalizedView, id);
    const target = mixerId14(item, id);
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    if (typeof setMixerItemLocalState === 'function') setMixerItemLocalState(normalizedView, target, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { syncMixerVolumeModalUi?.(normalizedView, target); } catch(e) {}
    postCommand('mixer_set_volume', mixerPayload14(normalizedView, target, ratio));
    window.clearTimeout(window.__vshookMixerVolumeConfirmTimer14 || 0);
    window.__vshookMixerVolumeConfirmTimer14 = window.setTimeout(() => postCommand('mixer_set_volume', mixerPayload14(normalizedView, target, ratio)), 90);
  };

  const prevMixerReset14 = typeof handleMixerVolumeReset === 'function' ? handleMixerVolumeReset : null;
  handleMixerVolumeReset = function(event, view, id) {
    event?.preventDefault?.(); event?.stopPropagation?.();
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const zero = typeof getMixerZeroDbRatio === 'function' ? getMixerZeroDbRatio() : 0.76;
    handleMixerVolumeInput(normalizedView, id, zero);
    if (prevMixerReset14) {
      // Mantem qualquer atualizacao visual antiga, mas o comando oficial ja foi enviado acima.
      try { prevMixerReset14(event, normalizedView, id); } catch(e) {}
    }
  };

  getPremixItemsForView = function(){ return (Array.isArray(state.premixTracks) ? state.premixTracks : []).map(normPremix14).filter(Boolean); };
  getPremixTracks = function(){ return getPremixItemsForView('tracks'); };
  findPremixTrack = function(id){
    const wanted = key14(id);
    return getPremixItemsForView('tracks').find(item => [item.id, item.guid, item.itemId, item.trackId, item.targetId].map(key14).includes(wanted)) || null;
  };

  const prevSelectPremix14 = typeof selectPremixSong === 'function' ? selectPremixSong : null;
  selectPremixSong = function(id) {
    const songId = key14(id);
    if (!songId) return;
    const song = (typeof getPremixSongs === 'function' ? getPremixSongs() : (state.premixSongs || [])).find(entry => [entry?.id, entry?.source_number, entry?.sourceNumber, entry?.number].map(key14).includes(songId)) || {};
    state.premixIsGlobal = false;
    state.premixSelectedSongId = songId;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixGroups = [];
    const cached = state.premixTracksBySongId?.[songId] || state.premixTracksByRegionId?.[songId];
    state.premixTracks = Array.isArray(cached) ? cached.map(normPremix14).filter(Boolean) : [];
    postCommand('premix_item_focus_song', {
      id: songId, songId, selectedRegionId: songId, regionId: songId,
      requestTracks: '1', requestFull: '1', routeToLua: true, luaControl: true,
      source_number: song?.source_number ?? song?.sourceNumber ?? song?.number,
      sourceNumber: song?.sourceNumber ?? song?.source_number ?? song?.number,
      startPos: song?.startPos ?? song?.start_pos ?? song?.start,
      start_pos: song?.start_pos ?? song?.startPos ?? song?.start,
      endPos: song?.endPos ?? song?.end_pos ?? song?.end,
      end_pos: song?.end_pos ?? song?.endPos ?? song?.end,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    });
    if (typeof fastPollBridge === 'function') fastPollBridge(24);
    render?.();
  };

  function premixPayload14(id, ratioValue = null) {
    const item = findPremixTrack(id) || {};
    const itemId = key14(item.itemId || item.id || item.guid || id);
    const songId = key14(state.premixSelectedSongId);
    const payload = {
      id: songId,
      songId,
      selectedRegionId: songId,
      regionId: songId,
      itemId,
      targetId: itemId,
      trackId: key14(item.trackId || item.trackGuid || item.guid || itemId),
      guid: itemId,
      routeToLua: true,
      luaControl: true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
    if (ratioValue !== null) {
      const ratio = ratio14(ratioValue, 0.5);
      payload.ratio = ratio; payload.volumeRatio = ratio; payload.scrollRatio = ratio;
    }
    return payload;
  }

  handlePremixVolumeInput = function(view, id, value) {
    const ratio = ratio14(value, 0.5);
    const item = findPremixTrack(id) || {};
    const itemId = key14(item.itemId || item.id || item.guid || id);
    if (!itemId || !key14(state.premixSelectedSongId)) return;
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    if (typeof setPremixTrackLocalState === 'function') setPremixTrackLocalState(itemId, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { syncMixerVolumeModalUi?.('premix', itemId); } catch(e) {}
    postCommand('premix_item_set_volume', premixPayload14(itemId, ratio));
    window.clearTimeout(window.__vshookPremixVolumeConfirmTimer14 || 0);
    window.__vshookPremixVolumeConfirmTimer14 = window.setTimeout(() => postCommand('premix_item_set_volume', premixPayload14(itemId, ratio)), 90);
  };

  handlePremixTrackToggle = function(event, action, id) {
    event?.preventDefault?.(); event?.stopPropagation?.();
    const item = findPremixTrack(id) || {};
    const itemId = key14(item.itemId || item.id || item.guid || id);
    if (!itemId || !key14(state.premixSelectedSongId)) return;
    const isFx = action === 'phase' || action === 'fx';
    if (typeof setPremixTrackLocalState === 'function') {
      if (isFx) setPremixTrackLocalState(itemId, { fxEnabled: !(item.fxEnabled !== false && item.fxOn !== false), fxOn: !(item.fxEnabled !== false && item.fxOn !== false) });
      else setPremixTrackLocalState(itemId, { mute: !(item.mute || item.muted), muted: !(item.mute || item.muted) });
    }
    postCommand(isFx ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute', premixPayload14(itemId));
    if (typeof fastPollBridge === 'function') fastPollBridge(12);
    render?.();
  };

  const prevBind14 = typeof bindEvents === 'function' ? bindEvents : null;
  if (prevBind14) {
    bindEvents = function(){
      prevBind14();
      document.querySelectorAll('[data-action="mixer-volume-slider"]').forEach((el) => {
        const view = el.getAttribute('data-mixer-view') || state.mixerVolumeView || 'tracks';
        const id = el.getAttribute('data-mixer-id') || state.mixerSelectedId || '';
        const run = () => handleMixerVolumeInput(view, id, el.value);
        el.addEventListener('pointermove', (event) => { if (event.buttons) run(); }, { passive: true });
        el.addEventListener('touchmove', run, { passive: true });
        el.addEventListener('pointerup', run, { passive: true });
        el.addEventListener('touchend', run, { passive: true });
      });
      document.querySelectorAll('[data-action="premix-volume-slider"]').forEach((el) => {
        const id = el.getAttribute('data-premix-track-id') || state.premixSelectedTrackId || '';
        const run = () => handlePremixVolumeInput('tracks', id, el.value);
        el.addEventListener('pointermove', (event) => { if (event.buttons) run(); }, { passive: true });
        el.addEventListener('touchmove', run, { passive: true });
        el.addEventListener('pointerup', run, { passive: true });
        el.addEventListener('touchend', run, { passive: true });
      });
      document.querySelectorAll('[data-action="premix-view-groups"], [data-action="premix-onoff"], [data-action="premix-global-reset"]').forEach((el) => { el.style.display = 'none'; });
    };
  }

  const style = document.createElement('style');
  style.setAttribute('data-vshook-fix14-mixer-premix', '1');
  style.textContent = `
    .mixerModalBoxFull .mixerViewTabsTriple{flex:0 0 auto!important;gap:6px!important;padding:4px 0 8px!important}
    .mixerModalBoxFull .mixerViewTabsTriple button,.mixerModalBoxFull .mixerViewTabs button{height:38px!important;min-height:38px!important;max-height:38px!important;padding:0 10px!important;font-size:12px!important;border-radius:10px!important}
    .mixerModalBoxFull .mixerRowsBox,.premixModalBoxFull .mixerRowsBox{align-content:flex-start!important;justify-content:flex-start!important}
    .mixerModalBoxFull .mixerRow,.premixModalBoxFull .mixerRow{flex:0 0 auto!important;min-height:52px!important;max-height:66px!important}
    .mixerModalBoxFull .sectionLabel,.premixModalBoxFull .sectionLabel{flex:0 0 auto!important;min-height:24px!important;margin:4px 0 6px!important}
    .premixInlineSlider{width:126px!important;min-width:104px!important;touch-action:pan-x!important}
  `;
  document.head?.appendChild(style);
})();


/* VS_HOOK_DIRECTOR_FIX15_NO_BOUNCE_AND_PREMIX_FROM_LUA
   - Mixer: segura valor local do slider até o snapshot novo chegar, evitando vai-e-volta.
   - Premix: lê sempre o payload do Lua, aceita premixTracks no topo ou dentro de premix,
     mantém carregando durante a requisição e manda regionIndex/start/end para o Lua achar a música certa.
*/
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX15_NO_BOUNCE_AND_PREMIX_FROM_LUA__) return;
  window.__VSHOOK_DIRECTOR_FIX15_NO_BOUNCE_AND_PREMIX_FROM_LUA__ = true;

  const key15 = (v) => String(v ?? '').trim();
  const num15 = (v, f = 0) => { const n = Number(v); return Number.isFinite(n) ? n : f; };
  const clamp15 = (v, f = 0.5) => Math.max(0, Math.min(1, num15(v, f)));
  const now15 = () => Date.now();
  const esc15 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));

  window.__vshookDirectorMixerHold15 = window.__vshookDirectorMixerHold15 || {};
  window.__vshookDirectorPremixHold15 = window.__vshookDirectorPremixHold15 || {};
  window.__vshookDirectorPremixRequest15 = window.__vshookDirectorPremixRequest15 || { songId: '', until: 0, tries: 0 };

  function parseMaybeJson15(value) {
    if (!value) return null;
    if (typeof value === 'object') return value;
    if (typeof value !== 'string') return null;
    try { return JSON.parse(value); } catch(e) { return null; }
  }

  function mergeSource15(data) {
    const base = (data && typeof data === 'object') ? data : {};
    const candidates = [
      base.luaLiveState, base.luaState, base.luaLive, base.lua,
      parseMaybeJson15(base.luaLiveJson), parseMaybeJson15(base.luaStateJson), parseMaybeJson15(base.LUA_LIVE_JSON_V1)
    ].filter(x => x && typeof x === 'object');
    return Object.assign({}, base, ...candidates);
  }

  function rowId15(item, fallback = '') {
    return key15(item?.id || item?.guid || item?.trackId || item?.itemId || item?.targetId || fallback);
  }
  function mixerHoldKey15(view, id) { return `${key15(view || 'tracks')}:${key15(id)}`; }
  function premixHoldKey15(songId, id) { return `${key15(songId)}:${key15(id)}`; }
  function setMixerHold15(view, id, ratio) {
    const k = mixerHoldKey15(view, id);
    window.__vshookDirectorMixerHold15[k] = { ratio: clamp15(ratio), until: now15() + 1600 };
  }
  function setPremixHold15(songId, id, ratio) {
    const k = premixHoldKey15(songId, id);
    window.__vshookDirectorPremixHold15[k] = { ratio: clamp15(ratio), until: now15() + 1600 };
  }
  function applyHoldRatio15(item, ratio) {
    if (!item || typeof item !== 'object') return item;
    return { ...item, volumeRatio: ratio, liveVolumeRatio: ratio, ratio, displayScale: item.displayScale || 'db' };
  }
  function overlayMixerHolds15(list, view) {
    const t = now15();
    return (Array.isArray(list) ? list : []).map((item, idx) => {
      const id = rowId15(item, `${view}-${idx}`);
      const hold = window.__vshookDirectorMixerHold15[mixerHoldKey15(view, id)] || window.__vshookDirectorMixerHold15[mixerHoldKey15(view, item?.guid)] || window.__vshookDirectorMixerHold15[mixerHoldKey15(view, item?.trackId)];
      if (!hold) return item;
      if (hold.until < t) { delete window.__vshookDirectorMixerHold15[mixerHoldKey15(view, id)]; return item; }
      const incoming = clamp15(item?.volumeRatio ?? item?.liveVolumeRatio ?? item?.ratio, -1);
      if (Math.abs(incoming - hold.ratio) < 0.012) {
        delete window.__vshookDirectorMixerHold15[mixerHoldKey15(view, id)];
        return item;
      }
      return applyHoldRatio15(item, hold.ratio);
    });
  }
  function overlayPremixHolds15(list, songId) {
    const t = now15();
    return (Array.isArray(list) ? list : []).map((item, idx) => {
      const id = rowId15(item, `premix-${idx}`);
      const hold = window.__vshookDirectorPremixHold15[premixHoldKey15(songId, id)] || window.__vshookDirectorPremixHold15[premixHoldKey15(songId, item?.guid)] || window.__vshookDirectorPremixHold15[premixHoldKey15(songId, item?.trackId)];
      if (!hold) return item;
      if (hold.until < t) { delete window.__vshookDirectorPremixHold15[premixHoldKey15(songId, id)]; return item; }
      const incoming = clamp15(item?.volumeRatio ?? item?.liveVolumeRatio ?? item?.ratio, -1);
      if (Math.abs(incoming - hold.ratio) < 0.012) {
        delete window.__vshookDirectorPremixHold15[premixHoldKey15(songId, id)];
        return item;
      }
      return applyHoldRatio15(item, hold.ratio);
    });
  }

  function normalizePremix15(item, index) {
    const base = (typeof normPremix14 === 'function') ? normPremix14(item, index)
      : (typeof normPremix13 === 'function') ? normPremix13(item)
      : (typeof normalizePremixTrackItem === 'function') ? normalizePremixTrackItem(item, 'tracks')
      : { ...(item || {}) };
    if (!base || typeof base !== 'object') return null;
    const id = rowId15(base, `item-${index || 0}`);
    if (!id) return null;
    const ratio = clamp15(base.volumeRatio ?? base.liveVolumeRatio ?? base.ratio, 0.5);
    const name = key15(base.name || base.label || base.trackName || base.displayName || `ITEM ${index || ''}`);
    return {
      ...base,
      id,
      guid: key15(base.guid || id),
      itemId: key15(base.itemId || id),
      targetId: key15(base.targetId || id),
      trackId: key15(base.trackId || base.trackGuid || base.guid || id),
      name,
      label: key15(base.label || name),
      view: 'tracks',
      type: 'item',
      itemMode: true,
      volumeRatio: ratio,
      liveVolumeRatio: ratio,
      ratio,
      mute: !!(base.mute ?? base.muted),
      muted: !!(base.muted ?? base.mute),
      fxEnabled: base.fxEnabled !== undefined ? !!base.fxEnabled : (base.fxOn !== undefined ? !!base.fxOn : true),
      fxOn: base.fxOn !== undefined ? !!base.fxOn : (base.fxEnabled !== undefined ? !!base.fxEnabled : true),
      displayScale: base.displayScale || 'db'
    };
  }

  function premixRowsFromSource15(src) {
    const p = src?.premix && typeof src.premix === 'object' ? src.premix : {};
    const arrays = [p.tracks, p.items, p.itemTracks, p.rows, src.premixTracks, src.premixItems, src.premixItemTracks, src.premixRows];
    for (const arr of arrays) if (Array.isArray(arr)) return arr;
    return [];
  }
  function premixSelectedFromSource15(src) {
    const p = src?.premix && typeof src.premix === 'object' ? src.premix : {};
    return key15(p.selectedSongId || p.selectedRegionId || src.premixSelectedSongId || src.premixSelectedRegionId || state.premixSelectedSongId);
  }

  const prevSync15 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync15) {
    syncFromBridge = function(data) {
      prevSync15(data);
      try {
        const src = mergeSource15(data);

        // Mixer: depois que o Bridge sincroniza, reaplica hold local se o snapshot ainda vier velho.
        if (Array.isArray(state.mixerTracks)) state.mixerTracks = overlayMixerHolds15(state.mixerTracks, 'tracks');
        if (Array.isArray(state.mixerGroups)) state.mixerGroups = overlayMixerHolds15(state.mixerGroups, 'groups');
        if (state.mixerMaster) state.mixerMaster = overlayMixerHolds15([state.mixerMaster], 'master')[0] || state.mixerMaster;

        const selected = premixSelectedFromSource15(src);
        const currentSelected = key15(state.premixSelectedSongId || window.__vshookDirectorPremixRequest15.songId);
        const rowsRaw = premixRowsFromSource15(src);
        const rows = rowsRaw.map((x, i) => normalizePremix15(x, i + 1)).filter(Boolean);

        if (src?.premix && Array.isArray(src.premix.songs)) state.premixSongs = src.premix.songs;
        if (selected) state.premixSelectedSongId = selected;
        state.premixIsGlobal = false;
        state.premixGlobalEnabled = false;
        state.premixGroups = [];
        state.premixGlobalTracks = [];
        state.premixGlobalGroups = [];

        if (rows.length) {
          const sid = selected || currentSelected;
          const finalRows = overlayPremixHolds15(rows, sid);
          state.premixTracks = finalRows;
          if (sid) {
            state.premixTracksBySongId = state.premixTracksBySongId || {};
            state.premixTracksByRegionId = state.premixTracksByRegionId || {};
            state.premixTracksBySongId[sid] = finalRows;
            state.premixTracksByRegionId[sid] = finalRows;
          }
          window.__vshookDirectorPremixRequest15.until = 0;
        } else if (currentSelected && now15() < Number(window.__vshookDirectorPremixRequest15.until || 0)) {
          // Snapshot velho sem premix não pode apagar a tela enquanto o Lua ainda está respondendo.
          const cached = state.premixTracksBySongId?.[currentSelected] || state.premixTracksByRegionId?.[currentSelected];
          state.premixTracks = Array.isArray(cached) ? overlayPremixHolds15(cached.map((x,i)=>normalizePremix15(x,i+1)).filter(Boolean), currentSelected) : (Array.isArray(state.premixTracks) ? state.premixTracks : []);
        } else if (selected && selected === currentSelected) {
          const cached = state.premixTracksBySongId?.[selected] || state.premixTracksByRegionId?.[selected];
          state.premixTracks = Array.isArray(cached) ? overlayPremixHolds15(cached.map((x,i)=>normalizePremix15(x,i+1)).filter(Boolean), selected) : [];
        }
        state.premixSelectedEnabled = true;
        state.premixSelectedCanEdit = !!key15(state.premixSelectedSongId);
      } catch(e) {}
    };
  }

  function songPayload15(songId) {
    const songs = typeof getPremixSongs === 'function' ? getPremixSongs() : (Array.isArray(state.premixSongs) ? state.premixSongs : []);
    const song = (songs || []).find(entry => [entry?.id, entry?.source_number, entry?.sourceNumber, entry?.number, entry?.regionIndex, entry?.luaRegionIndex].map(key15).includes(key15(songId))) || {};
    return {
      id: songId,
      songId,
      selectedRegionId: songId,
      regionId: songId,
      luaRegionIndex: song?.luaRegionIndex ?? song?.regionIndex ?? song?.region_index,
      regionIndex: song?.regionIndex ?? song?.luaRegionIndex ?? song?.region_index,
      region_index: song?.region_index ?? song?.regionIndex ?? song?.luaRegionIndex,
      requestTracks: '1',
      requestFull: '1',
      forceLuaPremix: true,
      routeToLua: true,
      luaControl: true,
      source_number: song?.source_number ?? song?.sourceNumber ?? song?.number,
      sourceNumber: song?.sourceNumber ?? song?.source_number ?? song?.number,
      startPos: song?.startPos ?? song?.start_pos ?? song?.start,
      start_pos: song?.start_pos ?? song?.startPos ?? song?.start,
      endPos: song?.endPos ?? song?.end_pos ?? song?.end,
      end_pos: song?.end_pos ?? song?.endPos ?? song?.end,
      name: song?.name ?? song?.label ?? '',
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
  }

  selectPremixSong = function(id) {
    const songId = key15(id);
    if (!songId) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = songId;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixGroups = [];
    const cached = state.premixTracksBySongId?.[songId] || state.premixTracksByRegionId?.[songId];
    state.premixTracks = Array.isArray(cached) ? cached.map((x,i)=>normalizePremix15(x,i+1)).filter(Boolean) : [];
    window.__vshookDirectorPremixRequest15 = { songId, until: now15() + 3500, tries: 0 };
    postCommand?.('premix_item_focus_song', songPayload15(songId));
    setTimeout(() => { if (key15(state.premixSelectedSongId) === songId && (!Array.isArray(state.premixTracks) || !state.premixTracks.length)) postCommand?.('premix_item_focus_song', songPayload15(songId)); }, 180);
    setTimeout(() => { if (key15(state.premixSelectedSongId) === songId && (!Array.isArray(state.premixTracks) || !state.premixTracks.length)) postCommand?.('premix_item_focus_song', songPayload15(songId)); }, 520);
    if (typeof fastPollBridge === 'function') fastPollBridge(30);
    render?.();
  };

  openPremixModal = function(){
    state.settingsMenuOpen = false;
    state.showGearModal = false;
    state.showMixerModal = false;
    state.showMixerVolumeModal = false;
    state.showPremixVolumeModal = false;
    state.showBpmModal = false;
    state.showTunerModal = false;
    state.showPremixModal = true;
    state.premixIsGlobal = false;
    state.premixView = 'songs';
    state.premixTrackView = 'tracks';
    state.premixSelectedTrackId = null;
    state.premixGroups = [];
    postCommand?.('premix_item_open', { requestTracks: '1', requestFull: '1', forceLuaPremix: true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix' });
    if (typeof fastPollBridge === 'function') fastPollBridge(24);
    render?.();
  };

  getPremixItemsForView = function(){
    return (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((x,i)=>normalizePremix15(x,i+1)).filter(Boolean);
  };
  getPremixTracks = function(){ return getPremixItemsForView('tracks'); };
  findPremixTrack = function(id){
    const wanted = key15(id);
    return getPremixItemsForView('tracks').find(item => [item.id, item.guid, item.itemId, item.trackId, item.targetId].map(key15).includes(wanted)) || null;
  };

  const prevSetMixerLocal15 = typeof setMixerItemLocalState === 'function' ? setMixerItemLocalState : null;
  setMixerItemLocalState = function(view, id, patch = {}) {
    if (prevSetMixerLocal15) { try { prevSetMixerLocal15(view, id, patch); } catch(e) {} }
    const wanted = key15(id);
    const apply = (item) => [item?.id, item?.guid, item?.trackId, item?.targetId].map(key15).includes(wanted) ? { ...item, ...patch } : item;
    if (view === 'groups') state.mixerGroups = (Array.isArray(state.mixerGroups) ? state.mixerGroups : []).map(apply);
    else if (view === 'master' && state.mixerMaster) state.mixerMaster = apply(state.mixerMaster);
    else state.mixerTracks = (Array.isArray(state.mixerTracks) ? state.mixerTracks : []).map(apply);
  };

  handleMixerVolumeInput = function(view, id, value) {
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const ratio = clamp15(value, 0.5);
    const item = typeof findMixerItem === 'function' ? (findMixerItem(normalizedView, id) || {}) : {};
    const target = rowId15(item, id);
    setMixerHold15(normalizedView, target, ratio);
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    setMixerItemLocalState(normalizedView, target, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { syncMixerVolumeModalUi?.(normalizedView, target); } catch(e) {}
    const payload = {
      view: normalizedView,
      id: target,
      targetId: target,
      trackId: key15(item.trackId || item.guid || target),
      guid: key15(item.guid || target),
      ratio,
      volumeRatio: ratio,
      scrollRatio: ratio,
      routeToLua: true,
      luaControl: true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'mixer'
    };
    postCommand?.('mixer_set_volume', payload);
    clearTimeout(window.__vshookMixerVolumeConfirmTimer15 || 0);
    window.__vshookMixerVolumeConfirmTimer15 = setTimeout(() => postCommand?.('mixer_set_volume', payload), 120);
  };

  const prevPremixLocal15 = typeof setPremixTrackLocalState === 'function' ? setPremixTrackLocalState : null;
  setPremixTrackLocalState = function(id, patch = {}) {
    if (prevPremixLocal15) { try { prevPremixLocal15(id, patch); } catch(e) {} }
    const wanted = key15(id);
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((item) => {
      const row = normalizePremix15(item, 0);
      return row && [row.id, row.guid, row.itemId, row.trackId, row.targetId].map(key15).includes(wanted) ? { ...item, ...patch } : item;
    });
  };

  function premixPayload15(id, ratioValue = null) {
    const item = findPremixTrack(id) || {};
    const itemId = rowId15(item, id);
    const songId = key15(state.premixSelectedSongId || window.__vshookDirectorPremixRequest15.songId);
    const payload = songPayload15(songId);
    Object.assign(payload, {
      itemId,
      targetId: itemId,
      guid: itemId,
      trackId: key15(item.trackId || item.trackGuid || item.guid || itemId)
    });
    if (ratioValue !== null) {
      const ratio = clamp15(ratioValue, 0.5);
      payload.ratio = ratio;
      payload.volumeRatio = ratio;
      payload.scrollRatio = ratio;
    }
    return payload;
  }

  handlePremixVolumeInput = function(view, id, value) {
    const ratio = clamp15(value, 0.5);
    const item = findPremixTrack(id) || {};
    const itemId = rowId15(item, id);
    const songId = key15(state.premixSelectedSongId || window.__vshookDirectorPremixRequest15.songId);
    if (!itemId || !songId) return;
    setPremixHold15(songId, itemId, ratio);
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    setPremixTrackLocalState(itemId, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { syncMixerVolumeModalUi?.('premix', itemId); } catch(e) {}
    const payload = premixPayload15(itemId, ratio);
    postCommand?.('premix_item_set_volume', payload);
    clearTimeout(window.__vshookPremixVolumeConfirmTimer15 || 0);
    window.__vshookPremixVolumeConfirmTimer15 = setTimeout(() => postCommand?.('premix_item_set_volume', payload), 120);
  };

  handlePremixTrackToggle = function(event, action, id) {
    event?.preventDefault?.(); event?.stopPropagation?.();
    const item = findPremixTrack(id) || {};
    const itemId = rowId15(item, id);
    const songId = key15(state.premixSelectedSongId || window.__vshookDirectorPremixRequest15.songId);
    if (!itemId || !songId) return;
    const isFx = action === 'phase' || action === 'fx';
    if (isFx) setPremixTrackLocalState(itemId, { fxEnabled: !(item.fxEnabled !== false && item.fxOn !== false), fxOn: !(item.fxEnabled !== false && item.fxOn !== false) });
    else setPremixTrackLocalState(itemId, { mute: !(item.mute || item.muted), muted: !(item.mute || item.muted) });
    postCommand?.(isFx ? 'premix_item_toggle_fx' : 'premix_item_toggle_mute', premixPayload15(itemId));
    if (typeof fastPollBridge === 'function') fastPollBridge(14);
    render?.();
  };

  const prevRenderPremixRows15 = typeof renderPremixTrackRows === 'function' ? renderPremixTrackRows : null;
  renderPremixTrackRows = function(){
    const rows = getPremixItemsForView('tracks');
    if (!rows.length && now15() < Number(window.__vshookDirectorPremixRequest15.until || 0)) {
      return `<div class="emptyState" style="padding:18px;text-align:center;color:#cbd5e1;font-weight:900">CARREGANDO ITENS DO LUA...</div>`;
    }
    if (prevRenderPremixRows15) return prevRenderPremixRows15();
    return rows.map((item) => `<div class="mixerRow premixMixerRow"><div class="mixerRowMain"><div class="mixerRowName">${esc15(item.name || item.label || 'ITEM')}</div></div></div>`).join('') || `<div class="emptyState" style="padding:18px;text-align:center;color:#cbd5e1;font-weight:900">SEM ITENS PARA ESSA MÚSICA</div>`;
  };

  const prevBind15 = typeof bindEvents === 'function' ? bindEvents : null;
  if (prevBind15) {
    bindEvents = function(){
      prevBind15();
      document.querySelectorAll('[data-action="mixer-volume-slider"]').forEach((el) => {
        const view = el.getAttribute('data-mixer-view') || state.mixerVolumeView || 'tracks';
        const id = el.getAttribute('data-mixer-id') || state.mixerSelectedId || '';
        const run = () => handleMixerVolumeInput(view, id, el.value);
        el.oninput = run;
        el.onchange = run;
      });
      document.querySelectorAll('[data-action="premix-volume-slider"]').forEach((el) => {
        const id = el.getAttribute('data-premix-track-id') || state.premixSelectedTrackId || '';
        const run = () => handlePremixVolumeInput('tracks', id, el.value);
        el.oninput = run;
        el.onchange = run;
      });
    };
  }
})();


/* VSHOOK_DIRECTOR_FIX18_LUA_COMMAND_FLATTEN_UI_HOLD
   - Premix: clique em música força tela de ITENS e pede lista ao Lua.
   - Mixer: snapshot velho não redesenha por cima do slider enquanto o usuário mexe.
   - Visual: master/grupos/tracks compactos no mobile. */
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX18_LUA_COMMAND_FLATTEN_UI_HOLD) return;
  window.__VSHOOK_DIRECTOR_FIX18_LUA_COMMAND_FLATTEN_UI_HOLD = true;

  const now18 = () => Date.now();
  const key18 = (v) => String(v ?? '').trim();
  const clamp18 = (v, fb = 0.5) => Math.max(0, Math.min(1, Number.isFinite(Number(v)) ? Number(v) : fb));
  const hasMixerHold18 = () => {
    const obj = window.__vshookDirectorMixerHold15 || {};
    const t = now18();
    return Object.keys(obj).some(k => obj[k] && Number(obj[k].until || 0) > t);
  };
  const hasPremixHold18 = () => {
    const obj = window.__vshookDirectorPremixHold15 || {};
    const t = now18();
    return Object.keys(obj).some(k => obj[k] && Number(obj[k].until || 0) > t);
  };
  function scheduleRender18(delay = 0) {
    clearTimeout(window.__vshookFix18RenderTimer || 0);
    window.__vshookFix18RenderTimer = setTimeout(() => { try { render?.(); } catch(e) {} }, delay);
  }
  function forceSliderDom18(selector, value) {
    try {
      document.querySelectorAll(selector).forEach((el) => {
        if (document.activeElement === el || el.matches(':active')) el.value = String(clamp18(value));
      });
    } catch(e) {}
  }

  // Reaplica render depois do sync antigo. Sem isso o prevSync renderiza o snapshot velho e o hold só fica no state.
  const prevSync18 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync18) {
    syncFromBridge = function(data) {
      const beforeMixerHold = hasMixerHold18();
      const beforePremixHold = hasPremixHold18();
      prevSync18(data);
      const afterMixerHold = hasMixerHold18();
      const afterPremixHold = hasPremixHold18();
      if ((state.showMixerModal || state.showMixerVolumeModal) && (beforeMixerHold || afterMixerHold)) {
        scheduleRender18(0);
      }
      if (state.showPremixModal && (beforePremixHold || afterPremixHold || state.premixView === 'tracks')) {
        scheduleRender18(0);
      }
    };
  }

  // Hold maior para cortar o vai-e-volta enquanto o Bridge ainda devolve estado antigo.
  if (typeof setMixerHold15 === 'function') {
    const oldSetMixerHold18 = setMixerHold15;
    setMixerHold15 = function(view, id, ratio) {
      oldSetMixerHold18(view, id, ratio);
      const k = (typeof mixerHoldKey15 === 'function') ? mixerHoldKey15(view, id) : `${view}:${id}`;
      window.__vshookDirectorMixerHold15 = window.__vshookDirectorMixerHold15 || {};
      window.__vshookDirectorMixerHold15[k] = { ratio: clamp18(ratio), until: now18() + 2600 };
    };
  }
  if (typeof setPremixHold15 === 'function') {
    const oldSetPremixHold18 = setPremixHold15;
    setPremixHold15 = function(songId, id, ratio) {
      oldSetPremixHold18(songId, id, ratio);
      const k = (typeof premixHoldKey15 === 'function') ? premixHoldKey15(songId, id) : `${songId}:${id}`;
      window.__vshookDirectorPremixHold15 = window.__vshookDirectorPremixHold15 || {};
      window.__vshookDirectorPremixHold15[k] = { ratio: clamp18(ratio), until: now18() + 2600 };
    };
  }

  const prevMixerInput18 = typeof handleMixerVolumeInput === 'function' ? handleMixerVolumeInput : null;
  if (prevMixerInput18) {
    handleMixerVolumeInput = function(view, id, value) {
      const ratio = clamp18(value);
      prevMixerInput18(view, id, ratio);
      forceSliderDom18('[data-action="mixer-volume-slider"]', ratio);
      scheduleRender18(0);
    };
  }

  const prevPremixInput18 = typeof handlePremixVolumeInput === 'function' ? handlePremixVolumeInput : null;
  if (prevPremixInput18) {
    handlePremixVolumeInput = function(view, id, value) {
      const ratio = clamp18(value);
      prevPremixInput18(view, id, ratio);
      forceSliderDom18('[data-action="premix-volume-slider"]', ratio);
      scheduleRender18(0);
    };
  }

  function findSong18(songId) {
    const id = key18(songId);
    const songs = (typeof getPremixSongs === 'function' ? getPremixSongs() : (Array.isArray(state.premixSongs) ? state.premixSongs : [])) || [];
    return songs.find((s) => [s?.id, s?.source_number, s?.sourceNumber, s?.number, s?.regionIndex, s?.luaRegionIndex, s?.region_index].map(key18).includes(id)) || {};
  }
  function songPayload18(songId) {
    const id = key18(songId);
    const song = findSong18(id);
    return {
      id, songId: id, selectedRegionId: id, regionId: id,
      luaRegionIndex: song?.luaRegionIndex ?? song?.regionIndex ?? song?.region_index,
      regionIndex: song?.regionIndex ?? song?.luaRegionIndex ?? song?.region_index,
      region_index: song?.region_index ?? song?.regionIndex ?? song?.luaRegionIndex,
      source_number: song?.source_number ?? song?.sourceNumber ?? song?.number,
      sourceNumber: song?.sourceNumber ?? song?.source_number ?? song?.number,
      startPos: song?.startPos ?? song?.start_pos ?? song?.start,
      start_pos: song?.start_pos ?? song?.startPos ?? song?.start,
      endPos: song?.endPos ?? song?.end_pos ?? song?.end,
      end_pos: song?.end_pos ?? song?.endPos ?? song?.end,
      name: song?.name ?? song?.label ?? '',
      requestTracks: '1', requestFull: '1', forceLuaPremix: true, routeToLua: true, luaControl: true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
  }

  // Força o comportamento correto no mobile: escolheu música => abre a tela de ITENS, não fica parado na lista.
  const prevSelectPremix18 = typeof selectPremixSong === 'function' ? selectPremixSong : null;
  selectPremixSong = function(id) {
    const songId = key18(id);
    if (!songId) return;
    state.premixIsGlobal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixSelectedSongId = songId;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixGroups = [];
    window.__vshookDirectorPremixRequest15 = { songId, until: now18() + 6000, tries: 0 };
    try { if (prevSelectPremix18) prevSelectPremix18(songId); } catch(e) {}
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixSelectedSongId = songId;
    postCommand?.('premix_item_focus_song', songPayload18(songId));
    setTimeout(() => postCommand?.('premix_item_focus_song', songPayload18(songId)), 120);
    setTimeout(() => postCommand?.('premix_item_focus_song', songPayload18(songId)), 420);
    setTimeout(() => postCommand?.('premix_item_focus_song', songPayload18(songId)), 900);
    if (typeof fastPollBridge === 'function') fastPollBridge(40);
    scheduleRender18(0);
  };

  // Captura o toque antes de qualquer bind antigo que só seleciona visualmente.
  document.addEventListener('click', function(ev) {
    const row = ev.target?.closest?.('[data-action="premix-song"][data-premix-song-id]');
    if (!row || !state.showPremixModal) return;
    ev.preventDefault();
    ev.stopPropagation();
    selectPremixSong(row.getAttribute('data-premix-song-id'));
  }, true);

  // Se já tem música selecionada e a tela está aberta, nunca fica numa coluna vazia à direita.
  const prevRenderPremix18 = typeof renderPremixModal === 'function' ? renderPremixModal : null;
  if (prevRenderPremix18) {
    renderPremixModal = function() {
      if (state.showPremixModal && key18(state.premixSelectedSongId) && state.premixView !== 'tracks') {
        state.premixView = 'tracks';
        state.premixTrackView = 'tracks';
      }
      return prevRenderPremix18();
    };
  }

  const prevRenderPremixRows18 = typeof renderPremixTrackRows === 'function' ? renderPremixTrackRows : null;
  if (prevRenderPremixRows18) {
    renderPremixTrackRows = function() {
      const rows = typeof getPremixItemsForView === 'function' ? getPremixItemsForView('tracks') : [];
      if ((!rows || !rows.length) && now18() < Number(window.__vshookDirectorPremixRequest15?.until || 0)) {
        return `<div class="emptyState" style="padding:18px;text-align:center;color:#cbd5e1;font-weight:900">CARREGANDO ITENS DO LUA...</div>`;
      }
      return prevRenderPremixRows18();
    };
  }

  // CSS final compacto e corrige container gigante do Master/Grupos.
  const style = document.createElement('style');
  style.textContent = `
    .mixerRowsBox{min-height:0!important;}
    .mixerModalBox .mixerRowsBox{height:auto!important;}
    .mixerRow{min-height:58px!important;height:auto!important;padding:8px 10px!important;gap:8px!important;}
    .mixerRowMain{min-width:0!important;}
    .mixerRowName{font-size:18px!important;line-height:1.1!important;}
    .mixerRowDb{min-width:42px!important;font-size:13px!important;}
    .mixerMiniBtn{width:42px!important;height:42px!important;min-width:42px!important;}
    .mixerViewTabs{gap:8px!important;margin:8px 0 10px!important;}
    .mixerViewTabs button{height:52px!important;min-height:52px!important;}
    .premixSongListBox{max-width:100%!important;width:100%!important;}
    .premixSongCard{width:100%!important;max-width:100%!important;}
    .premixInlineSlider{width:86px!important;max-width:28vw!important;}
    @media (max-width: 820px){
      .mixerModalBox,.premixModalBox{padding:24px!important;}
      .mixerRowsBox{max-height:calc(var(--app-vh,100dvh) - 250px)!important;}
      .mixerSwipePanel{flex:0 1 auto!important;min-height:0!important;}
    }
  `;
  document.head.appendChild(style);
})();

/* VSHOOK_DIRECTOR_FIX19_PREMIX_LIST_AND_FREE_SLIDERS
   - Premix abre SEMPRE na lista de músicas do repertório atual.
   - Voltar do Premix volta para lista e não fecha/trava.
   - Sliders de Mixer/Premix não redesenham a tela enquanto o dedo está arrastando.
   - Comando de volume é throttled e o envio final ocorre no soltar. */
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX19_PREMIX_LIST_AND_FREE_SLIDERS__) return;
  window.__VSHOOK_DIRECTOR_FIX19_PREMIX_LIST_AND_FREE_SLIDERS__ = true;

  const now19 = () => Date.now();
  const key19 = (v) => String(v ?? '').trim();
  const clamp19 = (v, fb = 0.5) => Math.max(0, Math.min(1, Number.isFinite(Number(v)) ? Number(v) : fb));
  const esc19 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(String(v ?? '')) : String(v ?? '').replace(/[&<>"]/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m])));
  const upper19 = (v) => (typeof upperText === 'function' ? upperText(String(v || '')) : String(v || '').toUpperCase());

  window.__vshookSliderDragging19 = window.__vshookSliderDragging19 || { active:false, until:0, pendingRender:false };
  function sliderActive19(){ return window.__vshookSliderDragging19.active || now19() < Number(window.__vshookSliderDragging19.until || 0); }
  function startSlider19(){ window.__vshookSliderDragging19.active = true; window.__vshookSliderDragging19.until = now19() + 1800; }
  function endSlider19(){
    window.__vshookSliderDragging19.active = false;
    window.__vshookSliderDragging19.until = now19() + 220;
    clearTimeout(window.__vshookSliderEndRender19 || 0);
    window.__vshookSliderEndRender19 = setTimeout(() => {
      window.__vshookSliderDragging19.until = 0;
      if (window.__vshookSliderDragging19.pendingRender) {
        window.__vshookSliderDragging19.pendingRender = false;
        try { window.__vshookRealRender19?.(); } catch(e) {}
      }
    }, 260);
  }

  if (typeof render === 'function' && !window.__vshookRealRender19) {
    window.__vshookRealRender19 = render;
    render = function(){
      if (sliderActive19()) {
        window.__vshookSliderDragging19.pendingRender = true;
        return '';
      }
      return window.__vshookRealRender19.apply(this, arguments);
    };
  }

  function rowId19(item, fallback) {
    return key19(item?.id || item?.guid || item?.trackId || item?.targetId || item?.itemId || item?.trackGuid || fallback);
  }
  function mixerList19(view) {
    if (view === 'groups') return Array.isArray(state.mixerGroups) ? state.mixerGroups : [];
    if (view === 'master') return state.mixerMaster ? [state.mixerMaster] : [];
    return Array.isArray(state.mixerTracks) ? state.mixerTracks : [];
  }
  function findMixer19(view, id) {
    const wanted = key19(id);
    if (!wanted) return null;
    if (typeof findMixerItem === 'function') {
      try { const found = findMixerItem(view, wanted); if (found) return found; } catch(e) {}
    }
    return mixerList19(view).find((item) => [item?.id,item?.guid,item?.trackId,item?.targetId].map(key19).includes(wanted)) || null;
  }
  function setMixerLocal19(view, id, ratio) {
    const wanted = key19(id);
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    const patch = { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale:'db' };
    if (typeof setMixerItemLocalState === 'function') { try { setMixerItemLocalState(view, wanted, patch); } catch(e) {} }
    const apply = (item) => [item?.id,item?.guid,item?.trackId,item?.targetId].map(key19).includes(wanted) ? { ...item, ...patch } : item;
    if (view === 'groups') state.mixerGroups = mixerList19('groups').map(apply);
    else if (view === 'master' && state.mixerMaster) state.mixerMaster = apply(state.mixerMaster);
    else state.mixerTracks = mixerList19('tracks').map(apply);
  }
  function postMixer19(view, id, ratio, finalSend=false) {
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const item = findMixer19(normalizedView, id) || {};
    const target = rowId19(item, id);
    const payload = {
      view: normalizedView, id: target, targetId: target,
      trackId: key19(item.trackId || item.guid || target), guid: key19(item.guid || target),
      ratio, volumeRatio: ratio, scrollRatio: ratio,
      routeToLua:true, luaControl:true, final: !!finalSend,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'mixer'
    };
    postCommand?.('mixer_set_volume', payload);
  }

  handleMixerVolumeInput = function(view, id, value, finalSend=false) {
    const normalizedView = view === 'groups' ? 'groups' : (view === 'master' ? 'master' : 'tracks');
    const ratio = clamp19(value, 0.5);
    const item = findMixer19(normalizedView, id) || {};
    const target = rowId19(item, id);
    startSlider19();
    try { if (typeof setMixerHold15 === 'function') setMixerHold15(normalizedView, target, ratio); } catch(e) {}
    setMixerLocal19(normalizedView, target, ratio);
    const input = document.querySelector(`[data-action="mixer-volume-slider"][data-mixer-id="${CSS.escape(String(id))}"]`) || document.querySelector('[data-action="mixer-volume-slider"]');
    if (input) input.value = String(ratio);
    clearTimeout(window.__vshookMixerSend19 || 0);
    if (finalSend) postMixer19(normalizedView, target, ratio, true);
    else window.__vshookMixerSend19 = setTimeout(() => postMixer19(normalizedView, target, ratio, false), 70);
  };

  function songIdFromSong19(song){ return key19(song?.id ?? song?.source_number ?? song?.sourceNumber ?? song?.number ?? song?.regionIndex ?? song?.luaRegionIndex ?? ''); }
  function isBlockSong19(song){ try { return typeof detectBlockItem === 'function' && detectBlockItem(song); } catch(e) { return false; } }
  function isParentSong19(song){ return !!(song && (song.isHashParent || song.familyRole === 'parent' || song.itemType === 'hash_parent' || song.type === 'hash_parent')); }
  function normalizeSongList19(list){
    return (Array.isArray(list) ? list : []).filter((song) => song && !isBlockSong19(song) && song.isPlayable !== false && !isParentSong19(song) && songIdFromSong19(song));
  }
  getPremixSongs = function(){
    const active = typeof getActivePlaylistSongsForPremix === 'function' ? normalizeSongList19(getActivePlaylistSongsForPremix()) : [];
    if (active.length) return active;
    const premix = normalizeSongList19(state.premixSongs);
    if (premix.length) return premix;
    return normalizeSongList19(state.regions);
  };
  if (typeof isPremixSelectableSong === 'function') {
    isPremixSelectableSong = function(song){ return !!songIdFromSong19(song) && !isBlockSong19(song) && song?.isPlayable !== false && !isParentSong19(song); };
  }

  const oldOpenPremix19 = typeof openPremixModal === 'function' ? openPremixModal : null;
  openPremixModal = function(){
    state.settingsMenuOpen = false;
    state.showGearModal = false;
    state.showMixerModal = false;
    state.showMixerVolumeModal = false;
    state.showPremixVolumeModal = false;
    state.showBpmModal = false;
    state.showTunerModal = false;
    state.showPremixModal = true;
    state.premixIsGlobal = false;
    state.premixView = 'songs';
    state.premixTrackView = 'tracks';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    state.premixTracks = [];
    state.premixGroups = [];
    try { armOverlayCloseGuard?.(650); } catch(e) {}
    postCommand?.('premix_item_open', { requestFull:'1', currentPlaylistOnly:true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix' });
    if (typeof fastPollBridge === 'function') fastPollBridge(8);
    try { window.__vshookRealRender19 ? window.__vshookRealRender19() : render?.(); } catch(e) {}
    return true;
  };
  openPremixFromMenu = function(event){ event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.(); return openPremixModal(); };

  backPremixSongList = function(event){
    event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.();
    state.premixView = 'songs';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixTracks = [];
    state.premixGroups = [];
    postCommand?.('premix_item_open', { requestFull:'1', currentPlaylistOnly:true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix' });
    if (typeof fastPollBridge === 'function') fastPollBridge(6);
    try { window.__vshookRealRender19 ? window.__vshookRealRender19() : render?.(); } catch(e) {}
    return false;
  };

  function songPayload19(songId) {
    const id = key19(songId);
    const song = getPremixSongs().find((s) => songIdFromSong19(s) === id) || {};
    return {
      id, songId:id, selectedRegionId:id, regionId:id,
      luaRegionIndex: song.luaRegionIndex ?? song.regionIndex ?? song.region_index,
      regionIndex: song.regionIndex ?? song.luaRegionIndex ?? song.region_index,
      source_number: song.source_number ?? song.sourceNumber ?? song.number,
      sourceNumber: song.sourceNumber ?? song.source_number ?? song.number,
      startPos: song.startPos ?? song.start_pos ?? song.start,
      endPos: song.endPos ?? song.end_pos ?? song.end,
      name: song.name ?? song.label ?? song.title ?? '',
      requestTracks:'1', requestItems:'1', requestFull:'1', forceLuaPremix:true, routeToLua:true, luaControl:true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
  }
  selectPremixSong = function(songId){
    const id = key19(songId);
    if (!id) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = id;
    state.selectedRegionId = id;
    state.selectedRegionIds = [id];
    state.selectedPlaylistSongId = null;
    state.selectedPlaylistSongIds = [];
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixTracks = [];
    state.premixGroups = [];
    window.__vshookDirectorPremixRequest15 = { songId:id, until: now19() + 7000, tries:0 };
    postCommand?.('premix_item_focus_song', songPayload19(id));
    setTimeout(() => postCommand?.('premix_item_focus_song', songPayload19(id)), 180);
    setTimeout(() => postCommand?.('premix_item_focus_song', songPayload19(id)), 520);
    if (typeof fastPollBridge === 'function') fastPollBridge(18);
    try { window.__vshookRealRender19 ? window.__vshookRealRender19() : render?.(); } catch(e) {}
  };

  function premixRows19(){ return (Array.isArray(state.premixTracks) ? state.premixTracks : []).filter(Boolean).map((item, index) => {
    const idRaw = key19(item.id || item.guid || item.itemId || item.trackId || item.targetId || `item-${index+1}`);
    const id = esc19(idRaw);
    const indexText = String(item.index ?? (index + 1)).padStart(2, '0');
    const rawName = item.name || item.label || item.trackName || item.itemName || item.takeName || `ITEM ${indexText}`;
    const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(rawName, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee') : esc19(rawName);
    const ratio = clamp19(item.volumeRatio ?? item.ratio ?? item.volume_ratio, 0.5);
    const db = esc19(typeof formatMixerDbLabel === 'function' ? formatMixerDbLabel(item.db ?? 0, ratio, item.displayScale) : String(item.db ?? ''));
    const muteClass = item.mute || item.muted ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn';
    const hasFx = !!(item.hasFx || Number(item.fxCount || 0) > 0 || item.fxEnabled !== undefined || item.fxOn !== undefined);
    const fxOn = item.fxEnabled !== false && item.fxOn !== false && hasFx;
    const fxClass = !hasFx ? 'mixerMiniBtn btnDisabled' : (fxOn ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn');
    return `<div class="mixerRow premixMixerRow premixMixerRowFix19" data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowIndex">${esc19(indexText)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div></div><div class="mixerRowDb">${db}</div><button class="${muteClass}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${id}">M</button><button class="${fxClass}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${id}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button><input class="premixInlineSlider premixInlineSliderFix19" type="range" min="0" max="1" step="0.001" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${id}" /></div>`;
  }).join(''); }

  renderPremixSongRows = function(){
    const songs = getPremixSongs();
    if (!songs.length) return '<div class="emptyBox">SEM MÚSICAS NO REPERTÓRIO ATUAL</div>';
    return songs.map((song) => {
      const id = songIdFromSong19(song);
      const selected = id && key19(state.premixSelectedSongId) === id;
      const title = song.name || song.label || song.title || song.displayName || song.sourceName || song.source_name || song.regionName || song.songName || `MÚSICA ${id}`;
      const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, 'premixSongTitleText', 'rowMarquee premixSongMarquee') : esc19(title);
      const duration = song.durationSec ? `<span class="premixSongDuration">${esc19(typeof formatTime === 'function' ? formatTime(song.durationSec) : song.durationSec)}</span>` : '';
      const color = typeof getAppItemTextColor === 'function' ? getAppItemTextColor(song) : '';
      const style = color ? ` style="--premix-row-color:${esc19(color)}"` : '';
      return `<div class="premixSongCard ${selected ? 'premixSongCardSelected selectedRow' : ''}"${style} data-action="premix-song" data-premix-song-id="${esc19(id)}"><div class="premixSongAccent"></div><div class="premixSongMain"><div class="premixSongTitle">${name}</div><div class="premixSongMeta">${duration}</div></div></div>`;
    }).join('');
  };
  renderPremixTrackRows = function(){
    const html = premixRows19();
    if (html) return html;
    if (now19() < Number(window.__vshookDirectorPremixRequest15?.until || 0)) return '<div class="emptyBox">CARREGANDO ITENS DO LUA...</div>';
    return '<div class="emptyBox">SEM ITENS NESSA MÚSICA</div>';
  };
  renderPremixModal = function(){
    if (!state.showPremixModal) return '';
    const isTracks = state.premixView === 'tracks' && key19(state.premixSelectedSongId);
    const selectedSong = getPremixSongs().find((song) => songIdFromSong19(song) === key19(state.premixSelectedSongId));
    const title = isTracks && selectedSong ? upper19(selectedSong.name || selectedSong.label || selectedSong.title || 'PREMIX') : 'PREMIX';
    const titleHtml = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee') : esc19(title);
    const content = isTracks
      ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px"><div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div><button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button></div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">ITENS</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
      : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button></div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div></div><div class="mixerRowsBox premixSongListBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`;
    return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`;
  };

  function premixItem19(id){
    const wanted = key19(id);
    return (Array.isArray(state.premixTracks) ? state.premixTracks : []).find((item) => [item?.id,item?.guid,item?.itemId,item?.trackId,item?.targetId].map(key19).includes(wanted)) || {};
  }
  function setPremixLocal19(id, ratio) {
    const wanted = key19(id);
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((item) => [item?.id,item?.guid,item?.itemId,item?.trackId,item?.targetId].map(key19).includes(wanted) ? { ...item, volumeRatio:ratio, liveVolumeRatio:ratio, ratio, db, displayScale:'db' } : item);
  }
  function premixPayload19(id, ratio, finalSend=false) {
    const item = premixItem19(id);
    const itemId = rowId19(item, id);
    return { ...songPayload19(state.premixSelectedSongId), itemId, targetId:itemId, trackId:key19(item.trackId || item.guid || itemId), guid:key19(item.guid || itemId), ratio, volumeRatio:ratio, scrollRatio:ratio, final:!!finalSend };
  }
  handlePremixVolumeInput = function(view, id, value, finalSend=false){
    const itemId = key19(id);
    const songId = key19(state.premixSelectedSongId);
    if (!itemId || !songId) return;
    const ratio = clamp19(value, 0.5);
    startSlider19();
    try { if (typeof setPremixHold15 === 'function') setPremixHold15(songId, itemId, ratio); } catch(e) {}
    setPremixLocal19(itemId, ratio);
    const input = document.querySelector(`[data-action="premix-volume-slider"][data-premix-track-id="${CSS.escape(String(id))}"]`);
    if (input) input.value = String(ratio);
    clearTimeout(window.__vshookPremixSend19 || 0);
    if (finalSend) postCommand?.('premix_item_set_volume', premixPayload19(itemId, ratio, true));
    else window.__vshookPremixSend19 = setTimeout(() => postCommand?.('premix_item_set_volume', premixPayload19(itemId, ratio, false)), 70);
  };

  document.addEventListener('pointerdown', (ev) => { if (ev.target?.matches?.('[data-action="mixer-volume-slider"], [data-action="premix-volume-slider"]')) startSlider19(); }, true);
  document.addEventListener('touchstart', (ev) => { if (ev.target?.matches?.('[data-action="mixer-volume-slider"], [data-action="premix-volume-slider"]')) startSlider19(); }, {capture:true, passive:true});
  document.addEventListener('pointerup', (ev) => {
    const el = ev.target?.closest?.('[data-action="mixer-volume-slider"], [data-action="premix-volume-slider"]');
    if (el) {
      if (el.getAttribute('data-action') === 'mixer-volume-slider') handleMixerVolumeInput(el.getAttribute('data-mixer-view') || state.mixerVolumeView || 'tracks', el.getAttribute('data-mixer-id') || state.mixerSelectedId || '', el.value, true);
      else handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || '', el.value, true);
    }
    endSlider19();
  }, true);
  document.addEventListener('touchend', (ev) => { endSlider19(); }, {capture:true, passive:true});
  document.addEventListener('input', function(ev){
    const el = ev.target?.closest?.('[data-action="mixer-volume-slider"], [data-action="premix-volume-slider"]');
    if (!el) return;
    ev.stopPropagation();
    ev.stopImmediatePropagation?.();
    startSlider19();
    if (el.getAttribute('data-action') === 'mixer-volume-slider') handleMixerVolumeInput(el.getAttribute('data-mixer-view') || state.mixerVolumeView || 'tracks', el.getAttribute('data-mixer-id') || state.mixerSelectedId || '', el.value, false);
    else handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || '', el.value, false);
  }, true);
  document.addEventListener('change', function(ev){
    const el = ev.target?.closest?.('[data-action="mixer-volume-slider"], [data-action="premix-volume-slider"]');
    if (!el) return;
    ev.stopPropagation();
    ev.stopImmediatePropagation?.();
    if (el.getAttribute('data-action') === 'mixer-volume-slider') handleMixerVolumeInput(el.getAttribute('data-mixer-view') || state.mixerVolumeView || 'tracks', el.getAttribute('data-mixer-id') || state.mixerSelectedId || '', el.value, true);
    else handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || '', el.value, true);
    endSlider19();
  }, true);
  document.addEventListener('click', function(ev){
    const back = ev.target?.closest?.('[data-action="premix-back"]');
    if (back && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); backPremixSongList(ev); return; }
    const row = ev.target?.closest?.('[data-action="premix-song"][data-premix-song-id]');
    if (row && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); selectPremixSong(row.getAttribute('data-premix-song-id')); }
  }, true);

  const style = document.createElement('style');
  style.id = 'vshook-director-fix19-style';
  style.textContent = `
    .premixInlineSliderFix19,.premixInlineSlider{flex:1 1 150px!important;width:150px!important;min-width:130px!important;max-width:42vw!important;height:42px!important;touch-action:pan-x!important;accent-color:#facc15!important;}
    .mixerVolumeSlider{width:100%!important;min-height:56px!important;height:56px!important;touch-action:pan-x!important;accent-color:#facc15!important;}
    .premixMixerRowFix19{grid-template-columns:34px minmax(0,1fr) 48px 42px 46px minmax(130px,42vw)!important;display:grid!important;align-items:center!important;}
    .premixSongListBox{width:100%!important;max-width:none!important;}
    .premixSongCard{width:100%!important;max-width:none!important;}
    .mixerRowsBox,.premixRowsBoxFull{overscroll-behavior:contain!important;}
    body.vshookDraggingSlider19 .mixerRowsBox{overflow:hidden!important;}
    @media (max-width:420px){.premixMixerRowFix19{grid-template-columns:28px minmax(0,1fr) 42px 38px 42px minmax(110px,38vw)!important;gap:5px!important}.premixInlineSliderFix19,.premixInlineSlider{min-width:110px!important;width:120px!important;}}
  `;
  document.head.appendChild(style);
})();


/* FIX20 - Premix: lista primeiro, ao clicar entra nos itens sem apagar as pistas; restaura comportamento do FIX18. */
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX20_PREMIX_RESTORE_ITEMS__) return;
  window.__VSHOOK_DIRECTOR_FIX20_PREMIX_RESTORE_ITEMS__ = true;

  const k20 = (v) => String(v ?? '').trim();
  const n20 = (v, f = 0.5) => { const n = Number(v); return Number.isFinite(n) ? n : f; };
  const c20 = (v, f = 0.5) => Math.max(0, Math.min(1, n20(v, f)));
  const esc20 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch])));
  const now20 = () => Date.now();

  function normalize20(item, index){
    if (!item || typeof item !== 'object') return null;
    let base = item;
    try {
      if (typeof normalizePremix15 === 'function') base = normalizePremix15(item, index);
      else if (typeof normalizePremixTrackItem === 'function') base = normalizePremixTrackItem(item, 'tracks');
    } catch(e) { base = item; }
    if (!base || typeof base !== 'object') return null;
    const id = k20(base.id || base.guid || base.itemId || base.trackId || base.targetId || `item-${index || 0}`);
    if (!id) return null;
    const name = k20(base.name || base.label || base.trackName || base.itemName || base.displayName || `ITEM ${index || ''}`);
    const ratio = c20(base.volumeRatio ?? base.liveVolumeRatio ?? base.ratio ?? base.volume_ratio, 0.5);
    return { ...base, id, guid:k20(base.guid || id), itemId:k20(base.itemId || id), targetId:k20(base.targetId || id), trackId:k20(base.trackId || base.trackGuid || base.guid || id), name, label:k20(base.label || name), volumeRatio:ratio, liveVolumeRatio:ratio, ratio, view:'tracks', type:'item', itemMode:true, displayScale:base.displayScale || 'db' };
  }

  function rowId20(item, fallback='') { return k20(item?.id || item?.guid || item?.itemId || item?.targetId || item?.trackId || fallback); }
  function songId20(song){ return k20(song?.id ?? song?.source_number ?? song?.sourceNumber ?? song?.number ?? song?.regionIndex ?? song?.luaRegionIndex ?? ''); }
  function block20(song){ try { return typeof detectBlockItem === 'function' && detectBlockItem(song); } catch(e) { return false; } }
  function parent20(song){ return !!(song && (song.isHashParent || song.familyRole === 'parent' || song.itemType === 'hash_parent' || song.type === 'hash_parent')); }
  function cleanSongs20(list){ return (Array.isArray(list) ? list : []).filter(s => s && !block20(s) && !parent20(s) && s.isPlayable !== false && songId20(s)); }

  getPremixSongs = function(){
    let active = [];
    try { if (typeof getActivePlaylistSongsForPremix === 'function') active = cleanSongs20(getActivePlaylistSongsForPremix()); } catch(e) {}
    if (active.length) return active;
    const premix = cleanSongs20(state.premixSongs);
    if (premix.length) return premix;
    return cleanSongs20(state.regions);
  };

  function cachedRows20(id){
    const keys = [k20(id)];
    const song = getPremixSongs().find(s => songId20(s) === k20(id));
    if (song) keys.push(k20(song.regionIndex), k20(song.luaRegionIndex), k20(song.source_number), k20(song.sourceNumber), k20(song.number));
    const maps = [state.premixTracksBySongId, state.premixTracksByRegionId, state.premixItemsBySongId, state.premixItemsByRegionId];
    for (const map of maps) {
      if (!map || typeof map !== 'object') continue;
      for (const key of keys) {
        if (key && Array.isArray(map[key]) && map[key].length) return map[key].map((x,i)=>normalize20(x,i+1)).filter(Boolean);
      }
    }
    const currentSel = k20(state.premixSelectedSongId || window.__vshookDirectorPremixRequest15?.songId);
    if (currentSel === k20(id) && Array.isArray(state.premixTracks) && state.premixTracks.length) return state.premixTracks.map((x,i)=>normalize20(x,i+1)).filter(Boolean);
    return [];
  }

  function temporaryRows20(id){
    const cached = cachedRows20(id);
    if (cached.length) return cached;
    // Último recurso visual: usa as pistas do Mixer apenas até o Lua devolver os ITENS reais.
    // Não salva isso como premix do Lua; é só para a tela não ficar vazia/travada.
    const mixer = Array.isArray(state.mixerTracks) ? state.mixerTracks : [];
    return mixer.map((x,i)=>normalize20({ ...x, type:'item', itemMode:true }, i+1)).filter(Boolean);
  }

  function payload20(id){
    const song = getPremixSongs().find(s => songId20(s) === k20(id)) || {};
    const sid = k20(id);
    return {
      id:sid, songId:sid, selectedRegionId:sid, regionId:sid,
      luaRegionIndex: song.luaRegionIndex ?? song.regionIndex ?? song.region_index,
      regionIndex: song.regionIndex ?? song.luaRegionIndex ?? song.region_index,
      region_index: song.region_index ?? song.regionIndex ?? song.luaRegionIndex,
      source_number: song.source_number ?? song.sourceNumber ?? song.number,
      sourceNumber: song.sourceNumber ?? song.source_number ?? song.number,
      startPos: song.startPos ?? song.start_pos ?? song.start,
      start_pos: song.start_pos ?? song.startPos ?? song.start,
      endPos: song.endPos ?? song.end_pos ?? song.end,
      end_pos: song.end_pos ?? song.endPos ?? song.end,
      name: song.name ?? song.label ?? song.title ?? '',
      requestTracks:'1', requestItems:'1', requestFull:'1', forceLuaPremix:true, routeToLua:true, luaControl:true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
  }

  openPremixModal = function(){
    state.settingsMenuOpen = false;
    state.showGearModal = false;
    state.showMixerModal = false;
    state.showMixerVolumeModal = false;
    state.showPremixVolumeModal = false;
    state.showBpmModal = false;
    state.showTunerModal = false;
    state.showPremixModal = true;
    state.premixIsGlobal = false;
    state.premixView = 'songs';
    state.premixTrackView = 'tracks';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    try { armOverlayCloseGuard?.(650); } catch(e) {}
    postCommand?.('premix_item_open', { requestFull:'1', requestTracks:'1', requestItems:'1', currentPlaylistOnly:true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix' });
    if (typeof fastPollBridge === 'function') fastPollBridge(12);
    render?.();
    return true;
  };
  openPremixFromMenu = function(event){ event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.(); return openPremixModal(); };

  selectPremixSong = function(id){
    const sid = k20(id);
    if (!sid) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = sid;
    state.selectedRegionId = sid;
    state.selectedRegionIds = [sid];
    state.selectedPlaylistSongId = null;
    state.selectedPlaylistSongIds = [];
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixGroups = [];

    const rows = temporaryRows20(sid);
    if (rows.length) state.premixTracks = rows;

    window.__vshookDirectorPremixRequest15 = { songId:sid, until: now20() + 9000, tries:0 };
    const p = payload20(sid);
    postCommand?.('premix_item_focus_song', p);
    postCommand?.('premix_focus_song', p);
    setTimeout(() => { if (k20(state.premixSelectedSongId) === sid) postCommand?.('premix_item_focus_song', payload20(sid)); }, 160);
    setTimeout(() => { if (k20(state.premixSelectedSongId) === sid) postCommand?.('premix_focus_song', payload20(sid)); }, 420);
    setTimeout(() => { if (k20(state.premixSelectedSongId) === sid) postCommand?.('premix_item_focus_song', payload20(sid)); }, 900);
    if (typeof fastPollBridge === 'function') fastPollBridge(40);
    render?.();
  };

  backPremixSongList = function(event){
    event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.();
    state.premixView = 'songs';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    if (typeof fastPollBridge === 'function') fastPollBridge(8);
    render?.();
    return false;
  };

  renderPremixSongRows = function(){
    const songs = getPremixSongs();
    if (!songs.length) return '<div class="emptyBox">SEM MÚSICAS NO REPERTÓRIO ATUAL</div>';
    return songs.map(song => {
      const id = songId20(song);
      const selected = id && k20(state.premixSelectedSongId) === id;
      const title = song.name || song.label || song.title || song.displayName || song.sourceName || song.regionName || song.songName || `MÚSICA ${id}`;
      const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, 'premixSongTitleText', 'rowMarquee premixSongMarquee') : esc20(title);
      const duration = song.durationSec ? `<span class="premixSongDuration">${esc20(typeof formatTime === 'function' ? formatTime(song.durationSec) : song.durationSec)}</span>` : '';
      return `<div class="premixSongCard ${selected ? 'premixSongCardSelected selectedRow' : ''}" data-action="premix-song" data-premix-song-id="${esc20(id)}"><div class="premixSongAccent"></div><div class="premixSongMain"><div class="premixSongTitle">${name}</div><div class="premixSongMeta">${duration}</div></div></div>`;
    }).join('');
  };

  renderPremixTrackRows = function(){
    const rows = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((x,i)=>normalize20(x,i+1)).filter(Boolean);
    if (!rows.length && now20() < Number(window.__vshookDirectorPremixRequest15?.until || 0)) return '<div class="emptyBox">CARREGANDO ITENS DO LUA...</div>';
    if (!rows.length) return '<div class="emptyBox">SEM ITENS NESSA MÚSICA</div>';
    return rows.map((item, index) => {
      const rawId = rowId20(item, `item-${index+1}`);
      const id = esc20(rawId);
      const idx = String(item.index ?? (index + 1)).padStart(2, '0');
      const title = item.name || item.label || item.trackName || item.itemName || `ITEM ${idx}`;
      const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee') : esc20(title);
      const ratio = c20(item.volumeRatio ?? item.liveVolumeRatio ?? item.ratio, 0.5);
      const db = esc20(typeof formatMixerDbLabel === 'function' ? formatMixerDbLabel(item.db ?? 0, ratio, item.displayScale) : String(item.db ?? ''));
      const muted = !!(item.mute || item.muted);
      const hasFx = !!(item.hasFx || Number(item.fxCount || 0) > 0 || item.fxEnabled !== undefined || item.fxOn !== undefined);
      const fxOn = hasFx && item.fxEnabled !== false && item.fxOn !== false;
      return `<div class="mixerRow premixMixerRow premixMixerRowFix20" data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowIndex">${esc20(idx)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div></div><div class="mixerRowDb">${db}</div><button class="${muted ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniMute' : 'mixerMiniBtn'}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${id}">M</button><button class="${!hasFx ? 'mixerMiniBtn btnDisabled' : (fxOn ? 'mixerMiniBtn mixerMiniBtnActive mixerMiniSolo' : 'mixerMiniBtn')}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${id}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button><input class="premixInlineSlider premixInlineSliderFix20" type="range" min="0" max="1" step="0.001" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${id}" /></div>`;
    }).join('');
  };

  renderPremixModal = function(){
    if (!state.showPremixModal) return '';
    const isTracks = state.premixView === 'tracks' && k20(state.premixSelectedSongId);
    const selectedSong = getPremixSongs().find(s => songId20(s) === k20(state.premixSelectedSongId));
    const title = isTracks && selectedSong ? (selectedSong.name || selectedSong.label || selectedSong.title || 'PREMIX') : 'PREMIX';
    const titleHtml = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee') : esc20(title);
    const content = isTracks
      ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px"><div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div><button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button></div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">ITENS</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
      : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button></div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div></div><div class="mixerRowsBox premixSongListBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`;
    return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`;
  };

  document.addEventListener('click', function(ev){
    const back = ev.target?.closest?.('[data-action="premix-back"]');
    if (back && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); backPremixSongList(ev); return; }
    const row = ev.target?.closest?.('[data-action="premix-song"][data-premix-song-id]');
    if (row && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); selectPremixSong(row.getAttribute('data-premix-song-id')); return; }
  }, true);

  const style = document.createElement('style');
  style.id = 'vshook-director-fix20-premix-style';
  style.textContent = `.premixMixerRowFix20{grid-template-columns:30px minmax(0,1fr) 46px 40px 44px minmax(125px,42vw)!important;display:grid!important;align-items:center!important;gap:6px!important}.premixInlineSliderFix20{min-width:125px!important;width:150px!important;max-width:42vw!important;height:42px!important;touch-action:pan-x!important;accent-color:#facc15!important}.premixSongCard{width:100%!important;max-width:none!important}@media(max-width:420px){.premixMixerRowFix20{grid-template-columns:26px minmax(0,1fr) 40px 36px 40px minmax(105px,38vw)!important}.premixInlineSliderFix20{min-width:105px!important;width:118px!important}}`;
  document.head.appendChild(style);
})();

/* FIX21 - Premix Diretor igual ao Lua: MÚSICAS -> PISTAS -> CONTROLE da pista; comandos diretos Lua; projeto muda aba no REAPER. */
(function(){
  if (window.__VSHOOK_DIRECTOR_FIX21_PREMIX_TRACK_CONTROL_PROJECT_TAB__) return;
  window.__VSHOOK_DIRECTOR_FIX21_PREMIX_TRACK_CONTROL_PROJECT_TAB__ = true;

  const k21 = (v) => String(v ?? '').trim();
  const esc21 = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch])));
  const clamp21 = (v, fb = 0.5) => {
    const n = Number(v);
    return Math.max(0, Math.min(1, Number.isFinite(n) ? n : fb));
  };
  const now21 = () => Date.now();

  function songId21(song) {
    return k21(song?.id ?? song?.source_number ?? song?.sourceNumber ?? song?.number ?? song?.regionIndex ?? song?.luaRegionIndex ?? '');
  }
  function isBlock21(song) {
    try { return typeof detectBlockItem === 'function' && detectBlockItem(song); } catch(e) { return false; }
  }
  function isParent21(song) {
    return !!(song && (song.isHashParent || song.familyRole === 'parent' || song.itemType === 'hash_parent' || song.type === 'hash_parent'));
  }
  function cleanSongs21(list) {
    return (Array.isArray(list) ? list : []).filter((song) => song && !isBlock21(song) && !isParent21(song) && song.isPlayable !== false && songId21(song));
  }

  getPremixSongs = function(){
    let active = [];
    try { if (typeof getActivePlaylistSongsForPremix === 'function') active = cleanSongs21(getActivePlaylistSongsForPremix()); } catch(e) {}
    if (active.length) return active;
    const premix = cleanSongs21(state.premixSongs);
    if (premix.length) return premix;
    return cleanSongs21(state.regions);
  };

  function selectedSong21(id = state.premixSelectedSongId) {
    const sid = k21(id);
    return getPremixSongs().find((song) => songId21(song) === sid) || {};
  }
  function payloadSong21(id = state.premixSelectedSongId) {
    const sid = k21(id);
    const song = selectedSong21(sid);
    return {
      id: sid,
      songId: sid,
      selectedRegionId: sid,
      regionId: sid,
      luaRegionIndex: song.luaRegionIndex ?? song.regionIndex ?? song.region_index,
      regionIndex: song.regionIndex ?? song.luaRegionIndex ?? song.region_index,
      region_index: song.region_index ?? song.regionIndex ?? song.luaRegionIndex,
      source_number: song.source_number ?? song.sourceNumber ?? song.number,
      sourceNumber: song.sourceNumber ?? song.source_number ?? song.number,
      startPos: song.startPos ?? song.start_pos ?? song.start,
      start_pos: song.start_pos ?? song.startPos ?? song.start,
      endPos: song.endPos ?? song.end_pos ?? song.end,
      end_pos: song.end_pos ?? song.endPos ?? song.end,
      name: song.name ?? song.label ?? song.title ?? '',
      requestTracks: '1',
      requestItems: '1',
      requestFull: '1',
      forceLuaPremix: true,
      routeToLua: true,
      luaControl: true,
      page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix'
    };
  }

  function normRow21(row, index = 0) {
    if (!row || typeof row !== 'object') return null;
    let base = row;
    try {
      if (typeof normalizePremix15 === 'function') base = normalizePremix15(row, index + 1);
      else if (typeof normalizePremixTrackItem === 'function') base = normalizePremixTrackItem(row, 'tracks');
    } catch(e) { base = row; }
    const id = k21(base.id || base.guid || base.itemId || base.targetId || base.trackId || `premix-${index}`);
    if (!id) return null;
    const name = k21(base.name || base.label || base.trackName || base.itemName || base.displayName || `PISTA ${index + 1}`);
    const ratio = clamp21(base.volumeRatio ?? base.liveVolumeRatio ?? base.ratio ?? base.volume_ratio, 0.5);
    return {
      ...base,
      id,
      guid: k21(base.guid || id),
      itemId: k21(base.itemId || id),
      targetId: k21(base.targetId || id),
      trackId: k21(base.trackId || base.trackGuid || base.guid || id),
      name,
      label: k21(base.label || name),
      volumeRatio: ratio,
      liveVolumeRatio: ratio,
      ratio,
      view: 'tracks',
      displayScale: base.displayScale || 'db'
    };
  }
  function rows21() {
    return (Array.isArray(state.premixTracks) ? state.premixTracks : []).map(normRow21).filter(Boolean);
  }
  function rowKey21(row, fallback = '') {
    return k21(row?.id || row?.guid || row?.itemId || row?.targetId || row?.trackId || fallback);
  }
  function findRow21(id) {
    const wanted = k21(id);
    return rows21().find((row) => [row.id, row.guid, row.itemId, row.targetId, row.trackId].map(k21).includes(wanted)) || null;
  }
  function setRowPatch21(id, patch) {
    const wanted = k21(id);
    if (!wanted) return;
    state.premixTracks = (Array.isArray(state.premixTracks) ? state.premixTracks : []).map((row, i) => {
      const r = normRow21(row, i);
      if (!r) return row;
      return [r.id, r.guid, r.itemId, r.targetId, r.trackId].map(k21).includes(wanted) ? { ...r, ...patch } : r;
    });
  }
  function postPremix21(type, rowId = '', extra = {}) {
    const sid = k21(state.premixSelectedSongId);
    const row = findRow21(rowId) || {};
    const rid = rowKey21(row, rowId);
    const payload = {
      ...payloadSong21(sid),
      itemId: rid,
      targetId: rid,
      trackId: k21(row.trackId || row.trackGuid || row.guid || rid),
      guid: k21(row.guid || rid),
      rowId: rid,
      ...extra
    };
    postCommand?.(type, payload);
    if (typeof fastPollBridge === 'function') fastPollBridge(12);
  }

  openPremixModal = function(){
    state.settingsMenuOpen = false;
    state.showGearModal = false;
    state.showMixerModal = false;
    state.showMixerVolumeModal = false;
    state.showPremixVolumeModal = false;
    state.showBpmModal = false;
    state.showTunerModal = false;
    state.showPremixModal = true;
    state.premixIsGlobal = false;
    state.premixView = 'songs';
    state.premixTrackView = 'tracks';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    state.premixTracks = [];
    state.premixGroups = [];
    try { armOverlayCloseGuard?.(650); } catch(e) {}
    postCommand?.('premix_item_open', { requestFull:'1', requestTracks:'1', requestItems:'1', currentPlaylistOnly:true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'premix' });
    if (typeof fastPollBridge === 'function') fastPollBridge(16);
    render?.();
    return true;
  };
  openPremixFromMenu = function(event){ event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.(); return openPremixModal(); };

  selectPremixSong = function(id){
    const sid = k21(id);
    if (!sid) return;
    const song = selectedSong21(sid);
    if (!song || !songId21(song)) return;
    state.premixIsGlobal = false;
    state.premixSelectedSongId = sid;
    state.selectedRegionId = sid;
    state.selectedRegionIds = [sid];
    state.selectedPlaylistSongId = null;
    state.selectedPlaylistSongIds = [];
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixView = 'tracks';
    state.premixTrackView = 'tracks';
    state.premixTracks = [];
    state.premixGroups = [];
    window.__vshookDirectorPremixRequest21 = { songId: sid, until: now21() + 9000 };
    const p = payloadSong21(sid);
    postCommand?.('premix_item_focus_song', p);
    postCommand?.('premix_focus_song', p);
    setTimeout(() => { if (k21(state.premixSelectedSongId) === sid) postCommand?.('premix_item_focus_song', payloadSong21(sid)); }, 180);
    setTimeout(() => { if (k21(state.premixSelectedSongId) === sid) postCommand?.('premix_item_focus_song', payloadSong21(sid)); }, 550);
    setTimeout(() => { if (k21(state.premixSelectedSongId) === sid) postCommand?.('premix_item_focus_song', payloadSong21(sid)); }, 1100);
    if (typeof fastPollBridge === 'function') fastPollBridge(40);
    render?.();
  };

  backPremixSongList = function(event){
    event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.();
    state.premixView = 'songs';
    state.premixSelectedSongId = null;
    state.premixSelectedTrackId = null;
    state.showPremixVolumeModal = false;
    state.premixTracks = [];
    render?.();
    return false;
  };

  renderPremixSongRows = function(){
    const songs = getPremixSongs();
    if (!songs.length) return '<div class="emptyBox">SEM MÚSICAS NO REPERTÓRIO ATUAL</div>';
    return songs.map((song) => {
      const id = songId21(song);
      const selected = id && k21(state.premixSelectedSongId) === id;
      const title = song.name || song.label || song.title || song.displayName || song.sourceName || song.regionName || song.songName || `MÚSICA ${id}`;
      const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, 'premixSongTitleText', 'rowMarquee premixSongMarquee') : esc21(title);
      const duration = song.durationSec ? `<span class="premixSongDuration">${esc21(typeof formatTime === 'function' ? formatTime(song.durationSec) : song.durationSec)}</span>` : '';
      return `<div class="premixSongCard ${selected ? 'premixSongCardSelected selectedRow' : ''}" data-action="premix-song" data-premix-song-id="${esc21(id)}"><div class="premixSongAccent"></div><div class="premixSongMain"><div class="premixSongTitle">${name}</div><div class="premixSongMeta">${duration}</div></div></div>`;
    }).join('');
  };

  renderPremixTrackRows = function(){
    const list = rows21();
    if (!list.length && now21() < Number(window.__vshookDirectorPremixRequest21?.until || 0)) return '<div class="emptyBox">CARREGANDO PISTAS DO LUA...</div>';
    if (!list.length) return '<div class="emptyBox">SEM PISTAS COM ITENS NESSA MÚSICA</div>';
    return list.map((item, index) => {
      const idRaw = rowKey21(item, `item-${index + 1}`);
      const id = esc21(idRaw);
      const idx = String(item.index ?? (index + 1)).padStart(2, '0');
      const title = item.name || item.label || item.trackName || item.itemName || `PISTA ${idx}`;
      const name = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'rowMarquee mixerNameMarquee premixTrackNameMarquee') : esc21(title);
      const ratio = clamp21(item.volumeRatio ?? item.liveVolumeRatio ?? item.ratio, 0.5);
      const db = esc21(typeof formatMixerDbLabel === 'function' ? formatMixerDbLabel(item.db ?? 0, ratio, item.displayScale) : String(item.db ?? ''));
      const muted = !!(item.mute || item.muted);
      const fxCount = Number(item.fxCount || 0);
      const hasFx = !!(item.hasFx || fxCount > 0 || item.fxEnabled !== undefined || item.fxOn !== undefined);
      const fxOn = hasFx && item.fxEnabled !== false && item.fxOn !== false;
      const sub = item.itemCount ? `<div class="mixerRowGroupName">${esc21(item.itemCount)} ITEM${Number(item.itemCount) === 1 ? '' : 'S'}${hasFx ? ' · FX ' + (fxOn ? 'ON' : 'OFF') : ''}${muted ? ' · MUTE' : ''}</div>` : '';
      return `<div class="mixerRow premixMixerRow premixTrackOnlyRowFix21" data-action="open-premix-volume" data-premix-view="tracks" data-premix-track-id="${id}" data-mixer-row-view="premix" data-mixer-row-id="${id}"><div class="mixerRowIndex">${esc21(idx)}</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div>${sub}</div><div class="mixerRowDb">${db}</div><div class="premixRowChevronFix21">›</div></div>`;
    }).join('');
  };

  openPremixVolumeModal = function(view, id){
    const row = findRow21(id);
    if (!row) return;
    state.showPremixVolumeModal = true;
    state.premixTrackView = 'tracks';
    state.premixSelectedTrackId = rowKey21(row, id);
    try { armOverlayCloseGuard?.(450); } catch(e) {}
    render?.();
  };
  closePremixVolumeModal = function(force = false){
    state.showPremixVolumeModal = false;
    state.premixSelectedTrackId = null;
    render?.();
  };
  renderPremixVolumeModal = function(){
    if (!state.showPremixVolumeModal || !state.premixSelectedTrackId) return '';
    const item = findRow21(state.premixSelectedTrackId);
    if (!item) return '';
    const id = rowKey21(item, state.premixSelectedTrackId);
    const title = item.name || item.label || item.trackName || item.itemName || 'PISTA';
    const ratio = clamp21(item.volumeRatio ?? item.liveVolumeRatio ?? item.ratio, 0.5);
    const muted = !!(item.mute || item.muted);
    const hasFx = !!(item.hasFx || Number(item.fxCount || 0) > 0 || item.fxEnabled !== undefined || item.fxOn !== undefined);
    const fxOn = hasFx && item.fxEnabled !== false && item.fxOn !== false;
    const db = esc21(typeof formatMixerDbLabel === 'function' ? formatMixerDbLabel(item.db ?? 0, ratio, item.displayScale) : String(item.db ?? ''));
    const nameHtml = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'rowMarquee mixerNameMarquee') : esc21(title);
    return `<div class="modalOverlay mixerVolumeOverlay premixVolumeOverlay" data-close-premix-volume style="z-index:3000;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerVolumeModalBox premixVolumeModalBoxFull premixControlBoxFix21" data-stop-modal data-mixer-volume-modal="1" style="position:relative;z-index:3001;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;overflow:hidden;border-radius:0;display:flex;flex-direction:column"><div class="mixerModalHeader"><div class="modalTitle">CONTROLE PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix-volume">VOLTAR</button></div><div class="premixControlTitleFix21">${nameHtml}</div><div class="premixControlButtonsFix21"><button class="${muted ? 'btnPlayActive premixControlMuteFix21' : 'btn premixControlMuteFix21'}" data-action="premix-mute" data-premix-view="tracks" data-premix-track-id="${esc21(id)}">M</button><button class="${!hasFx ? 'btnDisabled premixControlFxFix21' : (fxOn ? 'btnPlayActive premixControlFxFix21' : 'btn premixControlFxFix21')}" data-action="premix-phase" data-premix-view="tracks" data-premix-track-id="${esc21(id)}" ${hasFx ? '' : 'aria-disabled="true"'}>FX</button></div><div class="premixControlDbFix21">${db}</div><input class="mixerVolumeSlider premixControlSliderFix21" type="range" min="0" max="1" step="0.001" value="${ratio}" data-action="premix-volume-slider" data-premix-view="tracks" data-premix-track-id="${esc21(id)}" /><button class="modalCancelBtn premixResetFix21" data-action="premix-volume-reset" data-premix-view="tracks" data-premix-track-id="${esc21(id)}">RESET 0 dB</button></div></div>`;
  };

  renderPremixModal = function(){
    if (!state.showPremixModal) return '';
    const isTracks = state.premixView === 'tracks' && k21(state.premixSelectedSongId);
    const song = selectedSong21(state.premixSelectedSongId);
    const title = isTracks ? (song.name || song.label || song.title || 'PREMIX') : 'PREMIX';
    const titleHtml = typeof buildMarqueeText === 'function' ? buildMarqueeText(title, '', 'playlistTitleMarquee premixTitleMarquee') : esc21(title);
    const content = isTracks
      ? `<div class="mixerModalHeader premixFullHeader" style="gap:8px"><div class="modalTitle premixHeaderTitle" style="flex:1;min-width:0;overflow:hidden;white-space:nowrap">${titleHtml}</div><button class="modalCancelBtn mixerCloseBtn" data-action="premix-back">VOLTAR</button></div><div class="mixerSwipePanel" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto"><div class="sectionLabel mixerSectionLabel">PISTAS</div><div class="mixerRowsBox premixRowsBoxFull" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding-right:2px">${renderPremixTrackRows()}</div></div>`
      : `<div class="mixerModalHeader"><div class="modalTitle">PREMIX</div><button class="modalCancelBtn mixerCloseBtn" data-action="close-premix">FECHAR</button></div><div class="premixSongListHeader"><div class="sectionLabel mixerSectionLabel">MÚSICAS</div></div><div class="mixerRowsBox premixSongListBox" style="flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;padding-right:2px;margin-bottom:0;padding-bottom:0">${renderPremixSongRows()}</div>`;
    return `<div class="modalOverlay premixOverlay" data-close-premix style="z-index:2800;pointer-events:auto;align-items:stretch;justify-content:stretch;padding:0"><div class="modalBox mixerModalBox premixModalBox premixModalBoxFull" data-stop-modal style="display:flex;flex-direction:column;width:100vw;max-width:none;height:var(--app-vh,100dvh);max-height:none;min-height:0;overflow:hidden;pointer-events:auto;border-radius:0">${content}</div></div>`;
  };

  handlePremixTrackToggle = function(event, action, trackId, view = 'tracks'){
    event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.();
    const id = k21(trackId || state.premixSelectedTrackId);
    const row = findRow21(id);
    if (!row) return;
    if (action === 'mute') {
      const next = !(row.mute || row.muted);
      setRowPatch21(id, { mute: next, muted: next });
      postPremix21('premix_item_toggle_mute', id);
    } else if (action === 'phase' || action === 'fx') {
      const hasFx = !!(row.hasFx || Number(row.fxCount || 0) > 0 || row.fxEnabled !== undefined || row.fxOn !== undefined);
      if (!hasFx) return;
      const next = !(row.fxEnabled !== false && row.fxOn !== false);
      setRowPatch21(id, { fxEnabled: next, fxOn: next });
      postPremix21('premix_item_toggle_fx', id);
    }
    render?.();
  };

  function applyVolume21(id, ratio) {
    const db = typeof estimateMixerDisplayValueFromRatio === 'function' ? estimateMixerDisplayValueFromRatio(ratio, 0, 'db') : undefined;
    setRowPatch21(id, { volumeRatio: ratio, liveVolumeRatio: ratio, ratio, db, displayScale: 'db' });
    try { if (typeof setPremixHold15 === 'function') setPremixHold15(k21(state.premixSelectedSongId), id, ratio); } catch(e) {}
    const input = document.querySelector(`[data-action="premix-volume-slider"][data-premix-track-id="${CSS.escape(String(id))}"]`);
    if (input) input.value = String(ratio);
    const dbEl = document.querySelector('.premixControlDbFix21');
    if (dbEl && typeof formatMixerDbLabel === 'function') {
      const row = findRow21(id) || {};
      dbEl.textContent = formatMixerDbLabel(row.db ?? 0, ratio, row.displayScale);
    }
  }

  handlePremixVolumeInput = function(view, id, value, finalSend = false){
    const rid = k21(id || state.premixSelectedTrackId);
    if (!rid || !k21(state.premixSelectedSongId)) return;
    const ratio = clamp21(value, 0.5);
    applyVolume21(rid, ratio);
    clearTimeout(window.__vshookPremixSend21 || 0);
    const send = () => postPremix21('premix_item_set_volume', rid, { ratio, volumeRatio: ratio, scrollRatio: ratio, final: !!finalSend });
    if (finalSend) send(); else window.__vshookPremixSend21 = setTimeout(send, 55);
  };
  handlePremixVolumeReset = function(event, view, id){
    event?.preventDefault?.(); event?.stopPropagation?.(); event?.stopImmediatePropagation?.();
    const rid = k21(id || state.premixSelectedTrackId);
    const ratio = typeof getMixerZeroDbRatio === 'function' ? getMixerZeroDbRatio() : 0.76;
    handlePremixVolumeInput('tracks', rid, ratio, true);
    render?.();
  };

  // Projeto: ao tocar numa aba/projeto, já manda o REAPER trocar. OK continua mandando também.
  function sendProjectTab21(indexValue) {
    const idx = Number(indexValue);
    if (!Number.isFinite(idx)) return false;
    state.selectedProjectTabIndex = idx;
    state.activeProjectTabIndex = idx;
    const payload = { projectTabIndex: idx, index: idx, tabIndex: idx, projectIndex: idx, forceProjectTab: true, page: typeof getCurrentPcPageName === 'function' ? getCurrentPcPageName() : 'project' };
    postCommand?.('set_project_tab', payload);
    postCommand?.('select_project_tab', payload);
    if (typeof fastPollBridge === 'function') fastPollBridge(20);
    return true;
  }
  const oldSelectProjectTab21 = typeof selectProjectTabInModal === 'function' ? selectProjectTabInModal : null;
  selectProjectTabInModal = function(indexValue){
    if (oldSelectProjectTab21) { try { oldSelectProjectTab21(indexValue); } catch(e) {} }
    sendProjectTab21(indexValue);
    render?.();
  };
  confirmProjectTabsModal = function(){
    const idx = Number(state.selectedProjectTabIndex);
    state.showProjectTabsModal = false;
    render?.();
    if (Number.isFinite(idx)) sendProjectTab21(idx);
    if (typeof fastPollBridge === 'function') fastPollBridge(20);
  };

  document.addEventListener('click', function(ev){
    const back = ev.target?.closest?.('[data-action="premix-back"]');
    if (back && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); backPremixSongList(ev); return; }
    const song = ev.target?.closest?.('[data-action="premix-song"][data-premix-song-id]');
    if (song && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); selectPremixSong(song.getAttribute('data-premix-song-id')); return; }
    const row = ev.target?.closest?.('[data-action="open-premix-volume"],[data-premix-track-id].premixTrackOnlyRowFix21');
    if (row && state.showPremixModal && !ev.target?.closest?.('button,input')) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); openPremixVolumeModal('tracks', row.getAttribute('data-premix-track-id')); return; }
    const m = ev.target?.closest?.('[data-action="premix-mute"]');
    if (m && state.showPremixModal) { handlePremixTrackToggle(ev, 'mute', m.getAttribute('data-premix-track-id'), 'tracks'); return; }
    const fx = ev.target?.closest?.('[data-action="premix-phase"],[data-action="premix-fx"]');
    if (fx && state.showPremixModal) { handlePremixTrackToggle(ev, 'fx', fx.getAttribute('data-premix-track-id'), 'tracks'); return; }
    const reset = ev.target?.closest?.('[data-action="premix-volume-reset"]');
    if (reset && state.showPremixModal) { handlePremixVolumeReset(ev, 'tracks', reset.getAttribute('data-premix-track-id')); return; }
    const closeVol = ev.target?.closest?.('[data-action="close-premix-volume"]');
    if (closeVol && state.showPremixModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); closePremixVolumeModal(true); return; }
    const project = ev.target?.closest?.('[data-project-tab-index]');
    if (project && state.showProjectTabsModal) { ev.preventDefault(); ev.stopPropagation(); ev.stopImmediatePropagation?.(); selectProjectTabInModal(project.getAttribute('data-project-tab-index')); return; }
  }, true);

  document.addEventListener('input', function(ev){
    const el = ev.target?.closest?.('[data-action="premix-volume-slider"]');
    if (!el || !state.showPremixModal) return;
    ev.stopPropagation(); ev.stopImmediatePropagation?.();
    handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || state.premixSelectedTrackId || '', el.value, false);
  }, true);
  document.addEventListener('change', function(ev){
    const el = ev.target?.closest?.('[data-action="premix-volume-slider"]');
    if (!el || !state.showPremixModal) return;
    ev.stopPropagation(); ev.stopImmediatePropagation?.();
    handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || state.premixSelectedTrackId || '', el.value, true);
  }, true);
  document.addEventListener('pointerup', function(ev){
    const el = ev.target?.closest?.('[data-action="premix-volume-slider"]');
    if (!el || !state.showPremixModal) return;
    handlePremixVolumeInput('tracks', el.getAttribute('data-premix-track-id') || state.premixSelectedTrackId || '', el.value, true);
  }, true);

  const style = document.createElement('style');
  style.id = 'vshook-director-fix21-premix-style';
  style.textContent = `
    .premixTrackOnlyRowFix21{grid-template-columns:34px minmax(0,1fr) 54px 26px!important;display:grid!important;align-items:center!important;gap:8px!important;min-height:64px!important;touch-action:manipulation!important;}
    .premixTrackOnlyRowFix21 .mixerRowMain{min-width:0!important;}
    .premixRowChevronFix21{font-size:34px;font-weight:900;color:#93c5fd;line-height:1;text-align:center;}
    .premixControlBoxFix21{padding:22px!important;justify-content:flex-start!important;gap:18px!important;}
    .premixControlTitleFix21{min-height:58px;display:flex;align-items:center;justify-content:center;text-align:center;font-size:26px;font-weight:1000;color:#f8fafc;border:1px solid rgba(148,163,184,.32);border-radius:14px;background:rgba(15,23,42,.92);padding:10px;overflow:hidden;}
    .premixControlButtonsFix21{display:grid;grid-template-columns:1fr 1fr;gap:12px;width:100%;}
    .premixControlButtonsFix21 button{height:62px!important;border-radius:14px!important;font-size:26px!important;font-weight:1000!important;}
    .premixControlDbFix21{text-align:center;font-size:30px;font-weight:1000;color:#facc15;margin-top:10px;}
    .premixControlSliderFix21{width:100%!important;height:78px!important;min-height:78px!important;touch-action:pan-x!important;accent-color:#facc15!important;}
    .premixResetFix21{height:52px!important;border-radius:14px!important;background:#facc15!important;color:#111827!important;border-color:#facc15!important;font-weight:1000!important;}
  `;
  document.head.appendChild(style);
})();


/* VS_HOOK_DIRECTOR_FIX22_REMOVE_PREMIX_APP
   Premix foi removido do App Diretor. O Premix continua local no Lua.
   O Diretor fica com repertórios/músicas/letras via extensão e Mixer direto via extensão. */
(function(){
  const msg = 'Premix removido do App Diretor. Use o Premix direto no VS Hook.';
  function blockPremix(ev){
    const el = ev && ev.target && ev.target.closest ? ev.target.closest('[data-action="open-premix"],[data-action="open-premix-global"],[data-action^="premix"],[data-premix-track-id],[data-premix-song-id]') : null;
    if (!el) return;
    ev.preventDefault();
    ev.stopPropagation();
    if (ev.stopImmediatePropagation) ev.stopImmediatePropagation();
    try { if (typeof closePremixModal === 'function') closePremixModal(true); } catch(e) {}
    try { if (typeof showAppPopup === 'function') showAppPopup(msg, 'info', 1400); } catch(e) {}
    return false;
  }
  window.VSHOOK_DIRECTOR_PREMIX_DISABLED = true;
  try {
    openPremixModal = function(){ try { if (typeof showAppPopup === 'function') showAppPopup(msg, 'info', 1400); } catch(e) {} return false; };
    openPremixFromMenu = function(ev){ ev?.preventDefault?.(); ev?.stopPropagation?.(); try { if (typeof showAppPopup === 'function') showAppPopup(msg, 'info', 1400); } catch(e) {} return false; };
    openPremixGlobalModal = openPremixFromMenu;
    closePremixModal = function(){ if (state) { state.showPremixModal = false; state.showPremixVolumeModal = false; } return true; };
    renderPremixModal = function(){ return ''; };
    renderPremixVolumeModal = function(){ return ''; };
    if (state) { state.showPremixModal = false; state.showPremixVolumeModal = false; state.premixSelectedSongId = null; }
  } catch(e) {}
  document.addEventListener('click', blockPremix, true);
  document.addEventListener('pointerdown', blockPremix, true);
  const style = document.createElement('style');
  style.id = 'vshook-director-fix22-remove-premix';
  style.textContent = '[data-action="open-premix"],[data-action="open-premix-global"],.settingsActionPremix,.settingsActionPremixGlobal{display:none!important}.premixOverlay,.premixVolumeOverlay{display:none!important}';
  document.head.appendChild(style);
})();


// VS Hook FIX38 - Basic minimal/native app corrections
;(function(){
  try {
    const style = document.createElement('style')
    style.textContent = `
      .settingsBottomButtons{grid-template-columns:1fr 1fr!important;gap:10px!important}
      .settingsBottomButtons .settingsCloseButton{margin-left:0!important}
      .controlsRowDirectorMain{grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1fr)!important}
    `
    document.head && document.head.appendChild(style)
  } catch (error) {}
})();

// ==========================================================
// FIX75 - marker limpo sem overlays empilhados + timer progressivo com valor
// ==========================================================
(() => {
  if (window.__vshookFix75MarkerTimerCleanApplied) return;
  window.__vshookFix75MarkerTimerCleanApplied = true;

  const MARKER_ARM_MAX_MS = 120000;
  const MARKER_REACHED_TOLERANCE = 0.045;
  const S75 = (value) => {
    const s = String(value ?? '').trim();
    return (!s || s === 'null' || s === 'undefined') ? '' : s;
  };
  const N75 = (...values) => {
    for (const value of values) {
      const n = Number(value);
      if (Number.isFinite(n)) return n;
    }
    return Number.NaN;
  };

  let armedMarkerId75 = '';
  let armedMarkerTarget75 = Number.NaN;
  let armedMarkerStartedAt75 = 0;

  function listMarkers75() {
    try { if (typeof currentMarkers === 'function') return currentMarkers() || []; } catch (_) {}
    return Array.isArray(state.markers) ? state.markers : [];
  }
  function markerId75(item) {
    return S75(item?.id ?? item?.markerId ?? item?.originalIndex ?? item?.original_index ?? item?.index);
  }
  function findMarker75(id) {
    const key = S75(id);
    if (!key) return null;
    return listMarkers75().find((m) => markerId75(m) === key) || null;
  }
  function markerTarget75(id, fallback) {
    const m = findMarker75(id);
    return N75(m?.timeSec, m?.pos, m?.position, m?.startPos, m?.start_pos, fallback);
  }
  function playbackPosition75() {
    let pos = N75(state.playPosition, state.playPositionSec, state.currentPlayPosition, state.transportPosition, state.transportPositionSec, state.playbackPosition, state.playbackPositionSec);
    if (Number.isFinite(pos)) return pos;
    const start = N75(state.currentSongStart, state.playbackStartPos, state.playingStartPos);
    let elapsed = Number.NaN;
    try { if (typeof getCurrentPlayingElapsedSec === 'function') elapsed = Number(getCurrentPlayingElapsedSec()); } catch (_) {}
    try { if (!Number.isFinite(elapsed) && typeof getPlaybackElapsedSec === 'function') elapsed = Number(getPlaybackElapsedSec()); } catch (_) {}
    if (!Number.isFinite(elapsed)) elapsed = N75(state.playbackElapsedSec, state.currentSongElapsedSec, state.elapsedSec);
    if (Number.isFinite(start) && Number.isFinite(elapsed)) return start + elapsed;
    return Number.NaN;
  }
  function clearMarkerHolds75() {
    try { clearDirectorMarkerArmedLocalHold?.(); } catch (_) {}
    try { clearDirectorMarkerLocalHold?.(); } catch (_) {}
    try { if (typeof directorMarkerLocalHoldId !== 'undefined') directorMarkerLocalHoldId = null; } catch (_) {}
    try { if (typeof directorMarkerLocalHoldUntil !== 'undefined') directorMarkerLocalHoldUntil = 0; } catch (_) {}
    try { if (typeof directorMarkerArmedLocalHoldId !== 'undefined') directorMarkerArmedLocalHoldId = null; } catch (_) {}
    try { if (typeof directorMarkerArmedLocalHoldUntil !== 'undefined') directorMarkerArmedLocalHoldUntil = 0; } catch (_) {}
  }
  function clearMarkerVisual75() {
    armedMarkerId75 = '';
    armedMarkerTarget75 = Number.NaN;
    armedMarkerStartedAt75 = 0;
    state.markerGoFlashId = null;
    state.markerGoFlashStartedAtMs = 0;
    state.markerGoFlashForceUntil = 0;
    state.markerGoFlashTargetSec = null;
    state.selectedMarkerId = null;
    clearMarkerHolds75();
  }
  function armMarkerVisual75(id, target) {
    const key = S75(id);
    if (!key) return false;
    armedMarkerId75 = key;
    armedMarkerTarget75 = markerTarget75(key, target);
    armedMarkerStartedAt75 = Date.now();
    state.markerGoFlashId = key;
    state.selectedMarkerId = key;
    state.markerGoFlashStartedAtMs = armedMarkerStartedAt75;
    state.markerGoFlashForceUntil = Date.now() + MARKER_ARM_MAX_MS;
    state.markerGoFlashTargetSec = Number.isFinite(armedMarkerTarget75) ? armedMarkerTarget75 : null;
    try { setDirectorMarkerLocalHold?.(key, MARKER_ARM_MAX_MS); } catch (_) {}
    try { setDirectorMarkerArmedLocalHold?.(key, MARKER_ARM_MAX_MS); } catch (_) {}
    return true;
  }
  function reachedMarkerTarget75() {
    const key = S75(armedMarkerId75 || state.markerGoFlashId);
    if (!key) return false;
    let target = Number(armedMarkerTarget75);
    if (!Number.isFinite(target)) target = markerTarget75(key, state.markerGoFlashTargetSec);
    if (!Number.isFinite(target)) return false;
    armedMarkerTarget75 = target;
    const pos = playbackPosition75();
    if (!Number.isFinite(pos)) return false;
    return pos >= target - MARKER_REACHED_TOLERANCE;
  }
  function clearIfReached75() {
    if (S75(armedMarkerId75 || state.markerGoFlashId) && reachedMarkerTarget75()) {
      clearMarkerVisual75();
      return true;
    }
    if (S75(armedMarkerId75 || state.markerGoFlashId) && armedMarkerStartedAt75 && Date.now() - armedMarkerStartedAt75 > MARKER_ARM_MAX_MS) {
      clearMarkerVisual75();
      return true;
    }
    return false;
  }

  getDirectorMarkerArmedVisualId = function() {
    clearIfReached75();
    return S75(armedMarkerId75 || state.markerGoFlashId);
  };
  shouldShowDirectorMarkerCancelButton = function() {
    if (typeof isMarkersPanelOpen === 'function' && !isMarkersPanelOpen()) return false;
    clearIfReached75();
    return !!S75(armedMarkerId75 || state.markerGoFlashId);
  };
  isMarkerBlinking = function(item) {
    if (!item) return false;
    if (clearIfReached75()) return false;
    const id = markerId75(item);
    const armed = S75(armedMarkerId75 || state.markerGoFlashId);
    return !!(id && armed && id === armed);
  };
  handleMarkerCancel = function() {
    clearMarkerVisual75();
    try { postCommand('marker_cancel', { key: 'ESC', escapeKey: true, activeTab: 'playlist', page: 'markers', cancelMarker: true }); } catch (_) {}
    try { showAppPopup?.('MARKER CANCELADO', 'error', 1000); } catch (_) {}
    try { render?.(); } catch (_) {}
    return true;
  };

  const previousSelectMarker75 = typeof selectMarker === 'function' ? selectMarker : null;
  if (previousSelectMarker75 && !previousSelectMarker75.__fix75Wrapped) {
    selectMarker = function(id) {
      const key = S75(id);
      if (!key) return;
      if (S75(armedMarkerId75 || state.markerGoFlashId) && key !== S75(armedMarkerId75 || state.markerGoFlashId)) {
        clearMarkerVisual75();
      }
      const wasSelected = !!(key && (S75(state.selectedMarkerId) === key || S75(state.markerGoFlashId) === key || S75(armedMarkerId75) === key || (typeof isDirectorMarkerLocallyHeld === 'function' && isDirectorMarkerLocallyHeld(key))));
      const result = previousSelectMarker75.apply(this, arguments);
      if (wasSelected) {
        const m = findMarker75(key);
        armMarkerVisual75(key, m?.timeSec ?? m?.pos ?? m?.position);
      }
      return result;
    };
    selectMarker.__fix75Wrapped = true;
  }

  const previousSync75 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (previousSync75 && !previousSync75.__fix75Wrapped) {
    syncFromBridge = function(data) {
      const result = previousSync75.apply(this, arguments);
      try {
        if (data && typeof data === 'object') {
          const incoming = S75(data.markerGoId ?? data.armedMarkerId ?? data.markerGoFlashId);
          const hasMarkerField = Object.prototype.hasOwnProperty.call(data, 'markerGoId') || Object.prototype.hasOwnProperty.call(data, 'armedMarkerId') || Object.prototype.hasOwnProperty.call(data, 'markerGoFlashId');
          const target = N75(data.selectedMarkerPos, data.markerGoPos, data.armedMarkerPos);
          if (incoming) {
            armMarkerVisual75(incoming, target);
          } else if (hasMarkerField || data.markerReached === true || data.markerCancelled === true || data.markerCanceled === true) {
            clearMarkerVisual75();
          } else {
            clearIfReached75();
          }
          if (data.selectedMarkerId === null || data.selectedMarkerId === '') {
            if (!incoming) clearMarkerVisual75();
          }
        }
      } catch (_) {}
      return result;
    };
    syncFromBridge.__fix75Wrapped = true;
  }

  syncDirectorMarkerArmedVisualWithPlayback = function() {
    return clearIfReached75();
  };

  // Timer: sempre manda o valor atual do cronômetro progressivo para o Lua.
  function timerValue75() {
    const max = 99 * 3600 + 59 * 60 + 59;
    try { if (typeof getTimerElapsedSec === 'function') return Math.max(0, Math.min(max, Math.floor(Number(getTimerElapsedSec()) || 0))); } catch (_) {}
    const display = N75(state.timerDisplaySec, state.timerElapsedSec, state.timerAccumulatedSec);
    if (Number.isFinite(display)) return Math.max(0, Math.min(max, Math.floor(display)));
    return 0;
  }
  const previousPostCommand75 = typeof postCommand === 'function' ? postCommand : null;
  if (previousPostCommand75 && !previousPostCommand75.__fix75Wrapped) {
    postCommand = function(type, payload = {}) {
      const t = String(type || '');
      const isTimer = t === 'timer_toggle' || t === 'timer_start' || t === 'timer_stop' || t === 'timer_stop_reset' || t === 'timer_reset' || t === 'timer_set_mode' || t === 'timer_config';
      if (isTimer) {
        const data = payload && typeof payload === 'object' ? { ...payload } : {};
        const mode = normalizeDirectorTimerMode(data.timerMode || data.mode || state.timerMode || 'progressive');
        const value = timerValue75();
        data.timerMode = mode;
        data.mode = mode;
        data.timerValueSec = value;
        data.timerElapsedSec = value;
        data.elapsedSec = value;
        data.timerAccumulatedSec = value;
        if (mode === 'progressive') {
          data.timerProgressiveSec = value;
          data.progressiveSec = value;
        } else {
          const target = Number(data.timerTargetSec ?? data.targetSec ?? data.seconds ?? state.timerTargetSec ?? 0) || 0;
          data.timerTargetSec = target;
          data.targetSec = target;
          data.seconds = target;
        }
        return previousPostCommand75.call(this, type, data);
      }
      return previousPostCommand75.apply(this, arguments);
    };
    postCommand.__fix75Wrapped = true;
  }

  // Tuner continua removido do Diretor para este lançamento.
  try {
    openTunerModal = function(){ return false; };
    closeTunerModal = function(){ if (state) state.showTunerModal = false; return true; };
    renderTunerModal = function(){ return ''; };
    handleTunerAdjust = function(){ return false; };
    handleTunerReset = function(){ return false; };
    if (state) { state.showTunerModal = false; state.tunerModeActive = false; }
    const style = document.createElement('style');
    style.id = 'vshook-fix75-remove-tuner';
    style.textContent = '[data-action="open-tuner"],.settingsActionTuner,.tunerOverlay,.tunerDrawer{display:none!important}';
    document.head.appendChild(style);
  } catch (_) {}
})();


/* VS_HOOK_FIX83_DIRECTOR_ACTIVE_AND_QUEUE_STOP
   - Mantém heartbeat vivo para a extensão/Lua mostrar "APP DO DIRETOR ATIVO".
   - Mantém a fila local do Diretor até Stop/clear real, sem expirar em 12s.
   - Stop com fila seleciona imediatamente a música da fila e manda dados completos. */
(function(){
  if (window.__vshookFix83DirectorActiveQueueStopInstalled) return;
  window.__vshookFix83DirectorActiveQueueStopInstalled = true;
  const FIX83_QUEUE_TTL_MS = 30 * 60 * 1000;
  const FIX83_HEARTBEAT_MS = 650;
  let fix83LastHeartbeatAt = 0;
  let fix83ExplicitQueueClearUntil = 0;

  function fix83Str(v){ return v == null ? '' : String(v); }
  function fix83Now(){ return Date.now(); }
  function fix83CanHeartbeat(){
    try {
      if (window.__vshookDirectorLogoutInProgress) return false;
      if (fix83Now() < Number(window.__vshookDirectorHeartbeatBlockedUntil || 0)) return false;
      if (typeof needsAuthGate === 'function' && needsAuthGate()) return false;
      if (state && state.authEnabled && !state.authAuthenticated) return false;
      return true;
    } catch(e) { return true; }
  }

  function fix83DirectCommand(type, payload){
    if (!type) return;
    const now = fix83Now();
    const body = JSON.stringify({
      type,
      payload: {
        heartbeat: true,
        role: 'director',
        clientRole: 'director',
        appRole: 'director',
        source: 'director',
        mode: 'director',
        desiredState: 'active',
        authAuthenticated: '1',
        issuedAtMs: now,
        clientCommandId: `${now}-${type}-fix83-${Math.random().toString(16).slice(2, 8)}`,
        ...(payload && typeof payload === 'object' ? payload : {})
      }
    });
    try {
      const url = typeof vshookBridgeUrl === 'function' ? vshookBridgeUrl('/command') : '/command';
      fetch(url, { method:'POST', headers:{'Content-Type':'application/json'}, body, cache:'no-store' }).catch(function(){});
    } catch(e) {}
  }

  function fix83SendDirectorHeartbeat(force){
    if (!fix83CanHeartbeat()) return;
    const now = fix83Now();
    if (!force && (now - fix83LastHeartbeatAt) < FIX83_HEARTBEAT_MS) return;
    fix83LastHeartbeatAt = now;
    if (state) {
      state.appActive = true;
      state.directorAppActive = true;
      state.nativeBridgeConnected = state.nativeBridgeConnected || state.bridgeStatus === 'online';
    }
    fix83DirectCommand('director_heartbeat', { appActive:true, directorAppActive:true, directorActive:true });
  }

  const prevSendAppHeartbeatFix83 = typeof sendAppHeartbeat === 'function' ? sendAppHeartbeat : null;
  if (prevSendAppHeartbeatFix83) {
    sendAppHeartbeat = function(){
      try { prevSendAppHeartbeatFix83.apply(this, arguments); } catch(e) {}
      fix83SendDirectorHeartbeat(false);
    };
  }

  window.addEventListener('focus', function(){ fix83SendDirectorHeartbeat(true); }, { passive:true });
  document.addEventListener('visibilitychange', function(){ if (!document.hidden) fix83SendDirectorHeartbeat(true); }, { passive:true });
  document.addEventListener('pointerdown', function(){ fix83SendDirectorHeartbeat(true); }, { passive:true, capture:true });
  document.addEventListener('touchstart', function(){ fix83SendDirectorHeartbeat(true); }, { passive:true, capture:true });
  setInterval(function(){ fix83SendDirectorHeartbeat(false); }, FIX83_HEARTBEAT_MS);
  setTimeout(function(){ fix83SendDirectorHeartbeat(true); }, 80);
  setTimeout(function(){ fix83SendDirectorHeartbeat(true); }, 650);
  setTimeout(function(){ fix83SendDirectorHeartbeat(true); }, 1500);

  const prevSetLocalQueuedSongFix83 = typeof setLocalQueuedSong === 'function' ? setLocalQueuedSong : null;
  if (prevSetLocalQueuedSongFix83) {
    setLocalQueuedSong = function(id, tab){
      const key = fix83Str(id);
      const r = prevSetLocalQueuedSongFix83.apply(this, arguments);
      if (key) {
        state.localQueuedSongId = key;
        state.localQueuedSongAt = fix83Now();
        state.localQueuedSongTab = tab || state.activeTab || state.localQueuedSongTab || null;
        state.localQueuedSongHoldUntil = fix83Now() + FIX83_QUEUE_TTL_MS;
      }
      return r;
    };
  }

  const prevClearVisualQueueForDirectorFix83 = typeof clearVisualQueueForDirector === 'function' ? clearVisualQueueForDirector : null;
  if (prevClearVisualQueueForDirectorFix83) {
    clearVisualQueueForDirector = function(ms){
      fix83ExplicitQueueClearUntil = fix83Now() + 2500;
      state.localQueuedSongHoldUntil = 0;
      return prevClearVisualQueueForDirectorFix83.apply(this, arguments);
    };
  }

  if (typeof getLocalQueuedSongIdForRows === 'function') {
    getLocalQueuedSongIdForRows = function(){
      const key = fix83Str(state.localQueuedSongId);
      if (!key) return null;
      const at = Number(state.localQueuedSongAt || 0);
      const holdUntil = Number(state.localQueuedSongHoldUntil || 0) || (at + FIX83_QUEUE_TTL_MS);
      if (fix83Now() <= holdUntil) return key;
      if (typeof clearLocalQueuedSong === 'function') clearLocalQueuedSong();
      return null;
    };
  }

  if (typeof getExplicitQueuedSongId === 'function') {
    getExplicitQueuedSongId = function(){
      const key = fix83Str(state.localQueuedSongId);
      if (key) {
        const at = Number(state.localQueuedSongAt || 0);
        const holdUntil = Number(state.localQueuedSongHoldUntil || 0) || (at + FIX83_QUEUE_TTL_MS);
        if (fix83Now() <= holdUntil && (!isDirectorQueuedIdAllowed || isDirectorQueuedIdAllowed(key))) return key;
      }
      if (fix83Now() >= Number(remoteQueuedIgnoreUntil || 0) && state.queuedSongId != null && fix83Str(state.queuedSongId) !== '') {
        const q = fix83Str(state.queuedSongId);
        if (!isDirectorQueuedIdAllowed || isDirectorQueuedIdAllowed(q)) return q;
      }
      return null;
    };
  }

  function fix83FindItem(id){
    const key = fix83Str(id);
    if (!key) return null;
    try { if (typeof findSongByIdEverywhere === 'function') { const x = findSongByIdEverywhere(key); if (x) return x; } } catch(e) {}
    try { if (typeof findAnyPlaybackItemById === 'function') { const x = findAnyPlaybackItemById(key); if (x) return x; } } catch(e) {}
    return null;
  }

  function fix83PreferredTab(id, fallback){
    try { if (typeof getPreferredStoppedSelectionTab === 'function') return getPreferredStoppedSelectionTab(id, fallback || state.activeTab || 'playlist'); } catch(e) {}
    const item = fix83FindItem(id);
    if (item && Array.isArray(state.regions) && state.regions.includes(item)) return 'regions';
    return fallback || state.activeTab || 'playlist';
  }

  const prevGetDirectorStopSelectionTargetFix83 = typeof getDirectorStopSelectionTarget === 'function' ? getDirectorStopSelectionTarget : null;
  if (prevGetDirectorStopSelectionTargetFix83) {
    getDirectorStopSelectionTarget = function(stoppedId, preferredTab){
      const explicit = typeof getExplicitQueuedSongId === 'function' ? getExplicitQueuedSongId() : null;
      if (explicit) {
        const item = fix83FindItem(explicit);
        if (!item || !(typeof detectBlockItem === 'function' && detectBlockItem(item)) && !(typeof isHashChildItem === 'function' && isHashChildItem(item))) {
          return { id: fix83Str(explicit), tab: state.localQueuedSongTab || fix83PreferredTab(explicit, preferredTab || state.activeTab || 'playlist'), fromQueue:true, source:'manual_queue' };
        }
      }
      const r = prevGetDirectorStopSelectionTargetFix83.apply(this, arguments);
      if (r && r.id) return r;
      try {
        if (typeof getNextAutoQueuedSongId === 'function') {
          const autoId = getNextAutoQueuedSongId({ allowAutoBlocoBoundary:false });
          if (autoId) return { id: fix83Str(autoId), tab: fix83PreferredTab(autoId, preferredTab || state.activeTab || 'playlist'), fromQueue:true, source:'auto_queue' };
        }
      } catch(e) {}
      return r;
    };
  }

  const prevPostPlaybackToggleCommandFix83 = typeof postPlaybackToggleCommand === 'function' ? postPlaybackToggleCommand : null;
  if (prevPostPlaybackToggleCommandFix83) {
    postPlaybackToggleCommand = function(targetId, sourceTab, desiredPlaying, extraPayload){
      if (!desiredPlaying && extraPayload && extraPayload.stopSelectionTargetId != null && fix83Str(extraPayload.stopSelectionTargetId) !== '') {
        const stopId = fix83Str(extraPayload.stopSelectionTargetId);
        const item = fix83FindItem(stopId);
        if (item && typeof item === 'object') {
          const start = Number(item.startPos ?? item.start_pos);
          const end = Number(item.endPos ?? item.end_pos);
          const idx = Number(item.index);
          extraPayload = { ...extraPayload };
          extraPayload.queuedSelectionId = stopId;
          extraPayload.nextSelectionId = stopId;
          extraPayload.targetSelectionId = stopId;
          extraPayload.stopSelectionTargetTab = extraPayload.stopSelectionTargetTab || fix83PreferredTab(stopId, sourceTab || state.activeTab || 'playlist');
          if (Number.isFinite(start)) extraPayload.stopSelectionStartPos = start;
          if (Number.isFinite(end)) extraPayload.stopSelectionEndPos = end;
          if (Number.isFinite(idx)) extraPayload.stopSelectionPlaylistIndex = idx;
          if (item.source_number != null) extraPayload.stopSelectionSourceNumber = String(item.source_number);
          if (item.sourceNumber != null) extraPayload.stopSelectionSourceNumber = String(item.sourceNumber);
          if (item.uid != null) extraPayload.stopSelectionUid = String(item.uid);
        }
      }
      return prevPostPlaybackToggleCommandFix83.call(this, targetId, sourceTab, desiredPlaying, extraPayload);
    };
  }

  const prevSyncFromBridgeFix83 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSyncFromBridgeFix83) {
    syncFromBridge = function(data){
      const savedId = fix83Str(state.localQueuedSongId);
      const savedAt = Number(state.localQueuedSongAt || 0);
      const savedTab = state.localQueuedSongTab || null;
      const savedHold = Number(state.localQueuedSongHoldUntil || 0) || (savedAt + FIX83_QUEUE_TTL_MS);
      const r = prevSyncFromBridgeFix83.apply(this, arguments);
      const incomingPlayingId = fix83Str(data && (data.playingId ?? data.currentPlayingId ?? data.selectedPlayingId));
      if (savedId && fix83Now() > Number(fix83ExplicitQueueClearUntil || 0) && fix83Now() <= savedHold && incomingPlayingId !== savedId && !state.localQueuedSongId) {
        state.localQueuedSongId = savedId;
        state.localQueuedSongAt = savedAt || fix83Now();
        state.localQueuedSongTab = savedTab || state.activeTab || null;
        state.localQueuedSongHoldUntil = savedHold;
      }
      return r;
    };
  }
})();

/* VS_HOOK_FIX86_DIRECTOR_ACTIVE_SIMPLE_LOGOUT
   Comando simples: Diretor entra -> Lua mostra tela. Lua ACESSAR -> Diretor desloga.
   Sem heartbeat pesado e sem afetar Musicos/Recados. */
(function(){
  if (window.__vshookFix86DirectorActiveSimpleLogoutInstalled) return;
  window.__vshookFix86DirectorActiveSimpleLogoutInstalled = true;
  let announced = false;
  let lastAnnounceAt = 0;

  function now(){ return Date.now(); }
  function canAnnounceDirector(){
    try {
      if (window.__vshookDirectorLogoutInProgress) return false;
      if (typeof needsAuthGate === 'function' && needsAuthGate()) return false;
      if (state && state.authEnabled && !state.authAuthenticated) return false;
      return true;
    } catch(e) { return true; }
  }
  function bridgeUrl(path){
    try { return typeof vshookBridgeUrl === 'function' ? vshookBridgeUrl(path) : path; }
    catch(e) { return path; }
  }
  function sendDirectorEnter(force){
    if (!canAnnounceDirector()) return;
    const t = now();
    if (!force && announced && (t - lastAnnounceAt) < 60000) return;
    announced = true;
    lastAnnounceAt = t;
    try {
      if (state) { state.appActive = true; state.directorAppActive = true; }
      window.__vshookDirectorHeartbeatBlockedUntil = t + (365 * 24 * 60 * 60 * 1000); // bloqueia heartbeat antigo pesado
      fetch(bridgeUrl('/command'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        body: JSON.stringify({
          type: 'director_enter',
          payload: {
            role: 'director', clientRole: 'director', appRole: 'director', source: 'director',
            appActive: true, directorAppActive: true, directorActive: true,
            issuedAtMs: t,
            clientCommandId: `director-enter-${t}-${Math.random().toString(16).slice(2, 8)}`
          }
        })
      }).catch(function(){});
    } catch(e) {}
  }

  const prevSync86 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync86 && !syncFromBridge.__fix86DirectorLogoutWrapped) {
    syncFromBridge = function(data){
      if (data && typeof data === 'object') {
        const target = String(data.appLogoutTarget || data.logoutTarget || data.target || '').toLowerCase();
        const wantsDirector = !target || target === 'director' || target === 'diretor';
        const logout = wantsDirector && (data.forceDirectorLogout === true || data.directorLogoutRequested === true || data.logoutDirector === true);
        if (logout && typeof logoutDirectorToModeSelection === 'function') {
          try { logoutDirectorToModeSelection(data); } catch(e) {}
          return;
        }
      }
      return prevSync86.apply(this, arguments);
    };
    syncFromBridge.__fix86DirectorLogoutWrapped = true;
  }

  const prevLogout86 = typeof logoutDirectorToModeSelection === 'function' ? logoutDirectorToModeSelection : null;
  if (prevLogout86 && !logoutDirectorToModeSelection.__fix86LogoutWrapped) {
    logoutDirectorToModeSelection = function(data){
      announced = false;
      window.__vshookDirectorLogoutInProgress = true;
      window.__vshookDirectorHeartbeatBlockedUntil = now() + 20000;
      try {
        fetch(bridgeUrl('/command'), {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store',
          body: JSON.stringify({ type: 'director_logout_ack', payload: { role:'director', clientRole:'director', appRole:'director' } })
        }).catch(function(){});
      } catch(e) {}
      return prevLogout86.apply(this, arguments);
    };
    logoutDirectorToModeSelection.__fix86LogoutWrapped = true;
  }

  const prevSendHeartbeat86 = typeof sendAppHeartbeat === 'function' ? sendAppHeartbeat : null;
  if (prevSendHeartbeat86 && !sendAppHeartbeat.__fix86LightWrapped) {
    sendAppHeartbeat = function(){ sendDirectorEnter(false); };
    sendAppHeartbeat.__fix86LightWrapped = true;
  }

  window.addEventListener('focus', function(){ sendDirectorEnter(true); }, { passive:true });
  document.addEventListener('visibilitychange', function(){ if (!document.hidden) sendDirectorEnter(true); }, { passive:true });
  setTimeout(function(){ sendDirectorEnter(true); }, 80);
  setTimeout(function(){ sendDirectorEnter(true); }, 900);
})();



/* VS_HOOK_FIX87_EXPLICIT_DIRECTOR_FORCE_LOGOUT
   Lua -> extensao -> app Diretor: comando explicito director_force_logout. */
(function(){
  if (window.__vshookFix87ExplicitDirectorForceLogoutInstalled) return;
  window.__vshookFix87ExplicitDirectorForceLogoutInstalled = true;

  function bridgeUrl87(path){
    try { return typeof vshookBridgeUrl === 'function' ? vshookBridgeUrl(path) : path; }
    catch(e) { return path; }
  }
  function getLogoutCommand87(data){
    if (!data || typeof data !== 'object') return '';
    return String(data.directorCommand || data.appCommand || data.directorLogoutCommand || data.command || '').toLowerCase();
  }
  function getLogoutTarget87(data){
    if (!data || typeof data !== 'object') return '';
    return String(data.appLogoutTarget || data.logoutTarget || data.target || data.commandTarget || '').toLowerCase();
  }
  function getLogoutToken87(data){
    if (!data || typeof data !== 'object') return '';
    return String(data.directorLogoutToken || data.appLogoutToken || data.logoutToken || data.directorLogoutAt || data.updatedAt || '');
  }
  function hasConsumedLogout87(token){
    if (!token) return false;
    try { return localStorage.getItem('vshook_fix87_last_director_force_logout') === token; } catch(e) { return false; }
  }
  function markConsumedLogout87(token){
    if (!token) return;
    try { localStorage.setItem('vshook_fix87_last_director_force_logout', token); } catch(e) {}
  }
  function sendDirectorForceLogoutAck87(){
    try {
      fetch(bridgeUrl87('/command'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        body: JSON.stringify({
          type: 'director_force_logout_ack',
          payload: { role: 'director', clientRole: 'director', appRole: 'director', command: 'director_force_logout_ack' }
        })
      }).catch(function(){});
    } catch(e) {}
  }
  function shouldForceLogoutDirector87(data){
    const cmd = getLogoutCommand87(data);
    const target = getLogoutTarget87(data);
    const explicit = cmd === 'director_force_logout';
    const compatible = data && (data.forceDirectorLogout === true || data.directorLogoutRequested === true || data.logoutDirector === true);
    const wantsDirector = !target || target === 'director' || target === 'diretor';
    return wantsDirector && (explicit || compatible);
  }
  function forceDirectorLocalLogout88(data){
    // FIX88: nao setar __vshookDirectorLogoutInProgress antes de executar o logout.
    // A funcao antiga usa essa flag como guarda de reentrada; no FIX87 ela era ligada antes
    // e acabava bloqueando o proprio logout.
    try { window.__vshookDirectorLogoutInProgress = false; } catch(e) {}
    try { clearAccessSession(); } catch(e) {}
    try {
      localStorage.removeItem('vshook_access_session');
      localStorage.removeItem('vshook_director_auth');
      localStorage.removeItem('vshook_director_session');
      localStorage.removeItem('vshook_director_token');
      localStorage.setItem('vshook_last_director_logout_at', new Date().toISOString());
    } catch(e) {}
    try {
      if (state) {
        state.appActive = false;
        state.directorAppActive = false;
        state.authAuthenticated = false;
        state.authPassInput = '';
        state.authError = '';
        state.authShowPassword = false;
      }
    } catch(e) {}
    try { window.__vshookDirectorLogoutInProgress = true; } catch(e) {}
    if (typeof window.vshookExitToProjectSelector === 'function') {
      try { window.vshookExitToProjectSelector(); return true; } catch(e) {}
    }
    try { window.location.reload(); } catch(e) {}
    return true;
  }

  function executeDirectorForceLogout87(data){
    const token = getLogoutToken87(data) || `director-force-logout-${Date.now()}`;
    if (hasConsumedLogout87(token)) return true;
    markConsumedLogout87(token);
    try { window.__vshookDirectorHeartbeatBlockedUntil = Date.now() + 20000; } catch(e) {}
    sendDirectorForceLogoutAck87();
    return forceDirectorLocalLogout88(data || { directorCommand: 'director_force_logout', appLogoutTarget: 'director' });
  }

  const prevSync87 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync87 && !syncFromBridge.__fix87ExplicitLogoutWrapped) {
    syncFromBridge = function(data){
      if (shouldForceLogoutDirector87(data)) {
        executeDirectorForceLogout87(data);
        return;
      }
      return prevSync87.apply(this, arguments);
    };
    syncFromBridge.__fix87ExplicitLogoutWrapped = true;
  }

  window.vshookHandleDirectorForceLogout = executeDirectorForceLogout87;
})();
/* VS_HOOK_FIX89_QUEUE_HANDOFF_VISUAL_SELECTION
   Quando a fila entra automaticamente e a proxima musica começa a tocar,
   limpa a seleção azul que ficou presa na musica anterior. Ajuste visual apenas. */
(function(){
  if (window.__vshookFix89QueueHandoffVisualSelectionInstalled) return;
  window.__vshookFix89QueueHandoffVisualSelectionInstalled = true;

  function s89(value){ return value == null ? '' : String(value); }

  function isSame89(a, b){
    const aa = s89(a);
    const bb = s89(b);
    return !!aa && !!bb && aa === bb;
  }

  function clearStoppedHold89(){
    try {
      state.stoppedSelectionHoldId = null;
      state.stoppedSelectionHoldTab = null;
      state.stoppedSelectionHoldUntil = 0;
    } catch(e) {}
    try { if (typeof clearDirectorLocalSelectionHold === 'function') clearDirectorLocalSelectionHold(); } catch(e) {}
  }

  function clearSelectionForTab89(tab){
    try {
      if (tab === 'playlist') {
        state.selectedPlaylistSongId = null;
        state.selectedPlaylistSongIds = [];
      } else if (tab === 'regions') {
        state.selectedRegionId = null;
        state.selectedRegionIds = [];
      } else {
        state.selectedPlaylistSongId = null;
        state.selectedPlaylistSongIds = [];
        state.selectedRegionId = null;
        state.selectedRegionIds = [];
      }
    } catch(e) {}
  }

  function fixQueueHandoffVisualSelection89(previousPlayingId, currentPlayingId){
    const prev = s89(previousPlayingId);
    const now = s89(currentPlayingId || (state && state.playingId));
    if (!prev || !now || prev === now) return false;

    const selectedPlaylist = s89(state && state.selectedPlaylistSongId);
    const selectedRegion = s89(state && state.selectedRegionId);
    const stoppedHold = s89(state && state.stoppedSelectionHoldId);
    const activeTab = (state && state.activeTab) || 'playlist';

    const stalePlaylist = isSame89(selectedPlaylist, prev);
    const staleRegion = isSame89(selectedRegion, prev);
    const staleHold = isSame89(stoppedHold, prev);

    if (!stalePlaylist && !staleRegion && !staleHold) return false;

    clearStoppedHold89();
    try { state.selectionLockUntil = 0; } catch(e) {}
    try { if (typeof markDirectorRecentlyStoppedSelectionBlocked === 'function') markDirectorRecentlyStoppedSelectionBlocked(prev); } catch(e) {}

    // A musica tocando ja tem visual proprio. O azul antigo nao pode ficar na anterior.
    // Portanto limpamos a seleção presa; nao forçamos azul na musica tocando para nao misturar estados.
    if (stalePlaylist) clearSelectionForTab89('playlist');
    if (staleRegion) clearSelectionForTab89('regions');
    if (!stalePlaylist && !staleRegion && staleHold) clearSelectionForTab89(activeTab);

    try { if (typeof render === 'function') render(); } catch(e) {}
    return true;
  }

  const prevSync89 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync89 && !syncFromBridge.__fix89QueueHandoffVisualWrapped) {
    syncFromBridge = function(data){
      const previousPlayingId = s89(state && state.playingId);
      const previousSelectedPlaylist = s89(state && state.selectedPlaylistSongId);
      const previousSelectedRegion = s89(state && state.selectedRegionId);
      const previousStoppedHold = s89(state && state.stoppedSelectionHoldId);
      const result = prevSync89.apply(this, arguments);
      const currentPlayingId = s89(state && state.playingId);
      if (currentPlayingId && previousPlayingId && currentPlayingId !== previousPlayingId) {
        // Restaura temporariamente a referência anterior para detectar corretamente
        // quando o wrapper interno já mexeu nos campos antes deste wrapper rodar.
        if (!s89(state.selectedPlaylistSongId) && previousSelectedPlaylist === previousPlayingId) state.selectedPlaylistSongId = previousSelectedPlaylist;
        if (!s89(state.selectedRegionId) && previousSelectedRegion === previousPlayingId) state.selectedRegionId = previousSelectedRegion;
        if (!s89(state.stoppedSelectionHoldId) && previousStoppedHold === previousPlayingId) state.stoppedSelectionHoldId = previousStoppedHold;
        fixQueueHandoffVisualSelection89(previousPlayingId, currentPlayingId);
      }
      return result;
    };
    syncFromBridge.__fix89QueueHandoffVisualWrapped = true;
  }

  window.vshookFixQueueHandoffVisualSelection89 = fixQueueHandoffVisualSelection89;
})();


/* VS_HOOK_FIX90_CLEAR_BLUE_SELECTION_WHILE_PLAYING
   Seleção azul é apenas para música selecionada quando o Diretor está parado.
   Durante playback a música tocando usa o visual vermelho; fila usa amarelo.
   Portanto, quando existe playingId ativo, limpamos qualquer azul antigo sem mover
   a seleção para a música tocando. */
(function(){
  if (window.__vshookFix90ClearBlueWhilePlayingInstalled) return;
  window.__vshookFix90ClearBlueWhilePlayingInstalled = true;

  function hasPlaying90(){
    try {
      const id = state && state.playingId != null ? String(state.playingId) : '';
      if (id) return true;
      if (state && (state.isPlaying === true || state.playing === true || state.playbackPlaying === true)) return true;
    } catch(e) {}
    return false;
  }

  function clearBlueSelection90(){
    let changed = false;
    try {
      if (state.selectedPlaylistSongId != null || (Array.isArray(state.selectedPlaylistSongIds) && state.selectedPlaylistSongIds.length)) {
        state.selectedPlaylistSongId = null;
        state.selectedPlaylistSongIds = [];
        changed = true;
      }
      if (state.selectedRegionId != null || (Array.isArray(state.selectedRegionIds) && state.selectedRegionIds.length)) {
        state.selectedRegionId = null;
        state.selectedRegionIds = [];
        changed = true;
      }
      if (state.stoppedSelectionHoldId != null || state.stoppedSelectionHoldUntil) {
        state.stoppedSelectionHoldId = null;
        state.stoppedSelectionHoldTab = null;
        state.stoppedSelectionHoldUntil = 0;
        changed = true;
      }
      if (state.localSelectionHoldId != null || state.localSelectionHoldUntil) {
        state.localSelectionHoldId = null;
        state.localSelectionHoldTab = null;
        state.localSelectionHoldUntil = 0;
        changed = true;
      }
      if (state.directorLocalSelectionHoldId != null || state.directorLocalSelectionHoldUntil) {
        state.directorLocalSelectionHoldId = null;
        state.directorLocalSelectionHoldTab = null;
        state.directorLocalSelectionHoldUntil = 0;
        changed = true;
      }
      if (state.selectionLockUntil) {
        state.selectionLockUntil = 0;
        changed = true;
      }
    } catch(e) {}
    try { if (typeof clearDirectorLocalSelectionHold === 'function') clearDirectorLocalSelectionHold(); } catch(e) {}
    return changed;
  }

  const prevSync90 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (prevSync90 && !syncFromBridge.__fix90ClearBlueWhilePlayingWrapped) {
    syncFromBridge = function(data){
      const result = prevSync90.apply(this, arguments);
      if (hasPlaying90()) {
        if (clearBlueSelection90()) {
          try { if (typeof render === 'function') setTimeout(function(){ try { render(); } catch(e) {} }, 0); } catch(e) {}
        }
      }
      return result;
    };
    syncFromBridge.__fix90ClearBlueWhilePlayingWrapped = true;
  }

  const prevRender90 = typeof render === 'function' ? render : null;
  if (prevRender90 && !render.__fix90ClearBlueWhilePlayingWrapped) {
    render = function(){
      if (hasPlaying90()) clearBlueSelection90();
      return prevRender90.apply(this, arguments);
    };
    render.__fix90ClearBlueWhilePlayingWrapped = true;
  }

  window.vshookFix90ClearBlueSelectionWhilePlaying = clearBlueSelection90;
})();


/* VS_HOOK_FIX103_NATIVE_TP_MEDIA_AND_AUTO_SYNC
   TP1 via extensão: imagem/vídeo são renderizados por URL HTTP da extensão, não como texto. */
(function(){
  if (window.__VSHOOK_FIX103_NATIVE_TP_MEDIA_DIRECTOR__) return;
  window.__VSHOOK_FIX103_NATIVE_TP_MEDIA_DIRECTOR__ = true;
  const esc = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const up = (v) => (typeof upperText === 'function' ? upperText(v) : String(v || '').toUpperCase());
  const mediaKind = (type, path) => {
    const t = String(type || '').toLowerCase();
    const p = String(path || '').toLowerCase().split('?')[0];
    if (t.includes('image') || /\.(png|jpe?g|webp|gif|bmp|svg)$/.test(p)) return 'image';
    if (t.includes('video') || /\.(mp4|mov|m4v|webm|mkv|avi)$/.test(p)) return 'video';
    return 'text';
  };
  const mediaAllowsText = (type) => {
    const t = String(type || 'text').toLowerCase().replace(/[\s-]+/g,'_');
    return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain';
  };
  const bridgeUrl = (path) => { try { return typeof vshookBridgeUrl === 'function' ? vshookBridgeUrl(path) : path; } catch(e) { return path; } };
  function setTpFromBridge103(data){
    if (!data || typeof data !== 'object' || !state) return;
    const tp = data.tp1 && typeof data.tp1 === 'object' ? data.tp1 : {};
    const mediaType = String(data.tp1MediaType || data.telepromptTp1MediaType || tp.mediaType || tp.telepromptType || state.tp1MediaType || 'text').toLowerCase();
    const mediaPath = String(data.tp1MediaPath || data.telepromptTp1MediaPath || tp.mediaPath || tp.path || state.tp1MediaPath || '').trim();
    state.tp1MediaType = mediaType;
    state.telepromptTp1MediaType = mediaType;
    state.tp1MediaPath = mediaPath;
    state.telepromptTp1MediaPath = mediaPath;
    state.tp1MediaCurrentTime = Number(data.tp1MediaCurrentTime ?? tp.mediaCurrentTime ?? state.tp1MediaCurrentTime ?? 0) || 0;
    state.tp1MediaOffset = Number(data.tp1MediaOffset ?? tp.mediaOffset ?? state.tp1MediaOffset ?? 0) || 0;
    state.tp1MediaPlayrate = Number(data.tp1MediaPlayrate ?? tp.mediaPlayrate ?? state.tp1MediaPlayrate ?? 1) || 1;
    state.tp1SongName = String(data.tp1SongName || data.telepromptTp1SongName || data.tp1Song || tp.songName || tp.song || state.tp1SongName || '');
    state.tp1LyricsText = mediaAllowsText(mediaType) ? String(data.tp1LyricsText || data.tp1Lyrics || data.telepromptTp1Lyrics || data.telepromptTp1Text || tp.lyricsText || tp.lyrics || tp.text || state.tp1LyricsText || '') : '';
    state.tp1UpdatedAt = data.tp1UpdatedAt || tp.updatedAt || state.tp1UpdatedAt || null;
  }
  if (typeof syncFromBridge === 'function' && !syncFromBridge.__fix103TpMediaWrapped) {
    const prev = syncFromBridge;
    syncFromBridge = function(data){
      const result = prev(data);
      try { setTpFromBridge103(data); } catch(e) {}
      return result;
    };
    syncFromBridge.__fix103TpMediaWrapped = true;
  }
  function tpTitle(){ return String(state?.tp1SongName || state?.telepromptTp1SongName || state?.currentSongName || state?.playingSongName || state?.songName || 'TELEPROMPT 1').trim() || 'TELEPROMPT 1'; }
  function tpPath(){ return String(state?.tp1MediaPath || state?.telepromptTp1MediaPath || '').trim(); }
  function tpType(){ return String(state?.tp1MediaType || state?.telepromptTp1MediaType || 'text').toLowerCase(); }
  function tpText(){ return mediaAllowsText(tpType()) ? String(state?.tp1LyricsText || state?.tp1Lyrics || state?.telepromptTp1Lyrics || state?.telepromptTp1Text || '').trim() : ''; }
  function tpMediaUrl(path){ return path ? bridgeUrl('/media?slot=1&path=' + encodeURIComponent(path)) : ''; }
  function progress103(){ try { const d = Number(state.playbackDurationSec || state.currentSongDurationSec || 0); const r = Number(state.playbackRemainingSec || state.currentSongRemainingSec); if (d > 0 && Number.isFinite(r)) return Math.max(0, Math.min(100, ((d-r)/d)*100)); } catch(e){} return 0; }
  function renderTpBody103(){
    const path = tpPath();
    const kind = mediaKind(tpType(), path);
    if (kind === 'image') {
      const src = tpMediaUrl(path);
      return src ? `<div class="tpMediaStageFix103"><img class="tpMediaImageFix103" data-tp-media="image" src="${esc(src)}" alt="TP1" /></div>` : `<div class="lyricsTextView tpLyricsTextFix103">MÍDIA TP1 SEM CAMINHO</div>`;
    }
    if (kind === 'video') {
      const src = tpMediaUrl(path);
      const cur = Number(state?.tp1MediaCurrentTime || 0) || 0;
      return src ? `<div class="tpMediaStageFix103"><video class="tpMediaVideoFix103" data-tp-media="video" data-tp-current-time="${esc(cur)}" src="${esc(src)}" autoplay muted playsinline webkit-playsinline preload="auto"></video></div>` : `<div class="lyricsTextView tpLyricsTextFix103">VÍDEO TP1 SEM CAMINHO</div>`;
    }
    const text = tpText() || 'SEM CONTEÚDO NO TP1';
    return `<div class="lyricsTextView tpLyricsTextFix103" data-lyrics-text-view data-lyrics-source="${esc(text)}">${typeof lyricsTextToHtml === 'function' ? lyricsTextToHtml(text) : esc(text)}</div>`;
  }
  function syncTpMediaDom103(){
    const v = document.querySelector('video[data-tp-media="video"]');
    if (v) {
      const wanted = Number(state?.tp1MediaCurrentTime || v.getAttribute('data-tp-current-time') || 0) || 0;
      try { if (Number.isFinite(wanted) && Math.abs((v.currentTime || 0) - wanted) > 0.45) v.currentTime = wanted; } catch(e) {}
      try { v.muted = true; const p = v.play?.(); if (p && p.catch) p.catch(()=>{}); } catch(e) {}
    }
    const titleNode = document.querySelector('[data-lyrics-title]');
    if (titleNode) titleNode.textContent = up(tpTitle());
    const fill = document.querySelector('[data-lyrics-progress-fill]');
    if (fill) fill.style.width = `${Math.round(progress103()*10)/10}%`;
  }
  if (typeof renderLyricsPanel === 'function') {
    renderLyricsPanel = function(){
      if (!state.lyricsPanelOpen) return '';
      const title = up(tpTitle());
      const progress = Math.round(progress103()*10)/10;
      return `<div class="lyricsScreen telepromptOnlyScreen directorTp1OnlyScreen tpMediaScreenFix103" style="--tp-text-color:${esc((window.__vshookDirectorTpColorFix12 && window.__vshookDirectorTpColorFix12()) || '#f8fafc')};--tp-font:${esc((window.__vshookDirectorTpFontFix12 && window.__vshookDirectorTpFontFix12()) || 'Inter, Arial, sans-serif')}">
        <div class="lyricsTopBar lyricsTopBarTpFix12">
          <div class="lyricsNowPlaying lyricsNowPlayingTpFix12">
            <div class="lyricsNowPlayingTitle lyricsNowPlayingTitleFix12" data-lyrics-title>${esc(title)}</div>
            <div class="lyricsProgressTrack lyricsProgressTrackFix12"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${progress}%"></div></div>
          </div>
          <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonFix12" data-action="close-lyrics-panel">&gt;&gt;</button>
        </div>
        <div class="lyricsBody lyricsBodyTpFix12 tpMediaBodyFix103">${renderTpBody103()}</div>
      </div>`;
    };
  }
  if (typeof syncLyricsPanelDom === 'function') {
    const prevSyncDom = syncLyricsPanelDom;
    syncLyricsPanelDom = function(){ try { prevSyncDom(); } catch(e) {} syncTpMediaDom103(); };
  }
  setInterval(syncTpMediaDom103, 500);
})();

/* VS_HOOK_FIX_STOP_TRANSPORT_ONLY_FINAL
   Stop do Diretor não pode enviar música, índice, posição, fila ou alvo para a extensão.
   O problema aparecia depois de reorganizar o repertório porque o Stop carregava índice/posição antigos
   e a extensão interpretava como seek. Stop agora é transporte puro. */
(function(){
  if (window.__vshookFixStopTransportOnlyFinalInstalled) return;
  window.__vshookFixStopTransportOnlyFinalInstalled = true;

  function isDirectorStopCommand(type, payload){
    const t = String(type || '').toLowerCase();
    const p = payload && typeof payload === 'object' ? payload : {};
    const source = String(p.role || p.clientRole || p.appRole || p.source || p.mode || '').toLowerCase();
    const isDirector = !source || source.includes('director') || source.includes('diretor') || t.startsWith('director_');
    const wantsStop = t === 'director_stop_no_seek' || t === 'play_stop' || t === 'stop' ||
      (t.includes('stop') && !t.includes('timer')) ||
      p.forceStop === true || p.desiredPlaying === false || String(p.desiredState || '').toLowerCase() === 'stopped';
    return isDirector && wantsStop;
  }

  function makeDirectorTransportOnlyStopPayload(payload, sourceTab){
    const p = payload && typeof payload === 'object' ? payload : {};
    return {
      role: 'director',
      clientRole: 'director',
      appRole: 'director',
      source: 'director',
      mode: 'director',
      activeTab: sourceTab || p.activeTab || p.page || (typeof state === 'object' && state ? state.activeTab : '') || 'playlist',
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
      issuedAtMs: Date.now(),
      clientCommandId: p.clientCommandId || `director-stop-transport-only-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`
    };
  }

  const previousPostCommandStopFinal = typeof postCommand === 'function' ? postCommand : null;
  if (previousPostCommandStopFinal && !previousPostCommandStopFinal.__stopTransportOnlyFinalWrapped) {
    postCommand = function(type, payload = {}){
      if (isDirectorStopCommand(type, payload)) {
        return previousPostCommandStopFinal.call(this, 'director_stop_no_seek', makeDirectorTransportOnlyStopPayload(payload, payload && payload.activeTab));
      }
      return previousPostCommandStopFinal.apply(this, arguments);
    };
    postCommand.__stopTransportOnlyFinalWrapped = true;
  }

  const previousPostPlaybackToggleStopFinal = typeof postPlaybackToggleCommand === 'function' ? postPlaybackToggleCommand : null;
  if (previousPostPlaybackToggleStopFinal && !previousPostPlaybackToggleStopFinal.__stopTransportOnlyFinalWrapped) {
    postPlaybackToggleCommand = function(targetId, sourceTab, desiredPlaying, extraPayload){
      if (!desiredPlaying) {
        try { if (typeof directorStopRetryTimer !== 'undefined' && directorStopRetryTimer) clearTimeout(directorStopRetryTimer); } catch(e) {}
        const merged = extraPayload && typeof extraPayload === 'object' ? { ...extraPayload } : {};
        merged.activeTab = sourceTab || merged.activeTab || (typeof state === 'object' && state ? state.activeTab : '') || 'playlist';
        return postCommand('director_stop_no_seek', makeDirectorTransportOnlyStopPayload(merged, merged.activeTab));
      }
      return previousPostPlaybackToggleStopFinal.apply(this, arguments);
    };
    postPlaybackToggleCommand.__stopTransportOnlyFinalWrapped = true;
  }
})();



/* VS_HOOK_TIMER_DIRECTOR_CONTROL_FINAL
   Timer do Diretor: progressivo, regressivo e horário local enviados ao Lua/extensão.
   Não cria camada visual nova; apenas usa o modal/botão existente. */
function normalizeDirectorTimerMode(value) {
  const raw = String(value || '').trim().toLowerCase().replace(/[-\s]+/g, '_');
  if (raw === 'local_time' || raw === 'localtime' || raw === 'local' || raw === 'horario_local' || raw === 'hora_local' || raw === 'clock' || raw === 'relogio') return 'local_time';
  if (raw === 'countdown' || raw === 'regressive' || raw === 'regressivo' || raw === 'down') return 'countdown';
  return 'progressive';
}
function getDirectorDeviceLocalTimeParts() {
  const d = new Date();
  return { h: d.getHours(), m: d.getMinutes(), s: d.getSeconds() };
}
function getDirectorDeviceLocalTimeSec() {
  const t = getDirectorDeviceLocalTimeParts();
  return Math.max(0, Math.min(99 * 3600 + 59 * 60 + 59, t.h * 3600 + t.m * 60 + t.s));
}
function getDirectorDeviceLocalTimeText() {
  const t = getDirectorDeviceLocalTimeParts();
  return `${String(t.h).padStart(2, '0')}:${String(t.m).padStart(2, '0')}:${String(t.s).padStart(2, '0')}`;
}
function getDirectorTimerSnapshot(extra = {}) {
  const mode = normalizeDirectorTimerMode(extra.timerMode || extra.mode || state.timerMode || 'progressive');
  let target = Number(extra.timerTargetSec ?? extra.targetSec ?? extra.seconds ?? state.timerTargetSec ?? 0) || 0;
  target = Math.max(0, Math.min(99 * 3600 + 59 * 60 + 59, Math.floor(target)));
  const localSec = getDirectorDeviceLocalTimeSec();
  const localText = getDirectorDeviceLocalTimeText();
  let display = mode === 'local_time' ? localSec : 0;
  try { if (mode !== 'local_time' && typeof getTimerElapsedSec === 'function') display = Math.floor(Number(getTimerElapsedSec()) || 0); } catch (_) {}
  if (mode === 'countdown' && !state.timerRunning) display = target;
  if (mode === 'progressive' && !state.timerRunning) display = Math.max(0, Math.floor(Number(state.timerDisplaySec ?? state.timerAccumulatedSec ?? 0) || 0));
  return {
    timerMode: mode,
    mode,
    timerType: mode,
    timerTargetSec: mode === 'countdown' ? target : 0,
    targetSec: mode === 'countdown' ? target : 0,
    seconds: mode === 'countdown' ? target : 0,
    timerCountdownStartSec: mode === 'countdown' ? target : 0,
    countdownSec: mode === 'countdown' ? target : 0,
    countdownSeconds: mode === 'countdown' ? target : 0,
    timerDisplaySec: display,
    timerValueSec: display,
    timerElapsedSec: mode === 'countdown' ? Math.max(0, target - display) : display,
    elapsedSec: mode === 'countdown' ? Math.max(0, target - display) : display,
    timerAccumulatedSec: mode === 'local_time' ? 0 : (mode === 'countdown' ? Math.max(0, target - display) : display),
    timerProgressiveSec: mode === 'progressive' ? display : 0,
    progressiveSec: mode === 'progressive' ? display : 0,
    timerLocalTimeSec: localSec,
    localTimeSec: localSec,
    timerLocalTimeText: localText,
    localTimeText: localText,
    appDeviceLocalTime: localText,
    appDeviceLocalTimeSec: localSec,
    deviceEpochMs: Date.now(),
    timezoneOffsetMin: new Date().getTimezoneOffset(),
    source: 'director',
    appRole: 'director',
    clientRole: 'director',
    role: 'director'
  };
}
(function installDirectorTimerFinalPatch(){
  if (window.__vshookDirectorTimerFinalPatchApplied) return;
  window.__vshookDirectorTimerFinalPatchApplied = true;
  try { state.timerMode = normalizeDirectorTimerMode(state.timerMode || 'progressive'); } catch (_) {}

  const DIRECTOR_TIMER_COUNTDOWN_STORAGE_KEY = 'vshook.director.timer.countdownSec.v1';
  const DIRECTOR_TIMER_MAX_SECONDS = 99 * 3600 + 59 * 60 + 59;
  function clampDirectorCountdownSeconds(value) {
    const n = Math.floor(Number(value) || 0);
    return Math.max(0, Math.min(DIRECTOR_TIMER_MAX_SECONDS, n));
  }
  function loadDirectorCountdownTargetSec() {
    try {
      const raw = window.localStorage ? window.localStorage.getItem(DIRECTOR_TIMER_COUNTDOWN_STORAGE_KEY) : '';
      return clampDirectorCountdownSeconds(raw || 0);
    } catch (_) {
      return 0;
    }
  }
  function saveDirectorCountdownTargetSec(value) {
    const safe = clampDirectorCountdownSeconds(value);
    state.timerTargetSec = safe;
    try {
      if (window.localStorage) window.localStorage.setItem(DIRECTOR_TIMER_COUNTDOWN_STORAGE_KEY, String(safe));
    } catch (_) {}
    return safe;
  }
  if (!Number.isFinite(Number(state.timerTargetSec)) || Number(state.timerTargetSec) <= 0) {
    const savedCountdown = loadDirectorCountdownTargetSec();
    if (savedCountdown > 0) state.timerTargetSec = savedCountdown;
  }


  const previousGetTimerElapsedFinal = typeof getTimerElapsedSec === 'function' ? getTimerElapsedSec : null;
  getTimerElapsedSec = function() {
    try {
      state.timerMode = normalizeDirectorTimerMode(state.timerMode || 'progressive');
      if (state.timerMode === 'local_time') return getDirectorDeviceLocalTimeSec();
    } catch (_) {}
    return previousGetTimerElapsedFinal ? previousGetTimerElapsedFinal.apply(this, arguments) : 0;
  };

  openTimerModal = function() {
    state.timerMode = normalizeDirectorTimerMode(state.timerMode || 'progressive');
    state.showTimerModal = true;
    try { syncChronoDisplays?.(); } catch (_) {}
    render?.();
    return true;
  };

  setTimerModeFromApp = function(mode) {
    const next = normalizeDirectorTimerMode(mode);
    if (state.timerMode === 'countdown' && next !== 'countdown') {
      try { saveDirectorCountdownTargetSec(readTimerTargetSecondsFromModal?.() ?? state.timerTargetSec ?? 0); } catch (_) {}
    }
    if (next === 'countdown') {
      try {
        const fromInputs = readTimerTargetSecondsFromModal?.();
        const saved = loadDirectorCountdownTargetSec();
        state.timerTargetSec = clampDirectorCountdownSeconds((Number(fromInputs) > 0 ? fromInputs : (Number(state.timerTargetSec) > 0 ? state.timerTargetSec : saved)));
      } catch (_) {
        state.timerTargetSec = clampDirectorCountdownSeconds(Number(state.timerTargetSec) > 0 ? state.timerTargetSec : loadDirectorCountdownTargetSec());
      }
    }
    state.timerMode = next;
    if (next === 'local_time') {
      state.timerDisplaySec = getDirectorDeviceLocalTimeSec();
    } else if (next === 'progressive') {
      state.timerDisplaySec = state.timerRunning ? getTimerElapsedSec() : 0;
    } else if (!state.timerRunning) {
      state.timerDisplaySec = Number(state.timerTargetSec) || 0;
    }
    const snap = getDirectorTimerSnapshot({ timerMode: next });
    postCommand('timer_set_mode', { ...snap, timerRunning: !!state.timerRunning, running: !!state.timerRunning, action: 'set_mode', timerAction: 'set_mode' });
    try { syncChronoDisplays?.(); } catch (_) {}
    render?.();
    return true;
  };

  confirmTimerModal = function() {
    state.timerMode = normalizeDirectorTimerMode(state.timerMode || 'progressive');
    if (state.timerMode === 'countdown') {
      try { saveDirectorCountdownTargetSec(readTimerTargetSecondsFromModal?.() ?? state.timerTargetSec ?? 0); } catch (_) { state.timerTargetSec = clampDirectorCountdownSeconds(Number(state.timerTargetSec) || 0); }
    }

    const wasRunning = !!state.timerRunning;
    if (wasRunning && state.timerMode !== 'local_time') {
      const snapStop = getDirectorTimerSnapshot();
      state.timerRunning = false;
      state.timerStartedAt = 0;
      state.timerStartedAtMs = 0;
      state.timerAccumulatedSec = 0;
      state.timerElapsedSec = 0;
      state.timerDisplaySec = state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0;
      state.showTimerModal = false;
      postCommand('timer_stop_reset', { ...snapStop, timerRunning: false, running: false, action: 'stop_reset', timerAction: 'stop_reset' });
      try { syncChronoDisplays?.(); refreshChronoRenderLoop?.(); } catch (_) {}
      render?.();
      return true;
    }

    const now = Date.now();
    state.timerRunning = state.timerMode !== 'local_time';
    state.timerStartedAt = state.timerMode === 'local_time' ? 0 : now;
    state.timerStartedAtMs = state.timerMode === 'local_time' ? 0 : now;
    state.timerAccumulatedSec = 0;
    state.timerElapsedSec = 0;
    state.timerDisplaySec = state.timerMode === 'local_time'
      ? getDirectorDeviceLocalTimeSec()
      : (state.timerMode === 'countdown' ? (Number(state.timerTargetSec) || 0) : 0);
    state.showTimerModal = false;
    const snapStart = getDirectorTimerSnapshot();
    postCommand('timer_set_mode', { ...snapStart, timerRunning: !!state.timerRunning || state.timerMode === 'local_time', running: !!state.timerRunning || state.timerMode === 'local_time', action: 'set_mode', timerAction: 'set_mode' });
    postCommand('timer_start', { ...snapStart, timerRunning: !!state.timerRunning || state.timerMode === 'local_time', running: !!state.timerRunning || state.timerMode === 'local_time', action: 'start', timerAction: 'start', startedAt: now, timerStartedAt: now, timerStartedAtMs: now });
    try { syncChronoDisplays?.(); refreshChronoRenderLoop?.(); } catch (_) {}
    render?.();
    return true;
  };
})();


/* VS_HOOK_FIX_TOTAL_LOCK_DIRECTOR_HEARTBEAT_PERSIST
   Mantém o sinal real do App Diretor vivo na extensão enquanto o app está autenticado.
   Isso fecha a brecha de fechar/reabrir o Lua ou trocar projeto e perder a tela de bloqueio. */
(function(){
  if (window.__vshookFixTotalLockDirectorHeartbeatPersist) return;
  window.__vshookFixTotalLockDirectorHeartbeatPersist = true;
  let lastHeartbeatAt = 0;
  function canHeartbeat(){
    try {
      if (window.__vshookDirectorLogoutInProgress) return false;
      if (typeof needsAuthGate === 'function' && needsAuthGate()) return false;
      if (state && state.authEnabled && !state.authAuthenticated) return false;
      return true;
    } catch(e) { return true; }
  }
  function bridgeUrl(path){
    try { return typeof vshookBridgeUrl === 'function' ? vshookBridgeUrl(path) : path; }
    catch(e) { return path; }
  }
  function sendDirectorAlive(force){
    if (!canHeartbeat()) return;
    const t = Date.now();
    if (!force && (t - lastHeartbeatAt) < 1800) return;
    lastHeartbeatAt = t;
    try {
      window.__vshookDirectorHeartbeatBlockedUntil = 0;
      if (state) {
        state.appActive = true;
        state.directorAppActive = true;
        state.directorActive = true;
      }
      fetch(bridgeUrl('/command'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        body: JSON.stringify({
          type: 'director_heartbeat',
          payload: {
            role: 'director', clientRole: 'director', appRole: 'director', source: 'director',
            appActive: true, directorAppActive: true, directorActive: true,
            authAuthenticated: true, desiredState: 'authenticated', sessionHash: 'director-active',
            issuedAtMs: t,
            clientCommandId: `director-heartbeat-${t}-${Math.random().toString(16).slice(2, 8)}`
          }
        })
      }).catch(function(){});
    } catch(e) {}
  }
  const prevSendHeartbeat = typeof sendAppHeartbeat === 'function' ? sendAppHeartbeat : null;
  if (prevSendHeartbeat && !prevSendHeartbeat.__vshookTotalLockHeartbeatWrapped) {
    sendAppHeartbeat = function(){
      try { prevSendHeartbeat.apply(this, arguments); } catch(e) {}
      sendDirectorAlive(false);
    };
    sendAppHeartbeat.__vshookTotalLockHeartbeatWrapped = true;
  }
  window.addEventListener('focus', function(){ sendDirectorAlive(true); }, { passive:true });
  document.addEventListener('visibilitychange', function(){ if (!document.hidden) sendDirectorAlive(true); }, { passive:true });
  document.addEventListener('pointerdown', function(){ sendDirectorAlive(true); }, { passive:true, capture:true });
  document.addEventListener('touchstart', function(){ sendDirectorAlive(true); }, { passive:true, capture:true });
  setInterval(function(){ sendDirectorAlive(false); }, 1800);
  setTimeout(function(){ sendDirectorAlive(true); }, 80);
  setTimeout(function(){ sendDirectorAlive(true); }, 600);
})();
