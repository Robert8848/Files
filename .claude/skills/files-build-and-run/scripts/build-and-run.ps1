<#
.SYNOPSIS
    Build, package, install and launch Files (WinUI 3 / MSIX) from source - non-interactive.

.DESCRIPTION
    Idempotent agent-friendly script. Every step is skipped when already satisfied.
    Exits 0 on success, non-zero on failure with an actionable message on stderr.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-and-run.ps1

.NOTES
    Must run under Windows PowerShell 5.1 - the Appx module (Get-AppxPackage /
    Add-AppxPackage) does not exist in PowerShell 7.
#>
[CmdletBinding()]
param(
    # Repository root. Defaults to the nearest ancestor of this script that contains Files.slnx.
    [string]$RepoRoot = '',
    [string]$Configuration = 'Debug',
    [string]$Platform = 'x64',
    # Trigger a UAC prompt if the signing cert is not yet trusted machine-wide.
    [switch]$ElevateIfNeeded,
    # Install the .NET 10 SDK via winget if it is missing (system change).
    [switch]$InstallMissingSdk,
    # Install the Windows App Runtime if it is missing (per-user, no admin needed).
    [switch]$InstallMissingRuntime,
    # Install the Windows SDK via winget if it is missing (system change, ~1 GB download).
    [switch]$InstallMissingWindowsSdk,
    # Skip the launch/verify stage.
    [switch]$SkipLaunch,
    # Write a PNG screenshot of the desktop after launch.
    [string]$ScreenshotPath = ''
)

$ErrorActionPreference = 'Stop'
$script:Failures = @()

function Write-Step { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host "  [INFO] $Text" }
function Write-Warn { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

if (-not $RepoRoot) {
    if (-not $PSScriptRoot) { Write-Err '-RepoRoot is required when the script is not run from a file.'; exit 2 }
    # Walk up from the script's own folder until the repository root is found. The script
    # lives in <repo>\.claude\skills\files-build-and-run\scripts, so the root is not
    # simply the parent directory.
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path (Join-Path $dir 'Files.slnx')) { $RepoRoot = $dir; break }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    if (-not $RepoRoot) { Write-Err 'Could not locate the repository root (no Files.slnx found above this script).'; exit 2 }
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkDir = $RepoRoot)
    Push-Location $WorkDir
    try {
        # A native command writing to stderr is surfaced as an ErrorRecord when
        # captured with 2>&1. Under $ErrorActionPreference='Stop' that would
        # abort the script even though the tool succeeded, so the preference is
        # relaxed for the duration of the call.
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $FilePath @Arguments 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prevPref }
    } finally { Pop-Location }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}

# ---------------------------------------------------------------- preflight
Write-Step 'Preflight'

if (-not (Test-Path $RepoRoot)) { Write-Err "Repo root not found: $RepoRoot"; exit 2 }
$RepoRoot = (Resolve-Path $RepoRoot).Path
Write-Ok "Repo root: $RepoRoot"

# The Appx module (Get-AppxPackage / Add-AppxPackage) only exists in Windows
# PowerShell 5.1. PowerShell 7 fails with 'Operation is not supported on this
# platform (0x80131539)'.
if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
    Write-Err 'The Appx module is unavailable - this script must run under Windows PowerShell 5.1.'
    Write-Info 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.claude\skills\files-build-and-run\scripts\build-and-run.ps1'
    Write-Info '(pwsh / PowerShell 7 cannot load the Appx module)'
    exit 3
}

