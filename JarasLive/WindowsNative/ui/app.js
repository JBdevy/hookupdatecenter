import {showContextMenu, isContextMenuOpen} from './context-menu.js';
import {SelectionRouter, isTextInput} from './selection.js';
import {openEffects, closeEffects} from './app-effects.js';
import {clamp, decibels, gainLabel, sliderGain, gainSlider, clock, color, readable, layoutTracks, regionLanes, playlistRows, meterFraction, zoomAt, fadeGain} from './app-model.js';

const $ = id => document.getElementById(id);
const state = {project:null,song:null,transport:{},language:'pt-BR',revision:0,rows:[],tracks:new Set(),items:new Set(),regions:new Set(),
  scale:20,offset:0,vertical:0,follow:false,heights:new Map(),waveforms:new Map(),pendingWaves:new Set(),telemetryAt:0};
const host = globalThis.chrome?.webview;
const pending = new Map(); let serial = 0, frame = 0, gesture = null, playlistClose = null, playlistOpen = false, suppressPlaylistClick = false, viewportKey = '';
const tr = (pt,en) => state.language.startsWith('pt') ? pt : en;
function request(action, payload = {}) {
  if (!host) return Promise.reject(new Error(tr('A conexão com o CatLive não está disponível.','The connection to CatLive is unavailable.')));
  const id = ++serial;
  return new Promise((resolve,reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(tr('O CatLive não respondeu.','CatLive did not respond.'))); },60000);
    pending.set(id,{resolve,reject,timer});
    host.postMessage({id,action,payload:{...payload,projectID:payload.projectID??state.project?.id}});
  });
}
function send(action,payload) { request(action,payload).catch(error => notice(error.message)); }
function notice(message) { $('notice').textContent = message ?? ''; }
function dialog(title,message,buttons = [{id:'ok',label:'OK'}],respond = () => {}) {
  const element = $('message');
  if (element.open) element.close();
  element.querySelector('h2').textContent = title || 'CatLive';
  element.querySelector('p').textContent = message || '';
  const actions = element.querySelector('.dialog-actions'); actions.replaceChildren();
  for (const choice of buttons) {
    const button = document.createElement('button'); button.value=choice.id; button.textContent=choice.label;
    actions.append(button);
  }
  element.returnValue='cancel';
  element.onclose=()=>respond(element.returnValue || 'cancel');
  element.showModal();
}
host?.addEventListener('message',event=>receive(typeof event.data==='string'?JSON.parse(event.data):event.data));
function receive(message) {
  if (!message || typeof message !== 'object') return;
  if (message.type==='reply') {
    const call=pending.get(message.id); if(!call)return; clearTimeout(call.timer); pending.delete(message.id);
    if(message.ok)call.resolve(message.result);else call.reject(new Error(message.error||'CatLive')); return;
  }
  if(message.type==='notice'){notice(message.message);if(message.title)dialog(message.title,message.message);return;}
  if(message.type==='confirm'){dialog(message.title,message.message,message.buttons,choice=>send('confirm',{token:message.token,choice}));return;}
  if(message.type==='snapshot'){
    const changed=state.project?.id!==message.project?.id || state.song?.id!==message.song?.id;
    if(changed)closeEffects({discard:true});
    state.project=message.project;state.song=message.song??message.project?.songs?.[0];state.revision=message.revision;
    state.language=message.language||state.language;state.transport=message.transport??state.transport;state.auth=message.auth;
    updateAccount();
    if(changed){state.items.clear();state.tracks.clear();state.regions.clear();state.heights.clear();state.waveforms.clear();state.offset=0;state.vertical=0;state.follow=false;}
    state.rows=layoutTracks(state.song?.tracks??[],state.heights);
    document.documentElement.lang=state.language;
    document.querySelectorAll('[data-pt]').forEach(el=>el.textContent=tr(el.dataset.pt,el.dataset.en));
    $('project-name').textContent=state.project?.name||'CatLive';
    $('document-name').textContent=typeof message.document==='string'?message.document:(message.document?.name??'');
    if(message.status)notice(message.status);
    $('save').classList.toggle('dirty',Boolean(message.dirty));
    $('undo').disabled=message.canUndo===false;$('redo').disabled=message.canRedo===false;
    if(!gesture || gesture.trackID!=='')$('master-volume').value=gainSlider(state.project?.masterVolume??1);
    $('master-value').textContent=`${gainLabel(state.project?.masterVolume??1)} dB`;
    renderTracks();renderSetlist();resize();updateTransport();return;
  }
  if(message.type==='telemetry'){
    state.transport=message.transport??state.transport;state.telemetryAt=performance.now();
    updateMeters(message.meters);updateTransport();return;
  }
}

