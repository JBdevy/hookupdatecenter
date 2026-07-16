const timerEl = document.getElementById('lyricsTimer');
const overlayEl = document.getElementById('lyricsOverlay');
const songNameEl = document.getElementById('lyricsSongName');
let queueNameEl = document.getElementById('lyricsQueueName');
if (!queueNameEl && overlayEl) {
  queueNameEl = document.createElement('div');
  queueNameEl.id = 'lyricsQueueName';
  queueNameEl.className = 'lyrics-queue-name';
  overlayEl.appendChild(queueNameEl);
}
const textEl = document.getElementById('lyricsText');
const mediaLayerEl = document.getElementById('lyricsMediaLayer');
const previewOverlayEl = document.getElementById('lyricsPreviewOverlay');
const imageEl = document.getElementById('lyricsImage');
const videoEl = document.getElementById('lyricsVideo');
const contentProgressEl = document.getElementById('lyricsContentProgress');
const contentProgressFillEl = document.getElementById('lyricsContentProgressFill');
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
  textCase: 'uppercase',
  fontFamily: 'Arial',
  textScale: 1,
  borderEnabled: true,
  windowBorderEnabled: true,
  clockBorderEnabled: true,
  textBoxEnabled: true,
  clockEnabled: true,
  songNameEnabled: false,
  songNameColor: '#00ff55',
  queueNameColor: '#ffea00',
  queueNameEnabled: true,
  queueNamePosition: 'top',
  queueNameDepth: 80,
  songNameFontFamily: 'Arial',
  songNameScale: 1,
  songNamePosition: 'top',
  progressEnabled: false,
  progressPosition: 'bottom',
  progressColor: '#ffea00',
  clockPosition: 'top',
  clockScale: 1,
  mediaScale: 1,
  previewEnabled: true,
  previewScale: 1,
  alwaysOnTop: false,
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
let timerDisplayText = '';
let timerLocalTimeText = '';
let timerExpired = false;
let timerRemoteDisplaySec = Number.NaN;
let timerRemoteDisplayUpdatedAtMs = 0;
let closingLyricsWindow = false;
let lastTechnicalNoticeKey = '';
let technicalNoticeFlashTimer = null;
let closeButtonHideTimer = null;
let contentProgressState = {
  key: '',
  elapsed: 0,
  sourceElapsed: 0,
  backwardDriftCount: 0,
  duration: 0,
  playing: false,
  sampledAt: 0,
  visible: false
};
let contentProgressRaf = 0;

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

function updateNameSafeWidth() {
  const safeSongScale = clampScale(settings.songNameScale, 1, 3);
  const margin = window.innerWidth <= 520 ? 12 : 24;
  const available = Math.max(80, window.innerWidth - margin);
  const unscaledWidth = Math.max(60, Math.floor(available / Math.max(0.35, safeSongScale)));
  document.documentElement.style.setProperty('--lyrics-name-safe-width', `${unscaledWidth}px`);
}

function normalizeMediaScale(value, fallback = 1) {
  const n = Number(value);
  const base = Number.isFinite(n) ? n : fallback;
  return Math.max(0.5, Math.min(1, base));
}

function applyMediaScaleToElements(value = settings.mediaScale) {
  const safeMediaScale = normalizeMediaScale(value, 1);
  const transformValue = `translateZ(0) scale(${safeMediaScale})`;

  document.documentElement.style.setProperty('--lyrics-media-scale', String(safeMediaScale));
  if (mediaLayerEl) mediaLayerEl.style.setProperty('--lyrics-media-scale', String(safeMediaScale));

  [imageEl, videoEl].forEach((el) => {
    if (!el) return;
    el.style.setProperty('transform', transformValue, 'important');
    el.style.setProperty('transform-origin', 'center center', 'important');
    el.style.setProperty('will-change', 'transform', 'important');
  });

  return safeMediaScale;
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
  scheduleOverlayLayoutMetrics();
  return finalScale;
}

let overlayMetricsRaf = null;

function resolvedCssLength(variableName, fallback = 0) {
  if (!document.body) return fallback;
  const probe = document.createElement('div');
  probe.setAttribute('aria-hidden', 'true');
  probe.style.position = 'fixed';
  probe.style.left = '-10000px';
  probe.style.top = '-10000px';
  probe.style.width = `var(${variableName})`;
  probe.style.height = '1px';
  probe.style.pointerEvents = 'none';
  probe.style.visibility = 'hidden';
  document.body.appendChild(probe);
  const value = Number(probe.getBoundingClientRect().width) || fallback;
  probe.remove();
  return value;
}

function visibleOverlayHeight(el) {
  if (!el) return 0;
  const text = String(el.textContent || '').trim();
  const style = window.getComputedStyle(el);
  if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return 0;
  if (!text && (el === songNameEl || el === queueNameEl)) return 0;
  const rect = el.getBoundingClientRect();
  const fontSize = Number.parseFloat(style.fontSize) || 0;
  const parsedLineHeight = Number.parseFloat(style.lineHeight);
  const lineHeight = Number.isFinite(parsedLineHeight) ? parsedLineHeight : (fontSize * 1.14);
  const verticalChrome = (Number.parseFloat(style.paddingTop) || 0)
    + (Number.parseFloat(style.paddingBottom) || 0)
    + (Number.parseFloat(style.borderTopWidth) || 0)
    + (Number.parseFloat(style.borderBottomWidth) || 0);
  // offsetHeight pode ficar momentaneamente zerado na primeira pintura da fila.
  // A estimativa tipográfica impede que os dois nomes recebam o mesmo offset.
  const intrinsicHeight = text ? Math.ceil(lineHeight + verticalChrome) : 0;
  return Math.max(0, Math.ceil(rect.height || 0), Math.ceil(el.offsetHeight || 0), Math.ceil(el.scrollHeight || 0), intrinsicHeight);
}

