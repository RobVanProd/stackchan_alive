param(
  [string]$Version = "",
  [string]$ShareRoot = "",
  [string]$Url = "",
  [switch]$RequirePublicUrl,
  [int]$TimeoutSeconds = 20,
  [int]$ProbeRetries = 20,
  [int]$ProbeDelaySeconds = 3,
  [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Assert-File {
  param(
    [string]$Path,
    [int64]$MinBytes = 1
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing share file: $Path"
  }

  $item = Get-Item -LiteralPath $Path
  if ($item.Length -lt $MinBytes) {
    throw "Share file is too small: $Path ($($item.Length) bytes)"
  }
}

function Join-Url {
  param(
    [string]$BaseUrl,
    [string]$Path
  )

  return $BaseUrl.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Invoke-UrlProbe {
  param(
    [string]$TargetUrl,
    [int]$TimeoutSeconds,
    [int]$ProbeRetries,
    [int]$ProbeDelaySeconds
  )

  $maxAttempts = [Math]::Max(1, $ProbeRetries)
  $delaySeconds = [Math]::Max(0, $ProbeDelaySeconds)
  $lastError = ""
  $lastDnsError = ""
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
      $method = "curl"
      $resolvedAddress = ""
      $curlArgs = @("-L", "-I", "--max-time", $TimeoutSeconds, "--silent", "--show-error", $TargetUrl)
      $oldErrorActionPreference = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      try {
        $head = & $curl.Source @curlArgs 2>&1
        $curlExitCode = $LASTEXITCODE
      } finally {
        $ErrorActionPreference = $oldErrorActionPreference
      }

      if ($curlExitCode -ne 0 -and ($head | Out-String) -match "Could not resolve host") {
        try {
          $uri = [System.Uri]$TargetUrl
          if ($uri.Scheme -eq "https" -and $uri.Host -match "\.trycloudflare\.com$") {
            $resolvedAddress = Resolve-DnsName $uri.Host -Server 1.1.1.1 -Type A -ErrorAction Stop |
              Select-Object -First 1 -ExpandProperty IPAddress
            if (-not [string]::IsNullOrWhiteSpace($resolvedAddress)) {
              $method = "curl-resolve"
              $resolveArg = "$($uri.Host):443:$resolvedAddress"
              $oldErrorActionPreference = $ErrorActionPreference
              $ErrorActionPreference = "Continue"
              try {
                $head = & $curl.Source -L -I --resolve $resolveArg --max-time $TimeoutSeconds --silent --show-error $TargetUrl 2>&1
                $curlExitCode = $LASTEXITCODE
              } finally {
                $ErrorActionPreference = $oldErrorActionPreference
              }
            }
          }
        } catch {
          $lastDnsError = $_.Exception.Message
          $lastError = $lastDnsError
        }
      }

      if ($curlExitCode -eq 0) {
        $lines = @($head -split "`r?`n")
        $statusLine = @($lines | Where-Object { $_ -match "^HTTP/" } | Select-Object -Last 1)
        if ($statusLine.Count -eq 0) {
          throw "No HTTP status line returned for $TargetUrl"
        }

        $contentType = @($lines | Where-Object { $_ -match "^content-type:" } | Select-Object -Last 1)
        $contentLength = @($lines | Where-Object { $_ -match "^content-length:" } | Select-Object -Last 1)

        return [ordered]@{
          Url = $TargetUrl
          StatusLine = [string]$statusLine[0]
          ContentType = if ($contentType.Count -gt 0) { [string]$contentType[0] } else { "" }
          ContentLength = if ($contentLength.Count -gt 0) { [string]$contentLength[0] } else { "" }
          Method = $method
          ResolvedAddress = $resolvedAddress
        }
      }

      $lastError = "curl.exe failed with exit code $curlExitCode`: $(($head | Out-String).Trim())"
      if (-not [string]::IsNullOrWhiteSpace($lastDnsError)) {
        $lastError += " Public DNS fallback error: $lastDnsError"
      }
    }

    try {
      $response = Invoke-WebRequest -Uri $TargetUrl -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing
      return [ordered]@{
        Url = $TargetUrl
        StatusLine = "HTTP $([int]$response.StatusCode)"
        ContentType = [string]$response.Headers["Content-Type"]
        ContentLength = [string]$response.Headers["Content-Length"]
        Method = "Invoke-WebRequest"
        ResolvedAddress = ""
      }
    } catch {
      $lastError = $_.Exception.Message
    }

    if ($attempt -lt $maxAttempts -and $delaySeconds -gt 0) {
      Start-Sleep -Seconds $delaySeconds
    }
  }

  throw "Share URL probe failed after $maxAttempts retries for $TargetUrl. Last error: $lastError"
}

function Write-VerificationReport {
  param(
    [string]$ReportBasePath,
    [string]$Version,
    [string]$Url,
    [bool]$RequiredPublicUrl,
    [object[]]$Probes,
    [string]$ShareRootPath,
    [object]$ShareStatus
  )

  $lanUrls = @()
  if ($null -ne $ShareStatus -and $null -ne $ShareStatus.lanUrls) {
    $lanUrls = @($ShareStatus.lanUrls)
  }

  $reportObject = [ordered]@{
    schema = "stackchan.share-verification.v1"
    version = $Version
    generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    url = $Url
    requirePublicUrl = $RequiredPublicUrl
    shareRoot = $ShareRootPath
    bindAddress = if ($null -ne $ShareStatus) { [string]$ShareStatus.bindAddress } else { "" }
    loopbackUrl = if ($null -ne $ShareStatus) { [string]$ShareStatus.loopbackUrl } else { "" }
    lanUrls = @($lanUrls)
    probeCount = $Probes.Count
    allHttp200 = (@($Probes | Where-Object { $_.StatusLine -notmatch "\s200\s" }).Count -eq 0)
    usedCurlResolveFallback = (@($Probes | Where-Object { $_.Method -eq "curl-resolve" }).Count -gt 0)
    probes = @($Probes)
  }

  $jsonPath = $ReportBasePath
  if (-not $jsonPath.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
    $jsonPath = "$ReportBasePath.json"
  }
  $mdPath = [System.IO.Path]::ChangeExtension($jsonPath, ".md")

  $reportObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $fallbackText = if ($reportObject.usedCurlResolveFallback) { "yes" } else { "no" }
  $reportFileName = [System.IO.Path]::GetFileName($jsonPath)
  @(
    "# Share Verification Report",
    "",
    "- Version: $Version",
    "- URL: $Url",
    "- Generated UTC: $($reportObject.generatedUtc)",
    "- Public URL required: $RequiredPublicUrl",
    "- Bind address: $($reportObject.bindAddress)",
    "- LAN URL candidates: $(@($reportObject.lanUrls).Count)",
    "- Probe count: $($reportObject.probeCount)",
    "- All probes HTTP 200: $($reportObject.allHttp200)",
    "- Used curl DNS override fallback: $fallbackText",
    "",
    "Machine-readable report: ``$reportFileName``"
  ) | Set-Content -LiteralPath $mdPath -Encoding UTF8

  return [ordered]@{
    JsonPath = $jsonPath
    MarkdownPath = $mdPath
  }
}

function Assert-HttpOk {
  param(
    [object]$Probe,
    [string]$ExpectedType,
    [string]$Path
  )

  if ($Probe.StatusLine -notmatch "\s200\s") {
    throw "Share URL did not return HTTP 200 for $Path`: $($Probe.StatusLine)"
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedType) -and $Probe.ContentType -notmatch [regex]::Escape($ExpectedType)) {
    throw "Share URL content type mismatch for $Path`: expected $ExpectedType, got $($Probe.ContentType)"
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $manifestPath = Join-Path $repoRoot "release_manifest.json"
  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $Version = [string]$manifest.version
  } else {
    $Version = (git describe --tags --always --dirty).Trim()
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "Version is required when it cannot be inferred."
}

if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
  $ShareRoot = Join-Path $repoRoot "output/share/$Version"
}

