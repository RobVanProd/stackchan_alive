param(
  [Parameter(Mandatory = $true)]
  [string]$Device,
  [Parameter(Mandatory = $true)]
  [string]$Firmware,
  [int]$Port = 8790,
  [int]$DebugPort = 8789,
  [int]$RequestTimeoutSec = 45,
  [int]$HealthTimeoutSec = 180,
  [string]$EvidenceRoot = "",
  [ValidateSet("", "stable", "beta")]
  [string]$Channel = "",
  [string]$ChannelManifest = "",
  [switch]$ConfirmUpload,
  [switch]$SkipHealthWait
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

if (-not $ConfirmUpload) {
  throw "LAN OTA changes the running firmware. Re-run with -ConfirmUpload after checking the device is on stable external power and physically clear."
}
if ($Port -lt 1024 -or $Port -gt 65535) {
  throw "Port must be between 1024 and 65535."
}
if ($DebugPort -lt 1024 -or $DebugPort -gt 65535) {
  throw "DebugPort must be between 1024 and 65535."
}
if ($RequestTimeoutSec -lt 10 -or $RequestTimeoutSec -gt 600) {
  throw "RequestTimeoutSec must be between 10 and 600."
}
if ($HealthTimeoutSec -lt 30 -or $HealthTimeoutSec -gt 900) {
  throw "HealthTimeoutSec must be between 30 and 900."
}
if ($Device -notmatch '^[A-Za-z0-9._-]+$') {
  throw "Device must be a LAN hostname or IPv4 address without a URL scheme or path."
}

$firmwarePath = (Resolve-Path -LiteralPath $Firmware).Path
$firmwareInfo = Get-Item -LiteralPath $firmwarePath
if ($firmwareInfo.Length -le 0) {
  throw "Firmware image is empty: $firmwarePath"
}

$channelVerification = $null
$hasChannel = -not [string]::IsNullOrWhiteSpace($Channel)
$hasChannelManifest = -not [string]::IsNullOrWhiteSpace($ChannelManifest)
if ($hasChannel -ne $hasChannelManifest) {
  throw "Channel and ChannelManifest must be supplied together."
}
if ($hasChannel) {
  $manifestPath = (Resolve-Path -LiteralPath $ChannelManifest).Path
  $validatorPath = Join-Path (Split-Path -Parent $PSScriptRoot) "bridge\ota_channels.py"
  if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    throw "OTA channel validator is missing: $validatorPath"
  }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($null -eq $python) {
    throw "Python is required to validate an OTA channel manifest."
  }
  $validatorOutput = @(
    & $python.Source $validatorPath verify `
      --manifest $manifestPath `
      --channel $Channel `
      --firmware $firmwarePath 2>&1
  )
  if ($LASTEXITCODE -ne 0) {
    throw "OTA channel verification failed: $($validatorOutput -join [Environment]::NewLine)"
  }
  try {
    $channelVerification = ($validatorOutput -join [Environment]::NewLine) | ConvertFrom-Json
  } catch {
    throw "OTA channel validator returned invalid JSON: $($validatorOutput -join [Environment]::NewLine)"
  }
  if (-not $channelVerification.ok) {
    throw "OTA channel verification did not report ready."
  }
  Write-Host "Verified OTA channel $Channel version $($channelVerification.version) at source commit $($channelVerification.source_commit)."
}

$token = [Environment]::GetEnvironmentVariable("STACKCHAN_OTA_TOKEN")
if ([string]::IsNullOrEmpty($token)) {
  throw "Set STACKCHAN_OTA_TOKEN in this process environment before running the uploader."
}
$tokenBytes = [Text.Encoding]::UTF8.GetBytes($token)
if ($tokenBytes.Length -lt 32 -or $tokenBytes.Length -gt 128 -or $token -ne $token.Trim()) {
  throw "STACKCHAN_OTA_TOKEN must be 32 to 128 UTF-8 bytes with no leading or trailing whitespace."
}
foreach ($byte in $tokenBytes) {
  if ($byte -lt 0x21 -or $byte -gt 0x7E) {
    throw "STACKCHAN_OTA_TOKEN must contain printable ASCII without spaces."
  }
}

function Test-PrivateAddress {
  param([Net.IPAddress]$Address)

  if ([Net.IPAddress]::IsLoopback($Address)) {
    return $true
  }
  if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
    $bytes = $Address.GetAddressBytes()
    return $bytes[0] -eq 10 -or
      ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
      ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
      ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
  }
  return $Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or
    (($Address.GetAddressBytes()[0] -band 0xFE) -eq 0xFC)
}

$resolvedAddresses = @([Net.Dns]::GetHostAddresses($Device))
$privateAddresses = @($resolvedAddresses | Where-Object { Test-PrivateAddress $_ })
if ($resolvedAddresses.Count -eq 0 -or $privateAddresses.Count -ne $resolvedAddresses.Count) {
  throw "Device must resolve to a private, link-local, or loopback LAN address."
}

$sha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash.ToLowerInvariant()
$baseUri = "http://${Device}:$Port"
$debugBaseUri = "http://${Device}:$DebugPort"
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSec)

function Get-OtaStatus {
  $json = $client.GetStringAsync("$baseUri/status").GetAwaiter().GetResult()
  return $json | ConvertFrom-Json
}

$evidencePath = $null
$evidenceSequence = 0
if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $evidencePath = (New-Item -ItemType Directory -Force -Path $EvidenceRoot).FullName
  [ordered]@{
    schema = "stackchan.lan-ota-upload-evidence.v1"
    generated_at = [DateTime]::UtcNow.ToString("o")
    device = $Device
    ota_port = $Port
    debug_port = $DebugPort
    firmware_file = $firmwareInfo.Name
    firmware_bytes = $firmwareInfo.Length
    firmware_sha256 = $sha256
    channel = if ($null -ne $channelVerification) { $Channel } else { "" }
    channel_version = if ($null -ne $channelVerification) { $channelVerification.version } else { "" }
    channel_source_commit = if ($null -ne $channelVerification) { $channelVerification.source_commit } else { "" }
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidencePath "manifest.json") -Encoding UTF8
}

function Write-OtaEvidencePoll {
  param(
    [string]$Stage,
    [object]$Status = $null,
    [string]$StatusError = ""
  )

  if ($null -eq $evidencePath) {
    return
  }

  $script:evidenceSequence++
  $debug = $null
  $debugError = ""
  try {
    $debugJson = $client.GetStringAsync("$debugBaseUri/debug").GetAwaiter().GetResult()
    $debug = $debugJson | ConvertFrom-Json
  } catch {
    $debugError = $_.Exception.Message
  }

  $record = [ordered]@{
    schema = "stackchan.lan-ota-upload-poll.v1"
    sequence = $script:evidenceSequence
    observed_at = [DateTime]::UtcNow.ToString("o")
    stage = $Stage
    status = $Status
    status_error = $StatusError
    debug = $debug
    debug_error = $debugError
  }
  $name = "poll-{0:D4}.json" -f $script:evidenceSequence
  $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evidencePath $name) -Encoding UTF8
}

try {
  $before = Get-OtaStatus
  Write-OtaEvidencePoll -Stage "preflight" -Status $before
  if (-not $before.enabled) {
    throw "Device OTA endpoint is disabled. Confirm the token-enabled firmware and dedicated port."
  }
  if ($before.upload_active -or $before.health_pending -or -not $before.current_app_confirmed) {
    throw "Device is already uploading, validating, or running an unconfirmed image."
  }

  Write-Host "Uploading $($firmwareInfo.Name) ($($firmwareInfo.Length) bytes, SHA-256 $sha256) to $Device on LAN port $Port."
  $firmwareBytes = [IO.File]::ReadAllBytes($firmwarePath)
  $content = [Net.Http.ByteArrayContent]::new($firmwareBytes)
  $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("application/octet-stream")
  $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$baseUri/firmware")
  $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
  [void]$request.Headers.TryAddWithoutValidation("X-Stackchan-SHA256", $sha256)
  $request.Content = $content
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "OTA upload rejected with HTTP $([int]$response.StatusCode): $responseBody"
    }
    $accepted = $responseBody | ConvertFrom-Json
    if (-not $accepted.ok -or $accepted.sha256 -ne $sha256) {
      throw "Device response did not confirm the uploaded SHA-256."
    }
    Write-OtaEvidencePoll -Stage "upload-accepted" -Status $accepted
  } finally {
    $request.Dispose()
    $content.Dispose()
  }

  if ($SkipHealthWait) {
    Write-Host "Upload accepted; device reboot and health confirmation were not monitored."
    return
  }

  $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSec)
  $lastPhase = "rebooting"
  do {
    Start-Sleep -Seconds 2
    try {
      $status = Get-OtaStatus
    } catch {
      Write-OtaEvidencePoll -Stage "health-poll-unreachable" -StatusError $_.Exception.Message
      continue
    }
    Write-OtaEvidencePoll -Stage "health-poll" -Status $status
    if ($status.expected_sha256 -ne $sha256) {
      continue
    }
    if ($status.phase -ne $lastPhase) {
      Write-Host "OTA phase: $($status.phase)"
      $lastPhase = $status.phase
    }
    if ($status.phase -eq "confirmed" -and $status.current_app_confirmed) {
      Write-Host "OTA confirmed on partition $($status.running_partition)."
      return
    }
    if ($status.phase -in @("rollback_requested", "rolled_back", "failed")) {
      throw "OTA did not pass health validation: phase=$($status.phase), error=$($status.last_error)"
    }
  } while ([DateTime]::UtcNow -lt $deadline)

  throw "Timed out waiting for OTA health confirmation. Query $baseUri/status before taking further action."
} finally {
  if ($null -ne $evidencePath) {
    try {
      $finalStatus = Get-OtaStatus
      Write-OtaEvidencePoll -Stage "final" -Status $finalStatus
    } catch {
      Write-OtaEvidencePoll -Stage "final-unreachable" -StatusError $_.Exception.Message
    }
  }
  [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
  $client.Dispose()
  $handler.Dispose()
}
