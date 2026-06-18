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

const NOTICE_DURATION_MS = 20000

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
  noticeExpiresAt: 0,
  noticeId: '',
  lastView: '',
}

function getViewName() {
  if (state.loading) return 'loading'
  if (!state.connected) return 'offline'
  if (state.authRequired && !state.authenticated) return 'auth'
  return 'editor'
}

function getRemainingSeconds() {
  const remainingMs = Math.max(0, Number(state.noticeExpiresAt || 0) - Date.now())
  return remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0
}

function getStatusText() {
  const remaining = getRemainingSeconds()
  if (remaining > 0) return `RECADO ATIVO: ${remaining}s`
  if (Number(state.noticeExpiresAt || 0) > 0 && state.status === 'RECADO ATIVO') return 'RECADO EXPIRADO'
  return state.status || ''
}

function syncEditorDom() {
  const projectEl = document.getElementById('recadosProject')
  if (projectEl) projectEl.textContent = state.projectName || ''

  const statusEl = document.getElementById('recadosStatus')
  if (statusEl) statusEl.textContent = getStatusText()

  const sendButton = document.querySelector('[data-action="send"]')
  if (sendButton) {
    sendButton.disabled = !!state.sending
    sendButton.textContent = state.sending ? 'ENVIANDO...' : 'ENVIAR'
  }
}

function setStatus(text) {
  state.status = text || ''
  syncEditorDom()
}


function syncRecadosAuthDom(options = {}) {
  const input = document.getElementById('recadosPasswordInput')
  if (input && input.value !== String(state.password || '')) input.value = String(state.password || '')
  const statusEl = document.getElementById('recadosAuthStatus')
  if (statusEl) {
    const message = String(state.status || '')
    statusEl.textContent = message
    statusEl.style.display = message ? 'block' : 'none'
  }
  if (options && options.focus && input) {
    window.requestAnimationFrame(() => {
      try { input.focus({ preventScroll: true }) } catch (error) { try { input.focus() } catch (_) {} }
      try {
        const len = String(input.value || '').length
        input.setSelectionRange(len, len)
      } catch (error) {}
    })
  }
}

function focusRecadosPasswordInputSoon() {
  window.setTimeout(() => {
    const input = document.getElementById('recadosPasswordInput')
    if (!input) return
    try { input.focus({ preventScroll: true }) } catch (error) { try { input.focus() } catch (_) {} }
  }, 20)
}

function handleRecadosPasswordInput() {
  const input = document.getElementById('recadosPasswordInput')
  if (input) state.password = input.value
  if (state.status) {
    state.status = ''
    syncRecadosAuthDom({ focus: false })
  }
}

function syncFromBridge(data) {
  const previousView = getViewName()
  state.connected = true
  state.loading = false
  state.projectName = String(data.projectName || data.currentProjectName || '')
  state.authHash = getNoticeHashFromState(data)
  state.authRequired = Boolean(data.recadosAuthEnabled === true || data.technicalNoticeAuthEnabled === true || data.noticeAuthEnabled === true || state.authHash || data.recadosPassword || data.technicalNoticePassword || data.noticePassword)
  if (!state.authRequired) state.authenticated = true
  if (state.authRequired && state.authenticated && state.authHash && simpleHash(state.password) !== state.authHash) {
    state.authenticated = false
  }
  const nextView = getViewName()
  if (previousView !== nextView) render(true)
  else syncEditorDom()
}

async function pollTechnicalNotice() {
  if (!state.connected || getViewName() !== 'editor') return
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), { cache: 'no-store' })
    if (!response.ok) return
    const data = await response.json()
    const notice = data && data.notice ? data.notice : null
    if (!notice || String(notice.source || '').toLowerCase() !== 'recados') {
      if (getRemainingSeconds() <= 0) {
        state.noticeExpiresAt = 0
        state.noticeId = ''
      }
      syncEditorDom()
      return
    }
    state.noticeExpiresAt = Number(notice.expiresAt || 0)
    state.noticeId = String(notice.id || '')
    syncEditorDom()
  } catch (error) {}
}

async function pollBridge() {
  try {
    const response = await fetch(vshookBridgeUrl('/state'), { cache: 'no-store' })
    if (!response.ok) throw new Error('offline')
    const data = await response.json()
    syncFromBridge(data)
  } catch (error) {
    const previousView = getViewName()
    state.connected = false
    state.loading = false
    if (previousView !== getViewName()) render(true)
  }
  syncEditorDom()
}

function tryLogin(event) {
  event?.preventDefault?.()
  const input = document.getElementById('recadosPasswordInput')
  state.password = input ? input.value : state.password
  if (!state.authRequired || !state.authHash || simpleHash(state.password) === state.authHash) {
    state.authenticated = true
    state.status = ''
    render(true)
    return
  }
  state.authenticated = false
  state.status = 'SENHA INVALIDA'
  // Não re-renderiza a tela no erro, para não derrubar o teclado virtual.
  syncRecadosAuthDom({ focus: true })
}

function handleTextInput() {
  const input = document.getElementById('recadosTextInput')
  if (input) state.draft = input.value
  if (state.status) state.status = ''
  syncEditorDom()
}

