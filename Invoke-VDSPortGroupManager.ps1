#Requires -Version 7.4
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

.PARAMETER UplinkMap
    Import mode only. Maps uplink names used by the exported port groups to
    uplink names on the target switch, e.g.
    @{ 'Uplink 1' = 'uplink1'; 'Uplink 2' = 'uplink2' }.
    Exported teaming policies name their uplinks; when the target switch uses
    other names, the backup zip cannot be restored as is. With a map (or the
    interactive prompt that asks for the missing names), the port group is
    rebuilt from the settings file (<portgroup>.json) written at export time:
    the port group's complete configuration, with the mapped uplink names.

.PARAMETER PowerCLIBuild
    Optional. The PowerCLI build to use, the last part of the module version
    (e.g. 25718932 for 13.5.1.25718932). By default the script uses the newest
    build of which every module it needs is installed.

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
    # Import onto a VCF-built switch whose uplinks are named differently
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.lab.local -Mode Import -UplinkMap @{ 'Uplink 1' = 'uplink1'; 'Uplink 2' = 'uplink2' }

.EXAMPLE
    # Delete selected port groups (offers a safety export first)
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Delete

.EXAMPLE
    # Lab environment with self-signed certificate
    .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.lab.local -Mode Export -SkipCertificateValidation

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Version  : 1.2.1
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ (or VMware.PowerCLI 13+)
    Tested   : vCenter 9.1.1 and 9.0.2 (Holodeck lab), both directions between them

