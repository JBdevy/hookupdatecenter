function getVSHookBridgeBaseUrl() {
  try {
    const raw = localStorage.getItem('vshook_director_url')
    if (raw) return String(raw).replace(/\/+$/, '')
  } catch (error) {}
  return ''
}

function vshookBridgeUrl(path) {
  const base = getVSHookBridgeBaseUrl()
  const cleanPath = String(path || '').startsWith('/') ? String(path || '') : '/' + String(path || '')
  return base ? base + cleanPath : cleanPath
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function simpleHash(str) {
  const input = String(str ?? '')
  let h1 = 0x45D9
  let h2 = 0x2710
  for (let i = 0; i < input.length; i += 1) {
    const b = input.charCodeAt(i)
    const pos = i + 1
    h1 = (h1 ^ (b * pos + 17)) & 0xFFFFFF
    h2 = (h2 + ((b + i) * 131)) & 0xFFFFFF
    h1 = (h1 * 33 + h2) & 0xFFFFFF
    h2 = (h2 * 17 + h1) & 0xFFFFFF
  }
  const n = (((h1 << 12) >>> 0) + h2) >>> 0
  return n.toString(16).toUpperCase().padStart(8, '0')
}

function getNoticeHashFromState(data) {
  const candidates = [
    data?.recadosAuthHash,
    data?.recadosPasswordHash,
    data?.technicalNoticeAuthHash,
    data?.technicalNoticePasswordHash,
    data?.noticeAuthHash,
    data?.noticePasswordHash,
  ]
  for (const value of candidates) {
    const text = String(value || '').trim()
    if (text) return text
  }
  return ''
}

const state = {
  connected: false,
  loading: true,
  projectName: '',
  authRequired: false,
  authHash: '',
  authenticated: false,
  password: '',
  draft: '',
  status: '',
  sending: false,
}

function setStatus(text) {
  state.status = text || ''
  render()
}

function syncFromBridge(data) {
  state.connected = true
  state.loading = false
  state.projectName = String(data.projectName || data.currentProjectName || '')
  state.authHash = getNoticeHashFromState(data)
  state.authRequired = Boolean(data.recadosAuthEnabled === true || data.technicalNoticeAuthEnabled === true || data.noticeAuthEnabled === true || state.authHash || data.recadosPassword || data.technicalNoticePassword || data.noticePassword)
  if (!state.authRequired) state.authenticated = true
  if (state.authRequired && state.authenticated && state.authHash && simpleHash(state.password) !== state.authHash) {
    state.authenticated = false
  }
}

async function pollBridge() {
  try {
    const response = await fetch(vshookBridgeUrl('/state'), { cache: 'no-store' })
    if (!response.ok) throw new Error('offline')
    const data = await response.json()
    syncFromBridge(data)
  } catch (error) {
    state.connected = false
    state.loading = false
  }
  render()
}

function tryLogin(event) {
  event?.preventDefault?.()
  const input = document.getElementById('recadosPasswordInput')
  state.password = input ? input.value : state.password
  if (!state.authRequired || !state.authHash || simpleHash(state.password) === state.authHash) {
    state.authenticated = true
    state.status = ''
    render()
    return
  }
  state.authenticated = false
  state.status = 'SENHA INVALIDA'
  render()
}

function handleTextInput() {
  const input = document.getElementById('recadosTextInput')
  if (input) state.draft = input.value
  if (state.status) state.status = ''
}

async function sendRecado() {
  const text = String(state.draft || '').trim()
  if (!text || state.sending) {
    setStatus(text ? state.status : 'DIGITE UM RECADO')
    return
  }
  state.sending = true
  state.status = 'ENVIANDO...'
  render()
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'recados',
        text,
        passwordHash: simpleHash(state.password || ''),
      }),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao enviar')
    if (result.ignoredDuePriority) {
      state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      state.status = 'ENVIADO POR 10S'
    }
  } catch (error) {
    state.status = String(error?.message || 'ERRO AO ENVIAR').toLocaleUpperCase('pt-BR')
  } finally {
    state.sending = false
    render()
  }
}

function cancelRecado() {
  state.draft = ''
  state.status = ''
  render()
}

function backToModeSelector() {
  try {
    localStorage.removeItem('vshook_selected_mode')
  } catch (error) {}
  window.location.reload()
}

function renderOffline() {
  return `<div class="recadosShell"><div class="recadosCard"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Hook Center offline. Abra o VS Hook no REAPER e mantenha tudo na mesma rede Wi‑Fi.</p><button class="recadosSendButton" data-action="retry">PROCURAR NOVAMENTE</button><button class="recadosCancelButton" data-action="back">VOLTAR</button></div></div>`
}

function renderAuth() {
  return `<div class="recadosShell"><form class="recadosCard recadosAuthCard" id="recadosLoginForm"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Digite a senha do app Recados.</p><input id="recadosPasswordInput" class="recadosPasswordInput" type="password" autocomplete="current-password" placeholder="SENHA" value="${escapeHtml(state.password)}" />${state.status ? `<div class="recadosStatus">${escapeHtml(state.status)}</div>` : ''}<button class="recadosSendButton" type="submit">ENTRAR</button><button class="recadosCancelButton" type="button" data-action="back">VOLTAR</button></form></div>`
}

function renderEditor() {
  const sub = state.projectName ? `<div class="recadosProject">${escapeHtml(state.projectName)}</div>` : ''
  return `<div class="recadosApp"><div class="recadosTop"><button class="recadosSendButton" data-action="send" ${state.sending ? 'disabled' : ''}>${state.sending ? 'ENVIANDO...' : 'ENVIAR'}</button><button class="recadosCancelButton" data-action="cancel">CANCELAR</button></div>${sub}<textarea id="recadosTextInput" class="recadosTextInput" maxlength="500" placeholder="Digite o recado técnico...">${escapeHtml(state.draft)}</textarea>${state.status ? `<div class="recadosStatus">${escapeHtml(state.status)}</div>` : ''}</div>`
}

function bindEvents() {
  document.getElementById('recadosLoginForm')?.addEventListener('submit', tryLogin)
  document.querySelector('[data-action="retry"]')?.addEventListener('click', pollBridge)
  document.querySelector('[data-action="back"]')?.addEventListener('click', backToModeSelector)
  document.querySelector('[data-action="send"]')?.addEventListener('click', sendRecado)
  document.querySelector('[data-action="cancel"]')?.addEventListener('click', cancelRecado)
  document.getElementById('recadosTextInput')?.addEventListener('input', handleTextInput)
}

function render() {
  const root = document.getElementById('app')
  if (!root) return
  if (state.loading) {
    root.innerHTML = `<div class="recadosShell"><div class="recadosCard"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Conectando ao Hook Center...</p></div></div>`
  } else if (!state.connected) {
    root.innerHTML = renderOffline()
  } else if (state.authRequired && !state.authenticated) {
    root.innerHTML = renderAuth()
  } else {
    root.innerHTML = renderEditor()
  }
  bindEvents()
  const textInput = document.getElementById('recadosTextInput')
  if (textInput && document.activeElement !== textInput) {
    try { textInput.focus({ preventScroll: true }) } catch (error) {}
  }
}

function startRecadosApp() {
  render()
  pollBridge()
  setInterval(pollBridge, 1000)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startRecadosApp, { once: true })
} else {
  startRecadosApp()
}
