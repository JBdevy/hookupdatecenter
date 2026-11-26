export const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value) || 0));
export function decibels(gain) { return gain > 0 ? 20 * Math.log10(gain) : -Infinity; }
export function gainLabel(gain, digits = 1) {
  const db = decibels(gain);
  return Number.isFinite(db) ? `${db >= 0 ? '+' : ''}${db.toFixed(digits)}` : '−∞';
}
// Match GainFader.h: linear dB travel from -60 to +12, with silence at zero.
export const sliderGain = value => value <= 0 ? 0 : Math.pow(10, (-60 + clamp(value, 0, 1) * 72) / 20);
export const gainSlider = gain => gain <= 0 ? 0 : clamp((decibels(gain) + 60) / 72, 0, 1);
export function clock(seconds, hours = false) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0));
  const s = String(seconds % 60).padStart(2, '0'), m = String(Math.floor(seconds / 60) % 60).padStart(2, '0');
  return hours || seconds >= 3600 ? `${String(Math.floor(seconds / 3600)).padStart(2, '0')}:${m}:${s}` : `${m}:${s}`;
}
export function color(value, fallback = '#414141') {
  return typeof value === 'number' && Number.isFinite(value) ? `#${(value & 0xffffff).toString(16).padStart(6, '0')}` : fallback;
}
export function readable(value) {
  const n = Number.parseInt(value.slice(1), 16);
  return .2126 * (n >> 16) + .7152 * ((n >> 8) & 255) + .0722 * (n & 255) > 155 ? '#111' : '#fff';
}
// Only a connected group of overlapping items shares vertical space. An
// unrelated collision elsewhere in the track must not shrink an isolated item.
export function itemLanes(clips = []) {
  const tolerance = 1e-9, entries = new Map();
  const ordered = clips.filter(clip => Number.isFinite(clip.startTime) && Number.isFinite(clip.duration) && clip.duration > 0)
    .slice().sort((a,b) => a.startTime-b.startTime || (a.id<b.id?-1:a.id>b.id?1:0));
  let group = [], end = -Infinity, count = 1;
  const placeGroup = () => {
    if (!group.length) return;
    const ends = [], placed = [], lanes = new Map();
    let localCount = 1;
    const remember = (clip,lane) => { lanes.set(clip.id,lane); placed.push(clip); localCount=Math.max(localCount,lane+1); };
    for (const clip of group.filter(clip => clip.recordingLane == null)) {
      let lane=ends.findIndex(end => end<=clip.startTime+tolerance);
      if (lane<0) lane=ends.length;
      ends[lane]=clip.startTime+clip.duration; remember(clip,lane);
    }
    // Persisted takes retain their existing stacking order. This does not add a
    // recording preview or synthesize clips that the native host did not send.
    for (const clip of group.filter(clip => clip.recordingLane != null).sort((a,b) => a.recordingLane-b.recordingLane || a.startTime-b.startTime || (a.id<b.id?-1:a.id>b.id?1:0))) {
      let lane=0;
      for (const other of placed)
        if (other.startTime<clip.startTime+clip.duration-tolerance && other.startTime+other.duration>clip.startTime+tolerance)
          lane=Math.max(lane,lanes.get(other.id)+1);
      remember(clip,lane);
    }
    for (const clip of group) entries.set(clip.id,{localLane:lanes.get(clip.id),localCount});
    count=Math.max(count,localCount); group=[];
  };
  for (const clip of ordered) {
    if (group.length && clip.startTime>=end-tolerance) { placeGroup(); end=-Infinity; }
    group.push(clip); end=Math.max(end,clip.startTime+clip.duration);
  }
  placeGroup(); return {entries,count};
}
export function layoutTracks(tracks, heightOverrides = new Map()) {
  let y = 0;
  const byID = new Map(tracks.map(track => [track.id, track]));
  return tracks.map(track => {
    let depth = 0, parent = track.parentTrackID;
    const visited = new Set([track.id]);
    while (parent && !visited.has(parent) && depth < 5) { visited.add(parent); depth++; parent = byID.get(parent)?.parentTrackID; }
    const lanes=itemLanes(track.clips), multiple=lanes.count>1;
    const laneHeight=clamp(Math.round(72*(track.heightScale??1)*(multiple?.7:1)),multiple?26:24,multiple?168:480);
    const height = clamp(heightOverrides.get(track.id) ?? laneHeight*lanes.count, 24, Math.max(480,168*lanes.count));
    const row = {track, y, height, audioHeight:height, itemLanes:lanes, indent: depth ? 16 + (depth - 1) * 8 : 0}; y += height;
    return row;
  });
}
export function regionLanes(parts) {
  const ends = [], rows = new Map();
  for (const part of [...parts].sort((a, b) => a.startTime - b.startTime || b.endTime - a.endTime)) {
    const minimum = part.parentRegionID ? (rows.get(part.parentRegionID) ?? 0) + 1 : 0;
    let lane = minimum;
    while ((ends[lane] ?? -Infinity) > part.startTime + 1e-7) lane++;
    ends[lane] = part.endTime; rows.set(part.id, lane);
  }
  return {rows, count: Math.max(1, ends.length)};
}
export function playlistRows(project, song) {
  const parts = song?.parts ?? [], state = project?.regionSetlist;
  const playlist = state?.playlists?.find(item => item.id === state.selectedId && item.songId === song?.id);
  if (!playlist) return {name: 'All Regions', id: '', rows: parts.filter(part => !part.parentRegionID).map(part => ({entryID: part.id, part}))};
  const byID = new Map(parts.map(part => [part.id, part]));
  const aliases = new Map((playlist.duplicates ?? []).map(item => [item.id, item.regionId]));
  return {name: playlist.name, id: playlist.id, rows: (playlist.regionIds ?? []).flatMap(entryID => {
    const part = byID.get(aliases.get(entryID) ?? entryID); return part ? [{entryID, part}] : [];
  })};
}
export function meterFraction(gain) { return clamp((decibels(gain) + 60) / 60, 0, 1); }
export function fadeCurve(position, curvature = 0, sCurve = 1) {
  const t = clamp(position, 0, 1), bias = Math.pow(2, 4 * clamp(curvature, -1, 1));
  const shaped = t + clamp(sCurve, -1, 1) * (t * t * (3 - 2 * t) - t);
  return shaped / (bias + (1 - bias) * shaped);
}
export function fadeGain(clip, position) {
  const input = Math.min(clip.duration, clip.fadeIn ?? 0), output = Math.min(clip.duration, clip.fadeOut ?? 0);
  return (input > 0 ? fadeCurve((position - clip.startTime) / input, clip.fadeInCurve, clip.fadeInSCurve) : 1)
    * (output > 0 ? fadeCurve((clip.startTime + clip.duration - position) / output, clip.fadeOutCurve, clip.fadeOutSCurve) : 1);
}
export function zoomAt({scale, offset, x, delta, width, duration}) {
  const next = clamp(scale * Math.exp(-delta * .0025), .015, 2000);
  return {scale: next, offset: clamp((offset + x / scale) - x / next, 0, Math.max(0, duration - width / next))};
}
