const assert = require('assert');
const {
  buildGrandMa2Assignments,
  buildGrandMa2SongExports,
  buildResolumeMap,
  encodeOscAbsoluteFloat,
  findResolumeCueAtPosition,
  generateGrandMa2InstallerMacro,
  normalizeSettings
} = require('../src/hook-marker');

const songExports = buildGrandMa2SongExports({
  projectName: 'Teste MTC',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 12 }]
}, {
  sequence: 4,
  executorPage: 2,
  executor: 7,
  timecodePool: 9,
  timecodeSlot: 2,
  // Configurações antigas podem continuar no armazenamento local, mas não
  // devem mais deslocar os eventos exportados.
  offset: '00:00:05:00'
});
const [songExport, secondSongExport] = songExports;
const installerMacro = generateGrandMa2InstallerMacro({
  projectName: 'Teste MTC'
}, songExports);

assert(songExport, 'A exportacao da musica deveria existir.');
assert(songExport.macroXml.includes('SelectDrive 1'));
assert(!songExport.macroXml.includes('Select Drive (1 = onPC'));
assert(songExport.macroXml.includes('ClearAll'));
assert(songExport.macroXml.includes('<Macro index="0" name="Musica Teste">'));
assert(!songExport.macroXml.includes('Hook Marker -'));
assert(songExport.macroXml.includes('Label Sequence 4 Cue 1 &quot;Inicio&quot;'));
assert(secondSongExport.macroXml.includes('Label Sequence 5 Cue 1 &quot;Inicio&quot;'));
assert(songExport.timecodeXml.includes('<Cue name="Inicio">'));
assert(secondSongExport.timecodeXml.includes('<Cue name="Inicio">'));
assert(installerMacro.includes('Label Sequence 4 Cue 1 &quot;Inicio&quot;'));
assert(installerMacro.includes('Label Sequence 5 Cue 1 &quot;Inicio&quot;'));
assert(songExport.macroXml.includes(
  'Assign Sequence 4 Cue 1 /Trig=Timecode /TrigTime=0H0M10.00S'));
assert(!songExport.macroXml.includes('/TrigTime=0H0M15.00S'));
assert(songExport.macroXml.includes(
  'Assign Sequence 4 Cue 2 /Trig=Timecode /TrigTime=0H0M12.00S'));
assert(songExport.macroXml.includes('Assign Timecode 9 /Slot=2'));
assert(songExport.macroXml.includes('Assign TimecodeSlot 2 /PreRoll=0'));
assert(songExport.macroXml.includes('Assign TimecodeSlot 2 /AfterRoll=0'));
assert(songExport.macroXml.includes('Assign Timecode 9 /AutoStart=On'));
assert(songExport.macroXml.includes('Assign Timecode 9 /StatusCall=On'));
assert(songExport.macroXml.includes('Assign Timecode 9 /SwitchOff=&quot;Keep Playbacks&quot;'));
assert(songExport.macroXml.includes('Go Timecode 9'));
assert(songExport.timecodeXml.includes('lenght="1200" offset="0"'));
assert(songExport.timecodeXml.includes('time="300" command="Goto"'));
assert(songExport.timecodeXml.includes('time="360" command="Goto"'));
assert(songExport.timecodeXml.includes(
  'time="900" command="Off" pressed="true"'));
assert(!songExport.timecodeXml.includes(
  'time="600" command="Off" pressed="true"'));
assert(songExport.timecodeXml.includes('<SubTrack index="1" fader_command="Master">'));
assert(secondSongExport.timecodeXml.includes(
  'time="300" command="Off" pressed="true"'));
assert(!secondSongExport.timecodeXml.includes(
  'time="1200" command="Off" pressed="true"'));
assert(installerMacro.includes('<Macro index="0" name="Importar tudo - Teste MTC">'));
assert(!installerMacro.includes('Instalar Tudo'));
assert(generateGrandMa2InstallerMacro({}, []).includes(
  '<Macro index="0" name="Importar tudo - Projeto VS Hook">'));
assert(generateGrandMa2InstallerMacro({ projectName: 'São João $ "Show"' }, []).includes(
  '<Macro index="0" name="Importar tudo - Sao Joao Show">'));
assert.strictEqual((installerMacro.match(/SelectDrive 1/g) || []).length, 1,
  'O macro geral deve selecionar o drive apenas uma vez.');
