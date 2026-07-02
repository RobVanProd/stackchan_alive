param(
  [string]$Version,
  [int]$Port = 8787,
  [string]$BindAddress = "127.0.0.1",
  [switch]$Lan,
  [switch]$CloudflareTunnel,
  [switch]$DownloadCloudflared,
  [int]$TunnelWaitSeconds = 30,
  [int]$PublicUrlReadyWaitSeconds = 120,
  [int]$PublicUrlReadyPollSeconds = 2,
  [switch]$StopAfterUrl,
  [switch]$OpenLocal,
  [switch]$NoServe
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Assert-Command {
  param([string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "Required command is not available on PATH: $Name"
  }
}

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }
}

function Get-ReleaseManifest {
  param([string]$RootPath)

  $manifestPath = Join-Path $RootPath "release_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Invoke-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git @Arguments 2>$null
  } catch {
    return ""
  }
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
  return ($output | Out-String).Trim()
}

function Write-ShareStatus {
  param(
    [string]$Status,
    [string]$PublicUrl = "",
    [bool]$PublicUrlReady = $false,
    [int[]]$ProcessIds = @(),
    [string[]]$LanUrls = @()
  )

  if ($LanUrls.Count -eq 0 -and $null -ne $script:ShareLanUrls) {
    $LanUrls = @($script:ShareLanUrls)
  }

  $lanDiagnostics = if ($null -ne $script:ShareLanDiagnostics) { @($script:ShareLanDiagnostics) } else { @() }
  $hostProbeResults = if ($null -ne $script:ShareUrlProbeResults) { @($script:ShareUrlProbeResults) } else { @() }

  $statusObject = [ordered]@{
    version = $Version
    status = $Status
    generatedUtc = $generatedUtc
    updatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    bindAddress = $BindAddress
    loopbackUrl = "http://127.0.0.1`:$Port/"
    localUrl = $script:ShareProbeUrl
    lanUrls = @($LanUrls)
    lanDiagnostics = @($lanDiagnostics)
    hostProbeResults = @($hostProbeResults)
    lanTroubleshooting = "LAN_TROUBLESHOOTING.md"
    shareProbeReport = "share_probe_report.json"
    openLocalShare = "OPEN_LOCAL_SHARE.cmd"
    openLocalRequested = [bool]$OpenLocal
    publicUrl = $PublicUrl
    publicUrlReady = $PublicUrlReady
    processIds = @($ProcessIds)
    shareRoot = $shareRoot
  }

  $statusObject | ConvertTo-Json -Depth 7 | Set-Content -Path (Join-Path $shareRoot "share_status.json") -Encoding UTF8
  if (-not [string]::IsNullOrWhiteSpace($PublicUrl)) {
    $PublicUrl | Set-Content -Path (Join-Path $shareRoot "PUBLIC_URL.txt") -Encoding ASCII
  }
}

function Test-PublicUrlReady {
  param([string]$TargetUrl)

  if ([string]::IsNullOrWhiteSpace($TargetUrl)) {
    return $false
  }

  $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
  if ($null -ne $curl) {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $head = & $curl.Source -L -I --max-time 10 --silent --show-error $TargetUrl 2>&1
      $curlExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($curlExitCode -eq 0 -and (($head | Out-String) -match "HTTP/\S+\s+200\s")) {
      return $true
    }

    if ($curlExitCode -ne 0 -and ($head | Out-String) -match "Could not resolve host") {
      try {
        $uri = [System.Uri]$TargetUrl
        if ($uri.Scheme -eq "https" -and $uri.Host -match "\.trycloudflare\.com$") {
          $resolvedAddress = Resolve-DnsName $uri.Host -Server 1.1.1.1 -Type A -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty IPAddress
          if (-not [string]::IsNullOrWhiteSpace($resolvedAddress)) {
            $resolveArg = "$($uri.Host):443:$resolvedAddress"
            $oldErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
              $head = & $curl.Source -L -I --resolve $resolveArg --max-time 10 --silent --show-error $TargetUrl 2>&1
              $curlExitCode = $LASTEXITCODE
            } finally {
              $ErrorActionPreference = $oldErrorActionPreference
            }

            if ($curlExitCode -eq 0 -and (($head | Out-String) -match "HTTP/\S+\s+200\s")) {
              return $true
            }
          }
        }
      } catch {
      }
    }
  }

  try {
    $response = Invoke-WebRequest -Uri $TargetUrl -Method Get -TimeoutSec 10 -UseBasicParsing
    return ([int]$response.StatusCode -eq 200)
  } catch {
    return $false
  }
}

function Test-PrivateIpv4 {
  param([string]$Address)

  $bytes = $Address.Split(".")
  if ($bytes.Count -ne 4) {
    return $false
  }

  $first = [int]$bytes[0]
  $second = [int]$bytes[1]
  return (
    $first -eq 10 -or
    ($first -eq 172 -and $second -ge 16 -and $second -le 31) -or
    ($first -eq 192 -and $second -eq 168)
  )
}

function Get-HostIpv4Addresses {
  $addresses = @()

  try {
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
      $null -ne $_.IPv4Address -and
      $null -ne $_.NetAdapter -and
      $_.NetAdapter.Status -eq "Up"
    })

    foreach ($config in $configs) {
      foreach ($ip in @($config.IPv4Address)) {
        $address = [string]$ip.IPAddress
        if ([string]::IsNullOrWhiteSpace($address)) {
          continue
        }

        $name = [string]$config.InterfaceAlias
        $description = [string]$config.InterfaceDescription
        $adapterText = "$name $description"
        $isVirtual = $adapterText -match "(?i)virtual|vethernet|hyper-v|wsl|docker|vmware|virtualbox|npcap|loopback|bluetooth|tailscale"
        $hasGateway = @($config.IPv4DefaultGateway).Count -gt 0
        $isPrivate = Test-PrivateIpv4 -Address $address

        $addresses += [pscustomobject]@{
          Address = $address
          InterfaceAlias = $name
          InterfaceDescription = $description
          HasGateway = [bool]$hasGateway
          IsPrivate = [bool]$isPrivate
          IsVirtual = [bool]$isVirtual
        }
      }
    }
  } catch {
    try {
      $hostName = [System.Net.Dns]::GetHostName()
      $dnsAddresses = [System.Net.Dns]::GetHostAddresses($hostName) | Where-Object {
        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
      }

      foreach ($ip in $dnsAddresses) {
        $address = $ip.ToString()
        $addresses += [pscustomobject]@{
          Address = $address
          InterfaceAlias = "dns"
          InterfaceDescription = "DNS host address fallback"
          HasGateway = $false
          IsPrivate = [bool](Test-PrivateIpv4 -Address $address)
          IsVirtual = $false
        }
      }
    } catch {
    }
  }

  $addresses |
    Where-Object {
      $_.Address -notmatch "^127\." -and
      $_.Address -notmatch "^169\.254\." -and
      $_.Address -ne "0.0.0.0"
    } |
    Sort-Object -Property `
      @{ Expression = "IsVirtual"; Descending = $false },
      @{ Expression = "HasGateway"; Descending = $true },
      @{ Expression = "IsPrivate"; Descending = $true },
      @{ Expression = "Address"; Descending = $false } |
    Select-Object -Unique -Property Address, InterfaceAlias, InterfaceDescription, HasGateway, IsPrivate, IsVirtual
}

function Get-LanShareUrls {
  param([int]$SharePort)

  $candidates = @(Get-HostIpv4Addresses)
  if ($candidates.Count -eq 0) {
    return @()
  }

  $preferred = @($candidates | Where-Object { -not $_.IsVirtual })
  if ($preferred.Count -eq 0) {
    $preferred = $candidates
  }

  return @($preferred | ForEach-Object { "http://$($_.Address)`:$SharePort/" })
}

function Get-ShareLanUrlsForBind {
  param(
    [string]$Address,
    [int]$SharePort
  )

  if ($Address -eq "0.0.0.0") {
    return @(Get-LanShareUrls -SharePort $SharePort)
  }

  if ($Address -notmatch "^127\.") {
    return @("http://$Address`:$SharePort/")
  }

  return @()
}

