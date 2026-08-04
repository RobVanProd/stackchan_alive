$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Throws {
  param([scriptblock]$Action, [string]$Pattern)
  try {
    & $Action
  } catch {
    if ([string]$_.Exception.Message -notmatch $Pattern) {
      throw "Expected failure matching '$Pattern', got: $($_.Exception.Message)"
    }
    return
  }
  throw "Expected failure matching '$Pattern', but the action succeeded."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'stackchan-toolchain-identity-contract-' + [guid]::NewGuid().ToString('N'))
$isolationEnvironmentNames = @(
  'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'PYTHONDONTWRITEBYTECODE',
  'PYTHONHASHSEED', 'PYTHONUTF8', 'PYTHONIOENCODING',
  '__PYVENV_LAUNCHER__', '_PYTHON_HOST_PLATFORM',
  'CONDA_DEFAULT_ENV', 'CONDA_PREFIX', 'VIRTUAL_ENV',
  'PYTHONBREAKPOINT', 'PYTHONCASEOK', 'PYTHONCOERCECLOCALE', 'PYTHONDEBUG',
  'PYTHONEXECUTABLE', 'PYTHONFAULTHANDLER', 'PYTHONHOME', 'PYTHONINSPECT',
  'PYTHONINTMAXSTRDIGITS', 'PYTHONMALLOC', 'PYTHONNODEBUGRANGES', 'PYTHONPATH',
  'PYTHONOPTIMIZE', 'PYTHONPERFSUPPORT', 'PYTHONPLATLIBDIR', 'PYTHONPROFILEIMPORTTIME',
  'PYTHONPYCACHEPREFIX', 'PYTHONSTARTUP', 'PYTHONTRACEMALLOC', 'PYTHONUSERBASE',
  'PYTHONWARNDEFAULTENCODING', 'PYTHONWARNINGS'
)
$savedIsolationEnvironment = @{}
foreach ($name in $isolationEnvironmentNames) {
  $savedIsolationEnvironment[$name] = [Environment]::GetEnvironmentVariable(
    $name, [EnvironmentVariableTarget]::Process)
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $first = Join-Path $testRoot 'first'
  $second = Join-Path $testRoot 'second'
  New-Item -ItemType Directory -Path (Join-Path $first 'nested') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $second 'nested') -Force | Out-Null

  # Deliberately create the two path-independent fixtures in opposite orders.
  [IO.File]::WriteAllBytes((Join-Path $first 'alpha.txt'), [byte[]](0, 1, 2, 255))
  [IO.File]::WriteAllText((Join-Path $first 'nested/zeta.txt'), "zeta`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $second 'nested/zeta.txt'), "zeta`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 2, 255))
  $firstIdentity = Get-StackchanToolchainTreeIdentity -Root $first
  $secondIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($firstIdentity.treeSha256 -ceq $secondIdentity.treeSha256) `
    'Tree identity depends on absolute path or creation/enumeration order.'
  Assert-True ($firstIdentity.fileCount -eq 2 -and $firstIdentity.bytes -eq 9) `
    'Tree identity count/size accounting is incorrect.'

  $leaseRoot = Join-Path $testRoot 'lifetime-lease'
  New-Item -ItemType Directory -Path $leaseRoot | Out-Null
  $leaseFile = Join-Path $leaseRoot 'leased.txt'
  [IO.File]::WriteAllText($leaseFile, 'reviewed')
  $leaseState = New-StackchanToolchainLeaseState
  try {
    $leaseIdentity = Get-StackchanToolchainTreeIdentity `
      -Root $leaseRoot -LeaseState $leaseState -LeaseScope fixture
    $leaseHandleCount = $leaseState.streams.Count
    $repeatLeaseIdentity = Get-StackchanToolchainTreeIdentity `
      -Root $leaseRoot -LeaseState $leaseState -LeaseScope fixture
    Assert-True ($repeatLeaseIdentity.treeSha256 -ceq $leaseIdentity.treeSha256 -and
        $leaseState.streams.Count -eq $leaseHandleCount) `
      'Repeated guarded identity grew the retained-handle set or changed identity.'
    Assert-True ($leaseState.watchers.Count -eq 1) `
      'Guarded identity did not retain exactly one watcher for one component root.'
    if ($env:OS -eq 'Windows_NT') {
      Assert-Throws { [IO.File]::WriteAllText($leaseFile, 'unreviewed') } `
        '(used by another process|cannot access|being used)'
      Assert-Throws {
        Move-Item -LiteralPath $leaseFile -Destination (Join-Path $leaseRoot 'renamed.txt')
      } '(used by another process|cannot access|being used)'
      Assert-Throws { Remove-Item -LiteralPath $leaseFile -Force } `
        '(used by another process|cannot access|being used)'
    }
    $transientPath = Join-Path $leaseRoot 'transient-injection.py'
    [IO.File]::WriteAllText($transientPath, 'unreviewed')
    Remove-Item -LiteralPath $transientPath -Force
    Start-Sleep -Milliseconds 250
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $leaseState -Context 'transient injection fixture' -VerifyNamespace
    } 'changed after authentication'
    $transientEvidence = @($leaseState.violationEvidence)
    Assert-True ($transientEvidence.Count -gt 0 -and
        @($transientEvidence | Where-Object {
          [string]$_.schema -cne 'stackchan.toolchain-watcher-event.v1' -or
          [string]::IsNullOrWhiteSpace([string]$_.timeGeneratedUtc) -or
          [string]::IsNullOrWhiteSpace([string]$_.observedUtc) -or
          [string]::IsNullOrWhiteSpace([string]$_.watcherRoot) -or
          $null -eq $_.pathMetadata
        }).Count -eq 0) `
      'Transient watcher failure did not retain structured event evidence.'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $leaseState
  }
  [IO.File]::WriteAllText($leaseFile, 'released')
  Assert-True ([IO.File]::ReadAllText($leaseFile) -ceq 'released') `
    'Closing the guard did not release its retained file handles.'

  $subscriberRoot = Join-Path $testRoot 'missing-subscriber'
  New-Item -ItemType Directory -Path $subscriberRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $subscriberRoot 'input.txt'), 'reviewed')
  $subscriberState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $subscriberRoot -LeaseState $subscriberState -LeaseScope fixture)
    $subscriberWatcher = @($subscriberState.watchers.Values)[0]
    $removedSourceIdentifier = [string]$subscriberWatcher.sourceIdentifiers[0]
    Microsoft.PowerShell.Utility\Unregister-Event -SourceIdentifier $removedSourceIdentifier
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $subscriberState -Context 'missing subscriber fixture'
    } 'watcher subscription missing'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $subscriberState
  }

  $overflowRoot = Join-Path $testRoot 'overflow-event'
  New-Item -ItemType Directory -Path $overflowRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $overflowRoot 'input.txt'), 'reviewed')
  $overflowState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $overflowRoot -LeaseState $overflowState -LeaseScope fixture)
    $overflowWatcher = @($overflowState.watchers.Values)[0]
    $errorSourceIdentifier = @($overflowWatcher.sourceIdentifiers | Where-Object { $_ -like '*-Error' })[0]
    [void](Microsoft.PowerShell.Utility\New-Event `
      -SourceIdentifier $errorSourceIdentifier `
      -EventArguments @($overflowWatcher.watcher,
        [IO.ErrorEventArgs]::new([IO.InternalBufferOverflowException]::new('synthetic overflow'))))
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $overflowState -Context 'overflow fixture'
    } 'changed after authentication'
    $overflowEvidence = @($overflowState.violationEvidence)
    Assert-True ($overflowEvidence.Count -eq 1 -and
        [string]$overflowEvidence[0].registeredEventName -ceq 'Error' -and
        [string]$overflowEvidence[0].errorType -match 'InternalBufferOverflowException' -and
        [string]$overflowEvidence[0].errorMessage -match 'synthetic overflow') `
      'Watcher overflow did not retain its typed error evidence.'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $overflowState
  }

  $queuedRoot = Join-Path $testRoot 'queued-events'
  New-Item -ItemType Directory -Path $queuedRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $queuedRoot 'input.txt'), 'reviewed')
  $queuedState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $queuedRoot -LeaseState $queuedState -LeaseScope fixture)
    $queuedWatcher = @($queuedState.watchers.Values)[0]
    $changedSource = @($queuedWatcher.sourceIdentifiers | Where-Object { $_ -like '*-Changed' })[0]
    $createdSource = @($queuedWatcher.sourceIdentifiers | Where-Object { $_ -like '*-Created' })[0]
    $deletedSource = @($queuedWatcher.sourceIdentifiers | Where-Object { $_ -like '*-Deleted' })[0]
    $renamedSource = @($queuedWatcher.sourceIdentifiers | Where-Object { $_ -like '*-Renamed' })[0]
    [void](Microsoft.PowerShell.Utility\New-Event -SourceIdentifier $changedSource `
      -EventArguments @($queuedWatcher.watcher,
        [IO.FileSystemEventArgs]::new([IO.WatcherChangeTypes]::Changed, $queuedRoot, 'input.txt')))
    [void](Microsoft.PowerShell.Utility\New-Event -SourceIdentifier $createdSource `
      -EventArguments @($queuedWatcher.watcher,
        [IO.FileSystemEventArgs]::new([IO.WatcherChangeTypes]::Created, $queuedRoot, 'new.txt')))
    [void](Microsoft.PowerShell.Utility\New-Event -SourceIdentifier $deletedSource `
      -EventArguments @($queuedWatcher.watcher,
        [IO.FileSystemEventArgs]::new([IO.WatcherChangeTypes]::Deleted, $queuedRoot, 'gone.txt')))
    [void](Microsoft.PowerShell.Utility\New-Event -SourceIdentifier $renamedSource `
      -EventArguments @($queuedWatcher.watcher,
        [IO.RenamedEventArgs]::new([IO.WatcherChangeTypes]::Renamed, $queuedRoot,
          'new-name.txt', 'old-name.txt')))
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $queuedState -Context 'complete queued event fixture'
    } 'events=4'
    $queuedEvidence = @($queuedState.violationEvidence)
    $queuedNames = @($queuedEvidence.registeredEventName | Sort-Object)
    Assert-True ($queuedEvidence.Count -eq 4 -and
        ($queuedNames -join ',') -ceq 'Changed,Created,Deleted,Renamed' -and
        @($queuedEvidence.ordinal) -join ',' -ceq '0,1,2,3' -and
        @($queuedEvidence | Where-Object { -not [bool]$_.queueRemovalSucceeded }).Count -eq 0 -and
        @($queuedEvidence | Where-Object {
          [string]$_.registeredEventName -ceq 'Renamed' -and
          [string]$_.oldName -ceq 'old-name.txt' -and
          [string]$_.oldFullPath -ceq (Join-Path $queuedRoot 'old-name.txt')
        }).Count -eq 1) `
      'Watcher drain did not preserve every queued event and rename field.'
    $evidenceCountBeforeRepeatDrain = $queuedState.violationEvidence.Count
    $repeatDrainCount = Add-StackchanToolchainQueuedEventEvidence -LeaseState $queuedState
    Assert-True ($repeatDrainCount -eq 0 -and
        $queuedState.violationEvidence.Count -eq $evidenceCountBeforeRepeatDrain) `
      'Repeated watcher drain duplicated retained event evidence.'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $queuedState
  }

  $orderedRootA = Join-Path $testRoot 'globally-ordered-a'
  $orderedRootB = Join-Path $testRoot 'globally-ordered-b'
  New-Item -ItemType Directory -Path $orderedRootA, $orderedRootB | Out-Null
  [IO.File]::WriteAllText((Join-Path $orderedRootA 'input.txt'), 'reviewed')
  [IO.File]::WriteAllText((Join-Path $orderedRootB 'input.txt'), 'reviewed')
  $orderedState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $orderedRootA -LeaseState $orderedState -LeaseScope fixture)
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $orderedRootB -LeaseState $orderedState -LeaseScope fixture)
    $orderedWatcherA = $orderedState.watchers[[IO.Path]::GetFullPath($orderedRootA)]
    $orderedWatcherB = $orderedState.watchers[[IO.Path]::GetFullPath($orderedRootB)]
    $orderedChangedA = @($orderedWatcherA.sourceIdentifiers | Where-Object {
        $_ -like '*-Changed' })[0]
    $orderedChangedB = @($orderedWatcherB.sourceIdentifiers | Where-Object {
        $_ -like '*-Changed' })[0]
    [void](Microsoft.PowerShell.Utility\New-Event `
      -SourceIdentifier $orderedChangedB `
      -EventArguments @($orderedWatcherB.watcher,
        [IO.FileSystemEventArgs]::new(
          [IO.WatcherChangeTypes]::Changed, $orderedRootB, 'input.txt')))
    Start-Sleep -Milliseconds 100
    [void](Microsoft.PowerShell.Utility\New-Event `
      -SourceIdentifier $orderedChangedA `
      -EventArguments @($orderedWatcherA.watcher,
        [IO.FileSystemEventArgs]::new(
          [IO.WatcherChangeTypes]::Changed, $orderedRootA, 'input.txt')))
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $orderedState -Context 'global chronological fixture'
    } 'events=2'
    $orderedEvidence = @($orderedState.violationEvidence)
    Assert-True ($orderedEvidence.Count -eq 2 -and
        [string]$orderedEvidence[0].watcherRoot -ceq [IO.Path]::GetFullPath($orderedRootB) -and
        [string]$orderedEvidence[1].watcherRoot -ceq [IO.Path]::GetFullPath($orderedRootA) -and
        [datetime]$orderedEvidence[0].timeGeneratedUtc -lt
          [datetime]$orderedEvidence[1].timeGeneratedUtc) `
      'Watcher evidence was not ordered chronologically across guarded roots.'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $orderedState
  }

  $crossBatchRootA = Join-Path $testRoot 'cross-batch-a'
  $crossBatchRootB = Join-Path $testRoot 'cross-batch-b'
  New-Item -ItemType Directory -Path $crossBatchRootA, $crossBatchRootB | Out-Null
  [IO.File]::WriteAllText((Join-Path $crossBatchRootA 'input.txt'), 'reviewed')
  [IO.File]::WriteAllText((Join-Path $crossBatchRootB 'input.txt'), 'reviewed')
  $crossBatchState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $crossBatchRootA -LeaseState $crossBatchState -LeaseScope fixture)
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $crossBatchRootB -LeaseState $crossBatchState -LeaseScope fixture)
    $crossBatchPathA = [IO.Path]::GetFullPath($crossBatchRootA)
    $crossBatchPathB = [IO.Path]::GetFullPath($crossBatchRootB)
    $crossBatchWatcherA = $crossBatchState.watchers[$crossBatchPathA]
    $crossBatchWatcherB = $crossBatchState.watchers[$crossBatchPathB]
    $crossBatchChangedA = @($crossBatchWatcherA.sourceIdentifiers | Where-Object {
        $_ -like '*-Changed' })[0]
    $crossBatchChangedB = @($crossBatchWatcherB.sourceIdentifiers | Where-Object {
        $_ -like '*-Changed' })[0]
    [void](Microsoft.PowerShell.Utility\New-Event `
      -SourceIdentifier $crossBatchChangedA `
      -EventArguments @($crossBatchWatcherA.watcher,
        [IO.FileSystemEventArgs]::new(
          [IO.WatcherChangeTypes]::Changed, $crossBatchRootA, 'earlier.txt')))
    Start-Sleep -Milliseconds 100
    [void](Microsoft.PowerShell.Utility\New-Event `
      -SourceIdentifier $crossBatchChangedB `
      -EventArguments @($crossBatchWatcherB.watcher,
        [IO.FileSystemEventArgs]::new(
          [IO.WatcherChangeTypes]::Changed, $crossBatchRootB, 'later.txt')))
    [void]$crossBatchState.watchers.Remove($crossBatchPathA)
    $crossBatchFirstDrain = Add-StackchanToolchainQueuedEventEvidence `
      -LeaseState $crossBatchState
    $crossBatchState.watchers.Add($crossBatchPathA, $crossBatchWatcherA)
    $crossBatchSecondDrain = Add-StackchanToolchainQueuedEventEvidence `
      -LeaseState $crossBatchState
    $crossBatchEvidence = @($crossBatchState.violationEvidence)
    Assert-True ($crossBatchFirstDrain -eq 1 -and $crossBatchSecondDrain -eq 1 -and
        $crossBatchEvidence.Count -eq 2 -and
        [string]$crossBatchEvidence[0].name -ceq 'earlier.txt' -and
        [string]$crossBatchEvidence[1].name -ceq 'later.txt' -and
        @($crossBatchEvidence.ordinal) -join ',' -ceq '0,1' -and
        [datetime]$crossBatchEvidence[0].timeGeneratedUtc -lt
          [datetime]$crossBatchEvidence[1].timeGeneratedUtc) `
      'Cumulative watcher evidence was not globally reordered across drain batches.'
  } finally {
    if (-not $crossBatchState.watchers.ContainsKey([IO.Path]::GetFullPath($crossBatchRootA))) {
      $crossBatchState.watchers.Add(
        [IO.Path]::GetFullPath($crossBatchRootA), $crossBatchWatcherA)
    }
    Close-StackchanToolchainLeaseState -LeaseState $crossBatchState
  }

  foreach ($closureKind in @('scope', 'state')) {
    $closureRoot = Join-Path $testRoot "queued-$closureKind-closure"
    New-Item -ItemType Directory -Path $closureRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $closureRoot 'input.txt'), 'reviewed')
    $closureState = New-StackchanToolchainLeaseState
    try {
      [void](Get-StackchanToolchainTreeIdentity `
        -Root $closureRoot -LeaseState $closureState -LeaseScope fixture)
      $closureWatcher = @($closureState.watchers.Values)[0]
      $script:closureCreatedSource = @($closureWatcher.sourceIdentifiers | Where-Object {
          $_ -like '*-Created' })[0]
      $script:closureWatcher = $closureWatcher
      $script:closureRoot = $closureRoot
      $script:closureAssertDepth = 0
      $script:closureOriginalAssert = ${function:Assert-StackchanToolchainLeaseStateUnchanged}
      Set-Item -LiteralPath Function:Assert-StackchanToolchainLeaseStateUnchanged -Value {
        param(
          [Parameter(Mandatory = $true)]$LeaseState,
          [Parameter(Mandatory = $true)][string]$Context,
          [switch]$VerifyNamespace
        )
        $script:closureAssertDepth++
        try {
          & $script:closureOriginalAssert @PSBoundParameters
        } finally {
          $script:closureAssertDepth--
        }
        if ($script:closureAssertDepth -eq 0) {
          [void](Microsoft.PowerShell.Utility\New-Event `
            -SourceIdentifier $script:closureCreatedSource `
            -EventArguments @($script:closureWatcher.watcher,
              [IO.FileSystemEventArgs]::new(
                [IO.WatcherChangeTypes]::Created, $script:closureRoot, 'late.txt')))
        }
      }
      try {
        if ($closureKind -ceq 'scope') {
          Assert-Throws {
            Close-StackchanToolchainLeaseScope -LeaseState $closureState -Scope fixture `
              -RequireUnchanged -Context 'queued scope closure fixture'
          } 'changed during guarded scope closure'
        } else {
          Assert-Throws {
            Close-StackchanToolchainLeaseState -LeaseState $closureState `
              -RequireUnchanged -Context 'queued state closure fixture'
          } 'changed during guarded state closure'
        }
      } finally {
        Set-Item -LiteralPath Function:Assert-StackchanToolchainLeaseStateUnchanged `
          -Value $script:closureOriginalAssert
      }
      Assert-True (@($closureState.violationEvidence).Count -eq 1 -and
          [string]$closureState.violationEvidence[0].registeredEventName -ceq 'Created') `
        "Queued $closureKind closure did not retain its event evidence."
      if ($closureKind -ceq 'scope') {
        Assert-True ($closureState.watchers.Count -eq 0 -and
            $closureState.streams.Count -eq 0) `
          'Scope closure event was caught before, rather than during, post-disable drain.'
      } else {
        Assert-True ([bool]$closureState.closed) `
          'State closure event was caught before, rather than during, post-disable drain.'
      }
    } finally {
      Close-StackchanToolchainLeaseState -LeaseState $closureState
    }
  }

  foreach ($lateCleanupKind in @('scope', 'state')) {
    $lateCleanupRoot = Join-Path $testRoot "late-after-snapshot-$lateCleanupKind"
    New-Item -ItemType Directory -Path $lateCleanupRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $lateCleanupRoot 'input.txt'), 'reviewed')
    $lateCleanupState = New-StackchanToolchainLeaseState
    try {
      [void](Get-StackchanToolchainTreeIdentity `
        -Root $lateCleanupRoot -LeaseState $lateCleanupState -LeaseScope fixture)
      $lateCleanupWatcher = @($lateCleanupState.watchers.Values)[0]
      $lateChangedSource = @($lateCleanupWatcher.sourceIdentifiers | Where-Object {
          $_ -like '*-Changed' })[0]
      $script:lateCreatedSource = @($lateCleanupWatcher.sourceIdentifiers | Where-Object {
          $_ -like '*-Created' })[0]
      $script:lateCleanupWatcher = $lateCleanupWatcher
      $script:lateCleanupRoot = $lateCleanupRoot
      $script:lateMetadataInjected = $false
      $script:lateOriginalMetadata = ${function:Get-StackchanToolchainEventPathMetadata}
      Set-Item -LiteralPath Function:Get-StackchanToolchainEventPathMetadata -Value {
        param([AllowNull()][AllowEmptyString()][string]$LiteralPath)
        $result = & $script:lateOriginalMetadata -LiteralPath $LiteralPath
        if (-not $script:lateMetadataInjected) {
          $script:lateMetadataInjected = $true
          [void](Microsoft.PowerShell.Utility\New-Event `
            -SourceIdentifier $script:lateCreatedSource `
            -EventArguments @($script:lateCleanupWatcher.watcher,
              [IO.FileSystemEventArgs]::new(
                [IO.WatcherChangeTypes]::Created,
                $script:lateCleanupRoot,
                'late-after-snapshot.txt')))
        }
        return $result
      }
      [void](Microsoft.PowerShell.Utility\New-Event `
        -SourceIdentifier $lateChangedSource `
        -EventArguments @($lateCleanupWatcher.watcher,
          [IO.FileSystemEventArgs]::new(
            [IO.WatcherChangeTypes]::Changed, $lateCleanupRoot, 'input.txt')))
      try {
        Assert-Throws {
          Assert-StackchanToolchainLeaseStateUnchanged `
            -LeaseState $lateCleanupState -Context 'late-after-snapshot fixture'
        } 'events=1'
      } finally {
        Set-Item -LiteralPath Function:Get-StackchanToolchainEventPathMetadata `
          -Value $script:lateOriginalMetadata
      }
      Assert-True (@($lateCleanupState.violationEvidence).Count -eq 1 -and
          @(Microsoft.PowerShell.Utility\Get-Event `
            -SourceIdentifier $script:lateCreatedSource -ErrorAction SilentlyContinue).Count -eq 1) `
        'Late-after-snapshot fixture did not retain one queued event before cleanup.'
      if ($lateCleanupKind -ceq 'scope') {
        Close-StackchanToolchainLeaseScope `
          -LeaseState $lateCleanupState -Scope fixture
      } else {
        Close-StackchanToolchainLeaseState -LeaseState $lateCleanupState
      }
      $lateCleanupEvidence = @($lateCleanupState.violationEvidence)
      Assert-True ($lateCleanupEvidence.Count -eq 2 -and
          [string]$lateCleanupEvidence[1].registeredEventName -ceq 'Created' -and
          [string]$lateCleanupEvidence[1].name -ceq 'late-after-snapshot.txt' -and
          [bool]$lateCleanupEvidence[1].queueRemovalSucceeded -and
          @(Microsoft.PowerShell.Utility\Get-Event `
            -SourceIdentifier $script:lateCreatedSource -ErrorAction SilentlyContinue).Count -eq 0) `
        "Non-requiring $lateCleanupKind cleanup discarded late queued watcher evidence."
    } finally {
      Set-Item -LiteralPath Function:Get-StackchanToolchainEventPathMetadata `
        -Value $script:lateOriginalMetadata -ErrorAction SilentlyContinue
      Close-StackchanToolchainLeaseState -LeaseState $lateCleanupState
    }
  }

  $disabledRoot = Join-Path $testRoot 'disabled-watcher'
  New-Item -ItemType Directory -Path $disabledRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $disabledRoot 'input.txt'), 'reviewed')
  $disabledState = New-StackchanToolchainLeaseState
  try {
    [void](Get-StackchanToolchainTreeIdentity `
      -Root $disabledRoot -LeaseState $disabledState -LeaseScope fixture)
    @($disabledState.watchers.Values)[0].watcher.EnableRaisingEvents = $false
    Assert-Throws {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $disabledState -Context 'disabled watcher fixture'
    } 'watcher disabled'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $disabledState
  }

  New-Item -ItemType Directory -Path (Join-Path $second '.git') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $second '__pycache__') | Out-Null
  [IO.File]::WriteAllText((Join-Path $second '.git/noise'), 'ignored')
  [IO.File]::WriteAllText((Join-Path $second '__pycache__/noise.pyc'), 'ignored')
  [IO.File]::WriteAllText((Join-Path $second 'noise.pyc'), 'ignored')
  $cacheIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($cacheIdentity.treeSha256 -cne $firstIdentity.treeSha256) `
    'Executable bytecode or Git metadata was silently excluded from byte identity.'

  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 3, 255))
  $mutatedIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($mutatedIdentity.treeSha256 -cne $cacheIdentity.treeSha256) `
    'A same-length byte mutation did not change the tree identity.'

  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 2, 255))
  Move-Item -LiteralPath (Join-Path $second 'alpha.txt') -Destination (Join-Path $second 'case-tmp.txt')
  Move-Item -LiteralPath (Join-Path $second 'case-tmp.txt') -Destination (Join-Path $second 'ALPHA.txt')
  $caseIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($caseIdentity.treeSha256 -cne $cacheIdentity.treeSha256) `
    'A relative-path case mutation did not change the tree identity.'

  foreach ($unsafe in @('../escape', 'safe/../escape', 'C:/escape', '/escape', './escape', "bad`0name")) {
    Assert-Throws { ConvertTo-StackchanSafeIdentityRelativePath $unsafe } '(Unsafe|Non-canonical)'
  }

  if ($env:OS -ne 'Windows_NT') {
    $caseRoot = Join-Path $testRoot 'case-ambiguous'
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $caseRoot 'A'), 'a')
    [IO.File]::WriteAllText((Join-Path $caseRoot 'a'), 'b')
    Assert-Throws { Get-StackchanToolchainTreeIdentity -Root $caseRoot } 'Case-ambiguous'
  }

  $policy = @(Get-StackchanReleaseToolchainComponentPolicy -PlatformKey 'windows_amd64')
  $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($component in @($policy | Where-Object phase -ceq 'preBuild')) {
    Assert-True ($names.Add([string]$component.name)) "Duplicate policy component: $($component.name)"
    [void](ConvertTo-StackchanSafeIdentityRelativePath ([string]$component.relativePath))
    Assert-True ([string]$component.phase -in @('preBuild', 'postBuild')) `
      "Invalid component phase: $($component.name)"
  }
  Assert-True (@($policy | Where-Object { $_.name -like 'project-libdeps-*' }).Count -eq 3) `
    'Policy does not bind all three release libdeps trees after build.'
  Assert-True (@($policy | Where-Object { $_.name -like '*toolchain*' }).Count -ge 3) `
    'Policy does not bind the installed compiler toolchains.'
  Assert-True (@($policy | Where-Object { $_.name -eq 'legacy-core-penv' }).Count -eq 1 -and
    @($policy | Where-Object { $_.name -eq 'release-core-penv' }).Count -eq 1) `
    'Policy does not bind both PlatformIO-managed Python environments.'
  Assert-True (@($policy | Where-Object {
      $_.name -eq 'release-toolchain-identity-policy-source'
    }).Count -eq 1) 'Policy does not bind its reviewed PowerShell implementation bytes.'
  $pythonPolicy = @($policy | Where-Object { $_.name -eq 'python-installation' })
  Assert-True ($pythonPolicy.Count -eq 1 -and [string]$pythonPolicy[0].relativePath -ceq '@root') `
    'Policy does not bind the complete Python installation as one closed root.'
  Assert-Throws {
    Get-StackchanReleaseToolchainComponentPolicy -PlatformKey 'linux_amd64'
  } 'No reviewed release toolchain component policy'

  $fixtureRoots = @{
    pythonHome = Join-Path $testRoot 'identity-host/python'
    gitHome = Join-Path $testRoot 'identity-host/git'
    legacyCore = Join-Path $testRoot 'identity-host/legacy-core'
    releaseCore = Join-Path $testRoot 'identity-host/release-core'
    projectRoot = Join-Path $testRoot 'identity-host/project'
    libdepsRoot = Join-Path $testRoot 'identity-host/project/.pio/libdeps'
  }
  foreach ($root in $fixtureRoots.Values) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
  }
  foreach ($component in $policy) {
    $componentPath = Resolve-StackchanIdentityComponentPath `
      -RootMap $fixtureRoots -Component $component
    if ([IO.Path]::GetExtension($componentPath) -in @('.exe', '.dll', '.py')) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $componentPath) -Force | Out-Null
      [IO.File]::WriteAllText($componentPath, [string]$component.name)
    } else {
      New-Item -ItemType Directory -Path $componentPath -Force | Out-Null
      [IO.File]::WriteAllText((Join-Path $componentPath 'identity.fixture'), [string]$component.name)
    }
  }
  New-Item -ItemType Directory -Path (Join-Path $fixtureRoots.pythonHome 'Scripts') -Force | Out-Null
  foreach ($relative in @('python.exe', 'python312.zip', 'Scripts/pio.exe', 'Scripts/platformio.exe')) {
    [IO.File]::WriteAllText((Join-Path $fixtureRoots.pythonHome $relative), "fixture:$relative")
  }
  $fixturePio = Join-Path $fixtureRoots.pythonHome 'Scripts/platformio.exe'
  $fixturePython = Join-Path $fixtureRoots.pythonHome 'python.exe'
  $fixtureGit = Join-Path $fixtureRoots.gitHome 'cmd/git.exe'
  New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureGit) -Force | Out-Null
  [IO.File]::WriteAllText($fixtureGit, 'fixture:cmd/git.exe')
  $fixtureAllowlist = Join-Path $testRoot 'reviewed-fixture-allowlist.json'
  $candidate = [pscustomobject][ordered]@{
    schema = 'stackchan.release-toolchain-identity.v3'
    platformKey = 'windows_amd64'
    platformioCoreVersion = '6.1.19'
    pythonVersion = '3.12.10'
    identityScope = 'exact-host-installed-bytes'
    portableAcrossHosts = $false
    canonicalLibdepsSchema = 'stackchan.canonical-libdeps.v1'
    platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
    pythonExecutableRelativePath = 'python.exe'
    gitExecutableRelativePath = 'cmd/git.exe'
    review = [pscustomobject][ordered]@{
      status = 'reviewed'
      reviewer = 'fixture-reviewer'
      reason = 'contract fixture'
    }
    components = @(Get-StackchanReleaseToolchainObservedComponents `
      -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  }
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  $observedPython = @($candidate.components | Where-Object name -ceq 'python-installation')
  Assert-True ($observedPython.Count -eq 1 -and $observedPython[0].fileCount -ge 5) `
    'Complete Python installation inventory omitted root, archive, or Scripts bytes.'

  $pythonHomeFull = (Get-Item -LiteralPath $fixtureRoots.pythonHome).FullName.TrimEnd('\', '/')
  $fixturePythonFull = (Get-Item -LiteralPath $fixturePython).FullName
  $validProbe = [pscustomobject]@{
    executable = $fixturePythonFull
    prefix = $pythonHomeFull
    base_prefix = $pythonHomeFull
    path = @(
      (Join-Path $pythonHomeFull 'python312.zip'), (Join-Path $pythonHomeFull 'DLLs'),
      (Join-Path $pythonHomeFull 'Lib'), $pythonHomeFull,
      (Join-Path $pythonHomeFull 'Lib/site-packages'))
    enable_user_site = $false
    flags = [pscustomobject]@{
      no_user_site = 1; safe_path = $true; dont_write_bytecode = 1; optimize = 0
    }
  }
  Assert-StackchanPythonImportIsolationState `
    -Probe $validProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  $escapedProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $escapedProbe.path += (Join-Path $testRoot 'external-python')
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $escapedProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'import path contains an external'
  $userSiteProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $userSiteProbe.enable_user_site = $true
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $userSiteProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $unsafePathProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $unsafePathProbe.flags.safe_path = $false
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $unsafePathProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $optimizedProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $optimizedProbe.flags.optimize = 1
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $optimizedProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $wrongExecutableProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $wrongExecutable = Join-Path $fixtureRoots.pythonHome 'other-python.exe'
  [IO.File]::WriteAllText($wrongExecutable, 'other')
  $wrongExecutableProbe.executable = $wrongExecutable
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $wrongExecutableProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'

  foreach ($name in $isolationEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
  }
  $requiredIsolation = [ordered]@{
    PYTHONNOUSERSITE = '1'; PYTHONSAFEPATH = '1'; PYTHONDONTWRITEBYTECODE = '1'
    PYTHONHASHSEED = '0'; PYTHONUTF8 = '1'; PYTHONIOENCODING = 'utf-8'
  }
  foreach ($entry in $requiredIsolation.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(
      [string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
  }
  $escapePath = Join-Path $fixtureRoots.pythonHome 'Lib/site-packages/escape.pth'
  New-Item -ItemType Directory -Path (Split-Path -Parent $escapePath) -Force | Out-Null
  [IO.File]::WriteAllText($escapePath, (Join-Path $testRoot 'outside'))
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'escape files'
  Remove-Item -LiteralPath $escapePath -Force
  [Environment]::SetEnvironmentVariable(
    'PYTHONNOUSERSITE', $null, [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'requires PYTHONNOUSERSITE=1'
  [Environment]::SetEnvironmentVariable(
    'PYTHONNOUSERSITE', '1', [EnvironmentVariableTarget]::Process)
  [Environment]::SetEnvironmentVariable(
    'PYTHONOPTIMIZE', '1', [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'ambient import/runtime override: PYTHONOPTIMIZE'
  [Environment]::SetEnvironmentVariable(
    'PYTHONOPTIMIZE', $null, [EnvironmentVariableTarget]::Process)

  [Environment]::SetEnvironmentVariable(
    'PYTHONSAFEPATH', $null, [EnvironmentVariableTarget]::Process)
  Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $fixtureRoots.projectRoot
  [Environment]::SetEnvironmentVariable(
    'PYTHONPATH', (Join-Path $testRoot 'outside'), [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $fixtureRoots.projectRoot
  } 'ambient import/runtime override: PYTHONPATH'
  [Environment]::SetEnvironmentVariable(
    'PYTHONPATH', $null, [EnvironmentVariableTarget]::Process)
  [Environment]::SetEnvironmentVariable(
    'PYTHONSAFEPATH', '1', [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $fixtureRoots.projectRoot
  } 'requires PYTHONSAFEPATH to be unset'
  [Environment]::SetEnvironmentVariable(
    'PYTHONSAFEPATH', $null, [EnvironmentVariableTarget]::Process)
  [IO.File]::WriteAllText((Join-Path $fixtureRoots.projectRoot 'sitecustomize.py'), 'raise SystemExit(1)')
  Assert-Throws {
    Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $fixtureRoots.projectRoot
  } 'Python import escape file'
  Remove-Item -LiteralPath (Join-Path $fixtureRoots.projectRoot 'sitecustomize.py') -Force
  [Environment]::SetEnvironmentVariable(
    'PYTHONSAFEPATH', '1', [EnvironmentVariableTarget]::Process)

  $candidate.platformioExecutableRelativePaths = @(
    'Scripts/pio.exe', 'Scripts/platformio.exe', 'Scripts/fake-pio.exe')
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'executable paths are not the canonical policy'
  $candidate.platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
  $candidate.pythonExecutableRelativePath = 'Scripts/python.exe'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'executable paths are not the canonical policy'
  $candidate.pythonExecutableRelativePath = 'python.exe'

  $missingAllowlist = Join-Path $testRoot 'missing-allowlist.json'
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $missingAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(Cannot find path|does not exist)'
  $candidate.review.status = 'candidate-unreviewed'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(absent|unreviewed|another platform)'
  $candidate.review.status = 'reviewed'
  $candidate.platformKey = 'linux_amd64'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(absent|unreviewed|another platform)'
  $candidate.platformKey = 'windows_amd64'
  $candidate.identityScope = 'portable-version-only'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'version policy mismatch'
  $candidate.identityScope = 'exact-host-installed-bytes'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  $beforeMutation = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  [IO.File]::AppendAllText((
    Join-Path $fixtureRoots.legacyCore 'packages/toolchain-riscv32-esp/identity.fixture'), 'wrong-host')
  $afterMutation = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  $beforeCompiler = @($beforeMutation | Where-Object name -ceq 'legacy-package-toolchain-riscv32-esp')[0]
  $afterCompiler = @($afterMutation | Where-Object name -ceq 'legacy-package-toolchain-riscv32-esp')[0]
  Assert-True ($beforeCompiler.treeSha256 -cne $afterCompiler.treeSha256) `
    'A compiler-toolchain byte mutation did not change the observed pre-build identity.'

  foreach ($environment in @('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')) {
    $environmentPolicy = Get-StackchanExpectedLibdepsPolicy -Environment $environment
    Assert-True (@($environmentPolicy.leaves | Where-Object { $_ -ceq 'M5GFX' }).Count -eq 1) `
      "Fresh-libdeps policy does not require one canonical M5GFX leaf: $environment"
    Assert-True (@($environmentPolicy.leaves | Where-Object { $_ -match '^M5GFX@' }).Count -eq 0) `
      "Fresh-libdeps policy still permits a duplicate M5GFX version leaf: $environment"
    Assert-True (@($environmentPolicy.leaves | Where-Object { $_ -ceq 'M5Unified' }).Count -eq 1 -and
      @($environmentPolicy.leaves | Where-Object { $_ -match '^M5Unified@' }).Count -eq 0) `
      "Fresh-libdeps policy does not require one canonical M5Unified leaf: $environment"
    Assert-True (@($environmentPolicy.requirements | Where-Object {
      $_ -ceq 'M5Stack/M5GFX@0.2.24'
    }).Count -eq 1 -and @($environmentPolicy.requirements | Where-Object {
      $_ -ceq 'M5GFX@0.2.24'
    }).Count -eq 0) `
      "Fresh-libdeps policy does not require the owner-qualified exact M5GFX spec: $environment"
  }

  $registryVersionRoot = Join-Path $testRoot 'registry-version-fixture'
  New-Item -ItemType Directory -Path (Join-Path $registryVersionRoot 'M5GFX') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $registryVersionRoot 'M5Unified') -Force | Out-Null
  $registryVersionPolicy = Get-StackchanExpectedLibdepsPolicy -Environment stackchan_release_full
  [IO.File]::WriteAllText(
    (Join-Path $registryVersionRoot 'M5GFX/library.json'),
    '{"name":"M5GFX","version":"0.2.26"}')
  Assert-Throws {
    Assert-StackchanReviewedRegistryLibraryVersions `
      -Root $registryVersionRoot -Policy $registryVersionPolicy `
      -Environment stackchan_release_full
  } 'name/version does not match exact policy'
  [IO.File]::WriteAllText(
    (Join-Path $registryVersionRoot 'M5GFX/library.json'),
    '{"name":"M5GFX","version":"0.2.24"}')
  [IO.File]::WriteAllText(
    (Join-Path $registryVersionRoot 'M5Unified/library.json'),
    '{"name":"M5Unified","version":"0.2.17"}')
  Assert-StackchanReviewedRegistryLibraryVersions `
    -Root $registryVersionRoot -Policy $registryVersionPolicy `
    -Environment stackchan_release_full
  [IO.File]::WriteAllText(
    (Join-Path $registryVersionRoot 'M5Unified/library.json'),
    '{"name":"M5Unified","version":"0.2.19"}')
  Assert-Throws {
    Assert-StackchanReviewedRegistryLibraryVersions `
      -Root $registryVersionRoot -Policy $registryVersionPolicy `
      -Environment stackchan_release_full
  } 'name/version does not match exact policy'

  $staleLibdeps = Join-Path $fixtureRoots.projectRoot '.pio/libdeps/stackchan'
  $stalePolicy = Get-StackchanExpectedLibdepsPolicy -Environment stackchan
  New-Item -ItemType Directory -Path $staleLibdeps -Force | Out-Null
  foreach ($leaf in @($stalePolicy.leaves) + @('M5GFX@0.2.24')) {
    New-Item -ItemType Directory -Path (Join-Path $staleLibdeps $leaf) -Force | Out-Null
  }
  [IO.File]::WriteAllLines((Join-Path $staleLibdeps 'integrity.dat'), [string[]]$stalePolicy.requirements)
  Assert-Throws {
    Get-StackchanCanonicalLibdepsIdentity -Root $staleLibdeps -Environment stackchan
  } 'stale or has unexpected packages/files'
  Assert-Throws {
    New-StackchanReleaseToolchainIdentityCandidate `
      -RootMap $fixtureRoots -PlatformioExecutable $fixturePio `
      -PythonExecutable $fixturePython -PlatformKey windows_amd64
  } 'isolation probe failed'
  Assert-Throws {
    Get-StackchanReleaseToolchainObservedComponents `
      -RootMap $fixtureRoots -Phase PostBuild -PlatformKey windows_amd64
  } 'stale or has unexpected packages/files'
  Assert-Throws {
    Get-StackchanReleaseToolchainObservedComponents `
      -RootMap $fixtureRoots -Phase PreBuild -Environment stackchan `
      -PlatformKey windows_amd64
  } 'filter is valid only for PostBuild'

  function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& git @Arguments 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
      throw "Fixture Git failed: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return @($output)
  }
  $gitSeed = Join-Path $testRoot 'git-seed'
  $gitFirst = Join-Path $testRoot 'git-first'
  $gitSecond = Join-Path $testRoot 'git-second'
  Invoke-FixtureGit @('init', '--initial-branch=main', $gitSeed) | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'user.name', 'Fixture Builder') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'user.email', 'fixture@example.invalid') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'core.autocrlf', 'false') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $gitSeed 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $gitSeed 'src/source.cpp'), "int fixture = 1;`n")
  [IO.File]::WriteAllText((Join-Path $gitSeed 'builder.py'), "print('fixture')`n")
  Invoke-FixtureGit @('-C', $gitSeed, 'add', '--', 'src/source.cpp', 'builder.py') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'commit', '-m', 'fixture source') | Out-Null
  Invoke-FixtureGit @('clone', '--no-local', $gitSeed, $gitFirst) | Out-Null
  Invoke-FixtureGit @('clone', '--no-local', $gitSeed, $gitSecond) | Out-Null
  $fixtureCommit = (Invoke-FixtureGit @('-C', $gitSeed, 'rev-parse', 'HEAD') | Select-Object -Last 1).Trim()
  $fixtureShortCommit = $fixtureCommit.Substring(0, 7)
  $fixtureUri = "git+https://github.com/fixture/example.git#$fixtureShortCommit"
  $installStamps = @('20260803101010', '20260803111111')
  $cloneNumber = 0
  foreach ($clone in @($gitFirst, $gitSecond)) {
    Invoke-FixtureGit @('-C', $clone, 'remote', 'set-url', 'origin', 'https://github.com/fixture/example.git') | Out-Null
    $metadata = [ordered]@{
      type = 'library'
      name = 'FixtureGitLibrary'
      version = "0.0.0+$($installStamps[$cloneNumber]).sha.$fixtureShortCommit"
      spec = [ordered]@{
        owner = $null
        id = $null
        name = 'FixtureGitLibrary'
        requirements = $null
        uri = $fixtureUri
      }
    }
    [IO.File]::WriteAllText((Join-Path $clone '.git/.piopm'), ($metadata | ConvertTo-Json -Compress -Depth 4))
    $libraryMetadata = [ordered]@{ name = 'FixtureGitLibrary'; version = "0.0.0+$($installStamps[$cloneNumber])" }
    [IO.File]::WriteAllText((Join-Path $clone 'library.json'), ($libraryMetadata | ConvertTo-Json -Depth 2))
    $cloneNumber++
  }
  $gitFirstRecords = Get-StackchanCanonicalGitLibraryRecords `
    -LibraryRoot $gitFirst -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $gitSecondRecords = Get-StackchanCanonicalGitLibraryRecords `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $gitFirstIdentity = Get-StackchanIdentityFromRecords `
    -Records $gitFirstRecords.records -Schema 'stackchan.git-fixture.v1'
  $gitSecondIdentity = Get-StackchanIdentityFromRecords `
    -Records $gitSecondRecords.records -Schema 'stackchan.git-fixture.v1'
  Assert-True ($gitFirstIdentity.treeSha256 -ceq $gitSecondIdentity.treeSha256) `
    'Install timestamps or path/stat-bearing Git metadata changed canonical Git identity.'

  $gitFirstTree = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitFirst -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $sourceBefore = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($gitFirstTree.treeSha256 -ceq $sourceBefore.treeSha256) `
    'Complete canonical Git library identity varies across equivalent installs.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'src/source.cpp'), "int fixture = 2;`n")
  $sourceAfter = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($sourceBefore.treeSha256 -cne $sourceAfter.treeSha256) `
    'Canonical libdeps identity did not bind an actual source-byte mutation.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'src/source.cpp'), "int fixture = 1;`n")
  $builderBefore = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  [IO.File]::WriteAllText((Join-Path $gitSecond 'builder.py'), "print('fixturf')`n")
  $builderAfter = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($builderBefore.treeSha256 -cne $builderAfter.treeSha256) `
    'Canonical libdeps identity did not bind a build-readable builder.py mutation.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'builder.py'), "print('fixture')`n")

  $headPath = Join-Path $gitSecond '.git/HEAD'
  $headBytes = [IO.File]::ReadAllBytes($headPath)
  [IO.File]::WriteAllText($headPath, "ref: refs/heads/unreviewed`n")
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'HEAD ref is missing'
  [IO.File]::WriteAllBytes($headPath, $headBytes)

  $headRefPath = Join-Path $gitSecond '.git/refs/heads/main'
  $headRefBytes = [IO.File]::ReadAllBytes($headRefPath)
  [IO.File]::WriteAllText($headRefPath, (('0' * 40) + "`n"))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'commit does not match reviewed policy'
  [IO.File]::WriteAllBytes($headRefPath, $headRefBytes)

  $wrongCommitFirst = if ($fixtureCommit[0] -ceq '0') { '1' } else { '0' }
  $wrongFullCommit = $wrongCommitFirst + $fixtureCommit.Substring(1)
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $wrongFullCommit
  } 'commit does not match reviewed policy'

  [IO.File]::WriteAllText((Join-Path $gitSecond '.git/hooks/pre-commit'), 'malicious hook')
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Unexpected executable or object Git state'
  Remove-Item -LiteralPath (Join-Path $gitSecond '.git/hooks/pre-commit') -Force

  $configPath = Join-Path $gitSecond '.git/config'
  $configBytes = [IO.File]::ReadAllBytes($configPath)
  [IO.File]::WriteAllText($configPath, ([IO.File]::ReadAllText($configPath) -replace
    'https://github.com/fixture/example.git', 'https://github.com/evil/example.git'))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'remote source does not match reviewed policy'
  [IO.File]::WriteAllBytes($configPath, $configBytes)

  $piopmPath = Join-Path $gitSecond '.git/.piopm'
  $piopmBytes = [IO.File]::ReadAllBytes($piopmPath)
  [IO.File]::WriteAllText($piopmPath, ([IO.File]::ReadAllText($piopmPath) -replace
    [regex]::Escape($fixtureUri), 'git+https://github.com/evil/example.git#0000000'))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Unsafe PlatformIO Git package metadata'
  [IO.File]::WriteAllBytes($piopmPath, $piopmBytes)

  $packPath = @(Get-ChildItem (Join-Path $gitSecond '.git/objects/pack') -Filter '*.pack')[0].FullName
  $packBytes = [IO.File]::ReadAllBytes($packPath)
  $packBytes[20] = $packBytes[20] -bxor 1
  (Get-Item -LiteralPath $packPath).IsReadOnly = $false
  [IO.File]::WriteAllBytes($packPath, $packBytes)
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Git pack (content identity mismatch|object-to-offset mapping verification failed)'

  $requirementsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'requirements-firmware-release.txt'
  $actualRequirements = @(
    Get-Content -LiteralPath $requirementsPath |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') }
  )
  $expectedRequirements = @(
    'ajsonrpc==1.2.0', 'anyio==4.14.1', 'bottle==0.13.4',
    'certifi==2026.6.17', 'charset-normalizer==3.4.7', 'click==8.3.3',
    'colorama==0.4.6', 'h11==0.16.0', 'idna==3.18',
    'marshmallow==3.26.2', 'packaging==26.2', 'platformio==6.1.19',
    'pyelftools==0.33', 'pyserial==3.5', 'requests==2.34.2',
    'semantic-version==2.10.0', 'starlette==0.52.1', 'tabulate==0.10.0',
    'typing-extensions==4.15.0', 'urllib3==2.7.0', 'uvicorn==0.40.0',
    'wsproto==1.3.2'
  )
  Assert-True (($actualRequirements -join "`n") -ceq ($expectedRequirements -join "`n")) `
    'Firmware release Python requirements are not the reviewed exact transitive closure.'

  $helperText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1') -Raw
  foreach ($pattern in @(
      'FileOptions]::SequentialScan', 'StringComparer]::OrdinalIgnoreCase',
      'FileAttributes]::ReparsePoint', 'NormalizationForm]::FormC',
      'candidate-unreviewed', 'refuses a reparse-point root',
      'entire Python installation as one closed root', 'exact-host-installed-bytes',
      'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'python312.zip',
      'portableAcrossHosts', 'verify_git_pack_semantics.py',
      'object-to-offset mapping', 'stackchan.toolchain-lifetime-lease.v1',
      'FileSystemWatcher', 'InternalBufferSize = 65536', 'Register-ObjectEvent',
      'watcher subscription missing', 'VerifyNamespace', 'preBuildVerified',
      '$observedArguments.Environment = $Environment')) {
    Assert-True ($helperText.Contains($pattern)) "Toolchain identity helper missing safety policy: $pattern"
  }
  Assert-True (-not $helperText.Contains('-Environment $Environment -PythonExecutable')) `
    'PreBuild still forwards an empty optional environment into a ValidateSet parameter.'
  $reviewedAllowlistPath = Join-Path $PSScriptRoot 'release_toolchain_identity_allowlist.json'
  $reviewedAllowlist = Get-Content -LiteralPath $reviewedAllowlistPath -Raw | ConvertFrom-Json
  $reviewedHelper = @($reviewedAllowlist.components | Where-Object {
      [string]$_.name -ceq 'release-toolchain-identity-policy-source'
    })
  $helperItem = Get-Item -LiteralPath (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1') -Force
  $helperSha256 = Get-StackchanFileSha256 -LiteralPath $helperItem.FullName
  $helperRecordText = "$script:StackchanToolchainInventorySchema`nF`0$($helperItem.Name)`0$([long]$helperItem.Length)`0$helperSha256`n"
  $helperRecordHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $helperTreeSha256 = ([BitConverter]::ToString($helperRecordHasher.ComputeHash(
          [Text.Encoding]::UTF8.GetBytes($helperRecordText))) -replace '-', '').ToUpperInvariant()
  } finally {
    $helperRecordHasher.Dispose()
  }
  Assert-True ($reviewedHelper.Count -eq 1 -and
      [string]$reviewedHelper[0].treeSha256 -ceq $helperTreeSha256 -and
      [long]$reviewedHelper[0].bytes -eq [long]$helperItem.Length) `
    'Reviewed allowlist does not contain the production leaf identity for the helper source.'
  $candidateText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'new_release_toolchain_identity_candidate.ps1') -Raw
  Assert-True ($candidateText.Contains('refuses to overwrite the reviewed allowlist')) `
    'Allowlist candidate workflow can overwrite reviewed policy without an explicit review step.'
  foreach ($candidateSafety in @(
      'output/private/toolchain-identity-candidates', 'FileMode]::CreateNew',
      'FileShare]::None', 'Candidate output root must be one real private directory')) {
    Assert-True ($candidateText.Contains($candidateSafety)) `
      "Allowlist candidate workflow is missing output safety: $candidateSafety"
  }
  Assert-True (-not $candidateText.Contains('New-StackchanToolchainLeaseState')) `
    'Unreviewed candidate generation unexpectedly acquires release-authorizing lifetime guards.'

  [pscustomobject][ordered]@{
    schema = 'stackchan.release-toolchain-identity-contract.v3'
    status = 'pass'
    fixtureFiles = $firstIdentity.fileCount
    policyComponents = $policy.Count
    pinnedPythonDistributions = $actualRequirements.Count
  } | ConvertTo-Json -Compress
} finally {
  foreach ($name in $isolationEnvironmentNames) {
    [Environment]::SetEnvironmentVariable(
      $name, $savedIsolationEnvironment[$name], [EnvironmentVariableTarget]::Process)
  }
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ($resolvedTestRoot.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        'stackchan-toolchain-identity-contract-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
