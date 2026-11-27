<#
.SYNOPSIS
    Installs a PyKX query client for every user of an AVD image VM.

.DESCRIPTION
    Puts Python and PyKX in a folder that ordinary users can read but not
    change, so students on a multi-session host can query a kdb+/q server
    without installing anything or holding administrator rights.

    Under -InstallPath (default C:\Program Files\PyKX):
      tools\uv.exe              uv, pinned and checked against -UvSha256
      python\                   the CPython uv downloads (-PythonVersion)
      venv\                     a virtual environment with PyKX (-PykxVersion)
      bin\<prefix>-python.cmd   Python from that environment   (bin is on PATH)
      bin\<prefix>-test.cmd     queries -CheckHost:-CheckPort, if given

    The commands choose PyKX's mode each time they start. A user who has their
    own kdb licence puts kc.lic or k4.lic in OneDrive\<LicenseFolder> (or
    %USERPROFILE%\<LicenseFolder>, or sets QLIC), and PyKX runs licensed, with
    q in the Python process. Without one, the commands set PYKX_UNLICENSED=true
    for that run: PyKX then sends queries to a q server over IPC, cannot run q
    locally and needs no licence. Never put a kdb licence on an image; the
    install fails if the commands find one.

    -DesktopReadme names a text file for the all-users desktop, and
    -DesktopReadmeBase64 carries its contents (base64, so that quotes and
    backticks in examples survive run-command parameter passing).

    If msvcr100.dll, the Visual C++ 2010 runtime PyKX loads on Windows, is
    missing, installs Microsoft's VC++ 2010 SP1 x64 package after checking its
    SHA-256.

    Same contract as the other guest scripts: nothing counts as installed until
    it has been checked, and every exit path prints AVD_ markers. With
    -CheckHost, a query that fails is a failure: the image would not work for
    its users.

    Dot-source with $env:AVD_VS_LIB_ONLY=1 to load the functions without running.
#>
[CmdletBinding()]
param(
    [string] $PykxVersion = '',
    [string] $PythonVersion = '',
    [string] $UvVersion = '',
    [string] $UvSha256 = '',

    # Extra pip requirements, ';'-separated, e.g. 'jupyterlab==4.4.5;pandas'.
    [string] $ExtraPackages = '',

    [string] $InstallPath = 'C:\Program Files\PyKX',

    # Names the user commands: <prefix>-python and <prefix>-test.
    [string] $CommandPrefix = 'pykx',

    # A q server to query once installed. Empty skips the check.
    [string] $CheckHost = '',
    [string] $CheckPort = '',

    # Folder under the user's OneDrive (or profile) the commands look in for
    # a personal kdb licence.
    [string] $LicenseFolder = 'kx',

    # A text file for the all-users desktop: its name, and its contents as
    # base64 UTF-8. Both empty writes none.
    [string] $DesktopReadme = '',
    [string] $DesktopReadmeBase64 = '',

    [ValidateSet('install','remove')]
    [string] $Action = 'install',

    [string] $LogDir = 'C:\ProgramData\avd-image-setup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest crawls with it on

# Microsoft's Visual C++ 2010 SP1 redistributable, x64. A fixed vendor file.
$script:VcUrl    = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'
$script:VcSha256 = 'f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3'
$script:EnvKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:LogFile  = $null

function Out-Line {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host $Text
}

function Initialize-Log {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $script:LogFile = Join-Path $Dir 'install-pykx-client.log'
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
        [string]$Pykx = '',
        [string]$Python = '',
        [string]$Uv = '',
        [ValidateSet('ok','failed','skipped','')][string]$Check = '',
        [string]$Readme = '',
        [string]$Reason = ''
    )
    Out-Line "AVD_STATUS=$Status"
    Out-Line "AVD_PYKX_VERSION=$Pykx"
    Out-Line "AVD_PYTHON_VERSION=$Python"
    Out-Line "AVD_UV_VERSION=$Uv"
    Out-Line "AVD_CHECK=$Check"
    Out-Line "AVD_README=$Readme"
    Out-Line "AVD_REASON=$Reason"
}

