# VCF JSON Spec Creators

> **Disclaimer:** These scripts are provided as-is and have not been formally tested against a live VCF environment. Use at your own risk. Always validate the generated JSON payload via the SDDC Manager API's validation endpoints before submitting to production.

Interactive PowerShell scripts that build, validate, and export **VMware Cloud Foundation** JSON payloads via the SDDC Manager API — no manual JSON editing required.

| Script | Version | Purpose |
|---|---|---|
| `New-VCFWorkloadDomain.ps1` | 1.6.0 | Create a new workload domain |
| `New-VCFClusterSpec.ps1` | 1.1.0 | Add a cluster to an existing workload domain |
| `New-VCFvSANStretchSpec.ps1` | 1.1.0 | Stretch an existing cluster across two sites |
| `New-VCFNetworkPool.ps1` | 2.7.0 | Create a network pool in SDDC Manager |

---

## New-VCFWorkloadDomain.ps1

### What it does

1. **SDDC Manager connection** — authenticates and retrieves a Bearer token
2. **Host selection** — queries unassigned commissioned hosts; accepts comma-separated or range input (e.g. `1-3`)
3. **Storage type detection** — reads `storageType` from each selected host; aborts on mixed ESA/OSA
4. **Domain and vCenter configuration** — domain name, vCenter FQDN/name/datacenter/cluster, IP, gateway, subnet mask, appliance size, root and admin passwords
5. **VDS and network configuration** — VDS name and MTU, uplink names, vMotion/vSAN/NSX TEP VLAN IDs, optional static TEP IP pool or DHCP
6. **NSX configuration** — deploy a new NSX Manager (1 or 3 nodes) or join an existing instance
7. **Network pool selection** — picks from pools registered in SDDC Manager
8. **Build, validate, and save** — assembles the JSON payload, validates via `POST /v1/domains/validations`, saves to disk

### Usage

```powershell
# Interactive -- prompts for everything
.\New-VCFWorkloadDomain.ps1

# Offline testing with built-in stub data
.\New-VCFWorkloadDomain.ps1 -MockMode
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MockMode` | `switch` | — | Skip all SDDC Manager calls; use built-in stub data |

### Pre-filled variables

Open the script and populate the variables block at the top to skip repetitive prompts:

```powershell
$SDDCManagerFQDN   = 'sddc-manager.vcf.lab'
$DomainName        = 'wld-01'
$vCenterFQDN       = 'vcenter-wld01.vcf.lab'
$vCenterIP         = '192.168.10.10'
$vCenterGateway    = '192.168.10.1'
$vCenterSubnetMask = '255.255.255.0'
$VMotionVlanId     = '100'
$VSanVlanId        = '101'
$NSXTepVlanId      = '102'
# ...etc
```

### Output

```
POST https://<sddc-manager>/v1/domains
```

JSON saved as `<domainName>-workload-domain-<timestamp>.json`.

---

## New-VCFClusterSpec.ps1

### What it does

1. **SDDC Manager connection** — authenticates and retrieves a Bearer token
2. **Target workload domain** — lists existing domains; select the one to add a cluster to
3. **Host selection** — queries unassigned commissioned hosts; accepts comma-separated or range input
4. **Storage type detection** — reads `storageType` from each selected host; aborts on mixed ESA/OSA
5. **Cluster and vSAN configuration** — cluster name, vSAN datastore name, failures to tolerate (FTT 1 or 2)
6. **VDS and network configuration** — VDS name and MTU, uplink names, vMotion/vSAN/NSX TEP VLAN IDs, optional static TEP IP pool or DHCP, network pool selection
7. **Build, validate, and save** — assembles the JSON payload, validates via `POST /v1/clusters/validations`, saves to disk

### Usage

```powershell
# Interactive -- prompts for everything
.\New-VCFClusterSpec.ps1

# Offline testing with built-in stub data
.\New-VCFClusterSpec.ps1 -MockMode
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MockMode` | `switch` | — | Skip all SDDC Manager calls; use built-in stub data |

### Output

```
POST https://<sddc-manager>/v1/clusters
```

JSON saved as `<clusterName>-cluster-<timestamp>.json`.

---

## New-VCFvSANStretchSpec.ps1

### What it does

1. **SDDC Manager connection** — authenticates and retrieves a Bearer token
2. **Target cluster** — lists existing clusters; select the one to stretch
3. **Witness host configuration** — FQDN, vSAN IP address, subnet mask, and gateway for the witness appliance
4. **Secondary site host selection** — queries unassigned commissioned hosts for the secondary fault domain
5. **Network and fault domain configuration** — VDS name, uplink names, primary and secondary fault domain names
6. **Build, validate, and save** — assembles the JSON payload, optionally validates via `POST /v1/clusters/{id}/validations/stretch`, saves to disk

