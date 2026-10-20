#ifndef AppVersion
  #define AppVersion "1.06"
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

#if !FileExists(PackageDirectory + "\StemSeparationRuntime\python\python.exe") || !FileExists(PackageDirectory + "\StemSeparationRuntime\stream_windows.py") || !FileExists(PackageDirectory + "\StemSeparationRuntime\5c90dfd2-34c22ccb.th") || !FileExists(PackageDirectory + "\StemSeparationRuntime\Licenses\Demucs-LICENSE.txt")
  #error The CatStem runtime, model and license are required in the tested package.
#endif
#if !FileExists(PackageDirectory + "\StemSeparationRuntime\openvino_backend.py") || !FileExists(PackageDirectory + "\StemSeparationRuntime\htdemucs6-openvino.xml") || !FileExists(PackageDirectory + "\StemSeparationRuntime\htdemucs6-openvino.bin") || !FileExists(PackageDirectory + "\StemSeparationRuntime\htdemucs6-openvino.json") || !FileExists(PackageDirectory + "\StemSeparationRuntime\runtime.json")
  #error The verified CatStem FP32 inference graph and runtime manifest are required.
#endif

[Setup]
AppId={{67D3087D-1528-496B-B48A-1371A0FDD915}
AppName=CatLive
AppVersion={#AppVersion}
AppPublisher=Hook Developer
AppComments=CatLive MultiTrack Workstation
VersionInfoDescription=CatLive Installer
VersionInfoProductName=CatLive
SetupIconFile=..\..\Installer\Assets\CatLive.ico
DefaultDirName={commonpf64}\CatLive
DisableDirPage=yes
UsePreviousAppDir=no
DefaultGroupName=CatLive
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
OutputDir={#OutputDirectory}
OutputBaseFilename=Catlive-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=120,110
WizardImageFile=..\..\Installer\Assets\windows-sidebar.bmp
WizardSmallImageFile=..\..\Installer\Assets\windows-header.bmp
WizardImageStretch=yes
DisableWelcomePage=no
DisableReadyPage=yes
UninstallDisplayIcon={app}\CatLive.exe
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[LangOptions]
DialogFontName=Segoe UI
DialogFontSize=9
WelcomeFontName=Segoe UI
WelcomeFontSize=20

[Messages]
brazilianportuguese.SetupWindowTitle=Instalar CatLive
brazilianportuguese.WelcomeLabel1=Seu palco, pronto.
brazilianportuguese.WelcomeLabel2=Áudio, vídeo e controle do show.%nUma estação para a sua apresentação.%n%nVamos instalar o CatLive {#AppVersion} no seu computador.
brazilianportuguese.WizardSelectDir=Um lugar para o CatLive
brazilianportuguese.SelectDirDesc=Escolha onde deseja instalar o aplicativo.
brazilianportuguese.WizardSelectTasks=Os últimos detalhes
brazilianportuguese.SelectTasksDesc=Escolha como deseja acessar o CatLive.
brazilianportuguese.WizardInstalling=Preparando o seu palco
brazilianportuguese.InstallingLabel=O CatLive está sendo instalado. Isso pode levar alguns minutos.
brazilianportuguese.StatusExtractFiles=Instalando o CatLive e seus recursos…
brazilianportuguese.StatusCreateIcons=Criando os atalhos…
brazilianportuguese.StatusCreateRegistryEntries=Configurando os projetos CatLive…
brazilianportuguese.StatusSavingUninstall=Concluindo a instalação…
brazilianportuguese.FinishedHeadingLabel=Pronto para o próximo show.
brazilianportuguese.FinishedLabelNoIcons=O CatLive {#AppVersion} está instalado.%n%nAbra o aplicativo e entre na sua conta para começar.
brazilianportuguese.FinishedLabel=O CatLive {#AppVersion} está instalado.%n%nAbra o aplicativo e entre na sua conta para começar.
brazilianportuguese.ClickFinish=Clique em Concluir para fechar o instalador.
english.SetupWindowTitle=Install CatLive
english.WelcomeLabel1=Your stage is ready.
english.WelcomeLabel2=Audio, video and show control.%nOne workstation for your performance.%n%nLet's install CatLive {#AppVersion} on your computer.
english.WizardSelectDir=A place for CatLive
english.SelectDirDesc=Choose where to install the application.
english.WizardSelectTasks=The finishing touches
english.SelectTasksDesc=Choose how you want to access CatLive.
english.WizardInstalling=Preparing your stage
english.InstallingLabel=CatLive is being installed. This may take a few minutes.
english.StatusExtractFiles=Installing CatLive and its resources…
english.StatusCreateIcons=Creating shortcuts…
english.StatusCreateRegistryEntries=Setting up CatLive projects…
english.StatusSavingUninstall=Finishing the installation…
english.FinishedHeadingLabel=Ready for your next show.
english.FinishedLabelNoIcons=CatLive {#AppVersion} is installed.%n%nOpen the app and sign in to get started.
english.FinishedLabel=CatLive {#AppVersion} is installed.%n%nOpen the app and sign in to get started.
english.ClickFinish=Click Finish to close the installer.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CatLive"; Filename: "{app}\CatLive.exe"
Name: "{commondesktop}\CatLive"; Filename: "{app}\CatLive.exe"; Tasks: desktopicon

[Registry]
Root: HKLM; Subkey: "Software\Classes\.jl\OpenWithProgids"; ValueType: string; ValueName: "CatLive.Project"; ValueData: ""; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\Classes\CatLive.Project"; ValueType: string; ValueName: ""; ValueData: "CatLive Project"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CatLive.Project\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\CatLive.exe,0"
Root: HKLM; Subkey: "Software\Classes\CatLive.Project\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\CatLive.exe"" ""%1"""

Root: HKLM; Subkey: "Software\Classes\.ziplive\OpenWithProgids"; ValueType: string; ValueName: "CatLive.Package"; ValueData: ""; Flags: uninsdeletevalue
Root: HKLM; Subkey: "Software\Classes\CatLive.Package"; ValueType: string; ValueName: ""; ValueData: "CatLive Portable Project"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\CatLive.Package\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\CatLive.exe,0"
Root: HKLM; Subkey: "Software\Classes\CatLive.Package\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\CatLive.exe"" ""%1"""

[Run]
Filename: "{app}\CatLive.exe"; Description: "{cm:LaunchProgram,CatLive}"; Flags: nowait postinstall skipifsilent

[Code]
procedure InitializeWizard();
var
  Signature: TNewStaticText;
begin
  // Native controls retain Windows accessibility, keyboard focus and DPI sizing.
  WizardForm.WelcomeLabel1.Font.Color := $002B2520;
  WizardForm.WelcomeLabel1.Font.Style := [fsBold];
  WizardForm.FinishedHeadingLabel.Font.Color := $002B2520;
  WizardForm.FinishedHeadingLabel.Font.Style := [fsBold];
  WizardForm.PageNameLabel.Font.Color := $002B2520;
  // Internal library filenames do not help someone installing the workstation.
  WizardForm.FilenameLabel.Visible := False;
  Signature := TNewStaticText.Create(WizardForm);
  Signature.Parent := WizardForm;
  Signature.Caption := 'CatLive {#AppVersion}  ·  Hook Developer';
  Signature.Font.Size := 8;
  Signature.Font.Color := $007B7168;
  Signature.SetBounds(ScaleX(18), WizardForm.NextButton.Top + ScaleY(7), ScaleX(220), ScaleY(20));
end;
