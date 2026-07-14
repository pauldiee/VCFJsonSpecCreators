<#
.SYNOPSIS
    Creates a Network Pool in SDDC Manager via the REST API and saves the JSON payload to disk.

.DESCRIPTION
    - Collects cluster name, SDDC Manager FQDN, MTU, VLAN IDs, and CIDR-based network configuration
    - Validates all inputs before proceeding; re-prompts on errors
    - Derives the pool name by prepending "NP-" to the cluster name (e.g. NP-cluster-mgmt-01a)
    - Checks whether a pool with the same name already exists in SDDC Manager
    - Builds and saves the JSON payload to .\NetworkPools\NP-<cluster-name>.json
    - Previews the payload and confirms before submitting
    - POSTs to /v1/network-pools and reports the resulting pool ID
    - Supports mock mode for offline/lab testing without live SDDC Manager

.NOTES
    Script  : New-VCFNetworkPool.ps1
    Version : 3.0.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-03-24

    Compatibility:
        VCF 5.0, 5.1, 5.2, VCF 9.0 and 9.1
        Windows PowerShell 5.1 and PowerShell 7.x

    Note: in VCF 9.1 the vMotion and vSAN VLANs and IP ranges live ONLY in the network pool.
    They were removed from the workload domain and cluster specs (portGroupSpecs carries no
    vlanId there), so the pool is the single source of truth for that addressing.

    VCF 9 note:
        The SDDC Manager UI no longer exposes network pool management (moved to
        vCenter > Global Inventory List > Hosts > Network Pools), but the
        /v1/network-pools API endpoint remains fully supported.

    Changelog:
        1.0.0 - Initial release
        2.0.0 - Major rewrite: VCF 9 compatibility, SecureString credentials, TLS 1.2 enforcement,
                -SkipCertCheck switch, input validation, helper functions, relative output path
        2.1.0 - Added -SaveCredentials and -CredentialFile parameters
        2.2.0 - Fixed strict mode bug in Test-IPv4Address (.Count on pipeline result)
        2.3.0 - Fixed strict mode bugs in Invoke-VcfApi (missing Response property) and
                PSVersionTable.Platform check on Windows PowerShell 5.x
        2.4.0 - Fixed GET body bug in Invoke-VcfApi (empty string vs null body guard)
        2.5.0 - Changed pool name format to NP-<full-cluster-name>
        2.6.0 - Removed invalid logout calls; added -MockMode; added pre-filled variables block;
                aligned structure and banner with other VCF spec creator scripts
        2.7.0 - Relaxed subnet validation to accept any valid IPv4 address (not just x.x.x.0);
                last octet is now automatically normalized to 0 before use
        2.8.0 - Windows PowerShell 5.1 compatibility: replaced non-ASCII dashes (the file is
                BOM-less UTF-8, which 5.1 decodes as ANSI). This script already gated
                -SkipCertificateCheck correctly; no cert changes needed.
        3.0.0 - Networks are now defined by CIDR, not a bare subnet address. Previously the mask
                was hardcoded to 255.255.255.0 and the gateway/range were derived arithmetically
                as x.y.z.1 / x.y.z.10 / x.y.z.254 - i.e. a /24 was assumed and the pool range was
                not configurable. On a /25 that produced a wrong mask AND an end address outside
                the subnet (.254 does not exist in a /25). A real VCF 9.1 pool observed in the
                field is a /25 with a deliberate 21-address window (10.2.3.101-121), which the
                old code could not express at all.
                  * input is now a CIDR (any prefix /1 to /30), e.g. 10.2.3.0/25
                  * mask, network address and usable range are computed from the prefix
                  * gateway defaults to the first usable address and is overridable
                  * pool start/end are prompted (with derived defaults) and validated to fall
                    inside the subnet, excluding the network and broadcast addresses
                  * BREAKING: the $VSanSubnet / $VMotionSubnet pre-filled variables are replaced
                    by $VSanCidr / $VMotionCidr (plus optional gateway and pool-range variables)

.PARAMETER MockMode
    Run in mock mode: skips all SDDC Manager API calls and uses built-in stub data.
    Can also be enabled by setting $MockModeVar = $true in the variables block below.

