const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

let state = null;

function cleanErrorMessage(error) {
  let message = String(error?.message || error || 'Erro inesperado.');
  message = message.replace(/^Error invoking remote method '[^']+':\s*/i, '');
  message = message.replace(/^Error:\s*/i, '');
  return message.trim() || 'Erro inesperado.';
}

function friendlyError(error, fallback) {
  const message = cleanErrorMessage(error);
  const lower = message.toLowerCase();

  if (lower.includes('cpf não encontrado') || lower.includes('cpf nao encontrado')) {
    return 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF e o e-mail usados na compra.';
  }

  if (lower.includes('e-mail') || lower.includes('email')) {
    if (lower.includes('não encontrado') || lower.includes('nao encontrado') || lower.includes('não confere') || lower.includes('nao confere')) {
      return 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF e o e-mail usados na compra.';
    }
  }

  if (lower.includes('já possui') || lower.includes('limite') || lower.includes('computadores')) {
    return message;
  }

  if (lower.includes('network') || lower.includes('fetch failed') || lower.includes('failed to fetch')) {
    return 'Não foi possível verificar agora.\nVerifique sua internet e tente novamente.';
  }

  return message || fallback;
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
}


function setView(viewName) {
  $$('.nav-item').forEach((button) => button.classList.toggle('active', button.dataset.view === viewName));
  $$('.view').forEach((view) => view.classList.remove('active'));
  $(`#${viewName}View`).classList.add('active');
}

function formatDate(value) {
  if (!value) return '--';
  return new Date(value).toLocaleString('pt-BR');
}

