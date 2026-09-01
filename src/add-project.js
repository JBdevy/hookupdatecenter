const path = require('path');
const {
  CREATE_PROJECT_REGION_GAP_SECONDS,
  CREATE_PROJECT_TRACK_GROUPS,
  buildFolderTrackChunk,
  buildItemChunk,
  buildTrackChunk,
  classifyCreateProjectTrack,
  compareTracks,
  createGuid,
  normalizeTrackKey,
  quoteRpp,
  rppNumber,
  resolveCreateProjectTrackGroup
} = require('./create-project');

function parseRppName(line) {
  const value = String(line || '').replace(/^\s*NAME\s+/, '').trim();
  if (!value.startsWith('"')) return value;
  const closingQuote = value.lastIndexOf('"');
  return closingQuote > 0 ? value.slice(1, closingQuote) : value.slice(1);
}

function canonicalExistingTrackKey(trackName) {
  const classification = classifyCreateProjectTrack(`${String(trackName || '')}.wav`);
  return classification.recognized ? classification.key : normalizeTrackKey(trackName);
}

function groupKeyFromFolderName(folderName) {
  const key = normalizeTrackKey(folderName);
  const exact = CREATE_PROJECT_TRACK_GROUPS.find((group) => normalizeTrackKey(group.name) === key);
  if (exact) return exact.key;
  if (key === 'percussao' || key === 'percussivo') return 'percussivo';
  if (key === 'back-vocal' || key === 'back-vocais' || key === 'backing-vocals') return 'back-vocais';
  return '';
}

function parseTopLevelTrackRanges(lines) {
  const tracks = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^  <TRACK(?:\s|$)/.test(lines[index])) continue;
    let end = index + 1;
    while (end < lines.length && !/^  >\s*$/.test(lines[end])) end += 1;
    if (end >= lines.length) throw new Error('O arquivo .rpp possui uma pista incompleta.');
    const headerEnd = Math.min(end, lines.findIndex((line, lineIndex) => lineIndex > index && /^    </.test(line)));
    const safeHeaderEnd = headerEnd < 0 ? end : headerEnd;
    const headerLines = lines.slice(index + 1, safeHeaderEnd);
    const nameLine = headerLines.find((line) => /^    NAME\s+/.test(line));
    const colorLine = headerLines.find((line) => /^    PEAKCOL\s+/.test(line));
    const isBusOffset = headerLines.findIndex((line) => /^    ISBUS\s+/.test(line));
    const isBusLine = isBusOffset >= 0 ? headerLines[isBusOffset] : '    ISBUS 0 0';
    const isBusMatch = isBusLine.match(/^\s*ISBUS\s+(-?\d+)\s+(-?\d+)/);
    const folderDelta = Number(isBusMatch?.[2] || 0);
    tracks.push({
      index: tracks.length,
      start: index,
      end,
      name: nameLine ? parseRppName(nameLine) : `Pista ${tracks.length + 1}`,
      color: Number(colorLine?.match(/^\s*PEAKCOL\s+(-?\d+)/)?.[1]) || 16576,
      isBusLineIndex: isBusOffset >= 0 ? index + 1 + isBusOffset : -1,
      isBusType: Number(isBusMatch?.[1] || 0),
      folderDelta,
      isFolder: folderDelta > 0
    });
    index = end;
  }

  const folderStack = [];
  for (const track of tracks) {
    track.depthBefore = folderStack.length;
    track.parentIndex = folderStack.length ? folderStack[folderStack.length - 1] : null;
    if (track.folderDelta > 0) {
      for (let count = 0; count < track.folderDelta; count += 1) folderStack.push(track.index);
    } else if (track.folderDelta < 0) {
      for (let count = 0; count < Math.abs(track.folderDelta); count += 1) folderStack.pop();
    }
    track.depthAfter = folderStack.length;
  }

  for (const folder of tracks.filter((track) => track.isFolder)) {
    folder.closingTrackIndex = tracks.find((track) =>
      track.index > folder.index && track.depthAfter <= folder.depthBefore)?.index ?? null;
    folder.directChildren = tracks.filter((track) => track.parentIndex === folder.index).map((track) => track.index);
  }
  return tracks;
}

