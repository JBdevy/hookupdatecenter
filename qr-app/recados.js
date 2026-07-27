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

function formatRecadosError(error, fallback) {
  const message = String(error?.message || '').trim()
  const normalized = message.toLocaleLowerCase('pt-BR')
  if (error?.name === 'AbortError' || normalized.includes('abort')) {
    return 'O ENVIO DEMOROU DEMAIS. VERIFIQUE A CONEXÃO E TENTE NOVAMENTE.'
  }
  if (
    normalized.includes('failed to fetch') ||
    normalized.includes('fetch failed') ||
    normalized.includes('load failed') ||
    normalized.includes('networkerror') ||
    normalized.includes('network request failed') ||
    normalized.includes('internet connection appears to be offline')
  ) {
    return 'NÃO FOI POSSÍVEL CONECTAR AO VS HOOK. VERIFIQUE A REDE E TENTE NOVAMENTE.'
  }
  return String(message || fallback || 'NÃO FOI POSSÍVEL CONCLUIR A OPERAÇÃO.')
    .toLocaleUpperCase('pt-BR')
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
const EMBEDDED_DIRECTOR_MODE = (() => {
  try {
    return new URLSearchParams(window.location.search).get('embedded') === 'director'
  } catch (error) {
    return false
  }
})()
const DIRECTOR_RECADO_SESSION_KEY = 'vshook_director_recados_session_hash'

function getDirectorAuthHashFromState(data) {
  const candidates = [
    data?.directorAuthHash,
    data?.authHash,
    data?.accessAuthHash,
    data?.directorPasswordHash,
    data?.appDirectorAuthHash,
  ]
  for (const value of candidates) {
    const text = String(value || '').trim().toUpperCase()
    if (text) return text
  }
  return ''
}

function readDirectorRecadoSessionHash() {
  try {
    return String(sessionStorage.getItem(DIRECTOR_RECADO_SESSION_KEY) || '').trim().toUpperCase()
  } catch (error) {
    return ''
  }
}

function getRecadosRequestIdentity() {
  if (EMBEDDED_DIRECTOR_MODE) {
    return {
      source: 'director',
      sessionHash: String(state.directorSessionHash || '').trim().toUpperCase(),
    }
  }
  return {
    source: 'recados',
    passwordHash: simpleHash(state.password || ''),
  }
}

function withRecadosRequestIdentity(payload) {
  return Object.assign({}, payload || {}, getRecadosRequestIdentity())
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
  globalDraft: '',
  selectedSlot: 'global',
  templates: ['', '', ''],
  templateImages: ['', '', ''],
  editingTemplate: false,
  status: '',
  sending: false,
  noticeLocalDeadlineMs: 0,
  noticeId: '',
  noticeRemainingMs: 0,
  noticeLocalStarted: false,
  pinned: false,
  lastView: '',
  editorFocused: false,
  directorSessionHash: readDirectorRecadoSessionHash(),
}

function clampNoticeDuration(value, fallback = NOTICE_DURATION_MS) {
  const duration = Number(value)
  return Math.max(
    0,
    Math.min(
      NOTICE_DURATION_MS,
      Number.isFinite(duration) ? duration : fallback))
}

function beginLocalNoticeClock(pinned, durationMs = NOTICE_DURATION_MS) {
  const duration = clampNoticeDuration(durationMs)
  state.noticeLocalStarted = true
  state.pinned = pinned === true
  state.noticeRemainingMs = state.pinned ? duration : 0
  state.noticeLocalDeadlineMs = state.pinned
    ? 0
    : Date.now() + duration
}

function clearLocalNoticeClock() {
  state.noticeLocalDeadlineMs = 0
  state.noticeRemainingMs = 0
  state.noticeLocalStarted = false
  state.noticeId = ''
  state.pinned = false
}

function getRemoteInitialRemainingMs(notice, serverNow) {
  const pinned = notice?.pinned === true
  const paused = Number(notice?.pausedRemainingMs || 0)
  if (pinned && paused > 0) {
    return clampNoticeDuration(paused)
  }
  const expiresAt = Number(notice?.expiresAt || 0)
  const now = Number(serverNow)
  if (expiresAt > 0 && Number.isFinite(now) && now > 0) {
    return clampNoticeDuration(expiresAt - now)
  }
  return clampNoticeDuration(
    notice?.durationMs, NOTICE_DURATION_MS)
}

function syncLocalNoticeIdentity(notice, serverNow) {
  const nextId = String(notice?.id || '')
  if (!nextId) return
  const nextPinned = notice?.pinned === true
  const isNewNotice = nextId !== state.noticeId
  const pinStateChanged = nextPinned !== state.pinned
  if (isNewNotice) {
    state.noticeId = nextId
    beginLocalNoticeClock(
      nextPinned,
      getRemoteInitialRemainingMs(notice, serverNow))
    return
  }
  if (pinStateChanged) {
    const localRemaining = state.pinned
      ? clampNoticeDuration(state.noticeRemainingMs)
      : clampNoticeDuration(
          state.noticeLocalDeadlineMs - Date.now())
    state.pinned = nextPinned
    if (nextPinned) {
      state.noticeRemainingMs = localRemaining
      state.noticeLocalDeadlineMs = 0
    } else {
      state.noticeRemainingMs = 0
      state.noticeLocalDeadlineMs =
        Date.now() + localRemaining
    }
  }
}

function getViewName() {
  if (state.loading) return 'loading'
  if (!state.connected) return 'offline'
  if (state.authRequired && !state.authenticated) return 'auth'
  return 'editor'
}

function getRemainingSeconds() {
  if (state.pinned) return Math.max(0, Math.ceil(Number(state.noticeRemainingMs || 0) / 1000))
  const remainingMs = Math.max(
    0, Number(state.noticeLocalDeadlineMs || 0) - Date.now())
  return remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0
}

function getStatusText() {
  const remaining = getRemainingSeconds()
  if (remaining > 0) return `RECADO ATIVO: ${remaining}s`
  if (state.noticeLocalStarted && state.status === 'RECADO ATIVO') return 'RECADO EXPIRADO'
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
  const bridgeTemplates = data?.technicalNoticeSettings?.recadosTemplates
  const bridgeImages = data?.technicalNoticeSettings?.recadosImages
  const templateImagesChanged = Array.isArray(bridgeTemplates)
    ? applyTemplates(bridgeTemplates, bridgeImages)
    : false
  if (EMBEDDED_DIRECTOR_MODE) {
    state.directorSessionHash = readDirectorRecadoSessionHash() || getDirectorAuthHashFromState(data)
    state.authHash = ''
    state.authRequired = false
    state.authenticated = true
  } else {
    state.authHash = getNoticeHashFromState(data)
    state.authRequired = Boolean(data.recadosAuthEnabled === true || data.technicalNoticeAuthEnabled === true || data.noticeAuthEnabled === true || state.authHash || data.recadosPassword || data.technicalNoticePassword || data.noticePassword)
    if (!state.authRequired) state.authenticated = true
    if (state.authRequired && state.authenticated && state.authHash && simpleHash(state.password) !== state.authHash) {
      state.authenticated = false
    }
  }
  const nextView = getViewName()
  if (previousView !== nextView) render(true)
  else if (templateImagesChanged && nextView === 'editor') render(true)
  else syncEditorDom()
}

function applyTemplates(templates, images) {
  const previousImages = state.templateImages.join('\u0000')
  state.templates = [0, 1, 2].map((index) => String(templates?.[index] || '').slice(0, 500))
  if (Array.isArray(images)) {
    state.templateImages = [0, 1, 2].map((index) => String(images[index] || ''))
  }
  if (state.selectedSlot !== 'global' && !state.editingTemplate) {
    state.draft = state.templates[Number(state.selectedSlot)] || ''
    const input = document.getElementById('recadosTextInput')
    if (input && !state.editorFocused && document.activeElement !== input && input.value !== state.draft) input.value = state.draft
  }
  return previousImages !== state.templateImages.join('\u0000')
}

async function pollRecadosTemplates() {
  if (state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
  if (!state.connected || getViewName() !== 'editor' || state.editingTemplate) return
  try {
    const response = await fetch(vshookBridgeUrl('/recados-templates'), { cache: 'no-store' })
    if (!response.ok) return
    const data = await response.json()
    if (Array.isArray(data.templates) &&
        applyTemplates(data.templates, data.images)) {
      render(true)
    }
  } catch (_) {}
}

async function pollTechnicalNotice() {
  if (state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
  if (!state.connected || getViewName() !== 'editor') return
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), { cache: 'no-store' })
    if (!response.ok) return
    const data = await response.json()
    const notice = data && data.notice ? data.notice : null
    const expectedSource = EMBEDDED_DIRECTOR_MODE ? 'director' : 'recados'
    if (!notice || String(notice.source || '').toLowerCase() !== expectedSource) {
      if (getRemainingSeconds() <= 0) {
        state.noticeId = ''
      }
      syncEditorDom()
      return
    }
    // O servidor informa apenas qual recado está ativo. A contagem visual é
    // iniciada uma única vez e, depois disso, corre inteiramente neste app.
    syncLocalNoticeIdentity(notice, data?.now)
    syncEditorDom()
  } catch (error) {}
}