function mixer(kind,trackID,value,phase='change') {
  const targets=trackID?(state.tracks.has(trackID)?[...state.tracks]:[trackID]):[];
  send('mixer',{kind,trackID,value,targets,phase});
}
function updateAccount(){
  const auth=state.auth??{};$('account-state').textContent=auth.message||auth.title||'';
  const device=Boolean(auth.requiresDeviceName),allowed=Boolean(auth.allowed);
  $('email-label').hidden=$('cpf-label').hidden=device||allowed;$('device-label').hidden=!device;
  $('account-email').required=$('account-cpf').required=!device&&!allowed;$('account-device').required=device;
  $('account-submit').hidden=allowed;$('account-submit').disabled=Boolean(auth.busy);
  $('account-submit').textContent=device?tr('Salvar nome','Save name'):tr('Entrar','Sign in');
  $('account-close').textContent=tr('Fechar','Close');
}
$('account').onclick=()=>{updateAccount();$('account-dialog').showModal();};
$('account-close').onclick=()=>$('account-dialog').close();
$('account-dialog').querySelector('form').onsubmit=event=>{
  event.preventDefault();const device=state.auth?.requiresDeviceName;
  request(device?'deviceName':'login',device?{name:$('account-device').value}:{email:$('account-email').value,cpf:$('account-cpf').value}).catch(error=>$('account-state').textContent=error.message);
};
let finishSliderGesture=null;
function installSlider(input,kind,trackID,convert,local) {
  let active=false,held=false;
  const begin=()=>{if(active)return;active=true;gesture={trackID,kind};mixer(kind,trackID,convert(Number(input.value)),'begin');};
  const finish=()=>{held=false;if(finishSliderGesture===finish)finishSliderGesture=null;if(!active)return;active=false;mixer(kind,trackID,convert(Number(input.value)),'end');gesture=null;};
  // Chromium owns capture on the range thumb; taking capture on its outer
  // input terminates that native drag as soon as the pointer starts moving.
  input.addEventListener('pointerdown',event=>{event.stopPropagation();if(event.button!==0)return;finishSliderGesture?.();held=true;finishSliderGesture=finish;begin();});
  input.addEventListener('input',()=>{begin();const value=convert(Number(input.value));local?.(value);mixer(kind,trackID,value);});
  input.addEventListener('pointerup',finish);input.addEventListener('pointercancel',finish);
  input.addEventListener('change',()=>{if(!held)finish();});input.addEventListener('blur',finish);
}
window.addEventListener('pointerup',()=>finishSliderGesture?.());window.addEventListener('pointercancel',()=>finishSliderGesture?.());
installSlider($('master-volume'),'masterVolume','',sliderGain,value=>$('master-value').textContent=`${gainLabel(value)} dB`);
$('master-peak').onclick=()=>send('clearPeak',{trackID:''});
function showEffects(trackID='') {
  const track=state.song?.tracks?.find(track=>track.id===trackID);
  if(trackID&&!track)return;
  openEffects({trackID,name:track?.name??'Master',request,language:state.language,projectID:state.project?.id});
}
$('master-fx').onclick=()=>showEffects();

