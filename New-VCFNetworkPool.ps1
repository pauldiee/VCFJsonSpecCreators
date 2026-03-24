<#
.SYNOPSIS
    Creates a Network Pool in SDDC Manager via the REST API and saves the JSON payload to disk.

.DESCRIPTION
    - Collects cluster name, SDDC Manager FQDN, MTU, VLAN IDs, and subnet configuration
    - Validates all inputs before proceeding; re-prompts on errors
    - Derives the pool name by prepending "NP-" to the cluster name (e.g. NP-cluster-mgmt-01a)
    - Checks whether a pool with the same name already exists in SDDC Manager
    - Builds and saves the JSON payload to .\NetworkPools\NP-<cluster-name>.json
    - Previews the payload and confirms before submitting
    - POSTs to /v1/network-pools and reports the resulting pool ID
    - Supports mock mode for offline/lab testing without live SDDC Manager

.NOTES
    Script  : New-VCFNetworkPool.ps1
    Version : 2.7.0
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-03-24

    Compatibility:
        VCF 5.0, 5.1, 5.2, and VCF 9.0
        Windows PowerShell 5.1 and PowerShell 7.x

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
    Version = "2.7.0"
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
$VSanSubnet         = ''          # e.g. 172.16.11.0  (/24 assumed; last octet normalized to 0)
$VMotionSubnet      = ''          # e.g. 172.16.12.0  (/24 assumed; last octet normalized to 0)

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

function Get-NormalizedSubnet {
    param([string]$Subnet)
    $parts = $Subnet.Split('.')
    return "$($parts[0]).$($parts[1]).$($parts[2]).0"
}

function Get-NetworkDetails {
    param([string]$Subnet)
    $parts = $Subnet.Split('.')
    $base  = "$($parts[0]).$($parts[1]).$($parts[2])."
    return @{
        Gateway = $base + '1'
        StartIP = $base + '10'
        EndIP   = $base + '254'
    }
}

