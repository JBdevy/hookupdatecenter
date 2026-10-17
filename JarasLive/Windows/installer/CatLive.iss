#ifndef AppVersion
  #define AppVersion "1.02"
#endif
#ifndef PackageDirectory
  #error PackageDirectory must point to the tested CatLive package.
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required.
#endif
#if !FileExists(PackageDirectory + "\CatLiveLame.dll")
  #error CatLiveLame.dll is missing from the tested package.
#endif
#if !FileExists(PackageDirectory + "\Licenses\LAME\COPYING") || !FileExists(PackageDirectory + "\Licenses\LAME\lame-3.100-source.tar.gz")
  #error The LAME licence and complete source archive must accompany the runtime.
#endif
#if !FileExists(PackageDirectory + "\Licenses\LAME\config.h") || !FileExists(PackageDirectory + "\Licenses\LAME\BUILD.txt")
  #error The LAME replacement build instructions and configuration are missing.
#endif
#if !FileExists(PackageDirectory + "\Licenses\dr_libs\LICENSE")
  #error The dr_libs licence is missing from the tested package.
#endif
#if !FileExists(PackageDirectory + "\CatLiveRuntime\FFmpeg\avcodec-62.dll") || !FileExists(PackageDirectory + "\CatLiveRuntime\FFmpeg\avformat-62.dll") || !FileExists(PackageDirectory + "\CatLiveRuntime\FFmpeg\avutil-60.dll") || !FileExists(PackageDirectory + "\CatLiveRuntime\FFmpeg\swresample-6.dll") || !FileExists(PackageDirectory + "\CatLiveRuntime\FFmpeg\swscale-9.dll")
  #error The FFmpeg video runtime is missing from the tested package.
#endif
#if !FileExists(PackageDirectory + "\Licenses\FFmpeg\COPYING.LGPLv2.1")
  #error The FFmpeg licence is missing from the tested package.
#endif

[Setup]
AppId={{67D3087D-1528-496B-B48A-1371A0FDD915}
AppName=CatLive
AppVersion={#AppVersion}
AppPublisher=Hook Developer
DefaultDirName={localappdata}\Programs\CatLive
DefaultGroupName=CatLive
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
OutputDir={#OutputDirectory}
OutputBaseFilename=Catlive-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\CatLive.exe
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CatLive"; Filename: "{app}\CatLive.exe"
Name: "{autodesktop}\CatLive"; Filename: "{app}\CatLive.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\.jl\OpenWithProgids"; ValueType: string; ValueName: "CatLive.Project"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\CatLive.Project"; ValueType: string; ValueName: ""; ValueData: "CatLive Project"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\CatLive.Project\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\CatLive.exe,0"
Root: HKCU; Subkey: "Software\Classes\CatLive.Project\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\CatLive.exe"" ""%1"""

Root: HKCU; Subkey: "Software\Classes\.ziplive\OpenWithProgids"; ValueType: string; ValueName: "CatLive.Package"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\CatLive.Package"; ValueType: string; ValueName: ""; ValueData: "CatLive Portable Project"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\CatLive.Package\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\CatLive.exe,0"
Root: HKCU; Subkey: "Software\Classes\CatLive.Package\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\CatLive.exe"" ""%1"""

[Run]
Filename: "{app}\CatLive.exe"; Description: "{cm:LaunchProgram,CatLive}"; Flags: nowait postinstall skipifsilent