if (-not (Test-Path -LiteralPath $ShareRoot)) {
  throw "Missing share folder: $ShareRoot"
}

$shareRootPath = (Resolve-Path $ShareRoot).Path
$statusPath = Join-Path $shareRootPath "share_status.json"
$publicUrlPath = Join-Path $shareRootPath "PUBLIC_URL.txt"

$status = $null
if (Test-Path -LiteralPath $statusPath) {
  $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  if ($status.version -ne $Version) {
    throw "share_status.json version mismatch: expected $Version, got $($status.version)"
  }
}

if ([string]::IsNullOrWhiteSpace($Url) -and (Test-Path -LiteralPath $publicUrlPath)) {
  $Url = (Get-Content -LiteralPath $publicUrlPath -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($Url) -and $null -ne $status -and -not [string]::IsNullOrWhiteSpace([string]$status.publicUrl)) {
  $Url = [string]$status.publicUrl
}

if ([string]::IsNullOrWhiteSpace($Url) -and $null -ne $status -and -not [string]::IsNullOrWhiteSpace([string]$status.localUrl)) {
  $Url = [string]$status.localUrl
}

if ($RequirePublicUrl -and $Url -notmatch "^https://[-A-Za-z0-9]+\.trycloudflare\.com/?$") {
  throw "Expected a trycloudflare.com public URL, got: $Url"
}

if ([string]::IsNullOrWhiteSpace($Url)) {
  throw "No share URL found. Pass -Url or start share_release first."
}

$expectedFiles = @(
  @{ Path = "index.html"; MinBytes = 500; Type = "text/html" },
  @{ Path = "stackchan_alive_$Version.zip"; MinBytes = 1000000; Type = "application" },
  @{ Path = "stackchan_alive_$Version.zip.sha256"; MinBytes = 80; Type = "" },
  @{ Path = "stackchan_alive_preview.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "stackchan_alive_expression_sheet.png"; MinBytes = 2000; Type = "image/png" },
  @{ Path = "stackchan_alive_preview.mp4"; MinBytes = 1000; Type = "video/mp4" },
  @{ Path = "stackchan_alive_preview.gif"; MinBytes = 1000; Type = "image/gif" },
  @{ Path = "stackchan_alive_speech_preview.gif"; MinBytes = 1000; Type = "image/gif" },
  @{ Path = "artifacts/face/phase_a_idle_10s.gif"; MinBytes = 100000; Type = "image/gif" },
  @{ Path = "artifacts/face/phase_a_blink_filmstrip_50ms.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_a_unlabeled_expression_sheet.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_b_unlabeled_expression_sheet.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_c_idle_10s.gif"; MinBytes = 100000; Type = "image/gif" },
  @{ Path = "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "artifacts/face/phase_e_speech_reactive_6s.gif"; MinBytes = 1000; Type = "image/gif" },
  @{ Path = "voice/stackchan_spark_greeting.wav"; MinBytes = 1000; Type = "audio/" },
  @{ Path = "voice/stackchan_spark_thinking.wav"; MinBytes = 1000; Type = "audio/" },
  @{ Path = "voice/stackchan_spark_safety.wav"; MinBytes = 1000; Type = "audio/" },
  @{ Path = "voice/stackchan_spark_audition_warm_slow_greeting.wav"; MinBytes = 1000; Type = "audio/" },
  @{ Path = "voice/stackchan_spark_audition_bright_robot_greeting.wav"; MinBytes = 1000; Type = "audio/" },
  @{ Path = "voice/VOICE_SAMPLES.md"; MinBytes = 100; Type = "" },
  @{ Path = "voice/rvc/RVC_AUDITIONS.md"; MinBytes = 500; Type = "" },
  @{ Path = "voice/rvc/RVC_AUDITIONS.json"; MinBytes = 500; Type = "" },
  @{ Path = "voice/rvc/stackchan_rvc_neutral.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_warm_slow.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_bright_robot.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_bright_robot_less_static.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_spark_boops.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_high_character.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_thinking_neutral.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "voice/rvc/stackchan_rvc_safety_neutral.wav"; MinBytes = 100000; Type = "audio/" },
  @{ Path = "ARRIVAL_DAY_RUNBOOK.md"; MinBytes = 100; Type = "" },
  @{ Path = "QUICKSTART.md"; MinBytes = 100; Type = "" },
  @{ Path = "RELEASE_ACCEPTANCE.md"; MinBytes = 100; Type = "" },
  @{ Path = "release_acceptance.json"; MinBytes = 100; Type = "" },
  @{ Path = "GITHUB_ACTIONS_STATUS.md"; MinBytes = 100; Type = "" },
  @{ Path = "github_actions_status.json"; MinBytes = 100; Type = "" },
  @{ Path = "DEPENDENCIES.md"; MinBytes = 100; Type = "" },
  @{ Path = "dependency_lock.json"; MinBytes = 100; Type = "" },
  @{ Path = "VOICE_SOURCE_STATUS.md"; MinBytes = 100; Type = "" },
  @{ Path = "voice_source_status.json"; MinBytes = 100; Type = "" },
  @{ Path = "VOICE_SOURCE_PROVENANCE_TEMPLATE.md"; MinBytes = 100; Type = "" },
  @{ Path = "voice_source_provenance.yaml"; MinBytes = 100; Type = "" },
  @{ Path = "voice_rvc_base.yaml"; MinBytes = 100; Type = "" },
  @{ Path = "voice_rvc_base_metadata.json"; MinBytes = 100; Type = "" },
  @{ Path = "RVC_VOICE_BASE_STATUS.md"; MinBytes = 500; Type = "" },
  @{ Path = "rvc_voice_base_status.json"; MinBytes = 500; Type = "" },
  @{ Path = "OPEN_LOCAL_SHARE.cmd"; MinBytes = 50; Type = "" },
  @{ Path = "LAN_TROUBLESHOOTING.md"; MinBytes = 500; Type = "" },
  @{ Path = "share_probe_report.json"; MinBytes = 100; Type = "" },
  @{ Path = "RELEASE_NOTES.md"; MinBytes = 100; Type = "" },
  @{ Path = "READINESS_REPORT.md"; MinBytes = 100; Type = "" },
  @{ Path = "readiness_report.json"; MinBytes = 100; Type = "" },
  @{ Path = "SHA256SUMS.txt"; MinBytes = 100; Type = "" }
)

$hasPreflightReport = (Test-Path -LiteralPath (Join-Path $shareRootPath "preflight_report.md")) -and (Test-Path -LiteralPath (Join-Path $shareRootPath "preflight_report.json"))
if ($hasPreflightReport) {
  $expectedFiles += @(
    @{ Path = "preflight_report.md"; MinBytes = 100; Type = "" },
    @{ Path = "preflight_report.json"; MinBytes = 100; Type = "" }
  )
}

foreach ($file in $expectedFiles) {
  Assert-File (Join-Path $shareRootPath $file.Path) $file.MinBytes
}

$zipName = "stackchan_alive_$Version.zip"
$zipHashPath = Join-Path $shareRootPath "$zipName.sha256"
$zipHashText = (Get-Content -LiteralPath $zipHashPath -Raw).Trim()
if ($zipHashText -notmatch "^([a-f0-9]{64})  $([regex]::Escape($zipName))$") {
  throw "Invalid ZIP SHA256 sidecar format: $zipHashText"
}

$expectedZipHash = $Matches[1]
$actualZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $shareRootPath $zipName)).Hash.ToLowerInvariant()
if ($actualZipHash -ne $expectedZipHash) {
  throw "ZIP SHA256 sidecar mismatch for $zipName"
}

$indexText = Get-Content -LiteralPath (Join-Path $shareRootPath "index.html") -Raw
foreach ($pattern in @($Version, "Hardware validation is still pending", "No-hardware gates passed", "Hardware gates pending", "Consumer rollout", "GitHub Actions", "Speaker audio evidence", "Preflight Evidence", "No-hardware device preflight", "Pending Promotion Gates", "Do not mark this release consumer-ready", "display-only-flash", "servo-calibration", "mixed-mode-soak", "power-cycle-recovery", "target-speaker-audio-evidence", "hardware-evidence-verification", "production-voice-source", "completed AUDIO_REVIEW.md plus a real-device speaker recording under audio/", "Dependency Provenance", "Declared library deps", "Direct Git deps missing refs", "Resolved Git deps without SHA", "SCServo#ee6ee4a", "DEPENDENCIES.md", "dependency_lock.json", "stackchan_alive_preview.png", "stackchan_alive_expression_sheet.png", "stackchan_alive_preview.mp4", "stackchan_alive_speech_preview.gif", "Voice Samples", "Stackchan Spark Synth v4", "micro-prosody", "syllable gating", "electromechanical mask", "formant-like resonators", "sample-hold texture", "comb resonance", "light musical vocoder", "phrase-timed chirp/boop accents", "RVC Voice Auditions", "Current Lead: RVC Bright Robot", "Selected settings", "pitch 2, index 0.62, RMS mix 0.72, protect 0.28", "near-final direction", "bright synthetic robot character", "RVC Neutral", "RVC Warm Slow", "RVC Bright Robot", "RVC Bright Robot Less Static", "RVC Bright Robot Sweet Vocoder", "RVC Bright Robot Soft Boops", "RVC Spark Boops", "RVC High Character", "stackchan_rvc_neutral.wav", "stackchan_rvc_bright_robot_less_static.wav", "stackchan_rvc_safety_neutral.wav", "eSpeak-NG", "setup_voice_tools.cmd", "RenderEspeakSamples", "Voice Review Checklist", "Voice Source Gate", "blocked-pending-production-voice-source", "blocked voice-source gates", "VOICE_SOURCE_STATUS.md", "voice_source_status.json", "pending production source", "licensed or owned production voice required", "RVC Candidate Base", "candidate-pending-rights-review", "Weights.gg", "clyaxlb9b000eoiqywl68wcrc", "CA0BFE7A889D81532A449307057718BF83B343BD09D6B69CAF2DFB79450EF9AE", "RVC_VOICE_BASE_STATUS.md", "rvc_voice_base_status.json", "Generated RVC base status", "local archive verified for review cache", "voice_rvc_base.yaml", "voice_rvc_base_metadata.json", "Hardware Audio Evidence", "AUDIO_REVIEW.md", "audio/", "real-device speaker sample", "Generated source WAVs alone do not count", "VOICE_SOURCE_PROVENANCE_TEMPLATE.md", "voice_source_provenance.yaml", "ARRIVAL_DAY_RUNBOOK.md", "Transcript:", "Hello. I am Stackchan, and I am awake.", "Input received. I am thinking now. Curiosity level rising.", "Small problem found. I can help fix it. Safety first.", "Audition: Warm Slow", "Audition: Bright Robot", "Warmer and slightly slower", "Brighter synthetic pass", "voice/stackchan_spark_greeting.wav", "voice/stackchan_spark_thinking.wav", "voice/stackchan_spark_safety.wav", "voice/stackchan_spark_audition_warm_slow_greeting.wav", "voice/stackchan_spark_audition_bright_robot_greeting.wav", "voice/rvc/RVC_AUDITIONS.md", "voice/rvc/stackchan_rvc_bright_robot.wav", "voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav", "Arrival-Day Evidence Loop", "RUN_DISPLAY_ONLY.cmd", "RUN_SERVO_CALIBRATION.cmd", "RUN_PROGRESS_CHECK.cmd", "RUN_EVIDENCE_VERIFY.cmd", "RUN_CONSUMER_PROMOTION_CHECK.cmd", "Share Diagnostics", "OPEN_LOCAL_SHARE.cmd", "LAN_TROUBLESHOOTING.md", "share_probe_report.json", "share_status.json", "virtual/VPN adapters", "RELEASE_ACCEPTANCE.md", "release_acceptance.json", "GITHUB_ACTIONS_STATUS.md", "github_actions_status.json", "READINESS_REPORT.md", "readiness_report.json", "SHA256SUMS.txt", "stackchan_alive_$Version.zip", "stackchan_alive_$Version.zip.sha256")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected share guidance: $pattern"
  }
}

$lanTroubleshootingText = Get-Content -LiteralPath (Join-Path $shareRootPath "LAN_TROUBLESHOOTING.md") -Raw
foreach ($pattern in @("Stackchan Share LAN Troubleshooting", "OPEN_LOCAL_SHARE.cmd", "LAN URL Candidates", "Host Reachability Probes", "same Wi-Fi/LAN", "virtual", "Windows Firewall")) {
  if ($lanTroubleshootingText -notmatch [regex]::Escape($pattern)) {
    throw "LAN_TROUBLESHOOTING.md missing expected guidance: $pattern"
  }
}

$shareProbeReport = Get-Content -LiteralPath (Join-Path $shareRootPath "share_probe_report.json") -Raw | ConvertFrom-Json
if ($shareProbeReport.schema -ne "stackchan.share-probe-report.v1") {
  throw "share_probe_report.json schema mismatch: $($shareProbeReport.schema)"
}
if ($shareProbeReport.version -ne $Version) {
  throw "share_probe_report.json version mismatch: expected $Version, got $($shareProbeReport.version)"
}
if ($null -ne $status) {
  foreach ($propertyName in @("lanDiagnostics", "hostProbeResults", "lanTroubleshooting", "shareProbeReport", "openLocalShare", "openLocalRequested")) {
    if ($status.PSObject.Properties.Name -notcontains $propertyName) {
      throw "share_status.json missing LAN diagnostic field: $propertyName"
    }
  }
}

foreach ($pattern in @("Face Phase A Artifacts", "double-buffered M5Canvas", "frame telemetry", "layered animator skeleton", "tools/verify_face_phase_a.ps1", "phase_a_idle_10s.gif", "phase_a_blink_filmstrip_50ms.png", "phase_a_unlabeled_expression_sheet.png")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected Phase A face guidance: $pattern"
  }
}

