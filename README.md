# windows-admin-scripts

PowerShell scripts for common Windows / Active Directory administration
tasks: onboarding users from a CSV, collecting system inventory, finding
stale accounts, and checking disk and service health.

I wrote these as portfolio/lab work to practice writing PowerShell the way
I'd want to find it on a shared admin team: comment-based help on every
script, parameter validation, `-WhatIf` on anything that changes state,
logging, and errors that are handled instead of ending the run halfway
through.

| Script | Purpose | Changes anything? |
|--------|---------|-------------------|
| [`New-UserProvisioning.ps1`](scripts/New-UserProvisioning.ps1) | Create AD users from a CSV, with group membership and manager | **Yes**, supports `-WhatIf` / `-Confirm` |
| [`Get-SystemInventory.ps1`](scripts/Get-SystemInventory.ps1) | Hardware, OS, disks, IPs and hotfixes → CSV and HTML report | No |
| [`Get-ADStaleAccounts.ps1`](scripts/Get-ADStaleAccounts.ps1) | Report users/computers inactive for N days | No (report only) |
| [`Get-DiskAndServiceHealth.ps1`](scripts/Get-DiskAndServiceHealth.ps1) | Disk free-space thresholds and required-service checks with exit codes | No |

## Requirements

- Windows, with Windows PowerShell 5.1 or PowerShell 7+ (the inventory and
  health scripts use CIM and stop with a clear error on other platforms;
  the Pester tests run anywhere)
- **AD scripts:** the `ActiveDirectory` module (RSAT: *Active Directory
  Domain Services and Lightweight Directory Tools*). Provisioning needs
  rights to create users in the target OU; the stale-account report only
  needs read access.
- **Remote inventory/health checks:** WinRM enabled on the targets
  (`Enable-PSRemoting`) and allowed through the firewall from the admin
  workstation. Local checks need no remoting.

If scripts are blocked by execution policy, unblock the downloaded files
rather than turning the policy off:

```powershell
Get-ChildItem .\scripts\*.ps1 | Unblock-File
```

Every script has full help:

```powershell
Get-Help .\scripts\New-UserProvisioning.ps1 -Full
```

## Usage

### New-UserProvisioning.ps1

CSV columns: `FirstName`, `LastName` (required), plus optional
`Department`, `Title`, `EmployeeID`, `OU`, `Groups` (semicolon-separated)
and `Manager` (sAMAccountName). See
[`samples/new-users.sample.csv`](samples/new-users.sample.csv) (fake
data; the last row is intentionally invalid to show how bad rows are
handled).

```powershell
# 1. Always dry-run first
.\scripts\New-UserProvisioning.ps1 -CsvPath .\samples\new-users.sample.csv `
    -UpnSuffix corp.example.com -DefaultOU 'OU=Staff,DC=corp,DC=example,DC=com' -WhatIf

# 2. Run for real, pinned to one DC, and keep a results report
.\scripts\New-UserProvisioning.ps1 -CsvPath .\new-hires.csv -UpnSuffix corp.example.com `
    -DefaultOU 'OU=Staff,DC=corp,DC=example,DC=com' -Server dc01.corp.example.com -Verbose |
    Export-Csv .\provisioning-results.csv -NoTypeInformation
```

Example result objects from a `-WhatIf` run against the sample CSV (OU column
omitted for width):

```text
Line SamAccountName DisplayName         Status  Message
---- -------------- -----------         ------  -------
   2 jrivera        Jordan Rivera       WhatIf  Would create jrivera (jrivera@corp.example.com)
   3 jrivera2       Jamie Rivera        WhatIf  Would create jrivera2 (jrivera2@corp.example.com)
   4 cnguyen        Casey Nguyen        WhatIf  Would create cnguyen (cnguyen@corp.example.com)
   5 moneil         Morgan O'Neil       WhatIf  Would create moneil (moneil@corp.example.com)
   6 rduboismartin  Renée Dubois-Martin WhatIf  Would create rduboismartin (rduboismartin@corp.example.com)
   7                Taylor              Skipped LastName is required
```

How it behaves:

- Logon names are first initial + last name, lowercased, accents and
  punctuation removed, max 20 characters. Collisions with existing
  accounts *or earlier rows in the same file* get `2`, `3`, ... appended.
- Accounts are created **disabled**, with **change password at next
  logon** set and a random password generated with a cryptographic RNG.
  The password is built directly into a `SecureString` and is never shown,
  returned or logged. Enabling the account and issuing a temporary
  password stays part of the normal onboarding hand-off.
- Each row is validated (required names, OU distinguished-name format,
  EmployeeID format). Bad rows are skipped and logged; a failed group add
  marks the row `CreatedWithWarnings` instead of failing it.
