
function flattenBridgeHashChildrenFromSongList(songs) {
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

function normalizeBridgePlaylistsWithHashChildren(playlists) {
  return (Array.isArray(playlists) ? playlists : []).map((playlist) => ({
    ...playlist,
    songs: flattenBridgeHashChildrenFromSongList(playlist?.songs || []),
  }))
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
  return vshookHashClean(item.familyGroupId)
    || vshookHashClean(item.parentId)
    || vshookHashClean(item.parentSourceNumber)
    || vshookHashClean(item.source_number)
    || vshookHashClean(item.sourceNumber)
    || vshookHashClean(item.id)
    || vshookHashClean(item.songId)
}

function vshookHashParentIdentity(item) {
  if (!item || typeof item !== 'object') return ''
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
  const identity = vshookHashClean(el.getAttribute('data-family-group-id'))
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

function vshookCacheHashChildrenFromItems(items, type, playlistId) {
  vshookEnsureHashFrontState()
  const incoming = new Map()
  for (const item of Array.isArray(items) ? items : []) {
    if (!isHashChildItem(item)) continue
    const key = vshookHashKeyForItem(item, type, playlistId)
    if (!key) continue
    if (!incoming.has(key)) incoming.set(key, [])
    incoming.get(key).push({ ...item })
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
    const key = vshookHashKeyForItem(item, type, playlistId)
    if (!key) continue
    if (!map.has(key)) map.set(key, [])
    map.get(key).push(item)
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
  if (Object.prototype.hasOwnProperty.call(state.hashChildLocalOpenByKey, key)) {
    return state.hashChildLocalOpenByKey[key] === true
  }
  const fromBridge = bridgeChildMap && bridgeChildMap.get(key)
  return Array.isArray(fromBridge) && fromBridge.length > 0
}

function vshookGetDisplayItemsWithFrontHashChildren(items, type, playlistId) {
  vshookEnsureHashFrontState()
  const source = Array.isArray(items) ? items : []
  const childMap = vshookBuildHashChildMap(source, type, playlistId)
  const out = []
  const seenChildren = new Set()

  for (const item of source) {
    if (isHashChildItem(item)) continue
    out.push(item)
    if (!isHashParentItem(item)) continue
    const key = vshookHashKeyForItem(item, type, playlistId)
    if (!key || !vshookShouldShowHashChildren(key, childMap)) continue
    const children = vshookGetHashVisibleChildren(key, childMap)
    for (const child of children) {
      const childId = String(child?.id ?? child?.songId ?? child?.source_number ?? child?.sourceNumber ?? '')
      const dedupe = `${key}|${childId || out.length}`
      if (seenChildren.has(dedupe)) continue
      seenChildren.add(dedupe)
      out.push(child)
    }
  }
  return out
}

function vshookToggleHashChildrenFront(el, type) {
  vshookEnsureHashFrontState()
  const key = vshookHashKeyFromElement(el, type)
  if (!key) return false
  const currentItems = type === 'region'
    ? (Array.isArray(state.regions) ? state.regions : [])
    : (Array.isArray(activePlaylist()?.songs) ? activePlaylist().songs : [])
  const childMap = vshookBuildHashChildMap(currentItems, type === 'region' ? 'region' : 'song', state.activePlaylistId || '')
  const currentlyOpen = vshookShouldShowHashChildren(key, childMap)
  const nextOpen = !currentlyOpen
  const now = Date.now()
  if (nextOpen) {
    state.hashChildLocalOpenByKey[key] = true
    state.hashChildOpeningUntilByKey[key] = now + 260
    state.hashChildClosingUntilByKey[key] = 0
    render()
  } else {
    state.hashChildLocalOpenByKey[key] = false
    state.hashChildClosingUntilByKey[key] = now + 220
    state.hashChildOpeningUntilByKey[key] = 0
    render()
    window.setTimeout(() => {
      if (Date.now() >= Number(state.hashChildClosingUntilByKey?.[key] || 0)) {
        if (state.hashChildClosingUntilByKey) state.hashChildClosingUntilByKey[key] = 0
        render()
      }
    }, 230)
  }
  return true
}

function vshookHashChildAnimationClasses(item, type) {
  if (!isHashChildItem(item)) return ''
  vshookEnsureHashFrontState()
  const key = vshookHashKeyForItem(item, type, state.activePlaylistId || '')
  if (!key) return ''
  const now = Date.now()
  const classes = []
  if (now < Number(state.hashChildOpeningUntilByKey[key] || 0)) classes.push('hashChildExpandIn')
  if (now < Number(state.hashChildClosingUntilByKey[key] || 0)) classes.push('hashChildCollapseOut')
  return classes.join(' ')
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
  if (window.__vshookDirectorLogoutInProgress) return true
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
  // Corrige o +1s visual no total vindo da conversao REAPER/bridge.
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
  state.timerModalMode = state.timerRunning ? 'stop' : 'start'
  state.showTimerModal = true
  render()
}

function closeTimerModal() {
  state.showTimerModal = false
  render()
}

function confirmTimerModal() {
  if (state.timerMode === 'countdown') {
    state.timerTargetSec = readTimerTargetSecondsFromModal()
  }
  postCommand('timer_set_mode', {
    timerMode: state.timerMode,
    mode: state.timerMode,
    timerTargetSec: state.timerTargetSec || 0,
    targetSec: state.timerTargetSec || 0,
    seconds: state.timerTargetSec || 0,
  })
  state.showTimerModal = false
  render()
  postCommand('timer_toggle')
}


function setTimerModeFromApp(mode) {
  const next = String(mode || '').toLowerCase() === 'countdown' ? 'countdown' : 'progressive'
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

function vshookSumRootDuration(items) {
  return vshookRootFamilyItems(items).reduce((sum, item) => {
    if (detectBlockItem(item)) return sum
    return sum + (Number(item?.durationSec) || 0)
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
    if (now - lastRunAt < 500) {
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
    if (now - lastRunAt < 500) {
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
  const payload = getPlaybackCommandPayloadForTarget(targetId, sourceTab, desiredPlaying)
  if (extraPayload && typeof extraPayload === 'object') Object.assign(payload, extraPayload)

  // Stop vindo do Diretor: o Lua precisa receber como seleção principal a música
  // que deve ficar azul depois do Stop, não a música que estava tocando.
  // Antes o app mandava selectedPlaylistSongId/selectedRegionId com o ID da música parada
  // e apenas stopSelectionTargetId com o próximo alvo. Como campos extras antigos podem
  // não ser lidos por algumas versões do Lua, o azul ficava preso na música parada.
  if (!desiredPlaying && extraPayload && extraPayload.stopSelectionTargetId != null && String(extraPayload.stopSelectionTargetId) !== '' && String(extraPayload.stopSelectionTargetSource || '') !== 'stopped') {
    const stopTargetId = String(extraPayload.stopSelectionTargetId)
    const stopTargetTab = extraPayload.stopSelectionTargetTab || getPreferredStoppedSelectionTab(stopTargetId, sourceTab || state.activeTab || payload.activeTab || 'playlist')
    const stopTargetItem = findSongByIdEverywhere(stopTargetId) || findAnyPlaybackItemById(stopTargetId)

    payload.activeTab = stopTargetTab || payload.activeTab || sourceTab || state.activeTab || 'playlist'
    payload.selectedRegionId = payload.activeTab === 'regions' ? stopTargetId : null
    payload.selectedPlaylistSongId = payload.activeTab === 'playlist' ? stopTargetId : null
    payload.targetId = stopTargetId
    payload.songId = stopTargetId
    payload.nextSelectionId = stopTargetId
    payload.queuedSelectionId = stopTargetId

    if (stopTargetItem && typeof stopTargetItem === 'object') {
      const itemIndex = Number(stopTargetItem.index)
      const itemStart = Number(stopTargetItem.startPos ?? stopTargetItem.start_pos)
      const itemEnd = Number(stopTargetItem.endPos ?? stopTargetItem.end_pos)
      if (Number.isFinite(itemIndex)) payload.stopSelectionPlaylistIndex = itemIndex
      if (Number.isFinite(itemStart)) payload.stopSelectionStartPos = itemStart
      if (Number.isFinite(itemEnd)) payload.stopSelectionEndPos = itemEnd
    }
  }

  payload.noSeek = true
  payload.preserveCursor = true
  payload.transportOnly = true
  payload.activeTab = payload.activeTab || sourceTab || state.activeTab || 'playlist'
  // Play do Diretor não pode reselecionar/reposicionar a música.
  // A seleção já posiciona o cursor; o botão Play só dá transporte no ponto atual.
  const commandName = desiredPlaying ? 'director_play_no_seek' : 'director_stop_no_seek'
  const sent = postCommand(commandName, payload)

  // v2.0.36: após recarregar a página, o primeiro Stop podia ser perdido pelo
  // ciclo inicial do front/Bridge. Stop é idempotente, então fazemos um retry
  // curto apenas para Stop. Play continua sem duplicação.
  if (!desiredPlaying) {
    if (directorStopRetryTimer) clearTimeout(directorStopRetryTimer)
    const retryPayload = { ...payload, appRetry: true, retryReason: 'first_stop_after_reload_guard' }
    directorStopRetryTimer = setTimeout(() => {
      directorStopRetryTimer = null
      const stillLooksActive = !!(state.playingId || getPlaybackUiActive?.() || pendingPlaybackDesiredPlaying === false)
      if (!stillLooksActive) return
      retryPayload.clientCommandId = makeDirectorClientCommandId(commandName, retryPayload)
      postCommand(commandName, retryPayload)
    }, 180)
  }

  return sent
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

  const totalSec = songs.reduce((sum, song) => sum + (Number(song?.durationSec) || 0), 0)
  const lines = []
  const playlistName = String(playlist?.name ?? '').trim()
  if (playlistName) lines.push(playlistName)
  lines.push('')
  lines.push(`Tempo total: ${formatTotalTime(totalSec)}`)
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

function postCommand(type, payload = {}) {
  markDirectorLocalInput(700)
  const commandPayload = payload && typeof payload === 'object' ? { ...payload } : {}
  commandPayload.role = commandPayload.role || 'director'
  commandPayload.clientRole = commandPayload.clientRole || 'director'
  commandPayload.appRole = commandPayload.appRole || 'director'
  commandPayload.source = commandPayload.source || 'director'
  commandPayload.mode = commandPayload.mode || 'director'

  const commandType = String(type || '')
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

function bindPressAction(el, actionKey, handler) {
  if (!el || typeof handler !== 'function') return

  let lastPointerHandledAt = 0

  const run = (event, source) => {
    if (event?.type === 'pointerup' && event.pointerType === 'mouse' && event.button !== 0) return
    if (event?.type === 'click' && (Date.now() - lastPointerHandledAt) < 420) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      return
    }

    event?.preventDefault?.()
    event?.stopPropagation?.()

    // Usa uma chave global unica por botao/acao, sem separar por pointerup/click.
    // Isso evita o bug de executar duas vezes quando o pointerup renderiza a tela
    // e o click sintetico chega logo depois em outro elemento re-renderizado.
    const dedupeKey = String(actionKey || event?.type || 'generic')
    if (isDuplicatePress(dedupeKey, 360)) return

    if (event?.type === 'pointerup') {
      lastPointerHandledAt = Date.now()
    }

    handler(event)
  }

  el.addEventListener('pointerup', (event) => run(event, 'pointerup'))
  el.addEventListener('click', (event) => run(event, 'click'))
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
  if (!el || typeof handler !== 'function') return

  const shouldBlockUnifiedTap = (windowMs = 420) => {
    const key = String(actionKey || '')
    const now = Date.now()
    const last = Number(unifiedTapState.get(key) || 0)
    if (last > 0 && (now - last) < windowMs) return true
    unifiedTapState.set(key, now)
    return false
  }

  const invoke = (event, source) => {
    event?.preventDefault?.()
    event?.stopPropagation?.()
    if (shouldBlockUnifiedTap(source === 'click' ? 520 : 420)) return
    handler(event)
  }

  el.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return
    invoke(event, 'pointerdown')
  }, { passive: false })

  el.addEventListener('click', (event) => {
    invoke(event, 'click')
  })
}


function bindReliableTapAction(el, actionKey, handler) {
  if (!el || typeof handler !== 'function') return

  let downX = 0
  let downY = 0
  let downAt = 0
  let pointerHandledAt = 0
  let hadPointerDown = false
  let movedAsScroll = false

  const run = (event, source) => {
    if (Number(el.__hashLongPressJustFiredUntil || 0) > Date.now()) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      return
    }
    event?.preventDefault?.()
    event?.stopPropagation?.()
    const key = String(actionKey || '')
    const now = Date.now()
    const last = Number(unifiedTapState.get(key) || 0)
    if (last > 0 && (now - last) < 240) return
    unifiedTapState.set(key, now)
    markDirectorLocalInput(820)
    if (source === 'pointerup') pointerHandledAt = now
    handler(event)
  }

  el.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return
    downX = Number(event.clientX) || 0
    downY = Number(event.clientY) || 0
    downAt = Date.now()
    hadPointerDown = true
    movedAsScroll = false

    // Trava o re-render do bridge no início do toque, mas NÃO executa o comando aqui.
    // Executar no pointerdown bloqueava o pan-y e fazia a lista parar de rolar.
    markDirectorLocalInput(900)
  }, { passive: true })

  el.addEventListener('pointermove', (event) => {
    if (!hadPointerDown) return
    const dx = Math.abs((Number(event.clientX) || 0) - downX)
    const dy = Math.abs((Number(event.clientY) || 0) - downY)
    if (dy > 12 || dx > 28) movedAsScroll = true
  }, { passive: true })

  el.addEventListener('pointercancel', () => {
    hadPointerDown = false
    movedAsScroll = true
  }, { passive: true })

  el.addEventListener('pointerup', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return
    const dx = Math.abs((Number(event.clientX) || 0) - downX)
    const dy = Math.abs((Number(event.clientY) || 0) - downY)
    const elapsed = Date.now() - Number(downAt || 0)
    const isScroll = movedAsScroll || dx > 28 || dy > 18 || elapsed > 1200
    hadPointerDown = false
    if (isScroll) return
    run(event, 'pointerup')
  }, { passive: false })

  el.addEventListener('click', (event) => {
    if ((Date.now() - pointerHandledAt) < 520) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      return
    }
    run(event, 'click')
  })
}

function bindPlayTapAction(el, handler) {
  if (!el || typeof handler !== 'function') return

  // v2.0.37: no mobile/PWA, o primeiro Stop depois de recarregar podia ficar preso
  // porque o front esperava o click sintético depois do Play ter re-renderizado o botão.
  // Stop agora dispara no pointerdown/touchstart, que chega antes de qualquer re-render.
  // Play continua no click para não gerar Play duplo.
  let stopPointerHandledAt = 0
  let clickHandledAt = 0

  const swallow = (event) => {
    event?.preventDefault?.()
    event?.stopPropagation?.()
  }

  const runStopNow = (event, source) => {
    if (!getPlaybackUiActive()) return false
    const now = Date.now()
    const last = Math.max(Number(stopPointerHandledAt || 0), Number(clickHandledAt || 0))
    if (last > 0 && (now - last) < 520) {
      swallow(event)
      return true
    }
    stopPointerHandledAt = now
    swallow(event)
    markDirectorLocalInput(1200)
    handler(event)
    return true
  }

  const runClick = (event) => {
    if (event?.button != null && event.button !== 0) return
    const now = Date.now()
    if (stopPointerHandledAt > 0 && (now - stopPointerHandledAt) < 620) {
      swallow(event)
      return
    }
    if (clickHandledAt > 0 && (now - clickHandledAt) < 240) {
      swallow(event)
      return
    }
    clickHandledAt = now
    swallow(event)
    markDirectorLocalInput(900)
    handler(event)
  }

  // Sobrescreve binds antigos acumulados quando bindEvents roda novamente.
  el.onpointerdown = (event) => {
    if (event?.pointerType === 'mouse' && event.button !== 0) return
    runStopNow(event, 'pointerdown')
  }
  el.ontouchstart = (event) => {
    runStopNow(event, 'touchstart')
  }
  el.onpointerup = (event) => {
    if (event?.pointerType === 'mouse' && event.button !== 0) return
    if (stopPointerHandledAt > 0 && (Date.now() - stopPointerHandledAt) < 620) swallow(event)
  }
  el.ontouchend = (event) => {
    if (stopPointerHandledAt > 0 && (Date.now() - stopPointerHandledAt) < 620) swallow(event)
  }
  el.onclick = runClick
}

function bindModalCloseAction(el, actionKey, handler) {
  if (!el || typeof handler !== 'function') return

  const swallow = (event) => {
    event?.preventDefault?.()
    event?.stopPropagation?.()
  }

  const run = (event, source) => {
    if (event?.type === 'pointerup' && event.pointerType === 'mouse' && event.button !== 0) return
    swallow(event)
    const dedupeKey = String(actionKey || 'modal-close')
    if (isDuplicatePress(dedupeKey, source === 'click' ? 420 : 260)) return
    handler(event)
  }

  el.addEventListener('pointerdown', swallow, { passive: false })
  el.addEventListener('pointerup', (event) => run(event, 'pointerup'), { passive: false })
  el.addEventListener('click', (event) => run(event, 'click'))
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
  const bridgeStateUpdatedMs = parseBridgeStateUpdatedMs(data)
  state.lastBridgeUpdatedAtMs = bridgeStateUpdatedMs || 0
  syncDirectorPlaybackClockFromBridge(data)
  state.appActive = !!data.appActive
  state.autoBlocoEnabled = !!data.autoBlocoEnabled
  state.regions = Array.isArray(data.regions) ? data.regions : state.regions
  state.playlists = normalizeBridgePlaylistsWithHashChildren(Array.isArray(data.playlists) ? data.playlists : state.playlists)
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
    if (Array.isArray(data.premix.tracks)) {
      state.premixTracks = data.premix.tracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if (Array.isArray(data.premix.groups)) {
      state.premixGroups = data.premix.groups.map((item) => normalizePremixTrackItem(item, 'groups'))
    }
    if (Array.isArray(data.premix.globalTracks)) {
      state.premixGlobalTracks = data.premix.globalTracks.map((item) => normalizePremixTrackItem(item, 'tracks'))
    }
    if (Array.isArray(data.premix.globalGroups)) {
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

  state.activePlaylistId = typeof data.activePlaylistId === 'string' || data.activePlaylistId === null ? (data.activePlaylistId || null) : state.activePlaylistId

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
      markDirectorRecentlyStoppedSelectionBlocked(previousPlayingId)
      clearStoppedSelectionHold()
      if (String(state.selectedPlaylistSongId || '') === String(previousPlayingId || '')) {
        state.selectedPlaylistSongId = null
        state.selectedPlaylistSongIds = []
      }
      if (String(state.selectedRegionId || '') === String(previousPlayingId || '')) {
        state.selectedRegionId = null
        state.selectedRegionIds = []
      }
      clearDirectorLocalSelectionHold()
      state.selectionLockUntil = 0
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
  state.timerRunning = typeof data.timerRunning === 'boolean' ? data.timerRunning : state.timerRunning
  state.timerStartedAt = Number.isFinite(Number(data.timerStartedAt)) ? Number(data.timerStartedAt) : state.timerStartedAt
  state.timerAccumulatedSec = Number.isFinite(Number(data.timerAccumulatedSec)) ? Number(data.timerAccumulatedSec) : state.timerAccumulatedSec
  state.timerMode = String(data.timerMode || data.timerType || state.timerMode || 'progressive').toLowerCase() === 'countdown' ? 'countdown' : 'progressive'
  state.timerTargetSec = Number.isFinite(Number(data.timerTargetSec)) ? Number(data.timerTargetSec) : state.timerTargetSec
  state.timerDisplaySec = Number.isFinite(Number(data.timerDisplaySec)) ? Number(data.timerDisplaySec) : state.timerDisplaySec
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

  let remoteBaseTab = (data.currentPage === 'playlist' || data.currentPage === 'markers') ? 'playlist' : 'regions'
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
  if ((now - lastAppHeartbeatAt) < 900) return
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
    }, i * 80)
  }
}

async function pollBridge() {
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
  if (state.activeTab !== 'playlist') return
  state.localMarkersMode = true
  state.playlistView = 'markers'
  state.markersPanelAnimateUntil = Date.now() + 360
  state.settingsMenuOpen = false
  state.showTunerModal = false
  postCommand('set_page', { page: 'playlist' })
  postCommand('set_parts_visibility', { page: 'playlist', visible: '1' })
  render()
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
        postCommand('queue_region_song', { ...getPlaybackCommandPayloadForTarget(nextPlayableId, 'regions', false), id: nextPlayableId, targetId: nextPlayableId, activeTab: 'regions' })
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
      postCommand('queue_region_song', { ...getPlaybackCommandPayloadForTarget(key, 'regions', false), id: key, targetId: key, activeTab: 'regions' })
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
  postCommand('select_region', { id: key, activeTab: 'regions' })
  render()
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
    postCommand('autoplay_toggle')
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
        postCommand('queue_playlist_song', { ...getPlaybackCommandPayloadForTarget(nextPlayableId, 'playlist', false), id: nextPlayableId, targetId: nextPlayableId, activeTab: 'playlist' })
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
      postCommand('queue_playlist_song', { ...getPlaybackCommandPayloadForTarget(key, 'playlist', false), id: key, targetId: key, activeTab: 'playlist' })
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
  postCommand('select_playlist_song', { id: key, activeTab: 'playlist' })
  render()
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
    setDirectorMarkerLocalHold(key)
    setDirectorMarkerArmedLocalHold(key)
    postCommand('marker_go', { id: key })
    showAppPopup('MARKER ENGATILHADO', 'marker', 1200)
  } else {
    // Primeiro clique apenas seleciona: fica amarelo.
    state.selectedMarkerId = key
    state.markerGoFlashId = null
    clearDirectorMarkerArmedLocalHold()
    setDirectorMarkerLocalHold(key)
    postCommand('marker_select', { id: key })
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
    clearStoppedSelectionHold()
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
  postCommand('autoplay_toggle', { desiredAutoplay: nextEnabled, desiredState: nextEnabled ? 'on' : 'off' })
  render()
}

function handleAutoBlocoToggle() {
  const nextEnabled = !state.autoBlocoEnabled
  state.autoBlocoEnabled = nextEnabled
  render()
  postCommand('auto_bloco_toggle', { desiredAutoBloco: nextEnabled, desiredState: nextEnabled ? 'on' : 'off' })
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
    // Repertórios -> swipe para esquerda abre Markers.
    state.localMarkersMode = true
    state.playlistView = 'markers'
    state.markersPanelAnimateUntil = Date.now() + 360
    postCommand('set_page', { page: 'playlist' })
    postCommand('set_parts_visibility', { page: 'playlist', visible: '1' })
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
  if (!state.playingId || !item) return false
  const itemId = String(item.id ?? '')
  if (!itemId || String(getDirectorMarkerArmedVisualId?.() || '') !== itemId) return false
  const markerSongId = String(item.songId ?? '')
  if (markerSongId && String(state.playingId || '') !== markerSongId) return false
  const elapsed = getCurrentPlayingElapsedSec()
  if (elapsed == null) return false
  const markerTime = Number(item.timeSec) || 0
  const timeUntilMarker = markerTime - elapsed
  if (timeUntilMarker < -0.08) {
    syncDirectorMarkerArmedVisualWithPlayback?.([item])
    return false
  }
  return timeUntilMarker >= 0
}


function syncDirectorMarkerArmedVisualWithPlayback(markersList = null) {
  const armedId = String(getDirectorMarkerArmedVisualId?.() || '')
  if (!armedId || !state.playingId) return false
  const markers = Array.isArray(markersList) ? markersList : currentMarkers()
  const marker = markers.find((item) => String(item?.id) === armedId)
  if (!marker) return false

  const markerSongId = String(marker.songId ?? '')
  if (markerSongId && String(state.playingId || '') !== markerSongId) return false

  const elapsed = getCurrentPlayingElapsedSec()
  if (elapsed == null) return false
  const markerTime = Number(marker.timeSec)
  if (!Number.isFinite(markerTime)) return false

  // Enquanto ainda não chegou na Part, continua verde e piscando.
  if (elapsed + 0.08 < markerTime) return false

  // Chegou na Part: limpa verde, pisca e botão Cancelar no front, sem depender do Bridge.
  if (String(state.markerGoFlashId || '') === armedId) state.markerGoFlashId = null
  if (String(state.selectedMarkerId || '') === armedId) state.selectedMarkerId = null
  clearDirectorMarkerLocalHold?.()
  clearDirectorMarkerArmedLocalHold?.()
  return true
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
    return `<div class="${classes.join(' ')}" ${attr}${familyAttr}${blockOutlineStyle}>${progressBarHtml}${numberCol}${dragHandle}<div class="leftCol">${labelHtml}</div>${rightColHtml}</div>`
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
  if (!el || el.__hashLongPressBound === '1') return
  el.__hashLongPressBound = '1'
  let timer = null
  let startX = 0
  let startY = 0
  let fired = false

  const clear = () => {
    if (timer) window.clearTimeout(timer)
    timer = null
    document.body.classList.remove('vshookNoTextSelect')
  }

  const run = (event) => {
    fired = true
    el.__hashLongPressJustFiredUntil = Date.now() + 900
    document.body.classList.add('vshookNoTextSelect')
    event?.preventDefault?.()
    event?.stopPropagation?.()
    event?.stopImmediatePropagation?.()
    const id = type === 'region' ? el.getAttribute('data-region-id') : el.getAttribute('data-song-id')
    const activeTab = type === 'region' ? 'regions' : 'playlist'
    vshookToggleHashChildrenFront(el, type)
    markDirectorLocalInput(1500)
    postCommand('toggle_hash_children', {
      id,
      targetId: id,
      selectedRegionId: activeTab === 'regions' ? id : undefined,
      selectedPlaylistSongId: activeTab === 'playlist' ? id : undefined,
      familyGroupId: el.getAttribute('data-family-group-id') || '',
      familyRole: el.getAttribute('data-family-role') || '',
      parentId: el.getAttribute('data-parent-id') || '',
      activeTab,
      page: activeTab,
    })
    showAppPopup('MOSTRAR / OCULTAR FILHOS', 'marker', 1200)
    window.setTimeout(() => document.body.classList.remove('vshookNoTextSelect'), 250)
  }

  const begin = (event, x, y) => {
    if (event?.pointerType === 'mouse' && event.button !== 0) return
    if (type !== 'song') return
    if (state.activeTab !== 'playlist' || state.playlistView === 'markers') return
    if (state.editMode || state.deleteMode || state.dragActive || state.dragPending) return
    fired = false
    startX = Number(x) || 0
    startY = Number(y) || 0
    clear()
    document.body.classList.add('vshookNoTextSelect')
    timer = window.setTimeout(() => run(event), 1000)
  }

  const move = (event, x, y) => {
    if (!timer) return
    const dx = Math.abs((Number(x) || 0) - startX)
    const dy = Math.abs((Number(y) || 0) - startY)
    if (dx > 24 || dy > 24) clear()
  }

  const finish = (event) => {
    const wasFired = fired
    clear()
    if (wasFired) {
      event?.preventDefault?.()
      event?.stopPropagation?.()
      event?.stopImmediatePropagation?.()
    }
    window.setTimeout(() => { fired = false }, 160)
  }

  el.addEventListener('pointerdown', (event) => begin(event, event.clientX, event.clientY), { passive: false })
  el.addEventListener('pointermove', (event) => move(event, event.clientX, event.clientY), { passive: true })
  el.addEventListener('pointerup', finish, { passive: false })
  el.addEventListener('pointercancel', finish, { passive: false })

  el.addEventListener('touchstart', (event) => {
    const t = event.changedTouches && event.changedTouches[0]
    begin(event, t?.clientX, t?.clientY)
  }, { passive: false })
  el.addEventListener('touchmove', (event) => {
    const t = event.changedTouches && event.changedTouches[0]
    move(event, t?.clientX, t?.clientY)
  }, { passive: true })
  el.addEventListener('touchend', finish, { passive: false })
  el.addEventListener('touchcancel', finish, { passive: false })

  el.addEventListener('contextmenu', (event) => {
    event.preventDefault()
    event.stopPropagation()
  })
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
  document.querySelectorAll('[data-timer-part]').forEach((input) => {
    input.addEventListener('input', syncTimerTargetPreviewFromInputs)
    input.addEventListener('change', syncTimerTargetPreviewFromInputs)
  })
  document.querySelector('[data-action="live-toggle"]')?.addEventListener('click', handleLiveToggleFromMenu)
  document.querySelector('[data-action="confirm-live-off"]')?.addEventListener('click', confirmLiveOffFromMenu)
  document.querySelector('[data-action="cancel-live-off"]')?.addEventListener('click', cancelLiveOffFromMenu)
  bindReliableTapAction(document.querySelector('[data-action="toggle-settings"]'), 'toggle-settings', handleToggleSettingsMenu)
  bindReliableTapAction(document.querySelector('[data-action="open-project-tabs"]'), 'open-project-tabs', openProjectTabsModal)
  document.querySelector('[data-action="open-recados"]')?.addEventListener('click', openRecadosModal)
  document.querySelector('[data-action="open-gear"]')?.addEventListener('click', (event) => { event.preventDefault(); event.stopPropagation(); openGearModal() })
  document.querySelector('[data-action="close-gear"]')?.addEventListener('click', closeGearModal)
  document.querySelector('[data-action="back-project-selector"]')?.addEventListener('click', backToVSHookProjectSelector)
  document.querySelector('[data-action="close-project-tabs"]')?.addEventListener('click', closeProjectTabsModal)
  document.querySelector('[data-action="recados-send"]')?.addEventListener('click', sendDirectorRecado)
  document.querySelector('[data-action="recados-cancel"]')?.addEventListener('click', cancelDirectorRecado)
  document.querySelector('[data-action="recados-close"]')?.addEventListener('click', closeRecadosModal)
  document.getElementById('recadosDirectorTextarea')?.addEventListener('input', handleRecadosInputChange)
  document.querySelector('[data-action="confirm-project-tabs"]')?.addEventListener('click', confirmProjectTabsModal)
  document.querySelector('[data-close-project-tabs]')?.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeProjectTabsModal() })
  document.querySelector('[data-close-recados]')?.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeRecadosModal() })
  document.querySelectorAll('[data-project-tab-index]').forEach((el) => el.addEventListener('click', () => selectProjectTabInModal(el.getAttribute('data-project-tab-index'))))
  document.querySelector('[data-action="cycle-rgb-mode"]')?.addEventListener('click', cycleRgbMode)
  document.querySelector('[data-action="theme-light"]')?.addEventListener('click', () => setTheme('light'))
  document.querySelector('[data-action="theme-dark"]')?.addEventListener('click', () => setTheme('dark'))
  document.querySelector('[data-action="toggle-select"]')?.addEventListener('click', handleSelectAction)
  document.querySelector('[data-action="copy-playlist-names"]')?.addEventListener('click', handleCopyPlaylistNames)
  bindPressAction(document.querySelector('[data-action="open-mixer"]'), 'open-mixer', () => openMixerModal('tracks'))
  bindPremixMenuButton(document.querySelector('[data-action="open-premix"]'))
  bindPremixGlobalMenuButton(document.querySelector('[data-action="open-premix-global"]'))
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
  document.querySelector('[data-action="close-lyrics-panel"]')?.addEventListener('click', closeLyricsPanel)
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

