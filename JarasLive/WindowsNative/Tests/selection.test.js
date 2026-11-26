import test from 'node:test';
import assert from 'node:assert/strict';
import {SelectionRouter, isTextInput, timelineSelection, mixerSelection, visibleSelection, pianoRollSelection} from '../ui/selection.js';

class Events {
  listeners = new Map();
  addEventListener(type, listener) { if (!this.listeners.has(type)) this.listeners.set(type, new Set()); this.listeners.get(type).add(listener); }
  removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
  dispatch(type, event = {}) { for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event); }
}
function fixture() {
  const document = new Events(), window = new Events();
  document.defaultView = window; document.focused = true; document.hidden = false;
  document.hasFocus = () => document.focused;
  document.blockers = []; document.querySelectorAll = () => document.blockers;
  window.innerWidth = 1000; window.innerHeight = 800;
  window.getComputedStyle = node => node.style ?? {};
  const element = (name = 'div', bounds = [0, 0, 1000, 800], parent = null) => ({
    tagName: name.toUpperCase(), type: name === 'input' ? 'text' : undefined,
    ownerDocument: document, isConnected: true, parentElement: parent, hidden: false, style: {}, attributes: {},
    getAttribute(key) { return this.attributes[key] ?? null; },
    getClientRects() { return this.hidden ? [] : [this.getBoundingClientRect()]; },
    getBoundingClientRect() { const [left,top,width,height] = bounds; return {left,top,width,height,right:left+width,bottom:top+height}; },
  });
  document.body = element('body'); document.activeElement = document.body;
  const area = (bounds, parent) => element('div', bounds, parent ?? document.body);
  const pointer = (target, button = 0, extra = {}) => ({type: 'pointerdown', target, button,
    composedPath: () => { const nodes=[]; for (let node=target;node;node=node.parentElement)nodes.push(node);return nodes; }, ...extra});
  const key = (target = document.body, extra = {}) => ({type: 'keydown', target, key: 'a', ctrlKey: true,
    metaKey: false, altKey: false, shiftKey: false, defaultPrevented: false, propagationStopped: false,
    preventDefault() {this.defaultPrevented=true;}, stopPropagation() {this.propagationStopped=true;},
    composedPath: () => [target], ...extra});
  return {document,window,element,area,pointer,key};
}

test('last left or right clicked panel owns Ctrl+A independently of other selections', () => {
  const f=fixture(), calls=[]; const router=new SelectionRouter(f.document);
  try {
    const grid=f.area([200,0,500,700]), mixer=f.area([0,0,200,700]), setlist=f.area([700,0,300,700]);
    router.register(grid,()=>calls.push('grid'),{scope:'grid'});
    router.register(mixer,()=>calls.push('tracks'),{scope:'tracks'});
    router.register(setlist,()=>calls.push('setlist'),{scope:'setlist'});
    for(const [area,button] of [[grid,0],[mixer,2],[setlist,2]]) {
      f.document.dispatch('pointerdown',f.pointer(area,button));
      const event=f.key(); f.document.dispatch('keydown',event);
      assert.equal(event.defaultPrevented,true);assert.equal(event.propagationStopped,true);
    }
    assert.deepEqual(calls,['grid','tracks','setlist']);
    // A toolbar click retains the previous area's ownership, as on Mac.
    router.handlePointer(f.pointer(f.document.body,0,{clientX:900,clientY:750}));
    router.handleKey(f.key());assert.equal(calls.at(-1),'setlist');
  }finally{router.dispose();}
});

test('overlapping areas use Mac scope priority then smallest visible area',()=>{
  const f=fixture(), calls=[];const router=new SelectionRouter(f.document);
  try {
    const grid=f.area([0,0,800,700]), mixer=f.area([0,0,200,700],grid), nested=f.area([0,0,100,100],mixer);
    router.register(grid,()=>calls.push('grid'),{scope:'grid'});
    router.register(mixer,()=>calls.push('mixer'),{scope:'tracks'});
    router.register(nested,()=>calls.push('nested'),{scope:'tracks'});
    // Overlay route deliberately does not contain the registered roots.
    router.handlePointer(f.pointer(f.document.body,2,{clientX:50,clientY:50}));router.handleKey(f.key());
    assert.equal(calls.at(-1),'nested');
    const setlist=f.area([0,0,800,700]);router.register(setlist,()=>calls.push('setlist'),{scope:'setlist'});
    router.handlePointer(f.pointer(nested,2,{clientX:50,clientY:50}));router.handleKey(f.key());
    assert.equal(calls.at(-1),'setlist');
  }finally{router.dispose();}
});

