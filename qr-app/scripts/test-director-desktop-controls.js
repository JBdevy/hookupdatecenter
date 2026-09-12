const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const source = fs.readFileSync(path.resolve(__dirname, '..', 'vsdiretor.js'), 'utf8').replace(/\r\n/g, '\n')
const extract = (name) => {
  const start = source.indexOf('  function ' + name + '(')
  assert(start >= 0, name + ' ausente')
  const next = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(next >= 0, name + ' sem fim')
  return source.slice(start, start + 1 + next)
}
const viewport = { closest: () => ({}) }
const state = {
  showTelepromptScreen: true, telepromptFullscreen: false,
  authAuthenticated: true, bridgeOnline: true, snapshot: {},
  showTabletSearch: false, showRecadosScreen: false, showMenu: false,
}
let renders = 0
let plays = 0
let finePointer = true
let modal = null
const document = { activeElement: null }
const root = { querySelector: () => modal }
const window = { matchMedia: () => ({ matches: finePointer }) }
const mouse = new Function('state', 'window', 'scheduleRender',
  extract('handleTelepromptMouseDoubleClick') + '\nreturn handleTelepromptMouseDoubleClick')(state, window, () => renders++)
const space = new Function('state', 'document', 'root', 'handlePlay',
  extract('handleDesktopTransportSpace') + '\nreturn handleDesktopTransportSpace')(state, document, root, () => plays++)
const mouseEvent = (extra = {}) => ({
  button: 0, target: { closest: (s) => s === '[data-director-tp-viewport]' ? viewport : null },
  preventDefault() { this.prevented = true }, ...extra,
})
mouse(mouseEvent())
assert.equal(state.telepromptFullscreen, true)
mouse(mouseEvent())
assert.equal(state.telepromptFullscreen, false)
assert.equal(renders, 2)
mouse(mouseEvent({ sourceCapabilities: { firesTouchEvents: true } }))
finePointer = false
mouse(mouseEvent())
finePointer = true
mouse(mouseEvent({ button: 2 }))
mouse(mouseEvent({ target: { closest: () => null } }))
mouse(mouseEvent({ target: { closest: (s) => s.includes('button') ? {} : viewport } }))
state.showTelepromptScreen = false
mouse(mouseEvent())
assert.equal(renders, 2, 'toque, botoes, fora do TP e botao direito nao devem ampliar')
state.showTelepromptScreen = true

const spaceEvent = (extra = {}) => ({
  code: 'Space', key: ' ', target: { closest: () => null },
  preventDefault() { this.prevented = true },
  stopImmediatePropagation() { this.stopped = true }, ...extra,
})
let event = spaceEvent()
space(event)
assert.equal(plays, 1)
assert(event.prevented && event.stopped)
event = spaceEvent({ repeat: true })
space(event)
assert(event.prevented, 'segurar espaco nao pode rolar a pagina')
assert.equal(plays, 1, 'segurar espaco nao pode disparar varios Play/Stop')
for (const extra of [
  { ctrlKey: true }, { metaKey: true }, { altKey: true }, { shiftKey: true },
  { isComposing: true }, { defaultPrevented: true }, { code: 'KeyA', key: 'a' },
  { target: { closest: () => ({}) } },
]) space(spaceEvent(extra))
document.activeElement = { closest: () => ({}) }
space(spaceEvent())
document.activeElement = null
modal = {}
space(spaceEvent())
modal = null
for (const flag of ['showTabletSearch', 'showRecadosScreen', 'showMenu']) {
  state[flag] = true
  space(spaceEvent())
  state[flag] = false
}
for (const flag of ['authAuthenticated', 'bridgeOnline']) {
  state[flag] = false
  space(spaceEvent())
  state[flag] = true
}
assert.equal(plays, 1, 'espaco nao deve controlar transporte enquanto digita ou esta desconectado')

const inputs = {}
const ids = ['timerCountdownHours', 'timerCountdownMinutes', 'timerCountdownSeconds']
for (const id of ids) inputs[id] = {
  id, value: '00', matches: () => true,
  closest: () => ({ setAttribute() {} }),
  focus() {}, getAttribute: () => id === ids[0] ? 99 : 59,
}
document.getElementById = (id) => inputs[id]
root.querySelectorAll = () => Object.values(inputs)
state.showTimerModal = true
state.timerKeyboardField = ids[0]
state.timerKeyboardDigits = 0
const targets = []
const keypad = new Function('state', 'document', 'root', 'useTabletSearchKeyboard',
  'normalizeTimerCountdownInput', 'applyCountdownTarget', 'readCountdownInputs',
  extract('applyTimerKeyboardKey') + '\n' + extract('syncTimerKeyboardFieldDom') + '\nreturn applyTimerKeyboardKey')(
  state, document, root, () => true,
  (input) => { input.value = String(Math.min(input.getAttribute(), Number(input.value))).padStart(2, '0') },
  (target) => targets.push(target),
  () => Number(inputs[ids[0]].value) * 3600 + Number(inputs[ids[1]].value) * 60 + Number(inputs[ids[2]].value),
)
for (const key of ['0', '1', '3', '0', '4', '5']) keypad(key)
assert.equal(inputs[ids[0]].value, '01')
assert.equal(inputs[ids[1]].value, '30')
assert.equal(inputs[ids[2]].value, '45')
assert.equal(targets.at(-1), 5445)
keypad('clear')
assert.equal(inputs[ids[2]].value, '00')
keypad('5'); keypad('9'); keypad('backspace')
assert.equal(inputs[ids[2]].value, '05')
keypad('9'); keypad('9')
assert.equal(inputs[ids[2]].value, '59', 'segundos devem respeitar o limite')

