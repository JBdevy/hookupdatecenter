const VSHOOK_DIRECTOR_PORT = 47831
const VSHOOK_MUSICIANS_PORT = 47832
const VSHOOK_SCAN_TIMEOUT_MS = 650
const appRoot = document.getElementById('app')
let vshookDiscoveredProjects = []
let vshookBridgeBrowserMode = false

function vshookEscape(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function setShell(html) {
  appRoot.innerHTML = `<div class="vshook-shell"><div class="vshook-shell-card">${html}</div></div>`
}

function getLogoHtml() {
  return '<img class="vshook-shell-logo" src="./vshook-icon.png" alt="VS Hook" />'
}

function renderSearching() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Procurando projetos VS Hook disponíveis na rede Wi‑Fi...</p>
    <button class="vshook-secondary-button" id="refreshProjectsBtn">Procurar novamente</button>
  `)
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', () => {
    if (vshookBridgeBrowserMode) startBridgeBrowserMode()
    else startDiscovery()
  })
}

function renderNoProjects() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Nenhum projeto VS Hook foi encontrado.</p>
    <p class="vshook-shell-status">Abra o REAPER, inicie o VS Hook e mantenha o computador e o celular na mesma rede Wi‑Fi.</p>
    <button class="vshook-project-button" id="tryAgainBtn">Procurar</button>
  `)
  document.getElementById('tryAgainBtn')?.addEventListener('click', startDiscovery)
}

function getDefaultMusicianProject(projects) {
  const list = Array.isArray(projects) ? projects.filter(Boolean) : []
  if (!list.length) return null
  return list.find((project) => project.active) || list[0]
}

function renderModeFirst(projects) {
  vshookDiscoveredProjects = Array.isArray(projects) ? projects.slice() : []
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Escolha como vai entrar no VS Hook.</p>
    <div class="vshook-mode-list">
      <button class="vshook-mode-button" id="chooseDirectorBtn">Entrar como Diretor</button>
      <button class="vshook-mode-button" id="chooseMusicianBtn">Entrar como Músico</button>
      <button class="vshook-mode-button" id="chooseRecadosBtn">Entrar como Recados</button>
    </div>
    <button class="vshook-secondary-button" id="refreshProjectsBtn">Procurar novamente</button>
  `)

  document.getElementById('chooseDirectorBtn')?.addEventListener('click', () => {
    if (vshookDiscoveredProjects.length === 1) {
      renderProjects(vshookDiscoveredProjects)
    } else {
      renderProjects(vshookDiscoveredProjects)
    }
  })

  document.getElementById('chooseMusicianBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'musician', { skipProjectSwitch: true })
  })

  document.getElementById('chooseRecadosBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'recados', { skipProjectSwitch: true })
  })

  document.getElementById('refreshProjectsBtn')?.addEventListener('click', () => {
    if (vshookBridgeBrowserMode) startBridgeBrowserMode()
    else startDiscovery()
  })
}

function renderProjects(projects) {
  if (!Array.isArray(projects) || !projects.length) {
    if (vshookBridgeBrowserMode) renderBridgeNoProjects()
    else renderNoProjects()
    return
  }

  const rows = projects.map((project, index) => {
    const name = vshookEscape(project.projectName || project.name || '')
    return `<button class="vshook-project-button" data-project-index="${index}">🎼 ${name}</button>`
  }).join('')

  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">Modo Diretor</h1>
    <p class="vshook-shell-subtitle">Selecione o projeto disponível na rede Wi‑Fi.</p>
    <div class="vshook-project-list">${rows}</div>
    <button class="vshook-back-button" id="backModeBtn">Voltar</button>
    <button class="vshook-secondary-button" id="refreshProjectsBtn">Procurar novamente</button>
  `)

  document.querySelectorAll('[data-project-index]').forEach((button) => {
    button.addEventListener('click', () => {
      const index = Number(button.getAttribute('data-project-index'))
      const selected = projects[index]
      if (selected) enterApp(selected, 'director')
    })
  })

  document.getElementById('backModeBtn')?.addEventListener('click', () => renderModeFirst(vshookDiscoveredProjects))
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', () => {
    if (vshookBridgeBrowserMode) startBridgeBrowserMode()
    else startDiscovery()
  })
}

function renderModeSelection(project) {
  // Mantido por compatibilidade com versões antigas, mas o fluxo atual escolhe o modo antes do projeto.
  renderModeFirst([project].filter(Boolean))
}

