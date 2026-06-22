const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

let state = null;
let currentYoutubeWatchUrl = "";
let pendingConfirmResolve = null;

function cleanErrorMessage(error) {
  let message = String(error?.message || error || 'Erro inesperado.');
  message = message.replace(/^Error invoking remote method '[^']+':\s*/i, '');
  message = message.replace(/^Error:\s*/i, '');
  return message.trim() || 'Erro inesperado.';
}

function friendlyError(error, fallback) {
  const message = cleanErrorMessage(error);
  const lower = message.toLowerCase();

  const technicalPatterns = [
    'osascript',
    'administrator privileges',
    'with administrator',
    'eacces',
    'eperm',
    'permission denied',
    'operation not permitted',
    'command failed',
    'execfilesync',
    'child_process',
    'sys_runtime',
    'vscore',
    'hookdeveloper',
    'application support',
    'programdata',
    '.dat',
    'base64 -d',
    'base64 -D',
    'cancelled',
    'canceled',
    'cancelado',
    'user canceled',
    'user cancelled',
    '-128'
  ];

  if (technicalPatterns.some((item) => lower.includes(item))) {
    return fallback || 'Não foi possível concluir a operação. Tente novamente.';
  }

  if (lower.includes('cpf não encontrado') || lower.includes('cpf nao encontrado')) {
    return 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF/CNPJ e o e-mail usados na compra.';
  }

  if (lower.includes('e-mail') || lower.includes('email')) {
    if (lower.includes('não encontrado') || lower.includes('nao encontrado') || lower.includes('não confere') || lower.includes('nao confere')) {
      return 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF/CNPJ e o e-mail usados na compra.';
    }
  }

  if (lower.includes('compra ativa') || lower.includes('dados informados')) {
    return 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF/CNPJ e o e-mail usados na compra.';
  }

  if (lower.includes('cancelamento da assinatura') || lower.includes('assinatura está atrasada') || lower.includes('assinatura esta atrasada') || lower.includes('licença será removido') || lower.includes('licenca sera removido') || lower.includes('terceiros') || lower.includes('compartilhamento')) {
    return message;
  }

  if (lower.includes('já possui') || lower.includes('ja possui') || lower.includes('limite') || lower.includes('computadores') || lower.includes('remova 1 dispositivo')) {
    return message;
  }

  if (lower.includes('network') || lower.includes('fetch failed') || lower.includes('failed to fetch')) {
    return 'Não foi possível verificar agora.\nVerifique sua internet e tente novamente.';
  }

  return fallback || 'Não foi possível concluir a operação. Tente novamente.';
}

function showModal({ title = 'Aviso', message = '', type = 'info' }) {
  const backdrop = $('#appModal');
  const icon = $('#modalIcon');
  $('#modalTitle').textContent = title;
  $('#modalMessage').textContent = message;
  icon.className = `modal-icon ${type}`;
  icon.textContent = type === 'success' ? '✓' : (type === 'error' ? '×' : 'i');
  backdrop.classList.remove('hidden');
  $('#modalOkButton').focus();
}

function hideModal() {
  $('#appModal').classList.add('hidden');
  const okButton = $('#modalOkButton');
  const cancelButton = $('#modalCancelButton');
  if (okButton) okButton.textContent = 'OK';
  if (cancelButton) cancelButton.classList.add('hidden');
  if (pendingConfirmResolve) {
    const resolve = pendingConfirmResolve;
    pendingConfirmResolve = null;
    resolve(false);
  }
}

function confirmModal({ title = 'Confirmar', message = '', type = 'info', okText = 'Continuar', cancelText = 'Cancelar' }) {
  return new Promise((resolve) => {
    pendingConfirmResolve = resolve;
    showModal({ title, message, type });
    const okButton = $('#modalOkButton');
    const cancelButton = $('#modalCancelButton');
    okButton.textContent = okText;
    cancelButton.textContent = cancelText;
    cancelButton.classList.remove('hidden');
  });
}

function openVideoModal() {
  if (!currentYoutubeWatchUrl) {
    showModal({
      title: 'Vídeo indisponível',
      message: 'Nenhum vídeo foi publicado para esta atualização.',
      type: 'error'
    });
    return;
  }

  $('#youtubeWebview').src = currentYoutubeWatchUrl;
  $('#videoModal').classList.remove('hidden');
}

function closeVideoModal() {
  $('#youtubeWebview').src = 'about:blank';
  $('#videoModal').classList.add('hidden');
}

function showSupportQrModal({ qrSvg = '', url = '' } = {}) {
  const modal = $('#supportQrModal');
  const qr = $('#supportQrCode');
  if (!modal || !qr) return;
  qr.innerHTML = qrSvg || '';
  if (!qrSvg && url) {
    qr.textContent = url;
  }
  modal.classList.remove('hidden');
  $('#supportQrCloseButton')?.focus();
}

function closeSupportQrModal() {
  $('#supportQrModal')?.classList.add('hidden');
  const qr = $('#supportQrCode');
  if (qr) qr.innerHTML = '';
}

function updateDownloadCompactMode() {
  const isHomeActive = $('#homeView')?.classList.contains('active');
  const progressVisible = !$('#homeProgressArea')?.classList.contains('hidden');
  document.body.classList.toggle('download-compact', !!isHomeActive && !!progressVisible);
}

function setProgressVisible(visible) {
  $('#homeProgressArea')?.classList.toggle('hidden', !visible);
  $('#statusProgressCard')?.classList.toggle('hidden', !visible);
  updateDownloadCompactMode();
}

function resetVsHookProgress() {
  ['#progressBar', '#statusProgressBar'].forEach((selector) => {
    const el = $(selector);
    if (el) el.style.width = '0%';
  });
  ['#progressText', '#statusProgressText'].forEach((selector) => {
    const el = $(selector);
    if (el) el.textContent = '0%';
  });
  $('#installButton')?.classList.add('hidden');
  $('#statusInstallButton')?.classList.add('hidden');
}

function updateVsHookProgress(progress) {
  const safeProgress = Math.max(0, Math.min(100, Number(progress) || 0));
  ['#progressBar', '#statusProgressBar'].forEach((selector) => {
    const el = $(selector);
    if (el) el.style.width = `${safeProgress}%`;
  });
  ['#progressText', '#statusProgressText'].forEach((selector) => {
    const el = $(selector);
    if (el) el.textContent = `${safeProgress}%`;
  });
  if (safeProgress >= 100) {
    $('#installButton')?.classList.remove('hidden');
    $('#statusInstallButton')?.classList.remove('hidden');
  }
}

async function startVsHookDownload(updateOverride = null) {
  try {
    if (!(await ensureDeviceName())) return;
    setProgressVisible(true);
    resetVsHookProgress();
    const buttons = [$('#downloadButton'), $('#statusDownloadButton')].filter(Boolean);
    buttons.forEach((button) => {
      button.disabled = true;
      button.dataset.originalText = button.textContent;
      button.textContent = 'Baixando...';
    });
    await window.hookUpdateCenter.downloadUpdate(updateOverride ? { update: updateOverride } : undefined);
  } catch (error) {
    showModal({ title: 'Erro no download', message: friendlyError(error, 'Não foi possível baixar a atualização.'), type: 'error' });
  } finally {
    [$('#downloadButton'), $('#statusDownloadButton')].filter(Boolean).forEach((button) => {
      button.disabled = false;
      button.textContent = button.dataset.originalText || 'Baixar atualização';
      delete button.dataset.originalText;
    });
  }
}