foreach ($pattern in @("Face Phase B Artifacts", "procedural eye-corner cuts", "angled lids", "two-curve open mouth", "authored L0 pose keys", "phase_b_unlabeled_expression_sheet.png")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected Phase B face guidance: $pattern"
  }
}

foreach ($pattern in @("Face Phase C Artifacts", "autonomic blink state machine", "saccade jumps with settle", "breathing offset", "reduced-motion damping", "phase_c_idle_10s.gif")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected Phase C face guidance: $pattern"
  }
}

foreach ($pattern in @("Face Phase D Artifacts", "transition choreography clips", "visible anticipation", "staggered channel arrival", "tools/verify_face_phase_d.ps1", "phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected Phase D face guidance: $pattern"
  }
}

foreach ($pattern in @("Face Phase E Artifacts", "speech envelope sidecar", "L3 mouth ownership", "viseme-lite", "loud-syllable brow accents", "return-to-rest", "tools/verify_face_phase_e.ps1", "phase_e_speech_reactive_6s.gif")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected Phase E face guidance: $pattern"
  }
}

if ($hasPreflightReport) {
  foreach ($pattern in @("Preflight: pass", "preflight_report.md", "preflight_report.json")) {
    if ($indexText -notmatch [regex]::Escape($pattern)) {
      throw "index.html missing expected attached preflight guidance: $pattern"
    }
  }
}