function Get-ShareLanDiagnosticsForBind {
  param(
    [string]$Address,
    [int]$SharePort
  )

  if ($Address -match "^127\.") {
    return @()
  }

  $hostAddresses = @(Get-HostIpv4Addresses)
  if ($Address -ne "0.0.0.0") {
    $hostAddresses = @($hostAddresses | Where-Object { $_.Address -eq $Address })
    if ($hostAddresses.Count -eq 0) {
      $hostAddresses = @([pscustomobject]@{
        Address = $Address
        InterfaceAlias = "explicit-bind"
        InterfaceDescription = "Explicit bind address not present in adapter inventory"
        HasGateway = $false
        IsPrivate = [bool](Test-PrivateIpv4 -Address $Address)
        IsVirtual = $false
      })
    }
  } else {
    $preferred = @($hostAddresses | Where-Object { -not $_.IsVirtual })
    if ($preferred.Count -gt 0) {
      $hostAddresses = $preferred
    }
  }

  $rank = 0
  return @($hostAddresses | ForEach-Object {
    $rank += 1
    $notes = @()
    if ($_.IsVirtual) {
      $notes += "virtual-or-vpn-adapter"
    }
    if (-not $_.HasGateway) {
      $notes += "no-default-gateway"
    }
    if (-not $_.IsPrivate) {
      $notes += "not-rfc1918-private"
    }
    if ($notes.Count -eq 0) {
      $notes += "preferred-lan-candidate"
    }

    [ordered]@{
      rank = $rank
      url = "http://$($_.Address)`:$SharePort/"
      address = [string]$_.Address
      interfaceAlias = [string]$_.InterfaceAlias
      interfaceDescription = [string]$_.InterfaceDescription
      hasGateway = [bool]$_.HasGateway
      isPrivate = [bool]$_.IsPrivate
      isVirtual = [bool]$_.IsVirtual
      notes = @($notes)
    }
  })
}

function Assert-BindAddressAvailable {
  param([string]$Address)

  $parsedAddress = [System.Net.IPAddress]::Any
  if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
    throw "BindAddress must be an IPv4 address, got: $Address"
  }

  if ($Address -eq "127.0.0.1" -or $Address -eq "0.0.0.0") {
    return
  }

  $hostAddresses = @(Get-HostIpv4Addresses | Select-Object -ExpandProperty Address)
  if ($hostAddresses -notcontains $Address) {
    $availableText = if ($hostAddresses.Count -gt 0) { $hostAddresses -join ", " } else { "none detected" }
    throw "BindAddress $Address is not assigned to an active non-loopback interface. Use -Lan or one of: $availableText"
  }
}

function Wait-LocalUrlReady {
  param([string]$TargetUrl)

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if (Test-PublicUrlReady -TargetUrl $TargetUrl) {
      return $true
    }

    Start-Sleep -Milliseconds 500
  }

  return (Test-PublicUrlReady -TargetUrl $TargetUrl)
}

function Test-ShareUrlsFromHost {
  param([string[]]$Urls)

  $results = @()
  foreach ($url in @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    $started = Get-Date
    $statusCode = 0
    $errorMessage = ""
    $ok = $false

    try {
      $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 3 -UseBasicParsing
      $statusCode = [int]$response.StatusCode
      $ok = ($statusCode -ge 200 -and $statusCode -lt 400)
    } catch {
      $errorMessage = $_.Exception.Message
    }

    $ended = Get-Date
    $results += [ordered]@{
      url = $url
      reachableFromHost = $ok
      statusCode = $statusCode
      elapsedMs = [Math]::Round(($ended - $started).TotalMilliseconds, 1)
      error = $errorMessage
      note = "This probe only tests reachability from the machine running share_release. A phone or laptop must still be on the same network, allowed by the firewall, and using one of the LAN URLs."
    }
  }

  return @($results)
}

function Write-ShareProbeReport {
  param([string]$Status)

  $report = [ordered]@{
    schema = "stackchan.share-probe-report.v1"
    version = $Version
    status = $Status
    generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    bindAddress = $BindAddress
    loopbackUrl = "http://127.0.0.1`:$Port/"
    localUrl = $script:ShareProbeUrl
    lanUrls = @($script:ShareLanUrls)
    lanDiagnostics = @($script:ShareLanDiagnostics)
    hostProbeResults = @($script:ShareUrlProbeResults)
    openLocalShare = "OPEN_LOCAL_SHARE.cmd"
    openLocalRequested = [bool]$OpenLocal
  }

  $report | ConvertTo-Json -Depth 7 | Set-Content -Path (Join-Path $shareRoot "share_probe_report.json") -Encoding UTF8
}

function Write-LanTroubleshooting {
  $diagnostics = if ($null -ne $script:ShareLanDiagnostics) { @($script:ShareLanDiagnostics) } else { @() }
  $probeResults = if ($null -ne $script:ShareUrlProbeResults) { @($script:ShareUrlProbeResults) } else { @() }
  $lines = @(
    "# Stackchan Share LAN Troubleshooting",
    "",
    "Version: $Version",
    "Bind address: $BindAddress",
    "Loopback URL: http://127.0.0.1`:$Port/",
    "Host-only open helper: OPEN_LOCAL_SHARE.cmd",
    "",
    "Use OPEN_LOCAL_SHARE.cmd or the loopback URL on this Windows machine. Use a same-network URL only from another device on the same Wi-Fi/LAN.",
    "",
    "## LAN URL Candidates",
    ""
  )

  if ($diagnostics.Count -eq 0) {
    $lines += "- No non-loopback LAN candidates were detected for this share."
  } else {
    foreach ($item in $diagnostics) {
      $lines += "- $($item.url) - adapter: $($item.interfaceAlias); gateway: $($item.hasGateway); private: $($item.isPrivate); virtual: $($item.isVirtual); notes: $(@($item.notes) -join ', ')"
    }
  }

  $lines += @(
    "",
    "## Host Reachability Probes",
    ""
  )

  if ($probeResults.Count -eq 0) {
    $lines += "- No host probes have run yet. Start the share without `-NoServe` to probe loopback and LAN candidates."
  } else {
    foreach ($probe in $probeResults) {
      $state = if ($probe.reachableFromHost) { "reachable" } else { "not reachable" }
      $detail = if ([string]::IsNullOrWhiteSpace([string]$probe.error)) { "HTTP $($probe.statusCode)" } else { [string]$probe.error }
      $lines += "- $($probe.url) - $state from host ($detail, $($probe.elapsedMs) ms)"
    }
  }

  $lines += @(
    "",
    "## If Another Device Cannot Open The Page",
    "",
    "1. On this Windows machine, run `OPEN_LOCAL_SHARE.cmd` first to confirm the local server is alive.",
    "2. Try each same-network URL candidate, not the loopback URL.",
    "3. Prefer candidates marked `preferred-lan-candidate`; virtual, VPN, WSL, Docker, Bluetooth, or no-gateway adapters are less likely to work from another device.",
    "4. If every LAN URL fails, allow the Python server through Windows Firewall for private networks or use `-CloudflareTunnel -DownloadCloudflared`."
  )

  $lines | Set-Content -Path (Join-Path $shareRoot "LAN_TROUBLESHOOTING.md") -Encoding UTF8
}

function Wait-PublicUrlReady {
  param([string]$TargetUrl)

  $readyWaitSeconds = [Math]::Max(0, $PublicUrlReadyWaitSeconds)
  $pollSeconds = [Math]::Max(1, $PublicUrlReadyPollSeconds)
  $deadline = (Get-Date).AddSeconds($readyWaitSeconds)

  while ((Get-Date) -lt $deadline) {
    if (Test-PublicUrlReady -TargetUrl $TargetUrl) {
      return $true
    }

    Start-Sleep -Seconds $pollSeconds
  }

  return (Test-PublicUrlReady -TargetUrl $TargetUrl)
}

function Find-CloudflarePublicUrl {
  param([string[]]$LogPaths)

  foreach ($logPath in $LogPaths) {
    if (-not (Test-Path -LiteralPath $logPath)) {
      continue
    }

    $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($logText)) {
      continue
    }

    $match = [regex]::Match($logText, "https://[-A-Za-z0-9]+\.trycloudflare\.com")
    if ($match.Success) {
      return $match.Value
    }
  }

  return $null
}

