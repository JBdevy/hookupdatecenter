const VSHOOK_DIRECTOR_PORT = 47831
const VSHOOK_MUSICIANS_PORT = 47832
const VSHOOK_SCAN_TIMEOUT_MS = 650
const VSHOOK_SAVED_PROBE_TIMEOUT_MS = 650
const VSHOOK_MANUAL_IP_TIMEOUT_MS = 2800
const VSHOOK_SCAN_BATCH_SIZE = 72
const appRoot = document.getElementById('app')
let vshookDiscoveredProjects = []
let vshookBridgeBrowserMode = false
let vshookDiscoveryRunId = 0
let vshookProjectsRefreshRunId = 0

function vshookEscape(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}


function isVSHookFakeProjectName(value) {
  const name = String(value || '').trim().toLowerCase()
  if (!name) return true
  const compact = name.replace(/\s+/g, ' ')
  return compact === 'projeto 1'
    || compact === 'project 1'
    || compact === 'projeto vs hook'
    || compact === 'vs hook'
    || compact === 'demo'
    || compact === 'projeto demo'
}

function isVSHookRealProject(project) {
  if (!project || typeof project !== 'object') return false
  const name = project.projectName || project.name || project.title || project.label || ''
  if (isVSHookFakeProjectName(name)) return false
  return true
}

function setShell(html) {
  appRoot.innerHTML = `<div class="vshook-shell"><div class="vshook-shell-card">${html}</div></div>`
}

function getLogoHtml() {
  return '<img class="vshook-shell-logo" src="./vshook-icon.png" alt="VS Hook" />'
}

function renderManualIpBox() {
  return `
    <div class="vshook-manual-ip-box">
      <input class="vshook-manual-ip-input" id="manualIpInput" inputmode="decimal" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="IP do computador. Ex: 192.168.0.10" />
      <button class="vshook-secondary-button" id="manualIpBtn">Entrar pelo IP</button>
    </div>
  `
}

function attachManualIpHandler() {
  document.getElementById('manualIpBtn')?.addEventListener('click', () => attemptManualIpEntry())
  document.getElementById('manualIpInput')?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') attemptManualIpEntry()
  })
}

function renderSearching() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Procurando projetos VS Hook disponíveis na rede Wi‑Fi...</p>
    <p class="vshook-shell-status">A busca continua em segundo plano. Se preferir, digite o IP do computador agora.</p>
    ${renderManualIpBox()}
  `)
  attachManualIpHandler()
}

function renderNoProjects() {
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Nenhum projeto VS Hook foi encontrado.</p>
    <p class="vshook-shell-status">Abra o REAPER, inicie o VS Hook e mantenha o computador e o celular na mesma rede Wi‑Fi.</p>
    ${renderManualIpBox()}
  `)
  attachManualIpHandler()
}

function getDefaultMusicianProject(projects) {
  const list = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  if (!list.length) return null
  return list.find((project) => project.active) || list[0]
}

function renderModeFirst(projects) {
  vshookDiscoveredProjects = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Escolha como vai entrar no VS Hook.</p>
    <div class="vshook-mode-list">
      <button class="vshook-mode-button" id="chooseDirectorBtn">Entrar como Diretor</button>
      <button class="vshook-mode-button" id="chooseMusicianBtn">Entrar como Músico</button>
      <button class="vshook-mode-button" id="chooseRecadosBtn">Entrar como Recados</button>
    </div>
  `)

  document.getElementById('chooseDirectorBtn')?.addEventListener('click', () => {
    renderProjects(vshookDiscoveredProjects)
  })

  document.getElementById('chooseMusicianBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'musician', { skipProjectSwitch: true })
  })

  document.getElementById('chooseRecadosBtn')?.addEventListener('click', () => {
    const selected = getDefaultMusicianProject(vshookDiscoveredProjects)
    if (selected) enterApp(selected, 'recados', { skipProjectSwitch: true })
  })

}


async function refreshProjectSelector() {
  const runId = ++vshookProjectsRefreshRunId
  const currentProjects = Array.isArray(vshookDiscoveredProjects) ? vshookDiscoveredProjects.slice() : []
  renderProjects(currentProjects, { loading: true })

  let projects = []
  if (vshookBridgeBrowserMode) {
    projects = await fetchBridgeBrowserProjects()
  } else {
    const savedProjects = await probeStoredBridgeHosts()
    projects = savedProjects.length ? savedProjects : await scanInBatches(buildCandidateIps())
  }

  if (runId !== vshookProjectsRefreshRunId) return

  if (projects && projects.length) {
    renderProjects(projects, { status: 'Projetos atualizados.' })
  } else {
    renderProjects(currentProjects, { status: 'Nenhum projeto novo encontrado.' })
  }
}

function renderProjects(projects, options = {}) {
  const list = Array.isArray(projects) ? projects.filter(isVSHookRealProject) : []
  vshookDiscoveredProjects = list.slice()
  const loading = options && options.loading
  const status = options && options.status
  const rows = list.map((project, index) => {
    const name = vshookEscape(project.projectName || project.name || project.projectPath || '')
    return `<button class="vshook-project-button" data-project-index="${index}">🎼 ${name}</button>`
  }).join('')

  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">Modo Diretor</h1>
    <p class="vshook-shell-subtitle">Selecione o projeto disponível na rede Wi‑Fi.</p>
    <div class="vshook-project-list">${rows}</div>
    ${status ? `<p class="vshook-shell-status">${vshookEscape(status)}</p>` : ''}
    <div class="vshook-project-actions">
      <button class="vshook-back-button" id="backModeBtn">Voltar</button>
      <button class="vshook-secondary-button" id="refreshProjectsBtn" ${loading ? 'disabled' : ''}>${loading ? 'Atualizando...' : 'Atualizar'}</button>
    </div>
  `)

  document.querySelectorAll('[data-project-index]').forEach((button) => {
    button.addEventListener('click', () => {
      const index = Number(button.getAttribute('data-project-index'))
      const selected = list[index]
      if (selected) enterApp(selected, 'director')
    })
  })

  document.getElementById('backModeBtn')?.addEventListener('click', () => renderModeFirst(vshookDiscoveredProjects))
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', refreshProjectSelector)
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
  script.src = (mode === 'recados' ? './recados.js' : (mode === 'musician' ? './vsmusicos.js' : './vsdiretor.js')) + '?v=selecao-cores-borda-tema-1781928600'
  document.body.appendChild(script)
}

