#Requires -Version 7.4

<#
.SYNOPSIS
    Builds, shows or removes a throwaway test set in a LAB vCenter for the
    uplink-name handling of Invoke-VDSPortGroupManager.ps1 (v1.2.0).

.DESCRIPTION
    Lab use only. Creates two host-less distributed switches and seven test
    port groups, all named VPGM-T-*:

        VPGM-T-Src   uplinks named 'Uplink 1', 'Uplink 2' (like an older source switch)
        VPGM-T-Dst   uplinks named 'uplink1', 'uplink2'   (like a VCF-built switch)

        On VPGM-T-Src:
          VPGM-T-Vlan101  VLAN 101, explicit order: active 'Uplink 1', standby 'Uplink 2',
                          load balancing ExplicitFailover, forged transmits allowed
          VPGM-T-Trunk    VLAN trunk 200-210,300, uplink order inherited from the switch
          VPGM-T-Eph      ephemeral binding, no VLAN, active 'Uplink 2', 'Uplink 1' unused
          VPGM-T-Adv      VLAN 150, 16 ports fixed allocation, active 'Uplink 2' / standby 'Uplink 1',
                          ingress traffic shaping, NetFlow on, no reset at disconnect, a description
          VPGM-T-Pvlan601 private VLAN 601 (isolated, primary 600)
          VPGM-T-Pvlan602 private VLAN 602 (community, primary 600)
          VPGM-T-MacLearn VLAN 160, MAC learning on (limit 4096, drop), forged transmits
                          and MAC changes allowed: SecurityPolicy and MacManagementPolicy overlap
          VPGM-T-Nioc     VLAN 170 with a VM vNIC network resource pool (only if the switch
                          accepts NIOC on a host-less switch; skipped with a note otherwise)

        Private VLAN map: VPGM-T-Src has 600 promiscuous, 601 isolated and 602
        community; VPGM-T-Dst has 600 and 601 only, so an import of
        VPGM-T-Pvlan602 into VPGM-T-Dst must be skipped with a clear message
        (#25). VPGM-T-Dst has no VM vNIC network resource pool, so VPGM-T-Nioc
        gets the default pool there with a warning (#20).

    -Mode Show prints VLAN, binding, teaming and security of every VPGM-T-*
    port group on every VPGM-T-* switch, so an import can be compared with
    the source. -Mode Remove deletes every VPGM-T-* switch (and with it its
    port groups). Nothing else is touched.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create, Show or Remove.

.PARAMETER Datacenter
    Datacenter to create the switches in. Defaults to the first one.

.PARAMETER CredentialPath
    Defaults to <vCenterServer>.cred in the parent folder (the same file
    Invoke-VDSPortGroupManager.ps1 uses).

.PARAMETER SkipCertificateValidation
    Accept self-signed lab certificates.

.NOTES
    Script   : New-VPGMUplinkTestSet.ps1
    Version  : 1.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+
    Tested   : see the README of VDSPortGroupManager
#>

<# CHANGELOG
    v1.1.0  2026-11-19  Paul van Dieen
        - Broader set: private VLAN port groups (601 isolated, 602 community)
          with a full PVLAN map on VPGM-T-Src and 600/601 only on
          VPGM-T-Dst (#25); MAC learning (SecurityPolicy and
          MacManagementPolicy overlap); a VM vNIC network resource pool when
          the switch accepts NIOC (#20)
        - Show has columns for MAC learning and the network resource pools

    v1.0.1  2026-11-18  Paul van Dieen
        - Get-Help shows the full help again: the changelog moved out of the
          help block into its own comment block (the unknown .CHANGELOG
          keyword made Get-Help ignore the whole help block)
        - Blank line between #Requires and the help block, for the same reason

    v1.0.0  2026-11-13  Paul van Dieen
        - Initial release: Create / Show / Remove of the uplink-name test set
          for Invoke-VDSPortGroupManager.ps1 v1.2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$vCenterServer,
    [Parameter(Mandatory = $true)][ValidateSet('Create', 'Show', 'Remove')][string]$Mode,
    [string]$Datacenter = '',
    [string]$CredentialPath = '',
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.1.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$prefix        = 'VPGM-T-'

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VPGMUplinkTestSet.ps1' + (' ' * 20) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  $scriptAuthor - $scriptBlogUrl" -ForegroundColor Gray
Write-Host '  LAB USE ONLY - touches VPGM-T-* objects only' -ForegroundColor Yellow
Write-Host ('=' * 62) -ForegroundColor DarkCyan

if (-not $CredentialPath) {
    $safeVc = $vCenterServer -replace '[^\w\-.]', '_'
    $CredentialPath = Join-Path (Split-Path $PSScriptRoot -Parent) "$safeVc.cred"
}
if (-not (Test-Path $CredentialPath)) { throw "No credential file at $CredentialPath. Create it first." }
$credential = Import-Clixml -Path $CredentialPath

Import-Module VCF.PowerCLI -ErrorAction Stop 3>$null
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Write-Host "  Connected to $vCenterServer (version $($vi.Version), build $($vi.Build))" -ForegroundColor Green

function Set-UplinkNames {
    param($Switch, [string[]]$Names)
    $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
    $spec.ConfigVersion = $Switch.ExtensionData.Config.ConfigVersion
    $spec.UplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
    $spec.UplinkPortPolicy.UplinkPortName = $Names
    $Switch.ExtensionData.ReconfigureDvs($spec)
    return Get-VDSwitch -Server $vi -Name $Switch.Name
}

function Add-PvlanMap {
    param($Switch, [int[]]$Secondary)
    $sw = Get-VDSwitch -Server $vi -Name $Switch.Name
    $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
    $spec.ConfigVersion = $sw.ExtensionData.Config.ConfigVersion
    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.Add(@(600, 600, 'promiscuous'))
    foreach ($sec in $Secondary) { $entries.Add(@(600, $sec, $(if ($sec % 2) { 'isolated' } else { 'community' }))) }
    $spec.PvlanConfigSpec = @($entries | ForEach-Object {
        $e = New-Object VMware.Vim.VMwareDVSPvlanMapEntry
        $e.PrimaryVlanId = $_[0]; $e.SecondaryVlanId = $_[1]; $e.PvlanType = $_[2]
        New-Object VMware.Vim.VMwareDVSPvlanConfigSpec -Property @{ Operation = 'add'; PvlanEntry = $e }
    })
    $sw.ExtensionData.ReconfigureDvs($spec)
}

function Add-VnicPool {
    # NIOC on, a VM traffic reservation and one VM vNIC network resource pool.
    # Returns the pool key, or $null when vCenter refuses (host-less switch).
    param($Switch)
    try {
        $sw = Get-VDSwitch -Server $vi -Name $Switch.Name
        $sw.ExtensionData.EnableNetworkResourceManagement($true)
        $sw = Get-VDSwitch -Server $vi -Name $Switch.Name
        $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
        $spec.ConfigVersion = $sw.ExtensionData.Config.ConfigVersion
        $vmTraffic = @($sw.ExtensionData.Config.InfrastructureTrafficResourceConfig | Where-Object { $_.Key -eq 'virtualMachine' })[0]
        $vmTraffic.AllocationInfo.Reservation = [long]100
        $spec.InfrastructureTrafficResourceConfig = @($vmTraffic)
        $sw.ExtensionData.ReconfigureDvs($spec)
        $pool = New-Object VMware.Vim.DvsVmVnicResourcePoolConfigSpec
        $pool.Operation = 'add'; $pool.Name = 'VPGM-T-Pool'; $pool.Description = 'VPGM test pool'
        $pool.AllocationInfo = New-Object VMware.Vim.DvsVmVnicResourceAllocation -Property @{ ReservationQuota = [long]10 }
        $sw.ExtensionData.DvsReconfigureVmVnicNetworkResourcePool(@($pool))
        $sw = Get-VDSwitch -Server $vi -Name $Switch.Name
        return @($sw.ExtensionData.Config.VmVnicNetworkResourcePool | Where-Object { $_.Name -eq 'VPGM-T-Pool' })[0].Key
    } catch {
        Write-Host "  NIOC pool not created on $($Switch.Name): $($_.Exception.Message -replace '\s+', ' ')" -ForegroundColor DarkYellow
        return $null
    }
}

function Show-PortGroup {
    param($Pg)
    $v = $Pg.ExtensionData.Config.DefaultPortConfig.Vlan
    $vlan = switch ($v.GetType().Name) {
        'VmwareDistributedVirtualSwitchVlanIdSpec'    { "VLAN $($v.VlanId)" }
        'VmwareDistributedVirtualSwitchTrunkVlanSpec' { 'trunk ' + (($v.VlanId | ForEach-Object { if ($_.Start -eq $_.End) { $_.Start } else { "$($_.Start)-$($_.End)" } }) -join ',') }
        'VmwareDistributedVirtualSwitchPvlanSpec'     { "PVLAN $($v.PvlanId)" }
        default { $v.GetType().Name }
    }
    $t = Get-VDUplinkTeamingPolicy -VDPortgroup $Pg -Server $vi
    $s = Get-VDSecurityPolicy -VDPortgroup $Pg -Server $vi
    [pscustomobject]@{
        Switch    = $Pg.VDSwitch.Name
        PortGroup = $Pg.Name
        Vlan      = $vlan
        Binding   = "$($Pg.PortBinding)"
        Ports     = $Pg.NumPorts
        LB        = "$($t.LoadBalancingPolicy)"
        Order     = if ($t.UplinkPortOrderInherited) { 'inherited' } else { "A: $($t.ActiveUplinkPort -join '+') | S: $($t.StandbyUplinkPort -join '+') | U: $($t.UnusedUplinkPort -join '+')" }
        Security  = "P:$($s.AllowPromiscuous) M:$($s.MacChanges) F:$($s.ForgedTransmits)"
        Alloc     = if ($Pg.ExtensionData.Config.AutoExpand) { 'elastic' } else { 'fixed' }
        InShaping = if ($Pg.ExtensionData.Config.DefaultPortConfig.InShapingPolicy.Enabled.Value) { "on $($Pg.ExtensionData.Config.DefaultPortConfig.InShapingPolicy.AverageBandwidth.Value)" } else { 'off' }
        NetFlow   = [bool]$Pg.ExtensionData.Config.DefaultPortConfig.IpfixEnabled.Value
        ResetDisc = $Pg.ExtensionData.Config.Policy.PortConfigResetAtDisconnect
        Descr     = "$($Pg.ExtensionData.Config.Description)"
        MacLearn  = $(try { $ml = $Pg.ExtensionData.Config.DefaultPortConfig.MacManagementPolicy.MacLearningPolicy; if ($ml -and $ml.Enabled) { "on $($ml.Limit) $($ml.LimitPolicy)" } else { 'off' } } catch { '?' })
        VnicPool  = "$($Pg.ExtensionData.Config.VmVnicNetworkResourcePoolKey)"
    }
}

switch ($Mode) {
    'Create' {
        $dc = if ($Datacenter) { Get-Datacenter -Server $vi -Name $Datacenter } else { Get-Datacenter -Server $vi | Sort-Object Name | Select-Object -First 1 }
        if (Get-VDSwitch -Server $vi -Name "$prefix*" -ErrorAction SilentlyContinue) { throw "VPGM-T-* switches already exist; run -Mode Remove first." }
        Write-Host "  Datacenter: $($dc.Name)"
        $src = New-VDSwitch -Server $vi -Name "${prefix}Src" -Location $dc -NumUplinkPorts 2
        $src = Set-UplinkNames -Switch $src -Names @('Uplink 1', 'Uplink 2')
        $dst = New-VDSwitch -Server $vi -Name "${prefix}Dst" -Location $dc -NumUplinkPorts 2
        $dst = Set-UplinkNames -Switch $dst -Names @('uplink1', 'uplink2')
        Write-Host "  Created $($src.Name) [$($src.ExtensionData.Config.UplinkPortPolicy.UplinkPortName -join ', ')] and $($dst.Name) [$($dst.ExtensionData.Config.UplinkPortPolicy.UplinkPortName -join ', ')], version $($src.Version), no hosts" -ForegroundColor Green

        $pg1 = New-VDPortgroup -Server $vi -VDSwitch $src -Name "${prefix}Vlan101" -VlanId 101
        $null = Get-VDUplinkTeamingPolicy -VDPortgroup $pg1 -Server $vi | Set-VDUplinkTeamingPolicy -LoadBalancingPolicy ExplicitFailover -ActiveUplinkPort 'Uplink 1' -StandbyUplinkPort 'Uplink 2' -Confirm:$false
        $null = Get-VDSecurityPolicy -VDPortgroup $pg1 -Server $vi | Set-VDSecurityPolicy -ForgedTransmits $true -Confirm:$false

        $null = New-VDPortgroup -Server $vi -VDSwitch $src -Name "${prefix}Trunk" -VlanTrunkRange '200-210,300'

        $pg3 = New-VDPortgroup -Server $vi -VDSwitch $src -Name "${prefix}Eph" -PortBinding Ephemeral
        $null = Get-VDUplinkTeamingPolicy -VDPortgroup $pg3 -Server $vi | Set-VDUplinkTeamingPolicy -ActiveUplinkPort 'Uplink 2' -UnusedUplinkPort 'Uplink 1' -Confirm:$false

        # Settings that only the complete configuration carries: traffic
        # shaping, fixed allocation, NetFlow, a description, no reset at disconnect
        $pg4 = New-VDPortgroup -Server $vi -VDSwitch $src -Name "${prefix}Adv" -VlanId 150 -NumPorts 16
        $null = Get-VDUplinkTeamingPolicy -VDPortgroup $pg4 -Server $vi | Set-VDUplinkTeamingPolicy -ActiveUplinkPort 'Uplink 2' -StandbyUplinkPort 'Uplink 1' -Confirm:$false
        $pg4 = Get-VDPortgroup -Server $vi -Name "${prefix}Adv"
        $spec = New-Object VMware.Vim.DVPortgroupConfigSpec
        $spec.ConfigVersion = $pg4.ExtensionData.Config.ConfigVersion
        $spec.Description   = 'VPGM test: shaping, fixed allocation, NetFlow'
        $spec.AutoExpand    = $false
        $set = New-Object VMware.Vim.VMwareDVSPortSetting
        $shape = New-Object VMware.Vim.DVSTrafficShapingPolicy
        $shape.Inherited = $false
        $shape.Enabled = New-Object VMware.Vim.BoolPolicy -Property @{ Inherited = $false; Value = $true }
        $shape.AverageBandwidth = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]100000000 }
        $shape.PeakBandwidth    = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]200000000 }
        $shape.BurstSize        = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]104857600 }
        $set.InShapingPolicy = $shape
        $set.IpfixEnabled = New-Object VMware.Vim.BoolPolicy -Property @{ Inherited = $false; Value = $true }
        $spec.DefaultPortConfig = $set
        $spec.Policy = $pg4.ExtensionData.Config.Policy
        $spec.Policy.PortConfigResetAtDisconnect = $false
        $pg4.ExtensionData.ReconfigureDVPortgroup($spec)
        # Private VLANs (#25): full map on the source, 600/601 only on the target
        Add-PvlanMap -Switch $src -Secondary 601, 602
        Add-PvlanMap -Switch $dst -Secondary 601
        foreach ($pv in 601, 602) {
            $ps = New-Object VMware.Vim.DVPortgroupConfigSpec
            $ps.Name = "${prefix}Pvlan$pv"; $ps.Type = 'earlyBinding'; $ps.NumPorts = 8; $ps.AutoExpand = $true
            $ps.DefaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting
            $ps.DefaultPortConfig.Vlan = New-Object VMware.Vim.VmwareDistributedVirtualSwitchPvlanSpec -Property @{ Inherited = $false; PvlanId = $pv }
            (Get-VDSwitch -Server $vi -Name $src.Name).ExtensionData.AddDVPortgroup(@($ps))
        }
        # MAC learning: MacManagementPolicy with learning on, plus forged
        # transmits and MAC changes allowed (overlaps with SecurityPolicy)
        $ms = New-Object VMware.Vim.DVPortgroupConfigSpec
        $ms.Name = "${prefix}MacLearn"; $ms.Type = 'earlyBinding'; $ms.NumPorts = 8; $ms.AutoExpand = $true
        $ms.DefaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting
        $ms.DefaultPortConfig.Vlan = New-Object VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec -Property @{ Inherited = $false; VlanId = 160 }
        $mm = New-Object VMware.Vim.DVSMacManagementPolicy
        $mm.Inherited = $false; $mm.AllowPromiscuous = $false; $mm.MacChanges = $true; $mm.ForgedTransmits = $true
        $mm.MacLearningPolicy = New-Object VMware.Vim.DVSMacLearningPolicy -Property @{ Inherited = $false; Enabled = $true; AllowUnicastFlooding = $true; Limit = 4096; LimitPolicy = 'DROP' }
        $ms.DefaultPortConfig.MacManagementPolicy = $mm
        (Get-VDSwitch -Server $vi -Name $src.Name).ExtensionData.AddDVPortgroup(@($ms))
        # VM vNIC network resource pool (#20), only if vCenter accepts it here
        $poolKey = Add-VnicPool -Switch $src
        if ($poolKey) {
            $ns = New-Object VMware.Vim.DVPortgroupConfigSpec
            $ns.Name = "${prefix}Nioc"; $ns.Type = 'earlyBinding'; $ns.NumPorts = 8; $ns.AutoExpand = $true
            $ns.DefaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting
            $ns.DefaultPortConfig.Vlan = New-Object VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec -Property @{ Inherited = $false; VlanId = 170 }
            $ns.VmVnicNetworkResourcePoolKey = $poolKey
            (Get-VDSwitch -Server $vi -Name $src.Name).ExtensionData.AddDVPortgroup(@($ns))
        }
        Write-Host "  Created the test port groups on VPGM-T-Src$(if (-not $poolKey) { ' (without VPGM-T-Nioc)' })." -ForegroundColor Green
        Get-VDSwitch -Server $vi -Name "$prefix*" | Get-VDPortgroup -Server $vi | Where-Object { -not $_.IsUplink -and $_.Name -like "$prefix*" } |
            Sort-Object { $_.VDSwitch.Name }, Name | ForEach-Object { Show-PortGroup $_ } | Format-Table -AutoSize -Property * | Out-String -Width 400 | Write-Host
    }
    'Show' {
        Get-VDSwitch -Server $vi -Name "$prefix*" -ErrorAction SilentlyContinue | Get-VDPortgroup -Server $vi |
            Where-Object { -not $_.IsUplink } |
            Sort-Object { $_.VDSwitch.Name }, Name | ForEach-Object { Show-PortGroup $_ } | Format-Table -AutoSize -Property * | Out-String -Width 400 | Write-Host
    }
    'Remove' {
        $switches = @(Get-VDSwitch -Server $vi -Name "$prefix*" -ErrorAction SilentlyContinue)
        foreach ($sw in $switches) {
            Remove-VDSwitch -VDSwitch $sw -Server $vi -Confirm:$false
            Write-Host "  Removed $($sw.Name)" -ForegroundColor Green
        }
        if ($switches.Count -eq 0) { Write-Host '  Nothing to remove.' }
    }
}
Disconnect-VIServer -Server $vi -Confirm:$false
