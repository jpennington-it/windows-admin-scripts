<#
.SYNOPSIS
    Reports Active Directory user (and optionally computer) accounts that have not logged on recently.

.DESCRIPTION
    REPORT ONLY - this script never disables, moves or deletes anything.

    An account is reported as stale when:
      * its lastLogonTimestamp is older than -DaysInactive days, or
      * it has never logged on and was created more than -DaysInactive days ago.

    Accounts created recently that have not logged on yet (e.g. new hires)
    are deliberately not reported.

    Note: lastLogonTimestamp is replicated, but only updated when the stored
    value is older than ~9-14 days (ms-DS-Logon-Time-Sync-Interval). Treat
    results as accurate to roughly two weeks, which is why values below 30
    days produce a warning.

.PARAMETER DaysInactive
    Inactivity threshold in days (default 90).

.PARAMETER SearchBase
    Distinguished name of the OU to search. Defaults to the whole domain.

.PARAMETER IncludeComputers
    Also report stale computer accounts.

.PARAMETER IncludeDisabled
    Include accounts that are already disabled (excluded by default).

.PARAMETER OutputPath
    Optional CSV path to save the report.

.PARAMETER Server
    Optional domain controller to query.

.EXAMPLE
    .\Get-ADStaleAccounts.ps1 -DaysInactive 90 | Format-Table SamAccountName, LastLogonDate, DaysSinceLogon, Reason

.EXAMPLE
    .\Get-ADStaleAccounts.ps1 -SearchBase 'OU=Staff,DC=corp,DC=example,DC=com' -IncludeComputers -OutputPath .\stale-accounts.csv

    Saves a CSV for review by the account owners' managers before any cleanup.

.OUTPUTS
    PSCustomObject per stale account.

.NOTES
    Author : Joseph Pennington
    Requires the ActiveDirectory module (RSAT) and read access to the directory.
    Review service accounts and shared mailboxes carefully - they may not log
    on interactively and still be in use.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [ValidatePattern('^(OU|CN|DC)=[^,]+(,(OU|CN|DC)=[^,]+)*$')]
    [string]$SearchBase,

    [switch]$IncludeComputers,

    [switch]$IncludeDisabled,

    [ValidatePattern('\.csv$')]
    [string]$OutputPath,

    [ValidateNotNullOrEmpty()]
    [string]$Server
)

function Get-StaleAccountReason {
    <#
    .SYNOPSIS
        Returns why an account is stale, or $null if it is not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][Nullable[datetime]]$LastLogon,
        [AllowNull()][Nullable[datetime]]$Created,
        [Parameter(Mandatory = $true)][datetime]$Cutoff
    )
    if ($LastLogon) {
        if ($LastLogon -lt $Cutoff) { return ('No logon since {0:yyyy-MM-dd}' -f $LastLogon) }
        return $null
    }
    if ($Created -and $Created -lt $Cutoff) {
        return ('Never logged on (created {0:yyyy-MM-dd})' -f $Created)
    }
    return $null
}

function ConvertFrom-LastLogonTimestamp {
    <#
    .SYNOPSIS
        Converts the AD lastLogonTimestamp (FILETIME Int64) to a DateTime; 0 or empty means never.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [int64]$Value -le 0) { return $null }
    [datetime]::FromFileTime([int64]$Value)
}

if ($DaysInactive -lt 30) {
    Write-Warning -Message 'lastLogonTimestamp can lag by up to ~14 days; thresholds under 30 days may produce false positives.'
}

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw 'The ActiveDirectory PowerShell module (RSAT) is required.'
}
Import-Module -Name ActiveDirectory -ErrorAction Stop

$cutoff = (Get-Date).AddDays(-$DaysInactive)
$now = Get-Date
$query = @{
    Filter      = if ($IncludeDisabled) { '*' } else { 'Enabled -eq $true' }
    Properties  = @('lastLogonTimestamp', 'whenCreated', 'PasswordLastSet', 'Description', 'Enabled')
    ErrorAction = 'Stop'
}
if ($SearchBase) { $query['SearchBase'] = $SearchBase }
if ($Server) { $query['Server'] = $Server }

$accounts = New-Object -TypeName System.Collections.Generic.List[object]
try {
    Get-ADUser @query | ForEach-Object { $_ | Add-Member -NotePropertyName AccountType -NotePropertyValue 'User' -PassThru } |
        ForEach-Object { $accounts.Add($_) }
    if ($IncludeComputers) {
        $query['Properties'] += 'OperatingSystem'
        Get-ADComputer @query | ForEach-Object { $_ | Add-Member -NotePropertyName AccountType -NotePropertyValue 'Computer' -PassThru } |
            ForEach-Object { $accounts.Add($_) }
    }
}
catch {
    throw "Directory query failed: $($_.Exception.Message)"
}

Write-Verbose -Message "Evaluated $($accounts.Count) account(s) against cutoff $($cutoff.ToString('yyyy-MM-dd'))"

$report = foreach ($account in $accounts) {
    $lastLogon = ConvertFrom-LastLogonTimestamp -Value $account.lastLogonTimestamp
    $reason = Get-StaleAccountReason -LastLogon $lastLogon -Created $account.whenCreated -Cutoff $cutoff
    if (-not $reason) { continue }
    [pscustomobject]@{
        AccountType       = $account.AccountType
        SamAccountName    = $account.SamAccountName
        Name              = $account.Name
        Enabled           = $account.Enabled
        LastLogonDate     = $lastLogon
        DaysSinceLogon    = if ($lastLogon) { [int]($now - $lastLogon).TotalDays } else { $null }
        PasswordLastSet   = $account.PasswordLastSet
        WhenCreated       = $account.whenCreated
        Description       = $account.Description
        Reason            = $reason
        DistinguishedName = $account.DistinguishedName
    }
}
$report = @($report | Sort-Object -Property @{ Expression = { if ($null -eq $_.DaysSinceLogon) { [int]::MaxValue } else { $_.DaysSinceLogon } }; Descending = $true })

if ($OutputPath) {
    $report | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Verbose -Message "Wrote $($report.Count) row(s) to $OutputPath"
}
Write-Verbose -Message "$($report.Count) stale account(s) found. No changes were made."
$report
