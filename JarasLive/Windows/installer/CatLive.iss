#ifndef AppVersion
  #define AppVersion "1.01"
#endif
#ifndef PackageDirectory
  #error PackageDirectory must point to the tested CatLive package.
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required.
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

[Run]
Filename: "{app}\CatLive.exe"; Description: "{cm:LaunchProgram,CatLive}"; Flags: nowait postinstall skipifsilent
