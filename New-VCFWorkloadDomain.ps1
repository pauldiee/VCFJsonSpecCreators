#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a VCF 9 Workload Domain JSON, validates it against SDDC Manager, and saves it to file.

.DESCRIPTION
    - Queries SDDC Manager for unassigned commissioned hosts
    - Collects domain, vCenter, NSX, vSAN, and network pool configuration
    - Builds the workload domain JSON payload
    - Validates via SDDC Manager API (/v1/domains/validations)
    - Saves the JSON to disk
    - Supports mock mode for offline/lab testing without live SDDC Manager

.AUTHOR
    Paul van Dieen | hollebollevsan.nl

.VERSION
    1.4.0

.CHANGELOG
    1.0.0 - Initial release
    1.1.0 - Fixed SSL bypass for PowerShell 7 / .NET 6+ (ICertificatePolicy removed); added -SkipCertificateCheck to all Invoke-RestMethod calls
    1.2.0 - Added mock mode for offline testing (stub auth, hosts, pools, NSX instances, validation)
    1.2.1 - Fixed host selection to accept range input (e.g. 1-3); fixed scalar/array bug on storageType unique check
    1.3.0 - Added input validation (FQDN format, simple name, password length, license key format, output path); fixed $token loop-variable collision in host selection
    1.4.0 - Added Step 5 for VDS / network configuration: vCenter IP/gateway/subnet/size, VDS name/MTU, port-group VLAN IDs, activeUplinks, configurable geneveVlanId, optional static TEP IP pool, ESXi license key

.PARAMETER MockMode
    Run in mock mode: skips all SDDC Manager API calls and uses built-in stub data.
    Can also be enabled by setting $MockModeVar = $true in the variables block below.
#>

