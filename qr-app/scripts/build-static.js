const fs = require('fs')
const path = require('path')
const root = path.resolve(__dirname, '..')
const dist = path.join(root, 'dist')
const skip = new Set(['dist', 'node_modules', 'android', '.git', '.github', 'scripts'])
function rm(target){ if(fs.existsSync(target)) fs.rmSync(target,{recursive:true,force:true}) }
function mkdir(target){ fs.mkdirSync(target,{recursive:true}) }
function copyRecursive(src,dest){
  const stat = fs.statSync(src)
  if(stat.isDirectory()){
    const base = path.basename(src)
    if(skip.has(base)) return
    mkdir(dest)
    for(const item of fs.readdirSync(src)) copyRecursive(path.join(src,item), path.join(dest,item))
    return
  }
  const base = path.basename(src)
  if(['package.json','package-lock.json','capacitor.config.json','vite.config.js','README.md'].includes(base)) return
  mkdir(path.dirname(dest))
  fs.copyFileSync(src,dest)
}
rm(dist); mkdir(dist)
for(const item of fs.readdirSync(root)) copyRecursive(path.join(root,item), path.join(dist,item))
if(!fs.existsSync(path.join(dist,'index.html'))) throw new Error('dist/index.html não foi gerado')
console.log('Build estático concluído.')
