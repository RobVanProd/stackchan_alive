param(
  [string]$Port = "COM3",
  [int]$Baud = 115200,
  [int]$InterIntentDelayMs = 850,
  [int]$ReadBackMs = 450,
  [switch]$PrintOnly,
  [switch]$NoDemoOff
)

$ErrorActionPreference = "Stop"

$intentNames = @(
  "boot",
  "idle",
  "attend",
  "listen",
  "think",
  "speak",
  "react",
  "happy",
  "concern",
  "sleep",
  "error",
  "safety"
)

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

  Write-Host "[speak-all] > $Line"
  $Serial.WriteLine($Line)
}

function Read-SerialAvailable {
  param(
    [System.IO.Ports.SerialPort]$Serial,
    [int]$DrainMs
  )

  if ($DrainMs -le 0 -or -not $Serial.IsOpen) {
    return
  }

  $deadline = [DateTime]::UtcNow.AddMilliseconds($DrainMs)
  do {
    Start-Sleep -Milliseconds 10
    try {
      $text = $Serial.ReadExisting()
    } catch {
      return
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      foreach ($line in ($text -split "\r?\n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
          Write-Host "[speak-all] < $($line.Trim())"
        }
      }
    }
  } while ([DateTime]::UtcNow -lt $deadline)
}

Assert-Range -Name "Baud" -Value $Baud -Min 1200 -Max 921600
Assert-Range -Name "InterIntentDelayMs" -Value $InterIntentDelayMs -Min 100 -Max 10000
Assert-Range -Name "ReadBackMs" -Value $ReadBackMs -Min 0 -Max 5000

if ($PrintOnly) {
  if (-not $NoDemoOff) {
    Write-Host "[speak-all] > demo off"
  }
  foreach ($intent in $intentNames) {
    Write-Host "[speak-all] > speak $intent"
  }
  Write-Host "[speak-all] PrintOnly complete; no serial port was opened."
  exit 0
}

$serial = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$serial.NewLine = "`n"
$serial.ReadTimeout = 500
$serial.WriteTimeout = 1000
$serial.DtrEnable = $true
$serial.RtsEnable = $true

try {
  Write-Host "[speak-all] Opening $Port at $Baud baud."
  $serial.Open()
  Start-Sleep -Milliseconds 250

  if (-not $NoDemoOff) {
    Send-SerialLine -Serial $serial -Line "demo off"
    Start-Sleep -Milliseconds 200
    Read-SerialAvailable -Serial $serial -DrainMs $ReadBackMs
  }

  foreach ($intent in $intentNames) {
    Send-SerialLine -Serial $serial -Line "speak $intent"
    Start-Sleep -Milliseconds $InterIntentDelayMs
    Read-SerialAvailable -Serial $serial -DrainMs $ReadBackMs
  }

  Write-Host "[speak-all] Speak-all-intents demo complete."
} finally {
  if ($serial.IsOpen) {
    $serial.Close()
  }
  $serial.Dispose()
}