# Pure string join; Join-Path consults drive providers and throws for C:\ on
# the Linux test container.
function Join-WindowsPath {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    [System.IO.Path]::Combine($Parent, $Child)
}

# ----------------------------------------------------------- validation -----
# Values arrive as run-command parameters. They end up in file contents and
# command lines, so each must look like what it claims to be.

function Assert-Inputs {
    param(
        [string]$Pykx, [string]$Python, [string]$Uv, [string]$Sha,
        [string]$Prefix, [string]$HostName, [string]$Port,
        [string]$LicenseDir = 'kx', [string]$Readme = '', [string]$ReadmeB64 = ''
    )
    if ($Pykx   -notmatch '^\d+(\.\d+){1,3}$') { throw "PykxVersion '$Pykx' is not a version like 4.2.0." }
    if ($Python -notmatch '^3\.\d+(\.\d+)?$') { throw "PythonVersion '$Python' is not a version like 3.12." }
    if ($Uv     -notmatch '^\d+\.\d+\.\d+$')   { throw "UvVersion '$Uv' is not a version like 0.8.0." }
    if ($Sha    -notmatch '^[0-9a-fA-F]{64}$') { throw 'UvSha256 is not a 64-character hex SHA-256.' }
    if ($Prefix -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') { throw "CommandPrefix '$Prefix' must be letters, digits, '-' or '_'." }
    if ($LicenseDir -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $LicenseDir -match '\.\.') { throw "LicenseFolder '$LicenseDir' must be one folder name." }
    Assert-Readme -Name $Readme -Base64 $ReadmeB64
    if ($HostName -or $Port) {
        if ($HostName -notmatch '^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$') {
            throw "CheckHost '$HostName' is not a host name."
        }
        $n = 0
        if (-not [int]::TryParse($Port, [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
            throw "CheckPort '$Port' is not a port number."
        }
    }
}

# The desktop file: a plain .txt name, and base64 that decodes to at most
# 64 KB of UTF-8. Both or neither.
function Assert-Readme {
    param([string]$Name = '', [string]$Base64 = '')
    if (-not $Name -and -not $Base64) { return }
    if (-not $Name -or -not $Base64) { throw 'DesktopReadme and DesktopReadmeBase64 must be given together.' }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,79}\.txt$' -or $Name -match '\.\.') {
        throw "DesktopReadme '$Name' must be a plain .txt file name."
    }
    [void](ConvertFrom-ReadmeBase64 -Base64 $Base64)
}

function ConvertFrom-ReadmeBase64 {
    param([Parameter(Mandatory)][string]$Base64)
    if ($Base64 -notmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'DesktopReadmeBase64 is not base64.' }
    try { $bytes = [Convert]::FromBase64String($Base64) } catch { throw 'DesktopReadmeBase64 is not base64.' }
    if ($bytes.Length -gt 65536) { throw 'The desktop file is larger than 64 KB.' }
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    # Notepad copes with LF, but CRLF is what every Windows editor expects.
    return (($text -replace "`r`n", "`n") -replace "`n", "`r`n")
}

function Get-PublicDesktop {
    $dir = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = 'C:\Users\Public\Desktop' }
    return $dir
}

# 'a==1;b' -> @('a==1','b'). A pip requirement name with an optional extras
# list and version clause; anything else (spaces, quotes, URLs, options such
# as --index-url) is refused rather than handed to pip.
function ConvertFrom-PackageList {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$List)
    $result = @()
    foreach ($piece in ($List -split ';')) {
        $p = $piece.Trim()
        if (-not $p) { continue }
        if ($p -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._,-]+\])?((==|>=|<=|~=|!=|<|>)[A-Za-z0-9.*+!_-]+(,(==|>=|<=|~=|!=|<|>)[A-Za-z0-9.*+!_-]+)*)?$') {
            throw "Not a package requirement: '$p'"
        }
        $result += $p
    }
    return ,$result
}

# `uv --version` prints e.g. "uv 0.8.0 (0b2357294 2025-07-17)".
function Test-UvVersionText {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Version)
    return [bool]($Text -match ('^uv ' + [regex]::Escape($Version) + '( |$)'))
}

