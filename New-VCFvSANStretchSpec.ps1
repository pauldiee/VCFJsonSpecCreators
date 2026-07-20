<#
.SYNOPSIS
    Creates a VCF 9 vSAN Stretched Cluster spec JSON, optionally validates it against SDDC Manager, and saves it to file.

.DESCRIPTION
    - Queries SDDC Manager for existing clusters to select the one to stretch
    - Queries unassigned commissioned hosts for availability zone 2
    - Collects witness host, AZ2 NSX network (host TEP pool, uplink profile), and VDS configuration
    - Builds the clusterStretchSpec JSON payload per the VCF 9 API
    - Optionally validates via SDDC Manager API (POST /v1/clusters/{id}/validations)
    - Saves the JSON to disk (body for PATCH /v1/clusters/{id})
    - Optionally executes the stretch (PATCH /v1/clusters/{id}) from a chosen JSON file,
      after typed cluster-name confirmation
    - Supports mock mode for offline/lab testing without live SDDC Manager

.NOTES
    Script  : New-VCFvSANStretchSpec.ps1
    Version : 2.3.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-07-10

    1.0.0 - Initial release
    1.1.0 - Removed ESXi license key prompt; added deployWithoutLicenseKeys = true to payload (VCF 9 consumption-based licensing)
    2.0.0 - Reworked payload to the documented VCF 9 clusterStretchSpec format:
            hostSpecs with hostname + networkProfileName, networkSpec with AZ2 NSX
            network profile / host TEP pool / uplink profile, witnessSpec with vsanCidr,
            isEdgeClusterConfiguredForMultiAZ and witnessTrafficSharedWithVsanTraffic flags.
            Removed fault domain name prompts (not part of the API spec).
            Validation now uses POST /v1/clusters/{id}/validations; stretch via PATCH /v1/clusters/{id}.
    2.1.0 - Added optional execute step: prompts for a stretch spec JSON file (defaults to the
            one just saved) and submits PATCH /v1/clusters/{id} after typed cluster-name confirmation.
    2.2.0 - Windows PowerShell 5.1 compatibility: replaced non-ASCII dashes (the file is
            BOM-less UTF-8, which 5.1 decodes as ANSI, corrupting the tokenizer); gated
            -SkipCertificateCheck behind PSEdition -eq 'Core' so 5.1 falls back to the
            TrustAll ICertificatePolicy instead of failing on an unknown parameter
    2.2.1 - Fixed a crash in the AZ2 host list: SDDC Manager omits storageType (and can omit
            cpu/memory) on an unassigned host, and Set-StrictMode -Version Latest turns a
            missing property into a terminating error. Reads now go through Get-PropOrDefault
            and display 'n/a' when the field is absent.
    2.2.2 - Validation polling: a TASK_NOT_FOUND on the first poll is transient (SDDC Manager
            registers the validation task a moment after the POST returns) and no longer
            prints as a warning. Gives up after 6 consecutive failures with the manual GET
            URL instead of spinning the full 300s. Result fields (resultStatus,
            validationChecks) read via Get-PropOrDefault - same StrictMode hazard as the
            host list. Endpoints unchanged: POST and GET are both cluster-scoped.
    2.3.0 - The JSON is now written to disk BEFORE validation, not after. Validation is a long
            round trip that can fail, time out or be interrupted, and the payload is 30+
            prompts of work - a failed validation should cost a retry, not the whole run.
            The validation prompt is reworded to match ("Validate the JSON with this script?")
            since answering n now leaves you with a saved spec rather than nothing.
            Also fixed $ScriptMeta.Version, which was still reporting 2.2.0 in the banner.

.PARAMETER MockMode
    Run in mock mode: skips all SDDC Manager API calls and uses built-in stub data.
    Can also be enabled by setting $MockModeVar = $true in the variables block below.
#>

[CmdletBinding()]
param(
    [switch]$MockMode
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "New-VCFvSANStretchSpec.ps1"
    Version = "2.3.0"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-07-10"
}

#endregion

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Pre-filled variables (leave blank to be prompted) ---
$MockModeVar        = $false      # set to $true to enable mock mode without the -MockMode switch

$SDDCManagerFQDN    = ''          # e.g. sddc-manager.vcf.lab

# -- Witness host:
$WitnessFQDN        = ''          # e.g. witness.vcf.lab
$WitnessVsanIp      = ''          # e.g. 192.168.20.100 (IP on vSAN network)
$WitnessVsanCidr    = ''          # e.g. 192.168.20.0/24 (vSAN network CIDR)

# -- VDS (must match the existing cluster's VDS):
$VDSName            = ''          # e.g. wld-01-vds01    (leave blank to prompt)

