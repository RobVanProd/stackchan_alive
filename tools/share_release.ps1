param(
  [string]$Version,
  [int]$Port = 8787,
  [string]$BindAddress = "127.0.0.1",
  [switch]$CloudflareTunnel,
  [int]$TunnelWaitSeconds = 30,
  [switch]$NoServe
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Assert-Command {
  param([string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "Required command is not available on PATH: $Name"
  }
}

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

$packageRoot = Join-Path $repoRoot "output/release/$Version"
$zipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"

Assert-File $packageRoot
Assert-File $zipPath

$shareRoot = Join-Path $repoRoot "output/share/$Version"
if (Test-Path -LiteralPath $shareRoot) {
  Remove-Item -LiteralPath $shareRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $shareRoot | Out-Null

$files = @(
  @{ Source = $zipPath; Name = "stackchan_alive_$Version.zip" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.png"); Name = "stackchan_alive_preview.png" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.mp4"); Name = "stackchan_alive_preview.mp4" },
  @{ Source = (Join-Path $packageRoot "media/stackchan_alive_preview.gif"); Name = "stackchan_alive_preview.gif" },
  @{ Source = (Join-Path $packageRoot "RELEASE_NOTES.md"); Name = "RELEASE_NOTES.md" },
  @{ Source = (Join-Path $packageRoot "SHA256SUMS.txt"); Name = "SHA256SUMS.txt" }
)

foreach ($file in $files) {
  Assert-File $file.Source
  Copy-Item -LiteralPath $file.Source -Destination (Join-Path $shareRoot $file.Name)
}

$manifest = Get-Content -LiteralPath (Join-Path $packageRoot "release_manifest.json") -Raw | ConvertFrom-Json
$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

@"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Stackchan Alive $Version</title>
  <style>
    :root { color-scheme: light dark; font-family: Segoe UI, Arial, sans-serif; }
    body { margin: 0; padding: 32px; line-height: 1.45; }
    main { max-width: 960px; margin: 0 auto; }
    img, video { max-width: 100%; border: 1px solid #7775; }
    code { background: #7772; padding: 2px 5px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }
    .item { border: 1px solid #7775; padding: 16px; }
  </style>
</head>
<body>
<main>
  <h1>Stackchan Alive $Version</h1>
  <p>Device-ready prerelease. Hardware validation is still pending.</p>
  <p><strong>Commit:</strong> <code>$($manifest.commit)</code></p>
  <p><strong>Generated UTC:</strong> <code>$generatedUtc</code></p>

  <h2>Preview</h2>
  <p><img src="stackchan_alive_preview.png" alt="Stackchan Alive preview image"></p>
  <p><video src="stackchan_alive_preview.mp4" controls loop muted playsinline></video></p>

  <h2>Downloads</h2>
  <div class="grid">
    <div class="item"><a href="stackchan_alive_$Version.zip">Release ZIP</a></div>
    <div class="item"><a href="stackchan_alive_preview.png">Preview PNG</a></div>
    <div class="item"><a href="stackchan_alive_preview.mp4">Preview MP4</a></div>
    <div class="item"><a href="stackchan_alive_preview.gif">Preview GIF</a></div>
    <div class="item"><a href="RELEASE_NOTES.md">Release Notes</a></div>
    <div class="item"><a href="SHA256SUMS.txt">SHA256 Checksums</a></div>
  </div>

  <h2>Device Arrival Quickstart</h2>
  <p>After downloading and extracting the release ZIP, run this from inside the extracted folder:</p>
  <pre><code>.\tools\prepare_device_arrival.cmd -Port COM3</code></pre>
  <p>This verifies the package, dry-runs the display-only flash command, and creates a hardware evidence packet with runnable <code>RUN_*.cmd</code> files.</p>
  <p>Use display-only firmware first. Servo calibration requires the explicit <code>-ConfirmServoRisk</code> command generated in the evidence packet and a supervised clear work area.</p>
</main>
</body>
</html>
"@ | Set-Content -Path (Join-Path $shareRoot "index.html") -Encoding UTF8

Write-Host "Release share folder:"
Write-Host $shareRoot
Write-Host "Local URL:"
Write-Host "http://$BindAddress`:$Port/"

if ($NoServe) {
  exit 0
}

Assert-Command "python"
if ($CloudflareTunnel) {
  Assert-Command "cloudflared"
}

$serverArgs = @(
  "-m",
  "http.server",
  [string]$Port,
  "--bind",
  $BindAddress,
  "--directory",
  $shareRoot
)
$server = Start-Process -FilePath "python" -ArgumentList $serverArgs -WindowStyle Hidden -PassThru
$server.Id | Set-Content -Path (Join-Path $shareRoot "server.pid") -Encoding ASCII
Write-Host "Started local server PID $($server.Id)"

if ($CloudflareTunnel) {
  $cloudflaredOutLog = Join-Path $shareRoot "cloudflared.stdout.log"
  $cloudflaredErrLog = Join-Path $shareRoot "cloudflared.stderr.log"
  Remove-Item -LiteralPath $cloudflaredOutLog, $cloudflaredErrLog -Force -ErrorAction SilentlyContinue

  $tunnelArgs = @("tunnel", "--url", "http://$BindAddress`:$Port")
  $tunnel = Start-Process -FilePath "cloudflared" -ArgumentList $tunnelArgs -WindowStyle Hidden -RedirectStandardOutput $cloudflaredOutLog -RedirectStandardError $cloudflaredErrLog -PassThru
  $tunnel.Id | Set-Content -Path (Join-Path $shareRoot "cloudflared.pid") -Encoding ASCII
  Write-Host "Started cloudflared PID $($tunnel.Id)"
  Write-Host "Waiting up to $TunnelWaitSeconds seconds for the public tunnel URL..."

  $publicUrl = $null
  $deadline = (Get-Date).AddSeconds($TunnelWaitSeconds)
  while ((Get-Date) -lt $deadline -and [string]::IsNullOrWhiteSpace($publicUrl)) {
    foreach ($logPath in @($cloudflaredOutLog, $cloudflaredErrLog)) {
      if (-not (Test-Path -LiteralPath $logPath)) {
        continue
      }

      $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
      if ($logText -match "https://[-A-Za-z0-9]+\.trycloudflare\.com") {
        $publicUrl = $Matches[0]
        break
      }
    }

    if ([string]::IsNullOrWhiteSpace($publicUrl)) {
      Start-Sleep -Milliseconds 500
    }
  }

  if ([string]::IsNullOrWhiteSpace($publicUrl)) {
    Write-Warning "Cloudflare tunnel started, but no public URL was found yet."
    Write-Host "Cloudflared stdout log: $cloudflaredOutLog"
    Write-Host "Cloudflared stderr log: $cloudflaredErrLog"
  } else {
    Write-Host "Public tunnel URL:"
    Write-Host $publicUrl
  }
}

Write-Host "Stop sharing command:"
if ($CloudflareTunnel) {
  Write-Host "Stop-Process -Id $($server.Id),$($tunnel.Id)"
} else {
  Write-Host "Stop-Process -Id $($server.Id)"
}
