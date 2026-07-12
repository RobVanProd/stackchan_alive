param(
  [Parameter(Mandatory = $true)]
  [string]$CandidateManifestPath,
  [string]$Port = "COM4",
  [int]$Baud = 460800,
  [string]$ExpectedSha256 = "",
  [switch]$ConfirmServoRisk,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

function Get-StackchanPythonCandidates {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/python.exe"
  }
  $platformio = Get-StackchanPlatformioCommand
  if (Test-Path -LiteralPath $platformio) {
    $scriptsDir = Split-Path (Resolve-Path $platformio).Path -Parent
    $candidates += Join-Path (Split-Path $scriptsDir -Parent) "python.exe"
  }
  $candidates += @(
    Get-Command python -All -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty Source
  )
  return @(
    $candidates |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_ -notmatch "\\WindowsApps\\python\.exe$" -and
        (Test-Path -LiteralPath $_)
      } |
      Select-Object -Unique
  )
}

function Get-StackchanEsptoolInvocation {
  $coreDir = Get-StackchanPlatformioCoreDir
  $scripts = @()
  if (-not [string]::IsNullOrWhiteSpace($coreDir)) {
    $scripts += Join-Path $coreDir "packages/tool-esptoolpy/esptool.py"
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $scripts += Join-Path $env:USERPROFILE ".platformio/packages/tool-esptoolpy/esptool.py"
  }

  foreach ($python in Get-StackchanPythonCandidates) {
    foreach ($script in @($scripts | Select-Object -Unique)) {
      if (-not (Test-Path -LiteralPath $script)) {
        continue
      }
      try {
        $probe = @(Invoke-StackchanUtf8Process -Command $python -Arguments @($script, "version"))
        if (($probe | Out-String) -match "esptool") {
          return [pscustomobject]@{
            Command = (Resolve-Path $python).Path
            BaseArgs = @((Resolve-Path $script).Path)
          }
        }
      } catch {
        continue
      }
    }
  }
  throw "No usable PlatformIO esptool runtime was found."
}

if (-not $ConfirmServoRisk) {
  throw "Refusing archived production recovery without -ConfirmServoRisk. The image contains servo support even though motion is disabled at boot."
}
if ($Baud -lt 115200 -or $Baud -gt 921600) {
  throw "Baud must be between 115200 and 921600."
}

$manifestPath = (Resolve-Path -LiteralPath $CandidateManifestPath).Path
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "output"))
if (-not $manifestPath.StartsWith($outputRoot + [System.IO.Path]::DirectorySeparatorChar,
                                  [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Archived candidate manifest must be under the repository output directory."
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema -ne "stackchan.firmware-candidate.v1") {
  throw "Unsupported archived candidate schema: $($manifest.schema)"
}
if ([string]$manifest.environment -ne "stackchan_release_forensics") {
  throw "Archived recovery must use stackchan_release_forensics, got: $($manifest.environment)"
}
if ([string]$manifest.deployment_status -ne "not_installed" -or
    -not [bool]$manifest.requires_serial_recovery) {
  throw "Manifest is not marked as an uninstalled serial-recovery candidate."
}

$candidateDir = Split-Path $manifestPath -Parent
$firmwareName = [string]$manifest.firmware_file
if ([string]::IsNullOrWhiteSpace($firmwareName) -or
    [System.IO.Path]::GetFileName($firmwareName) -ne $firmwareName) {
  throw "Manifest firmware_file must be one local filename."
}
$firmwarePath = (Resolve-Path -LiteralPath (Join-Path $candidateDir $firmwareName)).Path
$firmware = Get-Item -LiteralPath $firmwarePath
if ($firmware.Length -lt 100000 -or $firmware.Length -ne [int64]$manifest.firmware_bytes) {
  throw "Archived firmware byte count does not match the manifest."
}
$firmwareStream = [System.IO.File]::OpenRead($firmwarePath)
try {
  if ($firmwareStream.ReadByte() -ne 0xE9) {
    throw "Archived firmware does not begin with the ESP application image magic byte."
  }
} finally {
  $firmwareStream.Dispose()
}
$actualSha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestSha256 = ([string]$manifest.firmware_sha256).ToLowerInvariant()
if ($actualSha256 -ne $manifestSha256) {
  throw "Archived firmware SHA256 does not match its manifest."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
    $actualSha256 -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
  throw "Archived firmware SHA256 does not match -ExpectedSha256."
}

$frameworkRoot = Join-Path $env:USERPROFILE ".platformio/packages/framework-arduinoespressif32"
$bootApp0 = Join-Path $frameworkRoot "tools/partitions/boot_app0.bin"
if (-not (Test-Path -LiteralPath $bootApp0)) {
  throw "Missing canonical OTA selector image: $bootApp0"
}
if ((Get-Item -LiteralPath $bootApp0).Length -ne 8192) {
  throw "Unexpected boot_app0.bin length; refusing to alter OTA selection."
}

if (-not $DryRun -and ([System.IO.Ports.SerialPort]::GetPortNames() -notcontains $Port)) {
  throw "Serial port is not present: $Port"
}

$esptool = Get-StackchanEsptoolInvocation
$arguments = @($esptool.BaseArgs) + @(
  "--chip", "esp32s3",
  "--port", $Port,
  "--baud", [string]$Baud,
  "--before", "default_reset",
  "--after", "hard_reset",
  "write_flash", "-z",
  "--flash_mode", "dio",
  "--flash_freq", "80m",
  "--flash_size", "16MB",
  "0xe000", (Resolve-Path $bootApp0).Path,
  "0x10000", $firmwarePath
)

if ($DryRun) {
  Write-Host "Dry run: $(Format-StackchanCommand (@($esptool.Command) + $arguments))"
} else {
  Write-Host "[recovery] candidate_sha256=$actualSha256 bytes=$($firmware.Length) port=$Port"
  Invoke-StackchanUtf8Process -Command $esptool.Command -Arguments $arguments
  Write-Host "[recovery] flash_verified=1 ota_slot=app0 motion_enabled_at_boot=0"
}

[pscustomobject]@{
  schema = "stackchan.archived-app-flash.v1"
  candidateManifest = $manifestPath
  firmwareSha256 = $actualSha256
  firmwareBytes = $firmware.Length
  port = $Port
  baud = $Baud
  otaSelectorOffset = "0xe000"
  appOffset = "0x10000"
  dryRun = [bool]$DryRun
}
