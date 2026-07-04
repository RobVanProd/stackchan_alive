param(
    [int] $IdleMillis = 1800000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$companionRoot = Join-Path $repoRoot "companion"

Push-Location $companionRoot
try {
    .\gradlew.bat :app-desktop:c0Spike "-DidleMillis=$IdleMillis"
} finally {
    Pop-Location
}
