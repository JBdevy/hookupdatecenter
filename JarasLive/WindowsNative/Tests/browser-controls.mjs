// Run against an isolated Edge/WebView-compatible Chromium instance serving
// browser-controls.html. CDP input tests real DOM focus/layout/font rendering;
// these tests do not claim the product's complete UI has been migrated.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const endpoint = process.env.CATLIVE_CDP ?? 'http://127.0.0.1:9224';
const pages = await (await fetch(`${endpoint}/json/list`, {signal: AbortSignal.timeout(10000)})).json();
const page = pages.find(page => page.type === 'page' && page.url === 'http://127.0.0.1:8765/');
assert.ok(page, 'component test page is open');
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {socket.addEventListener('open', resolve, {once:true}); socket.addEventListener('error', reject, {once:true})});
let serial = 0; const pending = new Map();
socket.addEventListener('message', event => {
  const reply = JSON.parse(event.data); const request = pending.get(reply.id);
  if (request) { pending.delete(reply.id); clearTimeout(request.timer); reply.error ? request.reject(reply.error) : request.resolve(reply.result); }
});
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => {pending.delete(id);reject(new Error(`Timeout: ${method}`))}, 10000);
    pending.set(id, {resolve,reject,timer}); socket.send(JSON.stringify({id,method,params}));
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {expression,returnByValue:true,awaitPromise:true});
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function click(x,y,button='left') {
  await send('Input.dispatchMouseEvent', {type:'mousePressed',x,y,button,clickCount:1});
  await send('Input.dispatchMouseEvent', {type:'mouseReleased',x,y,button,clickCount:1});
}
async function key(key, code, windowsVirtualKeyCode, modifiers = 0) {
  const event = {key,code,windowsVirtualKeyCode,modifiers};
  await send('Input.dispatchKeyEvent', {type:'keyDown',...event});
  await send('Input.dispatchKeyEvent', {type:'keyUp',...event});
}
async function bounds(selector) {
  return evaluate(`(() => {const element=document.querySelector(${JSON.stringify(selector)});if(!element)throw Error('Missing element');const r=element.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height}})()`);
}
async function clickControl(selector,button='left') {
  const {x,y,width,height}=await bounds(selector);assert.ok(width>0&&height>0,`${selector} is visible`);await click(x,y,button);
}
async function property(selector,expression) {
  return evaluate(`(() => {const element=document.querySelector(${JSON.stringify(selector)});return ${expression}})()`);
}
const control=name=>`[data-recording-control="${name}"]`;
const lock='[data-control="timeline-movement-lock"]';
async function enterChannels(value) {
  await clickControl(control('channels'));await key('a','KeyA',65,2);await send('Input.insertText',{text:String(value)});
}
async function menuLabels() {
  return evaluate(`Array.from(document.querySelectorAll('.catlive-context-menu [role^="menuitem"]'),element=>element.textContent.trim())`);
}
async function chooseMenu(label) {
  const target=await evaluate(`(() => {const element=Array.from(document.querySelectorAll('.catlive-context-menu [role^="menuitem"]')).find(element=>element.textContent.trim()===${JSON.stringify(label)});if(!element)throw Error('Missing menu label');const r=element.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  await click(target.x,target.y);
}
async function calls(name) {return evaluate(`fixture.calls.filter(call=>call.name===${JSON.stringify(name)})`)}
async function screenshot(name) {
  if(!process.env.CATLIVE_COMPONENT_SCREENSHOTS)return;
  await fs.mkdir(process.env.CATLIVE_COMPONENT_SCREENSHOTS,{recursive:true});
  const capture=await send('Page.captureScreenshot',{format:'png',fromSurface:true});
  await fs.writeFile(`${process.env.CATLIVE_COMPONENT_SCREENSHOTS}/${name}.png`,Buffer.from(capture.data,'base64'));
}
try {
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', {width:1366,height:768,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate', {url:'http://127.0.0.1:8765/'});
  for (let attempt=0;attempt<100;attempt++) {
    if (await evaluate('window.ready === true')) break;
    await new Promise(resolve => setTimeout(resolve,50));
  }
  await evaluate('document.fonts.ready');
  assert.equal(await evaluate('window.ready'), true);
  await click(420,180); await key('a','KeyA',65,2);
  await click(80,180,'right'); await key('a','KeyA',65,2);
  await click(1210,180); await key('a','KeyA',65,2);
  await click(420,700); await key('a','KeyA',65,2);
  assert.deepEqual(await evaluate('window.counts'), {tracks:1,timeline:1,setlist:1,piano:1});
  await evaluate('document.getElementById("text").focus()');
  await key('a','KeyA',65,2);
  assert.equal(await evaluate('document.activeElement.selectionEnd-document.activeElement.selectionStart'), 'Nome da pista'.length);
  assert.deepEqual(await evaluate('window.counts'), {tracks:1,timeline:1,setlist:1,piano:1});
  assert.equal(await evaluate('window.getSelection().toString()'), 'Nome da pista');
  await evaluate('window.openMenu(1340,750)');
  await key('ArrowRight','ArrowRight',39);
  assert.equal(await evaluate('document.querySelectorAll(".catlive-context-menu").length'), 2);
  await key('ArrowLeft','ArrowLeft',37);
  await key('a','KeyA',65,2);
  assert.deepEqual(await evaluate('window.counts'), {tracks:1,timeline:1,setlist:1,piano:1});
  await key('Escape','Escape',27);
  assert.equal(await evaluate('document.querySelectorAll(".catlive-context-menu").length'), 0);

  // Real browser input tests for the lock, with the explicitly simulated action
  // adapter exercising busy, failure and document-session race boundaries.
  assert.equal(await property(lock,'element.nextElementSibling.id'),'add');
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'false');
  assert.equal(await property(lock,'getComputedStyle(element).backgroundColor'),'rgba(255, 255, 255, 0.12)');
  await clickControl(lock,'right');assert.equal((await calls('lock')).length,0);
  await evaluate('fixture.hold("lock")');await clickControl(lock);await clickControl(lock);
  assert.equal((await calls('lock')).length,1);
  assert.equal(await property(lock,'element.disabled'),true);
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'false');
  await evaluate('fixture.release("lock")');
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'true');
  assert.equal(await property(lock,'getComputedStyle(element).backgroundColor'),'rgb(255, 220, 82)');
  await evaluate(`document.querySelector(${JSON.stringify(lock)}).focus()`);await key(' ','Space',32);
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'false');
  await evaluate('fixture.hold("lock")');await clickControl(lock);
  await evaluate('fixture.lock.reset({projectId:"fixture-project",sessionId:"fixture-session-2",locked:false,revision:0});fixture.release("lock")');
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'false');
  assert.equal(await property(lock,'element.disabled'),false);
  await evaluate('fixture.hold("lock")');await clickControl(lock);await evaluate('fixture.reject("lock","Rejected test command")');
  assert.deepEqual(await evaluate('fixture.errors'),['Rejected test command']);
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'false');
  await clickControl(lock);
  assert.equal(await property(lock,'element.getAttribute("aria-pressed")'),'true');

  assert.equal(await property(control('channels'),'element.value'),'32');
  await clickControl(control('decrease'));assert.equal(await property(control('channels'),'element.value'),'31');
  await clickControl(control('increase'));await clickControl(control('increase'),'right');
  const channelBounds=await bounds(control('channels'));
  await send('Input.dispatchMouseEvent',{type:'mouseWheel',x:channelBounds.x,y:channelBounds.y,deltaY:-100,deltaX:0});
  assert.equal(await property(control('channels'),'element.value'),'32');
  await enterChannels('0');assert.equal(await property(control('create'),'element.disabled'),true);
  await clickControl(control('create'));assert.equal((await calls('createProject')).length,0);
  await enterChannels('128');assert.equal(await property(control('increase'),'element.disabled'),true);
  await enterChannels('1');assert.equal(await property(control('decrease'),'element.disabled'),true);
  await enterChannels('32');await evaluate('fixture.hold("createProject")');
  await clickControl(control('create'));await clickControl(control('create'));
  assert.equal((await calls('createProject')).length,1);
  assert.equal(await property(control('channels'),'element.disabled'),true);
  await evaluate('fixture.release("createProject")');
  await clickControl(control('back'));assert.deepEqual((await calls('back'))[0].payload,{});
  await clickControl(control('channels'));await key('Enter','Enter',13);
  assert.deepEqual((await calls('createProject')).map(call=>call.payload),[{channels:32},{channels:32}]);

  await clickControl(control('mode-1'));assert.equal(await property(control('mode-1'),'element.getAttribute("aria-checked")'),'true');
  await key('ArrowRight','ArrowRight',39);assert.equal(await property(control('mode-2'),'element.getAttribute("aria-checked")'),'true');
  await key('End','End',35);assert.equal(await property(control('mode-0'),'element.getAttribute("aria-checked")'),'true');
  assert.equal(await property(control('format'),'element.closest(".catlive-recording-row").hidden'),true);
  assert.equal(await property(control('monitor-true'),'element.closest(".catlive-recording-row").hidden'),true);
  await key('Home','Home',36);
  await clickControl(control('format'));
  assert.deepEqual(await menuLabels(),['Use Advanced setting','WAV · 24-bit PCM','WAV · 32-bit float','MP3 · 320 kbps']);
  await screenshot('recording-format-menu');await chooseMenu('WAV · 32-bit float');
  assert.deepEqual((await calls('format')).at(-1).payload,{id:'fixture-track',format:'wav32'});
  assert.equal(await property(control('format'),'element.textContent'),'WAV · 32-bit float');
  await clickControl(control('monitor-false'));assert.deepEqual((await calls('monitor')).at(-1).payload,{id:'fixture-track',enabled:false});
  await evaluate('fixture.hold("format")');await clickControl(control('format'));await chooseMenu('MP3 · 320 kbps');
  assert.equal(await property(control('format'),'element.textContent'),'WAV · 32-bit float');
  await evaluate('fixture.reject("format","Format rejected for test")');
  assert.equal(await property('#rec-track [role="alert"]','element.textContent'),'Format rejected for test');
  assert.equal(await property(control('format'),'element.textContent'),'WAV · 32-bit float');
  await evaluate('fixture.track.update({recording:true})');
  assert.equal(await property(control('mode-2'),'element.disabled'),true);
  assert.equal(await property(control('format'),'element.disabled'),true);
  assert.equal(await property(control('monitor-true'),'element.disabled'),false);
  await evaluate('fixture.track.update({recording:false})');
  await clickControl(control('format'));await evaluate('fixture.track.update({track:{id:"fixture-track-2",recordingChannels:2,recordingFormat:null,inputMonitoring:true}})');
  assert.equal(await evaluate('document.querySelectorAll(".catlive-context-menu").length'),0);
  await evaluate('fixture.hold("channels")');await clickControl(control('mode-1'));await clickControl(control('channels'));
  await evaluate('fixture.release("channels")');
  assert.equal(await property(control('channels'),'document.activeElement===element'),true,'completion must not steal focus moved to another control');
  assert.equal(await property(control('mode-1'),'element.getAttribute("aria-checked")'),'true');
  await evaluate('fixture.hold("channels")');await clickControl(control('mode-2'));
  await evaluate('fixture.track.update({track:{id:"fixture-track-3",recordingChannels:0,recordingFormat:null,inputMonitoring:true}});fixture.release("channels")');
  assert.equal(await property(control('mode-0'),'element.getAttribute("aria-checked")'),'true','old track response must not overwrite the new track');
  await evaluate('fixture.track.update({track:{id:"fixture-track-3",recordingChannels:2,recordingFormat:null,inputMonitoring:true}})');

  await clickControl(control('advanced-format'));assert.deepEqual(await menuLabels(),['WAV','AIFF','MP3']);await chooseMenu('MP3');
  assert.equal(await property(control('advanced-bits'),'element.closest(".catlive-recording-row").hidden'),true);
  assert.equal(await property(control('advanced-bitrate'),'element.closest(".catlive-recording-row").hidden'),false);
  await clickControl(control('advanced-bitrate'));
  assert.deepEqual(await menuLabels(),['128 kbps','160 kbps','192 kbps','224 kbps','256 kbps','320 kbps']);
  await screenshot('advanced-mp3-bitrates');await chooseMenu('192 kbps');
  assert.deepEqual((await calls('advanced')).at(-1).payload,{format:'MP3',bitDepth:24,bitrate:192});
  await clickControl(control('advanced-format'));await chooseMenu('AIFF');
  await clickControl(control('advanced-bits'));assert.deepEqual(await menuLabels(),['16-bit PCM','24-bit PCM','32-bit PCM']);await chooseMenu('32-bit PCM');
  assert.deepEqual((await calls('advanced')).at(-1).payload,{format:'AIFF',bitDepth:32,bitrate:192});
  await clickControl(control('advanced-format'));await chooseMenu('MP3');
  await evaluate('fixture.hold("advanced")');await clickControl(control('advanced-bitrate'));await chooseMenu('128 kbps');
  assert.equal(await property(control('advanced-bitrate'),'element.textContent'),'192 kbps');
  await evaluate('fixture.reject("advanced","Advanced rejected for test")');
  assert.equal(await property(control('advanced-bitrate'),'element.textContent'),'192 kbps');
  assert.equal(await property('#rec-advanced [role="alert"]','element.textContent'),'Advanced rejected for test');
  await evaluate('fixture.advanced.update({format:"MP3",bitDepth:32,bitrate:192})');
  await screenshot('controls-100-percent');

  const layouts = [];
  for (const scale of [.6,.7,.8,.9,1,1.1,1.2]) {
    await evaluate(`document.documentElement.style.setProperty('--catlive-menu-font-size','${12*scale}px');window.openMenu(1360,760)`);
    const layout = await evaluate(`(() => {const e=document.querySelector('.catlive-context-menu');const r=e.getBoundingClientRect();const s=getComputedStyle(e);return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,font:s.fontFamily,size:s.fontSize,radius:s.borderRadius,blur:s.backdropFilter}})()`);
    assert.ok(layout.left >= 0 && layout.top >= 0 && layout.right <= 1366 && layout.bottom <= 768);
    assert.match(layout.font,/Inter/); assert.match(layout.blur,/blur\(16px\)/); assert.equal(layout.radius,'11px');
    layouts.push({scale,...layout});
    await key('Escape','Escape',27);
    // The host font-size token is tested at every supported percentage. The
    // isolated fixture does not claim to validate the complete app's scaling.
    const panels=await evaluate(`Array.from(document.querySelectorAll('.catlive-recording-panel')).map(element=>{const r=element.getBoundingClientRect(),s=getComputedStyle(element);return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,scrollWidth:element.scrollWidth,clientWidth:element.clientWidth,font:s.fontFamily,size:s.fontSize,transform:s.transform}})`);
    for(const panel of panels){
      assert.ok(panel.left>=0&&panel.top>=0&&panel.right<=1366&&panel.bottom<=768,`panel fits at ${scale}`);
      assert.ok(panel.scrollWidth<=panel.clientWidth,`panel has no horizontal clipping at ${scale}`);
      assert.match(panel.font,/Inter/);assert.equal(panel.transform,'none');
      assert.ok(Math.abs(parseFloat(panel.size)-12*scale)<.001);
    }
    layouts.at(-1).panels=panels;
    await clickControl(control('advanced-bitrate'));await chooseMenu(scale===.6?'128 kbps':'320 kbps');
    if(scale===.6||scale===1.2)await screenshot(`controls-${Math.round(scale*100)}-percent`);
  }
  await evaluate(`document.documentElement.style.setProperty('--catlive-menu-font-size','12px');document.getElementById('text').blur();window.openMenu(245,110)`);
  await key('ArrowRight','ArrowRight',39);
  if (process.env.CATLIVE_MENU_SCREENSHOT) {
    const capture = await send('Page.captureScreenshot', {format:'png',fromSurface:true});
    await fs.writeFile(process.env.CATLIVE_MENU_SCREENSHOT,Buffer.from(capture.data,'base64'));
  }
  console.log(JSON.stringify({passed:true,scope:'Real Edge component tests with an explicit simulated action adapter; not full product integration',engine:await evaluate('navigator.userAgent'),actions:await evaluate('fixture.calls'),layouts},null,2));
} catch (error) {
  await screenshot('failure').catch(()=>{});
  throw error;
} finally { socket.close(); }
