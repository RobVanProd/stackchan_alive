param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checker = Join-Path $PSScriptRoot "check_release_credential_hygiene.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("stackchan-release-credential-hygiene-" + [guid]::NewGuid().ToString("N"))
$powerShellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
$powerShellHost = if ($null -ne $powerShellCommand) { $powerShellCommand.Source } else { (Get-Process -Id $PID).Path }

$packageScript = Get-Content -LiteralPath (Join-Path $repoRoot "tools/package_release.ps1") -Raw
foreach ($pattern in @("check_release_credential_hygiene.ps1", "refusing to build or package from this checkout")) {
  if ($packageScript -notmatch [regex]::Escape($pattern)) {
    throw "package_release.ps1 does not fail closed on release credential hygiene: $pattern"
  }
}
Write-Host "[ok] every release package runs credential hygiene before building"

$firmwareWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/firmware.yml") -Raw
foreach ($pattern in @("Run release credential hygiene contract", "test_release_credential_hygiene_contract.ps1")) {
  if ($firmwareWorkflow -notmatch [regex]::Escape($pattern)) {
    throw "firmware.yml does not run the release credential hygiene contract: $pattern"
  }
}
Write-Host "[ok] companion CI runs the release credential hygiene contract"

$ignoreLines = @(
  "*.jks",
  "*.keystore",
  "*.p12",
  "*.pfx",
  "*.pkcs12",
  "*.key",
  "*.p8",
  "*.snk"
)

function Invoke-Checker {
  param([string]$Root)

  $output = & $powerShellHost -NoProfile -File $checker -Root $Root -Json 2>&1 | Out-String
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = $output
  }
}

function New-FixtureRepository {
  param(
    [string]$Name,
    [string[]]$IgnorePatterns = $ignoreLines
  )

  $root = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  & git -C $root init --quiet
  if ($LASTEXITCODE -ne 0) { throw "Could not initialize fixture repository $Name." }
  $IgnorePatterns | Set-Content -LiteralPath (Join-Path $root ".gitignore") -Encoding UTF8
  "safe fixture" | Set-Content -LiteralPath (Join-Path $root "README.md") -Encoding UTF8
  & git -C $root add .gitignore README.md
  if ($LASTEXITCODE -ne 0) { throw "Could not stage baseline fixture files for $Name." }
  return $root
}

try {
  $current = Invoke-Checker $repoRoot
  if ($current.exitCode -ne 0) {
    throw "Current source tree credential hygiene failed: $($current.output)"
  }
  Write-Host "[ok] current source tree has no tracked private signing credentials"

  $baselineRoot = New-FixtureRepository "baseline"
  $baseline = Invoke-Checker $baselineRoot
  if ($baseline.exitCode -ne 0 -or $baseline.output -notmatch 'release-credential-hygiene-ready') {
    throw "Expected a clean fixture to pass: $($baseline.output)"
  }
  Write-Host "[ok] all private-key bundle extensions are ignored"

  foreach ($extension in @("jks", "keystore", "p12", "pfx", "pkcs12", "key", "p8", "snk")) {
    $fixtureRoot = New-FixtureRepository "tracked-$extension"
    $credentialPath = Join-Path $fixtureRoot "credential.$extension"
    "not a real credential" | Set-Content -LiteralPath $credentialPath -Encoding UTF8
    & git -C $fixtureRoot add --force "credential.$extension"
    if ($LASTEXITCODE -ne 0) { throw "Could not force-stage .$extension fixture." }
    $result = Invoke-Checker $fixtureRoot
    if ($result.exitCode -eq 0 -or $result.output -notmatch "credential\.$extension") {
      throw "Expected a tracked .$extension bundle to fail: $($result.output)"
    }
  }
  Write-Host "[ok] tracked private-key bundle extensions are rejected"

  $markerRoot = New-FixtureRepository "private-key-marker"
  $beginMarker = "-----BEGIN " + "PRIVATE KEY-----"
  $endMarker = "-----END " + "PRIVATE KEY-----"
  @($beginMarker, "not-a-real-key", $endMarker) |
    Set-Content -LiteralPath (Join-Path $markerRoot "notes.txt") -Encoding UTF8
  & git -C $markerRoot add notes.txt
  if ($LASTEXITCODE -ne 0) { throw "Could not stage private-key marker fixture." }
  $markerResult = Invoke-Checker $markerRoot
  if ($markerResult.exitCode -eq 0 -or $markerResult.output -notmatch 'notes.txt') {
    throw "Expected a tracked private-key marker to fail: $($markerResult.output)"
  }
  Write-Host "[ok] tracked PEM private key markers are rejected"

  $missingIgnoreRoot = New-FixtureRepository `
    -Name "missing-pfx-ignore" `
    -IgnorePatterns @($ignoreLines | Where-Object { $_ -ne "*.pfx" })
  $missingIgnore = Invoke-Checker $missingIgnoreRoot
  if ($missingIgnore.exitCode -eq 0 -or $missingIgnore.output -notmatch 'ignore-pattern-pfx') {
    throw "Expected a missing private-key ignore pattern to fail: $($missingIgnore.output)"
  }
  Write-Host "[ok] missing private-key ignore patterns are rejected"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Release credential hygiene contract tests passed"
exit 0
