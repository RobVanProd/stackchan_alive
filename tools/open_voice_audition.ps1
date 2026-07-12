param(
  [switch]$All,
  [switch]$Rvc,
  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ($All -and $Rvc) {
  throw "Use either -All or -Rvc, not both."
}

function Resolve-FirstExisting {
  param([string[]]$Paths)

  foreach ($path in $Paths) {
    if (Test-Path -LiteralPath $path) {
      return (Resolve-Path $path).Path
    }
  }
  return ""
}

function ConvertTo-FileUri {
  param([string]$Path)

  return ([System.Uri]::new((Resolve-Path $Path).Path)).AbsoluteUri
}

function Write-CombinedAuditionPage {
  param([string]$RootPath)

  $indexDir = Join-Path $RootPath "output/voice_auditions"
  New-Item -ItemType Directory -Force -Path $indexDir | Out-Null
  $indexPath = Join-Path $indexDir "VOICE_AUDITION_INDEX.html"

  $sparkPage = Resolve-FirstExisting @(
    (Join-Path $RootPath "docs/media/voice/VOICE_AUDITION.html"),
    (Join-Path $RootPath "media/voice/VOICE_AUDITION.html")
  )
  $rvcPage = Resolve-FirstExisting @(
    (Join-Path $RootPath "output/voice_auditions/rvc_base/final/RVC_AUDITION.html")
  )

  $samples = @(
    [pscustomobject]@{
      Group = "Stackchan Spark"
      Title = "Bright Robot Greeting"
      Path = Resolve-FirstExisting @(
        (Join-Path $RootPath "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.mp3"),
        (Join-Path $RootPath "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3")
      )
    },
    [pscustomobject]@{
      Group = "Stackchan Spark"
      Title = "Thinking"
      Path = Resolve-FirstExisting @(
        (Join-Path $RootPath "docs/media/voice/stackchan_spark_thinking.mp3"),
        (Join-Path $RootPath "media/voice/stackchan_spark_thinking.mp3")
      )
    },
    [pscustomobject]@{
      Group = "RVC Review"
      Title = "Bright Robot"
      Path = Resolve-FirstExisting @(
        (Join-Path $RootPath "output/voice_auditions/rvc_base/final/stackchan_rvc_bright_robot.mp3")
      )
    },
    [pscustomobject]@{
      Group = "RVC Review"
      Title = "Thinking"
      Path = Resolve-FirstExisting @(
        (Join-Path $RootPath "output/voice_auditions/rvc_base/final/stackchan_rvc_thinking_neutral.mp3")
      )
    },
    [pscustomobject]@{
      Group = "RVC Review"
      Title = "Safety"
      Path = Resolve-FirstExisting @(
        (Join-Path $RootPath "output/voice_auditions/rvc_base/final/stackchan_rvc_safety_neutral.mp3")
      )
    }
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) }

  if (@($samples).Count -eq 0) {
    throw "Missing local MP3 audition samples. Render Stackchan Spark samples and, for RVC, supply an authorized local model and generate output under output/voice_auditions/."
  }

  $pageLinks = @()
  if (-not [string]::IsNullOrWhiteSpace($sparkPage)) {
    $pageLinks += "<a href=""$(ConvertTo-FileUri $sparkPage)"">Stackchan Spark page</a>"
  }
  if (-not [string]::IsNullOrWhiteSpace($rvcPage)) {
    $pageLinks += "<a href=""$(ConvertTo-FileUri $rvcPage)"">RVC page</a>"
  }

  $sampleHtml = foreach ($sample in $samples) {
    $group = [System.Net.WebUtility]::HtmlEncode($sample.Group)
    $title = [System.Net.WebUtility]::HtmlEncode($sample.Title)
    $uri = ConvertTo-FileUri $sample.Path
    @"
    <section class="sample">
      <div class="meta">$group</div>
      <h2>$title</h2>
      <audio src="$uri" controls preload="metadata"></audio>
      <p><a href="$uri">Open MP3</a></p>
    </section>
"@
  }

  $linkHtml = if ($pageLinks.Count -gt 0) { $pageLinks -join " " } else { "" }
  @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Stackchan Voice Audition Index</title>
  <style>
    :root { color-scheme: dark; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #071113; color: #e8f4f2; }
    body { margin: 0; padding: 24px; }
    main { max-width: 860px; margin: 0 auto; }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    h2 { margin: 4px 0 10px; font-size: 18px; letter-spacing: 0; }
    p { line-height: 1.5; color: #b7c8c5; }
    a { color: #68e4d4; margin-right: 16px; }
    audio { width: 100%; }
    .sample { border: 1px solid #24413f; border-radius: 8px; padding: 16px; margin: 16px 0; background: #0d1b1e; }
    .meta { color: #7baaa5; font-size: 13px; text-transform: uppercase; letter-spacing: 0.08em; }
    .note { border-left: 3px solid #68e4d4; padding-left: 12px; }
  </style>
</head>
<body>
  <main>
    <h1>Stackchan Voice Audition Index</h1>
    <p class="note">Local review page for available Stackchan Spark and RVC MP3 audition samples. RVC files remain review-only until source provenance and rights review are complete.</p>
    <p>$linkHtml</p>
$($sampleHtml -join "`n")
  </main>
</body>
</html>
"@ | Set-Content -Path $indexPath -Encoding UTF8

  return (Resolve-Path $indexPath).Path
}

if ($All) {
  $auditionPath = Write-CombinedAuditionPage -RootPath $root
  Write-Host "Stackchan combined voice audition page:"
  Write-Host $auditionPath
  if (-not $PrintOnly) {
    Start-Process $auditionPath
  }
  exit 0
}

$pageName = if ($Rvc) { "RVC_AUDITION.html" } else { "VOICE_AUDITION.html" }
$candidates = if ($Rvc) {
  @(
    (Join-Path $root "output/voice_auditions/rvc_base/final/$pageName")
  )
} else {
  @(
    (Join-Path $root "docs/media/voice/$pageName"),
    (Join-Path $root "media/voice/$pageName")
  )
}

$auditionPath = ""
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $auditionPath = (Resolve-Path $candidate).Path
    break
  }
}

if ([string]::IsNullOrWhiteSpace($auditionPath)) {
  if ($Rvc) {
    throw "Missing local Stackchan RVC audition page. Supply an authorized model and run tools/render_rvc_audition_mp3s.cmd; release packages intentionally do not include RVC output."
  }
  throw "Missing Stackchan voice audition page. Run tools/render_voice_samples.cmd in the repo, or use a verified release package that includes media/voice/VOICE_AUDITION.html."
}

if ($Rvc) {
  Write-Host "Stackchan RVC voice audition page:"
} else {
  Write-Host "Stackchan voice audition page:"
}
Write-Host $auditionPath

if (-not $PrintOnly) {
  Start-Process $auditionPath
}