async function pollBridge() {
  if (state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
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

function captureRecadosDraft() {
  const input = document.getElementById('recadosTextInput')
  if (input) state.draft = input.value
}

function getSelectedRecadoImage() {
  if (state.selectedSlot === 'global') return ''
  return String(state.templateImages[Number(state.selectedSlot)] || '')
}

function getRecadoImageUrl(imagePath) {
  const value = String(imagePath || '').trim()
  return value
    ? vshookBridgeUrl(`/media?path=${encodeURIComponent(value)}`)
    : ''
}

function readImageFileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    if (!file || !String(file.type || '').startsWith('image/')) {
      reject(new Error('Escolha um arquivo de imagem.'))
      return
    }
    if (Number(file.size || 0) > 25 * 1024 * 1024) {
      reject(new Error('A imagem deve ter no máximo 25 MB.'))
      return
    }
    const reader = new FileReader()
    reader.onerror = () => reject(new Error('Não foi possível ler a imagem.'))
    reader.onload = () => {
      const image = new Image()
      image.onerror = () => reject(new Error('Imagem inválida.'))
      image.onload = () => {
        const maxSide = 1600
        const scale = Math.min(
          1,
          maxSide / Math.max(1, Number(image.naturalWidth || image.width || 1)),
          maxSide / Math.max(1, Number(image.naturalHeight || image.height || 1)))
        const width = Math.max(1, Math.round((image.naturalWidth || image.width) * scale))
        const height = Math.max(1, Math.round((image.naturalHeight || image.height) * scale))
        const canvas = document.createElement('canvas')
        canvas.width = width
        canvas.height = height
        const context = canvas.getContext('2d', { alpha: false })
        if (!context) {
          reject(new Error('Não foi possível preparar a imagem.'))
          return
        }
        context.fillStyle = '#000'
        context.fillRect(0, 0, width, height)
        context.drawImage(image, 0, 0, width, height)
        resolve(canvas.toDataURL('image/jpeg', 0.74))
      }
      image.src = String(reader.result || '')
    }
    reader.readAsDataURL(file)
  })
}

