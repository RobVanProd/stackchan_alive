param(
  [string]$Version,
  [int]$Port = 8787,
  [string]$BindAddress = "127.0.0.1",
  [switch]$CloudflareTunnel,
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
Write-Host "Started local server PID $($server.Id)"

if ($CloudflareTunnel) {
  Assert-Command "cloudflared"
  $tunnelArgs = @("tunnel", "--url", "http://$BindAddress`:$Port")
  $tunnel = Start-Process -FilePath "cloudflared" -ArgumentList $tunnelArgs -WindowStyle Hidden -PassThru
  Write-Host "Started cloudflared PID $($tunnel.Id)"
  Write-Host "Run cloudflared logs in a visible terminal if you need to copy the public tunnel URL."
}
