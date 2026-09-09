<#
.SYNOPSIS
    Removes a Visual Studio instance from the image VM by installation path.

.DESCRIPTION
    Written to clean up an install that landed in the wrong directory (an
    unquoted path with spaces reaches the installer as several arguments, so
    'C:\Program Files\...' becomes 'C:\Program'). Also useful to reset the image
    before a clean reinstall.

    Follows the same contract as the installer: it verifies the instance is
    actually gone before reporting success, and prints markers on every exit
    path so the driver never has to infer anything from silence.

    Dot-source with $env:AVD_VS_LIB_ONLY=1 to load the functions without running.
#>
[CmdletBinding()]
param(
    # The instance to remove. Required, so this can never sweep up an unrelated
    # install by accident.
    [Parameter(Mandatory)]
    [string] $TargetInstallPath,

    # Remove the install directory afterwards, but ONLY when it is empty.
    [ValidateSet('true','false')]
    [string] $RemoveEmptyDirectory = 'true',

    [string] $LogDir = 'C:\ProgramData\avd-image-setup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Out-Line {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host $Text
}

function Initialize-Log {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $script:LogFile = Join-Path $Dir 'uninstall-vs.log'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Out-Line $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 }
}

function Write-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('success','failed')][string]$Status,
        [string]$Reason = ''
    )
    Out-Line "AVD_STATUS=$Status"
    Out-Line "AVD_REASON=$Reason"
}

function Get-VsWherePath {
    $pf = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($pf)) { $pf = 'C:\Program Files (x86)' }
    [System.IO.Path]::Combine($pf, 'Microsoft Visual Studio\Installer\vswhere.exe')
}

function Get-SetupEnginePath {
    $pf = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($pf)) { $pf = 'C:\Program Files (x86)' }
    [System.IO.Path]::Combine($pf, 'Microsoft Visual Studio\Installer\setup.exe')
}

# All instances vswhere knows about, as objects with Path/DisplayVersion.
function Get-VsInstances {
    $vswhere = Get-VsWherePath
    if (-not (Test-Path -LiteralPath $vswhere)) {
        Write-Log "vswhere not present at $vswhere - nothing installed." -Level WARN
        return @()
    }
    $raw = & $vswhere -products '*' -format json -utf8 2>$null
    if ([string]::IsNullOrWhiteSpace(($raw -join ''))) { return @() }

    $parsed = $raw -join "`n" | ConvertFrom-Json
    if (-not $parsed) { return @() }

    @($parsed) | ForEach-Object {
        [PSCustomObject]@{
            Path           = $_.installationPath
            DisplayVersion = $_.catalog.productDisplayVersion
        }
    }
}

function Test-PathMatch {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    return $Actual.TrimEnd('\') -eq $Expected.TrimEnd('\')
}

function Format-Argument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Invoke-VsUninstall {
    param([Parameter(Mandatory)][string]$InstallPath)

    $setup = Get-SetupEnginePath
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "Visual Studio setup engine not found at $setup - cannot uninstall."
    }

    # NOTE: 'setup.exe uninstall' does NOT support --wait (the bootstrapper does).
    # Passing it fails immediately with exit code 87, "Option 'wait' is unknown".
    # Because there is no --wait, the process may return before the uninstall has
    # finished, so the caller polls vswhere for actual removal.
    #
    # Quoted: Start-Process joins -ArgumentList unquoted, which is what put the
    # install in the wrong place to begin with.
    $vsArgs = @('uninstall', '--installPath', (Format-Argument $InstallPath),
                '--quiet', '--norestart', '--force')

    Write-Log "Running: $setup $($vsArgs -join ' ')"
    $proc = Start-Process -FilePath $setup -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
    return $proc.ExitCode
}

# setup.exe has no --wait for uninstall, so the process exiting proves nothing.
# Poll vswhere until the instance is actually gone.
function Wait-ForRemoval {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [int]$TimeoutSeconds = 1800,
        [int]$PollSeconds    = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $remaining = @(Get-VsInstances) | Where-Object { Test-PathMatch -Actual $_.Path -Expected $InstallPath }
        if (-not $remaining) { return $true }
        Write-Log "still present, waiting for uninstall to finish..."
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Invoke-Main {
    param([string]$Target = $TargetInstallPath)

    Initialize-Log -Dir $LogDir
    Write-Log "=== AVD image cleanup: remove Visual Studio at '$Target' ==="

    try {
        $before = @(Get-VsInstances)
        Write-Log "Instances found: $($before.Count)"
        foreach ($i in $before) { Write-Log "  $($i.DisplayVersion) at $($i.Path)" }

        $match = $before | Where-Object { Test-PathMatch -Actual $_.Path -Expected $Target }
        if (-not $match) {
            Write-Log "No instance at '$Target' - nothing to remove."
            Write-Result -Status success -Reason 'no matching instance; nothing to do'
            return 0
        }

        $code = Invoke-VsUninstall -InstallPath $Target
        if ($code -ne 0 -and $code -ne 3010) {
            throw "Uninstaller failed with exit code $code."
        }

        # Verify, rather than trusting the exit code. Without --wait the process
        # can return before the work is done, so allow time for it to complete.
        if (-not (Wait-ForRemoval -InstallPath $Target)) {
            throw "Uninstaller reported $code but vswhere still lists an instance at '$Target' after waiting."
        }
        $after = @(Get-VsInstances)
        Write-Log "Confirmed: no instance remains at '$Target'. Instances now: $($after.Count)"

        if ($RemoveEmptyDirectory -eq 'true' -and (Test-Path -LiteralPath $Target)) {
            $leftovers = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue)
            if ($leftovers.Count -eq 0) {
                Remove-Item -LiteralPath $Target -Force
                Write-Log "Removed empty directory '$Target'."
            } else {
                Write-Log "Directory '$Target' still holds $($leftovers.Count) item(s); leaving it in place for review." -Level WARN
            }
        }

        Write-Result -Status success -Reason "removed instance at $Target"
        return 0

    } catch {
        Write-Log $_.Exception.Message -Level ERROR
        Write-Result -Status failed -Reason $_.Exception.Message
        return 1
    }
}

if (-not $env:AVD_VS_LIB_ONLY) {
    $exitCode = Invoke-Main
    exit $exitCode
}
