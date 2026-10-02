# ============================================
#  ggplot Voice Copilot - Multi-LLM Edition - Launcher
# ============================================

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppDir

$LogDir  = "$env:APPDATA\ggplot-voice-copilot-multi-llm"
$LogFile = "$LogDir\launch.log"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss.ff')] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Show-Error([string]$msg) {
    Log "ERROR (dialog): $msg"
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "ggplot Voice Copilot - Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

Set-Content -Path $LogFile -Value "[$(Get-Date)] Starting ggplot Voice Copilot (Multi-LLM)"
Log "Working dir: $AppDir"

# -----------------------------------------------
#  Find Rscript: PATH, 64-bit registry (all version
#  subkeys), and a file system scan; then pick the
#  highest R 4.5.x. If none, offer to install 4.5.3.
# -----------------------------------------------
$R453Url = "https://cran.r-project.org/bin/windows/base/old/4.5.3/R-4.5.3-win.exe"

function Get-RVersion([string]$path) {
    if ($path -match 'R-(\d+\.\d+\.\d+)') { return [Version]$Matches[1] }
    $first = & $path --version 2>&1 | Select-Object -First 1
    if ("$first" -match 'version (\d+\.\d+\.\d+)') { return [Version]$Matches[1] }
    return $null
}

function Find-RInstalls {
    $rCandidates = @()

    $rInPath = Get-Command "Rscript" -ErrorAction SilentlyContinue
    if ($rInPath) {
        $rCandidates += $rInPath.Source
        Log "Found Rscript in PATH: $($rInPath.Source)"
    }

    Log "Scanning for R installations (64-bit registry + file system)..."

    # 1. 64-bit registry (avoids WOW64 redirection)
    $regSubPaths = @("SOFTWARE\R-core\R", "SOFTWARE\R-core\R64")
    foreach ($sub in $regSubPaths) {
        try {
            $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::Registry64)
            $key = $hklm.OpenSubKey($sub)
            if ($key) {
                # InstallPath directly on the key
                $ip = $key.GetValue("InstallPath")
                if ($ip) {
                    $c = Join-Path $ip "bin\Rscript.exe"
                    if (Test-Path $c) { $rCandidates += $c }
                }
                # Version subkeys (e.g. 4.5.1)
                foreach ($ver in $key.GetSubKeyNames()) {
                    try {
                        $vKey = $key.OpenSubKey($ver)
                        $ip2  = $vKey.GetValue("InstallPath")
                        if ($ip2) {
                            $c2 = Join-Path $ip2 "bin\Rscript.exe"
                            if (Test-Path $c2) { $rCandidates += $c2 }
                        }
                    } catch {}
                }
            }
        } catch { Log "Registry read error: $_" }
    }

    # 2. File system scan as additional fallback
    $searchRoots = @(
        "$env:ProgramFiles\R",
        "${env:ProgramFiles(x86)}\R",
        "$env:LOCALAPPDATA\Programs\R"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Filter "Rscript.exe" -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $rCandidates += $_.FullName }
        }
    }

    $rCandidates = $rCandidates | Select-Object -Unique
    Log "R candidates found: $($rCandidates -join '; ')"

    @(foreach ($c in $rCandidates) {
        $v = Get-RVersion $c
        if ($v) { [pscustomobject]@{ Path = $c; Version = $v } }
    })
}

# The pinned package snapshot is tested with R 4.5.x, and packages are built per R minor version.
function Select-R45($rFound) {
    $rFound | Where-Object { $_.Version.Major -eq 4 -and $_.Version.Minor -eq 5 } |
        Sort-Object Version -Descending | Select-Object -First 1
}