const trackElements=new Map();
function renderTracks(){
  const ids=new Set(state.rows.map(row=>row.track.id));
  for(const [id,element] of trackElements)if(!ids.has(id)){element.remove();trackElements.delete(id);}
  for(const [index,row] of state.rows.entries()){
    const track=row.track;let element=trackElements.get(track.id);
    if(!element){
      element=document.createElement('div');element.className='track';element.dataset.id=track.id;
      element.innerHTML='<div class="track-meters"><i></i><i></i></div><button class="peak" aria-label="Reset peak"></button><div class="track-name"></div><div class="track-controls"><button class="track-fx" aria-label="FX">FX</button><input class="track-pan" type="range" min="-1" max="1" step="0.01" aria-label="Pan"><button data-kind="mute">M</button><button data-kind="solo">S</button></div><div class="track-volume"><output></output><input type="range" min="0" max="1" step="0.001" aria-label="Volume"></div><button class="track-phase" data-kind="phase" aria-label="Phase invert">Ø</button><div class="track-resize"></div>';
      element.addEventListener('pointerdown',event=>{
        if(event.target.closest('input,button,.track-resize'))return;
        if(event.ctrlKey||event.metaKey){state.tracks.has(track.id)?state.tracks.delete(track.id):state.tracks.add(track.id);}else{state.tracks=new Set([track.id]);}
        send('selectTracks',{trackIDs:[...state.tracks]});updateSelections();
      });
      element.querySelector('.peak').onclick=()=>send('clearPeak',{trackID:track.id});
      element.querySelector('.track-fx').onclick=()=>showEffects(track.id);
      for(const button of element.querySelectorAll('[data-kind]'))button.onclick=()=>mixer(button.dataset.kind,track.id,button.dataset.active!=='true'?1:0);
      const volume=element.querySelector('.track-volume input');
      installSlider(volume,'volume',track.id,sliderGain,value=>element.querySelector('output').textContent=gainLabel(value));
      installSlider(element.querySelector('.track-pan'),'pan',track.id,value=>value);
      const grip=element.querySelector('.track-resize');let heightDrag=null;
      grip.onpointerdown=event=>{if(event.button!==0)return;event.preventDefault();grip.setPointerCapture(event.pointerId);heightDrag={y:event.clientY,height:element.offsetHeight};};
      grip.onpointermove=event=>{if(!heightDrag)return;const height=clamp(heightDrag.height+event.clientY-heightDrag.y,24,480);state.heights.set(track.id,height);state.rows=layoutTracks(state.song.tracks,state.heights);updateRowSizes();draw();};
      grip.onpointerup=()=>{heightDrag=null;};grip.onpointercancel=()=>{heightDrag=null;};
      trackElements.set(track.id,element);
    }
    const surface=color(track.color);element.style.setProperty('--track-color',surface);element.style.setProperty('--track-text',readable(surface));
    element.style.setProperty('--indent',`${row.indent}px`);element.style.height=`${row.height}px`;element.classList.toggle('compact',row.height<64);
    element.querySelector('.track-name').textContent=`${String(index+1).padStart(2,'0')}  ${track.name}`;
    element.classList.toggle('silent',Boolean(track.mute));
    if(!gesture || gesture.trackID!==track.id){element.querySelector('.track-volume input').value=gainSlider(track.volume??1);element.querySelector('.track-pan').value=track.pan??0;}
    element.querySelector('output').textContent=gainLabel(track.volume??1);
    for(const [key,value] of Object.entries({mute:track.mute,solo:track.solo,phase:track.phaseInverted}))element.querySelector(`[data-kind=${key}]`).dataset.active=Boolean(value);
    // Retain existing controls during every fader tick, including pointer capture.
    const at=$('tracks').children[index];if(at!==element)$('tracks').insertBefore(element,at??null);
  }
  updateSelections();publishViewport();
}
function updateRowSizes(){for(const row of state.rows){const e=trackElements.get(row.track.id);if(e){e.style.height=`${row.height}px`;e.classList.toggle('compact',row.height<64);}}publishViewport();}
function updateSelections(){for(const [id,el]of trackElements)el.classList.toggle('selected',state.tracks.has(id));draw();}

