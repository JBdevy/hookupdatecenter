/**
 * Mac menu contract, independent of DOM, Tauri and the audio engine.
 *
 * These functions only build the item arrays accepted by showContextMenu().
 * Callers supply REAL commands in `actions`; an absent command omits its item.
 * A command receives one frozen request object and may return a promise. It
 * must validate the captured project/song and current eligibility before
 * committing, perform undo/redo, and present the same confirmation as the Mac.
 * No builder mutates selection or deletes anything. Before displaying a grid
 * menu, apply contextSelection() to the application selection, as on Mac.
 * Track context menus preserve selection; their clicked track is pinned while
 * a command runs. The consumer owns that pin and panel/project lifetime.
 *
 * `t(key, fallback)` is optional. Keys are stable; fallbacks are the current
 * Mac labels, including their language. Never infer menu options from labels.
 * Separators are normalised after unavailable commands have been removed.
 * Menus intentionally contain no invented Copy/Paste/Delete/shortcut entries.
 * See routeDirectGesture(): many right clicks open an editor or select time,
 * rather than displaying a context menu.
 *
 * @typedef {string} ID
 * @typedef {{id?: string, label?: string, action?: () => unknown,
 *   checked?: boolean, disabled?: boolean, destructive?: boolean,
 *   separator?: boolean}} MenuItem
 * @typedef {(request: Readonly<Record<string, unknown>>) => unknown} Command
 * @typedef {{actions?: Record<string, Command>,
 *   t?: (key: string, fallback: string) => string,
 *   projectId?: ID, songId?: ID}} MenuContext
 */

function array(value) { return Array.from(value ?? []); }
function unique(value) { return [...new Set(array(value))]; }
function validId(id) { return id !== undefined && id !== null && id !== ''; }
function request(context, values = {}) {
  const result = {...values};
  if (context.projectId !== undefined) result.projectId = context.projectId;
  if (context.songId !== undefined) result.songId = context.songId;
  for (const [key, value] of Object.entries(result)) {
    if (Array.isArray(value)) result[key] = Object.freeze([...value]);
  }
  return Object.freeze(result);
}
function item(context, id, fallback, command, values = {}, options = {}) {
  const callback = context.actions?.[command];
  if (typeof callback !== 'function') return null;
  const payload = request(context, values);
  const {labelKey = id, ...presentation} = options;
  const label = context.t?.(`menu.${labelKey}`, fallback) ?? fallback;
  return {id, label, ...presentation, action: () => callback(payload)};
}
const separator = () => ({separator: true});
function menu(items) {
  const result = [];
  for (const entry of items) {
    if (!entry) continue;
    if (entry.separator && (!result.length || result.at(-1).separator)) continue;
    result.push(entry);
  }
  if (result.at(-1)?.separator) result.pop();
  return result;
}

/** A click on an unselected item targets that item alone; otherwise retain the batch. */
export function contextSelection(clickedId, selectedIds = []) {
  if (!validId(clickedId)) return [];
  const selected = unique(selectedIds).filter(validId);
  return selected.includes(clickedId) ? selected : [clickedId];
}

/**
 * TrackMixerRow.swift:677,842,1079,2137,2700,2868.
 * @param {MenuContext & {
 *   surface?: 'trackMixer'|'footerMixer',
 *   track: null|{id: ID, kind: string, parentTrackID?: ID, stereoLink?: unknown},
 *   tracks?: Array<{id: ID, kind: string, parentTrackID?: ID, stereoLink?: unknown}>,
 *   selectedIds?: Iterable<ID>, isFolder?: boolean, canLink?: boolean,
 *   deletionIds?: Iterable<ID>
 * }} context
 * `track:null` explicitly denotes master. kind is the domain TrackKind, not
 * an inferred UI label. canLink comes from the real linkableTracks predicate.
 * deletionIds may supply domain-approved deletion targets (e.g. folder children).
 * Commands: patch, fx, envelopeSettings, editTrack, createMIDI, soundDesigner,
 * group, ungroup, removeFromGroup, link, unlink, duplicateTracks, removeTracks.
 * Request: {trackId, trackIds}; editTrack adds nameEditable/master;
 * removeTracks uses deletionIds when provided. A master always has [null].
 */
