const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')

const sourcePath = path.resolve(__dirname, '..', 'vsdiretor.js')
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n')

function extractFunction(name) {
  const match = new RegExp('  (?:async )?function ' + name + '\\(').exec(source)
  assert(match, 'funcao ausente: ' + name)
  const startAt = match.index
  const next = /\n  (?:async )?function /.exec(source.slice(startAt + 1))
  assert(next, 'fim da funcao ausente: ' + name)
  return source.slice(startAt, startAt + 1 + next.index)
}

function extractCase(name, nextName) {
  const marker = "      case '" + name + "':"
  const nextMarker = "      case '" + nextName + "':"
  const startAt = source.indexOf(marker)
  const endAt = source.indexOf(nextMarker, startAt + marker.length)
  assert(startAt >= 0, 'handler ausente: ' + name)
  assert(endAt > startAt, 'fim do handler ausente: ' + name)
  return source.slice(startAt, endAt)
}

function countCalls(block, name) {
  return (block.match(new RegExp('\\b' + name + '\\s*\\(', 'g')) || []).length
}
const start = source.indexOf('  function scheduleRender(force = false) {')
const end = source.indexOf('  function focusPendingTabletSearchResultDom()', start)
const block = source.slice(start, end)
const signatureAt = block.indexOf('const sig =')
const changedAt = block.indexOf('if (sig !== state.lastHtmlSignature)')
const renderAt = block.indexOf('const html = renderApp()')

if (start < 0 || end < 0 || signatureAt < 0 || changedAt < 0 || renderAt < 0 ||
    !(signatureAt < changedAt && changedAt < renderAt)) {
  throw new Error('renderApp voltou a ser executado antes de confirmar mudança visual')
}
if (!source.includes('const htmlWithoutPreservedStyles = html.replace(') ||
    !source.includes('template.innerHTML = htmlWithoutPreservedStyles')) {
  throw new Error('CSS preservado voltou a ser enviado ao parser em cada render')
}
if (!source.includes('const DIRECTOR_VISUAL_FRAME_MS = 50') ||
    source.includes('IS_LEGACY_IOS')) {
  throw new Error('cadencia visual deixou de ser unica entre as plataformas')
}
if (!source.includes('const transportAnimating =') ||
    !source.includes('isPlaying(state.snapshot) && !isPaused(state.snapshot)')) {
  throw new Error('loop visual voltou a trabalhar continuamente com o transporte parado')
}
if (!source.includes('syncPlaybackProgressDom(sampledAt, true)') ||
    !source.includes('if (!dynamicOnly) syncPlaybackQueueHeaderDom(data)')) {
  throw new Error('loop visual voltou a recalcular o cabecalho estatico em cada quadro')
}
if (!source.includes("state.settingsSection = 'teleprompt-hub'\n        mountSettingsModalInPlace()") ||
    !source.includes("state.settingsSection = 'recados'\n        armAppConfigColorGuard()\n        mountSettingsModalInPlace()")) {
  throw new Error('navegacao interna de Config voltou a reconstruir a interface inteira')
}

// No Android o WebView entrega um clique sintetico depois do pointerup que
// abriu a tela de Config, e sem esta guarda ele cai sozinho no campo de cor e
// escancara o seletor nativo. Ela ja se perdeu uma vez numa sincronizacao
// entre as duas copias do app.
for (const parte of [
  "document.addEventListener('pointerdown', trackAppConfigColorPointerDown, true)",
  "document.addEventListener('click', guardAppConfigColorClick, true)",
]) {
  assert(source.includes(parte),
    'a guarda do seletor de cores do Android perdeu um registro: ' + parte)
}

const renderSignatureBlock = extractFunction('getAppRenderSignature')
for (const requiredPart of [
  'state.activeTab',
  'state.telepromptListOpen',
  'state.telepromptPartsOpen',
  'getHashDrawersRenderSignature()',
  'compactRenderState()',
]) {
  assert(renderSignatureBlock.includes(requiredPart),
    'assinatura visual perdeu componente: ' + requiredPart)
}
const scheduleRenderBlock = extractFunction('scheduleRender')
assert.match(scheduleRenderBlock,
  /const sig\s*=\s*getAppRenderSignature\s*\([^)]*\)/,
  'scheduleRender deve obter a assinatura pelo helper dedicado')
