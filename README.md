# SpicetifyManagerPro

[![Release](https://img.shields.io/github/v/release/Dalbouh02/SpicetifyManager?style=flat&label=Release)](https://github.com/Dalbouh02/SpicetifyManager/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-1DB954.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE.svg)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![Windows 10/11](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6.svg)](https://www.microsoft.com/windows)
[![Downloads](https://img.shields.io/github/downloads/Dalbouh02/SpicetifyManager/total?style=flat&label=Downloads&color=1DB954)](https://github.com/Dalbouh02/SpicetifyManager/releases)
[![Stars](https://img.shields.io/github/stars/Dalbouh02/SpicetifyManager?style=flat&label=Stars&color=1DB954)](https://github.com/Dalbouh02/SpicetifyManager/stargazers)
[![Last Commit](https://img.shields.io/github/last-commit/Dalbouh02/SpicetifyManager?style=flat&label=Last%20Update)](https://github.com/Dalbouh02/SpicetifyManager/commits/main)

PowerShell tool for installing, repairing, and removing Spicetify and Spotify on Windows, with Spotify version management: downgrade, roll forward, pin a version, and block automatic updates. Single `.ps1` file, WPF GUI plus console mode. No installer, no admin rights.

<img src="assets/main-window.png" alt="Main window" width="960">

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (preinstalled) or PowerShell 7+
- Internet connection

## Quick start

1. Download [`SpicetifyManagerPro.ps1`](https://github.com/Dalbouh02/SpicetifyManagerPro/releases/latest/download/SpicetifyManagerPro.ps1) from the latest release.
2. Right-click the file → **Run with PowerShell** → **Open** on the execution policy prompt.
3. Click **Start**.

If your browser renames the download or PowerShell blocks it, unblock it once:

```powershell
Unblock-File .\SpicetifyManagerPro.ps1
```

## What it does

**Start** runs the full workflow: preflight checks, install or verify Spotify (desktop, per-user), snapshot your customizations, install or update Spicetify, install the Marketplace, restore your customizations, apply the configuration. It downloads both Spotify and Spicetify if you have neither.

**Repair Only** reinstalls Spotify, rebuilds the Spicetify backup, and re-applies your configuration. Your themes, extensions, and settings are snapshotted first and restored after.

**Uninstall** removes Spicetify, restores stock Spotify, and keeps a backup of your customizations.

**Version** opens the version manager. You can list available versions, switch to any of them (downgrade or roll forward), and pin a version so installs and repairs keep it instead of taking the latest. User data (login, cache, settings) is carried across a version switch.

**Updates** toggles the update block. Blocking disables the update check inside the Spotify binary — the same method `spicetify spotify-updates block` uses. Spotify will not update itself while blocked. Blocking closes Spotify, discards any already-staged update, and is fully reversible. No admin rights and no ACL tricks.

Note for users of v1.1.3 and earlier: the old update block created guard files that stop modern Spotify versions from launching. Run **Block** or **Unblock** once with this version — it removes the old files and switches to the binary method. Spotify will start normally again.

The tool refuses to touch the Microsoft Store version of Spotify (it cannot be modified). Uninstall it from Windows Settings first; the tool then installs the desktop version.

## Command line

| Switch | Effect |
|---|---|
| `-NoUI` | Console mode, no GUI. For CI or scheduled tasks. |
| `-Repair` | Repair as described above, then exit. |
| `-Uninstall` | Uninstall as described above, then exit. |
| `-Diagnose` | Print environment info and exit. No side effects. |
| `-ListVersions` | List the Spotify version catalog and exit. |
| `-DowngradeTo <ver>` | Switch to a version, e.g. `1.2.13.661`. `none` clears the pin, `latest` clears the pin and repairs to the newest version. |
| `-AcceptVersionRisks` | Skip the confirmation for versions with known problems. |
| `-BlockUpdates` | Block Spotify self-updates, then exit. |
| `-UnblockUpdates` | Unblock Spotify self-updates, then exit. |
| `-KeepLog` | Keep the run log on success (deleted by default). |
| `-SkipPreflight` | Skip the pre-flight environment checks. |
| `-LogPath <path>` | Override the default log location. |
| `-CacheDir <path>` | Spicetify download cache directory. `none` disables caching. |
| `-MaxRetries <n>` | Network retry attempts. Default `3`. |
| `-RetryDelayMs <n>` | Milliseconds between retries. Default `2000`. |
| `-ProcessTimeoutMs <n>` | Per-process timeout in ms. Default `90000`. |
| `-BackupRetention <n>` | Backup snapshots to keep. Default `3`. |

### Examples

```powershell
# Full install / update (GUI)
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1

# Headless (CI, scheduled task)
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1 -NoUI

# Repair
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1 -Repair

# Downgrade to a specific version and pin it
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1 -DowngradeTo 1.2.13.661

# Block / unblock Spotify self-updates
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1 -BlockUpdates
powershell -ExecutionPolicy Bypass -File .\SpicetifyManagerPro.ps1 -UnblockUpdates
```

## Files

| Path | Purpose |
|---|---|
| `%APPDATA%\SpicetifyManagerPro\config.json` | Settings |
| `%APPDATA%\SpicetifyManagerPro\stats.json` | Counters |
| `%APPDATA%\SpicetifyManagerPro\windowstate.json` | Window position and size |
| `%APPDATA%\SpicetifyManagerPro\BackupHistory\` | Backup snapshots |
| `%TEMP%\SpicetifyManagerPro_<yyyyMMdd>.log` | Run log (deleted on success unless `-KeepLog`) |
| `%TEMP%\SpicetifyManagerPro_CRASH_<timestamp>.log` | Crash report. Never deleted automatically. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Initialization failure |
| `2` | Preflight failure |
| `3` | Backup failure |
| `4` | Spotify install or detection failure |
| `5` | Spicetify install or update failure |
| `6` | Marketplace install failure |
| `7` | Apply (configuration) failure |
| `8` | Uninstall failure |
| `9` | Restore failure |
| `10` | Cancelled by user |
| `11` | Version switch failure |
| `12` | Update block toggle failure |
| `64` | PowerShell older than 5.1 |
| `65` | Not running on Windows |
| `66` | WPF assemblies failed to load |
| `67` | GUI needs an interactive STA session |
| `68` | Another instance is already running |

## FAQ

**Does it need administrator rights?**
No. Everything installs per-user under `%APPDATA%` and `%LOCALAPPDATA%`.

**What does it change on my system?**
Spotify (`%APPDATA%\Spotify`), Spicetify (`%APPDATA%\spicetify`, `%LOCALAPPDATA%\spicetify`), its own folder under `%APPDATA%\SpicetifyManagerPro`, and temp files under `%TEMP%`. When the update block is on, it also rewrites nine bytes inside the Spotify binary (the update-check endpoint) — this invalidates the file's digital signature, which is expected and does not stop Spotify from running.

**What does it connect to?**
`api.github.com` and `github.com` (Spicetify and Marketplace releases), `download.scdn.co` (Spotify installer), and `raw.githubusercontent.com` plus `loadspot.amd64fox1.workers.dev` (the community Spotify version catalog by LoaderSpot). Run `-Diagnose` to see the full environment report.

**Spotify updated and my theme broke. What now?**
Run **Repair Only**. To keep a version fixed in place, pin it (**Version**) and block updates (**Updates**).

**A version switch failed and the tool talks about a rescue directory.**
Version switches stage and restore your user data first. If anything fails mid-switch, the data is parked in `%APPDATA%\SpicetifyManagerPro\UserdataRescue_<timestamp>` and the log tells you where. Nothing is deleted while a rescue directory exists.

**Why is the version list missing old versions?**
Versions are filtered by what works: your CPU architecture, Windows 10+, login-broken builds (1.1.87.612 – 1.2.5.1006), and very old builds are excluded or flagged.

## Credits

- [Spicetify](https://github.com/spicetify/cli)
- [Spicetify Marketplace](https://github.com/spicetify/marketplace)
- [LoaderSpot](https://github.com/LoaderSpot/table) — Spotify version catalog

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
