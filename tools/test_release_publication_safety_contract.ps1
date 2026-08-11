$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$publishPath = Join-Path $PSScriptRoot 'publish_release.ps1'
$sharePath = Join-Path $PSScriptRoot 'share_release.ps1'
$publishCmdPath = Join-Path $PSScriptRoot 'publish_release.cmd'
$shareCmdPath = Join-Path $PSScriptRoot 'share_release.cmd'
$gitCommand = Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitExecutable = (Resolve-Path -LiteralPath ([string]$gitCommand.Source)).Path
$powerShellCommand = Get-Command -Name powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
$powerShellExecutable = (Resolve-Path -LiteralPath ([string]$powerShellCommand.Source)).Path

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Get-ScriptAst {
  param([Parameter(Mandatory = $true)][string]$Path)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Path,
    [ref]$tokens,
    [ref]$errors
  )
  if (@($errors).Count -gt 0) {
    throw "PowerShell parse failed for $Path`: $(@($errors | ForEach-Object Message) -join '; ')"
  }
  return $ast
}

function Get-FunctionDefinition {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $definition = $Ast.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $Name
    }, $true)
  if ($null -eq $definition) {
    throw "Missing function definition: $Name"
  }
  return $definition
}

$publishText = Get-Content -LiteralPath $publishPath -Raw
$publishAst = Get-ScriptAst -Path $publishPath
$shareText = Get-Content -LiteralPath $sharePath -Raw
$publishCmdText = Get-Content -LiteralPath $publishCmdPath -Raw
$shareCmdText = Get-Content -LiteralPath $shareCmdPath -Raw
$null = Get-ScriptAst -Path $sharePath

Assert-True ($publishText -match 'Get-Command\s+-Name\s+git\s+-CommandType\s+Application') 'Publish must resolve Git as an Application.'
Assert-True ($publishText -match 'Get-Command\s+-Name\s+gh\s+-CommandType\s+Application') 'Publish must resolve GitHub CLI as an Application.'
Assert-True ($publishText -notmatch '\brepo\s+view\b') 'Publish must not infer repository authority through ambient GitHub CLI context.'
Assert-True ($publishText -match 'Real publication requires explicit -Repo owner/name') 'Real publication must require an explicit repository target.'
Assert-True ($publishText -match 'Assert-SafeGitHubRepositoryName -Value \$Repo') 'Publish must validate an explicitly supplied repository target.'
Assert-True ($shareText -match 'Get-Command\s+-Name\s+git\s+-CommandType\s+Application') 'Share must resolve Git as an Application.'
Assert-True ($publishText -match 'Get-Command\s+-Name\s+powershell\.exe\s+-CommandType\s+Application') 'Publish must resolve Windows PowerShell as an Application.'
Assert-True ($shareText -match 'Get-Command\s+-Name\s+powershell\.exe\s+-CommandType\s+Application') 'Share must resolve Windows PowerShell as an Application.'
Assert-True ($publishText -notmatch '&\s+powershell\.exe\b') 'Publish must never invoke ambient powershell.exe command resolution.'
Assert-True ($shareText -notmatch '&\s+powershell\.exe\b') 'Share must never invoke ambient powershell.exe command resolution.'
Assert-True ($publishText -match '&\s+\$script:publishPowerShellExecutable\b') 'Publish must invoke the exact resolved Windows PowerShell application.'
Assert-True ($shareText -match '&\s+\$script:sharePowerShellExecutable\b') 'Share must invoke the exact resolved Windows PowerShell application.'
Assert-True ($shareText -notmatch 'powershell\.exe\s+-NoProfile') 'Generated share helpers must not contain a bare PowerShell executable name.'
Assert-True ($shareText -match '`"\$script:sharePowerShellExecutable`" -NoProfile -ExecutionPolicy Bypass -File') 'Generated STOP_SHARING helper must quote the exact resolved PowerShell path and use -File.'
Assert-True ($publishText -notmatch '(?m)^\s*Set-Location\b') 'Publish must not change ambient working location.'
Assert-True ($shareText -notmatch '(?m)^\s*Set-Location\b') 'Share must not change ambient working location.'
foreach ($cmdWrapper in @(
    [pscustomobject]@{ name = 'Publish'; text = $publishCmdText; variable = 'STACKCHAN_PUBLISH_POWERSHELL'; script = 'publish_release.ps1' },
    [pscustomobject]@{ name = 'Share'; text = $shareCmdText; variable = 'STACKCHAN_SHARE_POWERSHELL'; script = 'share_release.ps1' }
  )) {
  Assert-True ($cmdWrapper.text -notmatch '(?im)^\s*powershell(?:\.exe)?\s') "$($cmdWrapper.name) CMD wrapper must not use ambient PowerShell command resolution."
  Assert-True ($cmdWrapper.text -match [regex]::Escape('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe')) "$($cmdWrapper.name) CMD wrapper must pin the Windows PowerShell system path."
  Assert-True ($cmdWrapper.text -match ('if not exist "%{0}%"' -f $cmdWrapper.variable)) "$($cmdWrapper.name) CMD wrapper must fail closed when exact Windows PowerShell is absent."
  Assert-True ($cmdWrapper.text -match ('"%{0}%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0{1}" %\*' -f $cmdWrapper.variable, $cmdWrapper.script)) "$($cmdWrapper.name) CMD wrapper must quote the exact executable and script paths."
}

