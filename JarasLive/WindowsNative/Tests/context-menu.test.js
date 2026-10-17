import test from 'node:test';
import assert from 'node:assert/strict';
import {clampMenuPosition, nextEnabledIndex, showContextMenu, isContextMenuOpen} from '../ui/context-menu.js';

test('keyboard traversal wraps and excludes separators and disabled commands', () => {
  const items = [{separator: true}, {label: 'one'}, {disabled: true}, {label: 'two'}, {separator: true}];
  assert.equal(nextEnabledIndex(items, -1, 1), 1);
  assert.equal(nextEnabledIndex(items, -1, -1), 3);
  assert.equal(nextEnabledIndex(items, 1, 1), 3);
  assert.equal(nextEnabledIndex(items, 3, 1), 1);
  assert.equal(nextEnabledIndex(items, 1, -1), 3);
  assert.equal(nextEnabledIndex([{disabled: true}, {separator: true}], -1, 1), -1);
  assert.equal(nextEnabledIndex([], 4, 1), -1);
});

test('menu placement respects all viewport edges including a zoomed viewport', () => {
  const viewport = {left: 25, top: 40, width: 320, height: 240};
  assert.deepEqual(clampMenuPosition({x: 340, y: 275, width: 200, height: 100, viewport}),
    {x: 137, y: 172, maxWidth: 304, maxHeight: 224});
  assert.deepEqual(clampMenuPosition({x: -100, y: -100, width: 999, height: 999, viewport}),
    {x: 33, y: 48, maxWidth: 304, maxHeight: 224});
  const tiny = clampMenuPosition({x: Infinity, y: NaN, width: 200, height: 200, viewport: {width: 4, height: 2}});
  assert.deepEqual(tiny, {x: 2, y: 1, maxWidth: 0, maxHeight: 0});
});

// Small event/DOM model for lifecycle and keyboard behavior; rendering is tested
// separately in WebView2. No screenshots or browser layout claims are inferred.
class Events {
  handlers = new Map();
  addEventListener(type, fn) {
    if (!this.handlers.has(type)) this.handlers.set(type, new Set());
    this.handlers.get(type).add(fn);
  }
  removeEventListener(type, fn) { this.handlers.get(type)?.delete(fn); }
  emit(type, properties = {}) {
    const event = {type, target: this, defaultPrevented: false, stopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; }, ...properties};
    let node = this;
    while (node) {
      for (const fn of [...(node.handlers?.get(type) ?? [])]) fn(event);
      if (event.stopped) break;
      node = node.parent;
    }
    return event;
  }
}
class Element extends Events {
  children = []; parent = null; attributes = new Map(); dataset = {}; style = {}; tabIndex = -1;
  constructor(doc, name) { super(); this.doc = doc; this.tagName = name.toUpperCase(); }
  append(...elements) { for (const element of elements) { element.parent = this; this.children.push(element); } }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = null; }
  get isConnected() { return this === this.doc.body || Boolean(this.parent?.isConnected); }
  setAttribute(key, value) { this.attributes.set(key, value); }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  removeAttribute(key) { this.attributes.delete(key); }
  contains(element) { return element === this || this.children.some(child => child.contains(element)); }
  focus() { this.doc.activeElement = this; this.emit('focusin'); }
  scrollIntoView() {}
  getBoundingClientRect() {
    const x = parseFloat(this.style.left) || 0, y = parseFloat(this.style.top) || 0;
    const width = Math.min(220, parseFloat(this.style.maxWidth) || 220);
    const height = Math.min(Math.max(30, this.children.length * 28 + 10), parseFloat(this.style.maxHeight) || Infinity);
    return {x, y, left: x, top: y, width, height, right: x + width, bottom: y + height};
  }
}
function environment() {
  const win = new Events();
  Object.assign(win, {innerWidth: 1024, innerHeight: 768, setTimeout, clearTimeout});
  const doc = new Events();
  doc.defaultView = win; doc.body = new Element(doc, 'body'); doc.body.parent = doc;
  doc.createElement = name => new Element(doc, name);
  doc.activeElement = doc.body;
  const previous = {document: globalThis.document, window: globalThis.window};
  globalThis.document = doc; globalThis.window = win;
  const trigger = new Element(doc, 'button'); doc.body.append(trigger); trigger.focus();
  return {doc, win, trigger,
    panels: () => doc.body.children.find(child => child.className === 'catlive-context-layer')?.children ?? [],
    restore() { globalThis.document = previous.document; globalThis.window = previous.window; },
  };
}