function Write-StopHelper {
  param([int[]]$ProcessIds)

  $stopScript = Join-Path $PSScriptRoot "stop_share.ps1"
  $stopCommand = "& '$stopScript' -ShareRoot '$shareRoot'"
  @(
    "@echo off",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$stopCommand`""
  ) | Set-Content -Path (Join-Path $shareRoot "STOP_SHARING.cmd") -Encoding ASCII

  if ($ProcessIds.Count -gt 0) {
    "Stop-Process -Id $($ProcessIds -join ',')" | Set-Content -Path (Join-Path $shareRoot "STOP_SHARING.ps1.txt") -Encoding ASCII
  }
}

function Write-OpenLocalShareHelper {
  param([string]$LocalUrl)

  @(
    "@echo off",
    "setlocal",
    "echo Opening Stackchan Alive local share on this Windows machine...",
    "echo $LocalUrl",
    "start ""Stackchan Alive Share"" ""$LocalUrl"""
  ) | Set-Content -Path (Join-Path $shareRoot "OPEN_LOCAL_SHARE.cmd") -Encoding ASCII
}

function Invoke-OpenLocalShare {
  param([string]$LocalUrl)

  if ([string]::IsNullOrWhiteSpace($LocalUrl)) {
    return
  }

  try {
    Start-Process -FilePath $LocalUrl | Out-Null
    Write-Host "Opened local share page:"
    Write-Host $LocalUrl
  } catch {
    Write-Warning "Could not open local share page automatically. Run OPEN_LOCAL_SHARE.cmd or open $LocalUrl manually. $($_.Exception.Message)"
  }
}

function Stop-ExistingShare {
  param([string]$ExistingShareRoot)

  if (-not (Test-Path -LiteralPath $ExistingShareRoot)) {
    return
  }

  $stopScript = Join-Path $PSScriptRoot "stop_share.ps1"
  if (-not (Test-Path -LiteralPath $stopScript)) {
    return
  }

  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript -ShareRoot $ExistingShareRoot | Out-Null
  } catch {
    Write-Warning "Existing share stop helper reported a problem: $($_.Exception.Message)"
  }
}

function Remove-ShareRoot {
  param([string]$ExistingShareRoot)

  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      Remove-Item -LiteralPath $ExistingShareRoot -Recurse -Force
      return
    } catch {
      if ($attempt -eq 5) {
        throw
      }
      Start-Sleep -Milliseconds (250 * $attempt)
    }
  }
}

function Get-CloudflaredPath {
  $command = Get-Command "cloudflared" -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  $localPath = Join-Path $repoRoot "output/tools/cloudflared.exe"
  if (Test-Path -LiteralPath $localPath) {
    return (Resolve-Path $localPath).Path
  }

  if (-not $DownloadCloudflared) {
    throw "Required command is not available on PATH: cloudflared. Re-run with -DownloadCloudflared to place a local copy under output/tools."
  }

  $toolsDir = Join-Path $repoRoot "output/tools"
  New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
  $downloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

  Write-Host "Downloading cloudflared:"
  Write-Host $downloadUrl
  Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath

  $item = Get-Item -LiteralPath $localPath
  if ($item.Length -lt 1000000) {
    throw "Downloaded cloudflared is unexpectedly small: $($item.Length) bytes"
  }

  return $item.FullName
}

function Get-PythonPath {
  $candidatePaths = @()
  $candidatePaths += @(Get-Command "python" -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $pythonRoots = Join-Path $env:LOCALAPPDATA "Programs/Python"
    if (Test-Path -LiteralPath $pythonRoots) {
      $candidatePaths += @(
        Get-ChildItem -LiteralPath $pythonRoots -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending |
          ForEach-Object { Join-Path $_.FullName "python.exe" }
      )
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidatePaths += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/python.exe"
    $candidatePaths += Join-Path $env:USERPROFILE ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
  }

  foreach ($path in @($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }
    if ($path -match "\\WindowsApps\\python\.exe$") {
      continue
    }

    try {
      $probe = & $path -c "import sys; print(sys.executable)" 2>$null
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($probe | Out-String).Trim())) {
        return (Resolve-Path $path).Path
      }
    } catch {
      continue
    }
  }

  throw "Required Python runtime is not available. Install Python 3, install PlatformIO, or add python.exe to PATH."
}

function Test-TcpPortAvailable {
  param(
    [string]$Address,
    [int]$CandidatePort
  )

  $listener = $null
  try {
    $ipAddress = [System.Net.IPAddress]::Parse($Address)
    $listener = [System.Net.Sockets.TcpListener]::new($ipAddress, $CandidatePort)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($null -ne $listener) {
      $listener.Stop()
    }
  }
}

function Test-SharePortAvailable {
  param(
    [string]$Address,
    [int]$CandidatePort
  )

  $addressesToCheck = @($Address)
  if ($Address -eq "0.0.0.0") {
    $addressesToCheck += "127.0.0.1"
    $addressesToCheck += @(Get-HostIpv4Addresses | Select-Object -ExpandProperty Address)
  }

  foreach ($addressToCheck in @($addressesToCheck | Select-Object -Unique)) {
    if (-not (Test-TcpPortAvailable -Address $addressToCheck -CandidatePort $CandidatePort)) {
      return $false
    }
  }

  return $true
}

function Find-AvailableTcpPort {
  param(
    [string]$Address,
    [int]$StartPort
  )

  $maxPort = [Math]::Min(65535, $StartPort + 200)
  for ($candidate = $StartPort; $candidate -le $maxPort; $candidate++) {
    if (Test-SharePortAvailable -Address $Address -CandidatePort $candidate) {
      return $candidate
    }
  }

  throw "No available TCP port found for $Address between $StartPort and $maxPort."
}

$rootManifest = Get-ReleaseManifest $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  if ($null -ne $rootManifest) {
    $Version = [string]$rootManifest.version
  } else {
    $Version = Invoke-GitText @("describe", "--tags", "--always", "--dirty")
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "Version is required when it cannot be inferred from git or release_manifest.json."
}

if ($Lan) {
  $BindAddress = "0.0.0.0"
}

Assert-BindAddressAvailable -Address $BindAddress
$script:ShareProbeUrl = if ($BindAddress -eq "0.0.0.0") { "http://127.0.0.1`:$Port/" } else { "http://$BindAddress`:$Port/" }
$script:ShareLanUrls = @()

$shareRoot = Join-Path $repoRoot "output/share/$Version"
if (Test-Path -LiteralPath $shareRoot) {
  Stop-ExistingShare -ExistingShareRoot $shareRoot
  Remove-ShareRoot -ExistingShareRoot $shareRoot
}
New-Item -ItemType Directory -Force -Path $shareRoot | Out-Null

if ($null -ne $rootManifest) {
  $packageRoot = $repoRoot
  $zipPath = Join-Path $shareRoot "stackchan_alive_$Version.zip"
  $zipItems = Get-ChildItem -LiteralPath $packageRoot -Force |
    Where-Object { $_.Name -ne "output" } |
    Select-Object -ExpandProperty FullName
  Compress-Archive -LiteralPath $zipItems -DestinationPath $zipPath -Force
} else {
  $packageRoot = Join-Path $repoRoot "output/release/$Version"
  $zipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
}

Assert-File $packageRoot
Assert-File $zipPath

$files = @(
  @{ Source = $zipPath; Name = "stackchan_alive_$Version.zip" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.png"); Name = "stackchan_alive_preview.png" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_expression_sheet.png"); Name = "stackchan_alive_expression_sheet.png" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.mp4"); Name = "stackchan_alive_preview.mp4" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.gif"); Name = "stackchan_alive_preview.gif" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_speech_preview.gif"); Name = "stackchan_alive_speech_preview.gif" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_a_idle_10s.gif"); Name = "artifacts/face/phase_a_idle_10s.gif" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_a_blink_filmstrip_50ms.png"); Name = "artifacts/face/phase_a_blink_filmstrip_50ms.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_a_unlabeled_expression_sheet.png"); Name = "artifacts/face/phase_a_unlabeled_expression_sheet.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_b_unlabeled_expression_sheet.png"); Name = "artifacts/face/phase_b_unlabeled_expression_sheet.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_c_idle_10s.gif"); Name = "artifacts/face/phase_c_idle_10s.gif" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png"); Name = "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png"); Name = "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png"); Name = "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png" },
  @{ Source = (Join-Path $packageRoot "artifacts/face/phase_e_speech_reactive_6s.gif"); Name = "artifacts/face/phase_e_speech_reactive_6s.gif" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_greeting.wav"); Name = "voice/stackchan_spark_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_thinking.wav"); Name = "voice/stackchan_spark_thinking.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_safety.wav"); Name = "voice/stackchan_spark_safety.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_audition_warm_slow_greeting.wav"); Name = "voice/stackchan_spark_audition_warm_slow_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.wav"); Name = "voice/stackchan_spark_audition_bright_robot_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3"); Name = "voice/stackchan_spark_audition_bright_robot_greeting.mp3" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_thinking.mp3"); Name = "voice/stackchan_spark_thinking.mp3" },
  @{ Source = (Join-Path $packageRoot "media/voice/VOICE_SAMPLES.md"); Name = "voice/VOICE_SAMPLES.md" },
  @{ Source = (Join-Path $packageRoot "media/voice/VOICE_AUDITION.html"); Name = "voice/VOICE_AUDITION.html" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITIONS.md"); Name = "voice/rvc/RVC_AUDITIONS.md" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITIONS.json"); Name = "voice/rvc/RVC_AUDITIONS.json" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_neutral.wav"); Name = "voice/rvc/stackchan_rvc_neutral.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_warm_slow.wav"); Name = "voice/rvc/stackchan_rvc_warm_slow.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot.wav"); Name = "voice/rvc/stackchan_rvc_bright_robot.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav"); Name = "voice/rvc/stackchan_rvc_bright_robot_less_static.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav"); Name = "voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav"); Name = "voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_spark_boops.wav"); Name = "voice/rvc/stackchan_rvc_spark_boops.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_high_character.wav"); Name = "voice/rvc/stackchan_rvc_high_character.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_thinking_neutral.wav"); Name = "voice/rvc/stackchan_rvc_thinking_neutral.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_safety_neutral.wav"); Name = "voice/rvc/stackchan_rvc_safety_neutral.wav" },
  @{ Source = (Join-Path $packageRoot "ARRIVAL_DAY_RUNBOOK.md"); Name = "ARRIVAL_DAY_RUNBOOK.md" },
  @{ Source = (Join-Path $packageRoot "QUICKSTART.md"); Name = "QUICKSTART.md" },
  @{ Source = (Join-Path $packageRoot "RELEASE_NOTES.md"); Name = "RELEASE_NOTES.md" },
  @{ Source = (Join-Path $packageRoot "RELEASE_ACCEPTANCE.md"); Name = "RELEASE_ACCEPTANCE.md" },
  @{ Source = (Join-Path $packageRoot "release_acceptance.json"); Name = "release_acceptance.json" },
  @{ Source = (Join-Path $packageRoot "GITHUB_ACTIONS_STATUS.md"); Name = "GITHUB_ACTIONS_STATUS.md" },
  @{ Source = (Join-Path $packageRoot "github_actions_status.json"); Name = "github_actions_status.json" },
  @{ Source = (Join-Path $packageRoot "DEPENDENCIES.md"); Name = "DEPENDENCIES.md" },
  @{ Source = (Join-Path $packageRoot "dependency_lock.json"); Name = "dependency_lock.json" },
  @{ Source = (Join-Path $packageRoot "VOICE_SOURCE_STATUS.md"); Name = "VOICE_SOURCE_STATUS.md" },
  @{ Source = (Join-Path $packageRoot "voice_source_status.json"); Name = "voice_source_status.json" },
  @{ Source = (Join-Path $packageRoot "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"); Name = "VOICE_SOURCE_PROVENANCE_TEMPLATE.md" },
  @{ Source = (Join-Path $packageRoot "data/voice_source_provenance.yaml"); Name = "voice_source_provenance.yaml" },
  @{ Source = (Join-Path $packageRoot "data/voice_rvc_base.yaml"); Name = "voice_rvc_base.yaml" },
  @{ Source = (Join-Path $packageRoot "data/voice_rvc_base_metadata.json"); Name = "voice_rvc_base_metadata.json" },
  @{ Source = (Join-Path $packageRoot "RVC_VOICE_BASE_STATUS.md"); Name = "RVC_VOICE_BASE_STATUS.md" },
  @{ Source = (Join-Path $packageRoot "rvc_voice_base_status.json"); Name = "rvc_voice_base_status.json" },
  @{ Source = (Join-Path $packageRoot "READINESS_REPORT.md"); Name = "READINESS_REPORT.md" },
  @{ Source = (Join-Path $packageRoot "readiness_report.json"); Name = "readiness_report.json" },
  @{ Source = (Join-Path $packageRoot "SHA256SUMS.txt"); Name = "SHA256SUMS.txt" }
)

