const assert = require('assert');
const {
  buildGrandMa2SongExports,
  buildResolumeMap,
  encodeOscAbsoluteFloat,
  findResolumeCueAtPosition,
  generateGrandMa2InstallerMacro
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
  timecodeSlot: 2
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
assert(songExport.macroXml.includes(
  'Assign Sequence 4 Cue 1 /Trig=Timecode /TrigTime=0H0M10.00S'));
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
assert(installerMacro.includes('<Macro index="0" name="VS Hook - Instalar Tudo">'));
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

const resolumeMap = buildResolumeMap({
  projectName: 'Teste Resolume',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 12 }]
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
  resolumeMap.cues, 35)?.column, 3);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 9.999), null,
  'A coluna nao pode disparar antes de o transporte cruzar o marcador.');

const movedResolumeMap = buildResolumeMap({
  projectName: 'Teste Resolume',
  regions: [
    { id: 'song-2', name: 'Outra Musica', start: 5, end: 9 },
    { id: 'song-1', name: 'Musica Teste', start: 20, end: 30 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 22 }]
}, { resolumeFirstColumn: 4 }, resolumeMap.assignments);
const columnsBySource = Object.fromEntries(
  movedResolumeMap.cues.map((cue) => [cue.sourceKey, cue.column]));
assert.strictEqual(columnsBySource['region:song-1'], 1);
assert.strictEqual(columnsBySource['marker:marker-1'], 2);
assert.strictEqual(columnsBySource['region:song-2'], 3);

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
