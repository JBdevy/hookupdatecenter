const assert = require('assert')
const fs = require('fs')
const path = require('path')

const source = fs.readFileSync(path.resolve(__dirname, '..', 'src', 'main.js'), 'utf8')

assert(source.includes('LICENSE_OFFLINE_GRACE_MS = 15 * 24 * 60 * 60 * 1000'),
  'Aviso offline não começa depois dos 15 dias')
assert(source.includes('LICENSE_OFFLINE_WARNING_MS = 3 * 24 * 60 * 60 * 1000'),
  'Janela obrigatória de aviso não tem três dias')
assert(source.includes('if ((nowMs - lastOnlineAt) >= LICENSE_OFFLINE_GRACE_MS)'),
  'Primeiro acesso tardio não inicia uma nova janela de aviso')
assert(source.includes('warningCount < 3 &&'),
  'Os avisos não avançam em três etapas')
assert(source.includes('nowMs >= lastWarningAt + (24 * 60 * 60 * 1000)'),
  'Mais de um aviso pode ser contado no mesmo dia')
assert(source.includes('expired: active && warningStartedAt > 0 && warningCount >= 3 && now >= deadlineAt'),
  'Bloqueio pode ocorrer antes dos três avisos')
assert(source.includes('licenseOfflineWarningShownThisSession !== warningCount'),
  'Aberturas repetidas no mesmo dia não mostram o aviso atual')
const offlineCatchStart = source.indexOf("const currentLicense = store.get('license') || {}", source.indexOf('async function checkLicenseStatus'))
const offlineCatchEnd = source.indexOf('\n    if (manual) dialog.showErrorBox', offlineCatchStart)
const offlineCatch = source.slice(offlineCatchStart, offlineCatchEnd)
assert(!offlineCatch.includes('removeLocalLicense()'),
  'Hook Center ainda pode apagar o token antes dos três avisos da extensão')
assert(offlineCatch.includes('extensão é a autoridade desta sequência'),
  'Extensão não está definida como autoridade dos avisos')
assert(source.includes('É necessário conectar à internet para validar sua licença. Não fique muito tempo sem conexão com a internet.'),
  'Mensagem solicitada não foi aplicada')

console.log('LICENSE_OFFLINE_WARNING_OK: 15 dias + aviso obrigatório de 3 dias.')
