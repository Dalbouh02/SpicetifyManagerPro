[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoUI,
    [switch]$Repair,
    [switch]$Uninstall,
    [switch]$KeepLog,
    [switch]$FromLauncher,
    [switch]$Diagnose,
    [int]$MaxRetries = 3,
    [int]$RetryDelayMs = 2000,
    [int]$ProcessTimeoutMs = 90000,
    [string]$LogPath,
    [string]$CacheDir,
    [int]$BackupRetention = 3,
    [switch]$SkipPreflight,

    [switch]$ListVersions,

    [switch]$BlockUpdates,

    [switch]$UnblockUpdates,

    [string]$DowngradeTo,

    [switch]$AcceptVersionRisks,

    [switch]$StaRelaunched
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([Environment]::GetEnvironmentVariable('OS') -ne 'Windows_NT') {
    [System.Console]::Error.WriteLine('SpicetifyManagerPro only runs on Microsoft Windows (PowerShell 5.1 or 7+).')
    exit 65
}

function Get-ClampedInt {
    param(
        $Value,
        [int]$Fallback,
        [int]$Min,
        [int]$Max
    )
    $parsed = 0
    if (-not [int]::TryParse("$Value", [ref]$parsed)) { $parsed = $Fallback }
    if ($parsed -lt $Min) { $parsed = $Min }
    if ($parsed -gt $Max) { $parsed = $Max }
    return $parsed
}

function Get-TempDir {

    if ($env:TEMP) { return $env:TEMP }
    return [System.IO.Path]::GetTempPath()
}

$Script:SettingsLimits = @{
    MaxRetriesMin       = 0
    MaxRetriesMax       = 10
    RetryDelayMin       = 100
    RetryDelayMax       = 30000
    ProcTimeoutMin      = 5000
    ProcTimeoutMax      = 600000
    RetentionMin        = 1
    RetentionMax        = 50
}

try {
    $tlsFlags = [Net.SecurityProtocolType]::Tls12
    $tls13Enum = [Net.SecurityProtocolType]::Tls13
    if ($null -ne $tls13Enum) {
        $tlsFlags = $tlsFlags -bor $tls13Enum
    }
} catch {

}
[Net.ServicePointManager]::SecurityProtocol = $tlsFlags

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host 'PowerShell 5.1+ is required. Detected: ' -NoNewline -ForegroundColor Red
    Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Yellow
    exit 64
}

$apartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

$downgradeConsoleOnly = $false
if ($DowngradeTo) {
    $downgradeConsoleOnly = (@('none', 'unpin', 'clear') -contains ("$DowngradeTo".Trim().ToLowerInvariant()))
}
$consoleOnlySwitch = ($ListVersions -or $BlockUpdates -or $UnblockUpdates -or $downgradeConsoleOnly)
if (-not $NoUI -and -not $Diagnose -and -not $consoleOnlySwitch -and $apartmentState -ne [System.Threading.ApartmentState]::STA) {
    $senderInfoVar = Get-Variable -Name PSSenderInfo -ErrorAction SilentlyContinue
    $remoteSession = ($null -ne $senderInfoVar -and $null -ne $senderInfoVar.Value)
    $guiHostileSession = ($remoteSession -or (-not [Environment]::UserInteractive) -or ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0))
    if ($guiHostileSession -or $StaRelaunched -or $PSVersionTable.PSVersion.Major -ge 7) {
        [System.Console]::Error.WriteLine(
            "SpicetifyManagerPro: the GUI needs an interactive STA thread (current: $apartmentState, remote session: $remoteSession).")
        [System.Console]::Error.WriteLine(
            'Start the script from an interactive PowerShell window (without -MTA), or rerun with -NoUI for console mode.')
        exit 67
    }
    $childArgs = New-Object System.Collections.Generic.List[string]
    $childArgs.AddRange([string[]]@('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)))
    foreach ($paramName in @($PSBoundParameters.Keys)) {
        $boundValue = $PSBoundParameters[$paramName]
        if ($boundValue -is [System.Management.Automation.SwitchParameter]) {
            if ($boundValue.IsPresent) { $childArgs.Add("-$paramName") }
        } else {

            $asText = "$boundValue"
            if ($asText -eq '') { continue }
            $childArgs.Add("-$paramName")
            $childArgs.Add(('"{0}"' -f ($asText -replace '"', '""')))
        }
    }

    $childArgs.Add('-StaRelaunched')
    $childArgs.Add('-FromLauncher')
    try {
        $staHost = Join-Path $PSHOME 'powershell.exe'
        $staChild = Start-Process -FilePath $staHost -ArgumentList $childArgs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        exit $staChild.ExitCode
    } catch {
        [System.Console]::Error.WriteLine("SpicetifyManagerPro: failed to relaunch on an STA thread: $($_.Exception.Message)")
        exit 67
    }
}

$Script:FailedAssemblies = New-Object System.Collections.Generic.List[string]
foreach ($asm in @('System.IO.Compression.FileSystem', 'System.Net.Http', 'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml')) {
    try {
        Add-Type -AssemblyName $asm -ErrorAction Stop
    } catch {
        $Script:FailedAssemblies.Add($asm)
    }
}

$Script:ScriptVersion   = '1.1.3'

$Script:SingleInstanceMutex = $null
$Script:LegacySingleInstanceMutex = $null
if (-not $Diagnose -and -not $ListVersions) {
    $newInstanceCreated = $false
    try {
        $Script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, 'Local\SpicetifyManagerPro.SingleInstance', [ref]$newInstanceCreated)
    } catch {
        $Script:SingleInstanceMutex = $null
        $newInstanceCreated = $true
        [System.Console]::Error.WriteLine("WARNING: single-instance lock could not be checked: $($_.Exception.Message)")
    }
    if (-not $newInstanceCreated) {
        $instanceMsg = 'Another SpicetifyManagerPro instance is already running. Close it first -- two instances at once can corrupt user data during version switches.'
        if (-not $NoUI -and $Script:FailedAssemblies.Count -eq 0) {
            $null = [System.Windows.MessageBox]::Show($instanceMsg, 'SpicetifyManagerPro',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        } else {
            [System.Console]::Error.WriteLine("SpicetifyManagerPro: $instanceMsg")
        }
        exit 68
    }
    $legacyInstanceTaken = $false
    $legacyCreated = $false
    try {
        $Script:LegacySingleInstanceMutex = [System.Threading.Mutex]::new($true, 'Local\SpicetifyManager.SingleInstance', [ref]$legacyCreated)
        $legacyInstanceTaken = (-not $legacyCreated)
    } catch {
        $Script:LegacySingleInstanceMutex = $null
        [System.Console]::Error.WriteLine("WARNING: legacy single-instance lock could not be checked: $($_.Exception.Message)")
    }
    if ($legacyInstanceTaken) {
        $legacyMsg = 'An instance of the previous SpicetifyManager is still running. Close it first -- two instances at once can corrupt user data during version switches.'
        if (-not $NoUI -and $Script:FailedAssemblies.Count -eq 0) {
            $null = [System.Windows.MessageBox]::Show($legacyMsg, 'SpicetifyManagerPro',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        } else {
            [System.Console]::Error.WriteLine("SpicetifyManagerPro: $legacyMsg")
        }
        exit 68
    }
}

$staleStageCutoff = (Get-Date).AddHours(-24)
foreach ($stalePattern in @('SpicetifyManagerPro_stage_*', 'SpicetifyManager_stage_*', 'spicetify_stage_*', 'marketplace_stage_*')) {
    Get-ChildItem -Path (Get-TempDir) -Filter $stalePattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTime -lt $staleStageCutoff) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
foreach ($crashLogPattern in @('SpicetifyManagerPro_CRASH_*.log', 'SpicetifyManager_CRASH_*.log')) {
    Get-ChildItem -Path (Get-TempDir) -Filter $crashLogPattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTime -lt (Get-Date).AddDays(-30)) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

$Script:AppStateDir     = Join-Path $env:APPDATA 'SpicetifyManagerPro'
$legacyAppStateDir      = Join-Path $env:APPDATA 'SpicetifyManager'
try {
    if (-not (Test-Path -LiteralPath $Script:AppStateDir) -and (Test-Path -LiteralPath $legacyAppStateDir)) {
        Copy-Item -LiteralPath $legacyAppStateDir -Destination $Script:AppStateDir -Recurse -Force -ErrorAction Stop
    }
} catch {
    [System.Console]::Error.WriteLine("WARNING: could not migrate settings from '$legacyAppStateDir' to '$($Script:AppStateDir)': $($_.Exception.Message)")
}
$Script:ConfigPath      = Join-Path $Script:AppStateDir 'config.json'
$Script:StatsPath       = Join-Path $Script:AppStateDir 'stats.json'
$Script:WindowStatePath = Join-Path $Script:AppStateDir 'windowstate.json'

$logPathInput = "" + $LogPath
$logPathInput = $logPathInput.Trim()
if ($logPathInput -ne '' -and $logPathInput -notmatch '^([a-zA-Z]:[\\/]|\\\\)') {
    [System.Console]::Error.WriteLine("WARNING: -LogPath must be an absolute path (got '$logPathInput'). Using the default log location instead.")
    $logPathInput = ''
}
$configLogFilePath = if ($logPathInput) { $logPathInput } else { Join-Path (Get-TempDir) "SpicetifyManagerPro_$(Get-Date -Format 'yyyyMMdd').log" }

$cacheInput        = ([string]$CacheDir).Trim()
$configCacheDir    = if ($cacheInput -ne '' -and $cacheInput -ine 'none') { $cacheInput } else { Join-Path $env:LOCALAPPDATA 'spicetify\cache' }

$configEnableCache = ($cacheInput -ine 'none')
$paramLimits       = $Script:SettingsLimits
$configMaxRetries  = Get-ClampedInt -Value $MaxRetries       -Fallback 3     -Min $paramLimits.MaxRetriesMin  -Max $paramLimits.MaxRetriesMax
$configRetryDelay  = Get-ClampedInt -Value $RetryDelayMs     -Fallback 2000  -Min $paramLimits.RetryDelayMin  -Max $paramLimits.RetryDelayMax
$configProcTimeout = Get-ClampedInt -Value $ProcessTimeoutMs -Fallback 90000 -Min $paramLimits.ProcTimeoutMin -Max $paramLimits.ProcTimeoutMax
$configRetention   = Get-ClampedInt -Value $BackupRetention  -Fallback 3     -Min $paramLimits.RetentionMin  -Max $paramLimits.RetentionMax

$Script:Config = [PSCustomObject]@{
    AppDataPath       = Join-Path $env:APPDATA 'spicetify'
    SpicetifyExePath  = Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe'
    MarketplaceDest   = Join-Path $env:APPDATA 'spicetify\CustomApps\marketplace'
    SpotifyExePath    = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
    SpotifyInstallDir = Join-Path $env:APPDATA 'Spotify'

    SpotifyStorePath  = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Spotify.exe'
    BackupDir         = Join-Path $env:APPDATA 'spicetify\Backup'

    BackupHistoryDir  = Join-Path $Script:AppStateDir 'BackupHistory'
    LogFilePath       = $configLogFilePath
    CacheDir          = $configCacheDir
    MaxRetries        = $configMaxRetries
    RetryDelayMs      = $configRetryDelay
    ProcessTimeoutMs  = $configProcTimeout
    FileLockRetries   = 20
    FileLockDelayMs   = 500
    BackupRetention   = $configRetention
    EnableCache       = $configEnableCache
    MinDiskSpaceMB    = 200

    PinnedSpotifyVersion = ''
}

$Script:StagingPath    = $null
$Script:StagingValid   = $false
$Script:TempFiles      = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$Script:CurrentPhase   = 'Init'
$Script:PhaseStartTime = $null
$Script:PhaseTimings   = [System.Collections.Generic.Dictionary[string, TimeSpan]]::new()
$Script:RunspaceState   = $null
$Script:CompletionTimer = $null

$Script:LogMutex           = [System.Threading.Mutex]::new($false)
$Script:LogWriteCount      = 0
$Script:LogFileWriteFailed = $false

$Script:LogPathCustomized = $PSBoundParameters.ContainsKey('LogPath')

$Script:ExitCodes = @{
    Init            = 1
    Preflight       = 2
    Backup          = 3
    SpotifyInstall  = 4
    SpicetifyInstall = 5
    Marketplace     = 6
    Apply           = 7
    Uninstall       = 8
    Restore         = 9
    Cancelled       = 10
    Downgrade       = 11
    VersionBlock    = 12
}

$Script:PhaseExitKeyMap = @{
    Init             = 'Init'
    Preflight        = 'Preflight'
    Backup           = 'Backup'
    Spotify          = 'SpotifyInstall'
    SpotifyInstall   = 'SpotifyInstall'
    Spicetify        = 'SpicetifyInstall'
    SpicetifyInstall = 'SpicetifyInstall'
    Marketplace      = 'Marketplace'
    Apply            = 'Apply'
    Uninstall        = 'Uninstall'
    Restore          = 'Restore'
    Repair           = 'SpotifyInstall'   
    Downgrade        = 'Downgrade'         
}

function Get-PhaseExitKey {
    param([string]$Phase)
    if ($Script:PhaseExitKeyMap.ContainsKey($Phase)) {
        return $Script:PhaseExitKeyMap[$Phase]
    }
    return $null
}

$Script:SpotifyCatalogManifestUrl = 'https://raw.githubusercontent.com/LoaderSpot/table/main/table/versions.json'
$Script:VersionCatalogCache       = $null

function Set-ContentAtomic {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper: -WhatIf is handled by its callers.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,

        [switch]$NoBom
    )

    $tmpPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        if ($NoBom) {
            [System.IO.File]::WriteAllText($tmpPath, $Value, [System.Text.UTF8Encoding]::new($false))
        } else {
            Set-Content -LiteralPath $tmpPath -Value $Value -Encoding UTF8 -ErrorAction Stop
        }
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmpPath) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Initialize-LogPath {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Direct console output is deliberate: the pipeline must stay clean of diagnostics.')]
    [CmdletBinding()]
    param()

    $logDir = Split-Path $Script:Config.LogFilePath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            Write-Log -Message "Created log directory: $logDir" -Level INFO
        } catch {

            $fallback = Join-Path (Get-TempDir) "SpicetifyManagerPro_$(Get-Date -Format 'yyyyMMdd').log"
            [System.Console]::WriteLine("WARNING: cannot create log directory '$logDir' ($($_.Exception.Message)). Falling back to: $fallback")
            $Script:Config.LogFilePath = $fallback
            $Script:LogPathCustomized = $false
        }
    }
}

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Direct console output is deliberate: Write-Output here would pollute the worker runspace result pipeline.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The ReleaseMutex and Enqueue catch blocks are intentionally quiet: both are last-resort guards where the entry has already reached the UI stream or the failure is cosmetic.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry     = "[$timestamp] [$Level] $Message"

    $lockHeld = $false
    try {
        if ($null -ne $Script:LogMutex) {
            try {
                $lockHeld = $Script:LogMutex.WaitOne(2000)
            } catch [System.Threading.AbandonedMutexException] {
                $lockHeld = $true
            } catch {
                $lockHeld = $false
            }
            if (-not $lockHeld -and -not $Script:LogFileWriteFailed) {
                $Script:LogFileWriteFailed = $true
                [System.Console]::WriteLine("WARNING: log file lock could not be acquired; entry dropped: $entry")
            }
        }
        if ($null -eq $Script:LogMutex -or $lockHeld) {
            $Script:LogWriteCount++
            if (($Script:LogWriteCount % 500) -eq 1) {
                try {
                    if ((Test-Path -LiteralPath $Script:Config.LogFilePath) -and
                        ((Get-Item -LiteralPath $Script:Config.LogFilePath -Force).Length -gt 10MB)) {
                        $rotatedLogPath = "$($Script:Config.LogFilePath).old"
                        Remove-Item -LiteralPath $rotatedLogPath -Force -ErrorAction SilentlyContinue
                        Move-Item -LiteralPath $Script:Config.LogFilePath -Destination $rotatedLogPath -Force -ErrorAction Stop
                    }
                } catch { }
            }
            $maxAttempts = 3
            for ($i = 1; $i -le $maxAttempts; $i++) {
                try {
                    Add-Content -LiteralPath $Script:Config.LogFilePath -Value $entry -Encoding UTF8 -ErrorAction Stop
                    break
                } catch {
                    if ($i -eq $maxAttempts) {
                        if (-not $Script:LogFileWriteFailed) {
                            $Script:LogFileWriteFailed = $true
                            [System.Console]::WriteLine("WARNING: log file write failed: $($_.Exception.Message)")
                        }
                    } else {
                        Start-Sleep -Milliseconds 100
                    }
                }
            }
        }
    } finally {
        if ($lockHeld) {
            try {
                $Script:LogMutex.ReleaseMutex()
            } catch {

            }
        }
    }

    if ($null -ne $Script:LogStream) {
        try {
            $Script:LogStream.Enqueue([PSCustomObject]@{
                Time  = $timestamp
                Level = $Level
                Msg   = $Message
            })
        } catch { }
    }
}

function Write-Step {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('OK', 'WARN', 'ERR', 'INFO', 'STEP')][string]$Type = 'INFO'
    )

    $logLevel = switch ($Type) {
        'OK'   { 'SUCCESS' }
        'ERR'  { 'ERROR' }
        'WARN' { 'WARN' }
        default { 'INFO' }
    }

    if (-not $Script:NoUI -and $Script:GUIActive) {
        Write-Log -Message $Message -Level $logLevel
    } else {
        $prefix = switch ($Type) {
            'OK'   { '[OK]    ' }
            'WARN' { '[!]     ' }
            'ERR'  { '[X]     ' }
            'STEP' { '[...]   ' }
            default{ '[i]     ' }
        }
        $color = switch ($Type) {
            'OK'   { 'Green' }
            'WARN' { 'Yellow' }
            'ERR'  { 'Red' }
            'STEP' { 'Cyan' }
            default{ 'White' }
        }
        Write-Host "$prefix$Message" -ForegroundColor $color
        Write-Log -Message $Message -Level $logLevel
    }
}

function Read-Config {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The quarantine rename is best-effort: when renaming itself fails, the original WARN path handles the corrupt file; there is nothing left to do inside the catch.')]
    [CmdletBinding()]
    param([System.Collections.Generic.HashSet[string]]$BoundParams)

    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) { return }

    $content = $null
    $readFailed = $false
    try {
        $content = Get-Content -LiteralPath $Script:ConfigPath -Raw -ErrorAction Stop
    } catch {
        $readFailed = $true
        Write-Log -Message "Could not read settings (keeping current values): $($_.Exception.Message)" -Level WARN
    }
    if ($readFailed) { return }

    try {
        $savedConfig = $content | ConvertFrom-Json
        $limits      = $Script:SettingsLimits

        $props = $savedConfig.PSObject.Properties

        $p = $props['MaxRetries']
        if ($null -ne $p -and -not $BoundParams.Contains('MaxRetries')) {
            $Script:Config.MaxRetries = Get-ClampedInt -Value $p.Value -Fallback $Script:Config.MaxRetries -Min $limits.MaxRetriesMin -Max $limits.MaxRetriesMax
        }
        $p = $props['RetryDelayMs']
        if ($null -ne $p -and -not $BoundParams.Contains('RetryDelayMs')) {
            $Script:Config.RetryDelayMs = Get-ClampedInt -Value $p.Value -Fallback $Script:Config.RetryDelayMs -Min $limits.RetryDelayMin -Max $limits.RetryDelayMax
        }
        $p = $props['ProcessTimeoutMs']
        if ($null -ne $p -and -not $BoundParams.Contains('ProcessTimeoutMs')) {
            $Script:Config.ProcessTimeoutMs = Get-ClampedInt -Value $p.Value -Fallback $Script:Config.ProcessTimeoutMs -Min $limits.ProcTimeoutMin -Max $limits.ProcTimeoutMax
        }
        $p = $props['BackupRetentionDays']
        if ($null -ne $p -and -not $BoundParams.Contains('BackupRetention')) {
            $Script:Config.BackupRetention = Get-ClampedInt -Value $p.Value -Fallback $Script:Config.BackupRetention -Min $limits.RetentionMin -Max $limits.RetentionMax
        }
        $p = $props['LogPath']
        if ($null -ne $p -and $p.Value -and -not $BoundParams.Contains('LogPath')) {
            $Script:Config.LogFilePath = [string]$p.Value
            $Script:LogPathCustomized = $true
        }
        $p = $props['CacheDir']
        if ($null -ne $p -and -not $BoundParams.Contains('CacheDir')) {
            $dirValue = ([string]$p.Value).Trim()
            if ($dirValue -ieq 'none') {
                $Script:Config.EnableCache = $false
            } elseif ($dirValue -ne '') {
                $Script:Config.CacheDir    = $dirValue
                $Script:Config.EnableCache = $true
            }
        }

        $p = $props['KeepLogFile']
        if ($null -ne $p -and -not $BoundParams.Contains('KeepLog')) {
            $Script:KeepLog = [bool]$p.Value
        }
        $p = $props['SkipPreflightCheck']
        if ($null -ne $p -and -not $BoundParams.Contains('SkipPreflight')) {
            $Script:SkipPreflight = [bool]$p.Value
        }
        $p = $props['PinnedSpotifyVersion']
        if ($null -ne $p -and $p.Value) {
            $pin = [string]$p.Value
            if ($pin -and $null -ne (ConvertTo-SpotifyVersion -Version $pin)) {

                $cfgPin = $Script:Config.PSObject.Properties['PinnedSpotifyVersion']
                if ($null -ne $cfgPin) { $cfgPin.Value = $pin }
            } else {
                Write-Log -Message "Ignoring invalid persisted version pin: '$pin'" -Level WARN
            }
        }

        Write-Log -Message "Loaded settings from $Script:ConfigPath" -Level INFO
    } catch {

        $quarantine = Join-Path (Split-Path $Script:ConfigPath -Parent) ("config.corrupt_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $renamed = $false
        try {
            Rename-Item -LiteralPath $Script:ConfigPath -NewName (Split-Path $quarantine -Leaf) -ErrorAction Stop
            $renamed = $true
        } catch { }
        if ($renamed) {
            Write-Log -Message "Settings file was unreadable -- quarantined as $quarantine; continuing with defaults." -Level WARN
        } else {
            Write-Log -Message "Failed to load settings (using defaults): $($_.Exception.Message)" -Level WARN
        }
    }
}

function Save-Config {
    [CmdletBinding()]
    param()

    $configDir = Split-Path $Script:ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $persistLogPath = if ($Script:LogPathCustomized) { $Script:Config.LogFilePath } else { '' }
    $persistCache   = if ($Script:Config.EnableCache) { $Script:Config.CacheDir } else { 'none' }

    $persistPin = ''
    $pinProp = $Script:Config.PSObject.Properties['PinnedSpotifyVersion']
    if ($null -ne $pinProp -and $pinProp.Value) { $persistPin = [string]$pinProp.Value }

    $configObj = [PSCustomObject]@{
        MaxRetries          = $Script:Config.MaxRetries
        RetryDelayMs        = $Script:Config.RetryDelayMs
        ProcessTimeoutMs    = $Script:Config.ProcessTimeoutMs
        BackupRetentionDays = $Script:Config.BackupRetention
        LogPath             = $persistLogPath
        CacheDir            = $persistCache
        KeepLogFile         = [bool]$Script:KeepLog
        SkipPreflightCheck  = [bool]$Script:SkipPreflight
        PinnedSpotifyVersion = $persistPin
    }

    try {

        Set-ContentAtomic -Path $Script:ConfigPath -Value ($configObj | ConvertTo-Json -Depth 3)
        Write-Log -Message "Saved settings to $Script:ConfigPath" -Level INFO
    } catch {
        Write-Log -Message "Failed to save settings: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

function Read-Stats {
    [CmdletBinding()]
    param()
    $Script:TotalRuns     = 0
    $Script:SuccessCount  = 0
    $Script:FailureCount  = 0
    if (-not (Test-Path -LiteralPath $Script:StatsPath)) { return }
    try {
        $s = Get-Content -LiteralPath $Script:StatsPath -Raw | ConvertFrom-Json

        $props = $s.PSObject.Properties
        $v = 0
        $p = $props['TotalRuns']
        if ($null -ne $p -and [int]::TryParse("$($p.Value)", [ref]$v)) { $Script:TotalRuns = $v }
        $p = $props['SuccessCount']
        if ($null -ne $p -and [int]::TryParse("$($p.Value)", [ref]$v)) { $Script:SuccessCount = $v }
        $p = $props['FailureCount']
        if ($null -ne $p -and [int]::TryParse("$($p.Value)", [ref]$v)) { $Script:FailureCount = $v }
    } catch {
        Write-Log -Message "Failed to load stats (resetting): $($_.Exception.Message)" -Level DEBUG
    }
}

function Save-Stats {
    [CmdletBinding()]
    param()
    try {
        $configDir = Split-Path $Script:StatsPath -Parent
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        $statsObj = [PSCustomObject]@{
            TotalRuns    = $Script:TotalRuns
            SuccessCount = $Script:SuccessCount
            FailureCount = $Script:FailureCount
        }
        Set-ContentAtomic -Path $Script:StatsPath -Value ($statsObj | ConvertTo-Json)
    } catch {
        Write-Log -Message "Failed to save stats: $($_.Exception.Message)" -Level DEBUG
    }
}

$Script:lastWindowStateSave = [DateTime]::MinValue

function Save-WindowState {
    param(
        [Parameter(Mandatory)]$Window,
        [switch]$Force
    )
    try {

        if ($Window.WindowState -eq [System.Windows.WindowState]::Minimized) { return }

        $now = [DateTime]::UtcNow
        if (-not $Force -and ($now - $Script:lastWindowStateSave).TotalMilliseconds -lt 1000) { return }
        $Script:lastWindowStateSave = $now
        $stateDir = Split-Path $Script:WindowStatePath -Parent
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }

        if ($Window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $saveWidth  = $Window.RestoreBounds.Width
            $saveHeight = $Window.RestoreBounds.Height
            $saveTop    = $Window.RestoreBounds.Top
            $saveLeft   = $Window.RestoreBounds.Left
        } else {
            $saveWidth  = $Window.ActualWidth
            $saveHeight = $Window.ActualHeight
            $saveTop    = $Window.Top
            $saveLeft   = $Window.Left
        }

        if ([double]::IsNaN($saveLeft) -or [double]::IsNaN($saveTop) -or
            [double]::IsNaN($saveWidth) -or [double]::IsNaN($saveHeight)) { return }

        $stateObj = [PSCustomObject]@{
            Top    = $saveTop
            Left   = $saveLeft
            Width  = $saveWidth
            Height = $saveHeight
        }
        Set-ContentAtomic -Path $Script:WindowStatePath -Value ($stateObj | ConvertTo-Json)
    } catch {

    }
}

function Restore-WindowState {
    param([Parameter(Mandatory)]$Window)
    if (-not (Test-Path -LiteralPath $Script:WindowStatePath)) { return }
    try {
        $json = Get-Content -LiteralPath $Script:WindowStatePath -Raw | ConvertFrom-Json

        $props = $json.PSObject.Properties
        if ($props['Width'] -and $props['Height'] -and $props['Left'] -and $props['Top'] -and
            $null -ne $json.Left -and $null -ne $json.Top) {

            $left   = [double]$json.Left
            $top    = [double]$json.Top
            $width  = [double]$json.Width
            $height = [double]$json.Height

            $sane = ($width -ge 100 -and $height -ge 100 -and
                     -not [double]::IsNaN($left) -and -not [double]::IsNaN($top))
            $onScreen = $false
            if ($sane) {
                $vsLeft   = [System.Windows.SystemParameters]::VirtualScreenLeft
                $vsTop    = [System.Windows.SystemParameters]::VirtualScreenTop
                $vsRight  = $vsLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
                $vsBottom = $vsTop + [System.Windows.SystemParameters]::VirtualScreenHeight

                $onScreen = ($left -lt ($vsRight - 100)) -and (($left + $width) -gt ($vsLeft + 100)) -and
                            ($top -lt ($vsBottom - 100)) -and (($top + $height) -gt ($vsTop + 100))
            }

            if ($sane -and $onScreen) {

                $Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
                $Window.Left   = $left
                $Window.Top    = $top
                $Window.Width  = $width
                $Window.Height = $height
            }
        }
    } catch {

    }
}

function Show-Banner {
    Clear-Host
    $bar = ('=' * 60)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '        Spicetify Lifecycle Manager v' -NoNewline -ForegroundColor Cyan
    Write-Host $Script:ScriptVersion -ForegroundColor White
    Write-Host '        Fully automatic - no input needed' -ForegroundColor DarkCyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}

function Show-ConsoleProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Percent
    )
    if ($Script:NoUI -or -not $Script:GUIActive) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete ([Math]::Min(100, [Math]::Max(0, $Percent))) -ErrorAction SilentlyContinue
    }
}

function Close-Progress {
    Write-Progress -Activity 'SpicetifyManagerPro' -Completed -ErrorAction SilentlyContinue
}

