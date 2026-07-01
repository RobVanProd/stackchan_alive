param(
  [string]$Version,
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if (-not $SkipBuild) {
  platformio run
  python tools/render_preview.py
}

$commit = (git rev-parse HEAD).Trim()
$shortCommit = (git rev-parse --short HEAD).Trim()
$outDir = Join-Path $repoRoot "output/release/$Version"
$zipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"

if (Test-Path -LiteralPath $outDir) {
  Remove-Item -LiteralPath $outDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$firmwareDir = Join-Path $outDir "firmware"
$mediaDir = Join-Path $outDir "media"
$docsDir = Join-Path $outDir "docs"
New-Item -ItemType Directory -Force -Path $firmwareDir, $mediaDir, $docsDir | Out-Null

$firmwareFiles = @(
  ".pio/build/stackchan/firmware.bin",
  ".pio/build/stackchan/firmware.elf",
  ".pio/build/stackchan/bootloader.bin",
  ".pio/build/stackchan/partitions.bin"
)

foreach ($file in $firmwareFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing build artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $firmwareDir
}

$mediaFiles = @(
  "docs/media/stackchan_alive_preview.png",
  "docs/media/stackchan_alive_preview.mp4",
  "docs/media/stackchan_alive_preview.gif"
)

foreach ($file in $mediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing preview artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $mediaDir
}

Copy-Item -LiteralPath "README.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/RELEASE_PROCESS.md" -Destination $docsDir

$manifest = [ordered]@{
  version = $Version
  commit = $commit
  shortCommit = $shortCommit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  board = "m5stack-cores3"
  platformioEnvironment = "stackchan"
  servoDefault = "disabled; STACKCHAN_ENABLE_SERVOS=0"
  status = "device-ready prerelease; hardware validation pending"
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir "release_manifest.json") -Encoding UTF8

@"
# Stackchan Alive $Version

Commit: $commit

This is a device-ready prerelease package. It is built and compile-checked, includes preview media, and keeps servo output disabled by default.

Hardware validation is still required before consumer rollout:

1. Display-only flash and 10-minute idle run.
2. Supervised servo-enable test.
3. Yaw classification and calibration.
4. 30-minute mixed idle/listen/speak soak.
5. USB power-cycle recovery test.

See `docs/DEVICE_BRINGUP.md` and `docs/PRODUCTION_READINESS.md`.
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_NOTES.md") -Encoding UTF8

$hashLines = Get-ChildItem -LiteralPath $outDir -File -Recurse |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object FullName |
  ForEach-Object {
    $relative = $_.FullName.Substring($outDir.Length + 1).Replace("\", "/")
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    "$($hash.Hash.ToLowerInvariant())  $relative"
  }

$hashLines | Set-Content -Path (Join-Path $outDir "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath

Write-Host "Release package:"
Write-Host $outDir
Write-Host $zipPath
