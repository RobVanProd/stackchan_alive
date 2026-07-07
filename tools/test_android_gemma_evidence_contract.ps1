param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_gemma_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$sourceCommit = "abcdef1234567890abcdef1234567890abcdef12"

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-android-gemma-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Value | ConvertTo-Json -Depth 16 | Set-Content -Path $Path -Encoding UTF8
}

function Write-Logcat {
  param([string]$Path)

  @"
07-06 12:00:00.000 StackchanBrain: mobile_brain_litert_turn profile=gemma4-e2b-litert-lm elapsed_ms=1200
07-06 12:00:01.000 StackchanBridge: response_end seq=42
"@ | Set-Content -Path $Path -Encoding UTF8
}

function Write-Review {
  param(
    [string]$Path,
    [string]$ReviewSourceCommit = $sourceCommit
  )

  @"
# Android Gemma-4-E2B Real-Device Review

- Reviewer: Contract Test
- Review date: 2026-07-06
- Support decision: pass
- Android device: Pixel contract
- Android version: 15
- App version: 1.0.0
- Source commit: $ReviewSourceCommit
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Logcat path: android_gemma_logcat.txt
- Benchmark path: model_benchmark.json
- Model local path: /storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm
- Model bytes observed: 2588147712
- Model SHA-256 observed: 181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c
- LiteRT turn decision: pass
- Benchmark decision: pass
- Eject/reload decision: pass
- Robot audio/TTS decision: pass
"@ | Set-Content -Path $Path -Encoding UTF8
}

function New-ReadyExport {
  return [ordered]@{
    schema = "stackchan.android.diagnostics-export.v1"
    generated_at = "2026-07-06T00:00:00Z"
    app = [ordered]@{
      package_name = "dev.stackchan.companion"
      version_name = "1.0.0"
      version_code = 1
    }
    endpoint = [ordered]@{
      endpoint_id = "phone-contract"
      endpoint_name = "Rob's Phone"
      endpoint_kind = "android"
      app_version = "1.0.0"
      priority = 80
      supports_binary_audio = $true
      capabilities = @("settings", "diagnostics", "brain_owner")
    }
    bridge = [ordered]@{
      service_status = "Foreground"
      primary_bridge_url = "ws://192.168.1.42:8765/bridge"
      robot_socket_connected = $true
      robot_state = "heartbeat"
      last_message_type = "app_text_turn"
      text_turns_submitted = 1
      last_text_turn_present = $true
    }
    pairing = [ordered]@{
      pairing_code_present = $true
      pairing_qr_scheme = "stackchan://pair"
      wifi_provisioning_command_template = 'wifi set ssid "<network-name>" pass "<network-password>" url "ws://192.168.1.42:8765/bridge"'
      password_redacted = $true
    }
    robot = [ordered]@{
      socket_connected = $true
      connected = $true
      device_id = "stackchan-bench-01"
      device_name = "Stackchan Bench"
      display_name = "Stackchan Bench"
      firmware_version = "bench-v1"
      fingerprint = "bench-v1"
      saved_on_phone = $true
    }
    model = [ordered]@{
      model_id = "Gemma-4-E2B"
      runtime = "LiteRT-LM"
      expected_file = "gemma-4-E2B-it.litertlm"
      expected_bytes = 2588147712
      expected_sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
      source_url = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
      local_path = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm"
      bytes = 2588147712
      downloaded = $true
      loaded = $true
      checksum_verified = $true
      download_in_progress = $false
      download_id_present = $false
      runner_status = "litert_adapter_selected"
      success_intent = "mobile_brain_litert_turn"
      failure_intent = "mobile_brain_litert_error"
      requires_real_device_inference_evidence = $true
    }
    saved_robots = @()
    trusted_endpoints = @()
    privacy = [ordered]@{
      local_first = $true
      raw_audio_retention = "none"
      transcript_export = "last text turn redacted to presence only"
    }
  }
}

