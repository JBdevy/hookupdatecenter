const timerEl = document.getElementById('lyricsTimer');
const overlayEl = document.getElementById('lyricsOverlay');
const songNameEl = document.getElementById('lyricsSongName');
const textEl = document.getElementById('lyricsText');
const mediaLayerEl = document.getElementById('lyricsMediaLayer');
const imageEl = document.getElementById('lyricsImage');
const videoEl = document.getElementById('lyricsVideo');
const closeButton = document.getElementById('closeLyricsButton');
const technicalNoticeEl = document.getElementById('technicalNotice');
const params = new URLSearchParams(window.location.search);
const lyricsSlot = Number(params.get('slot')) === 2 ? 2 : 1;

let settings = {
  textColor: '#ffea00',
  textBoxColor: '#ffea00',
  clockColor: '#00ff55',
  borderColor: '#00ff55',
  rgbBorderEnabled: false,
  rgbWindowBorderEnabled: false,
  rgbClockBorderEnabled: false,
  rgbTextBoxBorderEnabled: false,
  fontFamily: 'Arial',
  textScale: 1,
  borderEnabled: true,
  windowBorderEnabled: true,
  clockBorderEnabled: true,
  textBoxEnabled: true,
  clockEnabled: true,
  songNameEnabled: false,
  songNameColor: '#00ff55',
  songNameFontFamily: 'Arial',
  songNameScale: 1,
  songNamePosition: 'top',
  clockPosition: 'top',
  clockScale: 1,
  mediaScale: 1,
  clearMode: false
};
let technicalNoticeSettings = {
  textColor: '#ffea00',
  flashColor: '#ff0000',
  fontFamily: 'Arial',
  window1Enabled: true,
  window2Enabled: true,
  emojiEnabled: true,
  emoji: '⚠️'
};
let activeTechnicalNotice = null;
let lastText = '';
let lastTelepromptKey = '';
let lastMediaType = 'text';
let lastSongName = '';
let pendingVideoSeek = null;
let pendingVideoPlay = false;
let lastVideoSrc = '';
let lastVideoKey = '';
let lastVideoWasPlaying = false;
let lastVideoPlaybackRate = 1;
let lastVideoSyncAt = 0;
let timerRunning = false;
let timerStartedAtMs = 0;
let timerAccumulatedSec = 0;
let timerMode = 'progressive';
let timerTargetSec = 0;
let closingLyricsWindow = false;
let lastTechnicalNoticeKey = '';
let technicalNoticeFlashTimer = null;
let closeButtonHideTimer = null;

function normalizeColor(value, fallback) {
  return /^#[0-9a-fA-F]{6}$/.test(String(value || '')) ? value : fallback;
}


function normalizeScreenPosition(value, fallback = 'top') {
  const v = String(value || '').trim().toLowerCase();
  if (v === 'bottom' || v === 'below' || v === 'baixo' || v === 'down') return 'bottom';
  if (v === 'top' || v === 'above' || v === 'cima' || v === 'up') return 'top';
  return fallback;
}

function clampScale(value, fallback = 1, max = 1.25) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(0.35, Math.min(max, n));
}

function clockLetterSpacingFromScale(scale) {
  const n = Number(scale);
  const safe = Number.isFinite(n) ? n : 1;
  const spacing = 0.12 + Math.max(0, safe - 1) * 0.10;
  return `${Math.min(0.36, spacing).toFixed(3)}em`;
}

function applyClockScaleToFit(requestedScale = settings.clockScale) {
  const desired = clampScale(requestedScale, 1, 2.5);
  const availableWidth = Math.max(120, window.innerWidth - 10);
  let finalScale = desired;

  for (let i = 0; i < 5; i += 1) {
    document.documentElement.style.setProperty('--lyrics-clock-scale', String(finalScale));
    document.documentElement.style.setProperty('--lyrics-clock-letter-spacing', clockLetterSpacingFromScale(finalScale));

    if (!timerEl) break;
    const rect = timerEl.getBoundingClientRect();
    const width = Number(rect && rect.width) || 0;
    if (!width || width <= availableWidth) break;

    finalScale = Math.max(0.35, finalScale * (availableWidth / width) * 0.995);
  }

  document.documentElement.style.setProperty('--lyrics-clock-scale', String(finalScale));
  document.documentElement.style.setProperty('--lyrics-clock-letter-spacing', clockLetterSpacingFromScale(finalScale));
  return finalScale;
}

