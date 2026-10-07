[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$reportPath = Join-Path $PSScriptRoot "Active Directory - HTML Overview Report.ps1"
$source = Get-Content -LiteralPath $reportPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($reportPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "The report script has parser errors." }
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ADReportTests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$assertionCount = 0

function Assert-Report {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:assertionCount++
}

function Get-TestFunction {
    param([string]$Name)
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }.GetNewClosure(), $true)
    [scriptblock]::Create($definition.Extent.Text)
}

function Invoke-WorkerChecks {
    $assignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$collectionWorker'
    }, $true)
    $worker = $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
    function Import-Module { param($Name, $ErrorAction) }
    function Get-ADRootDSE {
        param($Properties, $Server, $ErrorAction)
        [pscustomobject]@{
            currentTime = Get-Date; isGlobalCatalogReady = "False"; isSynchronized = "TRUE"
            defaultNamingContext = "DC=fixture"
        }
    }
    function Get-ADDomain {
        param($Identity, $Server, $ErrorAction)
        [pscustomobject]@{ DistinguishedName = "DC=fixture"; PDCEmulator = "fixture" }
    }
    function Get-ADForest {
        param($Identity, $Server, $ErrorAction)
        [pscustomobject]@{ Name = "fixture" }
    }
    function Get-ADDomainController {
        param($Filter, $Server, $ErrorAction)
        @()
    }
    function Get-ADUser {
        param($Filter, $SearchBase, $Server, $ResultSetSize, $ErrorAction)
        1..7 | ForEach-Object { [pscustomobject]@{ Name = "user$_" } }
    }
    function New-CimSessionOption { param($Protocol); [pscustomobject]@{ Protocol = $Protocol } }
    function New-CimSession {
        param($ComputerName, $SessionOption, $OperationTimeoutSec, $ErrorAction)
        Assert-Report ($SessionOption.Protocol -eq "Wsman") "CIM uses WSMan."
        [pscustomobject]@{ ComputerName = $ComputerName }
    }
    function Get-CimInstance {
        param($ClassName, $CimSession, $Filter, $Property, $OperationTimeoutSec, $ErrorAction)
        if ($script:invalidDisk) { [pscustomobject]@{ DeviceID = "C:"; Size = 0; FreeSpace = 0 } }
        else { [pscustomobject]@{ DeviceID = "C:"; Size = 100GB; FreeSpace = 15GB } }
    }
    function Remove-CimSession {
        param($CimSession, $ErrorAction)
        $script:removedSessions++
    }
    $status = & $worker ([pscustomobject]@{ Kind = "Status"; Server = "fixture" }) 10
    Assert-Report (-not $status.Ready -and $status.Synchronized) "String booleans are parsed correctly."
    $count = & $worker ([pscustomobject]@{ Kind = "Users"; Method = "AD"; Server = "fixture"; SearchBase = "DC=fixture" }) 10
    Assert-Report ($count -eq 7) "AD user count is streamed."
    $script:invalidDisk = $false
    $script:removedSessions = 0
    $disk = & $worker ([pscustomobject]@{ Kind = "Disks"; Server = "fixture" }) 10
    Assert-Report ($disk.FreePercent -eq 15) "Disk percentages are calculated correctly."
    Assert-Report ($script:removedSessions -eq 1) "CIM session is removed after success."
    $script:invalidDisk = $true
    $failed = $false
    try { & $worker ([pscustomobject]@{ Kind = "Disks"; Server = "fixture" }) 10 | Out-Null }
    catch { $failed = $_.Exception.Message -match "invalid capacity" }
    Assert-Report $failed "Invalid disk capacity is surfaced, not silently defaulted."
    Assert-Report ($script:removedSessions -eq 2) "CIM session is removed after failure."
    $workerText = $worker.ToString()
    Assert-Report ($workerText -match 'PropertiesToLoad.Add\("objectGUID"\)' -and $workerText -match 'AuthenticationTypes\]::Signing' -and $workerText -match 'AuthenticationTypes\]::Sealing') "LDAP counting requests a minimal property and signs/seals its connection."
    $domainMismatch = $false
    function Get-ADDomain {
        param($Identity, $Server, $ErrorAction)
        [pscustomobject]@{ DistinguishedName = "DC=different"; PDCEmulator = "fixture" }
    }
    try { & $worker ([pscustomobject]@{ Kind = "Inventory"; Domain = "different"; Server = "fixture" }) 10 | Out-Null }
    catch { $domainMismatch = $_.Exception.Message -match "does not serve" }
    Assert-Report $domainMismatch "Mismatched domain and server fail explicitly."
}