test('native/canvas and DOM routes cannot invoke the same key twice; repeats are consumed',()=>{
  const f=fixture();let calls=0;const router=new SelectionRouter(f.document);
  try {
    const grid=f.area();router.register(grid,()=>{calls+=1;return true;});router.handlePointer(f.pointer(grid));
    const event=f.key();assert.equal(router.handleKey(event),true);f.document.dispatch('keydown',event);
    assert.equal(calls,1);assert.equal(router.handleKey(event),true);assert.equal(calls,1);
    const repeat=f.key(undefined,{repeat:true});assert.equal(router.handleKey(repeat),true);
    assert.equal(repeat.defaultPrevented,true);assert.equal(calls,1);
  }finally{router.dispose();}
});

test('empty application selection consumes browser Select All without inventing a selection',()=>{
  const f=fixture();let calls=0;const router=new SelectionRouter(f.document);
  try {
    const grid=f.area();router.register(grid,()=>{calls+=1;return false;});router.handlePointer(f.pointer(grid));
    const event=f.key();assert.equal(router.handleKey(event),true);assert.equal(event.defaultPrevented,true);assert.equal(calls,1);
    router.register(grid,()=>{throw new Error('application error');});
    const failed=f.key();assert.throws(()=>router.handleKey(failed),/application error/);assert.equal(failed.defaultPrevented,true);
  }finally{router.dispose();}
});

test('text fields, contenteditable, shadow editor and select controls retain their own selection',()=>{
  const f=fixture();let calls=0;const router=new SelectionRouter(f.document);
  try {
    const grid=f.area();router.register(grid,()=>{calls+=1;});router.handlePointer(f.pointer(grid));
    for(const name of ['input','textarea','select']) {
      const input=f.element(name);f.document.activeElement=input;
      const event=f.key(input);assert.equal(router.handleKey(event),false);assert.equal(event.defaultPrevented,false);
    }
    const editor=f.element();editor.isContentEditable=true;f.document.activeElement=editor;
    assert.equal(router.handleKey(f.key(editor)),false);
    const host=f.element();host.shadowRoot={activeElement:editor};f.document.activeElement=host;
    assert.equal(router.handleKey(f.key(host)),false);
    f.document.activeElement=f.document.body;
    const textbox=f.element();textbox.attributes.role='textbox';
    assert.equal(router.handleKey(f.key(textbox)),false);
    const retargeted=f.key(host,{composedPath:()=>[editor,host]});assert.equal(router.handleKey(retargeted),false);
    assert.equal(calls,0);
    for(const type of ['text','search','number','password','email'])assert.equal(isTextInput({...f.element('input'),type}),true);
    for(const type of ['checkbox','range','button'])assert.equal(isTextInput({...f.element('input'),type}),false);
  }finally{router.dispose();}
});

test('modal/menu/native gates prevent routing and preserve the last valid area',()=>{
  const f=fixture(), calls=[];let blocked=false;const router=new SelectionRouter(f.document,()=>blocked);
  try {
    const grid=f.area([0,0,500,700]), setlist=f.area([600,0,300,700]);
    router.register(grid,()=>calls.push('grid'));router.register(setlist,()=>calls.push('setlist'),{scope:'setlist'});
    router.handlePointer(f.pointer(grid));blocked=true;
    assert.equal(router.handlePointer(f.pointer(setlist,2)),false);assert.equal(router.handleKey(f.key()),false);
    blocked=false;const modal=f.element();f.document.blockers=[modal];
    assert.equal(router.handleKey(f.key()),false);assert.equal(router.handlePointer(f.pointer(setlist)),false);
    modal.hidden=true;router.handleKey(f.key());assert.deepEqual(calls,['grid']);
  }finally{router.dispose();}
});

test('inactive/foreign windows and hidden areas cannot receive selection commands',()=>{
  const f=fixture(), other=fixture();let calls=0;const router=new SelectionRouter(f.document);
  try {
    const ancestor=f.area(),grid=f.area([0,0,200,200],ancestor);router.register(grid,()=>{calls+=1;});router.handlePointer(f.pointer(grid));
    assert.equal(router.handleKey(f.key(other.document.body)),false);
    assert.equal(router.handleKey(f.key(undefined,{view:other.window})),false);
    f.window.dispatch('blur');assert.equal(router.handleKey(f.key()),false);f.window.dispatch('focus');
    f.document.focused=false;assert.equal(router.handleKey(f.key()),false);f.document.focused=true;
    f.document.hidden=true;assert.equal(router.handleKey(f.key()),false);f.document.hidden=false;
    ancestor.hidden=true;assert.equal(router.handleKey(f.key()),false);ancestor.hidden=false;
    ancestor.inert=true;assert.equal(router.handleKey(f.key()),false);ancestor.inert=false;
    ancestor.style.visibility='hidden';assert.equal(router.handleKey(f.key()),false);ancestor.style.visibility='visible';
    grid.isConnected=false;assert.equal(router.handleKey(f.key()),false);grid.isConnected=true;
    assert.equal(router.handleKey(f.key()),true);assert.equal(calls,1);
    assert.throws(()=>router.register(other.area(),()=>true),/this window/);
  }finally{router.dispose();}
});