let setlistKey='';
function renderSetlist(){
  const playlist=playlistRows(state.project,state.song);
  $('playlist').firstChild.textContent=`${playlist.name} `;
  const key=JSON.stringify([state.song?.id,playlist]);
  if(key!==setlistKey){
    setlistKey=key;$('setlist').replaceChildren();
    for(const {entryID,part}of playlist.rows){
      const button=document.createElement('button');button.className='region';button.dataset.id=part.id;button.dataset.entry=entryID;button.style.setProperty('--region-color',color(part.color));
      const title=document.createElement('strong');title.textContent=part.name;
      const details=document.createElement('span');const start=document.createElement('span');start.textContent=clock(part.startTime,true);const duration=document.createElement('span');duration.textContent=clock(part.endTime-part.startTime);details.append(start,duration);button.append(title,details);
      button.onpointerdown=event=>{if(event.button!==0)return;event.preventDefault();
        if(event.ctrlKey||event.metaKey){state.regions.has(entryID)?state.regions.delete(entryID):state.regions.add(entryID);}else state.regions=new Set([entryID]);
        send('selectRegion',{regionID:part.id,entryID});state.follow=false;focusRegion(part);renderSetlistSelection();};
      $('setlist').append(button);
    }
  }
  $('setlist-count').textContent=String(playlist.rows.length);
  $('setlist-duration').textContent=clock(playlist.rows.reduce((sum,{part})=>sum+Math.max(0,part.endTime-part.startTime),0),true);
  renderSetlistSelection();
}
function renderSetlistSelection(){for(const button of $('setlist').children){button.classList.toggle('selected',state.regions.has(button.dataset.entry)||button.dataset.id===state.transport.selectedRegionID);button.classList.toggle('playing',Boolean(state.transport.playing)&&button.dataset.id===(state.transport.regionID??state.transport.selectedRegionID));}}
function closePlaylist(){playlistClose?.();playlistClose=null;playlistOpen=false;$('playlist').setAttribute('aria-expanded','false');}
$('playlist').onclick=()=>{
  if(suppressPlaylistClick){suppressPlaylistClick=false;return;}
  if(playlistOpen){closePlaylist();return;}
  const rect=$('playlist').getBoundingClientRect();const current=state.project?.regionSetlist?.selectedId;
  const choices=[{id:'',name:'All Regions'},...(state.project?.regionSetlist?.playlists??[]).filter(p=>p.songId===state.song?.id)];
  playlistOpen=true;$('playlist').setAttribute('aria-expanded','true');
  playlistClose=showContextMenu({x:rect.left,y:rect.bottom+3,returnFocus:false,items:choices.map(p=>({label:p.name,checked:p.id===(current??''),action:()=>{closePlaylist();send('choosePlaylist',{playlistID:p.id});}}))});
};
// The native transport shortcut wins after the menu closes, even if the selector
// retains keyboard focus. Text editing and an open menu remain protected.
document.addEventListener('pointerdown',event=>{
  if(event.button===0&&playlistOpen&&event.target.closest?.('#playlist')){
    suppressPlaylistClick=true;closePlaylist();event.preventDefault();
  }
  setTimeout(()=>{if(playlistOpen&&!isContextMenuOpen()){playlistOpen=false;$('playlist').setAttribute('aria-expanded','false');}},0);
},true);