$publishGitInvocations = @($publishAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '^&\s+\$script:publishGitExecutable\b'
    }, $true))
Assert-True ($publishGitInvocations.Count -eq 1) 'Publish must invoke the Git application only through one hardened wrapper.'
$publishGitWrapper = Get-FunctionDefinition -Ast $publishAst -Name 'Invoke-PublishTrustedGit'
Assert-True ($publishGitInvocations[0].Extent.StartOffset -gt $publishGitWrapper.Extent.StartOffset -and
  $publishGitInvocations[0].Extent.EndOffset -lt $publishGitWrapper.Extent.EndOffset) 'Publish Git application invocation escaped the hardened wrapper.'
$publishGitHubInvocations = @($publishAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '^&\s+\$script:publishGitHubExecutable\b'
    }, $true))
Assert-True ($publishGitHubInvocations.Count -gt 0) 'Publish GitHub CLI invocations were not found.'
$shareAst = Get-ScriptAst -Path $sharePath
$shareGitInvocations = @($shareAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '^&\s+\$script:shareGitExecutable\b'
    }, $true))
Assert-True ($shareGitInvocations.Count -eq 1) 'Share must invoke the Git application only through one hardened wrapper.'
$shareGitWrapper = Get-FunctionDefinition -Ast $shareAst -Name 'Invoke-ShareTrustedGit'
Assert-True ($shareGitInvocations[0].Extent.StartOffset -gt $shareGitWrapper.Extent.StartOffset -and
  $shareGitInvocations[0].Extent.EndOffset -lt $shareGitWrapper.Extent.EndOffset) 'Share Git application invocation escaped the hardened wrapper.'

foreach ($wrapper in @(
    [pscustomobject]@{ name = 'publish'; text = $publishGitWrapper.Extent.Text; root = '$script:publishRepoRoot' },
    [pscustomobject]@{ name = 'share'; text = $shareGitWrapper.Extent.Text; root = '$script:shareRepoRoot' }
  )) {
  foreach ($requiredTrustPattern in @(
      'core.hooksPath=', 'core.fsmonitor=false', 'core.untrackedCache=false',
      'core.useBuiltinFSMonitor=false', 'maintenance.auto=false', 'core.autocrlf=true',
      'core.attributesFile=', 'filter.lfs.process=', 'filter.lfs.clean=',
      'filter.lfs.smudge=', 'filter.lfs.required=false', "'-C', $($wrapper.root)",
      "'GIT_NO_REPLACE_OBJECTS', '1', [EnvironmentVariableTarget]::Process",
      "'GIT_ATTR_NOSYSTEM', '1', [EnvironmentVariableTarget]::Process"
    )) {
    Assert-True ($wrapper.text.IndexOf($requiredTrustPattern, [System.StringComparison]::Ordinal) -ge 0) "$($wrapper.name) Git wrapper is missing trust control: $requiredTrustPattern"
  }
}

$tagFunctionText = (Get-FunctionDefinition -Ast $publishAst -Name 'New-VerifiedReleaseTag').Extent.Text
foreach ($requiredPattern in @(
    "Invoke-PublishTrustedGit -Arguments @('tag', '-a', `$Tag, `$Commit, '-m', `$Tag)",
    "'rev-list', '-n', '1', `$Tag",
    "Invoke-PublishTrustedGit -Arguments @('tag', '-d', `$Tag)"
  )) {
  Assert-True ($tagFunctionText.IndexOf($requiredPattern, [System.StringComparison]::Ordinal) -ge 0) "Tag creation guard missing exact pattern: $requiredPattern"
}

