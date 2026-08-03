$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$flashPath = Join-Path $PSScriptRoot 'flash_release_firmware.ps1'
$tokens = $null
$parseErrors = $null
$flashAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $flashPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
  throw 'Release flasher does not parse for snapshot contract testing.'
}
foreach ($functionName in @(
    'Copy-ReleaseZipSnapshot',
    'Get-LockedReleasePayloadSha256',
    'Get-LockedReleaseZipChecksumRecords',
    'Get-ReleaseFlashWriteArguments')) {
  $matches = @($flashAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq $functionName
  }, $true))
  if ($matches.Count -ne 1) {
    throw "Release flasher snapshot helper is missing or ambiguous: $functionName"
  }
  . ([scriptblock]::Create($matches[0].Extent.Text))
}
. (Join-Path $PSScriptRoot 'release_zip_safety.ps1')

$pairs = @(Get-ReleaseFlashWriteArguments `
  -Bootloader BOOT -Partitions PART -OtaSelector OTA -FirmwareBin APP)
$expectedPairs = @('0x0', 'BOOT', '0x8000', 'PART', '0xe000', 'OTA', '0x10000', 'APP')
if (($pairs -join "`n") -cne ($expectedPairs -join "`n")) {
  throw 'Release flasher address/payload helper is not exact.'
}

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-flash-snapshot-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $scratch 'source'
$extractRoot = Join-Path $scratch 'extracted'
$sourceZip = Join-Path $scratch 'source.zip'
$snapshotZip = Join-Path $scratch 'snapshot.zip'
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
$snapshotLock = $null
try {
  $payloadBytes = [System.Text.Encoding]::ASCII.GetBytes('immutable-payload')
  $payloadPath = Join-Path $sourceRoot 'payload.bin'
  [System.IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
  $payloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadPath).Hash.ToLowerInvariant()
  [System.IO.File]::WriteAllText(
    (Join-Path $sourceRoot 'SHA256SUMS.txt'), "$payloadHash  payload.bin`n",
    [System.Text.Encoding]::ASCII)
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $sourceRoot, $sourceZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

  $snapshotLock = Copy-ReleaseZipSnapshot `
    -SourcePath $sourceZip -DestinationPath $snapshotZip
  $snapshotHash = Get-LockedReleasePayloadSha256 -Stream $snapshotLock
  if ($snapshotHash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceZip).Hash) {
    throw 'Private flash ZIP snapshot does not match its locked source copy.'
  }

  $writeRejected = $false
  try {
    $writeProbe = [System.IO.FileStream]::new(
      $snapshotZip, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite)
    $writeProbe.Dispose()
  } catch {
    $writeRejected = $true
  }
  if (-not $writeRejected) {
    throw 'Locked flash ZIP snapshot allowed a concurrent writer.'
  }

  $records = Get-LockedReleaseZipChecksumRecords -SnapshotStream $snapshotLock
  if ($records.Count -ne 1 -or
      [string]$records['payload.bin'] -cne $payloadHash.ToUpperInvariant()) {
    throw 'Flash checksum authority was not read from the locked ZIP snapshot.'
  }
  Expand-StackchanReleaseZipSafely `
    -ZipPath $snapshotZip -DestinationPath $extractRoot
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $extractRoot 'payload.bin')).Hash `
      -cne $payloadHash.ToUpperInvariant()) {
    throw 'Locked flash ZIP snapshot extraction changed its payload.'
  }
} finally {
  if ($null -ne $snapshotLock) { $snapshotLock.Dispose() }
  if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

Write-Host 'Release flash snapshot/offset contract passed.'
