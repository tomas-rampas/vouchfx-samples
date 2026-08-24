#Requires -Version 7.0
<#
.SYNOPSIS
    Generates the throwaway certificates that tests/kafka-mtls.e2e.yaml
    declares for a mutually-authenticated Kafka `dependency` (not a service).

.DESCRIPTION
    ###########################################################################
    #  THIS IS A TEST CERTIFICATE AUTHORITY.  IT IS NOT SECURE.               #
    #                                                                         #
    #  Every private key it writes is unencrypted, world-generatable and      #
    #  reproducible by anyone who runs this file.  The authority signs        #
    #  anything asked of it and is trusted by nothing.  Do not install it,    #
    #  do not copy it into another project, and never present anything it     #
    #  issues to a system you did not create for the purpose.                 #
    ###########################################################################

    WHY A SCRIPT AND NOT A STEP.  vouchfx checks every path under a `security:`
    block — that it stays inside the suite directory, and that the file is
    actually there — BEFORE it starts a single container.  A `script.csharp`
    step runs long after that gate, so no step can create this material in
    time.  This mirrors examples/security-mtls.setup.ps1 in the engine repo.

    WHY .NET HERE AND openssl IN THE .sh SIBLING.  PowerShell 7 is built on
    .NET, so the certificate APIs below are already present on any Windows
    machine that can run this file. On Linux/macOS the reverse holds, which is
    what setup.sh uses instead — this sample's whole point is that a
    mutually-authenticated Kafka dependency needs no JDK (KAFKA_SSL_KEYSTORE_
    TYPE: PEM reads a plain PEM file, not a JKS one), so neither script ever
    shells out to keytool.

    THE KEYSTORE FILE'S CONCATENATION ORDER — key, then leaf certificate, then
    CA, in that order, all three in ONE file — is the order actually MEASURED
    against docker.io/confluentinc/confluent-local:8.2.0 with
    KAFKA_SSL_KEYSTORE_TYPE=PEM before this sample was written (broker logs
    inspected, ssl.keystore.location/ssl.truststore.location populated,
    ssl.client.auth = required, ssl.keystore.password = null, and a real
    produce/consume round trip completed against it). Do not "simplify" this
    to key+cert only without re-measuring — that is a DIFFERENT claim.

    THE KEY IS UNENCRYPTED. The measured broker config shows
    `ssl.key.password = null` with no KAFKA_SSL_KEY_PASSWORD set — no password
    variable is needed for an unencrypted key. Same open constraint vouchfx
    engine issue #384 tracks generally.

.PARAMETER Force
    Regenerate even when the existing material is still valid.

.EXAMPLE
    ./samples/kafka-mtls/setup.ps1

.EXAMPLE
    ./samples/kafka-mtls/setup.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CaSubject     = 'Vouchfx Sample kafka-mtls CA'
$ClientSubject = 'vouchfx-kafka-mtls-client'
$BrokerSubject = 'localhost'
$Days          = 30

$certsDir = Join-Path $PSScriptRoot 'tests' 'certs'

# Staging sits BESIDE the destination so publishing is a rename within one
# filesystem rather than a cross-volume copy. See the publish step.
$stagingDir = "$certsDir.new"

# The seven files the suite declares. Named once, checked once, listed once.
$outputs = @(
    'ca.pem',
    'client.pem', 'client-key.pem',
    'broker.pem', 'broker-key.pem',
    'broker.keystore.pem', 'broker.truststore.pem'
)

# ── Is the existing material still usable? ───────────────────────────────────
# Same three questions as examples/security-mtls.setup.ps1: present, chains to
# the CA beside it, and not within a day of expiring.
function Test-MaterialIsCurrent {
    foreach ($file in $outputs) {
        $path = Join-Path $certsDir $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $path).Length -eq 0) { return $false }
    }

    try {
        $ca = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            [System.IO.File]::ReadAllText((Join-Path $certsDir 'ca.pem')))
    }
    catch {
        return $false
    }

    try {
        if ($ca.NotAfter -le (Get-Date).AddDays(1)) { return $false }

        foreach ($leafFile in @('broker.pem', 'client.pem')) {
            $leaf = $null
            $chain = $null
            try {
                $leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
                    [System.IO.File]::ReadAllText((Join-Path $certsDir $leafFile)))

                $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
                $chain.ChainPolicy.TrustMode =
                    [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
                $chain.ChainPolicy.RevocationMode =
                    [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $null = $chain.ChainPolicy.CustomTrustStore.Add($ca)

                if (-not $chain.Build($leaf)) { return $false }
            }
            catch {
                return $false
            }
            finally {
                if ($null -ne $chain) { $chain.Dispose() }
                if ($null -ne $leaf) { $leaf.Dispose() }
            }
        }

        return $true
    }
    finally {
        $ca.Dispose()
    }
}

# ── Narrow a private key to its owner ────────────────────────────────────────
function Set-OwnerOnlyAccess {
    param([string] $Path)

    if (-not $IsWindows) {
        [System.IO.File]::SetUnixFileMode(
            $Path,
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
        return
    }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) { $null = $acl.RemoveAccessRule($existing) }

    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new(
            $me,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow))

    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not $Force -and (Test-MaterialIsCurrent)) {
    Write-Host "kafka-mtls: certificates in $certsDir are current — nothing to do."
    Write-Host 'kafka-mtls: pass -Force to regenerate them anyway.'
    exit 0
}

# ── Certificate helpers ──────────────────────────────────────────────────────

$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$clientAuthOid = '1.3.6.1.5.5.7.3.2'

