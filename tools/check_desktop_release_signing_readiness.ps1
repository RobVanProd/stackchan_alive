param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("windows", "macos")]
  [string]$Platform,
  [switch]$RequireReady,
  [switch]$RequireNativeToolchain,
  [switch]$ValidateAppleNotaryCredentials,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$codeSigningOid = "1.3.6.1.5.5.7.3.3"
$minimumRemainingDays = 30
$checks = @()
$issues = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
  if ($Status -eq "fail") { $script:issues += $Detail }
}

function Get-HostPlatform {
  if ($env:OS -eq "Windows_NT") { return "windows" }
  try {
    $uname = (& uname -s 2>$null | Out-String).Trim().ToLowerInvariant()
    if ($uname -eq "darwin") { return "macos" }
    if ($uname -eq "linux") { return "linux" }
  } catch {
  }
  return "unknown"
}

function Invoke-NativeCommand {
  param(
    [string]$Command,
    [string[]]$Arguments
  )

  $output = ""
  $exitCode = -1
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = (& $Command @Arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
  } catch {
    $output = $_.Exception.Message
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  return [pscustomobject]@{ exitCode = $exitCode; output = $output }
}

function Find-WindowsSignTool {
  $command = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -ne $command) { return [string]$command.Source }

  $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
  if ([string]::IsNullOrWhiteSpace($programFilesX86)) { return "" }
  $kitsRoot = Join-Path $programFilesX86 "Windows Kits/10/bin"
  if (-not (Test-Path -LiteralPath $kitsRoot -PathType Container)) { return "" }
  $candidate = Get-ChildItem -LiteralPath $kitsRoot -Recurse -File -Filter "signtool.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if ($null -eq $candidate) { return "" }
  return [string]$candidate.FullName
}

function Test-NativeWindowsCredentialMaterial {
  param(
    [string]$SignToolPath,
    [byte[]]$Pkcs12Bytes,
    [string]$Password
  )

  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("stackchan-signing-readiness-" + [guid]::NewGuid().ToString("N"))
  $certificatePath = Join-Path $temporaryRoot "authenticode.p12"
  $probePath = Join-Path $temporaryRoot "stackchan-signing-probe.exe"
  try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    [IO.File]::WriteAllBytes($certificatePath, $Pkcs12Bytes)

    $sourceExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ([string]::IsNullOrWhiteSpace($sourceExecutable) -or -not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
      throw "The current PowerShell executable is unavailable for a native signing probe."
    }
    Copy-Item -LiteralPath $sourceExecutable -Destination $probePath

    $signed = Invoke-NativeCommand $SignToolPath @(
      "sign", "/fd", "SHA256", "/f", $certificatePath, "/p", $Password, $probePath
    )
    if ($signed.exitCode -ne 0) {
      throw "SignTool could not sign a temporary executable with the configured PKCS#12 credential."
    }
    $verified = Invoke-NativeCommand $SignToolPath @("verify", "/pa", "/all", "/v", $probePath)
    if ($verified.exitCode -ne 0) {
      throw "SignTool could not verify the temporary Authenticode signing probe."
    }
  } finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-RequiredEnvironment {
  param([string[]]$Names)

  $values = @{}
  $missing = @()
  foreach ($name in $Names) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
      $missing += $name
    } else {
      $values[$name] = $value
    }
  }
  return [pscustomobject]@{ values = $values; missing = @($missing) }
}

function Test-CodeSigningEku {
  param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

  $ekuExtensions = @($Certificate.Extensions | Where-Object {
    $_.Oid.Value -eq "2.5.29.37"
  })
  foreach ($extension in $ekuExtensions) {
    $eku = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
    foreach ($oid in $eku.EnhancedKeyUsages) {
      if ($oid.Value -eq $script:codeSigningOid) { return $true }
    }
  }
  return $false
}

function Get-KeySummary {
  param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

  $algorithm = [string]$Certificate.PublicKey.Oid.FriendlyName
  $bits = 0
  $key = $null
  try {
    if ($Certificate.PublicKey.Oid.Value -eq "1.2.840.113549.1.1.1") {
      $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
      $algorithm = "RSA"
    } elseif ($Certificate.PublicKey.Oid.Value -eq "1.2.840.10045.2.1") {
      $key = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($Certificate)
      $algorithm = "ECDSA"
    }
    if ($null -ne $key) { $bits = [int]$key.KeySize }
  } finally {
    if ($null -ne $key) { $key.Dispose() }
  }
  return [pscustomobject]@{ algorithm = $algorithm; bits = $bits }
}

