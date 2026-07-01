param(
  [string]$Version,
  [int]$Port = 8787,
  [string]$BindAddress = "127.0.0.1",
  [switch]$CloudflareTunnel,
  [switch]$DownloadCloudflared,
  [int]$TunnelWaitSeconds = 30,
  [int]$PublicUrlReadyWaitSeconds = 120,
  [int]$PublicUrlReadyPollSeconds = 2,
  [switch]$StopAfterUrl,
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
    [int[]]$ProcessIds = @()
  )

  $statusObject = [ordered]@{
    version = $Version
    status = $Status
    generatedUtc = $generatedUtc
    updatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    localUrl = "http://$BindAddress`:$Port/"
    publicUrl = $PublicUrl
    publicUrlReady = $PublicUrlReady
    processIds = @($ProcessIds)
    shareRoot = $shareRoot
  }

  $statusObject | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $shareRoot "share_status.json") -Encoding UTF8
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

$shareRoot = Join-Path $repoRoot "output/share/$Version"
if (Test-Path -LiteralPath $shareRoot) {
  Remove-Item -LiteralPath $shareRoot -Recurse -Force
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
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_greeting.wav"); Name = "voice/stackchan_spark_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_thinking.wav"); Name = "voice/stackchan_spark_thinking.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_safety.wav"); Name = "voice/stackchan_spark_safety.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_audition_warm_slow_greeting.wav"); Name = "voice/stackchan_spark_audition_warm_slow_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.wav"); Name = "voice/stackchan_spark_audition_bright_robot_greeting.wav" },
  @{ Source = (Join-Path $packageRoot "media/voice/VOICE_SAMPLES.md"); Name = "voice/VOICE_SAMPLES.md" },
  @{ Source = (Join-Path $packageRoot "ARRIVAL_DAY_RUNBOOK.md"); Name = "ARRIVAL_DAY_RUNBOOK.md" },
  @{ Source = (Join-Path $packageRoot "QUICKSTART.md"); Name = "QUICKSTART.md" },
  @{ Source = (Join-Path $packageRoot "RELEASE_NOTES.md"); Name = "RELEASE_NOTES.md" },
  @{ Source = (Join-Path $packageRoot "RELEASE_ACCEPTANCE.md"); Name = "RELEASE_ACCEPTANCE.md" },
  @{ Source = (Join-Path $packageRoot "release_acceptance.json"); Name = "release_acceptance.json" },
  @{ Source = (Join-Path $packageRoot "GITHUB_ACTIONS_STATUS.md"); Name = "GITHUB_ACTIONS_STATUS.md" },
  @{ Source = (Join-Path $packageRoot "github_actions_status.json"); Name = "github_actions_status.json" },
  @{ Source = (Join-Path $packageRoot "DEPENDENCIES.md"); Name = "DEPENDENCIES.md" },
  @{ Source = (Join-Path $packageRoot "dependency_lock.json"); Name = "dependency_lock.json" },
  @{ Source = (Join-Path $packageRoot "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"); Name = "VOICE_SOURCE_PROVENANCE_TEMPLATE.md" },
  @{ Source = (Join-Path $packageRoot "data/voice_source_provenance.yaml"); Name = "voice_source_provenance.yaml" },
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

  <h2>Voice Samples</h2>
  <p>Prototype Stackchan Spark Synth v3 audition samples. These use a lightweight source with phrase-level micro-prosody, syllable gating, a speech-envelope electromechanical mask, formant-like resonators, sample-hold texture, ring modulation, comb resonance, and tiny synthetic chirps. They are original direction samples, not a character clone, and final consumer rollout still requires a licensed or owned production voice source.</p>
  <div class="grid">
    <div class="item">
      <strong>Greeting</strong>
      <audio src="voice/stackchan_spark_greeting.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p><a href="voice/stackchan_spark_greeting.wav">Download WAV</a></p>
    </div>
    <div class="item">
      <strong>Thinking</strong>
      <audio src="voice/stackchan_spark_thinking.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Input received. I am thinking now. Curiosity level rising.</p>
      <p><a href="voice/stackchan_spark_thinking.wav">Download WAV</a></p>
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
      <audio src="voice/stackchan_spark_audition_bright_robot_greeting.wav" controls preload="metadata"></audio>
      <p class="transcript"><strong>Transcript:</strong> Hello. I am Stackchan, and I am awake.</p>
      <p>Brighter and more synthetic for stronger robot character checks.</p>
      <p><a href="voice/stackchan_spark_audition_bright_robot_greeting.wav">Download WAV</a></p>
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

  <h2>Voice Source Gate</h2>
  <p>The current WAVs are review-only prototype samples. Production TTS remains blocked until the voice source is licensed or owned, the provenance template is completed, and real-device speaker evidence is captured.</p>
  <p>For the next formant-source audition pass, run <code>.\tools\setup_voice_tools.cmd -InstallEspeak -RenderEspeakSamples</code>, then rebuild the release. This keeps the Stackchan Spark Synth v3 DSP but replaces the fallback Windows source with eSpeak-NG when available.</p>
  <div class="status">
    <span class="pill pending">Voice source: pending production source</span>
    <span class="pill pending">Rollout gate: licensed or owned production voice required</span>
    <span class="pill pending">Speaker evidence: pending device</span>
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
    <div class="item"><a href="voice/VOICE_SAMPLES.md">Voice Sample Notes</a></div>
    <div class="item"><a href="voice/stackchan_spark_audition_warm_slow_greeting.wav">Warm Slow Voice Audition</a></div>
    <div class="item"><a href="voice/stackchan_spark_audition_bright_robot_greeting.wav">Bright Robot Voice Audition</a></div>
    <div class="item"><a href="VOICE_SOURCE_PROVENANCE_TEMPLATE.md">Voice Source Provenance Template</a></div>
    <div class="item"><a href="voice_source_provenance.yaml">Voice Source Provenance YAML</a></div>
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
</main>
</body>
</html>
"@ | Set-Content -Path (Join-Path $shareRoot "index.html") -Encoding UTF8

Write-ShareStatus -Status "prepared"

Write-Host "Release share folder:"
Write-Host $shareRoot
Write-Host "Local URL:"
Write-Host "http://$BindAddress`:$Port/"

if ($NoServe) {
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
$localUrl = "http://$BindAddress`:$Port/"
Write-Host "Waiting for local share page to answer..."
if (-not (Wait-LocalUrlReady -TargetUrl $localUrl)) {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  throw "Local share page did not answer before the readiness timeout: $localUrl"
}

if ($CloudflareTunnel) {
  $cloudflaredOutLog = Join-Path $shareRoot "cloudflared.stdout.log"
  $cloudflaredErrLog = Join-Path $shareRoot "cloudflared.stderr.log"
  Remove-Item -LiteralPath $cloudflaredOutLog, $cloudflaredErrLog -Force -ErrorAction SilentlyContinue

  $tunnelArgs = @("tunnel", "--url", "http://$BindAddress`:$Port")
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