function Ask-YesNo([string]$msg) {
    Log "QUESTION (dialog): $msg"
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "ggplot Voice Copilot - R 4.5 required",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    Log "Answer: $answer"
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Install-R453 {
    $out = Join-Path $env:TEMP "R-4.5.3-win.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # The progress bar makes Invoke-WebRequest many times slower in Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'
    Write-Host "Downloading R 4.5.3 from CRAN (about 90 MB). Please wait..."
    Log "Downloading $R453Url"
    $ok = $false
    try { Invoke-WebRequest -Uri $R453Url -OutFile $out -UseBasicParsing -ErrorAction Stop; $ok = $true }
    catch { Log "Invoke-WebRequest failed: $_" }
    if (-not $ok) {
        try { (New-Object System.Net.WebClient).DownloadFile($R453Url, $out); $ok = $true }
        catch { Log "WebClient download failed: $_" }
    }
    if (-not $ok) {
        try { Start-BitsTransfer -Source $R453Url -Destination $out -ErrorAction Stop; $ok = $true }
        catch { Log "BITS download failed: $_" }
    }
    if (-not $ok) { return $false }

    Write-Host "Installing R 4.5.3. Windows may ask for permission..."
    Log "Running R installer: $out /VERYSILENT /NORESTART"
    try {
        $proc = Start-Process -FilePath $out -ArgumentList "/VERYSILENT", "/NORESTART" -Wait -PassThru -ErrorAction Stop
        Log "R installer exit code: $($proc.ExitCode)"
    } catch {
        Log "R installer could not run: $_"
        return $false
    } finally {
        Remove-Item $out -ErrorAction SilentlyContinue
    }
    $true
}

$rFound = Find-RInstalls
$best = Select-R45 $rFound

if (-not $best) {
    $seen = (@($rFound) | Where-Object { $_ } | ForEach-Object { $_.Version.ToString() } | Select-Object -Unique) -join ', '
    if (-not $seen) { $seen = 'no R installation' }
    Log "R 4.5.x not found (found: $seen)"
    if (Ask-YesNo "GeomWhisper requires R 4.5 (any 4.5.x release).`n`nFound: $seen`n`nDownload and install R 4.5.3 from CRAN now? It is about 90 MB and needs internet access. Other R versions stay installed.") {
        if (Install-R453) {
            $rFound = Find-RInstalls
            $best = Select-R45 $rFound
        }
    }
}

if (-not $best) {
    Log "ERROR: R 4.5.x not available"
    Show-Error "GeomWhisper requires R 4.5 (any 4.5.x release; R 4.5.3 recommended), and it could not be found or installed.`n`nInstall R 4.5.3 from https://cran.r-project.org/bin/windows/base/old/4.5.3/ and relaunch GeomWhisper.`n`nDetails are in $LogFile"
    exit 1
}

$Rscript = $best.Path
Log "Selected Rscript: $Rscript (R $($best.Version))"

# -----------------------------------------------
#  Free port 7475 if a previous instance is stuck
# -----------------------------------------------
$Port = 7475
try {
    $stale = netstat -ano 2>$null | Select-String ":$Port\s" |
        ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -Unique |
        Where-Object { $_ -match '^\d+$' }
    foreach ($stalePid in $stale) {
        $proc = Get-Process -Id $stalePid -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -match "Rscript") {
            Log "Killing stale Rscript (PID $stalePid) on port $Port"
            Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
} catch { Log "Port cleanup error (non-fatal): $_" }

# -----------------------------------------------
#  Install or upgrade R packages in their own R
#  process, before Shiny loads any package DLLs
# -----------------------------------------------
$installLog = "$LogDir\install.log"
Set-Content -Path $installLog -Value ""
Log "Checking R packages (log: $installLog)..."
Write-Host ""
Write-Host "[setup] Checking R packages. A first launch or an update can take several minutes."
Write-Host "[setup] Please wait and do NOT close this window."
Write-Host ""
& $Rscript --vanilla "$AppDir\install_deps.R" 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $installLog
$installExit = $LASTEXITCODE
if ($installExit -ne 0) {
    Log "ERROR: package setup failed (exit code $installExit)"
    $lines = (Get-Content $installLog | Select-Object -Last 20) -join "`n"
    Show-Error "R packages could not be installed or upgraded.`n`n$lines`n`nFull log: $installLog"
    exit 1
}
Log "R packages are ready"

# -----------------------------------------------
#  Start Shiny (no auto-browser)
# -----------------------------------------------
Log "Starting Shiny app on port $Port (no auto-browser)..."
Write-Host ""
Write-Host "[start] Starting ggplot Voice Copilot (Multi-LLM edition)..."
Write-Host "[info]  Opening http://localhost:$Port in Chrome."
Write-Host ""

# Write R startup code to a temp file — avoids all command-line quoting issues
$rStartFile = "$LogDir\shiny_start.R"
$shinyLog   = "$LogDir\shiny.log"

Set-Content -Path $rStartFile -Encoding ascii -Value "source('install_deps.R'); invisible(use_geomwhisper_library()); shiny::runApp('.', host = '127.0.0.1', port = $Port, launch.browser = FALSE)"

# Clear old log so stale content never shows in error dialogs
Set-Content -Path $shinyLog -Value ""
$PollMax = 60

# Launch via cmd /c — like RInno's run.js approach, no PS redirect conflicts
# WindowStyle Hidden + RedirectStandardOutput cannot be combined in Start-Process
$cmdInner  = "`"$Rscript`" --vanilla `"$rStartFile`" >`"$shinyLog`" 2>&1"
$env:GGPLOT_VOICE_COPILOT_DESKTOP = "1"
$shinyProc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c `"$cmdInner`"" `
    -WorkingDirectory $AppDir `
    -WindowStyle Hidden `
    -PassThru
Log "Shiny started (PID $($shinyProc.Id))"

# -----------------------------------------------
#  Poll TCP port until Shiny is ready
#  Timeout: 300s on first run (packages install)
#           60s on subsequent runs
# -----------------------------------------------
Log "Waiting for Shiny to be ready on port $Port (timeout ${PollMax}s)..."
$ready = $false
for ($i = 0; $i -lt $PollMax; $i++) {
    Start-Sleep -Seconds 1

    # Print a heartbeat every 30s so the user knows the app is still working
    if (($i -gt 0) -and ($i % 30 -eq 0)) {
        Write-Host "[wait]  Still starting up... ($i s elapsed, max ${PollMax}s)"
    }

    if ($shinyProc.HasExited) {
        Log "ERROR: Shiny exited during startup (code $($shinyProc.ExitCode))"
        $errMsg = "Shiny failed to start (exit code $($shinyProc.ExitCode)).`nRscript: $Rscript`n`n"
        if (Test-Path $shinyLog) {
            $lines = (Get-Content $shinyLog | Select-Object -Last 20) -join "`n"
            $errMsg += "R output (last 20 lines):`n$lines`n`nFull log: $shinyLog"
        } else {
            $errMsg += "(No R output captured. Log dir: $LogDir)"
        }
        $errMsg += "`n`nTroubleshooting tips:`n"
        $errMsg += "  - If you see 'package not found': check your internet connection`n"
        $errMsg += "  - On corporate networks: a proxy may block CRAN. Set http_proxy`n"
        $errMsg += "    in a .Renviron file in your Documents folder, then re-launch.`n"
        $errMsg += "  - Install Rtools if you see 'cannot compile': https://cran.r-project.org/bin/windows/Rtools/"
        Show-Error $errMsg
        exit 1
    }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $Port)
        $tcp.Close()
        $ready = $true
        Log "Shiny is ready after $($i + 1)s"
        break
    } catch {}
}
if (-not $ready) {
    Log "WARNING: Shiny port not detected after ${PollMax}s — opening browser anyway (app may need a moment to load)"
    Write-Host "[warn]  App is taking longer than expected. The browser will open now — if you see a connection error, wait 30s and refresh."
}

# -----------------------------------------------
#  Open Chrome in --app mode (no address bar)
#  Falls back to default browser if Chrome not found
# -----------------------------------------------
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chrome = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($chrome) {
    Log "Opening Chrome (app mode): $chrome"
    $chromeProc = Start-Process -FilePath $chrome `
        -ArgumentList "--app=http://localhost:$Port --new-window" `
        -PassThru
    Log "Chrome started (PID $($chromeProc.Id))"
} else {
    Log "Chrome not found -- opening default browser"
    Start-Process "http://localhost:$Port"
    $chromeProc = $null
}

# -----------------------------------------------
#  Monitor: wait for Shiny to exit
#  (server.R calls stopApp()/q() on session end
#   when the user closes the browser window)
# -----------------------------------------------
Log "Monitoring -- waiting for Shiny to exit..."
Write-Host "[info]  Close the browser window to quit the app."
Write-Host ""

$shinyProc.WaitForExit()
Log "Shiny exited (code $($shinyProc.ExitCode)). Shutting down."
Log "Done"
