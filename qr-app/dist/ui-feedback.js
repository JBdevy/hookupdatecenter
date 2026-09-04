/* VS_HOOK_UI_FEEDBACK_V2 — som e vibracao de toque dos apps.

   Os dois saem de fabrica DESLIGADOS e sao independentes: da para deixar so a
   vibracao, so o som, os dois ou nenhum. O Diretor roda ao vivo e ninguem pode
   ser pego de surpresa no meio do culto ou do show. Liga em CONFIGURACOES.

   O clique e sintetizado na hora pelo Web Audio, sem arquivo de audio e sem
   plugin: o mesmo codigo vale para iPhone, Android e para o app que abre no
   navegador pelo Hook Center.

   SILENCIOSO MANDA. Quem colocou o aparelho no silencioso decidiu ficar em
   silencio, e nenhum retorno de interface tem o direito de passar por cima
   disso — nem o som, nem a vibracao. O audio do WebView ja e da categoria
   ambiente, entao o proprio sistema corta o som em qualquer lugar; NAO troque
   a categoria da sessao de audio no projeto iOS para forcar.

   A vibracao ninguem corta, entao ela e travada aqui pelo plugin
   vshook-silent-switch, que le o estado real do aparelho. Sem resposta dele a
   vibracao fica parada, em vez de arriscar desrespeitar. Por isso ela so
   funciona nos apps da loja: no navegador nenhum site consegue ler a chavinha
   de silencioso, e o navigator.vibrate do Android chacoalharia o aparelho
   mesmo em silencio. La fica so o som, que o sistema ja sabe calar. */

