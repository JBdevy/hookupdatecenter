const VSHOOK_DIRECTOR_PORT = 47831
const VSHOOK_MUSICIANS_PORT = 47832
const VSHOOK_SCAN_TIMEOUT_MS = 650
const VSHOOK_SAVED_PROBE_TIMEOUT_MS = 650
const VSHOOK_MANUAL_IP_TIMEOUT_MS = 2800
const VSHOOK_BRIDGE_BROWSER_TIMEOUT_MS = 4500
const VSHOOK_SCAN_BATCH_SIZE = 72
const appRoot = document.getElementById('app')
const VSHOOK_ASSET_VERSION = '1-0-1-chat-account-isolation-v69'
const VSHOOK_CHAT_BOOTSTRAP_KEY = 'vshook_chat_bootstrap_key'
const VSHOOK_CHAT_MOBILE_SESSION_KEY = 'vshook_chat_mobile_session'
const VSHOOK_CHAT_NOTIFICATION_TARGET_KEY = 'vshook_chat_notification_target'
const VSHOOK_CHAT_PUSH_TOKEN_KEY = 'vshook_chat_push_token'
const VSHOOK_CHAT_PUSH_MUTED_KEY = 'vshook_chat_push_muted'
const VSHOOK_CHAT_BACKEND_URL = 'https://hookupdate7.up.railway.app'
let vshookDiscoveredProjects = []
let vshookBridgeBrowserMode = false
let vshookDiscoveryController = null
let vshookRestartDiscoveryTimer = 0
let vshookDirectorDeviceMode = 'phone'
let vshookDirectorTabletStableViewport = null
let vshookDirectorTabletViewportRestoreTimer = 0
let vshookDirectorTabletLandscapeContinuation = null
let vshookDirectorAppActive = false
let vshookNativeKeepAwakePlugin = null
let vshookNativeScreenOrientationPlugin = null

// Todas as entradas usam a mesma busca. Sair da tela ou iniciar outra busca
// cancela tanto os resultados pendentes quanto as requisições de rede.
function cancelDiscovery() {
  if (vshookRestartDiscoveryTimer) {
    window.clearTimeout(vshookRestartDiscoveryTimer)
    vshookRestartDiscoveryTimer = 0
  }
  const controller = vshookDiscoveryController
  vshookDiscoveryController = null
  controller?.abort()
}

function beginDiscovery() {
  cancelDiscovery()
  vshookDiscoveryController = new AbortController()
  return vshookDiscoveryController.signal
}

function isCurrentDiscovery(signal) {
  return !signal.aborted && vshookDiscoveryController?.signal === signal
}

window.addEventListener('pagehide', cancelDiscovery)
window.addEventListener('beforeunload', cancelDiscovery)

function captureChatBootstrapKey() {
  try {
    const url = new URL(window.location.href)
    const bootstrapKey = String(url.searchParams.get('chatKey') || '').trim()
    if (/^[a-f0-9]{64}$/i.test(bootstrapKey)) {
      localStorage.setItem(VSHOOK_CHAT_BOOTSTRAP_KEY, bootstrapKey.toLowerCase())
      url.searchParams.delete('chatKey')
      window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`)
    }
  } catch (error) {}
}

function getStoredChatMobileSession() {
  try {
    const session = JSON.parse(localStorage.getItem(VSHOOK_CHAT_MOBILE_SESSION_KEY) || 'null')
    if (!session || !String(session.accessToken || '').startsWith('vshcm_') || !/^https?:\/\//i.test(String(session.backendUrl || ''))) return null
    if (session.expiresAt && Date.parse(session.expiresAt) <= Date.now()) {
      localStorage.removeItem(VSHOOK_CHAT_MOBILE_SESSION_KEY)
      return null
    }
    return session
  } catch (error) {
    return null
  }
}

async function bootstrapChatMobileSessionFromQr() {
  if (getStoredChatMobileSession()) return true
  let bootstrapKey = ''
  try { bootstrapKey = String(localStorage.getItem(VSHOOK_CHAT_BOOTSTRAP_KEY) || '').trim() }
  catch (error) {}
  if (!/^[a-f0-9]{64}$/i.test(bootstrapKey)) return false

  const controller = new AbortController()
  const timer = window.setTimeout(() => controller.abort(), 20000)
  try {
    const response = await fetch(`${window.location.origin}/chat/bootstrap`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ bootstrapKey }),
      cache: 'no-store',
      signal: controller.signal,
    })
    const result = await response.json().catch(() => ({}))
    const created = result?.mobileSession
    if (!response.ok || !created?.accessToken || !created?.backendUrl) return false
    localStorage.setItem(VSHOOK_CHAT_MOBILE_SESSION_KEY, JSON.stringify({
      accessToken: String(created.accessToken),
      backendUrl: String(created.backendUrl).replace(/\/+$/, ''),
      expiresAt: String(created.expiresAt || ''),
      bridgeBaseUrl: String(window.location.origin || '').replace(/\/+$/, ''),
    }))
    try { window.dispatchEvent(new CustomEvent('vshook-chat-session-changed', { detail: created })) } catch (error) {}
    localStorage.removeItem(VSHOOK_CHAT_BOOTSTRAP_KEY)
    return true
  } catch (error) {
    return false
  } finally {
    window.clearTimeout(timer)
  }
}

function hasStoredChatBootstrapKey() {
  try { return /^[a-f0-9]{64}$/i.test(String(localStorage.getItem(VSHOOK_CHAT_BOOTSTRAP_KEY) || '').trim()) }
  catch (error) { return false }
}

function renderStoredChatButton() {
  if (getStoredChatMobileSession()) return '<button class="vshook-mode-button" id="openStoredChatBtn">Abrir Chat Hook pela internet</button>'
  if (hasStoredChatBootstrapKey()) return '<button class="vshook-mode-button" id="openStoredChatBtn">Abrir Chat Hook</button>'
  return '<button class="vshook-mode-button" id="openStoredChatBtn">Entrar no Chat Hook</button>'
}

function enterStoredChat() {
  const session = getStoredChatMobileSession()
  if (!session && !hasStoredChatBootstrapKey()) return false
  if (session) setupNativeChatPushNotifications().catch(() => false)
  const bridgeBaseUrl = String(session?.bridgeBaseUrl || window.location.origin || '').replace(/\/+$/, '')
  enterApp({
    id: 'chat-hook-internet',
    projectName: 'Chat Hook',
    directorUrl: bridgeBaseUrl,
    musiciansUrl: bridgeBaseUrl,
    projectTabIndex: 0,
  }, 'chat', { skipProjectSwitch: true })
  return true
}

function markChatNotificationTarget() {
  try { localStorage.setItem(VSHOOK_CHAT_NOTIFICATION_TARGET_KEY, '1') } catch (error) {}
}

function consumeChatNotificationTarget() {
  try {
    const pending = localStorage.getItem(VSHOOK_CHAT_NOTIFICATION_TARGET_KEY) === '1'
    if (pending) localStorage.removeItem(VSHOOK_CHAT_NOTIFICATION_TARGET_KEY)
    return pending
  } catch (error) {
    return false
  }
}

function openChatFromNativeNotification() {
  markChatNotificationTarget()
  if (getStoredChatMobileSession() && enterStoredChat()) {
    try { localStorage.removeItem(VSHOOK_CHAT_NOTIFICATION_TARGET_KEY) } catch (error) {}
  }
}

let vshookChatPushListenersReady = false
let vshookChatPushTokenRotationRunning = false
let vshookChatPushTokenRotationAttempts = 0

function isChatPushMuted() {
  try { return localStorage.getItem(VSHOOK_CHAT_PUSH_MUTED_KEY) === '1' }
  catch (error) { return false }
}

async function postChatPushUnregister(session, pushToken) {
  if (!session?.accessToken || !session?.backendUrl || !pushToken) return false
  const response = await fetch(`${String(session.backendUrl).replace(/\/+$/, '')}/api/chat/push/unregister`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chatMobileToken: session.accessToken, pushToken }),
    cache: 'no-store',
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok || result.ok === false) throw new Error(result.error || 'Não foi possível silenciar as notificações do Chat Hook.')
  return true
}

async function revokeChatMobileSession(session) {
  if (!session?.accessToken || !session?.backendUrl) return false
  try {
    await fetch(`${String(session.backendUrl).replace(/\/+$/, '')}/api/chat/mobile/logout`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chatMobileToken: session.accessToken }),
      cache: 'no-store',
    })
    return true
  } catch (error) {
    return false
  }
}

async function reportChatPushDiagnostic(session, stage, detail = '') {
  if (!session?.accessToken || !session?.backendUrl) return false
  try {
    await fetch(`${String(session.backendUrl).replace(/\/+$/, '')}/api/chat/push/diagnostic`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chatMobileToken: session.accessToken,
        platform: String(window.Capacitor?.getPlatform?.() || '').toLowerCase(),
        stage: String(stage || '').slice(0, 80),
        detail: String(detail || '').slice(0, 500),
      }),
      cache: 'no-store',
    })
    return true
  } catch (error) {
    return false
  }
}

function publishChatPushStatus(code, message) {
  const status = { code: String(code || ''), message: String(message || '') }
  window.vshookChatPushStatus = status
  try { window.dispatchEvent(new CustomEvent('vshook-chat-push-status', { detail: status })) }
  catch (error) {}
}

async function postChatPushToken(session, pushToken, platform, firebaseProjectId = '') {
  if (!session?.accessToken || !session?.backendUrl || !pushToken) return false
  if (isChatPushMuted()) {
    await postChatPushUnregister(session, pushToken)
    return false
  }
  const response = await fetch(`${String(session.backendUrl).replace(/\/+$/, '')}/api/chat/push/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chatMobileToken: session.accessToken,
      pushToken,
      platform,
      firebaseProjectId: String(firebaseProjectId || '').trim(),
    }),
    cache: 'no-store',
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok || result.ok === false) {
    const error = new Error(result.error || 'Não foi possível ativar as notificações do Chat Hook.')
    error.rotatePushToken = result.rotatePushToken === true
    throw error
  }
  try { localStorage.setItem(VSHOOK_CHAT_PUSH_TOKEN_KEY, pushToken) } catch (error) {}
  vshookChatPushTokenRotationAttempts = 0
  return true
}

