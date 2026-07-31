param(
  [int]$Port = 5061,
  [int]$Threads = 12,
  [string]$ExecutablePath = "",
  [string]$ModelPath = "",
  [string]$InitialPrompt = "Stackchan,Gemma,Rhea,SearXNG,servo,telemetry,companion,bridge,camera,persona",
  [ValidateSet("auto", "cpu", "vulkan")]
  [string]$Backend = "auto",
  [int]$VulkanDevice = 0,
  [string]$WarmupWavPath = "docs\media\voice\stackchan_spark_greeting.wav",
  [int]$WarmupTimeoutSeconds = 30,
  [string]$OutputDir = "output\pc-brain\whisper-server",
  [int]$ReadyTimeoutSeconds = 30,
  [switch]$SkipWarmup,
  [switch]$StopExisting,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }
if ($Threads -lt 1 -or $Threads -gt 32) { throw "Threads must be between 1 and 32." }
if ($VulkanDevice -lt 0 -or $VulkanDevice -gt 15) { throw "VulkanDevice must be between 0 and 15." }
if ($WarmupTimeoutSeconds -lt 1 -or $WarmupTimeoutSeconds -gt 120) {
  throw "WarmupTimeoutSeconds must be between 1 and 120."
}
$NormalizedPrompt = (($InitialPrompt -replace "[\s,]+", ",").Trim(","))
if ($NormalizedPrompt.Length -gt 256) { throw "InitialPrompt cannot exceed 256 characters." }