async function installVsHookDownloadedUpdate() {
  const confirmed = await confirmModal({
    title: 'Instalar VS Hook',
    message: 'Feche o REAPER antes de continuar. O Hook Center vai instalar o VS Hook e os arquivos necessários.',
    type: 'info',
    okText: 'Instalar',
    cancelText: 'Cancelar'
  });

  if (!confirmed) return;

  try {
    const result = await window.hookUpdateCenter.installUpdate();
    if (result.ok) {
      renderState(await window.hookUpdateCenter.getState());
      setProgressVisible(false);
      resetVsHookProgress();
      showModal({ title: 'Instalação concluída', message: `${result.installedVersion || 'VS Hook'} foi instalado com sucesso.`, type: 'success' });
    }
  } catch (error) {
    showModal({ title: 'Erro ao instalar', message: friendlyError(error, 'Não foi possível instalar a atualização.'), type: 'error' });
  }
}


function setView(viewName) {
  $$('.nav-item').forEach((button) => button.classList.toggle('active', button.dataset.view === viewName));
  $$('.view').forEach((view) => view.classList.remove('active'));
  $(`#${viewName}View`).classList.add('active');
  document.body.classList.toggle('bridge-mode', viewName === 'bridge');
  document.body.classList.toggle('previous-mode', viewName === 'previous');
  document.body.classList.toggle('lyrics-mode', viewName === 'lyrics');
  updateDownloadCompactMode();
}

function formatDate(value) {
  if (!value) return '--';
  return new Date(value).toLocaleString('pt-BR');
}

function extractYoutubeId(url) {
  const value = String(url || '').trim();
  if (!value) return '';

  const embedMatch = value.match(/youtube\.com\/embed\/([^?&/]+)/i);
  if (embedMatch) return embedMatch[1];

  const watchMatch = value.match(/[?&]v=([^&]+)/i);
  if (watchMatch) return watchMatch[1];

  const shortMatch = value.match(/youtu\.be\/([^?&/]+)/i);
  if (shortMatch) return shortMatch[1];

  const shortsMatch = value.match(/youtube\.com\/shorts\/([^?&/]+)/i);
  if (shortsMatch) return shortsMatch[1];

  return '';
}

function normalizeYoutubeWatchUrl(url) {
  const id = extractYoutubeId(url);
  if (id) return `https://www.youtube.com/watch?v=${id}`;
  return String(url || '').trim();
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}




function normalizeLyricsScreenPosition(value, fallback = 'top') {
  const v = String(value || '').trim().toLowerCase();
  if (v === 'bottom' || v === 'below' || v === 'baixo' || v === 'down') return 'bottom';
  if (v === 'top' || v === 'above' || v === 'cima' || v === 'up') return 'top';
  return fallback;
}

function applyLyricsSettingsToForm(settings = {}) {
  const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj || {}, key);
  const isSlotMap = hasOwn(settings, 1) || hasOwn(settings, '1') || hasOwn(settings, 2) || hasOwn(settings, '2');
  const all = isSlotMap ? settings : { 1: settings, 2: settings };
  const slots = isSlotMap ? [1, 2].filter((slot) => hasOwn(all, slot) || hasOwn(all, String(slot))) : [1, 2];
  slots.forEach((slot) => {
    const data = all[slot] || all[String(slot)] || {};
    if (!data || typeof data !== 'object') return;
    const textColor = $(`#lyricsTextColor${slot}`);
    const clockColor = $(`#lyricsClockColor${slot}`);
    const textBoxColor = $(`#lyricsTextBoxColor${slot}`);
    const borderColor = $(`#lyricsBorderColor${slot}`);
    const rgbBorderEnabled = $(`#lyricsRgbBorderEnabled${slot}`);
    const rgbWindowBorderEnabled = $(`#lyricsRgbWindowBorderEnabled${slot}`);
    const rgbClockBorderEnabled = $(`#lyricsRgbClockBorderEnabled${slot}`);
    const rgbTextBoxBorderEnabled = $(`#lyricsRgbTextBoxBorderEnabled${slot}`);
    const fontFamily = $(`#lyricsFontFamily${slot}`);
    const textScale = $(`#lyricsTextScale${slot}`);
    const borderEnabled = $(`#lyricsBorderEnabled${slot}`);
    const windowBorderEnabled = $(`#lyricsWindowBorderEnabled${slot}`);
    const clockBorderEnabled = $(`#lyricsClockBorderEnabled${slot}`);
    const textBoxEnabled = $(`#lyricsTextBoxEnabled${slot}`);
    const clockEnabled = $(`#lyricsClockEnabled${slot}`);
    const songNameEnabled = $(`#lyricsSongNameEnabled${slot}`);
    const songNameColor = $(`#lyricsSongNameColor${slot}`);
    const songNameFontFamily = $(`#lyricsSongNameFontFamily${slot}`);
    const songNameScale = $(`#lyricsSongNameScale${slot}`);
    const songNamePosition = $(`#lyricsSongNamePosition${slot}`);
    const clockPosition = $(`#lyricsClockPosition${slot}`);
    const clockScale = $(`#lyricsClockScale${slot}`);
    const mediaScale = $(`#lyricsMediaScale${slot}`);
    const clearModeButton = $(`#lyricsClearModeButton${slot}`);
    if (textColor) textColor.value = data.textColor || '#ffea00';
    if (clockColor) clockColor.value = data.clockColor || '#00ff55';
    if (textBoxColor) textBoxColor.value = data.textBoxColor || data.textColor || '#ffea00';
    if (borderColor) borderColor.value = data.borderColor || data.clockColor || '#00ff55';
    const legacyRgb = data.rgbBorderEnabled === true;
    if (rgbBorderEnabled) rgbBorderEnabled.checked = legacyRgb;
    if (rgbWindowBorderEnabled) rgbWindowBorderEnabled.checked = (data.rgbWindowBorderEnabled ?? legacyRgb) === true;
    if (rgbClockBorderEnabled) rgbClockBorderEnabled.checked = data.rgbClockBorderEnabled === true;
    if (rgbTextBoxBorderEnabled) rgbTextBoxBorderEnabled.checked = data.rgbTextBoxBorderEnabled === true;
    if (fontFamily) fontFamily.value = data.fontFamily || 'Arial';
    if (textScale) textScale.value = String(Math.round((Number(data.textScale || 1) || 1) * 100));
    if (borderEnabled) borderEnabled.checked = data.borderEnabled !== false;
    if (windowBorderEnabled) windowBorderEnabled.checked = data.windowBorderEnabled ?? data.borderEnabled ?? true;
    if (clockBorderEnabled) clockBorderEnabled.checked = data.clockBorderEnabled ?? data.borderEnabled ?? true;
    if (textBoxEnabled) textBoxEnabled.checked = data.textBoxEnabled ?? true;
    if (clockEnabled) clockEnabled.checked = data.clockEnabled !== false;
    if (songNameEnabled) songNameEnabled.checked = data.songNameEnabled === true;
    if (songNameColor) songNameColor.value = data.songNameColor || data.clockColor || '#00ff55';
    if (songNameFontFamily) songNameFontFamily.value = data.songNameFontFamily || data.fontFamily || 'Arial';
    if (songNameScale) songNameScale.value = String(Math.round((Number(data.songNameScale || 1) || 1) * 100));
    if (songNamePosition) songNamePosition.value = normalizeLyricsScreenPosition(data.songNamePosition, 'top');
    if (clockPosition) clockPosition.value = data.clockPosition === 'bottom' ? 'bottom' : 'top';
    if (clockScale) clockScale.value = String(Math.round((Number(data.clockScale || 1) || 1) * 100));
    if (mediaScale) mediaScale.value = String(Math.round((Number(data.mediaScale || 1) || 1) * 100));
    if (clearModeButton) {
      const active = data.clearMode === true;
      clearModeButton.classList.toggle('active', active);
      clearModeButton.setAttribute('aria-pressed', active ? 'true' : 'false');
      clearModeButton.textContent = active ? 'Modo Clear ON' : 'Modo Clear';
    }
  });
}

