#Requires -Version 5.1
<#
.SYNOPSIS
    Export, import, or delete vSphere Distributed Switch (VDS) port groups interactively.

.DESCRIPTION
    Connects to a vCenter Server and presents interactive menus to select a VDS
    and the port groups to act on. Supports three modes:

        Export  - Export selected port groups to zip files in the backup directory.
        Import  - Import selected zip files to a chosen VDS, with optional renaming.
        Delete  - Delete selected port groups from a chosen VDS (with confirmation
                  and an optional safety export first).

    Port group pickers show the VLAN configuration and port count of every port
    group. All activity is written to both the console and a timestamped log file.

    Credentials are encrypted and saved as <hostname>.cred next to the script
    using Export-Clixml (DPAPI-protected, tied to the current Windows user).

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server.

.PARAMETER Mode
    The operation to perform: Export, Import, or Delete.
    If omitted, an interactive menu is shown.

.PARAMETER BackupDirectory
    Directory used to store exported zip files (Export mode) or read them from
    (Import mode). Defaults to a "Backups" subfolder next to the script.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER NamePrefix
    Optional prefix to prepend to imported port group names (Import mode only).
    e.g. -NamePrefix "NEW-" renames "HB-VLAN100-PRD" to "NEW-HB-VLAN100-PRD".

.PARAMETER NameSuffix
    Optional suffix to append to imported port group names (Import mode only).
    e.g. -NameSuffix "-v2" renames "HB-VLAN100-PRD" to "HB-VLAN100-PRD-v2".

.PARAMETER CredentialPath
    Path to the encrypted credential file. Defaults to <vCenterServer>.cred
    next to the script.

.PARAMETER ResetCredentials
    Force a new credential prompt even if a saved credential file exists.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation. For lab use with self-signed certificates.

.EXAMPLE
    # Interactive - pick the mode from a menu
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local

.EXAMPLE
    # Export selected port groups to the default backup directory
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Export

.EXAMPLE
    # Import selected port groups from a specific backup directory
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Import -BackupDirectory C:\Backups\VDS

.EXAMPLE
    # Import and rename port groups with a prefix and suffix
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Import -NamePrefix "NEW-" -NameSuffix "-v2"

.EXAMPLE
    # Delete selected port groups (offers a safety export first)
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Delete

.EXAMPLE
    # Lab environment with self-signed certificate
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Export -SkipCertificateValidation

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Version  : 1.1.2
    Requires : VCF.PowerCLI 9.0+ (recommended) or VMware.PowerCLI 13+
    Tested   : vSphere 9

