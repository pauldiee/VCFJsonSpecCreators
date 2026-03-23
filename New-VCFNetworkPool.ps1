#Requires -Version 5.0
<#
.SYNOPSIS
    Creates a Network Pool in VMware Cloud Foundation (VCF) via the SDDC Manager REST API.

.DESCRIPTION
    New-VCFNetworkPool.ps1 is an interactive script that guides you through the
    configuration of a new Network Pool in SDDC Manager. It collects all required
    network parameters, validates each input, builds and saves the JSON payload to
    disk, previews it on screen, and — after confirmation — submits the creation
    request to the SDDC Manager API.

    The script is compatible with both VCF 5.x and VCF 9.x. In VCF 9 the SDDC
    Manager UI is deprecated and day-2 network pool management has moved to
    vCenter (Global Inventory > Hosts > Network Pools) and VCF Operations, but
    the /v1/network-pools API endpoint remains fully supported for automation.

    WHAT THE SCRIPT DOES – STEP BY STEP:
      1. Optionally loads saved credentials from an encrypted file (-CredentialFile),
         or prompts via Get-Credential, optionally saving them for future use
         (-SaveCredentials).
      2. Collects cluster name, SDDC Manager FQDN, MTU, VLAN IDs, and subnets
         interactively, re-prompting on invalid input.
      3. Derives the pool name by prepending "NP-" to the full cluster name
         (e.g. cluster-mgmt-01a -> NP-cluster-mgmt-01a).
      4. Authenticates to SDDC Manager and obtains a Bearer token.
      5. Checks whether a pool with the same name already exists; exits if so.
      6. Builds the JSON payload (vSAN + vMotion networks) and saves it to a
         NetworkPools\ subfolder next to the script.
      7. Displays a JSON preview and asks for confirmation before creating.
      8. POSTs the payload to /v1/network-pools and reports the resulting pool ID.

    INPUT VALIDATION:
      - Cluster name       : must be non-empty.
      - SDDC Manager FQDN  : defaults to <first-3-chars-of-cluster>.mydns.local;
                             can be overridden at the prompt.
      - MTU                : defaults to 9000; warns if outside 1280-9216.
      - VLAN IDs           : must be integers in the range 0-4094.
      - Subnets            : must be valid IPv4 in x.x.x.0 form with all octets
                             in 0-255 and the host octet equal to 0 (/24 assumed).
      - All network fields are re-prompted together if any value is invalid.

    SAVED CREDENTIALS:
      Credentials are saved/loaded using Export-Clixml / Import-Clixml. On Windows
      the SecureString is encrypted with DPAPI, making the file readable only by
      the same user on the same machine. The default save path is:
        <script directory>\SavedCredentials\vcf-creds.xml
      A custom path can be provided via -CredentialFile.

    SECURITY:
      - Credentials are collected via Get-Credential (SecureString) - never stored
        in plain text.
      - TLS 1.2 is enforced on Windows PowerShell 5.x via ServicePointManager.
      - PowerShell 7 uses TLS 1.2/1.3 natively.
      - The -SkipCertCheck switch is available for lab environments with self-signed
        certificates (see parameter description below).

    OUTPUT FILES:
      The generated JSON is written to:
        <script directory>\NetworkPools\NP-<cluster-name>.json
      If the script is dot-sourced (no $PSScriptRoot), the current working
      directory is used as the base.

    POWERSHELL VERSION NOTES:
      - PowerShell 5.1 recommended (5.0 minimum); or PowerShell 7.x on Windows.

    VCF 9 NOTES:
      - In VCF 9, the SDDC Manager UI is deprecated. Network pools created via
        this script will also appear in vCenter under:
        Global Inventory List > Hosts > Network Pools
      - The SDDC Manager FQDN may differ from the cluster-name-derived default
        in VCF 9 deployments; override it at the prompt when needed.
      - No API version change was required; /v1/network-pools works in both
        VCF 5.x and VCF 9.x.

.PARAMETER SkipCertCheck
    Bypass SSL/TLS certificate validation. Intended for lab or development
    environments where SDDC Manager uses a self-signed certificate.
    On PowerShell 5.x this sets a global CertificatePolicy callback.
    On PowerShell 7 this passes -SkipCertificateCheck per request.
    NOT recommended for production use.

