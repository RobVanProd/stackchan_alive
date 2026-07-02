param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
$repoRootPath = $repoRoot.Path.TrimEnd("\", "/")
$sourceRoot = "src"
if (-not (Test-Path -LiteralPath $sourceRoot) -and (Test-Path -LiteralPath "provenance/src")) {
  $sourceRoot = "provenance/src"
}
if (-not (Test-Path -LiteralPath $sourceRoot)) {
  throw "Missing source tree. Expected src/ in a checkout or provenance/src/ in a release package."
}

$platformioPath = "platformio.ini"
if (-not (Test-Path -LiteralPath $platformioPath) -and (Test-Path -LiteralPath "provenance/platformio.ini")) {
  $platformioPath = "provenance/platformio.ini"
}
if (-not (Test-Path -LiteralPath $platformioPath)) {
  throw "Missing platformio.ini. Expected platformio.ini in a checkout or provenance/platformio.ini in a release package."
}

function Get-RelativeRepoPath {
  param([string]$Path)

  $fullPath = (Resolve-Path $Path).Path
  if ($fullPath.StartsWith($repoRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($repoRootPath.Length).TrimStart("\", "/").Replace("/", "\")
  }

  return $fullPath.Replace("/", "\")
}

function Get-SourceFiles {
  return @(
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include *.cpp, *.hpp, *.h |
      Where-Object { $_.FullName -notmatch "\\output\\" }
  )
}

function Expand-SourcePath {
  param([string]$RelativePath)

  if ($RelativePath -like "src/*" -or $RelativePath -like "src\*") {
    $suffix = $RelativePath.Substring(3).TrimStart("/", "\")
    return Join-Path $sourceRoot $suffix
  }

  return $RelativePath
}

function Assert-FileContains {
  param(
    [string]$Path,
    [string]$Pattern,
    [string]$Message
  )

  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -notmatch $Pattern) {
    throw $Message
  }
}

function Assert-FileNotContains {
  param(
    [string]$Path,
    [string]$Pattern,
    [string]$Message
  )

  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -match $Pattern) {
    throw $Message
  }
}

function Assert-NoMatchesOutside {
  param(
    [string]$Pattern,
    [string[]]$AllowedRelativePaths,
    [string]$Message
  )

  $allowed = @{}
  foreach ($path in $AllowedRelativePaths) {
    $allowed[(Expand-SourcePath $path).Replace("/", "\").ToLowerInvariant()] = $true
  }

  foreach ($file in Get-SourceFiles) {
    $relative = Get-RelativeRepoPath $file.FullName
    if ($allowed.ContainsKey($relative.ToLowerInvariant())) {
      continue
    }

    $matches = Select-String -LiteralPath $file.FullName -Pattern $Pattern -AllMatches -CaseSensitive
    if ($matches) {
      $locations = @($matches | ForEach-Object { "$relative`:$($_.LineNumber)" })
      throw "$Message$([Environment]::NewLine)$($locations -join [Environment]::NewLine)"
    }
  }
}

function Assert-NoMatchesInDirectory {
  param(
    [string]$Directory,
    [string]$Pattern,
    [string]$Message
  )

  $matches = @(
    Get-ChildItem -LiteralPath $Directory -Recurse -File -Include *.cpp, *.hpp, *.h |
      ForEach-Object {
        $file = $_
        Select-String -LiteralPath $file.FullName -Pattern $Pattern -AllMatches -CaseSensitive |
          ForEach-Object {
            $relative = Get-RelativeRepoPath $file.FullName
            "$relative`:$($_.LineNumber)"
          }
      }
  )

  if ($matches.Count -gt 0) {
    throw "$Message$([Environment]::NewLine)$($matches -join [Environment]::NewLine)"
  }
}

function Assert-PlatformioFlag {
  param(
    [string]$Environment,
    [string]$ExpectedFlag
  )

  $text = Get-Content -LiteralPath $platformioPath -Raw
  $escapedEnv = [regex]::Escape("[env:$Environment]")
  $sectionMatch = [regex]::Match($text, "(?ms)^$escapedEnv\s*(.*?)(?=^\[|\z)")
  if (-not $sectionMatch.Success) {
    throw "$platformioPath missing environment: $Environment"
  }
  if ($sectionMatch.Groups[1].Value -notmatch [regex]::Escape($ExpectedFlag)) {
    throw "$platformioPath $Environment missing expected flag: $ExpectedFlag"
  }
}

Assert-NoMatchesOutside `
  -Pattern "Stackchan_servo\.h|StackchanSERVO|ServoType::|servo_\.|\.moveX\(|\.moveY\(" `
  -AllowedRelativePaths @(
    "src/io/StackChanServoAdapter.hpp",
    "src/io/StackChanServoAdapter.cpp"
  ) `
  -Message "Servo hardware library calls must stay inside StackChanServoAdapter."

Assert-NoMatchesOutside `
  -Pattern "M5\.Display|M5GFX|LGFX" `
  -AllowedRelativePaths @(
    "src/io/DisplayAdapter.hpp",
    "src/io/DisplayAdapter.cpp"
  ) `
  -Message "Display hardware calls must stay inside DisplayAdapter."

Assert-NoMatchesOutside `
  -Pattern "M5\.In_I2C|M5\.config|M5\.begin|M5\.update|M5\.Log|#include\s*<M5Unified\.h>" `
  -AllowedRelativePaths @(
    "src/main.cpp",
    "src/io/DisplayAdapter.cpp",
    "src/io/StackChanServoAdapter.hpp",
    "src/io/StackChanServoAdapter.cpp"
  ) `
  -Message "Board-level M5 hardware calls must stay in main setup or io adapters."

Assert-NoMatchesOutside `
  -Pattern "writePitchDeg\(|writeYawAngleDeg\(|writeYawVelocity\(" `
  -AllowedRelativePaths @(
    "src/motion/ActuationEngine.cpp",
    "src/motion/ActuationEngine.hpp",
    "src/io/StackChanServoAdapter.hpp",
    "src/io/StackChanServoAdapter.cpp"
  ) `
  -Message "Only MotionTask's actuation engine and the servo adapter may use actuator write methods."

Assert-NoMatchesInDirectory `
  -Directory (Expand-SourcePath "src/persona") `
  -Pattern "Serial\.|M5\.|StackchanSERVO|Stackchan_servo|IDisplay|IActuator|DisplayAdapter|StackChanServoAdapter" `
  -Message "Persona layer must not gain direct board/adapter dependencies."

Assert-NoMatchesOutside `
  -Pattern "globalState|RobotSystemState" `
  -AllowedRelativePaths @() `
  -Message "Frame communication must use snapshots, not shared global robot state."

Assert-FileContains (Expand-SourcePath "src/main.cpp") "xQueueCreate\s*\(\s*1\s*,\s*sizeof\s*\(\s*RobotFrame\s*\)" "Frame queue must be single-slot RobotFrame."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "xQueueOverwrite\s*\(\s*gFrameQueue\s*,\s*&frame\s*\)" "Frame publishing must overwrite the single-slot queue."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "xQueuePeek\s*\(\s*gFrameQueue\s*,\s*&incoming\s*,\s*0\s*\)" "Runtime tasks must read the latest frame snapshot without draining it."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "xTaskCreatePinnedToCore\s*\(\s*MotionTask\s*,[^;]*&gMotionTaskHandle\s*,\s*1\s*\)" "MotionTask must be pinned to Core 1 and expose a telemetry handle."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "xTaskCreatePinnedToCore\s*\(\s*FaceTask\s*,[^;]*&gFaceTaskHandle\s*,\s*1\s*\)" "FaceTask must be pinned to Core 1 and expose a telemetry handle."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "xTaskCreatePinnedToCore\s*\(\s*IntentTask\s*,[^;]*&gIntentTaskHandle\s*,\s*1\s*\)" "IntentTask must be pinned to Core 1 and expose a telemetry handle."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "\[system\]" "Main loop must emit runtime health telemetry."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "heap_free" "Runtime health telemetry must report free heap."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "heap_min" "Runtime health telemetry must report minimum free heap."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "stack_face_hwm" "Runtime health telemetry must report face task stack margin."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "\[speech\]" "Runtime must emit speech cue telemetry for output-adapter evidence."
Assert-FileContains (Expand-SourcePath "src/main.cpp") "speechSeq" "Speech cue telemetry must expose the dedupe sequence number."

Assert-PlatformioFlag "stackchan" "-D STACKCHAN_ENABLE_SERVOS=0"
Assert-PlatformioFlag "stackchan" "-O3"
Assert-PlatformioFlag "stackchan" "-ffast-math"
Assert-PlatformioFlag "stackchan" "-fno-math-errno"
Assert-PlatformioFlag "stackchan" "-D CORE_DEBUG_LEVEL=0"
Assert-PlatformioFlag "stackchan_servo_calibration" "-D STACKCHAN_ENABLE_SERVOS=1"
Assert-PlatformioFlag "stackchan_servo_calibration" "-O3"
Assert-PlatformioFlag "stackchan_servo_calibration" "-ffast-math"
Assert-PlatformioFlag "stackchan_servo_calibration" "-fno-math-errno"
Assert-PlatformioFlag "stackchan_servo_calibration" "-D CORE_DEBUG_LEVEL=0"

Assert-FileContains (Expand-SourcePath "src/face/FaceAnimator.cpp") "smoothingAlpha" "FaceAnimator must compute per-tau smoothing alpha once per frame."
Assert-FileContains (Expand-SourcePath "src/face/FaceAnimator.cpp") "const float alpha40" "FaceAnimator must cache smoothing alphas for hot-path channels."
Assert-FileContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "kOpenMouthSegments\s*=\s*12" "DisplayAdapter open-mouth tessellation must stay bounded for device frame time."
Assert-FileContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "kSmilePow06" "DisplayAdapter must use the smile gain lookup instead of powf in the render hot path."
Assert-FileContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "kFrameBudgetUs\s*=\s*33333" "DisplayAdapter must keep a 30 fps frame budget marker in telemetry."
Assert-FileContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "fps_window" "DisplayAdapter telemetry must report actual frame-window cadence."
Assert-FileContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "slow_frames" "DisplayAdapter telemetry must report frame-budget misses."
Assert-FileNotContains (Expand-SourcePath "src/io/DisplayAdapter.cpp") "powf\s*\(" "DisplayAdapter render hot path must not call powf."
Assert-FileContains (Expand-SourcePath "src/face/ProceduralFace.cpp") "\[face\]" "ProceduralFace must emit animator telemetry for real-device evidence."
Assert-FileContains (Expand-SourcePath "src/face/ProceduralFace.cpp") "blink_count" "Face telemetry must report blink counter."
Assert-FileContains (Expand-SourcePath "src/face/ProceduralFace.cpp") "saccade_count" "Face telemetry must report saccade counter."
Assert-FileContains (Expand-SourcePath "src/face/ProceduralFace.cpp") "speech_env" "Face telemetry must report speech envelope state."

Write-Host "Architecture boundaries verified."
