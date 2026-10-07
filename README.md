This is a repository for scripts that I create and/or find useful.  Script names should be formatted with 'ProductName - WhatScriptDoes'. 

## Active Directory HTML report

[Active Directory - HTML Overview Report.ps1](./Active%20Directory%20-%20HTML%20Overview%20Report.ps1)
creates a self-contained HTML dashboard. It requires Windows PowerShell 5.1 or
PowerShell 7 on Windows, RSAT's ActiveDirectory module, directory read access,
and permission to query remote disks through authenticated WSMan CIM sessions.
Disk access may require additional permissions; do not disable authentication or
certificate checks to make a failed query work.

```powershell
# Original full enterprise-wide diagnostics, with interactive progress.
& ".\Active Directory - HTML Overview Report.ps1" -OpenReport

# Faster diagnostics against one selected controller.
& ".\Active Directory - HTML Overview Report.ps1" `
    -Domain contoso.com -Server DC01.contoso.com `
    -DiagnosticsLevel Quick -ThrottleLimit 4 -Verbose

# A report prepared for review before sharing.
& ".\Active Directory - HTML Overview Report.ps1" `
    -DiagnosticsLevel None -RedactSensitiveData -ProtectOutput `
    -OutputPath "C:\Reports\AD-Overview.html"
```

| Option | Default | Behavior |
|---|---|---|
| `DiagnosticsLevel` | `Full` | `Full` runs enterprise-wide replication and comprehensive DCDIAG; `Quick` targets the selected DC with connectivity, advertising, and replication tests; `None` explicitly skips diagnostics. |
| `ThrottleLimit` | `4` | Maximum simultaneous collection jobs, configurable from 1 to 16. Jobs are process-isolated for reliable cancellation and Windows PowerShell 5.1 compatibility. Startup overhead may outweigh parallelism gains for small environments. |
| `OperationTimeoutSeconds` | `60` | Per-job wall-clock deadline, including startup; inventory is one job and user count and each DC health/disk check are separate jobs. Increase this for large or slow directories. |
| `DiagnosticsTimeoutSeconds` | `300` | Deadline for each native diagnostic process. |
| `UserCountMethod` | `LDAP` | Paged, signed/sealed LDAP subtree search requesting only `objectGUID`, with referral chasing disabled to stay within the selected domain; `AD` streams `Get-ADUser` results through `Measure-Object`. Neither counts users in other domains. |
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

RootDSE health flags are unwrapped from AD property collections before Boolean
conversion. Missing, multi-valued, or invalid flags fail the health check rather
than being treated as healthy. LDAP resources are disposed through `psbase`
to avoid directory lookups during PowerShell member resolution.
LDAP uses the path-only `DirectoryEntry` constructor and then sets authentication
flags through `psbase`, preserving default Windows credentials. Passing
PowerShell `$null` to the constructor's username/password string arguments
converts them to empty credentials and can cause an unauthenticated-bind error.

If DCDIAG reaches its deadline, use `-DiagnosticsLevel Quick` for the selected
controller's connectivity, advertising, and replication tests, or increase
`-DiagnosticsTimeoutSeconds` (for example, `900`) to retain full enterprise-wide
coverage. The maximum is `7200` seconds. A timeout remains an unavailable check,
not a healthy result. If LDAP user counting still reports an operations error,
use `-UserCountMethod AD` and review the detailed warning; this explicitly selects
the AD cmdlet path rather than silently falling back after an LDAP failure.
LDAP failures include the target server and search base, plus the HRESULT and
extended LDAP error when available. Disabling referrals avoids failures while
following references outside the selected domain; it does not resolve all
authentication, connectivity, or directory-service errors.

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
