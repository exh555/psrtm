# Requires -Version 5.1

# Fileless Assembly Preloading (GAC Assemblies - Zero csc.exe invocations)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Web.Extensions

# Dot-source private scripts
. (Join-Path $PSScriptRoot "Private\ViewModelClasses.ps1")
. (Join-Path $PSScriptRoot "Private\DataCollector.ps1")
. (Join-Path $PSScriptRoot "Private\RunspaceEngine.ps1")

function Start-RemoteProcessManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ComputerName = "localhost",

        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [int]$RefreshIntervalMs = 2000,

        [Parameter(Mandatory = $false)]
        [switch]$Local
    )

    # Determine Local vs Remote Mode
    # Local mode is strictly explicitly requested via -Local switch.
    # Passing -ComputerName (including 'localhost') establishes a WinRM PSSession.
    $isLocalMode = [bool]$Local.IsPresent
    $targetName = if ($isLocalMode) { "Local Host ($env:COMPUTERNAME)" } else { $ComputerName }

    $session = $null
    if (-not $isLocalMode) {
        $sessionParams = @{ ComputerName = $ComputerName }
        if ($Credential) { $sessionParams['Credential'] = $Credential }

        Write-Verbose "Establishing persistent PSSession to $ComputerName..."
        try {
            $session = New-PSSession @sessionParams
        }
        catch {
            $hint = if ($ComputerName -in @('localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)) {
                " `nHint: To manage local processes without WinRM, run with '-Local':`n  Start-RemoteProcessManager -Local`nAlternatively, run PowerShell as Administrator to connect to localhost via WinRM."
            } else { "" }
            throw "Failed to establish PSSession to ${ComputerName}: $_$hint"
        }

        if (-not $session) {
            throw "Failed to establish PSSession to $ComputerName."
        }
    }

    try {
        # Load XAML UIs
        $mainXamlPath = Join-Path $PSScriptRoot "UI\MainWindow.xaml"
        [xml]$mainXaml = Get-Content -Path $mainXamlPath -Raw
        $reader = (New-Object System.Xml.XmlNodeReader $mainXaml)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Locate XAML Elements
        $gridProcesses  = $window.FindName("GridProcesses")
        $treeProcesses  = $window.FindName("TreeProcesses")
        $txtCpuSummary  = $window.FindName("TxtCpuSummary")
        $txtRamSummary  = $window.FindName("TxtRamSummary")
        $txtProcCount   = $window.FindName("TxtProcCount")
        $txtThreadCount = $window.FindName("TxtThreadCount")
        $txtHandleCount = $window.FindName("TxtHandleCount")
        $txtSearch      = $window.FindName("TxtSearch")
        $btnClearSearch = $window.FindName("BtnClearSearch")
        $statusText     = $window.FindName("StatusText")

        # Menu Items
        $menuRefresh    = $window.FindName("MenuRefresh")
        $menuExport     = $window.FindName("MenuExport")
        $menuExit       = $window.FindName("MenuExit")
        $menuViewFlat   = $window.FindName("MenuViewFlat")
        $menuViewTree   = $window.FindName("MenuViewTree")
        $menuRatePaused = $window.FindName("MenuRatePaused")
        $menuRate500ms  = $window.FindName("MenuRate500ms")
        $menuRate1s     = $window.FindName("MenuRate1s")
        $menuRate2s     = $window.FindName("MenuRate2s")
        $menuRate5s     = $window.FindName("MenuRate5s")
        $menuEndProcess = $window.FindName("MenuEndProcess")
        $menuEndTree    = $window.FindName("MenuEndProcessTree")
        $menuProperties = $window.FindName("MenuProperties")

        # Context Menu Items
        $ctxEndProcess  = $window.FindName("CtxEndProcess")
        $ctxEndTree     = $window.FindName("CtxEndTree")
        $ctxProperties  = $window.FindName("CtxProperties")
        $ctxTreeEnd     = $window.FindName("CtxTreeEndProcess")
        $ctxTreeEndTree = $window.FindName("CtxTreeEndTree")
        $ctxTreeProp    = $window.FindName("CtxTreeProperties")

        # Data Contexts & Collections
        $processCollection = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
        $treeCollection    = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
        $servicesCollection= [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
        $summaryVM         = [SystemSummaryViewModel]::new()

        $mainTabControl    = $window.FindName("MainTabControl")
        $gridServices      = $window.FindName("GridServices")
        $txtLogConsole     = $window.FindName("TxtLogConsole")
        $logPane           = $window.FindName("LogPane")
        $menuViewLog       = $window.FindName("MenuViewLog")
        $btnToggleLogPane  = $window.FindName("BtnToggleLogPane")
        $btnShowLog        = $window.FindName("BtnShowLog")
        $btnClearLog       = $window.FindName("BtnClearLog")

        if ($gridProcesses) { $gridProcesses.ItemsSource = $processCollection }
        if ($treeProcesses) { $treeProcesses.ItemsSource = $treeCollection }

        # Structured Console Logger Helper
        $logEvent = {
            param($cat, $msg)
            if ($txtLogConsole) {
                $ts = (Get-Date).ToString("HH:mm:ss.fff")
                $txtLogConsole.AppendText("[$ts] $cat | $msg`r`n")
                if ($txtLogConsole.Text.Length -gt 50000) {
                    $txtLogConsole.Text = $txtLogConsole.Text.Substring(10000)
                }
                $txtLogConsole.ScrollToEnd()
            }
        }

        # Log Console Pane Visibility Toggle
        $toggleLogPane = {
            param($show)
            if ($show -eq $null) {
                $show = ($logPane.Visibility -ne [System.Windows.Visibility]::Visible)
            }
            if ($show) {
                $logPane.Visibility = [System.Windows.Visibility]::Visible
                if ($menuViewLog) { $menuViewLog.IsChecked = $true }
                &$logEvent "USER" "Opened Activity Log Console"
            } else {
                $logPane.Visibility = [System.Windows.Visibility]::Collapsed
                if ($menuViewLog) { $menuViewLog.IsChecked = $false }
            }
        }

        if ($menuViewLog)      { $menuViewLog.add_Click({ &$toggleLogPane $menuViewLog.IsChecked }) }
        if ($btnToggleLogPane) { $btnToggleLogPane.add_Click({ &$toggleLogPane $false }) }
        if ($btnShowLog)       { $btnShowLog.add_Click({ &$toggleLogPane $null }) }
        if ($btnClearLog)      { $btnClearLog.add_Click({ $txtLogConsole.Text = ""; &$logEvent "USER" "Console log cleared" }) }

        # Resolve Services DataGrid ItemsSource lazily when tab content is instantiated by WPF
        $bindServicesGrid = {
            $gSvc = $window.FindName("GridServices")
            if ($gSvc -and -not $gSvc.ItemsSource) {
                $gSvc.ItemsSource = $servicesCollection

                $ctxStart   = $gSvc.FindName("CtxStartService")
                $ctxStop    = $gSvc.FindName("CtxStopService")
                $ctxRestart = $gSvc.FindName("CtxRestartService")

                if ($ctxStart)   { $ctxStart.add_Click({ &$actionControlService "Start" }) }
                if ($ctxStop)    { $ctxStop.add_Click({ &$actionControlService "Stop" }) }
                if ($ctxRestart) { $ctxRestart.add_Click({ &$actionControlService "Restart" }) }
            }
        }

        if ($mainTabControl) {
            $mainTabControl.add_SelectionChanged({ &$bindServicesGrid })
        }
        $window.add_Loaded({
            &$bindServicesGrid
            &$logEvent "SYSTEM" "Connected to target $targetName. Telemetry engine started."
        })

        # Interactive Tree Expander Click Listener
        if ($gridProcesses) {
            $gridProcesses.add_PreviewMouseLeftButtonDown({
                param($sender, $e)
                try {
                    $src = $e.OriginalSource
                    while ($src -and $src -ne $gridProcesses) {
                        if ($src -is [System.Windows.FrameworkElement] -and $src.Name -eq "BtnToggleExpander") {
                            $e.Handled = $true
                            $vm = $src.DataContext
                            if ($vm) {
                                $vm.IsExpanded = -not $vm.IsExpanded
                                if ($engineHandle -and $engineHandle.RefreshTree) {
                                    & $engineHandle.RefreshTree
                                } else {
                                    $cvs.Refresh()
                                }
                                &$logEvent "USER" "Toggled tree expander for '$($vm.Name)' (PID: $($vm.PID)) -> IsExpanded: $($vm.IsExpanded)"
                            }
                            break
                        }
                        if ($src -is [System.Windows.Media.Visual] -or $src -is [System.Windows.Media.Media3D.Visual3D]) {
                            $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src)
                        } else {
                            $src = $null
                        }
                    }
                } catch {}
            })
        }

        # Data Binding for Top Performance Bar
        $summaryBar = $window.FindName("SummaryBar")
        if ($summaryBar) { $summaryBar.DataContext = $summaryVM }

        $statusText.Text = "Connected to $targetName | Refresh Interval: $([Math]::Round($RefreshIntervalMs/1000, 1))s"

        # Search Filter (WPF CollectionViewSource)
        $cvs = [System.Windows.Data.CollectionViewSource]::GetDefaultView($processCollection)
        $filterScriptBlock = {
            param($item)
            try {
                if (-not $txtSearch) { return $true }
                $filterText = $txtSearch.Text
                if ([string]::IsNullOrWhiteSpace($filterText)) { return $true }
                
                $pVm = $item
                if (-not $pVm) { return $true }
                if ($pVm.Name -like "*$filterText*" -or $pVm.PID.ToString() -like "*$filterText*" -or $pVm.User -like "*$filterText*") {
                    return $true
                }
                return $false
            } catch {
                return $true
            }
        }.GetNewClosure()

        $cvs.Filter = [Predicate[Object]]$filterScriptBlock

        $txtSearch.add_TextChanged({ $cvs.Refresh() })
        $btnClearSearch.add_Click({ $txtSearch.Text = ""; $cvs.Refresh() })

        $applySort = {
            param(
                [string]$sortProperty,
                [System.ComponentModel.ListSortDirection]$sortDirection
            )
            $cvs.SortDescriptions.Clear()
            if ($sortProperty) {
                $sortDesc = [System.ComponentModel.SortDescription]::new($sortProperty, $sortDirection)
                $cvs.SortDescriptions.Add($sortDesc)
            }
            if ($cvs -is [System.ComponentModel.ICollectionViewLiveShaping]) {
                try {
                    $cvs.IsLiveSorting = $false
                    $cvs.LiveSortingProperties.Clear()
                } catch {}
            }
            $cvs.Refresh()
        }

        # View Switcher (Flat List vs Tree View via Menu)
        $switchView = {
            param($isTree)
            if ($engineHandle -and $engineHandle.StateContainer) {
                $engineHandle.StateContainer.IsTreeMode = $isTree
            }
            if ($engineHandle -and $engineHandle.RefreshTree) {
                & $engineHandle.RefreshTree
            }
            if ($isTree) {
                $menuViewFlat.IsChecked = $false
                $menuViewTree.IsChecked = $true
                if ($cvs -is [System.ComponentModel.ICollectionViewLiveShaping]) {
                    try { $cvs.IsLiveSorting = $false } catch {}
                }
                $cvs.SortDescriptions.Clear()
                try { $gridProcesses.Items.SortDescriptions.Clear() } catch {}
                foreach ($col in $gridProcesses.Columns) { $col.SortDirection = $null }
                $cvs.Refresh()
                &$logEvent "VIEW" "Switched view mode to Tree View"
            } else {
                $menuViewFlat.IsChecked = $true
                $menuViewTree.IsChecked = $false
                $nameCol = $gridProcesses.Columns | Where-Object { $_.SortMemberPath -eq "Name" }
                if ($nameCol) {
                    foreach ($col in $gridProcesses.Columns) { $col.SortDirection = $null }
                    $nameCol.SortDirection = "Ascending"
                }
                &$applySort "Name" "Ascending"
                &$logEvent "VIEW" "Switched view mode to Flat List"
            }
        }
        $menuViewFlat.add_Click({ &$switchView $false })
        $menuViewTree.add_Click({ &$switchView $true })

        # Standard DataGrid Column Header Sorting (Ascending <-> Descending for all columns)
        $gridProcesses.add_Sorting({
            param($sender, $e)

            $e.Handled = $true
            $column = $e.Column
            $sortPath = $column.SortMemberPath
            if (-not $sortPath) { $sortPath = [string]$column.Header }

            # Switch out of Tree Mode to Flat View when user explicitly clicks a column sort header
            if ($engineHandle -and $engineHandle.StateContainer -and $engineHandle.StateContainer.IsTreeMode) {
                $engineHandle.StateContainer.IsTreeMode = $false
                $menuViewFlat.IsChecked = $true
                $menuViewTree.IsChecked = $false
            }

            $newDir = if ($column.SortDirection -eq [System.ComponentModel.ListSortDirection]::Ascending -or [string]$column.SortDirection -eq "Ascending") {
                "Descending"
            } elseif ($column.SortDirection -eq [System.ComponentModel.ListSortDirection]::Descending -or [string]$column.SortDirection -eq "Descending") {
                "Ascending"
            } else {
                if ($sortPath -in @("CPU", "MemoryBytes", "Threads", "Handles")) {
                    "Descending"
                } else {
                    "Ascending"
                }
            }

            foreach ($col in $gridProcesses.Columns) { $col.SortDirection = $null }

            &$applySort $sortPath $newDir
            $column.SortDirection = $newDir
            &$logEvent "VIEW" "Sorted DataGrid by $sortPath ($newDir)"
        })

        # Start Polling Engine
        $engineHandle = Start-RemoteTaskManagerEngine -PSSession $session `
                                                    -Window $window `
                                                    -ProcessCollection $processCollection `
                                                    -TreeCollection $treeCollection `
                                                    -ServicesCollection $servicesCollection `
                                                    -SummaryViewModel $summaryVM `
                                                    -CollectorScript $script:RemoteCollectorScriptBlock `
                                                    -IntervalMs $RefreshIntervalMs `
                                                    -IsLocal $isLocalMode `
                                                    -LogConsole $txtLogConsole

        # Refresh Interval Rate Selection with Performance Impact Warning
        $updateRate = {
            param($interval, $isPaused, $label, $selectedItem)

            if ($interval -lt 2000 -and -not $isPaused) {
                $warnMsg = "High refresh rate selected ($label).`n`nFast polling (sub-2 second intervals) increases WinRM network bandwidth and host CPU load on target '$targetName'.`n`nAre you sure you want to proceed with $label refresh rate?"
                $confirm = [System.Windows.MessageBox]::Show($window, $warnMsg, "Performance Impact Warning", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
                    return
                }
            }

            $engineHandle.StateContainer.IntervalMs = $interval
            $engineHandle.StateContainer.IsPaused = $isPaused
            $statusText.Text = "Connected to $targetName | Refresh Interval: $label"

            $menuRatePaused.IsChecked = ($selectedItem -eq $menuRatePaused)
            $menuRate500ms.IsChecked  = ($selectedItem -eq $menuRate500ms)
            $menuRate1s.IsChecked     = ($selectedItem -eq $menuRate1s)
            $menuRate2s.IsChecked     = ($selectedItem -eq $menuRate2s)
            $menuRate5s.IsChecked     = ($selectedItem -eq $menuRate5s)
            &$logEvent "RATE" "Updated refresh interval to $label"
        }

        $menuRatePaused.add_Click({ &$updateRate 2000 $true "Paused" $menuRatePaused })
        $menuRate500ms.add_Click({ &$updateRate 500 $false "500ms" $menuRate500ms })
        $menuRate1s.add_Click({ &$updateRate 1000 $false "1s" $menuRate1s })
        $menuRate2s.add_Click({ &$updateRate 2000 $false "2s" $menuRate2s })
        $menuRate5s.add_Click({ &$updateRate 5000 $false "5s" $menuRate5s })

        # Helper: Get Selected Process Item
        $getSelectedVm = {
            return $gridProcesses.SelectedItem
        }

        # Action: End Process
        $actionEndProcess = {
            $selectedVm = &$getSelectedVm
            if (-not $selectedVm) { return }

            $msg = "Are you sure you want to terminate process '$($selectedVm.Name)' (PID: $($selectedVm.PID))?"
            $result = [System.Windows.MessageBox]::Show($window, $msg, "Confirm Process Termination", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)

            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                try {
                    $pidToKill = $selectedVm.PID
                    if ($isLocalMode) {
                        [System.Diagnostics.Process]::GetProcessById($pidToKill).Kill()
                    } else {
                        Invoke-Command -Session $session -ScriptBlock { param($id) [System.Diagnostics.Process]::GetProcessById($id).Kill() } -ArgumentList $pidToKill
                    }
                    &$logEvent "ACTION" "Terminated process '$($selectedVm.Name)' (PID: $pidToKill)"
                } catch {
                    &$logEvent "ERROR" "Failed to terminate process PID $pidToKill : $($_.Exception.Message)"
                    [System.Windows.MessageBox]::Show($window, "Failed to terminate process: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            }
        }

        # Action: End Process Tree
        $actionEndProcessTree = {
            $selectedVm = &$getSelectedVm
            if (-not $selectedVm) { return }

            $msg = "Are you sure you want to terminate process tree for '$($selectedVm.Name)' (PID: $($selectedVm.PID)) and all its descendants?"
            $result = [System.Windows.MessageBox]::Show($window, $msg, "Confirm Process Tree Termination", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)

            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                try {
                    $targetPid = $selectedVm.PID
                    $killScriptBlock = {
                        param($rootPid)
                        $visitedPids = [System.Collections.Generic.HashSet[int]]::new()
                        function Kill-Tree([int]$pidVal) {
                            if ($visitedPids.Contains($pidVal)) { return }
                            [void]$visitedPids.Add($pidVal)
                            $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$pidVal" -ErrorAction SilentlyContinue
                            foreach ($child in $children) {
                                Kill-Tree [int]$child.ProcessId
                            }
                            try { [System.Diagnostics.Process]::GetProcessById($pidVal).Kill() } catch {}
                        }
                        Kill-Tree $rootPid
                    }

                    if ($isLocalMode) {
                        & $killScriptBlock $targetPid
                    } else {
                        Invoke-Command -Session $session -ScriptBlock $killScriptBlock -ArgumentList $targetPid
                    }
                } catch {
                    [System.Windows.MessageBox]::Show($window, "Failed to terminate process tree: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            }
        }

        # Action: Show Properties Dialog
        $actionShowProperties = {
            $selectedVm = &$getSelectedVm
            if (-not $selectedVm) { return }

            $propXamlPath = Join-Path $PSScriptRoot "UI\PropertiesWindow.xaml"
            [xml]$propXaml = Get-Content -Path $propXamlPath -Raw
            $propReader = (New-Object System.Xml.XmlNodeReader $propXaml)
            $propWindow = [Windows.Markup.XamlReader]::Load($propReader)
            $propWindow.Owner = $window

            # Find Controls
            $propHeaderName = $propWindow.FindName("PropHeaderName")
            $propHeaderPid  = $propWindow.FindName("PropHeaderPid")
            $propParentPid  = $propWindow.FindName("PropParentPid")
            $propUser       = $propWindow.FindName("PropUser")
            $propArch       = $propWindow.FindName("PropArch")
            $propStartTime  = $propWindow.FindName("PropStartTime")
            $propPath       = $propWindow.FindName("PropPath")
            $propCmdLine    = $propWindow.FindName("PropCmdLine")
            $propCpu        = $propWindow.FindName("PropCpu")
            $propRam        = $propWindow.FindName("PropRam")
            $propThreadsHnd = $propWindow.FindName("PropThreadsHandles")
            $btnCloseProp   = $propWindow.FindName("BtnCloseProp")
            $btnPropEndProcess = $propWindow.FindName("BtnPropEndProcess")
            $btnPropEndTree    = $propWindow.FindName("BtnPropEndTree")

            # Set Properties
            $propHeaderName.Text = $selectedVm.Name
            $propHeaderPid.Text  = "(PID: $($selectedVm.PID))"
            $propParentPid.Text  = $selectedVm.ParentPID.ToString()
            $propUser.Text       = $selectedVm.User
            $propArch.Text       = $selectedVm.Architecture
            $propStartTime.Text  = $selectedVm.StartTime
            $propPath.Text       = $selectedVm.Path
            $propCmdLine.Text    = $selectedVm.CommandLine
            $propCpu.Text        = $selectedVm.CPUFormatted
            $propRam.Text        = $selectedVm.MemoryFormatted
            $propThreadsHnd.Text = "$($selectedVm.Threads) Threads / $($selectedVm.Handles) Handles"

            # Populate Process Hierarchy Ancestry & Descendant Tree
            $propTree = $propWindow.FindName("PropProcessTree")
            if ($propTree) {
                $treeRoots = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
                $pPid = $selectedVm.ParentPID
                if ($pPid -gt 0 -and $engineHandle -and $engineHandle.ProcessMap -and $engineHandle.ProcessMap.ContainsKey($pPid)) {
                    $parentVm = $engineHandle.ProcessMap[$pPid]
                    $parentVm.IsExpanded = $true
                    $selectedVm.IsExpanded = $true
                    [void]$treeRoots.Add($parentVm)
                } else {
                    $selectedVm.IsExpanded = $true
                    [void]$treeRoots.Add($selectedVm)
                }
                $propTree.ItemsSource = $treeRoots
            }

            # On-Demand Targeted TCP Socket Query for Selected Process PID (Zero Background Overhead)
            $gridNet = $propWindow.FindName("GridNetConnections")
            if ($gridNet) {
                $netCollection = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
                $targetPid = $selectedVm.PID
                $netScriptBlock = {
                    param($pVal)
                    Get-NetTCPConnection -OwningProcess $pVal -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State
                }
                
                try {
                    $rawConns = if ($isLocalMode) {
                        & $netScriptBlock $targetPid
                    } else {
                        Invoke-Command -Session $session -ScriptBlock $netScriptBlock -ArgumentList $targetPid
                    }

                    if ($rawConns) {
                        foreach ($c in $rawConns) {
                            $nVm = [NetworkConnectionViewModel]::new()
                            $nVm.PID = $targetPid
                            $nVm.LocalEndpoint = "$($c.LocalAddress):$($c.LocalPort)"
                            $nVm.RemoteEndpoint = "$($c.RemoteAddress):$($c.RemotePort)"
                            $nVm.State = [string]$c.State
                            [void]$netCollection.Add($nVm)
                        }
                    }
                } catch {}
                $gridNet.ItemsSource = $netCollection
            }

            if ($btnPropEndProcess) {
                $btnPropEndProcess.add_Click({
                    $msg = "Are you sure you want to terminate process '$($selectedVm.Name)' (PID: $($selectedVm.PID))?"
                    $result = [System.Windows.MessageBox]::Show($propWindow, $msg, "Confirm Termination", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                        try {
                            if ($isLocalMode) {
                                [System.Diagnostics.Process]::GetProcessById($selectedVm.PID).Kill()
                            } else {
                                Invoke-Command -Session $session -ScriptBlock { param($id) [System.Diagnostics.Process]::GetProcessById($id).Kill() } -ArgumentList $selectedVm.PID
                            }
                            $propWindow.Close()
                        } catch {
                            [System.Windows.MessageBox]::Show($propWindow, "Failed to terminate process: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                        }
                    }
                })
            }

            if ($btnPropEndTree) {
                $btnPropEndTree.add_Click({
                    $msg = "Are you sure you want to terminate process tree for '$($selectedVm.Name)' (PID: $($selectedVm.PID)) and all its descendants?"
                    $result = [System.Windows.MessageBox]::Show($propWindow, $msg, "Confirm Tree Termination", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                        try {
                            $targetPid = $selectedVm.PID
                            $killScriptBlock = {
                                param($rootPid)
                                $visitedPids = [System.Collections.Generic.HashSet[int]]::new()
                                function Kill-Tree([int]$pidVal) {
                                    if ($visitedPids.Contains($pidVal)) { return }
                                    [void]$visitedPids.Add($pidVal)
                                    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$pidVal" -ErrorAction SilentlyContinue
                                    foreach ($child in $children) { Kill-Tree [int]$child.ProcessId }
                                    try { [System.Diagnostics.Process]::GetProcessById($pidVal).Kill() } catch {}
                                }
                                Kill-Tree $rootPid
                            }
                            if ($isLocalMode) {
                                & $killScriptBlock $targetPid
                            } else {
                                Invoke-Command -Session $session -ScriptBlock $killScriptBlock -ArgumentList $targetPid
                            }
                            $propWindow.Close()
                        } catch {
                            [System.Windows.MessageBox]::Show($propWindow, "Failed to terminate process tree: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                        }
                    }
                })
            }

            $btnCloseProp.add_Click({ $propWindow.Close() })
            [void]$propWindow.ShowDialog()
        }

        # Action: Control Windows Service
        $actionControlService = {
            param($actName)
            $gSvc = $window.FindName("GridServices")
            if (-not $gSvc -or -not $gSvc.SelectedItem) { return }
            $svcVm = $gSvc.SelectedItem
            $svcName = $svcVm.Name

            try {
                if ($isLocalMode) {
                    if ($actName -eq "Start") { Start-Service -Name $svcName }
                    elseif ($actName -eq "Stop") { Stop-Service -Name $svcName -Force }
                    elseif ($actName -eq "Restart") { Restart-Service -Name $svcName -Force }
                } else {
                    if ($actName -eq "Start") { Invoke-Command -Session $session -ScriptBlock { param($n) Start-Service -Name $n } -ArgumentList $svcName }
                    elseif ($actName -eq "Stop") { Invoke-Command -Session $session -ScriptBlock { param($n) Stop-Service -Name $n -Force } -ArgumentList $svcName }
                    elseif ($actName -eq "Restart") { Invoke-Command -Session $session -ScriptBlock { param($n) Restart-Service -Name $n -Force } -ArgumentList $svcName }
                }
                [System.Windows.MessageBox]::Show($window, "Service '$svcName' $actName command executed successfully.", "Service Control", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            } catch {
                [System.Windows.MessageBox]::Show($window, "Failed to $actName service '$svcName': $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }

        # Action: Export CSV
        $actionExportCsv = {
            $saveDialog = New-Object System.Windows.Forms.SaveFileDialog -ErrorAction SilentlyContinue
            if (-not $saveDialog) {
                Add-Type -AssemblyName System.Windows.Forms
                $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
            }
            $saveDialog.Filter = "CSV File (*.csv)|*.csv"
            $saveDialog.FileName = "ProcessList_$($targetName -replace '[^a-zA-Z0-9]','_')_$((Get-Date).ToString('yyyyMMdd_HHmmss')).csv"

            if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $processCollection | Select-Object Name, PID, ParentPID, CPUFormatted, MemoryFormatted, Status, Threads, Handles, User, Path, CommandLine | Export-Csv -Path $saveDialog.FileName -NoTypeInformation
                [System.Windows.MessageBox]::Show($window, "Exported process list to $($saveDialog.FileName)", "Export Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        }

        # Bind Event Handlers
        $gridProcesses.add_MouseDoubleClick({
            param($sender, $e)
            $selectedVm = &$getSelectedVm
            if ($selectedVm) {
                &$actionShowProperties
            }
        })
        if ($menuEndProcess) { $menuEndProcess.add_Click($actionEndProcess) }
        if ($ctxEndProcess)  { $ctxEndProcess.add_Click($actionEndProcess) }
        if ($ctxTreeEnd)     { $ctxTreeEnd.add_Click($actionEndProcess) }

        if ($menuEndTree)    { $menuEndTree.add_Click($actionEndProcessTree) }
        if ($ctxEndTree)     { $ctxEndTree.add_Click($actionEndProcessTree) }
        if ($ctxTreeEndTree) { $ctxTreeEndTree.add_Click($actionEndProcessTree) }

        if ($menuProperties) { $menuProperties.add_Click($actionShowProperties) }
        if ($ctxProperties)  { $ctxProperties.add_Click($actionShowProperties) }
        if ($ctxTreeProp)    { $ctxTreeProp.add_Click($actionShowProperties) }

        $menuExport.add_Click($actionExportCsv)
        $menuRefresh.add_Click({ $cvs.Refresh() })
        $menuExit.add_Click({ $window.Close() })

        # Cleanup on Window Close
        $window.add_Closed({
            if ($engineHandle) {
                if ($engineHandle.Timer) { try { $engineHandle.Timer.Stop() } catch {} }
                try { $engineHandle.PowerShell.Stop() } catch {}
                try { $engineHandle.Runspace.Close() } catch {}
            }
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        })

        # Render WPF Window (Modal)
        [void]$window.ShowDialog()

    } finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Start-RemoteProcessManager
