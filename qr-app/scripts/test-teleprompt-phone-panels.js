const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const file = path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js'))
const source = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n')
function extract(name) {
  const start = source.indexOf('  function ' + name + '(')
  assert(start >= 0, name)
  const end = source.indexOf('\n  }', start)
  assert(end >= 0, name + ' sem fechamento')
  return source.slice(start, end + 4)
}
function fixture(device, musician = false) {
  const saved = {}
  const context = vm.createContext({
    IS_MUSICIAN_MONITOR: musician,
    document: { documentElement: { dataset: { directorDevice: device } } },
    state: { showTelepromptScreen: true, telepromptListOpen: false, telepromptPartsOpen: false },
    renders: 0,
    readJsonLocal: key => JSON.parse(saved[key] || '{}'),
    writeLocal: (key, value) => { saved[key] = value },
    mountSettingsModalInPlace() {},
    scheduleRender() { context.renders++ },
  })
  const start = source.indexOf('  const TELEPROMPT_TAB_CONTROLS =')
  const end = source.indexOf('\n  function ', start)
  vm.runInContext(source.slice(start, end) + [
    'getTelepromptRolePrefix', 'useCompactTelepromptTabControls',
    'getAvailableTelepromptTabControls', 'getTelepromptTabControlsKey',
    'getTelepromptTabControls', 'toggleTelepromptTabControl',
    'isTabletTelepromptLayout', 'canShowTelepromptPanels',
    'toggleTelepromptPanel', 'isTelepromptPartsSideVisible',
  ].map(extract).join('\n'), context)
  return context
}
const phone = fixture('phone')
assert.deepEqual(Array.from(phone.getAvailableTelepromptTabControls(), c => c.id),
  ['play', 'list', 'auto1', 'loop', 'parts'])
assert(Object.values(phone.getTelepromptTabControls()).every(value => value === false))
phone.toggleTelepromptTabControl('list')
phone.toggleTelepromptTabControl('parts')
assert.equal(phone.getTelepromptTabControls().list, true)
assert.equal(phone.getTelepromptTabControls().parts, true)
phone.toggleTelepromptPanel('list')
assert.equal(phone.state.telepromptListOpen, true)
assert.equal(phone.state.telepromptPartsOpen, false)
phone.toggleTelepromptPanel('parts')
assert.equal(phone.state.telepromptListOpen, false)
assert.equal(phone.isTelepromptPartsSideVisible(), true)
phone.toggleTelepromptPanel('list')
assert.equal(phone.state.telepromptPartsOpen, false)
assert.equal(phone.state.telepromptListOpen, true)
phone.toggleTelepromptPanel('list')
assert.equal(phone.state.telepromptListOpen, false, 'segundo toque devolve o TP')
phone.toggleTelepromptPanel('parts')
phone.toggleTelepromptTabControl('parts')
assert.equal(phone.state.telepromptPartsOpen, false, 'ocultar botão fecha o painel')
phone.state.showTelepromptScreen = false
phone.toggleTelepromptPanel('list')
assert.equal(phone.state.telepromptListOpen, false)
const tablet = fixture('tablet')
tablet.toggleTelepromptPanel('list')
tablet.toggleTelepromptPanel('parts')
assert.equal(tablet.state.telepromptListOpen, true)
assert.equal(tablet.state.telepromptPartsOpen, true, 'tablet mantém painéis simultâneos')
assert(!Array.from(tablet.getAvailableTelepromptTabControls(), c => c.id).includes('loop'))
const musician = fixture('phone', true)
assert.deepEqual(Array.from(musician.getAvailableTelepromptTabControls(), c => c.id),
  ['play', 'auto1', 'loop'], 'modo músicos permanece inalterado')
musician.toggleTelepromptPanel('list')
assert.equal(musician.state.telepromptListOpen, false)
console.log('TELEPROMPT_PHONE_PANELS_OK: ' + file)
