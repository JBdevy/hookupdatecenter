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

function cleanGrandMa2Name(value, fallback = 'Marcador') {
  const sanitize = (input) => cleanLabel(input, '')
    // O grandMA2 rejeita nomes com caracteres fora do conjunto ingles. Isso
    // inclui acentos, virgulas, aspas tipograficas e travessoes copiados de
    // títulos, mesmo quando o texto esta entre aspas no comando Label.
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[\u2010-\u2015\u2212]/g, '-')
    .replace(/[^A-Za-z0-9 _-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return (sanitize(value) || sanitize(fallback) || 'Marcador').slice(0, 96);
}

function safeFileStem(value) {
  const normalized = cleanGrandMa2Name(value, 'Projeto VS Hook')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[<>:"/\\|?*]+/g, '-')
    .replace(/[. ]+$/g, '')
    .trim();
  const stem = (normalized || 'Projeto VS Hook').slice(0, 96).replace(/[. ]+$/g, '');
  return /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(stem)
    ? `_${stem}`.slice(0, 96) : stem;
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
      const rawName = String(
        marker?.name ?? marker?.label ?? '').trim();
      return {
        id: String(marker?.id || `m${markerNumber}`),
        number: markerNumber,
        name: cleanLabel(rawName, `Marcador ${markerNumber}`),
        hasCustomName: rawName.length > 0,
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
        // Preserva inclusive o ID numerico 0 entregue pelo REAPER. Usar `||`
        // aqui faria a regiao 0 receber outra identidade e perder a coluna.
        id: String(region.id ?? region.uid ?? `song-${sourceIndex + 1}`),
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
      name: 'Inicio',
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
  const rawResolumeIncludeMarkers = settings.resolumeIncludeMarkers;
  return {
    fps: 30,
    // O VS Hook trabalha diretamente na timeline do REAPER. Valores antigos
    // salvos são ignorados para não deslocar cues ou colunas sem o usuário ver.
    offset: '00:00:00:00',
    sequence: positiveInteger(settings.sequence, 1, 9999),
    executorPage: positiveInteger(settings.executorPage, 1, 9999),
    executor: positiveInteger(settings.executor, 1, 9999),
    timecodePool: positiveInteger(settings.timecodePool, 1, 9999),
    timecodeSlot: positiveInteger(settings.timecodeSlot, 2, 8),
    resolumeHost: String(settings.resolumeHost || '127.0.0.1').trim() || '127.0.0.1',
    resolumePort: positiveInteger(settings.resolumePort, 7000, 65535),
    resolumeWebPort: positiveInteger(settings.resolumeWebPort, 8080, 65535),
    // Ausente significa ligado para preservar o comportamento das versões
    // anteriores. Somente um false explícito desativa os marcadores.
    resolumeIncludeMarkers: rawResolumeIncludeMarkers === undefined ||
      rawResolumeIncludeMarkers === null
      ? true
      : rawResolumeIncludeMarkers !== false &&
        String(rawResolumeIncludeMarkers).trim().toLowerCase() !== 'false' &&
        String(rawResolumeIncludeMarkers).trim() !== '0',
    // O mapa da Hook Center e o mapa nativo da extensão usam a mesma base.
    // Valores antigos salvos são deliberadamente migrados para a coluna 1.
    resolumeFirstColumn: 1
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
  const markers = normalizeMarkers(project.markers).map((marker) => ({
    ...marker,
    name: cleanGrandMa2Name(marker.name, `Marcador ${marker.cue}`)
  }));
  const projectName = cleanGrandMa2Name(project.projectName, 'Projeto VS Hook');
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

function buildGrandMa2MacroCommands(project = {}, inputSettings = {}) {
  const settings = normalizeSettings(inputSettings);
  const markers = normalizeMarkers(project.markers).map((marker) => ({
    ...marker,
    name: cleanGrandMa2Name(marker.name, `Marcador ${marker.cue}`)
  }));
  const projectName = cleanGrandMa2Name(project.projectName, 'Projeto VS Hook');
  const fileStem = safeFileStem(project.fileStem || projectName);
  const offsetSeconds = parseOffset(settings.offset, settings.fps);
  return [
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
    // O grandMA2 usa 0,5 s de Pre Roll por padrao. Como o MTC ja chega
    // posicionado e preparado pelo VS Hook, esse atraso so posterga a cue.
    `Assign TimecodeSlot ${settings.timecodeSlot} /PreRoll=0`,
    // Zera tambem a cauda do Slot ao pausar/parar. Keep Playbacks abaixo
    // conserva a ultima iluminacao, portanto isso nao escurece o palco.
    `Assign TimecodeSlot ${settings.timecodeSlot} /AfterRoll=0`,
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
}

function renderGrandMa2MacroXml(showName, macroName, commands) {
  const cleanShowName = cleanGrandMa2Name(showName, 'Projeto VS Hook');
  const cleanMacroName = cleanGrandMa2Name(macroName, `Importar tudo - ${cleanShowName}`);
  const lines = grandMa2Header(cleanShowName, 'macro');
  lines.push(`  <Macro index="0" name="${xmlEscape(cleanMacroName)}">`);
  commands.forEach((command, index) => {
    lines.push(`    <Macroline index="${index}">`);
    lines.push(`      <text>${xmlEscape(command)}</text>`);
    lines.push('    </Macroline>');
  });
  lines.push('  </Macro>');
  lines.push('</MA>');
  return `${lines.join('\r\n')}\r\n`;
}

function generateGrandMa2Macro(project = {}, inputSettings = {}) {
  const projectName = cleanGrandMa2Name(project.projectName, 'Projeto VS Hook');
  return renderGrandMa2MacroXml(
    projectName,
    projectName,
    buildGrandMa2MacroCommands(project, inputSettings));
}

function generateGrandMa2InstallerMacro(project = {}, songExports = []) {
  const projectName = cleanGrandMa2Name(project.projectName, 'Projeto VS Hook');
  const commands = ['SelectDrive 1'];
  for (const songExport of songExports) {
    const songCommands = Array.isArray(songExport?.macroCommands)
      ? songExport.macroCommands : [];
    commands.push(...songCommands.filter((command) =>
      String(command || '').trim().toLowerCase() !== 'selectdrive 1'));
  }
  return renderGrandMa2MacroXml(
    projectName,
    `Importar tudo - ${projectName}`,
    commands);
}

function buildGrandMa2Assignments(
  project = {}, savedAssignments = {}, options = {}) {
  const songs = normalizeSongs(project.songs || project.regions);
  const assignments = Object.create(null);
  const occupiedOffsets = new Set();
  const validOffset = (value) => {
    const text = String(value ?? '').trim();
    if (!/^\d+$/.test(text)) return null;
    const offset = Number(text);
    return Number.isSafeInteger(offset) && offset >= 0 && offset < 9999
      ? offset : null;
  };

  // Mantém inclusive as músicas que saíram do projeto. O grandMA2 não pode
  // ser consultado durante a exportação, portanto reutilizar automaticamente
  // um destino antigo poderia sobrescrever um executor que ainda existe no
  // show. Músicas novas sempre entram depois do maior destino já reservado.
  for (const [key, rawOffset] of Object.entries(savedAssignments || {})) {
    if (!String(key).startsWith('region:')) continue;
    const offset = validOffset(rawOffset);
    if (offset === null || occupiedOffsets.has(offset)) continue;
    assignments[key] = offset;
    occupiedOffsets.add(offset);
  }

  if (options.includeUnassigned !== false) {
    let nextOffset = occupiedOffsets.size
      ? Math.max(...occupiedOffsets) + 1 : 0;
    for (const song of songs) {
      const key = `region:${song.id}`;
      if (Object.hasOwn(assignments, key)) continue;
      while (occupiedOffsets.has(nextOffset)) nextOffset += 1;
      if (nextOffset >= 9999) {
        throw new Error('O mapa grandMA2 atingiu o limite de 9.999 músicas.');
      }
      assignments[key] = nextOffset;
      occupiedOffsets.add(nextOffset);
      nextOffset += 1;
    }
  }
  return assignments;
}

function buildGrandMa2SongExports(project = {}, inputSettings = {}, options = {}) {
  const baseSettings = normalizeSettings(inputSettings);
  const allSongs = normalizeSongs(project.songs || project.regions);
  const selectedSongIds = Array.isArray(options.selectedSongIds)
    ? new Set(options.selectedSongIds.map((id) => String(id)))
    : null;
  const selectedSongs = allSongs
    .map((song, projectIndex) => ({ song, projectIndex }))
    .filter(({ song }) => !selectedSongIds || selectedSongIds.has(song.id));
  const assignmentFor = ({ song, projectIndex }) => {
    const rawOffset = options.assignments?.[`region:${song.id}`];
    const text = String(rawOffset ?? '').trim();
    return /^\d+$/.test(text) ? Number(text) : projectIndex;
  };
  const lastSelectedOffset = selectedSongs.reduce(
    (highest, entry) => Math.max(highest, assignmentFor(entry)), -1);
  if (lastSelectedOffset >= 0 &&
      (baseSettings.sequence + lastSelectedOffset > 9999 ||
       baseSettings.executor + lastSelectedOffset > 9999 ||
       baseSettings.timecodePool + lastSelectedOffset > 9999)) {
    throw new Error('A numeração inicial não tem espaço suficiente para todas as músicas. Reduza Sequence, Executor ou Timecode inicial.');
  }
  // Calcula os nomes usando o projeto inteiro. Assim uma exportação parcial
  // mantém o mesmo arquivo e os mesmos destinos da exportação completa.
  const baseStems = allSongs.map((song) => safeFileStem(song.name));
  const reservedStems = new Set(baseStems.map((stem) => stem.toLowerCase()));
  // Mantem a reserva legada para nao mudar nomes de musicas ja exportadas.
  // O macro geral atual resolve colisoes com estes arquivos na exportacao.
  const usedStems = new Set(['00-vs-hook-instalar-tudo']);
  const stems = baseStems.map((baseStem) => {
    let stem = baseStem;
    let occurrence = 2;
    while (usedStems.has(stem.toLowerCase()) ||
        (stem !== baseStem && reservedStems.has(stem.toLowerCase()))) {
      const suffix = `-${occurrence++}`;
      stem = `${baseStem.slice(0, 96 - suffix.length).replace(/[. ]+$/g, '')}${suffix}`;
    }
    usedStems.add(stem.toLowerCase());
    return stem;
  });
  const timelineEnd = Math.max(
    finiteNumber(project.end, 0),
    ...allSongs.map((song) => song.end));
  return selectedSongs.map(({ song, projectIndex }) => {
    const stem = stems[projectIndex];
    const assignedOffset = assignmentFor({ song, projectIndex });
    const settings = normalizeSettings({
      ...baseSettings,
      sequence: baseSettings.sequence + assignedOffset,
      executor: baseSettings.executor + assignedOffset,
      timecodePool: baseSettings.timecodePool + assignedOffset
    });
    const songProject = {
      projectName: song.name,
      fileStem: stem,
      // Todos os shows cobrem a timeline inteira. O executor desta musica
      // permanece ativo ao parar e depois do fim da regiao; ele recebe Off
      // somente quando outra musica comeca. Assim o StatusCall recompõe um
      // seek deixando ativo apenas o executor da cue-alvo.
      end: timelineEnd,
      switchOffAt: allSongs
        .filter((otherSong) => otherSong.id !== song.id)
        .map((otherSong) => otherSong.start),
      markers: markersForSong(song, project.markers)
    };
    const macroCommands = buildGrandMa2MacroCommands(songProject, settings);
    return {
      song,
      stem,
      settings,
      markerCount: songProject.markers.length,
      macroFileName: `${stem}-macro.xml`,
      timecodeFileName: `${stem}-timecode.xml`,
      macroCommands,
      macroXml: renderGrandMa2MacroXml(song.name, song.name, macroCommands),
      timecodeXml: generateGrandMa2Timecode(songProject, settings)
    };
  });
}

function buildResolumeMap(
  project = {}, inputSettings = {}, savedAssignments = {}, options = {}) {
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
    songId: song.id,
    song
  }));
  // Marcadores soltos nao pertencem ao mapa. Em regioes sobrepostas, o
  // marcador pertence a menor regiao reproduzivel que o contem.
  const markersInsideSongs = settings.resolumeIncludeMarkers
    ? markers.map((marker) => {
      const song = songs
        .filter((candidate) =>
          marker.position > candidate.start + 0.0005 &&
          marker.position < candidate.end - 0.0005)
        .sort((left, right) =>
          (left.end - left.start) - (right.end - right.start))[0];
      return song ? { ...marker, songId: song.id, song } : null;
    }).filter(Boolean)
    : [];
  const timelineCues = [...regionStarts, ...markersInsideSongs]
    .sort((left, right) => {
      const positionDelta = left.position - right.position;
      if (positionDelta !== 0) return positionDelta;
      if (left.regionStart !== right.regionStart) {
        return left.regionStart === true ? -1 : 1;
      }
      return left.number - right.number;
    });
  // Cada regiao recebe um deck estavel e sempre comeca na coluna 1. Marcadores
  // recebem colunas locais a partir da 2 dentro do deck da propria musica.
  // Mover uma regiao no grid nao altera seu deck; fontes novas sao anexadas.
  const assignments = Object.create(null);
  const occupiedDecks = new Set();
  const sourceKeyFor = (marker) => marker.regionStart
    ? `region:${marker.songId}` : `marker:${marker.id}`;
  const validSourceKeys = new Set(timelineCues.map(sourceKeyFor));
  const parseAssignment = (value) => {
    const match = String(value ?? '').match(/^(\d+):(\d+)$/);
    if (!match) return null;
    const deckOffset = Number(match[1]);
    const columnOffset = Number(match[2]);
    return Number.isInteger(deckOffset) && deckOffset >= 0 &&
      deckOffset < 99999 && Number.isInteger(columnOffset) &&
      columnOffset >= 0 && columnOffset < 99999
      ? { deckOffset, columnOffset } : null;
  };
  const saved = Object.entries(savedAssignments || {})
    .filter(([key]) => validSourceKeys.has(key))
    .map(([key, value]) => ({ key, assignment: parseAssignment(value) }))
    .filter((entry) => entry.assignment);

  for (const entry of saved
    .filter(({ key, assignment }) =>
      key.startsWith('region:') && assignment.columnOffset === 0)
    .sort((left, right) =>
      left.assignment.deckOffset - right.assignment.deckOffset)) {
    if (occupiedDecks.has(entry.assignment.deckOffset)) continue;
    assignments[entry.key] = `${entry.assignment.deckOffset}:0`;
    occupiedDecks.add(entry.assignment.deckOffset);
  }

  if (options.includeUnassigned !== false) {
    let nextDeckOffset = occupiedDecks.size
      ? Math.max(...occupiedDecks) + 1 : 0;
    for (const regionStart of regionStarts) {
      const key = sourceKeyFor(regionStart);
      if (Object.hasOwn(assignments, key)) continue;
      while (occupiedDecks.has(nextDeckOffset)) nextDeckOffset += 1;
      assignments[key] = `${nextDeckOffset}:0`;
      occupiedDecks.add(nextDeckOffset);
      nextDeckOffset += 1;
    }
  }

  for (const song of songs) {
    const regionKey = `region:${song.id}`;
    const regionAssignment = parseAssignment(assignments[regionKey]);
    if (!regionAssignment) continue;
    const occupiedColumns = new Set([0]);
    const songMarkers = markersInsideSongs
      .filter((marker) => marker.songId === song.id)
      .sort((left, right) =>
        left.position - right.position || left.number - right.number);
    const savedMarkers = saved
      .filter(({ key, assignment }) =>
        key.startsWith('marker:') &&
        assignment.deckOffset === regionAssignment.deckOffset &&
        assignment.columnOffset >= 1 &&
        songMarkers.some((marker) => sourceKeyFor(marker) === key))
      .sort((left, right) =>
        left.assignment.columnOffset - right.assignment.columnOffset);
    for (const entry of savedMarkers) {
      if (occupiedColumns.has(entry.assignment.columnOffset)) continue;
      assignments[entry.key] =
        `${entry.assignment.deckOffset}:${entry.assignment.columnOffset}`;
      occupiedColumns.add(entry.assignment.columnOffset);
    }
    if (options.includeUnassigned !== false) {
      let nextColumnOffset = Math.max(...occupiedColumns) + 1;
      for (const marker of songMarkers) {
        const key = sourceKeyFor(marker);
        if (Object.hasOwn(assignments, key)) continue;
        while (occupiedColumns.has(nextColumnOffset)) nextColumnOffset += 1;
        assignments[key] = `${regionAssignment.deckOffset}:${nextColumnOffset}`;
        occupiedColumns.add(nextColumnOffset);
        nextColumnOffset += 1;
      }
    }
  }
  const mappedTimelineCues = timelineCues.filter((marker) =>
    Object.hasOwn(assignments, sourceKeyFor(marker)));
  return {
    format: 'vshook-resolume-cues',
    version: 2,
    generatedAt: new Date().toISOString(),
    projectName,
    fps: settings.fps,
    offset: settings.offset,
    assignments,
    destination: {
      protocol: 'OSC/UDP',
      host: settings.resolumeHost,
      port: settings.resolumePort,
      firstDeck: 1,
      firstColumn: 1,
      mapping: 'decks-and-columns'
    },
    cues: mappedTimelineCues.map((marker, index) => {
      const position = marker.position + offsetSeconds;
      const sourceKey = sourceKeyFor(marker);
      const assignment = parseAssignment(assignments[sourceKey]);
      const deck = assignment.deckOffset + 1;
      const column = assignment.columnOffset + 1;
      const song = marker.song || songs.find((item) =>
        item.id === marker.songId);
      return {
        cue: index + 1,
        sourceKey,
        sourceType: marker.regionStart === true ? 'region_start' : 'marker',
        regionStart: marker.regionStart === true,
        songId: song?.id || marker.songId || null,
        songStartSeconds: song
          ? Number((song.start + offsetSeconds).toFixed(6)) : null,
        songEndSeconds: song
          ? Number((song.end + offsetSeconds).toFixed(6)) : null,
        markerNumber: marker.regionStart === true ? null : marker.number,
        markerName: marker.name,
        deckName: song?.name || `Música ${deck}`,
        // Marcador sem nome conserva o nome automático do próprio Resolume.
        columnName: marker.regionStart === true
          ? 'Início'
          : (marker.hasCustomName === true ? marker.name : ''),
        markerColor: marker.color || null,
        positionSeconds: Number(position.toFixed(6)),
        timecode: secondsToTimecode(position, settings.fps),
        deck,
        column,
        oscDeckAddress: `/composition/decks/${deck}/select`,
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
    if (cuePosition < 0 || cuePosition > position + 0.000001) continue;
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

async function selectResolumeDeck(
  inputSettings = {}, deckOverride = null, settleMilliseconds = 70) {
  const settings = normalizeSettings(inputSettings);
  const deck = positiveInteger(deckOverride, 1, 99999);
  const address = `/composition/decks/${deck}/select`;
  const socket = dgram.createSocket('udp4');
  try {
    await sendUdpPacket(socket, encodeOscInt(address, 1),
      settings.resolumePort, settings.resolumeHost);
  } finally {
    socket.close();
  }
  const delay = Math.max(0, Math.min(500,
    Math.round(finiteNumber(settleMilliseconds, 70))));
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  return {
    ok: true,
    address,
    deck,
    host: settings.resolumeHost,
    port: settings.resolumePort
  };
}

async function setResolumeColumnPlayhead(
  inputSettings = {}, columnOverride = null, positionSeconds = 0) {
  const settings = normalizeSettings(inputSettings);
  const column = positiveInteger(
    columnOverride, settings.resolumeFirstColumn, 99999);
  const position = Math.max(0, finiteNumber(positionSeconds, 0));
  // O Resolume nao possui um playhead por coluna. Cada clip da coluna tem seu
  // proprio endereco, entao preparamos a mesma posicao nas camadas possiveis.
  // Enderecos de camadas inexistentes sao simplesmente ignorados pelo Resolume.
  const layerLimit = 64;
  const socket = dgram.createSocket('udp4');
  try {
    const sends = [];
    for (let layer = 1; layer <= layerLimit; layer += 1) {
      const address =
        `/composition/layers/${layer}/clips/${column}/transport/position`;
      sends.push(sendUdpPacket(socket,
        encodeOscAbsoluteFloat(address, position),
        settings.resolumePort,
        settings.resolumeHost));
    }
    await Promise.all(sends);
  } finally {
    socket.close();
  }
  return {
    ok: true,
    column,
    position,
    layers: layerLimit,
    host: settings.resolumeHost,
    port: settings.resolumePort
  };
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
  buildGrandMa2Assignments,
  buildGrandMa2SongExports,
  buildResolumeMap,
  encodeOscAbsoluteFloat,
  encodeOscInt,
  findResolumeCueAtPosition,
  generateGrandMa2Macro,
  generateGrandMa2InstallerMacro,
  generateGrandMa2Timecode,
  normalizeMarkers,
  normalizeSongs,
  normalizeSettings,
  parseOffset,
  safeFileStem,
  secondsToTimecode,
  secondsToGrandMa2TriggerTime,
  selectResolumeDeck,
  setResolumeColumnPlayhead,
  setResolumeCompositionSpeed,
  testResolumeColumn
};
