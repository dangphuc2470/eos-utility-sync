<#
.SYNOPSIS
    Installer for Canon Config Sync with Improved UI.
#>

$scriptName = "Sync-CanonConfig.ps1"
$localAppPath = "$env:LOCALAPPDATA\Canon_INC"
$scriptPath = Join-Path $localAppPath $scriptName

if (-not (Test-Path $scriptPath)) {
    Write-Error "Main sync script not found at $scriptPath"
    exit
}

Clear-Host
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "      CANON CONFIG SYNC INSTALLER             " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# STEP 1: DRIVE PATH
Write-Host "STEP 1: GOOGLE DRIVE PATH" -ForegroundColor Yellow
Write-Host "-----------------------------------------------"
Write-Host "Please specify where to store your master config."
Write-Host "Example: D:\Dropbox\CanonSync or G:\My Drive\Sync\Canon_INC" -ForegroundColor Gray
Write-Host ""
$selectedDrive = Read-Host "Path [Default: G:\My Drive\Sync\Canon_INC] (Press ENTER for default)"
if ([string]::IsNullOrWhiteSpace($selectedDrive)) { $selectedDrive = "G:\My Drive\Sync\Canon_INC" }

Write-Host ""
Write-Host ">> Target Path set to: $selectedDrive" -ForegroundColor Green
Write-Host ""

# STEP 2: SYNC MODE
Write-Host "STEP 2: SYNC MODE" -ForegroundColor Yellow
Write-Host "-----------------------------------------------"
Write-Host "1. [Run Once] - Syncs only at Windows login (Recommended)"
Write-Host "2. [Continuous] - Stays in background and syncs periodically"
Write-Host ""
$choice = Read-Host "Select Mode [1 or 2] (Press ENTER for 1)"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

$baseArgs = "-ExecutionPolicy Bypass -File `"$scriptPath`" -DrivePath `"$selectedDrive`""
$startupArgs = "-WindowStyle Hidden $baseArgs -AutoStartup"

if ($choice -eq "2") {
    Write-Host ""
    $inputSecs = Read-Host "Sync Interval in seconds [Default: 60] (Press ENTER for default)"
    if ([string]::IsNullOrWhiteSpace($inputSecs)) { $inputSecs = "60" }
    $startupArgs += " -Daemon -Interval $inputSecs"
    Write-Host ">> Mode set to: Continuous (Every $inputSecs seconds)" -ForegroundColor Green
} else {
    Write-Host ">> Mode set to: Run Once at Startup" -ForegroundColor Green
}

# INSTALLATION PROCESS
Write-Host ""
Write-Host "Finalizing installation..." -ForegroundColor Cyan
$WshShell = New-Object -ComObject WScript.Shell
$startupFolder = [Environment]::GetFolderPath('Startup')
$desktopFolder = [Environment]::GetFolderPath('Desktop')

# Cleanup links
$oldShortcuts = @("CanonSync_Startup.lnk", "Sync Canon Now.lnk")
foreach ($old in $oldShortcuts) {
    if (Test-Path (Join-Path $startupFolder $old)) { Remove-Item (Join-Path $startupFolder $old) -Force }
    if (Test-Path (Join-Path $desktopFolder $old)) { Remove-Item (Join-Path $desktopFolder $old) -Force }
}

# Create Shortcuts
$startupLnk = $WshShell.CreateShortcut((Join-Path $startupFolder "CanonSync_Startup.lnk"))
$startupLnk.TargetPath = "powershell.exe"
$startupLnk.Arguments = $startupArgs
$startupLnk.IconLocation = "shell32.dll,43"
$startupLnk.Save()

$desktopLnk = $WshShell.CreateShortcut((Join-Path $desktopFolder "Sync Canon Now.lnk"))
$desktopLnk.TargetPath = "powershell.exe"
$desktopLnk.Arguments = $baseArgs
$desktopLnk.IconLocation = "shell32.dll,43"
$desktopLnk.Save()

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  INSTALLATION COMPLETED SUCCESSFULLY!        " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Shortcuts added to Desktop and Startup folder."
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
