param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_android_play_release_readiness.ps1"
$keytool = Get-Command keytool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $keytool) {
  throw "keytool is required for the Android upload signing contract."
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-upload-signing-contract-" + [guid]::NewGuid().ToString("N"))
$keystorePath = Join-Path $temporaryDirectory "contract-upload-keys.jks"
$storePassword = ([guid]::NewGuid().ToString("N") + "StoreAa1!")
$validKeyPassword = ([guid]::NewGuid().ToString("N") + "ValidAa1!")
$weakKeyPassword = ([guid]::NewGuid().ToString("N") + "WeakAa1!")
$debugKeyPassword = ([guid]::NewGuid().ToString("N") + "DebugAa1!")
$shortKeyPassword = ([guid]::NewGuid().ToString("N") + "ShortAa1!")
$wrongPassword = ([guid]::NewGuid().ToString("N") + "WrongAa1!")
$storePasswordEnvironmentName = "STACKCHAN_CONTRACT_STORE_PASSWORD"
$keyPasswordEnvironmentName = "STACKCHAN_CONTRACT_KEY_PASSWORD"
$signingEnvironmentNames = @(
  "STACKCHAN_ANDROID_KEYSTORE",
  "STACKCHAN_ANDROID_KEYSTORE_PASSWORD",
  "STACKCHAN_ANDROID_KEY_ALIAS",
  "STACKCHAN_ANDROID_KEY_PASSWORD"
)
$environmentNames = @($signingEnvironmentNames + $storePasswordEnvironmentName + $keyPasswordEnvironmentName)
$previousEnvironment = @{}
$passCount = 0

function Invoke-ContractKeytool {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $keytool.Source @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "Contract keytool command failed with exit code $exitCode."
  }
}

function New-ContractKey {
  param(
    [string]$Alias,
    [string]$KeyPassword,
    [int]$KeySize,
    [int]$ValidityDays,
    [string]$DistinguishedName
  )

  [Environment]::SetEnvironmentVariable($keyPasswordEnvironmentName, $KeyPassword)
  Invoke-ContractKeytool -Arguments @(
    "-genkeypair",
    "-keystore", $keystorePath,
    "-storetype", "JKS",
    "-alias", $Alias,
    "-keyalg", "RSA",
    "-keysize", [string]$KeySize,
    "-validity", [string]$ValidityDays,
    "-dname", $DistinguishedName,
    "-storepass:env", $storePasswordEnvironmentName,
    "-keypass:env", $keyPasswordEnvironmentName,
    "-noprompt"
  )
}

function Set-SigningEnvironment {
  param(
    [string]$StorePassword,
    [string]$Alias,
    [string]$KeyPassword
  )

  [Environment]::SetEnvironmentVariable("STACKCHAN_ANDROID_KEYSTORE", $keystorePath)
  [Environment]::SetEnvironmentVariable("STACKCHAN_ANDROID_KEYSTORE_PASSWORD", $StorePassword)
  [Environment]::SetEnvironmentVariable("STACKCHAN_ANDROID_KEY_ALIAS", $Alias)
  [Environment]::SetEnvironmentVariable("STACKCHAN_ANDROID_KEY_PASSWORD", $KeyPassword)
}

function Clear-SigningEnvironment {
  foreach ($name in $signingEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null)
  }
}

function Invoke-ReadinessCheck {
  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $checkScript,
    "-Root",
    [string]$repoRoot,
    "-Json"
  )

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $powerShellExe @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  foreach ($secret in @($storePassword, $validKeyPassword, $weakKeyPassword, $debugKeyPassword, $shortKeyPassword, $wrongPassword)) {
    if ($text.Contains($secret)) {
      throw "Android signing readiness output exposed a contract credential."
    }
  }

  try {
    $report = $text | ConvertFrom-Json
  } catch {
    throw "Android signing readiness output was not valid JSON."
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    report = $report
  }
}

function Get-SigningCheck {
  param([object]$Report)

  $checks = @($Report.checks | Where-Object { $_.id -eq "play-upload-signing-environment" })
  if ($checks.Count -ne 1) {
    throw "Expected exactly one play-upload-signing-environment check."
  }
  return $checks[0]
}

