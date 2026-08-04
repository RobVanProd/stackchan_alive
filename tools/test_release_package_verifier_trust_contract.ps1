param(
  [string]$BehaviorFixtureRoot
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$packagePath = Join-Path $PSScriptRoot "package_release.ps1"
$verifyPath = Join-Path $PSScriptRoot "verify_release_package.ps1"
$packageText = Get-Content -LiteralPath $packagePath -Raw
$verifyText = Get-Content -LiteralPath $verifyPath -Raw
if ($verifyText.Contains('Release package verified:') -or
    -not $verifyText.Contains(
      'Package integrity verified in non-authorizing mode; release eligibility not established:')) {
  throw 'Non-authorizing package verification still uses release-authorizing success wording'
}
$zipSafetyPath = Join-Path $PSScriptRoot 'release_zip_safety.ps1'
$gitTrustPath = Join-Path $PSScriptRoot 'release_git_trust.ps1'
$selectorPolicyPath = Join-Path $PSScriptRoot 'release_ota_selector_policy.ps1'
$zipSafetyText = Get-Content -LiteralPath $zipSafetyPath -Raw
$gitTrustText = Get-Content -LiteralPath $gitTrustPath -Raw
$selectorPolicyText = Get-Content -LiteralPath $selectorPolicyPath -Raw

function Test-WithinFunctionDefinition {
  param([System.Management.Automation.Language.Ast]$Ast)

  $parent = $Ast.Parent
  while ($null -ne $parent) {
    if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      return $true
    }
    $parent = $parent.Parent
  }
  return $false
}

function Get-NearestStatementBlock {
  param([System.Management.Automation.Language.Ast]$Ast)

  $parent = $Ast
  while ($null -ne $parent -and
      $parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and
      $parent -isnot [System.Management.Automation.Language.NamedBlockAst]) {
    $parent = $parent.Parent
  }
  return $parent
}

function Test-DirectCommandParameter {
  param(
    [System.Management.Automation.Language.CommandAst]$Command,
    [string]$Name
  )

  return @($Command.CommandElements | Where-Object {
    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
      $_.ParameterName -ceq $Name
  }).Count -eq 1
}

function Test-DirectArrayString {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Value
  )

  $node = $Ast
  if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
    $node = $node.Expression
  }
  if ($node -isnot [System.Management.Automation.Language.ArrayExpressionAst]) {
    return $false
  }
  $statements = @($node.SubExpression.Statements)
  if ($statements.Count -ne 1 -or
      $statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
      $statements[0].PipelineElements.Count -ne 1 -or
      $statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
    return $false
  }
  $arrayLiteral = $statements[0].PipelineElements[0].Expression
  if ($arrayLiteral -isnot [System.Management.Automation.Language.ArrayLiteralAst]) {
    return $false
  }
  return @($arrayLiteral.Elements | Where-Object {
    $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $_.Value -ceq $Value
  }).Count -eq 1
}

function Get-DirectStringArrayValues {
  param([System.Management.Automation.Language.Ast]$Ast)

  $node = $Ast
  if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
    $node = $node.Expression
  }
  if ($node -isnot [System.Management.Automation.Language.ArrayExpressionAst]) {
    return $null
  }
  $statements = @($node.SubExpression.Statements)
  if ($statements.Count -ne 1 -or
      $statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
      $statements[0].PipelineElements.Count -ne 1 -or
      $statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
    return $null
  }
  $arrayLiteral = $statements[0].PipelineElements[0].Expression
  if ($arrayLiteral -isnot [System.Management.Automation.Language.ArrayLiteralAst] -or
      @($arrayLiteral.Elements | Where-Object {
        $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst]
      }).Count -ne 0) {
    return $null
  }
  return @($arrayLiteral.Elements | ForEach-Object { [string]$_.Value })
}

function Read-OperationalScriptAst {
  param([string]$RelativePath)

  $path = Join-Path $PSScriptRoot $RelativePath
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) {
    throw "Operational verifier caller does not parse: $RelativePath"
  }
  return $ast
}

function Assert-NoPreVerifierHelperLoad {
  param(
    [string]$RelativePath,
    [System.Management.Automation.Language.ScriptBlockAst]$Ast,
    [System.Management.Automation.Language.CommandAst[]]$VerifierInvocations
  )

  if ($VerifierInvocations.Count -eq 0) {
    throw "Operational verifier caller has no reachable verifier invocation: $RelativePath"
  }
  $firstVerifierOffset = [int](@($VerifierInvocations |
      Sort-Object { $_.Extent.StartOffset })[0].Extent.StartOffset)
  $preVerifierHelperLoads = @($Ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
        $node.Extent.StartOffset -ge $firstVerifierOffset -or
        (Test-WithinFunctionDefinition -Ast $node)) {
      return $false
    }
    if ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
      return $true
    }
    $text = $node.Extent.Text
    if ($text -notmatch '(?i)\.ps1(?:["'']|\s|\)|$)' -or
        $text -notmatch '\$PSScriptRoot') {
      return $false
    }
    $commandName = [string]$node.GetCommandName()
    return ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -or
      $commandName -match '^(?i:powershell(?:\.exe)?|pwsh(?:\.exe)?)$')
  }, $true))
  if ($preVerifierHelperLoads.Count -ne 0) {
    throw "Operational caller loads or executes a local helper before package eligibility: $RelativePath :: $($preVerifierHelperLoads[0].Extent.Text)"
  }
}

function Assert-NoPreVerifierSideEffects {
  param(
    [string]$RelativePath,
    [System.Management.Automation.Language.ScriptBlockAst]$Ast,
    [System.Management.Automation.Language.CommandAst]$FirstVerifier
  )

  $mutatingCommands = @(
    'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item',
    'Copy-Item', 'Move-Item', 'Rename-Item', 'Compress-Archive', 'Expand-Archive',
    'Start-Process', 'Start-Job', 'Invoke-WebRequest', 'Invoke-RestMethod'
  )
  $reachableMutations = @($Ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
        $node.Extent.StartOffset -ge $FirstVerifier.Extent.StartOffset -or
        (Test-WithinFunctionDefinition -Ast $node)) {
      return $false
    }
    $commandName = [string]$node.GetCommandName()
    if ($mutatingCommands -contains $commandName) {
      return $true
    }
    if ($commandName -ceq 'git') {
      $arguments = @($node.CommandElements | Select-Object -Skip 1 |
        ForEach-Object { $_.Extent.Text.Trim('"', "'") })
      return @($arguments | Where-Object {
        $_ -in @('tag', 'push', 'branch', 'checkout', 'switch', 'reset', 'worktree')
      }).Count -gt 0
    }
    if ($commandName -ceq 'gh') {
      return $node.Extent.Text -match '(?i)\b(release|pr)\s+(create|upload|edit|delete|close|merge)\b'
    }
    return $false
  }, $true))
  if ($reachableMutations.Count -ne 0) {
    throw "Release $RelativePath performs a side effect before package eligibility: $($reachableMutations[0].Extent.Text)"
  }

  $reachableMethodMutations = @($Ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Extent.StartOffset -lt $FirstVerifier.Extent.StartOffset -and
      -not (Test-WithinFunctionDefinition -Ast $node) -and
      $node.Member.Extent.Text -match '^(?i:WriteAllText|WriteAllBytes|Create|CreateDirectory|Delete|Move|Copy|Replace)$'
  }, $true))
  if ($reachableMethodMutations.Count -ne 0) {
    throw "Release $RelativePath invokes a mutating method before package eligibility: $($reachableMethodMutations[0].Extent.Text)"
  }

  $localFunctions = @{}
  foreach ($functionAst in @($Ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
  }, $true))) {
    $localFunctions[$functionAst.Name] = $functionAst
  }
  $preVerifierCommands = @($Ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
      $node.Extent.StartOffset -lt $FirstVerifier.Extent.StartOffset -and
      -not (Test-WithinFunctionDefinition -Ast $node)
  }, $true))
  $pendingFunctions = New-Object 'System.Collections.Generic.Queue[string]'
  foreach ($command in $preVerifierCommands) {
    $commandName = [string]$command.GetCommandName()
    if ($localFunctions.ContainsKey($commandName)) {
      $pendingFunctions.Enqueue($commandName)
    }
  }
  $visitedFunctions = @{}
  while ($pendingFunctions.Count -gt 0) {
    $functionName = $pendingFunctions.Dequeue()
    if ($visitedFunctions.ContainsKey($functionName)) { continue }
    $visitedFunctions[$functionName] = $true
    $functionAst = $localFunctions[$functionName]
    $functionCommands = @($functionAst.Body.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $functionCommands) {
      $commandName = [string]$command.GetCommandName()
      if ($mutatingCommands -contains $commandName -or
          $commandName -in @('Invoke-Expression', 'Import-Module') -or
          ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot)) {
        throw "Release $RelativePath reaches a side-effecting helper before package eligibility: $functionName :: $($command.Extent.Text)"
      }
      if ($localFunctions.ContainsKey($commandName) -and
          -not $visitedFunctions.ContainsKey($commandName)) {
        $pendingFunctions.Enqueue($commandName)
      }
    }
    $functionMethodMutations = @($functionAst.Body.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Extent.Text -match '^(?i:WriteAllText|WriteAllBytes|Create|CreateDirectory|Delete|Move|Copy|Replace)$'
    }, $true))
    if ($functionMethodMutations.Count -ne 0) {
      throw "Release $RelativePath reaches a mutating helper method before package eligibility: $functionName :: $($functionMethodMutations[0].Extent.Text)"
    }
  }
}

foreach ($forbidden in @(
  '. (Join-PackagePath',
  '& (Join-PackagePath',
  '-File (Join-PackagePath'
)) {
  if ($verifyText.Contains($forbidden)) {
    throw "Verifier trust contract found package-controlled code execution: $forbidden"
  }
}
foreach ($required in @(
  '. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")',
  'ast.parse(',
  '$bridgeRuntimePython -I -B -c $bridgeRuntimeAstCheck',
  '(Join-Path $PSScriptRoot "verify_voice_samples.ps1")',
  '(Join-Path $PSScriptRoot "verify_release_asset_contract.ps1")',
  'Expand-StackchanReleaseZipSafely -ZipPath $ZipPath -DestinationPath $cleanupDir',
  'Assert-ReleaseZipSidecar -LiteralZipPath $ZipPath',
  'Release ZIP SHA-256 sidecar mismatch',
  'Refusing unsafe package-relative path',
  'Operational release verification requires a clean trusted checkout',
  'Release verification refuses ambient Git overrides',
  'Assert-SafeReleaseVersionLeaf'
)) {
  if (-not $verifyText.Contains($required)) {
    throw "Verifier trust contract is missing: $required"
  }
}
$manifestLoadOffset = $verifyText.LastIndexOf(
  '$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json',
  [System.StringComparison]::Ordinal)
