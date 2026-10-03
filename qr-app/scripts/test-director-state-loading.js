const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const sourceFile = path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js'))
const source = fs.readFileSync(sourceFile, 'utf8').replace(/\r\n/g, '\n')
function extract(name) {
  const start = source.indexOf(`  function ${name}(`)
  const tail = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(start >= 0 && tail >= 0, name)
  return source.slice(start, start + 1 + tail)
}

function fixture(musician) {
  const state = { activeTab: 'playlist', hashRegionDrawerChildren: {}, hashRegionDrawers: {} }
  const context = vm.createContext({ state, IS_MUSICIAN_MONITOR: musician, now: () => 1000 })
  for (const name of [
    'normalizeSharedPage', 'syncSharedInterfaceState', 'getPlaylistSongs',
    'getActivePlaylist', 'getPlaylistItems', 'getRegions', 'getMarkers',
    'getRegionsWithOpenDrawers', 'isHashChild', 'getId', 'getName', 'isBlock',
    'hasAnyListData', 'hasRenderableListContent', 'mergeWithLastGoodSnapshot',
  ]) vm.runInContext(extract(name), context)
  return { state, context, run: code => vm.runInContext(code, context) }
}

const song = { id: 'song-1', name: 'Música de teste', start: 0, end: 120 }
for (const musician of [false, true]) {
  for (const pageField of ['currentPage', 'activePage', 'activeTab']) {
    const f = fixture(musician)
    f.context.payload = { [pageField]: 'regions', connected: true, regions: [song], playlists: [], markers: [] }
    f.run('syncSharedInterfaceState(payload)')
    assert.equal(f.state.activeTab, 'regions', `${musician ? 'Músico' : 'Diretor'} must honor ${pageField}`)
    assert.equal(f.run('getRegionsWithOpenDrawers(payload).length'), 1)
    assert.equal(f.run('getPlaylistItems(payload).length'), 0, 'do not manufacture a playlist from the general list')
  }
  const f = fixture(musician)
  f.context.payload = { currentPage: 'regions', activePage: 'playlist' }
  f.run('syncSharedInterfaceState(payload)')
  assert.equal(f.state.activeTab, 'playlist', 'current contract takes precedence over legacy currentPage')
  f.state.activeTabLocalUntil = 2000
  f.context.payload = { currentPage: 'regions' }
  f.run('syncSharedInterfaceState(payload)')
  assert.equal(f.state.activeTab, 'playlist', 'legacy alias must preserve the local page hold')
}

const f = fixture(false)
f.context.standby = { connected: true, standby: true, regions: [], playlists: [], markers: [] }
f.context.full = { connected: true, standby: false, playing: true, playingId: song.id, regions: [song], playlists: [], markers: [] }
f.run('state.snapshot = mergeWithLastGoodSnapshot(standby, null)')
assert.equal(f.run('hasRenderableListContent(state.snapshot)'), false)
f.run('state.snapshot = mergeWithLastGoodSnapshot(full, state.snapshot)')
assert.equal(f.run('hasRenderableListContent(state.snapshot)'), true, 'first full snapshot must replace initial standby')
f.run('state.snapshot = mergeWithLastGoodSnapshot(standby, state.snapshot)')
assert.equal(f.run('getRegions().length'), 1, 'a later standby cannot erase received music')
assert.equal(f.state.snapshot.playingId, song.id, 'standby cannot overwrite transport from the full state')
f.context.empty = { connected: true, standby: false, regions: [], playlists: [], markers: [] }
f.run('state.snapshot = mergeWithLastGoodSnapshot(empty, state.snapshot)')
assert.equal(f.run('hasRenderableListContent(state.snapshot)'), false, 'a full empty project must clear previous lists')

console.log(`DIRECTOR_STATE_LOADING_OK: legacy/current pages in both roles; standby/full/empty transitions (${sourceFile})`)
