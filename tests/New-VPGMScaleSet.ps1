#Requires -Version 7.4

<#
.SYNOPSIS
    Builds or removes a large throwaway set of distributed port groups in a
    LAB vCenter, to test Invoke-VDSPortGroupManager.ps1 at scale.

.DESCRIPTION
    Lab use only. Everything it creates is named VPGM-S-*, and Remove only
    deletes VPGM-S-* switches (with their port groups).

    Create  -SwitchCount host-less distributed switches (default 3,
            VPGM-S-VDS-1 and up; four uplinks 'uplink1'..'uplink4'; a PVLAN
            map 500 promiscuous, 501 isolated, 502 community) with
            -PortGroupCount port groups in total (default 1500, spread
            evenly), VPGM-S-<switch>-<nnnn>. The port groups take turns:
              VLAN 1-4094, a trunk range, a PVLAN (501 or 502)
              static (8 ports, elastic) or, every tenth, ephemeral binding
              teaming: inherited, route based on originating port with
              uplink1+2 active / 3 standby, explicit failover, or load based
              security: inherited, or forged transmits + MAC changes allowed
              every fifth: ingress traffic shaping
            Port groups are created 100 per AddDVPortgroup_Task.
            -WithTargetSwitch also creates an empty switch VPGM-S-Target
            (same uplinks and PVLAN map) to import into.
            Running Create again adds what is missing.
    Remove  Deletes every VPGM-S-* switch and its port groups.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create or Remove.

.PARAMETER SwitchCount
    Number of source switches (Create). Default 3.

.PARAMETER PortGroupCount
    Total number of port groups over the source switches (Create). Default 1500.

.PARAMETER WithTargetSwitch
    Create mode: also create the empty switch VPGM-S-Target.

.PARAMETER Datacenter
    Datacenter for the switches. Defaults to the first datacenter.

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred in the repo root
    (where Invoke-VDSPortGroupManager.ps1 keeps it).

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.EXAMPLE
    .\New-VPGMScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Create -WithTargetSwitch

.EXAMPLE
    .\New-VPGMScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Remove

.NOTES
    Script   : New-VPGMScaleSet.ps1
    Version  : 0.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : Lab, 2026-11-19: VCF 9.1.1 (Holodeck)
#>

