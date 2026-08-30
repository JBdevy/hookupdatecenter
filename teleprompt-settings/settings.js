const BRIDGE = 'http://127.0.0.1:47830';

const defaults = {
  preset: 'night',
  textColor: '#ffea00',
  textBoxColor: '#ffea00',
  clockColor: '#00ff55',
  clockExpiredColor: '#ff3131',
  clockBorderColor: '#00ff55',
  localClockColor: '#00ff55',
  localClockBorderColor: '#00ff55',
  borderColor: '#00ff55',
  songNameColor: '#00ff55',
  queueNameColor: '#ffea00',
  progressColor: '#ffea00',
  chordColor: '#fb923c',
  fontFamily: 'Arial',
  previewFontFamily: 'Arial',
  songNameFontFamily: 'Arial',
  queueNameFontFamily: 'Arial',
  chordFontFamily: 'Arial',
  textCase: 'uppercase',
  textAlignment: 'center',
  clockPosition: 'center-top',
  localClockPosition: 'right',
  songNamePosition: 'top',
  queueNamePosition: 'top',
  progressPosition: 'bottom',
  progressMode: 'lyrics',
  chordPosition: 'top',
  textScale: 1,
  clockScale: 1,
  songNameScale: 1,
  queueNameScale: 1,
  mediaScale: 1,
  previewScale: 1,
  localClockDepth: 1,
  chordScale: 1,
  windowBorderEnabled: true,
  clockBorderEnabled: true,
  localClockBorderEnabled: true,
  textBoxEnabled: true,
  clockEnabled: true,
  localClockEnabled: true,
  songNameEnabled: false,
  queueNameEnabled: true,
  progressEnabled: false,
  previewEnabled: true,
  previewSongDurationEnabled: true,
  previewBlockDurationEnabled: true,
  previewUnderlineEnabled: true,
  chordsEnabled: true,
  clearMode: false,
  rgbWindowBorderEnabled: false,
  rgbClockBorderEnabled: false,
  rgbTextBoxBorderEnabled: false,
  rgbChordBorderEnabled: false
};

const presetColors = {
  night: {
    textColor: '#ffea00',
    textBoxColor: '#ffea00',
    clockColor: '#00ff55',
    clockExpiredColor: '#ff3131',
    clockBorderColor: '#00ff55',
    localClockColor: '#00ff55',
    localClockBorderColor: '#00ff55',
    borderColor: '#00ff55',
    songNameColor: '#00ff55',
    queueNameColor: '#ffea00',
    progressColor: '#ffea00',
    chordColor: '#fb923c'
  },
  day: {
    textColor: '#ffffff',
    textBoxColor: '#ffffff',
    clockColor: '#ffffff',
    clockExpiredColor: '#d60000',
    clockBorderColor: '#ffffff',
    localClockColor: '#ffffff',
    localClockBorderColor: '#ffffff',
    borderColor: '#ffffff',
    songNameColor: '#ffffff',
    queueNameColor: '#ffffff',
    progressColor: '#ffffff',
    chordColor: '#d97706'
  }
};

function createPresetDefaults(preset, slot = 1) {
  const selectedPreset = preset === 'day' ? 'day' : 'night';
  return {
    ...defaults,
    ...presetColors[selectedPreset],
    preset: selectedPreset,
    previewEnabled: Number(slot) !== 2
  };
}

