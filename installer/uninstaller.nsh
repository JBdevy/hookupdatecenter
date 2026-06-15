!macro customUnInstall
  ; Arquivo de licença atual em C:\ProgramData
  Delete "$COMMONAPPDATA\HookDeveloper\VSCore\sys_runtime.dat"
  RMDir "$COMMONAPPDATA\HookDeveloper\VSCore"
  RMDir "$COMMONAPPDATA\HookDeveloper"

  ; Pasta pública do Windows
  ReadEnvStr $0 "PUBLIC"
  StrCmp $0 "" 0 +2
  StrCpy $0 "$PROFILE\..\Public"

  ; Licenças legadas
  Delete "$0\vshook_license.json"
  Delete "$PROFILE\.vshook_license.json"

  ; Scripts instalados pelo Hook Update Center
  Delete "$0\VS Hook APP\VS Hook.lua"
  Delete "$0\VS Hook APP\Hook Lyrics.lua"
  Delete "$0\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook lyrics.lua"

  ; Plugins/Extensões do REAPER
  Delete "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll"
  Delete "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll"

  ; Diretórios vazios
  RMDir "$0\VS Hook APP"
  RMDir "$APPDATA\REAPER\Scripts\VS Hook APP"
!macroend