async function getNativeFirebaseProjectId(platform) {
  if (platform !== 'android') return ''
  try {
    let nativePlugin = window.Capacitor?.Plugins?.VSHookLocalNetwork || null
    if (!nativePlugin && typeof window.Capacitor?.registerPlugin === 'function') {
      nativePlugin = window.Capacitor.registerPlugin('VSHookLocalNetwork')
    }
    if (typeof nativePlugin?.getFirebaseConfiguration !== 'function') return ''
    const configuration = await nativePlugin.getFirebaseConfiguration()
    return String(configuration?.projectId || '').trim()
  } catch (error) {
    console.warn('Não foi possível identificar o projeto Firebase do aplicativo', error)
    return ''
  }
}

async function rotateNativeChatPushToken(PushNotifications, rejectedToken, platform) {
  if (vshookChatPushTokenRotationRunning || vshookChatPushTokenRotationAttempts >= 2 || !PushNotifications) return false
  vshookChatPushTokenRotationRunning = true
  vshookChatPushTokenRotationAttempts += 1
  try {
    try { localStorage.removeItem(VSHOOK_CHAT_PUSH_TOKEN_KEY) } catch (error) {}
    if (platform === 'android') {
      let nativePlugin = window.Capacitor?.Plugins?.VSHookLocalNetwork || null
      if (!nativePlugin && typeof window.Capacitor?.registerPlugin === 'function') {
        nativePlugin = window.Capacitor.registerPlugin('VSHookLocalNetwork')
      }
      if (typeof nativePlugin?.renewFirebasePushToken !== 'function') {
        throw new Error('Renovação nativa do token Firebase indisponível.')
      }
      const renewed = await nativePlugin.renewFirebasePushToken()
      const newToken = String(renewed?.token || '').trim()
      if (!newToken || newToken === String(rejectedToken || '').trim()) {
        throw new Error('O Firebase não substituiu o token recusado.')
      }
      const currentSession = getStoredChatMobileSession()
      await postChatPushToken(currentSession, newToken, platform, await getNativeFirebaseProjectId(platform))
      return true
    }
    if (typeof PushNotifications.unregister === 'function') {
      await PushNotifications.unregister()
    }
    await PushNotifications.register()
    return true
  } catch (error) {
    console.warn('Não foi possível renovar o token do Chat Hook', error)
    return false
  } finally {
    vshookChatPushTokenRotationRunning = false
  }
}

async function setupNativeChatPushNotifications() {
  if (!isVshookInstalledNativeApp()) return false
  const session = getStoredChatMobileSession()
  if (!session) return false
  if (isChatPushMuted()) {
    publishChatPushStatus('muted', 'Notificações push silenciadas neste aparelho.')
    reportChatPushDiagnostic(session, 'muted').catch(() => false)
    let storedToken = ''
    try { storedToken = String(localStorage.getItem(VSHOOK_CHAT_PUSH_TOKEN_KEY) || '') }
    catch (error) {}
    if (storedToken) await postChatPushUnregister(session, storedToken).catch(() => false)
    return false
  }
  const PushNotifications = window.Capacitor?.Plugins?.PushNotifications
  if (!PushNotifications) {
    publishChatPushStatus('plugin_unavailable', 'Este aplicativo foi compilado sem o módulo de notificações push.')
    reportChatPushDiagnostic(session, 'plugin_unavailable').catch(() => false)
    return false
  }
  const platform = String(window.Capacitor?.getPlatform?.() || '').toLowerCase()

  if (!vshookChatPushListenersReady) {
    vshookChatPushListenersReady = true
    await PushNotifications.addListener('registration', async (token) => {
      const currentSession = getStoredChatMobileSession()
      const receivedToken = String(token?.value || '')
      const firebaseProjectId = await getNativeFirebaseProjectId(platform)
      postChatPushToken(currentSession, receivedToken, platform, firebaseProjectId).catch((error) => {
        if (error?.rotatePushToken === true) rotateNativeChatPushToken(PushNotifications, receivedToken, platform).catch(() => false)
        else {
          publishChatPushStatus('registration_rejected', error?.message || 'O servidor recusou o token de notificação.')
          reportChatPushDiagnostic(currentSession, 'registration_rejected', error?.message || '').catch(() => false)
          console.warn('Não foi possível registrar o token do Chat Hook', error)
        }
      }).then((registered) => {
        if (registered === true) publishChatPushStatus('registered', 'Notificações push ativadas neste aparelho.')
      })
    })
    await PushNotifications.addListener('registrationError', (error) => {
      const currentSession = getStoredChatMobileSession()
      const detail = error?.error || error?.message || JSON.stringify(error || {})
      publishChatPushStatus('registration_error', `Falha ao registrar notificações: ${detail || 'erro desconhecido'}`)
      reportChatPushDiagnostic(currentSession, 'registration_error', detail).catch(() => false)
      console.warn('Chat Hook push registration error', error)
    })
    await PushNotifications.addListener('pushNotificationActionPerformed', () => {
      openChatFromNativeNotification()
    })
  }

  try {
    if (platform === 'android' && typeof PushNotifications.createChannel === 'function') {
      await PushNotifications.createChannel({
        id: 'chat_hook_messages',
        name: 'Mensagens do Chat Hook',
        description: 'Novas mensagens recebidas no Chat Hook',
        importance: 5,
        visibility: 1,
        vibration: true,
        sound: 'default',
      })
    }
    let permission = await PushNotifications.checkPermissions()
    if (permission?.receive !== 'granted') {
      permission = await PushNotifications.requestPermissions()
    }
    if (permission?.receive !== 'granted') {
      const permissionState = String(permission?.receive || 'unknown')
      publishChatPushStatus('permission_denied', 'Notificações desativadas no Android. Ative a permissão nas configurações do aplicativo.')
      reportChatPushDiagnostic(session, 'permission_denied', permissionState).catch(() => false)
      return false
    }
    await PushNotifications.register()
    publishChatPushStatus('register_requested', 'Ativando notificações push...')
    reportChatPushDiagnostic(session, 'register_requested', platform).catch(() => false)
    return true
  } catch (error) {
    publishChatPushStatus('setup_error', `Não foi possível ativar notificações: ${error?.message || 'erro desconhecido'}`)
    reportChatPushDiagnostic(session, 'setup_error', error?.message || '').catch(() => false)
    console.warn('Não foi possível ativar notificações do Chat Hook', error)
    return false
  }
}

window.vshookSetupNativeChatPushNotifications = setupNativeChatPushNotifications
window.vshookIsChatPushMuted = isChatPushMuted
window.vshookSetChatPushMuted = async function (muted) {
  const shouldMute = muted === true
  try {
    if (shouldMute) localStorage.setItem(VSHOOK_CHAT_PUSH_MUTED_KEY, '1')
    else localStorage.removeItem(VSHOOK_CHAT_PUSH_MUTED_KEY)
  } catch (error) {}

  const session = getStoredChatMobileSession()
  let storedToken = ''
  try { storedToken = String(localStorage.getItem(VSHOOK_CHAT_PUSH_TOKEN_KEY) || '') }
  catch (error) {}

  if (shouldMute) {
    if (!session || !storedToken) return { muted: true, synced: true }
    try {
      await postChatPushUnregister(session, storedToken)
      return { muted: true, synced: true }
    } catch (error) {
      return { muted: true, synced: false, error: error.message }
    }
  }

  try {
    const platform = String(window.Capacitor?.getPlatform?.() || '').toLowerCase()
    if (session && storedToken && (platform === 'android' || platform === 'ios')) {
      try {
        await postChatPushToken(session, storedToken, platform, await getNativeFirebaseProjectId(platform))
      } catch (error) {
        if (error?.rotatePushToken !== true) throw error
        const PushNotifications = window.Capacitor?.Plugins?.PushNotifications
        await rotateNativeChatPushToken(PushNotifications, storedToken, platform)
      }
    }
    await setupNativeChatPushNotifications()
    return { muted: false, synced: true }
  } catch (error) {
    return { muted: false, synced: false, error: error.message }
  }
}

window.vshookLogoutChat = async function () {
  const session = getStoredChatMobileSession()
  let storedToken = ''
  try { storedToken = String(localStorage.getItem(VSHOOK_CHAT_PUSH_TOKEN_KEY) || '') } catch (error) {}
  if (session && storedToken) {
    try { await postChatPushUnregister(session, storedToken) } catch (error) {}
  }
  await revokeChatMobileSession(session)
  try {
    localStorage.removeItem(VSHOOK_CHAT_MOBILE_SESSION_KEY)
    localStorage.removeItem(VSHOOK_CHAT_BOOTSTRAP_KEY)
  } catch (error) {}
  try { window.dispatchEvent(new CustomEvent('vshook-chat-session-changed', { detail: null })) } catch (error) {}
  return true
}

