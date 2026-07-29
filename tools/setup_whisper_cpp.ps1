param(
  [string]$InstallDir = "output\local-tools\whisper.cpp",
  [ValidateSet("tiny.en", "base.en", "small.en", "medium.en")]
  [string]$Model = "base.en",
  [ValidateSet("prebuilt", "vulkan")]
  [string]$Backend = "prebuilt",
  [switch]$PreferBlas,
  [string]$VulkanSdkPath = "",
  [string]$VulkanBuildRoot = "",
  [int]$BuildParallelism = 8,
  [switch]$Force,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ($BuildParallelism -lt 1 -or $BuildParallelism -gt 32) {
  throw "BuildParallelism must be between 1 and 32."
}
if ($Backend -eq "vulkan" -and -not $PSBoundParameters.ContainsKey("InstallDir")) {
  $InstallDir = "output\local-tools\whisper.cpp-vulkan"
}

$InstallPath = New-Item -ItemType Directory -Force -Path $InstallDir
$DownloadDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath.FullName "downloads")
$ModelsDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath.FullName "models")
$PinnedWhisperTag = "v1.9.1"
$PinnedWhisperCommit = "f049fff95a089aa9969deb009cdd4892b3e74916"
$WhisperRepository = "https://github.com/ggml-org/whisper.cpp.git"
$KnownModelSha256 = @{
  "small.en" = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
}

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

function Find-WhisperServer {
  param([string]$Root)
  $found = Get-ChildItem -LiteralPath $Root -Filter "whisper-server.exe" -Recurse -ErrorAction SilentlyContinue |
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
  $partialPath = "$OutFile.partial"
  Invoke-WebRequest -Uri $Uri -OutFile $partialPath
  Move-Item -LiteralPath $partialPath -Destination $OutFile -Force
}

function Invoke-CheckedNative {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$Description
  )
  if ($Json) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $Output = @(& $FilePath @Arguments 2>&1)
      $ExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
      $Detail = ($Output | Select-Object -Last 12) -join " "
      throw "$Description failed with exit code $ExitCode. $Detail"
    }
  } else {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "$Description failed with exit code $LASTEXITCODE."
    }
  }
}

function Copy-VerifiedTool {
  param(
    [string]$Source,
    [string]$Destination
  )
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $DestinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($SourceHash -eq $DestinationHash) {
      return
    }
  }
  try {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
  } catch {
    throw "Could not install $(Split-Path -Leaf $Destination). Stop any running process using it and retry."
  }
}

$WhisperExe = ""
$WhisperServerExe = ""
$SourceCommit = $null
$VulkanSdkVersion = $null
$BuildRootPath = $null