assert.doesNotMatch(scheduleRenderBlock,
  /const sig\s*=\s*`\$\{state\.activeTab\}/,
  'assinatura visual voltou a ficar inline em scheduleRender')

extractFunction('syncSongRowsDom')
const finishSongInteractionBlock = extractFunction('finishSongInteractionDom')
assert.match(finishSongInteractionBlock, /\bsyncSongRowsDom\s*\(/,
  'interacao comum deve sincronizar as linhas no DOM local')
assert.match(finishSongInteractionBlock, /\bgetAppRenderSignature\s*\(/,
  'interacao comum deve manter a assinatura visual sincronizada')
assert.doesNotMatch(finishSongInteractionBlock,
  /\b(?:renderApp|updateAppHtmlPreservingTopStatus)\s*\(/,
  'interacao comum voltou a reconstruir o app inteiro')
const finishSyncAt = finishSongInteractionBlock.indexOf('syncSongRowsDom(')
const finishFallbackAt = finishSongInteractionBlock.indexOf('scheduleRender(true)')
const finishSignatureAt = finishSongInteractionBlock.indexOf('getAppRenderSignature(')
assert(finishSignatureAt > finishSyncAt,
  'assinatura deve ser atualizada depois da sincronizacao DOM local')
if (finishFallbackAt >= 0) {
  assert(finishFallbackAt > finishSyncAt && finishFallbackAt < finishSignatureAt,
    'render forcado deve ficar isolado antes do caminho simples')
  assert(finishSongInteractionBlock.slice(finishFallbackAt, finishSignatureAt).includes('return'),
    'fallback estrutural deve encerrar antes do caminho simples')
  assert.match(finishSongInteractionBlock.slice(finishSyncAt, finishFallbackAt),
    /\b(?:structural|isPartsInterfaceVisible)\b/,
    'render forcado deve possuir uma guarda estrutural explicita')
}
assert.equal((finishSongInteractionBlock.match(/scheduleRender\s*\(\s*true\s*\)/g) || []).length,
  finishFallbackAt >= 0 ? 1 : 0,
  'interacao comum nao deve possuir outros renders forcados')

const handleItemSelectBlock = extractFunction('handleItemSelect')
const playlistFlowAt = handleItemSelectBlock.indexOf("\n    if (type === 'playlist') {")
const regionFlowAt = handleItemSelectBlock.indexOf("\n    if (type === 'region') {", playlistFlowAt + 1)
assert(playlistFlowAt >= 0 && regionFlowAt > playlistFlowAt,
  'fluxos comuns de selecao nao foram encontrados')
const playlistFlow = handleItemSelectBlock.slice(playlistFlowAt, regionFlowAt)
const regionFlow = handleItemSelectBlock.slice(regionFlowAt)
for (const [name, flow] of [['playlist', playlistFlow], ['regions', regionFlow]]) {
  const simpleFlowAt = flow.indexOf('const alreadySelected')
  assert(simpleFlowAt >= 0, 'fluxo simples ausente: ' + name)
  const simpleFlow = flow.slice(simpleFlowAt)
  assert(countCalls(simpleFlow, 'finishSongInteractionDom') >= 1,
    'selecao comum deve finalizar pelo DOM local: ' + name)
  assert.equal(countCalls(simpleFlow, 'scheduleRender'), 0,
    'selecao comum nao deve agendar render global: ' + name)
}

extractFunction('renderMusicPane')
const createMusicPaneNodeBlock = extractFunction('createMusicPaneNode')
assert.match(createMusicPaneNodeBlock, /\brenderMusicPane\s*\(/,
  'montagem do painel deve renderizar somente o conteudo musical')
assert.doesNotMatch(createMusicPaneNodeBlock, /\brenderApp\s*\(/,
  'montagem do painel musical voltou a renderizar o app inteiro')
const swapMusicPaneBlock = extractFunction('swapMusicPaneDom')
assert.match(swapMusicPaneBlock, /\bcreateMusicPaneNode\s*\(/,
  'troca de aba deve montar somente o painel musical')
assert.doesNotMatch(swapMusicPaneBlock,
  /\b(?:renderApp|updateAppHtmlPreservingTopStatus|scheduleRender)\s*\(/,
  'troca do painel central voltou a reconstruir o app inteiro')
for (const tab of ['mixer', 'premix']) {
  assert(source.includes(`data-main-pane-tab="${tab}"`),
    `painel ${tab} deve participar do cache central`)
}
const cachedTabBlock = extractFunction('isCachedMainPaneTab')
for (const tab of ['playlist', 'regions', 'mixer', 'premix']) {
  assert(cachedTabBlock.includes(`activeTab === '${tab}'`),
    `cache central perdeu a tela ${tab}`)
}
const premixFullRenderBlock = extractFunction('renderPremixFullScreen')
assert.match(premixFullRenderBlock, /data-premix-screen-cache-placeholder/,
  'Premix de tela cheia deve reutilizar a superficie pronta')
assert.match(extractFunction('reuseCachedPremixFullScreen'),
  /premixFullScreenCache[\s\S]*replaceChild\(cached, placeholder\)/,
  'Premix de tela cheia deve preservar e recolocar o mesmo DOM')

const renderMusicianMonitorBlock = extractFunction('renderMusicianMonitorContent')
for (const [name, renderBlock] of [
  ['Diretor', extractFunction('renderMusicPane')],
  ['Musicos', renderMusicianMonitorBlock],
]) {
  assert.match(renderBlock, /\brenderCachedMusicList\s*\(/,
    `lista do ${name} deve usar o cache de DOM compartilhado`)
}
const reuseListsBlock = extractFunction('reuseStableListBoxes')
assert.match(reuseListsBlock, /data-music-list-cache-key/,
  'cache deve reconhecer a arvore de musicas ja montada')
assert.match(reuseListsBlock, /replaceChild\(currentList, nextList\)/,
  'cache deve reaproveitar o mesmo DOM da lista')
const renderCachedListBlock = extractFunction('renderCachedMusicList')
assert.match(renderCachedListBlock, /const rows = mounted \? '' : renderRows\(items, type\)/,
  'lista ja montada nao deve ser reconstruida nem fora da tela')
assert.match(scheduleRenderBlock, /restoreListScrollState\(scrollState\)[\s\S]{0,100}?syncSongRowsDom\(\)/,
  'estado dinamico deve ser sincronizado depois de recuperar a lista do cache')
const mountMainBlock = extractFunction('mountMainContentPanelDom')
assert.match(mountMainBlock, /reuseMatchingCachedMusicList\(current, next\)/,
  'Parts deve transportar a lista pronta para o painel dividido')
assert.match(mountMainBlock,
  /movedMusicList[\s\S]{0,220}?musicPaneCache\.delete\(currentMusicTab\)/,
  'Parts deve invalidar o painel antigo depois de mover a lista')
assert.match(mountMainBlock, /isUsableCachedMainPane\(state\.activeTab, cached\.node\)/,
  'retorno do Parts deve rejeitar um painel em cache sem a lista')
const usablePaneBlock = extractFunction('isUsableCachedMainPane')
for (const requiredList of [
  "activeTab !== 'playlist' && activeTab !== 'regions'",
  "activeTab === 'playlist' ? 'playlist' : 'region'",
]) {
  assert(usablePaneBlock.includes(requiredList),
    'protecao do Parts deve cobrir Repertorio e Musicas: ' + requiredList)
}

const stylePath = path.resolve(__dirname, '..', 'stylediretor-app.css')
const styles = fs.readFileSync(stylePath, 'utf8').replace(/\r\n/g, '\n')
assert.match(styles, /\.musicListRenderCache\s*\{[\s\S]{0,180}?will-change:\s*scroll-position/,
  'lista em cache deve manter a superficie de rolagem preparada')

const setTabBlock = extractFunction('setTab')
const paneSwapAt = setTabBlock.indexOf('swapMusicPaneDom(')
const structuralFallbackAt = setTabBlock.indexOf('scheduleRender(true)', paneSwapAt + 1)
assert(paneSwapAt >= 0, 'setTab deve trocar localmente playlist/regions')
assert(structuralFallbackAt > paneSwapAt,
  'render completo de setTab deve existir somente depois do caminho local')
assert.equal(countCalls(setTabBlock, 'swapMusicPaneDom'), 1,
  'setTab deve ter um unico ponto de troca do painel musical')
assert.equal((setTabBlock.match(/scheduleRender\s*\(\s*true\s*\)/g) || []).length, 1,
  'setTab deve reservar um unico render forcado para o fallback estrutural')
const pathSeparator = setTabBlock.slice(paneSwapAt, structuralFallbackAt)
assert(/\b(?:else|return)\b/.test(pathSeparator),
  'o caminho local de setTab deve encerrar ou separar o fallback estrutural')

assert.match(swapMusicPaneBlock,
  /rememberMusicPaneScroll\(previousTab,\s*current\)/,
  'troca de aba deve guardar a posicao da lista que esta saindo')
assert.match(swapMusicPaneBlock,
  /restoreMusicPaneScroll\(activeTab,\s*cached\.node\)/,
  'troca de aba deve restaurar a posicao propria da lista que esta voltando')
const songListScrollBlock = extractFunction('handleDirectorSongListScroll')
assert.match(songListScrollBlock,
  /rememberMusicPaneScroll\(scrollKey,\s*list\)/,
  'rolagem deve atualizar a memoria independente de Repertorio e Musicas')
assert(source.includes('const musicPaneScrollState = new Map()'),
  'cache deve manter posicao por aba mesmo quando o painel for recriado')

for (const [action, nextAction, tab] of [
  ['go-playlist', 'go-regions', 'playlist'],
  ['go-regions', 'go-markers', 'regions'],
]) {
  const handler = extractCase(action, nextAction)
  assert(handler.includes("setTab('" + tab + "')"),
    action + ' deve delegar a troca para setTab')
  assert.equal(countCalls(handler, 'scheduleRender'), 0,
    action + ' nao deve duplicar o render de setTab')
}

// A faixa de rolagem dedicada na linha da musica foi retirada junto com a sua
// opcao em Config. A lista volta a ser rolada pela propria linha, e nenhuma
// preferencia local sobra para reaparecer sozinha num aparelho ja usado.
for (const vestigio of [
  'songScrollLane',
  'directorSongScrollLaneEnabled',
  'song-scroll-lane-toggle',
  'vshook_director_tablet_song_scroll_lane',
  'data-song-scroll-lane',
]) {
  assert(!source.includes(vestigio),
    'a faixa de rolagem da linha voltou ao codigo: ' + vestigio)
}

// Uma selecao normal muda apenas o estado visual da linha. Nenhum caminho
// geral de render pode voltar a seguir a selecao alterando o scrollTop.
for (const [name, selectionBlock] of [
  ['handleItemSelect', handleItemSelectBlock],
  ['syncSharedInterfaceState', extractFunction('syncSharedInterfaceState')],
]) {
  assert.doesNotMatch(selectionBlock,
    /\b(?:scrollTop|scrollTo|scrollIntoView|queueDirectorSelectionScroll)\b/,
    name + ' nao deve reposicionar a lista por causa de selecao comum')
}
assert.equal(countCalls(scheduleRenderBlock, 'focusPendingDirectorSelectionDom'), 0,
  'render geral nao deve executar foco automatico de selecao comum')
for (const obsoleteSelectionFocus of [
  'queueDirectorSelectionScroll',
  'focusPendingDirectorSelectionDom',
  'directorSelectionScrollPending',
]) {
  assert(!source.includes(obsoleteSelectionFocus),
    'foco automatico de selecao voltou ao codigo: ' + obsoleteSelectionFocus)
}
const playlistScrollGestureBlock = extractFunction('handlePlaylistScrollGesture')
assert.match(playlistScrollGestureBlock,
  /event\.type\s*===\s*'pointerdown'[\s\S]*?gestureGuardUntil[\s\S]*?directorListScrollingUntil/,
  'pointerdown da lista deve impedir render antes do primeiro movimento')
assert.match(styles,
  /\.musicListRenderCache\s*\{[\s\S]{0,100}?overflow-anchor:\s*none/,
  'lista musical nao deve ancorar novamente a linha selecionada')

const onTapBlock = extractFunction('onTap')
assert.doesNotMatch(onTapBlock,
  /directorSongListScrollingUntil/,
  'um novo toque na musica nao pode ser bloqueado pela rolagem anterior')
assert.match(onTapBlock, /event\.type === 'click'[\s\S]*?playlistScrollSuppressClickUntil/,
  'somente o click sintetico posterior a rolagem deve ser bloqueado')
assert.match(onTapBlock, /event\.pointerId === playlistScrollSuppressedPointerId/,
  'uma linha musical arrastada deve continuar sendo tratada como scroll')
assert.match(playlistScrollGestureBlock, /Math\.hypot\(dx, dy\) > 10/,
  'a lista musical deve usar touch slop antes de assumir que o gesto e scroll')
assert.doesNotMatch(playlistScrollGestureBlock, /state\.ignoreTapUntil\s*=/,
  'o scroll da lista nao pode bloquear globalmente os demais botoes')

const partsSnapshotBlock = extractFunction('syncPartsMarkerStateFromSnapshot')
assert.match(partsSnapshotBlock,
  /if\s*\(!state\.partsArmedOwnerSongId\s*&&\s*hasReachedPartsArmedTarget\(data\)\)\s*\{\s*clearReachedPartsArmedTarget\(data\)/,
  'Parts deve limpar o alvo mesmo enquanto o Bridge ainda repete armedMarkerId')
const clearReachedPartsBlock = extractFunction('clearReachedPartsArmedTarget')
for (const requiredClear of [
  "state.partsArmedMarkerId = ''",
  "state.partsLocalSelectedMarkerId = ''",
  'syncMarkerSelectionDom()',
]) {
  assert(clearReachedPartsBlock.includes(requiredClear),
    'limpeza visual do alvo Parts incompleta: ' + requiredClear)
}

// A Lupa e a unica excecao: ela cria um alvo explicito, consumido pelo foco
// dedicado depois que a tela de busca fecha e a lista de destino reaparece.
const tabletSearchResultBlock = extractFunction('handleTabletSearchResult')
assert.match(tabletSearchResultBlock,
  /state\.tabletSearchPendingFocus\s*=\s*\{/,
  'resultado da Lupa deve criar tabletSearchPendingFocus')
for (const field of ['id', 'itemType', 'destinationTab', 'scheduled']) {
  assert.match(tabletSearchResultBlock, new RegExp('\\b' + field + '\\s*:'),
    'tabletSearchPendingFocus perdeu o campo ' + field)
}
assert(countCalls(scheduleRenderBlock, 'focusPendingTabletSearchResultDom') >= 1,
  'render deve continuar consumindo o foco explicito criado pela Lupa')

// CONFIG ABA TP controla somente a presença dos botões e começa toda
// desligada. A ordem declarada é também a ordem do rodapé.
assert.match(source,
  /\{ id: 'play'[\s\S]*?\{ id: 'list'[\s\S]*?\{ id: 'auto1'[\s\S]*?\{ id: 'auto2'[\s\S]*?\{ id: 'loop'[\s\S]*?\{ id: 'parts'[\s\S]*?\{ id: 'stopBreak'/,
  'ordem do rodapé do Teleprompt foi alterada')
const compactTpControls = extractFunction('getAvailableTelepromptTabControls')
for (const id of ['play', 'auto1', 'loop']) {
  assert(compactTpControls.includes(`control.id === '${id}'`),
    'modo compacto perdeu o controle ' + id)
}
for (const id of ['list', 'auto2', 'parts', 'stopBreak']) {
  assert(!compactTpControls.includes(`control.id === '${id}'`),
    'modo compacto não pode mostrar ' + id)
}
assert.match(compactTpControls, /filter\(\(control\) => control\.id !== 'loop'\)/,
  'no Tablet o PARTS deve ocupar o lugar do LOOP')
assert.match(extractFunction('getTelepromptTabControls'),
  /saved\?\.\[control\.id\]\s*===\s*true/,
  'controles do rodapé devem iniciar desligados')

// LIST e PARTS podem coexistir: 40% em cada lateral e 20% para o TP.
const telepromptRenderBlock = extractFunction('renderDirectorTelepromptScreen')
assert(telepromptRenderBlock.indexOf('<div class="directorTpControls">') <
  telepromptRenderBlock.indexOf('<div class="directorTpWorkspace"'),
  'barra superior do TP deve ficar fixa acima de LIST/TP/PARTS')
assert.match(telepromptRenderBlock,
  /getHideTelepromptTransport\(slot\)\s*\|\|\s*listOpen/,
  'abrir LIST deve ocultar temporariamente o transporte do TP')
assert(telepromptRenderBlock.indexOf('renderTelepromptTabFooterControls(data)') >
  telepromptRenderBlock.lastIndexOf('renderTelepromptPartsSide(data)'),
  'rodape do TP deve ficar abaixo de LIST/TP/PARTS, ocupando a largura total')
for (const requiredPart of [
  'renderTelepromptPlaylistSide(data)',
  'renderTelepromptPartsSide(data)',
  'data-list-open=',
  'data-parts-open=',
]) {
  assert(telepromptRenderBlock.includes(requiredPart),
    'layout lateral do TP perdeu: ' + requiredPart)
}
assert.match(styles,
  /\.directorTpWorkspace\[data-list-open="1"\]\[data-parts-open="1"\]\s*\{[^}]*grid-template-columns:\s*40%\s+minmax\(0,\s*20%\)\s+40%/,
  'LIST + TP + PARTS devem ocupar exatamente 40/20/40')
assert.match(styles,
  /\.directorTpPanel\s*>\s*\.directorTpFooterControls\s*\{[^}]*margin:\s*0\s+10px\s+10px/,
  'rodape do TP deve permanecer abaixo das colunas')
assert.match(styles,
  /\.directorTpPanel\s*>\s*\.directorTpControls\s*\{[^}]*margin:\s*10px\s+10px\s+0/,
  'barra superior do TP deve respeitar o contorno como o rodape')
assert.match(styles,
  /\.directorTpPanel\s*>\s*\.directorTpControls\s*>\s*\.directorTpTab\s*\{[^}]*height:\s*30px\s*!important[^}]*max-height:\s*30px\s*!important/,
  'botoes CONFIG/TP, TP/1, TP/2 e VOLTAR devem permanecer compactos')
assert.match(styles,
  /\.directorTpWorkspace\[data-list-open="1"\]\[data-parts-open="1"\]\s+\.directorTpClock,[\s\S]{0,300}?width:\s*calc\(50%\s*-\s*7px\)\s*!important[\s\S]{0,120}?height:\s*30px\s*!important[\s\S]{0,120}?max-height:\s*30px\s*!important/,
  'cronometro e horario local devem dividir o TP com o mesmo tamanho quando LIST e PARTS abrirem juntos')
assert.match(styles,
  /\.directorTpContent\s*>\s*\.playbackQueueHeader\s+\.playbackQueueNow,[\s\S]{0,260}?grid-template-columns:\s*max-content\s+22px\s+minmax\(0,\s*1fr\)\s+max-content\s*!important/,
  'rotulo, seta, nome e tempo do transporte do TP devem ocupar colunas independentes')
assert.match(source,
  /playbackQueueLabel">REPRODUZINDO<\/span>\s*<span class="playbackQueueStateArrow/,
  'seta do transporte deve ser irma do rotulo, nunca ficar sobre o nome')
const telepromptPartsSyncBlock = extractFunction('syncTelepromptPartsSideDom')
assert.match(telepromptPartsSyncBlock, /\brenderTelepromptPartsSide\s*\(/,
  'PARTS do TP deve ser remontado com a musica selecionada')
assert.match(telepromptPartsSyncBlock, /\bcurrent\.replaceWith\(next\)/,
  'PARTS do TP deve trocar somente sua lateral')
assert(!extractFunction('renderTelepromptPartsSide').includes('directorTpSideTitle">PARTS'),
  'lateral PARTS do TP nao deve manter cabecalho sem utilidade')
assert.match(source,
  /state\.showTelepromptScreen\s*&&\s*root\.querySelector\('\.directorTpOverlay'\)[\s\S]{0,420}?syncTelepromptPartsSideDom\(\)/,
  'snapshot de reproducao/fila deve atualizar imediatamente a lateral PARTS do TP')
assert.match(source,
  /case 'parts-song-playing':[\s\S]{0,420}?syncTelepromptPartsSideDom\(\)/,
  'botao da musica tocando deve atualizar a cor e a lista PARTS no proprio toque')
assert.match(source,
  /case 'parts-song-queued':[\s\S]{0,420}?syncTelepromptPartsSideDom\(\)/,
  'botao da musica na fila deve atualizar a cor e a lista PARTS no proprio toque')
assert.match(finishSongInteractionBlock, /\bsyncTelepromptPartsSideDom\s*\(/,
  'selecao na LIST deve sincronizar PARTS imediatamente')
assert.match(finishSongInteractionBlock, /isPartsInterfaceVisible\(\)\s*&&\s*!telepromptPartsSynced/,
  'PARTS lateral sincronizado nao deve provocar render geral do TP')
assert.match(extractFunction('isPartsInterfaceVisible'), /\bisTelepromptPartsSideVisible\s*\(/,
  'PARTS aberto dentro do TP deve contar como interface visivel')
assert.match(styles,
  /\.directorTpFooterControls\s*>\s*\.btnConfigOffRed\s*\{[^}]*#dc2626/,
  'LIST/PARTS fechados devem aparecer em vermelho')
assert.match(styles,
  /\.directorTpFooterControls\s*>\s*\.btnConfigOnGreen\s*\{[^}]*#22c55e/,
  'LIST/PARTS abertos devem aparecer em verde')
assert.match(styles,
  /\.directorTpSidePane \.item\.numberedItem\s*\{[^}]*grid-template-columns:\s*38px/,
  'lista lateral de 40% deve usar proporcoes completas de linha e numeracao')
const tpControlsConfigBlock = extractFunction('renderTelepromptTabControlsConfig')
assert.match(tpControlsConfigBlock,
  /telepromptTransportVisibilityButton[\s\S]*?teleprompt-transport-visibility-toggle/,
  'opcao de ocultar transporte deve ficar dentro de CONFIG ABA TP')
assert.match(extractFunction('renderSettingsModal'),
  /settingsMainTransportVisibilityButton[\s\S]*?main-transport-visibility-toggle/,
  'Config deve oferecer ocultacao independente do transporte da tela principal')
for (const mainScreenBlock of [
  extractFunction('renderMusicPane'),
  extractFunction('renderMusicianMonitorContent'),
  extractFunction('renderTabletTunerUnifiedContent'),
  extractFunction('renderTabletBpmUnifiedContent'),
]) {
  assert.match(mainScreenBlock, /renderMainPlaybackQueueHeader\s*\(/,
    'telas principais devem respeitar sua preferencia independente de transporte')
}
const autoBlockVisualBlock = extractFunction('isAutoBlocoBoundaryVisualTarget')
assert.doesNotMatch(autoBlockVisualBlock, /queuedManual|manualQueue/,
  'AT/BL ligado nao pode manter tarja laranja manual na primeira musica do proximo bloco')
assert.match(autoBlockVisualBlock, /nextBlockIndex[\s\S]*?isPlayable\(item\)/,
  'AT/BL deve esconder somente a primeira musica tocavel do proximo bloco')
const atBlToggleBlock = extractCase('atbl-toggle', 'play')
for (const syncCall of [
  'syncSongRowsDom()',
  'syncPlaybackQueueHeaderDom()',
  'syncPlaybackProgressDom()',
]) {
  assert(atBlToggleBlock.includes(syncCall),
    'AT/BL deve sincronizar localmente no mesmo toque: ' + syncCall)
}
const syncSongRowsBlock = extractFunction('syncSongRowsDom')
assert.match(syncSongRowsBlock, /const playingRowAppliedByList = new Set\(\)/,
  'cada lista visivel deve conservar sua propria tarja de reproducao')
assert.match(syncSongRowsBlock, /row\.closest\('\.listBox'\)/,
  'tarja tocando deve ser limitada por lista, nao pela interface inteira')
assert.match(extractFunction('syncSharedInterfaceState'),
  /localQueueHeld[\s\S]*?if\s*\(!localQueueHeld\)/,
  'fila local deve permanecer autoritativa enquanto o Bridge confirma')
const optimisticPositionBlock = extractFunction('getOptimisticPlayingVisualPosition')
assert.match(optimisticPositionBlock, /optimisticPlayingAnchorPos/,
  'inicio local da musica deve possuir ancora propria')
assert.match(optimisticPositionBlock, /locallyPaused/,
  'progresso local nao pode herdar o pausado antigo do Bridge')
assert(source.includes("showPopup('APENAS COM A MÚSICA PARADA'"),
  'aviso do Grid deve informar que a operacao exige musica parada')
const stoppedTransportBlock = extractFunction('bridgeExplicitlyStopped')
assert.match(stoppedTransportBlock, /hasStoppedFlag/,
  'flags booleanas de STOP devem vencer IDs antigos de reproducao')
assert.doesNotMatch(stoppedTransportBlock,
  /!data\.(?:playingId|playingSongId|currentSongId)/,
  'STOP nao pode depender da limpeza tardia dos IDs da musica anterior')
const initializeSeekBlock = extractFunction('initializeTransportSeekTargetCursor')
assert.match(initializeSeekBlock,
  /const stopped\s*=\s*!getTransportSeekPlaying[\s\S]*?!isPaused/,
  'Grid deve distinguir selecao parada de Play e Pause')
assert.match(initializeSeekBlock,
  /transportSeekCursorPos\s*=\s*start[\s\S]*?transportSeekPauseVisualHoldPos\s*=\s*start/,
  'nova selecao parada deve nascer e permanecer no inicio da musica')
assert.match(extractFunction('focusOpenTabletTransportPanel'),
  /initializeTransportSeekTargetCursor\(target, state\.snapshot\)/,
  'troca de selecao com o Grid aberto deve zerar seu cursor localmente')
for (const headerBlock of [
  extractFunction('renderPlaybackQueueHeader'),
  extractFunction('syncPlaybackQueueHeaderDom'),
]) {
  assert.match(headerBlock,
    /const playbackActive\s*=\s*isPlaying\(data\)\s*\|\|\s*isPaused\(data\)/,
    'barra de transporte deve depender do estado ativo, nao do ID antigo')
}

// O horário local vem sempre do relógio do aparelho e possui um tique próprio,
// independente dos snapshots e do estado de reprodução do Bridge.
const localClockBlock = extractFunction('syncDirectorLocalClockDom')
assert.match(localClockBlock, /deviceDate\.getTime\(\)/,
  'horario local deve usar a data do proprio aparelho')
assert.doesNotMatch(localClockBlock, /state\.snapshot|Bridge/,
  'horario local nao pode depender do snapshot do Bridge')
const animateBlock = extractFunction('animateDirectorProgress')
assert(animateBlock.indexOf('syncDirectorLocalClockDom(new Date())') <
  animateBlock.indexOf('const transportAnimating ='),
  'horario local deve atualizar mesmo com transporte parado ou Bridge offline')

// A pinça amplia somente a área do TP e a pinça inversa devolve o layout.
const pinchMoveBlock = extractFunction('handleTelepromptPinchMove')
assert.match(pinchMoveBlock, /ratio\s*>=\s*1\.16/,
  'pinça para ampliar o TP perdeu o limiar')
assert.match(pinchMoveBlock, /ratio\s*<=\s*0\.86/,
  'pinça inversa para sair do TP cheio perdeu o limiar')
assert.match(pinchMoveBlock, /state\.telepromptFullscreen\s*=\s*shouldEnter/,
  'pinça não atualiza mais o modo de tela cheia')
const mouseDoubleClickBlock = extractFunction('handleTelepromptMouseDoubleClick')
assert.match(mouseDoubleClickBlock, /\[data-director-tp-viewport\]/,
  'duplo clique deve agir somente dentro da area de leitura do TP')
assert.match(mouseDoubleClickBlock, /any-hover:\s*hover[\s\S]*?any-pointer:\s*fine/,
  'duplo clique do TP deve ficar restrito a dispositivos com mouse')
assert.match(mouseDoubleClickBlock, /state\.telepromptFullscreen\s*=\s*!state\.telepromptFullscreen/,
  'duplo clique do mouse deve alternar a tela cheia do TP')
assert.match(source,
  /document\.addEventListener\('dblclick', handleTelepromptMouseDoubleClick, true\)/,
  'evento de duplo clique do TP nao foi instalado')
assert.match(styles,
  /\.directorTpFullscreen[\s\S]*?\.directorTpContent\s*>\s*\.playbackQueueHeader[\s\S]*?display:\s*none\s*!important/,
  'tela cheia do TP deve ocultar transporte e controles')
assert.match(styles,
  /\.directorTpFullscreen \.directorTpSidePane\s*\{[^}]*display:\s*none\s*!important/,
  'tela cheia do TP deve ocultar LIST e PARTS')

// No Tablet a busca usa uma entrada somente de leitura e o teclado do app.
const tabletSearchRenderBlock = extractFunction('renderTabletSearchScreen')
assert.match(tabletSearchRenderBlock, /inputmode="\$\{ownKeyboard \? 'none' : 'search'\}"/,
  'Lupa do Tablet voltou a chamar o teclado nativo')
assert.match(tabletSearchRenderBlock, /readonly aria-readonly="true"/,
  'entrada da Lupa do Tablet deve permanecer somente de leitura')
assert.match(styles,
  /directorSearchPortraitMode \.tabletSearchScreen\s*\{[\s\S]{0,500}?inset:\s*0\s*!important/,
  'Lupa do Tablet deve ocupar a tela inteira do app')


// Um quadro pinta uma unica vez e o rAF roda antes dessa pintura. Se o render
// pesado voltar a entrar direto no rAF, tudo que a acao mudou no DOM (a marca
// do toque, a classe do proprio botao) volta a aparecer so junto com o render
// pronto — que e o toque parecendo ignorado no aparelho antigo.
const scheduleRenderTail = scheduleRenderBlock.slice(
  scheduleRenderBlock.indexOf('const runRender'))
assert.doesNotMatch(scheduleRenderTail,
  /requestAnimationFrame\(\s*runRender\s*\)/,
  'o render pesado voltou a entrar no mesmo quadro da acao')
assert.match(scheduleRenderTail,
  /requestAnimationFrame\([\s\S]{0,200}?setTimeout\(\s*runRender/,
  'o render pesado deve ser agendado para depois da pintura')

console.log(`DIRECTOR_PERFORMANCE_OK: ${sourcePath}`)
