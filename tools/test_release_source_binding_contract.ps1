$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$packagePath = Join-Path $PSScriptRoot "package_release.ps1"
$verifyPath = Join-Path $PSScriptRoot "verify_release_package.ps1"
. (Join-Path $PSScriptRoot "release_source_binding.ps1")
$packageText = Get-Content -LiteralPath $packagePath -Raw
$verifyText = Get-Content -LiteralPath $verifyPath -Raw
$expectedArrivalAuthorityGuidance = 'Return to the exact clean trusted source checkout, define the six-value releaseToolchain splat from docs/RELEASE_PROCESS.md, and pass this ZIP to tools/prepare_device_arrival.ps1. The archive does not confer release authority.'
$arrivalAuthorityGuidance = Get-StackchanArrivalAuthorityGuidance
if ($arrivalAuthorityGuidance -cne $expectedArrivalAuthorityGuidance) {
  throw 'Shared arrival-authority guidance changed unexpectedly.'
}
foreach ($authorityFixture in @(
  $arrivalAuthorityGuidance,
  $arrivalAuthorityGuidance.Replace(' ', "`n"),
  $arrivalAuthorityGuidance.Replace(' ', "`r`n"),
  $arrivalAuthorityGuidance.Replace(' ', "`t"),
  $arrivalAuthorityGuidance.Replace(' ', '  ')
)) {
  $normalizedAuthorityFixture = ConvertTo-StackchanMarkdownSemanticText -Text $authorityFixture
  if ($normalizedAuthorityFixture -cne $arrivalAuthorityGuidance) {
    throw 'Arrival-authority Markdown normalization changed formatting-equivalent semantics.'
  }
}
foreach ($authorityMutation in @(
  $arrivalAuthorityGuidance.Replace('exact clean trusted source checkout', 'trusted source checkout'),
  $arrivalAuthorityGuidance.Replace('six-value', 'five-value'),
  $arrivalAuthorityGuidance.Replace('prepare_device_arrival.ps1', 'run_device_preflight.ps1'),
  $arrivalAuthorityGuidance.Replace('does not confer', 'confers')
)) {
  if ((ConvertTo-StackchanMarkdownSemanticText -Text $authorityMutation) -ceq
      $arrivalAuthorityGuidance) {
    throw 'Arrival-authority Markdown normalization accepted a semantic mutation.'
  }
}
foreach ($requiredArrivalAuthorityProducerBinding in @(
  '$arrivalAuthorityGuidance = Get-StackchanArrivalAuthorityGuidance',
  'nextOperatorGuidance = if ($SkipBuild)',
  'Arrival authority is intentionally not embedded in this archive.'
)) {
  if (-not $packageText.Contains($requiredArrivalAuthorityProducerBinding)) {
    throw "Arrival-authority producer binding is missing: $requiredArrivalAuthorityProducerBinding"
  }
}
foreach ($requiredArrivalAuthorityVerifierBinding in @(
  '$arrivalAuthorityGuidance = Get-StackchanArrivalAuthorityGuidance',
  '$readinessSemanticMarkdown = ConvertTo-StackchanMarkdownSemanticText -Text $readinessMarkdown',
  '[string]$readinessJson.nextOperatorGuidance -cne $arrivalAuthorityGuidance',
  '$eligibilityDiagnosticPackage = [bool]$diagnosticPackageProperties[0].Value',
  'if ($eligibilityDiagnosticPackage -eq $false)',
  '$packageAuthorityDocPaths += ''READINESS_REPORT.md'''
)) {
  if (-not $verifyText.Contains($requiredArrivalAuthorityVerifierBinding)) {
    throw "Arrival-authority verifier binding is missing: $requiredArrivalAuthorityVerifierBinding"
  }
}
$eligibilityClassificationOffset = $verifyText.IndexOf(
  '$eligibilityDiagnosticPackage = [bool]$diagnosticPackageProperties[0].Value',
  [System.StringComparison]::Ordinal)
$readinessAuthorityScanOffset = $verifyText.IndexOf(
  'if ($eligibilityDiagnosticPackage -eq $false)',
  [System.StringComparison]::Ordinal)
$manifestAssignmentOffset = $verifyText.IndexOf(
  '$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json',
  [System.StringComparison]::Ordinal)
$verifyTokens = $null
$verifyParseErrors = $null
$verifyAst = [Management.Automation.Language.Parser]::ParseFile(
  $verifyPath, [ref]$verifyTokens, [ref]$verifyParseErrors)
if ($verifyParseErrors.Count -ne 0) {
  throw "Release verifier does not parse: $($verifyParseErrors | Out-String)"
}
$earlyManifestUses = @($verifyAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.VariablePath.UserPath -ceq 'manifest' -and
    $node.Extent.StartOffset -lt $manifestAssignmentOffset
}, $true))
if ($eligibilityClassificationOffset -lt 0 -or
    $readinessAuthorityScanOffset -le $eligibilityClassificationOffset -or
    $manifestAssignmentOffset -le $readinessAuthorityScanOffset -or
    $earlyManifestUses.Count -ne 0) {
  throw 'Readiness authority scanning uses release-manifest state before its trusted early classification.'
}
if (@([regex]::Matches(
    $packageText, [regex]::Escape('$arrivalAuthorityGuidance'))).Count -ne 3 -or
    @([regex]::Matches(
      $packageText, [regex]::Escape('Get-StackchanArrivalAuthorityGuidance'))).Count -ne 1 -or
    @([regex]::Matches(
      $verifyText, [regex]::Escape('$arrivalAuthorityGuidance'))).Count -ne 3 -or
    @([regex]::Matches(
      $verifyText, [regex]::Escape('Get-StackchanArrivalAuthorityGuidance'))).Count -ne 1) {
  throw 'Arrival-authority producer/verifier binding count is ambiguous.'
}
if (@([regex]::Matches(
    $verifyText,
    [regex]::Escape('$readinessSemanticMarkdown -notmatch [regex]::Escape($pattern)'))).Count -ne 2) {
  throw 'Readiness Markdown checks do not consistently use the semantic whitespace view.'
}
$readinessTemplateStart = $packageText.IndexOf(
  'Arrival authority is intentionally not embedded in this archive.',
  [System.StringComparison]::Ordinal)
