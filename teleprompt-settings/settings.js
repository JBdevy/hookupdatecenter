const BRIDGE = 'http://127.0.0.1:47830';

const defaults = {
  preset: 'night',
  textColor: '#ffea00',
  textBoxColor: '#ffea00',
  clockColor: '#00ff55',
  clockExpiredColor: '#ff3131',
  clockBorderColor: '#00ff55',
  localClockColor: '#00ff55',
  borderColor: '#00ff55',
  songNameColor: '#00ff55',
  queueNameColor: '#ffea00',
  progressColor: '#ffea00',
  fontFamily: 'Arial',
  songNameFontFamily: 'Arial',
  queueNameFontFamily: 'Arial',
  textCase: 'uppercase',
  clockPosition: 'center-top',
  localClockPosition: 'right',
  songNamePosition: 'top',
  queueNamePosition: 'top',
  progressPosition: 'bottom',
  textScale: 1,
  clockScale: 1,
  songNameScale: 1,
  queueNameScale: 1,
  mediaScale: 1,
  previewScale: 1,
  localClockDepth: 1,
  windowBorderEnabled: true,
  clockBorderEnabled: true,
  textBoxEnabled: true,
  clockEnabled: true,
  localClockEnabled: true,
  songNameEnabled: false,
  queueNameEnabled: true,
  progressEnabled: false,
  previewEnabled: true,
  clearMode: false,
  rgbWindowBorderEnabled: false,
  rgbClockBorderEnabled: false,
  rgbTextBoxBorderEnabled: false
};

const state = {
  view: 'teleprompt',
  slot: 1,
  values: {
    1: { ...defaults },
    2: { ...defaults, previewEnabled: false }
  },
  saveTimers: {
    1: null,
    2: null
  },
  notice: {
    textColor: '#ffea00',
    backgroundColor: '#000000',
    flashColor: '#ff0000',
    fontFamily: 'Arial',
    window1Enabled: true,
    window2Enabled: true,
    emojiEnabled: true,
    emoji: '⚠️',
    cleanDisplay: false
  },
  noticeSaveTimer: null
};

const numericKeys = new Set([
  'textScale', 'clockScale', 'songNameScale', 'queueNameScale',
  'mediaScale', 'previewScale',
  'localClockDepth'
]);
const controls = [
  ...document.querySelectorAll(
    '#telepromptSettingsCard [name]')
];
const noticeControls = [
  ...document.querySelectorAll(
    '#recadosSettingsCard [name]')
];
const statusEl = document.getElementById('saveStatus');
const noticeStatusEl =
  document.getElementById('recadosSaveStatus');

function setStatus(message, kind = '') {
  statusEl.textContent = message;
  statusEl.className = `save-status ${kind}`.trim();
}

function readControl(control) {
  if (control.type === 'checkbox') return control.checked;
  return numericKeys.has(control.name) ? Number(control.value) : control.value;
}

function updateOutputs() {
  document.querySelectorAll('[data-output]').forEach((output) => {
    const key = output.dataset.output;
    const value = state.values[state.slot][key];
    output.value = `${Math.round(Number(value) * 100)}%`;
  });
}

function render() {
  const value = state.values[state.slot];
  controls.forEach((control) => {
    if (!(control.name in value)) return;
    if (control.type === 'checkbox') control.checked = Boolean(value[control.name]);
    else control.value = value[control.name];
  });
  document.querySelectorAll('.lyrics-config-tab').forEach((tab) => {
    const active = tab.dataset.view === 'recados'
      ? state.view === 'recados'
      : state.view === 'teleprompt' &&
        Number(tab.dataset.slot) === state.slot;
    tab.classList.toggle('active', active);
    tab.setAttribute('aria-selected', String(active));
  });
  document.getElementById('telepromptSettingsCard')
    .classList.toggle('hidden', state.view !== 'teleprompt');
  document.getElementById('recadosSettingsCard')
    .classList.toggle('hidden', state.view !== 'recados');
  noticeControls.forEach((control) => {
    const key = control.name.replace(/^notice/, '');
    const normalizedKey =
      key.charAt(0).toLowerCase() + key.slice(1);
    if (!(normalizedKey in state.notice)) return;
    if (control.type === 'checkbox') {
      control.checked = Boolean(state.notice[normalizedKey]);
    } else {
      control.value = state.notice[normalizedKey];
    }
  });
  document.getElementById('windowTitle').textContent = `Janela ${state.slot}`;
  const clearButton = document.getElementById('clearMode');
  clearButton.classList.toggle('active', Boolean(value.clearMode));
  clearButton.setAttribute('aria-pressed', value.clearMode ? 'true' : 'false');
  clearButton.textContent = value.clearMode ? 'Modo Clear ON' : 'Modo Clear';
  document.getElementById('presetNight').classList.toggle(
    'preset-selected', value.preset !== 'day');
  document.getElementById('presetDay').classList.toggle(
    'preset-selected', value.preset === 'day');
  updateOutputs();
}