$probes = @()
$probedPaths = @("index.html", "stackchan_alive_$Version.zip", "stackchan_alive_$Version.zip.sha256", "stackchan_alive_preview.png", "stackchan_alive_expression_sheet.png", "stackchan_alive_preview.mp4", "stackchan_alive_preview.gif", "stackchan_alive_speech_preview.gif", "artifacts/face/phase_a_idle_10s.gif", "artifacts/face/phase_a_blink_filmstrip_50ms.png", "artifacts/face/phase_a_unlabeled_expression_sheet.png", "artifacts/face/phase_b_unlabeled_expression_sheet.png", "artifacts/face/phase_c_idle_10s.gif", "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png", "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png", "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png", "artifacts/face/phase_e_speech_reactive_6s.gif", "voice/stackchan_spark_greeting.wav", "voice/stackchan_spark_thinking.wav", "voice/stackchan_spark_safety.wav", "voice/stackchan_spark_audition_warm_slow_greeting.wav", "voice/stackchan_spark_audition_bright_robot_greeting.wav", "voice/rvc/RVC_AUDITIONS.md", "voice/rvc/RVC_AUDITIONS.json", "voice/rvc/stackchan_rvc_neutral.wav", "voice/rvc/stackchan_rvc_warm_slow.wav", "voice/rvc/stackchan_rvc_bright_robot.wav", "voice/rvc/stackchan_rvc_bright_robot_less_static.wav", "voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav", "voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav", "voice/rvc/stackchan_rvc_spark_boops.wav", "voice/rvc/stackchan_rvc_high_character.wav", "voice/rvc/stackchan_rvc_thinking_neutral.wav", "voice/rvc/stackchan_rvc_safety_neutral.wav", "ARRIVAL_DAY_RUNBOOK.md", "OPEN_LOCAL_SHARE.cmd", "LAN_TROUBLESHOOTING.md", "share_probe_report.json", "RELEASE_ACCEPTANCE.md", "release_acceptance.json", "GITHUB_ACTIONS_STATUS.md", "github_actions_status.json", "DEPENDENCIES.md", "dependency_lock.json", "VOICE_SOURCE_STATUS.md", "voice_source_status.json", "VOICE_SOURCE_PROVENANCE_TEMPLATE.md", "voice_source_provenance.yaml", "voice_rvc_base.yaml", "voice_rvc_base_metadata.json", "RVC_VOICE_BASE_STATUS.md", "rvc_voice_base_status.json", "READINESS_REPORT.md", "readiness_report.json", "SHA256SUMS.txt")
if ($hasPreflightReport) {
  $probedPaths += @("preflight_report.md", "preflight_report.json")
}
foreach ($file in $expectedFiles | Where-Object { $_.Path -in $probedPaths }) {
  $path = if ($file.Path -eq "index.html") { "/" } else { $file.Path }
  $probe = Invoke-UrlProbe -TargetUrl (Join-Url $Url $path) -TimeoutSeconds $TimeoutSeconds -ProbeRetries $ProbeRetries -ProbeDelaySeconds $ProbeDelaySeconds
  Assert-HttpOk -Probe $probe -ExpectedType $file.Type -Path $path
  $probes += [pscustomobject]$probe
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $shareRootPath "share_verification_report.json"
}
$reportPaths = Write-VerificationReport -ReportBasePath $ReportPath -Version $Version -Url $Url -RequiredPublicUrl ([bool]$RequirePublicUrl) -Probes $probes -ShareRootPath $shareRootPath -ShareStatus $status

Write-Host "Share release verified:"
Write-Host $Url
Write-Host "Report:"
Write-Host $reportPaths.JsonPath
$probes | ConvertTo-Json -Depth 4
