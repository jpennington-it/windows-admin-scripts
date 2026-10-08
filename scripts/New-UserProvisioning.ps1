<#
.SYNOPSIS
    Creates Active Directory user accounts from a CSV file.

.DESCRIPTION
    Reads new-hire records from a CSV file, validates every row, generates a
    unique sAMAccountName (first initial + last name), creates the account in
    the target OU and adds it to the listed groups.

    Safety defaults:
      * Supports -WhatIf and -Confirm. Always run with -WhatIf first.
      * Accounts are created DISABLED with a random password that is never
        displayed, returned, or logged, and "change password at next logon"
        is set. The help desk enables the account and sets a temporary
        password as part of the normal onboarding hand-off.
      * Invalid rows are skipped and logged; one bad row never stops the run.
      * Every action (including -WhatIf runs) is written to a log file.

    Expected CSV columns:
      FirstName   (required)
      LastName    (required)
      Department, Title, EmployeeID (optional)
      OU          (optional - distinguished name; falls back to -DefaultOU)
      Groups      (optional - semicolon separated group names)
      Manager     (optional - manager's sAMAccountName)

.PARAMETER CsvPath
    Path to the CSV file of users to create.

.PARAMETER UpnSuffix
    Domain suffix for the userPrincipalName, e.g. corp.example.com.

.PARAMETER DefaultOU
    Distinguished name of the OU used when a row has no OU value.

.PARAMETER LogPath
    Log file path. Defaults to .\logs\UserProvisioning-<timestamp>.log next
    to the script.

.PARAMETER Server
    Optional domain controller to target, so all reads and writes hit the
    same DC and avoid replication timing issues.

.EXAMPLE
    .\New-UserProvisioning.ps1 -CsvPath .\samples\new-users.sample.csv -UpnSuffix corp.example.com -DefaultOU 'OU=Staff,DC=corp,DC=example,DC=com' -WhatIf

    Dry run: validates the CSV and shows what would be created without changing anything.

.EXAMPLE
    .\New-UserProvisioning.ps1 -CsvPath .\new-hires.csv -UpnSuffix corp.example.com -DefaultOU 'OU=Staff,DC=corp,DC=example,DC=com' -Verbose |
        Export-Csv .\provisioning-results.csv -NoTypeInformation

    Creates the accounts and saves a per-row result report.

.OUTPUTS
    PSCustomObject with Line, SamAccountName, DisplayName, OU, Status and Message.

.NOTES
    Author : Joseph Pennington
    Requires the ActiveDirectory module (RSAT) and rights to create users in
    the target OU. Lab/portfolio script - test in a non-production domain first.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (Test-Path -LiteralPath $_ -PathType Leaf) { $true }
            else { throw "CSV file '$_' was not found." }
        })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$')]
    [string]$UpnSuffix,

    [ValidatePattern('^(OU|CN)=[^,]+(,(OU|CN)=[^,]+)*,DC=[^,]+(,DC=[^,]+)*$')]
    [string]$DefaultOU,

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'logs') -ChildPath ('UserProvisioning-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))),

    [ValidateNotNullOrEmpty()]
    [string]$Server
)

#region Helper functions

function Write-ProvisioningLog {
    <#
    .SYNOPSIS
        Appends a timestamped line to the log file and echoes it to the matching stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($script:LogFile) {
        # Logging must still happen during -WhatIf runs.
        Add-Content -LiteralPath $script:LogFile -Value $line -WhatIf:$false -Confirm:$false
    }
    switch ($Level) {
        'INFO' { Write-Verbose -Message $Message }
        default { Write-Warning -Message "$Level - $Message" }
    }
}

function ConvertTo-UnaccentedText {
    <#
    .SYNOPSIS
        Converts accented characters to their plain equivalents (e.g. an accented e becomes a plain e).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($char in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function ConvertTo-SamAccountName {
    <#
    .SYNOPSIS
        Builds a base logon name: first initial + last name, lowercase ASCII, max 20 characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$FirstName,
        [Parameter(Mandatory = $true)][string]$LastName,
        [ValidateRange(1, 20)][int]$MaxLength = 20
    )
    $first = (ConvertTo-UnaccentedText -Text $FirstName).ToLowerInvariant() -replace '[^a-z0-9]', ''
    $last = (ConvertTo-UnaccentedText -Text $LastName).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $first -or -not $last) {
        throw "Cannot build a logon name from '$FirstName $LastName'."
    }
    $sam = $first.Substring(0, 1) + $last
    if ($sam.Length -gt $MaxLength) { $sam = $sam.Substring(0, $MaxLength) }
    $sam
}

