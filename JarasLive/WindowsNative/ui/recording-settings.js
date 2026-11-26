import {showContextMenu} from './context-menu.js';

export const recordingMP3Bitrates = Object.freeze([128, 160, 192, 224, 256, 320]);
export const recordingBitDepths = Object.freeze([16, 24, 32]);
export const recordingChannelLimits = Object.freeze({minimum: 1, maximum: 128, initial: 32});
const formats = Object.freeze(['WAV', 'AIFF', 'MP3']);
const modes = Object.freeze([1, 2, 0]);
let nextPanelID = 0;

export function validRecordingChannelCount(value) {
  // Do not silently round/clamp a user's requested input count.
  if (typeof value !== 'number' && typeof value !== 'string') return false;
  if (typeof value === 'string' && !/^\d+$/.test(value.trim())) return false;
  const count = Number(value);
  return Number.isInteger(count) && count >= 1 && count <= 128;
}

export function normalizeAdvancedRecording(value = {}) {
  return {
    format: formats.includes(value.format) ? value.format : 'WAV',
    bitDepth: recordingBitDepths.includes(value.bitDepth) ? value.bitDepth : 24,
    bitrate: recordingMP3Bitrates.includes(value.bitrate) ? value.bitrate : 320,
  };
}

// Exact Mac recording keys: the track's wav32 override is FLOAT; Advanced's
// WAV/32 setting is PCM. Never merge those two encodings under one label/key.
export function recordingEncodingKey(trackFormat, advanced = {}) {
  const value = normalizeAdvancedRecording(advanced);
  if (trackFormat === 'wav') return 'wav24pcm';
  if (trackFormat === 'wav32') return 'wav32';
  if (trackFormat === 'mp3' || value.format === 'MP3') return `mp3-${value.bitrate}`;
  return `${value.format.toLowerCase()}${value.bitDepth}pcm`;
}