function applyTechnicalNoticeSettingsToForm(settings = {}) {
  const textColor = $('#technicalNoticeTextColor');
  const flashColor = $('#technicalNoticeFlashColor');
  const fontFamily = $('#technicalNoticeFontFamily');
  const window1Enabled = $('#technicalNoticeWindow1Enabled');
  const window2Enabled = $('#technicalNoticeWindow2Enabled');
  const emojiEnabled = $('#technicalNoticeEmojiEnabled');
  const emojiInput = $('#technicalNoticeEmoji');
  const emojiPreview = $('#technicalNoticeEmojiPreview');
  const emojiButton = $('#technicalNoticeEmojiPickerButton');
  const emoji = String(settings.emoji || '⚠️').trim().replace(/[\r\n\t]+/g, '').slice(0, 8) || '⚠️';
  if (textColor) textColor.value = settings.textColor || '#ffea00';
  if (flashColor) flashColor.value = settings.flashColor || '#ff0000';
  if (fontFamily) fontFamily.value = settings.fontFamily || 'Arial';
  if (window1Enabled) window1Enabled.checked = settings.window1Enabled !== false;
  if (window2Enabled) window2Enabled.checked = settings.window2Enabled !== false;
  if (emojiEnabled) emojiEnabled.checked = settings.emojiEnabled !== false;
  if (emojiInput) emojiInput.value = emoji;
  if (emojiPreview) emojiPreview.textContent = emoji;
  if (emojiButton) emojiButton.setAttribute('aria-label', `Emoji do recado: ${emoji}`);
}

async function refreshLyricsSettings() {
  try {
    applyLyricsSettingsToForm(await window.hookUpdateCenter.getLyricsSettings());
  } catch (_) {}
  try {
    applyTechnicalNoticeSettingsToForm(await window.hookUpdateCenter.getTechnicalNoticeSettings());
  } catch (_) {}
}

async function saveLyricsSettingsFromForm(slot = 1) {
  const id = Number(slot) === 2 ? 2 : 1;
  const payload = {
    slot: id,
    textColor: $(`#lyricsTextColor${id}`)?.value || '#ffea00',
    clockColor: $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    textBoxColor: $(`#lyricsTextBoxColor${id}`)?.value || $(`#lyricsTextColor${id}`)?.value || '#ffea00',
    borderColor: $(`#lyricsBorderColor${id}`)?.value || $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    rgbBorderEnabled: $(`#lyricsRgbWindowBorderEnabled${id}`)?.checked === true,
    rgbWindowBorderEnabled: $(`#lyricsRgbWindowBorderEnabled${id}`)?.checked === true,
    rgbClockBorderEnabled: $(`#lyricsRgbClockBorderEnabled${id}`)?.checked === true,
    rgbTextBoxBorderEnabled: $(`#lyricsRgbTextBoxBorderEnabled${id}`)?.checked === true,
    fontFamily: $(`#lyricsFontFamily${id}`)?.value || 'Arial',
    textScale: Math.max(0.5, Math.min(1.25, (Number($(`#lyricsTextScale${id}`)?.value || 100) / 100))),
    borderEnabled: $(`#lyricsWindowBorderEnabled${id}`)?.checked !== false,
    windowBorderEnabled: $(`#lyricsWindowBorderEnabled${id}`)?.checked !== false,
    clockBorderEnabled: $(`#lyricsClockBorderEnabled${id}`)?.checked !== false,
    textBoxEnabled: $(`#lyricsTextBoxEnabled${id}`)?.checked !== false,
    clockEnabled: $(`#lyricsClockEnabled${id}`)?.checked !== false,
    songNameEnabled: $(`#lyricsSongNameEnabled${id}`)?.checked === true,
    songNameColor: $(`#lyricsSongNameColor${id}`)?.value || $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    songNameFontFamily: $(`#lyricsSongNameFontFamily${id}`)?.value || $(`#lyricsFontFamily${id}`)?.value || 'Arial',
    songNameScale: Math.max(0.5, Math.min(3, (Number($(`#lyricsSongNameScale${id}`)?.value || 100) / 100))),
    songNamePosition: normalizeLyricsScreenPosition($(`#lyricsSongNamePosition${id}`)?.value, 'top'),
    clockPosition: $(`#lyricsClockPosition${id}`)?.value === 'bottom' ? 'bottom' : 'top',
    clockScale: Math.max(0.5, Math.min(2.5, (Number($(`#lyricsClockScale${id}`)?.value || 100) / 100))),
    mediaScale: Math.max(0.5, Math.min(1, (Number($(`#lyricsMediaScale${id}`)?.value || 100) / 100))),
    clearMode: $(`#lyricsClearModeButton${id}`)?.getAttribute('aria-pressed') === 'true'
  };
  const saved = await window.hookUpdateCenter.saveLyricsSettings(payload);
  // Atualiza apenas o slot salvo; nunca reaplica defaults na outra janela.
  applyLyricsSettingsToForm({ [id]: saved });
  return saved;
}

async function saveTechnicalNoticeSettingsFromForm() {
  const payload = {
    textColor: $('#technicalNoticeTextColor')?.value || '#ffea00',
    flashColor: $('#technicalNoticeFlashColor')?.value || '#ff0000',
    fontFamily: $('#technicalNoticeFontFamily')?.value || 'Arial',
    window1Enabled: $('#technicalNoticeWindow1Enabled')?.checked !== false,
    window2Enabled: $('#technicalNoticeWindow2Enabled')?.checked !== false,
    emojiEnabled: $('#technicalNoticeEmojiEnabled')?.checked !== false,
    emoji: ($('#technicalNoticeEmoji')?.value || '⚠️').trim().slice(0, 8) || '⚠️'
  };
  const saved = await window.hookUpdateCenter.saveTechnicalNoticeSettings(payload);
  applyTechnicalNoticeSettingsToForm(saved);
  return saved;
}


const lyricsAutoApplyTimers = { 1: null, 2: null, technical: null };
async function autoSaveLyricsSettings(slot) {
  const id = Number(slot) === 2 ? 2 : 1;
  clearTimeout(lyricsAutoApplyTimers[id]);
  lyricsAutoApplyTimers[id] = setTimeout(async () => {
    try {
      await saveLyricsSettingsFromForm(id);
    } catch (error) {
      console.warn('Auto-save Teleprompt settings failed', error);
    }
  }, 80);
}

async function autoSaveTechnicalNoticeSettings() {
  clearTimeout(lyricsAutoApplyTimers.technical);
  lyricsAutoApplyTimers.technical = setTimeout(async () => {
    try {
      await saveTechnicalNoticeSettingsFromForm();
    } catch (error) {
      console.warn('Auto-save technical notice settings failed', error);
    }
  }, 100);
}


function setupTechnicalNoticeEmojiPicker() {
  const button = $('#technicalNoticeEmojiPickerButton');
  const popover = $('#technicalNoticeEmojiPicker');
  const input = $('#technicalNoticeEmoji');
  const preview = $('#technicalNoticeEmojiPreview');
  if (!button || !popover || !input || popover.dataset.ready === '1') return;

  const emojis = [
    '⚠️', '✅', '❌', '🔔', '📢', '🎵', '🎶', '🔥',
    '⭐', '✨', '💡', '🙏', '🙌', '👀', '⏰', '🚨',
    '🎤', '🎧', '🎹', '🥁', '🎸', '🎺', '📌', '➡️',
    '⬅️', '⬆️', '⬇️', '🟢', '🟡', '🔴', '🔵', '🟣'
  ];

  popover.innerHTML = emojis.map((emoji) => (
    `<button class="emoji-option" type="button" data-emoji="${emoji}" role="option">${emoji}</button>`
  )).join('');

  const closePicker = () => {
    popover.classList.add('hidden');
    button.setAttribute('aria-expanded', 'false');
  };

  const openPicker = () => {
    popover.classList.remove('hidden');
    button.setAttribute('aria-expanded', 'true');
  };

  button.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (popover.classList.contains('hidden')) openPicker();
    else closePicker();
  });

  popover.querySelectorAll('.emoji-option').forEach((option) => {
    option.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const emoji = option.dataset.emoji || '⚠️';
      input.value = emoji;
      if (preview) preview.textContent = emoji;
      closePicker();
      autoSaveTechnicalNoticeSettings();
    });
  });

  document.addEventListener('click', (event) => {
    if (popover.classList.contains('hidden')) return;
    if (popover.contains(event.target) || button.contains(event.target)) return;
    closePicker();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closePicker();
  });

  popover.dataset.ready = '1';
}