[CmdletBinding()]
param(
    [switch]$MockMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Pre-filled variables (leave blank to be prompted) ─────────────────
$ScriptVersion      = '1.4.0'
$MockModeVar        = $false      # set to $true to enable mock mode without the -MockMode switch

$SDDCManagerFQDN    = ''          # e.g. sddc-manager.vcf.lab

$DomainName         = ''          # e.g. wld-01
$vCenterFQDN        = ''          # e.g. vcenter-wld01.vcf.lab
$vCenterName        = ''          # e.g. vcenter-wld01
$vCenterDatacenter  = ''          # e.g. WLD-Datacenter
$vCenterCluster     = ''          # e.g. WLD-Cluster-01
# -- vCenter networking (required by SDDC Manager API):
$vCenterIP          = ''          # e.g. 192.168.10.10
$vCenterGateway     = ''          # e.g. 192.168.10.1
$vCenterSubnetMask  = ''          # e.g. 255.255.255.0
$vCenterSize        = ''          # tiny, small, medium, large, xlarge

# -- VDS:
$VDSName            = ''          # leave blank to auto-generate (<DomainName>-vds01)
$VDSMtu             = ''          # leave blank to default to 9000
$VMotionVlanId      = ''          # e.g. 100
$VSanVlanId         = ''          # e.g. 101
$NSXTepVlanId       = ''          # e.g. 102  (also becomes geneveVlanId)
# -- NSX TEP static IP pool (leave all blank to use DHCP on the TEP VLAN):
$NSXTepPoolCidr     = ''          # e.g. 192.168.11.0/24
$NSXTepPoolGateway  = ''          # e.g. 192.168.11.1
$NSXTepPoolStart    = ''          # e.g. 192.168.11.50
$NSXTepPoolEnd      = ''          # e.g. 192.168.11.70

# -- ESXi:
$ESXiLicenseKey     = ''          # common ESXi license key for all hosts (leave blank to skip)

$NetworkPoolName    = ''          # existing network pool name in SDDC Manager

$NSXMode            = ''          # 'new' or 'existing' (leave blank to prompt)
# -- New NSX only:
$NSXManagerVIP      = ''          # e.g. nsx-wld01-vip.vcf.lab
$NSXManager1FQDN    = ''          # e.g. nsx-wld01-m1.vcf.lab
$NSXManager2FQDN    = ''          # e.g. nsx-wld01-m2.vcf.lab (leave blank for single node)
$NSXManager3FQDN    = ''          # e.g. nsx-wld01-m3.vcf.lab (leave blank for single node)
$NSXAdminPassword   = ''          # leave blank to prompt securely
$NSXAuditPassword   = ''          # leave blank to prompt securely
$NSXRootPassword    = ''          # leave blank to prompt securely
$NSXLicenseKey      = ''          # leave blank to skip (optional)

$OutputJsonPath     = ''          # e.g. C:\VCF\wld-01-domain.json (leave blank to auto-generate)
#endregion ───────────────────────────────────────────────────────────────────

# Resolve mock mode from either source
if ($MockModeVar) { $MockMode = [switch]$true }

#region ── Mock data ──────────────────────────────────────────────────────────
# Stub data used when -MockMode is active. Edit to match your intended config.
$MockHosts = @(
    [PSCustomObject]@{
        id          = 'host-mock-001'
        fqdn        = 'esxi-01.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
    [PSCustomObject]@{
        id          = 'host-mock-002'
        fqdn        = 'esxi-02.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
    [PSCustomObject]@{
        id          = 'host-mock-003'
        fqdn        = 'esxi-03.vcf.lab'
        storageType = 'ESA'
        cpu         = [PSCustomObject]@{ cores = 32 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 262144 }
    }
    [PSCustomObject]@{
        id          = 'host-mock-004'
        fqdn        = 'esxi-04.vcf.lab'
        storageType = 'OSA'           # intentionally OSA — select with an ESA host to test mixed-storage abort
        cpu         = [PSCustomObject]@{ cores = 16 }
        memory      = [PSCustomObject]@{ totalCapacityMB = 131072 }
    }
)

$MockPools = @(
    [PSCustomObject]@{ id = 'pool-mock-001'; name = 'MockPool-WLD' }
    [PSCustomObject]@{ id = 'pool-mock-002'; name = 'MockPool-Secondary' }
)

$MockNSXInstances = @(
    [PSCustomObject]@{
        id                 = 'nsx-mock-001'
        vip                = '192.168.10.50'
        vipFqdn            = 'nsx-mgmt-vip.vcf.lab'
        nsxtManagerVersion = '4.2.0.0'
    }
)
#endregion ───────────────────────────────────────────────────────────────────

#region ── Helpers ────────────────────────────────────────────────────────────
function Test-FQDN {
    param([string]$Value)
    return [bool]($Value -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$')
}

function Test-SimpleName {
    param([string]$Value)
    # Alphanumeric, hyphens, underscores — no spaces or dots (safe for VDS / port-group names)
    return [bool]($Value -match '^[a-zA-Z0-9][a-zA-Z0-9\-_]{0,62}$')
}

function Test-IPAddress {
    param([string]$Value)
    $addr = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$addr) -and
           $addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-VlanId {
    param([string]$Value)
    if ($Value -notmatch '^\d+$') { return $false }
    $id = [int]$Value
    return $id -ge 0 -and $id -le 4094
}

function Test-Cidr {
    param([string]$Value)
    if ($Value -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$') { return $false }
    $prefix = [int]($Value -split '/')[1]
    return $prefix -ge 1 -and $prefix -le 32
}

function Test-Password {
    param([string]$Value)
    return $Value.Length -ge 8
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
    # Try pre-filled value first
    if ($Value -and $Value.Trim() -ne '') {
        if (-not $Validator -or (& $Validator $Value.Trim())) { return $Value }
        Write-Warn "Pre-filled value is invalid: $InvalidMessage"
    }
    # Interactive prompt loop
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
            Write-Warn 'This field cannot be empty.'
            continue
        }
        if ($Validator -and -not (& $Validator $result.Trim())) {
            Write-Warn $InvalidMessage
            continue
        }
        return $result
    }
}

function Write-Header {
    param([string]$Text)
    $line = '-' * 60
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Step { param([string]$Text) Write-Host "  >> $Text" -ForegroundColor Yellow }
function Write-OK   { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Magenta }
function Write-Fail { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Mock { param([string]$Text) Write-Host "  [MOCK] $Text" -ForegroundColor DarkYellow }

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
    $resp = Invoke-RestMethod -Uri $uri -Method POST -ContentType 'application/json' -Body $body -SkipCertificateCheck
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
        Uri                  = $uri
        Method               = $Method
        Headers              = $headers
        ContentType          = 'application/json'
        SkipCertificateCheck = $true
    }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 20) }
    return Invoke-RestMethod @params
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── SSL / TLS ──────────────────────────────────────────────────────────
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
#endregion ───────────────────────────────────────────────────────────────────

#region ── Banner ────────────────────────────────────────────────────────────
$border  = '═' * 58
$blank   = '║' + (' ' * 58) + '║'
$title   = 'VCF Workload Domain Creator'
$sub     = "Paul van Dieen  |  hollebollevsan.nl  |  v$ScriptVersion"
$titleLine = '║   ' + $title + (' ' * (55 - $title.Length)) + '║'
$subLine   = '║   ' + $sub   + (' ' * (55 - $sub.Length))   + '║'
Write-Host ''
Write-Host "╔$border╗" -ForegroundColor Cyan
Write-Host $blank      -ForegroundColor Cyan
Write-Host $titleLine  -ForegroundColor Cyan
Write-Host $subLine    -ForegroundColor DarkCyan
Write-Host $blank      -ForegroundColor Cyan
Write-Host "╚$border╝" -ForegroundColor Cyan
Write-Host ''
#endregion ───────────────────────────────────────────────────────────────────

#region ── Mock mode banner ───────────────────────────────────────────────────
if ($MockMode) {
    $mockBanner = '=' * 60
    Write-Host ''
    Write-Host $mockBanner -ForegroundColor DarkYellow
    Write-Host '  MOCK MODE ACTIVE - no SDDC Manager calls will be made' -ForegroundColor DarkYellow
    Write-Host '  Stub data is used for hosts, pools, NSX, and validation' -ForegroundColor DarkYellow
    Write-Host $mockBanner -ForegroundColor DarkYellow
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 1: SDDC Manager connection ────────────────────────────────────
Write-Header 'Step 1 of 8  |  SDDC Manager Connection'

if ($MockMode) {
    $SDDCManagerFQDN = if ($SDDCManagerFQDN -and $SDDCManagerFQDN.Trim() -ne '') { $SDDCManagerFQDN } else { 'sddc-manager.vcf.lab' }
    $token           = 'mock-token-000000'
    Write-Mock "Skipping authentication. SDDC Manager: $SDDCManagerFQDN"
    Write-Mock "Token: $token"
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

    Write-Step "Authenticating to $SDDCManagerFQDN ..."
    try {
        $token = Get-SDDCToken -FQDN $SDDCManagerFQDN -Credential $sddcCred
        Write-OK 'Token acquired.'
    } catch {
        Write-Fail "Authentication failed: $_"
        exit 1
    }
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 2: Select unassigned hosts ────────────────────────────────────
Write-Header 'Step 2 of 8  |  Host Selection'

if ($MockMode) {
    Write-Mock 'Using mock host list (hosts 1-3 = ESA, host 4 = OSA for mixed-storage abort test).'
    $availHosts = $MockHosts
} else {
    Write-Step 'Querying unassigned commissioned hosts ...'
    try {
        $allHosts   = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/hosts?status=UNASSIGNED_USEABLE'
        $availHosts = $allHosts.elements
    } catch {
        Write-Fail "Failed to retrieve hosts: $_"
        exit 1
    }
    if (-not $availHosts -or $availHosts.Count -eq 0) {
        Write-Fail 'No unassigned commissioned hosts found in SDDC Manager.'
        exit 1
    }
}

Write-Host ''
Write-Host '  Available unassigned hosts:' -ForegroundColor White
$i = 1
foreach ($h in $availHosts) {
    Write-Host ("  [{0}] {1}  |  CPU: {2} cores  |  RAM: {3} GB  |  Storage: {4}" -f `
        $i,
        $h.fqdn,
        $h.cpu.cores,
        [math]::Round($h.memory.totalCapacityMB / 1024, 0),
        $h.storageType)
    $i++
}

Write-Host ''
$selection = Read-Host -Prompt 'Enter host numbers to include (comma-separated, e.g. 1,2,3)'
$indices = @()
foreach ($part in ($selection -split ',')) {
    $part = $part.Trim()
    if ($part -match '^(\d+)-(\d+)$') {
        # Range e.g. "1-3"
        $indices += [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $_ - 1 }
    } elseif ($part -match '^\d+$') {
        $indices += [int]$part - 1
    } else {
        Write-Fail "Invalid selection token: '$part' — expected a number or range (e.g. 1,2,3 or 1-3)."
        exit 1
    }
}

$selectedHosts = @()
foreach ($idx in $indices) {
    if ($idx -lt 0 -or $idx -ge $availHosts.Count) {
        Write-Fail "Invalid selection: $($idx + 1)"
        exit 1
    }
    $selectedHosts += $availHosts[$idx]
}

if ($selectedHosts.Count -lt 2) {
    Write-Warn 'At least 2 hosts are recommended for a workload domain.'
}

Write-OK "$($selectedHosts.Count) host(s) selected:"
foreach ($h in $selectedHosts) { Write-Host "    - $($h.fqdn)" }
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 3: Detect storage type ───────────────────────────────────────
Write-Header 'Step 3 of 8  |  Storage Type Detection'

$storageTypes = @($selectedHosts | Select-Object -ExpandProperty storageType -Unique)
if ($storageTypes.Count -gt 1) {
    Write-Fail "Mixed storage types detected across selected hosts: $($storageTypes -join ', ')"
    Write-Fail 'All hosts in a cluster must use the same storage type. Aborting.'
    exit 1
}

$storageType = $storageTypes[0]
Write-OK "Storage type: $storageType"
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 4: Domain / vCenter configuration ────────────────────────────
Write-Header 'Step 4 of 8  |  Domain and vCenter Configuration'

$DomainName        = Get-OrPrompt -Value $DomainName        -Prompt 'Workload domain name (e.g. wld-01)' `
    -Validator { param($v) Test-SimpleName $v } `
    -InvalidMessage 'Domain name must start with a letter or digit and contain only letters, digits, hyphens, or underscores (no spaces or dots).'
$vCenterFQDN       = Get-OrPrompt -Value $vCenterFQDN       -Prompt 'vCenter FQDN' `
    -Validator { param($v) Test-FQDN $v } `
    -InvalidMessage 'Must be a valid FQDN (e.g. vcenter-wld01.vcf.lab).'
$vCenterName       = Get-OrPrompt -Value $vCenterName       -Prompt 'vCenter name (short)' `
    -Validator { param($v) Test-SimpleName $v } `
    -InvalidMessage 'vCenter name must contain only letters, digits, hyphens, or underscores (no spaces or dots).'
$vCenterDatacenter = Get-OrPrompt -Value $vCenterDatacenter -Prompt 'Datacenter name'
$vCenterCluster    = Get-OrPrompt -Value $vCenterCluster    -Prompt 'Cluster name'

$vCenterRootPass  = Get-OrPrompt -Value '' -Prompt 'vCenter root password' -Secure `
    -Validator { param($v) Test-Password $v } `
    -InvalidMessage 'Password must be at least 8 characters.'
$vCenterAdminPass = Get-OrPrompt -Value '' -Prompt 'vCenter admin (administrator@vsphere.local) password' -Secure `
    -Validator { param($v) Test-Password $v } `
    -InvalidMessage 'Password must be at least 8 characters.'
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 5: VDS / Network configuration ───────────────────────────────
Write-Header 'Step 5 of 8  |  VDS and Network Configuration'

# ── vCenter networking ────────────────────────────────────────────────────────
$vcenterIP = Get-OrPrompt -Value $vCenterIP -Prompt 'vCenter IP address' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address (e.g. 192.168.10.10).'
$vcenterGateway = Get-OrPrompt -Value $vCenterGateway -Prompt 'vCenter default gateway' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address (e.g. 192.168.10.1).'
$vcenterSubnetMask = Get-OrPrompt -Value $vCenterSubnetMask -Prompt 'vCenter subnet mask' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid subnet mask (e.g. 255.255.255.0).'

# ── vCenter appliance size ────────────────────────────────────────────────────
$validVCSizes = @('tiny','small','medium','large','xlarge')
if ($vCenterSize -and $vCenterSize.Trim().ToLower() -in $validVCSizes) {
    $vcSize = $vCenterSize.Trim().ToLower()
    Write-OK "vCenter size (pre-filled): $vcSize"
} else {
    if ($vCenterSize -and $vCenterSize.Trim() -ne '') {
        Write-Warn "Pre-filled vCenter size '$vCenterSize' is not valid. Please select."
    }
    Write-Host ''
    Write-Host '  vCenter appliance size:' -ForegroundColor White
    Write-Host '  [1] tiny   [2] small   [3] medium   [4] large   [5] xlarge'
    Write-Host ''
    $vcSizeMap = @{ '1'='tiny'; '2'='small'; '3'='medium'; '4'='large'; '5'='xlarge' }
    $vcSizeChoice = ''
    while ($vcSizeChoice -notin @('1','2','3','4','5')) {
        $vcSizeChoice = Read-Host -Prompt 'Select vCenter size (1-5)'
        if ($vcSizeChoice -notin @('1','2','3','4','5')) { Write-Warn 'Please enter a number from 1 to 5.' }
    }
    $vcSize = $vcSizeMap[$vcSizeChoice]
}
Write-OK "vCenter size: $vcSize"

# ── VDS name & MTU ────────────────────────────────────────────────────────────
$vdsName = if ($VDSName -and $VDSName.Trim() -ne '') { $VDSName.Trim() } else { "$DomainName-vds01" }
Write-OK "VDS name: $vdsName"

$vdsMtuInput = Get-OrPrompt -Value $VDSMtu -Prompt 'VDS MTU (press Enter for 9000)' -Optional `
    -Validator { param($v) $v -match '^\d+$' -and [int]$v -ge 1500 -and [int]$v -le 9216 } `
    -InvalidMessage 'MTU must be an integer between 1500 and 9216.'
$vdsMtu = if ($vdsMtuInput -and $vdsMtuInput.Trim() -ne '') { [int]$vdsMtuInput } else { 9000 }
Write-OK "VDS MTU: $vdsMtu"

# ── VDS uplinks ───────────────────────────────────────────────────────────────
Write-Host ''
$uplinkInput = Get-OrPrompt -Value '' -Prompt 'VDS uplink names, comma-separated (press Enter for "uplink1,uplink2")' -Optional
$uplinkNames = if ($uplinkInput -and $uplinkInput.Trim() -ne '') {
    @($uplinkInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    @('uplink1', 'uplink2')
}
Write-OK "Uplinks: $($uplinkNames -join ', ')"

# ── Port group VLAN IDs ───────────────────────────────────────────────────────
$vMotionVlan = [int](Get-OrPrompt -Value $VMotionVlanId -Prompt 'vMotion port group VLAN ID (0-4094)' `
    -Validator { param($v) Test-VlanId $v } `
    -InvalidMessage 'VLAN ID must be an integer between 0 and 4094.')
$vsanVlan = [int](Get-OrPrompt -Value $VSanVlanId -Prompt 'vSAN port group VLAN ID (0-4094)' `
    -Validator { param($v) Test-VlanId $v } `
    -InvalidMessage 'VLAN ID must be an integer between 0 and 4094.')
$nsxTepVlan = [int](Get-OrPrompt -Value $NSXTepVlanId -Prompt 'NSX TEP (Geneve) VLAN ID (0-4094)' `
    -Validator { param($v) Test-VlanId $v } `
    -InvalidMessage 'VLAN ID must be an integer between 0 and 4094.')
Write-OK "VLAN IDs — vMotion: $vMotionVlan  |  vSAN: $vsanVlan  |  NSX TEP: $nsxTepVlan"

# ── NSX TEP IP pool (optional — leave blank to rely on DHCP) ─────────────────
$nsxTepPoolSpec = $null
$allTepPoolVarsSet = ($NSXTepPoolCidr    -and $NSXTepPoolCidr.Trim()    -ne '') -and
                    ($NSXTepPoolGateway  -and $NSXTepPoolGateway.Trim() -ne '') -and
                    ($NSXTepPoolStart    -and $NSXTepPoolStart.Trim()   -ne '') -and
                    ($NSXTepPoolEnd      -and $NSXTepPoolEnd.Trim()     -ne '')

if ($allTepPoolVarsSet) {
    # Validate pre-filled values
    $tepCidr    = $NSXTepPoolCidr.Trim()
    $tepGateway = $NSXTepPoolGateway.Trim()
    $tepStart   = $NSXTepPoolStart.Trim()
    $tepEnd     = $NSXTepPoolEnd.Trim()
    if (-not (Test-Cidr $tepCidr))        { Write-Warn "Pre-filled NSXTepPoolCidr '$tepCidr' is invalid.";       $allTepPoolVarsSet = $false }
    if (-not (Test-IPAddress $tepGateway)){ Write-Warn "Pre-filled NSXTepPoolGateway '$tepGateway' is invalid."; $allTepPoolVarsSet = $false }
    if (-not (Test-IPAddress $tepStart))  { Write-Warn "Pre-filled NSXTepPoolStart '$tepStart' is invalid.";     $allTepPoolVarsSet = $false }
    if (-not (Test-IPAddress $tepEnd))    { Write-Warn "Pre-filled NSXTepPoolEnd '$tepEnd' is invalid.";         $allTepPoolVarsSet = $false }
}

if (-not $allTepPoolVarsSet) {
    Write-Host ''
    Write-Host '  NSX TEP IP addressing:' -ForegroundColor White
    Write-Host '  [1] Use DHCP on the TEP VLAN'
    Write-Host '  [2] Configure a static IP pool for TEP addresses'
    Write-Host ''
    $tepChoice = ''
    while ($tepChoice -notin @('1', '2')) {
        $tepChoice = Read-Host -Prompt 'Select TEP IP option (1 or 2)'
        if ($tepChoice -notin @('1', '2')) { Write-Warn 'Please enter 1 or 2.' }
    }
    if ($tepChoice -eq '2') {
        $tepCidr    = Get-OrPrompt -Value '' -Prompt 'TEP IP pool CIDR (e.g. 192.168.11.0/24)' `
            -Validator { param($v) Test-Cidr $v } `
            -InvalidMessage 'Must be a valid CIDR (e.g. 192.168.11.0/24).'
        $tepGateway = Get-OrPrompt -Value '' -Prompt 'TEP IP pool gateway' `
            -Validator { param($v) Test-IPAddress $v } `
            -InvalidMessage 'Must be a valid IPv4 address.'
        $tepStart   = Get-OrPrompt -Value '' -Prompt 'TEP IP pool range start' `
            -Validator { param($v) Test-IPAddress $v } `
            -InvalidMessage 'Must be a valid IPv4 address.'
        $tepEnd     = Get-OrPrompt -Value '' -Prompt 'TEP IP pool range end' `
            -Validator { param($v) Test-IPAddress $v } `
            -InvalidMessage 'Must be a valid IPv4 address.'
        $allTepPoolVarsSet = $true
    }
}

if ($allTepPoolVarsSet) {
    $nsxTepPoolSpec = @{
        name    = "$DomainName-tep-pool"
        subnets = @(
            @{
                cidr                = $tepCidr
                gateway             = $tepGateway
                ipAddressPoolRanges = @( @{ start = $tepStart; end = $tepEnd } )
            }
        )
    }
    Write-OK "TEP IP pool: $tepCidr  ($tepStart – $tepEnd, GW: $tepGateway)"
} else {
    Write-OK 'DHCP will be used for NSX TEP IP assignment.'
}

# ── ESXi license key ──────────────────────────────────────────────────────────
$esxiLicenseInput = Get-OrPrompt -Value $ESXiLicenseKey `
    -Prompt 'ESXi license key for all hosts (press Enter to skip)' `
    -Optional `
    -Validator { param($v) $v -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$' } `
    -InvalidMessage 'License key must be in XXXXX-XXXXX-XXXXX-XXXXX-XXXXX format (uppercase letters and digits).'
if ($esxiLicenseInput) { Write-OK "ESXi license key set." } else { Write-Warn 'No ESXi license key provided.' }
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 6: NSX configuration ─────────────────────────────────────────
Write-Header 'Step 6 of 8  |  NSX Configuration'

if ($NSXMode -and $NSXMode.Trim() -ne '') {
    $nsxMode = $NSXMode.Trim().ToLower()
} else {
    Write-Host ''
    Write-Host '  NSX deployment options:' -ForegroundColor White
    Write-Host '  [1] Deploy new NSX Manager'
    Write-Host '  [2] Join existing NSX Manager'
    Write-Host ''
    $nsxModeChoice = ''
    while ($nsxModeChoice -notin @('1', '2')) {
        $nsxModeChoice = Read-Host -Prompt 'Select NSX option (1 or 2)'
        if ($nsxModeChoice -notin @('1', '2')) { Write-Warn 'Please enter 1 or 2.' }
    }
    $nsxMode = if ($nsxModeChoice -eq '1') { 'new' } else { 'existing' }
}

$nsxSpec = $null

if ($nsxMode -eq 'new') {
    # ── New NSX Manager ───────────────────────────────────────────────────────
    $nsxNodeCount = 0
    while ($nsxNodeCount -notin @(1, 3)) {
        $nsxNodeCountStr = Read-Host -Prompt 'Number of NSX Manager nodes (1 or 3)'
        $nsxNodeCount    = [int]$nsxNodeCountStr
        if ($nsxNodeCount -notin @(1, 3)) { Write-Warn 'Please enter 1 or 3.' }
    }

    $NSXManagerVIP   = Get-OrPrompt -Value $NSXManagerVIP   -Prompt 'NSX Manager VIP FQDN' `
        -Validator { param($v) Test-FQDN $v } `
        -InvalidMessage 'Must be a valid FQDN (e.g. nsx-wld01-vip.vcf.lab).'
    $NSXManager1FQDN = Get-OrPrompt -Value $NSXManager1FQDN -Prompt 'NSX Manager node 1 FQDN' `
        -Validator { param($v) Test-FQDN $v } `
        -InvalidMessage 'Must be a valid FQDN (e.g. nsx-wld01-m1.vcf.lab).'
    $nsxNodes        = @($NSXManager1FQDN)

    if ($nsxNodeCount -eq 3) {
        $NSXManager2FQDN = Get-OrPrompt -Value $NSXManager2FQDN -Prompt 'NSX Manager node 2 FQDN' `
            -Validator { param($v) Test-FQDN $v } `
            -InvalidMessage 'Must be a valid FQDN (e.g. nsx-wld01-m2.vcf.lab).'
        $NSXManager3FQDN = Get-OrPrompt -Value $NSXManager3FQDN -Prompt 'NSX Manager node 3 FQDN' `
            -Validator { param($v) Test-FQDN $v } `
            -InvalidMessage 'Must be a valid FQDN (e.g. nsx-wld01-m3.vcf.lab).'
        $nsxNodes += @($NSXManager2FQDN, $NSXManager3FQDN)
    }

    $NSXAdminPassword = Get-OrPrompt -Value $NSXAdminPassword -Prompt 'NSX admin password' -Secure `
        -Validator { param($v) Test-Password $v } `
        -InvalidMessage 'Password must be at least 8 characters.'
    $NSXAuditPassword = Get-OrPrompt -Value $NSXAuditPassword -Prompt 'NSX audit password' -Secure `
        -Validator { param($v) Test-Password $v } `
        -InvalidMessage 'Password must be at least 8 characters.'
    $NSXRootPassword  = Get-OrPrompt -Value $NSXRootPassword  -Prompt 'NSX root password'  -Secure `
        -Validator { param($v) Test-Password $v } `
        -InvalidMessage 'Password must be at least 8 characters.'
    $nsxLicenseInput  = Get-OrPrompt -Value $NSXLicenseKey    -Prompt 'NSX license key (press Enter to skip)' `
        -Optional `
        -Validator { param($v) $v -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$' } `
        -InvalidMessage 'License key must be in XXXXX-XXXXX-XXXXX-XXXXX-XXXXX format (uppercase letters and digits).'

    $nsxManagerSpecs = @()
    foreach ($nodeFqdn in $nsxNodes) {
        $nsxManagerSpecs += @{
            name           = ($nodeFqdn -split '\.')[0]
            networkDetails = @{ fqdn = $nodeFqdn }
        }
    }

    $nsxSpec = @{
        nsxManagerSpecs         = $nsxManagerSpecs
        vip                     = $NSXManagerVIP
        vipFqdn                 = $NSXManagerVIP
        nsxManagerAdminPassword = $NSXAdminPassword
        nsxManagerAuditPassword = $NSXAuditPassword
        nsxManagerRootPassword  = $NSXRootPassword
    }
    if ($nsxLicenseInput -and $nsxLicenseInput.Trim() -ne '') {
        $nsxSpec['licenseKey'] = $nsxLicenseInput
    }
    Write-OK "New NSX Manager configured ($nsxNodeCount node(s), VIP: $NSXManagerVIP)."

} else {
    # ── Join existing NSX Manager ─────────────────────────────────────────────
    if ($MockMode) {
        Write-Mock 'Using mock NSX instance list.'
        $nsxList = $MockNSXInstances
    } else {
        Write-Step 'Querying existing NSX Manager instances from SDDC Manager ...'
        try {
            $nsxInstances = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/nsxt-clusters'
            $nsxList      = $nsxInstances.elements
        } catch {
            Write-Fail "Failed to retrieve NSX instances: $_"
            exit 1
        }
        if (-not $nsxList -or $nsxList.Count -eq 0) {
            Write-Fail 'No existing NSX Manager instances found in SDDC Manager.'
            exit 1
        }
    }

    Write-Host ''
    Write-Host '  Existing NSX Manager instances:' -ForegroundColor White
    $i = 1
    foreach ($nsx in $nsxList) {
        Write-Host ("  [{0}] {1}  |  VIP: {2}  |  Version: {3}" -f `
            $i, $nsx.vipFqdn, $nsx.vip, $nsx.nsxtManagerVersion)
        $i++
    }
    Write-Host ''

    $nsxIdx = [int](Read-Host -Prompt 'Select NSX instance to join') - 1
    if ($nsxIdx -lt 0 -or $nsxIdx -ge $nsxList.Count) {
        Write-Fail 'Invalid NSX selection.'
        exit 1
    }
    $selectedNSX = $nsxList[$nsxIdx]

    $nsxSpec = @{
        nsxManagerRef = @{ id = $selectedNSX.id }
    }
    Write-OK "Will join existing NSX Manager: $($selectedNSX.vipFqdn) (ID: $($selectedNSX.id))."
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 7: Network pool ───────────────────────────────────────────────
Write-Header 'Step 7 of 8  |  Network Pool'

if ($MockMode) {
    Write-Mock 'Using mock network pool list.'
    $poolList = $MockPools
} else {
    Write-Step 'Querying network pools ...'
    try {
        $pools    = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/network-pools'
        $poolList = $pools.elements
    } catch {
        Write-Fail "Failed to retrieve network pools: $_"
        exit 1
    }
    if (-not $poolList -or $poolList.Count -eq 0) {
        Write-Fail 'No network pools found in SDDC Manager.'
        exit 1
    }
}

Write-Host ''
Write-Host '  Available network pools:' -ForegroundColor White
$i = 1
foreach ($p in $poolList) {
    Write-Host "  [$i] $($p.name)  (ID: $($p.id))"
    $i++
}
Write-Host ''

$selectedPool = $null
if ($NetworkPoolName -and $NetworkPoolName.Trim() -ne '') {
    $selectedPool = $poolList | Where-Object { $_.name -eq $NetworkPoolName } | Select-Object -First 1
    if (-not $selectedPool) {
        Write-Warn "Pre-filled pool name '$NetworkPoolName' not found. Please select manually."
    }
}

if (-not $selectedPool) {
    $poolIdx = [int](Read-Host -Prompt 'Select network pool number') - 1
    if ($poolIdx -lt 0 -or $poolIdx -ge $poolList.Count) {
        Write-Fail 'Invalid pool selection.'
        exit 1
    }
    $selectedPool = $poolList[$poolIdx]
}

Write-OK "Network pool selected: $($selectedPool.name) (ID: $($selectedPool.id))"
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 8: Build JSON payload ────────────────────────────────────────
Write-Header 'Step 8 of 8  |  Building JSON Payload'

# ── Host specs ────────────────────────────────────────────────────────────────
$esxiKey   = if ($esxiLicenseInput -and $esxiLicenseInput.Trim() -ne '') { $esxiLicenseInput.Trim() } else { $null }
$hostSpecs = @()
foreach ($h in $selectedHosts) {
    # Map each physical NIC to an uplink, cycling through the uplink list
    $nicIds  = @('vmnic0', 'vmnic1')
    $vmNics  = for ($j = 0; $j -lt $nicIds.Count; $j++) {
        @{ id = $nicIds[$j]; vdsName = $vdsName; uplink = $uplinkNames[$j % $uplinkNames.Count] }
    }
    $hostSpecs += @{
        id              = $h.id
        licenseKey      = $esxiKey
        hostNetworkSpec = @{ vmNics = $vmNics }
    }
}

# ── vSAN / datastore spec ─────────────────────────────────────────────────────
if ($storageType -eq 'ESA') {
    $vsanSpec = @{
        esaConfig            = @{ enabled = $true }
        failuresToTolerate   = 1
        datastoreName        = "$DomainName-vSAN-DS"
    }
} else {
    $vsanSpec = @{
        failuresToTolerate   = 1
        datastoreName        = "$DomainName-vSAN-DS"
    }
}

# ── NSX cluster spec (TEP VLAN + optional static IP pool) ────────────────────
$nsxClusterSpec = @{ geneveVlanId = $nsxTepVlan }
if ($nsxTepPoolSpec) {
    $nsxClusterSpec['ipAddressPoolsSpec'] = @($nsxTepPoolSpec)
}

# ── Full payload ──────────────────────────────────────────────────────────────
$payload = @{
    domainName  = $DomainName
    vcenterSpec = @{
        name               = $vCenterName
        networkDetailsSpec = @{
            dnsName    = $vCenterFQDN
            ipAddress  = $vcenterIP
            gateway    = $vcenterGateway
            subnetMask = $vcenterSubnetMask
        }
        rootPassword       = $vCenterRootPass
        adminPassword      = $vCenterAdminPass
        datacenterName     = $vCenterDatacenter
        vmSize             = $vcSize
    }
    computeSpec = @{
        clusterSpecs = @(
            @{
                name        = $vCenterCluster
                hostSpecs   = $hostSpecs
                vsanSpec    = $vsanSpec
                networkSpec = @{
                    vdsSpecs = @(
                        @{
                            name           = $vdsName
                            mtu            = $vdsMtu
                            portGroupSpecs = @(
                                @{
                                    name          = "$DomainName-vMotion-pg"
                                    transportType = 'VMOTION'
                                    vlanId        = $vMotionVlan
                                    activeUplinks = $uplinkNames
                                }
                                @{
                                    name          = "$DomainName-vSAN-pg"
                                    transportType = 'VSAN'
                                    vlanId        = $vsanVlan
                                    activeUplinks = $uplinkNames
                                }
                                @{
                                    name          = "$DomainName-NSX-TEP-pg"
                                    transportType = 'NSX'
                                    activeUplinks = $uplinkNames
                                }
                            )
                        }
                    )
                    nsxClusterSpec = $nsxClusterSpec
                }
            }
        )
    }
    nsxSpec         = $nsxSpec
    networkPoolName = $selectedPool.name
}

$jsonOutput = $payload | ConvertTo-Json -Depth 20
Write-OK 'JSON payload built successfully.'
#endregion ───────────────────────────────────────────────────────────────────

#region ── Validate ───────────────────────────────────────────────────────────
Write-Header 'Validation  |  SDDC Manager API'

if ($MockMode) {
    Write-Mock 'Skipping live validation. Returning mock SUCCEEDED result.'
    Write-Host ''
    Write-OK 'Validation PASSED (mock). Domain JSON is ready for review.'
} else {
    Write-Step 'Submitting validation request to /v1/domains/validations ...'
    $validationResp = $null
    try {
        $validationResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token `
            -Method POST -Path '/v1/domains/validations' -Body $payload
    } catch {
        Write-Fail "Validation request failed: $_"
    }

    if ($validationResp) {
        $validationId = $validationResp.id
        Write-OK "Validation submitted. ID: $validationId"
        Write-Step 'Polling for validation result ...'

        $maxWait     = 300
        $interval    = 10
        $elapsed     = 0
        $finalStatus = $null
        $poll        = $null

        while ($elapsed -lt $maxWait) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            try {
                $poll        = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token `
                    -Path "/v1/domains/validations/$validationId"
                $finalStatus = $poll.executionStatus
                Write-Host "    Elapsed: ${elapsed}s  |  Status: $finalStatus" -ForegroundColor DarkGray
                if ($finalStatus -in @('COMPLETED', 'FAILED')) { break }
            } catch {
                Write-Warn "Poll attempt failed: $_"
            }
        }

        Write-Host ''
        if ($finalStatus -eq 'COMPLETED') {
            if ($poll.resultStatus -eq 'SUCCEEDED') {
                Write-OK 'Validation PASSED. Domain JSON is ready for deployment.'
            } else {
                Write-Fail "Validation FAILED (resultStatus: $($poll.resultStatus))"
                if ($poll.validationChecks) {
                    Write-Host ''
                    Write-Host '  Validation errors:' -ForegroundColor Red
                    foreach ($check in $poll.validationChecks) {
                        if ($check.resultStatus -ne 'SUCCEEDED') {
                            Write-Host ("    [{0}] {1} - {2}" -f `
                                $check.resultStatus, $check.description, $check.errorMessage) -ForegroundColor Red
                        }
                    }
                }
            }
        } elseif ($finalStatus -eq 'FAILED') {
            Write-Fail 'Validation execution itself failed. Check SDDC Manager logs.'
        } else {
            Write-Warn "Validation timed out after ${maxWait}s. Last status: $finalStatus"
        }
    }
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── Save JSON to file ─────────────────────────────────────────────────
Write-Header 'Output  |  Saving JSON'

if ($OutputJsonPath -and $OutputJsonPath.Trim() -ne '') {
    $parentDir = Split-Path -Parent $OutputJsonPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        Write-Warn "Output directory '$parentDir' does not exist. Falling back to script directory."
        $OutputJsonPath = ''
    }
}
if (-not $OutputJsonPath -or $OutputJsonPath.Trim() -eq '') {
    $ts             = Get-Date -Format 'yyyyMMdd-HHmmss'
    $scriptDir      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputJsonPath = Join-Path $scriptDir "$DomainName-workload-domain-$ts.json"
}

try {
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($OutputJsonPath, $jsonOutput, $utf8Bom)
    Write-OK "JSON saved to: $OutputJsonPath"
} catch {
    Write-Fail "Failed to save JSON: $_"
}
#endregion ───────────────────────────────────────────────────────────────────

Write-Host ''
if ($MockMode) {
    Write-Host '  Done. (mock mode - no changes were made to SDDC Manager)' -ForegroundColor DarkYellow
} else {
    Write-Host '  Done.' -ForegroundColor Cyan
}
Write-Host ''
