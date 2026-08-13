# Windows MIDI Services Runtime and Tools

O instalador binário não é armazenado no Git por exceder o limite normal de tamanho do GitHub.

Durante o build do Windows, `scripts/prepare-windows-midi.js` baixa o instalador oficial x64 da Microsoft e valida:

- Release: `rc-4`
- Arquivo original: `Windows.MIDI.Services.SDK.Runtime.and.Tools.1.0.17-rc.4.25-x64.exe`
- Tamanho: `219603123` bytes
- SHA-256: `5d241b52669a69795b7503f53eb082f83a1860e5ebc50849427b79f15c1a2546`
- Origem: <https://github.com/microsoft/MIDI/releases/tag/rc-4>

O arquivo validado é incluído somente no instalador Windows da Hook Center como
`resources/windows-midi-services/Windows-MIDI-Services-Runtime-and-Tools-x64.exe`.
