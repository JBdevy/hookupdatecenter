const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')
const mobile = fs.readFileSync(path.join(root, 'qr-app', 'transfer-hook.js'), 'utf8')
const service = fs.readFileSync(path.join(root, 'src', 'copy-project.js'), 'utf8')

function extractFunction(source, name) {
  const declarations = [
    `async function ${name}(`,
    `function ${name}(`,
    `const ${name} = async`,
  ]
  const start = declarations.reduce((found, declaration) => {
    const index = source.indexOf(declaration)
    return index >= 0 && (found < 0 || index < found) ? index : found
  }, -1)
  assert(start >= 0, `Função ausente: ${name}`)
  let depth = 0
  let string = ''
  let escaped = false
  const opening = source.indexOf('{', start)
  for (let index = opening; index < source.length; index += 1) {
    const char = source[index]
    if (string) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === string) string = ''
      continue
    }
    if (char === "'" || char === '"' || char === '`') {
      string = char
      continue
    }
    if (char === '{') depth += 1
    if (char === '}' && --depth === 0) return source.slice(start, index + 1)
  }
  throw new Error(`Fim da função ausente: ${name}`)
}

const receiveFiles = extractFunction(mobile, 'receiveFiles')
assert.match(receiveFiles, /waitForShareManifest\(\)/,
  'Recebimento deve obter status, acesso e manifesto na mesma negociação')
assert.doesNotMatch(receiveFiles, /share\/status/,
  'Recebimento não pode consultar Status novamente depois de confirmar disponibilidade')

const handshake = extractFunction(mobile, 'waitForShareManifest')
assert.match(handshake, /Number\(error\?\.statusCode\)\s*!==\s*403/,
  'Sessão trocada entre Status e Manifesto deve refazer a negociação')
assert.match(handshake, /return\s+\{\s*access,\s*manifest\s*\}/,
  'Acesso e manifesto precisam sair juntos da negociação')

const ensureHttpServer = extractFunction(service, 'ensureHttpServer')
assert.match(ensureHttpServer, /if\s*\(httpReadyPromise\)\s*return httpReadyPromise/,
  'Inicializações simultâneas devem compartilhar a mesma tentativa do servidor')
assert.match(ensureHttpServer, /finally\s*\{\s*httpReadyPromise\s*=\s*null\s*\}/,
  'Falha ao abrir o servidor deve liberar uma nova tentativa sem reiniciar a Hook Center')

console.log('DROP_HOOK_RELIABILITY_OK')
