#ifndef BuildDir
#error BuildDir is required
#endif
[Setup]
AppId={{AD4C4654-AEDD-40BD-B04E-244F87B13A57}
AppName=CatLive Integration
AppVersion=1.29
AppPublisher=Hook Developer
DefaultDirName={localappdata}\Programs\CatLive Integration
DefaultGroupName=CatLive Integration
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#BuildDir}\installer
OutputBaseFilename=CatLive-Integration-1.29-Windows
SetupIconFile=..\..\JarasLive\Installer\Assets\CatLive.ico
UninstallDisplayIcon={app}\CatLiveIntegration.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
[Files]
Source: "{#BuildDir}\Release\CatLiveIntegration.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ThirdParty\httplib\LICENSE"; DestDir: "{app}\Licenses"; DestName: "cpp-httplib.txt"; Flags: ignoreversion
Source: "..\Resources\nlohmann-json-LICENSE.txt"; DestDir: "{app}\Licenses"; Flags: ignoreversion
[Icons]
Name: "{group}\CatLive Integration"; Filename: "{app}\CatLiveIntegration.exe"
[Run]
Filename: "{app}\CatLiveIntegration.exe"; Description: "{cm:LaunchProgram,CatLive Integration}"; Flags: nowait postinstall skipifsilent
