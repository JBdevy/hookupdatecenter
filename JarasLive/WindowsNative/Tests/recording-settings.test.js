import test from 'node:test';
import assert from 'node:assert/strict';
import {createTrackRecordingSettings, createRecordingProjectStep, createAdvancedRecordingSettings,
  validRecordingChannelCount, normalizeAdvancedRecording, recordingEncodingKey} from '../ui/recording-settings.js';

class Element {
  children = []; parent = null; handlers = new Map(); attributes = new Map(); dataset = {};
  _disabled = false; hidden = false; value = ''; textContent = ''; tabIndex = 0;
  constructor(doc, name) { this.doc = doc; this.tagName = name.toUpperCase(); }
  append(...values) { values.forEach(value => { value.parent = this; this.children.push(value); }); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = null; }
  setAttribute(key, value) { this.attributes.set(key, String(value)); }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  addEventListener(key, fn) { if (!this.handlers.has(key)) this.handlers.set(key, new Set()); this.handlers.get(key).add(fn); }
  removeEventListener(key, fn) { this.handlers.get(key)?.delete(fn); }
  get disabled() { return this._disabled; }
  set disabled(value) { this._disabled = value; if (value && this.doc.activeElement === this) this.doc.activeElement = this.doc.body; }
  get isConnected() { return this === this.doc.body || Boolean(this.parent?.isConnected); }
  focus() { this.doc.activeElement = this; }
  getBoundingClientRect() { return {left: 20, bottom: 100}; }
  emit(type, values = {}) {
    const event = {target: this, defaultPrevented: false, stopped: false,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.stopped = true; }, ...values};
    for (let current = this; current; current = event.stopped ? null : current.parent)
      for (const callback of [...(current.handlers.get(type) ?? [])]) callback(event);
    return event;
  }
}
function environment() {
  const doc = {createElement: name => new Element(doc, name)};
  doc.body = doc.createElement('body');
  let lastMenu = null;
  const showMenu = options => { lastMenu = options; return () => {}; };
  return {document: doc, showMenu, menu: () => lastMenu};
}
function descendants(element) { return [element, ...element.children.flatMap(descendants)]; }
function control(component, name) {
  const found = descendants(component.element).find(value => value.dataset.recordingControl === name);
  assert.ok(found, `control ${name} exists`); return found;
}
function mount(env, component) { env.document.body.append(component.element); return component; }
async function settle() { for (let count = 0; count < 8; count += 1) await Promise.resolve(); }
function pending() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return {promise, resolve, reject}; }

test('recording keys retain WAV24 PCM, WAV32 float and Advanced PCM distinctions', () => {
  const advanced = {format: 'WAV', bitDepth: 32, bitrate: 224};
  assert.equal(recordingEncodingKey(null, advanced), 'wav32pcm');
  assert.equal(recordingEncodingKey('wav', advanced), 'wav24pcm');
  assert.equal(recordingEncodingKey('wav32', advanced), 'wav32');
  assert.equal(recordingEncodingKey('mp3', advanced), 'mp3-224');
  assert.equal(recordingEncodingKey(null, {format: 'AIFF', bitDepth: 16, bitrate: 320}), 'aiff16pcm');
  assert.deepEqual(normalizeAdvancedRecording({format: 'unknown', bitDepth: 12, bitrate: 512}), {format: 'WAV', bitDepth: 24, bitrate: 320});
  for (const valid of [1, 32, 128, '32', ' 001 ']) assert.equal(validRecordingChannelCount(valid), true);
  for (const invalid of [0, 129, 1.5, true, null, undefined, [], '1e2', '1.5', '', ' ', Infinity]) assert.equal(validRecordingChannelCount(invalid), false);
});