.CHANGELOG
    v1.1.2  2026-07-07  Paul van Dieen
        - Import name-clash check is now datacenter-wide instead of per target
          switch - vCenter requires distributed port group names to be unique
          per datacenter, so importing onto a new VDS still clashed with the
          source switch's port groups
        - When clashes are detected and no -NamePrefix/-NameSuffix was given,
          import mode now prompts for a prefix/suffix interactively
        - Skip messages name the switch that already holds the clashing name

    v1.1.1  2026-07-07  Paul van Dieen
        - When cloning a new VDS from an existing one, the uplink PORT NAMES
          are now cloned as well - exported teaming policies reference uplinks
          by name (e.g. uplink1), so imports onto a switch with different
          uplink names failed with 'activeUplinkPortName ... is not valid'

    v1.1.0  2026-07-07  Paul van Dieen
        - Import mode target picker now offers '<Create a NEW VDS and import
          into it>' - prompts for datacenter (auto-selected when there is only
          one), name, and either clones version/uplink count/MTU from an
          existing VDS or asks for them (blank = vCenter defaults)
        - Warns after creation that the new VDS has no hosts attached yet

    v1.0.1  2026-07-07  Paul van Dieen
        - Export mode now detects NSX-backed port groups (segments created by
          NSX/Tanzu) up front and skips them with a clear message instead of
          failing with a cryptic PowerCLI error - vCenter cannot export these
        - Port group pickers tag NSX-backed port groups with [NSX-backed]
        - Export failures now log the actual error detail instead of the raw
          PowerCLI exception dump
        - Export summary reports succeeded / skipped (NSX-backed) / failed

    v1.0.0  2026-07-06  Paul van Dieen
        - Initial release in dedicated repository (graduated from the VCF
          scripts repo, formerly Manage-VDSPortGroups.ps1)
        - Re-saved as UTF-8 with BOM (was UTF-16)
        - Export now uses Export-VDPortGroup -Destination instead of changing
          the working directory and renaming the newest zip afterwards
        - Port group pickers now show VLAN configuration and port count
        - Interactive mode menu when -Mode is omitted
        - Import mode skips zips whose target name already exists on the
          selected VDS instead of failing mid-run
        - Delete mode warns when a port group is in use by VMs and offers a
          safety export before deletion
        - Credentials saved as <hostname>.cred next to the script via
          Export-Clixml, with -ResetCredentials switch
        - Added -SkipCertificateValidation for self-signed lab certificates
        - All PowerCLI cmdlets scoped with -Server to prevent operations on
          other linked vCenter connections
        - BackupDirectory now optional - defaults to Backups\ next to the script
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Export', 'Import', 'Delete')]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$NamePrefix = '',

    [Parameter(Mandatory = $false)]
    [string]$NameSuffix = '',

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.1.2'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# --- Console Banner -----------------------------------------------------------
Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  Invoke-VDSPortGroupManager.ps1' + (' ' * 15) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# --- Defaults -----------------------------------------------------------------
if (-not $BackupDirectory) { $BackupDirectory = Join-Path $scriptDir 'Backups' }
if (-not $LogDirectory)    { $LogDirectory    = Join-Path $scriptDir 'Logs' }

if (($NamePrefix -or $NameSuffix) -and $Mode -and $Mode -ne 'Import') {
    Write-Host '  [WARN] -NamePrefix and -NameSuffix are only applied in Import mode and will be ignored.' -ForegroundColor Yellow
}

# --- PowerCLI Module Check ----------------------------------------------------
$vcfModule    = Get-Module -Name VCF.PowerCLI              -ListAvailable
$legacyModule = Get-Module -Name VMware.VimAutomation.Core -ListAvailable

if (-not $vcfModule -and -not $legacyModule) {
    Write-Host '  [ERROR] No compatible PowerCLI module found.' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}

if ($vcfModule) {
    if (-not (Get-Module -Name VCF.PowerCLI)) {
        Write-Host '  [INFO] Loading VCF.PowerCLI...' -ForegroundColor Cyan
        Import-Module VCF.PowerCLI -ErrorAction Stop
    }
} else {
    if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
        Write-Host '  [INFO] Loading VMware.PowerCLI...' -ForegroundColor Cyan
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }
}

# --- Logging Setup --------------------------------------------------------------
if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogFile   = Join-Path $LogDirectory "VDSPortGroupManager_$timestamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        'SUCCESS' { Write-Host "  $entry" -ForegroundColor Green  }
        'WARNING' { Write-Host "  $entry" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  $entry" -ForegroundColor Red    }
        default   { Write-Host "  $entry" -ForegroundColor Cyan   }
    }
}

# --- Menu Functions -------------------------------------------------------------
function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select everything, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'all') {
            Write-Host "  Selected all $($Items.Count) item(s)." -ForegroundColor Green
            return $Items
        }
        $selectedIndices = @()
        $parts           = $userInput -split ','
        $parseError      = $false
        foreach ($part in $parts) {
            $part = $part.Trim()
            if ($part -match '^\d+$') {
                $selectedIndices += [int]$part
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end   = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "  Invalid range: $part (start must be equal to or less than end)." -ForegroundColor Red
                    $parseError = $true
                    break
                }
                $selectedIndices += $start..$end
            }
            else {
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, or 'all'." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $Items.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($Items.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $Items[$_ - 1] })
        Write-Host "`n  Selected $($selected.Count) item(s):" -ForegroundColor Green
        $selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host ''
        return $selected
    }
}

function Select-SingleItem {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter a number to select one item, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $Items.Count) {
                $selected = $Items[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Red
    }
}