window.addEventListener('online', () => {
  setupNativeChatPushNotifications().catch(() => false)
})

function attachStoredChatHandler() {
  document.getElementById('openStoredChatBtn')?.addEventListener('click', () => {
    if (getStoredChatMobileSession() || hasStoredChatBootstrapKey()) enterStoredChat()
    else renderChatLogin()
  })
}

function renderChatLogin() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">Entrar no Chat Hook</h1>
    <p class="vshook-shell-subtitle">Use o mesmo e-mail informado na compra do VS Hook.</p>
    <form id="chatLoginForm" class="vshook-login-form">
      <input id="chatLoginEmail" class="vshook-manual-ip-input" type="email" autocomplete="email" placeholder="E-mail da compra" required />
      <div id="chatLoginStatus" class="vshook-shell-status"></div>
      <button class="vshook-mode-button" type="submit">Entrar</button>
    </form>
    <button class="vshook-back-button" id="chatLoginBackBtn" type="button">Voltar</button>
  `)
  document.getElementById('chatLoginBackBtn')?.addEventListener('click', () => renderModeFirst(vshookDiscoveredProjects))
  document.getElementById('chatLoginForm')?.addEventListener('submit', async (event) => {
    event.preventDefault()
    const email = String(document.getElementById('chatLoginEmail')?.value || '').trim().toLowerCase()
    const status = document.getElementById('chatLoginStatus')
    const button = event.currentTarget.querySelector('button[type="submit"]')
    if (!email) return
    button.disabled = true
    if (status) status.textContent = 'Validando e-mail...'
    try {
      const response = await fetch(`${VSHOOK_CHAT_BACKEND_URL}/api/chat/mobile/session`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, mobileLogin: true }), cache: 'no-store'
      })
      const result = await response.json().catch(() => ({}))
      const created = result?.mobileSession
      if (!response.ok || !created?.accessToken) throw new Error(result?.error || 'E-mail não encontrado ou licença inativa.')
      localStorage.setItem(VSHOOK_CHAT_MOBILE_SESSION_KEY, JSON.stringify({
        accessToken: String(created.accessToken), backendUrl: VSHOOK_CHAT_BACKEND_URL,
        expiresAt: String(created.expiresAt || ''), bridgeBaseUrl: VSHOOK_CHAT_BACKEND_URL
      }))
      try { window.dispatchEvent(new CustomEvent('vshook-chat-session-changed', { detail: created })) } catch (error) {}
      enterStoredChat()
    } catch (error) {
      if (status) status.textContent = error.message || 'Não foi possível entrar no Chat Hook.'
    } finally {
      button.disabled = false
    }
  })
}

function renderStandaloneTransferHookButton() {
  return '<button class="vshook-mode-button" id="openStandaloneTransferHookBtn">Abrir Drop Hook</button>'
}

function enterStandaloneTransferHook() {
  let host = ''
  try { host = normalizeIp(localStorage.getItem('vshook_transfer_host') || '') } catch (_) {}
  if (!host) host = normalizeIp(window.location.hostname)
  if (!host) {
    host = normalizeIp(window.prompt('Digite o IP do computador com a Hook Center aberta:') || '')
  }
  if (!host) return false
  try { localStorage.setItem('vshook_transfer_host', host) } catch (_) {}
  enterApp({
    id: 'transfer-hook-local',
    projectName: 'Drop Hook',
    directorUrl: `http://${host}:${VSHOOK_DIRECTOR_PORT}`,
    musiciansUrl: `http://${host}:${VSHOOK_MUSICIANS_PORT}`,
    projectTabIndex: 0,
  }, 'transfer-hook', { skipProjectSwitch: true })
  return true
}

function attachStandaloneTransferHookHandler() {
  document.getElementById('openStandaloneTransferHookBtn')?.addEventListener('click', enterStandaloneTransferHook)
}

captureChatBootstrapKey()

function normalizeDirectorDeviceMode(value) {
  return String(value || '').toLowerCase() === 'tablet' ? 'tablet' : 'phone'
}

function applyDirectorDeviceMode(value) {
  vshookDirectorDeviceMode = normalizeDirectorDeviceMode(value)
  document.documentElement.dataset.directorDevice = vshookDirectorDeviceMode
  document.body?.classList.toggle('vshook-director-tablet', vshookDirectorDeviceMode === 'tablet')
  try {
    localStorage.setItem('vshook_director_device_mode', vshookDirectorDeviceMode)
  } catch (error) {}
  if (vshookDirectorDeviceMode !== 'tablet') void setDirectorNativeOrientation('phone')
  updateDirectorTabletWebViewport()
  updateDirectorTabletOrientationGuard()
}

function isDirectorTabletLandscape() {
  if (window.matchMedia) return window.matchMedia('(orientation: landscape)').matches
  return Number(window.innerWidth || 0) > Number(window.innerHeight || 0)
}

async function setDirectorNativeOrientation(mode) {
  if (!isVshookInstalledNativeApp()) return false
  try {
    if (!vshookNativeScreenOrientationPlugin) {
      vshookNativeScreenOrientationPlugin = window.Capacitor?.Plugins?.ScreenOrientation || null
      if (!vshookNativeScreenOrientationPlugin && typeof window.Capacitor?.registerPlugin === 'function') {
        vshookNativeScreenOrientationPlugin = window.Capacitor.registerPlugin('ScreenOrientation')
      }
    }
    if (!vshookNativeScreenOrientationPlugin) return false
    if (mode === 'tablet') {
      await vshookNativeScreenOrientationPlugin.lock({ orientation: 'landscape' })
    } else {
      await vshookNativeScreenOrientationPlugin.lock({ orientation: 'portrait' })
    }
    return true
  } catch (error) {
    return false
  }
}

async function waitForDirectorTabletLandscape(timeoutMs = 1600) {
  const deadline = Date.now() + timeoutMs
  while (!isDirectorTabletLandscape() && Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 80))
  }
  return isDirectorTabletLandscape()
}

function continueDirectorTabletAfterRotation() {
  if (!vshookDirectorTabletLandscapeContinuation || !isDirectorTabletLandscape()) return
  const continuation = vshookDirectorTabletLandscapeContinuation
  vshookDirectorTabletLandscapeContinuation = null
  continuation()
}

