param(
  [string]$PackageZip = "",
  [string]$Version = "",
  [string]$ExpectedCommit = "",
  [string]$ReportDir = "",
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

$script:PreflightStepResults = @()
$script:PreflightReportWritten = $false

function Write-PreflightReport {
  param(
    [ValidateSet("pass", "fail")]
    [string]$Status,
    [string]$ErrorMessage = ""
  )

  if ([string]::IsNullOrWhiteSpace($ReportDir)) {
    $reportVersion = if ([string]::IsNullOrWhiteSpace($Version)) { "commit-$($ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length)))" } else { $Version }
    $ReportDir = Join-Path $repoRoot "output/preflight/$reportVersion"
  }

  New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $report = [ordered]@{
    schema = "stackchan.preflight-report.v1"
    version = $Version
    commit = $ExpectedCommit
    status = $Status
    generatedUtc = $generatedUtc
    packageZip = $PackageZip
    allowDirty = [bool]$AllowDirty
    error = $ErrorMessage
    steps = @($script:PreflightStepResults)
  }

  $report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ReportDir "preflight_report.json") -Encoding UTF8

  $lines = @(
    "# Stackchan Device Preflight Report",
    "",
    "- Version: $Version",
    "- Commit: $ExpectedCommit",
    "- Status: $Status",
    "- Generated UTC: $generatedUtc",
    "- Package ZIP: $PackageZip",
    "- Allow dirty source: $([bool]$AllowDirty)",
    ""
  )

  if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
    $lines += @(
      "## Failure",
      "",
      $ErrorMessage,
      ""
    )
  }

  $lines += @(
    "## Steps",
    ""
  )

  foreach ($step in @($script:PreflightStepResults)) {
    $duration = if ($null -ne $step.durationSeconds) { "$($step.durationSeconds)s" } else { "" }
    $lines += "- $($step.status): $($step.name) $duration".TrimEnd()
  }

  $lines += @(
    "",
    "## Rollout Note",
    "",
    "This preflight proves the no-hardware gates for the named commit and package. Consumer rollout still requires real-device display, servo, soak, speaker-audio evidence, completed production voice-source provenance, and unblocked GitHub Actions."
  )

  $lines | Set-Content -Path (Join-Path $ReportDir "preflight_report.md") -Encoding UTF8
  $script:PreflightReportWritten = $true
}