$dryRunMarker = 'Dry run: verified parameters and local Git authority only'
$dryRunIndex = $publishText.IndexOf($dryRunMarker, [System.StringComparison]::Ordinal)
$firstOperationalVerifyAfterDryRun = $publishText.IndexOf('Invoke-OperationalPackageVerification `', $dryRunIndex, [System.StringComparison]::Ordinal)
$ghResolutionAfterDryRun = $publishText.IndexOf('$publishGitHubCommand = Get-Command', $dryRunIndex, [System.StringComparison]::Ordinal)
$snapshotAfterDryRun = $publishText.IndexOf('$snapshot = New-VerifiedPublicationSnapshot', $dryRunIndex, [System.StringComparison]::Ordinal)
Assert-True ($dryRunIndex -ge 0) 'Publish is missing the output-only dry-run branch.'
Assert-True ($firstOperationalVerifyAfterDryRun -gt $dryRunIndex) 'Dry-run return must precede operational verification.'
Assert-True ($ghResolutionAfterDryRun -gt $dryRunIndex) 'Dry-run return must precede GitHub CLI resolution/network access.'
Assert-True ($snapshotAfterDryRun -gt $dryRunIndex) 'Dry-run return must precede snapshot mutation.'
$dryRunTail = $publishText.Substring($dryRunIndex, $firstOperationalVerifyAfterDryRun - $dryRunIndex)
Assert-True ($dryRunTail -match '(?m)^\s*return\s*$') 'Dry-run branch must return before verification or mutation.'
foreach ($forbiddenPattern in @('New-Item', 'Copy-Item', 'Remove-Item', 'Expand-', 'Invoke-WebRequest', 'release create', 'release upload', 'ls-remote')) {
  Assert-True ($dryRunTail.IndexOf($forbiddenPattern, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Dry-run branch contains forbidden operation: $forbiddenPattern"
}

$sourceVerifyIndex = $shareText.IndexOf('Invoke-OperationalPackageVerification `', [System.StringComparison]::Ordinal)
$snapshotIndex = $shareText.IndexOf('$snapshot = New-VerifiedShareSnapshot', [System.StringComparison]::Ordinal)
$snapshotSidecarIndex = $shareText.IndexOf('$snapshotSidecar -cne', [System.StringComparison]::Ordinal)
$shareMutationIndex = $shareText.IndexOf('Stop-ExistingShare -ExistingShareRoot $shareRoot', [System.StringComparison]::Ordinal)
Assert-True ($sourceVerifyIndex -ge 0 -and $sourceVerifyIndex -lt $snapshotIndex) 'Source verification must precede share snapshot creation.'
Assert-True ($snapshotSidecarIndex -gt $snapshotIndex -and $snapshotSidecarIndex -lt $shareMutationIndex) 'Copied sidecar validation must precede persistent share mutation.'
Assert-True ($shareText.IndexOf('export_rollout_status.ps1', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Share must not execute the local rollout exporter into served output.'
Assert-True ($shareText.IndexOf('<a href="ROLLOUT_STATUS.', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Share must not advertise locally regenerated rollout assets.'

$workflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
$workflowMutationStepIndex = $workflowText.IndexOf('      - name: Create GitHub release', [System.StringComparison]::Ordinal)
Assert-True ($workflowMutationStepIndex -ge 0) 'Release workflow is missing its GitHub release mutation step.'
$workflowMutationStep = $workflowText.Substring($workflowMutationStepIndex)
$workflowRemoteProbe = '$remoteLines = @(& $gitCommand.Source ls-remote "https://github.com/${{ github.repository }}.git" $tagRef $peeledRef)'
$workflowCommitGate = 'if ($remoteCommit -cne ([string]$env:STACKCHAN_RELEASE_COMMIT).ToLowerInvariant())'
$workflowCreate = '& $ghCommand.Source release create $version `'
$workflowProbeIndex = $workflowMutationStep.IndexOf($workflowRemoteProbe, [System.StringComparison]::Ordinal)
$workflowGateIndex = $workflowMutationStep.IndexOf($workflowCommitGate, [System.StringComparison]::Ordinal)
$workflowCreateIndex = $workflowMutationStep.IndexOf($workflowCreate, [System.StringComparison]::Ordinal)
Assert-True ($workflowProbeIndex -ge 0 -and $workflowProbeIndex -lt $workflowGateIndex -and $workflowGateIndex -lt $workflowCreateIndex) 'Release workflow must resolve and compare the exact remote tag immediately before release creation.'
$workflowPreCreate = $workflowMutationStep.Substring($workflowGateIndex, $workflowCreateIndex - $workflowGateIndex)
foreach ($forbiddenMutation in @('gh release', 'release upload', 'git push', 'Copy-Item', 'New-Item', 'Remove-Item')) {
  Assert-True ($workflowPreCreate.IndexOf($forbiddenMutation, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Release workflow mutates state between remote tag verification and gh release create: $forbiddenMutation"
}
Assert-True ($workflowMutationStep.IndexOf('--target $env:STACKCHAN_RELEASE_COMMIT `', $workflowCreateIndex, [System.StringComparison]::Ordinal) -gt $workflowCreateIndex) 'Release workflow gh create must target exact STACKCHAN_RELEASE_COMMIT authority.'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('stackchan-publication-contract-' + [guid]::NewGuid().ToString('N'))
$releaseRoot = Join-Path $repoRoot 'output/release'
$dryVersion = 'dryrun-contract-' + [guid]::NewGuid().ToString('N')
$dryPackageRoot = Join-Path $releaseRoot $dryVersion
$dryZipPath = Join-Path $releaseRoot "stackchan_alive_$dryVersion.zip"
$drySidecarPath = "$dryZipPath.sha256"
$originalPath = $env:PATH
$originalLocation = (Get-Location).Path
try {
  New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
  $shimRoot = Join-Path $fixtureRoot 'bin'
  New-Item -ItemType Directory -Path $shimRoot | Out-Null
  $ghMarker = Join-Path $fixtureRoot 'gh-invoked.txt'
  $powerShellMarker = Join-Path $fixtureRoot 'ambient-powershell-invoked.txt'
  @('@echo off', "echo invoked>`"$ghMarker`"", 'exit /b 91') | Set-Content -LiteralPath (Join-Path $shimRoot 'gh.cmd') -Encoding ASCII
  $env:PATH = "$shimRoot;$originalPath"
  $env:STACKCHAN_PUBLICATION_POWERSHELL_MARKER = $powerShellMarker
  Set-Item -Path 'Function:\global:powershell.exe' -Value {
    'invoked' | Set-Content -LiteralPath $env:STACKCHAN_PUBLICATION_POWERSHELL_MARKER -Encoding ASCII
    throw 'Ambient powershell.exe function must never execute.'
  }

  New-Item -ItemType Directory -Path $dryPackageRoot -Force | Out-Null
  'unchanged package fixture' | Set-Content -LiteralPath (Join-Path $dryPackageRoot 'fixture.txt') -Encoding ASCII
  'unchanged zip fixture' | Set-Content -LiteralPath $dryZipPath -Encoding ASCII
  'unchanged sidecar fixture' | Set-Content -LiteralPath $drySidecarPath -Encoding ASCII
  $beforeCandidateHashes = @(
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dryPackageRoot 'fixture.txt'), $dryZipPath, $drySidecarPath |
      ForEach-Object Hash
  )
  $beforeTags = (& $gitExecutable -C $repoRoot tag --list | Sort-Object) -join "`n"
  $beforeSnapshots = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter "stackchan-publish-$PID-*" -ErrorAction SilentlyContinue | ForEach-Object FullName | Sort-Object)

  $dryOutput = & $publishPath -Version $dryVersion -CreateTag -DryRun *>&1
  Assert-True ($LASTEXITCODE -eq 0) "Publish dry run failed: $(($dryOutput | Out-String).Trim())"
  Assert-True (($dryOutput | Out-String).IndexOf($dryRunMarker, [System.StringComparison]::Ordinal) -ge 0) 'Publish dry run did not reach the output-only branch.'
  Assert-True (-not (Test-Path -LiteralPath $ghMarker)) 'Publish dry run invoked GitHub CLI.'
  Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) 'Publish dry run invoked ambient powershell.exe command resolution.'
  Assert-True ((Get-Location).Path -ceq $originalLocation) 'Publish dry run changed ambient working location.'
  $afterTags = (& $gitExecutable -C $repoRoot tag --list | Sort-Object) -join "`n"
  Assert-True ($afterTags -ceq $beforeTags) 'Publish dry run mutated local tags.'
  $afterCandidateHashes = @(
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dryPackageRoot 'fixture.txt'), $dryZipPath, $drySidecarPath |
      ForEach-Object Hash
  )
  Assert-True ((Compare-Object $beforeCandidateHashes $afterCandidateHashes).Count -eq 0) 'Publish dry run mutated package candidates.'
  $afterSnapshots = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter "stackchan-publish-$PID-*" -ErrorAction SilentlyContinue | ForEach-Object FullName | Sort-Object)
  Assert-True ((Compare-Object $beforeSnapshots $afterSnapshots).Count -eq 0) 'Publish dry run created a publication snapshot.'

  $targetRepo = Join-Path $fixtureRoot 'target'
  $ambientRepo = Join-Path $fixtureRoot 'ambient'
  & $gitExecutable init -q $targetRepo
  & $gitExecutable -C $targetRepo config user.name 'Publication Contract'
  & $gitExecutable -C $targetRepo config user.email 'publication-contract@example.invalid'
  & $gitExecutable -C $targetRepo config core.autocrlf false
  & $gitExecutable -C $targetRepo commit --allow-empty -m first | Out-Null
  $firstCommit = (& $gitExecutable -C $targetRepo rev-parse HEAD).Trim().ToLowerInvariant()
  & $gitExecutable -C $targetRepo commit --allow-empty -m second | Out-Null
  $secondCommit = (& $gitExecutable -C $targetRepo rev-parse HEAD).Trim().ToLowerInvariant()
  'trusted filter input' | Set-Content -LiteralPath (Join-Path $targetRepo 'probe.txt') -Encoding ASCII
  'probe.txt filter=lfs' | Set-Content -LiteralPath (Join-Path $targetRepo '.gitattributes') -Encoding ASCII
  & $gitExecutable -C $targetRepo add -- probe.txt .gitattributes
  & $gitExecutable -C $targetRepo commit -m probe | Out-Null
  & $gitExecutable init -q $ambientRepo
  & $gitExecutable -C $ambientRepo config user.name 'Publication Contract'
  & $gitExecutable -C $ambientRepo config user.email 'publication-contract@example.invalid'
  & $gitExecutable -C $ambientRepo commit --allow-empty -m ambient | Out-Null

  . ([scriptblock]::Create($publishGitWrapper.Extent.Text))
  . ([scriptblock]::Create((Get-FunctionDefinition -Ast $publishAst -Name 'Invoke-Checked').Extent.Text))
  . ([scriptblock]::Create((Get-FunctionDefinition -Ast $publishAst -Name 'New-VerifiedReleaseTag').Extent.Text))
  $script:publishGitExecutable = $gitExecutable
  $script:publishRepoRoot = $targetRepo
  $script:publishGitDisabledHooksPath = Join-Path $targetRepo 'disabled-publish-hooks-must-not-exist'
  $script:publishNullAttributesPath = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }

  $hookMarker = Join-Path $fixtureRoot 'hostile-hook-invoked.txt'
  $fsmonitorMarker = Join-Path $fixtureRoot 'hostile-fsmonitor-invoked.txt'
  $lfsMarker = Join-Path $fixtureRoot 'hostile-lfs-invoked.txt'
  $hostileHooks = Join-Path $fixtureRoot 'hostile-hooks'
  New-Item -ItemType Directory -Path $hostileHooks | Out-Null
  $hookMarkerForShell = $hookMarker.Replace('\', '/')
  $fsmonitorMarkerForShell = $fsmonitorMarker.Replace('\', '/')
  $lfsMarkerForShell = $lfsMarker.Replace('\', '/')
  @('#!/bin/sh', "echo invoked > `"$hookMarkerForShell`"", 'exit 0') |
    Set-Content -LiteralPath (Join-Path $hostileHooks 'pre-push') -Encoding ASCII
  $fsmonitorCommand = Join-Path $fixtureRoot 'hostile-fsmonitor'
  @('#!/bin/sh', "echo invoked > `"$fsmonitorMarkerForShell`"", 'exit 0') |
    Set-Content -LiteralPath $fsmonitorCommand -Encoding ASCII
  $lfsCommand = Join-Path $fixtureRoot 'hostile-lfs-filter'
  @('#!/bin/sh', "echo invoked > `"$lfsMarkerForShell`"", 'exit 91') |
    Set-Content -LiteralPath $lfsCommand -Encoding ASCII
  $globalAttributes = Join-Path $fixtureRoot 'hostile-global-attributes'
  '*.txt contractattr=set' | Set-Content -LiteralPath $globalAttributes -Encoding ASCII
  & $gitExecutable -C $targetRepo config core.hooksPath $hostileHooks
  & $gitExecutable -C $targetRepo config core.fsmonitor $fsmonitorCommand
  & $gitExecutable -C $targetRepo config core.untrackedCache true
  & $gitExecutable -C $targetRepo config maintenance.auto true
  & $gitExecutable -C $targetRepo config core.attributesFile $globalAttributes
  & $gitExecutable -C $targetRepo config filter.lfs.process $lfsCommand
  & $gitExecutable -C $targetRepo config filter.lfs.clean $lfsCommand
  & $gitExecutable -C $targetRepo config filter.lfs.smudge $lfsCommand
  & $gitExecutable -C $targetRepo config filter.lfs.required true
  & $gitExecutable -C $targetRepo replace $firstCommit $secondCommit
  $replacedSubject = (& $gitExecutable -C $targetRepo log -1 --format=%s $firstCommit).Trim()
  Assert-True ($replacedSubject -ceq 'second') 'Hostile replace-object fixture did not affect unhardened Git as expected.'

  $trustedSubject = (Invoke-PublishTrustedGit -Arguments @(
      'log', '-1', '--format=%s', $firstCommit) | Out-String).Trim()
  Assert-True ($trustedSubject -ceq 'first') 'Publish Git wrapper did not disable replace objects.'
  $trustedAttribute = (Invoke-PublishTrustedGit -Arguments @(
      'check-attr', 'contractattr', '--', 'probe.txt') | Out-String).Trim()
  Assert-True ($trustedAttribute -match 'contractattr:\s+unspecified$') 'Publish Git wrapper consulted hostile global attributes.'
  $null = Invoke-PublishTrustedGit -Arguments @('hash-object', '--path=probe.txt', 'probe.txt')
  $null = Invoke-PublishTrustedGit -Arguments @('status', '--porcelain=v1')
  foreach ($marker in @($hookMarker, $fsmonitorMarker, $lfsMarker)) {
    Assert-True (-not (Test-Path -LiteralPath $marker)) "Publish Git trust probe executed hostile external state: $marker"
  }

  . ([scriptblock]::Create($shareGitWrapper.Extent.Text))
  . ([scriptblock]::Create((Get-FunctionDefinition -Ast $shareAst -Name 'Invoke-GitText').Extent.Text))
  $script:shareGitExecutable = $gitExecutable
  $script:shareRepoRoot = $targetRepo
  $script:shareGitDisabledHooksPath = Join-Path $targetRepo 'disabled-share-hooks-must-not-exist'
  $script:shareNullAttributesPath = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }
  $shareHead = Invoke-GitText @('rev-parse', 'HEAD')
  Assert-True ($shareHead -match '^[0-9a-f]{40}$') 'Share pre-verifier trusted Git read did not return exact HEAD.'
  $shareSubject = (Invoke-ShareTrustedGit -Arguments @(
      'log', '-1', '--format=%s', $firstCommit) | Out-String).Trim()
  Assert-True ($shareSubject -ceq 'first') 'Share Git wrapper did not disable replace objects.'
  $null = Invoke-ShareTrustedGit -Arguments @('status', '--porcelain=v1')
  foreach ($marker in @($hookMarker, $fsmonitorMarker, $lfsMarker)) {
    Assert-True (-not (Test-Path -LiteralPath $marker)) "Share pre-verifier Git read executed hostile external state: $marker"
  }

  Set-Location $ambientRepo
  New-VerifiedReleaseTag -Tag 'contract-explicit-target' -Commit $firstCommit
  $tagCommit = (& $gitExecutable -C $targetRepo rev-list -n 1 contract-explicit-target).Trim().ToLowerInvariant()
  Assert-True ($tagCommit -ceq $firstCommit) 'Annotated tag did not target the explicit verified commit.'
  $ambientTag = & $gitExecutable -C $ambientRepo tag --list contract-explicit-target
  Assert-True ([string]::IsNullOrWhiteSpace(($ambientTag | Out-String).Trim())) 'Tag creation mutated the ambient repository instead of the exact repository.'
  $invalidTagRejected = $false
  try {
    New-VerifiedReleaseTag -Tag 'contract-invalid-target' -Commit ('0' * 40) 2>$null
  } catch {
    $invalidTagRejected = $true
  }
  Assert-True $invalidTagRejected 'Invalid explicit tag target was not rejected.'
  $invalidTag = & $gitExecutable -C $targetRepo tag --list contract-invalid-target
  Assert-True ([string]::IsNullOrWhiteSpace(($invalidTag | Out-String).Trim())) 'Failed explicit tag creation left a tag residue.'

  & $gitExecutable -C $targetRepo tag contract-lightweight $firstCommit
  $remoteRepo = Join-Path $fixtureRoot 'remote.git'
  & $gitExecutable init --bare -q $remoteRepo
  & $gitExecutable -C $targetRepo remote add contract-remote $remoteRepo
  Invoke-PublishTrustedGit -Arguments @(
    'push', '--quiet', 'contract-remote',
    'refs/tags/contract-explicit-target', 'refs/tags/contract-lightweight') 2>$null | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $hookMarker)) 'Hardened publication push executed the hostile pre-push hook.'
  . ([scriptblock]::Create((Get-FunctionDefinition -Ast $publishAst -Name 'Assert-RemoteTagPublishedAtCommit').Extent.Text))
  $remoteRefsBefore = (& $gitExecutable --git-dir=$remoteRepo show-ref | Sort-Object) -join "`n"
  Assert-RemoteTagPublishedAtCommit -Tag contract-explicit-target -Commit $firstCommit -Remote $remoteRepo
  Assert-RemoteTagPublishedAtCommit -Tag contract-lightweight -Commit $firstCommit -Remote $remoteRepo
  $wrongRemoteTargetRejected = $false
  try {
    Assert-RemoteTagPublishedAtCommit -Tag contract-explicit-target -Commit $secondCommit -Remote $remoteRepo
  } catch {
    $wrongRemoteTargetRejected = $true
  }
  Assert-True $wrongRemoteTargetRejected 'Remote annotated tag with the wrong peeled target was not rejected.'
  $remoteRefsAfter = (& $gitExecutable --git-dir=$remoteRepo show-ref | Sort-Object) -join "`n"
  Assert-True ($remoteRefsAfter -ceq $remoteRefsBefore) 'Remote tag verification mutated the remote fixture.'

  $fixtureTools = Join-Path $targetRepo 'tools'
  New-Item -ItemType Directory -Path $fixtureTools | Out-Null
  $fixturePublishPath = Join-Path $fixtureTools 'publish_release.ps1'
  $fixtureSharePath = Join-Path $fixtureTools 'share_release.ps1'
  Copy-Item -LiteralPath $publishPath -Destination $fixturePublishPath
  Copy-Item -LiteralPath $sharePath -Destination $fixtureSharePath
  $hostileDryVersion = 'hostile-dryrun-' + [guid]::NewGuid().ToString('N')
  $hostileReleaseRoot = Join-Path $targetRepo 'output/release'
  $hostilePackageRoot = Join-Path $hostileReleaseRoot $hostileDryVersion
  New-Item -ItemType Directory -Path $hostilePackageRoot -Force | Out-Null
  'hostile dry-run package fixture' | Set-Content -LiteralPath (Join-Path $hostilePackageRoot 'fixture.txt') -Encoding ASCII
  $hostileZip = Join-Path $hostileReleaseRoot "stackchan_alive_$hostileDryVersion.zip"
  $hostileSidecar = "$hostileZip.sha256"
  'hostile dry-run zip fixture' | Set-Content -LiteralPath $hostileZip -Encoding ASCII
  'hostile dry-run sidecar fixture' | Set-Content -LiteralPath $hostileSidecar -Encoding ASCII
  $hostileFilesBefore = @(
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $hostilePackageRoot 'fixture.txt'), $hostileZip, $hostileSidecar |
      ForEach-Object Hash
  )
  $hostileDryOutput = & $fixturePublishPath -Version $hostileDryVersion -CreateTag -DryRun *>&1
  Assert-True ($LASTEXITCODE -eq 0) "Hostile-config publish dry run failed: $(($hostileDryOutput | Out-String).Trim())"
  $hostileFilesAfter = @(
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $hostilePackageRoot 'fixture.txt'), $hostileZip, $hostileSidecar |
      ForEach-Object Hash
  )
  Assert-True ((Compare-Object $hostileFilesBefore $hostileFilesAfter).Count -eq 0) 'Hostile-config publish dry run mutated candidate files.'
  $hostileDryTag = & $gitExecutable -C $targetRepo tag --list $hostileDryVersion
  Assert-True ([string]::IsNullOrWhiteSpace(($hostileDryTag | Out-String).Trim())) 'Hostile-config publish dry run created a tag.'
  foreach ($marker in @($hookMarker, $fsmonitorMarker, $lfsMarker, $ghMarker)) {
    Assert-True (-not (Test-Path -LiteralPath $marker)) "Hostile-config publish dry run executed external state: $marker"
  }

  $shareFailure = $null
  try {
    & $fixtureSharePath -NoServe *>&1 | Out-Null
  } catch {
    $shareFailure = $_
  }
  Assert-True ($null -ne $shareFailure -and $shareFailure.Exception.Message -like 'Missing release ZIP:*') 'Hostile-config share fixture did not stop at the expected pre-verifier missing-ZIP gate.'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $targetRepo 'output/share'))) 'Share pre-verifier Git reads mutated persistent share state.'
  foreach ($marker in @($hookMarker, $fsmonitorMarker, $lfsMarker, $ghMarker)) {
    Assert-True (-not (Test-Path -LiteralPath $marker)) "Share pre-verifier Git reads executed external state: $marker"
  }

  $writeStopHelperText = (Get-FunctionDefinition -Ast $shareAst -Name 'Write-StopHelper').Extent.Text
  $quotedToolsRoot = "'" + $PSScriptRoot.Replace("'", "''") + "'"
  $writeStopHelperText = $writeStopHelperText.Replace('$PSScriptRoot', $quotedToolsRoot)
  . ([scriptblock]::Create($writeStopHelperText))
  $generatedShareRoot = Join-Path $fixtureRoot 'generated-share-helper'
  New-Item -ItemType Directory -Path $generatedShareRoot | Out-Null
  $shareRoot = $generatedShareRoot
  $script:sharePowerShellExecutable = $powerShellExecutable
  Write-StopHelper -ProcessIds @()
  $generatedStopHelper = Get-Content -LiteralPath (Join-Path $generatedShareRoot 'STOP_SHARING.cmd') -Raw
  $expectedPowerShellPrefix = "`"$powerShellExecutable`" -NoProfile -ExecutionPolicy Bypass -File `""
  Assert-True ($generatedStopHelper.IndexOf($expectedPowerShellPrefix, [System.StringComparison]::Ordinal) -ge 0) 'Generated STOP_SHARING.cmd does not invoke the exact quoted PowerShell application path.'
  Assert-True ($generatedStopHelper.IndexOf('-Command', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Generated STOP_SHARING.cmd must use -File, not an interpolated -Command payload.'
  Assert-True (-not (Test-Path -LiteralPath $powerShellMarker)) 'Generated stop-helper construction invoked ambient powershell.exe command resolution.'
} finally {
  Set-Location $originalLocation
  $env:PATH = $originalPath
  Remove-Item -Path 'Function:\global:powershell.exe' -ErrorAction SilentlyContinue
  Remove-Item Env:\STACKCHAN_PUBLICATION_POWERSHELL_MARKER -ErrorAction SilentlyContinue
  foreach ($candidate in @($dryPackageRoot, $dryZipPath, $drySidecarPath, $fixtureRoot)) {
    if (-not (Test-Path -LiteralPath $candidate)) {
      continue
    }
    $resolvedCandidate = [System.IO.Path]::GetFullPath($candidate)
    $resolvedFixtureRoot = [System.IO.Path]::GetFullPath($fixtureRoot)
    $resolvedReleaseRoot = [System.IO.Path]::GetFullPath($releaseRoot).TrimEnd('\', '/')
    $isFixture = $resolvedCandidate.StartsWith($resolvedFixtureRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $isExactDryCandidate = $resolvedCandidate -ceq [System.IO.Path]::GetFullPath($dryPackageRoot) -or
      $resolvedCandidate -ceq [System.IO.Path]::GetFullPath($dryZipPath) -or
      $resolvedCandidate -ceq [System.IO.Path]::GetFullPath($drySidecarPath)
    if (-not $isFixture -and -not $isExactDryCandidate -and
        -not $resolvedCandidate.StartsWith($resolvedReleaseRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing unsafe publication-contract cleanup: $resolvedCandidate"
    }
    Remove-Item -LiteralPath $resolvedCandidate -Recurse -Force
  }
}

Write-Host 'Release publication safety contract tests passed.'
