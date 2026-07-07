# VDSPortGroupManager

A PowerShell utility to export, import, or delete vSphere Distributed Switch (VDS) port groups interactively — useful for backing up port groups before changes, migrating them between switches or vCenters, and cleaning up with proper safeguards.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VDSPortGroupManager.ps1` | 1.1.2 | Export / import / delete VDS port groups — **vSphere 9 only** |

---

## How it works

The script connects to a vCenter, then runs one of three modes. Pass `-Mode Export|Import|Delete`, or omit it to pick from a menu. Every picker supports single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel`. Every action is logged to the console and a timestamped log file.

### Export

1. Pick the source VDS.
2. Pick one or more port groups. Each entry shows its VLAN configuration and port count; uplink port groups are excluded.
3. Each selected port group is exported to a portable zip (`<portgroup>.zip`) in the backup directory using the native `Export-VDPortGroup` backup format.

> **NSX note:** port groups backed by NSX segments (created by NSX, vSphere with Tanzu / VKS, or VPCs — e.g. `pod-default-*`, `kubernetes-cluster-*`) **cannot be exported** — the vCenter backup API does not support them and their configuration lives in NSX Manager. The picker tags them `[NSX-backed]` and the export skips them with a clear message instead of failing. The summary reports `succeeded / skipped (NSX-backed) / failed`.

### Import

1. Pick one or more zips from the backup directory.
2. Pick the target VDS — or choose **`<Create a NEW VDS and import into it>`**, which prompts for:
   - the datacenter (auto-selected when the vCenter has only one),
   - a name (must not exist yet),
   - the settings: either **clone version, uplink count, uplink port names, and MTU from an existing VDS**, or enter them manually (blank = vCenter defaults).
3. The script checks the chosen names against **all** port groups in the datacenter — vCenter requires distributed port group names to be unique per datacenter, across all switches, so restoring into the same datacenter needs a rename. If clashes are found and no `-NamePrefix` / `-NameSuffix` was given, it prompts for a prefix/suffix interactively.
4. Each zip is imported with `New-VDPortgroup -BackupPath`. Anything still clashing is skipped (with the owning switch named in the message), not failed.

> **Cross-switch note:** exported teaming policies reference uplinks **by name** (VCF-built switches use `uplink1`/`uplink2`). Importing onto a switch with different uplink names fails with `activeUplinkPortName ... is not valid` — this is why the create-new-VDS clone option also copies the uplink port names, and why cloning is the reliable path for migrations. A freshly created VDS has **no hosts attached**; add hosts before workloads can use the imported port groups.

### Delete

1. Pick the VDS, then the port groups to delete.
2. Port groups still in use by VMs are flagged — deleting those will fail server-side until the VMs are moved.
3. The script offers a safety export to zip first, then requires a typed `YES` before deleting anything.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Included with Windows 10 / Server 2016 and later |
| VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` |
| Network access | HTTPS to vCenter Server |

## Usage

```powershell
# Fully interactive — pick the mode from a menu
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab

# Export selected port groups (default backup directory: .\Backups)
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export

# Export to a specific directory
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -BackupDirectory C:\Backups\VDS

# Import port groups from backups
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -BackupDirectory C:\Backups\VDS

# Import and rename with a prefix and suffix
.\Invoke-VDSPortGroupManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -NamePrefix "NEW-" -NameSuffix "-v2"

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
| `-BackupDirectory` | `Backups\` next to the script | Where zips are written (Export) or read (Import) |
| `-LogDirectory` | `Logs\` next to the script | Where the per-run log file is written |
| `-NamePrefix` / `-NameSuffix` | none | Rename port groups on import; prompted for interactively when name clashes are detected |
| `-CredentialPath` | `<vCenterServer>.cred` next to the script | Alternate saved-credential file |
| `-ResetCredentials` | off | Force a new credential prompt |
| `-SkipCertificateValidation` | off | Accept self-signed vCenter certificates (labs) |

## Credentials

On first run the script prompts for credentials and saves them encrypted to `<vCenterServer>.cred` next to the script (`Export-Clixml`, DPAPI-protected, tied to the current Windows user and machine). Subsequent runs reuse the file automatically. Use `-ResetCredentials` to force a new prompt, or `-CredentialPath` to point at a different file.

Credential files are excluded from git via `.gitignore`.

## Output

| Path | Content |
|---|---|
| `Backups\` (default) | Exported port group zip files, named `<portgroup>.zip` |
| `Logs\` | Timestamped log file per run |

Both directories are created automatically and excluded from git.

## History

This script started life as `Manage-VDSPortGroups.ps1` in a general scripts repo and graduated to its own repository in July 2026 — see the `.CHANGELOG` block in the script for the full list of improvements made along the way.
