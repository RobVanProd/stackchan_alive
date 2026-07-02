param(
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

function Get-CommandVersionText {
  param([string]$CommandPath)

  try {
    $output = & $CommandPath --version 2>$null
    if ($LASTEXITCODE -eq 0) {
      return (($output | Select-Object -First 1) | Out-String).Trim()
    }
  } catch {
    return ""
  }
  return ""
}

$candidateReports = @()
foreach ($dir in Get-StackchanNativeCompilerDirs) {
  if ([string]::IsNullOrWhiteSpace($dir)) {
    continue
  }
  $exists = Test-Path -LiteralPath $dir
  $gcc = Join-Path $dir "gcc.exe"
  $gxx = Join-Path $dir "g++.exe"
  $hasGcc = Test-Path -LiteralPath $gcc
  $hasGxx = Test-Path -LiteralPath $gxx
  $candidateReports += [ordered]@{
    path = $dir
    exists = $exists
    hasGcc = $hasGcc
    hasGxx = $hasGxx
    gccVersion = if ($hasGcc) { Get-CommandVersionText $gcc } else { "" }
    gxxVersion = if ($hasGxx) { Get-CommandVersionText $gxx } else { "" }
  }
}

$selected = ""
$status = "missing"
$errorMessage = ""
try {
  $selected = Add-StackchanNativeCompilerToPath
  $status = "ready"
} catch {
  $errorMessage = $_.Exception.Message
}

$report = [ordered]@{
  schema = "stackchan.native-toolchain-check.v1"
  status = $status
  selectedPath = $selected
  path = $env:PATH
  candidates = @($candidateReports)
  installGuidance = @(
    "Install MSYS2 and use C:/msys64/mingw64/bin or C:/msys64/ucrt64/bin.",
    "Or install WinLibs with winget: winget install BrechtSanders.WinLibs.POSIX.UCRT",
    "Or install mingw with Chocolatey/Scoop and re-run this check.",
    "After installing, open a new terminal or add the compiler bin directory to PATH."
  )
  error = $errorMessage
}

if ($Json) {
  $report | ConvertTo-Json -Depth 6
} else {
  Write-Host "Native compiler toolchain: $status"
  if (-not [string]::IsNullOrWhiteSpace($selected)) {
    Write-Host "Selected: $selected"
  }
  if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
    Write-Host $errorMessage
  }
  Write-Host ""
  Write-Host "Candidate directories:"
  foreach ($candidate in $candidateReports) {
    $marker = if ($candidate.hasGcc -and $candidate.hasGxx) { "OK" } elseif ($candidate.exists) { "partial" } else { "missing" }
    Write-Host "[$marker] $($candidate.path)"
    if (-not [string]::IsNullOrWhiteSpace($candidate.gccVersion)) {
      Write-Host "  gcc: $($candidate.gccVersion)"
    }
    if (-not [string]::IsNullOrWhiteSpace($candidate.gxxVersion)) {
      Write-Host "  g++: $($candidate.gxxVersion)"
    }
  }
  if ($status -ne "ready") {
    Write-Host ""
    Write-Host "Install guidance:"
    foreach ($line in $report.installGuidance) {
      Write-Host "- $line"
    }
  }
}

if ($status -ne "ready") {
  exit 2
}
