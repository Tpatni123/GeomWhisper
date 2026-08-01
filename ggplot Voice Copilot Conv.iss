#define MyAppName "ggplot Voice Copilot (Multi-LLM)"
#define MyAppVersion "1.0.0"
#define MyAppExeName "ggplot Voice Copilot Conv.bat"
#define MyAppPublisher "ggplot Voice Copilot"
#define MyAppURL ""
; R version and URL are resolved dynamically at install time by querying the CRAN directory listing.

[Setup]
AppName = {#MyAppName}
AppId = {{D7E5F8A1-B2C3-4D56-E7F8-9A0B1C2D3E4F}
DefaultDirName = {userpf}\{#MyAppName}
DefaultGroupName = {#MyAppName}
OutputDir = installer_output
OutputBaseFilename = setup_{#MyAppName}
SetupIconFile = setup.ico
AppVersion = {#MyAppVersion}
AppPublisher = {#MyAppPublisher}
AppPublisherURL = {#MyAppURL}
AppSupportURL = {#MyAppURL}
AppUpdatesURL = {#MyAppURL}
PrivilegesRequired = lowest
InfoBeforeFile = infobefore.txt
InfoAfterFile = infoafter.txt
Compression = lzma2/ultra64
SolidCompression = yes
ArchitecturesInstallIn64BitMode = x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\default.ico"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{userprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\default.ico"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\default.ico"

[Files]
Source: "{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "default.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "setup.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "global.R"; DestDir: "{app}"; Flags: ignoreversion
Source: "server.R"; DestDir: "{app}"; Flags: ignoreversion
Source: "ui.R"; DestDir: "{app}"; Flags: ignoreversion
Source: "start.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "launch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "www\speech.js"; DestDir: "{app}\www"; Flags: ignoreversion
Source: "www\styles.css"; DestDir: "{app}\www"; Flags: ignoreversion
Source: "skills\nature.md"; DestDir: "{app}\skills"; Flags: ignoreversion
Source: "skills\apa.md"; DestDir: "{app}\skills"; Flags: ignoreversion
Source: "images\jade wang.JPG"; DestDir: "{app}\images"; Flags: ignoreversion
Source: "images\tushar patni.JPG"; DestDir: "{app}\images"; Flags: ignoreversion
Source: "images\yimei li.JPG"; DestDir: "{app}\images"; Flags: ignoreversion

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent shellexec

[Code]
// --- Diagnostic logging + comprehensive R detection ---

var
  DiagLog: String;
  GBestMajor, GBestMinor: Integer;
  GBestVersion: String;

procedure Log(Msg: String);
begin
  DiagLog := DiagLog + Msg + #13#10;
end;

procedure SaveLog;
var
  LogPath: String;
begin
  LogPath := ExpandConstant('{userdesktop}') + '\ggplot_installer_diag.log';
  Log('--- Saving log to: ' + LogPath + ' ---');
  SaveStringToFile(LogPath, DiagLog, False);
end;

// Parse version from folder name like "R-4.5.1" and update global best
procedure CheckRFolder(BaseDir, EntryName: String);
var
  v, r, cp: String;
  dp, ma, mi: Integer;
begin
  if (Length(EntryName) < 3) or (Copy(EntryName, 1, 2) <> 'R-') then Exit;
  v := Copy(EntryName, 3, Length(EntryName) - 2);
  cp := BaseDir + '\' + EntryName + '\bin\Rscript.exe';
  Log('      Version: ' + v + '  Path: ' + cp);
  if not FileExists(cp) then
  begin
    Log('      -> Rscript.exe NOT found');
    Exit;
  end;
  Log('      -> Rscript.exe EXISTS');
  dp := Pos('.', v);
  if dp = 0 then Exit;
  ma := StrToIntDef(Copy(v, 1, dp - 1), 0);
  r := Copy(v, dp + 1, Length(v) - dp);
  dp := Pos('.', r);
  if dp > 0 then
    mi := StrToIntDef(Copy(r, 1, dp - 1), 0)
  else
    mi := StrToIntDef(r, 0);
  Log('      Parsed: Major=' + IntToStr(ma) + ' Minor=' + IntToStr(mi));
  if (ma > GBestMajor) or ((ma = GBestMajor) and (mi > GBestMinor)) then
  begin
    GBestMajor := ma;
    GBestMinor := mi;
    GBestVersion := v;
    Log('      -> NEW BEST: ' + v);
  end;
end;

// Check a direct install path like D:\R-4.3.1 or C:\Users\x\...\R-4.5.1
procedure CheckDirectPath(InstPath: String);
var
  LastSlash: Integer;
  Folder: String;
begin
  Log('  Checking direct path: ' + InstPath);
  if not DirExists(InstPath) then
  begin
    Log('    -> does NOT exist');
    Exit;
  end;
  if not FileExists(InstPath + '\bin\Rscript.exe') then
  begin
    Log('    -> bin\Rscript.exe NOT found');
    Exit;
  end;
  Log('    -> bin\Rscript.exe EXISTS');
  LastSlash := Length(InstPath);
  while (LastSlash > 0) and (InstPath[LastSlash] <> '\') do
    Dec(LastSlash);
  if LastSlash > 0 then
    Folder := Copy(InstPath, LastSlash + 1, Length(InstPath) - LastSlash)
  else
    Folder := InstPath;
  Log('    Folder name: ' + Folder);
  CheckRFolder(Copy(InstPath, 1, LastSlash - 1), Folder);
end;

// Scan a directory for R-* subfolders
procedure ScanDirForR(SearchDir: String);
var
  FindRec: TFindRec;
begin
  Log('  Scanning: ' + SearchDir);
  if not DirExists(SearchDir) then
  begin
    Log('    -> does NOT exist');
    Exit;
  end;
  Log('    -> exists');
  if FindFirst(SearchDir + '\R-*', FindRec) then
  try
    repeat
      Log('    Entry: ' + FindRec.Name + ' (attr=' + IntToStr(FindRec.Attributes) + ')');
      if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        CheckRFolder(SearchDir, FindRec.Name);
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

function FindBestR(var OutVersion: String): Boolean;
var
  RegVal: String;
begin
  GBestMajor := 0;
  GBestMinor := 0;
  GBestVersion := '';

  Log('=== FindBestR START ===');

  // 1. Log registry keys
  Log('--- Registry scan ---');
  if RegQueryStringValue(HKLM, 'SOFTWARE\R-core\R', 'InstallPath', RegVal) then
    Log('  HKLM R\InstallPath = ' + RegVal)
  else
    Log('  HKLM R\InstallPath = NOT FOUND');
  if RegQueryStringValue(HKLM, 'SOFTWARE\R-core\R64', 'InstallPath', RegVal) then
    Log('  HKLM R64\InstallPath = ' + RegVal)
  else
    Log('  HKLM R64\InstallPath = NOT FOUND');
  if RegQueryStringValue(HKCU, 'SOFTWARE\R-core\R', 'InstallPath', RegVal) then
    Log('  HKCU R\InstallPath = ' + RegVal)
  else
    Log('  HKCU R\InstallPath = NOT FOUND');
  if RegQueryStringValue(HKCU, 'SOFTWARE\R-core\R64', 'InstallPath', RegVal) then
    Log('  HKCU R64\InstallPath = ' + RegVal)
  else
    Log('  HKCU R64\InstallPath = NOT FOUND');

  // 2. Check every registry InstallPath directly
  Log('--- Direct registry path checks ---');
  if RegQueryStringValue(HKLM, 'SOFTWARE\R-core\R', 'InstallPath', RegVal) then
    CheckDirectPath(RegVal);
  if RegQueryStringValue(HKLM, 'SOFTWARE\R-core\R64', 'InstallPath', RegVal) then
    CheckDirectPath(RegVal);
  if RegQueryStringValue(HKCU, 'SOFTWARE\R-core\R', 'InstallPath', RegVal) then
    CheckDirectPath(RegVal);
  if RegQueryStringValue(HKCU, 'SOFTWARE\R-core\R64', 'InstallPath', RegVal) then
    CheckDirectPath(RegVal);

  // 3. Scan standard directories for R-* subfolders
  Log('--- File-system scan ---');
  ScanDirForR(ExpandConstant('{sd}') + '\Program Files\R');
  ScanDirForR(ExpandConstant('{sd}') + '\Program Files (x86)\R');
  ScanDirForR(ExpandConstant('{localappdata}') + '\Programs\R');

  OutVersion := GBestVersion;
  Log('Best R found: ' + GBestVersion + ' (Major=' + IntToStr(GBestMajor) + ' Minor=' + IntToStr(GBestMinor) + ')');
  Result := (GBestVersion <> '');
  Log('=== FindBestR END ===');
end;

function GetInstalledRVersion: String;
var
  Ver: String;
begin
  if FindBestR(Ver) then
    Result := Ver
  else
    Result := '';
end;

function RNeeded: Boolean;
var
  Ver, Rest: String;
  DotPos, Major, Minor: Integer;
begin
  Result := True;
  if not FindBestR(Ver) then
  begin
    Log('RNeeded: No R found at all -> True');
    Exit;
  end;
  DotPos := Pos('.', Ver);
  if DotPos = 0 then Exit;
  Major := StrToIntDef(Copy(Ver, 1, DotPos - 1), 0);
  Rest := Copy(Ver, DotPos + 1, Length(Ver) - DotPos);
  DotPos := Pos('.', Rest);
  if DotPos > 0 then
    Minor := StrToIntDef(Copy(Rest, 1, DotPos - 1), 0)
  else
    Minor := StrToIntDef(Rest, 0);
  Result := not ((Major > 4) or ((Major = 4) and (Minor >= 4)));
  Log('RNeeded: ver=' + Ver + ' Major=' + IntToStr(Major) + ' Minor=' + IntToStr(Minor) + ' needed=' + IntToStr(Ord(Result)));
end;

function DownloadAndInstallR: Boolean;
var
  InstallerPath: string;
  ExecResult: Integer;
begin
  Result := False;
  // Use %TEMP% so the path matches exactly what PowerShell writes to.
  InstallerPath := GetEnv('TEMP') + '\R-latest-win.exe';

  // Step 1: Query CRAN's directory listing for the current release filename,
  // then download it. Forces TLS 1.2 (required on older Windows).
  // Fallback chain: Invoke-WebRequest -> WebClient.DownloadFile -> BITS transfer.
  // Exit code 0 = success; 1 = all download methods failed; 2 = version not found on page.
  MsgBox('Downloading the latest R from CRAN. This may take a few minutes depending on your internet connection.' + #13#10 + 'Click OK to begin.', mbInformation, MB_OK);
  if not Exec('powershell.exe',
    '-NoProfile -NonInteractive -Command "' +
      '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ' +
      'try { ' +
        '$page = (Invoke-WebRequest -Uri ''https://cran.r-project.org/bin/windows/base/'' -UseBasicParsing -ErrorAction Stop).Content; ' +
        '$m = [regex]::Match($page, ''href=.(R-\d+\.\d+\.\d+-win\.exe).''); ' +
        '$fn = $m.Groups[1].Value; ' +
        'if (-not $fn) { exit 2 }; ' +
        '$url = ''https://cran.r-project.org/bin/windows/base/'' + $fn; ' +
        '$out = $env:TEMP + ''\R-latest-win.exe''; ' +
        '$ok = $false; ' +
        'try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop; $ok = $true } catch {}; ' +
        'if (-not $ok) { try { (New-Object System.Net.WebClient).DownloadFile($url,$out); $ok = $true } catch {} }; ' +
        'if (-not $ok) { try { Start-BitsTransfer -Source $url -Destination $out -ErrorAction Stop; $ok = $true } catch {} }; ' +
        'if (-not $ok) { exit 1 } ' +
      '} catch { exit 1 }"',
    '', SW_HIDE, ewWaitUntilTerminated, ExecResult) then
  begin
    MsgBox('Could not launch PowerShell to download R.' + #13#10 +
           'Please install the latest R manually from https://cran.r-project.org', mbError, MB_OK);
    Exit;
  end;
  if ExecResult <> 0 then
  begin
    MsgBox('Failed to download R.' + #13#10 + #13#10 +
           'Common causes:' + #13#10 +
           '  - Firewall or antivirus blocking the download' + #13#10 +
           '  - No internet connection' + #13#10 +
           '  - Corporate proxy required' + #13#10 + #13#10 +
           'Please install the latest R manually from:' + #13#10 +
           'https://cran.r-project.org/bin/windows/base/' + #13#10 + #13#10 +
           'Then re-run this installer.', mbError, MB_OK);
    Exit;
  end;

  // Step 2: Run R installer silently
  if not Exec(InstallerPath, '/VERYSILENT /NORESTART', '', SW_HIDE, ewWaitUntilTerminated, ExecResult) then
  begin
    MsgBox('Failed to launch the R installer.' + #13#10 +
           'Please install R manually from https://cran.r-project.org', mbError, MB_OK);
    Exit;
  end;
  if ExecResult <> 0 then
    MsgBox('R installer finished with exit code ' + IntToStr(ExecResult) + '.' + #13#10 +
           'Verify that R is installed before launching the app.', mbInformation, MB_OK);

  // Step 3: Verify Rscript.exe exists on disk
  Log('--- Post-install verification ---');
  Result := not RNeeded;
  Log('DownloadAndInstallR final result: ' + IntToStr(Ord(Result)));
  SaveLog;
  if not Result then
  begin
    if GetInstalledRVersion <> '' then
      MsgBox('R ' + GetInstalledRVersion + ' was found but R 4.4+ is required.' + #13#10 +
             'Please install the latest R manually from https://cran.r-project.org', mbError, MB_OK)
    else
      MsgBox('R installation could not be verified.' + #13#10 +
             'Please install R manually from https://cran.r-project.org', mbError, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RStatusMsg: string;
begin
  if (CurStep = ssInstall) then
  begin
    Log('=== CurStepChanged: ssInstall ===');
    Log('Calling RNeeded...');
    if RNeeded then
    begin
      Log('RNeeded = True, showing dialog');
      SaveLog;
      if GetInstalledRVersion <> '' then
        RStatusMsg := 'Version found on this computer: ' + GetInstalledRVersion + ' (too old).'
      else
        RStatusMsg := 'R was not detected on this computer.';
      if MsgBox('R 4.4+ is required.' + #13#10 +
                'This app needs R 4.4+ for ellmer, shinychat, and ggplot2 4.x.' + #13#10 +
                RStatusMsg + #13#10#13#10 +
                'Click Yes to download and install the latest R from CRAN automatically (requires internet access).' + #13#10 +
                'Click No to cancel and install R manually from https://cran.r-project.org',
                mbConfirmation, MB_YESNO) = IDYES then
    begin
      if not DownloadAndInstallR then
        Abort;
    end
    else
    begin
      MsgBox('Installation cancelled. Please install R 4.4+ from https://cran.r-project.org and re-run this installer.', mbError, MB_OK);
      Abort;
    end;
    end
    else
    begin
      Log('RNeeded = False, R is OK');
      SaveLog;
    end;
  end;
end;

procedure InitializeWizard;
begin
end;