function renderDirectorTabletOrientationRequired() {
  const nativeApp = isVshookInstalledNativeApp()
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">${nativeApp ? 'Não foi possível girar a tela' : 'Desbloqueie a rotação'}</h1>
    <p class="vshook-shell-subtitle">${nativeApp ? 'Toque abaixo para o VS Hook tentar abrir o modo Tablet na horizontal novamente.' : 'Para usar o modo Tablet no navegador, desbloqueie a rotação do dispositivo e vire a tela para a posição horizontal.'}</p>
    <p class="vshook-shell-status">${nativeApp ? 'O aplicativo gira a tela automaticamente no Android e no iOS.' : 'O VS Hook continua automaticamente assim que detectar a tela horizontal.'}</p>
    <button class="vshook-mode-button" id="retryTabletOrientationBtn">${nativeApp ? 'Tentar novamente' : 'Já desbloqueei'}</button>
    <button class="vshook-back-button" id="backTabletOrientationBtn">Voltar</button>
  `)

  document.getElementById('retryTabletOrientationBtn')?.addEventListener('click', () => {
    if (nativeApp) requireDirectorTabletLandscape(vshookDirectorTabletLandscapeContinuation)
    else continueDirectorTabletAfterRotation()
  })
  document.getElementById('backTabletOrientationBtn')?.addEventListener('click', () => {
    vshookDirectorTabletLandscapeContinuation = null
    applyDirectorDeviceMode('phone')
    renderDirectorDeviceSelection()
  })
}

async function requireDirectorTabletLandscape(continuation) {
  applyDirectorDeviceMode('tablet')
  const pendingContinuation = continuation
  vshookDirectorTabletLandscapeContinuation = pendingContinuation

  if (isVshookInstalledNativeApp()) {
    const locked = await setDirectorNativeOrientation('tablet')
    if (vshookDirectorTabletLandscapeContinuation !== pendingContinuation) return locked
    if (locked) {
      await waitForDirectorTabletLandscape()
      if (vshookDirectorTabletLandscapeContinuation !== pendingContinuation) return true
      vshookDirectorTabletLandscapeContinuation = null
      pendingContinuation?.()
      return true
    }
  }

  if (isDirectorTabletLandscape()) {
    vshookDirectorTabletLandscapeContinuation = null
    pendingContinuation?.()
    return true
  }
  renderDirectorTabletOrientationRequired()
  return false
}

function ensureDirectorTabletOrientationOverlay() {
  let overlay = document.getElementById('vshookTabletOrientationOverlay')
  if (overlay) return overlay
  overlay = document.createElement('div')
  overlay.id = 'vshookTabletOrientationOverlay'
  overlay.className = 'vshook-tablet-orientation-overlay'
  overlay.hidden = true
  overlay.innerHTML = `
    <div class="vshook-tablet-orientation-card" role="status" aria-live="polite">
      ${getLogoHtml()}
      <h1 class="vshook-shell-title">Vire para horizontal</h1>
      <p class="vshook-shell-subtitle">O modo Tablet continua aberto. Desbloqueie a rotação e vire o dispositivo novamente para a posição horizontal.</p>
      <button class="vshook-mode-button" id="retryTabletRuntimeOrientationBtn">Já virei</button>
      <button class="vshook-back-button" id="backTabletRuntimeOrientationBtn">Voltar</button>
    </div>
  `
  document.body.appendChild(overlay)
  document.getElementById('retryTabletRuntimeOrientationBtn')?.addEventListener('click', updateDirectorTabletOrientationGuard)
  document.getElementById('backTabletRuntimeOrientationBtn')?.addEventListener('click', () => {
    vshookDirectorTabletLandscapeContinuation = null
    vshookDirectorAppActive = false
    applyDirectorDeviceMode('phone')
    renderDirectorDeviceSelection()
  })
  return overlay
}

function updateDirectorTabletOrientationGuard() {
  const blocked = vshookDirectorAppActive
    && vshookDirectorDeviceMode === 'tablet'
    && !isVshookInstalledNativeApp()
    && !isDirectorTabletLandscape()
  document.documentElement.classList.toggle('directorTabletOrientationBlocked', blocked)
  const current = document.getElementById('vshookTabletOrientationOverlay')
  if (!blocked && !current) return
  const overlay = current || ensureDirectorTabletOrientationOverlay()
  overlay.hidden = !blocked
}

function updateDirectorTabletWebViewport() {
  const root = document.documentElement
  if (root.classList.contains('directorSearchPortraitMode')
    || root.classList.contains('directorSearchViewportRestoring')
    || root.classList.contains('directorTabletKeyboardOpen')
    || root.classList.contains('directorTabletViewportRestoring')) return
  if (vshookDirectorDeviceMode !== 'tablet') {
    ;['--tablet-screen-width', '--tablet-screen-height', '--tablet-ui-width', '--tablet-ui-height', '--tablet-ui-scale', '--tablet-safe-top', '--tablet-safe-right', '--tablet-safe-bottom', '--tablet-safe-left'].forEach((name) => root.style.removeProperty(name))
    return
  }
  const portrait = window.matchMedia?.('(orientation: portrait)')?.matches
  const visibleWidth = Math.max(1, Math.floor(window.visualViewport?.width || window.innerWidth || 360))
  const visibleHeight = Math.max(1, Math.floor(window.visualViewport?.height || window.innerHeight || 640))
  vshookDirectorTabletStableViewport = { width: visibleWidth, height: visibleHeight, portrait: !!portrait }
  applyDirectorTabletWebViewport(vshookDirectorTabletStableViewport)
}

function applyDirectorTabletWebViewport(viewport) {
  if (!viewport || vshookDirectorDeviceMode !== 'tablet') return
  const root = document.documentElement
  const visibleWidth = Math.max(1, Math.floor(viewport.width || 360))
  const visibleHeight = Math.max(1, Math.floor(viewport.height || 640))
  const portrait = viewport.portrait === true
  const logicalWidth = portrait ? visibleHeight : visibleWidth
  const logicalHeight = portrait ? visibleWidth : visibleHeight
  const scale = Math.max(0.35, Math.min(1, logicalWidth / 900, logicalHeight / 500))
  const safeArea = readDirectorSafeAreaInsets()
  root.style.setProperty('--tablet-screen-width', `${logicalWidth}px`)
  root.style.setProperty('--tablet-screen-height', `${logicalHeight}px`)
  root.style.setProperty('--tablet-ui-width', `${Math.ceil(logicalWidth / scale)}px`)
  root.style.setProperty('--tablet-ui-height', `${Math.ceil(logicalHeight / scale)}px`)
  root.style.setProperty('--tablet-ui-scale', String(scale))
  root.style.setProperty('--tablet-safe-top', `${safeArea.top / scale}px`)
  root.style.setProperty('--tablet-safe-right', `${safeArea.right / scale}px`)
  root.style.setProperty('--tablet-safe-bottom', `${safeArea.bottom / scale}px`)
  root.style.setProperty('--tablet-safe-left', `${safeArea.left / scale}px`)
}

function readDirectorSafeAreaInsets() {
  let probe = document.getElementById('vshookSafeAreaProbe')
  if (!probe) {
    probe = document.createElement('div')
    probe.id = 'vshookSafeAreaProbe'
    probe.setAttribute('aria-hidden', 'true')
    probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;inset:0 auto auto 0;padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)'
    document.body.appendChild(probe)
  }
  const style = window.getComputedStyle(probe)
  return {
    top: Number.parseFloat(style.paddingTop) || 0,
    right: Number.parseFloat(style.paddingRight) || 0,
    bottom: Number.parseFloat(style.paddingBottom) || 0,
    left: Number.parseFloat(style.paddingLeft) || 0,
  }
}

function lockDirectorTabletPageScroll() {
  try { document.documentElement.scrollTop = 0 } catch (error) {}
  try { document.body.scrollTop = 0 } catch (error) {}
  try { window.scrollTo(0, 0) } catch (error) {}
}

function hasDirectorTabletViewportRecovered() {
  if (!vshookDirectorTabletStableViewport) return true
  const stable = vshookDirectorTabletStableViewport
  const portrait = !!(window.matchMedia && window.matchMedia('(orientation: portrait)').matches)
  const viewport = window.visualViewport
  const visibleWidth = Math.max(1, Math.floor((viewport && viewport.width) || window.innerWidth || 360))
  const visibleHeight = Math.max(1, Math.floor((viewport && viewport.height) || window.innerHeight || 640))
  return portrait === stable.portrait
    && visibleWidth >= Math.floor(stable.width * 0.85)
    && visibleHeight >= Math.floor(stable.height * 0.82)
}

function waitForDirectorTabletViewportRestore() {
  const root = document.documentElement
  applyDirectorTabletWebViewport(vshookDirectorTabletStableViewport)
  lockDirectorTabletPageScroll()
  if (hasDirectorTabletViewportRecovered()) {
    vshookDirectorTabletViewportRestoreTimer = 0
    root.classList.remove('directorTabletViewportRestoring')
    updateDirectorTabletWebViewport()
    window.dispatchEvent(new Event('vshooktabletviewportrestored'))
    return
  }
  vshookDirectorTabletViewportRestoreTimer = window.setTimeout(waitForDirectorTabletViewportRestore, 80)
}

function setDirectorTabletKeyboardOpen(open) {
  const root = document.documentElement
  if (vshookDirectorTabletViewportRestoreTimer) {
    window.clearTimeout(vshookDirectorTabletViewportRestoreTimer)
    vshookDirectorTabletViewportRestoreTimer = 0
  }
  if (open) {
    if (vshookDirectorDeviceMode !== 'tablet') return
    if (!vshookDirectorTabletStableViewport) updateDirectorTabletWebViewport()
    root.classList.remove('directorTabletViewportRestoring')
    root.classList.add('directorTabletKeyboardOpen')
    return
  }
  root.classList.remove('directorTabletKeyboardOpen')
  if (vshookDirectorDeviceMode !== 'tablet') {
    root.classList.remove('directorTabletViewportRestoring')
    updateDirectorTabletWebViewport()
    return
  }
  root.classList.add('directorTabletViewportRestoring')
  applyDirectorTabletWebViewport(vshookDirectorTabletStableViewport)
  lockDirectorTabletPageScroll()
  vshookDirectorTabletViewportRestoreTimer = window.setTimeout(waitForDirectorTabletViewportRestore, 80)
}

window.updateDirectorTabletWebViewport = updateDirectorTabletWebViewport
window.setDirectorTabletKeyboardOpen = setDirectorTabletKeyboardOpen

window.addEventListener('resize', updateDirectorTabletWebViewport)
window.visualViewport?.addEventListener?.('resize', updateDirectorTabletWebViewport)
window.addEventListener('resize', continueDirectorTabletAfterRotation)
window.visualViewport?.addEventListener?.('resize', continueDirectorTabletAfterRotation)
window.addEventListener('resize', updateDirectorTabletOrientationGuard)
window.visualViewport?.addEventListener?.('resize', updateDirectorTabletOrientationGuard)
window.addEventListener('orientationchange', () => {
  updateDirectorTabletOrientationGuard()
  window.setTimeout(() => {
    continueDirectorTabletAfterRotation()
    updateDirectorTabletOrientationGuard()
  }, 80)
})

function vshookEscape(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}


function isVSHookFakeProjectName(value) {
  const name = String(value || '').trim().toLowerCase()
  if (!name) return true
  const compact = name.replace(/\s+/g, ' ')
  return compact === 'projeto vs hook'
    || compact === 'vs hook'
    || compact === 'demo'
    || compact === 'projeto demo'
}

function isVSHookRealProject(project) {
  if (!project || typeof project !== 'object') return false
  const name = project.projectName || project.name || project.title || project.label || ''
  if (isVSHookFakeProjectName(name)) return false
  return true
}

function setShell(html, cardClass = '') {
  cancelDiscovery()
  // A escolha de dispositivo/projeto ainda faz parte da entrada. No tablet ela
  // permanece no eixo natural do aparelho; a interface horizontal começa só
  // depois que um projeto é aberto.
  vshookDirectorAppActive = false
  document.documentElement.classList.toggle('directorShellPortraitMode', vshookDirectorDeviceMode === 'tablet')
  updateDirectorTabletOrientationGuard()
  const safeCardClass = String(cardClass || '').replace(/[^a-zA-Z0-9_-]/g, '')
  appRoot.innerHTML = `<div class="vshook-shell"><div class="vshook-shell-card${safeCardClass ? ` ${safeCardClass}` : ''}">${html}</div></div>`
}

function getLogoHtml() {
  return '<img class="vshook-shell-logo" src="./vshook-icon.png" alt="VS Hook" />'
}

function renderManualIpBox() {
  return `
    <div class="vshook-manual-ip-box">
      <input class="vshook-manual-ip-input" id="manualIpInput" inputmode="decimal" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="IP do computador. Ex: 192.168.0.10" />
      <button class="vshook-secondary-button" id="manualIpBtn">Entrar pelo IP</button>
      <button class="vshook-secondary-button vshook-search-button" id="searchAgainBtn">Procurar</button>
    </div>
  `
}

function attachManualIpHandler() {
  document.getElementById('manualIpBtn')?.addEventListener('click', () => attemptManualIpEntry())
  document.getElementById('searchAgainBtn')?.addEventListener('click', () => restartDiscovery())
  document.getElementById('manualIpInput')?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') attemptManualIpEntry()
  })
}

function restartDiscovery() {
  // Invalida imediatamente a execução anterior e descarta apenas resultados
  // temporários. O próximo startDiscovery consulta de novo a rede ativa.
  cancelDiscovery()
  vshookDiscoveredProjects = []
  try { localStorage.removeItem('vshook_cached_mode_projects') } catch (error) {}
  const button = document.getElementById('searchAgainBtn')
  button?.classList.add('is-pressed')
  vshookRestartDiscoveryTimer = window.setTimeout(() => {
    vshookRestartDiscoveryTimer = 0
    startDiscovery()
  }, 120)
}

function renderSearching() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Procurando sessões VS Hook disponíveis na rede Wi‑Fi...</p>
    <div class="vshook-search-spinner" role="status" aria-label="Procurando"></div>
    <p class="vshook-shell-status">Abra o projeto no REAPER. A busca usa o Wi‑Fi atual e continua em segundo plano. Se preferir, digite o IP do computador.</p>
    ${renderStoredChatButton()}
    ${renderStandaloneTransferHookButton()}
    ${renderManualIpBox()}
  `)
  attachStoredChatHandler()
  attachStandaloneTransferHookHandler()
  attachManualIpHandler()
}

