<#
.SYNOPSIS
    Collects hardware, operating system, disk, network and patch inventory from Windows computers.

.DESCRIPTION
    Queries one or more computers over CIM (WinRM for remote machines) and
    produces:
      * inventory-<timestamp>.csv - one row per computer
      * patches-<timestamp>.csv   - most recent hotfixes per computer
      * inventory-<timestamp>.html - a single self-contained HTML report

    Unreachable computers are not fatal; they appear in the report with
    Status = 'Unreachable' and the error message, so the run always finishes.
    The script is read-only: it makes no changes to the target machines.

.PARAMETER ComputerName
    One or more computer names. Accepts pipeline input (e.g. from a text
    file or Get-ADComputer). Defaults to the local computer.

.PARAMETER OutputPath
    Folder for the report files. Created if it does not exist.

.PARAMETER Format
    Csv, Html or Both (default).

.PARAMETER PatchCount
    How many of the most recent hotfixes to include per computer (default 25).

.PARAMETER Credential
    Alternate credentials for remote CIM sessions.

.EXAMPLE
    .\Get-SystemInventory.ps1

    Inventories the local computer and writes CSV + HTML to .\inventory.

.EXAMPLE
    Get-Content .\computers.txt | .\Get-SystemInventory.ps1 -OutputPath C:\Reports -Format Html

    Inventories every computer listed in computers.txt.

.EXAMPLE
    Get-ADComputer -Filter 'OperatingSystem -like "*Server*"' | .\Get-SystemInventory.ps1 -Credential (Get-Credential)

    Inventories all servers in the domain (binds the Name property from the pipeline).

.OUTPUTS
    PSCustomObject per computer (the same data written to the inventory CSV).

