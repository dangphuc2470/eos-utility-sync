# Canon EOS Utility Config Sync

A set of PowerShell scripts to synchronize Canon EOS Utility sequence numbers (File Name Numbers) and settings across multiple computers and app versions using Google Drive.

## Features
- **Cross-Device & Cross-Version Sync**: Keep settings consistent everywhere.
- **Master Config Strategy**: Merges all version configs into one source of truth on Drive.
- **Two Operating Modes**:
    - **Run Once (Default)**: Syncs only when you log in to Windows. Minimal resource usage.
    - **Continuous (Daemon)**: Stays active in the background and syncs every X seconds. Ideal if you switch between computers frequently without logging off.

## Installation

1. Create a folder: `%LOCALAPPDATA%\Canon_INC\`
2. Place `Sync-CanonConfig.ps1` and `Setup-CanonSync.ps1` inside it.
3. Right-click `Setup-CanonSync.ps1` and select **Run with PowerShell**.
4. During setup, choose your preferred mode:
    - Press `1` for Run-Once mode.
    - Press `2` for Continuous (Daemon) mode.

## Customization
If you want to change the sync interval in Daemon mode, edit the shortcut created in your `Startup` folder or modify the `-Interval` value in the script. Default is 60 seconds.

## Requirements
- Windows 10/11
- Google Drive for Desktop installed (Default path: `G:\My Drive`)
