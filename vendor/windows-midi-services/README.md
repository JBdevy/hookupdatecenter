# Windows MIDI Services Runtime and Tools

O EXE montado é ignorado pelo Git. A cópia original é armazenada em `parts/runtime-x64.exe.part01` até `part05`, com no máximo 48 MiB por parte. Todos os cinco arquivos devem ser enviados junto com o script.

Durante o build do Windows, `scripts/prepare-windows-midi.js` reconstrói o instalador oficial x64 usando essas partes e valida o arquivo completo antes de incluí-lo. O link antigo da Microsoft é apenas uma alternativa para checkouts sem as partes; em 01/10/2026 ele retornava 404. A versão e as verificações permanecem:

- Release: `rc-4`
- Arquivo original: `Windows.MIDI.Services.SDK.Runtime.and.Tools.1.0.17-rc.4.25-x64.exe`
- Tamanho: `219603123` bytes
- SHA-256: `5d241b52669a69795b7503f53eb082f83a1860e5ebc50849427b79f15c1a2546`
- Origem: <https://github.com/microsoft/MIDI/releases/tag/rc-4>

O arquivo validado é incluído somente no instalador Windows da Hook Center como
`resources/windows-midi-services/Windows-MIDI-Services-Runtime-and-Tools-x64.exe`.