function Show-Summary {
    param(
        [string[]]$SuccessSteps = @(),
        [string[]]$WarningSteps = @(),
        [string]$ErrorStep
    )

    Close-Progress
    $bar = ('=' * 60)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ' Summary' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan

    foreach ($step in $SuccessSteps) {
        Write-Host '  [OK]    ' -NoNewline -ForegroundColor Green
        Write-Host $step
    }
    foreach ($step in $WarningSteps) {
        Write-Host '  [!]     ' -NoNewline -ForegroundColor Yellow
        Write-Host $step
    }
    if ($ErrorStep) {
        Write-Host '  [X]     ' -NoNewline -ForegroundColor Red
        Write-Host $ErrorStep
        Write-Host $bar -ForegroundColor Red
        Write-Host ' Failed.' -ForegroundColor Red
    } else {
        Write-Host $bar -ForegroundColor Cyan
        Write-Host ' All steps completed successfully.' -ForegroundColor Green
    }
    Write-Host $bar -ForegroundColor Cyan

    if ($Script:PhaseTimings.Count -gt 0) {
        Write-Host ''
        Write-Host ' Phase timings:' -ForegroundColor DarkCyan
        foreach ($kv in $Script:PhaseTimings) {
            Write-Host ('  {0,-20} {1:N1}s' -f $kv.Key, $kv.Value.TotalSeconds) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

$Script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SpicetifyManagerPro"
        Height="720" Width="980"
        MinHeight="600" MinWidth="820"
        WindowStartupLocation="CenterScreen"
        Background="#FF121212"
        WindowStyle="None"
        ResizeMode="CanResize"
        FontFamily="Segoe UI"
        Foreground="#FFFFFFFF"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#FF1DB954"/>
            <Setter Property="Foreground" Value="#FF000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF1ED760"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF179640"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF535353"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FFA0A0A0"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FFFFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#FF404040"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E3E"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF666666"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FF535353"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnSecondary}">
            <Setter Property="Foreground" Value="#FFE22134"/>
            <Setter Property="BorderBrush" Value="#FF504040"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF3D1518"/>
                    <Setter Property="BorderBrush" Value="#FFE22134"/>
                </Trigger>
                <Trigger Property="IsFocused" Value="True">
                    <Setter Property="BorderBrush" Value="#FF664444"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="#FFC01D28"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="8"/>
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FF1DB954"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid x:Name="TitleBar" Height="32" Background="#FF121212"
              VerticalAlignment="Top" Panel.ZIndex="100"
              Margin="0,0,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
                <TextBlock Text="&#127925;" FontSize="13" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock Text="SpicetifyManagerPro" FontSize="12" FontWeight="SemiBold"
                           Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnMinimize" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Minimize">
                    <Line X1="0" Y1="8" X2="12" Y2="8" Stroke="#FFFFFFFF" StrokeThickness="2"
                          HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF2D2D2D"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF404040"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>
                <Button x:Name="BtnMaximize" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Maximize">
                    <Rectangle Stroke="#FFFFFFFF" StrokeThickness="1.5"
                               Width="10" Height="10" Fill="Transparent"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF2D2D2D"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF404040"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>
                <Button x:Name="BtnClose" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Close">
                    <Grid Width="10" Height="10"
                          HorizontalAlignment="Center" VerticalAlignment="Center">
                        <Line X1="0" Y1="0" X2="10" Y2="10" Stroke="#FFFFFFFF" StrokeThickness="1"/>
                        <Line X1="10" Y1="0" X2="0" Y2="10" Stroke="#FFFFFFFF" StrokeThickness="1"/>
                    </Grid>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FFE81123"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FFC50F0F"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>
            </StackPanel>
        </Grid>
        <Grid Margin="0,32,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="64"/>     
                <RowDefinition Height="Auto"/>   
                <RowDefinition Height="*"/>      
                <RowDefinition Height="Auto"/>   
                <RowDefinition Height="56"/>     
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#FF000000" SnapsToDevicePixels="True">
                <Grid Margin="20,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="SpicetifyManagerPro" FontSize="20" FontWeight="Bold"
                                   Foreground="#FF1DB954" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtVersion" Text="v1.1.3" FontSize="11" Foreground="#FFB3B3B3"
                                   VerticalAlignment="Bottom" Margin="8,0,0,4"
                                   Cursor="Hand"
                                   ToolTip="Click for About dialog">
                            <TextBlock.Style>
                                <Style TargetType="TextBlock">
                                    <Style.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter Property="Foreground" Value="#FF1DB954"/>
                                            <Setter Property="TextDecorations" Value="Underline"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </TextBlock.Style>
                        </TextBlock>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Background="#FF1E1E1E" CornerRadius="4" Padding="10,5" Margin="0,0,10,0">
                            <TextBlock x:Name="TxtEnvInfo" FontSize="11" Foreground="#FF888888"
                                       VerticalAlignment="Center"/>
                        </Border>
                        <Border Background="#FF1E1E1E" CornerRadius="4" Padding="10,5" Margin="0,0,14,0">
                            <TextBlock x:Name="TxtInstalledState" FontSize="11" Foreground="#FF888888"
                                       VerticalAlignment="Center"/>
                        </Border>
                        <Button x:Name="BtnUpdateBlock" Content="Updates: --"
                                Background="#FF1E1E1E" Foreground="#FF888888"
                                BorderThickness="1" BorderBrush="#FF404040"
                                Padding="10,5" Margin="0,0,10,0" FontSize="11"
                                Cursor="Hand" ToolTip="Show or change the Spotify auto-update block state"
                                TabIndex="15"
                                AutomationProperties.Name="Update Block State Button">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                                        BorderBrush="{TemplateBinding BorderBrush}"
                                                        BorderThickness="{TemplateBinding BorderThickness}"
                                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                                    <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                                      VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF3D3D3D"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                                                    </Trigger>
                                                    <Trigger Property="IsPressed" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF454545"/>
                                                    </Trigger>
                                                    <Trigger Property="IsEnabled" Value="False">
                                                        <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                    <Style.Triggers>
                                        <Trigger Property="IsEnabled" Value="False">
                                            <Setter Property="Foreground" Value="#FF535353"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </Button.Style>
                        </Button>
                        <Button x:Name="BtnSettings" Content="Settings"
                                Background="#FF282828" Foreground="#FFFFFFFF"
                                BorderThickness="1" BorderBrush="#FF404040"
                                Padding="12,5" FontSize="11" FontWeight="SemiBold"
                                Cursor="Hand" ToolTip="Open configuration settings"
                                TabIndex="20"
                                AutomationProperties.Name="Settings Button">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                                        BorderBrush="{TemplateBinding BorderBrush}"
                                                        BorderThickness="{TemplateBinding BorderThickness}"
                                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                                    <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                                      VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF3D3D3D"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                                                    </Trigger>
                                                    <Trigger Property="IsPressed" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF454545"/>
                                                    </Trigger>
                                                    <Trigger Property="IsEnabled" Value="False">
                                                        <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                    <Style.Triggers>
                                        <Trigger Property="IsEnabled" Value="False">
                                            <Setter Property="Foreground" Value="#FF535353"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </Button.Style>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>
            <Border Grid.Row="1" Background="#FF181818" Padding="20,8" SnapsToDevicePixels="True">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="TxtPhase" Text="Idle" FontSize="13" FontWeight="SemiBold"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   ToolTip="Current operation phase"/>
                        <TextBlock x:Name="TxtDetail" Text="" FontSize="12" Foreground="#FFB3B3B3"
                                   Margin="16,0,0,0" VerticalAlignment="Center"
                                   ToolTip="Detailed status message"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Elapsed:" FontSize="11" Foreground="#FF7F7F7F"
                                   VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock x:Name="TxtElapsed" Text="00:00" FontSize="12"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   FontFamily="Consolas" ToolTip="Time elapsed since operation started"/>
                        <TextBlock Text="ETA:" FontSize="11" Foreground="#FF7F7F7F"
                                   VerticalAlignment="Center" Margin="16,0,6,0"/>
                        <TextBlock x:Name="TxtEta" Text="--:--" FontSize="12"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   FontFamily="Consolas" ToolTip="Estimated time remaining"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtLastRunStatus" Grid.Column="2" FontSize="10" Foreground="#FF888888"
                               VerticalAlignment="Center" HorizontalAlignment="Right"
                               Margin="20,0,0,0" Text="Ready"
                               ToolTip="Result of last operation"/>
                </Grid>
            </Border>
            <Grid Grid.Row="2" Margin="20,12,20,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="240" MinWidth="180" MaxWidth="320"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="#FF181818" CornerRadius="4" Padding="12" SnapsToDevicePixels="True">
                    <DockPanel>
                        <TextBlock Text="Workflow" FontSize="12" FontWeight="SemiBold"
                                   Foreground="#FFB3B3B3" Margin="0,0,0,8"
                                   DockPanel.Dock="Top"/>
                        <ScrollViewer VerticalScrollBarVisibility="Auto"
                                      HorizontalScrollBarVisibility="Disabled"
                                      CanContentScroll="False">
                            <ItemsControl x:Name="StepList">
                                <ItemsControl.ItemTemplate>
                                    <DataTemplate>
                                        <StackPanel Orientation="Horizontal" Margin="0,6" ToolTip="{Binding Tooltip}">
                                            <TextBlock Text="{Binding Icon}" FontSize="14"
                                                       Margin="0,0,10,0"
                                                       VerticalAlignment="Center" FontFamily="Segoe UI"
                                                       RenderTransformOrigin="0.5,0.5">
                                                <TextBlock.RenderTransform>
                                                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                                                </TextBlock.RenderTransform>
                                                <TextBlock.Style>
                                                    <Style TargetType="TextBlock">
                                                        <Setter Property="Foreground" Value="{Binding IconColor}"/>
                                                        <Style.Triggers>
                                                            <DataTrigger Binding="{Binding State}" Value="Active">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard Name="ActivePulse">
                                                                        <Storyboard>
                                                                            <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                                                                             From="1.0" To="0.30"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                                                             From="1.0" To="1.25"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                                                             From="1.0" To="1.25"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                                <DataTrigger.ExitActions>
                                                                    <RemoveStoryboard BeginStoryboardName="ActivePulse"/>
                                                                </DataTrigger.ExitActions>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding State}" Value="Done">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard>
                                                                        <Storyboard>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                                                             From="0.4" To="1.0"
                                                                                             Duration="0:0:0.25"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                                                             From="0.4" To="1.0"
                                                                                             Duration="0:0:0.25"/>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding State}" Value="Fail">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard>
                                                                        <Storyboard>
                                                                            <DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)">
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.0" Value="1.0"/>
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.08" Value="1.4"/>
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.16" Value="1.0"/>
                                                                            </DoubleAnimationUsingKeyFrames>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                            </DataTrigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </TextBlock.Style>
                                            </TextBlock>
                                            <TextBlock Text="{Binding Name}" FontSize="12"
                                                       Foreground="{Binding TextColor}"
                                                       VerticalAlignment="Center"
                                                       TextWrapping="Wrap"
                                                       MaxWidth="260"/>
                                        </StackPanel>
                                    </DataTemplate>
                                </ItemsControl.ItemTemplate>
                            </ItemsControl>
                        </ScrollViewer>
                    </DockPanel>
                </Border>
                <Border Grid.Column="1" Background="#FF0A0A0A" CornerRadius="4" Margin="12,0,0,0" SnapsToDevicePixels="True">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Background="#FF181818" Padding="12,6" CornerRadius="4,4,0,0" SnapsToDevicePixels="True">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="Live Log" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#FFB3B3B3" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                    <TextBox x:Name="TxtLogSearch" Width="150" Height="24" Margin="0,0,8,0"
                                             FontSize="11" VerticalAlignment="Center"
                                             ToolTip="Search log entries"/>
                                    <ComboBox x:Name="CmbLogLevelFilter" Width="120" Height="24" Margin="0,0,8,0"
                                              FontSize="11" VerticalAlignment="Center" SelectedIndex="0"
                                              ToolTip="Filter logs by severity level">
                                        <ComboBoxItem Content="All Levels" Tag=""/>
                                        <ComboBoxItem Content="Errors Only" Tag="ERROR"/>
                                        <ComboBoxItem Content="Warnings+" Tag="WARN"/>
                                        <ComboBoxItem Content="Info+" Tag="INFO"/>
                                    </ComboBox>
                                    <CheckBox x:Name="ChkAutoscroll" Content="Autoscroll" IsChecked="True"
                                              Foreground="#FFB3B3B3" FontSize="11" VerticalAlignment="Center"
                                              ToolTip="Automatically scroll to newest log entries"
                                              TabIndex="90"
                                              AutomationProperties.Name="Autoscroll Log Checkbox"/>
                                    <Button x:Name="BtnCopyLog" Content="C_opy" Style="{StaticResource BtnSecondary}"
                                            Padding="8,2" FontSize="10" Margin="8,0,0,0"
                                            ToolTip="Copy log contents to clipboard"
                                            TabIndex="100"
                                            AutomationProperties.Name="Copy Log Button"/>
                                    <Button x:Name="BtnOpenLog" Content="_Open File" Style="{StaticResource BtnSecondary}"
                                            Padding="8,2" FontSize="10" Margin="4,0,0,0"
                                            ToolTip="Open log file in text editor"
                                            TabIndex="110"
                                            AutomationProperties.Name="Open Log File Button"/>
                                    <Button x:Name="BtnExportLog" Content="_Export" Style="{StaticResource BtnSecondary}"
                                            Padding="8,4" FontSize="11" Margin="4,0,0,0"
                                            ToolTip="Export filtered logs to file (Alt+E)"
                                            TabIndex="120"
                                            AutomationProperties.Name="Export Log Button"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                        <Grid Grid.Row="1">
                            <ListBox x:Name="LogList" Background="Transparent" BorderThickness="0"
                                     ScrollViewer.HorizontalScrollBarVisibility="Auto"
                                     ScrollViewer.VerticalScrollBarVisibility="Auto"
                                     FontFamily="Cascadia Mono, Consolas, monospace" FontSize="11"
                                     VirtualizingPanel.IsVirtualizing="True"
                                     VirtualizingPanel.VirtualizationMode="Recycling">
                                <ListBox.ItemTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding Line}" Foreground="{Binding Color}"
                                                   TextWrapping="NoWrap"/>
                                    </DataTemplate>
                                </ListBox.ItemTemplate>
                                <ListBox.ItemContainerStyle>
                                    <Style TargetType="ListBoxItem">
                                        <Setter Property="Padding" Value="8,1"/>
                                        <Setter Property="Margin" Value="0"/>
                                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                        <Setter Property="Template">
                                            <Setter.Value>
                                                <ControlTemplate TargetType="ListBoxItem">
                                                    <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                                                        <ContentPresenter/>
                                                    </Border>
                                                </ControlTemplate>
                                            </Setter.Value>
                                        </Setter>
                                    </Style>
                                </ListBox.ItemContainerStyle>
                            </ListBox>
                            <TextBlock x:Name="TxtLogEmptyState" Text="No log entries yet. Click Start to begin."
                                       HorizontalAlignment="Center" VerticalAlignment="Center"
                                       Foreground="#FF555555" FontSize="12" FontStyle="Italic"
                                       IsHitTestVisible="False"/>
                        </Grid>
                    </Grid>
                </Border>
            </Grid>
            <Grid Grid.Row="3" Margin="20,12,20,8">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtProgressLabel" Text="Ready" FontSize="11" Foreground="#FFB3B3B3"/>
                    <TextBlock x:Name="TxtProgressPercent" Text="0%" FontSize="11" Foreground="#FFB3B3B3"
                               Grid.Column="1" FontFamily="Consolas"
                               ToolTip="Completion percentage"/>
                </Grid>
                <ProgressBar Grid.Row="1" x:Name="MainProgress" Height="8" Minimum="0" Maximum="100"
                             Value="0" Background="#FF282828" Foreground="#FF1DB954"
                             BorderThickness="0"/>
            </Grid>
            <Border Grid.Row="4" Background="#FF000000" Padding="20,0" SnapsToDevicePixels="True">
                <Grid VerticalAlignment="Center">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button Grid.Column="0" x:Name="BtnStart" Content="_Start"
                            Style="{StaticResource BtnPrimary}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Begin full Spicetify installation (Alt+S)"
                            TabIndex="30" IsDefault="True"
                            AutomationProperties.Name="Start Installation Button"/>
                    <Button Grid.Column="1" x:Name="BtnRepair" Content="_Repair Only"
                            Style="{StaticResource BtnSecondary}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Repair broken installation (Alt+R)"
                            TabIndex="40"
                            AutomationProperties.Name="Repair Installation Button"/>
                    <Button Grid.Column="2" x:Name="BtnUninstall" Content="_Uninstall"
                            Style="{StaticResource BtnDanger}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Remove Spicetify and restore Spotify (Alt+U)"
                            TabIndex="50"
                            AutomationProperties.Name="Uninstall Button"/>
                    <Button Grid.Column="3" x:Name="BtnVersion" Content="_Version..."
                            Style="{StaticResource BtnSecondary}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Downgrade, roll forward, or pin the Spotify version; manage update blocking (Alt+V)"
                            TabIndex="55"
                            AutomationProperties.Name="Version Management Button"/>
                    <Button Grid.Column="5" x:Name="BtnOpenSpicetify" Content="Open Spicetify Folder"
                            Style="{StaticResource BtnSecondary}" FontSize="11" Margin="0,0,4,0"
                            ToolTip="Open Spicetify configuration folder"
                            TabIndex="60"
                            AutomationProperties.Name="Open Spicetify Folder Button"/>
                    <Button Grid.Column="6" x:Name="BtnRestartSpotify" Content="Restart Spotify"
                            Style="{StaticResource BtnSecondary}" FontSize="11" Margin="0,0,4,0"
                            ToolTip="Restart Spotify to apply changes"
                            TabIndex="70"
                            AutomationProperties.Name="Restart Spotify Button"/>
                    <Button Grid.Column="7" x:Name="BtnCancel" Content="_Cancel"
                            Style="{StaticResource BtnSecondary}" FontSize="13" IsEnabled="False"
                            ToolTip="Cancel current operation (Alt+C)"
                            TabIndex="80" IsCancel="True"
                            AutomationProperties.Name="Cancel Operation Button"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

$Script:SettingsWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Height="552" Width="540"
        WindowStartupLocation="CenterOwner"
        Background="#FF121212" Foreground="#FFFFFFFF"
        FontFamily="Segoe UI" ResizeMode="NoResize"
        WindowStyle="None">
    <Window.Resources>
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FFFFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#FF404040"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E3E"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF666666"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FF535353"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#FF1DB954"/>
            <Setter Property="Foreground" Value="#FF000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF1ED760"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF179640"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF535353"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FFA0A0A0"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid x:Name="SettingsTitleBar" Height="32" Background="#FF121212"
              VerticalAlignment="Top" Panel.ZIndex="100">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Settings" FontSize="12" FontWeight="SemiBold"
                       Foreground="#FFFFFFFF" VerticalAlignment="Center" Margin="12,0,0,0"/>
            <Button x:Name="BtnSettingsClose" Grid.Column="1" Width="46" Height="32"
                    Background="Transparent" BorderThickness="0"
                    Cursor="Hand" ToolTip="Close">
                <TextBlock Text="x" FontSize="11" Foreground="#FFFFFFFF"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Button.Style>
                    <Style TargetType="Button">
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}"
                                            BorderThickness="0" Padding="0">
                                        <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFE81123"/>
                                        </Trigger>
                                        <Trigger Property="IsPressed" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFC50F0F"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </Button.Style>
            </Button>
        </Grid>
        <Grid Margin="20,32,20,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Settings" FontSize="18" FontWeight="Bold"
                       Foreground="#FF1DB954" Margin="0,0,0,16"/>
            <StackPanel Grid.Row="1" Margin="0,0,0,12">
                <TextBlock Text="Max attempts for network operations (3 = try up to 3 times total; 0 = single try)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtMaxRetries" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Maximum number of attempts for network operations, counting the first try (0-10)"
                         TabIndex="10"/>
            </StackPanel>
            <StackPanel Grid.Row="2" Margin="0,0,0,12">
                <TextBlock Text="Initial retry delay (ms)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtRetryDelayMs" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Initial delay in milliseconds between retry attempts (100-30000)"
                         TabIndex="20"/>
            </StackPanel>
            <StackPanel Grid.Row="3" Margin="0,0,0,12">
                <TextBlock Text="Process timeout (ms, min 5000)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtProcessTimeoutMs" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Timeout in milliseconds for external processes (5000-600000)"
                         TabIndex="30"/>
            </StackPanel>
            <StackPanel Grid.Row="4" Margin="0,0,0,12">
                <TextBlock Text="Backup snapshot retention count" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtBackupRetention" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Number of historical backup snapshots to keep (1-50)"
                         TabIndex="40"/>
            </StackPanel>
            <StackPanel Grid.Row="5" Margin="0,0,0,12">
                <TextBlock Text="Log file path (leave empty for default)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtLogPath" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Custom path for log file (empty uses default location)"
                         TabIndex="50"/>
            </StackPanel>
            <StackPanel Grid.Row="6" Margin="0,0,0,12">
                <TextBlock Text="Cache directory (empty = default, 'none' = disable)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtCacheDir" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Directory for cached downloads (empty=default, none=disable)"
                         TabIndex="60"/>
            </StackPanel>
            <StackPanel Grid.Row="7">
                <CheckBox x:Name="ChkKeepLog" Content="Preserve log file after exit"
                          Foreground="#FFB3B3B3" FontSize="12" Margin="0,8,0,0"
                          ToolTip="Keep log file on disk after application closes"
                          TabIndex="70"/>
                <CheckBox x:Name="ChkSkipPreflight" Content="Skip pre-flight environment checks (not recommended)"
                          Foreground="#FFB3B3B3" FontSize="12" Margin="0,8,0,0"
                          ToolTip="Skip network, disk space, and architecture checks"
                          TabIndex="80"/>
            </StackPanel>
            <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="BtnResetDefaults" Content="_Defaults" Style="{StaticResource BtnSecondary}"
                        Padding="12,4" FontSize="11" Margin="0,0,8,0"
                        ToolTip="Reset fields to default values"
                        TabIndex="85"
                        AutomationProperties.Name="Reset Defaults Button"/>
                <Button x:Name="BtnCancelSettings" Content="_Cancel" Style="{StaticResource BtnSecondary}"
                        Width="80" Margin="0,0,8,0" Padding="0,6"
                        ToolTip="Discard changes and close"
                        TabIndex="90"
                        AutomationProperties.Name="Cancel Settings Button"/>
                <Button x:Name="BtnSaveSettings" Content="_Save" Style="{StaticResource BtnPrimary}"
                        Width="80" Padding="0,6"
                        ToolTip="Save settings and close"
                        TabIndex="95"
                        AutomationProperties.Name="Save Settings Button"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

$Script:VersionWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Spotify Version Management" Height="640" Width="680"
        WindowStartupLocation="CenterOwner"
        Background="#FF121212" Foreground="#FFFFFFFF"
        FontFamily="Segoe UI" ResizeMode="NoResize"
        WindowStyle="None">
    <Window.Resources>
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FFFFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#FF404040"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E3E"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF666666"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FF535353"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#FF1DB954"/>
            <Setter Property="Foreground" Value="#FF000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF1ED760"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF179640"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF535353"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FFA0A0A0"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="VersionListItem" TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="#FFDADADA"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#FF232323"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#FF1A3D2A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid x:Name="VersionTitleBar" Height="32" Background="#FF121212"
              VerticalAlignment="Top" Panel.ZIndex="100">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Spotify Version Management" FontSize="12" FontWeight="SemiBold"
                       Foreground="#FFFFFFFF" VerticalAlignment="Center" Margin="12,0,0,0"/>
            <Button x:Name="BtnVerWinClose" Grid.Column="1" Width="46" Height="32"
                    Background="Transparent" BorderThickness="0"
                    Cursor="Hand" ToolTip="Close">
                <TextBlock Text="x" FontSize="11" Foreground="#FFFFFFFF"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Button.Style>
                    <Style TargetType="Button">
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}"
                                            BorderThickness="0" Padding="0">
                                        <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFE81123"/>
                                        </Trigger>
                                        <Trigger Property="IsPressed" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFC50F0F"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </Button.Style>
            </Button>
        </Grid>
        <Grid Margin="20,40,20,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock x:Name="TxtVerCurrent" Grid.Row="0" FontSize="12" Foreground="#FFB3B3B3"
                       TextWrapping="Wrap" Margin="0,0,0,10"/>
            <Grid Grid.Row="1" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="TxtVerSearch" Grid.Column="0" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Height="28"
                         VerticalContentAlignment="Center"
                         ToolTip="Filter versions (type to search, e.g. '1.2.13')"
                         TabIndex="10"
                         AutomationProperties.Name="Version Search Box"/>
                <Button x:Name="BtnVerRefresh" Grid.Column="1" Content="Refresh online"
                        Style="{StaticResource BtnSecondary}" Padding="12,4" FontSize="11" Margin="8,0,0,0"
                        ToolTip="Fetch the available versions from the online catalog (requires internet)"
                        TabIndex="20"
                        AutomationProperties.Name="Refresh Catalog Button"/>
            </Grid>
            <ListBox x:Name="LstVersions" Grid.Row="2"
                     Background="#FF1A1A1A" Foreground="#FFDADADA"
                     BorderBrush="#FF333333" BorderThickness="1"
                     ItemContainerStyle="{StaticResource VersionListItem}"
                     DisplayMemberPath="Display"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     ScrollViewer.VerticalScrollBarVisibility="Auto"
                     VirtualizingStackPanel.IsVirtualizing="True"
                     VirtualizingStackPanel.VirtualizationMode="Recycling"
                     ScrollViewer.CanContentScroll="True"
                     TabIndex="30"
                     AutomationProperties.Name="Version List"/>
            <Border Grid.Row="3" Background="#FF1E1E1E" CornerRadius="4" Padding="10,8" Margin="0,10,0,0">
                <TextBlock x:Name="TxtVerAdvisory" FontSize="11" Foreground="#FFB3B3B3"
                           TextWrapping="Wrap" MinHeight="34"
                           Text="Select a version to see details and advisories."/>
            </Border>
            <Grid Grid.Row="4" Margin="0,14,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnVerBlock" Grid.Column="0" Content="Block updates"
                        Style="{StaticResource BtnSecondary}" FontSize="12" Margin="0,0,8,0"
                        ToolTip="Toggle the deny-ACL update block (reversible, no admin rights)"
                        TabIndex="40"
                        AutomationProperties.Name="Toggle Update Block Button"/>
                <Button x:Name="BtnVerUnpin" Grid.Column="1" Content="Clear pin"
                        Style="{StaticResource BtnSecondary}" FontSize="12" Margin="0,0,8,0"
                        ToolTip="Remove the version pin so repairs install the latest again"
                        TabIndex="50"
                        AutomationProperties.Name="Clear Version Pin Button"/>
                <Button x:Name="BtnVerDowngrade" Grid.Column="3" Content="Switch to selected"
                        Style="{StaticResource BtnPrimary}" FontSize="12" Margin="0,0,8,0"
                        ToolTip="Download the selected version, verify it, and swap it in (login and prefs are kept)"
                        TabIndex="60"
                        AutomationProperties.Name="Switch Version Button"/>
                <Button x:Name="BtnVerClose" Grid.Column="4" Content="Close"
                        Style="{StaticResource BtnSecondary}" FontSize="12"
                        ToolTip="Close this dialog" IsCancel="True"
                        TabIndex="70"
                        AutomationProperties.Name="Close Version Dialog Button"/>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

$Script:LogStream      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$Script:StepStream     = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$Script:ProgressStream = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

$Script:CancellationToken      = [System.Threading.CancellationTokenSource]::new()
$Script:GUIActive              = $false
$Script:OperationRunning       = $false
$Script:CurrentPhasePercent    = 0
$Script:OperationStartTime     = $null
$Script:OperationUtcStart      = $null
$Script:MainWindow             = $null
$Script:LogView                = $null
$Script:LogLevelFilter         = ''       
$Script:LogSearchTerm          = ''
$Script:TotalRuns              = 0
$Script:SuccessCount           = 0
$Script:FailureCount           = 0

$Script:UI_TIMER_INTERVAL_MS        = 100
$Script:COMPLETION_POLL_INTERVAL_MS = 200

$Script:LogFilterSets = @{
    ''     = @('ERROR', 'WARN', 'SUCCESS', 'INFO', 'DEBUG')
    'ERROR'= @('ERROR')
    'WARN' = @('ERROR', 'WARN')
    'INFO' = @('ERROR', 'WARN', 'SUCCESS', 'INFO')
}

function Test-LogEntryVisible {
    param($Entry)
    $allowed = $Script:LogFilterSets[$Script:LogLevelFilter]
    if ($null -eq $allowed) { $allowed = $Script:LogFilterSets[''] }
    if ($allowed -notcontains $Entry.Level) { return $false }
    if ($Script:LogSearchTerm -ne '' -and $Entry.Line -notmatch [regex]::Escape($Script:LogSearchTerm)) {
        return $false
    }
    return $true
}

function Get-LogLevelColor {
    param([string]$Level)
    switch ($Level) {
        'ERROR'   { '#FFE22134' }
        'WARN'    { '#FFFFD700' }
        'SUCCESS' { '#FF1DB954' }
        'DEBUG'   { '#FF7F7F7F' }
        default   { '#FFE0E0E0' }
    }
}

function Format-LogEntry {
    param(
        [string]$Time,
        [string]$Level,
        [string]$Msg
    )
    $lvlPadded = $Level.PadRight(7)
    $prefix = switch ($Level) {
        'ERROR'   { '[FAIL] ' }
        'WARN'    { '[WARN] ' }
        'SUCCESS' { '[ OK ] ' }
        'DEBUG'   { '[DBG ] ' }
        default   { '--    ' }
    }
    return [PSCustomObject]@{
        Time  = $Time
        Level = $Level
        Line  = "[$Time] $lvlPadded ${prefix}$Msg"
        Color = Get-LogLevelColor -Level $Level
    }
}

function Get-FriendlyErrorMessage {
    param([string]$RawError)

    if (-not $RawError) { return 'Unknown error.' }
    $errorLower = $RawError.ToLowerInvariant()

    if ($errorLower -match 'remote name could not be resolved|network|dns|connect|unreachable') {
        return "Cannot connect to GitHub.`nPlease check your internet connection and try again."
    }
    if ($errorLower -match 'access.*denied|permission|unauthorized|admin') {
        return "Access denied.`nPlease check file permissions (running as Administrator is usually NOT required)."
    }
    if ($errorLower -match 'file.*not found|cannot find path|does not exist') {
        return "Required file not found.`nThe installation may be incomplete. Try running Repair."
    }
    if ($errorLower -match 'cannot convert|invalid.*type|parse') {
        return "Invalid input format.`nPlease check your settings values."
    }
    if ($errorLower -match 'timeout|timed out|elapsed') {
        return "Operation timed out.`nThe server may be busy. Please try again."
    }
    if ($errorLower -match 'rate limit') {
        return "GitHub API rate limit reached.`nWait a while and run again."
    }
    if ($errorLower -match 'microsoft store') {
        return "Microsoft Store Spotify detected.`nSpicetify cannot modify it. Uninstall the Store version first."
    }
    if ($errorLower -match 'spicetify|spotify') {
        if ($errorLower -match 'no spotify|spotify.*not found|spotify not installed') {
            return "Spotify not found.`nPlease install Spotify first, then run this tool again."
        }
        if ($errorLower -match 'already applied|already installed') {
            return "Spicetify appears to already be installed.`nUse Uninstall first, or try Repair."
        }
    }

    if ($RawError.Length -gt 200) {
        return $RawError.Substring(0, 200) + "..."
    }
    return $RawError
}

if (-not ('Spm.StepModel' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;

namespace Spm {
    public sealed class StepModel : INotifyPropertyChanged {
        private string _name;
        private string _tooltip;
        private string _icon;
        private string _iconColor;
        private string _textColor;
        private string _state;

        public event PropertyChangedEventHandler PropertyChanged;

        public StepModel(string name, string tooltip) {
            _name = name;
            _tooltip = tooltip;
            _icon = "\u25CB";
            _iconColor = "#FF535353";
            _textColor = "#FF7F7F7F";
            _state = "Pending";
        }

        public string Name    { get { return _name; } }
        public string Tooltip { get { return _tooltip; } }

        public string Icon {
            get { return _icon; }
            set { if (_icon != value) { _icon = value; OnChanged("Icon"); } }
        }
        public string IconColor {
            get { return _iconColor; }
            set { if (_iconColor != value) { _iconColor = value; OnChanged("IconColor"); } }
        }
        public string TextColor {
            get { return _textColor; }
            set { if (_textColor != value) { _textColor = value; OnChanged("TextColor"); } }
        }
        public string State {
            get { return _state; }
            set { if (_state != value) { _state = value; OnChanged("State"); } }
        }

        private void OnChanged(string propertyName) {
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
'@ -ErrorAction Stop
}

$Script:WorkflowSteps = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

function New-StepModel {
    param(
        [string]$Name,
        [string]$Tooltip
    )
    return New-Object Spm.StepModel -ArgumentList $Name, $Tooltip
}

function Set-StepVisual {
    param($Step, [string]$State)
    switch ($State) {
        'Pending' { $Step.Icon = [char]0x25CB; $Step.IconColor = '#FF535353'; $Step.TextColor = '#FF7F7F7F' }
        'Active'  { $Step.Icon = [char]0x25D4; $Step.IconColor = '#FF1DB954'; $Step.TextColor = '#FFFFFFFF' }
        'Done'    { $Step.Icon = [char]0x2713; $Step.IconColor = '#FF1DB954'; $Step.TextColor = '#FFB3B3B3' }
        'Warn'    { $Step.Icon = [char]0x26A0; $Step.IconColor = '#FFFFD700'; $Step.TextColor = '#FFB3B3B3' }
        'Fail'    { $Step.Icon = [char]0x2717; $Step.IconColor = '#FFE22134'; $Step.TextColor = '#FFB3B3B3' }
        'Skipped' { $Step.Icon = [char]0x2014; $Step.IconColor = '#FF535353'; $Step.TextColor = '#FF535353' }
    }
    $Step.State = $State
}

function Initialize-WorkflowSteps {
    param([ValidateSet('Full', 'Repair', 'Uninstall', 'Downgrade')][string]$Mode = 'Full')

    $Script:WorkflowSteps.Clear()
    if ($Mode -eq 'Uninstall') {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stop Spotify'     -Tooltip 'Terminate running Spotify processes'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup current'   -Tooltip 'Snapshot current customizations before removal'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Remove Spicetify' -Tooltip 'Delete Spicetify CLI binary and data'))
    } elseif ($Mode -eq 'Repair') {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stop Spotify'     -Tooltip 'Terminate running Spotify processes'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup'           -Tooltip 'Snapshot current customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Repair Spotify'   -Tooltip 'Reinstall Spotify to repair corrupted files'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spicetify backup' -Tooltip 'Recreate Spicetify backup'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Apply config'     -Tooltip 'Reapply Spicetify configuration'))
    } elseif ($Mode -eq 'Downgrade') {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stop Spotify'     -Tooltip 'Terminate running Spotify processes'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup'           -Tooltip 'Snapshot user customizations before the version change'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Download'         -Tooltip 'Fetch the target version installer and verify its signature'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stage'            -Tooltip 'Extract and verify the payload before touching the live install'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Swap'             -Tooltip 'Uninstall current Spotify, place the target payload, keep user data'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spicetify'        -Tooltip 'Recreate the Spicetify backup and reapply configuration'))
    } else {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Preflight'   -Tooltip 'Environment, network, disk, architecture checks'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spotify'     -Tooltip 'Detect or install Spotify (skip Store version)'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup'      -Tooltip 'Snapshot user customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spicetify'   -Tooltip 'Install or update Spicetify CLI'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Marketplace' -Tooltip 'Install or update Spicetify Marketplace'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Restore'     -Tooltip 'Restore user customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Apply'       -Tooltip 'Apply Spicetify configuration'))
    }
}

function Get-WorkflowStepIndex {
    param([Parameter(Mandatory)][string]$Name)
    for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
        if ($Script:WorkflowSteps[$i].Name -eq $Name) { return $i }
    }
    return -1
}

function Set-WindowChrome {
    param(
        [Parameter(Mandatory)]$Window,
        [int]$CaptionHeight = 32,
        [double]$ResizeBorder = 8,
        [string[]]$ChromeButtonNames = @()
    )

    $chrome = New-Object System.Windows.Shell.WindowChrome
    $chrome.CaptionHeight        = $CaptionHeight
    $chrome.ResizeBorderThickness = New-Object System.Windows.Thickness($ResizeBorder)
    $chrome.GlassFrameThickness  = New-Object System.Windows.Thickness(0)
    $chrome.CornerRadius         = New-Object System.Windows.CornerRadius(0)
    $chrome.UseAeroCaptionButtons = $false
    $Window.SetValue([System.Windows.Shell.WindowChrome]::WindowChromeProperty, $chrome)

    foreach ($name in $ChromeButtonNames) {
        $btn = $Window.FindName($name)
        if ($null -ne $btn) {
            $btn.SetValue([System.Windows.Shell.WindowChrome]::IsHitTestVisibleInChromeProperty, $true)
        }
    }
}

function New-MainWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:MainWindowXaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }

    Set-WindowChrome -Window $window -CaptionHeight 32 -ResizeBorder 8 `
        -ChromeButtonNames @('BtnMinimize', 'BtnMaximize', 'BtnClose', 'BtnSettings')

    $window | Add-Member -MemberType NoteProperty -Name Ctrl -Value @{
        TxtPhase             = $window.FindName('TxtPhase')
        TxtDetail            = $window.FindName('TxtDetail')
        TxtElapsed           = $window.FindName('TxtElapsed')
        TxtEta               = $window.FindName('TxtEta')
        TxtVersion           = $window.FindName('TxtVersion')
        TxtEnvInfo           = $window.FindName('TxtEnvInfo')
        TxtInstalledState    = $window.FindName('TxtInstalledState')
        TxtProgressLabel     = $window.FindName('TxtProgressLabel')
        TxtProgressPercent   = $window.FindName('TxtProgressPercent')
        TxtLastRunStatus     = $window.FindName('TxtLastRunStatus')
        MainProgress         = $window.FindName('MainProgress')
        StepList             = $window.FindName('StepList')
        LogList              = $window.FindName('LogList')
        TxtLogEmptyState     = $window.FindName('TxtLogEmptyState')
        ChkAutoscroll        = $window.FindName('ChkAutoscroll')
        BtnStart             = $window.FindName('BtnStart')
        BtnRepair            = $window.FindName('BtnRepair')
        BtnUninstall         = $window.FindName('BtnUninstall')
        BtnVersion           = $window.FindName('BtnVersion')
        BtnUpdateBlock       = $window.FindName('BtnUpdateBlock')
        BtnCancel            = $window.FindName('BtnCancel')
        BtnSettings          = $window.FindName('BtnSettings')
        BtnOpenSpicetify     = $window.FindName('BtnOpenSpicetify')
        BtnRestartSpotify    = $window.FindName('BtnRestartSpotify')
        BtnCopyLog           = $window.FindName('BtnCopyLog')
        BtnOpenLog           = $window.FindName('BtnOpenLog')
        BtnExportLog         = $window.FindName('BtnExportLog')
        TxtLogSearch         = $window.FindName('TxtLogSearch')
        CmbLogLevelFilter    = $window.FindName('CmbLogLevelFilter')
        BtnMinimize          = $window.FindName('BtnMinimize')
        BtnMaximize          = $window.FindName('BtnMaximize')
        BtnClose             = $window.FindName('BtnClose')
    }

    return $window
}

function New-SettingsWindow {
    param($Owner)
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:SettingsWindowXaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
    if ($Owner) { $window.Owner = $Owner }

    Set-WindowChrome -Window $window -CaptionHeight 32 -ResizeBorder 0 `
        -ChromeButtonNames @('BtnSettingsClose')
    $window | Add-Member -MemberType NoteProperty -Name Ctrl -Value @{
        TxtMaxRetries       = $window.FindName('TxtMaxRetries')
        TxtRetryDelayMs     = $window.FindName('TxtRetryDelayMs')
        TxtProcessTimeoutMs = $window.FindName('TxtProcessTimeoutMs')
        TxtBackupRetention  = $window.FindName('TxtBackupRetention')
        TxtLogPath          = $window.FindName('TxtLogPath')
        TxtCacheDir         = $window.FindName('TxtCacheDir')
        ChkKeepLog          = $window.FindName('ChkKeepLog')
        ChkSkipPreflight    = $window.FindName('ChkSkipPreflight')
        BtnSaveSettings     = $window.FindName('BtnSaveSettings')
        BtnCancelSettings   = $window.FindName('BtnCancelSettings')
        BtnResetDefaults    = $window.FindName('BtnResetDefaults')
        BtnSettingsClose    = $window.FindName('BtnSettingsClose')
    }
    return $window
}

function New-VersionWindow {
    param($Owner)
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:VersionWindowXaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
    if ($Owner) { $window.Owner = $Owner }

    Set-WindowChrome -Window $window -CaptionHeight 32 -ResizeBorder 0 `
        -ChromeButtonNames @('BtnVerWinClose')
    $window | Add-Member -MemberType NoteProperty -Name Ctrl -Value @{
        TxtVerCurrent    = $window.FindName('TxtVerCurrent')
        TxtVerSearch     = $window.FindName('TxtVerSearch')
        BtnVerRefresh    = $window.FindName('BtnVerRefresh')
        LstVersions      = $window.FindName('LstVersions')
        TxtVerAdvisory   = $window.FindName('TxtVerAdvisory')
        BtnVerBlock      = $window.FindName('BtnVerBlock')
        BtnVerUnpin      = $window.FindName('BtnVerUnpin')
        BtnVerDowngrade  = $window.FindName('BtnVerDowngrade')
        BtnVerClose      = $window.FindName('BtnVerClose')
        BtnVerWinClose   = $window.FindName('BtnVerWinClose')
    }
    return $window
}

function Update-UpdateBlockChip {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The brush lookup is cosmetic: when the WPF brushes cannot be resolved the chip still updates its text and tooltip, just without the accent color.')]
    param($Window)
    $w = if ($Window) { $Window } else { $Script:MainWindow }
    if ($null -eq $w) { return }
    $ctrlProp = $w.PSObject.Properties['Ctrl']
    if ($null -eq $ctrlProp -or $null -eq $ctrlProp.Value) { return }
    $ctrl = $ctrlProp.Value
    $btn = $null
    if ($ctrl -is [System.Collections.IDictionary]) {
        if ($ctrl.Contains('BtnUpdateBlock')) { $btn = $ctrl['BtnUpdateBlock'] }
    } else {
        $btnProp = $ctrl.PSObject.Properties['BtnUpdateBlock']
        if ($null -ne $btnProp) { $btn = $btnProp.Value }
    }
    if ($null -eq $btn) { return }
    $accentBrush  = $null
    $neutralBrush = $null
    try {
        $accentBrush  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF1DB954')
        $neutralBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF888888')
    } catch { }
    try {
        $state = Get-SpotifyUpdateBlockState
        if ([bool]$state.Blocked) {
            $btn.Content = 'Updates: BLOCKED'
            $btn.ToolTip = 'Spotify self-updates are blocked (deny ACL on the staging paths). Click to unblock.'
            if ($null -ne $accentBrush) { $btn.Foreground = $accentBrush }
        } else {
            $btn.Content = 'Updates: allowed'
            $btn.ToolTip = 'Spotify can self-update. Click to block updates (reversible, no admin rights).'
            if ($null -ne $neutralBrush) { $btn.Foreground = $neutralBrush }
        }
        if (@($state.PendingUpdateFiles).Count -gt 0) {
            $btn.ToolTip = "$($btn.ToolTip)`nA staged update is pending and may apply on the next launch."
        }
    } catch {
        $btn.Content = 'Updates: ?'
        $btn.ToolTip = "Block state could not be read: $($_.Exception.Message)"
    }
}

