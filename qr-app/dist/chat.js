(() => {
  const root = document.getElementById('app')
  const selectedProject = (() => {
    try { return JSON.parse(localStorage.getItem('vshook_selected_project') || '{}') }
    catch (_) { return {} }
  })()
  const apiBase = String(selectedProject.directorUrl || selectedProject.musiciansUrl || window.location.origin).replace(/\/+$/, '')
  const mobileSessionStorageKey = 'vshook_chat_mobile_session'
  const bootstrapKeyStorageKey = 'vshook_chat_bootstrap_key'
  const messages = new Map()
  let chatState = null
  let chatSessionRevision = 0
  let lastMessageId = 0
  let revision = 0
  let polling = false
  let sending = false
  let selectedMedia = null
  let voiceRecorder = null
  let voiceTimer = 0
  let voiceFinishing = false
  let replyingToMessageId = 0
  let editingMessageId = 0
  let actionMessageId = 0
  let messageHoldTimer = 0
  let messageHoldStart = null
  let suppressMessageClickUntil = 0
  let pollTimer = 0
  let mobileSession = readMobileSession()

  function readMobileSession() {
    try {
      const session = JSON.parse(localStorage.getItem(mobileSessionStorageKey) || 'null')
      if (!session || !String(session.accessToken || '').startsWith('vshcm_') || !/^https?:\/\//i.test(String(session.backendUrl || ''))) return null
      if (session.expiresAt && Date.parse(session.expiresAt) <= Date.now()) {
        localStorage.removeItem(mobileSessionStorageKey)
        return null
      }
      return session
    } catch (_) {
      return null
    }
  }

  function saveMobileSession(value) {
    mobileSession = value
    try { localStorage.setItem(mobileSessionStorageKey, JSON.stringify(value)) } catch (_) {}
  }

  function clearMobileSession() {
    mobileSession = null
    try { localStorage.removeItem(mobileSessionStorageKey) } catch (_) {}
  }

  function resetChatForCurrentSession() {
    chatSessionRevision += 1
    mobileSession = readMobileSession()
    chatState = null
    messages.clear()
    lastMessageId = 0
    revision = 0
    renderMessages(true)
    updateHeaderAndControls()
  }

  window.addEventListener('vshook-chat-session-changed', resetChatForCurrentSession)

  function escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
  }

  function initials(name) {
    const parts = String(name || 'User').trim().split(/\s+/).filter(Boolean)
    return (parts.length > 1 ? `${parts[0][0]}${parts[parts.length - 1][0]}` : parts[0]?.slice(0, 2) || 'U').toUpperCase()
  }

  function avatarHtml(name, url) {
    return url
      ? `<img src="${escapeHtml(url)}" alt="" />`
      : `<span>${escapeHtml(initials(name))}</span>`
  }

  function formatTime(value) {
    const date = new Date(value || '')
    if (!Number.isFinite(date.getTime())) return ''
    return date.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
  }

  function formatAudioTime(value) {
    const seconds = Math.max(0, Number(value) || 0)
    return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`
  }

  function initializeAudioPlayers(container) {
    container?.querySelectorAll('.chatMobileMessageAudio').forEach((player) => {
      const audio = player.querySelector('audio')
      const toggle = player.querySelector('[data-audio-action="toggle"]')
      const seek = player.querySelector('[data-audio-seek]')
      const current = player.querySelector('[data-audio-current]')
      const duration = player.querySelector('[data-audio-duration]')
      if (!audio || !toggle || !seek || !current || !duration) return
      let animationFrame = 0
      const sync = () => {
        const total = Number.isFinite(audio.duration) ? audio.duration : 0
        const elapsed = Number.isFinite(audio.currentTime) ? audio.currentTime : 0
        const progress = total > 0 ? Math.min(100, (elapsed / total) * 100) : 0
        toggle.textContent = audio.paused ? '▶' : '❚❚'
        toggle.setAttribute('aria-label', audio.paused ? 'Reproduzir áudio' : 'Pausar áudio')
        seek.value = String(progress)
        seek.style.setProperty('--audio-progress', `${progress}%`)
        current.textContent = formatAudioTime(elapsed)
        duration.textContent = formatAudioTime(total)
      }
      const stopSmoothSync = () => {
        if (animationFrame) cancelAnimationFrame(animationFrame)
        animationFrame = 0
        sync()
      }
      const smoothSync = () => {
        sync()
        if (!audio.paused && !audio.ended && audio.isConnected) animationFrame = requestAnimationFrame(smoothSync)
        else animationFrame = 0
      }
      audio.addEventListener('play', () => {
        if (!animationFrame) animationFrame = requestAnimationFrame(smoothSync)
        sync()
      })
      ;['loadedmetadata', 'durationchange', 'timeupdate'].forEach((type) => audio.addEventListener(type, sync))
      ;['pause', 'emptied'].forEach((type) => audio.addEventListener(type, stopSmoothSync))
      audio.addEventListener('ended', () => {
        audio.currentTime = 0
        stopSmoothSync()
      })
      seek.addEventListener('input', () => {
        if (Number.isFinite(audio.duration) && audio.duration > 0) audio.currentTime = (Number(seek.value) / 100) * audio.duration
        sync()
      })
      sync()
    })
  }

  function messagePreview(message) {
    const text = String(message?.text || '').replace(/\s+/g, ' ').trim()
    if (text) return text.slice(0, 120)
    if (message?.hasImage || message?.imageUrl) return '📷 Imagem'
    if (message?.hasAudio || message?.audioUrl) return '🎵 Áudio'
    if (message?.hasVideo || message?.videoUrl) return '🎬 Vídeo'
    return 'Mensagem'
  }

  function messagePermissions(message) {
    const ready = Boolean(message) && !message.pending && !message.failed && Number(message.id || 0) > 0
    const userId = Number(chatState?.user?.id || 0)
    const isAdmin = chatState?.user?.isAdmin === true
    const own = ready && userId > 0 && Number(message?.customerId || 0) === userId
    const hasAudio = Boolean(message?.hasAudio || message?.audioUrl)
    return {
      reply: ready,
      edit: ready && !hasAudio && (isAdmin || own),
      delete: ready && (isAdmin || own),
      pin: ready && !hasAudio && isAdmin && own && Boolean(String(message?.text || '').trim())
    }
  }

  async function requestJson(url, payload = {}) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 20000)
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        cache: 'no-store',
        signal: controller.signal,
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok || data?.ok === false) {
        const error = new Error(data?.error || `HTTP ${response.status}`)
        error.status = response.status
        error.retryAfter = Number(data?.retryAfter) || 0
        throw error
      }
      return data
    } finally {
      clearTimeout(timer)
    }
  }

  async function ensureMobileSession() {
    // A sessão persistida é a fonte de verdade. Uma troca de conta não pode
    // continuar usando o token antigo que ficou nesta variável em memória.
    const stored = readMobileSession()
    if (stored) {
      mobileSession = stored
      return stored
    }
    mobileSession = null
    const bootstrapKey = (() => {
      try { return String(localStorage.getItem(bootstrapKeyStorageKey) || '').trim() }
      catch (_) { return '' }
    })()
    if (!bootstrapKey) throw new Error('Não foi possível identificar o usuário. Volte e escaneie o QR Code da Hook Center novamente.')
    let result
    try {
      result = await requestJson(`${apiBase}/chat/bootstrap`, { bootstrapKey })
    } catch (error) {
      if (error.name === 'AbortError' || !Number(error.status)) {
        throw new Error('Não foi possível identificar o usuário. Abra a Hook Center e escaneie o QR Code novamente.')
      }
      throw error
    }
    const created = result?.mobileSession
    if (!created?.accessToken || !created?.backendUrl) throw new Error('A Hook Center não conseguiu identificar o usuário deste celular.')
    const session = {
      accessToken: String(created.accessToken),
      backendUrl: String(created.backendUrl).replace(/\/+$/, ''),
      expiresAt: String(created.expiresAt || ''),
      bridgeBaseUrl: apiBase,
    }
    saveMobileSession(session)
    try { localStorage.removeItem(bootstrapKeyStorageKey) } catch (_) {}
    return session
  }

  async function post(pathname, payload = {}, retry = true) {
    const session = await ensureMobileSession()
    try {
      return await requestJson(`${session.backendUrl}/api${pathname}`, {
        ...payload,
        chatMobileToken: session.accessToken,
      })
    } catch (error) {
      if (retry && Number(error.status) === 401) {
        clearMobileSession()
        return post(pathname, payload, false)
      }
      throw error
    }
  }

  function buildInterface() {
    root.innerHTML = `
      <main class="chatMobileShell">
        <header class="chatMobileHeader">
          <button id="chatMobileBack" class="chatMobileBack" type="button" aria-label="Voltar">‹</button>
          <button id="chatMobileCurrentAvatar" class="chatMobileAvatar chatMobileCurrentAvatar" type="button" aria-label="Alterar foto do perfil">H</button>
          <div class="chatMobileHeading">
            <h1>Chat Hook</h1>
            <span id="chatMobileConnection">Conectando...</span>
          </div>
          <div class="chatMobileHeaderActions">
            <button id="chatMobileAdminMenu" class="chatMobileHeaderButton" type="button" aria-label="Configurar chat" hidden>☰</button>
            <button id="chatMobileAvatarButton" class="chatMobileHeaderButton" type="button" hidden>Foto</button>
          </div>
        </header>
        <div id="chatMobileAvatarMenu" class="chatMobileCameraMenu chatMobileProfileMenu" hidden>
          <label class="chatMobileCameraMenuAction" data-avatar-action="change">
            Alterar foto
            <input id="chatMobileAvatarInput" class="chatMobileNativeFileInput" type="file" accept="image/*" />
          </label>
          <button id="chatMobileRemoveAvatar" type="button" data-avatar-action="remove">Remover foto</button>
        </div>

        <section id="chatMobilePinned" class="chatMobilePinned" hidden>
          <div><strong>📌 Mensagem fixada</strong><button id="chatMobileUnpin" type="button" hidden>Desafixar</button></div>
          <p id="chatMobilePinnedText"></p>
        </section>

        <section id="chatMobileMessages" class="chatMobileMessages" aria-live="polite">
          <div class="chatMobileEmpty">Carregando conversa...</div>
        </section>

        <div id="chatMobileClosedNotice" class="chatMobileClosedNotice" hidden>Chat fechado pelo administrador</div>
        <section id="chatMobileComposer" class="chatMobileComposer">
          <div id="chatMobileReplyPreview" class="chatMobileReplyPreview" hidden>
            <div><strong>Respondendo a <span id="chatMobileReplyName"></span></strong><p id="chatMobileReplyText"></p></div>
            <button id="chatMobileCancelReply" type="button" aria-label="Cancelar resposta">×</button>
          </div>
          <div id="chatMobilePreview" class="chatMobilePreview" hidden>
            <img id="chatMobilePreviewImage" alt="Imagem escolhida" />
            <button id="chatMobileRemoveImage" type="button" aria-label="Remover mídia">×</button>
          </div>
          <textarea id="chatMobileInput" rows="2" maxlength="1000" placeholder="Escreva uma mensagem..."></textarea>
          <emoji-picker id="chatMobileEmojiPicker" class="chatMobileEmojiPicker dark" locale="pt" emoji-version="17.0" data-source="https://cdn.jsdelivr.net/npm/emoji-picker-element-data@^1/pt/cldr/data.json" hidden></emoji-picker>
          <div class="chatMobileActions">
            <button id="chatMobileGallery" class="chatMobileIconButton" type="button" aria-label="Adicionar foto">📎</button>
            <input id="chatMobileGalleryInput" type="file" accept="image/*" hidden />
            <span id="chatMobileQuota"></span>
            <button id="chatMobileSend" class="chatMobileSend" type="button">Enviar</button>
          </div>
          <div id="chatMobileStatus" class="chatMobileStatus"></div>
        </section>
        <div id="chatMobileAdminModal" class="chatMobileAdminBackdrop" hidden>
          <section class="chatMobileAdminModal">
            <h2>Configurar Chat Hook</h2>
            <label><span>Permitir mensagens</span><input id="chatMobileAdminOpen" type="checkbox" /></label>
            <label><span>Mensagens por dia</span><input id="chatMobileAdminLimit" type="number" min="1" max="10000" /></label>
            <label><span>Ilimitado</span><input id="chatMobileAdminUnlimited" type="checkbox" /></label>
            <label><span>Limpar depois de quantos dias</span><input id="chatMobileAdminRetention" type="number" min="1" max="30" /></label>
            <div id="chatMobileAdminStatus" class="chatMobileStatus"></div>
            <div class="chatMobileAdminActions"><button id="chatMobileAdminClear" type="button">Limpar chat</button><button id="chatMobileAdminClose" type="button">Cancelar</button><button id="chatMobileAdminSave" type="button">Salvar</button></div>
          </section>
        </div>
        <div id="chatMobileMessageActions" class="chatMobileAdminBackdrop" hidden>
          <section class="chatMobileMessageActionModal">
            <h2 id="chatMobileMessageActionTitle">Opções da mensagem</h2>
            <div class="chatMobileMessageActionPreview"><strong id="chatMobileMessageActionName"></strong><p id="chatMobileMessageActionText"></p></div>
            <div id="chatMobileMessageActionButtons" class="chatMobileMessageActionButtons">
              <button type="button" data-message-action="reply">Responder</button>
              <button type="button" data-message-action="edit">Editar mensagem</button>
              <button type="button" data-message-action="pin">Fixar mensagem</button>
              <button class="danger" type="button" data-message-action="delete">Apagar mensagem</button>
            </div>
            <div id="chatMobileDeleteConfirmButtons" class="chatMobileMessageActionButtons" hidden>
              <button type="button" data-message-action="cancel-delete">Voltar</button>
              <button class="danger" type="button" data-message-action="confirm-delete">Apagar para todos</button>
            </div>
            <button id="chatMobileMessageActionCancel" class="chatMobileMessageActionCancel" type="button">Cancelar</button>
          </section>
        </div>
        <div id="chatMobileEditModal" class="chatMobileAdminBackdrop" hidden>
          <section class="chatMobileEditModal">
            <h2>Editar mensagem</h2>
            <textarea id="chatMobileEditInput" rows="6" maxlength="1000" placeholder="Digite o novo texto da mensagem..."></textarea>
            <div id="chatMobileEditStatus" class="chatMobileStatus"></div>
            <div class="chatMobileEditActions"><button id="chatMobileEditCancel" type="button">Cancelar</button><button id="chatMobileEditSave" type="button">Salvar edição</button></div>
          </section>
        </div>
      </main>`

    ensureEmojiPicker()
    bindEvents()
  }

  function ensureEmojiPicker() {
    if (document.querySelector('script[data-chat-emoji-module]')) return
    const script = document.createElement('script')
    script.type = 'module'
    script.src = 'https://cdn.jsdelivr.net/npm/emoji-picker-element@1.29.1/index.js'
    script.dataset.chatEmojiModule = '1'
    document.head.appendChild(script)
  }

  function renderMessages(forceBottom = false) {
    const container = document.getElementById('chatMobileMessages')
    if (!container) return
    const wasNearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 90
    const list = [...messages.values()].sort((a, b) => Number(a.id || 0) - Number(b.id || 0))
    if (!list.length) {
      container.innerHTML = '<div class="chatMobileEmpty">Nenhuma mensagem ainda. Comece a conversa.</div>'
      return
    }
    container.innerHTML = list.map((message) => {
      const name = escapeHtml(message.name || 'User')
      const text = escapeHtml(message.text || '').replace(/\n/g, '<br>')
      const currentUser = chatState?.user
      const sameCustomer = Number(message.customerId || 0) > 0
        && Number(message.customerId || 0) === Number(currentUser?.id || 0)
      const sameAdminIdentity = currentUser?.isAdmin === true && message.isAdmin === true
      const messageAvatarUrl = sameCustomer || sameAdminIdentity
        ? String(currentUser?.avatarUrl || '')
        : String(message.avatarUrl || '')
      const permissions = messagePermissions(message)
      const reply = message.replyTo
        ? `<button class="chatMobileReplyQuote" type="button" data-jump-message="${Number(message.replyTo.id || 0)}"><strong>${escapeHtml(message.replyTo.name || 'Usuário')}</strong><span>${escapeHtml(messagePreview(message.replyTo))}</span></button>`
        : ''
      const uploadBadge = message.pending
        ? '<span class="chatMobileUploadSpinner"></span>'
        : message.failed
          ? '<span class="chatMobileUploadFailed">!</span>'
          : ''
      const image = message.imageUrl
        ? `<button class="chatMobileMessageImage${message.pending ? ' uploading' : ''}" type="button" ${message.pending ? 'disabled' : `data-open-image="${escapeHtml(message.imageUrl)}"`}><img src="${escapeHtml(message.imageUrl)}" alt="Imagem de ${name}" />${uploadBadge}</button>`
        : ''
      const hasAudio = Boolean(message.audioUrl)
      const audio = hasAudio
        ? `<div class="chatMobileMessageAudio${message.pending ? ' uploading' : ''}">
            <audio src="${escapeHtml(message.audioUrl)}" preload="metadata"></audio>
            <button class="chatMobileAudioPlay" type="button" data-audio-action="toggle" aria-label="Reproduzir áudio">▶</button>
            <div class="chatMobileAudioTrack"><strong>Mensagem de voz</strong><input type="range" min="0" max="100" step="0.1" value="0" data-audio-seek aria-label="Posição do áudio" /><div class="chatMobileAudioTime"><span data-audio-current>0:00</span><span data-audio-duration>0:00</span></div></div>
            ${uploadBadge}
          </div>`
        : ''
      const video = message.videoUrl
        ? `<div class="chatMobileMessageVideo${message.pending ? ' uploading' : ''}"><video src="${escapeHtml(message.videoUrl)}" controls playsinline preload="metadata" ${message.pending ? 'muted' : ''}></video>${uploadBadge}</div>`
        : ''
      return `
        <article class="chatMobileMessage ${message.isAdmin ? 'admin' : 'user'}${permissions.reply ? ' actionable' : ''}${hasAudio ? ' audioMessage' : ''}" data-chat-message-id="${Number(message.id || 0)}">
          ${messageAvatarUrl
            ? `<button class="chatMobileAvatar" type="button" data-open-image="${escapeHtml(messageAvatarUrl)}" aria-label="Abrir foto de ${name}">${avatarHtml(message.name, messageAvatarUrl)}</button>`
            : `<div class="chatMobileAvatar">${avatarHtml(message.name, '')}</div>`}
          <div class="chatMobileBubble">
            <div class="chatMobileMessageHead">
              <strong>${name}</strong>
              ${message.isAdmin ? '<span>ADMIN</span>' : ''}
              <time>${escapeHtml(formatTime(message.createdAt))}</time>
              ${message.editedAt ? '<small class="chatMobileEdited">editada</small>' : ''}
            </div>
            ${reply}
            ${text ? `<p>${text}</p>` : ''}
            ${image}
            ${audio}
            ${video}
          </div>
        </article>`
    }).join('')
    initializeAudioPlayers(container)
    if (forceBottom || wasNearBottom) container.scrollTop = container.scrollHeight
  }

  function updateHeaderAndControls() {
    const user = chatState?.user || {}
    const settings = chatState?.chat || {}
    const limits = chatState?.limits || {}
    const avatar = document.getElementById('chatMobileCurrentAvatar')
    if (avatar) {
      avatar.innerHTML = avatarHtml(user.name || 'Hook', user.avatarUrl || '')
      avatar.disabled = !user.id
    }
    const connection = document.getElementById('chatMobileConnection')
    const onlineCount = Math.max(0, Number(chatState?.presence?.onlineCount || 0))
    if (connection) connection.textContent = `${settings.open === false ? 'Somente administradores' : 'Ao vivo'} · ${onlineCount} online`

    const pinnedText = String(settings.pinnedMessage || '').trim()
    const pinned = document.getElementById('chatMobilePinned')
    if (pinned) pinned.hidden = !pinnedText
    const pinnedOutput = document.getElementById('chatMobilePinnedText')
    if (pinnedOutput) pinnedOutput.textContent = pinnedText
    const unpin = document.getElementById('chatMobileUnpin')
    if (unpin) unpin.hidden = !pinnedText || user.isAdmin !== true

    const exhausted = user.id && !user.isAdmin && limits.unlimited !== true && Number(limits.remainingToday || 0) <= 0
    const closed = settings.open === false && !user.isAdmin
    const enabled = Boolean(user.id) && !exhausted && !closed && !sending
    const recordingVoice = voiceRecorder?.active === true
    const input = document.getElementById('chatMobileInput')
    const send = document.getElementById('chatMobileSend')
    if (input) {
      input.disabled = !enabled || recordingVoice
      input.placeholder = closed ? 'O chat está fechado' : exhausted ? 'Limite diário atingido' : 'Escreva uma mensagem...'
    }
    if (send) send.disabled = !enabled || recordingVoice
    const composer = document.getElementById('chatMobileComposer')
    const closedNotice = document.getElementById('chatMobileClosedNotice')
    if (composer) composer.hidden = closed
    if (closedNotice) closedNotice.hidden = !closed
    ;['chatMobileEmoji', 'chatMobileGallery', 'chatMobileCamera'].forEach((id) => {
      const button = document.getElementById(id)
      if (button) button.disabled = !enabled || (recordingVoice && id !== 'chatMobileAudio') || voiceFinishing
    })
    if (composer) composer.classList.toggle('recordingVoice', recordingVoice || voiceFinishing)
    const quota = document.getElementById('chatMobileQuota')
    if (quota) quota.textContent = user.isAdmin ? 'Administrador' : user.id ? (limits.unlimited === true ? `${Number(limits.usedToday || 0)} hoje • ilimitado` : `${Number(limits.usedToday || 0)}/${Number(limits.dailyLimit || 10)} hoje`) : '--'
    const adminMenu = document.getElementById('chatMobileAdminMenu')
    const avatarButton = document.getElementById('chatMobileAvatarButton')
    if (adminMenu) adminMenu.hidden = user.isAdmin !== true
    if (avatarButton) avatarButton.hidden = !user.id
    const removeAvatar = document.getElementById('chatMobileRemoveAvatar')
    if (removeAvatar) removeAvatar.hidden = !user.avatarUrl
  }

  function applyState(next, full = false) {
    if (!next?.ok) return
    const avatarChanged = String(chatState?.user?.avatarUrl || '') !== String(next.user?.avatarUrl || '')
    if (full) {
      messages.clear()
      lastMessageId = 0
    }
    chatState = next
    revision = Math.max(0, Number(next.chat?.revision || 0))
    let changed = full || avatarChanged
    for (const message of next.messages || []) {
      const id = Number(message.id || 0)
      if (!id) continue
      if (!messages.has(id)) changed = true
      messages.set(id, message)
      lastMessageId = Math.max(lastMessageId, id)
    }
    if (changed) renderMessages(full)
    if (replyingToMessageId && !messages.has(replyingToMessageId)) clearReplyToMessage()
    updateHeaderAndControls()
    const status = document.getElementById('chatMobileStatus')
    if (status?.dataset.connection === '1') {
      status.textContent = ''
      delete status.dataset.connection
    }
  }

  async function refresh(full = false) {
    if (polling || document.visibilityState === 'hidden') return
    const sessionRevision = chatSessionRevision
    polling = true
    try {
      const result = await post('/chat/state', { afterId: full ? 0 : lastMessageId })
      if (sessionRevision !== chatSessionRevision) return
      const serverRevision = Math.max(0, Number(result?.chat?.revision || 0))
      if (!full && revision && serverRevision !== revision) {
        polling = false
        await refresh(true)
        return
      }
      applyState(result, full || !chatState)
    } catch (error) {
      if (sessionRevision !== chatSessionRevision) return
      const status = document.getElementById('chatMobileStatus')
      if (status) {
        status.dataset.connection = '1'
        status.textContent = error.name === 'AbortError' ? 'A conexão demorou para responder.' : error.message
      }
      const connection = document.getElementById('chatMobileConnection')
      if (connection) connection.textContent = 'Desconectado'
    } finally {
      polling = false
    }
  }

  function fileAsDataUrl(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result || ''))
      reader.onerror = () => reject(new Error('Não foi possível ler a imagem.'))
      reader.readAsDataURL(file)
    })
  }

  function loadImage(url) {
    return new Promise((resolve, reject) => {
      const image = new Image()
      image.onload = () => resolve(image)
      image.onerror = () => reject(new Error('Não foi possível preparar essa imagem.'))
      image.src = url
    })
  }

  async function prepareImage(file, maxBytes = 6 * 1024 * 1024) {
    if (!file || !String(file.type || '').startsWith('image/')) throw new Error('Escolha uma imagem válida.')
    if (file.type === 'image/gif' && file.size <= maxBytes) {
      const dataUrl = await fileAsDataUrl(file)
      return { kind: 'image', dataUrl, mimeType: 'image/gif', base64: dataUrl.split(',')[1] || '' }
    }
    const sourceUrl = URL.createObjectURL(file)
    try {
      const image = await loadImage(sourceUrl)
      let width = image.naturalWidth || image.width
      let height = image.naturalHeight || image.height
      const maxSide = 1920
      const scale = Math.min(1, maxSide / Math.max(width, height))
      width = Math.max(1, Math.round(width * scale))
      height = Math.max(1, Math.round(height * scale))
      const canvas = document.createElement('canvas')
      canvas.width = width
      canvas.height = height
      const context = canvas.getContext('2d', { alpha: false })
      context.fillStyle = '#ffffff'
      context.fillRect(0, 0, width, height)
      context.drawImage(image, 0, 0, width, height)
      let quality = .88
      let dataUrl = canvas.toDataURL('image/jpeg', quality)
      while ((dataUrl.length * .75) > maxBytes * .95 && quality > .36) {
        quality -= .1
        dataUrl = canvas.toDataURL('image/jpeg', quality)
      }
      if ((dataUrl.length * .75) > maxBytes) throw new Error('A imagem ficou grande demais para enviar.')
      return { kind: 'image', dataUrl, mimeType: 'image/jpeg', base64: dataUrl.split(',')[1] || '' }
    } finally {
      URL.revokeObjectURL(sourceUrl)
    }
  }

  async function chooseMedia(file) {
    const status = document.getElementById('chatMobileStatus')
    try {
      if (status) status.textContent = ''
      selectedMedia = await prepareImage(file)
      const imagePreview = document.getElementById('chatMobilePreviewImage')
      const audioPreview = document.getElementById('chatMobilePreviewAudio')
      if (selectedMedia.kind === 'audio') {
        if (imagePreview) imagePreview.hidden = true
        if (audioPreview) {
          audioPreview.src = selectedMedia.dataUrl
          audioPreview.hidden = false
        }
      } else {
        if (imagePreview) {
          imagePreview.src = selectedMedia.dataUrl
          imagePreview.hidden = false
        }
        if (audioPreview) audioPreview.hidden = true
      }
      const box = document.getElementById('chatMobilePreview')
      if (box) {
        box.classList.toggle('audio', selectedMedia.kind === 'audio')
        box.hidden = false
      }
      if (status) status.textContent = ''
    } catch (error) {
      clearSelectedMedia()
      if (status) status.textContent = error.message
    }
  }

  function clearSelectedMedia() {
    selectedMedia = null
    const box = document.getElementById('chatMobilePreview')
    if (box) {
      box.hidden = true
      box.classList.remove('audio')
    }
    const imagePreview = document.getElementById('chatMobilePreviewImage')
    if (imagePreview) {
      imagePreview.removeAttribute('src')
      imagePreview.hidden = false
    }
    const audioPreview = document.getElementById('chatMobilePreviewAudio')
    if (audioPreview) {
      audioPreview.pause()
      audioPreview.removeAttribute('src')
      audioPreview.hidden = true
    }
    ;['chatMobileGalleryInput'].forEach((id) => {
      const input = document.getElementById(id)
      if (input) input.value = ''
    })
  }

  function formatVoiceTime(seconds) {
    const safe = Math.max(0, Math.floor(Number(seconds) || 0))
    return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2, '0')}`
  }

  function stopVoiceTimer() {
    if (voiceTimer) clearInterval(voiceTimer)
    voiceTimer = 0
  }

  function updateVoiceTimer() {
    const elapsed = voiceRecorder?.elapsedSeconds?.() || 0
    const timer = document.getElementById('chatMobileVoiceTimer')
    if (timer) timer.textContent = formatVoiceTime(elapsed)
    if (elapsed >= 60 && !voiceFinishing) finishVoiceRecording(true)
  }

  async function startVoiceRecording() {
    if (sending || voiceRecorder?.active || voiceFinishing) return
    const Recorder = window.VSHookVoiceRecorder
    const status = document.getElementById('chatMobileStatus')
    if (typeof Recorder !== 'function') {
      if (status) status.textContent = 'O gravador de voz não foi carregado.'
      return
    }
    clearSelectedMedia()
    const recorder = new Recorder()
    voiceRecorder = recorder
    try {
      await recorder.start()
      document.getElementById('chatMobileVoiceRecording').hidden = false
      if (status) status.textContent = ''
      stopVoiceTimer()
      updateVoiceTimer()
      voiceTimer = setInterval(updateVoiceTimer, 250)
      updateHeaderAndControls()
    } catch (error) {
      recorder.cancel()
      voiceRecorder = null
      document.getElementById('chatMobileVoiceRecording').hidden = true
      if (status) status.textContent = error.message
      updateHeaderAndControls()
    }
  }

  function cancelVoiceRecording() {
    stopVoiceTimer()
    voiceRecorder?.cancel?.()
    voiceRecorder = null
    voiceFinishing = false
    const panel = document.getElementById('chatMobileVoiceRecording')
    if (panel) panel.hidden = true
    const timer = document.getElementById('chatMobileVoiceTimer')
    if (timer) timer.textContent = '0:00'
    updateHeaderAndControls()
  }

  async function finishVoiceRecording(sendImmediately = true) {
    if (!voiceRecorder?.active || voiceFinishing) return
    const recorder = voiceRecorder
    const status = document.getElementById('chatMobileStatus')
    voiceFinishing = true
    stopVoiceTimer()
    updateHeaderAndControls()
    try {
      selectedMedia = await recorder.stop()
      voiceRecorder = null
      voiceFinishing = false
      document.getElementById('chatMobileVoiceRecording').hidden = true
      const timer = document.getElementById('chatMobileVoiceTimer')
      if (timer) timer.textContent = '0:00'
      updateHeaderAndControls()
      if (sendImmediately) await sendMessage()
    } catch (error) {
      recorder.cancel()
      voiceRecorder = null
      voiceFinishing = false
      const panel = document.getElementById('chatMobileVoiceRecording')
      if (panel) panel.hidden = true
      if (status) status.textContent = error.message
      updateHeaderAndControls()
    }
  }

  async function sendMessage() {
    if (sending) return
    const input = document.getElementById('chatMobileInput')
    const text = String(input?.value || '').trim()
    if (!text && !selectedMedia) {
      document.getElementById('chatMobileStatus').textContent = 'Digite uma mensagem ou escolha uma mídia.'
      return
    }
    const media = selectedMedia ? { ...selectedMedia } : null
    const replyToMessageId = messages.has(replyingToMessageId) ? replyingToMessageId : 0
    const replyTo = replyToMessageId ? messages.get(replyToMessageId) : null
    const tempId = media ? Date.now() * 1000 + Math.floor(Math.random() * 1000) : 0
    if (tempId) {
      const user = chatState?.user || {}
      messages.set(tempId, {
        id: tempId,
        customerId: user.id,
        name: user.name || 'User',
        isAdmin: user.isAdmin === true,
        avatarUrl: user.avatarUrl || '',
        text,
        imageUrl: media.kind === 'image' ? media.dataUrl : '',
        audioUrl: media.kind === 'audio' ? media.dataUrl : '',
        replyTo: replyTo ? {
          id: Number(replyTo.id), name: replyTo.name || 'Usuário', isAdmin: replyTo.isAdmin === true,
          text: replyTo.text || '', hasImage: Boolean(replyTo.imageUrl), hasAudio: Boolean(replyTo.audioUrl), hasVideo: Boolean(replyTo.videoUrl)
        } : null,
        createdAt: new Date().toISOString(),
        pending: true,
      })
      if (input) input.value = ''
      clearSelectedMedia()
      renderMessages(true)
    }
    sending = true
    updateHeaderAndControls()
    try {
      const result = await post('/chat/messages', {
        text,
        replyToMessageId,
        image: media?.kind === 'image' ? { mimeType: media.mimeType, base64: media.base64 } : null,
      })
      if (tempId) messages.delete(tempId)
      if (input) input.value = ''
      clearSelectedMedia()
      clearReplyToMessage()
      applyState(result, false)
      renderMessages(true)
      document.getElementById('chatMobileStatus').textContent = ''
    } catch (error) {
      if (tempId && messages.has(tempId)) {
        messages.set(tempId, { ...messages.get(tempId), pending: false, failed: true })
        renderMessages(true)
      }
      document.getElementById('chatMobileStatus').textContent = error.message
      await refresh(false).catch(() => {})
    } finally {
      sending = false
      updateHeaderAndControls()
    }
  }

  async function setPinnedMessage(messageId, button) {
    if (button) button.disabled = true
    try {
      const result = await post('/chat/pin', { messageId })
      applyState(result, true)
      document.getElementById('chatMobileStatus').textContent = Number(result?.chat?.pinnedMessageId || 0) ? 'Mensagem fixada.' : 'Mensagem desafixada.'
    } catch (error) {
      document.getElementById('chatMobileStatus').textContent = error.message
    } finally {
      if (button?.isConnected) button.disabled = false
    }
  }

  function clearReplyToMessage() {
    replyingToMessageId = 0
    const preview = document.getElementById('chatMobileReplyPreview')
    if (preview) preview.hidden = true
  }

  function replyToMessage(messageId) {
    const message = messages.get(Math.floor(Number(messageId)))
    if (!messagePermissions(message).reply) return
    replyingToMessageId = Number(message.id)
    document.getElementById('chatMobileReplyName').textContent = String(message.name || 'Usuário')
    document.getElementById('chatMobileReplyText').textContent = messagePreview(message)
    document.getElementById('chatMobileReplyPreview').hidden = false
    closeMessageActions()
    document.getElementById('chatMobileInput')?.focus()
  }

  function closeMessageActions() {
    actionMessageId = 0
    const modal = document.getElementById('chatMobileMessageActions')
    if (modal) modal.hidden = true
  }

  function openMessageActions(messageId) {
    const message = messages.get(Math.floor(Number(messageId)))
    const permissions = messagePermissions(message)
    if (!permissions.reply) return
    actionMessageId = Number(message.id)
    document.getElementById('chatMobileMessageActionTitle').textContent = 'Opções da mensagem'
    document.getElementById('chatMobileMessageActionName').textContent = String(message.name || 'Usuário')
    document.getElementById('chatMobileMessageActionText').textContent = messagePreview(message)
    const buttons = document.getElementById('chatMobileMessageActionButtons')
    buttons.hidden = false
    buttons.querySelector('[data-message-action="reply"]').hidden = !permissions.reply
    buttons.querySelector('[data-message-action="edit"]').hidden = !permissions.edit
    buttons.querySelector('[data-message-action="delete"]').hidden = !permissions.delete
    const pinButton = buttons.querySelector('[data-message-action="pin"]')
    pinButton.hidden = !permissions.pin
    pinButton.textContent = Number(chatState?.chat?.pinnedMessageId || 0) === Number(message.id) ? 'Desafixar mensagem' : 'Fixar mensagem'
    document.getElementById('chatMobileDeleteConfirmButtons').hidden = true
    document.getElementById('chatMobileMessageActions').hidden = false
    navigator.vibrate?.(18)
  }

  function openPinnedMessageActions() {
    const messageId = Number(chatState?.chat?.pinnedMessageId || 0)
    if (chatState?.user?.isAdmin !== true || messageId < 1) return
    if (messages.has(messageId)) {
      openMessageActions(messageId)
      return
    }
    actionMessageId = messageId
    document.getElementById('chatMobileMessageActionTitle').textContent = 'Mensagem fixada'
    document.getElementById('chatMobileMessageActionName').textContent = String(chatState?.user?.name || 'VS Hook')
    document.getElementById('chatMobileMessageActionText').textContent = String(chatState?.chat?.pinnedMessage || '')
    const buttons = document.getElementById('chatMobileMessageActionButtons')
    buttons.hidden = false
    buttons.querySelectorAll('[data-message-action]').forEach((button) => {
      button.hidden = button.dataset.messageAction !== 'pin'
    })
    buttons.querySelector('[data-message-action="pin"]').textContent = 'Desafixar mensagem'
    document.getElementById('chatMobileDeleteConfirmButtons').hidden = true
    document.getElementById('chatMobileMessageActions').hidden = false
    navigator.vibrate?.(18)
  }

  function requestDeleteFromActions() {
    if (!messagePermissions(messages.get(actionMessageId)).delete) return
    document.getElementById('chatMobileMessageActionTitle').textContent = 'Apagar mensagem?'
    document.getElementById('chatMobileMessageActionButtons').hidden = true
    document.getElementById('chatMobileDeleteConfirmButtons').hidden = false
  }

  async function deleteMessage(messageId, button) {
    const normalizedId = Math.floor(Number(messageId))
    if (!Number.isInteger(normalizedId) || normalizedId < 1) return
    if (!messagePermissions(messages.get(normalizedId)).delete) return
    if (button) button.disabled = true
    try {
      const result = await post('/chat/delete', { messageId: normalizedId })
      closeMessageActions()
      applyState(result, true)
      document.getElementById('chatMobileStatus').textContent = 'Mensagem apagada.'
    } catch (error) {
      document.getElementById('chatMobileStatus').textContent = error.message
    } finally {
      if (button?.isConnected) button.disabled = false
    }
  }

  function closeEditMessage() {
    editingMessageId = 0
    document.getElementById('chatMobileEditModal').hidden = true
    document.getElementById('chatMobileEditStatus').textContent = ''
  }

  function editMessage(messageId) {
    const normalizedId = Math.floor(Number(messageId))
    if (!Number.isInteger(normalizedId) || normalizedId < 1) return
    const message = messages.get(normalizedId)
    if (!messagePermissions(message).edit) return
    editingMessageId = normalizedId
    document.getElementById('chatMobileEditInput').value = String(message.text || '')
    document.getElementById('chatMobileEditStatus').textContent = ''
    closeMessageActions()
    document.getElementById('chatMobileEditModal').hidden = false
    setTimeout(() => document.getElementById('chatMobileEditInput')?.focus(), 0)
  }

  async function saveEditedMessage() {
    const normalizedId = editingMessageId
    if (!messagePermissions(messages.get(normalizedId)).edit) return
    const editedText = String(document.getElementById('chatMobileEditInput')?.value || '')
    if (editedText.length > 1000) {
      document.getElementById('chatMobileEditStatus').textContent = 'A mensagem pode ter no máximo 1000 caracteres.'
      return
    }
    const button = document.getElementById('chatMobileEditSave')
    button.disabled = true
    try {
      const result = await post('/chat/edit', { messageId: normalizedId, text: editedText })
      applyState(result, true)
      closeEditMessage()
      document.getElementById('chatMobileStatus').textContent = 'Mensagem editada.'
    } catch (error) {
      document.getElementById('chatMobileEditStatus').textContent = error.message
    } finally {
      if (button?.isConnected) button.disabled = false
    }
  }

  async function openAdminSettings() {
    if (chatState?.user?.isAdmin !== true) return
    const settings = chatState.chat || {}
    document.getElementById('chatMobileAdminOpen').checked = settings.open !== false
    document.getElementById('chatMobileAdminLimit').value = String(settings.dailyMessageLimit || 10)
    document.getElementById('chatMobileAdminUnlimited').checked = settings.dailyMessageUnlimited === true
    document.getElementById('chatMobileAdminLimit').disabled = settings.dailyMessageUnlimited === true
    document.getElementById('chatMobileAdminRetention').value = String(settings.retentionDays || 7)
    document.getElementById('chatMobileAdminStatus').textContent = ''
    document.getElementById('chatMobileAdminModal').hidden = false
  }

  async function saveAdminSettings() {
    const status = document.getElementById('chatMobileAdminStatus')
    try {
      const result = await post('/chat/admin/settings', {
        open: document.getElementById('chatMobileAdminOpen').checked,
        dailyMessageLimit: Number(document.getElementById('chatMobileAdminLimit').value),
        dailyMessageUnlimited: document.getElementById('chatMobileAdminUnlimited').checked,
        retentionDays: Number(document.getElementById('chatMobileAdminRetention').value),
      })
      applyState(result, true)
      document.getElementById('chatMobileAdminModal').hidden = true
    } catch (error) {
      status.textContent = error.message
    }
  }

  async function clearChatAsAdmin() {
    if (!window.confirm('Apagar todas as mensagens e mídias do Chat Hook?')) return
    try {
      const result = await post('/chat/admin/clear')
      applyState(result, true)
      document.getElementById('chatMobileAdminStatus').textContent = 'Chat limpo.'
    } catch (error) {
      document.getElementById('chatMobileAdminStatus').textContent = error.message
    }
  }

  async function uploadMobileAvatar(file) {
    const status = document.getElementById('chatMobileStatus')
    try {
      if (status) status.textContent = ''
      const image = await prepareImage(file, 3 * 1024 * 1024)
      const result = await post('/chat/avatar', { image: { mimeType: image.mimeType, base64: image.base64 } })
      applyState(result, true)
      if (status) status.textContent = ''
    } catch (error) {
      if (status) status.textContent = error.message
    }
  }

  async function removeMobileAvatar() {
    const status = document.getElementById('chatMobileStatus')
    try {
      if (status) status.textContent = ''
      const result = await post('/chat/avatar', { remove: true })
      applyState(result, true)
      if (status) status.textContent = ''
    } catch (error) {
      if (status) status.textContent = error.message
    }
  }

  function bindEvents() {
    document.getElementById('chatMobileCurrentAvatar')?.addEventListener('click', (event) => {
      event.stopPropagation()
      const avatarMenu = document.getElementById('chatMobileAvatarMenu')
      if (avatarMenu && chatState?.user?.id) avatarMenu.hidden = !avatarMenu.hidden
    })
    document.getElementById('chatMobileBack')?.addEventListener('click', () => {
      if (voiceRecorder?.active) cancelVoiceRecording()
      window.vshookExitToProjectSelector?.()
    })
    document.getElementById('chatMobileAdminMenu')?.addEventListener('click', openAdminSettings)
    document.getElementById('chatMobileAdminClose')?.addEventListener('click', () => { document.getElementById('chatMobileAdminModal').hidden = true })
    document.getElementById('chatMobileAdminSave')?.addEventListener('click', saveAdminSettings)
    document.getElementById('chatMobileAdminClear')?.addEventListener('click', clearChatAsAdmin)
    document.getElementById('chatMobileAdminUnlimited')?.addEventListener('change', (event) => { document.getElementById('chatMobileAdminLimit').disabled = event.target.checked })
    const avatarMenu = document.getElementById('chatMobileAvatarMenu')
    const avatarMenuButton = document.getElementById('chatMobileAvatarButton')
    avatarMenuButton?.addEventListener('click', (event) => {
      event.stopPropagation()
      if (avatarMenu) avatarMenu.hidden = !avatarMenu.hidden
    })
    avatarMenu?.addEventListener('click', (event) => {
      const action = event.target.closest('[data-avatar-action]')?.dataset.avatarAction
      if (!action) return
      if (action === 'change') return
      avatarMenu.hidden = true
      if (action === 'remove') removeMobileAvatar()
    })
    document.addEventListener('pointerdown', (event) => {
      if (!avatarMenu || avatarMenu.hidden || event.target === avatarMenuButton || avatarMenu.contains(event.target)) return
      avatarMenu.hidden = true
    })
    document.getElementById('chatMobileAvatarInput')?.addEventListener('change', async (event) => {
      if (avatarMenu) avatarMenu.hidden = true
      if (event.target.files?.length !== 1) {
        event.target.value = ''
        return
      }
      await uploadMobileAvatar(event.target.files[0])
      event.target.value = ''
    })
    const picker = document.getElementById('chatMobileEmojiPicker')
    const emojiButton = document.getElementById('chatMobileEmoji')
    emojiButton?.addEventListener('click', (event) => {
      event.stopPropagation()
      if (picker) picker.hidden = !picker.hidden
    })
    picker?.addEventListener('emoji-click', (event) => {
      const input = document.getElementById('chatMobileInput')
      const emoji = String(event.detail?.unicode || '')
      if (!emoji || !input) return
      const start = Number.isFinite(input.selectionStart) ? input.selectionStart : input.value.length
      const end = Number.isFinite(input.selectionEnd) ? input.selectionEnd : start
      input.setRangeText(emoji, start, end, 'end')
      input.focus()
      picker.hidden = true
    })
    document.addEventListener('pointerdown', (event) => {
      if (!picker || picker.hidden) return
      if (event.target === picker || event.target === emojiButton || picker.contains(event.target)) return
      picker.hidden = true
    })
    const attachmentButton = document.getElementById('chatMobileGallery')
    attachmentButton?.addEventListener('click', () => {
      document.getElementById('chatMobileGalleryInput')?.click()
    })
    document.getElementById('chatMobileGalleryInput')?.addEventListener('change', (event) => chooseMedia(event.target.files?.[0]))
    document.getElementById('chatMobileRemoveImage')?.addEventListener('click', clearSelectedMedia)
    document.getElementById('chatMobileCancelReply')?.addEventListener('click', clearReplyToMessage)
    document.getElementById('chatMobileSend')?.addEventListener('click', sendMessage)
    document.getElementById('chatMobileEditCancel')?.addEventListener('click', closeEditMessage)
    document.getElementById('chatMobileEditSave')?.addEventListener('click', saveEditedMessage)
    const messageActions = document.getElementById('chatMobileMessageActions')
    document.getElementById('chatMobileMessageActionCancel')?.addEventListener('click', closeMessageActions)
    messageActions?.addEventListener('click', (event) => {
      if (event.target === messageActions) return closeMessageActions()
      const action = event.target.closest('[data-message-action]')?.dataset.messageAction
      const messageId = actionMessageId
      if (!action || !messageId) return
      if (action === 'reply') replyToMessage(messageId)
      else if (action === 'edit') editMessage(messageId)
      else if (action === 'pin') {
        closeMessageActions()
        setPinnedMessage(messageId)
      } else if (action === 'delete') requestDeleteFromActions()
      else if (action === 'cancel-delete') openMessageActions(messageId)
      else if (action === 'confirm-delete') deleteMessage(messageId, event.target.closest('button'))
    })
    const editModal = document.getElementById('chatMobileEditModal')
    editModal?.addEventListener('click', (event) => { if (event.target === editModal) closeEditMessage() })
    const messagesContainer = document.getElementById('chatMobileMessages')
    const cancelMessageHold = () => {
      if (messageHoldTimer) clearTimeout(messageHoldTimer)
      messageHoldTimer = 0
      messageHoldStart = null
    }
    messagesContainer?.addEventListener('pointerdown', (event) => {
      if (event.pointerType === 'mouse' && event.button !== 0) return
      if (event.target.closest('button, input, audio')) return
      const article = event.target.closest('[data-chat-message-id]')
      const messageId = Number(article?.dataset.chatMessageId || 0)
      if (!messagePermissions(messages.get(messageId)).reply) return
      cancelMessageHold()
      messageHoldStart = { x: event.clientX, y: event.clientY, messageId }
      messageHoldTimer = window.setTimeout(() => {
        const heldMessageId = messageHoldStart?.messageId || 0
        messageHoldTimer = 0
        messageHoldStart = null
        if (!heldMessageId) return
        suppressMessageClickUntil = Date.now() + 700
        openMessageActions(heldMessageId)
      }, 520)
    })
    messagesContainer?.addEventListener('pointermove', (event) => {
      if (!messageHoldStart) return
      if (Math.hypot(event.clientX - messageHoldStart.x, event.clientY - messageHoldStart.y) > 12) cancelMessageHold()
    })
    ;['pointerup', 'pointercancel', 'pointerleave'].forEach((type) => messagesContainer?.addEventListener(type, cancelMessageHold))
    messagesContainer?.addEventListener('contextmenu', (event) => {
      const article = event.target.closest('[data-chat-message-id]')
      const messageId = Number(article?.dataset.chatMessageId || 0)
      if (!messageId || !messagePermissions(messages.get(messageId)).reply) return
      event.preventDefault()
      cancelMessageHold()
      openMessageActions(messageId)
    })
    messagesContainer?.addEventListener('click', (event) => {
      if (Date.now() < suppressMessageClickUntil) {
        event.preventDefault()
        event.stopPropagation()
        return
      }
      const audioAction = event.target.closest('[data-audio-action]')
      if (audioAction) {
        const audio = audioAction.closest('.chatMobileMessageAudio')?.querySelector('audio')
        if (!audio) return
        if (audio.paused) {
          messagesContainer.querySelectorAll('.chatMobileMessageAudio audio').forEach((candidate) => { if (candidate !== audio) candidate.pause() })
          audio.play().catch(() => {})
        } else audio.pause()
        return
      }
      const replyQuote = event.target.closest('[data-jump-message]')
      if (replyQuote) {
        const target = messagesContainer.querySelector(`[data-chat-message-id="${Number(replyQuote.dataset.jumpMessage || 0)}"]`)
        target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        target?.classList.add('highlighted')
        if (target) setTimeout(() => target.classList.remove('highlighted'), 900)
        return
      }
      const image = event.target.closest('[data-open-image]')
      if (image?.dataset.openImage) window.open(image.dataset.openImage, '_blank', 'noopener')
    })
    const pinnedMessage = document.getElementById('chatMobilePinned')
    let pinnedHoldTimer = 0
    let pinnedHoldStart = null
    const cancelPinnedHold = () => {
      if (pinnedHoldTimer) clearTimeout(pinnedHoldTimer)
      pinnedHoldTimer = 0
      pinnedHoldStart = null
    }
    pinnedMessage?.addEventListener('pointerdown', (event) => {
      if (event.pointerType === 'mouse' && event.button !== 0) return
      if (event.target.closest('button') || chatState?.user?.isAdmin !== true || !Number(chatState?.chat?.pinnedMessageId || 0)) return
      cancelPinnedHold()
      pinnedHoldStart = { x: event.clientX, y: event.clientY }
      pinnedHoldTimer = window.setTimeout(() => {
        pinnedHoldTimer = 0
        pinnedHoldStart = null
        openPinnedMessageActions()
      }, 520)
    })
    pinnedMessage?.addEventListener('pointermove', (event) => {
      if (pinnedHoldStart && Math.hypot(event.clientX - pinnedHoldStart.x, event.clientY - pinnedHoldStart.y) > 12) cancelPinnedHold()
    })
    ;['pointerup', 'pointercancel', 'pointerleave'].forEach((type) => pinnedMessage?.addEventListener(type, cancelPinnedHold))
    pinnedMessage?.addEventListener('contextmenu', (event) => {
      if (event.target.closest('button') || !Number(chatState?.chat?.pinnedMessageId || 0)) return
      event.preventDefault()
      cancelPinnedHold()
      openPinnedMessageActions()
    })
    document.getElementById('chatMobileUnpin')?.addEventListener('click', (event) => setPinnedMessage(0, event.currentTarget))
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refresh(!chatState).catch(() => {})
    })
  }

  buildInterface()
  refresh(true).catch(() => {})
  pollTimer = window.setInterval(() => refresh(false).catch(() => {}), 3000)
  window.addEventListener('beforeunload', () => clearInterval(pollTimer), { once: true })
})()
