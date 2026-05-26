[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }) -ChildPath "Reports"),

    [Parameter(Mandatory = $false)]
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-GraphModule {
    $requiredModules = @(
        "Microsoft.Graph.Authentication"
    )

    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            Write-Host "Module '$moduleName' not found. Installing..." -ForegroundColor Yellow
            try {
                Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Host "Module '$moduleName' installed successfully." -ForegroundColor Green
            }
            catch {
                throw "Failed to install '$moduleName'. Please install it manually: Install-Module $moduleName -Scope CurrentUser`nError: $_"
            }
        }

        if (-not (Get-Module -Name $moduleName)) {
            Write-Host "Importing module '$moduleName'..." -ForegroundColor Cyan
            Import-Module -Name $moduleName -ErrorAction Stop
        }
    }
}

function Connect-ToGraph {
    param(
        [string]$TenantId
    )

    $requiredScopes = @(
        "Device.Read.All",
        "DeviceManagementManagedDevices.Read.All"
    )

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $needsConnect = $true

    if ($ctx) {
        $hasScopes = $requiredScopes | Where-Object { $ctx.Scopes -contains $_ }
        if ($hasScopes.Count -eq $requiredScopes.Count) {
            if ([string]::IsNullOrWhiteSpace($TenantId) -or $ctx.TenantId -eq $TenantId) {
                $needsConnect = $false
            }
        }
    }

    if ($needsConnect) {
        $connectParams = @{
            Scopes = $requiredScopes
        }

        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $connectParams["TenantId"] = $TenantId
        }

        Write-Host "Connecting to Microsoft Graph (Entra ID & Intune)..." -ForegroundColor Cyan
        Connect-MgGraph @connectParams | Out-Null
        $ctx = Get-MgContext
        Write-Host "Connected to tenant: $($ctx.TenantId) as $($ctx.Account)" -ForegroundColor Green
    }
    else {
        $ctx = Get-MgContext
        Write-Host "Already connected to Microsoft Graph. Tenant: $($ctx.TenantId) as $($ctx.Account)" -ForegroundColor Green
    }
}

function Invoke-GraphCollectionRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri

    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next

        if ($response.value) {
            foreach ($entry in $response.value) {
                [void]$items.Add($entry)
            }
        }

        $next = if ($response.ContainsKey('@odata.nextLink')) { $response.'@odata.nextLink' } else { $null }
    }

    return $items
}

function Convert-TrustTypeToJoinType {
    param(
        [string]$TrustType
    )

    switch ($TrustType) {
        "AzureAd" { return "Microsoft Entra joined" }
        "AzureAD" { return "Microsoft Entra joined" }
        "ServerAd" { return "Microsoft Entra hybrid joined" }
        "Workplace" { return "Microsoft Entra registered" }
        default {
            if ([string]::IsNullOrWhiteSpace($TrustType)) {
                return "Unknown"
            }

            return $TrustType
        }
    }
}

function Convert-ToComparableDeviceName {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return $Name.Trim().ToLowerInvariant()
}

function Convert-ToComparableId {
    param(
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return ""
    }

    return $Id.Trim().ToLowerInvariant()
}

Ensure-GraphModule
Connect-ToGraph -TenantId $TenantId

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "Collecting Entra ID devices..."
$entraSelectWithActivity = "id,deviceId,displayName,accountEnabled,operatingSystem,operatingSystemVersion,trustType,approximateLastSignInDateTime"
$entraSelectFallback = "id,deviceId,displayName,accountEnabled,operatingSystem,operatingSystemVersion,trustType"

try {
    $entraRaw = Invoke-GraphCollectionRequest -Uri ("https://graph.microsoft.com/v1.0/devices?`$top=999&`$select={0}" -f $entraSelectWithActivity)
}
catch {
    Write-Warning "Could not retrieve approximateLastSignInDateTime from v1.0/devices. Continuing without Activity timestamp."
    $entraRaw = Invoke-GraphCollectionRequest -Uri ("https://graph.microsoft.com/v1.0/devices?`$top=999&`$select={0}" -f $entraSelectFallback)
}