function Get-WhisperListener {
  return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-WhisperHealth {
  try {
    return Invoke-RestMethod -Uri "http://127.0.0.1`:$Port/health" -TimeoutSec 3
  } catch {
    return $null
  }
}

function Get-WhisperBackendEvidence {
  param(
    [string]$LogPath,
    [string]$ExpectedBackend
  )
  $logText = if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
  } else {
    ""
  }
  $vulkanMatch = [regex]::Match(
    [string]$logText,
    "using\s+(Vulkan(?<device>\d+))\s+backend",
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  $actualBackend = if ($vulkanMatch.Success) { "vulkan" } else { "cpu" }
  $verified = $ExpectedBackend -eq "auto" -or $ExpectedBackend -eq $actualBackend
  return [pscustomobject]@{
    requested = $ExpectedBackend
    actual = $actualBackend
    verified = $verified
    device = if ($vulkanMatch.Success) { $vulkanMatch.Groups["device"].Value } else { $null }
  }
}

function Invoke-WhisperWarmup {
  param(
    [string]$AudioPath,
    [int]$TimeoutSeconds
  )
  Add-Type -AssemblyName System.Net.Http
  $client = [Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $multipart = [Net.Http.MultipartFormDataContent]::new()
  $stream = $null
  $audioContent = $null
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  try {
    $stream = [IO.File]::OpenRead($AudioPath)
    $audioContent = [Net.Http.StreamContent]::new($stream)
    $audioContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("audio/wav")
    $multipart.Add($audioContent, "file", [IO.Path]::GetFileName($AudioPath))
    $multipart.Add([Net.Http.StringContent]::new("json"), "response_format")
    $multipart.Add([Net.Http.StringContent]::new("0"), "temperature")
    $response = $client.PostAsync(
      "http://127.0.0.1`:$Port/inference",
      $multipart
    ).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "warmup inference returned HTTP $([int]$response.StatusCode)"
    }
    $payload = try { $body | ConvertFrom-Json } catch { $null }
    if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.text)) {
      throw "warmup inference returned no transcription"
    }
    return [pscustomobject]@{
      verified = $true
      elapsedMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
      transcriptChars = ([string]$payload.text).Length
    }
  } finally {
    $stopwatch.Stop()
    if ($audioContent) { $audioContent.Dispose() }
    if ($stream) { $stream.Dispose() }
    $multipart.Dispose()
    $client.Dispose()
  }
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
  $DiscoveredRoot = Join-Path $RepoRoot "output\local-tools"
  $DiscoveredServer = if (Test-Path -LiteralPath $DiscoveredRoot) {
    Get-ChildItem -LiteralPath $DiscoveredRoot -Filter "whisper-server.exe" `
      -Recurse -ErrorAction SilentlyContinue |
      Sort-Object FullName |
      Select-Object -First 1
  } else {
    $null
  }
  $Candidates = @(
    $env:STACKCHAN_WHISPER_SERVER_EXE,
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-vulkan\Release\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-vulkan\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\Release\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\whisper-server.exe"),
    $(if ($DiscoveredServer) { $DiscoveredServer.FullName })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  $ExecutablePath = $Candidates | Select-Object -First 1
}
if (-not $ExecutablePath -or -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
  throw "whisper-server.exe not found. Run tools\setup_whisper_cpp.cmd or pass -ExecutablePath."
}

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
  $Candidates = @(
    $env:STACKCHAN_WHISPER_MODEL,
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-vulkan\models\ggml-small.en.bin"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp-blas\models\ggml-small.en.bin"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\models\ggml-small.en.bin"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\models\ggml-base.en.bin")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  $ModelPath = $Candidates | Select-Object -First 1
}
if (-not $ModelPath -or -not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
  throw "whisper.cpp model not found. Run tools\setup_whisper_cpp.cmd or pass -ModelPath."
}

$ExecutablePath = (Resolve-Path $ExecutablePath).Path
$ModelPath = (Resolve-Path $ModelPath).Path
$ResolvedWarmupWavPath = $null
if (-not $SkipWarmup) {
  $WarmupCandidate = if ([IO.Path]::IsPathRooted($WarmupWavPath)) {
    $WarmupWavPath
  } else {
    Join-Path $RepoRoot $WarmupWavPath
  }
  if (-not (Test-Path -LiteralPath $WarmupCandidate -PathType Leaf)) {
    throw "Whisper warmup WAV not found: $WarmupCandidate"
  }
  $ResolvedWarmupWavPath = (Resolve-Path $WarmupCandidate).Path
}

$Existing = Get-WhisperListener
if ($Existing) {
  $ExistingProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($Existing.OwningProcess)" -ErrorAction SilentlyContinue
  if (-not $ExistingProcess -or [string]$ExistingProcess.CommandLine -notmatch "whisper-server(\.exe)?") {
    throw "Refusing to use or stop non-whisper listener PID $($Existing.OwningProcess) on port $Port."
  }
  if ($StopExisting) {
    Stop-Process -Id $Existing.OwningProcess -Force
    $Deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $Deadline -and (Get-WhisperListener)) {
      Start-Sleep -Milliseconds 200
    }
    if (Get-WhisperListener) { throw "Whisper server port $Port did not become free." }
  } else {
    $ExistingCommand = [string]$ExistingProcess.CommandLine
    $ExistingExecutable = [string]$ExistingProcess.ExecutablePath
    $ExecutableMatches = [string]::Equals(
      $ExistingExecutable,
      $ExecutablePath,
      [StringComparison]::OrdinalIgnoreCase
    )
    $ModelMatches = $ExistingCommand.IndexOf(
      $ModelPath,
      [StringComparison]::OrdinalIgnoreCase
    ) -ge 0
    $ThreadsMatch = $ExistingCommand -match "(?:^|\s)-(?:t|threads)\s+$Threads(?:\s|$)"
    $PromptMatches = [string]::IsNullOrWhiteSpace($NormalizedPrompt) -or
      $ExistingCommand.IndexOf(
        $NormalizedPrompt,
        [StringComparison]::OrdinalIgnoreCase
      ) -ge 0
    if (-not ($ExecutableMatches -and $ModelMatches -and $ThreadsMatch -and $PromptMatches)) {
      throw "Existing whisper.cpp server does not match the requested executable, model, threads, and prompt. Use -StopExisting."
    }
    $ExistingHealth = Get-WhisperHealth
    if (-not $ExistingHealth -or [string]$ExistingHealth.status -ne "ok") {
      throw "Existing whisper.cpp server on port $Port is not healthy."
    }
    $ExistingBackend = Get-WhisperBackendEvidence `
      -LogPath (Join-Path $OutputDir "whisper-server.stderr.log") `
      -ExpectedBackend $Backend
    if (-not [bool]$ExistingBackend.verified) {
      throw "Existing whisper.cpp server did not prove the requested '$Backend' backend. Use -StopExisting."
    }
    $ExistingWarmup = if ($SkipWarmup) {
      [pscustomobject]@{ verified = $false; elapsedMs = $null; transcriptChars = 0 }
    } else {
      Invoke-WhisperWarmup -AudioPath $ResolvedWarmupWavPath -TimeoutSeconds $WarmupTimeoutSeconds
    }
    $Reused = [ordered]@{
      schema = "stackchan.whisper-server-start.v1"
      status = "ready"
      reused = $true
      configVerified = $true
      pid = [int]$Existing.OwningProcess
      url = "http://127.0.0.1`:$Port"
      executable = $ExecutablePath
      executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
      threads = $Threads
      model = Split-Path -Leaf $ModelPath
      modelSha256 = (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
      initialPrompt = $NormalizedPrompt
      backend = [string]$ExistingBackend.actual
      backendDevice = $ExistingBackend.device
      backendVerified = [bool]$ExistingBackend.verified
      warmupVerified = [bool]$ExistingWarmup.verified
      warmupElapsedMs = $ExistingWarmup.elapsedMs
      warmupWavSha256 = if ($SkipWarmup) {
        $null
      } else {
        (Get-FileHash -LiteralPath $ResolvedWarmupWavPath -Algorithm SHA256).Hash.ToLowerInvariant()
      }
      health = $ExistingHealth
    }
    if ($Json) { $Reused | ConvertTo-Json -Depth 5 } else { Write-Host "Whisper server already ready: PID $($Reused.pid)" }
    exit 0
  }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputPath = (Resolve-Path $OutputDir).Path
