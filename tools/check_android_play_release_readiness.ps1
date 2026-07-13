param(
  [string]$Root = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Get-ConfiguredValue {
  param([string]$Name)

  $environmentValue = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
    return [ordered]@{
      source = "environment"
      value = $environmentValue
    }
  }

  $propertiesPath = Join-RootPath "companion/gradle.properties"
  if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $propertiesPath) {
      $trimmed = $line.Trim()
      if ($trimmed.StartsWith("#") -or $trimmed -notmatch "^$([regex]::Escape($Name))\s*=\s*(.+)$") {
        continue
      }
      return [ordered]@{
        source = "companion/gradle.properties"
        value = $matches[1].Trim()
      }
    }
  }

  return [ordered]@{
    source = ""
    value = ""
  }
}

function Invoke-KeytoolCommand {
  param(
    [string]$KeytoolPath,
    [string[]]$Arguments
  )

  $output = @()
  $exitCode = -1
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $KeytoolPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    $output = @($_.Exception.Message)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    exitCode = $exitCode
    output = @($output | ForEach-Object { [string]$_ })
  }
}

function Get-CertificateFromPemOutput {
  param([string[]]$Output)

  $text = $Output -join "`n"
  $match = [regex]::Match(
    $text,
    "-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----",
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  if (-not $match.Success) {
    throw "keytool did not return a PEM certificate."
  }

  $base64 = $match.Groups["body"].Value -replace "\s", ""
  $rawCertificate = [Convert]::FromBase64String($base64)
  return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $rawCertificate)
}