$report1 = foreach ($d in $entraRaw) {
    [PSCustomObject]@{
        "Device Name"  = $d.displayName
        "Device ID"    = $d.deviceId
        "Object ID"    = $d.id
        "Enabled"      = $d.accountEnabled
        "OS"           = $d.operatingSystem
        "OS Version"   = $d.operatingSystemVersion
        "Join Type"    = Convert-TrustTypeToJoinType -TrustType $d.trustType
        "Activity"     = $d.approximateLastSignInDateTime
    }
}

Write-Host "Collecting Intune managed devices..."
$intuneSelect = "id,deviceName,userPrincipalName,operatingSystem,osVersion,lastSyncDateTime,azureADDeviceId"
$intuneRaw = Invoke-GraphCollectionRequest -Uri ("https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=999&`$select={0}" -f $intuneSelect)

$report2 = foreach ($d in $intuneRaw) {
    $osVersion = @($d.operatingSystem, $d.osVersion) -join " "
    [PSCustomObject]@{
        "Device Name"                = $d.deviceName
        "Primary user UPN"           = $d.userPrincipalName
        "Operating System Version"   = $osVersion.Trim()
        "Last Check-in"              = $d.lastSyncDateTime
        "Intune Device ID"           = $d.id
        "Microsoft Entra Device ID"  = $d.azureADDeviceId
    }
}

Write-Host "Building comparison report..."
$entraByName = $report1 | Group-Object { Convert-ToComparableDeviceName -Name $_."Device Name" }
$intuneByName = $report2 | Group-Object { Convert-ToComparableDeviceName -Name $_."Device Name" }

$entraMap = @{}
foreach ($g in $entraByName) {
    $entraMap[$g.Name] = $g.Group
}

$intuneMap = @{}
foreach ($g in $intuneByName) {
    $intuneMap[$g.Name] = $g.Group
}

$allNames = @(@($entraMap.Keys) + @($intuneMap.Keys) | Sort-Object -Unique)
Write-Host "Found $($allNames.Count) unique device names to compare."
$comparisonRows = @()