function component(options, title, className = '') {
  const doc = options.document ?? globalThis.document;
  if (!doc?.createElement) throw new TypeError('Recording controls require a document.');
  const t = (key, fallback) => options.t?.(`recording.${key}`, fallback) ?? fallback;
  const element = doc.createElement('section');
  element.className = `catlive-recording-panel ${className}`.trim();
  element.setAttribute('role', 'group');
  const controls = new Map();
  const listeners = [];
  let disposed = false, pending = false, version = 0, closeMenu = null;
  const make = (tag, className, text) => {
    const value = doc.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = String(text);
    return value;
  };
  if (title) {
    const heading = make('h2', 'catlive-recording-title', title);
    heading.id = `catlive-recording-${++nextPanelID}`;
    element.setAttribute('aria-labelledby', heading.id);
    element.append(heading);
  }
  const error = make('p', 'catlive-recording-error');
  error.setAttribute('role', 'alert'); error.hidden = true;
  const listen = (target, type, callback) => {
    target.addEventListener(type, callback);
    listeners.push(() => target.removeEventListener(type, callback));
  };
  const control = (name, value) => { value.dataset.recordingControl = name; controls.set(name, value); return value; };
  const row = (label, child) => {
    const wrapper = make('div', 'catlive-recording-row');
    if (label) {
      const text = make('span', 'catlive-recording-label', label);
      text.id = `catlive-recording-${++nextPanelID}`;
      child.setAttribute('aria-labelledby', text.id); wrapper.append(text);
    }
    wrapper.append(child); element.append(wrapper); return wrapper;
  };
  const button = (name, label, callback) => {
    const value = control(name, make('button', 'catlive-recording-button', label));
    value.type = 'button';
    listen(value, 'click', event => {
      if (disposed || value.disabled || (event.button !== undefined && event.button !== 0)) return;
      callback(event);
    });
    return value;
  };
  let render = () => {};
  const commit = async (callback, payload, apply) => {
    if (disposed || pending || typeof callback !== 'function') return false;
    const revision = version;
    const focused = [...controls.values()].includes(doc.activeElement) ? doc.activeElement : null;
    let focusMoved = false;
    const movedFocus = event => {
      if (event.type === 'focusin' && (event.target === focused || event.target === doc.body)) return;
      if (event.type === 'keydown' && event.key !== 'Tab') return;
      focusMoved = true;
    };
    for (const type of ['focusin', 'pointerdown', 'keydown']) doc.addEventListener?.(type, movedFocus, true);
    pending = true; error.hidden = true; error.textContent = '';
    element.setAttribute('aria-busy', 'true'); render();
    try {
      await callback(Object.freeze({...payload}));
      if (!disposed && revision === version) apply?.();
      return true;
    } catch (failure) {
      if (!disposed && revision === version) {
        error.textContent = failure instanceof Error ? failure.message : String(failure);
        error.hidden = false;
        try { options.onError?.(failure); } catch (reportError) { console.error(reportError); }
      }
      return false;
    } finally {
      for (const type of ['focusin', 'pointerdown', 'keydown']) doc.removeEventListener?.(type, movedFocus, true);
      pending = false;
      if (!disposed) { element.setAttribute('aria-busy', 'false'); render(); }
      // Chromium blurs a focused button as soon as pending disables it. Restore
      // that focus for continued keyboard navigation only if the user and host
      // have not moved on while the real session command was in flight.
      if (!disposed && revision === version && !focusMoved && focused?.isConnected &&
          !focused.disabled && !focused.closest?.('[hidden]') &&
          (!doc.activeElement || doc.activeElement === doc.body || doc.activeElement === doc.documentElement)) {
        focused.focus({preventScroll: true});
      }
    }
  };
  function choice(name, label, getOptions) {
    const value = button(name, label, () => {
      closeMenu?.(false);
      const rect = value.getBoundingClientRect();
      const revision = version;
      closeMenu = (options.showMenu ?? showContextMenu)({
        x: rect.left, y: rect.bottom + 4, returnFocus: value,
        items: getOptions().map(entry => ({...entry, action: () => {
          if (!disposed && !pending && revision === version) return entry.action?.();
        }})), onError: options.onError,
      });
    });
    value.className += ' catlive-recording-choice';
    value.setAttribute('aria-haspopup', 'menu');
    return value;
  }
  function segmented(name, choices, choose) {
    const group = make('div', 'catlive-recording-segments');
    group.setAttribute('role', 'radiogroup');
    const buttons = choices.map(entry => {
      const value = button(`${name}-${entry.value}`, entry.label, () => choose(entry.value));
      value.setAttribute('role', 'radio'); group.append(value); return value;
    });
    listen(group, 'keydown', event => {
      if (disposed || event.altKey || event.ctrlKey || event.metaKey || event.isComposing) return;
      const at = buttons.indexOf(event.target);
      if (at < 0 || buttons[at].disabled) return;
      let index;
      if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') index = (at + buttons.length - 1) % buttons.length;
      else if (event.key === 'ArrowRight' || event.key === 'ArrowDown') index = (at + 1) % buttons.length;
      else if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = buttons.length - 1;
      else return;
      if (buttons[index].disabled) return;
      event.preventDefault(); event.stopPropagation(); buttons[index].focus(); choose(choices[index].value);
    });
    return {element: group, update(selected, disabled) {
      choices.forEach((entry, index) => {
        const active = entry.value === selected;
        buttons[index].setAttribute('aria-checked', String(active));
        buttons[index].tabIndex = active ? 0 : -1;
        buttons[index].disabled = disabled;
      });
    }};
  }
  return {
    element, t, make, controls, row, button, choice, segmented, control, listen, commit,
    get pending() { return pending; },
    setRenderer(callback) { render = callback; element.append(error); render(); },
    changed() { version += 1; closeMenu?.(false); closeMenu = null; error.hidden = true; error.textContent = ''; render(); },
    destroy() {
      if (disposed) return;
      disposed = true; version += 1; closeMenu?.(false);
      for (const remove of listeners) remove();
      element.remove();
    },
  };
}

/**
 * Track REC popover content, matching TrackRecordButton on Mac.
 * actions.setRecordingChannels({id,value:0|1|2})
 * actions.setRecordingFormat({id,format:null|'wav'|'wav32'|'mp3'})
 * actions.setInputMonitoring({id,enabled})
 * Callbacks must commit through the actual session. Missing callbacks disable
 * their controls; rejected callbacks retain the previous displayed value.
 */
