const assert = require('assert');
const {
  buildGrandMa2SongExports,
  buildResolumeMap,
  encodeOscAbsoluteFloat,
  findResolumeCueAtPosition
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

const resolumeMap = buildResolumeMap({
  projectName: 'Teste Resolume',
  regions: [
    { id: 'song-1', name: 'Musica Teste', start: 10, end: 20 },
    { id: 'song-2', name: 'Outra Musica', start: 30, end: 40 }
  ],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 12 }]
}, { resolumeFirstColumn: 4 });

assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 10.5)?.column, 4);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 18)?.column, 5);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 25), null);
assert.strictEqual(findResolumeCueAtPosition(
  resolumeMap.cues, 35)?.column, 6);

const pausePacket = encodeOscAbsoluteFloat('/composition/speed', 0);
assert(pausePacket.includes(Buffer.from(',sf\0')));
assert(pausePacket.includes(Buffer.from('a\0')));
assert.strictEqual(pausePacket.readFloatBE(pausePacket.length - 4), 0);

console.log('HOOK_MARKER_MTC_AUTOSTART_OK');