function resize(){
  const lanes=regionLanes(state.song?.parts??[]);state.lanes=lanes;
  document.documentElement.style.setProperty('--ruler-height',`${(lanes.count+3)*16}px`);
  for(const [id,parent]of [['grid-canvas','grid'],['ruler-canvas','ruler']]){
    const canvas=$(id),rect=$(parent).getBoundingClientRect(),dpr=devicePixelRatio||1;
    if(canvas.width!==Math.round(rect.width*dpr)||canvas.height!==Math.round(rect.height*dpr)){canvas.width=Math.round(rect.width*dpr);canvas.height=Math.round(rect.height*dpr);canvas.style.width=`${rect.width}px`;canvas.style.height=`${rect.height}px`;}
  }
  const duration=Math.max(state.song?.duration??0,60),width=$('grid').clientWidth;
  $('timeline-scroll').firstElementChild.style.width=`${Math.max(width,duration*state.scale)}px`;
  publishViewport();draw();
}
function publishViewport(){
  if(!state.project)return;
  const visible=document.body.classList.contains('track-hidden')?[]:state.rows.filter(row=>row.y+row.height>state.vertical&&row.y<state.vertical+$('tracks').clientHeight).map(row=>row.track.id);
  const key=state.project.id+':'+visible.join(',');
  if(key!==viewportKey){viewportKey=key;send('viewport',{trackIDs:visible});}
}
new ResizeObserver(resize).observe($('workspace'));
$('tracks').onscroll=()=>{state.vertical=$('tracks').scrollTop;publishViewport();draw();};
$('timeline-scroll').onscroll=()=>{state.offset=$('timeline-scroll').scrollLeft/state.scale;draw();};
function setOffset(value){state.offset=clamp(value,0,Math.max(0,(state.song?.duration??60)-$('grid').clientWidth/state.scale));$('timeline-scroll').scrollLeft=state.offset*state.scale;draw();}
function focusRegion(part){if(!part)return;const width=$('grid').clientWidth;state.scale=clamp(width/Math.max(2,(part.endTime-part.startTime)*1.15),.015,2000);resize();setOffset(Math.max(0,part.startTime-width/state.scale*.04));}
function draw(){if(!frame)frame=requestAnimationFrame(paint);}
function context(id){const c=$(id),ctx=c.getContext('2d');ctx.setTransform(devicePixelRatio||1,0,0,devicePixelRatio||1,0,0);return ctx;}
function clippedText(ctx,text,x,y,width){if(width<4)return;ctx.save();ctx.beginPath();ctx.rect(x,y-12,width,16);ctx.clip();ctx.fillText(text,x,y);ctx.restore();}
function paint(){
  frame=0;const width=$('grid').clientWidth,height=$('grid').clientHeight,ctx=context('grid-canvas');
  ctx.clearRect(0,0,width,height);ctx.fillStyle='#1d1d1d';ctx.fillRect(0,0,width,height);
  const bpm=state.transport.bpm??state.song?.bpm??120,beat=60/Math.max(1,bpm);
  let spacing=beat;while(spacing*state.scale<14)spacing*=2;
  ctx.strokeStyle='#343434';ctx.lineWidth=1;ctx.beginPath();
  for(let time=Math.floor(state.offset/spacing)*spacing;time<state.offset+width/state.scale;time+=spacing){const x=Math.round((time-state.offset)*state.scale)+.5;ctx.moveTo(x,0);ctx.lineTo(x,height);}ctx.stroke();
  ctx.font='600 10px Inter';state.hitItems=[];
  for(const row of state.rows){
    const y=row.y-state.vertical;if(y+row.height<0||y>height)continue;
    ctx.strokeStyle='#444';ctx.beginPath();ctx.moveTo(0,y+row.height-.5);ctx.lineTo(width,y+row.height-.5);ctx.stroke();
    for(const clip of row.track.clips??[]){
      const x=(clip.startTime-state.offset)*state.scale,w=clip.duration*state.scale;
      if(x+w<0||x>width||w<=0)continue;
      const {localLane,localCount}=row.itemLanes.entries.get(clip.id)??{localLane:0,localCount:1},laneHeight=row.audioHeight/localCount;
      const r={x:x+1,y:y+localLane*laneHeight+3,w:Math.max(1,w-2),h:Math.max(2,laneHeight-6),clip,track:row.track};state.hitItems.push(r);paintItem(ctx,r,width);
    }
  }
  paintRuler();updateCursors();
}
function paintItem(ctx,r,width){
  const {clip,track}=r,header=Math.min(21,r.h*.42),fill=color(track.color,'#515151');
  ctx.save();ctx.beginPath();ctx.roundRect(r.x,r.y,r.w,r.h,3);ctx.clip();
  ctx.globalAlpha=clip.muted ? .55 : 1;ctx.fillStyle=fill;ctx.fillRect(r.x,r.y,r.w,r.h);
  ctx.fillStyle='#484848';ctx.fillRect(r.x,r.y,r.w,header);
  const sourceName=(clip.name||clip.audioFile||track.audioFile||track.name||'').split(/[\\/]/).pop();
  const fullName=ctx.measureText(sourceName).width,space=r.w-9;
  let labelX=r.x+5;
  if(space>fullName+74){ctx.fillStyle='#eee';ctx.fillText(`${gainLabel((clip.gain??1)*(clip.normalizationGain??1))} dB`,labelX,r.y+14);labelX+=55;}
  if(space>22){ctx.fillStyle=clip.muted?'#ff5050':'#eee';ctx.fillText('M',labelX,r.y+14);labelX+=21;}
  ctx.fillStyle='#eee';clippedText(ctx,sourceName,labelX,r.y+14,r.x+r.w-labelX-3);
  const body={x:r.x,y:r.y+header,w:r.w,h:r.h-header};
  const start=Math.max(clip.startTime,state.offset),end=Math.min(clip.startTime+clip.duration,state.offset+width/state.scale);
  if(!clip.midi&&!clip.text&&(clip.audioFile||track.audioFile)&&end>start)paintWaveform(ctx,r,body,start,end);
  if(clip.text){ctx.fillStyle='#eee';ctx.font='10px Inter';clippedText(ctx,String(clip.text).replace(/\n/g,' '),r.x+4,body.y+13,r.w-8);}
  if(clip.midi){const notes=clip.midi.notes??[];ctx.fillStyle='#ddd';for(const note of notes){const nx=r.x+((note.startTime??note.start??0)*state.scale);const ny=body.y+body.h*(1-(note.pitch??60)/127);ctx.fillRect(nx,ny,Math.max(2,(note.duration??.1)*state.scale),2);}}
  ctx.restore();ctx.save();ctx.beginPath();ctx.roundRect(r.x,r.y,r.w,r.h,3);
  if(state.items.has(clip.id)){ctx.strokeStyle='#000';ctx.lineWidth=5;ctx.stroke();ctx.strokeStyle='#80ff9c';ctx.lineWidth=3;}else{ctx.strokeStyle=fill;ctx.lineWidth=.6;}ctx.stroke();ctx.restore();
}
function paintWaveform(ctx,r,body,start,end){
  const count=Math.max(1,Math.min(2048,Math.ceil((end-start)*state.scale*(devicePixelRatio||1))));
  const key=[state.project.id,state.song.id,r.clip.id,r.clip.audioFile??r.track.audioFile,r.clip.sourceOffset,r.clip.playbackRate,r.clip.loopStart,r.clip.loopLength,r.clip.channelMode,r.clip.startTime,r.clip.duration,start.toFixed(5),end.toFixed(5),count].join(':');
  const wave=state.waveforms.get(key);
  if(!state.waveforms.has(key)&&!state.pendingWaves.has(key)){
    state.pendingWaves.add(key);request('waveform',{clipID:r.clip.id,start,end,pixelWidth:count,revision:state.revision}).then(value=>{
      if(!value?.channels)return;if(state.waveforms.size>256)state.waveforms.delete(state.waveforms.keys().next().value);state.waveforms.set(key,value);draw();
    }).catch(()=>{state.waveforms.set(key,null);}).finally(()=>state.pendingWaves.delete(key));
  }
  if(!wave)return;
  const columnStart=wave.columnStart??wave.start,columnDuration=wave.columnDuration??(wave.end-wave.start)/wave.pixelWidth;
  const x=(columnStart-state.offset)*state.scale,w=columnDuration*wave.pixelWidth*state.scale,gain=clamp(r.clip.gain??1,0,15.8489)*clamp(r.clip.normalizationGain??1,0,15.8489),phase=r.clip.phaseInverted?-1:1;
  ctx.save();ctx.beginPath();ctx.rect(body.x,body.y,body.w,body.h);ctx.clip();ctx.fillStyle='#919184';ctx.strokeStyle='#919184';ctx.lineWidth=1/(devicePixelRatio||1);
  wave.channels.forEach((channel,index)=>{
    const laneH=body.h/wave.channels.length,mid=body.y+laneH*(index+.5),amp=laneH*.5;
    ctx.beginPath();ctx.moveTo(x,mid);ctx.lineTo(x+w,mid);ctx.stroke();
    const n=channel.min.length;if(!n)return;ctx.beginPath();
    for(let i=0;i<n;i++){
      const fade=fadeGain(r.clip,columnStart+(i+.5)*columnDuration);
      const a=channel.min[i]*gain*phase*fade,b=channel.max[i]*gain*phase*fade;
      const hi=clamp(Math.max(a,b),-1,1),lo=clamp(Math.min(a,b),-1,1);
      ctx.rect(x+i*w/n,mid-hi*amp,Math.max(w/n,.5/(devicePixelRatio||1)),Math.max((hi-lo)*amp,.5/(devicePixelRatio||1)));
    }ctx.fill();
  });ctx.restore();
}
function paintRuler(){
  const ctx=context('ruler-canvas'),w=$('ruler').clientWidth,h=$('ruler').clientHeight,lanes=state.lanes??regionLanes([]);
  ctx.clearRect(0,0,w,h);ctx.fillStyle='#1d1d1d';ctx.fillRect(0,0,w,h);ctx.font='600 9px Inter';
  for(const part of state.song?.parts??[]){
    const x=(part.startTime-state.offset)*state.scale,width=(part.endTime-part.startTime)*state.scale,y=(lanes.rows.get(part.id)??0)*16;
    if(x+width<0||x>w)continue;ctx.fillStyle=color(part.color,'#867589');ctx.fillRect(x,y,width,16);ctx.fillStyle=readable(ctx.fillStyle);clippedText(ctx,part.name,x+3,y+12,width-5);
  }
  for(const marker of state.song?.markers??[]){const x=(marker.position-state.offset)*state.scale;const y=lanes.count*16;ctx.fillStyle=color(marker.color,'#ccc');ctx.fillRect(x,y,2,16);clippedText(ctx,marker.name??'',x+4,y+12,120);}
  const step=state.scale>20?1:state.scale>4?10:state.scale>1?30:60;ctx.fillStyle='#aaa';
  for(let time=Math.floor(state.offset/step)*step;time<state.offset+w/state.scale;time+=step){const x=(time-state.offset)*state.scale;clippedText(ctx,clock(time,true),x+3,h-4,step*state.scale-4);}
  ctx.strokeStyle='#555';ctx.lineWidth=1;ctx.beginPath();for(let i=0;i<=lanes.count+3;i++){ctx.moveTo(0,Math.min(h-.5,i*16+.5));ctx.lineTo(w,Math.min(h-.5,i*16+.5));}ctx.stroke();
}
function updateCursors(){
  const position=state.transport.position??0,x=(position-state.offset)*state.scale;
  $('playhead').style.display=state.song&&x>=0&&x<=$('grid').clientWidth?'block':'none';$('playhead').style.left=`${x}px`;
  const edit=((state.transport.editPosition??position)-state.offset)*state.scale;
  $('edit-cursor').style.display=state.song&&edit>=0&&edit<=$('grid').clientWidth?'block':'none';$('edit-cursor').style.left=`${edit}px`;
}
function updateTransport(){
  const t=state.transport;$('play').dataset.active=Boolean(t.playing);$('clock').textContent=clock(t.position,true);
  $('bpm').firstChild.textContent=String(Math.round(t.bpm??state.song?.bpm??120))+' ';$('meter').textContent=`${t.beats??4}/${t.unit??4}`;
  const part=state.song?.parts?.find(p=>p.id===(t.regionID??t.selectedRegionID));$('region-name').textContent=part?.name??'—';$('region-time').textContent=clock(Math.max(0,(t.position??0)-(part?.startTime??0)));
  if(state.follow&&t.playing){const x=((t.position??0)-state.offset)*state.scale;if(x>$('grid').clientWidth*.85||x<0)setOffset((t.position??0)-$('grid').clientWidth*.15/state.scale);}
  updateCursors();renderSetlistSelection();
}
function updateMeters(meters){
  if(!meters)return;const entries=Array.isArray(meters)?meters:Object.entries(meters).map(([trackID,data])=>({trackID,...data}));
  for(const entry of entries){const id=entry.trackID??entry.id??'',element=id?trackElements.get(id):$('master');if(!element)continue;
    if(id&&(element.offsetTop+element.offsetHeight<state.vertical||element.offsetTop>state.vertical+$('tracks').clientHeight))continue;
    const levels=entry.levels??[entry.left??0,entry.right??0];element.querySelectorAll('.track-meters i,.master-meter i').forEach((bar,index)=>bar.style.setProperty('--level',`${meterFraction(levels[index]??levels[0])*100}%`));
    const peak=element.querySelector('.peak'),amplitude=entry.peak??entry.heldPeak??0;peak.textContent=amplitude>0?gainLabel(amplitude,2):'';peak.classList.toggle('clip',amplitude>=1);
  }
}