test('track popover dispatches actual values, waits for success and follows Advanced with null', async () => {
  const env = environment(); const requests = []; const work = pending();
  const component = mount(env, createTrackRecordingSettings({...env,
    track: {id: 'track', recordingChannels: 2, inputMonitoring: false, recordingFormat: 'wav32'},
    advanced: {format: 'AIFF', bitDepth: 24, bitrate: 192},
    actions: {
      setRecordingChannels: request => { requests.push(request); return work.promise; },
      setRecordingFormat: request => requests.push(request),
      setInputMonitoring: request => requests.push(request),
    },
  }));
  control(component, 'mode-1').emit('click', {button: 0});
  control(component, 'mode-1').emit('click', {button: 0});
  assert.deepEqual(requests, [{id: 'track', value: 1}]);
  assert.equal(control(component, 'mode-2').getAttribute('aria-checked'), 'true', 'does not claim an unapplied change');
  assert.equal(control(component, 'mode-1').disabled, true);
  work.resolve(); await settle();
  assert.equal(control(component, 'mode-1').getAttribute('aria-checked'), 'true');
  control(component, 'format').emit('click', {button: 0});
  assert.deepEqual(env.menu().items.map(item => item.label), ['Use Advanced setting', 'WAV · 24-bit PCM', 'WAV · 32-bit float', 'MP3 · 192 kbps']);
  await env.menu().items[0].action();
  assert.deepEqual(requests[1], {id: 'track', format: null});
  assert.equal(control(component, 'format').textContent, 'Use Advanced setting');
  control(component, 'monitor-true').emit('click', {button: 0}); await settle();
  assert.deepEqual(requests[2], {id: 'track', enabled: true});
  assert.equal(Object.isFrozen(requests[2]), true);
  component.destroy();
});

test('recording/busy locks mode and format but permits live monitoring; MIDI hides audio controls', async () => {
  const env = environment(); const requests = [];
  const component = mount(env, createTrackRecordingSettings({...env, recording: true,
    track: {id: 'track', recordingChannels: 1, inputMonitoring: true},
    actions: {setRecordingChannels: request => requests.push(request), setRecordingFormat: request => requests.push(request), setInputMonitoring: request => requests.push(request)},
  }));
  assert.equal(control(component, 'mode-2').disabled, true);
  assert.equal(control(component, 'format').disabled, true);
  assert.equal(control(component, 'monitor-false').disabled, false);
  control(component, 'monitor-false').emit('click', {button: 0}); await settle();
  assert.deepEqual(requests, [{id: 'track', enabled: false}]);
  component.update({recording: false, busy: true});
  assert.equal(control(component, 'mode-2').disabled, true);
  component.update({busy: false, track: {id: 'track', recordingChannels: 0}});
  assert.equal(control(component, 'format').parent.hidden, true);
  assert.equal(control(component, 'monitor-true').parent.parent.hidden, true);
  component.destroy();
});

test('failed commands keep current values; stale open menus and async results do not retarget another track', async () => {
  const env = environment(); const errors = []; const requests = []; const work = pending();
  const component = mount(env, createTrackRecordingSettings({...env,
    track: {id: 'first', recordingChannels: 2, recordingFormat: 'wav'}, onError: failure => errors.push(failure.message),
    actions: {
      setRecordingChannels: request => { requests.push(request); return work.promise; },
      setRecordingFormat: request => { requests.push(request); throw new Error('Disk unavailable'); },
    },
  }));
  control(component, 'format').emit('click', {button: 0});
  await env.menu().items[2].action();
  assert.equal(control(component, 'format').textContent, 'WAV · 24-bit PCM');
  assert.deepEqual(errors, ['Disk unavailable']);
  control(component, 'format').emit('click', {button: 0}); const stale = env.menu();
  component.update({track: {id: 'second', recordingChannels: 2}});
  await stale.items[1].action();
  assert.equal(requests.length, 1);
  control(component, 'mode-1').emit('click', {button: 0});
  component.update({track: {id: 'third', recordingChannels: 0}});
  work.resolve(); await settle();
  assert.equal(control(component, 'mode-0').getAttribute('aria-checked'), 'true');
  assert.deepEqual(requests[1], {id: 'second', value: 1});
  component.destroy();
});

test('segmented keyboard and right click never dispatch unexpected actions', async () => {
  const env = environment(); const requests = [];
  const component = mount(env, createTrackRecordingSettings({...env, track: {id: 'track', recordingChannels: 1},
    actions: {setRecordingChannels: request => requests.push(request)}}));
  control(component, 'mode-2').emit('click', {button: 2});
  assert.deepEqual(requests, []);
  const event = control(component, 'mode-1').emit('keydown', {key: 'ArrowRight'});
  await settle();
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(requests, [{id: 'track', value: 2}]);
  assert.equal(control(component, 'format').disabled, true, 'missing callbacks do not fake functionality');
  component.destroy();
  control(component, 'mode-1').emit('click', {button: 0}); await settle();
  assert.equal(requests.length, 1, 'destroy removes event listeners');
});

