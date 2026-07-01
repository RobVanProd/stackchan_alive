param(
  [switch]$InstallEspeak,
  [switch]$InstallSox,
  [switch]$RenderEspeakSamples,
  [switch]$ContinueOnInstallFailure,
  [string]$OutputDir = "docs/media/voice"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Get-StackchanCommandInfo {
  param([string[]]$Names)

  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
      return [pscustomobject]@{
        found = $true
        name = $command.Name
        source = $command.Source
      }
    }
  }

  return [pscustomobject]@{
    found = $false
    name = ""
    source = ""
  }
}

function Invoke-WingetInstall {
  param(
    [string]$PackageId,
    [string]$DisplayName
  )

  $winget = Get-Command "winget" -ErrorAction SilentlyContinue
  if ($null -eq $winget) {
    throw "winget is not available. Install $DisplayName manually, then re-run this script."
  }

  Write-Host "Installing $DisplayName with winget package $PackageId"
  & $winget.Source install --id $PackageId --exact --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    throw "winget install failed for $DisplayName ($PackageId)."
  }
}

$beforeEspeak = Get-StackchanCommandInfo @("espeak-ng", "espeak")
$beforeSox = Get-StackchanCommandInfo @("sox")
$installFailures = @()

if ($InstallEspeak -and -not $beforeEspeak.found) {
  try {
    Invoke-WingetInstall -PackageId "eSpeak-NG.eSpeak-NG" -DisplayName "eSpeak-NG"
  } catch {
    $installFailures += [pscustomobject]@{
      tool = "eSpeak-NG"
      packageId = "eSpeak-NG.eSpeak-NG"
      error = $_.Exception.Message
      note = "The Windows MSI can fail if another installer is active or if Visual C++ runtime repair is required. Close stale msiexec processes or reboot, then retry."
    }
    if (-not $ContinueOnInstallFailure) {
      throw
    }
  }
}

if ($InstallSox -and -not $beforeSox.found) {
  try {
    Invoke-WingetInstall -PackageId "ChrisBagwell.SoX" -DisplayName "SoX"
  } catch {
    $installFailures += [pscustomobject]@{
      tool = "SoX"
      packageId = "ChrisBagwell.SoX"
      error = $_.Exception.Message
      note = "SoX is optional; Stackchan Spark Synth v4 does not require it."
    }
    if (-not $ContinueOnInstallFailure) {
      throw
    }
  }
}

$afterEspeak = Get-StackchanCommandInfo @("espeak-ng", "espeak")
$afterSox = Get-StackchanCommandInfo @("sox")

$status = [ordered]@{
  schema = "stackchan.voice-tools-status.v1"
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  espeak = $afterEspeak
  sox = $afterSox
  recommendedSource = if ($afterEspeak.found) { "render_voice_samples.ps1 -Engine espeak" } else { "install eSpeak-NG, then render_voice_samples.ps1 -Engine espeak" }
  optionalPostProcessing = if ($afterSox.found) { "SoX available for external audition experiments" } else { "SoX not required; Stackchan Spark Synth v4 DSP is built into render_voice_samples.ps1" }
  installFailures = @($installFailures)
}

if ($RenderEspeakSamples) {
  if (-not $afterEspeak.found) {
    throw "Cannot render eSpeak samples because eSpeak-NG/eSpeak is not available. Re-run with -InstallEspeak or install it manually."
  }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "render_voice_samples.ps1") -Engine espeak -OutputDir $OutputDir
  if ($LASTEXITCODE -ne 0) {
    throw "eSpeak voice sample rendering failed."
  }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_voice_samples.ps1") -VoiceRoot $OutputDir
  if ($LASTEXITCODE -ne 0) {
    throw "eSpeak voice sample verification failed."
  }

  $status.renderedEspeakSamples = $true
  $status.outputDir = $OutputDir
} else {
  $status.renderedEspeakSamples = $false
}

$status | ConvertTo-Json -Depth 5

if ($afterEspeak.found) {
  Write-Host "eSpeak/formant source ready:"
  Write-Host "$($afterEspeak.name) $($afterEspeak.source)"
} else {
  Write-Host "eSpeak/formant source not installed. To install with winget:"
  Write-Host ".\tools\setup_voice_tools.cmd -InstallEspeak"
}

if ($afterSox.found) {
  Write-Host "SoX available:"
  Write-Host "$($afterSox.name) $($afterSox.source)"
}