function Test-NativeCertificateTrust {
  param(
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
    [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]$Certificates
  )

  $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
  try {
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
    foreach ($item in $Certificates) {
      if (-not [object]::ReferenceEquals($item, $Certificate)) {
        [void]$chain.ChainPolicy.ExtraStore.Add($item)
      }
    }
    if (-not $chain.Build($Certificate)) {
      throw "The code-signing certificate does not chain to a root trusted by the native host."
    }
  } finally {
    $chain.Dispose()
  }
}

function Get-SigningCertificate {
  param(
    [string]$Base64Value,
    [string]$Password
  )

  try {
    $bytes = [Convert]::FromBase64String($Base64Value)
  } catch {
    throw "The configured PKCS#12 value is not valid base64."
  }

  $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
  try {
    $collection.Import($bytes, $Password, $flags)
  } catch {
    throw "The configured PKCS#12 value could not be opened with its password."
  }

  $candidates = @($collection | Where-Object {
    $_.HasPrivateKey -and (Test-CodeSigningEku $_)
  })
  if ($candidates.Count -ne 1) {
    foreach ($item in $collection) { $item.Dispose() }
    throw "The PKCS#12 bundle must contain exactly one private code-signing certificate."
  }

  $selected = $candidates[0]
  return [pscustomobject]@{ certificate = $selected; certificates = $collection; bytes = $bytes }
}

