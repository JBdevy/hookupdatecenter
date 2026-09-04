/* VS_HOOK_UI_FEEDBACK_V1 — som e vibracao de toque dos apps.

   Sai de fabrica DESLIGADO: o Diretor roda ao vivo e ninguem pode ser pego de
   surpresa no meio do culto ou do show. Liga em CONFIGURACOES > SOM.

   O clique e sintetizado na hora pelo Web Audio, sem arquivo de audio e sem
   plugin: o mesmo codigo vale para iPhone, Android e para o app que abre no
   navegador. A vibracao usa o Haptics do Capacitor quando ele existe e cai
   para navigator.vibrate no Android; no iPhone sem o plugin so fica o som.

   O audio do WebView usa a categoria ambiente, entao a chavinha de silencioso
   do iPhone tambem cala estes cliques. Isso e proposital e NAO deve ser
   "corrigido": quem colocou o aparelho no silencioso decidiu ficar em
   silencio, e nenhum retorno de interface tem o direito de passar por cima
   disso. Nao troque a categoria da sessao de audio no projeto iOS para forcar
   o som. A vibracao continua, que e o retorno que o proprio sistema mantem no
   modo silencioso. */

;(function () {
  'use strict'

  var STORAGE_KEY = 'vshook_ui_sound'
  var SCROLL_TICK_DISTANCE = 34 // altura aproximada de uma linha da lista
  var SCROLL_TICK_INTERVAL = 45

  var audioContext = null
  var enabled = readEnabled()
  var scrollPositions = new WeakMap()
  var lastScrollTickAt = 0

  function readEnabled() {
    try { return localStorage.getItem(STORAGE_KEY) === 'on' } catch (error) { return false }
  }

  function writeEnabled(value) {
    try { localStorage.setItem(STORAGE_KEY, value ? 'on' : 'off') } catch (error) {}
  }

  // O iPhone so deixa criar/retomar o audio dentro de um gesto do usuario,
  // por isso o contexto nasce no primeiro toque e nao no carregamento.
  function getAudioContext() {
    if (!enabled) return null
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
    if (!enabled) return
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
    isEnabled: function () { return enabled },
    setEnabled: function (value) {
      enabled = !!value
      writeEnabled(enabled)
      if (enabled) feedback.press()
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

  // Botao responde no pointerdown para o som sair junto com o dedo.
  document.addEventListener('pointerdown', function (event) {
    if (!enabled) return
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
    if (!enabled) return
    var element = findTarget(event.target)
    if (!element || isDisabled(element) || !isSelectionRow(element)) return
    feedback.select()
  }, true)

  document.addEventListener('scroll', function (event) {
    if (!enabled) return
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

  window.vshookUiFeedback = feedback
})()
