$ErrorActionPreference = "Stop"

function New-ReleaseAssetEntry {
  param(
    [string]$Name,
    [string]$Path,
    [string]$Phase = "base"
  )

  [pscustomobject]@{
    Name = $Name
    Path = $Path
    Phase = $Phase
  }
}

function Get-ReleaseFirmwareAssetEntries {
  param(
    [string]$PackageRoot,
    [string]$FirmwareAssetRoot = "",
    [ValidateSet("Package", "Stage")]
    [string]$FirmwareAssetPathMode = "Package",
    [string]$Phase = "base"
  )

  if ($FirmwareAssetPathMode -eq "Stage") {
    if ([string]::IsNullOrWhiteSpace($FirmwareAssetRoot)) {
      throw "FirmwareAssetRoot is required when FirmwareAssetPathMode is Stage."
    }
    return @(
      New-ReleaseAssetEntry -Name "firmware-display-only.bin" -Path (Join-Path $FirmwareAssetRoot "firmware-display-only.bin") -Phase $Phase
      New-ReleaseAssetEntry -Name "firmware-servo-calibration.bin" -Path (Join-Path $FirmwareAssetRoot "firmware-servo-calibration.bin") -Phase $Phase
      New-ReleaseAssetEntry -Name "bootloader.bin" -Path (Join-Path $FirmwareAssetRoot "bootloader.bin") -Phase $Phase
      New-ReleaseAssetEntry -Name "partitions.bin" -Path (Join-Path $FirmwareAssetRoot "partitions.bin") -Phase $Phase
    )
  }

  return @(
    New-ReleaseAssetEntry -Name "firmware-display-only.bin" -Path (Join-Path $PackageRoot "firmware/display_only/firmware.bin") -Phase $Phase
    New-ReleaseAssetEntry -Name "firmware-servo-calibration.bin" -Path (Join-Path $PackageRoot "firmware/servo_calibration/firmware.bin") -Phase $Phase
    New-ReleaseAssetEntry -Name "bootloader.bin" -Path (Join-Path $PackageRoot "firmware/display_only/bootloader.bin") -Phase $Phase
    New-ReleaseAssetEntry -Name "partitions.bin" -Path (Join-Path $PackageRoot "firmware/display_only/partitions.bin") -Phase $Phase
  )
}

function Get-ReleaseBaseAssetEntries {
  param(
    [string]$Version,
    [string]$PackageRoot,
    [string]$ZipPath,
    [string]$ZipSidecarPath,
    [string]$FirmwareAssetRoot = "",
    [ValidateSet("Package", "Stage")]
    [string]$FirmwareAssetPathMode = "Package"
  )

  $entries = @(
    New-ReleaseAssetEntry -Name "stackchan_alive_$Version.zip" -Path $ZipPath
    New-ReleaseAssetEntry -Name "stackchan_alive_$Version.zip.sha256" -Path $ZipSidecarPath
    New-ReleaseAssetEntry -Name "stackchan_alive_preview.png" -Path (Join-Path $PackageRoot "media/stackchan_alive_preview.png")
    New-ReleaseAssetEntry -Name "stackchan_alive_expression_sheet.png" -Path (Join-Path $PackageRoot "media/stackchan_alive_expression_sheet.png")
    New-ReleaseAssetEntry -Name "stackchan_alive_preview.mp4" -Path (Join-Path $PackageRoot "media/stackchan_alive_preview.mp4")
    New-ReleaseAssetEntry -Name "stackchan_alive_preview.gif" -Path (Join-Path $PackageRoot "media/stackchan_alive_preview.gif")
    New-ReleaseAssetEntry -Name "stackchan_spark_greeting.wav" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_greeting.wav")
    New-ReleaseAssetEntry -Name "stackchan_spark_thinking.wav" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_thinking.wav")
    New-ReleaseAssetEntry -Name "stackchan_spark_safety.wav" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_safety.wav")
    New-ReleaseAssetEntry -Name "stackchan_spark_audition_warm_slow_greeting.wav" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_warm_slow_greeting.wav")
    New-ReleaseAssetEntry -Name "stackchan_spark_audition_bright_robot_greeting.wav" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.wav")
    New-ReleaseAssetEntry -Name "stackchan_spark_audition_bright_robot_greeting.mp3" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3")
    New-ReleaseAssetEntry -Name "stackchan_spark_thinking.mp3" -Path (Join-Path $PackageRoot "media/voice/stackchan_spark_thinking.mp3")
  )

  return @($entries + (Get-ReleaseFirmwareAssetEntries -PackageRoot $PackageRoot -FirmwareAssetRoot $FirmwareAssetRoot -FirmwareAssetPathMode $FirmwareAssetPathMode))
}

