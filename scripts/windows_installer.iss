; The AppId and previous install scope/path must remain stable across upgrades.
; Required ISCC defines: AppVersion, ReleaseDir, IconFile, PackageDir.
[Setup]
AppId={{8E9A5D2B-4F31-4C19-9A62-7B8D1E3F4A50}
AppName=Marco Movie
AppVersion={#AppVersion}
AppPublisher=Pilipala
DefaultDirName={autopf}\Marco Movie
DefaultGroupName=Marco Movie
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UsePreviousAppDir=yes
UsePreviousPrivileges=yes
UsePreviousTasks=yes
OutputDir={#PackageDir}
OutputBaseFilename=MarcoMovie-{#AppVersion}-windows-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\MarcoMovie-{#AppVersion}.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl,{#ChineseMessagesFile}"

[InstallDelete]
Type: filesandordirs; Name: "{app}\data\flutter_assets"
Type: filesandordirs; Name: "{app}\data\python"
Type: files; Name: "{app}\data\app.so"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\marco_movie.exe"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加快捷方式："

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Marco Movie"; Filename: "{app}\marco_movie.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MarcoMovie-{#AppVersion}.ico"
Name: "{autodesktop}\Marco Movie"; Filename: "{app}\marco_movie.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MarcoMovie-{#AppVersion}.ico"; Tasks: desktopicon
; Retain and refresh an existing shortcut even when an old install did not save task selection.
Name: "{autodesktop}\Marco Movie"; Filename: "{app}\marco_movie.exe"; WorkingDir: "{app}"; IconFilename: "{app}\MarcoMovie-{#AppVersion}.ico"; Check: RefreshExistingDesktopShortcut

[Run]
Filename: "{app}\marco_movie.exe"; Description: "立即启动 Marco Movie"; WorkingDir: "{app}"; Flags: nowait postinstall

[Code]
function RefreshExistingDesktopShortcut: Boolean;
begin
  Result := (not WizardIsTaskSelected('desktopicon')) and
    FileExists(ExpandConstant('{autodesktop}\Marco Movie.lnk'));
end;

// Inno Setup 6 uses a 32-bit setup process, including for x64 applications.
// Both pointer arguments are null; Integer keeps this compatible with its Pascal runtime.
procedure SHChangeNotify(wEventId: Integer; uFlags: Cardinal; dwItem1, dwItem2: Integer);
  external 'SHChangeNotify@shell32.dll stdcall';

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SHChangeNotify($08000000, 0, 0, 0);
end;