function Get-UniqueSamAccountName {
    <#
    .SYNOPSIS
        Appends 2, 3, ... to a base name until -ExistsCheck reports it is free.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)][scriptblock]$ExistsCheck,
        [ValidateRange(2, 999)][int]$MaxAttempts = 99
    )
    $candidate = $BaseName
    $counter = 1
    while (& $ExistsCheck $candidate) {
        $counter++
        if ($counter -gt $MaxAttempts) {
            throw "No free logon name found for base '$BaseName' after $MaxAttempts attempts."
        }
        $suffix = [string]$counter
        $candidate = $BaseName.Substring(0, [Math]::Min($BaseName.Length, 20 - $suffix.Length)) + $suffix
    }
    $candidate
}

function Test-ProvisioningRow {
    <#
    .SYNOPSIS
        Returns a list of validation problems for one CSV row (empty when the row is valid).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Row,
        [AllowEmptyString()][string]$OU
    )
    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($field in 'FirstName', 'LastName') {
        $value = $Row.$field
        if ([string]::IsNullOrWhiteSpace($value)) {
            $problems.Add("$field is required")
        }
        elseif ($value -notmatch "^[\p{L}][\p{L}' .-]*$") {
            $problems.Add("$field '$value' contains unexpected characters")
        }
    }
    if ([string]::IsNullOrWhiteSpace($OU)) {
        $problems.Add('No OU in row and no -DefaultOU supplied')
    }
    elseif ($OU -notmatch '^(OU|CN)=[^,]+(,(OU|CN)=[^,]+)*,DC=[^,]+(,DC=[^,]+)*$') {
        $problems.Add("OU '$OU' is not a valid distinguished name")
    }
    if ($Row.EmployeeID -and $Row.EmployeeID -notmatch '^\d{3,10}$') {
        $problems.Add("EmployeeID '$($Row.EmployeeID)' must be 3-10 digits")
    }
    $problems.ToArray()
}

function New-RandomPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creates an in-memory SecureString.')]
    <#
    .SYNOPSIS
        Returns a cryptographically random SecureString that meets AD complexity rules.
    .DESCRIPTION
        Uses RandomNumberGenerator with rejection sampling (no modulo bias) and
        builds the SecureString directly, so the password never exists as a
        plain [string].
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([ValidateRange(14, 128)][int]$Length = 20)

    $classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+?')
    $alphabet = -join $classes
    $limit = 256 - (256 % $alphabet.Length)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $chars = New-Object -TypeName 'System.Collections.Generic.List[char]'
            $buffer = New-Object -TypeName byte[] -ArgumentList 1
            while ($chars.Count -lt $Length) {
                $rng.GetBytes($buffer)
                if ($buffer[0] -lt $limit) { $chars.Add($alphabet[$buffer[0] % $alphabet.Length]) }
            }
            $hasAllClasses = $true
            foreach ($class in $classes) {
                if (-not ($chars | Where-Object { $class.IndexOf($_) -ge 0 })) { $hasAllClasses = $false }
            }
        } until ($hasAllClasses)

        $secure = New-Object -TypeName System.Security.SecureString
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $chars.Clear()
        $secure.MakeReadOnly()
        $secure
    }
    finally {
        $rng.Dispose()
    }
}

#endregion

#region Main

$script:LogFile = $LogPath
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
}

Write-ProvisioningLog -Message "Run started by $env:USERNAME. CSV: $CsvPath. WhatIf: $([bool]$WhatIfPreference)"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-ProvisioningLog -Level ERROR -Message 'ActiveDirectory module not found. Install RSAT: Active Directory tools.'
    throw 'The ActiveDirectory PowerShell module is required.'
}
Import-Module -Name ActiveDirectory -ErrorAction Stop

$adParams = @{}
if ($Server) { $adParams['Server'] = $Server }

$rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no data rows." }

