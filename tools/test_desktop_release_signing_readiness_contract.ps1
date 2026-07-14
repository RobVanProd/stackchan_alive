$ErrorActionPreference = "Stop"

$checker = Join-Path $PSScriptRoot "check_desktop_release_signing_readiness.ps1"
$powerShellHost = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $powerShellHost) {
  $powerShellHost = Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1
}

$environmentNames = @(
  "STACKCHAN_WINDOWS_PFX_B64",
  "STACKCHAN_WINDOWS_PFX_PASSWORD",
  "STACKCHAN_MACOS_CERTIFICATE_B64",
  "STACKCHAN_MACOS_CERTIFICATE_PASSWORD",
  "STACKCHAN_MACOS_SIGNING_IDENTITY",
  "STACKCHAN_MACOS_NOTARIZATION_APPLE_ID",
  "STACKCHAN_MACOS_NOTARIZATION_PASSWORD",
  "STACKCHAN_MACOS_NOTARIZATION_TEAM_ID"
)
$previousEnvironment = @{}
$secretValues = @(
  "windows-contract-password-Aa1!",
  "macos-contract-password-Bb2!",
  "wrong-contract-password-Cc3!",
  "notary-contract-password-Dd4!"
)
$passCount = 0

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$readinessWorkflowPath = Join-Path $repoRoot ".github/workflows/companion-signing-readiness.yml"
$releaseWorkflowPath = Join-Path $repoRoot ".github/workflows/release.yml"
if (-not (Test-Path -LiteralPath $readinessWorkflowPath -PathType Leaf)) {
  throw "Missing manual companion signing readiness workflow."
}
$readinessWorkflow = Get-Content -LiteralPath $readinessWorkflowPath -Raw
foreach ($pattern in @(
  "workflow_dispatch",
  "contents: read",
  "check_desktop_release_signing_readiness.ps1",
  "STACKCHAN_WINDOWS_PFX_B64",
  "STACKCHAN_WINDOWS_PFX_PASSWORD",
  "STACKCHAN_MACOS_CERTIFICATE_B64",
  "STACKCHAN_MACOS_CERTIFICATE_PASSWORD",
  "STACKCHAN_MACOS_SIGNING_IDENTITY",
  "STACKCHAN_MACOS_NOTARIZATION_APPLE_ID",
  "STACKCHAN_MACOS_NOTARIZATION_PASSWORD",
  "STACKCHAN_MACOS_NOTARIZATION_TEAM_ID",
  "RequireNativeToolchain",
  "ValidateAppleNotaryCredentials"
)) {
  if ($readinessWorkflow -notmatch [regex]::Escape($pattern)) {
    throw "Manual signing readiness workflow is missing: $pattern"
  }
}
foreach ($forbidden in @("gh release", "upload-artifact", "contents: write")) {
  if ($readinessWorkflow -match [regex]::Escape($forbidden)) {
    throw "Manual signing readiness workflow must not publish artifacts or releases: $forbidden"
  }
}
$passCount++
Write-Host "[PASS] manual signing readiness workflow validates without publishing"

$checkerText = Get-Content -LiteralPath $checker -Raw
foreach ($pattern in @(
  "SignTool could not verify the temporary Authenticode signing probe",
  "codesign could not verify the temporary Developer ID signing probe",
  "does not chain to a root trusted by the native host",
  "ExportParameters",
  '"--options", "runtime"'
)) {
  if ($checkerText -notmatch [regex]::Escape($pattern)) {
    throw "Desktop signing readiness checker is missing a native sign-and-verify probe: $pattern"
  }
}
$passCount++
Write-Host "[PASS] native desktop credential checks sign and verify temporary executables"

$releaseWorkflow = Get-Content -LiteralPath $releaseWorkflowPath -Raw
foreach ($pattern in @("Validate production desktop signing credentials", "check_desktop_release_signing_readiness.ps1", "RequireNativeToolchain", "ValidateAppleNotaryCredentials")) {
  if ($releaseWorkflow -notmatch [regex]::Escape($pattern)) {
    throw "Tagged release workflow is missing desktop signing preflight: $pattern"
  }
}
$passCount++
Write-Host "[PASS] tagged release runs native desktop signing preflight"

$firmwareWorkflowPath = Join-Path $repoRoot ".github/workflows/firmware.yml"
$firmwareWorkflow = Get-Content -LiteralPath $firmwareWorkflowPath -Raw
foreach ($pattern in @("check_desktop_release_signing_readiness.*", "test_desktop_release_signing_readiness_contract.ps1", "Run desktop release signing readiness contract")) {
  if ($firmwareWorkflow -notmatch [regex]::Escape($pattern)) {
    throw "Firmware CI is missing desktop signing readiness contract coverage: $pattern"
  }
}
$passCount++
Write-Host "[PASS] companion CI runs the desktop signing readiness contract"

