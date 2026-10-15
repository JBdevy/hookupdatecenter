const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const [exe, output] = process.argv.slice(2);
fs.mkdirSync(output, { recursive: true });
const root = fs.mkdtempSync(path.join(output, 'run-'));
const swift = fs.readFileSync(path.resolve(__dirname, '../../Application/Project/ProjectDocumentCodec.swift'), 'utf8');
const decodeBytes = text => Buffer.from(text.split(',').map(s => parseInt(s.trim(), 16)));
const header = decodeBytes(swift.match(/header = Data\(\[([^\]]+)\]/)[1]);
const key = decodeBytes(swift.match(/key = SymmetricKey\(data: Data\(\[([^\]]+)\]/)[1]);
function document(file) {
  const bytes = fs.readFileSync(file);
  assert.deepEqual(bytes.subarray(0, header.length), header);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, bytes.subarray(header.length, header.length + 12));
  decipher.setAAD(header); decipher.setAuthTag(bytes.subarray(-16));
  return JSON.parse(Buffer.concat([decipher.update(bytes.subarray(header.length + 12, -16)), decipher.final()]).toString());
}
function migrate(source, name, success = true) {
  const target = path.join(root, name + '.jl');
  const result = spawnSync(exe, ['--migrate-project', source, target], { timeout: 30000, windowsHide: true });
  assert(!result.error, String(result.error));
  const reportFile = path.join(root, name + '.migration.json');
  const report = fs.existsSync(reportFile) ? fs.readFileSync(reportFile, 'utf8') : 'No import report';
  assert.equal(result.status === 0, success, report);
  if (!success) return;
  const metadata = JSON.parse(report);
  return { project: document(metadata.document), file: metadata.document, warnings: metadata.warnings };
}
// Independent binary-plist writer: exercise the same Apple metadata format as the Swift fixtures.
function plist(dictionary) {
  const entries = Object.entries(dictionary), objects = [null];
  const keys = entries.map(([key]) => { objects.push(key); return objects.length - 1; });
  const values = entries.map(([,value]) => { objects.push(value); return objects.length - 1; });
  const ref = value => { const b=Buffer.alloc(2); b.writeUInt16BE(value); return b; };
  const length = (kind, count) => count < 15 ? Buffer.from([kind | count]) : Buffer.from([kind | 15, 0x10, count]);
  const chunks = objects.map((value,i) => {
    if (i===0) return Buffer.concat([length(0xd0, entries.length), ...keys.map(ref), ...values.map(ref)]);
    if (typeof value === 'string') return Buffer.concat([length(0x50, Buffer.byteLength(value)), Buffer.from(value)]);
    if (typeof value === 'boolean') return Buffer.from([value ? 9 : 8]);
    const b=Buffer.alloc(9); b[0]=0x13; b.writeBigInt64BE(BigInt(value),1); return b;
  });
  let offset=8; const offsets=chunks.map(chunk => { const value=offset; offset+=chunk.length; const b=Buffer.alloc(4); b.writeUInt32BE(value); return b; });
  const trailer=Buffer.alloc(32); trailer[6]=4; trailer[7]=2;
  trailer.writeBigUInt64BE(BigInt(objects.length),8); trailer.writeBigUInt64BE(0n,16); trailer.writeBigUInt64BE(BigInt(offset),24);
  return Buffer.concat([Buffer.from('bplist00'),...chunks,...offsets,trailer]);
}
const put=(buffer,offset,value,width=4) => { if(width===8)buffer.writeBigUInt64LE(BigInt(value),offset);else buffer.writeUIntLE(value,offset,width); };
function record(tag,body,owner=0,index=0,kind=23,version=5) {
  const h=Buffer.alloc(36); h.write(tag); put(h,4,version,2); put(h,6,kind,2); put(h,8,owner); put(h,tag==='karT'?18:14,index); put(h,28,body.length); return Buffer.concat([h,body]);
}
function text(buffer,offset,value,utf16=false) { const bytes=Buffer.from(value,utf16?'utf16le':'utf8');put(buffer,offset,utf16?bytes.length/2:bytes.length,2);bytes.copy(buffer,offset+2); }
function wave() {
  const pcm=Buffer.alloc(48000*12*2), h=Buffer.alloc(44);
  h.write('RIFF');h.writeUInt32LE(pcm.length+36,4);h.write('WAVEfmt ',8);h.writeUInt32LE(16,16);h.writeUInt16LE(1,20);h.writeUInt16LE(1,22);h.writeUInt32LE(48000,24);h.writeUInt32LE(96000,28);h.writeUInt16LE(2,32);h.writeUInt16LE(16,34);h.write('data',36);h.writeUInt32LE(pcm.length,40);
  for(let n=0;n<48000*12;n++)pcm.writeInt16LE(Math.round(Math.sin(n*2*Math.PI*440/48000)*12000),n*2);
  return Buffer.concat([h,pcm]);
}
const audio=wave(); fs.writeFileSync(path.join(root,'Guitar.wav'),audio);
const reaper=path.join(root,'Imported.rpp');
fs.writeFileSync(reaper, `<REAPER_PROJECT 0.1 7.0 1
 TEMPO 60 4 4
 <TEMPOENVEX
  PT 0 60 1
  PT 4 120 1
 >
 MARKER 1 0 "Introduction" 1
 MARKER 1 6 "" 1
 <TRACK {GROUP}
  NAME "Group"
  ISBUS 1 1
 >
 <TRACK {GUITAR}
  NAME "Guitar"
  ISBUS 2 -1
  VOLPAN 0.5 -0.25
  <ITEM
   POSITION 6
   LENGTH 10
   NAME "Trimmed guitar"
   SOFFS 1
   PLAYRATE 1 1 -4.75
   MUTE 1
   <SOURCE WAVE
    FILE "Guitar.wav"
   >
  >
  <ITEM
   POSITION 16
   LENGTH 2
   NAME "MIDI"
   <SOURCE MIDI
    HASDATA 1 960 QN
    E 0 90 3c 64
    E 960 80 3c 00
   >
  >
 >
>
`);
const rpp=migrate(reaper,'Reaper');
assert.equal(rpp.project.songs[0].tracks.length,2);
const rTrack=rpp.project.songs[0].tracks[1], rClip=rTrack.clips[0];
assert.equal(rTrack.parentTrackID,rpp.project.songs[0].tracks[0].id);
assert.equal(rClip.startTime,6);assert.equal(rClip.duration,10);assert.equal(rClip.sourceOffset,1);assert.equal(rClip.pitchSemitones,-4.75);assert.equal(rClip.muted,true);
assert.equal(rTrack.clips[1].midi.notes.length,1);assert.equal(rTrack.clips[1].midi.notes[0].length,1);
assert.deepEqual(fs.readFileSync(path.join(path.dirname(rpp.file),rClip.audioFile.path)),audio);
const logic=path.join(root,'Migration.logicx'), alternative=path.join(logic,'Alternatives/002');
fs.mkdirSync(alternative,{recursive:true});fs.mkdirSync(path.join(logic,'Resources'),{recursive:true});fs.mkdirSync(path.join(logic,'Media/Audio Files'),{recursive:true});
fs.writeFileSync(path.join(logic,'Media/Audio Files/Guitar.wav'),audio);
fs.writeFileSync(path.join(logic,'Resources/ProjectInformation.plist'),plist({ActiveVariant:2}));
fs.writeFileSync(path.join(alternative,'MetaData.plist'),plist({SampleRate:48000,BeatsPerMinute:60,SongSignatureNumerator:4,SongSignatureDenominator:4}));
const records=[];let sequence=Buffer.alloc(80);text(sequence,16,'Migration');records.push(record('qeSM',sequence,0x40000));
for(const [index,title] of ['Group','Guitar'].entries()) {
  const env=Buffer.alloc(200);text(env,158,title);records.push(record('ivnE',env,(index+1)<<18,0,20));
  const row=Buffer.alloc(58);row[0]=1;put(row,6,(index+1)<<18);put(row,14,index,2);records.push(record('karT',row,0x40000,index));
}
const file=Buffer.alloc(100);text(file,8,'Guitar.wav',true);records.push(record('lFuA',file,0,0,11));
const region=Buffer.alloc(160);put(region,6,48000,8);put(region,22,480000,8);text(region,74,'Trimmed guitar');records.push(record('gRuA',region,0,0,11));
const event=Buffer.alloc(80);event[0]=0x24;event.writeInt8(-5,53);event[50]=25;put(event,4,34560+8*960);put(event,12,0x100);put(event,20,2);for(const offset of [23,39,55,71])event[offset]=0x88;records.push(record('qSvE',event,0x40000));
const tempos=[];for(const [tick,bpm] of [[0,60],[3840,120]]){const t=Buffer.alloc(32);t[0]=0x60;t[23]=0x88;put(t,4,tick+38400);put(t,16,bpm*10000);tempos.push(t);}records.push(record('qSvE',Buffer.concat(tempos),0,0,3));
const marker=Buffer.alloc(48);marker[0]=0x12;marker[23]=0x88;marker[39]=0x88;put(marker,4,38400);put(marker,16,4);put(marker,28,8*960);records.push(record('qSvE',marker,0,0,22));records.push(record('qSxT',Buffer.from('{\\rtf1\\ansi Introduction}'),4<<16,0,32));
const body=Buffer.concat(records),container=Buffer.alloc(24);put(container,0,0xabc04723);put(container,16,body.length);fs.writeFileSync(path.join(alternative,'ProjectData'),Buffer.concat([container,body]));
const imported=migrate(logic,'Logic'), song=imported.project.songs[0], clip=song.tracks[1].clips[0];
assert.equal(song.tracks[1].parentTrackID,song.tracks[0].id);
assert.equal(clip.startTime,6);assert.equal(clip.duration,10);assert.equal(clip.sourceOffset,1);assert.equal(clip.pitchSemitones,-4.75);assert.equal(clip.muted,true);
assert.equal(song.parts[0].name,'Introduction');assert.equal(song.parts[0].endTime,6);
assert.deepEqual(fs.readFileSync(path.join(path.dirname(imported.file),clip.audioFile.path)),audio);
assert.deepEqual(fs.readFileSync(path.join(logic,'Media/Audio Files/Guitar.wav')),audio);
fs.writeFileSync(path.join(logic,'Resources/ProjectInformation.plist'),plist({ActiveVariant:7}));migrate(logic,'BadAlternative',false);
fs.writeFileSync(path.join(logic,'Resources/ProjectInformation.plist'),plist({ActiveVariant:true}));migrate(logic,'BooleanAlternative',false);
fs.writeFileSync(path.join(logic,'Resources/ProjectInformation.plist'),plist({ActiveVariant:2}));fs.writeFileSync(path.join(alternative,'ProjectData'),Buffer.from([0x23,0x47]));migrate(logic,'TruncatedLogic',false);
fs.writeFileSync(path.join(root,'Broken.rpp'),'<REAPER_PROJECT\n<TRACK\n');migrate(path.join(root,'Broken.rpp'),'TruncatedReaper',false);
console.log('DAW imports passed: independent REAPER and binary Logic fixtures, audio copy, MIDI, tempo, regions, folder routing and malformed inputs.');
console.log(root);
