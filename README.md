# VDSPortGroupManager

A PowerShell utility to export, import, or delete vSphere Distributed Switch (VDS) port groups interactively — useful for backing up port groups before changes, migrating them between switches or vCenters, and cleaning up with proper safeguards.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VDSPortGroupManager.ps1` | 1.5.1 | Export / import / delete VDS port groups, also onto a switch with other uplink names — lab-tested on vCenter 9.1.1 and 9.0.2, and from vCenter 8.0 U3 to 9.1.1 (vSphere 7 not tested, out of scope) |
| `tests/New-VPGMUplinkTestSet.ps1` | 1.0.1 | Builds, shows and removes a throwaway test set in a **lab** vCenter |

---

## How it works

The script connects to a vCenter, then runs one of three modes. Pass `-Mode Export|Import|Delete`, or omit it to pick from a menu. Every picker supports single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel` (`exit`, `quit` and `q` work too). Long lists: filter by name with a wildcard (`*prod*`) or `/text` for a substring; the list is renumbered and `all` takes what the filter shows (`reset` clears it). Above 50 items the picker shows the count and a few examples instead of the whole list (`list` shows everything); above 20 selected items the confirmation shows the count and the first and last 5. To skip the port group picker, pass `-PortGroupName` (Export, Delete) or `-BackupName` (Import) with names or wildcards; to skip the switch menu, pass `-VDSwitchName`. With all three (and a saved credential) an Export or Import runs unattended. In an interactive run without `-BackupDirectory`, the script asks for the backup directory right after the mode: Enter keeps `Backups\` next to the script, `B` opens the Windows folder browser, or type a path (Import shows how many backups the folder holds). Without console input, every prompt stops the script with a message naming the parameters to pass. Every action is logged to the console and a timestamped log file.

### Export

1. Pick the source VDS.
2. Pick one or more port groups. Each entry shows its VLAN configuration and port count; uplink port groups are excluded.
3. Each selected port group is exported to a portable zip (`<portgroup>.zip`) in the backup directory using the native `Export-VDPortGroup` backup format.
4. Next to each zip, a **settings file** `<portgroup>.json` is written: the port group's complete configuration as the vSphere API returns it (`DVPortgroupConfigInfo`: VLAN, teaming, security, traffic shaping, NetFlow, blocking, filtering, override and reset settings, allocation, NIOC pool, description), with a readable `Summary` on top. Import uses it when the zip alone can't do the job (see below).

> **NSX note:** port groups backed by NSX segments (created by NSX, vSphere with Tanzu / VKS, or VPCs — e.g. `pod-default-*`, `kubernetes-cluster-*`) **cannot be exported** — the vCenter backup API does not support them and their configuration lives in NSX Manager. The picker tags them `[NSX-backed]` and the export skips them with a clear message instead of failing. The summary reports `succeeded / skipped (NSX-backed) / failed`.

### Import

1. Pick one or more zips from the backup directory.
2. Pick the target VDS — or choose **`<Create a NEW VDS and import into it>`**, which prompts for:
   - the datacenter (auto-selected when the vCenter has only one),
   - a name (must not exist yet),
   - the settings: either **clone version, uplink count, uplink port names, and MTU from an existing VDS**, or enter them manually (blank = vCenter defaults).
3. The script checks the chosen names against **all** port groups in the datacenter — vCenter requires distributed port group names to be unique per datacenter, across all switches, so restoring into the same datacenter needs a rename. If clashes are found and no `-NamePrefix` / `-NameSuffix` was given, it prompts for a prefix/suffix interactively.
4. Each zip is imported with `New-VDPortgroup -BackupPath`. Anything still clashing is skipped (with the owning switch named in the message), not failed.

A freshly created VDS has **no hosts attached**; add hosts before workloads can use the imported port groups.

### Other uplink names on the target switch

An exported port group's teaming policy names its uplinks (`Uplink 1`, `uplink1`, `lag1`, ...). Restoring the zip onto a switch with other names fails in vCenter with `activeUplinkPortName ... is not valid`. That's the usual case in a migration: an older source switch with `Uplink 1` / `Uplink 2`, a VCF-built target switch with `uplink1` / `uplink2`.

Before each import, the script compares the uplink names the port group uses with the target switch's (a port group whose uplink order is inherited from its switch has none of its own and needs no check):

- **All names exist:** the zip is restored as before.
- **Names are missing:** they're reported **before** anything is created, and the port group is rebuilt from its settings file with the names mapped, in one `CreateDVPortgroup` call (all or nothing). The mapping comes from `-UplinkMap`, or from a prompt per missing name with a *skip* option:

  ```powershell
  .\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -UplinkMap @{ 'Uplink 1' = 'uplink1'; 'Uplink 2' = 'uplink2' }
  ```

  Uplinks that are unused in the source port group need no mapping. A LACP LAG mapped to a plain uplink gets a warning to check the load-balancing policy. A NIOC network resource pool the target switch doesn't have falls back to the default, with a warning.

**Restoring a zip from a newer vCenter onto an older one fails** (*"Uncompress and Deserialize failed on backup config blob"*, lab-verified 9.1.1 → 9.0.2). When that happens and a settings file exists, the script rebuilds the port group from it instead.

What a rebuild carries was checked in the lab by exporting the result again and comparing the complete configuration field by field with the source: identical on all 141 to 147 fields, inherited flags included, for VLAN, trunk, ephemeral binding, explicit failover order, traffic shaping, fixed allocation, NetFlow, description and reset-at-disconnect, between vCenter 9.1.1 and 9.0.2 in both directions.

Zips without a settings file (exported with v1.1.x) are restored as before, without the check.

### Delete

1. Pick the VDS, then the port groups to delete.
2. Port groups still in use by VMs are flagged — deleting those will fail server-side until the VMs are moved.
3. The script offers a safety export to zip first, then requires a typed `YES` before deleting anything.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 7.4+ | VCF.PowerCLI 9.x needs PowerShell 7 ([KB 409981](https://knowledge.broadcom.com/external/article/409981)); Windows ships 5.1, so start the script from `pwsh` |
| VCF.PowerCLI 9.0+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI 13+ also works) |
| Network access | HTTPS to vCenter Server |

Setting up PowerShell 7 and VCF.PowerCLI on a jump host, with or without internet access, and keeping one PowerCLI version per host: [Jump Host: PowerShell 7 and VCF PowerCLI](https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/).

**Which PowerCLI it loads.** The script imports only `VMware.VimAutomation.Vds` (and what it requires), not the whole VCF.PowerCLI bundle. If PowerCLI modules of different versions are already loaded in the session, or the import fails, it stops with the short error, the loaded modules and a link to the jump-host guide above: run it from a clean `pwsh -NoProfile` and keep one complete PowerCLI version per host. (v1.2.1 picked a PowerCLI build itself; v1.3.0 dropped that and `-PowerCLIBuild`, because it hid a broken jump host that other tools still fail on.)

## Usage

```powershell
# Fully interactive — pick the mode from a menu
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab

