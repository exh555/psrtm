# Remote Process Manager: Technical Specification

## 1. Overview
The **Remote Process Manager** is a high-performance, fileless, enterprise-grade WPF application built entirely in native PowerShell 5.1. It provides real-time monitoring and management of local and remote Windows processes and services without dropping temporary files, invoking `csc.exe`, or triggering Endpoint Detection and Response (EDR) alerts.

---

## 2. Architecture & Components

The application is structured using a strict **Model-View-ViewModel (MVVM)** pattern adapted for pure PowerShell. It decouples the UI rendering thread from the background telemetry polling mechanism, ensuring the interface remains fully responsive.

### 2.1 File Structure
* **`RemoteProcessManager.psd1`**: The module manifest defining the entry point.
* **`RemoteProcessManager.psm1`**: The primary module file containing the `Start-RemoteProcessManager` cmdlet. It loads all private scripts, creates the WPF window from embedded XAML, sets up event handlers, and coordinates the startup sequence.
* **`Private/RunspaceEngine.ps1`**: The heart of the host application. It creates a secondary background runspace (the "Coordinator Runspace"), which establishes a persistent PSSession to the target (or local machine) and dispatches the `DataCollector` payload back to the UI thread using a WPF `DispatcherTimer`.
* **`Private/DataCollector.ps1`**: A pure, uncompiled PowerShell script block that executes exclusively in-memory on the target system. It leverages raw .NET APIs (`System.Diagnostics.Process`, WMI/CIM for services) to gather data extremely fast, calculates CPU/Memory deltas, and streams the output back as GZIP-compressed JSON.
* **`Private/ViewModelClasses.ps1`**: Native PowerShell 5.1 classes implementing `INotifyPropertyChanged`. These represent the state of the processes, services, and system summary, serving as the DataContext for the WPF UI.

---

## 3. Data Flow & Telemetry Engine

### 3.1 Target Polling (`DataCollector.ps1`)
1. **Execution**: The script block is invoked via `Invoke-Command` (or directly `&` in local mode).
2. **Process Snapshot**: It calls `[System.Diagnostics.Process]::GetProcesses()` to instantly capture process states.
3. **Delta Calculation**: It calculates CPU percentage internally using `TotalProcessorTime` deltas between ticks to prevent the host machine from having to process historical performance data.
4. **Compression**: The resultant hashtable (Processes, System Stats, Services) is serialized to JSON, compressed using `[System.IO.Compression.GZipStream]`, converted to a Base64 string, and returned as a single string payload (typically `< 12KB`).

### 3.2 Host Ingestion (`RunspaceEngine.ps1`)
1. **DispatcherTimer Tick**: A `System.Windows.Threading.DispatcherTimer` runs on the UI thread at the specified refresh interval (e.g., 500ms - 2000ms).
2. **Decompression**: The UI thread reads the Base64 string from a thread-safe synchronized hash table (`$stateContainer`), decodes it, and decompresses it back into a PSObject graph.
3. **Smart ViewModel Diffing**:
   - The UI does *not* clear and rebuild the `ObservableCollection`. Doing so would destroy user selection, scroll state, and cause severe flickering.
   - Instead, it maintains a `$processMap` (a Dictionary keyed by PID).
   - For every incoming process, it checks if the PID exists. If yes, it calls `$vm.UpdateData()` to trigger property change notifications (`INotifyPropertyChanged`). If no, it creates a new ViewModel and adds it.
   - Dead processes (PIDs not in the current tick) are explicitly removed from the collection and the dictionary.

---

## 4. UI Implementation (MVVM)

### 4.1 Native Class Generation
The module completely avoids `Add-Type` (which drops C# code to disk and invokes `csc.exe`). Instead, it relies on PowerShell 5.1 `class` definitions for ViewModels. 

### 4.2 Views
- **Flat List (DataGrid)**: Binds to a `CollectionViewSource` supporting `ICollectionViewLiveShaping`. This enables rows to instantly re-sort themselves when CPU or Memory properties change in real-time.
- **Tree View**: In Tree Mode, a recursive algorithm rebuilds the hierarchy. It iterates over `$processMap` to find parent-child relationships, constructs a flattened sorted list reflecting expanded/collapsed states, and applies indentations mathematically using the `DepthLevel` property on the ViewModel.

### 4.3 Interactive Features
- **Heatmap Color Coding**: Processes are color-coded (Red, Orange, Yellow) based on real-time CPU thresholds.
- **Properties Inspector**: A modal window built on demand that provides deep-dive metrics, utilizing `Get-NetTCPConnection` and WMI queries to fetch process ancestry and active network sockets without pausing the main UI telemetry.
- **Remote Service Control**: Full integration with `Start-Service`, `Stop-Service`, and `Restart-Service` executed asynchronously via WinRM to prevent UI locking.

---

## 5. Security & EDR Compliance

* **No Disk Writes**: The application operates entirely in memory. It does not extract binary DLLs or write temporary script blocks to disk.
* **No Child Process Spawning**: By avoiding `Add-Type -TypeDefinition`, the application does not spawn `csc.exe` or `cvtres.exe`, which are common Indicators of Compromise (IoC) monitored by SOCs.
* **Minimal Target Impact**: The remote payload utilizes native .NET classes rather than slow WMI wrappers or CLIXML serialization pipelines, keeping target CPU impact below 0.5% even when polling every 500ms.
