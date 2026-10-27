import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
for (const path of ['Windows/Assets/Teleprompter.html', 'Apple/Shared/TeleprompterRemote.swift']) {
  const source = readFileSync(new URL('../' + path, import.meta.url), 'utf8');
  let code = source.slice(source.indexOf('function coloredText('), source.indexOf('function textNode('));
  if (path.endsWith('.swift')) code = code.replaceAll('\\\\', '\\');
  const element = () => ({ children: [], textContent: '', style: {}, append(child) { this.children.push(child); }, replaceChildren() { this.children = []; } });
  const scope = { document: { createElement: element }, applyCase: (v,s) => s.upper ? v.toUpperCase() : v, hex: v => '#' + v.toString(16).padStart(6, '0') };
  vm.createContext(scope); vm.runInContext(code, scope);
  const encoded = '\x1eCatLiveText/1\n' + JSON.stringify([{ text: 'É 🎵 ' }, { text: 'Am7\nG', color: 0xff4040 }, { text: '<script>literal' }]);
  const host = element(); scope.coloredText(host, 'fallback', encoded, {});
  assert.equal(host.children.map(v => v.textContent).join(''), 'É 🎵 Am7\nG<script>literal');
  assert.equal(host.children[1].style.color, '#ff4040'); assert.equal(host.children[0].style.color, undefined);
  scope.coloredText(host, 'fallback', encoded, { upper: true }); assert.equal(host.children[2].textContent, '<SCRIPT>LITERAL');
  scope.coloredText(host, 'legacy Am', undefined, {}); assert.equal(host.children[0].textContent, 'legacy Am');
  scope.coloredText(host, 'safe fallback', '\x1eCatLiveText/1\n[{"text":"x","color":"red;background:url(evil)"}]', {});
  assert.equal(host.children[0].textContent, 'safe fallback');
}
console.log('PASS: both browser teleprompters render selected colors, Unicode, case, literal HTML and legacy text safely');