const render = extract('renderTimerModal')
assert(render.indexOf('data-action="timer-toggle"') < render.indexOf('data-action="timer-init-auto"'))
assert(render.indexOf('data-action="timer-init-auto"') < render.indexOf('data-action="modal-close"'))
assert.match(render, /inputmode="\$\{ownKeyboard \? 'none' : 'numeric'\}"/)
assert.match(render, /readonly aria-readonly="true"/)
assert.match(extract('toggleTimerInitAuto'), /postCommand\('timer_set_init_auto', \{ initAutoEnabled: enabled \}\)/)
assert.match(extract('getTimerInitAutoEnabled'), /bridgeControlStateSettled/)
assert.match(source, /repeatableKeyboardAction = action === 'tablet-search-key' \|\| action === 'timer-key'/)
const styles = fs.readFileSync(path.resolve(__dirname, '..', 'stylediretor-app.css'), 'utf8')
assert.match(styles, /\.directorTpOverlay \*[\s\S]{0,150}?scrollbar-width: none/)
assert.match(styles, /\.directorTpOverlay \*::-webkit-scrollbar[\s\S]{0,100}?display: none/)
assert.match(styles, /html\[data-director-device="tablet"\] \.app:not\(\.musicianMonitor\) > \.timerModalOverlay[\s\S]{0,200}?justify-content: flex-start/)
let settled = false
const getInitAuto = new Function('state', 'bridgeControlStateSettled',
  extract('getTimerInitAutoEnabled') + '\nreturn getTimerInitAutoEnabled')(state, () => settled)
state.pendingTimerInitAuto = null
state.snapshot = { timerInitAutoEnabled: true }
const commands = []
const toggleInitAuto = new Function('state', 'getTimerInitAutoEnabled', 'now',
  'armBridgeControlStability', 'postCommand', 'syncTimerModalDom',
  extract('toggleTimerInitAuto') + '\nreturn toggleTimerInitAuto')(
  state, getInitAuto, () => 1000, () => {}, (type, payload) => commands.push({ type, payload }), () => {},
)
toggleInitAuto()
assert.equal(commands.at(-1).type, 'timer_set_init_auto')
assert.equal(commands.at(-1).payload.initAutoEnabled, false)
assert.equal(getInitAuto(), false, 'snapshot antigo nao pode desfazer o toque')
toggleInitAuto()
assert.equal(commands.at(-1).payload.initAutoEnabled, true, 'segundo toque alterna o estado local')
settled = true
state.snapshot = { timerInitAutoEnabled: false, timer: { initAutoEnabled: true } }
assert.equal(getInitAuto(), false, 'false explicito deve prevalecer sobre campo legado')
let ownKeyboard = true
state.showTimerModal = true
state.snapshot = {}
const renderModal = new Function('state', 'getEffectiveTimerMode', 'splitCountdownSec',
  'getCountdownTargetSec', 'useTabletSearchKeyboard', 'getTimerInitAutoEnabled',
  'isCountdownOverrun', 'getTimerDisplayText', 'escapeHtml',
  extract('renderTimerModal') + '\n' + extract('renderTimerKeyboard') + '\nreturn renderTimerModal')(
  state, () => 'countdown', () => ({ hours: 1, minutes: 30, seconds: 45 }),
  () => 5445, () => ownKeyboard, () => false, () => false, () => '01:30:45', (value) => value,
)
let html = renderModal()
assert.equal((html.match(/readonly aria-readonly="true"/g) || []).length, 3)
assert.equal((html.match(/inputmode="none"/g) || []).length, 3)
assert(html.includes('class="timerKeyboard"'))
ownKeyboard = false
html = renderModal()
assert(!html.includes('readonly'))
assert(!html.includes('class="timerKeyboard"'))
assert.equal((html.match(/inputmode="numeric"/g) || []).length, 3)
const scrollbarCss = fs.readFileSync(path.resolve(__dirname, '..', 'scrollbars.css'), 'utf8')
assert(scrollbarCss.includes('scrollbar-width: none !important'))
assert(scrollbarCss.includes('scrollbar-gutter: auto !important'))
assert(scrollbarCss.includes('*::-webkit-scrollbar'))
assert(!/\boverflow(?:-[xy])?\s*:/.test(scrollbarCss), 'ocultar barras nao pode bloquear rolagem')
for (const file of ['app-shell.css', 'stylediretor.css', 'stylediretor-app.css']) {
  const css = fs.readFileSync(path.resolve(__dirname, '..', file), 'utf8')
  assert(css.includes('@import url("./scrollbars.css")'), file + ' deve ocultar barras inclusive fora do TP')
}
console.log('DIRECTOR_DESKTOP_TIMER_CONTROLS_OK')
