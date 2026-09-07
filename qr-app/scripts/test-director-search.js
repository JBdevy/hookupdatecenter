const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const sourceFile = path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js'))
const source = fs.readFileSync(sourceFile, 'utf8').replace(/\r\n/g, '\n')

function extract(name) {
  const start = source.search(new RegExp(`  function ${name}\\(`))
  assert(start >= 0, name)
  const tail = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(tail >= 0, name)
  return source.slice(start, start + 1 + tail)
}

function fixture(device) {
  let html = '', htmlWrites = 0, handled = null, rendered = 0
  const entries = [
    { id: 'playlist-song', name: 'MÚSICA LOCAL', searchText: 'musica local', start: 10, end: 40 },
    { id: 'outside-song', name: 'CANÇÃO FORA', searchText: 'cancao fora', start: 50, end: 80 },
  ]
  const state = {
    activeTab: 'playlist', tabletSearchSourceTab: 'playlist', showTabletSearch: true,
    tabletSearchQuery: '', ignoreTapUntil: 0, snapshot: {},
  }
  const results = {
    get innerHTML() { return html },
    set innerHTML(value) { html = value; htmlWrites++ },
  }
  const context = vm.createContext({
    state, console, Number, String, Math,
    now: () => 1000,
    getTabletSearchEntries: () => entries,
    tabletSearchEntryIsInActivePlaylist: entry => entry.id === 'playlist-song',
    escapeHtml: value => String(value),
    upperText: value => String(value).toUpperCase(),
    formatTime: () => '0:30',
    isPlaying: () => false,
    handleItemSelect: element => { handled = element },
    scheduleRender: () => { rendered++ },
    setDirectorSearchPortraitMode() {},
    document: {
      getElementById: () => ({ blur() {} }),
      documentElement: {
        dataset: { directorDevice: device },
        classList: { contains: () => false },
      },
    },
    root: { querySelector: selector => selector.includes('results') ? results : { textContent: '' } },
  })
  for (const name of [
    'normalizeTabletSearchText', 'getFilteredTabletSearchEntries',
    'renderTabletSearchResults', 'syncTabletSearchResultsDom',
    'closeTabletSearchState', 'handleTabletSearchResult',
  ]) vm.runInContext(extract(name), context)
  return {
    state, context,
    run: code => vm.runInContext(code, context),
    handled: () => handled,
    rendered: () => rendered,
    htmlWrites: () => htmlWrites,
  }
}

for (const device of ['tablet', 'phone']) {
  let f = fixture(device)
  assert.equal(f.run('getFilteredTabletSearchEntries().length'), 1)
  assert.equal(f.run('getFilteredTabletSearchEntries()[0].regionsPage'), false)
  assert(f.run('renderTabletSearchResults()').includes('REPERTÓRIO'))

  f.state.tabletSearchQuery = 'cancao fora'
  assert.equal(f.run('getFilteredTabletSearchEntries()[0].id'), 'outside-song')
  assert.equal(f.run('getFilteredTabletSearchEntries()[0].regionsPage'), true)
  const resultHtml = f.run('renderTabletSearchResults()')
  assert(resultHtml.includes('MÚSICAS'))
  assert(resultHtml.includes('data-item-type="region"'))
  assert(resultHtml.includes('data-region-id="outside-song"'))

  f.run('syncTabletSearchResultsDom(); syncTabletSearchResultsDom()')
  assert.equal(f.htmlWrites(), 1, 'same local result must not rebuild the touched DOM')

  const element = {
    getAttribute(name) {
      return ({ 'data-search-start': '50', 'data-item-type': 'region',
        'data-region-id': 'outside-song', 'data-force-select': '1' })[name] ?? null
    },
    classList: { contains: () => false },
  }
  f.context.__resultElement = element
  f.run('handleTabletSearchResult("outside-song", __resultElement)')
  assert.equal(f.state.activeTab, 'regions')
  assert.equal(f.state.showTabletSearch, false)
  assert.equal(f.state.ignoreTapUntil, 1700, 'blocks synthesized taps on Grid behind the search')
  assert.equal(f.handled(), element)
  assert.equal(f.rendered(), 1)

  f = fixture(device)
  f.state.activeTab = 'regions'
  f.state.tabletSearchSourceTab = 'regions'
  f.state.tabletSearchQuery = 'música'
  assert.equal(f.run('getFilteredTabletSearchEntries().length'), 1)
  assert.equal(f.run('getFilteredTabletSearchEntries()[0].regionsPage'), true)
}

for (const forbidden of [
  'smart_search_open', 'smart_search_query', 'smart_search_activate',
  'smart_search_close', 'CONFIRMANDO NA EXTENSÃO',
]) assert(!source.includes(forbidden), `director search must not use ${forbidden}`)

console.log('DIRECTOR_SEARCH_OK:', sourceFile,
  'local tablet/phone search, direct selection, destination, DOM stability and ghost-tap guard')
