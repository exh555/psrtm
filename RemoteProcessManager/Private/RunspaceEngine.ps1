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

    # Create background PowerShell runspace with default cmdlet session state (CimCmdlets, Utility, etc.)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $collectorCode = $CollectorScript.ToString()

    # Pass parameters to background runspace polling script
    [void]$ps.AddScript({
        param(
            $session,
            $stateContainer,
            $collectorScriptText,
            $isLocalMode
        )

        $collectorSb = [scriptblock]::Create($collectorScriptText)

        while ($true) {
            try {
                if (-not $stateContainer.IsPaused) {
                    $jsonResult = $null
                    if ($isLocalMode) {
                        $jsonResult = & $collectorSb
                    } else {
                        $jsonResult = Invoke-Command -Session $session -ScriptBlock $collectorSb
                    }

                    if ($jsonResult) {
                        $stateContainer.Payload = $jsonResult
                    }
                }
            } catch {
                $stateContainer.LastErr = $_.Exception.Message
            }

            $sleepMs = $stateContainer.IntervalMs
            if ($sleepMs -lt 200) { $sleepMs = 200 }
            [System.Threading.Thread]::Sleep($sleepMs)
        }
    })

    [void]$ps.AddArgument($PSSession)
    [void]$ps.AddArgument($stateContainer)
    [void]$ps.AddArgument($collectorCode)
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

            $needsUpdate = $false
            if ($ProcessCollection.Count -ne $treeList.Count) {
                $needsUpdate = $true
            } else {
                for ($i = 0; $i -lt $treeList.Count; $i++) {
                    if ($ProcessCollection[$i] -ne $treeList[$i]) {
                        $needsUpdate = $true
                        break
                    }
                }
            }

            if ($needsUpdate) {
                $ProcessCollection.Clear()
                foreach ($item in $treeList) {
                    $ProcessCollection.Add($item)
                }
            }
        } else {
            if ($ProcessCollection.Count -ne $processMap.Count) {
                $cvs = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ProcessCollection)
                $wasLive = $false
                if ($cvs -is [System.ComponentModel.ICollectionViewLiveShaping] -and $cvs.IsLiveSorting) {
                    $wasLive = $true
                    try { $cvs.IsLiveSorting = $false } catch {}
                }

                foreach ($kvp in $processMap.GetEnumerator()) {
                    if (-not $ProcessCollection.Contains($kvp.Value)) {
                        $ProcessCollection.Add($kvp.Value)
                    }
                }

                if ($wasLive) {
                    try { $cvs.IsLiveSorting = $true } catch {}
                }
            }

            $cvs = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ProcessCollection)
            if ($cvs -and $cvs.SortDescriptions.Count -gt 0) {
                if ($cvs -is [System.ComponentModel.ICollectionViewLiveShaping]) {
                    try { $cvs.IsLiveSorting = $false } catch {}
                }
                $cvs.Refresh()
            }
        }
    }.GetNewClosure()

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

            $currentPids = [System.Collections.Generic.HashSet[int]]::new()
            $currentMap = @{}

            # B. Flat DataGrid In-Place Mutation & Heatmap Colors
            foreach ($item in $data.processes) {
                $pidVal = [int]$item.id
                [void]$currentPids.Add($pidVal)
                $currentMap[$pidVal] = $item

                $cpuVal = [double]$item.c
                $rowBg = "Transparent"
                if ($cpuVal -gt 50.0) { $rowBg = "#44ff0000" }
                elseif ($cpuVal -gt 25.0) { $rowBg = "#44ff8800" }
                elseif ($cpuVal -gt 10.0) { $rowBg = "#44ffff00" }

                $memVal = [long]$item.m

                if (-not $processMap.ContainsKey($pidVal)) {
                    $vm = [ProcessItemViewModel]::new()
                    $vm.PID = $pidVal
                    $vm.Name = $item.n
                    $vm.ParentPID = [int]$item.p
                    $vm.UpdateData($cpuVal, $memVal, $item.s, $item.t, $item.h, $item.u, $item.path, $item.cmd, $item.start, $item.arch, $rowBg)
                    $processMap[$pidVal] = $vm
                    $pidLifeTracker[$pidVal] = 0
                } else {
                    $vm = $processMap[$pidVal]
                    $vm.UpdateData($cpuVal, $memVal, $item.s, $item.t, $item.h, $item.u, $item.path, $item.cmd, $item.start, $item.arch, $rowBg)
                }
            }

            # C. Remove Dead Processes from Flat View
            $deadPids = @($processMap.Keys | Where-Object { -not $currentPids.Contains($_) })
            foreach ($deadPid in $deadPids) {
                $deadVm = $processMap[$deadPid]
                while ($ProcessCollection.Contains($deadVm)) {
                    [void]$ProcessCollection.Remove($deadVm)
                }
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
            $isInitialLoad = ($ProcessCollection.Count -eq 0 -and $isTreeMode -eq $false)
            if ($isInitialLoad) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            & $updateViewCollections
        } catch {
            $stateContainer.LastErr = "UI Timer ERR: $_ | $($_.ScriptStackTrace)"
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
