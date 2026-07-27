const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

let state = null;
let currentYoutubeWatchUrl = "";
let pendingConfirmResolve = null;
let hookRenameFolder = null;
let hookRenameLastPreview = null;
let selectedToolsPanel = 'rename';
let combinedDownloadInProgress = false;
let combinedDownloadReady = { package: false, vsHook: false, hookCenter: false };
let selectedLyricsConfigSlot = 1;
const selectedLyricsPresets = { 1: 'night', 2: 'night' };
let recadosHubSelectedSlot = 'global';
let recadosHubGlobalDraft = '';
let recadosHubTemplates = ['', '', ''];
let recadosHubEditingTemplate = false;
let recadosHubPinned = false;
let recadosHubNoticeActive = false;
let recadosHubExpiresAt = 0;
let recadosHubRemainingMs = 0;
let recadosHubCountdownTimer = 0;
let updateDescriptionFitFrame = 0;
let updateDescriptionResizeObserver = null;
let currentBridgeState = null;

function setLyricsConfigSlot(slot) {
  selectedLyricsConfigSlot = Number(slot) === 2 ? 2 : 1;

  $$('[data-lyrics-config-slot]').forEach((button) => {
    const active = Number(button.dataset.lyricsConfigSlot) === selectedLyricsConfigSlot;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });

  $$('[data-lyrics-config-panel]').forEach((panel) => {
    const active = Number(panel.dataset.lyricsConfigPanel) === selectedLyricsConfigSlot;
    panel.classList.toggle('active', active);
  });
}

async function applyLyricsPreset(slot, preset) {
  const id = Number(slot) === 2 ? 2 : 1;
  const isDay = preset === 'day';
  selectedLyricsPresets[id] = isDay ? 'day' : 'night';
  const colors = isDay
    ? { text: '#ffffff', textBox: '#ffffff', clock: '#ffffff', border: '#ffffff', song: '#ffffff', queue: '#ffffff', progress: '#ffffff' }
    : { text: '#ffea00', textBox: '#ffea00', clock: '#00ff55', border: '#00ff55', song: '#00ff55', queue: '#ffea00', progress: '#ffea00' };
  const fieldMap = {
    text: `#lyricsTextColor${id}`,
    textBox: `#lyricsTextBoxColor${id}`,
    clock: `#lyricsClockColor${id}`,
    border: `#lyricsBorderColor${id}`,
    song: `#lyricsSongNameColor${id}`,
    queue: `#lyricsQueueNameColor${id}`,
    progress: `#lyricsProgressColor${id}`
  };
  Object.entries(fieldMap).forEach(([key, selector]) => {
    const input = $(selector);
    if (input) input.value = colors[key];
  });
  await saveLyricsSettingsFromForm(id);
  $$(`[data-lyrics-preset-slot="${id}"]`).forEach((button) => {
    button.classList.toggle('preset-selected', button.dataset.lyricsPreset === selectedLyricsPresets[id]);
  });
}

function openTechnicalNoticeModal() {
  $('#technicalNoticeModal')?.classList.remove('hidden');
  $('#closeTechnicalNoticeModalButton')?.focus();
}

function closeTechnicalNoticeModal() {
  $('#technicalNoticeModal')?.classList.add('hidden');
}

async function openRecadosModal() {
  try { applyTechnicalNoticeSettingsToForm(await window.hookUpdateCenter.getTechnicalNoticeSettings()); } catch (_) {}
  syncHubRecadosModal();
  ensureHubRecadosCountdown();
  if (recadosHubNoticeActive) updateHubRecadosCountdown();
  else $('#recadosModalStatus').textContent = '';
  $('#recadosModal')?.classList.remove('hidden');
  $('#recadosDraftInput')?.focus();
}

function closeRecadosModal() {
  const input = $('#recadosDraftInput');
  if (input) {
    if (recadosHubSelectedSlot === 'global') recadosHubGlobalDraft = input.value;
    else if (recadosHubEditingTemplate) recadosHubTemplates[Number(recadosHubSelectedSlot)] = input.value;
  }
  $('#recadosModal')?.classList.add('hidden');
}

async function exitRecadosModal() {
  try {
    await window.hookUpdateCenter.cancelRecadosNotice();
    recadosHubNoticeActive = false;
    recadosHubExpiresAt = 0;
    recadosHubRemainingMs = 0;
    recadosHubPinned = false;
  } catch (_) {}
  closeRecadosModal();
}

function updateHubRecadosCountdown() {
  if (!recadosHubNoticeActive) return;
  const remainingMs = recadosHubPinned
    ? Math.max(0, Number(recadosHubRemainingMs || 0))
    : Math.max(0, Number(recadosHubExpiresAt || 0) - Date.now());
  const status = $('#recadosModalStatus');
  if (!status) return;
  if (remainingMs <= 0) {
    recadosHubNoticeActive = false;
    status.textContent = 'RECADO EXPIRADO';
    return;
  }
  status.textContent = `RECADO ATIVO: ${Math.ceil(remainingMs / 1000)}s`;
}

function ensureHubRecadosCountdown() {
  if (!recadosHubCountdownTimer) recadosHubCountdownTimer = window.setInterval(updateHubRecadosCountdown, 250);
}

function syncHubRecadosModal() {
  const input = $('#recadosDraftInput');
  const selectedIsGlobal = recadosHubSelectedSlot === 'global';
  const selectedIndex = selectedIsGlobal ? -1 : Number(recadosHubSelectedSlot);
  if (input) {
    const value = selectedIsGlobal ? recadosHubGlobalDraft : (recadosHubTemplates[selectedIndex] || '');
    if (document.activeElement !== input || input.value !== value) input.value = value;
    input.readOnly = !selectedIsGlobal && !recadosHubEditingTemplate;
    input.placeholder = selectedIsGlobal ? 'Digite o recado técnico...' : `Conteúdo do Recado ${selectedIndex + 1}`;
  }
  $$('[data-recados-slot]').forEach((button) => button.classList.toggle('active', button.dataset.recadosSlot === String(recadosHubSelectedSlot)));
  const edit = $('#editRecadosTemplateButton');
  if (edit) {
    edit.classList.toggle('hidden', selectedIsGlobal);
    edit.classList.toggle('saving', recadosHubEditingTemplate);
    edit.textContent = recadosHubEditingTemplate ? 'SALVAR' : 'EDITAR';
  }
  const pin = $('#toggleRecadosPinButton');
  if (pin) {
    pin.classList.toggle('active', recadosHubPinned);
    pin.setAttribute('aria-pressed', recadosHubPinned ? 'true' : 'false');
    pin.textContent = recadosHubPinned ? 'FIXADO' : 'FIXAR';
  }
}

function selectHubRecadosSlot(slot) {
  const input = $('#recadosDraftInput');
  if (input) {
    if (recadosHubSelectedSlot === 'global') recadosHubGlobalDraft = input.value;
    else if (recadosHubEditingTemplate) recadosHubTemplates[Number(recadosHubSelectedSlot)] = input.value;
  }
  recadosHubSelectedSlot = slot === 'global' ? 'global' : Math.max(0, Math.min(2, Number(slot)));
  recadosHubEditingTemplate = false;
  $('#recadosModalStatus').textContent = '';
  syncHubRecadosModal();
}

async function toggleHubRecadosTemplateEdit() {
  if (recadosHubSelectedSlot === 'global') return;
  const input = $('#recadosDraftInput');
  if (!recadosHubEditingTemplate) {
    recadosHubEditingTemplate = true;
    syncHubRecadosModal();
    input?.focus();
    return;
  }
  recadosHubTemplates[Number(recadosHubSelectedSlot)] = String(input?.value || '').trim();
  try {
    await saveTechnicalNoticeSettingsFromForm();
    recadosHubEditingTemplate = false;
    $('#recadosModalStatus').textContent = 'RECADO SALVO';
  } catch (error) {
    $('#recadosModalStatus').textContent = friendlyError(error, 'Não foi possível salvar o recado.');
  }
  syncHubRecadosModal();
}

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

function noticeModal({ title = 'Aviso', message = '', type = 'info', okText = 'OK' }) {
  return new Promise((resolve) => {
    pendingConfirmResolve = resolve;
    showModal({ title, message, type });
    const okButton = $('#modalOkButton');
    const cancelButton = $('#modalCancelButton');
    okButton.textContent = okText;
    if (cancelButton) cancelButton.classList.add('hidden');
  });
}

async function showDownloadDescriptionNotice() {
  return noticeModal({
    title: 'Leia a descrição',
    message: 'Leia a descrição da atualização antes de baixar.',
    type: 'info',
    okText: 'OK'
  });
}

