param(
  [string]$Port = "COM4",
  [Parameter(Mandatory = $true)][string]$Ssid,
  [string]$Password = "",
  [string]$BridgeHost = "192.168.127.220",
  [int]$BridgePort = 8765,
  [string]$BridgePath = "/bridge"
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

if ([string]::IsNullOrWhiteSpace($Password)) {
  $secure = Read-Host -AsSecureString "Stackchan WiFi password for '$Ssid'"
  $Password = ConvertFrom-SecureStringPlain $secure
}
if ([string]::IsNullOrWhiteSpace($Ssid)) { throw "Ssid is required." }
if ([string]::IsNullOrWhiteSpace($Password)) { throw "Password is required." }
if ([string]::IsNullOrWhiteSpace($BridgeHost)) { throw "BridgeHost is required." }
if ($BridgePort -le 0) { throw "BridgePort must be positive." }
if (-not $BridgePath.StartsWith("/")) { throw "BridgePath must start with /." }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$env:STACKCHAN_WIFI_SSID = $Ssid
$env:STACKCHAN_WIFI_PASSWORD = $Password
$env:STACKCHAN_BRIDGE_HOST = $BridgeHost
$env:STACKCHAN_BRIDGE_PORT = [string]$BridgePort
$env:STACKCHAN_BRIDGE_PATH = $BridgePath

Write-Host "[wifi-flash] Building and uploading stackchan_wifi for SSID '$Ssid' and bridge ws://$BridgeHost`:$BridgePort$BridgePath"
& (Join-Path $PSScriptRoot "flash_device.cmd") -Environment stackchan_wifi -Port $Port
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
