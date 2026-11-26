// Exercises the actual product DOM/canvas with an isolated, explicit host fixture.
// Audio integration is verified separately by FrontendBridge/Windows tests.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const endpoint=process.env.CATLIVE_CDP??'http://127.0.0.1:9228';
const url=process.env.CATLIVE_UI_URL??'http://127.0.0.1:8768/app.html';
const dpr=Number(process.env.CATLIVE_DPR??1);
const pages=await(await fetch(`${endpoint}/json/list`)).json();
const page=pages.find(p=>p.type==='page');assert.ok(page);
const socket=new WebSocket(page.webSocketDebuggerUrl);await new Promise(resolve=>socket.addEventListener('open',resolve,{once:true}));
let serial=0;const pending=new Map();
socket.addEventListener('message',event=>{const response=JSON.parse(event.data),call=pending.get(response.id);if(call){pending.delete(response.id);clearTimeout(call.timer);response.error?call.reject(response.error):call.resolve(response.result);}});
function send(method,params={}){return new Promise((resolve,reject)=>{const id=++serial,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timed out'));},10000);pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));});}
async function evaluate(expression){const result=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(result.exceptionDetails)throw Error(JSON.stringify(result.exceptionDetails));return result.result.value;}
async function click(selector){const box=await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);await send('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...box});await send('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...box});}
async function key(key,code,windowsVirtualKeyCode){await send('Input.dispatchKeyEvent',{type:'keyDown',key,code,windowsVirtualKeyCode});await send('Input.dispatchKeyEvent',{type:'keyUp',key,code,windowsVirtualKeyCode});}
await send('Page.enable');await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:dpr,mobile:false});
await send('Page.addScriptToEvaluateOnNewDocument',{source:`
  const track=(id,name,color,volume=1)=>({id,name,color,volume,pan:0,mute:false,solo:false,role:'other',clips:[{id:id+'-clip',audioFile:name+'.wav',startTime:2,duration:28,sourceOffset:0,gain:1}]});
  const song={id:'song',bpm:120,duration:90,tracks:[track('drums','DRUMS',0xa59525),track('bass','BASS',0x758440,.7079458),track('guitar','GUITARRA',0x348b32),track('keys','KEYBOARDS',0x31738a),track('vox','VOZ GUIA',0x777348)],parts:[{id:'a',name:'MÚSICA A',startTime:0,endTime:30,color:0x9a87a2},{id:'b',name:'MÚSICA B',startTime:30,endTime:60,color:0x887a96}]};
  const project={id:'fixture',name:'TESTE DE INTERFACE',masterVolume:1,songs:[song],regionSetlist:{playlists:[{id:'playlist',songId:'song',name:'Playlist 1',regionIds:['a','b']}]}};
  const transport={playing:false,position:4,editPosition:4,bpm:120,beats:4,unit:4,selectedRegionID:'a'};
  window.fixture={calls:[],push:null};
  window.chrome??={};window.chrome.webview={addEventListener(_,listener){fixture.push=data=>listener({data});},postMessage(request){fixture.calls.push(request);queueMicrotask(()=>{
    let result={};
    if(request.action==='snapshot')fixture.push({type:'snapshot',revision:1,project,song,transport,document:{name:'fixture.jl'},language:'pt',canUndo:true,canRedo:false});
    if(request.action==='togglePlay'){transport.playing=!transport.playing;fixture.push({type:'telemetry',transport,meters:[{trackID:'drums',left:.5,right:.4,peak:1.1}]});}
    if(request.action==='waveform'){const p=request.payload,n=p.pixelWidth;result={start:p.start,end:p.end,pixelWidth:n,columnStart:p.start,columnDuration:(p.end-p.start)/n,channels:[{min:Array.from({length:n},(_,i)=>-.35*Math.abs(Math.sin(i*.12))),max:Array.from({length:n},(_,i)=>.45*Math.abs(Math.sin(i*.12)))}]};}
    if(request.action==='effectsGet')result={settings:fixture.fxSettings??{inserted:[]},sampleRate:48000};
    if(request.action==='effectsCommit')fixture.fxSettings=structuredClone(request.payload.settings);
    if(request.action==='effectsRTA')result={ready:false,input:[],output:[],sampleRate:48000};
    fixture.push({type:'reply',id:request.id,ok:true,result});
  });}};
`});
await send('Page.navigate',{url});
for(let i=0;i<30;i++){if(await evaluate('document.querySelectorAll(".track").length===5'))break;await new Promise(r=>setTimeout(r,100));}
assert.equal(await evaluate('document.querySelectorAll(".track").length'),5);
assert.equal(await evaluate('document.querySelector("#document-name").textContent'),'fixture.jl');
assert.ok(await evaluate('fixture.calls.some(c=>c.action==="waveform")'),'real waveform request contract is used');
await click('#playlist');assert.ok(await evaluate('Boolean(document.querySelector("[role=menu]"))'));
await click('#playlist');
assert.equal(await evaluate('Boolean(document.querySelector("[role=menu]"))'),false,'clicking the selector again closes the playlist popup');
await key(' ','Space',32);
assert.equal(await evaluate('fixture.calls.filter(c=>c.action==="togglePlay").length'),1,'Space controls transport after closing playlist');
assert.equal(await evaluate('Boolean(document.querySelector("[role=menu]"))'),false);
assert.equal(await evaluate('document.querySelector("#play").dataset.active'),'true');
await key(' ','Space',32);assert.equal(await evaluate('document.querySelector("#play").dataset.active'),'false');
const peak=await evaluate('(()=>{const t=document.querySelector(".track"),p=t.querySelector(".peak");const a=t.getBoundingClientRect(),b=p.getBoundingClientRect();return{left:b.left-a.left,bottom:a.bottom-b.bottom,clip:p.classList.contains("clip")}})()');
assert.equal(peak.left,21);assert.ok(Math.abs(peak.bottom-5)<=1);assert.ok(peak.clip);
await click('.track-volume input');
const calls=await evaluate('fixture.calls.filter(c=>c.action==="mixer")');
assert.ok(calls.some(c=>c.payload.phase==='begin')&&calls.some(c=>c.payload.phase==='end'));
assert.ok(calls.every(c=>Number.isFinite(c.payload.value)));
await click('#master-volume');assert.deepEqual(await evaluate('fixture.calls.filter(c=>c.action==="mixer"&&c.payload.kind==="masterVolume").at(-1).payload.targets'),[]);
const drag=await evaluate(`(()=>{const r=document.querySelector('.track-volume input').getBoundingClientRect();return{x:r.left+r.width*.25,end:r.left+r.width*.75,y:r.top+r.height/2,at:fixture.calls.length}})()`);
await send('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,x:drag.x,y:drag.y});
await send('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,x:drag.end,y:drag.y});
await new Promise(r=>setTimeout(r,80));
let changes=await evaluate(`fixture.calls.slice(${drag.at}).filter(c=>c.action==='mixer')`);
assert.equal(changes.filter(c=>c.payload.phase==='begin').length,1);
assert.equal(changes.filter(c=>c.payload.phase==='end').length,0,'Native range drag ended before mouse-up');
assert.ok(changes.filter(c=>c.payload.phase==='change').length>=2,'The fader did not continue following its held pointer: '+JSON.stringify(changes));
await send('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,x:drag.end,y:drag.y});
changes=await evaluate(`fixture.calls.slice(${drag.at}).filter(c=>c.action==='mixer')`);assert.equal(changes.filter(c=>c.payload.phase==='end').length,1);
await evaluate(`(async()=>{const fx=await import('./app-effects.js');fixture.fxSettings={inserted:[],instances:[]};fx.insertNativeEffect(fixture.fxSettings,'EQ');})()`);
await click('.track-fx');
for(let i=0;i<20;i++){if(await evaluate('Boolean(document.querySelector(".fx-eq-graph canvas"))'))break;await new Promise(r=>setTimeout(r,30));}
assert.equal(await evaluate('fixture.calls.filter(c=>c.action==="effectsGet").at(-1).payload.trackID'),'drums');
assert.equal(await evaluate('document.querySelector(".fx-heading strong").textContent'),'FX · DRUMS');
await click('.fx-close');assert.equal(await evaluate('Boolean(document.querySelector(".catlive-fx"))'),false,'Track FX did not close');await click('#master-fx');
for(let i=0;i<20;i++){if(await evaluate('Boolean(document.querySelector(".fx-eq-graph canvas"))'))break;await new Promise(r=>setTimeout(r,30));}
assert.equal(await evaluate('fixture.calls.filter(c=>c.action==="effectsGet").at(-1).payload.trackID'),'');
assert.equal(await evaluate('document.querySelector(".fx-heading strong").textContent'),'FX · Master');
await evaluate(`fixture.push({type:'snapshot',revision:1,project:{...project,id:'second-project'},song,transport,language:'pt'});`);
assert.equal(await evaluate('Boolean(document.querySelector(".catlive-fx"))'),false,'Changing project retained a stale FX editor');
assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
assert.equal(await evaluate('document.querySelector("#grid-canvas").width/Math.round(document.querySelector("#grid").getBoundingClientRect().width)'),dpr);
assert.equal(await evaluate('document.querySelector(".track-name").scrollHeight<=document.querySelector(".track-name").clientHeight'),true,'Track label clipped vertically');
// Record the real canvas paths, then use the real pointer hit-test. No product
// diagnostics or synthetic waveform geometry is needed for this layout check.
await evaluate(`(()=>{
  const ctx=document.querySelector('#grid-canvas').getContext('2d'),round=ctx.roundRect.bind(ctx),clear=ctx.clearRect.bind(ctx),stroke=ctx.stroke.bind(ctx);
  fixture.rectangles=[];fixture.strokes=[];
  ctx.clearRect=(...args)=>{fixture.rectangles=[];fixture.strokes=[];fixture.lastRounded=null;return clear(...args);};
  ctx.roundRect=(...args)=>{fixture.rectangles.push(args);fixture.lastRounded=args;return round(...args);};
  ctx.stroke=(...args)=>{fixture.strokes.push({style:ctx.strokeStyle,width:ctx.lineWidth,rect:fixture.lastRounded});return stroke(...args);};
  fixture.originalClips=song.tracks[0].clips;
  const clip=(id,startTime,duration)=>({id,name:id,startTime,duration});
  song.tracks[0].clips=[clip('isolated',1,2),clip('adjacent',3,2),clip('pair-a',6,4),clip('pair-b',7,4),clip('triple-a',12,4),clip('triple-b',13,4),clip('triple-c',14,4)];
  fixture.push({type:'snapshot',revision:2,project,song,transport,language:'pt'});
})()`);
await evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
assert.equal(await evaluate('document.querySelector(".track").getBoundingClientRect().height'),150,'Track height retains the global maximum of three lanes');
let rectangles=await evaluate('fixture.rectangles.map(r=>r.slice(0,4))');
for(const expected of [[21,3,38,144],[61,3,38,144],[121,3,78,69],[141,78,78,69],[241,3,78,44],[261,53,78,44],[281,103,78,44]])
  assert.ok(rectangles.some(rect=>rect.every((n,i)=>Math.abs(n-expected[i])<.01)),`Real canvas has local item geometry ${expected}; got ${JSON.stringify(rectangles)}`);
const lowerItem=await evaluate(`(()=>{const r=document.querySelector('#grid').getBoundingClientRect();return{x:r.left+155,y:r.top+90}})()`);
await send('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...lowerItem});
await send('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...lowerItem});
await evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
assert.deepEqual(await evaluate(`fixture.strokes.filter(s=>s.style==='#80ff9c').map(s=>s.rect.slice(0,4))`),[[141,78,78,69]],'Hit-testing must select the lower local lane using its painted geometry');
await evaluate(`song.tracks[0].clips=fixture.originalClips;fixture.push({type:'snapshot',revision:3,project:{...project,id:'restored-fixture'},song,transport,language:'pt'});`);
await evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
for(const [width,density] of [[800,1],[1000,1.25],[1440,2]]){
  await send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:density,mobile:false});
  await evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  assert.ok(await evaluate('document.documentElement.scrollWidth<=innerWidth'),`no horizontal UI overflow at ${width}/${density}`);
  assert.ok(await evaluate('(()=>{const a=document.querySelector("#play").getBoundingClientRect(),b=document.querySelector("#transport").getBoundingClientRect();return a.left>=b.left&&a.right<=b.right&&a.bottom<=b.bottom})()'),`transport remains inside its row at ${width}/${density}`);
}
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:dpr,mobile:false});
await evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
const screenshot=await send('Page.captureScreenshot',{format:'png'});
await fs.writeFile(`/private/tmp/catlive-frontend-review/workspace-${dpr}x.png`,Buffer.from(screenshot.data,'base64'));
console.log('NATIVE_FRONTEND_REAL_DOM_PLAYLIST_SPACE_METERS_FADER_CANVAS_LOCAL_ITEM_LANES_AND_NATIVE_FX_ROUTING_OK');
socket.close();