function Get-ReleaseFinalAssetEntries {
  param(
    [string]$Version,
    [string]$PackageRoot,
    [string]$ZipPath,
    [string]$ZipSidecarPath,
    [string]$FirmwareAssetRoot = "",
    [ValidateSet("Package", "Stage")]
    [string]$FirmwareAssetPathMode = "Package"
  )

  return @(
    (Get-ReleaseBaseAssetEntries -Version $Version -PackageRoot $PackageRoot -ZipPath $ZipPath -ZipSidecarPath $ZipSidecarPath -FirmwareAssetRoot $FirmwareAssetRoot -FirmwareAssetPathMode $FirmwareAssetPathMode)
    New-ReleaseAssetEntry -Name "GITHUB_ACTIONS_STATUS.md" -Path (Join-Path $PackageRoot "GITHUB_ACTIONS_STATUS.md") -Phase "final"
    New-ReleaseAssetEntry -Name "github_actions_status.json" -Path (Join-Path $PackageRoot "github_actions_status.json") -Phase "final"
    New-ReleaseAssetEntry -Name "release_assets.json" -Path (Join-Path $PackageRoot "release_assets.json") -Phase "final"
  )
}

function Get-ReleaseAllowedAuditAssetEntries {
  param([string]$AuditRoot)

  return @(
    New-ReleaseAssetEntry -Name "RELEASE_AUDIT.md" -Path (Join-Path $AuditRoot "RELEASE_AUDIT.md") -Phase "audit"
    New-ReleaseAssetEntry -Name "RELEASE_AUDIT.json" -Path (Join-Path $AuditRoot "RELEASE_AUDIT.json") -Phase "audit"
  )
}

function Get-ReleaseCompanionAssetEntries {
  param(
    [string]$Version,
    [string]$CompanionAssetRoot
  )

  if ([string]::IsNullOrWhiteSpace($CompanionAssetRoot)) {
    throw "CompanionAssetRoot is required for companion release assets."
  }

  return @(
    New-ReleaseAssetEntry -Name "stackchan-companion-android-$Version.apk" -Path (Join-Path $CompanionAssetRoot "stackchan-companion-android-$Version.apk") -Phase "final"
    New-ReleaseAssetEntry -Name "stackchan-companion-android-$Version.aab" -Path (Join-Path $CompanionAssetRoot "stackchan-companion-android-$Version.aab") -Phase "final"
    New-ReleaseAssetEntry -Name "stackchan-companion-windows-$Version.msi" -Path (Join-Path $CompanionAssetRoot "stackchan-companion-windows-$Version.msi") -Phase "final"
    New-ReleaseAssetEntry -Name "stackchan-companion-linux-$Version.deb" -Path (Join-Path $CompanionAssetRoot "stackchan-companion-linux-$Version.deb") -Phase "final"
    New-ReleaseAssetEntry -Name "stackchan-companion-macos-$Version.dmg" -Path (Join-Path $CompanionAssetRoot "stackchan-companion-macos-$Version.dmg") -Phase "final"
    New-ReleaseAssetEntry -Name "COMPANION_RELEASE_EVIDENCE.json" -Path (Join-Path $CompanionAssetRoot "COMPANION_RELEASE_EVIDENCE.json") -Phase "final"
    New-ReleaseAssetEntry -Name "COMPANION_RELEASE_EVIDENCE.md" -Path (Join-Path $CompanionAssetRoot "COMPANION_RELEASE_EVIDENCE.md") -Phase "final"
  )
}