function renderNoProjects() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Nenhuma sessão VS Hook foi encontrada.</p>
    <p class="vshook-shell-status">Abra o projeto no REAPER e toque em Procurar. O Drop Hook funciona somente com a Hook Center aberta.</p>
    ${renderStoredChatButton()}
    ${renderStandaloneTransferHookButton()}
    ${renderManualIpBox()}
  `)
  attachStoredChatHandler()
  attachStandaloneTransferHookHandler()
  attachManualIpHandler()
}

function getDefaultMusicianProject(projects) {
  const list = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  if (!list.length) return null
  return list.find((project) => project.active) || list[0]
}

function renderModeFirst(projects) {
  vshookDiscoveredProjects = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Escolha como vai entrar no VS Hook.</p>
    <div class="vshook-mode-list">
      <button class="vshook-mode-button" id="chooseDirectorBtn">Entrar como Diretor</button>
      <button class="vshook-mode-button" id="chooseMusicianBtn">Entrar como Músico</button>
      <button class="vshook-mode-button" id="chooseRecadosBtn">Entrar como Recados</button>
      <button class="vshook-mode-button" id="chooseChatHookBtn">Entrar no Chat Hook</button>
      <button class="vshook-mode-button" id="chooseTransferHookBtn">Entrar no Drop Hook</button>
    </div>
    <div class="vshook-app-version">Versão 1.0.2 app</div>
  `)

  document.getElementById('chooseDirectorBtn')?.addEventListener('click', () => {
    renderDirectorDeviceSelection()
  })

  document.getElementById('chooseMusicianBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'musician', { skipProjectSwitch: true })
  })

  document.getElementById('chooseRecadosBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'recados', { skipProjectSwitch: true })
  })

  document.getElementById('chooseChatHookBtn')?.addEventListener('click', () => {
    if (getStoredChatMobileSession() || hasStoredChatBootstrapKey()) enterStoredChat()
    else renderChatLogin()
  })

  document.getElementById('chooseTransferHookBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'transfer-hook', { skipProjectSwitch: true })
  })

}

function renderDirectorDeviceSelection() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">Modo Diretor</h1>
    <p class="vshook-shell-subtitle">Escolha em qual dispositivo vai usar o Diretor.</p>
    <div class="vshook-device-list">
      <button class="vshook-device-button" id="chooseDirectorPhoneBtn">
        <svg class="vshook-device-icon vshook-device-icon-phone" viewBox="0 0 48 64" aria-hidden="true">
          <rect x="7" y="2" width="34" height="60" rx="7"></rect>
          <path d="M19 8h10"></path>
          <circle cx="24" cy="55" r="2"></circle>
        </svg>
        <span>Celular</span>
      </button>
      <button class="vshook-device-button" id="chooseDirectorTabletBtn">
        <svg class="vshook-device-icon vshook-device-icon-tablet" viewBox="0 0 72 50" aria-hidden="true">
          <rect x="2" y="4" width="68" height="42" rx="6"></rect>
          <circle cx="64" cy="25" r="2"></circle>
        </svg>
        <span>Tablet</span>
      </button>
    </div>
    <button class="vshook-back-button" id="backModeBtn">Voltar</button>
  `)

  document.getElementById('chooseDirectorPhoneBtn')?.addEventListener('click', () => {
    applyDirectorDeviceMode('phone')
    renderProjects(vshookDiscoveredProjects)
  })
  document.getElementById('chooseDirectorTabletBtn')?.addEventListener('click', () => {
    requireDirectorTabletLandscape(() => renderProjects(vshookDiscoveredProjects))
  })
  document.getElementById('backModeBtn')?.addEventListener('click', () => {
    applyDirectorDeviceMode('phone')
    renderModeFirst(vshookDiscoveredProjects)
  })
}


// O "Atualizar" precisa varrer a rede do mesmo jeito que a tela inicial. No app
// instalado a tela inicial monta os candidatos a partir dos IPs locais reais
// (plugin nativo); sem isso o botao varria a faixa generica e nao encontrava o
// projeto aberto no REAPER depois que a tela de sessoes ja estava na frente.
async function buildDiscoveryCandidateIps() {
  if (!isVshookInstalledNativeApp()) return buildCandidateIps()
  const localNetworks = await getVshookStoreLocalNetworks()
  return buildVshookStoreCandidateIps(localNetworks)
}

async function discoverProjectsFromActiveNetwork(signal) {
  if (signal?.aborted) return []
  const ips = await buildDiscoveryCandidateIps()
  if (signal?.aborted) return []
  return scanInBatches(ips, VSHOOK_SCAN_BATCH_SIZE, signal)
}

async function refreshProjectSelector() {
  renderProjects([], { loading: true, status: 'Procurando sessão ativa...' })
  const signal = beginDiscovery()

  let projects = []
  if (vshookBridgeBrowserMode) {
    projects = await fetchBridgeBrowserProjects(signal)
  } else {
    // Repete a mesma descoberta da tela inicial do app instalado. O plugin
    // consulta novamente a interface ativa, portanto uma troca de Wi-Fi entre
    // a entrada e este botão não reaproveita primeiro o endereço da rede velha.
    projects = await discoverProjectsFromActiveNetwork(signal)
  }

  if (!isCurrentDiscovery(signal)) return

  if (projects && projects.length) {
    renderProjects(projects, { status: 'Sessões atualizadas.' })
  } else {
    try {
      localStorage.removeItem('vshook_selected_project')
      localStorage.removeItem('vshook_cached_mode_projects')
    } catch (error) {}
    renderProjects([], { status: 'Abra o projeto no REAPER e verifique se a sessão está disponível.' })
  }
}

function renderProjects(projects, options = {}) {
  const list = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  vshookDiscoveredProjects = list.slice()
  const loading = options && options.loading
  const status = options && options.status
  const rows = list.map((project, index) => {
    const name = vshookEscape(project.projectName || project.name || project.projectPath || '')
    return `<button class="vshook-project-button" data-project-index="${index}">🎼 ${name}</button>`
  }).join('')

  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">Modo Diretor</h1>
    <p class="vshook-shell-subtitle">Selecione a sessão disponível na rede Wi‑Fi.</p>
    <div class="vshook-project-list">${rows || `<div class="vshook-shell-status">Abra o projeto no REAPER e verifique se a sessão está disponível.</div>`}</div>
    ${status ? `<p class="vshook-shell-status">${vshookEscape(status)}</p>` : ''}
    <div class="vshook-project-actions">
      <button class="vshook-back-button" id="backModeBtn">Voltar</button>
      <button class="vshook-secondary-button" id="refreshProjectsBtn" ${loading ? 'disabled' : ''}>${loading ? 'Atualizando...' : 'Atualizar'}</button>
    </div>
  `, 'vshook-project-shell-card')

  document.querySelectorAll('[data-project-index]').forEach((button) => {
    button.addEventListener('click', () => {
      const index = Number(button.getAttribute('data-project-index'))
      const selected = list[index]
      if (!selected) return
      if (vshookDirectorDeviceMode === 'tablet') {
        requireDirectorTabletLandscape(() => enterApp(selected, 'director'))
      } else {
        enterApp(selected, 'director')
      }
    })
  })

  document.getElementById('backModeBtn')?.addEventListener('click', () => {
    applyDirectorDeviceMode('phone')
    renderDirectorDeviceSelection()
  })
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', refreshProjectSelector)
}

