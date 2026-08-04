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
  let lastMessageId = 0
  let revision = 0
  let polling = false
  let sending = false
  let selectedMedia = null
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
    const current = mobileSession || readMobileSession()
    if (current) return current
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
          <div id="chatMobileCurrentAvatar" class="chatMobileAvatar chatMobileCurrentAvatar">H</div>
          <div class="chatMobileHeading">
            <h1>Chat Hook</h1>
            <span id="chatMobileConnection">Conectando...</span>
          </div>
        </header>

        <section id="chatMobilePinned" class="chatMobilePinned" hidden>
          <div><strong>📌 Mensagem fixada</strong><button id="chatMobileUnpin" type="button" hidden>Desafixar</button></div>
          <p id="chatMobilePinnedText"></p>
        </section>

        <section id="chatMobileMessages" class="chatMobileMessages" aria-live="polite">
          <div class="chatMobileEmpty">Carregando conversa...</div>
        </section>

        <section class="chatMobileComposer">
          <div id="chatMobilePreview" class="chatMobilePreview" hidden>
            <img id="chatMobilePreviewImage" alt="Imagem escolhida" />
            <video id="chatMobilePreviewVideo" muted playsinline preload="metadata" hidden></video>
            <button id="chatMobileRemoveImage" type="button" aria-label="Remover imagem">×</button>
          </div>
          <textarea id="chatMobileInput" rows="2" maxlength="1000" placeholder="Escreva uma mensagem..."></textarea>
          <emoji-picker id="chatMobileEmojiPicker" class="chatMobileEmojiPicker dark" locale="pt" emoji-version="17.0" data-source="https://cdn.jsdelivr.net/npm/emoji-picker-element-data@^1/pt/cldr/data.json" hidden></emoji-picker>
          <div class="chatMobileActions">
            <button id="chatMobileEmoji" class="chatMobileIconButton" type="button" aria-label="Emojis">😊</button>
            <button id="chatMobileGallery" class="chatMobileIconButton" type="button" aria-label="Escolher foto da galeria">📎</button>
            <button id="chatMobileCamera" class="chatMobileIconButton" type="button" aria-label="Tirar foto">📷</button>
            <input id="chatMobileGalleryInput" type="file" accept="image/*" hidden />
            <input id="chatMobileCameraInput" type="file" accept="image/*" capture="environment" hidden />
            <input id="chatMobileVideoInput" type="file" accept="video/mp4,video/quicktime,video/webm" capture="environment" hidden />
            <span id="chatMobileQuota"></span>
            <button id="chatMobileSend" class="chatMobileSend" type="button">Enviar</button>
          </div>
          <div id="chatMobileStatus" class="chatMobileStatus"></div>
        </section>
        <div id="chatMobileCameraMenu" class="chatMobileCameraMenu" hidden>
          <button id="chatMobilePhotoChoice" type="button">📷 Tirar foto</button>
          <button id="chatMobileVideoChoice" type="button">🎥 Gravar vídeo — até 30s</button>
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
    const userId = Number(chatState?.user?.id || 0)
    const isCurrentAdmin = chatState?.user?.isAdmin === true
    const pinnedId = Number(chatState?.chat?.pinnedMessageId || 0)
    container.innerHTML = list.map((message) => {
      const name = escapeHtml(message.name || 'User')
      const text = escapeHtml(message.text || '').replace(/\n/g, '<br>')
      const canPin = !message.pending && !message.failed && isCurrentAdmin && Number(message.customerId || 0) === userId && Boolean(String(message.text || '').trim())
      const pin = canPin
        ? `<button class="chatMobilePin" type="button" data-pin-message="${Number(message.id || 0)}">${Number(message.id || 0) === pinnedId ? 'Desafixar' : '📌 Fixar'}</button>`
        : ''
      const canDelete = !message.pending && !message.failed && (isCurrentAdmin || Number(message.customerId || 0) === userId)
      const deleteAction = canDelete
        ? `<button class="chatMobileDelete" type="button" data-delete-message="${Number(message.id || 0)}" aria-label="Apagar mensagem" title="Apagar mensagem">🗑</button>`
        : ''
      const uploadBadge = message.pending
        ? '<span class="chatMobileUploadSpinner"></span>'
        : message.failed
          ? '<span class="chatMobileUploadFailed">!</span>'
          : ''
      const image = message.imageUrl
        ? `<button class="chatMobileMessageImage${message.pending ? ' uploading' : ''}" type="button" ${message.pending ? 'disabled' : `data-open-image="${escapeHtml(message.imageUrl)}"`}><img src="${escapeHtml(message.imageUrl)}" alt="Imagem de ${name}" />${uploadBadge}</button>`
        : ''
      const video = message.videoUrl
        ? `<div class="chatMobileMessageVideo${message.pending ? ' uploading' : ''}"><video src="${escapeHtml(message.videoUrl)}" controls playsinline preload="metadata" ${message.pending ? 'muted' : ''}></video>${uploadBadge}</div>`
        : ''
      return `
        <article class="chatMobileMessage ${message.isAdmin ? 'admin' : 'user'}">
          <div class="chatMobileAvatar">${avatarHtml(message.name, message.avatarUrl)}</div>
          <div class="chatMobileBubble">
            <div class="chatMobileMessageHead">
              <strong>${name}</strong>
              ${message.isAdmin ? '<span>ADMIN</span>' : ''}
              <time>${escapeHtml(formatTime(message.createdAt))}</time>
              ${pin}
              ${deleteAction}
            </div>
            ${text ? `<p>${text}</p>` : ''}
            ${image}
            ${video}
          </div>
        </article>`
    }).join('')
    if (forceBottom || wasNearBottom) container.scrollTop = container.scrollHeight
  }

  function updateHeaderAndControls() {
    const user = chatState?.user || {}
    const settings = chatState?.chat || {}
    const limits = chatState?.limits || {}
    const avatar = document.getElementById('chatMobileCurrentAvatar')
    if (avatar) avatar.innerHTML = avatarHtml(user.name || 'Hook', user.avatarUrl || '')
    const connection = document.getElementById('chatMobileConnection')
    if (connection) connection.textContent = settings.open === false ? 'Somente administradores' : 'Ao vivo'

    const pinnedText = String(settings.pinnedMessage || '').trim()
    const pinned = document.getElementById('chatMobilePinned')
    if (pinned) pinned.hidden = !pinnedText
    const pinnedOutput = document.getElementById('chatMobilePinnedText')
    if (pinnedOutput) pinnedOutput.textContent = pinnedText
    const unpin = document.getElementById('chatMobileUnpin')
    if (unpin) unpin.hidden = !pinnedText || user.isAdmin !== true

    const exhausted = user.id && !user.isAdmin && Number(limits.remainingToday || 0) <= 0
    const closed = settings.open === false && !user.isAdmin
    const enabled = Boolean(user.id) && !exhausted && !closed && !sending
    const input = document.getElementById('chatMobileInput')
    const send = document.getElementById('chatMobileSend')
    if (input) {
      input.disabled = !enabled
      input.placeholder = closed ? 'O chat está fechado' : exhausted ? 'Limite diário atingido' : 'Escreva uma mensagem...'
    }
    if (send) send.disabled = !enabled
    ;['chatMobileEmoji', 'chatMobileGallery', 'chatMobileCamera'].forEach((id) => {
      const button = document.getElementById(id)
      if (button) button.disabled = !enabled
    })
    const quota = document.getElementById('chatMobileQuota')
    if (quota) quota.textContent = user.isAdmin ? 'Administrador' : user.id ? `${Number(limits.usedToday || 0)}/${Number(limits.dailyLimit || 10)} hoje` : '--'
    const videoChoice = document.getElementById('chatMobileVideoChoice')
    if (videoChoice) videoChoice.hidden = user.isAdmin !== true
    if (user.isAdmin !== true && selectedMedia?.kind === 'video') clearSelectedMedia()
  }

  function applyState(next, full = false) {
    if (!next?.ok) return
    if (full) {
      messages.clear()
      lastMessageId = 0
    }
    chatState = next
    revision = Math.max(0, Number(next.chat?.revision || 0))
    let changed = full
    for (const message of next.messages || []) {
      const id = Number(message.id || 0)
      if (!id) continue
      if (!messages.has(id)) changed = true
      messages.set(id, message)
      lastMessageId = Math.max(lastMessageId, id)
    }
    if (changed) renderMessages(full)
    updateHeaderAndControls()
    const status = document.getElementById('chatMobileStatus')
    if (status?.dataset.connection === '1') {
      status.textContent = ''
      delete status.dataset.connection
    }
  }

  async function refresh(full = false) {
    if (polling || document.visibilityState === 'hidden') return
    polling = true
    try {
      const result = await post('/chat/state', { afterId: full ? 0 : lastMessageId })
      const serverRevision = Math.max(0, Number(result?.chat?.revision || 0))
      if (!full && revision && serverRevision !== revision) {
        polling = false
        await refresh(true)
        return
      }
      applyState(result, full || !chatState)
    } catch (error) {
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

  async function prepareImage(file) {
    if (!file || !String(file.type || '').startsWith('image/')) throw new Error('Escolha uma imagem válida.')
    if (file.type === 'image/gif' && file.size <= 6 * 1024 * 1024) {
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
      while ((dataUrl.length * .75) > 5.7 * 1024 * 1024 && quality > .46) {
        quality -= .1
        dataUrl = canvas.toDataURL('image/jpeg', quality)
      }
      if ((dataUrl.length * .75) > 6 * 1024 * 1024) throw new Error('A imagem ficou grande demais para enviar.')
      return { kind: 'image', dataUrl, mimeType: 'image/jpeg', base64: dataUrl.split(',')[1] || '' }
    } finally {
      URL.revokeObjectURL(sourceUrl)
    }
  }

  function readVideoDuration(file) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file)
      const video = document.createElement('video')
      const finish = (callback) => {
        URL.revokeObjectURL(url)
        video.removeAttribute('src')
        callback()
      }
      video.preload = 'metadata'
      video.onloadedmetadata = () => finish(() => resolve(Number(video.duration) || 0))
      video.onerror = () => finish(() => reject(new Error('Não foi possível verificar a duração do vídeo.')))
      video.src = url
    })
  }

  async function prepareVideo(file) {
    const allowed = ['video/mp4', 'video/quicktime', 'video/webm']
    const mimeType = String(file?.type || '').toLowerCase()
    if (chatState?.user?.isAdmin !== true) throw new Error('Somente administradores podem enviar vídeos.')
    if (!file || !allowed.includes(mimeType)) throw new Error('Grave um vídeo MP4, MOV ou WEBM.')
    if (file.size > 40 * 1024 * 1024) throw new Error('O vídeo deve ter no máximo 40 MB.')
    const durationSeconds = await readVideoDuration(file)
    if (!durationSeconds || durationSeconds > 30.25) throw new Error('O vídeo pode ter no máximo 30 segundos.')
    const dataUrl = await fileAsDataUrl(file)
    return { kind: 'video', dataUrl, mimeType, base64: dataUrl.split(',')[1] || '', durationSeconds }
  }

  async function chooseMedia(file, kind = 'image') {
    const status = document.getElementById('chatMobileStatus')
    try {
      if (status) status.textContent = kind === 'video' ? 'Preparando vídeo...' : 'Preparando imagem...'
      selectedMedia = kind === 'video' ? await prepareVideo(file) : await prepareImage(file)
      const imagePreview = document.getElementById('chatMobilePreviewImage')
      const videoPreview = document.getElementById('chatMobilePreviewVideo')
      if (selectedMedia.kind === 'video') {
        if (imagePreview) imagePreview.hidden = true
        if (videoPreview) {
          videoPreview.src = selectedMedia.dataUrl
          videoPreview.hidden = false
        }
      } else {
        if (imagePreview) {
          imagePreview.src = selectedMedia.dataUrl
          imagePreview.hidden = false
        }
        if (videoPreview) videoPreview.hidden = true
      }
      const box = document.getElementById('chatMobilePreview')
      if (box) box.hidden = false
      if (status) status.textContent = ''
    } catch (error) {
      clearSelectedMedia()
      if (status) status.textContent = error.message
    }
  }

  function clearSelectedMedia() {
    selectedMedia = null
    const box = document.getElementById('chatMobilePreview')
    if (box) box.hidden = true
    const imagePreview = document.getElementById('chatMobilePreviewImage')
    if (imagePreview) {
      imagePreview.removeAttribute('src')
      imagePreview.hidden = false
    }
    const videoPreview = document.getElementById('chatMobilePreviewVideo')
    if (videoPreview) {
      videoPreview.pause()
      videoPreview.removeAttribute('src')
      videoPreview.hidden = true
    }
    ;['chatMobileGalleryInput', 'chatMobileCameraInput', 'chatMobileVideoInput'].forEach((id) => {
      const input = document.getElementById(id)
      if (input) input.value = ''
    })
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
        videoUrl: media.kind === 'video' ? media.dataUrl : '',
        videoDurationSeconds: media.durationSeconds || 0,
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
        image: media?.kind === 'image' ? { mimeType: media.mimeType, base64: media.base64 } : null,
        video: media?.kind === 'video' ? { mimeType: media.mimeType, base64: media.base64, durationSeconds: media.durationSeconds } : null,
      })
      if (tempId) messages.delete(tempId)
      if (input) input.value = ''
      clearSelectedMedia()
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

  async function deleteMessage(messageId, button) {
    const normalizedId = Math.floor(Number(messageId))
    if (!Number.isInteger(normalizedId) || normalizedId < 1) return
    if (!window.confirm('Apagar esta mensagem do Chat Hook para todos? Essa ação não pode ser desfeita.')) return
    if (button) button.disabled = true
    try {
      const result = await post('/chat/delete', { messageId: normalizedId })
      applyState(result, true)
      document.getElementById('chatMobileStatus').textContent = 'Mensagem apagada.'
    } catch (error) {
      document.getElementById('chatMobileStatus').textContent = error.message
    } finally {
      if (button?.isConnected) button.disabled = false
    }
  }

  function bindEvents() {
    document.getElementById('chatMobileBack')?.addEventListener('click', () => window.vshookExitToProjectSelector?.())
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
    const cameraButton = document.getElementById('chatMobileCamera')
    const cameraMenu = document.getElementById('chatMobileCameraMenu')
    document.getElementById('chatMobileGallery')?.addEventListener('click', () => document.getElementById('chatMobileGalleryInput')?.click())
    cameraButton?.addEventListener('click', (event) => {
      event.stopPropagation()
      if (chatState?.user?.isAdmin === true) {
        if (cameraMenu) cameraMenu.hidden = !cameraMenu.hidden
      } else {
        document.getElementById('chatMobileCameraInput')?.click()
      }
    })
    document.getElementById('chatMobilePhotoChoice')?.addEventListener('click', () => {
      if (cameraMenu) cameraMenu.hidden = true
      document.getElementById('chatMobileCameraInput')?.click()
    })
    document.getElementById('chatMobileVideoChoice')?.addEventListener('click', () => {
      if (cameraMenu) cameraMenu.hidden = true
      document.getElementById('chatMobileVideoInput')?.click()
    })
    document.addEventListener('pointerdown', (event) => {
      if (!cameraMenu || cameraMenu.hidden) return
      if (event.target === cameraButton || cameraMenu.contains(event.target)) return
      cameraMenu.hidden = true
    })
    document.getElementById('chatMobileGalleryInput')?.addEventListener('change', (event) => chooseMedia(event.target.files?.[0], 'image'))
    document.getElementById('chatMobileCameraInput')?.addEventListener('change', (event) => chooseMedia(event.target.files?.[0], 'image'))
    document.getElementById('chatMobileVideoInput')?.addEventListener('change', (event) => chooseMedia(event.target.files?.[0], 'video'))
    document.getElementById('chatMobileRemoveImage')?.addEventListener('click', clearSelectedMedia)
    document.getElementById('chatMobileSend')?.addEventListener('click', sendMessage)
    document.getElementById('chatMobileMessages')?.addEventListener('click', (event) => {
      const deleteButton = event.target.closest('[data-delete-message]')
      if (deleteButton) {
        deleteMessage(Number(deleteButton.dataset.deleteMessage || 0), deleteButton)
        return
      }
      const pin = event.target.closest('[data-pin-message]')
      if (pin) {
        setPinnedMessage(Number(pin.dataset.pinMessage || 0), pin)
        return
      }
      const image = event.target.closest('[data-open-image]')
      if (image?.dataset.openImage) window.open(image.dataset.openImage, '_blank', 'noopener')
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