const state = {
  view: 'teleprompt',
  slot: 1,
  values: {
    1: createPresetDefaults('night', 1),
    2: createPresetDefaults('night', 2)
  },
  profiles: {
    1: {
      night: createPresetDefaults('night', 1),
      day: createPresetDefaults('day', 1)
    },
    2: {
      night: createPresetDefaults('night', 2),
      day: createPresetDefaults('day', 2)
    }
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
    textScale: 1,
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
  'localClockDepth', 'chordScale'
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
  document.querySelectorAll('[data-notice-output]').forEach((output) => {
    const key = output.dataset.noticeOutput;
    const value = state.notice[key];
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
  const selectedPreset =
    state.values[selectedSlot].preset === 'day' ? 'day' : 'night';
  state.profiles[selectedSlot][selectedPreset] = {
    ...state.values[selectedSlot],
    preset: selectedPreset
  };
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

function normalizeSlotSettings(value, slot) {
  const selectedPreset = value?.preset === 'day' ? 'day' : 'night';
  const next = {
    ...createPresetDefaults(selectedPreset, slot),
    ...(value || {}),
    preset: selectedPreset
  };
  const oldTimerPosition =
    String(next.clockPosition || '').toLowerCase();
  next.textAlignment = ['left', 'center', 'right'].includes(
    String(next.textAlignment || '').toLowerCase())
    ? String(next.textAlignment).toLowerCase()
    : 'center';
  next.progressMode =
    String(next.progressMode || '').toLowerCase() === 'chords'
      ? 'chords'
      : 'lyrics';
  if (oldTimerPosition === 'top') {
    next.clockPosition = 'center-top';
  } else if (oldTimerPosition === 'bottom') {
    next.clockPosition = 'center-bottom';
  }
  if (Number(next.localClockDepth) > 3) {
    next.localClockDepth = 1;
  }
  delete next.queueNameDepth;
  delete next.alwaysOnTop;
  const oldClockPosition =
    String(next.localClockPosition || '').toLowerCase();
  next.localClockPosition =
    oldClockPosition.includes('left') ? 'left' : 'right';
  next.textScale = Math.min(
    1, Math.max(0.5, Number(next.textScale) || 1));
  next.clockScale = Math.min(
    1.5, Math.max(0.5, Number(next.clockScale) || 1));
  next.songNameScale = Math.min(
    2, Math.max(0.5, Number(next.songNameScale) || 1));
  next.queueNameScale = Math.min(
    2, Math.max(0.5, Number(next.queueNameScale) || 1));
  next.mediaScale = Math.min(
    1.5, Math.max(0.5, Number(next.mediaScale) || 1));
  next.localClockDepth = Math.min(
    2, Math.max(0.5, Number(next.localClockDepth) || 1));
  next.chordScale = Math.min(
    1, Math.max(0.1, Number(next.chordScale) || 1));
  return next;
}

function loadSlotProfiles(slot, activeSettings, storedProfiles) {
  const active = normalizeSlotSettings(activeSettings, slot);
  const activePreset = active.preset === 'day' ? 'day' : 'night';
  const source = storedProfiles && typeof storedProfiles === 'object'
    ? storedProfiles
    : {};
  const profiles = {};
  for (const preset of ['night', 'day']) {
    const stored = source[preset] && typeof source[preset] === 'object'
      ? source[preset]
      : (preset === activePreset ? active : null);
    profiles[preset] = normalizeSlotSettings({
      ...createPresetDefaults(preset, slot),
      ...(stored || {}),
      preset
    }, slot);
  }
  state.profiles[slot] = profiles;
  state.values[slot] = { ...profiles[activePreset] };
}

async function loadSettings() {
  try {
    const response = await fetch(`${BRIDGE}/teleprompt-settings`, {
      cache: 'no-store'
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    loadSlotProfiles(1, data.tp1 || {}, data.tp1Presets);
    loadSlotProfiles(2, data.tp2 || {}, data.tp2Presets);
    state.notice = {
      ...state.notice,
      ...(data.technicalNoticeSettings || {})
    };
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
    const selectedPreset =
      state.values[state.slot].preset === 'day' ? 'day' : 'night';
    state.profiles[state.slot][selectedPreset] = {
      ...state.values[state.slot]
    };
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
        : (control.type === 'range'
          ? Number(control.value)
          : control.value);
    updateOutputs();
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

async function applyPreset(preset) {
  const selectedSlot = state.slot;
  const selectedPreset = preset === 'day' ? 'day' : 'night';
  const currentPreset =
    state.values[selectedSlot].preset === 'day' ? 'day' : 'night';
  if (selectedPreset === currentPreset) return;

  clearTimeout(state.saveTimers[selectedSlot]);
  state.saveTimers[selectedSlot] = null;
  state.profiles[selectedSlot][currentPreset] = {
    ...state.values[selectedSlot],
    preset: currentPreset
  };
  // Persiste o perfil que está saindo antes de ativar o outro.
  await saveSlot(selectedSlot);
  state.values[selectedSlot] = {
    ...state.profiles[selectedSlot][selectedPreset],
    preset: selectedPreset
  };
  render();
  await saveNow(selectedSlot);
}

document.getElementById('presetNight').addEventListener(
  'click', () => applyPreset('night'));
document.getElementById('presetDay').addEventListener(
  'click', () => applyPreset('day'));
loadSettings();