function Test-NativeMacOSCredentialMaterial {
  param(
    [byte[]]$Pkcs12Bytes,
    [string]$Password,
    [string]$Identity
  )

  $security = Get-Command security -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $security) { throw "The macOS security tool is unavailable." }
  $codesign = Get-Command codesign -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $codesign) { throw "The macOS codesign tool is unavailable." }

  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("stackchan-signing-readiness-" + [guid]::NewGuid().ToString("N"))
  $certificatePath = Join-Path $temporaryRoot "developer-id.p12"
  $keychainPath = Join-Path $temporaryRoot "readiness.keychain-db"
  $probePath = Join-Path $temporaryRoot "stackchan-signing-probe"
  $keychainPassword = [guid]::NewGuid().ToString("N")
  try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    [IO.File]::WriteAllBytes($certificatePath, $Pkcs12Bytes)
    $created = Invoke-NativeCommand $security.Source @("create-keychain", "-p", $keychainPassword, $keychainPath)
    if ($created.exitCode -ne 0) { throw "A temporary validation keychain could not be created." }
    $unlocked = Invoke-NativeCommand $security.Source @("unlock-keychain", "-p", $keychainPassword, $keychainPath)
    if ($unlocked.exitCode -ne 0) { throw "The temporary validation keychain could not be unlocked." }
    $imported = Invoke-NativeCommand $security.Source @("import", $certificatePath, "-k", $keychainPath, "-P", $Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    if ($imported.exitCode -ne 0) { throw "The Developer ID certificate could not be imported into a temporary keychain." }
    $partitioned = Invoke-NativeCommand $security.Source @("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", $keychainPassword, $keychainPath)
    if ($partitioned.exitCode -ne 0) { throw "The imported Developer ID private key could not be enabled for codesign." }
    $identities = Invoke-NativeCommand $security.Source @("find-identity", "-v", "-p", "codesigning", $keychainPath)
    if ($identities.exitCode -ne 0 -or $identities.output.IndexOf($Identity, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
      throw "The configured Developer ID signing identity was not found after native keychain import."
    }
    Copy-Item -LiteralPath "/usr/bin/true" -Destination $probePath
    $signed = Invoke-NativeCommand $codesign.Source @(
      "--force", "--sign", $Identity, "--keychain", $keychainPath,
      "--options", "runtime", "--timestamp=none", $probePath
    )
    if ($signed.exitCode -ne 0) {
      throw "codesign could not sign a temporary hardened-runtime executable with the configured Developer ID credential."
    }
    $verified = Invoke-NativeCommand $codesign.Source @("--verify", "--strict", "--verbose=2", $probePath)
    if ($verified.exitCode -ne 0) {
      throw "codesign could not verify the temporary Developer ID signing probe."
    }
  } finally {
    if (Test-Path -LiteralPath $keychainPath) {
      [void](Invoke-NativeCommand $security.Source @("delete-keychain", $keychainPath))
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$requiredNames = if ($Platform -eq "windows") {
  @("STACKCHAN_WINDOWS_PFX_B64", "STACKCHAN_WINDOWS_PFX_PASSWORD")
} else {
  @(
    "STACKCHAN_MACOS_CERTIFICATE_B64",
    "STACKCHAN_MACOS_CERTIFICATE_PASSWORD",
    "STACKCHAN_MACOS_SIGNING_IDENTITY",
    "STACKCHAN_MACOS_NOTARIZATION_APPLE_ID",
    "STACKCHAN_MACOS_NOTARIZATION_PASSWORD",
    "STACKCHAN_MACOS_NOTARIZATION_TEAM_ID"
  )
}

$configured = Get-RequiredEnvironment $requiredNames
$certificateSummary = [ordered]@{
  subject = ""
  simpleName = ""
  thumbprint = ""
  notBeforeUtc = ""
  notAfterUtc = ""
  keyAlgorithm = ""
  keyBits = 0
  hasPrivateKey = $false
  codeSigningEku = $false
}
$nativeToolchainValidated = $false
$appleNotaryCredentialsValidated = $false

if ($configured.missing.Count -gt 0) {
  Add-Check "credential-presence" "pending" ("Missing required environment names: " + ($configured.missing -join ", ") + ".")
} else {
  Add-Check "credential-presence" "pass" "All required environment names are configured."
  $certificate = $null
  $material = $null
  try {
    $base64Name = if ($Platform -eq "windows") { "STACKCHAN_WINDOWS_PFX_B64" } else { "STACKCHAN_MACOS_CERTIFICATE_B64" }
    $passwordName = if ($Platform -eq "windows") { "STACKCHAN_WINDOWS_PFX_PASSWORD" } else { "STACKCHAN_MACOS_CERTIFICATE_PASSWORD" }
    $material = Get-SigningCertificate -Base64Value $configured.values[$base64Name] -Password $configured.values[$passwordName]
    $certificate = $material.certificate
    $key = Get-KeySummary $certificate
    $simpleName = $certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    $certificateSummary.subject = [string]$certificate.Subject
    $certificateSummary.simpleName = [string]$simpleName
    $certificateSummary.thumbprint = ([string]$certificate.Thumbprint).ToLowerInvariant()
    $certificateSummary.notBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString("o")
    $certificateSummary.notAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString("o")
    $certificateSummary.keyAlgorithm = [string]$key.algorithm
    $certificateSummary.keyBits = [int]$key.bits
    $certificateSummary.hasPrivateKey = [bool]$certificate.HasPrivateKey
    $certificateSummary.codeSigningEku = Test-CodeSigningEku $certificate

    $now = [DateTime]::UtcNow
    if ($certificate.NotBefore.ToUniversalTime() -gt $now) {
      throw "The code-signing certificate is not valid yet."
    }
    if ($certificate.NotAfter.ToUniversalTime() -lt $now.AddDays($minimumRemainingDays)) {
      throw "The code-signing certificate must remain valid for at least $minimumRemainingDays days."
    }
    if (($key.algorithm -eq "RSA" -and $key.bits -lt 2048) -or ($key.algorithm -eq "ECDSA" -and $key.bits -lt 256) -or $key.bits -le 0) {
      throw "The code-signing certificate uses an unsupported or undersized public key."
    }

    if ($Platform -eq "macos") {
      $identity = [string]$configured.values["STACKCHAN_MACOS_SIGNING_IDENTITY"]
      $teamId = [string]$configured.values["STACKCHAN_MACOS_NOTARIZATION_TEAM_ID"]
      $appleId = [string]$configured.values["STACKCHAN_MACOS_NOTARIZATION_APPLE_ID"]
      if ($identity -notmatch '^Developer ID Application: ') {
        throw "STACKCHAN_MACOS_SIGNING_IDENTITY must name a Developer ID Application identity."
      }
      if (-not [string]::Equals($simpleName, $identity, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The configured macOS signing identity does not match the PKCS#12 certificate."
      }
      if ($teamId -notmatch '^[A-Z0-9]{10}$' -or
          $certificate.Subject.IndexOf("OU=$teamId", [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
          $simpleName.IndexOf("($teamId)", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "The configured Apple team ID does not match the Developer ID certificate."
      }
      if ($appleId -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw "STACKCHAN_MACOS_NOTARIZATION_APPLE_ID must be an email address."
      }
    }

    Add-Check "certificate-material" "pass" "A private code-signing certificate with a valid identity, lifetime, and key is present."

    if ($RequireNativeToolchain) {
      $hostPlatform = Get-HostPlatform
      if ($hostPlatform -ne $Platform) {
        throw "Native $Platform signing validation requires a $Platform host."
      }
      Test-NativeCertificateTrust -Certificate $certificate -Certificates $material.certificates
      if ($Platform -eq "windows") {
        $signToolPath = Find-WindowsSignTool
        if ([string]::IsNullOrWhiteSpace($signToolPath)) {
          throw "signtool.exe is unavailable in the native Windows toolchain."
        }
        Test-NativeWindowsCredentialMaterial `
          -SignToolPath $signToolPath `
          -Pkcs12Bytes $material.bytes `
          -Password $configured.values["STACKCHAN_WINDOWS_PFX_PASSWORD"]
      } else {
        foreach ($tool in @("codesign", "security", "xcrun")) {
          if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            throw "The native macOS signing tool '$tool' is unavailable."
          }
        }
        Test-NativeMacOSCredentialMaterial `
          -Pkcs12Bytes $material.bytes `
          -Password $configured.values["STACKCHAN_MACOS_CERTIFICATE_PASSWORD"] `
          -Identity $configured.values["STACKCHAN_MACOS_SIGNING_IDENTITY"]
      }
      $nativeToolchainValidated = $true
      Add-Check "native-toolchain" "pass" "The native signing toolchain accepted the configured credential material."
    }

    if ($ValidateAppleNotaryCredentials) {
      if ($Platform -ne "macos") { throw "Apple notarization credential validation is only valid for macOS." }
      if ((Get-HostPlatform) -ne "macos") { throw "Apple notarization credential validation requires a native macOS host." }
      $xcrun = Get-Command xcrun -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $xcrun) { throw "xcrun is unavailable for Apple notarization credential validation." }
      $notaryResult = Invoke-NativeCommand $xcrun.Source @(
        "notarytool", "history",
        "--apple-id", $configured.values["STACKCHAN_MACOS_NOTARIZATION_APPLE_ID"],
        "--password", $configured.values["STACKCHAN_MACOS_NOTARIZATION_PASSWORD"],
        "--team-id", $configured.values["STACKCHAN_MACOS_NOTARIZATION_TEAM_ID"],
        "--output-format", "json"
      )
      if ($notaryResult.exitCode -ne 0) { throw "Apple rejected the configured notarization credentials." }
      $appleNotaryCredentialsValidated = $true
      Add-Check "apple-notary-credentials" "pass" "Apple accepted the configured notarization credentials."
    }
  } catch {
    Add-Check "credential-validation" "fail" $_.Exception.Message
  } finally {
    if ($null -ne $material -and $null -ne $material.certificates) {
      foreach ($item in $material.certificates) { $item.Dispose() }
    } elseif ($null -ne $certificate) {
      $certificate.Dispose()
    }
    if ($null -ne $material -and $null -ne $material.bytes) {
      [Array]::Clear($material.bytes, 0, $material.bytes.Length)
    }
  }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pending = @($checks | Where-Object { $_.status -eq "pending" }).Count
$status = if ($failed -gt 0) { "not-ready" } elseif ($pending -gt 0) { "pending-credentials" } else { "ready" }
$report = [ordered]@{
  schema = "stackchan.desktop-signing-readiness.v1"
  status = $status
  platform = $Platform
  hostPlatform = Get-HostPlatform
  generatedAtUtc = [DateTime]::UtcNow.ToString("o")
  requiredEnvironmentNames = @($requiredNames)
  certificate = $certificateSummary
  nativeToolchainRequired = [bool]$RequireNativeToolchain
  nativeToolchainValidated = $nativeToolchainValidated
  appleNotaryCredentialsRequired = [bool]$ValidateAppleNotaryCredentials
  appleNotaryCredentialsValidated = $appleNotaryCredentialsValidated
  checks = @($checks)
  issues = @($issues)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 6
} else {
  Write-Host "Desktop signing readiness: $status ($Platform)"
  foreach ($check in $checks) { Write-Host "[$($check.status)] $($check.id): $($check.detail)" }
}

if ($failed -gt 0) { exit 1 }
if ($RequireReady -and $status -ne "ready") { exit 2 }
