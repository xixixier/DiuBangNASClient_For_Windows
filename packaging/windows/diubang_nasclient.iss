; 铥棒文件 Windows 客户端安装包脚本（Inno Setup 6）
; 先执行 flutter build windows --release 并部署 MSVC 运行库，再用 ISCC 编译本脚本。

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "铥棒文件"
#define MyAppDirName "DiuBangNASClient"
#define MyAppPublisher "铥棒文件"
#define MyAppExeName "diubang_nasclient.exe"
#define MyAppId "{{6E2B9C47-3F1A-4D8E-9B65-2C7A1E4F8D90}"
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppDirName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=DiuBangNASClient-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
PrivilegesRequired=admin
AppMutex=Local\DiuBangNASClient.SingleInstance
CloseApplications=yes
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillApp"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "{#MyAppName}"; Flags: uninsdeletevalue dontcreatekey

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
