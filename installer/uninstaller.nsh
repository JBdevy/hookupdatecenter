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
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\ReaperScripts"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp"
  CreateDirectory "$TEMP\HookCenterUpgradeBackup\UserPlugins"

  IfFileExists "$R9\HookDeveloper\VSCore\sys_runtime.dat" 0 +2
    CopyFiles /SILENT "$R9\HookDeveloper\VSCore\sys_runtime.dat" "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat"

  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Beta.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Beta.lua"
  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook APP\VS Hook Estable.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScriptsApp\VS Hook Estable.lua"

  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook Beta.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook Beta.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Beta.lua"
  IfFileExists "$APPDATA\REAPER\Scripts\VS Hook Estable.lua" 0 +2
    CopyFiles /SILENT "$APPDATA\REAPER\Scripts\VS Hook Estable.lua" "$TEMP\HookCenterUpgradeBackup\ReaperScripts\VS Hook Estable.lua"

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
  ; nsExec mantém o processo de console oculto. ExecWait abria uma janela de CMD
  ; durante a instalação mesmo quando o icacls concluía normalmente.
  nsExec::ExecToLog 'icacls "$R9\HookDeveloper\HookCenter" /grant *S-1-5-32-545:(OI)(CI)M /T /C'
  Pop $R7

  ; O companion do Teleprompt e os temas ja fazem parte desta instalacao da
  ; Hook Center. Assim a primeira abertura nao precisa copiar uma pasta grande
  ; enquanto a janela ainda esta iniciando. O main.js mantem um fallback apenas
  ; para instalacoes antigas ou que tenham ficado incompletas.
  ; O instalador e por maquina, mas estes arquivos pertencem ao perfil do
  ; usuario que executa o REAPER. Sem este contexto, $APPDATA aponta para
  ; C:\ProgramData e cria uma pasta UserPlugins que o REAPER nao utiliza.
  SetShellVarContext current
  IfFileExists "$INSTDIR\resources\vshook-companion\VS Hook Teleprompt Settings.exe" 0 vshook_tp_settings_done
    CreateDirectory "$APPDATA\REAPER\UserPlugins\VSHookTelepromptSettings"
    nsExec::ExecToLog 'robocopy "$INSTDIR\resources\vshook-companion" "$APPDATA\REAPER\UserPlugins\VSHookTelepromptSettings" /E /NFL /NDL /NJH /NJS /NC /NS'
    Pop $R7
  vshook_tp_settings_done:

  IfFileExists "$INSTDIR\resources\vshook-themes\*.*" 0 vshook_themes_done
    CreateDirectory "$APPDATA\REAPER\ColorThemes"
    nsExec::ExecToLog 'robocopy "$INSTDIR\resources\vshook-themes" "$APPDATA\REAPER\ColorThemes" /E /NFL /NDL /NJH /NJS /NC /NS'
    Pop $R7
  vshook_themes_done:

  ; O VLC também vem dentro do instalador da Hook Center. Extraímos o runtime
  ; antes da primeira abertura, sem baixar nada na máquina do cliente. A troca
  ; é transacional para não substituir um runtime válido por uma extração falha.
  IfFileExists "$INSTDIR\resources\vlc-runtime\vlc-3.0.23-win64.zip" 0 vshook_vlc_done
  IfFileExists "$APPDATA\REAPER\UserPlugins\VSHookRuntime\VLC\libvlc.dll" 0 vshook_vlc_install
  IfFileExists "$APPDATA\REAPER\UserPlugins\VSHookRuntime\VLC\libvlccore.dll" 0 vshook_vlc_install
  IfFileExists "$APPDATA\REAPER\UserPlugins\VSHookRuntime\VLC\plugins\*.*" vshook_vlc_done vshook_vlc_install
  vshook_vlc_install:
    InitPluginsDir
    File /oname=$PLUGINSDIR\install-vlc-runtime.ps1 "${PROJECT_DIR}\installer\install-vlc-runtime.ps1"
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\install-vlc-runtime.ps1" -Archive "$INSTDIR\resources\vlc-runtime\vlc-3.0.23-win64.zip" -RuntimeRoot "$APPDATA\REAPER\UserPlugins\VSHookRuntime"'
    Pop $R7
    StrCmp $R7 "0" vshook_vlc_done
      DetailPrint "O runtime VLC será concluído na próxima abertura da Hook Center com o REAPER fechado."
  vshook_vlc_done:
  SetShellVarContext all

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
  ; A extensão anterior não pode permanecer ao lado de reaper_VSHookExt.dll:
  ; o REAPER carrega as duas quando os nomes coexistem.
  Delete "$APPDATA\REAPER\UserPlugins\reaper_vshook.dll"

  IfFileExists "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat" 0 +3
    CreateDirectory "$R9\HookDeveloper\VSCore"
    CopyFiles /SILENT "$TEMP\HookCenterUpgradeBackup\ProgramData\sys_runtime.dat" "$R9\HookDeveloper\VSCore\sys_runtime.dat"

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
  Delete "$APPDATA\REAPER\UserPlugins\reaper_VSHookExt.dll"
  Delete "$APPDATA\REAPER\UserPlugins\reaper_js_ReaScriptAPI64.dll"
  RMDir /r "$APPDATA\REAPER\UserPlugins\VSHookTelepromptSettings"

  ; Diretórios vazios
  RMDir "$0\VS Hook APP"
  RMDir "$APPDATA\REAPER\Scripts\VS Hook APP"

  skip_hook_data_cleanup:
!macroend
