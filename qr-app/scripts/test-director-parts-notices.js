const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const source = fs.readFileSync(path.resolve(process.argv[2] || path.join(__dirname, '../vsdiretor.js')), 'utf8').replace(/\r\n/g, '\n')
function extract(name) {
  const start = source.indexOf(`  function ${name}(`)
  const end = source.slice(start + 1).search(/\n  (?:async )?function /)
  assert(start >= 0 && end >= 0, name)
  return source.slice(start, start + 1 + end)
}
const state = { hashRegionDrawerChildren: {}, partsArmedMarkerId: 'stale-local' }
let shown = 0
const context = vm.createContext({ state,
  now: () => 1000, isPlaying: d => d.playing, isPaused: d => d.paused,
  getLoopActive: d => d.loop, getCurrentPlaybackPosition: d => d.playPosition ?? null,
  getPartsSongTarget: (_, d) => ({available: true, id: d.playingId, start: 0, end: 120}),
  getMarkers: d => d.markers || [], getId: m => m.id,
  getPartsMarkerInfo: m => /^[$]|^[*][1-4]/.test(m.name) ? {name: m.name.replace(/^[$]|^[*][1-4]/, '')} : null,
  firstFiniteNumber: xs => xs.find(v => typeof v === 'number' && Number.isFinite(v)) ?? null,
  findSongNameById: id => id === 'b' ? 'Canção B' : '', upperText: s => s.toUpperCase(),
  syncDirectorPopupDom: () => {},
  showPopup: text => { shown++; state.popupOwner = ''; state.popupText = text; state.popupUntil = 2600 },
})
for (const n of ['getProjects', 'getProjectItemId', 'getProjectItemIndex', 'getSnapshotActiveProjectSelection',
  'getPremixProjectPayload', 'snapshotProjectChanged', 'hasAnyListData', 'mergeWithLastGoodSnapshot',
  'clearPartCountdownPopup', 'processPartCountdownPopup']) vm.runInContext(extract(n), context)
const full = { connected: true, projectId: 'A', playingId: 'a', playing: true, playPosition: 24,
  regions: [{id:'a', name:'A'}], playlists: [{id:'list', songs:[{id:'a'}]}],
  markers: [{id:'verse',name:'$Verso',pos:30}, {id:'back',name:'*2Volta',pos:10}, {id:'other',name:'*1Outro',pos:140}] }
function update(changes) { context.data = {...full, ...changes}; vm.runInContext('processPartCountdownPopup(data)', context) }
update({}); assert.equal(shown, 0, 'no cue six seconds before the part')
update({playPosition:25}); assert.equal(state.popupText, 'VERSO')
update({playPosition:25}); assert.equal(shown, 1, 'repeated samples do not reannounce')
for (const [id,name] of [['back','VOLTA'], ['other','OUTRO'], ['__parts_song_start__:b','CANÇÃO B'], ['start:b','CANÇÃO B']]) {
 update({playPosition:26, armedMarkerId:id}); assert.equal(state.popupText, name, 'announce destination at current boundary')
}
update({playPosition:26, armedMarkerId:null, markerGoId:null}); assert.equal(state.popupText, 'VERSO', 'confirmed cancellation overrides stale local panel')
for (const changes of [{paused:true}, {playing:false}, {loop:true}, {standby:true}, {connected:false}, {reaperOnline:false}, {playPosition:31}]) {
 update({playPosition:26}); assert.equal(state.popupText, 'VERSO')
 update({playPosition:26, ...changes}); assert.equal(state.popupText, '', 'inactive or passed cue disappears')
}
update({playPosition:26, loop:true, loopEndPos:60}); assert.equal(state.popupText, 'VERSO', 'parts inside a longer loop remain reachable')
update({playPosition:26, loop:true, loopEndPos:30}); assert.equal(state.popupText, '', 'natural part at the return boundary is unreachable')
update({playPosition:26, loop:true, loopEndPos:30, armedMarkerId:'back'}); assert.equal(state.popupText, 'VOLTA', 'armed jump takes priority at the boundary')
state.popupOwner = ''; state.popupText = 'Unrelated error'; update({playing:false})
assert.equal(state.popupText, 'Unrelated error', 'clearing a part cannot dismiss another popup')
update({playPosition:26}); const prior = shown
update({playPosition:26, projectId:'B'}); assert.equal(shown, prior+1, 'same marker IDs in another project are independent')
context.before = full
context.partial = {projectId:'A', markers:[{id:'new'}]}
let merged = vm.runInContext('mergeWithLastGoodSnapshot(partial,before)',context)
assert.equal(merged.regions.length, 1, 'partial markers cannot erase songs')
assert.equal(merged.playlists.length, 1, 'partial markers cannot erase repertoire')
context.partial = {projectId:'A', standby:true, regions:[], playlists:[], markers:[]}
merged = vm.runInContext('mergeWithLastGoodSnapshot(partial,before)',context)
assert.equal(merged.regions.length, 1)
context.partial.projectId = 'B'
merged = vm.runInContext('mergeWithLastGoodSnapshot(partial,before)',context)
assert.equal(merged.regions.length, 0, 'standby from another project clears old music')
context.partial = {projectId:'A', standby:false, regions:[], playlists:[], markers:[]}
merged = vm.runInContext('mergeWithLastGoodSnapshot(partial,before)',context)
assert.equal(merged.regions.length, 0, 'full empty project remains empty')
console.log('PARTS_NOTICES_OK: natural, armed forward/back/other song/start, cancel, pause, stop, loop, stale state, project change and partial lists')