function applyMeasuredOverlayPlacement(el, position, offset) {
  if (!el) return;
  const safeOffset = `${Math.max(0, Number(offset) || 0)}px`;
  if (position === 'bottom') {
    el.style.setProperty('top', 'auto', 'important');
    el.style.setProperty('bottom', safeOffset, 'important');
  } else {
    el.style.setProperty('top', safeOffset, 'important');
    el.style.setProperty('bottom', 'auto', 'important');
  }
}

function clearMeasuredOverlayPlacement(el) {
  if (!el) return;
  el.style.removeProperty('top');
  el.style.removeProperty('bottom');
}

function updateOverlayLayoutMetrics() {
  const root = document.documentElement;
  const clockHeight = visibleOverlayHeight(timerEl);
  const songHeight = visibleOverlayHeight(songNameEl);
  const queueHeight = visibleOverlayHeight(queueNameEl);
  if (clockHeight > 0) root.style.setProperty('--lyrics-clock-real-height', `${clockHeight}px`);
  if (songHeight > 0) root.style.setProperty('--lyrics-song-real-height', `${songHeight}px`);
  if (queueHeight > 0) root.style.setProperty('--lyrics-queue-real-height', `${queueHeight}px`);

  // A posição final usa a altura realmente desenhada de cada elemento. Em uma
  // tela retrato, vw deixa o relógio muito mais alto que a estimativa antiga e
  // fazia as bordas do texto/nome entrarem por baixo dele.
  const edge = Math.max(3, resolvedCssLength('--lyrics-edge-offset', 6));
  const gap = Math.max(8, resolvedCssLength('--lyrics-overlay-gap', 8));
  const clockPosition = normalizeScreenPosition(settings.clockPosition, 'top');
  const songPosition = normalizeScreenPosition(settings.songNamePosition, 'top');
  const queuePosition = normalizeScreenPosition(settings.queueNamePosition, 'top');
  const clockVisible = clockHeight > 0 && !document.body.classList.contains('clock-hidden');
  const songVisible = songHeight > 0 && document.body.classList.contains('song-enabled');
  const queueVisible = queueHeight > 0 && document.body.classList.contains('queue-enabled');

  const offsets = {
    clockTop: edge,
    clockBottom: edge,
    songTop: edge,
    songBottom: edge,
    queueTop: edge,
    queueBottom: edge
  };

  let topCursor = edge;
  let topUsed = false;
  const placeTop = (key, height) => {
    offsets[key] = topCursor;
    topCursor += height + gap;
    topUsed = true;
  };
  // No topo: relógio, música atual e fila, nesta ordem.
  if (clockVisible && clockPosition === 'top') placeTop('clockTop', clockHeight);
  if (songVisible && songPosition === 'top') placeTop('songTop', songHeight);
  if (queueVisible && queuePosition === 'top') placeTop('queueTop', queueHeight);

  let bottomCursor = edge;
  let bottomUsed = false;
  let bottomQueueWasPlaced = false;
  const placeBottom = (key, height) => {
    offsets[key] = bottomCursor;
    bottomCursor += height + gap;
    bottomUsed = true;
  };
  // No rodapé a leitura visual continua música atual -> fila. Como os offsets
  // nascem de baixo, o relógio vem primeiro, depois a fila e por último a música.
  if (clockVisible && clockPosition === 'bottom') placeBottom('clockBottom', clockHeight);
  if (queueVisible && queuePosition === 'bottom') {
    placeBottom('queueBottom', queueHeight);
    bottomQueueWasPlaced = true;
  }
  if (songVisible && songPosition === 'bottom') {
    // Quando os dois nomes ficam no rodapé, reserva uma distância própria entre
    // eles. A fila deve aparecer visualmente ABAIXO do nome atual, nunca atrás.
    if (bottomQueueWasPlaced) bottomCursor += Math.max(0, 16 - gap);
    placeBottom('songBottom', songHeight);
  }

  root.style.setProperty('--lyrics-layout-clock-top', `${offsets.clockTop}px`);
  root.style.setProperty('--lyrics-layout-clock-bottom', `${offsets.clockBottom}px`);
  root.style.setProperty('--lyrics-layout-song-top', `${offsets.songTop}px`);
  root.style.setProperty('--lyrics-layout-song-bottom', `${offsets.songBottom}px`);
  root.style.setProperty('--lyrics-layout-queue-top', `${offsets.queueTop}px`);
  root.style.setProperty('--lyrics-layout-queue-bottom', `${offsets.queueBottom}px`);
  root.style.setProperty('--lyrics-layout-text-top', topUsed ? `${topCursor}px` : 'clamp(24px, 5vh, 58px)');
  root.style.setProperty('--lyrics-layout-text-bottom', bottomUsed ? `${bottomCursor}px` : 'clamp(24px, 5vh, 58px)');

  // Há muitas combinações de posição e escala no TP. Aplicar os offsets medidos
  // diretamente evita que uma regra CSS antiga prevaleça em uma largura/altura
  // específica e faça o nome da fila nascer atrás do nome da música atual.
  const overlayTemporarilyReplaced = document.body.classList.contains('preview-active')
    || document.body.classList.contains('notice-active');
  if (overlayTemporarilyReplaced) {
    clearMeasuredOverlayPlacement(timerEl);
    clearMeasuredOverlayPlacement(songNameEl);
    clearMeasuredOverlayPlacement(queueNameEl);
  } else {
    if (clockVisible) applyMeasuredOverlayPlacement(timerEl, clockPosition, clockPosition === 'bottom' ? offsets.clockBottom : offsets.clockTop);
    if (songVisible) applyMeasuredOverlayPlacement(songNameEl, songPosition, songPosition === 'bottom' ? offsets.songBottom : offsets.songTop);
    if (queueVisible) applyMeasuredOverlayPlacement(queueNameEl, queuePosition, queuePosition === 'bottom' ? offsets.queueBottom : offsets.queueTop);
  }
  document.body.classList.add('lyrics-layout-ready');
}