$readinessTemplateEnd = $packageText.IndexOf(
  '"@ | Set-Content -Path (Join-Path $outDir "READINESS_REPORT.md") -Encoding UTF8',
  $readinessTemplateStart,
  [System.StringComparison]::Ordinal)
if ($readinessTemplateStart -lt 0 -or $readinessTemplateEnd -le $readinessTemplateStart) {
  throw 'Release readiness Markdown authority template is missing or ambiguous.'
}
$readinessTemplateFixture = $packageText.Substring(
  $readinessTemplateStart, $readinessTemplateEnd - $readinessTemplateStart).Replace(
    '$arrivalAuthorityGuidance', $arrivalAuthorityGuidance)
$readinessTemplateSemanticText = ConvertTo-StackchanMarkdownSemanticText -Text $readinessTemplateFixture
if (-not $readinessTemplateSemanticText.Contains($arrivalAuthorityGuidance)) {
  throw 'Release readiness Markdown is not bound to the canonical arrival-authority guidance.'
}
$readmeLfFixture = "# Stackchan café`n`n![Preview](docs/media/preview.png)`n"
$readmeExpectedFixture = "# Stackchan café`r`n`r`n![Preview](media/preview.png)`r`n"
$readmeSourceFixtures = @(
  $readmeLfFixture,
  $readmeLfFixture.Replace("`n", "`r`n"),
  "# Stackchan café`r`n`n![Preview](docs/media/preview.png)`n",
  "# Stackchan café`r`r![Preview](docs/media/preview.png)`r"
)
foreach ($readmeSourceFixture in $readmeSourceFixtures) {
  $readmeResult = ConvertTo-StackchanPackageReadmeText -Text $readmeSourceFixture
  if ($readmeResult -cne $readmeExpectedFixture) {
    throw 'Package README transform does not canonicalize equivalent source EOL materializations.'
  }
  if ([regex]::IsMatch($readmeResult, '(?<!\r)\n|\r(?!\n)')) {
    throw 'Package README transform emitted a non-CRLF line ending.'
  }
}
$readmeUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$readmeExpectedBytes = $readmeUtf8.GetBytes($readmeExpectedFixture)
$readmeRejectedByteForms = @(
  $readmeUtf8.GetBytes($readmeExpectedFixture.Replace("`r`n", "`n")),
  [byte[]](@(0xEF, 0xBB, 0xBF) + @($readmeExpectedBytes)),
  [System.Text.Encoding]::Unicode.GetBytes($readmeExpectedFixture),
  $readmeUtf8.GetBytes($readmeExpectedFixture.Replace('Preview', 'Changed'))
)
foreach ($readmeRejectedBytes in $readmeRejectedByteForms) {
  if ([System.Linq.Enumerable]::SequenceEqual(
      [byte[]]$readmeExpectedBytes, [byte[]]$readmeRejectedBytes)) {
    throw 'Package README exact-byte fixture accepted alternate EOL, encoding, BOM, or semantics.'
  }
}
foreach ($requiredPackageReadmeBinding in @(
  '$packageReadmeText = ConvertTo-StackchanPackageReadmeText -Text $packageReadmeText',
  'New-Object System.Text.UTF8Encoding($false)'
)) {
  if (-not $packageText.Contains($requiredPackageReadmeBinding)) {
    throw "Package README producer binding is missing: $requiredPackageReadmeBinding"
  }
}
foreach ($requiredVerifierReadmeBinding in @(
  '$expectedPackageReadmeText = ConvertTo-StackchanPackageReadmeText -Text $trustedReadmeText',
  '$packageReadmeUtf8 = New-Object System.Text.UTF8Encoding($false, $true)',
  '$expectedPackageReadmeBytes = $packageReadmeUtf8.GetBytes($expectedPackageReadmeText)',
  '$actualPackageReadmeBytes = [System.IO.File]::ReadAllBytes((Join-PackagePath ''README.md''))',
  '[byte[]]$actualPackageReadmeBytes, [byte[]]$expectedPackageReadmeBytes'
)) {
  if (-not $verifyText.Contains($requiredVerifierReadmeBinding)) {
    throw "Package README verifier binding is missing: $requiredVerifierReadmeBinding"
  }
}
if ($verifyText.Contains("[System.IO.File]::ReadAllText((Join-PackagePath 'README.md'))")) {
  throw 'Operational verifier normalizes package README text instead of comparing exact bytes.'
}
$tokens = $null
$parseErrors = $null
$packageAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $packagePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
  throw "Could not parse production package script: $($parseErrors[0].Message)"
}
$inventoryFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('ConvertTo-CanonicalPackageInventory', 'Get-CanonicalPackageFileInventory')
}, $true))
if ($inventoryFunctions.Count -ne 2) {
  throw 'Production package script must define the two canonical package inventory functions exactly once'
}
foreach ($inventoryFunctionName in @('ConvertTo-CanonicalPackageInventory', 'Get-CanonicalPackageFileInventory')) {
  $definition = @($inventoryFunctions | Where-Object { $_.Name -eq $inventoryFunctionName })
  if ($definition.Count -ne 1) {
    throw "Production package inventory function is ambiguous: $inventoryFunctionName"
  }
  Invoke-Expression $definition[0].Extent.Text
}
foreach ($requiredInventoryBinding in @(
  '$includedToolsInventory = @(Get-CanonicalPackageFileInventory -Directory $toolsDir -PackagePrefix "tools")',
  '$provenanceFileInventory = @(Get-CanonicalPackageFileInventory -Directory $provenanceDir -PackagePrefix "provenance")',
  'includedTools = @($includedToolsInventory)',
  'provenanceFiles = @($provenanceFileInventory)'
)) {
  if (-not $packageText.Contains($requiredInventoryBinding)) {
    throw "Release manifest is not bound to its copied-file inventory: $requiredInventoryBinding"
  }
}
foreach ($trustedToolPolicyMember in @(
  '"tools/searxng/compose.yaml"',
  '"tools/searxng/settings.yml"'
)) {
  $releaseToolsPolicyStart = $packageText.IndexOf('$releaseTools = @(')
  $releaseToolsPolicyEnd = $packageText.IndexOf('foreach ($file in $releaseTools)', $releaseToolsPolicyStart)
  if ($releaseToolsPolicyStart -lt 0 -or $releaseToolsPolicyEnd -le $releaseToolsPolicyStart -or
      @([regex]::Matches(
        $packageText.Substring($releaseToolsPolicyStart, $releaseToolsPolicyEnd - $releaseToolsPolicyStart),
        [regex]::Escape($trustedToolPolicyMember))).Count -ne 1) {
    throw "Trusted release-tool literal policy must contain exactly one nested member: $trustedToolPolicyMember"
  }
}
foreach ($trustedPolicyMarker in @(
  'Get-TrustedReleaseToolPolicy',
  'Get-TrustedProvenancePolicy',
  'Get-OperationalTrustedCommitMaps',
  'Assert-OperationalSourceCheckoutBindings',
  'Operational whole-package inventory count does not match trusted packaging policy'
)) {
  if (-not $verifyText.Contains($trustedPolicyMarker)) {
    throw "Release verifier is missing trusted inventory policy: $trustedPolicyMarker"
  }
}
$lastToolCopyIndex = $packageText.LastIndexOf('Copy-Item -LiteralPath $file -Destination $toolDestination')
$lastProvenanceCopyIndex = $packageText.LastIndexOf('Copy-Item -LiteralPath "bridge/models/README.md" -Destination (Join-Path $visionLicenseDir "README.md") -Force')
$toolInventoryIndex = $packageText.IndexOf('$includedToolsInventory = @(')
$provenanceInventoryIndex = $packageText.IndexOf('$provenanceFileInventory = @(')
$manifestIndex = $packageText.IndexOf('$manifest = [ordered]@{')
if ($lastToolCopyIndex -lt 0 -or $lastProvenanceCopyIndex -lt 0 -or
    $toolInventoryIndex -le $lastToolCopyIndex -or
    $provenanceInventoryIndex -le $lastProvenanceCopyIndex -or
    $manifestIndex -le $toolInventoryIndex -or $manifestIndex -le $provenanceInventoryIndex) {
  throw 'Release inventories are not captured after every tools/provenance copy and before manifest construction'
}