.PARAMETER SaveCredentials
    After prompting for credentials via Get-Credential, encrypt and save them to
    disk using Export-Clixml. The file is written to the path specified by
    -CredentialFile (default: <script dir>\SavedCredentials\vcf-creds.xml).
    The credential file is protected by DPAPI and can only be decrypted by
    the same user account on the same machine.
    Cannot be used together with -CredentialFile (load vs. save are separate
    operations).

.PARAMETER CredentialFile
    Path to an encrypted credential file previously created with -SaveCredentials.
    When provided the script skips the Get-Credential prompt and loads credentials
    from this file instead. The file must have been created by the same user on
    the same Windows machine (DPAPI restriction).

.EXAMPLE
    .\New-VCFNetworkPool.ps1

    Runs the script in interactive mode with full certificate validation.
    You will be prompted for all required values. Suitable for production use.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SkipCertCheck

    Runs the script with certificate validation disabled. Use this in lab
    environments where SDDC Manager has a self-signed or untrusted certificate.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SaveCredentials

    Prompts for credentials via Get-Credential, then saves the encrypted
    credential file to the default path for future use.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -SaveCredentials -CredentialFile 'C:\VCF\my-creds.xml'

    Prompts for credentials and saves them to a custom file path.

.EXAMPLE
    .\New-VCFNetworkPool.ps1 -CredentialFile 'C:\VCF\my-creds.xml'

    Loads credentials from the specified encrypted file; no credential prompt.
    Useful for scheduled or repeated runs after an initial -SaveCredentials run.

.EXAMPLE
    # Typical interactive session (user input shown after the colon):
    #
    # Cluster name (e.g. sfo-m01-cl01)             : sfo-m01-cl01
    # SDDC Manager FQDN [sfo.mydns.local]           : sfo-sddc01.corp.local
    # (Get-Credential dialog opens)
    # MTU [9000]                                    : <Enter>
    # vSAN VLAN ID (0-4094)                         : 1611
    # vMotion VLAN ID (0-4094)                      : 1612
    # vSAN subnet   (e.g. 192.168.10.0)             : 172.16.11.0
    # vMotion subnet (e.g. 192.168.20.0)            : 172.16.12.0
    #
    # => Pool name  : NP-sfo-m01-cl01
    # => JSON saved : .\NetworkPools\NP-sfo-m01-cl01.json
    # => Pool ID    : <uuid returned by SDDC Manager>