assert(installerMacro.includes('Import &quot;Musica Teste-timecode&quot; At Timecode 9'));
assert(installerMacro.includes('Import &quot;Outra Musica-timecode&quot; At Timecode 10'));
assert(installerMacro.includes('Store Sequence 4 Cue 1 /nc'));
assert(installerMacro.includes('Store Sequence 5 Cue 1 /nc'));
assert(installerMacro.includes('Go Timecode 9'));
assert(installerMacro.includes('Go Timecode 10'));

const partialSongExports = buildGrandMa2SongExports({
  projectName: 'Teste MTC',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 12 }]
}, {
  sequence: 4,
  executorPage: 2,
  executor: 7,
  timecodePool: 9,
  timecodeSlot: 2
}, { selectedSongIds: ['song-2'] });
assert.strictEqual(partialSongExports.length, 1);
assert.strictEqual(partialSongExports[0].settings.sequence, 5);
assert.strictEqual(partialSongExports[0].settings.executor, 8);
assert.strictEqual(partialSongExports[0].settings.timecodePool, 10);
assert(partialSongExports[0].timecodeXml.includes(
  'time="300" command="Off" pressed="true"'));
const partialInstallerMacro = generateGrandMa2InstallerMacro({
  projectName: 'Teste MTC'
}, partialSongExports);
assert(!partialInstallerMacro.includes('Musica Teste-timecode'));
assert(partialInstallerMacro.includes('Outra Musica-timecode'));
assert(!partialInstallerMacro.includes('Store Sequence 4 Cue 1 /nc'));
assert(partialInstallerMacro.includes('Store Sequence 5 Cue 1 /nc'));

const persistedGrandMa2Assignments = buildGrandMa2Assignments({
  regions: [
    { id: 'song-new-before', name: 'Nova no começo', start: 1, end: 5 },
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ]
}, {
  'region:song-1': 0,
  'region:song-2': 1
});
assert.strictEqual(persistedGrandMa2Assignments['region:song-1'], 0);
assert.strictEqual(persistedGrandMa2Assignments['region:song-2'], 1);
assert.strictEqual(persistedGrandMa2Assignments['region:song-new-before'], 2,
  'Música nova deve entrar depois dos destinos já reservados.');
const mappedPartialExport = buildGrandMa2SongExports({
  regions: [
    { id: 'song-new-before', name: 'Nova no começo', start: 1, end: 5 },
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ]
}, {
  sequence: 1,
  executor: 1,
  timecodePool: 1
}, {
  selectedSongIds: ['song-new-before'],
  assignments: persistedGrandMa2Assignments
});
assert.strictEqual(mappedPartialExport[0].settings.sequence, 3);
assert.strictEqual(mappedPartialExport[0].settings.executor, 3);
assert.strictEqual(mappedPartialExport[0].settings.timecodePool, 3);

const grandMaReservedNameExport = buildGrandMa2SongExports({
  projectName: 'Teste de nomes',
  regions: [
    { id: 'song-special', name: 'Musica $especial', start: 0, end: 20 }
  ],
  markers: [
    { id: 'marker-special', number: 1, name: '$pre refrão', position: 10 }
  ]
})[0];
assert(grandMaReservedNameExport.macroXml.includes(
  'Label Sequence 1 Cue 2 &quot;pre refrao&quot;'));
assert(!grandMaReservedNameExport.macroXml.includes('$pre refrão'));
assert(grandMaReservedNameExport.timecodeXml.includes('<Cue name="pre refrao">'));
assert.strictEqual(grandMaReservedNameExport.timecodeFileName,
  'Musica especial-timecode.xml');

const grandMaPunctuationExport = buildGrandMa2SongExports({
  projectName: 'Teste de pontuação',
  regions: [
    { id: 'song-punctuation', name: 'ISABELA – ZUFA', start: 0, end: 20 }
  ],
  markers: [
    {
      id: 'marker-punctuation',
      number: 1,
      name: 'CHOPP, ALEGRIA E DIVERSÃO',
      position: 10
    }
  ]
})[0];
assert(grandMaPunctuationExport.macroXml.includes(
  'Label Sequence 1 &quot;ISABELA - ZUFA&quot;'));
assert(grandMaPunctuationExport.macroXml.includes(
  'Label Sequence 1 Cue 2 &quot;CHOPP ALEGRIA E DIVERSAO&quot;'));