export function buildTrackMenu(context = {}) {
  const {track, surface = 'trackMixer'} = context;
  if (!['trackMixer', 'footerMixer'].includes(surface)) throw new TypeError('Unknown mixer surface.');
  if (track === null) {
    const target = {trackId: null, trackIds: [null], master: true};
    return menu([
      item(context, 'track.patch', 'Patch', 'patch', target),
      item(context, 'track.fx', 'FX', 'fx', target),
      surface === 'trackMixer' && item(context, 'track.env', 'Env', 'envelopeSettings', target),
      item(context, 'track.edit', 'Editar pista', 'editTrack', {...target, nameEditable: false}),
    ]);
  }
  if (!validId(track?.id)) return [];
  const selected = unique(context.selectedIds);
  const tracks = array(context.tracks);
  if (!tracks.some(entry => entry.id === track.id)) tracks.push(track);
  const standard = track.kind === 'standard';
  const selectedTrack = standard && selected.includes(track.id);
  const trackIds = selectedTrack
    ? tracks.filter(entry => entry.kind === 'standard' && selected.includes(entry.id)).map(entry => entry.id)
    : [track.id];
  const target = {trackId: track.id, trackIds};
  const grouping = selectedTrack && selected.length > 1
    && !tracks.some(entry => selected.includes(entry.id) && entry.stereoLink != null);
  const folder = context.isFolder ?? tracks.some(entry => entry.parentTrackID === track.id);
  const deletionIds = context.deletionIds === undefined ? trackIds : unique(context.deletionIds).filter(validId);
  return menu([
    ['standard', 'timecode', 'video', 'generatedClick'].includes(track.kind)
      && item(context, 'track.patch', 'Patch', 'patch', target),
    surface === 'trackMixer' && track.kind === 'generatedClick'
      && item(context, 'track.soundDesigner', 'Sound Designer', 'soundDesigner', target),
    standard && item(context, 'track.fx', 'FX', 'fx', target),
    surface === 'trackMixer' && standard
      && item(context, 'track.createMIDI', 'Criar item MIDI', 'createMIDI', {trackId: track.id}),
    grouping && item(context, 'track.group', 'Create group', 'group', target),
    folder && item(context, 'track.ungroup', 'Ungroup', 'ungroup', {trackId: track.id}),
    track.parentTrackID != null
      && item(context, 'track.removeFromGroup', 'Remove from group', 'removeFromGroup', {trackId: track.id}),
    selectedTrack && context.canLink === true && item(context, 'track.link', 'Link tracks', 'link', target),
    track.stereoLink != null && item(context, 'track.unlink', 'Unlink tracks', 'unlink', {trackId: track.id}),
    item(context, 'track.edit', 'Editar pista', 'editTrack', {...target, master: false,
      nameEditable: standard && trackIds.length === 1}),
    standard && item(context, 'track.duplicate', trackIds.length > 1 ? 'Duplicar pistas' : 'Duplicar pista',
      'duplicateTracks', target, {labelKey: trackIds.length > 1 ? 'track.duplicateMany' : 'track.duplicateOne'}),
    separator(),
    deletionIds.length > 0 && item(context, 'track.remove', deletionIds.length > 1 ? 'Delete tracks' : 'Delete track',
      'removeTracks', {trackId: track.id, trackIds: deletionIds},
      {destructive: true, labelKey: deletionIds.length > 1 ? 'track.removeMany' : 'track.removeOne'}),
  ]);
}

/** TrackMixerRow.swift:17. Targets are resolved by the real mixerControlTargets. */
export function buildFXButtonMenu(context = {}) {
  if (!(context.insertedCount > 0)) return [];
  const trackIds = context.trackId == null ? [null] : unique(context.trackIds ?? [context.trackId]);
  return menu([item(context, 'fx.bypass', 'Bypass', 'setBypass', {
    trackId: context.trackId ?? null, trackIds, bypassed: !context.allBypassed,
  }, {checked: Boolean(context.allBypassed)})]);
}

/** TrackMixerRow.swift:71; actions.envelopeSettings({trackId}). */
export function buildEnvelopeMenu(context = {}) {
  return menu([item(context, 'env.settings', 'Envelope settings', 'envelopeSettings', {trackId: context.trackId ?? null})]);
}

