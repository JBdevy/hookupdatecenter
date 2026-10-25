import test from 'node:test';
import assert from 'node:assert/strict';
import * as menus from '../ui/product-menus.js';

const labels = items => items.filter(entry => !entry.separator).map(entry => entry.label);
const ids = items => items.filter(entry => !entry.separator).map(entry => entry.id);
const action = (items, id) => {
  const entry = items.find(entry => entry.id === id);
  assert.ok(entry, `Expected menu item ${id}`);
  return entry.action();
};
function recorder(names) {
  const calls = [];
  return {calls, actions: Object.fromEntries(names.split(' ').map(name => [name, payload => {
    calls.push({name, payload}); return {name, payload};
  }]))};
}
const trackCommands = 'patch fx envelopeSettings editTrack createMIDI soundDesigner group ungroup removeFromGroup link unlink removeTracks';
const gridCommands = 'setMuted freezeMIDI unify openFX createRegion reRender separateAudio normalize tuner exportAudio convertAudio';
const audio = (id, options = {}) => ({id, editable: true, audioExportable: true,
  midiEditable: false, contextActions: true, muted: false, hasFX: false, ...options});
const midi = (id, options = {}) => audio(id, {midiEditable: true, audioExportable: false, ...options});
test('complete track duplication targets the clicked track or standard selection in both mixers', () => {
  const r = recorder('duplicateTracks');
  const tracks = [{id:'a',kind:'standard'}, {id:'b',kind:'standard'}, {id:'generatedClick',kind:'generatedClick'}];
  for (const surface of ['trackMixer','footerMixer']) {
    const menu = menus.buildTrackMenu({surface,track:tracks[0],tracks,selectedIds:['a','b','generatedClick'],
      projectId:'project',songId:'song',actions:r.actions});
    assert.deepEqual(labels(menu),['Duplicar pistas']);
    action(menu,'track.duplicate');
    assert.deepEqual(r.calls.at(-1).payload,{trackId:'a',trackIds:['a','b'],projectId:'project',songId:'song'});
    const single = menus.buildTrackMenu({surface,track:tracks[0],tracks,selectedIds:['b'],actions:r.actions});
    assert.deepEqual(labels(single),['Duplicar pista']);
    action(single,'track.duplicate');
    assert.deepEqual(r.calls.at(-1).payload.trackIds,['a']);
    assert.deepEqual(menus.buildTrackMenu({surface,track:null,actions:r.actions}),[]);
    assert.deepEqual(menus.buildTrackMenu({surface,track:tracks[2],actions:r.actions}),[]);
  }
});
function assertClean(items) {
  assert.ok(!items[0]?.separator && !items.at(-1)?.separator, 'No leading/trailing separator');
  for (let i = 1; i < items.length; i++) assert.ok(!(items[i].separator && items[i - 1].separator));
  for (const entry of items.filter(entry => !entry.separator)) assert.equal(typeof entry.action, 'function');
}

test('track mixer and footer expose their actual Mac menus and selected track targets', () => {
  const r = recorder(trackCommands);
  const tracks = [{id: 'a', kind: 'standard'}, {id: 'b', kind: 'standard'}, {id: 'video', kind: 'video'}];
  const base = {track: tracks[0], tracks, selectedIds: ['a', 'b'], canLink: true, actions: r.actions};
  const lateral = menus.buildTrackMenu(base);
  assert.deepEqual(labels(lateral), ['Patch', 'FX', 'Criar item MIDI', 'Create group', 'Link tracks', 'Editar pista', 'Delete tracks']);
  action(lateral, 'track.patch');
  assert.deepEqual(r.calls.at(-1).payload, {trackId: 'a', trackIds: ['a', 'b']});
  action(lateral, 'track.createMIDI');
  assert.deepEqual(r.calls.at(-1).payload, {trackId: 'a'});
  action(lateral, 'track.edit');
  assert.equal(r.calls.at(-1).payload.nameEditable, false);
  const footer = menus.buildTrackMenu({...base, surface: 'footerMixer'});
  assert.deepEqual(labels(footer), ['Patch', 'FX', 'Create group', 'Link tracks', 'Editar pista', 'Delete tracks']);
  action(footer, 'track.remove');
  assert.deepEqual(r.calls.at(-1).payload.trackIds, ['a', 'b']);
  assertClean(lateral); assertClean(footer);
});