<# CHANGELOG
    v0.1.0  2026-11-19  Paul van Dieen
        - Initial version: Create and Remove of a large port group set for
          scale tests of Invoke-VDSPortGroupManager.ps1 (#24)
#>

param(
    [Parameter(Mandatory = $true)][string]$vCenterServer,
    [Parameter(Mandatory = $true)][ValidateSet('Create', 'Remove')][string]$Mode,
    [ValidateRange(1, 20)][int]$SwitchCount = 3,
    [ValidateRange(1, 20000)][int]$PortGroupCount = 1500,
    [switch]$WithTargetSwitch,
    [string]$Datacenter = '',
    [string]$CredentialPath = '',
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '0.1.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$prefix        = 'VPGM-S-'
$uplinks       = @('uplink1', 'uplink2', 'uplink3', 'uplink4')

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VPGMScaleSet.ps1' + (' ' * 25) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host '  LAB USE ONLY - touches VPGM-S-* objects only' -ForegroundColor Yellow
Write-Host ('=' * 62) -ForegroundColor DarkCyan

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path (Split-Path $PSScriptRoot -Parent) "$safeVc.cred" }
$credential = if (Test-Path $CredentialPath) { Import-Clixml -Path $CredentialPath } else { Get-Credential -Message "Credentials for $vCenterServer" }
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" Green

function Wait-VimTask {
    param($TaskRef)
    $null = Get-Task -Server $vi -Id "Task-$($TaskRef.Value)" | Wait-Task
}

function New-ScaleSwitch {
    # Host-less switch with four named uplinks and a PVLAN map; returns its view
    param($Dc, [string]$Name)
    $sw = Get-VDSwitch -Server $vi -Name $Name -ErrorAction SilentlyContinue
    if (-not $sw) {
        $sw = New-VDSwitch -Server $vi -Name $Name -Location $Dc -NumUplinkPorts $uplinks.Count
        $view = $sw.ExtensionData
        $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
        $spec.ConfigVersion = $view.Config.ConfigVersion
        $spec.UplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
        $spec.UplinkPortPolicy.UplinkPortName = $uplinks
        $pv = foreach ($e in @(@(500, 500, 'promiscuous'), @(500, 501, 'isolated'), @(500, 502, 'community'))) {
            $entry = New-Object VMware.Vim.VMwareDVSPvlanMapEntry
            $entry.PrimaryVlanId = $e[0]; $entry.SecondaryVlanId = $e[1]; $entry.PvlanType = $e[2]
            $ps = New-Object VMware.Vim.VMwareDVSPvlanConfigSpec
            $ps.Operation = 'add'; $ps.PvlanEntry = $entry
            $ps
        }
        $spec.PvlanConfigSpec = @($pv)
        Wait-VimTask $view.ReconfigureDvs_Task($spec)
        Say "Created switch $Name (uplinks $($uplinks -join ', '), PVLAN 500/501/502)"
    }
    return (Get-View -Server $vi -Id $sw.ExtensionData.MoRef)
}

function BoolP { param([bool]$Value) New-Object VMware.Vim.BoolPolicy -Property @{ Inherited = $false; Value = $Value } }

function New-PortGroupSpec {
    param([string]$Name, [int]$No)
    $spec = New-Object VMware.Vim.DVPortgroupConfigSpec
    $spec.Name = $Name
    $spec.Description = 'VDSPortGroupManager scale test - safe to delete'
    if ($No % 10 -eq 0) {
        $spec.Type = 'ephemeral'
    } else {
        $spec.Type = 'earlyBinding'; $spec.NumPorts = 8; $spec.AutoExpand = $true
    }
    $set = New-Object VMware.Vim.VMwareDVSPortSetting
    switch ($No % 3) {
        0 {
            $v = New-Object VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec
            $v.Inherited = $false; $v.VlanId = 1 + ($No % 4094)
        }
        1 {
            $v = New-Object VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec
            $v.Inherited = $false
            $lo = 1 + (($No * 7) % 4000)
            $v.VlanId = @((New-Object VMware.Vim.NumericRange -Property @{ Start = $lo; End = $lo + 10 }),
                          (New-Object VMware.Vim.NumericRange -Property @{ Start = $lo + 50; End = $lo + 50 }))
        }
        2 {
            $v = New-Object VMware.Vim.VmwareDistributedVirtualSwitchPvlanSpec
            $v.Inherited = $false; $v.PvlanId = @(501, 502)[$No % 2]
        }
    }
    $set.Vlan = $v
    switch ($No % 4) {
        1 {
            $t = New-Object VMware.Vim.VmwareUplinkPortTeamingPolicy
            $t.Inherited = $false
            $t.Policy = New-Object VMware.Vim.StringPolicy -Property @{ Inherited = $false; Value = 'loadbalance_srcid' }
            $t.UplinkPortOrder = New-Object VMware.Vim.VMwareUplinkPortOrderPolicy -Property @{ Inherited = $false; ActiveUplinkPort = [string[]]@('uplink1', 'uplink2'); StandbyUplinkPort = [string[]]@('uplink3') }
            $set.UplinkTeamingPolicy = $t
        }
        2 {
            $t = New-Object VMware.Vim.VmwareUplinkPortTeamingPolicy
            $t.Inherited = $false
            $t.Policy = New-Object VMware.Vim.StringPolicy -Property @{ Inherited = $false; Value = 'failover_explicit' }
            $t.UplinkPortOrder = New-Object VMware.Vim.VMwareUplinkPortOrderPolicy -Property @{ Inherited = $false; ActiveUplinkPort = [string[]]@('uplink2'); StandbyUplinkPort = [string[]]@('uplink1') }
            $set.UplinkTeamingPolicy = $t
        }
        3 {
            $t = New-Object VMware.Vim.VmwareUplinkPortTeamingPolicy
            $t.Inherited = $false
            $t.Policy = New-Object VMware.Vim.StringPolicy -Property @{ Inherited = $false; Value = 'loadbalance_loadbased' }
            $set.UplinkTeamingPolicy = $t
        }
    }
    if ($No % 2 -eq 1) {
        $s = New-Object VMware.Vim.DVSSecurityPolicy
        $s.Inherited = $false
        $s.AllowPromiscuous = BoolP $false
        $s.MacChanges = BoolP $true
        $s.ForgedTransmits = BoolP $true
        $set.SecurityPolicy = $s
    }
    if ($No % 5 -eq 0) {
        $shape = New-Object VMware.Vim.DVSTrafficShapingPolicy
        $shape.Inherited = $false
        $shape.Enabled = BoolP $true
        $shape.AverageBandwidth = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]100000000 }
        $shape.PeakBandwidth    = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]200000000 }
        $shape.BurstSize        = New-Object VMware.Vim.LongPolicy -Property @{ Inherited = $false; Value = [long]104857600 }
        $set.InShapingPolicy = $shape
    }
    $spec.DefaultPortConfig = $set
    return $spec
}

