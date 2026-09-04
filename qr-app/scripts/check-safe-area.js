/* VS_HOOK_SAFE_AREA_CHECK — impede a volta do bug do conteudo embaixo do notch.

   A tela principal (.app) para no limite seguro e e a referencia do app. Toda
   camada que cobre a tela — modal, tela de Teleprompt, painel, tela cheia —
   tem que ocupar a mesma caixa. O erro que se repete e alguem escrever
   "padding: 6px !important" numa dessas camadas para ajustar o desenho: isso
   apaga a area segura e o conteudo volta a comecar colado no topo, embaixo do
   recorte do iPhone.

   Este teste roda no build e reprova exatamente esse caso. Para passar, troque
   o valor cru pelo minimo seguro:

     padding: 6px            ->  padding: max(6px, var(--vsh-safe-top)) ...
     padding: 8px            ->  padding: var(--vsh-app-pad)

   Quando a camada de proposito nao leva recuo proprio — porque quem para no
   limite seguro e o filho dela ou o deslocamento da borda — escreva o motivo
   na regra com a nota "safe-area-ok:" dentro de um comentario, e o teste
   aceita.

   Rode sozinho com: node scripts/check-safe-area.js */

const fs = require('fs')
const path = require('path')
const root = path.resolve(__dirname, '..')

const FILES = [
  'app-shell.css', 'chat-app.css', 'recados-app.css', 'stylediretor-app.css',
  'transfer-hook-app.css', 'vsdiretor.js', 'app-shell.js', 'chat.js',
  'recados.js', 'transfer-hook.js',
]

// Nome da classe basta para reconhecer a camada: e a convencao ja usada no app.
const LAYER = /(Overlay|FullScreen|BootLoader|Backdrop|lyricsScreen|tabletSearchScreen|tunerDrawer|vshook-shell)$/
const SAFE = /vsh-safe|tablet-safe|vsh-app-pad|safe-area-inset/
const BOX = /^padding(-top|-bottom|-left|-right)?:|^inset:/
// A regra pode fixar a borda pelo deslocamento em vez do padding; ai o token
// seguro aparece nesses lados e a camada ja esta dentro da caixa.
const EDGE = /^(inset|top|right|bottom|left):/
const ALLOW = /safe-area-ok:/

function rules(css) {
  const out = []
  let depth = 0, selector = '', buffer = '', start = 0
  for (let i = 0; i < css.length; i++) {
    const c = css[i]
    if (c === '{') {
      if (depth === 0) { selector = buffer.trim(); start = i; buffer = ''; depth = 1 }
      else { depth++; buffer += c }
      continue
    }
    if (c === '}') {
      if (depth === 1) { out.push({ selector, body: buffer, line: css.slice(0, start).split('\n').length }); depth = 0; buffer = '' }
      else { depth--; buffer += c }
      continue
    }
    buffer += c
  }
  return out
}

// Regra dentro de @media conta a linha do @media: basta para achar no arquivo.
function flatten(css) {
  const out = []
  for (const rule of rules(css)) {
    if (/^@(media|supports)/.test(rule.selector)) {
      for (const inner of rules(rule.body)) out.push({ ...inner, line: rule.line })
    } else out.push(rule)
  }
  return out
}

const problems = []
for (const file of FILES) {
  const full = path.join(root, file)
  if (!fs.existsSync(full)) continue
  const source = fs.readFileSync(full, 'utf8')
  // No JS o CSS mora dentro de template string.
  const css = file.endsWith('.js') ? (source.match(/`[^`]*\{[^`]*\}[^`]*`/g) || []).join('\n') : source

  for (const rule of flatten(css)) {
    // So interessa a regra que mira a propria camada, nao um filho dela.
    const target = rule.selector.split(',')[0].trim().split(/\s+|>/).filter(Boolean).pop() || ''
    const classes = [...target.matchAll(/\.([A-Za-z][-A-Za-z0-9_]*)/g)].map((m) => m[1])
    if (!classes.some((name) => LAYER.test(name))) continue
    if (ALLOW.test(rule.body)) continue

    const body = rule.body.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\s+/g, '')
    const declarations = body.split(';')
    const box = declarations.filter((d) => BOX.test(d))
    if (!box.length) continue
    // Basta um lado da caixa citar o token: o recuo pode estar no padding ou
    // no deslocamento da propria camada.
    if (SAFE.test(declarations.filter((d) => BOX.test(d) || EDGE.test(d)).join(';'))) continue
    // inset:0 sozinho e valido: a camada cobre tudo e o recuo vem do padding.
    if (box.every((d) => /^inset:(0|auto)/.test(d))) continue

    problems.push(`${file}:${rule.line}  ${rule.selector.replace(/\s+/g, ' ').slice(0, 120)}\n    -> ${box.join('; ').slice(0, 120)}`)
  }
}

if (problems.length) {
  console.error('\nArea segura apagada em ' + problems.length + ' camada(s) de tela cheia:\n')
  problems.forEach((p) => console.error('  ' + p + '\n'))
  console.error('Troque o valor cru pelo minimo seguro — veja safe-area.css.\n')
  process.exit(1)
}
console.log('Area segura: todas as camadas de tela cheia respeitam a caixa da tela principal.')
