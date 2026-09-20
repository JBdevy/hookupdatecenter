const assert = require('assert')
const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '..')
const helper = fs.readFileSync(path.join(root, 'native', 'apple-peer-bridge', 'main.swift'), 'utf8')
const main = fs.readFileSync(path.join(root, 'src', 'main.js'), 'utf8')
const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build-release.yml'), 'utf8')

for (const token of [
  'NWListener', 'includePeerToPeer = true', '_vshook._tcp',
  'VSHOOK/1', '--director-port', '--musicians-port'
]) {
  assert(helper.includes(token), `Auxiliar macOS sem ${token}`)
}
for (const token of [
  'startApplePeerBridge', 'stopApplePeerBridge', 'applePeerBridgeProcess',
  "path.join(process.resourcesPath, 'apple-peer-bridge'"
]) {
  assert(main.includes(token), `Hook Center sem integração ${token}`)
}
const resources = packageJson.build.mac.extraResources || []
assert(resources.some((entry) => entry.to === 'apple-peer-bridge'),
  'Auxiliar Apple não está no pacote macOS')
assert(workflow.includes('scripts/build-apple-peer-bridge.sh'), 'Workflow não compila o auxiliar Apple')
assert(workflow.includes('lipo -verify_arch arm64 x86_64'), 'Workflow não valida binário universal')

console.log('Conexão direta Apple da Hook Center validada.')
