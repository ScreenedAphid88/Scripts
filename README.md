This is a repository for scripts that I create and/or find useful.  Script names should be formatted with 'ProductName - WhatScriptDoes'. 

## Active Directory HTML report

[Active Directory - HTML Overview Report.ps1](./Active%20Directory%20-%20HTML%20Overview%20Report.ps1)
creates a self-contained HTML dashboard. It requires Windows PowerShell 5.1 or
PowerShell 7 on Windows, RSAT's ActiveDirectory module, directory read access,
and permission to query remote disks through authenticated WSMan CIM sessions.
Disk access may require additional permissions; do not disable authentication or
certificate checks to make a failed query work.

```powershell
# Default Quick diagnostics against the selected controller, with interactive progress.
& ".\Active Directory - HTML Overview Report.ps1" -OpenReport

# Quick diagnostics against a specific domain and controller.
& ".\Active Directory - HTML Overview Report.ps1" `
    -Domain contoso.com -Server DC01.contoso.com -ThrottleLimit 4 -Verbose

# Opt-in comprehensive enterprise-wide diagnostics, with a longer deadline.
& ".\Active Directory - HTML Overview Report.ps1" `
    -DiagnosticsLevel Full -DiagnosticsTimeoutSeconds 1800

# A report prepared for review before sharing.
& ".\Active Directory - HTML Overview Report.ps1" `
    -DiagnosticsLevel None -RedactSensitiveData -ProtectOutput `
    -OutputPath "C:\Reports\AD-Overview.html"
```

| Option | Default | Behavior |
|---|---|---|
| `DiagnosticsLevel` | `Quick` | `Quick` targets the selected DC with connectivity, advertising, and replication tests; `Full` opts in to enterprise-wide replication and comprehensive DCDIAG (`/e /q /c`), which tests every forest DC sequentially and may need a longer `DiagnosticsTimeoutSeconds`; `None` explicitly skips diagnostics. |
| `ThrottleLimit` | `4` | Maximum simultaneous collection jobs, configurable from 1 to 16. Jobs are process-isolated for reliable cancellation and Windows PowerShell 5.1 compatibility. Startup overhead may outweigh parallelism gains for small environments. |
| `OperationTimeoutSeconds` | `60` | Per-job wall-clock deadline, including startup; inventory is one job and user count and each DC health/disk check are separate jobs. Increase this for large or slow directories. |
| `DiagnosticsTimeoutSeconds` | `300` | Deadline for each native diagnostic process. |
| `IncludeDiagnosticDetails` | Off | Include complete native output and detailed collection errors. DCDIAG `/q` output is retained without language-dependent filtering. |
| `IncludeCreatorIdentity` | Off | Include the generating user and workstation in the report. |
| `RedactSensitiveData` | Off | Mask known internal domain/server names, sites, creator identity, and IPv4 addresses in rendered text. Best-effort only: unexpected names or other identifiers in raw diagnostics may remain. Review before sharing. |
| `ProtectOutput` | Off | Before writing report contents, disable inherited file permissions and grant access only to the current user, Administrators, and SYSTEM. Requires a filesystem supporting Windows ACLs; failure stops report creation. The directory's permissions and privileged access still matter. |
| `Force` | Off | Allow replacement of an existing output file. |
| `OpenReport` | Off | Open the completed report using its associated application. |

Progress is shown with `Write-Progress`; `-Verbose` adds phase details, warnings
are sent to the warning stream, and completion is sent to the information
stream. The success stream returns a `FileInfo` for the saved HTML.
Reports include a confidentiality notice and collection-warning summary.
Missing tools, inaccessible controllers, and timeouts are not marked healthy;
non-GC controllers are excluded from the GC-readiness denominator. Repadmin's
exit code indicates command completion, not independently verified replication
health. Request diagnostic details when investigating its results.

Directory health, the domain controller table, and disk capacity cover every
domain controller in the forest, labeled by domain. The selected domain's DCs
are listed through the selected server; other forest domains are located by DNS
name. If another domain's DCs cannot be listed, the report records a collection
warning and continues; failure to list the selected domain's DCs stops the
report. The user count, functional levels, and FSMO details remain specific to
the selected domain.

User counting exclusively streams `Get-ADUser` results through `Measure-Object`,
using the selected controller and a subtree search under the selected domain's
distinguished name, without a result-count limit. The script no longer uses
direct `DirectoryEntry`/`DirectorySearcher` LDAP queries. The `UserCountMethod`
parameter has been removed; omit it from existing commands. Query failures
remain explicit and are not returned as zero users. Increase
`OperationTimeoutSeconds` if a large directory needs more collection time.

RootDSE health flags are unwrapped from AD property collections before Boolean
conversion. Missing, multi-valued, or invalid flags fail the health check rather
than being treated as healthy.

If DCDIAG reaches its deadline, use `-DiagnosticsLevel Quick` for the selected
controller's connectivity, advertising, and replication tests, or increase
`-DiagnosticsTimeoutSeconds` (for example, `900`) to retain full enterprise-wide
coverage. The maximum is `7200` seconds. A timeout remains an unavailable check,
not a healthy result. Use `-IncludeDiagnosticDetails` to retain native diagnostic
output and detailed collection warnings in the report.

Reports are first written to a temporary sibling file and then moved into place.
Native tools are invoked from their Windows system location, not command lookup.
Network output paths trigger a warning. There are no external report assets or
embedded credentials. No directory objects or DC configuration are modified.

The [sample report](./Active%20Directory%20-%20Sample%20Overview%20Report.html)
uses fictional data. Run the local fixture checks with:

```powershell
& ".\Active Directory - HTML Overview Report.Tests.ps1"
Invoke-ScriptAnalyzer -Path ".\Active Directory - HTML Overview Report.ps1"
```