$missingColumns = @('FirstName', 'LastName') | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missingColumns) { throw "CSV is missing required column(s): $($missingColumns -join ', ')" }

# Names reserved during this run, so duplicate rows don't collide (even under -WhatIf).
$reserved = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
$existsCheck = {
    param($Name)
    if ($reserved.Contains($Name)) { return $true }
    [bool](Get-ADUser @adParams -Filter "sAMAccountName -eq '$Name'" -ErrorAction Stop)
}

$results = New-Object -TypeName System.Collections.Generic.List[object]
$lineNumber = 1  # header is line 1

foreach ($row in $rows) {
    $lineNumber++
    $ou = if ($row.PSObject.Properties['OU'] -and $row.OU) { $row.OU.Trim() } else { $DefaultOU }
    $displayName = ('{0} {1}' -f $row.FirstName, $row.LastName).Trim()
    $result = [pscustomobject]@{
        Line           = $lineNumber
        SamAccountName = $null
        DisplayName    = $displayName
        OU             = $ou
        Status         = $null
        Message        = $null
    }

    $problems = @(Test-ProvisioningRow -Row $row -OU $ou)
    if ($problems.Count -gt 0) {
        $result.Status = 'Skipped'
        $result.Message = $problems -join '; '
        Write-ProvisioningLog -Level WARN -Message "Line $lineNumber skipped: $($result.Message)"
        $results.Add($result)
        continue
    }

    try {
        $sam = Get-UniqueSamAccountName -BaseName (ConvertTo-SamAccountName -FirstName $row.FirstName -LastName $row.LastName) -ExistsCheck $existsCheck
        [void]$reserved.Add($sam)
        $result.SamAccountName = $sam

        $newUser = @{
            Name                  = $displayName
            GivenName             = $row.FirstName.Trim()
            Surname               = $row.LastName.Trim()
            DisplayName           = $displayName
            SamAccountName        = $sam
            UserPrincipalName     = "$sam@$UpnSuffix"
            Path                  = $ou
            AccountPassword       = New-RandomPassword
            Enabled               = $false
            ChangePasswordAtLogon = $true
            ErrorAction           = 'Stop'
        }
        foreach ($optional in 'Department', 'Title', 'EmployeeID') {
            if ($row.PSObject.Properties[$optional] -and $row.$optional) { $newUser[$optional] = $row.$optional.Trim() }
        }
        if ($row.PSObject.Properties['Manager'] -and $row.Manager) {
            $newUser['Manager'] = (Get-ADUser @adParams -Identity $row.Manager.Trim() -ErrorAction Stop).DistinguishedName
        }

        if ($PSCmdlet.ShouldProcess("$displayName ($sam) in $ou", 'Create disabled AD user')) {
            New-ADUser @adParams @newUser
            Write-ProvisioningLog -Message "Line ${lineNumber}: created $sam ($displayName) in $ou"

            $groupErrors = @()
            $groups = if ($row.PSObject.Properties['Groups'] -and $row.Groups) { $row.Groups -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
            foreach ($group in $groups) {
                try {
                    Add-ADGroupMember @adParams -Identity $group -Members $sam -ErrorAction Stop
                    Write-ProvisioningLog -Message "Line ${lineNumber}: added $sam to '$group'"
                }
                catch {
                    $groupErrors += $group
                    Write-ProvisioningLog -Level WARN -Message "Line ${lineNumber}: could not add $sam to '$group': $($_.Exception.Message)"
                }
            }
            $result.Status = if ($groupErrors) { 'CreatedWithWarnings' } else { 'Created' }
            $result.Message = if ($groupErrors) { "Group add failed: $($groupErrors -join ', ')" } else { "Groups: $($groups.Count)" }
        }
        else {
            $result.Status = 'WhatIf'
            $result.Message = "Would create $sam ($($newUser.UserPrincipalName))"
            Write-ProvisioningLog -Message "Line ${lineNumber}: WhatIf - would create $sam in $ou"
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        Write-ProvisioningLog -Level ERROR -Message "Line ${lineNumber} ($displayName) failed: $($_.Exception.Message)"
    }
    $results.Add($result)
}

$summary = $results | Group-Object -Property Status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
Write-ProvisioningLog -Message "Run finished. $($summary -join ', '). Log: $LogPath"
$results

#endregion
