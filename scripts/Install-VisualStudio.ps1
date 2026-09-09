<#
.SYNOPSIS
    Installs Visual Studio Community with the C++ desktop workload on an AVD image VM.

.DESCRIPTION
    Designed to run under Azure `run-command` (as SYSTEM) so it needs no network
    path to the VM and no interactive logon.

    Contract with the driver: this script NEVER exits 0 without having positively
    verified a working C++ toolchain on disk, and it prints machine-readable
    marker lines that the driver requires to see. Absence of output is treated by
    the driver as failure, not success.

    Dot-source with $env:AVD_VS_LIB_ONLY=1 to load the functions without running.
#>
[CmdletBinding()]
param(
    [string]   $ExpectedVersion = '18.10.0',
    [string]   $BootstrapperUrl = 'https://aka.ms/vs/18/Stable/vs_community.exe',
    [string]   $InstallPath     = 'C:\Program Files\Microsoft Visual Studio\2026\Community',
    [string]   $LogDir          = 'C:\ProgramData\avd-image-setup',
    # A string, not a switch: run-command passes parameters as name=value pairs,
    # and [bool] would coerce the string 'false' to $true.
    # Optional build pin, e.g. '12201.205' for release 18.10.0. Empty = don't check.
    [string]   $ExpectedBuild     = '',
    [ValidateSet('true','false')]
    [string]   $AllowVersionDrift = 'false',
    [string[]] $Workloads = @(
        'Microsoft.VisualStudio.Workload.NativeDesktop'
    ),
    [string[]] $Components = @(
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.VC.CMake.Project',
        'Microsoft.VisualStudio.Component.VC.ATL',
        'Microsoft.VisualStudio.Component.VC.ASAN',
        'Microsoft.VisualStudio.Component.VC.DiagnosticTools',
        'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        'Microsoft.VisualStudio.Component.Vcpkg'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- logging ----

$script:LogFile = $null

# Single output sink for everything humans and the driver read.
#
# This MUST NOT be Write-Output. The success stream is a function's return
# value, so logging with Write-Output makes every caller return its log lines
# alongside (or instead of) its real result - Get-InstalledVs would return a
# string, StrictMode would throw on .Version, and `exit (Invoke-Main)` would
# swallow the entire transcript as the argument to exit. Write-Host is captured
# by run-command as stdout while staying out of the pipeline.
function Out-Line {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host $Text
}

function Initialize-Log {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $script:LogFile = Join-Path $Dir 'install-vs.log'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Out-Line $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
    }
}

# The driver greps for these. Emitted on every exit path, success or failure.
function Write-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('success', 'failed')][string]$Status,
        [string]$Version    = '',
        [string]$Build      = '',
        [string]$Reason     = '',
        [bool]  $RebootNeeded = $false
    )
    Out-Line "AVD_STATUS=$Status"
    Out-Line "AVD_VERSION=$Version"
    Out-Line "AVD_BUILD=$Build"
    Out-Line "AVD_REBOOT_REQUIRED=$($RebootNeeded.ToString().ToLower())"
    Out-Line "AVD_REASON=$Reason"
}

# ------------------------------------------------------------- discovery ----

function Get-VsWherePath {
    # Falls back rather than throwing on a null Join-Path argument, so a missing
    # environment variable surfaces as "vswhere not found" instead of a crash.
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        $programFilesX86 = 'C:\Program Files (x86)'
    }
    # [IO.Path]::Combine rather than Join-Path: it is pure string work and does
    # not consult PowerShell drive providers, so it behaves the same on the
    # Windows guest and on the Linux test container.
    [System.IO.Path]::Combine($programFilesX86, 'Microsoft Visual Studio\Installer\vswhere.exe')
}

# run-command executes as SYSTEM, where TEMP is normally set but not guaranteed
# (and is absent entirely when these functions are exercised under test).
function Get-TempDir {
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { return $env:TEMP }
    return [System.IO.Path]::GetTempPath()
}

# Returns $null when nothing is installed, otherwise a PSCustomObject with
# InstallationPath / Version / ProductId.
function Get-InstalledVs {
    $vswhere = Get-VsWherePath
    if (-not (Test-Path -LiteralPath $vswhere)) {
        Write-Log "vswhere not present at $vswhere - assuming no VS installed."
        return $null
    }

    $raw = & $vswhere -products '*' -format json -utf8 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) {
        Write-Log "vswhere returned no instances (exit $LASTEXITCODE)." -Level WARN
        return $null
    }

    $instances = $raw -join "`n" | ConvertFrom-Json
    if (-not $instances) { return $null }

    $instance = @($instances)[0]

    # installationVersion is major.minor.BUILD.revision (18.10.12201.205) - its
    # third component is the build number, NOT the patch level. The advertised
    # release version lives in catalog.productDisplayVersion (18.10.0). Compare
    # against that; deriving it from installationVersion is not possible.
    [PSCustomObject]@{
        InstallationPath = $instance.installationPath
        Version          = $instance.installationVersion
        DisplayVersion   = $instance.catalog.productDisplayVersion
        BuildVersion     = $instance.catalog.buildVersion
        ProductId        = $instance.productId
        IsComplete       = [bool]$instance.isComplete
    }
}