assert(!/[À-ÖØ-öø-ÿ,–]/.test(grandMaPunctuationExport.macroXml));
assert.strictEqual(grandMaPunctuationExport.timecodeFileName,
  'ISABELA - ZUFA-timecode.xml');

const resolumeMap = buildResolumeMap({
  projectName: 'Teste Resolume',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [
    { id: 'marker-1', number: 1, name: 'Refrao', position: 12 },
    { id: 'marker-outside', number: 2, name: 'Solto', position: 25 }
  ]
}, { resolumeFirstColumn: 4 });

assert.strictEqual(resolumeMap.destination.firstColumn, 1,
  'O Mapa Resolume deve sempre começar na coluna 1.');
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 10.5)?.column, 1);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 18)?.column, 2);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 25), null);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 35)?.column, 1);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 35)?.deck, 2);
assert.strictEqual(resolumeMap.cues.length, 3,
  'Marcadores fora de todas as musicas nao devem ocupar coluna.');
assert(!resolumeMap.cues.some((cue) => cue.sourceKey === 'marker:marker-outside'));
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 9.999), null,
  'A coluna nao pode disparar antes de o transporte cruzar o marcador.');

const regionsOnlyResolumeMap = buildResolumeMap({
  projectName: 'Somente regiões',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [
    { id: 'marker-1', number: 1, name: 'Refrao', position: 12 },
    { id: 'marker-2', number: 2, name: 'Solo', position: 32 }
  ]
}, { resolumeIncludeMarkers: false });
assert.deepStrictEqual(
  regionsOnlyResolumeMap.cues.map((cue) => cue.sourceKey),
  ['region:song-1', 'region:song-2'],
  'Ao desativar marcadores, somente inicios de regioes devem ocupar colunas.');
assert.deepStrictEqual(
  regionsOnlyResolumeMap.cues.map((cue) => cue.column),
  [1, 1],
  'Toda musica deve comecar na coluna 1 do proprio deck.');
assert.deepStrictEqual(
  regionsOnlyResolumeMap.cues.map((cue) => cue.deck), [1, 2]);
assert.strictEqual(normalizeSettings({}).resolumeIncludeMarkers, true,
  'Projetos antigos devem continuar considerando marcadores por padrao.');
assert.strictEqual(
  normalizeSettings({ resolumeIncludeMarkers: false }).resolumeIncludeMarkers,
  false);

const explicitMapProject = {
  projectName: 'Mapa explícito',
  regions: [
    { id: 'r1', name: 'Primeira', start: 0, end: 20 },
    { id: 'r2', name: 'Segunda', start: 30, end: 50 }
  ],
  markers: [
    { id: 'm1', number: 1, name: 'Parte 1', position: 5 },
    { id: 'm2', number: 2, name: 'Parte 2', position: 10 }
  ]
};
const explicitWithMarkers = buildResolumeMap(explicitMapProject, {
  resolumeIncludeMarkers: true
});
const explicitRegionsOnly = buildResolumeMap(explicitMapProject, {
  resolumeIncludeMarkers: false
});
assert.deepStrictEqual(
  explicitWithMarkers.cues.map((cue) => [cue.deck, cue.column]),
  [[1, 1], [1, 2], [1, 3], [2, 1]],
  'Cada musica deve usar seu proprio deck e colunas locais.');
assert.deepStrictEqual(
  explicitRegionsOnly.cues.map((cue) => [cue.deck, cue.column]),
  [[1, 1], [2, 1]],
  'Sem marcadores, cada deck deve conter somente a coluna Inicio.');

const savedExplicitAssignments = {
  'region:r1': '0:0',
  'marker:m1': '0:1'
};
const readOnlyExplicitMap = buildResolumeMap(explicitMapProject, {
  resolumeIncludeMarkers: true
}, savedExplicitAssignments, { includeUnassigned: false });
assert.deepStrictEqual(
  readOnlyExplicitMap.cues.map((cue) => cue.sourceKey),
  ['region:r1', 'marker:m1'],
  'Ler o mapa não pode atribuir colunas às fontes novas.');
const updatedExplicitMap = buildResolumeMap(explicitMapProject, {
  resolumeIncludeMarkers: true
}, savedExplicitAssignments);
assert.strictEqual(updatedExplicitMap.assignments['region:r1'], '0:0');
assert.strictEqual(updatedExplicitMap.assignments['marker:m1'], '0:1');
assert.strictEqual(updatedExplicitMap.assignments['marker:m2'], '0:2');
assert.strictEqual(updatedExplicitMap.assignments['region:r2'], '1:0',
  'Criar o mapa novamente deve manter o deck antigo e acrescentar os novos.');