async function ensureLicenseActiveForDownload() {
  if (state?.license?.active === true) return true;

  const shouldActivate = await confirmModal({
    title: 'Ativação necessária',
    message: 'Faça sua ativação primeiro para baixar as atualizações do VS Hook.',
    type: 'info',
    okText: 'Fazer ativação',
    cancelText: 'Cancelar'
  });

  if (shouldActivate) {
    setView('license');
    $('#cpfInput')?.focus();
  }

  return false;
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

function setHomeDownloadButtonProgress(progress, active) {
  const button = $('#downloadButton');
  if (!button) return;
  const safeProgress = Math.max(0, Math.min(100, Number(progress) || 0));
  button.style.setProperty('--download-progress', `${safeProgress}%`);
  button.classList.toggle('download-progress-active', active === true);
  if (active === true) button.textContent = `Baixando ${safeProgress}%`;
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
  if (combinedDownloadInProgress) setHomeDownloadButtonProgress(safeProgress, true);
  if (safeProgress >= 100 && !combinedDownloadInProgress) {
    $('#installButton')?.classList.remove('hidden');
    $('#statusInstallButton')?.classList.remove('hidden');
  }
}

async function startVsHookDownload(updateOverride = null) {
  try {
    if (!(await ensureLicenseActiveForDownload())) return;
    if (!(await showDownloadDescriptionNotice())) return;
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
      button.textContent = button.dataset.originalText || 'Baixar';
      delete button.dataset.originalText;
    });
  }
}

async function startCombinedUpdateDownload() {
  if (!state?.latestUpdate && !state?.hookCenterLatest) {
    showModal({ title: 'Atualizações', message: 'Nenhuma atualização disponível no momento.', type: 'info' });
    return;
  }

  if (!(await ensureLicenseActiveForDownload())) return;
  if (!(await ensureDeviceName())) return;

  const button = $('#downloadButton');
  if (state?.currentPackageInstalled === true) {
    const confirmed = await confirmModal({
      title: 'Reinstalar esta versão?',
      message: state?.currentPackageCached
        ? 'A Hook Center abrirá o instalador salvo no computador e reinstalará também a extensão.'
        : 'Os arquivos serão baixados novamente, salvos no computador e a instalação completa será aberta.',
      type: 'info',
      okText: 'Reinstalar',
      cancelText: 'Cancelar'
    });
    if (!confirmed) return;
    try {
      if (button) {
        button.disabled = true;
        button.textContent = 'Preparando...';
      }
      await window.hookUpdateCenter.installCachedUpdatePackage();
      if (state?.platform === 'darwin') {
        renderState(await window.hookUpdateCenter.getState());
        showModal({ title: 'Reinstalação pronta', message: 'A extensão foi reinstalada e o instalador da Hook Center foi aberto.', type: 'success' });
      }
    } catch (error) {
      showModal({ title: 'Erro ao reinstalar', message: friendlyError(error, 'Não foi possível reinstalar esta versão.'), type: 'error' });
      if (button) {
        button.disabled = false;
        button.textContent = 'Reinstalar';
      }
    }
    return;
  }

  if (!(await showDownloadDescriptionNotice())) return;
  combinedDownloadInProgress = true;
  combinedDownloadReady = { package: false, vsHook: false, hookCenter: false };
  $('#homeProgressArea')?.classList.add('hidden');
  resetVsHookProgress();
  if (button) {
    button.disabled = true;
    setHomeDownloadButtonProgress(0, true);
  }

  try {
    await window.hookUpdateCenter.cacheUpdatePackage();
    combinedDownloadReady = { package: true, vsHook: true, hookCenter: true };
  } catch (error) {
    showModal({ title: 'Erro no download', message: friendlyError(error, 'Não foi possível guardar o instalador e a extensão desta versão.'), type: 'error' });
  } finally {
    combinedDownloadInProgress = false;
    if (button) {
      button.disabled = false;
      button.classList.remove('download-progress-active');
      button.style.removeProperty('--download-progress');
      button.textContent = 'Baixar';
    }
    if (combinedDownloadReady.package) {
      updateVsHookProgress(100);
      const installButton = $('#installButton');
      if (installButton) {
        installButton.textContent = 'Instalar';
        installButton.classList.remove('hidden');
      }
      renderState(await window.hookUpdateCenter.getState());
    }
  }
}