function Invoke-UpdateBlockToggleUi {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The block-state probe is best-effort UI-side: on failure the toggle simply treats the update block as absent and the real operation reports any error in a message box.')]
    param($OwnerWindow)

    if ($Script:OperationRunning) {
        $null = [System.Windows.MessageBox]::Show($OwnerWindow,
            'Please wait for the current operation to complete before changing the update block.',
            'Operation in Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
        return
    }

    $state = $null
    try { $state = Get-SpotifyUpdateBlockState } catch { }
    $wasBlocked = ($null -ne $state -and [bool]$state.Blocked)

    if ($wasBlocked) {
        $body = @(
            'Unblock Spotify automatic updates?'
            ''
            'This removes the deny rules from the update staging paths;'
            'Spotify will update itself again on future launches.'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($OwnerWindow, $body, 'Unblock Updates',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne 'Yes') {
            return
        }
        try {
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
            Remove-SpotifyUpdateBlock | Out-Null
        } catch {

            $Script:ExitCode = $Script:ExitCodes['VersionBlock']
            if (-not $Script:ExitCode) { $Script:ExitCode = 12 }
            $null = [System.Windows.MessageBox]::Show($OwnerWindow,
                "Could not unblock updates:`n`n$($_.Exception.Message)",
                'Unblock Updates',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error)
            return
        } finally {
            [System.Windows.Input.Mouse]::OverrideCursor = $null
        }
    } else {
        $body = @(
            'Block Spotify automatic updates?'
            ''
            '  - Denies write access to Spotify update staging paths'
            '  - Reversible at any time, no admin rights required'
            '  - Spotify does not need to restart'
            '  - A pending staged update (if any) is discarded'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($OwnerWindow, $body, 'Block Updates',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne 'Yes') {
            return
        }
        try {
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
            Set-SpotifyUpdateBlock | Out-Null
        } catch {

            $Script:ExitCode = $Script:ExitCodes['VersionBlock']
            if (-not $Script:ExitCode) { $Script:ExitCode = 12 }
            $null = [System.Windows.MessageBox]::Show($OwnerWindow,
                "Could not block updates:`n`n$($_.Exception.Message)",
                'Block Updates',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error)
            return
        } finally {
            [System.Windows.Input.Mouse]::OverrideCursor = $null
        }
    }

    Update-UpdateBlockChip -Window $Script:MainWindow
    $null = Update-InstalledStateInfo -Window $Script:MainWindow
}

function Update-VersionDialogSelection {

    param(
        $Vw,
        [string]$InstalledVersion
    )

    $sel = $Vw.Ctrl.LstVersions.SelectedItem
    if ($null -eq $sel) {
        $Vw.Ctrl.TxtVerAdvisory.Text = 'Select a version to see details and advisories.'
        $Vw.Ctrl.TxtVerAdvisory.Foreground = [System.Windows.Media.Brushes]::Gray
        $Vw.Ctrl.BtnVerDowngrade.IsEnabled = $false
        $Vw.Ctrl.BtnVerDowngrade.Content = 'Switch to selected'
        return
    }

    $entry = $sel.Entry
    $advisories = Get-SpotifyVersionAdvisories -Entry $entry -InstalledVersion $InstalledVersion

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Target: $($entry.Full)  (released $($entry.Date))")
    foreach ($warnText in $advisories.Warnings) {
        $lines.Add("  - $warnText")
    }
    if ($advisories.HardBlock) {
        $lines.Add("")
        $lines.Add("BLOCKED: $($advisories.HardBlock)")
    }
    $Vw.Ctrl.TxtVerAdvisory.Text = ($lines -join "`n")
    if ($advisories.HardBlock) {
        $Vw.Ctrl.TxtVerAdvisory.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } elseif ($advisories.Warnings.Count -gt 0) {
        $Vw.Ctrl.TxtVerAdvisory.Foreground = [System.Windows.Media.Brushes]::Orange
    } else {
        $Vw.Ctrl.TxtVerAdvisory.Foreground = [System.Windows.Media.Brushes]::LightGray
    }

    $targetV = ConvertTo-SpotifyVersion -Version $entry.Short
    $currentV = ConvertTo-SpotifyVersion -Version $InstalledVersion
    $actionLabel = "Switch to $($entry.Short)"
    if ($null -ne $currentV -and $null -ne $targetV) {
        if ($currentV -eq $targetV)     { $actionLabel = "Reinstall $($entry.Short)" }
        elseif ($targetV -lt $currentV) { $actionLabel = "Downgrade to $($entry.Short)" }
        else                            { $actionLabel = "Upgrade to $($entry.Short)" }
    }
    $Vw.Ctrl.BtnVerDowngrade.Content = $actionLabel

    $Vw.Ctrl.BtnVerDowngrade.IsEnabled = $true
}

function Show-VersionWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Dispose guards on an already-failing refresh path: the error box right after them reports the actual failure.')]
    [CmdletBinding()]
    param()

    $w = $Script:MainWindow
    if ($Script:OperationRunning) {
        $null = [System.Windows.MessageBox]::Show($w,
            'Please wait for the current operation to complete before opening version management.',
            'Operation in Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
        return
    }

    $vw = New-VersionWindow -Owner $w
    $vw.Ctrl.BtnVerWinClose.Add_Click({ $vw.Close() })
    $vw.Ctrl.BtnVerClose.Add_Click({ $vw.Close() })

    $installed = Get-InstalledSpotifyFileVersion
    $arch = Get-SpotifyCatalogArch
    $installedV = ConvertTo-SpotifyVersion -Version $installed
    $pin = [string]$Script:Config.PinnedSpotifyVersion

    $buildStatusText = {
        param([string]$Tail)
        $text = if ($installed) { "Installed: $installed" } else { 'Installed: (not found in the managed location)' }
        if ($pin) { $text = "$text`nPinned: $pin (repairs keep this version)" }
        return "$text`n$Tail"
    }

    $populateFromCache = {
        $fresh = New-Object System.Collections.Generic.List[object]
        $loginMin = ConvertTo-SpotifyVersion -Version '1.1.87.612'
        $loginMax = ConvertTo-SpotifyVersion -Version '1.2.5.1006'
        foreach ($e in (Get-SpotifyVersionCatalog)) {
            if (-not (Test-SpotifyVersionOffered -Entry $e -Arch $arch)) { continue }
            $flags = @()
            $v = ConvertTo-SpotifyVersion -Version $e.Short
            if ($null -ne $installedV -and $null -ne $v -and $v -eq $installedV) { $flags += 'current' }
            if ($pin -and $e.Short -eq $pin) { $flags += 'pinned' }
            if ($null -ne $v -and $null -ne $loginMin -and $null -ne $loginMax -and
                $v -ge $loginMin -and $v -le $loginMax) { $flags += 'login broken' }
            $display = '{0,-16} {1,-12}' -f $e.Short, $e.Date
            if ($flags.Count -gt 0) { $display = "$display  [$($flags -join ', ')]" }
            $fresh.Add([PSCustomObject]@{ Display = $display; Entry = $e })
        }
        $vw | Add-Member -MemberType NoteProperty -Name AllVersions -Value $fresh -Force
        $filter = "$($vw.Ctrl.TxtVerSearch.Text)".Trim()
        $visible = $fresh
        if ($filter -ne '') {
            $visible = New-Object System.Collections.Generic.List[object]
            foreach ($item in $fresh) {
                if ($item.Display -like "*$filter*") { $visible.Add($item) }
            }
        }
        $vw.Ctrl.LstVersions.ItemsSource = $visible
        $vw.Ctrl.TxtVerCurrent.Text = & $buildStatusText ("Offered: $($fresh.Count) version(s) for native arch $arch (online catalog)")
        Update-VersionDialogSelection -Vw $vw -InstalledVersion $installed
    }

    if (-not $pin) { $vw.Ctrl.BtnVerUnpin.Visibility = [System.Windows.Visibility]::Collapsed }
    $vw | Add-Member -MemberType NoteProperty -Name RefreshInFlight -Value $false
    $vw | Add-Member -MemberType NoteProperty -Name RefreshTimer -Value $null
    $vw | Add-Member -MemberType NoteProperty -Name FetchClient -Value $null
    $vw | Add-Member -MemberType NoteProperty -Name FetchTask -Value $null
    $vw | Add-Member -MemberType NoteProperty -Name AllVersions -Value $null
    $vw | Add-Member -MemberType NoteProperty -Name ManualRefresh -Value $false
    $vw | Add-Member -MemberType NoteProperty -Name DialogClosed -Value $false
    $vw.Add_Closed({
        $vw | Add-Member -MemberType NoteProperty -Name DialogClosed -Value $true -Force
        if ($vw.RefreshTimer) { try { $vw.RefreshTimer.Stop() } catch { } }
        $vw.RefreshTimer = $null
        if ($vw.FetchTask -and -not $vw.FetchTask.IsCompleted) {
            try { $vw.FetchClient.CancelPendingRequests() } catch { }
        }
        if ($vw.FetchClient) { try { $vw.FetchClient.Dispose() } catch { } }
        $vw.FetchClient = $null
        $vw.FetchTask = $null
        $vw.RefreshInFlight = $false
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    })

    $vw.Ctrl.LstVersions.Add_SelectionChanged({
        Update-VersionDialogSelection -Vw $vw -InstalledVersion $installed
    })

    $vw.Ctrl.TxtVerSearch.Add_TextChanged({
        $filter = "$($vw.Ctrl.TxtVerSearch.Text)".Trim()
        $visible = New-Object System.Collections.Generic.List[object]
        if ($null -ne $vw.AllVersions) {
            foreach ($item in $vw.AllVersions) {
                if ($filter -eq '' -or $item.Display -like "*$filter*") {
                    $visible.Add($item)
                }
            }
        }
        $vw.Ctrl.LstVersions.ItemsSource = $visible
    })

    $beginOnlineFetch = {
        param([switch]$Manual)
        if ($vw.RefreshInFlight) { return }
        $vw.RefreshInFlight = $true
        $vw | Add-Member -MemberType NoteProperty -Name ManualRefresh -Value ([bool]$Manual) -Force
        $vw.Ctrl.BtnVerRefresh.IsEnabled = $false
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        $vw.Ctrl.TxtVerCurrent.Text = & $buildStatusText 'Fetching the available versions online...'

        $vw.FetchClient = $null
        $vw.FetchTask = $null
        $startError = $null
        try {
            $vw.FetchClient = [System.Net.Http.HttpClient]::new()
            $vw.FetchClient.Timeout = [TimeSpan]::FromSeconds(20)
            $vw.FetchTask = $vw.FetchClient.GetStringAsync($Script:SpotifyCatalogManifestUrl)
        } catch {
            $startError = $_.Exception.Message
        }
        if ($null -eq $vw.FetchTask) {
            if ($vw.FetchClient) { try { $vw.FetchClient.Dispose() } catch { } }
            $vw.RefreshTimer = $null
            $vw.RefreshInFlight = $false
            $vw.Ctrl.BtnVerRefresh.IsEnabled = $true
            [System.Windows.Input.Mouse]::OverrideCursor = $null
            $vw.Ctrl.TxtVerCurrent.Text = & $buildStatusText 'No versions loaded -- the online catalog is unreachable. Use Refresh to retry.'
            if ($vw.ManualRefresh) {
                $null = [System.Windows.MessageBox]::Show($vw,
                    "Online catalog unavailable:`n`n$startError",
                    'Version Catalog', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            }
            return
        }

        $refreshTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $refreshTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $vw.RefreshTimer = $refreshTimer
        $refreshTimer.Add_Tick({
            if (-not $vw.FetchTask.IsCompleted) { return }
            $vw.RefreshTimer.Stop()
            if ($vw.DialogClosed) {
                if ($vw.FetchClient) { try { $vw.FetchClient.Dispose() } catch { } }
                $vw.FetchClient = $null
                $vw.FetchTask = $null
                $vw.RefreshTimer = $null
                $vw.RefreshInFlight = $false
                return
            }
            $liveJson = $null
            $fetchError = $null
            try {
                $liveJson = $vw.FetchTask.Result
            } catch {
                $fetchError = $_.Exception.InnerException
                if ($null -eq $fetchError) { $fetchError = $_.Exception }
            }
            try { $vw.FetchClient.Dispose() } catch { }
            if ($null -ne $fetchError -or -not $liveJson) {
                $vw.RefreshTimer = $null
                $vw.RefreshInFlight = $false
                $vw.Ctrl.BtnVerRefresh.IsEnabled = $true
                [System.Windows.Input.Mouse]::OverrideCursor = $null
                $vw.Ctrl.TxtVerCurrent.Text = & $buildStatusText 'No versions loaded -- the online catalog is unreachable. Use Refresh to retry.'
                $errMsg = if ($fetchError) { $fetchError.Message } else { 'The catalog response was empty.' }
                if ($vw.ManualRefresh) {
                    $null = [System.Windows.MessageBox]::Show($vw,
                        "Online catalog unavailable:`n`n$errMsg",
                        'Version Catalog', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
                return
            }
            try {
                $null = Get-SpotifyVersionCatalog -Online -RawJson $liveJson
                & $populateFromCache
                if ($vw.ManualRefresh) {
                    $null = [System.Windows.MessageBox]::Show($vw,
                        "Catalog refreshed: $($vw.AllVersions.Count) version(s) offered.",
                        'Version Catalog', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                }
            } catch {
                $vw.Ctrl.TxtVerCurrent.Text = & $buildStatusText 'No versions loaded -- the online catalog could not be read. Use Refresh to retry.'
                if ($vw.ManualRefresh) {
                    $null = [System.Windows.MessageBox]::Show($vw,
                        "Online catalog refresh failed:`n`n$($_.Exception.Message)",
                        'Version Catalog', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                }
            } finally {
                $vw.RefreshTimer = $null
                $vw.RefreshInFlight = $false
                $vw.Ctrl.BtnVerRefresh.IsEnabled = $true
                [System.Windows.Input.Mouse]::OverrideCursor = $null
            }
        })
        $refreshTimer.Start()
    }
    $vw.Ctrl.BtnVerRefresh.Add_Click({ & $beginOnlineFetch -Manual })

    $updateBlockLabel = {
        try {
            $s = Get-SpotifyUpdateBlockState
            if ([bool]$s.Blocked) { $vw.Ctrl.BtnVerBlock.Content = 'Unblock updates' }
            else { $vw.Ctrl.BtnVerBlock.Content = 'Block updates' }
        } catch { $vw.Ctrl.BtnVerBlock.Content = 'Block updates' }
    }
    & $updateBlockLabel
    $vw.Ctrl.BtnVerBlock.Add_Click({
        Invoke-UpdateBlockToggleUi -OwnerWindow $vw
        & $updateBlockLabel
    })

    $vw.Ctrl.BtnVerUnpin.Add_Click({
        if (-not $Script:Config.PinnedSpotifyVersion) { return }
        $body = @(
            "Clear the version pin ($($Script:Config.PinnedSpotifyVersion))?"
            ''
            'Repairs and installs will use the latest Spotify again.'
            'The installed version itself is NOT changed.'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($vw, $body, 'Clear Version Pin',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne 'Yes') {
            return
        }
        $Script:Config.PinnedSpotifyVersion = ''
        $Script:PinnedSpotifyVersion = ''
        try {
            Save-Config
        } catch {
            Write-Log -Message "Could not persist the cleared pin: $($_.Exception.Message)" -Level WARN
        }
        $vw.Ctrl.BtnVerUnpin.Visibility = [System.Windows.Visibility]::Collapsed
        $null = Update-InstalledStateInfo -Window $w
        $null = [System.Windows.MessageBox]::Show($vw, 'Version pin cleared.',
            'Clear Version Pin',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $vw.Ctrl.BtnVerDowngrade.Add_Click({
        $sel = $vw.Ctrl.LstVersions.SelectedItem
        if ($null -eq $sel) { return }
        $entry = $sel.Entry
        $advisories = Get-SpotifyVersionAdvisories -Entry $entry -InstalledVersion $installed

        if ($advisories.HardBlock) {
            $ack = @(
                "WARNING -- version $($entry.Short):"
                ''
                $advisories.HardBlock
                ''
                'Do you explicitly want to continue anyway?'
            ) -join "`n"
            if ([System.Windows.MessageBox]::Show($vw, $ack, 'Blocking Advisory',
                    [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne 'Yes') {
                return
            }
            $Script:VersionRisksAccepted = $true
        }

        $Script:DowngradeTarget = $entry.Short
        $vw.Close()
        $confirmBody = @(
            "Switch Spotify to version $($entry.Short)?"
            ''
            'The tool will:'
            '  1. Stop Spotify and back up your customizations'
            "  2. Download the $($entry.Short) installer and verify it (size + signature)"
            '  3. Extract and verify the payload BEFORE touching the live install'
            '  4. Uninstall the current Spotify, then place the verified payload'
            '     (login and preferences are preserved)'
            '  5. Recreate the Spicetify backup and reapply your configuration'
            '  6. Set a version pin so repairs keep this version'
            ''
            'A previously active update block is re-applied afterwards.'
        ) -join "`n"
        Start-Operation -Mode 'Downgrade' -ConfirmTitle 'Confirm Version Change' -ConfirmBody $confirmBody
    })

    Update-VersionDialogSelection -Vw $vw -InstalledVersion $installed
    & $beginOnlineFetch

    $null = $vw.ShowDialog()
}

function Set-UiEnabled {
    param([bool]$Enabled)
    $w = $Script:MainWindow
    if ($null -eq $w) { return }
    $w.Dispatcher.Invoke([Action]{
        $w.Ctrl.BtnStart.IsEnabled          = $Enabled
        $w.Ctrl.BtnRepair.IsEnabled         = $Enabled
        $w.Ctrl.BtnUninstall.IsEnabled      = $Enabled
        $w.Ctrl.BtnVersion.IsEnabled        = $Enabled
        $w.Ctrl.BtnUpdateBlock.IsEnabled    = $Enabled
        $w.Ctrl.BtnSettings.IsEnabled       = $Enabled
        $w.Ctrl.BtnCancel.IsEnabled         = -not $Enabled
        $w.Ctrl.BtnOpenSpicetify.IsEnabled  = $Enabled
        $w.Ctrl.BtnRestartSpotify.IsEnabled = $Enabled
        if ($Enabled) {
            $w.Ctrl.BtnCancel.Content = "_Cancel"
            $w.Ctrl.MainProgress.IsIndeterminate = $false
        }
    })
}

function Update-ElapsedClock {
    param([datetime]$StartTime, [datetime]$Now)
    $w = $Script:MainWindow
    if ($null -eq $w -or $null -eq $w.Ctrl.TxtElapsed) { return }
    $elapsed = $Now - $StartTime
    $h = [int]$elapsed.TotalHours
    $m = $elapsed.Minutes
    $s = $elapsed.Seconds
    $elapsedStr = if ($h -gt 0) { '{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s }
                  else { '{0:D2}:{1:D2}' -f $m, $s }
    $w.Ctrl.TxtElapsed.Text = $elapsedStr
}

function New-UiTimer {
    param()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($Script:UI_TIMER_INTERVAL_MS)

    $timer.Add_Tick({
        $w = $Script:MainWindow
        if ($null -eq $w) { return }
        $startTime = $Script:OperationUtcStart
        if ($null -eq $startTime) { $startTime = [datetime]::UtcNow }
        try {
            $drained = 0
            $maxDrainPerTick = 200
            while (-not $Script:LogStream.IsEmpty -and $drained -lt $maxDrainPerTick) {
                $entry = $null
                if ($Script:LogStream.TryDequeue([ref]$entry)) {
                    $Script:LogEntries.Add((Format-LogEntry -Time $entry.Time -Level $entry.Level -Msg $entry.Msg))
                    $drained++
                } else { break }
            }

            $maxLogItems = 5000
            while ($Script:LogEntries.Count -gt $maxLogItems) {
                $Script:LogEntries.RemoveAt(0)
            }
            if ($null -ne $w.Ctrl.TxtLogEmptyState) {
                if ($Script:LogEntries.Count -gt 0) {
                    $w.Ctrl.TxtLogEmptyState.Visibility = [System.Windows.Visibility]::Collapsed
                } else {
                    $w.Ctrl.TxtLogEmptyState.Visibility = [System.Windows.Visibility]::Visible
                }
            }
            if ($drained -gt 0 -and $w.Ctrl.ChkAutoscroll.IsChecked -eq $true -and $Script:LogEntries.Count -gt 0) {
                $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
            }

            while (-not $Script:StepStream.IsEmpty) {
                $evt = $null
                if ($Script:StepStream.TryDequeue([ref]$evt)) {
                    if ($evt.Index -ge 0 -and $evt.Index -lt $Script:WorkflowSteps.Count) {
                        Set-StepVisual -Step $Script:WorkflowSteps[$evt.Index] -State $evt.State
                    }
                } else { break }
            }

            while (-not $Script:ProgressStream.IsEmpty) {
                $p = $null
                if ($Script:ProgressStream.TryDequeue([ref]$p)) {
                    if ($p.Phase) {

                        $phaseKey = Get-PhaseExitKey -Phase $p.Phase
                        if ($phaseKey) { $Script:CurrentPhase = $phaseKey }
                        $w.Ctrl.TxtPhase.Text = $p.Phase
                    }
                    if ($p.Detail) { $w.Ctrl.TxtDetail.Text = $p.Detail }
                    if ($p.Percent -ge 0) {
                        $clamped = [Math]::Min(100, [Math]::Max(0, $p.Percent))
                        $Script:CurrentPhasePercent = $clamped
                        $w.Ctrl.MainProgress.Value = $clamped
                        $w.Ctrl.TxtProgressPercent.Text = $clamped.ToString() + '%'
                        if ($w.Ctrl.MainProgress.IsIndeterminate) {
                            $w.Ctrl.MainProgress.IsIndeterminate = $false
                        }
                    }
                    if ($p.IsIndeterminate) {
                        $w.Ctrl.MainProgress.IsIndeterminate = $true
                    }
                    if ($p.Label) { $w.Ctrl.TxtProgressLabel.Text = $p.Label }
                } else { break }
            }

            Update-ElapsedClock -StartTime $startTime -Now ([datetime]::UtcNow)

            if ($Script:OperationRunning -and $Script:CurrentPhasePercent -gt 3 -and $Script:CurrentPhasePercent -lt 100) {
                $elapsedSoFar = ([datetime]::UtcNow - $startTime).TotalSeconds
                $estTotal = $elapsedSoFar / ($Script:CurrentPhasePercent / 100.0)
                $remaining = [Math]::Max(0, $estTotal - $elapsedSoFar)
                $h = [int]([Math]::Floor($remaining / 3600))
                $m = [int]([Math]::Floor(($remaining % 3600) / 60))
                $s = [int]([Math]::Floor($remaining % 60))
                $etaStr = if ($h -gt 0) { '{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s }
                          else { '{0:D2}:{1:D2}' -f $m, $s }
                $w.Ctrl.TxtEta.Text = $etaStr
            }

            if ($Script:CancellationToken.IsCancellationRequested) {
                $w.Ctrl.TxtEta.Text = 'cancelling...'
                if ($w.Ctrl.TxtPhase.Text -ne 'Cancelling') {
                    $w.Ctrl.TxtPhase.Text = 'Cancelling'
                    $w.Ctrl.TxtDetail.Text = 'Waiting for operation to stop...'
                    $w.Ctrl.MainProgress.IsIndeterminate = $true
                }
            }
        } catch {

        }
    })

    return $timer
}

$Script:WorkerFunctionNames = @(

    'Write-Log', 'Write-Step', 'Set-Progress', 'Set-Step',
    'Test-Cancelled', 'Assert-NotCancelled', 'Start-SleepCancellable', 'Invoke-WithRetry',
    'Invoke-ExternalCommand', 'Invoke-SpicetifyCli',
    'Copy-ItemSafe', 'Test-ZipIntegrity', 'Test-ZipEntryPaths', 'Wait-ForFileRelease',
    'Wait-ForSpotifyRelease', 'Get-FreeDiskSpaceMB', 'Set-IniValue', 'Set-ContentAtomic',
    'Get-DownloadGlobalPercent', 'Invoke-DownloadWithProgress',
    'Get-GitHubLatestRelease', 'Resolve-SpicetifyConfigPaths', 'Get-TempDir',
    'Get-IniValue',

    'Test-NetworkOk', 'Test-MicrosoftStoreSpotify', 'Test-ArchitectureSupported',
    'Test-InstallerSignature',
    'Test-DiskSpace', 'Stop-SpotifyProcess',
    'Install-Spotify', 'Repair-Spotify',
    'Backup-UserCustomizations', 'Restore-UserCustomizations', 'Save-BackupHistory',
    'Get-SpicetifyLocalVersion', 'Install-Spicetify', 'Uninstall-Spicetify',
    'Install-Marketplace',
    'Get-CombinedOutput', 'Test-BackupOutputForRepair', 'Test-ApplyOutputForFailure',
    'Invoke-SpicetifyBackupWithRepair', 'Invoke-SpicetifyApply',
    'Invoke-PreflightChecks',

    'ConvertTo-SpotifyVersion', 'Get-SpotifyCatalogArch', 'Get-SpotifyVersionCatalog',
    'Get-SpotifyCatalogEntry', 'Get-SpotifyDownloadInfo', 'Test-SpotifyVersionOffered',
    'Get-SpotifyVersionAdvisories', 'Test-PathDenyAcl', 'Set-DenyWriteAcl',
    'Get-SpotifyUpdateGuardScope', 'Get-SpotifyUpdateBlockState', 'Set-SpotifyUpdateBlock', 'Remove-SpotifyUpdateBlock',
    'Get-InstalledSpotifyFileVersion', 'Invoke-SpotifyInstallerDownload',
    'Invoke-SpotifyPayloadExtract', 'Invoke-SpotifyCurrentUninstall',
    'Stop-SpotifyUninstaller',
    'Invoke-SpotifyLeftoverCleanup', 'Invoke-SpotifyUserdataStage',
    'Invoke-SpotifyUserdataRestore', 'Invoke-SpotifyRegistryWrite',
    'Invoke-SpotifyVersionSwap', 'Get-PinnedSpotifyVersion', 'Save-Config',
    'Save-StagedUserdata', 'Get-HostOsMajor',

    'Start-Phase', 'Complete-Phase', 'Invoke-Workflow',

    'Get-WorkflowStepIndex', 'Set-StepVisual', 'Show-ConsoleProgress'
)

function New-WorkerScript {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Script:WorkerFunctionNames) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            throw "Worker assembly failed: function '$name' is not defined."
        }
        $fullText = $cmd.ScriptBlock.Ast.Extent.Text
        if ($fullText -notmatch "^function\s+$([regex]::Escape($name))") {
            throw "Worker assembly sanity check failed for '${name}'."
        }
        $parts.Add($fullText)
        $parts.Add('')
    }

    $bootstrap = @'
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Script:Config          = $Config
$Script:LogStream       = $LogStream
$Script:StepStream      = $StepStream
$Script:ProgressStream  = $ProgressStream
$Script:CancellationToken = $CancellationToken
$Script:ScriptVersion   = $ScriptVersion
$Script:UninstallMode   = $UninstallMode
$Script:RepairMode      = $RepairMode
$Script:SkipPreflight   = $SkipPreflight
$Script:WorkflowSteps   = $WorkflowSteps
$Script:TempFiles       = $TempFiles
$Script:PhaseTimings    = $PhaseTimings
$Script:GUIActive       = $true
$Script:NoUI            = $false
$Script:StagingPath     = $null
$Script:StagingValid    = $false
$Script:CurrentPhase    = 'Init'
$Script:PhaseStartTime  = $null
$Script:ExitCodes       = $ExitCodes
$Script:LogMutex        = $LogMutex
$Script:LogWriteCount   = 0
$Script:LogFileWriteFailed = $false
$Script:DowngradeMode        = $DowngradeMode
$Script:DowngradeTarget      = $DowngradeTarget
$Script:PinnedSpotifyVersion = $PinnedSpotifyVersion
$Script:AcceptVersionRisks   = $AcceptVersionRisks
$Script:WorkerActiveStepName = $null
$Script:UpdateBlockReapplyFailed = $false
$Script:VersionCatalogCache     = $VersionCatalogCache
$Script:SpotifyCatalogManifestUrl = $SpotifyCatalogManifestUrl
$Script:ConfigPath     = $ConfigPath
$Script:AppStateDir    = $AppStateDir
$Script:KeepLog        = $KeepLog
$Script:LogPathCustomized = $LogPathCustomized

try {
    $workflowResult = Invoke-Workflow
    Write-Output $workflowResult
} finally {
    try { Stop-SpotifyUninstaller } catch { }
    if ($Script:StagingPath -and (Test-Path -LiteralPath $Script:StagingPath)) {
        $rescueFailed = $false
        try {
            $null = Save-StagedUserdata -StagingPath $Script:StagingPath
        } catch {
            $rescueFailed = $true
        }
        if ($rescueFailed) {
            Write-Log -Message "Staging $Script:StagingPath left in place: user data could not be fully rescued. Recover it manually." -Level ERROR
        } else {
            Remove-Item -LiteralPath $Script:StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
'@
    $source = ($parts -join "`n") + "`n" + $bootstrap

    $parseErrors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "Assembled worker script has parse errors: $($parseErrors[0].Message)"
    }
    return $source
}

function New-WorkerRunspace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The dispose catch blocks are last-resort cleanup guards on an already-failing path; there is nothing left to do when disposal itself throws.')]
    param([Parameter(Mandatory)][string]$WorkerSource)

    $rs     = [runspacefactory]::CreateRunspace()
    $ps     = $null
    $opened = $false
    try {
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $opened = $true

        $rs.SessionStateProxy.SetVariable('Config',          $Script:Config)
        $rs.SessionStateProxy.SetVariable('LogStream',       $Script:LogStream)
        $rs.SessionStateProxy.SetVariable('StepStream',      $Script:StepStream)
        $rs.SessionStateProxy.SetVariable('ProgressStream',  $Script:ProgressStream)
        $rs.SessionStateProxy.SetVariable('CancellationToken', $Script:CancellationToken)
        $rs.SessionStateProxy.SetVariable('ScriptVersion',   $Script:ScriptVersion)
        $rs.SessionStateProxy.SetVariable('UninstallMode',   [bool]$Script:UninstallMode)
        $rs.SessionStateProxy.SetVariable('RepairMode',      [bool]$Script:RepairMode)
        $rs.SessionStateProxy.SetVariable('SkipPreflight',   [bool]$Script:SkipPreflight)
        $rs.SessionStateProxy.SetVariable('WorkflowSteps',   $Script:WorkflowSteps)
        $rs.SessionStateProxy.SetVariable('TempFiles',       $Script:TempFiles)
        $rs.SessionStateProxy.SetVariable('PhaseTimings',    $Script:PhaseTimings)
        $rs.SessionStateProxy.SetVariable('ExitCodes',       $Script:ExitCodes)
        $rs.SessionStateProxy.SetVariable('LogMutex',        $Script:LogMutex)

        $rs.SessionStateProxy.SetVariable('DowngradeMode',        [bool]$Script:DowngradeMode)
        $rs.SessionStateProxy.SetVariable('DowngradeTarget',      [string]$Script:DowngradeTarget)
        $rs.SessionStateProxy.SetVariable('PinnedSpotifyVersion', [string]$Script:Config.PinnedSpotifyVersion)

        $riskVal = $false
        $riskVar = Get-Variable -Name 'VersionRisksAccepted' -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $riskVar -and [bool]$riskVar.Value) { $riskVal = $true }
        if (-not $riskVal -and [bool]$AcceptVersionRisks) { $riskVal = $true }
        $rs.SessionStateProxy.SetVariable('AcceptVersionRisks', $riskVal)
        $rs.SessionStateProxy.SetVariable('VersionCatalogCache',       $Script:VersionCatalogCache)
        $rs.SessionStateProxy.SetVariable('SpotifyCatalogManifestUrl', $Script:SpotifyCatalogManifestUrl)
        $rs.SessionStateProxy.SetVariable('ConfigPath',          $Script:ConfigPath)
        $rs.SessionStateProxy.SetVariable('AppStateDir',         $Script:AppStateDir)
        $rs.SessionStateProxy.SetVariable('KeepLog',             [bool]$Script:KeepLog)
        $rs.SessionStateProxy.SetVariable('LogPathCustomized',   [bool]$Script:LogPathCustomized)

        $rs.SessionStateProxy.SetVariable('WhatIfPreference', [bool]$WhatIfPreference)

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($WorkerSource)

        return [PSCustomObject]@{
            Runspace   = $rs
            PowerShell = $ps
            Handle     = $ps.BeginInvoke()
        }
    } catch {
        if ($null -ne $ps) {
            try { $ps.Dispose() } catch { }
        }
        if ($opened) {
            try { $rs.Close() } catch { }
        }
        try { $rs.Dispose() } catch { }
        throw
    }
}

function Set-Progress {
    param(
        [string]$Phase,
        [string]$Detail,
        [int]$Percent = -1,
        [string]$Label,
        [switch]$IsIndeterminate
    )
    if ($Script:GUIActive) {
        $Script:ProgressStream.Enqueue([PSCustomObject]@{
            Phase          = $Phase
            Detail         = $Detail
            Percent        = $Percent
            Label          = $Label
            IsIndeterminate = $IsIndeterminate.IsPresent
        }) | Out-Null
    } else {
        if ($Percent -ge 0) {
            Show-ConsoleProgress -Activity 'SpicetifyManagerPro' -Status $Detail -Percent $Percent
        }
    }
}

function Set-Step {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$State)
    $index = Get-WorkflowStepIndex -Name $Name
    if ($index -lt 0) { return }

    if ($State -eq 'Active') {
        $Script:WorkerActiveStepName = $Name
    } elseif ($State -ne 'Active' -and $Script:WorkerActiveStepName -eq $Name) {
        $Script:WorkerActiveStepName = $null
    }
    if ($Script:GUIActive) {
        $Script:StepStream.Enqueue([PSCustomObject]@{
            Index = $index
            State = $State
        }) | Out-Null
    } else {
        Set-StepVisual -Step $Script:WorkflowSteps[$index] -State $State
    }
}

function Test-Cancelled {
    return ($null -ne $Script:CancellationToken -and $Script:CancellationToken.IsCancellationRequested)
}

function Assert-NotCancelled {
    if (Test-Cancelled) {
        throw 'Operation cancelled by user.'
    }
}

function Start-SleepCancellable {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure wait helper: it changes no system state beyond sleeping, -WhatIf is meaningless.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Milliseconds,
        [int]$SliceMs = 200
    )
    if ($SliceMs -lt 50) { $SliceMs = 50 }
    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        Assert-NotCancelled
        $slice = [Math]::Min($SliceMs, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    Assert-NotCancelled
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Label = 'Operation',
        [int]$MaxAttempts,
        [int]$InitialDelayMs
    )

    if (-not $PSBoundParameters.ContainsKey('MaxAttempts')) {
        $MaxAttempts = $Script:Config.MaxRetries
    }
    if (-not $PSBoundParameters.ContainsKey('InitialDelayMs')) {
        $InitialDelayMs = $Script:Config.RetryDelayMs
    }

    if ($MaxAttempts -le 0) {
        Assert-NotCancelled
        return & $Action
    }

    $delay = $InitialDelayMs
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Assert-NotCancelled
        try {
            return & $Action
        } catch {

            if (Test-Cancelled) { throw }
            $fatalClientError = $false
            $clientStatusCode = 0
            try {
                $webEx = $_.Exception
                $respStatus = $null
                if ($webEx -is [System.Net.WebException] -and $null -ne $webEx.Response) {
                    $respStatus = $webEx.Response.StatusCode
                } elseif ("$($webEx.GetType().FullName)" -eq 'Microsoft.PowerShell.Commands.HttpResponseException' -and $null -ne $webEx.Response) {
                    $respStatus = $webEx.Response.StatusCode
                }
                if ($null -ne $respStatus) { $clientStatusCode = [int]$respStatus }
                if ($clientStatusCode -ge 400 -and $clientStatusCode -lt 500 -and $clientStatusCode -ne 408 -and $clientStatusCode -ne 429) {
                    $fatalClientError = $true
                }
            } catch { $fatalClientError = $false }
            if ($fatalClientError) {
                Write-Log -Message "$Label failed with a client error (HTTP $clientStatusCode) -- not retrying." -Level ERROR
                throw
            }
            if ($attempt -eq $MaxAttempts) {
                Write-Log -Message "$Label failed after $MaxAttempts attempts: $($_.Exception.Message)" -Level ERROR
                throw
            }
            Write-Log -Message "$Label attempt $attempt failed (retry in ${delay}ms): $($_.Exception.Message)" -Level WARN
            Start-SleepCancellable -Milliseconds $delay
            $delay = [Math]::Min($delay * 2, 30000)
        }
    }
}

function Get-GitHubLatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $uri     = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    $headers = @{
        'User-Agent' = "SpicetifyManagerPro/$($Script:ScriptVersion)"
        'Accept'     = 'application/vnd.github+json'
    }

    try {
        $response = Invoke-WithRetry -Label 'GitHub API request' -Action {
            Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers $headers -ErrorAction Stop -TimeoutSec 30
        }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        $ex = $_.Exception
        $statusCode = 0
        if ($null -ne $ex -and $null -ne $ex.Response) {
            try { $statusCode = [int]$ex.Response.StatusCode } catch {}
        }

        if ($statusCode -eq 403 -or $ex.Message -match '\(403\)') {
            $resetEpoch = $null
            try { $resetEpoch = $ex.Response.Headers['X-RateLimit-Reset'] } catch {}
            $resetLong = 0
            if ($resetEpoch -and [long]::TryParse("$resetEpoch", [ref]$resetLong)) {
                $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetLong).LocalDateTime
                $waitMinutes = [Math]::Ceiling(([DateTimeOffset]$resetTime - [DateTimeOffset]::Now).TotalMinutes)
                $waitMinutes = [Math]::Max(1, $waitMinutes)
                throw "GitHub API rate limit exceeded. Resets at $resetTime (~$waitMinutes min). Please wait and run again."
            }
            throw 'GitHub API rate limit exceeded (60 requests/hour unauthenticated). Please wait an hour and run again.'
        }
        if ($statusCode -eq 404) {
            throw "GitHub repository not found: $Owner/$Repo. The project may have moved."
        }
        throw "Failed to fetch release info from $Owner/$Repo`: $($_.Exception.Message)"
    }
}

function Invoke-ExternalCommand {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The stream-drain and kill catch blocks are deliberate: partial output beats a hard failure, and a process may legitimately exit between the liveness check and the kill.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMs
    )

    if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $TimeoutMs = $Script:Config.ProcessTimeoutMs
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    } catch {}

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [PSCustomObject]@{
            ExitCode = -1
            Stdout   = ''
            Stderr   = "Failed to start process: $($_.Exception.Message)"
            TimedOut = $false
        }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $false
    try {
        $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($process.WaitForExit(500)) { $exited = $true; break }
            Assert-NotCancelled
            if ($waitSw.ElapsedMilliseconds -ge $TimeoutMs) { break }
        }
    } catch {
        try {
            $process.Kill()
            $null = $process.WaitForExit(5000)
        } catch {

        }
        throw
    }

    if (-not $exited) {
        try {
            $process.Kill()

            $null = $process.WaitForExit(5000)
        } catch {}
        $stdout = ''
        $stderr = ''
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}
        return [PSCustomObject]@{
            ExitCode = -1
            Stdout   = $stdout
            Stderr   = $stderr
            TimedOut = $true
        }
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
    try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        TimedOut = $false
    }
}

function Invoke-SpicetifyCli {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)

    $exe = $Script:Config.SpicetifyExePath
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Spicetify executable not found at: $exe"
    }

    $result = Invoke-ExternalCommand -FilePath $exe -Arguments "--bypass-admin $Command"

    if ($result.TimedOut) {
        throw "Spicetify command timed out: $Command"
    }

    return $result
}

function Copy-ItemSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Recurse,

        [switch]$AllowWildcard
    )

    if ($AllowWildcard) {
        if (-not (Test-Path -Path $Source)) {
            Write-Log -Message "Source does not exist, skipping copy: $Source" -Level DEBUG
            return
        }
    } elseif (-not (Test-Path -LiteralPath $Source)) {
        Write-Log -Message "Source does not exist, skipping copy: $Source" -Level DEBUG
        return
    }

    Invoke-WithRetry -Label "Copy $Source -> $Destination" -Action {
        $params = @{
            Destination = $Destination
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($Recurse) { $params.Recurse = $true }
        if ($AllowWildcard) {
            $params.Path = $Source
        } else {
            $params.LiteralPath = $Source
        }
        Copy-Item @params
    }
}

function Test-ZipIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $archive = $null
    $stream  = $null
    $buffer  = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $buffer  = [byte[]]::new(8192)
        foreach ($entry in $archive.Entries) {
            $stream = $entry.Open()

            $read = [long]0
            while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $read += $n }
            $stream.Dispose()
            $stream = $null
            if ($read -ne $entry.Length) {
                throw "Entry '$($entry.FullName)': read $read bytes, directory says $($entry.Length) -- archive is corrupt."
            }
        }
        return $true
    } catch {
        Write-Log -Message "ZIP integrity check failed for $Path`: $($_.Exception.Message)" -Level ERROR
        return $false
    } finally {
        if ($null -ne $stream)  { $stream.Dispose() }
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Test-ZipEntryPaths {

    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            $normalized = $name -replace '\\', '/'
            if ($normalized -match '^[a-zA-Z]:/') { return $false }
            if ($normalized.StartsWith('/')) { return $false }
            $segments = $normalized -split '/'
            foreach ($seg in $segments) {
                if ($seg -eq '..') { return $false }
                if ($seg -match ':') { return $false }
            }
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Wait-ForFileRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    for ($i = 0; $i -lt $Script:Config.FileLockRetries; $i++) {
        Assert-NotCancelled
        try {
            $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
            $stream.Dispose()
            return
        } catch {
            Write-Log -Message "File locked, waiting ($($i + 1)/$($Script:Config.FileLockRetries)): $Path" -Level DEBUG
            Start-Sleep -Milliseconds $Script:Config.FileLockDelayMs
        }
    }
    Write-Log -Message "File still locked after $($Script:Config.FileLockRetries) attempts: $Path. Proceeding." -Level WARN
}

function Wait-ForSpotifyRelease {
    [CmdletBinding()]
    param()

    $spotifyDir = $Script:Config.SpotifyInstallDir
    if (-not (Test-Path -LiteralPath $spotifyDir)) { return }

    $xpuiPath = Join-Path $spotifyDir 'apps\xpui.spa'
    if (Test-Path -LiteralPath $xpuiPath) {
        Wait-ForFileRelease -Path $xpuiPath
        return
    }

    $xpuiFile = Get-ChildItem -Path $spotifyDir -Filter 'xpui.spa' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($xpuiFile) {
        Wait-ForFileRelease -Path $xpuiFile.FullName
    } elseif (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {
        Wait-ForFileRelease -Path $Script:Config.SpotifyExePath
    }
}

function Get-FreeDiskSpaceMB {
    param([string]$Path)

    try {
        $drive = [System.IO.Path]::GetPathRoot((Resolve-Path -Path $Path -ErrorAction Stop).Path)
        $driveInfo = [System.IO.DriveInfo]::new($drive)
        if (-not $driveInfo.IsReady) { return -1 }
        return [int]([Math]::Floor($driveInfo.AvailableFreeSpace / 1MB))
    } catch {
        return -1
    }
}

function Get-DownloadGlobalPercent {
    param(
        [int]$Read,
        [int]$Total,
        [int]$Base,
        [int]$Weight
    )
    if ($Total -le 0) { return -1 }
    if ($Total -lt $Read) { $Read = $Total }
    $dlPct = [int]([Math]::Floor(($Read * 100.0) / $Total))
    if ($dlPct -gt 100) { $dlPct = 100 }
    if ($dlPct -lt 0)   { $dlPct = 0 }
    $global = $Base + [int]([Math]::Floor(($dlPct / 100.0) * $Weight))
    if ($global -gt ($Base + $Weight)) { $global = $Base + $Weight }
    if ($global -lt $Base)              { $global = $Base }
    return $global
}

function Invoke-DownloadWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Downloading',
        [int]$BasePercent = 0,
        [int]$Weight = 10,
        [int]$TimeoutMs = 0
    )

    $outDir = Split-Path $OutFile -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    $request  = $null
    $response = $null
    $inStream  = $null
    $outStream = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.UserAgent = "SpicetifyManagerPro/$($Script:ScriptVersion)"
        $request.AllowAutoRedirect = $true
        $request.ReadWriteTimeout = 30000
        if ($TimeoutMs -gt 0) {
            $request.Timeout = $TimeoutMs
            if ($TimeoutMs -lt 30000) { $request.ReadWriteTimeout = $TimeoutMs }
        }

        $response = $request.GetResponse()
        $total = $response.ContentLength
        $inStream  = $response.GetResponseStream()
        $outStream = [System.IO.File]::Create($OutFile)

        $buffer    = New-Object byte[] 65536
        $read      = 0
        $lastDlPct = -1

        while ($true) {
            Assert-NotCancelled
            $n = $inStream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $outStream.Write($buffer, 0, $n)
            $read += $n

            if ($total -gt 0) {
                $dlPct = [int]([Math]::Floor(($read * 100.0) / $total))
                if ($dlPct -gt 100) { $dlPct = 100 }
                if ($dlPct -ne $lastDlPct) {
                    $globalPct = Get-DownloadGlobalPercent -Read $read -Total $total -Base $BasePercent -Weight $Weight
                    Set-Progress -Phase $Label -Detail "$Label $dlPct%" -Percent $globalPct
                    $lastDlPct = $dlPct
                }
            } else {

                Set-Progress -Phase $Label -Detail $Label -IsIndeterminate
            }
        }
        $outStream.Flush()

        if ($total -gt 0 -and $read -lt $total) {
            throw "Download truncated: got $read of $total bytes"
        }
    } catch {
        if ($outStream) { try { $outStream.Dispose() } catch {} ; $outStream = $null }
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
        if ($response)  { $response.Dispose() }
    }
}