$operationalBindingOffset = if ($manifestLoadOffset -ge 0) {
  $verifyText.IndexOf(
    'Assert-OperationalPackageGitBindings -Manifest $manifest',
    $manifestLoadOffset,
    [System.StringComparison]::Ordinal)
} else { -1 }
$firstPackageHelperOffset = $verifyText.IndexOf(
  '& (Join-Path $PSScriptRoot "verify_voice_samples.ps1")',
  [System.StringComparison]::Ordinal)
if ($manifestLoadOffset -lt 0 -or $operationalBindingOffset -le $manifestLoadOffset -or
    $firstPackageHelperOffset -le $operationalBindingOffset) {
  throw 'Operational package Git binding must authenticate packaged helper bytes before their first execution.'
}
$verifyTokens = $null
$verifyParseErrors = $null
$verifyAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $verifyPath, [ref]$verifyTokens, [ref]$verifyParseErrors)
$packageTokens = $null
$packageParseErrors = $null
$packageAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $packagePath, [ref]$packageTokens, [ref]$packageParseErrors)
if ($verifyParseErrors.Count -ne 0 -or $packageParseErrors.Count -ne 0) {
  throw 'Verifier trust contract could not parse the package/verifier scripts'
}
$sidecarCalls = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.GetCommandName() -ceq 'Assert-ReleaseZipSidecar'
}, $true))
$zipExpansionCalls = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.GetCommandName() -ceq 'Expand-StackchanReleaseZipSafely'
}, $true))
if ($sidecarCalls.Count -ne 1 -or $zipExpansionCalls.Count -ne 1 -or
    $sidecarCalls[0].Extent.EndOffset -ge $zipExpansionCalls[0].Extent.StartOffset) {
  throw 'Release ZIP sidecar verification must occur exactly once before ZIP extraction.'
}
function Assert-ClosedPackageInventoryGovernanceText {
  param([Parameter(Mandatory = $true)][string]$Text)
  foreach ($marker in @(
    "'ls-tree', '-r', `$ExpectedCommit",
    "'ls-files', '-v'",
    "[string]`$CommitMaps.indexStates[`$sourcePath] -cne 'H'",
    '$workingBlob -cne $trustedBlob',
    'tools inventory does not equal the trusted commit-side packaging policy',
    'provenance inventory does not equal the trusted commit-side packaging policy',
    '$actualPackageFiles.Count -ne $allowedPackageFiles.Count',
    '-not $allowedPackageFiles.Contains([string]$path)',
    'root file outside the trusted packaging policy',
    'file outside the trusted copy-tree policy'
  )) {
    if (-not $Text.Contains($marker)) {
      throw "Closed package-inventory governance is missing: $marker"
    }
  }
}
Assert-ClosedPackageInventoryGovernanceText -Text $verifyText
foreach ($canary in @(
  [pscustomobject]@{ label = 'hidden operational caller'; marker = "[string]`$CommitMaps.indexStates[`$sourcePath] -cne 'H'" },
  [pscustomobject]@{ label = 'modified source twin'; marker = '$workingBlob -cne $trustedBlob' },
  [pscustomobject]@{ label = 'whole-package deletion'; marker = '$actualPackageFiles.Count -ne $allowedPackageFiles.Count' },
  [pscustomobject]@{ label = 'whole-package extra'; marker = '-not $allowedPackageFiles.Contains([string]$path)' }
)) {
  $mutatedGovernance = $verifyText.Replace([string]$canary.marker, '')
  try {
    Assert-ClosedPackageInventoryGovernanceText -Text $mutatedGovernance
    throw "Inventory governance mutation canary survived: $($canary.label)"
  } catch {
    if ($_.Exception.Message -like 'Inventory governance mutation canary survived:*') { throw }
  }
}
$releaseEligibleIfStatements = @($verifyAst.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and
    $_.Clauses[0].Item1.Extent.Text -eq '$RequireReleaseEligible'
})
$releaseFrontDoorGates = @($releaseEligibleIfStatements | Where-Object {
  $_.Extent.Text.Contains('requiredToolchainArguments') -and
    $_.Extent.Text.Contains('Assert-StackchanReleaseToolchainIdentity') -and
    $_.Extent.Text.Contains('pre-Git byte authority mismatch')
})
$releaseEligibilityGates = @($releaseEligibleIfStatements | Where-Object {
  $_.Extent.Text.Contains(
    'Operational release verification must run from the trusted checkout tools directory.')
})
if ($releaseFrontDoorGates.Count -ne 1 -or
    $releaseFrontDoorGates[0].Extent.EndOffset -ge
      $verifyText.IndexOf('$trustedGitDisabledHooksPath = Join-Path', [StringComparison]::Ordinal)) {
  throw 'Operational verifier must authenticate exact toolchain bytes before trusted Git setup'
}
if ($releaseEligibilityGates.Count -ne 1) {
  throw 'Operational verifier must contain exactly one top-level trusted checkout gate'
}
$releaseEligibilityGate = $releaseEligibilityGates[0]
$cleanupAssignments = @($verifyAst.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -eq '$cleanupDir' -and
    $_.Right.Extent.Text -eq '$null'
})
if ($cleanupAssignments.Count -ne 1) {
  throw 'Operational verifier cleanup boundary is ambiguous'
}
$preGateCodeCommands = @($verifyAst.FindAll({
  param($node)
  if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
      $node.Extent.StartOffset -ge $releaseEligibilityGate.Extent.EndOffset) {
    return $false
  }
  $commandName = [string]$node.GetCommandName()
  if ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
    return $node.Extent.Text -cne '. $identityHelperPath'
  }
  if ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand) {
    return $node.Extent.Text -cne '& $script:trustedGitExecutable @gitArguments'
  }
  if ($commandName -match '(?i)\.ps1$' -or
      $commandName -in @('Invoke-Expression', 'Import-Module') -or
      $commandName -match '^(?i:powershell(?:\.exe)?|pwsh(?:\.exe)?)$') {
    return $true
  }
  return $false
}, $true))
if ($preGateCodeCommands.Count -ne 0) {
  throw "Operational verifier can load or execute code before its trusted checkout gate: $($preGateCodeCommands[0].Extent.Text)"
}
foreach ($helper in @(
  'firmware_reproducibility_proof.ps1',
  'release_zip_safety.ps1',
  'release_dependency_evidence.ps1',
  'release_source_binding.ps1',
  'release_git_trust.ps1',
  'platformio_resolver.ps1'
)) {
  $expectedLoad = '. (Join-Path $PSScriptRoot "' + $helper + '")'
  $helperLoads = @($verifyAst.EndBlock.Statements | Where-Object {
    $_.Extent.Text -eq $expectedLoad
  })
  if ($helperLoads.Count -ne 1 -or
      $helperLoads[0].Extent.StartOffset -le $releaseEligibilityGate.Extent.EndOffset -or
      $helperLoads[0].Extent.EndOffset -ge $cleanupAssignments[0].Extent.StartOffset) {
    throw "Operational verifier loads $helper before its trusted checkout gate"
  }
}
$previewResolverLoad = @($verifyAst.EndBlock.Statements | Where-Object {
  $_.Extent.Text -eq '. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")'
})
if ($previewResolverLoad.Count -ne 1 -or
    $previewResolverLoad[0].Extent.StartOffset -le $releaseEligibilityGate.Extent.EndOffset) {
  throw 'Operational verifier preview resolver is not uniquely loaded after its trusted bootstrap gate.'
}
$bootstrapGitFunctions = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Invoke-TrustedVerifierGit'
}, $true))
if ($bootstrapGitFunctions.Count -ne 1) {
  throw 'Operational verifier trusted Git bootstrap is ambiguous'
}
$canonicalBlobHashFunctions = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-CanonicalGitBlobHash'
}, $true))
$earlyDiagnosticGates = @($verifyAst.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and
    $_.Clauses[0].Item1.Extent.Text -ceq
      'Test-Path -LiteralPath $eligibilityManifestPath -PathType Leaf' -and
    $_.Extent.Text.Contains('Operational release verification refuses diagnostic packages.')
})
if ($canonicalBlobHashFunctions.Count -ne 1 -or $earlyDiagnosticGates.Count -ne 1) {
  throw 'Operational verifier checkout-gate harness inputs are ambiguous'
}
$bootstrapGitText = $bootstrapGitFunctions[0].Extent.Text
foreach ($requiredBootstrap in @(
  'core.hooksPath=',
  'core.fsmonitor=false',
  'core.untrackedCache=false',
  'core.useBuiltinFSMonitor=false',
  'maintenance.auto=false',
  'GIT_NO_REPLACE_OBJECTS',
  '& $script:trustedGitExecutable @gitArguments'
)) {
  if (-not $bootstrapGitText.Contains($requiredBootstrap)) {
    throw "Operational verifier trusted Git bootstrap is missing: $requiredBootstrap"
  }
}
if ($bootstrapGitText.Contains('Invoke-StackchanTrustedGit')) {
  throw 'Operational verifier trusted Git bootstrap depends on a pre-gate local helper'
}
foreach ($gitBootstrapMarker in @(
  'Get-Command -Name git -CommandType Application',
  '$trustedGitExecutable = (Resolve-Path -LiteralPath ([string]$trustedGitCommand.Source)).Path'
)) {
  if (-not $verifyText.Contains($gitBootstrapMarker)) {
    throw "Operational verifier does not bootstrap-bind the Git application: $gitBootstrapMarker"
  }
}

