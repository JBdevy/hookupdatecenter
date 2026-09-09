// Relogio local da barra de progresso.
//
// O Bridge responde a cada 300ms e sempre com atraso variavel de rede. Enquanto
// a barra usava a porcentagem dele como base, cada resposta puxava a barra para
// o valor recebido — as vezes para tras, e logo depois correndo para recuperar.
// Este teste roda um Bridge falso com atraso oscilando entre 30ms e 150ms e
// cobra o que o operador enxerga: a barra nunca volta, nunca da arranco, e
// mesmo assim nao se descola do tempo real da musica.

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const sourcePath = path.resolve(__dirname, '..', 'vsdiretor.js')
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n')

function extract(name) {
  const startAt = source.indexOf('  function ' + name + '(')
  assert(startAt >= 0, 'funcao ausente: ' + name)
  const next = source.slice(startAt + 1).indexOf('\n  function ')
  assert(next >= 0, 'fim da funcao ausente: ' + name)
  return source.slice(startAt, startAt + 1 + next)
}

for (const constante of ['BAR_CLOCK_SNAP_SEC', 'BAR_CLOCK_EASE_SEC']) {
  assert(source.includes('const ' + constante + ' ='),
    'constante do relogio ausente: ' + constante)
}

const DURATION = 180
let clockMs = 0
let bridgePercent = 0

const context = vm.createContext({
  Math, Number, String,
  BAR_CLOCK_SNAP_SEC: 1.2,
  BAR_CLOCK_EASE_SEC: 0.25,
  barClockKey: '',
  barClockPercent: 0,
  barClockAtMs: 0,
  now: () => clockMs,
  isPlaying: () => true,
  isPaused: () => false,
  clampPercent: (value) => Math.max(0, Math.min(100, Number(value) || 0)),
  getVisualPlayingId: () => 'musica-1',
  getVisualPlayingDurationSec: () => DURATION,
  getVisualPlaybackProgressPercent: () => bridgePercent,
})
vm.runInContext(extract('getSmoothBarProgressPercent'), context)

function read(sampledAt) {
  clockMs = sampledAt
  return vm.runInContext(`getSmoothBarProgressPercent({}, ${sampledAt})`, context)
}

// Ancora inicial: com o relogio zerado a barra assume o valor do Bridge.
bridgePercent = 0
read(0)

const FRAME_MS = 16
const TOTAL_MS = 12000
const latencias = [30, 90, 150, 60, 120, 45]
let proximoPollEm = 300
let poll = 0
let anterior = read(0)
let maiorRecuo = 0
let maiorSalto = 0
let maiorDescolamento = 0

for (let t = FRAME_MS; t <= TOTAL_MS; t += FRAME_MS) {
  // O Bridge so fala de 300 em 300ms, e sempre sobre um instante ja passado.
  if (t >= proximoPollEm) {
    const atraso = latencias[poll % latencias.length]
    bridgePercent = ((t - atraso) / 1000 / DURATION) * 100
    proximoPollEm += 300
    poll += 1
  }
  const atual = read(t)
  const verdade = (t / 1000 / DURATION) * 100

  maiorRecuo = Math.max(maiorRecuo, anterior - atual)
  maiorSalto = Math.max(maiorSalto, atual - anterior)
  maiorDescolamento = Math.max(maiorDescolamento, Math.abs(atual - verdade))
  anterior = atual
}

assert(poll > 30, 'a simulacao precisa exercitar varios polls, rodou ' + poll)

// 1. A barra nunca volta. Era o "vai e volta".
assert.equal(maiorRecuo, 0,
  'a barra andou para tras ' + maiorRecuo.toFixed(4) + '%')

// 2. Nenhum quadro avanca muito mais do que o proprio tempo do quadro. Era a
//    "aceleracao": depois de saltar para tras a barra corria para recuperar.
const avancoNormal = (FRAME_MS / 1000 / DURATION) * 100
assert(maiorSalto < avancoNormal * 2.2,
  'a barra deu arranco de ' + maiorSalto.toFixed(5) +
  '%, mais que o dobro do avanco normal de ' + avancoNormal.toFixed(5) + '%')

// 3. Suavizar nao pode virar atraso: a barra segue colada no tempo real.
const descolamentoSec = (maiorDescolamento / 100) * DURATION
assert(descolamentoSec < 0.35,
  'a barra ficou ' + descolamentoSec.toFixed(3) + 's fora do tempo real')

// 4. Um seek de verdade nao pode ser diluido: ali a barra tem que pular.
bridgePercent = 50
const depoisDoSeek = read(TOTAL_MS + FRAME_MS)
assert(Math.abs(depoisDoSeek - 50) < 0.5,
  'seek deveria reancorar a barra de vez, ficou em ' + depoisDoSeek.toFixed(3) + '%')


// ---------------------------------------------------------------------------
// Cursor do painel Grid. Mesmo Bridge instavel, mesma cobranca — so que aqui a
// conta e em segundos da linha do tempo, nao em porcentagem.

for (const constante of ['SEEK_CLOCK_SNAP_SEC', 'SEEK_CLOCK_EASE_SEC']) {
  assert(source.includes('const ' + constante + ' ='),
    'constante do relogio do Grid ausente: ' + constante)
}