function scheduleOverlayLayoutMetrics() {
  if (overlayMetricsRaf) cancelAnimationFrame(overlayMetricsRaf);
  overlayMetricsRaf = requestAnimationFrame(() => {
    overlayMetricsRaf = null;
    updateOverlayLayoutMetrics();
  });
  setTimeout(updateOverlayLayoutMetrics, 80);
  setTimeout(updateOverlayLayoutMetrics, 240);
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
  document.documentElement.style.setProperty(
    '--lyrics-text-transform',
    settings.textCase === 'lowercase' ? 'lowercase' : (settings.textCase === 'original' ? 'none' : 'uppercase')
  );
  document.documentElement.style.setProperty('--lyrics-font', `${settings.fontFamily || 'Arial'}, sans-serif`);
  document.documentElement.style.setProperty('--lyrics-song-color', normalizeColor(settings.songNameColor || settings.clockColor, '#00ff55'));
  document.documentElement.style.setProperty('--lyrics-queue-color', normalizeColor(settings.queueNameColor || '#ffea00', '#ffea00'));
  document.documentElement.style.setProperty('--lyrics-progress-color', normalizeColor(settings.progressColor || '#ffea00', '#ffea00'));
  document.documentElement.style.setProperty('--lyrics-song-font', `${settings.songNameFontFamily || settings.fontFamily || 'Arial'}, sans-serif`);
  document.documentElement.style.setProperty('--lyrics-queue-font', `${settings.queueNameFontFamily || settings.songNameFontFamily || settings.fontFamily || 'Arial'}, sans-serif`);
  const queueDepth = Math.max(0, Math.min(240, Math.round(Number(settings.queueNameDepth ?? 80) || 80)));
  document.documentElement.style.setProperty('--lyrics-queue-z-index', String(2147483300 + queueDepth));
  const safeTextScale = clampScale(settings.textScale, 1, 1.25);
  const safeSongScale = clampScale(settings.songNameScale, 1, 3);
  const safeClockScale = clampScale(settings.clockScale, 1, 2.5);
  const safeMediaScale = normalizeMediaScale(settings.mediaScale, 1);
  document.documentElement.style.setProperty('--lyrics-text-scale', String(safeTextScale));
  document.documentElement.style.setProperty('--lyrics-song-scale', String(safeSongScale));
  updateNameSafeWidth();
  scheduleOverlayNameFit();
  applyClockScaleToFit(safeClockScale);
  applyMediaScaleToElements(safeMediaScale);
  document.documentElement.style.setProperty('--lyrics-preview-scale', String(clampScale(settings.previewScale, 1, 1)));
  scheduleMarqueeRefresh(document);
  scheduleOverlayLayoutMetrics();
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
  const queuePosition = normalizeScreenPosition(settings.queueNamePosition, 'top');
  document.body.classList.toggle('song-enabled', !clearMode && settings.songNameEnabled === true);
  document.body.classList.toggle('song-top', songPosition !== 'bottom');
  document.body.classList.toggle('song-bottom', songPosition === 'bottom');
  document.body.classList.toggle('queue-top', queuePosition !== 'bottom');
  document.body.classList.toggle('queue-bottom', queuePosition === 'bottom');
  const progressPosition = normalizeScreenPosition(settings.progressPosition, 'bottom');
  document.body.classList.toggle('progress-enabled', settings.progressEnabled === true);
  document.body.classList.toggle('progress-top', progressPosition === 'top');
  document.body.classList.toggle('progress-bottom', progressPosition !== 'top');
  // Compatibilidade com configuracoes antigas: agora o nome da musica tem posicao propria na tela.
  document.body.classList.toggle('song-above-clock', false);
  document.body.classList.toggle('song-below-clock', false);
  document.body.classList.toggle('clock-bottom', clockPosition === 'bottom');
  document.body.classList.toggle('clock-top', clockPosition !== 'bottom');
  forceClockAboveTechnicalNotice(document.body.classList.contains('notice-active'));
  scheduleOverlayLayoutMetrics();
  updateFontFit();
  renderContentProgress();
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

function formatTimer(sec, forceNegative = false) {
  const raw = Number(sec);
  const negative = forceNegative || Object.is(raw, -0) || (Number.isFinite(raw) && raw < 0);
  const total = Math.max(0, Math.floor(Math.abs(Number.isFinite(raw) ? raw : 0)));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${negative ? '- ' : ''}${String(h).padStart(2, '0')} : ${String(m).padStart(2, '0')} : ${String(s).padStart(2, '0')}`;
}

function getElapsedTimerSeconds() {
  if (!timerRunning) return timerAccumulatedSec;
  const live = (Date.now() - timerStartedAtMs) / 1000;
  return timerAccumulatedSec + Math.max(0, live);
}

function getCountdownRemainingRaw() {
  return timerTargetSec - getElapsedTimerSeconds();
}

function isTimerCountdownOverrun() {
  return timerMode === 'countdown' && timerRunning && (timerExpired || getCountdownRemainingRaw() <= 0);
}

function getLocalTimerSeconds() {
  // Usa primeiro o valor visual autoritativo publicado pela extensao.
  // Isso evita o Teleprompt reconstruir o regressivo com uma base antiga
  // e ficar preso em 00:00:00 quando o cronometro entra no negativo.
  if (Number.isFinite(timerRemoteDisplaySec) && timerRemoteDisplayUpdatedAtMs > 0) {
    let value = timerRemoteDisplaySec;
    if (timerRunning) {
      const live = Math.max(0, (Date.now() - timerRemoteDisplayUpdatedAtMs) / 1000);
      value += timerMode === 'countdown' ? -live : live;
    }
    if (timerMode === 'countdown') {
      if (value > 0) return Math.ceil(value);
      return -Math.floor(Math.abs(value));
    }
    return Math.max(0, value);
  }

  const elapsed = getElapsedTimerSeconds();
  if (timerMode === 'countdown') {
    const remaining = timerTargetSec - elapsed;
    if (remaining > 0) return Math.ceil(remaining);
    return -Math.floor(Math.abs(remaining));
  }
  return elapsed;
}

function formatBrowserLocalTime() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `${pad(now.getHours())} : ${pad(now.getMinutes())} : ${pad(now.getSeconds())}`;
}

// Mantem o horario local com exatamente o mesmo padrao visual dos outros modos
// do relogio: dois digitos e espacos ao redor dos separadores.
function formatLocalTimeLikeTimer(value) {
  const text = String(value || '').trim();
  const match = text.match(/^(\d{1,2})\s*:\s*(\d{1,2})\s*:\s*(\d{1,2})$/);
  if (!match) return formatBrowserLocalTime();
  const pad = (part) => String(Math.max(0, Number(part) || 0)).padStart(2, '0').slice(-2);
  return `${pad(match[1])} : ${pad(match[2])} : ${pad(match[3])}`;
}

function updateTimerVisual() {
  if (timerEl) {
    const overrun = isTimerCountdownOverrun();
    timerEl.classList.toggle('timer-overrun-blink', overrun);
    if (timerMode === 'local_time') {
      timerEl.textContent = formatLocalTimeLikeTimer(timerDisplayText || timerLocalTimeText);
    } else {
      timerEl.textContent = formatTimer(getLocalTimerSeconds(), overrun);
    }
    applyClockScaleToFit(settings.clockScale);
    scheduleOverlayLayoutMetrics();
  }
}


function escapePreviewHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function marqueeHtml(text, className = '') {
  const clean = String(text || '').trim();
  const value = escapePreviewHtml(clean);
  const baseClass = className ? `${className} ` : '';
  return `<span class="${baseClass}lyrics-marquee-wrap"><span class="lyrics-marquee-track"><span>${value}</span><span aria-hidden="true">${value}</span></span><span class="lyrics-static-text">${value}</span></span>`;
}

// VS_HOOK_FIX_TP_NAMES_SCALE_NOT_MARQUEE
// Nome da música atual e nome da fila não usam letreiro: o tamanho da fonte é reduzido
// proporcionalmente à janela, no mesmo conceito do relógio.
function nameFitHtml(text, className = '') {
  const clean = String(text || '').trim();
  const value = escapePreviewHtml(clean);
  const baseClass = className ? `${className} ` : '';
  return `<span class="${baseClass}lyrics-name-fit">${value}</span>`;
}

let overlayNameFitRaf = null;
function clampPx(value, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return min;
  return Math.max(min, Math.min(max, n));
}

function measureNameTextWidth(text, fontSizePx, fontFamily, fontWeight) {
  const value = String(text || '').trim();
  if (!value) return 0;
  const canvas = measureNameTextWidth.canvas || (measureNameTextWidth.canvas = document.createElement('canvas'));
  const ctx = canvas.getContext('2d');
  if (!ctx) return value.length * fontSizePx * 0.62;
  ctx.font = `${fontWeight || 900} ${fontSizePx}px ${fontFamily || 'Arial, sans-serif'}`;
  const measured = ctx.measureText(value).width || 0;
  return measured || (value.length * fontSizePx * 0.62);
}

function responsiveBaseNameFont(kind) {
  const safeScale = clampScale(settings.songNameScale, 1, 3);
  const vw = Math.max(1, Number(window.innerWidth) || 1);
  if (kind === 'queue') {
    return clampPx(vw * 0.0165, 14, 27) * safeScale;
  }
  return clampPx(vw * 0.022, 18, 34) * safeScale;
}

function fitNameFontForElement(el, kind) {
  if (!el) return 0;
  const text = String(el.textContent || '').trim();
  if (!text) return 0;
  const computed = window.getComputedStyle(el);
  const baseFont = responsiveBaseNameFont(kind);
  const horizontalPadding = kind === 'queue' ? 16 : 20;
  const safeMargin = (window.innerWidth <= 520 || window.innerHeight <= 360) ? 14 : 32;
  const available = Math.max(30, (Number(window.innerWidth) || 0) - safeMargin - horizontalPadding);
  const family = computed.fontFamily || (kind === 'queue' ? settings.queueNameFontFamily : settings.songNameFontFamily) || settings.fontFamily || 'Arial, sans-serif';
  const weight = computed.fontWeight || 900;
  const measured = measureNameTextWidth(text, baseFont, family, weight);
  if (!measured || measured <= available) return baseFont;
  const fitted = baseFont * (available / measured) * 0.985;
  return Math.max(8, Math.min(baseFont, fitted));
}

function fitOverlayNamesToWindow() {
  const songFont = fitNameFontForElement(songNameEl, 'song');
  const queueFont = fitNameFontForElement(queueNameEl, 'queue');
  if (songFont > 0) document.documentElement.style.setProperty('--lyrics-song-fit-font-size', `${songFont.toFixed(2)}px`);
  if (queueFont > 0) document.documentElement.style.setProperty('--lyrics-queue-fit-font-size', `${queueFont.toFixed(2)}px`);
  updateNameSafeWidth();
  scheduleOverlayLayoutMetrics();
}

function scheduleOverlayNameFit() {
  if (overlayNameFitRaf) cancelAnimationFrame(overlayNameFitRaf);
  overlayNameFitRaf = requestAnimationFrame(() => {
    overlayNameFitRaf = null;
    fitOverlayNamesToWindow();
  });
  [80, 220, 520, 1000].forEach((delay) => setTimeout(fitOverlayNamesToWindow, delay));
}

function previewWrappedHtml(text, kind = 'song') {
  const clean = String(text || '').trim();
  const value = escapePreviewHtml(clean);
  const safeKind = kind === 'title' ? 'title' : 'song';
  return `<span class="lyrics-preview-wrap-text lyrics-preview-${safeKind}-wrap">${value}</span>`;
}

let marqueeMeasureEl = null;
function measureMarqueeTextWidth(wrap, textEl) {
  if (!wrap || !textEl || !document.body) return 0;
  if (!marqueeMeasureEl) {
    marqueeMeasureEl = document.createElement('span');
    marqueeMeasureEl.setAttribute('aria-hidden', 'true');
    marqueeMeasureEl.style.position = 'fixed';
    marqueeMeasureEl.style.left = '-99999px';
    marqueeMeasureEl.style.top = '-99999px';
    marqueeMeasureEl.style.whiteSpace = 'nowrap';
    marqueeMeasureEl.style.pointerEvents = 'none';
    marqueeMeasureEl.style.visibility = 'hidden';
    document.body.appendChild(marqueeMeasureEl);
  }

  const cs = window.getComputedStyle(wrap);
  marqueeMeasureEl.style.fontFamily = cs.fontFamily;
  marqueeMeasureEl.style.fontSize = cs.fontSize;
  marqueeMeasureEl.style.fontWeight = cs.fontWeight;
  marqueeMeasureEl.style.fontStyle = cs.fontStyle;
  marqueeMeasureEl.style.letterSpacing = cs.letterSpacing;
  marqueeMeasureEl.style.textTransform = cs.textTransform;
  marqueeMeasureEl.textContent = textEl.textContent || '';
  return marqueeMeasureEl.getBoundingClientRect().width || marqueeMeasureEl.scrollWidth || 0;
}

let marqueeRefreshTimer = null;
function refreshMarqueeOverflow(root = document) {
  if (!root || !root.querySelectorAll) return;
  const items = root.querySelectorAll('.lyrics-marquee-wrap');
  items.forEach((wrap) => {
    const holder = wrap.closest('.lyrics-preview-title, .lyrics-preview-song, .lyrics-song-name, .lyrics-queue-name');
    if (!holder) {
      wrap.classList.remove('is-overflowing');
      wrap.classList.remove('preview-marquee-force');
      return;
    }

    const firstText = wrap.querySelector('.lyrics-marquee-track > span');
    const staticText = wrap.querySelector('.lyrics-static-text');
    const textValue = String((firstText || staticText)?.textContent || wrap.dataset.previewMarqueeText || '').trim();
    const holderBox = holder.getBoundingClientRect ? holder.getBoundingClientRect() : { width: 0 };
    const wrapBox = wrap.getBoundingClientRect ? wrap.getBoundingClientRect() : { width: 0 };
    const boxWidth = Math.max(
      0,
      Math.floor(holder.clientWidth || holderBox.width || wrap.clientWidth || wrapBox.width || 0)
    );
    const rawWidth = Math.max(
      firstText ? firstText.scrollWidth : 0,
      staticText ? staticText.scrollWidth : 0,
      measureMarqueeTextWidth(wrap, firstText || staticText)
    );

    const style = window.getComputedStyle(wrap);
    const fontSize = parseFloat(style.fontSize || '0') || (holder.classList.contains('lyrics-preview-title') ? 28 : 18);
    const approxWidth = textValue.length * fontSize * 0.64;
    const isTitle = holder.classList.contains('lyrics-preview-title');
    const isTopName = holder.classList.contains('lyrics-song-name') || holder.classList.contains('lyrics-queue-name');
    const candidateByLength = textValue.length >= (isTitle ? 10 : (isTopName ? 18 : 14));
    const overflowing = (boxWidth > 0 && (rawWidth > boxWidth + 2 || approxWidth > boxWidth + 2)) || candidateByLength;
    wrap.classList.toggle('is-overflowing', overflowing);
    wrap.classList.toggle('preview-marquee-force', overflowing);
  });
}

function scheduleMarqueeRefresh(root = document) {
  const target = root || document;
  requestAnimationFrame(() => refreshMarqueeOverflow(target));
  [80, 220, 520, 1000, 1600].forEach((delay) => {
    setTimeout(() => refreshMarqueeOverflow(target), delay);
  });
}

function cleanPreviewBlockLabel(value) {
  return String(value || '')
    .replace(/^\s*[:：]+\s*/g, '')
    .replace(/\s*[:：]+\s*$/g, '')
    .trim();
}

function renderPreviewOverlay(preview) {
  const enabled = settings.previewEnabled !== false;
  const active = enabled && preview && preview.active === true;
  document.body.classList.toggle('preview-active', !!active);
  if (!previewOverlayEl) return !!active;
  if (!active) {
    previewOverlayEl.innerHTML = '';
    previewOverlayEl.classList.add('hidden');
    return false;
  }
  const blocks = Array.isArray(preview.blocks) ? preview.blocks.slice(0, 8) : [];
  if (!blocks.length) {
    previewOverlayEl.innerHTML = `<div class="lyrics-preview-empty">${previewWrappedHtml(preview.noSongsMessage || 'Sem músicas', 'song')}</div>`;
    previewOverlayEl.classList.remove('hidden');
    return true;
  }
  previewOverlayEl.innerHTML = blocks.map((block) => {
    const name = cleanPreviewBlockLabel(block?.name || '');
    const songs = Array.isArray(block?.songs) ? block.songs.slice(0, 18) : [];
    const songRows = songs.map((song) => {
      const songName = String(song?.name || '').trim();
      if (!songName) return '';
      const isPlaying = song?.playing === true;
      const isQueued = song?.queued === true;
      const playingClass = isPlaying ? ' playing' : '';
      const queuedClass = isQueued ? ' queued' : '';
      const highlightedName = (isPlaying || isQueued) ? `[ ${songName} ]` : songName;
      return `<div class="lyrics-preview-song${playingClass}${queuedClass}">${previewWrappedHtml(highlightedName, 'song')}</div>`;
    }).join('') || `<div class="lyrics-preview-song lyrics-preview-song-empty">Sem músicas</div>`;
    return `<section class="lyrics-preview-card"><div class="lyrics-preview-title">${previewWrappedHtml(name || 'BLOCO', 'title')}</div><div class="lyrics-preview-song-list">${songRows}</div></section>`;
  }).join('');
  previewOverlayEl.classList.remove('hidden');
  return true;
}

function updateSongNameVisual(value, queuedValue) {
  const text = String(value || '').trim();
  const queueText = settings.queueNameEnabled === false ? '' : String(queuedValue || '').trim();
  const key = `${text}
${queueText}`;
  if (key === lastSongName) {
    updateNameSafeWidth();
    scheduleOverlayNameFit();
    scheduleOverlayLayoutMetrics();
    return;
  }
  lastSongName = key;
  if (songNameEl) {
    songNameEl.innerHTML = text ? nameFitHtml(text) : '';
  }
  if (queueNameEl) {
    queueNameEl.innerHTML = queueText ? nameFitHtml(queueText, 'lyrics-queue-name-fit') : '';
  }
  document.body.classList.toggle('queue-enabled', !!queueText);
  scheduleOverlayNameFit();
  scheduleOverlayLayoutMetrics();
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

function inferTelepromptTypeFromPath(value) {
  const clean = String(value || '').trim().split('?')[0].split('#')[0].toLowerCase();
  const ext = clean.includes('.') ? clean.slice(clean.lastIndexOf('.') + 1) : '';
  if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'svg'].includes(ext)) return 'image';
  if (['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'].includes(ext)) return 'video';
  return 'text';
}

function encodeLocalPathForFileUrl(value) {
  return String(value || '')
    .split('/')
    .map((part, index) => {
      if (index === 0 && /^[A-Za-z]:$/.test(part)) return part;
      return encodeURIComponent(part);
    })
    .join('/');
}

function mediaSrcFromRealPath(pathValue, urlValue) {
  const pathText = String(pathValue || '').trim();
  if (pathText) {
    if (/^(file|https?):\/\//i.test(pathText)) return pathText;
    const normalized = pathText.replace(/\\/g, '/');
    if (/^[A-Za-z]:\//.test(normalized)) return `file:///${encodeLocalPathForFileUrl(normalized)}`;
    if (normalized.startsWith('/')) return `file://${encodeLocalPathForFileUrl(normalized)}`;
    return normalized;
  }
  return String(urlValue || '').trim();
}

