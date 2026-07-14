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
| `vsan-stretch.json` | `New-VCFvSANStretchSpec.ps1` | `PATCH /v1/clusters/{id}` |

---

## network-pool.json

Network pool for vSAN and vMotion traffic, used as a prerequisite when commissioning hosts for a workload domain.

**Key values to replace:**
- VLAN IDs, subnets, and IP ranges to match your environment

Pool names follow the format `NP-<cluster-name>` — e.g. `NP-cluster-mgmt-01a`.

---

## workload-domain-new-nsx.json

Creates a new workload domain and deploys a **new 3-node NSX Manager cluster** as part of the same operation.

Verified field-by-field against a `POST /v1/domains` sample body taken from a live **VCF 9.1** SDDC Manager. Every key in this file exists in the 9.1 `DomainCreationSpec`.

**Key values to replace:**
- `vcenterSpec` — vCenter FQDN, IP, gateway, subnet mask, root password, and appliance size (`tiny` / `small` / `medium` / `large` / `xlarge`)
- `ssoDomainSpec.ssoDomainPassword` — the `administrator@vsphere.local` password (this is *not* `vcenterSpec.rootPassword`)
- `dnsServers` / `ntpServers` — required at the top level in VCF 9.x
- `clusterImageId` — a `personalityId` from `GET /v1/personalities`. **Mandatory for vCenter 9.0+**; the domain will not create without it
- `hostSpecs[].id` / `hostName` — host UUIDs and FQDNs from `GET /v1/hosts?status=UNASSIGNED_USEABLE`
- `nsxTSpec.vip` — the NSX Manager VIP **IP address**; `nsxTSpec.vipFqdn` is its **FQDN**. These are two different values
- `nsxTSpec.nsxManagerSpecs[].networkDetailsSpec` — each NSX node needs `dnsName`, `ipAddress`, `gateway`, and `subnetMask`
- `nsxTClusterSpec.uplinkProfiles[].transportVlan` — the NSX host TEP (overlay) VLAN
- `ipAddressPoolsSpec` — static TEP pool CIDR and range. Omit it (and `nsxtHostSwitchConfigs[].ipAddressPoolName`) to use DHCP on the TEP VLAN

**Things that are NOT in the VCF 9.1 spec**, despite appearing in VCF 5.x payloads and in earlier versions of this repo:
- `portGroupSpecs[].vlanId` — port groups carry no VLAN ID. The vMotion and vSAN VLANs come from the **network pool** the hosts were bound to at commission time
- a port group with `transportType: "NSX"` — `NSX` is not a legal enum value. The valid set is `VSAN, VMOTION, MANAGEMENT, PUBLIC, NFS, VREALIZE, ISCSI, EDGE_INFRA_OVERLAY_UPLINK, VM_MANAGEMENT, VSAN_EXTERNAL, FLEET_MANAGEMENT`
- a top-level `networkPoolName` — not part of `DomainCreationSpec`
- `nsxSpec` (it is `nsxTSpec`), and `nsxManagerSpecs[].networkDetails.fqdn` (it is `networkDetailsSpec`)
- `nsxClusterSpec.geneveVlanId` — still present but **deprecated**: *"This field is deprecated, instead please use transportVlan in uplinkProfiles"*

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

Stretches an existing vSAN cluster across two availability zones by adding second-AZ hosts, an NSX network profile (host TEP pool + uplink profile) for that zone, and a witness appliance.

This is the body for the stretch operation itself: `PATCH /v1/clusters/{id}`. To validate first, wrap the same content in one more level and POST it to `/v1/clusters/{id}/validations`:

```json
{
  "clusterUpdateSpec": {
    "clusterStretchSpec": { ... }
  }
}
```

**Key values to replace:**
- `hostSpecs[].id` / `hostname` — UUIDs and FQDNs of the AZ2 hosts; retrieve from `GET /v1/hosts?status=UNASSIGNED_USEABLE`
- `vmNics[].vdsName` — must match the VDS name already in use on the existing cluster
- `networkSpec.nsxClusterSpec.ipAddressPoolsSpec` — AZ2 host TEP pool CIDR, gateway, and range
- `networkSpec.nsxClusterSpec.uplinkProfiles[].transportVlan` — AZ2 host TEP VLAN
- `witnessSpec` — witness appliance FQDN, vSAN IP, and vSAN network CIDR (deploy the witness at a third site first)
- `networkProfiles[].isDefault` — `false` for workload domain clusters (the AZ1 default profile already exists; the AZ2 profile is a sub-config); `true` when stretching the management domain default cluster, where the stretch spec defines the cluster's first VCF network profile
- `isEdgeClusterConfiguredForMultiAZ` — set to `true` if an NSX Edge cluster runs on this vSphere cluster and is prepared for multi-AZ
- `witnessTrafficSharedWithVsanTraffic` — set to `true` only if witness traffic shares the vSAN network

**Prerequisites:** deploy and configure a vSAN witness host at a third location, create a network pool for AZ2, and commission the AZ2 hosts against it. The number of hosts in AZ2 should match AZ1.

---

## Common notes

- `deployWithoutLicenseKeys: true` is required for VCF 9 consumption-based licensing; remove it for VCF 5.x if needed
- `esaConfig.enabled: true` enables vSAN ESA; remove the `esaConfig` block entirely for OSA
- `failuresToTolerate` accepts `1` (FTT-1, minimum 3 hosts) or `2` (FTT-2, minimum 5 hosts)
- `ipAddressPoolsSpec` under `nsxClusterSpec` is optional — omit it to use DHCP for NSX transport node TEP addresses
- VDS and port group names are free-form; the scripts auto-generate them from the domain/cluster name but they can be overridden