# When no InstallPath was requested, the installer's default is fine and any
# location passes. When one WAS requested, it must be honoured exactly.
function Test-InstallLocation {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Actual))   { return $false }
    return $Actual.TrimEnd('\') -eq $Expected.TrimEnd('\')
}

# The real proof the workload landed: a usable x64 cl.exe on disk.
function Test-CppToolchain {
    param([Parameter(Mandatory)][string]$InstallationPath)

    $msvcRoot = Join-Path $InstallationPath 'VC\Tools\MSVC'
    if (-not (Test-Path -LiteralPath $msvcRoot)) {
        Write-Log "No MSVC toolset directory at $msvcRoot." -Level ERROR
        return $false
    }

    $cl = Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $cl) {
        Write-Log "MSVC toolset directory exists but no Hostx64/x64 cl.exe found." -Level ERROR
        return $false
    }

    Write-Log "Found C++ compiler: $cl"
    return $true
}

# Compares the advertised release version (e.g. '18.10.0'), optionally pinning
# the build too (e.g. '12201.205'). $Actual should be catalog.productDisplayVersion.
function Test-VersionMatch {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$ActualBuild   = '',
        [string]$ExpectedBuild = ''
    )
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    if ($Actual -ne $Expected) { return $false }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedBuild)) {
        if ([string]::IsNullOrWhiteSpace($ActualBuild)) { return $false }
        # buildVersion is the full 18.10.12201.205; accept either that or the
        # bare 12201.205 that the release-history table publishes.
        if ($ActualBuild -ne $ExpectedBuild -and -not $ActualBuild.EndsWith(".$ExpectedBuild")) {
            return $false
        }
    }
    return $true
}

# ------------------------------------------------------------- installer ----

function Get-Bootstrapper {
    param([string]$Url, [string]$Destination, [int]$MaxAttempts = 3)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Log "Downloading bootstrapper (attempt $attempt/$MaxAttempts): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
            break
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" -Level WARN
            if ($attempt -eq $MaxAttempts) { throw "Bootstrapper download failed after $MaxAttempts attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds (10 * $attempt)
        }
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Bootstrapper missing after download: $Destination"
    }

    # A captive portal or blocked egress yields an HTML error page, not a PE.
    $size = (Get-Item -LiteralPath $Destination).Length
    if ($size -lt 1MB) {
        throw "Bootstrapper is only $size bytes - egress is probably blocked or redirected."
    }
    $header = [System.IO.File]::ReadAllBytes($Destination)[0..1]
    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        throw "Bootstrapper is not a PE executable (no MZ header) - egress is probably intercepted."
    }

    Write-Log "Bootstrapper verified: $size bytes, PE header OK."
    return $Destination
}

# Wraps a value in double quotes when it contains whitespace, so it survives
# Start-Process's unquoted space-joining of -ArgumentList.
function Format-Argument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Invoke-VsSetup {
    param(
        [Parameter(Mandatory)][string]$Bootstrapper,
        [Parameter(Mandatory)][ValidateSet('install', 'modify')][string]$Mode,
        [string]$InstallPath,
        [string[]]$Workloads,
        [string[]]$Components
    )

    $vsArgs = @($Mode, '--quiet', '--wait', '--norestart', '--nocache', '--includeRecommended')

    # Start-Process joins -ArgumentList with spaces and does NOT quote the
    # elements. An unquoted 'C:\Program Files\...' therefore reaches the
    # installer as several arguments, and VS installs to 'C:\Program'. Quote any
    # value containing whitespace ourselves.
    if (-not [string]::IsNullOrWhiteSpace($InstallPath)) {
        $vsArgs += @('--installPath', (Format-Argument $InstallPath))
    }
    foreach ($w in $Workloads)  { $vsArgs += @('--add', (Format-Argument $w)) }
    foreach ($c in $Components) { $vsArgs += @('--add', (Format-Argument $c)) }

    Write-Log "Running: $Bootstrapper $($vsArgs -join ' ')"
    $proc = Start-Process -FilePath $Bootstrapper -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode
    Write-Log "Installer exit code: $code"
    return $code
}

# 0 = done, 3010 = done but needs reboot. Everything else is a real failure.
function Resolve-SetupExitCode {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0     { return @{ Ok = $true;  Reboot = $false; Reason = 'installer completed' } }
        3010  { return @{ Ok = $true;  Reboot = $true;  Reason = 'installer completed, reboot required' } }
        1602  { return @{ Ok = $false; Reboot = $false; Reason = 'installation cancelled (1602)' } }
        1618  { return @{ Ok = $false; Reboot = $false; Reason = 'another install in progress (1618)' } }
        5007  { return @{ Ok = $false; Reboot = $false; Reason = 'blocked by a prerequisite check (5007)' } }
        default { return @{ Ok = $false; Reboot = $false; Reason = "installer failed with exit code $ExitCode" } }
    }
}

