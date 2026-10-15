import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../Source');
for (const filename of fs.readdirSync(directory).filter(name => /\.(cpp|h)$/.test(name))) {
  const file = path.join(directory, filename);
  const source = fs.readFileSync(file, 'utf8');
  const output = source.replace(/"(?:\\.|[^"\\])*"(?:\s*"(?:\\.|[^"\\])*")*/g, (literal, offset) => {
    if (!/[^\x00-\x7f]/.test(literal)) return literal;
    const before = source.slice(Math.max(0, offset - 120), offset);
    if (/(?:String::fromUTF8|std::runtime_error)\s*\(\s*$/.test(before)) return literal;
    if (/\.name\s*=\s*$/.test(before)) return literal; // Core model names are std::string UTF-8.
    return `String::fromUTF8(${literal})`;
  });
  if (source !== output) fs.writeFileSync(file, output);
}
