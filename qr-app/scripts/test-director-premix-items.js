const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')

const sourceFile = path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js'))
const source = fs.readFileSync(sourceFile, 'utf8').replace(/\r\n/g, '\n')

function extract(name) {
  const start = source.indexOf(`  function ${name}(`)
  const tail = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(start >= 0 && tail >= 0, name)
  return source.slice(start, start + 1 + tail)
}

function fixture() {
  const state = {
    showPremixScreen: true,
    premixSongId: 'parent',
    premixSongName: 'Family',
    premixPlaySongId: 'child-a',
    premixPlaySongStart: 0,
    snapshot: null,
  }
  const context = vm.createContext({
    state,
    premixStructureSignatureCache: new WeakMap(),
    premixFullScreenCache: new Map(),
    root: { querySelector: () => null },
    getMarkers: data => data?.markers || [],
    getPlayingId: () => '',
    getAppTheme: () => 'dark',
    isPlaying: () => false,
    upperText: value => String(value).toUpperCase(),
    escapeHtml: value => String(value),
    renderPlaybackQueueHeader: () => '',
    renderPremixItemRow: item => `<div data-item="${item.itemId}" />`,
    // Other panels stay fixed; compactRenderState's Premix contribution is
    // its target and total item count, already covered by the outer signature.
    compactRenderState: () => ({}),
  })
  for (const name of [
    'getTransportSeekTargetKey', 'getHashDrawersRenderSignature',
    'getTabletMultiLoopsRenderSignature', 'getDirectorTelepromptContentKey',
    'getDirectorTechnicalNoticeKey', 'getTunerValuesSignature',
    'getBorderColorMode', 'getNumberColumnMode', 'getNumberSortDirection',
    'getAppliedNumberSortDirection', 'getPlayProtectionEnabled',
  ]) context[name] = () => ''
  for (const name of [
    'simpleHash', 'firstFiniteNumber', 'getName', 'getId',
    'isAppHiddenMixerTrack', 'getAppVisibleMixerTracks',
    'getPremixItemRows', 'getPremixSongSections', 'getPremixSectionItems',
    'getPremixAllItemRows', 'getPremixSnapshotSongId', 'getPremixItemId',
    'getPremixItemTrackId', 'getPremixSectionMarkerNumber',
    'getPremixSectionMarkerPosition', 'getPremixSectionTarget',
    'getPremixEffectiveTarget', 'getPremixFullScreenCacheKey',
    'getAppRenderSignature', 'renderPremixFullScreen',
  ]) vm.runInContext(extract(name), context)
  if (source.includes('  function getPremixStructureSignature(')) {
    vm.runInContext(extract('getPremixStructureSignature'), context)
  }
  return { state, context, run: code => vm.runInContext(code, context) }
}

const piano = { itemId: 'piano-item', trackId: 'piano', trackName: 'Piano', name: 'Piano take' }
function family(firstItems, secondItems) {
  return { premix: { selectedSongId: 'parent', songSections: [
    { songId: 'child-a', name: 'Song A', startPos: 0, endPos: 100, items: firstItems },
    { songId: 'child-b', name: 'Song B', startPos: 100, endPos: 200, items: secondItems },
  ] } }
}

test('item names cannot hide audio on an explicitly named musical track', () => {
  const f = fixture()
  for (const field of ['trackName', 'track_name', 'trackLabel', 'track']) {
    for (const name of ['MEDIA', 'Timecode', 'Cifras', 'Teleprompt 1', 'Teleprompt 2']) {
      f.state.snapshot = { premix: { items: [{ itemId: 'audio', name, [field]: 'Piano' }] } }
      assert.equal(f.run('getPremixItemRows().length'), 1, `${field}: ${name}`)
    }
  }
})

test('technical tracks remain hidden for track rows and their audio items', () => {
  const f = fixture()
  for (const name of ['MÉDIA', ' time-code ', 'Cifras', 'Teleprompt 1', 'TELEPROMPT_2']) {
    f.context.rows = [{ name }, { name: 'Ordinary take', trackName: name }]
    assert.equal(f.run('getAppVisibleMixerTracks(rows).length'), 0, name)
  }
})

test('moving an item between family songs refreshes a previously empty song', () => {
  const f = fixture()
  f.state.snapshot = family([], [piano])
  const beforeSignature = f.run('getAppRenderSignature()')
  const beforeHtml = f.run('renderPremixFullScreen()')
  f.state.snapshot = family([piano], [])
  assert.notEqual(f.run('renderPremixFullScreen()'), beforeHtml, 'visible song assignment changes')
  assert.notEqual(f.run('getAppRenderSignature()'), beforeSignature,
    'same item and section counts must not leave the previous DOM mounted')
})

test('replacing an item without changing the count invalidates the rendered list', () => {
  const f = fixture()
  f.state.snapshot = family([piano], [])
  const before = f.run('getAppRenderSignature()')
  f.state.snapshot = family([{ ...piano, itemId: 'new-take', name: 'New take' }], [])
  assert.notEqual(f.run('getAppRenderSignature()'), before)
})

test('volume-only snapshots keep the Premix structure and render signature stable', () => {
  const f = fixture()
  f.state.snapshot = family([piano], [])
  const beforeKey = f.run('getPremixFullScreenCacheKey()')
  const beforeSignature = f.run('getAppRenderSignature()')
  f.state.snapshot = family([{ ...piano, volume: 0.2, mute: true, solo: true }], [])
  assert.equal(f.run('getPremixFullScreenCacheKey()'), beforeKey)
  assert.equal(f.run('getAppRenderSignature()'), beforeSignature)
})

test('an echoed legacy scope id accepts canonical section ids without normalization', () => {
  const f = fixture()
  f.state.premixSongId = 'm12'
  f.state.premixPlaySongId = 'm12'
  for (const songSections of [[], [
    { songId: '12', name: 'Legacy child', startPos: 0, endPos: 100, items: [piano] },
  ]]) {
    f.state.snapshot = { premix: {
      selectedSongId: 'm12', selectedCanonicalSongId: '12', items: [piano], songSections,
    } }
    const html = f.run('renderPremixFullScreen()')
    assert(!html.includes('CARREGANDO PREMIX'), 'the echoed requested id satisfies readiness')
    assert(html.includes('data-item="piano-item"'))
  }
})

test('repeated cache-key reads reuse item structure within one snapshot', () => {
  const f = fixture()
  let reads = 0
  const item = { ...piano, get name() { reads += 1; return 'Piano take' } }
  f.state.snapshot = family([item], [])
  const beforeKey = f.run('getPremixFullScreenCacheKey()')
  const afterFirstRead = reads
  assert(afterFirstRead > 0)
  assert.equal(f.run('getPremixFullScreenCacheKey()'), beforeKey)
  assert.equal(reads, afterFirstRead, 'do not scan or serialize item structure twice per snapshot')
  f.state.premixPlaySongId = 'child-b'
  f.state.premixPlaySongStart = 100
  assert.notEqual(f.run('getPremixFullScreenCacheKey()'), beforeKey,
    'local song selection still invalidates the key in the same snapshot')
  assert.equal(reads, afterFirstRead)
})
