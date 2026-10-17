// Product actions belong to callers. This module owns only presentation,
// keyboard/pointer navigation, focus restoration and viewport positioning.
let activeMenu = null;
let nextMenuID = 0;

export function isContextMenuOpen() { return activeMenu !== null; }

export function nextEnabledIndex(items, current, direction) {
  if (!items.length) return -1;
  const step = direction < 0 ? -1 : 1;
  let index = Number.isInteger(current) ? current : -1;
  if (index < 0 || index >= items.length) index = step > 0 ? -1 : 0;
  for (let visited = 0; visited < items.length; visited += 1) {
    index = (index + step + items.length) % items.length;
    if (items[index] && !items[index].separator && !items[index].disabled) return index;
  }
  return -1;
}

// Coordinates are CSS pixels, including a visual viewport's offset when zoomed.
export function clampMenuPosition({x, y, width, height, viewport, margin = 8}) {
  const left = Number.isFinite(viewport?.left) ? viewport.left : 0;
  const top = Number.isFinite(viewport?.top) ? viewport.top : 0;
  const vw = Math.max(0, Number(viewport?.width) || 0);
  const vh = Math.max(0, Number(viewport?.height) || 0);
  const insetX = Math.min(Math.max(0, margin), vw / 2);
  const insetY = Math.min(Math.max(0, margin), vh / 2);
  const maxWidth = Math.max(0, vw - insetX * 2);
  const maxHeight = Math.max(0, vh - insetY * 2);
  const usedWidth = Math.min(Math.max(0, width || 0), maxWidth);
  const usedHeight = Math.min(Math.max(0, height || 0), maxHeight);
  const clamp = (value, min, max) => Math.max(min, Math.min(max, Number.isFinite(value) ? value : min));
  return {
    x: clamp(x, left + insetX, left + vw - insetX - usedWidth),
    y: clamp(y, top + insetY, top + vh - insetY - usedHeight),
    maxWidth, maxHeight,
  };
}

function textInput(element) {
  if (!element) return false;
  if (element.isContentEditable) return true;
  const tag = element.tagName?.toLowerCase();
  return tag === 'input' || tag === 'textarea' || tag === 'select';
}

function cleanItems(items) {
  const result = [];
  for (const item of Array.isArray(items) ? items : []) {
    if (!item || typeof item !== 'object') continue;
    if (item.separator) {
      if (result.length && !result.at(-1).separator) result.push({separator: true});
    } else {
      // Snapshot item metadata; external mutations cannot desynchronise ARIA and
      // navigation while a menu is visible. Actions keep their original closure.
      result.push({...item, label: String(item.label ?? '')});
    }
  }
  if (result.at(-1)?.separator) result.pop();
  return result;
}

/**
 * showContextMenu({x, y, items, onError, returnFocus}) -> close()
 *
 * items: {label, action, disabled, checked, shortcut, children, separator,
 *         destructive}. children is another items array. action may be async.
 * returnFocus: an element (default: the active element), or false to opt out.
 * Import context-menu.css once in the page. No product commands are added here.
 */
