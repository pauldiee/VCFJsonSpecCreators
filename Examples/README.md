# Example JSON Payloads

Reference payloads for each script in this repository. These show the exact structure that the scripts produce and submit to SDDC Manager.

> **Note:** All UUIDs and placeholder values (wrapped in `<angle brackets>`) must be replaced with real values from your environment before use.

---

## Files

| File | Script | API Endpoint |
|---|---|---|
| `network-pool.json` | `New-VCFNetworkPool.ps1` | `POST /v1/network-pools` |
| `workload-domain-new-nsx.json` | `New-VCFWorkloadDomain.ps1` | `POST /v1/domains` |
| `workload-domain-existing-nsx.json` | `New-VCFWorkloadDomain.ps1` | `POST /v1/domains` |
| `cluster-spec.json` | `New-VCFClusterSpec.ps1` | `POST /v1/clusters` |
| `vsan-stretch.json` | `New-VCFvSANStretchSpec.ps1` | `POST /v1/clusters/{id}/stretch` |

---

## network-pool.json

Network pool for vSAN and vMotion traffic, used as a prerequisite when commissioning hosts for a workload domain.

**Key values to replace:**
- VLAN IDs, subnets, and IP ranges to match your environment

Pool names follow the format `NP-<cluster-name>` — e.g. `NP-cluster-mgmt-01a`.

---

## workload-domain-new-nsx.json

Creates a new workload domain and deploys a **new 3-node NSX Manager cluster** as part of the same operation.

**Key values to replace:**
- `vcenterSpec` — vCenter FQDN, IP, gateway, subnet mask, passwords, and appliance size (`tiny` / `small` / `medium` / `large` / `xlarge`)
- `hostSpecs[].id` — host UUIDs from `GET /v1/hosts?status=UNASSIGNED_USEABLE`
- `vlanId` values — vMotion, vSAN, and NSX TEP VLANs
- `ipAddressPoolsSpec` — static TEP pool CIDR and range; remove this block entirely if using DHCP for TEPs
- `nsxSpec.nsxManagerSpecs` — NSX Manager node FQDNs
- `nsxSpec.vip` / `nsxSpec.vipFqdn` — NSX Manager virtual IP FQDN
- `nsxSpec` passwords — NSX admin, audit, and root passwords
- `networkPoolName` — must match an existing pool in SDDC Manager

---

## workload-domain-existing-nsx.json

Creates a new workload domain and **joins an existing NSX Manager** instance.

The only difference from the new-NSX variant is the `nsxSpec` block, which reduces to:

```json
"nsxSpec": {
  "nsxManagerRef": {
    "id": "<nsx-manager-uuid>"
  }
}
```

**Key values to replace:**
- Same as the new-NSX variant above
- `nsxSpec.nsxManagerRef.id` — UUID of the existing NSX Manager; retrieve it from `GET /v1/nsxt-managers`

---

## cluster-spec.json

Adds a new cluster to an existing workload domain.

**Key values to replace:**
- `domainId` — UUID of the target workload domain; retrieve it from `GET /v1/domains`
- `hostSpecs[].id` — host UUIDs from `GET /v1/hosts?status=UNASSIGNED_USEABLE`
- `vlanId` values — vMotion, vSAN, and NSX TEP VLANs
- `ipAddressPoolsSpec` — static TEP pool CIDR and range; remove this block entirely if using DHCP for TEPs
- `vsanSpec.esaConfig` — remove this block for OSA (original storage architecture)
- `networkPoolName` — must match an existing pool in SDDC Manager

---

## vsan-stretch.json

Stretches an existing cluster across two sites by adding secondary-site hosts and a witness appliance.

**Key values to replace:**
- `clusterId` — UUID of the cluster to stretch; retrieve it from `GET /v1/clusters`
- `stretchSpec.witnessSpec` — witness appliance FQDN, vSAN IP, netmask, and gateway
- `stretchSpec.primaryFaultDomainName` / `secondaryFaultDomainName` — names for the two fault domains
- `secondarySiteHostSpecs[].id` — host UUIDs of the secondary-site hosts
- `vmNics[].vdsName` — must match the VDS name already in use on the existing cluster

---

## Common notes

- `deployWithoutLicenseKeys: true` is required for VCF 9 consumption-based licensing; remove it for VCF 5.x if needed
- `esaConfig.enabled: true` enables vSAN ESA; remove the `esaConfig` block entirely for OSA
- `failuresToTolerate` accepts `1` (FTT-1, minimum 3 hosts) or `2` (FTT-2, minimum 5 hosts)
- `ipAddressPoolsSpec` under `nsxClusterSpec` is optional — omit it to use DHCP for NSX transport node TEP addresses
- VDS and port group names are free-form; the scripts auto-generate them from the domain/cluster name but they can be overridden