.PARAMETER SkipCertCheck
    Bypass SSL/TLS certificate validation. For lab environments with self-signed certificates.
    On PowerShell 5.x sets a global CertificatePolicy callback.
    On PowerShell 7 passes -SkipCertificateCheck per request.
    NOT recommended for production use.

.PARAMETER SaveCredentials
    After prompting for credentials via Get-Credential, encrypt and save them to disk.
    Default save path: <script dir>\SavedCredentials\vcf-creds.xml.
    Cannot be used together with -CredentialFile.

.PARAMETER CredentialFile
    Path to an encrypted credential file previously created with -SaveCredentials.
    Skips the interactive Get-Credential prompt.
    Cannot be used together with -SaveCredentials.

.EXAMPLE
    .\New-VCFNetworkPool.ps1

    Interactive mode with full certificate validation.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -MockMode

    Offline testing with built-in stub data; no SDDC Manager required.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SkipCertCheck

    Certificate validation disabled; for lab environments.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SkipCertCheck -SaveCredentials

    Prompts for credentials and saves them encrypted for future use.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SkipCertCheck -CredentialFile '.\SavedCredentials\vcf-creds.xml'

    Loads saved credentials; no interactive credential prompt.
#>

[CmdletBinding()]
param(
    [switch]$MockMode,
    [switch]$SkipCertCheck,
    [switch]$SaveCredentials,
    [string]$CredentialFile = ''
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "New-VCFNetworkPool.ps1"
    Version = "3.0.0"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-03-24"
}

#endregion

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Parameter guards ---

if ($SaveCredentials -and $CredentialFile) {
    Write-Error '-SaveCredentials and -CredentialFile cannot be used together. Use -SaveCredentials to create the file, then -CredentialFile to load it on subsequent runs.'
    exit 1
}
if ($MockMode -and ($SaveCredentials -or $CredentialFile)) {
    Write-Warning '-SaveCredentials and -CredentialFile are ignored in mock mode.'
}

#endregion

#region --- Pre-filled variables (leave blank to be prompted) ---

$MockModeVar        = $false      # set to $true to enable mock mode without the -MockMode switch

$SDDCManagerFQDN    = ''          # e.g. sddc-manager.vcf.lab
$ClusterName        = ''          # e.g. cluster-mgmt-01a

$MTU                = ''          # leave blank to default to 9000
$VSanVlanId         = ''          # e.g. 1611
$VMotionVlanId      = ''          # e.g. 1612
$VSanCidr           = ''          # e.g. 172.16.11.0/24  - any prefix, not just /24
$VMotionCidr        = ''          # e.g. 172.16.12.0/25
# Gateway and pool range: leave blank to be prompted (defaults are derived from the CIDR).
$VSanGateway        = ''          # e.g. 172.16.11.1     (default: first usable address)
$VSanPoolStart      = ''          # e.g. 172.16.11.101
$VSanPoolEnd        = ''          # e.g. 172.16.11.121
$VMotionGateway     = ''          # e.g. 172.16.12.1
$VMotionPoolStart   = ''          # e.g. 172.16.12.101
$VMotionPoolEnd     = ''          # e.g. 172.16.12.121

$OutputJsonPath     = ''          # leave blank to auto-generate (.\NetworkPools\NP-<cluster-name>.json)

#endregion

# Resolve mock mode from either source
if ($MockModeVar) { $MockMode = [switch]$true }

#region --- Mock data ---

# An empty pool list means the duplicate-name check always passes in mock mode.
$MockPools = @()

#endregion

#region --- Helpers ---

function Set-TlsOptions {
    param([bool]$SkipCert)

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # Windows PowerShell 5.x
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if ($SkipCert) {
            if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
                Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint svcPoint, X509Certificate cert,
        WebRequest req, int certProblem) { return true; }
}
"@
            }
            [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            Write-Warning 'Certificate validation is DISABLED. Use in lab environments only.'
        }
    }
    # PS 7: TLS 1.2/1.3 is default; -SkipCertificateCheck is passed per-call
}