.NOTES
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl

    REQUIREMENTS:
      - PowerShell 5.1 recommended (5.0 minimum); or PowerShell 7.0+
      - Network access to SDDC Manager on port 443
      - An SDDC Manager account with the ADMIN or NETWORK_ADMIN role

    TESTED ON:
      - VCF 5.0, 5.1, 5.2
      - VCF 9.0
      - Windows PowerShell 5.1
      - PowerShell 7.4 (Windows)

    ---------------------------------------------------------------------------
    CHANGELOG
    ---------------------------------------------------------------------------
    v2.6  2025-xx-xx  Remove invalid logout calls
          + Removed all DELETE /v1/tokens logout calls. The SDDC Manager API does
            not provide a token revocation endpoint - DELETE /v1/tokens does not
            exist and was returning an error on every run, causing the misleading
            warning "Could not invalidate the session token." Access tokens expire
            automatically after 1 hour per the API specification. Replaced the
            logout block with an informational note about token expiry.
    v2.5  2025-xx-xx  Network pool naming improvement
          + Changed pool name format from 'network-pool-<cluster-suffix>' to
            'NP-<full-cluster-name>' (e.g. NP-cluster-mgmt-01a). The old format
            stripped the first 4 characters of the cluster name assuming a short
            datacenter prefix (e.g. 'sfo-'), which produced nonsensical names for
            longer naming conventions like 'cluster-mgmt-01a'.
          + Removed cluster name length warning that was only relevant to the old
            substring-based naming logic.
          + Updated prompt example, description, and .EXAMPLE to reflect new format.
    v2.4  2025-xx-xx  GET body bugfix
          + Fixed bug: Invoke-VcfApi body guard used ($null -ne $Body). A [string]
            parameter with default $null can resolve to an empty string '' under
            PowerShell's type coercion, making the guard evaluate to $true and
            attaching an empty body to GET requests. .NET then rejects this with
            "Cannot send a content-body with this verb-type". Replaced guard with
            [string]::IsNullOrEmpty($Body) which correctly handles both $null and ''.
    v2.3  2025-xx-xx  Strict mode bugfixes continued
          + Fixed bug: Invoke-VcfApi catch block accessed $_.Exception.Response
            directly. Under Set-StrictMode -Version Latest, accessing a property
            that does not exist on the object throws before the $null check even
            runs. Replaced with Get-Member existence checks before each property
            access, making the error handler safe for all exception types.
          + Fixed bug: $PSVersionTable.Platform does not exist on Windows PowerShell
            5.x (it is PS 7-only); reading it under Set-StrictMode -Version Latest
            throws a PropertyNotFound error. Replaced with PSEdition + OS check.
            (This fix was applied in v2.2 but not documented there.)
    v2.2  2025-xx-xx  Strict mode bugfix
          + Fixed bug: Test-IPv4Address used .Count on a raw Where-Object pipeline
            result. Under Set-StrictMode -Version Latest, a pipeline that matches
            nothing returns $null instead of an empty collection, and $null has no
            .Count property, causing a runtime error. Fixed by wrapping in @() to
            guarantee an array type in all cases.
          + Applied the same @() guard to the Where-Object call that checks for an
            existing pool, for consistency.
    v2.1  2025-xx-xx  Saved credentials & version requirement cleanup
          + Relaxed #Requires from -Version 5.1 to -Version 5.0 since no 5.1-
            specific APIs are actually used. Added documentation note that 5.1
            is still strongly recommended and that PS Core 6.x is not supported.
          + Added -SaveCredentials switch: after Get-Credential prompt, encrypts
            and saves the PSCredential to disk via Export-Clixml.
          + Added -CredentialFile parameter: loads a previously saved credential
            file via Import-Clixml, skipping the interactive prompt entirely.
          + Default credential save path: <script dir>\SavedCredentials\vcf-creds.xml.
            Directory is created automatically if it does not exist.
          + Added platform warning on Linux/macOS: DPAPI is Windows-only; the
            Export-Clixml encryption is weaker on non-Windows platforms and the
            user is advised to restrict file permissions (chmod 600).
          + Added parameter validation: -SaveCredentials and -CredentialFile are
            mutually exclusive; combined use exits with a clear error.
          + Updated .DESCRIPTION, .PARAMETER, .EXAMPLE, and CHANGELOG sections.
    v2.0  2025-xx-xx  Major rewrite - VCF 9 compatibility & hardening
          COMPATIBILITY
          + Added support for VCF 9.x; documents that /v1/network-pools remains
            available even though the SDDC Manager UI is deprecated in VCF 9.
          + Added note directing users to vCenter > Global Inventory List >
            Hosts > Network Pools for VCF 9 day-2 management.

          SECURITY
          + Replaced hardcoded plaintext credentials with Get-Credential
            (SecureString); password is never stored as plain text in memory
            longer than the authentication call.
          + Added explicit TLS 1.2 enforcement for Windows PowerShell 5.1 via
            [Net.ServicePointManager]::SecurityProtocol.
          + Added -SkipCertCheck switch for lab environments with self-signed
            certificates (PS 5.1: ICertificatePolicy callback;
             PS 7: -SkipCertificateCheck per Invoke-RestMethod call).
          + Added session token handling (DELETE /v1/tokens); later found to be
            invalid as the API has no revocation endpoint - removed in v2.6.

          VALIDATION & ROBUSTNESS
          + Added Test-IPv4Address: validates each octet is in range 0-255,
            preventing inputs like 999.999.0.0 from passing silently.
          + Added Test-SubnetFormat: enforces that the host octet is 0 (/24).
          + Added Test-VlanId: enforces the valid VLAN range 0-4094.
          + Added Read-RequiredHost: prevents empty cluster name or FQDN.
          + Added cluster name length warning (< 5 chars = suspicious).
          + Network input loop now re-prompts all four fields together if any
            single value is invalid, listing all errors at once.
          + Fixed bug: existence check referenced undefined variable
            $targetNWPoolName; corrected to $networkPoolName.
          + Fixed bug: -WarningAction Stop on Write-Warning does not terminate
            a script; replaced with explicit exit 1.
          + Fixed bug: -Debug flag on Where-Object was unintentional; removed.

          CODE QUALITY
          + Replaced brittle Substring(0,9) IP derivation with a Split('.')
            approach that works correctly for any /24 subnet (e.g. 10.x.x.0).
          + Extracted reusable helper functions: Invoke-VcfApi, Get-NetworkDetails,
            Confirm-CreatePool, Set-TlsOptions, Test-IPv4Address,
            Test-SubnetFormat, Test-VlanId, Read-RequiredHost.
          + Invoke-VcfApi: unified REST wrapper with PS 5.1-compatible error
            handling (removed ?. null-conditional which is PS 7+ only).
          + $Body parameter default changed to $null; guard changed from
            if ($Body) to if ($null -ne $Body) to handle empty-body GET calls.
          + Output path changed from hardcoded D:\Scripts\... to a NetworkPools\
            subfolder relative to $PSScriptRoot, with fallback to Get-Location
            when $PSScriptRoot is empty (dot-sourced execution).
          + Added $mtu as a configurable prompt (default 9000) with range warning
            instead of a hardcoded magic number.
          + Added -SkipCertCheck as a proper param() switch with full help text.
          + Added Set-StrictMode -Version Latest and $ErrorActionPreference = 'Stop'
            for safer execution.
          + Added summary display of all collected values before authentication.
          + Confirm-CreatePool now includes the SDDC Manager FQDN in the prompt.
          + Added full .SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE, and
            .NOTES (with changelog) comment-based help.
    v1.0  2022-xx-xx  Initial release
          - Interactive prompts for cluster name, VLAN IDs, and subnets.
          - Derives SDDC Manager FQDN from the first 3 characters of the cluster
            name using a hardcoded domain suffix.
          - Hardcoded plaintext USERNAME / PASSWORD for authentication.
          - Generates JSON payload for vSAN and vMotion network pools.
          - Saves JSON to a hardcoded path (D:\Scripts\VMware\VCF\NetworkPools\).
          - Submits POST /v1/network-pools to create the pool.
          - Basic yes/no prompt before creation.

        ---------------------------------------------------------------------------