function Write-SyntheticSpeakAllIntentsLog {
  param([string]$Path)

  $intentNames = @("boot", "idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety")
  $earcons = @{
    boot = "wake"
    idle = "think"
    attend = "confirm"
    listen = "wake"
    think = "think"
    speak = "confirm"
    react = "confirm"
    happy = "happy"
    concern = "concern"
    sleep = "sleep"
    error = "error"
    safety = "safety"
  }
  $lines = @("[speak-all] > demo off")
  $seq = 10
  foreach ($intentName in $intentNames) {
    $earcon = $earcons[$intentName]
    $lines += "[speak-all] > speak $intentName"
    $lines += "[speak-all] < [control] command=speak_intent cue_intent=$intentName cue_earcon=$earcon at_ms=$($seq * 100)"
    $lines += "[speak-all] < [speech] seq=$seq at_ms=$($seq * 100 + 10) intent=$intentName priority=240 earcon=$earcon earcon_delay_ms=60 text=`"Synthetic packaged prompt for $intentName.`""
    $lines += "[speak-all] < [speech_audio] seq=$seq source=packaged_prompt prompt_id=$intentName prompt_wav=media/voice/stackchan_spark_greeting.wav prompt_sidecar=media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json earcon_delay_ms=60 earcon_samples=1600 earcon_peak=4100 earcon_checksum=ABCD$seq"
    $lines += "[speak-all] < [audio_out] seq=$seq source=packaged_prompt prompt_id=$intentName wav=media/voice/stackchan_spark_greeting.wav sidecar=media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json earcon_samples=1600 duck_on_barge_in=1"
    $seq++
  }
  $lines += "[speak-all] Speak-all-intents demo complete."
  $lines | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Step {
  param(
    [string]$Name,
    [scriptblock]$Command
  )

  Write-Host ""
  Write-Host "==> $Name"
  $startedUtc = (Get-Date).ToUniversalTime()
  try {
    & $Command
    if ($LASTEXITCODE -ne 0) {
      throw "Step failed: $Name"
    }
    $endedUtc = (Get-Date).ToUniversalTime()
    $script:PreflightStepResults += [ordered]@{
      name = $Name
      status = "pass"
      startedUtc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      endedUtc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      durationSeconds = [Math]::Round(($endedUtc - $startedUtc).TotalSeconds, 3)
    }
  } catch {
    $endedUtc = (Get-Date).ToUniversalTime()
    $script:PreflightStepResults += [ordered]@{
      name = $Name
      status = "fail"
      startedUtc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      endedUtc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
      durationSeconds = [Math]::Round(($endedUtc - $startedUtc).TotalSeconds, 3)
      error = $_.Exception.Message
    }
    Write-PreflightReport -Status "fail" -ErrorMessage $_.Exception.Message
    throw
  }
}

function Assert-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command is not available on PATH: $Name"
  }
}

function Assert-CleanSourceTree {
  $dirtyFiles = @(git status --porcelain)
  $generatedMediaDirtyFiles = @(
    $dirtyFiles | Where-Object { $_ -match "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|expression_sheet\.png)$" }
  )
  $sourceDirtyFiles = @(
    $dirtyFiles | Where-Object { $_ -notmatch "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|expression_sheet\.png)$" }
  )

  if ($sourceDirtyFiles.Count -gt 0 -and -not $AllowDirty) {
    $dirtyList = ($sourceDirtyFiles -join [Environment]::NewLine)
    throw "Source worktree is dirty. Commit or discard changes first, or pass -AllowDirty for a diagnostic preflight. Dirty files:$([Environment]::NewLine)$dirtyList"
  }

  if ($generatedMediaDirtyFiles.Count -gt 0) {
    Write-Host "Generated preview media has local changes; package tooling treats these as generated artifacts."
  }
}

function Assert-DependencyPins {
  $platformioLines = Get-Content -LiteralPath "platformio.ini"
  $libDeps = @()
  $insideLibDeps = $false

  foreach ($line in $platformioLines) {
    if ($line -match "^\s*lib_deps\s*=") {
      $insideLibDeps = $true
      continue
    }

    if ($insideLibDeps) {
      if ($line -match "^\s*\S+\s*=" -or $line -match "^\[.+\]") {
        $insideLibDeps = $false
      } elseif ($line -match "^\s+(.+?)\s*$") {
        $dep = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $dep.StartsWith('$')) {
          $libDeps += $dep
        }
      }
    }
  }

  foreach ($dep in $libDeps) {
    if ($dep -notmatch "(@|#)[A-Za-z0-9_.-]+$") {
      throw "PlatformIO dependency is not pinned: $dep"
    }
  }

  foreach ($line in Get-Content -LiteralPath "requirements-preview.txt") {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    if ($trimmed -notmatch "^[A-Za-z0-9_.-]+==[A-Za-z0-9_.-]+$") {
      throw "Preview dependency is not exactly pinned: $trimmed"
    }
  }
}

function Invoke-ToolText {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [ordered]@{
      ExitCode = $exitCode
      Text = ($output | Out-String)
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Assert-TextContains {
  param(
    [string]$Text,
    [string]$Expected
  )

  if ($Text -notmatch [regex]::Escape($Expected)) {
    throw "Expected command output to contain '$Expected'. Output:$([Environment]::NewLine)$Text"
  }
}

function Assert-GitHubActionsStatusExporterGate {
  $fixtureBase = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-actions-status-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $completeFixtureRoot = Join-Path $fixtureBase "complete-required-workflows"
  $preRunnerFixtureRoot = Join-Path $fixtureBase "pre-runner-allocation"
  $missingFixtureRoot = Join-Path $fixtureBase "missing-required-workflow"
  $completeOutputRoot = Join-Path $fixtureBase "out-complete"
  $preRunnerOutputRoot = Join-Path $fixtureBase "out-pre-runner"
  $missingOutputRoot = Join-Path $fixtureBase "out-missing"
  $fixtureCommit = "0123456789abcdef0123456789abcdef01234567"
  $fixtureVersion = "v0.0.0-actions-status-selftest"

  function Write-FixtureJson {
    param(
      [string]$Root,
      [string]$Name,
      [object]$Value
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $Value | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Root $Name) -Encoding UTF8
  }

  function New-FixtureJob {
    param(
      [long]$Id,
      [string]$Name,
      [string]$Conclusion,
      [int]$RunnerId,
      [object[]]$Steps
    )

    return [ordered]@{
      id = $Id
      name = $Name
      status = "completed"
      conclusion = $Conclusion
      labels = @()
      runner_id = $RunnerId
      runner_name = ""
      steps = @($Steps)
      html_url = "https://example.invalid/jobs/$Id"
    }
  }

  try {
    Write-FixtureJson $completeFixtureRoot "run_list.json" @(
      [ordered]@{
        databaseId = 101
        name = "Firmware"
        headSha = $fixtureCommit
        headBranch = "main"
        status = "completed"
        conclusion = "failure"
        createdAt = "2026-07-02T00:00:00Z"
        url = "https://example.invalid/runs/101"
        event = "push"
        displayTitle = "Firmware"
      },
      [ordered]@{
        databaseId = 102
        name = "Release"
        headSha = $fixtureCommit
        headBranch = "main"
        status = "completed"
        conclusion = "failure"
        createdAt = "2026-07-02T00:01:00Z"
        url = "https://example.invalid/runs/102"
        event = "push"
        displayTitle = "Release"
      }
    )
    Write-FixtureJson $completeFixtureRoot "jobs_101.json" ([ordered]@{ jobs = @((New-FixtureJob 201 "build" "failure" 0 @())) })
    Write-FixtureJson $completeFixtureRoot "jobs_102.json" ([ordered]@{ jobs = @((New-FixtureJob 202 "release" "failure" 0 @())) })
    foreach ($jobId in @(201, 202)) {
      Write-FixtureJson $completeFixtureRoot "annotations_$jobId.json" @(
        [ordered]@{
          annotation_level = "failure"
          path = ""
          message = "The job was not started because payments have failed or the spending limit was reached."
        }
      )
    }

    $completeResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "export_github_actions_status.ps1"),
      "-Repo", "RobVanProd/stackchan_alive",
      "-Version", $fixtureVersion,
      "-Commit", $fixtureCommit,
      "-OutputDir", $completeOutputRoot,
      "-FixtureRoot", $completeFixtureRoot,
      "-RequiredWorkflows", "Firmware,Release"
    )
    if ($completeResult.ExitCode -ne 0) {
      throw "Actions status exporter rejected complete required-workflow billing fixture:$([Environment]::NewLine)$($completeResult.Text)"
    }
    $completeStatus = Get-Content -LiteralPath (Join-Path $completeOutputRoot "github_actions_status.json") -Raw | ConvertFrom-Json
    if ($completeStatus.status -ne "external-account-billing-or-spending-limit") {
      throw "Expected billing fixture status external-account-billing-or-spending-limit, got $($completeStatus.status)"
    }
    if (@($completeStatus.missingRequiredWorkflows).Count -ne 0) {
      throw "Billing fixture unexpectedly reported missing required workflows: $(@($completeStatus.missingRequiredWorkflows) -join ', ')"
    }
    if ($completeStatus.externalBlock -ne $true) {
      throw "Billing fixture should mark externalBlock true."
    }
    if ($completeStatus.promotionReady -ne $false) {
      throw "Billing fixture should not be promotion ready."
    }
    if ([string]$completeStatus.nextAction -notmatch "billing") {
      throw "Billing fixture nextAction should mention billing."
    }
    foreach ($workflowName in @("Firmware", "Release")) {
      if (@($completeStatus.requiredWorkflows) -notcontains $workflowName) {
        throw "Billing fixture missing required workflow contract: $workflowName"
      }
    }

    Write-FixtureJson $preRunnerFixtureRoot "run_list.json" @(
      [ordered]@{
        databaseId = 201
        name = "Firmware"
        headSha = $fixtureCommit
        headBranch = "main"
        status = "completed"
        conclusion = "failure"
        createdAt = "2026-07-02T00:03:00Z"
        url = "https://example.invalid/runs/201"
        event = "push"
        displayTitle = "Firmware"
      },
      [ordered]@{
        databaseId = 202
        name = "Release"
        headSha = $fixtureCommit
        headBranch = "main"
        status = "completed"
        conclusion = "failure"
        createdAt = "2026-07-02T00:04:00Z"
        url = "https://example.invalid/runs/202"
        event = "push"
        displayTitle = "Release"
      }
    )
    Write-FixtureJson $preRunnerFixtureRoot "jobs_201.json" ([ordered]@{ jobs = @((New-FixtureJob 501 "native-tests" "failure" 0 @())) })
    Write-FixtureJson $preRunnerFixtureRoot "jobs_202.json" ([ordered]@{ jobs = @((New-FixtureJob 502 "release" "failure" 0 @())) })
    foreach ($jobId in @(501, 502)) {
      Write-FixtureJson $preRunnerFixtureRoot "annotations_$jobId.json" @()
    }

    $preRunnerResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "export_github_actions_status.ps1"),
      "-Repo", "RobVanProd/stackchan_alive",
      "-Version", $fixtureVersion,
      "-Commit", $fixtureCommit,
      "-OutputDir", $preRunnerOutputRoot,
      "-FixtureRoot", $preRunnerFixtureRoot,
      "-RequiredWorkflows", "Firmware,Release"
    )
    if ($preRunnerResult.ExitCode -ne 0) {
      throw "Actions status exporter rejected pre-runner allocation fixture:$([Environment]::NewLine)$($preRunnerResult.Text)"
    }
    $preRunnerStatus = Get-Content -LiteralPath (Join-Path $preRunnerOutputRoot "github_actions_status.json") -Raw | ConvertFrom-Json
    if ($preRunnerStatus.status -ne "external-account-ci-pre-runner-allocation") {
      throw "Expected pre-runner fixture status external-account-ci-pre-runner-allocation, got $($preRunnerStatus.status)"
    }
    if (@($preRunnerStatus.missingRequiredWorkflows).Count -ne 0) {
      throw "Pre-runner fixture unexpectedly reported missing required workflows: $(@($preRunnerStatus.missingRequiredWorkflows) -join ', ')"
    }
    if ($preRunnerStatus.externalBlock -ne $true) {
      throw "Pre-runner fixture should mark externalBlock true."
    }
    if ([string]$preRunnerStatus.nextAction -notmatch "runner") {
      throw "Pre-runner fixture nextAction should mention runner availability."
    }
    $preRunnerMarkdown = Get-Content -LiteralPath (Join-Path $preRunnerOutputRoot "GITHUB_ACTIONS_STATUS.md") -Raw
    Assert-TextContains $preRunnerMarkdown "no runner was assigned"

    Write-FixtureJson $missingFixtureRoot "run_list.json" @(
      [ordered]@{
        databaseId = 301
        name = "Firmware"
        headSha = $fixtureCommit
        headBranch = "main"
        status = "completed"
        conclusion = "success"
        createdAt = "2026-07-02T00:02:00Z"
        url = "https://example.invalid/runs/301"
        event = "push"
        displayTitle = "Firmware"
      }
    )
    Write-FixtureJson $missingFixtureRoot "jobs_301.json" ([ordered]@{ jobs = @((New-FixtureJob 401 "build" "success" 7 @([ordered]@{ name = "Checkout"; conclusion = "success" }))) })
    Write-FixtureJson $missingFixtureRoot "annotations_401.json" @()

    $missingResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "export_github_actions_status.ps1"),
      "-Repo", "RobVanProd/stackchan_alive",
      "-Version", $fixtureVersion,
      "-Commit", $fixtureCommit,
      "-OutputDir", $missingOutputRoot,
      "-FixtureRoot", $missingFixtureRoot,
      "-RequiredWorkflows", "Firmware,Release"
    )
    if ($missingResult.ExitCode -eq 0) {
      throw "Actions status exporter accepted a fixture missing the required Release workflow."
    }
    $missingStatus = Get-Content -LiteralPath (Join-Path $missingOutputRoot "github_actions_status.json") -Raw | ConvertFrom-Json
    if ($missingStatus.status -ne "missing-required-workflow") {
      throw "Expected missing fixture status missing-required-workflow, got $($missingStatus.status)"
    }
    if (@($missingStatus.missingRequiredWorkflows) -notcontains "Release") {
      throw "Missing fixture did not report Release as missing."
    }
    if ($missingStatus.externalBlock -ne $false) {
      throw "Missing fixture should not mark externalBlock true."
    }
    if ([string]$missingStatus.nextCommand -notmatch "git tag") {
      throw "Missing fixture nextCommand should suggest pushing the release tag."
    }
    $missingMarkdown = Get-Content -LiteralPath (Join-Path $missingOutputRoot "GITHUB_ACTIONS_STATUS.md") -Raw
    Assert-TextContains $missingMarkdown "Missing Required Workflows"
    Assert-TextContains $missingMarkdown "Release"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $fixtureBase) {
      Remove-Item -LiteralPath $fixtureBase -Recurse -Force
    }
  }
}

function Assert-CiAccountBlockExceptionDraftGate {
  $fixtureBase = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-ci-exception-draft-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $externalStatusPath = Join-Path $fixtureBase "github_actions_status_external.json"
  $successStatusPath = Join-Path $fixtureBase "github_actions_status_success.json"
  $draftPath = Join-Path $fixtureBase "CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json"
  $fixtureVersion = "v0.0.0-ci-exception-fixture"
  $fixtureCommit = "0123456789abcdef0123456789abcdef01234567"

  try {
    New-Item -ItemType Directory -Force -Path $fixtureBase | Out-Null

    [ordered]@{
      schema = "stackchan.github-actions-status.v1"
      version = $fixtureVersion
      commit = $fixtureCommit
      status = "external-account-ci-pre-runner-allocation"
      interpretation = "Required GitHub Actions jobs failed before runner allocation; no runner was assigned."
      externalBlock = $true
      promotionReady = $false
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $externalStatusPath -Encoding UTF8

    $draftResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "new_ci_account_block_exception.ps1"),
      "-ActionsStatusPath", $externalStatusPath,
      "-OutPath", $draftPath,
      "-Version", $fixtureVersion,
      "-Commit", $fixtureCommit
    )
    if ($draftResult.ExitCode -ne 0) {
      throw "CI exception draft helper rejected external account fixture:$([Environment]::NewLine)$($draftResult.Text)"
    }
    if (-not (Test-Path -LiteralPath $draftPath)) {
      throw "CI exception draft helper did not write CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json"
    }

    $draft = Get-Content -LiteralPath $draftPath -Raw | ConvertFrom-Json
    if ($draft.schema -ne "stackchan.ci-account-block-exception.v1") {
      throw "CI exception draft schema mismatch: $($draft.schema)"
    }
    if ($draft.version -ne $fixtureVersion -or $draft.commit -ne $fixtureCommit) {
      throw "CI exception draft did not pin version and commit."
    }
    if ($draft.githubActionsStatus -ne "external-account-ci-pre-runner-allocation") {
      throw "CI exception draft used wrong Actions status: $($draft.githubActionsStatus)"
    }
    if ($draft.riskAccepted -ne $false) {
      throw "CI exception draft riskAccepted should remain false."
    }
    if ($draft.localReleaseVerificationPassed -ne $false) {
      throw "CI exception draft localReleaseVerificationPassed should remain false."
    }
    if ($draft.strictHardwareEvidencePassed -ne $false) {
      throw "CI exception draft strictHardwareEvidencePassed should remain false."
    }
    if ($draft.productionVoiceSourceReady -ne $false) {
      throw "CI exception draft productionVoiceSourceReady should remain false."
    }
    foreach ($fieldName in @("approvedBy", "approvedUtc", "followUpOwner", "followUpDueUtc")) {
      if ([string]$draft.PSObject.Properties[$fieldName].Value -notmatch "TBD") {
        throw "CI exception draft $fieldName should remain a TBD placeholder."
      }
    }
    if ([string]$draft.sourceActionsStatusPath -ne $externalStatusPath) {
      throw "CI exception draft did not record the source Actions status path."
    }

    [ordered]@{
      schema = "stackchan.github-actions-status.v1"
      version = $fixtureVersion
      commit = $fixtureCommit
      status = "success"
      interpretation = "Required workflows succeeded."
      externalBlock = $false
      promotionReady = $true
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $successStatusPath -Encoding UTF8

    $rejectResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "new_ci_account_block_exception.ps1"),
      "-ActionsStatusPath", $successStatusPath,
      "-OutPath", (Join-Path $fixtureBase "SHOULD_NOT_EXIST.json"),
      "-Version", $fixtureVersion,
      "-Commit", $fixtureCommit
    )
    if ($rejectResult.ExitCode -eq 0) {
      throw "CI exception draft helper accepted a successful Actions status."
    }
    Assert-TextContains $rejectResult.Text "not an external account block"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $fixtureBase) {
      Remove-Item -LiteralPath $fixtureBase -Recurse -Force
    }
  }
}

function Write-LocalShareVerificationFixture {
  param(
    [string]$ShareRoot,
    [string]$ReleaseTag,
    [string]$VerifiedUrl
  )

  New-Item -ItemType Directory -Force -Path $ShareRoot | Out-Null
  [ordered]@{
    schema = "stackchan.share-status.v1"
    version = $ReleaseTag
    status = "local-ready"
    publicUrl = ""
    publicUrlReady = $false
    bindAddress = "127.0.0.1"
    loopbackUrl = $VerifiedUrl
    localUrl = $VerifiedUrl
    lanUrls = @()
  } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ShareRoot "share_status.json") -Encoding UTF8

  [ordered]@{
    schema = "stackchan.share-verification.v1"
    version = $ReleaseTag
    generatedUtc = "2026-07-02T00:00:00Z"
    url = $VerifiedUrl
    requirePublicUrl = $false
    shareRoot = $ShareRoot
    bindAddress = "127.0.0.1"
    loopbackUrl = $VerifiedUrl
    lanUrls = @()
    probeCount = 2
    allHttp200 = $true
    usedCurlResolveFallback = $false
    probes = @(
      [ordered]@{ path = "index.html"; statusLine = "HTTP/1.1 200 OK"; method = "invoke-webrequest" },
      [ordered]@{ path = "OPEN_LOCAL_SHARE.cmd"; statusLine = "HTTP/1.1 200 OK"; method = "invoke-webrequest" }
    )
  } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ShareRoot "share_verification_report.json") -Encoding UTF8

  @(
    "# Share Verification Report",
    "",
    "- Version: $ReleaseTag",
    "- URL: $VerifiedUrl",
    "- Public URL required: False",
    "- Probe count: 2",
    "- All probes HTTP 200: True",
    "",
    "Machine-readable report: ``share_verification_report.json``"
  ) | Set-Content -Path (Join-Path $ShareRoot "share_verification_report.md") -Encoding UTF8
}

function Assert-LocalShareEvidenceGate {
  $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-local-share-evidence-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $shareRoot = Join-Path $fixtureRoot "share"
  $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-local-share-selftest" } else { $Version }
  $verifiedUrl = "http://127.0.0.1:8787/"
  $packetPath = ""

  try {
    Write-LocalShareVerificationFixture -ShareRoot $shareRoot -ReleaseTag $releaseTag -VerifiedUrl $verifiedUrl

    $startResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "start_hardware_evidence.ps1"),
      "-ReleaseTag", $releaseTag,
      "-ShareRoot", $shareRoot,
      "-Port", "COM_TEST",
      "-Operator", "preflight",
      "-DeviceId", "LOCAL-SHARE-SELFTEST"
    )
    if ($startResult.ExitCode -ne 0) {
      throw "Local-share evidence packet generation failed:$([Environment]::NewLine)$($startResult.Text)"
    }

    $hardwareEvidenceRoot = (Resolve-Path (Join-Path $repoRoot "output/hardware-evidence")).Path
    $packetPath = @($startResult.Text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_) -and
        (Resolve-Path -LiteralPath $_).Path.StartsWith($hardwareEvidenceRoot, [System.StringComparison]::OrdinalIgnoreCase)
      } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($packetPath)) {
      throw "Could not find generated local-share evidence packet path in output:$([Environment]::NewLine)$($startResult.Text)"
    }
    $packetPath = (Resolve-Path -LiteralPath $packetPath).Path

    $metadata = Get-Content -LiteralPath (Join-Path $packetPath "metadata.json") -Raw | ConvertFrom-Json
    if ($null -eq $metadata.shareVerification) {
      throw "Generated evidence metadata did not include shareVerification."
    }
    if ([string]$metadata.shareVerification.verifiedUrl -ne $verifiedUrl) {
      throw "Generated evidence metadata verifiedUrl mismatch: $($metadata.shareVerification.verifiedUrl)"
    }
    if ([string]$metadata.shareVerification.publicUrl -ne $verifiedUrl) {
      throw "Generated evidence metadata compatibility publicUrl mismatch: $($metadata.shareVerification.publicUrl)"
    }
    if ([string]$metadata.shareVerification.urlKind -ne "loopback") {
      throw "Generated evidence metadata urlKind mismatch: $($metadata.shareVerification.urlKind)"
    }
    if ([string]$metadata.shareVerification.verifiedUrlFile -ne "share/VERIFIED_URL.txt") {
      throw "Generated evidence metadata missing verifiedUrlFile."
    }
    $requiredRecords = @($metadata.requiredRecords)
    if ($requiredRecords -notcontains "share/VERIFIED_URL.txt") {
      throw "Generated evidence requiredRecords did not include share/VERIFIED_URL.txt."
    }
    if ($requiredRecords -contains "share/PUBLIC_URL.txt") {
      throw "Generated local-only evidence should not require share/PUBLIC_URL.txt."
    }

    $verifiedUrlFile = Join-Path $packetPath "share/VERIFIED_URL.txt"
    if (-not (Test-Path -LiteralPath $verifiedUrlFile)) {
      throw "Generated evidence did not write share/VERIFIED_URL.txt."
    }
    if ((Get-Content -LiteralPath $verifiedUrlFile -Raw).Trim() -ne $verifiedUrl) {
      throw "Generated share/VERIFIED_URL.txt did not contain the verified local URL."
    }
    if (Test-Path -LiteralPath (Join-Path $packetPath "share/PUBLIC_URL.txt")) {
      throw "Generated local-only evidence unexpectedly copied share/PUBLIC_URL.txt."
    }

    $hostedReference = Get-Content -LiteralPath (Join-Path $packetPath "HOSTED_MEDIA_REFERENCE.md") -Raw
    Assert-TextContains $hostedReference "Verified URL: $verifiedUrl"
    Assert-TextContains $hostedReference "URL kind: loopback"
    Assert-TextContains $hostedReference "share/VERIFIED_URL.txt"

    $global:LASTEXITCODE = 0
  } finally {
    if (-not [string]::IsNullOrWhiteSpace($packetPath) -and (Test-Path -LiteralPath $packetPath)) {
      $resolvedPacket = (Resolve-Path -LiteralPath $packetPath).Path
      $hardwareEvidenceRoot = (Resolve-Path (Join-Path $repoRoot "output/hardware-evidence")).Path
      if ($resolvedPacket.StartsWith($hardwareEvidenceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedPacket -Recurse -Force
      }
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
      Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
  }
}

function Assert-RolloutStatusActionsOverrideGate {
  $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-rollout-actions-override-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $packageRoot = Join-Path $fixtureRoot "package"
  $overrideRoot = Join-Path $fixtureRoot "override"
  $outRoot = Join-Path $fixtureRoot "out"
  $fixtureCommit = "abcdef0123456789abcdef0123456789abcdef01"
  $releaseTag = "v0.0.0-rollout-actions-override"
  $overridePath = Join-Path $overrideRoot "github_actions_status.json"

  try {
    New-Item -ItemType Directory -Force -Path $packageRoot, $overrideRoot, $outRoot | Out-Null
    [ordered]@{
      version = $releaseTag
      commit = $fixtureCommit
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot "release_manifest.json") -Encoding UTF8
    [ordered]@{
      schema = "stackchan.readiness-report.v1"
      version = $releaseTag
      commit = $fixtureCommit
      consumerRollout = "blocked-pending-hardware-validation"
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot "readiness_report.json") -Encoding UTF8
    [ordered]@{
      schema = "stackchan.github-actions-status.v1"
      version = $releaseTag
      commit = $fixtureCommit
      status = "missing-required-workflow"
      missingRequiredWorkflows = @("Release")
      nextAction = "PACKAGED STATUS SHOULD NOT BE USED"
      nextCommand = "packaged-command"
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot "github_actions_status.json") -Encoding UTF8
    [ordered]@{
      schema = "stackchan.github-actions-status.v1"
      version = $releaseTag
      commit = $fixtureCommit
      status = "external-account-ci-pre-runner-allocation"
      missingRequiredWorkflows = @()
      nextAction = "Override Actions status was used."
      nextCommand = ".\tools\export_github_actions_status.cmd -Version $releaseTag"
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $overridePath -Encoding UTF8
    [ordered]@{
      schema = "stackchan.voice-source-status.v1"
      status = "production-source-ready"
      blockedGateCount = 0
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot "voice_source_status.json") -Encoding UTF8
    [ordered]@{
      schema = "stackchan.rvc-voice-base-status.v1"
      status = "consumer-approved"
      consumerApproved = $true
      distributionApproved = $true
      blockedGateCount = 0
      failedGateCount = 0
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot "rvc_voice_base_status.json") -Encoding UTF8

    $result = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "export_rollout_status.ps1"),
      "-Version", $releaseTag,
      "-PackageRoot", $packageRoot,
      "-OutDir", $outRoot,
      "-ActionsStatusPath", $overridePath,
      "-ExpectedCommit", $fixtureCommit
    )
    if ($result.ExitCode -ne 2) {
      throw "Rollout status fixture should remain blocked because no hardware evidence was supplied. Exit code: $($result.ExitCode). Output:$([Environment]::NewLine)$($result.Text)"
    }

    $status = Get-Content -LiteralPath (Join-Path $outRoot "ROLLOUT_STATUS.json") -Raw | ConvertFrom-Json
    if ([string]$status.actionsStatusPath -ne $overridePath) {
      throw "Rollout status did not record the Actions override path."
    }
    $requiredWorkflowGate = @($status.gates | Where-Object { $_.gate -eq "github-actions-required-workflows" } | Select-Object -First 1)
    if ($null -eq $requiredWorkflowGate -or [string]$requiredWorkflowGate.status -ne "pass") {
      throw "Rollout status did not use the override Actions missing-workflow list."
    }
    $actionsGate = @($status.gates | Where-Object { $_.gate -eq "github-actions" } | Select-Object -First 1)
    if ($null -eq $actionsGate -or [string]$actionsGate.status -ne "blocked-external") {
      throw "Rollout status did not use the override Actions external-block status."
    }
    if ([string]$actionsGate.evidence -notmatch "external-account-ci-pre-runner-allocation") {
      throw "Rollout status Actions gate did not report the override status."
    }
    if (@($status.blockers | Where-Object { [string]$_ -match "missing required workflow" }).Count -ne 0) {
      throw "Packaged missing-workflow status leaked into rollout status despite ActionsStatusPath override."
    }
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
      Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
  }
}

function Write-SyntheticAcceptanceArtifacts {
  param(
    [string]$EvidenceRoot,
    [string]$ReleaseTag,
    [string]$Commit
  )

  @(
    "# Release Acceptance",
    "",
    "Current decision: test-ready for device arrival.",
    "",
    "Consumer rollout decision: blocked pending hardware validation.",
    "",
    "## Still Required Before Consumer Rollout",
    "- Display-only flash",
    "- Speech-mouth demo evidence",
    "- Servo calibration",
    "- Mixed-mode soak",
    "- Power-cycle recovery",
    "- Target-speaker audio evidence",
    "- Hardware evidence verification"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "RELEASE_ACCEPTANCE.md") -Encoding UTF8

  $acceptance = [ordered]@{
    schema = "stackchan.release-acceptance.v1"
    version = $ReleaseTag
    commit = $Commit
    currentDecision = "test-ready-for-device-arrival"
    consumerRolloutDecision = "blocked-pending-hardware-validation"
    noHardwareAcceptance = @(
      [ordered]@{ requirement = "clean-release-package"; status = "pass" },
      [ordered]@{ requirement = "dependency-provenance-present"; status = "pass" },
      [ordered]@{ requirement = "voice-review-samples-present"; status = "pass" },
      [ordered]@{ requirement = "servo-risk-gated"; status = "pass" }
    )
    hardwareAcceptanceRequired = @(
      [ordered]@{ requirement = "display-only-flash"; status = "pending-hardware" },
      [ordered]@{ requirement = "speech-mouth-demo-evidence"; status = "pending-hardware" },
      [ordered]@{ requirement = "servo-calibration"; status = "pending-hardware" },
      [ordered]@{ requirement = "mixed-mode-soak"; status = "pending-hardware" },
      [ordered]@{ requirement = "power-cycle-recovery"; status = "pending-hardware" },
      [ordered]@{ requirement = "target-speaker-audio-evidence"; status = "pending-hardware" },
      [ordered]@{ requirement = "hardware-evidence-verification"; status = "pending-hardware" }
    )
  }
  $acceptance | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $EvidenceRoot "release_acceptance.json") -Encoding UTF8
}

function Write-SyntheticVoiceLeadArtifacts {
  param([string]$EvidenceRoot)

  $referenceDir = Join-Path $EvidenceRoot "reference_audio"
  New-Item -ItemType Directory -Force -Path $referenceDir | Out-Null

  $sourceWav = Join-Path $repoRoot "docs/media/voice/stackchan_spark_greeting.wav"
  if (-not (Test-Path -LiteralPath $sourceWav)) {
    throw "Synthetic voice fixture missing: $sourceWav"
  }

  $referenceFile = "reference_audio/stackchan_rvc_bright_robot.wav"
  $referencePath = Join-Path $EvidenceRoot $referenceFile
  Copy-Item -LiteralPath $sourceWav -Destination $referencePath -Force
  $referenceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $referencePath).Hash.ToLowerInvariant()

  $lead = [ordered]@{
    title = "RVC Bright Robot"
    file = "stackchan_rvc_bright_robot.wav"
    referenceFile = $referenceFile
    sha256 = $referenceHash
    transcript = "Hello. I am Stackchan, and I am awake."
    pitch = "2"
    index_rate = "0.62"
    rms_mix_rate = "0.72"
    protect = "0.28"
  }

  $manifest = [ordered]@{
    schema = "stackchan.rvc-auditions.selftest.v1"
    generatedBy = "run_device_preflight.ps1"
    note = "Synthetic preflight fixture for hardware-evidence verifier gates."
    leadAudition = $lead
    auditions = @($lead)
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $referenceDir "RVC_AUDITIONS.json") -Encoding UTF8

  @(
    "# RVC Auditions",
    "",
    "Synthetic preflight fixture for verifier coverage. This file is intentionally generated by the no-hardware preflight and is not a production voice-source approval.",
    "",
    "## Lead",
    "",
    "- Title: RVC Bright Robot",
    "- Reference WAV: reference_audio/stackchan_rvc_bright_robot.wav",
    "- SHA256: $referenceHash",
    "- Transcript: Hello. I am Stackchan, and I am awake.",
    "- Tuning: pitch 2, index 0.62, RMS mix 0.72, protect 0.28",
    "",
    "## Notes",
    "",
    "The real arrival-day packet copies the selected RVC lead audition from the release package. This synthetic copy exists so negative preflight fixtures can pass the voice-reference gate before intentionally failing the media or serial-marker gate.",
    "It keeps the verifier strict while allowing targeted self-tests."
  ) | Set-Content -Path (Join-Path $referenceDir "RVC_AUDITIONS.md") -Encoding UTF8

  @(
    "# RVC Lead Audition Reference",
    "",
    "This packet stages the current lead voice for speaker review. This is not production voice-source approval.",
    "",
    "- Lead audition: RVC Bright Robot",
    "- Reference WAV: reference_audio/stackchan_rvc_bright_robot.wav",
    "- SHA256: $referenceHash",
    "- Transcript: Hello. I am Stackchan, and I am awake.",
    "- Tuning: pitch 2, index 0.62, RMS mix 0.72, protect 0.28"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "RVC_LEAD_AUDITION.md") -Encoding UTF8

  return $lead
}

function Write-SyntheticVoiceGateStatus {
  param([string]$EvidenceRoot)

  $voiceSourceStatusValue = "blocked-pending-production-voice-source"
  $voiceSourceBlockedGateCount = 3
  $rvcStatusValue = "local-archive-verified-review-only"

  $voiceSourceStatus = [ordered]@{
    schema = "stackchan.voice-source-status.v1"
    generatedBy = "run_device_preflight.ps1"
    status = $voiceSourceStatusValue
    blockedGateCount = $voiceSourceBlockedGateCount
    note = "Synthetic preflight fixture. This keeps negative hardware-evidence self-tests past the voice-source provenance gate before they intentionally fail the media or serial-marker gate."
    gates = @(
      [ordered]@{ id = "production-source-selected"; status = "blocked"; reason = "synthetic fixture has no production voice source" },
      [ordered]@{ id = "production-source-license"; status = "blocked"; reason = "synthetic fixture has no license or consent evidence" },
      [ordered]@{ id = "rollout-gate-open"; status = "blocked"; reason = "synthetic fixture is never consumer promotion evidence" }
    )
  }
  $voiceSourceStatus | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $EvidenceRoot "voice_source_status.json") -Encoding UTF8

  @(
    "# Voice Source Status",
    "",
    "Generated by synthetic no-hardware preflight fixture.",
    "Status: $voiceSourceStatusValue",
    "Blocked gates: $voiceSourceBlockedGateCount",
    "",
    "This synthetic report is intentionally not a production voice-source approval. It exists so hardware-evidence negative self-tests can verify the media and serial-marker gates after passing the mandatory voice-source provenance shape.",
    "",
    "## Gates",
    "",
    "- [ ] production-source-selected - synthetic fixture has no production voice source.",
    "- [ ] production-source-license - synthetic fixture has no license or consent evidence.",
    "- [ ] rollout-gate-open - synthetic fixture is never consumer promotion evidence.",
    "",
    "Machine-readable status: voice_source_status.json"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "VOICE_SOURCE_STATUS.md") -Encoding UTF8

  $rvcStatus = [ordered]@{
    schema = "stackchan.rvc-voice-base-status.v1"
    generatedBy = "run_device_preflight.ps1"
    status = $rvcStatusValue
    consumerApproved = $false
    distributionApproved = $false
    note = "Synthetic preflight fixture. The RVC candidate is review-only here and does not clear production voice-source, consumer approval, or distribution approval gates."
    source = [ordered]@{
      title = "synthetic-preflight-rvc-placeholder"
      model = "review-only"
      localArchive = "not-required-for-selftest"
      rightsReview = "pending"
    }
  }
  $rvcStatus | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $EvidenceRoot "rvc_voice_base_status.json") -Encoding UTF8

  @(
    "# RVC Voice Base Status",
    "",
    "- Status: $rvcStatusValue",
    "- Consumer approved: False",
    "- Distribution approved: False",
    "",
    "This synthetic RVC base status is review-only. It keeps verifier self-tests aligned with real evidence packets while making clear that no consumer or distribution approval is granted by this fixture.",
    "",
    "The production voice-source gate remains blocked until rights, consent, training-source, commercial-device-use, generated-prompt distribution, and real-device evidence are complete.",
    "",
    "Machine-readable status: rvc_voice_base_status.json"
  ) | Set-Content -Path (Join-Path $EvidenceRoot "RVC_VOICE_BASE_STATUS.md") -Encoding UTF8

  return [ordered]@{
    voiceSourceStatus = $voiceSourceStatusValue
    voiceSourceBlockedGateCount = $voiceSourceBlockedGateCount
    rvcVoiceBaseStatus = $rvcStatusValue
    rvcConsumerApproved = $false
    rvcDistributionApproved = $false
    reports = @(
      "VOICE_SOURCE_STATUS.md",
      "voice_source_status.json",
      "RVC_VOICE_BASE_STATUS.md",
      "rvc_voice_base_status.json"
    )
  }
}

function Write-SyntheticNextSteps {
  param(
    [string]$EvidenceRoot,
    [string]$ReleaseTag,
    [string]$Commit
  )

  @(
    "# Stackchan Evidence Next Steps",
    "",
    "Release: $ReleaseTag",
    "Commit: $Commit",
    "Device: SELFTEST",
    "Port: COM_TEST",
    "Operator: preflight",
    "",
    "Synthetic preflight fixture for verifier coverage.",
    "",
    "## Run Order",
    "",
    "Pairing setup accepts ``pair ticket <stackchan://pair?...>`` or the raw QR payload when Wi-Fi credentials already exist; the ticket must not contain or print a Wi-Fi password.",
    "",
    "1. Run ``RUN_PACKAGE_VERIFY.cmd`` and confirm ``logs/package_verify.log`` ends with ``Release package verified:``.",
    "2. Run ``RUN_DISPLAY_ONLY.cmd`` and confirm the face is visible, flicker-free, and serial logs show display, face, and system telemetry.",
    "3. Run ``RUN_SPEECH_MOUTH_DEMO.cmd`` while display-only firmware is still connected to exercise speech-envelope mouth motion and capture ``logs/speech_mouth_demo_serial.log``.",
    "4. Run ``RUN_SPEAK_ALL_INTENTS.cmd`` while display-only firmware is still connected to exercise every packaged speech intent, earcon, and audio-output handoff, then capture ``logs/speak_all_intents_serial.log``.",
    "5. Add a display photo or short video with ``RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg``.",
    "6. Run ``RUN_SERVO_CALIBRATION.cmd`` only with the body clear; this command includes ``-ConfirmServoRisk`` and may move the hardware.",
    "7. Update ``calibration/calibration.yaml`` with measured limits and classify yaw as ``angle``, ``velocity``, or ``disabled``.",
    "8. Run ``RUN_SOAK_MONITOR.cmd`` for at least 30 minutes and record the result in ``OBSERVATIONS.md``.",
    "9. Run ``RUN_PLAY_LEAD_VOICE.cmd`` as the playback reference, record the target speaker path, then add the recording with ``RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav``.",
    "10. Complete ``AUDIO_REVIEW.md`` with real-device speaker results. Generated source WAVs alone do not count.",
    "11. Run ``RUN_PROGRESS_CHECK.cmd`` and fix every missing field, marker, media file, and unchecked checklist item it reports.",
    "12. Run ``RUN_ROLLOUT_STATUS.cmd`` to write ``ROLLOUT_STATUS.md`` and ``ROLLOUT_STATUS.json`` for handoff review.",
    "13. Run ``RUN_EVIDENCE_VERIFY.cmd`` for the strict hardware evidence gate.",
    "14. Run ``RUN_CONSUMER_PROMOTION_CHECK.cmd`` only after strict evidence verification passes.",
    "",
    "## Gates Still Expected",
    "",
    "- Hardware validation remains pending until this packet has real display, servo, soak, calibration, photo/video, and speaker evidence.",
    "- Production voice-source provenance remains pending until the owned or licensed source record is completed.",
    "- RVC voice-base evidence remains review-only until consumer and distribution approvals are explicitly recorded.",
    "",
    "## Hard Stops",
    "",
    "- Do not run servo calibration unless the body is clear and supervised.",
    "- Do not mark the audio gate complete without a recording captured from the actual target speaker path.",
    "- Do not use ``-AllowExternalAccountCiBlock`` from this synthetic packet. ``CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json`` must be completed only in a real evidence packet after each proof gate passes.",
    "- Do not promote if ``CHECKLIST.md`` still has unchecked gates or ``RUN_PROGRESS_CHECK.cmd`` reports missing evidence."
  ) | Set-Content -Path (Join-Path $EvidenceRoot "NEXT_STEPS.md") -Encoding UTF8
}

function Write-SyntheticBenchStatus {
  param([string]$EvidenceRoot)

  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  [ordered]@{
    schema = "stackchan.bench-status.v1"
    evidenceRoot = $EvidenceRoot
    generatedUtc = $generatedUtc
    status = "synthetic-preflight-fixture"
    nextAction = "Run verifier gate under test."
    nextCommand = "RUN_EVIDENCE_VERIFY.cmd"
    reason = "Synthetic preflight fixture, not real hardware evidence."
    findingCount = 1
    passCount = 0
    findings = @("Synthetic fixture cannot be used as rollout evidence.")
    passes = @()
  } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $EvidenceRoot "BENCH_STATUS.json") -Encoding UTF8

  @(
    "# Stackchan Bench Status",
    "",
    "- Schema: stackchan.bench-status.v1",
    "- Generated UTC: $generatedUtc",
    "- Status: synthetic-preflight-fixture",
    "- Next action: Run verifier gate under test.",
    "- Next command: ``RUN_EVIDENCE_VERIFY.cmd``",
    "- Reason: Synthetic preflight fixture, not real hardware evidence."
  ) | Set-Content -Path (Join-Path $EvidenceRoot "BENCH_STATUS.md") -Encoding UTF8
}

function Assert-FlashHelperSafety {
  $flashScript = Join-Path $PSScriptRoot "flash_device.ps1"

  $blockedServo = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan_servo_calibration",
    "-DryRun"
  )
  if ($blockedServo.ExitCode -eq 0) {
    throw "Servo calibration dry-run succeeded without -ConfirmServoRisk"
  }
  Assert-TextContains $blockedServo.Text "without -ConfirmServoRisk"

  $servoDryRun = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan_servo_calibration",
    "-ConfirmServoRisk",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  if ($servoDryRun.ExitCode -ne 0) {
    throw "Servo calibration dry-run failed unexpectedly:$([Environment]::NewLine)$($servoDryRun.Text)"
  }
  Assert-TextContains $servoDryRun.Text "Dry run: platformio run -e stackchan_servo_calibration --target upload --upload-port COM_TEST"
  Assert-TextContains $servoDryRun.Text "Dry run: platformio device monitor -e stackchan_servo_calibration --baud 115200 --port COM_TEST"

  $displayDryRun = Invoke-ToolText @(
    $flashScript,
    "-Environment", "stackchan",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  if ($displayDryRun.ExitCode -ne 0) {
    throw "Display-only dry-run failed unexpectedly:$([Environment]::NewLine)$($displayDryRun.Text)"
  }
  Assert-TextContains $displayDryRun.Text "Dry run: platformio run -e stackchan --target upload --upload-port COM_TEST"
  Assert-TextContains $displayDryRun.Text "Dry run: platformio device monitor -e stackchan --baud 115200 --port COM_TEST"
}

function Assert-ReleaseFlashHelperSafety {
  param(
    [string]$ZipPath,
    [switch]$AllowDirtyPackage
  )

  $flashScript = Join-Path $PSScriptRoot "flash_release_firmware.ps1"
  $dirtyPackageArg = @()
  if ($AllowDirtyPackage) {
    $dirtyPackageArg += "-AllowDirtyPackage"
  }

  $blockedArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "servo_calibration",
    "-DryRun"
  )
  $blockedServo = Invoke-ToolText ($blockedArgs + $dirtyPackageArg)
  if ($blockedServo.ExitCode -eq 0) {
    throw "Servo calibration package dry-run succeeded without -ConfirmServoRisk"
  }
  Assert-TextContains $blockedServo.Text "without -ConfirmServoRisk"

  $displayArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "display_only",
    "-DryRun",
    "-Monitor",
    "-Port", "COM_TEST"
  )
  $displayDryRun = Invoke-ToolText ($displayArgs + $dirtyPackageArg)
  if ($displayDryRun.ExitCode -ne 0) {
    throw "Display package dry-run failed unexpectedly:$([Environment]::NewLine)$($displayDryRun.Text)"
  }
  Assert-TextContains $displayDryRun.Text "Release package verified:"
  Assert-TextContains $displayDryRun.Text "Dry run:"
  Assert-TextContains $displayDryRun.Text "--chip esp32s3"
  Assert-TextContains $displayDryRun.Text "write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB"
  Assert-TextContains $displayDryRun.Text "Dry run: platformio device monitor --baud 115200 --port COM_TEST"

  $servoArgs = @(
    $flashScript,
    "-PackageZip", $ZipPath,
    "-Firmware", "servo_calibration",
    "-ConfirmServoRisk",
    "-DryRun",
    "-Port", "COM_TEST"
  )
  $servoDryRun = Invoke-ToolText ($servoArgs + $dirtyPackageArg)
  if ($servoDryRun.ExitCode -ne 0) {
    throw "Servo package dry-run failed unexpectedly:$([Environment]::NewLine)$($servoDryRun.Text)"
  }
  Assert-TextContains $servoDryRun.Text "Release package verified:"
  Assert-TextContains $servoDryRun.Text "Dry run:"
  Assert-TextContains $servoDryRun.Text "--chip esp32s3"
}

function Assert-ReleasePublishBranchGuard {
  param(
    [switch]$AllowDirtyPackage
  )

  $publishScript = Join-Path $PSScriptRoot "publish_release.ps1"
  $publishArgs = @(
    $publishScript,
    "-Version", $Version,
    "-Repo", "RobVanProd/stackchan_alive",
    "-CreateTag",
    "-PushCurrentBranch",
    "-PushTag",
    "-DryRun"
  )
  if ($AllowDirtyPackage) {
    $publishArgs += "-AllowDirtyPackage"
  }

  $publishDryRun = Invoke-ToolText $publishArgs
  if ($publishDryRun.ExitCode -ne 0) {
    throw "Publish dry-run failed unexpectedly:$([Environment]::NewLine)$($publishDryRun.Text)"
  }

  Assert-TextContains $publishDryRun.Text "Dry run: git push"
  Assert-TextContains $publishDryRun.Text "would verify"
  Assert-TextContains $publishDryRun.Text "before creating/uploading release assets"
  Assert-TextContains $publishDryRun.Text "Dry run: gh release create"
  Assert-TextContains $publishDryRun.Text "Release dry run passed:"
}

function Assert-HardwareEvidenceMediaGate {
  $evidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-evidence-media-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $logsDir = Join-Path $evidenceRoot "logs"
  $photosDir = Join-Path $evidenceRoot "photos"
  $audioDir = Join-Path $evidenceRoot "audio"
  $calibrationDir = Join-Path $evidenceRoot "calibration"
  $referenceDir = Join-Path $evidenceRoot "reference_audio"

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir, $referenceDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    $voiceLeadAudition = Write-SyntheticVoiceLeadArtifacts -EvidenceRoot $evidenceRoot
    $voiceGateStatus = Write-SyntheticVoiceGateStatus -EvidenceRoot $evidenceRoot
    Write-SyntheticNextSteps -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    Write-SyntheticBenchStatus -EvidenceRoot $evidenceRoot

    $observations = @(
      "# Hardware Test Observations",
      "",
      "## Display-Only Flash",
      "- Start UTC: 2026-07-01T00:00:00Z",
      "- End UTC: 2026-07-01T00:10:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Reset loop observed: no",
      "- Procedural face visible: yes",
      "- Dry-run servo log observed: yes",
      "",
      "## Servo Calibration Flash",
      "- Start UTC: 2026-07-01T00:10:00Z",
      "- End UTC: 2026-07-01T00:20:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Pitch behavior: inside safe range",
      "- Yaw classification: disabled",
      "- Heat or brownout observed: no",
      "- Calibration changes: recorded",
      "",
      "## Soak Test",
      "- Start UTC: 2026-07-01T00:20:00Z",
      "- End UTC: 2026-07-01T00:50:00Z",
      "- Duration: 30 minutes",
      "- Reset, stall, jitter, or heat observed: no",
      "- USB power-cycle recovery: pass"
    )
    $observations | Set-Content -Path (Join-Path $evidenceRoot "OBSERVATIONS.md") -Encoding UTF8

    @(
      "# Stackchan Audio Review",
      "",
      "## Speaker Playback",
      "- Start UTC: 2026-07-01T00:50:00Z",
      "- End UTC: 2026-07-01T00:51:00Z",
      "- Sample played: reference_audio/stackchan_rvc_bright_robot.wav",
      "- Voice variant: RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture for RVC Bright Robot lead audition"
    ) | Set-Content -Path (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Encoding UTF8
    Copy-Item -LiteralPath "docs/media/voice/stackchan_spark_greeting.wav" -Destination (Join-Path $audioDir "speaker.wav")

    @(
      "pitch_min_deg: -15",
      "pitch_max_deg: 15",
      "yaw_mode: disabled",
      "yaw_min_deg: -30",
      "yaw_max_deg: 30"
    ) | Set-Content -Path (Join-Path $calibrationDir "calibration.yaml") -Encoding UTF8

    @(
      "[boot] stackchan_alive mode=display_only serial=v1",
      "[display] M5 display renderer ready",
      "[display] frame_ms_avg=12.40 frame_ms_max=15.80 fps_avg=80.6 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=3 saccade_count=4 blink_open=1.00 breath_y=0.42 gaze_x=0.08 gaze_y=-0.03 gesture_active=0 speech_active=0 speech_env=0.00",
      "[control] command=safe_stop reduced_motion=1 motion_enabled=0 demo_enabled=0 speech_env=0.00 at_ms=2980",
      "[control] command=reduced_motion_on reduced_motion=1 at_ms=3060",
      "[face] reduced_motion=1",
      "[speech] seq=1 at_ms=3020 intent=listen priority=160 earcon=confirm earcon_delay_ms=0 text=`"I am listening with maximum attention.`"",
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
      "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300",
      "synthetic display log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8
    @(
      "Speech envelope sidecar written: speech\lead_voice.speech_envelope.json (276 frames, max env 1.000)",
      "Speech envelope sidecar verified:",
      "speech\lead_voice.speech_envelope.json",
      "[demo] Loaded sidecar speech\lead_voice.speech_envelope.json with 276 streamed frames.",
      "[demo] > mode speak 1.0",
      "[demo] < [control] command=mode_speak mode=speak event=external_command strength=1.00 at_ms=3080",
      "[demo] > speech 0.620 ah 100",
      "[demo] < [control] command=speech_env speech_env=0.62 viseme=ah duration_ms=100 at_ms=3100",
      "[demo] > speech 0.410 ee 100",
      "[demo] < [control] command=speech_env speech_env=0.41 viseme=ee duration_ms=100 at_ms=3120",
      "[demo] > speech clear",
      "[demo] < [control] command=speech_clear speech_env=0.00 viseme=neutral duration_ms=0 at_ms=3140",
      "[demo] Speech mouth demo complete.",
      "synthetic speech-mouth log line for verifier coverage."
    ) | Set-Content -Path (Join-Path $logsDir "speech_mouth_demo_serial.log") -Encoding UTF8
    Write-SyntheticSpeakAllIntentsLog -Path (Join-Path $logsDir "speak_all_intents_serial.log")
    @(
      "[boot] stackchan_alive mode=servo_calibration serial=v1",
      "[display] M5 display renderer ready",
      "[servo] enabling StackchanSERVO hardware output",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=10000",
      "synthetic servo log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "servo_calibration_serial.log") -Encoding UTF8
    @(
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=20000",
      "[display] frame_ms_avg=12.80 frame_ms_max=16.10 fps_avg=78.1 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=12 saccade_count=16 blink_open=1.00 breath_y=-0.18 gaze_x=-0.04 gaze_y=0.02 gesture_active=0 speech_active=0 speech_env=0.00",
      "[speech] seq=4 at_ms=20020 intent=think priority=150 earcon=think earcon_delay_ms=80 text=`"Input received. I am thinking now.`"",
      "[system] heap_free=242500 heap_min=238800 stack_loop_hwm=7200 stack_motion_hwm=3090 stack_face_hwm=2760 stack_intent_hwm=3280",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=30000",
      "synthetic soak log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "soak_serial.log") -Encoding UTF8

    [System.IO.File]::WriteAllBytes(
      (Join-Path $photosDir "header_only.png"),
      [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
    )

    $metadata = [ordered]@{
      releaseTag = $releaseTag
      commit = $ExpectedCommit
      createdUtc = "2026-07-01T00:00:00Z"
      deviceId = "SELFTEST"
      port = "COM_TEST"
      operator = "preflight"
      package = $null
      voiceLeadAudition = $voiceLeadAudition
      voiceGateStatus = $voiceGateStatus
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/speech_mouth_demo_serial.log",
        "logs/speak_all_intents_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "BENCH_STATUS.md",
        "BENCH_STATUS.json",
        "NEXT_STEPS.md",
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
        "RVC_LEAD_AUDITION.md",
        "VOICE_SOURCE_STATUS.md",
        "voice_source_status.json",
        "RVC_VOICE_BASE_STATUS.md",
        "rvc_voice_base_status.json",
        "reference_audio/RVC_AUDITIONS.md",
        "reference_audio/RVC_AUDITIONS.json",
        "reference_audio/stackchan_rvc_bright_robot.wav",
        "calibration/calibration.yaml"
      )
      benchStatus = [ordered]@{
        summary = "BENCH_STATUS.md"
        report = "BENCH_STATUS.json"
        refreshCommand = "RUN_PROGRESS_CHECK.cmd"
      }
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidenceRoot "metadata.json") -Encoding UTF8

    $verifyHardwareEvidence = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"),
      "-EvidenceRoot", $evidenceRoot,
      "-AllowMissingPackage"
    )

    if ($verifyHardwareEvidence.ExitCode -eq 0) {
      throw "Hardware evidence verifier accepted a header-only media file."
    }
    Assert-TextContains $verifyHardwareEvidence.Text "too small to be credible"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $evidenceRoot) {
      Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
    }
  }
}

function Assert-HardwareEvidenceSerialMarkerGate {
  $evidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-evidence-serial-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $logsDir = Join-Path $evidenceRoot "logs"
  $photosDir = Join-Path $evidenceRoot "photos"
  $audioDir = Join-Path $evidenceRoot "audio"
  $calibrationDir = Join-Path $evidenceRoot "calibration"
  $referenceDir = Join-Path $evidenceRoot "reference_audio"

  New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $calibrationDir, $referenceDir | Out-Null

  try {
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "README.md") -Encoding UTF8
    "- [x] synthetic gate" | Set-Content -Path (Join-Path $evidenceRoot "CHECKLIST.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "DEVICE_BRINGUP.md") -Encoding UTF8
    "ready" | Set-Content -Path (Join-Path $evidenceRoot "PRODUCTION_READINESS.md") -Encoding UTF8
    $releaseTag = if ([string]::IsNullOrWhiteSpace($Version)) { "v0.0.0-selftest" } else { $Version }
    Write-SyntheticAcceptanceArtifacts -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    $voiceLeadAudition = Write-SyntheticVoiceLeadArtifacts -EvidenceRoot $evidenceRoot
    $voiceGateStatus = Write-SyntheticVoiceGateStatus -EvidenceRoot $evidenceRoot
    Write-SyntheticNextSteps -EvidenceRoot $evidenceRoot -ReleaseTag $releaseTag -Commit $ExpectedCommit
    Write-SyntheticBenchStatus -EvidenceRoot $evidenceRoot

    $observations = @(
      "# Hardware Test Observations",
      "",
      "## Display-Only Flash",
      "- Start UTC: 2026-07-01T00:00:00Z",
      "- End UTC: 2026-07-01T00:10:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Reset loop observed: no",
      "- Procedural face visible: yes",
      "- Dry-run servo log observed: yes",
      "",
      "## Servo Calibration Flash",
      "- Start UTC: 2026-07-01T00:10:00Z",
      "- End UTC: 2026-07-01T00:20:00Z",
      "- Command: synthetic",
      "- Result: pass",
      "- Pitch behavior: inside safe range",
      "- Yaw classification: disabled",
      "- Heat or brownout observed: no",
      "- Calibration changes: recorded",
      "",
      "## Soak Test",
      "- Start UTC: 2026-07-01T00:20:00Z",
      "- End UTC: 2026-07-01T00:50:00Z",
      "- Duration: 30 minutes",
      "- Reset, stall, jitter, or heat observed: no",
      "- USB power-cycle recovery: pass"
    )
    $observations | Set-Content -Path (Join-Path $evidenceRoot "OBSERVATIONS.md") -Encoding UTF8

    @(
      "# Stackchan Audio Review",
      "",
      "## Speaker Playback",
      "- Start UTC: 2026-07-01T00:50:00Z",
      "- End UTC: 2026-07-01T00:51:00Z",
      "- Sample played: reference_audio/stackchan_rvc_bright_robot.wav",
      "- Voice variant: RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)",
      "- Speaker recording file: audio/speaker.wav",
      "- Intelligible through device speaker: yes",
      "- Clipping or distortion observed: no",
      "- Volume adequate at normal listening distance: yes",
      "- Delay or playback dropout observed: no",
      "- Selected voice direction: synthetic preflight fixture for RVC Bright Robot lead audition"
    ) | Set-Content -Path (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Encoding UTF8
    Copy-Item -LiteralPath "docs/media/voice/stackchan_spark_greeting.wav" -Destination (Join-Path $audioDir "speaker.wav")

    @(
      "pitch_min_deg: -15",
      "pitch_max_deg: 15",
      "yaw_mode: disabled",
      "yaw_min_deg: -30",
      "yaw_max_deg: 30"
    ) | Set-Content -Path (Join-Path $calibrationDir "calibration.yaml") -Encoding UTF8

    @(
      "[display] M5 display renderer ready",
      "[display] frame_ms_avg=12.40 frame_ms_max=15.80 fps_avg=80.6 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=3 saccade_count=4 blink_open=1.00 breath_y=0.42 gaze_x=0.08 gaze_y=-0.03 gesture_active=0 speech_active=0 speech_env=0.00",
      "[control] command=safe_stop reduced_motion=1 motion_enabled=0 demo_enabled=0 speech_env=0.00 at_ms=2980",
      "[control] command=reduced_motion_on reduced_motion=1 at_ms=3060",
      "[face] reduced_motion=1",
      "[speech] seq=1 at_ms=3020 intent=listen priority=160 earcon=confirm earcon_delay_ms=0 text=`"I am listening with maximum attention.`"",
      "[servo] dry-run mode; set STACKCHAN_ENABLE_SERVOS=1 after calibration",
      "[heartbeat] stackchan_alive mode=display_only uptime_ms=10000",
      "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300",
      "synthetic display log missing boot marker for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8
    @(
      "Speech envelope sidecar written: speech\lead_voice.speech_envelope.json (276 frames, max env 1.000)",
      "Speech envelope sidecar verified:",
      "speech\lead_voice.speech_envelope.json",
      "[demo] Loaded sidecar speech\lead_voice.speech_envelope.json with 276 streamed frames.",
      "[demo] > mode speak 1.0",
      "[demo] < [control] command=mode_speak mode=speak event=external_command strength=1.00 at_ms=3080",
      "[demo] > speech 0.620 ah 100",
      "[demo] < [control] command=speech_env speech_env=0.62 viseme=ah duration_ms=100 at_ms=3100",
      "[demo] > speech 0.410 ee 100",
      "[demo] < [control] command=speech_env speech_env=0.41 viseme=ee duration_ms=100 at_ms=3120",
      "[demo] > speech clear",
      "[demo] < [control] command=speech_clear speech_env=0.00 viseme=neutral duration_ms=0 at_ms=3140",
      "[demo] Speech mouth demo complete.",
      "synthetic speech-mouth log line for verifier coverage."
    ) | Set-Content -Path (Join-Path $logsDir "speech_mouth_demo_serial.log") -Encoding UTF8
    Write-SyntheticSpeakAllIntentsLog -Path (Join-Path $logsDir "speak_all_intents_serial.log")
    @(
      "[boot] stackchan_alive mode=servo_calibration serial=v1",
      "[display] M5 display renderer ready",
      "[servo] enabling StackchanSERVO hardware output",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=10000",
      "synthetic servo log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "servo_calibration_serial.log") -Encoding UTF8
    @(
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=20000",
      "[display] frame_ms_avg=12.80 frame_ms_max=16.10 fps_avg=78.1 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=12 saccade_count=16 blink_open=1.00 breath_y=-0.18 gaze_x=-0.04 gaze_y=0.02 gesture_active=0 speech_active=0 speech_env=0.00",
      "[speech] seq=4 at_ms=20020 intent=think priority=150 earcon=think earcon_delay_ms=80 text=`"Input received. I am thinking now.`"",
      "[system] heap_free=242500 heap_min=238800 stack_loop_hwm=7200 stack_motion_hwm=3090 stack_face_hwm=2760 stack_intent_hwm=3280",
      "[heartbeat] stackchan_alive mode=servo_calibration uptime_ms=30000",
      "synthetic soak log line for verifier negative-test coverage."
    ) | Set-Content -Path (Join-Path $logsDir "soak_serial.log") -Encoding UTF8

    Copy-Item -LiteralPath "docs/media/stackchan_alive_preview.png" -Destination (Join-Path $photosDir "evidence.png")

    $metadata = [ordered]@{
      releaseTag = $releaseTag
      commit = $ExpectedCommit
      createdUtc = "2026-07-01T00:00:00Z"
      deviceId = "SELFTEST"
      port = "COM_TEST"
      operator = "preflight"
      package = $null
      voiceLeadAudition = $voiceLeadAudition
      voiceGateStatus = $voiceGateStatus
      requiredLogs = @(
        "logs/display_only_serial.log",
        "logs/speech_mouth_demo_serial.log",
        "logs/speak_all_intents_serial.log",
        "logs/servo_calibration_serial.log",
        "logs/soak_serial.log"
      )
      requiredRecords = @(
        "BENCH_STATUS.md",
        "BENCH_STATUS.json",
        "NEXT_STEPS.md",
        "CHECKLIST.md",
        "RELEASE_ACCEPTANCE.md",
        "release_acceptance.json",
        "OBSERVATIONS.md",
        "AUDIO_REVIEW.md",
        "RVC_LEAD_AUDITION.md",
        "VOICE_SOURCE_STATUS.md",
        "voice_source_status.json",
        "RVC_VOICE_BASE_STATUS.md",
        "rvc_voice_base_status.json",
        "reference_audio/RVC_AUDITIONS.md",
        "reference_audio/RVC_AUDITIONS.json",
        "reference_audio/stackchan_rvc_bright_robot.wav",
        "calibration/calibration.yaml"
      )
      benchStatus = [ordered]@{
        summary = "BENCH_STATUS.md"
        report = "BENCH_STATUS.json"
        refreshCommand = "RUN_PROGRESS_CHECK.cmd"
      }
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidenceRoot "metadata.json") -Encoding UTF8

    $verifyHardwareEvidence = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"),
      "-EvidenceRoot", $evidenceRoot,
      "-AllowMissingPackage"
    )

    if ($verifyHardwareEvidence.ExitCode -eq 0) {
      throw "Hardware evidence verifier accepted logs without the display boot marker."
    }
    Assert-TextContains $verifyHardwareEvidence.Text "display-only boot marker"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $evidenceRoot) {
      Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
    }
  }
}

function Assert-ArrivalPacketScaffoldGate {
  param(
    [string]$ZipPath,
    [switch]$AllowDirtyPackage
  )

  $preflightReportDir = Join-Path $repoRoot "output/preflight/$Version"
  $preflightReportPath = Join-Path $preflightReportDir "preflight_report.json"
  $preflightBackupPath = $null
  if (Test-Path -LiteralPath $preflightReportPath) {
    $preflightBackupPath = "$preflightReportPath.preflight-selftest-$([System.Guid]::NewGuid().ToString('N')).bak"
    Move-Item -LiteralPath $preflightReportPath -Destination $preflightBackupPath
  }
  New-Item -ItemType Directory -Force -Path $preflightReportDir | Out-Null
  [ordered]@{
    schema = "stackchan.preflight-report.v1"
    version = $Version
    commit = $ExpectedCommit
    status = "pass"
    generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    note = "Temporary self-test report used to verify arrival-packet checklist annotation."
    steps = @()
  } | ConvertTo-Json -Depth 5 | Set-Content -Path $preflightReportPath -Encoding UTF8

  function Restore-TemporaryPreflightReport {
    Remove-Item -LiteralPath $preflightReportPath -Force -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($preflightBackupPath) -and (Test-Path -LiteralPath $preflightBackupPath)) {
      Move-Item -LiteralPath $preflightBackupPath -Destination $preflightReportPath
    }
  }

  $startArgs = @(
    (Join-Path $PSScriptRoot "start_hardware_evidence.ps1"),
    "-ReleaseTag", $Version,
    "-PackageZip", $ZipPath,
    "-Port", "COM_TEST",
    "-Operator", "preflight",
    "-DeviceId", "SELFTEST"
  )
  if ($AllowDirtyPackage) {
    $startArgs += "-AllowDirtyPackage"
  }

  $created = Invoke-ToolText $startArgs
  if ($created.ExitCode -ne 0) {
    Restore-TemporaryPreflightReport
    throw "Arrival packet scaffold creation failed:$([Environment]::NewLine)$($created.Text)"
  }

  $evidenceRoot = @(
    ($created.Text -split "\r?\n") |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
  ) | Select-Object -Last 1

  if ([string]::IsNullOrWhiteSpace($evidenceRoot)) {
    Restore-TemporaryPreflightReport
    throw "Could not locate generated arrival packet in output:$([Environment]::NewLine)$($created.Text)"
  }

  $evidenceRoot = (Resolve-Path $evidenceRoot).Path
  $evidenceBase = (Resolve-Path (Join-Path $repoRoot "output/hardware-evidence")).Path

  try {
    foreach ($relativePath in @(
      "README.md",
      "BENCH_STATUS.md",
      "BENCH_STATUS.json",
      "NEXT_STEPS.md",
      "CHECKLIST.md",
      "OBSERVATIONS.md",
      "AUDIO_REVIEW.md",
      "RVC_LEAD_AUDITION.md",
      "metadata.json",
      "logs/package_verify.log",
      "RUN_PLAY_LEAD_VOICE.cmd",
      "RUN_HARDWARE_SIM_BASELINE.cmd",
      "RUN_DISPLAY_ONLY.cmd",
      "RUN_SPEECH_MOUTH_DEMO.cmd",
      "RUN_SPEAK_ALL_INTENTS.cmd",
      "RUN_SERVO_CALIBRATION.cmd",
      "RUN_SOAK_MONITOR.cmd",
      "RUN_PACKAGE_VERIFY.cmd",
      "RUN_SIM_HARDWARE_COMPARE.cmd",
      "RUN_PROGRESS_CHECK.cmd",
      "RUN_ROLLOUT_STATUS.cmd",
      "RUN_ADD_MEDIA.cmd",
      "RUN_EVIDENCE_VERIFY.cmd",
      "RUN_CONSUMER_PROMOTION_CHECK.cmd",
      "reference_audio/RVC_AUDITIONS.md",
      "reference_audio/RVC_AUDITIONS.json",
      "reference_audio/stackchan_rvc_bright_robot.wav"
    )) {
      $path = Join-Path $evidenceRoot ($relativePath -replace "/", "\")
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Arrival packet missing scaffold file: $relativePath"
      }
      if ((Get-Item -LiteralPath $path).Length -lt 1) {
        throw "Arrival packet scaffold file is empty: $relativePath"
      }
    }

    $metadata = Get-Content -LiteralPath (Join-Path $evidenceRoot "metadata.json") -Raw | ConvertFrom-Json
    if ($null -eq $metadata.voiceLeadAudition) {
      throw "Arrival packet metadata missing voiceLeadAudition"
    }
    if ([string]$metadata.voiceLeadAudition.title -ne "RVC Bright Robot") {
      throw "Arrival packet lead voice mismatch: $($metadata.voiceLeadAudition.title)"
    }
    if ([string]$metadata.voiceLeadAudition.referenceFile -ne "reference_audio/stackchan_rvc_bright_robot.wav") {
      throw "Arrival packet lead reference mismatch: $($metadata.voiceLeadAudition.referenceFile)"
    }
    if ($null -eq $metadata.simulationBaseline) {
      throw "Arrival packet metadata missing simulationBaseline"
    }
    if ([string]$metadata.simulationBaseline.command -ne "RUN_HARDWARE_SIM_BASELINE.cmd") {
      throw "Arrival packet simulation baseline command mismatch: $($metadata.simulationBaseline.command)"
    }
    if ([string]$metadata.simulationBaseline.report -ne "simulation/hardware-sim/latest/hardware_simulation.json") {
      throw "Arrival packet simulation baseline report mismatch: $($metadata.simulationBaseline.report)"
    }
    if ([string]$metadata.simulationBaseline.compareCommand -ne "RUN_SIM_HARDWARE_COMPARE.cmd") {
      throw "Arrival packet simulation compare command mismatch: $($metadata.simulationBaseline.compareCommand)"
    }
    if ([string]$metadata.simulationBaseline.compareReport -ne "SIM_HARDWARE_COMPARE.json") {
      throw "Arrival packet simulation compare report mismatch: $($metadata.simulationBaseline.compareReport)"
    }
    if ([string]$metadata.simulationBaseline.compareSummary -ne "SIM_HARDWARE_COMPARE.md") {
      throw "Arrival packet simulation compare summary mismatch: $($metadata.simulationBaseline.compareSummary)"
    }
    if ([string]$metadata.simulationBaseline.evidenceRole -notmatch "comparison baseline") {
      throw "Arrival packet simulation baseline role should stay non-evidence: $($metadata.simulationBaseline.evidenceRole)"
    }
    foreach ($field in @(
      @("pitch", "2"),
      @("index_rate", "0.62"),
      @("rms_mix_rate", "0.72"),
      @("protect", "0.28")
    )) {
      $actual = [string]$metadata.voiceLeadAudition.PSObject.Properties[$field[0]].Value
      if ($actual -ne $field[1]) {
        throw "Arrival packet lead setting mismatch for $($field[0]): $actual"
      }
    }

    $leadPath = Join-Path $evidenceRoot "reference_audio/stackchan_rvc_bright_robot.wav"
    $leadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leadPath).Hash.ToLowerInvariant()
    if ($leadHash -ne [string]$metadata.voiceLeadAudition.sha256) {
      throw "Arrival packet lead reference hash mismatch"
    }

    $readme = Get-Content -LiteralPath (Join-Path $evidenceRoot "README.md") -Raw
    Assert-TextContains $readme "RUN_PLAY_LEAD_VOICE.cmd"
    Assert-TextContains $readme "real-device speaker recording"
    Assert-TextContains $readme "BENCH_STATUS.md"
    Assert-TextContains $readme "RUN_SIM_HARDWARE_COMPARE.cmd"
    Assert-TextContains $readme "SIM_HARDWARE_COMPARE.md"
    Assert-TextContains $readme "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json"

    $nextSteps = Get-Content -LiteralPath (Join-Path $evidenceRoot "NEXT_STEPS.md") -Raw
    Assert-TextContains $nextSteps "RUN_PACKAGE_VERIFY.cmd"
    Assert-TextContains $nextSteps "RUN_HARDWARE_SIM_BASELINE.cmd"
    Assert-TextContains $nextSteps "pre-arrival rehearsal only"
    Assert-TextContains $nextSteps "RUN_SIM_HARDWARE_COMPARE.cmd"
    Assert-TextContains $nextSteps "SIM_HARDWARE_COMPARE.md/json"
    Assert-TextContains $nextSteps "RUN_SPEAK_ALL_INTENTS.cmd"
    Assert-TextContains $nextSteps "BENCH_STATUS.md"
    Assert-TextContains $nextSteps "RUN_CONSUMER_PROMOTION_CHECK.cmd"
    Assert-TextContains $nextSteps "Generated source WAVs alone do not count"
    Assert-TextContains $nextSteps "Do not run servo calibration unless the body is clear"
    Assert-TextContains $nextSteps "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json"

    $ciExceptionTemplate = Get-Content -LiteralPath (Join-Path $evidenceRoot "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json") -Raw | ConvertFrom-Json
    if ($ciExceptionTemplate.schema -ne "stackchan.ci-account-block-exception.v1") {
      throw "Arrival packet CI exception template schema mismatch: $($ciExceptionTemplate.schema)"
    }
    if ($ciExceptionTemplate.version -ne $Version -or $ciExceptionTemplate.commit -ne $ExpectedCommit) {
      throw "Arrival packet CI exception template does not pin release version/commit."
    }
    foreach ($fieldName in @("approvedBy", "approvedUtc", "followUpOwner", "followUpDueUtc")) {
      if ([string]$ciExceptionTemplate.PSObject.Properties[$fieldName].Value -notmatch "TBD") {
        throw "Arrival packet CI exception template $fieldName should remain a TBD placeholder."
      }
    }
    foreach ($fieldName in @("riskAccepted", "localReleaseVerificationPassed", "strictHardwareEvidencePassed", "productionVoiceSourceReady")) {
      if ($ciExceptionTemplate.PSObject.Properties[$fieldName].Value -ne $false) {
        throw "Arrival packet CI exception template $fieldName should remain false until approved."
      }
    }

    $checklist = Get-Content -LiteralPath (Join-Path $evidenceRoot "CHECKLIST.md") -Raw
    Assert-TextContains $checklist 'Pre-marked no-hardware gates were proven by the matching preflight report'
    Assert-TextContains $checklist '- [x] `pio run -e stackchan` passes.'
    Assert-TextContains $checklist '- [x] `tools/run_device_preflight.ps1` passes.'
    Assert-TextContains $checklist '- [x] `tools/verify_release_package.ps1` passes for the release ZIP.'
    Assert-TextContains $checklist '- [ ] GitHub Actions `Firmware` workflow is green on `main`.'
    Assert-TextContains $checklist '- [ ] Production voice-source provenance is completed and no longer marked pending.'

    $audioReview = Get-Content -LiteralPath (Join-Path $evidenceRoot "AUDIO_REVIEW.md") -Raw
    Assert-TextContains $audioReview "reference_audio/stackchan_rvc_bright_robot.wav"
    Assert-TextContains $audioReview "RVC Bright Robot (pitch 2, index 0.62, RMS mix 0.72, protect 0.28)"

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $progressOutput = & cmd.exe /c (Join-Path $evidenceRoot "RUN_PROGRESS_CHECK.cmd") 2>&1
      $progressExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    $progressText = ($progressOutput | Out-String)
    if ($progressExitCode -ne 2) {
      throw "Expected arrival packet progress wrapper to exit 2 for missing real hardware evidence, got $progressExitCode. Output:$([Environment]::NewLine)$progressText"
    }
    Assert-TextContains $progressText "Hardware evidence progress:"
    Assert-TextContains $progressText "Bench status written:"
    Assert-TextContains $progressText "RVC lead audition reference hash matches metadata"
    Assert-TextContains $progressText "No real-device speaker recording found under audio/"
    foreach ($relativePath in @("BENCH_STATUS.md", "BENCH_STATUS.json")) {
      $path = Join-Path $evidenceRoot $relativePath
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Arrival packet progress check did not write: $relativePath"
      }
      if ((Get-Item -LiteralPath $path).Length -lt 100) {
        throw "Arrival packet progress check wrote a suspiciously small status file: $relativePath"
      }
    }
    $benchStatusMarkdown = Get-Content -LiteralPath (Join-Path $evidenceRoot "BENCH_STATUS.md") -Raw
    Assert-TextContains $benchStatusMarkdown "stackchan.bench-status.v1"
    Assert-TextContains $benchStatusMarkdown "blocked-or-pending"
    Assert-TextContains $benchStatusMarkdown "Next command:"
    Assert-TextContains $benchStatusMarkdown "RUN_DISPLAY_ONLY.cmd"
    $benchStatusJson = Get-Content -LiteralPath (Join-Path $evidenceRoot "BENCH_STATUS.json") -Raw | ConvertFrom-Json
    if ([string]$benchStatusJson.schema -ne "stackchan.bench-status.v1") {
      throw "Arrival packet BENCH_STATUS.json schema mismatch: $($benchStatusJson.schema)"
    }
    if ([string]$benchStatusJson.status -ne "blocked-or-pending") {
      throw "Arrival packet BENCH_STATUS.json should be blocked-or-pending, got $($benchStatusJson.status)"
    }
    if ([string]$benchStatusJson.nextCommand -notmatch "RUN_DISPLAY_ONLY\.cmd") {
      throw "Arrival packet BENCH_STATUS.json next command did not point at display evidence: $($benchStatusJson.nextCommand)"
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $rolloutOutput = & cmd.exe /c (Join-Path $evidenceRoot "RUN_ROLLOUT_STATUS.cmd") 2>&1
      $rolloutExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    $rolloutText = ($rolloutOutput | Out-String)
    if ($rolloutExitCode -ne 2) {
      throw "Expected rollout status wrapper to exit 2 for blocked/pending gates, got $rolloutExitCode. Output:$([Environment]::NewLine)$rolloutText"
    }
    Assert-TextContains $rolloutText "Rollout status exported:"
    foreach ($relativePath in @("ROLLOUT_STATUS.md", "ROLLOUT_STATUS.json")) {
      $path = Join-Path $evidenceRoot $relativePath
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Arrival packet rollout status did not write: $relativePath"
      }
    }
    $rolloutStatus = Get-Content -LiteralPath (Join-Path $evidenceRoot "ROLLOUT_STATUS.md") -Raw
    Assert-TextContains $rolloutStatus "blocked-or-pending"
    Assert-TextContains $rolloutStatus "Next action:"
    Assert-TextContains $rolloutStatus "Next command:"
    Assert-TextContains $rolloutStatus "RUN_DISPLAY_ONLY.cmd"
    Assert-TextContains $rolloutStatus "production-voice-source"
    Assert-TextContains $rolloutStatus "strict-hardware-evidence"
    Assert-TextContains $rolloutStatus "voice-gate-status-consistency"
    Assert-TextContains $rolloutStatus "Evidence metadata voiceGateStatus matches package voice status reports"
    $rolloutStatusJson = Get-Content -LiteralPath (Join-Path $evidenceRoot "ROLLOUT_STATUS.json") -Raw | ConvertFrom-Json
    if ([string]$rolloutStatusJson.nextOwner -ne "hardware") {
      throw "Arrival packet ROLLOUT_STATUS.json next owner should be hardware, got $($rolloutStatusJson.nextOwner)"
    }
    if ([string]$rolloutStatusJson.nextCommand -notmatch "RUN_DISPLAY_ONLY\.cmd") {
      throw "Arrival packet ROLLOUT_STATUS.json next command did not point at display evidence: $($rolloutStatusJson.nextCommand)"
    }
    $global:LASTEXITCODE = 0
  } finally {
    $resolvedEvidence = (Resolve-Path $evidenceRoot).Path
    if (-not $resolvedEvidence.StartsWith($evidenceBase, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean unexpected arrival packet path: $resolvedEvidence"
    }
    Remove-Item -LiteralPath $resolvedEvidence -Recurse -Force
    Restore-TemporaryPreflightReport
  }
}

function Assert-HardwareSimComparisonGate {
  $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-sim-compare-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $logsDir = Join-Path $fixtureRoot "logs"
  $simDir = Join-Path $fixtureRoot "simulation/hardware-sim/latest"

  try {
    New-Item -ItemType Directory -Force -Path $logsDir, $simDir | Out-Null

    $simResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "run_hardware_simulation.ps1"),
      "-OutputDir", $simDir,
      "-Json"
    )
    if ($simResult.ExitCode -ne 0) {
      throw "Hardware simulation comparator fixture could not generate a baseline:$([Environment]::NewLine)$($simResult.Text)"
    }

    @(
      "[boot] stackchan_alive mode=display_only serial=v1",
      "[display] M5 display renderer ready canvas=double-buffered",
      "[display] frame_ms_avg=12.40 frame_ms_max=15.80 fps_avg=80.6 fps_window=30.0 frame_budget_us=33333 slow_frames=0",
      "[face] mode=1 blink_count=3 saccade_count=4 blink_open=1.00 breath_y=0.42 gaze_x=0.08 gaze_y=-0.03 gesture_active=0 speech_active=0 speech_env=0.00",
      "[system] heap_free=243000 heap_min=239000 stack_loop_hwm=7200 stack_motion_hwm=3100 stack_face_hwm=2800 stack_intent_hwm=3300"
    ) | Set-Content -Path (Join-Path $logsDir "display_only_serial.log") -Encoding UTF8

    @(
      "[demo] > mode speak 1.0",
      "[demo] > speech 0.620 ah 100",
      "[demo] < [control] command=speech_env speech_env=0.62 viseme=ah duration_ms=100 at_ms=3100",
      "[demo] > speech clear",
      "[demo] Speech mouth demo complete."
    ) | Set-Content -Path (Join-Path $logsDir "speech_mouth_demo_serial.log") -Encoding UTF8

    Write-SyntheticSpeakAllIntentsLog -Path (Join-Path $logsDir "speak_all_intents_serial.log")

    @(
      "[bridge-replay] > bridge hello bench",
      "[bridge-replay] < [bridge] type=session_ready state=ready seq=0 at_ms=100 session=bench",
      "[bridge-replay] > bridge response happy 7 hello i am stackchan and i am awake",
      "[bridge-replay] < [bridge] type=response_start state=responding seq=7 at_ms=160 event=response_started intent=happy text=`"hello i am stackchan and i am awake`"",
      "[bridge-replay] > bridge audio 0.72 ee 80",
      "[bridge-replay] < [bridge] type=audio state=responding seq=7 at_ms=220 env=0.72 viseme=ee duration_ms=80 final=0",
      "[bridge-replay] > bridge end 7",
      "[bridge-replay] < [bridge] type=response_end state=ready seq=7 at_ms=300 event=response_ended",
      "[bridge-replay] > status",
      "[bridge-replay] < [runtime] motion_enabled=1 demo_enabled=0 reduced_motion=0 speech_active=0 speech_env=0.00 bridge_ready=1 bridge_state=ready bridge_messages=8 bridge_outputs=8 bridge_parse_errors=0 bridge_downlink_errors=0 bridge_downlink_playback_errors=0 bridge_timeouts=0",
      "[bridge-replay] Bridge replay demo complete."
    ) | Set-Content -Path (Join-Path $logsDir "bridge_replay_serial.log") -Encoding UTF8

    $compareResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "compare_hardware_sim_baseline.ps1"),
      "-EvidenceRoot", $fixtureRoot
    )
    if ($compareResult.ExitCode -ne 0) {
      throw "Hardware simulation comparator fixture failed with exit $($compareResult.ExitCode):$([Environment]::NewLine)$($compareResult.Text)"
    }
    Assert-TextContains $compareResult.Text "Status: pass"

    foreach ($relativePath in @("SIM_HARDWARE_COMPARE.md", "SIM_HARDWARE_COMPARE.json")) {
      $path = Join-Path $fixtureRoot $relativePath
      if (-not (Test-Path -LiteralPath $path)) {
        throw "Hardware simulation comparator did not write: $relativePath"
      }
      if ((Get-Item -LiteralPath $path).Length -lt 100) {
        throw "Hardware simulation comparator wrote a suspiciously small report: $relativePath"
      }
    }

    $report = Get-Content -LiteralPath (Join-Path $fixtureRoot "SIM_HARDWARE_COMPARE.json") -Raw | ConvertFrom-Json
    if ([string]$report.schema -ne "stackchan.hardware-sim-compare.v1") {
      throw "Hardware simulation comparator schema mismatch: $($report.schema)"
    }
    if ([string]$report.status -ne "pass") {
      throw "Hardware simulation comparator expected pass, got $($report.status)"
    }
    if ([int]$report.failCount -ne 0 -or [int]$report.pendingCount -ne 0) {
      throw "Hardware simulation comparator should have no failed or pending checks in the fixture."
    }

    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
      Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
  }
}

function Assert-SpeechEnvelopeSidecarGate {
  $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-speech-sidecar-gate-" + [System.Guid]::NewGuid().ToString("N"))
  $sourceWav = Join-Path $repoRoot "docs/media/voice/stackchan_spark_greeting.wav"
  $sidecarPath = Join-Path $fixtureRoot "stackchan_spark_greeting.speech_envelope.json"

  try {
    if (-not (Test-Path -LiteralPath $sourceWav)) {
      throw "Speech sidecar fixture WAV missing: $sourceWav"
    }

    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    $generateResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "generate_speech_envelope_sidecar.ps1"),
      "-InputWav", $sourceWav,
      "-OutputJson", $sidecarPath
    )
    if ($generateResult.ExitCode -ne 0) {
      throw "Speech sidecar generation failed:$([Environment]::NewLine)$($generateResult.Text)"
    }
    Assert-TextContains $generateResult.Text "Speech envelope sidecar written:"

    $verifyResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "verify_speech_envelope_sidecar.ps1"),
      "-Path", $sidecarPath,
      "-MinFrames", "100",
      "-MinMaxEnvelope", "0.5"
    )
    if ($verifyResult.ExitCode -ne 0) {
      throw "Speech sidecar verification failed:$([Environment]::NewLine)$($verifyResult.Text)"
    }
    Assert-TextContains $verifyResult.Text "Speech envelope sidecar verified:"

    $streamResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "send_speech_mouth_demo.ps1"),
      "-SidecarPath", $sidecarPath,
      "-MaxFrames", "12",
      "-PrintOnly"
    )
    if ($streamResult.ExitCode -ne 0) {
      throw "Speech sidecar dry stream failed:$([Environment]::NewLine)$($streamResult.Text)"
    }
    Assert-TextContains $streamResult.Text "Loaded sidecar"
    Assert-TextContains $streamResult.Text "mode speak 1.0"
    Assert-TextContains $streamResult.Text "speech clear"
    Assert-TextContains $streamResult.Text "PrintOnly complete"

    $speakAllResult = Invoke-ToolText @(
      (Join-Path $PSScriptRoot "send_speak_all_intents_demo.ps1"),
      "-PrintOnly"
    )
    if ($speakAllResult.ExitCode -ne 0) {
      throw "Speak-all-intents dry stream failed:$([Environment]::NewLine)$($speakAllResult.Text)"
    }
    Assert-TextContains $speakAllResult.Text "[speak-all] > speak boot"
    Assert-TextContains $speakAllResult.Text "[speak-all] > speak safety"
    Assert-TextContains $speakAllResult.Text "PrintOnly complete"
    $global:LASTEXITCODE = 0
  } finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
      Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
  }
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-parse HEAD).Trim()
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($Version)) {
  $zipName = [System.IO.Path]::GetFileName($PackageZip)
  if ($zipName -match "^stackchan_alive_(.+)\.zip$") {
    $Version = $Matches[1]
  } else {
    throw "Pass -Version when -PackageZip does not match stackchan_alive_<version>.zip"
  }
}

