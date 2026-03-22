# VCF Workload Domain Creator

An interactive PowerShell wizard that builds, validates, and exports a **VMware Cloud Foundation 9** workload domain JSON payload via the SDDC Manager API.

---

## Features

- 8-step guided wizard — no manual JSON editing required
- Full input validation: FQDNs, IP addresses, VLAN IDs, CIDRs, passwords, license key format
- Validates the payload against SDDC Manager (`POST /v1/domains/validations`) before saving
- Supports **ESA** and **OSA** vSAN storage (detects automatically from selected hosts)
- Supports deploying a **new NSX Manager** (1 or 3 nodes) or **joining an existing** one
- Optional static TEP IP pool configuration or DHCP fallback
- **Mock mode** for offline testing without a live SDDC Manager
- Saves the output JSON to disk (auto-named or user-specified path)

---

## Requirements

- PowerShell 5.1 or PowerShell 7+
- Network access to SDDC Manager
- SDDC Manager user with workload domain creation rights

---

## Usage

```powershell
# Interactive — prompts for everything
.\New-VCFWorkloadDomain.ps1

# Offline testing with built-in stub data
.\New-VCFWorkloadDomain.ps1 -MockMode
```

### Pre-filling variables

Open the script and populate the variables at the top to skip repetitive prompts:

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

---

## Wizard steps

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

---

## Output

The script saves a JSON file that can be submitted directly to SDDC Manager to create the workload domain:

```
POST https://<sddc-manager>/v1/domains
Content-Type: application/json
Authorization: Bearer <token>

<contents of the output JSON file>
```

---

## Author

Paul van Dieen — [hollebollevsan.nl](https://hollebollevsan.nl)
