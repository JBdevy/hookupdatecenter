(() => {
  'use strict'

  const VERSION = '1.0.0-native-extension-shared-control-v20'
  const POLL_MS = 300
  const METER_POLL_MS = 80
  const NOTICE_POLL_MS = 450
  const HEARTBEAT_MS = 4500
  const COMMAND_TIMEOUT_MS = 2600
  const POLL_TIMEOUT_MS = 2200
  const RECADO_IMAGE_UPLOAD_TIMEOUT_MS = 60000
  const TAP_DEDUPE_MS = 180
  const DIRECTOR_VISUAL_FRAME_MS = 25

  const root = document.getElementById('app') || document.body
  try {
    const userAgent = navigator.userAgent || ''
    const iPadDesktopMode = navigator.platform === 'MacIntel' && Number(navigator.maxTouchPoints || 0) > 1
    if (/Android/i.test(userAgent)) document.documentElement.dataset.directorPlatform = 'android'
    else if (/iPad|iPhone|iPod/i.test(userAgent) || iPadDesktopMode) document.documentElement.dataset.directorPlatform = 'ios'
  } catch (_) {}
  const APP_MODE = (() => { try { return String(localStorage.getItem('vshook_selected_mode') || 'director') } catch (_) { return 'director' } })()
  const IS_MUSICIAN_MONITOR = APP_MODE === 'musician'
  let bridgePollTimer = 0
  let meterPollTimer = 0
  let technicalNoticeTimer = 0
  let directorRenderTimer = 0
  let directorProgressAnimationFrame = 0
  let directorProgressLastPaintAt = 0
  const directorTpMediaWarmups = new Map()
  const directorTpVideoSyncStates = new WeakMap()
  let interfaceAccessButtonTimer = 0
  let liveMarkIndexSnapshot = null
  let liveMarkIndex = null

  const state = {
    snapshot: null,
    bridgeOnline: false,
    lastPollAt: 0,
    lastGoodAt: 0,
    pollInFlight: false,
    technicalNoticePollInFlight: false,
    technicalNoticeSnapshot: null,
    technicalNoticeSnapshotReady: false,
    technicalNoticeServerOffsetMs: 0,
    technicalNoticeLastGoodAt: 0,
    activeTab: 'playlist',
    mixerView: 'tracks',
    premixView: 'songs',
    premixTrackView: 'tracks',
    selectedPlaylistSongId: '',
    selectedRegionId: '',
    selectedMarkerId: '',
    markerSelectionClearedUntil: 0,
    selectedPremixSongId: '',
    queuedSongId: '',
    queuedManualVisualId: '',
    queuedSongLocalUntil: 0,
    sharedSelectionLocalUntil: 0,
    activeTabLocalUntil: 0,
    sharedControlsLocalUntil: 0,
    optimisticQueueClearedUntil: 0,
    optimisticPlayingId: '',
    optimisticPlayingUntil: 0,
    optimisticStoppedId: '',
    optimisticStoppedTab: '',
    optimisticStoppedUntil: 0,
    pendingTransportPlaying: null,
    pendingTransportPlayingUntil: 0,
    pendingAutoplay: null,
    pendingAutoplayMode: null,
    pendingAutoplayUntil: 0,
    pendingAutoBloco: null,
    pendingAutoBlocoUntil: 0,
    pendingAutoStop: null,
    pendingAutoStopUntil: 0,
    pendingStopPauseMode: null,
    pendingStopPauseModeUntil: 0,
    pendingStopPauseModeRequestToken: 0,
    pendingLive: null,
    pendingLiveUntil: 0,
    pendingPreviewMode: null,
    pendingPreviewUntil: 0,
    tabletPreviewPage: 0,
    meterPollInFlight: false,
    meterSnapshot: null,
    authAuthenticated: false,
    authPass: '',
    authError: '',
    pcAccessReleased: false,
    directorSessionAnnounced: false,
    directorClaimInFlight: false,
    lastDirectorLogoutSignature: '',
    showPassword: false,
    showPlaylistModal: false,
    showProjectModal: false,
    showMarkersOverlay: readLocal('vshook_director_parts_open', '0') === '1',
    optimisticActivePlaylistId: '',
    optimisticActivePlaylistName: '',
    optimisticActivePlaylistUntil: 0,
    pendingMultiProjectPlaylists: null,
    showMenu: false,
    showTimerModal: false,
    showSettingsModal: false,
    pendingInterfaceBlocking: null,
    hideInterfaceAccessNotification: readLocal('vshook_hide_interface_access_notification', '0') === '1',
    lastBlockedInterfaceAttemptRevision: null,
    lastProjectPlaylistSwitchBlockedRevision: null,
    showTelepromptColorPalette: false,
    numberOrderConfirmKind: '',
    numberOrderConfirmContext: 'playlist',
    numberOrderConfirmUseRegionId: false,
    numberOrderConfirmDescending: false,
    showTunerScreen: readLocal('vshook_director_tuner_open', '0') === '1',
    showTelepromptScreen: false,
    showRecadosScreen: false,
    recadosDraft: '',
    recadosGlobalDraft: '',
    recadosSelectedSlot: 'global',
    recadosTemplates: ['', '', ''],
    recadosTemplateImages: ['', '', ''],
    recadosEditingTemplate: false,
    recadosStatus: '',
    recadosSending: false,
    recadosNoticeExpiresAt: 0,
    recadosNoticeId: '',
    recadosNoticeRemainingMs: 0,
    recadosPinned: false,
    recadosTextFocused: false,
    showPremixScreen: false,
    showTabletSongToolsModal: false,
    tabletSongToolsChoice: 'premix',
    tabletSongToolsTarget: null,
    showTabletMultiLoopsModal: false,
    tabletMultiLoopTracksSlot: 0,
    tabletMultiLoopTracksScrollBySlot: { 1: 0, 2: 0 },
    tabletMultiLoopAutoLimitTarget: null,
    tabletMultiLoopAutoLimitTimer: 0,
    showTabletLiveResetConfirm: false,
    premixSourceTab: 'playlist',
    premixSongId: '',
    premixSongName: '',
    premixSongStart: 0,
    premixSongEnd: 0,
    premixPlaySongId: '',
    premixPlaySongName: '',
    premixPlaySongStart: 0,
    premixPlaySongEnd: 0,
    premixPlayMarkerNumber: 0,
    premixPlayMarkerEnumIndex: -1,
    telepromptSlot: readLocal('vshook_director_teleprompt_slot', '1') === '2' ? 2 : 1,
    tunerSourceTab: 'playlist',
    tunerOptimisticValues: {},
    hashRegionDrawers: readJsonLocal('vshook_director_hash_drawers', {}),
    hashRegionDrawerChildren: {},
    hashRegionDrawerPendingId: '',
    showMixerVolume: false,
    mixerVolumeTarget: null,
    showPremixVolume: false,
    premixVolumeTarget: null,
    showConfirmLiveOff: false,
    showConfirmTimerStop: false,
    showPlaylistCopyChildrenConfirm: false,
    playlistCopyPendingId: '',
    popupText: '',
    popupKind: 'info',
    popupUntil: 0,
    renderScheduled: false,
    renderForceRequested: false,
    wakeLock: null,
    wakeLockRequesting: false,
    lastHtmlSignature: '',
    lastTapKey: '',
    lastTapAt: 0,
    ignoreTapUntil: 0,
    lastProtectedPlayTapAt: 0,
    lastProtectedPlayMode: '',
    optimisticTimerMode: '',
    optimisticTimerModeUntil: 0,
    timerLocal: {
      initialized: false,
      running: false,
      mode: 'progressive',
      baseSec: 0,
      targetSec: 0,
      startedAtMs: 0,
      displaySec: 0,
      signature: '',
    },
    timerLocalIgnoreBridgeUntil: 0,
    partsLocalSelectedMarkerId: '',
    partsArmedMarkerId: '',
    partsArmedMarkerUntil: 0,
    partsMarkerSongSource: 'playing',
    partsArmedOwnerSongId: '',
    partsArmedOwnerTab: '',
    partsArmedOwnerStart: null,
    partsArmedOwnerEnd: null,
    partsTakeoverSongId: '',
    partsTakeoverTab: '',
    partsTakeoverPreviousPlayingId: '',
    partsLastPlayingId: '',
    showTransportSeekModal: readLocal('vshook_director_grid_open', '0') === '1',
    tabletTransportOpening: false,
    tabletPlaylistPendingId: '',
    tabletPartsSplit: readLocal('vshook_director_tablet_parts_open', '0') === '1',
    tabletTunerSplit: readLocal('vshook_director_tablet_tuner_open', '0') === '1',
    tabletMixerReturnTab: 'playlist',
    showTabletSearch: false,
    tabletSearchQuery: '',
    tabletSearchPendingFocus: null,
    tabletSearchViewportSnapshot: null,
    tabletSearchViewportRestoreTimer: 0,
    showTabletPlayHoldModal: false,
    tabletFadeoutEnabled: false,
    tabletFadeoutSeconds: 1,
    tabletFadeoutTracksOpen: false,
    tabletFadeoutPendingUntil: 0,
    tabletFadeoutTrackPendingUntil: 0,
    tabletFadeoutSelectedTrackIds: [],
    tabletFadeoutRuntimeActive: false,
    tabletFadeoutRuntimePendingUntil: 0,
    tabletFadeoutRuntimePendingState: null,
    tabletFadeoutProgress: 0,
    tabletFadeoutVisualAnchorProgress: 0,
    tabletFadeoutVisualAnchorAt: 0,
    transportSeekSongId: '',
    transportSeekSongName: '',
    transportSeekSongStart: 0,
    transportSeekSongEnd: 0,
    transportSeekSongTab: 'regions',
    transportSeekSongSource: 'playing',
    transportSeekDisplayDuration: 0,
    transportSeekMarkerNumber: 0,
    transportSeekMarkerEnumIndex: -1,
    transportSeekExplicitTarget: false,
    transportSeekCursorPos: 0,
    transportSeekDragging: false,
    transportSeekPlayVisualHoldPos: null,
    transportSeekPlayVisualHoldUntil: 0,
    transportSeekPendingPlaying: null,
    transportSeekPendingPlayingUntil: 0,
    transportSeekPauseVisualHoldPos: null,
    transportSeekPauseVisualHoldUntil: 0,
    topPlaylistTickerTitle: '',
    topPlaylistTickerStartedAt: 0,
    pendingLoop: null,
    pendingLoopUntil: 0,
    pendingMultiLoopBypass: null,
    pendingMultiLoopBypassUntil: 0,
    tabletMultiLoopBypassWarningKey: '',
    tabletMultiLoopBypassWarningLastPosition: null,
    tabletPartCountdownKey: '',
    tabletPartCountdownLastPosition: null,
    playlistSelectionClearedUntil: 0,
    regionSelectionClearedUntil: 0,
    playlistSelectionLocalUntil: 0,
    regionSelectionLocalUntil: 0,
    directorSelectionScrollPending: null,
  }

  const mixerToggleHold = new Map()
  const mixerVolumeHold = new Map()
  const premixItemMuteHold = new Map()
  const premixItemVolumeHold = new Map()
  let nativeFamilyDrawersLastSignature = null
  let nativeFamilyDrawersLastAppliedRevision = ''

  function now() { return Date.now() }

  function escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
  }

  function upperText(value) { return String(value ?? '').trim().toUpperCase() }

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

  function readLocal(key, fallback = '') {
    try { return localStorage.getItem(key) ?? fallback } catch (_) { return fallback }
  }

  function writeLocal(key, value) {
    try { localStorage.setItem(key, String(value ?? '')) } catch (_) {}
  }

  function removeLocal(key) {
    try { localStorage.removeItem(key) } catch (_) {}
  }

  function readJsonLocal(key, fallback) {
    try {
      const parsed = JSON.parse(readLocal(key, ''))
      return parsed && typeof parsed === 'object' ? parsed : fallback
    } catch (_) { return fallback }
  }

  function persistDirectorPanelState() {
    const openDrawers = {}
    for (const key of Object.keys(state.hashRegionDrawers || {})) {
      if (state.hashRegionDrawers[key]) openDrawers[key] = true
    }
    writeLocal('vshook_director_hash_drawers', JSON.stringify(openDrawers))
    writeLocal('vshook_director_grid_open', state.showTransportSeekModal ? '1' : '0')
    writeLocal('vshook_director_parts_open', state.showMarkersOverlay ? '1' : '0')
    writeLocal('vshook_director_tuner_open', state.showTunerScreen ? '1' : '0')
    writeLocal('vshook_director_tablet_parts_open', state.tabletPartsSplit ? '1' : '0')
    writeLocal('vshook_director_tablet_tuner_open', state.tabletTunerSplit ? '1' : '0')
    syncNativeFamilyDrawers()
  }

  function syncNativeFamilyDrawers(force = false) {
    if (!state.authAuthenticated || state.pcAccessReleased) return
    const openDrawerIds = Object.keys(state.hashRegionDrawers || {})
      .filter((key) => state.hashRegionDrawers[key])
      .sort()
      .join('|')
    if (!force && openDrawerIds === nativeFamilyDrawersLastSignature) return
    nativeFamilyDrawersLastSignature = openDrawerIds
    postCommand('director_family_drawers_sync', { openDrawerIds }).then((response) => {
      if (!response?.ok && nativeFamilyDrawersLastSignature === openDrawerIds) {
        nativeFamilyDrawersLastSignature = null
      }
    })
  }

  function syncFamilyDrawersFromBridge(data = state.snapshot) {
    const revision = String(data?.familyDrawerRevision ?? '')
    if (!revision || revision === nativeFamilyDrawersLastAppliedRevision) return false

    const rawIds = data?.openDrawerIds ?? data?.familyDrawerOpenIds ?? ''
    const ids = (Array.isArray(rawIds) ? rawIds : String(rawIds || '').split('|'))
      .map((value) => String(value || '').trim())
      .filter(Boolean)
    const next = {}
    for (const id of ids) next[id] = true
    state.hashRegionDrawers = next
    state.hashRegionDrawerChildren = {}
    nativeFamilyDrawersLastAppliedRevision = revision
    nativeFamilyDrawersLastSignature = ids.slice().sort().join('|')
    writeLocal('vshook_director_hash_drawers', JSON.stringify(next))
    return true
  }

  function getHashDrawersRenderSignature() {
    return Object.keys(state.hashRegionDrawers || {}).sort().map((key) => {
      const children = state.hashRegionDrawerChildren[key]
      return `${key}:${state.hashRegionDrawers[key] ? 1 : 0}:${Array.isArray(children) ? children.length : 0}`
    }).join('|')
  }

  function getAppTheme() {
    return readLocal('vshook_director_theme', 'dark') === 'light' ? 'light' : 'dark'
  }

  function getDrawerVisualStyle(data = state.snapshot) {
    const colors = {
      yellow: '#fff02e', green: '#1aff57', blue: '#3394ff', purple: '#b852ff',
      red: '#ff382e', orange: '#ff8514', cyan: '#1febff', white: '#ebf2ff', gray: '#8f99a8', grey: '#8f99a8'
    }
    const outlineName = String(data?.drawerOutlineColor || 'yellow').toLowerCase()
    const symbolName = String(data?.drawerSymbolColor || 'yellow').toLowerCase()
    return {
      outlineEnabled: data?.drawerOutlineEnabled !== false,
      symbolEnabled: data?.drawerSymbolEnabled !== false,
      outlineColor: colors[outlineName] || colors.yellow,
      symbolColor: colors[symbolName] || colors.yellow
    }
  }

  function getBlockSymbolVisualStyle(data = state.snapshot) {
    const colors = {
      yellow: '#fff02e', green: '#1aff57', blue: '#3394ff', purple: '#b852ff',
      red: '#ff382e', orange: '#ff8514', cyan: '#1febff', white: '#ebf2ff',
      gray: '#8f99a8', grey: '#8f99a8'
    }
    const allowed = new Set([
      'none', 'colon', 'angle', 'equal',
      'dash', 'diamond', 'spark', 'capsule'
    ])
    const rawMode = String(data?.blockSymbolMode ?? data?.block_symbol_mode ?? 'none').toLowerCase()
    const mode = allowed.has(rawMode) ? rawMode : 'none'
    const colorName = String(data?.blockSymbolColor ?? data?.block_symbol_color ?? 'yellow').toLowerCase()
    return {
      mode,
      color: colors[colorName] || colors.yellow
    }
  }

  function getNoBlockTextColor(data = state.snapshot) {
    const colors = {
      yellow: '#fff02e', green: '#1aff57', blue: '#3394ff', purple: '#b852ff',
      red: '#ff382e', orange: '#ff8514', cyan: '#1febff', white: '#ebf2ff',
      gray: '#8f99a8', grey: '#8f99a8'
    }
    const mode = String(
      data?.noBlockTextColorMode
      ?? data?.noBlockTextColor
      ?? data?.no_block_text_color_mode
      ?? 'none'
    ).trim().toLowerCase()
    return mode === 'none' ? '' : (colors[mode] || '')
  }

  function getLiveMarkVisualStyle(data = state.snapshot) {
    const colors = {
      yellow: { background: '#d8cd2f', border: '#fff02e' },
      green: { background: '#1dd951', border: '#1aff57' },
      blue: { background: '#3182da', border: '#3394ff' },
      purple: { background: '#9e4cda', border: '#b852ff' },
      red: { background: '#991b1b', border: '#ff382e' },
      orange: { background: '#d8751a', border: '#ff8514' },
      cyan: { background: '#21c9da', border: '#1febff' },
      white: { background: '#c8cfda', border: '#ebf2ff' },
      gray: { background: '#7d8693', border: '#8f99a8' },
      grey: { background: '#7d8693', border: '#8f99a8' }
    }
    const rawMode = String(
      data?.liveMarkColorMode ?? data?.liveMarkColor ??
      data?.live_mark_color_mode ?? 'gray'
    ).trim().toLowerCase()
    const mode = Object.prototype.hasOwnProperty.call(colors, rawMode)
      ? (rawMode === 'grey' ? 'gray' : rawMode)
      : 'gray'
    const fallback = colors[mode]
    const validHex = (value) => /^#[0-9a-f]{6}$/i.test(String(value || '').trim())
    const publishedBackground =
      data?.liveMarkBackgroundHex ?? data?.live_mark_background_hex
    const publishedBorder =
      data?.liveMarkBorderHex ?? data?.live_mark_border_hex
    const background = validHex(publishedBackground)
      ? String(publishedBackground).trim()
      : fallback.background
    const border = validHex(publishedBorder)
      ? String(publishedBorder).trim()
      : fallback.border
    return {
      mode,
      background,
      border,
      shadow: `${border}57`
    }
  }

  function getFamilyViewControlsEnabled(data = state.snapshot) {
    if (typeof data?.familyViewControlsEnabled === 'boolean') {
      return data.familyViewControlsEnabled
    }
    return false
  }

  function setAppTheme(theme) {
    const normalized = theme === 'light' ? 'light' : 'dark'
    writeLocal('vshook_director_theme', normalized)
    const app = root.querySelector('.app')
    if (!app) {
      scheduleRender(true)
      return
    }
    app.setAttribute('data-theme', normalized)
    root.querySelectorAll('[data-action="theme-light"],[data-action="theme-dark"]').forEach((button) => {
      const active = button.getAttribute('data-action') === `theme-${normalized}`
      button.classList.toggle('btnAutoplayActive', active)
      button.classList.toggle('btn', !active)
    })
  }

  const TELEPROMPT_FONT_OPTIONS = [
    { id: 'system', label: 'PADRÃO' },
    { id: 'arial', label: 'ARIAL' },
    { id: 'serif', label: 'SERIF' },
    { id: 'mono', label: 'MONO' },
  ]

  const TELEPROMPT_COLOR_OPTIONS = [
    { id: 'white', label: 'BRANCO', color: '#ffffff' },
    { id: 'yellow', label: 'AMARELO', color: '#fde047' },
    { id: 'cyan', label: 'CIANO', color: '#67e8f9' },
    { id: 'green', label: 'VERDE', color: '#86efac' },
    { id: 'red', label: 'VERMELHO', color: '#f87171' },
    { id: 'orange', label: 'LARANJA', color: '#fb923c' },
    { id: 'gold', label: 'DOURADO', color: '#fbbf24' },
    { id: 'lime', label: 'LIMÃO', color: '#bef264' },
    { id: 'turquoise', label: 'TURQUESA', color: '#2dd4bf' },
    { id: 'blue', label: 'AZUL', color: '#60a5fa' },
    { id: 'indigo', label: 'ÍNDIGO', color: '#818cf8' },
    { id: 'purple', label: 'ROXO', color: '#c084fc' },
    { id: 'pink', label: 'ROSA', color: '#f472b6' },
    { id: 'coral', label: 'CORAL', color: '#fb7185' },
    { id: 'silver', label: 'PRATA', color: '#cbd5e1' },
    { id: 'black', label: 'PRETO', color: '#000000' },
  ]

  function getTelepromptPreferenceKey(name) {
    return `vshook_${IS_MUSICIAN_MONITOR ? 'musician' : 'director'}_teleprompt_${name}`
  }

  function normalizeTelepromptFont(value) {
    const normalized = String(value || '').trim().toLowerCase()
    return TELEPROMPT_FONT_OPTIONS.some((option) => option.id === normalized) ? normalized : 'system'
  }

  function normalizeTelepromptColor(value) {
    const normalized = String(value || '').trim().toLowerCase()
    return TELEPROMPT_COLOR_OPTIONS.some((option) => option.id === normalized) ? normalized : 'white'
  }

  function getTelepromptFont() {
    return normalizeTelepromptFont(readLocal(getTelepromptPreferenceKey('font'), 'system'))
  }

  function getTelepromptColor() {
    return normalizeTelepromptColor(readLocal(getTelepromptPreferenceKey('text_color'), 'white'))
  }

  function getTelepromptColorValue(value = getTelepromptColor()) {
    return TELEPROMPT_COLOR_OPTIONS.find((option) => option.id === normalizeTelepromptColor(value))?.color || '#ffffff'
  }

  function syncTelepromptAppearanceDom() {
    const font = getTelepromptFont()
    const color = getTelepromptColor()
    const app = root.querySelector('.app')
    if (app) {
      app.setAttribute('data-teleprompt-font', font)
      app.setAttribute('data-teleprompt-color', color)
      app.style.setProperty('--teleprompt-text-color', getTelepromptColorValue(color))
    }
    root.querySelectorAll('[data-action="teleprompt-font-set"]').forEach((button) => {
      button.classList.toggle('telepromptSettingsOptionActive', button.getAttribute('data-value') === font)
    })
    root.querySelectorAll('[data-action="teleprompt-color-set"]').forEach((button) => {
      button.classList.toggle('telepromptSettingsOptionActive', button.getAttribute('data-value') === color)
    })
  }

  function setTelepromptFont(value) {
    writeLocal(getTelepromptPreferenceKey('font'), normalizeTelepromptFont(value))
    syncTelepromptAppearanceDom()
  }

  function setTelepromptColor(value) {
    writeLocal(getTelepromptPreferenceKey('text_color'), normalizeTelepromptColor(value))
    syncTelepromptAppearanceDom()
  }

  function toggleTelepromptColorPalette() {
    state.showTelepromptColorPalette = !state.showTelepromptColorPalette
    const button = root.querySelector('[data-action="teleprompt-colors-more"]')
    const palette = root.querySelector('[data-teleprompt-extra-colors]')
    button?.classList.toggle('telepromptMoreColorsButtonActive', state.showTelepromptColorPalette)
    button?.setAttribute('aria-expanded', state.showTelepromptColorPalette ? 'true' : 'false')
    palette?.classList.toggle('telepromptExtraColorsGridHidden', !state.showTelepromptColorPalette)
  }

  const BORDER_COLOR_SEQUENCE = [
    { id: 'fixed-yellow', label: 'FIXA: AMARELO', color: '#facc15' },
    { id: 'fixed-green', label: 'FIXA: VERDE', color: '#22c55e' },
    { id: 'fixed-blue', label: 'FIXA: AZUL', color: '#3b82f6' },
    { id: 'fixed-purple', label: 'FIXA: ROXO', color: '#8b5cf6' },
    { id: 'fixed-pink', label: 'FIXA: ROSA', color: '#ec4899' },
    { id: 'fixed-red', label: 'FIXA: VERMELHO', color: '#ef4444' },
    { id: 'fixed-white', label: 'FIXA: BRANCO', color: '#ffffff' },
    { id: 'rgb-slow', label: 'RGB LENTO', color: '#facc15' },
    { id: 'rgb-mid', label: 'RGB MEIO RÁPIDO', color: '#facc15' },
    { id: 'rgb-super', label: 'RGB SUPER RÁPIDO', color: '#facc15' },
    { id: 'off', label: 'DESLIGADO', color: '#111827' },
  ]

  function normalizeBorderColorMode(value) {
    const saved = String(value || '').trim()
    if (saved === 'fixed') return 'fixed-yellow'
    return BORDER_COLOR_SEQUENCE.some((item) => item.id === saved) ? saved : 'fixed-yellow'
  }

  function getBorderColorMode() {
    return normalizeBorderColorMode(readLocal('vshook_director_border_color_mode', 'fixed-yellow'))
  }

  function getBorderColorOption(mode = getBorderColorMode()) {
    const normalized = normalizeBorderColorMode(mode)
    return BORDER_COLOR_SEQUENCE.find((item) => item.id === normalized) || BORDER_COLOR_SEQUENCE[0]
  }

  function getBorderColorModeLabel(mode = getBorderColorMode()) {
    const label = String(getBorderColorOption(mode).label || '')
      .replace(/^FIXA:\s*/i, '')
    return `Cor da borda - ${label}`
  }

  function getBorderColorValue(mode = getBorderColorMode()) {
    return getBorderColorOption(mode).color
  }

  function getBorderColorGlow(mode = getBorderColorMode()) {
    const normalized = normalizeBorderColorMode(mode)
    if (normalized === 'off') return 'transparent'
    const color = getBorderColorValue(normalized)
    return /^#[0-9a-fA-F]{6}$/.test(color) ? `${color}55` : 'rgba(250,204,21,.34)'
  }

  function toggleBorderColorMode() {
    const current = getBorderColorMode()
    const index = BORDER_COLOR_SEQUENCE.findIndex((item) => item.id === current)
    const next = BORDER_COLOR_SEQUENCE[(Math.max(0, index) + 1) % BORDER_COLOR_SEQUENCE.length].id
    writeLocal('vshook_director_border_color_mode', next)
    showPopup(getBorderColorModeLabel(next), next === 'off' ? 'info' : 'success', 1000)
    scheduleRender(true)
  }

  function getNumberColumnMode() {
    return readLocal('vshook_director_number_mode', 'order') === 'region' ? 'region' : 'order'
  }

  function numberColumnUsesRegionId() {
    return getNumberColumnMode() === 'region'
  }

  function toggleNumberColumnMode() {
    state.numberOrderConfirmKind = 'number'
    state.numberOrderConfirmContext = getNumberOrderContext()
    state.numberOrderConfirmUseRegionId = !numberColumnUsesRegionId()
    state.numberOrderConfirmDescending = false
    scheduleRender(true)
  }

  function getNumberOrderContext() {
    if (state.showTunerScreen) return state.tunerSourceTab === 'regions' ? 'regions' : 'playlist'
    return state.activeTab === 'regions' ? 'regions' : 'playlist'
  }

  function getNumberOrderItems(context = getNumberOrderContext()) {
    const source = context === 'regions' ? getRegions(state.snapshot) : getPlaylistItems(state.snapshot)
    const visible = context === 'regions' ? getNumberSortedItems(source, 'region') : source.slice()
    return context === 'regions' ? visible : visible.filter((item) => !isBlock(item))
  }

  function getNumberOrderState(context = getNumberOrderContext()) {
    const items = getNumberOrderItems(context)
    if (items.length <= 1) return 'none'
    let ascending = true
    let descending = true
    let previous = getRegionNumberValue(items[0]) ?? 1
    for (let index = 1; index < items.length; index += 1) {
      const value = getRegionNumberValue(items[index]) ?? index + 1
      if (value < previous) ascending = false
      if (value > previous) descending = false
      previous = value
    }
    if (ascending) return 'asc'
    if (descending) return 'desc'
    return 'mixed'
  }

  // Igual ao Lua: se a ordem atual é 0-9, o próximo clique propõe 9-0.
  // Em qualquer outro estado, o próximo clique propõe 0-9.
  function getNumberSortDirection() {
    return getNumberOrderState() === 'asc' ? 'desc' : 'asc'
  }

  function getAppliedNumberSortDirection() {
    const value = readLocal('vshook_director_number_sort_applied', '')
    return value === 'asc' || value === 'desc' ? value : ''
  }

  function toggleNumberSortDirection() {
    if (!numberColumnUsesRegionId()) {
      showPopup('0-9 SÓ FUNCIONA COM NUMBER EM ID DA REGIÃO', 'error', 1800)
      return
    }
    const context = getNumberOrderContext()
    if (getNumberOrderItems(context).length <= 1) return
    state.numberOrderConfirmKind = 'sort'
    state.numberOrderConfirmContext = context
    state.numberOrderConfirmUseRegionId = true
    state.numberOrderConfirmDescending = getNumberOrderState(context) === 'asc'
    scheduleRender(true)
  }

  function closeNumberOrderConfirm() {
    state.numberOrderConfirmKind = ''
    state.numberOrderConfirmContext = 'playlist'
    state.numberOrderConfirmUseRegionId = false
    state.numberOrderConfirmDescending = false
    scheduleRender(true)
  }

  function applyNumberOrderSort(context, descending) {
    const direction = descending ? 'desc' : 'asc'
    if (context === 'playlist') {
      removeLocal('vshook_director_number_sort_applied')
      postCommand('sort_playlist_by_number', {
        direction,
        descending,
        activeTab: 'playlist',
        page: 'playlist',
      }).then((response) => {
        if (!response?.ok) showPopup('NÃO FOI POSSÍVEL ORGANIZAR', 'error', 1300)
        scheduleRender(true)
      })
      return
    }
    writeLocal('vshook_director_number_sort_applied', direction)
  }

  function confirmNumberOrderChange() {
    const kind = state.numberOrderConfirmKind
    if (!kind) return
    const context = state.numberOrderConfirmContext === 'regions' ? 'regions' : 'playlist'
    if (kind === 'number') {
      const useRegionId = state.numberOrderConfirmUseRegionId === true
      writeLocal('vshook_director_number_mode', useRegionId ? 'region' : 'order')
      if (useRegionId) applyNumberOrderSort(context, false)
      state.numberOrderConfirmKind = ''
      showPopup(useRegionId ? 'NUMBER: ID DA REGIÃO' : 'NUMBER: ORDEM DA LISTA', 'info', 1400)
      scheduleRender(true)
      return
    }
    const descending = state.numberOrderConfirmDescending === true
    applyNumberOrderSort(context, descending)
    state.numberOrderConfirmKind = ''
    showPopup(descending ? 'ORDENADO 9-0' : 'ORDENADO 0-9', 'info', 1400)
    scheduleRender(true)
  }

  function getPlayProtectionEnabled() {
    if (typeof state.snapshot?.playProtectionEnabled === 'boolean') {
      return state.snapshot.playProtectionEnabled
    }
    if (typeof state.snapshot?.manualStopFadeout?.playProtectionEnabled === 'boolean') {
      return state.snapshot.manualStopFadeout.playProtectionEnabled
    }
    return readLocal('vshook_director_play_protection', 'off') === 'on'
  }

  function togglePlayProtection() {
    const next = !getPlayProtectionEnabled()
    writeLocal('vshook_director_play_protection', next ? 'on' : 'off')
    if (state.snapshot && typeof state.snapshot === 'object') {
      state.snapshot.playProtectionEnabled = next
      if (state.snapshot.manualStopFadeout &&
          typeof state.snapshot.manualStopFadeout === 'object') {
        state.snapshot.manualStopFadeout.playProtectionEnabled = next
      }
    }
    postCommand('play_protection_set', {
      enabled: next,
      desiredState: next ? 'on' : 'off',
    })
    state.lastProtectedPlayTapAt = 0
    state.lastProtectedPlayMode = ''
    showPopup(next ? 'PLAY PROTECTION ON' : 'PLAY PROTECTION OFF', next ? 'success' : 'info', 1000)
    scheduleRender(true)
  }

  function allowProtectedPlayTap(mode, options = {}) {
    if (!getPlayProtectionEnabled()) return true
    const t = now()
    const currentMode = String(mode || '')
    const elapsed = t - Number(state.lastProtectedPlayTapAt || 0)
    const isSecondTap = state.lastProtectedPlayMode === currentMode && elapsed >= 0 && elapsed <= 520
    state.lastProtectedPlayTapAt = t
    state.lastProtectedPlayMode = currentMode
    if (isSecondTap) {
      state.lastProtectedPlayTapAt = 0
      state.lastProtectedPlayMode = ''
      return true
    }
    if (options.quiet) showPartsProtectionHintDom(currentMode)
    showPopup('TOQUE 2X — PLAY PROTECTION ATIVADO', 'info', 1100)
    return false
  }

  function getBridgeBaseUrl() {
    const saved = readLocal('vshook_director_url', '')
    if (saved) return saved.replace(/\/$/, '')
    return window.location.origin.replace(/\/$/, '')
  }

  function bridgeUrl(path) {
    const base = getBridgeBaseUrl()
    return `${base}${String(path || '').startsWith('/') ? path : `/${path}`}`
  }

  function withTimeout(ms) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), ms)
    return { signal: controller.signal, done: () => clearTimeout(timer) }
  }

  function showPopup(text, kind = 'info', durationMs = 1200) {
    const duration = Math.max(500, Number(durationMs) || 1200)
    const until = now() + duration
    state.popupText = String(text || '')
    state.popupKind = kind
    state.popupUntil = until
    // No TP o vídeo/imagem não pode ser recriado só para mostrar um aviso de
    // marker. Atualiza o popup isoladamente e preserva o player já carregado.
    syncDirectorPopupDom()
    scheduleRender(!state.showTelepromptScreen)
    setTimeout(() => {
      if (state.popupUntil === until) {
        state.popupText = ''
        state.popupUntil = 0
        syncDirectorPopupDom()
        scheduleRender(!state.showTelepromptScreen)
      }
    }, duration + 60)
  }

  function getProjectName(data = state.snapshot) {
    return String(data?.currentProjectName || data?.projectName || data?.activeProject?.name || 'VS HOOK').trim() || 'VS HOOK'
  }

  function getId(item) {
    if (!item || typeof item !== 'object') return ''
    const id = item.id ?? item.songId ?? item.regionId ?? item.markerId ?? item.guid ?? item.source_number ?? item.sourceNumber ?? item.number
    return id == null ? '' : String(id)
  }

  function getName(item) {
    if (!item || typeof item !== 'object') return ''
    return String(item.name || item.label || item.title || item.songName || item.regionName || item.markerName || '').trim()
  }

  function isBlock(item) {
    if (!item || typeof item !== 'object') return false
    if (item.isBlock === true || item.block === true) return true
    const t = String(item.itemType || item.type || item.kind || '').toLowerCase()
    if (t === 'block' || t === 'bloco' || t === 'playlist_block' || t === 'song_block') return true
    const n = Number(item.source_number ?? item.sourceNumber ?? item.number)
    return Number.isFinite(n) && n < 0
  }

  function isHashChild(item) {
    if (!item || typeof item !== 'object') return false
    const t = String(item.familyRole || item.itemType || item.type || '').toLowerCase()
    return item.isHashChild === true || t === 'child' || t === 'hash_child'
  }

  function isHashParent(item) {
    if (!item || typeof item !== 'object') return false
    const t = String(item.familyRole || item.itemType || item.type || '').toLowerCase()
    const name = String(item.name || item.label || item.title || '').trim()
    const namedParent = name.indexOf('--') === 0 || (name.length >= 2 && name.lastIndexOf('--') === name.length - 2)
    return item.isHashParent === true || namedParent || t === 'parent' || t === 'hash_parent'
  }

  function getHashFamilyParentId(item) {
    if (!item || typeof item !== 'object') return ''
    if (isHashChild(item)) {
      return String(item.parentId ?? item.parentRegionId ?? item.parentSourceNumber
        ?? item.parent_source_number ?? item.parent_region_number ?? '')
    }
    return isHashParent(item) ? String(getId(item) || '') : ''
  }

  function getPlayingHashChild(data = state.snapshot) {
    const playingId = getPlayingId(data)
    const playPos = firstFiniteNumber([
      data?.playPosition,
      data?.currentPlayPosition,
      data?.playbackPosition,
      data?.currentPosition,
      data?.position,
    ])
    const drawerChildren = Object.values(state.hashRegionDrawerChildren || {})
      .flatMap((rows) => Array.isArray(rows) ? rows : [])
    const candidates = [...getRegions(data), ...getPlaylistItems(data), ...drawerChildren]
      .filter((item) => isHashChild(item))
    const direct = candidates.find((item) => String(getId(item) || '') === playingId)
    if (direct) return direct
    if (playPos === null) return null
    return candidates.find((item) => {
      const start = getItemStart(item)
      const end = getItemEnd(item)
      return start !== null && end !== null && playPos >= start - 0.0005 && playPos < end - 0.0005
    }) || null
  }

  function queuedChildConflictsWithPlayingFamily(item, data = state.snapshot) {
    if (!isHashChild(item)) return false
    const targetParentId = getHashFamilyParentId(item)
    const playingChild = getPlayingHashChild(data)
    const playingParentId = getHashFamilyParentId(playingChild)
    return !!targetParentId && !!playingParentId && targetParentId === playingParentId
  }

  function normalizeColor(value) {
    if (value && typeof value === 'object') {
      return normalizeColor(value.hex || value.colorHex || value.color || value.value || '')
    }
    const color = String(value || '').trim()
    if (!color) return ''
    if (/^#[0-9a-f]{3,8}$/i.test(color)) return color
    if (/^[0-9a-f]{6}$/i.test(color)) return `#${color}`
    return ''
  }

  function getLuaBlockColor(item) {
    if (!item) return ''
    return normalizeColor(item.blockColorHex)
      || normalizeColor(item.block_color_hex)
      || normalizeColor(item.bridgeBlockColorHex)
      || normalizeColor(item.luaBlockColorHex)
      || normalizeColor(item.outlineColorHex)
      || normalizeColor(item.rowColorHex)
      || normalizeColor(item.blockColor)
      || normalizeColor(item.block_color)
      || normalizeColor(item.colorHex)
      || normalizeColor(item.color_hex)
      || normalizeColor(item.finalTextColorHex)
      || normalizeColor(item.textColorHex)
      || normalizeColor(item.inheritedBlockColorHex)
  }

  function getLuaItemTextColor(item) {
    if (!item) return ''
    if (isBlock(item)) return getLuaBlockColor(item)
    const inherited = normalizeColor(item.textColorHex)
      || normalizeColor(item.finalTextColorHex)
      || normalizeColor(item.inheritedBlockColorHex)
      || normalizeColor(item.blockColorHex)
      || normalizeColor(item.colorHex)
      || normalizeColor(item.color_hex)
    return inherited && inherited.toLowerCase() !== '#334155' ? inherited : ''
  }

  function itemColorStyle(item, type) {
    const color = type === 'marker' ? '' : getLuaItemTextColor(item)
    return color ? ` style="color:${escapeHtml(color)}!important"` : ''
  }

  function getRegionNumberValue(item) {
    const candidates = [
      item?.source_number,
      item?.sourceNumber,
      item?.regionIndex,
      item?.luaRegionIndex,
      item?.region_index,
      item?.number,
      item?.regionId,
      item?.id,
      item?.parentSourceNumber,
      item?.parent_source_number,
      item?.parent_region_number,
    ]
    for (const value of candidates) {
      const n = Number(value)
      if (Number.isFinite(n)) return n
    }
    return null
  }

  function getRowNumberText(item, fallback) {
    const regionNumber = getRegionNumberValue(item)
    const value = numberColumnUsesRegionId() && regionNumber !== null ? regionNumber : fallback
    return String(Math.abs(Math.floor(Number(value) || 0))).padStart(2, '0')
  }

  function getRowSortValue(entry) {
    const n = getRegionNumberValue(entry.item)
    return n ?? entry.songNumber ?? entry.index + 1
  }

  // O repertório já chega na ordem persistida pela extensão. Na aba Músicas,
  // todas as regiões são ordenadas pelo ID, incluindo regiões que representam blocos.
  function getNumberSortedItems(items, type) {
    const source = Array.isArray(items) ? items.slice() : []
    if (type !== 'playlist' && type !== 'region') return source

    // O repertório deve ser exatamente o mesmo publicado pela extensão/Lua.
    // Nunca aplica uma segunda ordem local no App.
    if (type === 'playlist') return source

    const direction = getAppliedNumberSortDirection()
    if (!direction || source.length < 2) return source

    const rows = source
      .map((item, index) => ({ item, index, songNumber: index + 1 }))

    rows.sort((a, b) => {
      const av = getRowSortValue(a)
      const bv = getRowSortValue(b)
      const diff = direction === 'desc' ? bv - av : av - bv
      return diff !== 0 ? diff : a.index - b.index
    })

    return rows.map((entry) => entry.item)
  }

  function isPlayable(item) {
    return !!item && !isBlock(item)
  }

  function getDurationSec(item) {
    if (!item) return 0
    const direct = Number(item.durationSec ?? item.duration_sec ?? item.lengthSec ?? item.length)
    if (Number.isFinite(direct) && direct >= 0) return direct
    const start = Number(item.startPos ?? item.start_pos ?? item.pos ?? item.rgnstart ?? item.regionStart)
    const end = Number(item.endPos ?? item.end_pos ?? item.rgnend ?? item.regionEnd)
    if (Number.isFinite(start) && Number.isFinite(end) && end >= start) return end - start
    return 0
  }

  // O total precisa usar a duração bruta start/end, igual ao Lua. durationSec é
  // arredondado por item pela extensão e não pode ser somado para o total.
  function getRawDurationSecForTotal(item) {
    if (!item) return 0
    const start = Number(item.startPos ?? item.start_pos ?? item.pos ?? item.rgnstart ?? item.regionStart)
    const end = Number(item.endPos ?? item.end_pos ?? item.rgnend ?? item.regionEnd)
    if (Number.isFinite(start) && Number.isFinite(end) && end >= start) return end - start
    const direct = Number(item.durationSec ?? item.duration_sec ?? item.lengthSec ?? item.length)
    return Number.isFinite(direct) && direct >= 0 ? direct : 0
  }

  function formatTime(sec) {
    const value = Math.max(0, Math.floor(Number(sec) || 0))
    const h = Math.floor(value / 3600)
    const m = Math.floor((value % 3600) / 60)
    const s = value % 60
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
    return `${m}:${String(s).padStart(2, '0')}`
  }

  function formatTotalTime(sec) {
    // Mesma regra do Lua: soma em ponto flutuante, arredonda apenas o total final
    // e exibe sempre HH:MM:SS.
    const value = Math.max(0, Math.floor((Number(sec) || 0) + 0.5))
    const h = Math.floor(value / 3600)
    const m = Math.floor((value % 3600) / 60)
    const s = value % 60
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  }

  function parseTotalClockText(value) {
    const raw = String(value ?? '').trim().replace(/^total\s*:\s*/i, '').trim()
    if (!raw) return null
    const parts = raw.split(':').map((part) => Number(part))
    if (parts.length === 2 && parts.every(Number.isFinite)) return Math.max(0, parts[0] * 60 + parts[1])
    if (parts.length === 3 && parts.every(Number.isFinite)) return Math.max(0, parts[0] * 3600 + parts[1] * 60 + parts[2])
    return null
  }

  function firstTotalText(values) {
    for (const value of values) {
      const seconds = parseTotalClockText(value)
      if (seconds !== null) return formatTotalTime(seconds)
    }
    return ''
  }

  function firstFiniteTotalNumber(values) {
    for (const value of values) {
      const number = Number(value)
      if (Number.isFinite(number) && number >= 0) return number
    }
    return null
  }

  function formatTimerTime(sec, forceNegative = false) {
    const raw = Number(sec)
    const negative = forceNegative || (Number.isFinite(raw) && raw < 0)
    const value = Math.max(0, Math.floor(Math.abs(Number.isFinite(raw) ? raw : 0)))
    const h = Math.floor(value / 3600)
    const m = Math.floor((value % 3600) / 60)
    const s = value % 60
    return `${negative ? '- ' : ''}${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  }

  function getPlaylistSongs(playlist) {
    if (Array.isArray(playlist?.songs)) return playlist.songs
    if (Array.isArray(playlist?.items)) return playlist.items
    if (Array.isArray(playlist?.tracks)) return playlist.tracks
    return []
  }

  function getPlaylistTotalSec(playlist) {
    return getPlaylistSongs(playlist).reduce((sum, item) => {
      // Blocos e filhos das regiões "--" não entram no total. O pai já cobre os filhos.
      if (!item || isBlock(item) || isHashChild(item)) return sum
      return sum + getRawDurationSecForTotal(item)
    }, 0)
  }

  function getRegionsTotalSec(data = state.snapshot) {
    return getRegions(data).reduce((sum, item) => {
      if (!item || isBlock(item) || isHashChild(item)) return sum
      return sum + getRawDurationSecForTotal(item)
    }, 0)
  }

  function getPlaylistTotalText(playlist) {
    const text = firstTotalText([
      playlist?.activePlaylistTotalText,
      playlist?.currentPlaylistTotalText,
      playlist?.playlistTotalText,
      playlist?.totalPlaylistText,
      playlist?.repertorioTotalText,
      playlist?.repertoryTotalText,
      playlist?.totalText,
      playlist?.durationText,
    ])
    if (text) return text
    const direct = firstFiniteTotalNumber([
      playlist?.activePlaylistTotalSec,
      playlist?.currentPlaylistTotalSec,
      playlist?.playlistTotalSec,
      playlist?.totalPlaylistSec,
      playlist?.repertorioTotalSec,
      playlist?.repertoryTotalSec,
      playlist?.totalDurationSec,
      playlist?.total_duration_sec,
      playlist?.totalSec,
      playlist?.durationTotalSec,
      playlist?.durationSec,
    ])
    if (direct !== null) return formatTotalTime(direct)
    return formatTotalTime(getPlaylistTotalSec(playlist))
  }

  function getActivePlaylistTotalText(data = state.snapshot, playlist = getActivePlaylist(data)) {
    const text = firstTotalText([
      data?.activePlaylistTotalText,
      data?.currentPlaylistTotalText,
      data?.playlistTotalText,
      data?.totalPlaylistText,
      data?.repertorioTotalText,
      data?.repertoryTotalText,
    ])
    if (text) return text
    const direct = firstFiniteTotalNumber([
      data?.activePlaylistTotalSec,
      data?.currentPlaylistTotalSec,
      data?.playlistTotalSec,
      data?.totalPlaylistSec,
      data?.repertorioTotalSec,
      data?.repertoryTotalSec,
    ])
    if (direct !== null) return formatTotalTime(direct)
    return getPlaylistTotalText(playlist)
  }

  function getRegionsTotalText(data = state.snapshot) {
    const text = firstTotalText([
      data?.regionsTotalText,
      data?.totalRegionsText,
      data?.musicasTotalText,
      data?.musicTotalText,
      data?.songsTotalText,
      data?.totalMusicasText,
    ])
    if (text) return text
    const direct = firstFiniteTotalNumber([
      data?.regionsTotalSec,
      data?.totalRegionsSec,
      data?.musicasTotalSec,
      data?.musicTotalSec,
      data?.songsTotalSec,
      data?.totalMusicasSec,
    ])
    if (direct !== null) return formatTotalTime(direct)
    return formatTotalTime(getRegionsTotalSec(data))
  }

  function renderTopPlaylistTitle(text) {
    const title = upperText(text || 'REPERTÓRIOS')
    const safe = escapeHtml(title)
    if (state.topPlaylistTickerTitle !== title || !state.topPlaylistTickerStartedAt) {
      state.topPlaylistTickerTitle = title
      state.topPlaylistTickerStartedAt = now()
    }
    if (title.length <= 18) return `<span class="topPlaylistTicker topPlaylistTickerStatic">${safe}</span>`
    // O root do app e redesenhado em varias acoes. Atraso negativo preserva a fase
    // do letreiro para ele nao reiniciar a cada clique ou selecao.
    const phaseSec = ((Math.max(0, now() - state.topPlaylistTickerStartedAt) % 9000) / 1000).toFixed(3)
    return `<span class="topPlaylistTicker topPlaylistTickerAnimated"><span class="topPlaylistTickerTrack" style="animation-delay:-${phaseSec}s;-webkit-animation-delay:-${phaseSec}s"><span>${safe}</span><span aria-hidden="true">${safe}</span></span></span>`
  }

  function renderPlaylistOptionTitle(text) {
    const title = upperText(text || 'REPERTÓRIO')
    const safe = escapeHtml(title)
    if (title.length <= 18) return `<span class="playlistOptionTicker playlistOptionTickerStatic">${safe}</span>`
    return `<span class="playlistOptionTicker playlistOptionTickerAnimated"><span class="playlistOptionTickerTrack"><span>${safe}</span><span aria-hidden="true">${safe}</span></span></span>`
  }

  function getActivePlaylist(data = state.snapshot) {
    const playlists = Array.isArray(data?.playlists) ? data.playlists : []
    if (!playlists.length) return null
    if (state.optimisticActivePlaylistId && now() < state.optimisticActivePlaylistUntil) {
      const optimistic = playlists.find((p) => String(p?.id ?? p?.playlistId ?? '') === String(state.optimisticActivePlaylistId))
      if (optimistic) return optimistic
    }
    const activeId = String(data?.activePlaylistId ?? '')
    if (activeId) {
      const byId = playlists.find((p) => String(p?.id ?? p?.playlistId ?? '') === activeId)
      if (byId) return byId
    }
    const name = String(data?.currentPlaylistName || '')
    if (name) {
      const byName = playlists.find((p) => String(p?.name || '') === name)
      if (byName) return byName
    }
    return playlists[0]
  }

  function syncActivePlaylistConfirmation(data = state.snapshot) {
    if (!state.optimisticActivePlaylistId && !state.optimisticActivePlaylistName) return
    const bridgeId = String(data?.activePlaylistId ?? data?.currentPlaylistIndex ?? '')
    const bridgeName = String(data?.activePlaylistName || data?.currentPlaylistName || '')
    const idMatches = !!state.optimisticActivePlaylistId && bridgeId === String(state.optimisticActivePlaylistId)
    const nameMatches = !!state.optimisticActivePlaylistName && bridgeName === String(state.optimisticActivePlaylistName)
    if (idMatches || nameMatches) {
      state.optimisticActivePlaylistId = ''
      state.optimisticActivePlaylistName = ''
      state.optimisticActivePlaylistUntil = 0
    }
  }

  function getPlaylistItems(data = state.snapshot) {
    const playlist = getActivePlaylist(data)
    return getPlaylistSongs(playlist)
  }

  function getRegions(data = state.snapshot) {
    return Array.isArray(data?.regions) ? data.regions : []
  }

  function getRegionsWithOpenDrawers(data = state.snapshot) {
    const regions = getRegions(data)
    const result = []
    for (const region of regions) {
      if (isHashChild(region)) continue
      result.push(region)
      const id = String(getId(region) || '')
      let children = state.hashRegionDrawerChildren[id]
      if (id && state.hashRegionDrawers[id]) {
        children = buildHashDrawerChildren(id, 'region', data)
      }
      if (id && state.hashRegionDrawers[id] && Array.isArray(children)) result.push(...children.map((child) => inheritDrawerParentColor(child, region)))
    }
    return result
  }

  function getPlaylistWithOpenDrawers(data = state.snapshot) {
    const items = getPlaylistItems(data)
    const result = []
    const parentIds = new Set(items.filter((item) => isHashParent(item)).map((item) => String(getId(item) || '')).filter(Boolean))
    for (const item of items) {
      const itemParentId = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
      if (isHashChild(item) && itemParentId && parentIds.has(itemParentId)) continue
      result.push(item)
      const id = String(getId(item) || '')
      let children = state.hashRegionDrawerChildren[id]
      if (id && state.hashRegionDrawers[id]) {
        children = buildHashDrawerChildren(id, 'playlist', data)
      }
      if (id && state.hashRegionDrawers[id] && Array.isArray(children)) result.push(...children.map((child) => inheritDrawerParentColor(child, item)))
    }
    return result
  }

  function inheritDrawerParentColor(child, parent) {
    return { ...child, color: parent?.color, colorHex: parent?.colorHex, textColor: parent?.textColor, textColorHex: parent?.textColorHex, finalTextColorHex: parent?.finalTextColorHex, blockColorHex: parent?.blockColorHex, bridgeBlockColorHex: parent?.bridgeBlockColorHex, inheritedBlockColorHex: parent?.inheritedBlockColorHex }
  }

  function itemFamilyContainsPlayingSong(item, data = state.snapshot) {
    const id = String(getId(item) || '')
    const playingId = getPlayingId(data)
    if (!id || !playingId) return false
    if (id === playingId) return true
    if (isHashChild(item)) return false
    const children = state.hashRegionDrawerChildren[id]
    if (Array.isArray(children) && children.some((child) => String(getId(child) || '') === playingId)) return true

    // Mantem o pai como representante visual mesmo entre atualizacoes do
    // snapshot/PreMix. Isso evita a marcacao sumir ao trocar de um filho para
    // o seguinte enquanto a gaveta continua fechada.
    if (!isHashParent(item) && !Array.isArray(children)) return false
    const playPos = firstFiniteNumber([
      data?.playPosition,
      data?.currentPlayPosition,
      data?.playbackPosition,
      data?.currentPosition,
      data?.position,
    ])
    const start = getItemStart(item)
    const end = getItemEnd(item)
    return playPos !== null && start !== null && end !== null &&
      playPos >= start - 0.0005 && playPos < end - 0.0005
  }

  function rowRepresentsPlayingSong(item, data = state.snapshot) {
    const id = String(getId(item) || '')
    if (!id) return false
    if (isHashChild(item)) return id === getPlayingId(data)
    if (state.hashRegionDrawers[id]) return id === getPlayingId(data)
    return itemFamilyContainsPlayingSong(item, data)
  }

  function getImmediateFamilyPlayingId(parentId, data = state.snapshot) {
    const id = String(parentId || '')
    if (!id) return id
    // Quando o alvo já é uma música-filho, o estado visual otimista precisa
    // manter exatamente esse ID. Resolver a família novamente fazia a seleção
    // e o painel "Tocando agora" piscarem na primeira música-filho.
    if (isHashChild(getSongItemById(id, data))) return id
    const children = state.hashRegionDrawerChildren[id]
    if (!state.hashRegionDrawers[id] || !Array.isArray(children) || !children.length) return id
    const cursor = firstFiniteNumber([
      data?.editCursorPosition,
      data?.cursorPosition,
      data?.currentPosition,
      data?.position,
      getItemStart(getSongItemById(id, data)),
    ])
    const ordered = children.slice().sort((a, b) => (getItemStart(a) || 0) - (getItemStart(b) || 0))
    const containing = cursor === null ? null : ordered.find((child) => {
      const start = getItemStart(child)
      const end = getItemEnd(child)
      return start !== null && end !== null && cursor >= start - 0.0005 && cursor < end - 0.0005
    })
    return String(getId(containing || ordered[0]) || id)
  }

  function clampTunerValue(value) {
    const n = Math.round(Number(value) || 0)
    return Math.max(-12, Math.min(12, n))
  }

  function getTunerItemKey(item) {
    if (!item || typeof item !== 'object') return ''
    const key = item.tunerKey ?? item.sourceNumber ?? item.source_number ?? item.regionNumber ?? item.number ?? getId(item)
    return key == null ? '' : String(key)
  }

  function getTunerSourceNumber(item) {
    const values = [item?.sourceNumber, item?.source_number, item?.regionNumber, item?.number, getRegionNumberValue(item)]
    for (const value of values) {
      const n = Number(value)
      if (Number.isFinite(n) && n >= 0) return Math.floor(n)
    }
    return null
  }

  function getTunerValue(item) {
    const key = getTunerItemKey(item)
    const pending = key ? state.tunerOptimisticValues?.[key] : null
    if (pending && Number(pending.until || 0) > now()) return clampTunerValue(pending.value)
    if (pending && key) delete state.tunerOptimisticValues[key]
    return clampTunerValue(item?.tunerValue ?? item?.tunerSemitones ?? item?.semitones ?? 0)
  }

  function formatTunerValue(value) {
    const n = clampTunerValue(value)
    return n > 0 ? `+${n}` : String(n)
  }

  function getTunerSourceItems(data = state.snapshot) {
    return state.tunerSourceTab === 'regions' ? getRegions(data) : getPlaylistItems(data)
  }

  function getMobileTunerSourceItems(data = state.snapshot) {
    const sourceType = getTunerSourceType()
    const itemType = sourceType === 'region' ? 'region' : 'playlist'
    const source = getNumberSortedItems(getTunerSourceItems(data), sourceType)
    const parentIds = new Set()

    for (const item of source) {
      if (!isHashChild(item)) continue
      const parentId = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
      if (parentId) parentIds.add(parentId)
    }
    for (const item of source) {
      if (isBlock(item) || isHashChild(item)) continue
      const id = String(getId(item) || '')
      if (id && (isHashParent(item) || itemHasChildSongMarkers(item, data) || Array.isArray(state.hashRegionDrawerChildren[id]))) {
        parentIds.add(id)
      }
    }

    const result = []
    const insertedChildren = new Set()
    for (const item of source) {
      const itemId = String(getId(item) || '')
      const itemParentId = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
      if (isHashChild(item) && itemParentId && parentIds.has(itemParentId)) continue

      result.push(item)
      if (!itemId || isBlock(item) || isHashChild(item) || !parentIds.has(itemId)) continue

      let children = buildHashDrawerChildren(itemId, itemType, data)
      if (!Array.isArray(children) || !children.length) {
        children = source.filter((candidate) => {
          if (!isHashChild(candidate)) return false
          const parentId = String(candidate?.parentId ?? candidate?.parentRegionId ?? candidate?.parentSourceNumber ?? candidate?.parent_source_number ?? candidate?.parent_region_number ?? '')
          return parentId === itemId
        })
      }
      children = children.slice().sort((a, b) => (getItemStart(a) || 0) - (getItemStart(b) || 0))
      for (const child of children) {
        const childKey = `${String(getId(child) || '')}|${String(getItemStart(child) ?? '')}|${String(getItemEnd(child) ?? '')}`
        if (insertedChildren.has(childKey)) continue
        insertedChildren.add(childKey)
        result.push(inheritDrawerParentColor(child, item))
      }
    }

    // Compatibilidade com snapshots antigos que entreguem um filho antes do pai.
    for (const item of source) {
      if (!isHashChild(item)) continue
      const childKey = `${String(getId(item) || '')}|${String(getItemStart(item) ?? '')}|${String(getItemEnd(item) ?? '')}`
      if (!insertedChildren.has(childKey)) result.push(item)
    }
    return result
  }

  function getTunerSourceType() {
    return state.tunerSourceTab === 'regions' ? 'region' : 'playlist'
  }

  function getTunerValuesSignature(data = state.snapshot) {
    if (!state.showTunerScreen && !state.tabletTunerSplit) return ''
    const source = state.showTunerScreen ? getMobileTunerSourceItems(data) : getTunerSourceItems(data)
    return source.map((item) => {
      if (isBlock(item)) return `b:${getId(item)}:${getName(item)}`
      return `${getTunerItemKey(item)}:${getTunerValue(item)}`
    }).join('|')
  }

  function getMarkers(data = state.snapshot) {
    return Array.isArray(data?.markers) ? data.markers : []
  }

  function getProjects(data = state.snapshot) {
    const lists = [data?.projects, data?.projectTabs, data?.openProjects, data?.tabs]
    for (const list of lists) {
      if (Array.isArray(list) && list.length) return list
    }
    return []
  }

  function getProjectItemId(item, index = 0) {
    return String(item?.id ?? item?.projectId ?? item?.tabId ?? item?.index ?? item?.projectIndex ?? `project-${index + 1}`)
  }

  function getProjectItemName(item, index = 0) {
    return String(item?.name ?? item?.projectName ?? item?.title ?? item?.label ?? `SESSÃO ${index + 1}`).trim()
  }

  function getActiveProject(data = state.snapshot) {
    return getProjects(data).find((project) =>
      project?.active === true ||
      project?.isActive === true ||
      project?.isCurrent === true) || null
  }

  function getMultiProjectPlaylistsEnabled(data = state.snapshot) {
    const requested = typeof state.pendingMultiProjectPlaylists === 'boolean'
      ? state.pendingMultiProjectPlaylists
      : data?.multiProjectPlaylistsEnabled === true ||
        data?.showAllProjectPlaylists === true
    return requested &&
      getMultiProjectPlaylistsAvailable(data)
  }

  function getMultiProjectPlaylistsAvailable(data = state.snapshot) {
    if (typeof data?.multiProjectPlaylistsAvailable === 'boolean') {
      return data.multiProjectPlaylistsAvailable
    }
    if (typeof data?.canEnableMultiProjectPlaylists === 'boolean') {
      return data.canEnableMultiProjectPlaylists
    }
    const shared =
      data?.openProjectPlaylists ??
      data?.allProjectPlaylists
    if (!Array.isArray(shared)) return false
    return shared.some((playlist) =>
      !openPlaylistBelongsToCurrentProject(
        playlist, data))
  }

  function getOpenProjectPlaylists(data = state.snapshot) {
    const shared = data?.openProjectPlaylists ?? data?.allProjectPlaylists
    if (Array.isArray(shared)) {
      return getMultiProjectPlaylistsEnabled(data)
        ? shared
        : shared.filter((playlist) =>
            openPlaylistBelongsToCurrentProject(playlist, data))
    }
    const activeProject = getActiveProject(data)
    const projectId = getProjectItemId(activeProject, Number(data?.activeProjectTabIndex || 0))
    const projectName = getProjectItemName(activeProject, Number(data?.activeProjectTabIndex || 0))
    const projectIndex = Number(activeProject?.index ?? data?.activeProjectTabIndex ?? 0)
    const playlists = Array.isArray(data?.playlists) ? data.playlists : []
    return playlists.map((playlist, index) => {
      const localPlaylistId = String(playlist?.playlistId ?? playlist?.id ?? index + 1)
      return {
        ...playlist,
        id: `${projectId}|${localPlaylistId}`,
        selectorId: `${projectId}|${localPlaylistId}`,
        playlistId: localPlaylistId,
        localPlaylistId,
        projectId,
        projectName,
        projectIndex,
        projectTabIndex: projectIndex,
        projectActive: true,
      }
    })
  }

  function getOpenPlaylistSelectorId(playlist, index = 0) {
    if (!playlist) return ''
    const direct = playlist?.selectorId ?? playlist?.selectionId
    if (direct != null && String(direct)) return String(direct)
    const projectId = String(playlist?.projectId ?? '')
    const localId = String(playlist?.localPlaylistId ?? playlist?.playlistId ?? playlist?.id ?? index + 1)
    return projectId ? `${projectId}|${localId}` : localId
  }

  function getOpenPlaylistLocalId(playlist, index = 0) {
    return String(playlist?.localPlaylistId ?? playlist?.playlistId ?? index + 1)
  }

  function openPlaylistBelongsToCurrentProject(playlist, data = state.snapshot) {
    if (!playlist) return false
    if (playlist?.projectActive === true) return true
    const activeProject = getActiveProject(data)
    return String(playlist?.projectId ?? '') ===
      String(activeProject ? getProjectItemId(activeProject) : '')
  }

  function anyOpenProjectTransportActive(data = state.snapshot) {
    const projects = getProjects(data)
    if (projects.some((project) =>
      project?.transportActive === true ||
      project?.playing === true ||
      project?.paused === true)) return true
    return data?.transportPlaying === true ||
      data?.playing === true ||
      data?.isPlaying === true ||
      data?.paused === true
  }

  function otherOpenProjectTransportActive(data = state.snapshot) {
    const projects = getProjects(data)
    const activeProject = getActiveProject(data)
    const activeProjectId = activeProject
      ? getProjectItemId(activeProject)
      : ''
    const activeProjectIndex = Number(
      activeProject?.index ??
      activeProject?.projectIndex ??
      data?.activeProjectTabIndex ??
      0)
    return projects.some((project, index) => {
      const projectId = getProjectItemId(project, index)
      const projectIndex = Number(
        project?.index ?? project?.projectIndex ?? index)
      const current =
        project?.active === true ||
        project?.isActive === true ||
        project?.isCurrent === true ||
        (activeProjectId && projectId === activeProjectId) ||
        projectIndex === activeProjectIndex
      if (current) return false
      return project?.transportActive === true ||
        project?.playing === true ||
        project?.paused === true
    })
  }

  function getItemStart(item) {
    return firstFiniteNumber([item?.startPos, item?.start_pos, item?.pos, item?.position, item?.regionStart, item?.rgnstart])
  }

  function getItemEnd(item) {
    return firstFiniteNumber([item?.endPos, item?.end_pos, item?.regionEnd, item?.rgnend])
  }

  function getPartsSongTarget(source = state.partsMarkerSongSource, data = state.snapshot) {
    const queued = source === 'queued'
    const selected = source === 'selected'
    const takeoverId = !queued && !selected ? String(state.partsTakeoverSongId || '') : ''
    const selectedId = state.activeTab === 'regions'
      ? (getSelectedRegionId(data) || getSelectedPlaylistId(data))
      : (getSelectedPlaylistId(data) || getSelectedRegionId(data))
    const id = queued ? getQueuedId(data) : selected ? selectedId : (takeoverId || getPlayingId(data))
    const item = getSongItemById(id, data)
    const start = firstFiniteNumber(queued
      ? [item?.startPos, item?.start_pos, item?.pos, item?.regionStart, item?.rgnstart, data?.queuedStartPos, data?.queueStartPos]
      : selected
        ? [item?.startPos, item?.start_pos, item?.pos, item?.regionStart, item?.rgnstart]
      : takeoverId
        ? [item?.startPos, item?.start_pos, item?.pos, item?.regionStart, item?.rgnstart]
        : [data?.currentSongStart, data?.playbackStartPos, data?.songStartPos, item?.startPos, item?.start_pos, item?.pos, item?.regionStart, item?.rgnstart])
    const end = firstFiniteNumber(queued
      ? [item?.endPos, item?.end_pos, item?.regionEnd, item?.rgnend, data?.queuedEndPos, data?.queueEndPos]
      : selected
        ? [item?.endPos, item?.end_pos, item?.regionEnd, item?.rgnend]
      : takeoverId
        ? [item?.endPos, item?.end_pos, item?.regionEnd, item?.rgnend]
        : [data?.currentSongEnd, data?.playbackEndPos, data?.songEndPos, item?.endPos, item?.end_pos, item?.regionEnd, item?.rgnend])
    const name = queued ? getQueuedSongName(data) : selected ? findSongNameById(id, data) : (takeoverId ? findSongNameById(id, data) : getNowPlayingName(data))
    const available = !!id && start !== null && end !== null && end > start
    return { source: queued ? 'queued' : selected ? 'selected' : 'playing', id, item, start, end, name, available }
  }

  function getEffectivePartsSongSource(data = state.snapshot) {
    const preferred = state.partsMarkerSongSource === 'queued' ? 'queued' : state.partsMarkerSongSource === 'selected' ? 'selected' : 'playing'
    const preferredTarget = getPartsSongTarget(preferred, data)
    if (preferred === 'selected' && preferredTarget.available && isPlaying(data)) {
      const playingTarget = getPartsSongTarget('playing', data)
      const sameId = playingTarget.available && String(playingTarget.id || '') === String(preferredTarget.id || '')
      const sameBounds = playingTarget.available && Number.isFinite(Number(playingTarget.start)) && Number.isFinite(Number(playingTarget.end))
        && Math.abs(Number(playingTarget.start) - Number(preferredTarget.start)) <= 0.002
        && Math.abs(Number(playingTarget.end) - Number(preferredTarget.end)) <= 0.002
      // A musica selecionada acabou de receber Play. A origem efetiva da Parts
      // passa a ser "tocando" imediatamente para o botao da musica atual ficar
      // ativo, sem depender de um toque posterior para atualizar o visual.
      if (sameId || sameBounds) return 'playing'
    }
    if (preferredTarget.available) return preferred
    // Quando a fila acabou de assumir o transporte, o snapshot pode ja ter
    // limpado queuedSongId antes de o estado visual trocar de fonte. Nesse
    // intervalo, prioriza a musica realmente tocando em vez da selecao antiga.
    const fallbacks = preferred === 'queued' && isPlaying(data)
      ? ['playing', 'selected', 'queued']
      : ['selected', 'queued', 'playing']
    for (const fallback of fallbacks) {
      if (fallback !== preferred && getPartsSongTarget(fallback, data).available) return fallback
    }
    return preferred
  }

  function getActivePartsRegion(data = state.snapshot) {
    const source = getEffectivePartsSongSource(data)
    const target = getPartsSongTarget(source, data)
    if (!target.available) return null
    return { item: target.item, start: target.start, end: target.end, id: target.id, source }
  }

  function itemHasChildSongMarkers(item, data = state.snapshot) {
    if (!item || isBlock(item) || isHashChild(item)) return false
    const start = getItemStart(item)
    const end = getItemEnd(item)
    if (start === null || end === null || end <= start) return false
    return getMarkers(data).some((marker) => {
      const pos = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
      const raw = getRawMarkerName(marker)
      return pos !== null && pos >= start - 0.0005 && pos < end - 0.0005 &&
        !!raw && !raw.startsWith('$') && !raw.startsWith('*') && !raw.startsWith('!')
    })
  }

  function partsTargetIsParent(data = state.snapshot) {
    const source = getEffectivePartsSongSource(data)
    const target = getPartsSongTarget(source, data)
    if (!target?.available || !target.id || isHashChild(target.item)) return false
    return isHashParent(target.item) || itemHasChildSongMarkers(target.item, data) || Array.isArray(state.hashRegionDrawerChildren[String(target.id)])
  }

  function renderPartsParentInstruction() {
    return '<div class="emptyBox partsParentInstruction">ABRA A GAVETA COM UM DUPLO TOQUE SOBRE ESSA REGIÃO E SELECIONE UMA MÚSICA</div>'
  }

  function resolveSongTabById(id, data = state.snapshot) {
    const wanted = String(id || '')
    if (!wanted) return state.activeTab === 'regions' ? 'regions' : 'playlist'
    if (getPlaylistItems(data).some((item) => String(getId(item)) === wanted)) return 'playlist'
    if (getRegions(data).some((item) => String(getId(item)) === wanted)) return 'regions'
    return state.activeTab === 'regions' ? 'regions' : 'playlist'
  }

  function getSongItemForTransport(id, preferredTab = '', data = state.snapshot) {
    const wanted = String(id || '')
    if (!wanted) return null
    const playlistItem = getPlaylistItems(data).find((item) => String(getId(item)) === wanted && !isBlock(item)) || null
    const regionItem = getRegions(data).find((item) => String(getId(item)) === wanted && !isBlock(item)) || null
    if (preferredTab === 'regions') return regionItem || playlistItem
    if (preferredTab === 'playlist') return playlistItem || regionItem
    return playlistItem || regionItem || getSongItemById(wanted, data)
  }

  function makeTransportSeekTarget(item, options = {}, data = state.snapshot) {
    if (!item && !options.id) return null
    const id = String(options.id || getId(item) || '')
    if (!id) return null
    const start = firstFiniteNumber([
      options.start,
      options.startPos,
      item?.startPos,
      item?.start_pos,
      item?.pos,
      item?.position,
      item?.regionStart,
      item?.rgnstart,
    ])
    const end = firstFiniteNumber([
      options.end,
      options.endPos,
      item?.endPos,
      item?.end_pos,
      item?.regionEnd,
      item?.rgnend,
    ])
    if (start === null || end === null || !(end > start)) return null
    const itemDuration = item ? getDurationSec(item) : 0
    const directDisplayDuration = firstFiniteNumber([
      options.displayDuration,
      options.durationSec,
      itemDuration > 0 ? itemDuration : null,
      end - start,
    ])
    return {
      id,
      name: String(options.name || getRowDisplayName(item, 0, 1) || findSongNameById(id, data) || 'MÚSICA'),
      start,
      end,
      displayDuration: directDisplayDuration !== null ? Math.max(0, directDisplayDuration) : Math.max(0, end - start),
      tab: options.tab === 'regions' ? 'regions' : 'playlist',
      source: String(options.source || ''),
      markerNumber: Number(options.markerNumber) || 0,
      markerEnumIndex: Number.isFinite(Number(options.markerEnumIndex)) ? Number(options.markerEnumIndex) : -1,
      exactPosition: options.exactPosition === true,
    }
  }

  function getLiveTransportSeekTarget(data = state.snapshot) {
    if (isPlaying(data)) {
      const id = getPlayingId(data)
      if (!id) return null
      const preferredTab = getPlaylistItems(data).some((item) => String(getId(item)) === id && !isBlock(item)) ? 'playlist' : resolveSongTabById(id, data)
      const item = getSongItemForTransport(id, preferredTab, data)
      return makeTransportSeekTarget(item, {
        id,
        name: getNowPlayingName(data) || findSongNameById(id, data),
        start: firstFiniteNumber([data?.currentSongStart, data?.playbackStartPos, getItemStart(item)]),
        end: firstFiniteNumber([data?.currentSongEnd, data?.playbackEndPos, getItemEnd(item)]),
        tab: preferredTab,
        source: 'playing',
      }, data)
    }

    const preferred = state.activeTab === 'regions'
      ? [{ id: getSelectedRegionId(data), tab: 'regions' }, { id: getSelectedPlaylistId(data), tab: 'playlist' }]
      : [{ id: getSelectedPlaylistId(data), tab: 'playlist' }, { id: getSelectedRegionId(data), tab: 'regions' }]
    for (const candidate of preferred) {
      if (!candidate.id) continue
      const item = getSongItemForTransport(candidate.id, candidate.tab, data)
      const target = makeTransportSeekTarget(item, {
        id: candidate.id,
        tab: candidate.tab,
        source: 'selected',
      }, data)
      if (target) return target
    }
    return null
  }

  function getStoredTransportSeekTarget() {
    if (!state.transportSeekSongId) return null
    return makeTransportSeekTarget(null, {
      id: state.transportSeekSongId,
      name: state.transportSeekSongName,
      start: state.transportSeekSongStart,
      end: state.transportSeekSongEnd,
      displayDuration: state.transportSeekDisplayDuration,
      tab: state.transportSeekSongTab,
      source: state.transportSeekSongSource,
      markerNumber: state.transportSeekMarkerNumber,
      markerEnumIndex: state.transportSeekMarkerEnumIndex,
      exactPosition: state.transportSeekExplicitTarget,
    })
  }

  function getTransportSeekTarget(data = state.snapshot) {
    // Depois que o modal abre, mantém a mesma música como referência. Assim uma
    // atualização transitória de seleção/fila não troca o início da representação.
    if (state.showTransportSeekModal) return getStoredTransportSeekTarget()
    return getLiveTransportSeekTarget(data)
  }

  function getTransportSeekTargetKey(data = state.snapshot) {
    if (!state.showTransportSeekModal) return ''
    const target = getTransportSeekTarget(data)
    if (!target) return 'none'
    return [target.id, target.name, target.start, target.end, target.displayDuration, target.tab, target.source, target.markerNumber, target.markerEnumIndex].join('|')
  }

  function getTransportSeekPlaying(data = state.snapshot) {
    const bridgePlaying = data?.transportPlaying === true || data?.playing === true
    if (state.transportSeekPendingPlaying !== null && now() < Number(state.transportSeekPendingPlayingUntil || 0)) {
      const desired = state.transportSeekPendingPlaying === true
      if (bridgePlaying === desired) {
        state.transportSeekPendingPlaying = null
        state.transportSeekPendingPlayingUntil = 0
        return bridgePlaying
      }
      return desired
    }
    state.transportSeekPendingPlaying = null
    state.transportSeekPendingPlayingUntil = 0
    return bridgePlaying
  }

  function getTransportSeekCursorPos(target = getTransportSeekTarget(), data = state.snapshot) {
    if (!target) return 0
    const start = Number(target.start) || 0
    const end = Number(target.end) || 0
    if (!(end > start)) return start
    let playPos = firstFiniteNumber([data?.playPosition, data?.currentPlayPosition, data?.playbackPosition])
    const heldPlayPos = Number(state.transportSeekPlayVisualHoldPos)
    const modalPlaying = getTransportSeekPlaying(data)
    if (modalPlaying && Number.isFinite(heldPlayPos) && now() < Number(state.transportSeekPlayVisualHoldUntil || 0)) {
      if (Number.isFinite(Number(playPos)) && Math.abs(Number(playPos) - heldPlayPos) <= 0.25) {
        state.transportSeekPlayVisualHoldPos = null
        state.transportSeekPlayVisualHoldUntil = 0
      } else {
        playPos = heldPlayPos
      }
    } else if (now() >= Number(state.transportSeekPlayVisualHoldUntil || 0)) {
      state.transportSeekPlayVisualHoldPos = null
      state.transportSeekPlayVisualHoldUntil = 0
    }
    const raw = modalPlaying
      ? playPos
      : state.transportSeekDragging
        ? state.transportSeekCursorPos
        : (() => {
            const bridgeCursor = firstFiniteNumber([data?.editCursorPosition, data?.cursorPosition, data?.currentPosition, data?.position])
            const pauseHold = Number(state.transportSeekPauseVisualHoldPos)
            if (Number.isFinite(pauseHold) && now() < Number(state.transportSeekPauseVisualHoldUntil || 0)) {
              if (Number.isFinite(Number(bridgeCursor)) && Math.abs(Number(bridgeCursor) - pauseHold) <= 0.25) {
                state.transportSeekPauseVisualHoldPos = null
                state.transportSeekPauseVisualHoldUntil = 0
                return bridgeCursor
              }
              return pauseHold
            }
            state.transportSeekPauseVisualHoldPos = null
            state.transportSeekPauseVisualHoldUntil = 0
            return firstFiniteNumber([bridgeCursor, state.transportSeekCursorPos])
          })()
    if (!Number.isFinite(Number(raw))) return start
    return Math.max(start, Math.min(end, Number(raw)))
  }

  function getTransportSeekCursorPercent(target = getTransportSeekTarget(), data = state.snapshot) {
    if (!target) return 0
    const start = Number(target.start) || 0
    const end = Number(target.end) || 0
    if (!(end > start)) return 0
    return clampPercent(((getTransportSeekCursorPos(target, data) - start) / (end - start)) * 100)
  }

  function getTransportSeekWaveBars(target = getTransportSeekTarget()) {
    if (!target) return []
    const count = 56
    let seed = parseInt(simpleHash(`${target.id}|${target.name}|${target.start}|${target.end}`).slice(0, 8), 16) >>> 0
    const bars = []
    for (let i = 0; i < count; i += 1) {
      seed = (seed * 1664525 + 1013904223) >>> 0
      const rnd = ((seed >>> 8) & 0xffff) / 0xffff
      const shape = 0.42 + 0.38 * Math.sin((i / Math.max(1, count - 1)) * Math.PI)
      bars.push(Math.max(12, Math.min(92, Math.round((rnd * 0.6 + shape * 0.4) * 100))))
    }
    return bars
  }

  function getTransportSeekMarkerLines(target = getTransportSeekTarget(), data = state.snapshot) {
    if (!target) return []
    const start = Number(target.start) || 0
    const end = Number(target.end) || 0
    if (!(end > start)) return []
    return getMarkers(data)
      .map((marker) => {
        const pos = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
        if (pos === null || pos <= start + 0.0005 || pos >= end - 0.0005) return null
        const markerName = getName(marker)
        const isLoop = markerName.startsWith('*1') || markerName.startsWith('*2')
        return {
          percent: clampPercent(((pos - start) / (end - start)) * 100),
          isLoop,
        }
      })
      .filter(Boolean)
  }

  function getTransportSeekMarkerSignature(target = getTransportSeekTarget(), data = state.snapshot) {
    if (!target) return 'empty'
    const markerKey = getTransportSeekMarkerLines(target, data)
      .map((marker) => `${marker.isLoop ? 'L' : 'M'}:${Number(marker.percent || 0).toFixed(4)}`)
      .join('|')
    return simpleHash(`${target.id}|${target.start}|${target.end}|${markerKey}`)
  }

  function renderTransportSeekMarkerLinesHtml(target = getTransportSeekTarget(), data = state.snapshot) {
    return getTransportSeekMarkerLines(target, data).map((marker) => marker.isLoop
      ? `<span class="transportSeekMarkerLine transportSeekMarkerLoop" style="left:${marker.percent}%"><span class="transportSeekMarkerHead">LOOP</span></span>`
      : `<span class="transportSeekMarkerLine" style="left:${marker.percent}%"><span class="transportSeekMarkerHead transportSeekMarkerHeadCyan">$</span></span>`
    ).join('')
  }

  function getTransportSeekWaveSignature(target = getTransportSeekTarget()) {
    if (!target) return 'empty'
    return simpleHash(`${target.id}|${target.name}|${target.start}|${target.end}|${target.displayDuration}`)
  }

  function renderTransportSeekWaveBarsHtml(target = getTransportSeekTarget()) {
    return getTransportSeekWaveBars(target)
      .map((height) => `<span class="transportSeekWaveBar" style="height:${Math.max(10, Math.min(96, Number(height) || 10))}%"></span>`)
      .join('')
  }

  function storeTransportSeekTarget(target, explicit = false) {
    if (!target) return
    state.transportSeekExplicitTarget = explicit === true
    state.transportSeekSongId = String(target.id || '')
    state.transportSeekSongName = String(target.name || 'MÚSICA')
    state.transportSeekSongStart = Number(target.start) || 0
    state.transportSeekSongEnd = Number(target.end) || 0
    state.transportSeekDisplayDuration = Math.max(0, Number(target.displayDuration) || (Number(target.end) - Number(target.start)) || 0)
    state.transportSeekSongTab = target.tab === 'regions' ? 'regions' : 'playlist'
    state.transportSeekSongSource = String(target.source || (explicit ? 'explicit' : 'selected'))
    state.transportSeekMarkerNumber = Number(target.markerNumber) || 0
    state.transportSeekMarkerEnumIndex = Number.isFinite(Number(target.markerEnumIndex)) ? Number(target.markerEnumIndex) : -1
  }

  function openTransportSeekModal(explicitTarget = null, shouldRender = true) {
    const wasOpen = state.showTransportSeekModal
    const target = explicitTarget || getLiveTransportSeekTarget(state.snapshot)
    if (!target) {
      if (document.documentElement.dataset.directorDevice === 'tablet' && !IS_MUSICIAN_MONITOR) {
        state.transportSeekSongId = ''
        state.transportSeekSongName = ''
        state.transportSeekSongStart = 0
        state.transportSeekSongEnd = 0
        state.transportSeekDisplayDuration = 0
        state.transportSeekExplicitTarget = false
        state.transportSeekCursorPos = 0
        state.showTransportSeekModal = true
        persistDirectorPanelState()
        if (!wasOpen) state.tabletTransportOpening = true
        if (shouldRender) scheduleRender(true)
        return true
      }
      showPopup(isPlaying(state.snapshot) ? 'MÚSICA NÃO ENCONTRADA' : 'SELECIONE UMA MÚSICA', 'error', 1100)
      return false
    }
    storeTransportSeekTarget(target, !!explicitTarget)
    state.showTransportSeekModal = true
    persistDirectorPanelState()
    if (!wasOpen && document.documentElement.dataset.directorDevice === 'tablet') state.tabletTransportOpening = true
    state.transportSeekCursorPos = getTransportSeekCursorPos(target, state.snapshot)
    if (shouldRender) scheduleRender(true)
    return true
  }

  function closeTransportSeekModal(shouldRender = true) {
    if (!state.showTransportSeekModal) return
    state.showTransportSeekModal = false
    persistDirectorPanelState()
    state.transportSeekExplicitTarget = false
    state.tabletTransportOpening = false
    if (shouldRender) scheduleRender(true)
  }

  function mountTransportSeekModalDom() {
    const current = root.querySelector('.transportSeekOverlay,.tabletTransportPanel')
    if (!state.showTransportSeekModal) {
      current?.remove?.()
      root.querySelector('[data-action="tablet-transport-panel"]')?.classList.remove('tabletSidebarButtonActive')
      return
    }
    if (current) return
    const container = root.querySelector('.app>.container')
    if (!container) return
    const html = renderTransportSeekModal(state.snapshot || {})
    if (!html) return
    container.insertAdjacentHTML('beforeend', html)
    root.querySelector('[data-action="tablet-transport-panel"]')?.classList.add('tabletSidebarButtonActive')
    syncTransportSeekModalDom()
  }

  function setTransportSeekCursorRatio(ratio) {
    const target = getTransportSeekTarget(state.snapshot)
    if (!target || getTransportSeekPlaying(state.snapshot)) return false
    const songStart = Number(target.start) || 0
    const songEnd = Number(target.end) || 0
    if (!(songEnd > songStart)) return false
    const pos = songStart + (songEnd - songStart) * Math.max(0, Math.min(1, Number(ratio) || 0))
    state.transportSeekCursorPos = pos
    // Mantém o último ponto enviado até a extensão publicá-lo no snapshot.
    // Sem esta retenção, um snapshot anterior podia desenhar o cursor no ponto
    // velho por um ciclo e causar o "vai e volta" apenas visual.
    state.transportSeekPauseVisualHoldPos = pos
    state.transportSeekPauseVisualHoldUntil = now() + 3000
    state.snapshot = { ...(state.snapshot || {}), editCursorPosition: pos, cursorPosition: pos }

    state.transportSeekCommandSeq = Math.max(Number(state.transportSeekCommandSeq) + 1 || 1, Date.now() * 1000)
    postCommand('edit_cursor_move', {
      position: pos,
      minPos: songStart,
      maxPos: songEnd,
      cursorMoveSeq: state.transportSeekCommandSeq,
    }).then((response) => {
      if (!response?.ok) showPopup('EXTENSÃO SEM RESPOSTA', 'error', 1100)
    })
    syncTransportSeekModalDom()
    return true
  }

  function handleTransportSeekSetPosition(el, event) {
    if (getTransportSeekPlaying(state.snapshot)) {
      showPopup('PARE A MÚSICA', 'error', 900)
      return
    }
    const rect = el?.getBoundingClientRect?.()
    if (!rect || !(rect.width > 0)) return
    const point = (event?.changedTouches && event.changedTouches[0]) || (event?.touches && event.touches[0]) || event
    const tabletRotatedWeb = document.documentElement.dataset.directorDevice === 'tablet'
      && window.matchMedia?.('(orientation: portrait)')?.matches
    if (tabletRotatedWeb) {
      // A interface foi girada 90 graus via CSS: o eixo X lógico da waveform
      // passa a acompanhar o eixo Y físico do toque.
      const clientY = Number(point?.clientY)
      if (!Number.isFinite(clientY) || !(rect.height > 0)) return
      setTransportSeekCursorRatio((clientY - rect.top) / rect.height)
      return
    }
    const clientX = Number(point?.clientX)
    if (!Number.isFinite(clientX)) return
    setTransportSeekCursorRatio((clientX - rect.left) / rect.width)
  }

  let transportSeekDragPointerId = null

  function handleTransportSeekDrag(event) {
    const wave = event.target?.closest?.('[data-action="transport-seek-set-position"]')
    if (event.type === 'pointerdown') {
      if (!wave) return
      if (getTransportSeekPlaying(state.snapshot)) {
        handleTransportSeekSetPosition(wave, event)
        return
      }
      transportSeekDragPointerId = event.pointerId
      state.transportSeekDragging = true
      try { wave.setPointerCapture?.(event.pointerId) } catch (_) {}
      event.preventDefault?.()
      handleTransportSeekSetPosition(wave, event)
      return
    }
    if (transportSeekDragPointerId === null || event.pointerId !== transportSeekDragPointerId) return
    const activeWave = wave || document.querySelector('[data-action="transport-seek-set-position"]')
    if (event.type === 'pointermove') {
      event.preventDefault?.()
      handleTransportSeekSetPosition(activeWave, event)
      return
    }
    if (event.type === 'pointerup') handleTransportSeekSetPosition(activeWave, event)
    transportSeekDragPointerId = null
    state.transportSeekDragging = false
  }

  function handleTransportSeekPlayToggle() {
    const data = state.snapshot || {}
    if (getTransportSeekPlaying(data)) {
      const pausedAt = getTransportSeekCursorPos(getTransportSeekTarget(data), data)
      state.transportSeekCursorPos = pausedAt
      state.transportSeekPauseVisualHoldPos = pausedAt
      state.transportSeekPauseVisualHoldUntil = now() + 3000
      state.transportSeekPendingPlaying = false
      state.transportSeekPendingPlayingUntil = now() + 3000
      postCommand('director_pause', { preserveCursor: true, transportOnly: true })
      syncTransportSeekModalDom()
      return
    }
    const target = getTransportSeekTarget(data)
    if (!target) {
      showPopup('SELECIONE UMA MÚSICA', 'error', 1000)
      return
    }
    clearPartsTakeover()
    clearPartsArmedOwner()
    if (target.tab === 'regions') {
      state.selectedRegionId = target.id
      state.selectedPlaylistSongId = ''
      state.regionSelectionClearedUntil = 0
      state.playlistSelectionClearedUntil = now() + 5000
    } else {
      state.selectedPlaylistSongId = target.id
      state.selectedRegionId = ''
      state.playlistSelectionClearedUntil = 0
      state.regionSelectionClearedUntil = now() + 5000
    }
    state.optimisticPlayingId = target.id
    state.optimisticPlayingUntil = now() + 4000
    const cursorPos = getTransportSeekCursorPos(target, data)
    state.transportSeekPlayVisualHoldPos = cursorPos
    state.transportSeekPlayVisualHoldUntil = now() + 5000
    state.transportSeekPendingPlaying = true
    state.transportSeekPendingPlayingUntil = now() + 3000
    postCommand('director_play_no_seek', {
      activeTab: target.tab,
      page: target.tab,
      targetId: target.id,
      songId: target.id,
      selectedRegionId: target.id,
      selectedPlaylistSongId: target.id,
      startPos: Number(target.start) || 0,
      endPos: Number(target.end) || 0,
      selectedStartPos: Number(target.start) || 0,
      selectedEndPos: Number(target.end) || 0,
      noSeek: true,
      preserveCursor: true,
      transportOnly: true,
    })
    syncTransportSeekModalDom()
  }

  function clearPartsArmedOwner() {
    state.partsArmedOwnerSongId = ''
    state.partsArmedOwnerTab = ''
    state.partsArmedOwnerStart = null
    state.partsArmedOwnerEnd = null
  }

  function clearPartsTakeover() {
    state.partsTakeoverSongId = ''
    state.partsTakeoverTab = ''
    state.partsTakeoverPreviousPlayingId = ''
  }

  function capturePartsArmedOwner(data = state.snapshot) {
    clearPartsArmedOwner()
    const source = getEffectivePartsSongSource(data)
    const target = getPartsSongTarget(source, data)
    if (source !== 'queued' || !target.available) return
    state.partsArmedOwnerSongId = String(target.id || '')
    state.partsArmedOwnerTab = resolveSongTabById(target.id, data)
    state.partsArmedOwnerStart = Number(target.start)
    state.partsArmedOwnerEnd = Number(target.end)
  }

  function hasEnteredArmedQueuedSong(data = state.snapshot) {
    if (!state.partsArmedOwnerSongId || !isPlaying(data)) return false
    const playPos = getCurrentPlaybackPosition(data)
    const start = Number(state.partsArmedOwnerStart)
    const end = Number(state.partsArmedOwnerEnd)
    if (playPos === null || !Number.isFinite(start) || !Number.isFinite(end) || end <= start) return false
    if (playPos < start - 0.12 || playPos >= end - 0.0005) return false
    const markerPos = getMarkerPositionById(state.partsArmedMarkerId, data)
    return markerPos === null || playPos >= markerPos - 0.35
  }

  function promotePartsQueuedMarkerTakeover(data = state.snapshot) {
    const id = String(state.partsArmedOwnerSongId || '')
    if (!id) return
    state.partsTakeoverSongId = id
    state.partsTakeoverTab = state.partsArmedOwnerTab || resolveSongTabById(id, data)
    state.partsTakeoverPreviousPlayingId = String(data?.playingId || '')
    state.partsMarkerSongSource = 'playing'
    state.queuedSongId = ''
    state.optimisticQueueClearedUntil = now() + 5000
    clearPartsArmedOwner()
  }

  function syncPartsTakeoverFromSnapshot(data = state.snapshot) {
    const ownerId = String(state.partsTakeoverSongId || '')
    if (!ownerId) return
    const rawPlayingId = String(data?.playingId || '')
    const previousPlayingId = String(state.partsTakeoverPreviousPlayingId || '')
    if (rawPlayingId === ownerId) {
      clearPartsTakeover()
      return
    }
    if (rawPlayingId && previousPlayingId && rawPlayingId !== previousPlayingId) clearPartsTakeover()
  }

  function getPartsTakeoverTarget() {
    const id = String(state.partsTakeoverSongId || '')
    if (!id) return null
    return { id, tab: state.partsTakeoverTab === 'regions' ? 'regions' : 'playlist' }
  }

  function ensurePartsTakeoverBeforeStop(data = state.snapshot) {
    if (state.partsTakeoverSongId || !state.partsArmedOwnerSongId) return
    const queuedId = getQueuedId(data)
    const ownerId = String(state.partsArmedOwnerSongId || '')
    if (hasEnteredArmedQueuedSong(data) || !queuedId || queuedId !== ownerId) promotePartsQueuedMarkerTakeover(data)
  }

  function getRawMarkerName(item) {
    return String(item?.rawName || item?.originalName || item?.name || item?.label || item?.markerName || '').trim()
  }

  function getPartsMarkerInfo(item) {
    const raw = getRawMarkerName(item)
    if (!raw) return null
    let prefix = ''
    let name = raw
    if (raw.startsWith('$')) {
      prefix = '$'
      name = raw.slice(1)
    } else if (raw.startsWith('*1')) {
      prefix = '*1'
      name = raw.slice(2)
    } else if (raw.startsWith('*2')) {
      prefix = '*2'
      name = raw.slice(2)
    } else {
      return null
    }
    name = name.replace(/^[-–—:\s]+/, '').trim()
    return { prefix, name: name || raw.slice(prefix.length).trim() || 'MARKER' }
  }

  function getPartsMarkers(data = state.snapshot) {
    if (partsTargetIsParent(data)) return []
    const region = getActivePartsRegion(data)
    if (!region) return []
    const songName = getPartsSongTarget(region.source, data).name
      || findSongNameById(region.id, data)
      || getName(region.item)
      || 'MÚSICA'
    const songStart = {
      id: `__parts_song_start__:${region.id}`,
      partsSongStart: true,
      partsDisplayName: `${songName} - INÍCIO`,
      pos: region.start,
      position: region.start,
      startPos: region.start,
      songId: region.id,
      partsSongSource: region.source,
    }
    const markers = getMarkers(data)
      .filter((marker) => {
        if (!getPartsMarkerInfo(marker)) return false
        const pos = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
        return pos !== null && pos >= region.start - 0.0005 && pos < region.end - 0.0005
      })
      .map((marker) => {
        const info = getPartsMarkerInfo(marker)
        return { ...marker, partsPrefix: info.prefix, partsDisplayName: info.name }
      })
    return [songStart, ...markers]
  }

  function getMarkerPositionById(id, data = state.snapshot) {
    const wanted = String(id || '')
    if (!wanted) return null
    if (wanted.indexOf('__parts_song_start__:') === 0) {
      const region = getActivePartsRegion(data)
      return region ? region.start : null
    }
    const marker = getMarkers(data).find((item) => String(getId(item)) === wanted)
    if (!marker) return null
    return firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
  }

  function getMixerTracks(data = state.snapshot) {
    const mixer = data?.mixer && typeof data.mixer === 'object' ? data.mixer : null
    if (state.mixerView === 'master') {
      const master = data?.mixerMaster || mixer?.master || data?.masterTrack || null
      return master && typeof master === 'object' ? [master] : []
    }
    if (state.mixerView === 'groups') return Array.isArray(data?.mixerGroups) ? data.mixerGroups : (Array.isArray(mixer?.groups) ? mixer.groups : [])
    return Array.isArray(data?.mixerTracks) ? data.mixerTracks : (Array.isArray(mixer?.tracks) ? mixer.tracks : [])
  }

  function getMixerItemIds(item, fallback = '') {
    return [
      item?.id,
      item?.guid,
      item?.targetId,
      item?.trackId,
      item?.trackGuid,
      item?.itemId,
      fallback,
    ].map((value) => String(value ?? '').trim()).filter(Boolean)
  }

  function findMixerTrackById(id, data = state.snapshot) {
    const wanted = String(id || '')
    if (!wanted) return null
    return getMixerTracks(data).find((item) => getMixerItemIds(item).includes(wanted)) || null
  }

  function getMixerPrimaryId(item, fallback = '') {
    return getMixerItemIds(item, fallback)[0] || String(fallback || '')
  }

  function clampRatio(value, fallback = 0.75) {
    const num = Number(value)
    return Math.max(0, Math.min(1, Number.isFinite(num) ? num : fallback))
  }

  function mixerRatioToDb(ratio) {
    const safe = clampRatio(ratio, 0.75)
    const zeroRatio = 0.76
    if (safe <= 0) return Number.NEGATIVE_INFINITY
    if (safe <= zeroRatio) {
      const minDb = -90
      const curve = 1.35
      const t = Math.pow(safe / zeroRatio, 1 / curve)
      return minDb + (t * -minDb)
    }
    return ((safe - zeroRatio) / (1 - zeroRatio)) * 12
  }

  function nativeMixerRatioToDb(ratio) {
    const safe = clampRatio(ratio, 0.75)
    if (safe <= 0) return Number.NEGATIVE_INFINITY
    return (safe * 72) - 60
  }

  function getMixerDbValue(item) {
    const id = getMixerPrimaryId(item)
    const hold = id ? mixerVolumeHold.get(id) : null
    if (hold && now() <= Number(hold.until || 0)) return nativeMixerRatioToDb(hold.ratio)
    const directRaw = item?.db ?? item?.volumeDb ?? item?.volume_db
    const direct = Number(directRaw)
    if (directRaw !== null && directRaw !== undefined && directRaw !== '' && Number.isFinite(direct)) return direct
    return nativeMixerRatioToDb(item?.volumeRatio ?? item?.volume ?? item?.ratio ?? 0.75)
  }

  function formatMixerDb(item) {
    const db = getMixerDbValue(item)
    if (!Number.isFinite(db)) return '-Inf dB'
    const normalized = Math.abs(db) < 0.05 ? 0 : Math.max(-90, Math.min(12, db))
    return `${normalized >= 0 ? '+' : ''}${normalized.toFixed(1)} dB`
  }

  function getMixerRatio(item) {
    const id = getMixerPrimaryId(item)
    const hold = id ? mixerVolumeHold.get(id) : null
    if (hold && now() <= Number(hold.until || 0)) return clampRatio(hold.ratio)
    return clampRatio(item?.volumeRatio ?? item?.volume ?? item?.ratio ?? 0.75)
  }

  function getHeldMixerToggle(item, field) {
    const rawValue = field === 'mute'
      ? item?.mute === true || item?.muted === true
      : item?.solo === true || item?.soloed === true
    for (const id of getMixerItemIds(item)) {
      const hold = mixerToggleHold.get(`${state.mixerView}:${id}:${field}`)
      if (!hold) continue
      if (now() > Number(hold.until || 0)) {
        mixerToggleHold.delete(`${state.mixerView}:${id}:${field}`)
        continue
      }
      // Assim que a leitura viva confirma o clique do app, solta a proteção
      // otimista. Uma mudança manual posterior no REAPER aparece na hora.
      if (rawValue === !!hold.value) {
        mixerToggleHold.delete(`${state.mixerView}:${id}:${field}`)
        continue
      }
      return !!hold.value
    }
    return rawValue
  }

  function setHeldMixerToggle(item, field, value) {
    for (const id of getMixerItemIds(item)) {
      mixerToggleHold.set(`${state.mixerView}:${id}:${field}`, { value: !!value, until: now() + 5000 })
    }
  }

  function setHeldMixerVolume(id, ratio) {
    const track = findMixerTrackById(id)
    for (const key of getMixerItemIds(track || {}, id)) {
      mixerVolumeHold.set(key, { ratio: clampRatio(ratio), until: now() + 5000 })
    }
  }

  function getMixerZeroDbRatio() {
    return 60 / 72
  }

  function getPremixSongs(data = state.snapshot) {
    const premix = data?.premix && typeof data.premix === 'object' ? data.premix : null
    const songs = Array.isArray(data?.premixSongs) ? data.premixSongs : (Array.isArray(premix?.songs) ? premix.songs : [])
    return songs.length ? songs : getRegions(data)
  }

  function getPremixTracks(data = state.snapshot) {
    const premix = data?.premix && typeof data.premix === 'object' ? data.premix : null
    if (state.premixTrackView === 'groups') {
      return Array.isArray(data?.premixGroups) ? data.premixGroups : (Array.isArray(premix?.groups) ? premix.groups : [])
    }
    return Array.isArray(data?.premixTracks) ? data.premixTracks : (Array.isArray(premix?.tracks) ? premix.tracks : getMixerTracks(data))
  }

  function getPremixItemRows(data = state.snapshot) {
    const premix = data?.premix && typeof data.premix === 'object' ? data.premix : null
    if (Array.isArray(data?.premixItems)) return data.premixItems
    if (Array.isArray(premix?.items)) return premix.items
    if (Array.isArray(premix?.itemRows)) return premix.itemRows
    return []
  }

  function getPremixSongSections(data = state.snapshot) {
    const premix = data?.premix && typeof data.premix === 'object' ? data.premix : null
    const sections = Array.isArray(premix?.songSections)
      ? premix.songSections
      : (Array.isArray(premix?.sections) ? premix.sections : [])
    return sections.filter((section) => section && typeof section === 'object')
  }

  function getPremixSectionItems(section) {
    if (!section || typeof section !== 'object') return []
    if (Array.isArray(section.items)) return section.items
    if (Array.isArray(section.itemRows)) return section.itemRows
    return []
  }

  function getPremixAllItemRows(data = state.snapshot) {
    const sections = getPremixSongSections(data)
    if (sections.length) return sections.flatMap((section) => getPremixSectionItems(section))
    return getPremixItemRows(data)
  }

  function getPremixSectionMarkerNumber(section) {
    if (!section || typeof section !== 'object') return 0
    const direct = Number(section.markerNumber ?? section.sourceNumber ?? section.source_number ?? section.number)
    if (Number.isFinite(direct) && direct > 0) return Math.trunc(direct)
    const rawId = String(section.songId ?? section.id ?? '')
    const match = rawId.match(/^m?(\d+)$/i)
    return match ? Number(match[1]) || 0 : 0
  }

  function getPremixSectionMarkerPosition(section, data = state.snapshot) {
    const markerNumber = getPremixSectionMarkerNumber(section)
    const sectionId = String(section?.songId ?? section?.id ?? '')
    const marker = getMarkers(data).find((candidate) => {
      const candidateNumber = Number(candidate?.number ?? candidate?.sourceNumber ?? candidate?.source_number)
      if (markerNumber > 0 && Number.isFinite(candidateNumber) && Math.trunc(candidateNumber) === markerNumber) return true
      const candidateId = String(getId(candidate) || '')
      if (!sectionId || !candidateId) return false
      return candidateId === sectionId || candidateId === `m${sectionId}` || `m${candidateId}` === sectionId
    })
    return marker ? firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos]) : null
  }

  function getPremixSectionTarget(section, data = state.snapshot) {
    if (!section || typeof section !== 'object') return null
    const id = String(section.songId ?? section.id ?? '')
    if (!id) return null
    const markerPosition = getPremixSectionMarkerPosition(section, data)
    const sectionStart = firstFiniteNumber([section.startPos, section.start_pos, section.pos])
    const sectionEnd = firstFiniteNumber([section.endPos, section.end_pos, section.rgnend])
    return {
      id,
      name: String(section.name || section.label || 'MÚSICA'),
      start: markerPosition !== null ? markerPosition : (sectionStart !== null ? sectionStart : 0),
      end: sectionEnd !== null ? sectionEnd : 0,
      markerNumber: getPremixSectionMarkerNumber(section),
      markerEnumIndex: Number.isFinite(Number(section.markerEnumIndex ?? section.enumIndex)) ? Number(section.markerEnumIndex ?? section.enumIndex) : -1,
      tab: 'regions',
      exactPosition: true,
    }
  }

  function buildHashDrawerChildren(parentId, itemType = 'region', data = state.snapshot) {
    const id = String(parentId || '')
    if (!id) return []
    const primary = itemType === 'playlist' ? getPlaylistItems(data) : getRegions(data)
    const secondary = itemType === 'playlist' ? getRegions(data) : getPlaylistItems(data)
    const parent = primary.find((item) => String(getId(item)) === id)
      || secondary.find((item) => String(getId(item)) === id)
      || null
    const parentStart = getItemStart(parent)
    const parentEnd = getItemEnd(parent)
    if (parentStart === null || parentEnd === null || parentEnd <= parentStart) return []

    // Formato atual: as musicas-filhas ja chegam da extensao como regioes da
    // segunda ruler lane. Reaproveita esses objetos, com seus limites exatos.
    const seenRegionChildren = new Set()
    const regionChildren = [...primary, ...secondary].map((candidate) => {
      if (!isHashChild(candidate)) return null
      const candidateParentId = String(candidate?.parentId ?? candidate?.parentRegionId ?? candidate?.parentSourceNumber ?? candidate?.parent_source_number ?? candidate?.parent_region_number ?? '')
      if (candidateParentId !== id) return null
      const childId = String(getId(candidate) || '')
      const start = getItemStart(candidate)
      const end = getItemEnd(candidate)
      if (!childId || start === null || end === null || end <= start + 0.0005) return null
      const sourceNumber = Number(candidate?.sourceNumber ?? candidate?.source_number ?? candidate?.number)
      const hasMatchingSongMarker = getMarkers(data).some((marker) => {
        const raw = getRawMarkerName(marker)
        const markerNumber = Number(marker?.number ?? marker?.sourceNumber ?? marker?.source_number)
        const markerStart = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
        return raw && !raw.startsWith('$') && !raw.startsWith('*') && !raw.startsWith('!') &&
          Number.isFinite(sourceNumber) && markerNumber === sourceNumber && markerStart !== null && Math.abs(markerStart - start) <= 0.001
      })
      const isNativeRegionChild = candidate?.isRegionChild === true || String(candidate?.sourceKind || '').toLowerCase() === 'region' || !hasMatchingSongMarker
      if (!isNativeRegionChild) return null
      const uniqueKey = `${childId}|${start.toFixed(6)}|${end.toFixed(6)}`
      if (seenRegionChildren.has(uniqueKey)) return null
      seenRegionChildren.add(uniqueKey)
      return {
        ...candidate,
        id: childId,
        type: 'hash_child',
        itemType: 'hash_child',
        isBlock: false,
        isPlayable: true,
        isHashChild: true,
        isRegionChild: true,
        sourceKind: 'region',
        familyRole: 'child',
        parentId: id,
        startPos: start,
        endPos: end,
        durationSec: Math.max(0, end - start),
        sourceNumber: Number.isFinite(sourceNumber) ? Math.trunc(sourceNumber) : 0,
        source_number: Number.isFinite(sourceNumber) ? Math.trunc(sourceNumber) : 0,
      }
    }).filter(Boolean).sort((a, b) => a.startPos - b.startPos)

    if (regionChildren.length) {
      state.hashRegionDrawerChildren[id] = regionChildren
      return regionChildren
    }

    const songMarkers = getMarkers(data).map((marker, index) => {
      const raw = getRawMarkerName(marker)
      const start = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
      const number = Number(marker?.number ?? marker?.sourceNumber ?? marker?.source_number)
      if (!raw || start === null || start < parentStart - 0.0005 || start >= parentEnd - 0.0005) return null
      if (raw.startsWith('$') || raw.startsWith('*') || raw.startsWith('!')) return null
      const markerId = String(getId(marker) || '')
      return { marker, index, raw, start, number, id: markerId.startsWith('m') ? markerId : `m${Number.isFinite(number) ? Math.trunc(number) : markerId || index + 1}` }
    }).filter(Boolean).sort((a, b) => a.start - b.start)

    const children = songMarkers.map((entry, index) => {
      const end = index + 1 < songMarkers.length ? songMarkers[index + 1].start : parentEnd
      if (end <= entry.start + 0.0005) return null
      const sourceNumber = Number.isFinite(entry.number) ? Math.trunc(entry.number) : index + 1
      return {
        id: entry.id,
        name: getName(entry.marker) || entry.raw,
        label: getName(entry.marker) || entry.raw,
        type: 'song',
        itemType: 'hash_child',
        isBlock: false,
        isPlayable: true,
        isHashChild: true,
        familyRole: 'child',
        parentId: id,
        startPos: entry.start,
        endPos: end,
        durationSec: Math.max(0, end - entry.start),
        sourceNumber,
        source_number: sourceNumber,
        markerEnumIndex: Number(entry.marker?.enumIndex ?? entry.marker?.markerEnumIndex ?? entry.index),
      }
    }).filter(Boolean)
    if (children.length) state.hashRegionDrawerChildren[id] = children
    return children
  }

  function restoreOpenHashDrawerFamily(data = state.snapshot) {
    for (const parentId of Object.keys(state.hashRegionDrawers || {})) {
      if (!state.hashRegionDrawers[parentId] || Array.isArray(state.hashRegionDrawerChildren[parentId])) continue
      const itemType = getPlaylistItems(data).some((item) => String(getId(item)) === parentId) ? 'playlist' : 'region'
      buildHashDrawerChildren(parentId, itemType, data)
    }
  }

  function getPremixEffectiveTarget(data = state.snapshot) {
    const sections = getPremixSongSections(data)
    if (sections.length) {
      const targets = sections.map(getPremixSectionTarget).filter(Boolean)
      const wantedId = String(state.premixPlaySongId || '')
      const wantedStart = Number(state.premixPlaySongStart) || 0
      let target = targets.find((candidate) =>
        candidate.id === wantedId &&
        (!(wantedStart > 0) || Math.abs(candidate.start - wantedStart) <= 0.001))
      if (!target) {
        const playingId = getPlayingId(data)
        target = targets.find((candidate) => candidate.id === playingId)
      }
      if (!target) target = targets[0] || null
      if (target) return target
    }
    return {
      id: String(state.premixPlaySongId || state.premixSongId || ''),
      name: String(state.premixPlaySongName || state.premixSongName || data?.premix?.selectedSongName || 'MÚSICA'),
      start: Number(state.premixPlaySongStart || state.premixSongStart) || 0,
      end: Number(state.premixPlaySongEnd || state.premixSongEnd) || 0,
      markerNumber: Number(state.premixPlayMarkerNumber) || 0,
      markerEnumIndex: Number.isFinite(Number(state.premixPlayMarkerEnumIndex)) ? Number(state.premixPlayMarkerEnumIndex) : -1,
      tab: state.premixSourceTab,
      exactPosition: false,
    }
  }

  function getPremixSnapshotSongId(data = state.snapshot) {
    const premix = data?.premix && typeof data.premix === 'object' ? data.premix : null
    return String(premix?.selectedSongId || data?.selectedPremixSongId || '')
  }

  function getPremixItemId(item) {
    return String(item?.itemId ?? item?.mediaItemId ?? item?.guid ?? item?.id ?? '')
  }

  function getPremixItemRatio(item) {
    const id = getPremixItemId(item)
    const hold = id ? premixItemVolumeHold.get(id) : null
    if (hold && now() <= Number(hold.until || 0)) return clampRatio(hold.ratio, 0.76)
    if (hold) premixItemVolumeHold.delete(id)
    return clampRatio(item?.volumeRatio ?? item?.ratio ?? 0.76, 0.76)
  }

  function getPremixItemMute(item) {
    const id = getPremixItemId(item)
    const hold = id ? premixItemMuteHold.get(id) : null
    if (hold && now() <= Number(hold.until || 0)) return !!hold.value
    if (hold) premixItemMuteHold.delete(id)
    return item?.mute === true || item?.muted === true
  }

  function setPremixItemRatio(id, ratio) {
    if (!id) return
    premixItemVolumeHold.set(String(id), { ratio: clampRatio(ratio, 0.76), until: now() + 5000 })
  }

  function setPremixItemMute(id, value) {
    if (!id) return
    premixItemMuteHold.set(String(id), { value: !!value, until: now() + 5000 })
  }

  function getSelectedPlaylistId(data = state.snapshot) {
    if (now() < Number(state.playlistSelectionClearedUntil || 0)) return ''
    if (state.selectedPlaylistSongId && now() < Number(state.playlistSelectionLocalUntil || 0)) return String(state.selectedPlaylistSongId)
    const readyId = getStoppedReadyVisualId(data)
    if (readyId && state.activeTab !== 'regions') return readyId
    return String(state.selectedPlaylistSongId || data?.selectedPlaylistSongId || '')
  }

  function getSelectedRegionId(data = state.snapshot) {
    if (now() < Number(state.regionSelectionClearedUntil || 0)) return ''
    if (state.selectedRegionId && now() < Number(state.regionSelectionLocalUntil || 0)) return String(state.selectedRegionId)
    const readyId = getStoppedReadyVisualId(data)
    if (readyId && state.activeTab === 'regions') return readyId
    return String(state.selectedRegionId || data?.selectedRegionId || '')
  }

  function getSelectedMarkerId(data = state.snapshot) {
    if (now() < Number(state.markerSelectionClearedUntil || 0)) return ''
    return String(state.selectedMarkerId || data?.selectedMarkerId || '')
  }

  function getPlayingId(data = state.snapshot) {
    if (bridgeExplicitlyStopped(data) &&
        state.pendingTransportPlaying !== true) return ''
    if (state.optimisticPlayingId && now() < state.optimisticPlayingUntil) return state.optimisticPlayingId
    if (state.tabletFadeoutRuntimeActive) return data?.playingId != null ? String(data.playingId) : String(state.optimisticStoppedId || '')
    if (state.optimisticStoppedUntil && now() < state.optimisticStoppedUntil) return ''
    return data?.playingId != null ? String(data.playingId) : ''
  }

  function isPlaying(data = state.snapshot) {
    if (state.tabletFadeoutRuntimeActive) return true
    if (state.pendingTransportPlaying !== null && now() < state.pendingTransportPlayingUntil) return !!state.pendingTransportPlaying
    if (bridgeExplicitlyStopped(data)) return false
    if (state.optimisticPlayingId && now() < state.optimisticPlayingUntil) return true
    if (state.optimisticStoppedUntil && now() < state.optimisticStoppedUntil) return false
    return data?.playing === true || !!data?.playingId
  }

  function bridgeExplicitlyStopped(data = state.snapshot) {
    if (!data || typeof data !== 'object') return false
    if (data.paused === true || data.transportPaused === true) return false
    return data.playing === false &&
      data.transportPlaying !== true &&
      data.isPlaying !== true &&
      !data.playingId &&
      !data.playingSongId &&
      !data.currentSongId
  }

  function syncVisualTransportState(data = state.snapshot) {
    if (!bridgeExplicitlyStopped(data) ||
        state.pendingTransportPlaying === true) return
    state.optimisticPlayingId = ''
    state.optimisticPlayingUntil = 0
  }

  function normalizeSharedPage(value) {
    const page = String(value || '').trim().toLowerCase()
    return page === 'playlist' || page === 'regions' || page === 'mixer'
      ? page : ''
  }

  function getDirectorSelectionScrollTarget() {
    const tab = state.activeTab === 'regions'
      ? 'regions'
      : state.activeTab === 'playlist' ? 'playlist' : ''
    if (!tab) return null
    const id = String((tab === 'regions'
      ? state.selectedRegionId
      : state.selectedPlaylistSongId) || '')
    return id ? { tab, id, key: `${tab}:${id}` } : null
  }

  function queueDirectorSelectionScroll(target) {
    if (IS_MUSICIAN_MONITOR || !target?.id) return
    state.directorSelectionScrollPending = {
      tab: target.tab,
      id: String(target.id),
      key: String(target.key || `${target.tab}:${target.id}`),
      expiresAt: now() + 1800,
      retryTimer: 0,
    }
  }

  function syncSharedInterfaceState(data = state.snapshot) {
    if (!data || typeof data !== 'object') return
    const currentTime = now()
    const previousSelectionTarget =
      getDirectorSelectionScrollTarget()
    const localSelectionWasPending =
      currentTime < Number(
        state.sharedSelectionLocalUntil || 0)

    const bridgeQueuedId = String(
      data?.queuedSongId || data?.queueSongId || '')
    const localQueuedId = String(state.queuedSongId || '')
    if (bridgeQueuedId === localQueuedId ||
        currentTime >= Number(state.queuedSongLocalUntil || 0)) {
      state.queuedSongId = bridgeQueuedId
      state.queuedManualVisualId =
        bridgeQueuedId && data?.queuedManual === true
          ? bridgeQueuedId : ''
      state.queuedSongLocalUntil = 0
      if (bridgeQueuedId) state.optimisticQueueClearedUntil = 0
    }

    const bridgePlaylistSelection = String(
      data?.selectedPlaylistSongId || '')
    const bridgeRegionSelection = String(
      data?.selectedRegionId || '')
    const bridgeMarkerSelection = String(
      data?.selectedMarkerId || '')
    const selectionMatches =
      bridgePlaylistSelection ===
        String(state.selectedPlaylistSongId || '') &&
      bridgeRegionSelection ===
        String(state.selectedRegionId || '') &&
      bridgeMarkerSelection ===
        String(state.selectedMarkerId || '')
    let bridgeSelectionApplied = false
    if (selectionMatches ||
        currentTime >= Number(
          state.sharedSelectionLocalUntil || 0)) {
      bridgeSelectionApplied = true
      state.selectedPlaylistSongId =
        bridgePlaylistSelection
      state.selectedRegionId = bridgeRegionSelection
      state.selectedMarkerId = bridgeMarkerSelection
      state.sharedSelectionLocalUntil = 0
      state.playlistSelectionLocalUntil = 0
      state.regionSelectionLocalUntil = 0
      state.playlistSelectionClearedUntil = 0
      state.regionSelectionClearedUntil = 0
      state.markerSelectionClearedUntil = 0
    }

    const reportedBridgePage = normalizeSharedPage(
      data?.activePage || data?.activeTab)
    // O app dos músicos acompanha as duas listas compartilhadas, mas não troca
    // para Mixer. Ao abrir Músicas na extensão ou no Diretor, ele passa a exibir
    // a mesma Lista Geral; ao voltar para Repertório, volta junto.
    const bridgePage = IS_MUSICIAN_MONITOR
      ? (reportedBridgePage === 'playlist' ||
          reportedBridgePage === 'regions'
          ? reportedBridgePage : '')
      : reportedBridgePage
    if (bridgePage &&
        (bridgePage === state.activeTab ||
         currentTime >= Number(
           state.activeTabLocalUntil || 0))) {
      const pageChanged = state.activeTab !== bridgePage
      if (pageChanged) {
        if (bridgePage === 'mixer' &&
            state.activeTab !== 'mixer') {
          state.tabletMixerReturnTab =
            state.activeTab === 'regions'
              ? 'regions' : 'playlist'
        }
        state.activeTab = bridgePage
        state.showMarkersOverlay = false
        state.tabletPartsSplit = false
        state.tabletTunerSplit = false
        state.showMenu = false
        state.showTabletSearch = false
        state.showSettingsModal = false
        state.showPlaylistModal = false
        state.showProjectModal = false
      }
      state.activeTabLocalUntil = 0
    }

    const nextSelectionTarget =
      getDirectorSelectionScrollTarget()
    if (bridgeSelectionApplied &&
        !localSelectionWasPending &&
        nextSelectionTarget &&
        nextSelectionTarget.key !==
          String(previousSelectionTarget?.key || '')) {
      queueDirectorSelectionScroll(nextSelectionTarget)
    }

    if (currentTime >= Number(
          state.sharedControlsLocalUntil || 0)) {
      state.pendingAutoplay = null
      state.pendingAutoplayMode = null
      state.pendingAutoBloco = null
      state.pendingAutoStop = null
      state.pendingStopPauseMode = null
      state.pendingLoop = null
      state.pendingMultiLoopBypass = null
      state.pendingLive = null
      state.pendingPreviewMode = null
      state.sharedControlsLocalUntil = 0

      const bridgePlaylistId = String(
        data?.activePlaylistId ??
        data?.currentPlaylistIndex ?? '')
      const bridgePlaylistName = String(
        data?.activePlaylistName ||
        data?.currentPlaylistName || '')
      const optimisticPlaylistMatches =
        (!!state.optimisticActivePlaylistId &&
          bridgePlaylistId === String(
            state.optimisticActivePlaylistId)) ||
        (!!state.optimisticActivePlaylistName &&
          bridgePlaylistName === String(
            state.optimisticActivePlaylistName))
      if (!optimisticPlaylistMatches) {
        state.optimisticActivePlaylistId = ''
        state.optimisticActivePlaylistName = ''
        state.optimisticActivePlaylistUntil = 0
      }
    }
  }

  function setPendingTransportPlaying(value, holdMs = 4000) {
    state.pendingTransportPlaying = !!value
    state.pendingTransportPlayingUntil = now() + Math.max(500, Number(holdMs) || 4000)
    syncMainControlButtonsDom()
  }

  function syncPendingTransportPlaying(data = state.snapshot) {
    if (state.pendingTransportPlaying === null) return
    if (now() >= Number(state.pendingTransportPlayingUntil || 0)) {
      state.pendingTransportPlaying = null
      state.pendingTransportPlayingUntil = 0
      return
    }
    const bridgePlaying = data?.playing === true || !!data?.playingId
    if (bridgePlaying === !!state.pendingTransportPlaying) {
      state.pendingTransportPlaying = null
      state.pendingTransportPlayingUntil = 0
    }
  }

  function isManualStopFadeoutConfigured(data = state.snapshot) {
    const config = data?.manualStopFadeout && typeof data.manualStopFadeout === 'object' ? data.manualStopFadeout : {}
    const enabled = state.tabletFadeoutEnabled || config.enabled === true || data?.manualStopFadeoutEnabled === true
    const selectedCount = Math.max(Number(config.selectedCount) || 0, (state.tabletFadeoutSelectedTrackIds || []).length)
    return enabled && selectedCount > 0
  }

  function isPaused(data = state.snapshot) {
    return data?.paused === true || data?.transportPaused === true
  }

  function getQueuedId(data = state.snapshot) {
    if (!isPlaying(data) && !isPaused(data)) return ''
    if (state.optimisticQueueClearedUntil && now() < state.optimisticQueueClearedUntil) return ''
    const queuedId = String(state.queuedSongId || data?.queuedSongId || data?.queueSongId || '')
    if (isAutoBlocoBoundaryVisualTarget(queuedId, data)) return ''
    return queuedId
  }

  function isAutoBlocoBoundaryVisualTarget(queuedId, data = state.snapshot) {
    const targetId = String(queuedId || '')
    if (!targetId || !getAutoBlocoEnabled(data) || !isPlaying(data)) return false

    // O AT/BL esconde somente o alvo automatico da virada de bloco. Uma fila
    // escolhida manualmente pelo usuario continua amarela, inclusive quando a
    // musica clicada esta dentro do proximo bloco.
    const localQueueActive = String(state.queuedSongId || '') === targetId
    const manualQueue = localQueueActive
      ? String(state.queuedManualVisualId || '') === targetId
      : data?.queuedManual === true
    if (manualQueue) return false

    const items = getPlaylistItems(data)
    if (!Array.isArray(items) || !items.length) return false

    let playingId = String(getPlayingId(data) || '')
    let playingIndex = items.findIndex((item) => String(getId(item) || '') === playingId)
    if (playingIndex < 0) {
      const playingChild = getPlayingHashChild(data)
      const parentId = getHashFamilyParentId(playingChild)
      if (parentId) playingIndex = items.findIndex((item) => String(getId(item) || '') === String(parentId))
    }
    const queuedIndex = items.findIndex((item) => String(getId(item) || '') === targetId)
    if (playingIndex < 0 || queuedIndex <= playingIndex) return false

    for (let index = playingIndex + 1; index <= queuedIndex; index += 1) {
      if (isBlock(items[index])) return true
    }
    return false
  }

  function getStoppedReadyVisualId(data = state.snapshot) {
    if (isPlaying(data) || isPaused(data)) return ''
    return String(getAutoBlocoTargetId(data) || state.queuedSongId || data?.queuedSongId || data?.queueSongId || '')
  }

  function getAutoplayEnabled(data = state.snapshot) {
    return getAutoplayMode(data) > 0
  }

  function getAutoplayMode(data = state.snapshot) {
    if (state.pendingAutoplay !== null && now() < state.pendingAutoplayUntil) {
      return state.pendingAutoplay
        ? (Number(state.pendingAutoplayMode) === 2 ? 2 : 1)
        : 0
    }
    const directMode = Number(data?.autoplayMode)
    if (directMode === 1 || directMode === 2) return directMode
    if (data?.autoplay2Enabled === true || data?.queuePrepareOnly === true) return 2
    if (data?.autoplay1Enabled === true ||
        data?.autoplayEnabled === true ||
        data?.autoPlayEnabled === true) return 1
    return 0
  }

  function getAutoplay1Enabled(data = state.snapshot) {
    return getAutoplayMode(data) === 1
  }

  function getAutoplay2Enabled(data = state.snapshot) {
    return getAutoplayMode(data) === 2
  }

  function getQueuedVisualKind(data = state.snapshot) {
    return getAutoplay2Enabled(data) ? 'green' : 'yellow'
  }

  function getQueuedRowClass(data = state.snapshot) {
    return getQueuedVisualKind(data) === 'green'
      ? 'queuedGreen' : 'queuedYellow'
  }

  function getQueuedTextClass(data = state.snapshot) {
    return getQueuedVisualKind(data) === 'green'
      ? 'queuedGreenText' : 'queuedYellowText'
  }

  function getAutoBlocoEnabled(data = state.snapshot) {
    // AT/BL pode permanecer armado mesmo com o Auto desligado, igual ao Lua.
    // Ele só produz efeito durante a execução automática, mas o estado é independente.
    if (state.pendingAutoBloco !== null && now() < state.pendingAutoBlocoUntil) return !!state.pendingAutoBloco
    return data?.autoBlocoArmed === true || data?.autoBlocoEnabled === true || data?.autoblockEnabled === true
  }

  function getAutoBlocoTargetId(data = state.snapshot) {
    return String(data?.autoBlocoTargetSongId || data?.autoBlocoTargetPlaylistSongId || '')
  }

  function getAutoStopEnabled(data = state.snapshot) {
    if (state.pendingAutoStop !== null && now() < state.pendingAutoStopUntil) return !!state.pendingAutoStop
    return data?.autoStopEnabled !== false && data?.autostopEnabled !== false
  }

  function getNormalStopEnabled(data = state.snapshot) {
    if (typeof data?.normalStopEnabled === 'boolean') return data.normalStopEnabled
    if (typeof data?.normal_stop_enabled === 'boolean') return data.normal_stop_enabled
    return true
  }

  function getStopPauseModeEnabled(data = state.snapshot) {
    if (state.pendingStopPauseMode !== null && now() < state.pendingStopPauseModeUntil) return !!state.pendingStopPauseMode
    return data?.stopPauseModeEnabled === true || data?.editModeStopPauseEnabled === true || data?.stopPauseEnabled === true
  }

  function getLiveEnabled(data = state.snapshot) {
    if (state.pendingLive !== null && now() < state.pendingLiveUntil) return !!state.pendingLive
    return data?.liveModeEnabled === true || data?.liveEnabled === true
  }

  function getPreviewMode(data = state.snapshot) {
    if (state.pendingPreviewMode !== null && now() < state.pendingPreviewUntil) return Number(state.pendingPreviewMode) || 0
    const value = Number(data?.previewMode ?? data?.previewIndex ?? 0)
    return value >= 1 && value <= 6 ? value : 0
  }

  function normalizeTimerMode(value) {
    const mode = String(value || '').trim().toLowerCase().replace(/[\s-]+/g, '_')
    if (mode === 'regressivo' || mode === 'regressive' || mode === 'countdown') return 'countdown'
    return 'progressive'
  }

  function getEffectiveTimerMode(data = state.snapshot) {
    if (state.optimisticTimerMode && now() < state.optimisticTimerModeUntil) return state.optimisticTimerMode

    // Depois que o Bridge publica o cronometro, o estado vivo da extensao e
    // autoritativo. O valor salvo no celular serve apenas como fallback antes
    // da primeira resposta do PC. Isso impede o app de reabrir no modo antigo.
    const bridgeMode = data?.timerMode ?? data?.timerType
    if (bridgeMode !== undefined && bridgeMode !== null && String(bridgeMode).trim() !== '') {
      return normalizeTimerMode(bridgeMode)
    }
    return normalizeTimerMode(readLocal('vshook_director_timer_mode', 'progressive'))
  }

  function clampCountdownPart(value, max) {
    const n = Math.floor(Number(value) || 0)
    return Math.max(0, Math.min(max, n))
  }

  function clampCountdownSec(value) {
    const n = Math.floor(Number(value) || 0)
    return Math.max(0, Math.min((99 * 3600) + (59 * 60) + 59, n))
  }

  function getCountdownTargetSec(data = state.snapshot) {
    // Quando o PC ja respondeu, usa primeiro o alvo publicado pela extensao.
    // O rascunho salvo no aparelho fica somente como fallback offline.
    const targetKeys = ['timerTargetSec', 'timerCountdownStartSec', 'timerCountdownSec', 'countdownSec']
    for (const key of targetKeys) {
      if (data && Object.prototype.hasOwnProperty.call(data, key)) {
        return clampCountdownSec(data[key])
      }
    }
    const draft = Number(readLocal('vshook_director_timer_countdown_sec', ''))
    if (Number.isFinite(draft) && draft > 0) return clampCountdownSec(draft)
    return clampCountdownSec(data?.timerDisplaySec ?? 0)
  }

  function timerNumber(value, fallback = 0) {
    const n = Number(value)
    return Number.isFinite(n) ? Math.max(0, n) : fallback
  }

  function timerSignedNumber(value, fallback = 0) {
    const n = Number(value)
    return Number.isFinite(n) ? n : fallback
  }

  function timerBridgeSignature(data = state.snapshot) {
    const mode = normalizeTimerMode(data?.timerMode || data?.timerType || 'progressive')
    return [
      mode,
      data?.timerRunning === true ? '1' : '0',
      timerNumber(data?.timerStartedAt || data?.timerStartedAtMs, 0).toFixed(0),
      timerNumber(data?.timerAccumulatedSec, 0).toFixed(3),
      timerNumber(data?.timerTargetSec ?? data?.timerCountdownStartSec, 0).toFixed(3),
      timerSignedNumber(data?.timerDisplaySec, 0).toFixed(3),
    ].join('|')
  }

  function syncLocalTimerFromBridge(data = state.snapshot) {
    if (!data || typeof data !== 'object') return
    if (now() < Number(state.timerLocalIgnoreBridgeUntil || 0)) return
    const hasTimer =
      Object.prototype.hasOwnProperty.call(data, 'timerRunning') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAt') ||
      Object.prototype.hasOwnProperty.call(data, 'timerStartedAtMs') ||
      Object.prototype.hasOwnProperty.call(data, 'timerDisplaySec') ||
      Object.prototype.hasOwnProperty.call(data, 'timerAccumulatedSec') ||
      Object.prototype.hasOwnProperty.call(data, 'timerTargetSec') ||
      Object.prototype.hasOwnProperty.call(data, 'timerCountdownStartSec')
    if (!hasTimer) return

    const mode = normalizeTimerMode(data.timerMode || data.timerType || state.timerLocal.mode || 'progressive')
    const target = mode === 'countdown'
      ? clampCountdownSec(data.timerTargetSec ?? data.timerCountdownStartSec ?? state.timerLocal.targetSec ?? getCountdownTargetSec(data))
      : clampCountdownSec(data.timerTargetSec ?? data.timerCountdownStartSec ?? state.timerLocal.targetSec ?? 0)
    const running = data.timerRunning === true
    const signature = timerBridgeSignature(data)
    if (state.timerLocal.initialized && state.timerLocal.signature === signature) return

    if (running) {
      const accumulated = timerNumber(data.timerAccumulatedSec, 0)
      const fallbackDisplay = mode === 'countdown'
        ? (target - accumulated)
        : accumulated
      const display = timerSignedNumber(data.timerDisplaySec, fallbackDisplay)
      const receivedAtMs = now()

      // timerStartedAt vem do relogio do PC. Usar esse epoch diretamente no
      // celular causa diferenca sempre que os dois aparelhos nao estao com a
      // hora absolutamente identica. Ancoramos no valor visual recebido e
      // continuamos localmente a partir do instante em que o snapshot chegou.
      state.timerLocal = {
        initialized: true,
        running: true,
        mode,
        baseSec: display,
        targetSec: target,
        startedAtMs: receivedAtMs,
        displaySec: display,
        signature,
      }

      writeLocal('vshook_director_timer_mode', mode)
      if (mode === 'countdown') writeLocal('vshook_director_timer_countdown_sec', target)
      return
    }

    const display = timerSignedNumber(data.timerDisplaySec, mode === 'countdown' ? target : timerNumber(data.timerAccumulatedSec, 0))
    state.timerLocal = {
      initialized: true,
      running: false,
      mode,
      baseSec: display,
      targetSec: target,
      startedAtMs: 0,
      displaySec: display,
      signature,
    }
    writeLocal('vshook_director_timer_mode', mode)
    if (mode === 'countdown') writeLocal('vshook_director_timer_countdown_sec', target)
  }

  function setLocalTimerMode(mode) {
    const normalized = normalizeTimerMode(mode)
    const target = getCountdownTargetSec(state.snapshot)
    state.timerLocal = {
      ...state.timerLocal,
      initialized: true,
      running: false,
      mode: normalized,
      baseSec: normalized === 'countdown' ? target : 0,
      targetSec: target,
      startedAtMs: 0,
      displaySec: normalized === 'countdown' ? target : 0,
      signature: `local-mode:${normalized}:${target}:${now()}`,
    }
  }

  function getLocalTimerSec() {
    const timer = state.timerLocal || {}
    if (!timer.initialized) return null
    const mode = normalizeTimerMode(timer.mode)
    const base = mode === 'countdown' ? timerSignedNumber(timer.baseSec, 0) : timerNumber(timer.baseSec, 0)
    if (!timer.running) return mode === 'countdown' ? timerSignedNumber(timer.displaySec, base) : timerNumber(timer.displaySec, base)
    const elapsed = Math.max(0, (now() - timerNumber(timer.startedAtMs, now())) / 1000)
    if (mode === 'countdown') return base - elapsed
    return base + elapsed
  }

  function applyLocalTimerToSnapshot(data = state.snapshot) {
    if (!state.timerLocal?.initialized || !data || typeof data !== 'object') return data
    const displaySec = getLocalTimerSec()
    const safeDisplay = displaySec === null
      ? (state.timerLocal.mode === 'countdown' ? timerSignedNumber(state.timerLocal.displaySec, 0) : timerNumber(state.timerLocal.displaySec, 0))
      : displaySec
    const countdownExpired = state.timerLocal.mode === 'countdown' && !!state.timerLocal.running && safeDisplay <= 0
    const targetSec = timerNumber(state.timerLocal.targetSec, 0)
    const accumulatedSec = state.timerLocal.mode === 'countdown'
      ? Math.max(0, targetSec - timerSignedNumber(state.timerLocal.baseSec, targetSec))
      : timerNumber(state.timerLocal.baseSec, 0)
    return {
      ...data,
      timerRunning: !!state.timerLocal.running,
      timerActive: !!state.timerLocal.running,
      timerEnabled: !!state.timerLocal.running,
      timerMode: state.timerLocal.mode,
      timerType: state.timerLocal.mode,
      timerStartedAt: state.timerLocal.running ? state.timerLocal.startedAtMs : 0,
      timerStartedAtMs: state.timerLocal.running ? state.timerLocal.startedAtMs : 0,
      timerAccumulatedSec: accumulatedSec,
      timerTargetSec: targetSec,
      timerCountdownStartSec: targetSec,
      timerDisplaySec: safeDisplay,
      timerElapsedSec: state.timerLocal.mode === 'countdown' ? Math.max(0, targetSec - safeDisplay) : Math.max(0, safeDisplay),
      timerExpired: countdownExpired,
      timerOverrun: countdownExpired,
      timerOverrunSec: countdownExpired ? Math.max(0, -safeDisplay) : 0,
      timerDisplayText: formatTimerTime(safeDisplay, countdownExpired),
    }
  }

  function splitCountdownSec(sec) {
    const safe = clampCountdownSec(sec)
    const hours = Math.floor(safe / 3600)
    const minutes = Math.floor((safe % 3600) / 60)
    const seconds = safe % 60
    return { hours, minutes, seconds }
  }

  function readCountdownInputs() {
    const h = clampCountdownPart(document.getElementById('timerCountdownHours')?.value, 99)
    const m = clampCountdownPart(document.getElementById('timerCountdownMinutes')?.value, 59)
    const s = clampCountdownPart(document.getElementById('timerCountdownSeconds')?.value, 59)
    return clampCountdownSec((h * 3600) + (m * 60) + s)
  }

  function applyCountdownTarget(sec, options = {}) {
    const target = clampCountdownSec(sec)
    writeLocal('vshook_director_timer_countdown_sec', target)
    const data = state.snapshot || {}
    if (normalizeTimerMode(state.timerLocal.mode) === 'countdown' && !state.timerLocal.running) {
      state.timerLocal = {
        ...state.timerLocal,
        initialized: true,
        mode: 'countdown',
        baseSec: target,
        targetSec: target,
        displaySec: target,
        startedAtMs: 0,
        signature: `local-target:${target}:${now()}`,
      }
    }
    state.snapshot = {
      ...data,
      timerMode: 'countdown',
      timerTargetSec: target,
      timerCountdownSec: target,
      countdownSec: target,
      timerDisplaySec: data.timerRunning ? data.timerDisplaySec : target,
      timerAccumulatedSec: data.timerRunning ? data.timerAccumulatedSec : target,
    }
    if (options.post !== false) postCommand('timer_set_target', getTimerCommandPayload({ timerMode: 'countdown', timerTargetSec: target }))
    if (options.render === false) {
      const preview = document.querySelector('.timerModalPreview')
      if (preview) preview.textContent = formatTimerTime(target)
    } else {
      scheduleRender(true)
    }
    return target
  }

  function isCountdownInputFocused() {
    return !!document.activeElement?.matches?.('[data-timer-countdown-input]')
  }

  function syncTimerModalDom() {
    if (!state.showTimerModal) return
    const data = state.snapshot || {}
    const preview = document.querySelector('.timerModalPreview')
    if (preview) preview.textContent = getTimerDisplayText(data)
  }

  function syncTimerDom() {
    const data = state.snapshot || {}
    const text = getTimerDisplayText(data)
    const overrun = isCountdownOverrun(data)
    const top = root.querySelector('.topTimerBtn')
    if (top) {
      top.textContent = text
      top.classList.toggle('timerOverrunBlink', overrun)
    }
    const preview = root.querySelector('.timerModalPreview')
    if (preview) preview.classList.toggle('timerOverrunBlink', overrun)
    if (state.showTimerModal) syncTimerModalDom()
  }

  function getTimerCommandPayload(extra = {}) {
    const data = state.snapshot || {}
    const mode = normalizeTimerMode(extra.timerMode || getEffectiveTimerMode(data))
    const target = clampCountdownSec(extra.timerTargetSec ?? getCountdownTargetSec(data))
    const base = {
      mode,
      timerMode: mode,
      ...extra,
    }
    if (mode !== 'countdown') {
      return {
        ...base,
        timerDisplaySec: Number.isFinite(Number(extra.timerDisplaySec)) ? Math.max(0, Number(extra.timerDisplaySec)) : 0,
        timerAccumulatedSec: Number.isFinite(Number(extra.timerAccumulatedSec)) ? Math.max(0, Number(extra.timerAccumulatedSec)) : 0,
      }
    }
    return {
      mode,
      timerMode: mode,
      timerTargetSec: target,
      targetSec: target,
      countdownSec: target,
      seconds: target,
      timerDisplaySec: mode === 'countdown' && !data.timerRunning ? target : getTimerSec({ ...data, timerMode: mode, timerTargetSec: target }),
      ...extra,
    }
  }

  function isCountdownOverrun(data = state.snapshot) {
    if (getEffectiveTimerMode(data) !== 'countdown' || data?.timerRunning !== true) return false
    if (data?.timerExpired === true || data?.timerOverrun === true || data?.timerNegative === true) return true
    return getTimerSec(data) <= 0
  }

  function getTimerDisplayText(data = state.snapshot) {
    return formatTimerTime(getTimerSec(data), isCountdownOverrun(data))
  }

  function setTimerModeOptimistic(mode) {
    const normalized = normalizeTimerMode(mode)
    state.optimisticTimerMode = normalized
    state.optimisticTimerModeUntil = now() + 12000
    writeLocal('vshook_director_timer_mode', normalized)
    setLocalTimerMode(normalized)
    const target = getCountdownTargetSec(state.snapshot)
    state.snapshot = {
      ...(state.snapshot || {}),
      timerMode: normalized,
      timerTargetSec: target,
      timerDisplaySec: normalized === 'countdown' ? target : 0,
      timerAccumulatedSec: normalized === 'countdown' ? target : 0,
      timerStartedAt: 0,
      timerStartedAtMs: 0,
      timerRunning: false,
    }
    state.snapshot = applyLocalTimerToSnapshot(state.snapshot)
    scheduleRender(true)
  }

  function applyTimerStartOptimistic() {
    const data = state.snapshot || {}
    const mode = getEffectiveTimerMode(data)
    const baseSec = mode === 'countdown' ? getCountdownTargetSec(data) : 0
    state.timerLocal = {
      initialized: true,
      running: true,
      mode,
      baseSec,
      targetSec: mode === 'countdown' ? baseSec : getCountdownTargetSec(data),
      startedAtMs: now(),
      displaySec: baseSec,
      signature: `local-start:${mode}:${baseSec}:${now()}`,
    }
    state.timerLocalIgnoreBridgeUntil = now() + 2200
    state.snapshot = {
      ...data,
      timerRunning: true,
      timerDisplaySec: baseSec,
      timerAccumulatedSec: baseSec,
      timerStartedAt: now(),
      timerStartedAtMs: now(),
    }
    state.snapshot = applyLocalTimerToSnapshot(state.snapshot)
    scheduleRender(true)
  }

  function applyTimerStopResetOptimistic() {
    const data = state.snapshot || {}
    const mode = getEffectiveTimerMode(data)
    state.timerLocal = {
      initialized: true,
      running: false,
      mode,
      baseSec: 0,
      targetSec: getCountdownTargetSec(data),
      startedAtMs: 0,
      displaySec: 0,
      signature: `local-stop:${mode}:${now()}`,
    }
    state.timerLocalIgnoreBridgeUntil = now() + 2200
    state.snapshot = {
      ...data,
      timerRunning: false,
      timerDisplaySec: 0,
      timerAccumulatedSec: 0,
      timerStartedAt: 0,
      timerStartedAtMs: 0,
    }
    state.snapshot = applyLocalTimerToSnapshot(state.snapshot)
    scheduleRender(true)
  }

  function handleTimerToggle() {
    const before = state.snapshot || {}
    const wasRunning = !!before.timerRunning
    const mode = getEffectiveTimerMode(before)
    if (wasRunning) {
      state.showConfirmTimerStop = true
      scheduleRender(true)
      return
    }
    const payload = getTimerCommandPayload({
      mode,
      timerMode: mode,
      timerRunning: true,
      running: true,
      timerDisplaySec: mode === 'countdown' ? getCountdownTargetSec(before) : 0,
      timerAccumulatedSec: mode === 'countdown' ? getCountdownTargetSec(before) : 0,
    })
    applyTimerStartOptimistic()
    postCommand('timer_start', payload)
  }

  function confirmTimerStop() {
    const before = state.snapshot || {}
    const mode = getEffectiveTimerMode(before)
    state.showConfirmTimerStop = false
    applyTimerStopResetOptimistic()
    postCommand('timer_stop_reset', getTimerCommandPayload({
      mode,
      timerMode: mode,
      timerRunning: false,
      running: false,
      timerDisplaySec: 0,
      timerAccumulatedSec: 0,
    }))
  }

  function getTimerSec(data = state.snapshot) {
    const mode = getEffectiveTimerMode(data)
    const local = getLocalTimerSec()
    if (local !== null && normalizeTimerMode(state.timerLocal.mode) === mode) return local
    const remote = Number(data?.timerDisplaySec)
    if (Number.isFinite(remote)) return mode === 'countdown' ? remote : Math.max(0, remote)
    const accumulated = Math.max(0, Number(data?.timerAccumulatedSec) || 0)
    if (!data?.timerRunning) return mode === 'countdown' ? (getCountdownTargetSec(data) - accumulated) : accumulated
    const started = Number(data?.timerStartedAt || data?.timerStartedAtMs || 0)
    if (!started) return mode === 'countdown' ? (getCountdownTargetSec(data) - accumulated) : accumulated
    const elapsed = Math.max(0, (now() - started) / 1000)
    if (mode === 'countdown') {
      const target = getCountdownTargetSec(data)
      return target - accumulated - elapsed
    }
    return accumulated + elapsed
  }

  function authEnabled(data = state.snapshot) {
    const enabled = data?.directorAuthEnabled ?? data?.authEnabled ?? data?.accessAuthEnabled
    const hash = getAuthHash(data)
    return !!hash && enabled !== false
  }

  function getAuthHash(data = state.snapshot) {
    return String(
      data?.directorAuthHash
      || data?.authHash
      || data?.accessAuthHash
      || data?.directorPasswordHash
      || data?.appDirectorAuthHash
      || ''
    ).trim().toUpperCase()
  }

  function getAuthRevision(data = state.snapshot) {
    return String(data?.directorAuthRevision || data?.authRevision || data?.accessAuthRevision || '').trim()
  }

  function syncAuthFromState(data) {
    if (state.pcAccessReleased) {
      state.authAuthenticated = false
      return
    }
    if (!authEnabled(data)) {
      state.authAuthenticated = true
      state.authError = ''
      return
    }
    const hash = getAuthHash(data)
    const saved = String(readLocal('vshook_access_session', '') || '').trim().toUpperCase()
    const revision = getAuthRevision(data)
    const savedRevision = String(readLocal('vshook_access_session_revision', '') || '').trim()
    const authenticated = !!(saved && saved === hash && (!revision || savedRevision === revision))
    if (!authenticated && (saved || savedRevision)) {
      removeLocal('vshook_access_session')
      removeLocal('vshook_access_session_revision')
    }
    if (state.authAuthenticated && !authenticated) state.directorSessionAnnounced = false
    state.authAuthenticated = authenticated
  }

  function returnToExistingAppShell() {
    if (window.__vshookReturningToExistingShell) return
    window.__vshookReturningToExistingShell = true
    try {
      localStorage.removeItem('vshook_selected_project')
      localStorage.removeItem('vshook_selected_mode')
      // Mantém a sessão autenticada durante a reconexão local.
    } catch (_) {}
    window.location.reload()
  }

  function handleDirectorLogoutRequest(data) {
    const requested = data?.forceDirectorLogout === true
      || data?.directorLogoutRequested === true
      || data?.logoutDirector === true
      || String(data?.directorCommand || data?.appCommand || data?.directorLogoutCommand || '').toLowerCase() === 'director_force_logout'
    if (!requested) return false

    const token = String(data?.directorLogoutToken || data?.logoutToken || '').trim()
    const command = String(data?.directorCommand || data?.appCommand || data?.directorLogoutCommand || 'director_force_logout').trim()
    const signature = token || `${command}|${String(data?.updatedAt || data?.stateUpdatedAt || '')}`

    // O pedido de logout permanece alguns segundos na extensao para chegar a
    // todos os Diretores conectados. Depois que este aparelho ja o atendeu e
    // voltou ao seletor, uma nova entrada nao pode ser expulsa pelo mesmo token.
    // O novo director_enter enviado logo abaixo limpa o pedido na extensao.
    const lastHandledToken = String(readLocal('vshook_last_handled_director_logout_token', '') || '').trim()
    if (token && token === lastHandledToken) return false
    if (signature && signature === state.lastDirectorLogoutSignature) return true

    state.lastDirectorLogoutSignature = signature
    if (token) writeLocal('vshook_last_handled_director_logout_token', token)
    state.pcAccessReleased = true
    state.directorSessionAnnounced = false
    state.directorClaimInFlight = false
    state.authPass = ''
    state.authError = ''
    state.showMenu = false
    state.showPlaylistModal = false
    state.showProjectModal = false
    state.showMarkersOverlay = false
    state.showTimerModal = false
    state.showSettingsModal = false
    state.showTunerScreen = false
    state.showTelepromptScreen = false
    state.showRecadosScreen = false

    const leaveDirector = () => returnToExistingAppShell()
    postCommand('director_force_logout_ack', {
      directorLogoutToken: token,
      logoutToken: token,
      directorCommand: command,
      appLogoutTarget: 'director',
      logoutTarget: 'director',
    }).finally(leaveDirector)
    setTimeout(leaveDirector, 450)
    return true
  }

  function ensureDirectorSessionClaimed() {
    if (!state.authAuthenticated || state.pcAccessReleased || state.directorSessionAnnounced || state.directorClaimInFlight) return

    // Ao entrar no Diretor com o transporte parado, nao mostra a fila antiga
    // enquanto a extensao limpa o cache nativo.
    if (!isPlaying(state.snapshot)) {
      state.queuedSongId = ''
      state.optimisticQueueClearedUntil = now() + 5000
    }

    state.directorClaimInFlight = true
    postCommand('director_enter', {
      sessionActive: true,
      authenticated: true,
      directorActive: true,
      appActive: true,
    }).then((response) => {
      if (response?.ok) state.directorSessionAnnounced = true
    }).finally(() => {
      state.directorClaimInFlight = false
    })
  }

  function postCommand(type, payload = {}) {
    const commandType = String(type || '')
    if (IS_MUSICIAN_MONITOR &&
        commandType !== 'director_family_drawers_sync') {
      return Promise.resolve({ ok: false, monitorOnly: true })
    }
    if (!commandType) return Promise.resolve(null)
    const queueInAnotherProject =
      commandType === 'queue_playlist_song' ||
      commandType === 'queue_region_song'
    const explicitPlayInAnotherProject =
      commandType === 'play_start' ||
      commandType === 'play' ||
      commandType === 'director_play_no_seek'
    const togglePlayInAnotherProject =
      (commandType === 'play_button' ||
       commandType === 'director_play_button' ||
       commandType === 'play_toggle') &&
      !isPlaying(state.snapshot || {})
    if ((queueInAnotherProject ||
         explicitPlayInAnotherProject ||
         togglePlayInAnotherProject) &&
        otherOpenProjectTransportActive()) {
      showPopup(
        'PARE A REPRODUÇÃO DA OUTRA ABA ANTES DE DAR PLAY OU USAR A FILA DE ESPERA',
        'error', 2200)
      return Promise.resolve({
        ok: false,
        blockedByOtherProjectPlayback: true,
      })
    }
    const optimisticHoldUntil = now() + 700
    state.sharedControlsLocalUntil = Math.max(
      Number(state.sharedControlsLocalUntil || 0),
      optimisticHoldUntil)
    if (commandType.includes('queue') ||
        commandType.includes('stop') ||
        commandType === 'autoplay_set' ||
        commandType === 'autoplay2_set') {
      state.queuedSongLocalUntil = Math.max(
        Number(state.queuedSongLocalUntil || 0),
        optimisticHoldUntil)
    }
    if (commandType.includes('select') ||
        commandType.includes('stop') ||
        commandType.includes('marker') ||
        commandType === 'clear_selection') {
      state.sharedSelectionLocalUntil = Math.max(
        Number(state.sharedSelectionLocalUntil || 0),
        optimisticHoldUntil)
    }
    if (commandType === 'set_page') {
      state.activeTabLocalUntil = Math.max(
        Number(state.activeTabLocalUntil || 0),
        optimisticHoldUntil)
    }
    const bodyPayload = {
      ...(payload && typeof payload === 'object' ? payload : {}),
      role: 'director',
      clientRole: 'director',
      appRole: 'director',
      source: 'director',
      // Alguns comandos usam `mode` como dado funcional (auto/mute/solo,
      // cronometro etc.). Nao sobrescreve esse valor com o papel do app.
      mode: payload && payload.mode !== undefined && payload.mode !== null && payload.mode !== '' ? payload.mode : 'director',
      controlMode: 'director',
      clientCommandId: `${Date.now()}-${commandType}-${Math.random().toString(16).slice(2, 8)}`,
    }
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    return fetch(bridgeUrl('/command'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: commandType, payload: bodyPayload }),
      signal: abort.signal,
    }).catch(() => null).finally(abort.done)
  }

  function getInterfaceBlockingEnabled(data = state.snapshot) {
    if (typeof state.pendingInterfaceBlocking === 'boolean') {
      return state.pendingInterfaceBlocking
    }
    return data?.blockInterfaceWhenDirectorConnected !== false
  }

  function dismissInterfaceAccessButton() {
    if (interfaceAccessButtonTimer) {
      window.clearTimeout(interfaceAccessButtonTimer)
      interfaceAccessButtonTimer = 0
    }
    const button = document.getElementById('directorInterfaceAccessButton')
    if (!button) return
    button.classList.remove('directorInterfaceAccessButtonVisible')
    window.setTimeout(() => {
      if (!button.classList.contains('directorInterfaceAccessButtonVisible')) {
        button.remove()
      }
    }, 320)
  }

  function allowLocalInterfaceFromDirector() {
    dismissInterfaceAccessButton()
    state.pendingInterfaceBlocking = false
    state.snapshot = {
      ...(state.snapshot || {}),
      blockInterfaceWhenDirectorConnected: false,
      directorInterfaceBlocked: false,
      sharedControl: true,
      exclusiveControl: false,
      controlMode: 'shared',
    }
    postCommand('director_allow_local_interface', {
      allow: true,
      keepDirectorConnected: true,
    })
    scheduleRender(true)
  }

  function showInterfaceAccessButton() {
    if (IS_MUSICIAN_MONITOR || state.hideInterfaceAccessNotification) return
    let button = document.getElementById('directorInterfaceAccessButton')
    if (!button) {
      button = document.createElement('button')
      button.id = 'directorInterfaceAccessButton'
      button.type = 'button'
      button.className = 'directorInterfaceAccessButton'
      button.textContent = 'PERMITIR'
      button.setAttribute('aria-label', 'Permitir controle da interface no computador')
      button.addEventListener('click', allowLocalInterfaceFromDirector)
      document.body.appendChild(button)
    }
    if (interfaceAccessButtonTimer) {
      window.clearTimeout(interfaceAccessButtonTimer)
    }
    button.classList.remove('directorInterfaceAccessButtonVisible')
    void button.offsetWidth
    button.classList.add('directorInterfaceAccessButtonVisible')
    interfaceAccessButtonTimer = window.setTimeout(
      dismissInterfaceAccessButton, 5000)
  }

  function syncBlockedInterfaceAttempt(data = state.snapshot) {
    const revision = String(
      data?.blockedInterfaceAttemptRevision ?? '0')
    if (state.lastBlockedInterfaceAttemptRevision === null) {
      state.lastBlockedInterfaceAttemptRevision = revision
      return
    }
    if (revision === state.lastBlockedInterfaceAttemptRevision) return
    state.lastBlockedInterfaceAttemptRevision = revision
    if (!state.hideInterfaceAccessNotification) {
      showInterfaceAccessButton()
    }
  }

  function syncProjectPlaylistSwitchBlocked(data = state.snapshot) {
    const revision = String(
      data?.projectPlaylistSwitchBlockedRevision ?? '0')
    if (state.lastProjectPlaylistSwitchBlockedRevision === null) {
      state.lastProjectPlaylistSwitchBlockedRevision = revision
      return
    }
    if (revision ===
        state.lastProjectPlaylistSwitchBlockedRevision) return
    state.lastProjectPlaylistSwitchBlockedRevision = revision
    showPopup(
      data?.projectPlaylistSwitchBlockedMessage ||
        'PARE A REPRODUÇÃO DA OUTRA ABA ANTES DE TROCAR DE REPERTÓRIO, DAR PLAY OU USAR A FILA DE ESPERA',
      'error', 2200)
  }

  function syncMultiProjectPlaylistsPreference(data = state.snapshot) {
    if (typeof state.pendingMultiProjectPlaylists !== 'boolean') return
    if (!getMultiProjectPlaylistsAvailable(data)) {
      state.pendingMultiProjectPlaylists = null
      return
    }
    const remote =
      data?.multiProjectPlaylistsEnabled === true ||
      data?.showAllProjectPlaylists === true
    if (remote === state.pendingMultiProjectPlaylists) {
      state.pendingMultiProjectPlaylists = null
    }
  }

  function syncInterfaceBlockingPreference(data = state.snapshot) {
    if (typeof state.pendingInterfaceBlocking !== 'boolean') return
    const remote = data?.blockInterfaceWhenDirectorConnected !== false
    if (remote === state.pendingInterfaceBlocking) {
      state.pendingInterfaceBlocking = null
    }
  }

  function wantsTrackMeters() {
    if (IS_MUSICIAN_MONITOR || document.visibilityState === 'hidden') return false
    if (!state.authAuthenticated || state.pcAccessReleased) return false
    return state.activeTab === 'mixer' || state.activeTab === 'premix' || state.showPremixScreen
  }

  function getTrackMeterIdentity(item) {
    const id = String(item?.trackId ?? item?.trackGuid ?? item?.guid ?? item?.id ?? '').trim()
    const rawIndex = Number(item?.trackIndex ?? item?.index)
    const index = Number.isFinite(rawIndex) ? Math.trunc(rawIndex) : -1
    return { id, index }
  }

  function renderTrackMeter(item) {
    const identity = getTrackMeterIdentity(item)
    return `<div class="trackMeter" data-track-meter data-track-meter-id="${escapeHtml(identity.id)}" data-track-meter-index="${identity.index}" aria-hidden="true"><span class="trackMeterLane"><span class="trackMeterBar trackMeterBarL"></span></span><span class="trackMeterLane"><span class="trackMeterBar trackMeterBarR"></span></span></div>`
  }

  function meterPeakPercent(value) {
    const peak = Math.max(0, Number(value) || 0)
    if (peak <= 0.000001) return 0
    const db = 20 * Math.log10(peak)
    return Math.max(0, Math.min(100, ((Math.max(-60, Math.min(6, db)) + 60) / 66) * 100))
  }

  function getTrackMeterReading(id, index) {
    const snapshot = state.meterSnapshot
    if (!snapshot || snapshot.active !== true) return null
    if (index === 0 || String(id || '').toUpperCase() === 'MASTER_TRACK') return snapshot.master || null
    const rows = Array.isArray(snapshot.tracks) ? snapshot.tracks : []
    const wantedId = String(id || '')
    if (wantedId) {
      for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
        const row = rows[rowIndex]
        if (String(row?.id ?? row?.guid ?? '') === wantedId) return row
      }
    }
    if (index > 0) {
      for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
        if (Number(rows[rowIndex]?.index) === index) return rows[rowIndex]
      }
    }
    return null
  }

  function syncTrackMetersDom() {
    root.querySelectorAll('[data-track-meter]').forEach((meter) => {
      const id = String(meter.getAttribute('data-track-meter-id') || '')
      const index = Number(meter.getAttribute('data-track-meter-index'))
      const reading = getTrackMeterReading(id, Number.isFinite(index) ? index : -1)
      const left = Math.max(0, Number(reading?.peakL) || 0)
      const right = Math.max(0, Number(reading?.peakR) || 0)
      const leftBar = meter.querySelector('.trackMeterBarL')
      const rightBar = meter.querySelector('.trackMeterBarR')
      if (leftBar) leftBar.style.width = `${meterPeakPercent(left)}%`
      if (rightBar) rightBar.style.width = `${meterPeakPercent(right)}%`
      meter.classList.toggle('trackMeterWarn', (left > 0.5 || right > 0.5) && left <= 1 && right <= 1)
      meter.classList.toggle('trackMeterOver', left > 1 || right > 1)
    })
  }

  function syncMixerRowsDom() {
    if (state.activeTab !== 'mixer') return
    root.querySelectorAll('.mixerRow[data-mixer-id]').forEach((row) => {
      const id = String(row.getAttribute('data-mixer-id') || '')
      const snapshotItem = findMixerTrackById(id)
      if (!snapshotItem) return
      const identity = getTrackMeterIdentity(snapshotItem)
      const reading = getTrackMeterReading(identity.id, identity.index)
      const liveItem = reading ? {
        ...snapshotItem,
        mute: reading.mute === true,
        muted: reading.mute === true,
        solo: reading.solo === true,
        soloed: reading.solo === true,
        volume: reading.volume,
        volumeRatio: reading.volumeRatio,
        db: reading.db,
      } : snapshotItem
      const muted = getHeldMixerToggle(liveItem, 'mute')
      const solo = getHeldMixerToggle(liveItem, 'solo')
      const muteButton = row.querySelector('[data-action="mixer-mute"]')
      const soloButton = row.querySelector('[data-action="mixer-solo"]')
      if (muteButton) {
        muteButton.classList.toggle('mixerMiniBtnActive', muted)
        muteButton.setAttribute('aria-pressed', muted ? 'true' : 'false')
      }
      if (soloButton) {
        soloButton.classList.toggle('mixerMiniBtnActive', solo)
        soloButton.setAttribute('aria-pressed', solo ? 'true' : 'false')
      }
      const dbText = formatMixerDb(liveItem)
      const groupDisplay = row.querySelector('.mixerRowGroupName')
      const dbDisplay = row.querySelector('.mixerRowDb')
      if (groupDisplay) groupDisplay.textContent = dbText
      if (dbDisplay) dbDisplay.textContent = dbText
    })
  }

  function stopTrackMeterPolling() {
    if (meterPollTimer) window.clearTimeout(meterPollTimer)
    meterPollTimer = 0
    state.meterSnapshot = null
    syncTrackMetersDom()
  }

  async function pollTrackMeters() {
    if (!wantsTrackMeters()) {
      stopTrackMeterPolling()
      return
    }
    if (state.meterPollInFlight) return
    state.meterPollInFlight = true
    const abort = withTimeout(700)
    let delay = METER_POLL_MS
    try {
      const response = await fetch(bridgeUrl('/meters'), { cache: 'no-store', signal: abort.signal })
      if (!response.ok) throw new Error(`meters ${response.status}`)
      const data = await response.json()
      state.meterSnapshot = data && typeof data === 'object' ? data : null
      syncTrackMetersDom()
      syncMixerRowsDom()
    } catch (_) {
      delay = 180
    } finally {
      abort.done()
      state.meterPollInFlight = false
      if (wantsTrackMeters()) meterPollTimer = window.setTimeout(pollTrackMeters, delay)
      else stopTrackMeterPolling()
    }
  }

  function syncTrackMeterPolling() {
    if (!wantsTrackMeters()) {
      stopTrackMeterPolling()
      return
    }
    if (!meterPollTimer && !state.meterPollInFlight) meterPollTimer = window.setTimeout(pollTrackMeters, 0)
  }

  function commitStopPauseModeToBridge(enabled, requestToken, attempt = 0) {
    if (state.pendingStopPauseModeRequestToken !== requestToken) return
    postCommand('stop_pause_mode_set', {
      enabled: !!enabled,
      stopPauseModeEnabled: !!enabled,
      desiredState: enabled ? 'on' : 'off',
      stopPauseRequestToken: requestToken,
    }).then(() => {
      if (state.pendingStopPauseModeRequestToken !== requestToken) return
      window.setTimeout(pollBridge, 80)
      // Reenvio idempotente curto: evita perder a alteração se o usuário
      // devolver o controle ao PC imediatamente depois de tocar no botão.
      if (attempt < 2) {
        const delay = attempt === 0 ? 220 : 520
        window.setTimeout(() => commitStopPauseModeToBridge(enabled, requestToken, attempt + 1), delay)
      }
    })
  }

  async function pollBridge() {
    if (isDirectorRecadosInputFocused()) return
    if (state.pollInFlight) return
    state.pollInFlight = true
    const abort = withTimeout(POLL_TIMEOUT_MS)
    try {
      const bridgeWasOnline = state.bridgeOnline
      const response = await fetch(bridgeUrl('/state'), { cache: 'no-store', signal: abort.signal })
      if (!response.ok) throw new Error(`state ${response.status}`)
      const data = await response.json()
      state.snapshot = mergeWithLastGoodSnapshot(data && typeof data === 'object' ? data : {}, state.snapshot)
      syncSharedInterfaceState(state.snapshot)
      syncInterfaceBlockingPreference(state.snapshot)
      syncBlockedInterfaceAttempt(state.snapshot)
      syncProjectPlaylistSwitchBlocked(state.snapshot)
      syncMultiProjectPlaylistsPreference(state.snapshot)
      syncVisualTransportState(state.snapshot)
      syncTabletFadeoutFromSnapshot(state.snapshot)
      syncPendingTransportPlaying(state.snapshot)
      syncLocalTimerFromBridge(state.snapshot)
      state.snapshot = applyLocalTimerToSnapshot(state.snapshot)
      syncFamilyDrawersFromBridge(state.snapshot)
      restoreOpenHashDrawerFamily(state.snapshot)
      // A próxima mídia de cada TP é aquecida em todo snapshot, mesmo quando
      // a tela de TP ainda não está aberta. Assim ela já está no dispositivo
      // quando o cursor alcançar o item.
      reconcileDirectorTelepromptMediaWarmups(
        state.snapshot)
      state.bridgeOnline = true
      if (!bridgeWasOnline) nativeFamilyDrawersLastSignature = null
      state.lastGoodAt = now()
      state.lastPollAt = now()

      if (IS_MUSICIAN_MONITOR) {
        // Monitor passivo: acompanha Repertório/Músicas publicados pela extensão,
        // sem executar rotinas de sessão, seleção, fila, Parts, Premix ou transporte.
        state.authAuthenticated = true
        state.showMenu = false
        state.showMarkersOverlay = false
        state.showPlaylistModal = false
        state.showProjectModal = false
        state.showTimerModal = false
        state.showTunerScreen = false
        state.showRecadosScreen = false
        state.showTransportSeekModal = false
        state.showPremixScreen = false
        state.showMixerVolume = false
      } else {
        const forcedDirectorLogout = handleDirectorLogoutRequest(state.snapshot)
        if (state.pendingAutoBloco !== null && state.snapshot?.autoBlocoEnabled === state.pendingAutoBloco) state.pendingAutoBloco = null
        if (state.pendingAutoStop !== null) {
          const bridgeAutoStop = state.snapshot?.autoStopEnabled !== false && state.snapshot?.autostopEnabled !== false
          if (bridgeAutoStop === state.pendingAutoStop) state.pendingAutoStop = null
        }
        if (state.pendingStopPauseMode !== null) {
          const hasBridgeStopPause = typeof state.snapshot?.stopPauseModeEnabled === 'boolean' ||
            typeof state.snapshot?.editModeStopPauseEnabled === 'boolean'
          const bridgeStopPause = state.snapshot?.stopPauseModeEnabled === true || state.snapshot?.editModeStopPauseEnabled === true
          if (hasBridgeStopPause && bridgeStopPause === state.pendingStopPauseMode) {
            state.pendingStopPauseMode = null
            state.pendingStopPauseModeUntil = 0
            state.pendingStopPauseModeRequestToken += 1
          } else if (now() >= Number(state.pendingStopPauseModeUntil || 0)) {
            state.pendingStopPauseMode = null
            state.pendingStopPauseModeUntil = 0
            state.pendingStopPauseModeRequestToken += 1
            showPopup('STOP/PAUSE NÃO SINCRONIZADO', 'error', 1600)
          }
        }
        if (state.pendingLoop !== null && state.snapshot?.loopActive === state.pendingLoop) {
          state.pendingLoop = null
          state.pendingLoopUntil = 0
        }
        if (state.pendingMultiLoopBypass !== null) {
          const bridgeBypass = state.snapshot?.multiloops?.bypassActive === true
          if (bridgeBypass === state.pendingMultiLoopBypass || now() >= Number(state.pendingMultiLoopBypassUntil || 0)) {
            state.pendingMultiLoopBypass = null
            state.pendingMultiLoopBypassUntil = 0
          }
        }
        if (!state.selectedPlaylistSongId && now() >= Number(state.playlistSelectionClearedUntil || 0) && state.snapshot?.selectedPlaylistSongId != null) state.selectedPlaylistSongId = String(state.snapshot.selectedPlaylistSongId)
        if (!state.selectedRegionId && now() >= Number(state.regionSelectionClearedUntil || 0) && state.snapshot?.selectedRegionId != null) state.selectedRegionId = String(state.snapshot.selectedRegionId)
        if (!state.selectedMarkerId && state.snapshot?.selectedMarkerId != null) state.selectedMarkerId = String(state.snapshot.selectedMarkerId)
        if (!forcedDirectorLogout) syncAuthFromState(state.snapshot)
        syncActivePlaylistConfirmation(state.snapshot)
        ensureDirectorSessionClaimed()
        syncNativeFamilyDrawers()
        syncQueueWhenQueuedSongStarts()
        syncPartsSourceOnPlayingChange(state.snapshot)
        syncPartsTakeoverFromSnapshot(state.snapshot)
        syncPartsMarkerStateFromSnapshot(state.snapshot)
        processTabletPartCountdownPopup(state.snapshot)
        processTabletMultiLoopBypassWarning(state.snapshot)
        syncDirectorRecadosFromSnapshot(state.snapshot)
      }
      scheduleRender()
    } catch (_) {
      // Uma leitura perdida no Wi-Fi não apaga a interface nem força um
      // redesenho completo. Só assume offline após perder o estado nativo por
      // alguns segundos; até lá mantém o último snapshot confirmado.
      const bridgeReallyOffline =
        !state.lastGoodAt || (now() - state.lastGoodAt) > 3200
      if (bridgeReallyOffline) {
        state.bridgeOnline = false
        nativeFamilyDrawersLastSignature = null
      }
      state.lastPollAt = now()
      if (bridgeReallyOffline) scheduleRender()
    } finally {
      abort.done()
      state.pollInFlight = false
    }
  }

  function hasAnyListData(data) {
    return !!(
      (Array.isArray(data?.playlists) && data.playlists.length) ||
      (Array.isArray(data?.regions) && data.regions.length) ||
      (Array.isArray(data?.markers) && data.markers.length)
    )
  }

  function hasRenderableListContent(data) {
    const lists = [getPlaylistItems(data), getRegions(data), getMarkers(data)]
    return lists.some((items) => Array.isArray(items) && items.some((item) => getName(item) || isBlock(item)))
  }

  function mergeWithLastGoodSnapshot(next, previous) {
    // O snapshot de descoberta é deliberadamente leve. Depois que o Diretor
    // já recebeu o estado completo, ele nunca pode substituir transporte,
    // fila, controles e listas pelo estado vazio de standby.
    if (next?.standby === true && previous && hasAnyListData(previous)) {
      const merged = { ...previous }
      const discoveryKeys = [
        'ok', 'connected', 'nativeBridge', 'bridgeVersion',
        'extensionVersion', 'updatedAt', 'heartbeatAt',
        'projectName', 'currentProjectName', 'projectPath',
        'projects', 'projectTabs', 'openProjects',
        'openProjectPlaylists', 'allProjectPlaylists',
        'activeProjectTabIndex', 'directorAuthEnabled',
        'authEnabled', 'accessAuthEnabled', 'directorAuthHash',
        'authHash', 'accessAuthHash', 'directorPasswordHash',
        'recadosAuthEnabled', 'technicalNoticeAuthEnabled',
        'recadosAuthHash', 'technicalNoticeAuthHash',
        'technicalNoticeSettings', 'technicalNotice',
      ]
      for (const key of discoveryKeys) {
        if (Object.prototype.hasOwnProperty.call(next, key)) {
          merged[key] = next[key]
        }
      }
      merged.standby = true
      merged.listPreservedFromLastGood = true
      return merged
    }
    if (!previous || !hasAnyListData(previous) || hasAnyListData(next)) return next
    const merged = { ...next }
    // Uma lista vazia em snapshot completo é um estado real (por exemplo,
    // projeto sem repertórios). Só preserva dados antigos quando a propriedade
    // não veio no payload.
    if (!Array.isArray(next.playlists) &&
        Array.isArray(previous.playlists)) {
      merged.playlists = previous.playlists
    }
    if (!Array.isArray(next.regions) &&
        Array.isArray(previous.regions)) {
      merged.regions = previous.regions
    }
    if (!Array.isArray(next.markers) &&
        Array.isArray(previous.markers)) {
      merged.markers = previous.markers
    }
    if (!Array.isArray(next.openProjectPlaylists) &&
        Array.isArray(previous.openProjectPlaylists)) {
      merged.openProjectPlaylists =
        previous.openProjectPlaylists
    }
    if (!Array.isArray(next.allProjectPlaylists) &&
        Array.isArray(previous.allProjectPlaylists)) {
      merged.allProjectPlaylists =
        previous.allProjectPlaylists
    }
    if (!Object.prototype.hasOwnProperty.call(next, 'currentPlaylistName') &&
        previous.currentPlaylistName) {
      merged.currentPlaylistName = previous.currentPlaylistName
    }
    if (!Object.prototype.hasOwnProperty.call(next, 'activePlaylistId') &&
        previous.activePlaylistId != null) {
      merged.activePlaylistId = previous.activePlaylistId
    }
    if (!Object.prototype.hasOwnProperty.call(next, 'currentProjectName') &&
        previous.currentProjectName) {
      merged.currentProjectName = previous.currentProjectName
    }
    if (!Object.prototype.hasOwnProperty.call(next, 'projectName') &&
        previous.projectName) {
      merged.projectName = previous.projectName
    }
    merged.listPreservedFromLastGood = true
    return merged
  }

  function syncQueueWhenQueuedSongStarts() {
    const playingId = getPlayingId()
    const queuedId = getQueuedId()
    if (!playingId || !queuedId || playingId !== queuedId || getAutoplayEnabled()) return
    state.queuedSongId = ''
    state.optimisticQueueClearedUntil = now() + 5000
  }

  function sendHeartbeat() {
    if (IS_MUSICIAN_MONITOR) return
    if (!state.authAuthenticated || state.pcAccessReleased) return
    if (!state.directorSessionAnnounced) {
      ensureDirectorSessionClaimed()
      return
    }
    postCommand('app_heartbeat', {
      heartbeat: true,
      sessionActive: true,
      authenticated: true,
      directorActive: true,
      appActive: true,
      role: 'director',
      clientRole: 'director',
      appRole: 'director',
    })
  }

  function renderAuthGate() {
    document.documentElement.classList.add('directorLoginPortraitMode')
    const error = `<div class="authGateError" aria-live="polite">${escapeHtml(state.authError || '')}</div>`
    return `
      <div class="authGateApp">
        <div class="authGateWrap">
          <div class="authGateCard">
            <div class="appBootLoaderGlow"></div>
            <img class="authGateLogo" src="./vshook-icon.png" alt="VS Hook" />
            <div class="authGateTitle">VS HOOK</div>
            <div class="authGateSubtitle">DIRETOR</div>
            <div class="authGateForm">
              <label class="authGatePassWrap" for="directorPassInput" aria-label="Senha do Diretor">
                <input class="authGateInput authGateInputWithToggle" id="directorPassInput" type="${state.showPassword ? 'text' : 'password'}" value="${escapeHtml(state.authPass)}" placeholder="Senha do Diretor" autocomplete="current-password" autocapitalize="none" autocorrect="off" spellcheck="false" enterkeyhint="go" />
                <button class="authGatePassToggle" data-action="toggle-password" type="button" aria-label="Mostrar senha">◉</button>
              </label>
              ${error}
              <button class="authGateButton" data-action="auth-login">ACESSAR</button>
            </div>
          </div>
        </div>
      </div>
    `
  }

  function popupHtml() {
    if (state.tabletFadeoutRuntimeActive) return '<div class="directorPopup directorPopup-info tabletFadeoutPersistentPopup">FADEROUT...</div>'
    if (!state.popupText || now() >= state.popupUntil) return ''
    return `<div class="directorPopup directorPopup-${escapeHtml(state.popupKind || 'info')}">${escapeHtml(state.popupText)}</div>`
  }

  function syncDirectorPopupDom() {
    const app = directChildByClass(root, 'app')
    if (!app) return
    let popup = null
    for (const child of Array.from(app.children || [])) {
      if (child.classList?.contains('directorPopup')) {
        popup = child
        break
      }
    }
    const fadeoutActive =
      state.tabletFadeoutRuntimeActive === true
    const visible =
      fadeoutActive ||
      (!!state.popupText && now() < state.popupUntil)
    if (!visible) {
      if (popup) popup.remove()
      return
    }
    if (!popup) {
      popup = document.createElement('div')
      app.appendChild(popup)
    }
    popup.className = fadeoutActive
      ? 'directorPopup directorPopup-info tabletFadeoutPersistentPopup'
      : `directorPopup directorPopup-${String(state.popupKind || 'info')}`
    popup.textContent =
      fadeoutActive ? 'FADEROUT...' : String(state.popupText || '')
  }

  function stopPauseModePopupHtml(data = state.snapshot) {
    if (IS_MUSICIAN_MONITOR || !getStopPauseModeEnabled(data)) return ''
    return '<div class="directorStopPausePersistentPopup" role="status" aria-live="polite">STOP/PAUSE ATIVO</div>'
  }

  function itemHasLiveMark(item, data = state.snapshot) {
    if (!item || isBlock(item) || !getLiveEnabled(data)) return false
    const id = String(getId(item) || '')
    if (liveMarkIndexSnapshot !== data || !liveMarkIndex) {
      const canonicalById = new Map()
      // Regiões são a fonte canônica. A cópia do repertório só complementa
      // IDs ausentes, impedindo uma flag antiga de sobreviver ao reset.
      for (const candidate of getRegions(data)) {
        const candidateId = String(getId(candidate) || '')
        if (candidateId) canonicalById.set(candidateId, candidate)
      }
      for (const candidate of getPlaylistItems(data)) {
        const candidateId = String(getId(candidate) || '')
        if (candidateId && !canonicalById.has(candidateId)) {
          canonicalById.set(candidateId, candidate)
        }
      }
      const markedIds = new Set()
      const childrenByParent = new Map()
      for (const [candidateId, candidate] of canonicalById) {
        if (candidate?.liveExecuted === true || candidate?.liveMarked === true) {
          markedIds.add(candidateId)
        }
        if (!isHashChild(candidate)) continue
        const parentId = String(
          candidate?.parentId ?? candidate?.parentRegionId ??
          candidate?.parentSourceNumber ?? candidate?.parent_source_number ??
          candidate?.parent_region_number ?? ''
        )
        if (!parentId) continue
        if (!childrenByParent.has(parentId)) childrenByParent.set(parentId, [])
        childrenByParent.get(parentId).push(candidateId)
      }
      liveMarkIndexSnapshot = data
      liveMarkIndex = { markedIds, childrenByParent }
    }

    if (isHashParent(item)) {
      const children = liveMarkIndex.childrenByParent.get(id) || []
      // A região-pai nunca completa pelo próprio tempo: somente quando todos
      // os filhos publicados pela extensão estiverem marcados.
      if (children.length) {
        return children.every((childId) =>
          liveMarkIndex.markedIds.has(childId))
      }
    }
    return !!id && liveMarkIndex.markedIds.has(id)
  }

  function rowClass(type, item) {
    const id = getId(item)
    const data = state.snapshot || {}
    const playingId = getPlayingId(data)
    const queuedId = getQueuedId(data)
    const selectedId = type === 'playlist' ? getSelectedPlaylistId(data) : type === 'region' ? getSelectedRegionId(data) : getSelectedMarkerId(data)
    const familySelectedId = isHashChild(item) ? String(state.selectedRegionId || '') : ''
    const classes = ['item']
    if (isBlock(item)) classes.push('blockItem')
    if (isHashChild(item)) classes.push('hashChildItem')
    if (itemHasLiveMark(item, data)) classes.push('liveExecutedItem')
    if (type === 'marker' && id && state.partsArmedMarkerId === id && now() < state.partsArmedMarkerUntil) classes.push('partsMarkerArmed')
    else if (type === 'marker' && id && state.partsLocalSelectedMarkerId === id) classes.push('partsMarkerLocalSelected')
    if (rowRepresentsPlayingSong(item, data)) classes.push('playing')
    else if (!isPlaying(data) && id && ((selectedId && id === selectedId) || (familySelectedId && id === familySelectedId))) classes.push(isBlock(item) ? 'selectedPink' : 'selectedBlue')
    else if (id && queuedId && id === queuedId) classes.push(getQueuedRowClass(data))
    return classes.join(' ')
  }

  function tunerRowClass(type, item, data = state.snapshot) {
    const id = String(getId(item) || '')
    const classes = rowClass(type, item).split(/\s+/).filter((name) =>
      name && name !== 'playing' && name !== 'queuedYellow' && name !== 'queuedGreen' && name !== 'selectedBlue' && name !== 'selectedPink')
    const playingId = getPlayingId(data)
    const queuedId = getQueuedId(data)
    const selectedId = type === 'playlist' ? getSelectedPlaylistId(data) : getSelectedRegionId(data)
    const childSelectedId = isHashChild(item) ? String(state.selectedRegionId || '') : ''
    if (id && id === playingId) classes.push('playing')
    else if (!isPlaying(data) && id && (id === selectedId || id === childSelectedId)) classes.push(isBlock(item) ? 'selectedPink' : 'selectedBlue')
    else if (id && id === queuedId) classes.push(getQueuedRowClass(data))
    return classes.join(' ')
  }

  function tunerTextClass(type, item, data = state.snapshot) {
    const id = String(getId(item) || '')
    if (id && id === getPlayingId(data)) return 'playingText'
    const selectedId = type === 'playlist' ? getSelectedPlaylistId(data) : getSelectedRegionId(data)
    const childSelectedId = isHashChild(item) ? String(state.selectedRegionId || '') : ''
    if (!isPlaying(data) && id && (id === selectedId || id === childSelectedId)) return isBlock(item) ? 'selectedPinkText' : 'selectedBlueText'
    if (id && id === getQueuedId(data)) return getQueuedTextClass(data)
    return 'text'
  }

  function textClass(type, item) {
    const id = getId(item)
    const data = state.snapshot || {}
    const playingId = getPlayingId(data)
    const queuedId = getQueuedId(data)
    const selectedId = type === 'playlist' ? getSelectedPlaylistId(data) : type === 'region' ? getSelectedRegionId(data) : getSelectedMarkerId(data)
    const familySelectedId = isHashChild(item) ? String(state.selectedRegionId || '') : ''
    if (rowRepresentsPlayingSong(item, data)) return 'playingText'
    if (!isPlaying(data) && id && ((selectedId && id === selectedId) || (familySelectedId && id === familySelectedId))) return isBlock(item) ? 'selectedPinkText' : 'selectedBlueText'
    if (id && queuedId && id === queuedId) return getQueuedTextClass(data)
    return 'text'
  }

  function timeClass(type, item) {
    return textClass(type, item).replace('Text', 'TimeText') === textClass(type, item) ? 'timeText' : textClass(type, item).replace('Text', 'TimeText')
  }

  function cleanBlockDisplayName(value, blockNumber) {
    const raw = upperText(value || '')
      .replace(/[:：]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
    const fallback = `BLOCO ${String(blockNumber || 1).padStart(2, '0')}`
    if (!raw || raw === 'BLOCO') return fallback
    return raw
  }

  function getRowDisplayName(item, index, blockNumber) {
    if (item?.partsDisplayName) return upperText(item.partsDisplayName)
    if (isBlock(item)) return cleanBlockDisplayName(getName(item), blockNumber)
    return upperText(getName(item) || `ITEM ${index + 1}`)
  }

  function getPartsSongStartRowClasses(item, data = state.snapshot) {
    if (!item?.partsSongStart) return ''
    if (!isPlaying(data)) return 'partsSongStartPart partsSongStartStopped'

    // A origem da tela Parts pode continuar como "selected" logo depois do Play.
    // A borda precisa seguir o estado real da música, não a origem usada para abrir a coluna.
    const songId = String(item.songId || '')
    const playingId = getPlayingId(data)
    const queuedId = getQueuedId(data)
    if (songId && playingId && songId === playingId) return 'partsSongStartPart partsSongStartPlaying'
    if (songId && queuedId && songId === queuedId) return 'partsSongStartPart partsSongStartQueued'

    // Fallback para snapshots antigos que ainda não publicam IDs consistentes.
    if (item.partsSongSource === 'playing') return 'partsSongStartPart partsSongStartPlaying'
    if (item.partsSongSource === 'queued') return 'partsSongStartPart partsSongStartQueued'
    return 'partsSongStartPart'
  }

  function renderRows(items, type, options = {}) {
    const sourceList = Array.isArray(items) ? items : []
    if (!sourceList.length) return `<div class="emptyBox">NENHUM ITEM ENCONTRADO</div>`
    const playlistHasBlocks = type === 'playlist' && sourceList.some((item) => isBlock(item))
    const showRowNumber = !IS_MUSICIAN_MONITOR && (type === 'playlist' || type === 'region')
    const displayList = getNumberSortedItems(sourceList, type)
    let sourceBlockNumber = 0
    let sourceSongNumber = 0
    let currentHashParentKey = ''
    const entries = displayList.map((item, index) => {
      const block = isBlock(item)
      if (block) sourceBlockNumber += 1
      const songNumber = showRowNumber && !block ? ++sourceSongNumber : 0
      const nextItem = displayList[index + 1]
      const inferredParent = type === 'region' && !isHashChild(item) && isHashChild(nextItem)
      const hashParent = (type === 'region' || type === 'playlist') && (isHashParent(item) || itemHasChildSongMarkers(item, state.snapshot) || inferredParent)
      if (hashParent) currentHashParentKey = String(getId(item) || getRegionNumberValue(item) || index)
      const explicitParentKey = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
      const parentKey = (type === 'region' || type === 'playlist') && isHashChild(item) ? (explicitParentKey || currentHashParentKey) : ''
      return { item, index, blockNumber: sourceBlockNumber, songNumber, parentKey, hashParent }
    })
    const list = type === 'region' || type === 'playlist'
      ? entries.filter((entry) => !isHashChild(entry.item) || !!state.hashRegionDrawers[entry.parentKey])
      : entries
    const progress = isPlaying(state.snapshot) ? getPlaybackProgressPercent(state.snapshot) : 0
    const playingId = getPlayingId(state.snapshot)
    const queuedId = getQueuedId(state.snapshot)
    const queueProgress = queuedId ? 100 - progress : 0
    const drawerVisual = getDrawerVisualStyle(state.snapshot)
    const blockSymbolVisual = getBlockSymbolVisualStyle(state.snapshot)
    return list.map((entry, visibleIndex) => {
      const item = entry.item
      const id = escapeHtml(getId(item))
      const rawId = getId(item)
      const isBlockRow = isBlock(item)
      const rowNumber = showRowNumber && !isBlockRow ? getRowNumberText(item, entry.songNumber) : ''
      const name = escapeHtml(getRowDisplayName(item, entry.index, entry.blockNumber))
      const sec = getDurationSec(item)
      const time = sec ? formatTime(sec) : ''
      const cls = rowClass(type, item)
      const tcls = textClass(type, item)
      const rcls = timeClass(type, item)
      const markedBlack = cls.split(/\s+/).some((name) => name === 'playing' || name === 'queuedYellow' || name === 'queuedGreen' || name === 'selectedBlue')
      const liveVisual = !markedBlack && cls.split(/\s+/).includes('liveExecutedItem')
      const playlistWithoutBlocks = type === 'playlist' && !playlistHasBlocks && !isBlockRow
      const noBlockTextColor = playlistWithoutBlocks
        ? getNoBlockTextColor(state.snapshot)
        : ''
      const itemBaseColorStyle = noBlockTextColor
        ? ` style="color:${noBlockTextColor}!important"`
        : itemColorStyle(item, type)
      // Sem nenhum bloco, Diretor e Músicos usam a cor configurada na extensão.
      // "Sem cor" preserva a cor própria da música; no tema claro, as demais
      // listas sem uma cor própria usam preto.
      // Em repertórios com blocos, nome e duração preservam a cor herdada do bloco.
      // Linhas tocando, em fila ou selecionadas continuam com texto preto.
      const forceBlackInLightTheme = getAppTheme() === 'light' &&
        !noBlockTextColor && (type !== 'playlist' || !playlistHasBlocks)
      const colorStyle = markedBlack
        ? ' style="color:#050505!important"'
        : liveVisual
          ? ' style="color:#f87171!important;text-decoration:none!important"'
          : forceBlackInLightTheme ? ' style="color:#050505!important"' : itemBaseColorStyle
      // O tempo individual do bloco usa o mesmo verde fixo da extensão,
      // inclusive durante seleção e marcação do modo Live.
      const timeColorStyle = isBlockRow
        ? ' style="color:#22c55e!important"'
        : liveVisual ? ' style="color:#f87171!important"' : colorStyle
      const numberColorStyle = liveVisual ? ' style="color:#f87171!important"' : itemBaseColorStyle
      const dataAttr = type === 'playlist' ? 'data-song-id' : type === 'region' ? 'data-region-id' : 'data-marker-id'
      const searchFocus = state.tabletSearchPendingFocus &&
        state.tabletSearchPendingFocus.itemType === type &&
        String(state.tabletSearchPendingFocus.id || '') === String(rawId || '')
      const searchFocusAttr = searchFocus ? ' data-tablet-search-scroll-target="1"' : ''
      const markerArmed = type === 'marker' && rawId && rawId === state.partsArmedMarkerId && now() < state.partsArmedMarkerUntil
      const partsSongStartClasses = type === 'marker' ? getPartsSongStartRowClasses(item, state.snapshot) : ''
      const partsSongStartAttrs = item?.partsSongStart
        ? ` data-parts-song-start="1" data-parts-song-source="${escapeHtml(item.partsSongSource || '')}"`
        : ''
      let tabletTunerControls = ''
      if (options.tabletTuner && (type === 'playlist' || type === 'region')) {
        const knownFamilyParent = isHashParent(item) || Array.isArray(state.hashRegionDrawerChildren[String(rawId || '')])
        if (isBlockRow || knownFamilyParent) {
          tabletTunerControls = '<div class="tabletTunerInlineControls tabletTunerInlineControlsEmpty"></div>'
        } else {
          const value = getTunerValue(item)
          const sourceNumber = getTunerSourceNumber(item)
          const sourceAttr = sourceNumber == null ? '' : ` data-tuner-source-number="${sourceNumber}"`
          tabletTunerControls = `<div class="tabletTunerInlineControls"><button class="tunerStepBtn" data-action="tuner-minus" data-tuner-song-id="${id}"${sourceAttr}${value <= -12 ? ' disabled' : ''}>−</button><button class="tabletTunerZero" data-action="tuner-reset" data-tuner-song-id="${id}"${sourceAttr}>${escapeHtml(formatTunerValue(value))}st</button><button class="tunerStepBtn" data-action="tuner-plus" data-tuner-song-id="${id}"${sourceAttr}${value >= 12 ? ' disabled' : ''}>+</button></div>`
        }
      }
      const hashParentKey = entry.hashParent ? String(rawId || getRegionNumberValue(item) || entry.index) : ''
      const hashParentAttr = hashParentKey ? ` data-hash-parent-key="${escapeHtml(hashParentKey)}" data-hash-parent="1"` : ''
      const familyDrawerControl =
        !!hashParentKey && getFamilyViewControlsEnabled(state.snapshot)
        ? `<button class="familyDrawerToggle${state.hashRegionDrawers[hashParentKey] ? ' familyDrawerToggleOpen' : ''}" data-action="family-drawer-toggle" data-family-parent-id="${escapeHtml(hashParentKey)}" data-family-item-type="${escapeHtml(type)}">${state.hashRegionDrawers[hashParentKey] ? 'Ocultar' : 'Mostrar'}</button>`
        : ''
      const blockLabel = isBlockRow
        ? `<div class="leftCol blockDesignerLabel blockSymbol-${escapeHtml(blockSymbolVisual.mode)}" style="--block-symbol-color:${escapeHtml(blockSymbolVisual.color)}"><span class="blockDesignerOrnament blockDesignerOrnamentLeft" aria-hidden="true"></span><span class="${tcls} blockDesignerText"${colorStyle}>${name}</span><span class="blockDesignerOrnament blockDesignerOrnamentRight" aria-hidden="true"></span></div>`
        : `<div class="leftCol"><span class="${tcls}"${colorStyle}>${name}</span></div>`
      const nextEntry = list[visibleIndex + 1]
      const drawerFamilyTop = !!(entry.hashParent && nextEntry && isHashChild(nextEntry.item) && nextEntry.parentKey === hashParentKey)
      const drawerFamilyChild = isHashChild(item) && !!entry.parentKey
      const drawerFamilyBottom = !!(drawerFamilyChild && (!nextEntry || !isHashChild(nextEntry.item) || nextEntry.parentKey !== entry.parentKey))
      const drawerClasses = [
        drawerFamilyTop || drawerFamilyChild ? 'drawerFamilyMember' : '',
        drawerFamilyTop ? 'drawerFamilyTop' : '',
        drawerFamilyBottom ? 'drawerFamilyBottom' : '',
        drawerVisual.outlineEnabled ? 'drawerOutlineEnabled' : '',
        drawerFamilyChild && drawerVisual.symbolEnabled ? 'drawerSymbolEnabled' : ''
      ].filter(Boolean).join(' ')
      const drawerStyleAttr = (drawerFamilyTop || drawerFamilyChild)
        ? ` style="--drawer-outline-color:${drawerVisual.outlineColor};--drawer-symbol-color:${drawerVisual.symbolColor}"`
        : ''
      const armedRegress = markerArmed ? getPartsArmedRegressPercent(state.snapshot) : 0
      const rowProgress = markerArmed
        ? `<div class="partsArmedRegressTrack"><div class="partsArmedRegressBar" style="width:${armedRegress}%"></div></div>`
        : rowRepresentsPlayingSong(item, state.snapshot)
          ? `<div class="rowProgressTrack"><div class="progressBar playingRowProgressBar" style="width:${progress}%"></div></div>`
          : rawId && queuedId && rawId === queuedId
            ? `<div class="rowProgressTrack queuedRowRegressTrack"><div class="progressBar queuedRowRegressBar" style="width:${queueProgress}%"></div></div>`
            : ''
      return `
        <div class="${cls} ${showRowNumber ? 'numberedItem' : ''}${familyDrawerControl ? ' hasFamilyDrawerToggle' : ''}${options.tabletTuner ? ' tabletTunerUnifiedItem' : ''}${partsSongStartClasses ? ` ${partsSongStartClasses}` : ''}${drawerClasses ? ` ${drawerClasses}` : ''}" ${dataAttr}="${id}" data-item-type="${type}" data-is-block="${isBlockRow ? '1' : '0'}"${hashParentAttr}${partsSongStartAttrs}${searchFocusAttr}${drawerStyleAttr} ${IS_MUSICIAN_MONITOR ? '' : 'data-action="select-item"'}>
          ${drawerFamilyTop || drawerFamilyChild ? '<span class="drawerOutlineSides" aria-hidden="true"></span>' : ''}
          ${drawerFamilyTop ? '<span class="drawerOutlineTop" aria-hidden="true"></span>' : ''}
          ${drawerFamilyBottom ? '<span class="drawerOutlineBottom" aria-hidden="true"></span>' : ''}
          ${drawerFamilyChild ? '<span class="drawerChildSymbol" aria-hidden="true"></span>' : ''}
          ${rowProgress}
          ${showRowNumber ? `<div class="rowNumberCol"><span class="rowNumberText"${numberColorStyle}>${rowNumber}</span></div>` : ''}
          ${blockLabel}
          ${familyDrawerControl}
          <div class="rightCol"><span class="${rcls}"${timeColorStyle}>${escapeHtml(time)}</span></div>
          ${tabletTunerControls}
        </div>
      `
    }).join('')
  }

  function getLoopActive(data = state.snapshot) {
    if (state.pendingLoop !== null && now() < Number(state.pendingLoopUntil || 0)) return !!state.pendingLoop
    return data?.loopActive === true || data?.repeatEnabled === true || data?.loopEnabled === true
  }

  function getMultiLoopBypassActive(data = state.snapshot) {
    if (state.pendingMultiLoopBypass !== null && now() < Number(state.pendingMultiLoopBypassUntil || 0)) {
      return state.pendingMultiLoopBypass === true
    }
    return data?.multiloops?.bypassActive === true
  }

  function syncTabletMultiLoopBypassDom(data = state.snapshot) {
    const active = getMultiLoopBypassActive(data)
    root.querySelectorAll('[data-action="multiloop-bypass"]').forEach((button) => {
      button.classList.toggle('tabletSidebarByButtonOn', active)
      button.classList.toggle('tabletSidebarByButtonOff', !active)
      button.classList.toggle('topMenuFlyoutBtnByOn', active)
      button.classList.toggle('topMenuFlyoutBtnByOff', !active)
      button.classList.toggle('topMenuFlyoutBtnActive', active)
      button.setAttribute('aria-pressed', active ? 'true' : 'false')
    })
  }

  function processTabletMultiLoopBypassWarning(data = state.snapshot) {
    const active = getMultiLoopBypassActive(data)
    if (IS_MUSICIAN_MONITOR || !active || !isPlaying(data)) {
      state.tabletMultiLoopBypassWarningKey = ''
      state.tabletMultiLoopBypassWarningLastPosition = null
      return
    }

    const playPos = getCurrentPlaybackPosition(data)
    const warningKey = String(data?.multiloops?.bypassWarningKey || '')
    const warningStart = firstFiniteNumber([
      data?.multiloops?.bypassWarningStartPos,
      data?.multiloops?.bypassWarningStart,
    ])
    if (playPos === null || !warningKey || warningStart === null) {
      state.tabletMultiLoopBypassWarningKey = ''
      state.tabletMultiLoopBypassWarningLastPosition = playPos
      return
    }

    const previousPos = Number(state.tabletMultiLoopBypassWarningLastPosition)
    if (Number.isFinite(previousPos) && playPos < previousPos - 0.05) {
      state.tabletMultiLoopBypassWarningKey = ''
    }
    state.tabletMultiLoopBypassWarningLastPosition = playPos

    const remaining = warningStart - playPos
    if (remaining < -0.05 || remaining > 4.05 || warningKey === state.tabletMultiLoopBypassWarningKey) return
    state.tabletMultiLoopBypassWarningKey = warningKey
    showPopup('ESSE LOOP NÃO SERÁ ARMADO. SE QUISER, DESATIVE O BY.', 'error', 3200)
  }

  function getLoopRange(data = state.snapshot) {
    const start = firstFiniteNumber([data?.loopStartPos, data?.loopStart, data?.loopSelectionStart, data?.timeSelectionStart])
    const end = firstFiniteNumber([data?.loopEndPos, data?.loopEnd, data?.loopSelectionEnd, data?.timeSelectionEnd])
    return { start, end, valid: start !== null && end !== null && end > start }
  }

  function cleanLoopMarkerName(value) {
    let name = String(value || '').trim()
    if (name.startsWith('*1') || name.startsWith('*2')) name = name.slice(2)
    else if (name.startsWith('$') || name.startsWith('!')) name = name.slice(1)
    name = name.replace(/^[-–—:\s]+/, '').trim()
    return upperText(name)
  }

  function getLoopDisplayInfo(data = state.snapshot) {
    const directMarker = cleanLoopMarkerName(data?.loopStartMarkerName || data?.loopFirstMarkerName || data?.loopSegmentName || data?.loopStartLabel)
    if (directMarker) return { name: directMarker, kind: 'marker' }

    const range = getLoopRange(data)
    if (range.valid) {
      const exactMarker = getMarkers(data).find((marker) => {
        const pos = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
        return pos !== null && Math.abs(pos - range.start) <= 0.001
      })
      const exactMarkerName = cleanLoopMarkerName(getRawMarkerName(exactMarker))
      if (exactMarkerName) return { name: exactMarkerName, kind: 'marker' }
    }

    const directRegion = upperText(data?.loopRegionName || data?.loopSongName || data?.loopRegionLabel || '')
    if (directRegion) return { name: directRegion, kind: 'region' }

    // Compatibilidade com extensoes anteriores: se o trecho comeca exatamente no
    // inicio da regiao (trecho antes do primeiro marker), usa o nome da musica.
    if (range.valid) {
      const regionItem = [...getPlaylistItems(data), ...getRegions(data)].find((item) => {
        if (!isPlayable(item)) return false
        const start = getItemStart(item)
        const end = getItemEnd(item)
        return start !== null && end !== null && Math.abs(start - range.start) <= 0.001 && range.end <= end + 0.001
      })
      const regionName = upperText(getName(regionItem) || '')
      if (regionName) return { name: regionName, kind: 'region' }
    }

    return { name: 'TRECHO ATUAL', kind: 'segment' }
  }

  function getLoopDisplayName(data = state.snapshot) {
    return getLoopDisplayInfo(data).name
  }

  function hasPlaybackReachedLoop(data = state.snapshot) {
    if (!getLoopActive(data) || !isPlaying(data)) return false
    const range = getLoopRange(data)
    const playPos = getCurrentPlaybackPosition(data)
    if (range.valid && playPos !== null) {
      return playPos >= range.start - 0.001 &&
        playPos < range.end - 0.0005
    }
    return data?.loopPlaybackReached === true
  }

  function hasSelectedOrPlayingMultiLoop(data = state.snapshot) {
    if (data?.selectedOrPlayingMultiLoopActive === true ||
        data?.multiloops?.selectedOrPlayingActive === true) return true

    const multiLoops = data?.multiloops
    if (!multiLoops || (multiLoops.loop1Enabled !== true &&
        multiLoops.loop2Enabled !== true)) return false

    const focusId = String(multiLoops.songId || '')
    if (!focusId) return false
    return [
      getPlayingId(data),
      getSelectedPlaylistId(data),
      getSelectedRegionId(data),
    ].some((id) => String(id || '') === focusId)
  }

  function getTransportMultiLoopStatus(data = state.snapshot) {
    if (getMultiLoopBypassActive(data)) {
      return {
        text: 'BY ATIVO MULTILOOPS DESATIVADOS',
        kind: 'bypass',
      }
    }

    if (hasPlaybackReachedLoop(data)) {
      const loopInfo = getLoopDisplayInfo(data)
      const loopName = cleanLoopMarkerName(
        data?.multiLoopPartName) ||
        upperText(loopInfo.name || '')
      return {
        text: loopName ? `${loopName} - EM LOOP` : 'EM LOOP',
        kind: loopInfo.kind === 'region' ? 'loop-region' : 'loop',
      }
    }

    if (hasSelectedOrPlayingMultiLoop(data)) {
      return {
        text: 'ESSA MÚSICA TEM MULTILOOP ATIVO',
        kind: 'active',
      }
    }

    return { text: '-', kind: 'idle' }
  }

  function renderPartsSongSwitch(data = state.snapshot) {
    const playingTarget = getPartsSongTarget('playing', data)
    const queuedTarget = getPartsSongTarget('queued', data)
    const effective = getEffectivePartsSongSource(data)
    const playingName = playingTarget.name || 'NENHUMA MÚSICA'
    const queuedName = queuedTarget.name || 'FILA VAZIA'
    const playingClass = `partsSongSwitchBtn ${effective === 'playing' && playingTarget.available ? 'partsSongSwitchBtnActive' : ''}`
    const queuedClass = `partsSongSwitchBtn ${effective === 'queued' && queuedTarget.available ? 'partsSongSwitchBtnActive' : ''}`
    return `<div class="partsSongSwitchRow"><button class="${playingClass}" data-action="parts-song-playing" title="${escapeHtml(playingName)}" ${playingTarget.available ? '' : 'disabled'}>${escapeHtml(playingName)}</button><button class="${queuedClass}" data-action="parts-song-queued" title="${escapeHtml(queuedName)}" ${queuedTarget.available ? '' : 'disabled'}>${escapeHtml(queuedName)}</button></div>`
  }

  function renderControls() {
    const playing = isPlaying(state.snapshot)
    const playLabel = playing ? 'STOP' : 'PLAY'
    const fadeoutRunning = state.tabletFadeoutRuntimeActive === true
    const fadeoutRemaining = `${Math.max(0, Math.min(100, (1 - getTabletFadeoutVisualProgress()) * 100))}%`
    const fadeoutStyle = fadeoutRunning ? ` style="--fadeout-remaining:${fadeoutRemaining}"` : ''
    const playClass = playing ? `btn btnStopActive${fadeoutRunning ? ' tabletFadeoutStopBlink tabletFadeoutRegress' : ''}` : 'btn btnPlayActive'
    const autoAvailable = state.activeTab === 'playlist'
    const auto1Class = !autoAvailable ? 'btn btnAutoUnavailable' : (getAutoplay1Enabled() ? 'btnAutoplayActive' : 'btn')
    const auto2Class = !autoAvailable ? 'btn btnAutoUnavailable' : (getAutoplay2Enabled() ? 'btnAutoplayActive btnAutoplay2Active' : 'btn')
    const cancelClass = state.partsArmedMarkerId ? 'btn btnStopActive partsCancelArmed' : 'btn'
    const loopClass = getLoopActive() ? 'btn btnLoopActive' : 'btn'
    if (state.activeTab === 'markers') {
      return `<div class="controlsRowPlaylist controlsRowEqual controlsRowMarkers"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${cancelClass}" data-action="marker-cancel">CANCELAR</button><button class="${loopClass}" data-action="loop">LOOP</button></div>`
    }
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet' && !IS_MUSICIAN_MONITOR
    const stopBreakClass = playing ? `btn btnStopActive tabletStopBreakPlaying${fadeoutRunning ? ' tabletFadeoutRegress' : ''}` : 'btn'
    if (state.activeTab === 'regions') {
      if (tabletMode) {
        const liveClass = getLiveEnabled() ? 'btn btnConfigOnGreen tabletLiveButtonActive' : 'btn btnConfigOffRed tabletLiveButton'
        return `<div class="controlsRowPlaylist controlsRowEqual controlsRowMusicMain"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${stopBreakClass}" data-action="stop-break"${fadeoutStyle}>STOP BREAK</button><button class="${liveClass}" data-action="live">LIVE</button></div>`
      }
      return `<div class="controlsRowPlaylist controlsRowTwo controlsRowMusicMain"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${stopBreakClass}" data-action="stop-break"${fadeoutStyle}>STOP BREAK</button></div>`
    }
    if (tabletMode) {
      const atBlArmed = getAutoBlocoEnabled()
      const atBlClass = atBlArmed ? 'btnAutoplayActive tabletAtBlArmed' : 'btn'
      const liveClass = getLiveEnabled() ? 'btn btnConfigOnGreen tabletLiveButtonActive' : 'btn btnConfigOffRed tabletLiveButton'
      return `<div class="controlsRowPlaylist controlsRowDirectorMain controlsRowDirectorMainTablet"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${auto1Class}" data-action="autoplay">AUTO 1</button><button class="${auto2Class}" data-action="autoplay2">AUTO 2</button><button class="${atBlClass}" data-action="atbl-toggle" aria-pressed="${atBlArmed ? 'true' : 'false'}">AT/BL</button><button class="${stopBreakClass}" data-action="stop-break"${fadeoutStyle}>STOP BREAK</button><button class="${liveClass}" data-action="live">LIVE</button></div>`
    }
    const phoneMode =
      document.documentElement.dataset.directorDevice === 'phone'
    const auto1Label = phoneMode ? 'AU1' : 'AUTO 1'
    const auto2Label = phoneMode ? 'AU2' : 'AUTO 2'
    return `<div class="controlsRowPlaylist controlsRowDirectorMain${phoneMode ? ' controlsRowDirectorMainPhone' : ''}"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${auto1Class}" data-action="autoplay">${auto1Label}</button><button class="${auto2Class}" data-action="autoplay2">${auto2Label}</button><button class="${stopBreakClass}" data-action="stop-break"${fadeoutStyle}>STOP BREAK</button></div>`
  }

  function renderMarkersControls() {
    const playing = isPlaying(state.snapshot)
    const playLabel = playing ? 'STOP' : 'PLAY'
    const fadeoutRunning = state.tabletFadeoutRuntimeActive === true
    const fadeoutRemaining = `${Math.max(0, Math.min(100, (1 - getTabletFadeoutVisualProgress()) * 100))}%`
    const fadeoutStyle = fadeoutRunning ? ` style="--fadeout-remaining:${fadeoutRemaining}"` : ''
    const playClass = playing ? `btn btnStopActive${fadeoutRunning ? ' tabletFadeoutStopBlink tabletFadeoutRegress' : ''}` : 'btn btnPlayActive'
    const cancelClass = state.partsArmedMarkerId ? 'btn btnStopActive partsCancelArmed' : 'btn'
    const loopClass = getLoopActive() ? 'btn btnLoopActive' : 'btn'
    return `<div class="controlsRowPlaylist controlsRowEqual controlsRowMarkers"><button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button><button class="${cancelClass}" data-action="marker-cancel">CANCELAR</button><button class="${loopClass}" data-action="loop">LOOP</button></div>`
  }

  function findSongNameById(id, data = state.snapshot) {
    const target = String(id || '')
    if (!target) return ''
    const lists = [
      ...Object.values(state.hashRegionDrawerChildren).filter(Array.isArray),
      getPlaylistItems(data),
      getRegions(data),
      getPremixSongs(data),
      getMarkers(data),
    ]
    for (const list of lists) {
      const found = (Array.isArray(list) ? list : []).find((item) => String(getId(item)) === target)
      if (found) return getRowDisplayName(found, 0, 1)
    }
    return ''
  }

  function getNowPlayingName(data = state.snapshot) {
    if (bridgeExplicitlyStopped(data) &&
        state.pendingTransportPlaying !== true) return ''
    // O Play recém-clicado é a fonte imediata do painel. Um estado otimista
    // antigo de Stop não pode deixar "Tocando agora" vazio até o Bridge responder.
    if (state.optimisticPlayingId && now() < state.optimisticPlayingUntil) {
      const optimisticName = upperText(findSongNameById(state.optimisticPlayingId, data))
      if (optimisticName) return optimisticName
    }
    if (state.optimisticStoppedUntil && now() < state.optimisticStoppedUntil) return ''
    const playingId = getPlayingId(data)
    const bridgePlayingId = data?.playingId != null ? String(data.playingId) : ''
    const localName = upperText(findSongNameById(playingId, data))
    if (state.optimisticPlayingId && now() < state.optimisticPlayingUntil && playingId && playingId !== bridgePlayingId) return localName
    const direct = data?.currentSongName || data?.playingSongName || data?.playingName || data?.currentRegionName || data?.activeSongName
    if (String(direct || '').trim()) return upperText(direct)
    return localName
  }

  function getQueuedSongName(data = state.snapshot) {
    if (!isPlaying(data) && !isPaused(data)) return ''
    if (state.optimisticQueueClearedUntil && now() < state.optimisticQueueClearedUntil) return ''
    if (!getQueuedId(data)) return ''
    const localQueuedId = String(state.queuedSongId || '')
    const bridgeQueuedId = String(data?.queuedSongId || data?.queueSongId || '')
    if (localQueuedId && localQueuedId !== bridgeQueuedId) return upperText(findSongNameById(localQueuedId, data))
    const direct = data?.queuedSongName || data?.queueSongName || data?.nextSongName || data?.nextRegionName
    if (String(direct || '').trim()) return upperText(direct)
    return upperText(findSongNameById(getQueuedId(data), data))
  }

  function clearConsumedQueueVisualOnPlayingChange(playingId, data = state.snapshot) {
    const queuedId = String(state.queuedSongId || data?.queuedSongId || data?.queueSongId || '')
    if (!queuedId || !playingId) return false

    const queuedItem = getSongItemById(queuedId, data)
    const queuedStart = firstFiniteNumber([
      queuedItem?.startPos, queuedItem?.start_pos, queuedItem?.pos,
      data?.queuedStartPos, data?.queueStartPos,
    ])
    const queuedEnd = firstFiniteNumber([
      queuedItem?.endPos, queuedItem?.end_pos,
      data?.queuedEndPos, data?.queueEndPos,
    ])
    const playingStart = firstFiniteNumber([data?.currentSongStart, data?.playbackStartPos, data?.songStartPos])
    const playingEnd = firstFiniteNumber([data?.currentSongEnd, data?.playbackEndPos, data?.songEndPos])
    const sameBounds = queuedStart !== null && queuedEnd !== null && playingStart !== null && playingEnd !== null
      && Math.abs(queuedStart - playingStart) <= 0.002
      && Math.abs(queuedEnd - playingEnd) <= 0.002
    if (queuedId !== String(playingId) && !sameBounds) return false

    // A extensao ja consumiu a fila real. Limpa imediatamente o cache visual
    // para o app nao reapresentar a propria musica como fila entre snapshots.
    state.queuedSongId = ''
    state.queuedManualVisualId = ''
    state.optimisticQueueClearedUntil = now() + 1500
    return true
  }

  function syncPartsSourceOnPlayingChange(data = state.snapshot) {
    const playingId = String(getPlayingId(data) || '')
    if (!playingId || !isPlaying(data)) {
      state.partsLastPlayingId = ''
      return false
    }
    if (state.partsLastPlayingId === playingId) return false

    state.partsLastPlayingId = playingId
    clearConsumedQueueVisualOnPlayingChange(playingId, data)
    focusOpenTabletTransportPanel(
      playingId, resolveSongTabById(playingId, data), 'playing')
    state.partsMarkerSongSource = 'playing'
    state.partsLocalSelectedMarkerId = ''
    state.partsArmedMarkerId = ''
    state.partsArmedMarkerUntil = 0
    clearPartsArmedOwner()
    if (isPartsInterfaceVisible()) scheduleRender(true)
    return true
  }

  function clampPercent(value) {
    const n = Number(value)
    if (!Number.isFinite(n)) return 0
    return Math.max(0, Math.min(100, n))
  }

  function firstFiniteNumber(values) {
    for (const value of values) {
      const n = Number(value)
      if (Number.isFinite(n)) return n
    }
    return null
  }

  function getSongItemById(id, data = state.snapshot) {
    const target = String(id || '')
    if (!target) return null
    const lists = [
      ...Object.values(state.hashRegionDrawerChildren).filter(Array.isArray),
      getPlaylistItems(data),
      getRegions(data),
      getPremixSongs(data),
      getMarkers(data),
    ]
    for (const list of lists) {
      const found = (Array.isArray(list) ? list : []).find((item) => String(getId(item)) === target)
      if (found) return found
    }
    return null
  }

  function getCurrentPlaybackPosition(data = state.snapshot) {
    return firstFiniteNumber([
      data?.playPosition,
      data?.currentPlayPosition,
      data?.currentPosition,
      data?.playbackPosition,
      data?.position,
    ])
  }

  function processTabletPartCountdownPopup(data = state.snapshot) {
    if (document.documentElement.dataset.directorDevice !== 'tablet' ||
        !isPlaying(data) || getLoopActive(data)) {
      state.tabletPartCountdownKey = ''
      state.tabletPartCountdownLastPosition = null
      return
    }

    const playPos = getCurrentPlaybackPosition(data)
    const playingRegion = getPartsSongTarget('playing', data)
    if (playPos === null || !playingRegion.available) return

    const previousPos = Number(state.tabletPartCountdownLastPosition)
    if (Number.isFinite(previousPos) && playPos < previousPos - 0.05) state.tabletPartCountdownKey = ''
    state.tabletPartCountdownLastPosition = playPos

    const regionStart = Number(playingRegion.start)
    const regionEnd = Number(playingRegion.end)
    const partRows = getMarkers(data)
      .map((marker) => {
        const info = getPartsMarkerInfo(marker)
        const pos = firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos])
        return info && pos !== null ? { marker, info, pos } : null
      })
      .filter((row) => row && row.pos > playPos + 0.0005 && row.pos >= regionStart - 0.0005 && row.pos < regionEnd - 0.0005)
      .sort((a, b) => a.pos - b.pos)

    const armedId = String(state.partsArmedMarkerId || data?.armedMarkerId || data?.markerGoId || '')
    let announcePos = null
    let announceName = ''
    let announceKey = ''

    if (armedId) {
      // O engatilhamento acontece no proximo limite da Part atual. O aviso usa
      // o nome do destino, mesmo quando ele esta em outra musica ou atras no projeto.
      announcePos = partRows.length ? partRows[0].pos : regionEnd
      const armedMarker = getMarkers(data).find((marker) => String(getId(marker)) === armedId)
      const armedInfo = armedMarker ? getPartsMarkerInfo(armedMarker) : null
      announceName = armedInfo?.name || (armedId.indexOf('__parts_song_start__:') === 0
        ? findSongNameById(armedId.slice('__parts_song_start__:'.length), data)
        : '') || 'ALVO ENGATILHADO'
      announceKey = `armed:${armedId}:${Number(announcePos).toFixed(4)}`
    } else if (partRows.length) {
      const next = partRows[0]
      announcePos = next.pos
      announceName = next.info.name
      announceKey = `part:${String(getId(next.marker))}:${next.pos.toFixed(4)}`
    }

    if (!Number.isFinite(Number(announcePos))) return
    const remaining = Number(announcePos) - playPos
    if (remaining < -0.05 || remaining > 5.05 || !announceKey || announceKey === state.tabletPartCountdownKey) return
    state.tabletPartCountdownKey = announceKey
    showPopup(upperText(announceName || 'PART'), 'info', 1600)
  }

  // Regresso do marker engatilhado: usa o trecho atual entre dois markers
  // da música em reprodução, que é o tempo real até o salto armado acontecer.
  function getPartsArmedRegressPercent(data = state.snapshot, smoothPlaybackPosition = null) {
    if (!state.partsArmedMarkerId || !isPlaying(data)) return 0

    const playPos = smoothPlaybackPosition === null
      ? getCurrentPlaybackPosition(data)
      : smoothPlaybackPosition
    const playingRegion = getPartsSongTarget('playing', data)
    if (playPos === null || !playingRegion.available) {
      return clampPercent(100 - getPlaybackProgressPercent(data))
    }

    const regionStart = Number(playingRegion.start)
    const regionEnd = Number(playingRegion.end)
    if (!Number.isFinite(regionStart) || !Number.isFinite(regionEnd) || regionEnd <= regionStart) {
      return clampPercent(100 - getPlaybackProgressPercent(data))
    }

    const boundaries = getMarkers(data)
      .filter((marker) => !!getPartsMarkerInfo(marker))
      .map((marker) => firstFiniteNumber([marker?.pos, marker?.position, marker?.startPos, marker?.start_pos]))
      .filter((pos) => pos !== null && pos > regionStart + 0.0005 && pos < regionEnd - 0.0005)
      .sort((a, b) => a - b)

    let segmentStart = regionStart
    let segmentEnd = regionEnd
    for (const markerPos of boundaries) {
      if (markerPos <= playPos + 0.0005) segmentStart = markerPos
      else {
        segmentEnd = markerPos
        break
      }
    }

    if (segmentEnd <= segmentStart) return 0
    const clampedPos = Math.max(segmentStart, Math.min(segmentEnd, playPos))
    return clampPercent(((segmentEnd - clampedPos) / (segmentEnd - segmentStart)) * 100)
  }

  function getPlaybackProgressPercent(data = state.snapshot) {
    const direct = firstFiniteNumber([
      data?.playbackProgressPercent,
      data?.progressPercent,
      data?.currentSongProgressPercent,
      data?.songProgressPercent,
      data?.playbackProgress,
      data?.progress,
    ])
    if (direct !== null) return clampPercent(direct <= 1 ? direct * 100 : direct)

    const remaining = firstFiniteNumber([
      data?.playbackRemainingSec,
      data?.currentSongRemainingSec,
      data?.remainingSec,
      data?.songRemainingSec,
    ])
    const elapsed = firstFiniteNumber([
      data?.playbackElapsedSec,
      data?.currentSongElapsedSec,
      data?.elapsedSec,
      data?.songElapsedSec,
    ])
    const duration = firstFiniteNumber([
      data?.playbackDurationSec,
      data?.currentSongDurationSec,
      data?.durationSec,
      data?.songDurationSec,
      getDurationSec(getSongItemById(getPlayingId(data), data)),
    ])
    if (duration && duration > 0) {
      if (elapsed !== null) return clampPercent((Math.max(0, elapsed) / duration) * 100)
      if (remaining !== null) return clampPercent(((duration - Math.max(0, remaining)) / duration) * 100)
    }

    const start = firstFiniteNumber([data?.currentSongStart, data?.playbackStartPos, data?.startPos])
    const end = firstFiniteNumber([data?.currentSongEnd, data?.playbackEndPos, data?.endPos])
    const pos = firstFiniteNumber([data?.currentPosition, data?.playbackPosition, data?.position, data?.cursorPosition])
    if (start !== null && end !== null && pos !== null && end > start) return clampPercent(((pos - start) / (end - start)) * 100)

    return 0
  }

  function getSmoothedPlaybackProgressPercent(data = state.snapshot) {
    const base = getPlaybackProgressPercent(data)
    if (!isPlaying(data) || !state.lastGoodAt) return base
    const duration = firstFiniteNumber([
      data?.playbackDurationSec,
      data?.currentSongDurationSec,
      data?.durationSec,
      data?.songDurationSec,
      getDurationSec(getSongItemById(getPlayingId(data), data)),
    ])
    if (!(duration > 0)) return base
    // O Bridge chega a cada 300 ms. Avança localmente entre dois snapshots
    // para a barra não ficar parada e depois saltar.
    const snapshotAgeSec = Math.max(
      0,
      Math.min(POLL_MS * 2, now() - state.lastGoodAt)
    ) / 1000
    return clampPercent(base + (snapshotAgeSec / duration) * 100)
  }

  function renderPlaybackQueueHeader(data = state.snapshot, holdable = false) {
    const nowName = getNowPlayingName(data) || 'NENHUMA MÚSICA EM REPRODUÇÃO'
    const queuedName = getQueuedSongName(data) || 'FILA DE ESPERA VAZIA'
    const loopActive = getLoopActive(data)
    const hasQueue = !!(getQueuedId(data) || getQueuedSongName(data))
    const showQueueBar = hasQueue && !loopActive
    const progress = isPlaying(data) ? getPlaybackProgressPercent(data) : 0
    const queueProgress = showQueueBar ? 100 - progress : 0
    const multiLoopStatus = getTransportMultiLoopStatus(data)
    const multiLoopClass = multiLoopStatus.kind === 'bypass'
      ? ' playbackQueueMultiLoopBypass'
      : multiLoopStatus.kind === 'loop' || multiLoopStatus.kind === 'loop-region'
        ? ` playbackQueueLoop${multiLoopStatus.kind === 'loop-region' ? ' playbackQueueLoopRegion' : ''}`
        : ''
    const auto2QueueClass = hasQueue && getAutoplay2Enabled(data)
      ? ' playbackQueuePrepareOnly' : ''
    return `
      <div class="playbackQueueHeader${holdable ? ' transportSeekHoldTarget' : ''}">
        <div class="playbackQueueLine playbackQueueNow">
          <span class="playbackQueueLabel">TOCANDO AGORA</span>
          <span class="playbackQueueTitle">${escapeHtml(nowName)}</span>
        </div>
        <div class="playbackQueueTrack playbackQueueTrackNow" aria-hidden="true"><div class="playbackQueueFill playbackQueueFillNow" style="width:${progress}%"></div></div>
        <div class="playbackQueueLine playbackQueueNext${auto2QueueClass}">
          <span class="playbackQueueLabel">FILA DE ESPERA</span>
          <span class="playbackQueueTitle">${escapeHtml(queuedName)}</span>
        </div>
        <div class="playbackQueueTrack playbackQueueTrackNext ${showQueueBar ? '' : 'playbackQueueTrackEmpty'}${auto2QueueClass}" aria-hidden="true"><div class="playbackQueueFill playbackQueueFillNext" style="width:${queueProgress}%"></div></div>
        <div class="playbackQueueLine playbackQueueMultiLoop${multiLoopClass}">
          <span class="playbackQueueLabel">MULTILOOPS</span>
          <span class="playbackQueueTitle">${escapeHtml(multiLoopStatus.text)}</span>
        </div>
      </div>
    `
  }

  function renderMainContent() {
    const data = state.snapshot || {}
    if (state.activeTab === 'playlist') {
      const playlist = getActivePlaylist(data)
      const title = upperText(playlist?.name || data.currentPlaylistName || 'REPERTÓRIO')
      return `<div class="contentPanel"><div class="sectionLabel sectionLabelSticky">${escapeHtml(title)}</div>${renderControls()}${renderPlaybackQueueHeader(data, true)}<div class="listBox">${renderRows(getPlaylistWithOpenDrawers(data), 'playlist')}</div></div>`
    }
    if (state.activeTab === 'regions') {
      return `<div class="contentPanel"><div class="sectionLabel sectionLabelSticky">LISTA GERAL</div>${renderControls()}${renderPlaybackQueueHeader(data, true)}<div class="listBox">${renderRows(getRegionsWithOpenDrawers(data), 'region')}</div></div>`
    }
    if (state.activeTab === 'markers') {
      return partsTargetIsParent(data)
        ? `<div class="contentPanel"><div class="sectionLabel sectionLabelSticky">PARTS</div>${renderPartsParentInstruction()}</div>`
        : `<div class="contentPanel"><div class="sectionLabel sectionLabelSticky">PARTS</div>${renderControls()}${renderPlaybackQueueHeader(data)}${renderPartsSongSwitch(data)}<div class="listBox markerListBox">${renderRows(getPartsMarkers(data), 'marker')}</div></div>`
    }
    if (state.activeTab === 'mixer') return renderMixerPage()
    if (state.activeTab === 'premix') return renderPremixPage()
    return `<div class="emptyBox">ABA NÃO ENCONTRADA</div>`
  }

  function renderMixerPage() {
    const rows = getMixerTracks().map((item) => {
      const rawId = getMixerPrimaryId(item, getId(item))
      const id = escapeHtml(rawId)
      const name = escapeHtml(upperText(getName(item) || 'TRACK'))
      const muted = getHeldMixerToggle(item, 'mute')
      const solo = getHeldMixerToggle(item, 'solo')
      const db = formatMixerDb(item)
      return `<div class="mixerRow" data-action="mixer-volume-open" data-mixer-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">•</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div><div class="mixerRowGroupName">${escapeHtml(db)}</div>${renderTrackMeter(item)}</div><div class="mixerRowDb">${escapeHtml(db)}</div><button class="mixerMiniBtn mixerMiniMute ${muted ? 'mixerMiniBtnActive' : ''}" data-action="mixer-mute" data-mixer-id="${id}" aria-pressed="${muted ? 'true' : 'false'}">M</button><button class="mixerMiniBtn mixerMiniSolo ${solo ? 'mixerMiniBtnActive' : ''}" data-action="mixer-solo" data-mixer-id="${id}" aria-pressed="${solo ? 'true' : 'false'}">S</button></div>`
    }).join('') || `<div class="emptyBox">MIXER SEM DADOS</div>`
    return `<div class="contentPanel mixerContentPanel"><div class="controlsRowPlaylist mixerTopControls"><button class="${state.mixerView === 'tracks' ? 'btnAutoplayActive' : 'btn'}" data-action="mixer-tracks">TRACKS</button><button class="${state.mixerView === 'groups' ? 'btnAutoplayActive' : 'btn'}" data-action="mixer-groups">GRUPOS</button><button class="${state.mixerView === 'master' ? 'btnAutoplayActive' : 'btn'}" data-action="mixer-master">MASTER</button></div><div class="listBox mixerListBox">${rows}</div></div>`
  }

  function renderPremixPage() {
    if (state.premixView === 'tracks') {
      const rows = getPremixTracks().map((item) => {
        const id = escapeHtml(getId(item))
        const name = escapeHtml(upperText(getName(item) || 'PREMIX'))
        const muted = item.mute === true || item.muted === true
        const ratio = Math.max(0, Math.min(1, Number(item.volumeRatio ?? item.volume ?? item.ratio ?? 0.75)))
        return `<div class="mixerRow premixMixerRow" data-premix-track-id="${id}"><div class="mixerRowColor"></div><div class="mixerRowIndex">•</div><div class="mixerRowMain"><div class="mixerRowName">${name}</div><div class="mixerRowGroupName">${Math.round(ratio * 100)}%</div>${renderTrackMeter(item)}</div><div class="mixerRowDb"></div><input class="premixInlineSlider" data-action="premix-volume" data-premix-track-id="${id}" type="range" min="0" max="1" step="0.01" value="${ratio}"><button class="mixerMiniBtn ${muted ? 'mixerMiniBtnActive' : ''}" data-action="premix-mute" data-premix-track-id="${id}">M</button><button class="mixerMiniBtn" data-action="premix-fx" data-premix-track-id="${id}">F</button></div>`
      }).join('') || `<div class="emptyBox">SELECIONE UMA MÚSICA NO PREMIX</div>`
      return `<div class="contentPanel"><div class="controlsRowPlaylist"><button class="btn" data-action="premix-back-songs">MÚSICAS</button><button class="${state.premixTrackView === 'tracks' ? 'btnAutoplayActive' : 'btn'}" data-action="premix-tracks">TRACKS</button><button class="${state.premixTrackView === 'groups' ? 'btnAutoplayActive' : 'btn'}" data-action="premix-groups">GRUPOS</button></div><div class="listBox"><div class="mixerRowsBox">${rows}</div></div></div>`
    }
    const rows = getPremixSongs().map((item) => {
      const id = escapeHtml(getId(item))
      const active = id && String(state.selectedPremixSongId || '') === id
      const enabled = item.premixEnabled === true || item.preMixEnabled === true || item.enabled === true
      return `<div class="item ${active ? 'selectedBlue' : ''}" data-action="premix-song" data-premix-song-id="${id}"><div class="leftCol"><span class="${active ? 'selectedBlueText' : 'text'}">${escapeHtml(upperText(getName(item) || 'MÚSICA'))}</span></div><div class="rightCol"><span class="premixSongStatus ${enabled ? 'premixSongStatusOn' : 'premixSongStatusOff'}">${enabled ? 'ON' : 'OFF'}</span></div></div>`
    }).join('') || `<div class="emptyBox">SEM MÚSICAS PARA PREMIX</div>`
    return `<div class="contentPanel"><div class="controlsRowPlaylist"><button class="btn" data-action="premix-global">GLOBAL</button><button class="btn" data-action="premix-open">ABRIR</button><button class="btn" data-action="premix-toggle">ON/OFF</button></div><div class="listBox">${rows}</div></div>`
  }

  function renderPremixItemRow(item, index) {
    const id = escapeHtml(getPremixItemId(item))
    const itemName = escapeHtml(upperText(getName(item) || `ITEM ${index + 1}`))
    const trackName = escapeHtml(upperText(item?.trackName || item?.track || `PISTA ${item?.trackIndex || index + 1}`))
    const ratio = getPremixItemRatio(item)
    const muted = getPremixItemMute(item)
    const db = mixerRatioToDb(ratio)
    const dbText = Number.isFinite(db) ? `${Math.abs(db) < 0.05 ? '0.0' : `${db >= 0 ? '+' : ''}${db.toFixed(1)}`} dB` : '-Inf dB'
    return `<div class="premixFullRow" data-premix-item-row="${id}">
      <div class="premixFullItemMain"><div class="premixFullTrackName">${trackName}</div><div class="premixFullItemName">${itemName}</div>${renderTrackMeter(item)}</div>
      <div class="premixFullSliderWrap"><input class="premixFullSlider" data-action="premix-item-volume" data-premix-item-id="${id}" type="range" min="0" max="1" step="0.001" value="${ratio}"><span class="premixFullDb">${escapeHtml(dbText)}</span></div>
      <button class="premixFullMute ${muted ? 'premixFullMuteActive' : ''}" data-action="premix-item-mute" data-premix-item-id="${id}" aria-pressed="${muted ? 'true' : 'false'}">M</button>
    </div>`
  }

  function renderPremixFullScreen(data = state.snapshot || {}) {
    if (!state.showPremixScreen) return ''
    const scopeId = String(state.premixSongId || '')
    const snapshotId = getPremixSnapshotSongId(data)
    const ready = !!scopeId && snapshotId === scopeId
    const sections = ready ? getPremixSongSections(data) : []
    const target = getPremixEffectiveTarget(data)
    const songName = upperText(state.premixSongName || data?.premix?.selectedSongName || 'MÚSICA')
    const transportPlaying = isPlaying(data)
    const playingTarget = transportPlaying && getPlayingId(data) === String(target?.id || '')

    let listContent = ''
    if (!ready) {
      listContent = `<div class="emptyBox premixFullEmpty">CARREGANDO PREMIX...</div>`
    } else if (sections.length) {
      listContent = sections.map((section, sectionIndex) => {
        const sectionTarget = getPremixSectionTarget(section)
        if (!sectionTarget) return ''
        const selected = sectionTarget.id === String(target?.id || '') &&
          Math.abs(sectionTarget.start - Number(target?.start || 0)) <= 0.001
        const sectionItems = getPremixSectionItems(section)
        const rows = sectionItems.map((item, itemIndex) => renderPremixItemRow(item, itemIndex)).join('')
          || `<div class="premixFamilyEmpty">NENHUM ITEM COMEÇA NESTA MÚSICA</div>`
        const sectionDuration = firstFiniteNumber([section?.durationSec, section?.duration_sec, section?.lengthSec, section?.length, Number(sectionTarget.end) - Number(sectionTarget.start)]) || 0
        return `<section class="premixFamilySection ${selected ? 'premixFamilySectionSelected' : ''}">
          <button class="premixFamilySongButton transportSeekPremixChildTarget ${selected ? 'premixFamilySongButtonSelected' : ''}" data-action="premix-family-song" data-premix-family-song-id="${escapeHtml(sectionTarget.id)}" data-premix-family-song-name="${escapeHtml(sectionTarget.name)}" data-premix-family-song-start="${sectionTarget.start}" data-premix-family-song-end="${sectionTarget.end}" data-premix-family-song-duration="${sectionDuration}" data-premix-family-marker-number="${sectionTarget.markerNumber}" data-premix-family-marker-enum-index="${sectionTarget.markerEnumIndex}">
            <span class="premixFamilySongIndex">${String(sectionIndex + 1).padStart(2, '0')}</span>
            <span class="premixFamilySongName">${escapeHtml(upperText(sectionTarget.name))}</span>
          </button>
          <div class="premixFamilyItems">${rows}</div>
        </section>`
      }).join('')
    } else {
      const items = getPremixItemRows(data)
      listContent = items.map((item, index) => renderPremixItemRow(item, index)).join('')
        || `<div class="emptyBox premixFullEmpty">NENHUM ITEM COMEÇA DENTRO DESTA MÚSICA</div>`
    }

    return `<div class="premixFullScreen">
      <div class="premixFullPanel">
        ${renderPlaybackQueueHeader(data, true)}
        <div class="premixFullControls">
          <button class="btn ${transportPlaying ? 'btnStopActive' : 'btnPlayActive'} ${playingTarget ? 'premixTransportCurrent' : ''}" data-action="premix-screen-transport">${transportPlaying ? 'PAUSE' : 'PLAY'}</button>
          <button class="btn premixFullBack" data-action="premix-screen-close">VOLTAR</button>
        </div>
        <div class="premixFullHeading"><div class="premixFullTitle">PREMIX</div><div class="premixFullSongName">${escapeHtml(songName)}</div></div>
        <div class="premixFullList listBox">${listContent}</div>
      </div>
    </div>`
  }

  function renderTunerScreen() {
    if (!state.showTunerScreen) return ''
    const data = state.snapshot || {}
    const sourceType = getTunerSourceType()
    const items = getMobileTunerSourceItems()

    let blockNumber = 0
    let songNumber = 0
    const progress = isPlaying(data) ? getPlaybackProgressPercent(data) : 0
    const playingId = getPlayingId(data)
    const queuedId = getQueuedId(data)
    const queueProgress = queuedId ? 100 - progress : 0
    const fadeoutRunning = state.tabletFadeoutRuntimeActive === true
    const fadeoutRemaining = `${Math.max(0, Math.min(100, (1 - getTabletFadeoutVisualProgress()) * 100))}%`
    const fadeoutStyle = fadeoutRunning ? ` style="--fadeout-remaining:${fadeoutRemaining}"` : ''
    const playLabel = isPlaying(data) ? 'STOP' : 'PLAY'
    const playClass = isPlaying(data)
      ? `btn btnStopActive${fadeoutRunning ? ' tabletFadeoutStopBlink tabletFadeoutRegress' : ''}`
      : 'btn btnPlayActive'
    const stopBreakClass = isPlaying(data)
      ? `btn btnStopActive tabletStopBreakPlaying${fadeoutRunning ? ' tabletFadeoutRegress' : ''}`
      : 'btn'
    const rows = (Array.isArray(items) ? items : []).map((item, index) => {
      const block = isBlock(item)
      if (block) blockNumber += 1
      if (!block) songNumber += 1
      const rawId = String(getId(item) || '')
      const id = escapeHtml(rawId)
      const name = escapeHtml(getRowDisplayName(item, index, blockNumber))
      const itemBaseColorStyle = itemColorStyle(item, sourceType)
      const rowNumber = block ? '' : getRowNumberText(item, songNumber)
      const rowCls = tunerRowClass(sourceType, item, data)
      const rowTextCls = tunerTextClass(sourceType, item, data)
      const markedBlack = rowCls.split(/\s+/).some((className) => className === 'playing' || className === 'queuedYellow' || className === 'queuedGreen' || className === 'selectedBlue')
      const colorStyle = markedBlack
        ? ' style="color:#050505!important"'
        : getAppTheme() === 'light' ? ' style="color:#050505!important"' : itemBaseColorStyle
      const numberColorStyle = markedBlack ? ' style="color:#050505!important"' : itemBaseColorStyle
      const familyParent = !block && (isHashParent(item) || Array.isArray(state.hashRegionDrawerChildren[String(getId(item) || '')]))
      const dataAttr = sourceType === 'playlist' ? 'data-song-id' : 'data-region-id'
      const selectAttrs = `${dataAttr}="${id}" data-item-type="${sourceType}" data-action="select-item"`
      const rowProgress = rawId && rawId === playingId
        ? `<div class="rowProgressTrack"><div class="progressBar playingRowProgressBar" style="width:${progress}%"></div></div>`
        : rawId && rawId === queuedId
          ? `<div class="rowProgressTrack queuedRowRegressTrack"><div class="progressBar queuedRowRegressBar" style="width:${queueProgress}%"></div></div>`
          : ''

      if (block) {
        return `
          <div class="${rowCls} numberedItem tunerFullRow tunerFullBlockRow" ${selectAttrs}>
            ${rowProgress}
            <div class="rowNumberCol"><span class="rowNumberText"${numberColorStyle}></span></div>
            <div class="leftCol tunerFullBlockName"><span class="text"${colorStyle}>${name}</span></div>
          </div>
        `
      }

      if (familyParent) {
        return `
          <div class="${rowCls} numberedItem tunerFullRow tunerFullParentRow" data-tuner-parent-id="${id}" ${selectAttrs}>
            ${rowProgress}
            <div class="rowNumberCol"><span class="rowNumberText"${numberColorStyle}>${escapeHtml(rowNumber)}</span></div>
            <div class="leftCol tunerFullSongName"><span class="${rowTextCls}"${colorStyle}>${name}</span></div>
          </div>
        `
      }

      const value = getTunerValue(item)
      const sourceNumber = getTunerSourceNumber(item)
      const minDisabled = value <= -12 ? ' disabled aria-disabled="true"' : ''
      const maxDisabled = value >= 12 ? ' disabled aria-disabled="true"' : ''
      return `
        <div class="${rowCls} numberedItem tunerFullRow" data-tuner-row-id="${id}" ${selectAttrs}>
          ${rowProgress}
          <div class="rowNumberCol"><span class="rowNumberText"${numberColorStyle}>${escapeHtml(rowNumber)}</span></div>
          <button class="tunerStepBtn tunerMinusBtn" data-action="tuner-minus" data-tuner-song-id="${id}"${sourceNumber == null ? '' : ` data-tuner-source-number="${sourceNumber}"`}${minDisabled}>−</button>
          <div class="leftCol tunerFullSongName"><span class="${rowTextCls}"${colorStyle}>${name}</span></div>
          <div class="tunerFullValue" data-tuner-value-for="${id}">${escapeHtml(formatTunerValue(value))}<small> ST</small></div>
          <button class="tunerStepBtn tunerPlusBtn" data-action="tuner-plus" data-tuner-song-id="${id}"${sourceNumber == null ? '' : ` data-tuner-source-number="${sourceNumber}"`}${maxDisabled}>+</button>
        </div>
      `
    }).join('') || '<div class="emptyBox">NENHUMA MÚSICA ENCONTRADA</div>'

    return `
      <div class="tunerFullScreen" data-stop-modal>
        <div class="tunerFullHeader tunerFullTransportHeader">
          <div class="tunerFullTransportActions">
            <button class="${playClass}" data-action="play"${fadeoutStyle}>${playLabel}</button>
            <button class="${stopBreakClass}" data-action="stop-break"${fadeoutStyle}>STOP BREAK</button>
            <button class="tunerFullCloseBtn" data-action="tuner-close">FECHAR</button>
          </div>
        </div>
        <div class="tunerFullList listBox">${rows}</div>
      </div>
    `
  }

  function adjustTunerFromButton(el, delta, absoluteValue = null) {
    const id = String(el?.getAttribute?.('data-tuner-song-id') || '')
    if (!id) return
    const items = state.showTunerScreen ? getMobileTunerSourceItems() : getTunerSourceItems()
    const item = items.find((candidate) => String(getId(candidate)) === id)
    if (!item || isBlock(item) || isHashParent(item)) return
    const key = getTunerItemKey(item)
    const next = clampTunerValue(absoluteValue === null ? getTunerValue(item) + Number(delta || 0) : absoluteValue)
    if (key) state.tunerOptimisticValues[key] = { value: next, until: now() + 4000 }
    const sourceNumberAttr = el.getAttribute('data-tuner-source-number')
    const sourceNumber = sourceNumberAttr !== null && sourceNumberAttr !== '' ? Number(sourceNumberAttr) : getTunerSourceNumber(item)
    postCommand('tuner_set', {
      songId: id,
      targetId: id,
      regionId: id,
      value: next,
      semitones: next,
      sourceNumber: Number.isFinite(sourceNumber) ? sourceNumber : undefined,
      regionNumber: Number.isFinite(sourceNumber) ? sourceNumber : undefined,
      activeTab: state.tunerSourceTab,
      page: state.tunerSourceTab,
    })
    scheduleRender(true)
  }

  function renderPlaylistModal() {
    if (!state.showPlaylistModal) return ''
    const multiProjectPlaylistsAvailable =
      getMultiProjectPlaylistsAvailable()
    const multiProjectPlaylists =
      getMultiProjectPlaylistsEnabled()
    const playlists = getOpenProjectPlaylists()
    const active = playlists.find((playlist) =>
      playlist?.active === true ||
      playlist?.current === true) || null
    const activeId = getOpenPlaylistSelectorId(active)
    const selectedId = String(state.tabletPlaylistPendingId || activeId)
    const selectedPlaylist = playlists.find((playlist, index) =>
      getOpenPlaylistSelectorId(playlist, index) === selectedId) || active
    const copyEnabled = selectedPlaylist &&
      openPlaylistBelongsToCurrentProject(selectedPlaylist)
    const rows = playlists.map((p, index) => {
      const id = escapeHtml(getOpenPlaylistSelectorId(p, index))
      const isActive = selectedId === getOpenPlaylistSelectorId(p, index)
      const title = multiProjectPlaylists
        ? `${p?.name || 'REPERTÓRIO'} — ${p?.projectName || 'SESSÃO'}`
        : `${p?.name || 'REPERTÓRIO'}`
      return `<button class="playlistOption ${isActive ? 'playlistOptionActive' : ''}" data-action="playlist-select" data-playlist-id="${id}"><span class="playlistOptionText">${renderPlaylistOptionTitle(title)}</span><span class="playlistOptionTime">${escapeHtml(getPlaylistTotalText(p))}</span></button>`
    }).join('') || `<div class="emptyBox">NENHUM REPERTÓRIO</div>`
    const buttons = `<div class="modalButtons playlistModalActionButtons"><button class="modalOkBtnWide tabletPlaylistOpenButton" data-action="tablet-playlist-open" ${selectedId ? '' : 'disabled'}>ABRIR</button><button class="modalOkBtnWide tabletPlaylistCopyButton" data-action="tablet-playlist-copy" ${copyEnabled ? '' : 'disabled'}>COPY</button><button class="modalCancelBtn" data-action="modal-close">FECHAR</button></div>`
    const multiTitle = multiProjectPlaylistsAvailable
      ? 'Mostrar repertórios das outras sessões abertas'
      : 'Abra outra sessão que tenha pelo menos um repertório'
    const header = `<div class="playlistModalHeader"><div class="modalTitle">REPERTÓRIOS</div><button class="${multiProjectPlaylists ? 'btnConfigOnGreen' : 'btnConfigOffRed'} playlistMultiButton" data-action="playlist-multi-toggle" aria-pressed="${multiProjectPlaylists ? 'true' : 'false'}" aria-disabled="${multiProjectPlaylistsAvailable ? 'false' : 'true'}" title="${escapeHtml(multiTitle)}"${multiProjectPlaylistsAvailable ? '' : ' disabled'}>${multiProjectPlaylists ? '[x]' : '[ ]'} MULTI</button></div>`
    return `<div class="modalOverlay tabletCenteredModalOverlay tabletPlaylistModalOverlay" data-action="modal-close"><div class="modalSpacer"></div><div class="modalBox playlistModalBox" data-stop-modal>${header}<div class="playlistSelectList">${rows}</div>${buttons}</div><div class="modalBottomSpace"></div></div>`
  }

  function renderProjectModal() {
    if (!state.showProjectModal) return ''
    const projects = getProjects()
    const rows = projects.map((p, index) => {
      const id = escapeHtml(getProjectItemId(p, index))
      const name = escapeHtml(upperText(getProjectItemName(p, index)))
      const active = p?.active === true || p?.isActive === true || p?.isCurrent === true || String(state.snapshot?.activeProjectId || state.snapshot?.currentProjectId || '') === getProjectItemId(p, index)
      return `<button class="playlistOption ${active ? 'playlistOptionActive' : ''}" data-action="project-select" data-project-id="${id}" data-project-index="${index}"><span class="playlistOptionText">${name}</span></button>`
    }).join('') || `<div class="emptyBox">NENHUMA SESSÃO ABERTA</div>`
    return `<div class="modalOverlay tabletCenteredModalOverlay projectModalOverlay" data-action="modal-close"><div class="modalSpacer"></div><div class="modalBox projectModalBox" data-stop-modal><div class="modalTitle">SESSÃO</div><div class="playlistSelectList">${rows}</div><div class="modalButtons"><button class="modalOkBtnWide" data-action="project-modal-ok">OK</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderMixerVolumeModal() {
    if (!state.showMixerVolume || !state.mixerVolumeTarget) return ''
    const id = String(state.mixerVolumeTarget || '')
    const track = findMixerTrackById(id)
    if (!track) return ''
    const ratio = getMixerRatio(track)
    const name = escapeHtml(upperText(getName(track) || 'TRACK'))
    return `<div class="modalOverlay mixerVolumeOverlay"><div class="modalSpacer"></div><div class="modalBox mixerVolumeModalBox mixerVolumeModalBoxWide" data-stop-modal><div class="mixerModalHeader"><div class="modalTitle mixerVolumeTitle">${name}</div><button class="modalCancelBtn" data-action="modal-close">FECHAR</button></div><div class="mixerVolumeDbDisplay">${escapeHtml(formatMixerDb(track))}</div><input class="mixerVolumeSlider mixerVolumeSliderWide" data-action="mixer-volume" data-mixer-id="${escapeHtml(id)}" type="range" min="0" max="1" step="0.001" value="${ratio}"><button class="modalOkBtnWide mixerZeroDbBtn" data-action="mixer-volume-zero" data-mixer-id="${escapeHtml(id)}">0 dB</button></div></div>`
  }

  function renderTimerModal() {
    if (!state.showTimerModal) return ''
    const data = state.snapshot || {}
    const mode = getEffectiveTimerMode(data)
    const running = !!data.timerRunning
    const toggleLabel = running ? 'PARAR' : 'INICIAR'
    const countdown = splitCountdownSec(getCountdownTargetSec(data))
    const countdownInputs = mode === 'countdown'
      ? `<div class="timerCountdownInputs"><label><span>H</span><input id="timerCountdownHours" data-timer-countdown-input data-timer-max="99" type="text" inputmode="numeric" pattern="[0-9]*" autocomplete="off" value="${String(countdown.hours).padStart(2, '0')}"></label><label><span>M</span><input id="timerCountdownMinutes" data-timer-countdown-input data-timer-max="59" type="text" inputmode="numeric" pattern="[0-9]*" autocomplete="off" value="${String(countdown.minutes).padStart(2, '0')}"></label><label><span>S</span><input id="timerCountdownSeconds" data-timer-countdown-input data-timer-max="59" type="text" inputmode="numeric" pattern="[0-9]*" autocomplete="off" value="${String(countdown.seconds).padStart(2, '0')}"></label></div>`
      : ''
    const actionButtons = `<div class="modalButtons timerActionButtons"><button class="${running ? 'btnStopActive' : 'modalOkBtnWide'}" data-action="timer-toggle">${toggleLabel}</button><button class="modalCancelBtn" data-action="modal-close">FECHAR</button></div>`
    return `<div class="modalOverlay"><div class="modalSpacer"></div><div class="modalBox timerModalBox" data-stop-modal><div class="modalTitle">CRONÔMETRO</div><div class="timerModalPreview ${isCountdownOverrun(data) ? 'timerOverrunBlink' : ''}">${escapeHtml(getTimerDisplayText(data))}</div>${countdownInputs}<div class="timerModeGrid"><button class="${mode === 'progressive' ? 'btnAutoplayActive' : 'btn'}" data-action="timer-mode-progressive">PROGRESSIVO</button><button class="${mode === 'countdown' ? 'btnAutoplayActive' : 'btn'}" data-action="timer-mode-countdown">REGRESSIVO</button></div>${actionButtons}</div><div class="modalBottomSpace"></div></div>`
  }

  function renderTimerStopConfirm() {
    if (!state.showConfirmTimerStop) return ''
    return `<div class="modalOverlay" data-action="timer-stop-cancel"><div class="modalSpacer"></div><div class="modalBox" data-stop-modal><div class="modalTitle">PARAR CRONÔMETRO?</div><div class="modalInfoText">O cronômetro será zerado.</div><div class="modalButtons"><button class="modalCancelBtn" data-action="timer-stop-cancel">CANCELAR</button><button class="modalOkBtnWide btnStopActive" data-action="timer-stop-confirm">PARAR</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderTelepromptAppearanceSettings() {
    const selectedFont = getTelepromptFont()
    const selectedColor = getTelepromptColor()
    const fontButtons = TELEPROMPT_FONT_OPTIONS.map((option) => `<button class="btn telepromptSettingsOption telepromptFontPreview telepromptFontPreview-${option.id}${selectedFont === option.id ? ' telepromptSettingsOptionActive' : ''}" data-action="teleprompt-font-set" data-value="${option.id}">${option.label}</button>`).join('')
    const renderColorButton = (option, extra = false) => `<button class="btn telepromptSettingsOption telepromptColorOption${extra ? ' telepromptExtraColorOption' : ''}${selectedColor === option.id ? ' telepromptSettingsOptionActive' : ''}" data-action="teleprompt-color-set" data-value="${option.id}" style="--teleprompt-option-color:${option.color}" aria-label="Cor ${option.label}"><span class="telepromptColorSwatch"></span><span>${option.label}</span></button>`
    const colorButtons = TELEPROMPT_COLOR_OPTIONS.slice(0, 4).map((option) => renderColorButton(option)).join('')
    const extraColors = `<div class="telepromptExtraColorsGrid${state.showTelepromptColorPalette ? '' : ' telepromptExtraColorsGridHidden'}" data-teleprompt-extra-colors>${TELEPROMPT_COLOR_OPTIONS.slice(4).map((option) => renderColorButton(option, true)).join('')}</div>`
    return `<div class="settingsCategory settingsTelepromptCategory"><div class="settingsCategoryTitle">TELEPROMPT — FONTE</div><div class="telepromptSettingsGrid telepromptFontSettingsGrid">${fontButtons}</div><div class="settingsCategoryTitle telepromptColorSettingsTitle">TELEPROMPT — COR DA LETRA</div><div class="telepromptSettingsGrid telepromptColorSettingsGrid">${colorButtons}</div><button class="btn telepromptMoreColorsButton${state.showTelepromptColorPalette ? ' telepromptMoreColorsButtonActive' : ''}" data-action="teleprompt-colors-more" aria-expanded="${state.showTelepromptColorPalette ? 'true' : 'false'}">Mais+</button>${extraColors}</div>`
  }

  function renderSettingsModal() {
    if (!state.showSettingsModal) return ''
    const theme = getAppTheme()
    const borderMode = getBorderColorMode()
    const borderModeLabel = getBorderColorModeLabel(borderMode)
    const telepromptAppearance = renderTelepromptAppearanceSettings()
    if (IS_MUSICIAN_MONITOR) {
      return `<div class="modalOverlay"><div class="modalSpacer"></div><div class="modalBox settingsModalBox musicianSettingsModal" data-stop-modal><div class="modalTitle">CONFIGURAÇÕES</div><div class="settingsCategory"><div class="settingsCategoryTitle">TEMA</div><div class="settingsThemeGrid"><button class="${theme === 'dark' ? 'btnAutoplayActive' : 'btn'}" data-action="theme-dark">MODO ESCURO</button><button class="${theme === 'light' ? 'btnAutoplayActive' : 'btn'}" data-action="theme-light">MODO CLARO</button></div><div class="settingsWideGrid"><button class="btn settingsBorderModeButton" data-action="border-color-mode">${borderModeLabel}</button></div></div>${telepromptAppearance}<div class="modalButtons settingsExitButtons musicianSettingsExitButtons"><button class="modalOkBtnWide btnStopActive settingsExitButton" data-action="exit-app">SAIR</button><button class="modalCancelBtn settingsCloseButton" data-action="modal-close">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
    }
    const sortContext = state.showTunerScreen
      ? (state.tunerSourceTab === 'regions' ? 'regions' : 'playlist')
      : (state.activeTab === 'regions' ? 'regions' : 'playlist')
    const numberMode = getNumberColumnMode()
    const numberSortEnabled = numberMode === 'region' && getNumberOrderItems(sortContext).length > 1
    const interfaceBlocking = getInterfaceBlockingEnabled()
    const hideAccessNotification = state.hideInterfaceAccessNotification
    const familyViewControls = getFamilyViewControlsEnabled()
    const accessControl = `<div class="settingsCategory settingsAccessCategory"><div class="settingsCategoryTitle">ACESSO DA INTERFACE</div><div class="settingsAccessGrid"><button class="${interfaceBlocking ? 'btnConfigOnGreen' : 'btnConfigOffRed'} settingsAccessControlButton" data-action="interface-blocking-toggle">${interfaceBlocking ? '[x]' : '[ ]'} Bloquear o uso da interface quando estiver conectado ao app do Diretor</button><button class="${hideAccessNotification ? 'btnConfigOnGreen' : 'btnConfigOffRed'} settingsAccessControlButton" data-action="interface-access-notification-toggle">${hideAccessNotification ? '[x]' : '[ ]'} Bloquear notificação de acesso da interface</button></div></div>`
    const drawerControl = `<div class="settingsCategory settingsDrawerCategory"><div class="settingsCategoryTitle">GAVETAS</div><div class="settingsWideGrid"><button class="${familyViewControls ? 'btnConfigOnGreen' : 'btnConfigOffRed'}" data-action="family-view-toggle">${familyViewControls ? '[x]' : '[ ]'} VIEW — Mostrar/Ocultar</button></div></div>`
    return `<div class="modalOverlay tabletCenteredModalOverlay tabletSettingsModalOverlay"><div class="modalSpacer"></div><div class="modalBox settingsModalBox" data-stop-modal><div class="modalTitle">CONFIGURAÇÕES</div><div class="settingsCategory"><div class="settingsCategoryTitle">TEMA</div><div class="settingsThemeGrid"><button class="${theme === 'dark' ? 'btnAutoplayActive' : 'btn'}" data-action="theme-dark">MODO ESCURO</button><button class="${theme === 'light' ? 'btnAutoplayActive' : 'btn'}" data-action="theme-light">MODO CLARO</button></div><div class="settingsWideGrid"><button class="btn settingsBorderModeButton" data-action="border-color-mode">${borderModeLabel}</button></div></div><div class="settingsCategory"><div class="settingsCategoryTitle">ORDENS</div><div class="settingsThemeGrid settingsNumberGrid"><button class="${numberMode === 'region' ? 'btnConfigOnGreen' : 'btnConfigOffRed'}" data-action="number-label">NUMBER</button><button class="btn" data-action="number-sort" aria-disabled="${numberSortEnabled ? 'false' : 'true'}"${numberSortEnabled ? '' : ' disabled'}>0-9</button></div></div>${drawerControl}${accessControl}${telepromptAppearance}<div class="modalButtons settingsExitButtons"><button class="modalOkBtnWide btnStopActive settingsExitButton" data-action="exit-app">SAIR</button><button class="modalCancelBtn settingsCloseButton" data-action="modal-close">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderNumberOrderConfirm() {
    const kind = state.numberOrderConfirmKind
    if (!kind || IS_MUSICIAN_MONITOR) return ''
    const context = state.numberOrderConfirmContext === 'regions' ? 'regions' : 'playlist'
    let title = 'NUMBER'
    let info = ''
    if (kind === 'number') {
      if (state.numberOrderConfirmUseRegionId) {
        info = context === 'playlist'
          ? 'A lista será reorganizada de acordo com o ID da região. Os blocos permanecerão exatamente onde estão.'
          : 'A lista será reorganizada de acordo com o ID da região.'
      } else {
        info = 'A numeração voltará a seguir a ordem da própria lista.'
      }
    } else {
      title = 'ORGANIZAR 0-9'
      info = state.numberOrderConfirmDescending
        ? 'Organizar do maior para o menor?'
        : 'Organizar do menor para o maior?'
    }
    return `<div class="modalOverlay tabletCenteredModalOverlay numberOrderConfirmOverlay"><div class="modalSpacer"></div><div class="modalBox numberOrderConfirmModal" data-stop-modal><div class="modalTitle">${title}</div><div class="modalInfoText">${info}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="number-order-cancel">CANCELAR</button><button class="modalOkBtnWide" data-action="number-order-confirm">CONFIRMAR</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function closeSettingsModalInPlace() {
    state.showSettingsModal = false
    state.showTelepromptColorPalette = false
    const box = root.querySelector('.settingsModalBox')
    const overlay = box?.closest?.('.modalOverlay')
    if (overlay) overlay.remove()
    else if (box) box.remove()
    root.querySelectorAll('[data-action="settings"]').forEach((button) => {
      button.classList.remove('tabletSidebarButtonActive')
    })
  }

  function renderLiveConfirm() {
    if (!state.showConfirmLiveOff) return ''
    const disabling = getLiveEnabled()
    const title = disabling ? 'DESATIVAR MODO LIVE?' : 'ATIVAR MODO LIVE?'
    const info = disabling
      ? 'Todas as marcações de músicas já tocadas serão apagadas.'
      : 'Cada música é marcada após 10 segundos. Uma região-pai só é marcada depois que todos os filhos dela forem tocados.'
    const action = disabling ? 'DESATIVAR' : 'ATIVAR'
    return `<div class="modalOverlay tabletCenteredModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletLiveConfirmModal" data-stop-modal><div class="modalTitle">${title}</div><div class="modalInfoText">${info}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="cancel-live-off">CANCELAR</button><button class="modalOkBtnWide" data-action="confirm-live-off">${action}</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderMenu() {
    if (!state.showMenu) return ''
    const atBlClass = getAutoBlocoEnabled() ? 'topMenuFlyoutBtn topMenuFlyoutBtnAtbl topMenuFlyoutBtnActive' : 'topMenuFlyoutBtn topMenuFlyoutBtnAtbl'
    const liveEnabled = getLiveEnabled()
    const liveClass = liveEnabled
      ? 'topMenuFlyoutBtn topMenuFlyoutBtnLive topMenuFlyoutBtnLiveOn topMenuFlyoutBtnActive'
      : 'topMenuFlyoutBtn topMenuFlyoutBtnLive topMenuFlyoutBtnLiveOff'
    const bypassActive = getMultiLoopBypassActive()
    const bypassClass = bypassActive
      ? 'topMenuFlyoutBtn topMenuFlyoutBtnBy topMenuFlyoutBtnByOn topMenuFlyoutBtnActive'
      : 'topMenuFlyoutBtn topMenuFlyoutBtnBy topMenuFlyoutBtnByOff'
    return `
      <div class="topMenuFlyout" data-stop-menu>
        <button class="topMenuFlyoutBtn" data-action="tablet-search">LUPA</button>
        <button class="topMenuFlyoutBtn" data-action="project-selector">SESSÃO</button>
        <button class="topMenuFlyoutBtn" data-action="go-mixer">MIXER</button>
        <button class="topMenuFlyoutBtn topMenuFlyoutBtnTuner" data-action="tuner-focus">TUNER</button>
        <button class="topMenuFlyoutBtn topMenuFlyoutBtnRecados" data-action="toggle-notice">RECADOS</button>
        <button class="${liveClass}" data-action="live" aria-pressed="${liveEnabled ? 'true' : 'false'}">MODO LIVE</button>
        <button class="${bypassClass}" data-action="multiloop-bypass" aria-label="Bypass dos multiloops" aria-pressed="${bypassActive ? 'true' : 'false'}">BY</button>
        ${state.activeTab === 'regions' ? '' : `<button class="${atBlClass}" data-action="atbl-toggle">AT/BL</button>`}
      </div>
    `
  }


  function normalizeDirectorNoticeColor(value, fallback) {
    const text = String(value || '').trim()
    return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback
  }

  function getDirectorTechnicalNoticeNow() {
    const offset = Number(state.technicalNoticeServerOffsetMs || 0)
    return now() + (Number.isFinite(offset) ? offset : 0)
  }

  function normalizeDirectorTechnicalNotice(notice) {
    if (!notice || typeof notice !== 'object') return null
    const text = String(notice.text || notice.message || '').trim()
    const expiresAt = Number(notice.expiresAt || 0)
    if (!text || !Number.isFinite(expiresAt) || expiresAt <= getDirectorTechnicalNoticeNow()) return null
    return {
      ...notice,
      text,
      expiresAt,
      source: String(notice.source || '').trim().toLowerCase(),
    }
  }

  function getDirectorTechnicalNotice(data = state.snapshot) {
    const notice = state.technicalNoticeSnapshotReady
      ? state.technicalNoticeSnapshot
      : (data?.technicalNotice && typeof data.technicalNotice === 'object' ? data.technicalNotice : null)
    return normalizeDirectorTechnicalNotice(notice)
  }

  function getDirectorTechnicalNoticeSettings(data = state.snapshot) {
    const raw = data?.technicalNoticeSettings && typeof data.technicalNoticeSettings === 'object'
      ? data.technicalNoticeSettings
      : {}
    const allowedFonts = ['Arial', 'Segoe UI', 'Verdana', 'Tahoma', 'Georgia', 'Trebuchet MS', 'Impact']
    const fontFamily = allowedFonts.includes(String(raw.fontFamily || '')) ? String(raw.fontFamily) : 'Arial'
    const emoji = String(raw.emoji || '⚠️').trim().replace(/[\r\n\t]+/g, '').slice(0, 8) || '⚠️'
    return {
      textColor: normalizeDirectorNoticeColor(raw.textColor, '#ffea00'),
      backgroundColor: normalizeDirectorNoticeColor(raw.backgroundColor, '#000000'),
      flashColor: normalizeDirectorNoticeColor(raw.flashColor, '#ff0000'),
      fontFamily,
      emojiEnabled: raw.emojiEnabled !== false,
      emoji,
    }
  }

  function formatDirectorTechnicalNoticeText(notice, data = state.snapshot) {
    const text = String(notice?.text || '').trim()
    if (!text) return ''
    const settings = getDirectorTechnicalNoticeSettings(data)
    return settings.emojiEnabled ? `${settings.emoji} ${text} ${settings.emoji}` : text
  }

  function getDirectorTechnicalNoticeKey(data = state.snapshot) {
    const notice = getDirectorTechnicalNotice(data)
    if (!notice) return ''
    return String(notice.id || notice.updatedAt || `${notice.source}:${notice.text}:${notice.expiresAt}`)
  }

  function renderDirectorTechnicalNotice(data = state.snapshot) {
    const notice = getDirectorTechnicalNotice(data)
    if (!notice) return ''
    const settings = getDirectorTechnicalNoticeSettings(data)
    const style = `--director-notice-text:${settings.textColor};--director-notice-background:${settings.backgroundColor};--director-notice-flash:${settings.flashColor};--director-notice-font:${escapeHtml(settings.fontFamily)}, sans-serif;`
    return `<div class="directorTpTechnicalNotice directorTpTechnicalNoticeFlash" style="${style}" data-director-technical-notice data-notice-id="${escapeHtml(getDirectorTechnicalNoticeKey(data))}" aria-live="assertive">${escapeHtml(formatDirectorTechnicalNoticeText(notice, data))}</div>`
  }

  function syncDirectorTechnicalNoticeDom() {
    if (!state.showTelepromptScreen) return
    const viewport = root.querySelector('[data-director-tp-viewport]')
    if (!viewport) return
    const notice = getDirectorTechnicalNotice(state.snapshot)
    let element = viewport.querySelector('[data-director-technical-notice]')
    if (!notice) {
      if (element) element.remove()
      return
    }

    const settings = getDirectorTechnicalNoticeSettings(state.snapshot)
    const key = getDirectorTechnicalNoticeKey(state.snapshot)
    if (!element) {
      element = document.createElement('div')
      element.className = 'directorTpTechnicalNotice directorTpTechnicalNoticeFlash'
      element.setAttribute('data-director-technical-notice', '')
      element.setAttribute('aria-live', 'assertive')
      viewport.appendChild(element)
    }

    const previousKey = String(element.getAttribute('data-notice-id') || '')
    element.setAttribute('data-notice-id', key)
    element.style.setProperty('--director-notice-text', settings.textColor)
    element.style.setProperty('--director-notice-background', settings.backgroundColor)
    element.style.setProperty('--director-notice-flash', settings.flashColor)
    element.style.setProperty('--director-notice-font', `${settings.fontFamily}, sans-serif`)
    const displayText = formatDirectorTechnicalNoticeText(notice, state.snapshot)
    if (element.textContent !== displayText) element.textContent = displayText

    if (previousKey !== key) {
      element.classList.remove('directorTpTechnicalNoticeFlash')
      void element.offsetWidth
      element.classList.add('directorTpTechnicalNoticeFlash')
    }
  }

  async function pollDirectorTechnicalNotice() {
    if (isDirectorRecadosInputFocused()) return
    if (state.technicalNoticePollInFlight) return
    state.technicalNoticePollInFlight = true
    const abort = withTimeout(POLL_TIMEOUT_MS)
    const previousKey = getDirectorTechnicalNoticeKey(state.snapshot)
    try {
      const response = await fetch(bridgeUrl('/technical-notice'), { cache: 'no-store', signal: abort.signal })
      if (!response.ok) throw new Error(`technical-notice ${response.status}`)
      const payload = await response.json()
      const serverNow = Number(payload?.now)
      if (Number.isFinite(serverNow) && serverNow > 0) {
        state.technicalNoticeServerOffsetMs = serverNow - now()
      }
      state.technicalNoticeSnapshot = payload?.notice && typeof payload.notice === 'object' ? payload.notice : null
      state.technicalNoticeSnapshotReady = true
      state.technicalNoticeLastGoodAt = now()
      syncDirectorRecadosFromSnapshot(state.snapshot)
      const nextKey = getDirectorTechnicalNoticeKey(state.snapshot)
      if (nextKey !== previousKey) scheduleRender()
      syncDirectorTechnicalNoticeDom()
      syncTransportSeekModalDom()
      syncDirectorRecadosDom()
    } catch (_) {
      // Mantém o último recado válido durante falhas curtas de rede.
      if (state.technicalNoticeSnapshotReady && !getDirectorTechnicalNotice(state.snapshot)) {
        state.technicalNoticeSnapshot = null
        syncDirectorTechnicalNoticeDom()
      }
    } finally {
      abort.done()
      state.technicalNoticePollInFlight = false
    }
  }

  function getDirectorRecadosRemainingSeconds() {
    if (state.recadosPinned) return Math.max(0, Math.ceil(Number(state.recadosNoticeRemainingMs || 0) / 1000))
    const remainingMs = Math.max(0, Number(state.recadosNoticeExpiresAt || 0) - getDirectorTechnicalNoticeNow())
    return remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0
  }

  function getDirectorRecadosStatusText() {
    const remaining = getDirectorRecadosRemainingSeconds()
    if (remaining > 0) return `RECADO ATIVO: ${remaining}s`
    if (Number(state.recadosNoticeExpiresAt || 0) > 0 && state.recadosStatus === 'RECADO ATIVO') return 'RECADO EXPIRADO'
    return state.recadosStatus || ''
  }

  function syncDirectorRecadosFromSnapshot(data = state.snapshot) {
    const templates = data?.technicalNoticeSettings?.recadosTemplates
    if (Array.isArray(templates)) {
      state.recadosTemplates = [0, 1, 2].map((index) => String(templates[index] || '').slice(0, 500))
      const images = data?.technicalNoticeSettings?.recadosImages
      if (Array.isArray(images)) {
        state.recadosTemplateImages = [0, 1, 2].map(
          (index) => String(images[index] || ''))
      }
      if (state.recadosSelectedSlot !== 'global' && !state.recadosEditingTemplate && !state.recadosTextFocused && document.activeElement?.id !== 'directorRecadosTextInput') {
        state.recadosDraft = state.recadosTemplates[Number(state.recadosSelectedSlot)] || ''
      }
    }
    const notice = getDirectorTechnicalNotice(data)
    if (!notice || notice.source !== 'director') {
      if (getDirectorRecadosRemainingSeconds() <= 0) {
        if (Number(state.recadosNoticeExpiresAt || 0) > 0 && state.recadosStatus === 'RECADO ATIVO') {
          state.recadosStatus = 'RECADO EXPIRADO'
        }
        state.recadosNoticeExpiresAt = 0
        state.recadosNoticeId = ''
        state.recadosNoticeRemainingMs = 0
        state.recadosPinned = false
      }
      return
    }
    state.recadosNoticeExpiresAt = Number(notice.expiresAt || 0)
    state.recadosNoticeId = String(notice.id || '')
    state.recadosNoticeRemainingMs = Math.max(0, Number(notice.pausedRemainingMs || 0))
    state.recadosPinned = notice.pinned === true
  }

  function isDirectorRecadosInputFocused() {
    return state.recadosTextFocused || document.activeElement?.id === 'directorRecadosTextInput'
  }

  function formatDirectorRecadosError(error, fallback) {
    const message = String(error?.message || '').trim()
    const normalized = message.toLocaleLowerCase('pt-BR')
    if (error?.name === 'AbortError' || normalized.includes('abort')) {
      return 'O ENVIO DEMOROU DEMAIS. VERIFIQUE A CONEXÃO E TENTE NOVAMENTE.'
    }
    if (
      normalized.includes('failed to fetch') ||
      normalized.includes('fetch failed') ||
      normalized.includes('load failed') ||
      normalized.includes('networkerror') ||
      normalized.includes('network request failed') ||
      normalized.includes('internet connection appears to be offline')
    ) {
      return 'NÃO FOI POSSÍVEL CONECTAR AO VS HOOK. VERIFIQUE A REDE E TENTE NOVAMENTE.'
    }
    return String(
      message || fallback || 'NÃO FOI POSSÍVEL CONCLUIR A OPERAÇÃO.')
      .toLocaleUpperCase('pt-BR')
  }

  function setDirectorRecadosAppHeight() {
    if (isDirectorRecadosInputFocused()) return
    const height = Math.max(360, Math.floor(window.innerHeight || document.documentElement.clientHeight || 640))
    document.documentElement.style.setProperty('--recados-app-height', `${height}px`)
  }

  function restoreDirectorRecadosViewport() {
    if (typeof window.setDirectorTabletKeyboardOpen === 'function') window.setDirectorTabletKeyboardOpen(false)
    if (state.recadosViewportRestoreTimer) window.clearTimeout(state.recadosViewportRestoreTimer)
    const finishRestore = () => {
      const classes = document.documentElement.classList
      if (classes.contains('directorTabletKeyboardOpen') || classes.contains('directorTabletViewportRestoring')) {
        state.recadosViewportRestoreTimer = window.setTimeout(finishRestore, 80)
        return
      }
      state.recadosViewportRestoreTimer = 0
      setDirectorRecadosAppHeight()
      updateViewportHeight()
    }
    state.recadosViewportRestoreTimer = window.setTimeout(finishRestore, 80)
  }

  function syncDirectorRecadosDom() {
    if (!state.showRecadosScreen) return
    const project = root.querySelector('[data-director-recados-project]')
    if (project) project.textContent = getProjectName(state.snapshot)
    const input = document.getElementById('directorRecadosTextInput')
    if (input && document.activeElement !== input && input.value !== state.recadosDraft) input.value = state.recadosDraft
    const status = root.querySelector('[data-director-recados-status]')
    if (status) status.textContent = getDirectorRecadosStatusText()
    const sendButton = root.querySelector('[data-action="recados-send"]')
    if (sendButton) {
      sendButton.disabled = !!state.recadosSending
      sendButton.textContent = state.recadosSending ? 'ENVIANDO...' : 'ENVIAR'
    }
    const cancelButton = root.querySelector('[data-action="recados-cancel"]')
    if (cancelButton) cancelButton.disabled = !!state.recadosSending
  }

  function setDirectorRecadosTouchMode(enabled) {
    const value = enabled ? 'auto' : 'manipulation'
    const tabletPortrait = !!enabled && document.documentElement.dataset.directorDevice === 'tablet'
    try { document.documentElement.style.touchAction = value } catch (_) {}
    try { document.body.style.touchAction = value } catch (_) {}
    try { document.documentElement.classList.toggle('directorRecadosTouchMode', !!enabled) } catch (_) {}
    try { document.body.classList.toggle('directorRecadosTouchMode', !!enabled) } catch (_) {}
    try { document.documentElement.classList.toggle('directorRecadosPortraitMode', tabletPortrait) } catch (_) {}
    try { document.body.classList.toggle('directorRecadosPortraitMode', tabletPortrait) } catch (_) {}
  }

  function openDirectorRecadosScreen() {
    state.showMenu = false
    state.showPlaylistModal = false
    state.showProjectModal = false
    state.showMarkersOverlay = false
    state.showTimerModal = false
    state.showSettingsModal = false
    state.showTunerScreen = false
    state.showTelepromptScreen = false
    state.showPremixScreen = false
    state.showMixerVolume = false
    state.showRecadosScreen = true
    setDirectorRecadosTouchMode(true)
    stopDirectorVisualLoops()
    state.recadosTextFocused = false
    setDirectorRecadosAppHeight()
    state.recadosSelectedSlot = 'global'
    state.recadosEditingTemplate = false
    state.recadosDraft = state.recadosGlobalDraft
    syncDirectorRecadosFromSnapshot(state.snapshot)
    try {
      sessionStorage.setItem(
        'vshook_director_recados_session_hash',
        getAuthHash(state.snapshot))
    } catch (_) {}
    scheduleRender(true)
  }

  function getDirectorSelectedRecadoImage() {
    if (state.recadosSelectedSlot === 'global') return ''
    return String(
      state.recadosTemplateImages[
        Number(state.recadosSelectedSlot)] || '')
  }

  function getDirectorRecadoImageUrl(imagePath) {
    const value = String(imagePath || '').trim()
    return value
      ? bridgeUrl(`/media?path=${encodeURIComponent(value)}`)
      : ''
  }

  function readDirectorRecadoImageFile(file) {
    return new Promise((resolve, reject) => {
      if (!file || !String(file.type || '').startsWith('image/')) {
        reject(new Error('Escolha um arquivo de imagem.'))
        return
      }
      if (Number(file.size || 0) > 25 * 1024 * 1024) {
        reject(new Error('A imagem deve ter no máximo 25 MB.'))
        return
      }
      const reader = new FileReader()
      reader.onerror = () => reject(
        new Error('Não foi possível ler a imagem.'))
      reader.onload = () => {
        const image = new Image()
        image.onerror = () => reject(new Error('Imagem inválida.'))
        image.onload = () => {
          const maxSide = 1600
          const sourceWidth = Math.max(
            1, Number(image.naturalWidth || image.width || 1))
          const sourceHeight = Math.max(
            1, Number(image.naturalHeight || image.height || 1))
          const scale = Math.min(
            1, maxSide / sourceWidth, maxSide / sourceHeight)
          const width = Math.max(1, Math.round(sourceWidth * scale))
          const height = Math.max(1, Math.round(sourceHeight * scale))
          const canvas = document.createElement('canvas')
          canvas.width = width
          canvas.height = height
          const context = canvas.getContext('2d', { alpha: false })
          if (!context) {
            reject(new Error('Não foi possível preparar a imagem.'))
            return
          }
          context.fillStyle = '#000'
          context.fillRect(0, 0, width, height)
          context.drawImage(image, 0, 0, width, height)
          resolve(canvas.toDataURL('image/jpeg', 0.74))
        }
        image.src = String(reader.result || '')
      }
      reader.readAsDataURL(file)
    })
  }

  function applyDirectorRecadosTemplates(result = {}) {
    state.recadosTemplates = [0, 1, 2].map(
      (index) => String(result.templates?.[index] || ''))
    state.recadosTemplateImages = [0, 1, 2].map(
      (index) => String(result.images?.[index] || ''))
  }

  async function saveDirectorRecadoImage(imageDataUrl) {
    if (state.recadosSelectedSlot === 'global' ||
        state.recadosSending) return
    state.recadosSending = true
    state.recadosStatus = 'SALVANDO IMAGEM...'
    syncDirectorRecadosDom()
    const abort = withTimeout(RECADO_IMAGE_UPLOAD_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/recados-templates'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          index: Number(state.recadosSelectedSlot),
          updateImage: true,
          imageDataUrl,
          source: 'director',
          sessionHash: getAuthHash(state.snapshot),
        }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) {
        throw new Error(result.error || 'Falha ao salvar a imagem')
      }
      applyDirectorRecadosTemplates(result)
      state.recadosStatus = 'IMAGEM SALVA'
      scheduleRender(true)
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO SALVAR A IMAGEM')
    } finally {
      abort.done()
      state.recadosSending = false
      syncDirectorRecadosDom()
    }
  }

  async function chooseDirectorRecadoImage(input) {
    const file = input?.files?.[0]
    if (!file) return
    try {
      const imageDataUrl = await readDirectorRecadoImageFile(file)
      await saveDirectorRecadoImage(imageDataUrl)
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'IMAGEM INVÁLIDA')
      syncDirectorRecadosDom()
    } finally {
      if (input) input.value = ''
    }
  }

  async function removeDirectorRecadoImage() {
    if (state.recadosSelectedSlot === 'global' ||
        state.recadosSending) return
    state.recadosSending = true
    state.recadosStatus = 'REMOVENDO IMAGEM...'
    syncDirectorRecadosDom()
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/recados-templates'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          index: Number(state.recadosSelectedSlot),
          updateImage: true,
          imagePath: '',
          source: 'director',
          sessionHash: getAuthHash(state.snapshot),
        }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) {
        throw new Error(result.error || 'Falha ao remover a imagem')
      }
      applyDirectorRecadosTemplates(result)
      state.recadosStatus = 'IMAGEM REMOVIDA'
      scheduleRender(true)
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO REMOVER A IMAGEM')
    } finally {
      abort.done()
      state.recadosSending = false
      syncDirectorRecadosDom()
    }
  }

  function selectDirectorRecadosSlot(slot) {
    const next = slot === 'global' ? 'global' : Math.max(0, Math.min(2, Number(slot)))
    if (state.recadosSelectedSlot === 'global') state.recadosGlobalDraft = state.recadosDraft
    state.recadosSelectedSlot = next
    state.recadosEditingTemplate = false
    state.recadosDraft = next === 'global' ? state.recadosGlobalDraft : (state.recadosTemplates[next] || '')
    state.recadosStatus = ''
    scheduleRender(true)
  }

  async function toggleDirectorRecadosTemplateEdit() {
    if (state.recadosSelectedSlot === 'global') return
    if (!state.recadosEditingTemplate) {
      state.recadosEditingTemplate = true
      scheduleRender(true)
      requestAnimationFrame(() => document.getElementById('directorRecadosTextInput')?.focus())
      return
    }
    const input = document.getElementById('directorRecadosTextInput')
    const text = String(input?.value ?? state.recadosDraft ?? '').trim().slice(0, 500)
    state.recadosDraft = text
    state.recadosSending = true
    state.recadosStatus = 'SALVANDO...'
    syncDirectorRecadosDom()
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/recados-templates'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          index: Number(state.recadosSelectedSlot),
          text,
          updateText: true,
          source: 'director',
          sessionHash: getAuthHash(state.snapshot),
        }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao salvar')
      applyDirectorRecadosTemplates(result)
      state.recadosEditingTemplate = false
      state.recadosStatus = 'RECADO SALVO'
      scheduleRender(true)
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO SALVAR')
    } finally {
      abort.done()
      state.recadosSending = false
      syncDirectorRecadosDom()
    }
  }

  function closeDirectorRecadosScreen() {
    if (!state.showRecadosScreen) return
    const input = document.getElementById('directorRecadosTextInput')
    if (input) state.recadosDraft = input.value
    state.showRecadosScreen = false
    setDirectorRecadosTouchMode(false)
    state.recadosTextFocused = false
    restoreDirectorRecadosViewport()
    state.recadosStatus = ''
    try {
      sessionStorage.removeItem(
        'vshook_director_recados_session_hash')
    } catch (_) {}
    startDirectorVisualLoops()
    pollBridge()
    pollDirectorTechnicalNotice()
    scheduleRender(true)
  }

  async function exitDirectorRecadosScreen() {
    await cancelDirectorRecado()
    closeDirectorRecadosScreen()
  }

  async function sendDirectorRecado() {
    const input = document.getElementById('directorRecadosTextInput')
    if (input) state.recadosDraft = input.value
    const text = String(state.recadosDraft || '').trim()
    const imagePath = getDirectorSelectedRecadoImage()
    if ((!text && !imagePath) || state.recadosSending) {
      if (!text && !imagePath) {
        state.recadosStatus =
          'DIGITE UM RECADO OU ESCOLHA UMA IMAGEM'
      }
      syncDirectorRecadosDom()
      return
    }
    state.recadosSending = true
    state.recadosStatus = 'ENVIANDO...'
    syncDirectorRecadosDom()
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/technical-notice'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          source: 'director',
          text: imagePath ? '' : text,
          imagePath,
          sessionHash: getAuthHash(state.snapshot),
          durationMs: 20000,
          pinned: state.recadosPinned === true,
        }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao enviar')
      state.recadosNoticeExpiresAt = Number(result?.notice?.expiresAt || 0) || (now() + 20000)
      state.recadosNoticeId = String(result?.notice?.id || '')
      state.recadosNoticeRemainingMs = Math.max(0, Number(result?.notice?.pausedRemainingMs || 0))
      state.recadosPinned = result?.notice?.pinned === true
      state.recadosStatus = 'RECADO ATIVO'
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO ENVIAR')
    } finally {
      abort.done()
      state.recadosSending = false
      syncDirectorRecadosDom()
    }
  }

  async function cancelDirectorRecado() {
    if (state.recadosSending) return
    state.recadosSending = true
    state.recadosStatus = 'CANCELANDO...'
    syncDirectorRecadosDom()
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/technical-notice'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'cancel',
          source: 'director',
          sessionHash: getAuthHash(state.snapshot),
        }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao cancelar')
      state.recadosNoticeExpiresAt = 0
      state.recadosNoticeId = ''
      state.recadosNoticeRemainingMs = 0
      state.recadosPinned = false
      state.recadosStatus = 'RECADO REMOVIDO'
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO CANCELAR')
    } finally {
      abort.done()
      state.recadosSending = false
      syncDirectorRecadosDom()
    }
  }

  async function toggleDirectorRecadosPin() {
    const input = document.getElementById('directorRecadosTextInput')
    if (input) {
      state.recadosDraft = input.value
      if (state.recadosSelectedSlot === 'global') state.recadosGlobalDraft = input.value
    }
    const pinned = !state.recadosPinned
    if (!state.recadosNoticeId) {
      state.recadosPinned = pinned
      state.recadosStatus = ''
      scheduleRender(true)
      return
    }
    state.recadosSending = true
    state.recadosStatus = 'ATUALIZANDO...'
    syncDirectorRecadosDom()
    const abort = withTimeout(COMMAND_TIMEOUT_MS)
    try {
      const response = await fetch(bridgeUrl('/technical-notice'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: pinned ? 'pin' : 'unpin', source: 'director', sessionHash: getAuthHash(state.snapshot) }),
        signal: abort.signal,
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao atualizar')
      state.recadosPinned = result?.notice?.pinned === true
      state.recadosNoticeExpiresAt = Number(result?.notice?.expiresAt || 0)
      state.recadosNoticeRemainingMs = Math.max(0, Number(result?.notice?.pausedRemainingMs || 0))
      state.recadosStatus = 'RECADO ATIVO'
    } catch (error) {
      state.recadosStatus = formatDirectorRecadosError(
        error, 'ERRO AO ATUALIZAR')
    } finally {
      abort.done()
      state.recadosSending = false
      scheduleRender(true)
    }
  }


  function normalizeDirectorTelepromptType(value, pathValue = '') {
    const declared = String(value || '').trim().toLowerCase()
    const cleanPath = String(pathValue || '').trim().split('?')[0].split('#')[0].toLowerCase()
    const ext = cleanPath.includes('.') ? cleanPath.slice(cleanPath.lastIndexOf('.') + 1) : ''
    if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'svg'].includes(ext)) return 'image'
    if (['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'].includes(ext)) return 'video'
    if (declared === 'image' || declared === 'img' || declared === 'picture') return 'image'
    if (declared === 'video' || declared === 'movie') return 'video'
    if (declared === 'empty' || declared === 'none') return 'empty'
    return 'text'
  }

  function getDirectorTelepromptState(slot = state.telepromptSlot, data = state.snapshot) {
    const normalizedSlot = Number(slot) === 2 ? 2 : 1
    const prefix = `tp${normalizedSlot}`
    const nested = data?.[prefix] && typeof data[prefix] === 'object' ? data[prefix] : {}
    const mediaPath = String(
      nested.mediaPath
      || nested.path
      || data?.[`${prefix}MediaPath`]
      || data?.[`telepromptTp${normalizedSlot}MediaPath`]
      || ''
    ).trim()
    const mediaUrl = String(
      nested.mediaUrl
      || nested.url
      || data?.[`${prefix}MediaUrl`]
      || data?.[`telepromptTp${normalizedSlot}MediaUrl`]
      || ''
    ).trim()
    const declaredType = nested.mediaType
      || nested.telepromptType
      || nested.type
      || data?.[`${prefix}MediaType`]
      || data?.[`telepromptTp${normalizedSlot}MediaType`]
      || ''
    const text = String(
      nested.overlayText
      ?? nested.lyricsText
      ?? nested.lyrics
      ?? nested.text
      ?? data?.[`${prefix}LyricsText`]
      ?? data?.[`${prefix}Lyrics`]
      ?? data?.[`telepromptTp${normalizedSlot}Lyrics`]
      ?? data?.[`telepromptTp${normalizedSlot}Text`]
      ?? ''
    )
    const songName = upperText(
      nested.songName
      || nested.song
      || nested.currentSongName
      || data?.[`${prefix}SongName`]
      || data?.[`telepromptTp${normalizedSlot}SongName`]
      || ''
    )
    const type = normalizeDirectorTelepromptType(declaredType, mediaPath || mediaUrl)
    const currentTime = Math.max(0, Number(
      nested.mediaCurrentTime
      ?? nested.currentTime
      ?? data?.[`${prefix}MediaCurrentTime`]
      ?? 0
    ) || 0)
    const mediaOffset = Math.max(0, Number(
      nested.mediaOffset
      ?? data?.[`${prefix}MediaOffset`]
      ?? 0
    ) || 0)
    const playrate = Math.max(0.1, Math.min(4, Number(
      nested.mediaPlayrate
      ?? nested.playrate
      ?? data?.[`${prefix}MediaPlayrate`]
      ?? 1
    ) || 1))
    const playing = nested.playing !== undefined ? nested.playing === true : isPlaying(data)
    const itemIndex = Number(nested.itemIndex ?? -1)
    const itemStart = Number(nested.itemStart ?? 0) || 0
    const itemEnd = Number(nested.itemEnd ?? 0) || 0
    const nextMediaPath = String(
      nested.nextMediaPath
      || data?.[`${prefix}NextMediaPath`]
      || data?.[`telepromptTp${normalizedSlot}NextMediaPath`]
      || ''
    ).trim()
    const nextMediaUrl = String(
      nested.nextMediaUrl
      || data?.[`${prefix}NextMediaUrl`]
      || data?.[`telepromptTp${normalizedSlot}NextMediaUrl`]
      || ''
    ).trim()
    const nextMediaType = normalizeDirectorTelepromptType(
      nested.nextMediaType
      || data?.[`${prefix}NextMediaType`]
      || data?.[`telepromptTp${normalizedSlot}NextMediaType`]
      || '',
      nextMediaPath || nextMediaUrl
    )
    const nextMediaOffset = Math.max(0, Number(
      nested.nextMediaOffset
      ?? data?.[`${prefix}NextMediaOffset`]
      ?? 0
    ) || 0)
    const nextMediaPlayrate = Math.max(0.1, Math.min(4, Number(
      nested.nextMediaPlayrate
      ?? data?.[`${prefix}NextMediaPlayrate`]
      ?? 1
    ) || 1))
    const nextMediaStart = Number(
      nested.nextMediaStart
      ?? data?.[`${prefix}NextMediaStart`]
      ?? 0
    ) || 0
    const nextMediaEnd = Number(
      nested.nextMediaEnd
      ?? data?.[`${prefix}NextMediaEnd`]
      ?? 0
    ) || 0
    return {
      slot: normalizedSlot,
      type,
      mediaPath,
      mediaUrl,
      text,
      songName,
      currentTime,
      mediaOffset,
      playrate,
      playing,
      itemIndex,
      itemStart,
      itemEnd,
      itemFound: nested.itemFound !== false && (nested.itemFound === true || !!text.trim() || !!mediaPath || !!mediaUrl),
      nextMedia: {
        type: nextMediaType,
        mediaPath: nextMediaPath,
        mediaUrl: nextMediaUrl,
        mediaOffset: nextMediaOffset,
        playrate: nextMediaPlayrate,
        itemStart: nextMediaStart,
        itemEnd: nextMediaEnd,
        itemFound: nested.nextMediaFound !== false &&
          (nested.nextMediaFound === true ||
           !!nextMediaPath || !!nextMediaUrl),
      },
    }
  }

  function getDirectorTelepromptMediaUrl(tp) {
    const appendVideoStart = (url) => {
      if (tp?.type !== 'video') return url
      const start = Math.max(0, Number(tp?.mediaOffset) || 0)
      return start > 0.001 ? `${url}#t=${start.toFixed(3)}` : url
    }
    const rawUrl = String(tp?.mediaUrl || '').trim()
    if (rawUrl) {
      if (/^https?:\/\//i.test(rawUrl)) return appendVideoStart(rawUrl)
      const localUrl = rawUrl.startsWith('/') ? rawUrl : `/${rawUrl}`
      const optimizedUrl = tp?.type === 'image'
        ? `${localUrl}${localUrl.includes('?') ? '&' : '?'}preview=low`
        : localUrl
      return appendVideoStart(bridgeUrl(optimizedUrl))
    }
    const rawPath = String(tp?.mediaPath || '').trim()
    if (!rawPath) return ''
    const preview = tp?.type === 'image' ? '&preview=low' : ''
    return appendVideoStart(
      bridgeUrl(`/media?path=${encodeURIComponent(rawPath)}${preview}`)
    )
  }

  function getDirectorTelepromptContentKey(slot = state.telepromptSlot, data = state.snapshot) {
    const tp = getDirectorTelepromptState(slot, data)
    return [tp.slot, tp.type, tp.mediaPath, tp.mediaUrl, tp.text, tp.songName, tp.itemIndex, tp.itemStart, tp.itemEnd].join('|')
  }

  function discardDirectorTelepromptWarmup(media) {
    if (!media) return
    if (typeof HTMLVideoElement !== 'undefined' &&
        media instanceof HTMLVideoElement) {
      try { media.pause() } catch (_) {}
      media.removeAttribute('src')
      try { media.load() } catch (_) {}
      try { media.remove() } catch (_) {}
    }
  }

  function getDirectorTelepromptPreloadHost() {
    let host = document.getElementById(
      'directorTpMediaPreloadHost')
    if (host) return host
    host = document.createElement('div')
    host.id = 'directorTpMediaPreloadHost'
    host.setAttribute('aria-hidden', 'true')
    host.style.cssText =
      'position:fixed;left:-10000px;top:-10000px;width:1px;height:1px;overflow:hidden;opacity:.001;pointer-events:none'
    document.body.appendChild(host)
    return host
  }

  function warmDirectorTelepromptDescriptor(
    descriptor, options = {}) {
    const mediaUrl =
      getDirectorTelepromptMediaUrl(descriptor)
    if (!mediaUrl ||
        (descriptor?.type !== 'image' &&
         descriptor?.type !== 'video')) return
    if (descriptor.type === 'video' &&
        options.allowVideo !== true) return
    const cacheKey = `${descriptor.type}|${mediaUrl}`
    const existing = directorTpMediaWarmups.get(cacheKey)
    if (existing) {
      if (descriptor.type === 'video' &&
          options.videoPreload === 'auto' &&
          existing.preload !== 'auto') {
        existing.preload = 'auto'
        existing.setAttribute('preload', 'auto')
        try { existing.load() } catch (_) {}
      }
      return
    }

    let media = null
    if (descriptor.type === 'image') {
      media = new Image()
      media.decoding = 'async'
      try { media.fetchPriority = 'low' } catch (_) {}
      media.onerror = () => {
        if (directorTpMediaWarmups.get(cacheKey) === media) {
          directorTpMediaWarmups.delete(cacheKey)
        }
      }
      media.src = mediaUrl
    } else {
      media = document.createElement('video')
      media.muted = true
      media.playsInline = true
      const videoPreload =
        options.videoPreload === 'metadata'
          ? 'metadata' : 'auto'
      media.preload = videoPreload
      media.setAttribute('preload', videoPreload)
      media.setAttribute('playsinline', '')
      media.setAttribute('webkit-playsinline', '')
      media.setAttribute('fetchpriority', 'low')
      media.setAttribute('aria-hidden', 'true')
      media.dataset.directorTpPreloaded = '1'
      media.onloadedmetadata = () => {
        const target = Math.max(
          0, Number(descriptor?.mediaOffset) || 0)
        if (target > 0.001) {
          try { media.currentTime = target } catch (_) {}
        }
      }
      media.onerror = () => {
        if (directorTpMediaWarmups.get(cacheKey) === media) {
          directorTpMediaWarmups.delete(cacheKey)
          discardDirectorTelepromptWarmup(media)
        }
      }
      media.setAttribute('src', mediaUrl)
      getDirectorTelepromptPreloadHost().appendChild(media)
      try { media.load() } catch (_) {}
    }
    directorTpMediaWarmups.set(cacheKey, media)

    // Guarda a mídia atual e a próxima de TP1/TP2, com pequena margem para
    // uma troca simultânea. O limite evita acumular vídeos de músicas antigas.
    while (directorTpMediaWarmups.size > 6) {
      const oldestKey = directorTpMediaWarmups.keys().next().value
      const oldest = directorTpMediaWarmups.get(oldestKey)
      directorTpMediaWarmups.delete(oldestKey)
      discardDirectorTelepromptWarmup(oldest)
    }
  }

  function warmDirectorTelepromptMedia(
    slot, data = state.snapshot) {
    const tp = getDirectorTelepromptState(slot, data)
    const selectedSlot =
      Number(state.telepromptSlot) === Number(tp.slot)
    const slotVisible =
      state.showTelepromptScreen &&
      selectedSlot
    // Se o TP não está visível, até a mídia atual pode ficar carregada para a
    // abertura/troca de TP ser imediata. Com o player visível, não cria um
    // segundo download concorrente para a mídia que já está tocando.
    warmDirectorTelepromptDescriptor(tp, {
      allowVideo: !slotVisible,
      videoPreload: selectedSlot ? 'auto' : 'metadata',
    })
    // Só a próxima mídia do TP selecionado recebe pré-carga. Pré-carregar
    // também a próxima do TP oculto competia com o vídeo que estava no ar.
    if (selectedSlot && tp.nextMedia?.itemFound) {
      warmDirectorTelepromptDescriptor(
        tp.nextMedia, {
          allowVideo: true,
          videoPreload: state.showTelepromptScreen
            ? 'auto' : 'metadata',
        })
    }
  }

  function reconcileDirectorTelepromptMediaWarmups(
    data = state.snapshot) {
    warmDirectorTelepromptMedia(1, data)
    warmDirectorTelepromptMedia(2, data)

    const wantedVideoKeys = new Set()
    for (const slot of [1, 2]) {
      const tp = getDirectorTelepromptState(slot, data)
      const selectedSlot =
        Number(state.telepromptSlot) === Number(tp.slot)
      const slotVisible =
        state.showTelepromptScreen && selectedSlot
      if (!slotVisible && tp.type === 'video') {
        const url = getDirectorTelepromptMediaUrl(tp)
        if (url) wantedVideoKeys.add(`video|${url}`)
      }
      if (selectedSlot && tp.nextMedia?.itemFound &&
          tp.nextMedia.type === 'video') {
        const url =
          getDirectorTelepromptMediaUrl(tp.nextMedia)
        if (url) wantedVideoKeys.add(`video|${url}`)
      }
    }

    for (const [key, media] of directorTpMediaWarmups) {
      if (!key.startsWith('video|') ||
          wantedVideoKeys.has(key)) continue
      directorTpMediaWarmups.delete(key)
      discardDirectorTelepromptWarmup(media)
    }
  }

  function takeDirectorTelepromptVideoWarmup(mediaUrl) {
    const cacheKey = `video|${String(mediaUrl || '')}`
    const media = directorTpMediaWarmups.get(cacheKey)
    if (!(typeof HTMLVideoElement !== 'undefined' &&
          media instanceof HTMLVideoElement)) return null
    directorTpMediaWarmups.delete(cacheKey)
    media.onloadedmetadata = null
    media.onerror = null
    media.removeAttribute('aria-hidden')
    media.removeAttribute('fetchpriority')
    media.style.cssText = ''
    return media
  }

  function setDirectorTelepromptSlot(slot, shouldRender = true) {
    const normalizedSlot = Number(slot) === 2 ? 2 : 1
    state.telepromptSlot = normalizedSlot
    writeLocal('vshook_director_teleprompt_slot', normalizedSlot)
    reconcileDirectorTelepromptMediaWarmups()
    if (shouldRender) {
      syncDirectorTelepromptDom()
      scheduleRender(false)
    }
  }

  function openDirectorTelepromptScreen(slot = null) {
    state.showMenu = false
    state.showMarkersOverlay = false
    state.showTunerScreen = false
    if (state.activeTab === 'mixer') setTab(state.tabletMixerReturnTab || 'playlist')
    state.showTelepromptScreen = true
    if (Number(slot) === 1 || Number(slot) === 2) {
      setDirectorTelepromptSlot(slot, false)
    } else {
      setDirectorTelepromptSlot(state.telepromptSlot, false)
    }
    scheduleRender(true)
  }

  function closeDirectorTelepromptScreen() {
    if (!state.showTelepromptScreen) return
    state.showTelepromptScreen = false
    // TP volta para a pagina que estava por baixo dele. No celular, sair do TP
    // pela aba Musicas nao deve mais redirecionar para Repertorio.
    scheduleRender(true)
  }

  function renderDirectorTelepromptScreen(data = state.snapshot || {}) {
    if (!state.showTelepromptScreen) return ''
    const slot = Number(state.telepromptSlot) === 2 ? 2 : 1
    const tp1Class = slot === 1 ? 'directorTpTab directorTpTabActive' : 'directorTpTab'
    const tp2Class = slot === 2 ? 'directorTpTab directorTpTabActive' : 'directorTpTab'
    return `
      <div class="directorTpOverlay" data-teleprompt-slot="${slot}">
        <div class="directorTpPanel">
          <div class="directorTpContent">
            ${renderPlaybackQueueHeader(data, !IS_MUSICIAN_MONITOR)}
            <div class="directorTpControls">
              <button class="${tp1Class}" data-action="teleprompt-slot-1">TP/1</button>
              <button class="${tp2Class}" data-action="teleprompt-slot-2">TP/2</button>
              <button class="directorTpTab directorTpBack" data-action="teleprompt-back">VOLTAR</button>
            </div>
            <div class="directorTpViewport" data-director-tp-viewport>
              <img class="directorTpImage directorTpHidden" alt="Conteúdo do Teleprompt" />
              <video class="directorTpVideo directorTpHidden" muted playsinline preload="auto"></video>
              <div class="directorTpText directorTpHidden" aria-live="polite"></div>
              <div class="directorTpEmpty">SEM CONTEÚDO NO TP/${slot}</div>
              ${renderDirectorTechnicalNotice(data)}
            </div>
          </div>
        </div>
      </div>
    `
  }

  function updateDirectorTpMediaAspect(element, width, height) {
    if (!element) return
    const w = Number(width) || 0
    const h = Number(height) || 0
    const ratio = h > 0 ? w / h : 0
    // Só mídias realmente próximas de 16:9 preenchem. Verticais e demais
    // proporções permanecem inteiras, com bordas quando necessário.
    element.classList.toggle('directorTpMediaWide169', ratio >= 1.72 && ratio <= 1.84)
  }

  function syncDirectorTelepromptDom() {
    if (!state.showTelepromptScreen) return
    const slot = Number(state.telepromptSlot) === 2 ? 2 : 1
    const overlay = root.querySelector('.directorTpOverlay')
    if (overlay) overlay.setAttribute('data-teleprompt-slot', String(slot))
    root.querySelectorAll('[data-action="teleprompt-slot-1"],[data-action="teleprompt-slot-2"]').forEach((button) => {
      const active = button.getAttribute('data-action') === `teleprompt-slot-${slot}`
      button.classList.toggle('directorTpTabActive', active)
    })
    const viewport = root.querySelector('[data-director-tp-viewport]')
    if (!viewport) return
    const image = viewport.querySelector('.directorTpImage')
    let video = viewport.querySelector('.directorTpVideo')
    const text = viewport.querySelector('.directorTpText')
    const empty = viewport.querySelector('.directorTpEmpty')
    const tp = getDirectorTelepromptState(state.telepromptSlot, state.snapshot)
    const mediaUrl = getDirectorTelepromptMediaUrl(tp)
    const hasText = !!String(tp.text || '').trim()
    const hasMedia = (tp.type === 'image' || tp.type === 'video') && !!mediaUrl
    reconcileDirectorTelepromptMediaWarmups(
      state.snapshot)

    viewport.setAttribute('data-content-type', hasMedia ? tp.type : (hasText ? 'text' : 'empty'))
    viewport.setAttribute('data-playing', tp.playing ? '1' : '0')

    const showText = hasText
    if (text) {
      if (text.textContent !== tp.text) text.textContent = tp.text
      text.classList.toggle('directorTpHidden', !showText)
      text.classList.toggle('directorTpTextOverlay', hasMedia)
      text.classList.toggle('directorTpTextOnly', !hasMedia && showText)
    }
    if (empty) {
      empty.textContent = `SEM CONTEÚDO NO TP/${slot}`
      empty.classList.toggle('directorTpHidden', hasMedia || showText)
    }

    if (tp.type === 'image' && mediaUrl) {
      if (video) {
        try { video.pause() } catch (_) {}
        if (video.getAttribute('src')) {
          video.removeAttribute('src')
          try { video.load() } catch (_) {}
        }
        video.classList.add('directorTpHidden')
      }
      if (image) {
        const sourceChanged = image.getAttribute('src') !== mediaUrl
        if (sourceChanged) image.classList.add('directorTpHidden')
        image.onload = () => {
          if (image.getAttribute('src') !== mediaUrl) return
          updateDirectorTpMediaAspect(image, image.naturalWidth, image.naturalHeight)
          image.classList.remove('directorTpHidden')
        }
        image.onerror = () => {
          if (image.getAttribute('src') === mediaUrl) image.classList.add('directorTpHidden')
        }
        try { image.fetchPriority = 'high' } catch (_) {}
        image.decoding = 'async'
        if (sourceChanged) image.setAttribute('src', mediaUrl)
        if (image.complete && image.naturalWidth > 0) {
          updateDirectorTpMediaAspect(image, image.naturalWidth, image.naturalHeight)
          image.classList.remove('directorTpHidden')
        }
      }
      return
    }

    if (image) image.classList.add('directorTpHidden')
    if (tp.type !== 'video' || !mediaUrl || !video) {
      if (video) {
        try { video.pause() } catch (_) {}
        if (video.getAttribute('src')) {
          video.removeAttribute('src')
          try { video.load() } catch (_) {}
        }
        video.classList.add('directorTpHidden')
      }
      return
    }

    if (video.getAttribute('src') !== mediaUrl) {
      const preloadedVideo =
        takeDirectorTelepromptVideoWarmup(mediaUrl)
      if (preloadedVideo) {
        try { video.pause() } catch (_) {}
        if (video.getAttribute('src')) {
          video.removeAttribute('src')
          try { video.load() } catch (_) {}
        }
        preloadedVideo.className =
          'directorTpVideo directorTpHidden'
        video.replaceWith(preloadedVideo)
        video = preloadedVideo
      }
    }

    if (video.readyState >= 1) updateDirectorTpMediaAspect(video, video.videoWidth, video.videoHeight)
    video.muted = true
    video.playsInline = true
    video.loop = false
    video.preload = 'auto'
    try { video.playbackRate = tp.playrate } catch (_) {}

    const sourceChanged = video.getAttribute('src') !== mediaUrl
    if (sourceChanged) video.classList.add('directorTpHidden')
    const targetTime = Math.max(0, Number(tp.currentTime) || 0)
    let videoSyncState = directorTpVideoSyncStates.get(video)
    if (!videoSyncState) {
      videoSyncState = {
        mediaUrl: '',
        targetTime: 0,
        targetAt: 0,
        playing: false,
        playrate: 1,
        lastCorrectionAt: 0,
      }
      directorTpVideoSyncStates.set(video, videoSyncState)
    }
    const syncNow = typeof performance !== 'undefined'
      ? performance.now() : Date.now()
    const syncSourceChanged =
      sourceChanged || videoSyncState.mediaUrl !== mediaUrl
    const hadPreviousTarget =
      videoSyncState.targetAt > 0 && !syncSourceChanged
    const elapsedSinceTarget = hadPreviousTarget
      ? Math.max(0,
          (syncNow - videoSyncState.targetAt) / 1000)
      : 0
    const targetDelta = hadPreviousTarget
      ? targetTime - videoSyncState.targetTime : 0
    const expectedTargetDelta =
      hadPreviousTarget && videoSyncState.playing
        ? elapsedSinceTarget *
          Math.max(0.1, Number(videoSyncState.playrate) || 1)
        : 0
    const targetJump = hadPreviousTarget && (
      targetDelta < -0.35 ||
      targetDelta - expectedTargetDelta > 1.1
    )
    const playingTransition = hadPreviousTarget &&
      videoSyncState.playing !== tp.playing
    const targetAdvancing = !hadPreviousTarget ||
      targetDelta > 0.02 || targetJump
    const applyVideoPosition = (force = false) => {
      if (!Number.isFinite(video.duration) || video.readyState < 1) return
      const currentTime =
        Math.max(0, Number(video.currentTime) || 0)
      const drift = Math.abs(currentTime - targetTime)
      const correctionNow = typeof performance !== 'undefined'
        ? performance.now() : Date.now()
      let shouldSeek = false
      if (force || syncSourceChanged ||
          playingTransition || targetJump) {
        shouldSeek = drift > 0.035
      } else if (!tp.playing) {
        shouldSeek = drift > 0.08
      } else {
        // Durante a reprodução, o vídeo corre localmente. Snapshot atrasado
        // nunca pode puxá-lo para trás. Só corrige se o player realmente ficou
        // para trás, com margem e intervalo suficientes para não engasgar.
        const videoBehindBy = targetTime - currentTime
        shouldSeek = targetAdvancing &&
          videoBehindBy > 1.15 &&
          correctionNow -
            Number(videoSyncState.lastCorrectionAt || 0) >= 1800
      }
      if (shouldSeek) {
        try { video.currentTime = Math.min(targetTime, Math.max(0, Number(video.duration) || targetTime)) } catch (_) {}
        videoSyncState.lastCorrectionAt = correctionNow
      }
    }
    videoSyncState.mediaUrl = mediaUrl
    videoSyncState.targetTime = targetTime
    videoSyncState.targetAt = syncNow
    videoSyncState.playing = tp.playing
    videoSyncState.playrate = tp.playrate

    video.onloadedmetadata = () => {
      updateDirectorTpMediaAspect(video, video.videoWidth, video.videoHeight)
      applyVideoPosition(true)
      if (tp.playing) {
        const promise = video.play()
        if (promise && typeof promise.catch === 'function') promise.catch(() => {})
      }
    }
    video.oncanplay = () => {
      if (video.getAttribute('src') !== mediaUrl) return
      video.classList.remove('directorTpHidden')
      applyVideoPosition(sourceChanged)
      if (tp.playing && video.paused) {
        const promise = video.play()
        if (promise && typeof promise.catch === 'function') promise.catch(() => {})
      }
    }
    video.onloadeddata = () => {
      if (video.getAttribute('src') !== mediaUrl) return
      video.classList.remove('directorTpHidden')
      applyVideoPosition(sourceChanged)
    }
    video.onerror = () => {
      if (video.getAttribute('src') !== mediaUrl) return
      video.classList.add('directorTpHidden')
    }

    if (sourceChanged) {
      video.setAttribute('src', mediaUrl)
      try { video.load() } catch (_) {}
    } else {
      if (video.readyState >= 2) video.classList.remove('directorTpHidden')
      applyVideoPosition(false)
    }

    if (tp.playing) {
      if (video.paused || video.ended) {
        const promise = video.play()
        if (promise && typeof promise.catch === 'function') promise.catch(() => {})
      }
    } else {
      try { video.pause() } catch (_) {}
      applyVideoPosition(false)
    }
  }

  function renderDirectorRecadosScreen(data = state.snapshot || {}) {
    if (!state.showRecadosScreen) return ''
    return `
      <div class="directorRecadosRoot">
        <iframe
          class="directorRecadosFrame"
          src="./recados.html?embedded=director&amp;v=1-0-0-recados-shared-v63"
          title="Recados"
          allow="clipboard-read; clipboard-write"></iframe>
      </div>
    `
  }

  function handleDirectorRecadosMessage(event) {
    if (event.origin !== window.location.origin) return
    if (event.data?.type !== 'vshook-recados-close') return
    closeDirectorRecadosScreen()
  }


  function renderMarkersOverlay(data = state.snapshot || {}) {
    if (!state.showMarkersOverlay) return ''
    const parentInstruction = partsTargetIsParent(data)
    return `
      <div class="partsOverlay">
        <div class="partsPanel">
          <div class="partsPanelTop">
            <div class="partsPanelTitle">PARTS</div>
            <button class="partsPanelClose" data-action="close-markers-overlay" aria-label="Fechar Parts">×</button>
          </div>
          <div class="contentPanel partsOverlayContent">
            ${parentInstruction ? renderPartsParentInstruction() : `${renderMarkersControls()}${renderPlaybackQueueHeader(data, true)}${renderPartsSongSwitch(data)}<div class="listBox markerListBox">${renderRows(getPartsMarkers(data), 'marker')}</div>`}
          </div>
        </div>
      </div>
    `
  }


  function renderTransportSeekModal(data = state.snapshot || {}) {
    if (!state.showTransportSeekModal) return ''
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet' && !IS_MUSICIAN_MONITOR
    const tabletOpeningClass = tabletMode && state.tabletTransportOpening ? ' tabletTransportPanelOpening' : ''
    if (tabletMode && state.tabletTransportOpening) state.tabletTransportOpening = false
    const target = getTransportSeekTarget(data)
    if (!target) {
      if (!tabletMode) return ''
      const emptyBars = [34,52,41,68,47,59,38,63,45,55,36,66,43,58,39,62,46,54,35,64,42,57,40,60]
        .map((height) => `<span class="transportSeekWaveBar" style="height:${height}%"></span>`)
        .join('')
      return `
        <section class="tabletTransportPanel tabletTransportPanelEmpty${tabletOpeningClass}" aria-label="Representação gráfica sem música selecionada">
          <div class="transportSeekRegionCard">
            <div class="transportSeekRegionTitle">SEM MÚSICA SELECIONADA</div>
            <div class="transportSeekWaveButton tabletTransportWaveDisabled" aria-disabled="true">
              <div class="transportSeekWaveGrid" aria-hidden="true"></div>
              <div class="transportSeekWaveBars">${emptyBars}</div>
              <span class="transportSeekCursorLine" style="left:0%"></span>
              <span class="transportSeekCursorHead" style="left:0%"></span>
            </div>
          </div>
          <div class="transportSeekMeta tabletTransportMeta">
            <span class="transportSeekMetaText">CURSOR 00:00</span>
            <span class="transportSeekMetaText">TOTAL 00:00</span>
          </div>
        </section>
      `
    }
    const duration = Math.max(0, Number(target.displayDuration) || ((Number(target.end) || 0) - (Number(target.start) || 0)))
    const cursorPos = getTransportSeekCursorPos(target, data)
    const cursorOffset = Math.max(0, cursorPos - (Number(target.start) || 0))
    const cursorPercent = getTransportSeekCursorPercent(target, data)
    const bars = renderTransportSeekWaveBarsHtml(target)
    const waveSignature = getTransportSeekWaveSignature(target)
    const markerLines = renderTransportSeekMarkerLinesHtml(target, data)
    const markerSignature = getTransportSeekMarkerSignature(target, data)
    if (tabletMode) {
      return `
        <section class="tabletTransportPanel${tabletOpeningClass}" aria-label="Representação gráfica da música">
          <div class="transportSeekRegionCard">
            <div class="transportSeekRegionTitle" data-transport-seek-title>${escapeHtml(upperText(target.name || 'MÚSICA'))}</div>
            <button class="transportSeekWaveButton" data-action="transport-seek-set-position" aria-label="Mover cursor dentro da música">
              <div class="transportSeekWaveGrid" aria-hidden="true"></div>
              <div class="transportSeekWaveBars" data-transport-seek-wave-signature="${waveSignature}">${bars}</div>
              <div class="transportSeekMarkers" data-transport-seek-marker-signature="${markerSignature}" aria-hidden="true">${markerLines}</div>
              <span class="transportSeekCursorLine" data-transport-seek-cursor-line style="left:${cursorPercent}%"></span>
              <span class="transportSeekCursorHead" data-transport-seek-cursor-head style="left:${cursorPercent}%"></span>
            </button>
          </div>
          <div class="transportSeekMeta tabletTransportMeta">
            <span class="transportSeekMetaText" data-transport-seek-cursor-text>CURSOR ${escapeHtml(formatTime(cursorOffset))}</span>
            <span class="transportSeekMetaText" data-transport-seek-total-text>TOTAL ${escapeHtml(formatTime(duration))}</span>
          </div>
        </section>
      `
    }
    const playLabel = getTransportSeekPlaying(data) ? 'PAUSE' : 'PLAY'
    const playClass = getTransportSeekPlaying(data) ? 'btn btnStopActive' : 'btn btnPlayActive'
    return `
      <div class="transportSeekOverlay">
        <div class="transportSeekModal">
          <div class="transportSeekRegionCard">
            <div class="transportSeekRegionTitle" data-transport-seek-title>${escapeHtml(upperText(target.name || 'MÚSICA'))}</div>
            <button class="transportSeekWaveButton" data-action="transport-seek-set-position" aria-label="Mover cursor dentro da música">
              <div class="transportSeekWaveGrid" aria-hidden="true"></div>
              <div class="transportSeekWaveBars" data-transport-seek-wave-signature="${waveSignature}">${bars}</div>
              <div class="transportSeekMarkers" data-transport-seek-marker-signature="${markerSignature}" aria-hidden="true">${markerLines}</div>
              <span class="transportSeekCursorLine" data-transport-seek-cursor-line style="left:${cursorPercent}%"></span>
              <span class="transportSeekCursorHead" data-transport-seek-cursor-head style="left:${cursorPercent}%"></span>
            </button>
          </div>
          <div class="transportSeekMeta">
            <span class="transportSeekMetaText" data-transport-seek-cursor-text>CURSOR ${escapeHtml(formatTime(cursorOffset))}</span>
            <span class="transportSeekMetaText" data-transport-seek-total-text>TOTAL ${escapeHtml(formatTime(duration))}</span>
          </div>
          <div class="transportSeekButtons">
            <button class="${playClass}" data-action="transport-seek-play" data-transport-seek-play-button>${playLabel}</button>
            <button class="btn" data-action="close-transport-seek-modal">FECHAR</button>
          </div>
        </div>
      </div>
    `
  }

  function renderMusicianMonitorContent(data = state.snapshot || {}) {
    const activePlaylist = getActivePlaylist(data)
    const regionsPage = state.activeTab === 'regions'
    const title = regionsPage
      ? 'ABA MÚSICAS'
      : upperText(activePlaylist?.name || data.currentPlaylistName || 'REPERTÓRIO')
    const rows = regionsPage
      ? getRegionsWithOpenDrawers(data)
      : getPlaylistItems(data)
    const rowType = regionsPage ? 'region' : 'playlist'
    // A tela principal do Músico usa a mesma lista ativa da extensão/Diretor.
    // A única diferença é o controle TP, sem comandos de transporte ou seleção.
    return `<div class="contentPanel"><div class="sectionLabel sectionLabelSticky">${escapeHtml(title)}</div><div class="controlsRowPlaylist controlsRowMusicianTp"><button class="btn musicianTpOnlyButton" data-action="open-teleprompt">TP</button></div>${renderPlaybackQueueHeader(data, false)}<div class="listBox">${renderRows(rows, rowType)}</div></div>`
  }

  function normalizeTabletSearchText(value) {
    const text = String(value || '').toLowerCase()
    try {
      return text.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    } catch (_) {
      return text
    }
  }

  function getHashChildParentId(item) {
    return String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
  }

  function getTabletSearchEntries(data = state.snapshot || {}) {
    const entries = []
    const seen = new Set()
    const regions = getRegions(data)
    const regionById = new Map()
    const childrenByParent = new Map()

    for (const item of regions) {
      const id = String(getId(item) || '')
      if (id) regionById.set(id, item)
      if (!isHashChild(item)) continue
      const parentId = getHashChildParentId(item)
      if (!parentId) continue
      if (!childrenByParent.has(parentId)) childrenByParent.set(parentId, [])
      childrenByParent.get(parentId).push(item)
    }

    const addEntry = (item, parentId = '', parentName = '') => {
      if (!item || isBlock(item)) return
      const id = String(getId(item) || '')
      if (!id || seen.has(id)) return
      const name = upperText(getName(item) || 'MÚSICA')
      const child = isHashChild(item) || !!parentId
      const ownerId = String(parentId || getHashChildParentId(item) || '')
      const owner = ownerId ? regionById.get(ownerId) : null
      const ownerName = upperText(parentName || getName(owner) || '')
      seen.add(id)
      entries.push({
        id,
        name,
        parentId: ownerId,
        parentName: ownerName,
        isChild: child,
        durationSec: getDurationSec(item),
        searchText: normalizeTabletSearchText(`${name} ${ownerName}`),
      })
    }

    for (const item of regions) {
      if (isBlock(item) || isHashChild(item)) continue
      const parentId = String(getId(item) || '')
      const parentName = upperText(getName(item) || '')
      addEntry(item)
      let children = childrenByParent.get(parentId) || []
      if (!children.length && (isHashParent(item) || itemHasChildSongMarkers(item, data))) {
        children = buildHashDrawerChildren(parentId, 'region', data)
      }
      for (const child of children) addEntry(child, parentId, parentName)
    }

    // Mantém pesquisáveis filhos recebidos antes do pai ou vindos de snapshots
    // antigos, sem duplicar os que já foram colocados sob a região correta.
    for (const item of regions) {
      if (isHashChild(item)) addEntry(item, getHashChildParentId(item))
    }

    const playlists = Array.isArray(data?.playlists) ? data.playlists : []
    for (const playlist of playlists) {
      for (const item of getPlaylistSongs(playlist)) {
        addEntry(item, isHashChild(item) ? getHashChildParentId(item) : '')
      }
    }
    return entries
  }

  function getFilteredTabletSearchEntries(data = state.snapshot || {}) {
    const query = normalizeTabletSearchText(state.tabletSearchQuery).trim()
    const entries = getTabletSearchEntries(data)
    if (!query) return entries
    const terms = query.split(/\s+/).filter(Boolean)
    return entries.filter((entry) => terms.every((term) => entry.searchText.indexOf(term) >= 0))
  }

  function tabletSearchEntryIsInActivePlaylist(entry, data = state.snapshot || {}) {
    if (!entry) return false
    const ids = new Set(getPlaylistItems(data).map((item) => String(getId(item) || '')).filter(Boolean))
    return ids.has(String(entry.id || '')) || (!!entry.parentId && ids.has(String(entry.parentId)))
  }

  function renderTabletSearchResults(data = state.snapshot || {}) {
    const entries = getFilteredTabletSearchEntries(data)
    if (!entries.length) return '<div class="tabletSearchEmpty">NENHUMA MÚSICA ENCONTRADA</div>'
    return entries.map((entry) => {
      const destination = tabletSearchEntryIsInActivePlaylist(entry, data) ? 'REPERTÓRIO' : 'MÚSICAS'
      const childLabel = entry.isChild ? `<span class="tabletSearchResultParent">FILHO DE ${escapeHtml(entry.parentName || 'REGIÃO')}</span>` : ''
      const duration = entry.durationSec > 0 ? formatTime(entry.durationSec) : ''
      return `<button type="button" class="tabletSearchResult" data-action="tablet-search-result" data-search-id="${escapeHtml(entry.id)}"><span class="tabletSearchResultMain"><span class="tabletSearchResultName">${escapeHtml(entry.name)}</span>${childLabel}</span><span class="tabletSearchResultSide"><span class="tabletSearchResultDestination">${destination}</span>${duration ? `<span class="tabletSearchResultTime">${escapeHtml(duration)}</span>` : ''}</span></button>`
    }).join('')
  }

  function renderTabletSearchScreen(data = state.snapshot || {}) {
    if (!state.showTabletSearch || IS_MUSICIAN_MONITOR) return ''
    const count = getFilteredTabletSearchEntries(data).length
    return `
      <section class="tabletSearchScreen" aria-label="Pesquisar músicas">
        <div class="tabletSearchPanel">
          <div class="tabletSearchHeader">
            <div class="tabletSearchTitle">LUPA</div>
            <button type="button" class="btn tabletSearchClose" data-action="tablet-search-close">FECHAR</button>
          </div>
          <div class="tabletSearchInputRow">
            <input id="tabletSearchInput" class="tabletSearchInput" type="search" inputmode="search" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="PESQUISAR MÚSICA" value="${escapeHtml(state.tabletSearchQuery)}">
            <span class="tabletSearchCount" data-tablet-search-count>${count}</span>
          </div>
          <div class="tabletSearchResults" data-tablet-search-results>${renderTabletSearchResults(data)}</div>
        </div>
      </section>
    `
  }

  function syncTabletSearchResultsDom() {
    if (!state.showTabletSearch) return
    const results = root.querySelector('[data-tablet-search-results]')
    const count = root.querySelector('[data-tablet-search-count]')
    if (results) results.innerHTML = renderTabletSearchResults(state.snapshot || {})
    if (count) count.textContent = String(getFilteredTabletSearchEntries(state.snapshot || {}).length)
  }

  function focusTabletSearchInput() {
    const input = document.getElementById('tabletSearchInput')
    if (!input) return
    try { input.focus({ preventScroll: true }) } catch (_) { input.focus() }
    try {
      const end = String(input.value || '').length
      input.setSelectionRange(end, end)
    } catch (_) {}
  }

  function renderTabletSidebar() {
    if (IS_MUSICIAN_MONITOR ||
        document.documentElement.dataset.directorDevice !== 'tablet' ||
        state.showTelepromptScreen) return ''
    const previewMode = getPreviewMode()
    const previewPage = state.tabletPreviewPage === 2 || (state.tabletPreviewPage === 0 && previewMode >= 4) ? 2 : 1
    const previewFirstSlot = previewPage === 2 ? 4 : 1
    const multiLoopBypassActive = getMultiLoopBypassActive(state.snapshot || {})
    return `
      <aside class="tabletDirectorSidebar tabletDirectorSidebarLeft tabletDirectorSidebarSingle" aria-label="Navegação do Diretor Tablet">
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarVerticalMedium${state.showTabletSearch ? ' tabletSidebarButtonActive' : ''}" data-action="tablet-search" aria-label="Lupa"><span class="tabletSidebarVerticalLabel">LUPA</span></button>
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarVerticalMedium${state.showProjectModal ? ' tabletSidebarButtonActive' : ''}" data-action="project-selector" aria-label="Sessão"><span class="tabletSidebarVerticalLabel">SESSÃO</span></button>
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarVerticalMedium${state.showTelepromptScreen ? ' tabletSidebarButtonActive' : ''}" data-action="tablet-teleprompt" aria-label="Teleprompt"><span class="tabletSidebarVerticalLabel">TP</span></button>
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarVerticalLong${state.showRecadosScreen ? ' tabletSidebarButtonActive' : ''}" data-action="tablet-recados" aria-label="Recados"><span class="tabletSidebarVerticalLabel">RECADOS</span></button>
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarVerticalMedium${state.showSettingsModal ? ' tabletSidebarButtonActive' : ''}" data-action="settings" aria-label="Configurações"><span class="tabletSidebarVerticalLabel">CONFIG</span></button>
      </aside>
      <aside class="tabletDirectorSidebar tabletDirectorSidebarRight tabletDirectorSidebarSingle" aria-label="Ferramentas do Diretor Tablet">
        <button class="tabletSidebarButton tabletSidebarVerticalButton tabletSidebarListButton${state.showPlaylistModal ? ' tabletSidebarButtonActive' : ''}" data-action="tablet-playlists" aria-label="Lista de repertórios"><span class="tabletSidebarVerticalLabel">RPTS</span></button>
        <button class="tabletSidebarButton tabletSidebarByButton ${multiLoopBypassActive ? 'tabletSidebarByButtonOn' : 'tabletSidebarByButtonOff'}" data-action="multiloop-bypass" aria-label="Bypass dos multiloops" aria-pressed="${multiLoopBypassActive ? 'true' : 'false'}">BY</button>
        <div class="tabletPreviewButtonGroup" aria-label="Previews ${previewFirstSlot} a ${previewFirstSlot + 2}">
          ${[previewFirstSlot, previewFirstSlot + 1, previewFirstSlot + 2].map((slot) => `<button class="tabletPreviewButton${previewMode === slot ? ' tabletPreviewButtonActive' : ''}" data-action="tablet-preview" data-preview-slot="${slot}" aria-label="Preview ${slot}; mantenha pressionado para alternar a página">P${slot}</button>`).join('')}
        </div>
        <button class="tabletSidebarButton${state.showTransportSeekModal ? ' tabletSidebarButtonActive' : ''}" data-action="tablet-transport-panel" aria-label="Representação gráfica">
          <svg class="tabletGridIconRight" viewBox="0 0 32 32" aria-hidden="true"><path d="M10 6.5v19l15-9.5z"></path></svg>
        </button>
        <div class="tabletSidebarSpacer"></div>
      </aside>
    `
  }

  function renderTabletTopBar() {
    if (IS_MUSICIAN_MONITOR ||
        document.documentElement.dataset.directorDevice !== 'tablet' ||
        state.showTelepromptScreen) return ''
    return `
      <nav class="tabletDirectorTopBar" aria-label="Navegação principal do Diretor Tablet">
        <button class="tabletTopBarButton tabletTopBarRepertorios${state.activeTab === 'playlist' && !state.showTelepromptScreen ? ' tabletTopBarButtonActive' : ''}" data-action="go-playlist">REPERTÓRIO</button>
        <button class="tabletTopBarButton tabletTopBarMusicas${state.activeTab === 'regions' && !state.showTelepromptScreen ? ' tabletTopBarButtonActive' : ''}" data-action="go-regions">MÚSICAS</button>
        <button class="tabletTopBarButton tabletTopBarTuner${state.tabletTunerSplit ? ' tabletTopBarButtonActive' : ''}" data-action="tablet-tuner-split">TUNER</button>
        <button class="tabletTopBarButton tabletTopBarMixer${state.activeTab === 'mixer' && !state.showRecadosScreen && !state.showTelepromptScreen ? ' tabletTopBarButtonActive' : ''}" data-action="tablet-mixer">MIXER</button>
        <button class="tabletTopBarButton tabletTopBarParts${state.tabletPartsSplit ? ' tabletTopBarButtonActive' : ''}" data-action="tablet-parts-split">PARTS</button>
      </nav>
    `
  }

  function renderTabletMainContent(data = state.snapshot || {}) {
    if (IS_MUSICIAN_MONITOR || document.documentElement.dataset.directorDevice !== 'tablet' || (!state.tabletPartsSplit && !state.tabletTunerSplit)) {
      return IS_MUSICIAN_MONITOR ? renderMusicianMonitorContent(data) : renderMainContent()
    }
    if (state.tabletTunerSplit) {
      return renderTabletTunerUnifiedContent(data)
    }
    const parentInstruction = partsTargetIsParent(data)
    return `
      <div class="tabletMainSplit">
        <div class="tabletMainSplitPrimary">${renderMainContent()}</div>
        <div class="tabletMainSplitParts">
          <div class="contentPanel tabletPartsContent">
            <div class="sectionLabel sectionLabelSticky">PARTS</div>
            ${parentInstruction ? `${renderPartsSongSwitch(data)}${renderPartsParentInstruction()}` : `<div class="controlsRowPlaylist tabletPartsControls">
              <button class="${state.partsArmedMarkerId ? 'btn btnStopActive partsCancelArmed' : 'btn'}" data-action="marker-cancel">CANCELAR</button>
              <button class="${getLoopActive(data) ? 'btn btnLoopActive' : 'btn'}" data-action="loop">LOOP</button>
            </div>
            ${renderPartsSongSwitch(data)}
            <div class="tabletPartsListFrame">
              ${renderTabletPartsOwner(data)}
              <div class="listBox markerListBox">${renderRows(getPartsMarkers(data), 'marker')}</div>
            </div>`}
          </div>
        </div>
      </div>
    `
  }

  function renderTabletTunerUnifiedContent(data = state.snapshot || {}) {
    const type = state.activeTab === 'regions' ? 'region' : 'playlist'
    const items = type === 'region' ? getRegionsWithOpenDrawers(data) : getPlaylistWithOpenDrawers(data)
    return `<div class="contentPanel tabletTunerUnifiedContent"><div class="tabletTunerUnifiedTop">${renderControls()}${renderPlaybackQueueHeader(data, true)}</div><div class="listBox tabletTunerUnifiedList">${renderRows(items, type, { tabletTuner: true })}</div></div>`
  }

  function renderTabletTunerPanel(data = state.snapshot || {}) {
    const sourceType = state.tunerSourceTab === 'regions' ? 'region' : 'playlist'
    const sourceItems = getNumberSortedItems(getTunerSourceItems(data), sourceType)
    let currentParentKey = ''
    const items = sourceItems.filter((item, index) => {
      if (sourceType !== 'region') return true
      if (isHashParent(item)) currentParentKey = String(getId(item) || getRegionNumberValue(item) || index)
      if (!isHashChild(item)) return true
      const parentKey = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? currentParentKey)
      return !!state.hashRegionDrawers[parentKey]
    })
    const rows = items.map((item) => {
      const id = escapeHtml(String(getId(item)))
      if (isBlock(item)) return `<div class="tabletTunerRow tabletTunerBlockRow" aria-hidden="true"></div>`
      const value = getTunerValue(item)
      const sourceNumber = getTunerSourceNumber(item)
      const sourceAttr = sourceNumber == null ? '' : ` data-tuner-source-number="${sourceNumber}"`
      return `<div class="tabletTunerRow"><div class="tabletTunerControls"><button class="tunerStepBtn" data-action="tuner-minus" data-tuner-song-id="${id}"${sourceAttr}${value <= -12 ? ' disabled' : ''}>−</button><button class="tabletTunerZero" data-action="tuner-reset" data-tuner-song-id="${id}"${sourceAttr}>${escapeHtml(formatTunerValue(value))}st</button><button class="tunerStepBtn" data-action="tuner-plus" data-tuner-song-id="${id}"${sourceAttr}${value >= 12 ? ' disabled' : ''}>+</button></div></div>`
    }).join('') || '<div class="emptyBox">NENHUMA MÚSICA ENCONTRADA</div>'
    return `<div class="contentPanel tabletTunerContent"><div class="tabletTunerTopSpacer"></div><div class="listBox tabletTunerList" aria-label="Controles do Tuner">${rows}</div></div>`
  }

  function renderTabletPartsOwner(data = state.snapshot || {}) {
    const source = getEffectivePartsSongSource(data)
    const target = getPartsSongTarget(source, data)
    if (!target?.available) return `<div class="tabletPartsOwner tabletPartsOwnerEmpty">SELECIONE UMA MÚSICA</div>`
    const sourceLabel = source === 'queued' ? 'EM ESPERA' : source === 'selected' ? 'SELECIONADA' : 'TOCANDO'
    return `
      <div class="tabletPartsOwner" data-parts-owner-source="${source}">
        <div class="tabletPartsOwnerTitle"><strong>${escapeHtml(upperText(target.name || findSongNameById(target.id, data) || 'MÚSICA'))}</strong><span>${sourceLabel}</span></div>
      </div>
    `
  }

  function renderTabletPlayHoldModal() {
    if (!state.showTabletPlayHoldModal) return ''
    const seconds = Math.max(1, Math.min(5, Number(state.tabletFadeoutSeconds) || 1))
    const playProtection = getPlayProtectionEnabled()
    const autoStop = getAutoStopEnabled()
    if (state.tabletFadeoutTracksOpen) {
      const selected = new Set((state.tabletFadeoutSelectedTrackIds || []).map(String))
      const tracks = getMixerTracks(state.snapshot || {})
      const rows = tracks.map((track, index) => {
        const id = String(track?.guid ?? track?.id ?? '')
        const checked = selected.has(id)
        return `<button class="tabletFadeoutTrackRow${checked ? ' tabletFadeoutTrackSelected' : ''}" data-action="tablet-fadeout-track-toggle" data-fadeout-track-id="${escapeHtml(id)}"><span class="tabletFadeoutTrackCheck">${checked ? '✓' : ''}</span><span class="tabletFadeoutTrackNumber">${Number(track?.index ?? index + 1)}</span><span class="tabletFadeoutTrackName">${escapeHtml(track?.name || track?.label || `Pista ${index + 1}`)}</span></button>`
      }).join('') || '<div class="emptyBox">NENHUMA PISTA ENCONTRADA</div>'
      return `
        <div class="modalOverlay tabletPlayHoldOverlay">
          <div class="modalSpacer"></div>
          <div class="modalBox tabletPlayHoldModal tabletFadeoutTracksModal" data-stop-modal>
            <div class="modalTitle">ESCOLHER PISTAS</div>
            <div class="tabletFadeoutTrackSummary"><span data-fadeout-selected-count>${selected.size}</span> PISTAS MARCADAS</div>
            <div class="tabletFadeoutTracksList">${rows}</div>
            <div class="tabletFadeoutTrackActions"><button class="btn" data-action="tablet-fadeout-tracks-all">TODAS</button><button class="btn" data-action="tablet-fadeout-tracks-clear">LIMPAR</button></div>
            <div class="modalButtons"><button class="modalCancelBtn" data-action="tablet-fadeout-tracks-back">VOLTAR</button><button class="modalCancelBtn" data-action="tablet-play-hold-close">FECHAR</button></div>
          </div>
          <div class="modalBottomSpace"></div>
        </div>
      `
    }
    return `
      <div class="modalOverlay tabletPlayHoldOverlay">
        <div class="modalSpacer"></div>
        <div class="modalBox tabletPlayHoldModal" data-stop-modal>
          <div class="modalTitle">PLAY</div>
          <button class="${state.tabletFadeoutEnabled ? 'btnConfigOnGreen' : 'btnConfigOffRed'} tabletFadeoutToggle" data-action="tablet-fadeout-toggle">FADEROUT</button>
          <div class="tabletFadeoutTimeControl">
            <button class="btn" data-action="tablet-fadeout-minus" ${seconds <= 1 ? 'disabled' : ''}>−</button>
            <strong data-tablet-fadeout-seconds>${seconds}s</strong>
            <button class="btn" data-action="tablet-fadeout-plus" ${seconds >= 5 ? 'disabled' : ''}>+</button>
          </div>
          <div class="tabletPlayModeToggles">
            <button class="${playProtection ? 'btnConfigOnGreen' : 'btnConfigOffRed'}" data-action="play-protection">PLAY PROTECTION</button>
            <button class="${autoStop ? 'btnConfigOnGreen' : 'btnConfigOffRed'}" data-action="auto-stop-toggle">AUTO STOP</button>
          </div>
          <button class="btn tabletChooseTracksButton" data-action="tablet-fadeout-tracks">ESCOLHER PISTAS</button>
          <div class="modalButtons"><button class="modalCancelBtn" data-action="tablet-play-hold-close">FECHAR</button></div>
        </div>
        <div class="modalBottomSpace"></div>
      </div>
    `
  }

  function getTabletMultiLoopsState() {
    const value = state.snapshot?.multiloops
    return value && typeof value === 'object' ? value : {}
  }

  function normalizeTabletMultiLoopTrackColor(value, fallback) {
    const raw = String(value || '').trim()
    if (/^#[0-9a-f]{6}$/i.test(raw)) return raw.toLowerCase()
    const short = raw.match(/^#([0-9a-f])([0-9a-f])([0-9a-f])$/i)
    if (short) return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`.toLowerCase()
    return fallback
  }

  function tabletMultiLoopTrackTint(color, alpha = 0.2) {
    const match = String(color || '').match(/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i)
    if (!match) return `rgba(57,214,104,${alpha})`
    return `rgba(${parseInt(match[1], 16)},${parseInt(match[2], 16)},${parseInt(match[3], 16)},${alpha})`
  }

  function prepareTabletMultiLoopTrackRows(tracks) {
    const snapshot = state.snapshot || {}
    const mixer = snapshot.mixer && typeof snapshot.mixer === 'object' ? snapshot.mixer : {}
    const mixerTracks = Array.isArray(snapshot.mixerTracks)
      ? snapshot.mixerTracks
      : (Array.isArray(mixer.tracks) ? mixer.tracks : [])
    const metadataById = new Map()
    mixerTracks.forEach((track, index) => {
      const id = String(track?.guid ?? track?.id ?? `mixer-track-${index}`)
      if (id) metadataById.set(id, track)
    })

    const openFamilies = []
    return tracks.map((track, index) => {
      const id = String(track?.guid ?? track?.id ?? '')
      const metadata = metadataById.get(id) || {}
      const rawFolderDepth = Number(track?.folderDepth ?? metadata?.folderDepth ?? 0)
      const folderDepth = Number.isFinite(rawFolderDepth) ? Math.trunc(rawFolderDepth) : 0
      const group = track?.group === true || metadata?.group === true || folderDepth > 0
      const fallbackColor = group ? '#39d668' : '#ffe02e'
      const color = normalizeTabletMultiLoopTrackColor(
        track?.displayColor ?? track?.color ?? track?.trackColor ??
        metadata?.displayColor ?? metadata?.color ?? metadata?.trackColor,
        fallbackColor)
      const familyOutlines = openFamilies.map((family) => ({ ...family }))
      const familyId = id || `multiloop-family-${index}`
      if (group) familyOutlines.push({ id: familyId, color })
      const prepared = {
        track,
        id,
        group,
        color,
        tint: tabletMultiLoopTrackTint(color, group ? 0.24 : 0.12),
        familyOutlines,
      }
      if (folderDepth > 0) {
        openFamilies.push({ id: familyId, color })
      } else if (folderDepth < 0) {
        let closeCount = -folderDepth
        while (closeCount-- > 0 && openFamilies.length) openFamilies.pop()
      }
      return prepared
    })
  }

  function renderTabletMultiLoopFamilyOutlines(rows, index) {
    const row = rows[index]
    if (!row?.familyOutlines?.length) return ''
    const previous = index > 0 ? rows[index - 1]?.familyOutlines || [] : []
    const next = index + 1 < rows.length ? rows[index + 1]?.familyOutlines || [] : []
    return row.familyOutlines.map((family, familyIndex) => {
      const continuesBefore = previous.some((candidate) => candidate.id === family.id)
      const continuesAfter = next.some((candidate) => candidate.id === family.id)
      const classes = `tabletMultiLoopFamilyOutline${continuesBefore ? '' : ' tabletMultiLoopFamilyOutlineStart'}${continuesAfter ? '' : ' tabletMultiLoopFamilyOutlineEnd'}`
      return `<span class="${classes}" style="--multiloop-family-color:${family.color};--multiloop-family-inset:${familyIndex * 3}px" aria-hidden="true"></span>`
    }).join('')
  }

  function rememberTabletMultiLoopTracksScroll(list = null) {
    const target = list || root.querySelector('.tabletMultiLoopTracksList')
    if (!target) return
    const slot = Math.max(1, Math.min(2, Number(target.getAttribute('data-multiloop-slot')) || Number(state.tabletMultiLoopTracksSlot) || 1))
    state.tabletMultiLoopTracksScrollBySlot[slot] = Math.max(0, Number(target.scrollTop) || 0)
  }

  function restoreTabletMultiLoopTracksScrollDom() {
    const list = root.querySelector('.tabletMultiLoopTracksList')
    if (!list) return
    const slot = Math.max(1, Math.min(2, Number(list.getAttribute('data-multiloop-slot')) || Number(state.tabletMultiLoopTracksSlot) || 1))
    list.scrollTop = Math.max(0, Number(state.tabletMultiLoopTracksScrollBySlot[slot]) || 0)
  }

  function handleTabletMultiLoopTracksScroll(event) {
    const list = event.target?.closest?.('.tabletMultiLoopTracksList')
    if (list) rememberTabletMultiLoopTracksScroll(list)
  }

  function clampMultiLoopAutoLimitDb(value, ceilingDb = 0) {
    const db = Number(value)
    const ceiling = Math.max(-90, Number.isFinite(Number(ceilingDb)) ? Number(ceilingDb) : 0)
    return Math.max(-90, Math.min(ceiling, Number.isFinite(db) ? db : -90))
  }

  function formatMultiLoopAutoLimitDb(value) {
    const db = Number(value)
    if (!Number.isFinite(db) || db <= -89.999) return '-INF dB'
    const safe = Math.abs(db) < 0.05 ? 0 : db
    return `${safe >= 0 ? '+' : ''}${safe.toFixed(1)} dB`
  }

  function queueMultiLoopAutoLimitCommand(target) {
    if (!target) return
    if (state.tabletMultiLoopAutoLimitTimer) return
    state.tabletMultiLoopAutoLimitTimer = window.setTimeout(() => {
      state.tabletMultiLoopAutoLimitTimer = 0
      postCommand('multiloop_track_limit_set', getTabletSongToolsPayload({
        slot: target.slot,
        trackId: target.id,
        guid: target.id,
        limitDb: target.valueDb,
      }))
    }, 90)
  }

  function flushMultiLoopAutoLimitCommand() {
    const target = state.tabletMultiLoopAutoLimitTarget
    if (!target || !state.tabletMultiLoopAutoLimitTimer) return
    window.clearTimeout(state.tabletMultiLoopAutoLimitTimer)
    state.tabletMultiLoopAutoLimitTimer = 0
    postCommand('multiloop_track_limit_set', getTabletSongToolsPayload({
      slot: target.slot,
      trackId: target.id,
      guid: target.id,
      limitDb: target.valueDb,
    }))
  }

  function renderTabletMultiLoopAutoLimitModal() {
    const target = state.tabletMultiLoopAutoLimitTarget
    if (!target) return ''
    const baseDb = Number.isFinite(Number(target.baseDb)) ? Number(target.baseDb) : 0
    const maxDb = Math.max(-90, baseDb)
    const targetDb = clampMultiLoopAutoLimitDb(target.valueDb, maxDb)
    return `<div class="modalOverlay tabletCenteredModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletMultiLoopAutoLimitModal" data-stop-modal><div class="modalTitle">LIMITE DO AUTO FADER</div><div class="tabletMultiLoopAutoLimitTrack">${escapeHtml(target.name || 'PISTA')}</div><div class="tabletMultiLoopAutoLimitInfo"><span>VOLUME ATUAL: ${escapeHtml(formatMultiLoopAutoLimitDb(baseDb))}</span><strong data-auto-limit-target>DESTINO DO FADE: ${escapeHtml(formatMultiLoopAutoLimitDb(targetDb))}</strong></div><input class="tabletMultiLoopAutoLimitSlider" data-action="tablet-multiloop-auto-limit" type="range" min="-90" max="${maxDb}" step="0.5" value="${targetDb}"><div class="tabletMultiLoopAutoLimitScale"><span>−INF</span><span>ATUAL ${escapeHtml(formatMultiLoopAutoLimitDb(maxDb))}</span></div><div class="modalButtons"><button class="modalCancelBtn" data-action="tablet-multiloop-auto-limit-back">VOLTAR</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function getTabletSongToolsPayload(extra = {}) {
    const target = state.tabletSongToolsTarget || {}
    const syncedSongKey = String(target.songKey || state.snapshot?.multiloops?.songKey || '')
    return {
      songId: String(target.id || ''),
      targetId: String(target.id || ''),
      songKey: syncedSongKey,
      premixKey: syncedSongKey,
      songName: String(target.name || ''),
      startPos: Number(target.start) || 0,
      endPos: Number(target.end) || 0,
      activeTab: String(target.tab || state.activeTab),
      page: String(target.tab || state.activeTab),
      ...extra,
    }
  }

  function renderTabletSongToolsModal() {
    if (!state.showTabletSongToolsModal) return ''
    const target = state.tabletSongToolsTarget || {}
    const choice = state.tabletSongToolsChoice
    const parentOnly = target.isParent === true
    const option = (value, label) => {
      const reset = value === 'reset'
      return `<button class="tabletSongToolOption${reset ? ' tabletSongToolResetOption' : ''}${!reset && choice === value ? ' tabletSongToolOptionActive' : ''}" data-action="${reset ? 'tablet-song-tool-reset' : 'tablet-song-tool-select'}" data-song-tool="${value}">${label}</button>`
    }
    const options = parentOnly
      ? `${option('premix', 'PREMIX')}${option('reset', 'RESET')}`
      : `${option('premix', 'PREMIX')}${option('multiloops', 'MULTILOOPS')}${option('reset', 'RESET')}`
    const actions = '<button class="modalOkBtnWide" data-action="tablet-song-tool-open">ABRIR</button><button class="modalCancelBtn" data-action="tablet-song-tool-close">FECHAR</button>'
    return `<div class="modalOverlay tabletCenteredModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletSongToolsModal${parentOnly ? ' tabletSongToolsParentModal' : ''}" data-stop-modal><div class="modalTitle">${escapeHtml(upperText(target.name || 'MÚSICA'))}</div><div class="tabletSongToolsOptions">${options}</div><div class="modalButtons tabletSongToolsActions">${actions}</div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderTabletLiveResetConfirm() {
    if (!state.showTabletLiveResetConfirm) return ''
    const name = upperText(state.tabletSongToolsTarget?.name || 'MÚSICA')
    return `<div class="modalOverlay tabletCenteredModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletLiveResetItemModal" data-stop-modal><div class="modalTitle">RESET LIVE</div><div class="modalInfoText">REMOVER A MARCAÇÃO DE “${escapeHtml(name)}”?</div><div class="modalButtons"><button class="modalCancelBtn" data-action="tablet-live-reset-cancel">CANCELAR</button><button class="modalOkBtnWide tabletResetConfirmBtn" data-action="tablet-live-reset-confirm">RESET</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function renderTabletMultiLoopsModal() {
    if (!state.showTabletMultiLoopsModal) return ''
    if (state.tabletMultiLoopAutoLimitTarget) return renderTabletMultiLoopAutoLimitModal()
    const data = getTabletMultiLoopsState()
    const slot = Number(state.tabletMultiLoopTracksSlot) || 0
    if (slot === 1 || slot === 2) {
      const tracks = Array.isArray(data.tracks) ? data.tracks : []
      const preparedTracks = prepareTabletMultiLoopTrackRows(tracks)
      const rows = preparedTracks.map((prepared, index) => {
        const track = prepared.track
        const trackName = track?.name || `Pista ${index + 1}`
        const rowStyle = `--multiloop-track-color:${prepared.color};--multiloop-track-tint:${prepared.tint};--multiloop-family-indent:${prepared.familyOutlines.length * 3}px`
        return `<div class="tabletMultiLoopTrackRow${prepared.group ? ' tabletMultiLoopTrackGroup' : ''}" style="${rowStyle}">${renderTabletMultiLoopFamilyOutlines(preparedTracks, index)}<span class="tabletMultiLoopTrackName">${escapeHtml(trackName)}</span><button class="tabletMultiLoopTrackToggle${track?.[`auto${slot}`] ? ' active' : ''}" data-action="tablet-multiloop-track" data-track-id="${escapeHtml(prepared.id)}" data-track-name="${escapeHtml(trackName)}" data-mode="auto" data-slot="${slot}">AUTO FADER</button><button class="tabletMultiLoopTrackToggle${track?.[`mute${slot}`] ? ' active mute' : ''}" data-action="tablet-multiloop-track" data-track-id="${escapeHtml(prepared.id)}" data-mode="mute" data-slot="${slot}">M</button><button class="tabletMultiLoopTrackToggle${track?.[`solo${slot}`] ? ' active solo' : ''}" data-action="tablet-multiloop-track" data-track-id="${escapeHtml(prepared.id)}" data-mode="solo" data-slot="${slot}">S</button></div>`
      }).join('') || '<div class="emptyBox">NENHUMA PISTA ENCONTRADA</div>'
      const seconds = Math.max(1, Math.min(5, Number(data[`fade${slot}Sec`]) || 3))
      return `<div class="modalOverlay tabletCenteredModalOverlay tabletMultiLoopModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletMultiLoopTracksModal" data-stop-modal><div class="modalTitle">M/S ${slot} — PISTAS</div><div class="tabletMultiLoopFadeControl"><button class="btn" data-action="tablet-multiloop-fade" data-slot="${slot}" data-delta="-1" ${seconds <= 1 ? 'disabled' : ''}>−</button><strong>${seconds}s</strong><button class="btn" data-action="tablet-multiloop-fade" data-slot="${slot}" data-delta="1" ${seconds >= 5 ? 'disabled' : ''}>+</button></div><div class="tabletMultiLoopTracksList" data-multiloop-slot="${slot}">${rows}</div><div class="modalButtons"><button class="modalCancelBtn" data-action="tablet-multiloop-tracks-back">VOLTAR</button><button class="modalCancelBtn" data-action="tablet-multiloop-close">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
    }
    const toggle = (label, action, active, available, slotNumber) => {
      return `<button class="tabletMultiLoopToggle${active ? ' tabletMultiLoopToggleActive' : ''}" data-action="${action}" data-slot="${slotNumber}" data-available="${available ? '1' : '0'}">${label}</button>`
    }
    return `<div class="modalOverlay tabletCenteredModalOverlay tabletMultiLoopModalOverlay"><div class="modalSpacer"></div><div class="modalBox tabletMultiLoopsModal" data-stop-modal><div class="modalTitle">MULTILOOPS</div><div class="tabletMultiLoopsSong">${escapeHtml(upperText(data.songName || state.tabletSongToolsTarget?.name || 'MÚSICA'))}</div><div class="tabletMultiLoopsGrid">${toggle('LOOP 1', 'tablet-multiloop-loop', data.loop1Enabled === true, data.loop1Available === true, 1)}${toggle('LOOP 2', 'tablet-multiloop-loop', data.loop2Enabled === true, data.loop2Available === true, 2)}${toggle('M/S 1', 'tablet-multiloop-ms', data.ms1Enabled === true, data.loop1Enabled === true, 1)}${toggle('M/S 2', 'tablet-multiloop-ms', data.ms2Enabled === true, data.loop2Enabled === true, 2)}</div><div class="tabletMultiLoopsHint">TOQUE E SEGURE EM M/S PARA CONFIGURAR AS PISTAS</div><div class="modalButtons tabletMultiLoopsActions"><button class="modalCancelBtn" data-action="tablet-multiloop-back">VOLTAR</button><button class="modalCancelBtn" data-action="tablet-multiloop-close">FECHAR</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function mountTabletPlayHoldModal() {
    state.showTabletPlayHoldModal = true
    state.tabletFadeoutTracksOpen = false
    if (root.querySelector('.tabletPlayHoldOverlay')) return
    const app = root.querySelector('.app')
    if (app) app.insertAdjacentHTML('beforeend', renderTabletPlayHoldModal())
  }

  function closeTabletPlayHoldModalDom() {
    state.showTabletPlayHoldModal = false
    state.tabletFadeoutTracksOpen = false
    root.querySelector('.tabletPlayHoldOverlay')?.remove()
  }

  function rerenderTabletPlayHoldModalDom() {
    const overlay = root.querySelector('.tabletPlayHoldOverlay')
    if (!overlay) return
    overlay.outerHTML = renderTabletPlayHoldModal()
  }

  function clampTabletFadeoutProgress(value) {
    return Math.max(0, Math.min(1, Number(value) || 0))
  }

  function getTabletFadeoutVisualProgress(sampledAt = now()) {
    const bridgeProgress = clampTabletFadeoutProgress(state.tabletFadeoutProgress)
    if (state.tabletFadeoutRuntimeActive !== true) return bridgeProgress
    const anchorAt = Number(state.tabletFadeoutVisualAnchorAt || 0)
    if (!(anchorAt > 0)) return bridgeProgress
    const durationMs = Math.max(100, Number(state.tabletFadeoutSeconds || 1) * 1000)
    const anchorProgress = clampTabletFadeoutProgress(state.tabletFadeoutVisualAnchorProgress)
    const elapsedRatio = Math.max(0, Number(sampledAt || 0) - anchorAt) / durationMs
    return clampTabletFadeoutProgress(Math.max(
      bridgeProgress,
      anchorProgress + elapsedRatio,
    ))
  }

  function anchorTabletFadeoutVisual(progress, sampledAt = now()) {
    state.tabletFadeoutVisualAnchorProgress = clampTabletFadeoutProgress(progress)
    state.tabletFadeoutVisualAnchorAt = Number(sampledAt) || now()
  }

  function resetTabletFadeoutVisual() {
    state.tabletFadeoutVisualAnchorProgress = 0
    state.tabletFadeoutVisualAnchorAt = 0
  }

  function syncTabletFadeoutFromSnapshot(data = state.snapshot || {}) {
    const sampledAt = now()
    const config = data?.manualStopFadeout && typeof data.manualStopFadeout === 'object' ? data.manualStopFadeout : {}
    if (sampledAt >= Number(state.tabletFadeoutPendingUntil || 0)) {
      const enabled = config.enabled ?? data?.manualStopFadeoutEnabled
      const seconds = config.durationSec ?? config.duration ?? data?.manualStopFadeoutDuration
      if (enabled != null) state.tabletFadeoutEnabled = enabled === true || enabled === 1 || String(enabled).toLowerCase() === 'true'
      if (seconds != null) state.tabletFadeoutSeconds = Math.max(1, Math.min(5, Number(seconds) || 1))
    }
    if (sampledAt >= Number(state.tabletFadeoutTrackPendingUntil || 0) && Array.isArray(config.selectedTrackIds)) {
      state.tabletFadeoutSelectedTrackIds = config.selectedTrackIds.map(String)
    }
    const wasActive = state.tabletFadeoutRuntimeActive === true
    const visualBeforeSync = getTabletFadeoutVisualProgress(sampledAt)
    const bridgeFadeoutActive = config.active === true || config.fading === true
    const pendingRuntimeState = state.tabletFadeoutRuntimePendingState
    const pendingRuntimeConfirmed = pendingRuntimeState === true ? bridgeFadeoutActive : pendingRuntimeState === false ? !bridgeFadeoutActive : true
    if (pendingRuntimeConfirmed || sampledAt >= Number(state.tabletFadeoutRuntimePendingUntil || 0)) {
      const active = bridgeFadeoutActive
      state.tabletFadeoutRuntimeActive = active
      state.tabletFadeoutRuntimePendingState = null
      state.tabletFadeoutRuntimePendingUntil = 0
      if (wasActive && !active && data?.playing !== true && !data?.playingId) {
        state.queuedSongId = ''
        state.optimisticQueueClearedUntil = now() + 1800
        state.optimisticPlayingId = ''
        state.optimisticPlayingUntil = 0
        state.optimisticStoppedUntil = 0
        state.selectedMarkerId = ''
        state.partsLocalSelectedMarkerId = ''
        state.partsArmedMarkerId = ''
        state.partsArmedMarkerUntil = 0
      }
    }
    const progress = Number(config.progress)
    state.tabletFadeoutProgress = Number.isFinite(progress)
      ? clampTabletFadeoutProgress(progress)
      : (state.tabletFadeoutRuntimeActive ? state.tabletFadeoutProgress : 0)
    if (state.tabletFadeoutRuntimeActive) {
      anchorTabletFadeoutVisual(
        Math.max(
          wasActive ? visualBeforeSync : 0,
          state.tabletFadeoutProgress,
        ),
        sampledAt,
      )
    } else {
      resetTabletFadeoutVisual()
    }
    syncTabletFadeoutProgressDom(sampledAt)
    syncTabletPlayHoldModalDom()
  }

  function syncTabletFadeoutProgressDom(sampledAt = now()) {
    const remaining = `${Math.max(0, Math.min(100, (1 - getTabletFadeoutVisualProgress(sampledAt)) * 100))}%`
    root.querySelectorAll('.tabletFadeoutRegress').forEach((button) => button.style.setProperty('--fadeout-remaining', remaining))
  }

  function syncMainControlButtonsDom() {
    const playing = isPlaying(state.snapshot)
    const fadeoutRunning = state.tabletFadeoutRuntimeActive === true
    const remaining = `${Math.max(0, Math.min(100, (1 - getTabletFadeoutVisualProgress()) * 100))}%`
    root.querySelectorAll('[data-action="play"]').forEach((button) => {
      button.textContent = playing ? 'STOP' : 'PLAY'
      button.classList.add('btn')
      button.classList.toggle('btnPlayActive', !playing)
      button.classList.toggle('btnStopActive', playing)
      button.classList.toggle('tabletFadeoutStopBlink', playing && fadeoutRunning)
      button.classList.toggle('tabletFadeoutRegress', playing && fadeoutRunning)
      if (fadeoutRunning) button.style.setProperty('--fadeout-remaining', remaining)
      else button.style.removeProperty('--fadeout-remaining')
    })

    root.querySelectorAll('[data-action="stop-break"]').forEach((button) => {
      button.classList.add('btn')
      button.classList.toggle('btnStopActive', playing)
      button.classList.toggle('tabletStopBreakPlaying', playing)
      button.classList.toggle('tabletFadeoutRegress', playing && fadeoutRunning)
      if (fadeoutRunning) button.style.setProperty('--fadeout-remaining', remaining)
      else button.style.removeProperty('--fadeout-remaining')
    })

    const autoAvailable = state.activeTab === 'playlist'
    const autoplay1Enabled = autoAvailable && getAutoplay1Enabled()
    const autoplay2Enabled = autoAvailable && getAutoplay2Enabled()
    root.querySelectorAll('[data-action="autoplay"]').forEach((button) => {
      button.classList.toggle('btnAutoplayActive', autoplay1Enabled)
      button.classList.toggle('btnAutoUnavailable', !autoAvailable)
      button.classList.toggle('btn', !autoplay1Enabled)
      button.setAttribute('aria-pressed', autoplay1Enabled ? 'true' : 'false')
    })
    root.querySelectorAll('[data-action="autoplay2"]').forEach((button) => {
      button.classList.toggle('btnAutoplayActive', autoplay2Enabled)
      button.classList.toggle('btnAutoplay2Active', autoplay2Enabled)
      button.classList.toggle('btnAutoUnavailable', !autoAvailable)
      button.classList.toggle('btn', !autoplay2Enabled)
      button.setAttribute('aria-pressed', autoplay2Enabled ? 'true' : 'false')
    })

    const liveEnabled = getLiveEnabled()
    root.querySelectorAll('[data-action="live"]').forEach((button) => {
      const menuButton = button.classList.contains('topMenuFlyoutBtn')
      button.classList.toggle('topMenuFlyoutBtnLiveOn', menuButton && liveEnabled)
      button.classList.toggle('topMenuFlyoutBtnLiveOff', menuButton && !liveEnabled)
      button.classList.toggle('topMenuFlyoutBtnActive', menuButton && liveEnabled)
      button.classList.toggle('btnConfigOnGreen', !menuButton && liveEnabled)
      button.classList.toggle('btnConfigOffRed', !menuButton && !liveEnabled)
      button.classList.toggle('tabletLiveButtonActive', !menuButton && liveEnabled)
      button.classList.toggle('tabletLiveButton', !menuButton && !liveEnabled)
      button.setAttribute('aria-pressed', liveEnabled ? 'true' : 'false')
    })
  }

  function syncTabletPlayHoldModalDom() {
    const modal = root.querySelector('.tabletPlayHoldModal')
    if (!modal) return
    const seconds = Math.max(1, Math.min(5, Number(state.tabletFadeoutSeconds) || 1))
    const toggle = modal.querySelector('[data-action="tablet-fadeout-toggle"]')
    toggle?.classList.toggle('btnConfigOnGreen', state.tabletFadeoutEnabled)
    toggle?.classList.toggle('btnConfigOffRed', !state.tabletFadeoutEnabled)
    const display = modal.querySelector('[data-tablet-fadeout-seconds]')
    if (display) display.textContent = `${seconds}s`
    const minus = modal.querySelector('[data-action="tablet-fadeout-minus"]')
    const plus = modal.querySelector('[data-action="tablet-fadeout-plus"]')
    if (minus) minus.disabled = seconds <= 1
    if (plus) plus.disabled = seconds >= 5
    const selected = new Set((state.tabletFadeoutSelectedTrackIds || []).map(String))
    modal.querySelectorAll('[data-fadeout-track-id]').forEach((row) => {
      const checked = selected.has(String(row.getAttribute('data-fadeout-track-id') || ''))
      row.classList.toggle('tabletFadeoutTrackSelected', checked)
      const check = row.querySelector('.tabletFadeoutTrackCheck')
      if (check) check.textContent = checked ? '✓' : ''
    })
    const count = modal.querySelector('[data-fadeout-selected-count]')
    if (count) count.textContent = String(selected.size)
  }

  function renderApp() {
    const data = state.snapshot || {}
    if (!IS_MUSICIAN_MONITOR && (authEnabled(data) || state.pcAccessReleased) && !state.authAuthenticated) return renderAuthGate()
    document.documentElement.classList.remove('directorLoginPortraitMode')
    if (!IS_MUSICIAN_MONITOR && state.showRecadosScreen) return renderDirectorRecadosScreen(data)
    const online = state.bridgeOnline || (now() - state.lastGoodAt < 4000)
    const activePlaylist = getActivePlaylist(data)
    const title = state.activeTab === 'playlist' ? upperText(activePlaylist?.name || data.currentPlaylistName || 'REPERTÓRIO') : state.activeTab === 'regions' ? 'MÚSICAS' : state.activeTab === 'markers' ? 'PARTS' : state.activeTab === 'mixer' ? 'MIXER' : 'PREMIX'
    const topPlaylistTitle = state.activeTab === 'regions'
      ? (IS_MUSICIAN_MONITOR ? 'ABA MÚSICAS' : 'LISTA GERAL')
      : upperText(activePlaylist?.name || data.currentPlaylistName || getProjectName(data) || 'REPERTÓRIO')
    const theme = getAppTheme()
    const borderMode = getBorderColorMode()
    const borderColor = getBorderColorValue(borderMode)
    const borderGlow = getBorderColorGlow(borderMode)
    const liveMarkVisual = getLiveMarkVisualStyle(data)
    const telepromptFont = getTelepromptFont()
    const telepromptColor = getTelepromptColor()
    const telepromptColorValue = getTelepromptColorValue(telepromptColor)
    return `
      <div class="app vshookNoTextSelect${IS_MUSICIAN_MONITOR ? ' musicianMonitor' : ''}" data-theme="${theme}" data-active-tab="${state.activeTab}" data-border-mode="${borderMode}" data-teleprompt-font="${telepromptFont}" data-teleprompt-color="${telepromptColor}" style="--app-border-color:${borderColor};--app-border-glow:${borderGlow};--teleprompt-text-color:${telepromptColorValue};--live-mark-background:${liveMarkVisual.background};--live-mark-border:${liveMarkVisual.border};--live-mark-shadow:${liveMarkVisual.shadow};">
        <style>
          .contentPanel{display:flex;flex-direction:column;flex:1;min-height:0}.controlsRowEqual{grid-template-columns:repeat(3,1fr)!important}.controlsRowTwo{grid-template-columns:repeat(2,1fr)!important}.controlsRowDirectorMain{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(70px,.72fr)!important;gap:6px!important}.controlsRowDirectorMain>button{height:42px!important;min-height:42px!important}.container{padding-top:9px!important}.app:not([data-border-mode^="rgb-"]) .container{border-color:var(--app-border-color)!important;box-shadow:0 0 0 1px var(--app-border-glow),0 0 18px var(--app-border-glow)!important;animation:none!important}.app[data-border-mode^="rgb-"] .container{border-color:#ef4444;box-shadow:0 0 0 1px rgba(239,68,68,.28),0 0 18px rgba(239,68,68,.45);animation:directorBorderRgb 6s linear infinite!important}.app[data-border-mode="rgb-mid"] .container{animation-duration:3s!important}.app[data-border-mode="rgb-super"] .container{animation-duration:.85s!important}@keyframes directorBorderRgb{0%{border-color:#ef4444;box-shadow:0 0 0 1px rgba(239,68,68,.28),0 0 18px rgba(239,68,68,.45)}20%{border-color:#facc15;box-shadow:0 0 0 1px rgba(250,204,21,.28),0 0 18px rgba(250,204,21,.45)}40%{border-color:#22c55e;box-shadow:0 0 0 1px rgba(34,197,94,.28),0 0 18px rgba(34,197,94,.45)}60%{border-color:#06b6d4;box-shadow:0 0 0 1px rgba(6,182,212,.28),0 0 18px rgba(6,182,212,.45)}80%{border-color:#8b5cf6;box-shadow:0 0 0 1px rgba(139,92,246,.28),0 0 18px rgba(139,92,246,.45)}100%{border-color:#ef4444;box-shadow:0 0 0 1px rgba(239,68,68,.28),0 0 18px rgba(239,68,68,.45)}}.app[data-border-mode="off"] .container{border-color:#111827!important;box-shadow:none!important}.topStatusRow{display:grid!important;grid-template-columns:minmax(58px,1fr) 104px 34px 34px!important;align-items:center!important;gap:6px!important;margin-bottom:10px!important}.topPlaylistButton{height:30px;width:100%;max-width:100%;min-width:0;border:1px solid #374151;border-radius:8px;background:#111827;color:#f8fafc!important;font-weight:900;font-size:10.5px;text-align:left;padding:0 8px;white-space:nowrap;overflow:hidden;box-shadow:none;display:flex!important;align-items:center!important}.topPlaylistTicker{display:block;width:100%;min-width:0;overflow:hidden;white-space:nowrap;color:#f8fafc!important}.topPlaylistTickerStatic{text-overflow:ellipsis}.topPlaylistTickerTrack{display:inline-flex;align-items:center;gap:30px;min-width:max-content;will-change:transform}.topPlaylistTickerTrack>span{flex:0 0 auto}.topPlaylistTickerAnimated .topPlaylistTickerTrack{animation:topPlaylistTickerScroll 9s linear infinite}@keyframes topPlaylistTickerScroll{0%{transform:translateX(0)}100%{transform:translateX(calc(-50% - 15px))}}.playlistOption[data-action="playlist-select"]{display:grid!important;grid-template-columns:minmax(0,1fr) auto!important;align-items:center!important;gap:10px!important}.playlistOption[data-action="playlist-select"] .playlistOptionText{min-width:0;overflow:hidden;white-space:nowrap;text-align:left}.playlistOptionTicker{display:block;width:100%;min-width:0;overflow:hidden;white-space:nowrap;color:#f8fafc!important}.playlistOptionTickerStatic{text-overflow:ellipsis}.playlistOptionTickerTrack{display:inline-flex;align-items:center;gap:30px;min-width:max-content;will-change:transform}.playlistOptionTickerTrack>span{flex:0 0 auto}.playlistOptionTickerAnimated .playlistOptionTickerTrack{animation:topPlaylistTickerScroll 9s linear infinite}.playlistOptionTime{justify-self:end;color:#facc15;font-weight:1000;font-size:12px;white-space:nowrap}.topTimerBtn{height:30px;width:104px;min-width:104px;border:1px solid #facc15;border-radius:8px;background:#16120a;color:#facc15!important;font-weight:900;font-size:12px;text-align:center;padding:0 4px;white-space:nowrap;box-shadow:0 0 0 1px rgba(250,204,21,.14)}.topHeaderTools{display:contents!important}.topMiniBtn{width:34px;height:30px;border:1px solid #475569;border-radius:8px;color:#f8fafc!important;font-weight:900;font-size:21px;line-height:1;display:flex!important;align-items:center!important;justify-content:center!important;padding:0!important;text-align:center!important}.topMenuIcon{display:block;line-height:1;transform:translateY(-2px)}.topMenuBtn{background:#6d28d9!important;border-color:#a78bfa!important}.topSettingsBtn{background:#1f2937!important;border-color:#4b5563!important;color:#f8fafc!important}.topMiniBtn:active,.topPlaylistButton:active,.topTimerBtn:active{transform:translateY(1px);filter:brightness(1.12)}.playingText,.playingTimeText{color:#f8fafc!important}.topRightTools{display:none!important}.bridgeOnline,.bridgeOffline{display:none!important}.headerRow{margin-top:1px!important;margin-bottom:7px!important}.middleInfo{display:flex!important;align-items:center!important;justify-content:center!important;min-height:22px!important;margin-top:4px!important}.middleInfoText{display:block!important;color:#facc15!important;font-size:13px!important;font-weight:1000!important;letter-spacing:.035em!important;text-align:center!important}.tabRow{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(70px,.72fr)!important;gap:6px!important;width:100%!important;padding-right:0!important}.tabRow>.tab,.tabRow>.activeTab{min-width:0!important;width:100%!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:clip!important;padding-left:5px!important;padding-right:5px!important;font-size:11.5px!important}.btnPlayActive{border-color:#22c55e!important;background:#14532d!important}.btnStopActive{border-color:#ef4444!important;background:#991b1b!important}.authGateError{color:#fecaca;font-weight:900;text-align:center}.rowLabelText{font-weight:900}.app .item .text,.app .item .timeText,.app .item .rowLabelText,.app .item .marqueeStatic,.app .item .marqueeTrack,.app .item .marqueeSegment,.app .item.blockItem .text,.app .item.blockItem .timeText,.app .item.blockItem .rowLabelText,.app .item.blockItem .blockText,.app .item.blockItem .blockTimeText{color:#f8fafc!important;text-shadow:none!important}.app .item.selectedBlue .selectedBlueText,.app .item.selectedBlue .selectedBlueTimeText,.app .item.playing .playingText,.app .item.playing .playingTimeText{color:#ffffff!important}.directorPopup{position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:10050;pointer-events:none;min-width:150px;max-width:82vw;padding:14px 20px;border-radius:14px;border:1px solid #facc15;background:rgba(2,6,23,.96);color:#facc15;text-align:center;font-weight:900;font-size:18px;letter-spacing:.04em;box-shadow:0 18px 40px rgba(0,0,0,.45),0 0 0 1px rgba(250,204,21,.18)}.settingsNumberGrid{margin-top:8px!important}.modalInfoText{color:#e5e7eb;text-align:center;font-weight:800;line-height:1.35;margin:12px 0 16px}.timerModalBox{max-width:430px!important;padding:20px!important}.timerModalPreview{height:74px;display:flex;align-items:center;justify-content:center;border:1px solid #374151;border-radius:12px;background:#05070a;color:#facc15;font-size:30px;font-weight:900;margin-bottom:16px;letter-spacing:.04em}.timerModeGrid,.settingsThemeGrid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}.timerModeGridThree{grid-template-columns:1fr 1fr 1fr!important}.timerModeGridThree>button{height:44px!important;min-height:44px!important;font-size:11px!important;padding-left:4px!important;padding-right:4px!important}.timerActionButtons{display:grid!important;grid-template-columns:1fr 1fr!important;gap:10px!important;margin-top:14px!important}.timerActionButtons>button{width:100%!important;min-width:0!important;height:44px!important;min-height:44px!important}.settingsWideGrid{display:grid;grid-template-columns:1fr;gap:10px;margin:0 0 12px}.settingsModalBox{max-width:330px}.settingsThemeGrid>button,.settingsWideGrid>button{height:42px!important;min-height:42px!important}.settingsBorderModeButton{background:#111827!important;border-color:#475569!important;color:#f8fafc!important;box-shadow:none!important}.settingsBorderModeButton:active{filter:brightness(1.12);transform:translateY(1px)}.mixerContentPanel{flex:1 1 auto!important;min-height:0!important}.mixerListBox{flex:1 1 auto!important;min-height:0!important;height:auto!important;padding:0!important;scroll-padding-bottom:8px!important}.mixerRowsBox{display:contents!important;border:0!important;background:transparent!important}.mixerRow{display:grid;grid-template-columns:10px 28px minmax(0,1fr) 72px 38px 38px;align-items:center;gap:7px;padding:10px;border-bottom:1px solid #18212c;min-height:56px}.mixerRow:last-child{border-bottom:0}.mixerRowColor{width:8px;height:36px;border-radius:999px;background:#334155}.mixerRowIndex{font-weight:900;color:#cbd5e1;text-align:center}.mixerRowMain{min-width:0}.mixerRowName{font-weight:900;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowGroupName{font-size:11px;color:#94a3b8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mixerRowDb{font-weight:1000;color:#facc15;text-align:right;white-space:nowrap;font-size:11px}.mixerMiniBtn{height:34px;width:34px;border-radius:8px;border:1px solid #475569;background:#111827;color:#f8fafc;font-weight:900}.mixerMiniMute.mixerMiniBtnActive{background:#dc2626!important;border-color:#f87171!important;color:#fff!important}.mixerMiniSolo.mixerMiniBtnActive{background:#facc15!important;border-color:#fde047!important;color:#111827!important}.mixerVolumeOverlay{align-items:center!important;justify-content:center!important;padding:0 8px!important}.mixerVolumeModalBoxWide{width:min(96vw,620px)!important;max-width:620px!important;padding:16px!important;box-sizing:border-box!important}.mixerModalHeader{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px}.mixerVolumeDbDisplay{text-align:center;color:#facc15;font-weight:1000;font-size:30px;margin:12px 0}.mixerVolumeSliderWide{width:100%!important;max-width:none!important;height:78px!important;min-height:78px!important;accent-color:#facc15!important;touch-action:pan-x!important;-webkit-appearance:none;appearance:none;background:transparent!important}.mixerVolumeSliderWide::-webkit-slider-runnable-track{height:28px!important;border-radius:999px!important;background:#1f2937!important;border:1px solid #facc15!important;box-shadow:inset 0 0 0 2px rgba(250,204,21,.12)!important}.mixerVolumeSliderWide::-webkit-slider-thumb{-webkit-appearance:none!important;appearance:none!important;width:42px!important;height:42px!important;border-radius:50%!important;background:#facc15!important;border:3px solid #fff7cc!important;box-shadow:0 0 0 5px rgba(250,204,21,.18)!important;margin-top:-8px!important}.mixerVolumeSliderWide::-moz-range-track{height:28px!important;border-radius:999px!important;background:#1f2937!important;border:1px solid #facc15!important}.mixerVolumeSliderWide::-moz-range-thumb{width:42px!important;height:42px!important;border-radius:50%!important;background:#facc15!important;border:3px solid #fff7cc!important;box-shadow:0 0 0 5px rgba(250,204,21,.18)!important}.mixerZeroDbBtn{height:46px!important;margin-top:8px!important;background:#facc15!important;color:#111827!important;border-color:#facc15!important}.premixInlineSlider{width:108px;min-width:80px;accent-color:#facc15}.premixSongStatus{display:inline-flex;align-items:center;justify-content:center;min-width:42px;height:24px;border-radius:999px;font-weight:900;font-size:12px;border:1px solid #475569}.premixSongStatusOn{background:#14532d;color:#bbf7d0;border-color:#22c55e}.premixSongStatusOff{background:#3f1d1d;color:#fecaca;border-color:#ef4444}
        </style>
        <style>
          html[data-director-device="phone"] .app:not(.musicianMonitor) .controlsRowDirectorMain{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr))!important;gap:4px!important;width:100%!important;max-width:100%!important;padding-right:0!important}
          html[data-director-device="phone"] .app:not(.musicianMonitor) .tabRow{display:grid!important;grid-template-columns:repeat(3,minmax(0,1fr))!important;gap:6px!important;width:100%!important;max-width:100%!important;padding-right:0!important}
          html[data-director-device="phone"] .app:not(.musicianMonitor) .controlsRowDirectorMain>button,
          html[data-director-device="phone"] .app:not(.musicianMonitor) .tabRow>button{box-sizing:border-box!important;display:flex!important;align-items:center!important;justify-content:center!important;flex:none!important;width:100%!important;min-width:0!important;max-width:100%!important;height:42px!important;min-height:42px!important;max-height:42px!important;margin:0!important}
        </style>
        <style>
          .app .item.selectedBlue .selectedBlueText,.app .item.selectedBlue .selectedBlueTimeText,.app .item.selectedPink .selectedPinkText,.app .item.selectedPink .selectedPinkTimeText,.app .item.queuedYellow .queuedYellowText,.app .item.queuedYellow .queuedYellowTimeText,.app .item.queuedGreen .queuedGreenText,.app .item.queuedGreen .queuedGreenTimeText,.app .item.queuedYellow .leftCol span,.app .item.queuedYellow .rightCol span,.app .item.queuedGreen .leftCol span,.app .item.queuedGreen .rightCol span,.app .item.queuedYellow .marqueeStatic,.app .item.queuedYellow .marqueeTrack,.app .item.queuedYellow .marqueeSegment,.app .item.queuedGreen .marqueeStatic,.app .item.queuedGreen .marqueeTrack,.app .item.queuedGreen .marqueeSegment,.app .item.playing .playingText,.app .item.playing .playingTimeText,.app .item.playing .leftCol span,.app .item.playing .rightCol span,.app .item.playing .marqueeStatic,.app .item.playing .marqueeTrack,.app .item.playing .marqueeSegment{color:#050505!important;text-shadow:none!important}
        </style>
        <style>
          .transportSeekHoldTarget{flex:0 0 auto}.transportSeekOverlay{position:fixed;inset:0;z-index:10060;background:rgba(2,6,23,.78);display:flex;align-items:center;justify-content:center;padding:18px 10px}.transportSeekModal{width:min(92vw,500px);max-width:500px;border:1px solid #7c3aed;border-radius:16px;background:#0b1220;box-shadow:0 24px 56px rgba(0,0,0,.5),0 0 0 1px rgba(167,139,250,.18);padding:14px;display:flex;flex-direction:column;gap:12px}.transportSeekRegionCard{border:1px solid #7c3aed;border-radius:12px;overflow:hidden;background:#111827}.transportSeekRegionTitle{padding:7px 10px;background:#6d28d9;color:#f8fafc;font-weight:1000;font-size:12px;letter-spacing:.03em;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.transportSeekWaveButton{position:relative;display:block;width:100%;height:126px;border:0;background:linear-gradient(180deg,#1b1f2a 0%,#0f172a 100%);padding:0;overflow:hidden;touch-action:none}.transportSeekWaveGrid{position:absolute;inset:0;background-image:linear-gradient(to right,rgba(255,255,255,.06) 1px,transparent 1px),linear-gradient(to bottom,rgba(255,255,255,.05) 1px,transparent 1px);background-size:22px 100%,100% 22px}.transportSeekWaveBars{position:absolute;left:10px;right:10px;top:18px;bottom:16px;display:flex;align-items:center;gap:2px}.transportSeekWaveBar{flex:1 1 0;background:linear-gradient(180deg,rgba(203,213,225,.88),rgba(100,116,139,.88));border-radius:999px;align-self:center;min-height:10%}.transportSeekMarkers{position:absolute;inset:0;pointer-events:none}.transportSeekMarkerLine{position:absolute;top:10px;bottom:10px;width:1px;background:rgba(6,182,212,.78);transform:translateX(-50%);box-shadow:0 0 7px rgba(6,182,212,.32)}.transportSeekMarkerLoop{width:2px;background:#ef4444;box-shadow:0 0 8px rgba(239,68,68,.58);z-index:3}.transportSeekMarkerHead{position:absolute;left:50%;top:-7px;transform:translateX(-50%);height:11px;line-height:11px;padding:0 3px;background:#ef4444;border:1px solid #fecaca;color:#fff;font-size:6.5px;font-weight:1000;letter-spacing:.04em;white-space:nowrap;box-shadow:0 0 6px rgba(239,68,68,.55)}.transportSeekMarkerHeadCyan{background:#06b6d4;border-color:#a5f3fc;color:#042f2e;box-shadow:0 0 6px rgba(6,182,212,.58)}.transportSeekCursorLine{position:absolute;top:8px;bottom:8px;width:2px;background:#14b8a6;transform:translateX(-50%);box-shadow:0 0 0 1px rgba(20,184,166,.18),0 0 10px rgba(20,184,166,.46)}.transportSeekCursorHead{position:absolute;top:5px;width:10px;height:10px;border-radius:999px;background:#14b8a6;transform:translateX(-50%);box-shadow:0 0 0 2px rgba(15,23,42,.88)}.transportSeekMeta{display:flex;align-items:center;justify-content:space-between;gap:10px}.transportSeekMetaText{color:#facc15;font-size:12px;font-weight:900;letter-spacing:.03em;white-space:nowrap}.transportSeekButtons{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,.86fr);gap:10px}.transportSeekButtons>button{height:44px!important;min-height:44px!important}
        </style>
        <style>
          .musicianMonitor .topStatusRow{grid-template-columns:minmax(58px,1fr) minmax(118px,.82fr) 34px!important}.musicianMonitor .topTimerBtn{width:100%!important;min-width:0!important;cursor:default!important;display:flex!important;align-items:center!important;justify-content:center!important;line-height:1!important}.musicianMonitor .topPlaylistButton{cursor:default!important}.musicianMonitor .controlsRowMusicianTp{display:grid!important;grid-template-columns:minmax(0,1fr)!important;gap:6px!important;margin-bottom:8px!important}.musicianMonitor .musicianTpOnlyButton{width:100%!important;height:42px!important;min-height:42px!important}.musicianMonitor .item{cursor:default!important}.musicianMonitor .playbackQueueHeader{flex:0 0 94px!important;min-height:94px!important;max-height:94px!important;width:100%!important;margin:0 0 8px!important;touch-action:pan-y!important}.musicianMonitor .playbackQueueLoop{animation:directorLoopPanelBlink .72s steps(2,end) infinite!important}.musicianMonitor .musicianSettingsExitButtons{margin-top:34px!important}.musicianMonitor .listBox{flex:1 1 auto!important;min-height:0!important}
        </style>
        ${popupHtml()}
        ${stopPauseModePopupHtml(data)}
        ${renderTabletSidebar()}
        ${renderTabletTopBar()}
        <div class="container">
          <div class="topStatusRow">
            ${IS_MUSICIAN_MONITOR
              ? `<button type="button" class="topPlaylistButton musicianStaticTopPlaylist" tabindex="-1" aria-disabled="true">${renderTopPlaylistTitle(topPlaylistTitle)}</button><button type="button" class="topTimerBtn ${isCountdownOverrun(data) ? 'timerOverrunBlink' : ''}" tabindex="-1" aria-disabled="true">${escapeHtml(getTimerDisplayText(data))}</button><div class="topHeaderTools"><button class="topMiniBtn topSettingsBtn" data-action="settings" aria-label="Configurações">⚙</button></div>`
              : `${state.activeTab === 'regions'
                  ? `<div class="topPlaylistButton topPlaylistButtonStatic" aria-label="Lista Geral">${renderTopPlaylistTitle(topPlaylistTitle)}</div>`
                  : `<button class="topPlaylistButton" data-action="open-playlist-modal">${renderTopPlaylistTitle(topPlaylistTitle)}</button>`}<button class="topTimerBtn ${isCountdownOverrun(data) ? 'timerOverrunBlink' : ''}" data-action="timer-open">${escapeHtml(getTimerDisplayText(data))}</button><div class="topHeaderTools"><button class="topMiniBtn topMenuBtn" data-action="top-menu" aria-label="Menu"><span class="topMenuIcon">☰</span></button><button class="topMiniBtn topSettingsBtn" data-action="settings" aria-label="Configurações">⚙</button></div>`}
          </div>
          ${IS_MUSICIAN_MONITOR ? '' : renderMenu()}
          ${IS_MUSICIAN_MONITOR ? '' : `<div class="headerRow"><div class="tabRow"><button class="${state.activeTab === 'playlist' ? 'activeTab' : 'tab'}" data-action="go-playlist">REPERTÓRIO</button><button class="${state.activeTab === 'regions' ? 'activeTab' : 'tab'}" data-action="go-regions">MÚSICAS</button><button class="${getLoopActive(data) ? 'tab loopTabActive' : 'tab'}" data-action="loop">LOOP</button></div></div>`}
          ${renderTabletMainContent(data)}
          ${IS_MUSICIAN_MONITOR ? '' : renderTransportSeekModal(data)}
        </div>
        ${renderTabletSearchScreen(data)}
        ${IS_MUSICIAN_MONITOR
          ? `${renderDirectorTelepromptScreen(data)}${renderSettingsModal()}`
          : `${renderMarkersOverlay(data)}${renderDirectorTelepromptScreen(data)}${renderPlaylistModal()}${renderPlaylistCopyChildrenConfirm()}${renderProjectModal()}${renderMixerVolumeModal()}${renderTimerModal()}${renderSettingsModal()}${renderNumberOrderConfirm()}${renderTabletPlayHoldModal()}${renderTabletSongToolsModal()}${renderTabletMultiLoopsModal()}${renderTabletLiveResetConfirm()}${renderLiveConfirm()}${renderTimerStopConfirm()}${renderTunerScreen()}${renderPremixFullScreen(data)}`}
      </div>
    `
  }

  function directChildByClass(parent, className) {
    if (!parent) return null
    const children = parent.children || []
    for (let index = 0; index < children.length; index += 1) {
      if (children[index].classList && children[index].classList.contains(className)) return children[index]
    }
    return null
  }

  function copyElementAttributes(target, source) {
    if (!target || !source) return
    const oldNames = target.getAttributeNames ? target.getAttributeNames() : []
    for (let index = 0; index < oldNames.length; index += 1) {
      if (!source.hasAttribute(oldNames[index])) target.removeAttribute(oldNames[index])
    }
    const newNames = source.getAttributeNames ? source.getAttributeNames() : []
    for (let index = 0; index < newNames.length; index += 1) {
      target.setAttribute(newNames[index], source.getAttribute(newNames[index]))
    }
  }

  function replaceChildrenAround(parent, nextParent, currentAnchor, nextAnchor, keepStyleNodes) {
    if (!parent || !nextParent || !currentAnchor || !nextAnchor) return false
    const currentNodes = Array.from(parent.childNodes || [])
    for (let index = 0; index < currentNodes.length; index += 1) {
      const node = currentNodes[index]
      const keepStyle = keepStyleNodes && node.nodeType === 1 && String(node.tagName || '').toLowerCase() === 'style'
      if (node !== currentAnchor && !keepStyle) parent.removeChild(node)
    }

    let afterAnchor = false
    const nextNodes = Array.from(nextParent.childNodes || [])
    for (let index = 0; index < nextNodes.length; index += 1) {
      const node = nextNodes[index]
      if (node === nextAnchor) {
        afterAnchor = true
        continue
      }
      if (keepStyleNodes && node.nodeType === 1 && String(node.tagName || '').toLowerCase() === 'style') continue
      if (afterAnchor) parent.appendChild(node)
      else parent.insertBefore(node, currentAnchor)
    }
    return true
  }

  function updateAppHtmlPreservingTopStatus(html) {
    const currentApp = directChildByClass(root, 'app')
    if (!currentApp) {
      root.innerHTML = html
      return
    }

    const template = document.createElement('template')
    template.innerHTML = html
    const nextApp = directChildByClass(template.content, 'app')
    const currentContainer = directChildByClass(currentApp, 'container')
    const nextContainer = directChildByClass(nextApp, 'container')
    const currentTop = directChildByClass(currentContainer, 'topStatusRow')
    const nextTop = directChildByClass(nextContainer, 'topStatusRow')
    if (!nextApp || !currentContainer || !nextContainer || !currentTop || !nextTop) {
      root.innerHTML = html
      return
    }

    copyElementAttributes(currentApp, nextApp)
    copyElementAttributes(currentContainer, nextContainer)
    copyElementAttributes(currentTop, nextTop)

    const currentTitle = currentTop.querySelector('.topPlaylistTicker')
    const nextTitle = nextTop.querySelector('.topPlaylistTicker')
    const sameTitle = !!currentTitle && !!nextTitle && currentTitle.textContent === nextTitle.textContent
    if (!sameTitle) currentTop.innerHTML = nextTop.innerHTML

    replaceChildrenAround(currentContainer, nextContainer, currentTop, nextTop, false)
    replaceChildrenAround(currentApp, nextApp, currentContainer, nextContainer, true)
  }

  function scheduleRender(force = false) {
    if (force) {
      state.lastHtmlSignature = ''
      state.renderForceRequested = true
    }
    if (state.renderScheduled) return
    state.renderScheduled = true

    const runRender = () => {
      if (!state.renderScheduled) return
      state.renderScheduled = false
      const forceRender = force || state.renderForceRequested
      state.renderForceRequested = false
      syncTrackMeterPolling()
      syncMainControlButtonsDom()
      syncTabletMultiLoopBypassDom()
      syncMixerRowsDom()
      syncDirectorPopupDom()
      if (!forceRender && transportTouchId !== null) {
        syncPlaybackProgressDom()
        syncTimerDom()
        return
      }
      if (!forceRender && state.showRecadosScreen && isDirectorRecadosInputFocused()) {
        syncDirectorRecadosDom()
        return
      }
      if (!forceRender && state.showTabletSearch && document.activeElement?.id === 'tabletSearchInput') {
        syncTabletSearchResultsDom()
        syncPlaybackProgressDom()
        syncTimerDom()
        return
      }
      const html = renderApp()
      const sig = `${state.activeTab}|${state.tabletPartsSplit}|${state.tabletPreviewPage}|${state.showTabletSearch}|${state.showMenu}|${state.showMarkersOverlay}|${state.showPlaylistModal}|${state.showProjectModal}|${state.showMixerVolume}|${state.mixerVolumeTarget}|${state.showTimerModal}|${state.showTunerScreen}|${state.showTelepromptScreen}|${state.showRecadosScreen}|${state.showTransportSeekModal}|${getTransportSeekTargetKey()}|${getHashDrawersRenderSignature()}|${state.showPremixScreen}|${state.premixSongId}|${state.premixPlaySongId}|${getPremixSnapshotSongId()}|${getPremixSongSections().length}|${getPremixAllItemRows().length}|${state.showTabletSongToolsModal}|${state.tabletSongToolsChoice}|${state.showTabletMultiLoopsModal}|${state.tabletMultiLoopTracksSlot}|${state.tabletMultiLoopAutoLimitTarget ? `${state.tabletMultiLoopAutoLimitTarget.id}:${state.tabletMultiLoopAutoLimitTarget.valueDb}` : ''}|${state.showTabletLiveResetConfirm}|${state.numberOrderConfirmKind}|${state.numberOrderConfirmContext}|${state.numberOrderConfirmUseRegionId}|${state.numberOrderConfirmDescending}|${JSON.stringify(state.snapshot?.multiloops || {})}|${state.telepromptSlot}|${getDirectorTelepromptContentKey()}|${getDirectorTechnicalNoticeKey()}|${state.tunerSourceTab}|${getTunerValuesSignature()}|${getBorderColorMode()}|${getNumberColumnMode()}|${getNumberSortDirection()}|${getAppliedNumberSortDirection()}|${getPlayProtectionEnabled()}|${state.authAuthenticated}|${state.popupText}|${state.popupUntil}|${JSON.stringify(compactRenderState())}`
      if (sig !== state.lastHtmlSignature) {
        if (!forceRender && state.showTransportSeekModal && getTransportSeekTarget(state.snapshot) && root.querySelector('.transportSeekOverlay, .tabletTransportPanel')) {
          state.lastHtmlSignature = sig
          syncPlaybackProgressDom()
          syncTimerDom()
          syncDirectorTelepromptDom()
          syncDirectorTechnicalNoticeDom()
          syncTransportSeekModalDom()
          return
        }
        if (!forceRender && state.showTelepromptScreen && root.querySelector('.directorTpOverlay')) {
          state.lastHtmlSignature = sig
          syncPlaybackProgressDom()
          syncTimerDom()
          syncDirectorTelepromptDom()
          syncDirectorTechnicalNoticeDom()
          return
        }
        if (!forceRender && isCountdownInputFocused()) {
          syncTimerModalDom()
          syncTimerDom()
          return
        }
        if (!forceRender && state.showMixerVolume && root.querySelector('.mixerVolumeModalBox')) {
          state.lastHtmlSignature = sig
          syncMixerVolumeModalDom()
          syncTimerDom()
          return
        }
        if (!forceRender && state.tabletMultiLoopAutoLimitTarget && root.querySelector('.tabletMultiLoopAutoLimitModal')) {
          state.lastHtmlSignature = sig
          syncPlaybackProgressDom()
          syncTimerDom()
          return
        }
        if (!forceRender && state.showRecadosScreen && root.querySelector('.directorRecadosRoot')) {
          state.lastHtmlSignature = sig
          syncDirectorRecadosDom()
          syncTimerDom()
          return
        }
        const scrollState = captureListScrollState()
        state.lastHtmlSignature = sig
        updateAppHtmlPreservingTopStatus(html)
        restoreFocusedInput()
        restoreListScrollState(scrollState)
      }
      syncPlaybackProgressDom()
      syncTimerDom()
      syncDirectorTelepromptDom()
      syncDirectorTechnicalNoticeDom()
      syncTransportSeekModalDom()
      syncTabletTunerRowsDom()
      syncMainControlButtonsDom()
      syncTrackMetersDom()
      syncMixerRowsDom()
      focusPendingTabletSearchResultDom()
      focusPendingDirectorSelectionDom()
      restoreTabletMultiLoopTracksScrollDom()
    }

    window.requestAnimationFrame(runRender)
  }

  function focusPendingTabletSearchResultDom() {
    const pending = state.tabletSearchPendingFocus
    if (!pending || !pending.id || pending.scheduled) return
    pending.scheduled = true
    const startedAt = now()
    const deadlineAt = startedAt + 6000
    let stableList = null
    const retry = (delay) => {
      if (state.tabletSearchPendingFocus !== pending) return
      window.setTimeout(applyFocus, delay)
    }
    const applyFocus = () => {
      if (state.tabletSearchPendingFocus !== pending) return
      const layoutRestoring = state.showTabletSearch ||
        document.documentElement.classList.contains('directorSearchPortraitMode') ||
        document.documentElement.classList.contains('directorSearchViewportRestoring') ||
        !!state.tabletSearchViewportRestoreTimer
      if (layoutRestoring) {
        if (now() < deadlineAt) retry(80)
        else state.tabletSearchPendingFocus = null
        return
      }
      if (pending.destinationTab && state.activeTab !== pending.destinationTab) {
        if (now() < deadlineAt) retry(80)
        else state.tabletSearchPendingFocus = null
        return
      }
      const scope = root.querySelector('.tabletMainSplitPrimary') || root.querySelector('.container') || root
      let wantedRow = scope.querySelector('[data-tablet-search-scroll-target="1"]')
      if (!wantedRow) {
        const rows = scope.querySelectorAll('.listBox [data-action="select-item"]')
        for (let index = 0; index < rows.length; index += 1) {
          const row = rows[index]
          const type = String(row.getAttribute('data-item-type') || '')
          const id = String(row.getAttribute(type === 'playlist' ? 'data-song-id' : 'data-region-id') || '')
          if (type === pending.itemType && id === String(pending.id)) {
            wantedRow = row
            break
          }
        }
      }
      if (!wantedRow) {
        if (now() < deadlineAt) retry(80)
        else state.tabletSearchPendingFocus = null
        return
      }
      const list = wantedRow.closest('.listBox')
      if (!list) {
        if (now() < deadlineAt) retry(80)
        else state.tabletSearchPendingFocus = null
        return
      }
      // Posiciona somente quando a lista é criada ou substituída. Enquanto a
      // mesma lista continuar na tela, nunca força o scroll novamente: assim
      // o usuário pode sair do resultado imediatamente.
      if (stableList === list) {
        if (now() - startedAt >= 1600 || now() >= deadlineAt) state.tabletSearchPendingFocus = null
        else retry(90)
        return
      }
      stableList = list
      const releaseFocus = () => {
        try { list.removeEventListener('touchstart', releaseFocus) } catch (_) {}
        try { list.removeEventListener('pointerdown', releaseFocus) } catch (_) {}
        try { list.removeEventListener('wheel', releaseFocus) } catch (_) {}
        if (state.tabletSearchPendingFocus === pending) state.tabletSearchPendingFocus = null
      }
      try { list.addEventListener('touchstart', releaseFocus, { passive: true }) } catch (_) { list.addEventListener('touchstart', releaseFocus) }
      try { list.addEventListener('pointerdown', releaseFocus) } catch (_) {}
      try { list.addEventListener('wheel', releaseFocus, { passive: true }) } catch (_) { list.addEventListener('wheel', releaseFocus) }
      const listRect = list.getBoundingClientRect()
      const rowRect = wantedRow.getBoundingClientRect()
      const measuredScale = list.offsetHeight > 0 ? listRect.height / list.offsetHeight : 1
      const scale = Number.isFinite(measuredScale) && measuredScale > 0.05 ? measuredScale : 1
      const contentTop = listRect.top + (Number(list.clientTop) || 0) * scale
      const directRows = Array.from(list.children).filter((row) => row && row.matches && row.matches('.item[data-action="select-item"]'))
      const directIndex = directRows.indexOf(wantedRow)
      let desired = list.scrollTop + (rowRect.top - contentTop) / scale
      if (directIndex >= 0) {
        const firstOffset = Number(directRows[0] && directRows[0].offsetTop)
        const wantedOffset = Number(wantedRow.offsetTop)
        if (Number.isFinite(firstOffset) && Number.isFinite(wantedOffset) && wantedOffset >= firstOffset) {
          desired = wantedOffset - firstOffset
        } else {
          let rowOffset = 0
          for (let index = 0; index < directIndex; index += 1) rowOffset += Number(directRows[index] && directRows[index].offsetHeight) || 0
          desired = rowOffset
        }
      }
      const maximum = Math.max(0, list.scrollHeight - list.clientHeight)
      const targetTop = Math.max(0, Math.min(maximum, desired))
      list.scrollTop = targetTop
      try { list.scrollTo({ top: targetTop, left: list.scrollLeft, behavior: 'auto' }) } catch (_) { list.scrollTop = targetTop }
      if (Math.abs(list.scrollTop - targetTop) > 1 || (maximum <= 0 && directIndex > 0)) {
        try { wantedRow.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'auto' }) }
        catch (_) { try { wantedRow.scrollIntoView(true) } catch (_) {} }
      }
      window.requestAnimationFrame(() => {
        if (state.tabletSearchPendingFocus === pending && Math.abs(list.scrollTop - targetTop) > 1) list.scrollTop = targetTop
      })

      // Continua apenas observando uma eventual substituição da lista pelo
      // retorno do Bridge. Na mesma instância não reposiciona outra vez.
      if (now() >= deadlineAt) {
        state.tabletSearchPendingFocus = null
        return
      }
      retry(90)
    }
    window.setTimeout(applyFocus, 40)
  }

  function focusPendingDirectorSelectionDom() {
    const pending = state.directorSelectionScrollPending
    if (!pending || IS_MUSICIAN_MONITOR) return
    if (now() >= Number(pending.expiresAt || 0)) {
      state.directorSelectionScrollPending = null
      return
    }

    const currentTarget = getDirectorSelectionScrollTarget()
    if (!currentTarget || currentTarget.key !== pending.key) {
      state.directorSelectionScrollPending = null
      return
    }

    const retry = () => {
      if (state.directorSelectionScrollPending !== pending ||
          pending.retryTimer) return
      pending.retryTimer = window.setTimeout(() => {
        pending.retryTimer = 0
        if (state.directorSelectionScrollPending === pending) {
          focusPendingDirectorSelectionDom()
        }
      }, 70)
    }

    // A busca já possui seu próprio posicionamento. Espera ela terminar para
    // que os dois focos não disputem o scroll da lista.
    if (state.tabletSearchPendingFocus) {
      retry()
      return
    }

    const scope =
      root.querySelector('.tabletMainSplitPrimary') ||
      root.querySelector('.container') || root
    const expectedType =
      pending.tab === 'regions' ? 'region' : 'playlist'
    let wantedRow = null
    for (const row of scope.querySelectorAll(
      '.listBox [data-action="select-item"]')) {
      if (String(row.getAttribute('data-item-type') || '') !==
          expectedType) continue
      const id = String(row.getAttribute(
        expectedType === 'playlist'
          ? 'data-song-id' : 'data-region-id') || '')
      if (id === pending.id) {
        wantedRow = row
        break
      }
    }

    const list = wantedRow?.closest?.('.listBox')
    if (!wantedRow || !list ||
        list.clientHeight <= 0) {
      retry()
      return
    }

    const listRect = list.getBoundingClientRect()
    const rowRect = wantedRow.getBoundingClientRect()
    const measuredScale =
      list.offsetHeight > 0
        ? listRect.height / list.offsetHeight : 1
    const scale =
      Number.isFinite(measuredScale) &&
      measuredScale > 0.05 ? measuredScale : 1
    let targetTop = list.scrollTop
    if (rowRect.top < listRect.top) {
      targetTop -= (listRect.top - rowRect.top) / scale
    } else if (rowRect.bottom > listRect.bottom) {
      targetTop += (rowRect.bottom - listRect.bottom) / scale
    }
    const maximum =
      Math.max(0, list.scrollHeight - list.clientHeight)
    targetTop =
      Math.max(0, Math.min(maximum, targetTop))
    if (Math.abs(list.scrollTop - targetTop) > 1) {
      list.scrollTop = targetTop
    }
    state.directorSelectionScrollPending = null
  }

  function syncTabletTunerRowsDom() {
    if (!state.tabletTunerSplit) return
    const primaryList = root.querySelector('.tabletMainSplitPrimary .contentPanel>.listBox')
    const tunerList = root.querySelector('.tabletTunerList')
    const spacer = root.querySelector('.tabletTunerTopSpacer')
    if (!primaryList || !tunerList || !spacer) return
    const contentTop = root.querySelector('.tabletTunerContent')?.getBoundingClientRect?.().top || 0
    const listTop = primaryList.getBoundingClientRect().top
    spacer.style.height = `${Math.max(0, listTop - contentTop)}px`
    const primaryRows = primaryList.querySelectorAll(':scope>.item')
    const tunerRows = tunerList.querySelectorAll(':scope>.tabletTunerRow')
    tunerRows.forEach((row, index) => {
      const primaryRow = primaryRows[index]
      const height = primaryRow?.getBoundingClientRect?.().height
      if (height) {
        const baseTop = primaryRow.offsetTop
        row.style.height = `${height}px`
        row.setAttribute('data-tuner-base-top', String(baseTop))
        row.style.top = `${baseTop - primaryList.scrollTop}px`
      }
    })
  }

  function syncTabletTunerScroll(event) {
    if (!state.tabletTunerSplit) return
    const primaryList = root.querySelector('.tabletMainSplitPrimary .contentPanel>.listBox')
    const tunerRows = root.querySelectorAll('.tabletTunerList>.tabletTunerRow')
    if (!primaryList || event.target !== primaryList) return
    const offset = primaryList.scrollTop
    for (var index = 0; index < tunerRows.length; index += 1) {
      var row = tunerRows[index]
      var baseTop = Number(row.getAttribute('data-tuner-base-top') || 0)
      row.style.top = `${baseTop - offset}px`
    }
  }

  function syncTransportSeekModalDom() {
    if (!state.showTransportSeekModal) return
    const target = getTransportSeekTarget(state.snapshot)
    if (!target) return
    const pos = getTransportSeekCursorPos(target, state.snapshot)
    const percent = getTransportSeekCursorPercent(target, state.snapshot)
    const cursorOffset = Math.max(0, pos - Number(target.start || 0))
    const duration = Math.max(0, Number(target.displayDuration) || (Number(target.end || 0) - Number(target.start || 0)))
    const title = root.querySelector('[data-transport-seek-title]')
    const waveBars = root.querySelector('.transportSeekWaveBars')
    const markers = root.querySelector('.transportSeekMarkers')
    const line = root.querySelector('[data-transport-seek-cursor-line]')
    const head = root.querySelector('[data-transport-seek-cursor-head]')
    const cursorText = root.querySelector('[data-transport-seek-cursor-text]')
    const totalText = root.querySelector('[data-transport-seek-total-text]')
    const playButton = root.querySelector('[data-transport-seek-play-button]')

    if (title) {
      const nextTitle = upperText(target.name || 'MÚSICA')
      if (title.textContent !== nextTitle) title.textContent = nextTitle
    }

    if (waveBars) {
      const waveSignature = getTransportSeekWaveSignature(target)
      if (waveBars.getAttribute('data-transport-seek-wave-signature') !== waveSignature) {
        waveBars.innerHTML = renderTransportSeekWaveBarsHtml(target)
        waveBars.setAttribute('data-transport-seek-wave-signature', waveSignature)
      }
    }

    if (markers) {
      const markerSignature = getTransportSeekMarkerSignature(target, state.snapshot)
      if (markers.getAttribute('data-transport-seek-marker-signature') !== markerSignature) {
        markers.innerHTML = renderTransportSeekMarkerLinesHtml(target, state.snapshot)
        markers.setAttribute('data-transport-seek-marker-signature', markerSignature)
        // O reflow abaixo evita que o WebKit/Safari mantenha a composição antiga.
        markers.style.webkitTransform = 'translateZ(0)'
        void markers.offsetWidth
      }
    }

    if (line) line.style.left = `${percent}%`
    if (head) head.style.left = `${percent}%`
    if (cursorText) cursorText.textContent = `CURSOR ${formatTime(cursorOffset)}`
    if (totalText) totalText.textContent = `TOTAL ${formatTime(duration)}`
    if (playButton) {
      const playing = getTransportSeekPlaying(state.snapshot)
      playButton.textContent = playing ? 'PAUSE' : 'PLAY'
      playButton.classList.toggle('btnStopActive', playing)
      playButton.classList.toggle('btnPlayActive', !playing)
    }
  }

  function syncMixerVolumeModalDom() {
    const input = root.querySelector('.mixerVolumeSlider[data-action="mixer-volume"]')
    const dbDisplay = root.querySelector('.mixerVolumeDbDisplay')
    if (!input || !dbDisplay) return
    const ratio = clampRatio(input.value, 0.75)
    const id = input.getAttribute('data-mixer-id') || state.mixerVolumeTarget || ''
    const track = findMixerTrackById(id) || { id, volumeRatio: ratio }
    dbDisplay.textContent = formatMixerDb({ ...track, volumeRatio: ratio })
  }

  function captureListScrollState() {
    return Array.from(root.querySelectorAll('.listBox')).map((el, index) => ({
      index,
      top: el.scrollTop,
      left: el.scrollLeft,
    }))
  }

  function restoreListScrollState(scrollState) {
    if (!Array.isArray(scrollState) || !scrollState.length) return
    const boxes = Array.from(root.querySelectorAll('.listBox'))
    for (const item of scrollState) {
      const el = boxes[item.index]
      if (!el) continue
      el.scrollTop = Math.max(0, Number(item.top) || 0)
      el.scrollLeft = Math.max(0, Number(item.left) || 0)
    }
  }

  function syncPlaybackQueueHeaderDom(data = state.snapshot || {}) {
    const nowName = getNowPlayingName(data) || 'NENHUMA MÚSICA EM REPRODUÇÃO'
    const queuedName = getQueuedSongName(data) || 'FILA DE ESPERA VAZIA'
    const loopActive = getLoopActive(data)
    const hasQueue = !!(getQueuedId(data) || getQueuedSongName(data))
    const showQueueBar = hasQueue && !loopActive
    const prepareOnly = showQueueBar && getAutoplay2Enabled(data)
    const multiLoopStatus = getTransportMultiLoopStatus(data)
    const loopStatus = multiLoopStatus.kind === 'loop' ||
      multiLoopStatus.kind === 'loop-region'

    for (const header of root.querySelectorAll('.playbackQueueHeader')) {
      const nowTitle = header.querySelector(
        '.playbackQueueNow .playbackQueueTitle')
      const queuedTitle = header.querySelector(
        '.playbackQueueNext .playbackQueueTitle')
      const multiLoopLine = header.querySelector('.playbackQueueMultiLoop')
      const multiLoopTitle = multiLoopLine?.querySelector(
        '.playbackQueueTitle')
      const queueLine = header.querySelector('.playbackQueueNext')
      const queueTrack = header.querySelector('.playbackQueueTrackNext')

      if (nowTitle && nowTitle.textContent !== nowName) {
        nowTitle.textContent = nowName
      }
      if (queuedTitle && queuedTitle.textContent !== queuedName) {
        queuedTitle.textContent = queuedName
      }
      if (multiLoopTitle &&
          multiLoopTitle.textContent !== multiLoopStatus.text) {
        multiLoopTitle.textContent = multiLoopStatus.text
      }

      queueLine?.classList.toggle('playbackQueuePrepareOnly', prepareOnly)
      queueTrack?.classList.toggle('playbackQueuePrepareOnly', prepareOnly)
      queueTrack?.classList.toggle('playbackQueueTrackEmpty', !showQueueBar)
      multiLoopLine?.classList.toggle(
        'playbackQueueMultiLoopBypass',
        multiLoopStatus.kind === 'bypass')
      multiLoopLine?.classList.toggle('playbackQueueLoop', loopStatus)
      multiLoopLine?.classList.toggle(
        'playbackQueueLoopRegion',
        multiLoopStatus.kind === 'loop-region')
    }
  }

  function syncPlaybackProgressDom() {
    const data = state.snapshot || {}
    syncPlaybackQueueHeaderDom(data)
    const progress = isPlaying(data) ? getSmoothedPlaybackProgressPercent(data) : 0
    const loopActive = getLoopActive(data)
    const hasQueue = !!(getQueuedId(data) || getQueuedSongName(data))
    const showQueueBar = hasQueue && !loopActive
    const queueProgress = showQueueBar ? 100 - progress : 0

    for (const el of root.querySelectorAll('.playbackQueueFillNow, .playingRowProgressBar')) {
      el.style.width = `${progress}%`
    }
    for (const el of root.querySelectorAll('.playbackQueueFillNext, .queuedRowRegressBar')) {
      el.style.width = `${queueProgress}%`
    }
    const rawPlayPosition = getCurrentPlaybackPosition(data)
    const smoothPlayPosition = rawPlayPosition === null || !isPlaying(data)
      ? rawPlayPosition
      : rawPlayPosition + Math.max(
          0,
          Math.min(POLL_MS * 2, now() - state.lastGoodAt)
        ) / 1000
    const armedRegress = getPartsArmedRegressPercent(data, smoothPlayPosition)
    for (const el of root.querySelectorAll('.partsArmedRegressBar')) {
      el.style.width = `${armedRegress}%`
    }
    for (const el of root.querySelectorAll('.playbackQueueTrackNext')) {
      el.classList.toggle('playbackQueueTrackEmpty', !showQueueBar)
    }
    const prepareOnly = showQueueBar && getAutoplay2Enabled(data)
    for (const el of root.querySelectorAll('.playbackQueueNext, .playbackQueueTrackNext')) {
      el.classList.toggle('playbackQueuePrepareOnly', prepareOnly)
    }
  }

  function getPartsContentRenderSignature(data = state.snapshot || {}) {
    if (!isPartsInterfaceVisible()) return ''
    const source = getEffectivePartsSongSource(data)
    const target = getPartsSongTarget(source, data)
    const rows = partsTargetIsParent(data) ? [] : getPartsMarkers(data)
    return JSON.stringify({
      transportPlaying: isPlaying(data),
      playingId: getPlayingId(data),
      queuedId: getQueuedId(data),
      source,
      target: [target?.id || '', target?.name || '', target?.start ?? '', target?.end ?? '', target?.available === true],
      parent: partsTargetIsParent(data),
      selectedMarker: state.partsLocalSelectedMarkerId || '',
      armedMarker: state.partsArmedMarkerId || '',
      takeover: state.partsTakeoverSongId || '',
      rows: rows.map((item) => [
        item?.id ?? item?.sourceNumber ?? item?.source_number ?? item?.number ?? '',
        item?.partsDisplayName ?? item?.name ?? '',
        item?.pos ?? item?.position ?? item?.markerPos ?? item?.startPos ?? item?.start_pos ?? '',
        item?.endPos ?? item?.end_pos ?? item?.rgnend ?? '',
        item?.color ?? item?.colorHex ?? item?.color_hex ?? '',
        item?.partsPrefix ?? '',
        item?.partsSongStart === true,
        item?.partsSongSource ?? '',
      ]),
    })
  }

  function compactRenderState() {
    const d = state.snapshot || {}
    const partsOpen = state.showMarkersOverlay
    return {
      online: state.bridgeOnline,
      project: getProjectName(d),
      tab: state.activeTab,
      tabletTunerSplit: state.tabletTunerSplit,
      playlist: d.activePlaylistId,
      playing: getPlayingId(d),
      transportPlaying: isPlaying(d),
      fadeoutActive: state.tabletFadeoutRuntimeActive,
      queued: getQueuedId(d),
      playingName: getNowPlayingName(d),
      queuedName: getQueuedSongName(d),
      selectedP: getSelectedPlaylistId(d),
      selectedR: getSelectedRegionId(d),
      selectedM: partsOpen ? '' : (state.selectedMarkerId || d.selectedMarkerId),
      partsSource: state.partsMarkerSongSource,
      partsEffectiveSource: getEffectivePartsSongSource(d),
      partsPlayingTarget: getPartsSongTarget('playing', d).id,
      partsQueuedTarget: getPartsSongTarget('queued', d).id,
      partsContent: getPartsContentRenderSignature(d),
      loopActive: getLoopActive(d),
      loopRange: [getLoopRange(d).start, getLoopRange(d).end],
      loopName: getLoopDisplayName(d),
      loopKind: getLoopDisplayInfo(d).kind,
      loopReached: hasPlaybackReachedLoop(d),
      multiLoopStatus: getTransportMultiLoopStatus(d).text,
      auto: partsOpen ? false : getAutoplayEnabled(d),
      autoMode: partsOpen ? 0 : getAutoplayMode(d),
      autoBloco: partsOpen ? false : getAutoBlocoEnabled(d),
      autoStop: getAutoStopEnabled(d),
      stopPauseMode: getStopPauseModeEnabled(d),
      live: getLiveEnabled(d),
      previewMode: getPreviewMode(d),
      timerMode: getEffectiveTimerMode(d),
      timerRunning: !!d.timerRunning,
      counts: [getPlaylistItems(d).length, getRegions(d).length, getMarkers(d).length, getMixerTracks(d).length, getPremixSongs(d).length, getPremixTracks(d).length],
      totals: [getActivePlaylistTotalText(d, getActivePlaylist(d)), getRegionsTotalText(d)],
      projects: getProjects(d).length,
      mixerView: state.mixerView,
      premixView: state.premixView,
      premixTrackView: state.premixTrackView,
      numberMode: getNumberColumnMode(),
      numberSort: getNumberSortDirection(),
      numberSortApplied: getAppliedNumberSortDirection(),
      borderMode: getBorderColorMode(),
      drawerStyle: getDrawerVisualStyle(d),
      liveMarkStyle: getLiveMarkVisualStyle(d),
      familyView: getFamilyViewControlsEnabled(d),
      playProtection: getPlayProtectionEnabled(),
      liveMarks: [...getPlaylistItems(d), ...getRegions(d)]
        .filter((item) => !isBlock(item))
        .map((item) => `${getId(item)}:${itemHasLiveMark(item, d) ? 1 : 0}`)
        .join('|'),
      tunerOpen: state.showTunerScreen,
      telepromptOpen: state.showTelepromptScreen,
      technicalNotice: getDirectorTechnicalNoticeKey(d),
      recadosOpen: state.showRecadosScreen,
      recadosTemplates: state.showRecadosScreen
        ? state.recadosTemplates.join('\u0000') : '',
      recadosImages: state.showRecadosScreen
        ? state.recadosTemplateImages.join('\u0000') : '',
      transportSeekOpen: state.showTransportSeekModal,
      transportSeekTarget: getTransportSeekTargetKey(d),
      premixOpen: state.showPremixScreen,
      premixTarget: state.premixSongId,
      premixSnapshotTarget: getPremixSnapshotSongId(d),
      premixItemCount: getPremixAllItemRows(d).length,
      telepromptSlot: state.telepromptSlot,
      telepromptContent: getDirectorTelepromptContentKey(),
      tunerSource: state.tunerSourceTab,
      tunerValues: getTunerValuesSignature(d),
    }
  }

  function restoreFocusedInput() {
    const input = document.getElementById('directorPassInput')
    if (input && state.authPass && input.value !== state.authPass) input.value = state.authPass
  }

  function isPartsInterfaceVisible() {
    return state.showMarkersOverlay || state.activeTab === 'markers' || state.tabletPartsSplit
  }

  function syncMarkerSelectionDom() {
    const selected = String(state.partsLocalSelectedMarkerId || '')
    const armed = String(state.partsArmedMarkerId || '')
    const armedActive = !!armed
    for (const row of root.querySelectorAll('.markerListBox [data-marker-id]')) {
      const id = String(row.getAttribute('data-marker-id') || '')
      const isArmed = armedActive && id === armed
      const isSelected = !isArmed && selected && id === selected
      row.classList.toggle('partsMarkerArmed', isArmed)
      row.classList.toggle('markerBlink', false)
      row.classList.toggle('partsMarkerLocalSelected', !!isSelected)
      let regressTrack = row.querySelector('.partsArmedRegressTrack')
      if (isArmed) {
        if (!regressTrack) {
          regressTrack = document.createElement('div')
          regressTrack.className = 'partsArmedRegressTrack'
          regressTrack.innerHTML = '<div class="partsArmedRegressBar"></div>'
          row.prepend(regressTrack)
        }
        const regressBar = regressTrack.querySelector('.partsArmedRegressBar')
        if (regressBar) regressBar.style.width = `${getPartsArmedRegressPercent(state.snapshot)}%`
      } else if (regressTrack) {
        regressTrack.remove()
      }
      row.classList.toggle('selectedBlue', false)
      row.classList.toggle('selectedPink', false)
      for (const text of row.querySelectorAll('.text, .selectedBlueText, .selectedPinkText, .playingText, .queuedYellowText, .queuedGreenText')) {
        if (text.classList.contains('playingText') || text.classList.contains('queuedYellowText') || text.classList.contains('queuedGreenText')) continue
        text.classList.toggle('text', !isSelected && !isArmed)
        text.classList.toggle('selectedBlueText', isSelected || isArmed)
        text.classList.toggle('selectedPinkText', false)
        text.style.setProperty('color', isArmed ? '#ffffff' : isSelected ? '#111827' : '#f8fafc', 'important')
      }
      for (const text of row.querySelectorAll('.timeText, .selectedBlueTimeText, .selectedPinkTimeText, .playingTimeText, .queuedYellowTimeText, .queuedGreenTimeText')) {
        if (text.classList.contains('playingTimeText') || text.classList.contains('queuedYellowTimeText') || text.classList.contains('queuedGreenTimeText')) continue
        text.classList.toggle('timeText', !isSelected && !isArmed)
        text.classList.toggle('selectedBlueTimeText', isSelected || isArmed)
        text.classList.toggle('selectedPinkTimeText', false)
        text.style.setProperty('color', isArmed ? '#ffffff' : isSelected ? '#111827' : '#f8fafc', 'important')
      }
    }
    syncPartsCancelButtonDom()
  }

  function syncPartsPlayButtonDom(playing) {
    if (!isPartsInterfaceVisible()) return
    for (const button of root.querySelectorAll('.partsOverlay [data-action="play"]')) {
      button.textContent = playing ? 'STOP' : 'PLAY'
      button.classList.toggle('btnStopActive', playing)
      button.classList.toggle('btnPlayActive', !playing)
    }
  }

  function syncPartsCancelButtonDom() {
    if (!isPartsInterfaceVisible()) return
    const armed = !!state.partsArmedMarkerId
    for (const button of root.querySelectorAll('.partsOverlay [data-action="marker-cancel"], .tabletPartsContent [data-action="marker-cancel"]')) {
      button.classList.toggle('btnStopActive', armed)
      button.classList.toggle('partsCancelArmed', armed)
      button.classList.toggle('btn', true)
    }
  }

  function syncPartsMarkerStateFromSnapshot(data = state.snapshot) {
    if (!isPartsInterfaceVisible()) return

    if (hasEnteredArmedQueuedSong(data)) {
      promotePartsQueuedMarkerTakeover(data)
      state.partsArmedMarkerId = ''
      state.partsArmedMarkerUntil = 0
      state.partsLocalSelectedMarkerId = ''
      syncMarkerSelectionDom()
      return
    }

    const nativeArmed = now() < Number(state.markerSelectionClearedUntil || 0) ? '' : String(data?.armedMarkerId || data?.markerGoId || '')
    if (nativeArmed) {
      state.partsArmedMarkerId = nativeArmed
      state.partsLocalSelectedMarkerId = nativeArmed
      state.partsArmedMarkerUntil = Number.MAX_SAFE_INTEGER
      syncMarkerSelectionDom()
      return
    }
    if (!state.partsArmedMarkerId) {
      syncPartsCancelButtonDom()
      return
    }
    const armedPos = getMarkerPositionById(state.partsArmedMarkerId, data)
    const playPos = firstFiniteNumber([data?.playPosition, data?.currentPlayPosition, data?.position])
    const crossed = !state.partsArmedOwnerSongId && armedPos !== null && playPos !== null && playPos >= armedPos - 0.08
    if (!isPlaying(data) || crossed) {
      state.partsArmedMarkerId = ''
      state.partsArmedMarkerUntil = 0
      if (crossed) state.partsLocalSelectedMarkerId = ''
      clearPartsArmedOwner()
      syncMarkerSelectionDom()
    }
  }

  function showPartsProtectionHintDom(mode) {
    if (!state.showMarkersOverlay) return
    const label = String(mode || '') === 'stop' ? '2X STOP' : '2X PLAY'
    for (const button of root.querySelectorAll('.partsOverlay [data-action="play"]')) {
      button.textContent = label
      window.setTimeout(() => {
        if (!state.showMarkersOverlay) return
        syncPartsPlayButtonDom(isPlaying())
      }, 650)
    }
  }

  function getPremixScopePayload() {
    return {
      id: state.premixSongId,
      targetId: state.premixSongId,
      songId: state.premixSongId,
      selectedRegionId: state.premixSongId,
      selectedPlaylistSongId: state.premixSongId,
      startPos: Number(state.premixSongStart) || 0,
      endPos: Number(state.premixSongEnd) || 0,
      selectedStartPos: Number(state.premixSongStart) || 0,
      selectedEndPos: Number(state.premixSongEnd) || 0,
      activeTab: state.premixSourceTab,
      page: state.premixSourceTab,
    }
  }

  function getPremixTargetPayload(data = state.snapshot) {
    const target = getPremixEffectiveTarget(data)
    return {
      id: String(target?.id || ''),
      targetId: String(target?.id || ''),
      songId: String(target?.id || ''),
      selectedRegionId: String(target?.id || ''),
      selectedPlaylistSongId: String(target?.id || ''),
      startPos: Number(target?.start) || 0,
      endPos: Number(target?.end) || 0,
      selectedStartPos: Number(target?.start) || 0,
      selectedEndPos: Number(target?.end) || 0,
      exactPosition: target?.exactPosition === true,
      useExplicitPosition: target?.exactPosition === true,
      seekToMarker: target?.exactPosition === true,
      seekTarget: target?.exactPosition === true ? 'marker' : '',
      markerNumber: Number(target?.markerNumber) || 0,
      sourceNumber: Number(target?.markerNumber) || 0,
      markerEnumIndex: Number.isFinite(Number(target?.markerEnumIndex)) ? Number(target.markerEnumIndex) : -1,
      activeTab: String(target?.tab || state.premixSourceTab),
      page: String(target?.tab || state.premixSourceTab),
    }
  }

  function getTabletSongToolsTargetFromRow(row) {
    const type = String(row?.getAttribute?.('data-item-type') || '')
    if ((type !== 'playlist' && type !== 'region') || row?.getAttribute?.('data-is-block') === '1') return null
    const attr = type === 'playlist' ? 'data-song-id' : 'data-region-id'
    const id = String(row.getAttribute(attr) || '')
    if (!id) return null
    const baseList = type === 'playlist' ? getPlaylistItems() : getRegions()
    // Filhos abertos na gaveta podem vir da coleção derivada da gaveta, e não
    // da lista principal de regiões. Incluí-los aqui permite o long press e o
    // multiloops funcionarem neles como em qualquer música.
    const drawerChildren = Object.values(state.hashRegionDrawerChildren || {})
      .flatMap((rows) => Array.isArray(rows) ? rows : [])
    const list = baseList.concat(drawerChildren)
    const childRow = row.classList.contains('hashChildItem')
    const item = (childRow ? drawerChildren : list).find((candidate) => String(getId(candidate)) === id)
      || list.find((candidate) => String(getId(candidate)) === id)
    if (!item || isBlock(item) || !isPlayable(item)) return null
    const start = getItemStart(item)
    const end = getItemEnd(item)
    return {
      type,
      tab: type === 'region' ? 'regions' : 'playlist',
      id,
      name: getRowDisplayName(item, 0, 1),
      isParent: (
        row.getAttribute('data-hash-parent') === '1'
        || isHashParent(item)
        || itemHasChildSongMarkers(item, state.snapshot)
        || Array.isArray(state.hashRegionDrawerChildren[id])
      ),
      start: Number.isFinite(start) ? start : 0,
      end: Number.isFinite(end) ? end : 0,
      // Multiloops usa a mesma chave persistente do Lua (numero da regiao).
      // A chave de Premix inclui limites de tempo e pode mudar/reabrir diferente.
      songKey: String(
        (item && item.source_number !== undefined && item.source_number !== null ? item.source_number : '')
        || (item && item.sourceNumber !== undefined && item.sourceNumber !== null ? item.sourceNumber : '')
        || (item && item.number !== undefined && item.number !== null ? item.number : '')
        || item?.tunerKey
        || item?.songKey
        || ''
      )
    }
  }

  function openTabletSongToolsForRow(row) {
    const target = getTabletSongToolsTargetFromRow(row)
    if (!target) return false
    state.tabletSongToolsTarget = target
    state.tabletSongToolsChoice = target.isParent === true ? '' : 'premix'
    state.showTabletSongToolsModal = true
    state.showTabletMultiLoopsModal = false
    state.tabletMultiLoopTracksSlot = 0
    state.showTabletLiveResetConfirm = false
    scheduleRender(true)
    return true
  }

  function openPremixScreenForTarget(target) {
    if (!target) return false
    const { type, id, name, start, end } = target
    state.showMenu = false
    state.showMarkersOverlay = false
    state.showTunerScreen = false
    state.showTelepromptScreen = false
    state.showPremixScreen = true
    state.premixSourceTab = type === 'region' ? 'regions' : 'playlist'
    state.premixSongId = id
    state.selectedPremixSongId = id
    state.premixSongName = name
    state.premixSongStart = start
    state.premixSongEnd = end
    state.premixPlaySongId = id
    state.premixPlaySongName = state.premixSongName
    state.premixPlaySongStart = state.premixSongStart
    state.premixPlaySongEnd = state.premixSongEnd
    state.premixPlayMarkerNumber = 0
    state.premixPlayMarkerEnumIndex = -1
    postCommand('premix_focus_song', getPremixScopePayload())
    scheduleRender(true)
    return true
  }

  function openPremixScreenForRow(row) {
    return openPremixScreenForTarget(getTabletSongToolsTargetFromRow(row))
  }

  function closePremixFullScreen() {
    if (!state.showPremixScreen) return
    state.showPremixScreen = false
    postCommand('premix_close', getPremixScopePayload())
    scheduleRender(true)
  }

  function leavePremixForTabletNavigation() {
    if (document.documentElement.dataset.directorDevice !== 'tablet' || !state.showPremixScreen) return false
    state.showPremixScreen = false
    postCommand('premix_close', getPremixScopePayload())
    return true
  }

  function playPremixTarget() {
    const target = getPremixEffectiveTarget()
    if (!target?.id) return
    state.premixPlaySongId = String(target.id)
    state.premixPlaySongName = String(target.name || '')
    state.premixPlaySongStart = Number(target.start) || 0
    state.premixPlaySongEnd = Number(target.end) || 0
    state.premixPlayMarkerNumber = Number(target.markerNumber) || 0
    state.premixPlayMarkerEnumIndex = Number.isFinite(Number(target.markerEnumIndex)) ? Number(target.markerEnumIndex) : -1
    state.optimisticPlayingId = String(target.id)
    state.optimisticPlayingUntil = now() + 4000
    state.optimisticStoppedUntil = 0
    postCommand('play_start', { ...getPremixTargetPayload(), noSeek: false, transportOnly: false })
    scheduleRender(true)
  }

  function pausePremixTransport() {
    postCommand('director_pause', { ...getPremixTargetPayload(), preserveCursor: true, transportOnly: true })
    scheduleRender(true)
  }

  function setTab(tab, options = {}) {
    if (state.activeTab === tab) return
    const previousTab = state.activeTab
    const changingMusicListTab = (previousTab === 'playlist' && tab === 'regions') || (previousTab === 'regions' && tab === 'playlist')
    if (changingMusicListTab) {
      state.selectedPlaylistSongId = ''
      state.selectedRegionId = ''
      state.playlistSelectionLocalUntil = 0
      state.regionSelectionLocalUntil = 0
      state.playlistSelectionClearedUntil = now() + 5000
      state.regionSelectionClearedUntil = now() + 5000
    }
    state.showMarkersOverlay = false
    state.activeTab = tab
    state.showMenu = false
    const page = tab === 'playlist' ? 'playlist' : tab === 'regions' ? 'regions' : tab === 'markers' ? 'markers' : tab
    if (tab === 'playlist' || tab === 'regions') {
      if (changingMusicListTab && options.keepRemoteSelection !== true) {
        postCommand('clear_selection', {
          previousPage: previousTab,
          activeTab: page,
          page,
          clearPlaylistSelection: true,
          clearRegionSelection: true,
        })
      }
    }
    if (tab === 'playlist' || tab === 'regions' ||
        tab === 'mixer') {
      postCommand('set_page', {
        page, activeTab: page,
        previousPage: previousTab,
      })
    }
    scheduleRender(true)
  }

  function openMarkersOverlay() {
    state.showMarkersOverlay = true
    persistDirectorPanelState()
    state.partsMarkerSongSource = getPartsSongTarget('queued').available ? 'queued' : (getPartsSongTarget('playing').available ? 'playing' : 'queued')
    state.partsLocalSelectedMarkerId = ''
    state.partsArmedMarkerId = ''
    state.partsArmedMarkerUntil = 0
    clearPartsArmedOwner()
    postCommand('set_page', { page: 'markers', activeTab: 'markers' })
    scheduleRender()
  }

  function closeMarkersOverlay() {
    if (!state.showMarkersOverlay) return
    state.showMarkersOverlay = false
    persistDirectorPanelState()
    state.partsLocalSelectedMarkerId = ''
    state.partsArmedMarkerId = ''
    state.partsArmedMarkerUntil = 0
    clearPartsArmedOwner()
    const page = state.activeTab === 'playlist' ? 'playlist' : 'regions'
    postCommand('set_page', { page, activeTab: page })
    scheduleRender()
  }

  function selectedPayload(id, tab) {
    const item = tab === 'playlist'
      ? getPlaylistItems().find((x) => getId(x) === id)
      : getRegions().find((x) => getId(x) === id)
    const payload = { id, targetId: id, songId: id, selectedRegionId: id, activeTab: tab, page: tab }
    if (item) {
      const start = Number(item.startPos ?? item.start_pos ?? item.pos ?? item.rgnstart ?? item.regionStart)
      const end = Number(item.endPos ?? item.end_pos ?? item.rgnend ?? item.regionEnd)
      if (Number.isFinite(start)) payload.selectedStartPos = start
      if (Number.isFinite(end)) payload.selectedEndPos = end
      if (Number.isFinite(start) && Number.isFinite(end) && end > start) payload.queueExactPosition = true
      if (tab === 'playlist') {
        const playlistOrder = Number(item.playlistOrder ?? item.order ?? item.playlistItemIndex ?? item.playlistSongIndex ?? item.index)
        if (Number.isFinite(playlistOrder) && playlistOrder > 0) {
          payload.playlistOrder = Math.trunc(playlistOrder)
          payload.playlistItemIndex = Math.trunc(playlistOrder)
        }
        const playlistEntryId = item.playlistEntryId ?? item.playlist_entry_id
        if (playlistEntryId != null && String(playlistEntryId)) payload.playlistEntryId = String(playlistEntryId)
      }
      if (item.source_number != null) payload.source_number = item.source_number
      if (item.sourceNumber != null) payload.sourceNumber = item.sourceNumber
    }
    return payload
  }

  function manualQueuePayload(id, tab) {
    return {
      ...selectedPayload(id, tab),
      queued: true,
      manual: true,
      queuedManual: true,
      auto: false,
      autoQueue: false,
    }
  }

  function resolveBlockClickTarget(type, id) {
    if (type !== 'playlist' && type !== 'region') return id
    const list = type === 'playlist' ? getPlaylistItems() : getRegions()
    const index = list.findIndex((item) => getId(item) === id)
    if (index < 0 || !isBlock(list[index])) return id
    for (let i = index + 1; i < list.length; i += 1) {
      const item = list[i]
      if (isBlock(item)) break
      if (isPlayable(item)) return getId(item)
    }
    return ''
  }

  function focusPartsSongSource(source) {
    state.partsMarkerSongSource = source === 'queued' ? 'queued' : source === 'selected' ? 'selected' : 'playing'
    state.partsLocalSelectedMarkerId = ''
    state.partsArmedMarkerId = ''
    state.partsArmedMarkerUntil = 0
    clearPartsArmedOwner()
  }

  function focusOpenTabletTransportPanel(id, tab, source = 'selected') {
    if (!state.showTransportSeekModal || document.documentElement.dataset.directorDevice !== 'tablet') return
    const wanted = String(id || '')
    const item = wanted ? getSongItemForTransport(wanted, tab, state.snapshot) : null
    const target = item ? makeTransportSeekTarget(item, { id: wanted, tab, source }, state.snapshot) : null
    if (!target) {
      state.transportSeekSongId = ''
      state.transportSeekSongName = ''
      state.transportSeekSongStart = 0
      state.transportSeekSongEnd = 0
      state.transportSeekDisplayDuration = 0
      state.transportSeekCursorPos = 0
      return
    }
    storeTransportSeekTarget(target, true)
    state.transportSeekCursorPos = getTransportSeekCursorPos(target, state.snapshot)
  }

  function isOpenFamilyParent(item, id) {
    const parentId = String(id || getId(item) || '')
    if (!parentId || !state.hashRegionDrawers[parentId]) return false
    return isHashParent(item) ||
      Array.isArray(state.hashRegionDrawerChildren[parentId])
  }

  function rejectOpenFamilyParentQueue(item, id) {
    if (!isOpenFamilyParent(item, id)) return false
    showPopup(
      'FECHE A GAVETA PARA COLOCAR A REGIÃO-PAI NA FILA',
      'error',
      1900
    )
    scheduleRender(true)
    return true
  }

  function handleItemSelect(el) {
    const type = el.getAttribute('data-item-type')
    const forceSelect = el.getAttribute('data-force-select') === '1'
    let id = el.getAttribute(type === 'playlist' ? 'data-song-id' : type === 'region' ? 'data-region-id' : 'data-marker-id') || ''
    if (!id) return
    id = resolveBlockClickTarget(type, id)
    if (!id) return
    if ((type === 'playlist' || type === 'region') && el.classList.contains('hashChildItem')) {
      let child = null
      for (const key of Object.keys(state.hashRegionDrawerChildren)) {
        const rows = state.hashRegionDrawerChildren[key]
        if (!Array.isArray(rows)) continue
        child = rows.find((candidate) => String(getId(candidate)) === id) || null
        if (child) break
      }
      if (!child) {
        child = [...getRegions(state.snapshot), ...getPlaylistItems(state.snapshot)]
          .find((candidate) => isHashChild(candidate) && String(getId(candidate)) === id) || null
      }
      if (!child) return
      const start = Number(child.startPos) || 0
      const end = Number(child.endPos) || 0
      const markerNumber = Number(child.sourceNumber || child.source_number) || 0
      const markerEnumIndex = Number.isFinite(Number(child.markerEnumIndex)) ? Number(child.markerEnumIndex) : -1
      const regionChild = child.isRegionChild === true || String(child.sourceKind || '').toLowerCase() === 'region'
      const childPayload = {
        id,
        targetId: id,
        songId: id,
        selectedRegionId: id,
        startPos: start,
        endPos: end,
        selectedStartPos: start,
        selectedEndPos: end,
        exactPosition: true,
        useExplicitPosition: true,
        seekToMarker: !regionChild,
        seekTarget: regionChild ? 'region' : 'marker',
        markerNumber: regionChild ? 0 : markerNumber,
        regionNumber: regionChild ? markerNumber : 0,
        sourceNumber: markerNumber,
        markerEnumIndex: regionChild ? -1 : markerEnumIndex,
        sourceKind: regionChild ? 'region' : 'hash_region_marker_song',
        isRegionChild: regionChild,
        activeTab: 'regions',
        page: 'regions',
      }
      if (isPlaying()) {
        if (getPlayingId() === id) {
          focusPartsSongSource('playing')
          focusOpenTabletTransportPanel(id, 'regions', 'playing')
          scheduleRender(true)
          return
        }
        if (queuedChildConflictsWithPlayingFamily(child)) {
          showPopup('ESSA MÚSICA NÃO PODE ENTRAR NA FILA DE ESPERA', 'error', 1800)
          scheduleRender(true)
          return
        }
        if (getQueuedId() === id) {
          state.queuedSongId = ''
          state.queuedManualVisualId = ''
          state.optimisticQueueClearedUntil = now() + 5000
          postCommand('clear_queue', { ...childPayload, clearQueue: true, clearQueuedSong: true })
        } else {
          state.queuedSongId = id
          state.queuedManualVisualId = id
          state.optimisticQueueClearedUntil = 0
          focusPartsSongSource('queued')
          postCommand('queue_region_song', {
            ...childPayload,
            queued: true,
            queueExactPosition: true,
            manual: true,
            queuedManual: true,
            auto: false,
            autoQueue: false,
          })
        }
        scheduleRender(true)
        return
      }
      if (type === 'playlist') {
        state.selectedPlaylistSongId = id
        state.selectedRegionId = ''
        state.playlistSelectionLocalUntil = now() + 5000
        state.regionSelectionLocalUntil = 0
        state.playlistSelectionClearedUntil = 0
        state.regionSelectionClearedUntil = now() + 5000
      } else {
        state.selectedRegionId = id
        state.selectedPlaylistSongId = ''
        state.regionSelectionLocalUntil = now() + 5000
        state.playlistSelectionLocalUntil = 0
        state.regionSelectionClearedUntil = 0
        state.playlistSelectionClearedUntil = now() + 5000
      }
      postCommand('select_region', childPayload)
      scheduleRender(true)
      return
    }
    if (type === 'marker') {
      const isSongStart = id.indexOf('__parts_song_start__:') === 0
      const songStartTarget = isSongStart ? getActivePartsRegion(state.snapshot) : null
      const markerCommandPayload = isSongStart && songStartTarget
        ? {
            id,
            markerId: id,
            songId: songStartTarget.id,
            targetId: songStartTarget.id,
            startPos: songStartTarget.start,
            position: songStartTarget.start,
            targetPosition: songStartTarget.start,
            songStart: true,
            partsSongStart: true,
            activeTab: 'markers',
            page: 'markers',
            confirm: true,
          }
        : { id, markerId: id, activeTab: 'markers', page: 'markers', confirm: true }
      state.selectedMarkerId = id
      state.markerSelectionClearedUntil = 0
      if (!isPlaying()) {
        state.partsLocalSelectedMarkerId = id
        state.partsArmedMarkerId = ''
        state.partsArmedMarkerUntil = 0
        clearPartsArmedOwner()
        syncMarkerSelectionDom()
        postCommand('marker_go', { ...markerCommandPayload, stopped: true })
        return
      }
      if (state.partsLocalSelectedMarkerId !== id) {
        state.partsLocalSelectedMarkerId = id
        state.partsArmedMarkerId = ''
        state.partsArmedMarkerUntil = 0
        clearPartsArmedOwner()
        syncMarkerSelectionDom()
        return
      }
      state.partsArmedMarkerId = id
      state.partsArmedMarkerUntil = Number.MAX_SAFE_INTEGER
      capturePartsArmedOwner(state.snapshot)
      syncMarkerSelectionDom()
      postCommand('marker_go', { ...markerCommandPayload, armed: true })
      return
    }
    if (type === 'playlist') {
      if (isPlaying()) {
        const selectedItem = getSongItemById(id)
        if (getPlayingId() === id || itemFamilyContainsPlayingSong(selectedItem)) {
          if (getQueuedId() === id) {
            state.queuedSongId = ''
            state.queuedManualVisualId = ''
            state.optimisticQueueClearedUntil = now() + 5000
            postCommand('clear_queue', selectedPayload(id, 'playlist'))
          }
          focusPartsSongSource('playing')
          focusOpenTabletTransportPanel(id, 'playlist', 'playing')
          scheduleRender(true)
          return
        }
        if (getQueuedId() === id) {
          state.queuedSongId = ''
          state.queuedManualVisualId = ''
          state.optimisticQueueClearedUntil = now() + 5000
          focusPartsSongSource('playing')
          focusOpenTabletTransportPanel(getPlayingId(), resolveSongTabById(getPlayingId()), 'playing')
          postCommand('clear_queue', selectedPayload(id, 'playlist'))
          scheduleRender(true)
          return
        }
        if (rejectOpenFamilyParentQueue(selectedItem, id)) return
        state.queuedSongId = id
        state.queuedManualVisualId = id
        state.optimisticQueueClearedUntil = 0
        focusPartsSongSource('queued')
        focusOpenTabletTransportPanel(getPlayingId(), resolveSongTabById(getPlayingId()), 'playing')
        postCommand('queue_playlist_song', manualQueuePayload(id, 'playlist'))
      } else {
        const alreadySelected = getSelectedPlaylistId() === id
        if (alreadySelected && !forceSelect) {
          state.selectedPlaylistSongId = ''
          state.selectedRegionId = ''
          state.playlistSelectionLocalUntil = 0
          state.regionSelectionLocalUntil = 0
          focusOpenTabletTransportPanel('', 'playlist', 'selected')
          state.playlistSelectionClearedUntil = now() + 5000
          state.regionSelectionClearedUntil = now() + 5000
          postCommand('clear_selection', {
            ...selectedPayload(id, 'playlist'),
            clearPlaylistSelection: true,
            clearRegionSelection: true,
          })
          scheduleRender()
          return
        }
        state.selectedPlaylistSongId = id
        state.selectedRegionId = ''
        state.playlistSelectionLocalUntil = now() + 5000
        state.regionSelectionLocalUntil = 0
        focusPartsSongSource('selected')
        focusOpenTabletTransportPanel(id, 'playlist', 'selected')
        state.playlistSelectionClearedUntil = 0
        state.regionSelectionClearedUntil = now() + 5000
        postCommand('select_playlist_song', selectedPayload(id, 'playlist'))
      }
      scheduleRender(true)
      return
    }
    if (type === 'region') {
      if (isPlaying()) {
        const selectedItem = getSongItemById(id)
        if (getPlayingId() === id || itemFamilyContainsPlayingSong(selectedItem)) {
          if (getQueuedId() === id) {
            state.queuedSongId = ''
            state.queuedManualVisualId = ''
            state.optimisticQueueClearedUntil = now() + 5000
            postCommand('clear_queue', selectedPayload(id, 'regions'))
          }
          focusPartsSongSource('playing')
          focusOpenTabletTransportPanel(id, 'regions', 'playing')
          scheduleRender(true)
          return
        }
        if (getQueuedId() === id) {
          state.queuedSongId = ''
          state.queuedManualVisualId = ''
          state.optimisticQueueClearedUntil = now() + 5000
          focusPartsSongSource('playing')
          focusOpenTabletTransportPanel(getPlayingId(), resolveSongTabById(getPlayingId()), 'playing')
          postCommand('clear_queue', selectedPayload(id, 'regions'))
          scheduleRender(true)
          return
        }
        if (rejectOpenFamilyParentQueue(selectedItem, id)) return
        state.queuedSongId = id
        state.queuedManualVisualId = id
        state.optimisticQueueClearedUntil = 0
        focusPartsSongSource('queued')
        focusOpenTabletTransportPanel(getPlayingId(), resolveSongTabById(getPlayingId()), 'playing')
        postCommand('queue_region_song', manualQueuePayload(id, 'regions'))
      } else {
        const alreadySelected = getSelectedRegionId() === id
        if (alreadySelected && !forceSelect) {
          state.selectedRegionId = ''
          state.selectedPlaylistSongId = ''
          state.regionSelectionLocalUntil = 0
          state.playlistSelectionLocalUntil = 0
          focusOpenTabletTransportPanel('', 'regions', 'selected')
          state.regionSelectionClearedUntil = now() + 5000
          state.playlistSelectionClearedUntil = now() + 5000
          postCommand('clear_selection', {
            ...selectedPayload(id, 'regions'),
            clearPlaylistSelection: true,
            clearRegionSelection: true,
          })
          scheduleRender()
          return
        }
        state.selectedRegionId = id
        state.selectedPlaylistSongId = ''
        state.regionSelectionLocalUntil = now() + 5000
        state.playlistSelectionLocalUntil = 0
        focusPartsSongSource('selected')
        focusOpenTabletTransportPanel(id, 'regions', 'selected')
        state.regionSelectionClearedUntil = 0
        state.playlistSelectionClearedUntil = now() + 5000
        postCommand('select_region', selectedPayload(id, 'regions'))
      }
      scheduleRender(true)
    }
  }

  function handlePlay() {
    const partsOpen = isPartsInterfaceVisible()
    const playing = isPlaying()
    const fadeoutRunning = state.tabletFadeoutRuntimeActive === true
    if (!fadeoutRunning && !allowProtectedPlayTap(playing ? 'stop' : 'play', { quiet: partsOpen })) return
    if (playing) {
      ensurePartsTakeoverBeforeStop(state.snapshot)
      const partsTakeover = getPartsTakeoverTarget()
      const stoppedId = partsTakeover?.id || getPlayingId() || state.selectedPlaylistSongId || state.selectedRegionId || ''
      const stoppedTab = partsTakeover?.tab || state.activeTab
      const queuedId = getQueuedId()
      const autoBlocoTargetId = getAutoBlocoTargetId()
      const normalStopEnabled = getNormalStopEnabled(state.snapshot)
      // Fila/Auto Bloco sempre vencem o Normal Stop. O modo puro so vale
      // quando nao existe nenhuma musica aguardando para o proximo Play.
      const nextSelectionId = queuedId || autoBlocoTargetId
      const stopTargetTab = nextSelectionId ? state.activeTab : stoppedTab
      const stopSelectionId = nextSelectionId || (normalStopEnabled ? '' : stoppedId)
      const stopPayload = { activeTab: stopTargetTab, page: stopTargetTab, targetId: stopSelectionId, selectedRegionId: stopSelectionId, selectedPlaylistSongId: stopSelectionId, noSeek: true, preserveCursor: true, transportOnly: true, normalStopEnabled, clearQueue: true, clearQueuedSong: true, autoBlocoTargetSongId: autoBlocoTargetId }

      if (fadeoutRunning) {
        state.tabletFadeoutRuntimeActive = false
        state.tabletFadeoutProgress = 0
        resetTabletFadeoutVisual()
        state.tabletFadeoutRuntimePendingState = false
        state.tabletFadeoutRuntimePendingUntil = now() + 1800
        setPendingTransportPlaying(false)
        postCommand('director_stop_no_seek', stopPayload)
        showPopup('STOP CANCELADO', 'info', 800)
        scheduleRender(true)
        return
      }

      if (isManualStopFadeoutConfigured(state.snapshot)) {
        state.tabletFadeoutRuntimeActive = true
        state.tabletFadeoutProgress = 0
        anchorTabletFadeoutVisual(0)
        state.tabletFadeoutRuntimePendingState = true
        state.tabletFadeoutRuntimePendingUntil = now() + 1800
        postCommand('director_stop_no_seek', stopPayload)
        scheduleRender(true)
        return
      }

      state.optimisticPlayingId = ''
      state.optimisticPlayingUntil = 0
      setPendingTransportPlaying(false)
      if (stoppedId) {
        state.optimisticStoppedId = stoppedId
        state.optimisticStoppedTab = stoppedTab
        state.optimisticStoppedUntil = now() + 5000
      }
      if (nextSelectionId) {
        if (!autoBlocoTargetId && state.activeTab === 'regions') {
          state.selectedRegionId = nextSelectionId
          state.selectedPlaylistSongId = ''
          state.regionSelectionClearedUntil = 0
          state.playlistSelectionClearedUntil = now() + 5000
          postCommand('select_region', selectedPayload(nextSelectionId, 'regions'))
        } else {
          state.selectedPlaylistSongId = nextSelectionId
          state.selectedRegionId = ''
          state.playlistSelectionClearedUntil = 0
          state.regionSelectionClearedUntil = now() + 5000
          postCommand('select_playlist_song', selectedPayload(nextSelectionId, 'playlist'))
        }
      } else if (stoppedId) {
        // Nao ha outra musica na fila: preserva a selecao da musica que parou.
        // Havendo queuedId ou AutoBloco, o bloco acima continua com a logica antiga.
        if (stoppedTab === 'regions') {
          state.selectedRegionId = stoppedId
          state.selectedPlaylistSongId = ''
          state.regionSelectionClearedUntil = 0
          state.playlistSelectionClearedUntil = now() + 5000
        } else {
          state.selectedPlaylistSongId = stoppedId
          state.selectedRegionId = ''
          state.playlistSelectionClearedUntil = 0
          state.regionSelectionClearedUntil = now() + 5000
        }
      }
      state.queuedSongId = ''
      state.optimisticQueueClearedUntil = now() + 5000
      postCommand('director_stop_no_seek', stopPayload)
      state.selectedMarkerId = ''
      state.markerSelectionClearedUntil = now() + 5000
      state.partsLocalSelectedMarkerId = ''
      state.partsArmedMarkerId = ''
      state.partsArmedMarkerUntil = 0
      postCommand('marker_cancel', { key: 'ESC', escapeKey: true, activeTab: 'markers', page: 'markers', cancelArmedMarker: true, clearMarkerSelection: true, clearOnly: true, noSeek: true, preserveCursor: true, stopCleanup: true })
      clearPartsTakeover()
      clearPartsArmedOwner()
      syncMarkerSelectionDom()
      if (partsOpen) syncPartsPlayButtonDom(false)
      else showPopup('STOP', 'error', 800)
    } else {
      clearPartsTakeover()
      clearPartsArmedOwner()
      state.optimisticStoppedId = ''
      state.optimisticStoppedTab = ''
      state.optimisticStoppedUntil = 0
      const id = state.activeTab === 'regions' ? (state.selectedRegionId || getSelectedRegionId()) : (state.selectedPlaylistSongId || getSelectedPlaylistId())
      if (id) {
        state.optimisticPlayingId = getImmediateFamilyPlayingId(id)
        state.optimisticPlayingUntil = now() + 4000
        state.partsLastPlayingId = state.optimisticPlayingId
      }
      state.partsMarkerSongSource = 'playing'
      state.partsLocalSelectedMarkerId = ''
      state.partsArmedMarkerId = ''
      state.partsArmedMarkerUntil = 0
      setPendingTransportPlaying(true)
      postCommand('director_play_no_seek', { activeTab: state.activeTab, page: state.activeTab, targetId: id || '', songId: id || '', selectedRegionId: id || '', selectedPlaylistSongId: id || '', noSeek: true, preserveCursor: true, transportOnly: true })
      if (partsOpen) syncPartsPlayButtonDom(true)
      else showPopup('PLAY', 'success', 700)
    }
    scheduleRender(true)
  }

  function handleStopBreak() {
    if (!isPlaying() && !state.tabletFadeoutRuntimeActive) return
    if (!allowProtectedPlayTap('stop-break')) return
    ensurePartsTakeoverBeforeStop(state.snapshot)
    const partsTakeover = getPartsTakeoverTarget()
    const stoppedId = partsTakeover?.id || getPlayingId() || state.selectedPlaylistSongId || state.selectedRegionId || ''
    const stoppedTab = partsTakeover?.tab || state.activeTab
    const queuedId = getQueuedId()
    const autoBlocoTargetId = getAutoBlocoTargetId()
    const nextSelectionId = queuedId || autoBlocoTargetId
    const stopTargetTab = nextSelectionId ? state.activeTab : stoppedTab
    const targetId = nextSelectionId || stoppedId

    state.tabletFadeoutRuntimeActive = false
    state.tabletFadeoutProgress = 0
    state.tabletFadeoutRuntimePendingState = false
    state.tabletFadeoutRuntimePendingUntil = now() + 1800
    state.optimisticPlayingId = ''
    state.optimisticPlayingUntil = 0
    setPendingTransportPlaying(false, 2500)
    state.optimisticStoppedId = stoppedId
    state.optimisticStoppedTab = stoppedTab
    state.optimisticStoppedUntil = now() + 1800
    state.queuedSongId = ''
    state.optimisticQueueClearedUntil = now() + 1800
    state.selectedMarkerId = ''
    state.partsLocalSelectedMarkerId = ''
    state.partsArmedMarkerId = ''
    state.partsArmedMarkerUntil = 0

    if (targetId) {
      if (stopTargetTab === 'regions') {
        state.selectedRegionId = targetId
        state.selectedPlaylistSongId = ''
      } else {
        state.selectedPlaylistSongId = targetId
        state.selectedRegionId = ''
      }
    }

    postCommand('director_stop_break', { activeTab: stopTargetTab, page: stopTargetTab, targetId, selectedRegionId: targetId, selectedPlaylistSongId: targetId, noSeek: true, preserveCursor: true, transportOnly: true, clearQueue: true, clearQueuedSong: true, ignoreFadeout: true, stopBreak: true, autoBlocoTargetSongId: autoBlocoTargetId })
    clearPartsTakeover()
    clearPartsArmedOwner()
    syncMarkerSelectionDom()
    showPopup('STOP BREAK', 'error', 800)
    scheduleRender(true)
  }

  function toggleAutoplay(mode = 1) {
    if (state.activeTab === 'regions') {
      showPopup('AUTO DISPONÍVEL APENAS NA ABA REPERTÓRIO', 'info', 1500)
      return
    }
    const desiredMode = Number(mode) === 2 ? 2 : 1
    const currentMode = getAutoplayMode()
    const next = currentMode !== desiredMode
    state.pendingAutoplay = next
    state.pendingAutoplayMode = next ? desiredMode : 0
    state.pendingAutoplayUntil = now() + 8000
    // A extensão é o único motor da fila automática. O front apenas muda o
    // modo; ao desligar, a própria extensão remove somente a fila automática
    // e preserva uma fila escolhida manualmente.
    const command = desiredMode === 2 ? 'autoplay2_set' : 'autoplay_set'
    const payload = {
      desiredState: next ? 'on' : 'off',
      autoplayEnabled: next,
      autoplayMode: next ? desiredMode : 0,
      activeTab: state.activeTab,
      page: state.activeTab,
    }
    if (desiredMode === 2) payload.desiredAutoplay2 = next
    else {
      payload.desiredAutoplay = next
      payload.autoPlayEnabled = next
    }
    postCommand(command, payload)
    syncMainControlButtonsDom()
    scheduleRender()
  }

  function toggleLive() {
    state.showMenu = false
    state.showConfirmLiveOff = true
    scheduleRender(true)
  }

  function togglePreview(slot) {
    const selected = Math.max(1, Math.min(6, Number(slot) || 1))
    const next = getPreviewMode() === selected ? 0 : selected
    state.pendingPreviewMode = next
    state.pendingPreviewUntil = now() + 3000
    postCommand('preview_set', { previewIndex: next, previewMode: next, desiredState: next > 0 })
    showPopup(next > 0 ? `PREVIEW ${next}` : 'PREVIEW DESLIGADO', next > 0 ? 'success' : 'info', 750)
    scheduleRender(true)
  }

  function focusDirectorPasswordInput() {
    const input = document.getElementById('directorPassInput')
    if (!input) return
    try { input.focus({ preventScroll: true }) } catch (_) { input.focus() }
    try {
      const end = String(input.value || '').length
      input.setSelectionRange(end, end)
    } catch (_) {}
  }

  function login() {
    if (!authEnabled(state.snapshot)) {
      state.pcAccessReleased = false
      state.authAuthenticated = true
      state.authError = ''
      state.directorSessionAnnounced = false
      ensureDirectorSessionClaimed()
      scheduleRender(true)
      return
    }

    const pass = String(document.getElementById('directorPassInput')?.value || state.authPass || '').trim()
    state.authPass = pass
    const hash = simpleHash(pass)
    if (hash === getAuthHash()) {
      writeLocal('vshook_access_session', hash)
      writeLocal('vshook_access_session_revision', getAuthRevision())
      state.pcAccessReleased = false
      state.authAuthenticated = true
      state.authError = ''
      state.directorSessionAnnounced = false
      ensureDirectorSessionClaimed()
      scheduleRender(true)
    } else {
      state.authError = 'SENHA INVÁLIDA'
      state.authPass = ''
      const input = document.getElementById('directorPassInput')
      if (input) input.value = ''
      const error = root.querySelector('.authGateError')
      if (error) error.textContent = state.authError
      // Mantém o foco dentro do mesmo gesto que acionou ACESSAR. Isso é
      // necessário para o iOS/Android autorizarem a reabertura do teclado.
      focusDirectorPasswordInput()
    }
  }

  function confirmLiveOff() {
    const next = !getLiveEnabled()
    state.showConfirmLiveOff = false
    state.pendingLive = next
    state.pendingLiveUntil = now() + 3000
    postCommand('live_set', { enabled: next, live: next, desiredState: next })
    showPopup(next ? 'LIVE LIGADO' : 'LIVE DESLIGADO', next ? 'success' : 'marker', 900)
    scheduleRender(true)
  }

  function getPlaylistCopyItems(playlist, includeChildren) {
    const items = getPlaylistSongs(playlist)
    const parentIds = new Set(items.filter((item) => isHashParent(item)).map((item) => String(getId(item) || '')).filter(Boolean))
    const result = []
    for (const item of items) {
      if (!item) continue
      const parentId = String(item?.parentId ?? item?.parentRegionId ?? item?.parentSourceNumber ?? item?.parent_source_number ?? item?.parent_region_number ?? '')
      if (isHashChild(item) && parentId && parentIds.has(parentId)) continue
      result.push(item)
      const itemId = String(getId(item) || '')
      if (includeChildren === true && itemId && parentIds.has(itemId)) {
        for (const child of buildHashDrawerChildren(itemId, 'playlist', state.snapshot)) result.push(child)
      }
    }
    return result
  }

  function playlistCopyHasFamilyChildren(playlist) {
    return getPlaylistSongs(playlist).some((item) => {
      const id = String(getId(item) || '')
      return !!id && isHashParent(item) && buildHashDrawerChildren(id, 'playlist', state.snapshot).length > 0
    })
  }

  function buildPlaylistCopyText(playlist, includeChildren = false) {
    const items = getPlaylistCopyItems(playlist, includeChildren)
    const itemLines = []
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index]
      if (!item) continue
      if (isBlock(item)) {
        if (itemLines.length && itemLines[itemLines.length - 1] !== '') itemLines.push('')
        itemLines.push(`[${getPlaylistCopyBlockTitle(item, index + 1)}]`)
      } else {
        itemLines.push(String(getName(item) || ''))
      }
    }
    if (!playlist || !itemLines.length) return ''

    const directTotal = firstFiniteTotalNumber([
      playlist?.activePlaylistTotalSec,
      playlist?.currentPlaylistTotalSec,
      playlist?.playlistTotalSec,
      playlist?.totalPlaylistSec,
      playlist?.repertorioTotalSec,
      playlist?.repertoryTotalSec,
      playlist?.totalDurationSec,
      playlist?.total_duration_sec,
      playlist?.totalSec,
      playlist?.durationTotalSec,
      playlist?.durationSec,
    ])
    const total = Math.max(0, Math.floor(directTotal !== null ? directTotal : getPlaylistTotalSec(playlist)))
    const hours = Math.floor(total / 3600)
    const minutes = Math.floor((total % 3600) / 60)
    const seconds = total % 60
    const totalText = hours > 0
      ? `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
      : `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
    return [String(playlist?.name || ''), '', `Tempo total: ${totalText}`, '', ...itemLines].join('\n')
  }

  function getPlaylistCopyBlockTitle(item, fallbackIndex) {
    const raw = String(getName(item) || '').trim()
    const blockNumber = Math.abs(Number(item?.blockNumber ?? item?.block_number ?? item?.sourceNumber ?? item?.source_number)) || Number(fallbackIndex) || 1
    const formatted = raw.match(/^[\s=:><-]*BLOCO\s+(.+?)[\s=:><-]*$/i)
    if (formatted) {
      const suffix = String(formatted[1] || '').replace(/[\s=:><-]+$/g, '').trim()
      return `BLOCO ${upperText(suffix || String(blockNumber).padStart(2, '0'))}`
    }
    const custom = raw.replace(/^[\s=:><-]+/g, '').replace(/[\s=:><-]+$/g, '').trim()
    return upperText(custom || `BLOCO ${String(blockNumber).padStart(2, '0')}`)
  }

  function copyTextWithTemporaryField(text) {
    if (!document.body || typeof document.execCommand !== 'function') return false
    const field = document.createElement('textarea')
    const previousFocus = document.activeElement
    const scrollX = window.pageXOffset || 0
    const scrollY = window.pageYOffset || 0
    field.value = String(text || '')
    field.setAttribute('readonly', '')
    field.setAttribute('aria-hidden', 'true')
    field.style.position = 'fixed'
    field.style.left = '0'
    field.style.top = '0'
    field.style.width = '2px'
    field.style.height = '2px'
    field.style.padding = '0'
    field.style.border = '0'
    field.style.opacity = '0.01'
    field.style.fontSize = '16px'
    field.style.userSelect = 'text'
    field.style.webkitUserSelect = 'text'
    field.style.pointerEvents = 'none'
    document.body.appendChild(field)
    try {
      field.focus({ preventScroll: true })
    } catch (_) {
      field.focus()
    }
    field.select()
    try { field.setSelectionRange(0, field.value.length) } catch (_) {}
    let copied = false
    try { copied = document.execCommand('copy') === true } catch (_) { copied = false }
    field.remove()
    try {
      if (previousFocus && typeof previousFocus.focus === 'function') previousFocus.focus({ preventScroll: true })
    } catch (_) {}
    try { window.scrollTo(scrollX, scrollY) } catch (_) {}
    return copied
  }

  function copyPlaylistText(text, details = {}) {
    if (!text) {
      showPopup('SEM LISTA', 'error', 900)
      scheduleRender(true)
      return
    }
    // HTTP local no celular normalmente bloqueia navigator.clipboard. O método
    // legado precisa rodar ainda dentro do toque do usuário para funcionar no
    // Safari/iPhone e no Chrome/Android.
    if (copyTextWithTemporaryField(text)) {
      showPopup('COPIADO', 'success', 850)
      return
    }
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text)
        .then(() => showPopup('COPIADO', 'success', 850))
        .catch(() => {
          postCommand('copy_playlist_names', { activeTab: state.activeTab, page: state.activeTab, text, ...details })
          showPopup('NÃO FOI POSSÍVEL COPIAR', 'error', 1200)
        })
    } else {
      postCommand('copy_playlist_names', { activeTab: state.activeTab, page: state.activeTab, text, ...details })
      showPopup('NÃO FOI POSSÍVEL COPIAR', 'error', 1200)
    }
    scheduleRender(true)
  }

  function getPendingPlaylistForCopy() {
    const wantedId = String(state.playlistCopyPendingId || state.tabletPlaylistPendingId || '')
    const openPlaylists = getOpenProjectPlaylists()
    const openPlaylist = openPlaylists.find((playlist, index) =>
      getOpenPlaylistSelectorId(playlist, index) === wantedId)
    if (openPlaylist &&
        !openPlaylistBelongsToCurrentProject(openPlaylist)) {
      return null
    }
    const localWantedId = openPlaylist
      ? getOpenPlaylistLocalId(openPlaylist)
      : wantedId
    const playlists = Array.isArray(state.snapshot?.playlists) ? state.snapshot.playlists : []
    return playlists.find((playlist) =>
      String(playlist?.id ?? playlist?.playlistId ?? '') ===
        localWantedId) || getActivePlaylist()
  }

  function copyCurrentPlaylistFromModal(includeChildren = null) {
    const playlist = getPendingPlaylistForCopy()
    if (!playlist) {
      showPopup('NENHUM REPERTÓRIO CRIADO', 'error', 1100)
      return
    }
    const playlistId = String(playlist?.id ?? playlist?.playlistId ?? '')
    if (includeChildren === null && playlistCopyHasFamilyChildren(playlist)) {
      state.playlistCopyPendingId = playlistId
      state.showPlaylistCopyChildrenConfirm = true
      scheduleRender(true)
      return
    }
    state.showPlaylistCopyChildrenConfirm = false
    state.playlistCopyPendingId = ''
    copyPlaylistText(buildPlaylistCopyText(playlist, includeChildren === true), {
      playlistId,
      id: playlistId,
      playlistName: String(playlist?.name || ''),
    })
  }

  function renderPlaylistCopyChildrenConfirm() {
    if (!state.showPlaylistCopyChildrenConfirm) return ''
    return `<div class="modalOverlay tabletCenteredModalOverlay"><div class="modalSpacer"></div><div class="modalBox playlistCopyChildrenConfirmModal" data-stop-modal><div class="modalTitle">COPIAR REPERTÓRIO</div><div class="modalInfoText">DESEJA COPIAR COM AS MÚSICAS DA GAVETA?</div><div class="modalButtons"><button class="modalCancelBtn" data-action="playlist-copy-without-children">NÃO</button><button class="modalOkBtnWide" data-action="playlist-copy-with-children">SIM</button></div></div><div class="modalBottomSpace"></div></div>`
  }

  function openSelectedPlaylist(selectorId) {
    const playlists = getOpenProjectPlaylists()
    const playlist = playlists.find((item, index) =>
      getOpenPlaylistSelectorId(item, index) ===
        String(selectorId))
    if (!playlist) return
    const currentProject =
      openPlaylistBelongsToCurrentProject(playlist)
    if (!currentProject &&
        anyOpenProjectTransportActive()) {
      showPopup(
        'PARE A REPRODUÇÃO ANTES DE ABRIR UM REPERTÓRIO DE OUTRA ABA',
        'error', 2200)
      scheduleRender(true)
      return
    }
    const playlistId =
      getOpenPlaylistLocalId(playlist)
    const playlistName = String(playlist?.name || '')
    if (currentProject) {
      state.optimisticActivePlaylistId = playlistId
      state.optimisticActivePlaylistName = playlistName
      state.optimisticActivePlaylistUntil = now() + 12000
    } else {
      state.optimisticActivePlaylistId = ''
      state.optimisticActivePlaylistName = ''
      state.optimisticActivePlaylistUntil = 0
    }
    state.activeTab = 'playlist'
    state.selectedPlaylistSongId = ''
    state.selectedRegionId = ''
    state.selectedMarkerId = ''
    state.showPlaylistModal = false
    state.tabletPlaylistPendingId = ''
    postCommand('select_playlist', {
      id: playlistId,
      playlistId,
      activePlaylistId: playlistId,
      name: playlistName,
      playlistName,
      activePlaylistName: playlistName,
      currentPlaylistName: playlistName,
      projectId: String(playlist?.projectId || ''),
      projectIndex: Number(playlist?.projectIndex ?? playlist?.projectTabIndex ?? 0),
      projectTabIndex: Number(playlist?.projectTabIndex ?? playlist?.projectIndex ?? 0),
      projectPath: String(playlist?.projectPath || ''),
      projectName: String(playlist?.projectName || ''),
    })
    if (!currentProject) {
      showPopup(
        `ABRINDO ${upperText(playlistName)} EM ${upperText(playlist?.projectName || 'OUTRA ABA')}`,
        'success', 1200)
    }
    scheduleRender(true)
  }

  function closeTabletSearchState() {
    const input = document.getElementById('tabletSearchInput')
    if (input) {
      try { input.blur() } catch (_) {}
    }
    state.showTabletSearch = false
    state.tabletSearchQuery = ''
    setDirectorSearchPortraitMode(false)
  }

  function setDirectorSearchPortraitMode(enabled) {
    const rootElement = document.documentElement
    const tabletMode = rootElement.dataset.directorDevice === 'tablet'
    const portrait = !!enabled && tabletMode
    if (state.tabletSearchViewportRestoreTimer) {
      window.clearTimeout(state.tabletSearchViewportRestoreTimer)
      state.tabletSearchViewportRestoreTimer = 0
    }
    if (!tabletMode) {
      rootElement.classList.remove('directorSearchPortraitMode', 'directorSearchViewportRestoring')
      try { document.body.classList.remove('directorSearchPortraitMode') } catch (_) {}
      state.tabletSearchViewportSnapshot = null
      return
    }
    if (portrait) rootElement.classList.remove('directorSearchViewportRestoring')
    if (portrait && !rootElement.classList.contains('directorSearchPortraitMode')) {
      const names = ['--tablet-screen-width', '--tablet-screen-height', '--tablet-ui-width', '--tablet-ui-height', '--tablet-ui-scale', '--app-vh']
      const snapshot = {}
      for (const name of names) snapshot[name] = rootElement.style.getPropertyValue(name)
      state.tabletSearchViewportSnapshot = snapshot
    }
    try { document.documentElement.classList.toggle('directorSearchPortraitMode', portrait) } catch (_) {}
    try { document.body.classList.toggle('directorSearchPortraitMode', portrait) } catch (_) {}
    if (!portrait) {
      rootElement.classList.add('directorSearchViewportRestoring')
      const snapshot = state.tabletSearchViewportSnapshot
      if (snapshot) {
        for (const name of Object.keys(snapshot)) {
          if (snapshot[name]) rootElement.style.setProperty(name, snapshot[name])
          else rootElement.style.removeProperty(name)
        }
      }
      state.tabletSearchViewportRestoreTimer = window.setTimeout(() => {
        state.tabletSearchViewportRestoreTimer = 0
        state.tabletSearchViewportSnapshot = null
        rootElement.classList.remove('directorSearchViewportRestoring')
        updateViewportHeight()
        try {
          if (typeof window.updateDirectorTabletWebViewport === 'function') window.updateDirectorTabletWebViewport()
        } catch (_) {}
      }, 520)
    }
  }

  function handleTabletSearchResult(searchId) {
    const id = String(searchId || '')
    const data = state.snapshot || {}
    const entry = getTabletSearchEntries(data).find((candidate) => String(candidate.id) === id)
    if (!entry) return

    const destinationTab = tabletSearchEntryIsInActivePlaylist(entry, data) ? 'playlist' : 'regions'
    const itemType = destinationTab === 'playlist' ? 'playlist' : 'region'
    if (entry.isChild && entry.parentId) {
      state.hashRegionDrawers[String(entry.parentId)] = true
      buildHashDrawerChildren(String(entry.parentId), itemType, data)
      persistDirectorPanelState()
    }

    closeTabletSearchState()
    state.showProjectModal = false
    state.showPlaylistModal = false
    state.showSettingsModal = false
    state.showTelepromptScreen = false
    state.showRecadosScreen = false
    if (state.activeTab === 'mixer') state.tabletMixerReturnTab = destinationTab
    // A seleção da lupa substituirá a seleção anterior logo abaixo. Ao trocar
    // de aba não envie clear_selection, pois ele pode chegar depois do comando
    // de seleção e apagar no Bridge aquilo que acabou de ser escolhido.
    setTab(destinationTab, { keepRemoteSelection: true })

    state.tabletSearchPendingFocus = { id: entry.id, itemType, destinationTab }
    const proxy = document.createElement('div')
    proxy.setAttribute('data-item-type', itemType)
    proxy.setAttribute('data-force-select', '1')
    proxy.setAttribute(itemType === 'playlist' ? 'data-song-id' : 'data-region-id', entry.id)
    if (entry.isChild) proxy.classList.add('hashChildItem')

    handleItemSelect(proxy)
    scheduleRender(true)
  }

  function handleAction(action, el, event) {
    if (IS_MUSICIAN_MONITOR) {
      const allowed = new Set(['settings', 'theme-light', 'theme-dark', 'teleprompt-font-set', 'teleprompt-color-set', 'teleprompt-colors-more', 'modal-close', 'exit-app', 'open-teleprompt', 'teleprompt-slot-1', 'teleprompt-slot-2', 'teleprompt-back', 'family-drawer-toggle'])
      if (!allowed.has(String(action || ''))) return
    }
    switch (action) {
      case 'menu': break
      case 'top-menu': state.showMenu = !state.showMenu; scheduleRender(true); break
      case 'settings': {
        const opening = !state.showSettingsModal
        closeTabletSearchState()
        state.showMenu = false
        if (!opening) {
          closeSettingsModalInPlace()
          break
        }
        state.showSettingsModal = true
        if (opening) {
          state.showProjectModal = false
          state.showPlaylistModal = false
          state.tabletPlaylistPendingId = ''
        }
        scheduleRender(true)
        break
      }
      case 'project-selector': {
        const opening = !state.showProjectModal
        closeTabletSearchState()
        state.showMenu = false
        state.showProjectModal = opening
        if (opening) {
          state.showPlaylistModal = false
          state.tabletPlaylistPendingId = ''
          state.showSettingsModal = false
        }
        scheduleRender(true)
        break
      }
      case 'open-playlist-modal': closeTabletSearchState(); state.showMenu = false; state.showProjectModal = false; state.showSettingsModal = false; state.tabletPlaylistPendingId = ''; state.showPlaylistModal = true; scheduleRender(true); break
      case 'tablet-search': {
        const opening = !state.showTabletSearch
        closeTabletSearchState()
        state.showMenu = false
        if (opening) {
          state.showTabletSearch = true
          setDirectorSearchPortraitMode(true)
          state.showProjectModal = false
          state.showPlaylistModal = false
          state.tabletPlaylistPendingId = ''
          state.showSettingsModal = false
          state.showTelepromptScreen = false
          state.showRecadosScreen = false
        }
        scheduleRender(true)
        if (opening) window.requestAnimationFrame(() => window.requestAnimationFrame(focusTabletSearchInput))
        break
      }
      case 'tablet-search-close': closeTabletSearchState(); scheduleRender(true); break
      case 'tablet-search-result': handleTabletSearchResult(el.getAttribute('data-search-id')); break
      case 'go-playlist':
        leavePremixForTabletNavigation()
        closeTabletSearchState()
        state.showSettingsModal = false
        state.showProjectModal = false
        state.showPlaylistModal = false
        state.tabletPlaylistPendingId = ''
        state.showTelepromptScreen = false
        if (state.tabletTunerSplit) state.tunerSourceTab = 'playlist'
        setTab('playlist')
        scheduleRender(true)
        break
      case 'go-regions':
        leavePremixForTabletNavigation()
        closeTabletSearchState()
        state.showSettingsModal = false
        state.showProjectModal = false
        state.showPlaylistModal = false
        state.tabletPlaylistPendingId = ''
        state.showTelepromptScreen = false
        if (state.tabletTunerSplit) state.tunerSourceTab = 'regions'
        setTab('regions')
        scheduleRender(true)
        break
      case 'go-markers': state.showMenu = false; openMarkersOverlay(); break
      case 'open-teleprompt': state.showMenu = false; openDirectorTelepromptScreen(); break
      case 'teleprompt-slot-1': setDirectorTelepromptSlot(1); break
      case 'teleprompt-slot-2': setDirectorTelepromptSlot(2); break
      case 'teleprompt-back': closeDirectorTelepromptScreen(); break
      case 'close-markers-overlay': closeMarkersOverlay(); break
      case 'close-transport-seek-modal': closeTransportSeekModal(); break
      case 'tablet-transport-panel': state.showTransportSeekModal ? closeTransportSeekModal() : openTransportSeekModal(); break
      case 'tablet-teleprompt':
        {
        const leavingPremix = leavePremixForTabletNavigation()
        closeTabletSearchState()
        state.showProjectModal = false
        state.showSettingsModal = false
        if (leavingPremix || !state.showTelepromptScreen) openDirectorTelepromptScreen()
        else closeDirectorTelepromptScreen()
        break
        }
      case 'tablet-preview': togglePreview(el.getAttribute('data-preview-slot')); break
      case 'tablet-parts-split':
        {
        const leavingPremix = leavePremixForTabletNavigation()
        closeTabletSearchState()
        state.showMenu = false
        state.showTelepromptScreen = false
        if (state.activeTab === 'mixer') setTab(state.tabletMixerReturnTab || 'playlist')
        state.tabletPartsSplit = leavingPremix ? true : !state.tabletPartsSplit
        if (state.tabletPartsSplit) state.tabletTunerSplit = false
        if (state.tabletPartsSplit && state.activeTab === 'markers') state.activeTab = 'playlist'
        persistDirectorPanelState()
        scheduleRender(true)
        break
        }
      case 'tablet-tuner-split':
        {
        const leavingPremix = leavePremixForTabletNavigation()
        closeTabletSearchState()
        state.showMenu = false
        state.showTelepromptScreen = false
        if (state.activeTab === 'mixer') setTab(state.tabletMixerReturnTab || 'playlist')
        state.tabletTunerSplit = leavingPremix ? true : !state.tabletTunerSplit
        if (state.tabletTunerSplit) {
          state.tabletPartsSplit = false
          state.tunerSourceTab = state.activeTab === 'regions' ? 'regions' : 'playlist'
          postCommand('tuner_focus', { activeTab: state.tunerSourceTab, page: state.tunerSourceTab, visible: true })
        } else {
          postCommand('set_tuner_visibility', { visible: false, activeTab: state.tunerSourceTab, page: state.tunerSourceTab })
        }
        persistDirectorPanelState()
        scheduleRender(true)
        break
        }
      case 'tablet-mixer':
        {
        const leavingPremix = leavePremixForTabletNavigation()
        closeTabletSearchState()
        if (state.activeTab === 'mixer') {
          if (leavingPremix) {
            scheduleRender(true)
            break
          }
          setTab(state.tabletMixerReturnTab || 'playlist')
          scheduleRender(true)
          break
        }
        state.tabletMixerReturnTab = state.activeTab || 'playlist'
        state.tabletPartsSplit = false
        state.tabletTunerSplit = false
        state.showTelepromptScreen = false
        state.showRecadosScreen = false
        persistDirectorPanelState()
        setTab('mixer')
        scheduleRender(true)
        break
        }
      case 'tablet-recados':
        closeTabletSearchState()
        if (state.showRecadosScreen) closeDirectorRecadosScreen()
        else {
          state.tabletPartsSplit = false
          state.tabletTunerSplit = false
          persistDirectorPanelState()
          openDirectorRecadosScreen()
        }
        scheduleRender(true)
        break
      case 'stop-break': handleStopBreak(); break
      case 'tablet-play-hold-close': closeTabletPlayHoldModalDom(); break
      case 'tablet-song-tool-select':
        state.tabletSongToolsChoice = String(el.getAttribute('data-song-tool') || 'premix')
        scheduleRender(true)
        break
      case 'tablet-song-tool-reset':
        state.showTabletSongToolsModal = false
        state.showTabletLiveResetConfirm = true
        scheduleRender(true)
        break
      case 'tablet-song-tool-close':
        state.showTabletSongToolsModal = false
        scheduleRender(true)
        break
      case 'tablet-song-tool-open': {
        const choice = state.tabletSongToolsChoice
        if (!choice) {
          showPopup('SELECIONE UMA OPÇÃO', 'error', 1500)
          scheduleRender(true)
          break
        }
        state.showTabletSongToolsModal = false
        if (choice === 'premix') openPremixScreenForTarget(state.tabletSongToolsTarget)
        else if (choice === 'multiloops') {
          state.showTabletMultiLoopsModal = true
          state.tabletMultiLoopTracksSlot = 0
          if (state.snapshot && typeof state.snapshot === 'object') {
            state.snapshot.multiloops = { songId: state.tabletSongToolsTarget?.id || '', songKey: state.tabletSongToolsTarget?.songKey || '', songName: state.tabletSongToolsTarget?.name || '', tracks: [] }
          }
          postCommand('multiloop_focus', getTabletSongToolsPayload())
          scheduleRender(true)
        } else {
          state.showTabletLiveResetConfirm = true
          scheduleRender(true)
        }
        break
      }
      case 'tablet-live-reset-cancel':
        state.showTabletLiveResetConfirm = false
        scheduleRender(true)
        break
      case 'tablet-live-reset-confirm':
        state.showTabletLiveResetConfirm = false
        postCommand('live_reset_item', getTabletSongToolsPayload())
        showPopup('MARCAÇÃO LIVE REMOVIDA', 'success', 900)
        scheduleRender(true)
        break
      case 'tablet-multiloop-loop': {
        const slot = Math.max(1, Math.min(2, Number(el.getAttribute('data-slot')) || 1))
        const data = getTabletMultiLoopsState()
        const key = `loop${slot}Enabled`
        if (data[key] !== true && data[`loop${slot}Available`] !== true) {
          showPopup(`SEM PAR DE MARKERS *${slot} COM *${slot}`, 'error', 1800)
          scheduleRender(true)
          break
        }
        data[key] = data[key] !== true
        if (!data[key]) data[`ms${slot}Enabled`] = false
        postCommand('multiloop_slot_set', getTabletSongToolsPayload({ slot, enabled: data[key], desiredState: data[key] ? 'on' : 'off' }))
        scheduleRender(true)
        break
      }
      case 'tablet-multiloop-ms': {
        const slot = Math.max(1, Math.min(2, Number(el.getAttribute('data-slot')) || 1))
        const data = getTabletMultiLoopsState()
        if (data[`loop${slot}Enabled`] !== true) {
          showPopup(`O LOOP ${slot} PRECISA ESTAR ATIVO`, 'error', 1800)
          scheduleRender(true)
          break
        }
        data[`ms${slot}Enabled`] = data[`ms${slot}Enabled`] !== true
        postCommand('multiloop_ms_set', getTabletSongToolsPayload({ slot, enabled: data[`ms${slot}Enabled`], desiredState: data[`ms${slot}Enabled`] ? 'on' : 'off' }))
        scheduleRender(true)
        break
      }
      case 'tablet-multiloop-track': {
        const slot = Math.max(1, Math.min(2, Number(el.getAttribute('data-slot')) || 1))
        const id = String(el.getAttribute('data-track-id') || '')
        const mode = String(el.getAttribute('data-mode') || '')
        const data = getTabletMultiLoopsState()
        const track = Array.isArray(data.tracks) ? data.tracks.find((row) => String(row?.guid ?? row?.id ?? '') === id) : null
        if (track && (mode === 'auto' || mode === 'mute' || mode === 'solo')) {
          const prop = `${mode}${slot}`
          track[prop] = track[prop] !== true
          if (track[prop]) {
            if (mode === 'mute') {
              track[`auto${slot}`] = false
              track[`solo${slot}`] = false
            } else {
              track[`mute${slot}`] = false
            }
          }
          postCommand('multiloop_track_set', getTabletSongToolsPayload({ slot, trackId: id, guid: id, mode, enabled: track[prop], desiredState: track[prop] ? 'on' : 'off' }))
        } else if (mode === 'auto' || mode === 'mute' || mode === 'solo') {
          const next = !el.classList.contains('active')
          postCommand('multiloop_track_set', getTabletSongToolsPayload({ slot, trackId: id, guid: id, mode, enabled: next, desiredState: next ? 'on' : 'off' }))
        }
        scheduleRender(true)
        break
      }
      case 'tablet-multiloop-auto-limit-back':
        flushMultiLoopAutoLimitCommand()
        state.tabletMultiLoopAutoLimitTarget = null
        scheduleRender(true)
        break
      case 'tablet-multiloop-fade': {
        const slot = Math.max(1, Math.min(2, Number(el.getAttribute('data-slot')) || 1))
        const delta = Number(el.getAttribute('data-delta')) || 0
        const data = getTabletMultiLoopsState()
        data[`fade${slot}Sec`] = Math.max(1, Math.min(5, (Number(data[`fade${slot}Sec`]) || 3) + delta))
        postCommand('multiloop_fade_adjust', getTabletSongToolsPayload({ slot, delta }))
        scheduleRender(true)
        break
      }
      case 'tablet-multiloop-tracks-back':
        state.tabletMultiLoopAutoLimitTarget = null
        state.tabletMultiLoopTracksSlot = 0
        scheduleRender(true)
        break
      case 'tablet-multiloop-back':
        state.tabletMultiLoopAutoLimitTarget = null
        state.showTabletMultiLoopsModal = false
        state.tabletMultiLoopTracksSlot = 0
        state.showTabletSongToolsModal = true
        postCommand('multiloop_close', getTabletSongToolsPayload())
        scheduleRender(true)
        break
      case 'tablet-multiloop-close':
        state.tabletMultiLoopAutoLimitTarget = null
        state.showTabletMultiLoopsModal = false
        state.tabletMultiLoopTracksSlot = 0
        postCommand('multiloop_close', getTabletSongToolsPayload())
        scheduleRender(true)
        break
      case 'tablet-fadeout-toggle': {
        state.tabletFadeoutEnabled = !state.tabletFadeoutEnabled
        state.tabletFadeoutPendingUntil = now() + 1800
        syncTabletPlayHoldModalDom()
        postCommand('manual_stop_fadeout_set_enabled', { enabled: state.tabletFadeoutEnabled, desiredState: state.tabletFadeoutEnabled ? 'on' : 'off' })
        break
      }
      case 'tablet-fadeout-minus': {
        state.tabletFadeoutSeconds = Math.max(1, Number(state.tabletFadeoutSeconds || 1) - 1)
        state.tabletFadeoutPendingUntil = now() + 1800
        syncTabletPlayHoldModalDom()
        postCommand('manual_stop_fadeout_set_duration', { duration: state.tabletFadeoutSeconds, durationSec: state.tabletFadeoutSeconds })
        break
      }
      case 'tablet-fadeout-plus': {
        state.tabletFadeoutSeconds = Math.min(5, Number(state.tabletFadeoutSeconds || 1) + 1)
        state.tabletFadeoutPendingUntil = now() + 1800
        syncTabletPlayHoldModalDom()
        postCommand('manual_stop_fadeout_set_duration', { duration: state.tabletFadeoutSeconds, durationSec: state.tabletFadeoutSeconds })
        break
      }
      case 'tablet-fadeout-tracks': state.tabletFadeoutTracksOpen = true; rerenderTabletPlayHoldModalDom(); break
      case 'tablet-fadeout-tracks-back': state.tabletFadeoutTracksOpen = false; rerenderTabletPlayHoldModalDom(); break
      case 'tablet-fadeout-track-toggle': {
        const id = String(el.getAttribute('data-fadeout-track-id') || '')
        if (!id) break
        const selected = new Set((state.tabletFadeoutSelectedTrackIds || []).map(String))
        if (selected.has(id)) selected.delete(id); else selected.add(id)
        state.tabletFadeoutSelectedTrackIds = Array.from(selected)
        state.tabletFadeoutTrackPendingUntil = now() + 1800
        syncTabletPlayHoldModalDom()
        postCommand('manual_stop_fadeout_toggle_track', { trackId: id, guid: id, targetId: id })
        break
      }
      case 'tablet-fadeout-tracks-all':
      case 'tablet-fadeout-tracks-clear': {
        const selectAll = action === 'tablet-fadeout-tracks-all'
        state.tabletFadeoutSelectedTrackIds = selectAll ? getMixerTracks(state.snapshot || {}).map((track) => String(track?.guid ?? track?.id ?? '')).filter(Boolean) : []
        state.tabletFadeoutTrackPendingUntil = now() + 1800
        syncTabletPlayHoldModalDom()
        postCommand('manual_stop_fadeout_set_all_tracks', { selected: selectAll, enabled: selectAll })
        break
      }
      case 'tablet-playlists':
        closeTabletSearchState()
        state.showMenu = false
        if (state.showPlaylistModal) state.tabletPlaylistPendingId = ''
        state.showPlaylistModal = !state.showPlaylistModal
        if (state.showPlaylistModal) {
          state.showProjectModal = false
          state.showSettingsModal = false
        }
        scheduleRender(true)
        break
      case 'transport-seek-set-position': handleTransportSeekSetPosition(el, event); break
      case 'transport-seek-play': handleTransportSeekPlayToggle(); break
      case 'go-mixer': setTab('mixer'); break
      case 'go-premix': setTab('premix'); break
      case 'tuner-focus': state.showMenu = false; state.tunerSourceTab = state.activeTab === 'regions' ? 'regions' : 'playlist'; state.showTunerScreen = true; postCommand('tuner_focus', { activeTab: state.tunerSourceTab, page: state.tunerSourceTab, visible: true }); scheduleRender(true); break
      case 'tuner-close': state.showTunerScreen = false; postCommand('set_tuner_visibility', { visible: false, activeTab: state.tunerSourceTab, page: state.tunerSourceTab }); scheduleRender(true); break
      case 'tuner-minus': adjustTunerFromButton(el, -1); break
      case 'tuner-plus': adjustTunerFromButton(el, 1); break
      case 'tuner-reset': adjustTunerFromButton(el, 0, 0); break
      case 'toggle-notice': openDirectorRecadosScreen(); break
      case 'recados-send': sendDirectorRecado(); break
      case 'recados-cancel': cancelDirectorRecado(); break
      case 'recados-pin': toggleDirectorRecadosPin(); break
      case 'recados-select-slot': selectDirectorRecadosSlot(el.getAttribute('data-recados-slot')); break
      case 'recados-edit-template': toggleDirectorRecadosTemplateEdit(); break
      case 'recados-choose-image':
        document.getElementById('directorRecadosImageInput')?.click()
        break
      case 'recados-remove-image': removeDirectorRecadoImage(); break
      case 'recados-exit': exitDirectorRecadosScreen(); break
      case 'atbl-toggle': {
        // O botão AT/BL é independente do Auto. Com Auto desligado ele apenas fica armado.
        const next = !getAutoBlocoEnabled()
        state.showMenu = false
        state.pendingAutoBloco = next
        state.pendingAutoBlocoUntil = now() + 8000
        postCommand('auto_bloco_set', { desiredAutoBloco: next, autoBlocoEnabled: next, desiredState: next ? 'on' : 'off', activeTab: state.activeTab, page: state.activeTab })
        showPopup(next ? 'AT/BL ON' : 'AT/BL OFF', 'success', 750)
        scheduleRender(true)
        break
      }
      case 'play': handlePlay(); break
      case 'autoplay': toggleAutoplay(1); break
      case 'autoplay2': toggleAutoplay(2); break
      case 'tp1': openDirectorTelepromptScreen(); break
      case 'live': toggleLive(); break
      case 'confirm-live-off': confirmLiveOff(); break
      case 'cancel-live-off': state.showConfirmLiveOff = false; scheduleRender(true); break
      case 'timer-open': state.showTimerModal = true; scheduleRender(true); break
      case 'timer-toggle': handleTimerToggle(); break
      case 'timer-stop-confirm': confirmTimerStop(); break
      case 'timer-stop-cancel': state.showConfirmTimerStop = false; scheduleRender(true); break
      case 'timer-mode-countdown': setTimerModeOptimistic('countdown'); postCommand('timer_set_mode', getTimerCommandPayload({ mode: 'countdown', timerMode: 'countdown', timerTargetSec: getCountdownTargetSec(state.snapshot), timerDisplaySec: getCountdownTargetSec(state.snapshot), timerAccumulatedSec: getCountdownTargetSec(state.snapshot) })); break
      case 'timer-mode-progressive': setTimerModeOptimistic('progressive'); postCommand('timer_set_mode', getTimerCommandPayload({ mode: 'progressive', timerMode: 'progressive', timerDisplaySec: 0, timerAccumulatedSec: 0 })); break
      case 'modal-close': { const insideModal = !!event.target?.closest?.('[data-stop-modal]'); const isOverlayAction = !!el.classList?.contains('modalOverlay'); if (insideModal && isOverlayAction) break; if (state.showSettingsModal && !!el.closest?.('.settingsModalBox')) { closeSettingsModalInPlace(); break; } state.showPlaylistModal = false; state.tabletPlaylistPendingId = ''; state.showProjectModal = false; state.showTimerModal = false; state.showSettingsModal = false; state.showTelepromptColorPalette = false; state.showTunerScreen = false; state.showTelepromptScreen = false; if (state.showRecadosScreen) setDirectorRecadosTouchMode(false); state.showRecadosScreen = false; state.showPremixScreen = false; state.showMixerVolume = false; state.showConfirmLiveOff = false; state.showConfirmTimerStop = false; state.mixerVolumeTarget = null; scheduleRender(true); break }
      case 'theme-light': setAppTheme('light'); break
      case 'theme-dark': setAppTheme('dark'); break
      case 'interface-blocking-toggle': {
        const next = !getInterfaceBlockingEnabled()
        state.pendingInterfaceBlocking = next
        state.snapshot = {
          ...(state.snapshot || {}),
          blockInterfaceWhenDirectorConnected: next,
          directorInterfaceBlocked: next,
        }
        postCommand('director_set_interface_blocking', {
          enabled: next,
          blockInterfaceWhenDirectorConnected: next,
        })
        scheduleRender(true)
        break
      }
      case 'interface-access-notification-toggle': {
        state.hideInterfaceAccessNotification =
          !state.hideInterfaceAccessNotification
        writeLocal('vshook_hide_interface_access_notification',
          state.hideInterfaceAccessNotification ? '1' : '0')
        if (state.hideInterfaceAccessNotification) {
          dismissInterfaceAccessButton()
        }
        scheduleRender(true)
        break
      }
      case 'family-view-toggle': {
        const next = !getFamilyViewControlsEnabled()
        state.snapshot = {
          ...(state.snapshot || {}),
          familyViewControlsEnabled: next,
        }
        postCommand('director_family_view_set', {
          enabled: next,
          familyViewControlsEnabled: next,
        })
        scheduleRender(true)
        break
      }
      case 'family-drawer-toggle': {
        const parentId = String(el.getAttribute('data-family-parent-id') || '')
        const itemType = String(el.getAttribute('data-family-item-type') || 'region')
        toggleHashFamilyDrawer(parentId, itemType)
        break
      }
      case 'teleprompt-font-set': setTelepromptFont(el.getAttribute('data-value')); break
      case 'teleprompt-color-set': setTelepromptColor(el.getAttribute('data-value')); break
      case 'teleprompt-colors-more': toggleTelepromptColorPalette(); break
      case 'number-label': toggleNumberColumnMode(); break
      case 'number-sort': toggleNumberSortDirection(); break
      case 'number-order-confirm': confirmNumberOrderChange(); break
      case 'number-order-cancel': closeNumberOrderConfirm(); break
      case 'border-color-mode': toggleBorderColorMode(); break
      case 'play-protection': togglePlayProtection(); break
      case 'auto-stop-toggle': {
        const next = !getAutoStopEnabled()
        state.pendingAutoStop = next
        state.pendingAutoStopUntil = now() + 8000
        postCommand('auto_stop_set', { desiredAutoStop: next, autoStopEnabled: next, autostopEnabled: next, enabled: next, desiredState: next ? 'on' : 'off', activeTab: state.activeTab, page: state.activeTab })
        showPopup(next ? 'AUTO STOP ON' : 'AUTO STOP OFF', 'success', 850)
        scheduleRender(true)
        break
      }
      case 'stop-pause-mode-toggle': {
        const next = !getStopPauseModeEnabled()
        state.pendingStopPauseMode = next
        state.pendingStopPauseModeUntil = now() + 8000
        state.pendingStopPauseModeRequestToken += 1
        commitStopPauseModeToBridge(next, state.pendingStopPauseModeRequestToken, 0)
        scheduleRender(true)
        break
      }
      case 'playlist-multi-toggle': {
        if (!getMultiProjectPlaylistsAvailable()) {
          state.pendingMultiProjectPlaylists = null
          showPopup(
            'ABRA OUTRA SESSÃO COM PELO MENOS UM REPERTÓRIO',
            'error', 1500)
          scheduleRender(true)
          break
        }
        const next = !getMultiProjectPlaylistsEnabled()
        state.pendingMultiProjectPlaylists = next
        postCommand('multi_project_playlists_set', {
          enabled: next,
          desiredState: next,
          multiEnabled: next,
          showAllProjectPlaylists: next,
        })
        const visible = getOpenProjectPlaylists()
        if (!visible.some((playlist, index) =>
          getOpenPlaylistSelectorId(playlist, index) ===
            String(state.tabletPlaylistPendingId || ''))) {
          const active = visible.find((playlist) =>
            playlist?.active === true ||
            playlist?.current === true) || visible[0]
          state.tabletPlaylistPendingId =
            getOpenPlaylistSelectorId(active)
        }
        scheduleRender(true)
        break
      }
      case 'playlist-select': {
        const playlistId = el.getAttribute('data-playlist-id') || ''
        state.tabletPlaylistPendingId = playlistId
        scheduleRender(true)
        break
      }
      case 'tablet-playlist-open': {
        const playlists = getOpenProjectPlaylists()
        const active = playlists.find((playlist) =>
          playlist?.active === true ||
          playlist?.current === true) || null
        const selectorId = String(
          state.tabletPlaylistPendingId ||
          getOpenPlaylistSelectorId(active))
        if (selectorId) openSelectedPlaylist(selectorId)
        break
      }
      case 'tablet-playlist-copy': copyCurrentPlaylistFromModal(); break
      case 'playlist-copy-with-children': copyCurrentPlaylistFromModal(true); break
      case 'playlist-copy-without-children': copyCurrentPlaylistFromModal(false); break
      case 'project-select': {
        const projectId = el.getAttribute('data-project-id') || ''
        const projectIndex = Number(el.getAttribute('data-project-index') || 0)
        postCommand('set_project_tab', { id: projectId, projectId, targetId: projectId, projectIndex, tabIndex: projectIndex })
        break
      }
      case 'project-modal-ok': state.showProjectModal = false; scheduleRender(true); break
      case 'auth-login': login(); break
      case 'toggle-password': state.showPassword = !state.showPassword; scheduleRender(true); break
      case 'marker-cancel': state.selectedMarkerId = ''; state.markerSelectionClearedUntil = now() + 5000; state.partsLocalSelectedMarkerId = ''; state.partsArmedMarkerId = ''; state.partsArmedMarkerUntil = 0; clearPartsArmedOwner(); syncMarkerSelectionDom(); postCommand('marker_cancel', { key: 'ESC', escapeKey: true, activeTab: 'markers', page: 'markers', cancelArmedMarker: true, clearMarkerSelection: true }); scheduleRender(true); break
      case 'parts-song-playing': {
        if (!getPartsSongTarget('playing').available) break
        state.partsMarkerSongSource = 'playing'
        state.partsLocalSelectedMarkerId = ''
        state.partsArmedMarkerId = ''
        state.partsArmedMarkerUntil = 0
        clearPartsArmedOwner()
        scheduleRender(true)
        break
      }
      case 'parts-song-queued': {
        if (!getPartsSongTarget('queued').available) break
        state.partsMarkerSongSource = 'queued'
        state.partsLocalSelectedMarkerId = ''
        state.partsArmedMarkerId = ''
        state.partsArmedMarkerUntil = 0
        clearPartsArmedOwner()
        scheduleRender(true)
        break
      }
      case 'loop': {
        const next = !getLoopActive()
        state.pendingLoop = next
        state.pendingLoopUntil = now() + 5000
        postCommand('loop_toggle', { activeTab: state.activeTab, page: state.activeTab, desiredState: next ? 'on' : 'off', enabled: next, active: next })
        scheduleRender(true)
        break
      }
      case 'multiloop-bypass': {
        const next = !getMultiLoopBypassActive()
        state.pendingMultiLoopBypass = next
        state.pendingMultiLoopBypassUntil = now() + 5000
        if (!next) {
          state.tabletMultiLoopBypassWarningKey = ''
          state.tabletMultiLoopBypassWarningLastPosition = null
        }
        syncTabletMultiLoopBypassDom()
        postCommand('multiloop_bypass_set', {
          enabled: next,
          desiredState: next ? 'on' : 'off',
          activeTab: state.activeTab,
          page: state.activeTab,
        })
        scheduleRender(true)
        break
      }
      case 'mixer-tracks': state.mixerView = 'tracks'; postCommand('mixer_focus', { view: 'tracks', page: state.activeTab }); scheduleRender(true); break
      case 'mixer-groups': state.mixerView = 'groups'; postCommand('mixer_focus', { view: 'groups', page: state.activeTab }); scheduleRender(true); break
      case 'mixer-master': state.mixerView = 'master'; postCommand('mixer_focus', { view: 'master', page: state.activeTab }); scheduleRender(true); break
      case 'mixer-focus': state.mixerView = 'master'; postCommand('mixer_focus', { view: 'master', page: state.activeTab }); scheduleRender(true); break
      case 'mixer-mute': {
        const id = el.getAttribute('data-mixer-id') || ''
        const track = findMixerTrackById(id) || { id }
        const next = !getHeldMixerToggle(track, 'mute')
        setHeldMixerToggle(track, 'mute', next)
        postCommand('mixer_toggle_mute', { id, targetId: id, trackId: id, view: state.mixerView, page: state.activeTab })
        scheduleRender(true)
        break
      }
      case 'mixer-solo': {
        const id = el.getAttribute('data-mixer-id') || ''
        const track = findMixerTrackById(id) || { id }
        const next = !getHeldMixerToggle(track, 'solo')
        setHeldMixerToggle(track, 'solo', next)
        postCommand('mixer_toggle_solo', { id, targetId: id, trackId: id, view: state.mixerView, page: state.activeTab })
        scheduleRender(true)
        break
      }
      case 'mixer-volume-open': state.mixerVolumeTarget = el.getAttribute('data-mixer-id') || ''; state.showMixerVolume = !!state.mixerVolumeTarget; scheduleRender(true); break
      case 'mixer-volume-zero': {
        const id = el.getAttribute('data-mixer-id') || state.mixerVolumeTarget || ''
        const ratio = getMixerZeroDbRatio()
        setHeldMixerVolume(id, ratio)
        postCommand('mixer_set_volume', { id, targetId: id, trackId: id, ratio, view: state.mixerView, page: state.activeTab })
        scheduleRender(true)
        break
      }
      case 'premix-song': state.selectedPremixSongId = el.getAttribute('data-premix-song-id') || ''; postCommand('premix_focus_song', { id: state.selectedPremixSongId, songId: state.selectedPremixSongId, selectedRegionId: state.selectedPremixSongId }); state.premixView = 'tracks'; scheduleRender(true); break
      case 'premix-open': postCommand('premix_item_open', { requestFull: '1', page: state.activeTab }); state.premixView = 'tracks'; scheduleRender(true); break
      case 'premix-global': state.selectedPremixSongId = '__GLOBAL__'; postCommand('premix_global_focus', { id: '__GLOBAL__', songId: '__GLOBAL__', global: true, isGlobal: true }); state.premixView = 'tracks'; scheduleRender(true); break
      case 'premix-toggle': postCommand('premix_toggle_enabled', { id: state.selectedPremixSongId, songId: state.selectedPremixSongId, selectedRegionId: state.selectedPremixSongId }); break
      case 'premix-back-songs': state.premixView = 'songs'; scheduleRender(true); break
      case 'premix-tracks': state.premixTrackView = 'tracks'; scheduleRender(true); break
      case 'premix-groups': state.premixTrackView = 'groups'; scheduleRender(true); break
      case 'premix-mute': postCommand('premix_toggle_mute', { id: state.selectedPremixSongId, songId: state.selectedPremixSongId, targetId: el.getAttribute('data-premix-track-id'), trackId: el.getAttribute('data-premix-track-id'), view: state.premixTrackView }); break
      case 'premix-fx': postCommand('premix_toggle_fx', { id: state.selectedPremixSongId, songId: state.selectedPremixSongId, targetId: el.getAttribute('data-premix-track-id'), trackId: el.getAttribute('data-premix-track-id'), view: state.premixTrackView }); break
      case 'premix-screen-close': closePremixFullScreen(); break
      case 'premix-screen-transport':
        if (isPlaying(state.snapshot || {})) pausePremixTransport()
        else if (isPaused(state.snapshot || {})) postCommand('director_play_no_seek', { ...getPremixTargetPayload(), noSeek: true, preserveCursor: true, transportOnly: true })
        else playPremixTarget()
        break
      case 'premix-family-song': {
        const id = String(el.getAttribute('data-premix-family-song-id') || '')
        const name = String(el.getAttribute('data-premix-family-song-name') || '')
        const start = Number(el.getAttribute('data-premix-family-song-start')) || 0
        const end = Number(el.getAttribute('data-premix-family-song-end')) || 0
        const markerNumber = Number(el.getAttribute('data-premix-family-marker-number')) || 0
        const markerEnumIndexRaw = Number(el.getAttribute('data-premix-family-marker-enum-index'))
        const markerEnumIndex = Number.isFinite(markerEnumIndexRaw) ? markerEnumIndexRaw : -1
        if (!id) break
        state.premixPlaySongId = id
        state.premixPlaySongName = name
        state.premixPlaySongStart = start
        state.premixPlaySongEnd = end
        state.premixPlayMarkerNumber = markerNumber
        state.premixPlayMarkerEnumIndex = markerEnumIndex
        state.selectedRegionId = id
        state.selectedPlaylistSongId = ''
        state.regionSelectionClearedUntil = 0
        state.playlistSelectionClearedUntil = now() + 5000
        postCommand('select_region', {
          id,
          targetId: id,
          songId: id,
          selectedRegionId: id,
          startPos: start,
          endPos: end,
          selectedStartPos: start,
          selectedEndPos: end,
          exactPosition: true,
          useExplicitPosition: true,
          seekToMarker: true,
          seekTarget: 'marker',
          markerNumber,
          sourceNumber: markerNumber,
          markerEnumIndex,
          activeTab: 'regions',
          page: 'regions',
        })
        scheduleRender(true)
        break
      }
      case 'premix-item-mute': {
        const id = String(el.getAttribute('data-premix-item-id') || '')
        if (!id) break
        const item = getPremixAllItemRows().find((candidate) => getPremixItemId(candidate) === id) || { id }
        const next = !getPremixItemMute(item)
        setPremixItemMute(id, next)
        el.classList.toggle('premixFullMuteActive', next)
        el.setAttribute('aria-pressed', next ? 'true' : 'false')
        postCommand('premix_item_toggle_mute', { ...getPremixTargetPayload(), itemId: id, mediaItemId: id, targetId: id, desiredMute: next, muted: next })
        break
      }
      case 'exit-app': if (typeof window.vshookExitToProjectSelector === 'function') window.vshookExitToProjectSelector(); else window.location.reload(); break
      case 'select-item': handleItemSelect(el); break
      default: break
    }
  }

  function handleRangeInput(event) {
    const el = event.target
    if (!el) return
    if (el.getAttribute('data-action') === 'tablet-multiloop-auto-limit') {
      const target = state.tabletMultiLoopAutoLimitTarget
      if (!target) return
      const valueDb = clampMultiLoopAutoLimitDb(el.value, target.baseDb)
      target.valueDb = valueDb
      const data = getTabletMultiLoopsState()
      const track = Array.isArray(data.tracks) ? data.tracks.find((row) => String(row?.guid ?? row?.id ?? '') === target.id) : null
      if (track) {
        track[`autoLimit${target.slot}Set`] = true
        track[`autoLimit${target.slot}Db`] = valueDb
      }
      const targetLabel = root.querySelector('[data-auto-limit-target]')
      if (targetLabel) targetLabel.textContent = `DESTINO DO FADE: ${formatMultiLoopAutoLimitDb(valueDb)}`
      queueMultiLoopAutoLimitCommand(target)
      return
    }
    if (el.getAttribute('data-action') === 'premix-item-volume') {
      const ratio = Number(el.value)
      const id = String(el.getAttribute('data-premix-item-id') || '')
      if (!id) return
      setPremixItemRatio(id, ratio)
      const db = mixerRatioToDb(ratio)
      const label = el.closest('.premixFullSliderWrap')?.querySelector('.premixFullDb')
      if (label) label.textContent = Number.isFinite(db) ? `${Math.abs(db) < 0.05 ? '0.0' : `${db >= 0 ? '+' : ''}${db.toFixed(1)}`} dB` : '-Inf dB'
      postCommand('premix_item_set_volume', { ...getPremixTargetPayload(), itemId: id, mediaItemId: id, targetId: id, ratio, volumeRatio: ratio })
      return
    }
    if (el.getAttribute('data-action') === 'premix-volume') {
      const ratio = Number(el.value)
      const id = el.getAttribute('data-premix-track-id') || ''
      postCommand('premix_set_volume', { id: state.selectedPremixSongId, songId: state.selectedPremixSongId, selectedRegionId: state.selectedPremixSongId, targetId: id, trackId: id, ratio, view: state.premixTrackView })
      return
    }
    if (el.getAttribute('data-action') === 'mixer-volume') {
      const ratio = Number(el.value)
      const id = el.getAttribute('data-mixer-id') || state.mixerVolumeTarget || ''
      setHeldMixerVolume(id, ratio)
      const track = findMixerTrackById(id) || { id, volumeRatio: ratio }
      const dbDisplay = root.querySelector('.mixerVolumeDbDisplay')
      if (dbDisplay) dbDisplay.textContent = formatMixerDb({ ...track, volumeRatio: ratio })
      const rowDb = root.querySelector(`[data-mixer-id="${CSS.escape(String(id))}"] .mixerRowDb`)
      if (rowDb) rowDb.textContent = formatMixerDb({ ...track, volumeRatio: ratio })
      postCommand('mixer_set_volume', { id, targetId: id, trackId: id, ratio, view: state.mixerView, page: state.activeTab })
    }
  }

  function isDuplicateTap(key) {
    const t = now()
    if (state.lastTapKey === key && (t - state.lastTapAt) < TAP_DEDUPE_MS) return true
    state.lastTapKey = key
    state.lastTapAt = t
    return false
  }

  function toggleHashFamilyDrawer(parentKey, itemType) {
    if (!parentKey) return
    if (state.hashRegionDrawers[parentKey]) {
      state.hashRegionDrawers[parentKey] = false
      if (state.hashRegionDrawerPendingId === parentKey) state.hashRegionDrawerPendingId = ''
    } else if (Array.isArray(state.hashRegionDrawerChildren[parentKey])) {
      state.hashRegionDrawers[parentKey] = true
    } else {
      state.hashRegionDrawers[parentKey] = true
      state.hashRegionDrawerPendingId = ''
      buildHashDrawerChildren(parentKey, itemType, state.snapshot)
    }
    persistDirectorPanelState()
    scheduleRender(true)
  }

  function onTap(event) {
    if (transportHoldConsumesTouch) return
    if (now() < state.ignoreTapUntil) return
    const el = event.target?.closest?.('[data-action]')
    if (!el) return
    const action = el.getAttribute('data-action') || ''

    const key = `${action}:${el.getAttribute('data-song-id') || el.getAttribute('data-region-id') || el.getAttribute('data-marker-id') || el.getAttribute('data-mixer-id') || el.getAttribute('data-premix-song-id') || el.getAttribute('data-premix-track-id') || el.getAttribute('data-premix-item-id') || el.getAttribute('data-tuner-song-id') || el.getAttribute('data-track-id') || el.getAttribute('data-search-id') || el.getAttribute('data-song-tool') || el.getAttribute('data-preview-slot') || el.getAttribute('data-slot') || ''}`
    const protectedTransportAction = getPlayProtectionEnabled() && (action === 'play' || action === 'stop-break')
    if (!protectedTransportAction && isDuplicateTap(key)) return
    event.preventDefault?.()
    event.stopPropagation?.()
    handleAction(action, el, event)
  }

  let premixHoldTimer = 0
  let premixHoldPointerId = null
  let premixHoldStartX = 0
  let premixHoldStartY = 0
  let premixHoldRow = null
  let premixHoldTriggered = false
  let premixHoldReady = false

  function cancelPremixHold() {
    if (premixHoldTimer) window.clearTimeout(premixHoldTimer)
    premixHoldTimer = 0
    premixHoldPointerId = null
    premixHoldRow = null
    premixHoldReady = false
  }

  function handlePremixHoldStart(event) {
    if (IS_MUSICIAN_MONITOR) return
    if (state.showPremixScreen || state.showTabletSongToolsModal || state.showTabletMultiLoopsModal || state.showTabletLiveResetConfirm || state.showMarkersOverlay || state.showTunerScreen || state.showTelepromptScreen ||
        state.showPlaylistModal || state.showProjectModal || state.showTimerModal || state.showSettingsModal || state.showMixerVolume) return
    if (event.pointerType === 'mouse' && event.button !== 0) return
    const row = event.target?.closest?.('.listBox .item[data-action="select-item"]')
    if (!row || row.getAttribute('data-is-block') === '1') return
    const type = row.getAttribute('data-item-type')
    if (type !== 'playlist' && type !== 'region') return
    cancelPremixHold()
    premixHoldPointerId = event.pointerId
    premixHoldStartX = Number(event.clientX) || 0
    premixHoldStartY = Number(event.clientY) || 0
    premixHoldRow = row
    premixHoldTriggered = false
    premixHoldReady = false
    premixHoldTimer = window.setTimeout(() => {
      const target = premixHoldRow
      premixHoldTimer = 0
      if (!target) return
      if (document.documentElement.dataset.directorDevice === 'tablet') {
        premixHoldTriggered = openTabletSongToolsForRow(target)
        premixHoldReady = false
        if (premixHoldTriggered) {
          state.ignoreTapUntil = now() + 700
          try { navigator.vibrate?.(20) } catch (_) {}
        }
        return
      }
      // Celular e tablet compartilham o mesmo seletor e as mesmas regras de
      // Reset Live. Regiao-pai oferece Premix + Reset; as demais tambem têm
      // Multiloops.
      premixHoldTriggered = openTabletSongToolsForRow(target)
      if (premixHoldTriggered) {
        state.ignoreTapUntil = now() + 700
        try { navigator.vibrate?.(35) } catch (_) {}
      }
    }, 650)
  }

  function handlePremixHoldMove(event) {
    if (premixHoldPointerId === null || event.pointerId !== premixHoldPointerId || (!premixHoldTimer && !premixHoldReady)) return
    const dx = (Number(event.clientX) || 0) - premixHoldStartX
    const dy = (Number(event.clientY) || 0) - premixHoldStartY
    if (Math.hypot(dx, dy) > 14) cancelPremixHold()
  }

  function handlePremixHoldEnd(event) {
    if (premixHoldPointerId !== null && event.pointerId === premixHoldPointerId) {
      if (premixHoldTriggered) state.ignoreTapUntil = now() + 500
      cancelPremixHold()
      premixHoldTriggered = false
    }
  }

  let multiLoopMsHoldTimer = 0
  let multiLoopMsHoldPointerId = null
  let multiLoopMsHoldSlot = 0
  let multiLoopMsHoldTriggered = false

  function cancelMultiLoopMsHold() {
    if (multiLoopMsHoldTimer) window.clearTimeout(multiLoopMsHoldTimer)
    multiLoopMsHoldTimer = 0
    multiLoopMsHoldPointerId = null
    multiLoopMsHoldSlot = 0
  }

  function handleMultiLoopMsHold(event) {
    if (event.type === 'pointerdown') {
      const button = event.target?.closest?.('[data-action="tablet-multiloop-ms"]')
      if (!button || button.disabled || (event.pointerType === 'mouse' && event.button !== 0)) return
      const requestedSlot = Math.max(1, Math.min(2, Number(button.getAttribute('data-slot')) || 1))
      if (getTabletMultiLoopsState()[`loop${requestedSlot}Enabled`] !== true) return
      cancelMultiLoopMsHold()
      multiLoopMsHoldPointerId = event.pointerId
      multiLoopMsHoldSlot = requestedSlot
      multiLoopMsHoldTriggered = false
      multiLoopMsHoldTimer = window.setTimeout(() => {
        multiLoopMsHoldTimer = 0
        multiLoopMsHoldTriggered = true
        state.tabletMultiLoopTracksSlot = multiLoopMsHoldSlot
        state.ignoreTapUntil = now() + 500
        try { navigator.vibrate?.(25) } catch (_) {}
        scheduleRender(true)
      }, 650)
      return
    }
    if (multiLoopMsHoldPointerId === null || event.pointerId !== multiLoopMsHoldPointerId) return
    if (event.type === 'pointerup' || event.type === 'pointercancel') {
      cancelMultiLoopMsHold()
      if (multiLoopMsHoldTriggered) state.ignoreTapUntil = now() + 500
      multiLoopMsHoldTriggered = false
    }
  }

  let multiLoopAutoHoldTimer = 0
  let multiLoopAutoHoldPointerId = null
  let multiLoopAutoHoldStartX = 0
  let multiLoopAutoHoldStartY = 0
  let multiLoopAutoHoldTriggered = false

  function cancelMultiLoopAutoHold() {
    if (multiLoopAutoHoldTimer) window.clearTimeout(multiLoopAutoHoldTimer)
    multiLoopAutoHoldTimer = 0
    multiLoopAutoHoldPointerId = null
  }

  function handleMultiLoopAutoHold(event) {
    if (event.type === 'pointerdown') {
      const button = event.target?.closest?.('[data-action="tablet-multiloop-track"][data-mode="auto"]')
      if (!button || button.disabled || (event.pointerType === 'mouse' && event.button !== 0)) return
      cancelMultiLoopAutoHold()
      multiLoopAutoHoldPointerId = event.pointerId
      multiLoopAutoHoldStartX = Number(event.clientX) || 0
      multiLoopAutoHoldStartY = Number(event.clientY) || 0
      multiLoopAutoHoldTriggered = false
      const slot = Math.max(1, Math.min(2, Number(button.getAttribute('data-slot')) || 1))
      const id = String(button.getAttribute('data-track-id') || '')
      const name = String(button.getAttribute('data-track-name') || 'PISTA')
      multiLoopAutoHoldTimer = window.setTimeout(() => {
        multiLoopAutoHoldTimer = 0
        rememberTabletMultiLoopTracksScroll(button.closest('.tabletMultiLoopTracksModal')?.querySelector('.tabletMultiLoopTracksList'))
        const data = getTabletMultiLoopsState()
        const track = Array.isArray(data.tracks) ? data.tracks.find((row) => String(row?.guid ?? row?.id ?? '') === id) : null
        if (!track || !id) return
        const saved = track[`autoLimit${slot}Set`] === true && Number.isFinite(Number(track[`autoLimit${slot}Db`]))
        const baseDb = Number.isFinite(Number(track.volumeDb)) ? Number(track.volumeDb) : 0
        state.tabletMultiLoopAutoLimitTarget = {
          slot,
          id,
          name,
          baseDb,
          valueDb: saved ? clampMultiLoopAutoLimitDb(track[`autoLimit${slot}Db`], baseDb) : -90,
        }
        multiLoopAutoHoldTriggered = true
        state.ignoreTapUntil = now() + 500
        try { navigator.vibrate?.(25) } catch (_) {}
        scheduleRender(true)
      }, 650)
      return
    }
    if (multiLoopAutoHoldPointerId === null || event.pointerId !== multiLoopAutoHoldPointerId) return
    if (event.type === 'pointermove') {
      const dx = (Number(event.clientX) || 0) - multiLoopAutoHoldStartX
      const dy = (Number(event.clientY) || 0) - multiLoopAutoHoldStartY
      if (Math.hypot(dx, dy) > 12) cancelMultiLoopAutoHold()
      return
    }
    if (event.type === 'pointerup' || event.type === 'pointercancel') {
      cancelMultiLoopAutoHold()
      if (multiLoopAutoHoldTriggered) state.ignoreTapUntil = now() + 500
      multiLoopAutoHoldTriggered = false
    }
  }


  let transportSeekHoldTimer = 0
  let transportSeekHoldPointerId = null
  let transportSeekHoldStartX = 0
  let transportSeekHoldStartY = 0
  let transportSeekHoldTriggered = false
  let transportHoldConsumesTouch = false

  function cancelTransportSeekHold() {
    if (transportSeekHoldTimer) window.clearTimeout(transportSeekHoldTimer)
    transportSeekHoldTimer = 0
    transportSeekHoldPointerId = null
  }

  function startTransportSeekHold(origin, inputId, clientX, clientY) {
    if (IS_MUSICIAN_MONITOR) return
    if (root.querySelector('.modalOverlay')) return
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet'
    const visibleTransportSeek = !!root.querySelector('.transportSeekOverlay,.tabletTransportPanel')
    if (state.showTransportSeekModal && !visibleTransportSeek) {
      state.showTransportSeekModal = false
      state.transportSeekExplicitTarget = false
      persistDirectorPanelState()
    }
    if ((!tabletMode && state.showTransportSeekModal) || state.showRecadosScreen || state.showMixerVolume || state.showTimerModal || state.showSettingsModal || state.showPlaylistModal || state.showProjectModal) return
    const premixChild = origin?.closest?.('.transportSeekPremixChildTarget')
    const transportPanel = origin?.closest?.('.transportSeekHoldTarget')
    if (!premixChild && !transportPanel) return
    if (!premixChild && origin?.closest?.('button,[data-action]')) return
    cancelTransportSeekHold()
    transportSeekHoldPointerId = inputId
    transportSeekHoldStartX = Number(clientX) || 0
    transportSeekHoldStartY = Number(clientY) || 0
    transportSeekHoldTriggered = false
    let explicitTarget = null
    if (premixChild) {
      const id = String(premixChild.getAttribute('data-premix-family-song-id') || '')
      const name = String(premixChild.getAttribute('data-premix-family-song-name') || 'MÚSICA')
      const start = Number(premixChild.getAttribute('data-premix-family-song-start'))
      const end = Number(premixChild.getAttribute('data-premix-family-song-end'))
      const displayDuration = Number(premixChild.getAttribute('data-premix-family-song-duration'))
      const markerNumber = Number(premixChild.getAttribute('data-premix-family-marker-number'))
      const markerEnumIndex = Number(premixChild.getAttribute('data-premix-family-marker-enum-index'))
      explicitTarget = makeTransportSeekTarget(null, { id, name, start, end, displayDuration, markerNumber, markerEnumIndex, tab: 'regions', source: 'premix-child', exactPosition: true })
    }
    transportSeekHoldTimer = window.setTimeout(() => {
      transportSeekHoldTimer = 0
      if (tabletMode && state.showTransportSeekModal) {
        closeTransportSeekModal(false)
        mountTransportSeekModalDom()
        transportSeekHoldTriggered = true
      } else {
        transportSeekHoldTriggered = openTransportSeekModal(explicitTarget, false)
        if (transportSeekHoldTriggered) mountTransportSeekModalDom()
      }
      if (transportSeekHoldTriggered) {
        transportHoldConsumesTouch = true
        // Permanece bloqueado enquanto o dedo estiver abaixado. O touchend
        // troca este prazo por uma janela curta antes de liberar os cliques.
        state.ignoreTapUntil = now() + 60000
        try { navigator.vibrate?.(35) } catch (_) {}
      }
    }, 1000)
    return true
  }

  function performTransportSwipe(dx, dy, elapsed, event) {
    if (elapsed > 1800) return false
    if (Math.abs(dx) < 28 || Math.abs(dx) < Math.abs(dy) * 0.8) return false
    state.ignoreTapUntil = now() + 320
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet' && !IS_MUSICIAN_MONITOR
    if (tabletMode) {
      if (state.showTelepromptScreen) {
        if (dx < 0) closeDirectorTelepromptScreen()
      } else if (state.tabletPartsSplit) {
        if (dx > 0) {
          state.tabletPartsSplit = false
          persistDirectorPanelState()
          scheduleRender(true)
        }
      } else if (dx < 0) {
        state.tabletPartsSplit = true
        state.tabletTunerSplit = false
        persistDirectorPanelState()
        scheduleRender(true)
      } else if (dx > 0) {
        openDirectorTelepromptScreen()
      }
    } else if (IS_MUSICIAN_MONITOR) {
      if (state.showTelepromptScreen) {
        if (dx < 0) closeDirectorTelepromptScreen()
      } else if (dx > 0) {
        openDirectorTelepromptScreen()
      }
    } else if (state.showTelepromptScreen) {
      if (dx < 0) closeDirectorTelepromptScreen()
    } else if (state.showMarkersOverlay) {
      if (dx > 0) closeMarkersOverlay()
    } else if (state.activeTab === 'playlist') {
      if (dx < 0) openMarkersOverlay()
      else if (dx > 0) openDirectorTelepromptScreen()
    } else if (state.activeTab === 'regions') {
      if (dx < 0) openMarkersOverlay()
      else if (dx > 0) openDirectorTelepromptScreen()
    }
    event.preventDefault?.()
    return true
  }

  let transportTouchId = null
  let transportTouchStartX = 0
  let transportTouchStartY = 0
  let transportTouchLastX = 0
  let transportTouchLastY = 0
  let transportTouchStartAt = 0
  let transportTouchCanSwipe = false
  let transportTouchSwipeTriggered = false

  function findTransportTouch(list, identifier) {
    if (!list) return null
    for (let index = 0; index < list.length; index += 1) {
      if (identifier === null || list[index].identifier === identifier) return list[index]
    }
    return null
  }

  function getTransportTouchDelta(clientX, clientY) {
    const physicalX = (Number(clientX) || 0) - transportTouchStartX
    const physicalY = (Number(clientY) || 0) - transportTouchStartY
    const rotatedTablet = document.documentElement.dataset.directorDevice === 'tablet'
      && window.matchMedia?.('(orientation: portrait)')?.matches
    return {
      dx: rotatedTablet ? physicalY : physicalX,
      dy: rotatedTablet ? -physicalX : physicalY,
    }
  }

  function resetTransportTouchGesture() {
    transportTouchId = null
    transportTouchStartAt = 0
    transportTouchCanSwipe = false
    transportTouchSwipeTriggered = false
  }

  function findTransportGestureTarget(clientX, clientY, eventTarget) {
    const direct = eventTarget instanceof Element ? eventTarget : null
    if (direct?.closest?.('.modalOverlay,[data-stop-modal]')) return null
    const directPremix = direct?.closest?.('.transportSeekPremixChildTarget') || null
    const directPanel = direct?.closest?.('.playbackQueueHeader') || null
    if (directPremix) return { origin: directPremix, transportPanel: null, premixChild: directPremix }
    if (directPanel && !direct?.closest?.('button,[data-action]')) {
      return { origin: directPanel, transportPanel: directPanel, premixChild: null }
    }

    const x = Number(clientX)
    const y = Number(clientY)
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null
    const candidates = document.querySelectorAll('.transportSeekPremixChildTarget,.playbackQueueHeader')
    for (let index = candidates.length - 1; index >= 0; index -= 1) {
      const candidate = candidates[index]
      const rect = candidate.getBoundingClientRect?.()
      if (!rect || rect.width <= 0 || rect.height <= 0) continue
      if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue
      const premixChild = candidate.matches?.('.transportSeekPremixChildTarget') ? candidate : null
      const transportPanel = candidate.matches?.('.playbackQueueHeader') ? candidate : null
      return { origin: candidate, transportPanel, premixChild }
    }
    return null
  }

  function handleTransportTouchStart(event) {
    if (transportTouchId !== null || !event.touches || event.touches.length !== 1) return
    const touch = event.touches[0]
    const target = findTransportGestureTarget(touch.clientX, touch.clientY, event.target)
    if (!target) return
    const origin = target.origin
    const transportPanel = target.transportPanel
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet' && !IS_MUSICIAN_MONITOR
    const visibleTransportSeek = !!root.querySelector('.transportSeekOverlay,.tabletTransportPanel')
    if (state.showPlaylistModal || state.showProjectModal || state.showTimerModal || state.showSettingsModal || state.showTunerScreen || state.showRecadosScreen || (!tabletMode && state.showTransportSeekModal && visibleTransportSeek) || state.showMixerVolume) return
    if (transportPanel && state.showPremixScreen) return

    transportTouchId = touch.identifier
    transportTouchStartX = Number(touch.clientX) || 0
    transportTouchStartY = Number(touch.clientY) || 0
    transportTouchLastX = transportTouchStartX
    transportTouchLastY = transportTouchStartY
    transportTouchStartAt = now()
    transportTouchCanSwipe = !!transportPanel
    transportTouchSwipeTriggered = false
    startTransportSeekHold(origin, `touch-${touch.identifier}`, transportTouchStartX, transportTouchStartY)
  }

  function handleTransportTouchMove(event) {
    if (transportTouchId === null) return
    if (transportHoldConsumesTouch) {
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }
    const touch = findTransportTouch(event.touches, transportTouchId)
    if (!touch) return
    transportTouchLastX = Number(touch.clientX) || 0
    transportTouchLastY = Number(touch.clientY) || 0
    const physicalX = transportTouchLastX - transportTouchStartX
    const physicalY = transportTouchLastY - transportTouchStartY
    if (Math.hypot(physicalX, physicalY) > 14) cancelTransportSeekHold()
    if (!transportTouchCanSwipe) return
    const delta = getTransportTouchDelta(transportTouchLastX, transportTouchLastY)
    const horizontal = Math.abs(delta.dx) > 10 && Math.abs(delta.dx) > Math.abs(delta.dy)
    if (horizontal) event.preventDefault()
    if (!transportTouchSwipeTriggered && horizontal && Math.abs(delta.dx) >= 28) {
      transportTouchSwipeTriggered = performTransportSwipe(delta.dx, delta.dy, now() - transportTouchStartAt, event)
      if (transportTouchSwipeTriggered) {
        // A ação redesenha a interface antes de o navegador necessariamente
        // entregar touchend/touchcancel. Libera já este gesto para o próximo
        // swipe conseguir abrir a tela que acabou de ser fechada.
        cancelTransportSeekHold()
        transportSeekHoldTriggered = false
        resetTransportTouchGesture()
      }
    }
  }

  function finishTransportTouch(event, cancelled = false) {
    if (transportTouchId === null) return
    const touch = findTransportTouch(event.changedTouches, transportTouchId)
      || findTransportTouch(event.touches, transportTouchId)
    if (touch) {
      transportTouchLastX = Number(touch.clientX) || 0
      transportTouchLastY = Number(touch.clientY) || 0
    }
    const elapsed = transportTouchStartAt ? now() - transportTouchStartAt : 0
    const canSwipe = transportTouchCanSwipe
    const swipeTriggered = transportTouchSwipeTriggered
    const holdTriggered = transportSeekHoldTriggered || transportHoldConsumesTouch
    const delta = getTransportTouchDelta(transportTouchLastX, transportTouchLastY)
    cancelTransportSeekHold()
    transportSeekHoldTriggered = false
    transportHoldConsumesTouch = false
    resetTransportTouchGesture()
    if (!cancelled && !holdTriggered && !swipeTriggered && canSwipe) performTransportSwipe(delta.dx, delta.dy, elapsed, event)
    else if (holdTriggered) {
      state.ignoreTapUntil = now() + 800
      event.preventDefault?.()
      event.stopImmediatePropagation?.()
    }
  }

  function handleTransportTouchEnd(event) {
    finishTransportTouch(event, false)
  }

  function handleTransportTouchCancel(event) {
    // WebKit e alguns WebViews encerram um swipe válido como touchcancel.
    // finishTransportTouch lê changedTouches antes de validar o deslocamento.
    finishTransportTouch(event, false)
  }

  function preventAppZoom() {
    const viewport = document.querySelector('meta[name="viewport"]')
    if (viewport) {
      viewport.setAttribute('content', 'width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover')
    }
    document.documentElement.style.touchAction = 'manipulation'
    document.body.style.touchAction = 'manipulation'
    let lastTouchEndAt = 0
    document.addEventListener('dblclick', (event) => event.preventDefault(), { passive: false })
    document.addEventListener('gesturestart', (event) => event.preventDefault(), { passive: false })
    document.addEventListener('gesturechange', (event) => event.preventDefault(), { passive: false })
    document.addEventListener('gestureend', (event) => event.preventDefault(), { passive: false })
    document.addEventListener('wheel', (event) => {
      if (event.ctrlKey || event.metaKey) event.preventDefault()
    }, { passive: false })
    document.addEventListener('touchmove', (event) => {
      if (event.touches && event.touches.length > 1) event.preventDefault()
    }, { passive: false })
    document.addEventListener('keydown', (event) => {
      if (!(event.ctrlKey || event.metaKey)) return
      const key = String(event.key || '').toLowerCase()
      if (key === '+' || key === '=' || key === '-' || key === '_' || key === '0') event.preventDefault()
    }, { passive: false })
    document.addEventListener('touchend', (event) => {
      if (state.showRecadosScreen && event.target?.closest?.('.directorRecadosRoot')) {
        lastTouchEndAt = 0
        return
      }
      const t = now()
      if (t - lastTouchEndAt <= 320) event.preventDefault()
      lastTouchEndAt = t
    }, { passive: false })
  }

  function handleAuthFieldPointerDown(event) {
    const wrap = event.target?.closest?.('.authGatePassWrap')
    if (!wrap || event.target?.closest?.('.authGatePassToggle')) return
    focusDirectorPasswordInput()
  }

  function handleMenuOutsidePointerUp(event) {
    if (!state.showMenu) return
    const target = event.target instanceof Element ? event.target : null
    if (target?.closest?.('.topMenuFlyout, .topMenuBtn')) return
    state.showMenu = false
    scheduleRender(true)
  }

  let playlistScrollPointerId = null
  let playlistScrollStartX = 0
  let playlistScrollStartY = 0
  let playlistScrollMoved = false

  function handlePlaylistScrollGesture(event) {
    if (event.type === 'pointerdown') {
      if (!event.target?.closest?.('.playlistModalBox .playlistSelectList, .settingsModalBox')) return
      playlistScrollPointerId = event.pointerId
      playlistScrollStartX = Number(event.clientX) || 0
      playlistScrollStartY = Number(event.clientY) || 0
      playlistScrollMoved = false
      return
    }
    if (playlistScrollPointerId === null || event.pointerId !== playlistScrollPointerId) return
    if (event.type === 'pointermove') {
      const dx = (Number(event.clientX) || 0) - playlistScrollStartX
      const dy = (Number(event.clientY) || 0) - playlistScrollStartY
      if (Math.hypot(dx, dy) > 7) {
        playlistScrollMoved = true
        state.ignoreTapUntil = now() + 500
      }
      return
    }
    if (playlistScrollMoved) state.ignoreTapUntil = now() + 500
    playlistScrollPointerId = null
    playlistScrollMoved = false
  }

  let tabletPlayHoldTimer = 0
  let tabletPlayHoldPointerId = null
  let tabletPlayHoldStartX = 0
  let tabletPlayHoldStartY = 0
  let tabletPlayHoldTriggered = false

  function cancelTabletPlayHold() {
    if (tabletPlayHoldTimer) window.clearTimeout(tabletPlayHoldTimer)
    tabletPlayHoldTimer = 0
    tabletPlayHoldPointerId = null
  }

  function handleTabletPlayHold(event) {
    if (event.type === 'pointerdown') {
      const button = event.target?.closest?.('[data-action="play"]')
      if (!button || (event.pointerType === 'mouse' && event.button !== 0)) return
      cancelTabletPlayHold()
      tabletPlayHoldPointerId = event.pointerId
      tabletPlayHoldStartX = Number(event.clientX) || 0
      tabletPlayHoldStartY = Number(event.clientY) || 0
      tabletPlayHoldTriggered = false
      tabletPlayHoldTimer = window.setTimeout(() => {
        tabletPlayHoldTimer = 0
        tabletPlayHoldTriggered = true
        state.showTabletPlayHoldModal = true
        state.ignoreTapUntil = now() + 700
        try { navigator.vibrate?.(35) } catch (_) {}
        mountTabletPlayHoldModal()
      }, 800)
      return
    }
    if (tabletPlayHoldPointerId === null || event.pointerId !== tabletPlayHoldPointerId) return
    if (event.type === 'pointermove') {
      const dx = (Number(event.clientX) || 0) - tabletPlayHoldStartX
      const dy = (Number(event.clientY) || 0) - tabletPlayHoldStartY
      if (Math.hypot(dx, dy) > 12) cancelTabletPlayHold()
      return
    }
    if (tabletPlayHoldTriggered) state.ignoreTapUntil = now() + 500
    cancelTabletPlayHold()
    tabletPlayHoldTriggered = false
  }

  let tabletPreviewHoldTimer = 0
  let tabletPreviewHoldPointerId = null
  let tabletPreviewHoldStartX = 0
  let tabletPreviewHoldStartY = 0
  let tabletPreviewHoldTriggered = false

  function cancelTabletPreviewHold() {
    if (tabletPreviewHoldTimer) window.clearTimeout(tabletPreviewHoldTimer)
    tabletPreviewHoldTimer = 0
    tabletPreviewHoldPointerId = null
  }

  function handleTabletPreviewHold(event) {
    if (IS_MUSICIAN_MONITOR || document.documentElement.dataset.directorDevice !== 'tablet') return
    if (event.type === 'pointerdown') {
      const button = event.target?.closest?.('[data-action="tablet-preview"]')
      if (!button || (event.pointerType === 'mouse' && event.button !== 0)) return
      cancelTabletPreviewHold()
      tabletPreviewHoldPointerId = event.pointerId
      tabletPreviewHoldStartX = Number(event.clientX) || 0
      tabletPreviewHoldStartY = Number(event.clientY) || 0
      tabletPreviewHoldTriggered = false
      tabletPreviewHoldTimer = window.setTimeout(() => {
        tabletPreviewHoldTimer = 0
        tabletPreviewHoldTriggered = true
        const previewMode = getPreviewMode()
        const currentPage =
          state.tabletPreviewPage === 2 ||
          (state.tabletPreviewPage === 0 && previewMode >= 4)
            ? 2 : 1
        state.tabletPreviewPage = currentPage === 1 ? 2 : 1
        state.ignoreTapUntil = now() + 700
        try { navigator.vibrate?.(35) } catch (_) {}
        scheduleRender(true)
      }, 650)
      return
    }
    if (tabletPreviewHoldPointerId === null || event.pointerId !== tabletPreviewHoldPointerId) return
    if (event.type === 'pointermove') {
      const dx = (Number(event.clientX) || 0) - tabletPreviewHoldStartX
      const dy = (Number(event.clientY) || 0) - tabletPreviewHoldStartY
      if (Math.hypot(dx, dy) > 10) cancelTabletPreviewHold()
      return
    }
    if (tabletPreviewHoldTriggered) state.ignoreTapUntil = now() + 500
    cancelTabletPreviewHold()
    tabletPreviewHoldTriggered = false
  }

  let directorRecadosHoldTimer = 0
  let directorRecadosHoldPointerId = null

  function handleDirectorRecadosHoldStart(event) {
    const button = event.target?.closest?.('[data-action="recados-select-slot"]')
    if (!button || (event.pointerType === 'mouse' && event.button !== 0)) return
    if (directorRecadosHoldTimer) window.clearTimeout(directorRecadosHoldTimer)
    directorRecadosHoldPointerId = event.pointerId
    directorRecadosHoldTimer = window.setTimeout(() => {
      directorRecadosHoldTimer = 0
      selectDirectorRecadosSlot(button.getAttribute('data-recados-slot'))
      state.ignoreTapUntil = now() + 500
      try { navigator.vibrate?.(35) } catch (_) {}
    }, 1000)
  }

  function handleDirectorRecadosHoldEnd(event) {
    if (directorRecadosHoldPointerId !== event.pointerId) return
    if (directorRecadosHoldTimer) window.clearTimeout(directorRecadosHoldTimer)
    directorRecadosHoldTimer = 0
    directorRecadosHoldPointerId = null
  }

  function normalizeTimerCountdownInput(input, options = {}) {
    if (!input?.matches?.('[data-timer-countdown-input]')) return
    let digits = String(input.value || '').replace(/\D/g, '')
    if (digits.length > 2) digits = digits.slice(-2)
    const max = Math.max(0, Number(input.getAttribute('data-timer-max') || 99))
    if (options.commit) {
      const value = Math.min(max, Math.max(0, Number(digits || 0)))
      digits = String(value).padStart(2, '0')
    }
    input.value = digits
  }

  function handleTimerCountdownBeforeInput(event) {
    const input = event.target
    if (!input?.matches?.('[data-timer-countdown-input]')) return
    if (!String(event.inputType || '').startsWith('insert') || !/^\d$/.test(String(event.data || ''))) return
    const current = String(input.value || '').replace(/\D/g, '')
    const start = Number(input.selectionStart)
    const end = Number(input.selectionEnd)
    const hasSelection = Number.isFinite(start) && Number.isFinite(end) && start !== end
    if (current.length < 2 || hasSelection) return
    event.preventDefault()
    input.value = (current + String(event.data)).slice(-2)
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  function handleTimerCountdownFocus(event) {
    const input = event.target
    if (!input?.matches?.('[data-timer-countdown-input]')) return
    if (typeof window.setDirectorTabletKeyboardOpen === 'function') {
      window.setDirectorTabletKeyboardOpen(true)
    }
    requestAnimationFrame(() => {
      try {
        input.select()
      } catch (_) {}
    })
  }

  function handleTimerCountdownPointerDown(event) {
    const input = event.target
    if (!input?.matches?.('[data-timer-countdown-input]')) return
    if (typeof window.setDirectorTabletKeyboardOpen === 'function') {
      window.setDirectorTabletKeyboardOpen(true)
    }
    if (document.activeElement === input) return
    try {
      input.focus({ preventScroll: true })
    } catch (_) {
      try { input.focus() } catch (_) {}
    }
  }

  function handleTimerCountdownBlur(event) {
    const input = event.target
    if (!input?.matches?.('[data-timer-countdown-input]')) return
    normalizeTimerCountdownInput(input, { commit: true })
    applyCountdownTarget(readCountdownInputs(), { render: false })
    window.setTimeout(() => {
      if (isCountdownInputFocused()) return
      if (typeof window.setDirectorTabletKeyboardOpen === 'function') {
        window.setDirectorTabletKeyboardOpen(false)
      }
    }, 80)
  }

  function installEvents() {
    document.addEventListener('scroll', handleTabletMultiLoopTracksScroll, true)
    document.addEventListener('pointerdown', handleAuthFieldPointerDown, true)
    document.addEventListener('pointerdown', handleTimerCountdownPointerDown, true)
    document.addEventListener('beforeinput', handleTimerCountdownBeforeInput, true)
    document.addEventListener('focusin', handleTimerCountdownFocus, true)
    document.addEventListener('focusout', handleTimerCountdownBlur, true)
    if (window.PointerEvent) {
      document.addEventListener('pointerdown', handleTabletPlayHold, { passive: true })
      document.addEventListener('pointermove', handleTabletPlayHold, { passive: true })
      document.addEventListener('pointerup', handleTabletPlayHold, { passive: true })
      document.addEventListener('pointercancel', handleTabletPlayHold, { passive: true })
      document.addEventListener('pointerdown', handleTabletPreviewHold, { passive: true })
      document.addEventListener('pointermove', handleTabletPreviewHold, { passive: true })
      document.addEventListener('pointerup', handleTabletPreviewHold, { passive: true })
      document.addEventListener('pointercancel', handleTabletPreviewHold, { passive: true })
      document.addEventListener('pointerdown', handlePlaylistScrollGesture, { passive: true })
      document.addEventListener('pointermove', handlePlaylistScrollGesture, { passive: true })
      document.addEventListener('pointerup', handlePlaylistScrollGesture, { passive: true })
      document.addEventListener('pointercancel', handlePlaylistScrollGesture, { passive: true })
      document.addEventListener('pointerdown', handleDirectorRecadosHoldStart, { passive: true })
      document.addEventListener('pointerup', handleDirectorRecadosHoldEnd, { passive: true })
      document.addEventListener('pointercancel', handleDirectorRecadosHoldEnd, { passive: true })
      document.addEventListener('pointerdown', handleTransportSeekDrag, { passive: false })
      document.addEventListener('pointermove', handleTransportSeekDrag, { passive: false })
      document.addEventListener('pointerup', handleTransportSeekDrag, { passive: false })
      document.addEventListener('pointercancel', handleTransportSeekDrag, { passive: false })
      document.addEventListener('pointerdown', handlePremixHoldStart, { passive: true })
      document.addEventListener('pointermove', handlePremixHoldMove, { passive: true })
      document.addEventListener('pointerup', handlePremixHoldEnd, { passive: true })
      document.addEventListener('pointercancel', handlePremixHoldEnd, { passive: true })
      document.addEventListener('pointerdown', handleMultiLoopMsHold, { passive: true })
      document.addEventListener('pointerup', handleMultiLoopMsHold, { passive: true })
      document.addEventListener('pointercancel', handleMultiLoopMsHold, { passive: true })
      document.addEventListener('pointerdown', handleMultiLoopAutoHold, { passive: true })
      document.addEventListener('pointermove', handleMultiLoopAutoHold, { passive: true })
      document.addEventListener('pointerup', handleMultiLoopAutoHold, { passive: true })
      document.addEventListener('pointercancel', handleMultiLoopAutoHold, { passive: true })
      document.addEventListener('pointerup', onTap, { passive: false })
      document.addEventListener('pointerup', handleMenuOutsidePointerUp, { passive: true })
    } else {
      document.addEventListener('click', onTap, false)
      document.addEventListener('click', handleMenuOutsidePointerUp, false)
    }
    document.addEventListener('touchstart', handleTransportTouchStart, { passive: true, capture: true })
    document.addEventListener('touchmove', handleTransportTouchMove, { passive: false, capture: true })
    document.addEventListener('touchend', handleTransportTouchEnd, { passive: false, capture: true })
    document.addEventListener('touchcancel', handleTransportTouchCancel, { passive: false, capture: true })
    document.addEventListener('contextmenu', (event) => {
      if (event.target?.closest?.('.transportSeekHoldTarget,.transportSeekPremixChildTarget,[data-action="tablet-multiloop-track"][data-mode="auto"]')) event.preventDefault()
    }, { passive: false })
    document.addEventListener('focusin', (event) => {
      if (event.target?.id === 'directorRecadosTextInput') {
        state.recadosTextFocused = true
        if (state.recadosViewportRestoreTimer) {
          window.clearTimeout(state.recadosViewportRestoreTimer)
          state.recadosViewportRestoreTimer = 0
        }
        if (typeof window.setDirectorTabletKeyboardOpen === 'function') window.setDirectorTabletKeyboardOpen(true)
      }
    }, true)
    document.addEventListener('focusout', (event) => {
      if (event.target?.id !== 'directorRecadosTextInput') return
      state.recadosDraft = event.target.value
      state.recadosTextFocused = false
      restoreDirectorRecadosViewport()
      window.setTimeout(() => { pollBridge(); pollDirectorTechnicalNotice(); scheduleRender() }, 0)
    }, true)
    document.addEventListener('input', (event) => {
      if (event.target?.id === 'directorPassInput') state.authPass = event.target.value
      if (event.target?.id === 'directorRecadosTextInput') return
      if (event.target?.id === 'tabletSearchInput') {
        state.tabletSearchQuery = event.target.value
        syncTabletSearchResultsDom()
        return
      }
      if (event.target?.matches?.('[data-timer-countdown-input]')) {
        normalizeTimerCountdownInput(event.target)
        applyCountdownTarget(readCountdownInputs(), { render: false })
      }
      handleRangeInput(event)
    }, true)
    document.addEventListener('change', (event) => {
      if (event.target?.id === 'directorRecadosImageInput') {
        chooseDirectorRecadoImage(event.target)
      }
    }, true)
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && document.activeElement?.id === 'directorPassInput') login()
      if (event.key === 'Escape' && state.showTransportSeekModal) closeTransportSeekModal()
      if (event.key === 'Escape' && state.showRecadosScreen) closeDirectorRecadosScreen()
      if (event.key === 'Escape' && state.showTabletSearch) {
        closeTabletSearchState()
        scheduleRender(true)
      }
    })
    window.addEventListener('resize', () => updateViewportHeight())
    preventAppZoom()
  }

  function updateViewportHeight() {
    if (isDirectorRecadosInputFocused()) return
    if (isCountdownInputFocused()) return
    if (document.activeElement?.id === 'tabletSearchInput') return
    if (document.documentElement.classList.contains('directorSearchViewportRestoring')) return
    if (document.documentElement.classList.contains('directorTabletKeyboardOpen')) return
    if (document.documentElement.classList.contains('directorTabletViewportRestoring')) return
    const tabletMode = document.documentElement.dataset.directorDevice === 'tablet'
    const tabletWebLandscape = tabletMode && window.matchMedia?.('(orientation: portrait)')?.matches
    const visibleWidth = Math.max(1, Math.floor(window.visualViewport?.width || window.innerWidth || 360))
    const visibleHeight = Math.max(1, Math.floor(window.visualViewport?.height || window.innerHeight || 640))
    let logicalWidth = tabletWebLandscape ? visibleHeight : visibleWidth
    let logicalHeight = tabletWebLandscape ? visibleWidth : visibleHeight

    if (tabletMode) {
      // Em telas menores, desenha o Tablet em uma prancheta virtual e reduz tudo
      // proporcionalmente. Assim nenhum controle é cortado no celular.
      const scale = Math.min(1, logicalWidth / 900, logicalHeight / 500)
      const safeScale = Math.max(0.35, scale)
      const virtualWidth = Math.ceil(logicalWidth / safeScale)
      const virtualHeight = Math.ceil(logicalHeight / safeScale)
      document.documentElement.style.setProperty('--tablet-screen-width', `${logicalWidth}px`)
      document.documentElement.style.setProperty('--tablet-screen-height', `${logicalHeight}px`)
      document.documentElement.style.setProperty('--tablet-ui-width', `${virtualWidth}px`)
      document.documentElement.style.setProperty('--tablet-ui-height', `${virtualHeight}px`)
      document.documentElement.style.setProperty('--tablet-ui-scale', String(safeScale))
      document.documentElement.style.setProperty('--app-vh', `${virtualHeight}px`)
      return
    }

    document.documentElement.style.removeProperty('--tablet-screen-width')
    document.documentElement.style.removeProperty('--tablet-screen-height')
    document.documentElement.style.removeProperty('--tablet-ui-width')
    document.documentElement.style.removeProperty('--tablet-ui-height')
    document.documentElement.style.removeProperty('--tablet-ui-scale')
    const h = Math.max(360, visibleHeight)
    document.documentElement.style.setProperty('--app-vh', `${h}px`)
  }

  async function requestScreenWakeLock() {
    if (!navigator.wakeLock || document.visibilityState === 'hidden' || state.wakeLock || state.wakeLockRequesting) return
    state.wakeLockRequesting = true
    try {
      const lock = await navigator.wakeLock.request('screen')
      state.wakeLock = lock
      lock.addEventListener?.('release', () => {
        if (state.wakeLock === lock) state.wakeLock = null
      })
    } catch (_) {
      state.wakeLock = null
    } finally {
      state.wakeLockRequesting = false
    }
  }

  function installWakeLock() {
    requestScreenWakeLock()
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        requestScreenWakeLock()
        if (!IS_MUSICIAN_MONITOR && state.authAuthenticated && !state.pcAccessReleased) {
          state.directorSessionAnnounced = false
          ensureDirectorSessionClaimed()
        }
      }
    })
    window.addEventListener('focus', () => {
      requestScreenWakeLock()
      if (!IS_MUSICIAN_MONITOR && state.authAuthenticated && !state.pcAccessReleased) {
        state.directorSessionAnnounced = false
        ensureDirectorSessionClaimed()
      }
    })
    document.addEventListener('pointerdown', () => requestScreenWakeLock(), { passive: true })
    document.addEventListener('touchstart', () => requestScreenWakeLock(), { passive: true })
  }

  function stopDirectorVisualLoops() {
    if (bridgePollTimer) window.clearInterval(bridgePollTimer)
    if (technicalNoticeTimer) window.clearInterval(technicalNoticeTimer)
    if (directorRenderTimer) window.clearInterval(directorRenderTimer)
    if (directorProgressAnimationFrame) window.cancelAnimationFrame(directorProgressAnimationFrame)
    bridgePollTimer = 0
    technicalNoticeTimer = 0
    directorRenderTimer = 0
    directorProgressAnimationFrame = 0
    directorProgressLastPaintAt = 0
  }

  function animateDirectorProgress(timestamp) {
    if (timestamp - directorProgressLastPaintAt >= DIRECTOR_VISUAL_FRAME_MS) {
      directorProgressLastPaintAt = timestamp
      if (!document.hidden && state.bridgeOnline) {
        syncPlaybackProgressDom()
        if (state.tabletFadeoutRuntimeActive) {
          syncTabletFadeoutProgressDom()
        }
      }
    }
    directorProgressAnimationFrame = window.requestAnimationFrame(animateDirectorProgress)
  }

  function startDirectorVisualLoops() {
    if (!bridgePollTimer) bridgePollTimer = window.setInterval(pollBridge, POLL_MS)
    if (!technicalNoticeTimer) technicalNoticeTimer = window.setInterval(pollDirectorTechnicalNotice, NOTICE_POLL_MS)
    if (!directorRenderTimer) directorRenderTimer = window.setInterval(() => scheduleRender(), 1000)
    if (!directorProgressAnimationFrame) {
      directorProgressAnimationFrame = window.requestAnimationFrame(animateDirectorProgress)
    }
  }

  function start() {
    updateViewportHeight()
    window.addEventListener('message', handleDirectorRecadosMessage)
    installEvents()
    installWakeLock()
    scheduleRender(true)
    pollBridge()
    pollDirectorTechnicalNotice()
    startDirectorVisualLoops()
    setInterval(sendHeartbeat, HEARTBEAT_MS)
    window.__VSHOOK_DIRECTOR_CLEAN__ = VERSION
  }

  start()
})()