if ($Backend -eq "vulkan") {
  if ([string]::IsNullOrWhiteSpace($VulkanSdkPath)) {
    $VulkanSdkPath = @(
      $env:VULKAN_SDK,
      [Environment]::GetEnvironmentVariable("VULKAN_SDK", "User"),
      [Environment]::GetEnvironmentVariable("VULKAN_SDK", "Machine")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
      Select-Object -First 1
  }
  if (-not $VulkanSdkPath -or -not (Test-Path -LiteralPath $VulkanSdkPath -PathType Container)) {
    throw "Vulkan SDK not found. Install it and set VULKAN_SDK, or pass -VulkanSdkPath."
  }
  $VulkanSdkPath = (Resolve-Path $VulkanSdkPath).Path
  $GlslcPath = Join-Path $VulkanSdkPath "Bin\glslc.exe"
  if (-not (Test-Path -LiteralPath $GlslcPath -PathType Leaf)) {
    throw "Vulkan SDK is missing Bin\glslc.exe: $VulkanSdkPath"
  }
  $ComponentsPath = Join-Path $VulkanSdkPath "components.xml"
  if (Test-Path -LiteralPath $ComponentsPath -PathType Leaf) {
    [xml]$Components = Get-Content -LiteralPath $ComponentsPath -Raw
    $VulkanSdkVersion = [string]$Components.Packages.ApplicationName -replace "^Vulkan SDK\s+", ""
  }

  $Git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  $Cmake = Get-Command cmake -ErrorAction SilentlyContinue | Select-Object -First 1
  $Ninja = Get-Command ninja -ErrorAction SilentlyContinue | Select-Object -First 1
  $CCompiler = Get-Command gcc -ErrorAction SilentlyContinue | Select-Object -First 1
  $CxxCompiler = Get-Command "g++" -ErrorAction SilentlyContinue | Select-Object -First 1
  foreach ($Tool in @(
    @{ Name = "git"; Command = $Git },
    @{ Name = "cmake"; Command = $Cmake },
    @{ Name = "ninja"; Command = $Ninja },
    @{ Name = "gcc"; Command = $CCompiler },
    @{ Name = "g++"; Command = $CxxCompiler }
  )) {
    if (-not $Tool.Command) {
      throw "$($Tool.Name) is required to build whisper.cpp with Vulkan."
    }
  }

  if ([string]::IsNullOrWhiteSpace($VulkanBuildRoot)) {
    $InstallDrive = [IO.Path]::GetPathRoot($InstallPath.FullName)
    $VulkanBuildRoot = Join-Path $InstallDrive "stackchan-tools\whisper-vulkan"
  }
  $BuildRootPath = (New-Item -ItemType Directory -Force -Path $VulkanBuildRoot).FullName
  $SourcePath = Join-Path $BuildRootPath "src"
  $BuildPath = Join-Path $BuildRootPath "build"

  if (-not (Test-Path -LiteralPath (Join-Path $SourcePath ".git") -PathType Container)) {
    if (Test-Path -LiteralPath $SourcePath) {
      throw "Vulkan source path exists but is not a Git checkout: $SourcePath"
    }
    Invoke-CheckedNative -FilePath $Git.Source `
      -Arguments @("clone", "--filter=blob:none", $WhisperRepository, $SourcePath) `
      -Description "whisper.cpp clone"
  }
  $Origin = (& $Git.Source -C $SourcePath remote get-url origin).Trim()
  if ($LASTEXITCODE -ne 0 -or
      $Origin -notmatch "(?i)(github\.com[:/])ggml-org/whisper\.cpp(?:\.git)?$") {
    throw "Vulkan source origin is not the official ggml-org/whisper.cpp repository."
  }
  $DirtySource = @(& $Git.Source -C $SourcePath status --porcelain)
  if ($LASTEXITCODE -ne 0 -or $DirtySource.Count -ne 0) {
    throw "Vulkan source checkout must be clean before selecting the pinned commit."
  }
  Invoke-CheckedNative -FilePath $Git.Source `
    -Arguments @("-C", $SourcePath, "fetch", "--tags", "origin", $PinnedWhisperCommit) `
    -Description "whisper.cpp pinned source fetch"
  Invoke-CheckedNative -FilePath $Git.Source `
    -Arguments @("-C", $SourcePath, "checkout", "--detach", $PinnedWhisperCommit) `
    -Description "whisper.cpp pinned source checkout"
  $SourceCommit = (& $Git.Source -C $SourcePath rev-parse HEAD).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $SourceCommit -ne $PinnedWhisperCommit) {
    throw "whisper.cpp source did not resolve to pinned commit $PinnedWhisperCommit."
  }

  $env:VULKAN_SDK = $VulkanSdkPath
  $env:Path = "$(Join-Path $VulkanSdkPath 'Bin');$env:Path"
  New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null
  Invoke-CheckedNative -FilePath $Cmake.Source -Arguments @(
    "-S", $SourcePath,
    "-B", $BuildPath,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_C_COMPILER=$($CCompiler.Source)",
    "-DCMAKE_CXX_COMPILER=$($CxxCompiler.Source)",
    "-DVulkan_GLSLC_EXECUTABLE=$GlslcPath",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DGGML_VULKAN=ON",
    "-DWHISPER_BUILD_TESTS=OFF",
    "-DWHISPER_BUILD_EXAMPLES=ON",
    "-DWHISPER_BUILD_SERVER=ON"
  ) -Description "whisper.cpp Vulkan configure"
  Invoke-CheckedNative -FilePath $Cmake.Source -Arguments @(
    "--build", $BuildPath,
    "--config", "Release",
    "--target", "whisper-server", "whisper-cli",
    "--parallel", "$BuildParallelism"
  ) -Description "whisper.cpp Vulkan build"

  $BuiltServer = Find-WhisperServer -Root $BuildPath
  $BuiltCli = Find-WhisperCli -Root $BuildPath
  if (-not $BuiltServer -or -not $BuiltCli) {
    throw "Vulkan build completed without whisper-server.exe and whisper-cli.exe."
  }
  $ReleasePath = New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath.FullName "Release")
  Copy-VerifiedTool -Source $BuiltServer `
    -Destination (Join-Path $ReleasePath.FullName "whisper-server.exe")
  Copy-VerifiedTool -Source $BuiltCli `
    -Destination (Join-Path $ReleasePath.FullName "whisper-cli.exe")
  $WhisperServerExe = (Resolve-Path (Join-Path $ReleasePath.FullName "whisper-server.exe")).Path
  $WhisperExe = (Resolve-Path (Join-Path $ReleasePath.FullName "whisper-cli.exe")).Path
} else {
  $WhisperExe = Find-WhisperCli -Root $InstallPath.FullName
  $WhisperServerExe = Find-WhisperServer -Root $InstallPath.FullName
  if (-not $WhisperExe -or -not $WhisperServerExe -or $Force) {
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
    $WhisperServerExe = Find-WhisperServer -Root $InstallPath.FullName
    if (-not $WhisperServerExe) {
      throw "Downloaded whisper.cpp, but whisper-server.exe was not found under $($InstallPath.FullName)."
    }
  }
}

