// Browser integration with production JS and an entirely intercepted network.
// Requires playwright-core (NODE_PATH may point to an existing installation).
// Optional: PLAYWRIGHT_CHROMIUM_EXECUTABLE=/path/to/chromium node this-file.js
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { chromium } = require('playwright-core')

const root = path.resolve(__dirname, '..')
const base = 'http://192.0.2.10:47831'
const source = fs.readFileSync(path.join(root, 'vsdiretor.js'), 'utf8')
const full = {
  connected: true, projectName: 'Projeto de teste', standby: false,
  runtimeControlActive: false, playing: true, playingId: 'song-1', playPosition: 10,
  regions: [{ id: 'song-1', name: 'Música fixture', start: 0, end: 120 }],
  playlists: [], markers: [],
}
const html = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/stylediretor-app.css"></head><body><div id="app"></div><script src="/vsdiretor.js"></script></body></html>'

async function fixture(browser, role, initial, options = {}) {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } })
  let payload = initial, polls = 0
  const commands = [], errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.addInitScript(({ role, base }) => {
    localStorage.setItem('vshook_selected_mode', role)
    localStorage.setItem('vshook_director_url', base)
  }, { role, base })
  await page.route('**/*', async route => {
    const request = route.request()
    const url = new URL(request.url())
    // No request reaches the LAN, internet or a real project.
    if (url.origin !== base) return route.abort()
    if (url.pathname === '/') return route.fulfill({
      contentType: 'text/html',
      body: options.shell ? fs.readFileSync(path.join(root, 'index.html')) : html,
    })
    if (url.pathname === '/projects' || url.pathname === '/discovery') {
      return route.fulfill({ json: {
        app: 'VS Hook', appName: 'VS Hook Diretor', projectName: 'Projeto de teste',
        projects: [{ id: '0', index: 0, name: 'Projeto de teste', active: true }],
      } })
    }
    if (url.pathname === '/state') {
      polls += 1
      if (polls === 1 && options.firstStateDelayMs) {
        await new Promise(resolve => setTimeout(resolve, options.firstStateDelayMs))
      }
      return route.fulfill({ json: payload })
    }
    if (url.pathname === '/command') {
      commands.push(request.postDataJSON())
      return route.fulfill({ json: { ok: true } })
    }
    if (url.pathname === '/technical-notice') return route.fulfill({ json: { ok: true, enabled: false } })
    if (url.pathname === '/mixer-timeline-cache') return route.fulfill({ json: { ok: true, projects: [] } })
    const file = path.resolve(root, '.' + url.pathname)
    if (file.startsWith(root + path.sep) && fs.existsSync(file) && fs.statSync(file).isFile()) {
      const contentType = file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : 'image/png'
      return route.fulfill({ contentType, body: fs.readFileSync(file) })
    }
    return route.fulfill({ status: 404, body: 'Not found' })
  })
  await page.goto(base)
  return { page, commands, errors, polls: () => polls, set: next => { payload = next } }
}

async function waitFor(check, message, timeout = 7000) {
  const deadline = Date.now() + timeout
  while (!(await check())) {
    assert(Date.now() < deadline, message)
    await new Promise(resolve => setTimeout(resolve, 50))
  }
}

