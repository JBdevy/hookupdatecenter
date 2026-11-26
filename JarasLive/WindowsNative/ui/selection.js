// Integration contract (matches EditorSelectionRouter on macOS):
// - Create ONE router per document/window, including detached mixers and MIDI.
// - Register the full panel root, not individual rows or DOM text selections:
//     router.register(grid, selectAllItems, {scope: 'grid'});
//     router.register(mixer, selectAllTracks, {scope: 'tracks'});
//     router.register(setlist, selectVisibleEntries, {scope: 'setlist'});
//     router.register(pianoRoll, selectVisibleNotes, {scope: 'pianoRoll'});
// - The callback is synchronous, updates the application's ID selection/anchor,
//   and returns true on change or false when empty/unavailable. A valid area's
//   Ctrl/Command+A is consumed even when empty, preventing browser Select All.
// - Pass blocked() for non-DOM gates: menus, mapping capture, native sheets,
//   document transitions, etc. DOM modal/menu and text editing gates also apply.
// - Capture pointerdown before opening a context menu. Left AND right clicks
//   select the owner panel without clearing highlights in other panels.
// - Native/canvas event bridges may call handlePointer/handleKey with the SAME
//   event that bubbles through the document; the key is applied only once.
// - Dispose registrations on unmount and dispose the router when its window closes.
//   Never invoke document.execCommand('selectAll') or Selection.selectAllChildren.
const routers = new WeakMap();
const scopePriority = Object.freeze({grid: 0, tracks: 1, setlist: 2, pianoRoll: 3});
const nonTextInputTypes = new Set(['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'color', 'file', 'hidden']);

export function isTextInput(element) {
  if (!element) return false;
  if (element.isContentEditable) return true;
  const role = element.getAttribute?.('role');
  if (role === 'textbox' || role === 'searchbox' || role === 'combobox') return true;
  const name = element.tagName?.toLowerCase();
  if (name === 'textarea' || name === 'select') return true;
  return name === 'input' && !nonTextInputTypes.has(element.type?.toLowerCase() || 'text');
}
function pathOf(event) {
  const path = event.composedPath?.();
  if (path?.length) return path;
  const result = [];
  for (let node = event.target; node; node = node.parentElement ?? node.parentNode ?? node.host)
    result.push(node);
  return result;
}
function activeElement(document) {
  let element = document.activeElement;
  while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
  return element;
}
function visible(element, document) {
  if (!element?.isConnected || element.ownerDocument !== document) return false;
  for (let node = element; node; node = node.parentElement ?? node.getRootNode?.()?.host) {
    if (node.hidden || node.inert || node.getAttribute?.('aria-hidden') === 'true') return false;
    const style = document.defaultView?.getComputedStyle?.(node);
    if (style?.display === 'none' || style?.visibility === 'hidden' || style?.visibility === 'collapse') return false;
  }
  return Boolean(element.getClientRects?.().length);
}
function visiblePoint(element, x, y, document) {
  const rect = element.getBoundingClientRect();
  let {left, top, right, bottom} = rect;
  const view = document.defaultView;
  const visual = view?.visualViewport;
  if (Number.isFinite(visual?.width ?? view?.innerWidth)) {
    left = Math.max(left, visual?.offsetLeft ?? 0);
    right = Math.min(right, (visual?.offsetLeft ?? 0) + (visual?.width ?? view.innerWidth));
    top = Math.max(top, visual?.offsetTop ?? 0);
    bottom = Math.min(bottom, (visual?.offsetTop ?? 0) + (visual?.height ?? view.innerHeight));
  }
  for (let node = element.parentElement ?? element.getRootNode?.()?.host; node;
    node = node.parentElement ?? node.getRootNode?.()?.host) {
    const style = view?.getComputedStyle?.(node);
    const clips = value => ['hidden', 'clip', 'scroll', 'auto'].includes(value);
    if (clips(style?.overflowX ?? style?.overflow) || clips(style?.overflowY ?? style?.overflow)) {
      const bounds = node.getBoundingClientRect();
      if (clips(style?.overflowX ?? style?.overflow)) { left = Math.max(left, bounds.left); right = Math.min(right, bounds.right); }
      if (clips(style?.overflowY ?? style?.overflow)) { top = Math.max(top, bounds.top); bottom = Math.min(bottom, bounds.bottom); }
    }
  }
  return x >= left && x < right && y >= top && y < bottom;
}
function blockingDOM(document) {
  const candidates = document.querySelectorAll?.(
    'dialog[open], [role="dialog"][aria-modal="true"], [role="alertdialog"][aria-modal="true"], [role="menu"], [data-selection-blocked="true"]',
  ) ?? [];
  return [...candidates].some(element => visible(element, document));
}

export class SelectionRouter {
  #areas = new Map();
  #focused = null;
  #document;
  #window;
  #blocked;
  #listeners = [];
  #handledKeys = new WeakSet();
  #windowActive;
  #disposed = false;
  constructor(document, blocked = () => false) {
    if (routers.has(document)) throw new Error('Only one SelectionRouter may own a document.');
    if (typeof blocked !== 'function') throw new TypeError('blocked must be a function.');
    this.#document = document;
    this.#window = document.defaultView;
    this.#blocked = blocked;
    this.#windowActive = document.hasFocus?.() ?? true;
    routers.set(document, this);
    this.#listen(document, 'pointerdown', event => this.handlePointer(event), true);
    this.#listen(document, 'keydown', event => this.handleKey(event));
    this.#listen(this.#window, 'focus', () => { this.#windowActive = true; });
    this.#listen(this.#window, 'blur', () => { this.#windowActive = false; });
  }
  #listen(target, type, callback, options) {
    target?.addEventListener(type, callback, options);
    this.#listeners.push(() => target?.removeEventListener(type, callback, options));
  }
  #available(event) {
    const doc = this.#document;
    if (this.#disposed || this.#blocked() || doc.hidden || !this.#windowActive
        || (typeof doc.hasFocus === 'function' && !doc.hasFocus()) || blockingDOM(doc)) return false;
    if (event.view && event.view !== this.#window) return false;
    const target = event.target;
    return !target || target === doc || target === this.#window || target.ownerDocument === doc;
  }
  register(element, selectAll, {scope = 'grid'} = {}) {
    if (this.#disposed) throw new Error('SelectionRouter is disposed.');
    if (!element || element.ownerDocument !== this.#document)
      throw new TypeError('Selection area must belong to this window.');
    if (typeof selectAll !== 'function') throw new TypeError('selectAll must be a function.');
    if (!Object.hasOwn(scopePriority, scope)) throw new TypeError(`Unknown selection scope: ${scope}`);
    const entry = {selectAll, priority: scopePriority[scope]};
    this.#areas.set(element, entry);
    return () => {
      // A stale unmount must not unregister a replacement at the same DOM root.
      if (this.#areas.get(element) !== entry) return;
      this.#areas.delete(element);
      if (this.#focused === element) this.#focused = null;
    };
  }
  handlePointer(event) {
    if (!this.#available(event) || ![0, 2].includes(event.button ?? 0)) return false;
    const path = pathOf(event);
    const candidates = [];
    for (const [element, entry] of this.#areas) {
      if (!visible(element, this.#document)) continue;
      const rect = element.getBoundingClientRect();
      const inPath = path.includes(element);
      // Geometry covers a native/canvas input overlay whose event route does not
      // contain the SwiftUI-equivalent background registration. A normal DOM
      // event still uses the same scope/size priority as the Mac implementation.
      const hasPoint = Number.isFinite(event.clientX) && Number.isFinite(event.clientY);
      const hit = hasPoint ? visiblePoint(element, event.clientX, event.clientY, this.#document) : inPath;
      if (hit) candidates.push({element, entry, size: rect.width * rect.height});
    }
    candidates.sort((a, b) => b.entry.priority - a.entry.priority || a.size - b.size);
    if (!candidates.length) return false; // Mac retains the last panel when clicking chrome.
    this.#focused = candidates[0].element;
    return true;
  }
  handleKey(event) {
    if (this.#handledKeys.has(event)) return true;
    if ((event.type && event.type !== 'keydown') || event.key?.toLowerCase() !== 'a'
        || !(event.ctrlKey || event.metaKey) || (event.ctrlKey && event.metaKey)
        || event.altKey || event.shiftKey || event.isComposing || event.defaultPrevented
        || !this.#available(event)) return false;
    const active = activeElement(this.#document);
    if (isTextInput(active) || active?.tagName?.toLowerCase() === 'iframe'
        || pathOf(event).some(isTextInput)) return false;
    const area = this.#focused;
    if (!visible(area, this.#document)) return false;
    const entry = this.#areas.get(area);
    if (!entry) return false;
    // Claim before calling application code, so callback errors and duplicate
    // event routes cannot fall back to selecting the page's DOM text.
    this.#handledKeys.add(event);
    event.preventDefault();
    event.stopPropagation();
    if (!event.repeat) entry.selectAll();
    return true;
  }
  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    for (const remove of this.#listeners) remove();
    this.#listeners.length = 0;
    this.#areas.clear();
    this.#focused = null;
    if (routers.get(this.#document) === this) routers.delete(this.#document);
  }
}

function ids(entries) {
  return new Set((Array.isArray(entries) ? entries : [])
    .map(entry => entry?.id).filter(id => id !== undefined && id !== null && id !== ''));
}
// Select all items in the current song, including offscreen and collapsed lanes.
export function timelineSelection(song) {
  return ids((song?.tracks ?? []).flatMap(track => track.clips ?? []));
}
export function mixerSelection(song) {
  // TrackKind.click has raw value generatedClick on Mac. These fixed-purpose
  // tracks are excluded from standard-track selection; folders remain eligible.
  const fixed = new Set(['generatedClick', 'timecode', 'video', 'teleprompt', 'teleprompt2', 'chords']);
  return ids((song?.tracks ?? []).filter(track => track.kind != null
    ? track.kind === 'standard' : !fixed.has(track.role?.id ?? track.role)));
}
// "Visible" means the filtered/current-playlist list, not only virtualised rows
// physically on screen. The caller supplies that list and updates its anchor.
export function visibleSelection(entries) { return ids(entries); }
export function pianoRollSelection(notes, channelFilter = 0) {
  return ids((Array.isArray(notes) ? notes : []).filter(note => channelFilter === 0 || note.channel === channelFilter));
}