function render() {

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
  const topTimerHtml = `<button class="topTimerButton ${state.timerRunning ? 'topTimerButtonRunning' : ''}" data-action="open-timer"><span data-chrono-display>${timerText}</span></button>`
  const topTime = state.activeTab === 'playlist'
    ? `${formatTotalTime(vshookSumRootDuration(playlist?.songs || []))}`
    : `${formatTotalTime(vshookSumRootDuration(state.regions))}`

  // 2.0.35: Cancelar de Markers aparece somente quando o marker estiver verde/engatilhado.
  // O rodapé reserva espaço fixo na tela de Markers para o botão não cobrir a lista.
  const markerCancelVisible = shouldShowDirectorMarkerCancelButton()
  const showMarkerFooterSpace = isMarkersPanelOpen()
  const markerFooterHtml = state.playlistView === 'markers'
    ? `<div class="directorMarkersCancelFooter ${markerCancelVisible ? 'directorMarkersCancelFooterActive' : 'directorMarkersCancelFooterIdle'}">${markerCancelVisible ? `<button class="directorMarkersCancelButton markerCancelGlobalButton" data-action="marker-cancel" type="button">Cancelar</button>` : ''}</div>`
    : ''
  const markerCancelGlobalButton = ''

  const content = state.activeTab === 'regions'
    ? `<div class="contentPanel"><div class="controlsStickyPanel"><div class="controlsRowPlaylist controlsRowEqual controlsRowDirectorMain"><button class="${getPlayButtonClass()}" data-action="play">${getPlayButtonLabel()}</button><button class="${getAutoplayVisualEnabled() ? 'btnAutoplayActive' : 'btn'}" data-action="autoplay">AUTO</button><button class="tab btnLyricsOpen lyricsNavButton lyricsNavButtonInline" data-action="open-lyrics-panel">&lt;&lt;</button></div>${renderNowPlayingBanner()}</div><div class="listBox">${renderRows(vshookRootFamilyItems(state.regions), 'region')}</div></div>`
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
    ? `<div class="settingsMenu" data-settings-menu><button class="settingsAction" data-action="open-project-tabs">PROJETOS</button><button class="settingsAction" data-action="open-mixer">MIXER</button><button class="settingsAction settingsActionPremix" data-action="open-premix">PREMIX</button><button class="settingsAction settingsActionPremixGlobal" data-action="open-premix-global">GLOBAL</button><button class="settingsAction settingsActionTuner" data-action="open-tuner">TUNER</button><button class="settingsAction ${state.liveModeEnabled ? 'settingsActionActive' : ''}" data-action="live-toggle">LIVE</button><button class="settingsAction settingsActionRecados" data-action="open-recados">RECADOS</button>${state.activeTab === 'playlist' && state.playlistView !== 'markers' ? `<button class="settingsAction ${state.autoBlocoEnabled ? 'settingsActionActive' : ''}" data-action="auto-bloco">AT/BL</button><button class="settingsAction settingsActionCopy" data-action="copy-playlist-names" ${canCopyPlaylistNames ? '' : 'disabled'}>COPY</button>` : ''}</div>`
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
    ? `<div class="modalOverlay" data-close-gear><div class="modalSpacer"></div><div class="modalBox settingsModalBox" data-stop-modal><div class="modalTitle">CONFIGURAÇÕES</div><div class="bridgeStatusCard"><span class="bridgeStatusLabel">CONEXÃO</span><span class="${state.bridgeStatus === 'online' ? 'bridgeOnline' : 'bridgeOffline'}">${state.bridgeStatus === 'online' ? 'ON' : 'OFF'}</span></div><div class="settingsSectionTitle">BORDA RGB</div><div class="settingsGrid settingsGridSingle"><button class="settingsToggleBtn settingsToggleWide" data-action="cycle-rgb-mode">RGB: ${getRgbModeLabel()}</button></div><div class="settingsSectionTitle">TEMA</div><div class="settingsGrid settingsGridTheme"><button class="${state.theme === 'dark' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-dark">ESCURO</button><button class="${state.theme === 'light' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-light">CLARO</button></div><div class="modalButtons settingsBottomButtons"><button class="modalCancelBtn vshookExitButton" data-action="back-project-selector">SAIR</button><button class="modalOkBtnWide settingsCloseButton" data-action="close-gear">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
    : ''

  const timerModalTitle = state.timerRunning ? 'DESEJA PARAR?' : 'DESEJA INICIAR?'
  const timerModeLabel = state.timerMode === 'countdown' ? 'REGRESSIVO' : 'PROGRESSIVO'
  const timerTargetParts = getTimerTargetPartsFromSeconds(state.timerTargetSec || 0)
  const timerTargetEditor = state.timerMode === 'countdown'
    ? `<div class="timerTargetEditor"><div class="timerTargetLabel">TEMPO REGRESSIVO</div><div class="timerTargetGrid"><label>H<input data-timer-part="h" type="number" inputmode="numeric" min="0" max="99" value="${timerTargetParts.h}"></label><label>M<input data-timer-part="m" type="number" inputmode="numeric" min="0" max="59" value="${timerTargetParts.m}"></label><label>S<input data-timer-part="s" type="number" inputmode="numeric" min="0" max="59" value="${timerTargetParts.s}"></label></div></div>`
    : ''
  const timerConfirmLabel = state.timerRunning ? 'PARAR' : 'INICIAR'
  const timerModal = state.showTimerModal
    ? `<div class="modalOverlay" data-close-timer><div class="modalSpacer"></div><div class="modalBox timerModalBox timerModalBoxWide" data-stop-modal><div class="modalTitle">CRONÔMETRO</div><div class="timerModalPreview" data-chrono-display>${state.timerMode === 'countdown' && !state.timerRunning ? formatChronoTime(state.timerTargetSec || 0) : timerText}</div><div class="timerModeCurrent">MODO: ${timerModeLabel}</div><div class="timerModeGrid"><button class="${state.timerMode === 'progressive' ? 'modalOkBtnWide' : 'modalCancelBtn'}" data-action="timer-mode-progressive">PROGRESSIVO</button><button class="${state.timerMode === 'countdown' ? 'modalOkBtnWide' : 'modalCancelBtn'}" data-action="timer-mode-countdown">REGRESSIVO</button></div>${timerTargetEditor}<div class="modalTitle timerModalActionTitle">${timerModalTitle}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="close-timer">SAIR</button><button class="modalOkBtnWide" data-action="confirm-timer">${timerConfirmLabel}</button></div></div><div class="modalBottomSpace"></div></div>`
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

  app.innerHTML = `<div class="app" data-theme="${state.theme}" style="--app-border-color:${appBorderColor};--app-border-glow:${appBorderGlow};"><style>.app{height:var(--app-vh,100dvh);min-height:var(--app-vh,100dvh);overflow:hidden}.container{height:calc(var(--app-vh,100dvh) - 16px)!important;min-height:calc(var(--app-vh,100dvh) - 16px)!important;overflow:hidden}@media (max-width:480px){.container{height:calc(var(--app-vh,100dvh) - 12px)!important;min-height:calc(var(--app-vh,100dvh) - 12px)!important}}.contentPanel{display:flex;flex-direction:column;flex:1;min-height:0;padding-bottom:2px}.controlsStickyPanel{flex:0 0 auto;position:relative;z-index:4;background:linear-gradient(180deg,#0a1018 0%,#06090f 100%)}.topTimerButton{min-width:96px;height:34px;padding:0 10px;border-radius:10px;border:1px solid #475569;background:#111827;color:#facc15;font-weight:900;font-size:14px;letter-spacing:.03em}.topTimerButtonRunning{border-color:#22c55e;background:#052e16;color:#86efac;box-shadow:0 0 0 1px rgba(34,197,94,.28),0 0 16px rgba(34,197,94,.14)}.timerModalBox{max-width:330px}.timerModalBoxWide{width:min(92vw,480px)!important;max-width:480px!important}.timerModeGrid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}.timerModeGrid button{min-height:44px;border-radius:12px;font-weight:900}.timerModeCurrent{text-align:center;color:#facc15;font-weight:900;margin:-4px 0 6px}.timerTargetEditor{margin:10px 0 8px;padding:10px;border:1px solid rgba(250,204,21,.35);border-radius:12px;background:rgba(250,204,21,.08)}.timerTargetLabel{text-align:center;color:#fde68a;font-weight:900;font-size:13px;margin-bottom:8px}.timerTargetGrid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}.timerTargetGrid label{display:flex;flex-direction:column;gap:5px;text-align:center;color:#cbd5e1;font-weight:900;font-size:12px}.timerTargetGrid input{width:100%;height:42px;border-radius:10px;border:1px solid #475569;background:#020617;color:#f8fafc;text-align:center;font-weight:900;font-size:18px;box-sizing:border-box}.app[data-theme="light"] .timerTargetGrid input{background:#fff;color:#0f172a;border-color:#cbd5e1}.timerModalActionTitle{font-size:14px!important;margin-top:6px!important}.modalInfoText{color:#e5e7eb;text-align:center;font-weight:800;line-height:1.35;margin:12px 0 16px}.timerModalPreview{height:54px;display:flex;align-items:center;justify-content:center;border:1px solid #374151;border-radius:10px;background:#05070a;color:#facc15;font-size:22px;font-weight:900;margin-bottom:14px}.progressBar{position:absolute;left:0;top:0;bottom:0;opacity:1;background:linear-gradient(90deg,#22c55e 0%,#16a34a 100%);pointer-events:none;border-radius:0;box-shadow:inset 0 0 0 1px rgba(134,239,172,.28),0 0 10px rgba(34,197,94,.22)}.progressBarWithNumber{left:42px}.sectionLabelSticky{margin-bottom:8px}.listBox{flex:1 1 auto;min-height:0;overflow-y:auto;overflow-x:hidden;padding-bottom:calc(env(safe-area-inset-bottom,0px) + 118px);scroll-padding-bottom:calc(env(safe-area-inset-bottom,0px) + 118px)}.markersNavButtonWide{min-width:88px;padding:10px 24px;font-size:22px;justify-content:center}.headerTotalSpacer{flex:1 1 auto;min-width:4px}.headerNavStack{display:flex;flex-direction:column;gap:4px;align-items:stretch}.headerNavFloating{position:absolute;right:12px;top:76px;z-index:8;width:88px}.headerNavFloatingSingle{position:absolute;right:12px;top:120px;z-index:8;width:88px}.headerLyricsButton{padding-top:8px;padding-bottom:8px;font-size:20px}.markersInlineBackButton{height:46px!important;min-height:46px!important;padding:0 10px!important;font-size:18px!important;border-radius:12px!important}.markerLoopButton{height:46px!important;min-height:46px!important;border-radius:12px!important;font-size:18px!important}.markerBackLyricsButton{background:linear-gradient(180deg,#facc15 0%,#d97706 100%)!important;border-color:#fde047!important;color:#111827!important;box-shadow:0 0 0 1px rgba(250,204,21,.35),0 0 12px rgba(250,204,21,.22)!important}.settingsBottomButtons{display:grid!important;grid-template-columns:1fr 1fr!important;gap:10px!important;margin-top:26px!important}.settingsBottomButtons>*{width:100%!important;min-height:46px!important;border-radius:12px!important;font-weight:900!important}.settingsCloseButton{border:1px solid #475569!important;background:#111827!important;color:#f8fafc!important}@keyframes appPopupFade{0%{opacity:0;transform:translateX(-50%) translateY(8px)}12%{opacity:1;transform:translateX(-50%) translateY(0)}78%{opacity:1;transform:translateX(-50%) translateY(0)}100%{opacity:0;transform:translateX(-50%) translateY(10px)}}@keyframes loopBlinkPulse{0%{opacity:1;box-shadow:0 0 0 rgba(250,204,21,0)}50%{opacity:.38;box-shadow:0 0 16px rgba(250,204,21,.58)}100%{opacity:1;box-shadow:0 0 0 rgba(250,204,21,0)}}.loopBlink{animation:loopBlinkPulse .58s linear infinite}.appPopup{position:fixed;left:50%;bottom:22px;top:auto;transform:translateX(-50%) translateY(0);z-index:3000;width:min(86vw,520px);min-height:78px;padding:16px 22px;border-radius:10px;font-weight:900;font-size:22px;line-height:1.18;text-align:center;display:flex;align-items:center;justify-content:center;box-shadow:0 18px 42px rgba(0,0,0,.46);border:1px solid rgba(255,255,255,.16);backdrop-filter:blur(8px);opacity:1;transition:opacity .22s ease,transform .22s ease}.appPopupTransient{animation:none;opacity:1;transform:translateX(-50%) translateY(0)}.appPopupHidden{opacity:0;transform:translateX(-50%) translateY(10px)}.appPopupInfo{background:rgba(17,24,39,.97);color:#f8fafc}.appPopupSuccess{background:rgba(21,128,61,.97);color:#fff}.appPopupMarker{background:rgba(250,204,21,.98);color:#111827;border-color:rgba(255,255,255,.35)}.appPopupError{background:rgba(185,28,28,.97);color:#fff}.appPopupPersistent{animation:none;opacity:1;transform:translateX(-50%) translateY(0)}@media (max-width:480px){.appPopup{width:min(88vw,460px);min-height:66px;padding:12px 16px;font-size:18px}.markersNavButtonWide{min-width:82px;padding:10px 20px;font-size:20px}.headerNavFloating{right:10px;top:72px;width:82px}.headerNavFloatingSingle{right:10px;top:114px;width:82px}.topTimerButton{min-width:88px;height:32px;font-size:13px;padding:0 8px}.timerModalPreview{font-size:20px;height:50px}}.mixerOverlay{align-items:center;justify-content:flex-start}.mixerVolumeOverlay{align-items:center;justify-content:flex-start;background:rgba(0,0,0,.52)}.mixerModalBox,.mixerVolumeModalBox,.bpmModalBox{width:min(92vw,420px)}.mixerRowsBox{border:1px solid #364152;border-radius:10px;background:#0b1220}.mixerRow{display:grid;grid-template-columns:10px 34px minmax(0,1fr) 58px 10px 38px 38px;align-items:center;gap:8px;padding:10px 10px;border-bottom:1px solid #18212c;min-height:56px;touch-action:pan-y}.mixerRow:last-child{border-bottom:none}.mixerRowColor{width:8px;height:36px;border-radius:999px;background:var(--mixer-color,#334155)}.mixerRowIndex{font-weight:900;color:#cbd5e1;text-align:center}.mixerRowMain{min-width:0}.mixerRowName{font-weight:900;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowGroupName{font-size:11px;color:#94a3b8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowDb{font-weight:900;color:#e2e8f0;text-align:right}.mixerMeter{position:relative;width:10px;height:38px;border-radius:999px;background:#111827;overflow:hidden;border:1px solid #334155}.mixerMeterFill{position:absolute;left:0;right:0;bottom:0;border-radius:999px;background:linear-gradient(180deg,#22c55e 0%,#16a34a 100%)}.mixerMiniBtn{height:34px;width:34px;border-radius:8px;border:1px solid #475569;background:#111827;color:#f8fafc;font-weight:900}.mixerMiniBtnActive{background:#15803d;border-color:#22c55e;color:#fff}.mixerVolumeTitle{margin:8px 0 14px;padding:12px 14px;border-radius:10px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);box-shadow:inset 3px 0 0 var(--mixer-color,#334155);font-weight:900}.mixerVolumeMeterWrap{display:flex;align-items:center;justify-content:center;gap:14px;margin-bottom:14px}.mixerVolumeDb{font-size:28px;font-weight:900;color:#f8fafc}.mixerVolumeSlider{width:100%;height:46px;appearance:none;background:transparent;touch-action:pan-x;will-change:transform}.mixerVolumeSlider::-webkit-slider-runnable-track{height:14px;border-radius:999px;background:#1f2937;border:1px solid #475569}.mixerVolumeSlider::-webkit-slider-thumb{-webkit-appearance:none;appearance:none;width:30px;height:30px;border-radius:50%;background:#22c55e;border:2px solid #ecfdf5;box-shadow:0 0 0 3px rgba(34,197,94,.18);margin-top:-9px}.mixerVolumeSlider::-moz-range-track{height:14px;border-radius:999px;background:#1f2937;border:1px solid #475569}.mixerVolumeSlider::-moz-range-thumb{width:30px;height:30px;border-radius:50%;background:#22c55e;border:2px solid #ecfdf5;box-shadow:0 0 0 3px rgba(34,197,94,.18)}.mixerSwipeHint{margin-top:12px}.bpmModalBox{max-width:320px}.bpmValueDisplay{font-size:42px;font-weight:900;text-align:center;margin:8px 0 10px;color:#f8fafc}.bpmMetaText{text-align:center;color:#cbd5e1;font-weight:700;margin-bottom:14px}.bpmControlsSimple{display:grid;grid-template-columns:1fr 1fr;gap:10px}.bpmAdjustBtn{height:52px;border-radius:12px;border:1px solid #22c55e;background:#15803d;color:#fff;font-size:28px;font-weight:900}.settingsActionTuner{background:#102a20;border-color:#34d399;color:#a7f3d0}.tunerOverlay{z-index:1670;align-items:stretch;justify-content:flex-end;padding:0;background:rgba(0,0,0,.45)}.tunerDrawer{width:clamp(260px,52vw,430px);height:var(--app-vh,100dvh);background:#111827;border-left:1px solid #364152;box-shadow:-18px 0 42px rgba(0,0,0,.45);padding:16px 14px 20px;display:flex;flex-direction:column;gap:10px;overflow:hidden}.tunerDrawerHeader{display:flex;align-items:flex-start;justify-content:space-between;gap:8px}.tunerDrawerSub{color:#94a3b8;font-weight:700;font-size:12px;margin-top:-4px}.tunerDrawerActions{display:flex;justify-content:flex-end}.tunerResetBtn{min-height:40px;padding:0 14px;border-radius:10px;border:1px solid #facc15;background:#3b2f0b;color:#fde68a;font-weight:900}.tunerRowsBox{flex:1 1 auto;min-height:0;overflow-y:auto;border:1px solid #364152;border-radius:10px;background:#0b1220}.tunerRow{display:grid;grid-template-columns:minmax(0,1fr);gap:8px;padding:10px;border-bottom:1px solid #18212c}.tunerRow:last-child{border-bottom:none}.tunerRowName{font-weight:900;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tunerRowBlock .tunerRowName{color:#facc15}.tunerRowControls{display:grid;grid-template-columns:58px minmax(64px,1fr) 58px;gap:4px;align-items:center}.tunerAdjustHitBtn{height:58px;width:58px;border:0;background:transparent;padding:0;margin:0;display:flex;align-items:center;justify-content:center;touch-action:manipulation;-webkit-tap-highlight-color:transparent}.tunerAdjustBtnFace{height:42px;width:42px;border-radius:10px;border:1px solid #475569;background:#111827;color:#f8fafc;font-size:24px;font-weight:900;display:flex;align-items:center;justify-content:center;box-sizing:border-box;pointer-events:none}.tunerValueBox{height:42px;border-radius:10px;border:1px solid #334155;background:#020617;color:#facc15;font-weight:900;font-size:20px;display:flex;align-items:center;justify-content:center}.app[data-theme="light"] .settingsActionTuner{background:#d1fae5;color:#065f46}.app[data-theme="light"] .tunerDrawer{background:#ffffff;border-left-color:#dbe4ee}.app[data-theme="light"] .tunerRowsBox{background:#f8fafc;border-color:#dbe4ee}.app[data-theme="light"] .tunerRowName{color:#0f172a}@media (max-width:480px){.tunerDrawer{width:calc(50vw + 26px);min-width:260px;padding:14px 12px 18px}.tunerRowControls{grid-template-columns:54px minmax(58px,1fr) 54px;gap:2px}.tunerAdjustHitBtn{height:54px;width:54px}.tunerAdjustBtnFace{height:38px;width:38px}.tunerValueBox{height:38px}}.markerFooterContainer .listBox{padding-bottom:160px!important;scroll-padding-bottom:160px!important}.vshookMarkerFooter{position:fixed;left:8px;right:8px;bottom:calc(env(safe-area-inset-bottom,0px) + 104px);z-index:2990;display:flex;justify-content:center;pointer-events:none}.vshookMarkerFooter .floatingCancelButton{position:static!important;left:auto!important;right:auto!important;bottom:auto!important;transform:none!important;width:min(62vw,280px)!important;min-width:190px!important;pointer-events:auto}.app:has(.vshookMarkerFooter) .appPopup{bottom:calc(env(safe-area-inset-bottom,0px) + 12px)!important}.app:has(.vshookMarkerFooter) .contentPanel{padding-bottom:0!important}@media(max-width:480px){.markerFooterContainer .listBox{padding-bottom:150px!important;scroll-padding-bottom:150px!important}.vshookMarkerFooter{bottom:calc(env(safe-area-inset-bottom,0px) + 98px)}}.markerGoConfirmed{background:#16a34a!important;border-color:#22c55e!important;color:#fff!important;box-shadow:inset 0 0 0 1px rgba(134,239,172,.38),0 0 16px rgba(34,197,94,.28)!important}.markerGoConfirmed .text,.markerGoConfirmed .timeText,.markerGoConfirmed .markerSelectedText,.markerGoConfirmed .markerSelectedTimeText,.markerGoConfirmed .marqueeStatic,.markerGoConfirmed .marqueeTrack,.markerGoConfirmed .marqueeSegment{color:#fff!important}.markerContentPanel{display:flex;flex-direction:column;min-height:0}.markerListBox{flex:1 1 auto;min-height:0;overflow-y:auto;padding-bottom:8px!important;scroll-padding-bottom:12px!important;border-bottom-left-radius:0;border-bottom-right-radius:0}.vshookFixedFooter{flex:0 0 155px!important;min-height:155px!important;margin-top:6px!important;padding:10px 12px calc(env(safe-area-inset-bottom,0px) + 10px)!important;border-top:1px solid rgba(148,163,184,.32);background:linear-gradient(180deg,rgba(15,23,42,.98),rgba(2,6,23,.99));display:flex;align-items:flex-start;justify-content:center;position:relative;z-index:20}.vshookFixedFooter .floatingCancelButton{position:static!important;left:auto!important;right:auto!important;bottom:auto!important;transform:none!important;width:min(62vw,280px)!important;min-width:190px!important;height:54px!important;pointer-events:auto;z-index:2}.footerButtonPlaceholder{height:54px}.app:has(.vshookFixedFooter) .appPopup{bottom:calc(env(safe-area-inset-bottom,0px) + 14px)!important;z-index:3010;min-height:54px!important;padding:9px 14px!important;font-size:17px!important;width:min(76vw,340px)!important;line-height:1.06!important}@media(max-width:480px){.vshookFixedFooter{flex-basis:148px;min-height:148px}.vshookFixedFooter .floatingCancelButton{height:52px!important}.app:has(.vshookFixedFooter) .appPopup{min-height:50px!important;padding:8px 12px!important;font-size:16px!important;width:min(74vw,320px)!important}}.controlsStickyPanel .controlsRowDirectorMain{grid-template-columns:minmax(112px,1fr) minmax(112px,1fr) minmax(112px,1fr)!important;gap:8px!important;width:100%!important;max-width:100%!important;justify-content:stretch!important}.controlsStickyPanel .controlsRowDirectorMain>*{width:100%!important;max-width:none!important;height:46px!important;min-height:46px!important;font-size:18px!important;border-radius:12px!important}.lyricsNavButtonInline{border-color:#38bdf8!important;background:linear-gradient(180deg,#0284c7 0%,#075985 100%)!important;color:#fff!important;box-shadow:0 0 0 1px rgba(56,189,248,.30),0 0 12px rgba(14,165,233,.20)!important}.tabRow{padding-right:86px!important}.tabRow .headerNavButtons{width:82px!important}.tabRow .markersNavButtonHeader{flex:0 0 82px!important;width:82px!important;min-width:82px!important}.tabRow .lyricsNavButtonHeader{display:none!important}@media(max-width:380px){.controlsStickyPanel .controlsRowDirectorMain{grid-template-columns:minmax(96px,1fr) minmax(96px,1fr) minmax(96px,1fr)!important;gap:7px!important}.controlsStickyPanel .controlsRowDirectorMain>*{height:44px!important;min-height:44px!important;font-size:17px!important}.tabRow{padding-right:78px!important}.tabRow .headerNavButtons{width:74px!important}.tabRow .markersNavButtonHeader{flex-basis:74px!important;width:74px!important;min-width:74px!important}}.controlsStickyPanel .controlsRowMarkers{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1fr)!important;gap:8px!important;width:100%!important;max-width:100%!important;justify-content:stretch!important}.controlsStickyPanel .controlsRowMarkers>*{width:100%!important;max-width:none!important;height:46px!important;min-height:46px!important;font-size:18px!important;border-radius:12px!important;padding:0 10px!important}.markerLoopButton,.markersInlineBackButton{height:46px!important;min-height:46px!important}.markerOpenYellowButton,.tabRow .markerOpenYellowButton,.tabRow .markersNavButtonHeader{background:linear-gradient(180deg,#facc15 0%,#d97706 100%)!important;border-color:#fde047!important;color:#111827!important;box-shadow:0 0 0 1px rgba(250,204,21,.35),0 0 12px rgba(250,204,21,.22)!important}.tabRow .headerNavButtons{width:92px!important}.tabRow .markersNavButtonHeader{flex:0 0 92px!important;width:92px!important;min-width:92px!important}.tabRow{padding-right:96px!important}.contentPanel .sectionLabel,.controlsStickyPanel .sectionLabelSticky{display:none!important}@media(max-width:380px){.controlsStickyPanel .controlsRowMarkers{gap:7px!important}.controlsStickyPanel .controlsRowMarkers>*{height:44px!important;min-height:44px!important;font-size:17px!important}.tabRow .headerNavButtons{width:84px!important}.tabRow .markersNavButtonHeader{flex-basis:84px!important;width:84px!important;min-width:84px!important}.tabRow{padding-right:88px!important}}/* v121 - ajustes finos Diretor: Play padronizado e contorno da aba Músicas */.controlsStickyPanel .controlsRowRegions.controlsRowEqual {  display: grid !important;  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr) !important;  gap: 8px !important;  width: 100% !important;  max-width: 100% !important;  justify-content: stretch !important;}.controlsStickyPanel .controlsRowRegions.controlsRowEqual > * {  height: 46px !important;  min-height: 46px !important;  max-height: 46px !important;  padding: 0 10px !important;  border-radius: 12px !important;  font-size: 18px !important;  line-height: 1 !important;  box-sizing: border-box !important;}.regionsTopLabel {  display: flex !important;  align-items: center !important;  min-height: 42px !important;  width: 100% !important;  min-width: 0 !important;  padding: 8px 12px !important;  border-radius: 10px !important;  border: 1px solid #374151 !important;  background: rgba(15, 23, 42, 0.9) !important;  color: #f8fafc !important;  font-weight: 900 !important;  box-sizing: border-box !important;  white-space: nowrap !important;  overflow: hidden !important;  text-overflow: ellipsis !important;}.app[data-theme="light"] .regionsTopLabel {  background: #ffffff !important;  border-color: #cbd5e1 !important;  color: #0f172a !important;}@media(max-width:380px){  .controlsStickyPanel .controlsRowRegions.controlsRowEqual > * {    height: 44px !important;    min-height: 44px !important;    max-height: 44px !important;    font-size: 17px !important;  }}.app .controlsStickyPanel .controlsRowRegions.controlsRowEqual > button[data-action="play"]{width:100%!important;font-size:15px!important;letter-spacing:0!important;padding:0 6px!important;justify-self:stretch!important;}.settingsActionPremix{background:#1f1637!important;border-color:#8b5cf6!important;color:#ddd6fe!important}.settingsActionPremixGlobal{background:#241b09!important;border-color:#f59e0b!important;color:#fde68a!important}.premixTopControls{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:10px}.premixTopControls button{height:42px;border-radius:12px;font-weight:900}.premixPlayButton{width:100%!important}.premixLockMessage{margin:-2px 0 10px;padding:10px;border:1px solid rgba(239,68,68,.65);border-radius:10px;background:rgba(127,29,29,.45);color:#fecaca;font-weight:900;text-align:center}.premixMixerRowDisabled{opacity:.58}.premixModalBoxFull,.mixerModalBoxFull{padding:14px!important}.premixRowsBoxFull{max-height:none!important}.premixVolumeModalBoxFull{padding:16px!important}.mixerModalBoxFull .mixerRowsBox{max-height:none!important}.premixSongStatus{display:inline-flex;align-items:center;justify-content:center;min-width:42px;height:24px;border-radius:999px;margin-left:8px;font-weight:900;font-size:12px;border:1px solid #475569}.premixSongStatusOn{background:#14532d;color:#bbf7d0;border-color:#22c55e}.premixSongStatusOff{background:#3f1d1d;color:#fecaca;border-color:#ef4444}.premixMixerRow{cursor:pointer}.premixVolumeOverlay{background:rgba(0,0,0,.56)}.premixBlockRow{justify-content:center!important;border-color:rgba(250,204,21,.45)!important;background:rgba(250,204,21,.10)!important;pointer-events:none!important}.premixBlockRow .songRowLabel{width:100%;text-align:center;font-weight:900;letter-spacing:.08em;color:var(--premix-row-color,#facc15)!important}.mixerCloseBtn{touch-action:manipulation!important;pointer-events:auto!important;min-width:86px!important;min-height:38px!important;position:relative!important;z-index:5!important}.app .item.playing{background:#b91c1c!important;border-color:#ef4444!important;box-shadow:inset 0 0 0 1px rgba(248,113,113,.36)!important}.app .item.playing.selectedBlue,.app .item.playing.selectedPink,.app .item.playing.queuedYellow{background:#b91c1c!important}.app .item.playing .rowLabelText,.app .item.playing .timeText,.app .item.playing .playingText,.app .item.playing .playingTimeText{color:#fff!important;font-weight:900!important}.hashChildItem{overflow:hidden;will-change:transform,opacity,max-height}.hashChildExpandIn{animation:vshookHashDrawerOpen .24s ease-out both}.hashChildCollapseOut{animation:vshookHashDrawerClose .20s ease-in both}@keyframes vshookHashDrawerOpen{0%{opacity:0;max-height:0;transform:translateY(-8px) scaleY(.86)}100%{opacity:1;max-height:64px;transform:translateY(0) scaleY(1)}}@keyframes vshookHashDrawerClose{0%{opacity:1;max-height:64px;transform:translateY(0) scaleY(1)}100%{opacity:0;max-height:0;transform:translateY(-8px) scaleY(.86)}}.vshookMarkerCancelOverlay{position:fixed!important;left:50%!important;bottom:calc(env(safe-area-inset-bottom,0px) + 18px)!important;transform:translateX(-50%)!important;z-index:9999!important;min-width:210px!important;height:56px!important;border-radius:14px!important;border:2px solid #fecaca!important;background:linear-gradient(180deg,#ef4444 0%,#991b1b 100%)!important;color:#fff!important;font-weight:1000!important;font-size:20px!important;text-transform:uppercase!important;letter-spacing:.05em!important;box-shadow:0 0 0 1px rgba(255,255,255,.18),0 0 22px rgba(239,68,68,.36)!important;pointer-events:auto!important;touch-action:manipulation!important}.vshookMarkerCancelOverlay:active{transform:translateX(-50%) scale(.97)!important}.container.markerFooterContainer .listBox.markerListBox{padding-bottom:calc(env(safe-area-inset-bottom,0px) + 160px)!important}.container.markerFooterContainer .listBox.markerListBox{padding-bottom:12px!important;scroll-padding-bottom:12px!important}.directorMarkersCancelFooter{flex:0 0 auto;min-height:calc(env(safe-area-inset-bottom,0px) + 84px);display:flex;align-items:center;justify-content:center;padding:10px 12px calc(env(safe-area-inset-bottom,0px) + 12px);box-sizing:border-box;background:linear-gradient(180deg,rgba(6,9,15,.96) 0%,rgba(2,6,23,.99) 100%);border-top:1px solid rgba(148,163,184,.18);position:relative;z-index:9}.directorMarkersCancelFooterIdle{pointer-events:none}.directorMarkersCancelButton{min-width:220px;height:56px;border-radius:14px;border:2px solid #fecaca;background:linear-gradient(180deg,#ef4444 0%,#991b1b 100%);color:#fff;font-weight:1000;font-size:20px;text-transform:uppercase;letter-spacing:.05em;box-shadow:0 0 0 1px rgba(255,255,255,.18),0 0 22px rgba(239,68,68,.38);pointer-events:auto;touch-action:manipulation}.directorMarkersCancelButton:active{transform:scale(.97)}.appPopupMarkersPanel{bottom:calc(env(safe-area-inset-bottom,0px) + 102px)!important;z-index:7000!important}.vshookNoTextSelect,.vshookNoTextSelect *,.hashChildItem,.hashParentItem,.rowLabelText,.songRowLabel,.regionRowLabel{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;}</style>${appPopupHtml}<div class="container ${showMarkerFooterSpace ? 'markerFooterContainer' : ''}" style="${borderStyle}"><div class="topStatusRow"><div class="${state.activeTab === 'playlist' ? 'topStatusLeftPlaylist' : 'topStatusLeft'}">${topTitleHtml}</div>${topTimerHtml}${rightToolsHtml}</div><div class="headerRow"><div class="tabRow"><button class="${state.activeTab === 'playlist' ? 'activeTab' : 'tab'}" data-action="go-playlist">REPERTÓRIOS</button><button class="${state.activeTab === 'regions' ? 'activeTab' : 'tab'}" data-action="go-regions">MÚSICAS</button><span class="headerTotal">${topTime}</span>${headerNavButtons}<span class="headerTotalSpacer"></span></div><div class="middleInfo"><span class="middleInfoText">${middleLabel}</span></div></div>${content}${showEditDoneFloating ? `<button class="floatingConfirmButton floatingConfirmRight" data-action="edit-done">OK</button>` : ''}${showDeleteConfirmFloating ? `<button class="floatingDangerButton floatingDangerLeft" data-action="delete-confirm">${state.activeTab === 'regions' ? 'SAIR' : 'DEL'}</button>` : ''}${showDeleteCancelFloating ? `<button class="floatingConfirmButton floatingConfirmRight" data-action="delete-cancel">SAIR</button>` : ''}${shouldShowClearButton ? `<button class="floatingClearButton" id="floatingClearButton" style="left:${state.clearButtonSide === 'left' ? '20px' : 'calc(100vw - 92px)'};">SAIR</button>` : ''}</div>${markerCancelGlobalButton}${lyricsPanelHtml}${createModal}${addExistingModal}${renameModal}${playlistSwitchModal}${deletePlaylistConfirmModal}${projectTabsModal}${recadosModal}${gearModal}${timerModal}${liveOffConfirmModal}${mixerModal}${mixerVolumeModal}${premixModal}${premixVolumeModal}${bpmModal}${tunerModal}</div>`
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
  bridgeTimer = setInterval(pollBridge, 150)
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
