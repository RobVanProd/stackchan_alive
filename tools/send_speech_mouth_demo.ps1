param(
  [string]$Port = "COM3",
  [int]$Baud = 115200,
  [string]$SidecarPath = "",
  [int]$InterCommandDelayMs = 0,
  [int]$FrameStride = 1,
  [int]$MaxFrames = 0,
  [switch]$PrintOnly,
  [switch]$NoModeCommand
)

$ErrorActionPreference = "Stop"

function Assert-Range {
  param(
    [string]$Name,
    [int]$Value,
    [int]$Min,
    [int]$Max
  )

  if ($Value -lt $Min -or $Value -gt $Max) {
    throw "$Name must be between $Min and $Max. Received $Value."
  }
}

function Send-SerialLine {
  param(
    [System.IO.Ports.SerialPort]$Serial,
    [string]$Line
  )

  Write-Host "[demo] > $Line"
  $Serial.WriteLine($Line)
}

function Format-Envelope {
  param([double]$Envelope)
  return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.000}", [Math]::Max(0.0, [Math]::Min(1.0, $Envelope)))
}

function Get-BuiltInSequence {
  return @(
    @{ Envelope = "0.12"; Shape = "neutral"; DurationMs = 120; DelayMs = 120 },
    @{ Envelope = "0.58"; Shape = "ah"; DurationMs = 150; DelayMs = 150 },
    @{ Envelope = "0.36"; Shape = "ee"; DurationMs = 120; DelayMs = 120 },
    @{ Envelope = "0.74"; Shape = "oh"; DurationMs = 160; DelayMs = 160 },
    @{ Envelope = "0.24"; Shape = "neutral"; DurationMs = 110; DelayMs = 110 },
    @{ Envelope = "0.66"; Shape = "ee"; DurationMs = 150; DelayMs = 150 },
    @{ Envelope = "0.42"; Shape = "ah"; DurationMs = 120; DelayMs = 120 },
    @{ Envelope = "0.80"; Shape = "oh"; DurationMs = 170; DelayMs = 170 },
    @{ Envelope = "0.30"; Shape = "ee"; DurationMs = 120; DelayMs = 120 },
    @{ Envelope = "0.62"; Shape = "ah"; DurationMs = 150; DelayMs = 150 },
    @{ Envelope = "0.18"; Shape = "neutral"; DurationMs = 120; DelayMs = 120 }
  )
}

function Get-SidecarSequence {
  param(
    [string]$Path,
    [int]$Stride,
    [int]$Limit
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing speech envelope sidecar: $Path"
  }

  $sidecar = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ([string]$sidecar.schema -ne "stackchan.speech-envelope-sidecar.v1") {
    throw "Unsupported sidecar schema: $($sidecar.schema)"
  }

  $frameMs = [int]$sidecar.frameMs
  Assert-Range -Name "sidecar frameMs" -Value $frameMs -Min 10 -Max 100
  $durationMs = [Math]::Max(50, [Math]::Min(2000, ($frameMs * $Stride) + 80))
  $sequence = New-Object System.Collections.Generic.List[object]
  $index = 0

  foreach ($frame in @($sidecar.frames)) {
    if (($index % $Stride) -ne 0) {
      $index++
      continue
    }
    if ($Limit -gt 0 -and $sequence.Count -ge $Limit) {
      break
    }

    $viseme = [string]$frame.viseme
    if (@("ah", "oh", "ee", "neutral") -notcontains $viseme) {
      $viseme = "neutral"
    }
    $sequence.Add(@{
      Envelope = Format-Envelope ([double]$frame.envelope)
      Shape = $viseme
      DurationMs = $durationMs
      DelayMs = $frameMs * $Stride
    }) | Out-Null
    $index++
  }

  if ($sequence.Count -eq 0) {
    throw "Speech envelope sidecar has no streamable frames: $Path"
  }

  Write-Host "[demo] Loaded sidecar $Path with $($sequence.Count) streamed frames."
  return $sequence.ToArray()
}

Assert-Range -Name "Baud" -Value $Baud -Min 1200 -Max 921600
Assert-Range -Name "InterCommandDelayMs" -Value $InterCommandDelayMs -Min 0 -Max 1000
Assert-Range -Name "FrameStride" -Value $FrameStride -Min 1 -Max 10
Assert-Range -Name "MaxFrames" -Value $MaxFrames -Min 0 -Max 10000

$sequence = if ([string]::IsNullOrWhiteSpace($SidecarPath)) {
  Get-BuiltInSequence
} else {
  Get-SidecarSequence -Path $SidecarPath -Stride $FrameStride -Limit $MaxFrames
}
if ($MaxFrames -gt 0 -and @($sequence).Count -gt $MaxFrames) {
  $sequence = @($sequence | Select-Object -First $MaxFrames)
}

if ($PrintOnly) {
  if (-not $NoModeCommand) {
    Write-Host "[demo] > mode speak 1.0"
  }
  foreach ($step in $sequence) {
    Write-Host "[demo] > speech $($step.Envelope) $($step.Shape) $($step.DurationMs)"
  }
  Write-Host "[demo] > speech clear"
  Write-Host "[demo] PrintOnly complete; no serial port was opened."
  exit 0
}

$serial = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$serial.NewLine = "`n"
$serial.ReadTimeout = 500
$serial.WriteTimeout = 1000
$serial.DtrEnable = $true
$serial.RtsEnable = $true

try {
  Write-Host "[demo] Opening $Port at $Baud baud."
  $serial.Open()
  Start-Sleep -Milliseconds 250

  if (-not $NoModeCommand) {
    Send-SerialLine -Serial $serial -Line "mode speak 1.0"
    Start-Sleep -Milliseconds 250
  }

  foreach ($step in $sequence) {
    $line = "speech $($step.Envelope) $($step.Shape) $($step.DurationMs)"
    Send-SerialLine -Serial $serial -Line $line
    $delayMs = if ($InterCommandDelayMs -gt 0) { $InterCommandDelayMs } else { [int]$step.DelayMs }
    Start-Sleep -Milliseconds ([Math]::Max(1, $delayMs))
  }

  Send-SerialLine -Serial $serial -Line "speech clear"
  Start-Sleep -Milliseconds 120
  Write-Host "[demo] Speech mouth demo complete."
} finally {
  if ($serial.IsOpen) {
    $serial.Close()
  }
  $serial.Dispose()
}
