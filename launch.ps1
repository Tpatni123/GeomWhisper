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
#  Find Rscript — mirrors GitHub version strategy:
#  PATH -> 64-bit registry (all version subkeys)
#  -> file system scan -> pick highest version
# -----------------------------------------------
$Rscript = $null

$rInPath = Get-Command "Rscript" -ErrorAction SilentlyContinue
if ($rInPath) {
    $Rscript = $rInPath.Source
    Log "Found Rscript in PATH: $Rscript"
}

if (-not $Rscript) {
    Log "Scanning for R installations (64-bit registry + file system)..."

    $rCandidates = @()

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

    # Pick highest version by parsing R-X.Y.Z from path
    $best = $rCandidates | Sort-Object {
        if ($_ -match 'R-(\d+\.\d+\.\d+)') { [Version]$Matches[1] } else { [Version]"0.0.0" }
    } -Descending | Select-Object -First 1

    if ($best) {
        # Enforce R >= 4.4 (required for ellmer, shinychat, ggplot2 4.x packages)
        if ($best -match 'R-(\d+)\.(\d+)') {
            if ([int]$Matches[1] -lt 4 -or ([int]$Matches[1] -eq 4 -and [int]$Matches[2] -lt 4)) {
                Log "ERROR: R < 4.4 found: $best"
                Show-Error "R 4.4 or higher is required.`nFound: $best`n`nThis app uses packages (ellmer, shinychat, ggplot2 4.x) that require R 4.4+.`nPlease upgrade R from https://cran.r-project.org"
                exit 1
            }
        }
        $Rscript = $best
        Log "Selected Rscript: $Rscript"
    }
}

if (-not $Rscript) {
    Log "ERROR: R not found"
    Show-Error "R not found.`n`nInstall R from https://cran.r-project.org"
    exit 1
}

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

Set-Content -Path $rStartFile -Encoding ascii -Value @"
pkgs <- c('shiny','ggplot2','shinyjs','jsonlite','bslib','ellmer','coro','promises','readxl','magick','shinychat')
miss <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
if (length(miss)) {
  cat('Installing missing packages:', paste(miss, collapse=', '), '\\n')
  usr_lib <- Sys.getenv('R_LIBS_USER')
  if (nchar(usr_lib) == 0) usr_lib <- file.path(Sys.getenv('APPDATA'), 'R', 'library')
  if (!dir.exists(usr_lib)) dir.create(usr_lib, recursive = TRUE, showWarnings = FALSE)
  .libPaths(c(usr_lib, .libPaths()))
  
  # Try multiple CRAN mirrors for reliability
  repos <- c(
    'https://cloud.r-project.org',
    'https://cran.rstudio.com',
    'https://posit.r-universe.dev'
  )
  
  # Try binary first, then source if binaries unavailable
  cat('Attempting to install packages...\\n')
  install.packages(miss, repos = repos, lib = usr_lib, type = 'both', quiet = FALSE)
  
  # Verify installation succeeded
  still_miss <- miss[!sapply(miss, requireNamespace, quietly = TRUE)]
  if (length(still_miss) > 0) {
    cat('\\nWARNING: Some packages could not be installed from binaries.\\n')
    cat('Attempting source installation...\\n')
    install.packages(still_miss, repos = repos, lib = usr_lib, type = 'source', quiet = FALSE)
    
    # Final check
    final_miss <- still_miss[!sapply(still_miss, requireNamespace, quietly = TRUE)]
    if (length(final_miss) > 0) {
      cat('\\nERROR: Failed to install packages:', paste(final_miss, collapse=', '), '\\n')
      cat('This may be because:\\n')
      cat('  1. No binary packages available for your R version\\n')
      cat('  2. Rtools not installed (needed for source compilation)\\n')
      cat('  3. Network/firewall issues\\n')
      cat('\\nSuggestions:\\n')
      cat('  - Use the latest R from https://cran.r-project.org/ (R 4.4+ required)\\n')
      cat('  - Install Rtools: https://cran.r-project.org/bin/windows/Rtools/\\n')
      cat('  - Check your internet connection\\n')
      quit(status = 1)
    }
  }
  cat('All packages installed successfully\\n')
}
shiny::runApp('.', host = '127.0.0.1', port = $Port, launch.browser = FALSE)
"@

# Clear old log so stale content never shows in error dialogs
Set-Content -Path $shinyLog -Value ""

# -----------------------------------------------
#  Pre-check: count missing packages so we can
#  set an appropriate startup timeout before
#  the long Shiny process is launched.
#  (First-run install of 11 packages can take
#   2-5 min on a slow connection — 60s is too short)
# -----------------------------------------------
$missCount = 0
try {
    $checkExpr = 'pkgs<-c(''shiny'',''ggplot2'',''shinyjs'',''jsonlite'',''bslib'',''ellmer'',''coro'',''promises'',''readxl'',''magick'',''shinychat'');cat(sum(!sapply(pkgs,requireNamespace,quietly=TRUE)))'
    $result    = & $Rscript --vanilla -e $checkExpr 2>$null
    $missCount = [int]($result -replace '[^0-9]', '')
} catch { $missCount = 0 }

if ($missCount -gt 0) {
    Log "First-run: $missCount package(s) missing — extended startup timeout (300s)"
    Write-Host ""
    Write-Host "[setup] First-run detected: installing $missCount R package(s)."
    Write-Host "[setup] This may take 2-5 minutes on a slow connection."
    Write-Host "[setup] Please wait and do NOT close this window."
    Write-Host ""
    $PollMax = 300
} else {
    Log "All packages present — standard startup timeout (60s)"
    $PollMax = 60
}

# Launch via cmd /c — like RInno's run.js approach, no PS redirect conflicts
# WindowStyle Hidden + RedirectStandardOutput cannot be combined in Start-Process
$cmdInner  = "`"$Rscript`" --vanilla `"$rStartFile`" >`"$shinyLog`" 2>&1"
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