function getMediaPayload(state = {}) {
  const media = state.media && typeof state.media === 'object' ? state.media : {};
  const rawPath = String(media.path || state.mediaPath || '').trim();
  const rawUrl = String(media.url || state.mediaUrl || '').trim();
  const inferredType = inferTelepromptTypeFromPath(rawPath || rawUrl);
  const declaredType = normalizeTelepromptType(media.type || state.telepromptType || state.mediaType || state.type);
  // FIX108: a extensao manda o caminho real do item; a janela decide por extensao.
  // Tipo separado fica só como fallback quando não há caminho de mídia.
  const type = inferredType !== 'text' ? inferredType : declaredType;
  const src = mediaSrcFromRealPath(rawPath, rawUrl);
  return {
    type,
    url: src,
    path: rawPath,
    currentTime: Math.max(0, Number(media.currentTime || state.mediaCurrentTime || 0)),
    offset: Math.max(0, Number(media.offset || state.mediaOffset || 0)),
    playrate: Number(media.playrate || state.mediaPlayrate || 1) || 1,
    itemGuid: String(media.itemGuid || state.itemGuid || ''),
    itemStart: Number(media.itemStart || state.itemStart || 0),
    itemEnd: Number(media.itemEnd || state.itemEnd || 0),
    itemLength: Number(media.itemLength || state.itemLength || 0),
    projectPosition: Number.isFinite(Number(media.position ?? state.position ?? state.projectPosition))
      ? Number(media.position ?? state.position ?? state.projectPosition)
      : Number.NaN,
    text: String(state.overlayText || state.text || state.lyrics || state.lyricsText || '')
  };
}