function renderModeSelection(project) {
  // Mantido por compatibilidade com versões antigas, mas o fluxo atual escolhe o modo antes do projeto.
  renderModeFirst([project].filter(Boolean))
}

function loadModeStyles(mode) {
  document.querySelectorAll('[data-vshook-mode-style]').forEach((el) => el.remove())
  const cssFile = mode === 'recados'
    ? './recados-app.css'
    : mode === 'chat'
      ? './chat-app.css'
      : mode === 'transfer-hook'
        ? './transfer-hook-app.css'
      : './stylediretor-app.css'
  const link = document.createElement('link')
  link.rel = 'stylesheet'
  link.href = `${cssFile}?v=${VSHOOK_ASSET_VERSION}`
  link.setAttribute('data-vshook-mode-style', mode)
  document.head.appendChild(link)
}

async function enterApp(project, mode, options = {}) {
  cancelDiscovery()
  try {
    localStorage.setItem('vshook_selected_project', JSON.stringify(project))
    localStorage.setItem('vshook_selected_project_tab_index', String(project.projectTabIndex ?? 0))
    localStorage.setItem('vshook_selected_mode', mode)
    localStorage.setItem('vshook_director_url', project.directorUrl)
    localStorage.setItem('vshook_musicians_url', project.musiciansUrl)
  } catch (error) {}

  if (mode === 'director') {
    vshookDirectorAppActive = true
    document.documentElement.classList.remove('directorShellPortraitMode')
    applyDirectorDeviceMode(vshookDirectorDeviceMode)
  } else {
    vshookDirectorAppActive = false
    void setDirectorNativeOrientation('phone')
    document.documentElement.classList.remove('directorShellPortraitMode')
    document.documentElement.removeAttribute('data-director-device')
    document.body?.classList.remove('vshook-director-tablet')
    updateDirectorTabletOrientationGuard()
  }

  const tabIndex = Number(project.projectTabIndex)
  const shouldSwitchProjectTab = mode === 'director' && !options.skipProjectSwitch
  if (shouldSwitchProjectTab && Number.isFinite(tabIndex)) {
    // A troca é processada pelo mesmo motor nativo que abastece o app. Não
    // bloqueia a montagem da interface esperando a resposta de rede.
    void fetch(`${project.directorUrl}/command`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'set_project_tab',
        payload: { projectTabIndex: tabIndex, index: tabIndex },
      }),
    }).catch(() => {})
  }

  appRoot.innerHTML = ''
  loadModeStyles(mode)

  document.querySelectorAll('[data-vshook-mode-script]').forEach((el) => el.remove())
  const script = document.createElement('script')
  const scriptFile = mode === 'recados'
    ? './recados.js'
    : mode === 'chat'
      ? './chat.js'
      : mode === 'transfer-hook'
        ? './transfer-hook.js'
      : './vsdiretor.js'
  script.src = `${scriptFile}?v=${VSHOOK_ASSET_VERSION}`
  script.setAttribute('data-vshook-mode-script', mode)
  document.body.appendChild(script)
}

function timeoutSignal(ms, parentSignal) {
  const controller = new AbortController()
  const abort = () => controller.abort()
  if (parentSignal?.aborted) abort()
  else parentSignal?.addEventListener('abort', abort, { once: true })
  const timer = setTimeout(() => controller.abort(), ms)
  return {
    signal: controller.signal,
    cancel: () => {
      clearTimeout(timer)
      parentSignal?.removeEventListener('abort', abort)
    },
  }
}

function normalizeIp(value) {
  const text = String(value || '').trim()
  const parts = text.split('.').map((part) => Number(part))
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return ''
  // Rede/broadcast dependem da máscara, não apenas do último octeto.
  if (parts[0] === 0 || parts[0] === 127) return ''
  return parts.join('.')
}

