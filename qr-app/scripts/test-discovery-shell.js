const fs = require('fs')
const path = require('path')
const vm = require('vm')
const assert = require('node:assert/strict')

const source = fs.readFileSync(path.join(__dirname, '..', 'app-shell.js'), 'utf8')
const storage = new Map()
const fastDiscovery = {
  app: 'VS Hook',
  appName: 'VS Hook Diretor',
  projects: [{ name: 'Teste', index: 0, active: true }],
}
let localNetworkAddressReads = 0
let activeLocalAddresses = ['192.168.77.42']
let respondingHost = '192.168.77.10'
let requestedHosts = []
let pendingRequests = new Set()
let abortedRequests = 0
let fetchOverride = null
let addressOverride = null
const orientationLocks = []
const windowListeners = new Map()
const elements = new Map()

function makeElement() {
  const listeners = new Map()
  return {
    value: '',
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    style: { removeProperty() {}, setProperty() {} },
    dataset: {},
    addEventListener(type, handler) { listeners.set(type, handler) },
    click() { return listeners.get('click')?.() },
    focus() {},
    setAttribute() {},
    removeAttribute() {},
    remove() {},
    appendChild() {},
  }
}

const appElement = makeElement()
let shellHtml = ''
Object.defineProperty(appElement, 'innerHTML', {
  get: () => shellHtml,
  set(html) {
    shellHtml = html
    elements.clear()
    elements.set('app', appElement)
    for (const [, id] of html.matchAll(/id="([^"]+)"/g)) elements.set(id, makeElement())
  },
})
elements.set('app', appElement)

function mockFetch(url, options = {}) {
  const parsedUrl = new URL(url)
  const port = Number(parsedUrl.port)
  requestedHosts.push(parsedUrl.hostname)
  if (fetchOverride) return fetchOverride(url, options)
  const responds = parsedUrl.hostname === respondingHost && port === 47831
  const delay = responds ? 5 : 500
  return new Promise((resolve, reject) => {
    const request = { url, signal: options.signal }
    pendingRequests.add(request)
    const cleanup = () => {
      clearTimeout(timer)
      pendingRequests.delete(request)
      options.signal?.removeEventListener('abort', abort)
    }
    const abort = () => {
      abortedRequests += 1
      cleanup()
      reject(new Error('aborted'))
    }
    const timer = setTimeout(() => {
      cleanup()
      resolve({
        ok: responds,
        json: async () => fastDiscovery,
      })
    }, delay)
    if (options.signal?.aborted) abort()
    else options.signal?.addEventListener('abort', abort, { once: true })
  })
}

const context = {
  console,
  setTimeout,
  clearTimeout,
  AbortController,
  URL,
  URLSearchParams,
  fetch: mockFetch,
  navigator: {},
  localStorage: {
    getItem: (key) => storage.get(key) || null,
    setItem: (key, value) => storage.set(key, String(value)),
    removeItem: (key) => storage.delete(key),
  },
  document: {
    getElementById: (id) => elements.get(id) || null,
    createElement: makeElement,
    querySelectorAll: () => [],
    addEventListener: () => {},
    body: makeElement(),
    head: makeElement(),
    documentElement: makeElement(),
  },
  window: {
    location: {
      protocol: 'capacitor:',
      hostname: 'localhost',
      port: '',
      search: '',
      origin: 'capacitor://localhost',
    },
    Capacitor: {
      isNativePlatform: () => true,
      Plugins: {
        ScreenOrientation: {
          lock: async ({ orientation }) => { orientationLocks.push(orientation) },
          unlock: async () => { throw new Error('O app nativo não deve desbloquear a orientação') },
        },
        VSHookLocalNetwork: {
          getAddresses: async () => {
            localNetworkAddressReads += 1
            if (addressOverride) return addressOverride()
            return { addresses: activeLocalAddresses }
          },
        },
      },
    },
    setTimeout,
    clearTimeout,
    addEventListener(type, handler) {
      const handlers = windowListeners.get(type) || []
      handlers.push(handler)
      windowListeners.set(type, handlers)
    },
  },
}
vm.createContext(context)
vm.runInContext(source, context)

const evaluate = (code) => vm.runInContext(code, context)
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(predicate, message) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) return
    await wait(5)
  }
  throw new Error(message)
}