$operationalRebuildFunctions = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-OperationalFirmwareMatchesTrustedRebuild'
}, $true))
if ($operationalRebuildFunctions.Count -ne 1) {
  throw 'Operational verifier independent-rebuild function is ambiguous'
}
$operationalRebuild = $operationalRebuildFunctions[0]
$operationalRebuildText = $operationalRebuild.Extent.Text
$expectedOperationalArtifacts = @(
  'firmware.bin', 'firmware.elf', 'bootloader.bin', 'partitions.bin', 'boot_app0.bin'
)
$operationalArtifactArrays = @($operationalRebuild.FindAll({
  param($node)
  if ($node -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return $false }
  $values = @(Get-DirectStringArrayValues -Ast $node)
  return ($values.Count -eq 5 -and $values -contains 'firmware.bin')
}, $true))
if ($operationalArtifactArrays.Count -ne 1) {
  throw 'Operational rebuild must define one exact fresh-build artifact inventory'
}
foreach ($artifactArray in $operationalArtifactArrays) {
  $values = @(Get-DirectStringArrayValues -Ast $artifactArray)
  if ((Compare-Object -ReferenceObject $expectedOperationalArtifacts `
      -DifferenceObject $values -CaseSensitive).Count -ne 0) {
    throw "Operational rebuild artifact inventory is not the exact five-file set: $($values -join ', ')"
  }
}

foreach ($requiredRebuildMarker in @(
  "[ordered]@{ environment = 'stackchan'; packageDir = 'display_only'; coreDir = `$defaultCoreDir }",
  "[ordered]@{ environment = 'stackchan_servo_calibration'; packageDir = 'servo_calibration'; coreDir = `$defaultCoreDir }",
  "[ordered]@{ environment = 'stackchan_release_full'; packageDir = 'full_online'; coreDir = `$releaseCoreDir }",
  '`$packageRelative = "firmware/`$([string]`$spec.packageDir)/`$artifact"',
  'Assert-StackchanReleaseFrameworkOtaSelector',
  'Get-StackchanReleaseOtaSelectorPolicy',
  'Two-cycle proof does not match reviewed OTA selector authority:',
  '`$pioExecutable = `$resolvedPlatformioExecutable',
  "`$pioVersion -cne 'PlatformIO Core, version 6.1.19'",
  '[string]$dependencyLock.platformioCore -cne $pioVersion',
  "@(& `$pioExecutable 'pkg' 'list' '-d' `$rebuildWorktree '-e' `$environment 2>&1)",
  'Compare-Object -ReferenceObject $expectedDependencyIdentity',
  '-DifferenceObject $actualDependencyIdentity -CaseSensitive',
  'Get-StackchanVerbosePlatformSource',
  '[string]$spec.coreDir',
  '[string]$expectedEnvironmentLock.platformSourceLeaf',
  "@(& `$pioExecutable 'pkg' 'install' '-d' `$rebuildWorktree '-e' `$environment 2>&1)",
  'Assert-StackchanReleaseToolchainIdentity',
  '-Phase PostBuild -Environment $environment',
  'Assert-StackchanReleaseBuildPythonEnvironment'
)) {
  $marker = $requiredRebuildMarker.Replace('`$', '$')
  if (-not $operationalRebuildText.Contains($marker)) {
    throw "Operational rebuild contract is missing: $marker"
  }
}

$evidenceParentAssignments = @($operationalRebuild.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$rebuildEvidenceParent'
}, $true))
$rebuildIdAssignments = @($operationalRebuild.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$rebuildId'
}, $true))
if ($evidenceParentAssignments.Count -ne 1 -or $rebuildIdAssignments.Count -ne 1 -or
    $evidenceParentAssignments[0].Right.Extent.Text.Contains('$Version') -or
    $rebuildIdAssignments[0].Right.Extent.Text.Contains('$Version')) {
  throw 'Operational rebuild evidence paths must not include the package Version value'
}

foreach ($evidenceField in @(
  'packageChecksumsSha256 = $packageChecksumsSha256',
  'dependencyLockSha256 = $dependencyLockSha256',
  'sourceCommit = $ExpectedCommit',
  'sourceEpoch = $ExpectedSourceEpoch',
  'platformioExecutable = $pioExecutable',
  'platformioExecutableSha256 = $pioExecutableSha256',
  'platformioVersion = $pioVersion',
  'defaultPlatformioCore = $defaultCoreDir',
  'releasePlatformioCore = $releaseCoreDir',
  'toolchainIdentity = [ordered]@{',
  'allowlistSha256 = $verifierToolchainAllowlistSha256',
  'preExecution = @($script:verifierToolchainIdentityRecords',
  'postBuild = @($script:verifierToolchainIdentityRecords',
  'records = @($rebuildRecords)'
)) {
  if (-not $operationalRebuildText.Contains($evidenceField)) {
    throw "Operational rebuild evidence is not strongly identity-bound: $evidenceField"
  }
}
foreach ($forbiddenCacheMarker in @(
  'attestationKey', 'cachedAttestation', 'attestationRoot',
  'operational-firmware-rebuild-cache', 'attestation reused'
)) {
  if ($operationalRebuildText.Contains($forbiddenCacheMarker)) {
    throw "Operational verifier must perform a fresh rebuild instead of trusting ignored-output cache state: $forbiddenCacheMarker"
  }
}
$operationalReturns = @($operationalRebuild.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.ReturnStatementAst]
}, $true))
if ($operationalReturns.Count -ne 1 -or
    -not $operationalRebuildText.Contains('if (-not $RequireReleaseEligible) { return }')) {
  throw 'Operational rebuild must not contain a release-eligible cache short-circuit'
}
foreach ($failureProbeMarker in @(
  '$worktreePathExists = Test-Path -LiteralPath $rebuildWorktree -PathType Container',
  "'worktree', 'list', '--porcelain'",
  '$_ -ceq "worktree $rebuildWorktree"',
  '$worktreePreserved = $worktreePathExists -and $worktreeAttached',
  "status = if (`$worktreePreserved) { 'failed-full-worktree-preserved' } else { 'failed-worktree-not-preserved' }"
)) {
  if (-not $operationalRebuildText.Contains($failureProbeMarker)) {
    throw "Operational rebuild failure status is not derived from actual worktree probes: $failureProbeMarker"
  }
}
$publicVerifierGuards = @($packageAst.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and $_.Clauses[0].Item1.Extent.Text -eq '-not $SkipBuild' -and
    $_.Extent.Text.Contains("'-RequireReleaseEligible'") -and
    $_.Extent.Text.Contains("'-ToolchainAllowlistPath'") -and
    $_.Extent.Text.Contains("'-GitExecutable'")
})
$publicVerifierGuardStatements = if ($publicVerifierGuards.Count -eq 1) {
  @($publicVerifierGuards[0].Clauses[0].Item2.Statements)
} else { @() }
$publicVerifierRequireAppends = @($publicVerifierGuardStatements | Where-Object {
  $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -eq '$packageVerifyArgs' -and
    $_.Operator -eq [System.Management.Automation.Language.TokenKind]::PlusEquals -and
    $_.Right.Extent.Text.Contains("'-RequireReleaseEligible'") -and
    $_.Right.Extent.Text.Contains("'-ToolchainAllowlistPath'") -and
    $_.Right.Extent.Text.Contains("'-ReleaseCoreDir'")
})
$publicVerifierArgumentAssignments = @($packageAst.EndBlock.Statements | Where-Object {
  $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -ceq '$packageVerifyArgs' -and
    $_.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals
})
$publicVerifierInvocations = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    @($node.CommandElements | Where-Object {
      $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Splatted -and $_.VariablePath.UserPath -ceq 'packageVerifyArgs'
    }).Count -eq 1
}, $true))
if ($publicVerifierArgumentAssignments.Count -ne 1 -or
    $publicVerifierInvocations.Count -ne 1 -or
    $publicVerifierGuards.Count -ne 1 -or
    $publicVerifierGuardStatements.Count -ne 1 -or
    $publicVerifierRequireAppends.Count -ne 1 -or
    $publicVerifierGuards[0].Extent.StartOffset -le $publicVerifierArgumentAssignments[0].Extent.EndOffset -or
    $publicVerifierInvocations[0].Extent.StartOffset -le $publicVerifierGuards[0].Extent.EndOffset) {
  throw 'Release-grade package verification does not conditionally require operational eligibility'
}
foreach ($required in @(
  'Release ZIP contains an unsafe, duplicate, or link entry',
  'Release ZIP exceeds the bounded extraction budget',
  'FileMode]::CreateNew',
  'Expand-StackchanReleaseZipSafely'
)) {
  if (-not $zipSafetyText.Contains($required)) {
    throw "Release ZIP safety contract is missing: $required"
  }
}
foreach ($required in @(
  'core.hooksPath=',
  'core.fsmonitor=false',
  'core.untrackedCache=false',
  'GIT_NO_REPLACE_OBJECTS'
)) {
  if (-not $gitTrustText.Contains($required)) {
    throw "Trusted Git contract is missing: $required"
  }
}
foreach ($required in @(
  'stackchan.release-ota-selector-policy.v1',
  '3.20017.241212+sha.dcc1105b',
  '3.3.6',
  'tools/partitions/boot_app0.bin',
  'F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0',
  'ReparsePoint',
  'FileShare]::Read'
)) {
  if (-not $selectorPolicyText.Contains($required)) {
    throw "Release OTA selector authority contract is missing: $required"
  }
}
foreach ($relative in @(
  'verify_release_package.ps1',
  'verify_consumer_promotion.ps1',
  'flash_release_firmware.ps1',
  'prepare_device_arrival.ps1',
  'export_rollout_status.ps1',
  'start_hardware_evidence.ps1',
  'generate_synthetic_hardware_evidence.ps1'
)) {
  $operationalText = Get-Content -LiteralPath (Join-Path $PSScriptRoot $relative) -Raw
  if ($operationalText.Contains('Expand-Archive')) {
    throw "Release ZIP consumer still uses raw Expand-Archive: $relative"
  }
  if ($relative -ne 'verify_release_package.ps1' -and
      $operationalText.Contains('Expand-StackchanReleaseZipSafely') -and
      -not $operationalText.Contains('release_zip_safety.ps1')) {
    throw "Release ZIP consumer does not load the trusted safe extractor: $relative"
  }
}
$operationalAsts = @{}
$operationalTexts = @{}
$operationalInvocations = @{}
$directEligibilitySpecs = @(
  [pscustomobject]@{ file = 'prepare_device_arrival.ps1'; kind = 'variable'; variable = 'verifyScript'; count = 4 },
  [pscustomobject]@{ file = 'verify_consumer_promotion.ps1'; kind = 'file-variable'; variable = 'verifyPackage'; count = 2 },
  [pscustomobject]@{ file = 'verify_published_release.ps1'; kind = 'source-any-paren'; variable = ''; count = 3 },
  [pscustomobject]@{ file = 'run_device_preflight.ps1'; kind = 'variable'; variable = 'verifyScript'; count = 2 },
  [pscustomobject]@{ file = 'start_bridge_ai_supervised_qualification.ps1'; kind = 'source-file-paren'; variable = ''; count = 1 }
)
foreach ($spec in $directEligibilitySpecs) {
  $ast = Read-OperationalScriptAst -RelativePath $spec.file
  $operationalAsts[$spec.file] = $ast
  $operationalTexts[$spec.file] = Get-Content -LiteralPath (Join-Path $PSScriptRoot $spec.file) -Raw
  $commands = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
      -not (Test-WithinFunctionDefinition -Ast $node)
  }, $true))
  $invocations = @($commands | Where-Object {
    $command = $_
    $elements = @($command.CommandElements)
    switch ([string]$spec.kind) {
      'variable' {
        return ($elements.Count -gt 0 -and
          $elements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
          $elements[0].VariablePath.UserPath -ceq [string]$spec.variable)
      }
      'file-variable' {
        return ($command.GetCommandName() -match '^(?i:powershell(?:\.exe)?|pwsh(?:\.exe)?)$' -and
          @($elements | Where-Object {
            $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
              $_.VariablePath.UserPath -ceq [string]$spec.variable
          }).Count -eq 1)
      }
      'source-paren' {
        return ($elements.Count -gt 0 -and
          $elements[0] -is [System.Management.Automation.Language.ParenExpressionAst] -and
          $elements[0].Extent.Text -match 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']')
      }
      'source-file-paren' {
        return ($command.GetCommandName() -match '^(?i:powershell(?:\.exe)?|pwsh(?:\.exe)?)$' -and
          @($elements | Where-Object {
            $_ -is [System.Management.Automation.Language.ParenExpressionAst] -and
              $_.Extent.Text -match 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']'
          }).Count -eq 1)
      }
      'source-any-paren' {
        return (@($elements | Where-Object {
          $_ -is [System.Management.Automation.Language.ParenExpressionAst] -and
            $_.Extent.Text -match 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']'
        }).Count -eq 1)
      }
    }
    return $false
  })
  if ($invocations.Count -ne [int]$spec.count) {
    throw "Operational verifier invocation structure is ambiguous in $($spec.file): expected $($spec.count), got $($invocations.Count)"
  }
  foreach ($invocation in $invocations) {
    if (-not (Test-DirectCommandParameter -Command $invocation -Name 'RequireReleaseEligible')) {
      throw "Operational verifier invocation lacks a direct eligibility switch in $($spec.file): $($invocation.Extent.Text)"
    }
    if ($spec.kind -eq 'file-variable') {
      $block = Get-NearestStatementBlock -Ast $invocation
      $pathAssignments = @($block.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
          $node.Left.Extent.Text -ceq ('$' + [string]$spec.variable) -and
          $node.Extent.StartOffset -lt $invocation.Extent.StartOffset -and
          (Get-NearestStatementBlock -Ast $node) -eq $block
      }, $true))
      if ($pathAssignments.Count -ne 1 -or
          $pathAssignments[0].Right.Extent.Text -notmatch 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']') {
        throw "Operational verifier path is not directly bound in the invocation block: $($spec.file)"
      }
    }
  }
  $priorInvocations = if ($operationalInvocations.ContainsKey($spec.file)) {
    @($operationalInvocations[$spec.file])
  } else { @() }
  $operationalInvocations[$spec.file] = @(@($priorInvocations) + @($invocations))
}

