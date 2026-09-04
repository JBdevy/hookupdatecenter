const dgram = require('dgram');

function finiteNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function positiveInteger(value, fallback = 1, maximum = 99999) {
  const hasValue = value !== null && value !== undefined &&
    String(value).trim() !== '';
  const number = Math.trunc(finiteNumber(hasValue ? value : fallback, fallback));
  return Math.min(maximum, Math.max(1, number));
}

function xmlEscape(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function cleanLabel(value, fallback = 'Marcador') {
  const cleaned = String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return (cleaned || fallback).slice(0, 96);
}

function safeFileStem(value) {
  const normalized = cleanLabel(value, 'Projeto VS Hook')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[<>:"/\\|?*]+/g, '-')
    .replace(/[. ]+$/g, '')
    .trim();
  return (normalized || 'Projeto VS Hook').slice(0, 100);
}

function normalizeMarkers(rawMarkers) {
  if (!Array.isArray(rawMarkers)) return [];
  return rawMarkers
    .map((marker, sourceIndex) => {
      const position = Math.max(0, finiteNumber(
        marker?.position ?? marker?.pos ?? marker?.time, 0));
      const markerNumber = positiveInteger(
        marker?.number ?? marker?.index ?? sourceIndex + 1,
        sourceIndex + 1);
      return {
        id: String(marker?.id || `m${markerNumber}`),
        number: markerNumber,
        name: cleanLabel(marker?.name ?? marker?.label, `Marcador ${markerNumber}`),
        position,
        color: /^#[0-9a-f]{6}$/i.test(String(marker?.color || ''))
          ? String(marker.color).toUpperCase()
          : ''
      };
    })
    .sort((left, right) => left.position - right.position || left.number - right.number)
    .map((marker, cueIndex) => ({ ...marker, cue: cueIndex + 1 }));
}

function normalizeSongs(rawRegions) {
  if (!Array.isArray(rawRegions)) return [];
  return rawRegions
    .filter((region) => region && region.isBlock !== true && region.isHashParent !== true)
    .map((region, sourceIndex) => {
      const start = Math.max(0, finiteNumber(
        region.startPos ?? region.start ?? region.position, 0));
      const end = Math.max(start, finiteNumber(
        region.endPos ?? region.end, start));
      return {
        id: String(region.id || region.uid || `song-${sourceIndex + 1}`),
        name: cleanLabel(region.name ?? region.label, `Música ${sourceIndex + 1}`),
        start,
        end,
        sourceIndex
      };
    })
    .filter((song) => song.end > song.start + 0.0005)
    .sort((left, right) => left.start - right.start || left.sourceIndex - right.sourceIndex);
}

function markersForSong(song, rawMarkers) {
  const contained = normalizeMarkers(rawMarkers)
    .filter((marker) =>
      marker.position > song.start + 0.0005 &&
      marker.position < song.end - 0.0005);
  return [
    {
      id: `region-${song.id}`,
      number: 1,
      name: song.name,
      // Um MTC continuo identifica a musica pela posicao do projeto. Reiniciar
      // todas as regioes em zero faria todos os shows do Slot 2 dispararem.
      position: song.start,
      color: '',
      regionStart: true
    },
    ...contained
  ].map((marker, index) => ({ ...marker, cue: index + 1 }));
}

function parseOffset(value, fps = 30) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, value);
  }
  const text = String(value || '').trim();
  if (!text) return 0;
  if (/^\d+(?:\.\d+)?$/.test(text)) return Math.max(0, Number(text));
  const parts = text.split(':').map((part) => Number(part));
  if (parts.some((part) => !Number.isFinite(part) || part < 0)) return 0;
  const [hours = 0, minutes = 0, seconds = 0, frames = 0] =
    parts.length >= 4 ? parts.slice(-4) : [0, ...parts].slice(-4);
  return Math.max(0,
    hours * 3600 + minutes * 60 + seconds + frames / Math.max(1, fps));
}

function secondsToTimecode(seconds, fps = 30) {
  const rate = Math.max(1, Math.round(finiteNumber(fps, 30)));
  let totalFrames = Math.max(0, Math.round(finiteNumber(seconds, 0) * rate));
  const frames = totalFrames % rate;
  totalFrames = Math.floor(totalFrames / rate);
  const secs = totalFrames % 60;
  totalFrames = Math.floor(totalFrames / 60);
  const minutes = totalFrames % 60;
  const hours = Math.floor(totalFrames / 60);
  return [hours, minutes, secs, frames]
    .map((part) => String(part).padStart(2, '0'))
    .join(':');
}