foreach ($file in $files) {
  Assert-File $file.Source
  $destination = Join-Path $shareRoot $file.Name
  $sourcePath = (Resolve-Path $file.Source).Path
  if ((Test-Path -LiteralPath $destination) -and ((Resolve-Path $destination).Path -eq $sourcePath)) {
    continue
  }
  $destinationParent = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $destinationParent)) {
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
  }
  Copy-Item -LiteralPath $file.Source -Destination $destination
}

$manifest = Get-Content -LiteralPath (Join-Path $packageRoot "release_manifest.json") -Raw | ConvertFrom-Json
$readiness = Get-Content -LiteralPath (Join-Path $packageRoot "readiness_report.json") -Raw | ConvertFrom-Json
$dependencyLock = Get-Content -LiteralPath (Join-Path $packageRoot "dependency_lock.json") -Raw | ConvertFrom-Json
$voiceSourceStatus = Get-Content -LiteralPath (Join-Path $packageRoot "voice_source_status.json") -Raw | ConvertFrom-Json
$rvcBaseStatus = Get-Content -LiteralPath (Join-Path $packageRoot "rvc_voice_base_status.json") -Raw | ConvertFrom-Json
$rvcAuditions = Get-Content -LiteralPath (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITIONS.json") -Raw | ConvertFrom-Json

$preflightRoot = Join-Path $repoRoot "output/preflight/$Version"
$preflightReportMarkdown = Join-Path $preflightRoot "preflight_report.md"
$preflightReportJson = Join-Path $preflightRoot "preflight_report.json"
$preflightReportAvailable = (Test-Path -LiteralPath $preflightReportMarkdown) -and (Test-Path -LiteralPath $preflightReportJson)
$preflightStatus = "pending"
$preflightStatusPillClass = "pending"
$preflightSection = @"
  <h2>Preflight Evidence</h2>
  <p>No-hardware device preflight has not been attached to this share yet. Run <code>.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_$Version.zip -Version $Version -ExpectedCommit $($manifest.commit)</code>, then re-run this share command to publish the pass/fail report.</p>
"@
$preflightDownloadItems = ""

if ($preflightReportAvailable) {
  Copy-Item -LiteralPath $preflightReportMarkdown -Destination (Join-Path $shareRoot "preflight_report.md")
  Copy-Item -LiteralPath $preflightReportJson -Destination (Join-Path $shareRoot "preflight_report.json")
  $preflightReport = Get-Content -LiteralPath $preflightReportJson -Raw | ConvertFrom-Json
  $preflightStatus = [string]$preflightReport.status
  $preflightStatusPillClass = if ($preflightStatus -eq "pass") { "pass" } else { "pending" }
  $preflightPassedSteps = @($preflightReport.steps | Where-Object { $_.status -eq "pass" }).Count
  $preflightFailedSteps = @($preflightReport.steps | Where-Object { $_.status -eq "fail" }).Count
  $preflightSection = @"
  <h2>Preflight Evidence</h2>
  <p>No-hardware device preflight report for this package is attached. It covers required commands, dependency pins, flash-helper safety gates, architecture boundaries, preview media, hardware-evidence verifier gates, native tests, embedded test firmware compile, firmware builds, release package verification, and release flash-helper checks.</p>
  <div class="status">
    <span class="pill $preflightStatusPillClass">Preflight: $preflightStatus</span>
    <span class="pill pass">Passed steps: $preflightPassedSteps</span>
    <span class="pill pending">Failed steps: $preflightFailedSteps</span>
  </div>
  <p><a href="preflight_report.md">Read preflight report</a> or <a href="preflight_report.json">download preflight JSON</a>.</p>
"@
  $preflightDownloadItems = @"
    <div class="item"><a href="preflight_report.md">Preflight Report</a></div>
    <div class="item"><a href="preflight_report.json">Preflight JSON</a></div>
"@
}

$sharedZipName = "stackchan_alive_$Version.zip"
$sharedZipPath = Join-Path $shareRoot $sharedZipName
Assert-File $sharedZipPath
$sharedZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sharedZipPath).Hash.ToLowerInvariant()
"$sharedZipHash  $sharedZipName" | Set-Content -Path (Join-Path $shareRoot "$sharedZipName.sha256") -Encoding ASCII

