param(
  [Parameter(Mandatory = $true)][string]$ReleaseCoreDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$originalSha256 = '6FC4C8912CBB1FA65A84A527EC5A3CB1280BBA399B02D4885C8C1D91AB7CC9D0'
$sealedSha256 = 'D16479CFAD23EF7C392B48C66B9E2422C0294E185746814ED4F7F9E4EFFACB60'
$relativeTarget = 'platforms/espressif32/builder/penv_setup.py'

$coreItem = Get-Item -LiteralPath $ReleaseCoreDir -Force -ErrorAction Stop
if (-not $coreItem.PSIsContainer -or
    ($coreItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'ReleaseCoreDir must be one real PlatformIO core directory.'
}
$coreRoot = $coreItem.FullName.TrimEnd('\', '/')
$targetPath = [IO.Path]::GetFullPath((Join-Path $coreRoot $relativeTarget))
$targetItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
if ($targetItem.PSIsContainer -or
    ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'The pioarduino penv setup target must be one real file.'
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash
$backupRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'output/private/toolchain-backups'
$backupPath = Join-Path $backupRoot "penv_setup.py.$originalSha256.bak"
if ($actualSha256 -ceq $sealedSha256) {
  if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash -cne $originalSha256) {
    throw 'Sealed pioarduino release core is missing its exact private original-byte backup.'
  }
  Write-Output "Pioarduino release core is already sealed: $targetPath"
  exit 0
}
if ($actualSha256 -cne $originalSha256) {
  throw "Refusing unreviewed pioarduino penv setup bytes: $actualSha256"
}

$originalBytes = [IO.File]::ReadAllBytes($targetPath)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$originalText = $utf8.GetString($originalBytes)
$oldDependency = '    "platformio": "https://github.com/pioarduino/platformio-core/archive/refs/tags/v6.1.18.zip",'
$newDependency = '    "pioarduino-core": "https://github.com/pioarduino/platformio-core/archive/refs/tags/v6.1.18.zip",'
$oldBranch = '        elif name == "platformio":'
$newBranch = '        elif name in ("platformio", "pioarduino-core"):'
if (($originalText.Split($oldDependency).Count - 1) -ne 1 -or
    ($originalText.Split($oldBranch).Count - 1) -ne 1) {
  throw 'Reviewed pioarduino seal anchors are missing or ambiguous.'
}
$sealedText = $originalText.Replace($oldDependency, $newDependency).Replace($oldBranch, $newBranch)
$sealedBytes = $utf8.GetBytes($sealedText)

$tempPath = "$targetPath.stackchan-sealed-$PID.tmp"
if (Test-Path -LiteralPath $tempPath) {
  throw "Refusing pre-existing seal temporary path: $tempPath"
}
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
if (-not (Test-Path -LiteralPath $backupPath)) {
  [IO.File]::WriteAllBytes($backupPath, $originalBytes)
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash -cne $originalSha256) {
  throw 'Private pioarduino backup does not match the reviewed original bytes.'
}

try {
  [IO.File]::WriteAllBytes($tempPath, $sealedBytes)
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash -cne $sealedSha256) {
    throw 'Generated pioarduino seal bytes do not match the reviewed patched identity.'
  }
  [IO.File]::Replace($tempPath, $targetPath, $null)
} finally {
  if (Test-Path -LiteralPath $tempPath) {
    Remove-Item -LiteralPath $tempPath -Force
  }
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash -cne $sealedSha256) {
  throw 'Pioarduino release core seal did not persist the reviewed bytes.'
}
Write-Output "Sealed pioarduino release core: $targetPath"
