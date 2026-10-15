$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot/build-windows.ps1" -Runtime win-x64
$Version = (Get-Content "$ProjectRoot/VERSION" -Raw).Trim()
$Payload = Join-Path $ProjectRoot 'build/windows/win-x64'
$Output = Join-Path $ProjectRoot "build/release/windows/$Version/ChiikawaPet-$Version-win-x64-setup.exe"
$Compiler = Get-Command makensis -ErrorAction SilentlyContinue
if (-not $Compiler) {
    $InstalledCompiler = "${env:ProgramFiles(x86)}/NSIS/makensis.exe"
    if (-not (Test-Path $InstalledCompiler)) { throw 'Install NSIS to create the Windows installer.' }
    $CompilerPath = $InstalledCompiler
} else { $CompilerPath = $Compiler.Source }
& $CompilerPath "/DVERSION=$Version" "/DPAYLOAD=$Payload" "/DOUTPUT=$Output" "$ProjectRoot/windows/installer.nsi"
if ($LASTEXITCODE -ne 0) { throw 'Windows installer build failed.' }
Write-Host "Windows installer: $Output"