$actionsStatusScript = Join-Path $packageRoot "tools/export_github_actions_status.ps1"
if ((Get-Command "gh" -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $actionsStatusScript)) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $actionsStatusScript -Version $Version -Commit $manifest.commit -OutputDir $shareRoot
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Unable to refresh GitHub Actions status for share; using packaged status artifacts."
  }
}
$actionsStatus = Get-Content -LiteralPath (Join-Path $shareRoot "github_actions_status.json") -Raw | ConvertFrom-Json
$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$passedGateCount = @($readiness.noHardwareProof | Where-Object { $_.status -eq "pass" }).Count
$pendingGateCount = @($readiness.hardwareGates | Where-Object { $_.status -match "pending" }).Count
$consumerRollout = [string]$readiness.consumerRollout
$voiceSourceGateStatus = [System.Net.WebUtility]::HtmlEncode([string]$voiceSourceStatus.status)
$voiceSourceBlockedGateCount = [int]$voiceSourceStatus.blockedGateCount
$rvcBaseStatusText = [System.Net.WebUtility]::HtmlEncode([string]$rvcBaseStatus.status)
$rvcBaseArchiveText = if ([bool]$rvcBaseStatus.localArchive.present) { "local archive verified for review cache" } else { "manifest recorded; local archive not bundled" }
$rvcBaseArchiveText = [System.Net.WebUtility]::HtmlEncode($rvcBaseArchiveText)
$rvcBaseExpectedSha = [System.Net.WebUtility]::HtmlEncode([string]$rvcBaseStatus.expectedArchive.sha256)
$rvcBaseExpectedBytes = [System.Net.WebUtility]::HtmlEncode([string]$rvcBaseStatus.expectedArchive.bytes)
$rvcLead = $rvcAuditions.leadAudition
if ($null -eq $rvcLead) {
  throw "RVC_AUDITIONS.json is missing leadAudition metadata."
}
$rvcLeadTitle = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.title)
$rvcLeadFile = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.file)
$rvcLeadTranscript = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.transcript)
$rvcLeadRating = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.userRating)
$rvcLeadPurpose = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.perceptualPurpose)
$rvcLeadPitch = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.pitch)
$rvcLeadIndex = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.index_rate)
$rvcLeadRms = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.rms_mix_rate)
$rvcLeadProtect = [System.Net.WebUtility]::HtmlEncode([string]$rvcLead.protect)
$rvcLeadPath = "voice/rvc/$($rvcLead.file)"
$rvcLeadPathHtml = [System.Net.WebUtility]::HtmlEncode($rvcLeadPath)
$declaredDependencyCount = @($dependencyLock.declaredLibDeps).Count
$directGitMissingRefCount = @($dependencyLock.dependencyAudit.directGitDepsMissingRef).Count
$duplicateDependencyCount = @($dependencyLock.dependencyAudit.duplicateResolvedPackages).Count
$unpinnedUpstreamGitCount = @($dependencyLock.dependencyAudit.unpinnedGitRequirements).Count
$gitResolvedWithoutShaCount = @($dependencyLock.dependencyAudit.gitResolvedWithoutSha).Count
$promotionGateItems = (@($readiness.hardwareGates) | ForEach-Object {
  $gateName = [System.Net.WebUtility]::HtmlEncode([string]$_.gate)
  $gateStatus = [System.Net.WebUtility]::HtmlEncode([string]$_.status)
  $gateEvidence = [System.Net.WebUtility]::HtmlEncode([string]$_.requiredEvidence)
  "    <li><strong>$gateName</strong> <code>$gateStatus</code>: $gateEvidence</li>"
}) -join [Environment]::NewLine

