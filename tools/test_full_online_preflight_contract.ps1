$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$scriptPath = "tools\run_full_online_preflight.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "Missing $scriptPath"
}

$text = Get-Content -LiteralPath $scriptPath -Raw
foreach ($pattern in @(
    "stackchan.full-online-preflight.v1",
    "pio run -e stackchan_full_online",
    "flash_device.cmd",
    "-DryRun",
    "-ConfirmServoRisk",
    "check_pc_brain_runtime.cmd",
    "run_pc_brain_stt_preflight.cmd",
    "check_first_pc_brain_deploy.cmd",
    "-RequireFullOnline",
    "full-online-preflight-ready-to-flash",
    "tools\flash_device.cmd -Environment stackchan_full_online"
  )) {
  if ($text -notmatch [regex]::Escape($pattern)) {
    throw "run_full_online_preflight.ps1 missing required pattern: $pattern"
  }
}

$flashInvocation = [regex]::Match($text, "&\s+`"tools\\flash_device\.cmd`"[\s\S]{0,260}")
if (-not $flashInvocation.Success) {
  throw "run_full_online_preflight.ps1 missing executable flash_device.cmd invocation."
}
foreach ($pattern in @("-DryRun", "-ConfirmServoRisk", "stackchan_full_online")) {
  if ($flashInvocation.Value -notmatch [regex]::Escape($pattern)) {
    throw "flash_device.cmd invocation missing required safety pattern: $pattern"
  }
}

Write-Host "Full-online preflight contract tests passed."
