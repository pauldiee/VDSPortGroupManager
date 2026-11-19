# VDSPortGroupManager test plan

How to test `Invoke-VDSPortGroupManager.ps1` in a lab: which lab, which
test set, which cases, and what came out. Labs are named by code only;
addresses live outside this repository.

## Labs

| Code | What | Role in the tests |
|---|---|---|
| **L8** | vCenter 8.0 U3, no hosts | Export source for vSphere 8 |
| **LA** | VCF 9.1.1 management vCenter | Main target; scale tests |
| **LB** | VCF 9.0.2 management vCenter | Functional set (2026-11-19); version-compatibility cases |

## Test sets

| Script | What it builds | Cleanup |
|---|---|---|
| `New-VPGMUplinkTestSet.ps1` | Functional set: host-less `VPGM-T-Src` (uplinks `Uplink 1/2`, private VLAN map 600/601/602) and `VPGM-T-Dst` (`uplink1/2`, private VLAN map 600/601 only); on the source VLAN, trunk, ephemeral, explicit failover, shaping/NetFlow/fixed allocation, PVLAN 601 and 602, MAC learning, and NIOC when vCenter accepts it | `-Mode Remove` |
| `New-VPGMScaleSet.ps1` | Scale set: 1500 port groups over three host-less switches (VLAN, trunk, PVLAN, teaming, security, shaping), optional empty `VPGM-S-Target` | `-Mode Remove` |

## Test cases

### A. Functional (New-VPGMUplinkTestSet.ps1)

Run: Create, Export all `VPGM-T-*` from `VPGM-T-Src`, Import into
`VPGM-T-Dst` with `-NamePrefix I-` and `-UplinkMap @{'Uplink 1'='uplink1';'Uplink 2'='uplink2'}`, Show, Remove.

| # | Case | Expected | Result (LB, 2026-11-19, 1.7.2) |
|---|---|---|---|
| F1 | `VPGM-T-Vlan101`, `-Eph`, `-Adv` (own uplink order) | Rebuilt from the settings file with the uplink map; order, shaping, NetFlow, fixed allocation and description kept | **pass** |
| F2 | `VPGM-T-Trunk` (inherited order) | Restored from the zip | **pass** |
| F3 | `VPGM-T-Pvlan601` (#25) | Rebuilt from the settings file right away, PVLAN 601 kept | **pass** |
| F4 | `VPGM-T-Pvlan602`, target lacks 602 (#25) | Skipped with *"private VLAN 602 is not in the private VLAN map"* | **pass** |
| F5 | `VPGM-T-MacLearn` | MAC learning on (4096, DROP), forged transmits and MAC changes allowed on the target | **pass** (restored from the zip) |
| F6 | `VPGM-T-Nioc` (#20) | Created only when vCenter accepts NIOC on a host-less switch | Not created on 9.0.2: *"A specified parameter was not correct: configSpec.VmVnicNetworkResourcePool.al…"*; the script says so and goes on |
| F7 | Export of a 9.1.1 backup, import on 9.0.2 | *"Uncompress and Deserialize failed on backup config blob"*, rebuilt from the settings file | 2026-11-13: seen (lab finding, see README) |

### B. Private VLAN restore (#25)

| # | Steps | Result (LA, 2026-11-19, PowerCLI 13.5.1) |
|---|---|---|
| P1 | `New-VDPortgroup -BackupPath` with the zip of a PVLAN port group, onto another switch with the same PVLAN map | Fails: `System.ArgumentNullException: Value cannot be null. (Parameter 'array')` in `VDSwitchBackupManager.GetVlanDescription` / `ReadBackup` (while reading the zip) |
| P2 | Same zip onto the same switch it came from | Fails the same way |
| P3 | Zips of a VLAN and a trunk port group | Restore fine |
| P4 | Tool 1.7.2 import of the three into a switch with the PVLAN map, export again, compare `Summary` and `DefaultPortConfig` | Identical for all three |

### C. Scale (New-VPGMScaleSet.ps1)

| # | Steps | Result (LA, 2026-11-19, 1.7.0/1.7.1) |
|---|---|---|
| S1 | Create 1500 port groups on three switches | 54 s |
| S2 | Export 500 port groups of one switch | 2:55 (about 0.35 s each) |
| S3 | Import 500 into the target switch | About 3 s per port group (`New-VDPortgroup -BackupPath`); 1.7.0 spent 96 s silent on the name check first, 1.7.1 does it in 1 s; 1.7.1 adds a text progress line every 5% |

## Open points

- NIOC (`VmVnicNetworkResourcePoolKey`, #20) can't be built on a host-less
  switch; test it on a switch with hosts.
- Whether a newer PowerCLI reads PVLAN backups (#25): re-run P1 after a
  PowerCLI update; the tool's rebuild works either way.
