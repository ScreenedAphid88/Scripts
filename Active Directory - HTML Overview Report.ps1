#Requires -Version 5.1
<#
.SYNOPSIS
Creates a self-contained Active Directory HTML health report.
.DESCRIPTION
Requires Windows PowerShell 5.1 or PowerShell 7 on Windows, the RSAT
ActiveDirectory module, and permission to read the directory. Disk checks use
authenticated WSMan CIM sessions; configure remote access without disabling
authentication or certificate validation. Collection runs in isolated,
throttled jobs with configurable deadlines.
.EXAMPLE
& ".\Active Directory - HTML Overview Report.ps1" -OpenReport
.EXAMPLE
& ".\Active Directory - HTML Overview Report.ps1" -DiagnosticsLevel Full `
    -DiagnosticsTimeoutSeconds 1800
.EXAMPLE
& ".\Active Directory - HTML Overview Report.ps1" -Server DC01.contoso.com `
    -RedactSensitiveData -ProtectOutput -DiagnosticsLevel None -Verbose
.NOTES
Quick diagnostics are the default and target the selected domain controller.
Full diagnostics are opt-in, enterprise-wide, and may need a longer
DiagnosticsTimeoutSeconds. Raw diagnostic/error details and creator
identity are opt-in. Redaction is best-effort, not a substitute for reviewing
the report before sharing it. Existing reports require -Force to overwrite.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Domain,
    [ValidateNotNullOrEmpty()]
    [string]$Server,
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot ("AD-Environment-Overview-{0}.html" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [switch]$OpenReport,
    [ValidateRange(1, 16)]
    [int]$ThrottleLimit = 4,
    [ValidateRange(5, 3600)]
    [int]$OperationTimeoutSeconds = 60,
    [ValidateRange(5, 7200)]
    [int]$DiagnosticsTimeoutSeconds = 300,
    [ValidateSet("None", "Quick", "Full")]
    [string]$DiagnosticsLevel = "Quick",
    [switch]$RedactSensitiveData,
    [switch]$IncludeDiagnosticDetails,
    [switch]$IncludeCreatorIdentity,
    [switch]$ProtectOutput,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$reportStarted = Get-Date
$redactionValues = @()
$collectionWarnings = [System.Collections.Generic.List[object]]::new()
$collectionOptions = @{ Limit = $ThrottleLimit; TimeoutSeconds = $OperationTimeoutSeconds }

function Protect-ReportText {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    if ($RedactSensitiveData) {
        foreach ($item in $redactionValues) {
            $text = [regex]::Replace($text, [regex]::Escape($item), "[redacted]", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        $text = [regex]::Replace($text, "\b(?:\d{1,3}\.){3}\d{1,3}\b", "[IP redacted]")
    }
    return $text
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode((Protect-ReportText $Value))
}

function Add-CollectionWarning {
    param([string]$Target, [string]$Check, [string]$Message)

    $collectionWarnings.Add([pscustomobject]@{ Target = $Target; Check = $Check; Message = $Message })
    Write-Warning (Protect-ReportText "$Target - ${Check}: $Message")
}

function Invoke-CollectionBatch {
    param(
        [object[]]$Tasks,
        [scriptblock]$Worker,
        [string]$Phase,
        [int]$PercentComplete,
        [int]$Limit,
        [int]$TimeoutSeconds
    )

    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($task in $Tasks) { $pending.Enqueue($task) }
    $active = [System.Collections.Generic.List[object]]::new()
    $completed = 0
    try {
        while ($pending.Count -gt 0 -or $active.Count -gt 0) {
            while ($pending.Count -gt 0 -and $active.Count -lt $Limit) {
                $task = $pending.Dequeue()
                Write-Verbose "$Phase - starting $($task.Name)"
                $job = Start-Job -ScriptBlock $Worker -ArgumentList $task, $TimeoutSeconds
                $active.Add([pscustomobject]@{ Task = $task; Job = $job; Started = Get-Date })
            }
            Write-Progress -Id 1 -Activity "Creating Active Directory report" -Status "$Phase ($completed of $($Tasks.Count) checks complete)" -PercentComplete $PercentComplete
            Write-Progress -Id 2 -ParentId 1 -Activity $Phase -Status (($active | ForEach-Object { $_.Task.Name }) -join ", ") -PercentComplete ([int](100 * $completed / $Tasks.Count))
            foreach ($entry in @($active.ToArray())) {
                $expired = ((Get-Date) - $entry.Started).TotalSeconds -ge $TimeoutSeconds
                if ($entry.Job.State -in @("Completed", "Failed", "Stopped") -or $expired) {
                    $value = $null
                    $failure = $null
                    if ($entry.Job.State -eq "Completed") {
                        try {
                            $value = Receive-Job -Job $entry.Job -ErrorAction Stop
                        }
                        catch {
                            $failure = $_.Exception.Message
                        }
                    }
                    elseif ($expired) {
                        $failure = "Collection exceeded the $TimeoutSeconds second deadline."
                    }
                    else {
                        $failure = "Collection job ended in state $($entry.Job.State). $($entry.Job.ChildJobs[0].JobStateInfo.Reason)"
                    }
                    if ($failure) {
                        Add-CollectionWarning -Target $entry.Task.Name -Check $Phase -Message $failure
                    }
                    [pscustomobject]@{ Task = $entry.Task; Value = $value; Error = $failure }
                    Remove-Job -Job $entry.Job -Force
                    $active.Remove($entry) | Out-Null
                    $completed++
                }
            }
            if ($active.Count -gt 0) { Start-Sleep -Milliseconds 200 }
        }
    }
    finally {
        foreach ($entry in $active) { Remove-Job -Job $entry.Job -Force }
        Write-Progress -Id 2 -Activity $Phase -Completed
    }
}

function Invoke-NativeDiagnostic {
    param([string]$ExecutableName, [string[]]$Arguments, [int]$TimeoutSeconds)

    $result = [ordered]@{ Output = ""; ExitCode = $null; Error = $null }
    $process = $null
    $processStarted = $false
    try {
        $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            $systemDirectory = Join-Path $env:SystemRoot "Sysnative"
        }
        $executablePath = Join-Path $systemDirectory $ExecutableName
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            throw "$ExecutableName is not installed at its expected system location."
        }
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $executablePath
        # Arguments are assembled internally, never accepted as free-form command text.
        $startInfo.Arguments = $Arguments -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $process.Start() | Out-Null
        $processStarted = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(200)) {
            Write-Progress -Id 1 -Activity "Creating Active Directory report" -Status "Running $ExecutableName ($([int]$timer.Elapsed.TotalSeconds)s elapsed)" -PercentComplete 80
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "$ExecutableName exceeded the $TimeoutSeconds second deadline."
            }
        }
        $remainingMilliseconds = [math]::Max(0, [int](($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000))
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdout, $stderr), $remainingMilliseconds)) {
            throw "$ExecutableName output capture exceeded the $TimeoutSeconds second deadline."
        }
        $result.ExitCode = $process.ExitCode
        $result.Output = ($stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()).Trim()
    }
    catch {
        $result.Error = $_.Exception.Message
        Add-CollectionWarning -Target $ExecutableName -Check "Diagnostics" -Message $result.Error
    }
    finally {
        if ($null -ne $process) {
            try {
                if ($processStarted -and -not $process.HasExited) {
                    $process.Kill()
                    if (-not $process.WaitForExit(5000)) { throw "Unable to confirm that $ExecutableName stopped." }
                }
            }
            finally { $process.Dispose() }
        }
    }
    return [pscustomobject]$result
}

