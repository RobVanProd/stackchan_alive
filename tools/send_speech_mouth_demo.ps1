param(
  [string]$Port = "COM3",
  [int]$Baud = 115200,
  [int]$InterCommandDelayMs = 90,
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

Assert-Range -Name "Baud" -Value $Baud -Min 1200 -Max 921600
Assert-Range -Name "InterCommandDelayMs" -Value $InterCommandDelayMs -Min 10 -Max 1000

$sequence = @(
  @{ Envelope = "0.12"; Shape = "neutral"; DurationMs = 120 },
  @{ Envelope = "0.58"; Shape = "ah"; DurationMs = 150 },
  @{ Envelope = "0.36"; Shape = "ee"; DurationMs = 120 },
  @{ Envelope = "0.74"; Shape = "oh"; DurationMs = 160 },
  @{ Envelope = "0.24"; Shape = "neutral"; DurationMs = 110 },
  @{ Envelope = "0.66"; Shape = "ee"; DurationMs = 150 },
  @{ Envelope = "0.42"; Shape = "ah"; DurationMs = 120 },
  @{ Envelope = "0.80"; Shape = "oh"; DurationMs = 170 },
  @{ Envelope = "0.30"; Shape = "ee"; DurationMs = 120 },
  @{ Envelope = "0.62"; Shape = "ah"; DurationMs = 150 },
  @{ Envelope = "0.18"; Shape = "neutral"; DurationMs = 120 }
)

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
    Start-Sleep -Milliseconds ([Math]::Max($InterCommandDelayMs, [int]$step.DurationMs))
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