export function createTrackRecordingSettings(options = {}) {
  const c = component(options, options.t?.('recording.mode', 'Recording mode') ?? 'Recording mode');
  const actions = options.actions ?? {};
  let state = {...options, track: {...options.track}, advanced: normalizeAdvancedRecording(options.advanced)};
  const formatValue = () => ['wav', 'wav32', 'mp3'].includes(state.track.recordingFormat) ? state.track.recordingFormat : null;
  const modeValue = () => modes.includes(state.track.recordingChannels) ? state.track.recordingChannels : 2;
  const mode = c.segmented('mode', [
    {value: 1, label: c.t('mono', 'Mono')}, {value: 2, label: c.t('stereo', 'Stereo')}, {value: 0, label: 'MIDI'},
  ], value => {
    if (state.recording || state.busy || modeValue() === value) return;
    c.commit(actions.setRecordingChannels, {id: state.track.id, value}, () => { state.track.recordingChannels = value; });
  });
  c.row('', mode.element); mode.element.setAttribute('aria-label', c.t('mode', 'Recording mode'));
  const formatOptions = () => [
    {value: null, label: c.t('useAdvanced', 'Use Advanced setting')},
    {value: 'wav', label: 'WAV · 24-bit PCM'}, {value: 'wav32', label: 'WAV · 32-bit float'},
    {value: 'mp3', label: `MP3 · ${state.advanced.bitrate} kbps`},
  ];
  const format = c.choice('format', '', () => formatOptions().map(entry => ({
    label: entry.label, checked: entry.value === formatValue(),
    action: () => {
      if (state.recording || state.busy || modeValue() === 0 || entry.value === formatValue()) return;
      return c.commit(actions.setRecordingFormat, {id: state.track.id, format: entry.value}, () => { state.track.recordingFormat = entry.value; });
    },
  })));
  const formatRow = c.row(c.t('format', 'Format'), format);
  const monitor = c.segmented('monitor', [
    {value: true, label: 'Monitor On'}, {value: false, label: 'Monitor Off'},
  ], enabled => {
    if (modeValue() === 0 || (state.track.inputMonitoring !== false) === enabled) return;
    c.commit(actions.setInputMonitoring, {id: state.track.id, enabled}, () => { state.track.inputMonitoring = enabled; });
  });
  const monitorRow = c.row('', monitor.element);
  monitor.element.setAttribute('aria-label', c.t('monitoring', 'Input monitoring'));
  c.setRenderer(() => {
    const missingTrack = !state.track.id;
    mode.update(modeValue(), missingTrack || c.pending || Boolean(state.recording || state.busy) || typeof actions.setRecordingChannels !== 'function');
    format.textContent = formatOptions().find(entry => entry.value === formatValue()).label;
    format.disabled = missingTrack || c.pending || Boolean(state.recording || state.busy) || typeof actions.setRecordingFormat !== 'function';
    formatRow.hidden = monitorRow.hidden = modeValue() === 0;
    monitor.update(state.track.inputMonitoring !== false, missingTrack || c.pending || typeof actions.setInputMonitoring !== 'function');
  });
  return {element: c.element, update(patch = {}) {
    state = {...state, ...patch, track: patch.track ? {...patch.track} : state.track,
      advanced: patch.advanced ? normalizeAdvancedRecording(patch.advanced) : state.advanced};
    c.changed();
  }, destroy: c.destroy};
}

