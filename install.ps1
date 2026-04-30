<#
.SYNOPSIS
    One-shot installer that gets Tabular Editor 2 working on corp-managed Windows
    machines where Microsoft Defender for Endpoint blocks Costura's in-memory
    Assembly.Load(byte[]) calls (causing TE2 to crash on launch with
    StackOverflowException / KERNELBASE.dll fault 0xe0434352).

.DESCRIPTION
    1. Downloads TE2 v2.28.0 portable from the official Tabular Editor GitHub release.
    2. Extracts the ZIP to %LOCALAPPDATA%\TabularEditor2.
    3. Decompresses Costura's embedded "costura.<name>.dll.compressed" resources
       and writes them as plain DLLs next to TabularEditor.exe. This makes .NET
       probing find them on disk via Assembly.LoadFrom(path), which AMSI does
       NOT intercept - bypassing the AMSI/Costura recursion crash without
       disabling any security control.
    4. Clears any stale TE2 user-cache from previous installs.
    5. Creates a "Tabular Editor 2.lnk" shortcut on the user's Desktop (handles
       OneDrive Known Folder Move).
    6. Optionally launches TE2 to verify it opens.

.NOTES
    Safe to re-run. No admin rights required. Only writes under the current user
    profile. Does NOT touch Defender, AMSI, or Tamper Protection settings.

    Project: https://github.com/adarsh-microsoft/tabular-editor-2-fix
#>

[CmdletBinding()]
param(
    [string]$Version = '2.28.0',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TabularEditor2'),
    [switch]$NoLaunch,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host "Tabular Editor 2 - Defender/Costura Fix Installer" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor DarkGray
Write-Host ""

# -- Pre-flight --------------------------------------------------------------
Write-Step "Pre-flight checks"

$net = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -EA 0
if (-not $net -or $net.Release -lt 528040) {
    throw ".NET Framework 4.8 or later is required. Install it from https://dotnet.microsoft.com/download/dotnet-framework and re-run."
}
Write-Ok ".NET Framework Release = $($net.Release) (>= 4.8)"

# Stop any running TE2 instance so we can overwrite files.
$running = Get-Process -Name TabularEditor -EA 0
if ($running) {
    Write-Warn2 "Stopping $($running.Count) running TabularEditor process(es)"
    $running | Stop-Process -Force -EA 0
    Start-Sleep -Seconds 1
}

# -- Download ----------------------------------------------------------------
$zipUrl = "https://github.com/TabularEditor/TabularEditor/releases/download/$Version/TabularEditor.Portable.zip"
$tmpZip = Join-Path $env:TEMP "TabularEditor.Portable.$Version.zip"

Write-Step "Downloading TE2 v$Version portable"
Write-Host "    Source : $zipUrl"
Write-Host "    Target : $tmpZip"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
$sz = (Get-Item $tmpZip).Length
Write-Ok ("Downloaded {0:N0} bytes" -f $sz)

# -- Extract -----------------------------------------------------------------
Write-Step "Extracting to $InstallDir"
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Expand-Archive -Path $tmpZip -DestinationPath $InstallDir -Force
Remove-Item $tmpZip -Force -EA 0

$exe = Join-Path $InstallDir 'TabularEditor.exe'
if (-not (Test-Path $exe)) {
    throw "TabularEditor.exe not found after extraction. Archive layout may have changed."
}

# Mark all extracted files as trusted (clears MOTW so Defender doesn't re-scan).
Get-ChildItem $InstallDir -Recurse -File | ForEach-Object { Unblock-File -LiteralPath $_.FullName -EA 0 }
Write-Ok "Extracted and unblocked"

# -- Costura DLL extraction (THE KEY FIX) ------------------------------------
Write-Step "Extracting Costura embedded DLLs to disk (Defender/AMSI workaround)"

# We must use Windows PowerShell 5.1 (.NET Framework) for ReflectionOnlyLoadFrom -
# PowerShell 7 (.NET 5+) removed that API. Windows PowerShell is always present
# on Windows at this fixed path.
$winPS = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $winPS)) {
    throw "Windows PowerShell 5.1 not found at $winPS - required for Costura extraction."
}