#>
param(
    [switch]$SkipCertCheck,
    [switch]$SaveCredentials,
    [string]$CredentialFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Parameter guard: -SaveCredentials and -CredentialFile are mutually exclusive
# ---------------------------------------------------------------------------
if ($SaveCredentials -and $CredentialFile) {
    Write-Error '-SaveCredentials and -CredentialFile cannot be used together. Use -SaveCredentials to create the file, then -CredentialFile to load it on subsequent runs.'
    exit 1
}

# ---------------------------------------------------------------------------
# Helper: enforce TLS 1.2 (PS 5.x) and optional cert bypass
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: invoke REST with consistent headers and clear error surfacing
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: prompt yes/no before creating the pool
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: validate an IPv4 address string with octet range check (0-255)
# ---------------------------------------------------------------------------
function Test-IPv4Address {
    param([string]$Address)
    if ($Address -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    return (@($Address.Split('.') | ForEach-Object { [int]$_ } | Where-Object { $_ -lt 0 -or $_ -gt 255 })).Count -eq 0
}

# ---------------------------------------------------------------------------
# Helper: validate subnet - valid IPv4 with host bits zeroed (/24 assumed)
# ---------------------------------------------------------------------------
function Test-SubnetFormat {
    param([string]$Subnet)
    if (-not (Test-IPv4Address -Address $Subnet)) { return $false }
    return ($Subnet.Split('.')[3] -eq '0')
}

# ---------------------------------------------------------------------------
# Helper: derive gateway / IP range from a /24 subnet
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: validate VLAN ID (0-4094)
# ---------------------------------------------------------------------------
function Test-VlanId {
    param([int]$VlanId)
    return ($VlanId -ge 0 -and $VlanId -le 4094)
}

# ---------------------------------------------------------------------------
# Helper: prompt for a non-empty string
# ---------------------------------------------------------------------------
function Read-RequiredHost {
    param([string]$Prompt)
    do {
        $value = (Read-Host $Prompt).Trim()
        if (-not $value) { Write-Warning 'Value cannot be empty.' }
    } until ($value)
    return $value
}

# ---------------------------------------------------------------------------
# Helper: resolve the base directory (robust against dot-sourcing)
# ---------------------------------------------------------------------------
function Get-BaseDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

# ---------------------------------------------------------------------------
# Helper: load or prompt for credentials, with optional save
# ---------------------------------------------------------------------------
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
            Write-Host "Credentials loaded from: $CredentialFile" -ForegroundColor Green
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
            Write-Host "Credentials saved to : $savePath" -ForegroundColor Green
            Write-Host "Load them next time  : .\New-VCFNetworkPool.ps1 -CredentialFile '$savePath'" -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "Could not save credentials: $($_.Exception.Message). Continuing without saving."
        }
    }

    return $cred
}