$arrayEligibilitySpecs = @(
  [pscustomobject]@{ file = 'flash_release_firmware.ps1'; variable = 'verifyArgs'; command = 'powershell.exe'; count = 1 },
  [pscustomobject]@{ file = 'flash_release_firmware.ps1'; variable = 'snapshotVerifyArgs'; command = 'powershell.exe'; count = 1 },
  [pscustomobject]@{ file = 'start_hardware_evidence.ps1'; variable = 'verifyArgs'; command = 'powershell.exe'; count = 2 },
  [pscustomobject]@{ file = 'run_device_preflight.ps1'; variable = 'earlyVerifyArgs'; command = 'powershell.exe'; count = 1 },
  [pscustomobject]@{ file = 'export_rollout_status.ps1'; variable = 'packageVerifyArguments'; command = 'Invoke-ToolCapture'; count = 1 }
)
foreach ($spec in $arrayEligibilitySpecs) {
  $ast = Read-OperationalScriptAst -RelativePath $spec.file
  $operationalAsts[$spec.file] = $ast
  $operationalTexts[$spec.file] = Get-Content -LiteralPath (Join-Path $PSScriptRoot $spec.file) -Raw
  $invocations = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
      -not (Test-WithinFunctionDefinition -Ast $node) -and
      $node.GetCommandName() -ceq [string]$spec.command -and
      @($node.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
          $_.VariablePath.UserPath -ceq [string]$spec.variable
      }).Count -eq 1
  }, $true))
  if ($invocations.Count -ne [int]$spec.count) {
    throw "Operational verifier argument-array invocation is ambiguous in $($spec.file): expected $($spec.count), got $($invocations.Count)"
  }
  foreach ($invocation in $invocations) {
    $assignments = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq ('$' + [string]$spec.variable) -and
        $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
        $node.Extent.StartOffset -lt $invocation.Extent.StartOffset
    }, $true) | Where-Object {
      $assignmentBlock = Get-NearestStatementBlock -Ast $_
      $null -ne $assignmentBlock -and
        $assignmentBlock.Extent.StartOffset -le $invocation.Extent.StartOffset -and
        $assignmentBlock.Extent.EndOffset -ge $invocation.Extent.EndOffset
    } | Sort-Object `
      @{ Expression = {
          (Get-NearestStatementBlock -Ast $_).Extent.EndOffset -
            (Get-NearestStatementBlock -Ast $_).Extent.StartOffset
        }; Ascending = $true },
      @{ Expression = { $_.Extent.StartOffset }; Descending = $true })
    $reachingAssignment = if ($assignments.Count -gt 0) { $assignments[0] } else { $null }
    if ($null -eq $reachingAssignment -or
        -not (Test-DirectArrayString -Ast $reachingAssignment.Right -Value '-RequireReleaseEligible')) {
      throw "Operational verifier argument array lacks a directly reachable eligibility switch in $($spec.file)"
    }
  }
  $priorInvocations = if ($operationalInvocations.ContainsKey($spec.file)) {
    @($operationalInvocations[$spec.file])
  } else { @() }
  $operationalInvocations[$spec.file] = @(@($priorInvocations) + @($invocations))
}

$flashReleaseText = [string]$operationalTexts['flash_release_firmware.ps1']
foreach ($selectorMarker in @(
    '$otaSelector = Join-Path $firmwareDir "boot_app0.bin"',
    'Packaged OTA selector must be exactly 8192 bytes.',
    'Assert-StackchanReleaseOtaSelectorBytes',
    'Copy-ReleaseZipSnapshot',
    '$snapshotLock = Copy-ReleaseZipSnapshot',
    '$snapshotZip.sha256',
    '$snapshotLock.Dispose()',
    'Private release ZIP snapshot failed eligibility verification.',
    'Get-LockedReleaseZipChecksumRecords',
    '$checksumRecords = Get-LockedReleaseZipChecksumRecords -SnapshotStream $snapshotLock',
    "[string]`$_.FullName -ceq 'SHA256SUMS.txt'",
    'Add-Type -AssemblyName System.IO.Compression',
    'Flash payload changed after snapshot verification:',
    'FileShare]::Read',
    'Get-ReleaseFlashWriteArguments')) {
  if (-not $flashReleaseText.Contains($selectorMarker)) {
    throw "Release flasher does not fail closed over the packaged OTA selector: $selectorMarker"
  }
}
$flashAst = $operationalAsts['flash_release_firmware.ps1']
$flashArgumentFunctions = @($flashAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ReleaseFlashWriteArguments'
}, $true))
if ($flashArgumentFunctions.Count -ne 1) {
  throw 'Release flasher must define exactly one pure flash-write argument helper.'
}
$semanticProbe = [scriptblock]::Create(
  $flashArgumentFunctions[0].Extent.Text + "`n" +
  "Get-ReleaseFlashWriteArguments -Bootloader BOOT -Partitions PART -OtaSelector OTA -FirmwareBin APP")
$actualFlashPairs = @(& $semanticProbe)
$expectedFlashPairs = @('0x0', 'BOOT', '0x8000', 'PART', '0xe000', 'OTA', '0x10000', 'APP')
if ($actualFlashPairs.Count -ne $expectedFlashPairs.Count) {
  throw 'Release flasher returned an unexpected number of address/payload arguments.'
}
for ($index = 0; $index -lt $expectedFlashPairs.Count; $index++) {
  if ([string]$actualFlashPairs[$index] -cne [string]$expectedFlashPairs[$index]) {
    throw "Release flasher address/payload pair mismatch at index $index."
  }
}

$shareFile = 'share_release.ps1'
$shareAst = Read-OperationalScriptAst -RelativePath $shareFile
$operationalAsts[$shareFile] = $shareAst
$operationalTexts[$shareFile] = Get-Content -LiteralPath (Join-Path $PSScriptRoot $shareFile) -Raw
$shareVerifierFunctions = @($shareAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-OperationalPackageVerification'
}, $true))
if ($shareVerifierFunctions.Count -ne 1) {
  throw 'Release sharing must define one operational package-verification wrapper'
}
$shareVerifierCommands = @($shareVerifierFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.CommandElements.Count -gt 0 -and
    $node.CommandElements[0] -is [System.Management.Automation.Language.ParenExpressionAst] -and
    $node.CommandElements[0].Extent.Text -match 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']'
}, $true))
if ($shareVerifierCommands.Count -ne 1 -or
    -not (Test-DirectCommandParameter -Command $shareVerifierCommands[0] -Name 'RequireReleaseEligible')) {
  throw 'Release sharing wrapper does not directly require operational package eligibility'
}
$shareWrapperCalls = @($shareAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.GetCommandName() -ceq 'Invoke-OperationalPackageVerification'
}, $true) | Sort-Object { $_.Extent.StartOffset })
if ($shareWrapperCalls.Count -ne 1) {
  throw "Release sharing must have exactly one reachable pre-share verifier call, got $($shareWrapperCalls.Count)"
}
$operationalInvocations[$shareFile] = $shareWrapperCalls