function Assert-Readiness {
  param(
    [object]$Result,
    [int]$ExpectedExitCode,
    [string]$ExpectedReportStatus,
    [string]$ExpectedCheckStatus,
    [string]$DetailPattern,
    [string]$Name
  )

  $check = Get-SigningCheck -Report $Result.report
  if ($Result.exitCode -ne $ExpectedExitCode) {
    throw "$Name returned exit code $($Result.exitCode); expected $ExpectedExitCode. Report status: $($Result.report.status). Signing check: $($check.status). Detail: $($check.detail)"
  }
  if ($Result.report.status -ne $ExpectedReportStatus) {
    throw "$Name returned status '$($Result.report.status)'; expected '$ExpectedReportStatus'."
  }
  if ($check.status -ne $ExpectedCheckStatus) {
    throw "$Name signing check was '$($check.status)'; expected '$ExpectedCheckStatus'."
  }
  if (-not [string]::IsNullOrWhiteSpace($DetailPattern) -and $check.detail -notmatch [regex]::Escape($DetailPattern)) {
    throw "$Name detail did not include '$DetailPattern': $($check.detail)"
  }

  $script:passCount++
  Write-Host "[PASS] $Name"
}

try {
  foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
  [Environment]::SetEnvironmentVariable($storePasswordEnvironmentName, $storePassword)

  New-ContractKey `
    -Alias "valid-upload" `
    -KeyPassword $validKeyPassword `
    -KeySize 4096 `
    -ValidityDays 10000 `
    -DistinguishedName "CN=Stackchan Upload Contract, OU=Release, O=Stackchan, L=Test, ST=Test, C=US"
  New-ContractKey `
    -Alias "weak-upload" `
    -KeyPassword $weakKeyPassword `
    -KeySize 2048 `
    -ValidityDays 10000 `
    -DistinguishedName "CN=Stackchan Weak Contract, OU=Release, O=Stackchan, L=Test, ST=Test, C=US"
  New-ContractKey `
    -Alias "debug-upload" `
    -KeyPassword $debugKeyPassword `
    -KeySize 4096 `
    -ValidityDays 10000 `
    -DistinguishedName "CN=Android Debug, OU=Android, O=Android, C=US"
  New-ContractKey `
    -Alias "short-upload" `
    -KeyPassword $shortKeyPassword `
    -KeySize 4096 `
    -ValidityDays 365 `
    -DistinguishedName "CN=Stackchan Short Contract, OU=Release, O=Stackchan, L=Test, ST=Test, C=US"

  Clear-SigningEnvironment
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 0 `
    -ExpectedReportStatus "source-ready-pending-upload-signing" `
    -ExpectedCheckStatus "pending" `
    -DetailPattern "Release tasks fail closed" `
    -Name "missing upload signing credentials remain pending and fail closed"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "valid-upload" -KeyPassword $validKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 0 `
    -ExpectedReportStatus "source-ready" `
    -ExpectedCheckStatus "pass" `
    -DetailPattern "RSA 4096 bits" `
    -Name "valid 4096-bit private upload key is accepted"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "missing-upload" -KeyPassword $validKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "store password and alias" `
    -Name "missing upload-key alias is rejected"

  Set-SigningEnvironment -StorePassword $wrongPassword -Alias "valid-upload" -KeyPassword $validKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "store password and alias" `
    -Name "wrong keystore password is rejected"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "valid-upload" -KeyPassword $wrongPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "private-key entry" `
    -Name "wrong private-key password is rejected"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "weak-upload" -KeyPassword $weakKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "requires at least 4096 bits" `
    -Name "weak 2048-bit upload key is rejected"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "debug-upload" -KeyPassword $debugKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "Android debug key" `
    -Name "Android debug certificate subject is rejected"

  Set-SigningEnvironment -StorePassword $storePassword -Alias "short-upload" -KeyPassword $shortKeyPassword
  Assert-Readiness `
    -Result (Invoke-ReadinessCheck) `
    -ExpectedExitCode 1 `
    -ExpectedReportStatus "not-ready" `
    -ExpectedCheckStatus "fail" `
    -DetailPattern "2033-10-23 UTC" `
    -Name "upload certificate expiring before the Play minimum is rejected"
} finally {
  foreach ($name in $environmentNames) {
    if ($null -eq $previousEnvironment[$name]) {
      [Environment]::SetEnvironmentVariable($name, $null)
    } else {
      [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name])
    }
  }
  if (Test-Path -LiteralPath $temporaryDirectory) {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
  }
}

Write-Host "Android upload signing contract passed: $passCount checks."
exit 0
