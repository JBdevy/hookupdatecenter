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
const useTimerKeyboard = new Function('state', extract('useTimerKeyboard') + '\nreturn useTimerKeyboard')(state)
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
  closest: (selector) => selector === 'label' ? { setAttribute() {} } : null,
  focus() {}, getAttribute: () => id === ids[0] ? 99 : 59,
}
document.getElementById = (id) => inputs[id]
root.querySelectorAll = () => Object.values(inputs)
state.showTimerModal = true
state.timerKeyboardField = ids[0]
state.timerKeyboardCaret = 0
const targets = []
const keypad = new Function('state', 'document', 'root', 'useTimerKeyboard',
  'normalizeTimerCountdownInput', 'applyCountdownTarget', 'readCountdownInputs',
  extract('editTimerCountdownDigits') + '\n' + extract('selectTimerKeyboardField') + '\n' + extract('applyTimerKeyboardKey') + '\n' + extract('syncTimerKeyboardFieldDom') + '\nreturn { key: applyTimerKeyboardKey, select: selectTimerKeyboardField }')(
  state, document, root, useTimerKeyboard,
  (input) => { input.value = String(Math.min(input.getAttribute(), Number(input.value))).padStart(2, '0') },
  (target) => targets.push(target),
  () => Number(inputs[ids[0]].value) * 3600 + Number(inputs[ids[1]].value) * 60 + Number(inputs[ids[2]].value),
)
keypad.select(inputs[ids[0]], 0)
keypad.key('0'); keypad.key('1')
keypad.select(inputs[ids[1]], 0)
keypad.key('3'); keypad.key('0')
keypad.select(inputs[ids[2]], 0)
keypad.key('4'); keypad.key('5')
assert.equal(inputs[ids[0]].value, '01')
assert.equal(inputs[ids[1]].value, '30')
assert.equal(inputs[ids[2]].value, '45')
assert.equal(targets.at(-1), 5445)
keypad.key('clear')
assert.equal(inputs[ids[2]].value, '00')
keypad.key('5'); keypad.key('9'); keypad.key('backspace')
assert.equal(inputs[ids[2]].value, '50', 'apagar deve respeitar o cursor, nao o fim do campo')
keypad.key('9'); keypad.key('9')
assert.equal(inputs[ids[2]].value, '59', 'segundos devem respeitar o limite')
assert.equal(state.timerKeyboardField, ids[2], 'digitar nao deve trocar de campo sozinho')
const editDigits = new Function(extract('editTimerCountdownDigits') + '\nreturn editTimerCountdownDigits')()
assert.deepEqual(editDigits('30', '8', 0), { value: '80', caret: 1 })
assert.deepEqual(editDigits('30', '8', 1), { value: '38', caret: 2 })
assert.deepEqual(editDigits('30', 'backspace', 0), { value: '30', caret: 0 })
assert.deepEqual(editDigits('30', 'backspace', 1), { value: '00', caret: 0 })
assert.deepEqual(editDigits('38', 'delete', 1), { value: '30', caret: 1 })
assert.equal(editDigits('30', 'invalid', 1), null)
const pointerCaret = new Function('state', extract('getTimerKeyboardPointerCaret') + '\nreturn getTimerKeyboardPointerCaret')(state)
const caretOffsets = []
const hourInput = inputs[ids[0]]
hourInput.getBoundingClientRect = () => ({ left: 100, width: 44 })
hourInput.closest = (selector) => selector === 'label' ? { setAttribute() {} }
  : selector === '.timerCountdownEditSurface' ? {
    querySelector: () => ({ getBoundingClientRect: () => ({ width: 20 }) }),
    style: { setProperty: (name, value) => caretOffsets.push([name, value]) },
  } : null
hourInput.setSelectionRange = (start, end) => { hourInput.selectionStart = start; hourInput.selectionEnd = end }
for (const [clientX, expected] of [[101, 0], [112, 0], [122, 1], [132, 2], [143, 2]]) {
  assert.equal(pointerCaret(hourInput, { clientX }), expected, 'posicao do toque deve considerar o texto centralizado')
}
const timerPointer = new Function('state', 'document', 'useTimerKeyboard',
  'selectTimerKeyboardField', 'getTimerKeyboardPointerCaret',
  extract('handleTimerCountdownPointerDown') + '\nreturn handleTimerCountdownPointerDown')(
  state, document, useTimerKeyboard, keypad.select, pointerCaret)
const pointerEvent = { target: hourInput, clientX: 122, preventDefault() { this.prevented = true } }
timerPointer(pointerEvent)
assert(pointerEvent.prevented, 'toque nao pode abrir o teclado nativo no tablet')
assert.equal(state.timerKeyboardCaret, 1)
assert.equal(hourInput.selectionStart, 1)
assert.deepEqual(caretOffsets.at(-1), ['--timer-caret-position', 1])
hourInput.value = '30'
keypad.key('8')
assert.equal(hourInput.value, '38', 'numero deve alterar o digito na posicao escolhida')
assert.equal(state.timerKeyboardField, ids[0])
const timerKeyDown = new Function('state', 'useTimerKeyboard', 'selectTimerKeyboardField',
  'applyTimerKeyboardKey', extract('handleTimerCountdownKeyDown') + '\nreturn handleTimerCountdownKeyDown')(
  state, useTimerKeyboard, keypad.select, keypad.key)
