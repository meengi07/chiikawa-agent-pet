param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [string]$ScreenshotsDirectory
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content "$ProjectRoot/VERSION" -Raw).Trim()
$Installer = (Resolve-Path $Installer).Path
if (-not $ScreenshotsDirectory) { $ScreenshotsDirectory = Join-Path $ProjectRoot 'build/windows-installer-smoke' }
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs/ChiikawaPet'
$Uninstaller = Join-Path $InstallDirectory 'Uninstall.exe'
$Executable = Join-Path $InstallDirectory 'ChiikawaPet.exe'
$RegistryKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/ChiikawaPet'
$UiProject = Join-Path $ProjectRoot 'checks/windows-ui/UiSmoke.csproj'
$SettingsDirectory = Join-Path $env:LOCALAPPDATA 'ChiikawaPet'
$SettingsPath = Join-Path $SettingsDirectory 'settings.json'
$SettingsDirectoryExisted = Test-Path $SettingsDirectory
$OriginalSettings = $null
if (Test-Path $SettingsPath) { $OriginalSettings = [IO.File]::ReadAllBytes($SettingsPath) }
$SentinelPath = Join-Path $SettingsDirectory ('installer-preservation-' + [Guid]::NewGuid().ToString('N') + '.txt')
$Sentinel = 'Chiikawa installer must preserve preferences outside its owned app directory.'
$Isolation = Join-Path ([IO.Path]::GetTempPath()) ('chiikawa-installer-' + [Guid]::NewGuid().ToString('N'))
$OriginalClaude = $env:CLAUDE_CONFIG_DIR
$OriginalCodex = $env:CODEX_HOME
if ((Test-Path $InstallDirectory) -or (Test-Path $RegistryKey)) { throw 'Run this installer check on a clean Windows machine or CI runner.' }
$RunSubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$StartupName = 'ChiikawaAgentPet'
$OriginalStartup = $null
$OriginalStartupKind = $null
$StartupTouched = $false
$Run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunSubkey)
try {
    if ($null -ne $Run -and $Run.GetValueNames() -contains $StartupName) {
        $OriginalStartup = $Run.GetValue($StartupName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $OriginalStartupKind = $Run.GetValueKind($StartupName)
    }
} finally {
    if ($null -ne $Run) { $Run.Dispose() }
}

function Get-StartupValue {
    $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunSubkey)
    try {
        if ($null -ne $Key) { return $Key.GetValue($StartupName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        return $null
    } finally {
        if ($null -ne $Key) { $Key.Dispose() }
    }
}

function Set-StartupValue([object]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::String) {
    $Key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RunSubkey)
    try { $Key.SetValue($StartupName, $Value, $Kind) }
    finally { $Key.Dispose() }
}

function Assert-Preserved {
    if ([IO.File]::ReadAllText($SentinelPath) -cne $Sentinel) { throw 'Installer removed or changed the preference sentinel.' }
    if ([IO.File]::ReadAllText((Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json')) -cne 'invalid-claude-installer-sentinel') {
        throw 'Installer removed or changed Claude credential sentinel.'
    }
    if ([IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'auth.json')) -cne 'invalid-codex-installer-sentinel') {
        throw 'Installer removed or changed Codex credential sentinel.'
    }
    $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    if ($Settings.Character -ne 'momonga' -or $Settings.Language -ne 'en' -or $Settings.Wanders -ne $false -or $Settings.Scale -ne 0.65) {
        throw 'Installer did not preserve pet preferences.'
    }
}

function Assert-Removed {
    for ($Attempt = 0; $Attempt -lt 80 -and ((Test-Path $RegistryKey) -or (Test-Path $InstallDirectory)); $Attempt++) {
        Start-Sleep -Milliseconds 250
    }
    if ((Test-Path $RegistryKey) -or (Test-Path $InstallDirectory)) { throw 'Uninstall did not remove the app directory and registry entry.' }
    $Shortcuts = Join-Path ([Environment]::GetFolderPath('Programs')) 'Chiikawa Pet'
    if (Test-Path $Shortcuts) { throw 'Uninstall did not remove Start menu shortcuts.' }
}

function Assert-MutexGuard([string]$Path, [switch]$Uninstall) {
    $Guard = [Threading.Mutex]::new($false, 'Local\ChiikawaAgentPet')
    $Blocked = $null
    try {
        $Blocked = Start-Process -FilePath $Path -ArgumentList '/S' -Wait -PassThru
        if ($Uninstall) {
            # NSIS's self-copy launcher can return 0 when the temporary uninstaller aborts.
            if (-not (Test-Path $Executable) -or -not (Test-Path $RegistryKey)) {
                throw 'Blocked uninstall changed the installation.'
            }
        } elseif ($Blocked.ExitCode -eq 0) {
            throw 'Installer ignored the running-pet mutex.'
        }
    } finally {
        if ($null -ne $Blocked) { $Blocked.Dispose() }
        $Guard.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Path $SettingsDirectory -Force | Out-Null
    [IO.File]::WriteAllText($SettingsPath, '{"Language":"en","Character":"momonga","Visible":true,"Wanders":false,"X":160,"Y":160,"Scale":0.65}')
    [IO.File]::WriteAllText($SentinelPath, $Sentinel)
    $env:CLAUDE_CONFIG_DIR = Join-Path $Isolation 'claude'
    $env:CODEX_HOME = Join-Path $Isolation 'codex'
    New-Item -ItemType Directory -Path $env:CLAUDE_CONFIG_DIR, $env:CODEX_HOME -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json'), 'invalid-claude-installer-sentinel')
    [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'auth.json'), 'invalid-codex-installer-sentinel')

    Assert-MutexGuard $Installer
    Assert-Removed
    dotnet run --project $UiProject --configuration Release -- --installer $Installer $ScreenshotsDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Native installation wizard verification failed.' }
    if ((Get-ItemProperty $RegistryKey).DisplayVersion -ne $Version) { throw 'Installed version mismatch.' }
    foreach ($Name in @('ChiikawaPet.exe', 'README.md', 'README.ko.md', 'LICENSE', 'ARTWORK-NOTICE.md', 'Uninstall.exe')) {
        if (-not (Test-Path (Join-Path $InstallDirectory $Name))) { throw "Installed file missing: $Name" }
    }
    Assert-Preserved
    dotnet run --no-build --project $UiProject --configuration Release -- --executable $Executable
    if ($LASTEXITCODE -ne 0) { throw 'Installed executable click/drag verification failed.' }
    Assert-Preserved
    Assert-MutexGuard $Uninstaller -Uninstall
    $BeforeUninstall = [Convert]::ToBase64String([IO.File]::ReadAllBytes($SettingsPath))
    $StartupTouched = $true
    Set-StartupValue ('"' + $Executable + '"')
    dotnet run --no-build --project $UiProject --configuration Release -- --uninstaller $Uninstaller $ScreenshotsDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Native uninstall wizard verification failed.' }
    Assert-Removed
    if ($null -ne (Get-StartupValue)) { throw 'Uninstall left its own launch-at-login registration.' }
    Assert-Preserved
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($SettingsPath)) -cne $BeforeUninstall) { throw 'Uninstall changed saved preference bytes.' }

    $Result = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
    if ($Result.ExitCode -ne 0 -or -not (Test-Path $Executable)) { throw 'Silent installation compatibility failed.' }
    if ((Get-ItemProperty $RegistryKey).DisplayVersion -ne $Version) { throw 'Silent installed version mismatch.' }
    if (Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue) { throw 'Silent installation unexpectedly launched the pet.' }
    Assert-Preserved
    $PortableStartup = '"' + (Join-Path $Isolation 'portable/ChiikawaPet.exe') + '"'
    Set-StartupValue $PortableStartup
    $Result = Start-Process -FilePath $Uninstaller -ArgumentList '/S' -Wait -PassThru
    if ($Result.ExitCode -ne 0) { throw 'Silent uninstall compatibility failed.' }
    Assert-Removed
    if ((Get-StartupValue) -cne $PortableStartup) { throw 'Uninstall removed another portable copy''s launch-at-login registration.' }
    Assert-Preserved
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($SettingsPath)) -cne $BeforeUninstall) { throw 'Silent installation/uninstall changed saved preference bytes.' }
    Write-Host "Windows native wizards, finish launch, installed executable, preservation, mutex and /S checks passed. Screenshots: $ScreenshotsDirectory"
} finally {
    try {
        foreach ($Pet in @(Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue)) {
            if ($Pet.Path -eq $Executable) {
                $Pet.CloseMainWindow() | Out-Null
                if (-not $Pet.WaitForExit(3000)) { $Pet.Kill(); $Pet.WaitForExit() }
            }
            $Pet.Dispose()
        }
        if (Test-Path $Uninstaller) {
            $Cleanup = Start-Process -FilePath $Uninstaller -ArgumentList '/S' -Wait -PassThru
            if ($Cleanup.ExitCode -ne 0) { throw 'Installer smoke cleanup uninstall failed.' }
        }
        Assert-Removed
    } finally {
        try {
            if ($StartupTouched) {
                if ($null -ne $OriginalStartupKind) {
                    Set-StartupValue $OriginalStartup $OriginalStartupKind
                } else {
                    $Run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunSubkey, $true)
                    try { if ($null -ne $Run) { $Run.DeleteValue($StartupName, $false) } }
                    finally { if ($null -ne $Run) { $Run.Dispose() } }
                }
            }
        } finally {
            if ($null -ne $OriginalSettings) { [IO.File]::WriteAllBytes($SettingsPath, $OriginalSettings) }
            elseif (Test-Path $SettingsPath) { Remove-Item $SettingsPath -Force }
            if (Test-Path $SentinelPath) { Remove-Item $SentinelPath -Force }
            if (-not $SettingsDirectoryExisted -and (Test-Path $SettingsDirectory) -and -not (Get-ChildItem $SettingsDirectory -Force)) {
                Remove-Item $SettingsDirectory
            }
            [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $OriginalClaude, 'Process')
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $OriginalCodex, 'Process')
            if (Test-Path $Isolation) { Remove-Item $Isolation -Recurse -Force }
        }
    }
}
