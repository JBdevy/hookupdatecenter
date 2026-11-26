import test from 'node:test';
import assert from 'node:assert/strict';
import {sliderGain,gainSlider,decibels,fadeCurve,fadeGain,playlistRows,regionLanes,itemLanes,layoutTracks,zoomAt} from '../ui/app-model.js';

test('fader preserves actual dB over the full production travel',()=>{
  assert.equal(sliderGain(0),0);assert.equal(gainSlider(0),0);
  for(const db of [-59,-48,-24,-12,-3,0,6,12]){
    const gain=Math.pow(10,db/20);
    assert.ok(Math.abs(sliderGain(gainSlider(gain))-gain)<1e-10);
    assert.ok(Math.abs(decibels(sliderGain((db+60)/72))-db)<1e-10);
  }
});
test('fades preserve Mac smoothstep and independent S/curvature shape',()=>{
  assert.equal(fadeCurve(0),0);assert.equal(fadeCurve(1),1);assert.equal(fadeCurve(.5),.5);
  assert.equal(fadeCurve(.25,0,0),.25);assert.equal(fadeCurve(.25,0,1),.15625);
  assert.ok(fadeCurve(.5,1)<.5);assert.ok(fadeCurve(.5,-1)>.5);
  const clip={startTime:10,duration:20,fadeIn:2,fadeOut:4};
  assert.equal(fadeGain(clip,10),0);assert.equal(fadeGain(clip,11),.5);
  assert.equal(fadeGain(clip,20),1);assert.equal(fadeGain(clip,28),.5);assert.equal(fadeGain(clip,30),0);
});
test('playlist duplicates reference the same region without cloning grid items',()=>{
  const song={id:'song',parts:[{id:'a'},{id:'b'},{id:'child',parentRegionID:'a'}]};
  const project={regionSetlist:{selectedId:'p',playlists:[{id:'p',songId:'song',name:'Show',regionIds:['a','b','duplicate'],duplicates:[{id:'duplicate',regionId:'a'}]}]}};
  const rows=playlistRows(project,song).rows;
  assert.deepEqual(rows.map(r=>r.entryID),['a','b','duplicate']);assert.equal(rows[0].part,rows[2].part);
  project.regionSetlist.selectedId='';assert.deepEqual(playlistRows(project,song).rows.map(r=>r.part.id),['a','b']);
});
test('nested tracks retain order and exact height; cyclic parents stay bounded',()=>{
  const tracks=[{id:'a'},{id:'b',parentTrackID:'a',heightScale:2},{id:'c',parentTrackID:'b'},{id:'d',parentTrackID:'d'}];
  const rows=layoutTracks(tracks,new Map([['c',24]]));
  assert.deepEqual(rows.map(r=>r.track.id),['a','b','c','d']);
  assert.deepEqual(rows.map(r=>r.y),[0,72,216,240]);assert.equal(rows[2].indent,24);
  assert.equal(rows[3].indent,0);
});
test('item overlap groups use local lanes while isolated and touching clips occupy the whole track',()=>{
  const clip=(id,startTime,duration)=>({id,startTime,duration});
  const clips=[clip('isolated',0,2),clip('adjacent',2,2),clip('pair-a',6,4),clip('pair-b',7,4),
    clip('triple-a',12,4),clip('triple-b',13,4),clip('triple-c',14,4)];
  const lanes=itemLanes(clips);
  assert.equal(lanes.count,3);
  assert.deepEqual([...lanes.entries],[['isolated',{localLane:0,localCount:1}],['adjacent',{localLane:0,localCount:1}],
    ['pair-a',{localLane:0,localCount:2}],['pair-b',{localLane:1,localCount:2}],
    ['triple-a',{localLane:0,localCount:3}],['triple-b',{localLane:1,localCount:3}],['triple-c',{localLane:2,localCount:3}]]);
  assert.deepEqual(itemLanes([...clips].reverse()),lanes,'Persisted insertion order must not change geometry');
  const rows=layoutTracks([{id:'a',clips},{id:'b',clips:[]}]);
  assert.equal(rows[0].audioHeight,150); assert.equal(rows[1].y,150);
  assert.equal(rows[0].audioHeight/lanes.entries.get('isolated').localCount,150);
  assert.equal(rows[0].audioHeight/lanes.entries.get('pair-a').localCount,75);
  assert.equal(rows[0].audioHeight/lanes.entries.get('triple-a').localCount,50);
  const resized=layoutTracks([{id:'a',clips}],new Map([['a',240]]))[0];
  assert.equal(resized.audioHeight,240); assert.equal(resized.itemLanes.entries.get('isolated').localCount,1);
});
test('connected overlap chains share their peak lane count with nanosecond adjacency tolerance',()=>{
  const clip=(id,startTime,duration)=>({id,startTime,duration});
  const lanes=itemLanes([clip('a',0,3),clip('b',2,3),clip('c',4,3),clip('touch',7-5e-10,2),clip('tail',12,2)]);
  for(const id of ['a','b','c'])assert.equal(lanes.entries.get(id).localCount,2);
  assert.equal(lanes.entries.get('c').localLane,0,'A released lane is reused within its overlap component');
  for(const id of ['touch','tail'])assert.deepEqual(lanes.entries.get(id),{localLane:0,localCount:1});
  assert.equal(itemLanes([clip('a',0,2),clip('b',2-2e-9,1)]).count,2,'A real overlap beyond tolerance needs a second lane');
});
test('persisted recording takes keep their stacking order without affecting a separate item',()=>{
  const lanes=itemLanes([{id:'take2',startTime:1,duration:4,recordingLane:2},{id:'base',startTime:0,duration:4},
    {id:'take1',startTime:1,duration:4,recordingLane:1},{id:'alone',startTime:9,duration:2}]);
  assert.deepEqual(lanes.entries.get('base'),{localLane:0,localCount:3});
  assert.deepEqual(lanes.entries.get('take1'),{localLane:1,localCount:3});
  assert.deepEqual(lanes.entries.get('take2'),{localLane:2,localCount:3});
  assert.deepEqual(lanes.entries.get('alone'),{localLane:0,localCount:1});
});
test('unified region children use a separate real lane and adjacent regions reuse lanes',()=>{
  const layout=regionLanes([{id:'root',startTime:0,endTime:20},{id:'child',parentRegionID:'root',startTime:0,endTime:10},{id:'next',startTime:20,endTime:30}]);
  assert.equal(layout.count,2);assert.equal(layout.rows.get('child'),1);assert.equal(layout.rows.get('next'),0);
});
test('zoom retains the time under the pointer and bounds the visible document',()=>{
  const prior={scale:20,offset:40,x:300,delta:-100,width:800,duration:200};const next=zoomAt(prior);
  assert.ok(Math.abs(prior.offset+prior.x/prior.scale-next.offset-prior.x/next.scale)<1e-10);
  assert.ok(zoomAt({...prior,offset:0,x:0}).offset>=0);
});
