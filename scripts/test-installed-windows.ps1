param([Parameter(Mandatory = $true)][string]$Installer)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content "$ProjectRoot/VERSION" -Raw).Trim()
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs/ChiikawaPet'
$RegistryKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/ChiikawaPet'
if (Test-Path $InstallDirectory) { throw 'Run this installer check on a clean Windows machine or CI runner.' }
$Result = Start-Process -FilePath (Resolve-Path $Installer) -ArgumentList '/S' -Wait -PassThru
if ($Result.ExitCode -ne 0) { throw 'Silent installation failed.' }
try {
    if ((Get-ItemProperty $RegistryKey).DisplayVersion -ne $Version) { throw 'Installed version mismatch.' }
    foreach ($Name in @('ChiikawaPet.exe', 'README.md', 'README.ko.md', 'LICENSE', 'ARTWORK-NOTICE.md', 'Uninstall.exe')) {
        if (-not (Test-Path (Join-Path $InstallDirectory $Name))) { throw "Installed file missing: $Name" }
    }
    dotnet run --project "$ProjectRoot/checks/windows-ui/UiSmoke.csproj" --configuration Release -- --executable "$InstallDirectory/ChiikawaPet.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Installed executable click/drag verification failed.' }
} finally {
    Start-Process (Join-Path $InstallDirectory 'Uninstall.exe') -ArgumentList '/S' -Wait
}
for ($Attempt = 0; $Attempt -lt 20 -and ((Test-Path $RegistryKey) -or (Test-Path "$InstallDirectory/ChiikawaPet.exe")); $Attempt++) {
    Start-Sleep -Milliseconds 250
}
if ((Test-Path $RegistryKey) -or (Test-Path "$InstallDirectory/ChiikawaPet.exe")) { throw 'Uninstall did not remove app and registry entry.' }
Write-Host 'Windows installation, ordinary executable interaction, and uninstall checks passed.'
