(() => {
  const root = document.getElementById('app')
  const selectedProject = (() => {
    try { return JSON.parse(localStorage.getItem('vshook_selected_project') || '{}') }
    catch (_) { return {} }
  })()
  const storedTransferHost = (() => {
    try { return String(localStorage.getItem('vshook_transfer_host') || '').trim() }
    catch (_) { return '' }
  })()
  const selectedBase = String(selectedProject.directorUrl || selectedProject.musiciansUrl ||
    (storedTransferHost ? `http://${storedTransferHost}:47831` : window.location.origin))
  const transferBase = (() => {
    const url = new URL(selectedBase)
    url.port = '47835'
    url.pathname = ''
    url.search = ''
    url.hash = ''
    return url.toString().replace(/\/$/, '')
  })()
  // Blocos menores são mais estáveis em Wi-Fi de celular e diminuem o trecho
  // que precisa ser repetido quando o rádio troca de rede ou perde um pacote.
  const CHUNK_BYTES = 256 * 1024
  let selectedFiles = []
  let busy = false
  const animalNames = ['Onça', 'Tigre', 'Raposa', 'Lobo', 'Leão', 'Coruja', 'Panda', 'Arara', 'Golfinho', 'Coala']
  const fruitNames = ['Maçã', 'Pera', 'Abacate', 'Manga', 'Caju', 'Uva', 'Melão', 'Acerola', 'Pitanga', 'Coco']
  const mobileDeviceName = (() => {
    try {
      const saved = String(localStorage.getItem('vshook_transfer_device_name') || '').trim()
      if (saved) return saved
      const bytes = new Uint32Array(2)
      crypto.getRandomValues(bytes)
      const created = `${animalNames[bytes[0] % animalNames.length]} ${fruitNames[bytes[1] % fruitNames.length]}`
      localStorage.setItem('vshook_transfer_device_name', created)
      return created
    } catch (_) {
      return 'Celular VS Hook'
    }
  })()

  root.innerHTML = `
    <main class="transferHookApp">
      <header class="transferHookHeader">
        <button id="transferHookBack" class="transferHookBack" type="button" aria-label="Voltar">‹</button>
        <div><h1>Drop Hook</h1><p>${mobileDeviceName} · Transferência direta pela rede local. Não usa internet.</p></div>
      </header>
      <div class="transferHookGrid">
        <section class="transferHookCard">
          <h2>Enviar para o computador</h2>
          <p>Escolha arquivos, fotos ou vídeos e digite o código exibido pela Hook Center.</p>
          <input id="transferSendCode" class="transferHookCode" inputmode="numeric" maxlength="6" placeholder="000000" />
          <div class="transferHookActions">
            <label class="transferHookFileLabel transferHookSecondary">Galeria<input id="transferGalleryInput" type="file" accept="image/*,video/*" multiple /></label>
            <label class="transferHookFileLabel transferHookSecondary">Arquivos<input id="transferFilesInput" type="file" multiple /></label>
            <label class="transferHookFileLabel transferHookSecondary">Tirar foto<input id="transferPhotoInput" type="file" accept="image/*" capture="environment" /></label>
            <label class="transferHookFileLabel transferHookSecondary">Gravar vídeo<input id="transferVideoInput" type="file" accept="video/*" capture="environment" /></label>
          </div>
          <div id="transferSelection" class="transferHookSelection">Nenhum arquivo selecionado.</div>
          <button id="transferSendButton" class="transferHookButton" type="button" disabled>Enviar arquivos</button>
        </section>
        <section class="transferHookCard">
          <h2>Receber do computador</h2>
          <p>No computador, clique em “Disponibilizar para celular”. Este aparelho encontra a Hook Center pela rede local, sem código.</p>
          <button id="transferReceiveButton" class="transferHookButton" type="button">Receber arquivos</button>
        </section>
        <section class="transferHookCard">
          <h2>Atividade</h2>
          <div class="transferHookProgress"><div id="transferProgressBar"></div></div>
          <div id="transferStatus" class="transferHookStatus">Aguardando.</div>
        </section>
      </div>
    </main>`

  const $ = (id) => document.getElementById(id)
  const normalizeCode = (value) => String(value || '').replace(/\D/g, '').slice(0, 6)
  const safeName = (name) => String(name || 'arquivo').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').replace(/[. ]+$/g, '') || 'arquivo'
  const setStatus = (text, kind = '') => {
    $('transferStatus').textContent = text
    $('transferStatus').className = `transferHookStatus ${kind}`.trim()
  }
  const setProgress = (done, total) => {
    const percent = total > 0 ? Math.min(100, Math.round(done * 100 / total)) : 0
    $('transferProgressBar').style.width = `${percent}%`
  }
  const setBusy = (value) => {
    busy = value
    document.querySelectorAll('.transferHookButton,.transferHookCode,input[type=file]').forEach((element) => { element.disabled = value })
    refreshSendButton()
  }
  const refreshSendButton = () => {
    $('transferSendButton').disabled = busy || selectedFiles.length === 0 || normalizeCode($('transferSendCode').value).length !== 6
  }
  const readJson = async (response) => {
    const body = await response.json().catch(() => ({}))
    if (!response.ok || !body.ok) {
      const error = new Error(body.error || `Falha de rede (${response.status}).`)
      error.statusCode = response.status
      throw error
    }
    return body
  }
  const randomTransferId = () => {
    const bytes = new Uint8Array(32)
    crypto.getRandomValues(bytes)
    return [...bytes].map((value) => value.toString(16).padStart(2, '0')).join('')
  }
  const pauseForReconnect = async () => {
    setStatus('Transferência pausada. Aguardando a rede voltar...')
    await new Promise((resolve) => setTimeout(resolve, 1200))
  }
  const canRetry = (error) => !Number(error?.statusCode) || Number(error.statusCode) === 409 || Number(error.statusCode) >= 500
  const waitForShareManifest = async () => {
    while (true) {
      try {
        const availability = await readJson(await fetch(
          `${transferBase}/transfer-hook/share/status`,
          { cache: 'no-store' }))
        if (!availability.available) {
          if (!availability.preparing) {
            const error = new Error('Nenhum arquivo está disponibilizado nesta Hook Center.')
            error.statusCode = 404
            throw error
          }
          setStatus('O computador está preparando os arquivos. Aguarde...')
          await new Promise((resolve) => setTimeout(resolve, 500))
          continue
        }
        const access = String(availability.access || '').trim()
        if (!/^[a-f0-9]{64}$/i.test(access)) {
          const error = new Error('A sessão do Drop Hook ainda está sendo preparada.')
          error.retryShareHandshake = true
          throw error
        }
        const manifest = await readJson(await fetch(
          `${transferBase}/transfer-hook/share/manifest?access=${encodeURIComponent(access)}`,
          { cache: 'no-store' }))
        return { access, manifest }
      } catch (error) {
        // Um 403 aqui representa uma sessão substituída entre Status e
        // Manifesto. Consulta novamente a sessão atual em vez de obrigar o
        // usuário a escolher o mesmo arquivo outra vez no computador.
        if (!canRetry(error) && Number(error?.statusCode) !== 403 &&
            error?.retryShareHandshake !== true) throw error
        await pauseForReconnect()
      }
    }
  }
  const setSelected = (fileList) => {
    const byName = new Map()
    for (const file of Array.from(fileList || [])) byName.set(safeName(file.name), file)
    selectedFiles = [...byName.entries()].map(([name, file]) => ({ name, file }))
    const total = selectedFiles.reduce((sum, entry) => sum + entry.file.size, 0)
    $('transferSelection').textContent = selectedFiles.length
      ? `${selectedFiles.length} arquivo(s) • ${(total / 1048576).toFixed(1)} MB`
      : 'Nenhum arquivo selecionado.'
    refreshSendButton()
  }

  async function sendFiles() {
    const code = normalizeCode($('transferSendCode').value)
    if (busy || code.length !== 6 || !selectedFiles.length) return
    setBusy(true)
    const total = selectedFiles.reduce((sum, entry) => sum + entry.file.size, 0)
    try {
      setStatus('Preparando envio local...')
      setProgress(0, total)
      const manifest = {
        schemaVersion: 1, transferId: randomTransferId(), code,
        rootName: 'Drop Hook', senderName: mobileDeviceName, directories: [],
        files: selectedFiles.map((entry, index) => ({ id: `file-${index + 1}`, relativePath: entry.name, size: entry.file.size })),
        totalBytes: total,
      }
      while (true) {
        try {
          const start = await readJson(await fetch(`${transferBase}/transfer-hook/start`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(manifest), cache: 'no-store'
          }))
          const missing = new Set(Array.isArray(start.missing) ? start.missing : [])
          const offsets = start.offsets && typeof start.offsets === 'object' ? start.offsets : {}
          let done = selectedFiles.reduce((sum, entry, index) => {
            const id = `file-${index + 1}`
            return sum + (missing.has(id)
              ? Math.max(0, Math.min(entry.file.size, Number(offsets[id]) || 0))
              : entry.file.size)
          }, 0)
          setProgress(done, total)
          for (let index = 0; index < selectedFiles.length; index += 1) {
            const entry = selectedFiles[index]
            const fileId = `file-${index + 1}`
            if (!missing.has(fileId)) continue
            let offset = Math.max(0, Math.min(entry.file.size, Number(offsets[fileId]) || 0))
            while (offset < entry.file.size) {
              const block = entry.file.slice(offset, Math.min(entry.file.size, offset + CHUNK_BYTES))
              const response = await fetch(`${transferBase}/transfer-hook/file`, {
                method: 'POST', headers: {
                  'Content-Type': 'application/octet-stream', 'x-copy-token': start.token,
                  'x-copy-file-id': fileId, 'x-copy-offset': String(offset),
                }, body: block, cache: 'no-store'
              })
              await readJson(response)
              offset += block.size
              done += block.size
              setProgress(done, total)
              setStatus(`Enviando ${entry.name} • ${index + 1} de ${selectedFiles.length}`)
            }
          }
          await readJson(await fetch(`${transferBase}/transfer-hook/finish`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ token: start.token }), cache: 'no-store'
          }))
          break
        } catch (error) {
          if (!canRetry(error)) throw error
          await pauseForReconnect()
        }
      }
      setProgress(total, total)
      setStatus('Arquivos enviados pela rede local.', 'success')
    } catch (error) {
      setStatus(error.message || 'Falha na transferência.', 'error')
    } finally { setBusy(false) }
  }

  async function receiveFiles() {
    if (busy) return
    setBusy(true)
    try {
      setStatus('Consultando o computador na rede local...')
      const { access, manifest } = await waitForShareManifest()
      const total = Number(manifest.totalBytes) || 0
      let done = 0
      let directoryHandle = null
      if ('showDirectoryPicker' in window) {
        try { directoryHandle = await window.showDirectoryPicker({ mode: 'readwrite' }) } catch (_) {}
      }
      for (let index = 0; index < manifest.files.length; index += 1) {
        const file = manifest.files[index]
        const chunks = []
        let received = 0
        while (received < Number(file.size) || Number(file.size) === 0 && !chunks.length) {
          try {
            setStatus(`Recebendo ${file.relativePath} • ${index + 1} de ${manifest.files.length}`)
            const response = await fetch(`${transferBase}/transfer-hook/share/file?access=${encodeURIComponent(access)}&id=${encodeURIComponent(file.id)}`, {
              headers: received > 0 ? { Range: `bytes=${received}-` } : {}, cache: 'no-store'
            })
            if (!response.ok) {
              const error = new Error(`Não foi possível receber ${file.relativePath}.`)
              error.statusCode = response.status
              throw error
            }
            if (received > 0 && response.status !== 206) {
              chunks.length = 0
              done -= received
              received = 0
            }
            const reader = response.body?.getReader()
            if (!reader) {
              const part = new Uint8Array(await response.arrayBuffer())
              chunks.push(part)
              received += part.byteLength
              done += part.byteLength
            } else {
              while (true) {
                const part = await reader.read()
                if (part.done) break
                chunks.push(part.value)
                received += part.value.byteLength
                done += part.value.byteLength
                setProgress(done, total)
              }
            }
            if (Number(file.size) === 0 || received >= Number(file.size)) break
          } catch (error) {
            if (!canRetry(error)) throw error
            await pauseForReconnect()
          }
        }
        const blob = new Blob(chunks)
        if (directoryHandle) {
          const parts = String(file.relativePath).split('/').filter(Boolean)
          let folder = directoryHandle
          for (const part of parts.slice(0, -1)) folder = await folder.getDirectoryHandle(safeName(part), { create: true })
          const handle = await folder.getFileHandle(safeName(parts.at(-1)), { create: true })
          const writable = await handle.createWritable()
          await writable.write(blob)
          await writable.close()
        } else {
          const link = document.createElement('a')
          link.href = URL.createObjectURL(blob)
          link.download = safeName(String(file.relativePath).split('/').pop())
          document.body.appendChild(link)
          link.click()
          link.remove()
          setTimeout(() => URL.revokeObjectURL(link.href), 30000)
        }
        setProgress(done, total)
      }
      setStatus('Arquivos recebidos pela rede local.', 'success')
    } catch (error) {
      setStatus(error.message || 'Falha ao receber os arquivos.', 'error')
    } finally { setBusy(false) }
  }

  for (const id of ['transferGalleryInput','transferFilesInput','transferPhotoInput','transferVideoInput']) {
    $(id).addEventListener('change', (event) => setSelected(event.target.files))
  }
  for (const id of ['transferSendCode']) {
    $(id).addEventListener('input', (event) => { event.target.value = normalizeCode(event.target.value); refreshSendButton() })
  }
  $('transferSendButton').addEventListener('click', sendFiles)
  $('transferReceiveButton').addEventListener('click', receiveFiles)
  $('transferHookBack').addEventListener('click', () => window.vshookExitToProjectSelector?.())
})()
