<#
.SYNOPSIS
    Places shortcuts on the all-users desktop of an AVD image VM.

.DESCRIPTION
    Writes to the Public Desktop (C:\Users\Public\Desktop), which every user of a
    multi-session host sees regardless of FSLogix profile state. That makes it
    the right place for "everyone gets this icon" on a golden image.

    Where the application already registered a Start Menu shortcut, that .lnk is
    copied rather than synthesised, so the icon, arguments and any Click-to-Run
    shim match exactly what the vendor intended.

    Same contract as the installer: verifies each shortcut resolves to a file
    that exists, and prints markers on every exit path.

    -Shortcuts takes 'Name=Target' pairs separated by ';', e.g.
      "Excel=C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE;Word=..."

    Dot-source with $env:AVD_VS_LIB_ONLY=1 to load the functions without running.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Shortcuts,

    # Remove a listed shortcut instead of creating it.
    [ValidateSet('create','remove')]
    [string] $Action = 'create',

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
    $script:LogFile = Join-Path $Dir 'set-shortcuts.log'
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
        [int]$Count  = 0,
        [string]$Reason = ''
    )
    Out-Line "AVD_STATUS=$Status"
    Out-Line "AVD_SHORTCUT_COUNT=$Count"
    Out-Line "AVD_REASON=$Reason"
}

function Get-PublicDesktop {
    $dir = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = 'C:\Users\Public\Desktop' }
    return $dir
}

function Get-StartMenuRoot { 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' }

# Pure string join. Join-Path consults PowerShell drive providers, so a Windows
# path like 'C:\Users\Public\Desktop' throws "drive C does not exist" on the
# Linux test container.
function Join-WindowsPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )
    [System.IO.Path]::Combine($Parent, $Child)
}

# "A=1;B=2" -> ordered list of @{ Name; Target }. Rejects malformed input rather
# than silently skipping it, so a typo cannot quietly produce zero shortcuts.
function ConvertFrom-ShortcutSpec {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Spec)

    $result = @()
    foreach ($piece in ($Spec -split ';')) {
        $trimmed = $piece.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1 -or $idx -eq ($trimmed.Length - 1)) {
            throw "Malformed shortcut spec '$trimmed' - expected 'Name=Target'."
        }
        $result += [PSCustomObject]@{
            Name   = $trimmed.Substring(0, $idx).Trim()
            Target = $trimmed.Substring($idx + 1).Trim()
        }
    }
    if ($result.Count -eq 0) { throw 'No shortcuts given.' }
    return $result
}

# Reads a .lnk's target without needing the file to be valid.
function Get-ShortcutTarget {
    param([Parameter(Mandatory)][string]$LnkPath)
    $shell = New-Object -ComObject WScript.Shell
    try {
        return $shell.CreateShortcut($LnkPath).TargetPath
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string]$LnkPath,
        [Parameter(Mandatory)][string]$Target
    )
    $shell = New-Object -ComObject WScript.Shell
    try {
        $sc = $shell.CreateShortcut($LnkPath)
        $sc.TargetPath       = $Target
        $sc.WorkingDirectory = Split-Path -Parent $Target
        $sc.Description      = [IO.Path]::GetFileNameWithoutExtension($Target)
        $sc.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# Prefer the vendor's own Start Menu shortcut so the icon and arguments match.
function Find-StartMenuShortcut {
    param([Parameter(Mandatory)][string]$Name)
    $candidate = Join-WindowsPath -Parent (Get-StartMenuRoot) -Child "$Name.lnk"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Set-OneShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$DesktopDir
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Target for '$Name' does not exist: $Target"
    }

    $lnk = Join-WindowsPath -Parent $DesktopDir -Child "$Name.lnk"

    if (Test-Path -LiteralPath $lnk) {
        $existing = Get-ShortcutTarget -LnkPath $lnk
        if ($existing -eq $Target) {
            Write-Log "'$Name' already points at $Target - leaving it alone."
            return $true
        }
        Write-Log "'$Name' points at '$existing', replacing with '$Target'." -Level WARN
    }

    $source = Find-StartMenuShortcut -Name $Name
    if ($source) {
        Write-Log "Copying vendor shortcut $source"
        Copy-Item -LiteralPath $source -Destination $lnk -Force
    } else {
        Write-Log "No Start Menu shortcut for '$Name'; creating one pointing at $Target"
        New-Shortcut -LnkPath $lnk -Target $Target
    }

    # Verify, rather than assuming the copy/create worked.
    if (-not (Test-Path -LiteralPath $lnk)) {
        throw "Shortcut for '$Name' was not created at $lnk"
    }
    $resolved = Get-ShortcutTarget -LnkPath $lnk
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Shortcut '$Name' has no target after creation."
    }
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Shortcut '$Name' resolves to a missing file: $resolved"
    }
    Write-Log "Verified '$Name' -> $resolved"
    return $true
}

function Remove-OneShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DesktopDir
    )
    $lnk = Join-WindowsPath -Parent $DesktopDir -Child "$Name.lnk"
    if (-not (Test-Path -LiteralPath $lnk)) {
        Write-Log "'$Name' is not on the public desktop - nothing to remove."
        return $true
    }
    Remove-Item -LiteralPath $lnk -Force
    if (Test-Path -LiteralPath $lnk) { throw "Failed to remove $lnk" }
    Write-Log "Removed $lnk"
    return $true
}

function Invoke-Main {
    param(
        [string]$Spec = $Shortcuts,
        [string]$Mode = $Action
    )

    Initialize-Log -Dir $LogDir
    Write-Log "=== AVD image setup: public desktop shortcuts ($Mode) ==="

    try {
        $desktop = Get-PublicDesktop
        Write-Log "Public desktop: $desktop"
        if (-not (Test-Path -LiteralPath $desktop)) {
            throw "Public desktop directory not found: $desktop"
        }

        $wanted = @(ConvertFrom-ShortcutSpec -Spec $Spec)
        Write-Log "Requested $($wanted.Count) shortcut(s)."

        $done = 0
        foreach ($s in $wanted) {
            if ($Mode -eq 'remove') {
                Remove-OneShortcut -Name $s.Name -DesktopDir $desktop | Out-Null
            } else {
                Set-OneShortcut -Name $s.Name -Target $s.Target -DesktopDir $desktop | Out-Null
            }
            Out-Line "AVD_SHORTCUT_OK=$($s.Name)"
            $done++
        }

        if ($done -ne $wanted.Count) {
            throw "Processed $done of $($wanted.Count) shortcuts."
        }

        Write-Log "All $done shortcut(s) $Mode`d and verified."
        Write-Result -Status success -Count $done -Reason "$Mode completed for $done shortcut(s)"
        return 0

    } catch {
        Write-Log $_.Exception.Message -Level ERROR
        Write-Result -Status failed -Count 0 -Reason $_.Exception.Message
        return 1
    }
}

if (-not $env:AVD_VS_LIB_ONLY) {
    $exitCode = Invoke-Main
    exit $exitCode
}