function setupLyricsAutoApply() {
  setupTechnicalNoticeEmojiPicker();
  [1, 2].forEach((slot) => {
    const ids = [
      `lyricsTextColor${slot}`,
      `lyricsClockColor${slot}`,
      `lyricsTextBoxColor${slot}`,
      `lyricsBorderColor${slot}`, 
      `lyricsRgbWindowBorderEnabled${slot}`,
      `lyricsRgbClockBorderEnabled${slot}`,
      `lyricsRgbTextBoxBorderEnabled${slot}`,
      `lyricsFontFamily${slot}`,
      `lyricsTextScale${slot}`,
      `lyricsBorderEnabled${slot}`,
      `lyricsWindowBorderEnabled${slot}`,
      `lyricsClockBorderEnabled${slot}`,
      `lyricsTextBoxEnabled${slot}`,
      `lyricsClockEnabled${slot}`,
      `lyricsSongNameEnabled${slot}`,
      `lyricsSongNameColor${slot}`,
      `lyricsSongNameFontFamily${slot}`,
      `lyricsSongNameScale${slot}`,
      `lyricsSongNamePosition${slot}`,
      `lyricsClockPosition${slot}`,
      `lyricsClockScale${slot}`,
      `lyricsMediaScale${slot}`,
      `lyricsClearModeButton${slot}`
    ];
    ids.forEach((id) => {
      const el = $(`#${id}`);
      if (!el || el.dataset.autoApplyLyrics === '1') return;
      el.dataset.autoApplyLyrics = '1';
      if (el.classList && el.classList.contains('clear-mode-button')) {
        el.addEventListener('click', () => {
          const active = el.getAttribute('aria-pressed') === 'true';
          el.setAttribute('aria-pressed', active ? 'false' : 'true');
          el.classList.toggle('active', !active);
          el.textContent = !active ? 'Modo Clear ON' : 'Modo Clear';
          autoSaveLyricsSettings(slot);
        });
        return;
      }
      const eventName = el.type === 'range' || el.type === 'color' ? 'input' : 'change';
      el.addEventListener(eventName, () => autoSaveLyricsSettings(slot));
      if (eventName !== 'change') el.addEventListener('change', () => autoSaveLyricsSettings(slot));
    });
  });

  ['technicalNoticeTextColor', 'technicalNoticeFlashColor', 'technicalNoticeFontFamily', 'technicalNoticeWindow1Enabled', 'technicalNoticeWindow2Enabled', 'technicalNoticeEmojiEnabled'].forEach((id) => {
    const el = $(`#${id}`);
    if (!el || el.dataset.autoApplyNotice === '1') return;
    el.dataset.autoApplyNotice = '1';
    const eventName = (el.type === 'color' || el.type === 'text') ? 'input' : 'change';
    el.addEventListener(eventName, autoSaveTechnicalNoticeSettings);
    if (eventName !== 'change') el.addEventListener('change', autoSaveTechnicalNoticeSettings);
  });
}

function renderBridgeState(bridge) {
  if (!bridge) return;
  const runningText = $('#bridgeRunningText');
  if (runningText) {
    runningText.textContent = bridge.running ? 'Conexão ativa. O Hook Center já está funcionando.' : (bridge.error ? 'Conexão parada. Clique em Reiniciar conexão e tente novamente.' : 'Conexão parada.');
    runningText.classList.toggle('ok-text', !!bridge.running);
  }
  const bridgeAddressEl = $('#bridgeLanIp');
  if (bridgeAddressEl) {
    const port = bridge.directorPort || 47831;
    const shortAddress = bridge.lanIp ? `${bridge.lanIp}:${port}` : '';
    const fullAddress = bridge.directorUrl || (bridge.lanIp ? `http://${bridge.lanIp}:${port}` : '');
    bridgeAddressEl.textContent = shortAddress || '--';
    bridgeAddressEl.title = fullAddress || shortAddress || '';
  }
  const qrImage = $('#browserQrImage');
  if (qrImage) {
    if (bridge.qrCodeUrl && bridge.running) {
      qrImage.src = `${bridge.qrCodeUrl}&t=${Date.now()}`;
      qrImage.classList.remove('hidden');
    } else {
      qrImage.removeAttribute('src');
      qrImage.classList.add('hidden');
    }
  }
  if ($('#bridgeDirectorPort')) $('#bridgeDirectorPort').textContent = String(bridge.directorPort || '--');
  if ($('#bridgeMusiciansPort')) $('#bridgeMusiciansPort').textContent = String(bridge.musiciansPort || '--');
  if ($('#bridgeScriptsDir')) $('#bridgeScriptsDir').textContent = bridge.scriptsDir || '--';
}


function getLicenseDevices() {
  const license = state?.license || {}
  return Array.isArray(license.devices) ? license.devices : []
}

function renderDevices() {
  if (!state) return
  const license = state.license || {}
  const devices = getLicenseDevices()
  const email = license.email || state.deviceLoginEmail || ''
  const deviceName = state.deviceName || ''
  const devicesEmailInput = $('#devicesEmailInput')
  const devicesNameInput = $('#devicesNameInput')
  const deviceNameInlineInput = $('#deviceNameInlineInput')
  if (devicesEmailInput && !devicesEmailInput.value) devicesEmailInput.value = email
  if (devicesNameInput) devicesNameInput.value = deviceName
  if (deviceNameInlineInput) deviceNameInlineInput.value = deviceName
  if ($('#devicesUsedText')) $('#devicesUsedText').textContent = String(license.devicesUsed ?? devices.length ?? '--')
  if ($('#devicesLimitText')) $('#devicesLimitText').textContent = String(license.maxDevices ?? '--')
  const current = devices.find((d) => d.current)
  if ($('#currentDeviceStatusText')) $('#currentDeviceStatusText').textContent = current ? 'Ativado' : 'Não ativado'
  const list = $('#devicesList')
  if (!list) return
  if (!devices.length) {
    list.innerHTML = '<p class="muted">Nenhum dispositivo carregado.</p>'
    return
  }
  list.innerHTML = devices.map((device) => {
    const name = escapeHtml(device.name || device.computerName || 'Dispositivo')
    const platform = escapeHtml(device.platform || '')
    const lastSeen = device.lastSeenAt ? formatDate(device.lastSeenAt) : '--'
    const machineId = escapeHtml(device.machineId || device.id || '')
    return `<div class="device-row ${device.current ? 'current-device' : ''}"><div><strong>${name}</strong><span>${platform || 'Sistema'} • ${lastSeen}${device.current ? ' • este computador' : ''}</span></div><button class="secondary-button device-remove-button" data-remove-device="${machineId}">Remover</button></div>`
  }).join('')
  list.querySelectorAll('[data-remove-device]').forEach((button) => {
    button.addEventListener('click', async () => {
      const machineId = button.getAttribute('data-remove-device')
      const isCurrentDevice = button.closest('.device-row')?.classList.contains('current-device')
      const ok = await confirmModal({
        title: isCurrentDevice ? 'Remover este computador' : 'Remover dispositivo',
        message: isCurrentDevice
          ? 'Este computador será removido da licença agora. Para usar o VS Hook novamente nele, será necessário ativar de novo.'
          : 'Remover este computador da licença?',
        type:'info',
        okText:'Remover',
        cancelText:'Cancelar'
      })
      if (!ok) return
      try {
        const result = await window.hookUpdateCenter.removeLicenseDevice({ machineId, email: $('#devicesEmailInput')?.value || email })
        renderState(result.state || await window.hookUpdateCenter.getState())
        $('#devicesMessage').textContent = isCurrentDevice ? 'Este computador foi removido da licença.' : 'Dispositivo removido.'
        if (isCurrentDevice) {
          showModal({ title:'Computador removido', message:'Este computador foi removido da licença. Para usar o VS Hook novamente nele, faça uma nova ativação.', type:'info' })
        }
      } catch (error) {
        showModal({ title:'Dispositivos', message:friendlyError(error, 'Não foi possível remover o dispositivo. Tente novamente.'), type:'error' })
      }
    })
  })
}