$publishFile = 'publish_release.ps1'
$publishAst = Read-OperationalScriptAst -RelativePath $publishFile
$operationalAsts[$publishFile] = $publishAst
$operationalTexts[$publishFile] = Get-Content -LiteralPath (Join-Path $PSScriptRoot $publishFile) -Raw
$publishVerifierFunctions = @($publishAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-OperationalPackageVerification'
}, $true))
if ($publishVerifierFunctions.Count -ne 1) {
  throw 'Release publication must define one operational package-verification wrapper'
}
$publishVerifierFunction = $publishVerifierFunctions[0]
$publishVerifierCommands = @($publishVerifierFunction.Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.CommandElements.Count -gt 1 -and
    $node.CommandElements[0] -is [System.Management.Automation.Language.ParenExpressionAst] -and
    $node.CommandElements[0].Extent.Text -match 'Join-Path\s+\$PSScriptRoot\s+["'']verify_release_package\.ps1["'']' -and
    @($node.CommandElements | Where-Object {
      $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Splatted -and $_.VariablePath.UserPath -ceq 'arguments'
    }).Count -eq 1
}, $true))
if ($publishVerifierCommands.Count -ne 1) {
  throw 'Release publication wrapper does not directly invoke the source-side verifier exactly once'
}
$publishArgumentAssignments = @($publishVerifierFunction.Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$arguments' -and
    $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals
}, $true))
if ($publishArgumentAssignments.Count -ne 1) {
  throw 'Release publication wrapper verifier argument source is ambiguous'
}
$publishArgumentsNode = $publishArgumentAssignments[0].Right
if ($publishArgumentsNode -is [System.Management.Automation.Language.CommandExpressionAst]) {
  $publishArgumentsNode = $publishArgumentsNode.Expression
}
$publishEligibilityPairs = if ($publishArgumentsNode -is [System.Management.Automation.Language.HashtableAst]) {
  @($publishArgumentsNode.KeyValuePairs | Where-Object {
    $_.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $_.Item1.Value -ceq 'RequireReleaseEligible'
  })
} else {
  @()
}
$publishEligibilityValue = if ($publishEligibilityPairs.Count -eq 1 -and
    $publishEligibilityPairs[0].Item2 -is [System.Management.Automation.Language.PipelineAst] -and
    $publishEligibilityPairs[0].Item2.PipelineElements.Count -eq 1 -and
    $publishEligibilityPairs[0].Item2.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
  $publishEligibilityPairs[0].Item2.PipelineElements[0].Expression
} else {
  $null
}
if ($publishEligibilityPairs.Count -ne 1 -or
    $publishEligibilityValue -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
    $publishEligibilityValue.VariablePath.UserPath -cne 'true' -or
    $publishArgumentAssignments[0].Extent.EndOffset -ge $publishVerifierCommands[0].Extent.StartOffset) {
  throw 'Release publication wrapper does not directly bind RequireReleaseEligible to true before its verifier call'
}
$publishWrapperCalls = @($publishAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.GetCommandName() -ceq 'Invoke-OperationalPackageVerification'
}, $true) | Sort-Object { $_.Extent.StartOffset })
if ($publishWrapperCalls.Count -ne 2) {
  throw "Release publication must have exactly two reachable verification wrapper calls, got $($publishWrapperCalls.Count)"
}
$operationalInvocations[$publishFile] = $publishWrapperCalls

foreach ($relativePath in @($operationalInvocations.Keys)) {
  Assert-NoPreVerifierHelperLoad `
    -RelativePath $relativePath `
    -Ast $operationalAsts[$relativePath] `
    -VerifierInvocations @($operationalInvocations[$relativePath])
}
foreach ($relativePath in @('publish_release.ps1', 'share_release.ps1')) {
  $firstVerifier = @($operationalInvocations[$relativePath] |
    Sort-Object { $_.Extent.StartOffset })[0]
  Assert-NoPreVerifierSideEffects `
    -RelativePath $relativePath -Ast $operationalAsts[$relativePath] -FirstVerifier $firstVerifier
}
$shareText = [string]$operationalTexts['share_release.ps1']
$shareMutations = @($shareAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.Left.Extent.Text -ceq '$shareRoot'
}, $true))
if ($shareMutations.Count -ne 1 -or
    $shareMutations[0].Extent.StartOffset -le $shareWrapperCalls[0].Extent.EndOffset -or
    $shareText.Contains('Join-Path $packageRoot "tools/') -or
    $shareText.Contains("Join-Path `$packageRoot 'tools/")) {
  throw 'Release sharing must verify before share mutation and must never execute package-contained tools'
}
foreach ($mutableExporter in @(
  'export_github_actions_status.ps1',
  'export_rollout_status.ps1'
)) {
  if ($shareText.Contains($mutableExporter)) {
    throw "Release sharing must not mix mutable exporter output into the verified share: $mutableExporter"
  }
}
$rolloutText = [string]$operationalTexts['export_rollout_status.ps1']
$rolloutAst = $operationalAsts['export_rollout_status.ps1']
$rolloutExtractCommands = @($rolloutAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    -not (Test-WithinFunctionDefinition -Ast $node) -and
    $node.GetCommandName() -ceq 'Expand-StackchanReleaseZipSafely'
}, $true))
$rolloutAuthorityAssignments = @($rolloutAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -in @('$ExpectedCommit', '$Version') -and
    $node.Right.Extent.Text -match '\$manifest\.(?:commit|version)'
}, $true))
$rolloutVerifierInvocation = @($operationalInvocations['export_rollout_status.ps1'])[0]
if ($rolloutExtractCommands.Count -ne 1 -or
    $rolloutExtractCommands[0].Extent.StartOffset -le $rolloutVerifierInvocation.Extent.EndOffset -or
    $rolloutAuthorityAssignments.Count -ne 0) {
  throw 'Rollout export must verify before ZIP extraction and must preserve caller authority'
}
$publishText = [string]$operationalTexts['publish_release.ps1']
foreach ($remoteMutation in @(
  'New-VerifiedReleaseTag -Tag $Version -Commit $tagCommit',
  'Assert-CurrentBranchPublishedAtCommit -Commit $tagCommit',
  'Invoke-Checked "Push tag $Version"'
)) {
  $mutationCommands = @($publishAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
      -not (Test-WithinFunctionDefinition -Ast $node) -and
      $node.Extent.Text.Contains($remoteMutation)
  }, $true))
  if ($mutationCommands.Count -ne 1 -or
      $mutationCommands[0].Extent.StartOffset -le $publishWrapperCalls[0].Extent.EndOffset) {
    throw "Release publication can mutate Git before operational package verification: $remoteMutation"
  }
}
$auditText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'audit_published_release.ps1') -Raw
if ($auditText.Contains('$ExpectedCommit = [string]$manifest.commit') -or
    -not $auditText.Contains('$trustedTagCommit')) {
  throw 'Published-release audit must derive commit authority from trusted Git, never the package manifest'
}
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$releaseWorkflowLines = @(Get-Content -LiteralPath $releaseWorkflowPath)
$workflowVerifierBlocks = New-Object 'System.Collections.Generic.List[string]'
for ($lineIndex = 0; $lineIndex -lt $releaseWorkflowLines.Count; $lineIndex++) {
  if ($releaseWorkflowLines[$lineIndex] -notmatch
      '^\s*(?:&\s+)?\.?[/\\]tools[/\\]verify_release_package\.ps1(?:\s|`|$)') {
    continue
  }
  $blockLines = New-Object 'System.Collections.Generic.List[string]'
  do {
    $blockLines.Add([string]$releaseWorkflowLines[$lineIndex])
    $continues = $releaseWorkflowLines[$lineIndex].TrimEnd().EndsWith('`')
    if ($continues) { $lineIndex++ }
  } while ($continues -and $lineIndex -lt $releaseWorkflowLines.Count)
  $workflowVerifierBlocks.Add(($blockLines -join "`n"))
}
if ($workflowVerifierBlocks.Count -eq 0) {
  throw 'Release workflow has no executable package verifier command'
}
foreach ($workflowVerifierBlock in $workflowVerifierBlocks) {
  if ($workflowVerifierBlock -notmatch '(?m)(?:^|\s)-RequireReleaseEligible(?:\s|$)') {
    throw "Release workflow verifier command omits operational package eligibility: $workflowVerifierBlock"
  }
}
foreach ($required in @(
  'Assert-SafeReleaseVersionLeaf',
  'Join-ContainedReleaseOutputPath',
  'Refusing release output path outside the governed root'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Package output-path contract is missing: $required"
  }
}

