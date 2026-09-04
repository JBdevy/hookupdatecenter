const assert = require('assert');
const { buildGrandMa2SongExports } = require('../src/hook-marker');

const [songExport] = buildGrandMa2SongExports({
  projectName: 'Teste MTC',
  regions: [{ id: 'song-1', name: 'Musica Teste', start: 10, end: 20 }],
  markers: [{ id: 'marker-1', number: 1, name: 'Refrao', position: 12 }]
}, {
  sequence: 4,
  executorPage: 2,
  executor: 7,
  timecodePool: 9,
  timecodeSlot: 2
});

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
assert(songExport.macroXml.includes('Assign Timecode 9 /StatusCall=Off'));
assert(songExport.macroXml.includes('Assign Timecode 9 /SwitchOff=&quot;Keep Playbacks&quot;'));
assert(songExport.macroXml.includes('Go Timecode 9'));
assert(songExport.timecodeXml.includes('lenght="600" offset="0"'));
assert(songExport.timecodeXml.includes('time="300" command="Goto"'));
assert(songExport.timecodeXml.includes('time="360" command="Goto"'));
assert(songExport.timecodeXml.includes('<SubTrack index="1" fader_command="Master">'));

console.log('HOOK_MARKER_MTC_AUTOSTART_OK');