function showCloseButtonTemporarily(duration = 5000) {
  if (!closeButton) return;
  document.body.classList.add('show-close-button');
  if (closeButtonHideTimer) clearTimeout(closeButtonHideTimer);
  closeButtonHideTimer = setTimeout(() => {
    document.body.classList.remove('show-close-button');
    closeButtonHideTimer = null;
  }, Math.max(500, Number(duration) || 5000));
}

function wireCloseButtonVisibility() {
  if (!closeButton) return;
  const reveal = () => showCloseButtonTemporarily(5000);
  window.addEventListener('mousemove', reveal, { passive: true });
  window.addEventListener('pointermove', reveal, { passive: true });
  window.addEventListener('mouseenter', reveal, { passive: true });
  window.addEventListener('touchstart', reveal, { passive: true });
  reveal();
}

function applySettings(next = {}) {
  const incoming = next && next.settings ? next.settings : next;
  if (next && next.slot && Number(next.slot) !== lyricsSlot) return;
  settings = { ...settings, ...incoming };
  document.documentElement.style.setProperty('--lyrics-text-color', normalizeColor(settings.textColor, '#ffea00'));
  document.documentElement.style.setProperty('--lyrics-text-box-color', normalizeColor(settings.textBoxColor || settings.textColor, '#ffea00'));
  document.documentElement.style.setProperty('--lyrics-clock-color', normalizeColor(settings.clockColor, '#00ff55'));
  document.documentElement.style.setProperty('--lyrics-border-color', normalizeColor(settings.borderColor || settings.clockColor, '#00ff55'));
  document.documentElement.style.setProperty('--lyrics-font', `${settings.fontFamily || 'Arial'}, sans-serif`);
  document.documentElement.style.setProperty('--lyrics-song-color', normalizeColor(settings.songNameColor || settings.clockColor, '#00ff55'));
  document.documentElement.style.setProperty('--lyrics-song-font', `${settings.songNameFontFamily || settings.fontFamily || 'Arial'}, sans-serif`);
  const safeTextScale = clampScale(settings.textScale, 1, 1.25);
  const safeSongScale = clampScale(settings.songNameScale, 1, 3);
  const safeClockScale = clampScale(settings.clockScale, 1, 2.5);
  const safeMediaScale = clampScale(settings.mediaScale, 1, 1.25);
  document.documentElement.style.setProperty('--lyrics-text-scale', String(safeTextScale));
  document.documentElement.style.setProperty('--lyrics-song-scale', String(safeSongScale));
  applyClockScaleToFit(safeClockScale);
  document.documentElement.style.setProperty('--lyrics-media-scale', String(safeMediaScale));
  const clearMode = settings.clearMode === true;
  const windowBorderEnabled = clearMode ? false : (settings.windowBorderEnabled ?? settings.borderEnabled ?? true);
  const clockBorderEnabled = clearMode ? false : (settings.clockBorderEnabled ?? settings.borderEnabled ?? true);
  const textBoxEnabled = clearMode ? false : (settings.textBoxEnabled ?? true);
  document.body.classList.toggle('clear-mode', clearMode);
  document.body.classList.toggle('border-hidden', windowBorderEnabled === false);
  const legacyRgb = settings.rgbBorderEnabled === true;
  document.body.classList.toggle('rgb-border-enabled', false);
  document.body.classList.toggle('rgb-window-border-enabled', !clearMode && ((settings.rgbWindowBorderEnabled ?? legacyRgb) === true));
  document.body.classList.toggle('rgb-clock-border-enabled', !clearMode && settings.rgbClockBorderEnabled === true);
  document.body.classList.toggle('rgb-text-box-border-enabled', !clearMode && settings.rgbTextBoxBorderEnabled === true);
  document.body.classList.toggle('clock-border-hidden', clockBorderEnabled === false);
  document.body.classList.toggle('text-box-hidden', textBoxEnabled === false);
  document.body.classList.toggle('clock-hidden', clearMode || settings.clockEnabled === false);
  const clockPosition = normalizeScreenPosition(settings.clockPosition, 'top');
  const songPosition = normalizeScreenPosition(settings.songNamePosition, 'top');
  document.body.classList.toggle('song-enabled', !clearMode && settings.songNameEnabled === true);
  document.body.classList.toggle('song-top', songPosition !== 'bottom');
  document.body.classList.toggle('song-bottom', songPosition === 'bottom');
  // Compatibilidade com configuracoes antigas: agora o nome da musica tem posicao propria na tela.
  document.body.classList.toggle('song-above-clock', false);
  document.body.classList.toggle('song-below-clock', false);
  document.body.classList.toggle('clock-bottom', clockPosition === 'bottom');
  document.body.classList.toggle('clock-top', clockPosition !== 'bottom');
  forceClockAboveTechnicalNotice(document.body.classList.contains('notice-active'));
  updateFontFit();
}