function Test-VlanId {
    param([int]$VlanId)
    return ($VlanId -ge 0 -and $VlanId -le 4094)
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

# Cluster name
if ($ClusterName -and $ClusterName.Trim()) {
    $clusterName = $ClusterName.Trim()
    Write-Host "  Cluster name      : $clusterName" -ForegroundColor DarkGray
} else {
    $clusterName = Read-RequiredHost '  Cluster name (e.g. cluster-mgmt-01a)'
}

# SDDC Manager FQDN
if ($SDDCManagerFQDN -and $SDDCManagerFQDN.Trim()) {
    $sddcManagerFqdn = $SDDCManagerFQDN.Trim()
    Write-Host "  SDDC Manager FQDN : $sddcManagerFqdn" -ForegroundColor DarkGray
} elseif ($MockMode) {
    $sddcManagerFqdn = 'sddc-manager.vcf.lab'
    Write-Host "  [MOCK] SDDC Manager FQDN: $sddcManagerFqdn" -ForegroundColor DarkYellow
} else {
    $derivedDC       = $clusterName.Substring(0, [Math]::Min(3, $clusterName.Length))
    $defaultFqdn     = "$derivedDC.mydns.local"   # <-- adjust default domain to match your environment
    $inputFqdn       = (Read-Host "  SDDC Manager FQDN [$defaultFqdn] (press Enter to accept)").Trim()
    $sddcManagerFqdn = if ($inputFqdn) { $inputFqdn } else { $defaultFqdn }
}

# Credentials (load from file, prompt, or prompt-and-save) — skipped in mock mode
if (-not $MockMode) {
    $cred = Get-VcfCredential `
        -ManagerFqdn     $sddcManagerFqdn `
        -CredentialFile  $CredentialFile `
        -SaveCredentials $SaveCredentials.IsPresent `
        -BaseDir         $baseDir
}

# MTU
if ($MTU -and $MTU.Trim() -and ($MTU.Trim() -match '^\d+$')) {
    [int]$mtu = [int]$MTU.Trim()
    Write-Host "  MTU               : $mtu" -ForegroundColor DarkGray
    if ($mtu -lt 1280 -or $mtu -gt 9216) {
        Write-Warning "MTU value $mtu is outside the typical range (1280-9216). Proceeding anyway."
    }
} else {
    $mtuInput = (Read-Host '  MTU [9000] (press Enter to accept)').Trim()
    [int]$mtu = if ($mtuInput) { [int]$mtuInput } else { 9000 }
    if ($mtu -lt 1280 -or $mtu -gt 9216) {
        Write-Warning "MTU value $mtu is outside the typical range (1280-9216). Proceeding anyway."
    }
}

# Network parameters — loop until all inputs are valid
$prefilledVsanVlan    = $VSanVlanId    -and $VSanVlanId.Trim()    -and ($VSanVlanId.Trim()    -match '^\d+$') -and (Test-VlanId ([int]$VSanVlanId.Trim()))
$prefilledVmotionVlan = $VMotionVlanId -and $VMotionVlanId.Trim() -and ($VMotionVlanId.Trim() -match '^\d+$') -and (Test-VlanId ([int]$VMotionVlanId.Trim()))
$prefilledVsanSubnet  = $VSanSubnet    -and (Test-SubnetFormat $VSanSubnet.Trim())
$prefilledVmotionSub  = $VMotionSubnet -and (Test-SubnetFormat $VMotionSubnet.Trim())

if ($prefilledVsanVlan -and $prefilledVmotionVlan -and $prefilledVsanSubnet -and $prefilledVmotionSub) {
    [int]$vsanVlanId    = [int]$VSanVlanId.Trim()
    [int]$vmotionVlanId = [int]$VMotionVlanId.Trim()
    $vsanSubnet         = $VSanSubnet.Trim()
    $vmotionSubnet      = $VMotionSubnet.Trim()
    Write-Host "  vSAN    VLAN / subnet : $vsanVlanId / $vsanSubnet" -ForegroundColor DarkGray
    Write-Host "  vMotion VLAN / subnet : $vmotionVlanId / $vmotionSubnet" -ForegroundColor DarkGray
} else {
    do {
        $inputErrors = @()

        $vsanVlanInput    = (Read-Host '  vSAN VLAN ID (0-4094)').Trim()
        $vmotionVlanInput = (Read-Host '  vMotion VLAN ID (0-4094)').Trim()
        $vsanSubnet       = (Read-Host '  vSAN subnet   (e.g. 192.168.10.0)').Trim()
        $vmotionSubnet    = (Read-Host '  vMotion subnet (e.g. 192.168.20.0)').Trim()

        if (-not ($vsanVlanInput -match '^\d+$'))         { $inputErrors += 'vSAN VLAN ID must be a number.' }
        elseif (-not (Test-VlanId ([int]$vsanVlanInput))) { $inputErrors += "vSAN VLAN ID $vsanVlanInput is out of range (0-4094)." }

        if (-not ($vmotionVlanInput -match '^\d+$'))         { $inputErrors += 'vMotion VLAN ID must be a number.' }
        elseif (-not (Test-VlanId ([int]$vmotionVlanInput))) { $inputErrors += "vMotion VLAN ID $vmotionVlanInput is out of range (0-4094)." }

        if (-not (Test-SubnetFormat $vsanSubnet))    { $inputErrors += "vSAN subnet '$vsanSubnet' is invalid. Use a valid IPv4 address (e.g. 192.168.10.0)." }
        if (-not (Test-SubnetFormat $vmotionSubnet)) { $inputErrors += "vMotion subnet '$vmotionSubnet' is invalid. Use a valid IPv4 address (e.g. 192.168.20.0)." }

        if ($inputErrors.Count -gt 0) {
            $inputErrors | ForEach-Object { Write-Warning $_ }
            Write-Host ""
        }
    } until ($inputErrors.Count -eq 0)

    [int]$vsanVlanId    = $vsanVlanInput
    [int]$vmotionVlanId = $vmotionVlanInput
}

# Derive pool name
$networkPoolName = "NP-$clusterName"

Write-Host ""
Write-Host "  Network pool name : $networkPoolName"                             -ForegroundColor Yellow
Write-Host "  SDDC Manager      : $sddcManagerFqdn"                            -ForegroundColor Yellow
Write-Host "  MTU               : $mtu"                                        -ForegroundColor Yellow
Write-Host "  vSAN              : VLAN $vsanVlanId   Subnet $vsanSubnet"       -ForegroundColor Yellow
Write-Host "  vMotion           : VLAN $vmotionVlanId  Subnet $vmotionSubnet"  -ForegroundColor Yellow
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

$vsanSubnet     = Get-NormalizedSubnet -Subnet $vsanSubnet
$vmotionSubnet  = Get-NormalizedSubnet -Subnet $vmotionSubnet

$vsanDetails    = Get-NetworkDetails -Subnet $vsanSubnet
$vmotionDetails = Get-NetworkDetails -Subnet $vmotionSubnet

$payload = [ordered]@{
    name     = $networkPoolName
    networks = @(
        [ordered]@{
            type    = 'VSAN'
            vlanId  = $vsanVlanId
            mtu     = $mtu
            subnet  = $vsanSubnet
            mask    = '255.255.255.0'
            gateway = $vsanDetails.Gateway
            ipPools = @(@{ start = $vsanDetails.StartIP; end = $vsanDetails.EndIP })
        },
        [ordered]@{
            type    = 'VMOTION'
            vlanId  = $vmotionVlanId
            mtu     = $mtu
            subnet  = $vmotionSubnet
            mask    = '255.255.255.0'
            gateway = $vmotionDetails.Gateway
            ipPools = @(@{ start = $vmotionDetails.StartIP; end = $vmotionDetails.EndIP })
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