.NOTES
    Author : Joseph Pennington
    Remote targets need WinRM enabled (Enable-PSRemoting) and the firewall
    rule for Windows Remote Management allowed from the admin workstation.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('CN', 'Name', 'DNSHostName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = [Environment]::MachineName,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'inventory'),

    [ValidateSet('Csv', 'Html', 'Both')]
    [string]$Format = 'Both',

    [ValidateRange(1, 500)]
    [int]$PatchCount = 25,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

begin {
    if (-not (Get-Command -Name New-CimSession -ErrorAction SilentlyContinue)) {
        throw 'This script uses the CIM cmdlets and must run on Windows (Windows PowerShell 5.1 or PowerShell 7+ on Windows).'
    }
    function ConvertTo-InstalledOnDate {
        <#
        .SYNOPSIS
            Win32_QuickFixEngineering.InstalledOn is an inconsistently formatted string; parse it safely.
        #>
        [CmdletBinding()]
        [OutputType([datetime])]
        param([AllowNull()][AllowEmptyString()][object]$Value)
        if ($null -eq $Value -or "$Value" -eq '') { return $null }
        if ($Value -is [datetime]) { return $Value }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
        return $null
    }

    function Test-IsLocalComputer {
        [CmdletBinding()]
        [OutputType([bool])]
        param([Parameter(Mandatory = $true)][string]$Name)
        $Name -in @('.', 'localhost', '127.0.0.1', [Environment]::MachineName)
    }

    $inventory = New-Object -TypeName System.Collections.Generic.List[object]
    $patches = New-Object -TypeName System.Collections.Generic.List[object]
}

process {
    foreach ($computer in $ComputerName) {
        Write-Verbose -Message "Querying $computer"
        $session = $null
        try {
            $sessionParams = @{ ErrorAction = 'Stop' }
            if (-not (Test-IsLocalComputer -Name $computer)) {
                $sessionParams['ComputerName'] = $computer
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
                    $sessionParams['Credential'] = $Credential
                }
            }
            $session = New-CimSession @sessionParams
            $cim = @{ CimSession = $session; ErrorAction = 'Stop' }

            $os = Get-CimInstance @cim -ClassName Win32_OperatingSystem
            $cs = Get-CimInstance @cim -ClassName Win32_ComputerSystem
            $bios = Get-CimInstance @cim -ClassName Win32_BIOS
            $cpu = @(Get-CimInstance @cim -ClassName Win32_Processor)
            $disks = @(Get-CimInstance @cim -ClassName Win32_LogicalDisk -Filter 'DriveType = 3')
            $nics = @(Get-CimInstance @cim -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True')
            $hotfixes = @(Get-CimInstance @cim -ClassName Win32_QuickFixEngineering |
                    ForEach-Object {
                        [pscustomobject]@{
                            ComputerName = $computer
                            HotFixID     = $_.HotFixID
                            Description  = $_.Description
                            InstalledOn  = ConvertTo-InstalledOnDate -Value $_.InstalledOn
                            InstalledBy  = $_.InstalledBy
                        }
                    } | Sort-Object -Property InstalledOn -Descending)

            foreach ($fix in ($hotfixes | Select-Object -First $PatchCount)) { $patches.Add($fix) }

            $diskSummary = foreach ($d in $disks) {
                if ($d.Size) {
                    '{0} {1:N1}/{2:N1} GB free ({3:N0}%)' -f $d.DeviceID, ($d.FreeSpace / 1GB), ($d.Size / 1GB), (100 * $d.FreeSpace / $d.Size)
                }
            }
            $ipv4 = $nics | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
            $latestPatch = ($hotfixes | Where-Object { $_.InstalledOn } | Select-Object -First 1).InstalledOn

            $inventory.Add([pscustomobject]@{
                    ComputerName      = $cs.Name
                    Status            = 'OK'
                    Manufacturer      = $cs.Manufacturer
                    Model             = $cs.Model
                    SerialNumber      = $bios.SerialNumber
                    BIOSVersion       = $bios.SMBIOSBIOSVersion
                    CPU               = ($cpu | Select-Object -First 1).Name
                    CPUCount          = $cpu.Count
                    Cores             = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
                    LogicalProcessors = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
                    MemoryGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                    OSName            = $os.Caption
                    OSVersion         = $os.Version
                    OSBuild           = $os.BuildNumber
                    OSArchitecture    = $os.OSArchitecture
                    InstallDate       = $os.InstallDate
                    LastBoot          = $os.LastBootUpTime
                    UptimeDays        = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
                    Disks             = $diskSummary -join '; '
                    IPv4Addresses     = $ipv4 -join ', '
                    HotfixCount       = $hotfixes.Count
                    LatestHotfixDate  = $latestPatch
                    Error             = $null
                })
        }
        catch {
            Write-Warning -Message "Could not inventory ${computer}: $($_.Exception.Message)"
            $inventory.Add([pscustomobject]@{
                    ComputerName = $computer
                    Status       = 'Unreachable'
                    Error        = $_.Exception.Message
                })
        }
        finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }
}

end {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # Make every row have every column so CSV/HTML headers are consistent.
    $columns = $inventory | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique
    $rows = $inventory | Select-Object -Property $columns

    if ($Format -in 'Csv', 'Both') {
        $invCsv = Join-Path -Path $OutputPath -ChildPath "inventory-$stamp.csv"
        $rows | Export-Csv -LiteralPath $invCsv -NoTypeInformation -Encoding UTF8
        Write-Verbose -Message "Wrote $invCsv"
        if ($patches.Count -gt 0) {
            $patchCsv = Join-Path -Path $OutputPath -ChildPath "patches-$stamp.csv"
            $patches | Export-Csv -LiteralPath $patchCsv -NoTypeInformation -Encoding UTF8
            Write-Verbose -Message "Wrote $patchCsv"
        }
    }

    if ($Format -in 'Html', 'Both') {
        $css = @'
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
 h1 { font-size: 20px; } h2 { font-size: 16px; margin-top: 28px; }
 table { border-collapse: collapse; font-size: 12px; }
 th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; vertical-align: top; }
 th { background: #f0f3f6; }
 tr:nth-child(even) { background: #fafafa; }
</style>
'@
        $summaryHtml = $rows | Select-Object ComputerName, Status, Manufacturer, Model, OSName, OSBuild, MemoryGB, UptimeDays, Disks, IPv4Addresses, LatestHotfixDate, Error |
            ConvertTo-Html -Fragment -PreContent '<h2>Systems</h2>'
        $patchHtml = $patches | Select-Object ComputerName, HotFixID, Description, InstalledOn |
            ConvertTo-Html -Fragment -PreContent "<h2>Recent hotfixes (latest $PatchCount per system)</h2>"
        $htmlPath = Join-Path -Path $OutputPath -ChildPath "inventory-$stamp.html"
        ConvertTo-Html -Head $css -Title 'System Inventory' `
            -PreContent ("<h1>System inventory</h1><p>Generated {0:yyyy-MM-dd HH:mm} - {1} system(s)</p>" -f (Get-Date), $inventory.Count) `
            -PostContent ($summaryHtml + $patchHtml) |
            Out-File -LiteralPath $htmlPath -Encoding UTF8
        Write-Verbose -Message "Wrote $htmlPath"
    }

    $inventory
}