# --- Interactive Mode Menu ------------------------------------------------------
if (-not $Mode) {
    $modeOptions = @(
        [pscustomobject]@{ Label = 'Export  - back up port groups to zip files';               Value = 'Export' }
        [pscustomobject]@{ Label = 'Import  - restore port groups from zip files';             Value = 'Import' }
        [pscustomobject]@{ Label = 'Delete  - remove port groups from a VDS (with safeguards)'; Value = 'Delete' }
    )
    $modeChoice = Select-SingleItem -Items $modeOptions -DisplayProperty 'Label' -Title 'Select operation mode'
    if (-not $modeChoice) {
        Write-Host '  No mode selected. Exiting.' -ForegroundColor Yellow
        exit 0
    }
    $Mode = $modeChoice.Value
}

# --- Credential Management ------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host '  [WARN] -ResetCredentials specified - prompting for new credentials.' -ForegroundColor Yellow
    } else {
        Write-Host '  [INFO] No saved credentials found - prompting.' -ForegroundColor Cyan
    }
    $credUser   = Read-Host "  Username for $vCenterServer"
    $credPass   = Read-Host '  Password' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($credUser, $credPass)
    $credential | Export-Clixml -Path $CredentialPath
    Write-Host "  [OK]   Credentials saved to $CredentialPath." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Loading saved credentials from $CredentialPath." -ForegroundColor Cyan
    $credential = Import-Clixml -Path $CredentialPath
}

# --- Connect to vCenter ---------------------------------------------------------
Write-Log "===== VDS Port Group Manager started (Mode: $Mode) ====="
Write-Log "vCenter:          $vCenterServer"
Write-Log "Backup Directory: $BackupDirectory"
Write-Log "Log File:         $LogFile"