/** TrackMixerRow.swift:3047. Existing slot only; By is not a checkmarked item. */
export function buildFooterFXSlotMenu(context = {}) {
  if (!validId(context.effectId)) return [];
  const target = {trackId: context.trackId ?? null, effectId: context.effectId};
  return menu([
    item(context, 'fx.slotBypass', 'By', 'toggleBypass', target),
    item(context, 'fx.remove', 'Remove', 'removeFX', target, {destructive: true}),
  ]);
}

/** ExternalPluginEditor.swift:226. Removal callback must open/obey confirmation policy. */
export function buildFXChainMenu(context = {}) {
  if (!validId(context.effectId)) return [];
  return menu([item(context, 'fx.remove', 'Remove', 'removeFX', {
    trackId: context.trackId ?? null, clipId: context.clipId ?? null, effectId: context.effectId,
  }, {destructive: true})]);
}

/**
 * SongListView.swift:274; AudioExportPlan.swift:40.
 * region is the clicked region; regions contains ALL current-song regions,
 * visibleRegionIds contains only filtered/current-playlist region IDs (no
 * block IDs, including virtualised rows). selectedIds may include block IDs.
 * Detection follows visible order; export preserves explicitly selected parent
 * AND child regions. Menu removal targets the CLICKED root, not the batch.
 * @param {MenuContext & {region: {id:ID,parentRegionID?:ID}, regions: Array<{id:ID}>,
 *   selectedIds?: Iterable<ID>, visibleRegionIds: Iterable<ID>, unified?: boolean,
 *   playlistId?: ID|null}} context
 * Commands: multiloops({regionId}), detectBPM({regionIds}), exportAudio({regionIds}),
 * editSong({regionId,entryIds,regionIds}), removeEntries({entryIds,playlistId,keyboard}).
 */
export function buildSetlistSongMenu(context = {}) {
  const {region} = context;
  if (!validId(region?.id)) return [];
  const entryIds = contextSelection(region.id, context.selectedIds);
  const allRegions = new Set(array(context.regions).map(entry => entry.id));
  const regionIds = entryIds.filter(id => allRegions.has(id));
  const detectIds = unique(context.visibleRegionIds).filter(id => entryIds.includes(id) && allRegions.has(id));
  return menu([
    entryIds.length === 1 && !context.unified
      && item(context, 'song.multiloops', 'Multiloops', 'multiloops', {regionId: region.id}),
    item(context, 'song.detectBPM', 'Detect BPM…', 'detectBPM', {regionIds: detectIds}),
    item(context, 'song.export', 'Export Audio', 'exportAudio', {regionIds}, {disabled: regionIds.length === 0}),
    item(context, 'song.edit', 'Edit song', 'editSong', {regionId: region.id, entryIds, regionIds}),
    region.parentRegionID == null && validId(context.playlistId) && entryIds.length === 1
      && item(context, 'song.duplicate', 'Duplicate region', 'duplicateRegion',
        {entryId: region.id, playlistId: context.playlistId}),
    region.parentRegionID == null && item(context, 'song.remove',
      context.playlistId == null ? 'Delete region' : 'Remove from playlist', 'removeEntries',
      {entryIds: [region.id], playlistId: context.playlistId ?? null, keyboard: false},
      {destructive: true, labelKey: context.playlistId == null ? 'song.deleteRegion' : 'song.removeFromPlaylist'}),
  ]);
}

/** SongListView.swift:176,791. Header never gains the choice-row edit/delete menu. */
export function buildPlaylistMenu(context = {}) {
  const {surface = 'choice', playlistId = null} = context;
  if (!['header', 'choice'].includes(surface)) throw new TypeError('Unknown playlist surface.');
  const target = {playlistId};
  const items = [item(context, 'playlist.copy', 'Copy to share', 'copyToShare', target,
    {disabled: context.hasSong !== true})];
  if (surface === 'choice' && validId(playlistId)) items.push(separator(),
    item(context, 'playlist.addRegions', 'Add regions', 'addRegions', target),
    item(context, 'playlist.edit', 'Edit', 'editPlaylist', target),
    item(context, 'playlist.clone', 'Clone playlist', 'clonePlaylist', target),
    item(context, 'playlist.remove', 'Delete playlist', 'removePlaylist', target, {destructive: true}));
  return menu(items);
}

