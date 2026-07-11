param(
  [string]$InstallDir = "output\local-tools\whisper.cpp",
  [ValidateSet("tiny.en", "base.en", "small.en", "medium.en")]
  [string]$Model = "base.en",
  [switch]$PreferBlas,
  [switch]$Force,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$InstallPath = New-Item -ItemType Directory -Force -Path $InstallDir
$DownloadDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath.FullName "downloads")
$ModelsDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath.FullName "models")

function Find-WhisperCli {
  param([string]$Root)
  $found = Get-ChildItem -LiteralPath $Root -Filter "whisper-cli.exe" -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    Select-Object -First 1
  if ($found) {
    return $found.FullName
  }
  return ""
}

function Invoke-Download {
  param(
    [string]$Uri,
    [string]$OutFile
  )
  if ((Test-Path -LiteralPath $OutFile -PathType Leaf) -and -not $Force) {
    return
  }
  Invoke-WebRequest -Uri $Uri -OutFile $OutFile
}

$WhisperExe = Find-WhisperCli -Root $InstallPath.FullName
if (-not $WhisperExe -or $Force) {
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest"
  $assetPattern = if ($PreferBlas) { "whisper-blas-bin-x64.zip" } else { "whisper-bin-x64.zip" }
  $asset = @($release.assets | Where-Object { $_.name -eq $assetPattern } | Select-Object -First 1)
  if (-not $asset) {
    throw "Could not find $assetPattern in latest whisper.cpp release $($release.tag_name)."
  }
  $zipPath = Join-Path $DownloadDir.FullName $asset.name
  Invoke-Download -Uri $asset.browser_download_url -OutFile $zipPath
  Expand-Archive -LiteralPath $zipPath -DestinationPath $InstallPath.FullName -Force
  $WhisperExe = Find-WhisperCli -Root $InstallPath.FullName
  if (-not $WhisperExe) {
    throw "Downloaded whisper.cpp, but whisper-cli.exe was not found under $($InstallPath.FullName)."
  }
}

$ModelFileName = "ggml-$Model.bin"
$ModelPath = Join-Path $ModelsDir.FullName $ModelFileName
if ((-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) -or $Force) {
  $modelUri = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$ModelFileName"
  Invoke-Download -Uri $modelUri -OutFile $ModelPath
}

$EnvScript = Join-Path $InstallPath.FullName "stackchan-whisper-env.ps1"
@(
  "`$env:STACKCHAN_WHISPER_CPP_EXE = '$($WhisperExe.Replace("'", "''"))'",
  "`$env:STACKCHAN_WHISPER_MODEL = '$($ModelPath.Replace("'", "''"))'",
  "`$env:STACKCHAN_STT_COMMAND = 'python bridge\whisper_cpp_stt.py'"
) | Set-Content -LiteralPath $EnvScript -Encoding UTF8

$result = [ordered]@{
  schema = "stackchan.whisper-cpp-setup.v1"
  status = "whisper-cpp-ready"
  installDir = (Resolve-Path $InstallPath.FullName).Path
  whisperExe = $WhisperExe
  model = $Model
  modelPath = (Resolve-Path $ModelPath).Path
  envScript = $EnvScript
  sttCommand = "python bridge\whisper_cpp_stt.py"
}

if ($Json) {
  $result | ConvertTo-Json -Depth 5
} else {
  Write-Host "whisper.cpp ready."
  Write-Host "Executable: $WhisperExe"
  Write-Host "Model: $ModelPath"
  Write-Host "Environment script: $EnvScript"
  Write-Host "STT command: python bridge\whisper_cpp_stt.py"
}