function stopContentProgressAnimation() {
  if (!contentProgressRaf) return;
  cancelAnimationFrame(contentProgressRaf);
  contentProgressRaf = 0;
}

function getLiveContentProgressElapsed() {
  const duration = Math.max(0, Number(contentProgressState.duration) || 0);
  let elapsed = Math.max(0, Number(contentProgressState.elapsed) || 0);
  if (contentProgressState.playing && contentProgressState.sampledAt > 0) {
    elapsed += Math.max(0, (performance.now() - contentProgressState.sampledAt) / 1000);
  }
  return duration > 0 ? Math.min(duration, elapsed) : 0;
}

function renderContentProgress() {
  if (!contentProgressEl || !contentProgressFillEl) return;
  const enabled = settings.progressEnabled === true;
  const noticeActive = document.body.classList.contains('notice-active');
  // A opcao "Mostrar progresso" reserva a faixa mesmo quando o cursor ainda
  // nao esta sobre um item. Antes a barra inteira era escondida se a duracao
  // ainda nao tivesse chegado do bridge, parecendo que a configuracao nao
  // funcionava. Preview e aviso tecnico continuam suprimindo a faixa.
  const visible = enabled && !noticeActive && contentProgressState.visible === true;
  contentProgressEl.classList.toggle('hidden', !visible);
  if (!visible) {
    contentProgressFillEl.style.width = '0%';
    stopContentProgressAnimation();
    return;
  }

  if (!(contentProgressState.duration > 0)) {
    contentProgressFillEl.style.width = '0%';
    stopContentProgressAnimation();
    return;
  }

  const ratio = Math.max(0, Math.min(1, getLiveContentProgressElapsed() / contentProgressState.duration));
  contentProgressFillEl.style.width = `${(ratio * 100).toFixed(3)}%`;

  if (contentProgressState.playing && ratio < 1) {
    if (!contentProgressRaf) {
      contentProgressRaf = requestAnimationFrame(() => {
        contentProgressRaf = 0;
        renderContentProgress();
      });
    }
  } else {
    stopContentProgressAnimation();
  }
}

