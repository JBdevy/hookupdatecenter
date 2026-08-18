const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

let state = null;
let currentYoutubeWatchUrl = "";
let pendingModalRequest = null;
let hookRenameFolder = null;
let hookRenameLastPreview = null;
let selectedToolsPanel = 'rename';
let hookMidiState = null;
let hookMidiBusy = false;
let hookMarkerState = null;
let hookMarkerBusy = false;
let hookMarkerRuntimeState = { active: false };
let copyProjectState = null;
let copyProjectSourceFolder = null;
let copyProjectDestinationFolder = null;
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
let chatHookState = null;
let chatHookPollTimer = 0;
let chatHookPollInFlight = false;
let chatHookSending = false;
let chatHookSelectedMedia = null;
let chatHookLastMessageId = 0;
let chatHookRevision = 0;
let chatHookClearedAt = '';
let chatHookLastPollAt = 0;
let chatAdminPassword = '';
let chatAdminPasswordResolver = null;
let releaseNotesReadResolver = null;
let releaseNotesReadScrollFrame = 0;
let hookTutorialGroups = { tutorials: [], questions: [] };
let hookTutorialCategory = 'tutorials';
let pingPongResizeObserver = null;
const chatHookMessagesById = new Map();
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

  const userFacingUpdateErrors = [
    'feche as configurações do tp',
    'feche as configuracoes do tp',
    'o aplicativo de configurações do tp',
    'o aplicativo de configuracoes do tp',
    'a cópia das configurações do tp',
    'a copia das configuracoes do tp',
    'o instalador da atualização da hook center não foi encontrado',
    'o instalador da atualizacao da hook center nao foi encontrado',
    'o instalador local da hook center não foi encontrado',
    'o instalador local da hook center nao foi encontrado',
    'não foi possível abrir o instalador da hook center',
    'nao foi possivel abrir o instalador da hook center',
    'não foi possível preparar o instalador da hook center',
    'nao foi possivel preparar o instalador da hook center',
    'chat hook',
    'mensagens permitidas hoje',
    'aguarde ',
    'somente administradores do chat',
    'escolha uma imagem',
    'a imagem deve ter no máximo',
    'a imagem deve ter no maximo',
    'vídeos não são permitidos',
    'videos nao sao permitidos',
    'digite uma mensagem ou escolha uma imagem'
  ];
  if (userFacingUpdateErrors.some((item) => lower.includes(item))) {
    return message;
  }

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

function resetModalControls() {
  const backdrop = $('#appModal');
  const okButton = $('#modalOkButton');
  const alternativeButton = $('#modalAlternativeButton');
  const cancelButton = $('#modalCancelButton');
  backdrop?.classList.remove('reinstall-source-choice');
  if (okButton) {
    okButton.textContent = 'OK';
    okButton.disabled = false;
  }
  if (alternativeButton) {
    alternativeButton.textContent = 'Reinstalar do PC';
    alternativeButton.disabled = false;
    alternativeButton.title = '';
    alternativeButton.classList.add('hidden');
  }
  if (cancelButton) {
    cancelButton.textContent = 'Cancelar';
    cancelButton.disabled = false;
    cancelButton.classList.add('hidden');
  }
}

function showModal({ title = 'Aviso', message = '', type = 'info' }) {
  const backdrop = $('#appModal');
  const icon = $('#modalIcon');
  resetModalControls();
  $('#modalTitle').textContent = title;
  $('#modalMessage').textContent = message;
  icon.className = `modal-icon ${type}`;
  icon.textContent = type === 'success' ? '✓' : (type === 'error' ? '×' : 'i');
  backdrop.classList.remove('hidden');
  $('#modalOkButton').focus();
}

function settleModal(value) {
  const request = pendingModalRequest;
  pendingModalRequest = null;
  $('#appModal').classList.add('hidden');
  resetModalControls();
  if (request) request.resolve(value);
}

function hideModal() {
  const dismissValue = pendingModalRequest
    ? pendingModalRequest.dismissValue
    : false;
  settleModal(dismissValue);
}

function confirmModal({ title = 'Confirmar', message = '', type = 'info', okText = 'Continuar', cancelText = 'Cancelar' }) {
  return new Promise((resolve) => {
    pendingModalRequest = {
      resolve,
      okValue: true,
      alternativeValue: null,
      cancelValue: false,
      dismissValue: false
    };
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
    pendingModalRequest = {
      resolve,
      okValue: true,
      alternativeValue: null,
      cancelValue: false,
      dismissValue: false
    };
    showModal({ title, message, type });
    const okButton = $('#modalOkButton');
    const cancelButton = $('#modalCancelButton');
    okButton.textContent = okText;
    if (cancelButton) cancelButton.classList.add('hidden');
  });
}

function reinstallSourceModal({ title = 'Reinstalar esta versão?', computerAvailable = false } = {}) {
  return new Promise((resolve) => {
    pendingModalRequest = {
      resolve,
      okValue: 'internet',
      alternativeValue: 'computer',
      cancelValue: null,
      dismissValue: null
    };
    showModal({
      title,
      message: computerAvailable
        ? 'Escolha se deseja baixar os arquivos novamente ou usar a cópia salva neste computador.'
        : 'Esta versão não está salva neste computador. Para reinstalar, baixe os arquivos novamente pela internet.',
      type: 'info'
    });
    const backdrop = $('#appModal');
    const okButton = $('#modalOkButton');
    const alternativeButton = $('#modalAlternativeButton');
    const cancelButton = $('#modalCancelButton');
    backdrop?.classList.add('reinstall-source-choice');
    if (okButton) okButton.textContent = 'Baixar da internet';
    if (alternativeButton) {
      alternativeButton.textContent = 'Reinstalar do PC';
      alternativeButton.disabled = !computerAvailable;
      alternativeButton.title = computerAvailable ? '' : 'Esta versão não está salva neste computador.';
      alternativeButton.classList.remove('hidden');
    }
    if (cancelButton) {
      cancelButton.textContent = 'Cancelar';
      cancelButton.classList.remove('hidden');
    }
    okButton?.focus();
  });
}

function stopReleaseNotesScrollHint() {
  if (releaseNotesReadScrollFrame) {
    cancelAnimationFrame(releaseNotesReadScrollFrame);
    releaseNotesReadScrollFrame = 0;
  }
}

function closeReleaseNotesReadModal(accepted = false) {
  stopReleaseNotesScrollHint();
  const modal = $('#releaseNotesReadModal');
  const content = $('#releaseNotesReadContent');
  modal?.classList.add('hidden');
  if (content) content.scrollTop = 0;
  const resolve = releaseNotesReadResolver;
  releaseNotesReadResolver = null;
  if (resolve) resolve(Boolean(accepted));
}

function startReleaseNotesScrollHint() {
  const content = $('#releaseNotesReadContent');
  if (!content) return;
  stopReleaseNotesScrollHint();
  content.scrollTop = 0;
  const maxScroll = content.scrollHeight - content.clientHeight;
  if (maxScroll <= 4) return;

  const peak = Math.min(maxScroll, Math.max(56, content.clientHeight * 0.16));
  const duration = 1000;
  const startedAt = performance.now();
  const step = (now) => {
    const progress = Math.min(1, (now - startedAt) / duration);
    content.scrollTop = peak * Math.sin(Math.PI * progress);
    if (progress < 1) {
      releaseNotesReadScrollFrame = requestAnimationFrame(step);
    } else {
      releaseNotesReadScrollFrame = 0;
      content.scrollTop = 0;
    }
  };
  releaseNotesReadScrollFrame = requestAnimationFrame(step);
}

function showReleaseNotesReadModal(message) {
  if (releaseNotesReadResolver) closeReleaseNotesReadModal(false);
  const modal = $('#releaseNotesReadModal');
  const content = $('#releaseNotesReadContent');
  if (!modal || !content) return Promise.resolve(false);

  content.textContent = String(message || 'Nenhuma Release Note foi publicada para esta versão.');
  content.scrollTop = 0;
  modal.classList.remove('hidden');

  return new Promise((resolve) => {
    releaseNotesReadResolver = resolve;
    requestAnimationFrame(() => {
      requestAnimationFrame(startReleaseNotesScrollHint);
    });
    $('#releaseNotesReadContinue')?.focus();
  });
}

