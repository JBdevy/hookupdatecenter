# Runtime FFmpeg para Windows

O build Windows baixa o FFmpeg 8.1.x LGPL compartilhado do BtbN. O build
macOS não empacota nem instala FFmpeg; a extensão usa o vídeo nativo do sistema.

O instalador Windows copia esse runtime para
`REAPER/UserPlugins/VSHookRuntime/FFmpeg`. A pasta antiga `VLC` e removida
apenas depois que a nova copia passa na verificacao de integridade.