$extractScript = @'
param([string]$Exe, [string]$OutDir)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
$asm = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($Exe)
$resources = $asm.GetManifestResourceNames() | Where-Object { $_ -like 'costura.*.compressed' }
if (-not $resources) { Write-Output 'NONE'; exit 0 }
$count = 0
foreach ($res in $resources) {
    $outName = $res -replace '^costura\.', '' -replace '\.compressed$', ''
    $outPath = Join-Path $OutDir $outName
    $stream  = $asm.GetManifestResourceStream($res)
    if (-not $stream) { continue }
    $deflate = New-Object System.IO.Compression.DeflateStream($stream, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.File]::Create($outPath)
    try { $deflate.CopyTo($out) } finally { $out.Dispose(); $deflate.Dispose(); $stream.Dispose() }
    $sz = (Get-Item $outPath).Length
    Write-Output ("FILE|{0}|{1}" -f $outName, $sz)
    $count++
}
Write-Output ("DONE|{0}" -f $count)
'@

$tmpScript = Join-Path $env:TEMP "te2-extract-$([Guid]::NewGuid().ToString('N')).ps1"
Set-Content -LiteralPath $tmpScript -Value $extractScript -Encoding UTF8
try {
    $output = & $winPS -NoProfile -ExecutionPolicy Bypass -File $tmpScript -Exe $exe -OutDir $InstallDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Costura extraction failed (exit $LASTEXITCODE):`n$($output -join "`n")"
    }
    $count = 0
    foreach ($line in $output) {
        $s = "$line"
        if ($s -eq 'NONE') {
            Write-Warn2 "No Costura resources found - this build may not need extraction. Skipping."
        } elseif ($s -like 'FILE|*') {
            $parts = $s.Split('|')
            Write-Host ("    + {0,-50} {1,12:N0} bytes" -f $parts[1], [int64]$parts[2])
        } elseif ($s -like 'DONE|*') {
            $count = [int]$s.Split('|')[1]
        }
    }
    if ($count -gt 0) { Write-Ok "Extracted $count embedded DLL(s)" }
} finally {
    Remove-Item $tmpScript -Force -EA 0
}

# -- Clear stale per-user cache ---------------------------------------------
Write-Step "Clearing stale per-user cache (%LOCALAPPDATA%\TabularEditor)"
$userCache = Join-Path $env:LOCALAPPDATA 'TabularEditor'
if (Test-Path $userCache) {
    $bak = "$userCache.bak-$(Get-Date -Format yyyyMMddHHmmss)"
    Move-Item -LiteralPath $userCache -Destination $bak -Force
    Write-Ok "Moved old cache to $bak"
} else {
    Write-Ok "No stale cache present"
}

# -- Desktop shortcut --------------------------------------------------------
if (-not $NoShortcut) {
    Write-Step "Creating Desktop shortcut"

    # Resolve user's real Desktop (handles OneDrive Known Folder Move).
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path $desktop)) {
        $desktop = Join-Path $env:USERPROFILE 'Desktop'
    }

    $lnk = Join-Path $desktop 'Tabular Editor 2.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $shortcut = $sh.CreateShortcut($lnk)
    $shortcut.TargetPath       = $exe
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation     = "$exe,0"
    $shortcut.Description      = "Tabular Editor 2 (v$Version, Defender-safe build)"
    $shortcut.Save()
    Write-Ok "Shortcut: $lnk"
}

# -- Launch ------------------------------------------------------------------
if (-not $NoLaunch) {
    Write-Step "Launching Tabular Editor 2"
    $p = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 6
    $alive = Get-Process -Id $p.Id -EA 0
    if ($alive) {
        Write-Ok "RUNNING. PID=$($p.Id), Title='$($alive.MainWindowTitle)', Mem=$([int]($alive.WorkingSet64/1MB))MB"
    } else {
        Write-Warn2 "Process exited - check Event Viewer (Application log) for .NET Runtime errors."
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Installed to: $InstallDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "If TE2 hangs when loading a Power BI XMLA model:" -ForegroundColor DarkGray
Write-Host "  - Use 'Azure Active Directory' auth in the connect dialog (NOT Username/Password)" -ForegroundColor DarkGray
Write-Host "  - Make sure the workspace URL has NO trailing space" -ForegroundColor DarkGray
Write-Host "  - The workspace must be on Premium / PPU / Fabric capacity with XMLA enabled" -ForegroundColor DarkGray
Write-Host ""