async function installCombinedDownloadedUpdates() {
  if (!combinedDownloadReady.package) return;
  const confirmed = await confirmModal({
    title: 'Instalar atualização',
    message: 'Feche o REAPER antes de continuar. A Hook Center instalará a extensão e abrirá o instalador completo.',
    type: 'info',
    okText: 'Instalar',
    cancelText: 'Cancelar'
  });
  if (!confirmed) return;

  try {
    await window.hookUpdateCenter.installCachedUpdatePackage();
    if (state?.platform === 'darwin') {
      renderState(await window.hookUpdateCenter.getState());
      setProgressVisible(false);
      resetVsHookProgress();
      showModal({ title: 'Atualizações prontas', message: 'A extensão foi instalada e o instalador da Hook Center foi aberto.', type: 'success' });
    }
    combinedDownloadReady = { package: false, vsHook: false, hookCenter: false };
  } catch (error) {
    showModal({ title: 'Erro ao instalar', message: friendlyError(error, 'Não foi possível instalar as atualizações.'), type: 'error' });
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



function getHookRenameFolderPaths() {
  if (Array.isArray(hookRenameFolder?.folderPaths) && hookRenameFolder.folderPaths.length) {
    return hookRenameFolder.folderPaths;
  }
  return hookRenameFolder?.folderPath ? [hookRenameFolder.folderPath] : [];
}

function getHookRenamePayload() {
  const useFolderSuffix = $('#hookRenameUseFolderSuffixCheck')?.checked === true;
  const bulkMode = $('#hookRenameBulkModeCheck')?.checked === true;
  const manualSuffix = $('#hookRenameSuffixInput')?.value || '';
  const suggestedSuffix = hookRenameFolder?.suggestedSuffix || $('#hookRenameSuggestedSuffixInput')?.value || '';
  const folderPaths = getHookRenameFolderPaths();
  return {
    folderPath: folderPaths[0] || '',
    folderPaths,
    suffix: useFolderSuffix ? suggestedSuffix : manualSuffix,
    useFolderSuffix,
    bulkMode
  };
}

function formatHookRenameSelectedPaths(result) {
  const paths = Array.isArray(result?.folderPaths) ? result.folderPaths : (result?.folderPath ? [result.folderPath] : []);
  if (!paths.length) return 'Escolha uma pasta para começar.';
  if (!result?.multiple) return paths[0] || '';

  const names = Array.isArray(result.folderNames) && result.folderNames.length
    ? result.folderNames
    : paths.map((item) => item.split(/[\\/]/).filter(Boolean).pop() || item);
  const visible = names.slice(0, 6).join(', ');
  const hidden = Math.max(0, names.length - 6);
  return hidden ? `${visible} + ${hidden} pasta(s)` : visible;
}

function setHookRenameProgress({ percent = 0, current = 0, total = 0, renamed = 0, failed = 0, phase = '' } = {}) {
  const safePercent = Math.max(0, Math.min(100, Number(percent) || 0));
  const bar = $('#hookRenameProgressBar');
  const text = $('#hookRenameProgressText');
  const count = $('#hookRenameProgressCount');
  if (bar) bar.style.width = `${safePercent}%`;
  if (text) text.textContent = `${safePercent}%`;
  if (count) {
    if (phase === 'done') count.textContent = `${renamed} renomeados${failed ? `, ${failed} falharam` : ''}`;
    else count.textContent = total ? `${current}/${total} arquivos` : 'Preparando...';
  }
}

function resetHookRenameProgress() {
  $('#hookRenameProgressArea')?.classList.add('hidden');
  setHookRenameProgress({ percent: 0, current: 0, total: 0, renamed: 0, failed: 0 });
}

function updateHookRenameControls() {
  const folderPaths = getHookRenameFolderPaths();
  const hasFolder = folderPaths.length > 0;
  const isManyFolders = hookRenameFolder?.multiple === true;
  const useFolderSuffix = $('#hookRenameUseFolderSuffixCheck')?.checked === true;
  const bulkCheck = $('#hookRenameBulkModeCheck');
  const suffixInput = $('#hookRenameSuffixInput');
  const suggestedInput = $('#hookRenameSuggestedSuffixInput');

  if (suffixInput) suffixInput.disabled = useFolderSuffix;
  if (suggestedInput) suggestedInput.value = hookRenameFolder?.suggestedSuffix || '';

  if (bulkCheck) {
    bulkCheck.disabled = !useFolderSuffix || !isManyFolders;
    if (!useFolderSuffix || !isManyFolders) bulkCheck.checked = false;
  }

  const payload = getHookRenamePayload();
  const hasSuffix = !!String(payload.suffix || '').trim();
  const runButton = $('#hookRenameRunButton');
  if (runButton) runButton.disabled = !hasFolder || !hasSuffix || !hookRenameLastPreview?.totalOperations;

  const help = $('#hookRenameModeHelp');
  if (help) {
    if (payload.bulkMode) {
      help.textContent = 'Modo em massa ativo: processa as pastas selecionadas uma por uma, sem entrar em subpastas, renomeando somente MP3, WAV e AIFF com o nome da própria pasta como sufixo.';
    } else if (isManyFolders) {
      help.textContent = 'Você selecionou várias pastas. Marque “Usar nome da pasta como sufixo” para liberar o modo Renomear em massa.';
    } else {
      help.textContent = 'Modo normal: renomeia somente os arquivos da pasta selecionada. Subpastas não são alteradas.';
    }
  }
}

function renderHookRenamePreview(preview = null) {
  hookRenameLastPreview = preview;
  const list = $('#hookRenamePreviewList');
  const summary = $('#hookRenameSummary');
  const badge = $('#hookRenamePreviewBadge');
  if (!list || !summary || !badge) return;

  const total = Number(preview?.totalOperations || 0);
  badge.textContent = String(total);

  if (!preview) {
    summary.textContent = 'Nenhuma prévia gerada ainda.';
    list.innerHTML = '<p class="muted">Escolha uma pasta e clique em gerar prévia.</p>';
    updateHookRenameControls();
    return;
  }

  const skipped = Number(preview.totalSkipped || 0);
  const scanned = Number(preview.totalScanned || 0);
  const folders = Number(preview.totalFolders || 0);
  const audioText = preview.audioOnly ? ' Somente MP3, WAV e AIFF.' : '';
  const folderText = folders > 1 ? ` ${folders} pasta(s).` : '';
  summary.textContent = `${total} arquivo(s) prontos para renomear.${folderText} ${scanned} arquivo(s) analisados. ${skipped} ignorado(s).${audioText}`;

  if (!total) {
    const reason = preview.bulkMode
      ? 'Nenhum arquivo de áudio MP3, WAV ou AIFF foi encontrado diretamente nas pastas selecionadas.'
      : 'Nenhum arquivo foi encontrado para renomear nesta pasta, ou todos já tinham o sufixo/teriam conflito.';
    list.innerHTML = `<p class="muted">${reason}</p>`;
    updateHookRenameControls();
    return;
  }

  const operations = Array.isArray(preview.operations) ? preview.operations : [];
  const hiddenCount = total - operations.length;
  const renderPreviewItem = (item, grouped = false) => `
    <div class="hook-rename-preview-item${grouped ? ' grouped' : ''}">
      <div>
        <span>${escapeHtml(item.fromName || '')}</span>
        <strong>${escapeHtml(item.toName || '')}</strong>
      </div>
      ${grouped ? '' : `<small>${escapeHtml(item.relativeFolder || '.')}</small>`}
    </div>
  `;
  let operationsHtml = operations.map((item) => renderPreviewItem(item)).join('');

  if (folders > 1) {
    const folderColors = ['#ffd21f', '#25d9ff', '#ff5ea8', '#ff8a2a', '#5dff72', '#b77cff'];
    const groups = new Map();
    operations.forEach((item) => {
      const folderName = String(item.relativeFolder || item.folderName || 'Pasta').trim() || 'Pasta';
      if (!groups.has(folderName)) groups.set(folderName, []);
      groups.get(folderName).push(item);
    });
    operationsHtml = Array.from(groups.entries()).map(([folderName, items], index) => `
      <section class="hook-rename-folder-region" style="--hook-folder-color: ${folderColors[index % folderColors.length]}">
        <header class="hook-rename-folder-header">
          <strong>${escapeHtml(folderName)}</strong>
        </header>
        <div class="hook-rename-folder-items">
          ${items.map((item) => renderPreviewItem(item, true)).join('')}
        </div>
      </section>
    `).join('');
  }

  list.innerHTML = `
    ${operationsHtml}
    ${hiddenCount > 0 ? `<p class="muted hook-rename-preview-limit">Mais ${hiddenCount} arquivo(s) não aparecem na lista para manter a tela leve.</p>` : ''}
  `;
  updateHookRenameControls();
}

function clearHookRename() {
  hookRenameFolder = null;
  hookRenameLastPreview = null;
  $('#hookRenameFolderLabel').textContent = 'Nenhuma pasta selecionada';
  $('#hookRenameFolderPath').textContent = 'Escolha uma pasta para começar.';
  $('#hookRenameSuffixInput').value = '';
  $('#hookRenameSuggestedSuffixInput').value = '';
  $('#hookRenameUseFolderSuffixCheck').checked = false;
  $('#hookRenameBulkModeCheck').checked = false;
  resetHookRenameProgress();
  renderHookRenamePreview(null);
}

function applyHookRenameSelection(result) {
  hookRenameFolder = result;
  hookRenameLastPreview = null;
  $('#hookRenameFolderLabel').textContent = result.folderName || 'Pasta selecionada';
  $('#hookRenameFolderPath').textContent = formatHookRenameSelectedPaths(result);
  $('#hookRenameSuggestedSuffixInput').value = result.suggestedSuffix || '';
  $('#hookRenameBulkModeCheck').checked = false;
  resetHookRenameProgress();
  renderHookRenamePreview(null);
  updateHookRenameControls();
}

async function selectHookRenameFolder() {
  const result = await window.hookUpdateCenter.selectHookRenameFolder();
  if (!result?.ok) return;
  applyHookRenameSelection(result);
}

async function selectManyHookRenameFolders() {
  const result = await window.hookUpdateCenter.selectManyHookRenameFolders();
  if (!result?.ok) return;
  applyHookRenameSelection(result);
}

async function generateHookRenamePreview() {
  const folderPaths = getHookRenameFolderPaths();
  if (!folderPaths.length) {
    showModal({ title: 'Hook Rename', message: 'Escolha uma pasta primeiro.', type: 'error' });
    return;
  }
  const payload = getHookRenamePayload();
  if (hookRenameFolder?.multiple && !payload.bulkMode) {
    showModal({ title: 'Hook Rename', message: 'Para várias pastas, marque “Usar nome da pasta como sufixo” e ative “Renomear em massa”.', type: 'error' });
    return;
  }
  if (payload.bulkMode && !payload.useFolderSuffix) {
    showModal({ title: 'Hook Rename', message: 'O modo em massa só funciona usando o nome da pasta como sufixo.', type: 'error' });
    return;
  }
  if (!String(payload.suffix || '').trim()) {
    showModal({ title: 'Hook Rename', message: 'Digite um sufixo ou marque para usar o nome da pasta.', type: 'error' });
    return;
  }

  const button = $('#hookRenamePreviewButton');
  try {
    button.disabled = true;
    button.textContent = 'Gerando...';
    const preview = await window.hookUpdateCenter.previewHookRename(payload);
    renderHookRenamePreview(preview);
  } catch (error) {
    hookRenameLastPreview = null;
    updateHookRenameControls();
    showModal({ title: 'Hook Rename', message: friendlyError(error, 'Não foi possível gerar a prévia.'), type: 'error' });
  } finally {
    button.disabled = false;
    button.textContent = 'Gerar prévia';
  }
}

async function runHookRename() {
  if (!hookRenameLastPreview?.totalOperations) {
    await generateHookRenamePreview();
    if (!hookRenameLastPreview?.totalOperations) return;
  }

  const payload = getHookRenamePayload();
  const confirmed = await confirmModal({
    title: 'Renomear arquivos',
    message: payload.bulkMode
      ? `O Hook Rename vai renomear ${hookRenameLastPreview.totalOperations} arquivo(s) de áudio em ${hookRenameLastPreview.totalFolders || payload.folderPaths.length} pasta(s), sem entrar em subpastas, usando o nome de cada pasta como sufixo.`
      : `O Hook Rename vai renomear ${hookRenameLastPreview.totalOperations} arquivo(s) na pasta selecionada.`,
    type: 'info',
    okText: 'Renomear',
    cancelText: 'Cancelar'
  });

  if (!confirmed) return;

  const runButton = $('#hookRenameRunButton');
  const previewButton = $('#hookRenamePreviewButton');
  try {
    $('#hookRenameProgressArea')?.classList.remove('hidden');
    setHookRenameProgress({ percent: 0, current: 0, total: hookRenameLastPreview.totalOperations });
    runButton.disabled = true;
    previewButton.disabled = true;
    const result = await window.hookUpdateCenter.runHookRename(payload);
    const message = `${result.renamed || 0} arquivo(s) renomeado(s). ${result.totalSkipped || 0} ignorado(s).${result.failed ? ` ${result.failed} falharam.` : ''}`;
    showModal({ title: result.failed ? 'Hook Rename concluído com avisos' : 'Hook Rename concluído', message, type: result.failed ? 'info' : 'success' });
    hookRenameLastPreview = null;
    await generateHookRenamePreview();
  } catch (error) {
    showModal({ title: 'Erro ao renomear', message: friendlyError(error, 'Não foi possível renomear os arquivos.'), type: 'error' });
  } finally {
    runButton.disabled = false;
    previewButton.disabled = false;
    updateHookRenameControls();
  }
}

function setupHookRename() {
  $('#hookRenameSelectFolderButton')?.addEventListener('click', async () => {
    try { await selectHookRenameFolder(); } catch (error) { showModal({ title: 'Hook Rename', message: friendlyError(error, 'Não foi possível escolher a pasta.'), type: 'error' }); }
  });
  $('#hookRenameSelectManyFoldersButton')?.addEventListener('click', async () => {
    try { await selectManyHookRenameFolders(); } catch (error) { showModal({ title: 'Hook Rename', message: friendlyError(error, 'Não foi possível escolher as pastas.'), type: 'error' }); }
  });
  $('#hookRenamePreviewButton')?.addEventListener('click', generateHookRenamePreview);
  $('#hookRenameRunButton')?.addEventListener('click', runHookRename);
  $('#hookRenameClearButton')?.addEventListener('click', clearHookRename);

  $('#hookRenameUseFolderSuffixCheck')?.addEventListener('change', () => {
    hookRenameLastPreview = null;
    renderHookRenamePreview(null);
    updateHookRenameControls();
  });
  $('#hookRenameBulkModeCheck')?.addEventListener('change', () => {
    hookRenameLastPreview = null;
    renderHookRenamePreview(null);
    updateHookRenameControls();
  });
  $('#hookRenameSuffixInput')?.addEventListener('input', () => {
    hookRenameLastPreview = null;
    renderHookRenamePreview(null);
    updateHookRenameControls();
  });

  window.hookUpdateCenter.onHookRenameProgress?.((progress) => {
    $('#hookRenameProgressArea')?.classList.remove('hidden');
    setHookRenameProgress(progress || {});
  });

  updateHookRenameControls();
}

function setToolsPanel(panelName = 'rename') {
  const allowed = ['rename', 'upcoming1', 'upcoming2', 'upcoming3'];
  selectedToolsPanel = allowed.includes(panelName) ? panelName : 'rename';
  $$('[data-tools-panel]').forEach((button) => {
    const active = button.dataset.toolsPanel === selectedToolsPanel;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });
  $$('[data-tools-panel-content]').forEach((panel) => {
    panel.classList.toggle('active', panel.dataset.toolsPanelContent === selectedToolsPanel);
  });
  if (selectedToolsPanel === 'rename') updateHookRenameControls();
}

function setupToolsSubmenu() {
  $$('[data-tools-panel]').forEach((button) => {
    button.addEventListener('click', () => setToolsPanel(button.dataset.toolsPanel));
  });
  setToolsPanel(selectedToolsPanel);
}

function setView(viewName) {
  $$('.nav-item').forEach((button) => button.classList.toggle('active', button.dataset.view === viewName));
  $$('.view').forEach((view) => view.classList.remove('active'));
  $(`#${viewName}View`).classList.add('active');
  document.body.classList.toggle('bridge-mode', viewName === 'bridge');
  document.body.classList.toggle('previous-mode', viewName === 'previous');
  document.body.classList.toggle('lyrics-mode', viewName === 'lyrics');
  document.body.classList.toggle('tools-mode', viewName === 'tools');
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

function setCheckedIfExists(id, value) {
  const el = document.getElementById(id);
  if (el) el.checked = value === true;
}

function applyLyricsSettingsToForm(settings = {}) {
  const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj || {}, key);
  const isSlotMap = hasOwn(settings, 1) || hasOwn(settings, '1') || hasOwn(settings, 2) || hasOwn(settings, '2');
  const all = isSlotMap ? settings : { 1: settings, 2: settings };
  const slots = isSlotMap ? [1, 2].filter((slot) => hasOwn(all, slot) || hasOwn(all, String(slot))) : [1, 2];
  slots.forEach((slot) => {
    const data = all[slot] || all[String(slot)] || {};
    if (!data || typeof data !== 'object') return;
    selectedLyricsPresets[slot] = data.preset === 'day' ? 'day' : 'night';
    $$(`[data-lyrics-preset-slot="${slot}"]`).forEach((button) => {
      button.classList.toggle('preset-selected', button.dataset.lyricsPreset === selectedLyricsPresets[slot]);
    });
    const textColor = $(`#lyricsTextColor${slot}`);
    const clockColor = $(`#lyricsClockColor${slot}`);
    const textBoxColor = $(`#lyricsTextBoxColor${slot}`);
    const borderColor = $(`#lyricsBorderColor${slot}`);
    const rgbBorderEnabled = $(`#lyricsRgbBorderEnabled${slot}`);
    const rgbWindowBorderEnabled = $(`#lyricsRgbWindowBorderEnabled${slot}`);
    const rgbClockBorderEnabled = $(`#lyricsRgbClockBorderEnabled${slot}`);
    const rgbTextBoxBorderEnabled = $(`#lyricsRgbTextBoxBorderEnabled${slot}`);
    const textCase = $(`#lyricsTextCase${slot}`);
    const fontFamily = $(`#lyricsFontFamily${slot}`);
    const textScale = $(`#lyricsTextScale${slot}`);
    const borderEnabled = $(`#lyricsBorderEnabled${slot}`);
    const windowBorderEnabled = $(`#lyricsWindowBorderEnabled${slot}`);
    const clockBorderEnabled = $(`#lyricsClockBorderEnabled${slot}`);
    const textBoxEnabled = $(`#lyricsTextBoxEnabled${slot}`);
    const clockEnabled = $(`#lyricsClockEnabled${slot}`);
    const songNameEnabled = $(`#lyricsSongNameEnabled${slot}`);
    const songNameColor = $(`#lyricsSongNameColor${slot}`);
    const queueNameColor = $(`#lyricsQueueNameColor${slot}`);
    const queueNameEnabled = $(`#lyricsQueueNameEnabled${slot}`);
    const queueNameDepth = $(`#lyricsQueueNameDepth${slot}`);
    const queueNameFontFamily = $(`#lyricsQueueNameFontFamily${slot}`);
    const songNameFontFamily = $(`#lyricsSongNameFontFamily${slot}`);
    const songNameScale = $(`#lyricsSongNameScale${slot}`);
    const songNamePosition = $(`#lyricsSongNamePosition${slot}`);
    const progressEnabled = $(`#lyricsProgressEnabled${slot}`);
    const progressPosition = $(`#lyricsProgressPosition${slot}`);
    const progressColor = $(`#lyricsProgressColor${slot}`);
    const queueNamePosition = $(`#lyricsQueueNamePosition${slot}`);
    const clockPosition = $(`#lyricsClockPosition${slot}`);
    const clockScale = $(`#lyricsClockScale${slot}`);
    const mediaScale = $(`#lyricsMediaScale${slot}`);
    const previewScale = $(`#lyricsPreviewScale${slot}`);
    const previewEnabled = $(`#lyricsPreviewEnabled${slot}`);
    const alwaysOnTop = $(`#lyricsAlwaysOnTop${slot}`);
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
    if (textCase) {
      textCase.value = data.textCase === 'lowercase'
        ? 'lowercase'
        : (data.textCase === 'original' ? 'original' : 'uppercase');
    }
    if (fontFamily) fontFamily.value = data.fontFamily || 'Arial';
    if (textScale) textScale.value = String(Math.round((Number(data.textScale || 1) || 1) * 100));
    if (borderEnabled) borderEnabled.checked = data.borderEnabled !== false;
    if (windowBorderEnabled) windowBorderEnabled.checked = data.windowBorderEnabled ?? data.borderEnabled ?? true;
    if (clockBorderEnabled) clockBorderEnabled.checked = data.clockBorderEnabled ?? data.borderEnabled ?? true;
    if (textBoxEnabled) textBoxEnabled.checked = data.textBoxEnabled ?? true;
    if (clockEnabled) clockEnabled.checked = data.clockEnabled !== false;
    if (songNameEnabled) songNameEnabled.checked = data.songNameEnabled === true;
    if (songNameColor) songNameColor.value = data.songNameColor || data.clockColor || '#00ff55';
    if (queueNameColor) queueNameColor.value = data.queueNameColor || '#ffea00';
    if (queueNameEnabled) queueNameEnabled.checked = data.queueNameEnabled !== false;
    if (queueNameDepth) queueNameDepth.value = String(Math.max(0, Math.min(240, Math.round(Number(data.queueNameDepth ?? 80) || 80))));
    if (queueNameFontFamily) queueNameFontFamily.value = data.queueNameFontFamily || data.songNameFontFamily || data.fontFamily || 'Arial';
    if (songNameFontFamily) songNameFontFamily.value = data.songNameFontFamily || data.fontFamily || 'Arial';
    if (songNameScale) songNameScale.value = String(Math.round((Number(data.songNameScale || 1) || 1) * 100));
    if (songNamePosition) songNamePosition.value = normalizeLyricsScreenPosition(data.songNamePosition, 'top');
    if (progressEnabled) progressEnabled.checked = data.progressEnabled === true;
    if (progressPosition) progressPosition.value = normalizeLyricsScreenPosition(data.progressPosition, 'bottom');
    if (progressColor) progressColor.value = data.progressColor || '#ffea00';
    if (queueNamePosition) queueNamePosition.value = normalizeLyricsScreenPosition(data.queueNamePosition, 'top');
    if (clockPosition) clockPosition.value = data.clockPosition === 'bottom' ? 'bottom' : 'top';
    if (clockScale) clockScale.value = String(Math.round((Number(data.clockScale || 1) || 1) * 100));
    if (mediaScale) mediaScale.value = String(Math.round((Number(data.mediaScale || 1) || 1) * 100));
    if (previewScale) previewScale.value = String(Math.round((Number(data.previewScale || 1) || 1) * 100));
    if (previewEnabled) previewEnabled.checked = data.previewEnabled !== false;
    if (alwaysOnTop) alwaysOnTop.checked = data.alwaysOnTop === true;
    setCheckedIfExists(`lyricsAlwaysOnTopQuick${slot}`, data.alwaysOnTop === true);
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
  const recadosPassword = $('#technicalNoticeRecadosPassword');
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
  if (recadosPassword) recadosPassword.value = String(settings.recadosPassword || '');
  recadosHubTemplates = [0, 1, 2].map((index) => String(settings.recadosTemplates?.[index] || ''));
  if (recadosHubSelectedSlot !== 'global' && !recadosHubEditingTemplate) syncHubRecadosModal();
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
    preset: selectedLyricsPresets[id] === 'day' ? 'day' : 'night',
    textColor: $(`#lyricsTextColor${id}`)?.value || '#ffea00',
    clockColor: $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    textBoxColor: $(`#lyricsTextBoxColor${id}`)?.value || $(`#lyricsTextColor${id}`)?.value || '#ffea00',
    borderColor: $(`#lyricsBorderColor${id}`)?.value || $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    rgbBorderEnabled: $(`#lyricsRgbWindowBorderEnabled${id}`)?.checked === true,
    rgbWindowBorderEnabled: $(`#lyricsRgbWindowBorderEnabled${id}`)?.checked === true,
    rgbClockBorderEnabled: $(`#lyricsRgbClockBorderEnabled${id}`)?.checked === true,
    rgbTextBoxBorderEnabled: $(`#lyricsRgbTextBoxBorderEnabled${id}`)?.checked === true,
    textCase: ['lowercase', 'original'].includes($(`#lyricsTextCase${id}`)?.value)
      ? $(`#lyricsTextCase${id}`).value
      : 'uppercase',
    fontFamily: $(`#lyricsFontFamily${id}`)?.value || 'Arial',
    textScale: Math.max(0.5, Math.min(1.25, (Number($(`#lyricsTextScale${id}`)?.value || 100) / 100))),
    borderEnabled: $(`#lyricsWindowBorderEnabled${id}`)?.checked !== false,
    windowBorderEnabled: $(`#lyricsWindowBorderEnabled${id}`)?.checked !== false,
    clockBorderEnabled: $(`#lyricsClockBorderEnabled${id}`)?.checked !== false,
    textBoxEnabled: $(`#lyricsTextBoxEnabled${id}`)?.checked !== false,
    clockEnabled: $(`#lyricsClockEnabled${id}`)?.checked !== false,
    songNameEnabled: $(`#lyricsSongNameEnabled${id}`)?.checked === true,
    songNameColor: $(`#lyricsSongNameColor${id}`)?.value || $(`#lyricsClockColor${id}`)?.value || '#00ff55',
    queueNameColor: $(`#lyricsQueueNameColor${id}`)?.value || '#ffea00',
    queueNameEnabled: $(`#lyricsQueueNameEnabled${id}`)?.checked !== false,
    queueNamePosition: normalizeLyricsScreenPosition($(`#lyricsQueueNamePosition${id}`)?.value, 'top'),
    queueNameDepth: Math.max(0, Math.min(240, Math.round(Number($(`#lyricsQueueNameDepth${id}`)?.value || 80)))),
    queueNameFontFamily: $(`#lyricsQueueNameFontFamily${id}`)?.value || $(`#lyricsSongNameFontFamily${id}`)?.value || $(`#lyricsFontFamily${id}`)?.value || 'Arial',
    songNameFontFamily: $(`#lyricsSongNameFontFamily${id}`)?.value || $(`#lyricsFontFamily${id}`)?.value || 'Arial',
    songNameScale: Math.max(0.5, Math.min(3, (Number($(`#lyricsSongNameScale${id}`)?.value || 100) / 100))),
    songNamePosition: normalizeLyricsScreenPosition($(`#lyricsSongNamePosition${id}`)?.value, 'top'),
    progressEnabled: $(`#lyricsProgressEnabled${id}`)?.checked === true,
    progressPosition: normalizeLyricsScreenPosition($(`#lyricsProgressPosition${id}`)?.value, 'bottom'),
    progressColor: $(`#lyricsProgressColor${id}`)?.value || '#ffea00',
    clockPosition: $(`#lyricsClockPosition${id}`)?.value === 'bottom' ? 'bottom' : 'top',
    clockScale: Math.max(0.5, Math.min(2.5, (Number($(`#lyricsClockScale${id}`)?.value || 100) / 100))),
    mediaScale: Math.max(0.5, Math.min(1, (Number($(`#lyricsMediaScale${id}`)?.value || 100) / 100))),
    previewEnabled: $(`#lyricsPreviewEnabled${id}`)?.checked !== false,
    previewScale: Math.max(0.5, Math.min(1, (Number($(`#lyricsPreviewScale${id}`)?.value || 100) / 100))),
    alwaysOnTop: ($(`#lyricsAlwaysOnTop${id}`)?.checked === true) || ($(`#lyricsAlwaysOnTopQuick${id}`)?.checked === true),
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
    emoji: ($('#technicalNoticeEmoji')?.value || '⚠️').trim().slice(0, 8) || '⚠️',
    recadosPassword: ($('#technicalNoticeRecadosPassword')?.value || '').trim(),
    recadosTemplates: recadosHubTemplates.map((text) => String(text || '').trim())
  };
  const saved = await window.hookUpdateCenter.saveTechnicalNoticeSettings(payload);
  applyTechnicalNoticeSettingsToForm(saved);
  return saved;
}

async function saveAllTelepromptSettingsFromForm() {
  await saveLyricsSettingsFromForm(1);
  await saveLyricsSettingsFromForm(2);
  await saveTechnicalNoticeSettingsFromForm();
}

async function exportTelepromptBackupFromForm() {
  await saveAllTelepromptSettingsFromForm();
  return window.hookUpdateCenter.exportLyricsBackup();
}

async function importTelepromptBackupToForm() {
  const result = await window.hookUpdateCenter.importLyricsBackup();
  if (result?.ok) {
    if (result.lyrics) applyLyricsSettingsToForm(result.lyrics);
    if (result.technicalNoticeSettings) applyTechnicalNoticeSettingsToForm(result.technicalNoticeSettings);
  }
  return result;
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
      `lyricsTextCase${slot}`,
      `lyricsFontFamily${slot}`,
      `lyricsTextScale${slot}`,
      `lyricsBorderEnabled${slot}`,
      `lyricsWindowBorderEnabled${slot}`,
      `lyricsClockBorderEnabled${slot}`,
      `lyricsTextBoxEnabled${slot}`,
      `lyricsClockEnabled${slot}`,
      `lyricsSongNameEnabled${slot}`,
      `lyricsQueueNameEnabled${slot}`,
      `lyricsSongNameColor${slot}`,
      `lyricsQueueNameColor${slot}`,
      `lyricsQueueNameDepth${slot}`,
      `lyricsQueueNamePosition${slot}`,
      `lyricsSongNameFontFamily${slot}`,
      `lyricsSongNameScale${slot}`,
      `lyricsSongNamePosition${slot}`,
      `lyricsProgressEnabled${slot}`,
      `lyricsProgressPosition${slot}`,
      `lyricsProgressColor${slot}`,
      `lyricsClockPosition${slot}`,
      `lyricsClockScale${slot}`,
      `lyricsMediaScale${slot}`,
      `lyricsPreviewScale${slot}`,
      `lyricsPreviewEnabled${slot}`,
      `lyricsAlwaysOnTop${slot}`,
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

  ['technicalNoticeTextColor', 'technicalNoticeFlashColor', 'technicalNoticeFontFamily', 'technicalNoticeWindow1Enabled', 'technicalNoticeWindow2Enabled', 'technicalNoticeEmojiEnabled', 'technicalNoticeRecadosPassword'].forEach((id) => {
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
  currentBridgeState = bridge;
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
  renderBridgeNetworkOptions(bridge);
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

function renderBridgeNetworkOptions(bridge = currentBridgeState) {
  const container = $('#bridgeNetworkOptions');
  if (!container || !bridge) return;
  const networks = Array.isArray(bridge.lanIps)
    ? bridge.lanIps : [];
  const selectedIp = String(
    bridge.selectedNetworkIp || bridge.lanIp || '');
  container.innerHTML = '';
  if (!networks.length) {
    const empty = document.createElement('p');
    empty.className = 'muted';
    empty.textContent = 'Nenhuma rede local encontrada.';
    container.appendChild(empty);
    return;
  }
  networks.forEach((item) => {
    const ip = String(item?.ip || '');
    const selected = !!ip && ip === selectedIp;
    const button = document.createElement('button');
    button.type = 'button';
    button.className =
      `bridge-network-option${selected
        ? ' bridge-network-option-selected' : ''}`;
    button.dataset.networkIp = ip;

    const name = document.createElement('strong');
    name.textContent = String(item?.name || 'Rede');
    const address = document.createElement('span');
    address.textContent = ip || '--';
    button.append(name, address);
    if (selected) {
      const badge = document.createElement('em');
      badge.textContent = 'EM USO';
      button.appendChild(badge);
    }
    container.appendChild(button);
  });
}

async function openBridgeNetworkModal() {
  $('#bridgeNetworkModal')?.classList.remove('hidden');
  try {
    const bridge =
      await window.hookUpdateCenter.getBridgeState();
    renderBridgeState(bridge);
  } catch (_) {
    renderBridgeNetworkOptions();
  }
  $('#closeBridgeNetworkModalButton')?.focus();
}

function closeBridgeNetworkModal() {
  $('#bridgeNetworkModal')?.classList.add('hidden');
}

async function selectBridgeNetworkFromModal(ip) {
  const selectedIp = String(ip || '');
  if (!selectedIp) return;
  const buttons = $$('#bridgeNetworkOptions button');
  buttons.forEach((button) => { button.disabled = true; });
  try {
    const bridge =
      await window.hookUpdateCenter.selectBridgeNetwork({
        ip: selectedIp
      });
    renderBridgeState(bridge);
    closeBridgeNetworkModal();
    showModal({
      title: 'Rede do app alterada',
      message:
        'O endereço e o QR Code agora usam a rede escolhida.',
      type: 'success'
    });
  } catch (error) {
    showModal({
      title: 'Erro ao trocar a rede',
      message: friendlyError(error,
        'Não foi possível usar a rede escolhida.'),
      type: 'error'
    });
    await refreshBridgeState();
  } finally {
    buttons.forEach((button) => { button.disabled = false; });
  }
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


function formatHookCenterDisplayVersion(version) {
  const raw = String(version || '2.1.0').replace(/^v/i, '').trim();
  const numeric = raw
    .replace(/[^0-9.].*$/g, '')
    .replace(/\.0$/g, '');
  const base = numeric || raw || '2.1';
  return `v${base} C`;
}

function updateDescriptionFits(element) {
  return element.scrollHeight <= element.clientHeight + 1
    && element.scrollWidth <= element.clientWidth + 1;
}

function fitUpdateDescriptionText() {
  if (updateDescriptionFitFrame) cancelAnimationFrame(updateDescriptionFitFrame);
  updateDescriptionFitFrame = requestAnimationFrame(() => {
    updateDescriptionFitFrame = 0;
    const card = $('#updateDescriptionCard');
    const description = $('#updateDescription');
    if (!card || !description || card.classList.contains('hidden') || !description.textContent) {
      description?.style.removeProperty('font-size');
      return;
    }

    const maximumFontSize = 18;
    const minimumFontSize = 1;
    description.style.setProperty('font-size', `${maximumFontSize}px`, 'important');
    if (updateDescriptionFits(description)) return;

    let lower = minimumFontSize;
    let upper = maximumFontSize;
    for (let index = 0; index < 12; index += 1) {
      const candidate = (lower + upper) / 2;
      description.style.setProperty('font-size', `${candidate}px`, 'important');
      if (updateDescriptionFits(description)) lower = candidate;
      else upper = candidate;
    }

    const fittedSize = Math.max(minimumFontSize, Math.floor(lower * 10) / 10);
    description.style.setProperty('font-size', `${fittedSize}px`, 'important');
  });
}

function showBackendUpdateDescription(value) {
  const card = $('#updateDescriptionCard');
  const description = $('#updateDescription');
  if (!card || !description) return;
  description.textContent = String(value || '').trim();
  card.classList.remove('hidden');
  card.setAttribute('aria-hidden', 'false');
  fitUpdateDescriptionText();
}

function renderState(nextState) {
  state = nextState;
  updateLyricsWindowButtons();
  $('#currentVersion').textContent = formatHookCenterDisplayVersion(state.statusDisplayVersion || state.currentVersion);
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
  const statusTestUpdate = isTestClientUpdate(state.testClientUpdate) ? state.testClientUpdate : null;
  $('#updateStatus').textContent = statusTestUpdate ? 'Atualização de cliente teste disponível' : 'Sem atualização de cliente teste';

  const hc = state.hookCenterLatest || {};
  const hcLearnButton = $('#hookCenterLearnButton');
  const hasTutorial = !!(hc.tutorialUrl || hc.learnUrl || hc.videoUrl);
  if (hcLearnButton) {
    hcLearnButton.classList.toggle('hidden', !hasTutorial);
    hcLearnButton.disabled = !hasTutorial;
    hcLearnButton.textContent = 'Quero aprender tudo sobre o VS Hook';
    hcLearnButton.removeAttribute('title');
  }
  const hasLatest = !!state.latestUpdate;
  const hasHookCenterUpdate = state.hookCenterUpdateAvailable === true;
  const hasHomeUpdate = hasLatest || hasHookCenterUpdate;
  const hasStatusTestUpdate = !!statusTestUpdate;
  $('#noUpdateCard').classList.toggle('hidden', hasHomeUpdate);
  $('#updateCard').classList.toggle('hidden', !hasHomeUpdate);
  $('#installedVsHookVersionLine')?.classList.toggle('hidden', !hasLatest);
  $('#statusNoUpdateInstallCard')?.classList.toggle('hidden', hasStatusTestUpdate);
  $('#statusUpdateInstallCard')?.classList.toggle('hidden', !hasStatusTestUpdate);

  if (hasLatest) {
    const update = state.latestUpdate;
    // A descrição da atualização do VS Hook fica exclusivamente no card separado de cima.
    // Remove do DOM qualquer descrição herdada que ainda exista dentro dos cards do VS Hook.
    document.querySelectorAll('#updateCard .description, #updateCard [data-update-description], #updateCard .changelog, #noUpdateCard .description, #statusUpdateInstallCard .description, #statusUpdateDescription').forEach((el) => el.remove());
    const vsHookTitle = update.title || `VS Hook ${update.version || ''}`;
    const displayTitle = hasHookCenterUpdate ? `${vsHookTitle} + Hook Center` : vsHookTitle;
    const displayVersion = hasHookCenterUpdate ? '2 ATUALIZAÇÕES' : (update.version ? `v${update.version}` : 'VS Hook');
    $('#updateTitle').textContent = displayTitle;
    $('#versionBadge').textContent = displayVersion;
    const homeDescriptionCard = $('#updateDescriptionCard');
    const homeDescription = $('#updateDescription');
    if (homeDescriptionCard && homeDescription) {
      // Exibe somente a descrição publicada para o pacote VS Hook no backend.
      // Não acrescenta título, versão, changelog ou dados da atualização da Hook Center.
      showBackendUpdateDescription(update.description);
    }

    const rawYoutubeUrl = update.youtubeUrl || '';
    currentYoutubeWatchUrl = normalizeYoutubeWatchUrl(rawYoutubeUrl);
    $('#videoBox').classList.toggle('hidden', !currentYoutubeWatchUrl);
    $('#videoModalTitle').textContent = vsHookTitle;

    // A descrição/changelog da atualização do VS Hook fica exclusivamente no card amarelo separado.
    // Não renderiza lista dentro do card principal para evitar duplicidade e liberar espaço.
    const changelogListEl = $('#changelogList');
    if (changelogListEl) {
      changelogListEl.innerHTML = '';
      changelogListEl.classList.add('hidden');
      changelogListEl.setAttribute('aria-hidden', 'true');
    }
  } else if (hasHookCenterUpdate) {
    $('#updateTitle').textContent = hc.title || 'Atualização do Hook Center';
    $('#versionBadge').textContent = hc.version ? `v${hc.version}` : 'HOOK CENTER';
    const homeDescriptionCard = $('#updateDescriptionCard');
    const homeDescription = $('#updateDescription');
    if (homeDescriptionCard && homeDescription) {
      showBackendUpdateDescription(hc.notes);
    }
    currentYoutubeWatchUrl = '';
    $('#videoBox')?.classList.add('hidden');
    const changelogListEl = $('#changelogList');
    if (changelogListEl) {
      changelogListEl.innerHTML = '';
      changelogListEl.classList.add('hidden');
      changelogListEl.setAttribute('aria-hidden', 'true');
    }
  } else {
    const homeDescriptionCard = $('#updateDescriptionCard');
    if (homeDescriptionCard) {
      homeDescriptionCard.classList.add('hidden');
      homeDescriptionCard.setAttribute('aria-hidden', 'true');
    }
    const homeDescription = $('#updateDescription');
    if (homeDescription) {
      homeDescription.textContent = '';
      homeDescription.style.removeProperty('font-size');
    }
  }

  const homeDownloadButton = $('#downloadButton');
  if (homeDownloadButton && !combinedDownloadInProgress) {
    homeDownloadButton.disabled = !hasHomeUpdate;
    homeDownloadButton.textContent = state.currentPackageInstalled ? 'Reinstalar' : 'Baixar';
  }

  if (hasStatusTestUpdate) {
    const update = statusTestUpdate;
    const displayTitle = update.title || `VS Hook ${update.version || ''}`;
    const displayVersion = update.version ? `v${update.version}` : 'VS Hook';
    const statusTitle = $('#statusUpdateTitle');
    if (statusTitle) statusTitle.textContent = displayTitle;
    const statusBadge = $('#statusVersionBadge');
    if (statusBadge) statusBadge.textContent = displayVersion;
    document.querySelectorAll('#statusUpdateInstallCard .description, #statusUpdateDescription').forEach((el) => el.remove());
    const statusDownloadButton = $('#statusDownloadButton');
    if (statusDownloadButton) {
      statusDownloadButton.disabled = !hasInstallableFiles(update);
      statusDownloadButton.textContent = 'Baixar';
    }
  } else {
    const statusTitle = $('#statusUpdateTitle');
    if (statusTitle) statusTitle.textContent = 'Atualização disponível';
    const statusBadge = $('#statusVersionBadge');
    if (statusBadge) statusBadge.textContent = 'VS Hook';
    document.querySelectorAll('#statusUpdateInstallCard .description, #statusUpdateDescription').forEach((el) => el.remove());
    const statusDownloadButton = $('#statusDownloadButton');
    if (statusDownloadButton) {
      statusDownloadButton.disabled = true;
      statusDownloadButton.textContent = 'Baixar';
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

  // Garante que nenhum card de atualização do VS Hook volte a exibir descrição duplicada.
  document.querySelectorAll('#updateCard .description, #updateCard [data-update-description], #updateCard .changelog, #noUpdateCard .description, #statusUpdateInstallCard .description, #statusUpdateDescription').forEach((el) => el.remove());

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
  const hasExpectedName = (value, expectedName) => {
    try {
      const filename = decodeURIComponent(new URL(String(value || ''), 'https://local.invalid').pathname.split('/').pop() || '').toLowerCase();
      return filename === expectedName.toLowerCase();
    } catch (_) {
      return false;
    }
  };

  if (state?.platform === 'darwin') {
    return hasExpectedName(files.vshookDylib || files.vshookExtDylib, 'reaper_VSHookExt.dylib');
  }

  return hasExpectedName(files.vshookDll || files.vshookExtDll, 'reaper_VSHookExt.dll');
}

function getInstallerUrlForUpdate(update) {
  const files = getPlatformFilesForUpdate(update);
  const direct = files?.installer || files?.exe || files?.dmg || update?.installerUrl || update?.downloadUrl || '';
  if (String(direct || '').trim()) return String(direct).trim();

  const hookCenter = state?.hookCenterLatest || {};
  const sameCurrentVersion = update?.current === true &&
    String(update?.version || '').trim() &&
    String(update?.version || '').trim() === String(hookCenter?.version || '').trim();
  return sameCurrentVersion ? String(hookCenter?.downloadUrl || '').trim() : '';
}

function hasCompleteInstallablePackage(update) {
  return hasInstallableFiles(update) && Boolean(getInstallerUrlForUpdate(update));
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
    const cached = update.cached === true;
    const installed = update.installed === true;
    const current = update.current === true;
    const packageAvailable = cached || hasCompleteInstallablePackage(update);

    return `
      <div class="card previous-update-card">
        <div class="update-header">
          <div>
            <p class="eyebrow">${current ? 'Versão atual' : 'Versão anterior'}</p>
            <h2>${title}</h2>
            <p class="muted">${date}</p>
          </div>
          <span class="badge">v${version}</span>
        </div>
        ${description ? `<p class="description">${description}</p>` : ''}
        <p class="previous-local-status ${cached ? 'is-cached' : ''}">
          ${cached ? 'Salva neste computador' : 'Disponível somente online'}${installed ? ' · instalada' : ''}
        </p>
        <div class="actions">
          <button class="primary-button previous-install-button" data-index="${index}" ${packageAvailable ? '' : 'disabled'}>${packageAvailable ? 'Instalar' : 'Indisponível'}</button>
          <button class="${cached ? 'danger-button' : 'secondary-button'} previous-cache-button" data-index="${index}" ${packageAvailable ? '' : 'disabled'}>
            ${cached ? 'Remover do meu PC' : packageAvailable ? 'Manter no meu PC' : 'Indisponível'}
          </button>
        </div>
      </div>
    `;
  }).join('');

  list.querySelectorAll('.previous-install-button').forEach((button) => {
    button.addEventListener('click', async () => {
      const index = Number(button.dataset.index);
      const update = updates[index];
      if (!hasCompleteInstallablePackage(update) && update.cached !== true) {
        showModal({ title: 'Versão indisponível', message: 'Não há arquivos disponíveis para esta versão neste sistema.', type: 'error' });
        return;
      }

      try {
        if (!(await ensureLicenseActiveForDownload())) return;
        const confirmed = await confirmModal({
          title: `Instalar versão ${update.version || ''}?`,
          message: update.cached
            ? 'A extensão será instalada e o instalador da Hook Center salvo no computador será aberto.'
            : 'Esta versão será baixada, mantida no computador e depois instalada por completo.',
          type: 'info',
          okText: 'Instalar',
          cancelText: 'Cancelar'
        });
        if (!confirmed) return;
        button.disabled = true;
        button.textContent = update.cached ? 'Instalando...' : 'Baixando...';
        await window.hookUpdateCenter.installCachedUpdatePackage({ update });
        if (state?.platform === 'darwin') {
          renderState(await window.hookUpdateCenter.getState());
          await loadPreviousUpdates();
          showModal({ title: 'Instalação pronta', message: 'A extensão foi instalada e o instalador da Hook Center foi aberto.', type: 'success' });
        }
      } catch (error) {
        showModal({ title: 'Erro ao instalar', message: friendlyError(error, 'Não foi possível instalar esta versão.'), type: 'error' });
      } finally {
        button.disabled = false;
        button.textContent = 'Instalar';
      }
    });
  });

  list.querySelectorAll('.previous-cache-button').forEach((button) => {
    button.addEventListener('click', async () => {
      const index = Number(button.dataset.index);
      const update = updates[index];
      try {
        if (update.cached) {
          const confirmed = await confirmModal({
            title: 'Remover esta versão do computador?',
            message: 'Se remover do PC, pode ser que esta atualização não esteja disponível para baixar novamente.',
            type: 'warning',
            okText: 'Remover do meu PC',
            cancelText: 'Cancelar'
          });
          if (!confirmed) return;
          button.disabled = true;
          button.textContent = 'Removendo...';
          await window.hookUpdateCenter.removeCachedUpdatePackage({ update });
        } else {
          if (!hasCompleteInstallablePackage(update)) {
            showModal({ title: 'Versão indisponível', message: 'Esta versão não possui a extensão e o instalador compatíveis com este sistema.', type: 'error' });
            return;
          }
          if (!(await ensureLicenseActiveForDownload())) return;
          button.disabled = true;
          button.textContent = 'Baixando...';
          await window.hookUpdateCenter.cacheUpdatePackage({ update });
        }
        renderState(await window.hookUpdateCenter.getState());
        await loadPreviousUpdates();
      } catch (error) {
        showModal({
          title: update.cached ? 'Erro ao remover' : 'Erro ao guardar',
          message: friendlyError(error, update.cached ? 'Não foi possível remover esta versão do computador.' : 'Não foi possível guardar esta versão no computador.'),
          type: 'error'
        });
      } finally {
        button.disabled = false;
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
  const sidebar = document.querySelector('.sidebar');
  if (shell) shell.classList.remove('sidebar-open');
  document.body.classList.remove('sidebar-open');
  if (sidebar) sidebar.removeAttribute('aria-hidden');
}


async function init() {
  setupSidebarToggle();
  window.addEventListener('resize', fitUpdateDescriptionText);
  const updateDescriptionCard = $('#updateDescriptionCard');
  if (updateDescriptionCard && typeof ResizeObserver === 'function') {
    updateDescriptionResizeObserver = new ResizeObserver(fitUpdateDescriptionText);
    updateDescriptionResizeObserver.observe(updateDescriptionCard);
  }
  $$('[data-lyrics-config-slot]').forEach((button) => {
    button.addEventListener('click', () => setLyricsConfigSlot(button.dataset.lyricsConfigSlot));
  });
  setLyricsConfigSlot(selectedLyricsConfigSlot);
  [1, 2].forEach((slot) => {
    $$(`[data-lyrics-preset-slot="${slot}"]`).forEach((button) => {
      button.classList.toggle('preset-selected', button.dataset.lyricsPreset === selectedLyricsPresets[slot]);
    });
  });
  $$('.lyrics-preset-button').forEach((button) => {
    button.addEventListener('click', async () => {
      try { await applyLyricsPreset(button.dataset.lyricsPresetSlot, button.dataset.lyricsPreset); }
      catch (error) { showModal({ title: 'Teleprompt', message: friendlyError(error, 'Não foi possível aplicar o preset.'), type: 'error' }); }
    });
  });
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
  $('#openTechnicalNoticeModalButton')?.addEventListener('click', openTechnicalNoticeModal);
  $('#openRecadosModalButton')?.addEventListener('click', openRecadosModal);
  $('#closeTechnicalNoticeModalButton')?.addEventListener('click', closeTechnicalNoticeModal);
  $('#closeTechnicalNoticeModalSecondaryButton')?.addEventListener('click', closeTechnicalNoticeModal);
  $('#closeRecadosModalButton')?.addEventListener('click', closeRecadosModal);
  $('#closeRecadosModalSecondaryButton')?.addEventListener('click', exitRecadosModal);
  $('#technicalNoticeModal')?.addEventListener('click', (event) => {
    if (event.target.id === 'technicalNoticeModal') closeTechnicalNoticeModal();
  });
  $('#recadosModal')?.addEventListener('click', (event) => {
    if (event.target.id === 'recadosModal') closeRecadosModal();
  });
  $$('[data-recados-slot]').forEach((button) => {
    button.addEventListener('click', () => selectHubRecadosSlot(button.dataset.recadosSlot));
  });
  $('#editRecadosTemplateButton')?.addEventListener('click', toggleHubRecadosTemplateEdit);
  $('#toggleRecadosPinButton')?.addEventListener('click', async () => {
    const input = $('#recadosDraftInput');
    if (input) {
      if (recadosHubSelectedSlot === 'global') recadosHubGlobalDraft = input.value;
      else if (recadosHubEditingTemplate) recadosHubTemplates[Number(recadosHubSelectedSlot)] = input.value;
    }
    const nextPinned = !recadosHubPinned;
    try {
      if (recadosHubNoticeActive) {
        const result = await window.hookUpdateCenter.setRecadosNoticePinned({ pinned: nextPinned });
        recadosHubExpiresAt = Number(result?.notice?.expiresAt || 0);
        recadosHubRemainingMs = Math.max(0, Number(result?.notice?.pausedRemainingMs || 0));
      }
      recadosHubPinned = nextPinned;
      if (recadosHubNoticeActive) updateHubRecadosCountdown();
      else $('#recadosModalStatus').textContent = '';
    } catch (error) {
      $('#recadosModalStatus').textContent = friendlyError(error, 'Não foi possível alterar o recado.');
    }
    syncHubRecadosModal();
  });
  $('#sendRecadosButton')?.addEventListener('click', async () => {
    const text = String($('#recadosDraftInput')?.value || '').trim();
    if (!text) { $('#recadosModalStatus').textContent = 'Digite um recado antes de enviar.'; return; }
    try {
      const result = await window.hookUpdateCenter.sendRecadosNotice({ text, pinned: recadosHubPinned });
      recadosHubNoticeActive = result?.ignoredDuePriority !== true;
      recadosHubExpiresAt = Number(result?.notice?.expiresAt || 0);
      recadosHubRemainingMs = Math.max(0, Number(result?.notice?.pausedRemainingMs || 0));
      if (result?.ignoredDuePriority) $('#recadosModalStatus').textContent = 'DIRETOR EM PRIORIDADE';
      else updateHubRecadosCountdown();
    } catch (error) {
      $('#recadosModalStatus').textContent = friendlyError(error, 'Não foi possível enviar o recado.');
    }
  });
  $('#cancelRecadosButton')?.addEventListener('click', async () => {
    try {
      const result = await window.hookUpdateCenter.cancelRecadosNotice();
      recadosHubNoticeActive = false;
      recadosHubExpiresAt = 0;
      recadosHubRemainingMs = 0;
      $('#recadosModalStatus').textContent = result?.ignoredDuePriority ? 'DIRETOR EM PRIORIDADE' : 'RECADO REMOVIDO';
    } catch (error) {
      $('#recadosModalStatus').textContent = friendlyError(error, 'Não foi possível retirar o recado.');
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      if (!$('#technicalNoticeModal')?.classList.contains('hidden')) closeTechnicalNoticeModal();
      else if (!$('#recadosModal')?.classList.contains('hidden')) closeRecadosModal();
      else if (!$('#bridgeNetworkModal')?.classList.contains('hidden')) closeBridgeNetworkModal();
      else if (!$('#supportQrModal')?.classList.contains('hidden')) closeSupportQrModal();
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
        if (button.dataset.view === 'tools') updateHookRenameControls();
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

  setupToolsSubmenu();
  setupHookRename();

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
  $('#openBridgeNetworkModalButton')?.addEventListener(
    'click', openBridgeNetworkModal);
  $('#closeBridgeNetworkModalButton')?.addEventListener(
    'click', closeBridgeNetworkModal);
  $('#bridgeNetworkModal')?.addEventListener('click', (event) => {
    if (event.target.id === 'bridgeNetworkModal') {
      closeBridgeNetworkModal();
    }
  });
  $('#bridgeNetworkOptions')?.addEventListener('click', (event) => {
    const button =
      event.target.closest('[data-network-ip]');
    if (button) {
      selectBridgeNetworkFromModal(
        button.dataset.networkIp);
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
      closeTechnicalNoticeModal();
    } catch (error) {
      showModal({ title: 'Avisos técnicos', message: friendlyError(error, 'Não foi possível salvar a aparência dos avisos técnicos.'), type: 'error' });
    }
  });
  $('#exportLyricsBackupButton')?.addEventListener('click', async () => {
    try {
      const result = await exportTelepromptBackupFromForm();
      if (result?.cancelled) return;
      showModal({ title: 'Backup do Teleprompt', message: 'Backup exportado com as duas janelas, presets, avisos técnicos e recados salvos.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Backup do Teleprompt', message: friendlyError(error, 'Não foi possível exportar o backup do Teleprompt.'), type: 'error' });
    }
  });
  $('#importLyricsBackupButton')?.addEventListener('click', async () => {
    try {
      const result = await importTelepromptBackupToForm();
      if (result?.cancelled) return;
      showModal({ title: 'Backup do Teleprompt', message: 'Backup importado para as duas janelas do Teleprompt.', type: 'success' });
    } catch (error) {
      showModal({ title: 'Backup do Teleprompt', message: friendlyError(error, 'Não foi possível importar o backup do Teleprompt.'), type: 'error' });
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

  async function runManualUpdateCheck(button, idleText) {
    if (!button) return;
    try {
      button.disabled = true;
      button.textContent = 'Verificando...';
      const result = await window.hookUpdateCenter.checkUpdates();
      renderState(result.state || await window.hookUpdateCenter.getState());
    } catch (error) {
      console.warn('[Hook Center] Verificação manual ignorada:', error?.message || error);
      renderState(await window.hookUpdateCenter.getState());
    } finally {
      button.disabled = false;
      button.textContent = idleText;
    }
  }

  $('#checkButton')?.addEventListener('click', () => {
    runManualUpdateCheck($('#checkButton'), 'Verificar atualização');
  });

  $('#statusCheckUpdateButton')?.addEventListener('click', () => {
    runManualUpdateCheck($('#statusCheckUpdateButton'), 'Verificar atualização');
  });

  $('#downloadButton').addEventListener('click', startCombinedUpdateDownload);
  $('#statusDownloadButton')?.addEventListener('click', () => {
    const testUpdate = isTestClientUpdate(state?.testClientUpdate) ? state.testClientUpdate : null;
    if (!testUpdate) {
      showModal({ title:'Cliente teste', message:'Nenhuma atualização teste disponível para este computador.', type:'info' });
      return;
    }
    startVsHookDownload(testUpdate);
  });
  $('#installButton').addEventListener('click', installCombinedDownloadedUpdates);
  $('#statusInstallButton')?.addEventListener('click', installVsHookDownloadedUpdate);

  $('#hookCenterLearnButton')?.addEventListener('click', async () => {
    const url = state?.hookCenterLatest?.tutorialUrl || state?.hookCenterLatest?.learnUrl || state?.hookCenterLatest?.videoUrl || '';
    if (!url) return;
    try {
      await window.hookUpdateCenter.openExternal(url);
    } catch (error) {
      showModal({ title: 'VS Hook', message: friendlyError(error, 'Não foi possível abrir o conteúdo.'), type: 'error' });
    }
  });

  $('#activateButton').addEventListener('click', async () => {
    try {
      const deviceNameInput = $('#deviceNameInlineInput');
      const deviceName = String(deviceNameInput?.value || '').trim();
      if (!deviceName) {
        if (deviceNameInput) {
          deviceNameInput.classList.add('input-required-error');
          deviceNameInput.focus();
        }
        $('#licenseMessage').textContent = 'Digite o nome deste dispositivo para ativar a licença.';
        return;
      }
      deviceNameInput?.classList.remove('input-required-error');
      const savedName = await window.hookUpdateCenter.setDeviceName({ deviceName });
      if (savedName?.state) state = savedName.state;
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
  // A verificação de atualização não deve abrir popup de erro. Instabilidade de rede/backend fica silenciosa.
  window.hookUpdateCenter.onUpdateError((message) => console.warn('[Hook Center] update-error ignorado:', message));
  window.hookUpdateCenter.onDownloadProgress((progress) => {
    updateVsHookProgress(progress);
  });
}

init().catch((error) => {
  showModal({ title: 'Erro ao iniciar', message: friendlyError(error, 'Não foi possível iniciar o Hook Center.'), type: 'error' });
});


  // VS_HOOK_FIX_PIN_QUICK_LISTENERS
  [1, 2].forEach((slot) => {
    const quick = $(`#lyricsAlwaysOnTopQuick${slot}`);
    if (!quick) return;
    quick.addEventListener('change', async () => {
      const main = $(`#lyricsAlwaysOnTop${slot}`);
      if (main) main.checked = quick.checked === true;
      try {
        await saveLyricsSettingsFromForm(slot);
      } catch (error) {
        setStatus(friendlyError(error, `Não foi possível fixar a janela ${slot}.`), 'error');
      }
    });
  });

  // VS_HOOK_FIX_PIN_MAIN_LISTENERS
  [1, 2].forEach((slot) => {
    const main = $(`#lyricsAlwaysOnTop${slot}`);
    if (!main) return;
    main.addEventListener('change', () => {
      const quick = $(`#lyricsAlwaysOnTopQuick${slot}`);
      if (quick) quick.checked = main.checked === true;
    });
  });