# Resolve the dotnet host. A machine where the SDK was just installed still has
# the stale PATH of the calling process, so fall back to the well-known install
# locations instead of concluding that the SDK is missing.
function Resolve-Dotnet {
    $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'))) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

$dotnet = Resolve-Dotnet
if ($dotnet) { $env:PATH = "$(Split-Path -Parent $dotnet);$env:PATH" }

$sdkOk = $false
$sdkVersions = @()
if ($dotnet) { $sdkVersions = @(& $dotnet --list-sdks 2>$null) }
if ($sdkVersions -match '^10\.') { $sdkOk = $true }
if (-not $sdkOk) {
    Write-Warn ".NET 10 SDK missing. Installed: $($sdkVersions -join ', ')"
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($InstallMissingSdk -and $winget) {
        Write-Info 'Installing Microsoft.DotNet.SDK.10 via winget...'
        $r = Invoke-Native 'winget.exe' @('install','--id','Microsoft.DotNet.SDK.10','--source','winget','-e','--accept-package-agreements','--accept-source-agreements','--silent')
        if ($r.ExitCode -ne 0) { Write-Err "winget install failed: $($r.Output)"; exit 3 }
        Write-Ok '.NET 10 SDK installed'
    } else {
        if (-not $winget) {
            Write-Warn 'winget is not available on this machine. Install the .NET 10 SDK manually:'
            Write-Info 'https://dotnet.microsoft.com/download/dotnet/10.0'
            Write-Info 'or without admin:  & ([scriptblock]::Create((Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1).Content)) -Channel 10.0 -InstallDir "$env:LOCALAPPDATA\Microsoft\dotnet"'
        } else {
            Write-Err 'Install it first: winget install --id Microsoft.DotNet.SDK.10 --source winget -e'
            Write-Info 'or re-run this script with -InstallMissingSdk'
        }
        exit 3
    }
    $dotnet = Resolve-Dotnet
    if ($dotnet) { $env:PATH = "$(Split-Path -Parent $dotnet);$env:PATH"; $sdkVersions = @(& $dotnet --list-sdks 2>$null) }
    if ($sdkVersions -notmatch '^10\.') { Write-Err 'Still no .NET 10 SDK after the install attempt'; exit 3 }
} else {
    Write-Ok ".NET 10 SDK present: $(($sdkVersions | Where-Object { $_ -match '^10\.' }) -join ', ')"
}

# Version of the Windows App SDK the project pins (Directory.Packages.props).
function Get-WinAppSdkVersion {
    $props = Join-Path $RepoRoot 'Directory.Packages.props'
    if (-not (Test-Path $props)) { return $null }
    try {
        $xml = [xml](Get-Content $props -Raw)
        $node = $xml.Project.ItemGroup.PackageVersion | Where-Object { $_.Include -eq 'Microsoft.WindowsAppSDK' } | Select-Object -First 1
        if ($node -and $node.Version) { return [string]$node.Version }
    } catch { }
    return $null
}
$winAppSdkVersion = Get-WinAppSdkVersion
if (-not $winAppSdkVersion) { $winAppSdkVersion = '2.5.1' }
$runtimeMinVersion = $winAppSdkVersion

# Only the 2.x framework package matters. The 1.x runtimes report versions like
# 4000.x / 8000.x, so a plain numeric comparison would match them by accident.
$warOk = @(Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.2*' -ErrorAction SilentlyContinue) |
    Where-Object { $_.Version -ge [version]$runtimeMinVersion } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($warOk) {
    Write-Ok "Windows App Runtime present: $($warOk.Name) $($warOk.Version)"
} else {
    Write-Warn "Windows App Runtime 2.x >= $runtimeMinVersion missing."
    $majorMinor = ($winAppSdkVersion -split '\.')[0..1] -join '.'
    $url = "https://aka.ms/windowsappsdk/$majorMinor/$winAppSdkVersion/windowsappruntimeinstall-x64.exe"
    if ($InstallMissingRuntime) {
        $installer = Join-Path $env:TEMP "windowsappruntimeinstall-$majorMinor.exe"
        try {
            Write-Info "Downloading $url"
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
            # Without --force the installer does a per-user install (no admin required).
            Write-Info 'Installing Windows App Runtime (per-user, no elevation)...'
            $p = Start-Process $installer -ArgumentList '--quiet' -Wait -PassThru -WindowStyle Hidden
            if ($p.ExitCode -ne 0) { throw "installer exit code $($p.ExitCode)" }
            Write-Ok 'Windows App Runtime installed'
        } catch {
            Write-Err "Runtime install failed: $($_.Exception.Message)"
            Write-Info "Install it manually: $url  (add --force for a machine-wide install)"
            exit 3
        }
        $warOk = @(Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.2*' -ErrorAction SilentlyContinue) |
            Where-Object { $_.Version -ge [version]$runtimeMinVersion } | Select-Object -First 1
        if (-not $warOk) { Write-Err 'Runtime still not registered after install'; exit 3 }
        Write-Ok "Windows App Runtime present: $($warOk.Name) $($warOk.Version)"
    } else {
        Write-Err "Install it manually: $url  (run with --quiet; add --force for a machine-wide install)"
        Write-Info 'or re-run this script with -InstallMissingRuntime'
        exit 3
    }
}

# --------------------------------------------------------- windows sdk
# cswinrt.exe (the C#/WinRT projection generator) resolves the SDK metadata
# through the registry key 'HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots'.
# Without it the build dies with 'Could not find the Windows SDK in the registry'
# and the XAML compiler then reports a cascade of 'Unknown target type' errors.
$winSdkOk = $false
try {
    $kitsRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
    $winSdkOk = $kitsRoot -and (Test-Path (Join-Path $kitsRoot 'UnionMetadata'))
} catch { }
if ($winSdkOk) {
    Write-Ok "Windows SDK present: $kitsRoot"
} else {
    Write-Warn 'Windows SDK not found. cswinrt.exe needs it to generate the WinRT projections.'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($InstallMissingWindowsSdk -and $winget) {
        Write-Info 'Installing Microsoft.WindowsSDK.10.0.26100 via winget (this downloads ~1 GB and needs elevation)...'
        $r = Invoke-Native 'winget.exe' @('install','--id','Microsoft.WindowsSDK.10.0.26100','--source','winget','-e','--accept-package-agreements','--accept-source-agreements','--silent')
        if ($r.ExitCode -ne 0) { Write-Err "winget install failed: $($r.Output)"; exit 3 }
        try {
            $kitsRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
            $winSdkOk = $kitsRoot -and (Test-Path (Join-Path $kitsRoot 'UnionMetadata'))
        } catch { }
        if (-not $winSdkOk) { Write-Err 'Windows SDK still not registered after the install attempt'; exit 3 }
        Write-Ok "Windows SDK present: $kitsRoot"
    } else {
        Write-Err 'Windows SDK not found. cswinrt.exe needs it to generate the WinRT projections.'
        Write-Info 'winget install --id Microsoft.WindowsSDK.10.0.26100 --source winget -e'
        Write-Info 'or re-run this script with -InstallMissingWindowsSdk'
        exit 3
    }
}

# ------------------------------------------------------- signing certificate
Write-Step 'Signing certificate'

$pfx    = Join-Path $env:TEMP 'FilesApp_SelfSigned.pfx'
$cer    = Join-Path $env:TEMP 'FilesApp_SelfSigned.cer'
$pfxPass = ''

function New-SelfSignedCert {
    # Cert: PSDrive / PKI module are unavailable on some stripped-down Windows images,
    # so the certificate is created through the .NET X509 APIs instead.
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
    $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        'CN=Files', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $eku = New-Object System.Security.Cryptography.OidCollection
    $eku.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.5.5.7.3.3')))
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($eku, $false)))
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false, $false, 0, $true)))
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(3))
    [System.IO.File]::WriteAllBytes($pfx, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12))
    [System.IO.File]::WriteAllBytes($cer, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    return $cert
}