async function showDownloadDescriptionNotice(updateOverride = null) {
  const releaseNotes = String(
    updateOverride?.releaseNotes ||
    state?.latestUpdate?.releaseNotes ||
    state?.hookCenterLatest?.releaseNotes ||
    updateOverride?.description ||
    state?.latestUpdate?.description ||
    state?.hookCenterLatest?.notes ||
    'Nenhuma Release Note foi publicada para esta versão.'
  ).trim();
  return showReleaseNotesReadModal(releaseNotes);
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

async function openUpdateVideoExternally() {
  if (!currentYoutubeWatchUrl) {
    showModal({
      title: 'Vídeo indisponível',
      message: 'Nenhum vídeo foi publicado para esta atualização.',
      type: 'error'
    });
    return;
  }

  try {
    await window.hookUpdateCenter.openExternal(currentYoutubeWatchUrl);
  } catch (error) {
    showModal({
      title: 'Vídeo da atualização',
      message: friendlyError(error, 'Não foi possível abrir o vídeo no navegador.'),
      type: 'error'
    });
  }
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
  if (safeProgress >= 100 && !combinedDownloadInProgress) {
    $('#installButton')?.classList.remove('hidden');
    $('#statusInstallButton')?.classList.remove('hidden');
  }
}

async function startVsHookDownload(updateOverride = null) {
  try {
    if (!(await ensureLicenseActiveForDownload())) return;
    if (!(await showDownloadDescriptionNotice(updateOverride))) return;
    if (!(await ensureDeviceName())) return;
    setProgressVisible(true);
    resetVsHookProgress();
    const buttons = [$('#downloadButton'), $('#statusDownloadButton')].filter(Boolean);
    buttons.forEach((button) => {
      button.disabled = true;
      button.dataset.originalText = button.textContent;
      button.textContent = 'Baixando...';
    });
    const directedInstaller = getInstallerUrlForUpdate(updateOverride);
    if (updateOverride && isTestClientUpdate(updateOverride)) {
      if (!directedInstaller) {
        throw new Error(
          'A atualização de cliente teste está sem o link próprio da Hook Center.'
        );
      }
      // A atualização direcionada pode trazer o pacote completo. Nesse caso,
      // guarda extensão + instalador juntos para o botão Instalar executar o
      // mesmo fluxo seguro da atualização oficial.
      await window.hookUpdateCenter.cacheUpdatePackage({ update: updateOverride });
      // Conserva exatamente a publicação direcionada que acabou de ser
      // guardada. A referência durável fica no processo principal/Store; o
      // botão Instalar não depende mais do estado online desta tela.
    } else {
      await window.hookUpdateCenter.downloadUpdate(updateOverride ? { update: updateOverride } : undefined);
    }
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
  if (!(await showDownloadDescriptionNotice())) return;

  const button = $('#downloadButton');
  if (state?.currentPackageInstalled === true) {
    const source = await reinstallSourceModal({
      title: 'Reinstalar esta versão?',
      computerAvailable: state?.currentPackageCached === true
    });
    if (!source) return;
    const downloadingFromInternet = source === 'internet';
    try {
      if (button) {
        button.disabled = true;
        if (downloadingFromInternet) {
          combinedDownloadInProgress = true;
          setProgressVisible(true);
          resetVsHookProgress();
          button.textContent = 'Baixando...';
        } else {
          button.textContent = 'Preparando...';
        }
      }
      const result = await window.hookUpdateCenter.installCachedUpdatePackage({ source });
      if (state?.platform === 'darwin') {
        renderState(await window.hookUpdateCenter.getState());
        const centerFirst = result?.action === 'center-first-dmg-opened';
        showModal({
          title: centerFirst ? 'Instale a nova Hook Center' : 'Reinstalação pronta',
          message: centerFirst
            ? 'A nova Hook Center foi aberta primeiro. Depois de instalá-la, abra a central nova para ela concluir automaticamente a extensão, o Teleprompt Settings e os temas.'
            : 'A extensão foi reinstalada e o instalador da Hook Center foi aberto.',
          type: 'success'
        });
      }
    } catch (error) {
      showModal({ title: 'Erro ao reinstalar', message: friendlyError(error, 'Não foi possível reinstalar esta versão.'), type: 'error' });
      if (button) {
        button.disabled = false;
        button.textContent = 'Reinstalar';
      }
    } finally {
      if (downloadingFromInternet) {
        combinedDownloadInProgress = false;
        if (button) {
          button.disabled = false;
          button.classList.remove('download-progress-active');
          button.style.removeProperty('--download-progress');
          button.textContent = 'Reinstalar';
        }
      }
    }
    return;
  }

  combinedDownloadInProgress = true;
  combinedDownloadReady = { package: false, vsHook: false, hookCenter: false };
  setProgressVisible(true);
  resetVsHookProgress();
  if (button) {
    button.disabled = true;
    button.textContent = 'Baixando...';
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
    message: 'Feche o REAPER antes de continuar. Se houver uma central nova, ela será instalada primeiro e concluirá automaticamente a extensão, o Teleprompt Settings e os temas quando abrir.',
    type: 'info',
    okText: 'Instalar',
    cancelText: 'Cancelar'
  });
  if (!confirmed) return;

  try {
    const result = await window.hookUpdateCenter.installCachedUpdatePackage();
    if (state?.platform === 'darwin') {
      renderState(await window.hookUpdateCenter.getState());
      setProgressVisible(false);
      resetVsHookProgress();
      const centerFirst = result?.action === 'center-first-dmg-opened';
      showModal({
        title: centerFirst ? 'Instale a nova Hook Center' : 'Atualizações prontas',
        message: centerFirst
          ? 'Instale a central nova e abra-a. Ela concluirá automaticamente a extensão, o Teleprompt Settings e os temas.'
          : 'A extensão foi instalada e o instalador da Hook Center foi aberto.',
        type: 'success'
      });
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
    // O processo principal instala o registro exato salvo no download. Isso
    // continua correto mesmo que a atualização de teste suma ou seja trocada
    // no backend enquanto este modal está aberto.
    const result = await window.hookUpdateCenter.installUpdate();
    if (result.ok && !String(result.action || '').startsWith('center-first-')) {
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
  if (!paths.length) return 'Escolha uma ou mais pastas para começar.';
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
    list.innerHTML = '<p class="muted">Escolha uma ou mais pastas e clique em gerar prévia.</p>';
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
  $('#hookRenameFolderPath').textContent = 'Escolha uma ou mais pastas para começar.';
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

let directCableState = null;

const directCableUiChannels = {
  projectSync: {
    label: 'Project Sync',
    select: '#directCableProjectSyncAdapterSelect',
    details: '#directCableProjectSyncDetails',
    badge: '#directCableProjectSyncBadge',
    configure: '#directCableProjectSyncConfigureButton',
    restore: '#directCableProjectSyncRestoreButton',
    result: '#directCableProjectSyncResult'
  },
  timecode: {
    label: 'Time Code',
    select: '#directCableTimecodeAdapterSelect',
    details: '#directCableTimecodeDetails',
    badge: '#directCableTimecodeBadge',
    configure: '#directCableTimecodeConfigureButton',
    restore: '#directCableTimecodeRestoreButton',
    result: '#directCableTimecodeResult'
  }
};

function renderDirectCableChannel(channel, state = directCableState) {
  const ui = directCableUiChannels[channel];
  const select = $(ui.select);
  const details = $(ui.details);
  const badge = $(ui.badge);
  if (!select) return;
  const previous = select.value;
  const adapters = Array.isArray(state?.adapters) ? state.adapters : [];
  const configured = state?.channels?.[channel] || {};
  select.innerHTML = adapters.length
    ? adapters.map((adapter) => `<option value="${escapeHtml(adapter.id)}">${escapeHtml(adapter.name)}${adapter.description && adapter.description !== adapter.name ? ` — ${escapeHtml(adapter.description)}` : ''}</option>`).join('')
    : '<option value="">Nenhum adaptador Ethernet encontrado</option>';
  const wanted = adapters.some((item) => item.id === previous)
    ? previous
    : (adapters.some((item) => item.id === configured.adapterId)
        ? configured.adapterId : (adapters[0]?.id || ''));
  select.value = wanted;
  const adapter = adapters.find((item) => item.id === wanted);
  if (adapter) {
    const linkText = adapter.connected ? 'Cabo conectado' : 'Sem sinal do cabo';
    const isFixed = configured.adapterId === adapter.id && !!configured.ip;
    badge.textContent = isFixed
      ? (adapter.connected ? 'Conectada' : 'Configurada — sem cabo')
      : (adapter.connected ? 'Disponível' : 'Aguardando cabo');
    badge.classList.toggle('direct-cable-badge-online', isFixed && adapter.connected);
    details.textContent = `${linkText}${adapter.linkSpeed ? ` • ${adapter.linkSpeed}` : ''}${adapter.ipv4 ? ` • IP atual ${adapter.ipv4}` : ' • Sem IPv4 configurado'}`;
  } else {
    badge.textContent = state?.supported === false ? 'Indisponível' : 'Não detectado';
    badge.classList.remove('direct-cable-badge-online');
    details.textContent = state?.error || 'Conecte um adaptador USB–Ethernet e clique em detectar novamente.';
  }
  $(ui.configure).disabled = !adapter;
  $(ui.restore).disabled = !configured.adapterId;
  const result = $(ui.result);
  if (result) {
    result.textContent = configured.ip
      ? `${ui.label} conectado em ${configured.ip}. Esta placa será usada automaticamente.`
      : `Escolha a placa dedicada ao ${ui.label} e clique em Conectar.`;
  }
}

function renderDirectCableState(state = directCableState) {
  renderDirectCableChannel('projectSync', state);
  renderDirectCableChannel('timecode', state);
}

async function refreshDirectCableState() {
  for (const ui of Object.values(directCableUiChannels)) {
    if ($(ui.result)) $(ui.result).textContent = 'Detectando adaptadores Ethernet...';
  }
  try {
    directCableState = await window.hookUpdateCenter.getDirectCableState();
    renderDirectCableState(directCableState);
  } catch (error) {
    directCableState = { ok: false, adapters: [], error: friendlyError(error) };
    renderDirectCableState(directCableState);
  }
}

async function configureDirectCableFromUi(channel) {
  const ui = directCableUiChannels[channel];
  const adapterId = $(ui.select)?.value || '';
  if (!adapterId) {
    showModal({ title: ui.label, message: `Escolha a placa dedicada ao ${ui.label}.`, type: 'error' });
    return;
  }
  const confirmed = await confirmModal({
    title: `Conectar Placa ${ui.label}?`,
    message: `A Hook Center configurará esta placa para conectar o ${ui.label}. O sistema poderá pedir a senha de administrador. O Wi‑Fi e os demais adaptadores não serão alterados.`,
    type: 'info',
    okText: 'Conectar'
  });
  if (!confirmed) return;
  const button = $(ui.configure);
  const resultBox = $(ui.result);
  button.disabled = true;
  if (resultBox) resultBox.textContent = 'Aguardando autorização do sistema...';
  try {
    const result = await window.hookUpdateCenter.configureDirectCable({ channel, adapterId });
    directCableState = result.state;
    renderDirectCableState(directCableState);
    if (resultBox) resultBox.textContent = `${ui.label} conectado em ${result.ip}.`;
    const peer = channel === 'projectSync' ? 'PC B' : 'PC C';
    showModal({ title: `Placa ${ui.label} conectada`, message: `A placa do ${ui.label} foi conectada usando ${result.ip}. Faça a mesma conexão na placa correspondente do ${peer}.`, type: 'success' });
  } catch (error) {
    if (resultBox) resultBox.textContent = friendlyError(error, `Não foi possível conectar a placa ${ui.label}.`);
    showModal({ title: `Placa ${ui.label}`, message: friendlyError(error, `Não foi possível conectar a placa ${ui.label}.`), type: 'error' });
  } finally {
    button.disabled = false;
  }
}

async function restoreDirectCableFromUi(channel) {
  const ui = directCableUiChannels[channel];
  const configured = directCableState?.channels?.[channel] || {};
  const adapterId = configured.adapterId || $(ui.select)?.value || '';
  if (!adapterId) return;
  const confirmed = await confirmModal({
    title: 'Restaurar DHCP?',
    message: `A placa conectada ao ${ui.label} voltará a obter o endereço IP automaticamente.`,
    type: 'info',
    okText: 'Restaurar'
  });
  if (!confirmed) return;
  const button = $(ui.restore);
  const resultBox = $(ui.result);
  button.disabled = true;
  try {
    const result = await window.hookUpdateCenter.restoreDirectCableDhcp({ channel, adapterId });
    directCableState = result.state;
    renderDirectCableState(directCableState);
    if (resultBox) {
      resultBox.textContent = result.sharedAdapterRetained
        ? `${ui.label} foi desconectado. A placa continua conectada ao outro canal.`
        : 'DHCP restaurado. O adaptador voltou para configuração automática.';
    }
  } catch (error) {
    showModal({ title: `Placa ${ui.label}`, message: friendlyError(error, 'Não foi possível restaurar o DHCP.'), type: 'error' });
  } finally {
    button.disabled = false;
  }
}

const pingPongGame = {
  running: false,
  frame: 0,
  lastFrameAt: 0,
  width: 960,
  height: 540,
  paddleWidth: 18,
  paddleHeight: 112,
  leftY: 214,
  rightY: 214,
  ballX: 480,
  ballY: 270,
  ballRadius: 11,
  ballVx: 390,
  ballVy: 130,
  leftScore: 0,
  rightScore: 0,
  speedMultiplier: 1,
  serveResumeAt: 0,
  keys: new Set()
};

function updatePingPongHeader() {
  const toggle = $('#pingPongToggleButton');
  const overlay = $('#pingPongStartOverlay');
  const score = $('#pingPongScore');
  const status = $('#pingPongStatus');
  if (toggle) {
    toggle.textContent = pingPongGame.running ? 'Encerrar' : 'Iniciar';
    toggle.classList.toggle('pingpong-stop-button', pingPongGame.running);
  }
  overlay?.classList.toggle('hidden', pingPongGame.running);
  if (score) score.innerHTML = `${pingPongGame.leftScore}&nbsp;&nbsp;×&nbsp;&nbsp;${pingPongGame.rightScore}`;
  if (status) status.textContent = pingPongGame.running
    ? `Partida em andamento • ${pingPongGame.speedMultiplier}x`
    : `Pronto para jogar • ${pingPongGame.speedMultiplier}x`;
}

function resetPingPongBall(direction = (Math.random() < 0.5 ? -1 : 1)) {
  pingPongGame.ballX = pingPongGame.width / 2;
  pingPongGame.ballY = pingPongGame.height / 2;
  pingPongGame.ballVx = 390 * direction;
  pingPongGame.ballVy = (100 + Math.random() * 150) * (Math.random() < 0.5 ? -1 : 1);
}

function drawPingPongGame() {
  const canvas = $('#pingPongCanvas');
  const ctx = canvas?.getContext('2d');
  if (!ctx) return;
  const { width, height, paddleWidth, paddleHeight, leftY, rightY, ballX, ballY, ballRadius } = pingPongGame;

  const background = ctx.createLinearGradient(0, 0, width, height);
  background.addColorStop(0, '#080910');
  background.addColorStop(0.5, '#151023');
  background.addColorStop(1, '#080910');
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, width, height);

  ctx.strokeStyle = 'rgba(255, 255, 255, .18)';
  ctx.lineWidth = 4;
  ctx.setLineDash([14, 18]);
  ctx.beginPath();
  ctx.moveTo(width / 2, 22);
  ctx.lineTo(width / 2, height - 22);
  ctx.stroke();
  ctx.setLineDash([]);

  ctx.shadowBlur = 22;
  ctx.shadowColor = '#9eff00';
  ctx.fillStyle = '#9eff00';
  ctx.fillRect(34, leftY, paddleWidth, paddleHeight);
  ctx.shadowColor = '#bb39ff';
  ctx.fillStyle = '#bb39ff';
  ctx.fillRect(width - 34 - paddleWidth, rightY, paddleWidth, paddleHeight);

  ctx.shadowColor = '#ffffff';
  ctx.shadowBlur = 18;
  ctx.fillStyle = '#ffffff';
  ctx.beginPath();
  ctx.arc(ballX, ballY, ballRadius, 0, Math.PI * 2);
  ctx.fill();
  ctx.shadowBlur = 0;
}

function updatePingPongGame(deltaSeconds) {
  const game = pingPongGame;
  const paddleSpeed = 470;
  if (game.keys.has('KeyW')) game.leftY -= paddleSpeed * deltaSeconds;
  if (game.keys.has('KeyS')) game.leftY += paddleSpeed * deltaSeconds;
  if (game.keys.has('ArrowUp')) game.rightY -= paddleSpeed * deltaSeconds;
  if (game.keys.has('ArrowDown')) game.rightY += paddleSpeed * deltaSeconds;
  game.leftY = Math.max(0, Math.min(game.height - game.paddleHeight, game.leftY));
  game.rightY = Math.max(0, Math.min(game.height - game.paddleHeight, game.rightY));

  // Depois de cada ponto, a bola permanece visível e parada no centro por
  // meio segundo. A pausa usa tempo real e não é encurtada pelo modo 2x–5x.
  if (game.serveResumeAt > performance.now()) return;
  game.serveResumeAt = 0;

  game.ballX += game.ballVx * deltaSeconds;
  game.ballY += game.ballVy * deltaSeconds;
  if (game.ballY - game.ballRadius <= 0 && game.ballVy < 0) game.ballVy *= -1;
  if (game.ballY + game.ballRadius >= game.height && game.ballVy > 0) game.ballVy *= -1;

  const leftPaddleX = 34 + game.paddleWidth;
  const rightPaddleX = game.width - 34 - game.paddleWidth;
  const bounceFromPaddle = (paddleY, direction) => {
    const relative = (game.ballY - (paddleY + game.paddleHeight / 2)) / (game.paddleHeight / 2);
    const speed = Math.min(720, Math.hypot(game.ballVx, game.ballVy) * 1.045);
    game.ballVx = Math.cos(relative * 0.78) * speed * direction;
    game.ballVy = Math.sin(relative * 0.78) * speed;
  };

  if (game.ballVx < 0 && game.ballX - game.ballRadius <= leftPaddleX && game.ballX > 25 && game.ballY >= game.leftY && game.ballY <= game.leftY + game.paddleHeight) {
    game.ballX = leftPaddleX + game.ballRadius;
    bounceFromPaddle(game.leftY, 1);
  }
  if (game.ballVx > 0 && game.ballX + game.ballRadius >= rightPaddleX && game.ballX < game.width - 25 && game.ballY >= game.rightY && game.ballY <= game.rightY + game.paddleHeight) {
    game.ballX = rightPaddleX - game.ballRadius;
    bounceFromPaddle(game.rightY, -1);
  }

  if (game.ballX < -game.ballRadius) {
    game.rightScore += 1;
    resetPingPongBall(1);
    game.serveResumeAt = performance.now() + 500;
    updatePingPongHeader();
  } else if (game.ballX > game.width + game.ballRadius) {
    game.leftScore += 1;
    resetPingPongBall(-1);
    game.serveResumeAt = performance.now() + 500;
    updatePingPongHeader();
  }
}

function runPingPongFrame(now) {
  if (!pingPongGame.running) return;
  const delta = Math.min(0.032, Math.max(0, (now - pingPongGame.lastFrameAt) / 1000));
  pingPongGame.lastFrameAt = now;
  const acceleratedDelta = delta * pingPongGame.speedMultiplier;
  const steps = Math.max(1, Math.ceil(acceleratedDelta / 0.008));
  const stepDelta = acceleratedDelta / steps;
  for (let step = 0; step < steps; step += 1) updatePingPongGame(stepDelta);
  drawPingPongGame();
  pingPongGame.frame = requestAnimationFrame(runPingPongFrame);
}

function startPingPongGame() {
  if (pingPongGame.running) return;
  pingPongGame.running = true;
  pingPongGame.leftScore = 0;
  pingPongGame.rightScore = 0;
  pingPongGame.leftY = (pingPongGame.height - pingPongGame.paddleHeight) / 2;
  pingPongGame.rightY = pingPongGame.leftY;
  pingPongGame.keys.clear();
  pingPongGame.serveResumeAt = 0;
  resetPingPongBall();
  pingPongGame.lastFrameAt = performance.now();
  updatePingPongHeader();
  $('#pingPongCanvas')?.focus();
  pingPongGame.frame = requestAnimationFrame(runPingPongFrame);
}

function stopPingPongGame() {
  pingPongGame.running = false;
  pingPongGame.keys.clear();
  pingPongGame.serveResumeAt = 0;
  if (pingPongGame.frame) cancelAnimationFrame(pingPongGame.frame);
  pingPongGame.frame = 0;
  updatePingPongHeader();
  drawPingPongGame();
}

function togglePingPongGame() {
  if (pingPongGame.running) stopPingPongGame();
  else startPingPongGame();
}

function resizePingPongCanvas() {
  const canvas = $('#pingPongCanvas');
  const shell = canvas?.parentElement;
  if (!canvas || !shell) return;
  const availableWidth = shell.clientWidth;
  const availableHeight = shell.clientHeight;
  if (availableWidth <= 0 || availableHeight <= 0) return;
  const scale = Math.min(availableWidth / pingPongGame.width, availableHeight / pingPongGame.height);
  canvas.style.width = `${Math.max(1, Math.floor(pingPongGame.width * scale))}px`;
  canvas.style.height = `${Math.max(1, Math.floor(pingPongGame.height * scale))}px`;
}

function setupPingPongGame() {
  const canvas = $('#pingPongCanvas');
  $('#pingPongToggleButton')?.addEventListener('click', togglePingPongGame);
  $('#pingPongStartButton')?.addEventListener('click', startPingPongGame);
  $('#pingPongSpeedSelect')?.addEventListener('change', (event) => {
    pingPongGame.speedMultiplier = Math.max(1, Math.min(5,
      Math.round(Number(event.currentTarget.value) || 1)));
    event.currentTarget.value = String(pingPongGame.speedMultiplier);
    updatePingPongHeader();
  });
  document.addEventListener('keydown', (event) => {
    if (!pingPongGame.running || selectedToolsPanel !== 'pingpong') return;
    if (!['KeyW', 'KeyS', 'ArrowUp', 'ArrowDown'].includes(event.code)) return;
    event.preventDefault();
    pingPongGame.keys.add(event.code);
  });
  document.addEventListener('keyup', (event) => pingPongGame.keys.delete(event.code));
  window.addEventListener('blur', () => pingPongGame.keys.clear());
  canvas?.addEventListener('pointermove', (event) => {
    if (!pingPongGame.running || !event.buttons) return;
    const rect = canvas.getBoundingClientRect();
    const x = (event.clientX - rect.left) * (pingPongGame.width / rect.width);
    const y = (event.clientY - rect.top) * (pingPongGame.height / rect.height) - pingPongGame.paddleHeight / 2;
    if (x < pingPongGame.width / 2) pingPongGame.leftY = Math.max(0, Math.min(pingPongGame.height - pingPongGame.paddleHeight, y));
    else pingPongGame.rightY = Math.max(0, Math.min(pingPongGame.height - pingPongGame.paddleHeight, y));
  });
  const stage = canvas?.parentElement;
  if (stage && typeof ResizeObserver === 'function') {
    pingPongResizeObserver = new ResizeObserver(resizePingPongCanvas);
    pingPongResizeObserver.observe(stage);
  }
  updatePingPongHeader();
  drawPingPongGame();
}

function updateHookMidiNamePreview() {
  const input = $('#hookMidiPortName');
  const rootName = String(input?.value || 'Hook MIDI').replace(/\s+/g, ' ').trim().slice(0, 27) || 'Hook MIDI';
  if ($('#hookMidiNamePreviewA')) $('#hookMidiNamePreviewA').textContent = `${rootName} (A)`;
  if ($('#hookMidiNamePreviewB')) $('#hookMidiNamePreviewB').textContent = `${rootName} (B)`;
}

function renderHookMidiAvailability(nextState = hookMidiState) {
  const data = nextState || {};
  hookMidiState = data;
  const badge = $('#hookMidiAvailabilityBadge');
  const runtimeBadge = $('#hookMidiRuntimeBadge');
  const message = $('#hookMidiSystemMessage');
  const startButton = $('#hookMidiStartButton');
  const refreshButton = $('#hookMidiRefreshButton');
  const installButton = $('#hookMidiInstallButton');
  const nameInput = $('#hookMidiPortName');
  const nameField = document.querySelector('.hook-midi-name-field');
  const windows10Card = $('#hookMidiWindows10Card');
  const macCard = $('#hookMidiMacCard');
  const portsCard = $('#hookMidiPortsCard');
  const portsList = $('#hookMidiPortsList');
  const countBadge = $('#hookMidiPortCountBadge');
  const ports = Array.isArray(data.ports) ? data.ports : [];
  const busy = hookMidiBusy || data.busy === true;
  const macos = data.macos === true || data.platform === 'darwin';
  const heroDescription = $('#hookMidiHeroDescription');
  const platformLabel = $('#hookMidiPlatformLabel');
  const providerTitle = $('#hookMidiProviderTitle');
  windows10Card?.classList.toggle('hidden', data.windows10 !== true);
  macCard?.classList.toggle('hidden', !macos);
  portsCard?.classList.toggle('hidden', data.supported !== true || macos);
  nameField?.classList.toggle('hidden', macos);
  installButton?.classList.toggle('hidden', !(data.supported && !data.consoleInstalled));
  if (macos) {
    if (heroDescription) heroDescription.textContent = 'Use o CoreMIDI e o Driver IAC nativos do macOS para comunicar o VS Hook, o REAPER e outros programas.';
    if (platformLabel) platformLabel.textContent = 'macOS';
    if (providerTitle) providerTitle.textContent = 'CoreMIDI — Driver IAC';
    if (badge) badge.textContent = 'Nativo do macOS';
    if (runtimeBadge) runtimeBadge.textContent = 'Sem instalação';
    if (message) message.textContent = 'Abra o Estúdio MIDI (Command+2), ative o Driver IAC e crie um barramento chamado Hook MIDI.';
    if (startButton) startButton.textContent = 'Abrir Estúdio MIDI';
  } else if (data.supported && data.consoleInstalled) {
    if (heroDescription) heroDescription.textContent = 'Crie portas MIDI virtuais para comunicar o VS Hook, o REAPER e outros programas no Windows 11.';
    if (platformLabel) platformLabel.textContent = 'Windows 11';
    if (providerTitle) providerTitle.textContent = 'Windows MIDI Services';
    if (badge) badge.textContent = 'Windows 11 compatível';
    if (runtimeBadge) runtimeBadge.textContent = data.serviceRunning ? 'Serviço ativo' : 'Pronto para iniciar';
    if (message) message.textContent = data.serviceRunning
      ? 'Windows MIDI Services ativo. Crie um par virtual para conectar dois programas neste computador.'
      : 'Componentes oficiais instalados. O serviço MIDI será iniciado pelo Windows ao criar as portas.';
    if (startButton) startButton.textContent = busy ? 'Criando...' : 'Criar portas';
  } else if (data.supported) {
    if (platformLabel) platformLabel.textContent = 'Windows 11';
    if (providerTitle) providerTitle.textContent = 'Windows MIDI Services';
    if (badge) badge.textContent = 'Windows 11';
    if (runtimeBadge) runtimeBadge.textContent = 'Componentes ausentes';
    if (message) message.textContent = 'Instale o Windows MIDI Services Runtime & Tools oficial para a Hook Center criar e remover as portas virtuais.';
    if (startButton) startButton.textContent = 'Instalação necessária';
  } else if (data.windows10) {
    if (platformLabel) platformLabel.textContent = 'Windows 10';
    if (providerTitle) providerTitle.textContent = 'Portas MIDI virtuais';
    if (badge) badge.textContent = 'Windows 10';
    if (runtimeBadge) runtimeBadge.textContent = 'Não compatível';
    if (message) message.textContent = 'O Hook MIDI requer o Windows 11. Para criar portas MIDI virtuais neste computador, recomendamos o loopMIDI.';
    if (startButton) startButton.textContent = 'Requer Windows 11';
  } else {
    if (badge) badge.textContent = 'Somente Windows 11';
    if (runtimeBadge) runtimeBadge.textContent = 'Indisponível';
    if (message) message.textContent = 'O Hook MIDI está disponível exclusivamente para computadores com Windows 11.';
    if (startButton) startButton.textContent = 'Indisponível neste sistema';
  }
  if (startButton) startButton.disabled = busy || !data.supported || (!macos && !data.consoleInstalled);
  if (refreshButton) refreshButton.disabled = busy;
  if (installButton) installButton.disabled = busy;
  if (nameInput) nameInput.disabled = macos || busy || !data.supported || !data.consoleInstalled;
  if (countBadge) countBadge.textContent = `${ports.length} ${ports.length === 1 ? 'par' : 'pares'}`;
  if (portsList) {
    portsList.innerHTML = ports.length
      ? ports.map((port) => `
        <div class="hook-midi-port-item">
          <div class="hook-midi-port-names">
            <strong>${escapeHtml(port.endpointA || `${port.rootName} (A)`)}</strong>
            <span>↔ ${escapeHtml(port.endpointB || `${port.rootName} (B)`)}</span>
          </div>
          <button class="secondary-button hook-midi-remove-button" type="button" data-hook-midi-remove="${escapeHtml(port.associationId)}" ${busy ? 'disabled' : ''}>Remover</button>
        </div>`).join('')
      : '<p class="muted">Nenhuma porta criada pela Hook Center nesta sessão do Windows.</p>';
  }
  updateHookMidiNamePreview();
}

function hookMidiErrorMessage(error, fallback) {
  const raw = String(error?.message || error || '').replace(/^Error invoking remote method '[^']+':\s*/i, '').replace(/^Error:\s*/i, '').trim();
  return raw || fallback;
}

async function refreshHookMidiState() {
  if (hookMidiBusy) return;
  if (!hookMidiState) renderHookMidiAvailability({
    platform: window.hookUpdateCenter?.platform,
    supported: window.hookUpdateCenter?.platform === 'win32' && Number.parseInt(String(window.hookUpdateCenter?.osRelease || '').split('.')[2] || '0', 10) >= 22000,
    windows10: window.hookUpdateCenter?.platform === 'win32' && Number.parseInt(String(window.hookUpdateCenter?.osRelease || '').split('.')[2] || '0', 10) < 22000,
    ports: []
  });
  try {
    renderHookMidiAvailability(await window.hookUpdateCenter.getHookMidiState());
  } catch (error) {
    showModal({ title: 'Hook MIDI', message: hookMidiErrorMessage(error, 'Não foi possível verificar o Windows MIDI Services.'), type: 'error' });
  }
}

async function createHookMidiPortFromUi() {
  if (hookMidiBusy) return;
  if (hookMidiState?.macos === true || window.hookUpdateCenter?.platform === 'darwin') {
    hookMidiBusy = true;
    renderHookMidiAvailability();
    try {
      await window.hookUpdateCenter.openHookMidiComponents();
    } catch (error) {
      showModal({ title: 'Hook MIDI', message: hookMidiErrorMessage(error, 'Não foi possível abrir a Configuração de Áudio e MIDI.'), type: 'error' });
    } finally {
      hookMidiBusy = false;
      renderHookMidiAvailability();
    }
    return;
  }
  hookMidiBusy = true;
  renderHookMidiAvailability();
  try {
    const result = await window.hookUpdateCenter.createHookMidiPort({ rootName: $('#hookMidiPortName')?.value || 'Hook MIDI' });
    hookMidiState = result?.state || await window.hookUpdateCenter.getHookMidiState();
    showModal({
      title: 'Portas Hook MIDI criadas',
      message: `${result.created.endpointA} e ${result.created.endpointB} já estão disponíveis nos programas MIDI. Envie por uma ponta e receba pela outra.`,
      type: 'success'
    });
  } catch (error) {
    showModal({ title: 'Não foi possível criar', message: hookMidiErrorMessage(error, 'O Windows MIDI Services não conseguiu criar as portas.'), type: 'error' });
  } finally {
    hookMidiBusy = false;
    renderHookMidiAvailability();
  }
}

async function removeHookMidiPortFromUi(associationId) {
  const port = (hookMidiState?.ports || []).find((item) => item.associationId === associationId);
  if (!port || hookMidiBusy) return;
  const confirmed = await confirmModal({
    title: 'Remover portas Hook MIDI?',
    message: `As portas ${port.endpointA} e ${port.endpointB} serão desconectadas dos programas que estiverem usando elas.`,
    type: 'info',
    okText: 'Remover',
    cancelText: 'Cancelar'
  });
  if (!confirmed) return;
  hookMidiBusy = true;
  renderHookMidiAvailability();
  try {
    const result = await window.hookUpdateCenter.removeHookMidiPort({ associationId });
    hookMidiState = result?.state || await window.hookUpdateCenter.getHookMidiState();
  } catch (error) {
    showModal({ title: 'Não foi possível remover', message: hookMidiErrorMessage(error, 'O Windows MIDI Services não conseguiu remover as portas.'), type: 'error' });
  } finally {
    hookMidiBusy = false;
    renderHookMidiAvailability();
  }
}

async function installHookMidiComponentsFromUi() {
  if (hookMidiBusy) return;
  hookMidiBusy = true;
  renderHookMidiAvailability();
  const button = $('#hookMidiInstallButton');
  if (button) button.textContent = 'Abrindo instalador...';
  try {
    const result = await window.hookUpdateCenter.openHookMidiComponents();
    if (result?.alreadyInstalled) {
      hookMidiState = await window.hookUpdateCenter.getHookMidiState();
      return;
    }
    showModal({
      title: result?.external ? 'Windows MIDI Services' : 'Instalador iniciado',
      message: result?.external
        ? 'A página oficial da Microsoft foi aberta. Instale o Windows MIDI Services Runtime & Tools e depois clique em Atualizar.'
        : 'Conclua a instalação oficial da Microsoft. Depois volte à Hook Center e clique em Atualizar para liberar a criação das portas.',
      type: 'info'
    });
  } catch (error) {
    showModal({ title: 'Não foi possível instalar', message: hookMidiErrorMessage(error, 'Não foi possível abrir o instalador do Windows MIDI Services.'), type: 'error' });
  } finally {
    hookMidiBusy = false;
    if (button) button.textContent = 'Instalar componentes oficiais';
    renderHookMidiAvailability();
  }
}

function copyProjectIsBusy(data = copyProjectState) {
  return ['discovering', 'preparing', 'checking', 'sending', 'receiving', 'paused'].includes(
    String(data?.phase || ''));
}

function renderCopyProjectState(nextState = copyProjectState) {
  if (nextState) copyProjectState = nextState;
  const data = copyProjectState || { phase: 'idle' };
  const busy = copyProjectIsBusy(data);
  const waiting = data.phase === 'waiting' && data.receiving === true;
  const receiverActive = data.receiving === true;
  const sourceButton = $('#copyProjectSelectSourceButton');
  const sourceFileButton = $('#copyProjectSelectFileButton');
  const destinationButton = $('#copyProjectSelectDestinationButton');
  const sendButton = $('#copyProjectSendButton');
  const receiveButton = $('#copyProjectReceiveButton');
  const cancelButton = $('#copyProjectCancelButton');
  const openButton = $('#copyProjectOpenDestinationButton');
  const shareButton = $('#copyProjectShareButton');
  const codeInput = $('#copyProjectReceiverCode');
  const statusBadge = $('#copyProjectStatusBadge');
  const progressBar = $('#copyProjectProgressBar');
  const total = Math.max(0, Number(data.totalBytes) || 0);
  const done = Math.max(0, Math.min(total, Number(data.bytesDone) || 0));
  const percent = total > 0 ? Math.min(100, Math.round((done * 100) / total))
    : data.phase === 'completed' ? 100 : 0;
  const phaseLabels = {
    idle: 'Parado', waiting: 'Aguardando emissor', sharing: 'Disponível na rede', discovering: 'Procurando receptor',
    preparing: 'Preparando arquivos', checking: 'Preparando destino',
    sending: 'Enviando', receiving: 'Recebendo', paused: 'Pausado',
    completed: 'Concluído', error: 'Erro'
  };
  const titleLabels = {
    idle: 'Aguardando', waiting: 'Pronto para receber', sharing: 'Pronto para o celular', discovering: 'Localizando o outro PC',
    preparing: 'Preparando a pasta', checking: 'Preparando o destino',
    sending: 'Enviando arquivos', receiving: 'Recebendo arquivos', paused: 'Aguardando reconexão',
    completed: 'Transferência concluída', error: 'Falha na transferência'
  };

  if ($('#copyProjectSourceName')) {
    $('#copyProjectSourceName').textContent = copyProjectSourceFolder?.name || 'Nenhum arquivo ou pasta selecionado';
    $('#copyProjectSourcePath').textContent = copyProjectSourceFolder?.path || 'Escolha um arquivo avulso ou uma pasta completa.';
  }
  if ($('#copyProjectDestinationName')) {
    $('#copyProjectDestinationName').textContent = copyProjectDestinationFolder?.name || 'Nenhuma pasta selecionada';
    $('#copyProjectDestinationPath').textContent = copyProjectDestinationFolder?.path || 'Arquivos com o mesmo nome serão substituídos neste local.';
  }
  const fixedCode = String(data.fixedCode || '');
  if ($('#copyProjectReceiveCode')) $('#copyProjectReceiveCode').textContent = fixedCode || (receiverActive ? (data.code || '------') : '------');
  if ($('#copyProjectShareCode')) $('#copyProjectShareCode').textContent = fixedCode || (data.sharing ? (data.shareCode || data.code || '------') : '------');
  if (statusBadge) statusBadge.textContent = phaseLabels[data.phase] || 'Parado';
  if ($('#copyProjectProgressTitle')) $('#copyProjectProgressTitle').textContent = titleLabels[data.phase] || 'Aguardando';
  if ($('#copyProjectProgressPercent')) $('#copyProjectProgressPercent').textContent = `${percent}%`;
  if (progressBar) {
    progressBar.style.width = `${percent}%`;
    progressBar.classList.toggle('copy-project-indeterminate',
      busy && total === 0);
  }
  let detail = 'Escolha se este computador vai enviar ou receber.';
  if (waiting) detail = 'Este computador está visível na rede. Digite o código no PC emissor.';
  else if (data.phase === 'sharing') detail = 'A pasta está disponível somente nesta rede local. Digite o código no celular.';
  else if (data.phase === 'paused') detail = 'Rede desconectada. A transferência continua automaticamente quando a conexão voltar.';
  else if (data.phase === 'discovering') detail = 'Procurando o computador que exibiu este código...';
  else if (data.phase === 'preparing') detail = 'Preparando a lista de arquivos para envio.';
  else if (data.phase === 'checking') detail = 'Preparando os arquivos no destino.';
  else if (data.phase === 'sending' || data.phase === 'receiving') {
    const doneMb = done / (1024 * 1024);
    const totalMb = total / (1024 * 1024);
    detail = `${doneMb.toFixed(1)} de ${totalMb.toFixed(1)} MB`;
    if (data.fileCount > 0) detail += ` • Arquivo ${Math.min(data.fileIndex || 0, data.fileCount)} de ${data.fileCount}`;
  } else if (data.phase === 'completed') detail = data.result || 'Transferência concluída.';
  else if (data.phase === 'error') detail = data.error || 'Não foi possível concluir a transferência.';
  if ($('#copyProjectProgressText')) $('#copyProjectProgressText').textContent = detail;
  if ($('#copyProjectCurrentFile')) $('#copyProjectCurrentFile').textContent = data.currentFile || data.peerName || '';

  const operationActive = busy || waiting || data.sharing;
  if (sourceButton) sourceButton.disabled = operationActive;
  if (sourceFileButton) sourceFileButton.disabled = operationActive;
  if (destinationButton) destinationButton.disabled = operationActive;
  if (codeInput) codeInput.disabled = operationActive;
  if (sendButton) sendButton.disabled = operationActive || !copyProjectSourceFolder || String(codeInput?.value || '').length !== 6;
  if (receiveButton) {
    receiveButton.disabled = busy || (!waiting && !copyProjectDestinationFolder);
    receiveButton.textContent = receiverActive ? 'Desativar recebimento' : 'Ativar recebimento';
  }
  if (shareButton) {
    shareButton.disabled = busy || waiting || (!data.sharing && !copyProjectSourceFolder);
    shareButton.textContent = data.sharing ? 'Parar de disponibilizar' : 'Disponibilizar para celular';
  }
  cancelButton?.classList.toggle('hidden', !busy);
  openButton?.classList.toggle('hidden', !(data.phase === 'completed' && data.receivedPath));
}

async function selectCopyProjectFolder(mode) {
  try {
    const result = await window.hookUpdateCenter.selectCopyProjectFolder(mode);
    if (result?.canceled) return;
    const folder = { path: result.path, name: result.name || result.path,
      kind: result.kind || (mode === 'send-file' ? 'file' : 'folder') };
    if (mode === 'receive') copyProjectDestinationFolder = folder;
    else copyProjectSourceFolder = folder;
    renderCopyProjectState();
  } catch (error) {
    showModal({ title: 'Transfer Hook', message: friendlyError(error, 'Não foi possível escolher o arquivo ou a pasta.'), type: 'error' });
  }
}

async function toggleCopyProjectReceiver() {
  try {
    if (copyProjectState?.receiving) {
      renderCopyProjectState(await window.hookUpdateCenter.stopCopyProjectReceive());
      return;
    }
    if (!copyProjectDestinationFolder) return;
    renderCopyProjectState(await window.hookUpdateCenter.startCopyProjectReceive({
      destinationPath: copyProjectDestinationFolder.path
    }));
  } catch (error) {
    showModal({ title: 'Transfer Hook', message: friendlyError(error, 'Não foi possível ativar o recebimento.'), type: 'error' });
  }
}

async function sendCopyProjectFolder() {
  if (!copyProjectSourceFolder || copyProjectIsBusy()) return;
  const code = String($('#copyProjectReceiverCode')?.value || '').replace(/\D/g, '').slice(0, 6);
  if (code.length !== 6) return;
  try {
    await window.hookUpdateCenter.sendCopyProject({
      sourcePath: copyProjectSourceFolder.path, code
    });
  } catch (error) {
    // O estado detalhado também chega pelo evento, mas o modal torna a falha
    // de descoberta/rede inequívoca quando o usuário está em outra aba.
    showModal({ title: 'Transfer Hook', message: friendlyError(error, 'Não foi possível enviar os arquivos.'), type: 'error' });
  }
}

async function toggleCopyProjectShare() {
  try {
    if (copyProjectState?.sharing) {
      renderCopyProjectState(await window.hookUpdateCenter.stopCopyProjectShare());
      return;
    }
    if (!copyProjectSourceFolder) return;
    renderCopyProjectState(await window.hookUpdateCenter.startCopyProjectShare({
      sourcePath: copyProjectSourceFolder.path
    }));
  } catch (error) {
    showModal({ title: 'Transfer Hook', message: friendlyError(error, 'Não foi possível disponibilizar os arquivos.'), type: 'error' });
  }
}

async function refreshCopyProjectState() {
  try { renderCopyProjectState(await window.hookUpdateCenter.getCopyProjectState()); } catch (_) {}
}

function readHookMarkerSettings() {
  return {
    fps: Number($('#hookMarkerFps')?.value || 30),
    offset: String($('#hookMarkerOffset')?.value || '00:00:00:00').trim(),
    sequence: Number($('#hookMarkerSequence')?.value || 1),
    executorPage: Number($('#hookMarkerExecutorPage')?.value || 1),
    executor: Number($('#hookMarkerExecutor')?.value || 1),
    timecodePool: Number($('#hookMarkerTimecodePool')?.value || 1),
    timecodeSlot: Number($('#hookMarkerTimecodeSlot')?.value || 2),
    resolumeHost: String($('#hookMarkerResolumeHost')?.value || '127.0.0.1').trim(),
    resolumePort: Number($('#hookMarkerResolumePort')?.value || 7000),
    resolumeFirstColumn: Number($('#hookMarkerResolumeFirstColumn')?.value || 1)
  };
}

function applyHookMarkerSettings(settings = {}) {
  const fields = {
    hookMarkerFps: settings.fps,
    hookMarkerOffset: settings.offset,
    hookMarkerSequence: settings.sequence,
    hookMarkerExecutorPage: settings.executorPage,
    hookMarkerExecutor: settings.executor,
    hookMarkerTimecodePool: settings.timecodePool,
    hookMarkerTimecodeSlot: settings.timecodeSlot,
    hookMarkerResolumeHost: settings.resolumeHost,
    hookMarkerResolumePort: settings.resolumePort,
    hookMarkerResolumeFirstColumn: settings.resolumeFirstColumn
  };
  Object.entries(fields).forEach(([id, value]) => {
    const input = $(`#${id}`);
    if (input && value !== undefined && value !== null) input.value = String(value);
  });
}

function hookMarkerTimecode(seconds, fps) {
  const rate = Math.max(1, Math.round(Number(fps) || 30));
  let framesTotal = Math.max(0, Math.round((Number(seconds) || 0) * rate));
  const frames = framesTotal % rate;
  framesTotal = Math.floor(framesTotal / rate);
  const secs = framesTotal % 60;
  framesTotal = Math.floor(framesTotal / 60);
  const minutes = framesTotal % 60;
  const hours = Math.floor(framesTotal / 60);
  return [hours, minutes, secs, frames]
    .map((value) => String(value).padStart(2, '0')).join(':');
}

function parseHookMarkerOffset(value, fps) {
  const parts = String(value || '').trim().split(':').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part) || part < 0)) return 0;
  return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / Math.max(1, fps);
}

function renderHookMarkerPreview() {
  const list = $('#hookMarkerPreviewList');
  if (!list) return;
  const markers = Array.isArray(hookMarkerState?.markers) ? hookMarkerState.markers : [];
  const songs = Array.isArray(hookMarkerState?.songs) ? hookMarkerState.songs : [];
  if (!hookMarkerState?.connected) {
    list.innerHTML = '<p class="muted">Conecte o REAPER para visualizar os marcadores.</p>';
    return;
  }
  if (!songs.length && !markers.length) {
    list.innerHTML = '<p class="muted">O projeto aberto não possui regiões de música nem marcadores.</p>';
    return;
  }
  const settings = readHookMarkerSettings();
  const fps = Math.max(1, Math.round(settings.fps || 30));
  const offset = parseHookMarkerOffset(settings.offset, fps);
  const firstColumn = Math.max(1, Math.round(settings.resolumeFirstColumn || 1));
  const markerGlobalIndex = new Map(markers.map((marker, index) => [String(marker.id), index]));
  const songHtml = songs.map((song, songIndex) => {
    const start = Number(song.start) || 0;
    const end = Math.max(start, Number(song.end) || start);
    const contained = markers.filter((marker) => {
      const position = Number(marker.position) || 0;
      return position > start + 0.0005 && position < end - 0.0005;
    });
    const cues = [
      { id: `region-${song.id}`, name: song.name, position: 0, regionStart: true },
      ...contained.map((marker) => ({ ...marker, position: Math.max(0, (Number(marker.position) || 0) - start) }))
    ];
    return `
      <div class="hook-marker-song-heading">
        <strong>${escapeHtml(song.name || `Música ${songIndex + 1}`)}</strong>
        <span>Sequence ${settings.sequence + songIndex} · Executor ${settings.executorPage}.${settings.executor + songIndex} · Timecode ${settings.timecodePool + songIndex}</span>
      </div>
      ${cues.map((cue, cueIndex) => {
        const resolumeIndex = markerGlobalIndex.get(String(cue.id));
        return `
          <div class="hook-marker-preview-item${cue.regionStart ? ' is-region-start' : ''}">
            <strong>${cueIndex + 1}</strong>
            <span title="${escapeHtml(cue.name || '')}">${escapeHtml(cue.name || `Cue ${cueIndex + 1}`)}${cue.regionStart ? ' — início da região' : ''}</span>
            <code>${hookMarkerTimecode((Number(cue.position) || 0) + offset, fps)}</code>
            <span>${cue.regionStart || resolumeIndex === undefined ? 'Início' : `Coluna ${firstColumn + resolumeIndex}`}</span>
          </div>`;
      }).join('')}`;
  }).join('');
  const markerHtml = markers.map((marker, index) => `
    <div class="hook-marker-preview-item">
      <strong>${index + 1}</strong>
      <span title="${escapeHtml(marker.name || '')}">${escapeHtml(marker.name || `Marcador ${index + 1}`)}</span>
      <code>${hookMarkerTimecode((Number(marker.position) || 0) + offset, fps)}</code>
      <span>Coluna ${firstColumn + index}</span>
    </div>`).join('');
  list.innerHTML = songHtml || markerHtml;
}

function renderHookMarkerRuntimeState(nextState) {
  if (nextState) hookMarkerRuntimeState = nextState;
  const active = hookMarkerRuntimeState?.active === true;
  const button = $('#hookMarkerRunResolumeButton');
  const status = $('#hookMarkerResolumeRuntimeStatus');
  if (button) {
    button.textContent = active ? 'Desativar execução' : 'Ativar durante o Play';
    button.classList.toggle('is-running', active);
  }
  if (status) {
    if (hookMarkerRuntimeState?.lastError) {
      status.textContent = hookMarkerRuntimeState.lastError;
      status.classList.add('is-error');
    } else if (active) {
      const lastCue = Number(hookMarkerRuntimeState.lastTriggeredCue) || 0;
      status.textContent = lastCue > 0
        ? `Ativo. Último cue enviado: ${lastCue}.`
        : `Ativo com ${hookMarkerRuntimeState.cueCount || 0} cues. Aguardando o Play do REAPER.`;
      status.classList.remove('is-error');
    } else {
      status.textContent = 'Execução automática desligada.';
      status.classList.remove('is-error');
    }
  }
}

function renderHookMarkerState(nextState, { applySettings = false } = {}) {
  if (nextState) hookMarkerState = nextState;
  if (applySettings && hookMarkerState?.settings) applyHookMarkerSettings(hookMarkerState.settings);
  const connected = hookMarkerState?.connected === true;
  const markers = Array.isArray(hookMarkerState?.markers) ? hookMarkerState.markers : [];
  const songs = Array.isArray(hookMarkerState?.songs) ? hookMarkerState.songs : [];
  const badge = $('#hookMarkerStatusBadge');
  if (badge) badge.textContent = connected ? 'REAPER conectado' : 'Aguardando REAPER';
  $('#hookMarkerProjectName').textContent = connected
    ? (hookMarkerState.projectName || 'Projeto sem nome')
    : 'Nenhum projeto conectado';
  $('#hookMarkerProjectPath').textContent = connected
    ? (hookMarkerState.projectPath || 'Projeto ainda não foi salvo em disco.')
    : 'Abra o REAPER e carregue um projeto com marcadores.';
  $('#hookMarkerCountBadge').textContent = `${songs.length} música${songs.length === 1 ? '' : 's'} · ${markers.length} marcador${markers.length === 1 ? '' : 'es'}`;
  const canExportGrandMa2 = connected && songs.length > 0 && !hookMarkerBusy;
  const canUseResolume = connected && markers.length > 0 && !hookMarkerBusy;
  $('#hookMarkerExportGrandMa2Button').disabled = !canExportGrandMa2;
  $('#hookMarkerExportResolumeButton').disabled = !canUseResolume;
  $('#hookMarkerRunResolumeButton').disabled = !canUseResolume && hookMarkerRuntimeState?.active !== true;
  $('#hookMarkerRefreshButton').disabled = hookMarkerBusy;
  $('#hookMarkerTestResolumeButton').disabled = hookMarkerBusy;
  renderHookMarkerPreview();
}

async function refreshHookMarkerState({ applySettings = true } = {}) {
  try {
    renderHookMarkerState(await window.hookUpdateCenter.getHookMarkerState(), { applySettings });
    renderHookMarkerRuntimeState(await window.hookUpdateCenter.getHookMarkerRuntimeState());
  } catch (error) {
    hookMarkerState = { connected: false, markers: [], songs: [] };
    renderHookMarkerState();
    showModal({ title: 'Hook Marker', message: friendlyError(error, 'Não foi possível ler os marcadores do REAPER.'), type: 'error' });
  }
}

async function toggleHookMarkerResolumeRuntime() {
  if (hookMarkerBusy) return;
  hookMarkerBusy = true;
  renderHookMarkerState();
  try {
    const runtime = hookMarkerRuntimeState?.active
      ? await window.hookUpdateCenter.stopHookMarkerResolume()
      : await window.hookUpdateCenter.startHookMarkerResolume(readHookMarkerSettings());
    renderHookMarkerRuntimeState(runtime);
  } catch (error) {
    showModal({ title: 'Hook Marker', message: friendlyError(error, 'Não foi possível alterar a execução automática do Resolume.'), type: 'error' });
  } finally {
    hookMarkerBusy = false;
    renderHookMarkerState();
  }
}

async function saveHookMarkerSettingsFromUi() {
  renderHookMarkerPreview();
  try {
    await window.hookUpdateCenter.saveHookMarkerSettings(readHookMarkerSettings());
    if (hookMarkerRuntimeState?.active) {
      renderHookMarkerRuntimeState(await window.hookUpdateCenter.stopHookMarkerResolume());
    }
  } catch (_) {}
}

async function exportHookMarkerGrandMa2() {
  if (hookMarkerBusy) return;
  hookMarkerBusy = true;
  renderHookMarkerState();
  try {
    const result = await window.hookUpdateCenter.exportHookMarkerGrandMa2(readHookMarkerSettings());
    if (!result?.cancelled) showModal({
      title: 'Arquivos grandMA2 prontos',
      message: `${result.songCount} música(s) exportada(s): ${result.markerCount} cues em ${result.fileCount} arquivos XML. Para cada música, copie o timecode para importexport e o macro para macros no grandMA2.`,
      type: 'success'
    });
  } catch (error) {
    showModal({ title: 'Hook Marker', message: friendlyError(error, 'Não foi possível exportar os arquivos grandMA2.'), type: 'error' });
  } finally {
    hookMarkerBusy = false;
    renderHookMarkerState();
  }
}

async function exportHookMarkerResolume() {
  if (hookMarkerBusy) return;
  hookMarkerBusy = true;
  renderHookMarkerState();
  try {
    const result = await window.hookUpdateCenter.exportHookMarkerResolume(readHookMarkerSettings());
    if (!result?.cancelled) showModal({
      title: 'Mapa Resolume pronto',
      message: `${result.markerCount} cues exportados com os endereços OSC das colunas.`,
      type: 'success'
    });
  } catch (error) {
    showModal({ title: 'Hook Marker', message: friendlyError(error, 'Não foi possível exportar o mapa do Resolume.'), type: 'error' });
  } finally {
    hookMarkerBusy = false;
    renderHookMarkerState();
  }
}

async function testHookMarkerResolume() {
  if (hookMarkerBusy) return;
  hookMarkerBusy = true;
  renderHookMarkerState();
  try {
    const result = await window.hookUpdateCenter.testHookMarkerResolume(readHookMarkerSettings());
    showModal({
      title: 'Comando enviado ao Resolume',
      message: `A coluna ${result.column} foi acionada em ${result.host}:${result.port}.`,
      type: 'success'
    });
  } catch (error) {
    showModal({ title: 'Hook Marker', message: friendlyError(error, 'Não foi possível enviar o comando OSC ao Resolume.'), type: 'error' });
  } finally {
    hookMarkerBusy = false;
    renderHookMarkerState();
  }
}

function setToolsPanel(panelName = 'rename') {
  const allowed = ['rename', 'cable', 'midi', 'copy-project', 'hook-marker', 'pingpong'];
  if (selectedToolsPanel === 'pingpong' && panelName !== 'pingpong' && pingPongGame.running) stopPingPongGame();
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
  if (selectedToolsPanel === 'cable') refreshDirectCableState();
  if (selectedToolsPanel === 'midi') refreshHookMidiState();
  if (selectedToolsPanel === 'copy-project') refreshCopyProjectState();
  if (selectedToolsPanel === 'hook-marker') refreshHookMarkerState();
  if (selectedToolsPanel === 'pingpong') requestAnimationFrame(resizePingPongCanvas);
}

function setupToolsSubmenu() {
  $$('[data-tools-panel]').forEach((button) => {
    button.addEventListener('click', () => setToolsPanel(button.dataset.toolsPanel));
  });
  $('#directCableRefreshButton')?.addEventListener('click', refreshDirectCableState);
  $('#directCableProjectSyncAdapterSelect')?.addEventListener('change', () => renderDirectCableChannel('projectSync', directCableState));
  $('#directCableTimecodeAdapterSelect')?.addEventListener('change', () => renderDirectCableChannel('timecode', directCableState));
  $('#directCableProjectSyncConfigureButton')?.addEventListener('click', () => configureDirectCableFromUi('projectSync'));
  $('#directCableTimecodeConfigureButton')?.addEventListener('click', () => configureDirectCableFromUi('timecode'));
  $('#directCableProjectSyncRestoreButton')?.addEventListener('click', () => restoreDirectCableFromUi('projectSync'));
  $('#directCableTimecodeRestoreButton')?.addEventListener('click', () => restoreDirectCableFromUi('timecode'));
  $('#hookMidiStartButton')?.addEventListener('click', createHookMidiPortFromUi);
  $('#hookMidiRefreshButton')?.addEventListener('click', refreshHookMidiState);
  $('#hookMidiInstallButton')?.addEventListener('click', installHookMidiComponentsFromUi);
  $('#hookMidiPortName')?.addEventListener('input', updateHookMidiNamePreview);
  $('#hookMidiPortName')?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') createHookMidiPortFromUi();
  });
  $('#hookMidiPortsList')?.addEventListener('click', (event) => {
    const button = event.target.closest('[data-hook-midi-remove]');
    if (button) removeHookMidiPortFromUi(button.dataset.hookMidiRemove);
  });
  $('#hookMidiLoopMidiButton')?.addEventListener('click', () => {
    window.hookUpdateCenter.openExternal(
      'https://www.tobias-erichsen.de/software/loopmidi.html');
  });
  $('#copyProjectSelectSourceButton')?.addEventListener('click', () => selectCopyProjectFolder('send'));
  $('#copyProjectSelectFileButton')?.addEventListener('click', () => selectCopyProjectFolder('send-file'));
  $('#copyProjectSelectDestinationButton')?.addEventListener('click', () => selectCopyProjectFolder('receive'));
  $('#copyProjectSendButton')?.addEventListener('click', sendCopyProjectFolder);
  $('#copyProjectShareButton')?.addEventListener('click', toggleCopyProjectShare);
  $('#copyProjectReceiveButton')?.addEventListener('click', toggleCopyProjectReceiver);
  $('#copyProjectCancelButton')?.addEventListener('click', async () => {
    try { renderCopyProjectState(await window.hookUpdateCenter.cancelCopyProject()); } catch (_) {}
  });
  $('#copyProjectOpenDestinationButton')?.addEventListener('click', () => {
    window.hookUpdateCenter.openCopyProjectDestination().catch((error) => {
      showModal({ title: 'Transfer Hook', message: friendlyError(error, 'Não foi possível abrir a pasta recebida.'), type: 'error' });
    });
  });
  $('#copyProjectReceiverCode')?.addEventListener('input', (event) => {
    event.currentTarget.value = String(event.currentTarget.value || '').replace(/\D/g, '').slice(0, 6);
    renderCopyProjectState();
  });
  $('#hookMarkerRefreshButton')?.addEventListener('click', () => refreshHookMarkerState({ applySettings: false }));
  $('#hookMarkerExportGrandMa2Button')?.addEventListener('click', exportHookMarkerGrandMa2);
  $('#hookMarkerExportResolumeButton')?.addEventListener('click', exportHookMarkerResolume);
  $('#hookMarkerTestResolumeButton')?.addEventListener('click', testHookMarkerResolume);
  $('#hookMarkerRunResolumeButton')?.addEventListener('click', toggleHookMarkerResolumeRuntime);
  [
    '#hookMarkerFps', '#hookMarkerOffset', '#hookMarkerSequence',
    '#hookMarkerExecutorPage', '#hookMarkerExecutor', '#hookMarkerTimecodePool',
    '#hookMarkerTimecodeSlot',
    '#hookMarkerResolumeHost', '#hookMarkerResolumePort',
    '#hookMarkerResolumeFirstColumn'
  ].forEach((selector) => {
    $(selector)?.addEventListener('change', saveHookMarkerSettingsFromUi);
  });
  $('#hookMarkerOffset')?.addEventListener('input', renderHookMarkerPreview);
  $('#hookMarkerResolumeFirstColumn')?.addEventListener('input', renderHookMarkerPreview);
  window.hookUpdateCenter.onCopyProjectState(renderCopyProjectState);
  window.hookUpdateCenter.onHookMarkerRuntimeState(renderHookMarkerRuntimeState);
  setupPingPongGame();
  setToolsPanel(selectedToolsPanel);
}

