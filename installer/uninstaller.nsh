; Hook Center NSIS hooks
; - Desinstalação real: remove licença local, scripts e plugins instalados pelo Hook Center.
; - Atualização/reinstalação: preserva licença, scripts e plugins para não desativar o cliente.

!macro customInit
  ; Antes de instalar/atualizar, salva uma cópia dos dados que não podem ser perdidos
  ; caso o instalador antigo execute o uninstaller durante a atualização.
  ReadEnvStr $R9 "PROGRAMDATA"
  StrCmp $R9 "" 0 +2
  StrCpy $R9 "C:\ProgramData"

  ReadEnvStr $R8 "PUBLIC"
  StrCmp $R8 "" 0 +2
  StrCpy $R8 "$PROFILE\..\Public"

  RMDir /r "$TEMP\HookCenterUpgradeBackup"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\ProgramData"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\ReaperScripts"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\UserPlugins"

  IfFileExists "$R9\HookDeveloper\VSCore\sys_runtime.dat" 0 +2
    CopyFiles /SILENT "$R9\HookDeveloper\VSCore\sys_runtime.dat" "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat"

  IfFileExists "$R8\VS Hook APP\VS Hook Beta.lua" 0 +2
    CopyFiles /SILENT "$R8\VS Hook APP\VS Hook Beta.lua" "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Beta.lua"
  IfFileExists "$R8\VS Hook APP\VS Hook Estable.lua" 0 +2
    CopyFiles /SILENT "$R8\VS Hook APP\VS Hook Estable.lua" "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Estable.lua"

  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Beta.lua"
  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Estable.lua"

  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook Beta.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook Beta.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Beta.lua"
  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook Estable.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook Estable.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Estable.lua"

  IfFileExists "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll" "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_vshook.dll"
  IfFileExists "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll" "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_js_ReaScriptAPI64.dll"

  ; Flag lida pelo uninstaller novo. Se uma atualização executar o uninstaller,
  ; ele não deve limpar licença/script/plugin.
  CreateDirectory "$R9\HookDeveloper\VSCore"
  FileOpen $R7 "$R9\HookDeveloper\VSCore\installing.flag" w
  FileWrite $R7 "installing"
  FileClose $R7
!macroend

!macro customInstall
  ; Restaura dados preservados depois da instalação/atualização.
  ReadEnvStr $R9 "PROGRAMDATA"
  StrCmp $R9 "" 0 +2
  StrCpy $R9 "C:\ProgramData"

  ReadEnvStr $R8 "PUBLIC"
  StrCmp $R8 "" 0 +2
  StrCpy $R8 "$PROFILE\..\Public"

  ; Pasta externa do app QR atualizável.
  ; O Hook Center serve os arquivos daqui e pode atualizar essa pasta pelo backend
  ; sem reinstalar o Electron inteiro.
  CreateDirectory "$R9\HookDeveloper\HookCenter"
  CreateDirectory "$R9\HookDeveloper\HookCenter\qr-app"
  ExecWait 'icacls "$R9\HookDeveloper\HookCenter" /grant *S-1-5-32-545:(OI)(CI)M /T /C'

  ; Limpa nomes antigos para não deixar lixo da nomes antigos.
  Delete "$R8\VS Hook APP\VS Hook Pro.lua"
  Delete "$R8\VS Hook APP\VS Hook Basic.lua"
  Delete "$R8\VS Hook APP\VS Hook.lua"
  Delete "$R8\VS Hook APP\Hook Lyrics.lua"
  Delete "$R8\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Pro.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Basic.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Pro.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Basic.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook lyrics.lua"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat" 0 +3
    CreateDirectory "$R9\HookDeveloper\VSCore"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat" "$R9\HookDeveloper\VSCore\sys_runtime.dat"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Beta.lua" 0 +3
    CreateDirectory "$R8\VS Hook APP"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Beta.lua" "$R8\VS Hook APP\VS Hook Beta.lua"
  IfFileExists "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Estable.lua" 0 +3
    CreateDirectory "$R8\VS Hook APP"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\PublicVSHookApp\VS Hook Estable.lua" "$R8\VS Hook APP\VS Hook Estable.lua"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Beta.lua" 0 +3
    CreateDirectory "$APPDATA\REAPER\Scripts\VS Hook APP"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Beta.lua" "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua"
  IfFileExists "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Estable.lua" 0 +3
    CreateDirectory "$APPDATA\REAPER\Scripts\VS Hook APP"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Estable.lua" "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Beta.lua" 0 +3
    CreateDirectory "$APPDATA\REAPER\Scripts"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Beta.lua" "$APPDATA\REAPER\Scripts\VS Hook Beta.lua"
  IfFileExists "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Estable.lua" 0 +3
    CreateDirectory "$APPDATA\REAPER\Scripts"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Estable.lua" "$APPDATA\REAPER\Scripts\VS Hook Estable.lua"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_vshook.dll" 0 +3
    CreateDirectory "$APPDATA\REAPER\UserPlugins"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_vshook.dll" "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll"
  IfFileExists "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_js_ReaScriptAPI64.dll" 0 +3
    CreateDirectory "$APPDATA\REAPER\UserPlugins"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\UserPlugins\reaper_js_ReaScriptAPI64.dll" "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll"

  Delete "$R9\HookDeveloper\VSCore\installing.flag"
  RMDir /r "$TEMP\HookCenterUpgradeBackup"