function New-ContractPkcs12Base64 {
  param(
    [string]$Subject,
    [string]$Password,
    [bool]$IncludeCodeSigningEku = $true,
    [int]$ValidDays = 365,
    [int]$KeyBits = 3072
  )

  $rsa = [System.Security.Cryptography.RSA]::Create($KeyBits)
  $certificate = $null
  try {
    $distinguishedName = New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Subject)
    $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
      $distinguishedName,
      $rsa,
      [System.Security.Cryptography.HashAlgorithmName]::SHA256,
      [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $request.CertificateExtensions.Add(
      (New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
        $true
      ))
    )
    if ($IncludeCodeSigningEku) {
      $oids = New-Object System.Security.Cryptography.OidCollection
      [void]$oids.Add((New-Object System.Security.Cryptography.Oid("1.3.6.1.5.5.7.3.3")))
      $request.CertificateExtensions.Add(
        (New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($oids, $false))
      )
    }
    $certificate = $request.CreateSelfSigned(
      [DateTimeOffset]::UtcNow.AddDays(-1),
      [DateTimeOffset]::UtcNow.AddDays($ValidDays)
    )
    $bytes = $certificate.Export(
      [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
      $Password
    )
    return [Convert]::ToBase64String($bytes)
  } finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    $rsa.Dispose()
  }
}

function Clear-ContractEnvironment {
  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null)
  }
}

function Set-WindowsContractEnvironment {
  param(
    [string]$Base64,
    [string]$Password
  )
  Clear-ContractEnvironment
  [Environment]::SetEnvironmentVariable("STACKCHAN_WINDOWS_PFX_B64", $Base64)
  [Environment]::SetEnvironmentVariable("STACKCHAN_WINDOWS_PFX_PASSWORD", $Password)
}

function Set-MacOSContractEnvironment {
  param(
    [string]$Base64,
    [string]$Password,
    [string]$Identity = "Developer ID Application: Stackchan Contract (AB12CD34EF)",
    [string]$AppleId = "release-contract@example.com",
    [string]$NotaryPassword = "notary-contract-password-Dd4!",
    [string]$TeamId = "AB12CD34EF"
  )
  Clear-ContractEnvironment
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_CERTIFICATE_B64", $Base64)
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_CERTIFICATE_PASSWORD", $Password)
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_SIGNING_IDENTITY", $Identity)
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_NOTARIZATION_APPLE_ID", $AppleId)
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_NOTARIZATION_PASSWORD", $NotaryPassword)
  [Environment]::SetEnvironmentVariable("STACKCHAN_MACOS_NOTARIZATION_TEAM_ID", $TeamId)
}

function Invoke-ContractCheck {
  param(
    [ValidateSet("windows", "macos")]
    [string]$Platform,
    [bool]$RequireReady = $true
  )

  $arguments = @("-NoProfile", "-File", $checker, "-Platform", $Platform, "-Json")
  if ($RequireReady) { $arguments += "-RequireReady" }
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $powerShellHost.Source @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  $text = ($output | Out-String).Trim()
  foreach ($secret in $secretValues) {
    if ($text.Contains($secret)) { throw "Desktop signing readiness output exposed a contract credential." }
  }
  try {
    $report = $text | ConvertFrom-Json
  } catch {
    throw "Desktop signing readiness output was not valid JSON: $text"
  }
  return [pscustomobject]@{ exitCode = $exitCode; report = $report }
}

function Assert-Result {
  param(
    [object]$Result,
    [int]$ExitCode,
    [string]$Status,
    [string]$DetailPattern,
    [string]$Name
  )

  if ($Result.exitCode -ne $ExitCode) {
    throw "$Name returned exit code $($Result.exitCode); expected $ExitCode. Status: $($Result.report.status). Issues: $(@($Result.report.issues) -join '; ')"
  }
  if ([string]$Result.report.status -ne $Status) {
    throw "$Name returned status '$($Result.report.status)'; expected '$Status'."
  }
  $details = @($Result.report.checks | ForEach-Object { [string]$_.detail }) -join "`n"
  if (-not [string]::IsNullOrWhiteSpace($DetailPattern) -and $details -notmatch [regex]::Escape($DetailPattern)) {
    throw "$Name did not report '$DetailPattern': $details"
  }
  $script:passCount++
  Write-Host "[PASS] $Name"
}