# Replace only collection boundaries for end-to-end rendering tests.
$mockBatch = @'
function Invoke-CollectionBatch {
    param($Tasks, $Worker, $Phase, $PercentComplete, $Limit, $TimeoutSeconds)
    foreach ($task in $Tasks) {
        $value = $null
        $failure = $null
        switch ($task.Kind) {
            "Inventory" {
                $domain = [pscustomobject]@{
                    DNSRoot = "contoso.com"; NetBIOSName = "CONTOSO"; Forest = "contoso.com"
                    DistinguishedName = "DC=contoso,DC=com"; PDCEmulator = "DC01.contoso.com"
                    RIDMaster = "DC01.contoso.com"; InfrastructureMaster = "DC02.contoso.com"
                    DomainMode = "Windows2016Domain"
                }
                $forest = [pscustomobject]@{
                    SchemaMaster = "DC01.contoso.com"; DomainNamingMaster = "DC01.contoso.com"
                    ForestMode = "Windows2016Forest"; GlobalCatalogs = @("DC01.contoso.com")
                }
                $controllers = @(
                    [pscustomobject]@{ Name = "DC01"; HostName = "DC01.contoso.com"; IPv4Address = "10.20.0.10"; Site = "Headquarters"; OperatingSystem = "Windows Server <2022>"; IsGlobalCatalog = $true }
                    [pscustomobject]@{ Name = "DC02"; HostName = "DC02.contoso.com"; IPv4Address = "10.20.0.11"; Site = "Headquarters"; OperatingSystem = "Windows Server 2022"; IsGlobalCatalog = $false }
                )
                if ($env:AD_REPORT_TEST_SCENARIO -eq "Single") { $controllers = @($controllers[0]) }
                $value = [pscustomobject]@{
                    Domain = $domain; Forest = $forest; Server = "DC01.contoso.com"
                    Root = [pscustomobject]@{ forestFunctionality = 7; domainFunctionality = 7 }
                    Controllers = $controllers
                }
            }
            "Users" {
                $value = 1247
                if ($env:AD_REPORT_TEST_SCENARIO -eq "Failures") { $failure = "User query failed." }
            }
            "Status" {
                $value = [pscustomobject]@{ CurrentTime = Get-Date; Ready = $true; Synchronized = $true }
                if ($env:AD_REPORT_TEST_SCENARIO -eq "Failures") { $value = $null; $failure = "LDAP error on DC01.contoso.com <unsafe>." }
            }
            "Disks" {
                $value = @(
                    [pscustomobject]@{ DeviceId = "C:"; SizeGb = 100; FreeGb = 9.9; FreePercent = 9.9 }
                    [pscustomobject]@{ DeviceId = "D:"; SizeGb = 100; FreeGb = 15; FreePercent = 15 }
                )
                if ($env:AD_REPORT_TEST_SCENARIO -eq "Failures") { $value = $null; $failure = "CIM error on DC02.contoso.com <unsafe>." }
            }
        }
        if ($failure) { Add-CollectionWarning -Target $task.Name -Check $Phase -Message $failure }
        [pscustomobject]@{ Task = $task; Value = $value; Error = $failure }
    }
}
'@
$mockNative = @'
function Invoke-NativeDiagnostic {
    param($ExecutableName, $Arguments, $TimeoutSeconds)
    if ($env:AD_REPORT_TEST_SCENARIO -eq "NativeFailure") {
        Add-CollectionWarning -Target $ExecutableName -Check "Diagnostics" -Message "Tool unavailable."
        return [pscustomobject]@{ Output = ""; ExitCode = $null; Error = "Tool unavailable." }
    }
    $output = if ($ExecutableName -eq "dcdiag.exe" -and $env:AD_REPORT_TEST_SCENARIO -eq "Localized") {
        "Echec de replication DC01.contoso.com <unsafe>."
    } elseif ($ExecutableName -eq "repadmin.exe") { "Replication Summary Start Time: fixture" } else { "" }
    [pscustomobject]@{ Output = $output; ExitCode = 0; Error = $null }
}
'@
$replacements = @(
    @{ Name = "Invoke-CollectionBatch"; Text = $mockBatch }
    @{ Name = "Invoke-NativeDiagnostic"; Text = $mockNative }
)
$mockSource = $source
$definitions = foreach ($replacement in $replacements) {
    $name = $replacement.Name
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }.GetNewClosure(), $true)
    [pscustomobject]@{ Start = $definition.Extent.StartOffset; End = $definition.Extent.EndOffset; Text = $replacement.Text }
}
foreach ($definition in ($definitions | Sort-Object Start -Descending)) {
    $mockSource = $mockSource.Remove($definition.Start, $definition.End - $definition.Start).Insert($definition.Start, $definition.Text)
}
$mockReport = [scriptblock]::Create($mockSource)
$originalScenario = $env:AD_REPORT_TEST_SCENARIO
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    Invoke-WorkerChecks
    $env:AD_REPORT_TEST_SCENARIO = "Healthy"
    $outputPath = Join-Path $testDirectory "healthy.html"
    $file = & $mockReport -OutputPath $outputPath -DiagnosticsLevel None -ProtectOutput
    Assert-Report ($file -is [System.IO.FileInfo]) "Report returns a FileInfo, not status text."
    $html = Get-Content -LiteralPath $file.FullName -Raw
    Assert-Report ($html -match "Not a Global Catalog") "Non-GC controller is labeled correctly."
    Assert-Report ($html -match "1 of 1 configured Global Catalogs") "GC denominator excludes non-GCs."
    Assert-Report ($html -match "Skipped" -and $html -notmatch "Generated by") "Skipped diagnostics and opt-in identity are explicit."
    Assert-Report ($html -match "Windows Server &lt;2022&gt;") "Inventory text is HTML-encoded."
    Assert-Report ($html -match 'class="danger" style="width: 9.9%' -and $html -match 'class="warning" style="width: 15.0%') "Disk thresholds and invariant CSS values are correct."
    Assert-Report ($html.IndexOf("<h2>Domain and forest</h2>") -lt $html.IndexOf("<h2>Directory health</h2>")) "Domain information precedes health."
    Assert-Report ($html.IndexOf("<h2>FSMO role holders</h2>") -lt $html.IndexOf("<h2>Directory health</h2>")) "FSMO roles precede health."
    $acl = Get-Acl -LiteralPath $file.FullName
    Assert-Report $acl.AreAccessRulesProtected "Protected report disables inherited permissions."
    $sidRules = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Assert-Report ($sidRules.Count -eq 3 -and $currentSid -in $sidRules -and "S-1-5-32-544" -in $sidRules -and "S-1-5-18" -in $sidRules) "Protected file grants only the intended principals."

    $overwriteRejected = $false
    try { & $mockReport -OutputPath $outputPath -DiagnosticsLevel None | Out-Null }
    catch { $overwriteRejected = $_.Exception.Message -match "already exists" }
    Assert-Report $overwriteRejected "Existing report cannot be overwritten without Force."
    $invalidPathRejected = $false
    try { & $mockReport -OutputPath (Join-Path $testDirectory "wrong.txt") -DiagnosticsLevel None | Out-Null }
    catch { $invalidPathRejected = $_.Exception.Message -match "must end" }
    Assert-Report $invalidPathRejected "Output requires an HTML filename."
    $env:AD_REPORT_TEST_SCENARIO = "Single"
    & $mockReport -OutputPath $outputPath -DiagnosticsLevel None -Force | Out-Null
    Assert-Report ((Get-Content -LiteralPath $outputPath -Raw) -match "1 of 1 domain controllers") "Single-controller reports render correctly."

    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fr-FR")
    $env:AD_REPORT_TEST_SCENARIO = "Failures"
    $redactedPath = Join-Path $testDirectory "redacted.html"
    & $mockReport -OutputPath $redactedPath -DiagnosticsLevel None -RedactSensitiveData -IncludeDiagnosticDetails -IncludeCreatorIdentity -WarningAction SilentlyContinue | Out-Null
    $redacted = Get-Content -LiteralPath $redactedPath -Raw
    Assert-Report ($redacted -notmatch "contoso|DC01|DC02|10\.20\.0\.|Headquarters") "Known infrastructure identifiers are redacted throughout the HTML."
    Assert-Report ($redacted -match "\[redacted\]" -and $redacted -match "&lt;unsafe&gt;") "Redacted error details remain HTML-encoded."
    Assert-Report ($redacted -match "Review required" -and $redacted -match "Unavailable") "Partial collection is not shown as healthy."
    $privatePath = Join-Path $testDirectory "private.html"
    & $mockReport -OutputPath $privatePath -DiagnosticsLevel None -WarningAction SilentlyContinue | Out-Null
    Assert-Report ((Get-Content -LiteralPath $privatePath -Raw) -notmatch "unsafe") "Detailed collection errors are opt-in."

    $env:AD_REPORT_TEST_SCENARIO = "Localized"
    $localizedPath = Join-Path $testDirectory "localized.html"
    & $mockReport -OutputPath $localizedPath -DiagnosticsLevel Quick -IncludeDiagnosticDetails -WarningAction SilentlyContinue | Out-Null
    $localized = Get-Content -LiteralPath $localizedPath -Raw
    Assert-Report ($localized -match "Echec de replication" -and $localized -match "Review output") "Non-English DCDIAG output is retained and requires review."
    Assert-Report ($localized -match 'style="width: 9.9%') "Decimal-comma cultures do not produce invalid chart widths."
    $env:AD_REPORT_TEST_SCENARIO = "Healthy"
    & $mockReport -OutputPath (Join-Path $testDirectory "full.html") -DiagnosticsLevel Full | Out-Null
    Assert-Report ((Get-Content -LiteralPath (Join-Path $testDirectory "full.html") -Raw) -match "No reported errors") "Clean full diagnostics remain healthy without raw details."
    $env:AD_REPORT_TEST_SCENARIO = "NativeFailure"
    & $mockReport -OutputPath (Join-Path $testDirectory "missing.html") -DiagnosticsLevel Full -WarningAction SilentlyContinue | Out-Null
    Assert-Report ((Get-Content -LiteralPath (Join-Path $testDirectory "missing.html") -Raw) -match "check unavailable") "Missing native tools are reported as unavailable."

    # Exercise the real scheduler and native timeout helper with safe local work.
    $RedactSensitiveData = $false
    $redactionValues = @()
    $collectionWarnings = [System.Collections.Generic.List[object]]::new()
    $DiagnosticsTimeoutSeconds = 1
    . (Get-TestFunction "Protect-ReportText")
    . (Get-TestFunction "Add-CollectionWarning")
    . (Get-TestFunction "Invoke-CollectionBatch")
    . (Get-TestFunction "Invoke-NativeDiagnostic")
    $tasks = @(1..4 | ForEach-Object { [pscustomobject]@{ Name = "Local $_" } })
    $existingJobs = @(Get-Job | Select-Object -ExpandProperty Id)
    $results = @(Invoke-CollectionBatch -Tasks $tasks -Worker {
        param($Task, $TimeoutSeconds)
        $started = Get-Date
        Start-Sleep -Seconds 2
        [pscustomobject]@{ Name = $Task.Name; Started = $started; Finished = Get-Date; Pid = $PID }
    } -Phase "Local concurrency tests" -PercentComplete 0 -Limit 2 -TimeoutSeconds 20)
    Assert-Report ($results.Count -eq 4 -and @($results | Where-Object { $_.Error }).Count -eq 0) "Bounded scheduler collects all tasks."
    Assert-Report (@($results.Value.Pid | Select-Object -Unique).Count -eq 4) "Collection jobs are process-isolated."
    $maxConcurrent = 0
    foreach ($result in $results) {
        $atStart = @($results | Where-Object {
            $_.Value.Started -le $result.Value.Started -and $_.Value.Finished -gt $result.Value.Started
        }).Count
        $maxConcurrent = [math]::Max($maxConcurrent, $atStart)
    }
    Assert-Report ($maxConcurrent -eq 2) "Scheduler runs concurrently without exceeding its throttle."
    $timeoutTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $timeout = @(Invoke-CollectionBatch -Tasks @([pscustomobject]@{ Name = "Timeout" }) -Worker {
        param($Task, $TimeoutSeconds)
        Start-Sleep -Seconds 20
    } -Phase "Local timeout test" -PercentComplete 0 -Limit 1 -TimeoutSeconds 2 -WarningAction SilentlyContinue)
    Assert-Report ($timeout[0].Error -match "deadline") "Scheduler timeout produces an explicit failure."
    Assert-Report ($timeoutTimer.Elapsed.TotalSeconds -lt 10) "Scheduler timeout interrupts the 20-second worker within its deadline allowance."
    $failedJob = @(Invoke-CollectionBatch -Tasks @([pscustomobject]@{ Name = "Failure" }) -Worker {
        param($Task, $TimeoutSeconds)
        throw "Fixture collection failed."
    } -Phase "Local failure test" -PercentComplete 0 -Limit 1 -TimeoutSeconds 20 -WarningAction SilentlyContinue)
    Assert-Report ($failedJob[0].Error -match "Failed" -and $null -eq $failedJob[0].Value) "A failed worker cannot return a healthy-shaped result."
    Assert-Report (@(Get-Job | Where-Object { $_.Id -notin $existingJobs }).Count -eq 0) "Test-owned jobs are cleaned up."
    $native = Invoke-NativeDiagnostic -ExecutableName "ping.exe" -Arguments @("-n", "10", "127.0.0.1") -TimeoutSeconds 1 -WarningAction SilentlyContinue
    Assert-Report ($null -eq $native.ExitCode -and $native.Error -match "deadline") "Native diagnostic timeout is not marked successful."
    $missing = Invoke-NativeDiagnostic -ExecutableName "ADReportMissingTool.exe" -Arguments @() -TimeoutSeconds 1 -WarningAction SilentlyContinue
    Assert-Report ($missing.Error -match "expected system location") "Missing system tool returns an explicit error."
    $nativeSuccess = Invoke-NativeDiagnostic -ExecutableName "cmd.exe" -Arguments @("/c", "exit", "7") -TimeoutSeconds 5
    Assert-Report ($nativeSuccess.ExitCode -eq 7 -and -not $nativeSuccess.Error) "Native helper preserves nonzero exit codes."
    Write-Output "Passed $assertionCount assertions. No Active Directory connections were made."
}
finally {
    $env:AD_REPORT_TEST_SCENARIO = $originalScenario
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    # Only remove explicitly enumerated files created in this unique test directory.
    Get-ChildItem -LiteralPath $testDirectory -File | Remove-Item -Force
    Remove-Item -LiteralPath $testDirectory
}
