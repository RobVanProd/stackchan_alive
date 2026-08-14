param(
  [string]$Port = "COM4",
  [Parameter(Mandatory = $true)][string]$Ssid,
  [string]$BridgeHost = "192.168.127.220",
  [int]$BridgePort = 8765,
  [string]$BridgePath = "/bridge",
  [switch]$ConfirmServoRisk
)

# Builds, archives, and USB-flashes the stackchan_release_forensics_vision
# candidate (camera + host vision, motion off at boot). Private values are
# read from a secure prompt and the ignored pairing file; they are never
# echoed and never written into the archived manifest.

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

if (-not $ConfirmServoRisk) {
  throw "This firmware enables motor output capability (motion stays off at boot). Clear the body, supervise, and re-run with -ConfirmServoRisk."
}

function ConvertFrom-SecureStringPlain {
  param([securestring]$Value)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$secure = Read-Host -AsSecureString "Stackchan WiFi password for '$Ssid'"
$password = ConvertFrom-SecureStringPlain $secure
if ([string]::IsNullOrWhiteSpace($password)) { throw "Password is required." }

$pairingFile = Join-Path $repoRoot "output\private\camera-pairing-code.txt"
$pairingCode = ""
if (Test-Path -LiteralPath $pairingFile) {
  $pairingCode = (Get-Content -LiteralPath $pairingFile -Raw).Trim()
  Write-Host "[vision-flash] Pairing code loaded from ignored private file (not displayed)."
} else {
  Write-Warning "No pairing file at output\private\camera-pairing-code.txt; camera pairing will use the firmware default."
}

$env:STACKCHAN_WIFI_SSID = $Ssid
$env:STACKCHAN_WIFI_PASSWORD = $password
$env:STACKCHAN_BRIDGE_HOST = $BridgeHost
$env:STACKCHAN_BRIDGE_PORT = [string]$BridgePort
$env:STACKCHAN_BRIDGE_PATH = $BridgePath
if ($pairingCode) { $env:STACKCHAN_PAIRING_SHORT_CODE = $pairingCode }

$commit = (& git rev-parse --short=8 HEAD).Trim()
$dirty = [bool](& git status --porcelain)
Write-Host "[vision-flash] Building stackchan_release_forensics_vision from $commit (dirty=$dirty)"

$buildArgs = @("run", "-e", "stackchan_release_forensics_vision")
Invoke-StackchanPlatformio @buildArgs
if ($LASTEXITCODE -ne 0) { throw "Build failed." }

$buildDir = ".pio\build\stackchan_release_forensics_vision"
$fwPath = Join-Path $buildDir "firmware.bin"
$fwHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fwPath).Hash.ToLowerInvariant()
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archive = "output\private\firmware-candidates\aliveness-vision-$commit-$stamp"
New-Item -ItemType Directory -Force $archive | Out-Null
foreach ($name in @("firmware.bin", "firmware.elf", "firmware.map", "bootloader.bin", "partitions.bin")) {
  Copy-Item (Join-Path $buildDir $name) $archive
}
$bootApp0 = Join-Path $env:USERPROFILE ".platformio\packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin"
if (Test-Path -LiteralPath $bootApp0) { Copy-Item $bootApp0 $archive }
Get-ChildItem $archive -File | ForEach-Object {
  "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant(), $_.Name
} | Set-Content -Encoding utf8 (Join-Path $archive "SHA256SUMS.txt")
@{
  schema = "stackchan.private-firmware-candidate.v1"
  status = "built-pre-flash"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  sourceCommit = (& git rev-parse HEAD).Trim()
  sourceBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
  sourceClean = (-not $dirty)
  environment = "stackchan_release_forensics_vision"
  firmwareSha256 = $fwHash
  firmwareBytes = (Get-Item $fwPath).Length
  motionEnabledAtBoot = $false
  autonomousMotionAtBoot = $false
  wifiCredentialsConfigured = $true
  pairingCodeConfigured = [bool]$pairingCode
  privateValuesIncludedInManifest = $false
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $archive "manifest-built.json")

Write-Host ""
Write-Host "[vision-flash] firmware SHA-256: $fwHash"
Write-Host "[vision-flash] archived to: $archive"
Write-Host "[vision-flash] Flashing over $Port ..."

$uploadArgs = @("run", "-e", "stackchan_release_forensics_vision", "--target", "upload", "--upload-port", $Port)
Invoke-StackchanPlatformio @uploadArgs
if ($LASTEXITCODE -ne 0) { throw "Upload failed. The archived candidate is intact; check the USB cable/port and re-run." }

Write-Host ""
Write-Host "[vision-flash] Done. Record this in the evidence log:"
Write-Host "  installed firmware SHA-256 = $fwHash"
Write-Host "  source commit             = $commit"
