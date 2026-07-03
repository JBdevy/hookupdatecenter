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
  queueNameColor: '#ffea00',
  queueNameEnabled: true,
  queueNamePosition: 'top',
  queueNameDepth: 80,
  songNameFontFamily: 'Arial',
  songNameScale: 1,
  songNamePosition: 'top',
  clockPosition: 'top',
  clockScale: 1,
  mediaScale: 1,
  previewEnabled: true,
  previewScale: 1,
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
  document.documentElement.style.setProperty('--lyrics-queue-color', normalizeColor(settings.queueNameColor || '#ffea00', '#ffea00'));
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
  applyClockScaleToFit(safeClockScale);
  applyMediaScaleToElements(safeMediaScale);
  document.documentElement.style.setProperty('--lyrics-preview-scale', String(clampScale(settings.previewScale, 1, 1)));
  scheduleMarqueeRefresh(document); 
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
    const remaining = Math.max(0, timerTargetSec - elapsed);
    // Regressivo no TP precisa arredondar para cima.
    // Assim 02:00:00 não vira 01:59:59 no primeiro frame.
    return remaining > 0 ? Math.ceil(remaining) : 0;
  }
  return elapsed;
}

function formatBrowserLocalTime() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
}

function updateTimerVisual() {
  if (timerEl) {
    if (timerMode === 'local_time') {
      timerEl.textContent = timerDisplayText || timerLocalTimeText || formatBrowserLocalTime();
    } else {
      timerEl.textContent = formatTimer(getLocalTimerSeconds());
    }
    applyClockScaleToFit(settings.clockScale);
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
    const holder = wrap.closest('.lyrics-preview-title, .lyrics-preview-song');
    if (!holder) {
      wrap.classList.remove('is-overflowing');
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
    const candidateByLength = textValue.length >= (isTitle ? 10 : 14);
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
      const playingClass = song?.playing ? ' playing' : '';
      const queuedClass = song?.queued ? ' queued' : '';
      return `<div class="lyrics-preview-song${playingClass}${queuedClass}">${previewWrappedHtml(songName, 'song')}</div>`;
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
  if (key === lastSongName) return;
  lastSongName = key;
  if (songNameEl) {
    songNameEl.innerHTML = text ? marqueeHtml(text) : '';
  }
  if (queueNameEl) {
    queueNameEl.innerHTML = queueText ? marqueeHtml(queueText, 'lyrics-queue-marquee') : '';
  }
  document.body.classList.toggle('queue-enabled', !!queueText);
  scheduleMarqueeRefresh(document);
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
    playrate: Number(media.playrate || state.mediaPlayrate || 1) || 1,
    itemGuid: String(media.itemGuid || state.itemGuid || ''),
    itemStart: Number(media.itemStart || state.itemStart || 0),
    itemEnd: Number(media.itemEnd || state.itemEnd || 0),
    itemLength: Number(media.itemLength || state.itemLength || 0),
    text: String(state.overlayText || state.text || state.lyrics || state.lyricsText || '')
  };
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

    if (nextMode !== timerMode || Math.abs(nextTarget - timerTargetSec) > 0.5 || nextDisplayText !== timerDisplayText || nextLocalTimeText !== timerLocalTimeText) {
      timerMode = nextMode;
      timerTargetSec = nextTarget;
      timerDisplayText = nextDisplayText;
      timerLocalTimeText = nextLocalTimeText;
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
    applyMediaScaleToElements(settings.mediaScale);
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
window.addEventListener('resize', () => scheduleMarqueeRefresh(document), { passive: true });