for(const [id,action]of [['open','open'],['save','save'],['undo','undo'],['redo','redo'],['play','play'],['pause','pause'],['stop','stop']])$(id).onclick=()=>{if(action==='play')state.follow=true;send(action);};
$('add-track').onclick=()=>send('addTrack',{name:'Audio'});
for(const [id,className]of [['track-toggle','track-hidden'],['setlist-toggle','setlist-hidden']])$(id).onclick=()=>{document.body.classList.toggle(className);resize();};
const divider=$('track-divider');let dividerDrag=false;
divider.onpointerdown=e=>{if(e.button!==0)return;e.preventDefault();dividerDrag=true;divider.setPointerCapture(e.pointerId);};
divider.onpointermove=e=>{if(!dividerDrag)return;document.documentElement.style.setProperty('--track-width',`${clamp(e.clientX-34,240,Math.min(700,innerWidth-400))}px`);resize();};
divider.onpointerup=()=>{dividerDrag=false;};divider.onpointercancel=()=>{dividerDrag=false;};

$('grid').addEventListener('wheel',event=>{
  event.preventDefault();state.follow=false;
  if(event.shiftKey||Math.abs(event.deltaX)>Math.abs(event.deltaY)){setOffset(state.offset+(event.deltaX||event.deltaY)/state.scale);return;}
  const x=event.clientX-$('grid').getBoundingClientRect().left,next=zoomAt({scale:state.scale,offset:state.offset,x,delta:event.deltaY,width:$('grid').clientWidth,duration:state.song?.duration??60});
  state.scale=next.scale;resize();setOffset(next.offset);
},{passive:false});
let pressedItem=null;
$('grid').onpointerdown=event=>{
  if(event.button!==0)return;state.follow=false;const rect=$('grid').getBoundingClientRect(),x=event.clientX-rect.left,y=event.clientY-rect.top;
  const item=state.hitItems?.findLast(r=>x>=r.x&&x<r.x+r.w&&y>=r.y&&y<r.y+r.h);
  if(!item){state.items.clear();send('seek',{seconds:Math.max(0,state.offset+x/state.scale)});pressedItem=null;}
  else if(event.ctrlKey||event.metaKey){state.items.has(item.clip.id)?state.items.delete(item.clip.id):state.items.add(item.clip.id);pressedItem=null;}
  else if(!state.items.has(item.clip.id)){state.items=new Set([item.clip.id]);pressedItem=null;}else pressedItem={id:item.clip.id,x:event.clientX,y:event.clientY};
  draw();
};
$('grid').onpointerup=event=>{if(pressedItem&&Math.hypot(event.clientX-pressedItem.x,event.clientY-pressedItem.y)<4){state.items=new Set([pressedItem.id]);draw();}pressedItem=null;};
$('ruler').onpointerdown=event=>{if(event.button!==0)return;state.follow=false;send('seek',{seconds:Math.max(0,state.offset+(event.clientX-$('ruler').getBoundingClientRect().left)/state.scale)});};

