# VCF JSON Spec Creators

A collection of interactive PowerShell wizards that build, validate, and export **VMware Cloud Foundation 9** JSON payloads via the SDDC Manager API — no manual JSON editing required.

| Script | Purpose |
|--------|---------|
| `New-VCFWorkloadDomain.ps1` | Create a new workload domain |
| `New-VCFClusterSpec.ps1` | Add a cluster to an existing workload domain |
| `New-VCFvSANStretchSpec.ps1` | Stretch an existing cluster across two sites |

---

## New-VCFWorkloadDomain.ps1

Builds the full workload domain payload including vCenter, NSX, vSAN, VDS, and network pool configuration.

### Features

- 8-step guided wizard
- Full input validation: FQDNs, IP addresses, VLAN IDs, CIDRs, passwords, license key format
- Validates the payload against SDDC Manager (`POST /v1/domains/validations`) before saving
- Supports **ESA** and **OSA** vSAN storage (auto-detected from selected hosts)
- Supports deploying a **new NSX Manager** (1 or 3 nodes) or **joining an existing** one
- Optional static TEP IP pool or DHCP fallback
- **Mock mode** for offline testing without a live SDDC Manager
- Saves output JSON to disk (auto-named or user-specified path)

### Usage

```powershell
# Interactive — prompts for everything
.\New-VCFWorkloadDomain.ps1

# Offline testing with built-in stub data
.\New-VCFWorkloadDomain.ps1 -MockMode
```

### Wizard steps

| Step | Description |
|------|-------------|
| 1 | SDDC Manager connection and authentication |
| 2 | Select unassigned commissioned hosts |
| 3 | Auto-detect storage type (ESA / OSA) |
| 4 | Domain name, vCenter name, datacenter, cluster, passwords |
| 5 | VDS name, MTU, uplinks, VLAN IDs, TEP IP pool, ESXi license key |
| 6 | NSX configuration (new or existing) |
| 7 | Network pool selection |
| 8 | Build JSON, validate against SDDC Manager, save to disk |

### Output

```
POST https://<sddc-manager>/v1/domains
```

---

## New-VCFClusterSpec.ps1

Builds the add-cluster payload for deploying an additional cluster into an existing workload domain.

### Features

- 7-step guided wizard
- Picks target domain from a live list of existing workload domains
- Supports **ESA** and **OSA** vSAN storage (auto-detected, aborts on mixed types)
- Configurable vSAN failures to tolerate (FTT 1 or 2)
- VDS name, MTU, uplinks, VLAN IDs, optional static TEP IP pool or DHCP fallback
- ESXi license key per cluster
- Validates the payload against SDDC Manager (`POST /v1/clusters/validations`) before saving
- **Mock mode** for offline testing

### Usage

```powershell
# Interactive — prompts for everything
.\New-VCFClusterSpec.ps1

# Offline testing with built-in stub data
.\New-VCFClusterSpec.ps1 -MockMode
```

### Wizard steps

| Step | Description |
|------|-------------|
| 1 | SDDC Manager connection and authentication |
| 2 | Select target workload domain |
| 3 | Select unassigned commissioned hosts |
| 4 | Auto-detect storage type (ESA / OSA) |
| 5 | Cluster name, vSAN datastore name, failures to tolerate |
| 6 | VDS name, MTU, uplinks, VLAN IDs, TEP IP pool, ESXi license key, network pool |
| 7 | Build JSON, validate against SDDC Manager, save to disk |

### Output

```
POST https://<sddc-manager>/v1/clusters
```

---

## New-VCFvSANStretchSpec.ps1

Builds the stretch spec payload for converting an existing cluster into a vSAN stretched cluster across two fault domains with a witness host.

### Features

- 6-step guided wizard
- Picks target cluster from a live list of existing clusters
- Collects witness host FQDN, vSAN IP, netmask, and gateway
- Selects secondary site hosts from unassigned commissioned hosts
- Configurable fault domain names for primary and secondary sites
- Optional static TEP IP pool or DHCP (inherited from cluster VDS)
- Optionally validates via SDDC Manager (`POST /v1/clusters/{id}/validations/stretch`) before saving
- **Mock mode** for offline testing

### Usage

```powershell
# Interactive — prompts for everything
.\New-VCFvSANStretchSpec.ps1

# Offline testing with built-in stub data
.\New-VCFvSANStretchSpec.ps1 -MockMode
```

### Wizard steps

| Step | Description |
|------|-------------|
| 1 | SDDC Manager connection and authentication |
| 2 | Select target cluster to stretch |
| 3 | Witness host FQDN, vSAN IP, netmask, and gateway |
| 4 | Select secondary site hosts from unassigned commissioned hosts |
| 5 | VDS name, uplinks, fault domain names, ESXi license key |
| 6 | Build JSON, optionally validate against SDDC Manager, save to disk |

### Output

```
POST https://<sddc-manager>/v1/clusters/{clusterId}/stretch
```

---

## Common features

All three scripts share the same patterns:

- **Pre-fillable variables** — populate the variables block at the top of each script to skip repetitive prompts
- **Mock mode** — run with `-MockMode` or set `$MockModeVar = $true` to use built-in stub data without any SDDC Manager connectivity
- **Input validation** — FQDNs, IP addresses, VLAN IDs, CIDRs, passwords, and license keys are validated before the JSON is built
- **UTF-8 BOM output** — JSON files are saved with UTF-8 BOM encoding for compatibility with all tools
- **Auto-named output** — files are named `<identifier>-<type>-<timestamp>.json` when no path is specified

### Requirements

- PowerShell 5.1 or PowerShell 7+
- Network access to SDDC Manager (not required in mock mode)
- SDDC Manager user with appropriate rights

### Pre-filling variables example

```powershell
$SDDCManagerFQDN   = 'sddc-manager.vcf.lab'
$VMotionVlanId     = '100'
$VSanVlanId        = '101'
$NSXTepVlanId      = '102'
# ...etc
```

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://hollebollevsan.nl)
