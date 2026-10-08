#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester 5 tests. These run on any OS with PowerShell 7 (or Windows PowerShell 5.1)
    and do NOT need Active Directory, WinRM, or admin rights:

      * every script parses cleanly and has comment-based help and [CmdletBinding()]
      * the pure helper functions are extracted from each script via the AST and
        unit-tested in isolation, so no script body is ever executed.

    Run:  Invoke-Pester -Path ./tests -Output Detailed
#>

BeforeDiscovery {
    $scriptsDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'scripts'
    $scriptCases = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

BeforeAll {
    $script:ScriptsDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'scripts'
    $script:SamplesDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'samples'

    function Get-ScriptFunctionDefinition {
        <# Returns the source text of the named functions defined inside a script file. #>
        param([string]$Path, [string[]]$Name)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $Name
            }, $true) | ForEach-Object { $_.Extent.Text }
    }
}

Describe 'Script quality: <Name>' -ForEach $scriptCases {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $parseErrors = $errors
        $help = $ast.GetHelpContent()
        $paramBlock = $ast.ParamBlock
    }

    It 'parses without syntax errors' {
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'has a synopsis, description and at least one example' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        $help.Examples.Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        $documented = $help.Parameters.Keys | ForEach-Object { $_.ToUpperInvariant() }
        foreach ($p in $paramBlock.Parameters) {
            $p.Name.VariablePath.UserPath.ToUpperInvariant() | Should -BeIn $documented
        }
    }

    It 'uses [CmdletBinding()]' {
        $paramBlock.Attributes.TypeName.Name | Should -Contain 'CmdletBinding'
    }

    It 'contains no hard-coded credentials' {
        $content = Get-Content -LiteralPath $Path -Raw
        $content | Should -Not -Match '(?i)password\s*=\s*["''][^"'']+["'']'
        $content | Should -Not -Match '(?i)ConvertTo-SecureString\s+.*-AsPlainText'
    }
}

Describe 'New-UserProvisioning.ps1' {
    BeforeAll {
        $path = Join-Path -Path $script:ScriptsDir -ChildPath 'New-UserProvisioning.ps1'
        $names = 'ConvertTo-UnaccentedText', 'ConvertTo-SamAccountName', 'Get-UniqueSamAccountName', 'Test-ProvisioningRow', 'New-RandomPassword'
        foreach ($definition in Get-ScriptFunctionDefinition -Path $path -Name $names) {
            . ([scriptblock]::Create($definition))
        }
        $validOU = 'OU=Staff,DC=corp,DC=example,DC=com'
    }

    It 'supports -WhatIf and -Confirm' {
        $cmd = Get-Command -Name $path
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
    }

    Context 'ConvertTo-SamAccountName' {
        It 'builds first initial + last name in lowercase' {
            ConvertTo-SamAccountName -FirstName 'Jordan' -LastName 'Rivera' | Should -Be 'jrivera'
        }
        It 'strips accents, apostrophes and hyphens' {
            ConvertTo-SamAccountName -FirstName 'Renée' -LastName "Dubois-Martin" | Should -Be 'rduboismartin'
            ConvertTo-SamAccountName -FirstName 'Morgan' -LastName "O'Neil" | Should -Be 'moneil'
        }
        It 'truncates to 20 characters' {
            (ConvertTo-SamAccountName -FirstName 'Alexandria' -LastName 'Montgomery-Wellington').Length | Should -Be 20
        }
        It 'throws when nothing usable remains' {
            { ConvertTo-SamAccountName -FirstName '!!' -LastName 'Rivera' } | Should -Throw
        }
    }

    Context 'Get-UniqueSamAccountName' {
        It 'returns the base name when it is free' {
            Get-UniqueSamAccountName -BaseName 'jrivera' -ExistsCheck { param($n) $false } | Should -Be 'jrivera'
        }
        It 'appends a number when taken' {
            $taken = @('jrivera', 'jrivera2')
            Get-UniqueSamAccountName -BaseName 'jrivera' -ExistsCheck { param($n) $n -in $taken } | Should -Be 'jrivera3'
        }
        It 'keeps the result within 20 characters' {
            $base = 'abcdefghijklmnopqrst'
            $result = Get-UniqueSamAccountName -BaseName $base -ExistsCheck { param($n) $n -eq $base }
            $result | Should -Be 'abcdefghijklmnopqrs2'
        }
        It 'gives up after MaxAttempts' {
            { Get-UniqueSamAccountName -BaseName 'x' -ExistsCheck { $true } -MaxAttempts 5 } | Should -Throw
        }
    }

    Context 'Test-ProvisioningRow' {
        It 'accepts a valid row' {
            $row = [pscustomobject]@{ FirstName = 'Casey'; LastName = 'Nguyen'; EmployeeID = '100233' }
            Test-ProvisioningRow -Row $row -OU $validOU | Should -BeNullOrEmpty
        }
        It 'rejects a missing last name' {
            $row = [pscustomobject]@{ FirstName = 'Taylor'; LastName = '' }
            Test-ProvisioningRow -Row $row -OU $validOU | Should -Contain 'LastName is required'
        }
        It 'rejects a malformed OU' {
            $row = [pscustomobject]@{ FirstName = 'Casey'; LastName = 'Nguyen' }
            (Test-ProvisioningRow -Row $row -OU 'Staff/Users') -join ' ' | Should -Match 'not a valid distinguished name'
        }
        It 'rejects a missing OU' {
            $row = [pscustomobject]@{ FirstName = 'Casey'; LastName = 'Nguyen' }
            (Test-ProvisioningRow -Row $row -OU '') -join ' ' | Should -Match 'No OU'
        }
        It 'rejects a non-numeric EmployeeID' {
            $row = [pscustomobject]@{ FirstName = 'Casey'; LastName = 'Nguyen'; EmployeeID = 'ABC' }
            (Test-ProvisioningRow -Row $row -OU $validOU) -join ' ' | Should -Match 'EmployeeID'
        }
        It 'flags exactly one invalid row in the sample CSV' {
            $rows = Import-Csv -LiteralPath (Join-Path -Path $script:SamplesDir -ChildPath 'new-users.sample.csv') -Encoding UTF8
            $invalid = $rows | Where-Object {
                $ou = if ($_.OU) { $_.OU } else { $validOU }
                (Test-ProvisioningRow -Row $_ -OU $ou).Count -gt 0
            }
            @($invalid).Count | Should -Be 1
            $invalid.FirstName | Should -Be 'Taylor'
        }
    }

    Context 'New-RandomPassword' {
        It 'returns a read-only SecureString of the requested length' {
            $pw = New-RandomPassword -Length 24
            $pw | Should -BeOfType [securestring]
            $pw.Length | Should -Be 24
            $pw.IsReadOnly() | Should -BeTrue
        }
        It 'meets complexity (upper, lower, digit, symbol)' {
            $plain = [System.Net.NetworkCredential]::new('', (New-RandomPassword)).Password
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -Match '\d'
            $plain | Should -Match '[^A-Za-z0-9]'
        }
        It 'rejects lengths below 14' {
            { New-RandomPassword -Length 8 } | Should -Throw
        }
    }
}