function updateContentProgressFromState(state = {}, suppressed = false) {
  const media = getMediaPayload(state);
  const itemStart = Number(media.itemStart);
  const itemEnd = Number(media.itemEnd);
  const explicitLength = Number(media.itemLength);
  const duration = explicitLength > 0
    ? explicitLength
    : (Number.isFinite(itemStart) && Number.isFinite(itemEnd) ? Math.max(0, itemEnd - itemStart) : 0);

  let elapsed = 0;
  if (Number.isFinite(media.projectPosition) && Number.isFinite(itemStart)) {
    elapsed = media.projectPosition - itemStart;
  } else if (media.type === 'video' || media.type === 'image') {
    const playrate = Math.max(0.0001, Math.abs(Number(media.playrate) || 1));
    elapsed = (Math.max(0, Number(media.currentTime) || 0) - Math.max(0, Number(media.offset) || 0)) / playrate;
  }

  const key = [media.itemGuid, media.itemStart, media.itemEnd, media.type, media.path || media.url, media.text].join('|');
  const sourceElapsed = Math.max(0, Math.min(duration, Number(elapsed) || 0));
  let visualElapsed = sourceElapsed;
  let backwardDriftCount = 0;
  const sameItem = key === contentProgressState.key && duration > 0 && contentProgressState.duration > 0;
  if (sameItem && state.playing === true && contentProgressState.playing === true) {
    const previousLiveElapsed = getLiveContentProgressElapsed();
    const sourceMoved = Math.abs(sourceElapsed - (Number(contentProgressState.sourceElapsed) || 0)) > 0.001;
    if (!sourceMoved) {
      // O bridge pode repetir a mesma amostra em vários polls. Mantém o avanço
      // local em vez de voltar para essa amostra antiga a cada 120 ms.
      visualElapsed = previousLiveElapsed;
      backwardDriftCount = Number(contentProgressState.backwardDriftCount) || 0;
    } else {
      const drift = sourceElapsed - previousLiveElapsed;
      // Pequenas diferenças são apenas atraso entre as duas leituras. Um salto
      // maior continua sendo tratado imediatamente como seek real.
      if (drift < -0.32 && drift >= -0.55) {
        backwardDriftCount = (Number(contentProgressState.backwardDriftCount) || 0) + 1;
        visualElapsed = backwardDriftCount >= 2 ? sourceElapsed : previousLiveElapsed;
        if (backwardDriftCount >= 2) backwardDriftCount = 0;
      } else {
        visualElapsed = Math.abs(drift) <= 0.55
          ? Math.max(previousLiveElapsed, sourceElapsed)
          : sourceElapsed;
      }
    }
  }
  contentProgressState = {
    key,
    elapsed: Math.max(0, Math.min(duration, visualElapsed)),
    sourceElapsed,
    backwardDriftCount,
    duration,
    playing: state.playing === true,
    sampledAt: performance.now(),
    visible: suppressed !== true
  };
  renderContentProgress();
}