function secondsToGrandMa2TriggerTime(seconds) {
  let totalCentiseconds = Math.max(0,
    Math.round(finiteNumber(seconds, 0) * 100));
  const centiseconds = totalCentiseconds % 100;
  totalCentiseconds = Math.floor(totalCentiseconds / 100);
  const secs = totalCentiseconds % 60;
  totalCentiseconds = Math.floor(totalCentiseconds / 60);
  const minutes = totalCentiseconds % 60;
  const hours = Math.floor(totalCentiseconds / 60);
  return `${hours}H${minutes}M${secs}.${String(centiseconds).padStart(2, '0')}S`;
}

function normalizeSettings(settings = {}) {
  return {
    fps: 30,
    offset: String(settings.offset || '00:00:00:00'),
    sequence: positiveInteger(settings.sequence, 1, 9999),
    executorPage: positiveInteger(settings.executorPage, 1, 9999),
    executor: positiveInteger(settings.executor, 1, 9999),
    timecodePool: positiveInteger(settings.timecodePool, 1, 9999),
    timecodeSlot: positiveInteger(settings.timecodeSlot, 2, 8),
    resolumeHost: String(settings.resolumeHost || '127.0.0.1').trim() || '127.0.0.1',
    resolumePort: positiveInteger(settings.resolumePort, 7000, 65535),
    resolumeFirstColumn: positiveInteger(settings.resolumeFirstColumn, 1, 99999)
  };
}

function grandMa2Header(projectName, styleName) {
  const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, '');
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    `<?xml-stylesheet type="text/xsl" href="styles/${styleName}@sheet.xsl"?>`,
    '<MA xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://schemas.malighting.de/grandma2/xml/MA" xsi:schemaLocation="http://schemas.malighting.de/grandma2/xml/MA http://schemas.malighting.de/grandma2/xml/3.9.61/MA.xsd" major_vers="3" minor_vers="9" stream_vers="61">',
    `  <Info datetime="${xmlEscape(timestamp)}" showfile="${xmlEscape(projectName)}" />`
  ];
}

function generateGrandMa2Timecode(project = {}, inputSettings = {}) {
  const settings = normalizeSettings(inputSettings);
  const markers = normalizeMarkers(project.markers);
  const projectName = cleanLabel(project.projectName, 'Projeto VS Hook');
  const offsetSeconds = parseOffset(settings.offset, settings.fps);
  const switchOffFrames = Array.isArray(project.switchOffAt)
    ? project.switchOffAt.map((position) => Math.max(0,
      Math.round((finiteNumber(position, 0) + offsetSeconds) * settings.fps)))
    : [];
  const events = [
    ...markers.map((marker) => ({
      frame: Math.max(0,
        Math.round((marker.position + offsetSeconds) * settings.fps)),
      command: 'Goto',
      marker
    })),
    ...switchOffFrames.map((frame) => ({ frame, command: 'Off' }))
  ].sort((left, right) => {
    const frameDifference = left.frame - right.frame;
    if (frameDifference !== 0) return frameDifference;
    if (left.command === right.command) return 0;
    return left.command === 'Off' ? -1 : 1;
  });
  const timelineEndFrame = Math.max(0, Math.ceil(
    (finiteNumber(project.end, 0) + offsetSeconds) * settings.fps));
  const lastEventFrame = events.length
    ? events[events.length - 1].frame
    : 0;
  const showLength = Math.max(
    timelineEndFrame,
    lastEventFrame + settings.fps);
  const lines = grandMa2Header(projectName, 'timecode');
  lines.push(`  <Timecode index="${settings.timecodePool - 1}" name="${xmlEscape(projectName)}" slot="TC Slot ${settings.timecodeSlot}" frame_format="${settings.fps} FPS" lenght="${showLength}" offset="0">`);
  lines.push('    <Track index="0" active="true" expanded="true">');
  lines.push(`      <Object name="Executor ${settings.executorPage}.${settings.executor}">`);
  lines.push('        <No>30</No>');
  lines.push('        <No>1</No>');
  lines.push(`        <No>${settings.executorPage}</No>`);
  lines.push(`        <No>${settings.executor}</No>`);
  lines.push('      </Object>');
  lines.push('      <SubTrack index="0">');
  events.forEach((event, index) => {
    if (event.command === 'Off') {
      lines.push(`        <Event index="${index}" time="${event.frame}" command="Off" pressed="true" />`);
      return;
    }
    const marker = event.marker;
    lines.push(`        <Event index="${index}" time="${event.frame}" command="Goto" pressed="true" step="${marker.cue}">`);
    lines.push(`          <Cue name="${xmlEscape(marker.name)}">`);
    lines.push(`            <No>${settings.executorPage}</No>`);
    lines.push(`            <No>${settings.executor}</No>`);
    lines.push(`            <No>${marker.cue}</No>`);
    lines.push('          </Cue>');
    lines.push('        </Event>');
  });
  lines.push('      </SubTrack>');
  lines.push('      <SubTrack index="1" fader_command="Master">');
  lines.push('        <Event index="0" fader_level="1" />');
  lines.push('      </SubTrack>');
  lines.push('    </Track>');
  lines.push('  </Timecode>');
  lines.push('</MA>');
  return `${lines.join('\r\n')}\r\n`;
}