function parseBridgeAddress(value) {
  let text = String(value || '').trim()
  if (!text) return { ip: '', port: null }
  text = text.replace(/^https?:\/\//i, '')
  text = text.replace(/\/.*$/, '')
  const match = text.match(/^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$/)
  if (!match) return { ip: '', port: null }
  const ip = normalizeIp(match[1])
  const port = match[2] ? Number(match[2]) : null
  if (!ip) return { ip: '', port: null }
  if (port != null && (!Number.isInteger(port) || port < 1 || port > 65535)) return { ip: '', port: null }
  return { ip, port }
}

async function attemptManualIpEntry() {
  const input = document.getElementById('manualIpInput')
  const parsed = parseBridgeAddress(input?.value || '')
  const ip = parsed.ip
  if (!ip) {
    if (input) input.focus()
    return
  }

  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Conectando no IP informado...</p>
    <p class="vshook-shell-status">${vshookEscape(parsed.port ? `${ip}:${parsed.port}` : ip)}</p>
  `)
  const signal = beginDiscovery()

  const projects = await fetchDiscovery(ip, VSHOOK_MANUAL_IP_TIMEOUT_MS, parsed.port, signal)
  if (!isCurrentDiscovery(signal)) return
  if (projects && projects.length) {
    renderModeFirst(projects)
  } else {
    try { localStorage.setItem('vshook_transfer_host', ip) } catch (_) {}
    renderNoProjects()
    const nextInput = document.getElementById('manualIpInput')
    if (nextInput) {
      nextInput.value = parsed.port ? `${ip}:${parsed.port}` : ip
      nextInput.focus()
    }
  }
}

function hostFromUrl(value) {
  try {
    return normalizeIp(new URL(String(value || '')).hostname)
  } catch (error) {
    return parseBridgeAddress(value).ip
  }
}

function subnetFromIp(ip) {
  const clean = normalizeIp(ip)
  if (!clean) return ''
  const parts = clean.split('.')
  return `${parts[0]}.${parts[1]}.${parts[2]}`
}

function uniquePush(list, seen, value) {
  const text = String(value || '').trim()
  if (!text || seen.has(text)) return
  seen.add(text)
  list.push(text)
}

function getStoredBridgeHosts() {
  const hosts = []
  const seen = new Set()
  try {
    const directorUrl = localStorage.getItem('vshook_director_url')
    const musiciansUrl = localStorage.getItem('vshook_musicians_url')
    uniquePush(hosts, seen, hostFromUrl(directorUrl))
    uniquePush(hosts, seen, hostFromUrl(musiciansUrl))
    const project = JSON.parse(localStorage.getItem('vshook_selected_project') || 'null')
    uniquePush(hosts, seen, hostFromUrl(project?.directorUrl))
    uniquePush(hosts, seen, hostFromUrl(project?.musiciansUrl))
    uniquePush(hosts, seen, hostFromUrl(project?.host))
    uniquePush(hosts, seen, hostFromUrl(project?.lanHost))
  } catch (error) {}
  return hosts
}

async function fetchJsonWithTimeout(url, timeoutMs, signal) {
  if (signal?.aborted) return null
  const t = timeoutSignal(timeoutMs, signal)
  try {
    const response = await fetch(url, {
      cache: 'no-store',
      signal: t.signal,
    })
    if (t.signal.aborted || !response.ok) return null
    const payload = await response.json()
    return t.signal.aborted ? null : payload
  } catch (error) {
    return null
  } finally {
    t.cancel()
  }
}

function getPortsToTry(preferredPort) {
  const ports = []
  const seen = new Set()
  function push(port) {
    const value = Number(port)
    if (!Number.isInteger(value) || value < 1 || value > 65535 || seen.has(value)) return
    seen.add(value)
    ports.push(value)
  }
  push(preferredPort)
  push(VSHOOK_DIRECTOR_PORT)
  push(VSHOOK_MUSICIANS_PORT)
  return ports
}

async function fetchDiscoveryOnPort(ip, port, timeoutMs = VSHOOK_SCAN_TIMEOUT_MS, signal) {
  const cleanIp = normalizeIp(ip)
  if (!cleanIp || signal?.aborted) return null
  const baseUrl = `http://${cleanIp}:${port}`

  const discovery =
    await fetchJsonWithTimeout(`${baseUrl}/discovery`, timeoutMs, signal) ||
    await fetchJsonWithTimeout(`${baseUrl}/discovery.json`, timeoutMs, signal) ||
    null

  const projectsPayload =
    await fetchJsonWithTimeout(`${baseUrl}/projects`, timeoutMs, signal) ||
    await fetchJsonWithTimeout(`${baseUrl}/projects.json`, timeoutMs, signal) ||
    await fetchJsonWithTimeout(`${baseUrl}/state`, timeoutMs, signal) ||
    await fetchJsonWithTimeout(`${baseUrl}/state.json`, timeoutMs, signal) ||
    discovery

  if (signal?.aborted || (!discovery && !projectsPayload)) return null

  const isVsHook =
    discovery?.app === 'VS Hook' ||
    projectsPayload?.app === 'VS Hook' ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('diretor') ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('músicos') ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('musicos')

  const projects = extractProjectList(projectsPayload || discovery, discovery || projectsPayload, cleanIp)
  if (!projects.length) return null
  if (!isVsHook && !projects.some((project) => project.projectName)) return null
  return projects
}

async function fetchDiscovery(ip, timeoutMs = VSHOOK_SCAN_TIMEOUT_MS, preferredPort = null, signal) {
  const cleanIp = normalizeIp(ip)
  if (!cleanIp || signal?.aborted) return null
  for (const port of getPortsToTry(preferredPort)) {
    if (signal?.aborted) return null
    const projects = await fetchDiscoveryOnPort(cleanIp, port, timeoutMs, signal)
    if (projects && projects.length) return projects
  }
  return null
}

async function probeStoredBridgeHosts(signal) {
  const storedHosts = getStoredBridgeHosts()
  for (const ip of storedHosts) {
    if (signal?.aborted) return []
    const projects = await fetchDiscovery(ip, VSHOOK_SAVED_PROBE_TIMEOUT_MS, null, signal)
    if (projects && projects.length) return projects
  }
  return []
}

function normalizeProjectEntry(rawProject, fallbackIndex, baseInfo, ip) {
  const source = rawProject && typeof rawProject === 'object' ? rawProject : { name: rawProject }
  const rawIndex = source.index ?? source.projectTabIndex ?? source.tabIndex ?? source.id ?? fallbackIndex
  const projectTabIndex = Number.isFinite(Number(rawIndex)) ? Number(rawIndex) : fallbackIndex
  const projectName = String(
    source.name ||
    source.projectName ||
    source.title ||
    source.label ||
    baseInfo?.projectName ||
    ''
  ).trim()

  if (!projectName) return null
  if (isVSHookFakeProjectName(projectName)) return null

  return {
    projectName,
    projectId: String(source.id ?? source.projectId ?? source.tabId ?? projectTabIndex),
    projectTabIndex,
    projectPath: source.path || source.projectPath || '',
    active: !!(source.active || source.isCurrent || source.current),
    directorUrl: `http://${ip}:${VSHOOK_DIRECTOR_PORT}`,
    musiciansUrl: `http://${ip}:${VSHOOK_MUSICIANS_PORT}`,
  }
}

function extractProjectList(payload, baseInfo, ip) {
  const candidates = [
    Array.isArray(payload) ? payload : null,
    payload?.projects,
    payload?.projectTabs,
    payload?.openProjects,
    payload?.tabs,
    payload?.reaperProjects,
    payload?.availableProjects,
  ]

  for (const list of candidates) {
    if (!Array.isArray(list) || !list.length) continue
    const normalized = list
      .map((item, index) => normalizeProjectEntry(item, index, baseInfo, ip))
      .filter(Boolean)

    if (normalized.length) return normalized
  }

  const fallback = normalizeProjectEntry({
    name: payload?.projectName || baseInfo?.projectName,
    path: payload?.projectPath || baseInfo?.projectPath,
    active: true,
    index: payload?.activeProjectTabIndex ?? payload?.activeProjectTabId ?? 0,
  }, 0, baseInfo, ip)

  return fallback ? [fallback] : []
}

function buildCandidateIps() {
  const ips = []
  const seenIps = new Set()
  const seenSubnets = new Set()
  const prioritySubnets = []
  const secondarySubnets = []

  const storedHosts = getStoredBridgeHosts()
  for (const host of storedHosts) {
    uniquePush(ips, seenIps, host)
    uniquePush(prioritySubnets, seenSubnets, subnetFromIp(host))
  }

  // Faixas comuns em roteadores. Não fixa IP específico de cliente; o usuário
  // pode entrar manualmente pelo IP enquanto a varredura continua.
  ;[
    '192.168.0', '192.168.1', '192.168.100', '192.168.10', '192.168.15',
    '192.168.2', '192.168.3', '192.168.4', '192.168.5', '192.168.11',
    '192.168.18', '192.168.20', '192.168.25', '192.168.31', '192.168.50',
    '192.168.68', '192.168.86', '192.168.88', '192.168.101', '192.168.102',
    '10.0.0', '10.0.1', '10.1.1', '10.10.0', '172.16.0', '172.16.1'
  ].forEach((subnet) => uniquePush(prioritySubnets, seenSubnets, subnet))

  const common192 = [43, 49, 56, 168, 254]
  common192.forEach((n) => uniquePush(secondarySubnets, seenSubnets, `192.168.${n}`))
  for (let n = 2; n <= 10; n += 1) uniquePush(secondarySubnets, seenSubnets, `10.0.${n}`)
  ;['10.10.10', '10.100.0'].forEach((subnet) => uniquePush(secondarySubnets, seenSubnets, subnet))
  for (let n = 17; n <= 31; n += 1) {
    uniquePush(secondarySubnets, seenSubnets, `172.${n}.0`)
    uniquePush(secondarySubnets, seenSubnets, `172.${n}.1`)
  }

  // Primeiro testa hosts comuns em TODAS as sub-redes; só depois faz a varredura completa.
  const preferredHosts = [1, 2, 10, 11, 15, 20, 30, 50, 80, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 120, 150, 180, 200, 220, 254]
  for (const subnet of prioritySubnets) {
    for (const host of preferredHosts) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of prioritySubnets) {
    for (let host = 1; host <= 254; host += 1) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of secondarySubnets) {
    for (const host of preferredHosts) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of secondarySubnets) {
    for (let host = 1; host <= 254; host += 1) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }

  return ips
}

async function scanInBatches(ips, batchSize = VSHOOK_SCAN_BATCH_SIZE, signal) {
  for (let i = 0; i < ips.length; i += batchSize) {
    if (signal?.aborted) return []
    const batch = ips.slice(i, i + batchSize)
    const firstResult = await new Promise((resolve) => {
      if (!batch.length) {
        resolve(null)
        return
      }
      let pending = batch.length
      let settled = false
      const controller = new AbortController()
      const finish = (result) => {
        if (settled) return
        settled = true
        signal?.removeEventListener('abort', abort)
        controller.abort()
        resolve(result)
      }
      const abort = () => finish(null)
      signal?.addEventListener('abort', abort, { once: true })
      const finishMiss = () => {
        pending -= 1
        if (pending <= 0) finish(null)
      }
      for (const ip of batch) {
        if (settled) break
        fetchDiscovery(ip, VSHOOK_SCAN_TIMEOUT_MS, null, controller.signal).then((result) => {
          if (settled) return
          const items = Array.isArray(result) ? result.filter(Boolean) : (result ? [result] : [])
          if (items.length) {
            finish(items)
            return
          }
          finishMiss()
        }).catch(finishMiss)
      }
    })
    if (firstResult?.length) return firstResult
  }
  return []
}


function isBridgeBrowserMode() {
  try {
    const params = new URLSearchParams(window.location.search || '')
    if (params.get('qr') === '1' || params.get('bridge') === '1') return true
    const protocol = String(window.location.protocol || '').toLowerCase()
    const port = Number(window.location.port || 0)
    const host = String(window.location.hostname || '').toLowerCase()
    if (!protocol.startsWith('http')) return false
    if (host === 'localhost' || host === '127.0.0.1') return false
    return port === VSHOOK_DIRECTOR_PORT || port === VSHOOK_MUSICIANS_PORT
  } catch (error) {
    return false
  }
}

function getBridgeBrowserHost() {
  try {
    return String(window.location.hostname || '').trim()
  } catch (error) {
    return ''
  }
}

async function fetchBridgeBrowserProjects(signal) {
  const host = getBridgeBrowserHost()
  if (!host || signal?.aborted) return []

  const payload =
    await fetchJsonWithTimeout(`${window.location.origin}/projects`, VSHOOK_BRIDGE_BROWSER_TIMEOUT_MS, signal) ||
    await fetchJsonWithTimeout(`${window.location.origin}/discovery`, VSHOOK_BRIDGE_BROWSER_TIMEOUT_MS, signal) ||
    await fetchJsonWithTimeout(`${window.location.origin}/state`, VSHOOK_BRIDGE_BROWSER_TIMEOUT_MS, signal)

  if (!payload || signal?.aborted) return []
  return extractProjectList(payload, payload, host)
}

function renderBridgeNoProjects() {
  vshookDiscoveredProjects = []
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Nenhuma sessão VS Hook foi encontrada.</p>
    <p class="vshook-shell-status">Abra o projeto no REAPER. O Drop Hook funciona somente com a Hook Center aberta.</p>
    ${renderStoredChatButton()}
    ${renderStandaloneTransferHookButton()}
    <button class="vshook-secondary-button" id="refreshProjectsBtn">Atualizar</button>
  `)
  attachStoredChatHandler()
  attachStandaloneTransferHookHandler()
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', startBridgeBrowserMode)
}

async function startBridgeBrowserMode() {
  vshookBridgeBrowserMode = true
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Carregando sessão do Hook Center...</p>
  `)
  const signal = beginDiscovery()
  const projects = await fetchBridgeBrowserProjects(signal)
  if (!isCurrentDiscovery(signal)) return
  if (projects.length) renderModeFirst(projects)
  else renderBridgeNoProjects()
}

async function startDiscovery() {
  renderSearching()
  const signal = beginDiscovery()
  const savedProjects = await probeStoredBridgeHosts(signal)
  if (!isCurrentDiscovery(signal)) return
  if (savedProjects.length) {
    renderModeFirst(savedProjects)
    return
  }
  const projects = await scanInBatches(buildCandidateIps(), VSHOOK_SCAN_BATCH_SIZE, signal)
  if (!isCurrentDiscovery(signal)) return
  if (projects.length) renderModeFirst(projects)
  else renderNoProjects()
}

