(() => {
  const MAX_AUDIO_BYTES = 20 * 1024 * 1024

  function preferredMimeType() {
    if (typeof MediaRecorder === 'undefined') return ''
    const candidates = [
      'audio/webm;codecs=opus',
      'audio/mp4',
      'audio/webm',
      'audio/ogg;codecs=opus'
    ]
    return candidates.find((type) => {
      try { return MediaRecorder.isTypeSupported(type) } catch (_) { return false }
    }) || ''
  }

  function friendlyMicrophoneError(error) {
    const name = String(error?.name || '')
    if (name === 'NotAllowedError' || name === 'PermissionDeniedError') {
      return 'Permita o acesso ao microfone para gravar uma mensagem de voz.'
    }
    if (name === 'NotFoundError' || name === 'DevicesNotFoundError') {
      return 'Nenhum microfone foi encontrado neste dispositivo.'
    }
    if (name === 'NotReadableError' || name === 'TrackStartError') {
      return 'O microfone está sendo usado por outro aplicativo.'
    }
    return error?.message || 'Não foi possível iniciar o microfone.'
  }

  function blobAsPayload(blob, durationSeconds) {
    return new Promise((resolve, reject) => {
      if (!blob?.size) return reject(new Error('A gravação ficou vazia. Tente novamente.'))
      if (blob.size > MAX_AUDIO_BYTES) return reject(new Error('A mensagem de voz deve ter no máximo 20 MB.'))
      const reader = new FileReader()
      reader.onerror = () => reject(new Error('Não foi possível preparar a mensagem de voz.'))
      reader.onload = () => {
        const dataUrl = String(reader.result || '')
        const base64 = dataUrl.includes(',') ? dataUrl.slice(dataUrl.indexOf(',') + 1) : ''
        if (!base64) return reject(new Error('A gravação ficou inválida. Tente novamente.'))
        resolve({
          kind: 'audio',
          recorded: true,
          mimeType: String(blob.type || 'audio/wav').split(';')[0].toLowerCase(),
          base64,
          dataUrl,
          durationSeconds: Math.max(0, Number(durationSeconds) || 0)
        })
      }
      reader.readAsDataURL(blob)
    })
  }

  function encodeMonoWav(chunks, sampleRate) {
    const length = chunks.reduce((total, chunk) => total + chunk.length, 0)
    const buffer = new ArrayBuffer(44 + length * 2)
    const view = new DataView(buffer)
    const writeText = (offset, text) => {
      for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i))
    }
    writeText(0, 'RIFF')
    view.setUint32(4, 36 + length * 2, true)
    writeText(8, 'WAVE')
    writeText(12, 'fmt ')
    view.setUint32(16, 16, true)
    view.setUint16(20, 1, true)
    view.setUint16(22, 1, true)
    view.setUint32(24, sampleRate, true)
    view.setUint32(28, sampleRate * 2, true)
    view.setUint16(32, 2, true)
    view.setUint16(34, 16, true)
    writeText(36, 'data')
    view.setUint32(40, length * 2, true)
    let offset = 44
    chunks.forEach((chunk) => {
      for (let i = 0; i < chunk.length; i += 1) {
        const sample = Math.max(-1, Math.min(1, chunk[i]))
        view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true)
        offset += 2
      }
    })
    return new Blob([buffer], { type: 'audio/wav' })
  }

  class VoiceRecorder {
    constructor() {
      this.stream = null
      this.recorder = null
      this.chunks = []
      this.audioContext = null
      this.sourceNode = null
      this.processorNode = null
      this.silentGain = null
      this.pcmChunks = []
      this.sampleRate = 48000
      this.startedAt = 0
      this.active = false
    }

    async start() {
      if (this.active) return
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error('Este dispositivo não oferece gravação pelo microfone.')
      }
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({
          video: false,
          audio: {
            channelCount: 1,
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true
          }
        })
      } catch (error) {
        throw new Error(friendlyMicrophoneError(error))
      }
      this.startedAt = performance.now()
      this.active = true
      const mimeType = preferredMimeType()
      if (typeof MediaRecorder !== 'undefined') {
        try {
          this.chunks = []
          this.recorder = mimeType
            ? new MediaRecorder(this.stream, { mimeType, audioBitsPerSecond: 64000 })
            : new MediaRecorder(this.stream)
          this.recorder.addEventListener('dataavailable', (event) => {
            if (event.data?.size) this.chunks.push(event.data)
          })
          this.recorder.start(250)
          return
        } catch (_) {
          this.recorder = null
          this.chunks = []
        }
      }
      await this.startWavFallback()
    }

    async startWavFallback() {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext
      if (!AudioContextClass) {
        this.cleanup()
        throw new Error('A gravação de voz não é compatível com este dispositivo.')
      }
      this.audioContext = new AudioContextClass()
      if (this.audioContext.state === 'suspended') await this.audioContext.resume()
      this.sampleRate = this.audioContext.sampleRate || 48000
      this.pcmChunks = []
      this.sourceNode = this.audioContext.createMediaStreamSource(this.stream)
      this.processorNode = this.audioContext.createScriptProcessor(4096, 1, 1)
      this.silentGain = this.audioContext.createGain()
      this.silentGain.gain.value = 0
      this.processorNode.onaudioprocess = (event) => {
        if (!this.active) return
        this.pcmChunks.push(new Float32Array(event.inputBuffer.getChannelData(0)))
      }
      this.sourceNode.connect(this.processorNode)
      this.processorNode.connect(this.silentGain)
      this.silentGain.connect(this.audioContext.destination)
    }

    elapsedSeconds() {
      return this.startedAt ? Math.max(0, (performance.now() - this.startedAt) / 1000) : 0
    }

    async stop() {
      if (!this.active) throw new Error('Nenhuma gravação está ativa.')
      const durationSeconds = this.elapsedSeconds()
      let blob
      if (this.recorder) {
        blob = await new Promise((resolve, reject) => {
          const recorder = this.recorder
          recorder.addEventListener('stop', () => {
            const type = String(recorder.mimeType || this.chunks[0]?.type || 'audio/webm')
            resolve(new Blob(this.chunks, { type }))
          }, { once: true })
          recorder.addEventListener('error', () => reject(new Error('A gravação de voz foi interrompida.')), { once: true })
          try {
            if (recorder.state === 'recording') recorder.requestData()
            recorder.stop()
          } catch (error) { reject(error) }
        })
      } else {
        blob = encodeMonoWav(this.pcmChunks, this.sampleRate)
      }
      this.active = false
      this.cleanup()
      return blobAsPayload(blob, durationSeconds)
    }

    cancel() {
      this.active = false
      if (this.recorder && this.recorder.state !== 'inactive') {
        try { this.recorder.stop() } catch (_) {}
      }
      this.cleanup()
    }

    cleanup() {
      if (this.processorNode) {
        this.processorNode.onaudioprocess = null
        try { this.processorNode.disconnect() } catch (_) {}
      }
      if (this.sourceNode) try { this.sourceNode.disconnect() } catch (_) {}
      if (this.silentGain) try { this.silentGain.disconnect() } catch (_) {}
      if (this.audioContext) this.audioContext.close().catch(() => {})
      if (this.stream) this.stream.getTracks().forEach((track) => track.stop())
      this.stream = null
      this.recorder = null
      this.audioContext = null
      this.sourceNode = null
      this.processorNode = null
      this.silentGain = null
      this.chunks = []
      this.pcmChunks = []
      this.startedAt = 0
    }
  }

  window.VSHookVoiceRecorder = VoiceRecorder
})()