function setView(viewName) {
  if (viewName !== 'tools' && pingPongGame.running) stopPingPongGame();
  $$('.nav-item').forEach((button) => button.classList.toggle('active', button.dataset.view === viewName));
  $$('.view').forEach((view) => view.classList.remove('active'));
  $(`#${viewName}View`).classList.add('active');
  document.body.classList.toggle('bridge-mode', viewName === 'bridge');
  document.body.classList.toggle('previous-mode', viewName === 'previous');
  document.body.classList.toggle('lyrics-mode', viewName === 'lyrics');
  document.body.classList.toggle('tools-mode', viewName === 'tools');
  updateDownloadCompactMode();
  if (viewName === 'home') refreshChatHook(!chatHookState).catch(() => {});
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

function isChatHookHomeVisible() {
  return document.visibilityState !== 'hidden' && $('#homeView')?.classList.contains('active');
}

function chatHookInitials(name) {
  const parts = String(name || 'User').trim().split(/\s+/).filter(Boolean);
  return (parts.length > 1 ? `${parts[0][0]}${parts[parts.length - 1][0]}` : parts[0]?.slice(0, 2) || 'U').toUpperCase();
}

function formatChatHookTime(value) {
  const date = new Date(value || '');
  if (!Number.isFinite(date.getTime())) return '';
  return date.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
}

function chatHookAvatarHtml(name, avatarUrl = '') {
  if (avatarUrl) return `<img src="${escapeHtml(avatarUrl)}" alt="" />`;
  return `<span>${escapeHtml(chatHookInitials(name))}</span>`;
}

function renderChatHookMessages(forceBottom = false) {
  const container = $('#chatHookMessages');
  if (!container) return;
  const wasNearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 64;
  const retentionDays = Math.max(1, Math.min(30, Number(chatHookState?.chat?.retentionDays || 7)));
  const cutoff = Date.now() - (retentionDays * 24 * 60 * 60 * 1000);
  const messages = [...chatHookMessagesById.values()]
    .filter((message) => {
      const createdAt = new Date(message.createdAt || '').getTime();
      return !Number.isFinite(createdAt) || createdAt >= cutoff;
    })
    .sort((a, b) => Number(a.id || 0) - Number(b.id || 0));
  const currentUserId = Number(chatHookState?.user?.id || 0);
  const currentUserIsAdmin = chatHookState?.user?.isAdmin === true;
  const pinnedMessageId = Number(chatHookState?.chat?.pinnedMessageId || 0);

  if (!messages.length) {
    container.innerHTML = '<div class="chat-hook-empty">Nenhuma mensagem ainda. Comece a conversa.</div>';
    return;
  }

  container.innerHTML = messages.map((message) => {
    const safeName = escapeHtml(message.name || 'User');
    const safeText = escapeHtml(message.text || '').replace(/\n/g, '<br>');
    const uploadState = message.pending
      ? '<span class="chat-hook-upload-spinner" aria-label="Enviando mídia"></span>'
      : message.failed
        ? '<span class="chat-hook-upload-failed">!</span>'
        : '';
    const image = message.imageUrl
      ? `<button class="chat-hook-message-image${message.pending ? ' is-uploading' : ''}${message.failed ? ' is-failed' : ''}" type="button"${message.pending ? ' disabled' : ` data-chat-image-url="${escapeHtml(message.imageUrl)}"`} title="${message.pending ? 'Enviando imagem' : 'Abrir imagem'}"><img src="${escapeHtml(message.imageUrl)}" alt="Imagem enviada por ${safeName}" />${uploadState}</button>`
      : '';
    const video = message.videoUrl
      ? `<div class="chat-hook-message-video${message.pending ? ' is-uploading' : ''}${message.failed ? ' is-failed' : ''}"><video src="${escapeHtml(message.videoUrl)}" controls playsinline preload="metadata" ${message.pending ? 'muted' : ''}></video>${uploadState}</div>`
      : '';
    const canPin = !message.pending && !message.failed && currentUserIsAdmin && Number(message.customerId || 0) === currentUserId && Boolean(String(message.text || '').trim());
    const isPinned = canPin && Number(message.id || 0) === pinnedMessageId;
    const pinAction = canPin
      ? `<button class="chat-hook-pin-message" type="button" data-chat-pin-message-id="${Number(message.id || 0)}" title="${isPinned ? 'Desafixar mensagem' : 'Fixar mensagem no topo'}">${isPinned ? 'Desafixar' : '📌 Fixar'}</button>`
      : '';
    const canDelete = !message.pending && !message.failed && (currentUserIsAdmin || Number(message.customerId || 0) === currentUserId);
    const deleteAction = canDelete
      ? `<button class="chat-hook-delete-message" type="button" data-chat-delete-message-id="${Number(message.id || 0)}" title="Apagar mensagem" aria-label="Apagar mensagem">🗑</button>`
      : '';
    return `
      <article class="chat-hook-message ${message.isAdmin ? 'admin' : 'user'}">
        <div class="chat-hook-avatar">${chatHookAvatarHtml(message.name, message.avatarUrl)}</div>
        <div class="chat-hook-message-body">
          <div class="chat-hook-message-head">
            <strong>${safeName}</strong>
            ${message.isAdmin ? '<span>ADMIN</span>' : ''}
            <time>${escapeHtml(formatChatHookTime(message.createdAt))}</time>
            ${pinAction}
            ${deleteAction}
          </div>
          ${safeText ? `<p>${safeText}</p>` : ''}
          ${image}
          ${video}
        </div>
      </article>`;
  }).join('');
  if (forceBottom || wasNearBottom) container.scrollTop = container.scrollHeight;
}

function renderChatHookCurrentUser() {
  const user = chatHookState?.user;
  const currentAvatar = $('#chatHookCurrentAvatar');
  const userKey = `${user?.id || ''}|${user?.name || ''}|${user?.avatarUrl || ''}|${user?.isAdmin === true}`;
  if (currentAvatar && currentAvatar.dataset.userKey !== userKey) {
    currentAvatar.dataset.userKey = userKey;
    currentAvatar.innerHTML = chatHookAvatarHtml(user?.name || 'Hook', user?.avatarUrl || '');
  }
  const avatarButton = $('#chatHookAvatarButton');
  if (avatarButton) avatarButton.classList.toggle('hidden', user?.isAdmin !== true);
  $('#chatHookAdminMenuButton')?.classList.toggle('hidden', user?.isAdmin !== true);
}

function chatHookCooldownRemaining() {
  if (chatHookState?.user?.isAdmin) return 0;
  const target = new Date(chatHookState?.limits?.nextAllowedAt || '').getTime();
  return Number.isFinite(target) ? Math.max(0, Math.ceil((target - Date.now()) / 1000)) : 0;
}

function renderChatHookControls() {
  const user = chatHookState?.user;
  const settings = chatHookState?.chat || {};
  const limits = chatHookState?.limits || {};
  const cooldown = chatHookCooldownRemaining();
  const authenticated = Boolean(user?.id);
  const exhausted = authenticated && !user?.isAdmin && limits.unlimited !== true && Number(limits.remainingToday || 0) <= 0;
  const closed = settings.open === false && !user?.isAdmin;
  const available = authenticated && !closed && !exhausted && cooldown <= 0 && !chatHookSending;
  const input = $('#chatHookMessageInput');
  const send = $('#chatHookSendButton');
  const imageButton = $('#chatHookImageButton');
  const mediaInput = $('#chatHookImageInput');
  const emojiButton = $('#chatHookEmojiButton');
  if (input) {
    input.disabled = !available;
    input.placeholder = !authenticated
      ? 'Ative sua licença para participar'
      : closed
      ? 'Chat fechado pelo administrador'
      : exhausted
        ? 'Limite diário atingido'
        : cooldown > 0
          ? `Aguarde ${cooldown}s para enviar novamente`
          : 'Escreva uma mensagem...';
  }
  if (send) {
    send.disabled = !available;
    send.textContent = chatHookSending ? 'Enviando...' : (cooldown > 0 ? `${cooldown}s` : 'Enviar');
  }
  if (imageButton) imageButton.disabled = !available;
  if (mediaInput) {
    const isAdmin = user?.isAdmin === true;
    mediaInput.accept = isAdmin
      ? 'image/png,image/jpeg,image/webp,image/gif,video/mp4,video/quicktime,video/webm'
      : 'image/png,image/jpeg,image/webp,image/gif';
    if (imageButton) imageButton.title = isAdmin ? 'Enviar foto, print ou vídeo de até 30s' : 'Enviar foto ou print';
    if (!isAdmin && chatHookSelectedMedia?.kind === 'video') clearChatHookSelectedMedia();
  }
  if (emojiButton) emojiButton.disabled = !available;
  $('#chatHookClosedNotice')?.classList.toggle('hidden', !closed);
  $('#chatHookComposer')?.classList.toggle('hidden', closed);
  const quota = $('#chatHookQuota');
  if (quota) quota.textContent = user?.isAdmin
    ? 'Administrador'
    : user?.id
      ? (limits.unlimited === true ? `${Number(limits.usedToday || 0)} hoje • ilimitado` : `${Number(limits.usedToday || 0)}/${Number(limits.dailyLimit || 10)} hoje`)
      : '--';
}

function renderHookTutorialCategory(category = hookTutorialCategory) {
  const cards = $('#hookTutorialCards');
  if (!cards) return;
  hookTutorialCategory = category === 'questions' ? 'questions' : 'tutorials';
  $$('[data-hook-tutorial-category]').forEach((button) => button.classList.toggle('active',
    button.dataset.hookTutorialCategory === hookTutorialCategory));
  const items = hookTutorialGroups[hookTutorialCategory] || [];
  const singular = hookTutorialCategory === 'questions' ? 'dúvida' : 'tutorial';
  cards.innerHTML = items.length ? items.map((item) => `
    <button class="hook-tutorial-card" type="button" data-tutorial-url="${escapeHtml(item.videoUrl || '')}">
      <img src="${escapeHtml(item.imageUrl || '')}" alt="${escapeHtml(item.title || singular)}" />
      <strong>${escapeHtml(item.title || `Assistir ${singular}`)}</strong>
    </button>`).join('') : `<p class="muted">Nenhum card de ${hookTutorialCategory === 'questions' ? 'dúvidas' : 'tutorial'} cadastrado ainda.</p>`;
}

async function openHookTutorialsModal() {
  const modal = $('#hookTutorialsModal');
  const cards = $('#hookTutorialCards');
  if (!modal || !cards) return;
  hookTutorialCategory = 'tutorials';
  modal.classList.remove('hidden');
  $$('[data-hook-tutorial-category]').forEach((button) => button.classList.toggle('active',
    button.dataset.hookTutorialCategory === 'tutorials'));
  cards.innerHTML = '<p class="muted">Carregando tutoriais...</p>';
  try {
    const result = await window.hookUpdateCenter.getHookTutorials();
    hookTutorialGroups = {
      tutorials: Array.isArray(result?.tutorials) ? result.tutorials : (Array.isArray(result?.items) ? result.items : []),
      questions: Array.isArray(result?.questions) ? result.questions : []
    };
    renderHookTutorialCategory('tutorials');
  } catch (error) {
    cards.innerHTML = `<p class="muted">${escapeHtml(friendlyError(error, 'Não foi possível carregar os tutoriais.'))}</p>`;
  }
}

function openChatHookAdminModal() {
  if (chatHookState?.user?.isAdmin !== true) return;
  const settings = chatHookState.chat || {};
  $('#chatHookAdminOpen').checked = settings.open !== false;
  $('#chatHookAdminDailyLimit').value = String(settings.dailyMessageLimit || 10);
  $('#chatHookAdminUnlimited').checked = settings.dailyMessageUnlimited === true;
  $('#chatHookAdminDailyLimit').disabled = settings.dailyMessageUnlimited === true;
  $('#chatHookAdminRetentionDays').value = String(settings.retentionDays || 7);
  $('#chatHookAdminModalStatus').textContent = '';
  $('#chatHookAdminModal').classList.remove('hidden');
}

function requestChatAdminPassword() {
  if (chatAdminPassword) return Promise.resolve(true);
  if (chatAdminPasswordResolver) return Promise.resolve(false);
  $('#chatAdminPasswordInput').value = '';
  $('#chatAdminPasswordStatus').textContent = '';
  $('#chatAdminPasswordModal').classList.remove('hidden');
  setTimeout(() => $('#chatAdminPasswordInput')?.focus(), 0);
  return new Promise((resolve) => { chatAdminPasswordResolver = resolve; });
}

function closeChatAdminPasswordModal(result = false) {
  $('#chatAdminPasswordModal')?.classList.add('hidden');
  const resolve = chatAdminPasswordResolver;
  chatAdminPasswordResolver = null;
  if (resolve) resolve(result);
}

async function confirmChatAdminPassword() {
  const password = String($('#chatAdminPasswordInput')?.value || '');
  const status = $('#chatAdminPasswordStatus');
  const button = $('#chatAdminPasswordConfirm');
  if (!password) { if (status) status.textContent = 'Digite a senha do painel.'; return; }
  if (button) button.disabled = true;
  try {
    await window.hookUpdateCenter.unlockChatAdmin({ adminPassword: password });
    chatAdminPassword = password;
    closeChatAdminPasswordModal(true);
  } catch (error) {
    if (status) status.textContent = friendlyError(error, 'Senha inválida.');
  } finally {
    if (button) button.disabled = false;
  }
}

function openChatReleaseNotesModal() {
  $('#chatReleaseNotesInput').value = String(chatHookState?.releaseNotes || chatHookState?.adminUpdate?.releaseNotes || state?.hookCenterLatest?.releaseNotes || '');
  $('#chatReleaseNotesStatus').textContent = '';
  $('#chatReleaseNotesModal').classList.remove('hidden');
}

function openChatPublishUpdateModal() {
  const update = chatHookState?.adminUpdate || {};
  const fields = {
    chatPublishVersion: update.version,
    chatPublishReleaseVersion: update.releaseVersion,
    chatPublishTitle: update.title,
    chatPublishYoutubeUrl: update.youtubeUrl,
    chatPublishWindowsUrl: update.windowsUrl,
    chatPublishMacosUrl: update.macosUrl,
    chatPublishWindowsExtensionUrl: update.windowsExtensionUrl,
    chatPublishMacosExtensionUrl: update.macosExtensionUrl,
    chatPublishTutorialUrl: update.tutorialUrl,
    chatPublishDescription: update.description,
    chatPublishReleaseNotes: update.releaseNotes
  };
  Object.entries(fields).forEach(([id, value]) => { if ($(`#${id}`)) $(`#${id}`).value = String(value || ''); });
  $('#chatPublishUpdateStatus').textContent = '';
  $('#chatPublishUpdateModal').classList.remove('hidden');
}

async function openChatAdminAction(action) {
  $('#chatHookAdminMenu')?.classList.add('hidden');
  if (!(await requestChatAdminPassword())) return;
  if (action === 'config') openChatHookAdminModal();
  else if (action === 'release-notes') openChatReleaseNotesModal();
  else if (action === 'publish-update') openChatPublishUpdateModal();
}

function closeChatHookAdminModal() {
  $('#chatHookAdminModal')?.classList.add('hidden');
}

async function saveChatHookAdminSettings() {
  const button = $('#chatHookAdminSaveButton');
  const status = $('#chatHookAdminModalStatus');
  if (button) button.disabled = true;
  try {
    const result = await window.hookUpdateCenter.updateChatAdminSettings({
      adminPassword: chatAdminPassword,
      open: $('#chatHookAdminOpen').checked,
      dailyMessageLimit: Number($('#chatHookAdminDailyLimit').value),
      dailyMessageUnlimited: $('#chatHookAdminUnlimited').checked,
      retentionDays: Number($('#chatHookAdminRetentionDays').value)
    });
    applyChatHookState(result, { full: true });
    closeChatHookAdminModal();
  } catch (error) {
    if (status) status.textContent = friendlyError(error, 'Não foi possível salvar as configurações.');
  } finally {
    if (button) button.disabled = false;
  }
}

async function clearChatHookFromAdminModal() {
  const confirmed = await confirmModal({ title: 'Limpar Chat Hook?', message: 'Todas as mensagens e mídias serão apagadas para todos.', type: 'warning', okText: 'Limpar' });
  if (!confirmed) return;
  try {
    const result = await window.hookUpdateCenter.clearChatAsAdmin({ adminPassword: chatAdminPassword });
    applyChatHookState(result, { full: true });
    $('#chatHookAdminModalStatus').textContent = 'Chat limpo.';
  } catch (error) {
    $('#chatHookAdminModalStatus').textContent = friendlyError(error, 'Não foi possível limpar o chat.');
  }
}

async function saveChatReleaseNotesFromModal() {
  const status = $('#chatReleaseNotesStatus');
  try {
    const result = await window.hookUpdateCenter.saveChatReleaseNotes({ adminPassword: chatAdminPassword, releaseNotes: $('#chatReleaseNotesInput').value });
    applyChatHookState(result, { full: true });
    $('#chatReleaseNotesModal').classList.add('hidden');
  } catch (error) {
    if (status) status.textContent = friendlyError(error, 'Não foi possível salvar as Release Notes.');
  }
}

async function publishUpdateFromChatModal() {
  const status = $('#chatPublishUpdateStatus');
  const button = $('#chatPublishUpdateSave');
  if (button) button.disabled = true;
  try {
    await window.hookUpdateCenter.publishUpdateFromHookCenter({
      adminPassword: chatAdminPassword,
      update: {
        version: $('#chatPublishVersion').value,
        releaseVersion: $('#chatPublishReleaseVersion').value,
        title: $('#chatPublishTitle').value,
        youtubeUrl: $('#chatPublishYoutubeUrl').value,
        windowsUrl: $('#chatPublishWindowsUrl').value,
        macosUrl: $('#chatPublishMacosUrl').value,
        windowsExtensionUrl: $('#chatPublishWindowsExtensionUrl').value,
        macosExtensionUrl: $('#chatPublishMacosExtensionUrl').value,
        tutorialUrl: $('#chatPublishTutorialUrl').value,
        description: $('#chatPublishDescription').value,
        releaseNotes: $('#chatPublishReleaseNotes').value
      }
    });
    $('#chatPublishUpdateModal').classList.add('hidden');
    await window.hookUpdateCenter.checkUpdates().catch(() => null);
    showModal({ title: 'Atualização publicada', message: 'A atualização foi publicada com sucesso.', type: 'success' });
  } catch (error) {
    if (status) status.textContent = friendlyError(error, 'Não foi possível publicar a atualização.');
  } finally {
    if (button) button.disabled = false;
  }
}

function applyChatHookState(next, { full = false } = {}) {
  if (!next?.ok) return;
  const nextRevision = Math.max(0, Number(next.chat?.revision || 0));
  const nextClearedAt = String(next.chat?.clearedAt || '');
  const resetMessages = full;
  if (resetMessages) {
    chatHookMessagesById.clear();
    chatHookLastMessageId = 0;
  }
  chatHookRevision = nextRevision;
  chatHookClearedAt = nextClearedAt;
  chatHookState = next;
  let messagesChanged = resetMessages;
  for (const message of (next.messages || [])) {
    const id = Number(message.id || 0);
    if (!id) continue;
    if (!chatHookMessagesById.has(id)) messagesChanged = true;
    chatHookMessagesById.set(id, message);
    chatHookLastMessageId = Math.max(chatHookLastMessageId, id);
  }
  const retentionDays = Math.max(1, Math.min(30, Number(next.chat?.retentionDays || 7)));
  const cutoff = Date.now() - (retentionDays * 24 * 60 * 60 * 1000);
  for (const [id, message] of chatHookMessagesById.entries()) {
    const createdAt = new Date(message.createdAt || '').getTime();
    if (Number.isFinite(createdAt) && createdAt < cutoff) {
      chatHookMessagesById.delete(id);
      messagesChanged = true;
    }
  }

  const pinned = $('#chatHookPinned');
  const pinnedText = String(next.chat?.pinnedMessage || '').trim();
  if (pinned) pinned.classList.toggle('hidden', !pinnedText);
  if ($('#chatHookPinnedText')) $('#chatHookPinnedText').textContent = pinnedText;
  const unpinButton = $('#chatHookUnpinButton');
  if (unpinButton) unpinButton.classList.toggle('hidden', !pinnedText || next.user?.isAdmin !== true);
  if ($('#chatHookConnectionStatus')) {
    $('#chatHookConnectionStatus').textContent = next.chat?.open === false ? 'Somente administradores' : 'Ao vivo';
  }
  renderChatHookCurrentUser();
  const customerNameInput = $('#chatCustomerNameInput');
  if (customerNameInput && document.activeElement !== customerNameInput) {
    customerNameInput.value = String(next.user?.name || '');
  }
  if (messagesChanged) renderChatHookMessages(full);
  renderChatHookControls();
  if ($('#chatHookStatus')?.dataset.kind === 'connection') $('#chatHookStatus').textContent = '';
}

async function refreshChatHook(forceFull = false) {
  if (!isChatHookHomeVisible() || chatHookPollInFlight) return;
  chatHookPollInFlight = true;
  chatHookLastPollAt = Date.now();
  try {
    const afterId = forceFull ? 0 : chatHookLastMessageId;
    const result = await window.hookUpdateCenter.getChatState(afterId);
    const serverRevision = Math.max(0, Number(result?.chat?.revision || 0));
    if (!forceFull && chatHookRevision && serverRevision !== chatHookRevision) {
      chatHookPollInFlight = false;
      await refreshChatHook(true);
      return;
    }
    applyChatHookState(result, { full: forceFull || !chatHookState });
  } catch (error) {
    const status = $('#chatHookStatus');
    if (status) {
      status.dataset.kind = 'connection';
      status.textContent = friendlyError(error, 'Não foi possível conectar ao Chat Hook.');
    }
    if ($('#chatHookConnectionStatus')) $('#chatHookConnectionStatus').textContent = 'Desconectado';
    if (!chatHookState) {
      const messages = $('#chatHookMessages');
      if (messages) messages.innerHTML = '<div class="chat-hook-empty">Ative sua licença e conecte-se à internet para usar o chat.</div>';
      renderChatHookControls();
    }
  } finally {
    chatHookPollInFlight = false;
  }
}

function startChatHookPolling() {
  if (chatHookPollTimer) return;
  chatHookPollTimer = window.setInterval(() => {
    if (Date.now() - chatHookLastPollAt >= 3000) refreshChatHook(false).catch(() => {});
    renderChatHookControls();
  }, 1000);
}

function readChatHookFile(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Não foi possível ler a mídia escolhida.'));
    reader.onload = () => {
      const dataUrl = String(reader.result || '');
      const base64 = dataUrl.includes(',') ? dataUrl.slice(dataUrl.indexOf(',') + 1) : '';
      if (!base64) return reject(new Error('A mídia escolhida é inválida.'));
      resolve({ mimeType: file.type, base64, dataUrl, name: file.name || 'mídia' });
    };
    reader.readAsDataURL(file);
  });
}

