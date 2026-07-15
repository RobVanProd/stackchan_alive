param(
  [string]$SearxngUrl = "http://127.0.0.1:8080",
  [string[]]$AllowedEngines = @("duckduckgo", "wikipedia", "brave")
)

$ErrorActionPreference = "Stop"
$expectedUrl = "http://127.0.0.1:8080"
if ($SearxngUrl.TrimEnd("/") -ne $expectedUrl) {
  throw "SearXNG acceptance is restricted to $expectedUrl"
}

$listeners = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
$loopbackOnly = $listeners.Count -gt 0 -and @(
  $listeners | Where-Object { $_.LocalAddress -notin @("127.0.0.1", "::1") }
).Count -eq 0

$searchBody = @{
  q = "Stackchan open source robot"
  format = "json"
  language = "en"
}
$response = Invoke-RestMethod -Uri "$expectedUrl/search" -Method Post -Body $searchBody -TimeoutSec 10
$rows = @($response.results)
$observedEngines = @(
  $rows | ForEach-Object { @($_.engines) + @($_.engine) } | Where-Object { $_ } | Sort-Object -Unique
)
$allowlistApplied = $observedEngines.Count -gt 0 -and @(
  $observedEngines | Where-Object { $_ -notin $AllowedEngines }
).Count -eq 0

$python = & python bridge\research_acceptance.py --searxng-url $expectedUrl 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Broker search/fetch acceptance failed: $python"
}
$broker = $python | ConvertFrom-Json
$report = [ordered]@{
  schema = "stackchan.local-research-gate.v1"
  searxng_url = $expectedUrl
  listener_count = $listeners.Count
  loopback_only = $loopbackOnly
  json_response = $null -ne $response.results
  allowlist_applied = $allowlistApplied
  observed_engine_count = $observedEngines.Count
  search_result_count = $rows.Count
  broker_search_result_count = $broker.search_result_count
  broker_fetch_ok = $broker.fetch_ok
  broker_audit_records = $broker.broker_audit_records
  pass = $loopbackOnly -and $allowlistApplied -and $broker.pass
}
$report | ConvertTo-Json -Depth 5
if (-not $report.pass) { exit 1 }