test('master never gains group, MIDI, rename or delete commands even when callbacks are available', () => {
  const r = recorder(trackCommands);
  for (const surface of ['trackMixer', 'footerMixer']) {
    const result = menus.buildTrackMenu({surface, track: null, selectedIds: ['a', 'b'], canLink: true,
      deletionIds: ['master'], isFolder: true, actions: r.actions});
    assert.deepEqual(labels(result), surface === 'trackMixer'
      ? ['Patch', 'FX', 'Env', 'Editar pista'] : ['Patch', 'FX', 'Editar pista']);
    action(result, 'track.edit');
    assert.deepEqual(r.calls.at(-1).payload, {trackId: null, trackIds: [null], master: true, nameEditable: false});
  }
  assert.deepEqual(menus.buildTrackMenu({actions: r.actions}), []);
});

test('track type, clicked membership and group/link state govern options independently', () => {
  const r = recorder(trackCommands);
  const track = {id: 'a', kind: 'standard', parentTrackID: 'folder', stereoLink: {partner: 'b'}};
  const tracks = [track, {id: 'b', kind: 'standard'}, {id: 'child', kind: 'standard', parentTrackID: 'a'}];
  const linked = menus.buildTrackMenu({track, tracks, selectedIds: ['a', 'b'], actions: r.actions});
  assert.ok(!ids(linked).includes('track.group'));
  assert.ok(!ids(linked).includes('track.link'));
  for (const id of ['track.ungroup', 'track.removeFromGroup', 'track.unlink']) assert.ok(ids(linked).includes(id));
  const outside = menus.buildTrackMenu({track: tracks[1], tracks, selectedIds: ['a', 'child'], canLink: true, actions: r.actions});
  assert.ok(!ids(outside).includes('track.group') && !ids(outside).includes('track.link'));
  action(outside, 'track.patch'); assert.deepEqual(r.calls.at(-1).payload.trackIds, ['b']);
  action(outside, 'track.edit'); assert.equal(r.calls.at(-1).payload.nameEditable, true);
  for (const kind of ['timecode', 'video', 'generatedClick', 'teleprompt']) {
    const menu = menus.buildTrackMenu({track: {id: 'special', kind}, actions: r.actions});
    assert.equal(ids(menu).includes('track.patch'), kind !== 'teleprompt');
    assert.equal(ids(menu).includes('track.soundDesigner'), kind === 'generatedClick');
    assert.ok(!ids(menu).includes('track.fx') && !ids(menu).includes('track.createMIDI'));
  }
  assert.ok(!ids(menus.buildTrackMenu({surface: 'footerMixer', track: {id: 'generatedClick', kind: 'generatedClick'}, actions: r.actions}))
    .includes('track.soundDesigner'));
  const approved = menus.buildTrackMenu({track: tracks[0], deletionIds: ['a', 'child'], actions: r.actions});
  action(approved, 'track.remove'); assert.deepEqual(r.calls.at(-1).payload.trackIds, ['a', 'child']);
});

test('missing real callbacks omit entries and leave no stray separators', () => {
  const builders = [
    () => menus.buildTrackMenu({track: {id: 'a', kind: 'standard'}}),
    () => menus.buildFXButtonMenu({insertedCount: 1}),
    () => menus.buildFooterFXSlotMenu({effectId: 'eq'}),
    () => menus.buildFXChainMenu({effectId: 'eq'}),
    () => menus.buildPlaylistMenu({playlistId: 'p', hasSong: true}),
    () => menus.buildRegionMenu({regionId: 'r'}),
    () => menus.buildTimelineItemMenu({item: audio('a'), items: [audio('a')]}),
    () => menus.buildEnvelopeMenu(), () => menus.buildBlankGridMenu(),
    () => menus.buildEditCursorMenu(), () => menus.buildVideoMenu(),
    () => menus.buildMixerDockMenu(), () => menus.buildTeleprompterMenu({index: 1}),
    () => menus.buildRecentProjectMenu({path: 'project.jl'}),
    () => menus.buildAutomationPointMenu({envelopeId: 'env'}),
    () => menus.buildFXParameterMenu({scope: {}, parameter: {}}),
  ];
  for (const build of builders) assert.deepEqual(build(), []);
  const result = menus.buildTimelineItemMenu({item: audio('a'), actions: {exportAudio: () => {}}});
  assert.deepEqual(labels(result), ['Export']); assertClean(result);
});