function loadModeStyles(mode) {
  document.querySelectorAll('[data-vshook-mode-style]').forEach((el) => el.remove())
  const cssFile = mode === 'recados' ? './recados-app.css' : (mode === 'musician' ? './musicos-app.css' : './stylediretor-app.css')
  const link = document.createElement('link')
  link.rel = 'stylesheet'
  link.href = cssFile
  link.setAttribute('data-vshook-mode-style', mode)
  document.head.appendChild(link)
}

async function enterApp(project, mode, options = {}) {
  try {
    localStorage.setItem('vshook_selected_project', JSON.stringify(project))
    localStorage.setItem('vshook_selected_project_tab_index', String(project.projectTabIndex ?? 0))
    localStorage.setItem('vshook_selected_mode', mode)
    localStorage.setItem('vshook_director_url', project.directorUrl)
    localStorage.setItem('vshook_musicians_url', project.musiciansUrl)
  } catch (error) {}

  const tabIndex = Number(project.projectTabIndex)
  const shouldSwitchProjectTab = mode === 'director' && !options.skipProjectSwitch
  if (shouldSwitchProjectTab && Number.isFinite(tabIndex)) {
    try {
      await fetch(`${project.directorUrl}/command`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'set_project_tab',
          payload: { projectTabIndex: tabIndex, index: tabIndex },
        }),
      })
    } catch (error) {}
  }

  appRoot.innerHTML = ''
  loadModeStyles(mode)

  const script = document.createElement('script')
  script.src = mode === 'recados' ? './recados.js' : (mode === 'musician' ? './vsmusicos.js' : './vsdiretor.js')
  document.body.appendChild(script)
}

function timeoutSignal(ms) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), ms)
  return { signal: controller.signal, cancel: () => clearTimeout(timer) }
}

function normalizeProjectEntry(rawProject, fallbackIndex, baseInfo, ip) {
  const source = rawProject && typeof rawProject === 'object' ? rawProject : { name: rawProject }
  const rawIndex = source.index ?? source.projectTabIndex ?? source.tabIndex ?? source.id ?? fallbackIndex
  const projectTabIndex = Number.isFinite(Number(rawIndex)) ? Number(rawIndex) : fallbackIndex
  const projectName = String(
    source.name ||
    source.projectName ||
    source.title ||
    source.label ||
    baseInfo?.projectName ||
    ''
  ).trim()

  if (!projectName) return null

  return {
    projectName,
    projectId: String(source.id ?? source.projectId ?? source.tabId ?? projectTabIndex),
    projectTabIndex,
    projectPath: source.path || source.projectPath || '',
    active: !!(source.active || source.isCurrent || source.current),
    directorUrl: `http://${ip}:${VSHOOK_DIRECTOR_PORT}`,
    musiciansUrl: `http://${ip}:${VSHOOK_MUSICIANS_PORT}`,
  }
}

function extractProjectList(payload, baseInfo, ip) {
  const candidates = [
    Array.isArray(payload) ? payload : null,
    payload?.projects,
    payload?.projectTabs,
    payload?.openProjects,
    payload?.tabs,
    payload?.reaperProjects,
    payload?.availableProjects,
  ]

  for (const list of candidates) {
    if (!Array.isArray(list) || !list.length) continue
    const normalized = list
      .map((item, index) => normalizeProjectEntry(item, index, baseInfo, ip))
      .filter(Boolean)

    if (normalized.length) return normalized
  }

  const fallback = normalizeProjectEntry({
    name: payload?.projectName || baseInfo?.projectName,
    path: payload?.projectPath || baseInfo?.projectPath,
    active: true,
    index: payload?.activeProjectTabIndex ?? payload?.activeProjectTabId ?? 0,
  }, 0, baseInfo, ip)

  return fallback ? [fallback] : []
}

async function fetchJsonWithTimeout(url, timeoutMs) {
  const t = timeoutSignal(timeoutMs)
  try {
    const response = await fetch(url, {
      cache: 'no-store',
      signal: t.signal,
    })
    if (!response.ok) return null
    return await response.json()
  } catch (error) {
    return null
  } finally {
    t.cancel()
  }
}