if ([string]::IsNullOrWhiteSpace($ReportDir)) {
  $reportVersion = if ([string]::IsNullOrWhiteSpace($Version)) { "commit-$($ExpectedCommit.Substring(0, [Math]::Min(12, $ExpectedCommit.Length)))" } else { $Version }
  $ReportDir = Join-Path $repoRoot "output/preflight/$reportVersion"
}

Invoke-Step "Check required commands" {
  Assert-Command git
  Get-StackchanPlatformioCommand | Out-Null
  Add-StackchanNativeCompilerToPath | Out-Null
}

Invoke-Step "Check source tree and dependency pins" {
  Assert-CleanSourceTree
  Assert-DependencyPins
}

Invoke-Step "Check flash helper safety gates" {
  Assert-FlashHelperSafety
}

Invoke-Step "Check runtime architecture boundaries" {
  & (Join-Path $PSScriptRoot "verify_architecture.ps1")
}

Invoke-Step "Check GitHub Actions status exporter gates" {
  Assert-GitHubActionsStatusExporterGate
}

Invoke-Step "Check CI account-block exception draft helper" {
  Assert-CiAccountBlockExceptionDraftGate
}

Invoke-Step "Check local share evidence capture" {
  Assert-LocalShareEvidenceGate
}

Invoke-Step "Check rollout status Actions override" {
  Assert-RolloutStatusActionsOverrideGate
}