/** REC Multitrack creation step. onCreate opens the real save/create workflow. */
export function createRecordingProjectStep(options = {}) {
  const c = component(options, 'REC Multitrack');
  const actions = options.actions ?? {};
  let channels = String(options.channels ?? 32);
  const group = c.make('div', 'catlive-recording-channel-input');
  const input = c.control('channels', c.make('input', 'catlive-recording-input'));
  // Text + numeric inputMode avoids mouse-wheel changes to the channel count.
  input.type = 'text'; input.inputMode = 'numeric'; input.pattern = '[0-9]*'; input.value = channels;
  input.setAttribute('aria-label', c.t('channels', 'Channels'));
  const adjust = delta => {
    if (c.pending) return;
    const value = Number(channels);
    if (validRecordingChannelCount(value + delta)) { channels = String(value + delta); input.value = channels; c.changed(); }
  };
  const down = c.button('decrease', '−', () => adjust(-1)); down.setAttribute('aria-label', c.t('fewerChannels', 'Fewer channels'));
  const up = c.button('increase', '+', () => adjust(1)); up.setAttribute('aria-label', c.t('moreChannels', 'More channels'));
  group.append(input, down, up); c.row(c.t('channels', 'Channels'), group);
  const explanation = c.make('p', 'catlive-recording-description',
    c.t('multitrackSummary', 'Mono inputs in sequence, all tracks armed, monitoring off.'));
  c.element.append(explanation);
  const footer = c.make('div', 'catlive-recording-actions');
  const back = c.button('back', c.t('back', 'Back'), () => c.commit(actions.back, {}));
  const create = c.button('create', c.t('createProject', 'Create Project'), () => {
    if (validRecordingChannelCount(channels)) c.commit(actions.createProject, {channels: Number(channels)});
  });
  create.className += ' catlive-recording-primary';
  footer.append(back, create); c.element.append(footer);
  c.listen(input, 'input', () => { if (!c.pending) { channels = input.value; c.changed(); } });
  c.listen(input, 'keydown', event => {
    if (event.key !== 'Enter' || event.repeat || event.isComposing || event.ctrlKey || event.metaKey || event.altKey) return;
    event.preventDefault(); event.stopPropagation();
    if (validRecordingChannelCount(channels)) c.commit(actions.createProject, {channels: Number(channels)});
  });
  c.setRenderer(() => {
    const valid = validRecordingChannelCount(channels);
    input.disabled = c.pending; input.setAttribute('aria-invalid', String(!valid));
    down.disabled = c.pending || !valid || Number(channels) <= 1;
    up.disabled = c.pending || !valid || Number(channels) >= 128;
    create.disabled = c.pending || !valid || typeof actions.createProject !== 'function';
    back.disabled = c.pending || typeof actions.back !== 'function';
  });
  return {element: c.element, update(patch = {}) {
    if (patch.channels !== undefined) { channels = String(patch.channels); input.value = channels; }
    c.changed();
  }, destroy: c.destroy};
}

/** Advanced → Record. Persists Mac MediaProcessingFormat keys through callback. */
export function createAdvancedRecordingSettings(options = {}) {
  const c = component(options, '', 'catlive-recording-inline');
  const callback = options.actions?.setAdvancedRecording;
  let state = normalizeAdvancedRecording(options.value);
  const choose = patch => {
    const value = {...state, ...patch};
    if (Object.keys(patch).every(key => state[key] === value[key])) return;
    return c.commit(callback, value, () => { state = value; });
  };
  const format = c.choice('advanced-format', '', () => formats.map(value => ({
    label: value, checked: state.format === value, action: () => choose({format: value}),
  })));
  c.row(c.t('format', 'Format'), format);
  const bits = c.choice('advanced-bits', '', () => recordingBitDepths.map(value => ({
    label: `${value}-bit PCM`, checked: state.bitDepth === value, action: () => choose({bitDepth: value}),
  })));
  const bitsRow = c.row(c.t('bitDepth', 'Bit depth'), bits);
  const bitrate = c.choice('advanced-bitrate', '', () => recordingMP3Bitrates.map(value => ({
    label: `${value} kbps`, checked: state.bitrate === value, action: () => choose({bitrate: value}),
  })));
  const bitrateRow = c.row(c.t('quality', 'Quality'), bitrate);
  c.setRenderer(() => {
    format.textContent = state.format; bits.textContent = `${state.bitDepth}-bit PCM`; bitrate.textContent = `${state.bitrate} kbps`;
    format.disabled = bits.disabled = bitrate.disabled = c.pending || typeof callback !== 'function';
    bitsRow.hidden = state.format === 'MP3'; bitrateRow.hidden = state.format !== 'MP3';
  });
  return {element: c.element, update(value = {}) { state = normalizeAdvancedRecording(value); c.changed(); }, destroy: c.destroy};
}
