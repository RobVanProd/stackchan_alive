$ErrorActionPreference = 'Stop'

$packagePath = Join-Path $PSScriptRoot 'package_release.ps1'
$verifyPath = Join-Path $PSScriptRoot 'verify_release_package.ps1'
$gitTrustPath = Join-Path $PSScriptRoot 'release_git_trust.ps1'
$platformioResolverPath = Join-Path $PSScriptRoot 'platformio_resolver.ps1'
$previewPythonResolverPath = Join-Path $PSScriptRoot 'preview_python_resolver.ps1'
$packageText = Get-Content -LiteralPath $packagePath -Raw
$verifyText = Get-Content -LiteralPath $verifyPath -Raw
$gitTrustText = Get-Content -LiteralPath $gitTrustPath -Raw
$platformioResolverText = Get-Content -LiteralPath $platformioResolverPath -Raw
$previewPythonResolverText = Get-Content -LiteralPath $previewPythonResolverPath -Raw

foreach ($scriptPath in @(
  $packagePath, $verifyPath, $gitTrustPath, $platformioResolverPath,
  $previewPythonResolverPath
)) {
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -ne 0) {
    throw "Release command-trust input does not parse: $scriptPath"
  }
}

$packageFailureOffset = $packageText.IndexOf('Assert-StackchanReleaseToolchainIdentity', [StringComparison]::Ordinal)
$packageGitOffset = $packageText.IndexOf(
  '$releaseBootstrapGitCommand = Get-Command', [StringComparison]::Ordinal)
if ($packageFailureOffset -lt 0 -or $packageGitOffset -lt 0 -or
    $packageFailureOffset -ge $packageGitOffset -or
    -not $packageText.Contains('pre-Git byte authority mismatch')) {
  throw 'Release-grade packaging does not authenticate exact toolchain bytes before Git resolution.'
}
$verifyFailureOffset = $verifyText.IndexOf('Assert-StackchanReleaseToolchainIdentity', [StringComparison]::Ordinal)
$verifyGitOffset = $verifyText.IndexOf('$trustedGitCommand = Get-Command', [StringComparison]::Ordinal)
if ($verifyFailureOffset -lt 0 -or $verifyGitOffset -lt 0 -or
    $verifyFailureOffset -ge $verifyGitOffset -or
    -not $verifyText.Contains('pre-Git byte authority mismatch')) {
  throw 'Release-eligible verification does not authenticate exact toolchain bytes before Git resolution.'
}

foreach ($forbidden in @('& powershell.exe', '& subst.exe', '& tar.exe', 'git-lfs')) {
  if ($packageText.Contains($forbidden) -or $verifyText.Contains($forbidden) -or
      $gitTrustText.Contains($forbidden)) {
    throw "Release command trust contains a forbidden ambient command path: $forbidden"
  }
}
foreach ($required in @(
  '[Environment]::SystemDirectory', 'New-StackchanDeterministicReleaseZip',
  '[System.IO.Compression.ZipArchive]', '[System.IO.FileMode]::CreateNew'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Release packaging is missing deterministic command/archive trust: $required"
  }
}
if (-not $verifyText.Contains('[Environment]::SystemDirectory') -or
    -not $verifyText.Contains('& $verifierPowerShellExecutable')) {
  throw 'Release verification does not pin Windows PowerShell to its validated system path.'
}
foreach ($required in @(
  '[Parameter(Mandatory = $true)][string]$GitExecutable',
  '& $resolvedGitExecutable @gitArguments', 'filter.lfs.process=',
  'filter.lfs.smudge=', 'filter.lfs.clean=', 'filter.lfs.required=false'
)) {
  if (-not $gitTrustText.Contains($required)) {
    throw "Trusted Git wrapper is missing pinned/LFS-disabled behavior: $required"
  }
}
if ($gitTrustText.Contains('Get-Command') -or $gitTrustText.Contains('PinLfsFilter')) {
  throw 'Trusted Git wrapper must not re-resolve Git or optionally enable LFS.'
}
foreach ($resolver in @(
  [pscustomobject]@{ label = 'PlatformIO'; text = $platformioResolverText },
  [pscustomobject]@{ label = 'preview Python'; text = $previewPythonResolverText }
)) {
  foreach ($required in @('-CommandType Application', 'FileAttributes]::ReparsePoint', "-cne '.exe'")) {
    if (-not $resolver.text.Contains($required)) {
      throw "$($resolver.label) resolver does not require an exact application executable: $required"
    }
  }
}

$packageTokens = $null
$packageParseErrors = $null
$packageAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $packagePath, [ref]$packageTokens, [ref]$packageParseErrors)
$zipFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'New-StackchanDeterministicReleaseZip'
}, $true))
if ($zipFunctions.Count -ne 1) {
  throw 'Deterministic release ZIP function is ambiguous.'
}
. ([scriptblock]::Create($zipFunctions[0].Extent.Text))

$contractRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-release-command-trust-' + [guid]::NewGuid().ToString('N'))
try {
  $treeOne = Join-Path $contractRoot 'tree-one'
  $treeTwo = Join-Path $contractRoot 'tree-two'
  [System.IO.Directory]::CreateDirectory((Join-Path $treeOne 'nested')) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $treeTwo 'nested')) | Out-Null
  foreach ($tree in @($treeOne, $treeTwo)) {
    [System.IO.File]::WriteAllText(
      (Join-Path $tree 'z-last.txt'), "last`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
      (Join-Path $tree 'nested/a-first.txt'), "first`n", [System.Text.UTF8Encoding]::new($false))
  }
  $zipOne = Join-Path $contractRoot 'one.zip'
  $zipTwo = Join-Path $contractRoot 'two.zip'
  $entriesOne = @(New-StackchanDeterministicReleaseZip `
    -RootPath $treeOne -ZipPath $zipOne -SourceEpoch 1700000001)
  $entriesTwo = @(New-StackchanDeterministicReleaseZip `
    -RootPath $treeTwo -ZipPath $zipTwo -SourceEpoch 1700000001)
  if ((Get-FileHash -LiteralPath $zipOne -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath $zipTwo -Algorithm SHA256).Hash) {
    throw 'Deterministic release ZIP bytes differ for identical trees and source epochs.'
  }
  $expectedEntries = @('nested/a-first.txt', 'z-last.txt')
  if ((Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $entriesOne `
      -CaseSensitive -SyncWindow 0).Count -ne 0 -or
      (Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $entriesTwo `
      -CaseSensitive -SyncWindow 0).Count -ne 0) {
    throw 'Deterministic release ZIP central-directory order is not ordinal and stable.'
  }

  $systemDirectory = [System.IO.Path]::GetFullPath([Environment]::SystemDirectory)
  $systemPowerShell = Join-Path $systemDirectory 'WindowsPowerShell/v1.0/powershell.exe'
  if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) {
    throw 'Command-trust behavior contract requires Windows PowerShell.'
  }
  $markerRoot = Join-Path $contractRoot 'markers'
  [System.IO.Directory]::CreateDirectory($markerRoot) | Out-Null
  $behaviorScript = Join-Path $contractRoot 'front-door-behavior.ps1'
  $behaviorSource = @'