function inspectRppProject(rppText) {
  const text = String(rppText || '');
  if (!text.trimStart().startsWith('<REAPER_PROJECT')) throw new Error('O arquivo selecionado não é um projeto válido do REAPER.');
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const tracks = parseTopLevelTrackRanges(lines);
  let timelineEnd = 0;
  let maxMarkerId = 0;
  let maxItemId = 0;
  const regionIds = new Set();

  for (const line of lines) {
    const marker = line.match(/^\s*MARKER\s+(\d+)\s+(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(.*)$/);
    if (marker) {
      const markerId = Number(marker[1]) || 0;
      const position = Number(marker[2]) || 0;
      maxMarkerId = Math.max(maxMarkerId, markerId);
      timelineEnd = Math.max(timelineEnd, position);
      if (/\sR(?:\s|$)/.test(marker[3])) regionIds.add(markerId);
    }
    const itemId = line.match(/^\s*IID\s+(\d+)/);
    if (itemId) maxItemId = Math.max(maxItemId, Number(itemId[1]) || 0);
  }

  for (const track of tracks) {
    for (let index = track.start + 1; index < track.end; index += 1) {
      if (!/^    <ITEM(?:\s|$)/.test(lines[index])) continue;
      let itemEnd = index + 1;
      while (itemEnd < track.end && !/^    >\s*$/.test(lines[itemEnd])) itemEnd += 1;
      const itemLines = lines.slice(index + 1, itemEnd);
      const position = Number(itemLines.find((line) => /^      POSITION\s+/.test(line))?.trim().split(/\s+/)[1]) || 0;
      const length = Number(itemLines.find((line) => /^      LENGTH\s+/.test(line))?.trim().split(/\s+/)[1]) || 0;
      timelineEnd = Math.max(timelineEnd, position + length);
      index = itemEnd;
    }
  }

  const groupFolders = new Map();
  for (const track of tracks.filter((item) => item.isFolder)) {
    const groupKey = groupKeyFromFolderName(track.name);
    if (groupKey && !groupFolders.has(groupKey)) groupFolders.set(groupKey, track);
  }
  const firstTrackStart = tracks[0]?.start;
  const rootClosingLine = (() => {
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      if (/^>\s*$/.test(lines[index])) return index;
    }
    return lines.length;
  })();

  return {
    text,
    newline,
    lines,
    tracks,
    groupFolders,
    timelineEnd,
    maxMarkerId,
    maxItemId,
    regionCount: regionIds.size,
    markerInsertIndex: Number.isInteger(firstTrackStart) ? firstTrackStart : rootClosingLine,
    rootClosingLine
  };
}

function buildExistingTrackMap(model) {
  const result = new Map();
  for (const track of model.tracks) {
    if (track.isFolder) continue;
    const key = canonicalExistingTrackKey(track.name);
    if (!result.has(key)) result.set(key, track);
  }
  return result;
}

function shiftIncomingAudit(incomingAudit, appendStart, mediaSequenceOffset) {
  const songs = incomingAudit.songs.map((song, index) => ({
    ...song,
    mediaIndex: mediaSequenceOffset + index,
    start: song.start + appendStart,
    end: song.end + appendStart
  }));
  return {
    ...incomingAudit,
    songs,
    totalDuration: songs.length ? songs[songs.length - 1].end : appendStart
  };
}

function auditAddProjectRpp(rppText, incomingAudit, { projectPath = '' } = {}) {
  if (!incomingAudit?.songs?.length || !incomingAudit?.tracks?.length) {
    throw new Error('A auditoria não possui músicas válidas para adicionar.');
  }
  const model = inspectRppProject(rppText);
  const appendStart = model.timelineEnd > 0 ? model.timelineEnd + CREATE_PROJECT_REGION_GAP_SECONDS : 0;
  const shifted = shiftIncomingAudit(incomingAudit, appendStart, model.regionCount);
  const existingTracks = buildExistingTrackMap(model);
  const tracks = shifted.tracks.map((track) => {
    const existing = existingTracks.get(track.key);
    const group = resolveCreateProjectTrackGroup(track.name);
    return {
      ...track,
      groupKey: group.key,
      groupName: group.name,
      action: existing ? 'reuse' : 'create',
      existingTrackName: existing?.name || '',
      existingTrackIndex: existing?.index ?? null,
      targetGroupExists: model.groupFolders.has(group.key)
    };
  });
  const groups = shifted.groups.map((group) => ({
    ...group,
    tracks: tracks.filter((track) => track.groupKey === group.key)
  }));
  return {
    ...shifted,
    projectPath: projectPath ? path.resolve(projectPath) : '',
    projectFileName: projectPath ? path.basename(projectPath) : '',
    tracks,
    groups,
    existingProjectTrackCount: model.tracks.length,
    existingTimelineEnd: model.timelineEnd,
    appendStart,
    existingRegionCount: model.regionCount,
    reusedTrackCount: tracks.filter((track) => track.action === 'reuse').length,
    newTrackCount: tracks.filter((track) => track.action === 'create').length,
    existingGroupCount: new Set(tracks.filter((track) => track.targetGroupExists).map((track) => track.groupKey)).size
  };
}

function addInsertion(insertions, lineIndex, newLines) {
  if (!newLines?.length) return;
  if (!insertions.has(lineIndex)) insertions.set(lineIndex, []);
  insertions.get(lineIndex).push(...newLines);
}

