param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$verifyScript = Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]
$requiredDashboardNotes = "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state"

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Write-TestPng {
  param([string]$Path)

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $bytes = New-Object byte[] 1024
  $signature = [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
  [Array]::Copy($signature, 0, $bytes, 0, $signature.Length)
  $bytes[16] = 0x00
  $bytes[17] = 0x00
  $bytes[18] = 0x00
  $bytes[19] = 0x20
  $bytes[20] = 0x00
  $bytes[21] = 0x00
  $bytes[22] = 0x00
  $bytes[23] = 0x20
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-TestEvidenceRoot {
  param(
    [switch]$WithManifest,
    [string]$Notes = ""
  )

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-strict-dashboard-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root "android/companion-probe") | Out-Null

  Write-JsonFile -Path (Join-Path $root "android/companion-probe/android_companion_probe.json") -Value ([ordered]@{
      schema = "stackchan.android-companion-probe.v1"
      status = "pass"
      issues = @()
    })
  Write-JsonFile -Path (Join-Path $root "metadata.json") -Value ([ordered]@{
      androidCompanionProbes = [ordered]@{
        apkInstallReport = ""
        companionProbeReport = "android/companion-probe/android_companion_probe.json"
        screenOffSoakReport = ""
        udpBeaconProbeReport = ""
        logcatReport = ""
      }
    })

  if ($WithManifest) {
    Write-TestPng -Path (Join-Path $root "photos/android-dashboard.png")
    Write-JsonFile -Path (Join-Path $root "media_manifest.json") -Value ([ordered]@{
        schema = "stackchan.hardware-media-manifest.v1"
        entries = @(
          [ordered]@{
            kind = "photo"
            relativePath = "photos/android-dashboard.png"
            notes = $Notes
          }
        )
      })
  }

  return $root
}

function Invoke-StrictDashboardContractCheck {
  param([string]$EvidenceRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $verifyScript `
      -EvidenceRoot $EvidenceRoot `
      -AndroidDashboardEvidenceContractSelfTest 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    text = ($output | Out-String).TrimEnd()
  }
}

function Assert-ContractFailsWith {
  param(
    [string]$Name,
    [string]$EvidenceRoot,
    [string]$Needle
  )

  $result = Invoke-StrictDashboardContractCheck -EvidenceRoot $EvidenceRoot
  if ([int]$result.exitCode -eq 0) {
    throw "Expected strict dashboard verifier contract case '$Name' to fail."
  }
  if ([string]$result.text -notlike "*$Needle*") {
    throw "Expected strict dashboard verifier contract case '$Name' to mention '$Needle'. Output:`n$($result.text)"
  }
  Write-Host "[ok] exercised $Name"
}

try {
  Set-Location $repoRoot

  $missingManifestRoot = New-TestEvidenceRoot
  Assert-ContractFailsWith -Name "missing dashboard media manifest" -EvidenceRoot $missingManifestRoot -Needle "media_manifest.json is missing"

  $incompleteNotesRoot = New-TestEvidenceRoot -WithManifest -Notes "Android dashboard connected state only"
  Assert-ContractFailsWith -Name "incomplete dashboard notes" -EvidenceRoot $incompleteNotesRoot -Needle "missing a photo/video entry"

  $validRoot = New-TestEvidenceRoot -WithManifest -Notes $requiredDashboardNotes
  $validResult = Invoke-StrictDashboardContractCheck -EvidenceRoot $validRoot
  if ([int]$validResult.exitCode -ne 0) {
    throw "Expected valid strict dashboard verifier contract case to pass. Output:`n$($validResult.text)"
  }
  if ([string]$validResult.text -notlike "*Android dashboard strict evidence contract verified*") {
    throw "Valid strict dashboard verifier contract case did not report success. Output:`n$($validResult.text)"
  }
  Write-Host "[ok] exercised valid dashboard media evidence"

  Write-Host "Strict Android dashboard evidence contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }
    $resolvedRoot = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $resolvedRoot -and $resolvedRoot.Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedRoot.Path -Recurse -Force
    }
  }
}