function Invoke-VcfApi {
    param(
        [string]    $Method,
        [string]    $Uri,
        [hashtable] $Headers,
        [string]    $Body        = $null,
        [string]    $ContentType = 'application/json',
        [bool]      $SkipCert   = $false
    )

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = $ContentType
    }
    if (-not [string]::IsNullOrEmpty($Body)) { $params['Body'] = $Body }

    # PS 7+ supports -SkipCertificateCheck natively
    if ($SkipCert -and $PSVersionTable.PSEdition -eq 'Core') {
        $params['SkipCertificateCheck'] = $true
    }

    try {
        Invoke-RestMethod @params
    }
    catch {
        # Strict mode throws when accessing a missing property even inside a
        # $null check, so we test for the property's existence first.
        $statusCode = $null
        $response   = $null
        if ($_.Exception | Get-Member -Name 'Response' -MemberType Properties -ErrorAction SilentlyContinue) {
            $response = $_.Exception.Response
        }
        if ($null -ne $response -and ($response | Get-Member -Name 'StatusCode' -MemberType Properties -ErrorAction SilentlyContinue)) {
            $statusCode = [int]$response.StatusCode
        }
        $msg = if ($statusCode) { "HTTP $statusCode" } else { 'No HTTP response' }
        Write-Error "API call failed [$Method $Uri] - $msg`n$($_.Exception.Message)"
        throw
    }
}

function Confirm-CreatePool {
    param([string]$PoolName, [string]$ManagerFqdn)
    $choices = [System.Management.Automation.Host.ChoiceDescription[]] @('&Yes', '&No')
    $answer  = $host.UI.PromptForChoice(
        'Confirm Creation',
        "Create network pool '$PoolName' on '$ManagerFqdn'?",
        $choices, 0
    )
    return ($answer -eq 0)
}