function applyTechnicalNoticeSettings(next = {}) {
  technicalNoticeSettings = { ...technicalNoticeSettings, ...(next || {}) };
  document.documentElement.style.setProperty('--notice-text-color', normalizeColor(technicalNoticeSettings.textColor, '#ffea00'));
  document.documentElement.style.setProperty('--notice-flash-color', normalizeColor(technicalNoticeSettings.flashColor, '#ff0000'));
  document.documentElement.style.setProperty('--notice-font', `${technicalNoticeSettings.fontFamily || 'Arial'}, sans-serif`);
}

function getTechnicalNoticeEmoji() {
  const emoji = String(technicalNoticeSettings.emoji || '⚠️').trim().replace(/[\r\n\t]+/g, '').slice(0, 8);
  return emoji || '⚠️';
}

function isTechnicalNoticeEnabledForSlot() {
  if (lyricsSlot === 2) return technicalNoticeSettings.window2Enabled !== false;
  return technicalNoticeSettings.window1Enabled !== false;
}

function formatTechnicalNoticeText(text) {
  const clean = String(text || '').trim();
  if (!clean) return '';
  if (technicalNoticeSettings.emojiEnabled === false) return clean;
  const emoji = getTechnicalNoticeEmoji();
  return `${emoji} ${clean} ${emoji}`;
}

function flashTechnicalNoticeBackground() {
  if (!technicalNoticeEl) return;
  technicalNoticeEl.classList.remove('notice-flash');
  void technicalNoticeEl.offsetWidth;
  technicalNoticeEl.classList.add('notice-flash');
  if (technicalNoticeFlashTimer) clearTimeout(technicalNoticeFlashTimer);
  technicalNoticeFlashTimer = setTimeout(() => {
    technicalNoticeEl.classList.remove('notice-flash');
    technicalNoticeFlashTimer = null;
  }, 1150);
}


function forceClockAboveTechnicalNotice(active) {
  const shouldShowClock = active === true && settings.clearMode !== true && settings.clockEnabled !== false;
  try {
    document.body.classList.toggle('notice-clock-visible', shouldShowClock);
    if (shouldShowClock && overlayEl && overlayEl.parentElement !== document.body) {
      document.body.appendChild(overlayEl);
    }
    if (shouldShowClock && timerEl) {
      timerEl.style.display = 'block';
      timerEl.style.visibility = 'visible';
      timerEl.style.opacity = '1';
      timerEl.style.zIndex = '2147483647';
    } else if (timerEl) {
      timerEl.style.removeProperty('display');
      timerEl.style.removeProperty('visibility');
      timerEl.style.removeProperty('opacity');
      timerEl.style.removeProperty('z-index');
    }
  } catch (_) {}
}

function updateTechnicalNoticeVisual(notice = activeTechnicalNotice) {
  activeTechnicalNotice = notice && typeof notice === 'object' ? notice : null;
  const text = String(activeTechnicalNotice?.text || activeTechnicalNotice?.message || '').trim();
  const expiresAt = Number(activeTechnicalNotice?.expiresAt || 0);
  const active = settings.clearMode !== true && isTechnicalNoticeEnabledForSlot() && !!text && Number.isFinite(expiresAt) && expiresAt > Date.now();
  if (!technicalNoticeEl) return;
  if (!active) {
    technicalNoticeEl.textContent = '';
    technicalNoticeEl.classList.add('hidden');
    document.body.classList.remove('notice-active');
    forceClockAboveTechnicalNotice(false);
    lastTechnicalNoticeKey = '';
    return;
  }
  const noticeKey = String(activeTechnicalNotice?.id || activeTechnicalNotice?.updatedAt || `${text}:${expiresAt}`);
  technicalNoticeEl.textContent = formatTechnicalNoticeText(text);
  technicalNoticeEl.classList.remove('hidden');
  document.body.classList.add('notice-active');
  forceClockAboveTechnicalNotice(true);
  if (noticeKey && noticeKey !== lastTechnicalNoticeKey) {
    lastTechnicalNoticeKey = noticeKey;
    flashTechnicalNoticeBackground();
  }
}

