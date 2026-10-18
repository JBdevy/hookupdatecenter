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
const parityCases = [];
function migrate(source, name, success = true) {
  const caseRoot=path.join(root,'parity',name);fs.mkdirSync(caseRoot,{recursive:true});
  const copy=path.join(caseRoot,path.basename(source));fs.cpSync(source,copy,{recursive:true});
  const parity={name,source:path.relative(root,copy).split(path.sep).join('/'),success};parityCases.push(parity);
  const target = path.join(root, name + '.jl');
  const result = spawnSync(exe, ['--migrate-project', source, target], { timeout: 30000, windowsHide: true });
  assert(!result.error, String(result.error));
  const reportFile = path.join(root, name + '.migration.json');
  const report = fs.existsSync(reportFile) ? fs.readFileSync(reportFile, 'utf8') : 'No import report';
  assert.equal(result.status === 0, success, report);
  if (!success) return;
  const metadata = JSON.parse(report), project = document(metadata.document);
  parity.project=project;
  return { project, file: metadata.document, warnings: metadata.warnings };
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
// A Mac RPP often spells accents as combining characters while copied files
// on Windows use composed names. Check both directions, including folders.
for (const [diskForm, projectForm] of [['NFC','NFD'], ['NFD','NFC']]) {
  const folder = `Mídia-${diskForm}`, name = 'Canção.wav';
  const diskFolder = path.join(root, folder.normalize(diskForm));
  fs.mkdirSync(diskFolder); fs.writeFileSync(path.join(diskFolder, name.normalize(diskForm)), audio);
  const input = path.join(root, `Unicode-${diskForm}.rpp`);
  fs.writeFileSync(input, fs.readFileSync(reaper,'utf8').replace('FILE "Guitar.wav"',
    `FILE "${folder.normalize(projectForm)}/${name.normalize(projectForm)}"`));
  const imported = migrate(input, `Unicode-${diskForm}`);
  assert(!imported.warnings.some(w => w.includes('Missing media')), imported.warnings.join('\n'));
  const clip = imported.project.songs[0].tracks[1].clips[0];
  assert.deepEqual(fs.readFileSync(path.join(path.dirname(imported.file), clip.audioFile.path)), audio);
}
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
// VS Hook project ExtState: same migration contract as the current Mac importer.
const rgn=(id,a,b,name)=>`MARKER ${id} ${a} "${name}" 1\nMARKER ${id} ${b} "" 1`;
const mark=(id,at,name)=>`MARKER ${id} ${at} "${name}" 0`;
const bin=(key,value)=>`<BIN ${key}\n${Buffer.from(value+'\0').toString('base64')}\n>`;
const ext=(playlist='',loops='')=>`<EXTSTATE\n<CHATGPT_REGION_PLAYLIST\n${playlist}\n>\n<VS_HOOK_MULTILOOPS\n${loops}\n>\n>`;
const escapeHook=s=>s.replaceAll('\\','\\\\').replaceAll('|','\\p').replaceAll('\t','\\t').replaceAll('\n','\\n');
const entry=(id,a,b,title,kind='region',options={})=>['ITEM',kind,id,a,b,escapeHook(title),options.color||'',options.source||'', '',options.child?'1':'0',options.marker||'', '', '',options.center?'1':'0'].join('\t');
function hookCase(name,content,success=true){const source=path.join(root,name+'.rpp');fs.writeFileSync(source,`<REAPER_PROJECT 0.1 7.0 1\nTEMPO 120 4 4\n${content}\n>\n`);return migrate(source,name,success);}
const listName='Domingo | Noite\tFinal\nBis\\Ao vivo';
const playlistText=['PLAYLIST\tAbertura',entry('-1',0,0,'Introdução | banda','block',{color:'green'}),entry('7',20,30,'Segundo'),entry('-2',0,0,'Louvor','block',{color:'purple',center:true}),entry('0',0,10,'Primeiro'),entry('-3',0,0,'Fim','block',{color:'orange'}),'END','PLAYLIST\t'+escapeHook(listName),entry('0',0,10,'Primeiro'),entry('7',20,30,'Segundo'),'END'].join('\n');
const playlists=hookCase('HookPlaylists',[rgn(0,0,10,'Primeiro'),rgn(7,20,30,'Segundo'),ext(bin('PLAYLISTS_DB_V3',playlistText)+'\n'+bin('LAST_PLAYLIST_NAME_V1',listName))].join('\n')).project;
const lists=playlists.regionSetlist, partsByName=Object.fromEntries(playlists.songs[0].parts.map(p=>[p.name,p.id]));
assert.deepEqual(lists.playlists.map(p=>p.name),['Abertura',listName]);assert.equal(lists.selectedId,lists.playlists[1].id);
assert.deepEqual(lists.playlists[0].regionIds,[partsByName.Segundo,partsByName.Primeiro]);assert.deepEqual(lists.blocks.map(b=>b.beforeRegionId??null),[partsByName.Segundo,partsByName.Primeiro,null]);
assert.deepEqual(lists.blocks.map(b=>b.color),[0x2ebd5c,0x8f57f0,0xf58f29]);assert.deepEqual(lists.blocks.map(b=>b.symbol),[true,false,true]);
const four=hookCase('HookFourSlots',[rgn(10,0,100,'Canção'),...[1,2,3,4].flatMap(slot=>[mark(100+slot*2,slot*20-15,`*${slot} entrada`),mark(101+slot*2,slot*20-10,`*${slot} saída`)]),mark(199,90,'*Ponte'),'<TRACK {KEYS}\nNAME " # Keys"\n>',ext('TUNER_OFFSETS_V1 "10=-12"','STATE_V2 "E\t10\t1\t0\t0\t1\t1\t0\t1\t0"')].join('\n')).project.songs[0];
assert.equal(four.parts.length,1);assert.equal(four.parts[0].pitchSemitones,-12);assert.deepEqual(four.parts[0].pitchTrackIDs,[four.tracks[0].id]);
assert.deepEqual(four.parts[0].multiLoops.map(l=>l.name),['*1','*2','*3','*4']);assert.deepEqual(four.parts[0].multiLoops.map(l=>l.enabled),[true,false,true,false]);assert.deepEqual(four.parts[0].multiLoops.map(l=>l.mixerEnabled),[false,true,true,false]);
assert.equal(four.markers.filter(m=>!m.tempoBPM).length,9);assert(four.markers.filter(m=>!m.tempoBPM).every(m=>m.section&&!m.name.startsWith('*')&&!m.sourceRegionID));
const guitar='{AAAAAAAA-1111-1111-1111-111111111111}', keys='{BBBBBBBB-2222-2222-2222-222222222222}';
const loopMix=[['T','5','1','2','0','0'],['P','5','1',guitar.toLowerCase(),'1','0'],['F','5','1',keys,'1','1'],['L','5','1',keys,'-9','0']].map(r=>r.join('\t')).join('\n');
const mix=hookCase('HookLoopMixer',[rgn(5,0,20,'Canção'),mark(20,3,'*1'),mark(21,10,'*1'),`<TRACK ${guitar}\nNAME "Guitar"\n>`,`<TRACK ${keys}\nNAME "Keys"\n>`,ext('',bin('STATE_V2','E\t5\t1\t0\t1\t0\t0\t0\t0\t0')+'\n'+bin('MS_STATE_V1',loopMix))].join('\n')).project.songs[0];
const ml=mix.parts[0].multiLoops[0];assert.equal(ml.fadeSeconds,2);assert.deepEqual(ml.tracks.map(t=>t.id),mix.tracks.map(t=>t.id));assert(ml.tracks[0].mute&&!ml.tracks[0].solo);assert(ml.tracks[1].autoFader);assert(Math.abs(ml.tracks[1].gain-Math.pow(10,-9/20))<1e-7);
const familyList=['PLAYLIST\tShow',entry('100',0,20,'Filha A','region',{source:'marker',child:true,marker:'7'}),entry('7',50,70,'Solta'),entry('100',0,40,'Família'),entry('999',50,70,'Removida'),'END'].join('\n');
const family=hookCase('HookFamily',[rgn(100,0,40,'-- Família'),rgn(7,50,70,'Solta'),mark(7,0,'Filha A'),mark(8,20,'Filha B'),mark(30,22,'*2'),mark(31,27,'*2'),ext(bin('PLAYLISTS_DB_V3',familyList)+'\nTUNER_OFFSETS_V1 "7=3|8=-7|100=12"','STATE_V2 "E\t8\t0\t1\t0\t0\t0\t0\t0\t0"')].join('\n'));
const familySong=family.project.songs[0],parent=familySong.parts.find(p=>p.name==='Família'),solo=familySong.parts.find(p=>p.name==='Solta'),children=familySong.parts.filter(p=>p.parentRegionID===parent.id);
assert.deepEqual(children.map(p=>p.name),['Filha A','Filha B']);assert.deepEqual(children.map(p=>p.pitchSemitones),[3,-7]);assert.equal(parent.pitchSemitones??0,0);assert.equal(solo.pitchSemitones,3);assert.deepEqual(family.project.regionSetlist.playlists[0].regionIds,[parent.id,solo.id]);assert.equal(children[1].multiLoops[0].enabled,true);assert(family.warnings.some(w=>w.includes('removidas')));
const noState=hookCase('HookLoopNoState',[rgn(1,0,20,'Canção'),mark(4,2,'*1'),mark(5,20.0004,'*1')].join('\n')).project.songs[0];
assert.equal(noState.parts[0].multiLoops[0].enabled,false);assert.equal(noState.markers.find(m=>m.id===noState.parts[0].multiLoops[0].marker2).position,20);
const cues=hookCase('HookOrdinaryCue',[rgn(1,0,20,'Canção'),mark(2,7,'Refrão'),ext('TUNER_OFFSETS_V1 "1=9|2=-7"')].join('\n')).project.songs[0];assert.equal(cues.parts.length,1);assert.equal(cues.parts[0].pitchSemitones,9);assert.deepEqual(cues.parts[0].pitchTrackIDs,[]);assert.equal(cues.markers.find(m=>m.name==='Refrão').sourceRegionID,undefined);
const split=hookCase('ReaperNestedSplit',[rgn(100,0,40,'Family'),rgn(10,0,20,'First'),mark(10,0,'Duplicate'),mark(11,10,'Second')].join('\n')).project.songs[0];assert.deepEqual(split.parts.filter(p=>p.parentRegionID).map(p=>[p.name,p.startTime,p.endTime]),[['First',0,10],['Second',10,20]]);assert.equal(split.markers.filter(m=>!m.tempoBPM&&m.position===0).length,1);
hookCase('HookMalformed',rgn(1,0,20,'Song')+'\n'+ext('<BIN PLAYLISTS_DB_V3\nnot-base64!!\n>'),false);
assert(imported.project.songs[0].tracks.every(t=>t.color===0x828282));
// Build Logic MUSICAS MIDI-region metadata, including a standalone song and
// duplicate ordinary flags at child starts. Match Mac's linked-flag priority.
function logicContainer(records){const b=Buffer.concat(records),h=Buffer.alloc(24);put(h,0,0xabc04723);put(h,16,b.length);return Buffer.concat([h,b]);}
const musicRecords=[];let musicRoot=Buffer.alloc(100);text(musicRoot,16,'Show');musicRecords.push(record('qeSM',musicRoot,0x40000));
let musicEnv=Buffer.alloc(200);text(musicEnv,158,'MUSICAS');musicRecords.push(record('ivnE',musicEnv,0x40000,0,20));let musicTrack=Buffer.alloc(58);musicTrack[0]=1;put(musicTrack,6,0x40000);musicRecords.push(record('karT',musicTrack,0x40000,0));
for(const [index,[name,start,length]] of [['First',0,4],['Second',4,4],['Outside',12,4]].entries()){
 const owner=(10+index)<<16,seq=Buffer.alloc(160),padded=(name.length+1)&~1;text(seq,16,name);put(seq,16+62+padded,length*960);musicRecords.push(record('qeSM',seq,owner));
 const e=Buffer.alloc(80);e[0]=0x20;put(e,4,34560+start*960);put(e,20,1);put(e,32,10+index);for(const o of [23,39,55,71])e[o]=0x88;musicRecords.push(record('qSvE',e,0x40000));
}
const musicMarker=Buffer.alloc(48);musicMarker[0]=0x12;musicMarker[23]=0x88;musicMarker[39]=0x88;put(musicMarker,4,38400);put(musicMarker,16,4);put(musicMarker,28,8*960);musicRecords.push(record('qSvE',musicMarker,0,0,22));musicRecords.push(record('qSxT',Buffer.from('{\\rtf1\\ansi Family}'),4<<16,0,32));
fs.writeFileSync(path.join(logic,'Resources/ProjectInformation.plist'),plist({ActiveVariant:2}));fs.writeFileSync(path.join(alternative,'MetaData.plist'),plist({SampleRate:48000,BeatsPerMinute:60,SongSignatureNumerator:4,SongSignatureDenominator:4}));fs.writeFileSync(path.join(alternative,'ProjectData'),logicContainer(musicRecords));
const logicMusic=migrate(logic,'LogicMusic').project.songs[0];assert.deepEqual(logicMusic.parts.map(p=>p.name),['Family','First','Second','Outside']);
const normalFlags=logicMusic.markers.filter(m=>!m.tempoBPM);assert.deepEqual(normalFlags.map(m=>m.name),['First','Second','Outside']);assert(normalFlags[0].sourceRegionID&&normalFlags[1].sourceRegionID);assert(!normalFlags[2].sourceRegionID);
const duplicateMixer=Buffer.alloc(180);duplicateMixer[89]=64;put(duplicateMixer,116,90*16777216);Buffer.alloc(16,7).copy(duplicateMixer,153);
fs.writeFileSync(path.join(alternative,'ProjectData'),logicContainer([...musicRecords,record('OCuA',duplicateMixer,0,0,0,7),record('OCuA',duplicateMixer,0,0,0,7)]));migrate(logic,'LogicDuplicateMixer',false);
console.log('VS Hook playlists/blocks/tuner/four loops/linked songs and Logic MUSICAS/standalone/duplicate-mixer parity passed.');

console.log('DAW imports passed: independent REAPER and binary Logic fixtures, audio copy, MIDI, tempo, regions, folder routing and malformed inputs.');
fs.writeFileSync(path.join(root,'parity-cases.json'),JSON.stringify(parityCases,null,2));
const exchange=path.join(output,'parity-fixtures');fs.mkdirSync(exchange,{recursive:true});
fs.cpSync(path.join(root,'parity'),path.join(exchange,'parity'),{recursive:true});
fs.copyFileSync(path.join(root,'parity-cases.json'),path.join(exchange,'parity-cases.json'));
console.log(root);