const selection=new SelectionRouter(document,()=>Boolean($('message').open||$('account-dialog').open));
selection.register($('grid'),()=>{state.items=new Set((state.song?.tracks??[]).flatMap(t=>(t.clips??[]).map(c=>c.id)));draw();return true;},{scope:'grid'});
selection.register($('tracks'),()=>{state.tracks=new Set(state.rows.map(r=>r.track.id));updateSelections();return true;},{scope:'tracks'});
selection.register($('setlist'),()=>{state.regions=new Set(playlistRows(state.project,state.song).rows.map(r=>r.entryID));renderSetlistSelection();return true;},{scope:'setlist'});
document.addEventListener('keydown',event=>{
  if(event.defaultPrevented||event.isComposing||isTextInput(event.target)||$('message').open||$('account-dialog').open||isContextMenuOpen())return;
  if(event.code==='Space'&&!event.ctrlKey&&!event.metaKey&&!event.altKey&&!event.shiftKey){event.preventDefault();if(!event.repeat)send('togglePlay');return;}
  if((event.ctrlKey||event.metaKey)&&!event.altKey){
    const actions={KeyS:'save',KeyO:'open',KeyZ:event.shiftKey?'redo':'undo',KeyY:'redo'};
    if(actions[event.code]){event.preventDefault();if(!event.repeat)send(actions[event.code]);}
  }
  if(event.altKey&&!event.ctrlKey&&!event.metaKey){if(event.code==='KeyT'){$('track-toggle').click();event.preventDefault();}if(event.code==='KeyS'){$('setlist-toggle').click();event.preventDefault();}}
},true);
window.addEventListener('blur',()=>{finishSliderGesture?.();pressedItem=null;closePlaylist();});
document.addEventListener('contextmenu',event=>event.preventDefault());
document.fonts.ready.then(draw);
request('snapshot').catch(error=>notice(error.message));