# ===========================================================================
# MAIN
# ===========================================================================

Set-TlsOptions -SkipCert $SkipCertCheck.IsPresent

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  VCF Network Pool Creator  (VCF 5.x / VCF 9 compatible)   ' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
if ($SkipCertCheck) {
    Write-Host '  [!] Running with certificate validation DISABLED         ' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Cyan
}
Write-Host ''

$baseDir = Get-BaseDir

# ---------------------------------------------------------------------------
# 1. Collect and validate user input
# ---------------------------------------------------------------------------

# Cluster name
$clusterName = Read-RequiredHost 'Cluster name (e.g. cluster-mgmt-01a)'

# SDDC Manager FQDN
$derivedDC       = $clusterName.Substring(0, [Math]::Min(3, $clusterName.Length))
$defaultFqdn     = "$derivedDC.mydns.local"   # <-- adjust default domain to match your environment
$inputFqdn       = (Read-Host "SDDC Manager FQDN [$defaultFqdn] (press Enter to accept)").Trim()
$sddcManagerFqdn = if ($inputFqdn) { $inputFqdn } else { $defaultFqdn }

# Credentials (load from file, prompt, or prompt-and-save)
$cred = Get-VcfCredential `
    -ManagerFqdn     $sddcManagerFqdn `
    -CredentialFile  $CredentialFile `
    -SaveCredentials $SaveCredentials.IsPresent `
    -BaseDir         $baseDir

# MTU (default 9000, allow override)
$mtuInput = (Read-Host 'MTU [9000] (press Enter to accept)').Trim()
[int]$mtu = if ($mtuInput) { [int]$mtuInput } else { 9000 }
if ($mtu -lt 1280 -or $mtu -gt 9216) {
    Write-Warning "MTU value $mtu is outside the typical range (1280-9216). Proceeding anyway."
}

# Network parameters - loop until all inputs are valid
do {
    $inputErrors = @()

    $vsanVlanInput    = (Read-Host 'vSAN VLAN ID (0-4094)').Trim()
    $vmotionVlanInput = (Read-Host 'vMotion VLAN ID (0-4094)').Trim()
    $vsanSubnet       = (Read-Host 'vSAN subnet   (e.g. 192.168.10.0 - last octet must be 0)').Trim()
    $vmotionSubnet    = (Read-Host 'vMotion subnet (e.g. 192.168.20.0 - last octet must be 0)').Trim()

    if (-not ($vsanVlanInput -match '^\d+$'))         { $inputErrors += 'vSAN VLAN ID must be a number.' }
    elseif (-not (Test-VlanId ([int]$vsanVlanInput))) { $inputErrors += "vSAN VLAN ID $vsanVlanInput is out of range (0-4094)." }

    if (-not ($vmotionVlanInput -match '^\d+$'))         { $inputErrors += 'vMotion VLAN ID must be a number.' }
    elseif (-not (Test-VlanId ([int]$vmotionVlanInput))) { $inputErrors += "vMotion VLAN ID $vmotionVlanInput is out of range (0-4094)." }

    if (-not (Test-SubnetFormat $vsanSubnet))    { $inputErrors += "vSAN subnet '$vsanSubnet' is invalid. Use x.x.x.0 with valid octets (0-255)." }
    if (-not (Test-SubnetFormat $vmotionSubnet)) { $inputErrors += "vMotion subnet '$vmotionSubnet' is invalid. Use x.x.x.0 with valid octets (0-255)." }

    if ($inputErrors.Count -gt 0) {
        $inputErrors | ForEach-Object { Write-Warning $_ }
        Write-Host ''
    }
} until ($inputErrors.Count -eq 0)

