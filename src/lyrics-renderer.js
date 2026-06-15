const timerEl = document.getElementById('lyricsTimer');
const textEl = document.getElementById('lyricsText');
const closeButton = document.getElementById('closeLyricsButton');
const params = new URLSearchParams(window.location.search);
const lyricsSlot = Number(params.get('slot')) === 2 ? 2 : 1;

let settings = {
  textColor: '#ffea00',
  clockColor: '#00ff55',
  fontFamily: 'Arial'
};
let lastText = '';
let timerRunning = false;
let timerStartedAtMs = 0;
let timerAccumulatedSec = 0;
let closingLyricsWindow = false;

function normalizeColor(value, fallback) {
  return /^#[0-9a-fA-F]{6}$/.test(String(value || '')) ? value : fallback;
}

function applySettings(next = {}) {
  const incoming = next && next.settings ? next.settings : next;
  if (next && next.slot && Number(next.slot) !== lyricsSlot) return;
  settings = { ...settings, ...incoming };
  document.documentElement.style.setProperty('--lyrics-text-color', normalizeColor(settings.textColor, '#ffea00'));
  document.documentElement.style.setProperty('--lyrics-clock-color', normalizeColor(settings.clockColor, '#00ff55'));
  document.documentElement.style.setProperty('--lyrics-font', `${settings.fontFamily || 'Arial'}, sans-serif`);
  updateFontFit();
}

function formatTimer(sec) {
  const total = Math.max(0, Math.floor(Number(sec) || 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${String(h).padStart(2, '0')} : ${String(m).padStart(2, '0')} : ${String(s).padStart(2, '0')}`;
}

function getLocalTimerSeconds() {
  if (!timerRunning) return timerAccumulatedSec;
  const live = (Date.now() - timerStartedAtMs) / 1000;
  return timerAccumulatedSec + Math.max(0, live);
}

function updateTimerVisual() {
  timerEl.textContent = formatTimer(getLocalTimerSeconds());
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
  textEl.style.fontSize = `${chosen}px`;
}

async function pollState() {
  try {
    const state = await window.hookUpdateCenter.getLyricsState();
    const nextText = String(state.text || '');
    if (nextText !== lastText) {
      lastText = nextText;
      updateFontFit();
    }

    const nextRunning = !!state.timerRunning;
    const nextAccumulated = Number(state.timerAccumulatedSec || 0);
    const nextStartedRaw = Number(state.timerStartedAt || 0);
    const nextStartedMs = nextStartedRaw > 1000000000000 ? nextStartedRaw : nextStartedRaw * 1000;

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
  try { applySettings(await window.hookUpdateCenter.getLyricsSettings(lyricsSlot)); } catch (_) { applySettings(settings); }
  window.hookUpdateCenter.onLyricsSettingsUpdated?.(applySettings);
  const stopCloseButtonDrag = (event) => {
    event.preventDefault();
    event.stopPropagation();
  };

  const closeLyrics = async (event) => {
    if (event) stopCloseButtonDrag(event);
    if (closingLyricsWindow) return;
    closingLyricsWindow = true;
    try { await window.hookUpdateCenter.closeCurrentWindow(); } catch (_) { closingLyricsWindow = false; }
  };

  closeButton.addEventListener('pointerdown', stopCloseButtonDrag, true);
  closeButton.addEventListener('mousedown', stopCloseButtonDrag, true);
  closeButton.addEventListener('mouseup', stopCloseButtonDrag, true);
  closeButton.addEventListener('pointerup', closeLyrics, true);
  closeButton.addEventListener('click', closeLyrics, true);
  window.addEventListener('resize', updateFontFit);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      window.hookUpdateCenter.closeLyricsWindow?.(lyricsSlot);
      window.hookUpdateCenter.closeCurrentWindow();
    }
  });
  await pollState();
  setInterval(pollState, 120);
  setInterval(updateTimerVisual, 250);
}

init();
