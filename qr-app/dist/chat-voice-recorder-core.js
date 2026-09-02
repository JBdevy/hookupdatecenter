(() => {
  const LIMIT = 20 * 1024 * 1024
  const mime = () => typeof MediaRecorder === 'undefined' ? '' : (['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm', 'audio/ogg;codecs=opus'].find((type) => { try { return MediaRecorder.isTypeSupported(type) } catch (_) { return false } }) || '')
  const friendly = (error) => {
    const name = String(error?.name || '')
    if (name === 'NotAllowedError' || name === 'PermissionDeniedError') return 'Permita o acesso ao microfone para gravar uma mensagem de voz.'
    if (name === 'NotFoundError' || name === 'DevicesNotFoundError') return 'Nenhum microfone foi encontrado neste dispositivo.'
    if (name === 'NotReadableError' || name === 'TrackStartError') return 'O microfone está sendo usado por outro aplicativo.'
    return error?.message || 'Não foi possível iniciar o microfone.'
  }
  const payload = (blob, durationSeconds) => new Promise((resolve, reject) => {
    if (!blob?.size) return reject(new Error('A gravação ficou vazia. Tente novamente.'))
    if (blob.size > LIMIT) return reject(new Error('A mensagem de voz deve ter no máximo 20 MB.'))
    const reader = new FileReader()
    reader.onerror = () => reject(new Error('Não foi possível preparar a mensagem de voz.'))
    reader.onload = () => {
      const dataUrl = String(reader.result || '')
      const base64 = dataUrl.includes(',') ? dataUrl.slice(dataUrl.indexOf(',') + 1) : ''
      if (!base64) return reject(new Error('A gravação ficou inválida. Tente novamente.'))
      resolve({ kind: 'audio', recorded: true, mimeType: String(blob.type || 'audio/wav').split(';')[0].toLowerCase(), base64, dataUrl, durationSeconds })
    }
    reader.readAsDataURL(blob)
  })
  const wav = (chunks, sampleRate) => {
    const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0)
    const buffer = new ArrayBuffer(44 + length * 2)
    const view = new DataView(buffer)
    const text = (offset, value) => { for (let i = 0; i < value.length; i += 1) view.setUint8(offset + i, value.charCodeAt(i)) }
    text(0, 'RIFF'); view.setUint32(4, 36 + length * 2, true); text(8, 'WAVE'); text(12, 'fmt ')
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, length * 2, true)
    let offset = 44
    chunks.forEach((chunk) => { for (let i = 0; i < chunk.length; i += 1) { const sample = Math.max(-1, Math.min(1, chunk[i])); view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true); offset += 2 } })
    return new Blob([buffer], { type: 'audio/wav' })
  }
  class VoiceRecorder {
    constructor() { this.stream = null; this.recorder = null; this.chunks = []; this.context = null; this.source = null; this.processor = null; this.gain = null; this.pcm = []; this.rate = 48000; this.startedAt = 0; this.active = false }
    async start() {
      if (this.active) return
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('Este dispositivo não oferece gravação pelo microfone.')
      try { this.stream = await navigator.mediaDevices.getUserMedia({ video: false, audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } }) } catch (error) { throw new Error(friendly(error)) }
      this.startedAt = performance.now(); this.active = true
      if (typeof MediaRecorder !== 'undefined') {
        try { const type = mime(); this.recorder = type ? new MediaRecorder(this.stream, { mimeType: type, audioBitsPerSecond: 64000 }) : new MediaRecorder(this.stream); this.recorder.addEventListener('dataavailable', (event) => { if (event.data?.size) this.chunks.push(event.data) }); this.recorder.start(250); return } catch (_) { this.recorder = null; this.chunks = [] }
      }
      const Context = window.AudioContext || window.webkitAudioContext
      if (!Context) { this.cleanup(); throw new Error('A gravação de voz não é compatível com este dispositivo.') }
      this.context = new Context(); if (this.context.state === 'suspended') await this.context.resume(); this.rate = this.context.sampleRate || 48000
      this.source = this.context.createMediaStreamSource(this.stream); this.processor = this.context.createScriptProcessor(4096, 1, 1); this.gain = this.context.createGain(); this.gain.gain.value = 0
      this.processor.onaudioprocess = (event) => { if (this.active) this.pcm.push(new Float32Array(event.inputBuffer.getChannelData(0))) }
      this.source.connect(this.processor); this.processor.connect(this.gain); this.gain.connect(this.context.destination)
    }
    elapsedSeconds() { return this.startedAt ? Math.max(0, (performance.now() - this.startedAt) / 1000) : 0 }
    async stop() {
      if (!this.active) throw new Error('Nenhuma gravação está ativa.')
      const duration = this.elapsedSeconds(); let blob
      if (this.recorder) blob = await new Promise((resolve, reject) => { const recorder = this.recorder; recorder.addEventListener('stop', () => resolve(new Blob(this.chunks, { type: String(recorder.mimeType || this.chunks[0]?.type || 'audio/webm') })), { once: true }); recorder.addEventListener('error', () => reject(new Error('A gravação de voz foi interrompida.')), { once: true }); try { if (recorder.state === 'recording') recorder.requestData(); recorder.stop() } catch (error) { reject(error) } })
      else blob = wav(this.pcm, this.rate)
      this.active = false; this.cleanup(); return payload(blob, duration)
    }
    cancel() { this.active = false; if (this.recorder && this.recorder.state !== 'inactive') try { this.recorder.stop() } catch (_) {}; this.cleanup() }
    cleanup() { if (this.processor) { this.processor.onaudioprocess = null; try { this.processor.disconnect() } catch (_) {} } if (this.source) try { this.source.disconnect() } catch (_) {} if (this.gain) try { this.gain.disconnect() } catch (_) {} if (this.context) this.context.close().catch(() => {}); if (this.stream) this.stream.getTracks().forEach((track) => track.stop()); this.stream = null; this.recorder = null; this.context = null; this.source = null; this.processor = null; this.gain = null; this.chunks = []; this.pcm = []; this.startedAt = 0 }
  }
  window.VSHookVoiceRecorder = VoiceRecorder
})()