# -- AZ2 NSX host TEP network:
$Az2TepCidr         = ''          # e.g. 192.168.32.0/24
$Az2TepGateway      = ''          # e.g. 192.168.32.1
$Az2TepRangeStart   = ''          # e.g. 192.168.32.50
$Az2TepRangeEnd     = ''          # e.g. 192.168.32.70
$Az2TransportVlan   = ''          # e.g. 202 (AZ2 host TEP VLAN)

$OutputJsonPath     = ''          # e.g. C:\VCF\wld-01-stretch.json (leave blank to auto-generate)
#endregion

# Resolve mock mode from either source
if ($MockModeVar) { $MockMode = [switch]$true }

#region --- Mock data ---
$MockClusters = @(
    [PSCustomObject]@{
        id     = 'cluster-mock-001'
        name   = 'wld-cl-01'
        status = 'ACTIVE'
    }
    [PSCustomObject]@{
        id     = 'cluster-mock-002'
        name   = 'mgmt-cl-01'
        status = 'ACTIVE'
    }
)

$MockHosts = @(
    [PSCustomObject]@{
        id          = 'host-mock-101'
        fqdn        = 'esxi-sec-01.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
    [PSCustomObject]@{
        id          = 'host-mock-102'
        fqdn        = 'esxi-sec-02.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
    [PSCustomObject]@{
        id          = 'host-mock-103'
        fqdn        = 'esxi-sec-03.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
)
#endregion

#region --- Helpers ---
function Test-FQDN {
    param([string]$Value)
    return [bool]($Value -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$')
}

function Test-SimpleName {
    param([string]$Value)
    return [bool]($Value -match '^[a-zA-Z0-9][a-zA-Z0-9\-_]{0,62}$')
}

function Test-IPAddress {
    param([string]$Value)
    $addr = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$addr) -and
           $addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-Password {
    param([string]$Value)
    return $Value.Length -ge 8
}

function Test-CIDR {
    param([string]$Value)
    if ($Value -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { return $false }
    return (Test-IPAddress $Matches[1]) -and ([int]$Matches[2] -ge 1) -and ([int]$Matches[2] -le 32)
}

function Get-PropOrDefault {
    # Set-StrictMode -Version Latest turns a missing property into a terminating error.
    # SDDC Manager omits optional fields entirely (e.g. storageType on an unassigned host),
    # so every read of an API-returned object must go through this.
    param(
        $Object,
        [string]$Name,
        $Default = 'n/a'
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Test-VlanId {
    param([string]$Value)
    return ($Value -match '^\d+$') -and ([int]$Value -ge 0) -and ([int]$Value -le 4094)
}

function Get-OrPrompt {
    param(
        [string]$Value,
        [string]$Prompt,
        [switch]$Secure,
        [switch]$Optional,
        [scriptblock]$Validator,
        [string]$InvalidMessage = 'Invalid value, please try again.'
    )
    if ($Value -and $Value.Trim() -ne '') {
        if (-not $Validator -or (& $Validator $Value.Trim())) { return $Value }
        Write-Host "  WARNING: Pre-filled value is invalid: $InvalidMessage" -ForegroundColor Yellow
    }
    while ($true) {
        if ($Secure) {
            $ss     = Read-Host -Prompt $Prompt -AsSecureString
            $result = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                          [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        } else {
            $result = Read-Host -Prompt $Prompt
        }
        if (-not $result -or $result.Trim() -eq '') {
            if ($Optional) { return '' }
            Write-Host "  WARNING: This field cannot be empty." -ForegroundColor Yellow
            continue
        }
        if ($Validator -and -not (& $Validator $result.Trim())) {
            Write-Host "  WARNING: $InvalidMessage" -ForegroundColor Yellow
            continue
        }
        return $result
    }
}

function Get-SDDCToken {
    param(
        [string]$FQDN,
        [System.Management.Automation.PSCredential]$Credential
    )
    $uri  = "https://$FQDN/v1/tokens"
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json
    $params = @{
        Uri         = $uri
        Method      = 'POST'
        ContentType = 'application/json'
        Body        = $body
    }
    # PS 7+ supports -SkipCertificateCheck natively. Windows PowerShell 5.1 does not
    # have the parameter at all; there the TrustAll ICertificatePolicy installed in
    # the SSL region below is what bypasses validation.
    if ($PSVersionTable.PSEdition -eq 'Core') { $params['SkipCertificateCheck'] = $true }
    $resp = Invoke-RestMethod @params
    return $resp.accessToken
}

function Invoke-SDDC {
    param(
        [string]$FQDN,
        [string]$Token,
        [string]$Method = 'GET',
        [string]$Path,
        [object]$Body = $null
    )
    $headers = @{ Authorization = "Bearer $Token" }
    $uri     = "https://$FQDN$Path"
    $params  = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $headers
        ContentType = 'application/json'
    }
    if ($PSVersionTable.PSEdition -eq 'Core') { $params['SkipCertificateCheck'] = $true }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 20) }
    return Invoke-RestMethod @params
}
#endregion

#region --- SSL / TLS ---
if (-not $MockMode) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $null = [System.Net.Http.HttpClientHandler]  # preload assembly
    } else {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}
#endregion

#region --- Banner ---
$bannerWidth = 62
Write-Host ""
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ("  {0,-30} {1}" -f $ScriptMeta.Name, ("v" + $ScriptMeta.Version)) -ForegroundColor Cyan
Write-Host ("  Author : {0}" -f $ScriptMeta.Author) -ForegroundColor Cyan
Write-Host ("  Blog   : {0}" -f $ScriptMeta.Blog) -ForegroundColor Cyan
Write-Host ("  Date   : {0}" -f $ScriptMeta.Date) -ForegroundColor DarkGray
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ""
#endregion

#region --- Mock mode banner ---
if ($MockMode) {
    Write-Host "  *** MOCK MODE ACTIVE - no SDDC Manager calls will be made ***" -ForegroundColor Yellow
    Write-Host "  Stub data is used for clusters, hosts, and validation" -ForegroundColor DarkGray
    Write-Host ""
}
#endregion

#region --- Step 1: SDDC Manager connection ---
Write-Host ("`n  [Step 1 of 6  --  SDDC Manager Connection]") -ForegroundColor Cyan

if ($MockMode) {
    $SDDCManagerFQDN = if ($SDDCManagerFQDN -and $SDDCManagerFQDN.Trim() -ne '') { $SDDCManagerFQDN } else { 'sddc-manager.vcf.lab' }
    $token           = 'mock-token-000000'
    Write-Host "  [MOCK] Skipping authentication. SDDC Manager: $SDDCManagerFQDN" -ForegroundColor DarkYellow
    Write-Host "  [MOCK] Token: $token" -ForegroundColor DarkYellow
} else {
    $SDDCManagerFQDN = Get-OrPrompt -Value $SDDCManagerFQDN -Prompt 'SDDC Manager FQDN' `
        -Validator { param($v) Test-FQDN $v } `
        -InvalidMessage 'Must be a valid FQDN (e.g. sddc-manager.vcf.lab).'
    $sddcUser = Get-OrPrompt -Value '' -Prompt 'SDDC Manager username (e.g. administrator@vsphere.local)'
    $sddcPass = Get-OrPrompt -Value '' -Prompt 'SDDC Manager password' -Secure `
        -Validator { param($v) Test-Password $v } `
        -InvalidMessage 'Password must be at least 8 characters.'
    $sddcPass = ConvertTo-SecureString $sddcPass -AsPlainText -Force
    $sddcCred = New-Object System.Management.Automation.PSCredential($sddcUser, $sddcPass)

    Write-Host "  Authenticating to $SDDCManagerFQDN ..." -ForegroundColor Cyan
    try {
        $token = Get-SDDCToken -FQDN $SDDCManagerFQDN -Credential $sddcCred
        Write-Host "  Token acquired." -ForegroundColor Green
    } catch {
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
        exit 1
    }
}
#endregion

#region --- Step 2: Select target cluster ---
Write-Host ("`n  [Step 2 of 6  --  Target Cluster Selection]") -ForegroundColor Cyan

if ($MockMode) {
    Write-Host "  [MOCK] Using mock cluster list." -ForegroundColor DarkYellow
    $clusterList = $MockClusters
} else {
    Write-Host "  Querying existing clusters from SDDC Manager ..." -ForegroundColor Cyan
    try {
        $clustersResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/clusters'
        $clusterList  = $clustersResp.elements
    } catch {
        Write-Host "  Failed to retrieve clusters: $_" -ForegroundColor Red
        exit 1
    }
    if (-not $clusterList -or $clusterList.Count -eq 0) {
        Write-Host "  No clusters found in SDDC Manager." -ForegroundColor Red
        exit 1
    }
}

Write-Host ''
Write-Host '  Available clusters:' -ForegroundColor White
$i = 1
foreach ($c in $clusterList) {
    Write-Host ("  [{0}] {1}  (ID: {2}  |  Status: {3})" -f $i, $c.name, $c.id, $c.status)
    $i++
}
Write-Host ''

$clusterIdx = [int](Read-Host -Prompt 'Select cluster to stretch') - 1
if ($clusterIdx -lt 0 -or $clusterIdx -ge $clusterList.Count) {
    Write-Host "  Invalid cluster selection." -ForegroundColor Red
    exit 1
}
$selectedCluster = $clusterList[$clusterIdx]
Write-Host "  Target cluster: $($selectedCluster.name)  (ID: $($selectedCluster.id))" -ForegroundColor Green
#endregion

#region --- Step 3: Witness host configuration ---
Write-Host ("`n  [Step 3 of 6  --  Witness Host Configuration]") -ForegroundColor Cyan

Write-Host ''
Write-Host '  The witness host arbitrates between the two availability zones.' -ForegroundColor White
Write-Host '  It must be deployed at a third location before stretching.' -ForegroundColor White
Write-Host '  It can be a vSAN Witness Appliance (OVA) or a physical host.' -ForegroundColor White
Write-Host ''

$WitnessFQDN     = Get-OrPrompt -Value $WitnessFQDN -Prompt 'Witness host FQDN (e.g. witness.vcf.lab)' `
    -Validator { param($v) Test-FQDN $v } `
    -InvalidMessage 'Must be a valid FQDN.'
$WitnessVsanIp   = Get-OrPrompt -Value $WitnessVsanIp -Prompt 'Witness vSAN IP address' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'
$WitnessVsanCidr = Get-OrPrompt -Value $WitnessVsanCidr -Prompt 'Witness vSAN network CIDR (e.g. 192.168.20.0/24)' `
    -Validator { param($v) Test-CIDR $v } `
    -InvalidMessage 'Must be a valid CIDR (e.g. 192.168.20.0/24).'

Write-Host "  Witness: $WitnessFQDN  |  vSAN IP: $WitnessVsanIp  |  CIDR: $WitnessVsanCidr" -ForegroundColor Green
#endregion

#region --- Step 4: Secondary site host selection ---
Write-Host ("`n  [Step 4 of 6  --  Availability Zone 2 Host Selection]") -ForegroundColor Cyan

Write-Host ''
Write-Host '  Select the hosts that will form availability zone 2.' -ForegroundColor White
Write-Host '  These must be unassigned commissioned hosts in SDDC Manager,' -ForegroundColor White
Write-Host '  commissioned against the AZ2 network pool.' -ForegroundColor White
Write-Host '  The number of AZ2 hosts should match the AZ1 host count.' -ForegroundColor White
Write-Host ''

if ($MockMode) {
    Write-Host "  [MOCK] Using mock host list." -ForegroundColor DarkYellow
    $availHosts = $MockHosts
} else {
    Write-Host "  Querying unassigned commissioned hosts ..." -ForegroundColor Cyan
    try {
        $allHosts   = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/hosts?status=UNASSIGNED_USEABLE'
        $availHosts = $allHosts.elements
    } catch {
        Write-Host "  Failed to retrieve hosts: $_" -ForegroundColor Red
        exit 1
    }
    if (-not $availHosts -or $availHosts.Count -eq 0) {
        Write-Host "  No unassigned commissioned hosts found in SDDC Manager." -ForegroundColor Red
        exit 1
    }
}

Write-Host '  Available unassigned hosts:' -ForegroundColor White
$i = 1
foreach ($h in $availHosts) {
    $cores  = Get-PropOrDefault (Get-PropOrDefault $h 'cpu' $null) 'cores'
    $memMB  = Get-PropOrDefault (Get-PropOrDefault $h 'memory' $null) 'totalCapacityMB' $null
    $ramGB  = if ($null -eq $memMB) { 'n/a' } else { [math]::Round($memMB / 1024, 0) }
    Write-Host ("  [{0}] {1}  |  CPU: {2} cores  |  RAM: {3} GB  |  Storage: {4}" -f `
        $i,
        (Get-PropOrDefault $h 'fqdn'),
        $cores,
        $ramGB,
        (Get-PropOrDefault $h 'storageType'))
    $i++
}

Write-Host ''
$selection = Read-Host -Prompt 'Enter host numbers for availability zone 2 (comma-separated or range, e.g. 1,2,3 or 1-3)'
$indices = @()
foreach ($part in ($selection -split ',')) {
    $part = $part.Trim()
    if ($part -match '^(\d+)-(\d+)$') {
        $indices += [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $_ - 1 }
    } elseif ($part -match '^\d+$') {
        $indices += [int]$part - 1
    } else {
        Write-Host "  Invalid selection token: '$part' - expected a number or range (e.g. 1,2,3 or 1-3)." -ForegroundColor Red
        exit 1
    }
}

$secondaryHosts = @()
foreach ($idx in $indices) {
    if ($idx -lt 0 -or $idx -ge $availHosts.Count) {
        Write-Host "  Invalid selection: $($idx + 1)" -ForegroundColor Red
        exit 1
    }
    $secondaryHosts += $availHosts[$idx]
}

if ($secondaryHosts.Count -eq 0) {
    Write-Host "  No hosts selected for availability zone 2." -ForegroundColor Red
    exit 1
}

Write-Host "  $($secondaryHosts.Count) host(s) selected for availability zone 2:" -ForegroundColor Green
foreach ($h in $secondaryHosts) { Write-Host "    - $($h.fqdn)" }
#endregion

#region --- Step 5: Network configuration ---
Write-Host ("`n  [Step 5 of 6  --  Network Configuration]") -ForegroundColor Cyan

# -- VDS name --
Write-Host ''
Write-Host '  The VDS name must match the existing VDS in the target cluster.' -ForegroundColor White
Write-Host ''
$vdsName = Get-OrPrompt -Value $VDSName -Prompt 'VDS name (must match existing cluster VDS)' `
    -Validator { param($v) Test-SimpleName $v } `
    -InvalidMessage 'VDS name must contain only letters, digits, hyphens, or underscores (no spaces or dots).'
Write-Host "  VDS name: $vdsName" -ForegroundColor Green

# -- VDS uplinks --
Write-Host ''
$uplinkInput = Get-OrPrompt -Value '' -Prompt 'VDS uplink names, comma-separated (press Enter for "uplink1,uplink2")' -Optional
$uplinkNames = if ($uplinkInput -and $uplinkInput.Trim() -ne '') {
    @($uplinkInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    @('uplink1', 'uplink2')
}
Write-Host "  Uplinks: $($uplinkNames -join ', ')" -ForegroundColor Green

# -- AZ2 NSX host TEP network --
Write-Host ''
Write-Host '  AZ2 hosts need their own NSX network profile: a host TEP IP pool' -ForegroundColor White
Write-Host '  and an uplink profile with the AZ2 host TEP (transport) VLAN.' -ForegroundColor White
Write-Host ''
$Az2TepCidr       = Get-OrPrompt -Value $Az2TepCidr -Prompt 'AZ2 host TEP pool CIDR (e.g. 192.168.32.0/24)' `
    -Validator { param($v) Test-CIDR $v } `
    -InvalidMessage 'Must be a valid CIDR (e.g. 192.168.32.0/24).'
$Az2TepGateway    = Get-OrPrompt -Value $Az2TepGateway -Prompt 'AZ2 host TEP pool gateway' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'
$Az2TepRangeStart = Get-OrPrompt -Value $Az2TepRangeStart -Prompt 'AZ2 host TEP pool range start' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'
$Az2TepRangeEnd   = Get-OrPrompt -Value $Az2TepRangeEnd -Prompt 'AZ2 host TEP pool range end' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'
$Az2TransportVlan = Get-OrPrompt -Value $Az2TransportVlan -Prompt 'AZ2 host TEP (transport) VLAN ID' `
    -Validator { param($v) Test-VlanId $v } `
    -InvalidMessage 'Must be a VLAN ID between 0 and 4094.'
Write-Host "  AZ2 TEP: $Az2TepCidr  |  GW: $Az2TepGateway  |  Range: $Az2TepRangeStart-$Az2TepRangeEnd  |  VLAN: $Az2TransportVlan" -ForegroundColor Green

# -- Network profile scope --
Write-Host ''
Write-Host '  Management domain default cluster (bring-up): the stretch spec defines the' -ForegroundColor White
Write-Host '  cluster''s first VCF network profile -> global config (answer y).' -ForegroundColor White
Write-Host '  Workload domain cluster: the default profile already exists -> the AZ2' -ForegroundColor White
Write-Host '  profile is a sub-config (answer n).' -ForegroundColor White
$defaultProfileChoice = ''
while ($defaultProfileChoice -notin @('y', 'n')) {
    $defaultProfileChoice = (Read-Host -Prompt 'Is this the cluster''s first VCF network profile? (y = management domain, n = workload domain)').ToLower()
    if ($defaultProfileChoice -notin @('y', 'n')) { Write-Host "  WARNING: Please enter y or n." -ForegroundColor Yellow }
}
$isDefaultNetworkProfile = ($defaultProfileChoice -eq 'y')
Write-Host "  Network profile isDefault: $isDefaultNetworkProfile" -ForegroundColor Green

# -- Multi-AZ flags --
Write-Host ''
$edgeChoice = ''
while ($edgeChoice -notin @('y', 'n')) {
    $edgeChoice = (Read-Host -Prompt 'Does an NSX Edge cluster run on this vSphere cluster, prepared for multi-AZ? (y/n)').ToLower()
    if ($edgeChoice -notin @('y', 'n')) { Write-Host "  WARNING: Please enter y or n." -ForegroundColor Yellow }
}
$isEdgeClusterConfiguredForMultiAZ = ($edgeChoice -eq 'y')

$witnessSharedChoice = ''
while ($witnessSharedChoice -notin @('y', 'n')) {
    $witnessSharedChoice = (Read-Host -Prompt 'Does witness traffic share the vSAN network? (y/n, usually n)').ToLower()
    if ($witnessSharedChoice -notin @('y', 'n')) { Write-Host "  WARNING: Please enter y or n." -ForegroundColor Yellow }
}
$witnessTrafficSharedWithVsanTraffic = ($witnessSharedChoice -eq 'y')

Write-Host ("  Edge multi-AZ: {0}  |  Witness traffic shared with vSAN: {1}" -f `
    $isEdgeClusterConfiguredForMultiAZ, $witnessTrafficSharedWithVsanTraffic) -ForegroundColor Green

#endregion

#region --- Step 6: Build JSON payload ---
Write-Host ("`n  [Step 6 of 6  --  Building JSON Payload]") -ForegroundColor Cyan

# -- Generated AZ2 NSX object names --
$networkProfileName = "$($selectedCluster.name)-az2-network-profile01"
$tepPoolName        = "$($selectedCluster.name)-az2-tep-pool"
$uplinkProfileName  = "$($selectedCluster.name)-az2-uplink-profile01"
$nsxUplinkNames     = for ($j = 1; $j -le $uplinkNames.Count; $j++) { "uplink-$j" }

# -- AZ2 host specs --
$az2HostSpecs = @()
foreach ($h in $secondaryHosts) {
    $nicIds = @('vmnic0', 'vmnic1')
    $vmNics = for ($j = 0; $j -lt $nicIds.Count; $j++) {
        @{ id = $nicIds[$j]; vdsName = $vdsName; uplink = $uplinkNames[$j % $uplinkNames.Count] }
    }
    $az2HostSpecs += @{
        id              = $h.id
        hostname        = $h.fqdn
        hostNetworkSpec = @{
            networkProfileName = $networkProfileName
            vmNics             = $vmNics
        }
    }
}

# -- Full payload (body for PATCH /v1/clusters/{id}) --
$payload = @{
    clusterStretchSpec = @{
        deployWithoutLicenseKeys            = $true
        hostSpecs                           = $az2HostSpecs
        isEdgeClusterConfiguredForMultiAZ   = $isEdgeClusterConfiguredForMultiAZ
        networkSpec                         = @{
            networkProfiles = @(
                @{
                    isDefault             = $isDefaultNetworkProfile
                    name                  = $networkProfileName
                    nsxtHostSwitchConfigs = @(
                        @{
                            ipAddressPoolName    = $tepPoolName
                            uplinkProfileName    = $uplinkProfileName
                            vdsName              = $vdsName
                            vdsUplinkToNsxUplink = for ($j = 0; $j -lt $uplinkNames.Count; $j++) {
                                @{ nsxUplinkName = $nsxUplinkNames[$j]; vdsUplinkName = $uplinkNames[$j] }
                            }
                        }
                    )
                }
            )
            nsxClusterSpec  = @{
                ipAddressPoolsSpec = @(
                    @{
                        name        = $tepPoolName
                        description = "AZ2 host TEP pool"
                        subnets     = @(
                            @{
                                cidr                = $Az2TepCidr
                                gateway             = $Az2TepGateway
                                ipAddressPoolRanges = @(
                                    @{ start = $Az2TepRangeStart; end = $Az2TepRangeEnd }
                                )
                            }
                        )
                    }
                )
                uplinkProfiles     = @(
                    @{
                        name          = $uplinkProfileName
                        transportVlan = [int]$Az2TransportVlan
                        teamings      = @(
                            @{
                                name           = 'DEFAULT'
                                policy         = 'LOADBALANCE_SRCID'
                                activeUplinks  = @($nsxUplinkNames)
                                standByUplinks = @()
                            }
                        )
                    }
                )
            }
        }
        witnessSpec                         = @{
            fqdn     = $WitnessFQDN
            vsanIp   = $WitnessVsanIp
            vsanCidr = $WitnessVsanCidr
        }
        witnessTrafficSharedWithVsanTraffic = $witnessTrafficSharedWithVsanTraffic
    }
}

$jsonOutput = $payload | ConvertTo-Json -Depth 20
Write-Host "  JSON payload built successfully." -ForegroundColor Green
#endregion

#region --- Save JSON to file ---
# Written BEFORE validation on purpose: validation is a long round trip that can fail,
# time out or be interrupted, and the payload is 30+ prompts of work. Get it on disk
# first so a failed validation costs a retry, not the whole run.
Write-Host ("`n  [Output  --  Saving JSON]") -ForegroundColor Cyan

if ($OutputJsonPath -and $OutputJsonPath.Trim() -ne '') {
    $parentDir = Split-Path -Parent $OutputJsonPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        Write-Host "  WARNING: Output directory '$parentDir' does not exist. Falling back to script directory." -ForegroundColor Yellow
        $OutputJsonPath = ''
    }
}
if (-not $OutputJsonPath -or $OutputJsonPath.Trim() -eq '') {
    $ts             = Get-Date -Format 'yyyyMMdd-HHmmss'
    $scriptDir      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $clusterSlug    = $selectedCluster.name -replace '[^a-zA-Z0-9\-_]', '-'
    $OutputJsonPath = Join-Path $scriptDir "$clusterSlug-vsan-stretch-$ts.json"
}

try {
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputJsonPath, $jsonOutput, $utf8Bom)
    Write-Host "  JSON saved to: $OutputJsonPath" -ForegroundColor Green
} catch {
    Write-Host "  Failed to save JSON: $_" -ForegroundColor Red
}
#endregion

#region --- Validate ---
Write-Host ("`n  [Validation  --  SDDC Manager API]") -ForegroundColor Cyan

if ($MockMode) {
    Write-Host "  [MOCK] Skipping live validation. Returning mock SUCCEEDED result." -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host "  Validation PASSED (mock). Stretch spec JSON is ready for review." -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '  The JSON is already saved. Validation is optional from here: the script can' -ForegroundColor White
    Write-Host '  submit it and poll for the result, or you can validate it yourself in SDDC' -ForegroundColor White
    Write-Host '  Manager and skip ahead to the execute step.' -ForegroundColor White
    Write-Host ''

    $validateChoice = ''
    while ($validateChoice -notin @('y', 'n')) {
        $validateChoice = (Read-Host -Prompt 'Validate the JSON with this script? (y/n)').ToLower()
        if ($validateChoice -notin @('y', 'n')) { Write-Host "  WARNING: Please enter y or n." -ForegroundColor Yellow }
    }

    if ($validateChoice -eq 'y') {
        Write-Host "  Submitting validation request to /v1/clusters/$($selectedCluster.id)/validations ..." -ForegroundColor Cyan
        $validationBody = @{ clusterUpdateSpec = @{ clusterStretchSpec = $payload.clusterStretchSpec } }
        $validationResp = $null
        try {
            $validationResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token `
                -Method POST -Path "/v1/clusters/$($selectedCluster.id)/validations" -Body $validationBody
        } catch {
            Write-Host "  Validation request failed: $_" -ForegroundColor Red
        }

        if ($validationResp) {
            $validationId = Get-PropOrDefault $validationResp 'id' $null
            Write-Host "  Validation submitted. ID: $validationId" -ForegroundColor Green

            # The POST response shape decides which id is pollable. Keep it visible: a
            # TASK_NOT_FOUND on the GET means this id is not the one the status endpoint
            # wants, and without the raw body there is no way to tell which field is.
            Write-Host "  POST response fields: $($validationResp.PSObject.Properties.Name -join ', ')" -ForegroundColor DarkGray

            Write-Host "  Polling for validation result ..." -ForegroundColor Cyan

            $maxWait     = 300
            $interval    = 10
            $elapsed     = 0
            $finalStatus = $null
            $poll        = $null

            # Status is tracked on the cluster-scoped path, same as the kickoff POST.
            # SDDC Manager can answer TASK_NOT_FOUND for the first few seconds after the
            # POST returns, before the validation task is registered - that is expected
            # and transient, so early failures are reported quietly and retried.
            $pollPath     = "/v1/clusters/$($selectedCluster.id)/validations/$validationId"
            $failStreak   = 0
            $maxFailures  = 6
            $lastPollErr  = $null

            while ($elapsed -lt $maxWait) {
                Start-Sleep -Seconds $interval
                $elapsed += $interval

                try {
                    $poll = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path $pollPath
                } catch {
                    $lastPollErr = $_
                    $failStreak++
                    if ($failStreak -eq 1) {
                        Write-Host "    Elapsed: ${elapsed}s  |  validation task not registered yet, retrying ..." -ForegroundColor DarkGray
                    } else {
                        Write-Host "  WARNING: Poll attempt failed ($failStreak/$maxFailures): $lastPollErr" -ForegroundColor Yellow
                    }
                    if ($failStreak -ge $maxFailures) {
                        Write-Host "  Giving up on polling after $failStreak consecutive failures." -ForegroundColor Yellow
                        Write-Host "  The validation may still be running. Check it manually:" -ForegroundColor Yellow
                        Write-Host "    GET https://$SDDCManagerFQDN$pollPath" -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '  Raw POST response (which field is the pollable id?):' -ForegroundColor DarkGray
                        Write-Host ($validationResp | ConvertTo-Json -Depth 5) -ForegroundColor DarkGray
                        break
                    }
                    continue
                }

                $failStreak  = 0
                $finalStatus = Get-PropOrDefault $poll 'executionStatus' $null
                Write-Host "    Elapsed: ${elapsed}s  |  Status: $finalStatus" -ForegroundColor DarkGray
                if ($finalStatus -in @('COMPLETED', 'FAILED')) { break }
            }

            Write-Host ''
            if ($finalStatus -eq 'COMPLETED') {
                $resultStatus = Get-PropOrDefault $poll 'resultStatus' $null
                if ($resultStatus -eq 'SUCCEEDED') {
                    Write-Host "  Validation PASSED. Stretch spec JSON is ready for deployment." -ForegroundColor Green
                } else {
                    Write-Host "  Validation FAILED (resultStatus: $resultStatus)" -ForegroundColor Red
                    $checks = Get-PropOrDefault $poll 'validationChecks' $null
                    if ($checks) {
                        Write-Host ''
                        Write-Host '  Validation errors:' -ForegroundColor Red
                        foreach ($check in $checks) {
                            if ((Get-PropOrDefault $check 'resultStatus' $null) -ne 'SUCCEEDED') {
                                Write-Host ("    [{0}] {1} - {2}" -f `
                                    (Get-PropOrDefault $check 'resultStatus'),
                                    (Get-PropOrDefault $check 'description'),
                                    (Get-PropOrDefault $check 'errorMessage')) -ForegroundColor Red
                            }
                        }
                    }
                }
            } elseif ($finalStatus -eq 'FAILED') {
                Write-Host "  Validation execution itself failed. Check SDDC Manager logs." -ForegroundColor Red
            } else {
                Write-Host "  WARNING: Validation timed out after ${maxWait}s. Last status: $finalStatus" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  WARNING: Validation skipped. Review the JSON before deploying:" -ForegroundColor Yellow
        Write-Host "    $OutputJsonPath" -ForegroundColor DarkGray
    }
}
#endregion

#region --- Optional: Execute stretch ---
Write-Host ("`n  [Execute  --  Stretch Operation (optional)]") -ForegroundColor Cyan

if ($MockMode) {
    Write-Host "  [MOCK] Execution is not available in mock mode." -ForegroundColor DarkYellow
} else {
    $executeChoice = ''
    while ($executeChoice -notin @('y', 'n')) {
        $executeChoice = (Read-Host -Prompt 'Execute the stretch operation now? (y/n)').ToLower()
        if ($executeChoice -notin @('y', 'n')) { Write-Host "  WARNING: Please enter y or n." -ForegroundColor Yellow }
    }

    if ($executeChoice -eq 'y') {
        $executeJsonPath = Read-Host -Prompt "Path to stretch spec JSON (press Enter for '$OutputJsonPath')"
        if (-not $executeJsonPath -or $executeJsonPath.Trim() -eq '') { $executeJsonPath = $OutputJsonPath }

        $executePayload = $null
        try {
            $executePayload = Get-Content -LiteralPath $executeJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Host "  Failed to read or parse JSON file: $_" -ForegroundColor Red
        }

        if ($executePayload -and -not ($executePayload.PSObject.Properties.Name -contains 'clusterStretchSpec')) {
            Write-Host "  The JSON file does not contain a 'clusterStretchSpec' object. Execution cancelled." -ForegroundColor Red
            $executePayload = $null
        }

        if ($executePayload) {
            Write-Host ''
            Write-Host "  This starts the stretch workflow on cluster '$($selectedCluster.name)'." -ForegroundColor Yellow
            Write-Host '  The operation is long-running and cannot easily be undone.' -ForegroundColor Yellow
            $confirmName = Read-Host -Prompt 'Type the cluster name to confirm execution'
            if ($confirmName -cne $selectedCluster.name) {
                Write-Host "  Confirmation did not match '$($selectedCluster.name)'. Execution cancelled." -ForegroundColor Yellow
            } else {
                Write-Host "  Submitting PATCH /v1/clusters/$($selectedCluster.id) ..." -ForegroundColor Cyan
                try {
                    $taskResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token `
                        -Method PATCH -Path "/v1/clusters/$($selectedCluster.id)" -Body $executePayload
                    Write-Host "  Stretch task submitted." -ForegroundColor Green
                    if ($taskResp -and ($taskResp.PSObject.Properties.Name -contains 'id')) {
                        Write-Host "  Task ID: $($taskResp.id)" -ForegroundColor Green
                        Write-Host "  Monitor progress in the SDDC Manager UI (Tasks panel) or via:" -ForegroundColor DarkGray
                        Write-Host "  GET https://$SDDCManagerFQDN/v1/tasks/$($taskResp.id)" -ForegroundColor DarkGray
                    }
                } catch {
                    Write-Host "  Stretch request failed: $_" -ForegroundColor Red
                }
            }
        }
    } else {
        Write-Host "  Execution skipped. The saved JSON can be submitted later." -ForegroundColor DarkGray
    }
}
#endregion

Write-Host ''
Write-Host '  To apply the stretch operation, PATCH the saved JSON to:' -ForegroundColor DarkGray
Write-Host "  PATCH https://$SDDCManagerFQDN/v1/clusters/$($selectedCluster.id)" -ForegroundColor DarkGray
Write-Host ''
if ($MockMode) {
    Write-Host '  Done. (mock mode - no changes were made to SDDC Manager)' -ForegroundColor DarkYellow
} else {
    Write-Host '  Done.' -ForegroundColor Cyan
}
Write-Host ''