test('setlist multiple selection uses visible detection, all valid export regions and single clicked removal', () => {
  const r = recorder('multiloops detectBPM exportAudio editSong removeEntries');
  const regions = [{id: 'root'}, {id: 'child', parentRegionID: 'root'}, {id: 'other'}];
  const selectedIds = new Set(['root', 'child', 'block', 'missing']);
  const context = {region: regions[0], regions, selectedIds, visibleRegionIds: ['other', 'child', 'root'], actions: r.actions};
  const result = menus.buildSetlistSongMenu(context);
  assert.deepEqual(labels(result), ['Detect BPM…', 'Export Audio', 'Edit song', 'Delete region']);
  action(result, 'song.detectBPM'); assert.deepEqual(r.calls.at(-1).payload.regionIds, ['child', 'root']);
  action(result, 'song.export'); assert.deepEqual(r.calls.at(-1).payload.regionIds, ['root', 'child']);
  action(result, 'song.edit'); assert.deepEqual(r.calls.at(-1).payload.entryIds, [...selectedIds]);
  action(result, 'song.remove');
  assert.deepEqual(r.calls.at(-1).payload, {entryIds: ['root'], playlistId: null, keyboard: false});
  const child = menus.buildSetlistSongMenu({...context, region: regions[1]});
  assert.ok(!ids(child).includes('song.remove'));
  const outside = menus.buildSetlistSongMenu({...context, region: regions[2], playlistId: 'playlist'});
  assert.equal(labels(outside)[0], 'Multiloops');
  action(outside, 'song.export'); assert.deepEqual(r.calls.at(-1).payload.regionIds, ['other']);
  assert.equal(labels(outside).at(-1), 'Remove from playlist');
  const unified = menus.buildSetlistSongMenu({...context, selectedIds: [], unified: true});
  assert.ok(!ids(unified).includes('song.multiloops'));
});

test('playlist header, All regions and named playlist choices have distinct menus', () => {
  const r = recorder('copyToShare addRegions editPlaylist clonePlaylist removePlaylist');
  for (const context of [{surface: 'header', playlistId: 'p'}, {surface: 'choice', playlistId: null}]) {
    const result = menus.buildPlaylistMenu({...context, hasSong: true, actions: r.actions});
    assert.deepEqual(labels(result), ['Copy to share']);
  }
  const result = menus.buildPlaylistMenu({playlistId: 'p', hasSong: false, actions: r.actions});
  assert.deepEqual(labels(result), ['Copy to share', 'Add regions', 'Edit', 'Clone playlist', 'Delete playlist']);
  assert.equal(result[0].disabled, true);
  action(result, 'playlist.clone'); assert.deepEqual(r.calls.at(-1).payload, {playlistId: 'p'});
  assert.equal(result.at(-1).destructive, true); assertClean(result);
});

test('region menu is capability-driven with no unrelated editing or clipboard commands', () => {
  const r = recorder('editRegion detectBPM unify disunify exportAudio removeRegion');
  assert.deepEqual(labels(menus.buildRegionMenu({regionId: 'r', actions: r.actions})),
    ['Edit', 'Detect BPM…', 'Unify', 'Disunify', 'Export Audio', 'Delete region']);
  const limited = menus.buildRegionMenu({regionId: 'r', actions: {editRegion: r.actions.editRegion, disunify: r.actions.disunify}});
  assert.deepEqual(labels(limited), ['Edit', 'Disunify']);
  action(limited, 'region.disunify'); assert.deepEqual(r.calls.at(-1).payload, {regionId: 'r'});
});