Write-Log "Connecting to vCenter: $vCenterServer ..."
try {
    $null = Set-PowerCLIConfiguration `
        -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
        -Confirm:$false -Scope Session -WarningAction SilentlyContinue
    $viConn = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Log "Connected to $vCenterServer (version $($viConn.Version), build $($viConn.Build))." -Level SUCCESS
} catch {
    Write-Log "Failed to connect to vCenter '$vCenterServer': $_" -Level ERROR
    exit 1
}

# --- vCenter Helper Functions ---------------------------------------------------
function Get-VlanLabel {
    param([Parameter(Mandatory = $true)]$PortGroup)
    try {
        $vlanConfig = $PortGroup.VlanConfiguration
        if ($null -eq $vlanConfig) { return 'None' }
        $label = "$vlanConfig"
        if (-not $label) { return 'None' }
        return $label
    } catch {
        return 'Unknown'
    }
}

function Get-VDSwitchPicklist {
    param([switch]$IncludeCreateNew)
    try {
        $switches = Get-VDSwitch -Server $viConn -ErrorAction Stop | Sort-Object Name
        $list = @($switches | ForEach-Object {
            [pscustomobject]@{
                Label = ('{0}  [version {1}, {2} uplink port(s)]' -f $_.Name, $_.Version, $_.NumUplinkPorts)
                Item  = $_
            }
        })
        if ($IncludeCreateNew) {
            $list += [pscustomobject]@{
                Label = '<Create a NEW VDS and import into it>'
                Item  = 'CREATE-NEW'
            }
        }
        return $list
    }
    catch {
        Write-Log "Could not retrieve VDS switches: $_" -Level ERROR
        Disconnect-VIServer -Server $viConn -Confirm:$false
        exit 1
    }
}

function New-VDSwitchInteractive {
    $datacenters = @(Get-Datacenter -Server $viConn | Sort-Object Name)
    if ($datacenters.Count -eq 0) {
        Write-Log 'No datacenter found on this vCenter - cannot create a VDS.' -Level ERROR
        return $null
    }
    if ($datacenters.Count -eq 1) {
        $datacenter = $datacenters[0]
        Write-Log "Using datacenter: $($datacenter.Name)"
    }
    else {
        $dcItems = @($datacenters | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Item = $_ } })
        $dcChoice = Select-SingleItem -Items $dcItems -DisplayProperty 'Label' -Title 'Select datacenter for the new VDS'
        if (-not $dcChoice) { return $null }
        $datacenter = $dcChoice.Item
    }

    $existingSwitches = @(Get-VDSwitch -Server $viConn -ErrorAction SilentlyContinue)
    $newName = ''
    while (-not $newName) {
        $candidate = (Read-Host "  Name for the new VDS (or 'cancel' to abort)").Trim()
        if ($candidate -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if (-not $candidate) {
            Write-Host '  Name cannot be empty.' -ForegroundColor Red
            continue
        }
        if ($existingSwitches | Where-Object { $_.Name -eq $candidate }) {
            Write-Host "  A VDS named '$candidate' already exists on this vCenter." -ForegroundColor Red
            continue
        }
        $newName = $candidate
    }

    $numUplinks  = $null
    $mtu         = $null
    $vdsVersion  = ''
    $cloneSource = $null
    if ($existingSwitches.Count -gt 0) {
        $answer = (Read-Host '  Clone version, uplink count and MTU from an existing VDS? (y/N)').Trim()
        if ($answer -match '^[Yy]') {
            $cloneChoice = Select-SingleItem -Items (Get-VDSwitchPicklist) -DisplayProperty 'Label' -Title 'Select VDS to clone settings from'
            if ($cloneChoice) { $cloneSource = $cloneChoice.Item }
        }
    }
    if ($cloneSource) {
        $vdsVersion = $cloneSource.Version
        $numUplinks = $cloneSource.NumUplinkPorts
        $mtu        = $cloneSource.Mtu
        Write-Log "Cloning settings from '$($cloneSource.Name)': version $vdsVersion, $numUplinks uplink port(s), MTU $mtu."
    }
    else {
        $uplinkInput = (Read-Host '  Number of uplink ports (blank = default 4)').Trim()
        if ($uplinkInput -match '^\d+$' -and [int]$uplinkInput -ge 1) {
            $numUplinks = [int]$uplinkInput
        }
        elseif ($uplinkInput) {
            Write-Host '  Not a valid number - using the default.' -ForegroundColor Yellow
        }
        $mtuInput = (Read-Host '  MTU (blank = default 1500)').Trim()
        if ($mtuInput -match '^\d+$') {
            $mtu = [int]$mtuInput
        }
        elseif ($mtuInput) {
            Write-Host '  Not a valid number - using the default.' -ForegroundColor Yellow
        }
        $versionInput = (Read-Host '  VDS version, e.g. 8.0.3 (blank = newest this vCenter supports)').Trim()
        if ($versionInput) { $vdsVersion = $versionInput }
    }

    try {
        $params = @{ Server = $viConn; Name = $newName; Location = $datacenter; ErrorAction = 'Stop' }
        if ($numUplinks) { $params['NumUplinkPorts'] = $numUplinks }
        if ($mtu)        { $params['Mtu']            = $mtu }
        if ($vdsVersion) { $params['Version']        = $vdsVersion }
        $newSwitch = New-VDSwitch @params
        Write-Log "Created VDS '$($newSwitch.Name)' (version $($newSwitch.Version), $($newSwitch.NumUplinkPorts) uplink port(s), MTU $($newSwitch.Mtu)) in datacenter '$($datacenter.Name)'." -Level SUCCESS
        if ($cloneSource) {
            # Teaming policies in exported port groups reference uplinks by NAME;
            # New-VDSwitch assigns its own default names, so clone the source names too
            try {
                $sourceUplinkNames = @($cloneSource.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
                $newUplinkNames    = @($newSwitch.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
                if ($sourceUplinkNames -and (Compare-Object $sourceUplinkNames $newUplinkNames)) {
                    $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
                    $spec.ConfigVersion = $newSwitch.ExtensionData.Config.ConfigVersion
                    $spec.UplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
                    $spec.UplinkPortPolicy.UplinkPortName = $sourceUplinkNames
                    $newSwitch.ExtensionData.ReconfigureDvs($spec)
                    $newSwitch = Get-VDSwitch -Server $viConn -Name $newSwitch.Name -ErrorAction Stop
                    Write-Log "Renamed uplink ports to match '$($cloneSource.Name)': $($sourceUplinkNames -join ', ')" -Level SUCCESS
                }
            }
            catch {
                Write-Log "Could not clone uplink port names from '$($cloneSource.Name)': $($_.Exception.Message). Imported teaming policies that reference the source uplink names may fail." -Level WARNING
            }
        }
        Write-Log 'The new VDS has no hosts attached yet - add hosts before workloads can use the imported port groups.' -Level WARNING
        return $newSwitch
    }
    catch {
        Write-Log "Could not create VDS '$newName': $($_.Exception.Message)" -Level WARNING
        return $null
    }
}

function Get-PortGroupPicklist {
    param(
        [Parameter(Mandatory = $true)]$Switch
    )
    $portGroups = $Switch | Get-VDPortgroup -Server $viConn |
        Where-Object { -not $_.IsUplink } |
        Sort-Object Name
    Write-Log "Found $(@($portGroups).Count) port group(s) on switch '$($Switch.Name)' (uplinks excluded)."
    return @($portGroups | ForEach-Object {
        $nsxTag = if (Test-NsxBackedPortGroup -PortGroup $_) { '  [NSX-backed]' } else { '' }
        [pscustomobject]@{
            Label = ('{0}  [VLAN: {1}, Ports: {2}]{3}' -f $_.Name, (Get-VlanLabel -PortGroup $_), $_.NumPorts, $nsxTag)
            Item  = $_
        }
    })
}

function Test-NsxBackedPortGroup {
    param([Parameter(Mandatory = $true)]$PortGroup)
    try {
        return ($PortGroup.ExtensionData.Config.BackingType -eq 'nsx')
    } catch {
        return $false
    }
}

function Export-PortGroups {
    param(
        [Parameter(Mandatory = $true)][array]$PortGroups,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -Path $Destination)) {
        Write-Log "Backup directory not found. Creating: $Destination"
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $success = 0
    $skipped = 0
    $fail    = 0
    foreach ($portgrp in $PortGroups) {
        if (Test-NsxBackedPortGroup -PortGroup $portgrp) {
            Write-Log "Skipped '$($portgrp.Name)': NSX-backed segment. vCenter cannot export these; manage it from NSX Manager instead." -Level WARNING
            $skipped++
            continue
        }
        $safeName = $portgrp.Name -replace '[\\/:*?"<>|]', '_'
        $zipPath  = Join-Path $Destination "$safeName.zip"
        try {
            Export-VDPortGroup -VDPortGroup $portgrp -Destination $zipPath -Force -ErrorAction Stop | Out-Null
            Write-Log "Exported: $safeName.zip" -Level SUCCESS
            $success++
        }
        catch {
            # PowerCLI VimException messages are tab-separated: timestamp, cmdlet, detail
            $reason = "$($_.Exception.Message)"
            if ($reason -match "`t") {
                $reason = @($reason -split "`t" | Where-Object { $_.Trim() })[-1].Trim()
            }
            Write-Log "Could not export '$($portgrp.Name)': $reason" -Level WARNING
            $fail++
        }
    }
    Write-Log "Export complete: $success succeeded, $skipped skipped (NSX-backed), $fail failed."
    return @{ Success = $success; Skipped = $skipped; Fail = $fail }
}