### Usage

```powershell
# Interactive -- prompts for everything
.\New-VCFvSANStretchSpec.ps1

# Offline testing with built-in stub data
.\New-VCFvSANStretchSpec.ps1 -MockMode
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MockMode` | `switch` | — | Skip all SDDC Manager calls; use built-in stub data |

### Output

```
POST https://<sddc-manager>/v1/clusters/{clusterId}/stretch
```

JSON saved as `<clusterName>-vsan-stretch-<timestamp>.json`.

---

## New-VCFNetworkPool.ps1

### What it does

1. **Input collection** — cluster name, SDDC Manager FQDN, credentials, MTU, VLAN IDs, and subnets
2. **Input validation** — validates every field before proceeding, re-prompts on errors
3. **Duplicate check** — verifies no pool with the same name already exists in SDDC Manager
4. **JSON build and preview** — assembles the payload for vSAN and vMotion networks, saves to `NetworkPools\`, and shows a preview before submitting
5. **Submit** — POSTs to `/v1/network-pools` and reports the resulting pool ID

Pool names follow the format `NP-<cluster-name>` — for example, `cluster-mgmt-01a` becomes `NP-cluster-mgmt-01a`.

### Usage

```powershell
# Interactive -- prompts for everything
.\New-VCFNetworkPool.ps1

# Offline testing with built-in stub data
.\New-VCFNetworkPool.ps1 -MockMode

# Lab -- skip certificate validation
.\New-VCFNetworkPool.ps1 -SkipCertCheck

# Save credentials for reuse
.\New-VCFNetworkPool.ps1 -SkipCertCheck -SaveCredentials

# Subsequent runs with saved credentials
.\New-VCFNetworkPool.ps1 -SkipCertCheck -CredentialFile '.\SavedCredentials\vcf-creds.xml'
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-MockMode` | Switch | Skip all SDDC Manager calls; use built-in stub data. |
| `-SkipCertCheck` | Switch | Disables SSL/TLS certificate validation. For lab use only. |
| `-SaveCredentials` | Switch | Encrypts and saves credentials to disk after the `Get-Credential` prompt. |
| `-CredentialFile` | String | Path to a saved credential file. Skips the interactive credential prompt. |

`-SaveCredentials` and `-CredentialFile` are mutually exclusive.

### Output

```
POST https://<sddc-manager>/v1/network-pools
```

JSON saved as `.\NetworkPools\NP-<cluster-name>.json`.

### Compatibility

- VCF 5.0, 5.1, 5.2, and VCF 9.0
- Windows PowerShell 5.1 and PowerShell 7.x

> **VCF 9 note:** The SDDC Manager UI no longer exposes network pool management (moved to vCenter → Global Inventory List → Hosts → Network Pools), but the `/v1/network-pools` API endpoint remains fully supported.

---

## Common

All scripts share the same patterns:

- **Pre-fillable variables** — populate the block at the top of each script to skip prompts
- **Mock mode** — run with `-MockMode` or set `$MockModeVar = $true` for fully offline testing
- **Input validation** — FQDNs, IP addresses, VLAN IDs, CIDRs, and passwords validated before the JSON is built
- **UTF-8 BOM output** — JSON files saved with UTF-8 BOM for compatibility with all tools
- **deployWithoutLicenseKeys** — workload domain, cluster, and vSAN stretch payloads include `deployWithoutLicenseKeys: true` (VCF 9 consumption-based licensing)

### Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1 or 7+ | Included with Windows 10 / Server 2016 and later |
| SDDC Manager access | Not required in mock mode |

---

## Examples

The [`Examples/`](Examples/) folder contains reference JSON payloads for each script — useful for understanding the expected structure before running a script, or for constructing payloads manually.

| File | Description |
|---|---|
| [`network-pool.json`](Examples/network-pool.json) | Network pool with vSAN and vMotion networks |
| [`workload-domain-new-nsx.json`](Examples/workload-domain-new-nsx.json) | Workload domain with a new 3-node NSX Manager |
| [`workload-domain-existing-nsx.json`](Examples/workload-domain-existing-nsx.json) | Workload domain joining an existing NSX Manager |
| [`cluster-spec.json`](Examples/cluster-spec.json) | New cluster added to an existing workload domain |
| [`vsan-stretch.json`](Examples/vsan-stretch.json) | vSAN cluster stretched across two sites |

See [`Examples/README.md`](Examples/README.md) for field-by-field notes on each file.

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
