#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a VCF 9 vSAN Stretched Cluster spec JSON, optionally validates it against SDDC Manager, and saves it to file.

.DESCRIPTION
    - Queries SDDC Manager for existing clusters to select the one to stretch
    - Queries unassigned commissioned hosts for the secondary site
    - Collects witness host, fault domain, and network configuration
    - Builds the vSAN stretch spec JSON payload
    - Optionally validates via SDDC Manager API (/v1/clusters/{id}/validations/stretch)
    - Saves the JSON to disk
    - Supports mock mode for offline/lab testing without live SDDC Manager

.AUTHOR
    Paul van Dieen | hollebollevsan.nl

.VERSION
    1.0.0

.CHANGELOG
    1.0.0 - Initial release

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
$ScriptVersion      = '1.0.0'
$MockModeVar        = $false      # set to $true to enable mock mode without the -MockMode switch

$SDDCManagerFQDN    = ''          # e.g. sddc-manager.vcf.lab

# -- Witness host:
$WitnessFQDN        = ''          # e.g. witness.vcf.lab
$WitnessVsanIp      = ''          # e.g. 192.168.20.100 (IP on vSAN network)
$WitnessNetmask     = ''          # e.g. 255.255.255.0
$WitnessGateway     = ''          # e.g. 192.168.20.1

# -- Fault domain names:
$PrimaryFaultDomainName   = ''    # e.g. Preferred-Site  (leave blank to prompt)
$SecondaryFaultDomainName = ''    # e.g. Secondary-Site  (leave blank to prompt)

# -- VDS (must match the existing cluster's VDS):
$VDSName            = ''          # e.g. wld-01-vds01    (leave blank to prompt)

# -- ESXi license key for secondary site hosts (leave blank to skip):
$ESXiLicenseKey     = ''

$OutputJsonPath     = ''          # e.g. C:\VCF\wld-01-stretch.json (leave blank to auto-generate)
#endregion ───────────────────────────────────────────────────────────────────

# Resolve mock mode from either source
if ($MockModeVar) { $MockMode = [switch]$true }

#region ── Mock data ──────────────────────────────────────────────────────────
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
#endregion ───────────────────────────────────────────────────────────────────

#region ── Helpers ────────────────────────────────────────────────────────────
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
        Write-Warn "Pre-filled value is invalid: $InvalidMessage"
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

#region ── Banner ─────────────────────────────────────────────────────────────
$border  = '═' * 58
$blank   = '║' + (' ' * 58) + '║'
$title   = 'VCF vSAN Stretched Cluster Spec Creator'
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
    Write-Host '  Stub data is used for clusters, hosts, and validation' -ForegroundColor DarkYellow
    Write-Host $mockBanner -ForegroundColor DarkYellow
}
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 1: SDDC Manager connection ────────────────────────────────────
Write-Header 'Step 1 of 6  |  SDDC Manager Connection'

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

#region ── Step 2: Select target cluster ──────────────────────────────────────
Write-Header 'Step 2 of 6  |  Target Cluster Selection'

