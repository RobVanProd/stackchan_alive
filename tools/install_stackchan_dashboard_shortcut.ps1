param(
  [string]$DeviceHost = "192.168.1.238",
  [string]$ShortcutName = "Stackchan Alive.lnk"
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Launcher = (Resolve-Path (Join-Path $PSScriptRoot "start_stackchan_dashboard.ps1")).Path
$IconSource = (Resolve-Path (Join-Path $PSScriptRoot "..\docs\store-assets\desktop\stackchan-alive.ico")).Path
$StableRepoRoot = $RepoRoot
$WorktreeMarker = "$([IO.Path]::DirectorySeparatorChar)output$([IO.Path]::DirectorySeparatorChar)worktrees$([IO.Path]::DirectorySeparatorChar)"
$MarkerIndex = $RepoRoot.IndexOf($WorktreeMarker, [StringComparison]::OrdinalIgnoreCase)
if ($MarkerIndex -ge 0) { $StableRepoRoot = $RepoRoot.Substring(0, $MarkerIndex) }
$StableLauncher = Join-Path $StableRepoRoot "tools\start_stackchan_dashboard.ps1"
$BootstrapDir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "StackchanAlive"
$Bootstrap = Join-Path $BootstrapDir "start_dashboard.ps1"
$InstalledIcon = Join-Path $BootstrapDir "stackchan-alive.ico"
$Desktop = [Environment]::GetFolderPath("Desktop")
$ShortcutPath = Join-Path $Desktop $ShortcutName
$PowerShell = (Get-Command powershell.exe).Source

New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null
$BootstrapText = @"
`$ErrorActionPreference = "Stop"
`$launchers = @(
  '$($StableLauncher.Replace("'", "''"))',
  '$($Launcher.Replace("'", "''"))'
)
`$launcher = `$launchers | Where-Object { Test-Path -LiteralPath `$_ } | Select-Object -First 1
if (-not `$launcher) { throw "Stackchan dashboard launcher is not installed in the main checkout or its setup worktree." }
& `$launcher -DeviceHost '$($DeviceHost.Replace("'", "''"))'
exit `$LASTEXITCODE
"@
Set-Content -LiteralPath $Bootstrap -Value $BootstrapText -Encoding UTF8
Copy-Item -LiteralPath $IconSource -Destination $InstalledIcon -Force

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $PowerShell
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Bootstrap`""
$Shortcut.WorkingDirectory = $StableRepoRoot
$Shortcut.Description = "Start Stackchan Alive and open the local bridge dashboard"
$Shortcut.IconLocation = "$InstalledIcon,0"
$Shortcut.Save()

if (-not (Test-Path -LiteralPath $ShortcutPath)) {
  throw "Desktop shortcut was not created."
}
Write-Host "Created: $ShortcutPath"