# =============================================================================
# EXPORT
# =============================================================================
if ($Mode -eq 'Export') {
    Write-Log '--- EXPORT MODE ---'
    $switchChoice = Select-SingleItem -Items (Get-VDSwitchPicklist) -DisplayProperty 'Label' -Title 'Select VDS to EXPORT from'
    if (-not $switchChoice) {
        Write-Log 'No switch selected. Skipping export.' -Level WARNING
    }
    else {
        $vdSwitch = $switchChoice.Item
        Write-Log "Selected switch: $($vdSwitch.Name)"
        $pgChoices = Select-MultipleItems -Items (Get-PortGroupPicklist -Switch $vdSwitch) -DisplayProperty 'Label' -Title 'Select port groups to EXPORT'
        if (@($pgChoices).Count -eq 0) {
            Write-Log 'No port groups selected for export. Skipping.' -Level WARNING
        }
        else {
            $portgrps = @($pgChoices | ForEach-Object { $_.Item })
            Write-Log "Exporting $($portgrps.Count) port group(s) to $BackupDirectory ..."
            $null = Export-PortGroups -PortGroups $portgrps -Destination $BackupDirectory
        }
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    Write-Log '--- IMPORT MODE ---'
    if (-not (Test-Path -Path $BackupDirectory)) {
        Write-Log "Backup directory does not exist: $BackupDirectory" -Level ERROR
        Disconnect-VIServer -Server $viConn -Confirm:$false
        exit 1
    }
    $allZips = @(Get-ChildItem -Path $BackupDirectory -Filter '*.zip' | Sort-Object Name)
    if ($allZips.Count -eq 0) {
        Write-Log "No .zip files found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        Write-Log "Found $($allZips.Count) zip file(s) in backup directory."
        $selectedZips = Select-MultipleItems -Items $allZips -DisplayProperty 'Name' -Title 'Select port group backups to IMPORT'
        if (@($selectedZips).Count -eq 0) {
            Write-Log 'No zip files selected for import. Skipping.' -Level WARNING
        }
        else {
            $switchChoice = Select-SingleItem -Items (Get-VDSwitchPicklist -IncludeCreateNew) -DisplayProperty 'Label' -Title 'Select VDS to IMPORT to'
            $vdSwitch = $null
            if ($switchChoice) {
                if ($switchChoice.Item -is [string] -and $switchChoice.Item -eq 'CREATE-NEW') {
                    $vdSwitch = New-VDSwitchInteractive
                }
                else {
                    $vdSwitch = $switchChoice.Item
                }
            }
            if (-not $vdSwitch) {
                Write-Log 'No target switch selected. Skipping import.' -Level WARNING
            }
            else {
                Write-Log "Selected switch: $($vdSwitch.Name)"

                # Distributed port group names must be unique across the whole
                # DATACENTER, not just the target switch
                $existingByName = @{}
                try {
                    $dcPortGroups = @(Get-VDSwitch -Server $viConn -Location $vdSwitch.Datacenter -ErrorAction Stop |
                        Get-VDPortgroup -Server $viConn -ErrorAction Stop)
                }
                catch {
                    $dcPortGroups = @(Get-VDPortgroup -Server $viConn)
                }
                foreach ($pg in $dcPortGroups) {
                    if (-not $existingByName.ContainsKey($pg.Name)) { $existingByName[$pg.Name] = $pg.VDSwitch.Name }
                }

                if (-not $NamePrefix -and -not $NameSuffix) {
                    $conflicts = @($selectedZips | Where-Object {
                        $existingByName.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($_.Name))
                    })
                    if ($conflicts.Count -gt 0) {
                        Write-Log "$($conflicts.Count) of $(@($selectedZips).Count) selected backup(s) clash with port group names that already exist in this datacenter (names must be unique per datacenter, across all switches)." -Level WARNING
                        Write-Host '  Enter a prefix and/or suffix to rename on import, or leave both blank to skip clashing backups.' -ForegroundColor Gray
                        $NamePrefix = (Read-Host '  Name prefix (blank = none)').Trim()
                        $NameSuffix = (Read-Host '  Name suffix (blank = none)').Trim()
                    }
                }
                if ($NamePrefix) { Write-Log "Applying name prefix: '$NamePrefix'" }
                if ($NameSuffix) { Write-Log "Applying name suffix: '$NameSuffix'" }
                if (-not $NamePrefix -and -not $NameSuffix) {
                    Write-Log 'No name prefix or suffix specified. Port groups will keep their original names.'
                }
                $importSuccess = 0
                $importFail    = 0
                $importSkipped = 0
                foreach ($zip in $selectedZips) {
                    $originalName = [System.IO.Path]::GetFileNameWithoutExtension($zip.Name)
                    $newName      = "$NamePrefix$originalName$NameSuffix"
                    if ($existingByName.ContainsKey($newName)) {
                        if ($existingByName[$newName] -eq $vdSwitch.Name) {
                            Write-Log "Skipped '$($zip.Name)': port group '$newName' already exists on '$($vdSwitch.Name)'." -Level WARNING
                        }
                        else {
                            Write-Log "Skipped '$($zip.Name)': port group '$newName' already exists on '$($existingByName[$newName])' in the same datacenter. Use a name prefix/suffix to import a renamed copy." -Level WARNING
                        }
                        $importSkipped++
                        continue
                    }
                    try {
                        $null = $vdSwitch | New-VDPortgroup -BackupPath $zip.FullName -Name $newName -ErrorAction Stop
                        $existingByName[$newName] = $vdSwitch.Name
                        if ($newName -ne $originalName) {
                            Write-Log "Imported: '$originalName' -> '$newName'" -Level SUCCESS
                        } else {
                            Write-Log "Imported: '$originalName'" -Level SUCCESS
                        }
                        $importSuccess++
                    }
                    catch {
                        Write-Log "Could not import '$($zip.Name)': $_" -Level WARNING
                        $importFail++
                    }
                }
                Write-Log "Import complete: $importSuccess succeeded, $importSkipped skipped, $importFail failed."
            }
        }
    }
}

