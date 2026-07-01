function Get-StackchanPythonCandidates {
  $candidates = @()
  $candidates += @(Get-Command "python" -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)

  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $pythonRoots = Join-Path $env:LOCALAPPDATA "Programs/Python"
    if (Test-Path -LiteralPath $pythonRoots) {
      $candidates += @(
        Get-ChildItem -LiteralPath $pythonRoots -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending |
          ForEach-Object { Join-Path $_.FullName "python.exe" }
      )
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates += Join-Path $env:USERPROFILE ".platformio/penv/Scripts/python.exe"
    $candidates += Join-Path $env:USERPROFILE ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
  }

  return @(
    $candidates |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
}

function Get-StackchanPreviewPython {
  foreach ($path in Get-StackchanPythonCandidates) {
    if (-not (Test-Path -LiteralPath $path) -or $path -match "\\WindowsApps\\python\.exe$") {
      continue
    }

    try {
      $probe = & $path -c "import PIL, imageio, imageio_ffmpeg; print('preview-media-ok')" 2>$null
      if ($LASTEXITCODE -eq 0 -and (($probe | Out-String) -match "preview-media-ok")) {
        return (Resolve-Path $path).Path
      }
    } catch {
      continue
    }
  }

  $searched = (Get-StackchanPythonCandidates) -join [Environment]::NewLine
  throw "No usable Python runtime with pillow, imageio, and imageio-ffmpeg found. Install preview requirements with a real Python 3 runtime, or run: python -m pip install -r requirements-preview.txt. Searched:$([Environment]::NewLine)$searched"
}
