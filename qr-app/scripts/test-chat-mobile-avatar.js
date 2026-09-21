const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.resolve(__dirname, '..')

for (const relativePath of ['chat.js', 'dist/chat.js']) {
  const source = fs.readFileSync(path.join(root, relativePath), 'utf8')
  assert.match(source, /class="chatMobileCameraMenuAction" data-avatar-action="change"/,
    `${relativePath}: alterar foto precisa ser uma ação nativa`)
  assert.match(source, /id="chatMobileAvatarInput" class="chatMobileNativeFileInput" type="file" accept="image\/\*"/,
    `${relativePath}: o seletor de imagem precisa permanecer associado ao toque`)
  assert.doesNotMatch(source, /chatMobileAvatarInput'\)\?\.click\(\)/,
    `${relativePath}: WebViews móveis podem bloquear click programático em input oculto`)
  assert.match(source, /if \(avatarMenu && chatState\?\.user\?\.id\) avatarMenu\.hidden = !avatarMenu\.hidden/,
    `${relativePath}: qualquer usuário autenticado deve editar tocando no avatar`)
  assert.match(source, /if \(avatarButton\) avatarButton\.hidden = !user\.id/,
    `${relativePath}: o botão Foto não pode depender de permissão administrativa`)
}

const css = fs.readFileSync(path.join(root, 'chat-app.css'), 'utf8')
assert.match(css, /\.chatMobileNativeFileInput\s*\{[^}]*opacity:\s*0;/s,
  'o input deve ficar invisível sem usar display:none/hidden')

console.log('CHAT_MOBILE_AVATAR_OK: seleção nativa e edição disponíveis para usuário comum.')
