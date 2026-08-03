# Requires Windows PowerShell 5.1
# 100% In-Memory Class Compilation (Zero DLL Writes, Zero csc.exe invocations)

class ProcessItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$PID
    [string]$Name
    [int]$ParentPID
    [double]$CPU
    [string]$CPUFormatted
    [long]$MemoryBytes
    [string]$MemoryFormatted
    [string]$Status
    [string]$User
    [int]$Threads
    [int]$Handles
    [string]$Path
    [string]$CommandLine
    [string]$StartTime
    [string]$Architecture
    [bool]$IsExpanded
    [bool]$IsSelected
    [int]$Level
    [bool]$IsTreeMode
    [double]$IndentWidth
    [string]$TreeVisibility
    [string]$ToggleVisibility
    [string]$LeafVisibility
    [string]$ToggleSymbol
    [string]$RowBackground

    [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]$Children

    # INotifyPropertyChanged Implementation for PS 5.1 Classes
    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ProcessItemViewModel() {
        $this.Children = [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]::new()
        $this.Handlers = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.User = "N/A"
        $this.Path = "N/A"
        $this.CommandLine = "N/A"
        $this.StartTime = "N/A"
        $this.Architecture = "x64"
        $this.CPU = 0.0
        $this.CPUFormatted = "0.0%"
        $this.MemoryBytes = 0
        $this.MemoryFormatted = "0 MB"
        $this.IsExpanded = $true
        $this.Level = 0
        $this.IsTreeMode = $false
        $this.IndentWidth = 0.0
        $this.TreeVisibility = "Collapsed"
        $this.ToggleVisibility = "Collapsed"
        $this.LeafVisibility = "Collapsed"
        $this.ToggleSymbol = "[-]"
        $this.RowBackground = "#FFFFFF"
    }

    [void] UpdateTreeState([int]$level, [bool]$isTreeMode, [bool]$hasChildren) {
        $this.Level = $level
        $this.IsTreeMode = $isTreeMode
        $this.IndentWidth = if ($isTreeMode) { [double]($level * 18) } else { 0.0 }

        if ($isTreeMode) {
            if ($hasChildren) {
                $this.ToggleVisibility = "Visible"
                $this.LeafVisibility = "Collapsed"
            } elseif ($level -gt 0) {
                $this.ToggleVisibility = "Collapsed"
                $this.LeafVisibility = "Visible"
            } else {
                $this.ToggleVisibility = "Collapsed"
                $this.LeafVisibility = "Collapsed"
            }
        } else {
            $this.ToggleVisibility = "Collapsed"
            $this.LeafVisibility = "Collapsed"
        }

        $this.ToggleSymbol = if ($this.IsExpanded) { "[-]" } else { "[+]" }

        $this.OnPropertyChanged('Level')
        $this.OnPropertyChanged('IsTreeMode')
        $this.OnPropertyChanged('IndentWidth')
        $this.OnPropertyChanged('ToggleVisibility')
        $this.OnPropertyChanged('LeafVisibility')
        $this.OnPropertyChanged('ToggleSymbol')
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        foreach ($h in $this.Handlers) {
            try { $h.Invoke($this, $eventArgs) } catch {}
        }
    }

    # In-place Data Mutation with Change Notifications
    [void] UpdateData(
        [double]$cpu,
        [long]$memory,
        [string]$status,
        [int]$threads,
        [int]$handles,
        [string]$user,
        [string]$path,
        [string]$cmdLine,
        [string]$startTime,
        [string]$arch,
        [string]$rowBg
    ) {
        $this.CPU = $cpu
        $this.CPUFormatted = "$($this.CPU.ToString('F1'))%"
        $this.MemoryBytes = $memory
        $mb = [Math]::Round($this.MemoryBytes / 1MB)
        $this.MemoryFormatted = "$mb MB"
        $this.Status = $status
        $this.Threads = $threads
        $this.Handles = $handles
        if (-not [string]::IsNullOrEmpty($rowBg)) { $this.RowBackground = $rowBg }

        if (-not [string]::IsNullOrEmpty($user) -and $user -ne "N/A") { $this.User = $user }
        if (-not [string]::IsNullOrEmpty($path) -and $path -ne "N/A") { $this.Path = $path }
        if (-not [string]::IsNullOrEmpty($cmdLine) -and $cmdLine -ne "N/A") { $this.CommandLine = $cmdLine }
        if (-not [string]::IsNullOrEmpty($startTime) -and $startTime -ne "N/A") { $this.StartTime = $startTime }
        if (-not [string]::IsNullOrEmpty($arch)) { $this.Architecture = $arch }

        $this.OnPropertyChanged('CPU')
        $this.OnPropertyChanged('CPUFormatted')
        $this.OnPropertyChanged('MemoryBytes')
        $this.OnPropertyChanged('MemoryFormatted')
        $this.OnPropertyChanged('Status')
        $this.OnPropertyChanged('Threads')
        $this.OnPropertyChanged('Handles')
        $this.OnPropertyChanged('User')
        $this.OnPropertyChanged('Path')
        $this.OnPropertyChanged('CommandLine')
        $this.OnPropertyChanged('StartTime')
        $this.OnPropertyChanged('Architecture')
        $this.OnPropertyChanged('RowBackground')
    }
}

class ServiceItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [string]$Name
    [string]$DisplayName
    [int]$PID
    [string]$Status
    [string]$StartType
    [string]$User
    [string]$StatusBrush

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ServiceItemViewModel() {
        $this.Handlers = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.Status = "Stopped"
        $this.StatusBrush = "#64748B"
        $this.StartType = "Manual"
        $this.User = "N/A"
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        foreach ($h in $this.Handlers) {
            try { $h.Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateService([string]$name, [string]$disp, [int]$pidVal, [string]$status, [string]$startType, [string]$user) {
        $this.Name = $name
        $this.DisplayName = $disp
        $this.PID = $pidVal
        $this.Status = $status
        $this.StartType = $startType
        $this.User = $user
        $this.StatusBrush = if ($status -eq "Running") { "#16A34A" } else { "#64748B" }

        $this.OnPropertyChanged('Name')
        $this.OnPropertyChanged('DisplayName')
        $this.OnPropertyChanged('PID')
        $this.OnPropertyChanged('Status')
        $this.OnPropertyChanged('StartType')
        $this.OnPropertyChanged('User')
        $this.OnPropertyChanged('StatusBrush')
    }
}

class NetworkConnectionViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$PID
    [string]$Protocol
    [string]$LocalEndpoint
    [string]$RemoteEndpoint
    [string]$State
    [string]$StateBrush

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    NetworkConnectionViewModel() {
        $this.Handlers = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.Protocol = "TCP"
        $this.State = "ESTABLISHED"
        $this.StateBrush = "#16A34A"
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        foreach ($h in $this.Handlers) {
            try { $h.Invoke($this, $eventArgs) } catch {}
        }
    }
}

class SystemSummaryViewModel : System.ComponentModel.INotifyPropertyChanged {
    [double]$CpuUsage
    [string]$CpuSummaryFormatted
    [long]$RamUsedMB
    [long]$RamTotalMB
    [string]$RamSummaryFormatted
    [int]$ProcessCount
    [int]$ThreadCount
    [int]$HandleCount
    [string]$CpuPoints
    [string]$RamPoints

    hidden [System.Collections.Generic.Queue[double]] $CpuHistory
    hidden [System.Collections.Generic.Queue[double]] $RamHistory
    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    SystemSummaryViewModel() {
        $this.Handlers = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.CpuHistory = [System.Collections.Generic.Queue[double]]::new()
        $this.RamHistory = [System.Collections.Generic.Queue[double]]::new()
        $this.CpuUsage = 0.0
        $this.CpuSummaryFormatted = "0.0%"
        $this.RamUsedMB = 0
        $this.RamTotalMB = 0
        $this.RamSummaryFormatted = "0 / 0 MB"
        $this.ProcessCount = 0
        $this.ThreadCount = 0
        $this.HandleCount = 0
        $this.CpuPoints = "0,22 88,22"
        $this.RamPoints = "0,22 88,22"

        for ($i = 0; $i -lt 30; $i++) {
            $this.CpuHistory.Enqueue(0.0)
            $this.RamHistory.Enqueue(0.0)
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        foreach ($h in $this.Handlers) {
            try { $h.Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateSummary([double]$cpu, [long]$ramUsed, [long]$ramTotal, [int]$procs, [int]$threads, [int]$handles) {
        $this.CpuUsage = $cpu
        $this.CpuSummaryFormatted = "$($this.CpuUsage.ToString('F1'))%"
        $this.RamUsedMB = $ramUsed
        $this.RamTotalMB = $ramTotal
        $this.RamSummaryFormatted = "$($this.RamUsedMB) / $($this.RamTotalMB) MB"
        $this.ProcessCount = $procs
        $this.ThreadCount = $threads
        $this.HandleCount = $handles

        # Update History Queues
        if ($this.CpuHistory.Count -ge 30) { [void]$this.CpuHistory.Dequeue() }
        $this.CpuHistory.Enqueue($cpu)

        $ramPct = if ($ramTotal -gt 0) { ($ramUsed / $ramTotal) * 100.0 } else { 0.0 }
        if ($this.RamHistory.Count -ge 30) { [void]$this.RamHistory.Dequeue() }
        $this.RamHistory.Enqueue($ramPct)

        # Build Sparkline Polyline Points (90x24 Canvas)
        $cpuArr = $this.CpuHistory.ToArray()
        $ramArr = $this.RamHistory.ToArray()
        $cSb = [System.Text.StringBuilder]::new()
        $rSb = [System.Text.StringBuilder]::new()

        for ($i = 0; $i -lt $cpuArr.Count; $i++) {
            $x = [Math]::Round(($i / 29.0) * 88.0, 1)
            $yCpu = 22.0 - (($cpuArr[$i] / 100.0) * 20.0)
            if ($yCpu -lt 2.0) { $yCpu = 2.0 }
            if ($yCpu -gt 22.0) { $yCpu = 22.0 }

            $yRam = 22.0 - (($ramArr[$i] / 100.0) * 20.0)
            if ($yRam -lt 2.0) { $yRam = 2.0 }
            if ($yRam -gt 22.0) { $yRam = 22.0 }

            [void]$cSb.Append("$x,$yCpu ")
            [void]$rSb.Append("$x,$yRam ")
        }
        $this.CpuPoints = $cSb.ToString().Trim()
        $this.RamPoints = $rSb.ToString().Trim()

        $this.OnPropertyChanged('CpuUsage')
        $this.OnPropertyChanged('CpuSummaryFormatted')
        $this.OnPropertyChanged('RamUsedMB')
        $this.OnPropertyChanged('RamTotalMB')
        $this.OnPropertyChanged('RamSummaryFormatted')
        $this.OnPropertyChanged('ProcessCount')
        $this.OnPropertyChanged('ThreadCount')
        $this.OnPropertyChanged('HandleCount')
        $this.OnPropertyChanged('CpuPoints')
        $this.OnPropertyChanged('RamPoints')
    }
}
