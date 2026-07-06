param(
  [string]$Port = "COM4",
  [int]$Baud = 115200,
  [Parameter(Mandatory = $true)][string]$Ssid,
  [string]$Password = "",
  [string]$BridgeUrl = "ws://192.168.127.220:8765/bridge",
  [string]$LogPath = "output\hardware-evidence\first-live-bridge\logs\wifi_provision_serial.log",
  [int]$ReadBackMs = 12000,
  [int]$OpenSettleMs = 3500,
  [switch]$NoDtr,
  [switch]$NoRts,
  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

function ConvertFrom-SecureStringPlain {
  param([securestring]$Value)
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

function ConvertTo-SerialQuotedToken {
  param([string]$Value)
  if ($null -eq $Value) {
    return '""'
  }
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Redact-Line {
  param([string]$Line)
  $redacted = $Line -replace '(?i)(\bpass(?:word)?(?:\s+|=))(?:"(?:\\.|[^"])*"|\S+)', '$1<redacted>'
  $redacted = $redacted -replace '(?i)(\bpsk(?:\s+|=))(?:"(?:\\.|[^"])*"|\S+)', '$1<redacted>'
  return $redacted
}

function Write-LogLine {
  param([string]$Line)
  Write-Host $Line
  Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($Password)) {
  $secure = Read-Host -AsSecureString "Stackchan WiFi password for '$Ssid'"
  $Password = ConvertFrom-SecureStringPlain $secure
}

if ([string]::IsNullOrWhiteSpace($Ssid)) {
  throw "Ssid is required."
}
if ($Ssid.Length -gt 32) {
  throw "Ssid is too long for the firmware store; max 32 characters."
}
if ($Password.Length -gt 64) {
  throw "Password is too long for the firmware store; max 64 characters."
}

$command = "wifi set ssid $(ConvertTo-SerialQuotedToken $Ssid) pass $(ConvertTo-SerialQuotedToken $Password) url $(ConvertTo-SerialQuotedToken $BridgeUrl)"
$redactedCommand = Redact-Line $command

if ($PrintOnly) {
  Write-Host "[wifi-provision] > $redactedCommand"
  exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Set-Content -LiteralPath $LogPath -Value "[wifi-provision] started=$(Get-Date -Format o) port=$Port baud=$Baud bridge=$BridgeUrl" -Encoding UTF8
Write-LogLine "[wifi-provision] > $redactedCommand"

$serial = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$serial.NewLine = "`n"
$serial.ReadTimeout = 250
$serial.WriteTimeout = 1000
$serial.DtrEnable = -not $NoDtr
$serial.RtsEnable = -not $NoRts

$sawWifi = $false
$sawStatus = $false
try {
  $serial.Open()
  Start-Sleep -Milliseconds $OpenSettleMs
  try { [void]$serial.ReadExisting() } catch {}
  $serial.WriteLine($command)
  Start-Sleep -Milliseconds 1000
  $serial.WriteLine("status")

  $deadline = [DateTime]::UtcNow.AddMilliseconds($ReadBackMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 40
    try {
      $text = $serial.ReadExisting()
    } catch {
      break
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
      continue
    }
    foreach ($raw in ($text -split "\r?\n")) {
      $line = $raw.Trim()
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      $redacted = Redact-Line $line
      Write-LogLine "[wifi-provision] < $redacted"
      if ($line -match '^\[wifi\]') {
        $sawWifi = $true
      }
      if ($line -match '^\[(runtime|heartbeat|system)\]') {
        $sawStatus = $true
      }
    }
  }
} finally {
  if ($serial.IsOpen) {
    $serial.Close()
  }
  $serial.Dispose()
}

Write-LogLine "[wifi-provision] saw_wifi=$([int]$sawWifi) saw_status=$([int]$sawStatus)"
if (-not $sawWifi) {
  throw "Did not see a [wifi] result line from Stackchan. Check $LogPath for captured serial output."
}
