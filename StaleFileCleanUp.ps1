<#
.SYNOPSIS
Archives stale scan files and deletes expired archived scans.

.DESCRIPTION
Moves files older than one day from C:\ScanFolder directly into
C:\ExpiredScans. Source folders are not moved or recreated. Files in
C:\ExpiredScans that are older than seven days are deleted and recorded in
C:\ScanReports\DeletedScans.csv.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scanFolder = 'C:\ScanFolder'
$expiredScansFolder = 'C:\ExpiredScans'
$reportFolder = 'C:\ScanReports'
$deletionLog = Join-Path -Path $reportFolder -ChildPath 'DeletedScans.csv'
$archiveCutoff = (Get-Date).AddDays(-1)
$deletionCutoff = (Get-Date).AddDays(-7)

if (-not (Test-Path -LiteralPath $scanFolder -PathType Container)) {
	throw "Scan folder does not exist: $scanFolder"
}

foreach ($folder in @($expiredScansFolder, $reportFolder)) {
	if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
		New-Item -Path $folder -ItemType Directory -Force | Out-Null
	}
}

if ((Test-Path -LiteralPath $deletionLog -PathType Leaf) -and
	(Get-Item -LiteralPath $deletionLog).Length -gt 0) {
	$existingLog = @(Import-Csv -LiteralPath $deletionLog)
	if ($existingLog.Count -gt 0 -and
		'CreationDate' -notin $existingLog[0].PSObject.Properties.Name) {
		$existingLog | Select-Object FileName, Owner,
			@{ Name = 'CreationDate'; Expression = { $null } }, DeletionDate |
			Export-Csv -LiteralPath $deletionLog -NoTypeInformation
	}
}

$staleScanFiles = Get-ChildItem -LiteralPath $scanFolder -File -Recurse -Force |
	Where-Object { $_.LastWriteTime -lt $archiveCutoff }

foreach ($file in $staleScanFiles) {
	$destinationPath = Join-Path -Path $expiredScansFolder -ChildPath $file.Name

	if (Test-Path -LiteralPath $destinationPath) {
		Write-Warning "Skipped '$($file.FullName)' because '$destinationPath' already exists."
		continue
	}

	try {
		Move-Item -LiteralPath $file.FullName -Destination $destinationPath
		Write-Verbose "Moved '$($file.FullName)' to '$destinationPath'."
	}
	catch {
		Write-Error "Failed to move '$($file.FullName)': $_"
	}
}

$expiredFiles = Get-ChildItem -LiteralPath $expiredScansFolder -File -Recurse -Force |
	Where-Object { $_.LastWriteTime -lt $deletionCutoff }

foreach ($file in $expiredFiles) {
	try {
		try {
			$owner = (Get-Acl -LiteralPath $file.FullName).Owner
		}
		catch {
			$owner = 'Unknown'
			Write-Warning "Could not determine the owner of '$($file.FullName)': $_"
		}

		$fileName = $file.Name
		$fullPath = $file.FullName
		$creationDate = $file.CreationTime.ToString('o')
		Remove-Item -LiteralPath $fullPath -Force

		[pscustomobject]@{
			FileName     = $fileName
			Owner        = $owner
			CreationDate = $creationDate
			DeletionDate = (Get-Date).ToString('o')
		} | Export-Csv -LiteralPath $deletionLog -Append -NoTypeInformation

		Write-Verbose "Deleted '$fullPath' and appended the deletion to '$deletionLog'."
	}
	catch {
		Write-Error "Failed to delete or log '$($file.FullName)': $_"
	}
}
