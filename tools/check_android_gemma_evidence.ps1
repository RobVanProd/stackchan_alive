param(
  [string]$Root = "",
  [string]$DiagnosticsExportPath = "output/android-gemma/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$LogcatPath = "output/android-gemma/latest/android_gemma_logcat.txt",
  [string]$BenchmarkPath = "output/android-gemma/latest/model_benchmark.json",
  [string]$ReviewPath = "output/android-gemma/latest/ANDROID_GEMMA_REVIEW.md",
  [switch]$WriteTemplate,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

Set-Location $Root

if (-not [System.IO.Path]::IsPathRooted($DiagnosticsExportPath)) {
  $DiagnosticsExportPath = Join-Path $Root $DiagnosticsExportPath
}
if (-not [System.IO.Path]::IsPathRooted($LogcatPath)) {
  $LogcatPath = Join-Path $Root $LogcatPath
}
if (-not [System.IO.Path]::IsPathRooted($BenchmarkPath)) {
  $BenchmarkPath = Join-Path $Root $BenchmarkPath
}
if (-not [System.IO.Path]::IsPathRooted($ReviewPath)) {
  $ReviewPath = Join-Path $Root $ReviewPath
}

$ExpectedModelId = "Gemma-4-E2B"
$ExpectedRuntime = "LiteRT-LM"
$ExpectedModelFile = "gemma-4-E2B-it.litertlm"
$ExpectedModelBytes = 2588147712
$ExpectedModelSha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
$ExpectedSourceUrl = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
$ExpectedBenchmarkProfile = "gemma4-e2b-litert-lm"
$ExpectedBenchmarkMaxMedianMs = 2500.0
$ExpectedBenchmarkMinTokensPerSec = 5.0
$ExpectedBenchmarkMinPassRate = 0.95
$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Convert-ToRelativePath {
  param([string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $rootFull = [System.IO.Path]::GetFullPath([string]$Root)
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($rootFull.Length).TrimStart("\", "/") -replace "\\", "/"
  }
  return $full -replace "\\", "/"
}

function Get-Field {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Test-HasField {
  param(
    [object]$Object,
    [string]$Name
  )

  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Test-TrueField {
  param(
    [object]$Object,
    [string]$Name
  )

  return (Test-HasField $Object $Name) -and ((Get-Field $Object $Name) -eq $true)
}

function Convert-ToInt64OrNull {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    return [int64]$Value
  } catch {
    return $null
  }
}

function Convert-ToDoubleOrNull {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    return [double]$Value
  } catch {
    return $null
  }
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-fA-F0-9]{40}$"
}

function Test-ArrayContainsString {
  param(
    [object]$Value,
    [string]$Expected
  )

  if ($null -eq $Value) {
    return $false
  }
  return @($Value | ForEach-Object { [string]$_ }) -contains $Expected
}

function Get-ReviewSourceCommit {
  param([string]$Text)

  $match = [regex]::Match($Text, "(?im)^-\s*Source commit:\s*([a-fA-F0-9]{40})\s*$")
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Add-ExactFieldCheck {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Actual,
    [object]$Expected,
    [string]$Evidence
  )

  if ($Actual -eq $Expected) {
    Add-Check $Id $Name "pass" $Evidence "Value matches expected release contract."
  } else {
    Add-Check $Id $Name "fail" $Evidence "Expected '$Expected' but found '$Actual'."
  }
}

function Add-RequiredFieldCheck {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Object,
    [string[]]$Fields,
    [string]$Evidence
  )

  $missing = @()
  foreach ($field in $Fields) {
    if (-not (Test-HasField $Object $field)) {
      $missing += $field
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "fail" $Evidence ("Missing required fields: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" $Evidence "Required fields are present."
  }
}

function Write-GemmaReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Gemma-4-E2B Real-Device Review

Complete this after running the final Android build on a real phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Logcat path: android_gemma_logcat.txt
- Benchmark path: model_benchmark.json
- Model local path:
- Model bytes observed:
- Model SHA-256 observed:
- LiteRT turn decision: pending
- Benchmark decision: pending
- Eject/reload decision: pending
- Robot audio/TTS decision: pending

Required review:

- Download Manager fetched `gemma-4-E2B-it.litertlm` from the pinned LiteRT Community URL.
- Cached model size is 2588147712 bytes.
- Cached model SHA-256 is `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`.
- Load succeeds only after the size and SHA-256 check pass.
- Eject clears staged state without deleting the cached model, then Load can stage it again.
- Diagnostics export shows `runner_status=litert_adapter_selected`.
- A real text turn returns `mobile_brain_litert_turn` in logcat and does not emit `mobile_brain_litert_error`.
- `model_benchmark.json` is a non-dry-run `stackchan.model-benchmark.v1` report for `gemma4-e2b-litert-lm` with `summary.candidate_gate.status=pass`.
- Robot response audio/TTS was heard or captured in the hardware evidence packet.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-GemmaReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $DiagnosticsExportPath
$logcatEvidence = Convert-ToRelativePath $LogcatPath
$benchmarkEvidence = Convert-ToRelativePath $BenchmarkPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath
$sourceCommit = ""
$benchmarkRecommendedProfile = ""
$benchmarkMedianMs = $null
$benchmarkMedianTokensPerSec = $null

if (-not (Test-Path -LiteralPath $DiagnosticsExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json after downloading, loading, ejecting, reloading, and using Gemma on a real phone."
} else {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pass" $exportEvidence "Diagnostics export JSON exists."

  try {
    $diagnostics = Get-Content -LiteralPath $DiagnosticsExportPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "diagnostics-export-json-parse" "Android diagnostics export parses" "fail" $exportEvidence $_.Exception.Message
    $diagnostics = $null
  }

  if ($null -ne $diagnostics) {
    Add-ExactFieldCheck "schema" "Diagnostics export schema" (Get-Field $diagnostics "schema") "stackchan.android.diagnostics-export.v1" $exportEvidence
    $model = Get-Field $diagnostics "model"
    Add-RequiredFieldCheck "model-fields" "Gemma LiteRT model fields" $model @("model_id", "runtime", "expected_file", "expected_bytes", "expected_sha256", "source_url", "local_path", "bytes", "downloaded", "loaded", "checksum_verified", "runner_status", "success_intent", "failure_intent", "requires_real_device_inference_evidence") $exportEvidence
    Add-ExactFieldCheck "model-id" "Gemma model id" (Get-Field $model "model_id") $ExpectedModelId $exportEvidence
    Add-ExactFieldCheck "model-runtime" "Gemma runtime" (Get-Field $model "runtime") $ExpectedRuntime $exportEvidence
    Add-ExactFieldCheck "model-file" "Gemma expected file" (Get-Field $model "expected_file") $ExpectedModelFile $exportEvidence
    Add-ExactFieldCheck "model-bytes" "Gemma expected bytes" (Convert-ToInt64OrNull (Get-Field $model "expected_bytes")) $ExpectedModelBytes $exportEvidence
    Add-ExactFieldCheck "model-sha256" "Gemma expected SHA-256" (Get-Field $model "expected_sha256") $ExpectedModelSha256 $exportEvidence
    Add-ExactFieldCheck "model-source-url" "Gemma source URL" (Get-Field $model "source_url") $ExpectedSourceUrl $exportEvidence
    Add-ExactFieldCheck "model-success-intent" "Gemma success intent" (Get-Field $model "success_intent") "mobile_brain_litert_turn" $exportEvidence
    Add-ExactFieldCheck "model-failure-intent" "Gemma failure intent" (Get-Field $model "failure_intent") "mobile_brain_litert_error" $exportEvidence

    $localPath = [string](Get-Field $model "local_path")
    if (-not [string]::IsNullOrWhiteSpace($localPath) -and $localPath.EndsWith($ExpectedModelFile, [System.StringComparison]::OrdinalIgnoreCase)) {
      Add-Check "model-local-path" "Gemma local path" "pass" $exportEvidence "Local path points at the pinned LiteRT-LM artifact."
    } else {
      Add-Check "model-local-path" "Gemma local path" "pending" $exportEvidence "Load the pinned Gemma asset on the Android device before exporting diagnostics."
    }

    $actualModelBytes = Convert-ToInt64OrNull (Get-Field $model "bytes")
    if ((Test-TrueField $model "downloaded") -and (Test-TrueField $model "loaded") -and (Test-TrueField $model "checksum_verified") -and ($actualModelBytes -eq $ExpectedModelBytes)) {
      Add-Check "model-loaded-state" "Gemma downloaded, verified, and loaded" "pass" $exportEvidence "Export shows downloaded=true, loaded=true, checksum_verified=true, and expected byte count."
    } else {
      Add-Check "model-loaded-state" "Gemma downloaded, verified, and loaded" "pending" $exportEvidence "Download the model, pass SHA-256 verification, and tap Load before exporting diagnostics."
    }

    if ((Get-Field $model "runner_status") -eq "litert_adapter_selected" -and (Test-TrueField $model "requires_real_device_inference_evidence")) {
      Add-Check "litert-adapter-selected" "LiteRT adapter selected" "pass" $exportEvidence "Diagnostics require and select real-device LiteRT inference evidence."
    } else {
      Add-Check "litert-adapter-selected" "LiteRT adapter selected" "pending" $exportEvidence "Loaded Gemma diagnostics must report runner_status=litert_adapter_selected and requires_real_device_inference_evidence=true."
    }
  }
}

if (-not (Test-Path -LiteralPath $LogcatPath -PathType Leaf)) {
  Add-Check "litert-logcat" "LiteRT text-turn logcat evidence" "pending" $logcatEvidence "Capture logcat for a real text turn after Gemma is loaded."
} else {
  $logText = Get-Content -LiteralPath $LogcatPath -Raw
  $hasSuccess = $logText.Contains("mobile_brain_litert_turn")
  $hasFailure = $logText.Contains("mobile_brain_litert_error")
  if ($hasSuccess -and -not $hasFailure) {
    Add-Check "litert-logcat" "LiteRT text-turn logcat evidence" "pass" $logcatEvidence "Logcat includes mobile_brain_litert_turn and no mobile_brain_litert_error."
  } elseif ($hasFailure) {
    Add-Check "litert-logcat" "LiteRT text-turn logcat evidence" "fail" $logcatEvidence "Logcat includes mobile_brain_litert_error; fix or recapture a passing run before v1 sign-off."
  } else {
    Add-Check "litert-logcat" "LiteRT text-turn logcat evidence" "pending" $logcatEvidence "Logcat does not include mobile_brain_litert_turn yet."
  }
}

if (-not (Test-Path -LiteralPath $BenchmarkPath -PathType Leaf)) {
  Add-Check "benchmark-json" "Android LiteRT-LM model benchmark JSON" "pending" $benchmarkEvidence "Run bridge/model_benchmark.py for gemma4-e2b-litert-lm with a configured real runner and attach model_benchmark.json."
} else {
  Add-Check "benchmark-json" "Android LiteRT-LM model benchmark JSON" "pass" $benchmarkEvidence "Benchmark JSON exists."

  try {
    $benchmark = Get-Content -LiteralPath $BenchmarkPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "benchmark-json-parse" "Android LiteRT-LM model benchmark parses" "fail" $benchmarkEvidence $_.Exception.Message
    $benchmark = $null
  }

  if ($null -ne $benchmark) {
    Add-ExactFieldCheck "benchmark-schema" "Model benchmark schema" (Get-Field $benchmark "schema") "stackchan.model-benchmark.v1" $benchmarkEvidence
    Add-ExactFieldCheck "benchmark-require-runner" "Model benchmark uses configured runner" (Get-Field $benchmark "require_runner") $true $benchmarkEvidence

    $summary = Get-Field $benchmark "summary"
    $candidateGate = Get-Field $summary "candidate_gate"
    $profiles = Get-Field $summary "profiles"
    $profileSummary = Get-Field $profiles $ExpectedBenchmarkProfile
    $candidateProfiles = Get-Field $candidateGate "profiles"
    $profileDecision = Get-Field $candidateProfiles $ExpectedBenchmarkProfile
    $benchmarkRecommendedProfile = [string](Get-Field $candidateGate "recommended_profile")
    $benchmarkMedianMs = Convert-ToDoubleOrNull (Get-Field $profileSummary "median_elapsed_ms")
    $benchmarkMedianTokensPerSec = Convert-ToDoubleOrNull (Get-Field $profileSummary "median_tokens_per_sec")

    $cases = Convert-ToInt64OrNull (Get-Field $profileSummary "cases")
    $configuredRunnerCases = Convert-ToInt64OrNull (Get-Field $profileSummary "configured_runner_cases")
    $passRate = Convert-ToDoubleOrNull (Get-Field $profileSummary "pass_rate")
    $readyProfilesOk = Test-ArrayContainsString (Get-Field $candidateGate "ready_profiles") $ExpectedBenchmarkProfile
    $candidateReady = (Get-Field $profileDecision "ready") -eq $true
    $candidateBlockers = @(Get-Field $profileDecision "blockers")
    $profileReady = (Get-Field $profileSummary "status") -eq "pass" -and
      $null -ne $cases -and $cases -ge 5 -and
      $null -ne $configuredRunnerCases -and $configuredRunnerCases -eq $cases -and
      $null -ne $passRate -and $passRate -ge $ExpectedBenchmarkMinPassRate -and
      $readyProfilesOk -and
      $candidateReady -and
      $candidateBlockers.Count -eq 0

    Add-ExactFieldCheck "benchmark-summary-status" "Model benchmark summary status" (Get-Field $summary "status") "pass" $benchmarkEvidence
    Add-ExactFieldCheck "benchmark-candidate-gate" "Model benchmark candidate gate" (Get-Field $candidateGate "status") "pass" $benchmarkEvidence
    Add-ExactFieldCheck "benchmark-recommended-profile" "Model benchmark recommended mobile profile" $benchmarkRecommendedProfile $ExpectedBenchmarkProfile $benchmarkEvidence
    if ($profileReady) {
      Add-Check "benchmark-profile-ready" "Gemma LiteRT-LM benchmark profile ready" "pass" $benchmarkEvidence "gemma4-e2b-litert-lm passed the full configured-runner candidate gate."
    } else {
      Add-Check "benchmark-profile-ready" "Gemma LiteRT-LM benchmark profile ready" "fail" $benchmarkEvidence "Benchmark must include gemma4-e2b-litert-lm with all cases using a configured runner, pass_rate >= 0.95, candidate ready=true, and no blockers."
    }

    if ($null -ne $benchmarkMedianMs -and $benchmarkMedianMs -le $ExpectedBenchmarkMaxMedianMs -and $null -ne $benchmarkMedianTokensPerSec -and $benchmarkMedianTokensPerSec -ge $ExpectedBenchmarkMinTokensPerSec) {
      Add-Check "benchmark-speed" "Gemma LiteRT-LM benchmark speed budget" "pass" $benchmarkEvidence "Median latency and tokens/sec meet the v1 mobile brain thresholds."
    } else {
      Add-Check "benchmark-speed" "Gemma LiteRT-LM benchmark speed budget" "fail" $benchmarkEvidence "Expected median_elapsed_ms <= $ExpectedBenchmarkMaxMedianMs and median_tokens_per_sec >= $ExpectedBenchmarkMinTokensPerSec for gemma4-e2b-litert-lm."
    }
  }
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "gemma-review" "Android Gemma human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the review after the real-device Gemma run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $sourceCommit = Get-ReviewSourceCommit $reviewText
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $sourceCommitOk = Test-Commit $sourceCommit
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $turnOk = $reviewText -match "(?im)^-\s*LiteRT turn decision:\s*pass\s*$"
  $benchmarkOk = $reviewText -match "(?im)^-\s*Benchmark decision:\s*pass\s*$"
  $ejectOk = $reviewText -match "(?im)^-\s*Eject/reload decision:\s*pass\s*$"
  $audioOk = $reviewText -match "(?im)^-\s*Robot audio/TTS decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $sourceCommitOk -and $supportOk -and $turnOk -and $benchmarkOk -and $ejectOk -and $audioOk) {
    Add-Check "gemma-review" "Android Gemma human review packet" "pass" $reviewEvidence "Reviewer, date, support decision, LiteRT turn, benchmark, eject/reload, and robot audio/TTS decisions are pass."
  } else {
    Add-Check "gemma-review" "Android Gemma human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Source commit: <40-character SHA>, Support decision: pass, LiteRT turn decision: pass, Benchmark decision: pass, Eject/reload decision: pass, and Robot audio/TTS decision: pass."
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-gemma-evidence" } else { "android-gemma-real-device-ready" }

$report = [ordered]@{
  schema = "stackchan.android-gemma-evidence.v1"
  status = $status
  sourceCommit = $sourceCommit
  root = [string]$Root
  diagnosticsExportPath = Convert-ToRelativePath $DiagnosticsExportPath
  logcatPath = Convert-ToRelativePath $LogcatPath
  benchmarkPath = Convert-ToRelativePath $BenchmarkPath
  reviewPath = Convert-ToRelativePath $ReviewPath
  expectedModelFile = $ExpectedModelFile
  expectedModelBytes = $ExpectedModelBytes
  expectedModelSha256 = $ExpectedModelSha256
  benchmarkProfile = $ExpectedBenchmarkProfile
  benchmarkRecommendedProfile = $benchmarkRecommendedProfile
  benchmarkMedianMs = $benchmarkMedianMs
  benchmarkMedianTokensPerSec = $benchmarkMedianTokensPerSec
  passCount = $passCount
  failCount = $failCount
  pendingCount = $pendingCount
  requireReady = [bool]$RequireReady
  checks = $checks
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android Gemma evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