$maliciousVersion = 'diagnostic-x\..\contract-victim'
$savedBuildEnvironment = @(
  Get-ChildItem Env: | Where-Object { $_.Name -like 'PLATFORMIO_*' -or $_.Name -like 'GIT_*' }
)
try {
  foreach ($entry in $savedBuildEnvironment) {
    Remove-Item ("Env:\" + $entry.Name) -ErrorAction SilentlyContinue
  }
  foreach ($scriptPath in @($packagePath, $verifyPath)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Version', $maliciousVersion)
    if ($scriptPath -eq $packagePath) { $arguments += @('-SkipBuild', '-AllowDirty') }
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& powershell.exe @arguments 2>&1)
      $childExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($childExit -eq 0 -or ($output | Out-String) -notmatch 'safe filename component') {
      throw "Unsafe version was not rejected before path use by $scriptPath"
    }
  }
} finally {
  foreach ($entry in $savedBuildEnvironment) {
    Set-Item ("Env:\" + $entry.Name) -Value $entry.Value
  }
}

$savedGitDir = $env:GIT_DIR
try {
  $env:GIT_DIR = Join-Path $repoRoot '.git'
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $gitOverrideOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyPath `
      -Version 'git-override-contract' `
      -PackageRoot (Join-Path $repoRoot 'output/contract-tests/missing-package') `
      -ExpectedCommit ("1" * 40) 2>&1)
    $gitOverrideExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($gitOverrideExit -eq 0 -or ($gitOverrideOutput | Out-String) -notmatch 'refuses ambient Git overrides') {
    throw "Verifier did not reject ambient Git redirection before package/path work"
  }
} finally {
  if ($null -eq $savedGitDir) {
    Remove-Item Env:\GIT_DIR -ErrorAction SilentlyContinue
  } else {
    $env:GIT_DIR = $savedGitDir
  }
}

$gitTrustRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-git-trust-contract-' + [guid]::NewGuid().ToString('N'))
try {
  $gitMain = Join-Path $gitTrustRoot 'main'
  $maliciousHooks = Join-Path $gitTrustRoot 'malicious-hooks'
  $safeWorktree = Join-Path $gitTrustRoot 'safe-worktree'
  $markerPath = Join-Path $gitTrustRoot 'LOCAL_GIT_CONFIG_EXECUTED.txt'
  $disabledHooks = Join-Path $gitTrustRoot 'disabled-hooks-must-not-exist'
  New-Item -ItemType Directory -Force -Path $gitMain, $maliciousHooks | Out-Null
  & git -C $gitMain init -q
  & git -C $gitMain config user.name 'Stackchan Contract'
  & git -C $gitMain config user.email 'contract@example.invalid'
  Set-Content -LiteralPath (Join-Path $gitMain 'tracked.txt') -Value 'trusted' -Encoding ASCII
  & git -C $gitMain add tracked.txt
  & git -C $gitMain commit -q -m trusted
  $trustedCommit = (& git -C $gitMain rev-parse HEAD).Trim()
  $postCheckout = Join-Path $maliciousHooks 'post-checkout'
  @"
#!/bin/sh
printf executed > '$($markerPath.Replace('\', '/'))'
"@ | Set-Content -LiteralPath $postCheckout -Encoding ASCII
  & git -C $gitMain config core.hooksPath $maliciousHooks
  & git -C $gitMain config core.fsmonitor $postCheckout

  . $gitTrustPath
  $gitApplication = Get-Command -Name git -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
  $gitExecutable = (Resolve-Path -LiteralPath ([string]$gitApplication.Source)).Path
  Invoke-StackchanTrustedGit -GitExecutable $gitExecutable -DisabledHooksPath $disabledHooks -Arguments @(
    '-C', $gitMain, 'worktree', 'add', '--detach', $safeWorktree, $trustedCommit)
  if ($LASTEXITCODE -ne 0) { throw 'Trusted Git contract could not create the fixture worktree' }
  $trustedStatus = @(Invoke-StackchanTrustedGit -GitExecutable $gitExecutable -DisabledHooksPath $disabledHooks -Arguments @(
    '-C', $safeWorktree, 'status', '--porcelain=v1', '--untracked-files=all'))
  if ($LASTEXITCODE -ne 0 -or $trustedStatus.Count -ne 0) {
    throw 'Trusted Git contract could not audit the fixture worktree'
  }
  if (Test-Path -LiteralPath $markerPath) {
    throw 'Trusted Git wrapper executed repository-local hook or fsmonitor configuration'
  }
  Invoke-StackchanTrustedGit -GitExecutable $gitExecutable -DisabledHooksPath $disabledHooks -Arguments @(
    '-C', $gitMain, 'worktree', 'remove', $safeWorktree)
  if ($LASTEXITCODE -ne 0) { throw 'Trusted Git contract could not remove the fixture worktree' }
} finally {
  if ((Test-Path -LiteralPath (Join-Path $gitTrustRoot 'main/.git')) -and
      (Test-Path -LiteralPath (Join-Path $gitTrustRoot 'safe-worktree'))) {
    & git -C (Join-Path $gitTrustRoot 'main') worktree remove --force `
      (Join-Path $gitTrustRoot 'safe-worktree') 2>$null
  }
  if (Test-Path -LiteralPath $gitTrustRoot) {
    Get-ChildItem -LiteralPath $gitTrustRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    [System.IO.Directory]::Delete($gitTrustRoot, $true)
  }
}

$epochTrustRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-epoch-trust-contract-' + [guid]::NewGuid().ToString('N'))
try {
  $epochTools = Join-Path $epochTrustRoot 'tools'
  New-Item -ItemType Directory -Force -Path $epochTools | Out-Null
  foreach ($relative in @(
    'verify_release_package.ps1',
    'firmware_reproducibility_proof.ps1',
    'release_zip_safety.ps1',
    'release_dependency_evidence.ps1',
    'release_source_binding.ps1',
    'release_git_trust.ps1',
    'release_ota_selector_policy.ps1',
    'platformio_resolver.ps1',
    'preview_python_resolver.ps1'
  )) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $epochTools
  }
  @'
tools/release_dependency_evidence.ps1 filter=contractclean
'@ | Set-Content -LiteralPath (Join-Path $epochTrustRoot '.gitattributes') -Encoding ASCII
  @'
import sys

sys.stdin.buffer.read()
with open("filter_expected.bin", "rb") as expected:
    sys.stdout.buffer.write(expected.read())
