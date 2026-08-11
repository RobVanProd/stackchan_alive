$script:StackchanReleaseOtaSelectorSchema = 'stackchan.release-ota-selector-policy.v1'
$script:StackchanReleaseOtaSelectorSha256 = `
  'F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0'

function Get-StackchanReleaseOtaSelectorPolicy {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')]
    [string]$Environment
  )

  $frameworkVersion = if ($Environment -ceq 'stackchan_release_full') {
    '3.3.6'
  } else {
    '3.20017.241212+sha.dcc1105b'
  }
  return [pscustomobject][ordered]@{
    schema = $script:StackchanReleaseOtaSelectorSchema
    environment = $Environment
    frameworkPackageName = 'framework-arduinoespressif32'
    frameworkPackageVersion = $frameworkVersion
    selectorRelativePath = 'tools/partitions/boot_app0.bin'
    exactBytes = 8192
    sha256 = $script:StackchanReleaseOtaSelectorSha256
  }
}

function Get-StackchanReleaseOtaSelectorSha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)

  $stream = [System.IO.FileStream]::new(
    $LiteralPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read,
    1MB,
    [System.IO.FileOptions]::SequentialScan)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($hasher.ComputeHash($stream)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
    $stream.Dispose()
  }
}

function Assert-StackchanReleaseOtaSelectorBytes {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')]
    [string]$Environment,
    [Parameter(Mandatory = $true)][string]$LiteralPath
  )

  $policy = Get-StackchanReleaseOtaSelectorPolicy -Environment $Environment
  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
    throw "Missing reviewed OTA selector for $Environment`: $LiteralPath"
  }
  $item = Get-Item -LiteralPath $LiteralPath -Force
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Reviewed OTA selector may not be a reparse point for $Environment`: $LiteralPath"
  }
  if ([long]$item.Length -ne [long]$policy.exactBytes) {
    throw "OTA selector byte count is not authorized for $Environment`: $($item.Length)"
  }
  $actualSha256 = Get-StackchanReleaseOtaSelectorSha256 -LiteralPath $item.FullName
  if ($actualSha256 -cne [string]$policy.sha256) {
    throw "OTA selector SHA-256 is not authorized for $Environment`: $actualSha256"
  }
  return [pscustomobject][ordered]@{
    policy = $policy
    path = $item.FullName
    bytes = [long]$item.Length
    sha256 = $actualSha256
  }
}

function Assert-StackchanReleaseFrameworkOtaSelector {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')]
    [string]$Environment,
    [Parameter(Mandatory = $true)][string]$CoreDir
  )

  $policy = Get-StackchanReleaseOtaSelectorPolicy -Environment $Environment
  if (-not (Test-Path -LiteralPath $CoreDir -PathType Container)) {
    throw "Missing PlatformIO core for OTA selector policy: $CoreDir"
  }
  $coreItem = Get-Item -LiteralPath $CoreDir -Force
  if ($coreItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Selected PlatformIO core may not be a reparse point for $Environment`: $CoreDir"
  }
  $resolvedCore = $coreItem.FullName.TrimEnd('\', '/')
  $frameworkRoot = Join-Path $resolvedCore (
    'packages/' + [string]$policy.frameworkPackageName)
  if (-not (Test-Path -LiteralPath $frameworkRoot -PathType Container)) {
    throw "Missing reviewed framework package for $Environment`: $frameworkRoot"
  }
  $frameworkItem = Get-Item -LiteralPath $frameworkRoot -Force
  if ($frameworkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Reviewed framework package may not be a reparse point for $Environment`: $frameworkRoot"
  }
  $frameworkRoot = $frameworkItem.FullName.TrimEnd('\', '/')
  $corePrefix = $resolvedCore + [System.IO.Path]::DirectorySeparatorChar
  if (-not $frameworkRoot.StartsWith($corePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Reviewed framework package escaped the selected PlatformIO core for $Environment."
  }

  $metadataPath = Join-Path $frameworkRoot 'package.json'
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Missing framework package identity for $Environment`: $metadataPath"
  }
  $metadataItem = Get-Item -LiteralPath $metadataPath -Force
  if ($metadataItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Framework package identity may not be a reparse point for $Environment`: $metadataPath"
  }
  try {
    $metadata = Get-Content -LiteralPath $metadataItem.FullName -Raw | ConvertFrom-Json
  } catch {
    throw "Framework package identity is unreadable for $Environment`: $($_.Exception.Message)"
  }
  if ([string]$metadata.name -cne [string]$policy.frameworkPackageName -or
      [string]$metadata.version -cne [string]$policy.frameworkPackageVersion) {
    throw (
      "Framework package identity is not authorized for $Environment`: " +
      "$([string]$metadata.name)@$([string]$metadata.version)")
  }

  $relativeParts = ([string]$policy.selectorRelativePath).Split('/')
  $selectorPath = $frameworkRoot
  foreach ($part in $relativeParts) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -in @('.', '..')) {
      throw "Unsafe OTA selector policy path for $Environment."
    }
    $selectorPath = Join-Path $selectorPath $part
    if (-not (Test-Path -LiteralPath $selectorPath)) {
      throw "Missing OTA selector policy path component for $Environment`: $selectorPath"
    }
    $component = Get-Item -LiteralPath $selectorPath -Force
    if ($component.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "OTA selector policy path may not contain reparse points for $Environment`: $selectorPath"
    }
  }
  $selectorPath = (Get-Item -LiteralPath $selectorPath -Force).FullName
  $frameworkPrefix = $frameworkRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $selectorPath.StartsWith($frameworkPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OTA selector escaped the reviewed framework package for $Environment."
  }
  return Assert-StackchanReleaseOtaSelectorBytes `
    -Environment $Environment -LiteralPath $selectorPath
}
