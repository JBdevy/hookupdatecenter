const BRIDGE = 'http://127.0.0.1:47830';
const NOTICE_DURATION_MS = 20000;

const elements = {
  project: document.getElementById('projectName'),
  send: document.getElementById('sendButton'),
  remove: document.getElementById('removeButton'),
  pin: document.getElementById('pinButton'),
  edit: document.getElementById('editButton'),
  exit: document.getElementById('exitButton'),
  input: document.getElementById('messageInput'),
  imagePanel: document.getElementById('imagePanel'),
  imagePreview: document.getElementById('imagePreview'),
  imageEmpty: document.getElementById('imageEmpty'),
  chooseImage: document.getElementById('chooseImageButton'),
  removeImage: document.getElementById('removeImageButton'),
  status: document.getElementById('status'),
  slots: [...document.querySelectorAll('[data-slot]')]
};

const state = {
  connected: false,
  projectName: '',
  authHash: '',
  selectedSlot: 'global',
  templates: ['', '', ''],
  templateImages: ['', '', ''],
  globalDraft: '',
  editingTemplate: false,
  busy: false,
  notice: null,
  status: ''
};

async function fetchJson(path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(
    () => controller.abort(), Number(options.timeoutMs || 3000));
  const { timeoutMs: _timeoutMs, ...fetchOptions } = options;
  try {
    const response = await fetch(`${BRIDGE}${path}`, {
      cache: 'no-store',
      ...fetchOptions,
      signal: controller.signal
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) {
      throw new Error(payload.error || `HTTP ${response.status}`);
    }
    return payload;
  } finally {
    window.clearTimeout(timeout);
  }
}

function currentDraft() {
  return String(elements.input.value || '').slice(0, 500);
}

function selectedImagePath() {
  if (state.selectedSlot === 'global') return '';
  return String(state.templateImages[state.selectedSlot] || '');
}

function imagePreviewUrl(imagePath) {
  return imagePath
    ? `${BRIDGE}/media?path=${encodeURIComponent(imagePath)}`
    : '';
}

function remainingSeconds() {
  const notice = state.notice;
  if (!notice) return 0;
  if (notice.pinned === true) {
    return Math.max(
      0, Math.ceil(Number(notice.pausedRemainingMs || 0) / 1000));
  }
  return Math.max(
    0, Math.ceil((Number(notice.expiresAt || 0) - Date.now()) / 1000));
}

function statusText() {
  const remaining = remainingSeconds();
  if (remaining > 0) {
    return state.notice?.pinned
      ? `RECADO FIXADO: ${remaining}s RESTANTES`
      : `RECADO ATIVO: ${remaining}s`;
  }
  return state.status || '';
}

function render() {
  elements.project.textContent = state.connected
    ? (state.projectName || 'VS HOOK CONECTADO')
    : 'EXTENSÃO DESCONECTADA';
  elements.status.textContent = statusText();
  elements.send.disabled = state.busy || !state.connected;
  elements.remove.disabled = state.busy || !state.connected;
  elements.pin.disabled = state.busy || !state.connected;
  elements.send.textContent = state.busy ? 'AGUARDE…' : 'ENVIAR';
  const pinned = state.notice?.pinned === true;
  elements.pin.classList.toggle('active', pinned);
  elements.pin.setAttribute('aria-pressed', String(pinned));
  elements.pin.textContent = pinned ? 'FIXADO' : 'FIXAR';
  elements.slots.forEach((button) => {
    button.classList.toggle(
      'active', String(button.dataset.slot) === String(state.selectedSlot));
  });
  const templateSelected = state.selectedSlot !== 'global';
  elements.edit.classList.toggle('hidden', !templateSelected);
  elements.edit.classList.toggle('saving', state.editingTemplate);
  elements.edit.textContent =
    state.editingTemplate ? 'SALVAR' : 'EDITAR';
  elements.input.readOnly =
    templateSelected && !state.editingTemplate;
  elements.input.placeholder = templateSelected
    ? `Conteúdo do Recado ${Number(state.selectedSlot) + 1}`
    : 'Digite o recado técnico…';
  elements.imagePanel.classList.toggle('hidden', !templateSelected);
  const imagePath = selectedImagePath();
  const hasImage = Boolean(imagePath);
  elements.imagePreview.classList.toggle('hidden', !hasImage);
  elements.imageEmpty.classList.toggle('hidden', hasImage);
  if (hasImage) {
    const expectedUrl = imagePreviewUrl(imagePath);
    if (elements.imagePreview.dataset.path !== imagePath) {
      elements.imagePreview.dataset.path = imagePath;
      elements.imagePreview.src = expectedUrl;
    }
  } else {
    elements.imagePreview.removeAttribute('src');
    elements.imagePreview.dataset.path = '';
  }
  elements.chooseImage.disabled =
    state.busy || !state.connected || !templateSelected;
  elements.chooseImage.textContent =
    hasImage ? 'TROCAR IMAGEM' : 'ESCOLHER IMAGEM';
  elements.removeImage.disabled =
    state.busy || !state.connected || !hasImage;
  elements.slots.forEach((button) => {
    const slot = Number(button.dataset.slot);
    button.classList.toggle(
      'has-image',
      Number.isInteger(slot) &&
        Boolean(state.templateImages[slot]));
  });
}

function selectSlot(slot) {
  if (state.selectedSlot === 'global') {
    state.globalDraft = currentDraft();
  }
  state.selectedSlot =
    slot === 'global'
      ? 'global'
      : Math.max(0, Math.min(2, Number(slot)));
  state.editingTemplate = false;
  elements.input.value = state.selectedSlot === 'global'
    ? state.globalDraft
    : state.templates[state.selectedSlot] || '';
  state.status = '';
  render();
}

let refreshInFlight = false;
async function refresh() {
  if (refreshInFlight) return;
  if (document.activeElement === elements.input &&
      !elements.input.readOnly) {
    render();
    return;
  }
  refreshInFlight = true;
  try {
    const [snapshotResult, noticeResult, templateResult] =
      await Promise.allSettled([
        fetchJson('/state'),
        fetchJson('/technical-notice'),
        fetchJson('/recados-templates')
      ]);
    if (snapshotResult.status !== 'fulfilled') {
      throw snapshotResult.reason;
    }
    const snapshot = snapshotResult.value;
    const noticeData = noticeResult.status === 'fulfilled'
      ? noticeResult.value : {};
    const templateData = templateResult.status === 'fulfilled'
      ? templateResult.value : {};
    state.connected = true;
    state.projectName = String(
      snapshot.projectName ||
      snapshot.currentProjectName || '');
    state.authHash = String(
      snapshot.recadosAuthHash ||
      snapshot.technicalNoticeAuthHash || '');
    state.templates = [0, 1, 2].map(
      (index) => String(
        templateData.templates?.[index] ||
        snapshot.technicalNoticeSettings
          ?.recadosTemplates?.[index] || '').slice(0, 500));
    state.templateImages = [0, 1, 2].map(
      (index) => String(
        templateData.images?.[index] ||
        snapshot.technicalNoticeSettings
          ?.recadosImages?.[index] || ''));
    state.notice = noticeData.notice &&
      String(noticeData.notice.source || '').toLowerCase() === 'recados'
      ? noticeData.notice
      : null;
    if (state.selectedSlot !== 'global' &&
        !state.editingTemplate) {
      elements.input.value =
        state.templates[state.selectedSlot] || '';
    }
  } catch (error) {
    state.connected = false;
    state.status = 'ABRA O REAPER COM A EXTENSÃO VS HOOK';
  } finally {
    refreshInFlight = false;
  }
  render();
}

async function saveTemplate() {
  if (state.selectedSlot === 'global') return;
  if (!state.editingTemplate) {
    state.editingTemplate = true;
    render();
    elements.input.focus();
    return;
  }
  state.busy = true;
  state.status = 'SALVANDO…';
  render();
  try {
    const payload = await fetchJson('/recados-templates', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'recados',
        index: Number(state.selectedSlot),
        updateText: true,
        text: currentDraft(),
        passwordHash: state.authHash
      })
    });
    state.templates = [0, 1, 2].map(
      (index) => String(payload.templates?.[index] || ''));
    state.templateImages = [0, 1, 2].map(
      (index) => String(payload.images?.[index] || ''));
    state.editingTemplate = false;
    state.status = 'RECADO SALVO';
  } catch (error) {
    state.status = String(error.message || 'ERRO AO SALVAR')
      .toLocaleUpperCase('pt-BR');
  } finally {
    state.busy = false;
    render();
  }
}

