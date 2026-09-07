const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const sourceFile = path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js'))
const source = fs.readFileSync(sourceFile, 'utf8').replace(/\r\n/g, '\n')
function extract(name) {
  const pattern = new RegExp(`  (?:async )?function ${name}\\(`)
  const start = source.search(pattern)
  assert(start >= 0, name)
  const tail = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(tail >= 0, name)
  return source.slice(start, start + 1 + tail)
}
const names = ['normalizeTabletSearchText', 'getNativeTabletSearchEntries',
  'getFilteredTabletSearchEntries', 'renderTabletSearchResults', 'syncTabletSearchResultsDom',
  'nativeTabletSearchPayload', 'nativeTabletSearchIsCurrent', 'postNativeTabletSearchCommand',
  'failNativeTabletSearch', 'waitForNativeTabletSearch', 'syncNativeTabletSearchState',
  'beginNativeTabletSearch', 'queueNativeTabletSearchQuery', 'activateNativeTabletSearchResult',
  'closeTabletSearchState', 'handleTabletSearchResult']
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
function fixture(device) {
  let timerId = 0, htmlWrites = 0, html = ''
  const timers = new Map(), sent = []
  const input = { disabled: false, blur() {} }
  const results = { get innerHTML() { return html }, set innerHTML(value) { html = value; htmlWrites++ } }
  const state = { activeTab: 'regions', showTabletSearch: true, tabletSearchQuery: 'Música', snapshot: {} }
  const c = vm.createContext({ state, console, Promise, Number, String, Date, Math,
    window: { setTimeout(fn, ms) { timers.set(++timerId, { fn, ms }); return timerId }, clearTimeout(id) { timers.delete(id) } },
    document: { getElementById() { return input }, documentElement: { dataset: { directorDevice: device }, classList: { contains() { return false } } } },
    root: { querySelector(selector) { return selector.includes('results') ? results : {} } },
    escapeHtml: value => String(value), upperText: value => String(value).toUpperCase(), formatTime: () => '1:00',
    isPlaying: data => !!data.playing, scheduleRender() {}, setDirectorSearchPortraitMode() {},
    postCommand(type, payload) {
      return new Promise(resolve => sent.push({ type, payload, resolve }))
    }
  })
  names.forEach(name => vm.runInContext(extract(name), c))
  const run = code => vm.runInContext(code, c)
  const tick = async ms => {
    const due = [...timers].filter(([, timer]) => timer.ms === ms)
    due.forEach(([id, timer]) => { timers.delete(id); timer.fn() })
    await flush()
  }
  const respond = async (request, ok = true) => {
    request.resolve(ok ? { ok: true, json: async () => ({ ok: true }) } : null)
    await flush()
  }
  const snapshot = (overrides = {}) => {
    const search = { protocolVersion: 2, open: true, ready: true,
      searchClient: state.tabletSearchNativeClient, searchSerial: state.tabletSearchNativeSerial,
      searchSequence: state.tabletSearchNativeQuerySequence, appliedQuery: state.tabletSearchQuery,
      results: [{ id: 'normal', name: 'Música normal', start: 50, end: 80, regionsPage: true }], ...overrides }
    state.snapshot = { smartSearch: search }
    run('syncNativeTabletSearchState(state.snapshot)')
    return search
  }
  const ready = async () => {
    run('beginNativeTabletSearch()')
    await respond(sent.at(-1)); await tick(24)
    await respond(sent.at(-1)); snapshot()
  }
  return { state, run, sent, tick, respond, snapshot, ready, input,
    htmlWrites: () => htmlWrites, html: () => html }
}
async function test(device) {
  let f = fixture(device)
  await f.ready()
  assert.equal(f.run('getFilteredTabletSearchEntries().length'), 1)
  assert(f.run('renderTabletSearchResults()').includes('MÚSICAS'))
  f.run('syncTabletSearchResultsDom(); syncTabletSearchResultsDom()')
  assert.equal(f.htmlWrites(), 1, 'unchanged results do not destroy touched DOM nodes')
  // Local optimistic results are never selectable while typing/waiting.
  f.run('state.tabletSearchQuery = "Outra"; queueNativeTabletSearchQuery("Outra")')
  assert.equal(f.run('getFilteredTabletSearchEntries().length'), 0)
  f.run('handleTabletSearchResult("normal")')
  assert(!f.state.tabletSearchNativeActivation)
  await f.tick(24); await f.respond(f.sent.at(-1)); f.snapshot()
  // Keep overlay after HTTP acceptance; close only for matching execution ack.
  f.run('handleTabletSearchResult("normal"); handleTabletSearchResult("normal")')
  await flush()
  assert.equal(f.sent.filter(r => r.type === 'smart_search_activate').length, 1)
  assert.equal(f.input.disabled, true)
  const activation = f.state.tabletSearchNativeActivation
  await f.respond(f.sent.at(-1))
  assert(f.state.showTabletSearch)
  f.snapshot({ activationSequence: activation.searchSequence - 1, activationOk: true })
  assert(f.state.showTabletSearch)
  f.snapshot({ activationSequence: activation.searchSequence, activationOk: true, open: false })
  assert.equal(f.state.showTabletSearch, false)

  f = fixture(device); await f.ready()
  f.run('handleTabletSearchResult("normal")'); await flush()
  await f.respond(f.sent.at(-1), false)
  assert(f.state.showTabletSearch && f.state.tabletSearchNativeError)
  assert(f.html().includes('TENTAR NOVAMENTE'))
  f.run('beginNativeTabletSearch()')
  assert.equal(f.state.tabletSearchNativeError, '')
  await f.respond(f.sent.at(-1)); await f.tick(24); await f.respond(f.sent.at(-1)); f.snapshot()
  f.run('handleTabletSearchResult("normal")'); await flush()
  const pending = f.state.tabletSearchNativeActivation
  await f.respond(f.sent.at(-1))
  f.snapshot({ activationSequence: pending.searchSequence, activationOk: false, activationError: 'Resultado removido' })
  assert(f.state.showTabletSearch && f.state.tabletSearchNativeError === 'Resultado removido')

  f = fixture(device)
  f.run('beginNativeTabletSearch()')
  const oldOpen = f.sent[0]
  await f.tick(24) // callback waiting for old open
  f.run('closeTabletSearchState(); state.showTabletSearch = true; beginNativeTabletSearch()')
  await f.respond(oldOpen)
  assert(!f.sent.some(r => r.type === 'smart_search_query'), 'old query cannot send after reopen')
  const close = f.sent.find(r => r.type === 'smart_search_close')
  assert(close.payload.searchSerial < f.state.tabletSearchNativeSerial)
  f = fixture(device); await f.ready()
  f.run('handleTabletSearchResult("normal"); closeTabletSearchState(); state.showTabletSearch = true; beginNativeTabletSearch()')
  await flush()
  assert(!f.sent.some(r => r.type === 'smart_search_activate'), 'canceled confirmation cannot send')

  f = fixture(device); await f.ready()
  f.run('handleTabletSearchResult("normal")'); await flush(); await f.respond(f.sent.at(-1))
  await f.tick(8000)
  assert(f.state.showTabletSearch && f.state.tabletSearchNativeError)
  f = fixture(device); await f.ready()
  f.snapshot({ protocolVersion: 1 })
  assert(f.state.tabletSearchNativeError.includes('ATUALIZE'))
  f = fixture(device); await f.ready()
  f.snapshot({ sourcePlaylistName: 'Repertorio' })
  f.state.snapshot.playing = true
  assert(f.run('renderTabletSearchResults()').includes('REPERTÓRIO'))
  f.state.snapshot.playing = false
  assert(f.run('renderTabletSearchResults()').includes('MÚSICAS'))
  f.snapshot({ results: [] })
  assert(f.run('renderTabletSearchResults()').includes('NENHUMA MÚSICA'))
  f.snapshot({ searchSerial: 0 })
  assert.equal(f.run('getFilteredTabletSearchEntries().length'), 0)
}
(async () => {
  await test('tablet'); await test('phone')
  console.log('DIRECTOR_SEARCH_OK:', sourceFile, 'tablet/phone, authoritative results, errors/retry, stale actions, ack, duplicates, destination and DOM stability')
})().catch(error => { console.error(error); process.exitCode = 1 })