# Export selected port groups (default backup directory: .\Backups)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export

# Export to a specific directory
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -BackupDirectory C:\Backups\VDS

# Import, and pick the backup folder in a dialog: press B at the directory prompt
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import

# Import port groups from backups in a given folder
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -BackupDirectory C:\Backups\VDS

# Import and rename with a prefix and suffix
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -NamePrefix "NEW-" -NameSuffix "-v2"

# Import onto a switch with other uplink names (e.g. a VCF-built switch)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -UplinkMap @{ 'Uplink 1' = 'uplink1'; 'Uplink 2' = 'uplink2' }

# Export or import by name, without the picker (names or wildcards)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -PortGroupName 'pg-*-prod', 'VLAN100'
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -BackupName 'pg-*-prod'

# Unattended: switch, port groups and mode as parameters (credential saved by an earlier interactive run)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -VDSwitchName 'vds-01' -PortGroupName 'pg-*'

# Delete port groups (flags in-use port groups, offers safety export, requires typed YES)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Delete

# Lab environment with self-signed certificate
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -SkipCertificateValidation
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-vCenterServer` | *(required)* | vCenter Server FQDN or IP |
| `-Mode` | interactive menu | `Export`, `Import`, or `Delete` |
| `-BackupDirectory` | `Backups\` next to the script; an interactive run asks (Enter, `B` = folder browser, or a path) | Where zips are written (Export) or read (Import) |
| `-LogDirectory` | `Logs\` next to the script | Where the per-run log file is written |
| `-NamePrefix` / `-NameSuffix` | none | Rename port groups on import; prompted for interactively when name clashes are detected |
| `-UplinkMap` | none | Import: source uplink name → target uplink name, e.g. `@{ 'Uplink 1' = 'uplink1' }`; prompted for interactively per missing name |
| `-PortGroupName` | none | Export / Delete: port group names or wildcards to act on, instead of the picker |
| `-VDSwitchName` | none | All modes: exact name of the VDS, instead of the switch menu; an unknown name stops with the list of switches. Creating a new VDS on import stays interactive |
| `-BackupName` | none | Import: backup zip names or wildcards (with or without `.zip`), instead of the picker |
| `-CredentialPath` | `<vCenterServer>.cred` next to the script | Alternate saved-credential file |
| `-ResetCredentials` | off | Force a new credential prompt |
| `-SkipCertificateValidation` | off | Accept self-signed vCenter certificates (labs) |

## Credentials

On first run the script prompts for credentials and saves them encrypted to `<vCenterServer>.cred` next to the script (`Export-Clixml`, DPAPI-protected, tied to the current Windows user and machine). Subsequent runs reuse the file automatically. Use `-ResetCredentials` to force a new prompt, or `-CredentialPath` to point at a different file.

Credential files are excluded from git via `.gitignore`.

## Output

| Path | Content |
|---|---|
| `Backups\` (default) | Exported port group zip files `<portgroup>.zip`, and settings files `<portgroup>.json` |
| `Logs\` | Timestamped log file per run |

Both directories are created automatically and excluded from git.

## Testing in a lab

`tests/New-VPGMUplinkTestSet.ps1` builds a test set in a **lab** vCenter (`-Mode Create`): two host-less switches, `VPGM-T-Src` (uplinks `Uplink 1/2`) and `VPGM-T-Dst` (`uplink1/2`, like VCF), and four port groups on the source covering VLAN, trunk with inherited order, ephemeral binding, explicit failover order, traffic shaping, fixed allocation, NetFlow and a description. `-Mode Show` lists their settings side by side; `-Mode Remove` deletes the two switches. It only touches `VPGM-T-*` objects and uses the same `.cred` file as the main script.

Suggested run: Create, Export from `VPGM-T-Src`, Import onto `VPGM-T-Dst` without a map (the port groups with their own uplink order are reported and can be skipped), Import with `-UplinkMap`, Export the result and compare the `Spec` in the settings files, Remove.

Lab findings (Holodeck, vCenter 9.1.1 and 9.0.2, 2026-11-13):

- A port group backup zip from vCenter 9.1.1 can't be restored on 9.0.2 (*"Uncompress and Deserialize failed on backup config blob"*); the other direction works.
- `SecurityPolicy` and `MacManagementPolicy` overlap. `MacManagementPolicy` has one inherited flag for the whole object, so sending it makes every security setting explicit; the rebuild leaves it out unless MAC learning is set explicitly.
- In the API, a port group's uplink order is only active and standby; unused uplinks are everything else, so they need no mapping.

Lab findings (vCenter 8.0 U3k build 25600417 to Holodeck vCenter 9.1.1 build 25784172, v1.4.0, 2026-11-16):

- Export from 8 and import onto `VPGM-T-Dst` on 9.1.1 with `-UplinkMap @{ 'Uplink 1' = 'uplink1'; 'Uplink 2' = 'uplink2' }` and `-NamePrefix 'V8-'`: 4 of 4, and every setting `-Mode Show` lists (plus NetFlow, reset at disconnect and the description) equal to the source.
- A zip from vCenter 8 restores on 9.1.1: the port group with an inherited uplink order came back from vCenter's own backup; the other three were rebuilt from the settings file with the mapped names.
- `-UplinkMap` takes a hashtable, which `pwsh -File` can't pass; call the script with `pwsh -Command "& .\Invoke-VDSPortGroupManager.ps1 ... -UplinkMap @{ ... }"` or from a PowerShell prompt. In a scheduled task, end the command with `; exit $LASTEXITCODE`, or `-Command` reports 1 instead of the script's own exit code (0 = done, 1 = one or more port groups failed, 2 = stopped for lack of console input). Failed port groups are logged in red and listed with their reason in the mode's summary.
- Delete always asks for a typed `YES`, so it never runs unattended; Export and Import can (#11).
- vSphere 7 sources are not tested and out of scope.

## History

This script started life as `Manage-VDSPortGroups.ps1` in a general scripts repo and graduated to its own repository in July 2026 — see the `.CHANGELOG` block in the script for the full list of improvements made along the way.