export function showContextMenu({x = 0, y = 0, items = [], onError, returnFocus} = {}) {
  const previousFocus = activeMenu?.layer.contains(document.activeElement)
    ? activeMenu.focusTarget : document.activeElement;
  activeMenu?.close(false);
  const rootItems = cleanItems(items);
  if (!rootItems.length) return () => {};
  const doc = document;
  const win = doc.defaultView ?? window;
  const focusTarget = returnFocus === undefined ? previousFocus : returnFocus;
  const layer = doc.createElement('div');
  layer.className = 'catlive-context-layer';
  const frames = [];
  const listeners = [];
  let closed = false;
  let hoverTimer = 0;
  let typeTimer = 0;
  let typed = '';
  const listen = (target, type, callback, options) => {
    target?.addEventListener(type, callback, options);
    listeners.push(() => target?.removeEventListener(type, callback, options));
  };
  const stopHover = () => { win.clearTimeout(hoverTimer); hoverTimer = 0; };
  const restoreFocus = () => {
    if (focusTarget && focusTarget.isConnected && typeof focusTarget.focus === 'function')
      focusTarget.focus({preventScroll: true});
  };
  function close(restore = true) {
    if (closed) return;
    closed = true;
    stopHover();
    win.clearTimeout(typeTimer);
    for (const remove of listeners) remove();
    layer.remove();
    if (activeMenu?.close === close) activeMenu = null;
    if (restore) restoreFocus();
  }
  activeMenu = {close, layer, focusTarget};

  function viewport() {
    const visual = win.visualViewport;
    return {left: visual?.offsetLeft ?? 0, top: visual?.offsetTop ?? 0,
      width: visual?.width ?? win.innerWidth, height: visual?.height ?? win.innerHeight};
  }
  function position(frame) {
    const view = viewport();
    const limits = clampMenuPosition({x: 0, y: 0, width: 0, height: 0, viewport: view});
    frame.panel.style.maxWidth = `${limits.maxWidth}px`;
    frame.panel.style.minWidth = `${Math.min(208, limits.maxWidth)}px`;
    frame.panel.style.maxHeight = `${limits.maxHeight}px`;
    const bounds = frame.panel.getBoundingClientRect();
    let px = x, py = y;
    if (frame.parentRow) {
      const anchor = frame.parentRow.getBoundingClientRect();
      px = anchor.right + 3;
      py = anchor.top - 4;
      if (px + bounds.width > view.left + view.width - 8) px = anchor.left - bounds.width - 3;
    }
    const placed = clampMenuPosition({x: px, y: py, width: bounds.width, height: bounds.height, viewport: view});
    frame.panel.style.left = `${placed.x}px`;
    frame.panel.style.top = `${placed.y}px`;
  }
  function dropAfter(level) {
    while (frames.length > level + 1) {
      const removed = frames.pop();
      removed.parentRow?.setAttribute('aria-expanded', 'false');
      removed.parentRow?.removeAttribute('aria-controls');
      removed.panel.remove();
    }
  }
  function select(frame, index, focus = true) {
    if (index < 0 || frame.items[index]?.disabled || frame.items[index]?.separator) return;
    if (frame.selected !== index) {
      dropAfter(frame.level);
      if (frame.rows[frame.selected]) {
        frame.rows[frame.selected].dataset.active = 'false';
        frame.rows[frame.selected].tabIndex = -1;
      }
      frame.selected = index;
    }
    const row = frame.rows[index];
    row.dataset.active = 'true';
    row.tabIndex = 0;
    if (focus) {
      row.focus({preventScroll: true});
      row.scrollIntoView?.({block: 'nearest', inline: 'nearest'});
    }
  }
  function submenu(frame, index, focus) {
    const item = frame.items[index];
    if (!item || item.disabled) return;
    const children = cleanItems(item.children);
    if (!children.length) return;
    const existing = frames[frame.level + 1];
    if (existing?.parentRow === frame.rows[index]) {
      if (focus) focusFirst(existing);
      return;
    }
    dropAfter(frame.level);
    const child = createFrame(children, frame.rows[index], frame.level + 1);
    frame.rows[index].setAttribute('aria-expanded', 'true');
    frame.rows[index].setAttribute('aria-controls', child.panel.id);
    if (focus) focusFirst(child);
  }
  function focusFirst(frame) {
    const index = nextEnabledIndex(frame.items, -1, 1);
    if (index >= 0) select(frame, index);
    else frame.panel.focus({preventScroll: true});
  }
  function report(error) {
    if (typeof onError === 'function') {
      try { onError(error); } catch (reportError) { console.error(reportError); }
    } else console.error(error);
  }
  function activate(frame, index) {
    const item = frame.items[index];
    if (closed || !item || item.disabled || item.separator) return;
    if (cleanItems(item.children).length) { submenu(frame, index, true); return; }
    close();
    if (typeof item.action !== 'function') return;
    try { Promise.resolve(item.action()).catch(report); } catch (error) { report(error); }
  }
  function handleKey(event) {
    if (closed || event.defaultPrevented || event.isComposing || textInput(event.target)
        || event.ctrlKey || event.metaKey || event.altKey) return;
    const frame = [...frames].reverse().find(entry => entry.panel.contains(doc.activeElement));
    if (!frame) return;
    let handled = true;
    stopHover();
    switch (event.key) {
      case 'ArrowDown': select(frame, nextEnabledIndex(frame.items, frame.selected, 1)); break;
      case 'ArrowUp': select(frame, nextEnabledIndex(frame.items, frame.selected, -1)); break;
      case 'Home': select(frame, nextEnabledIndex(frame.items, -1, 1)); break;
      case 'End': select(frame, nextEnabledIndex(frame.items, -1, -1)); break;
      case 'ArrowRight': submenu(frame, frame.selected, true); break;
      case 'ArrowLeft':
      case 'Escape':
        if (frame.level > 0) {
          const parentRow = frame.parentRow;
          dropAfter(frame.level - 1);
          parentRow.focus({preventScroll: true});
        } else if (event.key === 'Escape') close();
        break;
      case 'Enter':
      case ' ': activate(frame, frame.selected); break;
      case 'Tab': close(); handled = false; break;
      default: {
        if (event.key?.length !== 1 || event.key.trim() === '') { handled = false; break; }
        win.clearTimeout(typeTimer);
        typed += event.key.toLocaleLowerCase();
        typeTimer = win.setTimeout(() => { typed = ''; }, 650);
        const search = [...typed].every(char => char === typed[0]) ? typed[0] : typed;
        for (let offset = 1; offset <= frame.items.length; offset += 1) {
          const index = (Math.max(-1, frame.selected) + offset) % frame.items.length;
          const item = frame.items[index];
          if (!item.disabled && !item.separator && item.label.toLocaleLowerCase().startsWith(search)) {
            select(frame, index); break;
          }
        }
      }
    }
    if (handled) { event.preventDefault(); event.stopPropagation(); }
  }
  function createFrame(frameItems, parentRow, level) {
    const panel = doc.createElement('div');
    panel.className = 'catlive-context-menu';
    panel.id = `catlive-context-menu-${++nextMenuID}`;
    panel.setAttribute('role', 'menu');
    panel.setAttribute('aria-orientation', 'vertical');
    if (parentRow) panel.setAttribute('aria-labelledby', parentRow.id);
    panel.tabIndex = -1;
    const frame = {panel, items: frameItems, rows: [], selected: -1, parentRow, level};
    for (const [index, item] of frameItems.entries()) {
      const row = doc.createElement('div');
      frame.rows.push(row);
      if (item.separator) {
        row.className = 'catlive-context-separator';
        row.setAttribute('role', 'separator');
        panel.append(row);
        continue;
      }
      row.className = 'catlive-context-item';
      row.id = `${panel.id}-item-${index}`;
      row.tabIndex = -1;
      const checkable = typeof item.checked === 'boolean';
      row.setAttribute('role', checkable ? 'menuitemcheckbox' : 'menuitem');
      if (checkable) row.setAttribute('aria-checked', String(item.checked));
      if (item.disabled) row.setAttribute('aria-disabled', 'true');
      if (item.destructive) row.dataset.destructive = 'true';
      const children = cleanItems(item.children);
      if (children.length) {
        row.setAttribute('aria-haspopup', 'menu'); row.setAttribute('aria-expanded', 'false');
      }
      const mark = doc.createElement('span');
      mark.className = 'catlive-context-check'; mark.setAttribute('aria-hidden', 'true');
      const label = doc.createElement('span');
      label.className = 'catlive-context-label'; label.textContent = item.label;
      row.append(mark, label);
      if (item.shortcut) {
        const shortcut = doc.createElement('span'); shortcut.className = 'catlive-context-shortcut';
        shortcut.textContent = String(item.shortcut); shortcut.setAttribute('aria-hidden', 'true');
        row.append(shortcut);
      }
      const arrow = doc.createElement('span');
      arrow.className = 'catlive-context-arrow'; arrow.setAttribute('aria-hidden', 'true');
      row.append(arrow);
      row.addEventListener('pointerenter', () => {
        stopHover();
        if (item.disabled) { dropAfter(frame.level); return; }
        select(frame, index);
        if (children.length) hoverTimer = win.setTimeout(() => {
          if (!closed && frames.includes(frame)) submenu(frame, index, false);
        }, 130);
      });
      row.addEventListener('pointerdown', event => {
        if (event.button !== 0) return;
        event.preventDefault();
        if (!item.disabled) select(frame, index);
      });
      row.addEventListener('click', event => {
        if (event.button !== 0) return;
        event.preventDefault(); event.stopPropagation(); activate(frame, index);
      });
      panel.append(row);
    }
    panel.addEventListener('pointerenter', stopHover);
    panel.addEventListener('scroll', () => dropAfter(frame.level));
    layer.append(panel); frames.push(frame); position(frame);
    return frame;
  }

  doc.body.append(layer);
  listen(layer, 'keydown', handleKey);
  listen(layer, 'contextmenu', event => event.preventDefault());
  listen(doc, 'pointerdown', event => { if (!layer.contains(event.target)) close(false); }, true);
  listen(doc, 'focusin', event => { if (!layer.contains(event.target)) close(false); });
  listen(win, 'blur', () => close(false));
  listen(doc, 'visibilitychange', () => { if (doc.hidden) close(false); });
  const reposition = () => { for (const frame of frames) position(frame); };
  listen(win, 'resize', reposition);
  listen(win.visualViewport, 'resize', reposition);
  listen(win.visualViewport, 'scroll', reposition);
  focusFirst(createFrame(rootItems, null, 0));
  return () => close();
}