test('async mode changes preserve keyboard focus without stealing focus after navigation or a host update', async () => {
  const env = environment(); let work = pending();
  const component = mount(env, createTrackRecordingSettings({...env, track: {id: 'track', recordingChannels: 2},
    actions: {setRecordingChannels: () => work.promise}}));
  const mono = control(component, 'mode-1'), stereo = control(component, 'mode-2');
  mono.focus(); mono.emit('click', {button: 0});
  assert.equal(env.document.activeElement, env.document.body, 'disabled button loses focus like Chromium');
  work.resolve(); await settle();
  assert.equal(env.document.activeElement, mono);
  work = pending(); mono.emit('keydown', {key: 'ArrowRight'});
  const outside = env.document.createElement('input'); env.document.body.append(outside); outside.focus();
  work.resolve(); await settle();
  assert.equal(env.document.activeElement, outside, 'completion respects navigation to another control');
  work = pending(); mono.focus(); mono.emit('click', {button: 0});
  component.update({track: {id: 'replacement', recordingChannels: 2}});
  work.resolve(); await settle();
  assert.equal(env.document.activeElement, env.document.body, 'host replacement invalidates old focus restoration');
  assert.equal(stereo.getAttribute('aria-checked'), 'true');
  component.destroy();
});

test('REC Multitrack accepts 32 real channels and rejects malformed input without clamping', async () => {
  const env = environment(); const calls = []; const work = pending();
  const component = mount(env, createRecordingProjectStep({...env,
    actions: {createProject: request => { calls.push(request); return work.promise; }, back: request => calls.push(request)},
  }));
  const input = control(component, 'channels');
  assert.equal(input.value, '32'); assert.equal(input.type, 'text');
  for (const value of ['0', '129', '3.5', 'abc', '1e2']) {
    input.value = value; input.emit('input');
    assert.equal(control(component, 'create').disabled, true);
    input.emit('keydown', {key: 'Enter'});
  }
  assert.deepEqual(calls, []);
  input.value = '32'; input.emit('input');
  input.emit('keydown', {key: 'Enter', repeat: true}); assert.deepEqual(calls, []);
  input.emit('keydown', {key: 'Enter'});
  control(component, 'create').emit('click', {button: 0});
  assert.deepEqual(calls, [{channels: 32}]);
  assert.equal(control(component, 'back').disabled, true);
  work.resolve(); await settle();
  component.update({channels: 128}); assert.equal(control(component, 'increase').disabled, true);
  component.update({channels: 1}); assert.equal(control(component, 'decrease').disabled, true);
  component.destroy();
});

test('Advanced preserves WAV/AIFF PCM options and all MP3 qualities through real persistence callback', async () => {
  const env = environment(); const changes = [];
  const component = mount(env, createAdvancedRecordingSettings({...env,
    value: {format: 'AIFF', bitDepth: 32, bitrate: 256}, actions: {setAdvancedRecording: value => changes.push(value)},
  }));
  control(component, 'advanced-bits').emit('click', {button: 0});
  assert.deepEqual(env.menu().items.map(item => item.label), ['16-bit PCM', '24-bit PCM', '32-bit PCM']);
  control(component, 'advanced-format').emit('click', {button: 0});
  assert.deepEqual(env.menu().items.map(item => item.label), ['WAV', 'AIFF', 'MP3']);
  await env.menu().items[2].action();
  assert.deepEqual(changes[0], {format: 'MP3', bitDepth: 32, bitrate: 256});
  assert.equal(control(component, 'advanced-bits').parent.hidden, true);
  assert.equal(control(component, 'advanced-bitrate').parent.hidden, false);
  control(component, 'advanced-bitrate').emit('click', {button: 0});
  assert.deepEqual(env.menu().items.map(item => item.label), ['128 kbps', '160 kbps', '192 kbps', '224 kbps', '256 kbps', '320 kbps']);
  await env.menu().items[3].action();
  assert.deepEqual(changes[1], {format: 'MP3', bitDepth: 32, bitrate: 224});
  control(component, 'advanced-format').emit('click', {button: 0}); await env.menu().items[1].action();
  assert.equal(control(component, 'advanced-bits').textContent, '32-bit PCM', 'switching formats retains the stored PCM preference');
  component.destroy();
});