Invoke-Step "Check speech envelope sidecar tooling" {
  Assert-SpeechEnvelopeSidecarGate
}

Invoke-Step "Check LiteRT-LM contract smoke" {
  & (Join-Path $PSScriptRoot "run_litert_lm_smoke.ps1") -OutputDir (Join-Path $ReportDir "litert-lm-smoke")
}

Invoke-Step "Check hardware simulation proxy" {
  & (Join-Path $PSScriptRoot "run_hardware_simulation.ps1") -OutputDir (Join-Path $ReportDir "hardware-sim")
}

Invoke-Step "Check LAN bridge smoke report" {
  & (Join-Path $PSScriptRoot "run_lan_smoke.ps1") -OutputDir (Join-Path $ReportDir "lan-smoke")
}

Invoke-Step "Check pre-arrival simulation report" {
  & (Join-Path $PSScriptRoot "run_prearrival_sim_check.ps1") -OutputDir (Join-Path $ReportDir "prearrival-sim")
}

Invoke-Step "Check hardware simulation comparator" {
  Assert-HardwareSimComparisonGate
}

Invoke-Step "Check preview media quality" {
  & (Join-Path $PSScriptRoot "verify_preview_media.ps1")
}

Invoke-Step "Check hardware evidence media gate" {
  Assert-HardwareEvidenceMediaGate
}

