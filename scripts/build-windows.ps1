param([ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content "$ProjectRoot/VERSION" -Raw).Trim()
if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw 'VERSION must contain MAJOR.MINOR.PATCH.'
}
$Destination = Join-Path $ProjectRoot "build/windows/$Runtime"
$Artwork = Join-Path $ProjectRoot 'build/windows-artwork'
& "$PSScriptRoot/render-windows-artwork.ps1" -OutputDirectory $Artwork

dotnet run --project "$ProjectRoot/windows/Checks/Checks.csproj" -c Release
if ($LASTEXITCODE -ne 0) { throw 'Windows logic checks failed.' }
dotnet publish "$ProjectRoot/windows/ChiikawaPet.csproj" -c Release -r $Runtime --self-contained true -o $Destination "-p:ApplicationIcon=$Artwork/AppIcon.ico"
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
Copy-Item "$ProjectRoot/windows/README.md" "$Destination/README.md" -Force
Copy-Item "$ProjectRoot/windows/README.ko.md" "$Destination/README.ko.md" -Force
Copy-Item "$ProjectRoot/LICENSE" "$Destination/LICENSE" -Force
Copy-Item "$ProjectRoot/assets/NOTICE.md" "$Destination/ARTWORK-NOTICE.md" -Force
Copy-Item "$ProjectRoot/VERSION" "$Destination/VERSION" -Force
$ReleaseDirectory = Join-Path $ProjectRoot "build/release/windows/$Version"
New-Item -ItemType Directory -Path $ReleaseDirectory -Force | Out-Null
$Archive = Join-Path $ReleaseDirectory "ChiikawaPet-$Version-$Runtime.zip"
Compress-Archive -Path "$Destination/*" -DestinationPath $Archive -Force
Write-Host "Windows app: $Destination/ChiikawaPet.exe"
Write-Host "Portable ZIP: $Archive"
