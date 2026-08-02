# Requires Windows PowerShell 5.1
# Host Synchronization Engine (Background Runspace Pipeline)

function Start-RemoteTaskManagerEngine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession]$PSSession,

        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.ObjectModel.ObservableCollection[Object]]$ProcessCollection,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $false)]
        [System.Collections.ObjectModel.ObservableCollection[Object]]$TreeCollection,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $false)]
        [System.Collections.ObjectModel.ObservableCollection[Object]]$ServicesCollection,

        [Parameter(Mandatory = $true)]
        [Object]$SummaryViewModel,

        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [ScriptBlock]$CollectorScript,

        [Parameter(Mandatory = $false)]
        [int]$IntervalMs = 2000,

        [Parameter(Mandatory = $false)]
        [bool]$IsLocal = $false,

        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [System.Windows.Controls.TextBox]$LogConsole
    )

    if (-not $CollectorScript) {
        $CollectorScript = $script:RemoteCollectorScriptBlock
    }

    if (-not ('ProcessItemViewModel' -as [type])) {
        $vmScriptPath = Join-Path $PSScriptRoot "ViewModelClasses.ps1"
        . $vmScriptPath
    }

    # Shared State container for dynamic interval changes and payload passing
    $stateContainer = [hashtable]::Synchronized(@{
        IntervalMs = $IntervalMs
        IsPaused   = $false
        Payload    = $null
        LastErr    = $null
        IsTreeMode = $false
        LatestNetworkData = $null
    })

    # Create background PowerShell runspace
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    # Pass parameters to background runspace polling script
    [void]$ps.AddScript({
        param(
            $session,
            $stateContainer,
            $collectorScriptBlock,
            $isLocalMode
        )

        while ($true) {
            try {
                if (-not $stateContainer.IsPaused) {
                    $jsonResult = $null
                    if ($isLocalMode) {
                        $jsonResult = & $collectorScriptBlock
                    } else {
                        $jsonResult = Invoke-Command -Session $session -ScriptBlock $collectorScriptBlock
                    }

                    if ($jsonResult) {
                        $stateContainer.Payload = $jsonResult
                    }
                }
            } catch {
                $stateContainer.LastErr = $_.Exception.Message
            }

            $sleepMs = $StateContainer.IntervalMs
            if ($sleepMs -lt 200) { $sleepMs = 200 }
            Start-Sleep -Milliseconds $sleepMs
        }
    })

    [void]$ps.AddArgument($PSSession)
    [void]$ps.AddArgument($stateContainer)
    [void]$ps.AddArgument($CollectorScript)
    [void]$ps.AddArgument($IsLocal)

    $handle = $ps.BeginInvoke()

    # Main-Thread DispatcherTimer for safe, deadlock-free UI updates
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal, $Window.Dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)

    # Local dictionaries & lifecycle counters for UI diffing
    $processMap  = [System.Collections.Generic.Dictionary[int, Object]]::new()
    $servicesMap = [System.Collections.Generic.Dictionary[string, Object]]::new()
    $pidLifeTracker = @{}
    $isInitialLoad = $true

    $tickHandler = {
        $payloadJson = $stateContainer.Payload
        if (-not $payloadJson) { return }
        $stateContainer.Payload = $null # consume payload

        try {
            if ($payloadJson.StartsWith("GZIP:")) {
                $b64 = $payloadJson.Substring(5)
                $compressedBytes = [Convert]::FromBase64String($b64)
                $msIn = [System.IO.MemoryStream]::new($compressedBytes, $false)
                $gsIn = [System.IO.Compression.GZipStream]::new($msIn, [System.IO.Compression.CompressionMode]::Decompress)
                $sr = [System.IO.StreamReader]::new($gsIn, [System.Text.Encoding]::UTF8)
                $payloadJson = $sr.ReadToEnd()
                $sr.Close()
                $gsIn.Close()
                $msIn.Close()
            }
            $data = $payloadJson | ConvertFrom-Json
            if (-not $data) { return }

            # A. Update Top Summary Bar & Sparklines
            if ($data.system) {
                $sys = $data.system
                $SummaryViewModel.UpdateSummary(
                    [double]$sys.cpu,
                    [long]$sys.ramUsed,
                    [long]$sys.ramTotal,
                    [int]$sys.procs,
                    [int]$sys.threads,
                    [int]$sys.handles
                )
            }

            # Record Log Console Telemetry Entry
            if ($LogConsole) {
                $jsonKB = [Math]::Round($payloadJson.Length / 1KB, 1)
                $ts = (Get-Date).ToString("HH:mm:ss.fff")
                $svcCount = if ($data.services) { $data.services.Count } else { 0 }
                $LogConsole.AppendText("[$ts] TELEMETRY | Snapshot Received | JSON Size: ${jsonKB} KB | Procs: $($data.processes.Count) | Svcs: ${svcCount} | CPU: $($data.system.cpu)% | RAM: $($data.system.ramUsed) MB`r`n")
                if ($LogConsole.Text.Length -gt 50000) {
                    $LogConsole.Text = $LogConsole.Text.Substring(10000)
                }
                $LogConsole.ScrollToEnd()
            }

            # Save network data for Properties dialog
            if ($data.network) {
                $stateContainer.LatestNetworkData = $data.network
            }

            # B. Flat DataGrid In-Place Mutation & Heatmap Colors
            $incomingProcs = $data.processes
            $currentPids = [System.Collections.Generic.HashSet[int]]::new()

            foreach ($item in $incomingProcs) {
                $pidVal = [int]$item.id
                [void]$currentPids.Add($pidVal)

                $cpuVal     = [double]$item.c
                $memVal     = [long]$item.m
                $statusVal  = [string]$item.s
                $threadVal  = [int]$item.t
                $handleVal  = [int]$item.h
                $userVal    = [string]$item.u
                $pathVal    = [string]$item.path
                $cmdVal     = [string]$item.cmd
                $startVal   = [string]$item.start
                $archVal    = [string]$item.arch
                $pName      = [string]$item.n
                $parentVal  = [int]$item.p

                # Heatmap background calculation (Initial processes start at 99 so they don't glow green on startup)
                if (-not $pidLifeTracker.ContainsKey($pidVal)) {
                    $pidLifeTracker[$pidVal] = if ($isInitialLoad) { 99 } else { 0 }
                } else {
                    $pidLifeTracker[$pidVal]++
                }
                $lifeTicks = $pidLifeTracker[$pidVal]

                $rowBg = if ($lifeTicks -lt 4) {
                    "#DCFCE7" # Soft Green for New Processes (2s)
                } elseif ($cpuVal -ge 10.0) {
                    "#FEF3C7" # Soft Amber for High CPU
                } else {
                    "#FFFFFF"
                }

                if ($processMap.ContainsKey($pidVal)) {
                    $vm = $processMap[$pidVal]
                    $vm.UpdateData($cpuVal, $memVal, $statusVal, $threadVal, $handleVal, $userVal, $pathVal, $cmdVal, $startVal, $archVal, $rowBg)
                } else {
                    $vm = [ProcessItemViewModel]::new()
                    $vm.PID = $pidVal
                    $vm.Name = $pName
                    $vm.ParentPID = $parentVal
                    $vm.UpdateData($cpuVal, $memVal, $statusVal, $threadVal, $handleVal, $userVal, $pathVal, $cmdVal, $startVal, $archVal, $rowBg)

                    $processMap[$pidVal] = $vm
                    $ProcessCollection.Add($vm)
                }
            }
            $isInitialLoad = $false

            # C. Remove Dead Processes from Flat View
            $deadPids = @($processMap.Keys | Where-Object { -not $currentPids.Contains($_) })
            foreach ($deadPid in $deadPids) {
                $deadVm = $processMap[$deadPid]
                [void]$ProcessCollection.Remove($deadVm)
                [void]$processMap.Remove($deadPid)
                $pidLifeTracker.Remove($deadPid)
            }

            # D. Windows Services Update
            if ($ServicesCollection -and $data.services) {
                $incomingSvcs = $data.services
                $currSvcNames = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($s in $incomingSvcs) {
                    $sName = [string]$s.n
                    [void]$currSvcNames.Add($sName)
                    $sDisp = [string]$s.d
                    $sPid  = [int]$s.p
                    $sSt   = [string]$s.st
                    $sSm   = [string]$s.sm
                    $sUsr  = [string]$s.u

                    if ($servicesMap.ContainsKey($sName)) {
                        $sVm = $servicesMap[$sName]
                        $sVm.UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr)
                    } else {
                        $sVm = [ServiceItemViewModel]::new()
                        $sVm.UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr)
                        $servicesMap[$sName] = $sVm
                        $ServicesCollection.Add($sVm)
                    }
                }
            }

            # E. Tree View Hierarchy Rebuild with Interactive Collapse Filtering
            & $updateViewCollections
        } catch {
            $stateContainer.LastErr = "UI Timer ERR: $_ | $($_.ScriptStackTrace)"
        }
    }.GetNewClosure()

    $updateViewCollections = {
        $isTreeMode = [bool]$stateContainer.IsTreeMode

        $activePids = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($kvp in $processMap.GetEnumerator()) {
            [void]$activePids.Add($kvp.Value.PID)
            $kvp.Value.Children.Clear()
        }

        $roots = [System.Collections.Generic.List[Object]]::new()
        $childrenMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[Object]]]::new()

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $pPid = $vm.ParentPID

            if ($pPid -gt 0 -and $activePids.Contains($pPid) -and $pPid -ne $vm.PID) {
                if (-not $childrenMap.ContainsKey($pPid)) {
                    $childrenMap[$pPid] = [System.Collections.Generic.List[Object]]::new()
                }
                $childrenMap[$pPid].Add($vm)

                $parentVm = $processMap[$pPid]
                [void]$parentVm.Children.Add($vm)
            } else {
                $roots.Add($vm)
            }
        }

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $curr = $vm
            $lvl = 0
            $pathPids = [System.Collections.Generic.HashSet[int]]::new()
            [void]$pathPids.Add($curr.PID)
            while ($curr.ParentPID -gt 0 -and $activePids.Contains($curr.ParentPID) -and $curr.ParentPID -ne $curr.PID -and $lvl -lt 15) {
                if ($pathPids.Contains($curr.ParentPID)) { break }
                $curr = $processMap[$curr.ParentPID]
                [void]$pathPids.Add($curr.PID)
                $lvl++
            }
            $hasChildren = $childrenMap.ContainsKey($vm.PID) -and ($childrenMap[$vm.PID].Count -gt 0)
            $vm.UpdateTreeState($lvl, $isTreeMode, $hasChildren)
        }

        if ($isTreeMode) {
            $cvs = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ProcessCollection)
            if ($cvs -and $cvs.SortDescriptions.Count -gt 0) {
                $cvs.SortDescriptions.Clear()
            }

            $sortedRoots = @($roots | Sort-Object PID)
            $treeList = [System.Collections.Generic.List[Object]]::new()
            $visitedPids = [System.Collections.Generic.HashSet[int]]::new()

            $appendNodeBlock = {
                param($node, $visited)
                if ($visited.Contains($node.PID)) { return }
                [void]$visited.Add($node.PID)
                $treeList.Add($node)
                if ($node.IsExpanded -and $childrenMap.ContainsKey($node.PID)) {
                    $children = @($childrenMap[$node.PID] | Sort-Object PID)
                    foreach ($child in $children) {
                        & $appendNodeBlock $child $visited
                    }
                }
            }

            foreach ($root in $sortedRoots) {
                & $appendNodeBlock $root $visitedPids
            }

            $ProcessCollection.Clear()
            foreach ($item in $treeList) {
                $ProcessCollection.Add($item)
            }
        } else {
            $cvs = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ProcessCollection)
            if ($cvs -and $cvs.SortDescriptions.Count -gt 0) {
                $cvs.Refresh()
            }
        }
    }.GetNewClosure()

    $timer.add_Tick($tickHandler)
    $timer.Start()

    return @{ 
        Runspace       = $rs
        PowerShell     = $ps
        Handle         = $handle
        Timer          = $timer
        StateContainer = $stateContainer
        ProcessMap     = $processMap
        ServicesMap    = $servicesMap
        RefreshTree    = $updateViewCollections
    }
}
