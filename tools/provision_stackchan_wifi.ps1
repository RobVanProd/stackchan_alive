param(
  [string]$Port = "COM4",
  [int]$Baud = 115200,
  [ValidateSet("home", "away")][string]$Profile = "home",
  [string]$Ssid = "",
  [string]$Password = "",
  [string]$BridgeUrl = "ws://192.168.127.220:8765/bridge",
  [string]$AccessClientId = "",
  [string]$AccessClientSecret = "",
  [string]$LogPath = "output\hardware-evidence\first-live-bridge\logs\wifi_provision_serial.log",
  [int]$ReadBackMs = 12000,
  [int]$OpenSettleMs = 3500,
  [switch]$NoDtr,
  [switch]$NoRts,
  [switch]$ActivateOnly,
  [switch]$ClearProfile,
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
  $redacted = $redacted -replace '(?i)(\b(?:access_id|client_id|cf_access_id)(?:\s+|=))(?:"(?:\\.|[^"])*"|\S+)', '$1<redacted>'
  $redacted = $redacted -replace '(?i)(\b(?:access_secret|client_secret|cf_access_secret)(?:\s+|=))(?:"(?:\\.|[^"])*"|\S+)', '$1<redacted>'
  return $redacted
}

function Write-LogLine {
  param([string]$Line)
  Write-Host $Line
  Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

if ($ActivateOnly -and $ClearProfile) {
  throw "ActivateOnly and ClearProfile cannot be used together."
}

if (-not $ActivateOnly -and -not $ClearProfile -and [string]::IsNullOrWhiteSpace($Password)) {
  $secure = Read-Host -AsSecureString "Stackchan WiFi password for '$Ssid'"
  $Password = ConvertFrom-SecureStringPlain $secure
}

if (-not $ActivateOnly -and -not $ClearProfile -and [string]::IsNullOrWhiteSpace($Ssid)) {
  throw "Ssid is required."
}
if ($Ssid.Length -gt 32) {
  throw "Ssid is too long for the firmware store; max 32 characters."
}
if ($Password.Length -gt 64) {
  throw "Password is too long for the firmware store; max 64 characters."
}

$bridgeUri = $null
if (-not $ActivateOnly -and -not $ClearProfile) {
  if (-not [Uri]::TryCreate($BridgeUrl, [UriKind]::Absolute, [ref]$bridgeUri) -or
      $bridgeUri.Scheme -notin @("ws", "wss") -or
      [string]::IsNullOrWhiteSpace($bridgeUri.Host)) {
    throw "BridgeUrl must be an absolute ws:// or wss:// URL."
  }
  if ($Profile -eq "away") {
    if ($bridgeUri.Scheme -ne "wss") {
      throw "The away profile requires a wss:// Cloudflare endpoint."
    }
    $parsedIp = $null
    if ([System.Net.IPAddress]::TryParse($bridgeUri.Host, [ref]$parsedIp)) {
      throw "The away profile requires a TLS hostname, not a numeric IP address."
    }
    if ([string]::IsNullOrWhiteSpace($AccessClientId)) {
      $AccessClientId = Read-Host "Cloudflare Access client ID"
    }
    if ([string]::IsNullOrWhiteSpace($AccessClientSecret)) {
      $secureAccess = Read-Host -AsSecureString "Cloudflare Access client secret"
      $AccessClientSecret = ConvertFrom-SecureStringPlain $secureAccess
    }
    if ([string]::IsNullOrWhiteSpace($AccessClientId) -or
        [string]::IsNullOrWhiteSpace($AccessClientSecret)) {
      throw "The away profile requires both Cloudflare Access credentials."
    }
    if ($AccessClientId.Length -gt 96 -or $AccessClientSecret.Length -gt 96) {
      throw "Cloudflare Access credentials exceed the firmware store limit of 96 characters."
    }
  }
}

$command = if ($ActivateOnly) {
  "wifi use $Profile"
} elseif ($ClearProfile) {
  "wifi clear $Profile"
} elseif ($Profile -eq "away") {
  "wifi set away ssid $(ConvertTo-SerialQuotedToken $Ssid) pass $(ConvertTo-SerialQuotedToken $Password) url $(ConvertTo-SerialQuotedToken $BridgeUrl) access_id $(ConvertTo-SerialQuotedToken $AccessClientId) access_secret $(ConvertTo-SerialQuotedToken $AccessClientSecret)"
} else {
  "wifi set ssid $(ConvertTo-SerialQuotedToken $Ssid) pass $(ConvertTo-SerialQuotedToken $Password) url $(ConvertTo-SerialQuotedToken $BridgeUrl)"
}
$redactedCommand = Redact-Line $command

if ($PrintOnly) {
  Write-Host "[wifi-provision] > $redactedCommand"
  exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Set-Content -LiteralPath $LogPath -Value "[wifi-provision] started=$(Get-Date -Format o) port=$Port baud=$Baud profile=$Profile bridge=$BridgeUrl" -Encoding UTF8
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