try {
  foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
  }

  $windowsPassword = $secretValues[0]
  $macosPassword = $secretValues[1]
  $wrongPassword = $secretValues[2]
  $windowsPfx = New-ContractPkcs12Base64 `
    -Subject "CN=Stackchan Windows Contract, OU=Release, O=Stackchan Contract, C=US" `
    -Password $windowsPassword
  $windowsNoEkuPfx = New-ContractPkcs12Base64 `
    -Subject "CN=Stackchan Windows No EKU, OU=Release, O=Stackchan Contract, C=US" `
    -Password $windowsPassword `
    -IncludeCodeSigningEku $false
  $windowsExpiringPfx = New-ContractPkcs12Base64 `
    -Subject "CN=Stackchan Windows Expiring, OU=Release, O=Stackchan Contract, C=US" `
    -Password $windowsPassword `
    -ValidDays 5
  $windowsWeakKeyPfx = New-ContractPkcs12Base64 `
    -Subject "CN=Stackchan Windows Weak Key, OU=Release, O=Stackchan Contract, C=US" `
    -Password $windowsPassword `
    -KeyBits 1024
  $macosIdentity = "Developer ID Application: Stackchan Contract (AB12CD34EF)"
  $macosPfx = New-ContractPkcs12Base64 `
    -Subject "CN=$macosIdentity, OU=AB12CD34EF, O=Stackchan Contract, C=US" `
    -Password $macosPassword

  Clear-ContractEnvironment
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows -RequireReady $false) `
    -ExitCode 0 `
    -Status "pending-credentials" `
    -DetailPattern "STACKCHAN_WINDOWS_PFX_B64" `
    -Name "missing Windows credentials remain pending"

  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 2 `
    -Status "pending-credentials" `
    -DetailPattern "STACKCHAN_WINDOWS_PFX_PASSWORD" `
    -Name "required Windows credentials fail closed when missing"

  Set-WindowsContractEnvironment -Base64 "not-base64" -Password $windowsPassword
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "not valid base64" `
    -Name "invalid Windows PKCS12 base64 is rejected"

  Set-WindowsContractEnvironment -Base64 $windowsPfx -Password $wrongPassword
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "could not be opened" `
    -Name "wrong Windows PKCS12 password is rejected"

  Set-WindowsContractEnvironment -Base64 $windowsNoEkuPfx -Password $windowsPassword
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "private code-signing certificate" `
    -Name "Windows certificate without code-signing EKU is rejected"

  Set-WindowsContractEnvironment -Base64 $windowsExpiringPfx -Password $windowsPassword
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "remain valid for at least 30 days" `
    -Name "near-expiry Windows certificate is rejected"

  Set-WindowsContractEnvironment -Base64 $windowsWeakKeyPfx -Password $windowsPassword
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform windows) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "unsupported or undersized public key" `
    -Name "undersized Windows signing key is rejected"

  Set-WindowsContractEnvironment -Base64 $windowsPfx -Password $windowsPassword
  $validWindows = Invoke-ContractCheck -Platform windows
  Assert-Result `
    -Result $validWindows `
    -ExitCode 0 `
    -Status "ready" `
    -DetailPattern "private code-signing certificate" `
    -Name "valid Windows signing credential material is accepted"
  if ($validWindows.report.certificate.keyAlgorithm -ne "RSA" -or [int]$validWindows.report.certificate.keyBits -ne 3072) {
    throw "Valid Windows signing material did not preserve its RSA key identity."
  }

  Set-MacOSContractEnvironment -Base64 $macosPfx -Password $macosPassword
  $validMacOS = Invoke-ContractCheck -Platform macos
  Assert-Result `
    -Result $validMacOS `
    -ExitCode 0 `
    -Status "ready" `
    -DetailPattern "valid identity" `
    -Name "valid macOS Developer ID credential material is accepted"
  if ([string]$validMacOS.report.certificate.simpleName -ne $macosIdentity) {
    throw "Valid macOS signing material did not preserve its Developer ID identity."
  }

  Set-MacOSContractEnvironment `
    -Base64 $macosPfx `
    -Password $macosPassword `
    -Identity "Developer ID Application: Wrong Contract (AB12CD34EF)"
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform macos) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "does not match the PKCS#12 certificate" `
    -Name "mismatched macOS signing identity is rejected"

  Set-MacOSContractEnvironment `
    -Base64 $macosPfx `
    -Password $macosPassword `
    -TeamId "ZZ98YY76XX"
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform macos) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "team ID does not match" `
    -Name "mismatched Apple team ID is rejected"

  Set-MacOSContractEnvironment `
    -Base64 $macosPfx `
    -Password $macosPassword `
    -AppleId "not-an-email"
  Assert-Result `
    -Result (Invoke-ContractCheck -Platform macos) `
    -ExitCode 1 `
    -Status "not-ready" `
    -DetailPattern "must be an email address" `
    -Name "invalid Apple notarization account shape is rejected"
} finally {
  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name])
  }
}

Write-Host "Desktop release signing readiness contract passed: $passCount checks."
exit 0
