!macro customUnInstall
  ; Arquivo de licença atual
  Delete "$PROGRAMDATA\HookDeveloper\VSCore\sys_runtime.dat"
  RMDir "$PROGRAMDATA\HookDeveloper\VSCore"
  RMDir "$PROGRAMDATA\HookDeveloper"

  ; Licenças legadas
  Delete "$PUBLIC\vshook_license.json"
  Delete "$PROFILE\.vshook_license.json"

  ; Scripts instalados pelo Hook Update Center
  Delete "$PUBLIC\VS Hook APP\VS Hook.lua"
  Delete "$PUBLIC\VS Hook APP\Hook Lyrics.lua"
  Delete "$PUBLIC\VS Hook APP\Hook lyrics.lua"
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
  RMDir "$PUBLIC\VS Hook APP"
  RMDir "$APPDATA\REAPER\Scripts\VS Hook APP"
!macroend