function Get-IniValue {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $Default }

    $inSection = $false
    foreach ($line in [System.IO.File]::ReadAllLines($FilePath, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -match '^\s*\[') {
            $inSection = ($line -match "^\s*\[$([regex]::Escape($Section))\]\s*$")
            continue
        }
        if ($inSection -and $line -notmatch '^\s*[;#]' -and
            $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return $Default
}

function Set-IniValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $dir = Split-Path $FilePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($FilePath, [System.Text.UTF8Encoding]::new($false))) {
        $lines.Add($line)
    }

    $sectionIndex = -1
    $keyIndex     = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*\[$([regex]::Escape($Section))\]\s*$") {
            $sectionIndex = $i
            break
        }
    }

    if ($sectionIndex -ge 0) {
        $nextSection = $lines.Count
        for ($j = $sectionIndex + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^\s*\[') {
                $nextSection = $j
                break
            }
            if ($lines[$j] -notmatch '^\s*[;#]' -and
                $lines[$j] -match "^\s*$([regex]::Escape($Key))\s*=") {
                $keyIndex = $j
                break
            }
        }

        if ($keyIndex -ge 0) {
            $lines[$keyIndex] = "${Key}=${Value}"
        } else {
            $lines.Insert($nextSection, "${Key}=${Value}")
        }
    } else {
        $lines.Add("[$Section]")
        $lines.Add("${Key}=${Value}")
    }

    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    Set-ContentAtomic -Path $FilePath -Value $content -NoBom
}

function Resolve-SpicetifyConfigPaths {
    [CmdletBinding()]
    param()

    $iniPath = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) { return }

    $lines = [System.IO.File]::ReadAllLines($iniPath, [System.Text.UTF8Encoding]::new($false))

    foreach ($line in $lines) {
        if ($line -match '^\s*spotify_path\s*=\s*(.+)$') {
            $candidate = $Matches[1].Trim()

            try {

                if (-not [System.IO.Path]::IsPathRooted($candidate)) {
                    Write-Log -Message "Ignoring relative spotify_path from INI: '$candidate' (a full path is required)." -Level WARN
                } else {
                    $resolved = Join-Path $candidate 'Spotify.exe'
                    if (Test-Path -LiteralPath $resolved) {
                        $Script:Config.SpotifyExePath    = $resolved
                        $Script:Config.SpotifyInstallDir = $candidate
                        Write-Log -Message "Resolved Spotify path from INI: $($Script:Config.SpotifyExePath)" -Level DEBUG
                    }
                }
            } catch {
                Write-Log -Message "Ignoring malformed spotify_path from INI: '$candidate'" -Level WARN
            }
        }
        elseif ($line -match '^\s*backup_dir\s*=\s*(.+)$') {
            $candidate = $Matches[1].Trim()

            $safe = $false
            $full = $null
            try {
                if ([System.IO.Path]::IsPathRooted($candidate)) {
                    $full = [System.IO.Path]::GetFullPath($candidate)
                    $fullNorm = $full.TrimEnd('\').TrimEnd('/')
                    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\').TrimEnd('/')
                    $isRoot = ($fullNorm -ieq $root)

                    $blockChildren = @(
                        [Environment]::GetEnvironmentVariable('SystemRoot'),
                        [Environment]::GetEnvironmentVariable('ProgramFiles'),
                        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
                        [Environment]::GetEnvironmentVariable('ProgramW6432'),
                        [Environment]::GetEnvironmentVariable('ProgramData')
                    )
                    $blockExact = @($blockChildren)
                    foreach ($envName in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')) {
                        $v = [Environment]::GetEnvironmentVariable($envName)
                        if ($v) { $blockExact += $v }
                    }
                    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
                    if ($userProfile) {
                        foreach ($known in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')) {
                            $blockExact += (Join-Path $userProfile $known)
                        }
                        $usersRoot = Split-Path $userProfile -Parent
                        if ($usersRoot) { $blockExact += $usersRoot }
                    }

                    $isProtected = $false
                    foreach ($protected in $blockChildren) {
                        if ($protected) {

                            $prot = $protected.TrimEnd('\').TrimEnd('/')
                            if ($fullNorm -ieq $prot -or
                                $fullNorm.StartsWith($prot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                                $fullNorm.StartsWith($prot + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                                $isProtected = $true
                            }
                        }
                    }
                    if (-not $isProtected) {
                        foreach ($protected in $blockExact) {
                            if ($protected) {
                                $prot = $protected.TrimEnd('\').TrimEnd('/')
                                if ($fullNorm -ieq $prot) { $isProtected = $true; break }
                            }
                        }
                    }

                    if ((Test-Path -LiteralPath $full -PathType Container) -and -not $isRoot -and -not $isProtected) {
                        $safe = $true
                    }
                }
            } catch {

            }
            if ($safe -and $full) {

                $Script:Config.BackupDir = $full
                Write-Log -Message "Resolved backup_dir from INI: $($Script:Config.BackupDir)" -Level DEBUG
            } else {
                Write-Log -Message "Ignoring unsafe backup_dir from INI: '$candidate' (must be an existing directory, not a drive root, not a system or profile root location). Keeping: $($Script:Config.BackupDir)" -Level WARN
            }
        }
    }
}

function Test-NetworkOk {
    [CmdletBinding()]
    param()

    $endpoints = @(
        @{ Name = 'GitHub API';      Url = 'https://api.github.com' }
        @{ Name = 'GitHub download'; Url = 'https://github.com' }
        @{ Name = 'Spotify CDN';     Url = 'https://download.scdn.co' }
    )

    $failed = @()
    foreach ($ep in $endpoints) {
        Assert-NotCancelled
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Log -Message "Preflight: $($ep.Name) reachable (HTTP $($resp.StatusCode))" -Level DEBUG
        } catch {
            $code = 0
            if ($null -ne $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($code -ge 400 -and $code -lt 500 -and $code -ne 408 -and $code -ne 429) {
                Write-Log -Message "Preflight: $($ep.Name) reachable (HTTP $code)" -Level DEBUG
            } else {
                Write-Log -Message "Preflight: $($ep.Name) unreachable: $($_.Exception.Message)" -Level WARN
                $failed += $ep.Name
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Log -Message "Network unreachable for: $($failed -join ', ')" -Level ERROR
        return $false
    }
    return $true
}

function Test-InstallerSignature {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    if ($sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Spotify installer signature is NOT valid ($($sig.Status)). The download may be corrupted or tampered with. Refusing to run it."
    }
    $subject = if ($null -ne $sig.SignerCertificate) { "$($sig.SignerCertificate.Subject)" } else { '' }

    if ($subject -notmatch '(^|,)\s*(CN|O)\s*=\s*"?Spotify AB"?\s*(,|$)') {
        throw "Spotify installer is signed by an unexpected publisher: $subject"
    }
    Write-Log -Message "Installer signature verified: $subject" -Level INFO
    return $true
}

function Test-ArchitectureSupported {
    [CmdletBinding()]
    param()

    $ok = $true
    $warning = $null

    if (-not [Environment]::Is64BitOperatingSystem) {
        $ok = $false
        $warning = '32-bit Windows detected. Spicetify ships x64-only binaries and is not supported on this architecture.'
        $arch = 'x86 OS'
    } else {
        $arch = $env:PROCESSOR_ARCHITECTURE
        if (-not $arch) { $arch = [System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
        if ($arch -eq 'ARM64') {
            $ok = $true
            $warning = 'ARM64 detected. Spicetify x64 binary will run via Windows emulation -- functionally supported but slower than native.'
        } elseif ($arch -eq 'x86') {
            $ok = $true
            $warning = 'Running 32-bit PowerShell on 64-bit Windows -- supported, but a 64-bit shell is recommended.'
        }
    }

    return [PSCustomObject]@{
        Ok      = $ok
        Arch    = $arch
        Warning = $warning
    }
}

function ConvertTo-SpotifyVersion {

    [CmdletBinding()]
    param([string]$Version)

    if (-not $Version) { return $null }
    if ("$Version" -notmatch '^(\d{1,5})\.(\d{1,5})\.(\d{1,5})(?:\.(\d{1,5}))?') { return $null }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $build = [int]$Matches[3]
    $rev   = 0
    if ($Matches[4]) { $rev = [int]$Matches[4] }
    try {
        return [version]("{0}.{1}.{2}.{3}" -f $major, $minor, $build, $rev)
    } catch {
        return $null
    }
}

function Get-SpotifyCatalogArch {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The registry/native-env probes are best-effort: on failure the function deliberately falls through to the process-level environment variable and the bitness check below.')]
    [CmdletBinding()]
    param()

    $native = ''
    try {
        $native = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch {
        $native = ''
    }
    if (-not $native) { $native = "$env:PROCESSOR_ARCHITECTURE" }
    if ($native -eq 'ARM64') { return 'arm64' }
    if ($native -eq 'x86')   { return 'x86' }
    try {
        if (-not [Environment]::Is64BitOperatingSystem) { return 'x86' }
    } catch {

    }
    return 'x64'
}

function Get-HostOsMajor {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The registry and OSVersion probes are best-effort by design: on failure the function deliberately falls through to the next source / the default major 10.')]
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') { return 10 }
    try {
        $buildNumber = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction Stop).CurrentBuildNumber
        $build = 0
        if ([int]::TryParse($buildNumber, [ref]$build) -and $build -ge 10240) {
            return 10
        }
    } catch { }
    try {
        return [int][Environment]::OSVersion.Version.Major
    } catch {
        return 10
    }
}

function Get-SpotifyVersionCatalog {
    [CmdletBinding()]
    param(
        [switch]$Online,
        [string]$RawJson
    )

    if ($null -ne $Script:VersionCatalogCache -and -not $Online) {
        return , $Script:VersionCatalogCache
    }

    if ($PSBoundParameters.ContainsKey('RawJson')) {
        $jsonText = "$RawJson"
        if ([string]::IsNullOrWhiteSpace($jsonText)) { throw 'The catalog payload was empty.' }
    } else {
        try {
            $resp = Invoke-WithRetry -Label 'Fetch online version catalog' -Action {
                Invoke-WebRequest -Uri $Script:SpotifyCatalogManifestUrl -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            }
            $jsonText = $resp.Content
        } catch {
            Write-Log -Message "Online catalog unavailable: $($_.Exception.Message)" -Level WARN
            throw
        }
    }
    $live = $null
    try {
        $live = $jsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The online catalog is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $live) {
        throw 'The online catalog is not valid JSON: the payload parsed to null.'
    }
    $allowedHosts = @('loadspot.amd64fox1.workers.dev', 'download.scdn.co')
    $byShort = @{}
    $adopted = 0
    $skipped = 0
    foreach ($p in $live.PSObject.Properties) {
        $short = ''
        try {
            $short = ([string]$p.Name).Trim()
            $v   = $p.Value
            $winProp = $v.PSObject.Properties['win']
            $win = if ($null -ne $winProp) { $winProp.Value } else { $null }
            if ($null -eq $win) { continue }
            if ($short -notmatch '^\d{1,5}(\.\d{1,5}){2,3}$') { throw 'not a Spotify version key' }
            $fullProp = $v.PSObject.Properties['fullversion']
            $full = if ($null -ne $fullProp) { (([string]$fullProp.Value).Trim() -replace "[`r`n]", '') } else { '' }
            if ($full -notmatch '^\d{1,5}(\.\d{1,5}){2,3}(\.[A-Za-z0-9]+)?$') { throw 'malformed fullversion' }
            $fields = @{
                Short = $short
                Full  = $full
                Date  = ''
            }
            foreach ($arch in @('x64', 'x86', 'arm64')) {
                $keyArch = if ($arch -eq 'arm64') { 'Arm64' } else { $arch.ToUpper() }
                $a    = $win.PSObject.Properties[$arch]
                $size = [long]0
                $url  = ''
                if ($null -ne $a -and $null -ne $a.Value) {
                    $sizeProp = $a.Value.PSObject.Properties['size']
                    $urlProp  = $a.Value.PSObject.Properties['url']
                    if ($null -eq $sizeProp -or $null -eq $urlProp) { throw "missing $arch size/url" }
                    $size = [long]$sizeProp.Value
                    $url  = (([string]$urlProp.Value).Trim() -replace "[`r`n]", '')
                    $dateProp = $a.Value.PSObject.Properties['date']
                    if ($null -ne $dateProp -and $fields['Date'] -eq '') {
                        $fields['Date'] = (([string]$dateProp.Value).Trim() -replace "[`r`n]", '')
                    }
                }
                if ($size -gt 0) {
                    if ($url -notmatch '^https://') { throw "non-HTTPS $arch url" }
                    $hostOk = $false
                    try {
                        $urlParsed = [Uri]$url
                        $hostOk = (($allowedHosts -contains $urlParsed.Host) -and
                            ($urlParsed.Port -eq 443) -and
                            ([string]::IsNullOrEmpty($urlParsed.UserInfo)))
                    } catch { $hostOk = $false }
                    if (-not $hostOk) { throw "$arch url is not an allowed https host on port 443 without credentials" }
                }
                $fields["Size$keyArch"] = $size
                $fields["Url$keyArch"]  = $url
            }
            if ($fields['SizeX64'] -le 0 -and $fields['SizeX86'] -le 0 -and $fields['SizeArm64'] -le 0) {
                throw 'no usable Windows build'
            }
            $byShort[$short] = [PSCustomObject]$fields
            $adopted++
        } catch {
            $skipped++
            Write-Log -Message "Skipped malformed catalog entry '$short': $($_.Exception.Message)" -Level WARN
        }
    }
    if ($byShort.Count -eq 0) {
        throw 'The online catalog contains no usable Windows entries.'
    }
    Write-Log -Message "Online catalog loaded: $adopted adopted, $skipped skipped, $($byShort.Count) total." -Level INFO

    $sorted = @($byShort.Values | Sort-Object -Property @{ Expression = {
        $v = ConvertTo-SpotifyVersion -Version $_.Short
        if ($null -eq $v) { [version]'0.0.0.0' } else { $v }
    }} -Descending)
    $Script:VersionCatalogCache = $sorted
    return , $sorted
}

function Get-SpotifyCatalogEntry {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)

    $want = "$Version".Trim()
    if ($want -eq '') { return $null }
    $catalog = Get-SpotifyVersionCatalog
    foreach ($e in $catalog) {
        if ($e.Short -eq $want) { return $e }
    }
    foreach ($e in $catalog) {
        if ($e.Full -eq $want) { return $e }
    }
    return $null
}

function Get-SpotifyDownloadInfo {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$Arch
    )
    if (-not $Arch) { $Arch = Get-SpotifyCatalogArch }
    $sizeProp = 'Size' + $Arch
    $urlProp  = 'Url' + $Arch

    $urlEntry  = $Entry.PSObject.Properties[$urlProp]
    $sizeEntry = $Entry.PSObject.Properties[$sizeProp]
    $url  = if ($null -ne $urlEntry)  { [string]$urlEntry.Value }  else { '' }
    $size = if ($null -ne $sizeEntry) { try { [long]$sizeEntry.Value } catch { [long]0 } } else { [long]0 }
    return [PSCustomObject]@{
        Url          = $url
        ExpectedSize = $size
        Arch         = $Arch
    }
}

function Test-SpotifyVersionOffered {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$Arch
    )
    if (-not $Arch) { $Arch = Get-SpotifyCatalogArch }
    $info = Get-SpotifyDownloadInfo -Entry $Entry -Arch $Arch
    if ($info.ExpectedSize -le 0) { return $false }

    $target = ConvertTo-SpotifyVersion -Version $Entry.Short
    if ($null -eq $target) { return $false }

    $osMajor = Get-HostOsMajor
    if ($osMajor -lt 10) {

        $win7Max = ConvertTo-SpotifyVersion -Version '1.2.5.1006'
        if ($target -gt $win7Max) { return $false }
    }
    return $true
}

function Get-SpotifyVersionAdvisories {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$InstalledVersion,

        [string]$Arch
    )

    $warnings  = New-Object System.Collections.Generic.List[string]
    $hardBlock = $null
    $target = ConvertTo-SpotifyVersion -Version $Entry.Short
    if ($null -eq $target) {
        return [PSCustomObject]@{ HardBlock = 'Version string could not be parsed.'; Warnings = @() }
    }

    if (-not $Arch) { $arch = Get-SpotifyCatalogArch } else { $arch = $Arch }
    $info = Get-SpotifyDownloadInfo -Entry $Entry -Arch $arch
    if ($info.ExpectedSize -le 0) {
        $hardBlock = "No native $arch build exists for $($Entry.Short). Choose a different version."
    }

    if ((Get-HostOsMajor) -lt 10) {
        $win7Max = ConvertTo-SpotifyVersion -Version '1.2.5.1006'
        if ($target -gt $win7Max -and -not $hardBlock) {
            $hardBlock = 'Windows 7/8.1 cannot run Spotify versions newer than 1.2.5.1006.'
        }
    }

    $loginMin = ConvertTo-SpotifyVersion -Version '1.1.87.612'
    $loginMax = ConvertTo-SpotifyVersion -Version '1.2.5.1006'
    if ($null -ne $loginMin -and $null -ne $loginMax -and
        $target -ge $loginMin -and $target -le $loginMax -and -not $hardBlock) {
        $hardBlock = 'Login is broken on Spotify 1.1.87.612 - 1.2.5.1006 (Spotify server-side change). You would likely be unable to sign in on this version.'
    }

    if ($InstalledVersion) {
        $cur = ConvertTo-SpotifyVersion -Version $InstalledVersion
        if ($null -ne $cur) {
            if ($cur -eq $target) {
                $warnings.Add('This is the currently installed version (reinstall/repair).')
            } elseif ($target -lt $cur) {
                $warnings.Add("This is a DOWNGRADE from $InstalledVersion.")
            } else {
                $warnings.Add("This is an upgrade/roll-forward from $InstalledVersion.")
            }
        }
    }
    $oldFloor = ConvertTo-SpotifyVersion -Version '1.1.87.0'
    if ($null -ne $oldFloor -and $target -lt $oldFloor) {
        $warnings.Add('Very old version: Spicetify support is unlikely and the client may misbehave.')
    }
    $warnings.Add('Spicetify will recreate its backup and reapply your configuration after the swap.')

    return [PSCustomObject]@{
        HardBlock = $hardBlock
        Warnings  = $warnings.ToArray()
    }
}

function Test-PathDenyAcl {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
                return $true
            }
        }
    } catch {
        Write-Log -Message "Could not read ACL of $Path : $($_.Exception.Message)" -Level WARN
    }
    return $false
}

function Set-DenyWriteAcl {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The verification re-read is best-effort: the throw right below it decides the outcome when the deny rules could not be confirmed removed.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Remove,
        [switch]$IsFile
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ACL target does not exist: $Path"
    }
    if (-not $PSCmdlet.ShouldProcess($Path, $(if ($Remove) { 'Remove deny ACE' } else { 'Apply deny ACE' }))) {
        return $false
    }
    $acl = Get-Acl -LiteralPath $Path

    $denyRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
                   [System.Security.AccessControl.FileSystemRights]::AppendData -bor
                   [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
                   [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
                   [System.Security.AccessControl.FileSystemRights]::Delete -bor
                   [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles

    if ($Remove) {

        $changed = $false
        $failed  = $false
        $foreign = 0
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Deny) { continue }
            $isOurs = $false
            try {
                $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                $isOurs = ($sid.Value -eq 'S-1-1-0') -and
                    (([int64]$rule.FileSystemRights -band [int64]$denyRights) -eq [int64]$rule.FileSystemRights)
            } catch { $isOurs = $false }
            if (-not $isOurs) {
                $foreign++
                continue
            }
            if ($acl.RemoveAccessRule($rule)) {
                $changed = $true
            } else {
                $failed = $true
            }
        }
        if ($changed -or $failed) {
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        }

        $remaining = 0
        try {
            $check = Get-Acl -LiteralPath $Path
            foreach ($r in @($check.Access)) {
                if ($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Deny) { continue }
                $ours = $false
                try {
                    $rsid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                    $ours = ($rsid.Value -eq 'S-1-1-0') -and
                        (([int64]$r.FileSystemRights -band [int64]$denyRights) -eq [int64]$r.FileSystemRights)
                } catch { $ours = $false }
                if ($ours) { $remaining++ }
            }
        } catch { }
        if ($foreign -gt 0) {
            Write-Log -Message "Left $foreign foreign deny rule(s) untouched on $Path (not created by this tool)." -Level INFO
        }
        if ($remaining -gt 0 -or $failed) {
            throw "The deny rules on $Path could not be fully removed ($remaining of ours remain; they may be inherited from a parent folder). Remove them on the parent path, or run: icacls `"$Path`" /remove:d Everyone"
        }
        return $changed
    }

    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    if ($IsFile) {
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
        $denyRights,
        $inherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
    return $true
}

function Get-SpotifyUpdateGuardScope {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Config access is best-effort here: the block-state probe may run before the Spotify paths are resolved, in which case the guard falls back to the default per-user Spotify locations.')]
    [CmdletBinding()]
    param()

    $localDir   = Join-Path $env:LOCALAPPDATA 'Spotify'
    $roamingDir = Join-Path $env:APPDATA 'Spotify'
    $installDir = ''
    try {
        if ($null -ne $Script:Config -and $Script:Config.SpotifyInstallDir) {
            $installDir = "$($Script:Config.SpotifyInstallDir)"
        } elseif ($null -ne $Script:Config -and $Script:Config.SpotifyExePath) {
            $installDir = Split-Path -Parent "$($Script:Config.SpotifyExePath)"
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($installDir)) { $installDir = $roamingDir }

    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($installDir, $localDir, $roamingDir)) {
        $full = "$d"
        try { $full = [System.IO.Path]::GetFullPath($d) } catch { }
        while ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.Substring(0, $full.Length - 1) }
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        $dup = $false
        foreach ($e in $dirs) { if ($e -ieq $full) { $dup = $true; break } }
        if (-not $dup) { $dirs.Add($full) }
    }

    $resolvedInstall = if ($dirs.Count -gt 0) { $dirs[0] } else { $roamingDir }
    return [PSCustomObject]@{
        InstallDir = $resolvedInstall
        LocalDir   = $localDir
        RoamingDir = $roamingDir
        Dirs       = $dirs
    }
}

function Get-SpotifyUpdateBlockState {

    [CmdletBinding()]
    param()

    $paths = Get-SpotifyUpdateGuardScope

    $guarded = @()
    $pending = @()
    $seen    = @{}
    foreach ($dir in @($paths.Dirs)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in @('Spotify_new.exe', 'Spotify_new.exe.sig')) {
            $f = Join-Path $dir $name
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $key = $f.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-PathDenyAcl -Path $f) { $guarded += $f } else { $pending += $f }
        }
    }

    $denyLocal   = Test-PathDenyAcl -Path (Join-Path $paths.LocalDir 'Update')
    $denyRoaming = Test-PathDenyAcl -Path (Join-Path $paths.RoamingDir 'Update')
    $denyInstall = Test-PathDenyAcl -Path (Join-Path $paths.InstallDir 'Update')

    return [PSCustomObject]@{
        Blocked                = ($denyLocal -or $denyRoaming -or $denyInstall -or $guarded.Count -gt 0)
        DenyOnUpdateDir        = $denyLocal
        DenyOnRoamingUpdateDir = $denyRoaming
        DenyOnInstallUpdateDir = $denyInstall
        InstallDir             = $paths.InstallDir
        GuardedFiles           = $guarded
        PendingUpdateFiles     = $pending
    }
}

function Set-SpotifyUpdateBlock {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Force)

    Write-Step -Message 'Blocking Spotify automatic updates...' -Type STEP

    if (-not $Force) {
        if (Test-MicrosoftStoreSpotify) {
            throw 'The Microsoft Store Spotify was detected. Store updates are managed by Windows itself and cannot be blocked this way. Install the desktop (per-user) Spotify first if you want version control.'
        }

        $state = Get-SpotifyUpdateBlockState
        if ($state.Blocked) {
            Write-Step -Message 'Spotify updates are already blocked.' -Type WARN
            return $state
        }

        if (-not $PSCmdlet.ShouldProcess('Spotify update staging paths', 'Apply deny ACL')) {
            return $state
        }

        if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
            throw "Per-user Spotify was not found at $($Script:Config.SpotifyExePath). Install Spotify first -- the update block targets the per-user desktop client."
        }
    }

    $paths = Get-SpotifyUpdateGuardScope

    foreach ($dir in @($paths.Dirs)) {
        foreach ($name in @('Spotify_new.exe', 'Spotify_new.exe.sig')) {
            $p = Join-Path $dir $name
            if (Test-Path -LiteralPath $p) {
                try {
                    if (Test-PathDenyAcl -Path $p) {
                        $null = Set-DenyWriteAcl -Path $p -Remove -IsFile
                    }
                    Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                    Write-Log -Message "Discarded pending update file: $p" -Level INFO
                } catch {
                    Write-Step -Message "  Could not discard pending update file $p -- it may still apply on the next launch: $($_.Exception.Message)" -Type WARN
                }
            }
        }
    }

    foreach ($dir in @($paths.Dirs)) {
        $updateDir = Join-Path $dir 'Update'
        if (-not (Test-Path -LiteralPath $updateDir)) {
            New-Item -ItemType Directory -Force -Path $updateDir | Out-Null
        }
        $null = Set-DenyWriteAcl -Path $updateDir
        Write-Log -Message "Deny ACL applied to $updateDir" -Level INFO
    }

    foreach ($dir in @($paths.Dirs)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in @('Spotify_new.exe', 'Spotify_new.exe.sig')) {
            $p = Join-Path $dir $name
            if (-not (Test-Path -LiteralPath $p)) {
                [System.IO.File]::WriteAllText($p, '')
                $null = Set-DenyWriteAcl -Path $p -IsFile
                Write-Log -Message "Guard file created: $p" -Level INFO
            }
        }
    }

    Write-Step -Message 'Spotify updates blocked (deny ACLs on the update staging paths in the install and local folders).' -Type OK
    Write-Log -Message 'The block is user-scope and reversible at any time (-UnblockUpdates / the GUI toggle). No admin rights are involved.' -Level INFO
    return (Get-SpotifyUpdateBlockState)
}

function Remove-SpotifyUpdateBlock {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Unblocking Spotify updates...' -Type STEP

    $state = Get-SpotifyUpdateBlockState
    if (-not $state.Blocked) {
        Write-Step -Message 'Spotify updates are not blocked.' -Type INFO
        return $state
    }

    if (-not $PSCmdlet.ShouldProcess('Spotify update staging paths', 'Remove deny ACL')) {
        return $state
    }

    $paths = Get-SpotifyUpdateGuardScope

    $unlockDirs = @()
    if ($state.DenyOnUpdateDir)        { $unlockDirs += (Join-Path $paths.LocalDir 'Update') }
    if ($state.DenyOnRoamingUpdateDir) { $unlockDirs += (Join-Path $paths.RoamingDir 'Update') }
    if ($state.DenyOnInstallUpdateDir) { $unlockDirs += (Join-Path $paths.InstallDir 'Update') }

    $anyFailed = $false
    $handled   = @{}
    foreach ($dir in $unlockDirs) {
        $key = $dir.ToLowerInvariant()
        if ($handled.ContainsKey($key)) { continue }
        $handled[$key] = $true
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        try {
            $null = Set-DenyWriteAcl -Path $dir -Remove
            Write-Log -Message "Deny rules removed from $dir" -Level INFO
        } catch {
            $anyFailed = $true
            Write-Step -Message "  Could not unlock $dir : $($_.Exception.Message)" -Type WARN
        }
    }

    foreach ($guard in @($state.GuardedFiles)) {
        if (-not (Test-Path -LiteralPath $guard)) { continue }
        try {
            $null = Set-DenyWriteAcl -Path $guard -Remove -IsFile
            Remove-Item -LiteralPath $guard -Force -ErrorAction Stop
            Write-Log -Message "Guard file removed: $guard" -Level INFO
        } catch {
            $anyFailed = $true
            Write-Step -Message "  Could not remove guard file $guard -- delete it manually (or run: icacls `"$guard`" /remove:d Everyone)" -Type WARN
        }
    }

    if ($anyFailed) {
        throw 'Some block elements could not be removed -- see the warnings above.'
    }
    Write-Step -Message 'Spotify updates unblocked.' -Type OK
    return (Get-SpotifyUpdateBlockState)
}