async function sendRecado() {
  const input = document.getElementById('recadosTextInput')
  if (input) state.draft = input.value
  const text = String(state.draft || '').trim()
  if (!text || state.sending) {
    setStatus(text ? state.status : 'DIGITE UM RECADO')
    return
  }
  state.sending = true
  state.status = 'ENVIANDO...'
  syncEditorDom()
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
      state.noticeExpiresAt = 0
      state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      state.noticeExpiresAt = Number(result?.notice?.expiresAt || 0) || (Date.now() + NOTICE_DURATION_MS)
      state.noticeId = String(result?.notice?.id || '')
      state.status = 'RECADO ATIVO'
    }
  } catch (error) {
    state.status = String(error?.message || 'ERRO AO ENVIAR').toLocaleUpperCase('pt-BR')
  } finally {
    state.sending = false
    syncEditorDom()
  }
}

async function cancelRecado(options = {}) {
  const silent = !!options.silent
  if (state.sending) return false
  state.sending = true
  if (!silent) state.status = 'CANCELANDO...'
  syncEditorDom()
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        action: 'cancel',
        source: 'recados',
        passwordHash: simpleHash(state.password || ''),
      }),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao cancelar')
    if (result.ignoredDuePriority) {
      if (!silent) state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      state.noticeExpiresAt = 0
      state.noticeId = ''
      if (!silent) state.status = 'RECADO REMOVIDO'
    }
  } catch (error) {
    if (!silent) state.status = String(error?.message || 'ERRO AO CANCELAR').toLocaleUpperCase('pt-BR')
  } finally {
    state.sending = false
    syncEditorDom()
  }
  return true
}

async function exitRecadosApp() {
  backToModeSelector()
}

function backToModeSelector() {
  try {
    localStorage.removeItem('vshook_selected_mode')
  } catch (error) {}
  window.location.reload()
}

function renderOffline() {
  return `<div class="recadosShell"><div class="recadosCard"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Hook Center offline. Abra o VS Hook no REAPER e mantenha tudo na mesma rede Wi‑Fi.</p><button class="recadosCancelButton recadosBackWide" data-action="back">VOLTAR</button></div></div>`
}

function renderAuth() {
  return `<div class="recadosShell recadosAuthShell"><form class="recadosCard recadosAuthCard" id="recadosLoginForm"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Digite a senha do app Recados.</p><input id="recadosPasswordInput" class="recadosPasswordInput" type="password" inputmode="text" enterkeyhint="done" autocomplete="current-password" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="SENHA" value="${escapeHtml(state.password)}" /><div id="recadosAuthStatus" class="recadosStatus" style="${state.status ? '' : 'display:none'}">${escapeHtml(state.status || '')}</div><div class="recadosAuthButtons"><button class="recadosSendButton" type="submit">ENTRAR</button><button class="recadosCancelButton" type="button" data-action="back">VOLTAR</button></div></form></div>`
}

function renderEditor() {
  const sub = state.projectName ? `<div id="recadosProject" class="recadosProject">${escapeHtml(state.projectName)}</div>` : `<div id="recadosProject" class="recadosProject"></div>`
  return `<div class="recadosApp"><div class="recadosTop"><button class="recadosSendButton" data-action="send" ${state.sending ? 'disabled' : ''}>${state.sending ? 'ENVIANDO...' : 'ENVIAR'}</button><button class="recadosCancelButton" data-action="cancel">CANCELAR</button></div>${sub}<textarea id="recadosTextInput" class="recadosTextInput" maxlength="500" placeholder="Digite o recado técnico...">${escapeHtml(state.draft)}</textarea><div id="recadosStatus" class="recadosStatus">${escapeHtml(getStatusText())}</div><button class="recadosExitButton" data-action="exit">SAIR</button></div>`
}

function bindEvents() {
  document.getElementById('recadosLoginForm')?.addEventListener('submit', tryLogin)
  const recadosPasswordInput = document.getElementById('recadosPasswordInput')
  recadosPasswordInput?.addEventListener('input', handleRecadosPasswordInput)
  recadosPasswordInput?.addEventListener('pointerdown', focusRecadosPasswordInputSoon, { passive: true })
  recadosPasswordInput?.addEventListener('touchend', focusRecadosPasswordInputSoon, { passive: true })
  recadosPasswordInput?.addEventListener('click', focusRecadosPasswordInputSoon)
  document.querySelector('[data-action="retry"]')?.addEventListener('click', pollBridge)
  document.querySelector('[data-action="back"]')?.addEventListener('click', backToModeSelector)
  document.querySelector('[data-action="send"]')?.addEventListener('click', sendRecado)
  document.querySelector('[data-action="cancel"]')?.addEventListener('click', () => cancelRecado())
  document.querySelector('[data-action="exit"]')?.addEventListener('click', exitRecadosApp)
  document.getElementById('recadosTextInput')?.addEventListener('input', handleTextInput)
}

function render(force = false) {
  const root = document.getElementById('app')
  if (!root) return
  const view = getViewName()
  if (!force && state.lastView === view) {
    syncEditorDom()
    return
  }
  state.lastView = view
  if (view === 'loading') {
    root.innerHTML = `<div class="recadosShell"><div class="recadosCard"><img class="recadosLogo" src="./vshook-icon.png" alt="VS Hook" /><h1>Recados</h1><p>Conectando ao Hook Center...</p></div></div>`
  } else if (view === 'offline') {
    root.innerHTML = renderOffline()
  } else if (view === 'auth') {
    root.innerHTML = renderAuth()
  } else {
    root.innerHTML = renderEditor()
  }
  bindEvents()
  if (view === 'editor') syncEditorDom()
}

function startRecadosApp() {
  render(true)
  pollBridge()
  setInterval(pollBridge, 1000)
  setInterval(pollTechnicalNotice, 1000)
  setInterval(syncEditorDom, 250)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startRecadosApp, { once: true })
} else {
  startRecadosApp()
}