function timeoutSignal(ms) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), ms)
  return { signal: controller.signal, cancel: () => clearTimeout(timer) }
}

function normalizeIp(value) {
  const text = String(value || '').trim()
  const parts = text.split('.').map((part) => Number(part))
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return ''
  if (parts[0] === 0 || parts[0] === 127 || parts[3] === 0 || parts[3] === 255) return ''
  return parts.join('.')
}

function parseBridgeAddress(value) {
  let text = String(value || '').trim()
  if (!text) return { ip: '', port: null }
  text = text.replace(/^https?:\/\//i, '')
  text = text.replace(/\/.*$/, '')
  const match = text.match(/^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$/)
  if (!match) return { ip: '', port: null }
  const ip = normalizeIp(match[1])
  const port = match[2] ? Number(match[2]) : null
  if (!ip) return { ip: '', port: null }
  if (port != null && (!Number.isInteger(port) || port < 1 || port > 65535)) return { ip: '', port: null }
  return { ip, port }
}

async function attemptManualIpEntry() {
  const input = document.getElementById('manualIpInput')
  const parsed = parseBridgeAddress(input?.value || '')
  const ip = parsed.ip
  if (!ip) {
    if (input) input.focus()
    return
  }

  const runId = ++vshookDiscoveryRunId
  setShell(`
    ${getLogoHtml()}
    <h1 class="vshook-shell-title">VS Hook</h1>
    <p class="vshook-shell-subtitle">Conectando no IP informado...</p>
    <p class="vshook-shell-status">${vshookEscape(parsed.port ? `${ip}:${parsed.port}` : ip)}</p>
  `)

  const projects = await fetchDiscovery(ip, VSHOOK_MANUAL_IP_TIMEOUT_MS, parsed.port)
  if (runId !== vshookDiscoveryRunId) return
  if (projects && projects.length) {
    renderModeFirst(projects)
  } else {
    renderNoProjects()
    const nextInput = document.getElementById('manualIpInput')
    if (nextInput) {
      nextInput.value = parsed.port ? `${ip}:${parsed.port}` : ip
      nextInput.focus()
    }
  }
}

function hostFromUrl(value) {
  try {
    return normalizeIp(new URL(String(value || '')).hostname)
  } catch (error) {
    return parseBridgeAddress(value).ip
  }
}

function subnetFromIp(ip) {
  const clean = normalizeIp(ip)
  if (!clean) return ''
  const parts = clean.split('.')
  return `${parts[0]}.${parts[1]}.${parts[2]}`
}

function uniquePush(list, seen, value) {
  const text = String(value || '').trim()
  if (!text || seen.has(text)) return
  seen.add(text)
  list.push(text)
}

function getStoredBridgeHosts() {
  const hosts = []
  const seen = new Set()
  try {
    const directorUrl = localStorage.getItem('vshook_director_url')
    const musiciansUrl = localStorage.getItem('vshook_musicians_url')
    uniquePush(hosts, seen, hostFromUrl(directorUrl))
    uniquePush(hosts, seen, hostFromUrl(musiciansUrl))
    const project = JSON.parse(localStorage.getItem('vshook_selected_project') || 'null')
    uniquePush(hosts, seen, hostFromUrl(project?.directorUrl))
    uniquePush(hosts, seen, hostFromUrl(project?.musiciansUrl))
    uniquePush(hosts, seen, hostFromUrl(project?.host))
    uniquePush(hosts, seen, hostFromUrl(project?.lanHost))
  } catch (error) {}
  return hosts
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

function getPortsToTry(preferredPort) {
  const ports = []
  const seen = new Set()
  function push(port) {
    const value = Number(port)
    if (!Number.isInteger(value) || value < 1 || value > 65535 || seen.has(value)) return
    seen.add(value)
    ports.push(value)
  }
  push(preferredPort)
  push(VSHOOK_DIRECTOR_PORT)
  push(VSHOOK_MUSICIANS_PORT)
  return ports
}

async function fetchDiscoveryOnPort(ip, port, timeoutMs = VSHOOK_SCAN_TIMEOUT_MS) {
  const cleanIp = normalizeIp(ip)
  if (!cleanIp) return null
  const baseUrl = `http://${cleanIp}:${port}`

  const discovery =
    await fetchJsonWithTimeout(`${baseUrl}/discovery`, timeoutMs) ||
    await fetchJsonWithTimeout(`${baseUrl}/discovery.json`, timeoutMs) ||
    null

  const projectsPayload =
    await fetchJsonWithTimeout(`${baseUrl}/projects`, timeoutMs) ||
    await fetchJsonWithTimeout(`${baseUrl}/projects.json`, timeoutMs) ||
    await fetchJsonWithTimeout(`${baseUrl}/state`, timeoutMs) ||
    await fetchJsonWithTimeout(`${baseUrl}/state.json`, timeoutMs) ||
    discovery

  if (!discovery && !projectsPayload) return null

  const isVsHook =
    discovery?.app === 'VS Hook' ||
    projectsPayload?.app === 'VS Hook' ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('diretor') ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('músicos') ||
    String(discovery?.appName || projectsPayload?.appName || '').toLowerCase().includes('musicos')

  const projects = extractProjectList(projectsPayload || discovery, discovery || projectsPayload, cleanIp)
  if (!projects.length) return null
  if (!isVsHook && !projects.some((project) => project.projectName)) return null
  return projects
}

async function fetchDiscovery(ip, timeoutMs = VSHOOK_SCAN_TIMEOUT_MS, preferredPort = null) {
  const cleanIp = normalizeIp(ip)
  if (!cleanIp) return null
  for (const port of getPortsToTry(preferredPort)) {
    const projects = await fetchDiscoveryOnPort(cleanIp, port, timeoutMs)
    if (projects && projects.length) return projects
  }
  return null
}

async function probeStoredBridgeHosts() {
  const storedHosts = getStoredBridgeHosts()
  for (const ip of storedHosts) {
    const projects = await fetchDiscovery(ip, VSHOOK_SAVED_PROBE_TIMEOUT_MS)
    if (projects && projects.length) return projects
  }
  return []
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
  if (isVSHookFakeProjectName(projectName)) return null

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

function buildCandidateIps() {
  const ips = []
  const seenIps = new Set()
  const seenSubnets = new Set()
  const prioritySubnets = []
  const secondarySubnets = []

  const storedHosts = getStoredBridgeHosts()
  for (const host of storedHosts) {
    uniquePush(ips, seenIps, host)
    uniquePush(prioritySubnets, seenSubnets, subnetFromIp(host))
  }

  // Faixas comuns em roteadores. Não fixa IP específico de cliente; o usuário
  // pode entrar manualmente pelo IP enquanto a varredura continua.
  ;[
    '192.168.0', '192.168.1', '192.168.100', '192.168.10', '192.168.15',
    '192.168.2', '192.168.3', '192.168.4', '192.168.5', '192.168.11',
    '192.168.18', '192.168.20', '192.168.25', '192.168.31', '192.168.50',
    '192.168.68', '192.168.86', '192.168.88', '192.168.101', '192.168.102',
    '10.0.0', '10.0.1', '10.1.1', '10.10.0', '172.16.0', '172.16.1'
  ].forEach((subnet) => uniquePush(prioritySubnets, seenSubnets, subnet))

  const common192 = [43, 49, 56, 168, 254]
  common192.forEach((n) => uniquePush(secondarySubnets, seenSubnets, `192.168.${n}`))
  for (let n = 2; n <= 10; n += 1) uniquePush(secondarySubnets, seenSubnets, `10.0.${n}`)
  ;['10.10.10', '10.100.0'].forEach((subnet) => uniquePush(secondarySubnets, seenSubnets, subnet))
  for (let n = 17; n <= 31; n += 1) {
    uniquePush(secondarySubnets, seenSubnets, `172.${n}.0`)
    uniquePush(secondarySubnets, seenSubnets, `172.${n}.1`)
  }

  // Primeiro testa hosts comuns em TODAS as sub-redes; só depois faz a varredura completa.
  const preferredHosts = [1, 2, 10, 11, 15, 20, 30, 50, 80, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 120, 150, 180, 200, 220, 254]
  for (const subnet of prioritySubnets) {
    for (const host of preferredHosts) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of prioritySubnets) {
    for (let host = 1; host <= 254; host += 1) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of secondarySubnets) {
    for (const host of preferredHosts) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }
  for (const subnet of secondarySubnets) {
    for (let host = 1; host <= 254; host += 1) uniquePush(ips, seenIps, `${subnet}.${host}`)
  }

  return ips
}

async function scanInBatches(ips, batchSize = VSHOOK_SCAN_BATCH_SIZE) {
  const found = []
  const seen = new Set()
  for (let i = 0; i < ips.length; i += batchSize) {
    const batch = ips.slice(i, i + batchSize)
    const results = await Promise.all(batch.map((ip) => fetchDiscovery(ip)))
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
    <button class="vshook-secondary-button" id="refreshProjectsBtn">Atualizar</button>
  `)
  document.getElementById('refreshProjectsBtn')?.addEventListener('click', startBridgeBrowserMode)
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
  const runId = ++vshookDiscoveryRunId
  renderSearching()
  const savedProjects = await probeStoredBridgeHosts()
  if (runId !== vshookDiscoveryRunId) return
  if (savedProjects.length) {
    renderModeFirst(savedProjects)
    return
  }
  const projects = await scanInBatches(buildCandidateIps())
  if (runId !== vshookDiscoveryRunId) return
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


function getVSHookModeSelectionFallbackProjects() {
  const projects = []
  const seen = new Set()
  const addProject = (project) => {
    if (!project || typeof project !== 'object') return
    if (!isVSHookRealProject(project)) return
    const directorUrl = String(project.directorUrl || '').replace(/\/+$/, '')
    const musiciansUrl = String(project.musiciansUrl || '').replace(/\/+$/, '')
    if (!directorUrl && !musiciansUrl) return
    const key = `${directorUrl}|${musiciansUrl}|${project.projectTabIndex ?? ''}|${project.projectName || project.name || ''}`
    if (seen.has(key)) return
    seen.add(key)
    projects.push({ ...project, directorUrl, musiciansUrl })
  }

  try {
    if (Array.isArray(vshookDiscoveredProjects)) vshookDiscoveredProjects.forEach(addProject)
  } catch (error) {}

  try {
    const selected = JSON.parse(localStorage.getItem('vshook_selected_project') || 'null')
    addProject(selected)
  } catch (error) {}

  try {
    const cached = JSON.parse(localStorage.getItem('vshook_cached_mode_projects') || '[]')
    if (Array.isArray(cached)) cached.forEach(addProject)
  } catch (error) {}

  // Não cria mais projeto fake usando apenas URLs antigas do localStorage.
  // Se não veio projeto real do Hook Center/Lua, a lista fica vazia.

  return projects
}

function prepareVSHookModeSelectionAfterReload() {
  const projects = getVSHookModeSelectionFallbackProjects()
  try {
    localStorage.setItem('vshook_force_mode_selection', '1')
    localStorage.setItem('vshook_cached_mode_projects', JSON.stringify(projects))
  } catch (error) {}
  return projects
}

function consumeVSHookForcedModeSelection() {
  try {
    if (localStorage.getItem('vshook_force_mode_selection') !== '1') return null
    localStorage.removeItem('vshook_force_mode_selection')
    const cached = JSON.parse(localStorage.getItem('vshook_cached_mode_projects') || '[]')
    return Array.isArray(cached) ? cached : []
  } catch (error) {
    return null
  }
}

window.vshookExitToProjectSelector = function () {
  prepareVSHookModeSelectionAfterReload()
  try {
    localStorage.removeItem('vshook_selected_project')
    localStorage.removeItem('vshook_selected_mode')
    localStorage.removeItem('vshook_access_session')
  } catch (error) {}
  window.location.reload()
}

window.addEventListener('load', () => {
  keepScreenAwake()
  const forcedModeProjects = consumeVSHookForcedModeSelection()
  if (forcedModeProjects && forcedModeProjects.length) {
    renderModeFirst(forcedModeProjects)
    return
  }
  if (isBridgeBrowserMode()) startBridgeBrowserMode()
  else startDiscovery()
})
