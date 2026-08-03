param(
  [Parameter(Mandatory = $true)][string]$DefaultCoreDir,
  [Parameter(Mandatory = $true)][string]$ReleaseCoreDir,
  [Parameter(Mandatory = $true)][string]$PlatformioExecutable,
  [Parameter(Mandatory = $true)][string]$PythonExecutable,
  [string]$ProjectRoot,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $candidateRoot = Join-Path $ProjectRoot 'output/private/toolchain-identity-candidates'
  New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
  $OutputPath = Join-Path $candidateRoot (
    'release_toolchain_identity_allowlist_candidate_' +
    (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json')
}
$resolvedProjectRoot = (Get-Item -LiteralPath $ProjectRoot -Force -ErrorAction Stop).FullName
$trackedAllowlist = [IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot 'tools/release_toolchain_identity_allowlist.json'))
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ($resolvedOutput.Equals($trackedAllowlist, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Candidate generation refuses to overwrite the reviewed allowlist. Generate under output/private, review the diff, and update the tracked file explicitly.'
}

$pythonHome = Split-Path -Parent (Split-Path -Parent (
  (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName))
$rootMap = @{
  pythonHome = $pythonHome
  legacyCore = (Get-Item -LiteralPath $DefaultCoreDir -Force -ErrorAction Stop).FullName
  releaseCore = (Get-Item -LiteralPath $ReleaseCoreDir -Force -ErrorAction Stop).FullName
  projectRoot = $resolvedProjectRoot
}
$candidate = New-StackchanReleaseToolchainIdentityCandidate `
  -RootMap $rootMap `
  -PlatformioExecutable $PlatformioExecutable `
  -PythonExecutable $PythonExecutable
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
Write-Output $resolvedOutput