for (const [key, expected] of [['ArrowLeft', 1], ['Home', 0], ['ArrowLeft', 0], ['End', 2], ['ArrowRight', 2]]) {
  const event = { target: hourInput, key, preventDefault() { this.prevented = true } }
  timerKeyDown(event)
  assert(event.prevented)
  assert.equal(state.timerKeyboardCaret, expected)
}
timerKeyDown({ target: hourInput, key: 'Backspace', preventDefault() {} })
assert.equal(hourInput.value, '30')
assert.equal(state.timerKeyboardCaret, 1)
const timerBeforeInput = new Function('editTimerCountdownDigits', 'Event',
  extract('handleTimerCountdownBeforeInput') + '\nreturn handleTimerCountdownBeforeInput')(
  editDigits, class { constructor(type) { this.type = type } })
hourInput.dispatchEvent = () => {}
hourInput.value = '30'
hourInput.setSelectionRange(1, 1)
timerBeforeInput({ target: hourInput, inputType: 'insertText', data: '8', preventDefault() {} })
assert.equal(hourInput.value, '38', 'celular tambem deve respeitar a posicao do cursor nativo')
assert.equal(hourInput.selectionStart, 2)

const render = extract('renderTimerModal')
assert(render.indexOf('data-action="timer-toggle"') < render.indexOf('data-action="timer-init-auto"'))
assert(render.indexOf('data-action="timer-init-auto"') < render.indexOf('data-action="modal-close"'))
assert.match(render, /inputmode="\$\{ownKeyboard \? 'none' : 'numeric'\}"/)
assert.match(render, /readonly aria-readonly="true"/)
assert.match(extract('toggleTimerInitAuto'), /postCommand\('timer_set_init_auto', \{ initAutoEnabled: enabled \}\)/)
assert.match(extract('getTimerInitAutoEnabled'), /bridgeControlStateSettled/)
assert.match(source, /repeatableKeyboardAction = action === 'tablet-search-key' \|\| action === 'timer-key'/)
const styles = fs.readFileSync(path.resolve(__dirname, '..', 'stylediretor-app.css'), 'utf8')
assert(styles.includes('@keyframes timerCountdownCaretBlink'))
assert(styles.includes('left: calc(50% - 1ch + var(--timer-caret-position, 0) * 1ch)'))
assert.match(render, /timerCountdownCaret/)
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
let timerMode = 'countdown'
state.showTimerModal = true
state.snapshot = {}
const renderModal = new Function('state', 'getEffectiveTimerMode', 'splitCountdownSec',
  'getCountdownTargetSec', 'useTimerKeyboard', 'getTimerInitAutoEnabled',
  'isCountdownOverrun', 'getTimerDisplayText', 'escapeHtml',
  extract('renderTimerModal') + '\n' + extract('renderTimerKeyboard') + '\nreturn renderTimerModal')(
  state, () => timerMode, () => ({ hours: 1, minutes: 30, seconds: 45 }),
  () => 5445, useTimerKeyboard, () => false, () => false, () => '01:30:45', (value) => value,
)
let html = renderModal()
assert.equal((html.match(/readonly aria-readonly="true"/g) || []).length, 3)
assert.equal((html.match(/inputmode="none"/g) || []).length, 3)
assert(html.includes('class="timerKeyboard"'))
document.documentElement = { dataset: {} }
for (const device of ['phone', 'tablet', undefined]) {
  document.documentElement.dataset.directorDevice = device
  html = renderModal()
  assert.equal((html.match(/readonly aria-readonly="true"/g) || []).length, 3)
  assert.equal((html.match(/inputmode="none"/g) || []).length, 3)
  assert.equal((html.match(/class="timerCountdownCaret"/g) || []).length, 3)
  assert.equal((html.match(/data-action="timer-key"/g) || []).length, 12)
  assert(useTimerKeyboard(), 'cronometro deve usar teclado proprio independente do modo')
}
let nativeKeyboardRequests = 0
const timerFocus = new Function('state', 'window', 'useTimerKeyboard', 'selectTimerKeyboardField',
  extract('handleTimerCountdownFocus') + '\nreturn handleTimerCountdownFocus')(
  state, { setDirectorTabletKeyboardOpen() { nativeKeyboardRequests++ } }, useTimerKeyboard, keypad.select)
document.documentElement.dataset.directorDevice = 'phone'
timerFocus({ target: hourInput })
assert.equal(nativeKeyboardRequests, 0, 'celular nao deve chamar teclado nativo no cronometro')
const useSearchKeyboard = new Function('document', 'IS_MUSICIAN_MONITOR',
  extract('useTabletSearchKeyboard') + '\nreturn useTabletSearchKeyboard')(document, false)
assert.equal(useSearchKeyboard(), false, 'lupa do celular nao deve ser alterada')
document.documentElement.dataset.directorDevice = 'tablet'
assert.equal(useSearchKeyboard(), true)
timerMode = 'progressive'
html = renderModal()
assert(!html.includes('class="timerKeyboard"'), 'progressivo nao precisa de campos nem teclado')
state.showTimerModal = false
assert.equal(useTimerKeyboard(), false)
assert.equal(renderModal(), '')
state.showTimerModal = true
assert(styles.includes('html[data-director-device="phone"] .timerModalOwnKeyboard .timerKeyboard'))
assert(styles.includes('grid-template-columns: repeat(3, minmax(0, 1fr))'))
assert(styles.includes('min-height: 44px !important'))
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