if ($MockMode) {
    Write-Mock 'Using mock cluster list.'
    $clusterList = $MockClusters
} else {
    Write-Step 'Querying existing clusters from SDDC Manager ...'
    try {
        $clustersResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token -Path '/v1/clusters'
        $clusterList  = $clustersResp.elements
    } catch {
        Write-Fail "Failed to retrieve clusters: $_"
        exit 1
    }
    if (-not $clusterList -or $clusterList.Count -eq 0) {
        Write-Fail 'No clusters found in SDDC Manager.'
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
    Write-Fail 'Invalid cluster selection.'
    exit 1
}
$selectedCluster = $clusterList[$clusterIdx]
Write-OK "Target cluster: $($selectedCluster.name)  (ID: $($selectedCluster.id))"
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 3: Witness host configuration ─────────────────────────────────
Write-Header 'Step 3 of 6  |  Witness Host Configuration'

Write-Host ''
Write-Host '  The witness host arbitrates between the two fault domains.' -ForegroundColor White
Write-Host '  It can be a vSAN Witness Appliance (OVA) or a physical host.' -ForegroundColor White
Write-Host ''

$WitnessFQDN    = Get-OrPrompt -Value $WitnessFQDN -Prompt 'Witness host FQDN (e.g. witness.vcf.lab)' `
    -Validator { param($v) Test-FQDN $v } `
    -InvalidMessage 'Must be a valid FQDN.'
$WitnessVsanIp  = Get-OrPrompt -Value $WitnessVsanIp -Prompt 'Witness vSAN IP address' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'
$WitnessNetmask = Get-OrPrompt -Value $WitnessNetmask -Prompt 'Witness vSAN subnet mask' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid subnet mask (e.g. 255.255.255.0).'
$WitnessGateway = Get-OrPrompt -Value $WitnessGateway -Prompt 'Witness vSAN gateway' `
    -Validator { param($v) Test-IPAddress $v } `
    -InvalidMessage 'Must be a valid IPv4 address.'

Write-OK "Witness: $WitnessFQDN  |  vSAN IP: $WitnessVsanIp  |  GW: $WitnessGateway"
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 4: Secondary site host selection ──────────────────────────────
Write-Header 'Step 4 of 6  |  Secondary Site Host Selection'

Write-Host ''
Write-Host '  Select the hosts that will form the secondary (stretched) fault domain.' -ForegroundColor White
Write-Host '  These must be unassigned commissioned hosts in SDDC Manager.' -ForegroundColor White
Write-Host '  The number of secondary site hosts should match the primary site host count.' -ForegroundColor White
Write-Host ''

if ($MockMode) {
    Write-Mock 'Using mock host list.'
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
$selection = Read-Host -Prompt 'Enter host numbers for the secondary site (comma-separated or range, e.g. 1,2,3 or 1-3)'
$indices = @()
foreach ($part in ($selection -split ',')) {
    $part = $part.Trim()
    if ($part -match '^(\d+)-(\d+)$') {
        $indices += [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $_ - 1 }
    } elseif ($part -match '^\d+$') {
        $indices += [int]$part - 1
    } else {
        Write-Fail "Invalid selection token: '$part' — expected a number or range (e.g. 1,2,3 or 1-3)."
        exit 1
    }
}

$secondaryHosts = @()
foreach ($idx in $indices) {
    if ($idx -lt 0 -or $idx -ge $availHosts.Count) {
        Write-Fail "Invalid selection: $($idx + 1)"
        exit 1
    }
    $secondaryHosts += $availHosts[$idx]
}

if ($secondaryHosts.Count -eq 0) {
    Write-Fail 'No hosts selected for the secondary site.'
    exit 1
}

Write-OK "$($secondaryHosts.Count) host(s) selected for secondary site:"
foreach ($h in $secondaryHosts) { Write-Host "    - $($h.fqdn)" }
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 5: Network and fault domain configuration ─────────────────────
Write-Header 'Step 5 of 6  |  Network and Fault Domain Configuration'

# ── VDS name ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  The VDS name must match the existing VDS in the target cluster.' -ForegroundColor White
Write-Host ''
$vdsName = Get-OrPrompt -Value $VDSName -Prompt 'VDS name (must match existing cluster VDS)' `
    -Validator { param($v) Test-SimpleName $v } `
    -InvalidMessage 'VDS name must contain only letters, digits, hyphens, or underscores (no spaces or dots).'
Write-OK "VDS name: $vdsName"

# ── VDS uplinks ───────────────────────────────────────────────────────────────
Write-Host ''
$uplinkInput = Get-OrPrompt -Value '' -Prompt 'VDS uplink names, comma-separated (press Enter for "uplink1,uplink2")' -Optional
$uplinkNames = if ($uplinkInput -and $uplinkInput.Trim() -ne '') {
    @($uplinkInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    @('uplink1', 'uplink2')
}
Write-OK "Uplinks: $($uplinkNames -join ', ')"

# ── Fault domain names ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Fault domain names identify the two sites in the stretched cluster.' -ForegroundColor White
Write-Host ''
$PrimaryFaultDomainName = Get-OrPrompt -Value $PrimaryFaultDomainName `
    -Prompt 'Primary (preferred) fault domain name (e.g. Preferred-Site)' `
    -Validator { param($v) $v.Trim().Length -ge 1 } `
    -InvalidMessage 'Fault domain name cannot be empty.'
$SecondaryFaultDomainName = Get-OrPrompt -Value $SecondaryFaultDomainName `
    -Prompt 'Secondary fault domain name (e.g. Secondary-Site)' `
    -Validator { param($v) $v.Trim().Length -ge 1 } `
    -InvalidMessage 'Fault domain name cannot be empty.'
Write-OK "Fault domains — Primary: $PrimaryFaultDomainName  |  Secondary: $SecondaryFaultDomainName"

# ── ESXi license key ──────────────────────────────────────────────────────────
$esxiLicenseInput = Get-OrPrompt -Value $ESXiLicenseKey `
    -Prompt 'ESXi license key for secondary site hosts (press Enter to skip)' `
    -Optional `
    -Validator { param($v) $v -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$' } `
    -InvalidMessage 'License key must be in XXXXX-XXXXX-XXXXX-XXXXX-XXXXX format (uppercase letters and digits).'
if ($esxiLicenseInput) { Write-OK "ESXi license key set." } else { Write-Warn 'No ESXi license key provided.' }
#endregion ───────────────────────────────────────────────────────────────────

#region ── Step 6: Build JSON payload ────────────────────────────────────────
Write-Header 'Step 6 of 6  |  Building JSON Payload'

# ── Secondary site host specs ─────────────────────────────────────────────────
$esxiKey = if ($esxiLicenseInput -and $esxiLicenseInput.Trim() -ne '') { $esxiLicenseInput.Trim() } else { $null }

$secondaryHostSpecs = @()
foreach ($h in $secondaryHosts) {
    $nicIds = @('vmnic0', 'vmnic1')
    $vmNics = for ($j = 0; $j -lt $nicIds.Count; $j++) {
        @{ id = $nicIds[$j]; vdsName = $vdsName; uplink = $uplinkNames[$j % $uplinkNames.Count] }
    }
    $secondaryHostSpecs += @{
        id              = $h.id
        licenseKey      = $esxiKey
        hostNetworkSpec = @{ vmNics = $vmNics }
    }
}

# ── Full payload ──────────────────────────────────────────────────────────────
$payload = @{
    clusterId  = $selectedCluster.id
    stretchSpec = @{
        primaryFaultDomainName   = $PrimaryFaultDomainName
        secondaryFaultDomainName = $SecondaryFaultDomainName
        witnessSpec              = @{
            fqdn        = $WitnessFQDN
            vsanIp      = $WitnessVsanIp
            vsanNetmask = $WitnessNetmask
            vsanGateway = $WitnessGateway
        }
        secondarySiteHostSpecs   = $secondaryHostSpecs
    }
}

$jsonOutput = $payload | ConvertTo-Json -Depth 20
Write-OK 'JSON payload built successfully.'
#endregion ───────────────────────────────────────────────────────────────────

#region ── Validate ───────────────────────────────────────────────────────────
Write-Header 'Validation  |  SDDC Manager API'

if ($MockMode) {
    Write-Mock 'Skipping live validation. Returning mock SUCCEEDED result.'
    Write-Host ''
    Write-OK 'Validation PASSED (mock). Stretch spec JSON is ready for review.'
} else {
    $validateChoice = ''
    while ($validateChoice -notin @('y', 'n')) {
        $validateChoice = (Read-Host -Prompt 'Submit for validation against SDDC Manager? (y/n)').ToLower()
        if ($validateChoice -notin @('y', 'n')) { Write-Warn 'Please enter y or n.' }
    }

    if ($validateChoice -eq 'y') {
        Write-Step "Submitting validation request to /v1/clusters/$($selectedCluster.id)/validations/stretch ..."
        $validationResp = $null
        try {
            $validationResp = Invoke-SDDC -FQDN $SDDCManagerFQDN -Token $token `
                -Method POST -Path "/v1/clusters/$($selectedCluster.id)/validations/stretch" -Body $payload.stretchSpec
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
                        -Path "/v1/clusters/$($selectedCluster.id)/validations/stretch/$validationId"
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
                    Write-OK 'Validation PASSED. Stretch spec JSON is ready for deployment.'
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
    } else {
        Write-Warn 'Validation skipped. Review the JSON before deploying.'
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
    $clusterSlug    = $selectedCluster.name -replace '[^a-zA-Z0-9\-_]', '-'
    $OutputJsonPath = Join-Path $scriptDir "$clusterSlug-vsan-stretch-$ts.json"
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
Write-Host '  To apply the stretch operation, POST the stretchSpec to:' -ForegroundColor DarkGray
Write-Host "  POST https://$SDDCManagerFQDN/v1/clusters/$($selectedCluster.id)/stretch" -ForegroundColor DarkGray
Write-Host ''
if ($MockMode) {
    Write-Host '  Done. (mock mode - no changes were made to SDDC Manager)' -ForegroundColor DarkYellow
} else {
    Write-Host '  Done.' -ForegroundColor Cyan
}
Write-Host ''
