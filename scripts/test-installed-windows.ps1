param([Parameter(Mandatory = $true)][string]$Installer)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content "$ProjectRoot/VERSION" -Raw).Trim()
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs/ChiikawaPet'
$RegistryKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/ChiikawaPet'
if (Test-Path $InstallDirectory) { throw 'Run this installer check on a clean Windows machine or CI runner.' }
$Result = Start-Process -FilePath (Resolve-Path $Installer) -ArgumentList '/S' -Wait -PassThru
if ($Result.ExitCode -ne 0) { throw 'Silent installation failed.' }
$PetProcess = $null
try {
    if ((Get-ItemProperty $RegistryKey).DisplayVersion -ne $Version) { throw 'Installed version mismatch.' }
    foreach ($Name in @('ChiikawaPet.exe', 'README.md', 'README.ko.md', 'LICENSE', 'ARTWORK-NOTICE.md', 'Uninstall.exe')) {
        if (-not (Test-Path (Join-Path $InstallDirectory $Name))) { throw "Installed file missing: $Name" }
    }
    $PetProcess = Start-Process (Join-Path $InstallDirectory 'ChiikawaPet.exe') -ArgumentList '--preview 100 --show-usage' -PassThru
    Start-Sleep -Seconds 3
    if ($PetProcess.HasExited) { throw 'Installed pet exited during preview startup.' }
} finally {
    if ($PetProcess -and -not $PetProcess.HasExited) { Stop-Process -Id $PetProcess.Id; $PetProcess.WaitForExit() }
    Start-Process (Join-Path $InstallDirectory 'Uninstall.exe') -ArgumentList '/S' -Wait
}
for ($Attempt = 0; $Attempt -lt 20 -and ((Test-Path $RegistryKey) -or (Test-Path "$InstallDirectory/ChiikawaPet.exe")); $Attempt++) {
    Start-Sleep -Milliseconds 250
}
if ((Test-Path $RegistryKey) -or (Test-Path "$InstallDirectory/ChiikawaPet.exe")) { throw 'Uninstall did not remove app and registry entry.' }
Write-Host 'Windows installation, preview startup, and uninstall checks passed.'