/** RegionEditor.swift:381. Domain eligibility is represented by optional callbacks. */
export function buildRegionMenu(context = {}) {
  if (!validId(context.regionId)) return [];
  const target = {regionId: context.regionId};
  return menu([
    item(context, 'region.edit', 'Edit', 'editRegion', target),
    item(context, 'region.detectBPM', 'Detect BPM…', 'detectBPM', target),
    item(context, 'region.unify', 'Unify', 'unify', target),
    item(context, 'region.disunify', 'Disunify', 'disunify', target),
    item(context, 'region.export', 'Export Audio', 'exportAudio', target),
    item(context, 'region.remove', 'Delete region', 'removeRegion', target, {destructive: true}),
  ]);
}

/**
 * GridSelectionInput.swift:1131–1268. item/items are projected GridSelectionItem
 * descriptors, not raw AudioClip: {id, editable, midiEditable, audioExportable,
 * contextActions, muted, hasFX}. The caller computes those domain capabilities.
 * selectedIds includes all selected items. A right drag is marquee selection
 * and MUST NOT call this builder. Use the click result only on pointer-up.
 * Commands: setMuted({itemIds,muted}), freezeMIDI({itemIds,channels}),
 * unify({itemIds}), openFX({itemId,insert:false}), createRegion({itemId}),
 * reRender/normalize/tuner/exportAudio({itemIds}), convertAudio({itemIds,mode}).
 * Conversion modes are the Mac values: 1=L, 2=R, 3=L-R, 0=stereo.
 * @param {MenuContext & {item: {id:ID}, items:Array<Object>, selectedIds?:Iterable<ID>}} context
 */
export function buildTimelineItemMenu(context = {}) {
  const clicked = context.item;
  if (!validId(clicked?.id)) return [];
  const selectedIds = contextSelection(clicked.id, context.selectedIds);
  const lookup = new Map(array(context.items).map(entry => [entry.id, entry]));
  lookup.set(clicked.id, clicked);
  const selected = selectedIds.map(id => lookup.get(id)).filter(Boolean);
  const ids = predicate => selected.filter(predicate).map(entry => entry.id);
  const exportIds = ids(entry => entry.editable && entry.audioExportable);
  if (!clicked.contextActions && !exportIds.length) return [];
  const editable = selected.filter(entry => entry.editable);
  const unifyIds = ids(entry => entry.editable && (entry.audioExportable || entry.midiEditable));
  const entries = [];
  const muteItem = eligible => {
    const muted = !eligible.every(entry => entry.muted);
    return item(context, muted ? 'item.mute' : 'item.unmute', muted ? 'Mute items' : 'Unmute items',
      'setMuted', {itemIds: eligible.filter(entry => Boolean(entry.muted) !== muted).map(entry => entry.id), muted});
  };
  if (clicked.midiEditable) {
    const midi = editable.filter(entry => entry.midiEditable);
    entries.push(muteItem(midi));
    for (const [channels, label] of [[1, 'Convert Mono'], [2, 'Convert Stereo']])
      entries.push(item(context, `item.midiConvert${channels}`, label, 'freezeMIDI', {itemIds: midi.map(entry => entry.id), channels}));
    entries.push(item(context, 'item.unify', 'Unify items', 'unify', {itemIds: unifyIds}));
    if (clicked.hasFX) entries.push(item(context, 'item.fx', 'FX', 'openFX', {itemId: clicked.id, insert: false}));
    return menu(entries); // The Mac MIDI branch has no audio export tail.
  }
  if (clicked.contextActions) {
    entries.push(
      item(context, 'item.createRegion', 'Criar região do item', 'createRegion', {itemId: clicked.id}),
      item(context, 'item.reRender', 'Re-render', 'reRender', {itemIds: selectedIds}),
      item(context, 'item.unify', 'Unify items', 'unify', {itemIds: unifyIds}),
      item(context, 'item.tuner', 'Tuner', 'tuner', {itemIds: ids(entry => entry.audioExportable && !entry.midiEditable)}),
      ...(selectedIds.length === 1 && clicked.editable && clicked.audioExportable && !clicked.midiEditable && !clicked.isProjectionMedia ? [item(context, 'item.separateAudio', 'Separation audio', 'separateAudio', {itemId: clicked.id})] : []),
      item(context, 'item.normalize', 'Normalize…', 'normalize', {itemIds: selectedIds}));
    if (clicked.editable) {
      entries.push(separator());
      for (const [mode, label] of [[1, 'Convert Mono - L'], [2, 'Convert Mono - R'], [3, 'Convert Mono L-R'], [0, 'Convert Stereo']])
        entries.push(item(context, `item.audioConvert${mode}`, label, 'convertAudio', {itemIds: selectedIds, mode}));
    }
  }
  if (editable.length) entries.push(separator(), muteItem(editable));
  entries.push(separator(), item(context, 'item.export', 'Export', 'exportAudio', {itemIds: exportIds}, {disabled: exportIds.length === 0}));
  return menu(entries);
}