function promptDeviceNameModal(initialValue = '') {
  return new Promise((resolve) => {
    const backdrop = $('#deviceNameModal')
    const input = $('#deviceNameModalInput')
    const error = $('#deviceNameModalError')
    if (!backdrop || !input) return resolve('')
    input.value = initialValue || state?.deviceName || ''
    error.textContent = ''
    backdrop.classList.remove('hidden')
    setTimeout(() => input.focus(), 30)
    const cleanup = (value) => {
      backdrop.classList.add('hidden')
      $('#deviceNameModalSave')?.removeEventListener('click', onSave)
      $('#deviceNameModalCancel')?.removeEventListener('click', onCancel)
      input.removeEventListener('keydown', onKey)
      resolve(value)
    }
    const onSave = async () => {
      const value = input.value.trim()
      if (!value) { error.textContent = 'Digite um nome para este dispositivo.'; return }
      try {
        const result = await window.hookUpdateCenter.setDeviceName({ deviceName: value })
        renderState(result.state || await window.hookUpdateCenter.getState())
        cleanup(value)
      } catch (error) {
        error.textContent = friendlyError(error, 'Ocorreu um erro. Contate o suporte.')
      }
    }
    const onCancel = () => cleanup('')
    const onKey = (event) => { if (event.key === 'Enter') onSave(); if (event.key === 'Escape') onCancel() }
    $('#deviceNameModalSave')?.addEventListener('click', onSave)
    $('#deviceNameModalCancel')?.addEventListener('click', onCancel)
    input.addEventListener('keydown', onKey)
  })
}

async function ensureDeviceName() {
  const current = String(state?.deviceName || '').trim()
  if (current) return current
  return await promptDeviceNameModal(current)
}

function promptDeviceLoginModal() {
  return new Promise((resolve) => {
    const backdrop = $('#deviceLoginModal')
    const input = $('#deviceLoginModalEmail')
    const error = $('#deviceLoginModalError')
    if (!backdrop || !input) return resolve(false)
    input.value = state?.deviceLoginEmail || state?.license?.email || ''
    error.textContent = ''
    backdrop.classList.remove('hidden')
    setTimeout(() => input.focus(), 30)
    const cleanup = (ok) => {
      backdrop.classList.add('hidden')
      $('#deviceLoginModalEnter')?.removeEventListener('click', onEnter)
      $('#deviceLoginModalLater')?.removeEventListener('click', onLater)
      input.removeEventListener('keydown', onKey)
      resolve(ok)
    }
    const onEnter = async () => {
      const email = input.value.trim()
      if (!email || !email.includes('@')) { error.textContent = 'Digite o e-mail usado na compra.'; return }
      try {
        const result = await window.hookUpdateCenter.loginLicenseDevices({ email })
        renderState(result.state || await window.hookUpdateCenter.getState())
        const msg = result?.result?.message || 'Login realizado.'
        if (result?.result?.reason === 'device_limit') {
          setView('devices')
          showModal({ title:'Remova 1 dispositivo', message:msg, type:'error' })
        }
        cleanup(true)
      } catch (error) {
        error.textContent = friendlyError(error, 'Ocorreu um erro. Contate o suporte.')
      }
    }
    const onLater = () => cleanup(false)
    const onKey = (event) => { if (event.key === 'Enter') onEnter(); if (event.key === 'Escape') onLater() }
    $('#deviceLoginModalEnter')?.addEventListener('click', onEnter)
    $('#deviceLoginModalLater')?.addEventListener('click', onLater)
    input.addEventListener('keydown', onKey)
  })
}


function updateLyricsWindowButtons() {
  const windows = state?.lyricsWindows || {};
  const oneOpen = !!windows.oneOpen;
  const twoOpen = !!windows.twoOpen;
  const oneButton = $('#openLyricsOneButton');
  const twoButton = $('#openLyricsTwoButton');
  if (oneButton) {
    oneButton.textContent = oneOpen ? 'Fechar Teleprompt 1' : 'Abrir Teleprompt 1';
    oneButton.classList.toggle('danger-button', oneOpen);
  }
  if (twoButton) {
    twoButton.textContent = twoOpen ? 'Fechar Teleprompt 2' : 'Abrir Teleprompt 2';
    twoButton.classList.toggle('danger-button', twoOpen);
  }
}

function isTestClientUpdate(update) {
  if (!update) return false;
  const source = String(update.source || update.origin || '').toLowerCase();
  return Boolean(
    update.testClient ||
    update.isTestClient ||
    update.clientTest ||
    update.test_client ||
    source === 'test-client' ||
    source === 'cliente-teste'
  );
}