async function run() {
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
  })
  try {
    for (const role of ['director', 'musician']) {
      for (const pageField of ['currentPage', 'activePage', 'activeTab']) {
        const f = await fixture(browser, role, { ...full, [pageField]: 'regions', standby: true, playing: false, regions: [] })
        try {
          await waitFor(() => f.polls() >= 3, 'initial standby should be polled')
          assert.equal(await f.page.locator('.musicListRenderCache .item').count(), 0)
          f.set({ ...full, [pageField]: 'regions' })
          await f.page.locator('.musicListRenderCache .item').first().waitFor({ state: 'visible', timeout: 6000 })
          assert((await f.page.locator('.musicListRenderCache').innerText()).includes('MÚSICA FIXTURE'))
          assert.equal(await f.page.locator('.app').getAttribute('data-active-tab'), 'regions')
          const afterFull = f.polls()
          f.set({ ...full, [pageField]: 'regions', standby: true, playing: false, regions: [] })
          await waitFor(() => f.polls() >= afterFull + 2, 'later standby should arrive')
          assert.equal(await f.page.locator('.musicListRenderCache .item').count(), 1, 'later standby must retain mounted rows')
          if (role === 'director') {
            const enter = f.commands.find(command => command.type === 'director_enter')
            assert(enter, 'authenticated Director must claim the session')
            assert.equal(enter.payload.role, 'director')
            assert.equal(enter.payload.authenticated, true)
            if (pageField === 'currentPage') {
              await waitFor(() => f.commands.some(command => command.type === 'app_heartbeat'), 'Director must keep its heartbeat')
            }
          } else {
            assert.equal(f.commands.length, 0, 'Musician must remain a passive reader')
          }
          assert.deepEqual(f.errors, [])
          console.log(`DOM_OK: ${role} ${pageField}, initial standby -> playing full -> later standby; ${f.polls()} polls`)
        } finally { await f.page.close() }
      }
    }

    // A newly opened password-protected Director must not claim ownership
    // before a valid login, even though GET /state succeeds.
    const hashStart = source.indexOf('  function simpleHash(')
    const hashEnd = source.slice(hashStart + 1).search(/\n  (?:async )?function /)
    const authHash = vm.runInNewContext(source.slice(hashStart, hashStart + 1 + hashEnd) + '; simpleHash("fixture-pass")')
    const f = await fixture(browser, 'director', { ...full, activePage: 'regions', directorAuthEnabled: true, directorAuthHash: authHash })
    try {
      await f.page.locator('#directorPassInput').waitFor({ state: 'visible' })
      await waitFor(() => f.polls() >= 3, 'protected state should be polled')
      assert(!f.commands.some(command => command.type === 'director_enter'))
      await f.page.locator('#directorPassInput').fill('incorrect')
      await f.page.locator('[data-action="auth-login"]').click()
      await f.page.waitForFunction(() => document.querySelector('.authGateError')?.textContent.includes('INVÁLIDA'))
      assert(!f.commands.some(command => command.type === 'director_enter'))
      await f.page.locator('#directorPassInput').fill('fixture-pass')
      await f.page.locator('#directorPassInput').press('Enter')
      await f.page.locator('.musicListRenderCache .item').first().waitFor({ state: 'visible' })
      await waitFor(() => f.commands.some(command => command.type === 'director_enter'), 'valid login should claim Director')
      assert.deepEqual(f.errors, [])
      console.log('DOM_OK: Director authentication preserved; invalid password never claims; valid password loads music')
    } finally { await f.page.close() }

    const delayed = await fixture(browser, 'director', {
      ...full, activePage: 'regions', standby: true, regions: [], playing: false,
    }, { firstStateDelayMs: 1800 })
    try {
      await waitFor(() => delayed.commands.some(command => command.type === 'director_enter'), 'bounded server wait must fit the existing client timeout')
      delayed.set({ ...full, activePage: 'regions' })
      await delayed.page.locator('.musicListRenderCache .item').first().waitFor({ state: 'visible', timeout: 6000 })
      assert.deepEqual(delayed.errors, [])
      console.log('DOM_OK: 1800 ms initial cached response remains inside client timeout; next poll displays refreshed music')
    } finally { await delayed.page.close() }

    for (const role of ['director', 'musician']) {
      const shell = await fixture(browser, role, { ...full, currentPage: 'regions' }, { shell: true })
      try {
        await shell.page.locator(role === 'director' ? '#chooseDirectorBtn' : '#chooseMusicianBtn').click()
        if (role === 'director') {
          await shell.page.locator('#chooseDirectorPhoneBtn').click()
          await shell.page.locator('[data-project-index="0"]').click()
        }
        await shell.page.locator('.musicListRenderCache .item').first().waitFor({ state: 'visible' })
        assert.equal(await shell.page.locator('.app').getAttribute('data-active-tab'), 'regions')
        assert.deepEqual(shell.errors, [])
        if (role === 'musician') assert.equal(shell.commands.length, 0)
        else assert(shell.commands.some(command => command.type === 'set_project_tab'))
        const loadedScript = await shell.page.locator('script[data-vshook-mode-script]').getAttribute('src')
        assert(loadedScript.includes('state-loading-v1'), 'QR shell must request the refreshed client asset')
        console.log(`DOM_OK: QR index -> project discovery -> ${role} -> visible music, refreshed script loaded`)
      } finally { await shell.page.close() }
    }
  } finally { await browser.close() }
}

run().catch(error => { console.error(error); process.exitCode = 1 })