const zeroRegionMap = buildResolumeMap({
  projectName: 'Regiao zero',
  regions: [{ id: 0, name: 'Primeira', start: 1, end: 5 }],
  markers: []
});
assert.strictEqual(zeroRegionMap.cues[0].sourceKey, 'region:0',
  'A regiao de ID zero deve manter identidade estavel no mapa.');

const unnamedResolumeMarkerMap = buildResolumeMap({
  projectName: 'Marcador sem nome',
  regions: [{ id: 'r1', name: 'Musica', start: 0, end: 20 }],
  markers: [{ id: 'm1', number: 1, name: '', position: 5 }]
});
assert.strictEqual(unnamedResolumeMarkerMap.cues[0].columnName, 'Início');
assert.strictEqual(unnamedResolumeMarkerMap.cues[1].columnName, '',
  'Marcador sem nome deve conservar o nome automatico da coluna do Resolume.');

const childOnlyResolumeMap = buildResolumeMap({
  projectName: 'Familia Resolume',
  regions: [
    { id: 'parent', name: 'Bloco', start: 0, end: 30, isHashParent: true },
    { id: 'child', name: 'Musica Filho', start: 10, end: 20, isHashChild: true }
  ],
  markers: [
    { id: 'parent-only', number: 1, name: 'Solto no pai', position: 5 },
    { id: 'inside-child', number: 2, name: 'Parte', position: 12 }
  ]
});
assert.deepStrictEqual(
  childOnlyResolumeMap.cues.map((cue) => cue.sourceKey),
  ['region:child', 'marker:inside-child'],
  'Regiao-pai e marcadores fora das musicas-filho nao devem ocupar colunas.');

const compactedResolumeMap = buildResolumeMap({
  projectName: 'Mapa antigo',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [
    { id: 'inside', number: 1, name: 'Parte', position: 12 },
    { id: 'outside', number: 2, name: 'Solto', position: 25 }
  ]
}, {}, {
  'region:song-1': '0:0',
  'marker:outside': '0:1',
  'marker:inside': '0:2',
  'region:song-2': '1:0'
});
assert.deepStrictEqual(
  compactedResolumeMap.cues.map((cue) => [cue.deck, cue.column]),
  [[1, 1], [1, 3], [2, 1]],
  'Remover uma fonte nao deve renumerar decks e colunas ja entregues.');
assert(!Object.hasOwn(compactedResolumeMap.assignments, 'marker:outside'));

const movedResolumeMap = buildResolumeMap({
  projectName: 'Teste Resolume',
  regions: [
    { id: 'song-2', name: 'Outra Musica', start: 5, end: 9 },
    { id: 'song-1', name: 'Musica Teste', start: 20, end: 30 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 22 }]
}, { resolumeFirstColumn: 4 }, resolumeMap.assignments);
const slotsBySource = Object.fromEntries(
  movedResolumeMap.cues.map((cue) => [
    cue.sourceKey, `${cue.deck}:${cue.column}`]));
assert.strictEqual(slotsBySource['region:song-1'], '1:1');
assert.strictEqual(slotsBySource['marker:marker-1'], '1:2');
assert.strictEqual(slotsBySource['region:song-2'], '2:1');

const collidingNames = buildGrandMa2SongExports({
  projectName: 'Nomes repetidos',
  regions: [
    { id: 'a', name: 'Musica', start: 0, end: 5 },
    { id: 'b', name: 'Musica', start: 5, end: 10 },
    { id: 'c', name: 'Musica-2', start: 10, end: 15 }
  ],
  markers: []
});
const generatedNames = collidingNames.flatMap((item) => [
  item.macroFileName.toLowerCase(), item.timecodeFileName.toLowerCase()
]);
assert.strictEqual(new Set(generatedNames).size, generatedNames.length,
  'Musicas com nomes repetidos nao podem sobrescrever XMLs umas das outras.');

const pausePacket = encodeOscAbsoluteFloat('/composition/speed', 0);
assert(pausePacket.includes(Buffer.from(',sf\0')));
assert(pausePacket.includes(Buffer.from('a\0')));
assert.strictEqual(pausePacket.readFloatBE(pausePacket.length - 4), 0);

console.log('HOOK_MARKER_MTC_AUTOSTART_OK');