function readChatHookVideoDuration(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement('video');
    const finish = (callback) => {
      URL.revokeObjectURL(url);
      video.removeAttribute('src');
      callback();
    };
    video.preload = 'metadata';
    video.onloadedmetadata = () => finish(() => resolve(Number(video.duration) || 0));
    video.onerror = () => finish(() => reject(new Error('Não foi possível verificar a duração do vídeo.')));
    video.src = url;
  });
}

async function readChatHookImage(file, maxBytes) {
  const allowed = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
  if (!file || !allowed.includes(String(file.type || '').toLowerCase())) {
    throw new Error('Escolha uma imagem PNG, JPG, WEBP ou GIF.');
  }
  if (file.size > maxBytes) {
    throw new Error(`A imagem deve ter no máximo ${Math.floor(maxBytes / 1024 / 1024)} MB.`);
  }
  return { ...(await readChatHookFile(file)), kind: 'image' };
}

async function readChatHookMedia(file) {
  const mimeType = String(file?.type || '').toLowerCase();
  const imageTypes = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
  const videoTypes = ['video/mp4', 'video/quicktime', 'video/webm'];
  if (imageTypes.includes(mimeType)) {
    if (file.size > 6 * 1024 * 1024) throw new Error('A imagem deve ter no máximo 6 MB.');
    return { ...(await readChatHookFile(file)), kind: 'image' };
  }
  if (!videoTypes.includes(mimeType)) throw new Error('Escolha uma imagem ou um vídeo MP4, MOV ou WEBM.');
  if (chatHookState?.user?.isAdmin !== true) throw new Error('Somente administradores podem enviar vídeos.');
  if (file.size > 40 * 1024 * 1024) throw new Error('O vídeo deve ter no máximo 40 MB.');
  const durationSeconds = await readChatHookVideoDuration(file);
  if (!durationSeconds || durationSeconds > 30.25) throw new Error('O vídeo pode ter no máximo 30 segundos.');
  return { ...(await readChatHookFile(file)), kind: 'video', durationSeconds };
}