function Get-InstalledSpotifyFileVersion {

    [CmdletBinding()]
    param()

    $exe = $Script:Config.SpotifyExePath
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    try {
        $v = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
        if ("$v" -eq '') { return $null }

        return ("$v" -replace ',', '.')
    } catch {
        return $null
    }
}

function Get-PinnedSpotifyVersion {

    [CmdletBinding()]
    param()

    $v = Get-Variable -Name 'PinnedSpotifyVersion' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v -and $v.Value) { return [string]$v.Value }
    return ''
}

function Invoke-SpotifyInstallerDownload {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$Arch,
        [int]$BasePercent = 20,
        [int]$Weight = 35
    )
    if (-not $Arch) { $Arch = Get-SpotifyCatalogArch }

    $info = Get-SpotifyDownloadInfo -Entry $Entry -Arch $Arch
    if ($info.ExpectedSize -le 0) {
        throw "No $Arch installer exists for $($Entry.Full)."
    }

    if (-not $PSCmdlet.ShouldProcess("Spotify $($Entry.Short) installer ($Arch)", 'Download and verify')) {
        Write-Log -Message '[WhatIf] Installer download skipped.' -Level INFO
        return ''
    }

    $installerPath = Join-Path (Get-TempDir) ("SpotifySetup_{0}_{1}.exe" -f ($Entry.Short -replace '\.', '_'), (New-Guid).ToString('N').Substring(0, 8))
    $null = $Script:TempFiles.Add($installerPath)

    Write-Step -Message "  Downloading Spotify $($Entry.Short) ($Arch, $([Math]::Round($info.ExpectedSize / 1MB, 1)) MB)..." -Type STEP

    Invoke-WithRetry -Label "Download Spotify $($Entry.Full)" -Action {
        Invoke-DownloadWithProgress `
            -Uri $info.Url `
            -OutFile $installerPath `
            -Label "Downloading Spotify $($Entry.Short)" `
            -BasePercent $BasePercent -Weight $Weight `
            -TimeoutMs 600000
        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw 'Installer download failed -- file not created.'
        }
        $size = (Get-Item -LiteralPath $installerPath).Length
        if ($size -ne $info.ExpectedSize) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded installer size mismatch: got $size bytes, the catalog expects $($info.ExpectedSize). The download may be corrupted -- retrying."
        }
        if ($size -lt 1024) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            throw "Installer is suspiciously small ($size bytes)."
        }
    }

    $null = Test-InstallerSignature -Path $installerPath
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "The downloaded installer is missing from disk: $installerPath"
    }
    Write-Log -Message "Installer for $($Entry.Full) downloaded and signature-verified ($((Get-Item -LiteralPath $installerPath).Length) bytes)." -Level INFO
    return $installerPath
}

function Invoke-SpotifyPayloadExtract {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)]$Entry
    )

    if (-not $PSCmdlet.ShouldProcess($StagingDir, 'Extract installer payload')) {
        Write-Log -Message '[WhatIf] Payload extraction skipped.' -Level INFO
        return $true
    }

    if (Test-Path -LiteralPath $StagingDir) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

    Write-Step -Message "  Extracting Spotify $($Entry.Short)..." -Type STEP
    Set-Progress -Phase 'Downgrade' -Detail 'Extracting installer payload...' -IsIndeterminate

    $result = Invoke-ExternalCommand -FilePath $InstallerPath -Arguments ('/extract "{0}"' -f $StagingDir) -TimeoutMs ([Math]::Max(300000, [int]$Script:Config.ProcessTimeoutMs))
    if ($result.TimedOut) {
        throw 'Installer /extract timed out.'
    }
    if ($result.ExitCode -ne 0) {
        throw "Installer /extract failed (exit $($result.ExitCode)): $($result.Stderr)"
    }

    $stagedExe = Join-Path $StagingDir 'Spotify.exe'
    if (-not (Test-Path -LiteralPath $stagedExe)) {
        throw "Extraction incomplete: $stagedExe is missing."
    }

    $stagedVersion = ("$((Get-Item -LiteralPath $stagedExe).VersionInfo.FileVersion)" -replace ',', '.')
    $stagedV = ConvertTo-SpotifyVersion -Version $stagedVersion
    $targetV = ConvertTo-SpotifyVersion -Version $Entry.Short
    if ($null -eq $stagedV -or $null -eq $targetV -or $stagedV -ne $targetV) {
        throw "Staged payload version mismatch: expected $($Entry.Short), the staged Spotify.exe reports '$stagedVersion'."
    }

    $xpuiPath = Join-Path $StagingDir 'Apps\xpui.spa'
    if (-not (Test-Path -LiteralPath $xpuiPath)) {
        throw "Extraction incomplete: $xpuiPath is missing."
    }
    if (-not (Test-ZipIntegrity -Path $xpuiPath)) {
        throw 'xpui.spa failed the zip integrity check -- the extraction is corrupted. Aborting before any change to the live installation.'
    }

    Write-Step -Message "  Payload verified: Spotify.exe v$stagedVersion, xpui.spa integrity OK." -Type OK
    return $true
}

function Stop-SpotifyUninstaller {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Deliberately not gated on -WhatIf: this is a data-protection kill of a runaway uninstaller child on a failure/cancel path -- skipping it under WhatIf would risk user data, and under WhatIf the uninstaller never runs anyway.')]
    [CmdletBinding()]
    param()

    $children = @(Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { return }
    Write-Log -Message "Stopping the Spotify uninstaller child process ($($children.Count) instance(s))..." -Level WARN
    foreach ($c in $children) {
        try { Stop-Process -Id $c.Id -Force -ErrorAction Stop } catch {
            Write-Log -Message "Could not stop uninstaller process $($c.Id): $($_.Exception.Message)" -Level WARN
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    if (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue) {
        Write-Log -Message 'The Spotify uninstaller child process is still running after the stop attempt -- it may still be deleting files.' -Level ERROR
    }
}

function Invoke-SpotifyCurrentUninstall {

    [CmdletBinding()]
    param()

    $exe        = $Script:Config.SpotifyExePath
    $installDir = $Script:Config.SpotifyInstallDir

    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Step -Message '  No existing Spotify install to remove (fresh placement).' -Type INFO
        Invoke-SpotifyLeftoverCleanup
        return
    }

    $installedVersion = Get-InstalledSpotifyFileVersion
    $uninstaller      = Join-Path $installDir 'uninstall.exe'
    $installedV       = ConvertTo-SpotifyVersion -Version $installedVersion
    $switchV          = ConvertTo-SpotifyVersion -Version '1.2.84.476'

    if ($null -ne $installedV -and $null -ne $switchV -and $installedV -ge $switchV) {
        if (-not (Test-Path -LiteralPath $uninstaller)) {
            throw "Spotify $installedVersion requires uninstall.exe, which is missing at $uninstaller. Run a Repair first, or remove the folder manually."
        }
        Write-Step -Message "  Running the Spotify uninstaller (v$installedVersion)..." -Type STEP
        $r = Invoke-ExternalCommand -FilePath $uninstaller -Arguments '/silent'
        if ($r.TimedOut) {
            throw 'The Spotify uninstaller timed out.'
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 10000) {
            Assert-NotCancelled
            $child = Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($child) { break }
            if (-not (Test-Path -LiteralPath $exe)) { break }
            Start-SleepCancellable -Milliseconds 200
        }
        if (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue) {
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $deadline) {
                Assert-NotCancelled
                if (-not (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue)) { break }
                if (-not (Test-Path -LiteralPath $exe)) { break }
                Start-SleepCancellable -Milliseconds 250
            }
        }
    } else {
        Write-Step -Message "  Uninstalling Spotify (legacy method, v$installedVersion)..." -Type STEP
        $r = Invoke-ExternalCommand -FilePath $exe -Arguments '/UNINSTALL /SILENT'
        if ($r.TimedOut) {
            throw 'The Spotify uninstall timed out.'
        }

        if (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue) {
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $deadline) {
                Assert-NotCancelled
                if (-not (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue)) { break }
                if (-not (Test-Path -LiteralPath $exe)) { break }
                Start-SleepCancellable -Milliseconds 250
            }
        }
    }

    Start-SleepCancellable -Milliseconds 300
    Invoke-SpotifyLeftoverCleanup

    if (Test-Path -LiteralPath $exe) {
        throw 'Spotify uninstall failed -- Spotify.exe is still present.'
    }
    Write-Step -Message '  Previous Spotify removed.' -Type OK
}

function Invoke-SpotifyLeftoverCleanup {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The Stop-SpotifyUninstaller call is best-effort cleanup: it logs its own failures, and a throw here must not mask the leftover-removal outcome that is reported right below.')]
    [CmdletBinding()]
    param()

    $targets = @(
        $Script:Config.SpotifyInstallDir,
        (Join-Path $env:LOCALAPPDATA 'Spotify')
    )
    foreach ($p in $targets) {
        if (Test-Path -LiteralPath $p) {
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                Write-Log -Message "Removed leftover: $p" -Level INFO
            } catch {
                Write-Log -Message "Leftover removal failed (continuing): $p -- $($_.Exception.Message)" -Level WARN
            }
        }
    }

    $uninstallerExe = Join-Path (Get-TempDir) 'SpotifyUninstall.exe'
    if (-not (Test-Path -LiteralPath $uninstallerExe)) { return }

    $lastErr = ''
    $removed = $false
    try {
        Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction Stop
        $removed = $true
    } catch {
        $lastErr = $_.Exception.Message
    }

    if (-not $removed) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not (Get-Process -Name 'SpotifyUninstall' -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
        }
        try { Stop-SpotifyUninstaller } catch { }
        for ($attempt = 0; $attempt -lt 5 -and -not $removed; $attempt++) {
            try {
                Remove-Item -LiteralPath $uninstallerExe -Force -ErrorAction Stop
                $removed = $true
            } catch {
                $lastErr = $_.Exception.Message
                Start-Sleep -Milliseconds 400
            }
        }
    }

    if ($removed) {
        Write-Log -Message "Removed leftover: $uninstallerExe" -Level INFO
    } else {
        Write-Log -Message "Leftover removal failed (continuing): $uninstallerExe -- $lastErr (the uninstaller copy is still locked; it is harmless and can be deleted after the next reboot)" -Level WARN
    }
}

function Invoke-SpotifyUserdataStage {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StagingDir)

    $installDir = $Script:Config.SpotifyInstallDir
    $dataDir    = Join-Path $StagingDir 'userdata'
    $preserved  = @()
    foreach ($name in @('Users', 'prefs', 'persistent')) {
        $src = Join-Path $installDir $name
        if (Test-Path -LiteralPath $src) {
            if (-not (Test-Path -LiteralPath $dataDir)) {
                New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            }

            $dst = Join-Path $dataDir $name
            if (Test-Path -LiteralPath $dst) {
                Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            $preserved += $name
        }
    }
    if ($preserved.Count -gt 0) {
        Write-Step -Message "  Preserved user data: $($preserved -join ', ')." -Type INFO
    } else {
        Write-Log -Message 'No user data found to preserve (fresh profile after the swap).' -Level INFO
    }
    return $preserved
}

function Invoke-SpotifyUserdataRestore {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagingDir
    )

    $dataDir    = Join-Path $StagingDir 'userdata'
    $installDir = $Script:Config.SpotifyInstallDir
    if (-not (Test-Path -LiteralPath $dataDir)) { return @() }
    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    }

    $restored = @()
    $failed   = @()
    foreach ($name in @('Users', 'prefs', 'persistent')) {
        $src = Join-Path $dataDir $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $installDir $name
        try {

            if (Test-Path -LiteralPath $dst) {
                Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $dst)) { throw 'move did not land' }
            $restored += $name
        } catch {
            $failed += $name
            Write-Log -Message "Could not restore user data item '$name' into $installDir`: $($_.Exception.Message)" -Level ERROR
        }
    }
    if ($failed.Count -gt 0) {
        throw "User data restore failed for: $($failed -join ', '). The staged copy is still in $dataDir"
    }
    if ($restored.Count -gt 0) {
        Write-Step -Message "  User data restored: $($restored -join ', ') (login and preferences kept)." -Type INFO
    } else {
        Write-Log -Message 'No staged user data found to restore (fresh profile).' -Level INFO
    }
    return $restored
}

function Save-StagedUserdata {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [switch]$NoRestore
    )

    $dataDir = Join-Path $StagingPath 'userdata'
    if (-not (Test-Path -LiteralPath $dataDir)) { return '' }
    $hasContent = $false
    try {
        $hasContent = (@(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction Stop).Count -gt 0)
    } catch {
        $hasContent = $true
    }
    if (-not $hasContent) { return '' }

    if (-not $NoRestore) {

        try {
            $null = Invoke-SpotifyUserdataRestore -StagingDir $StagingPath
            Write-Log -Message "Rescued staged user data back into $($Script:Config.SpotifyInstallDir) after a failed swap." -Level WARN
            return ''
        } catch {
            Write-Log -Message "Direct user-data restore failed ($($_.Exception.Message)) -- quarantining instead." -Level ERROR
        }
    }

    $quarantine = Join-Path $Script:AppStateDir ("UserdataRescue_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $quarantine -ErrorAction Stop | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction Stop)) {
        Move-Item -LiteralPath $child.FullName -Destination (Join-Path $quarantine $child.Name) -Force -ErrorAction Stop
    }
    Write-Log -Message "USER DATA QUARANTINED at $quarantine (the only copy was in staging after a failed swap). Copy it back into $($Script:Config.SpotifyInstallDir) manually if needed." -Level ERROR
    return $quarantine
}

function Invoke-SpotifyRegistryWrite {

    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FullVersion)

    $installDir = $Script:Config.SpotifyInstallDir
    $exe        = Join-Path $installDir 'Spotify.exe'
    $regPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Spotify'

    try {
        if (-not (Test-Path -LiteralPath $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name 'DisplayIcon'     -Value "$exe,0" -Type String
        Set-ItemProperty -Path $regPath -Name 'DisplayName'     -Value 'Spotify' -Type String
        Set-ItemProperty -Path $regPath -Name 'DisplayVersion'  -Value $FullVersion -Type String
        Set-ItemProperty -Path $regPath -Name 'Publisher'       -Value 'Spotify AB' -Type String
        Set-ItemProperty -Path $regPath -Name 'UninstallString' -Value "$exe /uninstall" -Type ExpandString
        Set-ItemProperty -Path $regPath -Name 'URLInfoAbout'    -Value 'https://www.spotify.com' -Type String
        Write-Log -Message 'Uninstall registry entry updated for the swapped version.' -Level INFO
    } catch {
        Write-Step -Message "  Registry entry could not be updated (non-fatal): $($_.Exception.Message)" -Type WARN
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
        $lnk = $shell.CreateShortcut((Join-Path $startMenuDir 'Spotify.lnk'))
        $lnk.TargetPath = $exe
        $null = $lnk.Save()

        $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Spotify.lnk'
        if (Test-Path -LiteralPath $desktopLnk) {
            $d = $shell.CreateShortcut($desktopLnk)
            $d.TargetPath = $exe
            $null = $d.Save()
        }
        Write-Log -Message 'Shortcuts updated.' -Level INFO
    } catch {
        Write-Step -Message "  Shortcuts could not be updated (non-fatal): $($_.Exception.Message)" -Type WARN
    }
}

function Invoke-SpotifyVersionSwap {

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Entry
    )

    if (-not $PSCmdlet.ShouldProcess("Spotify $($Entry.Short)", 'Swap installation (uninstall current, place verified payload)')) {
        Write-Log -Message '[WhatIf] Version swap skipped.' -Level INFO
        return
    }

    $stagingDir = $Script:StagingPath
    if (-not $stagingDir -or -not (Test-Path -LiteralPath (Join-Path $stagingDir 'payload'))) {
        throw 'Version swap called without a staged payload.'
    }
    $payloadDir = Join-Path $stagingDir 'payload'

    $blockState = Get-SpotifyUpdateBlockState
    try {
        if ($blockState.Blocked) {
            Write-Step -Message '  Temporarily lifting the update block for the swap...' -Type INFO
            Remove-SpotifyUpdateBlock | Out-Null
        }

        $null = Invoke-SpotifyUserdataStage -StagingDir $stagingDir

        Invoke-SpotifyCurrentUninstall

        if (Test-Path -LiteralPath $Script:Config.SpotifyInstallDir) {

            $residue = @(Get-ChildItem -LiteralPath $Script:Config.SpotifyInstallDir -Force -ErrorAction SilentlyContinue |
                Where-Object { -not ($_.PSIsContainer -and @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) })
            if ($residue.Count -gt 0) {
                throw "Installation directory is not empty after the uninstaller ran ($($residue.Count) item(s) left; likely locked files). Refusing to mix versions -- close Spotify and other locks, then retry, or remove $($Script:Config.SpotifyInstallDir) manually."
            }
        }
        Write-Step -Message "  Placing Spotify $($Entry.Short) into $($Script:Config.SpotifyInstallDir)..." -Type STEP
        New-Item -ItemType Directory -Force -Path $Script:Config.SpotifyInstallDir | Out-Null
        Get-ChildItem -LiteralPath $payloadDir |
            Move-Item -Destination $Script:Config.SpotifyInstallDir -Force -ErrorAction Stop
        Wait-ForSpotifyRelease

        $placed  = Get-InstalledSpotifyFileVersion
        $placedV = ConvertTo-SpotifyVersion -Version $placed
        $targetV = ConvertTo-SpotifyVersion -Version $Entry.Short
        if ($null -eq $placedV -or $null -eq $targetV -or $placedV -ne $targetV) {
            throw "Placement verification failed: expected $($Entry.Short), found '$placed'."
        }
        $placedXpui = Join-Path $Script:Config.SpotifyInstallDir 'Apps\xpui.spa'
        if (-not (Test-Path -LiteralPath $placedXpui)) {
            throw "Placement verification failed: $placedXpui is missing."
        }
        if (-not (Test-ZipIntegrity -Path $placedXpui)) {
            throw "Placement verification failed: $placedXpui did not pass the zip integrity check."
        }

        Invoke-SpotifyRegistryWrite -FullVersion $Entry.Full

        $null = Invoke-SpotifyUserdataRestore -StagingDir $stagingDir
    } catch {

        Stop-SpotifyUninstaller
        $dataDir = Join-Path $stagingDir 'userdata'
        if (Test-Path -LiteralPath $dataDir) {
            $directOk = $false
            try {
                $null = Invoke-SpotifyUserdataRestore -StagingDir $stagingDir
                $directOk = $true
            } catch {
                Write-Log -Message "Direct user-data restore failed: $($_.Exception.Message)" -Level ERROR
            }
            if (-not $directOk) {
                try {
                    $null = Save-StagedUserdata -StagingPath $stagingDir
                } catch {
                    Write-Log -Message "USER DATA COULD NOT BE RESCUED from $dataDir -- recover it manually before deleting anything." -Level ERROR
                }
            }
        }
        throw
    } finally {

        if ($blockState.Blocked) {
            Write-Step -Message '  Re-applying the update block...' -Type INFO
            try {
                Set-SpotifyUpdateBlock -Force | Out-Null
            } catch {
                $Script:UpdateBlockReapplyFailed = $true
                Write-Step -Message "  Could not re-apply the update block: $($_.Exception.Message)" -Type WARN
            }
        }
    }

    Write-Step -Message "  Spotify is now version $($Entry.Short)." -Type OK
}

function Invoke-SpotifyVersionList {

    [CmdletBinding()]
    param()

    $arch       = Get-SpotifyCatalogArch
    $catalog    = Get-SpotifyVersionCatalog
    $installed  = Get-InstalledSpotifyFileVersion
    $installedV = ConvertTo-SpotifyVersion -Version $installed
    $pin        = [string]$Script:Config.PinnedSpotifyVersion

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host ' Spotify version catalog (downgrade / roll-forward)' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    if ($installed) {
        Write-Host " Installed: $installed" -ForegroundColor Green
    } else {
        Write-Host ' Installed: (not found in the managed location)' -ForegroundColor DarkGray
    }
    if ($pin) { Write-Host " Version pin: $pin (repairs keep this version)" -ForegroundColor Green }
    Write-Host " Native arch: $arch  |  catalog versions: $($catalog.Count)"
    Write-Host ''

    $loginMin = ConvertTo-SpotifyVersion -Version '1.1.87.612'
    $loginMax = ConvertTo-SpotifyVersion -Version '1.2.5.1006'

    $offered = 0
    foreach ($e in $catalog) {
        if (-not (Test-SpotifyVersionOffered -Entry $e -Arch $arch)) { continue }
        $offered++
        $flags = @()
        $v = ConvertTo-SpotifyVersion -Version $e.Short
        if ($null -ne $installedV -and $null -ne $v -and $v -eq $installedV) { $flags += 'CURRENT' }
        if ($pin -and $e.Short -eq $pin) { $flags += 'PINNED' }
        if ($null -ne $v -and $null -ne $loginMin -and $null -ne $loginMax -and
            $v -ge $loginMin -and $v -le $loginMax) { $flags += 'login-broken' }
        $flagStr = ''
        if ($flags.Count -gt 0) { $flagStr = '  [' + ($flags -join ', ') + ']' }
        $color = [Console]::ForegroundColor
        if ($flags -contains 'CURRENT') { $color = 'Green' }
        elseif ($flags -contains 'login-broken') { $color = 'Yellow' }
        Write-Host ("  {0,-16} {1,-12}{2}" -f $e.Short, $e.Date, $flagStr) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host " $offered version(s) offered for this machine ($arch)."
    Write-Host ' Switch with:  .\SpicetifyManagerPro.ps1 -DowngradeTo <version>   (or the GUI: Version... button)'
    Write-Host ' Block updates: -BlockUpdates   |  Unblock: -UnblockUpdates   |  Clear pin: -DowngradeTo none'
    Write-Host ''
}

function Test-MicrosoftStoreSpotify {
    [CmdletBinding()]
    param()

    $storePath = $Script:Config.SpotifyStorePath
    if (Test-Path -LiteralPath $storePath) {
        try {
            $item = Get-Item -LiteralPath $storePath -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                return $true
            }
        } catch {
            return $false
        }
    }

    try {
        $pkg = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic*' -ErrorAction Stop
        if ($pkg) { return $true }
    } catch {

    }

    return $false
}

function Test-DiskSpace {
    [CmdletBinding()]
    param()

    $minMB = $Script:Config.MinDiskSpaceMB

    $tempFree  = Get-FreeDiskSpaceMB -Path (Get-TempDir)
    $appFree   = Get-FreeDiskSpaceMB -Path $env:APPDATA
    $localFree = Get-FreeDiskSpaceMB -Path $env:LOCALAPPDATA

    foreach ($v in @($tempFree, $appFree, $localFree)) {
        if ($v -lt 0) {
            Write-Log -Message 'Free space could not be determined for one of the target volumes -- proceeding, but the disk check is incomplete.' -Level WARN
            break
        }
    }

    $ok = (($tempFree -lt 0) -or ($tempFree -ge $minMB)) -and
          (($appFree -lt 0) -or ($appFree -ge $minMB)) -and
          (($localFree -lt 0) -or ($localFree -ge $minMB))

    return [PSCustomObject]@{
        Ok          = $ok
        TempFreeMB  = $tempFree
        AppFreeMB   = $appFree
        LocalFreeMB = $localFree
        MinMB       = $minMB
    }
}

function Invoke-PreflightChecks {
    [CmdletBinding()]
    param()

    if ($Script:SkipPreflight) {
        Write-Step -Message 'Pre-flight checks skipped by setting.' -Type WARN
        return
    }

    Write-Step -Message 'Running pre-flight checks...' -Type STEP

    $arch = Test-ArchitectureSupported
    if (-not $arch.Ok) {
        Write-Step -Message "  $($arch.Warning)" -Type ERR
        throw $arch.Warning
    }
    if ($arch.Warning) {
        Write-Step -Message "  $($arch.Warning)" -Type WARN
    } else {
        Write-Step -Message "  Architecture: $($arch.Arch) -- OK." -Type OK
    }

    $disk = Test-DiskSpace
    if (-not $disk.Ok) {
        $msg = "Insufficient disk space. Temp: $($disk.TempFreeMB) MB, AppData: $($disk.AppFreeMB) MB, LocalAppData: $($disk.LocalFreeMB) MB. Required: $($disk.MinMB) MB."
        Write-Step -Message "  $msg" -Type ERR
        throw $msg
    }
    Write-Step -Message "  Disk space: Temp $($disk.TempFreeMB) MB / AppData $($disk.AppFreeMB) MB / LocalAppData $($disk.LocalFreeMB) MB -- OK." -Type OK

    if (-not (Test-NetworkOk)) {
        throw 'Network unreachable. Check your connection or proxy.'
    }
    Write-Step -Message '  Network connectivity OK.' -Type OK

    if (Test-MicrosoftStoreSpotify) {
        $msg = @'
Microsoft Store version of Spotify detected. Spicetify cannot modify the Store
version. To use Spicetify:
  1. Open Settings > Apps > Installed apps
  2. Uninstall "Spotify" (the Store version)
  3. Run this tool again -- it will install the standard desktop version
     from https://download.scdn.co/SpotifySetup.exe
'@
        Write-Step -Message '  Microsoft Store Spotify detected!' -Type ERR
        Write-Step -Message $msg -Type ERR
        throw 'Microsoft Store Spotify is not supported by Spicetify. Uninstall it first.'
    }
    Write-Step -Message '  No Microsoft Store Spotify detected.' -Type OK

    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        Write-Step -Message "  PowerShell $($PSVersionTable.PSVersion) detected. PS 7+ recommended for best performance." -Type WARN
    } else {
        Write-Step -Message "  PowerShell $($PSVersionTable.PSVersion) -- OK." -Type OK
    }

    Write-Step -Message 'Pre-flight checks passed.' -Type OK
}

function Stop-SpotifyProcess {
    [CmdletBinding()]

    param([switch]$Force)

    if ($WhatIfPreference) {
        Write-Log -Message 'WhatIf: skipping Spotify process stop.' -Level INFO
        return
    }

    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Spotify' })
    if ($procs.Count -eq 0) { return }

    Write-Log -Message "Stopping $($procs.Count) Spotify process(es)" -Level INFO
    try {
        $procs | Stop-Process -Force -ErrorAction Continue
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Spotify' })).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Log -Message "Failed to stop Spotify processes: $($_.Exception.Message)" -Level WARN
    }

    $remaining = @()
    try {
        $remaining = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Spotify' })
    } catch {

    }
    if ($remaining.Count -gt 0) {
        throw "Spotify is still running after 10 seconds and could not be stopped ($($remaining.Count) process(es)). Close Spotify manually (check the system tray) and try again."
    }
}

function Install-Spotify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Spotify not found. Installing...' -Type STEP

    if (-not $PSCmdlet.ShouldProcess('Spotify', 'Download and install')) {
        return
    }

    $activePin = Get-PinnedSpotifyVersion
    if ($activePin) {
        try {
            $pinEntry = Get-SpotifyCatalogEntry -Version $activePin
        } catch {
            throw "Version pin '$activePin' is active but the online catalog is unreachable: $($_.Exception.Message). Clear the pin (-DowngradeTo none) or retry when online."
        }
        if ($null -ne $pinEntry) {
            Write-Step -Message "  Version pin active -- installing Spotify $($pinEntry.Short) instead of the latest." -Type WARN
            $Script:StagingPath = Join-Path (Get-TempDir) ("SpicetifyManagerPro_stage_{0}" -f (New-Guid).ToString('N').Substring(0, 8))
            $installerPath = Invoke-SpotifyInstallerDownload -Entry $pinEntry -BasePercent 5 -Weight 10
            if (-not $installerPath -or $installerPath -isnot [string] -or -not (Test-Path -LiteralPath $installerPath)) {
                $gotKind = if ($null -eq $installerPath) { 'no value' } else { $installerPath.GetType().Name }
                throw "Installer download did not produce a usable file path (got $gotKind). This is a tool bug -- please report it with the log file."
            }
            $payloadDir = Join-Path $Script:StagingPath 'payload'
            $null = Invoke-SpotifyPayloadExtract -InstallerPath $installerPath -StagingDir $payloadDir -Entry $pinEntry
            Invoke-SpotifyVersionSwap -Entry $pinEntry
            Write-Step -Message "Pinned Spotify $($pinEntry.Short) installed." -Type OK
            return
        }
        Write-Step -Message "  Version pin '$activePin' is not in the catalog -- installing the latest instead." -Type WARN
    }

    $installerPath = Join-Path (Get-TempDir) "SpotifySetup_$(New-Guid).exe"
    $null = $Script:TempFiles.Add($installerPath)

    Write-Step -Message '  Downloading Spotify installer...' -Type STEP
    Invoke-WithRetry -Label 'Download Spotify installer' -Action {

        Invoke-DownloadWithProgress `
            -Uri 'https://download.scdn.co/SpotifySetup.exe' `
            -OutFile $installerPath `
            -Label 'Downloading Spotify installer' `
            -BasePercent 5 -Weight 10 `
            -TimeoutMs 180000
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw 'Spotify installer download failed -- file not created.'
    }
    $size = (Get-Item $installerPath).Length
    if ($size -lt 1024) {
        throw "Spotify installer is suspiciously small ($size bytes). Download may have failed."
    }
    Write-Log -Message "Downloaded Spotify installer: $size bytes" -Level DEBUG

    $null = Test-InstallerSignature -Path $installerPath

    Write-Step -Message '  Running Spotify installer...' -Type STEP

    Set-Progress -Phase 'Spotify' -Detail 'Running Spotify installer...' -IsIndeterminate
    $result = Invoke-ExternalCommand -FilePath $installerPath -TimeoutMs 180000

    if ($result.TimedOut) {
        throw 'Spotify installer timed out after 180 seconds'
    }

    if ($result.ExitCode -ne 0) {
        Write-Log -Message "Installer exited with code $($result.ExitCode) -- may be normal." -Level WARN
    }

    $xpuiPath = Join-Path $Script:Config.SpotifyInstallDir 'Apps\xpui.spa'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 120000) {
        if ((Test-Path -LiteralPath $Script:Config.SpotifyExePath) -and
            (Test-Path -LiteralPath $xpuiPath)) {
            break
        }
        Start-SleepCancellable -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
        throw 'Spotify executable not found after installation'
    }

    if (-not (Test-Path -LiteralPath $xpuiPath)) {
        throw "Installation incomplete: $xpuiPath is missing (installer may still be running)."
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease
    Write-Step -Message 'Spotify installed.' -Type OK
}

function Repair-Spotify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Repairing Spotify...' -Type WARN

    if (-not $PSCmdlet.ShouldProcess('Spotify', 'Repair installation')) {
        return
    }

    $activePin = Get-PinnedSpotifyVersion
    if ($activePin) {
        try {
            $pinEntry = Get-SpotifyCatalogEntry -Version $activePin
        } catch {
            throw "Version pin '$activePin' is active but the online catalog is unreachable: $($_.Exception.Message). Clear the pin (-DowngradeTo none) or retry when online."
        }
        if ($null -ne $pinEntry) {
            Write-Step -Message "  Version pin active -- repairing Spotify $($pinEntry.Short) instead of the latest." -Type WARN
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            $Script:StagingPath = Join-Path (Get-TempDir) ("SpicetifyManagerPro_stage_{0}" -f (New-Guid).ToString('N').Substring(0, 8))
            $installerPath = Invoke-SpotifyInstallerDownload -Entry $pinEntry -BasePercent 25 -Weight 15
            if (-not $installerPath -or $installerPath -isnot [string] -or -not (Test-Path -LiteralPath $installerPath)) {
                $gotKind = if ($null -eq $installerPath) { 'no value' } else { $installerPath.GetType().Name }
                throw "Installer download did not produce a usable file path (got $gotKind). This is a tool bug -- please report it with the log file."
            }
            $payloadDir = Join-Path $Script:StagingPath 'payload'
            $null = Invoke-SpotifyPayloadExtract -InstallerPath $installerPath -StagingDir $payloadDir -Entry $pinEntry
            Invoke-SpotifyVersionSwap -Entry $pinEntry
            Write-Step -Message "Pinned Spotify $($pinEntry.Short) repaired." -Type OK
            return
        }
        Write-Step -Message "  Version pin '$activePin' is not in the catalog -- repairing with the latest instead." -Type WARN
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease

    $installerPath = Join-Path (Get-TempDir) "SpotifySetup_$(New-Guid).exe"
    $null = $Script:TempFiles.Add($installerPath)

    Write-Step -Message '  Downloading Spotify installer...' -Type STEP
    Invoke-WithRetry -Label 'Download Spotify installer (repair)' -Action {

        Invoke-DownloadWithProgress `
            -Uri 'https://download.scdn.co/SpotifySetup.exe' `
            -OutFile $installerPath `
            -Label 'Downloading Spotify installer (repair)' `
            -BasePercent 25 -Weight 15 `
            -TimeoutMs 180000
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw 'Spotify installer download failed during repair.'
    }
    $size = (Get-Item $installerPath).Length
    if ($size -lt 1024) {
        throw "Spotify installer is suspiciously small ($size bytes). Download may have failed."
    }

    $null = Test-InstallerSignature -Path $installerPath

    Write-Step -Message '  Running Spotify installer...' -Type STEP
    Set-Progress -Phase 'SpotifyInstall' -Detail 'Running Spotify installer...' -IsIndeterminate
    $result = Invoke-ExternalCommand -FilePath $installerPath -TimeoutMs 180000

    if ($result.TimedOut) {
        throw 'Spotify installer timed out after 180 seconds during repair'
    }
    if ($result.ExitCode -ne 0) {
        Write-Log -Message "Installer exited with code $($result.ExitCode) -- may be normal." -Level WARN
    }

    $xpuiPath = Join-Path $Script:Config.SpotifyInstallDir 'Apps\xpui.spa'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 120000) {
        if ((Test-Path -LiteralPath $Script:Config.SpotifyExePath) -and
            (Test-Path -LiteralPath $xpuiPath)) {
            break
        }
        Start-SleepCancellable -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
        throw 'Spotify executable not found after repair'
    }

    if (-not (Test-Path -LiteralPath $xpuiPath)) {
        throw "Repair incomplete: $xpuiPath is missing (installer may still be running or failed)."
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease
    Write-Step -Message 'Spotify repaired.' -Type OK
}