function renderState(nextState) {
  state = nextState;
  updateLyricsWindowButtons();
  const isMac = state.platform === 'darwin';
  const macLabel = state.arch === 'arm64' ? 'macOS Apple Silicon' : 'macOS Intel';

  $('#platformLabel').textContent = isMac ? macLabel : 'Windows 10/11';
  $('#currentVersion').textContent = state.currentVersion ? `v${String(state.currentVersion).replace(/^v/i, '')}` : 'v1.9.5';
  const installedVersionLabel = state.installedVsHookVersion ? `v${String(state.installedVsHookVersion).replace(/^v/i, '')}` : '--';
  const installedVersionEl = $('#installedVsHookVersion');
  if (installedVersionEl) installedVersionEl.textContent = installedVersionLabel;
  const homeInstalledVersionAlwaysEl = $('#homeInstalledVsHookVersionAlways');
  if (homeInstalledVersionAlwaysEl) homeInstalledVersionAlwaysEl.textContent = installedVersionLabel;
  const statusInstalledVersionEl = $('#statusInstalledVsHookVersion');
  if (statusInstalledVersionEl) statusInstalledVersionEl.textContent = installedVersionLabel;
  const statusUpdateInstalledVersionEl = $('#statusUpdateInstalledVersion');
  if (statusUpdateInstalledVersionEl) statusUpdateInstalledVersionEl.textContent = installedVersionLabel;
  const machineIdCodeEl = $('#machineIdCode');
  if (machineIdCodeEl) machineIdCodeEl.textContent = state.machineId || state.license?.machineId || '--';
  $('#lastCheck').textContent = formatDate(state.lastCheck);
  const statusTestUpdate = isTestClientUpdate(state.latestUpdate) ? state.latestUpdate : null;
  $('#updateStatus').textContent = statusTestUpdate ? 'Atualização de cliente teste disponível' : 'Sem atualização de cliente teste';

  const hc = state.hookCenterLatest || {};
  const hcText = $('#hookCenterUpdateText');
  const hcButton = $('#hookCenterUpdateButton');
  const hcActions = $('#hookCenterUpdateActions');
  const hcLearnCard = $('#hookCenterLearnCard');
  const hcLearnButton = $('#hookCenterLearnButton');
  const hasTutorial = !!(hc.tutorialUrl || hc.learnUrl || hc.videoUrl);
  if (hcLearnCard) hcLearnCard.classList.remove('hidden');
  if (hcLearnButton) {
    hcLearnButton.disabled = !hasTutorial;
    hcLearnButton.textContent = 'Assistir agora';
    hcLearnButton.removeAttribute('title');
  }
  if (hcText && hcButton) {
    if (state.hookCenterUpdateAvailable) {
      hcText.textContent = `Nova versão disponível: ${hc.version || ''}. ${hc.notes || ''}`.trim();
      hcButton.classList.remove('hidden');
      hcActions?.classList.remove('hidden');
    } else if (hc.version) {
      hcText.textContent = `Hook Center atualizado. Última versão publicada: ${hc.version}.`;
      hcButton.classList.add('hidden');
      hcActions?.classList.add('hidden');
    } else {
      hcText.textContent = 'Nenhuma atualização do Hook Center publicada.';
      hcButton.classList.add('hidden');
      hcActions?.classList.add('hidden');
    }
  }

  const hasLatest = !!state.latestUpdate;
  const hasStatusTestUpdate = !!statusTestUpdate;
  $('#noUpdateCard').classList.toggle('hidden', hasLatest);
  $('#updateCard').classList.toggle('hidden', !hasLatest);
  $('#statusNoUpdateInstallCard')?.classList.toggle('hidden', hasStatusTestUpdate);
  $('#statusUpdateInstallCard')?.classList.toggle('hidden', !hasStatusTestUpdate);

  if (hasLatest) {
    const update = state.latestUpdate;
    const displayTitle = update.title || `VS Hook ${update.version || ''}`;
    const displayVersion = update.version ? `v${update.version}` : 'VS Hook';
    $('#updateTitle').textContent = displayTitle;
    $('#versionBadge').textContent = displayVersion;
    $('#updateDescription').textContent = update.description || '';

    const rawYoutubeUrl = update.youtubeUrl || '';
    currentYoutubeWatchUrl = normalizeYoutubeWatchUrl(rawYoutubeUrl);
    $('#videoBox').classList.toggle('hidden', !currentYoutubeWatchUrl);
    $('#videoModalTitle').textContent = displayTitle;

    const changelog = Array.isArray(update.changelog) ? update.changelog : [];
    $('#changelogList').innerHTML = changelog.map((item) => `<li>${escapeHtml(item)}</li>`).join('');
  }

  if (hasStatusTestUpdate) {
    const update = statusTestUpdate;
    const displayTitle = update.title || `VS Hook ${update.version || ''}`;
    const displayVersion = update.version ? `v${update.version}` : 'VS Hook';
    const statusTitle = $('#statusUpdateTitle');
    if (statusTitle) statusTitle.textContent = displayTitle;
    const statusBadge = $('#statusVersionBadge');
    if (statusBadge) statusBadge.textContent = displayVersion;
    const statusDescription = $('#statusUpdateDescription');
    if (statusDescription) statusDescription.textContent = update.description || '';
    const statusDownloadButton = $('#statusDownloadButton');
    if (statusDownloadButton) {
      statusDownloadButton.disabled = !hasInstallableFiles(update);
      statusDownloadButton.textContent = 'Baixar atualização teste';
    }
  } else {
    const statusTitle = $('#statusUpdateTitle');
    if (statusTitle) statusTitle.textContent = 'Atualização disponível';
    const statusBadge = $('#statusVersionBadge');
    if (statusBadge) statusBadge.textContent = 'VS Hook';
    const statusDescription = $('#statusUpdateDescription');
    if (statusDescription) statusDescription.textContent = '';
    const statusDownloadButton = $('#statusDownloadButton');
    if (statusDownloadButton) {
      statusDownloadButton.disabled = true;
      statusDownloadButton.textContent = 'Baixar atualização';
    }
    $('#statusInstallButton')?.classList.add('hidden');
  }

  renderBridgeState(state.bridge);

  const license = state.license || {};
  $('#cpfInput').value = license.document || license.cpf || license.cnpj || $('#cpfInput').value || '';
  $('#emailInput').value = license.email || $('#emailInput').value || '';
  $('#licenseActive').textContent = license.active ? 'Ativa' : 'Pendente';
  $('#licenseActive').classList.toggle('ok-text', !!license.active);
  $('#licenseDevices').textContent = `${license.devicesUsed || 0} de ${license.maxDevices || 0}`;
  
  const licenseMessage = license.message || license.warning || '';
  if (licenseMessage) {
    $('#licenseMessage').textContent = licenseMessage;
  } else if (license.active) {
    $('#licenseMessage').textContent = 'Licença ativa.';
  } else if (!$('#licenseMessage').textContent) {
    $('#licenseMessage').textContent = 'Aguardando ativação.';
  }

  renderDevices();
}


async function refreshBridgeState() {
  try {
    const bridge = await window.hookUpdateCenter.getBridgeState();
    renderBridgeState(bridge);
  } catch (_) {}
}

async function refreshState() {
  renderState(await window.hookUpdateCenter.getState());
  if (!(state?.deviceLoginEmail || state?.license?.email)) {
    setTimeout(() => promptDeviceLoginModal(), 250);
  }
}


function getPlatformFilesForUpdate(update) {
  const platformKey = state?.platform === 'darwin' ? 'macos' : 'windows';
  return update?.files?.[platformKey] || {};
}

function hasInstallableFiles(update) {
  const files = getPlatformFilesForUpdate(update);
  if (!files) return false;

  if (state?.platform === 'darwin') {
    const jsApi = state?.arch === 'arm64'
      ? (files.jsApiArmDylib || files.jsApiDylib)
      : (files.jsApiIntelDylib || files.jsApiDylib);
    return !!(files.lua || files.hookLyricsLua || files.lyricsLua || files.vshookDylib || jsApi);
  }

  return Object.values(files || {}).some(Boolean);
}

function renderPreviousUpdates(updates) {
  const list = $('#previousUpdatesList');
  if (!Array.isArray(updates) || updates.length === 0) {
    list.innerHTML = `
      <div class="card">
        <h2>Nenhuma versão encontrada</h2>
        <p class="muted">Ainda não existem atualizações anteriores disponíveis.</p>
      </div>
    `;
    return;
  }

  list.innerHTML = updates.map((update, index) => {
    const version = escapeHtml(update.version || 'Sem versão');
    const title = escapeHtml(update.title || `VS Hook ${version}`);
    const date = escapeHtml(formatDate(update.publishedAt || update.createdAt));
    const description = escapeHtml(update.description || '');

    return `
      <div class="card previous-update-card">
        <div class="update-header">
          <div>
            <p class="eyebrow">Versão anterior</p>
            <h2>${title}</h2>
            <p class="muted">${date}</p>
          </div>
          <span class="badge">v${version}</span>
        </div>
        ${description ? `<p class="description">${description}</p>` : ''}
        <div class="actions">
          <button class="primary-button previous-download-button" data-index="${index}">Baixar esta versão</button>
        </div>
      </div>
    `;
  }).join('');

  list.querySelectorAll('.previous-download-button').forEach((button) => {
    button.addEventListener('click', async () => {
      const index = Number(button.dataset.index);
      const update = updates[index];
      if (!hasInstallableFiles(update)) {
        showModal({ title: 'Versão indisponível', message: 'Não há arquivos disponíveis para esta versão neste sistema.', type: 'error' });
        return;
      }

      try {
        setView('home');
        setProgressVisible(true);
        resetVsHookProgress();
        button.disabled = true;
        button.textContent = 'Baixando...';
        await window.hookUpdateCenter.downloadUpdate({ update });
      } catch (error) {
        showModal({ title: 'Erro no download', message: friendlyError(error, 'Não foi possível baixar esta versão.'), type: 'error' });
      } finally {
        button.disabled = false;
        button.textContent = 'Baixar esta versão';
      }
    });
  });
}