foreach ($name in $allNames) {
  try {
    Write-Host "DEBUG: Processing '$name'"
    $entraRows = @()
    $intuneRows = @()

    if ($entraMap.ContainsKey($name)) {
        $entraRows = @($entraMap[$name])
    }

    if ($intuneMap.ContainsKey($name)) {
        $intuneRows = @($intuneMap[$name])
    }

    $displayName = ($entraRows | Select-Object -First 1)."Device Name"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = ($intuneRows | Select-Object -First 1)."Device Name"
    }

    Write-Host "DEBUG: Sorting entraIds"
    $entraIds = @(
        $entraRows |
            ForEach-Object { Convert-ToComparableId -Id $_."Object ID" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    Write-Host "DEBUG: Sorting intuneIds"
    $intuneIds = @(
        $intuneRows |
            ForEach-Object { Convert-ToComparableId -Id $_."Microsoft Entra Device ID" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    $duplicateInEntra = $entraRows.Count -gt 1
    $duplicateInIntune = $intuneRows.Count -gt 1

    Write-Host "DEBUG: Sorting allComparableIds"
    $allComparableIds = @(@($entraIds) + @($intuneIds) | Sort-Object -Unique)
    Write-Host "DEBUG: allComparableIds count=$($allComparableIds.Count)"

    if ($allComparableIds.Count -eq 0) {
        $status = "NoComparableIds"
        if ($entraRows.Count -gt 0 -and $intuneRows.Count -eq 0) {
            $status = "OnlyInEntra"
        }
        elseif ($intuneRows.Count -gt 0 -and $entraRows.Count -eq 0) {
            $status = "OnlyInIntune"
        }

        $comparisonRows += [PSCustomObject]@{
            "Device Name"                 = $displayName
            "Entra Object ID"             = ""
            "Intune Entra Device ID"      = ""
            "Match Status"                = $status
            "Duplicate In Entra"          = $duplicateInEntra
            "Duplicate In Intune"         = $duplicateInIntune
            "Entra Record Count"          = $entraRows.Count
            "Intune Record Count"         = $intuneRows.Count
            "Detail"                      = "No Object ID / Entra Device ID values available for comparison"
        }

        continue
    }

    foreach ($id in $allComparableIds) {
        $existsInEntra = $entraIds -contains $id
        $existsInIntune = $intuneIds -contains $id

        $status = if ($existsInEntra -and $existsInIntune) {
            "Matched"
        }
        elseif ($existsInEntra) {
            "MissingInIntune"
        }
        else {
            "MissingInEntra"
        }

        $comparisonRows += [PSCustomObject]@{
            "Device Name"                 = $displayName
            "Entra Object ID"             = if ($existsInEntra) { $id } else { "" }
            "Intune Entra Device ID"      = if ($existsInIntune) { $id } else { "" }
            "Match Status"                = $status
            "Duplicate In Entra"          = $duplicateInEntra
            "Duplicate In Intune"         = $duplicateInIntune
            "Entra Record Count"          = $entraRows.Count
            "Intune Record Count"         = $intuneRows.Count
            "Detail"                      = "Compared Object ID (Entra) with Microsoft Entra Device ID (Intune) by device name"
        }
    }
  }
  catch {
    Write-Warning "CAUGHT exception type=[$($_.Exception.GetType().FullName)] in device '$name': $($_.Exception.Message)"
    throw
  }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$report1Path = Join-Path -Path $OutputPath -ChildPath ("Report1-EntraDevices-{0}.csv" -f $timestamp)
$report2Path = Join-Path -Path $OutputPath -ChildPath ("Report2-IntuneDevices-{0}.csv" -f $timestamp)
$report3Path = Join-Path -Path $OutputPath -ChildPath ("Report3-DeviceComparison-{0}.csv" -f $timestamp)
$report4Path = Join-Path -Path $OutputPath -ChildPath ("Report4-Summary-{0}.csv" -f $timestamp)

$statusKeys = @("Matched", "MissingInEntra", "MissingInIntune")
$summaryRows = @()

foreach ($statusKey in $statusKeys) {
    $statusCount = @($comparisonRows | Where-Object { $_."Match Status" -eq $statusKey }).Count
    $summaryRows += [PSCustomObject]@{
        "Metric" = "StatusCount"
        "Category" = $statusKey
        "Count" = $statusCount
    }
}

$duplicateInEntraCount = @(
    $comparisonRows |
        Where-Object { $_."Duplicate In Entra" -eq $true } |
        Select-Object -ExpandProperty "Device Name" -Unique
).Count

$duplicateInIntuneCount = @(
    $comparisonRows |
        Where-Object { $_."Duplicate In Intune" -eq $true } |
        Select-Object -ExpandProperty "Device Name" -Unique
).Count

$summaryRows += [PSCustomObject]@{
    "Metric" = "DuplicateDeviceNameCount"
    "Category" = "Entra"
    "Count" = $duplicateInEntraCount
}

$summaryRows += [PSCustomObject]@{
    "Metric" = "DuplicateDeviceNameCount"
    "Category" = "Intune"
    "Count" = $duplicateInIntuneCount
}

$summaryRows += [PSCustomObject]@{
    "Metric" = "TotalRecords"
    "Category" = "Report1-EntraDevices"
    "Count" = @($report1).Count
}

$summaryRows += [PSCustomObject]@{
    "Metric" = "TotalRecords"
    "Category" = "Report2-IntuneDevices"
    "Count" = @($report2).Count
}

$summaryRows += [PSCustomObject]@{
    "Metric" = "TotalRecords"
    "Category" = "Report3-ComparisonRows"
    "Count" = @($comparisonRows).Count
}

Write-Host "Exporting reports..."
$report1 | Sort-Object { [string]$_."Device Name" }, { [string]$_."Object ID" } | Export-Csv -Path $report1Path -NoTypeInformation -Encoding UTF8
Write-Host "  Report 1 done."
$report2 | Sort-Object { [string]$_."Device Name" }, { [string]$_."Intune Device ID" } | Export-Csv -Path $report2Path -NoTypeInformation -Encoding UTF8
Write-Host "  Report 2 done."
$comparisonRows | Sort-Object { [string]$_."Device Name" }, { [string]$_."Match Status" }, { [string]$_."Entra Object ID" }, { [string]$_."Intune Entra Device ID" } | Export-Csv -Path $report3Path -NoTypeInformation -Encoding UTF8
Write-Host "  Report 3 done."
$summaryRows | Export-Csv -Path $report4Path -NoTypeInformation -Encoding UTF8

Write-Host "Done. Reports generated:"
Write-Host "  - $report1Path"
Write-Host "  - $report2Path"
Write-Host "  - $report3Path"
Write-Host "  - $report4Path"