async function saveTemplateImage(imagePath) {
  if (state.selectedSlot === 'global') return false;
  const slot = Number(state.selectedSlot);
  const previousPath = String(state.templateImages[slot] || '');
  state.busy = true;
  state.status = imagePath ? 'SALVANDO IMAGEM…' : 'REMOVENDO IMAGEM…';
  render();
  try {
    const payload = await fetchJson('/recados-templates', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'recados',
        index: slot,
        updateImage: true,
        imagePath: String(imagePath || ''),
        passwordHash: state.authHash
      })
    });
    state.templates = [0, 1, 2].map(
      (index) => String(payload.templates?.[index] || ''));
    state.templateImages = [0, 1, 2].map(
      (index) => String(payload.images?.[index] || ''));
    await window.vsHookRecados?.cleanupImages(
      slot, state.templateImages[slot]);
    state.status = imagePath
      ? 'IMAGEM SALVA — ELA TERÁ PRIORIDADE SOBRE O TEXTO'
      : 'IMAGEM REMOVIDA — O TEXTO SALVO VOLTA A SER USADO';
    return true;
  } catch (error) {
    await window.vsHookRecados?.cleanupImages(slot, previousPath);
    state.status = String(error.message || 'ERRO AO SALVAR IMAGEM')
      .toLocaleUpperCase('pt-BR');
    return false;
  } finally {
    state.busy = false;
    render();
  }
}