$canonicalInventory = @(ConvertTo-CanonicalPackageInventory `
  -PackagePaths @('tools/z.ps1', 'tools/searxng/settings.yml', 'tools/a.ps1') `
  -RequiredPrefix 'tools')
if (($canonicalInventory -join '|') -cne 'tools/a.ps1|tools/searxng/settings.yml|tools/z.ps1') {
  throw "Canonical package inventory is not ordinally sorted and normalized: $($canonicalInventory -join '|')"
}
foreach ($invalidInventory in @(
  @('tools/a.ps1', 'tools/A.ps1'),
  @('tools/../escape.ps1'),
  @('provenance/not-a-tool.ps1')
)) {
  try {
    ConvertTo-CanonicalPackageInventory -PackagePaths $invalidInventory -RequiredPrefix 'tools' | Out-Null
    throw "Canonical package inventory accepted invalid paths: $($invalidInventory -join ', ')"
  } catch {
    if ($_.Exception.Message -like 'Canonical package inventory accepted invalid paths:*') {
      throw
    }
  }
}
$inventoryFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-package-inventory-contract-' + [guid]::NewGuid().ToString('N'))
try {
  $inventoryTools = Join-Path $inventoryFixtureRoot 'tools'
  $inventorySearxng = Join-Path $inventoryTools 'searxng'
  New-Item -ItemType Directory -Force -Path $inventorySearxng | Out-Null
  Set-Content -LiteralPath (Join-Path $inventoryTools 'package_release.ps1') -Value 'fixture'
  Set-Content -LiteralPath (Join-Path $inventorySearxng 'compose.yaml') -Value 'fixture'
  Set-Content -LiteralPath (Join-Path $inventorySearxng 'settings.yml') -Value 'fixture'
  $capturedToolInventory = @(Get-CanonicalPackageFileInventory -Directory $inventoryTools -PackagePrefix 'tools')
  $expectedToolInventory = @(
    'tools/package_release.ps1',
    'tools/searxng/compose.yaml',
    'tools/searxng/settings.yml'
  )
  if (($capturedToolInventory -join '|') -cne ($expectedToolInventory -join '|')) {
    throw "Copied tools inventory omitted or invented a package member: $($capturedToolInventory -join '|')"
  }
  $inventoryProvenance = Join-Path $inventoryFixtureRoot 'provenance'
  $inventorySource = Join-Path $inventoryProvenance 'src'
  New-Item -ItemType Directory -Force -Path $inventorySource | Out-Null
  Set-Content -LiteralPath (Join-Path $inventoryProvenance 'platformio.ini') -Value 'fixture'
  Set-Content -LiteralPath (Join-Path $inventorySource 'main.cpp') -Value 'fixture'
  $capturedProvenanceInventory = @(
    Get-CanonicalPackageFileInventory -Directory $inventoryProvenance -PackagePrefix 'provenance')
  $expectedProvenanceInventory = @('provenance/platformio.ini', 'provenance/src/main.cpp')
  if (($capturedProvenanceInventory -join '|') -cne ($expectedProvenanceInventory -join '|')) {
    throw "Copied provenance inventory omitted or invented a package member: $($capturedProvenanceInventory -join '|')"
  }
} finally {
  if (Test-Path -LiteralPath $inventoryFixtureRoot) {
    Remove-Item -LiteralPath $inventoryFixtureRoot -Recurse -Force
  }
}
$cleanupFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Remove-ReleaseSourceWorktree'
}, $true))
if ($cleanupFunctions.Count -ne 1) {
  throw 'Production package script must define exactly one release-source cleanup function'
}
Invoke-Expression $cleanupFunctions[0].Extent.Text
$identityFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Get-CanonicalReleaseGitIdentity', 'Assert-ReleaseSourceIdentity')
}, $true))
if ($identityFunctions.Count -ne 2) {
  throw 'Production package script must define the two source-identity audit functions exactly once'
}
foreach ($identityFunctionName in @('Get-CanonicalReleaseGitIdentity', 'Assert-ReleaseSourceIdentity')) {
  $definition = @($identityFunctions | Where-Object { $_.Name -eq $identityFunctionName })
  if ($definition.Count -ne 1) {
    throw "Production package script source-identity function is ambiguous: $identityFunctionName"
  }
  Invoke-Expression $definition[0].Extent.Text
}