test('audio menu matches Mac groups and targets each operation using the correct selection filter', () => {
  const r = recorder(gridCommands);
  const items = [audio('a'), audio('b', {muted: true}), midi('m'), audio('locked', {editable: false})];
  const result = menus.buildTimelineItemMenu({item: items[0], items, selectedIds: items.map(i => i.id), actions: r.actions});
  assert.deepEqual(labels(result), ['Criar região do item', 'Re-render', 'Unify items', 'Tuner', 'Normalize…',
    'Convert Mono - L', 'Convert Mono - R', 'Convert Mono L-R', 'Convert Stereo', 'Mute items', 'Export']);
  action(result, 'item.createRegion'); assert.deepEqual(r.calls.at(-1).payload, {itemId: 'a'});
  action(result, 'item.reRender'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['a', 'b', 'm', 'locked']);
  action(result, 'item.unify'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['a', 'b', 'm']);
  action(result, 'item.tuner'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['a', 'b', 'locked']);
  action(result, 'item.audioConvert3'); assert.deepEqual(r.calls.at(-1).payload, {itemIds: ['a', 'b', 'm', 'locked'], mode: 3});
  action(result, 'item.mute'); assert.deepEqual(r.calls.at(-1).payload, {itemIds: ['a', 'm'], muted: true});
  action(result, 'item.export'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['a', 'b']);
  assertClean(result);
});

test('MIDI menu excludes audio tail and keeps MIDI conversion and clicked FX semantics', () => {
  const r = recorder(gridCommands);
  const items = [midi('m', {muted: true, hasFX: true}), midi('m2', {muted: true}), audio('a')];
  const result = menus.buildTimelineItemMenu({item: items[0], items, selectedIds: ['m', 'm2', 'a'], actions: r.actions});
  assert.deepEqual(labels(result), ['Unmute items', 'Convert Mono', 'Convert Stereo', 'Unify items', 'FX']);
  action(result, 'item.unmute'); assert.deepEqual(r.calls.at(-1).payload, {itemIds: ['m', 'm2'], muted: false});
  action(result, 'item.midiConvert2'); assert.deepEqual(r.calls.at(-1).payload, {itemIds: ['m', 'm2'], channels: 2});
  action(result, 'item.unify'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['m', 'm2', 'a']);
  action(result, 'item.fx'); assert.deepEqual(r.calls.at(-1).payload, {itemId: 'm', insert: false});
  const noFX = menus.buildTimelineItemMenu({item: items[1], items, selectedIds: ['a'], actions: r.actions});
  assert.ok(!ids(noFX).includes('item.fx'));
  action(noFX, 'item.midiConvert1'); assert.deepEqual(r.calls.at(-1).payload.itemIds, ['m2']);
  assertClean(result);
});

test('grid context respects contextActions/export eligibility and does not add forbidden menu options', () => {
  const r = recorder(`${gridCommands} copy paste remove import`);
  const locked = audio('locked', {editable: false, audioExportable: false, contextActions: false});
  assert.deepEqual(menus.buildTimelineItemMenu({item: locked, items: [locked], actions: r.actions}), []);
  const editable = audio('a');
  const limited = menus.buildTimelineItemMenu({item: locked, items: [locked, editable], selectedIds: ['locked', 'a'], actions: r.actions});
  assert.deepEqual(labels(limited), ['Mute items', 'Export']);
  const noAudio = audio('n', {audioExportable: false});
  const result = menus.buildTimelineItemMenu({item: noAudio, items: [noAudio], actions: r.actions});
  assert.equal(result.at(-1).disabled, true);
  for (const entry of [...limited, ...result]) {
    assert.ok(!entry.shortcut);
    assert.ok(!['Copy', 'Paste', 'Delete', 'Import'].includes(entry.label));
  }
  const blank = menus.buildBlankGridMenu({trackId: 't', point: {x: 2, y: 3}, actions: {...r.actions, createMIDI: payload => payload}});
  assert.deepEqual(labels(blank), ['Criar item MIDI']);
  assert.deepEqual(action(blank, 'grid.createMIDI'), {trackId: 't', point: {x: 2, y: 3}});
});