/** GridSelectionInput.swift:1171. The caller resolves the hit-tested lane/point. */
export function buildBlankGridMenu(context = {}) {
  return menu([item(context, 'grid.createMIDI', 'Criar item MIDI', 'createMIDI', {
    trackId: context.trackId, point: context.point ? Object.freeze({...context.point}) : undefined,
  })]);
}

/** TimelineGridView.swift:3596. Secondary/subplay head has no context menu. */
export function buildEditCursorMenu(context = {}) {
  if (context.secondary) return [];
  return menu([
    item(context, 'cursor.marker', 'Create marker', 'createMarker', {tempo: false}),
    item(context, 'cursor.tempoMarker', 'Create tempo marker', 'createTempoMarker', {tempo: true}),
  ]);
}

/** TeleprompterWindow.swift:495. index must be 1 or 2. */
export function buildTeleprompterMenu(context = {}) {
  if (context.index !== 1 && context.index !== 2) return [];
  return menu([
    item(context, 'tp.settings', 'Configurações', 'settings', {index: context.index}),
    item(context, 'tp.remote', 'TP Remoto', 'remote', {index: context.index}),
  ]);
}

/** TransportView.swift:1043. Deliberately no Import command. */
export function buildVideoMenu(context = {}) {
  return menu([item(context, 'video.stretch', 'Stretch', 'setStretch', {stretch: !context.stretch}, {checked: Boolean(context.stretch)})]);
}

/** MainView.swift:471. undocked=true means the action is Dock mixer. */
export function buildMixerDockMenu(context = {}) {
  return menu([item(context, 'mixer.dock', context.undocked ? 'Dock mixer' : 'Undock mixer', 'setDocked',
    {docked: Boolean(context.undocked)}, {labelKey: context.undocked ? 'mixer.dock' : 'mixer.undock'})]);
}

/** ProjectDocuments.swift:1309. requestDeletion must retain the confirmation workflow. */
export function buildRecentProjectMenu(context = {}) {
  if (!context.path || context.busy || context.playing) return [];
  return menu([item(context, 'recent.remove', context.missing ? 'Remove from recents' : 'Delete project',
    'requestDeletion', {path: context.path, missing: Boolean(context.missing)},
    {destructive: true, labelKey: context.missing ? 'recent.removeMissing' : 'recent.deleteProject'})]);
}

/** AutomationEditor.swift:314. Caller performs nearest-point selection before building. */
export function buildAutomationPointMenu(context = {}) {
  if (!validId(context.envelopeId)) return [];
  return menu([['linear', 'Linear'], ['square', 'Square'], ['smooth', 'Smooth'],
    ['fastStart', 'Fast start'], ['fastEnd', 'Fast end']].map(([shape, label]) =>
    item(context, `automation.${shape}`, label, 'setShape', {
      envelopeId: context.envelopeId, pointIds: unique(context.pointIds), shape,
    })));
}