foreach ($required in @(
  "New-ShortReleaseScratchPath -Label 'release-src'",
  "worktree', 'add', '--detach', `$releaseSourceRoot, `$canonicalBuildCommit",
  'Push-Location $releaseSourceRoot',
  '$packageTrackedSourceRoot = if ($SkipBuild) { [string]$repoRoot } else { [string]$releaseSourceRoot }',
  'Copy-StackchanCommitBoundPackageFile',
  'Copy-StackchanCommitBoundLfsPackageFile',
  '-GitCommonDir $releaseGitCommonDir',
  'offline-local-lfs-object-bound-to-commit-pointer-v1',
  'voiceRvcSourceBindings = @($voiceRvcSourceBindings)',
  '$releaseToolsRoot = if ($SkipBuild)',
  '-Phase "final commit-bound package source staging"',
  '-Phase "final release checkout audit"',
  'Remove-ReleaseSourceWorktree',
  '-RejectIgnored',
  '--ignored=matching',
  '--ignore-submodules=none',
  'packageSourceIsolationPolicy',
  'detached-clean-worktree-pinned-to-package-commit'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Release source-binding contract is missing: $required"
  }
}
if ($packageText.Contains('Join-Path $repoRoot ([string]$asset.source_path)')) {
  throw 'Persona WAV packaging still reads from the mutable main checkout'
}
$sourceCleanupFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Remove-ReleaseSourceWorktree'
}, $true))
if ($sourceCleanupFunctions.Count -ne 1) {
  throw 'Commit-bound package source cleanup function is missing or ambiguous.'
}
$sourceCleanupText = $sourceCleanupFunctions[0].Extent.Text
if (-not $sourceCleanupText.Contains('full-failed-worktree-retained-attached') -or
    -not $sourceCleanupText.Contains('is a package failure; the full worktree remains attached') -or
    -not $sourceCleanupText.Contains('source root is missing while its worktree is registered') -or
    -not $sourceCleanupText.Contains('final state cannot be audited') -or
    $sourceCleanupText.Contains("'worktree', 'remove', '--force'")) {
  throw 'Commit-bound package source drift is not retained as a complete attached worktree'
}
foreach ($required in @(
  'packageSourceIsolationPolicy -ne "detached-clean-worktree-pinned-to-package-commit"',
  'packageSourceCommit -cne $ExpectedCommit',
  'packageSourceEpoch',
  "'cat-file', 'blob', `$pointerBlob",
  'Get-StackchanUtf8GitBlobHash',
  'LFS pointer reconstruction does not match the exact commit blob',
  'ConvertTo-StackchanCanonicalLfsPointerRecord',
  'Assert-StackchanPackageLfsPayloadMatchesPointerRecord',
  'Assert-StackchanLfsSourceBindingRecord'
)) {
  if (-not $verifyText.Contains($required)) {
    throw "Release source-binding verifier is missing: $required"
  }
}
if ($verifyText.Contains('-SourcePaths $lfsMediaSources') -or
    $verifyText.Contains('-CommitPointerRoot $resolvedVerifierRoot')) {
  throw 'Operational verifier still depends on hydrated working-tree bytes for LFS binding.'
}
$sourceCreationIndex = $packageText.IndexOf("New-ShortReleaseScratchPath -Label 'release-src'")
$sourcePushIndex = $packageText.IndexOf('Push-Location $releaseSourceRoot')
$firstTrackedCopyIndex = $packageText.IndexOf('Copy-Item -LiteralPath "README.md"')
$finalVerifierCommands = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    @($node.CommandElements | Where-Object {
      $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Splatted -and $_.VariablePath.UserPath -ceq 'packageVerifyArgs'
    }).Count -eq 1
}, $true))
if ($finalVerifierCommands.Count -ne 1) {
  throw 'Final package verifier invocation is structurally ambiguous'
}
$finalVerifierIndex = $finalVerifierCommands[0].Extent.StartOffset
$sourceRemovalIndex = $packageText.LastIndexOf('Remove-ReleaseSourceWorktree')
if ($sourceCreationIndex -lt 0 -or $sourcePushIndex -le $sourceCreationIndex -or
    $firstTrackedCopyIndex -le $sourcePushIndex -or $sourceRemovalIndex -le $finalVerifierIndex) {
  throw "Commit-bound source lifetime/order is invalid"
}
$topLevelStatements = @($packageAst.EndBlock.Statements)
$hashAssignments = @($topLevelStatements | Where-Object {
  $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -eq '$hashLines'
})
if ($hashAssignments.Count -ne 1) {
  throw 'Final package hashing boundary is ambiguous'
}
$hashStatementIndex = [array]::IndexOf($topLevelStatements, $hashAssignments[0])
$finalAuditGuard = if ($hashStatementIndex -gt 0) {
  $topLevelStatements[$hashStatementIndex - 1]
} else {
  $null
}
if ($finalAuditGuard -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $finalAuditGuard.Clauses.Count -ne 1 -or
    $finalAuditGuard.Clauses[0].Item1.Extent.Text -ne '-not $SkipBuild') {
  throw 'Final release source audit must be the direct top-level predecessor of package hashing'
}
$finalAuditStatements = @($finalAuditGuard.Clauses[0].Item2.Statements)
$lastFinalAuditStatement = if ($finalAuditStatements.Count -gt 0) {
  $finalAuditStatements[-1]
} else {
  $null
}
$lastFinalAuditCommand = if ($lastFinalAuditStatement -is [System.Management.Automation.Language.PipelineAst] -and
    $lastFinalAuditStatement.PipelineElements.Count -eq 1 -and
    $lastFinalAuditStatement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst]) {
  $lastFinalAuditStatement.PipelineElements[0]
} else {
  $null
}
$lastFinalAuditParameters = if ($null -ne $lastFinalAuditCommand) {
  @($lastFinalAuditCommand.CommandElements |
    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
    ForEach-Object { $_.ParameterName })
} else {
  @()
}
if ($null -eq $lastFinalAuditCommand -or
    $lastFinalAuditCommand.GetCommandName() -ne 'Assert-ReleaseSourceIdentity' -or
    $lastFinalAuditParameters -notcontains 'RejectIgnored' -or
    $lastFinalAuditCommand.Extent.Text -notmatch '(?m)-Phase\s+"final commit-bound package source staging"' -or
    $lastFinalAuditCommand.Extent.Text -notmatch '(?m)-ProjectRoot\s+\$releaseSourceRoot') {
  throw 'Final package hash/ZIP/verifier chain is not immediately preceded by the reachable ignored-file source audit'
}
$zipCreationCommands = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'New-StackchanDeterministicReleaseZip' -and
    $node.Extent.Text -match '(?m)-RootPath\s+\$outDir\s+-ZipPath\s+\$zipPath'
}, $true))
if ($zipCreationCommands.Count -ne 1 -or
    $zipCreationCommands[0].Extent.StartOffset -le $hashAssignments[0].Extent.EndOffset -or
    $finalVerifierCommands[0].Extent.StartOffset -le $zipCreationCommands[0].Extent.EndOffset) {
  throw 'Final ignored-file audit does not govern the package hash, ZIP, and final verifier in one ordered chain'
}

$lfsFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-lfs-source-binding-contract-' + [guid]::NewGuid().ToString('N'))
try {
  $pointerRoot = Join-Path $lfsFixtureRoot 'pointer'
  $pointerRelative = 'media/voice/rvc/model.bin'
  $pointerPath = Join-Path $pointerRoot $pointerRelative
  $gitCommonDir = Join-Path $lfsFixtureRoot 'git-common'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pointerPath), $gitCommonDir | Out-Null
  $payload = [byte[]](0..255)
  $payloadHasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $payloadHash = [System.BitConverter]::ToString(
      $payloadHasher.ComputeHash($payload)).Replace('-', '').ToLowerInvariant()
  } finally {
    $payloadHasher.Dispose()
  }
  $pointerText = "version https://git-lfs.github.com/spec/v1`noid sha256:$payloadHash`nsize $($payload.Length)`n"
  $canonicalPointerBlob = Get-StackchanUtf8GitBlobHash -Text $pointerText -HashLength 40
  $crlfPointerBlob = Get-StackchanUtf8GitBlobHash `
    -Text $pointerText.Replace("`n", "`r`n") -HashLength 40
  $missingFinalLfBlob = Get-StackchanUtf8GitBlobHash `
    -Text $pointerText.TrimEnd("`n") -HashLength 40
  if ($canonicalPointerBlob -eq $crlfPointerBlob -or
      $canonicalPointerBlob -eq $missingFinalLfBlob) {
    throw 'Canonical pointer Git-blob proof did not distinguish exact line-ending bytes.'
  }
  [System.IO.File]::WriteAllText(
    $pointerPath, $pointerText, (New-Object System.Text.UTF8Encoding($false)))
  $objectPath = Join-Path $gitCommonDir (
    "lfs/objects/$($payloadHash.Substring(0, 2))/$($payloadHash.Substring(2, 2))/$payloadHash")
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $objectPath) | Out-Null
  [System.IO.File]::WriteAllBytes($objectPath, $payload)

  $destination = Join-Path $lfsFixtureRoot 'package/model.bin'
  $binding = Copy-StackchanCommitBoundLfsPackageFile `
    -CommitPointerRoot $pointerRoot `
    -GitCommonDir $gitCommonDir `
    -RelativePath $pointerRelative `
    -DestinationPath $destination `
    -ExpectedBytes $payload.Length `
    -ExpectedSha256 $payloadHash
  if ([string]$binding.sha256 -cne $payloadHash.ToUpperInvariant() -or
      [int64]$binding.bytes -ne $payload.Length -or
      -not [System.Linq.Enumerable]::SequenceEqual(
        [byte[]][System.IO.File]::ReadAllBytes($destination), $payload)) {
    throw 'Commit-bound LFS copy did not produce the exact pointer-bound payload.'
  }
  Assert-StackchanPackageLfsPayloadMatchesCommitPointer `
    -CommitPointerRoot $pointerRoot -RelativePath $pointerRelative -PackagePath $destination

  foreach ($case in @(
      'wrong-reviewed-hash', 'corrupt-object', 'malformed-pointer',
      'missing-final-lf', 'missing-object')) {
    $casePointerRoot = Join-Path $lfsFixtureRoot "pointer-$case"
    $casePointerPath = Join-Path $casePointerRoot $pointerRelative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $casePointerPath) | Out-Null
    $casePointerText = if ($case -eq 'malformed-pointer') {
      $pointerText + "extension unreviewed`n"
    } elseif ($case -eq 'missing-final-lf') {
      $pointerText.TrimEnd("`n")
    } else {
      $pointerText
    }
    [System.IO.File]::WriteAllText(
      $casePointerPath, $casePointerText, (New-Object System.Text.UTF8Encoding($false)))
    $caseCommonDir = if ($case -eq 'missing-object') {
      $missingCommon = Join-Path $lfsFixtureRoot 'missing-git-common'
      New-Item -ItemType Directory -Force -Path (Join-Path $missingCommon 'lfs/objects') | Out-Null
      $missingCommon
    } else {
      $gitCommonDir
    }
    if ($case -eq 'corrupt-object') {
      [System.IO.File]::WriteAllBytes($objectPath, [byte[]](255..0))
    }
    $caseDestination = Join-Path $lfsFixtureRoot "package-$case/model.bin"
    try {
      Copy-StackchanCommitBoundLfsPackageFile `
        -CommitPointerRoot $casePointerRoot `
        -GitCommonDir $caseCommonDir `
        -RelativePath $pointerRelative `
        -DestinationPath $caseDestination `
        -ExpectedBytes $payload.Length `
        -ExpectedSha256 $(if ($case -eq 'wrong-reviewed-hash') { '0' * 64 } else { $payloadHash }) | Out-Null
      throw "Commit-bound LFS copy accepted invalid fixture: $case"
    } catch {
      if ($_.Exception.Message -eq "Commit-bound LFS copy accepted invalid fixture: $case") { throw }
    } finally {
      if ($case -eq 'corrupt-object') {
        [System.IO.File]::WriteAllBytes($objectPath, $payload)
      }
    }
    if ((Test-Path -LiteralPath $caseDestination) -or
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $caseDestination) `
          -Filter '*.lfs-stage-*' -Force -ErrorAction SilentlyContinue).Count -ne 0) {
      throw "Failed commit-bound LFS copy retained output: $case"
    }
  }
  try {
    Copy-StackchanCommitBoundLfsPackageFile `
      -CommitPointerRoot $pointerRoot -GitCommonDir $gitCommonDir `
      -RelativePath '../model.bin' -DestinationPath (Join-Path $lfsFixtureRoot 'escape.bin') `
      -ExpectedBytes $payload.Length -ExpectedSha256 $payloadHash | Out-Null
    throw 'Commit-bound LFS copy accepted traversal.'
  } catch {
    if ($_.Exception.Message -eq 'Commit-bound LFS copy accepted traversal.') { throw }
  }

  [System.IO.File]::WriteAllBytes($pointerPath, $payload)
  $commitPointerRecord = ConvertTo-StackchanCanonicalLfsPointerRecord `
    -PointerText $pointerText -RelativePath $pointerRelative
  Assert-StackchanPackageLfsPayloadMatchesPointerRecord `
    -Pointer $commitPointerRecord -PackagePath $destination
  try {
    Get-StackchanCommitBoundLfsPointerRecord `
      -CommitPointerRoot $pointerRoot -RelativePath $pointerRelative | Out-Null
    throw 'Hydrated-checkout regression fixture unexpectedly parsed working payload bytes as a pointer.'
  } catch {
    if ($_.Exception.Message -eq
        'Hydrated-checkout regression fixture unexpectedly parsed working payload bytes as a pointer.') {
      throw
    }
  }

  $expectedCommit = 'a' * 40
  $expectedPointerBlob = 'b' * 40
  $validManifestBinding = [pscustomobject]@{
    sourcePath = $pointerRelative
    sourceCommit = $expectedCommit
    pointerBlob = $expectedPointerBlob
    bytes = $commitPointerRecord.bytes
    sha256 = $commitPointerRecord.sha256
    policy = 'offline-local-lfs-object-bound-to-commit-pointer-v1'
  }
  Assert-StackchanLfsSourceBindingRecord `
    -ManifestBindings @($validManifestBinding) `
    -SourcePath $pointerRelative `
    -ExpectedCommit $expectedCommit `
    -PointerBlob $expectedPointerBlob `
    -Pointer $commitPointerRecord
  $invalidManifestBindings = [System.Collections.Generic.List[object]]::new()
  $invalidManifestBindings.Add([object[]]@([pscustomobject]@{
      sourcePath = $pointerRelative; sourceCommit = ('c' * 40); pointerBlob = $expectedPointerBlob
      bytes = $commitPointerRecord.bytes; sha256 = $commitPointerRecord.sha256
      policy = 'offline-local-lfs-object-bound-to-commit-pointer-v1'
    })) | Out-Null
  $invalidManifestBindings.Add([object[]]@([pscustomobject]@{
      sourcePath = $pointerRelative; sourceCommit = $expectedCommit; pointerBlob = ('d' * 40)
      bytes = $commitPointerRecord.bytes; sha256 = $commitPointerRecord.sha256
      policy = 'offline-local-lfs-object-bound-to-commit-pointer-v1'
    })) | Out-Null
  $invalidManifestBindings.Add([object[]]@([pscustomobject]@{
      sourcePath = $pointerRelative; sourceCommit = $expectedCommit; pointerBlob = $expectedPointerBlob
      bytes = $commitPointerRecord.bytes; sha256 = ('E' * 64)
      policy = 'offline-local-lfs-object-bound-to-commit-pointer-v1'
    })) | Out-Null
  $invalidManifestBindings.Add(
    [object[]]@($validManifestBinding, $validManifestBinding)) | Out-Null
  foreach ($invalidBindings in $invalidManifestBindings) {
    try {
      Assert-StackchanLfsSourceBindingRecord `
        -ManifestBindings @($invalidBindings) `
        -SourcePath $pointerRelative `
        -ExpectedCommit $expectedCommit `
        -PointerBlob $expectedPointerBlob `
        -Pointer $commitPointerRecord
      throw 'RVC LFS manifest binding accepted mutated or duplicate evidence.'
    } catch {
      if ($_.Exception.Message -eq
          'RVC LFS manifest binding accepted mutated or duplicate evidence.') {
        throw
      }
    }
  }
} finally {
  if (Test-Path -LiteralPath $lfsFixtureRoot) {
    [System.IO.Directory]::Delete($lfsFixtureRoot, $true)
  }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  "stackchan-source-binding-contract-" + [guid]::NewGuid().ToString("N"))
$main = Join-Path $root "main"
$snapshot = Join-Path $root "snapshot"
try {
  New-Item -ItemType Directory -Force -Path $main | Out-Null
  & git -C $main init -q
  & git -C $main config user.name "Stackchan Contract"
  & git -C $main config user.email "contract@example.invalid"
  & git -C $main config core.autocrlf false
  [System.IO.File]::WriteAllText((Join-Path $main 'tracked.txt'), "commit-a`n")
  [System.IO.File]::WriteAllText((Join-Path $main '.gitignore'), "personas/private/`n")
  New-Item -ItemType Directory -Path (Join-Path $main 'personas/spark/audio') -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $main 'personas/spark/audio/prompt.wav'), [byte[]](1, 2, 3, 4))
  & git -C $main add tracked.txt
  & git -C $main add .gitignore
  & git -C $main add personas/spark/audio/prompt.wav
  & git -C $main commit -q -m "commit a"
  $commitA = (& git -C $main rev-parse HEAD).Trim()
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & git -C $main worktree add --detach $snapshot $commitA 2>&1 | Out-Null
    $worktreeExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($worktreeExit -ne 0) { throw "Could not create source-binding fixture worktree" }

  [System.IO.File]::WriteAllText((Join-Path $main 'tracked.txt'), "commit-b`n")
  [System.IO.File]::WriteAllBytes((Join-Path $main 'personas/spark/audio/prompt.wav'), [byte[]](9, 8, 7, 6))
  [System.IO.File]::WriteAllText((Join-Path $main 'untracked.txt'), "must-not-package`n")
  & git -C $main add tracked.txt
  & git -C $main commit -q -m "commit b"

  if ((Get-Content -LiteralPath (Join-Path $snapshot 'tracked.txt') -Raw) -ne "commit-a`n") {
    throw "Detached package source changed with the mutable main worktree"
  }
  if (Test-Path -LiteralPath (Join-Path $snapshot 'untracked.txt')) {
    throw "Mutable untracked main-worktree content entered the package source"
  }
  $packagedPrompt = Join-Path $root 'package/media/voice/prompt.wav'
  Copy-StackchanCommitBoundPackageFile `
    -PackageSourceRoot $snapshot `
    -RelativePath 'personas/spark/audio/prompt.wav' `
    -DestinationPath $packagedPrompt
  if (-not [System.Linq.Enumerable]::SequenceEqual(
      [byte[]][System.IO.File]::ReadAllBytes($packagedPrompt),
      [byte[]](1, 2, 3, 4))) {
    throw "Production commit-bound copy helper read mutable main-worktree WAV bytes"
  }
  try {
    Copy-StackchanCommitBoundPackageFile `
      -PackageSourceRoot $snapshot -RelativePath '../tracked.txt' `
      -DestinationPath (Join-Path $root 'escaped.txt')
    throw "Production commit-bound copy helper accepted traversal"
  } catch {
    if ($_.Exception.Message -eq "Production commit-bound copy helper accepted traversal") { throw }
  }
  if ((& git -C $snapshot rev-parse HEAD).Trim() -cne $commitA -or
      @(& git -C $snapshot status --porcelain=v1 --untracked-files=all).Count -ne 0) {
    throw "Detached package source lost its clean commit identity"
  }

  $script:releaseSourceLocationPushed = $false
  $script:releaseSourceWorktreeAdded = $true
  $script:releaseSourceRoot = Join-Path $root 'missing-release-source'
  try {
    Remove-ReleaseSourceWorktree
    throw 'Production cleanup accepted a missing registered worktree'
  } catch {
    if ($_.Exception.Message -eq 'Production cleanup accepted a missing registered worktree') { throw }
    if ($_.Exception.Message -notmatch 'final state cannot be audited') {
      throw "Production cleanup returned the wrong missing-worktree failure: $($_.Exception.Message)"
    }
  }

  function Invoke-ReleaseGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & git @Arguments
  }
  $ignoredPayload = Join-Path $snapshot 'personas/private/hitchhiker.bin'
  New-Item -ItemType Directory -Path (Split-Path -Parent $ignoredPayload) -Force | Out-Null
  [System.IO.File]::WriteAllText($ignoredPayload, 'must-not-package')
  $hitchhikeCopy = Join-Path $root 'hitchhike-package/personas'
  Copy-Item -LiteralPath (Join-Path $snapshot 'personas') -Destination $hitchhikeCopy -Recurse
  if (-not (Test-Path -LiteralPath (Join-Path $hitchhikeCopy 'private/hitchhiker.bin'))) {
    throw 'Ignored-file fixture did not reproduce the broad recursive-copy risk'
  }
  $snapshotEpoch = (& git -C $snapshot show -s --format=%ct $commitA).Trim()
  $archiveMarker = Join-Path $root 'ARCHIVE_CREATED.txt'
  try {
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $commitA `
      -ExpectedEpoch $snapshotEpoch `
      -Phase 'contract pre-archive audit' `
      -ProjectRoot $snapshot `
      -RejectIgnored
    [System.IO.File]::WriteAllText($archiveMarker, 'archive-created')
    throw 'Production source audit accepted an ignored hitchhiker before archive creation'
  } catch {
    if ($_.Exception.Message -eq 'Production source audit accepted an ignored hitchhiker before archive creation') {
      throw
    }
    if ($_.Exception.Message -notmatch 'not clean during contract pre-archive audit') {
      throw "Production source audit returned the wrong ignored-file failure: $($_.Exception.Message)"
    }
  }
  if (Test-Path -LiteralPath $archiveMarker) {
    throw 'Archive side effect occurred after an ignored package-source hitchhiker was planted'
  }
  $script:releaseSourceLocationPushed = $false
  $script:releaseSourceWorktreeAdded = $true
  $script:releaseSourceRoot = $snapshot
  $script:releaseSourceFailureRecorded = $false
  $canonicalBuildCommit = $commitA
  $repoRoot = $main
  $driftFailureRoot = Join-Path $main 'output/private/package-source-failures'
  try {
    Remove-ReleaseSourceWorktree
    throw 'Production cleanup accepted commit-bound source drift'
  } catch {
    if ($_.Exception.Message -eq 'Production cleanup accepted commit-bound source drift') { throw }
    if ($_.Exception.Message -notmatch 'source drift is a package failure') {
      throw "Production cleanup returned the wrong drift failure: $($_.Exception.Message)"
    }
  }
  $attachedWorktrees = @(& git -C $main worktree list --porcelain |
    Where-Object { $_.StartsWith('worktree ') } |
    ForEach-Object { $_.Substring('worktree '.Length).Replace('/', '\') })
  if (-not (Test-Path -LiteralPath $snapshot) -or
      -not (Test-Path -LiteralPath $ignoredPayload) -or
      $attachedWorktrees -notcontains $snapshot) {
    throw 'Production cleanup did not retain the complete drifted worktree attached'
  }
  $failureEvidence = @(Get-ChildItem -LiteralPath $driftFailureRoot -Filter FAILURE_EVIDENCE.json -Recurse -File)
  if ($failureEvidence.Count -ne 1 -or
      (Get-Content -LiteralPath $failureEvidence[0].FullName -Raw) -notmatch
        'commit-bound-source-drift-full-worktree-preserved') {
    throw 'Production cleanup did not preserve commit-bound source drift evidence'
  }
  & git -C $main worktree remove --force $snapshot
  if ($LASTEXITCODE -ne 0) { throw "Could not remove source-binding fixture worktree" }
} finally {
  if ((Test-Path -LiteralPath (Join-Path $main '.git')) -and
      (Test-Path -LiteralPath $snapshot)) {
    & git -C $main worktree remove --force $snapshot 2>$null
  }
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.IsReadOnly = $false }
    [System.IO.Directory]::Delete($root, $true)
  }
}

Write-Host "Release source-binding contract passed."