try {
    if ($Mode -eq 'Create') {
        $started = Get-Date
        $dc = if ($Datacenter) { Get-Datacenter -Server $vi -Name $Datacenter } else { Get-Datacenter -Server $vi | Sort-Object Name | Select-Object -First 1 }
        Say "Datacenter: $($dc.Name)"
        $made = 0; $had = 0
        $left = $PortGroupCount
        for ($s = 1; $s -le $SwitchCount; $s++) {
            $swName = "${prefix}VDS-$s"
            $view = New-ScaleSwitch -Dc $dc -Name $swName
            $want = if ($s -eq $SwitchCount) { $left } else { [int][Math]::Floor($PortGroupCount / $SwitchCount) }
            $left -= $want
            $existing = @{}
            $pgRefs = @($view.Portgroup)
            if ($pgRefs.Count -gt 0) { foreach ($v in @(Get-View -Server $vi -Id $pgRefs -Property Name)) { $existing[$v.Name] = 1 } }
            $specs = New-Object System.Collections.Generic.List[object]
            for ($n = 1; $n -le $want; $n++) {
                $pgName = '{0}{1}-{2:D4}' -f $prefix, $s, $n
                if ($existing.ContainsKey($pgName)) { $had++; continue }
                $specs.Add((New-PortGroupSpec -Name $pgName -No $n))
            }
            for ($i = 0; $i -lt $specs.Count; $i += 100) {
                $chunk = $specs.GetRange($i, [Math]::Min(100, $specs.Count - $i)).ToArray()
                Wait-VimTask $view.AddDVPortgroup_Task([VMware.Vim.DVPortgroupConfigSpec[]]$chunk)
                $made += $chunk.Count
                Write-Progress -Activity "Creating port groups on $swName" -Status "$($i + $chunk.Count) of $($specs.Count)" -PercentComplete ([int](100 * ($i + $chunk.Count) / $specs.Count))
                Say "  $swName`: $($i + $chunk.Count) of $($specs.Count) created"
            }
            Write-Progress -Activity "Creating port groups on $swName" -Completed
        }
        if ($WithTargetSwitch) { $null = New-ScaleSwitch -Dc $dc -Name "${prefix}Target" }
        Say ("Done in {0:mm\:ss}: {1} port group(s) created, {2} already there, on {3} switch(es)." -f ((Get-Date) - $started), $made, $had, $SwitchCount) Green
    }
    else {
        $switches = @(Get-VDSwitch -Server $vi -Name "$prefix*" -ErrorAction SilentlyContinue)
        foreach ($sw in $switches) {
            $n = @($sw.ExtensionData.Portgroup).Count
            Remove-VDSwitch -VDSwitch $sw -Server $vi -Confirm:$false
            Say "Removed $($sw.Name) with $n port group(s) (uplink group included)" Yellow
        }
        if ($switches.Count -eq 0) { Say 'Nothing to remove.' }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