async function keepScreenAwake() {
  try {
    if (isVshookInstalledNativeApp()) {
      if (!vshookNativeKeepAwakePlugin) {
        vshookNativeKeepAwakePlugin = window.Capacitor?.Plugins?.KeepAwake || null
        if (!vshookNativeKeepAwakePlugin && typeof window.Capacitor?.registerPlugin === 'function') {
          vshookNativeKeepAwakePlugin = window.Capacitor.registerPlugin('KeepAwake')
        }
      }
      if (typeof vshookNativeKeepAwakePlugin?.keepAwake === 'function') {
        await vshookNativeKeepAwakePlugin.keepAwake()
        return
      }
    }
  } catch (error) {}

  try {
    if ('wakeLock' in navigator && (!window.__vshookWakeLock || window.__vshookWakeLock.released)) {
      window.__vshookWakeLock = await navigator.wakeLock.request('screen')
    }
  } catch (error) {}
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    keepScreenAwake()
    if (vshookDirectorDeviceMode === 'tablet') void setDirectorNativeOrientation('tablet')
  }
})


function getVSHookModeSelectionFallbackProjects() {
  const projects = []
  const seen = new Set()
  const addProject = (project) => {
    if (!project || typeof project !== 'object') return
    if (!isVSHookRealProject(project)) return
    const directorUrl = String(project.directorUrl || '').replace(/\/+$/, '')
    const musiciansUrl = String(project.musiciansUrl || '').replace(/\/+$/, '')
    if (!directorUrl && !musiciansUrl) return
    const key = `${directorUrl}|${musiciansUrl}|${project.projectTabIndex ?? ''}|${project.projectName || project.name || ''}`
    if (seen.has(key)) return
    seen.add(key)
    projects.push({ ...project, directorUrl, musiciansUrl })
  }

  try {
    if (Array.isArray(vshookDiscoveredProjects)) vshookDiscoveredProjects.forEach(addProject)
  } catch (error) {}

  // Não reaproveita projeto salvo/cacheado quando o Bridge está fechado.
  // A seleção de projeto só mostra projeto vivo descoberto agora pelo Hook Center/Bridge.
  try {
    localStorage.removeItem('vshook_cached_mode_projects')
  } catch (error) {}

  // Não cria mais projeto fake usando apenas URLs antigas do localStorage.
  // Se não veio projeto real do Hook Center/Lua, a lista fica vazia.

  return projects
}

function prepareVSHookModeSelectionAfterReload() {
  const projects = getVSHookModeSelectionFallbackProjects()
  try {
    localStorage.setItem('vshook_force_mode_selection', '1')
    localStorage.setItem('vshook_cached_mode_projects', JSON.stringify(projects))
  } catch (error) {}
  return projects
}

function consumeVSHookForcedModeSelection() {
  try {
    if (localStorage.getItem('vshook_force_mode_selection') !== '1') return null
    localStorage.removeItem('vshook_force_mode_selection')
    const cached = JSON.parse(localStorage.getItem('vshook_cached_mode_projects') || '[]')
    localStorage.removeItem('vshook_cached_mode_projects')
    return Array.isArray(cached) ? cached : []
  } catch (error) {
    return null
  }
}

window.vshookExitToProjectSelector = function () {
  cancelDiscovery()
  prepareVSHookModeSelectionAfterReload()
  try {
    localStorage.removeItem('vshook_selected_project')
    localStorage.removeItem('vshook_selected_mode')
    // Mantém vshook_access_session para voltar ao Diretor sem pedir a senha novamente.
  } catch (error) {}
  window.location.reload()
}



// Única diferença do app da loja: descoberta automática usando a interface
// de rede informada pelo Android/iOS. Todo o restante vem da Hook Center.
let vshookStoreLocalNetworkPlugin = null

function isVshookInstalledNativeApp() {
  try {
    const capacitor = window.Capacitor
    if (typeof capacitor?.isNativePlatform === 'function') return capacitor.isNativePlatform()
    const platform = typeof capacitor?.getPlatform === 'function'
      ? String(capacitor.getPlatform() || '').toLowerCase()
      : ''
    if (platform === 'android' || platform === 'ios') return true
  } catch (error) {}
  const protocol = String(window.location?.protocol || '').toLowerCase()
  return protocol === 'capacitor:' || protocol === 'ionic:'
}

function isVshookStorePrivateIpv4(value) {
  const ip = normalizeIp(value)
  if (!ip) return false
  const parts = ip.split('.').map(Number)
  if (parts[0] === 10) return true
  if (parts[0] === 192 && parts[1] === 168) return true
  return parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31
}

async function getVshookStoreLocalNetworks() {
  if (!isVshookInstalledNativeApp()) return []
  try {
    if (!vshookStoreLocalNetworkPlugin) {
      vshookStoreLocalNetworkPlugin = window.Capacitor?.Plugins?.VSHookLocalNetwork || null
      if (!vshookStoreLocalNetworkPlugin && typeof window.Capacitor?.registerPlugin === 'function') {
        vshookStoreLocalNetworkPlugin = window.Capacitor.registerPlugin('VSHookLocalNetwork')
      }
    }
    if (!vshookStoreLocalNetworkPlugin) return []
    const result = await vshookStoreLocalNetworkPlugin.getAddresses()
    // Plugins antigos retornavam somente addresses; os novos incluem a máscara.
    const networks = Array.isArray(result?.networks) ? result.networks : result?.addresses
    return normalizeVshookLocalNetworks(networks)
  } catch (error) {
    return []
  }
}

async function getVshookStoreLocalNetworkAddresses() {
  return [...new Set((await getVshookStoreLocalNetworks()).map((network) => network.address))]
}

function vshookIpv4Number(value) {
  return String(value).split('.').reduce((number, part) => number * 256 + Number(part), 0)
}

function vshookNumberIpv4(value) {
  return [24, 16, 8, 0].map((shift) => Math.floor(value / 2 ** shift) % 256).join('.')
}

function normalizeVshookLocalNetworks(networks) {
  const result = []
  const seen = new Set()
  for (const entry of Array.isArray(networks) ? networks : []) {
    const address = normalizeIp(typeof entry === 'string' ? entry : entry?.address)
    const prefixLength = typeof entry === 'string' ? 24 : entry?.prefixLength
    if (!isVshookStorePrivateIpv4(address) || !Number.isInteger(prefixLength) ||
        prefixLength < 1 || prefixLength > 32) continue
    const key = `${address}/${prefixLength}`
    if (seen.has(key)) continue
    seen.add(key)
    result.push({ address, prefixLength })
  }
  return result
}

function buildVshookStoreCandidateIps(localNetworks) {
  const result = []
  const seen = new Set()
  const networks = normalizeVshookLocalNetworks(localNetworks)
  const ownAddresses = new Set(networks.map((network) => network.address))
  const ranges = networks.flatMap(({ address, prefixLength }) => {
    const size = 2 ** (32 - prefixLength)
    // Evita milhões de requisições em redes muito amplas. Nelas usa-se IP manual.
    if (size > 65536) return []
    const start = Math.floor(vshookIpv4Number(address) / size) * size
    return [{ first: start + (prefixLength <= 30 ? 1 : 0),
      last: start + size - 1 - (prefixLength <= 30 ? 1 : 0) }]
  })
  const push = (value) => {
    const ip = normalizeIp(value)
    if (!ip || seen.has(ip) || ownAddresses.has(ip)) return
    const number = vshookIpv4Number(ip)
    if (!ranges.some((range) => number >= range.first && number <= range.last)) return
    seen.add(ip)
    result.push(ip)
  }
  // Histórico só tem prioridade se ainda pertence à rede local atual.
  for (const host of getStoredBridgeHosts()) push(host)
  const preferredHosts = [1, 2, 10, 11, 15, 20, 30, 50, 80, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 120, 150, 180, 200, 220, 254]
  for (const range of ranges) {
    for (let block = Math.floor(range.first / 256) * 256; block <= range.last; block += 256) {
      for (const host of preferredHosts) push(vshookNumberIpv4(block + host))
    }
  }
  for (const range of ranges) {
    for (let host = range.first; host <= range.last; host += 1) push(vshookNumberIpv4(host))
  }
  return result
}

const vshookStoreDefaultDiscovery = startDiscovery
startDiscovery = async function () {
  if (!isVshookInstalledNativeApp()) return vshookStoreDefaultDiscovery()
  renderSearching()
  const signal = beginDiscovery()
  const projects = await discoverProjectsFromActiveNetwork(signal)
  if (!isCurrentDiscovery(signal)) return
  if (projects.length) renderModeFirst(projects)
  else renderNoProjects()
}

window.addEventListener('load', async () => {
  await setDirectorNativeOrientation('phone')
  keepScreenAwake()
  const forcedModeProjects = consumeVSHookForcedModeSelection()
  await bootstrapChatMobileSessionFromQr()
  await setupNativeChatPushNotifications()
  if (forcedModeProjects !== null) {
    renderModeFirst(forcedModeProjects)
    return
  }
  try {
    if ((consumeChatNotificationTarget() || localStorage.getItem('vshook_selected_mode') === 'chat') && getStoredChatMobileSession()) {
      enterStoredChat()
      return
    }
  } catch (error) {}
  if (isBridgeBrowserMode()) startBridgeBrowserMode()
  else startDiscovery()
})