$StdoutPath = Join-Path $OutputPath "whisper-server.stdout.log"
$StderrPath = Join-Path $OutputPath "whisper-server.stderr.log"

$ServerArguments = @(
  "-m", $ModelPath,
  "--host", "127.0.0.1",
  "--port", "$Port",
  "-t", "$Threads",
  "-nt"
)
if (-not [string]::IsNullOrWhiteSpace($NormalizedPrompt)) {
  $ServerArguments += @("--prompt", $NormalizedPrompt)
}
if ($Backend -eq "vulkan") {
  $ServerArguments += @("-dev", "$VulkanDevice")
} elseif ($Backend -eq "cpu") {
  $ServerArguments += "-ng"
}

$Process = Start-Process -FilePath $ExecutablePath -ArgumentList $ServerArguments `
  -WorkingDirectory $RepoRoot -RedirectStandardOutput $StdoutPath `
  -RedirectStandardError $StderrPath -WindowStyle Hidden -PassThru

$Health = $null
$ReadyDeadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while ((Get-Date) -lt $ReadyDeadline) {
  if ($Process.HasExited) {
    $Detail = if (Test-Path -LiteralPath $StderrPath) {
      (Get-Content -LiteralPath $StderrPath -Tail 20) -join " "
    } else {
      "no stderr"
    }
    throw "whisper.cpp server exited before ready: $Detail"
  }
  $Health = Get-WhisperHealth
  if ($Health -and [string]$Health.status -eq "ok") { break }
  Start-Sleep -Milliseconds 250
}
if (-not $Health -or [string]$Health.status -ne "ok") {
  Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  throw "whisper.cpp server did not become ready within $ReadyTimeoutSeconds seconds."
}

$BackendEvidence = Get-WhisperBackendEvidence -LogPath $StderrPath -ExpectedBackend $Backend
if (-not [bool]$BackendEvidence.verified) {
  Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  throw "Whisper server started with '$($BackendEvidence.actual)' instead of requested '$Backend' backend."
}
$Warmup = try {
  if ($SkipWarmup) {
    [pscustomobject]@{ verified = $false; elapsedMs = $null; transcriptChars = 0 }
  } else {
    Invoke-WhisperWarmup -AudioPath $ResolvedWarmupWavPath -TimeoutSeconds $WarmupTimeoutSeconds
  }
} catch {
  Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  throw "Whisper server warmup failed: $($_.Exception.Message)"
}

$Process.Id | Set-Content -LiteralPath (Join-Path $OutputPath "whisper-server.pid") -Encoding ASCII
$Result = [ordered]@{
  schema = "stackchan.whisper-server-start.v1"
  status = "ready"
  reused = $false
  configVerified = $true
  pid = [int]$Process.Id
  url = "http://127.0.0.1`:$Port"
  executable = $ExecutablePath
  executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
  threads = $Threads
  model = Split-Path -Leaf $ModelPath
  modelSha256 = (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
  initialPrompt = $NormalizedPrompt
  backend = [string]$BackendEvidence.actual
  backendDevice = $BackendEvidence.device
  backendVerified = [bool]$BackendEvidence.verified
  warmupVerified = [bool]$Warmup.verified
  warmupElapsedMs = $Warmup.elapsedMs
  warmupWavSha256 = if ($SkipWarmup) {
    $null
  } else {
    (Get-FileHash -LiteralPath $ResolvedWarmupWavPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  health = $Health
}
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Whisper server ready: PID $($Process.Id)" }