function generateGrandMa2Macro(project = {}, inputSettings = {}) {
  const settings = normalizeSettings(inputSettings);
  const markers = normalizeMarkers(project.markers);
  const projectName = cleanLabel(project.projectName, 'Projeto VS Hook');
  const fileStem = safeFileStem(project.fileStem || projectName);
  const offsetSeconds = parseOffset(settings.offset, settings.fps);
  const commands = [
    'SelectDrive 1',
    'ClearAll',
    ...markers.flatMap((marker) => {
      const frame = Math.max(0,
        Math.round((marker.position + offsetSeconds) * settings.fps));
      const triggerTime = secondsToGrandMa2TriggerTime(frame / settings.fps);
      return [
        `Store Sequence ${settings.sequence} Cue ${marker.cue} /nc`,
        `Label Sequence ${settings.sequence} Cue ${marker.cue} \"${marker.name}\"`,
        `Assign Sequence ${settings.sequence} Cue ${marker.cue} /Trig=Timecode /TrigTime=${triggerTime}`
      ];
    }),
    `Label Sequence ${settings.sequence} \"${projectName}\"`,
    `Assign Sequence ${settings.sequence} At Executor ${settings.executorPage}.${settings.executor} /o`,
    `Import \"${fileStem}-timecode\" At Timecode ${settings.timecodePool}`,
    `Assign Timecode ${settings.timecodePool} /Slot=${settings.timecodeSlot}`,
    // AutoStart recoloca o show em Play sempre que o MTC externo reaparece.
    // StatusCall recompõe imediatamente a última cue anterior quando o MTC
    // salta para outro ponto, em vez de esperar o próximo evento da timeline.
    `Assign Timecode ${settings.timecodePool} /AutoStart=On`,
    `Assign Timecode ${settings.timecodePool} /StatusCall=On`,
    `Assign Timecode ${settings.timecodePool} /SwitchOff=\"Keep Playbacks\"`,
    `Label Timecode ${settings.timecodePool} \"${projectName}\"`,
    // Um show ligado a fonte externa precisa ficar em Play, aguardando MTC.
    `Go Timecode ${settings.timecodePool}`
  ];
  const lines = grandMa2Header(projectName, 'macro');
  lines.push(`  <Macro index="0" name="${xmlEscape(projectName)}">`);
  commands.forEach((command, index) => {
    lines.push(`    <Macroline index="${index}">`);
    lines.push(`      <text>${xmlEscape(command)}</text>`);
    lines.push('    </Macroline>');
  });
  lines.push('  </Macro>');
  lines.push('</MA>');
  return `${lines.join('\r\n')}\r\n`;
}

