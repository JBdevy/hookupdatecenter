// Native FX editor for the desktop WebView host. Audio stays in NativeFX;
// this module only edits documents and displays the actual analyzer frames.
const clamp = (v, a, b) => Math.max(a, Math.min(b, Number(v) || 0));
const copy = value => structuredClone(value);
const kinds = Object.freeze(['EQ', 'Compressor', 'Delay', 'Reverb', 'Limiter', 'Pitch', 'Cat Gate', 'CatLive Trigger']);
const enabledKeys = {EQ:'eqEnabled',Compressor:'compressorEnabled',Delay:'delayEnabled',Reverb:'reverbEnabled',Limiter:'limiterEnabled',Pitch:'pitchEnabled','Cat Gate':'gateEnabled','CatLive Trigger':'triggerEnabled'};
const bandColors = ['#d99cff','#62ceee','#75dc8b','#f2cc64','#f59c86','#b3a2fb','#8bddd3','#e98db9','#c9d67d','#a3bedf'];
const id = () => crypto.randomUUID();
let activeEditor = null;

export function effectDefaults(kind) {
  const value = {inserted:[],bands:[],eqEnabled:false,compressorEnabled:false,delayEnabled:false,reverbEnabled:false,
    threshold:-20,ratio:4,attack:.005,release:.1,makeup:0,delayTime:.25,feedback:25,delayMix:20,reverbRoom:1,reverbMix:20,
    reverbDecay:2,reverbLowCut:80,reverbHighCut:12000,pitchSemitones:0,limiter:{inputGain:0,ceiling:-.1,release:.1},
    gate:{threshold:-40,attack:.001,decay:.02,hold:.05,release:.1,highPass:20,lowPass:20000,filterOutput:false},
    trigger:{threshold:-30,retrigger:.08,gain:0,mix:100,attack:0,decay:.1,sustain:1,release:.02}};
  if (kind === 'EQ') value.bands = [30,200,1000,5000,18000].map((frequency,i)=>({id:id(),frequency,gain:0,q:.707,type:i===0?'lowCut':i===4?'highCut':'bell',slope:12,enabled:true}));
  if (enabledKeys[kind]) value[enabledKeys[kind]] = true;
  return value;
}
export function effectEntry(settings, key) {
  const instance = settings.instances?.find(entry => key === `Native:${entry.id}` || key === `Instance:${entry.id}`);
  if (instance) return {key, kind:instance.kind, value:instance.settings};
  if (key?.startsWith('External:')) {
    const external = settings.externalPlugins?.find(entry=>`External:${entry.id}`===key);
    return {key,kind:'External',name:external?.name??key,value:external??{}};
  }
  return {key,kind:key,value:settings};
}
export function insertNativeEffect(settings, kind) {
  if (!kinds.includes(kind)) throw new Error('Unsupported native effect.');
  const instance = {id:id(),kind,settings:effectDefaults(kind)};
  (settings.instances??=[]).push(instance);
  const key=`Native:${instance.id}`; (settings.inserted??=[]).push(key); return key;
}