[int]$vsanVlanId    = $vsanVlanInput
[int]$vmotionVlanId = $vmotionVlanInput

# Derive pool name
$networkPoolName = "NP-$clusterName"

Write-Host ''
Write-Host "Network pool name : $networkPoolName"                             -ForegroundColor Yellow
Write-Host "SDDC Manager      : $sddcManagerFqdn"                            -ForegroundColor Yellow
Write-Host "MTU               : $mtu"                                        -ForegroundColor Yellow
Write-Host "vSAN              : VLAN $vsanVlanId   Subnet $vsanSubnet"       -ForegroundColor Yellow
Write-Host "vMotion           : VLAN $vmotionVlanId  Subnet $vmotionSubnet"  -ForegroundColor Yellow
Write-Host ''

# ---------------------------------------------------------------------------
# 2. Authenticate to SDDC Manager
# ---------------------------------------------------------------------------
$authUrl  = "https://$sddcManagerFqdn/v1/tokens"
$authBody = [ordered]@{
    username = $cred.UserName
    password = $cred.GetNetworkCredential().Password
} | ConvertTo-Json

Write-Host 'Authenticating to SDDC Manager...' -ForegroundColor Cyan
$tokenResponse = Invoke-VcfApi -Method POST -Uri $authUrl -Headers @{} -Body $authBody -SkipCert $SkipCertCheck.IsPresent
$sessionHeader = @{
    Authorization = "Bearer $($tokenResponse.accessToken)"
    Accept        = 'application/json'
}
Write-Host 'Authentication successful.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Check whether the pool already exists
# ---------------------------------------------------------------------------
Write-Host "Checking for existing pool '$networkPoolName'..." -ForegroundColor Cyan
$allPools = Invoke-VcfApi -Method GET `
    -Uri      "https://$sddcManagerFqdn/v1/network-pools" `
    -Headers  $sessionHeader `
    -SkipCert $SkipCertCheck.IsPresent

$existingPool = @($allPools.elements | Where-Object { $_.name -eq $networkPoolName })
if ($existingPool) {
    Write-Warning "Network pool '$networkPoolName' already exists (ID: $($existingPool.id)). Exiting."
    exit 1
}
Write-Host "Pool '$networkPoolName' not found - proceeding." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Build JSON payload
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5. Save JSON to file
# ---------------------------------------------------------------------------
$outputDir = Join-Path $baseDir 'NetworkPools'
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}
$jsonFile = Join-Path $outputDir "$networkPoolName.json"
$jsonBody | Out-File -FilePath $jsonFile -Encoding utf8 -Force
Write-Host "JSON saved to: $jsonFile" -ForegroundColor Green

# Show payload preview
Write-Host ''
Write-Host '--- JSON Payload Preview ---' -ForegroundColor DarkGray
Write-Host $jsonBody
Write-Host '----------------------------' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# 6. Confirm and create the pool
# ---------------------------------------------------------------------------
if (-not (Confirm-CreatePool -PoolName $networkPoolName -ManagerFqdn $sddcManagerFqdn)) {
    Write-Host 'Operation cancelled by user.' -ForegroundColor Yellow
    exit 0
}

Write-Host "Creating network pool '$networkPoolName'..." -ForegroundColor Cyan
$createResult = Invoke-VcfApi -Method POST `
    -Uri      "https://$sddcManagerFqdn/v1/network-pools" `
    -Headers  $sessionHeader `
    -Body     $jsonBody `
    -SkipCert $SkipCertCheck.IsPresent

# The SDDC Manager API has no logout endpoint; the token expires automatically after 1 hour.
Write-Host 'Note: session token expires automatically in 1 hour.' -ForegroundColor DarkGray

Write-Host ''
Write-Host "Network pool '$networkPoolName' created successfully!" -ForegroundColor Green
Write-Host "Pool ID : $($createResult.id)"                        -ForegroundColor Green
Write-Host ''
Write-Host 'NOTE (VCF 9): Network pools are also visible and manageable via:' -ForegroundColor DarkYellow
Write-Host '  vCenter > Global Inventory List > Hosts > Network Pools'        -ForegroundColor DarkYellow
Write-Host '  and through VCF Operations.'                                     -ForegroundColor DarkYellow
