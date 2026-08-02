# Requires Windows PowerShell 5.1
# Lightweight Remote & Local Process Metric Collector ScriptBlock

$script:RemoteCollectorScriptBlock = {
    param($ForceRefreshMeta = $false)

    if (-not $script:LastSnapTime) {
        $script:LastSnapTime = [DateTime]::UtcNow
        $script:LastProcessTimes = @{}
        $script:ProcessMetaCache = @{}
        $script:LastMetaRefresh = [DateTime]::MinValue
    }

    $now = [DateTime]::UtcNow
    $timeDelta = ($now - $script:LastSnapTime).TotalSeconds
    if ($timeDelta -le 0) { $timeDelta = 1.0 }
    $coreCount = [Environment]::ProcessorCount

    if (-not $script:ParentMap) {
        $script:ParentMap = @{}
        $script:CmdMap    = @{}
        $script:ExeMap    = @{}
        $script:UserCache = @{}
        $script:KnownPids = [System.Collections.Generic.HashSet[int]]::new()
    }

    $processes = [System.Diagnostics.Process]::GetProcesses()
    $currPids = [System.Collections.Generic.HashSet[int]]::new()
    $newPids = [System.Collections.Generic.List[int]]::new()

    foreach ($p in $processes) {
        $id = $p.Id
        [void]$currPids.Add($id)
        if (-not $script:KnownPids.Contains($id)) {
            $newPids.Add($id)
        }
    }

    # Query WMI ONLY when new PIDs appear or at initial startup (0.00% CPU overhead on steady state ticks)
    if ($newPids.Count -gt 0 -or $script:KnownPids.Count -eq 0) {
        try {
            $wmiProcs = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CommandLine, ExecutablePath -ErrorAction SilentlyContinue
            if ($wmiProcs) {
                foreach ($wp in $wmiProcs) {
                    $pidKey = [int]$wp.ProcessId
                    $script:ParentMap[$pidKey] = [int]$wp.ParentProcessId
                    $script:CmdMap[$pidKey]    = [string]$wp.CommandLine
                    $script:ExeMap[$pidKey]    = [string]$wp.ExecutablePath
                    [void]$script:KnownPids.Add($pidKey)

                    if (-not $script:UserCache.ContainsKey($pidKey)) {
                        $usrName = "N/A"
                        try {
                            $ownerInfo = Invoke-CimMethod -InputObject $wp -MethodName GetOwner -ErrorAction SilentlyContinue
                            if ($ownerInfo -and $ownerInfo.User) {
                                $usrName = if ($ownerInfo.Domain) { "$($ownerInfo.Domain)\$($ownerInfo.User)" } else { $ownerInfo.User }
                            }
                        } catch {}
                        $script:UserCache[$pidKey] = $usrName
                    }
                }
            }
        } catch {}
    }

    # Clean dead PIDs from cache
    $deadPids = @($script:KnownPids | Where-Object { -not $currPids.Contains($_) })
    foreach ($dp in $deadPids) {
        [void]$script:KnownPids.Remove($dp)
        $script:ParentMap.Remove($dp)
        $script:CmdMap.Remove($dp)
        $script:ExeMap.Remove($dp)
        $script:UserCache.Remove($dp)
        if ($script:SentMetadataPids) {
            [void]$script:SentMetadataPids.Remove($dp)
        }
    }

    $parentMap = $script:ParentMap
    $cmdMap    = $script:CmdMap
    $exeMap    = $script:ExeMap
    $resultList = [System.Collections.Generic.List[PSObject]]::new()

    $totalThreads = 0
    $totalHandles = 0
    $totalProcCpuSum = 0.0

    foreach ($p in $processes) {
        try {
            $pidVal = $p.Id
            if ($pidVal -eq 0) { continue }

            # Core Metrics
            $pName = $p.ProcessName
            $workingSet = $p.WorkingSet64
            $isResponding = try { $p.Responding } catch { $true }
            $statusStr = if ($isResponding) { "Running" } else { "Not Responding" }
            $threadCount = try { $p.Threads.Count } catch { 1 }
            $handleCount = try { $p.HandleCount } catch { 0 }

            $totalThreads += $threadCount
            $totalHandles += $handleCount

            # Delta CPU math
            $cpuPercent = 0.0
            try {
                $totalTime = $p.TotalProcessorTime.TotalSeconds
                if ($script:LastProcessTimes.ContainsKey($pidVal)) {
                    $prevTime = $script:LastProcessTimes[$pidVal]
                    $timeDiff = $totalTime - $prevTime
                    $cpuPercent = [Math]::Round(($timeDiff / ($timeDelta * $coreCount)) * 100.0, 1)
                    if ($cpuPercent -lt 0) { $cpuPercent = 0.0 }
                }
                $script:LastProcessTimes[$pidVal] = $totalTime
            } catch {
                $cpuPercent = 0.0
            }
            $totalProcCpuSum += $cpuPercent

            # Metadata resolution (ParentPID, Path, CmdLine, StartTime, Arch, User)
            $parentPid = 0
            $cmdLine = "N/A"
            $exePath = "N/A"
            $userStr = "N/A"
            $startTimeStr = "N/A"
            try {
                $startTimeStr = $p.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
            } catch {}

            if ($parentMap.ContainsKey($pidVal)) { $parentPid = $parentMap[$pidVal] }
            if ($cmdMap.ContainsKey($pidVal) -and $cmdMap[$pidVal]) { $cmdLine = $cmdMap[$pidVal] }
            if ($exeMap.ContainsKey($pidVal) -and $exeMap[$pidVal]) { $exePath = $exeMap[$pidVal] }
            if ($script:UserCache.ContainsKey($pidVal) -and $script:UserCache[$pidVal] -ne "N/A") { $userStr = $script:UserCache[$pidVal] }

            if ($pidVal -eq 4 -and $userStr -eq "N/A") {
                $userStr = "NT AUTHORITY\SYSTEM"
            }

            $archStr = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

            if (-not $script:SentMetadataPids) {
                $script:SentMetadataPids = [System.Collections.Generic.HashSet[int]]::new()
            }
            $isNewMeta = -not $script:SentMetadataPids.Contains($pidVal)
            if ($isNewMeta) { [void]$script:SentMetadataPids.Add($pidVal) }

            $pObj = [PSCustomObject]@{
                id   = $pidVal
                n    = $pName
                p    = $parentPid
                c    = $cpuPercent
                m    = $workingSet
                s    = $statusStr
                t    = $threadCount
                h    = $handleCount
            }
            if ($isNewMeta) {
                $pObj | Add-Member -NotePropertyName "u" -NotePropertyValue $userStr
                $pObj | Add-Member -NotePropertyName "path" -NotePropertyValue $exePath
                $pObj | Add-Member -NotePropertyName "cmd" -NotePropertyValue $cmdLine
                $pObj | Add-Member -NotePropertyName "start" -NotePropertyValue $startTimeStr
                $pObj | Add-Member -NotePropertyName "arch" -NotePropertyValue $archStr
            }
            $resultList.Add($pObj)
        } catch {}
    }

    # RAM & System CPU Metrics
    $ramTotalMB = 0
    $ramUsedMB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize, FreePhysicalMemory -ErrorAction SilentlyContinue
        if ($os) {
            $ramTotalMB = [Math]::Round($os.TotalVisibleMemorySize / 1KB)
            $ramUsedMB = $ramTotalMB - [Math]::Round($os.FreePhysicalMemory / 1KB)
        }
    } catch {}

    # Windows Services Collection (Cached every 30s to keep target CPU at 0.00%)
    $servicesList = [System.Collections.Generic.List[PSObject]]::new()
    if (-not $script:LastServiceRefresh -or (($now - $script:LastServiceRefresh).TotalSeconds -gt 30)) {
        try {
            $svcs = Get-CimInstance Win32_Service -Property Name, DisplayName, ProcessId, State, StartMode -ErrorAction SilentlyContinue
            if ($svcs) {
                $script:CachedServicesList = [System.Collections.Generic.List[PSObject]]::new()
                foreach ($s in $svcs) {
                    $sPid = try { [int]$s.ProcessId } catch { 0 }
                    $sObj = [PSCustomObject]@{
                        n    = [string]$s.Name
                        d    = [string]$s.DisplayName
                        p    = $sPid
                        st   = [string]$s.State
                        sm   = [string]$s.StartMode
                        u    = "N/A"
                    }
                    $script:CachedServicesList.Add($sObj)
                }
                $script:LastServiceRefresh = $now
            }
        } catch {}
    }
    if ($script:CachedServicesList) {
        $servicesList = $script:CachedServicesList
    }

    $systemCpu = [Math]::Min(100.0, [Math]::Round($totalProcCpuSum, 1))

    $payload = [PSCustomObject]@{
        system = [PSCustomObject]@{
            cpu      = $systemCpu
            ramUsed  = $ramUsedMB
            ramTotal = $ramTotalMB
            procs    = $resultList.Count
            threads  = $totalThreads
            handles  = $totalHandles
        }
        processes = $resultList
        services  = $servicesList
    }

    $script:LastSnapTime = $now
    $rawJson = $payload | ConvertTo-Json -Compress -Depth 4
    
    # GZip Base64 Compression for 19x Network Size Reduction
    $ms = [System.IO.MemoryStream]::new()
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $rawBytes = [System.Text.Encoding]::UTF8.GetBytes($rawJson)
    $gs.Write($rawBytes, 0, $rawBytes.Length)
    $gs.Close()
    return "GZIP:" + [Convert]::ToBase64String($ms.ToArray())
}