async function loadPreviousUpdates() {
  const button = $('#refreshPreviousButton');
  try {
    button.disabled = true;
    button.textContent = 'Verificando...';
    const result = await window.hookUpdateCenter.getPreviousUpdates();
    if (result.ok === false) {
      showModal({
        title: 'Histórico indisponível',
        message: friendlyError(result.error || '', 'Não foi possível carregar as atualizações anteriores.'),
        type: 'error'
      });
    }
    renderPreviousUpdates(result.updates || []);
  } catch (error) {
    showModal({ title: 'Erro ao carregar versões', message: friendlyError(error, 'Não foi possível carregar as atualizações anteriores.'), type: 'error' });
  } finally {
    button.disabled = false;
    button.textContent = 'Carregar versões';
  }
}


function setupSidebarToggle() {
  const shell = document.querySelector('.app-shell');
  const toggle = document.getElementById('sidebarToggleButton');
  const sidebar = document.querySelector('.sidebar');
  if (!shell || !toggle || !sidebar) return;

  const setOpen = (open) => {
    shell.classList.toggle('sidebar-open', !!open);
    document.body.classList.toggle('sidebar-open', !!open);
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    toggle.setAttribute('title', open ? 'Fechar menu' : 'Abrir menu');
  };

  setOpen(false);

  toggle.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    setOpen(!shell.classList.contains('sidebar-open'));
  });

  sidebar.querySelectorAll('.nav-item').forEach((button) => {
    button.addEventListener('click', () => setOpen(false));
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') setOpen(false);
  });

  document.addEventListener('click', (event) => {
    if (!shell.classList.contains('sidebar-open')) return;
    if (sidebar.contains(event.target) || toggle.contains(event.target)) return;
    setOpen(false);
  });
}