// Digital biquad response, using the same Q, Butterworth order and gain
// convention as NativeFX::parameterPreview. This is a response curve only;
// the input/output spectrum always comes from the backend's PCM analyzer.
export function equalizerResponse(bands, frequency, sampleRate = 48000) {
  const rate=Math.max(1000,sampleRate), w=2*Math.PI*clamp(frequency,1,rate*.499)/rate;
  let response=0;
  const magnitude = c => {
    const real=(v,offset)=>v[offset]+v[offset+1]*Math.cos(w)+v[offset+2]*Math.cos(2*w);
    const imag=(v,offset)=>-v[offset+1]*Math.sin(w)-v[offset+2]*Math.sin(2*w);
    return 10*Math.log10(Math.max(1e-24,(real(c,0)**2+imag(c,0)**2)/(real(c,3)**2+imag(c,3)**2)));
  };
  for(const band of bands??[]) {
    if(band.enabled===false)continue;
    const f=clamp(band.frequency??1000,20,Math.min(20000,rate*.45)),q=clamp(band.q??.707,.1,18);
    const omega=2*Math.PI*f/rate,cs=Math.cos(omega),sn=Math.sin(omega),A=10**(clamp(band.gain??0,-24,24)/40);
    const cut=band.type==='lowCut'||band.type==='highCut',order=cut?clamp(Math.trunc((band.slope??12)/6),1,32):2;
    for(let stage=0;stage<Math.max(1,Math.floor(order/2));stage++) {
      let c;
      if(cut&&order===1) {
        const k=Math.tan(Math.PI*f/rate), b=(band.type==='lowCut'?1:k)/(1+k);
        c=[b,band.type==='lowCut'?-b:b,0,1,(k-1)/(k+1),0];
      } else if(cut) {
        const Q=1/(2*Math.sin(Math.PI*(2*stage+1)/(2*order))),a=sn/(2*Q);
        c=band.type==='lowCut'?[(1+cs)/2,-1-cs,(1+cs)/2,1+a,-2*cs,1-a]:[(1-cs)/2,1-cs,(1-cs)/2,1+a,-2*cs,1-a];
      } else {
        const a=sn/(2*q),b=2*Math.sqrt(A)*a;
        if(band.type==='lowShelf') c=[A*((A+1)-(A-1)*cs+b),2*A*((A-1)-(A+1)*cs),A*((A+1)-(A-1)*cs-b),(A+1)+(A-1)*cs+b,-2*((A-1)+(A+1)*cs),(A+1)+(A-1)*cs-b];
        else if(band.type==='highShelf')c=[A*((A+1)+(A-1)*cs+b),-2*A*((A-1)+(A+1)*cs),A*((A+1)+(A-1)*cs-b),(A+1)-(A-1)*cs+b,2*((A-1)-(A+1)*cs),(A+1)-(A-1)*cs-b];
        else c=[1+a*A,-2*cs,1-a*A,1+a/A,-2*cs,1-a/A];
      }
      response+=magnitude(c);
    }
  }
  return response;
}

const control = (label,path,min,max,step=1,unit='',scale=1,log=false)=>({label,path,min,max,step,unit,scale,log});
const controls = {
  Compressor:[control('Threshold','threshold',-60,0,.1,'dB'),control('Ratio','ratio',1,20,.1,':1'),control('Gain','makeup',-12,24,.1,'dB'),control('Attack','attack',.1,200,.1,'ms',1000,true),control('Release','release',10,3000,1,'ms',1000,true)],
  Delay:[control('Time','delayTime',10,2000,1,'ms',1000,true),control('Feedback','feedback',0,90,.1,'%'),control('Mix','delayMix',0,100,.1,'%')],
  Reverb:[control('Mix','reverbMix',0,100,.1,'%'),control('Decay','reverbDecay',.1,20,.1,'s',1,true),control('Low Cut','reverbLowCut',20,2000,1,'Hz',1,true),control('High Cut','reverbHighCut',2000,20000,1,'Hz',1,true)],
  Limiter:[control('Input Gain','limiter.inputGain',-24,24,.1,'dB'),control('Ceiling','limiter.ceiling',-24,0,.1,'dB'),control('Release','limiter.release',10,3000,1,'ms',1000,true)],
  Pitch:[control('Semitones','pitchSemitones',-12,12,1,'st')],
  'Cat Gate':[control('Threshold','gate.threshold',-80,0,.1,'dB'),control('Attack','gate.attack',0,2000,.1,'ms',1000),control('Decay','gate.decay',0,2000,1,'ms',1000),control('Hold','gate.hold',0,2000,1,'ms',1000),control('Release','gate.release',0,5000,1,'ms',1000),control('High Pass','gate.highPass',20,20000,1,'Hz',1,true),control('Low Pass','gate.lowPass',20,20000,1,'Hz',1,true)],
  'CatLive Trigger':[control('Threshold','trigger.threshold',-80,0,.1,'dB'),control('Retrigger','trigger.retrigger',5,2000,1,'ms',1000,true),control('Gain','trigger.gain',-24,24,.1,'dB'),control('Mix','trigger.mix',0,100,.1,'%'),control('Attack','trigger.attack',0,10000,1,'ms',1000),control('Decay','trigger.decay',0,10000,1,'ms',1000),control('Sustain','trigger.sustain',0,100,.1,'%',100),control('Release','trigger.release',0,20000,1,'ms',1000)],
};
const readPath=(value,path)=>path.split('.').reduce((v,key)=>v?.[key],value);
function writePath(value,path,number) {const keys=path.split('.');for(const key of keys.slice(0,-1))value=value[key]??={};value[keys.at(-1)]=number;}