Invoke-Step "Check hardware evidence serial marker gate" {
  Assert-HardwareEvidenceSerialMarkerGate
}

Invoke-Step "Run native logic tests" {
  Invoke-StackchanPlatformio test -e native_logic
}

Invoke-Step "Compile embedded test firmware" {
  Invoke-StackchanPlatformio test -e stackchan --without-uploading --without-testing
}

Invoke-Step "Build display-only and servo-calibration firmware" {
  Invoke-StackchanPlatformio run -e stackchan -e stackchan_servo_calibration
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  Invoke-Step "Verify release package" {
    $verifyScript = Join-Path $PSScriptRoot "verify_release_package.ps1"
    if ($AllowDirty) {
      & $verifyScript -Version $Version -ZipPath $PackageZip -ExpectedCommit $ExpectedCommit -AllowDirtyPackage
    } else {
      & $verifyScript -Version $Version -ZipPath $PackageZip -ExpectedCommit $ExpectedCommit
    }
  }

  Invoke-Step "Check arrival packet scaffold" {
    Assert-ArrivalPacketScaffoldGate $PackageZip -AllowDirtyPackage:$AllowDirty
  }

  Invoke-Step "Check release binary flash helper" {
    Assert-ReleaseFlashHelperSafety $PackageZip -AllowDirtyPackage:$AllowDirty
  }

  Invoke-Step "Check release publish branch guard" {
    Assert-ReleasePublishBranchGuard -AllowDirtyPackage:$AllowDirty
  }
}

Write-Host ""
Write-Host "Device preflight passed for commit $ExpectedCommit"
Write-PreflightReport -Status "pass"
Write-Host "Preflight report:"
Write-Host $ReportDir