function buildGrandMa2SongExports(project = {}, inputSettings = {}) {
  const baseSettings = normalizeSettings(inputSettings);
  const songs = normalizeSongs(project.songs || project.regions);
  const lastSongOffset = Math.max(0, songs.length - 1);
  if (baseSettings.sequence + lastSongOffset > 9999 ||
      baseSettings.executor + lastSongOffset > 9999 ||
      baseSettings.timecodePool + lastSongOffset > 9999) {
    throw new Error('A numeração inicial não tem espaço suficiente para todas as músicas. Reduza Sequence, Executor ou Timecode inicial.');
  }
  const usedStems = new Map();
  const timelineEnd = Math.max(
    finiteNumber(project.end, 0),
    ...songs.map((song) => song.end));
  return songs.map((song, index) => {
    const baseStem = safeFileStem(song.name);
    const occurrence = (usedStems.get(baseStem.toLocaleLowerCase()) || 0) + 1;
    usedStems.set(baseStem.toLocaleLowerCase(), occurrence);
    const stem = occurrence === 1 ? baseStem : `${baseStem}-${occurrence}`;
    const settings = normalizeSettings({
      ...baseSettings,
      sequence: baseSettings.sequence + index,
      executor: baseSettings.executor + index,
      timecodePool: baseSettings.timecodePool + index
    });
    const songProject = {
      projectName: song.name,
      fileStem: stem,
      // Todos os shows cobrem a timeline inteira. O executor desta musica
      // permanece ativo ao parar e depois do fim da regiao; ele recebe Off
      // somente quando outra musica comeca. Assim o StatusCall recompõe um
      // seek deixando ativo apenas o executor da cue-alvo.
      end: timelineEnd,
      switchOffAt: songs
        .filter((otherSong) => otherSong.id !== song.id)
        .map((otherSong) => otherSong.start),
      markers: markersForSong(song, project.markers)
    };
    return {
      song,
      stem,
      settings,
      markerCount: songProject.markers.length,
      macroFileName: `${stem}-macro.xml`,
      timecodeFileName: `${stem}-timecode.xml`,
      macroXml: generateGrandMa2Macro(songProject, settings),
      timecodeXml: generateGrandMa2Timecode(songProject, settings)
    };
  });
}

function buildResolumeMap(project = {}, inputSettings = {}) {
  const settings = normalizeSettings(inputSettings);
  const markers = normalizeMarkers(project.markers);
  const songs = normalizeSongs(project.songs || project.regions);
  const projectName = cleanLabel(project.projectName, 'Projeto VS Hook');
  const offsetSeconds = parseOffset(settings.offset, settings.fps);
  const regionStarts = songs.map((song) => ({
    id: `region-${song.id}`,
    number: 0,
    name: song.name,
    position: song.start,
    color: '',
    regionStart: true,
    songId: song.id
  }));
  // Um marcador exatamente no inicio da regiao nao pode disparar duas colunas
  // no mesmo frame. Nesse caso o inicio da regiao e a cue autoritativa.
  const markersOutsideRegionStarts = markers.filter((marker) =>
    !regionStarts.some((regionStart) =>
      Math.abs(regionStart.position - marker.position) <= 0.0005));
  const timelineCues = [...regionStarts, ...markersOutsideRegionStarts]
    .sort((left, right) => {
      const positionDelta = left.position - right.position;
      if (positionDelta !== 0) return positionDelta;
      if (left.regionStart !== right.regionStart) {
        return left.regionStart === true ? -1 : 1;
      }
      return left.number - right.number;
    });
  return {
    format: 'vshook-resolume-cues',
    version: 1,
    generatedAt: new Date().toISOString(),
    projectName,
    fps: settings.fps,
    offset: settings.offset,
    destination: {
      protocol: 'OSC/UDP',
      host: settings.resolumeHost,
      port: settings.resolumePort,
      mapping: 'columns'
    },
    cues: timelineCues.map((marker, index) => {
      const position = marker.position + offsetSeconds;
      const column = settings.resolumeFirstColumn + index;
      const song = marker.regionStart === true
        ? songs.find((item) => item.id === marker.songId)
        : songs.find((item) =>
          marker.position > item.start + 0.0005 &&
          marker.position < item.end - 0.0005);
      return {
        cue: index + 1,
        sourceType: marker.regionStart === true ? 'region_start' : 'marker',
        regionStart: marker.regionStart === true,
        songId: song?.id || marker.songId || null,
        songStartSeconds: song
          ? Number((song.start + offsetSeconds).toFixed(6)) : null,
        songEndSeconds: song
          ? Number((song.end + offsetSeconds).toFixed(6)) : null,
        markerNumber: marker.regionStart === true ? null : marker.number,
        markerName: marker.name,
        markerColor: marker.color || null,
        positionSeconds: Number(position.toFixed(6)),
        timecode: secondsToTimecode(position, settings.fps),
        column,
        oscAddress: `/composition/columns/${column}/connect`,
        oscValue: 1
      };
    })
  };
}