$ModelFileName = "ggml-$Model.bin"
$ModelPath = Join-Path $ModelsDir.FullName $ModelFileName
if ((-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) -or $Force) {
  $modelUri = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$ModelFileName"
  Invoke-Download -Uri $modelUri -OutFile $ModelPath
}
$ModelSha256 = (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($KnownModelSha256.ContainsKey($Model) -and $ModelSha256 -ne $KnownModelSha256[$Model]) {
  throw "Downloaded $Model model SHA-256 does not match the pinned production model."
}

$EnvScript = Join-Path $InstallPath.FullName "stackchan-whisper-env.ps1"
@(
  "`$env:STACKCHAN_WHISPER_CPP_EXE = '$($WhisperExe.Replace("'", "''"))'",
  "`$env:STACKCHAN_WHISPER_SERVER_EXE = '$($WhisperServerExe.Replace("'", "''"))'",
  "`$env:STACKCHAN_WHISPER_MODEL = '$($ModelPath.Replace("'", "''"))'",
  "`$env:STACKCHAN_STT_COMMAND = 'python bridge\whisper_cpp_stt.py'"
) | Set-Content -LiteralPath $EnvScript -Encoding UTF8

$result = [ordered]@{
  schema = "stackchan.whisper-cpp-setup.v1"
  status = "whisper-cpp-ready"
  backend = $Backend
  installDir = (Resolve-Path $InstallPath.FullName).Path
  whisperExe = $WhisperExe
  whisperServerExe = $WhisperServerExe
  whisperServerSha256 = (Get-FileHash -LiteralPath $WhisperServerExe -Algorithm SHA256).Hash.ToLowerInvariant()
  sourceTag = if ($Backend -eq "vulkan") { $PinnedWhisperTag } else { $null }
  sourceCommit = $SourceCommit
  sourceRepository = if ($Backend -eq "vulkan") { $WhisperRepository } else { $null }
  buildRoot = $BuildRootPath
  vulkanSdk = if ($Backend -eq "vulkan") { $VulkanSdkPath } else { $null }
  vulkanSdkVersion = $VulkanSdkVersion
  model = $Model
  modelPath = (Resolve-Path $ModelPath).Path
  modelSha256 = $ModelSha256
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
