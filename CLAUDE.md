# VCFJsonSpecCreators — Claude Code Context

> Auto-loaded by Claude Code. Conventions for any collaborator's Claude instance working in this repo.

---

## Project overview

Interactive PowerShell scripts that build, validate and POST **VMware Cloud Foundation** spec JSON via the SDDC Manager API — network pool, workload domain, cluster, vSAN stretch. No hand-editing of JSON.

This is the **last mile** of a three-repo flow:

| Step | Repo | What it does |
| --- | --- | --- |
| 1 | [VCF9-DeploymentPlanning](https://github.com/pauldiee/VCF9-DeploymentPlanning) | Network/DNS plan, role-based intake, the Broadcom planning workbook |
| 2 | [VCFHostPreparation](https://github.com/pauldiee/VCFHostPreparation) | Images and commissions the ESXi hosts into SDDC Manager |
| 3 | **VCFJsonSpecCreators** *(this repo)* | Builds the spec JSON from those hosts and submits it |

The host UUIDs returned by SDDC Manager after commissioning are the input to the scripts here.

Default branch is **`master`**, not `main`. Single remote (`origin`) — no GitLab mirror.

Author: Paul van Dieen — https://www.hollebollevsan.nl

---

## Hard constraints

These two are non-obvious and a well-meaning cleanup will silently undo them. Both were real, shipped bugs.

### 1. Source must be ASCII-only

The `.ps1` files are **BOM-less UTF-8**. Windows PowerShell 5.1 decodes BOM-less files using the **ANSI codepage**, so a single em-dash or en-dash inside a string literal becomes mojibake and corrupts the tokenizer — you get cascading `Missing closing '}'` and `The string is missing the terminator` errors far from the real line.

Three of the four scripts could not be parsed by 5.1 at all until this was fixed (see #2). Use `-` and never `—`/`–` in `.ps1` files.

> Note this is the **opposite** of the `VCF9-DeploymentPlanning` convention, where em-dashes in `docs/` are fine. That rule does not apply here.

### 2. The scripts must run on Windows PowerShell 5.1

That is what a customer jump host has. Consequences:

- **`-SkipCertificateCheck` does not exist on 5.1.** Gate it: `if ($PSVersionTable.PSEdition -eq 'Core') { $params['SkipCertificateCheck'] = $true }`, and let the `TrustAll` `ICertificatePolicy` in the SSL region handle 5.1 (see #3).
- Verify with the **5.1 parser**, not just `pwsh`:

```powershell
powershell -NoProfile -Command "
  `$errs = `$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'Script.ps1'), [ref]`$null, [ref]`$errs)
  if (`$errs) { `$errs | Select -First 5 } else { 'PASS' }"
```

A script that parses under `pwsh` 7 tells you nothing about 5.1.

---

## The specs are three different models

Verified against a live VCF 9.1 SDDC Manager (#4, #5). **Do not assume one shape fits all.**

`DomainCreationSpec` (`POST /v1/domains`) and the cluster spec (`POST /v1/clusters`) share an **identical** `computeSpec.clusterSpecs[]`. Only the top level differs — the cluster spec takes `domainId`, `deployWithoutLicenseKeys`, `dnsServers`, `ntpServers`. Fix one, fix the other the same way.

**`clusterStretchSpec` (`ClusterUpdateSpec`, `PATCH /v1/clusters/{id}`) is a genuinely different model.** Two differences look like bugs and are not:

- its `networkSpec.nsxClusterSpec` takes `{ipAddressPoolsSpec, uplinkProfiles}` **directly** — there is **no `nsxTClusterSpec` wrapper**, unlike the domain and cluster specs
- it uses lowercase **`hostname`**, where the domain and cluster specs use **`hostName`**

**Do not "align" `New-VCFvSANStretchSpec.ps1` to the domain spec.** It is field-proven (a live management-domain stretch completed) and you would break it. See #6, which was opened on exactly this bad inference and closed as refuted.

### VCF 9.1 gotchas (all cost real time to find)

Does **not** exist in 9.1, despite appearing in VCF 5.x payloads:

- `nsxSpec` → it is **`nsxTSpec`**; `nsxManagerSpecs[].networkDetails.fqdn` → it is **`networkDetailsSpec`** with `dnsName`/`ipAddress`/`gateway`/`subnetMask`
- `portGroupSpecs[].vlanId` → port groups carry no VLAN. **The vMotion/vSAN VLANs come from the network pool**, which is therefore the single source of truth for that addressing
- `transportType: "NSX"` on a port group → not a legal enum value
- top-level `networkPoolName` → the pool binds at host commission
- `clusterSpecs[].vsanSpec` → it is `datastoreSpec.vsanDatastoreSpec`
- `vcenterSpec.adminPassword` → the SSO password is `ssoDomainSpec.ssoDomainPassword`

Required and easy to miss:

- **`clusterImageId`** — mandatory for vCenter 9.0+, from `GET /v1/personalities`. Its absence is not obvious from the error message.
- `nsxClusterSpec` must wrap its contents in **`nsxTClusterSpec`** (domain + cluster only — see above)
- `geneveVlanId` still exists but is **deprecated**; use `uplinkProfiles[].transportVlan`
- `vipFqdn` is required; **`vip` is `[Deprecated]`**, optional, and takes an **IP** — not the FQDN
- top-level `dnsServers`, `ntpServers`, `ssoDomainSpec`, `orgName`

### Stretching a mgmt domain vs a workload domain

Differs by exactly one flag, and nothing else in the payload signals which you are doing:

| Stretching | `networkProfiles[].isDefault` |
| --- | --- |
| Management domain default cluster | `true` — the stretch spec defines the cluster's first VCF network profile |
| Workload domain cluster | `false` — the AZ1 default already exists; AZ2 is a sub-config |

---

## Verifying a spec change

**Do not trust TechDocs alone.** They are internally inconsistent (the worked examples write `hostname` where the 9.1 schema page says `hostName`). The live appliance is the tiebreaker.

Two techniques, both cheap:

1. **Diff against a sample body.** The SDDC Manager API explorer hands you a complete sample request body for any endpoint. Walk every key path your payload emits and check it exists in that sample. Unknown fields show up before you make a single call.

2. **POST to `/validations` with placeholder host UUIDs.** No commissioned hosts needed. Read the *error class*, not pass/fail:

   | Response | Means |
   | --- | --- |
   | `REST_INVALID_API_INPUT` — *"Invalid input"* | Rejected at the **schema layer**. The shape is wrong. |
   | `ESXIS_NOT_FOUND` — *"ESXi Host(s) Not Found"* | **Schema passed.** It reached host resolution and only tripped on the fake UUIDs. This is the success signal. |

   On `/v1/clusters/validations` the second surfaces as a generic `PUBLIC_INTERNAL_SERVER_ERROR` — read the `causes[]` array for the real message.

   **Always run the old/suspect payload as a control in the same session.** Without it you cannot tell whether "host not found" means the schema passed or the endpoint says that for everything.

---

## Customer data hygiene

The generated spec JSON contains **cleartext passwords** — vCenter root, SSO, NSX admin/audit/root. The moment it is written it is customer data.

- Never commit a generated spec (`*-workload-domain-*.json`, `*-cluster-*.json`, `NetworkPools/*.json`)
- Never paste one into a ticket, chat or issue
- Examples in `Examples/` use `<placeholder>` secrets and Rainpole-style values (`vcf.lab`, `192.168.x.x`) only — keep it that way
- Delete the generated file once the domain is deployed

---

## Pre-commit checklist

1. **Version bumped in all three places**: the `.NOTES Version` field, the `$ScriptMeta.Version` block, and the README version table — together, in the same commit.
2. **`.NOTES` changelog** has a new entry, newest at the bottom of the list. Max 10 values on every version component (`.0`–`.9`): after patch `.9` roll the minor, after minor `.9` roll the major (never `0.10.0`).
3. **Parses under Windows PowerShell 5.1** (see above) — not just `pwsh`.
4. **No non-ASCII characters** in any `.ps1`.
5. **`Examples/` regenerated** if the payload shape changed, and `Examples/README.md` updated to match.
6. **No customer values or credentials** in the diff.

## GitHub issues

Every bug, fix or idea gets an issue, opened **before** the work. Check open **and** closed issues first (`gh issue list --state all`) — #6 exists as a closed cautionary tale. Ask who requested it and apply the matching `requested-by:` label. Close only when real use confirms it, not when the code merely looks done.