function Get-HealthClass {
    param(
        [bool]$IsHealthy,
        [bool]$IsUnknown = $false
    )

    if ($IsUnknown) {
        return "warning"
    }

    if ($IsHealthy) {
        return "success"
    }

    return "danger"
}

function Get-StatusText {
    param(
        [bool]$IsHealthy,
        [bool]$IsUnknown = $false,
        [string]$HealthyText = "Healthy",
        [string]$UnhealthyText = "Attention required",
        [string]$UnknownText = "Unavailable"
    )

    if ($IsUnknown) {
        return $UnknownText
    }

    if ($IsHealthy) {
        return $HealthyText
    }

    return $UnhealthyText
}

if ($env:OS -ne "Windows_NT") { throw "This report requires Windows and RSAT." }
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($resolvedOutputPath) -notin @(".html", ".htm")) {
    throw "OutputPath must end in .html or .htm."
}
if (Test-Path -LiteralPath $resolvedOutputPath -PathType Container) {
    throw "OutputPath must identify a file, not a directory."
}
if ((Test-Path -LiteralPath $resolvedOutputPath) -and -not $Force) {
    throw "The report already exists. Use -Force to replace it."
}
if ($resolvedOutputPath.StartsWith("\\")) {
    Write-Warning "The output is on a network share. Confirm its access controls before saving sensitive infrastructure information."
}
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$collectionWorker = {
    param($Task, $TimeoutSeconds)
    $ErrorActionPreference = "Stop"
    if ($Task.Kind -in @("Inventory", "Status", "Users")) {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    switch ($Task.Kind) {
        "Inventory" {
            $parameters = @{ ErrorAction = "Stop" }
            if ($Task.Domain) { $parameters.Identity = $Task.Domain }
            if ($Task.Server) { $parameters.Server = $Task.Server }
            $domainInfo = Get-ADDomain @parameters
            $targetServer = if ($Task.Server) { $Task.Server } else { $domainInfo.PDCEmulator }
            $root = Get-ADRootDSE -Server $targetServer -ErrorAction Stop
            if ($root.defaultNamingContext -ne $domainInfo.DistinguishedName) {
                throw "The selected server does not serve the requested domain."
            }
            [pscustomobject]@{
                Domain = $domainInfo
                Server = $targetServer
                Root = $root
                Forest = Get-ADForest -Identity $domainInfo.Forest -Server $targetServer -ErrorAction Stop
                Controllers = @(Get-ADDomainController -Filter * -Server $targetServer -ErrorAction Stop |
                    Sort-Object Name | Select-Object Name, HostName, IPv4Address, Site, OperatingSystem, IsGlobalCatalog)
            }
        }
        "Users" {
            (Get-ADUser -Filter * -SearchBase $Task.SearchBase -SearchScope Subtree -Server $Task.Server -ResultSetSize $null -ErrorAction Stop |
                Measure-Object).Count
        }
        "Status" {
            $root = Get-ADRootDSE -Properties currentTime, isGlobalCatalogReady, isSynchronized -Server $Task.Server -ErrorAction Stop
            $health = @{}
            foreach ($property in @("isGlobalCatalogReady", "isSynchronized")) {
                $values = @($root.$property)
                if ($values.Count -ne 1 -or $null -eq $values[0]) {
                    throw "RootDSE property $property must contain exactly one Boolean value."
                }
                $health[$property] = [System.Convert]::ToBoolean($values[0])
            }
            [pscustomobject]@{
                CurrentTime = $root.currentTime
                Ready = $health.isGlobalCatalogReady
                Synchronized = $health.isSynchronized
            }
        }
        "Disks" {
            $session = $null
            try {
                $options = New-CimSessionOption -Protocol Wsman
                $session = New-CimSession -ComputerName $Task.Server -SessionOption $options -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop
                Get-CimInstance -ClassName Win32_LogicalDisk -CimSession $session -Filter "DriveType=3" -Property DeviceID, Size, FreeSpace -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop |
                    ForEach-Object {
                        if ($_.Size -le 0 -or $_.FreeSpace -lt 0 -or $_.FreeSpace -gt $_.Size) {
                            throw "Disk $($_.DeviceID) has an invalid capacity."
                        }
                        [pscustomobject]@{
                            DeviceId = $_.DeviceID
                            SizeGb = [math]::Round($_.Size / 1GB, 1)
                            FreeGb = [math]::Round($_.FreeSpace / 1GB, 1)
                            FreePercent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
                        }
                    }
            }
            finally {
                if ($null -ne $session) { Remove-CimSession -CimSession $session -ErrorAction Stop }
            }
        }
    }
}

try {
Write-Information "Starting Active Directory report collection." -InformationAction Continue
$inventoryTask = [pscustomobject]@{ Kind = "Inventory"; Name = "Domain and forest inventory"; Domain = $Domain; Server = $Server }
$inventory = Invoke-CollectionBatch -Tasks @($inventoryTask) -Worker $collectionWorker -Phase "Reading directory configuration" -PercentComplete 5 @collectionOptions
if ($inventory.Error -or $null -eq $inventory.Value) { throw "Directory inventory failed. Verify RSAT, domain access, and the collection deadline. $($inventory.Error)" }
$domainInfo = $inventory.Value.Domain
$rootDse = $inventory.Value.Root
$forestInfo = $inventory.Value.Forest
$targetServer = $inventory.Value.Server
$domainControllers = @($inventory.Value.Controllers)
if ($domainControllers.Count -eq 0) { throw "No domain controllers were returned for the selected domain." }

$redactionValues = @(
    $domainInfo.DNSRoot; $domainInfo.NetBIOSName; $domainInfo.Forest
    $domainInfo.DistinguishedName; $env:USERNAME; $env:COMPUTERNAME; $targetServer
    $forestInfo.SchemaMaster; $forestInfo.DomainNamingMaster
    $domainInfo.PDCEmulator; $domainInfo.RIDMaster; $domainInfo.InfrastructureMaster
    $forestInfo.GlobalCatalogs
    foreach ($dc in $domainControllers) { $dc.HostName; $dc.Name; $dc.IPv4Address; $dc.Site }
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique | Sort-Object { $_.Length } -Descending

$userTask = [pscustomobject]@{ Kind = "Users"; Name = "User count"; SearchBase = $domainInfo.DistinguishedName; Server = $targetServer }
$tasks = @(
    $userTask
    foreach ($dc in $domainControllers) {
        [pscustomobject]@{ Kind = "Status"; Name = "$($dc.Name) directory health"; Server = $dc.HostName }
        [pscustomobject]@{ Kind = "Disks"; Name = "$($dc.Name) disk capacity"; Server = $dc.HostName }
    }
)
$checks = @(Invoke-CollectionBatch -Tasks $tasks -Worker $collectionWorker -Phase "Counting users and checking domain controllers" -PercentComplete 25 @collectionOptions)
$userCheck = $checks | Where-Object { $_.Task.Kind -eq "Users" }
$userCount = if ($userCheck.Error) { "Unavailable" } else { $userCheck.Value }
$checkIndex = @{}
foreach ($check in $checks) { $checkIndex["$($check.Task.Kind):$($check.Task.Server)"] = $check }
$domainControllerResults = @(
    foreach ($dc in $domainControllers) {
        $status = $checkIndex["Status:$($dc.HostName)"]
        $disks = $checkIndex["Disks:$($dc.HostName)"]
        $available = -not $status.Error -and $null -ne $status.Value
        if (-not $disks.Error -and @($disks.Value).Count -eq 0) {
            Add-CollectionWarning -Target $dc.Name -Check "Disk capacity" -Message "No fixed disks were returned."
        }
        [pscustomobject]@{
            Name = $dc.Name; HostName = $dc.HostName; IPv4Address = $dc.IPv4Address
            Site = $dc.Site; OperatingSystem = $dc.OperatingSystem; IsGlobalCatalog = [bool]$dc.IsGlobalCatalog
            CurrentTime = if ($available) { $status.Value.CurrentTime } else { $null }
            IsGlobalCatalogReady = if ($available) { $status.Value.Ready } else { $false }
            IsSynchronized = if ($available) { $status.Value.Synchronized } else { $false }
            StatusAvailable = $available; StatusError = $status.Error
            Disks = @($disks.Value | Where-Object { $null -ne $_ }); DiskError = $disks.Error
        }
    }
)

$replicationOutput = "Skipped by DiagnosticsLevel None."
$dcdiagOutput = "Skipped by DiagnosticsLevel None."
$replicationExitCode = $null
$dcdiagExitCode = $null
$diagnostic = [pscustomobject]@{ Output = ""; ExitCode = $null; Error = $null }
if ($DiagnosticsLevel -ne "None") {
    if ($targetServer -notmatch '^[a-zA-Z0-9._-]+$') { throw "Diagnostic target must be a DNS server name without command-line metacharacters." }
    $replicationArguments = if ($DiagnosticsLevel -eq "Full") { @("/replsum", "/errorsonly") } else { @("/replsum", $targetServer, "/errorsonly") }
    $dcdiagArguments = if ($DiagnosticsLevel -eq "Full") { @("/e", "/q", "/c") } else { @("/s:$targetServer", "/q", "/test:Connectivity", "/test:Advertising", "/test:Replications") }
    Write-Verbose "Running $DiagnosticsLevel replication diagnostics."
    $replication = Invoke-NativeDiagnostic -ExecutableName "repadmin.exe" -Arguments $replicationArguments -TimeoutSeconds $DiagnosticsTimeoutSeconds
    Write-Verbose "Running $DiagnosticsLevel domain controller diagnostics."
    $diagnostic = Invoke-NativeDiagnostic -ExecutableName "dcdiag.exe" -Arguments $dcdiagArguments -TimeoutSeconds $DiagnosticsTimeoutSeconds
    $replicationExitCode = $replication.ExitCode
    $dcdiagExitCode = $diagnostic.ExitCode
    $replicationOutput = if ($replication.Error) { "Replication check unavailable." } elseif ($replication.ExitCode -eq 0) { "repadmin completed successfully. Its exit code alone does not establish replication health; review its output." } else { "Replication check returned exit code $($replication.ExitCode)." }
    $dcdiagOutput = if ($diagnostic.Error) { "DCDIAG check unavailable." } elseif ($diagnostic.ExitCode -eq 0 -and -not $diagnostic.Output) { "No errors found in dcdiag results." } else { "DCDIAG returned output or an unsuccessful exit code. Review is required." }
    if (-not $replication.Error -and $replication.ExitCode -ne 0) {
        Add-CollectionWarning -Target "repadmin.exe" -Check "Replication" -Message "Exit code $($replication.ExitCode)."
    }
    if (-not $diagnostic.Error -and ($diagnostic.ExitCode -ne 0 -or $diagnostic.Output)) {
        Add-CollectionWarning -Target "dcdiag.exe" -Check "Domain controller diagnostics" -Message "DCDIAG returned output or an unsuccessful exit code."
    }
    if ($IncludeDiagnosticDetails) {
        if ($replication.Output) { $replicationOutput += [Environment]::NewLine + $replication.Output }
        if ($diagnostic.Output) { $dcdiagOutput += [Environment]::NewLine + $diagnostic.Output }
    }
    else {
        $replicationOutput += " Raw output omitted; use -IncludeDiagnosticDetails to include it."
        $dcdiagOutput += " Raw output omitted; use -IncludeDiagnosticDetails to include it."
    }
}

$globalCatalogControllers = @($domainControllerResults | Where-Object { $_.IsGlobalCatalog })
$readyCount = @($globalCatalogControllers | Where-Object { $_.StatusAvailable -and $_.IsGlobalCatalogReady }).Count
$globalCatalogCount = $globalCatalogControllers.Count
$synchronizedCount = @($domainControllerResults | Where-Object { $_.StatusAvailable -and $_.IsSynchronized }).Count
$domainControllerCount = $domainControllerResults.Count
$readyPercent = if ($globalCatalogCount -gt 0) { [math]::Round(($readyCount / $globalCatalogCount) * 100) } else { 0 }
$synchronizedPercent = if ($domainControllerCount -gt 0) { [math]::Round(($synchronizedCount / $domainControllerCount) * 100) } else { 0 }
$readyAngle = [math]::Round(($readyPercent / 100) * 360)
$synchronizedAngle = [math]::Round(($synchronizedPercent / 100) * 360)
$unknownCount = @($domainControllerResults | Where-Object { -not $_.StatusAvailable }).Count
$unknownGcCount = @($globalCatalogControllers | Where-Object { -not $_.StatusAvailable }).Count

$domainControllerRows = foreach ($dc in $domainControllerResults) {
    $readyClass = Get-HealthClass -IsHealthy $dc.IsGlobalCatalogReady -IsUnknown (-not $dc.StatusAvailable)
    $syncClass = Get-HealthClass -IsHealthy $dc.IsSynchronized -IsUnknown (-not $dc.StatusAvailable)
    $readyText = Get-StatusText -IsHealthy $dc.IsGlobalCatalogReady -IsUnknown (-not $dc.StatusAvailable) -HealthyText "Ready" -UnhealthyText "Not ready"
    if (-not $dc.IsGlobalCatalog) {
        $readyClass = "neutral"
        $readyText = "Not a Global Catalog"
    }
    $syncText = Get-StatusText -IsHealthy $dc.IsSynchronized -IsUnknown (-not $dc.StatusAvailable) -HealthyText "Synchronized" -UnhealthyText "Not synchronized"
    $currentTime = if ($dc.CurrentTime) { Get-Date $dc.CurrentTime -Format "yyyy-MM-dd HH:mm:ss" } else { "Unavailable" }

    @"
<tr>
  <td><strong>$(ConvertTo-HtmlEncoded $dc.Name)</strong><span class="subtle">$(ConvertTo-HtmlEncoded $dc.HostName)</span></td>
  <td>$(ConvertTo-HtmlEncoded $dc.IPv4Address)</td>
  <td>$(ConvertTo-HtmlEncoded $dc.Site)</td>
  <td>$(ConvertTo-HtmlEncoded $dc.OperatingSystem)</td>
  <td>$(ConvertTo-HtmlEncoded $currentTime)</td>
  <td><span class="badge $readyClass">$readyText</span></td>
  <td><span class="badge $syncClass">$syncText</span></td>
</tr>
"@
}

$diskCards = foreach ($dc in $domainControllerResults) {
    $diskContent = if ($dc.Disks.Count -gt 0 -and -not $dc.DiskError) {
        $diskRows = foreach ($disk in $dc.Disks) {
            $diskClass = if ($disk.FreePercent -lt 10) {
                "danger"
            }
            elseif ($disk.FreePercent -lt 20) {
                "warning"
            }
            else {
                "success"
            }

            @"
<div class="disk-row">
  <div class="disk-heading">
    <strong>$(ConvertTo-HtmlEncoded $disk.DeviceId)</strong>
    <span>$(ConvertTo-HtmlEncoded $disk.FreeGb) GB free of $(ConvertTo-HtmlEncoded $disk.SizeGb) GB</span>
  </div>
  <div class="progress" role="img" aria-label="$(ConvertTo-HtmlEncoded $disk.DeviceId) has $(ConvertTo-HtmlEncoded $disk.FreePercent) percent free space">
    <span class="$diskClass" style="width: $($disk.FreePercent.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))%"></span>
  </div>
  <div class="disk-caption">$($disk.FreePercent)% free</div>
</div>
"@
        }
        $diskRows -join [Environment]::NewLine
    }
    else {
        $diskMessage = if ($dc.DiskError -and $IncludeDiagnosticDetails) { $dc.DiskError } elseif ($dc.DiskError) { "Disk check unavailable. See collection warnings." } else { "No fixed disks were returned." }
        "<div class=`"empty-state`">$(ConvertTo-HtmlEncoded $diskMessage)</div>"
    }

    @"
<article class="card disk-card">
  <div class="card-header">
    <div>
      <p class="eyebrow">Domain controller</p>
      <h3>$(ConvertTo-HtmlEncoded $dc.Name)</h3>
    </div>
    <span class="badge neutral">$(ConvertTo-HtmlEncoded $dc.IPv4Address)</span>
  </div>
  $diskContent
</article>
"@
}

$globalCatalogRows = foreach ($globalCatalog in $forestInfo.GlobalCatalogs) {
    "<li><span class=`"status-dot neutral`"></span>$(ConvertTo-HtmlEncoded $globalCatalog)</li>"
}

$fsmoRoles = @(
    [pscustomobject]@{ Role = "Schema Master"; Holder = $forestInfo.SchemaMaster }
    [pscustomobject]@{ Role = "Domain Naming Master"; Holder = $forestInfo.DomainNamingMaster }
    [pscustomobject]@{ Role = "PDC Emulator"; Holder = $domainInfo.PDCEmulator }
    [pscustomobject]@{ Role = "RID Master"; Holder = $domainInfo.RIDMaster }
    [pscustomobject]@{ Role = "Infrastructure Master"; Holder = $domainInfo.InfrastructureMaster }
)

$fsmoCards = foreach ($role in $fsmoRoles) {
    @"
<div class="role-card">
  <span>$(ConvertTo-HtmlEncoded $role.Role)</span>
  <strong>$(ConvertTo-HtmlEncoded $role.Holder)</strong>
</div>
"@
}

$reportGenerated = Get-Date
$replicationHealthy = ($replicationExitCode -eq 0)
$dcdiagHealthy = ($dcdiagExitCode -eq 0) -and (-not $diagnostic.Output)
$replicationClass = Get-HealthClass -IsHealthy $replicationHealthy -IsUnknown ($null -eq $replicationExitCode)
$dcdiagClass = Get-HealthClass -IsHealthy $dcdiagHealthy -IsUnknown ($null -eq $dcdiagExitCode)
$replicationLabel = Get-StatusText -IsHealthy $replicationHealthy -IsUnknown ($null -eq $replicationExitCode) -HealthyText "Command completed" -UnhealthyText "Review output"
$dcdiagLabel = Get-StatusText -IsHealthy $dcdiagHealthy -IsUnknown ($null -eq $dcdiagExitCode) -HealthyText "No reported errors" -UnhealthyText "Review output"
if ($DiagnosticsLevel -eq "None") {
    $replicationLabel = "Skipped"
    $dcdiagLabel = "Skipped"
}
$warningRows = foreach ($warning in $collectionWarnings) {
    $message = if ($IncludeDiagnosticDetails) { $warning.Message } else { "Check incomplete or needs attention. Run with -IncludeDiagnosticDetails for details." }
    "<tr><td>$(ConvertTo-HtmlEncoded $warning.Target)</td><td>$(ConvertTo-HtmlEncoded $warning.Check)</td><td>$(ConvertTo-HtmlEncoded $message)</td></tr>"
}
$warningsContent = if ($collectionWarnings.Count -gt 0) {
    "<div class=`"table-wrap`"><table><thead><tr><th>Target</th><th>Check</th><th>Details</th></tr></thead><tbody>$($warningRows -join [Environment]::NewLine)</tbody></table></div>"
}
else {
    "<p class=`"collection-message`">All requested checks completed without collection warnings.</p>"
}
$collectionLabel = if ($collectionWarnings.Count -gt 0) { "Review required" } else { "Complete" }
$collectionClass = if ($collectionWarnings.Count -gt 0) { "warning" } else { "success" }
$sensitivityText = if ($RedactSensitiveData) {
    "Redacted infrastructure report. Redaction is best-effort; review before sharing."
}
else {
    "Confidential infrastructure information. Share only with authorized recipients."
}
$footerText = "Values reflect collection time. Diagnostics: $DiagnosticsLevel. Runtime: $([math]::Round(($reportGenerated - $reportStarted).TotalSeconds, 1)) seconds."
if ($IncludeCreatorIdentity) { $footerText += " Generated by $env:USERNAME on $env:COMPUTERNAME." }
Write-Progress -Id 1 -Activity "Creating Active Directory report" -Status "Rendering HTML report" -PercentComplete 90

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>
  (() => {
    const param = new URLSearchParams(window.location.search).get("scoutTheme");
    const theme =
      param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>
<title>Active Directory Environment Overview</title>
<style>
:root {
  color-scheme: light;
  --cp-bg: #f7f4ef;
  --cp-bg-elevated: #fcfbf8;
  --cp-surface: #ffffff;
  --cp-surface-soft: #f5f5f5;
  --cp-border: #dedede;
  --cp-border-strong: #919191;
  --cp-text: #242424;
  --cp-text-muted: #5c5c5c;
  --cp-text-soft: #6f6f6f;
  --cp-accent: #b11f4b;
  --cp-accent-hover: #9a1a41;
  --cp-accent-soft: rgba(177, 31, 75, 0.08);
  --cp-accent-fg: #ffffff;
  --cp-success: #16a34a;
  --cp-danger: #dc2626;
  --cp-warning: #f59e0b;
  --cp-link: #0078d4;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
  --cp-overlay: rgba(255, 255, 255, 0.8);
  --cp-panel: rgba(255, 255, 255, 0.86);
  --cp-panel-strong: rgba(255, 255, 255, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.55);
  --cp-highlight: rgba(177, 31, 75, 0.12);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --cp-bg: #3d3b3a;
  --cp-bg-elevated: #343231;
  --cp-surface: #292929;
  --cp-surface-soft: #2e2e2e;
  --cp-border: #474747;
  --cp-border-strong: #5f5f5f;
  --cp-text: #dedede;
  --cp-text-muted: #919191;
  --cp-text-soft: #b0b0b0;
  --cp-accent: #fd8ea1;
  --cp-accent-hover: #fb7b91;
  --cp-accent-soft: rgba(253, 142, 161, 0.14);
  --cp-accent-fg: #1a1a1a;
  --cp-success: #4ade80;
  --cp-danger: #f87171;
  --cp-warning: #fbbf24;
  --cp-link: #4da6ff;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
  --cp-overlay: rgba(41, 41, 41, 0.88);
  --cp-panel: rgba(41, 41, 41, 0.72);
  --cp-panel-strong: rgba(41, 41, 41, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.04);
  --cp-highlight: rgba(253, 142, 161, 0.12);
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--cp-bg);
  color: var(--cp-text);
  font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif;
  line-height: 1.5;
}
button { font: inherit; }
.shell { width: min(1440px, calc(100% - 32px)); margin: 0 auto; padding: 32px 0 64px; }
.hero {
  display: flex;
  justify-content: space-between;
  gap: 24px;
  align-items: flex-start;
  padding: 28px;
  border: 1px solid var(--cp-border);
  border-top: 4px solid var(--cp-accent);
  border-radius: 16px;
  background: var(--cp-bg-elevated);
  box-shadow: 0 1px 2px var(--cp-border);
}
.hero h1 { margin: 4px 0 8px; font-size: clamp(1.75rem, 4vw, 2.75rem); line-height: 1.1; }
.hero p { margin: 0; color: var(--cp-text-muted); }
.eyebrow {
  margin: 0;
  color: var(--cp-accent);
  font-size: .75rem;
  font-weight: 700;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.hero-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.button {
  border: 1px solid var(--cp-border-strong);
  border-radius: .625rem;
  background: var(--cp-surface);
  color: var(--cp-text);
  padding: 9px 14px;
  cursor: pointer;
}
.button:hover { border-color: var(--cp-accent); color: var(--cp-accent); }
.summary-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 16px;
  margin-top: 20px;
}
.card {
  border: 1px solid var(--cp-border);
  border-radius: 16px;
  background: var(--cp-surface);
  box-shadow: 0 1px 2px var(--cp-border);
}
.metric { padding: 20px; }
.metric span { color: var(--cp-text-muted); font-size: .875rem; }
.metric strong { display: block; margin-top: 4px; font-size: 2rem; line-height: 1.1; }
.section { margin-top: 32px; }
.section-heading { display: flex; justify-content: space-between; align-items: end; gap: 16px; margin-bottom: 12px; }
.section-heading h2 { margin: 0; font-size: 1.35rem; }
.section-heading p { margin: 0; color: var(--cp-text-muted); font-size: .875rem; }
.health-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.health-card { padding: 24px; display: flex; align-items: center; gap: 24px; }
.donut {
  width: 112px;
  height: 112px;
  flex: 0 0 112px;
  border-radius: 50%;
  display: grid;
  place-items: center;
  position: relative;
}
.donut::after {
  content: "";
  width: 76px;
  height: 76px;
  position: absolute;
  border-radius: 50%;
  background: var(--cp-surface);
}
.donut strong { position: relative; z-index: 1; font-size: 1.35rem; }
.health-copy h3 { margin: 0 0 4px; }
.health-copy p { margin: 0; color: var(--cp-text-muted); }
.table-card { overflow: hidden; }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 13px 16px; border-bottom: 1px solid var(--cp-border); text-align: left; vertical-align: middle; white-space: nowrap; }
th { background: var(--cp-surface-soft); color: var(--cp-text-muted); font-size: .75rem; letter-spacing: .05em; text-transform: uppercase; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover { background: var(--cp-accent-soft); }
.subtle { display: block; color: var(--cp-text-muted); font-size: .75rem; font-weight: 400; }
.badge {
  display: inline-flex;
  align-items: center;
  border: 1px solid currentColor;
  border-radius: 999px;
  padding: 3px 9px;
  font-size: .75rem;
  font-weight: 700;
}
.success { color: var(--cp-success); }
.warning { color: var(--cp-warning); }
.danger { color: var(--cp-danger); }
.neutral { color: var(--cp-text-muted); }
.disk-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.disk-card { padding: 20px; }
.card-header { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 20px; }
.card-header h3 { margin: 2px 0 0; }
.disk-row + .disk-row { margin-top: 20px; }
.disk-heading { display: flex; justify-content: space-between; gap: 12px; font-size: .875rem; }
.disk-heading span, .disk-caption { color: var(--cp-text-muted); }
.progress { height: 12px; margin: 7px 0 4px; overflow: hidden; border-radius: 999px; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); }
.progress span { display: block; height: 100%; background: currentColor; border-radius: inherit; }
.disk-caption { font-size: .75rem; text-align: right; }
.details-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.detail-card { padding: 20px; }
.detail-card h3 { margin: 0 0 16px; }
.facts { margin: 0; display: grid; gap: 12px; }
.facts div { display: flex; justify-content: space-between; gap: 16px; padding-bottom: 10px; border-bottom: 1px solid var(--cp-border); }
.facts div:last-child { padding-bottom: 0; border-bottom: 0; }
.facts dt { color: var(--cp-text-muted); }
.facts dd { margin: 0; font-weight: 700; text-align: right; }
.server-list { list-style: none; padding: 0; margin: 0; display: grid; gap: 10px; }
.server-list li { display: flex; align-items: center; gap: 8px; }
.status-dot { width: 9px; height: 9px; border-radius: 50%; background: currentColor; }
.role-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.role-card { padding: 16px; border: 1px solid var(--cp-border); border-radius: .625rem; background: var(--cp-surface); }
.role-card span { display: block; color: var(--cp-text-muted); font-size: .75rem; margin-bottom: 6px; }
.role-card strong { overflow-wrap: anywhere; }
.diagnostics-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.diagnostic { overflow: hidden; }
.diagnostic-header { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 16px 18px; border-bottom: 1px solid var(--cp-border); }
.diagnostic-header h3 { margin: 0; }
pre {
  min-height: 180px;
  max-height: 420px;
  overflow: auto;
  margin: 0;
  padding: 18px;
  background: var(--cp-surface-soft);
  color: var(--cp-text);
  font: .8rem/1.55 Consolas, "Courier New", Courier, monospace;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.empty-state { padding: 20px; border: 1px dashed var(--cp-border-strong); border-radius: .625rem; color: var(--cp-text-muted); }
.sensitivity { margin-top: 16px; padding: 12px 16px; border: 1px solid var(--cp-warning); border-radius: .625rem; color: var(--cp-text); background: var(--cp-surface); }
.collection-message { padding: 16px; margin: 0; }
.footer { margin-top: 32px; color: var(--cp-text-muted); font-size: .8rem; text-align: center; }
@media (max-width: 1000px) {
  .summary-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .role-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .diagnostics-grid { grid-template-columns: 1fr; }
}
@media (max-width: 700px) {
  .shell { width: min(100% - 20px, 1440px); padding-top: 10px; }
  .hero { padding: 20px; flex-direction: column; }
  .hero-actions { justify-content: flex-start; }
  .summary-grid, .health-grid, .disk-grid, .details-grid, .role-grid { grid-template-columns: 1fr; }
  .health-card { align-items: flex-start; flex-direction: column; }
}
@media print {
  .shell { width: 100%; padding: 0; }
  .hero-actions { display: none; }
  .card, .hero, .role-card { box-shadow: none; break-inside: avoid; }
  .section { break-inside: avoid; }
  pre { max-height: none; }
}
</style>
</head>
<body>
<main class="shell">
  <header class="hero">
    <div>
      <p class="eyebrow">Infrastructure health report</p>
      <h1>Active Directory Overview</h1>
      <p>$(ConvertTo-HtmlEncoded $domainInfo.DNSRoot) &middot; Generated $(ConvertTo-HtmlEncoded ($reportGenerated.ToString("MMMM d, yyyy 'at' h:mm tt")))</p>
    </div>
    <div class="hero-actions">
      <button class="button" type="button" onclick="toggleTheme()">Toggle theme</button>
      <button class="button" type="button" onclick="window.print()">Print report</button>
    </div>
  </header>

  <aside class="sensitivity">$(ConvertTo-HtmlEncoded $sensitivityText)</aside>

  <section class="section">
    <div class="section-heading"><h2>Collection status</h2><span class="badge $collectionClass">$collectionLabel</span></div>
    <div class="card">$warningsContent</div>
    <p class="subtle">$($collectionWarnings.Count) warnings. Diagnostics scope: $DiagnosticsLevel. Raw diagnostic details are opt-in.</p>
  </section>

  <section class="summary-grid" aria-label="Environment summary">
    <article class="card metric"><span>User objects</span><strong>$(ConvertTo-HtmlEncoded $userCount)</strong></article>
    <article class="card metric"><span>Domain controllers</span><strong>$(ConvertTo-HtmlEncoded $domainControllerCount)</strong></article>
    <article class="card metric"><span>Forest functional level</span><strong>$(ConvertTo-HtmlEncoded $rootDse.forestFunctionality)</strong></article>
    <article class="card metric"><span>Domain functional level</span><strong>$(ConvertTo-HtmlEncoded $rootDse.domainFunctionality)</strong></article>
  </section>

  <section class="section">
    <div class="section-heading"><h2>Domain and forest</h2><p>Configuration details</p></div>
    <div class="details-grid">
      <article class="card detail-card">
        <h3>Directory configuration</h3>
        <dl class="facts">
          <div><dt>Domain</dt><dd>$(ConvertTo-HtmlEncoded $domainInfo.DNSRoot)</dd></div>
          <div><dt>NetBIOS name</dt><dd>$(ConvertTo-HtmlEncoded $domainInfo.NetBIOSName)</dd></div>
          <div><dt>Forest</dt><dd>$(ConvertTo-HtmlEncoded $domainInfo.Forest)</dd></div>
          <div><dt>Domain mode</dt><dd>$(ConvertTo-HtmlEncoded $domainInfo.DomainMode)</dd></div>
          <div><dt>Forest mode</dt><dd>$(ConvertTo-HtmlEncoded $forestInfo.ForestMode)</dd></div>
        </dl>
      </article>
      <article class="card detail-card">
        <h3>Global Catalog servers</h3>
        <ul class="server-list">$($globalCatalogRows -join [Environment]::NewLine)</ul>
      </article>
    </div>
  </section>

  <section class="section">
    <div class="section-heading"><h2>FSMO role holders</h2><p>Flexible Single Master Operations</p></div>
    <div class="role-grid">$($fsmoCards -join [Environment]::NewLine)</div>
  </section>

  <section class="section">
    <div class="section-heading">
      <h2>Directory health</h2>
      <p>Unavailable checks are reported separately, not treated as failures</p>
    </div>
    <div class="health-grid">
      <article class="card health-card">
        <div class="donut" style="background: conic-gradient(var(--cp-success) 0deg $($readyAngle)deg, var(--cp-surface-soft) $($readyAngle)deg 360deg)"><strong>$readyPercent%</strong></div>
        <div class="health-copy"><h3>Global Catalog readiness</h3><p>$readyCount of $globalCatalogCount configured Global Catalogs are ready; $unknownGcCount unavailable.</p></div>
      </article>
      <article class="card health-card">
        <div class="donut" style="background: conic-gradient(var(--cp-success) 0deg $($synchronizedAngle)deg, var(--cp-surface-soft) $($synchronizedAngle)deg 360deg)"><strong>$synchronizedPercent%</strong></div>
        <div class="health-copy"><h3>Directory synchronization</h3><p>$synchronizedCount of $domainControllerCount domain controllers are synchronized; $unknownCount unavailable.</p></div>
      </article>
    </div>
  </section>

  <section class="section">
    <div class="section-heading"><h2>Domain controllers</h2><p>Inventory and current health state</p></div>
    <div class="card table-card">
      <div class="table-wrap">
        <table>
          <thead><tr><th>Server</th><th>IP address</th><th>Site</th><th>Operating system</th><th>Server time</th><th>GC status</th><th>Sync status</th></tr></thead>
          <tbody>$($domainControllerRows -join [Environment]::NewLine)</tbody>
        </table>
      </div>
    </div>
  </section>

  <section class="section">
    <div class="section-heading"><h2>Disk capacity</h2><p>Free space on fixed drives; under 20% is highlighted</p></div>
    <div class="disk-grid">$($diskCards -join [Environment]::NewLine)</div>
  </section>

  <section class="section">
    <div class="section-heading"><h2>Diagnostics</h2><p>Replication and domain-controller checks</p></div>
    <div class="diagnostics-grid">
      <article class="card diagnostic">
        <div class="diagnostic-header"><h3>Replication summary</h3><span class="badge $replicationClass">$replicationLabel</span></div>
        <pre>$(ConvertTo-HtmlEncoded $replicationOutput)</pre>
      </article>
      <article class="card diagnostic">
        <div class="diagnostic-header"><h3>DCDIAG errors</h3><span class="badge $dcdiagClass">$dcdiagLabel</span></div>
        <pre>$(ConvertTo-HtmlEncoded $dcdiagOutput)</pre>
      </article>
    </div>
  </section>

  <footer class="footer">$(ConvertTo-HtmlEncoded $footerText)</footer>
</main>
<script>
function toggleTheme() {
  const current = document.documentElement.getAttribute("data-theme");
  document.documentElement.setAttribute("data-theme", current === "dark" ? "light" : "dark");
}
</script>
</body>
</html>
"@

$temporaryPath = Join-Path $outputDirectory ([System.IO.Path]::GetRandomFileName())
$temporaryCreated = $false
try {
    $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $temporaryCreated = $true
    $stream.Dispose()
    if ($ProtectOutput) {
        $security = [System.Security.AccessControl.FileSecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        foreach ($sid in @($currentUser, [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544"), [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18"))) {
            $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, "FullControl", "Allow"))
        }
        Set-Acl -LiteralPath $temporaryPath -AclObject $security
    }
    [System.IO.File]::WriteAllText($temporaryPath, $html, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $resolvedOutputPath -Force:$Force
}
finally {
    if ($temporaryCreated -and (Test-Path -LiteralPath $temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force }
}
Write-Information "Active Directory HTML report created: $resolvedOutputPath ($($collectionWarnings.Count) warnings)." -InformationAction Continue

if ($OpenReport) {
    Start-Process -FilePath $resolvedOutputPath
}
Get-Item -LiteralPath $resolvedOutputPath
}
finally {
    Write-Progress -Id 2 -Activity "Collection" -Completed
    Write-Progress -Id 1 -Activity "Creating Active Directory report" -Completed
}