function clearChatHookSelectedMedia() {
  chatHookSelectedMedia = null;
  $('#chatHookImagePreview')?.classList.add('hidden');
  const imagePreview = $('#chatHookImagePreviewImage');
  if (imagePreview) {
    imagePreview.removeAttribute('src');
    imagePreview.classList.remove('hidden');
  }
  const videoPreview = $('#chatHookVideoPreview');
  if (videoPreview) {
    videoPreview.pause();
    videoPreview.removeAttribute('src');
    videoPreview.classList.add('hidden');
  }
  const input = $('#chatHookImageInput');
  if (input) input.value = '';
}

async function sendChatHookMessage() {
  if (chatHookSending) return;
  const input = $('#chatHookMessageInput');
  const text = String(input?.value || '').trim();
  if (!text && !chatHookSelectedMedia) {
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = 'Digite uma mensagem ou escolha uma mídia.';
    return;
  }
  const selectedMedia = chatHookSelectedMedia ? { ...chatHookSelectedMedia } : null;
  const optimisticId = selectedMedia ? Date.now() * 1000 + Math.floor(Math.random() * 1000) : 0;
  if (optimisticId) {
    const user = chatHookState?.user || {};
    chatHookMessagesById.set(optimisticId, {
      id: optimisticId,
      customerId: user.id || null,
      name: user.name || 'User',
      isAdmin: user.isAdmin === true,
      text,
      imageUrl: selectedMedia.kind === 'image' ? selectedMedia.dataUrl : '',
      videoUrl: selectedMedia.kind === 'video' ? selectedMedia.dataUrl : '',
      videoDurationSeconds: selectedMedia.durationSeconds || 0,
      avatarUrl: user.avatarUrl || '',
      createdAt: new Date().toISOString(),
      pending: true
    });
    if (input) input.value = '';
    clearChatHookSelectedMedia();
    renderChatHookMessages(true);
  }
  chatHookSending = true;
  renderChatHookControls();
  try {
    const result = await window.hookUpdateCenter.sendChatMessage({
      text,
      image: selectedMedia?.kind === 'image' ? { mimeType: selectedMedia.mimeType, base64: selectedMedia.base64 } : null,
      video: selectedMedia?.kind === 'video' ? { mimeType: selectedMedia.mimeType, base64: selectedMedia.base64, durationSeconds: selectedMedia.durationSeconds } : null
    });
    if (optimisticId) chatHookMessagesById.delete(optimisticId);
    if (input) input.value = '';
    clearChatHookSelectedMedia();
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = '';
    applyChatHookState(result, { full: false });
    renderChatHookMessages(true);
  } catch (error) {
    if (optimisticId && chatHookMessagesById.has(optimisticId)) {
      chatHookMessagesById.set(optimisticId, {
        ...chatHookMessagesById.get(optimisticId),
        pending: false,
        failed: true
      });
      renderChatHookMessages(true);
    }
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = friendlyError(error, 'Não foi possível enviar a mensagem.');
    await refreshChatHook(false).catch(() => {});
  } finally {
    chatHookSending = false;
    renderChatHookControls();
  }
}

