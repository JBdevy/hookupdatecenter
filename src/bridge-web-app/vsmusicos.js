function getVSHookBridgeBaseUrl() {
  try {
    const raw = localStorage.getItem('vshook_musicians_url') || localStorage.getItem('vshook_director_url')
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


const APP_LOADING_MIN_MS = 1200
const POLL_INTERVAL_MS = 150
const POPUP_FADE_MS = 220
const BRIDGE_OFFLINE_GRACE_MS = 4500
let bridgePollInFlight = false
let bridgePollSeq = 0
let lastAppliedBridgePollSeq = 0
const playbackLiveState = { id: null, remaining: null }

function parseBridgeStateUpdatedMs(data) {
  if (!data || typeof data !== 'object') return 0
  const candidates = [data.heartbeatAt, data.lastHeartbeatAt, data.updatedAt, data.stateUpdatedAt, data.serverUpdatedAt]
  for (const value of candidates) {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    if (value != null && String(value).trim() !== '') {
      const parsed = Date.parse(String(value))
      if (Number.isFinite(parsed)) return parsed
    }
  }
  return 0
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
const APP_THEME_STORAGE_KEY = 'vs_hook_musicos_theme'
const APP_ENTERED_STORAGE_KEY = 'vs_hook_musicos_entered'

const state = {
  theme: 'dark',
  rgbMode: 'auto',
  rgbFixedIndex: 0,
  borderHue: 96,
  bridgeStatus: 'offline',
  lastBridgeUpdatedAtMs: 0,
  noticeEnabled: true,
  entered: false,
  activeTab: 'playlist',
  currentPage: 'playlist',
  currentPlaylistName: '',
  activePlaylistId: null,
  activePlaylistTotalSec: null,
  currentPlaylistTotalSec: null,
  playlistTotalSec: null,
  totalPlaylistSec: null,
  activePlaylistTotalText: '',
  currentPlaylistTotalText: '',
  playlistTotalText: '',
  totalPlaylistText: '',
  regionsTotalSec: null,
  totalRegionsSec: null,
  musicasTotalSec: null,
  totalMusicasSec: null,
  regionsTotalText: '',
  totalRegionsText: '',
  musicasTotalText: '',
  totalMusicasText: '',
  regions: [],
  playlists: [],
  markers: [],
  selectedRegionId: null,
  selectedRegionIds: [],
  selectedPlaylistSongId: null,
  selectedPlaylistSongIds: [],
  playingId: null,
  queuedSongId: null,
  bridgePopupVisible: false,
  bridgePopupText: '',
  bridgePopupError: false,
  bridgePopupPersistent: false,
  showGearModal: false,
  timerRunning: false,
  timerStartedAt: 0,
  timerStartedAtMs: 0,
  timerAccumulatedSec: 0,
  timerMode: 'progressive',
  timerTargetSec: 0,
  timerDisplaySec: 0,
  timerDisplayText: '',
  timerLocalTimeText: '',
  timerTriggerSeq: 0,
  playlistScrollRatio: null,
  regionsScrollRatio: null,
  playlistScrollOffsetRows: null,
  regionsScrollOffsetRows: null,
  playlistScrollTopPx: null,
  regionsScrollTopPx: null,
  remoteScrollVersion: '',
  projectTabs: [],
  activeProjectTabIndex: 0,
  showProjectTabsModal: false,
  selectedProjectTabIndex: null,
  lyricsPanelOpen: false,
  tp1LyricsText: '',
  tp1SongName: '',
  tp1MediaType: 'text',
  tp1UpdatedAt: null,
}

let borderTimer = null
let bridgeTimer = null
let appBootStartedAt = Date.now()
let appLoadingVisible = true
let lastRenderSignature = ''
let popupFadeTimer = null
const bridgePopupDisplay = { mounted: false, text: '', error: false, persistent: false, fading: false }
let wakeLockSentinel = null
let wakeLockEnabled = true
let noSleepVideoEl = null
let wakeLockRefreshTimer = 0
let lastAppliedRemoteScrollKey = ''
let lastRemoteScrollTouchAt = 0
let lastFocusedSelectionKey = ''
let playbackRenderTimer = null
let musicosUserScrollLockedUntil = 0
let musicosLocalSelectedTab = null
let musicosLocalSelectedSongId = null
let musicosLastAutoScrollPlayingId = null
let musicosLastPlayingIdForSelectionClear = null
let musicosUserSelectedTab = false
let musicosIgnoreScrollCaptureUntil = 0
let musicosSwipeStartX = null
let musicosSwipeStartY = null
let musicosSwipeStartAt = 0
const musicosManualScrollTopByTab = { playlist: 0, regions: 0 }

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

function musicosFirstTotalText(values) {
  for (const value of values) {
    const raw = String(value ?? '').trim()
    if (!raw) continue
    const clean = raw.replace(/^total\s*:\s*/i, '').trim()
    if (/^\d{1,3}:\d{2}(?::\d{2})?$/.test(clean)) return clean
  }
  return ''
}

function musicosFirstFiniteTotalNumber(values) {
  for (const value of values) {
    const number = Number(value)
    if (Number.isFinite(number) && number >= 0) return number
  }
  return null
}

function resolveMusicosPlaylistTotalText(playlist) {
  // Exibe exatamente o texto enviado pelo Lua/Bridge quando existir.
  // Isso evita diferença de arredondamento entre app e Lua.
  const fromStateText = musicosFirstTotalText([
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
  const fromStateNumber = musicosFirstFiniteTotalNumber([
    state?.activePlaylistTotalSec,
    state?.currentPlaylistTotalSec,
    state?.playlistTotalSec,
    state?.totalPlaylistSec,
    state?.repertorioTotalSec,
    state?.repertoryTotalSec,
    playlist?.activePlaylistTotalSec,
    playlist?.currentPlaylistTotalSec,
    playlist?.playlistTotalSec,
    playlist?.totalPlaylistSec,
    playlist?.repertorioTotalSec,
    playlist?.totalSec,
    playlist?.durationSec,
  ])
  if (fromStateNumber !== null) return formatTotalTime(fromStateNumber)
  return formatTotalTime(vshookSumRootDuration(playlist?.songs || []))
}

function resolveMusicosRegionsTotalText() {
  const fromStateText = musicosFirstTotalText([
    state?.regionsTotalText,
    state?.totalRegionsText,
    state?.musicasTotalText,
    state?.musicTotalText,
    state?.songsTotalText,
    state?.totalMusicasText,
  ])
  if (fromStateText) return fromStateText
  const fromStateNumber = musicosFirstFiniteTotalNumber([
    state?.regionsTotalSec,
    state?.totalRegionsSec,
    state?.musicasTotalSec,
    state?.musicTotalSec,
    state?.songsTotalSec,
    state?.totalMusicasSec,
  ])
  if (fromStateNumber !== null) return formatTotalTime(fromStateNumber)
  return formatTotalTime(vshookSumRootDuration(state.regions))
}

const TITLE_TICKER_CYCLE_MS = 9000

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
    return `<span class="titleTicker titleTickerStatic"><span class="titleTickerText musicosTitleText">${safeText}</span></span>`
  }
  return `<span class="titleTicker titleTickerAnimated"><span class="titleTickerTrack"${getTickerPhaseStyle(TITLE_TICKER_CYCLE_MS)}><span class="titleTickerSegment musicosTitleText">${safeText}</span><span class="titleTickerGap">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="titleTickerSegment musicosTitleText">${safeText}</span></span></span>`
}

function normalizeMusicosTimerMode(value) {
  const mode = String(value || '').trim().toLowerCase().replace(/[\s-]+/g, '_')
  if (mode === 'regressivo' || mode === 'regressive' || mode === 'countdown') return 'countdown'
  if (mode === 'local' || mode === 'local_time' || mode === 'horario_local' || mode === 'hora_local') return 'local_time'
  return 'progressive'
}

function getMusicosDeviceLocalTimeText() {
  const fromBridge = String(state.timerLocalTimeText || state.timerDisplayText || '').trim()
  if (fromBridge && /^\d{1,2}:\d{2}(?::\d{2})?$/.test(fromBridge)) return fromBridge
  const now = new Date()
  return `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`
}

function getChronoElapsedSeconds() {
  const max = 99 * 3600 + 59 * 60 + 59
  const mode = normalizeMusicosTimerMode(state.timerMode || 'progressive')
  const remoteDisplay = Number(state.timerDisplaySec)

  if (mode === 'countdown') {
    if (!state.timerRunning && Number.isFinite(remoteDisplay)) {
      return Math.max(0, Math.min(max, Math.floor(remoteDisplay)))
    }
    const target = Math.max(0, Math.min(max, Number(state.timerTargetSec) || 0))
    const base = Math.max(0, Number(state.timerAccumulatedSec) || 0)
    const startedAt = Number(state.timerStartedAt || state.timerStartedAtMs) || 0
    const live = state.timerRunning && startedAt > 0 ? Math.floor((Date.now() - startedAt) / 1000) : 0
    return Math.max(0, target - Math.max(0, base + live))
  }

  if (!state.timerRunning && Number.isFinite(remoteDisplay) && remoteDisplay > 0) {
    return Math.max(0, Math.min(max, Math.floor(remoteDisplay)))
  }
  const base = Math.max(0, Math.floor(Number(state.timerAccumulatedSec) || 0))
  if (!state.timerRunning) return Math.min(base, max)
  const startedAt = Number(state.timerStartedAt || state.timerStartedAtMs) || 0
  if (!startedAt) return Math.min(base, max)
  return Math.max(0, Math.min(max, base + Math.floor((Date.now() - startedAt) / 1000)))
}

function getMusicosChronoDisplayText() {
  return normalizeMusicosTimerMode(state.timerMode || 'progressive') === 'local_time'
    ? getMusicosDeviceLocalTimeText()
    : formatChronoTime(getChronoElapsedSeconds())
}

function formatChronoTime(totalSeconds) {
  const safe = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function ensureNoSleepVideo() {
  if (noSleepVideoEl) return noSleepVideoEl
  const video = document.createElement('video')
  video.setAttribute('playsinline', '')
  video.setAttribute('webkit-playsinline', '')
  video.setAttribute('muted', '')
  video.muted = true
  video.defaultMuted = true
  video.loop = true
  video.autoplay = true
  video.preload = 'auto'
  video.playsInline = true
  video.disablePictureInPicture = true
  video.style.position = 'fixed'
  video.style.width = '1px'
  video.style.height = '1px'
  video.style.opacity = '0.01'
  video.style.pointerEvents = 'none'
  video.style.right = '0'
  video.style.bottom = '0'
  video.style.left = 'auto'
  video.style.top = 'auto'
  video.style.zIndex = '1'
  video.style.transform = 'translateZ(0)'
  const source = document.createElement('source')
  source.src = 'data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAGbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAkx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAABAAAAAQAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAAG7bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAAMgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABbm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAATZzdGJsAAAAsnN0c2QAAAAAAAAAAQAAAKJhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAABAAEASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAN/+EAGGdkAA2s2UEA8A8AAAMAAgAAAwB4HixckAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAAxAAAAHHN0dHMAAAAAAAAAAQAAAAEAAAAUAAAAFHN0c2MAAAAAAAAAAQAAAAEAAAABAAAAAQAAAAxzdHN6AAAAAAAAABQAAAABAAAAFHN0Y28AAAAAAAAAAQAAALg='
  video.appendChild(source)
  document.body.appendChild(video)
  noSleepVideoEl = video
  return video
}

function kickNoSleepVideo() {
  try {
    const video = ensureNoSleepVideo()
    if (!video) return
    if (Number.isFinite(video.currentTime) && video.currentTime > 0.45) video.currentTime = 0.01
    video.muted = true
    video.defaultMuted = true
    video.loop = true
    video.playsInline = true
    video.setAttribute('muted', '')
    video.setAttribute('playsinline', '')
    video.setAttribute('webkit-playsinline', '')
    const playPromise = video.play?.()
    if (navigator.mediaSession) navigator.mediaSession.playbackState = 'playing'
    if (playPromise && typeof playPromise.then === 'function') playPromise.catch(() => {})
  } catch (error) {
  }
}

async function requestScreenWakeLock() {
  if (!wakeLockEnabled) return
  if (document.visibilityState !== 'visible') return
  if ('wakeLock' in navigator && typeof navigator.wakeLock?.request === 'function') {
    try {
      if (!wakeLockSentinel) {
        wakeLockSentinel = await navigator.wakeLock.request('screen')
        wakeLockSentinel?.addEventListener?.('release', () => {
          wakeLockSentinel = null
        })
      }
      return
    } catch (error) {
      wakeLockSentinel = null
    }
  }
  try {
    kickNoSleepVideo()
  } catch (error) {
  }
}

async function releaseScreenWakeLock() {
  try {
    await wakeLockSentinel?.release?.()
  } catch (error) {
  } finally {
    wakeLockSentinel = null
  }
  try {
    noSleepVideoEl?.pause?.()
  } catch (error) {
  }
}

function setupScreenWakeLock() {
  const rearmWakeLock = () => {
    requestScreenWakeLock()
    kickNoSleepVideo()
  }
  rearmWakeLock()
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') rearmWakeLock()
    else releaseScreenWakeLock()
  })
  window.addEventListener('focus', rearmWakeLock)
  window.addEventListener('pageshow', rearmWakeLock)
  window.addEventListener('resume', rearmWakeLock)
  window.addEventListener('orientationchange', rearmWakeLock)
  document.addEventListener('click', rearmWakeLock, { passive: true })
  document.addEventListener('touchstart', rearmWakeLock, { passive: true })
  document.addEventListener('touchend', rearmWakeLock, { passive: true })
  document.addEventListener('touchmove', rearmWakeLock, { passive: true })
  document.addEventListener('pointerdown', rearmWakeLock, { passive: true })
  document.addEventListener('keydown', rearmWakeLock, { passive: true })
  if (wakeLockRefreshTimer) clearInterval(wakeLockRefreshTimer)
  wakeLockRefreshTimer = setInterval(() => {
    if (document.visibilityState !== 'visible') return
    requestScreenWakeLock()
    kickNoSleepVideo()
  }, 900)
}

function buildMarqueeText(text, textClass = '', extraClass = '') {
  const normalized = upperText(text ?? '')
  const source = encodeURIComponent(normalized)
  const safeText = escapeHtml(normalized)
  const safeTextClass = escapeHtml(textClass || '')
  const safeExtraClass = escapeHtml(extraClass || '')
  const shouldForceMarquee = (safeExtraClass.includes('musicosTitleMarquee') || safeExtraClass.includes('playlistTitleMarquee') || safeExtraClass.includes('playlistOptionMarquee')) && normalized.length >= 16
  return `<span class="marqueeViewport ${safeExtraClass}" data-marquee data-marquee-source="${source}" data-marquee-text-class="${safeTextClass}" data-marquee-force="${shouldForceMarquee ? '1' : '0'}"><span class="marqueeStatic ${safeTextClass}">${safeText}</span></span>`
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
    const needs = force || textWidth > viewportWidth + 6

    if (needs) {
      viewport.classList.add('is-marquee')
      viewport.innerHTML = `<span class="marqueeMeasure ${classAttr}">${safeText}</span><span class="marqueeTrack ${classAttr}"><span class="marqueeSegment">${safeText}</span><span class="marqueeSpacer">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="marqueeSegment">${safeText}</span></span>`
    } else {
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


function getCurrentSelectionFocusId() {
  // No app dos musicos, a lista so deve ser puxada automaticamente
  // quando existe musica tocando. Parado, o usuario pode rolar livremente
  // e selecionar qualquer musica apenas para consultar a letra.
  return state.playingId != null ? String(state.playingId) : ''
}

function buildSelectionFocusKey() {
  return `${String(state.activeTab || '')}|${getCurrentSelectionFocusId()}`
}

function syncSelectedItemIntoView(force = false) {
  // App dos musicos com navegacao livre:
  // nao puxa mais a lista para a musica tocando nem para selecao recebida do Lua.
  musicosLastAutoScrollPlayingId = state.playingId ? String(state.playingId) : null
  return
}

function syncRemoteListScroll(force = false) {
  return
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
  return /^[=:\-]+\s*BLOCO\s+.+\s*[=:\-]+$/i.test(text) || /^BLOCO\s+.+/i.test(text)
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
  return normalizeLyricsText(item?.lyricsText ?? item?.lyrics ?? '')
}

function findMusicosSongById(id) {
  const key = String(id || '')
  if (!key) return null

  const region = Array.isArray(state.regions) ? state.regions.find((item) => String(item?.id ?? item?.songId ?? '') === key) : null
  if (region && !detectBlockItem(region)) return region

  for (const playlist of Array.isArray(state.playlists) ? state.playlists : []) {
    const found = Array.isArray(playlist?.songs) ? playlist.songs.find((item) => String(item?.id ?? item?.songId ?? '') === key) : null
    if (found && !detectBlockItem(found)) return found
  }

  return null
}

function isMusicosLocalSelectionValid() {
  if (!musicosLocalSelectedSongId) return false
  return !!findMusicosSongById(musicosLocalSelectedSongId)
}

function getMusicosLocalSelectedSong() {
  if (!isMusicosLocalSelectionValid()) return null
  return findMusicosSongById(musicosLocalSelectedSongId)
}

function setMusicosLocalSelection(tab, itemId) {
  // App dos Músicos agora é somente monitor: clique não cria seleção.
  return false
}

function getMusicosCurrentLyricsSong() {
  // App dos Músicos agora é monitor do TP1: só mostra nome/letra vindos do Teleprompt 1.
  // Não usa mais letra armazenada por música e não usa imagem/vídeo.
  const mediaType = String(state.tp1MediaType || 'text').toLowerCase()
  const allowText = !mediaType || mediaType === 'text' || mediaType === 'lyrics' || mediaType === 'empty' || mediaType === 'empty_item' || mediaType === 'emptyitem' || mediaType === 'text/plain'
  const title = String(state.tp1SongName || '').trim()
  const text = allowText ? String(state.tp1LyricsText || '').trim() : ''
  if (!title && !text) return null
  return { name: title || 'TELEPROMPT 1', lyricsText: text }
}

function getMusicosLyricsProgressRatio(song) {
  if (state.playingId) {
    const playing = findMusicosSongById(state.playingId)
    if (playing && !detectBlockItem(playing)) {
      const playbackItem = getPlaybackAwareItem(playing, true, false)
      return getRowProgressRatio(playbackItem, true, false)
    }
  }
  return 0
}

function openMusicosLyricsPanel() {
  if (state.lyricsPanelOpen) {
    syncMusicosLyricsPanelDom()
    return
  }
  state.lyricsPanelOpen = true
  render()
}

function closeMusicosLyricsPanel() {
  state.lyricsPanelOpen = false
  render()
}

function renderMusicosLyricsPanel() {
  if (!state.lyricsPanelOpen) return ''
  const song = getMusicosCurrentLyricsSong()
  const title = song ? upperText(song.name || 'TELEPROMPT 1') : 'TELEPROMPT 1'
  const lyricsText = song ? String(song.lyricsText || '') : ''
  const textToShow = lyricsText || 'SEM CONTEÚDO NO TP1'
  const progress = Math.round(getMusicosLyricsProgressRatio(song) * 1000) / 10
  return `<div class="lyricsScreen telepromptOnlyScreen">
    <div class="lyricsTopBar">
      <div class="lyricsNowPlaying">
        <div class="lyricsNowPlayingTitle" data-lyrics-title>${escapeHtml(title)}</div>
        <div class="lyricsProgressTrack"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${progress}%"></div></div>
      </div>
      <button class="lyricsBackButton lyricsBlueButton" data-action="close-lyrics-panel">&gt;&gt;</button>
    </div>
    <div class="lyricsBody">
      <div class="lyricsTextView" data-lyrics-text-view data-lyrics-source="${escapeHtml(textToShow)}">${lyricsTextToHtml(textToShow)}</div>
    </div>
  </div>`
}

function syncMusicosLyricsPanelDom() {
  if (!state.lyricsPanelOpen) return
  const song = getMusicosCurrentLyricsSong()

  const fill = document.querySelector('[data-lyrics-progress-fill]')
  if (fill) fill.style.width = `${Math.round(getMusicosLyricsProgressRatio(song) * 1000) / 10}%`

  const titleNode = document.querySelector('[data-lyrics-title]')
  const title = song ? upperText(song.name || 'TELEPROMPT 1') : 'TELEPROMPT 1'
  if (titleNode && titleNode.textContent !== title) {
    titleNode.textContent = title
  }

  const textNode = document.querySelector('[data-lyrics-text-view]')
  if (textNode) {
    const nextSource = song && String(song.lyricsText || '').trim() ? String(song.lyricsText || '') : 'SEM CONTEÚDO NO TP1'
    if (textNode.getAttribute('data-lyrics-source') !== nextSource) {
      textNode.setAttribute('data-lyrics-source', nextSource)
      textNode.innerHTML = lyricsTextToHtml(nextSource)
    }
  }
}

function getCurrentPlaylist() {
  const playlists = Array.isArray(state.playlists) ? state.playlists : []
  if (!playlists.length) return null
  const activeId = String(state.activePlaylistId || '')
  const byId = playlists.find((item) => String(item?.id || '') === activeId)
  if (byId) return byId
  const byName = playlists.find((item) => String(item?.name || '') === String(state.currentPlaylistName || ''))
  if (byName) return byName
  return playlists[0]
}

function getDisplayItems() {
  if (state.activeTab === 'regions') return vshookRootFamilyItems(state.regions)
  const playlist = getCurrentPlaylist()
  return Array.isArray(playlist?.songs) ? playlist.songs : []
}

function getNextAutoQueuedSongId() {
  if (!state.autoplayEnabled || !state.playingId) return null
  const playingKey = String(state.playingId || '')
  const lists = []
  const playlist = getCurrentPlaylist()
  if (Array.isArray(playlist?.songs) && playlist.songs.length) lists.push(playlist.songs)
  if (Array.isArray(state.regions) && state.regions.length) lists.push(state.regions)

  for (const list of lists) {
    const idx = list.findIndex((item) => String(item?.id ?? item?.songId ?? '') === playingKey)
    if (idx < 0) continue
    for (let i = idx + 1; i < list.length; i += 1) {
      const item = list[i]
      if (!item || detectBlockItem(item) || isHashChildItem(item)) continue
      const id = String(item.id ?? item.songId ?? '')
      if (id && id !== playingKey) return id
    }
  }
  return null
}

function getVisualQueuedSongId() {
  const isQueuedIdAllowed = (id) => {
    const key = String(id ?? '')
    if (!key) return false
    const song = findMusicosSongById ? findMusicosSongById(key) : null
    return !(song && isHashChildItem(song))
  }
  if (state.queuedSongId && isQueuedIdAllowed(state.queuedSongId)) return String(state.queuedSongId)
  const autoQueuedId = getNextAutoQueuedSongId()
  return autoQueuedId && isQueuedIdAllowed(autoQueuedId) ? String(autoQueuedId) : null
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

function getPlaybackAwareItem(item, isPlaying, isBlock) {
  if (!item || !isPlaying || isBlock) return item
  const duration = Number(item?.durationSec) || 0
  const remaining = Number(item?.remainingSec)
  const region = (state.regions || []).find((entry) => String(entry?.id || '') === String(item?.id || ''))
  const sourceDuration = Number(region?.durationSec) || duration || 0
  const regionRemaining = Number(region?.remainingSec)
  const sourceRemaining = Number.isFinite(remaining)
    ? remaining
    : (Number.isFinite(regionRemaining) ? regionRemaining : (sourceDuration > 0 ? sourceDuration : remaining))
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

function getRowNumberText(items, index) {
  const item = items[index]
  if (detectBlockItem(item)) return '--'
  let count = 0
  for (let i = 0; i <= index; i += 1) {
    if (!detectBlockItem(items[i])) count += 1
  }
  return String(count).padStart(2, '0')
}

function renderRows(items, type) {
  if (!items.length) return '<div class="emptyBox musicosEmptyPad">SEM ITENS</div>'
  const visualQueuedSongId = getVisualQueuedSongId()
  return items.map((item, index) => {
    const itemId = String(item?.id ?? '')
    const isBlock = detectBlockItem(item)
    const blockOutlineStyle = isBlock ? ` style="--block-outline-color:${escapeHtml(getBlockOutlineColorCss(item))};--block-outline-glow:${escapeHtml(getBlockOutlineGlowCss(item))};"` : ''
    const isHashChild = isHashChildItem(item)
    const isHashParent = isHashParentItem(item)
    const inheritedItemTextColor = getAppItemTextColor(item, isBlock)
    const itemTextColor = (type === 'region' || type === 'regions')
      ? '#ffffff'
      : (inheritedItemTextColor && String(inheritedItemTextColor).trim() !== '' ? inheritedItemTextColor : '#ffffff')
    const isPlaying = !isBlock && String(state.playingId || '') === itemId
    const isQueued = !isBlock && !isHashChild && String(visualQueuedSongId || '') === itemId
    const isLiveExecuted = !isPlaying && !isQueued && !isBlock && !!(item?.isLiveExecuted || item?.liveExecuted || item?.alreadyPlayed || item?.played || item?.executed)
    const isSelected = false

    const classes = ['item', 'numberedItem']
    if (isQueued) classes.push('queuedYellow')
    else if (isSelected) classes.push('selectedPink')
    if (isPlaying) classes.push('playing')
    if (isLiveExecuted) classes.push('liveExecuted')
    if (isBlock) classes.push('blockItem')
    if (isHashChild) classes.push('hashChildItem')
    if (isHashParent) classes.push('hashParentItem')

    const playbackItem = getPlaybackAwareItem(item, isPlaying, isBlock)
    const progressRatio = getRowProgressRatio(playbackItem, isPlaying, isBlock)
    const label = isBlock ? formatAppBlockLabel(item) : formatHashFamilyLabel(item, item?.name || item?.label || '---')
    const textClass = isPlaying
      ? 'playingText'
      : isQueued
      ? 'queuedYellowText'
      : isSelected
      ? 'selectedPinkText'
      : isLiveExecuted
      ? 'liveExecutedText'
      : isBlock
      ? 'blockText'
      : 'text'

    const timeClass = isPlaying
      ? 'playingTimeText'
      : isQueued
      ? 'queuedYellowTimeText'
      : isSelected
      ? 'selectedPinkTimeText'
      : isLiveExecuted
      ? 'liveExecutedTimeText'
      : isBlock
      ? 'blockTimeText'
      : 'timeText'

    const time = isBlock ? '' : formatTime(isPlaying ? (playbackItem?.remainingSec ?? playbackItem?.durationSec) : playbackItem?.durationSec)
    const safeProgressRatio = Math.max(0, Math.min(1, Number(progressRatio) || 0))
    const visualProgressRatio = isPlaying ? Math.max(0.002, safeProgressRatio) : safeProgressRatio
    const progressWidthCss = `calc(${(visualProgressRatio * 100).toFixed(3)}% - ${(42 * visualProgressRatio).toFixed(3)}px)`
    const progressBarHtml = isPlaying
      ? `<div class="progressBar progressBarWithNumber" data-row-progress-bar="1" style="left:42px;width:${progressWidthCss};min-width:10px;"></div>`
      : ''
    const playingAttr = isPlaying ? ' data-playing-row="1"' : ''
    const numberCol = `<div class="numberCol ${getRowNumberText(items, index) === '--' ? 'numberColEmpty' : ''}"><span>${escapeHtml(getRowNumberText(items, index))}</span></div>`
    const rightColHtml = time
      ? `<div class="rightCol"><span class="${timeClass}">${escapeHtml(time)}</span></div>`
      : `<div class="rightCol rightColEmpty"></div>`

    const labelStyle = itemTextColor && !isPlaying && !isQueued && !isSelected ? ` style="color:${escapeHtml(itemTextColor)}"` : ''
    return `<div class="${classes.join(' ')}" data-item-id="${escapeHtml(itemId)}" data-item-type="${escapeHtml(type)}"${playingAttr}${blockOutlineStyle}>${progressBarHtml}${numberCol}<div class="leftCol"><span class="rowLabelText ${textClass}"${labelStyle}>${escapeHtml(label)}</span></div>${rightColHtml}</div>`
  }).join('')
}

async function pollBridge() {
  if (bridgePollInFlight) return
  bridgePollInFlight = true
  const requestSeq = ++bridgePollSeq
  const previousSignature = buildBridgeRenderSignature()
  let bridgeOk = false

  try {
    const response = await fetch(vshookBridgeUrl('/state'), { cache: 'no-store' })
    if (!response.ok) throw new Error('offline')
    const data = await response.json()
    if (requestSeq >= lastAppliedBridgePollSeq) {
      lastAppliedBridgePollSeq = requestSeq
      syncFromBridge(data)
      bridgeOk = true
    }
  } catch (e) {
    if (bridgeLooksOffline()) {
      state.bridgeStatus = 'offline'
      state.appActive = false
    }
  } finally {
    bridgePollInFlight = false
  }

  if (bridgeLooksOffline()) {
    state.bridgeStatus = 'offline'
    state.appActive = false
    state.authAuthenticated = false
    state.authShowPassword = false
  }

  const nextSignature = buildBridgeRenderSignature()
  const shouldRenderNow = !shouldPauseBridgeRender() && (nextSignature !== lastBridgeRenderSignature || nextSignature !== previousSignature)
  if (shouldRenderNow) {
    const now = Date.now()
    if ((now - lastBridgeUiRenderAt) >= 90 || bridgeOk) {
      lastBridgeUiRenderAt = now
      render()
    }
  } else if (state.lyricsPanelOpen) {
    syncMusicosLyricsPanelDom()
  }
}

function ensureBootLoader() {
  let loader = document.getElementById('appBootLoader')
  if (loader) return loader
  loader = document.createElement('div')
  loader.id = 'appBootLoader'
  loader.className = 'appBootLoader'
  loader.innerHTML = `
    <div class="appBootLoaderInner">
      <img class="appBootLoaderIcon" alt="VS Hook Musicos" src="./vsmusicos-icon-512.png" />
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

function postCommand(type, payload = {}) {
  return fetch(vshookBridgeUrl('/command'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type, payload }),
  }).catch(() => {})
}

function openGearModal() {
  state.showGearModal = true
  render()
}

function closeGearModal() {
  state.showGearModal = false
  render()
}

function normalizeRgbMode() {
  const mode = String(state.rgbMode || '').toLowerCase()
  const fixedIndex = Math.max(0, Math.min(RGB_FIXED_HUES.length - 1, Number(state.rgbFixedIndex) || 0))

  if (mode === 'fixed') {
    state.rgbMode = 'fixed'
    state.rgbFixedIndex = fixedIndex
    state.borderHue = RGB_FIXED_HUES[fixedIndex] ?? 96
    return RGB_MODE_SEQUENCE.find((item) => item.mode === 'fixed' && item.fixedIndex === fixedIndex) || RGB_MODE_SEQUENCE[0]
  }

  if (mode === 'off') {
    state.rgbMode = 'off'
    state.rgbFixedIndex = 0
    state.borderHue = 0
    return RGB_MODE_SEQUENCE.find((item) => item.mode === 'off') || RGB_MODE_SEQUENCE[10]
  }

  state.rgbMode = 'auto'
  state.rgbFixedIndex = 0
  return RGB_MODE_SEQUENCE.find((item) => item.mode === 'auto') || RGB_MODE_SEQUENCE[9]
}

function getRgbModeIndex() {
  const current = normalizeRgbMode()
  const index = RGB_MODE_SEQUENCE.findIndex((item) => item.mode === current.mode && item.fixedIndex === current.fixedIndex)
  return index >= 0 ? index : 9
}

function getRgbModeLabel() {
  return normalizeRgbMode().label
}

function getBorderColorCss() {
  normalizeRgbMode()
  if (state.rgbMode === 'fixed' && Number(state.rgbFixedIndex) === 8) return '#f8fafc'
  return `hsl(${state.borderHue}, 100%, 55%)`
}

function getBorderGlowCss() {
  normalizeRgbMode()
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

function applyRgbMode(next) {
  if (!next) return
  state.rgbMode = next.mode
  state.rgbFixedIndex = Number(next.fixedIndex) || 0
  normalizeRgbMode()
  updateBorderEffect()
}

function cycleRgbMode() {
  const currentIndex = getRgbModeIndex()
  const next = RGB_MODE_SEQUENCE[(currentIndex + 1) % RGB_MODE_SEQUENCE.length] || RGB_MODE_SEQUENCE[9]
  applyRgbMode(next)
  lastRenderSignature = ''
  render()
}

function loadThemePreference() {
  try {
    const saved = localStorage.getItem(APP_THEME_STORAGE_KEY)
    if (saved === 'light' || saved === 'dark') state.theme = saved
    const entered = localStorage.getItem(APP_ENTERED_STORAGE_KEY)
    state.entered = entered === '1'
  } catch (error) {}
}

function saveThemePreference() {
  try {
    localStorage.setItem(APP_THEME_STORAGE_KEY, state.theme)
  } catch (error) {}
}

function setEntered(value) {
  state.entered = !!value
  try {
    localStorage.setItem(APP_ENTERED_STORAGE_KEY, state.entered ? '1' : '0')
  } catch (error) {}
}

function setTheme(themeName) {
  state.theme = themeName === 'light' ? 'light' : 'dark'
  saveThemePreference()
  render()
}

function handleEnterApp(event) {
  event?.preventDefault?.()
  event?.stopPropagation?.()
  if (bridgeLooksOffline()) return
  setEntered(true)
  requestScreenWakeLock()
  kickNoSleepVideo()
  render()
}

function ensureNoticeAlwaysEnabled() {
  state.noticeEnabled = true
}


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

function updateBridgeState(data) {
  state.bridgeStatus = data && data.connected ? 'online' : 'offline'
  state.lastBridgeUpdatedAtMs = parseBridgeStateUpdatedMs(data) || 0
  ensureNoticeAlwaysEnabled()
  state.currentPage = String(data.currentPage || state.currentPage || 'playlist')
  state.currentPlaylistName = String(data.currentPlaylistName || data.activePlaylistName || state.currentPlaylistName || '')
  state.autoBlocoEnabled = !!data.autoBlocoEnabled
  state.autoplayEnabled = typeof data.autoplayEnabled === 'boolean' ? data.autoplayEnabled : !!data.autoplayEnabled
  state.activePlaylistId = data.activePlaylistId != null ? String(data.activePlaylistId) : state.activePlaylistId
  state.activePlaylistTotalSec = musicosFirstFiniteTotalNumber([data.activePlaylistTotalSec, data.currentPlaylistTotalSec, data.playlistTotalSec, data.totalPlaylistSec, data.repertorioTotalSec, data.repertoryTotalSec]) ?? state.activePlaylistTotalSec
  state.currentPlaylistTotalSec = state.activePlaylistTotalSec
  state.playlistTotalSec = state.activePlaylistTotalSec
  state.totalPlaylistSec = state.activePlaylistTotalSec
  state.activePlaylistTotalText = musicosFirstTotalText([data.activePlaylistTotalText, data.currentPlaylistTotalText, data.playlistTotalText, data.totalPlaylistText, data.repertorioTotalText, data.repertoryTotalText]) || state.activePlaylistTotalText || ''
  state.currentPlaylistTotalText = state.activePlaylistTotalText
  state.playlistTotalText = state.activePlaylistTotalText
  state.totalPlaylistText = state.activePlaylistTotalText
  state.regionsTotalSec = musicosFirstFiniteTotalNumber([data.regionsTotalSec, data.totalRegionsSec, data.musicasTotalSec, data.musicTotalSec, data.songsTotalSec, data.totalMusicasSec]) ?? state.regionsTotalSec
  state.totalRegionsSec = state.regionsTotalSec
  state.musicasTotalSec = state.regionsTotalSec
  state.totalMusicasSec = state.regionsTotalSec
  state.regionsTotalText = musicosFirstTotalText([data.regionsTotalText, data.totalRegionsText, data.musicasTotalText, data.musicTotalText, data.songsTotalText, data.totalMusicasText]) || state.regionsTotalText || ''
  state.totalRegionsText = state.regionsTotalText
  state.musicasTotalText = state.regionsTotalText
  state.totalMusicasText = state.regionsTotalText
  state.regions = Array.isArray(data.regions) ? data.regions : []
  state.playlists = normalizeBridgePlaylistsWithHashChildren(Array.isArray(data.playlists) ? data.playlists : [])
  state.projectTabs = Array.isArray(data.projectTabs) ? data.projectTabs : (Array.isArray(data.projects) ? data.projects : state.projectTabs)
  state.activeProjectTabIndex = Number.isFinite(Number(data.activeProjectTabIndex)) ? Number(data.activeProjectTabIndex) : state.activeProjectTabIndex
  if (state.selectedProjectTabIndex === null) state.selectedProjectTabIndex = state.activeProjectTabIndex
  state.markers = Array.isArray(data.markers) ? data.markers : []
  // No app dos musicos, a selecao feita no Lua/diretor nao deve destacar nem focar itens.
  state.selectedRegionId = null
  state.selectedRegionIds = []
  state.selectedPlaylistSongId = null
  state.selectedPlaylistSongIds = []
  const nextPlayingId = data.playingId != null ? String(data.playingId) : null
  if (nextPlayingId && nextPlayingId !== musicosLastPlayingIdForSelectionClear) {
    musicosLocalSelectedTab = null
    musicosLocalSelectedSongId = null
  }
  state.playingId = nextPlayingId
  musicosLastPlayingIdForSelectionClear = nextPlayingId
  if (musicosLocalSelectedSongId && !isMusicosLocalSelectionValid()) {
    musicosLocalSelectedTab = null
    musicosLocalSelectedSongId = null
  }
  resetPlaybackLiveState()
  state.queuedSongId = data.queuedSongId != null ? String(data.queuedSongId) : (data.queuedPlaylistSongId != null ? String(data.queuedPlaylistSongId) : null)
  state.timerRunning = !!data.timerRunning
  state.timerStartedAt = Number(data.timerStartedAt || data.timerStartedAtMs) || 0
  state.timerStartedAtMs = state.timerStartedAt
  state.timerAccumulatedSec = Number(data.timerAccumulatedSec) || 0
  state.timerMode = normalizeMusicosTimerMode(data.timerMode || data.timerType || state.timerMode || 'progressive')
  const nextTarget = Number(data.timerTargetSec ?? data.timerCountdownStartSec)
  if (Number.isFinite(nextTarget)) state.timerTargetSec = Math.max(0, nextTarget)
  const nextDisplay = Number(data.timerDisplaySec)
  if (Number.isFinite(nextDisplay)) state.timerDisplaySec = Math.max(0, nextDisplay)
  else if (state.timerMode === 'countdown' && !state.timerRunning) state.timerDisplaySec = Math.max(0, Number(state.timerTargetSec) || 0)
  state.timerDisplayText = String(data.timerDisplayText || '')
  state.timerLocalTimeText = String(data.timerLocalTimeText || '')
  state.timerTriggerSeq = Number(data.timerTriggerSeq || state.timerTriggerSeq || 0) || 0
  state.tp1MediaType = String(data.tp1MediaType || data.telepromptTp1MediaType || 'text').toLowerCase()
  const tp1AllowsText = !state.tp1MediaType || state.tp1MediaType === 'text' || state.tp1MediaType === 'lyrics' || state.tp1MediaType === 'empty' || state.tp1MediaType === 'empty_item' || state.tp1MediaType === 'emptyitem' || state.tp1MediaType === 'text/plain'
  state.tp1LyricsText = tp1AllowsText ? String(data.tp1LyricsText || data.tp1Lyrics || data.telepromptTp1Lyrics || '') : ''
  state.tp1SongName = String(data.tp1SongName || data.telepromptTp1SongName || data.tp1Song || '')
  state.tp1UpdatedAt = data.tp1UpdatedAt || null
  const scrollInfo = (data && typeof data.scroll === 'object' && data.scroll) ? data.scroll : null
  state.playlistScrollRatio = Number.isFinite(Number(scrollInfo?.playlist ?? data.playlistScrollRatio)) ? Number(scrollInfo?.playlist ?? data.playlistScrollRatio) : null
  state.regionsScrollRatio = Number.isFinite(Number(scrollInfo?.regions ?? data.regionsScrollRatio)) ? Number(scrollInfo?.regions ?? data.regionsScrollRatio) : null
  state.playlistScrollOffsetRows = Number.isFinite(Number(data.playlistScrollOffsetRows)) ? Number(data.playlistScrollOffsetRows) : null
  state.regionsScrollOffsetRows = Number.isFinite(Number(data.regionsScrollOffsetRows)) ? Number(data.regionsScrollOffsetRows) : null
  state.playlistScrollTopPx = Number.isFinite(Number(data.playlistScrollTopPx)) ? Number(data.playlistScrollTopPx) : null
  state.regionsScrollTopPx = Number.isFinite(Number(data.regionsScrollTopPx)) ? Number(data.regionsScrollTopPx) : null
  state.remoteScrollVersion = String(data.scrollSyncVersion || [
    state.playlistScrollRatio ?? 'x',
    state.regionsScrollRatio ?? 'x',
    state.playlistScrollOffsetRows ?? 'x',
    state.regionsScrollOffsetRows ?? 'x',
    state.playlistScrollTopPx ?? 'x',
    state.regionsScrollTopPx ?? 'x',
    String(state.currentPage || '')
  ].join('|'))
const bridgePage = String(data.currentPage || data.page || '').toLowerCase()
  const nextRemoteTab = (bridgePage === 'regions' || bridgePage === 'musicas' || bridgePage === 'músicas') ? 'regions' : 'playlist'
  if (state.activeTab !== nextRemoteTab) {
    musicosLocalSelectedTab = null
    musicosLocalSelectedSongId = null
    musicosLastAutoScrollPlayingId = null
    musicosUserScrollLockedUntil = 0
  }
  state.activeTab = nextRemoteTab

  state.bridgePopupVisible = !!data.popupVisible
  state.bridgePopupText = String(data.popupText || '')
  state.bridgePopupError = !!data.popupError
  state.bridgePopupPersistent = !!data.popupPersistent

  if (state.bridgePopupVisible && state.bridgePopupText) {
    if (popupFadeTimer) {
      clearTimeout(popupFadeTimer)
      popupFadeTimer = null
    }
    bridgePopupDisplay.mounted = true
    bridgePopupDisplay.text = state.bridgePopupText
    bridgePopupDisplay.error = state.bridgePopupError
    bridgePopupDisplay.persistent = state.bridgePopupPersistent
    bridgePopupDisplay.fading = false
  } else if (bridgePopupDisplay.mounted && !bridgePopupDisplay.fading) {
    bridgePopupDisplay.fading = true
    popupFadeTimer = window.setTimeout(() => {
      bridgePopupDisplay.mounted = false
      bridgePopupDisplay.text = ''
      bridgePopupDisplay.error = false
      bridgePopupDisplay.persistent = false
      bridgePopupDisplay.fading = false
      popupFadeTimer = null
      render()
    }, POPUP_FADE_MS)
  }
}

async function pollBridge() {
  if (bridgePollInFlight) return
  bridgePollInFlight = true
  const requestSeq = ++bridgePollSeq
  const previousSignature = buildRenderSignature()
  let bridgeOk = false
  try {
    const response = await fetch(vshookBridgeUrl('/state'), { cache: 'no-store' })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()
    if (requestSeq >= lastAppliedBridgePollSeq) {
      lastAppliedBridgePollSeq = requestSeq
      updateBridgeState(data)
      bridgeOk = true
      if (appLoadingVisible) hideBootLoader()
    }
  } catch (error) {
    if (bridgeLooksOffline()) {
      state.bridgeStatus = 'offline'
    }
  } finally {
    bridgePollInFlight = false
  }

  if (state.lyricsPanelOpen) {
    syncBridgePopupDom()
    syncMusicosLyricsPanelDom()
    return
  }

  const nextSignature = buildRenderSignature()
  const shouldRenderNow = appLoadingVisible || nextSignature !== lastRenderSignature || nextSignature !== previousSignature
  if (shouldRenderNow) {
    render()
    syncPlaybackDom()
    updateBorderEffect()
  } else {
    syncChronoDom()
    syncPlaybackDom()
  }
}

function shouldPauseBridgeRender() {
  return !!state.lyricsPanelOpen
}

function buildRenderSignature() {
  const playlist = getCurrentPlaylist()
  const items = getDisplayItems()
  return JSON.stringify({
    theme: state.theme,
    rgbMode: state.rgbMode,
    rgbFixedIndex: state.rgbFixedIndex,
    bridgeStatus: state.bridgeStatus,
    lyricsPanelOpen: state.lyricsPanelOpen,
    tp1LyricsText: state.tp1LyricsText,
    tp1SongName: state.tp1SongName,
    tp1UpdatedAt: state.tp1UpdatedAt,
    activeTab: state.activeTab,
    musicosLocalSelectedTab,
    musicosLocalSelectedSongId,
    currentPlaylistName: state.currentPlaylistName,
    activePlaylistId: state.activePlaylistId,
    activePlaylistTotalText: state.activePlaylistTotalText,
    activePlaylistTotalSec: state.activePlaylistTotalSec,
    regionsTotalText: state.regionsTotalText,
    regionsTotalSec: state.regionsTotalSec,
    // No app dos musicos, com tudo parado a selecao remota do REAPER nao deve
    // recriar a lista nem puxar o scroll. A selecao local serve para consultar letras.
    selectedRegionId: null,
    selectedRegionIds: [],
    selectedPlaylistSongId: null,
    selectedPlaylistSongIds: [],
    // No app dos musicos, tocar/parar pelo Lua nao deve recriar a tela nem mover a lista.
    // A barra superior e o destaque da musica tocando sao atualizados via syncPlaybackDom().
    playingId: null,
    queuedSongId: state.queuedSongId,
    autoBlocoEnabled: state.autoBlocoEnabled,
    popup: bridgePopupDisplay,
    noticeEnabled: state.noticeEnabled,
    entered: state.entered,
    showGearModal: state.showGearModal,
    timerRunning: state.timerRunning,
    timerStartedAt: state.timerStartedAt,
    timerAccumulatedSec: state.timerAccumulatedSec,
    showProjectTabsModal: state.showProjectTabsModal,
    activeProjectTabIndex: state.activeProjectTabIndex,
    selectedProjectTabIndex: state.selectedProjectTabIndex,
    projectTabs: (state.projectTabs || []).map((tab) => ({ index: Number(tab.index), name: tab.name || tab.projectName, active: !!(tab.active || tab.isCurrent) })),
    playlistName: playlist?.name || '',
    items: items.map((item) => ({
      id: item?.id,
      name: item?.name,
      durationSec: item?.durationSec,
      // No app dos musicos, nunca use remainingSec na assinatura.
      // O bridge atualiza esse campo durante a reproducao e isso recriava a lista,
      // interferindo na rolagem livre e na selecao manual.
      remainingSec: null,
      isBlock: item?.isBlock,
      blockColorHex: item?.blockColorHex,
      inheritedBlockColorHex: item?.inheritedBlockColorHex,
      familyRole: item?.familyRole,
      familyGroupId: item?.familyGroupId,
      depth: item?.depth,
    })),
  })
}

function bridgeLooksOffline() {
  const updatedAtMs = Number(state.lastBridgeUpdatedAtMs) || 0
  if (!updatedAtMs) return state.bridgeStatus !== 'online'
  return (Date.now() - updatedAtMs) > BRIDGE_OFFLINE_GRACE_MS
}

function renderEntryGate() {
  const offline = bridgeLooksOffline()
  return `<div class="app authGateApp" data-theme="${escapeHtml(state.theme || 'dark')}">
    <div class="authGateWrap">
      <div class="authGateCard">
        <img class="authGateLogo" src="./vsmusicos-icon-512.png" alt="VS Hook Musicos" />
        <div class="authGateTitle">VS Hook Musicos</div>
        <div class="authGateSubtitle">VISUALIZAÇÃO</div>
        <div class="authGateForm">
          <div class="authGateSingleButtonWrap">
            <button id="enterMusicosBtn" class="authGateButton" type="button" ${offline ? 'disabled' : ''}>ENTRAR</button>
          </div>
          ${offline ? '<div class="authGateOffline">REAPER OFFLINE</div>' : ''}
        </div>
      </div>
    </div>
  </div>`
}


function openProjectTabsModal() {
  state.showGearModal = false
  state.showProjectTabsModal = true
  state.selectedProjectTabIndex = Number.isFinite(Number(state.activeProjectTabIndex)) ? Number(state.activeProjectTabIndex) : 0
  render()
}

function closeProjectTabsModal() {
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
  pollBridge()
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


function renderGearModal() {
  if (!state.showGearModal) return ''
  return `<div class="modalOverlay" data-close-gear>
    <div class="modalSpacer"></div>
    <div class="modalBox settingsModalBox" data-stop-modal>
      <div class="modalTitle">CONFIGURAÇÕES</div>
      <div class="bridgeStatusCard">
        <span class="bridgeStatusLabel">CONEXÃO</span>
        <span class="${state.bridgeStatus === 'online' ? 'bridgeOnline' : 'bridgeOffline'}">${state.bridgeStatus === 'online' ? 'ON' : 'OFF'}</span>
      </div>
      <div class="settingsSectionTitle">BORDA RGB</div>
      <div class="settingsGrid settingsGridSingle">
        <button class="settingsToggleBtn settingsToggleWide" data-action="cycle-rgb-mode">RGB: ${escapeHtml(getRgbModeLabel())}</button>
      </div>
      <div class="settingsSectionTitle">TEMA</div>
      <div class="settingsGrid settingsGridTheme">
        <button class="${state.theme === 'dark' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-dark">ESCURO</button>
        <button class="${state.theme === 'light' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-light">CLARO</button>
      </div>
      <div class="modalButtons settingsBottomButtons">
        <button class="modalCancelBtn vshookExitButton" data-action="back-project-selector">SAIR</button>
        <button class="modalOkBtnWide settingsCloseButton" data-action="close-gear">FECHAR</button>
      </div>
    </div>
    <div class="modalBottomSpace"></div>
  </div>`
}

function getCurrentPlayingItem() {
  const playingId = String(state.playingId || '')
  if (!playingId) return null
  const matchesPlaying = (item) => String(item?.id ?? item?.songId ?? '') === playingId
  const regions = Array.isArray(state.regions) ? state.regions : []
  const region = regions.find(matchesPlaying)
  let playlistSong = null
  for (const playlist of (Array.isArray(state.playlists) ? state.playlists : [])) {
    const songs = Array.isArray(playlist?.songs) ? playlist.songs : []
    const found = songs.find(matchesPlaying)
    if (found) { playlistSong = found; break }
  }
  const display = getDisplayItems().find(matchesPlaying)
  const base = region || display || playlistSong
  if (!base) return null
  // Junta dados da musica do repertorio com os dados ao vivo da regiao.
  // Assim o nome aparece mesmo fora da aba atual e a barra usa remainingSec/durationSec reais.
  return { ...(playlistSong || {}), ...(display || {}), ...(region || {}), id: playingId }
}

function getMusicosQueuedItem() {
  const queuedId = getVisualQueuedSongId ? getVisualQueuedSongId() : (state.queuedSongId ? String(state.queuedSongId) : '')
  if (!queuedId) return null
  const song = findMusicosSongById(queuedId)
  if (!song || detectBlockItem(song) || isHashChildItem(song)) return null
  return song
}

function renderNowPlayingLine() {
  const playingItem = getCurrentPlayingItem()
  const queuedItem = getMusicosQueuedItem()
  const playingName = playingItem && !detectBlockItem(playingItem) ? upperText(playingItem?.name || playingItem?.label || '') : ''
  const queuedName = queuedItem ? upperText(queuedItem?.name || queuedItem?.label || '') : ''
  return `<div class="musicosNowPlayingLine liveQueueStatusPanel" data-musicos-now-playing="1">
    <div class="liveQueueStatusRow liveQueueStatusPlaying"><span class="liveQueueStatusPrefix">EM REPRODUÇÃO</span><span class="liveQueueStatusText">${escapeHtml(playingName || '--')}</span></div>
    <div class="liveQueueStatusRow liveQueueStatusQueued"><span class="liveQueueStatusPrefix">FILA DE ESPERA</span><span class="liveQueueStatusText">${escapeHtml(queuedName || '--')}</span></div>
  </div>`
}

function renderPopup(extraClass = '') {
  if (!bridgePopupDisplay.mounted) return ''
  const popupTextForRender = upperText(bridgePopupDisplay.text)
  const popupErrorForRender = bridgePopupDisplay.error
  const popupPersistentForRender = bridgePopupDisplay.persistent
  const popupClassSuffix = popupErrorForRender ? 'Error' : (/loop/i.test(String(popupTextForRender || '')) ? 'Success' : 'Marker')
  const extra = extraClass ? ` ${extraClass}` : ''
  return `<div class="appPopup appPopup${popupClassSuffix}${extra} ${popupPersistentForRender ? 'appPopupPersistent' : 'appPopupTransient'} ${bridgePopupDisplay.fading ? 'appPopupHidden' : ''}">${escapeHtml(popupTextForRender)}</div>`
}

function syncBridgePopupDom() {
  const appShell = document.querySelector('#app > .app')
  if (!appShell) return
  const lyricsSlot = state.lyricsPanelOpen ? document.querySelector('.lyricsScreen .lyricsPopupSlot') : null
  const rootPopup = appShell.querySelector(':scope > .appPopup')
  const slotPopup = lyricsSlot ? lyricsSlot.querySelector('.appPopup') : null
  const html = renderPopup(lyricsSlot ? 'lyricsInlinePopup' : '')
  if (!html) {
    if (rootPopup) rootPopup.remove()
    if (slotPopup) slotPopup.remove()
    return
  }
  const temp = document.createElement('div')
  temp.innerHTML = html
  const next = temp.firstElementChild
  if (!next) return
  if (lyricsSlot) {
    if (rootPopup) rootPopup.remove()
    next.classList.add('lyricsInlinePopup')
    if (slotPopup) slotPopup.replaceWith(next)
    else lyricsSlot.replaceChildren(next)
    return
  }
  if (slotPopup) slotPopup.remove()
  if (rootPopup) rootPopup.replaceWith(next)
  else appShell.insertAdjacentElement('afterbegin', next)
}

function render() {
  const app = document.getElementById('app')
  if (!app) return

  const previousList = document.querySelector('.musicosListBox')
  const previousTab = String(state.activeTab || 'playlist')
  const previousListScrollTop = previousList ? previousList.scrollTop : null
  if (previousList) {
    musicosManualScrollTopByTab[previousTab] = previousList.scrollTop || 0
  }

    // Se a tela de letra dos músicos já está aberta, não recria o app inteiro.
  // Recriar o DOM dava a sensação de abrir/fechar em loop.
  if (state.lyricsPanelOpen && document.querySelector('.lyricsScreen')) {
    syncBridgePopupDom()
    syncMusicosLyricsPanelDom()
    return
  }


  const signature = buildRenderSignature()
  if (signature === lastRenderSignature && !appLoadingVisible) return
  lastRenderSignature = signature

  if (!state.entered) {
    app.innerHTML = renderEntryGate()
    bindEvents()
    return
  }

  const playlist = getCurrentPlaylist()
  const items = getDisplayItems()
  const topTitle = state.activeTab === 'playlist'
    ? upperText(playlist?.name || state.currentPlaylistName || 'SEM REPERTÓRIO')
    : 'MÚSICAS'
  const topTime = state.activeTab === 'playlist'
    ? resolveMusicosPlaylistTotalText(playlist)
    : resolveMusicosRegionsTotalText()

  const borderColor = getBorderColorCss()
  const borderGlow = getBorderGlowCss()
  const borderStyle = state.rgbMode === 'off'
    ? `border-color:rgba(71,85,105,0.55);box-shadow:0 0 0 1px rgba(71,85,105,0.35), inset 0 0 10px rgba(255,255,255,0.03);`
    : `border-color:${borderColor};box-shadow:0 0 0 1px ${borderColor}, 0 0 14px ${borderGlow}, inset 0 0 10px rgba(255,255,255,0.03);`

  const popupHtml = renderPopup()
  const gearModal = renderGearModal()
  const projectTabsModal = renderProjectTabsModal()
  const lyricsPanelHtml = renderMusicosLyricsPanel()
  const chronoText = getMusicosChronoDisplayText()
  const nowPlayingHtml = renderNowPlayingLine()

  const topTitleHtml = buildTitleTicker(topTitle)

  // Evita capturar o scrollTop 0 criado pela reconstrução do DOM como se fosse rolagem do usuario.
  musicosIgnoreScrollCaptureUntil = Date.now() + 700

  app.innerHTML = `<div class="app" data-theme="${escapeHtml(state.theme)}" style="--app-border-color:${escapeHtml(borderColor)};--app-border-glow:${escapeHtml(borderGlow)};"><style>.musicosHeaderRow{width:100%!important;max-width:100%!important;display:block!important}.musicosHeaderRow .tabRow{display:grid!important;grid-template-columns:repeat(3,minmax(0,1fr))!important;align-items:center!important;gap:8px!important;width:100%!important;max-width:100%!important;box-sizing:border-box!important;justify-self:stretch!important;justify-content:stretch!important}.musicosHeaderRow .tabRow>.tab,.musicosHeaderRow .tabRow>.activeTab{width:100%!important;min-width:0!important;height:40px!important;min-height:40px!important;padding:0 8px!important;font-size:13px!important;line-height:1!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;display:flex!important;align-items:center!important;justify-content:center!important;letter-spacing:.01em!important;box-sizing:border-box!important}.musicosHeaderRow .headerTotal{grid-column:2!important;width:100%!important;min-width:0!important;font-size:13px!important;white-space:nowrap!important;margin:0!important;text-align:center!important;justify-self:stretch!important;align-self:center!important;overflow:hidden!important;text-overflow:clip!important;box-sizing:border-box!important}.musicosHeaderSpacer{display:none!important}.musicosLyricsNavButton{grid-column:3!important;justify-self:stretch!important;margin:0!important;margin-left:0!important;width:100%!important;min-width:0!important;max-width:none!important;flex:none!important;transform:none!important;height:40px!important;min-height:40px!important;font-size:20px!important;border-radius:11px!important;padding-left:0!important;padding-right:0!important;box-sizing:border-box!important}.musicosSectionLabel,.sectionLabel{display:none!important}.musicosContentPanel{padding-top:0!important}@media(max-width:380px){.musicosHeaderRow .tabRow{grid-template-columns:repeat(3,minmax(0,1fr))!important;gap:6px!important}.musicosHeaderRow .tabRow>.tab,.musicosHeaderRow .tabRow>.activeTab{height:38px!important;min-height:38px!important;font-size:12px!important;padding:0 6px!important}.musicosHeaderRow .headerTotal{font-size:12px!important}.musicosLyricsNavButton{height:38px!important;min-height:38px!important}}.hashChildItem,.hashParentItem,.rowLabelText,.songRowLabel,.regionRowLabel{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;}</style>
    ${popupHtml}
    <div class="container" style="${borderStyle}">
      <div class="musicosStickyPanel">
        <div class="topStatusRow topStatusRowMusicos">
          <div class="${state.activeTab === 'playlist' ? 'topStatusLeftPlaylist' : 'topStatusLeft'}">
            <span class="musicosStaticTitle">${topTitleHtml}</span>
          </div>
          <div class="topTimerButton topTimerButtonMusicos ${(state.timerRunning || state.timerMode === 'local_time') ? 'topTimerButtonRunning' : ''}" aria-live="polite" data-chrono-display="1">${escapeHtml(chronoText)}</div>
          <div class="topRightTools">
            <button class="menuButton gearMenuButton" data-action="open-gear">⚙</button>
          </div>
        </div>
        <div class="musicosHeaderRow">
          <div class="tabRow">
            <button class="activeTab musicosRepertorioButton" type="button" data-action="musicos-tab-playlist">${state.activeTab === 'regions' ? 'MÚSICAS' : 'REPERTÓRIOS'}</button>
            <span class="headerTotal">${escapeHtml(topTime)}</span><button class="tab markersNavButton markersNavButtonWide lyricsNavButton musicosLyricsNavButton" data-action="open-lyrics-panel">TP1</button>
          </div>
        </div>
      </div>
      <div class="musicosContentPanel musicosContentNoFooter" style="display:flex;flex-direction:column;min-height:0;flex:1 1 auto;padding-bottom:0;">
        ${nowPlayingHtml}
        <div class="listBox musicosListBox" style="flex:1 1 auto;min-height:0;padding-bottom:8px;scroll-padding-bottom:12px;">${renderRows(items, state.activeTab)}</div>
      </div>
    </div>
    ${gearModal}
    ${projectTabsModal}
    ${lyricsPanelHtml}
  </div>`

  bindEvents()
  scheduleMarqueeBehavior()
  window.requestAnimationFrame(() => {
    const list = document.querySelector('.musicosListBox')
    if (list) {
      const tab = String(state.activeTab || 'playlist')
      if (previousListScrollTop !== null) {
        list.scrollTop = previousListScrollTop
        musicosManualScrollTopByTab[tab] = previousListScrollTop
      } else {
        list.scrollTop = musicosManualScrollTopByTab[tab] || 0
      }
    }
    syncChronoDom()
    syncPlaybackDom()
    window.requestAnimationFrame(() => {
      const list2 = document.querySelector('.musicosListBox')
      if (list2) {
        const tab = String(state.activeTab || 'playlist')
        musicosManualScrollTopByTab[tab] = list2.scrollTop || 0
      }
      syncChronoDom()
      syncPlaybackDom()
      syncMusicosLyricsPanelDom()
    })
  })
}




function handleMusicosSwipeStart(event) {
  musicosSwipeStartX = event.changedTouches?.[0]?.clientX ?? null
  musicosSwipeStartY = event.changedTouches?.[0]?.clientY ?? null
  musicosSwipeStartAt = Date.now()
}

function handleMusicosSwipeEnd(event) {
  const endX = event.changedTouches?.[0]?.clientX ?? null
  const endY = event.changedTouches?.[0]?.clientY ?? null
  if (musicosSwipeStartX == null || musicosSwipeStartY == null || endX == null || endY == null) return
  const deltaX = endX - musicosSwipeStartX
  const deltaY = endY - musicosSwipeStartY
  const absX = Math.abs(deltaX)
  const absY = Math.abs(deltaY)
  const elapsed = Date.now() - musicosSwipeStartAt
  musicosSwipeStartX = null
  musicosSwipeStartY = null
  if (absX < 108 || absY > 78 || absX <= (absY * 1.7) || elapsed > 760) return

  if (state.lyricsPanelOpen) {
    // Dentro das letras: só swipe para a esquerda volta para a tela principal.
    if (deltaX <= -108) closeMusicosLyricsPanel()
    return
  }

  // Na tela principal: swipe para a direita abre a tela de letras.
  if (deltaX >= 108) openMusicosLyricsPanel()
}


function bindMusicosFreeScroll() {
  const list = document.querySelector('.musicosListBox')
  if (!list || list.dataset.freeScrollBound === '1') return
  list.dataset.freeScrollBound = '1'
  const markUserScroll = (event) => {
    const eventType = String(event?.type || '')
    // O evento scroll disparado pela recriação/restauração da lista não pode zerar
    // a posição manual. Toque e roda do mouse continuam valendo como ação do usuario.
    if (eventType === 'scroll' && Date.now() < musicosIgnoreScrollCaptureUntil) return
    musicosUserScrollLockedUntil = Date.now() + 2500
    const tab = String(state.activeTab || 'playlist')
    musicosManualScrollTopByTab[tab] = list.scrollTop || 0
  }
  list.addEventListener('touchstart', markUserScroll, { passive: true })
  list.addEventListener('touchstart', handleMusicosSwipeStart, { passive: true })
  list.addEventListener('touchmove', markUserScroll, { passive: true })
  list.addEventListener('touchend', handleMusicosSwipeEnd, { passive: true })
  list.addEventListener('wheel', markUserScroll, { passive: true })
  list.addEventListener('scroll', markUserScroll, { passive: true })
}

function bindMusicosLyricsSwipe() {
  const lyrics = document.querySelector('.lyricsScreen')
  if (!lyrics || lyrics.dataset.swipeBound === '1') return
  lyrics.dataset.swipeBound = '1'
  lyrics.addEventListener('touchstart', handleMusicosSwipeStart, { passive: true })
  lyrics.addEventListener('touchend', handleMusicosSwipeEnd, { passive: true })
}

function setMusicosActiveTab(tab) {
  const nextTab = tab === 'regions' ? 'regions' : 'playlist'
  const list = document.querySelector('.musicosListBox')
  if (list) musicosManualScrollTopByTab[String(state.activeTab || 'playlist')] = list.scrollTop || 0
  state.activeTab = nextTab
  musicosUserSelectedTab = true
  musicosUserScrollLockedUntil = Date.now() + 6000
  render()
}

function bindEvents() {
  bindMusicosFreeScroll()
  bindMusicosLyricsSwipe()
  document.getElementById('enterMusicosBtn')?.addEventListener('click', handleEnterApp)
  document.querySelector('[data-action="open-lyrics-panel"]')?.addEventListener('click', openMusicosLyricsPanel)
  document.querySelector('[data-action="close-lyrics-panel"]')?.addEventListener('click', closeMusicosLyricsPanel)
  document.querySelector('[data-action="musicos-tab-playlist"]')?.addEventListener('click', () => setMusicosActiveTab('playlist'))
  // Sem seleção no app dos Músicos: a lista é apenas monitorável/rolável.
  document.querySelector('[data-action="open-gear"]')?.addEventListener('click', (event) => {
    event.preventDefault()
    event.stopPropagation()
    openGearModal()
  })
  document.querySelector('[data-action="close-gear"]')?.addEventListener('click', closeGearModal)
  document.querySelector('[data-action="back-project-selector"]')?.addEventListener('click', backToVSHookProjectSelector)
  document.querySelector('[data-action="open-project-tabs"]')?.addEventListener('click', openProjectTabsModal)
  document.querySelector('[data-action="close-project-tabs"]')?.addEventListener('click', closeProjectTabsModal)
  document.querySelector('[data-action="confirm-project-tabs"]')?.addEventListener('click', confirmProjectTabsModal)
  document.querySelector('[data-close-project-tabs]')?.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeProjectTabsModal() })
  document.querySelectorAll('[data-project-tab-index]').forEach((el) => el.addEventListener('click', () => selectProjectTabInModal(el.getAttribute('data-project-tab-index'))))
  document.querySelector('[data-action="cycle-rgb-mode"]')?.addEventListener('click', cycleRgbMode)
  document.querySelector('[data-action="theme-dark"]')?.addEventListener('click', () => setTheme('dark'))
  document.querySelector('[data-action="theme-light"]')?.addEventListener('click', () => setTheme('light'))
  document.querySelector('[data-close-gear]')?.addEventListener('click', (event) => {
    if (event.target !== event.currentTarget) return
    closeGearModal()
  })
  document.querySelectorAll('[data-stop-modal]').forEach((el) => {
    el.addEventListener('click', (event) => event.stopPropagation())
  })
}

function updateBorderEffect() {
  const container = document.querySelector('.container')
  if (!container) return
  const appRoot = document.querySelector('#app > .app')
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
  loadThemePreference()
  registerPwaServiceWorker()
  setupScreenWakeLock()
  appBootStartedAt = Date.now()
  showBootLoader()
  try { render() } catch (error) { console.error('render start error', error) }
  updateBorderEffect()
  pollBridge()
  if (borderTimer) clearInterval(borderTimer)
  if (bridgeTimer) clearInterval(bridgeTimer)
  if (playbackRenderTimer) clearInterval(playbackRenderTimer)
  borderTimer = setInterval(() => {
    if (state.rgbMode === 'auto') {
      state.borderHue = (state.borderHue + 6) % 360
      updateBorderEffect()
    }
  }, 180)
  bridgeTimer = setInterval(pollBridge, POLL_INTERVAL_MS)
  playbackRenderTimer = setInterval(() => {
    try {
      syncChronoDom()
      syncPlaybackDom()
      syncMusicosLyricsPanelDom()
    } catch (error) {
      console.error('playback render error', error)
    }
  }, 250)
  window.setTimeout(() => {
    if (appLoadingVisible) hideBootLoader(true)
  }, 4500)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startApp, { once: true })
} else {
  startApp()
}


function syncChronoDom() {
  const chronoText = getMusicosChronoDisplayText()
  document.querySelectorAll('[data-chrono-display]').forEach((node) => {
    if (node.textContent !== chronoText) node.textContent = chronoText
  })
}


function syncMusicosPlayingRowProgressDom() {
  const currentId = state.playingId != null ? String(state.playingId) : ''
  if (!currentId) return false

  const sourceItem = getCurrentPlayingItem() || findMusicosSongById(currentId)
  if (!sourceItem || detectBlockItem(sourceItem)) return false

  const playbackItem = getPlaybackAwareItem(sourceItem, true, false)
  const ratio = Math.max(0, Math.min(1, Number(getRowProgressRatio(playbackItem, true, false)) || 0))
  const visualRatio = Math.max(0.002, ratio)
  const timeValue = playbackItem?.remainingSec ?? playbackItem?.durationSec
  const timeText = formatTime(timeValue)
  let touched = false

  document.querySelectorAll('.musicosListBox [data-item-id]').forEach((row) => {
    const rowId = String(row.getAttribute('data-item-id') || '')
    if (rowId !== currentId) {
      row.classList.remove('playing')
      row.removeAttribute('data-playing-row')
      const oldBar = row.querySelector('[data-row-progress-bar]')
      if (oldBar) oldBar.remove()
      return
    }
    if (row.classList.contains('blockItem')) return

    row.classList.add('playing')
    row.setAttribute('data-playing-row', '1')

    let bar = row.querySelector('[data-row-progress-bar]')
    if (!bar) {
      bar = document.createElement('div')
      bar.className = 'progressBar progressBarWithNumber'
      bar.setAttribute('data-row-progress-bar', '1')
      bar.style.left = '42px'
      bar.style.minWidth = '10px'
      row.insertBefore(bar, row.firstChild)
    }
    bar.style.width = `calc(${(visualRatio * 100).toFixed(3)}% - ${(42 * visualRatio).toFixed(3)}px)`

    const timeNode = row.querySelector('.rightCol span')
    if (timeNode && timeText && timeNode.textContent !== timeText) {
      timeNode.textContent = timeText
    }
    touched = true
  })

  return touched
}

function syncPlaybackDom() {
  if (state.lyricsPanelOpen) {
    syncMusicosLyricsPanelDom()
    return
  }

  const panel = document.querySelector('.musicosContentPanel')
  if (panel) {
    const current = panel.querySelector('.musicosNowPlayingLine')
    const next = renderNowPlayingLine()
    if (!current && next) {
      const label = panel.querySelector('.musicosSectionLabel')
      if (label) label.insertAdjacentHTML('afterend', next)
      else panel.insertAdjacentHTML('afterbegin', next)
    } else if (current && !next) {
      current.remove()
    } else if (current && next && current.outerHTML !== next) {
      current.outerHTML = next
    }
  }

  const list = document.querySelector('.musicosListBox')
  if (!list) return

  // Enquanto existe musica tocando, o Lua nao pode mexer na lista dos musicos.
  // A lista fica livre para rolar e selecionar outras musicas; so a barra superior
  // de progresso e atualizada.
  if (state.playingId) {
    syncMusicosPlayingRowProgressDom()
    return
  }

  // Deixa a navegacao da lista livre: durante gesto/inercia do usuario,
  // atualiza a barra superior, mas nao recria as linhas nem puxa o scroll.
  if (Date.now() < musicosUserScrollLockedUntil) return

  const scrollTop = list.scrollTop
  const html = renderRows(getDisplayItems(), state.activeTab)
  if (list.innerHTML !== html) {
    list.innerHTML = html
    list.scrollTop = scrollTop
    bindMusicosFreeScroll()
    scheduleMarqueeBehavior()
  }
}


/* VS_HOOK_MUSICOS_FIX8_TP1_ONLY */
(function(){
  if (window.__VSHOOK_MUSICOS_FIX8_TP1_ONLY__) return;
  window.__VSHOOK_MUSICOS_FIX8_TP1_ONLY__ = true;
  getMusicosCurrentLyricsSong = function() {
    const mediaType = String(state.tp1MediaType || 'text').toLowerCase();
    const allowText = !mediaType || mediaType === 'text' || mediaType === 'lyrics' || mediaType === 'empty' || mediaType === 'empty_item' || mediaType === 'emptyitem' || mediaType === 'text/plain';
    const title = String(state.tp1SongName || '').trim();
    const text = allowText ? String(state.tp1LyricsText || '').trim() : '';
    if (!title && !text) return null;
    return { name: title || 'TELEPROMPT 1', lyricsText: text };
  };
  const previousUpdateBridgeStateFix8 = typeof updateBridgeState === 'function' ? updateBridgeState : null;
  if (previousUpdateBridgeStateFix8) {
    updateBridgeState = function(data) {
      previousUpdateBridgeStateFix8(data);
      state.tp1MediaType = String(data?.tp1MediaType || data?.telepromptTp1MediaType || state.tp1MediaType || 'text').toLowerCase();
      const allowText = !state.tp1MediaType || state.tp1MediaType === 'text' || state.tp1MediaType === 'lyrics' || state.tp1MediaType === 'empty' || state.tp1MediaType === 'empty_item' || state.tp1MediaType === 'emptyitem' || state.tp1MediaType === 'text/plain';
      state.tp1LyricsText = allowText ? String(data?.tp1LyricsText || data?.tp1Lyrics || data?.telepromptTp1Lyrics || '') : '';
      state.tp1SongName = String(data?.tp1SongName || data?.telepromptTp1SongName || data?.tp1Song || '');
    };
  }
})();


/* VS_HOOK_MUSICOS_FIX9_TP1_VISUAL_ONLY: sem armazenamento; mostra só nome/letra textual do TP1. */
(function(){
  if (window.__VSHOOK_MUSICOS_FIX9_TP1_VISUAL_ONLY__) return;
  window.__VSHOOK_MUSICOS_FIX9_TP1_VISUAL_ONLY__ = true;

  function mediaAllowsTextFix9(type) {
    const t = String(type || 'text').toLowerCase().replace(/[\s-]+/g, '_');
    return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain';
  }

  const previousSyncFromBridgeMusicosFix9 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (previousSyncFromBridgeMusicosFix9) {
    syncFromBridge = function(data) {
      previousSyncFromBridgeMusicosFix9(data);
      const mediaType = String(data?.tp1MediaType || data?.telepromptTp1MediaType || state.tp1MediaType || 'text').toLowerCase();
      state.tp1MediaType = mediaType;
      state.tp1SongName = String(data?.tp1SongName || data?.telepromptTp1SongName || data?.tp1Song || state.tp1SongName || '');
      state.tp1LyricsText = mediaAllowsTextFix9(mediaType) ? String(data?.tp1LyricsText || data?.tp1Lyrics || data?.telepromptTp1Lyrics || '') : '';
    };
  }

  getCurrentLyricsSong = function() {
    const mediaType = String(state.tp1MediaType || 'text').toLowerCase();
    const title = String(state.tp1SongName || '').trim();
    const text = mediaAllowsTextFix9(mediaType) ? String(state.tp1LyricsText || '').trim() : '';
    return { name: title || 'TELEPROMPT 1', lyricsText: text };
  };

  if (typeof renderMusicosLyricsPanel === 'function') {
    const previousRenderMusicosLyricsPanelFix9 = renderMusicosLyricsPanel;
    renderMusicosLyricsPanel = function() {
      const html = previousRenderMusicosLyricsPanelFix9();
      return html
        .replace(/SEM LETRA CADASTRADA/g, 'SEM CONTEÚDO NO TP1')
        .replace(/LETRAS/g, 'TELEPROMPT 1');
    };
  }
})();


/* VS_HOOK_NATIVE_FIX10_MUSICOS: TP1 color/font config and compact return button. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX10_MUSICOS__) return;
  window.__VSHOOK_NATIVE_FIX10_MUSICOS__ = true;
  const TP_COLOR_KEY = 'vshook_musicos_tp_text_color';
  const TP_FONT_KEY = 'vshook_musicos_tp_font_family';
  const TP_COLORS = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];
  function lsGet(key, fallback){ try { return localStorage.getItem(key) || fallback; } catch(e){ return fallback; } }
  function lsSet(key, value){ try { localStorage.setItem(key, String(value || '')); } catch(e){} }
  function getColor(){ return lsGet(TP_COLOR_KEY, '#f8fafc'); }
  function getFont(){ return lsGet(TP_FONT_KEY, TP_FONTS[0]); }
  function setColor(value){ lsSet(TP_COLOR_KEY, value); render?.(); }
  function setFont(value){ lsSet(TP_FONT_KEY, value); render?.(); }

  function mediaAllowsTextFix10(mediaType) {
    const t = String(mediaType || 'text').toLowerCase().replace(/[- ]/g, '_');
    return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain';
  }
  getMusicosCurrentLyricsSong = function() {
    const mediaType = String(state.tp1MediaType || 'text').toLowerCase();
    const title = String(state.tp1SongName || '').trim();
    const text = mediaAllowsTextFix10(mediaType) ? String(state.tp1LyricsText || '').trim() : '';
    return { name: title || 'TELEPROMPT 1', lyricsText: text };
  };
  renderMusicosLyricsPanel = function() {
    if (!state.lyricsPanelOpen) return '';
    const song = getMusicosCurrentLyricsSong();
    const title = upperText(song.name || 'TELEPROMPT 1');
    const lyricsText = String(song.lyricsText || '').trim();
    const textToShow = lyricsText || 'SEM CONTEÚDO NO TP1';
    const progress = Math.round(getMusicosLyricsProgressRatio(song) * 1000) / 10;
    return `<div class="lyricsScreen telepromptOnlyScreen" style="--tp-text-color:${escapeHtml(getColor())};--tp-font:${escapeHtml(getFont())}">
      <div class="lyricsTopBar">
        <div class="lyricsNowPlaying lyricsNowPlayingWideFix10">
          <div class="lyricsNowPlayingTitle" data-lyrics-title>${escapeHtml(title)}</div>
          <div class="lyricsProgressTrack"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${progress}%"></div></div>
        </div>
        <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonCompactFix10" data-action="close-lyrics-panel">&gt;&gt;</button>
      </div>
      <div class="lyricsBody">
        <div class="lyricsTextView tpLyricsTextFix10" data-lyrics-text-view data-lyrics-source="${escapeHtml(textToShow)}">${lyricsTextToHtml(textToShow)}</div>
      </div>
    </div>`;
  };
  if (typeof renderGearModal === 'function') {
    const previousRenderGearModal = renderGearModal;
    renderGearModal = function() {
      let html = previousRenderGearModal();
      if (!html || html.includes('TP1 LETRA')) return html;
      const colorButtons = TP_COLORS.map(c => `<button class="settingsToggleBtn ${getColor() === c ? 'settingsToggleBtnActive' : ''}" data-action="tp-color" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
      const fontButtons = TP_FONTS.map((f,i) => `<button class="settingsToggleBtn ${getFont() === f ? 'settingsToggleBtnActive' : ''}" data-action="tp-font" data-font="${escapeHtml(f)}" style="font-family:${escapeHtml(f)}">${TP_FONT_LABELS[i]}</button>`).join('');
      const block = `<div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix10">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix10">${fontButtons}</div>`;
      return html.replace('<div class="modalButtons settingsBottomButtons">', block + '<div class="modalButtons settingsBottomButtons">');
    };
  }
  if (typeof bindEvents === 'function') {
    const previousBindEvents = bindEvents;
    bindEvents = function() {
      previousBindEvents();
      document.querySelectorAll('[data-action="tp-color"]').forEach(el => el.addEventListener('click', () => setColor(el.getAttribute('data-color') || '#f8fafc')));
      document.querySelectorAll('[data-action="tp-font"]').forEach(el => el.addEventListener('click', () => setFont(el.getAttribute('data-font') || TP_FONTS[0])));
    };
  }
  function installStyle(){
    if (document.getElementById('vshook-native-fix10-musicos-style')) return;
    const style=document.createElement('style');
    style.id='vshook-native-fix10-musicos-style';
    style.textContent=`.lyricsBackButtonCompactFix10{width:54px!important;min-width:54px!important;max-width:54px!important;padding-left:0!important;padding-right:0!important;flex:0 0 54px!important}.lyricsNowPlayingWideFix10{min-width:0!important;flex:1 1 auto!important}.tpLyricsTextFix10{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important;font-size:clamp(22px,5.6vw,38px)!important;line-height:1.28!important;text-align:center!important;white-space:pre-wrap!important}.settingsGridTpFix10{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important}.settingsGridFontFix10{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}.settingsGridTpFix10 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important}`;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installStyle); else installStyle();
})();


/* VS_HOOK_NATIVE_FIX11_MUSICOS: TP1 layout/config igual Diretor. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX11_MUSICOS__) return;
  window.__VSHOOK_NATIVE_FIX11_MUSICOS__ = true;
  const TP_COLOR_KEY = 'vshook_musicos_tp_text_color';
  const TP_FONT_KEY = 'vshook_musicos_tp_font_family';
  const TP_COLORS = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];
  const getLS = (k, f) => { try { return localStorage.getItem(k) || f; } catch(e) { return f; } };
  const setLS = (k, v) => { try { localStorage.setItem(k, String(v || '')); } catch(e) {} };
  const getColor = () => getLS(TP_COLOR_KEY, '#f8fafc');
  const getFont = () => getLS(TP_FONT_KEY, TP_FONTS[0]);
  const setColor = (v) => { setLS(TP_COLOR_KEY, v || '#f8fafc'); render?.(); };
  const setFont = (v) => { setLS(TP_FONT_KEY, v || TP_FONTS[0]); render?.(); };
  function installStyle(){
    if (document.getElementById('vshook-native-fix11-musicos-style')) return;
    const s = document.createElement('style');
    s.id = 'vshook-native-fix11-musicos-style';
    s.textContent = `.lyricsTopBarTpFix10,.lyricsTopBarTpFix11{display:flex!important;align-items:center!important;gap:8px!important;width:100%!important;box-sizing:border-box!important}.lyricsNowPlayingWideFix10,.lyricsNowPlayingWideFix11{flex:1 1 auto!important;width:auto!important;max-width:none!important;min-width:0!important;overflow:hidden!important}.lyricsBackButtonCompactFix10,.lyricsBackButtonCompactFix11{width:68px!important;min-width:68px!important;max-width:68px!important;flex:0 0 68px!important;padding-left:0!important;padding-right:0!important;font-size:22px!important}.tpLyricsTextFix10,.tpLyricsTextFix11{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important}.settingsGridTpFix11{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important}.settingsGridFontFix11{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}.settingsGridTpFix11 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important}`;
    document.head.appendChild(s);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installStyle); else installStyle();
  function inject(){
    try {
      const box = document.querySelector('.settingsModalBox');
      if (!box || box.querySelector('[data-fix11-tp-settings="1"]') || box.querySelector('[data-fix12-tp-settings="1"]')) return;
      const wrap = document.createElement('div');
      wrap.setAttribute('data-fix11-tp-settings','1');
      const colorButtons = TP_COLORS.map(c => `<button class="settingsToggleBtn ${getColor() === c ? 'settingsToggleBtnActive' : ''}" data-action="tp-color-fix11" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
      const fontButtons = TP_FONTS.map((f,i) => `<button class="settingsToggleBtn ${getFont() === f ? 'settingsToggleBtnActive' : ''}" data-action="tp-font-fix11" data-font="${f}" style="font-family:${f}">${TP_FONT_LABELS[i]}</button>`).join('');
      wrap.innerHTML = `<div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix11">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix11">${fontButtons}</div>`;
      const bottom = box.querySelector('.settingsBottomButtons');
      box.insertBefore(wrap, bottom || null);
      wrap.querySelectorAll('[data-action="tp-color-fix11"]').forEach(el => el.addEventListener('click', () => setColor(el.getAttribute('data-color') || '#f8fafc')));
      wrap.querySelectorAll('[data-action="tp-font-fix11"]').forEach(el => el.addEventListener('click', () => setFont(el.getAttribute('data-font') || TP_FONTS[0])));
    } catch(e) {}
  }
  if (typeof bindEvents === 'function') {
    const prev = bindEvents;
    bindEvents = function(){ prev(); inject(); };
  }
  if (typeof renderLyricsPanel === 'function') {
    const prevRender = renderLyricsPanel;
    renderLyricsPanel = function(){
      const html = prevRender();
      if (!html) return html;
      return html
        .replace(/lyricsTopBarTpFix10/g, 'lyricsTopBarTpFix10 lyricsTopBarTpFix11')
        .replace(/lyricsNowPlayingWideFix10/g, 'lyricsNowPlayingWideFix10 lyricsNowPlayingWideFix11')
        .replace(/lyricsBackButtonCompactFix10/g, 'lyricsBackButtonCompactFix10 lyricsBackButtonCompactFix11')
        .replace(/tpLyricsTextFix10/g, 'tpLyricsTextFix10 tpLyricsTextFix11')
        .replace(/--tp-text-color:[^;]+;/, `--tp-text-color:${getColor()};`)
        .replace(/--tp-font:[^;]+;/, `--tp-font:${getFont()};`);
    };
  }
})();


/* VS_HOOK_NATIVE_FIX12_MUSICOS: TP1 only, single config, larger title/progress area. */
(function(){
  if (window.__VSHOOK_NATIVE_FIX12_MUSICOS__) return;
  window.__VSHOOK_NATIVE_FIX12_MUSICOS__ = true;
  const TP_COLOR_KEY = 'vshook_musicos_tp_text_color';
  const TP_FONT_KEY = 'vshook_musicos_tp_font_family';
  const TP_COLORS = ['#f8fafc', '#facc15', '#22c55e', '#38bdf8', '#f472b6', '#fb923c'];
  const TP_FONTS = ['Inter, Arial, sans-serif', 'Arial, sans-serif', 'Verdana, sans-serif', 'Georgia, serif', 'Courier New, monospace', 'Times New Roman, serif'];
  const TP_FONT_LABELS = ['PADRÃO', 'ARIAL', 'VERDANA', 'GEORGIA', 'COURIER', 'TIMES'];
  const esc = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const up = (v) => (typeof upperText === 'function' ? upperText(v) : String(v || '').toUpperCase());
  const lsGet = (k, f) => { try { return localStorage.getItem(k) || f; } catch(e) { return f; } };
  const lsSet = (k, v) => { try { localStorage.setItem(k, String(v || '')); } catch(e) {} };
  const getColor = () => lsGet(TP_COLOR_KEY, '#f8fafc');
  const getFont = () => lsGet(TP_FONT_KEY, TP_FONTS[0]);
  const setColor = (v) => { lsSet(TP_COLOR_KEY, v || '#f8fafc'); render?.(); };
  const setFont = (v) => { lsSet(TP_FONT_KEY, v || TP_FONTS[0]); render?.(); };
  function mediaAllowsText(type){ const t = String(type || 'text').toLowerCase().replace(/[\s-]+/g,'_'); return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain'; }
  function tpTitle(){ return String(state.tp1SongName || state.telepromptTp1SongName || state.tp1Song || state.currentSongName || state.playingSongName || 'TELEPROMPT 1').trim() || 'TELEPROMPT 1'; }
  function tpText(){ const media = state.tp1MediaType || state.telepromptTp1MediaType || 'text'; return mediaAllowsText(media) ? String(state.tp1LyricsText || state.tp1Lyrics || state.telepromptTp1Lyrics || state.telepromptTp1Text || '').trim() : ''; }

  if (typeof syncFromBridge === 'function' && !window.__VSHOOK_NATIVE_FIX12_MUSICOS_SYNC_WRAPPED__) {
    window.__VSHOOK_NATIVE_FIX12_MUSICOS_SYNC_WRAPPED__ = true;
    const prev = syncFromBridge;
    syncFromBridge = function(data){
      prev(data);
      const media = String(data?.tp1MediaType || data?.telepromptTp1MediaType || state.tp1MediaType || 'text');
      state.tp1MediaType = media;
      state.tp1SongName = String(data?.tp1SongName || data?.telepromptTp1SongName || data?.tp1Song || state.tp1SongName || '');
      state.tp1LyricsText = mediaAllowsText(media) ? String(data?.tp1LyricsText || data?.tp1Lyrics || data?.telepromptTp1Lyrics || data?.telepromptTp1Text || state.tp1LyricsText || '') : '';
    };
  }
  getCurrentLyricsSong = function(){ return { name: tpTitle(), lyricsText: tpText() }; };
  getMusicosCurrentLyricsSong = getCurrentLyricsSong;

  renderMusicosLyricsPanel = function(){
    if (!state.lyricsPanelOpen) return '';
    const title = up(tpTitle());
    const text = tpText() || 'SEM CONTEÚDO NO TP1';
    const progress = (() => { try { const d = Number(state.playbackDurationSec || state.currentSongDurationSec || 0); const r = Number(state.playbackRemainingSec || state.currentSongRemainingSec); if (d > 0 && Number.isFinite(r)) return Math.max(0, Math.min(100, ((d-r)/d)*100)); } catch(e){} return 0; })();
    return `<div class="lyricsScreen telepromptOnlyScreen musicosTp1OnlyScreen" style="--tp-text-color:${esc(getColor())};--tp-font:${esc(getFont())}">
      <div class="lyricsTopBar lyricsTopBarTpFix12">
        <div class="lyricsNowPlaying lyricsNowPlayingTpFix12">
          <div class="lyricsNowPlayingTitle lyricsNowPlayingTitleFix12" data-lyrics-title>${esc(title)}</div>
          <div class="lyricsProgressTrack lyricsProgressTrackFix12"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${Math.round(progress*10)/10}%"></div></div>
        </div>
        <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonFix12" data-action="close-lyrics-panel">&gt;&gt;</button>
      </div>
      <div class="lyricsBody lyricsBodyTpFix12">
        <div class="lyricsTextView tpLyricsTextFix12" data-lyrics-text-view data-lyrics-source="${esc(text)}">${typeof lyricsTextToHtml === 'function' ? lyricsTextToHtml(text) : esc(text)}</div>
      </div>
    </div>`;
  };
  renderLyricsPanel = renderMusicosLyricsPanel;

  function tpSettingsBlock(){
    const colorButtons = TP_COLORS.map(c => `<button class="settingsToggleBtn ${getColor() === c ? 'settingsToggleBtnActive' : ''}" data-action="tp-color-fix12" data-color="${c}" style="color:${c};border-color:${c}">A</button>`).join('');
    const fontButtons = TP_FONTS.map((f,i) => `<button class="settingsToggleBtn ${getFont() === f ? 'settingsToggleBtnActive' : ''}" data-action="tp-font-fix12" data-font="${esc(f)}" style="font-family:${esc(f)}">${TP_FONT_LABELS[i]}</button>`).join('');
    return `<div data-fix12-tp-settings="1"><div class="settingsSectionTitle">TP1 LETRA</div><div class="settingsGrid settingsGridTpFix12">${colorButtons}</div><div class="settingsSectionTitle">FONTE TP1</div><div class="settingsGrid settingsGridFontFix12">${fontButtons}</div></div>`;
  }
  renderGearModal = function(){
    if (!state.showGearModal) return '';
    return `<div class="modalOverlay" data-close-gear>
      <div class="modalSpacer"></div>
      <div class="modalBox settingsModalBox" data-stop-modal>
        <div class="modalTitle">CONFIGURAÇÕES</div>
        <div class="bridgeStatusCard"><span class="bridgeStatusLabel">CONEXÃO</span><span class="bridgeOnline">NATIVE ON</span></div>
        <div class="settingsSectionTitle">BORDA RGB</div>
        <div class="settingsGrid settingsGridSingle"><button class="settingsToggleBtn settingsToggleWide" data-action="cycle-rgb-mode">RGB: ${esc(getRgbModeLabel?.() || '')}</button></div>
        <div class="settingsSectionTitle">TEMA</div>
        <div class="settingsGrid settingsGridTheme"><button class="${state.theme === 'dark' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-dark">ESCURO</button><button class="${state.theme === 'light' ? 'settingsToggleBtn settingsToggleBtnActive' : 'settingsToggleBtn'}" data-action="theme-light">CLARO</button></div>
        ${tpSettingsBlock()}
        <div class="modalButtons settingsBottomButtons"><button class="modalCancelBtn vshookExitButton" data-action="back-project-selector">SAIR</button><button class="modalOkBtnWide settingsCloseButton" data-action="close-gear">FECHAR</button></div>
      </div>
      <div class="modalBottomSpace"></div>
    </div>`;
  };
  if (typeof bindEvents === 'function') {
    const prevBind = bindEvents;
    bindEvents = function(){
      prevBind();
      document.querySelectorAll('[data-action="tp-color-fix12"]').forEach(el => el.addEventListener('click', () => setColor(el.getAttribute('data-color') || '#f8fafc')));
      document.querySelectorAll('[data-action="tp-font-fix12"]').forEach(el => el.addEventListener('click', () => setFont(el.getAttribute('data-font') || TP_FONTS[0])));
    };
  }
  function installStyle(){
    if (document.getElementById('vshook-native-fix12-musicos-style')) return;
    const style = document.createElement('style');
    style.id = 'vshook-native-fix12-musicos-style';
    style.textContent = `.lyricsTopBarTpFix12{display:flex!important;align-items:center!important;gap:10px!important;width:100%!important;box-sizing:border-box!important;padding:10px 10px 8px!important;min-height:74px!important}.lyricsNowPlayingTpFix12{flex:1 1 auto!important;min-width:0!important;width:auto!important;max-width:none!important;display:flex!important;flex-direction:column!important;gap:7px!important;overflow:hidden!important}.lyricsNowPlayingTitleFix12{display:block!important;min-width:0!important;max-width:100%!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;font-size:clamp(15px,4.2vw,24px)!important;font-weight:1000!important;line-height:1.05!important}.lyricsProgressTrackFix12{width:100%!important;min-width:0!important;flex:0 0 8px!important;height:8px!important}.lyricsBackButtonFix12{width:82px!important;min-width:82px!important;max-width:82px!important;flex:0 0 82px!important;padding-left:0!important;padding-right:0!important;font-size:23px!important;font-weight:1000!important;display:flex!important;align-items:center!important;justify-content:center!important}.tpLyricsTextFix12{color:var(--tp-text-color,#f8fafc)!important;font-family:var(--tp-font,Inter,Arial,sans-serif)!important;font-size:clamp(22px,5.8vw,40px)!important;line-height:1.26!important;text-align:center!important;white-space:pre-wrap!important}.settingsGridTpFix12{display:grid!important;grid-template-columns:repeat(6,minmax(0,1fr))!important;gap:8px!important}.settingsGridTpFix12 .settingsToggleBtn{font-size:22px!important;font-weight:1000!important}.settingsGridFontFix12{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}`;
    document.head.appendChild(style);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installStyle); else installStyle();
})();


/* VS_HOOK_FIX39_MUSICOS_BASIC_TIMER_QUEUE */
(function(){
  if (window.__VSHOOK_FIX39_MUSICOS_BASIC_TIMER_QUEUE__) return;
  window.__VSHOOK_FIX39_MUSICOS_BASIC_TIMER_QUEUE__ = true;
  const oldSync = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (!oldSync) return;
  let lastTimerSeq = 0;
  syncFromBridge = function(data){
    oldSync(data);
    if (!data) return;
    const q = data.queuedSongId ?? data.queuedPlaylistSongId ?? data.queuedRegionNumber ?? null;
    if (q != null && String(q) !== '') state.queuedSongId = String(q);
    const seq = Number(data.timerTriggerSeq || 0);
    if (seq && seq !== lastTimerSeq) {
      lastTimerSeq = seq;
      state.timerRunning = !!data.timerRunning;
      state.timerStartedAt = Number(data.timerStartedAt || data.timerStartedAtMs || Date.now()) || Date.now();
      state.timerAccumulatedSec = Number(data.timerAccumulatedSec || 0) || 0;
      try { if (typeof render === 'function') render(); } catch(e) {}
    }
  };
})();

/* VS_HOOK_FIX51_MUSICOS_TIMER_LUA_DIRECT */
(function(){
  if (window.__VSHOOK_FIX51_MUSICOS_TIMER_LUA_DIRECT__) return;
  window.__VSHOOK_FIX51_MUSICOS_TIMER_LUA_DIRECT__ = true;
  let lastTimerSignature51 = '';
  const oldSync51 = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (!oldSync51) return;
  syncFromBridge = function(data){
    oldSync51(data);
    if (!data) return;
    const hasTimer = Object.prototype.hasOwnProperty.call(data, 'timerRunning') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAt') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAtMs') ||
      Object.prototype.hasOwnProperty.call(data, 'timerTriggerSeq');
    if (!hasTimer) return;
    const started = Number(data.timerStartedAt || data.timerStartedAtMs || 0) || 0;
    const accum = Number(data.timerAccumulatedSec || data.timerDisplaySec || 0) || 0;
    const mode = String(data.timerMode || data.timerType || state.timerMode || 'progressive');
    const target = Number(data.timerTargetSec || state.timerTargetSec || 0) || 0;
    const running = !!data.timerRunning;
    const seq = Number(data.timerTriggerSeq || 0) || 0;
    const sig = [running ? 1 : 0, Math.floor(started), Math.floor(accum), mode, Math.floor(target), seq].join('|');
    if (sig === lastTimerSignature51) return;
    lastTimerSignature51 = sig;
    state.timerRunning = running;
    state.timerStartedAt = started || Date.now();
    state.timerAccumulatedSec = accum;
    state.timerMode = mode;
    state.timerTargetSec = target;
    state.timerTriggerSeq = seq;
    try { render?.(); } catch(e) {}
  };
})();


/* VS_HOOK_FIX55_MUSICOS_TIMER_LIGHT */
(function(){
  if (window.__VSHOOK_FIX55_MUSICOS_TIMER_LIGHT__) return;
  window.__VSHOOK_FIX55_MUSICOS_TIMER_LIGHT__ = true;
  let lastSig = '';
  const oldSync = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (!oldSync) return;
  syncFromBridge = function(data){
    oldSync(data);
    if (!data) return;
    const hasTimer = Object.prototype.hasOwnProperty.call(data, 'timerRunning') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAt') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAtMs') ||
      Object.prototype.hasOwnProperty.call(data, 'timerTriggerSeq') ||
      Object.prototype.hasOwnProperty.call(data, 'timerDisplaySec');
    if (!hasTimer) return;
    const running = !!data.timerRunning;
    const started = Number(data.timerStartedAt || data.timerStartedAtMs || 0) || (running ? Date.now() : 0);
    const accum = Number(data.timerAccumulatedSec || data.timerDisplaySec || 0) || 0;
    const mode = String(data.timerMode || data.timerType || state.timerMode || 'progressive');
    const target = Number(data.timerTargetSec || state.timerTargetSec || 0) || 0;
    const seq = Number(data.timerTriggerSeq || 0) || 0;
    const sig = [running ? 1 : 0, Math.floor(started), Math.floor(accum), mode, Math.floor(target), seq].join('|');
    if (sig === lastSig) return;
    lastSig = sig;
    state.timerRunning = running;
    state.timerStartedAt = started;
    state.timerStartedAtMs = started;
    state.timerAccumulatedSec = accum;
    state.timerDisplaySec = accum;
    state.timerMode = mode;
    state.timerTargetSec = target;
    state.timerTriggerSeq = seq;
    try { if (typeof refreshChronoRenderLoop === 'function') refreshChronoRenderLoop(); } catch(e) {}
    try { if (typeof render === 'function') render(); } catch(e) {}
  };
})();


/* VS_HOOK_FIX103_NATIVE_TP_MEDIA_AND_AUTO_SYNC
   TP1 via extensão: imagem/vídeo são renderizados por URL HTTP da extensão, não como texto. */
(function(){
  if (window.__VSHOOK_FIX103_NATIVE_TP_MEDIA_MUSICOS__) return;
  window.__VSHOOK_FIX103_NATIVE_TP_MEDIA_MUSICOS__ = true;
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
  if (typeof renderMusicosLyricsPanel === 'function' || typeof renderLyricsPanel === 'function') {
    const renderTpPanel103 = function(){
      if (!state.lyricsPanelOpen) return '';
      const title = up(tpTitle());
      const progress = Math.round(progress103()*10)/10;
      return `<div class="lyricsScreen telepromptOnlyScreen musicosTp1OnlyScreen tpMediaScreenFix103" style="--tp-text-color:${esc((window.__vshookMusicosTpColorFix12 && window.__vshookMusicosTpColorFix12()) || '#f8fafc')};--tp-font:${esc((window.__vshookMusicosTpFontFix12 && window.__vshookMusicosTpFontFix12()) || 'Inter, Arial, sans-serif')}">
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
    if (typeof renderMusicosLyricsPanel !== 'undefined') renderMusicosLyricsPanel = renderTpPanel103;
    if (typeof renderLyricsPanel !== 'undefined') renderLyricsPanel = renderTpPanel103;
  }
  if (typeof syncLyricsPanelDom === 'function') {
    const prevSyncDom = syncLyricsPanelDom;
    syncLyricsPanelDom = function(){ try { prevSyncDom(); } catch(e) {} syncTpMediaDom103(); };
  }
  setInterval(syncTpMediaDom103, 500);
})();


/* VS_HOOK_FIX_STOP_QUEUE_TP_MUSICOS_FINAL
   - Blocos sem ':' no app dos musicos.
   - Progresso do TP1 usa a mesma base da musica tocando/lista, sem sobe/desce.
*/
(function(){
  if (window.__VSHOOK_FIX_STOP_QUEUE_TP_MUSICOS_FINAL__) return;
  window.__VSHOOK_FIX_STOP_QUEUE_TP_MUSICOS_FINAL__ = true;
  const esc = (v) => (typeof escapeHtml === 'function' ? escapeHtml(v) : String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])));
  const up = (v) => (typeof upperText === 'function' ? upperText(v) : String(v || '').toUpperCase());
  const originalFormatAppBlockLabel = typeof formatAppBlockLabel === 'function' ? formatAppBlockLabel : null;
  formatAppBlockLabel = function(item) {
    let label = originalFormatAppBlockLabel ? originalFormatAppBlockLabel(item) : String(item?.blockDisplayName || item?.blockName || item?.name || item?.label || 'BLOCO');
    label = String(label || '').replace(/\s*:\s*$/g, '').replace(/\s+:\s+/g, ' ').replace(/^:+\s*/g, '').trim();
    return up(label || 'BLOCO');
  };

  let tpProgressLastId = null;
  let tpProgressLastValue = 0;
  let tpProgressLastAt = 0;
  function findCurrentPlayingItemForTp() {
    const id = state && state.playingId != null ? String(state.playingId) : '';
    if (!id) return null;
    if (typeof findMusicosSongById === 'function') {
      const song = findMusicosSongById(id);
      if (song && !(typeof detectBlockItem === 'function' && detectBlockItem(song))) return song;
    }
    const lists = [];
    if (Array.isArray(state?.regions)) lists.push(state.regions);
    if (Array.isArray(state?.playlists)) {
      state.playlists.forEach(pl => { if (Array.isArray(pl?.songs)) lists.push(pl.songs); });
    }
    for (const list of lists) {
      const found = list.find(item => String(item?.id ?? item?.songId ?? '') === id);
      if (found && !(typeof detectBlockItem === 'function' && detectBlockItem(found))) return found;
    }
    return null;
  }
  function computeStableTpProgressPercent() {
    const id = state && state.playingId != null ? String(state.playingId) : '';
    if (!id) { tpProgressLastId = null; tpProgressLastValue = 0; return 0; }
    let ratio = 0;
    try {
      const item = findCurrentPlayingItemForTp();
      if (item) {
        const aware = (typeof getPlaybackAwareItem === 'function') ? getPlaybackAwareItem(item, true, false) : item;
        if (typeof getRowProgressRatio === 'function') ratio = Number(getRowProgressRatio(aware, true, false)) || 0;
      }
    } catch(e) { ratio = 0; }
    if (!Number.isFinite(ratio) || ratio <= 0) {
      try {
        const d = Number(state.playbackDurationSec || state.currentSongDurationSec || 0) || 0;
        const r = Number(state.playbackRemainingSec || state.currentSongRemainingSec);
        if (d > 0 && Number.isFinite(r)) ratio = Math.max(0, Math.min(1, (d - r) / d));
      } catch(e) {}
    }
    ratio = Math.max(0, Math.min(1, Number(ratio) || 0));
    const value = Math.round(ratio * 1000) / 10;
    const now = Date.now();
    if (tpProgressLastId !== id) {
      tpProgressLastId = id;
      tpProgressLastValue = value;
      tpProgressLastAt = now;
      return value;
    }
    // Durante reprodução, a barra não pode voltar/subir e descer a cada poll.
    const stable = Math.max(tpProgressLastValue || 0, value);
    tpProgressLastValue = stable;
    tpProgressLastAt = now;
    return stable;
  }
  window.__vshookMusicosTpProgressPercent = computeStableTpProgressPercent;
  const mediaAllowsText = (type) => { const t = String(type || 'text').toLowerCase().replace(/[\s-]+/g,'_'); return !t || t === 'text' || t === 'lyrics' || t === 'empty' || t === 'empty_item' || t === 'emptyitem' || t === 'text_plain' || t === 'text/plain'; };
  const tpTitle = () => String(state?.tp1SongName || state?.telepromptTp1SongName || state?.currentSongName || state?.playingSongName || state?.songName || 'TELEPROMPT 1').trim() || 'TELEPROMPT 1';
  const tpText = () => mediaAllowsText(state?.tp1MediaType || state?.telepromptTp1MediaType || 'text') ? String(state?.tp1LyricsText || state?.tp1Lyrics || state?.telepromptTp1Lyrics || state?.telepromptTp1Text || '').trim() : '';
  if (typeof renderMusicosLyricsPanel === 'function' || typeof renderLyricsPanel === 'function') {
    const renderFixedTpPanel = function(){
      if (!state.lyricsPanelOpen) return '';
      const title = up(tpTitle());
      const text = tpText() || 'SEM CONTEÚDO NO TP1';
      const progress = computeStableTpProgressPercent();
      return `<div class="lyricsScreen telepromptOnlyScreen musicosTp1OnlyScreen" style="--tp-text-color:${esc((window.__vshookMusicosTpColorFix12 && window.__vshookMusicosTpColorFix12()) || '#f8fafc')};--tp-font:${esc((window.__vshookMusicosTpFontFix12 && window.__vshookMusicosTpFontFix12()) || 'Inter, Arial, sans-serif')}">
        <div class="lyricsTopBar lyricsTopBarTpFix12">
          <div class="lyricsNowPlaying lyricsNowPlayingTpFix12">
            <div class="lyricsNowPlayingTitle lyricsNowPlayingTitleFix12" data-lyrics-title>${esc(title)}</div>
            <div class="lyricsProgressTrack lyricsProgressTrackFix12"><div class="lyricsProgressFill" data-lyrics-progress-fill style="width:${progress}%"></div></div>
          </div>
          <button class="lyricsBackButton lyricsBlueButton lyricsBackButtonFix12" data-action="close-lyrics-panel">&gt;&gt;</button>
        </div>
        <div class="lyricsBody lyricsBodyTpFix12"><div class="lyricsTextView tpLyricsTextFix12" data-lyrics-text-view data-lyrics-source="${esc(text)}">${typeof lyricsTextToHtml === 'function' ? lyricsTextToHtml(text) : esc(text)}</div></div>
      </div>`;
    };
    if (typeof renderMusicosLyricsPanel !== 'undefined') renderMusicosLyricsPanel = renderFixedTpPanel;
    if (typeof renderLyricsPanel !== 'undefined') renderLyricsPanel = renderFixedTpPanel;
  }
  const prevSyncMusicosLyricsPanelDom = typeof syncMusicosLyricsPanelDom === 'function' ? syncMusicosLyricsPanelDom : null;
  syncMusicosLyricsPanelDom = function(){
    try { if (prevSyncMusicosLyricsPanelDom) prevSyncMusicosLyricsPanelDom(); } catch(e) {}
    if (!state.lyricsPanelOpen) return;
    const fill = document.querySelector('[data-lyrics-progress-fill]');
    if (fill) fill.style.width = `${computeStableTpProgressPercent()}%`;
    const titleNode = document.querySelector('[data-lyrics-title]');
    const title = up(tpTitle());
    if (titleNode && titleNode.textContent !== title) titleNode.textContent = title;
    const textNode = document.querySelector('[data-lyrics-text-view]');
    const nextText = tpText() || 'SEM CONTEÚDO NO TP1';
    if (textNode && textNode.getAttribute('data-lyrics-source') !== nextText) {
      textNode.setAttribute('data-lyrics-source', nextText);
      textNode.innerHTML = typeof lyricsTextToHtml === 'function' ? lyricsTextToHtml(nextText) : esc(nextText);
    }
  };
  setInterval(() => { try { syncMusicosLyricsPanelDom(); } catch(e) {} }, 500);
})();


/* VS_HOOK_FIX_MUSICOS_BLOCK_LABEL_SAME_AS_DIRETOR_FINAL
   App dos Músicos usa a mesma limpeza visual dos blocos do repertório do Diretor: sem :, sem ====, sem wrappers. */
(function(){
  if (window.__VSHOOK_MUSICOS_BLOCK_LABEL_SAME_AS_DIRETOR_FINAL__) return;
  window.__VSHOOK_MUSICOS_BLOCK_LABEL_SAME_AS_DIRETOR_FINAL__ = true;

  function _up(v){
    try { return typeof upperText === 'function' ? upperText(v) : String(v || '').toLocaleUpperCase('pt-BR'); }
    catch(e){ return String(v || '').toUpperCase(); }
  }

  function _fallbackSuffix(item){
    try {
      if (typeof getBlockFallbackSuffix === 'function') return getBlockFallbackSuffix(item);
      const n = Math.abs(Number(item && (item.source_number ?? item.sourceNumber ?? item.id) || 1)) || 1;
      return String(n).padStart(2, '0');
    } catch(e) { return '01'; }
  }

  function _stripBlockDecor(text){
    let t = _up(text).trim();
    // remove qualquer decoração repetida nas pontas: :::: BLOCO X :::: / ==== BLOCO X ==== / ---- BLOCO X ----
    t = t.replace(/^[=:\-\s]+/g, '').replace(/[=:\-\s]+$/g, '').trim();
    // remove separadores soltos depois de BLOCO: BLOCO: X / BLOCO - X / BLOCO = X
    t = t.replace(/^BLOCO\s*[=:\-]+\s*/i, 'BLOCO ');
    // remove ':' que tenha sobrado no começo/fim depois da primeira limpeza
    t = t.replace(/^:+/g, '').replace(/:+$/g, '').trim();
    // troca sequências internas de dois-pontos decorativos por espaço, sem destruir nomes normais
    t = t.replace(/\s*:{2,}\s*/g, ' ').trim();
    return t;
  }

  formatAppBlockLabel = function(item){
    const rawCandidate = String((item && (item.blockDisplayName || item.blockName || item.name || item.label)) || '').trim();
    const customCandidate = String((item && item.blockCustomName) || '').trim();
    const raw = customCandidate || rawCandidate || 'BLOCO';
    let clean = _stripBlockDecor(raw);

    if (!clean) clean = 'BLOCO';

    // Se veio BLOCO decorado, normaliza igual ao Diretor: BLOCO + sufixo/nome, sem pontuação.
    if (/^BLOCO(?:\s+|$)/i.test(clean)) {
      let suffix = clean.replace(/^BLOCO\s*/i, '').trim();
      suffix = _stripBlockDecor(suffix);
      if (!suffix || suffix === 'BLOCO') suffix = _fallbackSuffix(item);
      return _up('BLOCO ' + suffix);
    }

    // Se for nome customizado do bloco, exibe o nome limpo, igual o Diretor.
    return _up(clean);
  };

  if (typeof renderApp === 'function') {
    try { renderApp(); } catch(e) {}
  }
})();


/* VS_HOOK_FIX_MUSICOS_TIMER_REGRESSIVO_LOCAL_FINAL */
(function(){
  if (window.__VSHOOK_FIX_MUSICOS_TIMER_REGRESSIVO_LOCAL_FINAL__) return;
  window.__VSHOOK_FIX_MUSICOS_TIMER_REGRESSIVO_LOCAL_FINAL__ = true;

  function mode(value){
    try { return normalizeMusicosTimerMode(value); } catch(e) {
      const m = String(value || '').trim().toLowerCase().replace(/[\s-]+/g, '_');
      if (m === 'regressivo' || m === 'regressive' || m === 'countdown') return 'countdown';
      if (m === 'local' || m === 'local_time' || m === 'horario_local' || m === 'hora_local') return 'local_time';
      return 'progressive';
    }
  }

  const oldSync = typeof syncFromBridge === 'function' ? syncFromBridge : null;
  if (oldSync && !oldSync.__vshookMusicosTimerFinalWrapped) {
    syncFromBridge = function(data){
      const result = oldSync(data);
      try {
        if (data && typeof data === 'object') {
          const hasTimer = Object.prototype.hasOwnProperty.call(data, 'timerMode') ||
            Object.prototype.hasOwnProperty.call(data, 'timerType') ||
            Object.prototype.hasOwnProperty.call(data, 'timerTargetSec') ||
            Object.prototype.hasOwnProperty.call(data, 'timerCountdownStartSec') ||
            Object.prototype.hasOwnProperty.call(data, 'timerDisplaySec') ||
            Object.prototype.hasOwnProperty.call(data, 'timerDisplayText') ||
            Object.prototype.hasOwnProperty.call(data, 'timerLocalTimeText') ||
            Object.prototype.hasOwnProperty.call(data, 'timerRunning') ||
            Object.prototype.hasOwnProperty.call(data, 'timerStartedAt') ||
            Object.prototype.hasOwnProperty.call(data, 'timerStartedAtMs') ||
            Object.prototype.hasOwnProperty.call(data, 'timerAccumulatedSec');
          if (hasTimer) {
            state.timerMode = mode(data.timerMode || data.timerType || state.timerMode || 'progressive');
            if (Object.prototype.hasOwnProperty.call(data, 'timerRunning')) state.timerRunning = !!data.timerRunning;
            const started = Number(data.timerStartedAt || data.timerStartedAtMs);
            if (Number.isFinite(started)) { state.timerStartedAt = started; state.timerStartedAtMs = started; }
            const accum = Number(data.timerAccumulatedSec);
            if (Number.isFinite(accum)) state.timerAccumulatedSec = Math.max(0, accum);
            const target = Number(data.timerTargetSec ?? data.timerCountdownStartSec);
            if (Number.isFinite(target)) state.timerTargetSec = Math.max(0, target);
            const display = Number(data.timerDisplaySec);
            if (Number.isFinite(display)) state.timerDisplaySec = Math.max(0, display);
            else if (state.timerMode === 'countdown' && !state.timerRunning) state.timerDisplaySec = Math.max(0, Number(state.timerTargetSec) || 0);
            state.timerDisplayText = String(data.timerDisplayText || state.timerDisplayText || '');
            state.timerLocalTimeText = String(data.timerLocalTimeText || state.timerLocalTimeText || '');
            state.timerTriggerSeq = Number(data.timerTriggerSeq || state.timerTriggerSeq || 0) || 0;
            try { syncChronoDom?.(); } catch(e) {}
          }
        }
      } catch(e) {}
      return result;
    };
    syncFromBridge.__vshookMusicosTimerFinalWrapped = true;
  }

  if (typeof syncChronoDom === 'function' && !syncChronoDom.__vshookMusicosTimerFinalWrapped) {
    syncChronoDom = function(){
      const text = (typeof getMusicosChronoDisplayText === 'function') ? getMusicosChronoDisplayText() : formatChronoTime(getChronoElapsedSeconds());
      document.querySelectorAll('[data-chrono-display]').forEach((node) => { if (node.textContent !== text) node.textContent = text; });
      document.querySelectorAll('.topTimerButtonMusicos').forEach((node) => {
        if (mode(state.timerMode) === 'local_time' || !!state.timerRunning) node.classList.add('topTimerButtonRunning');
        else node.classList.remove('topTimerButtonRunning');
      });
    };
    syncChronoDom.__vshookMusicosTimerFinalWrapped = true;
  }
})();