function findResolumeCueAtPosition(rawCues, rawPosition) {
  const cues = Array.isArray(rawCues) ? rawCues : [];
  const position = Math.max(0, finiteNumber(rawPosition, 0));
  let current = null;
  for (const cue of cues) {
    const cuePosition = finiteNumber(cue?.positionSeconds, -1);
    if (cuePosition < 0 || cuePosition > position + 0.045) continue;
    const songStart = finiteNumber(cue?.songStartSeconds, NaN);
    const songEnd = finiteNumber(cue?.songEndSeconds, NaN);
    const belongsToSong = !!cue?.songId &&
      Number.isFinite(songStart) && Number.isFinite(songEnd);
    if (belongsToSong &&
        (position < songStart - 0.0005 || position >= songEnd - 0.0005)) {
      continue;
    }
    if (!current || cuePosition >= finiteNumber(current.positionSeconds, -1)) {
      current = cue;
    }
  }
  return current;
}

function oscString(value) {
  const source = Buffer.from(`${String(value)}\0`, 'utf8');
  const paddedLength = Math.ceil(source.length / 4) * 4;
  return paddedLength === source.length
    ? source
    : Buffer.concat([source, Buffer.alloc(paddedLength - source.length)]);
}

function encodeOscInt(address, value) {
  const integer = Buffer.alloc(4);
  integer.writeInt32BE(Math.trunc(finiteNumber(value, 0)), 0);
  return Buffer.concat([oscString(address), oscString(',i'), integer]);
}

function encodeOscAbsoluteFloat(address, value) {
  const number = Buffer.alloc(4);
  number.writeFloatBE(finiteNumber(value, 0), 0);
  return Buffer.concat([
    oscString(address),
    oscString(',sf'),
    oscString('a'),
    number
  ]);
}

function sendUdpPacket(socket, packet, port, host) {
  return new Promise((resolve, reject) => {
    socket.send(packet, port, host, (error) => error ? reject(error) : resolve());
  });
}

async function testResolumeColumn(inputSettings = {}, columnOverride = null) {
  const settings = normalizeSettings(inputSettings);
  const column = positiveInteger(columnOverride, settings.resolumeFirstColumn, 99999);
  const address = `/composition/columns/${column}/connect`;
  const socket = dgram.createSocket('udp4');
  try {
    await sendUdpPacket(socket, encodeOscInt(address, 1),
      settings.resolumePort, settings.resolumeHost);
    await new Promise((resolve) => setTimeout(resolve, 45));
    await sendUdpPacket(socket, encodeOscInt(address, 0),
      settings.resolumePort, settings.resolumeHost);
  } finally {
    socket.close();
  }
  return { ok: true, address, column, host: settings.resolumeHost, port: settings.resolumePort };
}

async function selectResolumeColumn(inputSettings = {}, columnOverride = null) {
  const settings = normalizeSettings(inputSettings);
  const column = positiveInteger(
    columnOverride, settings.resolumeFirstColumn, 99999);
  const address = `/composition/columns/${column}/selected`;
  const socket = dgram.createSocket('udp4');
  try {
    await sendUdpPacket(socket, encodeOscInt(address, 1),
      settings.resolumePort, settings.resolumeHost);
  } finally {
    socket.close();
  }
  return { ok: true, address, column, host: settings.resolumeHost, port: settings.resolumePort };
}

async function setResolumeCompositionSpeed(inputSettings = {}, speed = 1) {
  const settings = normalizeSettings(inputSettings);
  const address = '/composition/speed';
  const socket = dgram.createSocket('udp4');
  try {
    await sendUdpPacket(socket,
      encodeOscAbsoluteFloat(address, speed),
      settings.resolumePort,
      settings.resolumeHost);
  } finally {
    socket.close();
  }
  return { ok: true, address, speed, host: settings.resolumeHost, port: settings.resolumePort };
}

module.exports = {
  buildGrandMa2SongExports,
  buildResolumeMap,
  encodeOscAbsoluteFloat,
  encodeOscInt,
  findResolumeCueAtPosition,
  generateGrandMa2Macro,
  generateGrandMa2Timecode,
  normalizeMarkers,
  normalizeSongs,
  normalizeSettings,
  parseOffset,
  safeFileStem,
  secondsToTimecode,
  secondsToGrandMa2TriggerTime,
  selectResolumeColumn,
  setResolumeCompositionSpeed,
  testResolumeColumn
};
