param(
  [Parameter(Mandatory = $true)][string]$DefaultCoreDir,
  [Parameter(Mandatory = $true)][string]$ReleaseCoreDir,
  [Parameter(Mandatory = $true)][string]$PlatformioExecutable,
  [Parameter(Mandatory = $true)][string]$PythonExecutable,
  [Parameter(Mandatory = $true)][string]$GitExecutable,
  [string]$LibdepsRoot,
  [string]$ProjectRoot,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$resolvedProjectRoot = (Get-Item -LiteralPath $ProjectRoot -Force -ErrorAction Stop).FullName
$candidateRoot = Join-Path $resolvedProjectRoot 'output/private/toolchain-identity-candidates'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
  $OutputPath = Join-Path $candidateRoot (
    'release_toolchain_identity_allowlist_candidate_' +
    (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json')
}
if ([string]::IsNullOrWhiteSpace($LibdepsRoot)) {
  $LibdepsRoot = Join-Path $resolvedProjectRoot '.pio/libdeps'
}
$trackedAllowlist = [IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot 'tools/release_toolchain_identity_allowlist.json'))
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ($resolvedOutput.Equals($trackedAllowlist, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Candidate generation refuses to overwrite the reviewed allowlist. Generate under output/private, review the diff, and update the tracked file explicitly.'
}
$resolvedCandidateRoot = [IO.Path]::GetFullPath($candidateRoot).TrimEnd('\', '/')
$candidatePrefix = $resolvedCandidateRoot + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedOutput.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolvedOutput) -notmatch '^release_toolchain_identity_allowlist_candidate_[0-9]{8}-[0-9]{6}\.json$' -or
    (Test-Path -LiteralPath $resolvedOutput)) {
  throw 'Candidate output must be one fresh timestamped JSON file under output/private/toolchain-identity-candidates.'
}
New-Item -ItemType Directory -Force -Path $resolvedCandidateRoot | Out-Null
$candidateRootItem = Get-Item -LiteralPath $resolvedCandidateRoot -Force
if (-not $candidateRootItem.PSIsContainer -or
    ($candidateRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'Candidate output root must be one real private directory.'
}

$pythonHome = Split-Path -Parent (Split-Path -Parent (
  (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName))
$resolvedGit = (Get-Item -LiteralPath $GitExecutable -Force -ErrorAction Stop).FullName
$gitHome = Split-Path -Parent (Split-Path -Parent $resolvedGit)
$rootMap = @{
  pythonHome = $pythonHome
  gitHome = $gitHome
  legacyCore = (Get-Item -LiteralPath $DefaultCoreDir -Force -ErrorAction Stop).FullName
  releaseCore = (Get-Item -LiteralPath $ReleaseCoreDir -Force -ErrorAction Stop).FullName
  projectRoot = $resolvedProjectRoot
  libdepsRoot = (Get-Item -LiteralPath $LibdepsRoot -Force -ErrorAction Stop).FullName
}
$candidate = New-StackchanReleaseToolchainIdentityCandidate `
  -RootMap $rootMap `
  -PlatformioExecutable $PlatformioExecutable `
  -PythonExecutable $PythonExecutable `
  -GitExecutable $resolvedGit
$candidateJson = $candidate | ConvertTo-Json -Depth 8
$stream = [IO.File]::Open(
  $resolvedOutput, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
try {
  $writer.WriteLine($candidateJson)
} finally {
  $writer.Dispose()
  $stream.Dispose()
}
Write-Output $resolvedOutput