function Add-CaExtension {
    param([System.Security.Cryptography.X509Certificates.CertificateRequest] $Request)

    $Request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $true, $false, 0, $true))
    $Request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
    $Request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
            $Request.PublicKey, $false))
}

# Issues one leaf under $Issuer and returns its certificate plus its key in PEM.
function New-Leaf {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Issuer,
        [string] $CommonName,
        [switch] $WithLocalhostSans,
        [datetime] $NotBefore,
        [datetime] $NotAfter
    )

    $key = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$CommonName", $key,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
                $false, $false, 0, $true))
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment, $true))

        $ekus = [System.Security.Cryptography.OidCollection]::new()
        $null = $ekus.Add([System.Security.Cryptography.Oid]::new($serverAuthOid))
        $null = $ekus.Add([System.Security.Cryptography.Oid]::new($clientAuthOid))
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekus, $false))

        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
                $request.PublicKey, $false))

        if ($WithLocalhostSans) {
            $sans = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
            $sans.AddDnsName('localhost')
            $sans.AddDnsName('broker')
            $sans.AddIpAddress([System.Net.IPAddress]::Loopback)
            $request.CertificateExtensions.Add($sans.Build())
        }

        $serial = [byte[]]::new(8)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($serial)

        $signed = $request.Create($Issuer, $NotBefore, $NotAfter, $serial)
        try {
            return [pscustomobject]@{
                CertificatePem = $signed.ExportCertificatePem()
                PrivateKeyPem  = $key.ExportPkcs8PrivateKeyPem()
            }
        }
        finally {
            $signed.Dispose()
        }
    }
    finally {
        $key.Dispose()
    }
}

# ── Generate ─────────────────────────────────────────────────────────────────

Write-Host "kafka-mtls: generating a TEST certificate authority in $certsDir"

$notBefore = (Get-Date).ToUniversalTime().AddMinutes(-5)
$notAfter  = $notBefore.AddDays($Days)

$caKey = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $caRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$CaSubject", $caKey,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    Add-CaExtension -Request $caRequest

    $ca = $caRequest.CreateSelfSigned($notBefore, $notAfter)
    try {
        $caPem = $ca.ExportCertificatePem() + "`n"

        # CN/SAN localhost + broker + 127.0.0.1 — the hostname the client
        # dials for every secured target vouchfx starts.
        $broker = New-Leaf -Issuer $ca -CommonName $BrokerSubject -WithLocalhostSans `
            -NotBefore $notBefore -NotAfter $notAfter

        # No SAN: this identity is never dialled, only presented.
        $client = New-Leaf -Issuer $ca -CommonName $ClientSubject `
            -NotBefore $notBefore -NotAfter $notAfter
    }
    finally {
        $ca.Dispose()
    }
}
finally {
    $caKey.Dispose()
}

# Everything is written into a STAGING DIRECTORY and published by swapping the
# directory itself — see setup.sh's own note on why (an interrupted file-by-
# file publish can leave a set that mixes two authorities and looks complete).
$work = $stagingDir
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $work -Force
try {
    # LF endings and no BOM: the broker's key store is a concatenation of
    # three of these files, and a stray BOM or CRLF inside a PEM block that
    # Kafka's parser did not expect is exactly the kind of thing a byte-exact
    # measurement does not cover on every platform.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    function Write-Pem {
        param([string] $Name, [string] $Content)
        [System.IO.File]::WriteAllText(
            (Join-Path $work $Name), ($Content -replace "`r`n", "`n"), $utf8NoBom)
    }

    Write-Pem 'ca.pem'         $caPem
    Write-Pem 'broker.pem'     ($broker.CertificatePem + "`n")
    Write-Pem 'broker-key.pem' $broker.PrivateKeyPem
    Write-Pem 'client.pem'     ($client.CertificatePem + "`n")
    Write-Pem 'client-key.pem' $client.PrivateKeyPem

    # Keystore = key, then leaf certificate, then CA, concatenated into ONE
    # file — the MEASURED order (see the header note). Truststore is the CA
    # alone.
    Write-Pem 'broker.keystore.pem'   ($broker.PrivateKeyPem + "`n" + $broker.CertificatePem + "`n" + $caPem)
    Write-Pem 'broker.truststore.pem' $caPem

    # Keys are narrowed BEFORE the swap, so they are never briefly readable at
    # the live path.
    foreach ($key in @('client-key.pem', 'broker-key.pem', 'broker.keystore.pem')) {
        Set-OwnerOnlyAccess -Path (Join-Path $work $key)
    }

    if (Test-Path -LiteralPath $certsDir) {
        Remove-Item -LiteralPath $certsDir -Recurse -Force
    }

    Move-Item -LiteralPath $work -Destination $certsDir
}
catch {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    throw
}

Write-Host "kafka-mtls: wrote $($outputs.Count) files to $certsDir"
Write-Host 'kafka-mtls:   ca.pem                 the private CA the broker and client chain to'
Write-Host 'kafka-mtls:   client.pem/-key        the identity the suite presents (security.clientCert/clientKey)'
Write-Host 'kafka-mtls:   broker.pem/-key        the broker''s own leaf identity (pre-concatenation)'
Write-Host 'kafka-mtls:   broker.keystore.pem    the broker''s key store: key, then cert, then CA (serverArtifacts)'
Write-Host 'kafka-mtls:   broker.truststore.pem  the broker''s trust store (= ca.pem) (serverArtifacts)'
Write-Host "kafka-mtls: valid for $Days days. THIS IS TEST MATERIAL — the keys are"
Write-Host 'kafka-mtls: unencrypted and the authority is trusted by nothing. Never reuse it.'