async function saveRecadoImage(imageDataUrl) {
  if (state.selectedSlot === 'global' || state.sending) return
  state.sending = true
  setStatus('SALVANDO IMAGEM...')
  try {
    const response = await fetch(vshookBridgeUrl('/recados-templates'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(withRecadosRequestIdentity({
        index: Number(state.selectedSlot),
        updateImage: true,
        imageDataUrl,
      })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) {
      throw new Error(result.error || 'Falha ao salvar a imagem')
    }
    applyTemplates(result.templates, result.images)
    state.status = 'IMAGEM SALVA'
    render(true)
  } catch (error) {
    state.status = formatRecadosError(
      error, 'ERRO AO SALVAR A IMAGEM')
  } finally {
    state.sending = false
    syncEditorDom()
  }
}

async function chooseRecadoImage(event) {
  const file = event?.target?.files?.[0]
  if (!file) return
  try {
    const imageDataUrl = await readImageFileAsDataUrl(file)
    await saveRecadoImage(imageDataUrl)
  } catch (error) {
    setStatus(formatRecadosError(error, 'IMAGEM INVÁLIDA'))
  } finally {
    if (event?.target) event.target.value = ''
  }
}

async function removeRecadoImage() {
  if (state.selectedSlot === 'global' || state.sending) return
  state.sending = true
  setStatus('REMOVENDO IMAGEM...')
  try {
    const response = await fetch(vshookBridgeUrl('/recados-templates'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(withRecadosRequestIdentity({
        index: Number(state.selectedSlot),
        updateImage: true,
        imagePath: '',
      })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) {
      throw new Error(result.error || 'Falha ao remover a imagem')
    }
    applyTemplates(result.templates, result.images)
    state.status = 'IMAGEM REMOVIDA'
    render(true)
  } catch (error) {
    state.status = formatRecadosError(
      error, 'ERRO AO REMOVER A IMAGEM')
  } finally {
    state.sending = false
    syncEditorDom()
  }
}

function selectRecadoSlot(slot) {
  captureRecadosDraft()
  const next = slot === 'global' ? 'global' : Math.max(0, Math.min(2, Number(slot)))
  if (state.selectedSlot === 'global') state.globalDraft = state.draft
  state.selectedSlot = next
  state.editingTemplate = false
  state.draft = next === 'global' ? state.globalDraft : (state.templates[next] || '')
  state.status = ''
  render(true)
}

async function toggleTemplateEdit() {
  if (state.selectedSlot === 'global') return
  if (!state.editingTemplate) {
    state.editingTemplate = true
    render(true)
    requestAnimationFrame(() => document.getElementById('recadosTextInput')?.focus())
    return
  }
  const input = document.getElementById('recadosTextInput')
  const text = String(input?.value ?? state.draft ?? '').trim().slice(0, 500)
  state.draft = text
  state.sending = true
  setStatus('SALVANDO...')
  try {
    const response = await fetch(vshookBridgeUrl('/recados-templates'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(withRecadosRequestIdentity({
        index: Number(state.selectedSlot),
        text,
        updateText: true,
      })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao salvar')
    applyTemplates(result.templates, result.images)
    state.editingTemplate = false
    state.status = 'RECADO SALVO'
    render(true)
  } catch (error) {
    state.status = formatRecadosError(error, 'ERRO AO SALVAR')
  } finally {
    state.sending = false
    syncEditorDom()
  }
}

async function sendRecado() {
  const input = document.getElementById('recadosTextInput')
  if (input) state.draft = input.value
  const text = String(state.draft || '').trim()
  const imagePath = getSelectedRecadoImage()
  if ((!text && !imagePath) || state.sending) {
    setStatus((text || imagePath) ? state.status : 'DIGITE UM RECADO OU ESCOLHA UMA IMAGEM')
    return
  }
  state.sending = true
  state.status = 'ENVIANDO...'
  syncEditorDom()
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(withRecadosRequestIdentity({
        text: imagePath ? '' : text,
        imagePath,
        pinned: state.pinned === true,
        durationMs: NOTICE_DURATION_MS,
      })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao enviar')
    if (result.ignoredDuePriority) {
      clearLocalNoticeClock()
      state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      state.noticeId = String(result?.notice?.id || '')
      beginLocalNoticeClock(
        result?.notice?.pinned === true,
        NOTICE_DURATION_MS)
      state.status = 'RECADO ATIVO'
    }
  } catch (error) {
    state.status = formatRecadosError(error, 'ERRO AO ENVIAR')
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
      body: JSON.stringify(withRecadosRequestIdentity({
        action: 'cancel',
      })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao cancelar')
    if (result.ignoredDuePriority) {
      if (!silent) state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      clearLocalNoticeClock()
      if (!silent) state.status = 'RECADO REMOVIDO'
    }
  } catch (error) {
    if (!silent) {
      state.status = formatRecadosError(error, 'ERRO AO CANCELAR')
    }
  } finally {
    state.sending = false
    syncEditorDom()
  }
  return true
}

async function exitRecadosApp() {
  await cancelRecado({ silent: true })
  backToModeSelector()
}

function backToModeSelector() {
  if (EMBEDDED_DIRECTOR_MODE) {
    try {
      window.parent.postMessage({ type: 'vshook-recados-close' }, window.location.origin)
    } catch (error) {}
    return
  }
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
  const slotButtons = [0, 1, 2].map((slot) => `<button class="recadosSlotButton ${state.selectedSlot === slot ? 'recadosSlotButtonActive' : ''}" data-action="select-slot" data-slot="${slot}">RECADO ${slot + 1}${state.templateImages[slot] ? ' · IMG' : ''}</button>`).join('')
  const globalButton = `<button class="recadosSlotButton recadosGlobalButton ${state.selectedSlot === 'global' ? 'recadosSlotButtonActive' : ''}" data-action="select-slot" data-slot="global">GLOBAL</button>`
  const editButton = state.selectedSlot === 'global' ? '' : `<button class="recadosEditButton ${state.editingTemplate ? 'recadosSaveButton' : ''}" data-action="edit-template">${state.editingTemplate ? 'SALVAR' : 'EDITAR'}</button>`
  const readonly = state.selectedSlot !== 'global' && !state.editingTemplate ? 'readonly' : ''
  const placeholder = state.selectedSlot === 'global' ? 'Digite o recado técnico...' : `Conteúdo do Recado ${Number(state.selectedSlot) + 1}`
  const imagePath = getSelectedRecadoImage()
  const imagePanel = state.selectedSlot === 'global' ? '' : `<div class="recadosImagePanel">${imagePath ? `<img class="recadosImagePreview" src="${escapeHtml(getRecadoImageUrl(imagePath))}" alt="Imagem do Recado ${Number(state.selectedSlot) + 1}" />` : `<div class="recadosImageEmpty">SEM IMAGEM</div>`}<div class="recadosImageActions"><button class="recadosImageButton" data-action="choose-image">${imagePath ? 'TROCAR IMAGEM' : 'ESCOLHER IMAGEM'}</button>${imagePath ? `<button class="recadosImageRemoveButton" data-action="remove-image">REMOVER IMAGEM</button>` : ''}</div><input id="recadosImageInput" class="recadosImageInput" type="file" accept="image/*" /></div>`
  return `<div class="recadosApp"><div class="recadosTop"><button class="recadosSendButton" data-action="send" ${state.sending ? 'disabled' : ''}>${state.sending ? 'ENVIANDO...' : 'ENVIAR'}</button><button class="recadosCancelButton" data-action="cancel">RETIRAR</button></div><button class="recadosPinButton ${state.pinned ? 'recadosPinButtonActive' : ''}" data-action="pin" aria-pressed="${state.pinned ? 'true' : 'false'}">${state.pinned ? 'FIXADO' : 'FIXAR'}</button><div class="recadosSlots">${slotButtons}${globalButton}</div><div class="recadosContentArea"><textarea id="recadosTextInput" class="recadosTextInput" maxlength="500" autocomplete="off" autocapitalize="sentences" autocorrect="off" spellcheck="false" enterkeyhint="enter" data-gramm="false" placeholder="${escapeHtml(placeholder)}" ${readonly}>${escapeHtml(state.draft)}</textarea>${imagePanel}</div>${editButton}<div id="recadosStatus" class="recadosStatus">${escapeHtml(getStatusText())}</div><button class="recadosExitButton" data-action="exit">SAIR</button></div>`
}

async function toggleRecadosPin() {
  captureRecadosDraft()
  const pinned = !state.pinned
  if (!state.noticeId) {
    state.pinned = pinned
    state.status = state.pinned ? 'FIXAR ATIVADO' : ''
    render(true)
    return
  }
  state.sending = true
  setStatus('ATUALIZANDO...')
  const localRemainingBeforeToggle = state.pinned
    ? clampNoticeDuration(state.noticeRemainingMs)
    : clampNoticeDuration(
        state.noticeLocalDeadlineMs - Date.now())
  try {
    const response = await fetch(vshookBridgeUrl('/technical-notice'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(withRecadosRequestIdentity({ action: pinned ? 'pin' : 'unpin' })),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok || result.ok === false) throw new Error(result.error || 'Falha ao atualizar')
    if (result.ignoredDuePriority) {
      state.status = 'DIRETOR EM PRIORIDADE'
    } else {
      const nextPinned = result?.notice?.pinned === true
      state.pinned = nextPinned
      state.noticeLocalStarted = true
      state.noticeRemainingMs =
        nextPinned ? localRemainingBeforeToggle : 0
      state.noticeLocalDeadlineMs = nextPinned
        ? 0
        : Date.now() + localRemainingBeforeToggle
      state.status = 'RECADO ATIVO'
    }
  } catch (error) {
    state.status = formatRecadosError(error, 'ERRO AO ATUALIZAR')
  } finally {
    state.sending = false
    render(true)
  }
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
  document.querySelector('[data-action="pin"]')?.addEventListener('click', toggleRecadosPin)
  document.querySelector('[data-action="exit"]')?.addEventListener('click', exitRecadosApp)
  document.querySelector('[data-action="edit-template"]')?.addEventListener('click', toggleTemplateEdit)
  document.querySelector('[data-action="choose-image"]')?.addEventListener('click', () => {
    document.getElementById('recadosImageInput')?.click()
  })
  document.querySelector('[data-action="remove-image"]')?.addEventListener('click', removeRecadoImage)
  document.getElementById('recadosImageInput')?.addEventListener('change', chooseRecadoImage)
  document.querySelectorAll('[data-action="select-slot"]').forEach((button) => {
    let holdTimer = 0
    const select = () => selectRecadoSlot(button.getAttribute('data-slot'))
    button.addEventListener('click', select)
    button.addEventListener('pointerdown', () => { holdTimer = window.setTimeout(select, 1000) }, { passive: true })
    const cancelHold = () => { if (holdTimer) window.clearTimeout(holdTimer); holdTimer = 0 }
    button.addEventListener('pointerup', cancelHold, { passive: true })
    button.addEventListener('pointercancel', cancelHold, { passive: true })
    button.addEventListener('pointerleave', cancelHold, { passive: true })
  })
  const recadosTextInput = document.getElementById('recadosTextInput')
  recadosTextInput?.addEventListener('focus', () => {
    state.editorFocused = true
    if (typeof window.setDirectorTabletKeyboardOpen === 'function') window.setDirectorTabletKeyboardOpen(true)
    if (recadosRefreshTimer) window.clearTimeout(recadosRefreshTimer)
    recadosRefreshTimer = 0
  })
  recadosTextInput?.addEventListener('blur', () => {
    state.draft = recadosTextInput.value
    state.editorFocused = false
    if (typeof window.setDirectorTabletKeyboardOpen === 'function') window.setDirectorTabletKeyboardOpen(false)
    window.setTimeout(setRecadosAppHeight, 560)
    window.setTimeout(async () => {
      await refreshRecadosData()
      scheduleRecadosRefresh()
    }, 0)
  })
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

let recadosRefreshTimer = 0
let recadosRefreshRunning = false
let recadosVisualTimer = 0

function setRecadosAppHeight() {
  if (state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
  const height = Math.max(360, Math.floor(window.innerHeight || document.documentElement.clientHeight || 640))
  document.documentElement.style.setProperty('--recados-app-height', `${height}px`)
}

async function refreshRecadosData() {
  if (recadosRefreshRunning || state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
  recadosRefreshRunning = true
  try {
    await pollBridge()
    if (!state.editorFocused && document.activeElement?.id !== 'recadosTextInput') {
      await Promise.all([
        pollTechnicalNotice(),
        pollRecadosTemplates(),
      ])
    }
  } finally {
    recadosRefreshRunning = false
  }
}

function scheduleRecadosVisualRefresh() {
  if (recadosVisualTimer) window.clearTimeout(recadosVisualTimer)
  recadosVisualTimer = window.setTimeout(() => {
    recadosVisualTimer = 0
    if (getViewName() === 'editor') syncEditorDom()
    scheduleRecadosVisualRefresh()
  }, 100)
}

function scheduleRecadosRefresh() {
  if (state.editorFocused || document.activeElement?.id === 'recadosTextInput') return
  if (recadosRefreshTimer) window.clearTimeout(recadosRefreshTimer)
  recadosRefreshTimer = window.setTimeout(async () => {
    await refreshRecadosData()
    scheduleRecadosRefresh()
  }, 1000)
}

function startRecadosApp() {
  if (window.__vshookRecadosAppStarted) return
  window.__vshookRecadosAppStarted = true
  setRecadosAppHeight()
  window.addEventListener('orientationchange', () => window.setTimeout(setRecadosAppHeight, 250), { passive: true })
  render(true)
  refreshRecadosData()
  scheduleRecadosRefresh()
  scheduleRecadosVisualRefresh()
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startRecadosApp, { once: true })
} else {
  startRecadosApp()
}