function Test-CertTrusted {
    param([string]$Thumbprint)
    # Machine-wide first: package deployment only honours LocalMachine\Root.
    foreach ($loc in @('LocalMachine', 'CurrentUser')) {
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $loc)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $hit = $store.Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
            $store.Close()
            if ($hit) { return $loc }
        } catch { }
    }
    return $null
}

$cert = $null
if (Test-Path $pfx) {
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx, $pfxPass,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Write-Ok "Existing PFX found: $pfx"
    } catch { Write-Warn "Existing PFX unusable, regenerating"; $cert = $null }
}
if (-not $cert) {
    Write-Info 'Generating self-signed certificate CN=Files...'
    $cert = New-SelfSignedCert
    Write-Ok "PFX written: $pfx"
    Write-Ok "Thumbprint: $($cert.Thumbprint)"
}

$trustedIn = Test-CertTrusted -Thumbprint $cert.Thumbprint
if ($trustedIn -eq 'LocalMachine') {
    Write-Ok 'Certificate trusted in LocalMachine\Root'
} else {
    Write-Warn "Certificate not trusted machine-wide (found in: $(if ($trustedIn) { $trustedIn } else { 'none' }))"
    $elevated = Test-Admin
    if ($elevated) {
        $r = Invoke-Native 'certutil.exe' @('-addstore','-f','Root', $cer)
        if ($r.ExitCode -eq 0) { Write-Ok 'Certificate added to LocalMachine\Root' }
        else { Write-Err "certutil failed: $($r.Output)"; exit 4 }
    } elseif ($ElevateIfNeeded) {
        Write-Info 'Requesting elevation (a UAC prompt appears on the desktop - approve it)...'
        $p = Start-Process -FilePath 'certutil.exe' -ArgumentList '-addstore','-f','Root', $cer -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Ok 'Certificate added to LocalMachine\Root' }
        else { Write-Err "certutil failed with exit code $($p.ExitCode)"; exit 4 }
    } else {
        Write-Err 'Package deployment trusts machine-wide roots only. Run this once as Administrator:'
        Write-Info  "certutil -addstore -f Root `"$cer`""
        Write-Info  'or re-run the script with -ElevateIfNeeded (triggers a UAC prompt).'
        exit 4
    }
}

# ------------------------------------------------------------------ restore
Write-Step 'Restore'

$assets = Join-Path $RepoRoot 'src\Files.App.Server\obj\project.assets.json'
if (Test-Path $assets) {
    Write-Ok 'NuGet assets already restored (skipping)'
} else {
    Write-Info 'dotnet restore Files.slnx  (takes a few minutes)...'
    $r = Invoke-Native 'dotnet.exe' @('restore','Files.slnx','-v:quiet')
    if ($r.ExitCode -ne 0) { Write-Err "restore failed:`n$($r.Output)"; exit 5 }
    Write-Ok 'Restore completed'
}