.CHANGELOG
    v1.2.1  2026-11-13  Paul van Dieen
        - PowerCLI loading picks one complete set itself instead of importing
          VCF.PowerCLI: the newest build of which every module the script needs
          (VMware.VimAutomation.Vds and its dependencies, read from the module
          manifests) is installed, imported file by file, dependencies first.
          Machines with several PowerCLI versions side by side or a half-done
          offline install no longer end in 'The required module ... is not
          loaded' or 'OnImportModule ... Value cannot be null' (#5)
        - When a PowerCLI is already loaded in the session (a profile or an
          earlier command), the script completes that same build
        - New -PowerCLIBuild to force a build
        - A module that can't be loaded now stops the script with a clear
          message (clean session with pwsh -NoProfile, incomplete or blocked
          offline install) and lists what is loaded, instead of the raw error

    v1.2.0  2026-11-13  Paul van Dieen
        - Export writes a settings file (<portgroup>.json) next to each zip:
          the port group's complete configuration as the vSphere API returns
          it (DVPortgroupConfigInfo: VLAN, teaming, security, traffic shaping,
          NetFlow, blocking, filtering, override and reset settings,
          allocation, NIOC pool, description), serialised with its types,
          plus a readable summary and the source switch's uplink and LAG names
        - Import checks, before restoring, which uplink names a port group's
          teaming policy uses and whether the target switch has them. If it
          does, the zip is restored as before. If not, the missing names are
          reported up front instead of vCenter's 'activeUplinkPortName ...
          is not valid' afterwards
        - New -UplinkMap (and an interactive prompt for names it doesn't
          cover): the port group is rebuilt from the settings file with one
          CreateDVPortgroup call (all or nothing), carrying every setting,
          with the mapped uplink names. A NIOC network resource pool the
          target switch doesn't have falls back to the default, with a warning
        - Warns when a LACP LAG is mapped to a plain uplink
        - When restoring a zip fails and a settings file exists, the port group
          is rebuilt from the settings file instead: a backup from a newer
          vCenter can't be restored on an older one ('Uncompress and
          Deserialize failed', lab-verified 9.1.1 -> 9.0.2)
        - SecurityPolicy and MacManagementPolicy overlap; the rebuild sends
          MacManagementPolicy only when MAC learning is set explicitly, so
          inherited security settings stay inherited (lab-verified)
        - Zips without a settings file (older exports) behave as before
        - Minimum PowerShell is now 7.4: VCF.PowerCLI 9.x needs PowerShell 7
          (KB 409981, #1)

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
    [hashtable]$UplinkMap = @{},

    [Parameter(Mandatory = $false)]
    [int]$PowerCLIBuild = 0,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.2.1'
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
if ($UplinkMap.Count -gt 0 -and $Mode -and $Mode -ne 'Import') {
    Write-Host '  [WARN] -UplinkMap is only applied in Import mode and will be ignored.' -ForegroundColor Yellow
}

# --- PowerCLI Module Check ----------------------------------------------------
# The script needs only VMware.VimAutomation.Vds and what it depends on, not
# the whole VCF.PowerCLI bundle. PowerShell loads one version of a module per
# session, the PowerCLI modules require each other with MINIMUM versions (so
# PowerShell picks the newest copy it finds), and machines often carry several
# PowerCLI versions side by side. Left to itself that produces a mix of
# versions and errors such as "The required module ... is not loaded" or
# "OnImportModule ... Value cannot be null". So the script picks one complete
# set itself: the newest PowerCLI build of which every module it needs is
# present, read from the modules' own manifests, and imports exactly those
# files, dependencies first.

function Stop-ModuleLoadFailure {
    param([string]$What, [string]$Reason)
    Write-Host "  [ERROR] Could not load $What." -ForegroundColor Red
    if ($Reason) { Write-Host "          $Reason" -ForegroundColor Red }
    Write-Host '          Usually one of these:' -ForegroundColor Yellow
    Write-Host '          - another PowerCLI version is already loaded in this session (profile or an' -ForegroundColor Yellow
    Write-Host '            earlier command); start a clean session with "pwsh -NoProfile" and run the' -ForegroundColor Yellow
    Write-Host '            script first;' -ForegroundColor Yellow
    Write-Host '          - no complete PowerCLI set: after an offline install, every module folder from the' -ForegroundColor Yellow
    Write-Host '            PowerCLI zip must be in one module path, unblocked (Unblock-File the zip before' -ForegroundColor Yellow
    Write-Host '            extracting it).' -ForegroundColor Yellow
    $loaded = @(Get-Module -Name VMware.*, VCF.PowerCLI)
    if ($loaded.Count -gt 0) {
        Write-Host '          Loaded now:' -ForegroundColor Yellow
        $loaded | Sort-Object Name | ForEach-Object {
            Write-Host "            $($_.Name) $($_.Version)  ($($_.ModuleBase))" -ForegroundColor Yellow
        }
    }
    exit 1
}
function Get-ShortError {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    return $m
}

function Resolve-PowerCLISet {
    # For one PowerCLI build (the revision part of the module versions, e.g.
    # 25718932 for 13.5.1.25718932 and VMware.Vim 9.1.0.25718932), walk the
    # RequiredModules of VMware.VimAutomation.Vds and return the module
    # manifests in load order (dependencies first), or the names that are
    # missing in that build.
    param([Parameter(Mandatory = $true)][int]$Build, [Parameter(Mandatory = $true)]$Available)
    $order   = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $missing = [System.Collections.Generic.List[string]]::new()
    $visit = {
        param([string]$Name)
        if (-not $seen.Add($Name)) { return }
        $m = $Available | Where-Object { $_.Name -eq $Name -and $_.Version.Revision -eq $Build } | Select-Object -First 1
        if (-not $m) { $missing.Add($Name); return }
        $data = Import-PowerShellDataFile -Path $m.Path
        if ($data.ContainsKey('RequiredModules')) {
            foreach ($req in @($data.RequiredModules)) {
                if (-not $req) { continue }
                $reqName = if ($req -is [hashtable]) { $req.ModuleName } else { "$req" }
                & $visit $reqName
            }
        }
        $order.Add($m)
    }
    & $visit 'VMware.VimAutomation.Vds'
    return [pscustomobject]@{ Build = $Build; Modules = @($order); Missing = @($missing) }
}

$available = @(Get-Module -ListAvailable -All -Name VMware.* | Where-Object { $_.Path -like '*.psd1' })
if (-not ($available | Where-Object { $_.Name -eq 'VMware.VimAutomation.Vds' })) {
    Write-Host '  [ERROR] No PowerCLI found (VMware.VimAutomation.Vds is not installed).' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}

$loadedPcli = @(Get-Module -Name VMware.* | Where-Object { $_.Version.Revision -gt 0 })
if ($loadedPcli.Count -gt 0) {
    # Part of a PowerCLI is already in this session (a profile, an earlier
    # command); loaded versions are fixed until the session ends, so complete
    # that same build. Two different builds loaded can't be fixed in-session.
    $loadedBuilds = @($loadedPcli | ForEach-Object { [int]$_.Version.Revision } | Select-Object -Unique)
    if ($loadedBuilds.Count -gt 1) {
        Stop-ModuleLoadFailure -What 'one consistent PowerCLI set' -Reason "Modules of different PowerCLI builds are already loaded in this session ($($loadedBuilds -join ', '))."
    }
    $builds = $loadedBuilds
    Write-Host "  [INFO] PowerCLI build $($loadedBuilds[0]) is already (partly) loaded in this session; completing that build." -ForegroundColor Cyan
}
elseif ($PowerCLIBuild) {
    $builds = @($PowerCLIBuild)
}
else {
    $builds = @($available | Where-Object { $_.Name -eq 'VMware.VimAutomation.Vds' } |
        Sort-Object Version -Descending | ForEach-Object { [int]$_.Version.Revision } | Select-Object -Unique)
}

$chosen = $null
$tried  = @()
foreach ($b in $builds) {
    $set = Resolve-PowerCLISet -Build $b -Available $available
    if ($set.Missing.Count -eq 0) { $chosen = $set; break }
    $tried += "build $b is missing $($set.Missing -join ', ')"
}
if (-not $chosen) {
    Stop-ModuleLoadFailure -What 'a complete PowerCLI set' -Reason ($tried -join '; ')
}
if ($tried.Count -gt 0) {
    Write-Host "  [WARN] Skipped incomplete PowerCLI set(s): $($tried -join '; ')." -ForegroundColor Yellow
}
$vdsModule = $chosen.Modules | Where-Object { $_.Name -eq 'VMware.VimAutomation.Vds' }
Write-Host "  [INFO] Loading PowerCLI $($vdsModule.Version) ($($chosen.Modules.Count) modules)..." -ForegroundColor Cyan
foreach ($m in $chosen.Modules) {
    $already = Get-Module -Name $m.Name
    if ($already) {
        if (@($already | Where-Object { $_.Version -eq $m.Version }).Count -eq 0) {
            Stop-ModuleLoadFailure -What "$($m.Name) $($m.Version)" -Reason "$($m.Name) $(@($already)[0].Version) is already loaded in this session."
        }
        continue
    }
    try {
        Import-Module -Name $m.Path -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
    }
    catch {
        Stop-ModuleLoadFailure -What "$($m.Name) $($m.Version)" -Reason (Get-ShortError $_)
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
            # Settings file next to the zip, used by Import to rebuild the port
            # group when the target switch has other uplink names
            try {
                $jsonPath = Join-Path $Destination "$safeName.json"
                Get-PortGroupSettings -PortGroup $portgrp | ConvertTo-Json -Depth 6 |
                    Set-Content -Path $jsonPath -Encoding UTF8
                Write-Log "  Settings file: $safeName.json"
            }
            catch {
                Write-Log "  Could not write the settings file for '$($portgrp.Name)': $($_.Exception.Message). The zip is fine; only a rebuild with -UplinkMap needs this file." -Level WARNING
            }
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

# --- Uplink-name handling (v1.2.0) -----------------------------------------------
# Exported teaming policies name their uplinks. Restoring a zip onto a switch
# with other uplink names fails in vCenter, so Export also writes the port
# group's complete configuration (the vSphere API DVPortgroupConfigInfo) to a
# JSON settings file, and Import can rebuild the port group from it with
# CreateDVPortgroup, with mapped uplink names. A rebuild carries every setting,
# not a hand-picked subset.

$script:VimAssembly       = [VMware.Vim.DVPortgroupConfigSpec].Assembly
$script:ResolvedUplinkMap = @{}
$script:UnmappedUplink    = ''

function ConvertTo-VimData {
    # Generic, type-preserving serialisation of a VMware.Vim object graph to
    # plain data for ConvertTo-Json. Every object keeps its type in '_type' so
    # derived types (VMwareDVSPortSetting, VmwareDistributedVirtualSwitchVlanIdSpec,
    # ...) come back exactly. Managed object references are switch- or
    # vCenter-specific and are left out.
    param($Value)
    if ($null -eq $Value) { return $null }
    $t = $Value.GetType()
    if ($t.IsEnum) { return $Value.ToString() }
    if ($t.IsPrimitive -or $Value -is [string] -or $Value -is [decimal] -or $Value -is [datetime]) { return $Value }
    if ($Value -is [VMware.Vim.ManagedObjectReference]) { return $null }
    if ($Value -is [System.Array]) {
        $items = @(foreach ($v in $Value) { ConvertTo-VimData $v })
        return , $items
    }
    $o = [ordered]@{ '_type' = $t.FullName }
    foreach ($p in $t.GetProperties()) {
        if ($p.Name -in @('LinkedView', 'DynamicType', 'DynamicProperty')) { continue }
        if ($p.GetIndexParameters().Count -gt 0) { continue }
        $v = $p.GetValue($Value)
        if ($null -eq $v) { continue }
        $c = ConvertTo-VimData $v
        if ($null -ne $c) { $o[$p.Name] = $c }
    }
    return $o
}

function ConvertFrom-VimData {
    # Reverse of ConvertTo-VimData: builds typed VMware.Vim objects from the
    # JSON data. Fields this PowerCLI/vSphere version doesn't know are listed in
    # $script:UnknownFields instead of failing.
    param($Data, [Parameter(Mandatory = $true)][type]$TargetType)
    if ($null -eq $Data) { return $null }
    $u = [Nullable]::GetUnderlyingType($TargetType)
    if ($u) { $TargetType = $u }
    if ($TargetType.IsArray) {
        $et   = $TargetType.GetElementType()
        $list = @(foreach ($d in @($Data)) { ConvertFrom-VimData $d $et })
        $arr  = [Array]::CreateInstance($et, $list.Count)
        for ($i = 0; $i -lt $list.Count; $i++) { $arr[$i] = $list[$i] }
        return , $arr
    }
    if ($TargetType.IsEnum) { return [Enum]::Parse($TargetType, "$Data") }
    if ($TargetType -eq [string]) { return [string]$Data }
    if ($TargetType.IsPrimitive -or $TargetType -eq [decimal] -or $TargetType -eq [datetime]) {
        return [Convert]::ChangeType($Data, $TargetType, [Globalization.CultureInfo]::InvariantCulture)
    }
    $typeName = $null
    if ($Data.PSObject.Properties['_type']) { $typeName = $Data._type }
    $t = $TargetType
    if ($typeName) {
        $resolved = $script:VimAssembly.GetType($typeName)
        if ($resolved) { $t = $resolved }
    }
    $obj = [Activator]::CreateInstance($t)
    foreach ($prop in $Data.PSObject.Properties) {
        if ($prop.Name -eq '_type') { continue }
        $pi = $t.GetProperty($prop.Name)
        if (-not $pi -or -not $pi.CanWrite) {
            $script:UnknownFields += "$($t.Name).$($prop.Name)"
            continue
        }
        $pi.SetValue($obj, (ConvertFrom-VimData $prop.Value $pi.PropertyType))
    }
    return $obj
}

function Get-PortGroupSettings {
    # The settings file: a readable Summary for people, and Spec, the complete
    # configuration in the shape of a DVPortgroupConfigSpec, for the rebuild.
    param([Parameter(Mandatory = $true)]$PortGroup)
    $cfg  = $PortGroup.ExtensionData.Config
    $dpc  = $cfg.DefaultPortConfig
    $sw   = $PortGroup.VDSwitch

    $vlanSummary = 'None'
    switch ($dpc.Vlan.GetType().Name) {
        'VmwareDistributedVirtualSwitchVlanIdSpec'    { $vlanSummary = "VLAN $($dpc.Vlan.VlanId)" }
        'VmwareDistributedVirtualSwitchTrunkVlanSpec' {
            $vlanSummary = 'Trunk ' + (@($dpc.Vlan.VlanId | ForEach-Object { if ($_.Start -eq $_.End) { "$($_.Start)" } else { "$($_.Start)-$($_.End)" } }) -join ',')
        }
        'VmwareDistributedVirtualSwitchPvlanSpec'     { $vlanSummary = "Private VLAN $($dpc.Vlan.PvlanId)" }
    }
    $order = $dpc.UplinkTeamingPolicy.UplinkPortOrder
    $lagNames = @()
    try { $lagNames = @($sw.ExtensionData.Config.LacpGroupConfig | ForEach-Object { $_.Name }) } catch { $lagNames = @() }

    $spec = [ordered]@{ '_type' = 'VMware.Vim.DVPortgroupConfigSpec' }
    foreach ($name in @('Name', 'NumPorts', 'PortNameFormat', 'DefaultPortConfig', 'Description', 'Type',
                        'Policy', 'VendorSpecificConfig', 'AutoExpand', 'VmVnicNetworkResourcePoolKey')) {
        $v = $cfg.$name
        if ($null -eq $v) { continue }
        $c = ConvertTo-VimData $v
        if ($null -ne $c) { $spec[$name] = $c }
    }

    return [ordered]@{
        SettingsFormat    = 2
        ScriptVersion     = $scriptVersion
        ExportedFrom      = "$vCenterServer (vSphere API $($viConn.Version))"
        ExportedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Name              = $PortGroup.Name
        SourceSwitch      = $sw.Name
        SourceUplinkNames = @($sw.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        SourceLagNames    = $lagNames
        Summary           = [ordered]@{
            Vlan              = $vlanSummary
            PortBinding       = "$($PortGroup.PortBinding)"
            NumPorts          = [int]$cfg.NumPorts
            AutoExpand        = $cfg.AutoExpand
            UplinkOrder       = if ($order.Inherited) { 'inherited from the switch' } else { "active: $(@($order.ActiveUplinkPort) -join ', '); standby: $(@($order.StandbyUplinkPort) -join ', ')" }
            LoadBalancing     = "$($dpc.UplinkTeamingPolicy.Policy.Value)"
            InShaping         = [bool]$dpc.InShapingPolicy.Enabled.Value
            OutShaping        = [bool]$dpc.OutShapingPolicy.Enabled.Value
            NetFlow           = [bool]$dpc.IpfixEnabled.Value
            Blocked           = [bool]$dpc.Blocked.Value
            NetworkResourcePool = "$($dpc.NetworkResourcePoolKey.Value)"
        }
        Spec              = $spec
    }
}

function Get-UplinkNamesInUse {
    # The uplink names a port group's own teaming order refers to. Empty when
    # the order is inherited from the switch: then no names travel with it.
    param([Parameter(Mandatory = $true)]$Settings)
    # Empty lists and null values are left out of the settings file, so every
    # step checks that the property exists (the script runs in strict mode)
    $order = $Settings
    foreach ($step in @('Spec', 'DefaultPortConfig', 'UplinkTeamingPolicy', 'UplinkPortOrder')) {
        if ($null -eq $order -or -not $order.PSObject.Properties[$step]) { return @() }
        $order = $order.$step
    }
    if ($order.PSObject.Properties['Inherited'] -and $order.Inherited) { return @() }
    $names = @()
    foreach ($list in @('ActiveUplinkPort', 'StandbyUplinkPort')) {
        if ($order.PSObject.Properties[$list]) { $names += @($order.$list) }
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

function Get-SwitchUplinkNames {
    param([Parameter(Mandatory = $true)]$Switch)
    return @($Switch.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
}

function Get-SwitchLagNames {
    param([Parameter(Mandatory = $true)]$Switch)
    try { return @($Switch.ExtensionData.Config.LacpGroupConfig | ForEach-Object { $_.Name }) } catch { return @() }
}

function Resolve-UplinkMapping {
    # Returns a hashtable source name -> target name for every name in
    # $Missing, from -UplinkMap first and the interactive prompt second.
    # Answers are remembered for the rest of the run. Returns $null when a
    # name stays unmapped (the user chose to skip, or the map is invalid).
    param(
        [Parameter(Mandatory = $true)][string[]]$Missing,
        [Parameter(Mandatory = $true)][string[]]$TargetNames,
        [Parameter(Mandatory = $true)][string]$PortGroupName
    )
    $result = @{}
    foreach ($name in $Missing) {
        if ($script:ResolvedUplinkMap.ContainsKey($name)) {
            $result[$name] = $script:ResolvedUplinkMap[$name]
            continue
        }
        if ($UplinkMap.ContainsKey($name)) {
            $mapped = "$($UplinkMap[$name])"
            if ($TargetNames -notcontains $mapped) {
                Write-Log "-UplinkMap maps '$name' to '$mapped', but the target switch has no uplink '$mapped' (it has: $($TargetNames -join ', '))." -Level WARNING
                $script:UnmappedUplink = $name
                return $null
            }
            $script:ResolvedUplinkMap[$name] = $mapped
            $result[$name] = $mapped
            continue
        }
        $items = @($TargetNames | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } })
        $items += [pscustomobject]@{ Label = '<skip this port group>'; Value = $null }
        $choice = Select-SingleItem -Items $items -DisplayProperty 'Label' -Title "Port group '$PortGroupName' uses uplink '$name', which the target switch doesn't have. Map it to"
        if (-not $choice -or -not $choice.Value) { $script:UnmappedUplink = $name; return $null }
        $script:ResolvedUplinkMap[$name] = $choice.Value
        $result[$name] = $choice.Value
        Write-Log "Uplink mapping: '$name' -> '$($choice.Value)' (used for the rest of this run)."
    }
    return $result
}

function New-PortGroupFromSettings {
    # Rebuilds a port group from its complete exported configuration with one
    # CreateDVPortgroup call (all or nothing), after replacing what points at
    # the source switch: uplink names, and NIOC pool keys the target lacks.
    param(
        [Parameter(Mandatory = $true)]$Switch,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][hashtable]$Map
    )
    $script:UnknownFields = @()
    $spec = ConvertFrom-VimData $Settings.Spec ([VMware.Vim.DVPortgroupConfigSpec])
    if ($script:UnknownFields.Count -gt 0) {
        Write-Log "  Settings this vCenter/PowerCLI doesn't know, left out: $(($script:UnknownFields | Select-Object -Unique) -join ', ')" -Level WARNING
    }
    $spec.Name          = $Name
    $spec.ConfigVersion = $null

    # SecurityPolicy and MacManagementPolicy overlap. MacManagementPolicy has
    # one inherited flag for the whole object, SecurityPolicy one per setting;
    # sending both makes every security setting explicit on the target (lab-
    # verified on 9.1.1). Send MacManagementPolicy only when MAC learning, which
    # exists only there, is set explicitly.
    $dpc = $spec.DefaultPortConfig
    if ($dpc -and $dpc.SecurityPolicy -and $dpc.MacManagementPolicy) {
        $learning = $dpc.MacManagementPolicy.MacLearningPolicy
        if (-not $learning -or $learning.Inherited) {
            $dpc.MacManagementPolicy = $null
        }
        else {
            Write-Log "  '$Name' has MAC learning set explicitly; promiscuous mode, MAC address changes and forged transmits become explicit settings on the target too." -Level WARNING
        }
    }

    # Uplink names
    $targetLags = Get-SwitchLagNames -Switch $Switch
    $sourceLags = @($Settings.SourceLagNames | Where-Object { $_ })
    foreach ($src in $Map.Keys) {
        if ($sourceLags -contains $src -and $targetLags -notcontains $Map[$src]) {
            Write-Log "'$Name': LACP LAG '$src' is mapped to the plain uplink '$($Map[$src])'. Check the load-balancing policy (source: $($Settings.Summary.LoadBalancing)) after the import." -Level WARNING
        }
    }
    $order   = $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder
    $active  = @()
    $standby = @()
    if ($order -and -not $order.Inherited) {
        $active  = @($order.ActiveUplinkPort  | Where-Object { $_ } | ForEach-Object { if ($Map.ContainsKey($_)) { $Map[$_] } else { $_ } } | Select-Object -Unique)
        $standby = @($order.StandbyUplinkPort | Where-Object { $_ } | ForEach-Object { if ($Map.ContainsKey($_)) { $Map[$_] } else { $_ } } | Select-Object -Unique | Where-Object { $active -notcontains $_ })
        $order.ActiveUplinkPort  = [string[]]$active
        $order.StandbyUplinkPort = [string[]]$standby
    }

    # NIOC network resource pools are per switch: keep a key only if the
    # target switch has it, otherwise fall back to the default with a warning
    $poolKeys = @()
    try { $poolKeys += @($Switch.ExtensionData.NetworkResourcePool | ForEach-Object { $_.Key }) } catch { }
    try { $poolKeys += @($Switch.ExtensionData.Config.VmVnicNetworkResourcePool | ForEach-Object { $_.Key }) } catch { }
    $nrp = $spec.DefaultPortConfig.NetworkResourcePoolKey
    if ($nrp -and $nrp.Value -and $nrp.Value -ne '-1' -and $poolKeys -notcontains $nrp.Value) {
        Write-Log "'$Name': network resource pool '$($nrp.Value)' doesn't exist on '$($Switch.Name)'; the port group gets the default pool." -Level WARNING
        $nrp.Value = '-1'
    }
    if ($spec.VmVnicNetworkResourcePoolKey -and $poolKeys -notcontains $spec.VmVnicNetworkResourcePoolKey) {
        Write-Log "'$Name': VM vNIC network resource pool '$($spec.VmVnicNetworkResourcePoolKey)' doesn't exist on '$($Switch.Name)'; left out." -Level WARNING
        $spec.VmVnicNetworkResourcePoolKey = $null
    }

    $null = $Switch.ExtensionData.CreateDVPortgroup($spec)
    $mapText = ($Map.Keys | Sort-Object | ForEach-Object { "$_ -> $($Map[$_])" }) -join ', '
    if ($order -and -not $order.Inherited -and $Map.Count -gt 0) {
        Write-Log "  Rebuilt from the settings file (complete configuration) with uplink mapping $mapText. Active: $($active -join ', '); standby: $($standby -join ', ')."
    } else {
        Write-Log "  Rebuilt from the settings file (complete configuration)."
    }
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
                    # Uplink-name check against the target switch, using the
                    # settings file written at export (v1.2.0 and later)
                    $settings  = $null
                    $rebuildMap = $null
                    $jsonPath  = [System.IO.Path]::ChangeExtension($zip.FullName, '.json')
                    if (Test-Path -Path $jsonPath) {
                        try {
                            $settings = Get-Content -Path $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        }
                        catch {
                            Write-Log "Could not read '$([System.IO.Path]::GetFileName($jsonPath))': $($_.Exception.Message). Restoring '$($zip.Name)' from the zip without an uplink check." -Level WARNING
                        }
                        if ($settings -and (-not $settings.PSObject.Properties['SettingsFormat'] -or [int]$settings.SettingsFormat -lt 2 -or -not $settings.PSObject.Properties['Spec'])) {
                            Write-Log "'$([System.IO.Path]::GetFileName($jsonPath))' is from an older format without the complete configuration. Re-export with v1.2.0; restoring '$($zip.Name)' from the zip without an uplink check." -Level WARNING
                            $settings = $null
                        }
                    }
                    if ($settings) {
                        $targetNames = Get-SwitchUplinkNames -Switch $vdSwitch
                        $missing = @(Get-UplinkNamesInUse -Settings $settings | Where-Object { $targetNames -notcontains $_ })
                        if ($missing.Count -gt 0) {
                            Write-Log "'$originalName' uses uplink name(s) $($missing -join ', ') that '$($vdSwitch.Name)' doesn't have (it has: $($targetNames -join ', '))."
                            $rebuildMap = Resolve-UplinkMapping -Missing $missing -TargetNames $targetNames -PortGroupName $originalName
                            if (-not $rebuildMap) {
                                $hint = ($missing | ForEach-Object { "'$_' = '<target uplink>'" }) -join '; '
                                Write-Log "Skipped '$($zip.Name)': no valid target uplink for '$($script:UnmappedUplink)'. Map every missing name, e.g. -UplinkMap @{ $hint }, or answer the prompt." -Level WARNING
                                $importSkipped++
                                continue
                            }
                        }
                    }
                    elseif (-not (Test-Path -Path $jsonPath)) {
                        Write-Log "No settings file for '$($zip.Name)' (exported before v1.2.0): restoring the zip without an uplink check."
                    }
                    try {
                        if ($rebuildMap) {
                            $null = New-PortGroupFromSettings -Switch $vdSwitch -Name $newName -Settings $settings -Map $rebuildMap
                        }
                        else {
                            try {
                                $null = $vdSwitch | New-VDPortgroup -BackupPath $zip.FullName -Name $newName -ErrorAction Stop
                            }
                            catch {
                                # A backup from a newer vCenter can't be restored on an
                                # older one ('Uncompress and Deserialize failed on backup
                                # config blob', lab-verified 9.1.1 -> 9.0.2). The settings
                                # file can still rebuild it.
                                if (-not $settings) { throw }
                                $zipError = "$($_.Exception.Message)"
                                if ($zipError -match "`t") { $zipError = @($zipError -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
                                Write-Log "Restoring '$($zip.Name)' from the zip failed ($zipError). Rebuilding it from the settings file instead." -Level WARNING
                                if (Get-VDPortgroup -Server $viConn -Name $newName -ErrorAction SilentlyContinue) {
                                    throw "a port group '$newName' was left behind by the failed restore; remove it and run the import again"
                                }
                                $null = New-PortGroupFromSettings -Switch $vdSwitch -Name $newName -Settings $settings -Map @{}
                            }
                        }
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
