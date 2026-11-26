import test from 'node:test';
import assert from 'node:assert/strict';
import {mountTimelineLock} from '../ui/timeline-lock.js';

// Lifecycle/event fixture. Actual WebView rendering is verified separately;
// these tests do not infer visual fidelity from a synthetic DOM.
class Element {
  children = []; parentNode = null; attributes = new Map(); dataset = {}; listeners = new Map();
  constructor(doc, name) { this.ownerDocument = doc; this.tagName = name; this.disabled = false; }
  get isConnected() { return this === this.ownerDocument.body || Boolean(this.parentNode?.isConnected); }
  append(...items) { for (const item of items) { item.remove(); item.parentNode = this; this.children.push(item); } }
  insertBefore(item, before) {
    const index = this.children.indexOf(before);
    assert.notEqual(index, -1);
    item.remove(); item.parentNode = this; this.children.splice(index, 0, item);
  }
  remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(item => item !== this); this.parentNode = null; }
  setAttribute(key, value) { this.attributes.set(key, String(value)); }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  addEventListener(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(callback);
  }
  removeEventListener(type, callback) { this.listeners.get(type)?.delete(callback); }
  emit(type, properties = {}) {
    const event = {button: 0, repeat: false, defaultPrevented: false, stopped: false,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.stopped = true; }, ...properties};
    event.done = Promise.all([...this.listeners.get(type) ?? []].map(callback => callback(event)));
    return event;
  }
}
function fixture() {
  const doc = {createElement: name => new Element(doc, name), createElementNS: (_, name) => new Element(doc, name)};
  doc.body = new Element(doc, 'body');
  const row = doc.createElement('div'), title = doc.createElement('span'), addButton = doc.createElement('button');
  doc.body.append(row); row.append(title, addButton);
  return {doc, row, title, addButton};
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return {promise, resolve, reject};
}
const state = (locked, revision) => ({state: {timelineMovementLocked: locked, revision}});

test('mounts immediately left of real Add and only reflects a confirmed native state', async () => {
  const env = fixture(), pending = deferred(), calls = [];
  const control = mountTimelineLock({...env, projectId: 'project', sessionId: 'load-1', revision: 1,
    actions: {setTimelineMovementLocked: request => { calls.push(request); return pending.promise; }}});
  assert.deepEqual(env.row.children, [env.title, control.element, env.addButton]);
  assert.equal(control.element.type, 'button');
  assert.equal(control.element.getAttribute('aria-pressed'), 'false');
  const event = control.element.emit('click');
  assert.equal(control.element.getAttribute('aria-pressed'), 'false', 'no optimistic mutation');
  assert.equal(control.element.getAttribute('aria-busy'), 'true');
  assert.equal(control.element.disabled, true);
  await control.element.emit('click').done;
  assert.equal(calls.length, 1, 'pending clicks cannot issue overlapping edits');
  assert.deepEqual(calls[0], {projectId: 'project', sessionId: 'load-1', locked: true});
  assert.equal(Object.isFrozen(calls[0]), true);
  pending.resolve(state(true, 2)); await event.done;
  assert.equal(control.element.getAttribute('aria-pressed'), 'true');
  assert.equal(control.element.dataset.locked, 'true');
  assert.equal(control.element.disabled, false);
  assert.equal(control.element.getAttribute('aria-busy'), 'false');
  control.destroy();
});

test('right click and held Enter/Space do not create extra toggle commands', async () => {
  const env = fixture(); let calls = 0;
  const control = mountTimelineLock({...env, projectId: 'p',
    actions: {setTimelineMovementLocked: () => { calls += 1; return state(true, calls); }}});
  await control.element.emit('click', {button: 2}).done;
  assert.equal(calls, 0);
  for (const key of ['Enter', ' ', 'Spacebar']) {
    const event = control.element.emit('keydown', {key, repeat: true});
    assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true);
  }
  assert.equal(control.element.emit('keydown', {key: 'Enter', repeat: false}).defaultPrevented, false);
  await control.element.emit('click', {button: undefined}).done;
  assert.equal(calls, 1, 'native keyboard activation still works');
  control.destroy();
});

test('command errors and malformed responses preserve the committed state and allow retry', async () => {
  const env = fixture(), errors = []; let attempt = 0;
  const control = mountTimelineLock({...env, projectId: 'p', locked: true, onError: error => errors.push(error.message),
    actions: {setTimelineMovementLocked: () => {
      attempt += 1;
      if (attempt === 1) throw new Error('Could not persist');
      if (attempt === 2) return {};
      return state(false, 2);
    }}});
  await control.element.emit('click').done;
  assert.equal(control.element.dataset.locked, 'true'); assert.equal(control.element.disabled, false);
  await control.element.emit('click').done;
  assert.equal(control.element.dataset.locked, 'true'); assert.equal(errors.length, 2);
  await control.element.emit('click').done;
  assert.equal(control.element.dataset.locked, 'false'); assert.equal(attempt, 3);
  control.destroy();
});