test('FX button, slot and chain keep their distinct menu choices and bypass targets', () => {
  const r = recorder('setBypass toggleBypass removeAllFX removeFX');
  assert.deepEqual(menus.buildFXButtonMenu({insertedCount: 0, actions: r.actions}), []);
  const button = menus.buildFXButtonMenu({insertedCount: 2, allBypassed: true, trackId: 'a', trackIds: ['a', 'b'], actions: r.actions});
  assert.deepEqual(labels(button), ['Bypass']); assert.equal(button[0].checked, true);
  action(button, 'fx.bypass'); assert.deepEqual(r.calls.at(-1).payload, {trackId: 'a', trackIds: ['a', 'b'], bypassed: false});
  const master = menus.buildFXButtonMenu({insertedCount: 1, trackId: null, trackIds: ['a'], actions: r.actions});
  action(master, 'fx.bypass'); assert.deepEqual(r.calls.at(-1).payload.trackIds, [null]);
  const slot = menus.buildFooterFXSlotMenu({effectId: 'eq', trackId: 'a', actions: r.actions});
  assert.deepEqual(labels(slot), ['By', 'Remove']); assert.ok(!Object.hasOwn(slot[0], 'checked'));
  assert.deepEqual(labels(menus.buildFXChainMenu({effectId: 'eq', actions: r.actions})), ['Remove']);
  assert.deepEqual(menus.buildFooterFXSlotMenu({actions: r.actions}), []);
});

test('cursor, video, TP, mixer, recents and automation preserve exact small menus', () => {
  const r = recorder('createMarker createTempoMarker import settings remote setStretch setDocked requestDeletion setShape mapMIDI');
  assert.deepEqual(labels(menus.buildEditCursorMenu({actions: r.actions})), ['Create marker', 'Create tempo marker']);
  assert.deepEqual(menus.buildEditCursorMenu({secondary: true, actions: r.actions}), []);
  const video = menus.buildVideoMenu({stretch: true, actions: r.actions});
  assert.deepEqual(labels(video), ['Stretch']); assert.equal(video[0].checked, true);
  action(video, 'video.stretch'); assert.deepEqual(r.calls.at(-1).payload, {stretch: false});
  for (const index of [1, 2]) {
    const tp = menus.buildTeleprompterMenu({index, actions: r.actions});
    assert.deepEqual(labels(tp), ['Configurações', 'TP Remoto']);
    action(tp, 'tp.remote'); assert.deepEqual(r.calls.at(-1).payload, {index});
  }
  assert.deepEqual(menus.buildTeleprompterMenu({index: 3, actions: r.actions}), []);
  assert.deepEqual(labels(menus.buildMixerDockMenu({undocked: true, actions: r.actions})), ['Dock mixer']);
  assert.deepEqual(labels(menus.buildMixerDockMenu({undocked: false, actions: r.actions})), ['Undock mixer']);
  for (const missing of [false, true]) assert.deepEqual(labels(menus.buildRecentProjectMenu({path: 'p.jl', missing, actions: r.actions})),
    [missing ? 'Remove from recents' : 'Delete project']);
  for (const flags of [{busy: true}, {playing: true}]) assert.deepEqual(menus.buildRecentProjectMenu({path: 'p.jl', ...flags, actions: r.actions}), []);
  const automation = menus.buildAutomationPointMenu({envelopeId: 'env', pointIds: ['p1', 'p2'], actions: r.actions});
  assert.deepEqual(labels(automation), ['Linear', 'Square', 'Smooth', 'Fast start', 'Fast end']);
  action(automation, 'automation.fastStart'); assert.deepEqual(r.calls.at(-1).payload, {envelopeId: 'env', pointIds: ['p1', 'p2'], shape: 'fastStart'});
  assert.deepEqual(labels(menus.buildFXParameterMenu({scope: {effect: 'eq'}, parameter: {key: 'gain'}, actions: r.actions})), ['Map MIDI']);
  assert.deepEqual(menus.buildFXParameterMenu({parameter: {key: 'gain'}, actions: r.actions}), []);
});

