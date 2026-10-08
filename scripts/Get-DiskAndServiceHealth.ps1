<#
.SYNOPSIS
    Checks free disk space and the state of important services on one or more Windows computers.

.DESCRIPTION
    Produces one result object per check with a Status of OK, WARNING or
    CRITICAL, which makes the output easy to filter, export, or feed into a
    scheduled task / monitoring system.

      * Disk checks: every fixed disk, compared against -WarningPercentFree
        and -CriticalPercentFree.
      * Service checks: each service in -ServiceName must exist and be
        Running (CRITICAL otherwise).
      * Optional: -IncludeStoppedAutomatic flags any Automatic-start service
        that is not running (WARNING), minus a list of services that
        normally stop on their own.

    Read-only: nothing is restarted or changed.

.PARAMETER ComputerName
    Computers to check. Defaults to the local computer.

.PARAMETER WarningPercentFree
    Free-space percentage at or below which a disk is WARNING (default 20).

.PARAMETER CriticalPercentFree
    Free-space percentage at or below which a disk is CRITICAL (default 10).
    Must be lower than -WarningPercentFree.

.PARAMETER ServiceName
    Services that must be running.

.PARAMETER IncludeStoppedAutomatic
    Also report Automatic services that are stopped.

.PARAMETER ExcludeService
    Services ignored by -IncludeStoppedAutomatic (they commonly start/stop on demand).

.PARAMETER OutputPath
    Optional CSV path for the results.

.PARAMETER SetExitCode
    Exit with 0 (all OK), 1 (warnings) or 2 (critical) - useful for scheduled tasks and monitoring agents.

.PARAMETER Credential
    Alternate credentials for remote CIM sessions.

.EXAMPLE
    .\Get-DiskAndServiceHealth.ps1 | Where-Object Status -ne 'OK'

.EXAMPLE
    .\Get-DiskAndServiceHealth.ps1 -ComputerName FS01, APP01 -ServiceName LanmanServer, W32Time -IncludeStoppedAutomatic -OutputPath .\health.csv

.EXAMPLE
    powershell.exe -File .\Get-DiskAndServiceHealth.ps1 -SetExitCode -WarningPercentFree 15 -CriticalPercentFree 5

    Run from a scheduled task; the exit code reflects the worst result.

.OUTPUTS
    PSCustomObject with ComputerName, CheckType, Target, Detail and Status.

.NOTES
    Author : Joseph Pennington
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('CN', 'Name')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = [Environment]::MachineName,

    [ValidateRange(1, 99)]
    [int]$WarningPercentFree = 20,

    [ValidateRange(1, 99)]
    [int]$CriticalPercentFree = 10,

    [ValidateNotNullOrEmpty()]
    [string[]]$ServiceName = @('EventLog', 'Dnscache', 'W32Time', 'LanmanServer', 'WinRM'),

    [switch]$IncludeStoppedAutomatic,

    [string[]]$ExcludeService = @('gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'sppsvc', 'RemoteRegistry',
        'MapsBroker', 'TrustedInstaller', 'WbioSrvc', 'CDPSvc', 'tiledatamodelsvc', 'clr_optimization_v4.0.30319_32',
        'clr_optimization_v4.0.30319_64', 'ShellHWDetection', 'BITS', 'UsoSvc', 'wuauserv'),

    [ValidatePattern('\.csv$')]
    [string]$OutputPath,

    [switch]$SetExitCode,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

