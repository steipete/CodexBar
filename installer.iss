; CodexBar native Windows tray installer
#define MyAppName "CodexBar"
#define MyAppPublisher "Peter Steinberger"
#define MyAppURL "https://github.com/steipete/CodexBar"
#define MyAppExeName "CodexBar.Windows.exe"

#ifndef MyAppArch
  #define MyAppArch "x64"
#endif

#ifndef publish
  #define publish "publish\windows\win-x64"
#endif

#if !FileExists(publish + "\CodexBar.Windows.exe")
  #error CodexBar.Windows.exe payload missing. Run Scripts\build_windows.ps1 installer after publishing the Windows app.
#endif

[Setup]
AppId={{C0DEXBAR-7RAY-W1ND-0001}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL=https://github.com/steipete/CodexBar/issues
AppUpdatesURL=https://github.com/steipete/CodexBar/releases
DefaultDirName={localappdata}\CodexBar
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=CodexBar-Setup-{#MyAppArch}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#MyAppExeName}
AppMutex=CodexBar.Windows.Tray
#if MyAppArch == "arm64"
ArchitecturesInstallIn64BitMode=arm64
ArchitecturesAllowed=arm64
#else
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startupicon"; Description: "Start CodexBar when Windows starts"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#publish}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\CodexBar Windows settings"; Filename: "{userappdata}\CodexBar\windows-settings.json"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
