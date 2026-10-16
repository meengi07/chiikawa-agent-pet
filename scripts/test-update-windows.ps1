param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$Signature,
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$PreviousPortable,
    [Parameter(Mandatory = $true)][string]$PreviousInstaller
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
$Signature = (Resolve-Path -LiteralPath $Signature).Path
$Package = (Resolve-Path -LiteralPath $Package).Path
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$PreviousPortable = (Resolve-Path -LiteralPath $PreviousPortable).Path
$PreviousInstaller = (Resolve-Path -LiteralPath $PreviousInstaller).Path
$Version = (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).version
$Cache = Join-Path $env:LOCALAPPDATA 'ChiikawaPet/Updates'
$Settings = Join-Path $env:LOCALAPPDATA 'ChiikawaPet/settings.json'
$InstalledTarget = Join-Path $env:LOCALAPPDATA 'Programs/ChiikawaPet'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ChiikawaPet'
$Root = Join-Path $Cache ('smoke-' + [Guid]::NewGuid().ToString('N'))
$Payload = Join-Path $Root 'trusted-current-payload'
$OriginalSettings = if (Test-Path -LiteralPath $Settings) { [IO.File]::ReadAllBytes($Settings) } else { $null }
$Preferences = '{"Language":"en","Character":"usagi","Scale":0.8,"Visible":true,"Wanders":false,"AutomaticUpdates":false,"X":80,"Y":80}'
$Helpers = [Collections.Generic.List[Diagnostics.Process]]::new()
if ((Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $InstalledTarget) -or (Test-Path $UninstallKey)) {
    throw 'Run update smoke in an isolated Windows account without an installed/running pet.'
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetUpdateSmokeWindows {
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static IntPtr Find(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, _) => {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != (uint)processId || !IsWindowVisible(window)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    public static bool Close(int processId) {
        IntPtr window = Find(processId);
        return window != IntPtr.Zero && PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
New-Item -ItemType Directory -Path $Root -Force | Out-Null
Expand-Archive -LiteralPath $Package -DestinationPath $Payload
$TrustedHelper = Join-Path $Payload 'ChiikawaPet.Updater.exe'
if (!(Test-Path -LiteralPath $TrustedHelper)) { throw 'Official ZIP is missing the native update helper.' }

function Require([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function App-Version([string]$Target) {
    $Info = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Target 'ChiikawaPet.exe'))
    return "$($Info.FileMajorPart).$($Info.FileMinorPart).$($Info.FileBuildPart)"
}
function Stop-Pet {
    foreach ($Pet in Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue) {
        $null = [PetUpdateSmokeWindows]::Close($Pet.Id)
        if (!$Pet.WaitForExit(10000)) { $Pet.Kill(); $Pet.WaitForExit() }
    }
}
function Start-Pet([string]$Target) {
    [IO.File]::WriteAllText($Settings, $Preferences)
    $Pet = Start-Process -FilePath (Join-Path $Target 'ChiikawaPet.exe') -WorkingDirectory $Target -PassThru
    Start-Sleep -Milliseconds 1800
    $Pet.Refresh()
    Require (!$Pet.HasExited) 'Previous real app did not start.'
    return $Pet
}
function Assert-Preferences {
    $Saved = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json
    Require ($Saved.Language -eq 'en' -and $Saved.Character -eq 'usagi' -and $Saved.Scale -eq 0.8 -and !$Saved.Wanders -and !$Saved.AutomaticUpdates) 'Update changed saved preferences.'
}
function New-Session([string]$Target, [bool]$Installed, [Diagnostics.Process]$Pet, [string]$Asset) {
    $Session = Join-Path $Cache ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Session | Out-Null
    Copy-Item -LiteralPath $Manifest -Destination (Join-Path $Session 'updates.json')
    Copy-Item -LiteralPath $Signature -Destination (Join-Path $Session 'updates.sig')
    $LocalPackage = Join-Path $Session ([IO.Path]::GetFileName($Asset))
    Copy-Item -LiteralPath $Asset -Destination $LocalPackage
    Copy-Item -LiteralPath $TrustedHelper -Destination (Join-Path $Session 'ChiikawaPet.Updater.exe')
    $Request = @{
        target = $Target; currentVersion = (App-Version $Target); version = $Version; installed = $Installed
        processId = $Pet.Id; processStart = $Pet.StartTime.ToUniversalTime().Ticks; package = $LocalPackage
    }
    [IO.File]::WriteAllText((Join-Path $Session 'request.json'), ($Request | ConvertTo-Json -Compress))
    return $Session
}
function Start-Helper([string]$Session) {
    $Helper = Start-Process -FilePath (Join-Path $Session 'ChiikawaPet.Updater.exe') -ArgumentList ('"' + (Join-Path $Session 'request.json') + '"') -WorkingDirectory $Session -PassThru -WindowStyle Hidden
    $script:Helpers.Add($Helper)
    return $Helper
}
function Wait-Prepared([string]$Session, [Diagnostics.Process]$Helper) {
    $Deadline = [DateTime]::UtcNow.AddMinutes(2)
    while (!(Test-Path -LiteralPath (Join-Path $Session 'prepared'))) {
        $Helper.Refresh()
        if ($Helper.HasExited) { throw "Helper rejected valid signed update: $(Get-Content (Join-Path $Session 'error') -Raw -ErrorAction SilentlyContinue)" }
        if ([DateTime]::UtcNow -gt $Deadline) { throw 'Helper preparation timed out.' }
        Start-Sleep -Milliseconds 100
    }
}
function Assert-Rejection([string]$Target, [bool]$Installed, [string]$Asset, [string]$Kind) {
    $Pet = Start-Pet $Target
    $Before = (Get-FileHash -LiteralPath (Join-Path $Target 'ChiikawaPet.exe') -Algorithm SHA256).Hash
    $Session = New-Session $Target $Installed $Pet $Asset
    if ($Kind -eq 'signature') { [IO.File]::WriteAllText((Join-Path $Session 'updates.sig'), 'invalid-signature') }
    if ($Kind -eq 'hash') {
        $LocalPackage = Join-Path $Session ([IO.Path]::GetFileName($Asset))
        $Stream = [IO.File]::Open($LocalPackage, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        try { $Byte = $Stream.ReadByte(); $Stream.Position = 0; $Stream.WriteByte($Byte -bxor 1) } finally { $Stream.Dispose() }
    }
    if ($Kind -eq 'version') {
        $RequestPath = Join-Path $Session 'request.json'
        $Request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
        $Request.version = $Request.currentVersion
        [IO.File]::WriteAllText($RequestPath, ($Request | ConvertTo-Json -Compress))
    }
    if ($Kind -eq 'target') {
        $RequestPath = Join-Path $Session 'request.json'
        $Request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
        $Request.target = Split-Path $Target -Parent
        [IO.File]::WriteAllText($RequestPath, ($Request | ConvertTo-Json -Compress))
    }
    $Helper = Start-Helper $Session
    Require ($Helper.WaitForExit(30000)) "Invalid $Kind update did not terminate."
    $Helper.Refresh(); $Pet.Refresh()
    Require ($Helper.ExitCode -ne 0 -and !$Pet.HasExited) "Invalid $Kind update stopped the current app."
    Require (!(Test-Path -LiteralPath (Join-Path $Session 'prepared'))) "Invalid $Kind update was prepared."
    Require ((Get-FileHash -LiteralPath (Join-Path $Target 'ChiikawaPet.exe') -Algorithm SHA256).Hash -eq $Before) "Invalid $Kind update modified the current executable."
    Assert-Preferences
    Stop-Pet
    Remove-Item -LiteralPath $Session -Recurse -Force
    Write-Host "PASS $Kind rejection: current app stayed running and intact."
}
function Apply-Update([string]$Target, [bool]$Installed, [string]$Asset, [bool]$Rollback) {
    $PreviousVersion = App-Version $Target
    $Pet = Start-Pet $Target
    $Session = New-Session $Target $Installed $Pet $Asset
    $Helper = Start-Helper $Session
    Wait-Prepared $Session $Helper
    if (!$Rollback) {
        [IO.File]::WriteAllText((Join-Path $Session 'commit'), 'apply')
        Start-Sleep -Milliseconds 500
        Require ((App-Version $Target) -eq $PreviousVersion -and !$Pet.HasExited) 'Helper modified the target before the old process exited.'
    }
    Require ([PetUpdateSmokeWindows]::Close($Pet.Id)) 'Could not request old-process exit.'
    Require ($Pet.WaitForExit(15000)) 'Old app did not release its executable and mutex.'
    if ($Rollback) { [IO.File]::WriteAllText($Settings, '{malformed-settings') }
    [IO.File]::WriteAllText((Join-Path $Session 'commit'), 'apply')
    if ($Rollback) {
        # A real startup failure: signed new app cannot read malformed settings and never acknowledges readiness.
        $Deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            $Candidate = Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $Pet.Id -and [PetUpdateSmokeWindows]::Find($_.Id) -ne [IntPtr]::Zero }
            if ([DateTime]::UtcNow -gt $Deadline) { throw 'Expected new-app startup error was not visible.' }
            Start-Sleep -Milliseconds 100
        } while (!$Candidate)
        [IO.File]::WriteAllText($Settings, $Preferences)
    }
    Require ($Helper.WaitForExit(240000)) 'Apply helper timed out.'
    $Helper.Refresh()
    $Result = Get-Content -LiteralPath (Join-Path $Session 'result') -Raw
    $Expected = if ($Rollback) { $PreviousVersion } else { $Version }
    Require ((App-Version $Target) -eq $Expected) 'Target version after apply/rollback is incorrect.'
    Require (($Rollback -and $Helper.ExitCode -ne 0 -and $Result -eq 'rolled back') -or (!$Rollback -and $Helper.ExitCode -eq 0 -and $Result -eq "updated $Version")) "Unexpected helper outcome: $Result"
    $Running = @(Get-Process -Name ChiikawaPet -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $Target 'ChiikawaPet.exe') })
    Require ($Running.Count -eq 1 -and $Running[0].Id -ne $Pet.Id) 'Exactly one app did not restart from the original target path.'
    if (!$Rollback) { Require (Test-Path -LiteralPath (Join-Path $Session 'started')) 'New app never acknowledged startup.' }
    if ($Installed) { Require ((Get-ItemProperty $UninstallKey).DisplayVersion -eq $Expected) 'Uninstall registry version was not applied/restored.' }
    if (!$Installed) { Require ((Get-Content -LiteralPath (Join-Path $Target 'unrelated.txt') -Raw) -eq 'user-owned sentinel') 'Portable update changed an unrelated user file.' }
    Assert-Preferences
    Stop-Pet
    Remove-Item -LiteralPath $Session -Recurse -Force
    Write-Host "PASS installed=$Installed rollback=${Rollback}: real verified replacement, process restart, registry and preferences."
}
try {
    $Portable = Join-Path $Root 'Portable space Ω'
    Expand-Archive -LiteralPath $PreviousPortable -DestinationPath $Portable
    $InventoryName = '.chiikawa-managed-files.json'
    $LegacyInventory = @(Get-ChildItem -LiteralPath $Portable -Recurse -File | ForEach-Object { $_.FullName.Substring($Portable.Length + 1).Replace('\', '/') })
    if (!(Test-Path -LiteralPath (Join-Path $Portable $InventoryName))) {
        $LegacyInventory += $InventoryName
        [IO.File]::WriteAllText((Join-Path $Portable $InventoryName), (ConvertTo-Json -InputObject $LegacyInventory -Compress))
    }
    [IO.File]::WriteAllText((Join-Path $Portable 'unrelated.txt'), 'user-owned sentinel')
    foreach ($Kind in @('signature', 'hash', 'version', 'target')) { Assert-Rejection $Portable $false $Package $Kind }
    Apply-Update $Portable $false $Package $true
    Apply-Update $Portable $false $Package $false
    $Setup = Start-Process -FilePath $PreviousInstaller -ArgumentList '/S' -Wait -PassThru
    Require ($Setup.ExitCode -eq 0) 'Previous installer failed.'
    foreach ($Kind in @('signature', 'hash', 'version', 'target')) { Assert-Rejection $InstalledTarget $true $Installer $Kind }
    Apply-Update $InstalledTarget $true $Installer $true
    Apply-Update $InstalledTarget $true $Installer $false
} finally {
    foreach ($Helper in $Helpers) {
        $Helper.Refresh()
        if (!$Helper.HasExited) { $Helper.Kill(); $Helper.WaitForExit() }
    }
    Stop-Pet
    if (Test-Path -LiteralPath (Join-Path $InstalledTarget 'Uninstall.exe')) {
        Start-Process -FilePath (Join-Path $InstalledTarget 'Uninstall.exe') -ArgumentList '/S' -Wait | Out-Null
    }
    if ($null -ne $OriginalSettings) { [IO.File]::WriteAllBytes($Settings, $OriginalSettings) }
    elseif (Test-Path -LiteralPath $Settings) { Remove-Item -LiteralPath $Settings -Force }
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
