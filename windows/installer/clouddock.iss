; 云坞（CloudDock）的 Windows 安装包（Inno Setup 6）。
; CI 用 ISCC.exe 编译，版本号 / 路径都由命令行 /D 传入，脚本里不写死任何机器路径：
;   ISCC.exe /DAppVersion=1.2.4 /DRepoRoot=... /DSourceDir=... /DOutputDir=... /DOutputBase=...
; 本地想试打：先在 pfm-frontend 根目录 `bash dev.sh build windows`，再
;   ISCC.exe /DAppVersion=1.2.4 windows\installer\clouddock.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef RepoRoot
  #define RepoRoot "..\.."
#endif

#ifndef SourceDir
  #define SourceDir RepoRoot + "\build\windows\x64\runner\Release"
#endif

#ifndef OutputDir
  #define OutputDir RepoRoot + "\dist"
#endif

#ifndef OutputBase
  #define OutputBase "clouddock-setup"
#endif

[Setup]
; AppId 一旦发布就不能改：Windows 靠它认「同一个应用」，改了等于换了产品、旧版卸不掉
AppId={{7C1F4B62-3D2E-4A18-9C55-2E8D3A6B41F0}
AppName=云坞 (CloudDock)
AppVersion={#AppVersion}
AppVerName=云坞 (CloudDock) {#AppVersion}
AppPublisher=com.shifangyuan
AppPublisherURL=https://github.com/jenken827/pfm-frontend
AppSupportURL=https://github.com/jenken827/pfm-frontend
AppUpdatesURL=https://github.com/jenken827/pfm-frontend/releases
; 装到当前用户目录，不需要管理员权限，也就不弹 UAC
DefaultDirName={autopf}\CloudDock
DefaultGroupName=云坞
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#RepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\clouddock.exe
LicenseFile={#RepoRoot}\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 构建产物是 x64（flutter build windows 只出 x64）
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\云坞"; Filename: "{app}\clouddock.exe"
Name: "{autodesktop}\云坞"; Filename: "{app}\clouddock.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\clouddock.exe"; Description: "Launch CloudDock"; Flags: nowait postinstall skipifsilent