function normalizeYoutubeUrl(url) {
  if (!url) return '';
  if (url.includes('/embed/')) return url;
  const watchMatch = url.match(/[?&]v=([^&]+)/);
  if (watchMatch) return `https://www.youtube.com/embed/${watchMatch[1]}`;
  const shortMatch = url.match(/youtu\.be\/([^?&]+)/);
  if (shortMatch) return `https://www.youtube.com/embed/${shortMatch[1]}`;
  return url;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function renderState(nextState) {
  state = nextState;
  const isMac = state.platform === 'darwin';

  $('#platformLabel').textContent = isMac ? 'macOS 11+' : 'Windows 10/11';
  $('#currentVersion').textContent = state.currentVersion || '--';
  $('#lastCheck').textContent = formatDate(state.lastCheck);
  $('#updateStatus').textContent = state.latestUpdate ? 'Última publicação carregada' : 'Aguardando publicação';

  const hasLatest = !!state.latestUpdate;
  $('#noUpdateCard').classList.toggle('hidden', hasLatest);
  $('#updateCard').classList.toggle('hidden', !hasLatest);

  if (hasLatest) {
    const update = state.latestUpdate;
    $('#updateTitle').textContent = update.title || `VS Hook ${update.version || ''}`;
    $('#versionBadge').textContent = update.version ? `v${update.version}` : 'VS Hook';
    $('#updateDescription').textContent = update.description || '';

    const iframeUrl = normalizeYoutubeUrl(update.youtubeUrl || '');
    $('#youtubeFrame').src = iframeUrl;

    const changelog = Array.isArray(update.changelog) ? update.changelog : [];
    $('#changelogList').innerHTML = changelog.map((item) => `<li>${escapeHtml(item)}</li>`).join('');
  }

  const license = state.license || {};
  $('#cpfInput').value = license.cpf || $('#cpfInput').value || '';
  $('#emailInput').value = license.email || $('#emailInput').value || '';
  $('#licenseActive').textContent = license.active ? 'Ativa' : 'Pendente';
  $('#licenseActive').classList.toggle('ok-text', !!license.active);
  $('#licenseDevices').textContent = `${license.devicesUsed || 0} de ${license.maxDevices || 0}`;
  
  if (license.active) {
    $('#licenseMessage').textContent = 'Licença ativa.';
  } else if (!$('#licenseMessage').textContent) {
    $('#licenseMessage').textContent = 'Aguardando ativação.';
  }
}

async function refreshState() {
  renderState(await window.hookUpdateCenter.getState());
}

async function init() {
  await refreshState();

  $('#modalOkButton').addEventListener('click', hideModal);
  $('#appModal').addEventListener('click', (event) => { if (event.target.id === 'appModal') hideModal(); });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape') hideModal(); });

  $$('.nav-item').forEach((button) => {
    button.addEventListener('click', () => setView(button.dataset.view));
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

  $('#downloadButton').addEventListener('click', async () => {
    try {
      $('#downloadCard').classList.remove('hidden');
      $('#downloadButton').disabled = true;
      $('#downloadButton').textContent = 'Baixando...';
      $('#progressBar').style.width = '0%';
      $('#progressText').textContent = '0%';
      $('#installButton').classList.add('hidden');
      await window.hookUpdateCenter.downloadUpdate();
    } catch (error) {
      showModal({ title: 'Erro no download', message: friendlyError(error, 'Não foi possível baixar a atualização.'), type: 'error' });
    } finally {
      $('#downloadButton').disabled = false;
      $('#downloadButton').textContent = 'Baixar / Reinstalar VS Hook';
    }
  });

  $('#installButton').addEventListener('click', async () => {
    try {
      const result = await window.hookUpdateCenter.installUpdate();
      if (result.ok) {
        renderState(await window.hookUpdateCenter.getState());
        $('#downloadCard').classList.add('hidden');
        $('#installButton').classList.add('hidden');
        $('#progressBar').style.width = '0%';
        $('#progressText').textContent = '0%';
        showModal({ title: 'Instalação concluída', message: `${result.installedVersion || 'VS Hook'} foi instalado com sucesso.`, type: 'success' });
      }
    } catch (error) {
      showModal({ title: 'Erro ao instalar', message: friendlyError(error, 'Não foi possível instalar a atualização.'), type: 'error' });
    }
  });

  $('#activateButton').addEventListener('click', async () => {
    try {
      $('#activateButton').disabled = true;
      $('#activateButton').textContent = 'Ativando...';
      $('#licenseMessage').textContent = 'Verificando dados...';

      const result = await window.hookUpdateCenter.activateLicense({
        cpf: $('#cpfInput').value,
        email: $('#emailInput').value
      });

      renderState(result.state || await window.hookUpdateCenter.getState());
      $('#licenseMessage').textContent = 'Licença ativada com sucesso.';
    } catch (error) {
      $('#licenseMessage').textContent = friendlyError(error, 'Erro ao ativar licença.');
      showModal({ title: 'Licença não encontrada', message: friendlyError(error, 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF e o e-mail usados na compra.'), type: 'error' });
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
      $('#licenseMessage').textContent = result.active ? 'Licença ativa.' : 'Esta licença não está ativa.';
      if (!result.active) {
        showModal({
          title: 'Licença não encontrada',
          message: 'Não encontramos uma compra ativa para os dados informados.\nVerifique o CPF e o e-mail usados na compra.',
          type: 'error'
        });
      }
    } catch (error) {
      const msg = friendlyError(error, 'Não foi possível verificar a licença.');
      $('#licenseMessage').textContent = msg;
      showModal({ title: 'Licença não encontrada', message: msg, type: 'error' });
    } finally {
      $('#licenseCheckButton').disabled = false;
      $('#licenseCheckButton').textContent = 'Verificar licença';
    }
  });

  window.hookUpdateCenter.onUpdateStatus(renderState);
  window.hookUpdateCenter.onLicenseStatus(renderState);
  window.hookUpdateCenter.onUpdateError((message) => showModal({ title: 'Erro ao verificar atualização', message: friendlyError(message, 'Não foi possível verificar atualizações.'), type: 'error' }));
  window.hookUpdateCenter.onDownloadProgress((progress) => {
    $('#progressBar').style.width = `${progress}%`;
    $('#progressText').textContent = `${progress}%`;
    if (progress >= 100) $('#installButton').classList.remove('hidden');
  });
}

init().catch((error) => {
  showModal({ title: 'Erro ao iniciar', message: friendlyError(error, 'Não foi possível iniciar o Hook Update Center.'), type: 'error' });
});