export function closeEffects(options){activeEditor?.close(options);}
export function openEffects({trackID='',settings={},request,language='en',name='',projectID}={}) {
  if(typeof request!=='function')throw new TypeError('A native FX bridge is required.');
  closeEffects();
  if(!document.querySelector('link[data-effects-style]')) {const link=document.createElement('link');link.rel='stylesheet';link.href=new URL('./app-effects.css',import.meta.url).href;link.dataset.effectsStyle='true';document.head.append(link);}
  const tr=(pt,en)=>language.startsWith('pt')?pt:en;
  const make=(tag,className,text)=>{const e=document.createElement(tag);if(className)e.className=className;if(text!==undefined)e.textContent=text;return e;};
  const panel=make('section','catlive-fx');panel.setAttribute('role','dialog');panel.setAttribute('aria-modal','false');panel.setAttribute('aria-label',`FX ${name||'Master'}`);panel.tabIndex=-1;
  const heading=make('header','fx-heading'),title=make('strong','',`FX · ${name||(trackID?tr('Pista','Track'):'Master')}`),close=make('button','fx-close','×');close.type='button';close.setAttribute('aria-label',tr('Fechar efeitos','Close effects'));heading.append(title,close);
  const layout=make('div','fx-layout'),aside=make('aside','fx-chain'),chainList=make('div','fx-chain-list'),chainTools=make('div','fx-chain-tools'),add=make('select','fx-add');add.setAttribute('aria-label',tr('Adicionar efeito','Add effect'));
  const option=make('option','',tr('+ Adicionar efeito','+ Add effect'));option.value='';add.append(option);
  for(const kind of kinds){const item=make('option','',kind);item.value=kind;add.append(item);}
  chainTools.append(add);aside.append(chainList,chainTools);
  const editor=make('main','fx-editor'),error=make('p','fx-error');error.setAttribute('role','alert');error.hidden=true;
  layout.append(aside,editor);panel.append(heading,layout,error);document.body.append(panel);
  let chain=copy(settings??{}),verified=copy(chain),selected=(chain.inserted??[])[0]??null,bandIndex=0,sampleRate=48000,closed=false,loading=true,previewFrame=0,dirty=false,editSerial=0,commitPromise=Promise.resolve(),pendingCommits=0;
  let canvas=null,graphContext=null,graphObserver=null,rta=null,rtaKey=null,rtaBusy=false,rtaTimer=0,drawFrame=0,graphDrag=null,controlGesture=null,refreshFields=()=>{};
  const finishControl=()=>{const finish=controlGesture;controlGesture=null;finish?.();};
  window.addEventListener('pointerup',finishControl);window.addEventListener('pointercancel',finishControl);
  const report=failure=>{if(closed)return;error.textContent=failure instanceof Error?failure.message:String(failure);error.hidden=false;};
  const call=(action,payload={})=>request(action,{trackID,...payload,...(projectID?{projectID}:{})});
  const entry=()=>selected?effectEntry(chain,selected):null;
  const setDirty=()=>{dirty=true;editSerial++;error.hidden=true;};
  function previewNow() {
    cancelAnimationFrame(previewFrame);previewFrame=0;
    const current=entry();if(closed||loading||!current||!enabledKeys[current.kind])return;
    call('effectsPreview',{key:current.key,kind:current.kind,settings:copy(current.value),chainSettings:copy(chain)}).catch(report);
  }
  function preview(){setDirty();if(!previewFrame)previewFrame=requestAnimationFrame(previewNow);scheduleDraw();}
  function commit(){
    if(closed||loading||!dirty)return commitPromise;
    if(previewFrame)previewNow();
    dirty=false;const snapshot=copy(chain),version=editSerial;pendingCommits++;
    commitPromise=commitPromise.catch(()=>{}).then(()=>call('effectsCommit',{settings:snapshot})).then(()=>{verified=copy(snapshot);}).catch(failure=>{
      if(version===editSerial&&!closed){chain=copy(verified);render();previewNow();}report(failure);
    }).finally(()=>pendingCommits--);
    return commitPromise;
  }
  const button=(label,callback,className='')=>{const b=make('button',className,label);b.type='button';b.onclick=callback;return b;};
  function stopAnalysis(){
    clearTimeout(rtaTimer);rtaTimer=0;const key=rtaKey;rtaKey=null;rta=null;
    if(key)call('effectsRTA',{key,enabled:false}).catch(()=>{});
  }
  async function tickAnalysis(){
    if(closed||!rtaKey)return;
    if(document.hidden||rtaBusy){rtaTimer=setTimeout(tickAnalysis,100);return;}
    const key=rtaKey;rtaBusy=true;
    try{const frame=await call('effectsRTA',{key,enabled:true});if(!closed&&rtaKey===key){rta=frame;if(frame.sampleRate>0)sampleRate=frame.sampleRate;scheduleDraw();}}
    catch(failure){if(rtaKey===key)report(failure);}
    finally{rtaBusy=false;if(!closed&&rtaKey)rtaTimer=setTimeout(tickAnalysis,50);}
  }
  function analysis(key){if(rtaKey===key)return;stopAnalysis();if(key){rtaKey=key;tickAnalysis();}}
  function choose(key){commit();selected=key;bandIndex=0;render();}
  function renderChain(){
    chainList.replaceChildren();
    for(const key of chain.inserted??[]){const current=effectEntry(chain,key),row=button(current.name??current.kind,()=>choose(key),'fx-insert');row.dataset.key=key;row.classList.toggle('selected',key===selected);row.setAttribute('aria-pressed',String(key===selected));
      const enabled=enabledKeys[current.kind]?current.value[enabledKeys[current.kind]]:current.kind==='External'?!current.value.bypassed:true;row.classList.toggle('bypassed',enabled===false);chainList.append(row);}
  }
  function bindControl(parent,spec,value,getObject=()=>entry()?.value){
    const row=make('label','fx-parameter'),label=make('span','',spec.label),slider=make('input','fx-range'),number=make('input','fx-number'),unit=make('span','fx-unit',spec.unit);
    slider.type='range';slider.min=spec.log?0:spec.min;slider.max=spec.log?1:spec.max;slider.step=spec.log?.001:spec.step;slider.setAttribute('aria-label',spec.label);slider.dataset.parameter=spec.path;
    number.type='number';number.min=spec.min;number.max=spec.max;number.step=spec.step;number.setAttribute('aria-label',`${spec.label} ${spec.unit}`);
    const slide=value=>spec.log?Math.log(Math.max(spec.min,value)/spec.min)/Math.log(spec.max/spec.min):value;
    const actual=value=>spec.log?spec.min*(spec.max/spec.min)**value:value;
    const refresh=()=>{const v=Number(readPath(getObject(),spec.path)??value)*spec.scale;slider.value=slide(v);number.value=Number(v.toFixed(spec.step<1?2:0));};
    const update=raw=>{let v=clamp(raw,spec.min,spec.max)/spec.scale;const object=getObject();if(!object)return;
      if(spec.path==='gate.highPass')v=Math.min(v,object.gate.lowPass);if(spec.path==='gate.lowPass')v=Math.max(v,object.gate.highPass);
      writePath(object,spec.path,v);refresh();preview();};
    let held=false;
    // Chromium captures its internal range thumb. Capturing the outer input
    // would steal that capture and end the native drag on its first movement.
    slider.onpointerdown=event=>{if(event.button===0){held=true;controlGesture=finish;}};
    const finish=()=>{if(!held)return;held=false;commit();};
    slider.onpointerup=slider.onpointercancel=finish;
    slider.oninput=()=>update(actual(Number(slider.value)));slider.onchange=()=>{if(!held)commit();};slider.onblur=()=>{held=false;commit();};
    number.oninput=()=>{if(number.value!==''&&number.validity.valid)update(Number(number.value));};number.onchange=()=>{if(number.value!==''&&Number.isFinite(number.valueAsNumber))update(number.valueAsNumber);else refresh();commit();};number.onblur=()=>{refresh();commit();};
    row.append(label,slider,number,unit);parent.append(row);refresh();return refresh;
  }
  function optionSelect(parent,label,options,value,changed){
    const row=make('label','fx-choice'),name=make('span','',label),select=make('select');select.setAttribute('aria-label',label);
    for(const [key,text]of options){const option=make('option','',text);option.value=key;select.append(option);}select.value=value;
    select.onchange=()=>{changed(select.value);preview();commit();};row.append(name,select);parent.append(row);return select;
  }
  function render(){
    graphObserver?.disconnect();graphObserver=null;canvas=null;graphContext=null;refreshFields=()=>{};editor.replaceChildren();renderChain();add.disabled=loading;
    if(loading){editor.append(make('p','fx-empty',tr('Carregando efeitos…','Loading effects…')));analysis(null);return;}
    const current=entry();if(!current){editor.append(make('p','fx-empty',tr('Adicione um efeito à pista.','Add an effect to this track.')));analysis(null);return;}
    const toolbar=make('div','fx-toolbar'),label=make('strong','',current.name??current.kind),enabled=make('input');enabled.type='checkbox';enabled.setAttribute('aria-label',tr('Ativado','Enabled'));
    const enableField=enabledKeys[current.kind];
    if(enableField){enabled.checked=Boolean(current.value[enableField]);enabled.onchange=()=>{current.value[enableField]=enabled.checked;setDirty();commit();renderChain();};toolbar.append(enabled);}
    toolbar.append(label);
    const move=(direction)=>{const index=chain.inserted.indexOf(selected),to=index+direction;if(to<0||to>=chain.inserted.length)return;[chain.inserted[index],chain.inserted[to]]=[chain.inserted[to],chain.inserted[index]];setDirty();commit();renderChain();};
    const up=button('↑',()=>move(-1)),down=button('↓',()=>move(1)),remove=button(tr('Remover','Remove'),()=>{
      const at=chain.inserted.indexOf(selected);chain.inserted.splice(at,1);
      chain.instances=chain.instances?.filter(item=>selected!==`Native:${item.id}`&&selected!==`Instance:${item.id}`);
      if(current.kind==='External')chain.externalPlugins=chain.externalPlugins?.filter(item=>selected!==`External:${item.id}`);
      if(current.kind==='CatLive Trigger'&&current.value===chain)delete chain.trigger;
      selected=chain.inserted[Math.min(at,chain.inserted.length-1)]??null;setDirty();commit();render();
    });up.setAttribute('aria-label',tr('Mover efeito para cima','Move effect up'));down.setAttribute('aria-label',tr('Mover efeito para baixo','Move effect down'));
    up.disabled=chain.inserted.indexOf(selected)===0;down.disabled=chain.inserted.indexOf(selected)===chain.inserted.length-1;toolbar.append(up,down,remove);editor.append(toolbar);
    if(current.kind==='EQ'){buildEQ(current.value);analysis(current.key);return;}analysis(null);
    if(!controls[current.kind]){editor.append(make('p','fx-empty',tr('O editor deste efeito ainda não está disponível nesta interface. O processamento atual foi preservado.','This effect editor is not available in this interface yet. Its current processing is preserved.')));return;}
    if(current.kind==='Cat Gate')editor.append(make('p','fx-explanation',tr('High Pass e Low Pass filtram somente a detecção.','High Pass and Low Pass filter only the detector.')));
    if(current.kind==='Reverb')optionSelect(editor,'Room',[[0,'Small'],[1,'Medium'],[2,'Large']],current.value.reverbRoom??1,value=>current.value.reverbRoom=Number(value));
    if(current.kind==='CatLive Trigger'){
      const sampleRow=make('div','fx-sample'),sample=make('span','',current.value.trigger?.samplePath?.split(/[\\/]/).at(-1)||tr('Nenhum sample carregado','No sample loaded'));
      const load=button(tr('Carregar sample','Load sample'),async()=>{load.disabled=true;try{await commit();const result=await call('effectsChooseSample',{key:current.key});if(result?.settings&&!closed){chain=copy(result.settings);verified=copy(chain);render();}}catch(failure){report(failure);}finally{load.disabled=false;}});sampleRow.append(load,sample);editor.append(sampleRow);
    }
    const parameters=make('div','fx-parameters');for(const spec of controls[current.kind])bindControl(parameters,spec,readPath(effectDefaults(current.kind),spec.path));editor.append(parameters);
  }
  function buildEQ(value){
    const graph=make('div','fx-eq-graph');canvas=make('canvas');canvas.setAttribute('aria-label',tr('Resposta do equalizador e espectro de entrada e saída','Equalizer response and input/output spectrum'));graph.append(canvas);editor.append(graph);graphContext=canvas.getContext('2d');
    const legend=make('div','fx-rta-legend');legend.append(make('span','fx-input','RTA INPUT'),make('span','fx-output','OUTPUT'));editor.append(legend);
    const bandRow=make('div','fx-bands');
    for(const [i,band]of (value.bands??[]).entries()) {const b=button(String(i+1),()=>{bandIndex=i;render();},'fx-band');b.style.setProperty('--band',bandColors[i%bandColors.length]);b.classList.toggle('selected',i===bandIndex);b.classList.toggle('bypassed',band.enabled===false);bandRow.append(b);}
    const more=button('+',()=>{if((value.bands?.length??0)>=10)return;(value.bands??=[]).push({id:id(),frequency:1000,gain:0,q:.707,type:'bell',slope:12,enabled:true});bandIndex=value.bands.length-1;setDirty();commit();render();});more.setAttribute('aria-label',tr('Adicionar banda','Add band'));more.disabled=(value.bands?.length??0)>=10;bandRow.append(more);editor.append(bandRow);
    bandIndex=Math.max(0,Math.min(bandIndex,(value.bands?.length??1)-1));const band=value.bands?.[bandIndex];
    if(band){
      const choices=make('div','fx-band-options'),on=make('label','fx-band-enable'),toggle=make('input');toggle.type='checkbox';toggle.checked=band.enabled!==false;toggle.onchange=()=>{band.enabled=toggle.checked;preview();commit();render();};on.append(toggle,document.createTextNode(tr('Banda ativada','Band enabled')));choices.append(on);
      optionSelect(choices,tr('Tipo','Type'),[['lowCut','Low Cut'],['lowShelf','Low Shelf'],['bell','Bell'],['highShelf','High Shelf'],['highCut','High Cut']],band.type??'bell',value=>{band.type=value;render();});
      if(band.type==='lowCut'||band.type==='highCut')optionSelect(choices,tr('Inclinação','Slope'),[6,12,18,24,36,48,60,72,84,96].map(n=>[n,`${n} dB/oct`]),band.slope??12,n=>band.slope=Number(n));
      choices.append(button(tr('Remover banda','Remove band'),()=>{value.bands.splice(bandIndex,1);setDirty();commit();render();}));editor.append(choices);
      const parameters=make('div','fx-parameters fx-eq-parameters'),refresh=[];
      for(const spec of [control('Frequency','frequency',20,Math.min(20000,sampleRate*.45),1,'Hz',1,true),control('Gain','gain',-24,24,.1,'dB'),control('Q','q',.1,18,.01,'',1,true)]) {
        if(spec.path==='gain'&&(band.type==='lowCut'||band.type==='highCut'))continue;
        refresh.push(bindControl(parameters,spec,readPath(band,spec.path),()=>band));
      }editor.append(parameters);refreshFields=()=>refresh.forEach(fn=>fn());
    }
    canvas.onpointerdown=event=>{
      if(event.button!==0)return;const p=point(event),rect=plot();let closest=-1,distance=20;
      (value.bands??[]).forEach((band,index)=>{const d=Math.hypot(freqX(band.frequency,rect)-p.x,gainY(isCut(band)?0:band.gain??0,rect)-p.y);if(d<distance){closest=index;distance=d;}});
      if(closest<0)return;
      event.preventDefault();
      // Select before acquiring capture so the numerical controls and the
      // dragged node always edit the same band, including after a node switch.
      if(bandIndex!==closest){bandIndex=closest;render();}
      graphDrag={id:event.pointerId,index:closest};canvas.setPointerCapture(event.pointerId);scheduleDraw();
    };
    canvas.onpointermove=event=>{
      if(!graphDrag||graphDrag.id!==event.pointerId)return;const p=point(event),rect=plot(),band=value.bands[graphDrag.index];
      band.frequency=clamp(20*(maxFrequency()/20)**clamp((p.x-rect.x)/rect.w,0,1),20,maxFrequency());if(!isCut(band))band.gain=clamp(24-(p.y-rect.y)/rect.h*48,-24,24);
      preview();if(graphDrag.index===bandIndex)refreshFields();
    };
    const finish=()=>{if(!graphDrag)return;graphDrag=null;commit();render();};canvas.onpointerup=finish;canvas.onpointercancel=finish;canvas.onlostpointercapture=finish;
    canvas.onwheel=event=>{event.preventDefault();const band=value.bands?.[bandIndex];if(!band)return;band.q=clamp((band.q??.707)*Math.exp(-event.deltaY*.002),.1,18);preview();refreshFields();clearTimeout(canvas.qCommit);canvas.qCommit=setTimeout(commit,150);};
    graphObserver=new ResizeObserver(scheduleDraw);graphObserver.observe(graph);scheduleDraw();
  }
  const isCut=band=>band.type==='lowCut'||band.type==='highCut';
  const maxFrequency=()=>Math.min(20000,sampleRate*.45);
  const point=event=>{const r=canvas.getBoundingClientRect();return{x:event.clientX-r.left,y:event.clientY-r.top};};
  const plot=()=>({x:42,y:14,w:Math.max(10,canvas.clientWidth-58),h:Math.max(10,canvas.clientHeight-42)});
  const freqX=(f,r)=>r.x+clamp(Math.log(Math.max(20,f)/20)/Math.log(maxFrequency()/20),0,1)*r.w;
  const gainY=(gain,r)=>r.y+(24-clamp(gain,-24,24))/48*r.h;
  function scheduleDraw(){if(!drawFrame&&!closed)drawFrame=requestAnimationFrame(()=>{drawFrame=0;draw();});}
  function draw(){
    if(!canvas||!graphContext||closed)return;const c=graphContext,r=plot(),w=canvas.clientWidth,h=canvas.clientHeight,dpr=Math.min(2,devicePixelRatio||1);
    if(canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);}c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);c.fillStyle='#101010';c.fillRect(0,0,w,h);c.font='11px Inter,system-ui';c.lineWidth=1;
    for(const db of [-24,-12,0,12,24]){const y=gainY(db,r);c.strokeStyle=db===0?'#575757':'#2c2c2c';c.beginPath();c.moveTo(r.x,y);c.lineTo(r.x+r.w,y);c.stroke();c.fillStyle='#a5a5a5';c.fillText(`${db>0?'+':''}${db}`,5,y+4);}
    for(const f of [20,50,100,200,500,1000,2000,5000,10000,20000]){if(f>maxFrequency())continue;const x=freqX(f,r);c.strokeStyle='#2a2a2a';c.beginPath();c.moveTo(x,r.y);c.lineTo(x,r.y+r.h);c.stroke();c.fillStyle='#aaa';c.fillText(f>=1000?`${f/1000}k`:f,x-8,h-7);}
    c.save();c.beginPath();c.rect(r.x,r.y,r.w,r.h);c.clip();
    for(const [field,stroke,fill]of [['input','#aeb3b7','#ffffff08'],['output','#68d18b','#50c87817']]) {
      const values=rta?.ready?rta[field]:null;if(!Array.isArray(values)||values.length<2)continue;c.beginPath();
      values.forEach((db,i)=>{const f=(rta.minFrequency??20)*((rta.maxFrequency??maxFrequency())/(rta.minFrequency??20))**(i/(values.length-1)),x=freqX(f,r),y=r.y+(1-clamp((Number(db)+96)/96,0,1))*r.h;i===0?c.moveTo(x,y):c.lineTo(x,y);});
      c.strokeStyle=stroke;c.lineWidth=1.1;c.stroke();c.lineTo(r.x+r.w,r.y+r.h);c.lineTo(r.x,r.y+r.h);c.closePath();c.fillStyle=fill;c.fill();
    }
    const bands=entry()?.value.bands??[];c.beginPath();for(let x=0;x<=r.w;x+=2){const f=20*(maxFrequency()/20)**(x/r.w),y=gainY(equalizerResponse(bands,f,sampleRate),r);x?c.lineTo(r.x+x,y):c.moveTo(r.x+x,y);}c.strokeStyle='#e7e7e7';c.lineWidth=1.75;c.stroke();
    bands.forEach((band,i)=>{const x=freqX(band.frequency,r),y=gainY(isCut(band)?0:band.gain??0,r);c.globalAlpha=band.enabled===false?.35:1;c.beginPath();c.arc(x,y,i===bandIndex?7:5,0,Math.PI*2);c.fillStyle=bandColors[i%bandColors.length];c.fill();if(i===bandIndex){c.lineWidth=1.4;c.strokeStyle='#fff';c.stroke();}c.globalAlpha=1;});c.restore();
  }
  add.onchange=()=>{if(!add.value||loading)return;commit();selected=insertNativeEffect(chain,add.value);add.value='';setDirty();commit();render();};
  let windowDrag=null;
  heading.onpointerdown=event=>{if(event.button!==0||event.target.closest('button'))return;const r=panel.getBoundingClientRect();windowDrag={x:event.clientX,y:event.clientY,left:r.left,top:r.top};heading.setPointerCapture(event.pointerId);event.preventDefault();};
  heading.onpointermove=event=>{if(!windowDrag)return;panel.style.left=`${clamp(windowDrag.left+event.clientX-windowDrag.x,0,innerWidth-100)}px`;panel.style.top=`${clamp(windowDrag.top+event.clientY-windowDrag.y,0,innerHeight-42)}px`;panel.style.transform='none';};
  heading.onpointerup=heading.onpointercancel=()=>windowDrag=null;
  panel.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();handle.close();}else if(event.key!==' ')event.stopPropagation();});
  const handle={element:panel,close(options={}){if(closed)return;if(options.discard){dirty=false;controlGesture=null;}else{finishControl();commit();}stopAnalysis();closed=true;cancelAnimationFrame(previewFrame);cancelAnimationFrame(drawFrame);graphObserver?.disconnect();window.removeEventListener('pointerup',finishControl);window.removeEventListener('pointercancel',finishControl);panel.remove();if(activeEditor===handle)activeEditor=null;},get pending(){return pendingCommits>0;}};
  close.onclick=handle.close;activeEditor=handle;render();panel.focus({preventScroll:true});
  call('effectsGet').then(result=>{if(closed)return;chain=copy(result.settings??{});verified=copy(chain);selected=chain.inserted?.includes(selected)?selected:chain.inserted?.[0]??null;sampleRate=result.sampleRate||48000;loading=false;render();}).catch(failure=>{loading=false;report(failure);add.disabled=true;});
  return handle;
}