function New-ReadyBenchmark {
  return [ordered]@{
    schema = "stackchan.model-benchmark.v1"
    generated_at = "2026-07-06T00:00:00Z"
    profiles_requested = @("gemma4-e2b-litert-lm")
    cases_requested = @("greeting", "noise", "picked_up", "memory", "safety")
    persona = "spark"
    require_runner = $true
    summary = [ordered]@{
      status = "pass"
      total_cases = 5
      ok_cases = 5
      configured_runner_cases = 5
      error_cases = 0
      validation_failure_cases = 0
      pass_rate = 1.0
      profiles = [ordered]@{
        "gemma4-e2b-litert-lm" = [ordered]@{
          status = "pass"
          cases = 5
          ok = 5
          configured_runner_cases = 5
          pass_rate = 1.0
          median_elapsed_ms = 1200.0
          median_tokens_per_sec = 8.5
        }
      }
      candidate_gate = [ordered]@{
        status = "pass"
        thresholds = [ordered]@{
          min_pass_rate = 0.95
          max_median_ms = 2500.0
          min_tokens_per_sec = 5.0
        }
        ready_profiles = @("gemma4-e2b-litert-lm")
        recommended_profile = "gemma4-e2b-litert-lm"
        profiles = [ordered]@{
          "gemma4-e2b-litert-lm" = [ordered]@{
            status = "candidate-pass"
            ready = $true
            blockers = @()
          }
        }
      }
    }
    results = @()
  }
}