async function fetchDiscovery(ip) {
  const baseUrl = `http://${ip}:${VSHOOK_DIRECTOR_PORT}`
  const discovery = await fetchJsonWithTimeout(`${baseUrl}/discovery`, VSHOOK_SCAN_TIMEOUT_MS)
  if (!discovery || discovery.app !== 'VS Hook') return null

  const statePayload =
    await fetchJsonWithTimeout(`${baseUrl}/projects`, VSHOOK_SCAN_TIMEOUT_MS) ||
    await fetchJsonWithTimeout(`${baseUrl}/state`, VSHOOK_SCAN_TIMEOUT_MS) ||
    discovery

  const projects = extractProjectList(statePayload, discovery, ip)
  return projects.length ? projects : null
}

function buildCandidateIps() {
  const subnets = [
    '192.168.0',
    '192.168.1',
    '192.168.2',
    '192.168.15',
    '10.0.0',
    '10.0.1',
    '172.16.0',
  ]
  const ips = []
  for (const subnet of subnets) {
    for (let i = 1; i <= 254; i++) ips.push(`${subnet}.${i}`)
  }
  return ips
}

async function scanInBatches(ips, batchSize = 42) {
  const found = []
  const seen = new Set()
  for (let i = 0; i < ips.length; i += batchSize) {
    const batch = ips.slice(i, i + batchSize)
    const results = await Promise.all(batch.map(fetchDiscovery))
    for (const result of results) {
      const items = Array.isArray(result) ? result : (result ? [result] : [])
      for (const item of items) {
        if (!item) continue
        const key = `${item.directorUrl}|${item.projectTabIndex ?? ''}|${item.projectName}`
        if (seen.has(key)) continue
        seen.add(key)
        found.push(item)
      }
    }
    if (found.length > 0) break
  }
  return found
}


function isBridgeBrowserMode() {
  try {
    const params = new URLSearchParams(window.location.search || '')
    if (params.get('qr') === '1' || params.get('bridge') === '1') return true
    const protocol = String(window.location.protocol || '').toLowerCase()
    const port = Number(window.location.port || 0)
    const host = String(window.location.hostname || '').toLowerCase()
    if (!protocol.startsWith('http')) return false
    if (host === 'localhost' || host === '127.0.0.1') return false
    return port === VSHOOK_DIRECTOR_PORT || port === VSHOOK_MUSICIANS_PORT
  } catch (error) {
    return false
  }
}

function getBridgeBrowserHost() {
  try {
    return String(window.location.hostname || '').trim()
  } catch (error) {
    return ''
  }
}

async function fetchBridgeBrowserProjects() {
  const host = getBridgeBrowserHost()
  if (!host) return []

  const payload =
    await fetchJsonWithTimeout(`${window.location.origin}/projects`, VSHOOK_SCAN_TIMEOUT_MS) ||
    await fetchJsonWithTimeout(`${window.location.origin}/discovery`, VSHOOK_SCAN_TIMEOUT_MS) ||
    await fetchJsonWithTimeout(`${window.location.origin}/state`, VSHOOK_SCAN_TIMEOUT_MS)

  if (!payload) return []
  return extractProjectList(payload, payload, host)
}

function renderBridgeNoProjects() {
  vshookDiscoveredProjects = []
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Nenhum projeto VS Hook foi encontrado.</p>
    <p class="vshook-shell-status">Abra o REAPER, inicie o VS Hook e mantenha o Hook Center aberto.</p>
    <button class="vshook-project-button" id="tryAgainBtn">Atualizar conexão</button>
  `)
  document.getElementById('tryAgainBtn')?.addEventListener('click', startBridgeBrowserMode)
}

async function startBridgeBrowserMode() {
  vshookBridgeBrowserMode = true
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Carregando projeto do Hook Center...</p>
  `)
  const projects = await fetchBridgeBrowserProjects()
  if (projects.length) renderModeFirst(projects)
  else renderBridgeNoProjects()
}

async function startDiscovery() {
  renderSearching()
  const projects = await scanInBatches(buildCandidateIps())
  if (projects.length) renderModeFirst(projects)
  else renderNoProjects()
}

async function keepScreenAwake() {
  try {
    if ('wakeLock' in navigator) window.__vshookWakeLock = await navigator.wakeLock.request('screen')
  } catch (error) {}
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') keepScreenAwake()
})

window.vshookExitToProjectSelector = function () {
  try {
    localStorage.removeItem('vshook_selected_project')
    localStorage.removeItem('vshook_selected_mode')
  } catch (error) {}
  window.location.reload()
}

window.addEventListener('load', () => {
  keepScreenAwake()
  if (isBridgeBrowserMode()) startBridgeBrowserMode()
  else startDiscovery()
})