# ------------------------------------------------------------------ main ----

function Invoke-Main {
    # Taken as explicit parameters (defaulting to the script parameters) so the
    # decision logic can be driven directly without depending on ambient scope.
    param(
        [string]$Version    = $ExpectedVersion,
        [string]$Build      = $ExpectedBuild,
        [string]$TargetPath = $InstallPath,
        [bool]  $AllowDrift = ($AllowVersionDrift -eq 'true')
    )

    Initialize-Log -Dir $LogDir
    Write-Log "=== AVD image setup: Visual Studio Community $Version (C++) ==="
    Write-Log "Host: $env:COMPUTERNAME  User: $env:USERNAME"

    $rebootNeeded = $false

    try {
        $existing = Get-InstalledVs

        if ($existing -and (Test-VersionMatch -Actual $existing.DisplayVersion -Expected $Version `
                                              -ActualBuild $existing.BuildVersion -ExpectedBuild $Build) `
                       -and (Test-InstallLocation -Actual $existing.InstallationPath -Expected $TargetPath) `
                       -and (Test-CppToolchain -InstallationPath $existing.InstallationPath)) {
            Write-Log "Visual Studio $($existing.DisplayVersion) (build $($existing.BuildVersion)) with C++ toolchain already present at $($existing.InstallationPath) - nothing to do."
            Write-Result -Status success -Version $existing.DisplayVersion -Build $existing.BuildVersion `
                         -Reason 'already installed' -RebootNeeded $false
            return 0
        }

        $mode = if ($existing) { 'modify' } else { 'install' }
        # Named $installTarget, not $targetPath: PowerShell is case-insensitive,
        # so the latter would silently shadow the $TargetPath parameter.
        $installTarget = if ($existing) { $existing.InstallationPath } else { $TargetPath }
        if ($existing) {
            Write-Log "Existing install $($existing.DisplayVersion) at $installTarget is incomplete or mismatched - running '$mode'."
        }

        $tmp = Join-Path (Get-TempDir) 'vs_community.exe'
        Get-Bootstrapper -Url $BootstrapperUrl -Destination $tmp | Out-Null

        $code   = Invoke-VsSetup -Bootstrapper $tmp -Mode $mode -InstallPath $installTarget -Workloads $Workloads -Components $Components
        $status = Resolve-SetupExitCode -ExitCode $code
        if (-not $status.Ok) { throw $status.Reason }
        $rebootNeeded = $status.Reboot
        Write-Log $status.Reason

        # --- verification: never trust the exit code alone -------------------
        $final = Get-InstalledVs
        if (-not $final) { throw 'Post-install verification failed: vswhere reports no VS instance.' }
        Write-Log "Post-install: VS $($final.DisplayVersion) (installationVersion $($final.Version)) at $($final.InstallationPath)"

        # Catches an install that landed somewhere unintended - e.g. a path with
        # spaces that reached the installer unquoted and became 'C:\Program'.
        if (-not (Test-InstallLocation -Actual $final.InstallationPath -Expected $TargetPath)) {
            throw "Post-install verification failed: Visual Studio landed at '$($final.InstallationPath)' but '$TargetPath' was requested."
        }

        if (-not (Test-CppToolchain -InstallationPath $final.InstallationPath)) {
            throw 'Post-install verification failed: no usable x64 cl.exe - the C++ workload did not land.'
        }

        if (-not (Test-VersionMatch -Actual $final.DisplayVersion -Expected $Version `
                                    -ActualBuild $final.BuildVersion -ExpectedBuild $Build)) {
            $msg = "Version drift: expected $Version" +
                   $(if ($Build) { " build $Build" } else { '' }) +
                   " but Stable delivered $($final.DisplayVersion) build $($final.BuildVersion). " +
                   'Community has no fixed-version bootstrapper, so a newer Stable release changes what you get. ' +
                   'Re-run with -AllowVersionDrift once you have decided to accept the new version.'
            if (-not $AllowDrift) { throw $msg }
            Write-Log $msg -Level WARN
        }

        Write-Log 'Verification passed.'
        Write-Result -Status success -Version $final.DisplayVersion -Build $final.BuildVersion `
                     -Reason 'installed and verified' -RebootNeeded $rebootNeeded
        return 0

    } catch {
        Write-Log $_.Exception.Message -Level ERROR
        $v = ''
        try { $cur = Get-InstalledVs; if ($cur) { $v = $cur.Version } } catch { }
        Write-Result -Status failed -Version $v -Reason $_.Exception.Message -RebootNeeded $rebootNeeded
        return 1
    }
}

if (-not $env:AVD_VS_LIB_ONLY) {
    # Assign first: `exit (Invoke-Main)` would consume anything the function
    # emitted on the success stream instead of letting it reach the transcript.
    $exitCode = Invoke-Main
    exit $exitCode
}