function applyMediaTextOverlay(text) {
  const value = String(text || '').trim();
  if (!value) {
    textEl.classList.add('hidden');
    if (lastText !== '') {
      lastText = '';
      updateFontFit();
    }
    return false;
  }
  textEl.classList.remove('hidden');
  if (value !== lastText) {
    lastText = value;
    updateFontFit();
  }
  return true;
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
  const src = media.url;
  if (!src) return showEmptyMode();
  if (lastMediaType === 'video') stopAndClearVideo();
  lastMediaType = 'image';
  mediaLayerEl?.classList.remove('hidden');
  videoEl?.classList.add('hidden');
  imageEl?.classList.remove('hidden');
  applyMediaScaleToElements(settings.mediaScale);
  if (imageEl && imageEl.getAttribute('src') !== src) imageEl.setAttribute('src', src);
  applyMediaTextOverlay(media.text);
}

function showVideoMode(media, playing) {
  document.body.classList.add('media-active');
  const src = media.url;
  if (!src || !videoEl) return showEmptyMode();

  const mediaKey = `${media.itemGuid || ''}|${src}|${media.itemStart || 0}|${media.itemEnd || 0}|${media.itemLength || 0}`;
  const urlChanged = lastVideoSrc !== src || videoEl.getAttribute('src') !== src;
  const itemChanged = lastVideoKey !== mediaKey;
  const targetTime = Math.max(0, Number(media.currentTime) || 0);
  const nextRate = Math.max(0.1, Math.min(4, Number(media.playrate || 1) || 1));

  lastMediaType = 'video';
  lastTelepromptKey = mediaKey;
  lastVideoKey = mediaKey;
  mediaLayerEl?.classList.remove('hidden');
  imageEl?.classList.add('hidden');
  videoEl.classList.remove('hidden');
  applyMediaScaleToElements(settings.mediaScale);
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

  applyMediaTextOverlay(media.text);
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
    updateSongNameVisual(state.song || state.songName || state.currentSongName || state.musicName || '', state.queuedSongName || state.queueSongName || state.previewOverlay?.queuedSongName || '');
    const previewActive = renderPreviewOverlay(state.previewOverlay || null);
    if (previewActive) {
      showEmptyMode();
    } else {
      renderTelepromptState(state);
    }
    updateContentProgressFromState(state, previewActive);

    const nextRunning = !!state.timerRunning;
    const nextAccumulated = Number(state.timerAccumulatedSec || 0);
    const nextStartedRaw = Number(state.timerStartedAt || 0);
    const nextStartedMs = nextStartedRaw > 1000000000000 ? nextStartedRaw : nextStartedRaw * 1000;
    const nextModeRaw = String(state.timerMode || state.timerType || 'progressive').toLowerCase();
    const nextMode = (nextModeRaw === 'local_time' || nextModeRaw === 'localtime' || nextModeRaw === 'local' || nextModeRaw === 'hora_local' || nextModeRaw === 'horario_local' || nextModeRaw === 'clock' || nextModeRaw === 'relogio')
      ? 'local_time'
      : ((nextModeRaw === 'countdown' || nextModeRaw === 'regressive' || nextModeRaw === 'regressivo') ? 'countdown' : 'progressive');
    const nextTarget = Math.max(0, Math.min(359999, Number(state.timerTargetSec || state.timerCountdownStartSec || 0)));
    const nextDisplayText = String(state.timerDisplayText || '').trim();
    const nextLocalTimeText = String(state.timerLocalTimeText || '').trim();
    const nextDisplaySec = Number(state.timerDisplaySec);
    const nextExpired = state.timerExpired === true || state.timerOverrun === true || state.timerNegative === true ||
      String(nextDisplayText || '').trim().startsWith('-') ||
      (nextMode === 'countdown' && nextRunning && Number.isFinite(nextDisplaySec) && nextDisplaySec <= 0);

    if (Number.isFinite(nextDisplaySec)) {
      timerRemoteDisplaySec = nextDisplaySec;
      timerRemoteDisplayUpdatedAtMs = Date.now();
    }

    if (nextMode !== timerMode || Math.abs(nextTarget - timerTargetSec) > 0.5 || nextDisplayText !== timerDisplayText || nextLocalTimeText !== timerLocalTimeText || nextExpired !== timerExpired) {
      timerMode = nextMode;
      timerTargetSec = nextTarget;
      timerDisplayText = nextDisplayText;
      timerLocalTimeText = nextLocalTimeText;
      timerExpired = nextExpired;
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
  const useNativeMacWindowDrag = window.hookUpdateCenter.platform === 'darwin';
  if (useNativeMacWindowDrag) {
    // O macOS precisa transferir a NSWindow entre as telas por arraste nativo.
    // setPosition com screenX/screenY mistura espaços de coordenadas quando os
    // monitores usam escalas diferentes e pode deixar a janela fora da tela.
    document.documentElement.classList.add('macos-native-window-drag');
  } else {
    setupManualWindowDrag();
  }
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
    updateNameSafeWidth();
    scheduleOverlayNameFit();
    updateFontFit();
    applyClockScaleToFit(settings.clockScale);
    applyMediaScaleToElements(settings.mediaScale);
    scheduleMarqueeRefresh(document);
    scheduleOverlayLayoutMetrics();
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

// VS_HOOK_FIX_ALL_TP_NAMES_MARQUEE_RESIZE
window.addEventListener('resize', () => { updateNameSafeWidth(); scheduleOverlayNameFit(); scheduleOverlayLayoutMetrics(); }, { passive: true });
