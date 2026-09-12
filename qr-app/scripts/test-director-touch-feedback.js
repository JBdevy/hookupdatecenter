// Retorno visual imediato do toque.
//
// O aparelho antigo continua sendo o piso: nele o render que segue o toque
// ocupa o quadro inteiro e a tela so muda centenas de milissegundos depois.
// Sem uma marca no proprio dedo o botao parece nao ter respondido e o operador
// aperta de novo ao vivo. Este teste guarda as tres regras que fazem a marca
// valer: ela entra no pointerdown, nao encosta em render nenhum, e a linha da
// lista fica de fora para nao acender a cada rolagem.

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const sourcePath = path.resolve(__dirname, '..', 'vsdiretor.js')
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n')

function extractFunction(name) {
  const startAt = source.indexOf('  function ' + name + '(')
  assert(startAt >= 0, 'funcao ausente: ' + name)
  const next = source.slice(startAt + 1).indexOf('\n  function ')
  assert(next >= 0, 'fim da funcao ausente: ' + name)
  return source.slice(startAt, startAt + 1 + next)
}

// A marca precisa ser visivel sozinha, sem depender do :active do WebKit, que
// o iOS segura enquanto decide se o gesto virou rolagem.
assert.match(source, /\.vshookPressed\{[^}]*filter:brightness\(/,
  'a classe de pressionado perdeu o realce visual')
assert.match(source, /button\.vshookPressed[^{]*\{[^}]*transform:translateY\(/,
  'o botao pressionado perdeu o afundamento')

// O CSS da marca nao pode viver dentro do renderApp: as telas de login e de
// Recados retornam antes dele e ficariam sem retorno de toque.
const stylesBlock = extractFunction('ensurePressedFeedbackStylesDom')
assert.match(stylesBlock, /document\.head\.appendChild\(node\)/,
  'o CSS da marca deve viver num no permanente do head')
assert.match(stylesBlock, /getElementById\('vshookPressedFeedbackStyles'\)[\s\S]{0,120}remove\(\)/,
  'o no deve voltar para o fim do head para vencer o CSS do modo')
assert(source.indexOf('    ensurePressedFeedbackStylesDom()') >= 0 &&
  source.indexOf('    ensurePressedFeedbackStylesDom()') < source.indexOf('    installEvents()'),
  'o CSS da marca deve ser instalado na abertura do app, antes dos eventos')

const markBlock = extractFunction('markPressedFeedbackDom')
assert.match(markBlock, /closest\?\.\('\[data-action\]'\)/,
  'a marca deve seguir o mesmo alvo que onTap usa')
assert.match(markBlock, /closest\('\.item'\)/,
  'a linha da lista deve ficar de fora da marca de pressionado')
assert.match(markBlock, /aria-disabled/,
  'botao desabilitado nao pode acender como se tivesse respondido')
assert.match(markBlock, /classList\.add\('vshookPressed'\)/,
  'a marca de pressionado nao e mais aplicada')

// Nada aqui pode disparar trabalho de render: e justamente o render que esta
// atrasado, e a marca existe para aparecer antes dele.
for (const name of [
  'markPressedFeedbackDom',
  'clearPressedFeedbackDom',
  'releasePressedFeedbackDom',
]) {
  assert.doesNotMatch(extractFunction(name),
    /\b(?:scheduleRender|renderApp|updateAppHtmlPreservingTopStatus)\s*\(/,
    'o retorno de toque voltou a depender do render: ' + name)
}

const releaseBlock = extractFunction('releasePressedFeedbackDom')
const outerFrameAt = releaseBlock.indexOf('window.requestAnimationFrame(')
const innerFrameAt = releaseBlock.indexOf('window.requestAnimationFrame(', outerFrameAt + 1)
assert(outerFrameAt >= 0 && innerFrameAt > outerFrameAt,
  'a marca deve sobreviver ao quadro do render antes de sair')
assert.match(releaseBlock, /window\.setTimeout\(clearPressedFeedbackDom/,
  'a marca precisa de uma saida garantida se o quadro nunca chegar')

const clearBlock = extractFunction('clearPressedFeedbackDom')
assert.match(clearBlock, /window\.clearTimeout\(pressedFeedbackReleaseTimer\)/,
  'a saida garantida deve ser cancelada quando a marca ja saiu')

// A ordem do registro e o que garante que a marca pinte antes do trabalho do
// toque: pointerdown em captura, e a soltura depois do onTap.
const markAt = source.indexOf(
  "document.addEventListener('pointerdown', markPressedFeedbackDom, { passive: true, capture: true })")
const tapAt = source.indexOf(
  "document.addEventListener('pointerup', onTap, { passive: false })")
const releaseAt = source.indexOf(
  "document.addEventListener('pointerup', releasePressedFeedbackDom, { passive: true })")
assert(markAt >= 0, 'a marca deixou de entrar no pointerdown em captura')
assert(tapAt > markAt, 'a marca deve ser registrada antes do onTap')
assert(releaseAt > tapAt, 'a soltura deve correr depois da acao do toque')

// Gesto que virou rolagem, ou que o sistema cancelou, nao pode deixar um botao
// aceso na tela do operador.
assert.match(source,
  /document\.addEventListener\('pointercancel', clearPressedFeedbackDom/,
  'o cancelamento do ponteiro deve apagar a marca')
assert.match(source,
  /document\.addEventListener\('scroll', clearPressedFeedbackDom, true\)/,
  'a rolagem deve apagar a marca')

// O alvo funcional tambem precisa sobreviver a um render entre a descida e a
// soltura do dedo. Sem isso o retorno aparece, mas a acao so entra no segundo
// toque em botoes como SAIR, MODO CLARO e MUSÍCAS.
const captureBlock = extractFunction('captureActionPointer')
assert.match(captureBlock, /pendingActionPointers\.set\(event\.pointerId/,
  'o alvo da acao precisa ser guardado no pointerdown')
assert.match(captureBlock, /state\.ignoreTapUntil\s*=\s*0/,
  'um toque novo precisa liberar o bloqueio pertencente ao gesto anterior')
assert(!source.includes('function moveActionPointer('),
  'botoes nao devem cancelar a acao por uma distancia fixa de arrasto')
const resolveTapBlock = extractFunction('resolveTapElement')
assert.match(resolveTapBlock,
  /document\.elementFromPoint\(clientX, clientY\)\?\.closest\?\.\('\[data-action\]'\)/,
  'a soltura precisa conferir qual controle realmente ficou sob o dedo')
assert.match(resolveTapBlock,
  /releasedElement === pending\.element\) return releasedElement/,
  'o arrasto que termina dentro do mesmo botao deve executar a acao')
assert.match(resolveTapBlock,
  /clientX >= rect\.left[\s\S]*?clientX <= rect\.right[\s\S]*?clientY >= rect\.top[\s\S]*?clientY <= rect\.bottom/,
  'o fallback deve validar os limites reais do controle')
assert.match(resolveTapBlock,
  /!pending\.element\?\.isConnected[\s\S]*?getActionElementKey\(releasedElement\) === getActionElementKey\(pending\.element\)/,
  'o controle equivalente deve sobreviver a um render durante o gesto')
assert.doesNotMatch(resolveTapBlock, /pending\.moved|TOLERANCE/,
  'a decisao dos botoes deve depender da area final, nao da distancia percorrida')
assert.match(extractFunction('onTap'), /const el = resolveTapElement\(event\)/,
  'onTap deve usar o alvo preservado do gesto')
assert(source.indexOf("document.addEventListener('pointerdown', captureActionPointer") < tapAt,
  'o alvo funcional deve ser capturado antes do pointerup')

// Alguns WebViews emitem o retorno visual do pointerdown, mas perdem a rota de
// pointerup. O click delegado fica sempre instalado como segunda rota e a marca
// do pointerup impede que o mesmo gesto execute a acao duas vezes.
assert(source.includes("document.addEventListener('click', onTap, false)"),
  'o click de seguranca precisa existir tambem quando PointerEvent esta disponivel')
const onTapBlock = extractFunction('onTap')
assert.match(onTapBlock,
  /event\.type === 'click'[\s\S]*?lastPointerDispatchedAction[\s\S]*?return/,
  'o click sintetico precisa ser deduplicado depois do pointerup')
assert.match(onTapBlock,
  /event\.type === 'pointerup'[\s\S]*?lastPointerDispatchedAction\s*=\s*\{ key, at: now\(\) \}/,
  'o pointerup precisa registrar a acao executada para proteger o fallback')

console.log(`DIRECTOR_TOUCH_FEEDBACK_OK: ${sourcePath}`)