function Test-IPv4Address {
    param([string]$Address)
    if ($Address -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    return (@($Address.Split('.') | ForEach-Object { [int]$_ } | Where-Object { $_ -lt 0 -or $_ -gt 255 })).Count -eq 0
}

function Test-SubnetFormat {
    param([string]$Subnet)
    return (Test-IPv4Address -Address $Subnet)
}

function Test-CidrFormat {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') { return $false }
    if (-not (Test-IPv4Address -Address $Matches[1])) { return $false }
    $prefix = [int]$Matches[2]
    # /31 and /32 leave no usable host range for a pool.
    return ($prefix -ge 1 -and $prefix -le 30)
}

function ConvertTo-UInt32Ip {
    param([string]$Address)
    $o = $Address.Split('.') | ForEach-Object { [uint32]$_ }
    return ([uint32]$o[0] -shl 24) -bor ([uint32]$o[1] -shl 16) -bor ([uint32]$o[2] -shl 8) -bor [uint32]$o[3]
}

function ConvertFrom-UInt32Ip {
    param([uint32]$Value)
    return '{0}.{1}.{2}.{3}' -f `
        (($Value -shr 24) -band 255), (($Value -shr 16) -band 255),
        (($Value -shr 8)  -band 255), ($Value -band 255)
}

# Derives everything a network pool needs from a CIDR, for ANY prefix length.
# The previous version hardcoded a /24 (mask 255.255.255.0, range .10-.254), which
# silently produced an invalid pool on, say, a /25 - .254 does not exist in one.
function Get-CidrInfo {
    param([string]$Cidr)

    $parts   = $Cidr.Split('/')
    $prefix  = [int]$parts[1]
    $ipVal   = ConvertTo-UInt32Ip $parts[0]

    # Mask as a uint32. Guard the shift: 32 - 0 would be an undefined shift width.
    $maskVal = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }

    $network   = $ipVal -band $maskVal
    $broadcast = $network -bor (-bnot $maskVal)

    return @{
        Prefix      = $prefix
        Network     = ConvertFrom-UInt32Ip $network
        Mask        = ConvertFrom-UInt32Ip $maskVal
        Broadcast   = ConvertFrom-UInt32Ip $broadcast
        FirstUsable = ConvertFrom-UInt32Ip ($network + 1)
        LastUsable  = ConvertFrom-UInt32Ip ($broadcast - 1)
        NetworkVal  = $network
        BroadcastVal= $broadcast
    }
}

# True when Address is a usable host address inside Cidr (excludes network + broadcast).
function Test-IpInCidr {
    param([string]$Address, [string]$Cidr)
    if (-not (Test-IPv4Address -Address $Address)) { return $false }
    $info = Get-CidrInfo -Cidr $Cidr
    $val  = ConvertTo-UInt32Ip $Address
    return ($val -gt $info.NetworkVal -and $val -lt $info.BroadcastVal)
}

function Test-VlanId {
    param([int]$VlanId)
    return ($VlanId -ge 0 -and $VlanId -le 4094)
}

function Test-MtuValue {
    param([string]$Value)
    if ($Value -notmatch '^\d+$') { return $false }
    $m = [int]$Value
    return ($m -ge 1280 -and $m -le 9216)
}

# The cluster name becomes the pool name (NP-<name>) AND part of the output file path
# (.\NetworkPools\NP-<name>.json), so path separators and whitespace must be rejected.
function Test-ClusterNameFormat {
    param([string]$Value)
    return [bool]($Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')
}

function Test-FqdnFormat {
    param([string]$Value)
    return [bool]($Value -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$')
}

# True when two CIDRs overlap at all (either contains the other's network address).
function Test-CidrOverlap {
    param([string]$CidrA, [string]$CidrB)
    $a = Get-CidrInfo -Cidr $CidrA
    $b = Get-CidrInfo -Cidr $CidrB
    return -not ($a.BroadcastVal -lt $b.NetworkVal -or $b.BroadcastVal -lt $a.NetworkVal)
}

function Read-RequiredHost {
    param([string]$Prompt)
    do {
        $value = (Read-Host $Prompt).Trim()
        if (-not $value) { Write-Warning 'Value cannot be empty.' }
    } until ($value)
    return $value
}

function Get-BaseDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Get-VcfCredential {
    param(
        [string]$ManagerFqdn,
        [string]$CredentialFile,
        [bool]  $SaveCredentials,
        [string]$BaseDir
    )

    # --- Load from file ---
    if ($CredentialFile) {
        if (-not (Test-Path $CredentialFile)) {
            Write-Error "Credential file not found: $CredentialFile"
            exit 1
        }
        try {
            $cred = Import-Clixml -Path $CredentialFile
            if ($cred -isnot [System.Management.Automation.PSCredential]) {
                Write-Error "File '$CredentialFile' does not contain a valid PSCredential object."
                exit 1
            }
            Write-Host "  Credentials loaded from: $CredentialFile" -ForegroundColor Green
            return $cred
        }
        catch {
            Write-Error "Failed to load credentials from '$CredentialFile': $($_.Exception.Message)"
            exit 1
        }
    }

    # --- Prompt interactively ---
    $cred = Get-Credential -Message "Enter SDDC Manager credentials for $ManagerFqdn`nUsername must include domain in UPN format, e.g. administrator@vsphere.local or admin@local"

    # --- Optionally save ---
    if ($SaveCredentials) {
        $saveDir  = Join-Path $BaseDir 'SavedCredentials'
        $savePath = Join-Path $saveDir 'vcf-creds.xml'

        if (-not (Test-Path $saveDir)) {
            New-Item -ItemType Directory -Path $saveDir | Out-Null
        }

        try {
            $cred | Export-Clixml -Path $savePath -Force
            Write-Host "  Credentials saved to : $savePath" -ForegroundColor Green
            Write-Host "  Load them next time  : .\New-VCFNetworkPool.ps1 -CredentialFile '$savePath'" -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Could not save credentials: $($_.Exception.Message). Continuing without saving."
        }
    }

    return $cred
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
    Write-Host "  Auth, duplicate check, and pool creation are skipped" -ForegroundColor DarkGray
    Write-Host ""
}

#endregion

#region --- TLS setup ---

if (-not $MockMode) {
    Set-TlsOptions -SkipCert $SkipCertCheck.IsPresent
    if ($SkipCertCheck) {
        Write-Host "  [!] Certificate validation DISABLED - lab use only" -ForegroundColor Yellow
        Write-Host ""
    }
}

#endregion

$baseDir = Get-BaseDir

#region --- Step 1: Input collection ---

Write-Host ("`n  [Step 1 of 4  --  Configuration Input]") -ForegroundColor Cyan

# Cluster name - becomes the pool name (NP-<name>) and part of the output file path,
# so reject anything with whitespace or path separators in it.
if ($ClusterName -and (Test-ClusterNameFormat $ClusterName.Trim())) {
    $clusterName = $ClusterName.Trim()
    Write-Host "  Cluster name      : $clusterName" -ForegroundColor DarkGray
} else {
    if ($ClusterName -and $ClusterName.Trim()) {
        Write-Warning "Pre-filled ClusterName '$ClusterName' is invalid."
    }
    do {
        $clusterName = (Read-Host '  Cluster name (e.g. cluster-mgmt-01a)').Trim()
        $ok = Test-ClusterNameFormat $clusterName
        if (-not $ok) {
            Write-Warning 'Cluster name must start with a letter or digit and contain only letters, digits, dots, hyphens or underscores (no spaces or slashes).'
        }
    } until ($ok)
}

# SDDC Manager FQDN
if ($SDDCManagerFQDN -and (Test-FqdnFormat $SDDCManagerFQDN.Trim())) {
    $sddcManagerFqdn = $SDDCManagerFQDN.Trim()
    Write-Host "  SDDC Manager FQDN : $sddcManagerFqdn" -ForegroundColor DarkGray
} elseif ($MockMode) {
    $sddcManagerFqdn = 'sddc-manager.vcf.lab'
    Write-Host "  [MOCK] SDDC Manager FQDN: $sddcManagerFqdn" -ForegroundColor DarkYellow
} else {
    if ($SDDCManagerFQDN -and $SDDCManagerFQDN.Trim()) {
        Write-Warning "Pre-filled SDDCManagerFQDN '$SDDCManagerFQDN' is not a valid FQDN."
    }
    do {
        $sddcManagerFqdn = (Read-Host '  SDDC Manager FQDN (e.g. sddc-manager.vcf.lab)').Trim()
        $ok = Test-FqdnFormat $sddcManagerFqdn
        if (-not $ok) { Write-Warning 'Must be a valid FQDN (e.g. sddc-manager.vcf.lab).' }
    } until ($ok)
}

# Credentials (load from file, prompt, or prompt-and-save) - skipped in mock mode
if (-not $MockMode) {
    $cred = Get-VcfCredential `
        -ManagerFqdn     $sddcManagerFqdn `
        -CredentialFile  $CredentialFile `
        -SaveCredentials $SaveCredentials.IsPresent `
        -BaseDir         $baseDir
}

# MTU - must be numeric and in range. The old code cast the raw input with [int] before
# checking it was a number at all, so a typo like "90o0" threw instead of re-prompting,
# and an out-of-range value only warned and carried on.
if ($MTU -and (Test-MtuValue $MTU.Trim())) {
    [int]$mtu = [int]$MTU.Trim()
    Write-Host "  MTU               : $mtu" -ForegroundColor DarkGray
} else {
    if ($MTU -and $MTU.Trim()) {
        Write-Warning "Pre-filled MTU '$MTU' is invalid (must be an integer between 1280 and 9216)."
    }
    do {
        $mtuInput = (Read-Host '  MTU [9000] (press Enter to accept)').Trim()
        if (-not $mtuInput) { $mtuInput = '9000' }
        $ok = Test-MtuValue $mtuInput
        if (-not $ok) { Write-Warning 'MTU must be an integer between 1280 and 9216.' }
    } until ($ok)
    [int]$mtu = [int]$mtuInput
}

# Collects VLAN + CIDR + gateway + pool range for one network, deriving sensible
# defaults from the CIDR and validating that every address lands inside the subnet.
function Read-NetworkConfig {
    param(
        [string]$Label,           # 'vSAN' / 'vMotion'
        [string]$ExampleCidr,
        [string]$PrefillVlan,
        [string]$PrefillCidr,
        [string]$PrefillGateway,
        [string]$PrefillStart,
        [string]$PrefillEnd
    )

    Write-Host ""
    Write-Host "  -- $Label network --" -ForegroundColor White

    # VLAN
    $vlan = $null
    if ($PrefillVlan -and $PrefillVlan.Trim() -match '^\d+$' -and (Test-VlanId ([int]$PrefillVlan.Trim()))) {
        $vlan = [int]$PrefillVlan.Trim()
        Write-Host "  $Label VLAN ID: $vlan (pre-filled)" -ForegroundColor DarkGray
    } else {
        do {
            $in = (Read-Host "  $Label VLAN ID (0-4094)").Trim()
            $ok = ($in -match '^\d+$') -and (Test-VlanId ([int]$in))
            if (-not $ok) { Write-Warning "VLAN ID must be a number between 0 and 4094." }
        } until ($ok)
        $vlan = [int]$in
    }

    # CIDR
    $cidr = $null
    if ($PrefillCidr -and (Test-CidrFormat $PrefillCidr.Trim())) {
        $cidr = $PrefillCidr.Trim()
        Write-Host "  $Label CIDR: $cidr (pre-filled)" -ForegroundColor DarkGray
    } else {
        do {
            $in = (Read-Host "  $Label CIDR (e.g. $ExampleCidr)").Trim()
            $ok = Test-CidrFormat $in
            if (-not $ok) { Write-Warning "Must be a valid CIDR with a prefix between /1 and /30 (e.g. $ExampleCidr)." }
        } until ($ok)
        $cidr = $in
    }

    $info = Get-CidrInfo -Cidr $cidr
    Write-Host ("  -> network {0}  mask {1}  usable {2} - {3}" -f `
        $info.Network, $info.Mask, $info.FirstUsable, $info.LastUsable) -ForegroundColor DarkGray

    # Gateway - defaults to the first usable address
    $gw = $null
    if ($PrefillGateway -and (Test-IpInCidr $PrefillGateway.Trim() $cidr)) {
        $gw = $PrefillGateway.Trim()
    } else {
        do {
            $in = (Read-Host ("  $Label gateway (Enter for {0})" -f $info.FirstUsable)).Trim()
            if (-not $in) { $in = $info.FirstUsable }
            $ok = Test-IpInCidr $in $cidr
            if (-not $ok) { Write-Warning "Gateway must be a usable address inside $cidr." }
        } until ($ok)
        $gw = $in
    }

    # Pool range - defaults to everything after the gateway, up to the last usable address
    $defStart = ConvertFrom-UInt32Ip ((ConvertTo-UInt32Ip $gw) + 1)
    $defEnd   = $info.LastUsable

    $start = $null; $end = $null
    $prefillRangeOk = $PrefillStart -and $PrefillEnd -and
                      (Test-IpInCidr $PrefillStart.Trim() $cidr) -and
                      (Test-IpInCidr $PrefillEnd.Trim() $cidr) -and
                      ((ConvertTo-UInt32Ip $PrefillStart.Trim()) -le (ConvertTo-UInt32Ip $PrefillEnd.Trim())) -and
                      -not ((ConvertTo-UInt32Ip $gw) -ge (ConvertTo-UInt32Ip $PrefillStart.Trim()) -and
                            (ConvertTo-UInt32Ip $gw) -le (ConvertTo-UInt32Ip $PrefillEnd.Trim()))
    if ($prefillRangeOk) {
        $start = $PrefillStart.Trim(); $end = $PrefillEnd.Trim()
    } else {
        do {
            $errs = @()
            $sIn = (Read-Host "  $Label pool start (Enter for $defStart)").Trim()
            if (-not $sIn) { $sIn = $defStart }
            $eIn = (Read-Host "  $Label pool end   (Enter for $defEnd)").Trim()
            if (-not $eIn) { $eIn = $defEnd }

            if (-not (Test-IpInCidr $sIn $cidr)) { $errs += "Pool start '$sIn' is not a usable address inside $cidr." }
            if (-not (Test-IpInCidr $eIn $cidr)) { $errs += "Pool end '$eIn' is not a usable address inside $cidr." }
            if ($errs.Count -eq 0) {
                $sVal = ConvertTo-UInt32Ip $sIn
                $eVal = ConvertTo-UInt32Ip $eIn
                $gVal = ConvertTo-UInt32Ip $gw
                if ($sVal -gt $eVal) {
                    $errs += "Pool start '$sIn' is after pool end '$eIn'."
                }
                # The gateway must not be handed out to a host.
                elseif ($gVal -ge $sVal -and $gVal -le $eVal) {
                    $errs += "Pool range $sIn - $eIn contains the gateway $gw. Exclude the gateway from the pool."
                }
            }
            $errs | ForEach-Object { Write-Warning $_ }
        } until ($errs.Count -eq 0)
        $start = $sIn; $end = $eIn
    }

    return @{
        VlanId  = $vlan
        Subnet  = $info.Network
        Mask    = $info.Mask
        Gateway = $gw
        Start   = $start
        End     = $end
        Cidr    = $cidr
    }
}

$vsanNet = Read-NetworkConfig -Label 'vSAN' -ExampleCidr '172.16.11.0/24' `
    -PrefillVlan $VSanVlanId -PrefillCidr $VSanCidr -PrefillGateway $VSanGateway `
    -PrefillStart $VSanPoolStart -PrefillEnd $VSanPoolEnd

$vmotionNet = Read-NetworkConfig -Label 'vMotion' -ExampleCidr '172.16.12.0/25' `
    -PrefillVlan $VMotionVlanId -PrefillCidr $VMotionCidr -PrefillGateway $VMotionGateway `
    -PrefillStart $VMotionPoolStart -PrefillEnd $VMotionPoolEnd

# Cross-network sanity: the two networks must be genuinely distinct. Neither of these is
# catchable inside Read-NetworkConfig, which only ever sees one network at a time.
$crossErrors = @()
if ($vsanNet.VlanId -eq $vmotionNet.VlanId) {
    $crossErrors += "vSAN and vMotion are both on VLAN $($vsanNet.VlanId). They must use different VLANs."
}
if (Test-CidrOverlap $vsanNet.Cidr $vmotionNet.Cidr) {
    $crossErrors += "vSAN ($($vsanNet.Cidr)) and vMotion ($($vmotionNet.Cidr)) overlap. They must be separate subnets."
}
if ($crossErrors.Count -gt 0) {
    Write-Host ""
    $crossErrors | ForEach-Object { Write-Warning $_ }
    Write-Host ""
    Write-Host "  Re-run the script with corrected values." -ForegroundColor Red
    exit 1
}

# Derive pool name
$networkPoolName = "NP-$clusterName"

Write-Host ""
Write-Host "  Network pool name : $networkPoolName"   -ForegroundColor Yellow
Write-Host "  SDDC Manager      : $sddcManagerFqdn"   -ForegroundColor Yellow
Write-Host "  MTU               : $mtu"               -ForegroundColor Yellow
Write-Host ("  vSAN              : VLAN {0}  {1}  mask {2}  gw {3}  pool {4} - {5}" -f `
    $vsanNet.VlanId, $vsanNet.Subnet, $vsanNet.Mask, $vsanNet.Gateway, $vsanNet.Start, $vsanNet.End) -ForegroundColor Yellow
Write-Host ("  vMotion           : VLAN {0}  {1}  mask {2}  gw {3}  pool {4} - {5}" -f `
    $vmotionNet.VlanId, $vmotionNet.Subnet, $vmotionNet.Mask, $vmotionNet.Gateway, $vmotionNet.Start, $vmotionNet.End) -ForegroundColor Yellow
Write-Host ""

#endregion

#region --- Step 2: Authenticate and check for existing pool ---

Write-Host ("`n  [Step 2 of 4  --  SDDC Manager Check]") -ForegroundColor Cyan

if ($MockMode) {
    Write-Host "  [MOCK] Skipping authentication and duplicate-name check." -ForegroundColor DarkYellow
    $sessionHeader = @{}
    $allPools      = [PSCustomObject]@{ elements = $MockPools }
} else {
    $authUrl  = "https://$sddcManagerFqdn/v1/tokens"
    $authBody = [ordered]@{
        username = $cred.UserName
        password = $cred.GetNetworkCredential().Password
    } | ConvertTo-Json

    Write-Host "  Authenticating to SDDC Manager ..." -ForegroundColor Cyan
    $tokenResponse = Invoke-VcfApi -Method POST -Uri $authUrl -Headers @{} -Body $authBody -SkipCert $SkipCertCheck.IsPresent
    $sessionHeader = @{
        Authorization = "Bearer $($tokenResponse.accessToken)"
        Accept        = 'application/json'
    }
    Write-Host "  Authentication successful." -ForegroundColor Green

    Write-Host "  Checking for existing pool '$networkPoolName' ..." -ForegroundColor Cyan
    $allPools = Invoke-VcfApi -Method GET `
        -Uri      "https://$sddcManagerFqdn/v1/network-pools" `
        -Headers  $sessionHeader `
        -SkipCert $SkipCertCheck.IsPresent
}

$existingPool = @($allPools.elements | Where-Object { $_.name -eq $networkPoolName })
if ($existingPool) {
    Write-Warning "Network pool '$networkPoolName' already exists (ID: $($existingPool.id)). Exiting."
    exit 1
}

if ($MockMode) {
    Write-Host "  [MOCK] Pool '$networkPoolName' not found in stub data - proceeding." -ForegroundColor DarkYellow
} else {
    Write-Host "  Pool '$networkPoolName' not found - proceeding." -ForegroundColor Green
}

#endregion

#region --- Step 3: Build and save JSON ---

Write-Host ("`n  [Step 3 of 4  --  Build and Save JSON]") -ForegroundColor Cyan

$payload = [ordered]@{
    name     = $networkPoolName
    networks = @(
        [ordered]@{
            type    = 'VSAN'
            vlanId  = $vsanNet.VlanId
            mtu     = $mtu
            subnet  = $vsanNet.Subnet
            mask    = $vsanNet.Mask
            gateway = $vsanNet.Gateway
            ipPools = @(@{ start = $vsanNet.Start; end = $vsanNet.End })
        },
        [ordered]@{
            type    = 'VMOTION'
            vlanId  = $vmotionNet.VlanId
            mtu     = $mtu
            subnet  = $vmotionNet.Subnet
            mask    = $vmotionNet.Mask
            gateway = $vmotionNet.Gateway
            ipPools = @(@{ start = $vmotionNet.Start; end = $vmotionNet.End })
        }
    )
}

$jsonBody = $payload | ConvertTo-Json -Depth 10

# Resolve output path
if ($OutputJsonPath -and $OutputJsonPath.Trim()) {
    $jsonFile = $OutputJsonPath.Trim()
    $outputDir = Split-Path $jsonFile -Parent
} else {
    $outputDir = Join-Path $baseDir 'NetworkPools'
    $jsonFile  = Join-Path $outputDir "$networkPoolName.json"
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

[System.IO.File]::WriteAllText($jsonFile, $jsonBody, [System.Text.UTF8Encoding]::new($true))
Write-Host "  JSON saved to: $jsonFile" -ForegroundColor Green

# Show payload preview
Write-Host ""
Write-Host "  --- JSON Payload Preview ---" -ForegroundColor DarkGray
Write-Host $jsonBody
Write-Host "  ----------------------------" -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Step 4: Confirm and create ---

Write-Host ("`n  [Step 4 of 4  --  Confirm and Create]") -ForegroundColor Cyan

if (-not (Confirm-CreatePool -PoolName $networkPoolName -ManagerFqdn $sddcManagerFqdn)) {
    Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

if ($MockMode) {
    Write-Host ""
    Write-Host "  [MOCK] Skipping pool creation POST." -ForegroundColor DarkYellow
    Write-Host "  [MOCK] In a live run SDDC Manager would return a pool ID here." -ForegroundColor DarkYellow
} else {
    Write-Host "  Creating network pool '$networkPoolName' ..." -ForegroundColor Cyan
    $createResult = Invoke-VcfApi -Method POST `
        -Uri      "https://$sddcManagerFqdn/v1/network-pools" `
        -Headers  $sessionHeader `
        -Body     $jsonBody `
        -SkipCert $SkipCertCheck.IsPresent

    # The SDDC Manager API has no logout endpoint; the token expires automatically after 1 hour.
    Write-Host "  Note: session token expires automatically in 1 hour." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Network pool '$networkPoolName' created successfully!" -ForegroundColor Green
    Write-Host "  Pool ID : $($createResult.id)"                        -ForegroundColor Green
}

Write-Host ""
Write-Host "  NOTE (VCF 9): Network pools are also visible and manageable via:" -ForegroundColor DarkYellow
Write-Host "    vCenter > Global Inventory List > Hosts > Network Pools"        -ForegroundColor DarkYellow
Write-Host "    and through VCF Operations."                                     -ForegroundColor DarkYellow
Write-Host ""

#endregion