;(function () {
  'use strict'

  var SOUND_KEY = 'vshook_ui_sound'
  var VIBRATE_KEY = 'vshook_ui_vibrate'
  var SCROLL_TICK_DISTANCE = 34 // altura aproximada de uma linha da lista
  var SCROLL_TICK_INTERVAL = 45
  var SILENT_CACHE_MS = 2000

  var audioContext = null
  var soundEnabled = readFlag(SOUND_KEY)
  var vibrateEnabled = readFlag(VIBRATE_KEY)
  var scrollPositions = new WeakMap()
  var lastScrollTickAt = 0

  // Consultar o estado do aparelho custa caro no iPhone (toca um som mudo de
  // 0,2 s), entao a resposta vale por alguns segundos e e renovada em segundo
  // plano. Enquanto a primeira resposta nao chega, dentro do app nao vibra.
  var silentMode = null
  var silentCheckedAt = 0
  var silentChecking = false

  function readFlag(key) {
    try { return localStorage.getItem(key) === 'on' } catch (error) { return false }
  }

  function writeFlag(key, value) {
    try { localStorage.setItem(key, value ? 'on' : 'off') } catch (error) {}
  }

  function silentPlugin() {
    try {
      return (window.Capacitor && window.Capacitor.Plugins &&
        window.Capacitor.Plugins.VSHookSilentSwitch) || null
    } catch (error) {
      return null
    }
  }

  function refreshSilentMode() {
    var plugin = silentPlugin()
    if (!plugin || silentChecking) return
    if (silentCheckedAt && Date.now() - silentCheckedAt < SILENT_CACHE_MS) return
    silentChecking = true
    Promise.resolve()
      .then(function () { return plugin.getStatus() })
      .then(function (status) {
        silentMode = status && status.supported === false
          ? 'normal'
          : (status && status.mode) || 'normal'
      })
      .catch(function () { silentMode = 'normal' })
      .then(function () {
        silentCheckedAt = Date.now()
        silentChecking = false
      })
  }

  // Dentro do app o plugin diz o estado real do aparelho; sem resposta dele a
  // vibracao fica parada.
  function vibrationAllowed() {
    refreshSilentMode()
    if (silentMode === null) return false
    return silentMode !== 'silent'
  }

  // O iPhone so deixa criar/retomar o audio dentro de um gesto do usuario,
  // por isso o contexto nasce no primeiro toque e nao no carregamento.
  function getAudioContext() {
    if (!soundEnabled) return null
    var Ctor = window.AudioContext || window.webkitAudioContext
    if (!Ctor) return null
    try {
      if (!audioContext) audioContext = new Ctor()
      if (audioContext.state === 'suspended') audioContext.resume()
      return audioContext
    } catch (error) {
      return null
    }
  }

  function playTone(options) {
    var context = getAudioContext()
    if (!context) return
    try {
      var now = context.currentTime
      var duration = Math.max(0.004, Number(options.duration) || 0.014)
      var peak = Math.max(0.001, Number(options.gain) || 0.05)
      var oscillator = context.createOscillator()
      var amplifier = context.createGain()
      oscillator.type = options.type || 'sine'
      oscillator.frequency.setValueAtTime(Number(options.from) || 1400, now)
      if (options.to) {
        oscillator.frequency.exponentialRampToValueAtTime(Number(options.to), now + duration)
      }
      // Envelope curto: sem o corte suave o clique estala no alto-falante.
      amplifier.gain.setValueAtTime(0.0001, now)
      amplifier.gain.exponentialRampToValueAtTime(peak, now + 0.004)
      amplifier.gain.exponentialRampToValueAtTime(0.0001, now + duration)
      oscillator.connect(amplifier)
      amplifier.connect(context.destination)
      oscillator.start(now)
      oscillator.stop(now + duration + 0.02)
    } catch (error) {}
  }

  function vibrate(style) {
    if (!vibrateEnabled || !vibrationAllowed()) return
    try {
      var haptics = window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.Haptics
      if (haptics && typeof haptics.impact === 'function') {
        haptics.impact({ style: style || 'Light' })
        return
      }
    } catch (error) {}
    try {
      if (typeof navigator.vibrate === 'function') navigator.vibrate(style === 'Medium' ? 14 : 8)
    } catch (error) {}
  }

  var feedback = {
    isSoundEnabled: function () { return soundEnabled },
    isVibrateEnabled: function () { return vibrateEnabled },
    setSoundEnabled: function (value) {
      soundEnabled = !!value
      writeFlag(SOUND_KEY, soundEnabled)
      if (soundEnabled) feedback.press()
    },
    setVibrateEnabled: function (value) {
      vibrateEnabled = !!value
      writeFlag(VIBRATE_KEY, vibrateEnabled)
      if (vibrateEnabled) {
        silentCheckedAt = 0
        refreshSilentMode()
        vibrate('Medium')
      }
    },
    press: function () {
      playTone({ type: 'triangle', from: 1500, duration: 0.013, gain: 0.05 })
      vibrate('Light')
    },
    toggle: function (turningOn) {
      playTone(turningOn
        ? { type: 'sine', from: 680, to: 1020, duration: 0.055, gain: 0.06 }
        : { type: 'sine', from: 680, to: 430, duration: 0.055, gain: 0.06 })
      vibrate('Medium')
    },
    select: function () {
      playTone({ type: 'triangle', from: 940, duration: 0.02, gain: 0.045 })
      vibrate('Light')
    },
    tick: function () {
      playTone({ type: 'sine', from: 2200, duration: 0.006, gain: 0.016 })
    },
  }

  function active() {
    return soundEnabled || vibrateEnabled
  }

  function isDisabled(element) {
    return element.disabled === true ||
      element.getAttribute('aria-disabled') === 'true' ||
      element.classList.contains('btnDisabled')
  }

  function findTarget(node) {
    var element = node && node.nodeType === 1 ? node : (node && node.parentElement)
    while (element && element !== document.body) {
      if (element.matches('button, [data-action], [role="button"], .btn, .nav-item, .item, .tab, input[type="checkbox"], label')) {
        return element
      }
      element = element.parentElement
    }
    return null
  }

  function isSelectionRow(element) {
    return element.matches('.item, [data-marker-id], [data-song-id], [data-region-id]') ||
      element.getAttribute('data-action') === 'select-item'
  }

  // Estado ligado/desligado que o proprio app ja marca no botao. Com ele o
  // toque de ativar e o de desativar ficam diferentes.
  function readToggleState(element) {
    var pressed = element.getAttribute('aria-pressed')
    if (pressed === 'true') return true
    if (pressed === 'false') return false
    var classes = String(element.className || '')
    if (/(?:^|\s)[\w-]*(?:Active|OnGreen)(?:\s|$)/.test(classes)) return true
    if (/(?:^|\s)[\w-]*OffRed(?:\s|$)/.test(classes)) return false
    if (element.type === 'checkbox') return element.checked === true
    return null
  }

  // Botao responde no pointerdown para o retorno sair junto com o dedo.
  document.addEventListener('pointerdown', function (event) {
    if (!active()) return
    var element = findTarget(event.target)
    if (!element || isDisabled(element)) return
    // Linha de lista fica de fora: encostar nela para rolar nao e escolher.
    if (isSelectionRow(element)) return
    var state = readToggleState(element)
    if (state === null) feedback.press()
    else feedback.toggle(!state)
  }, true)

  // A linha da lista soa no click, que so acontece quando o toque virou
  // escolha de verdade e nao rolagem.
  document.addEventListener('click', function (event) {
    if (!active()) return
    var element = findTarget(event.target)
    if (!element || isDisabled(element) || !isSelectionRow(element)) return
    feedback.select()
  }, true)

  document.addEventListener('scroll', function (event) {
    if (!soundEnabled) return
    var element = event.target
    if (!element || element.nodeType !== 1) return
    if (!element.matches('.listBox, .markerListBox, .musicosListBox, [data-scroll-tick]')) return
    var previous = scrollPositions.get(element)
    var current = element.scrollTop
    if (previous === undefined) { scrollPositions.set(element, current); return }
    if (Math.abs(current - previous) < SCROLL_TICK_DISTANCE) return
    scrollPositions.set(element, current)
    var now = Date.now()
    if (now - lastScrollTickAt < SCROLL_TICK_INTERVAL) return
    lastScrollTickAt = now
    feedback.tick()
  }, true)

  // O usuario pode mexer na chavinha de silencioso com o app aberto.
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState !== 'visible') return
    silentCheckedAt = 0
    refreshSilentMode()
  })

  if (vibrateEnabled) refreshSilentMode()

  window.vshookUiFeedback = feedback
})()
