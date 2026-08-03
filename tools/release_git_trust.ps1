function Invoke-StackchanTrustedGit {
  param(
    [Parameter(Mandatory = $true)][string]$GitExecutable,
    [Parameter(Mandatory = $true)][string]$DisabledHooksPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  if (Test-Path -LiteralPath $DisabledHooksPath) {
    throw "Trusted Git disabled-hooks path must not exist: $DisabledHooksPath"
  }
  if (-not (Test-Path -LiteralPath $GitExecutable -PathType Leaf)) {
    throw "Trusted Git executable is missing: $GitExecutable"
  }
  $gitExecutableItem = Get-Item -LiteralPath $GitExecutable -Force
  if ($gitExecutableItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint -or
      ($env:OS -eq 'Windows_NT' -and [string]$gitExecutableItem.Extension -cne '.exe')) {
    throw "Trusted Git requires one exact non-redirected executable file: $GitExecutable"
  }
  $resolvedGitExecutable = $gitExecutableItem.FullName
  $gitArguments = @(
    '-c', "core.hooksPath=$DisabledHooksPath",
    '-c', 'core.fsmonitor=false',
    '-c', 'core.untrackedCache=false',
    '-c', 'core.useBuiltinFSMonitor=false',
    '-c', 'maintenance.auto=false',
    '-c', 'core.autocrlf=true',
    '-c', ('core.attributesFile=' + $(if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' })),
    '-c', 'filter.lfs.process=',
    '-c', 'filter.lfs.smudge=',
    '-c', 'filter.lfs.clean=',
    '-c', 'filter.lfs.required=false'
  )
  $gitArguments += $Arguments

  $previousNoReplaceObjects = $env:GIT_NO_REPLACE_OBJECTS
  $previousNoSystemAttributes = $env:GIT_ATTR_NOSYSTEM
  try {
    $env:GIT_NO_REPLACE_OBJECTS = '1'
    $env:GIT_ATTR_NOSYSTEM = '1'
    & $resolvedGitExecutable @gitArguments
  } finally {
    if ($null -eq $previousNoReplaceObjects) {
      Remove-Item Env:\GIT_NO_REPLACE_OBJECTS -ErrorAction SilentlyContinue
    } else {
      $env:GIT_NO_REPLACE_OBJECTS = $previousNoReplaceObjects
    }
    if ($null -eq $previousNoSystemAttributes) {
      Remove-Item Env:\GIT_ATTR_NOSYSTEM -ErrorAction SilentlyContinue
    } else {
      $env:GIT_ATTR_NOSYSTEM = $previousNoSystemAttributes
    }
  }
}