test('authoritative Undo beats a late response while newer response revisions can advance state', async () => {
  const env = fixture(); let pending = deferred();
  const control = mountTimelineLock({...env, projectId: 'p', revision: 1,
    actions: {setTimelineMovementLocked: () => pending.promise}});
  const first = control.element.emit('click');
  control.update({locked: false, revision: 3}); // Undo after the toggle revision 2.
  pending.resolve(state(true, 2)); await first.done;
  assert.equal(control.element.dataset.locked, 'false');
  control.update({locked: true, revision: 2});
  assert.equal(control.element.dataset.locked, 'false', 'stale pushed state is ignored');
  pending = deferred();
  const second = control.element.emit('click');
  control.update({locked: false, revision: 4});
  pending.resolve(state(true, 5)); await second.done;
  assert.equal(control.element.dataset.locked, 'true', 'response newer than the notification wins');
  control.destroy();
});

test('redundant state ticks and enabled changes do not discard a valid confirmation', async () => {
  const env = fixture(), pending = deferred();
  const control = mountTimelineLock({...env, projectId: 'p', revision: 1,
    actions: {setTimelineMovementLocked: () => pending.promise}});
  const event = control.element.emit('click');
  control.update({locked: false, revision: 1});
  control.update({enabled: false});
  pending.resolve(state(true, 2)); await event.done;
  assert.equal(control.element.dataset.locked, 'true'); assert.equal(control.element.disabled, true);
  control.update({enabled: true}); assert.equal(control.element.disabled, false);
  control.destroy();
});

test('new projects and same-project reloads ignore both stale success and failure', async () => {
  const env = fixture(), first = deferred(), second = deferred(), errors = [], calls = [];
  let promise = first.promise;
  const control = mountTimelineLock({...env, projectId: 'p', sessionId: 'load-1',
    onError: error => errors.push(error), actions: {setTimelineMovementLocked: request => { calls.push(request); return promise; }}});
  const oldEvent = control.element.emit('click');
  control.reset({projectId: 'p', sessionId: 'load-2', locked: false, revision: 0});
  promise = second.promise;
  const newEvent = control.element.emit('click');
  first.resolve(state(true, 99)); await oldEvent.done;
  assert.equal(control.element.dataset.locked, 'false');
  assert.equal(control.element.getAttribute('aria-busy'), 'true', 'old success cannot clear the new request');
  control.update({projectId: 'another', sessionId: 'another-load', locked: true});
  second.reject(new Error('Old document failed')); await newEvent.done;
  assert.equal(control.element.dataset.locked, 'true'); assert.equal(control.element.disabled, false);
  assert.deepEqual(errors, []); assert.deepEqual(calls.map(call => call.sessionId), ['load-1', 'load-2']);
  control.destroy();
});

test('reset to an unloaded document disables the control and retains no old locked state', async () => {
  const env = fixture(); let calls = 0;
  const control = mountTimelineLock({...env, projectId: 'p', locked: true,
    actions: {setTimelineMovementLocked: () => { calls += 1; return state(false, 2); }}});
  control.reset({projectId: null, sessionId: null});
  assert.equal(control.element.disabled, true); assert.equal(control.element.dataset.locked, 'false');
  await control.element.emit('click').done; assert.equal(calls, 0);
  control.destroy();
});

test('remount and destruction clean handlers without a stale promise reviving the control', async () => {
  const env = fixture(), pending = deferred(); let errors = 0;
  const old = mountTimelineLock({...env, projectId: 'p', onError: () => { errors += 1; },
    actions: {setTimelineMovementLocked: () => pending.promise}});
  const event = old.element.emit('click');
  const current = mountTimelineLock({...env, projectId: 'p', actions: {setTimelineMovementLocked: () => state(true, 2)}});
  assert.deepEqual(env.row.children, [env.title, current.element, env.addButton]);
  assert.equal(old.element.isConnected, false); assert.equal(old.element.listeners.get('click').size, 0);
  pending.reject(new Error('Unmounted')); await event.done;
  assert.equal(errors, 0); assert.equal(current.element.dataset.locked, 'false');
  old.update({locked: true}); assert.equal(old.element.dataset.locked, 'false');
  current.destroy(); current.destroy();
  assert.deepEqual(env.row.children, [env.title, env.addButton]);
});

test('missing real command stays unavailable and no synthetic Add/workspace is created', () => {
  const env = fixture();
  const control = mountTimelineLock({...env, projectId: 'p'});
  assert.equal(control.element.disabled, true);
  control.update({actions: {setTimelineMovementLocked: () => state(true, 1)}});
  assert.equal(control.element.disabled, false);
  control.destroy(); env.addButton.remove();
  assert.throws(() => mountTimelineLock({...env}), /real Add button/);
});