function replaceFolderClosingDelta(chunk, folderDelta) {
  return chunk.map((line) => /^    ISBUS\s+2\s+-1\s*$/.test(line)
    ? `    ISBUS 2 ${folderDelta}`
    : line);
}

function buildAddProjectRpp(rppText, audit) {
  if (!audit?.songs?.length || !audit?.tracks?.length) throw new Error('A auditoria do Add Project está vazia.');
  const model = inspectRppProject(rppText);
  const existingTracks = buildExistingTrackMap(model);
  const insertions = new Map();
  const replacements = new Map();
  const itemCounter = { value: model.maxItemId };

  let regionId = model.maxMarkerId;
  const markerLines = [];
  for (const song of audit.songs) {
    regionId += 1;
    markerLines.push(`  MARKER ${regionId} ${rppNumber(song.start)} ${quoteRpp(song.name)} 1 0 1 R ${createGuid()} 0 1`);
    markerLines.push(`  MARKER ${regionId} ${rppNumber(song.end)} "" 1`);
  }
  addInsertion(insertions, model.markerInsertIndex, markerLines);

  const newTracks = [];
  for (const track of audit.tracks) {
    const existing = existingTracks.get(track.key);
    if (!existing) {
      newTracks.push(track);
      continue;
    }
    const itemLines = [];
    for (const song of audit.songs) {
      for (const file of song.files.filter((item) => item.trackKey === track.key)) {
        itemCounter.value += 1;
        itemLines.push(...buildItemChunk(file, song, itemCounter.value));
      }
    }
    addInsertion(insertions, existing.end, itemLines);
  }

  const auditGroups = audit.groups.map((group) => ({
    ...group,
    tracks: newTracks.filter((track) => track.groupKey === group.key).sort(compareTracks)
  })).filter((group) => group.tracks.length);

  for (const group of auditGroups) {
    const existingFolder = model.groupFolders.get(group.key);
    if (!existingFolder) {
      const chunks = [...buildFolderTrackChunk(group)];
      group.tracks.forEach((track, index) => {
        chunks.push(...buildTrackChunk(track, audit.songs, itemCounter, group.color, index === group.tracks.length - 1));
      });
      addInsertion(insertions, model.rootClosingLine, chunks);
      continue;
    }

    const directChildren = existingFolder.directChildren.map((index) => model.tracks[index]);
    const color = existingFolder.color || group.color;
    const beforeTargets = new Map();
    const tailTracks = [];
    for (const newTrack of group.tracks) {
      const target = directChildren.find((child) => {
        if (child.isFolder) return false;
        const classification = classifyCreateProjectTrack(`${child.name}.wav`);
        const comparableName = classification.recognized ? classification.name : child.name;
        return compareTracks(newTrack, { name: comparableName }) < 0;
      });
      if (!target) tailTracks.push(newTrack);
      else {
        if (!beforeTargets.has(target.start)) beforeTargets.set(target.start, []);
        beforeTargets.get(target.start).push(newTrack);
      }
    }
    for (const [lineIndex, tracks] of beforeTargets) {
      const chunks = [];
      tracks.forEach((track) => chunks.push(...buildTrackChunk(track, audit.songs, itemCounter, color, false)));
      addInsertion(insertions, lineIndex, chunks);
    }
    if (tailTracks.length) {
      const closingTrack = model.tracks[existingFolder.closingTrackIndex];
      if (!closingTrack || closingTrack.isBusLineIndex < 0 || closingTrack.folderDelta >= 0) {
        throw new Error(`Não foi possível inserir novas pistas dentro do grupo ${existingFolder.name}.`);
      }
      replacements.set(closingTrack.isBusLineIndex, '    ISBUS 0 0');
      const chunks = [];
      tailTracks.forEach((track, index) => {
        let chunk = buildTrackChunk(track, audit.songs, itemCounter, color, index === tailTracks.length - 1);
        if (index === tailTracks.length - 1) chunk = replaceFolderClosingDelta(chunk, closingTrack.folderDelta);
        chunks.push(...chunk);
      });
      addInsertion(insertions, closingTrack.end + 1, chunks);
    }
  }

  const recordPathLine = model.lines.findIndex((line) => /^  RECORD_PATH\s+/.test(line));
  if (recordPathLine >= 0) replacements.set(recordPathLine, '  RECORD_PATH "Media" ""');

  const output = [];
  for (let index = 0; index < model.lines.length; index += 1) {
    if (insertions.has(index)) output.push(...insertions.get(index));
    output.push(replacements.get(index) ?? model.lines[index]);
  }
  if (insertions.has(model.lines.length)) output.push(...insertions.get(model.lines.length));
  return `${output.join(model.newline).replace(/(?:\r?\n)*$/, '')}${model.newline}`;
}

module.exports = {
  auditAddProjectRpp,
  buildAddProjectRpp,
  canonicalExistingTrackKey,
  inspectRppProject
};