'@ | Set-Content -LiteralPath (Join-Path $epochTrustRoot 'filter_clean.py') -Encoding ASCII
  Copy-Item -LiteralPath (Join-Path $epochTools 'release_dependency_evidence.ps1') `
    -Destination (Join-Path $epochTrustRoot 'filter_expected.bin')
  $gateHarnessPath = Join-Path $epochTools 'release_checkout_gate_harness.ps1'
  $gateHarnessText = @(
@'
param(
  [Parameter(Mandatory = $true)][string]$ExpectedCommit,
  [Parameter(Mandatory = $true)][string]$ExpectedSourceEpoch,
  [Parameter(Mandatory = $true)][string]$GitExecutable,
  [string]$PackageRoot,
  [switch]$AllowDirtyPackage
)
$ErrorActionPreference = 'Stop'
$RequireReleaseEligible = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
$script:trustedGitExecutable = (Get-Item -LiteralPath $GitExecutable -Force -ErrorAction Stop).FullName
$script:trustedGitDisabledHooksPath = Join-Path $repoRoot (
  'output/private/disabled-verifier-git-hooks-' + $PID + '-' + [guid]::NewGuid().ToString('N'))
$script:trustedNullAttributesPath = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }
if (Test-Path -LiteralPath $script:trustedGitDisabledHooksPath) {
  throw "Verifier Git disabled-hooks sentinel unexpectedly exists: $script:trustedGitDisabledHooksPath"
}
'@
    $bootstrapGitFunctions[0].Extent.Text
    $canonicalBlobHashFunctions[0].Extent.Text
    $releaseEligibilityGate.Extent.Text
@'
if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $packageRootPath = (Resolve-Path -LiteralPath $PackageRoot).Path
  $eligibilityManifestPath = Join-Path $packageRootPath 'release_manifest.json'
'@
    $earlyDiagnosticGates[0].Extent.Text
@'
}
'@
  ) -join "`r`n`r`n"
  [IO.File]::WriteAllText(
    $gateHarnessPath, $gateHarnessText, (New-Object Text.UTF8Encoding($false)))
  $earlyDiagnosticRoot = Join-Path $epochTrustRoot 'package'
  New-Item -ItemType Directory -Path $earlyDiagnosticRoot | Out-Null
  [ordered]@{
    version = 'diagnostic-early-contract'
    diagnosticPackage = $true
  } | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $earlyDiagnosticRoot 'release_manifest.json') -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $epochTrustRoot '.gitignore') `
    -Value "ignored-verifier/`n" -Encoding ASCII
  & git -C $epochTrustRoot init -q
  & git -C $epochTrustRoot config user.name 'Stackchan Contract'
  & git -C $epochTrustRoot config user.email 'contract@example.invalid'
  & git -C $epochTrustRoot add tools package .gitignore .gitattributes filter_clean.py filter_expected.bin
  & git -C $epochTrustRoot commit -q -m trusted-epoch
  & git -C $epochTrustRoot config filter.contractclean.clean 'python filter_clean.py'
  & git -C $epochTrustRoot config filter.contractclean.smudge cat
  & git -C $epochTrustRoot config filter.contractclean.required true
  $epochCommit = (& git -C $epochTrustRoot rev-parse HEAD).Trim()
  $epochValue = (& git -C $epochTrustRoot show -s --format=%ct HEAD).Trim()
  $wrongEpoch = if ($epochValue -eq '1') { '2' } else { '1' }
  $fixtureGitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $fixtureGitCommand) {
    throw 'Checkout-gate fixture requires a Git application'
  }
  $fixtureGitExecutable = (
    Resolve-Path -LiteralPath ([string]$fixtureGitCommand.Source)).Path
  $gateBaseArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gateHarnessPath,
    '-ExpectedCommit', $epochCommit, '-GitExecutable', $fixtureGitExecutable)
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $epochOutput = @(& powershell.exe @gateBaseArgs `
      -ExpectedSourceEpoch $wrongEpoch 2>&1)
    $epochExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($epochExit -eq 0 -or
      ($epochOutput | Out-String) -notmatch 'does not match the trusted checkout commit epoch') {
    throw "Operational verifier did not derive and enforce the trusted commit epoch: $($epochOutput | Out-String)"
  }
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $earlyDiagnosticOutput = @(& powershell.exe @gateBaseArgs `
      -PackageRoot $earlyDiagnosticRoot `
      -ExpectedSourceEpoch $epochValue `
      -AllowDirtyPackage `
      2>&1)
    $earlyDiagnosticExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($earlyDiagnosticExit -eq 0 -or
      ($earlyDiagnosticOutput | Out-String) -notmatch 'Operational release verification refuses diagnostic packages') {
    throw 'Operational verifier did not reject a diagnostic manifest at the early eligibility gate'
  }

  foreach ($dirtyHelperName in @(
    'firmware_reproducibility_proof.ps1',
    'release_zip_safety.ps1',
    'release_dependency_evidence.ps1',
    'release_source_binding.ps1',
    'release_git_trust.ps1',
    'release_ota_selector_policy.ps1',
    'platformio_resolver.ps1',
    'preview_python_resolver.ps1'
  )) {
    $preGateMarker = Join-Path ([System.IO.Path]::GetTempPath()) (
      'stackchan-dirty-helper-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
    $dirtyHelperPath = Join-Path $epochTools $dirtyHelperName
    $markerLiteral = $preGateMarker.Replace("'", "''")
    $dirtyHelperText = Get-Content -LiteralPath $dirtyHelperPath -Raw
    ("[System.IO.File]::WriteAllText('$markerLiteral', 'executed')`r`n" + $dirtyHelperText) |
      Set-Content -LiteralPath $dirtyHelperPath -Encoding UTF8
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $dirtyHelperOutput = @(& powershell.exe @gateBaseArgs `
        -ExpectedSourceEpoch $epochValue 2>&1)
      $dirtyHelperExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($dirtyHelperExit -eq 0 -or
        ($dirtyHelperOutput | Out-String) -notmatch 'requires a clean trusted checkout') {
      throw "Operational verifier did not reject dirty $dirtyHelperName at the checkout gate"
    }
    if (Test-Path -LiteralPath $preGateMarker) {
      throw "Operational verifier executed dirty $dirtyHelperName before the checkout gate"
    }
    & git -C $epochTrustRoot checkout -- ("tools/" + $dirtyHelperName)
    if ($LASTEXITCODE -ne 0) {
      throw "Could not restore dirty-helper contract fixture: $dirtyHelperName"
    }
  }

  foreach ($hiddenIndexCase in @(
    [pscustomobject]@{
      helper = 'firmware_reproducibility_proof.ps1'
      setFlag = '--assume-unchanged'
      clearFlag = '--no-assume-unchanged'
      label = 'assume-unchanged'
    },
    [pscustomobject]@{
      helper = 'release_zip_safety.ps1'
      setFlag = '--skip-worktree'
      clearFlag = '--no-skip-worktree'
      label = 'skip-worktree'
    }
  )) {
    $hiddenMarker = Join-Path ([System.IO.Path]::GetTempPath()) (
      'stackchan-hidden-helper-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
    $hiddenRelative = 'tools/' + [string]$hiddenIndexCase.helper
    $hiddenPath = Join-Path $epochTrustRoot $hiddenRelative
    try {
      & git -C $epochTrustRoot update-index ([string]$hiddenIndexCase.setFlag) -- $hiddenRelative
      if ($LASTEXITCODE -ne 0) {
        throw "Could not set $($hiddenIndexCase.label) on the dirty-helper fixture"
      }
      $hiddenLiteral = $hiddenMarker.Replace("'", "''")
      $hiddenText = Get-Content -LiteralPath $hiddenPath -Raw
      ("[System.IO.File]::WriteAllText('$hiddenLiteral', 'executed')`r`n" + $hiddenText) |
        Set-Content -LiteralPath $hiddenPath -Encoding UTF8
      $previousErrorPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        $hiddenOutput = @(& powershell.exe @gateBaseArgs `
          -ExpectedSourceEpoch $epochValue 2>&1)
        $hiddenExit = $LASTEXITCODE
      } finally {
        $ErrorActionPreference = $previousErrorPreference
      }
      if ($hiddenExit -eq 0 -or
          ($hiddenOutput | Out-String) -notmatch 'refuses hidden index state|requires exact HEAD bytes') {
        throw "Operational verifier did not reject $($hiddenIndexCase.label) helper state"
      }
      if (Test-Path -LiteralPath $hiddenMarker) {
        throw "Operational verifier executed a $($hiddenIndexCase.label) dirty helper before rejection"
      }
    } finally {
      & git -C $epochTrustRoot update-index ([string]$hiddenIndexCase.clearFlag) -- $hiddenRelative
      & git -C $epochTrustRoot checkout -- $hiddenRelative
    }
  }

  $filteredHelperRelative = 'tools/release_dependency_evidence.ps1'
  $filteredHelperPath = Join-Path $epochTrustRoot $filteredHelperRelative
  $filteredMarker = Join-Path $epochTrustRoot 'CUSTOM_FILTER_HELPER_EXECUTED.txt'
  try {
    $filteredMarkerLiteral = $filteredMarker.Replace("'", "''")
    $filteredHelperText = Get-Content -LiteralPath $filteredHelperPath -Raw
    $filteredCanary = @(
      "[System.IO.File]::WriteAllText('$filteredMarkerLiteral', 'executed') # CONTRACT_CANARY",
      "throw 'custom clean-filter helper executed' # CONTRACT_CANARY"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText(
      $filteredHelperPath, ($filteredCanary + "`r`n" + $filteredHelperText),
      (New-Object System.Text.UTF8Encoding($false)))
    & git -C $epochTrustRoot update-index --really-refresh -- $filteredHelperRelative | Out-Null
    $ordinaryFilteredStatus = @(& git -C $epochTrustRoot status --porcelain=v1 -- $filteredHelperRelative)
    if ($LASTEXITCODE -ne 0 -or $ordinaryFilteredStatus.Count -ne 0) {
      $ordinaryFilteredDiff = @(& git -C $epochTrustRoot diff -- $filteredHelperRelative)
      throw "Custom clean-filter fixture did not hide the helper mutation from ordinary Git status: $($ordinaryFilteredStatus -join '; ') :: $($ordinaryFilteredDiff -join '; ')"
    }
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $filteredOutput = @(& powershell.exe @gateBaseArgs `
        -ExpectedSourceEpoch $epochValue 2>&1)
      $filteredExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($filteredExit -eq 0 -or
        ($filteredOutput | Out-String) -notmatch 'requires canonical HEAD content') {
      throw 'Operational verifier let a custom clean-filter hide a modified trusted helper'
    }
    if (Test-Path -LiteralPath $filteredMarker) {
      throw 'Operational verifier executed the custom-filter-hidden helper before rejection'
    }
  } finally {
    & git -C $epochTrustRoot checkout -- $filteredHelperRelative
  }

  $infoAttributesPath = Join-Path $epochTrustRoot '.git/info/attributes'
  $infoHelperRelative = 'tools/release_zip_safety.ps1'
  $infoHelperPath = Join-Path $epochTrustRoot $infoHelperRelative
  $infoMarker = Join-Path $epochTrustRoot 'INFO_ATTRIBUTES_HELPER_EXECUTED.txt'
  try {
    Set-Content -LiteralPath $infoAttributesPath `
      -Value 'tools/*.ps1 filter=contractclean' -Encoding ASCII
    $infoMarkerLiteral = $infoMarker.Replace("'", "''")
    $infoHelperText = Get-Content -LiteralPath $infoHelperPath -Raw
    ("[System.IO.File]::WriteAllText('$infoMarkerLiteral', 'executed')`r`n" +
      "throw 'info attributes helper executed'`r`n" + $infoHelperText) |
      Set-Content -LiteralPath $infoHelperPath -Encoding UTF8
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $infoAttributesOutput = @(& powershell.exe @gateBaseArgs `
        -ExpectedSourceEpoch $epochValue 2>&1)
      $infoAttributesExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($infoAttributesExit -eq 0 -or
        ($infoAttributesOutput | Out-String) -notmatch 'refuses repository-local Git attributes') {
      throw 'Operational verifier did not reject repository-local info/attributes'
    }
    if (Test-Path -LiteralPath $infoMarker) {
      throw 'Operational verifier executed an info/attributes-hidden helper before rejection'
    }
  } finally {
    Remove-Item -LiteralPath $infoAttributesPath -Force -ErrorAction SilentlyContinue
    & git -C $epochTrustRoot checkout -- $infoHelperRelative
  }

  $nestedVerifierRoot = Join-Path $epochTrustRoot 'ignored-verifier/tools'
  New-Item -ItemType Directory -Path $nestedVerifierRoot -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $epochTools 'verify_release_package.ps1') `
    -Destination $nestedVerifierRoot
  $nestedHarnessPath = Join-Path $nestedVerifierRoot 'release_checkout_gate_harness.ps1'
  Copy-Item -LiteralPath $gateHarnessPath -Destination $nestedHarnessPath
  $nestedMarker = Join-Path $epochTrustRoot 'NESTED_HELPER_EXECUTED.txt'
  $nestedMarkerLiteral = $nestedMarker.Replace("'", "''")
  ("[System.IO.File]::WriteAllText('$nestedMarkerLiteral', 'executed')`r`n" +
    (Get-Content -LiteralPath (Join-Path $epochTools 'firmware_reproducibility_proof.ps1') -Raw)) |
    Set-Content -LiteralPath (Join-Path $nestedVerifierRoot 'firmware_reproducibility_proof.ps1') -Encoding UTF8
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $nestedOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass `
      -File $nestedHarnessPath `
      -ExpectedCommit $epochCommit `
      -GitExecutable $fixtureGitExecutable `
      -ExpectedSourceEpoch $epochValue `
      2>&1)
    $nestedExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($nestedExit -eq 0 -or
      ($nestedOutput | Out-String) -notmatch 'refuses a nested or ignored verifier') {
    throw 'Operational verifier did not reject an ignored nested verifier before helper loading'
  }
  if (Test-Path -LiteralPath $nestedMarker) {
    throw 'Ignored nested verifier loaded its local packaged helper before rejection'
  }
  } finally {
    if (Test-Path -LiteralPath $epochTrustRoot) {
      Get-ChildItem -LiteralPath $epochTrustRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.IsReadOnly = $false }
      [System.IO.Directory]::Delete($epochTrustRoot, $true)
    }
  }
$zipContractRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-verifier-zip-contract-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $zipContractRoot | Out-Null
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $unsafeZip = Join-Path $zipContractRoot 'unsafe.zip'
  $archive = [System.IO.Compression.ZipFile]::Open($unsafeZip, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $archive.CreateEntry('../OUTSIDE.txt')
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    try { $writer.Write('must not extract') } finally { $writer.Dispose() }
  } finally {
    $archive.Dispose()
  }
  $unsafeZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $unsafeZip).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText(
    "$unsafeZip.sha256",
    "$unsafeZipHash  $([IO.Path]::GetFileName($unsafeZip))`n",
    [Text.Encoding]::ASCII)
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $unsafeZipOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyPath `
      -Version 'zip-contract' -ZipPath $unsafeZip -ExpectedCommit ("1" * 40) 2>&1)
    $unsafeZipExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($unsafeZipExit -eq 0 -or ($unsafeZipOutput | Out-String) -notmatch 'unsafe, duplicate, or link entry') {
    throw "ZIP traversal entry was not rejected before extraction"
  }
  if (Test-Path -LiteralPath (Join-Path $zipContractRoot 'OUTSIDE.txt')) {
    throw "ZIP traversal entry escaped the verifier extraction root"
  }

  . $zipSafetyPath
  $hostileArchives = @()
  $duplicateZip = Join-Path $zipContractRoot 'duplicate.zip'
  $archive = [System.IO.Compression.ZipFile]::Open($duplicateZip, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in @('same.txt', 'SAME.txt')) {
      $entry = $archive.CreateEntry($name)
      $writer = New-Object System.IO.StreamWriter($entry.Open())
      try { $writer.Write($name) } finally { $writer.Dispose() }
    }
  } finally { $archive.Dispose() }
  $hostileArchives += $duplicateZip

  $linkZip = Join-Path $zipContractRoot 'link.zip'
  $archive = [System.IO.Compression.ZipFile]::Open($linkZip, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $archive.CreateEntry('package-link')
    $entry.ExternalAttributes = [int]((0xA000 -bor 0x1FF) -shl 16)
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    try { $writer.Write('target') } finally { $writer.Dispose() }
  } finally { $archive.Dispose() }
  $hostileArchives += $linkZip

  foreach ($hostileZip in $hostileArchives) {
    $destination = Join-Path $zipContractRoot ([System.IO.Path]::GetFileNameWithoutExtension($hostileZip) + '-extract')
    New-Item -ItemType Directory -Path $destination | Out-Null
    try {
      Expand-StackchanReleaseZipSafely -ZipPath $hostileZip -DestinationPath $destination
      throw "Safe ZIP extractor accepted hostile archive: $hostileZip"
    } catch {
      if ($_.Exception.Message -like 'Safe ZIP extractor accepted hostile archive:*') { throw }
    }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count -ne 0) {
      throw "Hostile ZIP was partially extracted before rejection: $hostileZip"
    }
  }
} finally {
  if (Test-Path -LiteralPath $zipContractRoot) {
    [System.IO.Directory]::Delete($zipContractRoot, $true)
  }
}

if (-not [string]::IsNullOrWhiteSpace($BehaviorFixtureRoot)) {
  $sourceFixture = (Resolve-Path -LiteralPath $BehaviorFixtureRoot).Path
  $behaviorRoot = if ($env:OS -eq 'Windows_NT') {
    Join-Path ([System.IO.Path]::GetPathRoot($repoRoot)) (
      'svt-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  } else {
    Join-Path ([System.IO.Path]::GetTempPath()) (
      'svt-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  }
  $packageRoot = Join-Path $behaviorRoot 'package'
  try {
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
    if ($env:OS -eq 'Windows_NT') {
      & robocopy.exe $sourceFixture $packageRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
      if ($LASTEXITCODE -ge 8) { throw "Could not copy hostile-package behavior fixture (robocopy exit $LASTEXITCODE)" }
    } else {
      Get-ChildItem -LiteralPath $sourceFixture -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $packageRoot -Recurse -Force
      }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release_manifest.json') -Raw | ConvertFrom-Json
    $baselineArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifyPath,
      '-Version', [string]$manifest.version,
      '-PackageRoot', $packageRoot,
      '-ExpectedCommit', [string]$manifest.commit
    )
    if ([bool]$manifest.diagnosticPackage) { $baselineArgs += '-AllowDirtyPackage' }
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $baselineOutput = @(& powershell.exe @baselineArgs 2>&1)
      $baselineExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    $expectedSuccess = if ([bool]$manifest.diagnosticPackage) {
      'Diagnostic archive integrity verified'
    } else {
      'Release package verified'
    }
    if ($baselineExit -ne 0 -or ($baselineOutput | Out-String) -notmatch [regex]::Escape($expectedSuccess)) {
      throw "Unmodified hostile-package fixture did not reach verifier success: $($baselineOutput | Out-String)"
    }

    $mutatedRelatives = New-Object System.Collections.Generic.List[string]
    $trustedPowerShellTwins = @(
      'tools/firmware_reproducibility_proof.ps1',
      'tools/release_zip_safety.ps1',
      'tools/release_dependency_evidence.ps1',
      'tools/release_git_trust.ps1',
      'tools/release_ota_selector_policy.ps1',
      'tools/preview_python_resolver.ps1',
      'tools/verify_voice_samples.ps1',
      'tools/verify_tracked_rvc_assets.ps1',
      'tools/verify_speech_envelope_sidecar.ps1',
      'tools/verify_preview_media.ps1',
      'tools/verify_face_phase_a.ps1',
      'tools/verify_face_phase_b.ps1',
      'tools/verify_face_phase_c.ps1',
      'tools/verify_face_phase_d.ps1',
      'tools/verify_face_phase_e.ps1',
      'tools/verify_release_asset_contract.ps1'
    )
    foreach ($relative in $trustedPowerShellTwins) {
      $twinPath = Join-Path $packageRoot $relative
      if (-not (Test-Path -LiteralPath $twinPath -PathType Leaf)) {
        throw "Behavior fixture is missing trusted-script twin: $relative"
      }
      $markerPath = Join-Path $behaviorRoot (
        'EXECUTED-' + ($relative -replace '[^A-Za-z0-9]', '_') + '.txt')
      $tokens = $null
      $parseErrors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $twinPath, [ref]$tokens, [ref]$parseErrors)
      if ($parseErrors.Count -ne 0) { throw "Cannot instrument invalid fixture script: $relative" }
      $insertOffset = if ($null -ne $ast.ParamBlock) { $ast.ParamBlock.Extent.EndOffset } else { 0 }
      $original = [System.IO.File]::ReadAllText($twinPath)
      $canary = "`r`nSet-Content -LiteralPath '$($markerPath.Replace("'", "''"))' -Value 'executed' -Encoding ASCII`r`nthrow 'package canary executed'`r`n"
      $instrumented = $original.Insert($insertOffset, $canary)
      [System.IO.File]::WriteAllText(
        $twinPath, $instrumented, (New-Object System.Text.UTF8Encoding($false)))
      $reparseTokens = $null
      $reparseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile(
        $twinPath, [ref]$reparseTokens, [ref]$reparseErrors)
      if ($reparseErrors.Count -ne 0) { throw "Instrumented fixture script is invalid: $relative" }
      $mutatedRelatives.Add($relative)
    }

    $nestedPackagedMarker = Join-Path $behaviorRoot 'EXECUTED-ignored_nested_verifier.txt'
    $nestedPackagedVerifier = Join-Path $packageRoot 'tools/ignored/nested/verify_release_package.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $nestedPackagedVerifier) -Force | Out-Null
    @(
      'param()',
      "Set-Content -LiteralPath '$($nestedPackagedMarker.Replace("'", "''"))' -Value 'executed' -Encoding ASCII",
      "throw 'ignored nested packaged verifier executed'"
    ) | Set-Content -LiteralPath $nestedPackagedVerifier -Encoding UTF8

    $pythonRelative = 'bridge/lan_service.py'
    $pythonPath = Join-Path $packageRoot $pythonRelative
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
      throw "Behavior fixture is missing Python trust twin: $pythonRelative"
    }
    $pythonMarker = Join-Path $behaviorRoot 'EXECUTED-bridge_lan_service_py.txt'
    $pythonText = [System.IO.File]::ReadAllText($pythonPath)
    $mainGuard = 'if __name__ == "__main__":'
    $mainOffset = $pythonText.LastIndexOf($mainGuard, [System.StringComparison]::Ordinal)
    if ($mainOffset -lt 0) { throw 'Behavior fixture Python twin lacks its main guard' }
    $pythonCanary = "from pathlib import Path as _CanaryPath`n_CanaryPath(r'$($pythonMarker.Replace('\', '/'))').write_text('executed')`nraise RuntimeError('package canary executed')`n"
    [System.IO.File]::WriteAllText(
      $pythonPath,
      $pythonText.Insert($mainOffset, $pythonCanary),
      (New-Object System.Text.UTF8Encoding($false)))
    $astCheckOutput = @(& python -I -B -c `
      'import ast,sys; ast.parse(open(sys.argv[1], encoding=sys.getdefaultencoding()).read())' `
      $pythonPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Instrumented Python twin is invalid: $($astCheckOutput | Out-String)" }
    $mutatedRelatives.Add($pythonRelative)

    $firstMutatedHashPath = $null
    foreach ($line in Get-Content -LiteralPath (Join-Path $packageRoot 'SHA256SUMS.txt')) {
      if ($line -match '^[0-9a-fA-F]{64}\s{2}(.+)$' -and $mutatedRelatives.Contains($Matches[1])) {
        $firstMutatedHashPath = $Matches[1]
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($firstMutatedHashPath)) {
      throw 'Behavior fixture checksums do not cover the instrumented trust twins'
    }
    $previousErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $behaviorOutput = @(& powershell.exe @baselineArgs 2>&1)
      $behaviorExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorPreference
    }
    if ($behaviorExit -eq 0 -or
        ($behaviorOutput | Out-String) -notmatch [regex]::Escape("SHA256 mismatch for $firstMutatedHashPath")) {
      throw "Hostile-package run did not reach the final checksum checkpoint: $($behaviorOutput | Out-String)"
    }
    $executedMarkers = @(Get-ChildItem -LiteralPath $behaviorRoot -Filter 'EXECUTED-*.txt' -File -ErrorAction SilentlyContinue)
    if ($executedMarkers.Count -ne 0) {
      throw "Hostile package code executed: $($executedMarkers.Name -join ', ')"
    }
  } finally {
    if (Test-Path -LiteralPath $behaviorRoot) {
      $deleteRoot = if ($env:OS -eq 'Windows_NT' -and -not $behaviorRoot.StartsWith('\\?\')) {
        "\\?\$behaviorRoot"
      } else { $behaviorRoot }
      [System.IO.Directory]::Delete($deleteRoot, $true)
    }
  }
}

Write-Host "Release package verifier trust contract passed."