function Backup-UserCustomizations {
    [CmdletBinding()]
    param()

    if ($WhatIfPreference) {
        Write-Log -Message 'WhatIf: skipping user customization backup staging.' -Level INFO
        return
    }
    if (-not (Test-Path -LiteralPath $Script:Config.AppDataPath)) {
        Write-Log -Message 'No Spicetify app data directory found. Nothing to back up.' -Level INFO
        return
    }

    Write-Log -Message 'Backing up user customizations...' -Level INFO
    Wait-ForSpotifyRelease

    try {
        if (-not $Script:StagingPath) {
            $Script:StagingPath = Join-Path (Get-TempDir) "spicetify_staging_$(New-Guid)"
        }
        if (-not (Test-Path -LiteralPath $Script:StagingPath)) {
            New-Item -ItemType Directory -Force -Path $Script:StagingPath | Out-Null
        }

        $items = @(
            @{ Src = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'; Dst = $Script:StagingPath; Recurse = $false }
            @{ Src = Join-Path $Script:Config.AppDataPath 'Extensions';     Dst = Join-Path $Script:StagingPath 'Extensions'; Recurse = $true }
            @{ Src = Join-Path $Script:Config.AppDataPath 'Themes';         Dst = Join-Path $Script:StagingPath 'Themes';      Recurse = $true }
        )

        foreach ($item in $items) {
            if (Test-Path -LiteralPath $item.Src) {
                Copy-ItemSafe -Source $item.Src -Destination $item.Dst -Recurse:$item.Recurse
            }
        }

        $customAppsSrc = Join-Path $Script:Config.AppDataPath 'CustomApps'
        if (Test-Path -LiteralPath $customAppsSrc) {
            $customAppsDst = Join-Path $Script:StagingPath 'CustomApps'
            New-Item -ItemType Directory -Force -Path $customAppsDst | Out-Null
            foreach ($child in @(Get-ChildItem -LiteralPath $customAppsSrc -Force)) {
                if ($child.Name -ieq 'marketplace') { continue }
                Copy-ItemSafe -Source $child.FullName -Destination (Join-Path $customAppsDst $child.Name) -Recurse
            }
        }

        $Script:StagingValid = $true
        New-Item -ItemType File -Path (Join-Path $Script:StagingPath '.backup_complete') -Force | Out-Null
        Write-Log -Message 'Backup completed.' -Level SUCCESS
    } catch {
        $Script:StagingValid = $false
        Write-Log -Message "Backup failed: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

function Save-BackupHistory {
    [CmdletBinding()]
    param()

    if ($WhatIfPreference) { return }
    if (-not $Script:StagingValid) { return }
    if (-not $Script:StagingPath -or -not (Test-Path -LiteralPath $Script:StagingPath)) { return }

    if (-not (Test-Path -LiteralPath $Script:Config.BackupHistoryDir)) {
        New-Item -ItemType Directory -Force -Path $Script:Config.BackupHistoryDir | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $histDest = Join-Path $Script:Config.BackupHistoryDir "backup_$ts"
    Copy-ItemSafe -Source $Script:StagingPath -Destination $histDest -Recurse

    if (-not (Test-Path -LiteralPath (Join-Path $histDest '.backup_complete'))) {
        Write-Log -Message "History snapshot incomplete at $histDest -- removing it." -Level ERROR
        Remove-Item -LiteralPath $histDest -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log -Message "Snapshot saved to backup history: $histDest" -Level DEBUG
    }

    $history = @(Get-ChildItem -Path $Script:Config.BackupHistoryDir -Directory -Filter 'backup_*' |
        Sort-Object Name -Descending)
    if ($history.Count -gt $Script:Config.BackupRetention) {
        $toDelete = $history | Select-Object -Skip $Script:Config.BackupRetention
        foreach ($old in $toDelete) {
            Write-Log -Message "Pruning old backup: $($old.FullName)" -Level DEBUG
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-UserCustomizations {
    [CmdletBinding()]
    param()

    if ($WhatIfPreference) {
        Write-Log -Message 'WhatIf: skipping user customization restore (nothing was staged).' -Level INFO
        return
    }
    if (-not $Script:StagingValid) {
        Write-Log -Message 'No valid backup staging data. Skipping restore.' -Level DEBUG
        return
    }

    $marker = Join-Path $Script:StagingPath '.backup_complete'
    if (-not (Test-Path -LiteralPath $marker)) {
        Write-Log -Message 'Backup marker missing. Skipping restore.' -Level WARN
        return
    }

    Write-Log -Message 'Restoring user customizations...' -Level INFO

    try {
        $appData = $Script:Config.AppDataPath

        if (-not (Test-Path -LiteralPath $appData)) {
            New-Item -ItemType Directory -Force -Path $appData | Out-Null
        }

        foreach ($dir in @('Extensions', 'Themes', 'CustomApps')) {
            $target = Join-Path $appData $dir
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            }
        }

        $iniSrc = Join-Path $Script:StagingPath 'config-xpui.ini'
        if (Test-Path -LiteralPath $iniSrc) {
            Copy-ItemSafe -Source $iniSrc -Destination $appData
        }

        foreach ($dir in @('Extensions', 'Themes')) {
            $src = Join-Path $Script:StagingPath $dir
            if (Test-Path -LiteralPath $src) {

                Copy-ItemSafe -Source "$src/*" -Destination (Join-Path $appData $dir) -Recurse -AllowWildcard
            }
        }

        $caSrc = Join-Path $Script:StagingPath 'CustomApps'
        if (Test-Path -LiteralPath $caSrc) {
            $caDst = Join-Path $appData 'CustomApps'
            if (-not (Test-Path -LiteralPath $caDst)) {
                New-Item -ItemType Directory -Force -Path $caDst | Out-Null
            }
            foreach ($child in @(Get-ChildItem -LiteralPath $caSrc -Force)) {
                if ($child.Name -ieq 'marketplace') { continue }

                $appDst = Join-Path $caDst $child.Name
                if (-not (Test-Path -LiteralPath $appDst)) {
                    New-Item -ItemType Directory -Force -Path $appDst | Out-Null
                }
                Copy-ItemSafe -Source "$($child.FullName)/*" -Destination $appDst -Recurse -AllowWildcard
            }
        }

        Write-Log -Message 'Customizations restored.' -Level SUCCESS
    } catch {
        throw "Restore failed: $($_.Exception.Message)"
    }
}

function Get-SpicetifyLocalVersion {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Script:Config.SpicetifyExePath)) { return $null }

    try {
        $r = Invoke-SpicetifyCli '--version'
        if ($r.ExitCode -ne 0) { return $null }
    } catch {
        return $null
    }

    if ($r.Stdout -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
        try { return [version]$Matches[1] } catch { return $null }
    }
    return $null
}

function Install-Spicetify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $exe = $Script:Config.SpicetifyExePath
    $currentVersion = $null
    $release        = $null
    $needsInstall   = -not (Test-Path -LiteralPath $exe)

    if (-not $needsInstall) {
        $currentVersion = Get-SpicetifyLocalVersion
        if ($null -eq $currentVersion) {
            Write-Log -Message 'Local version query failed. Forcing reinstall.' -Level WARN
            $needsInstall = $true
        }
    }

    if (-not $needsInstall) {
        $release = Get-GitHubLatestRelease -Owner 'spicetify' -Repo 'cli'
        $latestTag = $release.tag_name -replace '^v', '' -replace '-.*$', ''
        $latestVersion = $null
        try {
            $latestVersion = [version]$latestTag
        } catch {
            Write-Log -Message "Could not parse remote version '$latestTag'. Forcing reinstall." -Level WARN
            $needsInstall = $true
        }

        if (-not $needsInstall -and $currentVersion -ge $latestVersion) {
            Write-Step -Message "Spicetify $currentVersion is current (latest: $latestVersion)." -Type OK
            return
        }
        if (-not $needsInstall) {
            Write-Step -Message "Upgrading Spicetify $currentVersion -> $latestVersion..." -Type STEP
        }
    } else {
        Write-Step -Message 'Spicetify not found. Installing...' -Type STEP
    }

    if (-not $PSCmdlet.ShouldProcess('Spicetify', 'Install/Update')) {
        return
    }

    if ($null -eq $release) {
        $release = Get-GitHubLatestRelease -Owner 'spicetify' -Repo 'cli'
    }

    $asset = $release.assets | Where-Object {
        $_.name -match '^spicetify-[\d.]+-windows-x64\.zip$'
    } | Select-Object -First 1
    if (-not $asset) {
        throw 'Windows x64 binary not found in latest Spicetify release. Assets: ' + (($release.assets | ForEach-Object { $_.name }) -join ', ')
    }

    $tempZip = $null
    $cachedZip = $null
    if ($Script:Config.EnableCache) {
        if (-not (Test-Path -LiteralPath $Script:Config.CacheDir)) {
            New-Item -ItemType Directory -Force -Path $Script:Config.CacheDir | Out-Null
        }

        $cachedZip = Join-Path $Script:Config.CacheDir $asset.name
        if (Test-Path -LiteralPath $cachedZip) {
            if (Test-ZipIntegrity -Path $cachedZip) {
                Write-Log -Message "Using cached Spicetify binary: $cachedZip" -Level INFO
                $tempZip = $cachedZip
            } else {
                Write-Log -Message 'Cached Spicetify binary is corrupt -- re-downloading.' -Level WARN
                Remove-Item -LiteralPath $cachedZip -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $tempZip) {
        $tempZip = Join-Path (Get-TempDir) "spicetify_$(New-Guid).zip"
        $null = $Script:TempFiles.Add($tempZip)
        Write-Step -Message '  Downloading Spicetify binary...' -Type STEP
        Invoke-WithRetry -Label 'Download Spicetify binary' -Action {

            Invoke-DownloadWithProgress `
                -Uri $asset.browser_download_url `
                -OutFile $tempZip `
                -Label 'Downloading Spicetify binary' `
                -BasePercent 30 -Weight 20 `
                -TimeoutMs 300000
        }

        if (-not (Test-ZipIntegrity -Path $tempZip)) {
            throw 'Downloaded Spicetify archive is corrupted'
        }

        if ($Script:Config.EnableCache -and $cachedZip) {
            try {
                Copy-Item -Path $tempZip -Destination $cachedZip -Force -ErrorAction Stop
                Write-Log -Message "Cached Spicetify binary at: $cachedZip" -Level DEBUG
            } catch {
                Write-Log -Message "Failed to cache binary: $($_.Exception.Message)" -Level DEBUG
            }
        }
    }

    $digestProp = $asset.PSObject.Properties['digest']
    $digest = if ($digestProp) { "$($digestProp.Value)" } else { '' }
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToUpperInvariant()
        $actual = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            throw "Spicetify archive digest mismatch (expected $expected, got $actual). Refusing to install."
        }
        Write-Log -Message 'Spicetify archive digest verified against the GitHub release manifest.' -Level INFO
    } else {

        Write-Log -Message 'No sha256 digest in the GitHub release manifest -- skipping digest verification.' -Level DEBUG
    }

    $installDir = Split-Path $exe

    if ($cachedZip -and $tempZip -eq $cachedZip) {
        $stagedZip = Join-Path (Get-TempDir) "spicetify_stage_$(New-Guid).zip"
        Copy-Item -LiteralPath $tempZip -Destination $stagedZip -Force
        $null = $Script:TempFiles.Add($stagedZip)
        $tempZip = $stagedZip
    }

    $oldDir = $null
    if (Test-Path -LiteralPath $installDir) {
        $installLeaf = Split-Path $installDir -Leaf
        Get-ChildItem -LiteralPath (Split-Path $installDir -Parent) -Directory -Filter ($installLeaf + '.old_*') -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $oldDir = Join-Path (Split-Path $installDir -Parent) ($installLeaf + '.old_' + (New-Guid).ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $installDir -Destination $oldDir -Force
    }
    try {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Write-Step -Message '  Extracting Spicetify...' -Type STEP

        if (-not (Test-ZipEntryPaths -Path $tempZip)) {
            throw 'Spicetify archive contains unsafe entry paths (path traversal) -- refusing to extract.'
        }
        Expand-Archive -Path $tempZip -DestinationPath $installDir -Force
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "Spicetify executable not found after extraction: $exe"
        }

        if ($oldDir -and $Script:Config.CacheDir) {
            $installRoot = $installDir.TrimEnd('\').TrimEnd('/')
            $cacheNorm = "$($Script:Config.CacheDir)".TrimEnd('\').TrimEnd('/')
            $cacheInsideInstall = $cacheNorm.StartsWith($installRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                                  $cacheNorm.StartsWith($installRoot + '/', [System.StringComparison]::OrdinalIgnoreCase)
            if ($cacheInsideInstall) {

                $rel = $cacheNorm.Substring($installRoot.Length).TrimStart('\').TrimStart('/').Replace('/', '\')
                $oldCache = Join-Path $oldDir $rel
                $newCache = Join-Path $installDir $rel
                if (Test-Path -LiteralPath $oldCache) {
                    try {
                        $newCacheParent = Split-Path $newCache -Parent
                        if ($newCacheParent -and -not (Test-Path -LiteralPath $newCacheParent)) {
                            New-Item -ItemType Directory -Force -Path $newCacheParent | Out-Null
                        }
                        Move-Item -LiteralPath $oldCache -Destination $newCache -Force
                        Write-Log -Message 'Preserved the download cache across the Spicetify update.' -Level INFO
                    } catch {
                        Write-Log -Message "Could not migrate the download cache: $($_.Exception.Message)" -Level WARN
                    }
                }
            }
        }
    } catch {

        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($oldDir -and (Test-Path -LiteralPath $oldDir)) {
            Move-Item -LiteralPath $oldDir -Destination $installDir -Force
        }
        throw
    }
    if ($oldDir) {
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    $installDirNorm = $installDir.TrimEnd('\').TrimEnd('/')
    $alreadyInPath = $false
    foreach ($entry in $pathEntries) {
        if ($entry.Trim().TrimEnd('\').TrimEnd('/') -ieq $installDirNorm) {
            $alreadyInPath = $true
            break
        }
    }
    if (-not $alreadyInPath) {

        Write-Log -Message "Previous user PATH: $userPath" -Level INFO
        $separator = if ($userPath -and -not $userPath.EndsWith(';')) { ';' } else { '' }
        [Environment]::SetEnvironmentVariable('Path', "${userPath}${separator}${installDir}", 'User')
        $sessionSep = if ($env:Path -and -not $env:Path.EndsWith(';')) { ';' } else { '' }
        $env:Path = "${env:Path}${sessionSep}${installDir}"
        Write-Log -Message "Added $installDir to user PATH" -Level INFO
    }

    Write-Step -Message 'Spicetify installed.' -Type OK
}

function Uninstall-Spicetify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Uninstalling Spicetify...' -Type STEP

    if (-not $PSCmdlet.ShouldProcess('Spicetify', 'Uninstall')) {
        return
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease

    if (Test-Path -LiteralPath $Script:Config.SpicetifyExePath) {
        Write-Step -Message '  Restoring Spotify to pre-Spicetify state...' -Type STEP
        $r = Invoke-SpicetifyCli 'restore'
        Write-Log -Message "Restore exit code: $($r.ExitCode)" -Level DEBUG
        Write-Log -Message "Restore stdout: $($r.Stdout)" -Level DEBUG
        if ($r.Stderr) { Write-Log -Message "Restore stderr: $($r.Stderr)" -Level DEBUG }

        if ($r.TimedOut) {
            throw "spicetify restore timed out -- uninstall aborted so the recovery files stay available."
        }
        if ($r.ExitCode -ne 0) {
            $restoreOut = Get-CombinedOutput -Result $r
            throw "spicetify restore FAILED (exit $($r.ExitCode)): $restoreOut -- uninstall aborted so the recovery files stay available."
        }
    } elseif (Test-Path -LiteralPath $Script:Config.BackupDir) {

        throw "spicetify executable is missing but its backup exists at $($Script:Config.BackupDir); Spotify may still be patched. Uninstall aborted so the recovery files stay available. Reinstall spicetify and run the uninstall again (it will restore Spotify first), or restore manually from the backup folder."
    }

    foreach ($p in @(
        $Script:Config.AppDataPath,
        (Split-Path $Script:Config.SpicetifyExePath)
    )) {
        if (Test-Path -LiteralPath $p) {
            Write-Step -Message "  Removing $p ..." -Type STEP
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $p) {
                throw "Could not remove '$p' (files locked by a running process?). Uninstall is incomplete."
            }
        }
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $installDir = Split-Path $Script:Config.SpicetifyExePath
        $installDirNorm = $installDir.TrimEnd('\').TrimEnd('/')
        $newEntries = @()
        foreach ($entry in ($userPath -split ';')) {
            if ($entry.Trim().TrimEnd('\').TrimEnd('/') -ine $installDirNorm -and $entry.Trim() -ne '') {
                $newEntries += $entry.Trim()
            }
        }

        Write-Log -Message "Previous user PATH: $userPath" -Level INFO
        [Environment]::SetEnvironmentVariable('Path', ($newEntries -join ';'), 'User')
    }

    Write-Step -Message 'Spicetify uninstalled.' -Type OK
}

function Install-Marketplace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $dest = $Script:Config.MarketplaceDest

    if (-not $PSCmdlet.ShouldProcess('Marketplace', 'Install/Update')) {
        return
    }

    $staging = Join-Path (Get-TempDir) "marketplace_stage_$((New-Guid).ToString('N'))"
    $null = $Script:TempFiles.Add($staging)
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $zipPath = Join-Path $staging 'marketplace.zip'

    Write-Step -Message '  Downloading Marketplace...' -Type STEP
    $marketAsset = $null
    try {
        $marketRelease = Get-GitHubLatestRelease -Owner 'spicetify' -Repo 'marketplace'
        $marketAsset = @($marketRelease.assets) | Where-Object { "$($_.name)" -eq 'marketplace.zip' } | Select-Object -First 1
        if ($null -eq $marketAsset) {
            Write-Log -Message 'Marketplace asset not found in the GitHub release manifest -- continuing without a digest check.' -Level WARN
        }
    } catch {
        Write-Log -Message "GitHub release metadata unavailable for the Marketplace ($($_.Exception.Message)) -- continuing without a digest check." -Level WARN
    }
    Invoke-WithRetry -Label 'Download Marketplace' -Action {

        Invoke-DownloadWithProgress `
            -Uri 'https://github.com/spicetify/marketplace/releases/latest/download/marketplace.zip' `
            -OutFile $zipPath `
            -Label 'Downloading Marketplace' `
            -BasePercent 60 -Weight 10 `
            -TimeoutMs 300000
    }

    if ($null -ne $marketAsset) {
        $zipItem = Get-Item -LiteralPath $zipPath -ErrorAction Stop
        if ($zipItem.Length -ne [long]$marketAsset.size) {
            throw "Marketplace zip size mismatch: expected $([long]$marketAsset.size) bytes from the GitHub manifest, got $($zipItem.Length)."
        }
        $marketDigest = ""
        $marketDigestProp = $marketAsset.PSObject.Properties['digest']
        if ($null -ne $marketDigestProp) { $marketDigest = "$($marketDigestProp.Value)" }
        if ($marketDigest -match '^sha256:([0-9a-fA-F]{64})$') {
            $marketExpected = $Matches[1].ToUpperInvariant()
            $marketActual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($marketActual -ne $marketExpected) {
                throw "Marketplace zip digest mismatch (expected $marketExpected, got $marketActual). Refusing to install."
            }
            Write-Log -Message 'Marketplace zip digest verified against the GitHub release manifest.' -Level INFO
        } else {
            Write-Log -Message 'No sha256 digest on the Marketplace release asset -- size check only.' -Level DEBUG
        }
    }

    if (-not (Test-ZipIntegrity -Path $zipPath)) {
        $size = 0
        try { $size = (Get-Item $zipPath -ErrorAction Stop).Length } catch {}
        if ($size -lt 1024) {
            throw "Downloaded Marketplace file is suspiciously small ($size bytes). URL may have returned an error page."
        }
        throw 'Downloaded Marketplace archive is corrupted'
    }

    Write-Step -Message '  Extracting Marketplace...' -Type STEP
    $extractDir = Join-Path $staging 'extracted'

    if (-not (Test-ZipEntryPaths -Path $zipPath)) {
        throw 'Marketplace archive contains unsafe entry paths (path traversal) -- refusing to extract.'
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'index.js'))) {
        $distDir = Get-ChildItem -LiteralPath $extractDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'index.js') } |
            Select-Object -First 1
        if ($distDir) {
            Write-Step -Message '  Flattening marketplace-dist folder...' -Type STEP
            foreach ($item in @(Get-ChildItem -LiteralPath $distDir.FullName -Force)) {
                Move-Item -LiteralPath $item.FullName -Destination $extractDir -Force
            }
            Remove-Item -LiteralPath $distDir.FullName -Force
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'index.js'))) {
        throw 'Marketplace archive is missing index.js at the expected level -- the upstream layout may have changed.'
    }

    $oldDest = $null
    if (Test-Path -LiteralPath $dest) {
        $destLeaf = Split-Path $dest -Leaf
        $destParent = Split-Path $dest -Parent
        Get-ChildItem -LiteralPath $destParent -Directory -Filter ($destLeaf + '.old_*') -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $oldDest = Join-Path $destParent ($destLeaf + '.old_' + (New-Guid).ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $dest -Destination $oldDest -Force
    }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Move-Item -LiteralPath $extractDir -Destination $dest
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'index.js'))) {
            throw 'Marketplace swap verification failed (index.js missing at destination).'
        }
    } catch {
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($oldDest -and (Test-Path -LiteralPath $oldDest)) {
            Move-Item -LiteralPath $oldDest -Destination $dest -Force
        }
        throw
    }
    if ($oldDest) {
        Remove-Item -LiteralPath $oldDest -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    $null = $Script:TempFiles.Remove($staging)

    Write-Step -Message 'Marketplace installed.' -Type OK
}

function Get-CombinedOutput {
    param($Result)
    $parts = @()
    if ($Result.Stdout) { $parts += $Result.Stdout }
    if ($Result.Stderr) { $parts += $Result.Stderr }
    return ($parts -join "`n")
}

function Test-BackupOutputForRepair {
    param([string]$Output)
    if (-not $Output) { return $false }
    return $Output.ToLowerInvariant() -match 'cannot be backed up|mismatched|failed to backup|re-?install spotify'
}

function Test-ApplyOutputForFailure {

    param([string]$Output, [int]$ExitCode)
    if ($ExitCode -ne 0) {
        $lower = "$Output".ToLowerInvariant()
        if ($lower -match 'mismatched') {
            return @{ Fatal = $true; Reason = 'version_mismatch_repair' }
        }
        return @{ Fatal = $true; Reason = 'non_zero_exit' }
    }
    $lower = "$Output".ToLowerInvariant()
    if ($lower -match "haven't backed up|cannot be backed up|failed to apply") {
        return @{ Fatal = $true; Reason = 'explicit_failure_phrase' }
    }
    return @{ Fatal = $false; Reason = 'ok' }
}

function Invoke-SpicetifyBackupWithRepair {
    [CmdletBinding()]
    param()

    if ($WhatIfPreference) {
        Write-Log -Message 'WhatIf: skipping Spicetify backup (re)creation.' -Level INFO
        return
    }

    $backupDir = $Script:Config.BackupDir
    $oldBackup = $null
    if (Test-Path -LiteralPath $backupDir) {
        $backupLeaf = Split-Path $backupDir -Leaf
        $backupParent = Split-Path $backupDir -Parent

        Get-ChildItem -LiteralPath $backupParent -Directory -Filter ($backupLeaf + '.old_*') -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $oldBackup = Join-Path $backupParent ($backupLeaf + '.old_' + (New-Guid).ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $backupDir -Destination $oldBackup -Force
    }

    $backupSucceeded = $false
    try {
        $r = Invoke-SpicetifyCli 'backup'
        $out = Get-CombinedOutput -Result $r
        if (Test-BackupOutputForRepair -Output $out) {
            Write-Step -Message '  Spotify needs repair. Running repair...' -Type WARN
            Repair-Spotify
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            $r = Invoke-SpicetifyCli 'backup'
            $out = Get-CombinedOutput -Result $r

            if ($r.ExitCode -ne 0) {
                throw "Spicetify backup failed after repair (exit $($r.ExitCode)): $out"
            }
        } elseif ($r.ExitCode -ne 0) {
            throw "Spicetify backup failed (exit $($r.ExitCode)): $out"
        }
        $backupSucceeded = $true
    } finally {
        if ($backupSucceeded -and (Test-Path -LiteralPath $backupDir)) {
            if ($oldBackup) {
                Remove-Item -LiteralPath $oldBackup -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {

            if (Test-Path -LiteralPath $backupDir) {
                Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($oldBackup -and (Test-Path -LiteralPath $oldBackup)) {
                Move-Item -LiteralPath $oldBackup -Destination $backupDir -Force
                Write-Step -Message '  New Spicetify backup failed -- previous backup restored.' -Type WARN
            }
        }
    }
}

function Invoke-SpicetifyApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Applying Spicetify configuration...' -Type STEP

    if (-not $PSCmdlet.ShouldProcess('Spicetify configuration', 'Apply')) {
        return
    }

    Stop-SpotifyProcess
    Wait-ForSpotifyRelease

    Write-Step -Message '  Creating Spicetify backup...' -Type STEP
    Invoke-SpicetifyBackupWithRepair

    Write-Step -Message '  Configuring Marketplace custom app...' -Type STEP
    $configResult = Invoke-SpicetifyCli 'config custom_apps marketplace'
    if ($configResult.ExitCode -ne 0) {
        Write-Log -Message "Marketplace config returned exit $($configResult.ExitCode)" -Level WARN
    }

    $marketplaceThemeDir = Join-Path $Script:Config.AppDataPath 'Themes\marketplace'
    if (-not (Test-Path -LiteralPath $marketplaceThemeDir)) {
        Write-Step -Message '  Creating Marketplace placeholder theme...' -Type STEP
        New-Item -ItemType Directory -Force -Path $marketplaceThemeDir | Out-Null

        $colorIni = @'
[Base]
text               = FFFFFF
subtext            = B3B3B3
main               = 121212
sidebar            = 000000
player             = 181818
card               = 282828
shadow             = 000000
selected-row       = FFFFFF
button             = 1DB954
button-active      = 1DB954
button-disabled    = 535353
tab-active         = FFFFFF
notification       = 1DB954
notification-error = E22134
misc               = B3B3B3
'@
        $colorIniPath = Join-Path $marketplaceThemeDir 'color.ini'
        [System.IO.File]::WriteAllText($colorIniPath, $colorIni, [System.Text.UTF8Encoding]::new($false))
    }

    $iniPath = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'
    $existingTheme = ''
    try {
        $existingTheme = (Get-IniValue -FilePath $iniPath -Section 'Setting' -Key 'current_theme').Trim()
    } catch {
        Write-Log -Message "Could not read current_theme from INI: $($_.Exception.Message)" -Level DEBUG
    }
    if ($existingTheme -eq '') {
        Write-Step -Message '  No theme configured -- applying the Marketplace placeholder theme...' -Type STEP
        $themeResult = Invoke-SpicetifyCli 'config current_theme marketplace'
        if ($themeResult.ExitCode -ne 0) {
            Write-Log -Message "current_theme config returned exit $($themeResult.ExitCode)" -Level WARN
        }
    } else {
        Write-Step -Message "  Preserving the existing theme: $existingTheme" -Type STEP
    }

    Write-Step -Message '  Applying Spicetify customizations...' -Type STEP
    $applyResult = Invoke-SpicetifyCli 'apply'
    $applyOutput = Get-CombinedOutput -Result $applyResult

    $verdict = Test-ApplyOutputForFailure -Output $applyOutput -ExitCode $applyResult.ExitCode

    if ($verdict.Fatal) {
        Write-Step -Message "  Apply failed ($($verdict.Reason)). Running repair..." -Type WARN
        Write-Log -Message "Apply output: $applyOutput" -Level DEBUG

        Repair-Spotify
        Stop-SpotifyProcess -Force
        Wait-ForSpotifyRelease

        Write-Step -Message '  Creating fresh backup after repair...' -Type STEP
        Invoke-SpicetifyBackupWithRepair

        Write-Step -Message '  Retrying apply...' -Type STEP
        $applyResult = Invoke-SpicetifyCli 'apply'
        $applyOutput = Get-CombinedOutput -Result $applyResult
        $verdict = Test-ApplyOutputForFailure -Output $applyOutput -ExitCode $applyResult.ExitCode

        if ($verdict.Fatal) {
            throw "Spicetify apply failed even after repair ($($verdict.Reason), exit $($applyResult.ExitCode)): $applyOutput"
        }
    }

    if ($applyOutput.ToLowerInvariant() -match 'mismatched|version mismatch') {
        Write-Step -Message '  Spotify is newer than Spicetify fully supports. Some features may have issues.' -Type WARN
        Write-Log -Message 'Check for Spicetify update: https://github.com/spicetify/cli/releases' -Level WARN
    }

    Write-Step -Message '  Verifying config INI...' -Type STEP
    try {

        $existingApps = Get-IniValue -FilePath $iniPath -Section 'AdditionalOptions' -Key 'custom_apps'
        $apps = @($existingApps -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($apps -notcontains 'marketplace') { $apps += 'marketplace' }
        Set-IniValue -FilePath $iniPath -Section 'AdditionalOptions' -Key 'custom_apps' -Value ($apps -join '|')

        $themeNow = (Get-IniValue -FilePath $iniPath -Section 'Setting' -Key 'current_theme').Trim()
        if ($themeNow -eq '') {
            Set-IniValue -FilePath $iniPath -Section 'Setting' -Key 'current_theme' -Value 'marketplace'
            $themeNow = 'marketplace'
        }
        Write-Log -Message "INI verified: custom_apps=$($apps -join '|'), current_theme=$themeNow" -Level SUCCESS
    } catch {
        Write-Log -Message "Failed to write INI: $($_.Exception.Message)" -Level WARN
    }

    Write-Step -Message 'Configuration applied.' -Type OK
}

function Start-Phase {
    param([string]$Name)
    $Script:CurrentPhase = $Name
    $Script:PhaseStartTime = [DateTime]::UtcNow
    Write-Log -Message "Entering phase: $Name" -Level INFO
}

function Complete-Phase {
    param([string]$Name, [switch]$Failed)
    if ($null -ne $Script:PhaseStartTime) {
        $elapsed = [DateTime]::UtcNow - $Script:PhaseStartTime
        $Script:PhaseTimings[$Name] = $elapsed
        if ($Failed) {
            Write-Log -Message "Phase $Name FAILED after $([Math]::Round($elapsed.TotalSeconds, 2))s" -Level ERROR
        } else {
            Write-Log -Message "Phase $Name completed in $([Math]::Round($elapsed.TotalSeconds, 2))s" -Level INFO
        }
    }
}

function Invoke-Workflow {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        SuccessSteps = @()
        WarningSteps = @()
    }

    Write-Log -Message "Log file: $($Script:Config.LogFilePath)" -Level INFO

    try {

        Start-Phase 'Init'
        Resolve-SpicetifyConfigPaths
        Complete-Phase 'Init'

        if ($Script:UninstallMode) {
            Start-Phase 'Uninstall'
            Set-Progress -Phase 'Uninstall' -Detail 'Stopping Spotify' -Percent 5

            Set-Step -Name 'Stop Spotify' -State 'Active'
            Assert-NotCancelled
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            Set-Step -Name 'Stop Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify stopped'

            Set-Step -Name 'Backup current' -State 'Active'
            Set-Progress -Phase 'Uninstall' -Detail 'Backing up current customizations' -Percent 15
            Assert-NotCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup current' -State 'Done'
            $result.SuccessSteps += 'Final snapshot preserved'

            Set-Step -Name 'Remove Spicetify' -State 'Active'
            Set-Progress -Phase 'Uninstall' -Detail 'Removing Spicetify' -Percent 40
            Assert-NotCancelled
            Uninstall-Spicetify
            Set-Step -Name 'Remove Spicetify' -State 'Done'
            $result.SuccessSteps += 'Spicetify removed'

            Set-Progress -Phase 'Uninstall' -Detail 'Done' -Percent 100
            Write-Step -Message "Uninstall completed. Customization snapshots kept in $($Script:Config.BackupHistoryDir)" -Type OK
            Complete-Phase 'Uninstall'

        } elseif ($Script:DowngradeMode) {

            Start-Phase 'Downgrade'

            $targetEntry = Get-SpotifyCatalogEntry -Version $Script:DowngradeTarget
            if ($null -eq $targetEntry) {
                Write-Step -Message "  Version not found in the cached catalog -- consulting the live table before refusing." -Type WARN
                try {
                    $null = Get-SpotifyVersionCatalog -Online
                    $targetEntry = Get-SpotifyCatalogEntry -Version $Script:DowngradeTarget
                } catch {
                    Write-Log -Message "Live catalog refresh failed: $($_.Exception.Message)" -Level WARN
                }
            }
            if ($null -eq $targetEntry) {
                throw "Version '$($Script:DowngradeTarget)' is not in the catalog. Use -ListVersions (or the GUI version dialog) to see what is available."
            }
            $targetArch = Get-SpotifyCatalogArch
            $advisories = Get-SpotifyVersionAdvisories -Entry $targetEntry -InstalledVersion (Get-InstalledSpotifyFileVersion) -Arch $targetArch
            if ($advisories.HardBlock) {

                $risksAccepted = $false
                $rv = Get-Variable -Name 'AcceptVersionRisks' -Scope Script -ErrorAction SilentlyContinue
                if ($null -ne $rv -and [bool]$rv.Value) { $risksAccepted = $true }
                if (-not $risksAccepted) {
                    throw "Version $($targetEntry.Short) is blocked for this machine: $($advisories.HardBlock)"
                }
                Write-Step -Message "  Proceeding despite the blocking advisory (explicitly accepted): $($advisories.HardBlock)" -Type WARN
            }
            foreach ($adv in $advisories.Warnings) {
                Write-Step -Message "  Note: $adv" -Type WARN
            }
            Write-Log -Message "Version switch target: $($targetEntry.Full) ($targetArch)" -Level INFO

            if (Test-MicrosoftStoreSpotify) {
                throw 'The Microsoft Store Spotify was detected. Version management targets the per-user desktop Spotify -- uninstall the Store version first.'
            }
            if (-not $Script:SkipPreflight) {
                $dlInfo = Get-SpotifyDownloadInfo -Entry $targetEntry -Arch $targetArch
                $neededTempMB = [int][Math]::Ceiling($dlInfo.ExpectedSize / 1MB) + 128

                $neededAppMB  = [int][Math]::Max(768, [int][Math]::Ceiling(($dlInfo.ExpectedSize / 1MB) * 4) + 256)
                $freeTemp = Get-FreeDiskSpaceMB -Path (Get-TempDir)
                $freeApp  = Get-FreeDiskSpaceMB -Path $Script:AppStateDir
                if (($freeTemp -ge 0 -and $freeTemp -lt $neededTempMB) -or ($freeApp -ge 0 -and $freeApp -lt $neededAppMB)) {
                    throw "Insufficient disk space for the version switch: need ~$neededTempMB MB free in %TEMP% (installer) and ~$neededAppMB MB in %APPDATA% (payload + install); have TEMP=$freeTemp MB, APPDATA=$freeApp MB. Free up space and retry."
                }
                Write-Step -Message "  Disk space OK for the swap (TEMP $freeTemp MB / APPDATA $freeApp MB free)." -Type OK
            }

            if ($WhatIfPreference) {
                Write-Step -Message "  [WhatIf] Would switch Spotify to $($targetEntry.Full) ($targetArch): download + verify + extract + uninstall current + place + reapply Spicetify + set pin. Nothing was changed." -Type INFO
                $result.WarningSteps += "[WhatIf] version switch to $($targetEntry.Short) skipped"
                Complete-Phase 'Downgrade'
                return $result
            }

            $oldStaging = @(Get-ChildItem -LiteralPath $Script:AppStateDir -Directory -Filter 'Staging*' -ErrorAction SilentlyContinue)
            foreach ($old in $oldStaging) {
                $recent = $false
                try {
                    $recent = ((Get-Date) - $old.LastWriteTime).TotalMinutes -lt 10
                } catch { $recent = $false }
                if ($recent) {
                    Write-Log -Message "Leaving recent staging dir alone (may belong to a concurrent run): $($old.FullName)" -Level WARN
                    continue
                }
                try {

                    $null = Save-StagedUserdata -StagingPath $old.FullName -NoRestore
                } catch {
                    Write-Log -Message "Could not rescue userdata in old staging $($old.FullName) -- leaving the directory in place." -Level ERROR
                    continue
                }
                try {
                    Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop
                    Write-Log -Message "Removed stale staging dir: $($old.FullName)" -Level INFO
                } catch {
                    Write-Log -Message "Could not remove stale staging dir $($old.FullName): $($_.Exception.Message)" -Level WARN
                }
            }
            $Script:StagingPath = Join-Path $Script:AppStateDir ("Staging_{0}" -f (New-Guid).ToString('N').Substring(0, 8))

            Set-Step -Name 'Stop Spotify' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Stopping Spotify' -Percent 2
            Assert-NotCancelled
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            Set-Step -Name 'Stop Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify stopped'

            Set-Step -Name 'Backup' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Backing up customizations' -Percent 8
            Assert-NotCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup' -State 'Done'
            $result.SuccessSteps += 'Customizations backed up'

            $Script:PinnedSpotifyVersion = $targetEntry.Short

            Set-Step -Name 'Download' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Downloading target installer' -Percent 10
            Assert-NotCancelled
            $installerPath = Invoke-SpotifyInstallerDownload -Entry $targetEntry -Arch $targetArch -BasePercent 10 -Weight 35
            if (-not $installerPath -or $installerPath -isnot [string] -or -not (Test-Path -LiteralPath $installerPath)) {
                $gotKind = if ($null -eq $installerPath) { 'no value' } else { $installerPath.GetType().Name }
                throw "Installer download did not produce a usable file path (got $gotKind). This is a tool bug -- please report it with the log file."
            }
            Set-Step -Name 'Download' -State 'Done'
            $result.SuccessSteps += "Installer for $($targetEntry.Short) downloaded and verified"

            Set-Step -Name 'Stage' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Extracting and verifying payload' -Percent 50
            Assert-NotCancelled
            $payloadDir = Join-Path $Script:StagingPath 'payload'
            $null = Invoke-SpotifyPayloadExtract -InstallerPath $installerPath -StagingDir $payloadDir -Entry $targetEntry
            Set-Step -Name 'Stage' -State 'Done'
            $result.SuccessSteps += 'Payload extracted and verified'

            Set-Step -Name 'Swap' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Swapping installation' -Percent 60
            Assert-NotCancelled
            Invoke-SpotifyVersionSwap -Entry $targetEntry
            if ($Script:UpdateBlockReapplyFailed) {
                $reapplyNote = 'The update block could not be re-applied after the swap -- run -BlockUpdates (or the header toggle) to restore it.'
                Write-Step -Message "  $reapplyNote" -Type WARN
                $result.WarningSteps += $reapplyNote
                $Script:UpdateBlockReapplyFailed = $false
            }

            $Script:Config.PinnedSpotifyVersion = $targetEntry.Short
            $pinPersisted = $true
            try {
                Save-Config
            } catch {
                $pinPersisted = $false
                $pinMsg = "Version pin could not be persisted to settings: $($_.Exception.Message) -- repairs may use the latest until it is saved."
                Write-Step -Message "  $pinMsg" -Type WARN
                $result.WarningSteps += $pinMsg
            }
            Set-Step -Name 'Swap' -State 'Done'
            $result.SuccessSteps += "Spotify is now version $($targetEntry.Short)"

            Set-Step -Name 'Spicetify' -State 'Active'
            Set-Progress -Phase 'Downgrade' -Detail 'Reapplying Spicetify' -Percent 85
            Assert-NotCancelled
            if (Test-Path -LiteralPath $Script:Config.SpicetifyExePath) {
                try {
                    Stop-SpotifyProcess -Force
                    Wait-ForSpotifyRelease
                    Invoke-SpicetifyBackupWithRepair
                    Invoke-SpicetifyApply
                    $result.SuccessSteps += 'Spicetify backup recreated and config reapplied'
                } catch {

                    $spiceMsg = "Version change complete, but Spicetify could not be reapplied: $($_.Exception.Message)"
                    Write-Step -Message "  $spiceMsg" -Type WARN
                    $result.WarningSteps += $spiceMsg
                    Write-Log -Message 'Run Start or Repair to retry the Spicetify setup against the new version.' -Level WARN
                }
            } else {
                Write-Step -Message '  Spicetify not installed -- skipping reapply.' -Type INFO
                $result.WarningSteps += 'Spicetify not installed -- skipped reapply'
            }
            Set-Step -Name 'Spicetify' -State 'Done'

            Set-Progress -Phase 'Downgrade' -Detail 'Done' -Percent 100

            $pinNote = if ($pinPersisted) { '' } else { ' (version pin NOT persisted -- see the warnings)' }
            Write-Step -Message "Version change to $($targetEntry.Short) completed$pinNote." -Type OK
            Complete-Phase 'Downgrade'

        } elseif ($Script:RepairMode) {
            Set-Step -Name 'Stop Spotify' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Stopping Spotify' -Percent 5
            Start-Phase 'SpotifyInstall'
            Assert-NotCancelled
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease

            if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
                throw 'Spotify is not installed. Cannot repair. Run the full install first.'
            }
            Set-Step -Name 'Stop Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify stopped'
            Complete-Phase 'SpotifyInstall'

            Set-Step -Name 'Backup' -State 'Active'
            Set-Progress -Phase 'Backup' -Detail 'Backing up customizations' -Percent 20
            Start-Phase 'Backup'
            Assert-NotCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup' -State 'Done'
            $result.SuccessSteps += 'Customizations backed up'
            Complete-Phase 'Backup'

            Set-Step -Name 'Repair Spotify' -State 'Active'
            Set-Progress -Phase 'SpotifyInstall' -Detail 'Reinstalling Spotify...' -Percent 25

            Start-Phase 'SpotifyInstall'
            Assert-NotCancelled
            Repair-Spotify
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            Set-Step -Name 'Repair Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify reinstalled'
            Complete-Phase 'SpotifyInstall'

            Set-Step -Name 'Spicetify backup' -State 'Active'
            Set-Progress -Phase 'Apply' -Detail 'Recreating Spicetify backup' -Percent 55
            Start-Phase 'Apply'
            Assert-NotCancelled
            Invoke-SpicetifyBackupWithRepair
            Set-Step -Name 'Spicetify backup' -State 'Done'
            $result.SuccessSteps += 'Spicetify backup recreated'

            Set-Step -Name 'Apply config' -State 'Active'
            Set-Progress -Phase 'Apply' -Detail 'Reapplying Spicetify config' -Percent 70
            Assert-NotCancelled
            Invoke-SpicetifyApply
            Set-Step -Name 'Apply config' -State 'Done'
            $result.SuccessSteps += 'Configuration reapplied'
            Complete-Phase 'Apply'

            Set-Progress -Phase 'Repair' -Detail 'Done' -Percent 100
            Write-Step -Message 'Repair completed.' -Type OK

        } else {
            Set-Step -Name 'Preflight' -State 'Active'
            Set-Progress -Phase 'Preflight' -Detail 'Running pre-flight checks' -Percent 2
            Start-Phase 'Preflight'
            Assert-NotCancelled
            Invoke-PreflightChecks
            Set-Step -Name 'Preflight' -State 'Done'
            $result.SuccessSteps += 'Pre-flight checks passed'
            Complete-Phase 'Preflight'

            Set-Step -Name 'Spotify' -State 'Active'
            Set-Progress -Phase 'Spotify' -Detail 'Checking Spotify' -Percent 5
            Start-Phase 'SpotifyInstall'
            Assert-NotCancelled
            Stop-SpotifyProcess -Force

            if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
                Set-Progress -Phase 'Spotify' -Detail 'Installing Spotify...' -Percent 5
                Install-Spotify
                $result.SuccessSteps += 'Spotify installed'
            } else {
                Write-Step -Message 'Spotify found.' -Type OK
                $result.SuccessSteps += 'Spotify found'
            }
            Set-Step -Name 'Spotify' -State 'Done'
            Complete-Phase 'SpotifyInstall'

            Set-Step -Name 'Backup' -State 'Active'
            Set-Progress -Phase 'Backup' -Detail 'Backing up customizations...' -Percent 20 -IsIndeterminate
            Start-Phase 'Backup'
            Assert-NotCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup' -State 'Done'
            $result.SuccessSteps += 'Customizations backed up (history kept)'
            Complete-Phase 'Backup'

            Set-Step -Name 'Spicetify' -State 'Active'
            Set-Progress -Phase 'Spicetify' -Detail 'Installing Spicetify...' -Percent 30
            Start-Phase 'SpicetifyInstall'
            Assert-NotCancelled
            Install-Spicetify

            if (-not (Test-Path -LiteralPath $Script:Config.SpicetifyExePath)) {
                throw 'Spicetify not installed. Cannot continue.'
            }
            Set-Step -Name 'Spicetify' -State 'Done'
            $result.SuccessSteps += 'Spicetify installed/updated'
            Complete-Phase 'SpicetifyInstall'

            Set-Step -Name 'Marketplace' -State 'Active'
            Set-Progress -Phase 'Marketplace' -Detail 'Installing Marketplace...' -Percent 60
            Start-Phase 'Marketplace'
            Assert-NotCancelled
            Write-Step -Message 'Installing Marketplace...' -Type STEP
            Install-Marketplace
            Set-Step -Name 'Marketplace' -State 'Done'
            $result.SuccessSteps += 'Marketplace installed'
            Complete-Phase 'Marketplace'

            Set-Step -Name 'Restore' -State 'Active'
            Set-Progress -Phase 'Restore' -Detail 'Restoring customizations...' -Percent 75
            Start-Phase 'Restore'
            Assert-NotCancelled
            Restore-UserCustomizations
            Set-Step -Name 'Restore' -State 'Done'
            $result.SuccessSteps += 'Customizations restored'
            Complete-Phase 'Restore'

            Set-Step -Name 'Apply' -State 'Active'
            Set-Progress -Phase 'Apply' -Detail 'Applying configuration...' -Percent 85
            Start-Phase 'Apply'
            Assert-NotCancelled
            Invoke-SpicetifyApply
            Set-Step -Name 'Apply' -State 'Done'
            $result.SuccessSteps += 'Configuration applied'
            Complete-Phase 'Apply'

            Set-Progress -Phase 'Complete' -Detail 'Done' -Percent 100
            Write-Step -Message 'Workflow completed successfully.' -Type OK
        }
    } catch {

        $failName = $Script:WorkerActiveStepName
        if (-not $failName) {
            for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
                if ($Script:WorkflowSteps[$i].State -eq 'Active') {
                    $failName = $Script:WorkflowSteps[$i].Name
                    break
                }
            }
        }
        if ($failName) {
            Set-Step -Name $failName -State 'Fail'
            $Script:WorkerActiveStepName = $null
        }
        for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
            if ($Script:WorkflowSteps[$i].State -eq 'Pending') {
                Set-Step -Name $Script:WorkflowSteps[$i].Name -State 'Skipped'
            }
        }
        if ($null -ne $Script:PhaseStartTime -and $Script:CurrentPhase) {
            Complete-Phase $Script:CurrentPhase -Failed
        }
        throw
    }

    return $result
}

