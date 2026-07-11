$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-supervised-flash-" + [guid]::NewGuid().ToString("N"))
$readinessPath = Join-Path $tempRoot "FULL_ONLINE_FLASH_READINESS.json"
$outDir = Join-Path $tempRoot "out"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Write-Json $readinessPath ([ordered]@{
      schema = "stackchan.full-online-flash-readiness.v1"
      status = "full-online-flash-ready"
      readyToFlash = $true
      generatedAt = ([datetimeoffset]::Now.ToString("o"))
      failed = 0
      pending = 1
      checks = @()
    })

  $refusalOutput = & "tools\flash_full_online_when_ready.ps1" `
    -ReadinessJsonPath $readinessPath `
    -OutDir $outDir `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected missing safety confirmations to fail."
  }
  $refusal = $refusalOutput | ConvertFrom-Json
  if ($refusal.status -ne "full-online-supervised-flash-not-run") {
    throw "Expected not-run refusal, got $($refusal.status)."
  }
  foreach ($id in @("operator-present", "body-clear", "servo-risk-confirmed")) {
    $check = @($refusal.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $check -or $check.status -ne "fail") {
      throw "Expected $id to fail without explicit confirmation."
    }
  }

  $dryRunOutput = & "tools\flash_full_online_when_ready.ps1" `
    -ReadinessJsonPath $readinessPath `
    -OutDir $outDir `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if (-not $?) {
    throw "Expected dry-run supervised flash to pass: $dryRunOutput"
  }
  $dryRun = $dryRunOutput | ConvertFrom-Json
  if ($dryRun.status -ne "full-online-supervised-flash-dry-run-ready" -or $dryRun.dryRun -ne $true) {
    throw "Expected dry-run-ready status, got status=$($dryRun.status) dryRun=$($dryRun.dryRun)."
  }
  $freshCheck = @($dryRun.steps | Where-Object { $_.id -eq "readiness-fresh" })[0]
  if ($null -eq $freshCheck -or $freshCheck.status -ne "pass") {
    throw "Expected fresh readiness check to pass."
  }
  $flashCheck = @($dryRun.steps | Where-Object { $_.id -eq "flash-command" })[0]
  if ($null -eq $flashCheck -or $flashCheck.status -ne "pass") {
    throw "Expected dry-run flash command to pass."
  }
  $flashLog = Get-Content -LiteralPath (Join-Path $outDir "flash_full_online.log") -Raw
  if ($flashLog -notmatch "Dry run: platformio run -e stackchan_full_online --target upload") {
    throw "Expected dry-run flash log to contain platformio upload command."
  }

  $badReadinessPath = Join-Path $tempRoot "BAD_FLASH_READINESS.json"
  Write-Json $badReadinessPath ([ordered]@{
      schema = "stackchan.full-online-flash-readiness.v1"
      status = "full-online-flash-not-ready"
      readyToFlash = $false
      generatedAt = ([datetimeoffset]::Now.ToString("o"))
      failed = 1
      pending = 0
      checks = @()
    })
  $badOutput = & "tools\flash_full_online_when_ready.ps1" `
    -ReadinessJsonPath $badReadinessPath `
    -OutDir $outDir `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if ($?) {
    throw "Expected bad readiness to fail."
  }
  $bad = $badOutput | ConvertFrom-Json
  if ($bad.status -ne "full-online-supervised-flash-not-run") {
    throw "Expected not-run for bad readiness, got $($bad.status)."
  }

  $staleReadinessPath = Join-Path $tempRoot "STALE_FLASH_READINESS.json"
  Write-Json $staleReadinessPath ([ordered]@{
      schema = "stackchan.full-online-flash-readiness.v1"
      status = "full-online-flash-ready"
      readyToFlash = $true
      generatedAt = ([datetimeoffset]::Now.AddHours(-3).ToString("o"))
      failed = 0
      pending = 1
      checks = @()
    })
  $staleOutput = & "tools\flash_full_online_when_ready.ps1" `
    -ReadinessJsonPath $staleReadinessPath `
    -OutDir $outDir `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -MaxReadinessAgeMinutes 60 `
    -Json
  if ($?) {
    throw "Expected stale readiness to fail."
  }
  $stale = $staleOutput | ConvertFrom-Json
  if ($stale.status -ne "full-online-supervised-flash-not-run") {
    throw "Expected not-run for stale readiness, got $($stale.status)."
  }
  $staleFreshCheck = @($stale.steps | Where-Object { $_.id -eq "readiness-fresh" })[0]
  if ($null -eq $staleFreshCheck -or $staleFreshCheck.status -ne "fail") {
    throw "Expected stale readiness freshness check to fail."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online supervised flash contract tests passed."