async function init() {
  setupSidebarToggle();
  await refreshState();

  $('#modalOkButton').addEventListener('click', () => {
    if (pendingConfirmResolve) {
      const resolve = pendingConfirmResolve;
      pendingConfirmResolve = null;
      $('#appModal').classList.add('hidden');
      $('#modalOkButton').textContent = 'OK';
      $('#modalCancelButton').classList.add('hidden');
      resolve(true);
      return;
    }
    hideModal();
  });
  $('#modalCancelButton').addEventListener('click', hideModal);
  $('#appModal').addEventListener('click', (event) => { if (event.target.id === 'appModal') hideModal(); });
  $('#supportQrModal')?.addEventListener('click', (event) => { if (event.target.id === 'supportQrModal') closeSupportQrModal(); });
  $('#supportQrCloseButton')?.addEventListener('click', closeSupportQrModal);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      if (!$('#supportQrModal')?.classList.contains('hidden')) closeSupportQrModal();
      else if (!$('#videoModal').classList.contains('hidden')) closeVideoModal();
      else hideModal();
    }
  });

  $$('.nav-item').forEach((button) => {
    if (button.dataset.view) {
      button.addEventListener('click', () => {
        setView(button.dataset.view);
        if (button.dataset.view === 'previous') loadPreviousUpdates();
        if (button.dataset.view === 'bridge') refreshBridgeState();
        if (button.dataset.view === 'lyrics') refreshLyricsSettings();
      });
    }
  });

  const openSupport = async () => {
    try {
      const result = await window.hookUpdateCenter.openSupport();
      showSupportQrModal(result || {});
    } catch (error) {
      showModal({
        title: 'Suporte',
        message: 'Suporte indisponível no momento. Tente novamente mais tarde.',
        type: 'error'
      });
    }
  };

  $('#supportNavButton')?.addEventListener('click', openSupport);
  $('#restartBridgeButton')?.addEventListener('click', async () => {
    try {
      $('#restartBridgeButton').disabled = true;
      $('#restartBridgeButton').textContent = 'Reiniciando...';
      const bridge = await window.hookUpdateCenter.restartBridge();
      renderBridgeState(bridge);
      showModal({ title: 'Conexão reiniciada', message: 'A conexão via app foi reiniciada com sucesso.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Erro na conexão', message: friendlyError(error, 'Não foi possível reiniciar a conexão via app.'), type: 'error' });
    } finally {
      $('#restartBridgeButton').disabled = false;
      $('#restartBridgeButton').textContent = 'Reiniciar conexão';
    }
  });
  $('#supportButton')?.addEventListener('click', openSupport);

  $('#refreshPreviousButton')?.addEventListener('click', async () => {
    await loadPreviousUpdates();
  });

  $('#openLyricsOneButton')?.addEventListener('click', async () => {
    try {
      await saveLyricsSettingsFromForm(1);
      await window.hookUpdateCenter.openLyricsWindow(1);
      renderState(await window.hookUpdateCenter.getState());
    } catch (error) {
      showModal({ title: 'Teleprompt', message: friendlyError(error, 'Não foi possível alternar o Teleprompt 1.'), type: 'error' });
    }
  });
  $('#openLyricsTwoButton')?.addEventListener('click', async () => {
    try {
      await saveLyricsSettingsFromForm(2);
      await window.hookUpdateCenter.openLyricsWindow(2);
      renderState(await window.hookUpdateCenter.getState());
    } catch (error) {
      showModal({ title: 'Teleprompt', message: friendlyError(error, 'Não foi possível alternar o Teleprompt 2.'), type: 'error' });
    }
  });
  $('#saveLyricsSettingsButton1')?.addEventListener('click', async () => {
    try {
      await saveLyricsSettingsFromForm(1);
      showModal({ title: 'Teleprompt', message: 'A aparência da janela 1 foi salva.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Teleprompt', message: friendlyError(error, 'Não foi possível salvar a aparência.'), type: 'error' });
    }
  });
  $('#saveLyricsSettingsButton2')?.addEventListener('click', async () => {
    try {
      await saveLyricsSettingsFromForm(2);
      showModal({ title: 'Teleprompt', message: 'A aparência da janela 2 foi salva.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Teleprompt', message: friendlyError(error, 'Não foi possível salvar a aparência.'), type: 'error' });
    }
  });
  $('#saveTechnicalNoticeSettingsButton')?.addEventListener('click', async () => {
    try {
      await saveTechnicalNoticeSettingsFromForm();
      showModal({ title: 'Avisos técnicos', message: 'A aparência dos avisos técnicos foi salva.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Avisos técnicos', message: friendlyError(error, 'Não foi possível salvar a aparência dos avisos técnicos.'), type: 'error' });
    }
  });
  setupLyricsAutoApply();
  window.hookUpdateCenter.onLyricsSettingsUpdated?.(applyLyricsSettingsToForm);
  window.hookUpdateCenter.onTechnicalNoticeSettingsUpdated?.(applyTechnicalNoticeSettingsToForm);
  window.hookUpdateCenter.onLyricsWindowsStateUpdated?.((windows) => {
    state = { ...(state || {}), lyricsWindows: windows || {} };
    updateLyricsWindowButtons();
  });

  $('#openVideoModalButton')?.addEventListener('click', openVideoModal);
  $('#closeVideoModalButton')?.addEventListener('click', closeVideoModal);
  $('#videoModal')?.addEventListener('click', (event) => {
    if (event.target.id === 'videoModal') closeVideoModal();
  });

  $('#checkButton').addEventListener('click', async () => {
    $('#checkButton').disabled = true;
    $('#checkButton').textContent = 'Verificando...';
    const result = await window.hookUpdateCenter.checkUpdates();
    renderState(result.state || await window.hookUpdateCenter.getState());
    $('#checkButton').disabled = false;
    $('#checkButton').textContent = 'Conferir atualização';
  });

  $('#laterButton').addEventListener('click', () => {
    window.close();
  });

  $('#downloadButton').addEventListener('click', () => startVsHookDownload());
  $('#statusDownloadButton')?.addEventListener('click', () => {
    const testUpdate = isTestClientUpdate(state?.latestUpdate) ? state.latestUpdate : null;
    if (!testUpdate) {
      showModal({ title:'Cliente teste', message:'Nenhuma atualização teste disponível para este computador.', type:'info' });
      return;
    }
    startVsHookDownload(testUpdate);
  });
  $('#installButton').addEventListener('click', installVsHookDownloadedUpdate);
  $('#statusInstallButton')?.addEventListener('click', installVsHookDownloadedUpdate);

  $('#hookCenterLearnButton')?.addEventListener('click', async () => {
    const url = state?.hookCenterLatest?.tutorialUrl || state?.hookCenterLatest?.learnUrl || state?.hookCenterLatest?.videoUrl || '';
    if (!url) return;
    try {
      await window.hookUpdateCenter.openExternal(url);
    } catch (error) {
      showModal({ title: 'Hook Center', message: friendlyError(error, 'Não foi possível abrir o vídeo.'), type: 'error' });
    }
  });

  $('#hookCenterUpdateButton')?.addEventListener('click', async () => {
    if (!(await ensureDeviceName())) return;
    const confirmed = await confirmModal({
      title: 'Atualizar Hook Center',
      message: state?.platform === 'darwin'
        ? 'O DMG será baixado e aberto. Depois arraste o Hook Center para Aplicativos.'
        : 'O instalador será baixado e executado. O Hook Center vai fechar para instalar a nova versão.',
      type: 'info',
      okText: 'Atualizar',
      cancelText: 'Cancelar'
    });
    if (!confirmed) return;
    try {
      $('#hookCenterUpdateButton').disabled = true;
      $('#hookCenterUpdateButton').textContent = 'Baixando...';
      const result = await window.hookUpdateCenter.installHookCenterUpdate();
      if (state?.platform === 'darwin') {
        showModal({ title: 'DMG baixado', message: 'O instalador do Hook Center foi aberto. Instale por cima da versão atual.', type: 'success' });
      }
    } catch (error) {
      showModal({ title: 'Erro ao atualizar Hook Center', message: friendlyError(error, 'Não foi possível atualizar o Hook Center.'), type: 'error' });
    } finally {
      $('#hookCenterUpdateButton').disabled = false;
      $('#hookCenterUpdateButton').textContent = 'Atualizar Hook Center';
    }
  });

  $('#activateButton').addEventListener('click', async () => {
    try {
      if (!(await ensureDeviceName())) return;
      $('#activateButton').disabled = true;
      $('#activateButton').textContent = 'Ativando...';
      $('#licenseMessage').textContent = 'Verificando dados...';

      const result = await window.hookUpdateCenter.activateLicense({
        cpf: $('#cpfInput').value,
        email: $('#emailInput').value
      });

      renderState(result.state || await window.hookUpdateCenter.getState());
      const msg = result?.result?.message || result?.result?.warning || 'Licença ativada com sucesso.';
      $('#licenseMessage').textContent = msg;
      if (result?.result?.warning) {
        showModal({ title: 'Aviso da assinatura', message: msg, type: 'info' });
      }
    } catch (error) {
      const currentState = await window.hookUpdateCenter.getState().catch(() => null);
      if (currentState?.license?.active) {
        renderState(currentState);
        const activeMsg = 'Licença já está ativa neste computador.';
        $('#licenseMessage').textContent = activeMsg;
        showModal({ title: 'Licença ativa', message: activeMsg, type: 'success' });
      } else {
        const msg = friendlyError(error, 'Não foi possível concluir a ativação. Tente novamente.');
        $('#licenseMessage').textContent = msg;
        const lowerMsg = msg.toLowerCase();
        const title = (lowerMsg.includes('terceiros') || lowerMsg.includes('compartilhamento')) ? 'Alerta de licença' : ((lowerMsg.includes('não foi possível concluir') || lowerMsg.includes('nao foi possivel concluir')) ? 'Não foi possível concluir' : 'Licença não encontrada');
        showModal({ title, message: msg, type: 'error' });
      }
    } finally {
      $('#activateButton').disabled = false;
      $('#activateButton').textContent = 'Ativar licença';
    }
  });

  $('#licenseCheckButton').addEventListener('click', async () => {
    try {
      $('#licenseCheckButton').disabled = true;
      $('#licenseCheckButton').textContent = 'Verificando...';
      const result = await window.hookUpdateCenter.checkLicenseStatus();
      renderState(result.state || await window.hookUpdateCenter.getState());
      const msg = result?.result?.message || result?.result?.warning || (result.active ? 'Licença ativa.' : 'Esta licença não está ativa.');
      $('#licenseMessage').textContent = msg;
      if (result?.result?.warning && result.active) {
        showModal({ title: 'Aviso da assinatura', message: msg, type: 'info' });
      }
      if (!result.active) {
        showModal({
          title: 'Licença não ativa',
          message: msg,
          type: 'error'
        });
      }
    } catch (error) {
      const msg = friendlyError(error, 'Não foi possível verificar a licença.');
      $('#licenseMessage').textContent = msg;
      showModal({ title: 'Não foi possível concluir', message: msg, type: 'error' });
    } finally {
      $('#licenseCheckButton').disabled = false;
      $('#licenseCheckButton').textContent = 'Verificar licença';
    }
  });


  $('#saveDeviceNameButton')?.addEventListener('click', async () => {
    try {
      const value = $('#devicesNameInput')?.value || $('#deviceNameInlineInput')?.value || ''
      const result = await window.hookUpdateCenter.setDeviceName({ deviceName: value })
      renderState(result.state || await window.hookUpdateCenter.getState())
      $('#devicesMessage').textContent = 'Nome do dispositivo salvo.'
    } catch (error) {
      showModal({ title:'Dispositivos', message:friendlyError(error, 'Ocorreu um erro. Contate o suporte.'), type:'error' })
    }
  });

  $('#devicesLoginButton')?.addEventListener('click', async () => {
    try {
      await ensureDeviceName()
      const result = await window.hookUpdateCenter.loginLicenseDevices({ email: $('#devicesEmailInput')?.value || $('#emailInput')?.value || '' })
      renderState(result.state || await window.hookUpdateCenter.getState())
      const msg = result?.result?.message || 'Login realizado.'
      $('#devicesMessage').textContent = msg
      if (result?.result?.reason === 'device_limit') showModal({ title:'Remova 1 dispositivo', message:msg, type:'error' })
    } catch (error) {
      showModal({ title:'Dispositivos', message:friendlyError(error, 'Ocorreu um erro. Contate o suporte.'), type:'error' })
    }
  });

  $('#deviceNameInlineInput')?.addEventListener('change', async () => {
    const value = $('#deviceNameInlineInput')?.value || ''
    if (!value.trim()) return
    try { renderState((await window.hookUpdateCenter.setDeviceName({ deviceName: value })).state || await window.hookUpdateCenter.getState()) } catch (_) {}
  });

  window.hookUpdateCenter.onUpdateStatus(renderState);
  window.hookUpdateCenter.onLicenseStatus(renderState);
  window.hookUpdateCenter.onUpdateError((message) => showModal({ title: 'Erro ao verificar atualização', message: friendlyError(message, 'Não foi possível verificar atualizações.'), type: 'error' }));
  window.hookUpdateCenter.onDownloadProgress((progress) => {
    updateVsHookProgress(progress);
  });
}

init().catch((error) => {
  showModal({ title: 'Erro ao iniciar', message: friendlyError(error, 'Não foi possível iniciar o Hook Center.'), type: 'error' });
});