function Update-InstalledStateInfo {
    param($Window)

    $spotifyFound   = $false
    $spicetifyFound = $false
    $spotifyVersion   = 'Not Found'
    $spicetifyVersion = 'Not Found'

    try {
        $spotifyPaths = @(
            "${env:PROGRAMFILES}\Spotify\Spotify.exe"
            "${env:PROGRAMFILES(X86)}\Spotify\Spotify.exe"
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\Spotify.exe"
            "$env:LOCALAPPDATA\Spotify\Spotify.exe"
            "$env:LOCALAPPDATA\Programs\Spotify\Spotify.exe"
            "${env:APPDATA}\Spotify\Spotify.exe"
        )
        foreach ($path in $spotifyPaths) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                $spotifyFound = $true
                try {

                    $spotifyVersion = ((Get-Item -LiteralPath $path).VersionInfo.FileVersion -replace ',', '.')
                    if (-not $spotifyVersion) { $spotifyVersion = 'Installed' }
                } catch {
                    $spotifyVersion = 'Installed'
                }
                break
            }
        }

        try {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'

            $spotifyReg = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
                          Where-Object {
                              $dn = $_.PSObject.Properties['DisplayName']
                              ($null -ne $dn) -and ("$($dn.Value)" -like '*Spotify*')
                          }
            if ($spotifyReg) { $spotifyFound = $true }
        } catch {}

        $spicetifyExePath = $null
        if (Test-Path -LiteralPath $Script:Config.SpicetifyExePath) {
            $spicetifyFound = $true
            $spicetifyExePath = $Script:Config.SpicetifyExePath
        } else {
            try {
                $inPath = Get-Command spicetify -ErrorAction SilentlyContinue
                if ($inPath) {
                    $spicetifyFound = $true
                    $spicetifyExePath = $inPath.Source
                }
            } catch {}
        }
        if (-not $spicetifyFound) {
            foreach ($path in @(
                (Join-Path $env:USERPROFILE '.spicetify\spicetify.exe')
                (Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe')
            )) {
                if (Test-Path -LiteralPath $path) {
                    $spicetifyFound = $true
                    $spicetifyExePath = $path

                    $Script:Config.SpicetifyExePath = $path
                    Write-Log -Message "Adopted existing Spicetify installation at: $path" -Level INFO
                    break
                }
            }
        }

        if ($spicetifyFound -and $spicetifyExePath) {

            $trustedPaths = @(
                $Script:Config.SpicetifyExePath
                (Join-Path $env:USERPROFILE '.spicetify\spicetify.exe')
                (Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe')
            )
            if ($trustedPaths -contains $spicetifyExePath) {
                try {
                    $verOutput = & $spicetifyExePath --version 2>$null
                    if ("$verOutput" -match '\d+\.\d+(\.\d+)?') {
                        $spicetifyVersion = $Matches[0]
                    } else {
                        $spicetifyVersion = 'Installed'
                    }
                } catch {
                    $spicetifyVersion = 'Installed'
                }
            } else {
                $spicetifyVersion = "external ($spicetifyExePath)"
            }
        }
    } catch {
        Write-Log -Message "Detection error: $($_.Exception.Message)" -Level DEBUG
    }

    $pinSuffix = ''
    $activePin = Get-PinnedSpotifyVersion
    if ($activePin) { $pinSuffix = " (pinned $activePin)" }
    $spotifyStatus   = if ($spotifyFound)   { "[OK] v$spotifyVersion$pinSuffix" }   else { '[--] Not Found' }
    $spicetifyStatus = if ($spicetifyFound) { "[OK] v$spicetifyVersion" } else { '[--] Not Found' }

    try {
        if ($spotifyFound -and -not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
            $spotifyStatus = "[OK] v$spotifyVersion$pinSuffix (external; workflow manages %APPDATA%\Spotify)"
        }
    } catch { }
    if ($Window) {
        $Window.Ctrl.TxtInstalledState.Text = "Spotify: $spotifyStatus | Spicetify: $spicetifyStatus"
        Update-UpdateBlockChip -Window $Window
    }

    return [PSCustomObject]@{
        SpotifyFound   = $spotifyFound
        SpicetifyFound = $spicetifyFound
    }
}