@"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Stackchan Alive $Version</title>
  <style>
    :root { color-scheme: light dark; font-family: Segoe UI, Arial, sans-serif; }
    body { margin: 0; padding: 32px; line-height: 1.45; }
    main { max-width: 960px; margin: 0 auto; }
    img, video { max-width: 100%; border: 1px solid #7775; }
    audio { width: 100%; margin-top: 8px; }
    code { background: #7772; padding: 2px 5px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }
    .item { border: 1px solid #7775; padding: 16px; }
    .status { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0; }
    .pill { border: 1px solid #7775; padding: 6px 10px; }
    .pass { border-color: #2ea04399; }
    .pending { border-color: #d2992299; }
    .transcript { font-size: 0.95em; margin: 10px 0 0; }
    .checklist li { margin-bottom: 6px; }
  </style>
</head>
<body>
<main>
  <h1>Stackchan Alive $Version</h1>
  <p>Device-ready prerelease. Hardware validation is still pending.</p>
  <p><strong>Commit:</strong> <code>$($manifest.commit)</code></p>
  <p><strong>Generated UTC:</strong> <code>$generatedUtc</code></p>
  <div class="status">
    <span class="pill pass">No-hardware gates passed: $passedGateCount</span>
    <span class="pill pending">Hardware gates pending: $pendingGateCount</span>
    <span class="pill pending">Consumer rollout: $consumerRollout</span>
    <span class="pill pending">GitHub Actions: $($actionsStatus.status)</span>
    <span class="pill $preflightStatusPillClass">Preflight: $preflightStatus</span>
    <span class="pill pending">Speaker audio evidence: pending device</span>
  </div>
  <p><strong>GitHub Actions:</strong> $($actionsStatus.interpretation)</p>

$preflightSection

  <h2>Pending Promotion Gates</h2>
  <p>These gates come directly from <code>readiness_report.json</code>. Do not mark this release consumer-ready until each item has explicit real-device evidence.</p>
  <ul class="checklist">
$promotionGateItems
  </ul>

  <h2>Dependency Provenance</h2>
  <p>The release ZIP includes copied build inputs, dependency provenance, and a machine-readable dependency lock. Direct Git dependencies are required to be pinned, and resolved Git packages must carry SHA evidence.</p>
  <div class="status">
    <span class="pill pass">Declared library deps: $declaredDependencyCount</span>
    <span class="pill pass">Direct Git deps missing refs: $directGitMissingRefCount</span>
    <span class="pill pass">Resolved Git deps without SHA: $gitResolvedWithoutShaCount</span>
    <span class="pill pending">Duplicate resolved packages for review: $duplicateDependencyCount</span>
    <span class="pill pending">Upstream unpinned Git declarations: $unpinnedUpstreamGitCount</span>
  </div>
  <p>The duplicate and upstream-unpinned entries are the known transitive <code>SCServo</code> declarations from <code>stackchan-arduino</code>; this project also declares <code>SCServo#ee6ee4a</code> directly.</p>

  <h2>Preview</h2>
  <p><img src="stackchan_alive_preview.png" alt="Stackchan Alive preview image"></p>
  <p><img src="stackchan_alive_expression_sheet.png" alt="Stackchan Alive expression sheet"></p>
  <p><video src="stackchan_alive_preview.mp4" controls loop muted playsinline></video></p>
  <p><img src="stackchan_alive_speech_preview.gif" alt="Stackchan Alive speech-reactive preview GIF"></p>

  <h2>Face Phase A Artifacts</h2>
  <p>Phase A adds the double-buffered M5Canvas render path, frame telemetry, and the small layered animator skeleton with independent smoothing constants. These artifacts are generated procedurally by <code>tools/render_preview.py</code> and checked by <code>tools/verify_face_phase_a.ps1</code>.</p>
  <p><img src="artifacts/face/phase_a_unlabeled_expression_sheet.png" alt="Phase A unlabeled expression sheet"></p>
  <p><img src="artifacts/face/phase_a_blink_filmstrip_50ms.png" alt="Phase A blink filmstrip"></p>
  <p><img src="artifacts/face/phase_a_idle_10s.gif" alt="Phase A idle 10 second GIF"></p>

  <h2>Face Phase B Artifacts</h2>
  <p>Phase B adds procedural eye-corner cuts, angled lids, mouth corners and width, a two-curve open mouth, pupil dilation, and authored L0 pose keys. The unlabeled sheet is the gate artifact for checking distinct silhouettes and mandatory asymmetry.</p>
  <p><img src="artifacts/face/phase_b_unlabeled_expression_sheet.png" alt="Phase B unlabeled expression sheet"></p>

  <h2>Face Phase C Artifacts</h2>
  <p>Phase C adds the autonomic blink state machine with squash, saccade jumps with settle, breathing offset, gaze staging, reduced-motion damping, and idle fidget hooks inside the face animator. The idle GIF is the gate artifact for checking that no two seconds are static.</p>
  <p><img src="artifacts/face/phase_c_idle_10s.gif" alt="Phase C idle 10 second GIF"></p>

  <h2>Face Phase D Artifacts</h2>
  <p>Phase D adds transition choreography clips with visible anticipation, channel lag, staggered channel arrival, and state-specific timing. These filmstrips are generated at one frame per 50 ms and checked by <code>tools/verify_face_phase_d.ps1</code> for blink anticipation, Think-to-Speak mouth pre-open, and the staged Sleep droop.</p>
  <p><img src="artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png" alt="Phase D Idle to Listen filmstrip"></p>
  <p><img src="artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png" alt="Phase D Think to Speak filmstrip"></p>
  <p><img src="artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png" alt="Phase D Idle to Sleep filmstrip"></p>

  <h2>Face Phase E Artifacts</h2>
  <p>Phase E adds the speech envelope sidecar hook, L3 mouth ownership during active speech, viseme-lite width and roundness changes, loud-syllable brow accents, and stale-envelope return-to-rest behavior. The preview GIF uses a fixed synthetic envelope to show mouth motion tracking syllable peaks; final sync and target-speaker proof still require real-device audio evidence.</p>
  <p><img src="artifacts/face/phase_e_speech_reactive_6s.gif" alt="Phase E speech-reactive mouth GIF"></p>
  <p>Checked by <code>tools/verify_face_phase_e.ps1</code> for frame dimensions, mouth motion range, visible syllable peaks, and return to rest after speech.</p>

  <h2>Voice Samples</h2>
  <p>Prototype Stackchan Spark Synth v4 audition samples. These use a lightweight source with phrase-level micro-prosody, syllable gating, a speech-envelope electromechanical mask, formant-like resonators, sample-hold texture, ring modulation, comb resonance, tiny synthetic chirps, and a light musical vocoder/earcon blend on the Bright Robot pass. They are original direction samples, not a character clone, and final consumer rollout still requires a licensed or owned production voice source.</p>
  <div class="grid">
    <div class="item">
      <strong>Greeting</strong>
      <audio src="voice/stackchan_spark_greeting.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p><a href="voice/stackchan_spark_greeting.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>Thinking</strong>
      <audio src="voice/stackchan_spark_thinking.mp3" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Input received. I am thinking now. Curiosity level rising.</p>
      <p><a href="voice/stackchan_spark_thinking.wav">Download WAV</a> | <a href="voice/stackchan_spark_thinking.mp3">Download MP3</a></p>
    </div>
    <div class="item">
      <strong>Safety</strong>
      <audio src="voice/stackchan_spark_safety.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Small problem found. I can help fix it. Safety first.</p>
      <p><a href="voice/stackchan_spark_safety.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>Audition: Warm Slow</strong>
      <audio src="voice/stackchan_spark_audition_warm_slow_greeting.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Warmer and slightly slower for small-speaker intelligibility checks.</p>
      <p><a href="voice/stackchan_spark_audition_warm_slow_greeting.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>Audition: Bright Robot</strong>
      <audio src="voice/stackchan_spark_audition_bright_robot_greeting.mp3" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Brighter synthetic pass with slightly reduced static, a light musical vocoder blend, and phrase-timed chirp/boop accents.</p>
      <p><a href="voice/stackchan_spark_audition_bright_robot_greeting.wav">Download WAV</a> | <a href="voice/stackchan_spark_audition_bright_robot_greeting.mp3">Download MP3</a></p>
    </div>
  </div>
  <h3>Voice Review Checklist</h3>
  <ul class="checklist">
    <li>Clear enough to understand through a small device speaker.</li>
    <li>Robot-like without sounding like a direct movie-character clone.</li>
    <li>Prefer eSpeak-NG or an owned lightweight TTS source for formant character when available.</li>
    <li>Friendly, curious, and concise enough for repeated device use.</li>
    <li>Worth moving into a licensed or owned production voice source before consumer rollout.</li>
  </ul>

  <h2>RVC Voice Auditions</h2>
  <p>Review-only samples rendered through the selected RVC candidate base. These compare pitch, RVC blend, light vocoder, and beep/boop balance. They are not consumer-approved until voice rights and source provenance are cleared.</p>
  <div class="item">
    <strong>Current Lead: $rvcLeadTitle</strong>
    <audio src="$rvcLeadPathHtml" controls preload="metadata"></audio>
    <p class="transcript"><strong>Transcript:</strong> $rvcLeadTranscript</p>
    <p><strong>Selected settings:</strong> pitch $rvcLeadPitch, index $rvcLeadIndex, RMS mix $rvcLeadRms, protect $rvcLeadProtect.</p>
    <p><strong>Listening note:</strong> $rvcLeadRating. $rvcLeadPurpose.</p>
    <p><a href="$rvcLeadPathHtml">Download $rvcLeadFile</a></p>
  </div>
  <div class="grid">
    <div class="item">
      <strong>RVC Neutral</strong>
      <audio src="voice/rvc/stackchan_rvc_neutral.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Closest to the raw RVC base with only a light Stackchan edge.</p>
      <p><a href="voice/rvc/stackchan_rvc_neutral.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Warm Slow</strong>
      <audio src="voice/rvc/stackchan_rvc_warm_slow.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Warmer, slower, softer consonants for small-speaker intelligibility.</p>
      <p><a href="voice/rvc/stackchan_rvc_warm_slow.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Bright Robot</strong>
      <audio src="voice/rvc/stackchan_rvc_bright_robot.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Brighter robot pass with light vocoder and subtle phrase earcons.</p>
      <p><a href="voice/rvc/stackchan_rvc_bright_robot.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Bright Robot Less Static</strong>
      <audio src="voice/rvc/stackchan_rvc_bright_robot_less_static.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Near-final pass: same pitch 2 / index 0.62 / RMS mix 0.72 / protect 0.28 settings, with roughly 8% less static edge.</p>
      <p><a href="voice/rvc/stackchan_rvc_bright_robot_less_static.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Bright Robot Sweet Vocoder</strong>
      <audio src="voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Near-final pass: same winning RVC settings with a slightly more pleasant fourth/fifth vocoder blend.</p>
      <p><a href="voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Bright Robot Soft Boops</strong>
      <audio src="voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Near-final pass: same winning RVC settings with the beeps and boops tucked lower under the voice.</p>
      <p><a href="voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Spark Boops</strong>
      <audio src="voice/rvc/stackchan_rvc_spark_boops.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Friendly candidate with slightly more musical beeps and boops.</p>
      <p><a href="voice/rvc/stackchan_rvc_spark_boops.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC High Character</strong>
      <audio src="voice/rvc/stackchan_rvc_high_character.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Most synthetic and animated; useful as an upper bound.</p>
      <p><a href="voice/rvc/stackchan_rvc_high_character.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Thinking</strong>
      <audio src="voice/rvc/stackchan_rvc_thinking_neutral.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Input received. I am thinking now. Curiosity level rising.</p>
      <p>Neutral RVC settings on the thinking line.</p>
      <p><a href="voice/rvc/stackchan_rvc_thinking_neutral.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>RVC Safety</strong>
      <audio src="voice/rvc/stackchan_rvc_safety_neutral.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Small problem found. I can help fix it. Safety first.</p>
      <p>Neutral RVC settings on the safety line.</p>
      <p><a href="voice/rvc/stackchan_rvc_safety_neutral.wav">Download WAV</a></p>
    </div>
  </div>

  <h2>Voice Source Gate</h2>
  <p>The current WAVs are review-only prototype samples. Production TTS remains blocked until the voice source is licensed or owned, the provenance template is completed, and real-device speaker evidence is captured.</p>
  <p>Generated status: <code>$voiceSourceGateStatus</code> with <code>$voiceSourceBlockedGateCount</code> blocked voice-source gates. See <a href="VOICE_SOURCE_STATUS.md">VOICE_SOURCE_STATUS.md</a> and <a href="voice_source_status.json">voice_source_status.json</a>.</p>
  <p>For the next formant-source audition pass, run <code>.\tools\setup_voice_tools.cmd -InstallEspeak -RenderEspeakSamples</code>, then rebuild the release. This keeps the Stackchan Spark Synth v4 DSP but replaces the fallback Windows source with eSpeak-NG when available.</p>
  <div class="status">
    <span class="pill pending">Voice source: pending production source</span>
    <span class="pill pending">Rollout gate: licensed or owned production voice required</span>
    <span class="pill pending">Speaker evidence: pending device</span>
  </div>

  <h2>RVC Candidate Base</h2>
  <p>The selected audition base is the Drive/Weights.gg RVC archive <code>stackchan voice - Weights.gg Model.zip</code>. It is tracked as <code>candidate-pending-rights-review</code> for internal voice-conversion auditions only; it is not bundled in the release ZIP and is not consumer-approved.</p>
  <p>Checked by <code>tools/verify_rvc_voice_base.ps1</code> for manifest markers and, when the local archive is present, ZIP size, SHA256, entries, and embedded metadata.</p>
  <p>Generated RVC base status: <code>$rvcBaseStatusText</code>; $rvcBaseArchiveText. See <a href="RVC_VOICE_BASE_STATUS.md">RVC_VOICE_BASE_STATUS.md</a> and <a href="rvc_voice_base_status.json">rvc_voice_base_status.json</a>.</p>
  <ul class="checklist">
    <li>Drive file ID: <code>1I5A2kfTDE-VPWVo_cGIRRObkGv5w9Spb</code></li>
    <li>Weights.gg model: <code>clyaxlb9b000eoiqywl68wcrc</code>; title <code>joh</code>; author metadata <code>triceratops</code>.</li>
    <li>ZIP bytes: <code>$rvcBaseExpectedBytes</code>; ZIP SHA256: <code>$rvcBaseExpectedSha</code></li>
    <li>Consumer rollout remains blocked until license, consent, training-source, commercial-device-use, and generated-prompt distribution evidence are recorded.</li>
  </ul>
  <div class="status">
    <span class="pill pending">RVC base: candidate-pending-rights-review</span>
    <span class="pill pending">Rights review: pending</span>
    <span class="pill pending">Model ZIP: not bundled</span>
  </div>

  <h2>Hardware Audio Evidence</h2>
  <p>When the device arrives, the evidence packet now includes <code>AUDIO_REVIEW.md</code> and an <code>audio/</code> folder. Record at least one real-device speaker sample and mark the audio review fields with concrete pass/fail values before running promotion checks.</p>
  <ul class="checklist">
    <li>Save a real speaker recording under <code>audio/</code>; supported evidence includes WAV, MP3, M4A, AAC, MP4, MOV, or WEBM.</li>
    <li>Complete <code>AUDIO_REVIEW.md</code> with the sample played, selected voice direction, and recording filename.</li>
    <li>Promotion requires intelligible audio, no clipping or distortion, adequate normal-distance volume, and no playback dropout or excessive delay.</li>
    <li>Generated source WAVs alone do not count as target-speaker evidence.</li>
  </ul>

  <h2>Downloads</h2>
  <div class="grid">
    <div class="item"><a href="stackchan_alive_$Version.zip">Release ZIP</a></div>
    <div class="item"><a href="stackchan_alive_preview.png">Preview PNG</a></div>
    <div class="item"><a href="stackchan_alive_expression_sheet.png">Expression Sheet PNG</a></div>
    <div class="item"><a href="stackchan_alive_preview.mp4">Preview MP4</a></div>
    <div class="item"><a href="stackchan_alive_preview.gif">Preview GIF</a></div>
    <div class="item"><a href="stackchan_alive_speech_preview.gif">Speech-Reactive Preview GIF</a></div>
    <div class="item"><a href="artifacts/face/phase_a_idle_10s.gif">Face Phase A Idle GIF</a></div>
    <div class="item"><a href="artifacts/face/phase_a_blink_filmstrip_50ms.png">Face Phase A Filmstrip</a></div>
    <div class="item"><a href="artifacts/face/phase_a_unlabeled_expression_sheet.png">Face Phase A Unlabeled Sheet</a></div>
    <div class="item"><a href="artifacts/face/phase_b_unlabeled_expression_sheet.png">Face Phase B Unlabeled Sheet</a></div>
    <div class="item"><a href="artifacts/face/phase_c_idle_10s.gif">Face Phase C Idle GIF</a></div>
    <div class="item"><a href="artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png">Face Phase D Idle to Listen Filmstrip</a></div>
    <div class="item"><a href="artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png">Face Phase D Think to Speak Filmstrip</a></div>
    <div class="item"><a href="artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png">Face Phase D Idle to Sleep Filmstrip</a></div>
    <div class="item"><a href="artifacts/face/phase_e_speech_reactive_6s.gif">Face Phase E Speech GIF</a></div>
    <div class="item"><a href="voice/VOICE_SAMPLES.md">Voice Sample Notes</a></div>
    <div class="item"><a href="voice/VOICE_AUDITION.html">Local Voice Audition Page</a></div>
    <div class="item"><a href="voice/stackchan_spark_audition_warm_slow_greeting.wav">Warm Slow Voice Audition</a></div>
    <div class="item"><a href="voice/stackchan_spark_audition_bright_robot_greeting.wav">Bright Robot Voice Audition</a></div>
    <div class="item"><a href="voice/stackchan_spark_audition_bright_robot_greeting.mp3">Bright Robot MP3</a></div>
    <div class="item"><a href="voice/stackchan_spark_thinking.mp3">Thinking MP3</a></div>
    <div class="item"><a href="voice/rvc/RVC_AUDITIONS.md">RVC Audition Notes</a></div>
    <div class="item"><a href="voice/rvc/RVC_AUDITIONS.json">RVC Audition JSON</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_neutral.wav">RVC Neutral WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_warm_slow.wav">RVC Warm Slow WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_bright_robot.wav">RVC Bright Robot WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_bright_robot_less_static.wav">RVC Bright Robot Less Static WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav">RVC Bright Robot Sweet Vocoder WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav">RVC Bright Robot Soft Boops WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_spark_boops.wav">RVC Spark Boops WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_high_character.wav">RVC High Character WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_thinking_neutral.wav">RVC Thinking WAV</a></div>
    <div class="item"><a href="voice/rvc/stackchan_rvc_safety_neutral.wav">RVC Safety WAV</a></div>
    <div class="item"><a href="VOICE_SOURCE_STATUS.md">Voice Source Status</a></div>
    <div class="item"><a href="voice_source_status.json">Voice Source Status JSON</a></div>
    <div class="item"><a href="VOICE_SOURCE_PROVENANCE_TEMPLATE.md">Voice Source Provenance Template</a></div>
    <div class="item"><a href="voice_source_provenance.yaml">Voice Source Provenance YAML</a></div>
    <div class="item"><a href="voice_rvc_base.yaml">RVC Candidate Base YAML</a></div>
    <div class="item"><a href="voice_rvc_base_metadata.json">RVC Candidate Metadata JSON</a></div>
    <div class="item"><a href="RVC_VOICE_BASE_STATUS.md">RVC Base Status</a></div>
    <div class="item"><a href="rvc_voice_base_status.json">RVC Base Status JSON</a></div>
    <div class="item"><a href="ARRIVAL_DAY_RUNBOOK.md">Arrival-Day Runbook</a></div>
    <div class="item"><a href="QUICKSTART.md">Quickstart</a></div>
    <div class="item"><a href="RELEASE_ACCEPTANCE.md">Release Acceptance Checklist</a></div>
    <div class="item"><a href="release_acceptance.json">Acceptance JSON</a></div>
    <div class="item"><a href="GITHUB_ACTIONS_STATUS.md">GitHub Actions Status</a></div>
    <div class="item"><a href="github_actions_status.json">Actions Status JSON</a></div>
    <div class="item"><a href="DEPENDENCIES.md">Dependency Provenance</a></div>
    <div class="item"><a href="dependency_lock.json">Dependency Lock JSON</a></div>
    <div class="item"><a href="RELEASE_NOTES.md">Release Notes</a></div>
    <div class="item"><a href="READINESS_REPORT.md">Readiness Report</a></div>
    <div class="item"><a href="readiness_report.json">Readiness JSON</a></div>
$preflightDownloadItems
    <div class="item"><a href="stackchan_alive_$Version.zip.sha256">ZIP SHA256</a></div>
    <div class="item"><a href="SHA256SUMS.txt">SHA256 Checksums</a></div>
  </div>

  <h2>Device Arrival Quickstart</h2>
  <p>Bench operator runbook: <a href="ARRIVAL_DAY_RUNBOOK.md">ARRIVAL_DAY_RUNBOOK.md</a></p>
  <p>After downloading and extracting the release ZIP, run this from inside the extracted folder:</p>
  <pre><code>.\tools\prepare_device_arrival.cmd -Port COM3 -Operator &quot;Your Name&quot; -DeviceId STACKCHAN-001</code></pre>
  <p>This verifies the package, dry-runs the display-only flash command, and creates a hardware evidence packet with runnable <code>RUN_*.cmd</code> files.</p>
  <h3>Arrival-Day Evidence Loop</h3>
  <ol>
    <li>Run <code>RUN_DISPLAY_ONLY.cmd</code> and confirm the face appears with dry-run servo logs.</li>
    <li>Run <code>RUN_SERVO_CALIBRATION.cmd</code> only after the body is clear and supervised.</li>
    <li>Run <code>RUN_SOAK_MONITOR.cmd</code> for the 30-minute mixed-mode soak.</li>
    <li>Complete <code>AUDIO_REVIEW.md</code> and save a real-device speaker recording under <code>audio/</code>.</li>
    <li>Run <code>RUN_PROGRESS_CHECK.cmd</code> during testing to list missing logs, observation fields, audio evidence, media, calibration updates, and unchecked gates.</li>
    <li>Run <code>RUN_EVIDENCE_VERIFY.cmd</code> only when the progress check is clean and the packet is ready for promotion review.</li>
    <li>Run <code>RUN_CONSUMER_PROMOTION_CHECK.cmd</code> only after evidence verification passes and production voice-source provenance plus GitHub Actions status are ready.</li>
  </ol>
  <p>Use display-only firmware first. Servo calibration requires the explicit <code>-ConfirmServoRisk</code> command generated in the evidence packet and a supervised clear work area.</p>
  <h2>Share Diagnostics</h2>
  <p>Local and LAN troubleshooting artifacts: <a href="OPEN_LOCAL_SHARE.cmd">OPEN_LOCAL_SHARE.cmd</a>, <a href="LAN_TROUBLESHOOTING.md">LAN_TROUBLESHOOTING.md</a>, <a href="share_status.json">share_status.json</a>, and <a href="share_probe_report.json">share_probe_report.json</a>.</p>
  <p>If a same-network URL does not open from another device, use the LAN troubleshooting report to identify virtual/VPN adapters, no-gateway addresses, and host-side probe results before trying another candidate.</p>
</main>
</body>
</html>
"@ | Set-Content -Path (Join-Path $shareRoot "index.html") -Encoding UTF8

if (-not $NoServe) {
  $requestedPort = $Port
  $Port = Find-AvailableTcpPort -Address $BindAddress -StartPort $Port
  if ($Port -ne $requestedPort) {
    Write-Warning "Requested share port $requestedPort is already in use; using $Port instead."
  }
}

$script:ShareLanDiagnostics = @(Get-ShareLanDiagnosticsForBind -Address $BindAddress -SharePort $Port)
$script:ShareLanUrls = @($script:ShareLanDiagnostics | ForEach-Object { [string]$_.url })
$script:ShareUrlProbeResults = @()
$script:ShareProbeUrl = if ($BindAddress -eq "0.0.0.0") {
  "http://127.0.0.1`:$Port/"
} else {
  "http://$BindAddress`:$Port/"
}

Write-LanTroubleshooting
Write-ShareProbeReport -Status "prepared"
Write-ShareStatus -Status "prepared"
Write-OpenLocalShareHelper -LocalUrl "http://127.0.0.1`:$Port/"

Write-Host "Release share folder:"
Write-Host $shareRoot
Write-Host "Host-only URL for this Windows machine:"
Write-Host "http://127.0.0.1`:$Port/"
Write-Host "Host-only open helper:"
Write-Host (Join-Path $shareRoot "OPEN_LOCAL_SHARE.cmd")
if ($script:ShareLanUrls.Count -gt 0) {
  Write-Host "Same-network URL candidates:"
  foreach ($lanCandidate in $script:ShareLanDiagnostics) {
    Write-Host "$($lanCandidate.url)  [$($lanCandidate.interfaceAlias); $(@($lanCandidate.notes) -join ', ')]"
  }
} elseif ($BindAddress -eq "0.0.0.0") {
  Write-Warning "No active non-loopback IPv4 address was detected. The loopback URL should still work on this machine."
}
Write-Host "LAN troubleshooting report:"
Write-Host (Join-Path $shareRoot "LAN_TROUBLESHOOTING.md")

if ($NoServe) {
  if ($OpenLocal) {
    Write-Warning "-OpenLocal was ignored because -NoServe only prepares the share folder."
  }
  exit 0
}

$pythonPath = Get-PythonPath
if ($CloudflareTunnel) {
  $cloudflaredPath = Get-CloudflaredPath
}

$serverArgs = @(
  "-m",
  "http.server",
  [string]$Port,
  "--bind",
  $BindAddress,
  "--directory",
  $shareRoot
)
$serverOutLog = Join-Path $shareRoot "server.stdout.log"
$serverErrLog = Join-Path $shareRoot "server.stderr.log"
Remove-Item -LiteralPath $serverOutLog, $serverErrLog -Force -ErrorAction SilentlyContinue
$server = Start-Process -FilePath $pythonPath -ArgumentList $serverArgs -WindowStyle Hidden -RedirectStandardOutput $serverOutLog -RedirectStandardError $serverErrLog -PassThru
$server.Id | Set-Content -Path (Join-Path $shareRoot "server.pid") -Encoding ASCII
Write-StopHelper -ProcessIds @($server.Id)
Write-ShareStatus -Status "local" -ProcessIds @($server.Id)
Write-Host "Started local server PID $($server.Id)"
Write-Host "Waiting for local share page to answer..."
if (-not (Wait-LocalUrlReady -TargetUrl $script:ShareProbeUrl)) {
  $script:ShareUrlProbeResults = @(Test-ShareUrlsFromHost -Urls (@("http://127.0.0.1`:$Port/") + $script:ShareLanUrls))
  Write-ShareProbeReport -Status "local-readiness-failed"
  Write-LanTroubleshooting
  Write-ShareStatus -Status "local-readiness-failed" -ProcessIds @($server.Id)
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  throw "Local share page did not answer before the readiness timeout: $script:ShareProbeUrl"
}

$script:ShareUrlProbeResults = @(Test-ShareUrlsFromHost -Urls (@("http://127.0.0.1`:$Port/") + $script:ShareLanUrls))
Write-ShareProbeReport -Status "local-ready"
Write-LanTroubleshooting
Write-ShareStatus -Status "local" -ProcessIds @($server.Id)
if ($OpenLocal) {
  Invoke-OpenLocalShare -LocalUrl $script:ShareProbeUrl
}

if ($CloudflareTunnel) {
  $cloudflaredOutLog = Join-Path $shareRoot "cloudflared.stdout.log"
  $cloudflaredErrLog = Join-Path $shareRoot "cloudflared.stderr.log"
  Remove-Item -LiteralPath $cloudflaredOutLog, $cloudflaredErrLog -Force -ErrorAction SilentlyContinue

  $tunnelOriginUrl = $script:ShareProbeUrl.TrimEnd("/")
  $tunnelArgs = @("tunnel", "--url", $tunnelOriginUrl)
  $tunnel = Start-Process -FilePath $cloudflaredPath -ArgumentList $tunnelArgs -WindowStyle Hidden -RedirectStandardOutput $cloudflaredOutLog -RedirectStandardError $cloudflaredErrLog -PassThru
  $tunnel.Id | Set-Content -Path (Join-Path $shareRoot "cloudflared.pid") -Encoding ASCII
  Write-StopHelper -ProcessIds @($server.Id, $tunnel.Id)
  Write-ShareStatus -Status "tunnel-starting" -ProcessIds @($server.Id, $tunnel.Id)
  Write-Host "Started cloudflared PID $($tunnel.Id)"
  Write-Host "Waiting up to $TunnelWaitSeconds seconds for the public tunnel URL..."

  $publicUrl = $null
  $publicUrlReady = $false
  $deadline = (Get-Date).AddSeconds($TunnelWaitSeconds)
  while ((Get-Date) -lt $deadline -and [string]::IsNullOrWhiteSpace($publicUrl)) {
    $publicUrl = Find-CloudflarePublicUrl -LogPaths @($cloudflaredOutLog, $cloudflaredErrLog)

    if ([string]::IsNullOrWhiteSpace($publicUrl)) {
      Start-Sleep -Milliseconds 500
    }
  }

  if ([string]::IsNullOrWhiteSpace($publicUrl)) {
    Start-Sleep -Seconds 2
    $publicUrl = Find-CloudflarePublicUrl -LogPaths @($cloudflaredOutLog, $cloudflaredErrLog)
  }

  if ([string]::IsNullOrWhiteSpace($publicUrl)) {
    Write-ShareStatus -Status "tunnel-url-pending" -ProcessIds @($server.Id, $tunnel.Id)
    Write-Warning "Cloudflare tunnel started, but no public URL was found yet."
    Write-Host "Cloudflared stdout log: $cloudflaredOutLog"
    Write-Host "Cloudflared stderr log: $cloudflaredErrLog"
  } else {
    Write-Host "Public tunnel URL:"
    Write-Host $publicUrl
    Write-Host "Waiting up to $PublicUrlReadyWaitSeconds seconds for the public tunnel page to answer..."
    $publicUrlReady = Wait-PublicUrlReady -TargetUrl $publicUrl
    if ($publicUrlReady) {
      Write-ShareStatus -Status "tunnel-ready" -PublicUrl $publicUrl -PublicUrlReady $true -ProcessIds @($server.Id, $tunnel.Id)
      Write-Host "Public tunnel page is ready."
    } else {
      Write-ShareStatus -Status "tunnel-url-pending" -PublicUrl $publicUrl -PublicUrlReady $false -ProcessIds @($server.Id, $tunnel.Id)
      Write-Warning "Cloudflare tunnel URL was found, but the public page did not answer before the readiness timeout."
      Write-Host "Cloudflared stdout log: $cloudflaredOutLog"
      Write-Host "Cloudflared stderr log: $cloudflaredErrLog"
    }
  }

  if ($StopAfterUrl) {
    $stopIds = @($server.Id, $tunnel.Id)
    Stop-Process -Id $stopIds -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $stopIds -Timeout 5 -ErrorAction SilentlyContinue
    Write-ShareStatus -Status "stopped-after-url" -PublicUrl $publicUrl -PublicUrlReady $publicUrlReady -ProcessIds @($stopIds)
    Write-Host "Stopped sharing processes after tunnel check."
    exit 0
  }
}

Write-Host "Stop sharing command:"
if ($CloudflareTunnel) {
  Write-Host "Stop-Process -Id $($server.Id),$($tunnel.Id)"
} else {
  Write-Host "Stop-Process -Id $($server.Id)"
}