- A timestamped log is written to `.\scripts\logs\` (override with
  `-LogPath`), including during `-WhatIf` runs.

### Get-SystemInventory.ps1

```powershell
.\scripts\Get-SystemInventory.ps1                                   # local machine
Get-Content .\computers.txt | .\scripts\Get-SystemInventory.ps1 -OutputPath .\reports
Get-ADComputer -Filter 'OperatingSystem -like "*Server*"' |
    .\scripts\Get-SystemInventory.ps1 -Format Html -Credential (Get-Credential)
```

Writes `inventory-<timestamp>.csv`, `patches-<timestamp>.csv` and a
self-contained `inventory-<timestamp>.html`. Collected per machine:
manufacturer/model/serial, BIOS, CPU/cores, RAM, OS edition/build,
install date, last boot/uptime, fixed-disk usage, IPv4 addresses, hotfix
count and most recent hotfix date. Machines that can't be reached show up
in the report as `Unreachable` with the error, so one offline host doesn't
stop the run.

### Get-ADStaleAccounts.ps1

```powershell
.\scripts\Get-ADStaleAccounts.ps1 -DaysInactive 90 |
    Format-Table SamAccountName, LastLogonDate, DaysSinceLogon, Reason

.\scripts\Get-ADStaleAccounts.ps1 -SearchBase 'OU=Staff,DC=corp,DC=example,DC=com' `
    -IncludeComputers -OutputPath .\stale-accounts.csv
```

An account is reported if its last logon is older than the threshold, or
if it has *never* logged on and was created before the threshold (so
recent new hires aren't flagged). Disabled accounts are excluded unless
`-IncludeDisabled` is used.

### Get-DiskAndServiceHealth.ps1

```powershell
.\scripts\Get-DiskAndServiceHealth.ps1 | Where-Object Status -ne 'OK'

.\scripts\Get-DiskAndServiceHealth.ps1 -ComputerName FS01, APP01 `
    -ServiceName LanmanServer, W32Time -IncludeStoppedAutomatic -OutputPath .\health.csv

# From a scheduled task: exit code 0 = OK, 1 = warning, 2 = critical
powershell.exe -NoProfile -File .\scripts\Get-DiskAndServiceHealth.ps1 -SetExitCode
```

```text
ComputerName CheckType Target   Detail                                    Status
------------ --------- ------   ------                                    ------
FS01         Disk      C:       41.2 GB free of 126.4 GB (32.6%)          OK
FS01         Disk      D:       38.9 GB free of 499.9 GB (7.8%)           CRITICAL
FS01         Service   W32Time  Windows Time: Running (Auto)              OK
APP01        Service   Spooler  Print Spooler: Stopped (Auto)             CRITICAL
```

*(Illustrative output from a run with `-ServiceName W32Time, Spooler`.)*

## Safety notes

- **Run `-WhatIf` first** for anything that creates or changes objects, and
  test in a lab or non-production OU before using real data.
- The reporting scripts are read-only. `Get-ADStaleAccounts.ps1` contains no
  disable/move/delete commands on purpose - stale-account cleanup should be
  a reviewed change, not a side effect of a report. Service accounts and
  shared mailboxes often don't log on interactively and can look stale.
- `lastLogonTimestamp` only replicates every ~9-14 days, so treat
  "last logon" as accurate to about two weeks.
- Generated logs and reports can contain real names and hostnames;
  `.gitignore` excludes them so they are never committed.
- No credentials are stored in any script. Use `-Credential (Get-Credential)`
  or run from an account with the needed rights.

## Testing

Tests use [Pester 5](https://pester.dev/) and run on Windows, Linux or
macOS without a domain:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed

# Optional lint
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\scripts -Recurse
```

What the tests cover:

- every script parses, uses `[CmdletBinding()]`, and documents every parameter
- helper functions (logon-name generation, row validation, password
  generator, stale-account logic, disk thresholds) are pulled out of the
  scripts with the PowerShell AST and unit-tested directly
- end-to-end runs of the provisioning and stale-account scripts against a
  **stub `ActiveDirectory` module**, confirming `-WhatIf` makes no changes,
  accounts are created disabled, and passwords never reach the log

The inventory and health scripts depend on live CIM data, so beyond
parsing/help and their helper logic they need a real Windows host to test.

## What I learned

- Writing `SupportsShouldProcess` correctly, including making logging
  ignore `-WhatIf` so dry runs still leave an audit trail.
- Comment-based help placement matters: a `#Requires` line *above* the help
  block silently breaks `Get-Help` for a script.
- Handling directory data defensively: accented names, duplicate names
  within one import, and `lastLogonTimestamp` replication lag.
- Making scripts testable without the real environment by keeping logic in
  small functions and stubbing the external module.

## Roadmap

- [ ] Offboarding script (disable, strip groups, move to a disabled OU) with `-WhatIf` and an approval CSV
- [ ] Optional email/Teams summary for the health check
- [ ] Package the helpers as a module with a manifest
- [ ] GitHub Actions workflow running Pester and PSScriptAnalyzer

## License

[MIT](LICENSE) © Joseph Pennington
