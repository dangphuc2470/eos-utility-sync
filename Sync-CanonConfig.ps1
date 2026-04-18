<#
.SYNOPSIS
    Canon EOS Utility Configuration Sync Engine.
#>
param (
    [switch]$AutoStartup,
    [switch]$Daemon,
    [int]$Interval = 60,
    [string]$DrivePath = "G:\My Drive\Sync\Canon_INC" # Default fallback
)

if (-not $AutoStartup -and -not $Daemon) {
    Write-Host "Syncing Canon Configurations via Drive..." -ForegroundColor Cyan
}

$localBase = "$env:LOCALAPPDATA\Canon_INC"
$driveBase = $DrivePath

# Check if the parent of driveBase exists (to verify Drive is mounted)
$driveRoot = Split-Path $driveBase -Parent
if ($AutoStartup) {
    $retry = 0
    while (-not (Test-Path $driveRoot) -and ($retry -lt 24)) {
        Start-Sleep -Seconds 5
        $retry++
    }
}

do {
    if (Test-Path $driveRoot) {
        if (-not (Test-Path $driveBase)) { New-Item -ItemType Directory -Path $driveBase -Force | Out-Null }

        $apps = Get-ChildItem -Path $localBase -Directory
        foreach ($app in $apps) {
            if ((Get-Item $app.FullName).Attributes -match "ReparsePoint") { continue }
            
            $driveAppPath = Join-Path $driveBase $app.Name
            if (-not (Test-Path $driveAppPath)) { New-Item -ItemType Directory -Path $driveAppPath -Force | Out-Null }
            
            $versions = Get-ChildItem -Path $app.FullName -Directory
            foreach ($versionDir in $versions) {
                if ($versionDir.Attributes -match "ReparsePoint") { continue }
                robocopy $versionDir.FullName $driveAppPath /E /COPY:DAT /DCOPY:T /XO /FFT /R:1 /W:1 /NP /NJH /NJS /XF "*.ps1" | Out-Null
                robocopy $driveAppPath $versionDir.FullName /E /COPY:DAT /DCOPY:T /XO /FFT /R:1 /W:1 /NP /NJH /NJS /XF "*.ps1" | Out-Null
            }
        }
    }

    if ($Daemon) {
        Start-Sleep -Seconds $Interval
    }
} while ($Daemon)

if (-not $AutoStartup -and -not $Daemon) {
    Write-Host "Sync Completed Successfully!" -ForegroundColor Green
    Start-Sleep -Seconds 2
}