# The .cmd files users run. %~dp0 is the folder the .cmd sits in, so they keep
# working if the install folder is moved.
#
# <prefix>-python decides PyKX's mode on every start: licensed if QLIC is set
# or a kc.lic/k4.lic is in OneDrive\<folder> (personal or work OneDrive) or
# %USERPROFILE%\<folder>; otherwise PYKX_UNLICENSED=true for this run only.
# setlocal keeps both from leaking into the user's console.
function Get-WrapperContent {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$HostName = '',
        [string]$Port = '',
        [string]$LicenseFolder = 'kx'
    )
    $lines = @(
        '@echo off'
        'setlocal'
        "if not defined QLIC if defined OneDrive call :try `"%OneDrive%\$LicenseFolder`""
        "if not defined QLIC if defined OneDriveCommercial call :try `"%OneDriveCommercial%\$LicenseFolder`""
        "if not defined QLIC call :try `"%USERPROFILE%\$LicenseFolder`""
        'if not defined QLIC set "PYKX_UNLICENSED=true"'
        '"%~dp0..\venv\Scripts\python.exe" %*'
        'exit /b'
        ':try'
        'if exist "%~1\kc.lic" set "QLIC=%~1"'
        'if exist "%~1\k4.lic" set "QLIC=%~1"'
        'exit /b 0'
    )
    $w = [ordered]@{}
    $w["$Prefix-python.cmd"] = ($lines -join "`r`n") + "`r`n"
    if ($HostName) {
        $code = "import pykx as kx; q = kx.SyncQConnection('$HostName', $Port, timeout=10); print(q('tables[]')); q.close()"
        $w["$Prefix-test.cmd"] = "@call `"%~dp0$Prefix-python.cmd`" -c `"$code`"`r`n"
    }
    return $w
}

