param(
    [string]$Domain,
    [string]$Server
)

# Validate that the ActiveDirectory module is loaded
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Host "Error: ActiveDirectory module could not be loaded. Please ensure RSAT is installed." -ForegroundColor Red
    exit 1
}

# Get domain information - use parameters if provided
try {
    if ($Domain) {
        $domain = Get-ADDomain -Identity $Domain -ErrorAction Stop
    } else {
        $domain = Get-ADDomain -ErrorAction Stop
    }
    
    if ($Server) {
        $RootDSE = Get-ADRootDSE -Server $Server -ErrorAction Stop
        $forest = Get-ADForest -Identity $domain.Forest -Server $Server -ErrorAction Stop
        $DCList = Get-ADDomainController -Filter * -Server $Server -ErrorAction Stop
    } else {
        $RootDSE = Get-ADRootDSE -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        $DCList = Get-ADDomainController -Filter * -ErrorAction Stop
    }
    
    $UserCount = Get-ADUser -ResultSetSize $null -Filter * -ErrorAction Stop
} catch {
    Write-Host "Error gathering AD information: $_" -ForegroundColor Red
    exit 1
}

write-host ' '
write-host ' ' 
Write-host 'All Domain Controllers in Domain' -ForegroundColor yellow

# General Domain Info
Write-host ' '
write-host 'Total Users Objects in AD: ' -ForegroundColor green -nonewline
write-host (@($UserCount).Count)

# Get name and IP address of each Domain Controller
Foreach ($DC in $DCList) {
    try {
        Write-host ' '
        $DCDetail = Get-ADComputer $DC.Name -Properties * -ErrorAction Stop | Select-Object Name, IPv4Address
        $DCTime = Get-ADRootDSE -Server $DC.Name -ErrorAction Stop
        Write-host 'Server Name: ' -ForegroundColor green -nonewline
        write-host $DCDetail.Name 
        
        Write-host 'IP Address: ' -ForegroundColor green -nonewline
        write-host $DCDetail.IPv4Address
        
        Write-host 'Server Date/Time: ' -ForegroundColor green -nonewline
        write-host $DCTime.currentTime
        
        # Get disk space information
        Write-host 'Disk Space Info: ' -ForegroundColor green
        try {
            $Disk = Get-WmiObject win32_LogicalDisk -ComputerName $DC.Name -Filter "DriveType=3" -ErrorAction Stop | 
                Select-Object DeviceID, `
                    @{Name="Size(GB)";Expression={"{0:N1}" -f ($_.size/1gb)}}, `
                    @{Name="FreeSpace(GB)";Expression={"{0:N1}" -f($_.freespace/1gb)}}, `
                    @{Name="% FreeSpace";Expression={"{0:N2}%" -f(($_.freespace/$_.size)*100)}}
            $Disk | Format-Table -AutoSize
        } catch {
            Write-Host "  Unable to retrieve disk information from $($DC.Name): $_" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Error processing DC $($DC.Name): $_" -ForegroundColor Red
    }
    Write-host ' '
}


Write-host ' '
Write-host 'Domain and Forest Function Levels' -ForegroundColor yellow 

# Forest Info
Write-host 'Forest Function Level: ' -ForegroundColor green -nonewline
Write-host $RootDSE.forestFunctionality 

Write-host 'Domain Function Level: ' -ForegroundColor green -nonewline
Write-host $RootDSE.domainFunctionality

Write-host ' '

# List Global Catalogs
Write-host 'Global Catalog Servers: ' -ForegroundColor green
$forest.GlobalCatalogs | Format-Table -Property @{Name="Name";Expression={$_}} -AutoSize

Write-host ' ' 

# List FSMO Role Holders
Write-host 'Schema Master: ' -ForegroundColor green -nonewline
Write-host $forest.SchemaMaster

Write-host 'PDC Emulator: ' -ForegroundColor green -nonewline
Write-host $domain.PDCEmulator 

Write-host 'RID Master: ' -ForegroundColor green -nonewline
Write-host $domain.RIDMaster

Write-host 'Infrastructure Master: ' -ForegroundColor green -nonewline
Write-host $domain.InfrastructureMaster

Write-host 'Domain Naming Master: ' -ForegroundColor green -nonewline
Write-host $forest.DomainNamingMaster

# Empty line for formatting
Write-host ' '
Write-host ' '


# Global Catalog Readiness and Sync status info
# Check Catalog Readiness    
Write-host 'Global Catalog Readiness Check' -ForegroundColor Yellow
Foreach ($DC in $DCList) {
    try {
        $GCReady = Get-ADRootDSE -Properties * -Server $DC.Name -ErrorAction Stop
        if ($GCReady.isGlobalCatalogReady -eq $TRUE) {
            Write-host $DC.Name -nonewline
            Write-host ' - Global Catalog is READY' -ForegroundColor green 
        } else {
            Write-host $DC.Name -nonewline
            Write-host ' - Global Catalog is NOT READY' -ForegroundColor red
        }
    } catch {
        Write-host $DC.Name -nonewline
        Write-host ' - Unable to check: $_' -ForegroundColor Yellow
    }
}

# Empty line for formatting
Write-host ' '
Write-host ' '

# Check Sync Status
Write-host 'Global Catalog Synchronization Stats' -ForegroundColor Yellow     
Foreach ($DC in $DCList) {
    try {
        $GCReady = Get-ADRootDSE -Properties * -Server $DC.Name -ErrorAction Stop
        if ($GCReady.isSynchronized -eq $TRUE) {
            Write-host $DC.Name -nonewline
            Write-host ' - Global Catalog is synchronized' -ForegroundColor green
        } else {
            Write-host $DC.Name -nonewline
            Write-host ' - Global Catalog is NOT synchronized' -ForegroundColor red
        }
    } catch {
        Write-host $DC.Name -nonewline
        Write-host ' - Unable to check: $_' -ForegroundColor Yellow
    }
}
    
# Empty line for formatting
Write-host ' '
Write-host ' '
# Domain Replication Status
Write-host 'Domain Replication Status' -ForegroundColor Yellow
try {
    repadmin /replsum /errorsonly
} catch {
    Write-Host "Error running replication check: $_" -ForegroundColor Yellow
}

# Empty line for formatting
Write-host ' '
Write-host ' '

# DCDIAG - Display only errors
Write-host 'Domain Controller Diagnostic Results' -ForegroundColor Yellow
Write-host 'Showing errors only...' -ForegroundColor Cyan
Write-host ' '

try {
    # Run dcdiag and capture output
    $dcdiagOutput = dcdiag /e /q /c 2>&1
    
    # Filter for error lines (lines containing "failed", "error", etc.)
    $errorLines = @()
    $dcdiagOutput | ForEach-Object {
        if ($_ -match '\[FAILED\]|\[ERROR\]|failed|error' -or $_ -match '^\s*DC:') {
            $errorLines += $_
        }
    }
    
    if ($errorLines.Count -gt 0) {
        $errorLines | ForEach-Object {
            if ($_ -match '\[FAILED\]') {
                Write-Host $_ -ForegroundColor Red
            } elseif ($_ -match 'error') {
                Write-Host $_ -ForegroundColor Yellow
            } else {
                Write-Host $_
            }
        }
    } else {
        Write-Host "No errors found in dcdiag results" -ForegroundColor Green
    }
} catch {
    Write-Host "Error running dcdiag: $_" -ForegroundColor Red
}

Write-host ' '
Write-host 'AD Environment Overview Complete' -ForegroundColor Green