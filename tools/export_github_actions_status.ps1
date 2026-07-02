param(
  [string]$Repo = "RobVanProd/stackchan_alive",
  [string]$Version = "",
  [string]$Commit = "",
  [string]$OutputDir = "",
  [string[]]$RequiredWorkflows = @("Firmware", "Release"),
  [string]$FixtureRoot = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Commit)) {
  $Commit = (git rev-parse HEAD).Trim()
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $repoRoot "output/actions-status/$Version"
}

$RequiredWorkflows = @(
  $RequiredWorkflows |
    ForEach-Object { ([string]$_) -split "," } |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)
if ($RequiredWorkflows.Count -lt 1) {
  throw "At least one required workflow must be specified."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Get-FixtureJson {
  param(
    [string]$Name
  )

  $fixturePath = Join-Path $FixtureRoot $Name
  if (-not (Test-Path -LiteralPath $fixturePath)) {
    throw "Missing GitHub Actions status fixture: $fixturePath"
  }

  return (Get-Content -LiteralPath $fixturePath -Raw).Trim()
}

function Get-GhJson {
  param([string[]]$Arguments)

  if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq "run" -and $Arguments[1] -eq "list") {
      return Get-FixtureJson "run_list.json"
    }

    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq "api") {
      $apiPath = [string]$Arguments[1]
      if ($apiPath -match "/actions/runs/(\d+)/attempts/1/jobs$") {
        return Get-FixtureJson "jobs_$($Matches[1]).json"
      }
      if ($apiPath -match "/check-runs/(\d+)/annotations$") {
        return Get-FixtureJson "annotations_$($Matches[1]).json"
      }
    }

    throw "Unsupported GitHub Actions status fixture command: gh $($Arguments -join ' ')"
  }

  $output = & gh @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "gh command failed: gh $($Arguments -join ' ')`n$($output | Out-String)"
  }
  return ($output | Out-String).Trim()
}

function Split-Repo {
  param([string]$Repository)

  $parts = $Repository -split "/", 2
  if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
    throw "Repo must be in owner/name form: $Repository"
  }
  return [ordered]@{ owner = $parts[0]; name = $parts[1] }
}

function Get-RunAnnotations {
  param(
    [string]$Repository,
    [long]$RunId
  )

  $repoParts = Split-Repo $Repository
  $jobsJson = Get-GhJson @("api", "repos/$($repoParts.owner)/$($repoParts.name)/actions/runs/$RunId/attempts/1/jobs")
  $jobs = ($jobsJson | ConvertFrom-Json).jobs
  $jobReports = @()

  foreach ($job in @($jobs)) {
    $annotations = @()
    try {
      $annotationJson = Get-GhJson @("api", "repos/$($repoParts.owner)/$($repoParts.name)/check-runs/$($job.id)/annotations")
      $parsedAnnotations = $annotationJson | ConvertFrom-Json
      if ($parsedAnnotations.PSObject.Properties.Name -contains "value") {
        $parsedAnnotations = $parsedAnnotations.value
      }
      foreach ($annotation in @($parsedAnnotations)) {
        $annotations += [ordered]@{
          level = [string]$annotation.annotation_level
          path = [string]$annotation.path
          message = [string]$annotation.message
        }
      }
    } catch {
      $annotations += [ordered]@{
        level = "warning"
        path = ""
        message = "Unable to read check-run annotations: $($_.Exception.Message)"
      }
    }

    $jobReports += [ordered]@{
      name = [string]$job.name
      status = [string]$job.status
      conclusion = [string]$job.conclusion
      labels = @($job.labels)
      runnerId = [int]$job.runner_id
      runnerName = [string]$job.runner_name
      stepCount = @($job.steps).Count
      annotations = @($annotations)
      url = [string]$job.html_url
    }
  }

  return @($jobReports)
}

$runListJson = Get-GhJson @(
  "run",
  "list",
  "--repo", $Repo,
  "--limit", "50",
  "--json", "databaseId,name,headSha,headBranch,status,conclusion,createdAt,url,event,displayTitle"
)
$parsedRuns = $runListJson | ConvertFrom-Json
$allRuns = @()
foreach ($run in $parsedRuns) {
  $allRuns += $run
}
$matchingRuns = @(
  $allRuns |
    Where-Object { $_.headSha -eq $Commit -and $RequiredWorkflows -contains [string]$_.name } |
    Sort-Object createdAt
)

$runReports = @()
foreach ($run in $matchingRuns) {
  $jobs = Get-RunAnnotations -Repository $Repo -RunId ([long]$run.databaseId)
  $runReports += [ordered]@{
    workflow = [string]$run.name
    runId = [long]$run.databaseId
    event = [string]$run.event
    branchOrTag = [string]$run.headBranch
    status = [string]$run.status
    conclusion = [string]$run.conclusion
    createdAt = [string]$run.createdAt
    url = [string]$run.url
    jobs = @($jobs)
  }
}