Describe 'Get-ADStaleAccounts.ps1' {
    BeforeAll {
        $path = Join-Path -Path $script:ScriptsDir -ChildPath 'Get-ADStaleAccounts.ps1'
        foreach ($definition in Get-ScriptFunctionDefinition -Path $path -Name 'Get-StaleAccountReason', 'ConvertFrom-LastLogonTimestamp') {
            . ([scriptblock]::Create($definition))
        }
        $cutoff = (Get-Date '2026-01-01')
    }

    It 'is report-only (no Disable/Remove/Set/Move cmdlets)' {
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match '(?i)\b(Disable|Remove|Set|Move)-AD'
    }
    It 'flags an account whose last logon is before the cutoff' {
        Get-StaleAccountReason -LastLogon (Get-Date '2025-06-15') -Created (Get-Date '2020-01-01') -Cutoff $cutoff |
            Should -Be 'No logon since 2025-06-15'
    }
    It 'ignores an account that logged on recently' {
        Get-StaleAccountReason -LastLogon (Get-Date '2026-02-01') -Created (Get-Date '2020-01-01') -Cutoff $cutoff |
            Should -BeNullOrEmpty
    }
    It 'flags an old account that never logged on' {
        Get-StaleAccountReason -LastLogon $null -Created (Get-Date '2025-03-01') -Cutoff $cutoff |
            Should -Match '^Never logged on'
    }
    It 'ignores a new account that has not logged on yet' {
        Get-StaleAccountReason -LastLogon $null -Created (Get-Date '2026-02-10') -Cutoff $cutoff |
            Should -BeNullOrEmpty
    }
    It 'converts lastLogonTimestamp and treats 0 as never' {
        $ft = (Get-Date '2025-06-15T12:00:00').ToFileTime()
        (ConvertFrom-LastLogonTimestamp -Value $ft).Date | Should -Be (Get-Date '2025-06-15').Date
        ConvertFrom-LastLogonTimestamp -Value 0 | Should -BeNullOrEmpty
        ConvertFrom-LastLogonTimestamp -Value $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-DiskAndServiceHealth.ps1' {
    BeforeAll {
        $path = Join-Path -Path $script:ScriptsDir -ChildPath 'Get-DiskAndServiceHealth.ps1'
        foreach ($definition in Get-ScriptFunctionDefinition -Path $path -Name 'Get-DiskStatus', 'Get-ServiceCheckStatus') {
            . ([scriptblock]::Create($definition))
        }
    }

    It 'classifies disk free space: <Pct>% -> <Expected>' -ForEach @(
        @{ Pct = 55; Expected = 'OK' }
        @{ Pct = 20; Expected = 'WARNING' }
        @{ Pct = 12.5; Expected = 'WARNING' }
        @{ Pct = 10; Expected = 'CRITICAL' }
        @{ Pct = 0; Expected = 'CRITICAL' }
    ) {
        Get-DiskStatus -PercentFree $Pct -Warning 20 -Critical 10 | Should -Be $Expected
    }

    It 'treats a stopped required service as CRITICAL' {
        Get-ServiceCheckStatus -State 'Stopped' -Required | Should -Be 'CRITICAL'
    }
    It 'treats a stopped optional automatic service as WARNING' {
        Get-ServiceCheckStatus -State 'Stopped' | Should -Be 'WARNING'
    }
    It 'treats a running service as OK' {
        Get-ServiceCheckStatus -State 'Running' -Required | Should -Be 'OK'
    }
    It 'rejects a critical threshold that is not below the warning threshold' {
        { & $path -WarningPercentFree 10 -CriticalPercentFree 15 } | Should -Throw '*must be lower*'
    }
}

Describe 'Get-SystemInventory.ps1' {
    BeforeAll {
        $path = Join-Path -Path $script:ScriptsDir -ChildPath 'Get-SystemInventory.ps1'
        foreach ($definition in Get-ScriptFunctionDefinition -Path $path -Name 'ConvertTo-InstalledOnDate') {
            . ([scriptblock]::Create($definition))
        }
    }

    It 'only accepts Csv, Html or Both for -Format' {
        (Get-Command -Name $path).Parameters['Format'].Attributes.ValidValues | Should -Be @('Csv', 'Html', 'Both')
    }
    It 'parses hotfix dates and tolerates blanks' {
        (ConvertTo-InstalledOnDate -Value '2026-03-14').Date | Should -Be (Get-Date '2026-03-14').Date
        ConvertTo-InstalledOnDate -Value '' | Should -BeNullOrEmpty
        ConvertTo-InstalledOnDate -Value 'not a date' | Should -BeNullOrEmpty
    }
}

Describe 'End-to-end runs against a stub ActiveDirectory module' {
    # A fake ActiveDirectory module is placed first on PSModulePath so the real
    # scripts run unmodified without a domain. The stubs record every call.
    BeforeAll {
        $stubRoot = Join-Path -Path $TestDrive -ChildPath 'modules'
        $stubDir = Join-Path -Path $stubRoot -ChildPath 'ActiveDirectory'
        New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $stubDir -ChildPath 'ActiveDirectory.psm1') -Value @'
$global:StubAD = @{ Created = New-Object System.Collections.Generic.List[object]; GroupAdds = New-Object System.Collections.Generic.List[object] }
function Get-ADUser {
    [CmdletBinding()]
    param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$SearchBase, [string]$Server)
    if ($Identity) { return [pscustomobject]@{ SamAccountName = $Identity; DistinguishedName = "CN=$Identity,OU=Staff,DC=corp,DC=example,DC=com" } }
    if ($Filter -match "sAMAccountName -eq '(.+)'") { if ($Matches[1] -eq 'cnguyen') { return [pscustomobject]@{ SamAccountName = 'cnguyen' } } return }
    if ($global:StubAD.Users) { return $global:StubAD.Users }
}
function New-ADUser {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Name, $GivenName, $Surname, $DisplayName, $SamAccountName, $UserPrincipalName, $Path,
          $AccountPassword, $Enabled, $ChangePasswordAtLogon, $Department, $Title, $EmployeeID, $Manager, $Server)
    if ($PSCmdlet.ShouldProcess($SamAccountName)) { $global:StubAD.Created.Add([pscustomobject]$PSBoundParameters) }
}
function Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Identity, $Members, $Server)
    if ($Identity -eq 'GG-Missing') { throw "Cannot find group '$Identity'" }
    if ($PSCmdlet.ShouldProcess($Identity)) { $global:StubAD.GroupAdds.Add("$Identity<-$Members") }
}
function Get-ADComputer { [CmdletBinding()] param([string]$Filter, [string[]]$Properties, [string]$SearchBase, [string]$Server) }
'@
        $script:OriginalModulePath = $env:PSModulePath
        $env:PSModulePath = $stubRoot + [IO.Path]::PathSeparator + $env:PSModulePath
        $script:Provision = Join-Path -Path $script:ScriptsDir -ChildPath 'New-UserProvisioning.ps1'
        $script:Csv = Join-Path -Path $script:SamplesDir -ChildPath 'new-users.sample.csv'
        $script:DefaultOU = 'OU=Staff,DC=corp,DC=example,DC=com'
    }
    AfterAll {
        $env:PSModulePath = $script:OriginalModulePath
        Remove-Module -Name ActiveDirectory -ErrorAction SilentlyContinue
        Remove-Variable -Name StubAD -Scope Global -ErrorAction SilentlyContinue
    }

    It 'makes no changes under -WhatIf but still logs and reports every row' {
        $log = Join-Path -Path $TestDrive -ChildPath 'whatif.log'
        $results = & $script:Provision -CsvPath $script:Csv -UpnSuffix 'corp.example.com' -DefaultOU $script:DefaultOU -LogPath $log -WhatIf -WarningAction SilentlyContinue 6>$null
        $global:StubAD.Created.Count | Should -Be 0
        $global:StubAD.GroupAdds.Count | Should -Be 0
        @($results | Where-Object Status -eq 'WhatIf').Count | Should -Be 5
        ($results | Where-Object Status -eq 'Skipped').Line | Should -Be 7
        $results.SamAccountName | Should -Contain 'jrivera'
        $results.SamAccountName | Should -Contain 'jrivera2'   # second Rivera gets a suffix
        $results.SamAccountName | Should -Contain 'cnguyen2'   # cnguyen already "exists" in the stub
        Get-Content -LiteralPath $log -Raw | Should -Match 'Run finished'
    }

    It 'creates disabled accounts that must change password, and never logs the password' {
        $log = Join-Path -Path $TestDrive -ChildPath 'real.log'
        $results = & $script:Provision -CsvPath $script:Csv -UpnSuffix 'corp.example.com' -DefaultOU $script:DefaultOU -LogPath $log -Confirm:$false -WarningAction SilentlyContinue
        @($results | Where-Object Status -eq 'Created').Count | Should -Be 5
        $global:StubAD.Created.Count | Should -Be 5
        foreach ($u in $global:StubAD.Created) {
            $u.Enabled | Should -BeFalse
            $u.ChangePasswordAtLogon | Should -BeTrue
            $u.AccountPassword | Should -BeOfType [securestring]
            $u.UserPrincipalName | Should -Match '@corp\.example\.com$'
        }
        ($global:StubAD.Created | Where-Object SamAccountName -eq 'jrivera').Manager | Should -Match '^CN=mlopez,'
        $global:StubAD.GroupAdds | Should -Contain 'GG-VPN-Users<-jrivera'
        Get-Content -LiteralPath $log -Raw | Should -Not -Match '(?i)password'
    }

    It 'reports only stale accounts, oldest first' {
        $now = Get-Date
        $global:StubAD.Users = @(
            [pscustomobject]@{ SamAccountName = 'active'; Name = 'Active User'; Enabled = $true; lastLogonTimestamp = $now.AddDays(-5).ToFileTime(); whenCreated = $now.AddYears(-2); DistinguishedName = 'CN=a' }
            [pscustomobject]@{ SamAccountName = 'old'; Name = 'Old User'; Enabled = $true; lastLogonTimestamp = $now.AddDays(-200).ToFileTime(); whenCreated = $now.AddYears(-3); DistinguishedName = 'CN=b' }
            [pscustomobject]@{ SamAccountName = 'never'; Name = 'Never User'; Enabled = $true; lastLogonTimestamp = $null; whenCreated = $now.AddDays(-120); DistinguishedName = 'CN=c' }
            [pscustomobject]@{ SamAccountName = 'newhire'; Name = 'New Hire'; Enabled = $true; lastLogonTimestamp = $null; whenCreated = $now.AddDays(-3); DistinguishedName = 'CN=d' }
            [pscustomobject]@{ SamAccountName = 'stale'; Name = 'Stale User'; Enabled = $true; lastLogonTimestamp = $now.AddDays(-95).ToFileTime(); whenCreated = $now.AddYears(-1); DistinguishedName = 'CN=e' }
        )
        $csvOut = Join-Path -Path $TestDrive -ChildPath 'stale.csv'
        $report = & (Join-Path -Path $script:ScriptsDir -ChildPath 'Get-ADStaleAccounts.ps1') -DaysInactive 90 -OutputPath $csvOut
        $report.SamAccountName | Should -Be @('never', 'old', 'stale')
        (Import-Csv -LiteralPath $csvOut).Count | Should -Be 3
    }
}

Describe 'Platform guard' -Skip:($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    It '<Name> stops with a clear message when CIM is unavailable' -ForEach @(
        @{ Name = 'Get-SystemInventory.ps1' }
        @{ Name = 'Get-DiskAndServiceHealth.ps1' }
    ) {
        $scriptPath = Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'scripts') -ChildPath $Name
        { & $scriptPath -WarningAction SilentlyContinue } | Should -Throw '*must run on Windows*'
    }
}
