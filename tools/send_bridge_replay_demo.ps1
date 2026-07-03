param(
  [string]$Port = "COM3",
  [int]$Baud = 115200,
  [string]$TranscriptPath = "",
  [int]$InterCommandDelayMs = 220,
  [int]$ReadBackMs = 450,
  [switch]$PrintOnly,
  [switch]$NoDemoOff
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

  Write-Host "[bridge-replay] > $Line"
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
          Write-Host "[bridge-replay] < $($line.Trim())"
        }
      }
    }
  } while ([DateTime]::UtcNow -lt $deadline)
}

function Get-BuiltInTranscript {
  return @(
    "bridge hello bench",
    "bridge listening",
    "bridge thinking 7",
    "bridge response happy 7 hello i am stackchan and i am awake",
    "bridge audio 0.18 neutral 60",
    "bridge audio 0.55 ah 80",
    "bridge audio 0.72 ee 80",
    "bridge audio 0.44 oh 80",
    "bridge audio 0.12 neutral 60 final",
    "bridge end 7",
    "status"
  )
}

function Get-TranscriptFromFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing bridge transcript file: $Path"
  }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($rawLine in Get-Content -LiteralPath $Path) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
      continue
    }
    if ($line -notmatch "^(bridge|status|telemetry|health|demo)\b") {
      throw "Unsupported bridge transcript command: $line"
    }
    $lines.Add($line) | Out-Null
  }

  if ($lines.Count -eq 0) {
    throw "Bridge transcript has no commands: $Path"
  }

  Write-Host "[bridge-replay] Loaded transcript $Path with $($lines.Count) commands."
  return $lines.ToArray()
}

Assert-Range -Name "Baud" -Value $Baud -Min 1200 -Max 921600
Assert-Range -Name "InterCommandDelayMs" -Value $InterCommandDelayMs -Min 25 -Max 10000
Assert-Range -Name "ReadBackMs" -Value $ReadBackMs -Min 0 -Max 5000

$commands = if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
  Get-BuiltInTranscript
} else {
  Get-TranscriptFromFile -Path $TranscriptPath
}

if ($PrintOnly) {
  if (-not $NoDemoOff) {
    Write-Host "[bridge-replay] > demo off"
  }
  foreach ($command in $commands) {
    Write-Host "[bridge-replay] > $command"
  }
  Write-Host "[bridge-replay] PrintOnly complete; no serial port was opened."
  exit 0
}

$serial = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$serial.NewLine = "`n"
$serial.ReadTimeout = 500
$serial.WriteTimeout = 1000
$serial.DtrEnable = $true
$serial.RtsEnable = $true

try {
  Write-Host "[bridge-replay] Opening $Port at $Baud baud."
  $serial.Open()
  Start-Sleep -Milliseconds 250

  if (-not $NoDemoOff) {
    Send-SerialLine -Serial $serial -Line "demo off"
    Start-Sleep -Milliseconds 200
    Read-SerialAvailable -Serial $serial -DrainMs $ReadBackMs
  }

  foreach ($command in $commands) {
    Send-SerialLine -Serial $serial -Line $command
    Start-Sleep -Milliseconds $InterCommandDelayMs
    Read-SerialAvailable -Serial $serial -DrainMs $ReadBackMs
  }

  Write-Host "[bridge-replay] Bridge replay demo complete."
} finally {
  if ($serial.IsOpen) {
    $serial.Close()
  }
  $serial.Dispose()
}