function Start-Operation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Last-resort guards inside the completion handler: disposal/UI-re-enable failures must never escape a DispatcherTimer tick -- the whole point of the guarded rewrite.')]
    param(
        [Parameter(Mandatory)][ValidateSet('Full', 'Repair', 'Uninstall', 'Downgrade')][string]$Mode,
        [Parameter(Mandatory)][string]$ConfirmTitle,
        [Parameter(Mandatory)][string]$ConfirmBody
    )

    if ($Script:OperationRunning) { return }

    $w = $Script:MainWindow

    if ([System.Windows.MessageBox]::Show($w, $ConfirmBody, $ConfirmTitle,
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne 'Yes') {
        return
    }

    $Script:UninstallMode        = ($Mode -eq 'Uninstall')
    $Script:RepairMode           = ($Mode -eq 'Repair')
    $Script:DowngradeMode        = ($Mode -eq 'Downgrade')
    $Script:OperationRunning     = $true
    $Script:CurrentPhasePercent  = 0
    $Script:CurrentOpLabel       = $Mode
    $Script:CancellationToken    = [System.Threading.CancellationTokenSource]::new()
    $Script:OperationStartTime   = Get-Date
    $Script:CurrentPhase         = 'Init'

    Initialize-WorkflowSteps -Mode $Mode

    $drop = $null
    while ($Script:LogStream.TryDequeue([ref]$drop)) { }
    while ($Script:StepStream.TryDequeue([ref]$drop)) { }
    while ($Script:ProgressStream.TryDequeue([ref]$drop)) { }

    $w.Ctrl.LogList.Items.Refresh()
    $Script:LogEntries.Clear()
    $w.Ctrl.MainProgress.Value = 0
    $w.Ctrl.TxtProgressPercent.Text = '0%'
    $w.Ctrl.TxtProgressLabel.Text = "Starting $($Mode.ToLowerInvariant())..."
    $w.Ctrl.TxtEta.Text = '--:--'
    $w.Ctrl.TxtPhase.Text = 'Starting'
    $w.Ctrl.TxtDetail.Text = ''

    Set-UiEnabled -Enabled $false

    $startTime = [datetime]::UtcNow
    $Script:OperationUtcStart = $startTime
    $uiTimer = New-UiTimer
    $uiTimer.Start()
    $w | Add-Member -MemberType NoteProperty -Name UiTimer -Value $uiTimer -Force

    try {
        $workerSource = New-WorkerScript
        $Script:RunspaceState = New-WorkerRunspace -WorkerSource $workerSource
    } catch {
        $uiTimer.Stop()
        if ($null -ne $Script:CancellationToken) {
            try { $Script:CancellationToken.Dispose() } catch {
                Write-Log -Message "CancellationToken dispose failed (benign): $($_.Exception.Message)" -Level DEBUG
            }
        }
        $Script:OperationRunning = $false
        $Script:DowngradeMode   = $false
        $Script:DowngradeTarget = ''
        Set-UiEnabled -Enabled $true

        Write-Log -Message "Failed to start the operation worker: $($_.Exception.Message)" -Level ERROR
        $Script:ExitCode = $Script:ExitCodes['Init']
        if (-not $Script:ExitCode) { $Script:ExitCode = 1 }
        $null = [System.Windows.MessageBox]::Show($w,
            "Failed to start the operation worker:`n`n$($_.Exception.Message)",
            'SpicetifyManagerPro',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error)
        return
    }

    if ($null -ne $Script:CompletionTimer) {
        $Script:CompletionTimer.Stop()
    }
    $Script:CompletionTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:CompletionTimer.Interval = [TimeSpan]::FromMilliseconds($Script:COMPLETION_POLL_INTERVAL_MS)
    $Script:CompletionTimer.Add_Tick({
        $w = $Script:MainWindow
        if ($null -eq $w) { return }
        if ($null -eq $Script:RunspaceState -or -not $Script:RunspaceState.Handle.IsCompleted) { return }
        $Script:CompletionTimer.Stop()

        try {
            while (-not $Script:LogStream.IsEmpty) {
                $entry = $null
                if ($Script:LogStream.TryDequeue([ref]$entry)) {
                    $Script:LogEntries.Add((Format-LogEntry -Time $entry.Time -Level $entry.Level -Msg $entry.Msg))
                } else { break }
            }

            $maxLogItems = 5000
            while ($Script:LogEntries.Count -gt $maxLogItems) {
                $Script:LogEntries.RemoveAt(0)
            }
            if ($w.Ctrl.ChkAutoscroll.IsChecked -eq $true -and $Script:LogEntries.Count -gt 0) {
                $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
            }

            while (-not $Script:ProgressStream.IsEmpty) {
                $p = $null
                if ($Script:ProgressStream.TryDequeue([ref]$p)) {
                    if ($p.Phase) {
                        $phaseKey = Get-PhaseExitKey -Phase $p.Phase
                        if ($phaseKey) { $Script:CurrentPhase = $phaseKey }
                        $w.Ctrl.TxtPhase.Text = $p.Phase
                    }
                    if ($p.Detail) { $w.Ctrl.TxtDetail.Text = $p.Detail }
                } else { break }
            }

            while (-not $Script:StepStream.IsEmpty) {
                $s = $null
                if ($Script:StepStream.TryDequeue([ref]$s)) {
                    if ($s.Index -ge 0 -and $s.Index -lt $Script:WorkflowSteps.Count) {
                        Set-StepVisual -Step $Script:WorkflowSteps[$s.Index] -State $s.State
                    }
                } else { break }
            }

            $workerError = $null
            $workerResult = $null
            try {
                $workerResult = $Script:RunspaceState.PowerShell.EndInvoke($Script:RunspaceState.Handle)
            } catch {
                $workerError = $_.Exception.InnerException
                if ($null -eq $workerError) { $workerError = $_.Exception }
            }
            $Script:RunspaceState.PowerShell.Dispose()
            $Script:RunspaceState.Runspace.Close()
            $Script:RunspaceState.Runspace.Dispose()
            $Script:RunspaceState = $null

            foreach ($path in @($Script:TempFiles)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $Script:TempFiles.Clear()

            $opLabel = $Script:CurrentOpLabel

            if ($workerError -and $Script:AbandonRequested) {

                $w.Ctrl.TxtPhase.Text = 'Cancelled'
                $w.Ctrl.TxtDetail.Text = 'Operation abandoned while closing'
                $w.Ctrl.TxtProgressLabel.Text = 'Cancelled'
                $w.Ctrl.TxtEta.Text = 'cancelled'
                $w.Ctrl.MainProgress.IsIndeterminate = $false
            } elseif ($workerError -and $workerError.Message -match 'cancelled by user') {
                $w.Ctrl.TxtPhase.Text = 'Cancelled'
                $w.Ctrl.TxtDetail.Text = 'Operation was cancelled by user'
                $w.Ctrl.TxtProgressLabel.Text = 'Cancelled'
                $w.Ctrl.TxtEta.Text = 'cancelled'
                $w.Ctrl.MainProgress.IsIndeterminate = $false
                $Script:TotalRuns++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - CANCELLED ($opLabel)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Orange
                Save-Stats

                $Script:ExitCode = $Script:ExitCodes['Cancelled']
                $null = [System.Windows.MessageBox]::Show($w,
                    'Operation was cancelled.',
                    'Cancelled',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            } elseif ($workerError) {
                $msg = Get-FriendlyErrorMessage -RawError $workerError.Message
                $w.Ctrl.TxtPhase.Text = 'Failed'
                $w.Ctrl.TxtDetail.Text = $msg
                $w.Ctrl.TxtProgressLabel.Text = "Error: $msg"
                $w.Ctrl.TxtEta.Text = 'failed'
                $w.Ctrl.MainProgress.IsIndeterminate = $false
                $errItem = Format-LogEntry -Time (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') -Level 'ERROR' -Msg $workerError.Message
                $Script:LogEntries.Add($errItem)
                if ($Script:LogEntries.Count -gt 0) {
                    $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
                }
                $Script:TotalRuns++
                $Script:FailureCount++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - FAILED ($opLabel)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Red
                Save-Stats

                $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
                if (-not $phaseCode) { $phaseCode = 1 }
                $Script:ExitCode = $phaseCode
                $null = [System.Windows.MessageBox]::Show($w,
                    "$opLabel failed:`n`n$msg`n`nSee the log panel for details.",
                    'SpicetifyManagerPro',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error)
            } else {
                $w.Ctrl.TxtPhase.Text = 'Complete'
                $w.Ctrl.TxtDetail.Text = ''
                $w.Ctrl.TxtProgressLabel.Text = "$opLabel completed successfully"
                $w.Ctrl.TxtEta.Text = 'done'
                $w.Ctrl.MainProgress.Value = 100
                $w.Ctrl.TxtProgressPercent.Text = '100%'
                $Script:ExitCode = 0

                $duration = (Get-Date) - $Script:OperationStartTime
                $durationStr = "{0:mm\:ss}" -f $duration
                if ($duration.TotalHours -ge 1) {
                    $durationStr = "{0:h\:mm\:ss}" -f $duration
                }
                $Script:TotalRuns++
                $Script:SuccessCount++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - SUCCESS ($opLabel, $durationStr)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Green
                Save-Stats

                $extraNote = if ($opLabel -eq 'Uninstall') {
                    "Your customization snapshots were kept in:`n$($Script:Config.BackupHistoryDir)"
                } else { '' }

                $warnNote = ''
                $warnProp = $null
                if ($workerResult) { $warnProp = $workerResult.PSObject.Properties['WarningSteps'] }
                if ($null -ne $warnProp -and @($warnProp.Value).Count -gt 0) {
                    $warnNote = "`n`nWarnings:`n- " + (@($warnProp.Value) -join "`n- ")
                }

                $null = [System.Windows.MessageBox]::Show($w,
                    "$opLabel completed successfully.$extraNote$warnNote",
                    'SpicetifyManagerPro',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            }

            $null = Update-InstalledStateInfo -Window $w
        } catch {

            Write-Log -Message "Completion handler error: $($_.Exception.Message)" -Level ERROR
            $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
            if (-not $phaseCode) { $phaseCode = 1 }
            if ($Script:ExitCode -eq 0) { $Script:ExitCode = $phaseCode }
        } finally {
            if ($null -ne $Script:RunspaceState) {
                if ($null -ne $Script:RunspaceState.PowerShell) {
                    try { $null = $Script:RunspaceState.PowerShell.EndInvoke($Script:RunspaceState.Handle) } catch { }
                    try { $Script:RunspaceState.PowerShell.Dispose() } catch { }
                }
                try { $Script:RunspaceState.Runspace.Close() } catch { }
                try { $Script:RunspaceState.Runspace.Dispose() } catch { }
                $Script:RunspaceState = $null
            }
            if ($w.UiTimer) { try { $w.UiTimer.Stop() } catch { } }

            if ($Script:CurrentOpLabel -eq 'Downgrade') {
                $Script:DowngradeMode   = $false
                $Script:DowngradeTarget = ''
            }
            $Script:LaunchArmedRepair = $false
            $Script:AbandonRequested  = $false
            $Script:PinnedSpotifyVersion = [string]$Script:Config.PinnedSpotifyVersion
            $Script:OperationRunning = $false
            try { Set-UiEnabled -Enabled $true } catch { }
        }
    })
    $Script:CompletionTimer.Start()
}

function Show-MainWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Abandon-path last-resort guards: cancellation and worker-stop failures must not block the window close the user just confirmed.')]
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    $Script:GUIActive = $true
    $Script:MainWindow = New-MainWindow
    $w = $Script:MainWindow

    $Script:LogEntries = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $w.Ctrl.LogList.ItemsSource = $Script:LogEntries
    $Script:LogView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Script:LogEntries)
    $Script:LogView.Filter = [Predicate[object]]{ param($item) Test-LogEntryVisible -Entry $item }

    $w.Ctrl.StepList.ItemsSource = $Script:WorkflowSteps
    $w.Ctrl.TxtEnvInfo.Text = "PS $($PSVersionTable.PSVersion.ToString())  *  $env:PROCESSOR_ARCHITECTURE"
    $w.Ctrl.TxtVersion.Text = "v$($Script:ScriptVersion)"

    $null = Update-InstalledStateInfo -Window $w
    $w.Ctrl.TxtLastRunStatus.Text = 'Ready'

    $Script:CurrentPhasePercent = 0
    $Script:ProgressStream.Enqueue([PSCustomObject]@{
        Phase = 'Idle'; Detail = ''; Percent = 0; Label = 'Ready'
    }) | Out-Null

    $UpdateMaximizeIcon = {
        $btn = $w.Ctrl.BtnMaximize
        if ($w.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $grid = New-Object System.Windows.Controls.Grid
            $rect1 = New-Object System.Windows.Shapes.Rectangle
            $rect1.Stroke = [System.Windows.Media.Brushes]::White
            $rect1.StrokeThickness = 1.5
            $rect1.Width = 7
            $rect1.Height = 7
            $rect1.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
            $rect2 = New-Object System.Windows.Shapes.Rectangle
            $rect2.Stroke = [System.Windows.Media.Brushes]::White
            $rect2.StrokeThickness = 1.5
            $rect2.Width = 7
            $rect2.Height = 7
            $rect2.Margin = New-Object System.Windows.Thickness(0, 0, 2, 2)
            $null = $grid.Children.Add($rect1)
            $null = $grid.Children.Add($rect2)
            $btn.Content = $grid
        } else {
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Stroke = [System.Windows.Media.Brushes]::White
            $rect.StrokeThickness = 1.5
            $rect.Width = 10
            $rect.Height = 10
            $rect.Fill = [System.Windows.Media.Brushes]::Transparent
            $btn.Content = $rect
        }
    }

    $w.Ctrl.BtnMinimize.Add_Click({
        $w.WindowState = [System.Windows.WindowState]::Minimized
    })

    $w.Ctrl.BtnMaximize.Add_Click({
        if ($w.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $w.WindowState = [System.Windows.WindowState]::Normal
        } else {
            $w.WindowState = [System.Windows.WindowState]::Maximized
        }
        & $UpdateMaximizeIcon
    })

    $w.Ctrl.BtnClose.Add_Click({
        $w.Close()
    })

    $w.Add_StateChanged({
        & $UpdateMaximizeIcon
        Save-WindowState -Window $w
    })

    $w.Ctrl.TxtVersion.Add_MouseLeftButtonUp({
        $successRateLine = if ($Script:TotalRuns -gt 0) {
            '  Success Rate: ' + [Math]::Round(($Script:SuccessCount / $Script:TotalRuns) * 100) + '%'
        } else {
            '  Success Rate: N/A (no runs yet)'
        }
        $aboutMsg = @(
            "SpicetifyManagerPro v$($Script:ScriptVersion)"
            ''
            'A fully automatic Spicetify lifecycle manager.'
            'Features:'
            '  - One-click Spicetify installation'
            '  - Marketplace integration'
            '  - Automatic backup/restore with history'
            '  - Repair and uninstall tools'
            '  - Spotify version management (downgrade / roll-forward)'
            '  - Reversible Spotify auto-update blocking'
            ''
            'Statistics (persisted):'
            "  Total Runs: $Script:TotalRuns"
            "  Successful: $Script:SuccessCount"
            "  Failed:     $Script:FailureCount"
            $successRateLine
            ''
            "Settings: $Script:ConfigPath"
            "Backups:  $($Script:Config.BackupHistoryDir)"
            ''
            'GitHub: https://github.com/Dalbouh02/SpicetifyManagerPro'
            ''
            'Powered by PowerShell + WPF'
        ) -join "`n"

        $null = [System.Windows.MessageBox]::Show($w, $aboutMsg, 'About SpicetifyManagerPro',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $w.Ctrl.BtnStart.Add_Click({

        if ($Script:LaunchArmedRepair) {
            Start-Operation -Mode 'Repair' -ConfirmTitle 'Confirm Repair (reinstall latest)' -ConfirmBody (@(
                'The version pin was cleared -- this repair reinstalls the current latest Spotify.'
                ''
                'Repair mode will:'
                '  1. Stop Spotify'
                '  2. Back up your customizations'
                '  3. Reinstall Spotify (latest release)'
                '  4. Recreate the Spicetify backup'
                '  5. Reapply the Spicetify configuration'
                ''
                'Continue?'
            ) -join "`n")
            return
        }

        if ($Script:DowngradeMode -and $Script:DowngradeTarget) {
            Start-Operation -Mode 'Downgrade' -ConfirmTitle 'Confirm Version Change' -ConfirmBody (@(
                "Switch Spotify to version $($Script:DowngradeTarget)?"
                ''
                'The tool will download and verify that version, swap it in'
                'preserving your login and preferences, then reapply Spicetify.'
                ''
                'Continue?'
            ) -join "`n")
            return
        }
        Start-Operation -Mode 'Full' -ConfirmTitle 'Confirm Installation' -ConfirmBody (@(
            'This will perform the following actions:'
            '  - Download/install Spicetify CLI'
            '  - Download/install Spicetify Marketplace'
            '  - Modify your Spotify installation'
            '  - Back up any existing customizations'
            ''
            'This process may take several minutes.'
            ''
            'Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnRepair.Add_Click({
        Start-Operation -Mode 'Repair' -ConfirmTitle 'Confirm Repair' -ConfirmBody (@(
            'Repair mode will:'
            '  1. Stop Spotify'
            '  2. Back up your customizations'
            '  3. Reinstall Spotify'
            '  4. Recreate the Spicetify backup'
            '  5. Reapply the Spicetify configuration'
            ''
            'Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnUninstall.Add_Click({
        Start-Operation -Mode 'Uninstall' -ConfirmTitle 'Confirm Uninstall' -ConfirmBody (@(
            'Uninstall will:'
            '  1. Stop Spotify'
            '  2. Save a final snapshot of your customizations'
            "     to $($Script:Config.BackupHistoryDir)"
            '  3. Restore Spotify to its pre-Spicetify state'
            '  4. Remove Spicetify CLI, Marketplace, and custom apps'
            '  5. Remove Spicetify from your PATH'
            ''
            'Spotify will remain installed. Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnVersion.Add_Click({
        Show-VersionWindow
    })

    $w.Ctrl.BtnUpdateBlock.Add_Click({
        Invoke-UpdateBlockToggleUi -OwnerWindow $w
    })

    $w.Ctrl.BtnCancel.Add_Click({
        if ($w.Ctrl.BtnCancel.IsEnabled -eq $false) { return }

        $cancelMsg = @(
            'Are you sure you want to cancel?'
            ''
            'Cancelling may leave Spicetify in an incomplete state.'
            'You may need to run Repair afterwards.'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($w, $cancelMsg, 'Confirm Cancellation',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne 'Yes') {
            return
        }

        try {
            $Script:CancellationToken.Cancel()
            $Script:ProgressStream.Enqueue([PSCustomObject]@{
                Phase = 'Cancelling'
                Detail = 'Requesting cancellation... please wait'
                Percent = -1
                IsIndeterminate = $true
            }) | Out-Null
            $w.Ctrl.BtnCancel.IsEnabled = $false
            $w.Ctrl.BtnCancel.Content = '_Cancelling...'
            Write-Log -Message 'Cancellation requested by user.' -Level WARN
        } catch {
            Write-Log -Message "Cancel failed: $($_.Exception.Message)" -Level WARN
        }
    })

    $w.Ctrl.BtnSettings.Add_Click({
        if ($Script:OperationRunning) {
            $null = [System.Windows.MessageBox]::Show($w,
                'Please wait for the current operation to complete before opening Settings.',
                'Operation in Progress',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information)
            return
        }

        $sw = New-SettingsWindow -Owner $w
        $sw.Ctrl.TxtMaxRetries.Text       = "$($Script:Config.MaxRetries)"
        $sw.Ctrl.TxtRetryDelayMs.Text     = "$($Script:Config.RetryDelayMs)"
        $sw.Ctrl.TxtProcessTimeoutMs.Text = "$($Script:Config.ProcessTimeoutMs)"
        $sw.Ctrl.TxtBackupRetention.Text  = "$($Script:Config.BackupRetention)"
        $sw.Ctrl.TxtLogPath.Text          = if ($Script:LogPathCustomized) { $Script:Config.LogFilePath } else { '' }
        $sw.Ctrl.TxtCacheDir.Text         = if ($Script:Config.EnableCache) { $Script:Config.CacheDir } else { 'none' }
        $sw.Ctrl.ChkKeepLog.IsChecked     = [bool]$Script:KeepLog
        $sw.Ctrl.ChkSkipPreflight.IsChecked = [bool]$Script:SkipPreflight

        $sw.Ctrl.BtnCancelSettings.Add_Click({ $sw.Close() })
        $sw.Ctrl.BtnSettingsClose.Add_Click({ $sw.Close() })

        $sw.Ctrl.BtnResetDefaults.Add_Click({
            $sw.Ctrl.TxtMaxRetries.Text       = '3'
            $sw.Ctrl.TxtRetryDelayMs.Text     = '2000'
            $sw.Ctrl.TxtProcessTimeoutMs.Text = '90000'
            $sw.Ctrl.TxtBackupRetention.Text  = '3'
            $sw.Ctrl.TxtLogPath.Text          = ''
            $sw.Ctrl.TxtCacheDir.Text         = ''
            $sw.Ctrl.ChkKeepLog.IsChecked     = $false
            $sw.Ctrl.ChkSkipPreflight.IsChecked = $false
        })

        $sw.Ctrl.BtnSaveSettings.Add_Click({
            $limits = $Script:SettingsLimits
            $errorsFound = @()

            $maxRetries = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtMaxRetries.Text, [ref]$maxRetries)) {
                $errorsFound += 'Max attempts must be a valid number'
            } elseif ($maxRetries -lt $limits.MaxRetriesMin -or $maxRetries -gt $limits.MaxRetriesMax) {
                $errorsFound += "Max attempts must be between $($limits.MaxRetriesMin) and $($limits.MaxRetriesMax) (counting the first try)"
            }

            $retryDelay = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtRetryDelayMs.Text, [ref]$retryDelay)) {
                $errorsFound += 'Retry Delay must be a valid number (milliseconds)'
            } elseif ($retryDelay -lt $limits.RetryDelayMin -or $retryDelay -gt $limits.RetryDelayMax) {
                $errorsFound += "Retry Delay must be between $($limits.RetryDelayMin) and $($limits.RetryDelayMax) ms"
            }

            $procTimeout = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtProcessTimeoutMs.Text, [ref]$procTimeout)) {
                $errorsFound += 'Process Timeout must be a valid number (milliseconds)'
            } elseif ($procTimeout -lt $limits.ProcTimeoutMin -or $procTimeout -gt $limits.ProcTimeoutMax) {
                $errorsFound += "Process Timeout must be between $($limits.ProcTimeoutMin) and $($limits.ProcTimeoutMax) ms"
            }

            $retention = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtBackupRetention.Text, [ref]$retention)) {
                $errorsFound += 'Backup Retention must be a valid number'
            } elseif ($retention -lt $limits.RetentionMin -or $retention -gt $limits.RetentionMax) {
                $errorsFound += "Backup Retention must be between $($limits.RetentionMin) and $($limits.RetentionMax)"
            }

            $logPathInput = $sw.Ctrl.TxtLogPath.Text.Trim()
            if ($logPathInput -ne '' -and $logPathInput -notmatch '^([a-zA-Z]:[\\/]|\\\\)') {
                $errorsFound += 'Log file path must be an absolute path (e.g. C:\logs\spm.log)'
            }

            $cacheInput = $sw.Ctrl.TxtCacheDir.Text.Trim()
            if ($cacheInput -ne '' -and $cacheInput -ine 'none' -and $cacheInput -notmatch '^[a-zA-Z]:\\') {
                $errorsFound += "Cache directory must be an absolute path, or 'none' to disable"
            }

            if ($errorsFound.Count -gt 0) {
                $null = [System.Windows.MessageBox]::Show($sw, ($errorsFound -join "`n"), 'Validation Errors',
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }

            try {
                $Script:Config.MaxRetries       = $maxRetries
                $Script:Config.RetryDelayMs     = $retryDelay
                $Script:Config.ProcessTimeoutMs = $procTimeout
                $Script:Config.BackupRetention  = $retention

                if ($logPathInput -eq '') {

                    $Script:Config.LogFilePath = Join-Path (Get-TempDir) "SpicetifyManagerPro_$(Get-Date -Format 'yyyyMMdd').log"
                    $Script:LogPathCustomized = $false
                } else {
                    $Script:Config.LogFilePath = $logPathInput
                    $Script:LogPathCustomized = $true
                }

                Initialize-LogPath
                $logPathNotice = ''
                if ($logPathInput -ne '' -and $Script:Config.LogFilePath -ne $logPathInput) {

                    $logPathNotice = "`n`nWARNING: the log directory could not be created. The log path fell back to:`n$($Script:Config.LogFilePath)"
                }

                if ($cacheInput -ieq 'none') {
                    $Script:Config.EnableCache = $false
                } else {
                    $Script:Config.EnableCache = $true
                    if ($cacheInput -ne '') {
                        $Script:Config.CacheDir = $cacheInput
                    } else {
                        $Script:Config.CacheDir = Join-Path $env:LOCALAPPDATA 'spicetify\cache'
                    }
                }

                $Script:KeepLog      = [bool]$sw.Ctrl.ChkKeepLog.IsChecked
                $Script:SkipPreflight = [bool]$sw.Ctrl.ChkSkipPreflight.IsChecked

                Save-Config

                $null = [System.Windows.MessageBox]::Show($sw,
                    "Settings saved. They apply to the next operation.$logPathNotice",
                    'Settings', 'OK', 'Information')
                $sw.Close()
            } catch {
                $settingsError = Get-FriendlyErrorMessage -RawError $_.Exception.Message
                $null = [System.Windows.MessageBox]::Show($sw, "Invalid input: $settingsError", 'Settings', 'OK', 'Error')
            }
        })

        $null = $sw.ShowDialog()
    })

    $w.Ctrl.BtnOpenSpicetify.Add_Click({
        $p = $Script:Config.AppDataPath
        if (Test-Path -LiteralPath $p) {

            Start-Process explorer.exe -ArgumentList ('"{0}"' -f $p)
        } else {
            $null = [System.Windows.MessageBox]::Show($w, 'Folder does not exist yet: ' + $p,
                'Open Folder', 'OK', 'Information')
        }
    })

    $w.Ctrl.BtnRestartSpotify.Add_Click({
        $restartMsg = @(
            'This will close and restart Spotify.'
            ''
            'Any unsaved playback state may be lost.'
            ''
            'Continue?'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($w, $restartMsg, 'Confirm Restart',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne 'Yes') {
            return
        }
        try {
            Stop-SpotifyProcess -Force

            Start-Sleep -Milliseconds 1000
            if (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {

                Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Script:Config.SpotifyExePath)
                $null = [System.Windows.MessageBox]::Show($w, 'Spotify restarted.', 'Restart', 'OK', 'Information')
            } else {
                $null = [System.Windows.MessageBox]::Show($w, 'Spotify not found at expected location.',
                    'Restart', 'OK', 'Warning')
            }
        } catch {
            $errorMsg = Get-FriendlyErrorMessage -RawError $_.Exception.Message
            $null = [System.Windows.MessageBox]::Show($w, "Failed: $errorMsg", 'Restart', 'OK', 'Error')
        }
    })

    $w.Ctrl.BtnCopyLog.Add_Click({
        try {
            $sb = [System.Text.StringBuilder]::new()
            foreach ($item in $Script:LogEntries) {
                if (Test-LogEntryVisible -Entry $item) {
                    $null = $sb.AppendLine($item.Line)
                }
            }
            [System.Windows.Clipboard]::SetText($sb.ToString())
            $null = [System.Windows.MessageBox]::Show($w, 'Visible log entries copied to clipboard.',
                'Copy', 'OK', 'Information')
        } catch {
            $null = [System.Windows.MessageBox]::Show($w, 'Copy failed: ' + $_.Exception.Message,
                'Copy', 'OK', 'Error')
        }
    })

    $w.Ctrl.BtnOpenLog.Add_Click({
        if (Test-Path -LiteralPath $Script:Config.LogFilePath) {
            Start-Process notepad.exe -ArgumentList ('"{0}"' -f $Script:Config.LogFilePath)
        } else {
            $null = [System.Windows.MessageBox]::Show($w, 'No log file exists yet.', 'Open Log', 'OK', 'Information')
        }
    })

    $w.Ctrl.BtnExportLog.Add_Click({
        try {
            $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
            $saveDialog.Filter = 'Text Files|*.txt|Log Files|*.log|All Files|*.*'
            $saveDialog.DefaultExt = '.txt'
            $saveDialog.FileName = 'SpicetifyManagerPro_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt'

            if ($saveDialog.ShowDialog($w) -eq $true) {

                $sb = [System.Text.StringBuilder]::new()
                $count = 0
                foreach ($item in $Script:LogEntries) {
                    if (Test-LogEntryVisible -Entry $item) {
                        $null = $sb.AppendLine($item.Line)
                        $count++
                    }
                }
                [System.IO.File]::WriteAllText($saveDialog.FileName, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

                $null = [System.Windows.MessageBox]::Show($w,
                    "Exported $count log entries to:`n$($saveDialog.FileName)",
                    'Export Complete',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            }
        } catch {
            $null = [System.Windows.MessageBox]::Show($w,
                'Failed to export log: ' + $_.Exception.Message,
                'Export Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error)
        }
    })

    $w.Ctrl.TxtLogSearch.Add_TextChanged({
        $Script:LogSearchTerm = $w.Ctrl.TxtLogSearch.Text.Trim()
        if ($null -ne $Script:LogView) { $Script:LogView.Refresh() }
    })

    $w.Ctrl.CmbLogLevelFilter.Add_SelectionChanged({
        $selectedItem = $w.Ctrl.CmbLogLevelFilter.SelectedItem
        if ($selectedItem) {
            $tagValue = $selectedItem.Tag
            $Script:LogLevelFilter = if ($null -ne $tagValue) { $tagValue.ToString() } else { '' }
            if ($null -ne $Script:LogView) { $Script:LogView.Refresh() }
        }
    })

    $w.Add_PreviewKeyDown({
        if ($_.Key -eq 'Escape' -and -not $Script:OperationRunning) {
            $w.Close()
        }
    })

    $w.Add_Closing({
        if ($Script:OperationRunning) {

            $body = @(
                'An operation is still running.'
                ''
                'Abandon it and close? The worker will be stopped immediately;'
                'if it is mid-step, that step may be left incomplete (run a'
                'Repair afterwards).'
            ) -join "`n"
            $choice = [System.Windows.MessageBox]::Show($w, $body, 'Operation in Progress',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($choice -ne 'Yes') {
                $_.Cancel = $true
                $null = [System.Windows.MessageBox]::Show($w,
                    'The window will stay open until the operation finishes or is abandoned.',
                    'Busy', 'OK', 'Information')
                return
            }
            $Script:AbandonRequested = $true
            try { if ($null -ne $Script:CancellationToken) { $Script:CancellationToken.Cancel() } } catch { }
            try {
                if ($null -ne $Script:RunspaceState -and $null -ne $Script:RunspaceState.PowerShell) {
                    $Script:RunspaceState.PowerShell.BeginStop($null, $null)
                }
            } catch { }
            $Script:OperationRunning = $false
            if (-not $Script:ExitCode) {
                $Script:ExitCode = $Script:ExitCodes['Cancelled']
                if (-not $Script:ExitCode) { $Script:ExitCode = 10 }
            }

            $Script:TotalRuns++
            Save-Stats
        }

        Save-WindowState -Window $w -Force
        try { $Script:CancellationToken.Dispose() } catch {}
    })

    $w.Add_Closed({
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Action]{
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }) | Out-Null
    })

    Restore-WindowState -Window $w

    $null = $w.Show()

    $w.Add_LocationChanged({ Save-WindowState -Window $w })
    $w.Add_SizeChanged({ Save-WindowState -Window $w })

    [System.Windows.Threading.Dispatcher]::Run()
}

function Invoke-Diagnostics {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' SpicetifyManagerPro -- Diagnostic Mode' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''

    Write-Host '--- Environment ---' -ForegroundColor Yellow
    Write-Host ('  PowerShell Version:  ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('  PS Edition:          ' + $PSVersionTable.PSEdition)
    Write-Host ('  OS:                  ' + $env:OS)
    Write-Host ('  Architecture:        ' + $env:PROCESSOR_ARCHITECTURE)
    $clrVer = if ($PSVersionTable.ContainsKey('CLRVersion')) { "$($PSVersionTable['CLRVersion'])" } else { '(not available on PS Core)' }
    Write-Host ('  .NET Version:        ' + $clrVer)
    Write-Host ('  Host Name:           ' + $Host.Name)
    Write-Host ('  User Interactive:    ' + [Environment]::UserInteractive)
    $isAdmin = 'unknown'
    try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    Write-Host ('  Is Admin:            ' + $isAdmin)
    Write-Host ''

    Write-Host '--- TLS ---' -ForegroundColor Yellow
    try {
        Write-Host ('  SecurityProtocol:    ' + [Net.ServicePointManager]::SecurityProtocol)
    } catch {
        Write-Host ('  SecurityProtocol:    ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    }
    try {
        $null = [Net.SecurityProtocolType]::Tls13
        Write-Host '  Tls13 available:     Yes'
    } catch {
        Write-Host '  Tls13 available:     No (using Tls12 only)' -ForegroundColor DarkYellow
    }
    Write-Host ''

    Write-Host '--- Paths ---' -ForegroundColor Yellow
    Write-Host ('  APPDATA:             ' + $env:APPDATA)
    Write-Host ('  LOCALAPPDATA:        ' + $env:LOCALAPPDATA)
    Write-Host ('  TEMP:                ' + $env:TEMP)
    Write-Host ('  Settings file:       ' + $Script:ConfigPath)
    Write-Host ('  Stats file:          ' + $Script:StatsPath)
    Write-Host ('  Log file:            ' + $Script:Config.LogFilePath)
    Write-Host ('  Cache dir:           ' + $Script:Config.CacheDir + ' (enabled: ' + $Script:Config.EnableCache + ')')
    Write-Host ('  Backup history:      ' + $Script:Config.BackupHistoryDir)
    Write-Host ('  Spicetify exe:       ' + $Script:Config.SpicetifyExePath)
    Write-Host ('  Spotify exe:         ' + $Script:Config.SpotifyExePath)
    Write-Host ('  Spotify install dir: ' + $Script:Config.SpotifyInstallDir)
    Write-Host ('  Marketplace dest:    ' + $Script:Config.MarketplaceDest)
    Write-Host ''

    Write-Host '--- Disk Space ---' -ForegroundColor Yellow
    $tempFree = Get-FreeDiskSpaceMB -Path (Get-TempDir)
    $appFree  = Get-FreeDiskSpaceMB -Path $env:APPDATA
    Write-Host ('  TEMP drive free:     ' + $tempFree + ' MB')
    Write-Host ('  APPDATA drive free:  ' + $appFree + ' MB')
    Write-Host ('  Minimum required:    ' + $Script:Config.MinDiskSpaceMB + ' MB')
    Write-Host ''

    Write-Host '--- Network ---' -ForegroundColor Yellow
    foreach ($ep in @(
        @{ Name = 'GitHub API';      Url = 'https://api.github.com' }
        @{ Name = 'GitHub download'; Url = 'https://github.com' }
        @{ Name = 'Spotify CDN';     Url = 'https://download.scdn.co' }
    )) {
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Host ('  ' + $ep.Name.PadRight(20) + ' OK (HTTP ' + $resp.StatusCode + ')') -ForegroundColor Green
        } catch {
            $code = 0
            if ($null -ne $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($code -gt 0) {
                Write-Host ('  ' + $ep.Name.PadRight(20) + ' Reachable (HTTP ' + $code + ')') -ForegroundColor DarkYellow
            } else {
                Write-Host ('  ' + $ep.Name.PadRight(20) + ' UNREACHABLE: ' + $_.Exception.Message) -ForegroundColor Red
            }
        }
    }
    Write-Host ''

    Write-Host '--- Spotify ---' -ForegroundColor Yellow
    $desktopSpotify = Test-Path -LiteralPath $Script:Config.SpotifyExePath
    $storeSpotify   = Test-MicrosoftStoreSpotify
    Write-Host ('  Desktop Spotify installed: ' + $desktopSpotify)
    Write-Host ('  Store Spotify installed:   ' + $storeSpotify)
    if ($desktopSpotify) {
        try {
            $ver = (Get-Item $Script:Config.SpotifyExePath).VersionInfo
            Write-Host ('  Spotify version:           ' + $ver.ProductVersion)
        } catch {}
    }
    Write-Host ''

    Write-Host '--- Version Management ---' -ForegroundColor Yellow
    try {
        $diagArch = Get-SpotifyCatalogArch
        Write-Host ('  Native catalog arch:       ' + $diagArch)
        $diagPin = [string]$Script:Config.PinnedSpotifyVersion
        if ($diagPin) {
            Write-Host ('  Version pin:               ' + $diagPin) -ForegroundColor Green
        } else {
            Write-Host '  Version pin:               (none -- latest is used)'
        }
        try {
            $diagCatalog = Get-SpotifyVersionCatalog
            Write-Host ('  Catalog versions:          ' + $diagCatalog.Count + ' (online)')
            if ($diagCatalog.Count -gt 0) {
                Write-Host ('  Newest catalog version:    ' + $diagCatalog[0].Full)
            }
        } catch {
            Write-Host ('  Catalog unavailable:       ' + $_.Exception.Message) -ForegroundColor Red
        }
        $diagBlock = Get-SpotifyUpdateBlockState
        Write-Host ('  Update block:              ' + $(if ($diagBlock.Blocked) { 'ACTIVE (deny ACL)' } else { 'not active' }))
        Write-Host ('  Update dir deny ACL:       ' + $diagBlock.DenyOnUpdateDir)
        Write-Host ('  Roaming Update deny ACL:   ' + $diagBlock.DenyOnRoamingUpdateDir)
        Write-Host ('  Install dir:               ' + $diagBlock.InstallDir)
        Write-Host ('  Install Update deny ACL:   ' + $diagBlock.DenyOnInstallUpdateDir)
        Write-Host ('  Guard files:               ' + @($diagBlock.GuardedFiles).Count)
        if (@($diagBlock.PendingUpdateFiles).Count -gt 0) {
            Write-Host ('  PENDING staged update:     ' + @($diagBlock.PendingUpdateFiles).Count + ' file(s) -- will apply on next launch') -ForegroundColor Yellow
        }

        $diagRescue = @(Get-ChildItem -LiteralPath $Script:AppStateDir -Directory -Filter 'UserdataRescue_*' -ErrorAction SilentlyContinue)
        if ($diagRescue.Count -gt 0) {
            Write-Host '  USERDATA RESCUE DIRS (recover manually):' -ForegroundColor Yellow
            foreach ($rd in $diagRescue) { Write-Host ('    ' + $rd.FullName) -ForegroundColor Yellow }
        }
    } catch {
        Write-Host ('  Version management probe failed: ' + $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''

    Write-Host '--- Spicetify ---' -ForegroundColor Yellow
    $spicetifyInstalled = Test-Path -LiteralPath $Script:Config.SpicetifyExePath
    Write-Host ('  Spicetify installed:  ' + $spicetifyInstalled)
    if ($spicetifyInstalled) {
        try {
            $r = Invoke-ExternalCommand -FilePath $Script:Config.SpicetifyExePath -Arguments '--version' -TimeoutMs 10000
            Write-Host ('  Spicetify version:    ' + $r.Stdout.Trim())
        } catch {
            Write-Host ('  Spicetify version:    ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        }
        $historyCount = 0
        if (Test-Path -LiteralPath $Script:Config.BackupHistoryDir) {
            $historyCount = @(Get-ChildItem -Path $Script:Config.BackupHistoryDir -Directory -Filter 'backup_*').Count
        }
        Write-Host ('  Backup snapshots:     ' + $historyCount + ' (retention: ' + $Script:Config.BackupRetention + ')')
    }
    Write-Host ''

    Write-Host '--- Assemblies ---' -ForegroundColor Yellow
    if ($Script:FailedAssemblies.Count -gt 0) {
        foreach ($asm in $Script:FailedAssemblies) {
            Write-Host ('  ' + $asm.PadRight(40) + ' FAILED TO LOAD (GUI may not start)') -ForegroundColor Red
        }
    } else {
        Write-Host '  All required assemblies loaded OK' -ForegroundColor Green
    }
    Write-Host ''

    Write-Host '--- Config ---' -ForegroundColor Yellow
    Write-Host ('  MaxRetries:        ' + $Script:Config.MaxRetries)
    Write-Host ('  RetryDelayMs:      ' + $Script:Config.RetryDelayMs)
    Write-Host ('  ProcessTimeoutMs:  ' + $Script:Config.ProcessTimeoutMs)
    Write-Host ('  BackupRetention:   ' + $Script:Config.BackupRetention)
    Write-Host ('  EnableCache:       ' + $Script:Config.EnableCache)
    Write-Host ('  MinDiskSpaceMB:    ' + $Script:Config.MinDiskSpaceMB)
    Write-Host ''

    Write-Host '--- Statistics ---' -ForegroundColor Yellow
    Write-Host ('  Total runs:        ' + $Script:TotalRuns)
    Write-Host ('  Successful:        ' + $Script:SuccessCount)
    Write-Host ('  Failed:            ' + $Script:FailureCount)
    Write-Host ''

    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' Diagnostic complete. No changes were made to your system.' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''
}

function Hide-ConsoleWindow {

    try {
        $parentIsExplorer = $false
        try {
            $myPid = $PID
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$myPid" -ErrorAction Stop).ParentProcessId
            $parentName = (Get-Process -Id $parent -ErrorAction Stop).ProcessName
            $parentIsExplorer = ($parentName -ieq 'explorer')
        } catch {

            Write-Log -Message "Console-owner detection failed (keeping console visible): $($_.Exception.Message)" -Level DEBUG
        }
        if (-not $parentIsExplorer) { return }

        if (-not ('SpmWin32.Native' -as [type])) {
            Add-Type -Namespace SpmWin32 -Name Native -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("kernel32.dll")]
            public static extern System.IntPtr GetConsoleWindow();
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction Stop
        }
        $hwnd = [SpmWin32.Native]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {

            [void][SpmWin32.Native]::ShowWindow($hwnd, 0)
        }
    } catch {

    }
}

function Show-ConsoleWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Crash-path best-effort: if the interop cannot be loaded there is no console to show, and throwing here would mask the actual fatal error being reported.')]
    param()

    try {
        if (-not ('SpmWin32.Native' -as [type])) {
            Add-Type -Namespace SpmWin32 -Name Native -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("kernel32.dll")]
            public static extern System.IntPtr GetConsoleWindow();
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction Stop
        }
        $hwnd = [SpmWin32.Native]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {

            [void][SpmWin32.Native]::ShowWindow($hwnd, 5)
        }
    } catch { }
}

function Write-FatalError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    Show-ConsoleWindow

    $crashTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $crashReport = New-Object System.Text.StringBuilder
    $null = $crashReport.AppendLine('=' * 70)
    $null = $crashReport.AppendLine('SpicetifyManagerPro -- CRASH REPORT')
    $null = $crashReport.AppendLine('Time:        ' + $crashTime)
    $null = $crashReport.AppendLine('Phase:       ' + $Script:CurrentPhase)
    $null = $crashReport.AppendLine('PS Version:  ' + $PSVersionTable.PSVersion.ToString())
    $null = $crashReport.AppendLine('OS:          ' + $env:OS)
    $null = $crashReport.AppendLine('Arch:        ' + $env:PROCESSOR_ARCHITECTURE)

    $apartmentInfo = 'unknown'
    try { $apartmentInfo = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString() } catch { $apartmentInfo = 'unknown' }
    $remoteInfo = $false
    try {
        $senderVar = Get-Variable -Name PSSenderInfo -ErrorAction SilentlyContinue
        if ($null -ne $senderVar -and $null -ne $senderVar.Value) { $remoteInfo = $true }
    } catch { $remoteInfo = $false }
    $sessionInfo = 'unknown'
    try { $sessionInfo = [string][System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch { $sessionInfo = 'unknown' }
    $null = $crashReport.AppendLine('Apartment:   ' + $apartmentInfo + '  (GUI requires STA)')
    $null = $crashReport.AppendLine('Remote:      ' + $remoteInfo)
    $null = $crashReport.AppendLine('SessionId:   ' + $sessionInfo + '  (0 = no interactive desktop)')
    $null = $crashReport.AppendLine('Interactive: ' + [Environment]::UserInteractive)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('Error Type:  ' + $ErrorRecord.Exception.GetType().FullName)
    $null = $crashReport.AppendLine('Message:     ' + $ErrorRecord.Exception.Message)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('Script Stack Trace:')
    $null = $crashReport.AppendLine($ErrorRecord.ScriptStackTrace)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('.NET Stack Trace:')
    $null = $crashReport.AppendLine($ErrorRecord.Exception.StackTrace)
    $null = $crashReport.AppendLine('.' * 70)
    $inner = $ErrorRecord.Exception.InnerException
    $depth = 1
    while ($null -ne $inner -and $depth -lt 10) {
        $null = $crashReport.AppendLine("Inner Exception ${depth}:")
        $null = $crashReport.AppendLine('  Type:    ' + $inner.GetType().FullName)
        $null = $crashReport.AppendLine('  Message: ' + $inner.Message)
        $null = $crashReport.AppendLine('')
        $inner = $inner.InnerException
        $depth++
    }
    $null = $crashReport.AppendLine('=' * 70)

    $reportText = $crashReport.ToString()

    try {
        Write-Host '' -ForegroundColor Red
        Write-Host ('=' * 70) -ForegroundColor Red
        Write-Host ' FATAL ERROR' -ForegroundColor Red
        Write-Host ('=' * 70) -ForegroundColor Red
        Write-Host (' Phase:   ' + $Script:CurrentPhase) -ForegroundColor Yellow
        Write-Host (' Error:   ' + $ErrorRecord.Exception.Message) -ForegroundColor Yellow
        Write-Host (' Type:    ' + $ErrorRecord.Exception.GetType().Name) -ForegroundColor DarkYellow
        $innerEx = $ErrorRecord.Exception.InnerException
        $depth = 1
        while ($null -ne $innerEx -and $depth -le 5) {
            Write-Host (" Inner[$depth]: " + $innerEx.Message) -ForegroundColor DarkYellow
            $innerEx = $innerEx.InnerException
            $depth++
        }
        Write-Host '' -ForegroundColor Red
        Write-Host ' Stack Trace:' -ForegroundColor DarkRed
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkGray
        Write-Host ('=' * 70) -ForegroundColor Red
    } catch { }

    $crashLogPath = Join-Path (Get-TempDir) ('SpicetifyManagerPro_CRASH_' + (Get-Date -Format 'yyyyMMdd_HHmmssfff') + '.log')
    try {
        [System.IO.File]::WriteAllText($crashLogPath, $reportText, [System.Text.UTF8Encoding]::new($true))
        Write-Host '' -ForegroundColor Cyan
        Write-Host (' Crash log saved: ' + $crashLogPath) -ForegroundColor Cyan
        Write-Host (' Regular log:     ' + $Script:Config.LogFilePath) -ForegroundColor Cyan
        Write-Host '' -ForegroundColor Cyan
    } catch {
        Write-Host ' Failed to write crash log file.' -ForegroundColor Red
    }

    try {
        $null = Write-Log -Message $reportText -Level ERROR
    } catch { }

    try {

        if (-not [Environment]::UserInteractive -or $NoUI) { return }
        Write-Host ''
        Write-Host ('=' * 70) -ForegroundColor Yellow
        Write-Host ' Window will stay open for 10 seconds so you can copy the log.' -ForegroundColor Yellow
        Write-Host ' Press Ctrl+C to abort now, or wait for the countdown.' -ForegroundColor Gray
        Write-Host ('=' * 70) -ForegroundColor Yellow
        Write-Host ''
        $countdown = 10
        while ($countdown -gt 0) {
            Write-Host -NoNewline ("`r  Closing in {0,2} seconds...  " -f $countdown)
            Start-Sleep -Milliseconds 1000
            $countdown--
        }
        Write-Host ''
    } catch { }
}

function Invoke-FinalCleanup {
    param([int]$ExitCode)

    try { Close-Progress } catch {}

    if (-not $Script:GUIActive -and $ExitCode -ne 0 -and $ExitCode -notin @(1, 2)) {
        try { Stop-SpotifyProcess -Force } catch {}
    }

    if ($Script:StagingPath -and (Test-Path -LiteralPath $Script:StagingPath)) {
        $rescueFailed = $false
        try {
            $null = Save-StagedUserdata -StagingPath $Script:StagingPath
        } catch {
            $rescueFailed = $true
        }
        if ($rescueFailed) {
            Write-Log -Message "Staging $Script:StagingPath left in place: user data could not be fully rescued. Recover it manually." -Level ERROR
        } else {
            Remove-Item -LiteralPath $Script:StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($path in @($Script:TempFiles)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $Script:TempFiles.Clear()

    if ($null -ne $Script:CancellationToken) {
        try { $Script:CancellationToken.Dispose() } catch {}
    }

    if ($ExitCode -eq 0 -and -not $Script:KeepLog -and (Test-Path -LiteralPath $Script:Config.LogFilePath)) {
        Remove-Item -LiteralPath $Script:Config.LogFilePath -Force -ErrorAction SilentlyContinue
    }
}

$Script:InteractiveLaunch = ($Host.Name -eq 'ConsoleHost') -and `
    [Environment]::UserInteractive -and `
    -not $FromLauncher -and `
    -not $NoUI

if ($Uninstall -and $Repair) {
    Write-Host 'Note: both -Uninstall and -Repair were specified -- Uninstall takes precedence.' -ForegroundColor Yellow
}
if (($BlockUpdates -and $UnblockUpdates)) {
    Write-Host 'Note: both -BlockUpdates and -UnblockUpdates were specified -- Unblock takes precedence.' -ForegroundColor Yellow
}

$Script:UninstallMode = [bool]$Uninstall
$Script:RepairMode    = [bool]$Repair
$Script:KeepLog       = [bool]$KeepLog
$Script:SkipPreflight = [bool]$SkipPreflight
$Script:CurrentOpLabel = 'Install'
$Script:DowngradeMode   = $false
$Script:DowngradeTarget = ''

$Script:LaunchArmedRepair   = $false
$Script:AbandonRequested    = $false
$Script:UpdateBlockReapplyFailed = $false
$Script:VersionRisksAccepted = [bool]$AcceptVersionRisks

$Script:WorkerActiveStepName = $null

$Script:ExitReason = $null
$Script:ExitCode   = 0

$guiCriticalAssemblies = @('PresentationFramework', 'PresentationCore', 'WindowsBase')
$missingGuiAssemblies = @($Script:FailedAssemblies | Where-Object { $guiCriticalAssemblies -contains $_ })
if ($missingGuiAssemblies.Count -gt 0 -and -not $NoUI -and -not $Diagnose) {
    [System.Console]::Error.WriteLine('Cannot start: required WPF assemblies failed to load: ' + ($missingGuiAssemblies -join ', '))
    exit 66
}
foreach ($failedAsm in $Script:FailedAssemblies) {
    Write-Log -Message "Assembly failed to load: $failedAsm (GUI may not start)" -Level WARN
}

$boundParamSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($k in $PSBoundParameters.Keys) { $null = $boundParamSet.Add($k) }
Read-Config -BoundParams $boundParamSet
Read-Stats
Initialize-LogPath

$Script:PinnedSpotifyVersion = [string]$Script:Config.PinnedSpotifyVersion

if ($ListVersions) {
    try {
        Invoke-SpotifyVersionList
        $Script:ExitCode = 0
    } catch {
        Write-Host "ERROR listing versions: $($_.Exception.Message)" -ForegroundColor Red
        $Script:ExitCode = $Script:ExitCodes['Downgrade']
    }
    if ($Script:InteractiveLaunch) {
        Write-Host 'Press any key to close...' -ForegroundColor Gray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
    }
    exit $Script:ExitCode
}

if ($BlockUpdates -or $UnblockUpdates) {
    $blockAction = if ($UnblockUpdates) { 'unblock' } else { 'block' }
    try {
        if ($UnblockUpdates) {
            Remove-SpotifyUpdateBlock | Out-Null
        } else {
            Set-SpotifyUpdateBlock | Out-Null
        }
        $Script:ExitCode = 0
    } catch {
        Write-Host "ERROR: could not $blockAction updates: $($_.Exception.Message)" -ForegroundColor Red
        $Script:ExitCode = $Script:ExitCodes['VersionBlock']
    }
    if ($Script:InteractiveLaunch) {
        Write-Host 'Press any key to close...' -ForegroundColor Gray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
    }
    exit $Script:ExitCode
}

if ($DowngradeTo) {
    $downgradeInput = "$DowngradeTo".Trim()
    if ($downgradeInput -ieq 'none' -or $downgradeInput -ieq 'unpin' -or $downgradeInput -ieq 'clear') {
        if ($Script:Config.PinnedSpotifyVersion) {
            $Script:Config.PinnedSpotifyVersion = ''
            $Script:PinnedSpotifyVersion = ''
            $pinSaved = $true
            try { Save-Config } catch {
                $pinSaved = $false
                Write-Host "Note: the pin could not be persisted: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            if ($pinSaved) {
                Write-Host "Version pin cleared. Future repairs install the latest Spotify again." -ForegroundColor Green
            } else {
                Write-Host 'The version pin could NOT be cleared (settings could not be saved) -- it is still active.' -ForegroundColor Red
                exit $Script:ExitCodes['Downgrade']
            }
        } else {
            Write-Host 'No version pin is set -- nothing to clear.' -ForegroundColor Gray
        }
        exit 0
    }
    if ($downgradeInput -ieq 'latest') {
        if ($Script:Config.PinnedSpotifyVersion) {
            $Script:Config.PinnedSpotifyVersion = ''
            $Script:PinnedSpotifyVersion = ''
            try {
                Save-Config
            } catch {
                Write-Host "WARNING: the pin could not be persisted -- the clear may not survive this session: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        Write-Host 'Version pin cleared -- running a repair that reinstalls the latest Spotify.' -ForegroundColor Yellow
        $Script:RepairMode = $true

        $Script:LaunchArmedRepair = $true
    } else {
        $targetEntry = $null
        try {
            $targetEntry = Get-SpotifyCatalogEntry -Version $downgradeInput
        } catch {
            Write-Host "The online catalog is unavailable: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Version switching needs an internet connection. Try again when online, or use -ListVersions to list versions.' -ForegroundColor Yellow
            exit $Script:ExitCodes['Downgrade']
        }
        if ($null -eq $targetEntry) {
            Write-Host "Version '$downgradeInput' is not in the catalog. Use -ListVersions to see available versions." -ForegroundColor Red
            exit $Script:ExitCodes['Downgrade']
        }
        $advisories = Get-SpotifyVersionAdvisories -Entry $targetEntry -InstalledVersion (Get-InstalledSpotifyFileVersion)
        foreach ($adv in $advisories.Warnings) {
            Write-Host "Note: $adv" -ForegroundColor Yellow
        }
        if ($advisories.HardBlock) {
            if (-not $AcceptVersionRisks) {
                Write-Host "REFUSED: $($advisories.HardBlock)" -ForegroundColor Red
                Write-Host 'Run again with -AcceptVersionRisks to proceed anyway.' -ForegroundColor Yellow
                exit $Script:ExitCodes['Downgrade']
            }
            Write-Host 'Proceeding despite the blocking advisory (-AcceptVersionRisks).' -ForegroundColor Yellow
        }
        $Script:DowngradeMode = $true
        $Script:DowngradeTarget = $targetEntry.Short
        $Script:CurrentOpLabel = 'Downgrade'
        if ($Script:UninstallMode) {
            Write-Host 'Note: -Uninstall takes precedence over -DowngradeTo for this run. The version change is skipped.' -ForegroundColor Yellow
            $Script:DowngradeMode = $false
        } elseif ($Script:RepairMode) {
            Write-Host 'Note: -Repair takes precedence over -DowngradeTo for this run. The version change is skipped.' -ForegroundColor Yellow
            $Script:DowngradeMode = $false
        }
    }
}

if ($Diagnose) {
    try {
        Invoke-Diagnostics
        $Script:ExitCode = 0
    } catch {
        Write-Host ''
        Write-Host ('FATAL in diagnostics: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Type: ' + $_.Exception.GetType().FullName) -ForegroundColor DarkYellow
        Write-Host ('Stack: ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
        $Script:ExitCode = 1
    }
    if ($Script:InteractiveLaunch) {
        Write-Host 'Press any key to close...' -ForegroundColor Gray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
    }
    exit $Script:ExitCode
}

if (-not $NoUI) {
    Hide-ConsoleWindow
    $Script:InteractiveLaunch = $false
    try {
        Show-Banner
        Initialize-WorkflowSteps -Mode $(if ($Script:UninstallMode) { 'Uninstall' } elseif ($Script:DowngradeMode) { 'Downgrade' } elseif ($Script:RepairMode) { 'Repair' } else { 'Full' })
        Show-MainWindow

        if ($Script:ExitCode -eq 0) {
            $Script:ExitReason = 'Success'
        } else {
            $Script:ExitReason = "Completed with exit code $($Script:ExitCode)"
        }
    } catch {
        Write-FatalError -ErrorRecord $_
        if ("$($_.Exception.Message)" -match 'cancelled by user') {
            $Script:ExitReason = 'Cancelled by user'
            $Script:ExitCode   = $Script:ExitCodes['Cancelled']
            if (-not $Script:ExitCode) { $Script:ExitCode = 10 }
        } else {
            $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
            if (-not $phaseCode) { $phaseCode = 1 }
            $Script:ExitReason = "Failed at phase: $Script:CurrentPhase"
            $Script:ExitCode   = $phaseCode
        }
        Show-Summary -SuccessSteps @() -WarningSteps @() -ErrorStep $Script:ExitReason
    } finally {
        Invoke-FinalCleanup -ExitCode $Script:ExitCode
        if ($Script:InteractiveLaunch) {
            Write-Host ''
            Write-Host 'Press any key to close...' -ForegroundColor Gray
            try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
        }
        exit $Script:ExitCode
    }
} else {
    Show-Banner

    try {
        $workflowResult = Invoke-Workflow
        if ($null -eq $workflowResult) {
            $workflowResult = [PSCustomObject]@{ SuccessSteps = @(); WarningSteps = @() }
        }
        Show-Summary -SuccessSteps $workflowResult.SuccessSteps -WarningSteps $workflowResult.WarningSteps
        $Script:ExitReason = 'Success'
        $Script:ExitCode   = 0
    } catch {
        Write-FatalError -ErrorRecord $_
        if ("$($_.Exception.Message)" -match 'cancelled by user') {
            $Script:ExitReason = 'Cancelled by user'
            $Script:ExitCode   = $Script:ExitCodes['Cancelled']
            if (-not $Script:ExitCode) { $Script:ExitCode = 10 }
        } else {
            $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
            if (-not $phaseCode) { $phaseCode = 1 }
            $Script:ExitReason = "Failed at phase: $Script:CurrentPhase"
            $Script:ExitCode   = $phaseCode
        }
        Show-Summary -SuccessSteps @() -WarningSteps @() -ErrorStep $Script:ExitReason
    } finally {
        Invoke-FinalCleanup -ExitCode $Script:ExitCode
        if ($Script:InteractiveLaunch) {
            Write-Host ''
            Write-Host 'Press any key to close...' -ForegroundColor Gray
            try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
        }
        exit $Script:ExitCode
    }
}
