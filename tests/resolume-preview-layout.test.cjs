// Run with node_modules/electron/dist/electron.exe (ELECTRON_RUN_AS_NODE unset).
// Hidden test window only: does not load the application or start its services.
const { app, BrowserWindow } = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

app.whenReady().then(async () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/renderer.js'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '../src/styles.css'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, '../src/index.html'), 'utf8');
  const header = html.match(/<div class="hook-marker-preview-head resolume-tool-preview-head"[^>]*>[\s\S]*?<\/div>/)[0];
  const list = { innerHTML: '' };
  const context = vm.createContext({
    $: (selector) => selector === '#resolumeToolPreviewList' ? list : {},
    escapeHtml: (value) => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;'),
    hookMarkerState: { connected: true, resolumeMap: { created: true, cues: [{
      deck: 1, column: 1, sourceType: 'region_start', timecode: '00:01:20.00',
      deckName: 'Uma música com um nome muito longo '.repeat(12),
      columnName: 'Início de uma música com um nome longo '.repeat(12)
    }] } }
  });
  vm.runInContext(source.slice(source.indexOf('function renderResolumeToolPreview()'),
    source.indexOf('function renderHookMarkerRuntimeState(')), context);
  vm.runInContext('renderResolumeToolPreview()', context);
  const window = new BrowserWindow({ show: false, webPreferences: { contextIsolation: true } });
  await window.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
    `<style>${css}\nbody { display:block; margin:0; padding:12px; }</style>` +
    `<section class="card resolume-tool-preview-card">${header}<div class="hook-marker-preview-list">${list.innerHTML}</div></section>`));
  for (const width of [1200, 940, 720, 600, 360]) {
    window.setContentSize(width, 600);
    const state = await window.webContents.executeJavaScript(`new Promise(resolve => requestAnimationFrame(() => {
      const row = document.querySelector('.resolume-tool-preview-item');
      const head = document.querySelector('.resolume-tool-preview-head');
      const rect = el => { const r = el.getBoundingClientRect(); return {left:r.left, right:r.right, width:r.width}; };
      const name = row.children[0];
      resolve({
        viewport: innerWidth, row: rect(row), music: rect(name),
        ellipsis: getComputedStyle(name).textOverflow,
        clipped: name.scrollWidth > name.clientWidth,
        title: name.title === name.textContent,
        headerVisible: getComputedStyle(head).display !== 'none',
        headers: [...head.children].map(rect),
        cells: [...row.children].map(rect)
      });
    }))`);
    assert(state.row.right <= state.viewport, `row overflow at ${width}`);
    assert.equal(state.ellipsis, 'ellipsis');
    assert(state.clipped && state.title, `long name must truncate, keeping full tooltip at ${width}`);
    if (state.headerVisible) {
      assert(state.music.width <= 240, `music column too wide at ${width}`);
      assert(state.headers[1].width >= 100, 'Marcadores needs room for its label');
      for (let index = 1; index < 4; index++) {
        assert(state.headers[index].left - state.headers[index - 1].right >= 9);
        assert(state.cells[index].left - state.cells[index - 1].right >= 9);
      }
    }
  }
  window.destroy();
  console.log('RESOLUME_PREVIEW_LAYOUT_OK: five window widths; bounded music column, separate labels, long names truncated with full tooltip');
  app.quit();
}).catch(error => {
  console.error(error);
  app.exit(1);
});