# ------------------------------------------------------------ build + package
Write-Step 'Build and package'

$buildArgs = @(
    'build', 'src\Files.App\Files.App.csproj',
    '-c', $Configuration,
    "-p:Platform=$Platform",
    '-p:AppxBundle=Never',
    '-p:GenerateAppxPackageOnBuild=true',
    '-p:UapAppxPackageBuildMode=SideloadOnly',
    '-p:AppxPackageSigningEnabled=true',
    "-p:PackageCertificateKeyFile=$pfx",
    "-p:PackageCertificatePassword=$pfxPass",
    '-p:PublishAot=false',
    '-p:SelfContained=false',
    '-p:PublishReadyToRun=false',
    '-v:quiet', '-clp:ErrorsOnly'
)

Write-Info "dotnet build ($Configuration|$Platform) - expect a few minutes..."
$buildStart = Get-Date
$r = Invoke-Native 'dotnet.exe' $buildArgs
if ($r.ExitCode -ne 0) { Write-Err "build failed:`n$($r.Output)"; exit 6 }
Write-Ok 'Build completed'

# The packaging output lands in src\Files.App\AppPackages\<pkg>_<arch>_<cfg>_Test\ (build)
# or next to the publish output in src\Files.App\bin\... (publish). Search both, newest wins.
$msix = @(
    Get-ChildItem -Path (Join-Path $RepoRoot 'src\Files.App\AppPackages') -Filter '*.msix' -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path (Join-Path $RepoRoot 'src\Files.App\bin') -Filter '*.msix' -Recurse -ErrorAction SilentlyContinue
) | Where-Object { $_.FullName -notmatch '\\Dependencies\\' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $msix) { Write-Err 'No .msix produced'; exit 7 }
if ($msix.LastWriteTime -lt $buildStart.AddSeconds(-30)) { Write-Warn 'Found MSIX may be stale' }
Write-Ok "MSIX: $($msix.FullName) ($([math]::Round($msix.Length/1MB,1)) MB)"

# ------------------------------------------------------------------- install
Write-Step 'Install'