test('keyboard opens a submenu, skips disabled entries, returns left and restores focus on Escape', () => {
  const env = environment(); let close;
  try {
    close = showContextMenu({items: [
      {label: 'Disabled', disabled: true},
      {label: 'Parent', children: [{label: 'Child disabled', disabled: true}, {label: 'Child'}]},
      {separator: true}, {label: 'Last'},
    ]});
    const panel = env.panels()[0];
    const parent = panel.children[1], last = panel.children[3];
    assert.equal(env.doc.activeElement, parent);
    assert.equal(parent.getAttribute('aria-haspopup'), 'menu');
    parent.emit('keydown', {key: 'ArrowRight'});
    assert.equal(env.panels().length, 2);
    assert.equal(parent.getAttribute('aria-expanded'), 'true');
    assert.equal(env.doc.activeElement, env.panels()[1].children[1]);
    env.doc.activeElement.emit('keydown', {key: 'ArrowLeft'});
    assert.equal(env.panels().length, 1);
    assert.equal(parent.getAttribute('aria-expanded'), 'false');
    assert.equal(parent.getAttribute('aria-controls'), null);
    assert.equal(env.doc.activeElement, parent);
    parent.emit('keydown', {key: 'End'});
    assert.equal(env.doc.activeElement, last);
    last.emit('keydown', {key: 'ArrowDown'});
    assert.equal(env.doc.activeElement, parent);
    parent.emit('keydown', {key: 'Escape'});
    assert.equal(isContextMenuOpen(), false);
    assert.equal(env.doc.activeElement, env.trigger);
  } finally { close?.(); env.restore(); }
});

test('checked and destructive state use ARIA and actions run exactly once after closing', async () => {
  const env = environment(); let close; let count = 0; const errors = [];
  try {
    close = showContextMenu({items: [
      {separator: true}, {label: '<b>Literal label</b>', checked: true, destructive: true, shortcut: 'Ctrl+D',
        action: async () => { count += 1; assert.equal(isContextMenuOpen(), false); throw new Error('action failure'); }},
      {separator: true},
    ], onError: error => errors.push(error.message)});
    const row = env.panels()[0].children[0];
    assert.equal(row.getAttribute('role'), 'menuitemcheckbox');
    assert.equal(row.getAttribute('aria-checked'), 'true');
    assert.equal(row.dataset.destructive, 'true');
    assert.equal(row.children[1].textContent, '<b>Literal label</b>');
    assert.equal(env.panels()[0].children.length, 1);
    row.emit('keydown', {key: 'Enter'});
    row.emit('click', {button: 0});
    await Promise.resolve(); await Promise.resolve();
    assert.equal(count, 1);
    assert.deepEqual(errors, ['action failure']);
    assert.equal(env.doc.activeElement, env.trigger);
  } finally { close?.(); env.restore(); }
});

test('outside click and window blur dismiss without stealing new focus; listener lifecycle is cleaned', () => {
  const env = environment(); let close;
  try {
    const input = new Element(env.doc, 'input'); env.doc.body.append(input);
    close = showContextMenu({items: [{label: 'One'}]});
    input.emit('pointerdown', {button: 0}); input.focus();
    assert.equal(isContextMenuOpen(), false);
    assert.equal(env.doc.activeElement, input);
    const key = input.emit('keydown', {key: 'Home'});
    assert.equal(key.defaultPrevented, false);
    close = showContextMenu({items: [{label: 'One'}], returnFocus: false});
    env.win.emit('blur');
    assert.equal(isContextMenuOpen(), false);
    for (const handlers of env.win.handlers.values()) assert.equal(handlers.size, 0);
    for (const handlers of env.doc.handlers.values()) assert.equal(handlers.size, 0);
  } finally { close?.(); env.restore(); }
});

test('replacing an open menu preserves its original focus destination and modified keys remain untouched', () => {
  const env = environment(); let close;
  try {
    showContextMenu({items: [{label: 'Old'}]});
    close = showContextMenu({items: [{label: 'New'}, {label: 'Other'}]});
    assert.equal(env.panels().length, 1);
    const first = env.doc.activeElement;
    assert.equal(first.emit('keydown', {key: 'ArrowDown', ctrlKey: true}).defaultPrevented, false);
    assert.equal(env.doc.activeElement, first);
    close();
    assert.equal(env.doc.activeElement, env.trigger);
    assert.equal(isContextMenuOpen(), false);
  } finally { close?.(); env.restore(); }
});