param(
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$MarkerRoot,
  [switch]$Verifier
)
$ErrorActionPreference = 'Stop'
function global:git { [IO.File]::WriteAllText((Join-Path $MarkerRoot 'git.txt'), 'executed') }
function global:powershell.exe { [IO.File]::WriteAllText((Join-Path $MarkerRoot 'powershell.txt'), 'executed') }
function global:subst.exe { [IO.File]::WriteAllText((Join-Path $MarkerRoot 'subst.txt'), 'executed') }
function global:tar.exe { [IO.File]::WriteAllText((Join-Path $MarkerRoot 'tar.txt'), 'executed') }
try {
  if ($Verifier) {
    & $Target -RequireReleaseEligible
  } else {
    & $Target -Version 'command-trust-contract'
  }
  throw 'front door unexpectedly succeeded'
} catch {
  $message = $_.Exception.Message
  if ($Verifier) {
    if ($message -notlike '*Release-eligible verification requires explicit -GitExecutable authority*') { throw }
  } elseif ($message -notlike '*Release packaging requires explicit -GitExecutable authority*') {
    throw
  }
}
'@
  [System.IO.File]::WriteAllText(
    $behaviorScript, $behaviorSource, [System.Text.UTF8Encoding]::new($false))
  & $systemPowerShell -NoProfile -ExecutionPolicy Bypass -File $behaviorScript `
    -Target $packagePath -MarkerRoot $markerRoot
  if ($LASTEXITCODE -ne 0) { throw 'Release package front-door hostile behavior probe failed.' }
  & $systemPowerShell -NoProfile -ExecutionPolicy Bypass -File $behaviorScript `
    -Target $verifyPath -MarkerRoot $markerRoot -Verifier
  if ($LASTEXITCODE -ne 0) { throw 'Release verifier front-door hostile behavior probe failed.' }
  if (@(Get-ChildItem -LiteralPath $markerRoot -File -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'A hostile ambient command executed before a release front-door refusal.'
  }

  . $gitTrustPath
  $gitApplication = Get-Command -Name git -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
  $gitExecutable = (Resolve-Path -LiteralPath ([string]$gitApplication.Source)).Path
  $gitFunctionMarker = Join-Path $markerRoot 'git-function.txt'
  function global:git { [System.IO.File]::WriteAllText($gitFunctionMarker, 'executed') }
  $disabledHooks = Join-Path $contractRoot 'disabled-hooks-must-not-exist'
  $gitOutput = @(Invoke-StackchanTrustedGit -GitExecutable $gitExecutable `
    -DisabledHooksPath $disabledHooks -Arguments @('--version'))
  if ($LASTEXITCODE -ne 0 -or ($gitOutput | Out-String) -notmatch '^git version ' -or
      (Test-Path -LiteralPath $gitFunctionMarker)) {
    throw 'Trusted Git did not execute its pinned application path.'
  }
  $fakeGit = Join-Path $contractRoot 'git.cmd'
  [System.IO.File]::WriteAllText(
    $fakeGit, "@echo executed>$gitFunctionMarker`r`n", [System.Text.Encoding]::ASCII)
  try {
    Invoke-StackchanTrustedGit -GitExecutable $fakeGit `
      -DisabledHooksPath $disabledHooks -Arguments @('--version')
    throw 'Trusted Git accepted a command-script shim.'
  } catch {
    if ($_.Exception.Message -eq 'Trusted Git accepted a command-script shim.') { throw }
  }
  if (Test-Path -LiteralPath $gitFunctionMarker) {
    throw 'Trusted Git executed a rejected command-script shim.'
  }
  Remove-Item Function:\git -Force -ErrorAction SilentlyContinue

  $shimDirectory = Join-Path $contractRoot 'shim-path'
  [System.IO.Directory]::CreateDirectory($shimDirectory) | Out-Null
  $pioMarker = Join-Path $markerRoot 'platformio-shim.txt'
  $pythonMarker = Join-Path $markerRoot 'python-shim.txt'
  [System.IO.File]::WriteAllText(
    (Join-Path $shimDirectory 'platformio.cmd'), "@echo executed>$pioMarker`r`n", [System.Text.Encoding]::ASCII)
  [System.IO.File]::WriteAllText(
    (Join-Path $shimDirectory 'python.cmd'), "@echo executed>$pythonMarker`r`n", [System.Text.Encoding]::ASCII)
  $global:StackchanPioResolverMarker = $pioMarker
  $global:StackchanPythonResolverMarker = $pythonMarker
  function global:platformio {
    [System.IO.File]::WriteAllText($global:StackchanPioResolverMarker, 'function-executed')
  }
  function global:pio {
    [System.IO.File]::WriteAllText($global:StackchanPioResolverMarker, 'function-executed')
  }
  function global:python {
    [System.IO.File]::WriteAllText($global:StackchanPythonResolverMarker, 'function-executed')
  }
  $savedPath = $env:PATH
  $savedLocalAppData = $env:LOCALAPPDATA
  $savedUserProfile = $env:USERPROFILE
  $savedPlatformioExe = $env:PLATFORMIO_EXE
  try {
    $env:PATH = $shimDirectory
    $env:LOCALAPPDATA = $contractRoot
    $env:USERPROFILE = $contractRoot
    Remove-Item Env:\PLATFORMIO_EXE -ErrorAction SilentlyContinue
    . $platformioResolverPath
    . $previewPythonResolverPath
    try {
      Get-StackchanPlatformioCommand | Out-Null
      throw 'PlatformIO resolver accepted a command-script shim.'
    } catch {
      if ($_.Exception.Message -eq 'PlatformIO resolver accepted a command-script shim.') { throw }
    }
    try {
      Get-StackchanPreviewPython | Out-Null
      throw 'Preview Python resolver accepted a command-script shim.'
    } catch {
      if ($_.Exception.Message -eq 'Preview Python resolver accepted a command-script shim.') { throw }
    }
  } finally {
    $env:PATH = $savedPath
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:USERPROFILE = $savedUserProfile
    if ($null -eq $savedPlatformioExe) {
      Remove-Item Env:\PLATFORMIO_EXE -ErrorAction SilentlyContinue
    } else {
      $env:PLATFORMIO_EXE = $savedPlatformioExe
    }
    Remove-Item Function:\platformio, Function:\pio, Function:\python `
      -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name StackchanPioResolverMarker, StackchanPythonResolverMarker `
      -Scope Global -Force -ErrorAction SilentlyContinue
  }
  if ((Test-Path -LiteralPath $pioMarker) -or (Test-Path -LiteralPath $pythonMarker)) {
    throw 'A diagnostic command resolver executed a command-script shim.'
  }
} finally {
  Remove-Item Function:\git -Force -ErrorAction SilentlyContinue
  Remove-Item Function:\platformio, Function:\pio, Function:\python `
    -Force -ErrorAction SilentlyContinue
  Remove-Variable -Name StackchanPioResolverMarker, StackchanPythonResolverMarker `
    -Scope Global -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $contractRoot) {
    [System.IO.Directory]::Delete($contractRoot, $true)
  }
}

Write-Output 'Release command trust contract passed.'