async function postCommand(payload) {
  const response = await fetch(`${BRIDGE}/command`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

async function saveSlot(slot) {
  const selectedSlot = Number(slot) === 2 ? 2 : 1;
  await postCommand({
    type: 'teleprompt_settings',
    slot: selectedSlot,
    ...state.values[selectedSlot]
  });
}

async function saveNow(slot = state.slot) {
  const selectedSlot = Number(slot) === 2 ? 2 : 1;
  clearTimeout(state.saveTimers[selectedSlot]);
  state.saveTimers[selectedSlot] = null;
  setStatus('Aplicando nas janelas nativas…');
  try {
    await saveSlot(selectedSlot);
    setStatus(
      `Configurações do Teleprompt ${selectedSlot} salvas e aplicadas.`,
      'saved');
  } catch (error) {
    setStatus('Não foi possível aplicar. Abra o REAPER com a extensão carregada.', 'error');
  }
}

async function saveNoticeNow() {
  clearTimeout(state.noticeSaveTimer);
  state.noticeSaveTimer = null;
  noticeStatusEl.textContent =
    'Aplicando os Recados nas janelas nativas…';
  noticeStatusEl.className = 'save-status';
  try {
    await postCommand({
      type: 'technical_notice_settings',
      ...state.notice
    });
    noticeStatusEl.textContent =
      'Configurações dos Recados salvas e aplicadas.';
    noticeStatusEl.className = 'save-status saved';
  } catch (error) {
    noticeStatusEl.textContent =
      'Não foi possível aplicar. Abra o REAPER com a extensão carregada.';
    noticeStatusEl.className = 'save-status error';
  }
}

function scheduleNoticeSave() {
  clearTimeout(state.noticeSaveTimer);
  state.noticeSaveTimer =
    setTimeout(saveNoticeNow, 120);
}

function scheduleSave() {
  const selectedSlot = state.slot;
  clearTimeout(state.saveTimers[selectedSlot]);
  state.saveTimers[selectedSlot] =
    setTimeout(() => saveNow(selectedSlot), 120);
}

async function loadSettings() {
  try {
    const response = await fetch(`${BRIDGE}/teleprompt-settings`, {
      cache: 'no-store'
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    state.values[1] = { ...defaults, ...(data.tp1 || {}) };
    state.values[2] = {
      ...defaults,
      previewEnabled: false,
      ...(data.tp2 || {})
    };
    state.notice = {
      ...state.notice,
      ...(data.technicalNoticeSettings || {})
    };
    // Migra o espaçamento alto usado pelo primeiro protótipo.
    for (const slot of [1, 2]) {
      const oldTimerPosition =
        String(state.values[slot].clockPosition || '').toLowerCase();
      if (oldTimerPosition === 'top') {
        state.values[slot].clockPosition = 'center-top';
      } else if (oldTimerPosition === 'bottom') {
        state.values[slot].clockPosition = 'center-bottom';
      }
      if (Number(state.values[slot].localClockDepth) > 3) {
        state.values[slot].localClockDepth = 1;
      }
      delete state.values[slot].queueNameDepth;
      delete state.values[slot].alwaysOnTop;
      const oldClockPosition =
        String(state.values[slot].localClockPosition || '').toLowerCase();
      state.values[slot].localClockPosition =
        oldClockPosition.includes('left') ? 'left' : 'right';
      state.values[slot].textScale = Math.min(
        1, Math.max(0.5, Number(state.values[slot].textScale) || 1));
      state.values[slot].clockScale = Math.min(
        1, Math.max(0.5, Number(state.values[slot].clockScale) || 1));
      state.values[slot].songNameScale = Math.min(
        2, Math.max(0.5, Number(state.values[slot].songNameScale) || 1));
      state.values[slot].queueNameScale = Math.min(
        2, Math.max(0.5, Number(state.values[slot].queueNameScale) || 1));
      state.values[slot].mediaScale = Math.min(
        1.5, Math.max(0.5, Number(state.values[slot].mediaScale) || 1));
      state.values[slot].localClockDepth = Math.min(
        2, Math.max(0.5, Number(state.values[slot].localClockDepth) || 1));
    }
    setStatus('Configurações carregadas da extensão.', 'saved');
  } catch (error) {
    setStatus('Não foi possível carregar as configurações.', 'error');
  }
  render();
}

controls.forEach((control) => {
  const eventName =
    control.type === 'range' || control.type === 'color'
      ? 'input'
      : 'change';
  control.addEventListener(eventName, () => {
    state.values[state.slot][control.name] = readControl(control);
    updateOutputs();
    scheduleSave();
  });
});

noticeControls.forEach((control) => {
  const eventName =
    control.type === 'color' ? 'input' : 'change';
  control.addEventListener(eventName, () => {
    const key = control.name.replace(/^notice/, '');
    const normalizedKey =
      key.charAt(0).toLowerCase() + key.slice(1);
    state.notice[normalizedKey] =
      control.type === 'checkbox'
        ? control.checked
        : control.value;
    scheduleNoticeSave();
  });
});

document.querySelectorAll('.lyrics-config-tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    if (tab.dataset.view === 'recados') {
      state.view = 'recados';
      render();
      return;
    }
    state.view = 'teleprompt';
    state.slot = Number(tab.dataset.slot) === 2 ? 2 : 1;
    render();
  });
});

function applyPreset(preset) {
  const day = preset === 'day';
  state.values[state.slot] = {
    ...state.values[state.slot],
    preset: day ? 'day' : 'night',
    textColor: day ? '#ffffff' : '#ffea00',
    textBoxColor: day ? '#ffffff' : '#ffea00',
    clockColor: day ? '#ffffff' : '#00ff55',
    clockExpiredColor: day ? '#d60000' : '#ff3131',
    clockBorderColor: day ? '#ffffff' : '#00ff55',
    localClockColor: day ? '#ffffff' : '#00ff55',
    borderColor: day ? '#ffffff' : '#00ff55',
    songNameColor: day ? '#ffffff' : '#00ff55',
    queueNameColor: day ? '#ffffff' : '#ffea00',
    progressColor: day ? '#ffffff' : '#ffea00'
  };
  render();
  saveNow(state.slot);
}

document.getElementById('presetNight').addEventListener(
  'click', () => applyPreset('night'));
document.getElementById('presetDay').addEventListener(
  'click', () => applyPreset('day'));
document.getElementById('clearMode').addEventListener('click', () => {
  state.values[state.slot].clearMode =
    !state.values[state.slot].clearMode;
  render();
  saveNow(state.slot);
});

loadSettings();