# A rebuild changes the package payload, so Windows refuses to overwrite an existing
# registration of the same identity (0x80073CFB). Remove it first.
$existing = Get-AppxPackage -Name 'FilesDev' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    # A running Files.exe holds files inside the package install location, which makes
    # the removal (and the re-install) fail. Stop it before touching the registration.
    $running = Get-Process -Name Files -ErrorAction SilentlyContinue
    if ($running) {
        Write-Info "Stopping running Files process (pid $($running.Id -join ', '))..."
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Info "Removing existing registration $($existing.PackageFullName)..."
    try {
        Remove-AppxPackage -Package $existing.PackageFullName -PreserveApplicationData -ErrorAction Stop
    } catch {
        Remove-AppxPackage -Package $existing.PackageFullName -ErrorAction Stop
    }
    Start-Sleep -Seconds 3
}

$r = Invoke-Native 'powershell.exe' @('-NoProfile','-Command', "Add-AppxPackage -Path '$($msix.FullName)' -ErrorAction Stop")
if ($r.ExitCode -ne 0) { Write-Err "Add-AppxPackage failed:`n$($r.Output)"; exit 8 }

$pkg = Get-AppxPackage -Name 'FilesDev' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) { Write-Err 'Package not registered after install'; exit 9 }
Write-Ok "Installed: $($pkg.Name) $($pkg.Version) (Status=$($pkg.Status))"

# -------------------------------------------------------------------- launch
if ($SkipLaunch) { Write-Step 'Launch skipped (-SkipLaunch)'; exit 0 }

Write-Step 'Launch and verify'

Get-Process -Name Files -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$launched = $false
try { Start-Process 'files-dev.exe' -ErrorAction Stop; $launched = $true } catch { Write-Warn 'files-dev.exe alias not found, falling back to installed exe' }
if (-not $launched) {
    $exe = Join-Path $pkg.InstallLocation 'Files.exe'
    Start-Process $exe -ErrorAction Stop
}

$proc = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $proc = Get-Process -Name Files -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($proc) { break }
}
if (-not $proc) { Write-Err 'Application did not present a window within 60s'; exit 10 }

# The splash screen already owns a window handle titled 'Files'; wait for the real
# main window ('Home - Files' / '主页 - Files') before declaring success.
$title = ''
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $proc.Refresh()
    $title = $proc.MainWindowTitle
    if ($title -and $title -ne 'Files') { break }
}
Write-Ok "Running: pid=$($proc.Id) title='$title'"

# Bring the window to the front so a screenshot proves the UI is actually rendered.
# SetForegroundWindow alone is ignored for background processes, so the window is
# temporarily promoted to TOPMOST and then demoted again.
try {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FilesAgentWin32 {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    public static void BringToFront(IntPtr hWnd) {
        const uint SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
        IntPtr topmost = new IntPtr(-1), notTopmost = new IntPtr(-2);
        ShowWindow(hWnd, 9); // SW_RESTORE
        SetWindowPos(hWnd, topmost, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetWindowPos(hWnd, notTopmost, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW | SWP_NOACTIVATE);
        SetForegroundWindow(hWnd);
    }
}
'@ -ErrorAction SilentlyContinue
    [FilesAgentWin32]::BringToFront($proc.MainWindowHandle)
    Start-Sleep -Seconds 3
} catch { Write-Warn 'Could not raise the window to the foreground' }

if ($ScreenshotPath) {
    # Tolerate a literal '$env:TEMP\...' prefix (the value may come from a non-PowerShell shell)
    # and resolve relative paths against the repo root.
    if ($ScreenshotPath -like '$env:TEMP*') {
        $ScreenshotPath = $env:TEMP + $ScreenshotPath.Substring('$env:TEMP'.Length)
    }
    if (-not [System.IO.Path]::IsPathRooted($ScreenshotPath)) {
        $ScreenshotPath = Join-Path $RepoRoot $ScreenshotPath
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $bmp.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Ok "Screenshot: $ScreenshotPath"
    } catch { Write-Warn "Screenshot failed: $($_.Exception.Message)" }
}

Write-Step 'Done'
Write-Ok 'Files is built, installed and running.'
exit 0