!macroend

!macro customUnInstall
  ReadEnvStr $1 "PROGRAMDATA"
  StrCmp $1 "" 0 +2
  StrCpy $1 "C:\ProgramData"

  ; Se este uninstaller for chamado durante atualização/reinstalação,
  ; mantém licença, scripts e plugins.
  IfFileExists "$1\HookDeveloper\VSCore\installing.flag" skip_hook_data_cleanup 0

  ; Arquivo de licença atual em C:\ProgramData
  Delete "$1\HookDeveloper\VSCore\sys_runtime.dat"
  Delete "$1\HookDeveloper\VSCore\installing.flag"
  RMDir "$1\HookDeveloper\VSCore"
  RMDir "$1\HookDeveloper"

  ; Pasta pública do Windows
  ReadEnvStr $0 "PUBLIC"
  StrCmp $0 "" 0 +2
  StrCpy $0 "$PROFILE\..\Public"

  ; App QR externo atualizado pelo backend
  RMDir /r "$1\HookDeveloper\HookCenter\qr-app"
  RMDir "$1\HookDeveloper\HookCenter"

  ; Licenças legadas
  Delete "$0\vshook_license.json"
  Delete "$PROFILE\.vshook_license.json"

  ; Scripts instalados pelo Hook Update Center
  Delete "$0\VS Hook APP\VS Hook Beta.lua"
  Delete "$0\VS Hook APP\VS Hook Estable.lua"
  Delete "$0\VS Hook APP\VS Hook Pro.lua"
  Delete "$0\VS Hook APP\VS Hook Basic.lua"
  Delete "$0\VS Hook APP\VS Hook.lua"
  Delete "$0\VS Hook APP\Hook Lyrics.lua"
  Delete "$0\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Pro.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Basic.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook APP\Hook lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Beta.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Estable.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Pro.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook Basic.lua"
  Delete "$APPDATA\REAPER\Scripts\VS Hook.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook Lyrics.lua"
  Delete "$APPDATA\REAPER\Scripts\Hook lyrics.lua"

  ; Plugins/Extensões do REAPER
  Delete "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll"
  Delete "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll"

  ; Diretórios vazios
  RMDir "$0\VS Hook APP"
  RMDir "$APPDATA\REAPER\Scripts\VS Hook APP"

  skip_hook_data_cleanup:
!macroend