begin {
    if ($CriticalPercentFree -ge $WarningPercentFree) {
        throw "-CriticalPercentFree ($CriticalPercentFree) must be lower than -WarningPercentFree ($WarningPercentFree)."
    }
    if (-not (Get-Command -Name New-CimSession -ErrorAction SilentlyContinue)) {
        throw 'This script uses the CIM cmdlets and must run on Windows (Windows PowerShell 5.1 or PowerShell 7+ on Windows).'
    }

    function Get-DiskStatus {
        <#
        .SYNOPSIS
            Classifies a free-space percentage as OK, WARNING or CRITICAL.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)][double]$PercentFree,
            [Parameter(Mandatory = $true)][int]$Warning,
            [Parameter(Mandatory = $true)][int]$Critical
        )
        if ($PercentFree -le $Critical) { 'CRITICAL' }
        elseif ($PercentFree -le $Warning) { 'WARNING' }
        else { 'OK' }
    }

    function Get-ServiceCheckStatus {
        <#
        .SYNOPSIS
            Classifies a service: required services must be Running; others only warn.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [AllowNull()][string]$State,
            [switch]$Required
        )
        if ($State -eq 'Running') { 'OK' }
        elseif ($Required) { 'CRITICAL' }
        else { 'WARNING' }
    }

    function New-HealthResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an output object.')]
        [CmdletBinding()]
        param(
            [string]$ComputerName,
            [string]$CheckType,
            [string]$Target,
            [string]$Detail,
            [ValidateSet('OK', 'WARNING', 'CRITICAL')][string]$Status
        )
        [pscustomobject]@{
            ComputerName = $ComputerName
            CheckType    = $CheckType
            Target       = $Target
            Detail       = $Detail
            Status       = $Status
            CheckedAt    = Get-Date
        }
    }

    $results = New-Object -TypeName System.Collections.Generic.List[object]
}

process {
    foreach ($computer in $ComputerName) {
        $session = $null
        try {
            $sessionParams = @{ ErrorAction = 'Stop' }
            if ($computer -notin @('.', 'localhost', [Environment]::MachineName)) {
                $sessionParams['ComputerName'] = $computer
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sessionParams['Credential'] = $Credential }
            }
            $session = New-CimSession @sessionParams
            $cim = @{ CimSession = $session; ErrorAction = 'Stop' }

            foreach ($disk in Get-CimInstance @cim -ClassName Win32_LogicalDisk -Filter 'DriveType = 3') {
                if (-not $disk.Size) { continue }
                $pct = [math]::Round(100 * $disk.FreeSpace / $disk.Size, 1)
                $detail = '{0:N1} GB free of {1:N1} GB ({2}%)' -f ($disk.FreeSpace / 1GB), ($disk.Size / 1GB), $pct
                $results.Add((New-HealthResult -ComputerName $computer -CheckType 'Disk' -Target $disk.DeviceID -Detail $detail -Status (Get-DiskStatus -PercentFree $pct -Warning $WarningPercentFree -Critical $CriticalPercentFree)))
            }

            $services = @(Get-CimInstance @cim -ClassName Win32_Service)
            foreach ($name in $ServiceName) {
                $svc = $services | Where-Object { $_.Name -eq $name }
                if (-not $svc) {
                    $results.Add((New-HealthResult -ComputerName $computer -CheckType 'Service' -Target $name -Detail 'Service not found' -Status 'CRITICAL'))
                    continue
                }
                $results.Add((New-HealthResult -ComputerName $computer -CheckType 'Service' -Target $name -Detail "$($svc.DisplayName): $($svc.State) ($($svc.StartMode))" -Status (Get-ServiceCheckStatus -State $svc.State -Required)))
            }

            if ($IncludeStoppedAutomatic) {
                $stopped = $services | Where-Object {
                    $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and
                    $_.Name -notin $ServiceName -and $_.Name -notin $ExcludeService
                }
                foreach ($svc in $stopped) {
                    $results.Add((New-HealthResult -ComputerName $computer -CheckType 'AutoService' -Target $svc.Name -Detail "$($svc.DisplayName): $($svc.State)" -Status (Get-ServiceCheckStatus -State $svc.State)))
                }
            }
        }
        catch {
            Write-Warning -Message "Could not check ${computer}: $($_.Exception.Message)"
            $results.Add((New-HealthResult -ComputerName $computer -CheckType 'Connectivity' -Target $computer -Detail $_.Exception.Message -Status 'CRITICAL'))
        }
        finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }
}

end {
    if ($OutputPath) {
        $results | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Verbose -Message "Wrote $($results.Count) result(s) to $OutputPath"
    }
    $results

    if ($SetExitCode) {
        $code = 0
        if ($results.Status -contains 'CRITICAL') { $code = 2 }
        elseif ($results.Status -contains 'WARNING') { $code = 1 }
        exit $code
    }
}
