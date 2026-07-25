param(
  [string]$SearxngUrl = "http://127.0.0.1:8080",
  [string[]]$AllowedEngines = @("duckduckgo", "wikipedia", "brave"),
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$expectedUrl = "http://127.0.0.1:8080"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ResearchAcceptance = Join-Path $RepoRoot "bridge\research_acceptance.py"
$report = [ordered]@{
  schema = "stackchan.local-research-gate.v1"
  status = "not-ready"
  searxng_url = $expectedUrl
  listener_count = 0
  loopback_only = $false
  json_response = $false
  allowlist_applied = $false
  observed_engine_count = 0
  search_result_count = 0
  broker_search_result_count = 0
  broker_fetch_ok = $false
  broker_audit_records = 0
  error = ""
  remediation = ""
  pass = $false
}

function Complete-ResearchGate {
  param([int]$ExitCode)

  $payload = $report | ConvertTo-Json -Depth 6
  if (-not $Json) {
    if ($ExitCode -eq 0) {
      Write-Host "Local research ready at $expectedUrl"
    } else {
      Write-Warning "Local research is not ready: $($report.error)"
      if ($report.remediation) { Write-Warning $report.remediation }
    }
  }
  Write-Output $payload
  exit $ExitCode
}

if ($SearxngUrl.TrimEnd("/") -ne $expectedUrl) {
  $report.error = "searxng_url_not_loopback_contract"
  $report.remediation = "Use the release endpoint $expectedUrl."
  Complete-ResearchGate 1
}

$listeners = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
$report.listener_count = $listeners.Count
if ($listeners.Count -eq 0) {
  $report.error = "searxng_listener_missing"
  $report.remediation = "Install Docker or Podman, then run tools\start_local_research.ps1."
  Complete-ResearchGate 1
}

$nonLoopbackListeners = @(
  $listeners | Where-Object { $_.LocalAddress -notin @("127.0.0.1", "::1") }
)
$report.loopback_only = $nonLoopbackListeners.Count -eq 0
if (-not $report.loopback_only) {
  $report.error = "searxng_listener_not_loopback_only"
  $report.remediation = "Stop the exposed service and use tools\searxng\compose.yaml."
  Complete-ResearchGate 1
}

$searchBody = @{
  q = "Stackchan open source robot"
  format = "json"
  language = "en"
}
try {
  $response = Invoke-RestMethod -Uri "$expectedUrl/search" -Method Post -Body $searchBody -TimeoutSec 10
} catch {
  $report.error = "searxng_json_request_failed"
  $report.remediation = "Inspect the SearXNG container logs and confirm JSON output is enabled."
  Complete-ResearchGate 1
}

$rows = @($response.results)
$report.json_response = $null -ne $response.results
$report.search_result_count = $rows.Count
$observedEngines = @(
  $rows | ForEach-Object { @($_.engines) + @($_.engine) } | Where-Object { $_ } | Sort-Object -Unique
)
$report.observed_engine_count = $observedEngines.Count
$report.allowlist_applied = $observedEngines.Count -gt 0 -and @(
  $observedEngines | Where-Object { $_ -notin $AllowedEngines }
).Count -eq 0
if (-not $report.json_response -or $rows.Count -eq 0) {
  $report.error = "searxng_search_results_missing"
  $report.remediation = "Inspect enabled engines and upstream connectivity."
  Complete-ResearchGate 1
}
if (-not $report.allowlist_applied) {
  $report.error = "searxng_engine_allowlist_failed"
  $report.remediation = "Use the checked-in settings.yml engine allowlist."
  Complete-ResearchGate 1
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCommand -or -not (Test-Path -LiteralPath $ResearchAcceptance -PathType Leaf)) {
  $report.error = "research_acceptance_runtime_missing"
  $report.remediation = "Use the complete release package and prepare its Python runtime."
  Complete-ResearchGate 1
}

$pythonExecutable = if ($pythonCommand.Path) { $pythonCommand.Path } else { $pythonCommand.Source }
$pythonOutput = & $pythonExecutable $ResearchAcceptance --searxng-url $expectedUrl 2>&1
$pythonExit = $LASTEXITCODE
if ($pythonExit -ne 0) {
  $report.error = "broker_search_fetch_acceptance_failed"
  $report.remediation = "Verify public HTTPS search results and outbound HTTPS page fetching."
  Complete-ResearchGate 1
}
try {
  $broker = ($pythonOutput -join "`n") | ConvertFrom-Json
} catch {
  $report.error = "broker_acceptance_output_invalid"
  $report.remediation = "Run bridge\research_acceptance.py directly and inspect its output."
  Complete-ResearchGate 1
}

$report.broker_search_result_count = [int]$broker.search_result_count
$report.broker_fetch_ok = [bool]$broker.fetch_ok
$report.broker_audit_records = [int]$broker.broker_audit_records
$report.pass = $report.loopback_only -and $report.allowlist_applied -and [bool]$broker.pass
if (-not $report.pass) {
  $report.error = "local_research_acceptance_failed"
  $report.remediation = "Inspect the structured gate fields and SearXNG container logs."
  Complete-ResearchGate 1
}

$report.status = "local-research-ready"
Complete-ResearchGate 0
