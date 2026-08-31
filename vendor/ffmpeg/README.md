# Runtime FFmpeg da Hook Center

O build Windows baixa o FFmpeg 8.1.x LGPL compartilhado do BtbN. O build
macOS compila o fonte oficial 8.1.2 em duas arquiteturas e cria bibliotecas
universais x86_64 + arm64 com VideoToolbox.

Os instaladores copiam somente esse runtime para
`REAPER/UserPlugins/VSHookRuntime/FFmpeg`. A pasta antiga `VLC` e removida
apenas depois que a nova copia passa na verificacao de integridade.