async function setChatHookPinnedMessage(messageId, button = null) {
  if (chatHookState?.user?.isAdmin !== true) return;
  if (button) button.disabled = true;
  try {
    const result = await window.hookUpdateCenter.setChatPinnedMessage({ messageId });
    applyChatHookState(result, { full: true });
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = Number(messageId) > 0 && Number(result?.chat?.pinnedMessageId || 0) > 0
      ? 'Mensagem fixada no topo.'
      : 'Mensagem desafixada.';
  } catch (error) {
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = friendlyError(error, 'Não foi possível alterar a mensagem fixada.');
  } finally {
    if (button?.isConnected) button.disabled = false;
  }
}

async function deleteChatHookMessage(messageId, button = null) {
  const normalizedId = Math.floor(Number(messageId));
  if (!Number.isInteger(normalizedId) || normalizedId < 1) return;
  const confirmed = await confirmModal({
    title: 'Apagar mensagem?',
    message: 'Essa mensagem será apagada do Chat Hook para todos. Essa ação não pode ser desfeita.',
    type: 'warning',
    okText: 'Apagar',
    cancelText: 'Cancelar'
  });
  if (!confirmed) return;
  if (button) button.disabled = true;
  try {
    const result = await window.hookUpdateCenter.deleteChatMessage({ messageId: normalizedId });
    applyChatHookState(result, { full: true });
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = 'Mensagem apagada.';
  } catch (error) {
    if ($('#chatHookStatus')) $('#chatHookStatus').textContent = friendlyError(error, 'Não foi possível apagar a mensagem.');
  } finally {
    if (button?.isConnected) button.disabled = false;
  }
}