function Test-PlayUploadSigningEnvironment {
  $requiredNames = @(
    "STACKCHAN_ANDROID_KEYSTORE",
    "STACKCHAN_ANDROID_KEYSTORE_PASSWORD",
    "STACKCHAN_ANDROID_KEY_ALIAS",
    "STACKCHAN_ANDROID_KEY_PASSWORD"
  )
  $configured = @{}
  $missing = @()
  foreach ($name in $requiredNames) {
    $value = Get-ConfiguredValue $name
    $configured[$name] = $value
    if ([string]::IsNullOrWhiteSpace([string]$value.value)) {
      $missing += $name
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "pending" `
      -Evidence "STACKCHAN_ANDROID_KEYSTORE*" `
      -Detail ("Upload signing credentials are not configured yet; missing " + ($missing -join ", ") + ". Release tasks fail closed; lab debug signing requires the explicit stackchan.allowLabDebugReleaseSigning property.")
    return
  }

  $keystorePath = [string]$configured["STACKCHAN_ANDROID_KEYSTORE"].value
  $resolvedKeystore = if ([System.IO.Path]::IsPathRooted($keystorePath)) { $keystorePath } else { Join-Path $Root $keystorePath }
  if (-not (Test-Path -LiteralPath $resolvedKeystore -PathType Leaf)) {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "fail" `
      -Evidence "STACKCHAN_ANDROID_KEYSTORE" `
      -Detail "Upload signing variables are present, but the configured keystore file does not exist."
    return
  }

  $keytool = Get-Command keytool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $keytool) {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "fail" `
      -Evidence "keytool" `
      -Detail "Upload signing variables are configured, but keytool is unavailable for cryptographic validation."
    return
  }

  $storePasswordEnvironmentName = "STACKCHAN_KEYTOOL_STORE_PASSWORD"
  $keyPasswordEnvironmentName = "STACKCHAN_KEYTOOL_KEY_PASSWORD"
  $destinationPasswordEnvironmentName = "STACKCHAN_KEYTOOL_DESTINATION_PASSWORD"
  $temporaryEnvironment = [ordered]@{
    $storePasswordEnvironmentName = [string]$configured["STACKCHAN_ANDROID_KEYSTORE_PASSWORD"].value
    $keyPasswordEnvironmentName = [string]$configured["STACKCHAN_ANDROID_KEY_PASSWORD"].value
    $destinationPasswordEnvironmentName = ([guid]::NewGuid().ToString("N") + "Aa1!")
  }
  $previousEnvironment = @{}
  $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-upload-key-check-" + [guid]::NewGuid().ToString("N"))
  $temporaryKeyStore = Join-Path $temporaryDirectory "private-key-check.p12"
  $certificate = $null
  $rsa = $null
  $sha256 = $null

  try {
    New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
    foreach ($entry in $temporaryEnvironment.GetEnumerator()) {
      $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
      [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }

    $alias = [string]$configured["STACKCHAN_ANDROID_KEY_ALIAS"].value
    $listResult = Invoke-KeytoolCommand -KeytoolPath $keytool.Source -Arguments @(
      "-list",
      "-v",
      "-keystore", $resolvedKeystore,
      "-storepass:env", $storePasswordEnvironmentName,
      "-alias", $alias
    )
    if ($listResult.exitCode -ne 0) {
      Add-Check `
        -Id "play-upload-signing-environment" `
        -Name "Play upload signing environment" `
        -Status "fail" `
        -Evidence "keytool keystore/alias validation" `
        -Detail "The configured keystore could not be opened with the configured store password and alias."
      return
    }

    # Importing only the selected entry into a disposable store proves that it is a private key
    # and that both the store and key passwords are correct without modifying the source keystore.
    $privateKeyResult = Invoke-KeytoolCommand -KeytoolPath $keytool.Source -Arguments @(
      "-importkeystore",
      "-srckeystore", $resolvedKeystore,
      "-srcstorepass:env", $storePasswordEnvironmentName,
      "-srcalias", $alias,
      "-srckeypass:env", $keyPasswordEnvironmentName,
      "-destkeystore", $temporaryKeyStore,
      "-deststoretype", "PKCS12",
      "-deststorepass:env", $destinationPasswordEnvironmentName,
      "-destkeypass:env", $destinationPasswordEnvironmentName,
      "-noprompt"
    )
    if ($privateKeyResult.exitCode -ne 0) {
      Add-Check `
        -Id "play-upload-signing-environment" `
        -Name "Play upload signing environment" `
        -Status "fail" `
        -Evidence "keytool private-key validation" `
        -Detail "The configured alias is not an exportable private-key entry with the configured key password."
      return
    }

    $certificateResult = Invoke-KeytoolCommand -KeytoolPath $keytool.Source -Arguments @(
      "-exportcert",
      "-rfc",
      "-keystore", $resolvedKeystore,
      "-storepass:env", $storePasswordEnvironmentName,
      "-alias", $alias
    )
    if ($certificateResult.exitCode -ne 0) {
      Add-Check `
        -Id "play-upload-signing-environment" `
        -Name "Play upload signing environment" `
        -Status "fail" `
        -Evidence "keytool certificate validation" `
        -Detail "The configured private-key certificate could not be exported for validation."
      return
    }

    $certificate = Get-CertificateFromPemOutput -Output $certificateResult.output
    $issues = New-Object System.Collections.Generic.List[string]
    $rsaKeySize = 0
    if ($certificate.PublicKey.Oid.Value -ne "1.2.840.113549.1.1.1") {
      $issues.Add("certificate public key is not RSA")
    } else {
      try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $rsa) {
          $issues.Add("certificate RSA public key could not be read")
        } else {
          $rsaKeySize = $rsa.KeySize
          if ($rsaKeySize -lt 4096) {
            $issues.Add("RSA key size is $rsaKeySize bits; project policy requires at least 4096 bits")
          }
        }
      } catch {
        $issues.Add("certificate RSA public key could not be read")
      }
    }

    if ($certificate.Subject -match "(?i)Android Debug") {
      $issues.Add("certificate subject identifies an Android debug key")
    }

    $nowUtc = [DateTime]::UtcNow
    $notBeforeUtc = $certificate.NotBefore.ToUniversalTime()
    $notAfterUtc = $certificate.NotAfter.ToUniversalTime()
    $playExpiryFloorUtc = [DateTime]::ParseExact(
      "2033-10-23T00:00:00Z",
      "yyyy-MM-dd'T'HH:mm:ss'Z'",
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime()
    if ($notBeforeUtc -gt $nowUtc.AddMinutes(5)) {
      $issues.Add("certificate is not valid yet")
    }
    if ($notAfterUtc -le $nowUtc) {
      $issues.Add("certificate has expired")
    } elseif ($notAfterUtc -lt $playExpiryFloorUtc) {
      $issues.Add("certificate expires before the Google Play minimum of 2033-10-23 UTC")
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $fingerprintBytes = $sha256.ComputeHash($certificate.RawData)
    $fingerprint = ($fingerprintBytes | ForEach-Object { $_.ToString("X2") }) -join ":"
    if ($issues.Count -gt 0) {
      Add-Check `
        -Id "play-upload-signing-environment" `
        -Name "Play upload signing environment" `
        -Status "fail" `
        -Evidence "keytool certificate/private-key validation" `
        -Detail ("Upload key validation failed: " + ($issues -join "; ") + ".")
      return
    }

    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "pass" `
      -Evidence "keytool certificate/private-key validation" `
      -Detail ("Validated private-key entry: RSA $rsaKeySize bits, expires " + $notAfterUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + ", certificate SHA-256 $fingerprint.")
  } catch {
    Add-Check `
      -Id "play-upload-signing-environment" `
      -Name "Play upload signing environment" `
      -Status "fail" `
      -Evidence "keytool certificate/private-key validation" `
      -Detail "Upload signing material could not be validated. No credential values were emitted."
  } finally {
    if ($null -ne $sha256) {
      $sha256.Dispose()
    }
    if ($null -ne $rsa) {
      $rsa.Dispose()
    }
    if ($null -ne $certificate) {
      $certificate.Dispose()
    }
    foreach ($entry in $temporaryEnvironment.GetEnumerator()) {
      if ($null -eq $previousEnvironment[$entry.Key]) {
        [Environment]::SetEnvironmentVariable($entry.Key, $null)
      } else {
        [Environment]::SetEnvironmentVariable($entry.Key, $previousEnvironment[$entry.Key])
      }
    }
    if (Test-Path -LiteralPath $temporaryDirectory) {
      Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
  }
}

function Join-RootPath {
  param([string]$RelativePath)
  return Join-Path $Root $RelativePath
}

function Test-FilePresent {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath
  )

  $path = Join-RootPath $RelativePath
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    Add-Check $Id $Name "pass" $RelativePath "File exists."
  } else {
    Add-Check $Id $Name "fail" $RelativePath "File is missing."
  }
}

function Test-TextPatterns {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath,
    [string[]]$Patterns
  )

  $path = Join-RootPath $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "fail" $RelativePath "File is missing."
    return
  }
  $text = Get-Content -LiteralPath $path -Raw
  $missing = @($Patterns | Where-Object { $text -notmatch [regex]::Escape($_) })
  if ($missing.Count -eq 0) {
    Add-Check $Id $Name "pass" $RelativePath "All expected patterns are present."
  } else {
    Add-Check $Id $Name "fail" $RelativePath ("Missing: " + ($missing -join ", "))
  }
}

function Get-PngDimensions {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 24) {
    throw "PNG file is too small."
  }
  $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
  for ($index = 0; $index -lt $signature.Count; $index++) {
    if ($bytes[$index] -ne $signature[$index]) {
      throw "PNG signature mismatch."
    }
  }
  $widthBytes = $bytes[16..19]
  $heightBytes = $bytes[20..23]
  if ([BitConverter]::IsLittleEndian) {
    [array]::Reverse($widthBytes)
    [array]::Reverse($heightBytes)
  }
  return [ordered]@{
    width = [BitConverter]::ToInt32($widthBytes, 0)
    height = [BitConverter]::ToInt32($heightBytes, 0)
  }
}

function Test-PngSize {
  param(
    [string]$Id,
    [string]$Name,
    [string]$RelativePath,
    [int]$ExpectedWidth,
    [int]$ExpectedHeight
  )

  $path = Join-RootPath $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Add-Check $Id $Name "fail" $RelativePath "PNG is missing."
    return
  }
  try {
    $dimensions = Get-PngDimensions $path
    if ($dimensions.width -eq $ExpectedWidth -and $dimensions.height -eq $ExpectedHeight) {
      Add-Check $Id $Name "pass" $RelativePath "PNG is $($dimensions.width)x$($dimensions.height)."
    } else {
      Add-Check $Id $Name "fail" $RelativePath "Expected ${ExpectedWidth}x${ExpectedHeight}; found $($dimensions.width)x$($dimensions.height)."
    }
  } catch {
    Add-Check $Id $Name "fail" $RelativePath $_.Exception.Message
  }
}

Test-TextPatterns `
  -Id "manifest-launcher-icon" `
  -Name "Manifest launcher icon wiring" `
  -RelativePath "companion/app-android/src/main/AndroidManifest.xml" `
  -Patterns @('android:icon="@mipmap/ic_launcher"', 'android:roundIcon="@mipmap/ic_launcher_round"', 'android:label="Stackchan Companion"')

Test-FilePresent "adaptive-icon" "Adaptive launcher icon" "companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"
Test-FilePresent "round-adaptive-icon" "Round adaptive launcher icon" "companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml"
Test-FilePresent "icon-foreground" "Launcher foreground vector" "companion/app-android/src/main/res/drawable/ic_launcher_foreground.xml"
Test-FilePresent "icon-monochrome" "Launcher monochrome vector" "companion/app-android/src/main/res/drawable/ic_launcher_monochrome.xml"
Test-PngSize "play-icon-png" "Play high-resolution icon" "docs/store-assets/play/icon-512.png" 512 512
Test-PngSize "play-feature-graphic" "Play feature graphic" "docs/store-assets/play/feature-graphic-1024x500.png" 1024 500

Test-TextPatterns `
  -Id "play-screenshot-capture-plan" `
  -Name "Play screenshot capture plan" `
  -RelativePath "docs/store-assets/play/SCREENSHOT_CAPTURE_PLAN.md" `
  -Patterns @("Play Screenshot Capture Plan", "phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics", "physical Android phone", "square Stack-chan display face", "final internal-testing or release-candidate build")

Test-TextPatterns `
  -Id "gradle-play-signing" `
  -Name "Gradle Play upload signing inputs" `
  -RelativePath "companion/app-android/build.gradle.kts" `
  -Patterns @("STACKCHAN_ANDROID_KEYSTORE", "STACKCHAN_ANDROID_KEYSTORE_PASSWORD", "STACKCHAN_ANDROID_KEY_ALIAS", "STACKCHAN_ANDROID_KEY_PASSWORD", "playRelease", "isDebuggable = false", "stackchan.allowLabDebugReleaseSigning", "verifyReleaseSigning", "Android release signing is not configured")

Test-PlayUploadSigningEnvironment

Test-TextPatterns `
  -Id "ci-aab-build" `
  -Name "CI builds Android release bundle" `
  -RelativePath ".github/workflows/firmware.yml" `
  -Patterns @(":app-android:bundleRelease", "companion/app-android/build/outputs/bundle/release/*.aab")

Test-TextPatterns `
  -Id "ci-android-emulator-launch-smoke" `
  -Name "CI runs Android emulator launch smoke" `
  -RelativePath ".github/workflows/firmware.yml" `
  -Patterns @("companion-android-emulator-smoke", "companion-android-apks", "actions/download-artifact@v7", "system-images;android-35;aosp_atd;x86_64", "test_android_emulator_launch.ps1", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "output/android-emulator-smoke/latest/**")

Test-TextPatterns `
  -Id "tag-android-emulator-release-gate" `
  -Name "Tag release validates upload key and exact release APK launch" `
  -RelativePath ".github/workflows/release.yml" `
  -Patterns @("Validate Android upload key", "check_android_play_release_readiness.ps1", "companion-android-emulator-smoke", "Download upload-signed Android release", "Run upload-signed Android emulator launch smoke", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence")

Test-TextPatterns `
  -Id "release-evidence-aab" `
  -Name "Release evidence covers AAB signing" `
  -RelativePath "tools/export_companion_release_evidence.ps1" `
  -Patterns @("*.aab", "androidBundleSigning", "android-release-aab-signature", "jarsigner")

Test-TextPatterns `
  -Id "release-evidence-emulator-apk-binding" `
  -Name "Release evidence binds emulator smoke to the release APK" `
  -RelativePath "tools/export_companion_release_evidence.ps1" `
  -Patterns @("AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "check_android_emulator_release_evidence.ps1", "androidEmulatorEvidenceRequired", "android-emulator-release-apk-evidence")

Test-TextPatterns `
  -Id "play-store-evidence-checker" `
  -Name "Play Store evidence checker" `
  -RelativePath "tools/check_android_play_store_evidence.ps1" `
  -Patterns @("stackchan.android-play-store-evidence.v1", "applicationId", "releaseAabSha256", "playSigningEnabled", "privacyPolicyUrl", "privacyPolicySourcePath", "docs/ANDROID_PLAY_PRIVACY_POLICY.md", "internalTestingInstallStatus", "screenshots", "phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics", "DATA_SAFETY_REVIEW.md", "POLICY_REVIEW.md", "ANDROID_PLAY_POLICY_DECLARATIONS.md", "raw microphone audio is not stored")

Test-TextPatterns `
  -Id "play-release-doc" `
  -Name "Play release checklist" `
  -RelativePath "docs/ANDROID_PLAY_RELEASE.md" `
  -Patterns @("Android Play Release Checklist", "app-android-release.aab", "Play App Signing", "cryptographically validates", "test_android_upload_signing_contract.ps1", "certificate SHA-256 fingerprint", "CI runtime smoke", "API 35 AOSP ATD", "feature-graphic-1024x500.png", "SCREENSHOT_CAPTURE_PLAN.md", "ANDROID_PLAY_POLICY_DECLARATIONS.md", "ANDROID_PLAY_PRIVACY_POLICY.md", "check_android_play_store_evidence.cmd", "Play Console internal testing", "RECORD_AUDIO")

Test-TextPatterns `
  -Id "play-policy-declarations" `
  -Name "Play policy and data-safety declarations" `
  -RelativePath "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md" `
  -Patterns @("Google Play Data safety form", "Privacy policy URL", "ANDROID_PLAY_PRIVACY_POLICY.md", "Data Safety Draft", "Not collected", "RECORD_AUDIO", "raw microphone audio is not stored", "password_redacted=true", "Foreground service Play Console draft", "connectedDevice", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "not directed to children")

Test-TextPatterns `
  -Id "play-privacy-policy-page" `
  -Name "Play-facing privacy policy page" `
  -RelativePath "docs/ANDROID_PLAY_PRIVACY_POLICY.md" `
  -Patterns @("Stackchan Companion Privacy Policy", "dev.stackchan.companion", "does not create accounts", "does not persist raw microphone audio", "diagnostics export", "password_redacted=true", "optional Mobile Brain model", "saved robot and trusted companion records", "not directed to children")

foreach ($relativePath in @(
  "fastlane/metadata/android/en-US/title.txt",
  "fastlane/metadata/android/en-US/short_description.txt",
  "fastlane/metadata/android/en-US/full_description.txt",
  "fastlane/metadata/android/en-US/changelogs/1.txt"
)) {
  Test-FilePresent ("metadata-" + ($relativePath -replace "[^A-Za-z0-9]+", "-").Trim("-")) "Play listing metadata" $relativePath
}

Test-TextPatterns `
  -Id "play-listing-title" `
  -Name "Play listing title" `
  -RelativePath "fastlane/metadata/android/en-US/title.txt" `
  -Patterns @("Stackchan Companion")

Test-TextPatterns `
  -Id "play-listing-short-description" `
  -Name "Play listing short description" `
  -RelativePath "fastlane/metadata/android/en-US/short_description.txt" `
  -Patterns @("Local companion bridge", "Stack-chan")

Test-TextPatterns `
  -Id "play-listing-full-description" `
  -Name "Play listing full description" `
  -RelativePath "fastlane/metadata/android/en-US/full_description.txt" `
  -Patterns @("pairing", "phone-side companion bridge", "saved Stack-chan nodes", "Live dashboard", "square Stack-chan face preview", "Push-to-talk", "Gemma-4-E2B", "download", "load", "eject", "Persona import/export", "diagnostics export", "trusted companion-node", "local-first", "raw microphone audio is not stored", "internal testing", "physical robot validation", "screen-off bridge soak evidence")

Test-TextPatterns `
  -Id "play-listing-changelog" `
  -Name "Play listing changelog" `
  -RelativePath "fastlane/metadata/android/en-US/changelogs/1.txt" `
  -Patterns @("Guided Stack-chan pairing", "saved-node add/remove", "square Stack-chan face preview", "Gemma-4-E2B", "Persona import/export", "diagnostics export", "protected robot controls")

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failedChecks.Count -gt 0) {
  "not-ready"
} elseif ($pendingChecks.Count -gt 0) {
  "source-ready-pending-upload-signing"
} else {
  "source-ready"
}
$report = [ordered]@{
  schema = "stackchan.android-play-release-readiness.v1"
  status = $status
  root = [string]$Root
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  pending = $pendingChecks.Count
  failed = $failedChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android Play release readiness: $status"
  Write-Host "Passed: $($report.passed)  Pending: $($report.pending)  Failed: $($report.failed)"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0) {
  exit 1
}