/** FXParameterMapping.swift:33. The scoped parameter descriptor is supplied by its real editor. */
export function buildFXParameterMenu(context = {}) {
  if (!context.parameter || !context.scope) return [];
  return menu([item(context, 'fx.mapMIDI', 'Map MIDI', 'mapMIDI', {
    scope: Object.freeze({...context.scope}), parameter: Object.freeze({...context.parameter}),
  })]);
}

/**
 * Normalised direct gestures, NOT DOM listeners or popup menu choices.
 * `context` is a completed right click (or Mac Control-click), never the
 * initial down of a possible drag. Normalisation must NOT treat Windows
 * Ctrl+left-click as a right click. A pointer capture owner routes drag phases.
 * Source: TransportView:675; TimelineWheelInput:999; MIDIEditor:345;
 * RegionEditor:437; TrackMixerRow:17,3047; ExternalPluginEditor:219.
 * The remaining direct configuration targets correspond to immediateRightClick
 * call sites; the consumer supplies the existing real editor callbacks.
 */
export const DIRECT_GESTURES = Object.freeze(Object.fromEntries(Object.entries({
  save: {context: 'exportPortable'},
  timelineHeader: {context: 'seekSubplay', rightDragStart: 'beginTimeSelection', rightDrag: 'updateTimeSelection', rightDragEnd: 'endTimeSelection'},
  pianoRoll: {rightDown: 'beginNoteSelection', rightDrag: 'updateNoteSelection', rightUp: 'endNoteSelection'},
  marker: {context: 'editMarker', altClick: 'removeMarker'},
  fxButton: {shiftClick: 'setBypass', altClick: 'removeAllFX'},
  fxSlot: {shiftClick: 'toggleBypass', altClick: 'removeFX', altContext: 'removeFX'},
  fxChainRow: {altClick: 'toggleBypass', altContext: 'removeFX'},
  setlistBlock: {context: 'editBlock'},
  setlistAuto: {context: 'configureAuto'},
  setlistBlocks: {context: 'configureBlockDefaults'},
  bpm: {context: 'editBPM'},
  bpmStep: {context: 'mapControl'},
  mixerControl: {context: 'mapControl'},
  metronome: {context: 'configureMetronome'},
  remote: {context: 'configureRemote'},
  keyboard: {context: 'configureKeyboard'},
  tuner: {context: 'editTuner'},
  teleprompterPreview: {context: 'choosePreviewPage'},
  teleprompterTimer: {context: 'configureTimer'},
  record: {context: 'configureRecording'},
  eqGraph: {context: 'addBand'},
}).map(([target, gestures]) => [target, Object.freeze(gestures)])));

/**
 * @param {{target:string, gesture:string, context?:MenuContext & Object}} input
 * @returns {{handled:boolean, result?:unknown}}
 * No DOM mutation or preventDefault occurs here. Only consume a DOM gesture
 * when handled=true; await result/catch errors through the application's UI.
 * Context payload is `data` (captured coordinates/IDs), never an Event object.
 * Domain gates: blocked; pianoRoll editable/inNoteArea; marker sourceRegionID/
 * unifiedRegionID; fxButton insertedCount; setlistBlocks playlistId. Other
 * capabilities are represented by callback presence. Same-event duplication
 * and pointer capture belong to the consumer, as with SelectionRouter.
 */
export function routeDirectGesture({target, gesture, context = {}} = {}) {
  if (context.blocked) return {handled: false};
  const gestures = Object.hasOwn(DIRECT_GESTURES, target) ? DIRECT_GESTURES[target] : undefined;
  const command = gestures && Object.hasOwn(gestures, gesture) ? gestures[gesture] : undefined;
  const callback = command && context.actions?.[command];
  if (typeof callback !== 'function') return {handled: false};
  if (target === 'pianoRoll' && (!context.editable || !context.inNoteArea)) return {handled: false};
  if (target === 'marker' && gesture === 'altClick'
      && (context.sourceRegionID != null || context.unifiedRegionID != null)) return {handled: false};
  if (target === 'fxButton' && !(context.insertedCount > 0)) return {handled: false};
  if (target === 'setlistBlocks' && !validId(context.playlistId)) return {handled: false};
  const values = {...context.data};
  if (target === 'fxButton' && gesture === 'shiftClick') values.bypassed = !context.allBypassed;
  return {handled: true, result: callback(request(context, values))};
}