async function chooseImage() {
  if (state.selectedSlot === 'global' || state.busy) return;
  if (!window.vsHookRecados?.chooseImage) {
    state.status = 'SELETOR DE IMAGENS INDISPONÍVEL';
    render();
    return;
  }
  state.status = 'ESCOLHENDO IMAGEM…';
  render();
  try {
    const result = await window.vsHookRecados.chooseImage(
      Number(state.selectedSlot));
    if (result?.cancelled) {
      state.status = '';
      render();
      return;
    }
    if (!result?.ok || !result.path) {
      throw new Error(
        result?.error || 'Não foi possível selecionar a imagem.');
    }
    await saveTemplateImage(result.path);
  } catch (error) {
    state.status = String(error.message || 'ERRO AO ESCOLHER IMAGEM')
      .toLocaleUpperCase('pt-BR');
    render();
  }
}

async function removeImage() {
  if (!selectedImagePath() || state.busy) return;
  await saveTemplateImage('');
}

async function sendNotice() {
  const text = currentDraft().trim();
  const imagePath = selectedImagePath();
  if (!text && !imagePath) {
    state.status = state.selectedSlot === 'global'
      ? 'DIGITE UM RECADO'
      : 'DIGITE UM RECADO OU ESCOLHA UMA IMAGEM';
    render();
    return;
  }
  state.busy = true;
  state.status = 'ENVIANDO…';
  render();
  try {
    const payload = await fetchJson('/technical-notice', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'recados',
        text: imagePath ? '' : text,
        imagePath,
        pinned: state.notice?.pinned === true,
        passwordHash: state.authHash
      })
    });
    state.notice = payload.notice || {
      text: imagePath ? '' : text,
      imagePath,
      expiresAt: Date.now() + NOTICE_DURATION_MS
    };
    state.status = payload.ignoredDuePriority
      ? 'OUTRO RECADO TEM PRIORIDADE'
      : (imagePath ? 'IMAGEM ATIVA' : 'RECADO ATIVO');
  } catch (error) {
    state.status = String(error.message || 'ERRO AO ENVIAR')
      .toLocaleUpperCase('pt-BR');
  } finally {
    state.busy = false;
    render();
  }
}

async function removeNotice(silent = false) {
  if (state.busy) return false;
  state.busy = true;
  if (!silent) state.status = 'RETIRANDO…';
  render();
  try {
    const payload = await fetchJson('/technical-notice', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'cancel',
        source: 'recados',
        passwordHash: state.authHash
      })
    });
    if (!payload.ignoredDuePriority) state.notice = null;
    if (!silent) {
      state.status = payload.ignoredDuePriority
        ? 'OUTRO RECADO TEM PRIORIDADE'
        : 'RECADO REMOVIDO';
    }
  } catch (error) {
    if (!silent) {
      state.status = String(error.message || 'ERRO AO RETIRAR')
        .toLocaleUpperCase('pt-BR');
    }
  } finally {
    state.busy = false;
    render();
  }
  return true;
}

async function togglePin() {
  if (!state.notice) {
    state.status = 'ENVIE UM RECADO ANTES DE FIXAR';
    render();
    return;
  }
  const pin = state.notice.pinned !== true;
  state.busy = true;
  state.status = 'ATUALIZANDO…';
  render();
  try {
    const payload = await fetchJson('/technical-notice', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: pin ? 'pin' : 'unpin',
        source: 'recados',
        passwordHash: state.authHash
      })
    });
    state.notice = payload.notice || state.notice;
    state.status = pin ? 'RECADO FIXADO' : 'RECADO ATIVO';
  } catch (error) {
    state.status = String(error.message || 'ERRO AO ATUALIZAR')
      .toLocaleUpperCase('pt-BR');
  } finally {
    state.busy = false;
    render();
  }
}

elements.slots.forEach((button) => {
  button.addEventListener(
    'click', () => selectSlot(button.dataset.slot));
});
elements.edit.addEventListener('click', saveTemplate);
elements.chooseImage.addEventListener('click', chooseImage);
elements.removeImage.addEventListener('click', removeImage);
elements.send.addEventListener('click', sendNotice);
elements.remove.addEventListener(
  'click', () => removeNotice(false));
elements.pin.addEventListener('click', togglePin);
elements.exit.addEventListener('click', async () => {
  await removeNotice(true);
  window.close();
});
elements.input.addEventListener('input', () => {
  if (state.selectedSlot === 'global') {
    state.globalDraft = currentDraft();
  }
});
elements.imagePreview.addEventListener('error', () => {
  elements.imagePreview.classList.add('hidden');
  elements.imageEmpty.classList.remove('hidden');
  elements.imageEmpty.textContent = 'IMAGEM SALVA, MAS NÃO FOI POSSÍVEL EXIBIR A PRÉVIA';
});
elements.imagePreview.addEventListener('load', () => {
  elements.imageEmpty.textContent = 'NENHUMA IMAGEM SALVA';
});

render();
refresh();
window.setInterval(refresh, 1000);
window.setInterval(render, 250);