function setupChatHook() {
  $('#chatHookAdminMenuButton')?.addEventListener('click', (event) => {
    event.stopPropagation();
    $('#chatHookAdminMenu')?.classList.toggle('hidden');
  });
  $('#chatHookAdminMenu')?.addEventListener('click', (event) => {
    const action = event.target.closest('[data-chat-admin-action]')?.dataset.chatAdminAction;
    if (action) openChatAdminAction(action);
  });
  document.addEventListener('pointerdown', (event) => {
    const menu = $('#chatHookAdminMenu');
    const button = $('#chatHookAdminMenuButton');
    if (!menu || menu.classList.contains('hidden') || event.target === button || menu.contains(event.target)) return;
    menu.classList.add('hidden');
  });
  $('#chatAdminPasswordConfirm')?.addEventListener('click', confirmChatAdminPassword);
  $('#chatAdminPasswordCancel')?.addEventListener('click', () => closeChatAdminPasswordModal(false));
  $('#chatAdminPasswordInput')?.addEventListener('keydown', (event) => { if (event.key === 'Enter') confirmChatAdminPassword(); });
  $('#chatHookAdminCancelButton')?.addEventListener('click', closeChatHookAdminModal);
  $('#chatHookAdminSaveButton')?.addEventListener('click', saveChatHookAdminSettings);
  $('#chatHookAdminClearButton')?.addEventListener('click', clearChatHookFromAdminModal);
  $('#chatHookAdminUnlimited')?.addEventListener('change', (event) => {
    $('#chatHookAdminDailyLimit').disabled = event.target.checked;
  });
  $('#chatReleaseNotesCancel')?.addEventListener('click', () => $('#chatReleaseNotesModal')?.classList.add('hidden'));
  $('#chatReleaseNotesSave')?.addEventListener('click', saveChatReleaseNotesFromModal);
  $('#chatPublishUpdateCancel')?.addEventListener('click', () => $('#chatPublishUpdateModal')?.classList.add('hidden'));
  $('#chatPublishUpdateSave')?.addEventListener('click', publishUpdateFromChatModal);
  const sendWithEnter = $('#chatHookSendWithEnter');
  if (sendWithEnter) {
    sendWithEnter.checked = localStorage.getItem('chatHookSendWithEnter') === '1';
    sendWithEnter.addEventListener('change', () => {
      localStorage.setItem('chatHookSendWithEnter', sendWithEnter.checked ? '1' : '0');
    });
  }
  $('#saveChatCustomerNameButton')?.addEventListener('click', async () => {
    const input = $('#chatCustomerNameInput');
    const button = $('#saveChatCustomerNameButton');
    const message = $('#chatCustomerNameMessage');
    const name = String(input?.value || '').replace(/\s+/g, ' ').trim();
    if (!name) {
      if (message) message.textContent = 'Digite seu nome.';
      input?.focus();
      return;
    }
    if (button) {
      button.disabled = true;
      button.textContent = 'Salvando...';
    }
    try {
      const result = await window.hookUpdateCenter.updateChatProfile({ name });
      applyChatHookState(result, { full: true });
      if (message) message.textContent = 'Nome atualizado.';
    } catch (error) {
      if (message) message.textContent = friendlyError(error, 'Não foi possível atualizar seu nome.');
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = 'Salvar meu nome';
      }
    }
  });
  const picker = $('#chatHookEmojiPicker');
  if (picker) {
    picker.addEventListener('emoji-click', (event) => {
      const input = $('#chatHookMessageInput');
      const emoji = String(event.detail?.unicode || '');
      if (!emoji || !input) return;
      const start = Number.isFinite(input.selectionStart) ? input.selectionStart : input.value.length;
      const end = Number.isFinite(input.selectionEnd) ? input.selectionEnd : start;
      input.setRangeText(emoji, start, end, 'end');
      input.focus();
      picker.classList.add('hidden');
    });
  }
  const emojiButton = $('#chatHookEmojiButton');
  emojiButton?.addEventListener('click', (event) => {
    event.stopPropagation();
    picker?.classList.toggle('hidden');
  });
  document.addEventListener('pointerdown', (event) => {
    if (!picker || picker.classList.contains('hidden')) return;
    if (event.target === emojiButton || event.target === picker || picker.contains(event.target)) return;
    picker.classList.add('hidden');
  });
  $('#chatHookImageButton')?.addEventListener('click', () => $('#chatHookImageInput')?.click());
  $('#chatHookImageInput')?.addEventListener('change', async (event) => {
    try {
      chatHookSelectedMedia = await readChatHookMedia(event.target.files?.[0]);
      const imagePreview = $('#chatHookImagePreviewImage');
      const videoPreview = $('#chatHookVideoPreview');
      if (chatHookSelectedMedia.kind === 'video') {
        if (imagePreview) imagePreview.classList.add('hidden');
        if (videoPreview) {
          videoPreview.src = chatHookSelectedMedia.dataUrl;
          videoPreview.classList.remove('hidden');
        }
      } else {
        if (imagePreview) {
          imagePreview.src = chatHookSelectedMedia.dataUrl;
          imagePreview.classList.remove('hidden');
        }
        if (videoPreview) videoPreview.classList.add('hidden');
      }
      $('#chatHookImagePreview')?.classList.remove('hidden');
      if ($('#chatHookStatus')) $('#chatHookStatus').textContent = '';
    } catch (error) {
      clearChatHookSelectedMedia();
      if ($('#chatHookStatus')) $('#chatHookStatus').textContent = error.message;
    }
  });
  $('#chatHookRemoveImageButton')?.addEventListener('click', clearChatHookSelectedMedia);
  $('#chatHookSendButton')?.addEventListener('click', sendChatHookMessage);
  $('#chatHookMessageInput')?.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' || event.isComposing) return;
    const sendOnPlainEnter = sendWithEnter?.checked === true &&
      !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey;
    const sendOnShortcut = (event.ctrlKey || event.metaKey) && !event.shiftKey;
    if (sendOnPlainEnter || sendOnShortcut) {
      event.preventDefault();
      sendChatHookMessage();
    }
  });
  $('#chatHookMessages')?.addEventListener('click', (event) => {
    const deleteButton = event.target.closest('[data-chat-delete-message-id]');
    if (deleteButton) {
      deleteChatHookMessage(Number(deleteButton.dataset.chatDeleteMessageId || 0), deleteButton);
      return;
    }
    const pinButton = event.target.closest('[data-chat-pin-message-id]');
    if (pinButton) {
      setChatHookPinnedMessage(Number(pinButton.dataset.chatPinMessageId || 0), pinButton);
      return;
    }
    const button = event.target.closest('[data-chat-image-url]');
    if (button?.dataset.chatImageUrl) window.hookUpdateCenter.openExternal(button.dataset.chatImageUrl).catch(() => {});
  });
  $('#chatHookUnpinButton')?.addEventListener('click', (event) => setChatHookPinnedMessage(0, event.currentTarget));
  $('#chatHookAvatarButton')?.addEventListener('click', () => $('#chatHookAvatarInput')?.click());
  $('#chatHookAvatarInput')?.addEventListener('change', async (event) => {
    const status = $('#chatHookStatus');
    try {
      const image = await readChatHookImage(event.target.files?.[0], 3 * 1024 * 1024);
      if (status) status.textContent = 'Salvando foto...';
      const result = await window.hookUpdateCenter.uploadChatAvatar({ image: { mimeType: image.mimeType, base64: image.base64 } });
      applyChatHookState(result, { full: true });
      if (status) status.textContent = 'Foto atualizada.';
    } catch (error) {
      if (status) status.textContent = friendlyError(error, 'Não foi possível alterar a foto.');
    } finally {
      event.target.value = '';
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (isChatHookHomeVisible()) refreshChatHook(!chatHookState).catch(() => {});
  });
  startChatHookPolling();
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
  const planCard = $('#licensePlanCard');
  const supportedPlanTypes = new Set(['lifetime', 'monthly', 'annual', 'mixed']);
  const planType = supportedPlanTypes.has(String(license.planType || '').toLowerCase())
    ? String(license.planType).toLowerCase()
    : 'none';
  const planDefaults = {
    lifetime: { label: 'Vitalício', description: 'Compra única, sem renovação.' },
    monthly: { label: 'Mensal', description: 'Assinatura com renovação mensal.' },
    annual: { label: 'Anual', description: 'Assinatura com renovação anual.' },
    mixed: { label: 'Mais de um plano', description: 'Esta licença reúne compras de tipos diferentes.' },
    none: { label: 'Não identificado', description: 'Ative ou verifique a licença para consultar seu plano.' }
  };
  if (planCard) {
    planCard.classList.remove('plan-none', 'plan-lifetime', 'plan-monthly', 'plan-annual', 'plan-mixed');
    planCard.classList.add(`plan-${planType}`);
  }
  if ($('#licensePlanLabel')) $('#licensePlanLabel').textContent = license.planLabel || planDefaults[planType].label;
  if ($('#licensePlanDescription')) $('#licensePlanDescription').textContent = planDefaults[planType].description;
  
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

  // Atualização direcionada nunca pode herdar o instalador da publicação
  // principal. Sem o link próprio, o botão deve acusar pacote incompleto.
  if (isTestClientUpdate(update)) return '';

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
          <button class="primary-button previous-install-button" data-index="${index}" ${packageAvailable ? '' : 'disabled'}>${packageAvailable ? (installed ? 'Reinstalar' : 'Instalar') : 'Indisponível'}</button>
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
        if (!(await showDownloadDescriptionNotice(update))) return;
        const reinstalling = update.installed === true;
        let source = null;
        if (reinstalling) {
          source = await reinstallSourceModal({
            title: `Reinstalar versão ${update.version || ''}?`,
            computerAvailable: update.cached === true
          });
          if (!source) return;
        } else {
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
        }
        button.disabled = true;
        button.textContent = reinstalling
          ? (source === 'internet' ? 'Baixando...' : 'Reinstalando...')
          : (update.cached ? 'Instalando...' : 'Baixando...');
        await window.hookUpdateCenter.installCachedUpdatePackage(
          reinstalling ? { update, source } : { update }
        );
        if (state?.platform === 'darwin') {
          renderState(await window.hookUpdateCenter.getState());
          await loadPreviousUpdates();
          showModal({
            title: reinstalling ? 'Reinstalação pronta' : 'Instalação pronta',
            message: reinstalling
              ? 'A extensão foi reinstalada e o instalador da Hook Center foi aberto.'
              : 'A extensão foi instalada e o instalador da Hook Center foi aberto.',
            type: 'success'
          });
        }
      } catch (error) {
        const reinstalling = update.installed === true;
        showModal({
          title: reinstalling ? 'Erro ao reinstalar' : 'Erro ao instalar',
          message: friendlyError(error, reinstalling
            ? 'Não foi possível reinstalar esta versão.'
            : 'Não foi possível instalar esta versão.'),
          type: 'error'
        });
      } finally {
        button.disabled = false;
        button.textContent = update.installed === true ? 'Reinstalar' : 'Instalar';
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
  setupChatHook();
  refreshChatHook(true).catch(() => {});

  $('#modalOkButton').addEventListener('click', () => {
    if (pendingModalRequest) {
      settleModal(pendingModalRequest.okValue);
      return;
    }
    hideModal();
  });
  $('#modalAlternativeButton')?.addEventListener('click', (event) => {
    if (event.currentTarget.disabled) return;
    if (pendingModalRequest) {
      settleModal(pendingModalRequest.alternativeValue);
      return;
    }
    hideModal();
  });
  $('#modalCancelButton').addEventListener('click', () => {
    if (pendingModalRequest) {
      settleModal(pendingModalRequest.cancelValue);
      return;
    }
    hideModal();
  });
  $('#appModal').addEventListener('click', (event) => { if (event.target.id === 'appModal') hideModal(); });
  $('#releaseNotesReadContinue')?.addEventListener('click', () => closeReleaseNotesReadModal(true));
  $('#releaseNotesReadCancel')?.addEventListener('click', () => closeReleaseNotesReadModal(false));
  $('#releaseNotesReadModal')?.addEventListener('click', (event) => {
    if (event.target.id === 'releaseNotesReadModal') closeReleaseNotesReadModal(false);
  });
  ['wheel', 'touchstart', 'pointerdown'].forEach((eventName) => {
    $('#releaseNotesReadContent')?.addEventListener(eventName, stopReleaseNotesScrollHint, { passive: true });
  });
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

  $('#openVideoModalButton')?.addEventListener('click', openUpdateVideoExternally);

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
  $('#hookTutorialsButton')?.addEventListener('click', openHookTutorialsModal);
  $$('[data-hook-tutorial-category]').forEach((button) => button.addEventListener('click', () =>
    renderHookTutorialCategory(button.dataset.hookTutorialCategory)));
  $('#closeHookTutorialsModal')?.addEventListener('click', () => $('#hookTutorialsModal')?.classList.add('hidden'));
  $('#hookTutorialCards')?.addEventListener('click', (event) => {
    const card = event.target.closest('[data-tutorial-url]');
    if (card?.dataset.tutorialUrl) window.hookUpdateCenter.openExternal(card.dataset.tutorialUrl).catch(() => {});
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
  window.hookUpdateCenter.onLicenseStatus((nextState) => {
    renderState(nextState);
    chatHookState = null;
    chatHookMessagesById.clear();
    chatHookLastMessageId = 0;
    refreshChatHook(true).catch(() => {});
  });
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
