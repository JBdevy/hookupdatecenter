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
for (const path of ['Windows/Assets/Teleprompter.html','Apple/Shared/TeleprompterRemote.swift']) {
 const source=readFileSync(new URL('../'+path,import.meta.url),'utf8');
 let code=source.slice(source.indexOf('function coloredText('),source.indexOf('function textNode('));
 if(path.endsWith('.swift'))code=code.replaceAll('\\\\','\\');
 const element=()=>({children:[],style:{},append(e){this.children.push(e)},replaceChildren(){this.children=[]}});
 const host=element(), content={clientWidth:800,clientHeight:500};
 const scope={document:{createElement:element},$:id=>id==='lyrics'?host:content,innerWidth:800,innerHeight:600,applyCase:v=>v,hex:v=>'#'+v.toString(16),color:()=> '#abcdef'};
 vm.createContext(scope);vm.runInContext(code,scope);
 const first='\x1eCatLiveText/1\n'+JSON.stringify([{text:'Primeira 🎵',color:0xff4040}]);
 const d={textStyled:'\x1eCatLiveColumns/1\n'+JSON.stringify([first,'Segunda'])};
 const settings={textScale:100,textBoxEnabled:true};scope.lyricColumns(d,settings);
 assert.equal(host.children.length,2);assert.equal(host.style.flexDirection,'row');assert.equal(host.children[0].children[0].children[0].textContent,'Primeira 🎵');assert.equal(host.children[0].children[0].children[0].style.color,'#ff4040');
 scope.innerWidth=400;scope.innerHeight=800;scope.lyricColumns(d,settings);assert.equal(host.style.flexDirection,'column');assert.equal(host.children[1].children[0].children[0].textContent,'Segunda');
 scope.lyricColumns({textStyled:'plain'},settings);assert.equal(host.style.width,'');assert.equal(host.style.height,'');
}
console.log('PASS: two independent colored columns render horizontally/vertically in both browser hosts');