test('localisation is injected and command requests retain original IDs and project context', async () => {
  const seen = [], selected = ['a', 'b'];
  const r = recorder('patch');
  const result = menus.buildTrackMenu({track: {id: 'a', kind: 'standard'}, tracks: [{id: 'a', kind: 'standard'}, {id: 'b', kind: 'standard'}],
    selectedIds: selected, projectId: 'project', songId: 'song', actions: r.actions,
    t: (key, fallback) => {seen.push([key, fallback]); return `Traduzido ${fallback}`;}});
  assert.deepEqual(labels(result), ['Traduzido Patch']); assert.deepEqual(seen, [['menu.track.patch', 'Patch']]);
  selected.splice(0, 2, 'other'); r.actions.patch = () => assert.fail('must retain actual supplied command');
  action(result, 'track.patch');
  const payload = r.calls.at(-1).payload;
  assert.deepEqual(payload, {trackId: 'a', trackIds: ['a', 'b'], projectId: 'project', songId: 'song'});
  assert.ok(Object.isFrozen(payload) && Object.isFrozen(payload.trackIds));
  const asyncMenu = menus.buildVideoMenu({actions: {setStretch: async () => 'completed'}});
  assert.equal(await action(asyncMenu, 'video.stretch'), 'completed');
});

test('state-dependent labels have distinct translation keys rather than ambiguous reused keys', () => {
  const keys = new Map();
  const r = recorder('removeTracks removeEntries requestDeletion setDocked');
  const shared = {actions: r.actions, t: (key, fallback) => {
    if (keys.has(key)) assert.equal(keys.get(key), fallback, `Ambiguous translation key ${key}`);
    keys.set(key, fallback); return fallback;
  }};
  for (const deletionIds of [['a'], ['a', 'b']])
    menus.buildTrackMenu({...shared, track: {id: 'a', kind: 'standard'}, deletionIds});
  for (const playlistId of [null, 'playlist'])
    menus.buildSetlistSongMenu({...shared, region: {id: 'r'}, regions: [{id: 'r'}], playlistId});
  for (const missing of [true, false]) menus.buildRecentProjectMenu({...shared, path: 'p.jl', missing});
  for (const undocked of [true, false]) menus.buildMixerDockMenu({...shared, undocked});
  assert.equal(keys.size, 8);
});

test('direct save/header/piano/marker gestures dispatch real commands without constructing a popup', () => {
  const r = recorder('exportPortable seekSubplay beginTimeSelection updateTimeSelection endTimeSelection beginNoteSelection updateNoteSelection endNoteSelection editMarker');
  const invoke = (target, gesture, extra = {}) => menus.routeDirectGesture({target, gesture, context: {
    actions: r.actions, projectId: 'p', data: {time: 12, markerId: 'marker'}, ...extra,
  }});
  assert.equal(invoke('save', 'context').handled, true); assert.equal(r.calls.at(-1).name, 'exportPortable');
  assert.equal(invoke('timelineHeader', 'context').handled, true); assert.equal(r.calls.at(-1).name, 'seekSubplay');
  for (const [gesture, command] of [['rightDragStart', 'beginTimeSelection'], ['rightDrag', 'updateTimeSelection'], ['rightDragEnd', 'endTimeSelection']]) {
    assert.equal(invoke('timelineHeader', gesture).handled, true); assert.equal(r.calls.at(-1).name, command);
  }
  assert.equal(invoke('pianoRoll', 'context', {editable: true, inNoteArea: true}).handled, false);
  for (const [gesture, command] of [['rightDown', 'beginNoteSelection'], ['rightDrag', 'updateNoteSelection'], ['rightUp', 'endNoteSelection']]) {
    assert.equal(invoke('pianoRoll', gesture, {editable: true, inNoteArea: true}).handled, true); assert.equal(r.calls.at(-1).name, command);
  }
  assert.equal(invoke('marker', 'context').handled, true); assert.equal(r.calls.at(-1).name, 'editMarker');
  assert.ok(!Object.values(menus.DIRECT_GESTURES).some(gestures => Object.values(gestures).includes('showContextMenu')));
});

