<#
.SYNOPSIS
    Canon EOS Utility Configuration Sync - With Final Summary
#>
param (
    [switch]$AutoStartup,
    [switch]$Daemon,
    [int]$Interval = 60,
    [string]$DrivePath = "G:\My Drive\Sync\Canon_INC"
)

$isQuiet = $AutoStartup -or ($Daemon -and -not $PSBoundParameters.ContainsKey('Debug'))

if (-not $isQuiet) {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "       CANON CONFIG SYNC INTERFACE            " -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
}

$localBase = "$env:LOCALAPPDATA\Canon_INC"
$driveBase = $DrivePath
$driveRoot = Split-Path $driveBase -Parent
$updatedCount = 0

if ($AutoStartup) {
    $retry = 0; while (-not (Test-Path $driveRoot) -and ($retry -lt 24)) { Start-Sleep -Seconds 5; $retry++ }
}

do {
    $localUpdated = 0
    if (Test-Path $driveRoot) {
        if (-not (Test-Path $driveBase)) { New-Item -ItemType Directory -Path $driveBase -Force | Out-Null }

        $apps = Get-ChildItem -Path $localBase -Directory
        foreach ($app in $apps) {
            if ((Get-Item $app.FullName).Attributes -match "ReparsePoint") { continue }
            $cleanName = ($app.Name -split '\.|_Url|_Strong')[0]
            $driveAppPath = Join-Path $driveBase $app.Name
            if (-not (Test-Path $driveAppPath)) { New-Item -ItemType Directory -Path $driveAppPath -Force | Out-Null }
            
            $versions = Get-ChildItem -Path $app.FullName -Directory
            foreach ($versionDir in $versions) {
                if ($versionDir.Attributes -match "ReparsePoint") { continue }
                if (-not $isQuiet) { Write-Host "  [>] $cleanName ($($versionDir.Name))... " -NoNewline -ForegroundColor White }

                $flags = "/E /COPY:DAT /DCOPY:T /XO /FFT /R:1 /W:1 /NP /NJH /NJS /NDL /NFL /XF `".ps1`""
                $out = Invoke-Expression "robocopy `"$($versionDir.FullName)`" `"$driveAppPath`" $flags"
                $out += Invoke-Expression "robocopy `"$driveAppPath`" `"$($versionDir.FullName)`" $flags"
                
                if (-not $isQuiet) {
                    if ($out -match "New File" -or $out -match "Newer") {
                        Write-Host "UPDATED" -ForegroundColor Yellow
                        $localUpdated++
                    } else {
                        Write-Host "OK" -ForegroundColor Green
                    }
                }
            }
        }
    }
    $updatedCount = $localUpdated
    if ($Daemon) { Start-Sleep -Seconds $Interval }
} while ($Daemon)

if (-not $isQuiet) {
    Write-Host ""
    Write-Host "----------------------------------------------" -ForegroundColor Cyan
    if ($updatedCount -gt 0) {
        Write-Host "  SUMMARY: $updatedCount item(s) were updated." -ForegroundColor Yellow
    } else {
        Write-Host "  SUMMARY: All items are already up-to-date." -ForegroundColor Green
    }
    Write-Host "----------------------------------------------" -ForegroundColor Cyan
    Write-Host "Closing in 5 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
}