test('scroll clipping prevents an invisible region from taking pointer ownership',()=>{
  const f=fixture(),calls=[];const router=new SelectionRouter(f.document);
  try {
    const grid=f.area([0,0,500,500]),clip=f.area([0,0,100,100]),hiddenRegion=f.area([0,0,400,400],clip);
    clip.style.overflow='hidden';router.register(grid,()=>calls.push('grid'));router.register(hiddenRegion,()=>calls.push('tracks'),{scope:'tracks'});
    router.handlePointer(f.pointer(f.document.body,0,{clientX:150,clientY:150}));router.handleKey(f.key());
    assert.deepEqual(calls,['grid']);
  }finally{router.dispose();}
});

test('exact Ctrl+A or Meta+A only, excluding composition, modified chords and keyup',()=>{
  const f=fixture();let calls=0;const router=new SelectionRouter(f.document);
  try {
    const grid=f.area();router.register(grid,()=>{calls+=1;});router.handlePointer(f.pointer(grid));
    for(const extra of [{shiftKey:true},{altKey:true},{metaKey:true},{ctrlKey:false},{isComposing:true},{defaultPrevented:true},{type:'keyup'},{key:'s'}])
      assert.equal(router.handleKey(f.key(undefined,extra)),false);
    assert.equal(router.handleKey(f.key(undefined,{ctrlKey:false,metaKey:true,key:'A'})),true);assert.equal(calls,1);
  }finally{router.dispose();}
});

test('registrations replace safely, detach, dispose, and stay isolated per window',()=>{
  const f=fixture(),other=fixture(),calls=[];const router=new SelectionRouter(f.document),second=new SelectionRouter(other.document);
  try {
    const first=f.area(),otherArea=other.area();const stale=router.register(first,()=>calls.push('old'));
    const remove=router.register(first,()=>calls.push('new'));stale();
    router.handlePointer(f.pointer(first));router.handleKey(f.key());assert.deepEqual(calls,['new']);
    second.register(otherArea,()=>calls.push('other'));second.handlePointer(other.pointer(otherArea));second.handleKey(other.key());
    assert.deepEqual(calls,['new','other']);remove();assert.equal(router.handleKey(f.key()),false);
    assert.throws(()=>new SelectionRouter(f.document),/one SelectionRouter/);
    router.dispose();router.dispose();
    for(const listeners of f.document.listeners.values())assert.equal(listeners.size,0);
    for(const listeners of f.window.listeners.values())assert.equal(listeners.size,0);
    assert.throws(()=>router.register(first,()=>true),/disposed/);
    const replacement=new SelectionRouter(f.document);replacement.dispose();
  }finally{router.dispose();second.dispose();}
});

test('selection helpers mirror current-song items, standard mixer tracks, filtered setlist and MIDI channels',()=>{
  const song={tracks:[
    {id:'a',role:'keys',clips:[{id:'item-a'}]},
    {id:'click',role:'generatedClick',clips:[{id:'item-click'}]},
    {id:'group',role:{id:'group'},clips:[]},
    {id:'timecode',role:{id:'timecode'},clips:[{id:'item-tc'}]},
    {id:'tp',role:'teleprompt'}, {id:'tp2',role:'teleprompt2'}, {id:'video',role:'video'}, {id:'chords',role:'chords'},
  ]};
  assert.deepEqual([...timelineSelection(song)],['item-a','item-click','item-tc']);
  assert.deepEqual([...mixerSelection(song)],['a','group']);
  assert.deepEqual([...visibleSelection([{id:'filtered-one'},{id:'offscreen-two'},{id:'filtered-one'}])],['filtered-one','offscreen-two']);
  const notes=[{id:'n1',channel:1},{id:'n2',channel:2},{id:'n3',channel:1}];
  assert.deepEqual([...pianoRollSelection(notes,1)],['n1','n3']);
  assert.deepEqual([...pianoRollSelection(notes)],['n1','n2','n3']);
  for(const helper of [timelineSelection,mixerSelection,visibleSelection,pianoRollSelection])assert.equal(helper(null).size,0);
});
