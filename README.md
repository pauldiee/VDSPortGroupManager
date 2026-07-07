# VDSPortGroupManager

A PowerShell utility to export, import, or delete vSphere Distributed Switch (VDS) port groups interactively — useful for backing up port groups before changes, migrating them between switches or vCenters, and cleaning up with proper safeguards.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VDSPortGroupManager.ps1` | 1.1.2 | Export / import / delete VDS port groups — **vSphere 9 only** |

---

## What it does

- **Export** — connects to a vCenter, lets you pick a VDS and one or more port groups (shown with their VLAN configuration and port count), and exports each to a portable zip file using the native `Export-VDPortGroup` backup format. NSX-backed port groups (segments created by NSX or vSphere with Tanzu) cannot be exported by vCenter — they are tagged `[NSX-backed]` in the picker and skipped with a clear message.
- **Import** — lists the zip files in the backup directory, lets you select which to restore and onto which VDS. The target picker also offers creating a **new VDS** on the spot (pick a datacenter, name it, and clone version, uplink count **and uplink names**, and MTU from an existing switch — or enter them manually; exported teaming policies reference uplinks by name, so cloning is the reliable path) — note the new switch has no hosts attached yet. Port groups can be renamed on import with `-NamePrefix` / `-NameSuffix` — vCenter requires distributed port group names to be unique per **datacenter** (across all switches), so restoring into the same datacenter needs a rename. The script checks for clashes datacenter-wide, offers to enter a prefix/suffix interactively when it finds any, and skips (rather than fails) anything still clashing.
- **Delete** — interactive selection with two safeguards: port groups still in use by VMs are flagged (deletion of those will fail server-side), and the script offers a safety export before asking for a typed `YES` confirmation.

All selections support single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel`. Every action is logged to the console and a timestamped log file.

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
