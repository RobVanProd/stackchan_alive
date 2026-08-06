$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'release_ota_selector_policy.ps1')
. (Join-Path $PSScriptRoot 'platformio_resolver.ps1')

function Assert-Throws {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $failed = $false
  try {
    & $Action
  } catch {
    $failed = $true
  }
  if (-not $failed) {
    throw "OTA selector policy mutation was accepted: $Label"
  }
}

$legacyPolicy = Get-StackchanReleaseOtaSelectorPolicy -Environment 'stackchan'
$servoPolicy = Get-StackchanReleaseOtaSelectorPolicy -Environment 'stackchan_servo_calibration'
$releasePolicy = Get-StackchanReleaseOtaSelectorPolicy -Environment 'stackchan_release_full'
foreach ($policy in @($legacyPolicy, $servoPolicy, $releasePolicy)) {
  if ([string]$policy.schema -cne 'stackchan.release-ota-selector-policy.v1' -or
      [string]$policy.frameworkPackageName -cne 'framework-arduinoespressif32' -or
      [string]$policy.selectorRelativePath -cne 'tools/partitions/boot_app0.bin' -or
      [long]$policy.exactBytes -ne 8192 -or
      [string]$policy.sha256 -cne
        'F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0') {
    throw "OTA selector policy entry is not exact: $([string]$policy.environment)"
  }
}
if ([string]$legacyPolicy.frameworkPackageVersion -cne '3.20017.241212+sha.dcc1105b' -or
    [string]$servoPolicy.frameworkPackageVersion -cne '3.20017.241212+sha.dcc1105b' -or
    [string]$releasePolicy.frameworkPackageVersion -cne '3.3.6') {
  throw 'OTA selector environment-to-framework routing is not exact.'
}

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-selector-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $wrongSize = Join-Path $scratch 'wrong-size.bin'
  [System.IO.File]::WriteAllBytes($wrongSize, (New-Object byte[] 8191))
  Assert-Throws -Label '8191 bytes' -Action {
    Assert-StackchanReleaseOtaSelectorBytes -Environment 'stackchan' -LiteralPath $wrongSize
  }

  $wrongHash = Join-Path $scratch 'wrong-hash.bin'
  [System.IO.File]::WriteAllBytes($wrongHash, (New-Object byte[] 8192))
  Assert-Throws -Label 'correct size with unreviewed hash' -Action {
    Assert-StackchanReleaseOtaSelectorBytes -Environment 'stackchan' -LiteralPath $wrongHash
  }

  $fakeCore = Join-Path $scratch 'fake-core'
  $fakeFramework = Join-Path $fakeCore 'packages/framework-arduinoespressif32'
  $fakeSelectorDir = Join-Path $fakeFramework 'tools/partitions'
  New-Item -ItemType Directory -Path $fakeSelectorDir -Force | Out-Null
  [System.IO.File]::WriteAllBytes(
    (Join-Path $fakeSelectorDir 'boot_app0.bin'), (New-Object byte[] 8192))
  [System.IO.File]::WriteAllText(
    (Join-Path $fakeFramework 'package.json'),
    '{"name":"framework-arduinoespressif32","version":"3.20017.241212+sha.dcc1105b"}',
    [System.Text.UTF8Encoding]::new($false))
  Assert-Throws -Label 'fake core same-size selector' -Action {
    Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan' -CoreDir $fakeCore
  }
  Assert-Throws -Label 'release environment routed to legacy framework' -Action {
    Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan_release_full' -CoreDir $fakeCore
  }

  [System.IO.File]::WriteAllText(
    (Join-Path $fakeFramework 'package.json'),
    '{"name":"not-the-framework","version":"3.20017.241212+sha.dcc1105b"}',
    [System.Text.UTF8Encoding]::new($false))
  Assert-Throws -Label 'wrong framework name' -Action {
    Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan' -CoreDir $fakeCore
  }
  [System.IO.File]::WriteAllText(
    (Join-Path $fakeFramework 'package.json'),
    '{"name":"framework-arduinoespressif32","version":"0.0.0"}',
    [System.Text.UTF8Encoding]::new($false))
  Assert-Throws -Label 'wrong framework version' -Action {
    Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan' -CoreDir $fakeCore
  }
  Remove-Item -LiteralPath (Join-Path $fakeSelectorDir 'boot_app0.bin') -Force
  Assert-Throws -Label 'missing selector' -Action {
    Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan' -CoreDir $fakeCore
  }

  if ($env:OS -eq 'Windows_NT') {
    $junctionCore = Join-Path $scratch 'junction-core'
    $junctionPackages = Join-Path $junctionCore 'packages'
    New-Item -ItemType Directory -Path $junctionPackages -Force | Out-Null
    $junctionTarget = Join-Path $scratch 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction `
      -Path (Join-Path $junctionPackages 'framework-arduinoespressif32') `
      -Target $junctionTarget | Out-Null
    Assert-Throws -Label 'framework junction' -Action {
      Assert-StackchanReleaseFrameworkOtaSelector -Environment 'stackchan' -CoreDir $junctionCore
    }
  }
} finally {
  if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

$installedChecks = @(
  [ordered]@{ environment = 'stackchan'; core = (Get-StackchanPlatformioCoreDir) },
  [ordered]@{ environment = 'stackchan_servo_calibration'; core = (Get-StackchanPlatformioCoreDir) }
)
$releaseCore = if ($env:OS -eq 'Windows_NT') {
  Join-Path ([System.IO.Path]::GetPathRoot($env:SystemRoot)) 'spio/pioarduino'
} else {
  Join-Path ([System.IO.Path]::GetTempPath()) 'stackchan-pio-release-cores/pioarduino'
}
$installedChecks += [ordered]@{ environment = 'stackchan_release_full'; core = $releaseCore }
foreach ($installed in $installedChecks) {
  if (-not [string]::IsNullOrWhiteSpace([string]$installed.core) -and
      (Test-Path -LiteralPath ([string]$installed.core) -PathType Container)) {
    Assert-StackchanReleaseFrameworkOtaSelector `
      -Environment ([string]$installed.environment) `
      -CoreDir ([string]$installed.core) | Out-Null
  }
}

Write-Host 'Release OTA selector authority contract passed.'