# PATH editing, as pure string functions over the ';'-separated value.
function Add-PathEntry {
    param([AllowEmptyString()][string]$PathValue, [Parameter(Mandatory)][string]$Entry)
    $parts = @($PathValue -split ';' | Where-Object { $_ })
    if ($parts -contains $Entry -or $parts -contains "$Entry\") { return $PathValue }
    return (@($parts) + $Entry) -join ';'
}

function Remove-PathEntry {
    param([AllowEmptyString()][string]$PathValue, [Parameter(Mandatory)][string]$Entry)
    return (@($PathValue -split ';' | Where-Object { $_ -and $_ -ne $Entry -and $_ -ne "$Entry\" })) -join ';'
}

# ------------------------------------------------------------ edges ---------

# The machine PATH without expanding %SystemRoot% and friends, so writing it
# back keeps them as references.
function Get-MachinePath {
    (Get-Item -LiteralPath $script:EnvKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Set-MachinePath {
    param([Parameter(Mandatory)][string]$Value)
    Set-ItemProperty -LiteralPath $script:EnvKey -Name Path -Value $Value -Type ExpandString
}

function Get-MachineVariable { param([string]$Name) [Environment]::GetEnvironmentVariable($Name, 'Machine') }
function Set-MachineVariable { param([string]$Name, [AllowNull()][string]$Value) [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine') }

function Get-VerifiedDownload {
    param([string]$Url, [string]$Sha256, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Url - expected $Sha256, got $actual"
    }
}

# Runs a program and returns its exit code and stdout. stderr is merged in
# but kept as text: Windows PowerShell turns redirected native stderr into
# error records, which 'Stop' would make fatal.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $lines = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($lines -join "`n").Trim() }
}

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    $r = Invoke-Native -File $File -Arguments $Arguments
    if ($r.Text) { foreach ($l in $r.Text -split "`n") { Write-Log "  $l" } }
    if ($r.Code -ne 0) { throw "$([IO.Path]::GetFileName($File)) $($Arguments -join ' ') exited with code $($r.Code)" }
}

function Test-VcRuntime { Test-Path -LiteralPath (Join-WindowsPath $env:SystemRoot 'System32\msvcr100.dll') }

function Install-VcRuntime {
    param([string]$WorkDir)
    $exe = Join-WindowsPath $WorkDir 'vcredist_x64.exe'
    Get-VerifiedDownload -Url $script:VcUrl -Sha256 $script:VcSha256 -OutFile $exe
    $p = Start-Process -FilePath $exe -ArgumentList '/q', '/norestart' -Wait -PassThru
    if (@(0, 3010) -notcontains $p.ExitCode) { throw "vcredist_x64.exe exited with code $($p.ExitCode)" }
    if (-not (Test-VcRuntime)) { throw 'msvcr100.dll is still missing after installing the VC++ 2010 runtime.' }
}

function Install-Uv {
    param([string]$Version, [string]$Sha256, [string]$Destination, [string]$WorkDir)
    $zip = Join-WindowsPath $WorkDir 'uv.zip'
    $url = "https://github.com/astral-sh/uv/releases/download/$Version/uv-x86_64-pc-windows-msvc.zip"
    Get-VerifiedDownload -Url $url -Sha256 $Sha256 -OutFile $zip
    $unzipped = Join-WindowsPath $WorkDir 'uv'
    Expand-Archive -LiteralPath $zip -DestinationPath $unzipped -Force
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath (Join-WindowsPath $unzipped 'uv.exe') -Destination $Destination -Force
}

# The PyKX version importable from the venv, or '' if none.
function Get-PykxVersion {
    param([string]$VenvPython)
    if (-not (Test-Path -LiteralPath $VenvPython)) { return '' }
    $env:PYKX_UNLICENSED = 'true'
    $r = Invoke-Native -File $VenvPython -Arguments @('-c', 'import pykx; print(pykx.__version__)')
    if ($r.Code -ne 0) { return '' }
    return (($r.Text -split "`n")[-1]).Trim()
}

function Get-PythonVersion {
    param([string]$VenvPython)
    $r = Invoke-Native -File $VenvPython -Arguments @('-c', 'import platform; print(platform.python_version())')
    if ($r.Code -ne 0) { return '' }
    return $r.Text.Trim()
}

# ------------------------------------------------------------- main ---------

function Invoke-Remove {
    param([string]$Root, [string]$Readme = '')
    if ($Readme) {
        $file = Join-WindowsPath (Get-PublicDesktop) $Readme
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force; Write-Log "Removed $file" }
    }
    $bin = Join-WindowsPath $Root 'bin'
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
        if (Test-Path -LiteralPath $Root) { throw "Failed to remove $Root" }
        Write-Log "Removed $Root"
    }
    $path = Get-MachinePath
    $new = Remove-PathEntry -PathValue $path -Entry $bin
    if ($new -ne $path) { Set-MachinePath $new; Write-Log "Removed $bin from the machine PATH" }
    if (Get-MachineVariable 'PYKX_UNLICENSED') {
        Set-MachineVariable 'PYKX_UNLICENSED' $null
        Write-Log 'Removed the machine variable PYKX_UNLICENSED'
    }
}

function Invoke-Main {
    # Explicit parameters, defaulting to the script's, so tests can drive the
    # decision logic without depending on ambient scope.
    param(
        [string]$Mode          = $Action,
        [string]$PykxVer       = $PykxVersion,
        [string]$PythonVer     = $PythonVersion,
        [string]$UvVer         = $UvVersion,
        [string]$UvHash        = $UvSha256,
        [string]$Extra         = $ExtraPackages,
        [string]$Root          = $InstallPath,
        [string]$Prefix        = $CommandPrefix,
        [string]$HostName      = $CheckHost,
        [string]$Port          = $CheckPort,
        [string]$LicenseDir    = $LicenseFolder,
        [string]$Readme        = $DesktopReadme,
        [string]$ReadmeB64     = $DesktopReadmeBase64
    )
    Initialize-Log -Dir $LogDir
    Write-Log "=== AVD image setup: PyKX client ($Mode) ==="
    $work = Join-WindowsPath ([IO.Path]::GetTempPath()) "avd-pykx-$PID"

    try {
        if ($Mode -eq 'remove') {
            Invoke-Remove -Root $Root -Readme $Readme
            Write-Result -Status success -Check skipped -Reason "removed $Root"
            return 0
        }

        Assert-Inputs -Pykx $PykxVer -Python $PythonVer -Uv $UvVer -Sha $UvHash `
                      -Prefix $Prefix -HostName $HostName -Port $Port `
                      -LicenseDir $LicenseDir -Readme $Readme -ReadmeB64 $ReadmeB64
        $extraList = ConvertFrom-PackageList -List $Extra

        $tools  = Join-WindowsPath $Root 'tools'
        $bin    = Join-WindowsPath $Root 'bin'
        $venv   = Join-WindowsPath $Root 'venv'
        $uv     = Join-WindowsPath $tools 'uv.exe'
        $venvPy = Join-WindowsPath $venv 'Scripts\python.exe'
        New-Item -ItemType Directory -Force -Path $work, $bin | Out-Null

        # 1. The C runtime PyKX loads.
        if (Test-VcRuntime) { Write-Log 'Visual C++ 2010 runtime present.' }
        else { Write-Log 'Installing the Visual C++ 2010 SP1 x64 runtime.'; Install-VcRuntime -WorkDir $work }

        # 2. uv, used only to build the environment. Not on PATH.
        $uvText = if (Test-Path -LiteralPath $uv) { (Invoke-Native -File $uv -Arguments @('--version')).Text } else { '' }
        if (Test-UvVersionText -Text $uvText -Version $UvVer) { Write-Log "uv $UvVer present." }
        else { Write-Log "Installing uv $UvVer."; Install-Uv -Version $UvVer -Sha256 $UvHash -Destination $uv -WorkDir $work }
        $uvText = (Invoke-Native -File $uv -Arguments @('--version')).Text
        if (-not (Test-UvVersionText -Text $uvText -Version $UvVer)) { throw "uv reports '$uvText', expected $UvVer" }

        # 3. Python and PyKX. uv downloads Python into the install folder, not
        # SYSTEM's profile, and keeps its cache in the temporary folder.
        $env:UV_PYTHON_INSTALL_DIR = Join-WindowsPath $Root 'python'
        $env:UV_CACHE_DIR = Join-WindowsPath $work 'uv-cache'
        $env:UV_NO_PROGRESS = '1'
        $packages = @("pykx==$PykxVer") + $extraList
        $marker = Join-WindowsPath $venv 'avd-requirements.txt'
        $wanted = ($packages + "python=$PythonVer") -join "`n"
        $have = if (Test-Path -LiteralPath $marker) { (Get-Content -Raw -LiteralPath $marker).Trim() } else { '' }
        if ($have -eq $wanted -and (Get-PykxVersion -VenvPython $venvPy) -eq $PykxVer) {
            Write-Log "Python environment already has: $($packages -join ', ')"
        } else {
            Write-Log "Building $venv with Python $PythonVer and $($packages -join ', ')"
            if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
            Invoke-Checked -File $uv -Arguments @('venv', $venv, '--python', $PythonVer, '--python-preference', 'only-managed')
            # Compile now: users cannot write __pycache__ under Program Files.
            Invoke-Checked -File $uv -Arguments (@('pip', 'install', '--python', $venvPy, '--compile-bytecode') + $packages)
            Set-Content -LiteralPath $marker -Value $wanted -Encoding ascii
        }

        # 4. Commands for users.
        $wrappers = Get-WrapperContent -Prefix $Prefix -HostName $HostName -Port $Port -LicenseFolder $LicenseDir
        foreach ($name in $wrappers.Keys) {
            $file = Join-WindowsPath $bin $name
            [IO.File]::WriteAllText($file, $wrappers[$name], [Text.Encoding]::ASCII)
            Write-Log "Wrote $file"
        }

        # 5. Machine settings, read by every new sign-in. The commands choose
        # PyKX's mode themselves; a machine-wide PYKX_UNLICENSED, as earlier
        # versions of this script set, would stop a user's own licence working.
        if (Get-MachineVariable 'PYKX_UNLICENSED') {
            Set-MachineVariable 'PYKX_UNLICENSED' $null
            Write-Log 'Removed the machine variable PYKX_UNLICENSED; the commands set it per run'
        }
        $path = Get-MachinePath
        $newPath = Add-PathEntry -PathValue $path -Entry $bin
        if ($newPath -ne $path) { Set-MachinePath $newPath; Write-Log "Added $bin to the machine PATH" }

        # 6. Verify, rather than trusting the installer's exit codes.
        $pykx = Get-PykxVersion -VenvPython $venvPy
        if ($pykx -ne $PykxVer) { throw "PyKX in $venv reports '$pykx', expected $PykxVer" }
        $python = Get-PythonVersion -VenvPython $venvPy
        if (-not $python.StartsWith("$PythonVer")) { throw "Python in $venv reports '$python', expected $PythonVer" }
        Write-Log "Verified PyKX $pykx on Python $python"

        # The commands, as a user without a licence would run them: nothing
        # inherited from this script's own checks.
        foreach ($v in 'PYKX_UNLICENSED', 'QLIC') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        $cmd = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $pyCmd = Join-WindowsPath $bin "$Prefix-python.cmd"
        # No spaces in the code, so it needs no quotes: given more than two
        # quotes, cmd /c strips the outer pair and breaks the quoted path.
        $r = Invoke-Native -File $cmd -Arguments @('/c', $pyCmd, '-c', "print(__import__('pykx').licensed)")
        $mode = (($r.Text -split "`n")[-1]).Trim()
        if ($r.Code -ne 0) { throw "$Prefix-python failed to import PyKX (exit $($r.Code)): $($r.Text)" }
        if ($mode -ne 'False') {
            throw "$Prefix-python started PyKX licensed ('$mode') with no user licence. A licence file is reachable from this VM; an image must not carry one."
        }
        Write-Log "$Prefix-python falls back to unlicensed mode when the user has no licence"

        # And the other branch: a user with a licence file in their profile.
        # The code imports only os, so the empty stand-in file is never read.
        $fakeHome = Join-WindowsPath $work 'licence-test'
        $fakeDir  = Join-WindowsPath $fakeHome $LicenseDir
        [void][IO.Directory]::CreateDirectory($fakeDir)
        [IO.File]::WriteAllText((Join-WindowsPath $fakeDir 'kc.lic'), '')
        $realHome = $env:USERPROFILE
        try {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $fakeHome, 'Process')
            $code = "print(__import__('os').environ.get('QLIC'),__import__('os').environ.get('PYKX_UNLICENSED'),sep='|')"
            $r = Invoke-Native -File $cmd -Arguments @('/c', $pyCmd, '-c', $code)
        } finally {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $realHome, 'Process')
        }
        $seen = (($r.Text -split "`n")[-1]).Trim()
        if ($r.Code -ne 0 -or $seen -ne "$fakeDir|None") {
            throw "$Prefix-python did not pick up a licence in %USERPROFILE%\$LicenseDir (saw '$seen', expected '$fakeDir|None')"
        }
        Write-Log "$Prefix-python finds a user's licence in %USERPROFILE%\$LicenseDir and runs licensed"

        $readmeFile = ''
        if ($Readme) {
            $readmeFile = Join-WindowsPath (Get-PublicDesktop) $Readme
            $text = ConvertFrom-ReadmeBase64 -Base64 $ReadmeB64
            [IO.File]::WriteAllText($readmeFile, $text, (New-Object System.Text.UTF8Encoding($false)))
            if ([IO.File]::ReadAllText($readmeFile) -ne $text) { throw "$readmeFile does not hold what was written" }
            Write-Log "Wrote $readmeFile"
        }

        $check = 'skipped'
        if ($HostName) {
            $test = Join-WindowsPath $bin "$Prefix-test.cmd"
            $r = Invoke-Native -File $cmd -Arguments @('/c', $test)
            foreach ($l in $r.Text -split "`n") { Write-Log "  $l" }
            if ($r.Code -ne 0) {
                throw "installed, but querying ${HostName}:$Port failed (exit $($r.Code)); is this VM's network allowed by the server's firewall?"
            }
            $check = 'ok'
            Write-Log "Queried ${HostName}:$Port"
        }

        Write-Result -Status success -Pykx $pykx -Python $python -Uv $UvVer -Check $check -Readme $Readme -Reason 'installed and verified'
        return 0

    } catch {
        Write-Log $_.Exception.Message -Level ERROR
        Write-Result -Status failed -Reason $_.Exception.Message
        return 1
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if (-not $env:AVD_VS_LIB_ONLY) {
    $exitCode = Invoke-Main
    exit $exitCode
}