function Write-ReadyEvidence {
  param(
    [string]$EvidenceRoot,
    [string]$ReviewSourceCommit = $sourceCommit
  )

  Write-JsonFile -Path (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_EXPORT.json") -Value (New-ReadyExport)
  Write-Logcat -Path (Join-Path $EvidenceRoot "android_gemma_logcat.txt")
  Write-JsonFile -Path (Join-Path $EvidenceRoot "model_benchmark.json") -Value (New-ReadyBenchmark)
  Write-Review -Path (Join-Path $EvidenceRoot "ANDROID_GEMMA_REVIEW.md") -ReviewSourceCommit $ReviewSourceCommit
}

function Invoke-GemmaCheck {
  param([string]$EvidenceRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-DiagnosticsExportPath",
    (Join-Path $EvidenceRoot "ANDROID_DIAGNOSTICS_EXPORT.json"),
    "-LogcatPath",
    (Join-Path $EvidenceRoot "android_gemma_logcat.txt"),
    "-BenchmarkPath",
    (Join-Path $EvidenceRoot "model_benchmark.json"),
    "-ReviewPath",
    (Join-Path $EvidenceRoot "ANDROID_GEMMA_REVIEW.md"),
    "-SourceCommit",
    $sourceCommit,
    "-RequireReady",
    "-Json"
  )

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

try {
  Set-Location $repoRoot

  $readyRoot = New-TempEvidenceRoot
  Write-ReadyEvidence -EvidenceRoot $readyRoot
  $readyResult = Invoke-GemmaCheck -EvidenceRoot $readyRoot
  if ([int]$readyResult.exitCode -ne 0 -or $readyResult.report.status -ne "android-gemma-real-device-ready") {
    throw "Expected complete Android Gemma evidence to be ready. Output: $($readyResult.text)"
  }
  if ($readyResult.report.sourceCommit -ne $sourceCommit -or $readyResult.report.expectedSourceCommit -ne $sourceCommit) {
    throw "Expected Android Gemma evidence report to emit matching sourceCommit and expectedSourceCommit."
  }
  if ($readyResult.report.benchmarkProfile -ne "gemma4-e2b-litert-lm" -or $readyResult.report.benchmarkRecommendedProfile -ne "gemma4-e2b-litert-lm") {
    throw "Expected Android Gemma evidence report to emit benchmark profile identity."
  }
  foreach ($id in @("benchmark-json", "benchmark-schema", "benchmark-require-runner", "benchmark-summary-status", "benchmark-candidate-gate", "benchmark-recommended-profile", "benchmark-profile-ready", "benchmark-speed", "gemma-review", "gemma-review-source-commit-match")) {
    Assert-CheckStatus -Report $readyResult.report -Id $id -Status "pass"
  }
  Write-Host "[ok] complete Android Gemma benchmark evidence is accepted"

  $missingBenchmarkRoot = New-TempEvidenceRoot
  Write-ReadyEvidence -EvidenceRoot $missingBenchmarkRoot
  Remove-Item -LiteralPath (Join-Path $missingBenchmarkRoot "model_benchmark.json") -Force
  $missingBenchmarkResult = Invoke-GemmaCheck -EvidenceRoot $missingBenchmarkRoot
  if ([int]$missingBenchmarkResult.exitCode -eq 0) {
    throw "Expected missing Android Gemma benchmark evidence to fail RequireReady."
  }
  Assert-CheckStatus -Report $missingBenchmarkResult.report -Id "benchmark-json" -Status "pending"
  Write-Host "[ok] missing Android Gemma benchmark evidence is rejected"

  $dryRunRoot = New-TempEvidenceRoot
  Write-ReadyEvidence -EvidenceRoot $dryRunRoot
  $dryRunBenchmark = New-ReadyBenchmark
  $dryRunBenchmark.require_runner = $false
  $dryRunBenchmark.summary.status = "dry-run-no-runner-configured"
  $dryRunBenchmark.summary.configured_runner_cases = 0
  $dryRunBenchmark.summary.profiles."gemma4-e2b-litert-lm".status = "dry-run"
  $dryRunBenchmark.summary.profiles."gemma4-e2b-litert-lm".configured_runner_cases = 0
  $dryRunBenchmark.summary.candidate_gate.status = "no-candidate"
  $dryRunBenchmark.summary.candidate_gate.ready_profiles = @()
  $dryRunBenchmark.summary.candidate_gate.recommended_profile = ""
  $dryRunBenchmark.summary.candidate_gate.profiles."gemma4-e2b-litert-lm".status = "candidate-dry-run"
  $dryRunBenchmark.summary.candidate_gate.profiles."gemma4-e2b-litert-lm".ready = $false
  $dryRunBenchmark.summary.candidate_gate.profiles."gemma4-e2b-litert-lm".blockers = @("not_all_cases_used_configured_runner")
  Write-JsonFile -Path (Join-Path $dryRunRoot "model_benchmark.json") -Value $dryRunBenchmark
  $dryRunResult = Invoke-GemmaCheck -EvidenceRoot $dryRunRoot
  if ([int]$dryRunResult.exitCode -eq 0) {
    throw "Expected dry-run Android Gemma benchmark evidence to fail."
  }
  Assert-CheckStatus -Report $dryRunResult.report -Id "benchmark-require-runner" -Status "fail"
  Assert-CheckStatus -Report $dryRunResult.report -Id "benchmark-profile-ready" -Status "fail"
  Write-Host "[ok] dry-run Android Gemma benchmark evidence is rejected"

  $slowBenchmarkRoot = New-TempEvidenceRoot
  Write-ReadyEvidence -EvidenceRoot $slowBenchmarkRoot
  $slowBenchmark = New-ReadyBenchmark
  $slowBenchmark.summary.profiles."gemma4-e2b-litert-lm".median_elapsed_ms = 2600.0
  Write-JsonFile -Path (Join-Path $slowBenchmarkRoot "model_benchmark.json") -Value $slowBenchmark
  $slowBenchmarkResult = Invoke-GemmaCheck -EvidenceRoot $slowBenchmarkRoot
  if ([int]$slowBenchmarkResult.exitCode -eq 0) {
    throw "Expected slow Android Gemma benchmark evidence to fail."
  }
  Assert-CheckStatus -Report $slowBenchmarkResult.report -Id "benchmark-speed" -Status "fail"
  Write-Host "[ok] slow Android Gemma benchmark evidence is rejected"

  $staleReviewRoot = New-TempEvidenceRoot
  Write-ReadyEvidence -EvidenceRoot $staleReviewRoot -ReviewSourceCommit ("b" * 40)
  $staleReviewResult = Invoke-GemmaCheck -EvidenceRoot $staleReviewRoot
  if ([int]$staleReviewResult.exitCode -eq 0) {
    throw "Expected stale Android Gemma review source commit to fail."
  }
  Assert-CheckStatus -Report $staleReviewResult.report -Id "gemma-review-source-commit-match" -Status "fail"
  Write-Host "[ok] stale Android Gemma review source commit is rejected"

  Write-Host "Android Gemma evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