function formatTimer(sec) {
  const total = Math.max(0, Math.floor(Number(sec) || 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${String(h).padStart(2, '0')} : ${String(m).padStart(2, '0')} : ${String(s).padStart(2, '0')}`;
}

function getElapsedTimerSeconds() {
  if (!timerRunning) return timerAccumulatedSec;
  const live = (Date.now() - timerStartedAtMs) / 1000;
  return timerAccumulatedSec + Math.max(0, live);
}

function getLocalTimerSeconds() {
  const elapsed = getElapsedTimerSeconds();
  if (timerMode === 'countdown') {
    return Math.max(0, timerTargetSec - elapsed);
  }
  return elapsed;
}

function updateTimerVisual() {
  if (timerEl) {
    timerEl.textContent = formatTimer(getLocalTimerSeconds());
    applyClockScaleToFit(settings.clockScale);
  }
}

function updateSongNameVisual(value) {
  const text = String(value || '').trim();
  if (text === lastSongName) return;
  lastSongName = text;
  if (songNameEl) songNameEl.textContent = text;
}

function updateFontFit() {
  const text = lastText.trim();
  if (!text) {
    textEl.textContent = '';
    return;
  }

  textEl.textContent = lastText;
  const max = window.innerHeight >= 850 ? 86 : window.innerHeight >= 650 ? 74 : 58;
  const min = 18;
  let chosen = min;

  for (let size = max; size >= min; size -= 2) {
    textEl.style.fontSize = `${size}px`;
    if (textEl.scrollHeight <= textEl.clientHeight && textEl.scrollWidth <= textEl.clientWidth) {
      chosen = size;
      break;
    }
  }
  textEl.style.fontSize = `${Math.max(12, chosen * clampScale(settings.textScale, 1))}px`;
}

function normalizeTelepromptType(value) {
  const type = String(value || '').trim().toLowerCase();
  if (type === 'image' || type === 'img' || type === 'picture') return 'image';
  if (type === 'video' || type === 'movie') return 'video';
  if (type === 'empty' || type === 'none') return 'empty';
  return 'text';
}

function getMediaPayload(state = {}) {
  const media = state.media && typeof state.media === 'object' ? state.media : {};
  const type = normalizeTelepromptType(media.type || state.telepromptType || state.mediaType || state.type);
  return {
    type,
    url: String(media.url || state.mediaUrl || ''),
    path: String(media.path || state.mediaPath || ''),
    currentTime: Math.max(0, Number(media.currentTime || state.mediaCurrentTime || 0)),
    playrate: Number(media.playrate || state.mediaPlayrate || 1) || 1,
    itemGuid: String(media.itemGuid || state.itemGuid || ''),
    itemStart: Number(media.itemStart || state.itemStart || 0),
    itemEnd: Number(media.itemEnd || state.itemEnd || 0),
    itemLength: Number(media.itemLength || state.itemLength || 0)
  };
}

function stopAndClearVideo() {
  if (!videoEl) return;
  try { videoEl.pause(); } catch (_) {}
  if (videoEl.getAttribute('src')) {
    videoEl.removeAttribute('src');
    try { videoEl.load(); } catch (_) {}
  }
  pendingVideoSeek = null;
  pendingVideoPlay = false;
  lastVideoSrc = '';
  lastVideoKey = '';
  lastVideoWasPlaying = false;
  lastVideoPlaybackRate = 1;
  lastVideoSyncAt = 0;
}

function hideMedia() {
  document.body.classList.remove('media-active');
  mediaLayerEl?.classList.add('hidden');
  imageEl?.classList.add('hidden');
  videoEl?.classList.add('hidden');
}

function showTextMode(text) {
  if (lastMediaType === 'video') stopAndClearVideo();
  lastMediaType = 'text';
  hideMedia();
  textEl.classList.remove('hidden');
  if (String(text || '') !== lastText) {
    lastText = String(text || '');
    updateFontFit();
  }
}

function showEmptyMode() {
  if (lastMediaType === 'video') stopAndClearVideo();
  lastMediaType = 'empty';
  hideMedia();
  textEl.classList.remove('hidden');
  if (lastText !== '') {
    lastText = '';
    updateFontFit();
  }
}

function seekVideoIfNeeded(targetTime, force = false, options = {}) {
  if (!videoEl) return false;
  const value = Math.max(0, Number(targetTime) || 0);
  const now = Date.now();
  const isPlaying = options.playing === true;

  if (!Number.isFinite(videoEl.duration) || videoEl.readyState < 1) {
    pendingVideoSeek = value;
    pendingVideoPlay = isPlaying;
    return false;
  }

  try {
    const drift = Math.abs((Number(videoEl.currentTime) || 0) - value);
    // Evita micro-seeks em todo poll. Eles eram a principal causa das travadinhas.
    // Enquanto toca, só corrige quando o drift fica perceptível ou em troca de item/corte.
    // Enquanto o vídeo está tocando, não ficar "caçando" sincronismo a cada poll.
    // Isso eliminava o efeito visual de o vídeo ficar se mexendo/tentando encaixar.
    const tolerance = isPlaying ? 2.00 : 0.08;
    const minInterval = isPlaying ? 1800 : 0;
    if (force || (drift > tolerance && (now - lastVideoSyncAt) > minInterval)) {
      lastVideoSyncAt = now;
      videoEl.currentTime = value;
      return true;
    }
  } catch (_) {}
  return false;
}

function showImageMode(media) {
  document.body.classList.add('media-active');
  const src = media.url || media.path;
  if (!src) return showEmptyMode();
  if (lastMediaType === 'video') stopAndClearVideo();
  lastMediaType = 'image';
  textEl.classList.add('hidden');
  mediaLayerEl?.classList.remove('hidden');
  videoEl?.classList.add('hidden');
  imageEl?.classList.remove('hidden');
  if (imageEl && imageEl.getAttribute('src') !== src) imageEl.setAttribute('src', src);
  if (lastText !== '') {
    lastText = '';
    updateFontFit();
  }
}

function showVideoMode(media, playing) {
  document.body.classList.add('media-active');
  const src = media.url || media.path;
  if (!src || !videoEl) return showEmptyMode();

  const mediaKey = `${media.itemGuid || ''}|${src}|${media.itemStart || 0}|${media.itemEnd || 0}|${media.itemLength || 0}`;
  const urlChanged = lastVideoSrc !== src || videoEl.getAttribute('src') !== src;
  const itemChanged = lastVideoKey !== mediaKey;
  const targetTime = Math.max(0, Number(media.currentTime) || 0);
  const nextRate = Math.max(0.1, Math.min(4, Number(media.playrate || 1) || 1));

  lastMediaType = 'video';
  lastTelepromptKey = mediaKey;
  lastVideoKey = mediaKey;
  textEl.classList.add('hidden');
  mediaLayerEl?.classList.remove('hidden');
  imageEl?.classList.add('hidden');
  videoEl.classList.remove('hidden');
  videoEl.muted = true;
  videoEl.playsInline = true;
  videoEl.loop = false;
  videoEl.preload = 'auto';

  if (Math.abs((Number(lastVideoPlaybackRate) || 1) - nextRate) > 0.001) {
    try { videoEl.playbackRate = nextRate; } catch (_) {}
    lastVideoPlaybackRate = nextRate;
  }

  if (urlChanged) {
    lastVideoSrc = src;
    pendingVideoSeek = targetTime;
    pendingVideoPlay = !!playing;
    videoEl.setAttribute('src', src);
    try { videoEl.load(); } catch (_) {}
  } else {
    // Mesmo arquivo com outro corte/item: não recarrega o vídeo, só reposiciona.
    if (itemChanged || !playing) {
      seekVideoIfNeeded(targetTime, true, { playing: !!playing });
    } else {
      seekVideoIfNeeded(targetTime, false, { playing: !!playing });
    }
  }

  if (playing) {
    pendingVideoPlay = true;
    if (videoEl.paused || videoEl.ended || !lastVideoWasPlaying) {
      const playPromise = videoEl.play();
      if (playPromise && typeof playPromise.catch === 'function') playPromise.catch(() => {});
    }
  } else {
    pendingVideoPlay = false;
    if (!videoEl.paused) {
      try { videoEl.pause(); } catch (_) {}
    }
    seekVideoIfNeeded(targetTime, true, { playing: false });
  }
  lastVideoWasPlaying = !!playing;

  if (lastText !== '') {
    lastText = '';
    updateFontFit();
  }
}

function renderTelepromptState(state = {}) {
  const media = getMediaPayload(state);

  // Modo Clear limpa somente texto vindo de Empty Item.
  // Imagem e video continuam liberados para a janela.
  if (media.type === 'image') return showImageMode(media);
  if (media.type === 'video') return showVideoMode(media, !!state.playing);
  if (media.type === 'empty') return showEmptyMode();

  if (settings.clearMode === true) return showEmptyMode();
  return showTextMode(String(state.text || ''));
}

async function pollState() {
  try {
    const state = await window.hookUpdateCenter.getLyricsState(lyricsSlot);
    if (state.technicalNoticeSettings) applyTechnicalNoticeSettings(state.technicalNoticeSettings);
    updateTechnicalNoticeVisual(state.technicalNotice || null);
    updateSongNameVisual(state.song || state.songName || state.currentSongName || state.musicName || '');
    renderTelepromptState(state);

    const nextRunning = !!state.timerRunning;
    const nextAccumulated = Number(state.timerAccumulatedSec || 0);
    const nextStartedRaw = Number(state.timerStartedAt || 0);
    const nextStartedMs = nextStartedRaw > 1000000000000 ? nextStartedRaw : nextStartedRaw * 1000;
    const nextModeRaw = String(state.timerMode || state.timerType || 'progressive').toLowerCase();
    const nextMode = (nextModeRaw === 'countdown' || nextModeRaw === 'regressive' || nextModeRaw === 'regressivo') ? 'countdown' : 'progressive';
    const nextTarget = Math.max(0, Math.min(359999, Number(state.timerTargetSec || state.timerCountdownStartSec || 0)));

    if (nextMode !== timerMode || Math.abs(nextTarget - timerTargetSec) > 0.5) {
      timerMode = nextMode;
      timerTargetSec = nextTarget;
      updateTimerVisual();
    }

    if (nextRunning !== timerRunning || Math.abs(nextAccumulated - timerAccumulatedSec) > 1.5) {
      timerRunning = nextRunning;
      timerAccumulatedSec = nextAccumulated;
      timerStartedAtMs = nextRunning && nextStartedMs > 0 ? nextStartedMs : Date.now();
      updateTimerVisual();
    } else if (nextRunning && nextStartedMs > 0 && Math.abs(nextStartedMs - timerStartedAtMs) > 1500) {
      timerStartedAtMs = nextStartedMs;
    }
  } catch (_) {}
}

async function init() {
  try {
    document.body.style.pointerEvents = 'auto';
    document.documentElement.style.pointerEvents = 'auto';
  } catch (_) {}
  try { applySettings(await window.hookUpdateCenter.getLyricsSettings(lyricsSlot)); } catch (_) { applySettings(settings); }
  try { applyTechnicalNoticeSettings(await window.hookUpdateCenter.getTechnicalNoticeSettings()); } catch (_) { applyTechnicalNoticeSettings(technicalNoticeSettings); }
  window.hookUpdateCenter.onLyricsSettingsUpdated?.(applySettings);
  window.hookUpdateCenter.onTechnicalNoticeSettingsUpdated?.(applyTechnicalNoticeSettings);
  wireCloseButtonVisibility();
  const stopCloseButtonDrag = (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
  };

  const closeLyrics = async (event) => {
    if (event) stopCloseButtonDrag(event);
    if (closingLyricsWindow) return;
    closingLyricsWindow = true;
    try {
      await window.hookUpdateCenter.closeCurrentWindow();
    } catch (_) {
      try { await window.hookUpdateCenter.closeLyricsWindow?.(lyricsSlot); }
      catch (_) { closingLyricsWindow = false; }
    }
  };

  if (closeButton) {
    closeButton.addEventListener('pointerdown', closeLyrics, true);
    closeButton.addEventListener('mousedown', closeLyrics, true);
    closeButton.addEventListener('touchstart', closeLyrics, true);
    closeButton.addEventListener('click', closeLyrics, true);
  }

  const setupManualWindowDrag = () => {
    let dragState = null;
    const isCloseTarget = (target) => Boolean(target && target.closest && target.closest('#closeLyricsButton'));

    const beginDrag = async (event) => {
      if ((event.button !== undefined && event.button !== 0) || isCloseTarget(event.target) || Number(event.detail || 0) >= 2) return;
      event.preventDefault();
      try {
        const response = await window.hookUpdateCenter.getCurrentWindowBounds?.();
        if (!response || !response.ok || !response.bounds) return;
        dragState = {
          pointerId: event.pointerId,
          startScreenX: Number(event.screenX) || 0,
          startScreenY: Number(event.screenY) || 0,
          startX: Number(response.bounds.x) || 0,
          startY: Number(response.bounds.y) || 0
        };
        try { document.body.setPointerCapture?.(event.pointerId); } catch (_) {}
      } catch (_) {
        dragState = null;
      }
    };

    const moveDrag = (event) => {
      if (!dragState || (dragState.pointerId !== undefined && event.pointerId !== dragState.pointerId)) return;
      event.preventDefault();
      const nextX = dragState.startX + ((Number(event.screenX) || 0) - dragState.startScreenX);
      const nextY = dragState.startY + ((Number(event.screenY) || 0) - dragState.startScreenY);
      window.hookUpdateCenter.moveCurrentWindow?.({ x: nextX, y: nextY });
    };

    const endDrag = (event) => {
      if (!dragState) return;
      if (event && dragState.pointerId !== undefined && event.pointerId !== dragState.pointerId) return;
      try { document.body.releasePointerCapture?.(dragState.pointerId); } catch (_) {}
      dragState = null;
    };

    let lastRightClickAt = 0;
    let lastLeftClickAt = 0;
    let lastLeftDoubleClickHandledAt = 0;
    let fullscreenToggleBusy = false;

    const stopGestureEvent = (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
    };

    const requestFullscreenToggle = async () => {
      if (fullscreenToggleBusy) return;
      fullscreenToggleBusy = true;
      dragState = null;
      try {
        await window.hookUpdateCenter.toggleCurrentWindowFullscreen?.();
      } catch (_) {}
      setTimeout(() => { fullscreenToggleBusy = false; }, 260);
    };

    document.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      event.stopPropagation();
    }, true);

    document.addEventListener('mousedown', (event) => {
      if (isCloseTarget(event.target)) return;
      const button = Number(event.button);
      const now = Date.now();

      if (button === 2) {
        if ((now - lastRightClickAt) <= 420) {
          stopGestureEvent(event);
          dragState = null;
          window.hookUpdateCenter.closeCurrentWindow?.();
          return;
        }
        lastRightClickAt = now;
        return;
      }

      if (button === 0) {
        if ((now - lastLeftClickAt) <= 420) {
          stopGestureEvent(event);
          lastLeftClickAt = 0;
          lastLeftDoubleClickHandledAt = now;
          requestFullscreenToggle();
          return;
        }
        lastLeftClickAt = now;
      }
    }, true);

    document.addEventListener('pointerdown', beginDrag, true);
    document.addEventListener('pointermove', moveDrag, true);
    document.addEventListener('pointerup', endDrag, true);
    document.addEventListener('pointercancel', endDrag, true);

    document.addEventListener('dblclick', (event) => {
      if (isCloseTarget(event.target)) return;
      const now = Date.now();
      if ((now - lastLeftDoubleClickHandledAt) <= 520) {
        stopGestureEvent(event);
        return;
      }
      stopGestureEvent(event);
      lastLeftDoubleClickHandledAt = now;
      requestFullscreenToggle();
    }, true);

    window.addEventListener('blur', () => { dragState = null; });
  };
  setupManualWindowDrag();
  if (videoEl) {
    const applyPendingVideoSync = () => {
      if (pendingVideoSeek !== null) {
        const shouldPlay = pendingVideoPlay;
        const target = pendingVideoSeek;
        seekVideoIfNeeded(target, true, { playing: shouldPlay });
        pendingVideoSeek = null;
        if (shouldPlay) {
          if (videoEl.paused || videoEl.ended) {
            const playPromise = videoEl.play();
            if (playPromise && typeof playPromise.catch === 'function') playPromise.catch(() => {});
          }
        } else {
          try { videoEl.pause(); } catch (_) {}
        }
      }
    };
    videoEl.addEventListener('loadedmetadata', applyPendingVideoSync);
    videoEl.addEventListener('canplay', applyPendingVideoSync);
  }
  window.addEventListener('resize', () => {
    updateFontFit();
    applyClockScaleToFit(settings.clockScale);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      window.hookUpdateCenter.closeLyricsWindow?.(lyricsSlot);
      window.hookUpdateCenter.closeCurrentWindow();
    }
  });
  await pollState();
  setInterval(pollState, 120);
  setInterval(updateTimerVisual, 250);
  setInterval(() => updateTechnicalNoticeVisual(activeTechnicalNotice), 250);
}

init();