test('direct gesture gates protect derived markers, empty FX, piano ruler and unavailable commands', () => {
  const r = recorder('removeMarker removeAllFX setBypass beginNoteSelection configureBlockDefaults');
  const route = (target, gesture, context = {}) => menus.routeDirectGesture({target, gesture, context: {actions: r.actions, ...context}});
  for (const derived of [{sourceRegionID: 'r'}, {unifiedRegionID: 'r'}]) assert.equal(route('marker', 'altClick', derived).handled, false);
  assert.equal(route('marker', 'altClick').handled, true);
  assert.equal(route('fxButton', 'altClick', {insertedCount: 0}).handled, false);
  assert.equal(route('fxButton', 'altClick', {insertedCount: 1}).handled, true);
  assert.equal(route('fxButton', 'shiftClick', {insertedCount: 1, allBypassed: false, data: {trackIds: ['a', 'b']}}).handled, true);
  assert.deepEqual(r.calls.at(-1), {name: 'setBypass', payload: {trackIds: ['a', 'b'], bypassed: true}});
  assert.equal(route('pianoRoll', 'rightDown', {editable: false, inNoteArea: true}).handled, false);
  assert.equal(route('pianoRoll', 'rightDown', {editable: true, inNoteArea: false}).handled, false);
  assert.equal(route('setlistBlocks', 'context', {playlistId: null}).handled, false);
  assert.equal(route('setlistBlocks', 'context', {playlistId: 'p'}).handled, true);
  assert.equal(route('marker', 'altClick', {blocked: true}).handled, false);
  assert.equal(route('save', 'context').handled, false);
  assert.equal(route('constructor', 'context').handled, false);
  assert.equal(route('marker', 'toString').handled, false);
  assert.equal(route('marker', 'ctrlClick').handled, false);
});

test('context selection deduplicates a selected batch and never mutates its input', () => {
  const selected = ['a', 'b', 'a'];
  assert.deepEqual(menus.contextSelection('a', selected), ['a', 'b']);
  assert.deepEqual(menus.contextSelection('c', selected), ['c']);
  assert.deepEqual(menus.contextSelection(null, selected), []);
  assert.deepEqual(selected, ['a', 'b', 'a']);
});


test('region duplicate menu requires one row in a named playlist and passes occurrence identity', () => {
  const r = recorder('duplicateRegion');
  const context = {region: {id: 'copy', sourceRegionId: 'original'}, regions: [{id: 'original'}],
    selectedIds: ['copy'], visibleRegionIds: ['copy'], playlistId: 'playlist', actions: r.actions};
  const result = menus.buildSetlistSongMenu(context);
  assert.deepEqual(labels(result), ['Duplicate region']);
  action(result, 'song.duplicate');
  assert.deepEqual(r.calls.at(-1).payload, {entryId: 'copy', playlistId: 'playlist'});
  assert.deepEqual(menus.buildSetlistSongMenu({...context, playlistId: null}), []);
  assert.deepEqual(menus.buildSetlistSongMenu({...context, selectedIds: ['copy','original']}), []);
  assert.deepEqual(menus.buildSetlistSongMenu({...context, region: {id:'copy',parentRegionID:'parent'}}), []);
});

 test('audio separation is offered for one audio item and sends only that ID', () => {
  const r = recorder(gridCommands), a = audio('source');
  const single = menus.buildTimelineItemMenu({item:a, items:[a], selectedIds:['source'], actions:r.actions});
  action(single, 'item.separateAudio'); assert.deepEqual(r.calls.at(-1).payload, {itemId:'source'});
  const many = menus.buildTimelineItemMenu({item:a, items:[a,audio('other')], selectedIds:['source','other'], actions:r.actions});
  assert.equal(many.some(e => e.id === 'item.separateAudio'), false);
});