// O arraste do dedo e as retencoes de Play/Pause nao podem passar pelo
// relogio: elas ja tem caminho proprio e suavizar ali seria arrastar o dedo
// contra uma mola.
const cursorPosBlock = extract('getTransportSeekCursorPos')
assert.match(cursorPosBlock,
  /let playPos = getSmoothSeekPlayPositionSec\(data, sampledAt, target\)/,
  'o cursor do Grid deve andar pelo relogio local')
const suavizadoAt = cursorPosBlock.indexOf('getSmoothSeekPlayPositionSec')
const arrasteAt = cursorPosBlock.indexOf('state.transportSeekDragging')
assert(arrasteAt > suavizadoAt,
  'o arraste deve continuar depois, num caminho separado do relogio')

let relogioMs = 0
let posBridge = 0
const gridContext = vm.createContext({
  Math, Number, String,
  SEEK_CLOCK_SNAP_SEC: 1.2,
  SEEK_CLOCK_EASE_SEC: 0.25,
  seekClockKey: '',
  seekClockPosSec: 0,
  seekClockAtMs: 0,
  now: () => relogioMs,
  isPlaying: () => true,
  isPaused: () => false,
  getVisualPlayingId: () => 'musica-1',
  getSmoothedCurrentPlaybackPosition: () => posBridge,
})
vm.runInContext(extract('getSmoothSeekPlayPositionSec'), gridContext)

function lerGrid(sampledAt) {
  relogioMs = sampledAt
  return vm.runInContext(
    `getSmoothSeekPlayPositionSec({}, ${sampledAt}, { id: 'alvo' })`, gridContext)
}

posBridge = 0
lerGrid(0)
let proximoGrid = 300
let pollGrid = 0
let antGrid = lerGrid(0)
let recuoGrid = 0
let saltoGrid = 0
let descolaGrid = 0

for (let t = FRAME_MS; t <= TOTAL_MS; t += FRAME_MS) {
  if (t >= proximoGrid) {
    const atraso = latencias[pollGrid % latencias.length]
    posBridge = (t - atraso) / 1000
    proximoGrid += 300
    pollGrid += 1
  }
  const atual = lerGrid(t)
  recuoGrid = Math.max(recuoGrid, antGrid - atual)
  saltoGrid = Math.max(saltoGrid, atual - antGrid)
  descolaGrid = Math.max(descolaGrid, Math.abs(atual - t / 1000))
  antGrid = atual
}

assert(pollGrid > 30, 'a simulacao do Grid precisa de varios polls')
assert.equal(recuoGrid, 0,
  'o cursor do Grid andou para tras ' + recuoGrid.toFixed(4) + 's')
assert(saltoGrid < (FRAME_MS / 1000) * 2.2,
  'o cursor do Grid deu arranco de ' + saltoGrid.toFixed(4) + 's num quadro')
assert(descolaGrid < 0.35,
  'o cursor do Grid ficou ' + descolaGrid.toFixed(3) + 's fora do tempo real')

posBridge = 90
const gridDepoisDoSeek = lerGrid(TOTAL_MS + FRAME_MS)
assert(Math.abs(gridDepoisDoSeek - 90) < 0.05,
  'seek deveria reancorar o cursor do Grid de vez, ficou em ' +
  gridDepoisDoSeek.toFixed(3) + 's')


// ---------------------------------------------------------------------------
// A barra de regresso da fila de espera nao tem relogio proprio: ela e o
// espelho do progresso ("falta isto para a proxima entrar"). Entao ela so fica
// suave enquanto for derivada do MESMO valor suavizado. Se algum dia alguem
// voltar a calcula-la sobre o progresso cru do Bridge, ela volta a tremer
// sozinha, com a barra de progresso ao lado dela lisa — e fica dificil de ver.

const barsBlock = extract('syncPlaybackBarsDom')
assert(barsBlock.includes('const progress = getSmoothBarProgressPercent('),
  'o tique por quadro deve tirar o progresso do relogio local')
assert(barsBlock.includes('100 - progress'),
  'o regresso da fila deve espelhar o progresso suavizado')

const progressDomBlock = extract('syncPlaybackProgressDom')
assert(progressDomBlock.includes('const barProgress = getSmoothBarProgressPercent('),
  'o tique de texto deve ler o mesmo relogio antes de pintar as barras')
assert(progressDomBlock.includes('const barQueueProgress = showQueueBar ? 100 - barProgress'),
  'o regresso da fila deve sair do progresso suavizado, nao do cru')

for (const [seletor, variavel] of [
  ['.playbackQueueFillNow', 'barProgress'],
  ['.playbackQueueFillNext', 'barQueueProgress'],
  ['.playingRowProgressBar', 'barProgress'],
  ['.queuedRowRegressBar', 'barQueueProgress'],
]) {
  assert(progressDomBlock.includes(
    "setBarScaleDom('" + seletor + "', " + variavel + ")"),
    'barra pintada fora do relogio local: ' + seletor)
}

console.log(`DIRECTOR_BAR_CLOCK_OK: ${sourcePath} ` +
  `(${poll} polls, recuo ${maiorRecuo.toFixed(4)}%, ` +
  `descolamento ${descolamentoSec.toFixed(3)}s)`)
