/**
 * Mount the timeline movement lock immediately before the real Add button.
 * Import timeline-lock.css once. This is a control, not a replacement workspace.
 *
 * actions.setTimelineMovementLocked({projectId, sessionId, locked}) must validate
 * the captured document/session before invoking the native session action, and
 * return its {state:{timelineMovementLocked,revision}} result. The adapter owns
 * persistence/history; this component never edits the document optimistically.
 *
 * Feed authoritative project/Undo/Redo notifications through update(). Call
 * reset() for each document load, including reopening the SAME project UUID;
 * sessionId should be the host's unique load/session token. destroy() unmounts.
 */
const mountedLocks = new WeakMap();
const svgNamespace = 'http://www.w3.org/2000/svg';
const validID = value => typeof value === 'string' && value.length > 0;
const validRevision = value => Number.isSafeInteger(value) && value >= 0;
const owns = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

export function mountTimelineLock({addButton, projectId = null, sessionId = projectId,
  locked = false, revision = null, enabled = true, actions = {}, onError, t} = {}) {
  if (!addButton?.ownerDocument || !addButton.parentNode)
    throw new TypeError('The real Add button must be mounted before mounting its timeline lock.');
  mountedLocks.get(addButton)?.destroy();
  const doc = addButton.ownerDocument;
  const button = doc.createElement('button');
  button.type = 'button';
  button.className = 'catlive-timeline-lock';
  button.setAttribute('data-control', 'timeline-movement-lock');
  const svg = doc.createElementNS(svgNamespace, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  const shackle = doc.createElementNS(svgNamespace, 'path');
  const body = doc.createElementNS(svgNamespace, 'rect');
  for (const [key, value] of Object.entries({x: 5, y: 11, width: 14, height: 10, rx: 2}))
    body.setAttribute(key, String(value));
  const keyhole = doc.createElementNS(svgNamespace, 'path');
  keyhole.setAttribute('d', 'M12 15v3');
  svg.append(shackle, body, keyhole);
  button.append(svg);
  addButton.parentNode.insertBefore(button, addButton);

  let context = {projectId, sessionId, locked: locked === true,
    revision: validRevision(revision) ? revision : null, enabled: enabled !== false, actions};
  let generation = 0, authorityVersion = 0, pending = null, destroyed = false;
  const label = (key, fallback) => String(t?.(`timelineLock.${key}`, fallback) ?? fallback);
  function render() {
    const available = context.enabled && validID(context.projectId) && validID(context.sessionId)
      && typeof context.actions?.setTimelineMovementLocked === 'function';
    button.disabled = !available || pending !== null;
    button.setAttribute('aria-label', label('label', 'Bloquear movimento no grid'));
    button.setAttribute('aria-pressed', String(context.locked));
    button.setAttribute('aria-busy', String(pending !== null));
    button.dataset.locked = String(context.locked);
    button.title = context.locked
      ? label('unlock', 'Desbloquear posições e bordas no grid')
      : label('lock', 'Bloquear posições e bordas no grid');
    shackle.setAttribute('d', context.locked ? 'M8 11V7a4 4 0 0 1 8 0v4' : 'M8 11V7a4 4 0 0 1 7.5-2');
  }
  function report(error) {
    // Error presentation is owned by the host; a faulty error callback must not
    // leave the button permanently busy or create an unhandled click promise.
    try { onError?.(error); } catch { /* Host error handling is isolated. */ }
  }
  async function activate(event) {
    if (event.button != null && event.button !== 0) return;
    if (destroyed || button.disabled || pending || !button.isConnected) return;
    const request = Object.freeze({projectId: context.projectId, sessionId: context.sessionId,
      locked: !context.locked});
    const token = {generation, authorityVersion};
    pending = token;
    render();
    try {
      const result = await context.actions.setTimelineMovementLocked(request);
      if (destroyed || generation !== token.generation || pending !== token) return;
      const state = result?.state;
      if (typeof state?.timelineMovementLocked !== 'boolean')
        throw new TypeError('The timeline lock command did not return authoritative session state.');
      if (validRevision(state.revision) && context.revision !== null && state.revision < context.revision) return;
      // An intervening authoritative update wins unless the command response
      // demonstrably belongs to a later native revision.
      if (authorityVersion !== token.authorityVersion && !(validRevision(state.revision)
        && context.revision !== null && state.revision > context.revision)) return;
      context.locked = state.timelineMovementLocked;
      if (validRevision(state.revision)) context.revision = state.revision;
    } catch (error) {
      if (!destroyed && generation === token.generation && pending === token) report(error);
    } finally {
      if (!destroyed && generation === token.generation && pending === token) {
        pending = null;
        render();
      }
    }
  }
  function keydown(event) {
    if (event.repeat && [' ', 'Spacebar', 'Enter'].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }
  function update(values = {}, reset = false) {
    if (destroyed) return;
    const nextProject = owns(values, 'projectId') ? values.projectId : context.projectId;
    const nextSession = owns(values, 'sessionId') ? values.sessionId
      : nextProject !== context.projectId ? nextProject : context.sessionId;
    const changedSession = reset || nextProject !== context.projectId || nextSession !== context.sessionId;
    const previousLocked = context.locked, previousRevision = context.revision;
    if (changedSession) {
      generation += 1;
      pending = null;
      context.locked = false;
      context.revision = null;
    } else if (validRevision(values.revision) && context.revision !== null && values.revision < context.revision) {
      return; // Ignore an out-of-order native state notification.
    }
    context.projectId = nextProject;
    context.sessionId = nextSession;
    if (owns(values, 'locked')) context.locked = values.locked === true;
    if (validRevision(values.revision)) context.revision = values.revision;
    else if (context.locked !== previousLocked) context.revision = null;
    if (changedSession || context.locked !== previousLocked || context.revision !== previousRevision)
      authorityVersion += 1;
    if (owns(values, 'enabled')) context.enabled = values.enabled !== false;
    if (owns(values, 'actions')) context.actions = values.actions;
    render();
  }
  const controller = Object.freeze({
    element: button,
    update,
    reset: values => update(values, true),
    destroy() {
      if (destroyed) return;
      destroyed = true;
      generation += 1;
      pending = null;
      button.removeEventListener('click', activate);
      button.removeEventListener('keydown', keydown);
      button.remove();
      if (mountedLocks.get(addButton) === controller) mountedLocks.delete(addButton);
    },
  });
  button.addEventListener('click', activate);
  button.addEventListener('keydown', keydown);
  mountedLocks.set(addButton, controller);
  render();
  return controller;
}