# =============================================================================
# DELETE
# =============================================================================
if ($Mode -eq 'Delete') {
    Write-Log '--- DELETE MODE ---'
    $switchChoice = Select-SingleItem -Items (Get-VDSwitchPicklist) -DisplayProperty 'Label' -Title 'Select VDS to DELETE from'
    if (-not $switchChoice) {
        Write-Log 'No switch selected. Skipping delete.' -Level WARNING
    }
    else {
        $vdSwitch = $switchChoice.Item
        Write-Log "Selected switch: $($vdSwitch.Name)"
        $pgChoices = Select-MultipleItems -Items (Get-PortGroupPicklist -Switch $vdSwitch) -DisplayProperty 'Label' -Title 'Select port groups to DELETE'
        if (@($pgChoices).Count -eq 0) {
            Write-Log 'No port groups selected for deletion. Skipping.' -Level WARNING
        }
        else {
            $portgrps = @($pgChoices | ForEach-Object { $_.Item })

            # Flag port groups that still have VMs attached - Remove-VDPortGroup will fail on these
            Write-Host "`n  *** WARNING: You are about to permanently delete $($portgrps.Count) port group(s):" -ForegroundColor Red
            foreach ($portgrp in $portgrps) {
                $vmCount = 0
                try { $vmCount = @($portgrp.ExtensionData.Vm).Count } catch { $vmCount = 0 }
                if ($vmCount -gt 0) {
                    Write-Host "    - $($portgrp.Name)  [IN USE by $vmCount VM(s) - deletion will fail]" -ForegroundColor Red
                } else {
                    Write-Host "    - $($portgrp.Name)" -ForegroundColor Yellow
                }
            }
            Write-Host ''

            $backupFirst = (Read-Host '  Export a safety backup of these port groups first? (Y/n)').Trim()
            if ($backupFirst -notmatch '^[Nn]') {
                Write-Log "Creating safety export in $BackupDirectory before deletion ..."
                $null = Export-PortGroups -PortGroups $portgrps -Destination $BackupDirectory
            }

            $confirm = (Read-Host "  Type 'YES' to confirm deletion, or anything else to cancel").Trim()
            if ($confirm -cne 'YES') {
                Write-Log 'Deletion cancelled by user.' -Level WARNING
            }
            else {
                Write-Log "User confirmed deletion of $($portgrps.Count) port group(s)."
                $deleteSuccess = 0
                $deleteFail    = 0
                foreach ($portgrp in $portgrps) {
                    try {
                        Remove-VDPortGroup -VDPortGroup $portgrp -Confirm:$false -ErrorAction Stop
                        Write-Log "Deleted: $($portgrp.Name)" -Level SUCCESS
                        $deleteSuccess++
                    }
                    catch {
                        Write-Log "Could not delete '$($portgrp.Name)': $_" -Level WARNING
                        $deleteFail++
                    }
                }
                Write-Log "Delete complete: $deleteSuccess succeeded, $deleteFail failed."
            }
        }
    }
}

# =============================================================================
# DISCONNECT
# =============================================================================
Write-Log 'Disconnecting from vCenter...'
Disconnect-VIServer -Server $viConn -Confirm:$false
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