async function run() {
  await evaluate("setDirectorNativeOrientation('phone')")
  await evaluate("setDirectorNativeOrientation('tablet')")
  assert.deepEqual(orientationLocks, ['portrait', 'landscape'],
    'o app nativo deve manter retrato fora do Diretor Tablet')

  const addresses = await vm.runInContext('getVshookStoreLocalNetworkAddresses()', context)
  if (addresses.length !== 1 || addresses[0] !== '192.168.77.42') {
    throw new Error(`O bridge nativo nao entregou o IP esperado: ${JSON.stringify(addresses)}`)
  }

  const candidates = vm.runInContext('buildVshookStoreCandidateIps(["192.168.77.42"])', context)
  if (!candidates.slice(0, 254).every((ip) => ip.startsWith('192.168.77.'))) {
    throw new Error('A faixa da rede ativa nao ficou em primeiro lugar.')
  }

  storage.set('vshook_director_url', 'http://10.0.0.8:47831')
  storage.set('vshook_musicians_url', 'http://192.168.77.99:47832')
  const candidatesWithHistory = vm.runInContext(
    'buildVshookStoreCandidateIps(["192.168.77.42"])',
    context,
  )
  if (candidatesWithHistory[0] !== '192.168.77.99' ||
      candidatesWithHistory.indexOf('10.0.0.8') < 254) {
    throw new Error('Um IP antigo de outra rede passou na frente do Wi-Fi atual.')
  }
  storage.delete('vshook_director_url')
  storage.delete('vshook_musicians_url')

  const startedAt = Date.now()
  const projects = await vm.runInContext('fetchDiscovery("192.168.77.10", 800)', context)
  const elapsed = Date.now() - startedAt
  if (!Array.isArray(projects) || projects[0]?.projectName !== 'Teste') {
    throw new Error('A primeira porta valida nao retornou a sessao.')
  }
  if (elapsed >= 200) {
    throw new Error(`A descoberta esperou a segunda porta (${elapsed} ms).`)
  }

  const batchStartedAt = Date.now()
  const batchProjects = await vm.runInContext(
    'scanInBatches(["192.168.77.2", "192.168.77.10", "192.168.77.200"])',
    context,
  )
  const batchElapsed = Date.now() - batchStartedAt
  if (!Array.isArray(batchProjects) || batchProjects[0]?.projectName !== 'Teste') {
    throw new Error('A busca em lote não retornou a primeira sessão encontrada.')
  }
  if (batchElapsed >= 200) {
    throw new Error(`A busca em lote esperou os outros IPs (${batchElapsed} ms).`)
  }

  vm.runInContext(`vshookDiscoveredProjects = [{
    projectName: 'Projeto aberto',
    directorUrl: 'http://192.168.77.10:47831',
    musiciansUrl: 'http://192.168.77.10:47832',
    projectTabIndex: 0
  }]`, context)
  vm.runInContext('prepareVSHookModeSelectionAfterReload()', context)
  const restoredProjects = vm.runInContext('consumeVSHookForcedModeSelection()', context)
  if (!Array.isArray(restoredProjects) || restoredProjects[0]?.projectName !== 'Projeto aberto') {
    throw new Error('A saída do app não preservou a tela dos cinco modos.')
  }
  if (vm.runInContext('consumeVSHookForcedModeSelection()', context) !== null) {
    throw new Error('A restauração da tela dos modos deveria ser usada uma única vez.')
  }

  const hasStoreDiscoveryOverride = vm.runInContext(
    'startDiscovery !== vshookStoreDefaultDiscovery',
    context,
  )
  if (!hasStoreDiscoveryOverride) {
    throw new Error('A descoberta automatica exclusiva do app da loja nao foi instalada.')
  }

  activeLocalAddresses = ['192.168.88.42']
  respondingHost = '192.168.88.10'
  requestedHosts = []
  const refreshedProjects = await vm.runInContext(
    'discoverProjectsFromActiveNetwork()',
    context,
  )
  if (!Array.isArray(refreshedProjects) || refreshedProjects[0]?.projectName !== 'Teste') {
    throw new Error('O Atualizar nao repetiu a descoberta pela rede ativa.')
  }
  if (localNetworkAddressReads < 2) {
    throw new Error('O Atualizar nao consultou novamente o endereco do Wi-Fi conectado.')
  }
  if (!requestedHosts.length || requestedHosts.some((host) => !host.startsWith('192.168.88.'))) {
    throw new Error('O Atualizar nao iniciou a busca pela nova faixa do Wi-Fi conectado.')
  }

  assert.equal(pendingRequests.size, 0, 'Ao encontrar a sessão, os demais IPs do lote devem ser abortados.')

  // Cancelamento no meio de um lote não pode testar fallback nem iniciar o próximo lote.
  respondingHost = ''
  requestedHosts = []
  context.testAbort = new AbortController()
  const scan = evaluate('scanInBatches(["192.168.88.1", "192.168.88.2"], 1, testAbort.signal)')
  assert.equal(pendingRequests.size, 1)
  context.testAbort.abort()
  assert.equal((await scan).length, 0)
  await wait(20)
  assert.equal(pendingRequests.size, 0)
  assert.equal(requestedHosts.length, 1, 'Busca cancelada continuou requisitando endpoints ou lotes.')

  // Procurar reinicia pela nova rede e encerra imediatamente as requisições antigas.
  requestedHosts = []
  const oldSearch = evaluate('startDiscovery()')
  await until(() => pendingRequests.size > 0, 'Busca inicial não começou.')
  const abortsBeforeRestart = abortedRequests
  activeLocalAddresses = ['192.168.99.42']
  respondingHost = '192.168.99.10'
  elements.get('searchAgainBtn').click()
  assert.equal(pendingRequests.size, 0, 'Procurar não abortou a busca anterior imediatamente.')
  assert.ok(abortedRequests > abortsBeforeRestart)
  requestedHosts = []
  await oldSearch
  await until(() => shellHtml.includes('Escolha como vai entrar'), 'Nova busca não abriu os modos.')
  assert.ok(requestedHosts.length > 0)
  assert.ok(requestedHosts.every((host) => host.startsWith('192.168.99.')))
  assert.equal(pendingRequests.size, 0)

  // Simula um corpo JSON que ainda resolve após abort: Voltar precisa vencer a resposta tardia.
  let deliverPayload
  fetchOverride = async () => ({
    ok: true,
    json: () => new Promise((resolve) => { deliverPayload = resolve }),
  })
  const refresh = evaluate('refreshProjectSelector()')
  await until(() => !!deliverPayload, 'Atualizar não solicitou a sessão.')
  elements.get('backModeBtn').click()
  const deviceScreen = shellHtml
  assert.ok(deviceScreen.includes('Escolha em qual dispositivo'))
  deliverPayload(fastDiscovery)
  await refresh
  assert.equal(shellHtml, deviceScreen, 'Resposta tardia substituiu a tela após Voltar.')
  fetchOverride = null

  // O plugin nativo não oferece abort; sua resposta atrasada não deve iniciar uma varredura.
  let deliverAddresses
  addressOverride = () => new Promise((resolve) => { deliverAddresses = resolve })
  requestedHosts = []
  const addressRefresh = evaluate('refreshProjectSelector()')
  await until(() => !!deliverAddresses, 'O plugin de rede não foi consultado.')
  elements.get('backModeBtn').click()
  deliverAddresses({ addresses: ['192.168.77.42'] })
  await addressRefresh
  assert.equal(requestedHosts.length, 0, 'Consulta nativa cancelada iniciou uma varredura.')
  addressOverride = null

  // Entrar pelo IP cancela a descoberta automática e também um Procurar já agendado.
  respondingHost = ''
  const automatic = evaluate('startDiscovery()')
  await until(() => pendingRequests.size > 0, 'Busca automática não iniciou.')
  elements.get('searchAgainBtn').click()
  elements.get('manualIpInput').value = '192.168.99.10'
  respondingHost = '192.168.99.10'
  requestedHosts = []
  await evaluate('attemptManualIpEntry()')
  await automatic
  const manualScreen = shellHtml
  const manualRequests = requestedHosts.length
  await wait(160)
  assert.equal(shellHtml, manualScreen)
  assert.equal(requestedHosts.length, manualRequests, 'Busca agendada sobreviveu à entrada pelo IP.')
  assert.ok(requestedHosts.every((host) => host === respondingHost))
  assert.equal(pendingRequests.size, 0)

  // A busca de navegador/QR compartilha o mesmo ciclo, mas usa somente a origem do bridge.
  context.window.Capacitor.isNativePlatform = () => false
  context.window.location = {
    protocol: 'http:', hostname: '192.168.99.10', port: '47831',
    origin: 'http://192.168.99.10:47831', search: '?bridge=1',
  }
  requestedHosts = []
  await evaluate('startBridgeBrowserMode()')
  assert.ok(shellHtml.includes('Escolha como vai entrar'))
  assert.deepEqual(requestedHosts, ['192.168.99.10'])

  // Sair para outro modo cancela o Atualizar do bridge e não remonta a tela depois.
  respondingHost = ''
  const bridgeRefresh = evaluate('refreshProjectSelector()')
  await until(() => pendingRequests.size > 0, 'Atualizar do bridge não iniciou.')
  await evaluate(`enterApp({projectName: 'Teste', projectTabIndex: 0,
    directorUrl: 'http://192.168.99.10:47831', musiciansUrl: 'http://192.168.99.10:47832'},
    'musician', {skipProjectSwitch: true})`)
  await bridgeRefresh
  assert.equal(pendingRequests.size, 0)
  assert.equal(shellHtml, '', 'Resposta do bridge substituiu o modo já aberto.')

  // Navegador comum também cancela o probe salvo antes de entrar na varredura completa.
  evaluate('vshookBridgeBrowserMode = false')
  requestedHosts = []
  const browserSearch = evaluate('startDiscovery()')
  await until(() => pendingRequests.size > 0, 'Probe salvo do navegador não iniciou.')
  for (const handler of windowListeners.get('pagehide') || []) handler()
  await browserSearch
  await wait(20)
  assert.equal(pendingRequests.size, 0)
  assert.equal(requestedHosts.length, 1, 'Sair da página deixou a busca do navegador continuar.')

  console.log('Cancelamento ok: lotes, Procurar, Wi-Fi trocado, Voltar, JSON/plugin tardios, IP manual, modos, bridge e pagehide.')

  console.log(`Discovery automática ok: ${addresses[0]}, resposta em ${batchElapsed} ms.`)
}

run().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
