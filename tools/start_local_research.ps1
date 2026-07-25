param(
  [string]$SearxngUrl = "http://127.0.0.1:8080",
  [ValidateSet("auto", "docker", "podman")]
  [string]$Runtime = "auto",
  [int]$ReadyTimeoutSeconds = 120,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Checker = Join-Path $PSScriptRoot "check_local_research.ps1"
$ComposeFile = Join-Path $PSScriptRoot "searxng\compose.yaml"
$PinnedImage = "docker.io/searxng/searxng:2026.7.24-4f64d9501"
$expectedUrl = "http://127.0.0.1:8080"
$result = [ordered]@{
  schema = "stackchan.local-research-start.v1"
  status = "not-ready"
  searxng_url = $expectedUrl
  container_runtime = $null
  compose_file = "tools/searxng/compose.yaml"
  image = $PinnedImage
  already_running = $false
  started = $false
  gate = $null
  error = ""
  remediation = ""
}

function Write-StartResult {
  param([int]$ExitCode)

  $payload = $result | ConvertTo-Json -Depth 8
  if (-not $Json) {
    if ($ExitCode -eq 0) {
      Write-Host "Local research ready at $expectedUrl"
    } else {
      Write-Warning "Local research could not start: $($result.error)"
      if ($result.remediation) { Write-Warning $result.remediation }
    }
  }
  Write-Output $payload
  exit $ExitCode
}

function Invoke-ResearchGate {
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Checker `
    -SearxngUrl $expectedUrl -Json 2>$null
  $exitCode = $LASTEXITCODE
  $gate = $null
  try { $gate = ($output -join "`n") | ConvertFrom-Json } catch {}
  return [pscustomobject]@{
    exitCode = $exitCode
    gate = $gate
  }
}

if ($SearxngUrl.TrimEnd("/") -ne $expectedUrl) {
  $result.error = "searxng_url_not_loopback_contract"
  $result.remediation = "Use the release endpoint $expectedUrl."
  Write-StartResult 1
}
if ($ReadyTimeoutSeconds -lt 15 -or $ReadyTimeoutSeconds -gt 600) {
  $result.error = "ready_timeout_out_of_range"
  $result.remediation = "Use a timeout between 15 and 600 seconds."
  Write-StartResult 1
}
if (-not (Test-Path -LiteralPath $Checker -PathType Leaf) -or
    -not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
  $result.error = "local_research_release_files_missing"
  $result.remediation = "Use a complete Stackchan release package."
  Write-StartResult 1
}

$initial = Invoke-ResearchGate
if ($initial.exitCode -eq 0 -and $initial.gate -and [bool]$initial.gate.pass) {
  $result.status = "local-research-ready"
  $result.already_running = $true
  $result.gate = $initial.gate
  Write-StartResult 0
}

$candidates = if ($Runtime -eq "auto") { @("docker", "podman") } else { @($Runtime) }
$selectedRuntime = ""
$runtimeInstalled = $false
foreach ($candidate in $candidates) {
  $command = Get-Command $candidate -ErrorAction SilentlyContinue
  if (-not $command) { continue }
  $runtimeInstalled = $true
  $runtimeExecutable = if ($command.Path) { $command.Path } else { $command.Source }
  $null = & $runtimeExecutable info 2>$null
  if ($LASTEXITCODE -ne 0) { continue }
  $null = & $runtimeExecutable compose version 2>$null
  if ($LASTEXITCODE -ne 0) { continue }
  $selectedRuntime = $runtimeExecutable
  $result.container_runtime = $candidate
  break
}

if (-not $selectedRuntime) {
  $result.error = if ($runtimeInstalled) {
    "container_runtime_not_ready"
  } else {
    "container_runtime_missing"
  }
  $result.remediation = if ($runtimeInstalled) {
    "Start Docker Desktop or the Podman machine, then run this command again."
  } else {
    "Install Docker Desktop or Podman; Stackchan does not elevate or install system software."
  }
  Write-StartResult 1
}

$previousSecret = $env:SEARXNG_SECRET
$generatedSecret = [string]::IsNullOrWhiteSpace($previousSecret)
if ($generatedSecret) {
  $bytes = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  $env:SEARXNG_SECRET = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

try {
  $composeOutput = & $selectedRuntime compose -f $ComposeFile up -d 2>&1
  $composeExit = $LASTEXITCODE
} finally {
  if ($generatedSecret) {
    Remove-Item Env:\SEARXNG_SECRET -ErrorAction SilentlyContinue
  } else {
    $env:SEARXNG_SECRET = $previousSecret
  }
}
if ($composeExit -ne 0) {
  $result.error = "searxng_compose_start_failed"
  $result.remediation = "Inspect the container runtime and tools\searxng\compose.yaml."
  Write-StartResult 1
}
$result.started = $true

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
do {
  Start-Sleep -Seconds 2
  $gateResult = Invoke-ResearchGate
  if ($gateResult.exitCode -eq 0 -and $gateResult.gate -and [bool]$gateResult.gate.pass) {
    $result.status = "local-research-ready"
    $result.gate = $gateResult.gate
    Write-StartResult 0
  }
} while ((Get-Date) -lt $deadline)

$result.gate = $gateResult.gate
$result.error = "local_research_readiness_timeout"
$result.remediation = "Inspect container logs and the structured research gate."
Write-StartResult 1