$allJobs = @($runReports | ForEach-Object { $_.jobs })
$allAnnotations = @($allJobs | ForEach-Object { $_.annotations })
$observedWorkflowNames = @($runReports | ForEach-Object { [string]$_.workflow } | Select-Object -Unique)
$missingRequiredWorkflows = @(
  $RequiredWorkflows |
    Where-Object { $observedWorkflowNames -notcontains $_ }
)
$allRequiredWorkflowsObserved = ($missingRequiredWorkflows.Count -eq 0)
$billingMessages = @(
  $allAnnotations |
    Where-Object { $_.message -match "payments have failed|spending limit" }
)
$jobsNeverReachedRunner = ($allJobs.Count -gt 0 -and @($allJobs | Where-Object { $_.runnerId -eq 0 -and $_.stepCount -eq 0 }).Count -eq $allJobs.Count)
$allSuccessful = ($allRequiredWorkflowsObserved -and $runReports.Count -gt 0 -and @($runReports | Where-Object { $_.conclusion -ne "success" }).Count -eq 0)

$summaryStatus = "missing"
if (-not $allRequiredWorkflowsObserved -and $runReports.Count -gt 0) {
  $summaryStatus = "missing-required-workflow"
} elseif ($allSuccessful) {
  $summaryStatus = "success"
} elseif ($allRequiredWorkflowsObserved -and $billingMessages.Count -gt 0 -and $jobsNeverReachedRunner) {
  $summaryStatus = "external-account-billing-or-spending-limit"
} elseif ($allRequiredWorkflowsObserved -and $jobsNeverReachedRunner) {
  $summaryStatus = "external-account-ci-pre-runner-allocation"
} elseif ($runReports.Count -gt 0) {
  $summaryStatus = "failed-or-incomplete"
}

$report = [ordered]@{
  schema = "stackchan.github-actions-status.v1"
  version = $Version
  commit = $Commit
  repo = $Repo
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = $summaryStatus
  interpretation = if ($summaryStatus -eq "external-account-billing-or-spending-limit") {
    "GitHub Actions did not start any job steps because GitHub reported an account billing or spending-limit issue. Treat local release verification and device preflight as the available technical evidence until account billing is fixed and workflows can run."
  } elseif ($summaryStatus -eq "external-account-ci-pre-runner-allocation") {
    "GitHub Actions did not start any job steps and no runner was assigned to any matching job. GitHub did not provide a billing annotation, so this is recorded as an external pre-runner allocation failure rather than an in-repo build or test failure. Treat local release verification and device preflight as the available technical evidence until hosted jobs can start."
  } elseif ($summaryStatus -eq "success") {
    "GitHub Actions completed successfully for all required workflows on the matching commit."
  } elseif ($summaryStatus -eq "missing-required-workflow") {
    "At least one required GitHub Actions workflow was not found for this commit in the recent run list. This is not promotion-ready because success requires every required workflow to be observed."
  } elseif ($summaryStatus -eq "missing") {
    "No matching Firmware or Release workflow runs were found for this commit in the recent run list."
  } else {
    "One or more GitHub Actions runs failed or were incomplete; inspect run and job annotations."
  }
  requiredWorkflows = @($RequiredWorkflows)
  missingRequiredWorkflows = @($missingRequiredWorkflows)
  workflows = @($runReports)
}

$jsonPath = Join-Path $OutputDir "github_actions_status.json"
$mdPath = Join-Path $OutputDir "GITHUB_ACTIONS_STATUS.md"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

$workflowLines = @()
foreach ($workflow in @($runReports)) {
  $workflowLines += "- $($workflow.workflow): $($workflow.conclusion) ($($workflow.url))"
  foreach ($job in @($workflow.jobs)) {
    $workflowLines += "  - Job $($job.name): $($job.conclusion), runnerId=$($job.runnerId), steps=$($job.stepCount)"
    foreach ($annotation in @($job.annotations)) {
      $workflowLines += "    - $($annotation.message)"
    }
  }
}

if ($workflowLines.Count -eq 0) {
  $workflowLines += "- No matching required workflow runs found for this commit."
}

$missingWorkflowLines = @()
foreach ($workflowName in $missingRequiredWorkflows) {
  $missingWorkflowLines += "- $workflowName"
}
if ($missingWorkflowLines.Count -eq 0) {
  $missingWorkflowLines += "- None"
}

@"
# GitHub Actions Status

Release: $Version
Commit: $Commit
Repository: $Repo
Status: $summaryStatus
Required workflows: $($RequiredWorkflows -join ", ")

$($report.interpretation)

## Missing Required Workflows

$($missingWorkflowLines -join [Environment]::NewLine)

## Matching Workflow Runs

$($workflowLines -join [Environment]::NewLine)

Machine-readable status: ``github_actions_status.json``
"@ | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "GitHub Actions status exported:"
Write-Host $mdPath
Write-Host $jsonPath

if ($summaryStatus -eq "failed-or-incomplete" -or $summaryStatus -eq "missing" -or $summaryStatus -eq "missing-required-workflow") {
  exit 1
}
