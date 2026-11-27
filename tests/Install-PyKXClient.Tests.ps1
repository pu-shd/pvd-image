#Requires -Modules Pester
<#
    Pester tests for Install-PyKXClient.ps1.

    Downloads, uv, Python and the registry are mocked. What is tested is the
    logic that decides what reaches a command line or a file (input validation,
    the package list, the user commands), the PATH editing, and the contract:
    nothing is reported installed until the installed versions are read back,
    and a configured check that fails makes the run fail.
#>

BeforeAll {
    $env:AVD_VS_LIB_ONLY = '1'
    $script:PyKXScript = Join-Path $PSScriptRoot '..' 'scripts' 'Install-PyKXClient.ps1'
    . $script:PyKXScript
}

AfterAll {
    Remove-Item Env:\AVD_VS_LIB_ONLY -ErrorAction SilentlyContinue
}

Describe 'PyKX script is valid PowerShell as shipped' {
    BeforeAll {
        $script:PErrors = $null
        $script:PAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:PyKXScript, [ref]$null, [ref]$script:PErrors)
    }
    It 'parses with no errors' { $script:PErrors | Should -BeNullOrEmpty }
    It 'has param() as its first statement' { $script:PAst.ParamBlock | Should -Not -BeNullOrEmpty }
    It 'exposes every parameter the driver passes' {
        $names = $script:PAst.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($n in 'Action','InstallPath','PykxVersion','PythonVersion','UvVersion','UvSha256',
                       'CommandPrefix','ExtraPackages','CheckHost','CheckPort') {
            $names | Should -Contain $n
        }
    }
    It 'pins the VC++ runtime download to a SHA-256' {
        $script:VcSha256 | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Assert-Inputs' {
    BeforeAll {
        $script:Good = @{
            Pykx = '4.2.0'; Python = '3.12'; Uv = '0.8.0'
            Sha = ('a' * 64); Prefix = 'hfm'; HostName = 'q.example.invalid'; Port = '6005'
        }
    }
    It 'accepts good values' { { Assert-Inputs @script:Good } | Should -Not -Throw }
    It 'accepts no check host and no port' {
        $v = $script:Good.Clone(); $v.HostName = ''; $v.Port = ''
        { Assert-Inputs @v } | Should -Not -Throw
    }
    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a PyKX version with a command after it'; Key = 'Pykx';     Value = '4.2.0;calc' }
        @{ Name = 'Python 2';                                Key = 'Python';   Value = '2.7' }
        @{ Name = 'a uv version with two parts';             Key = 'Uv';       Value = '0.8' }
        @{ Name = 'a short SHA-256';                         Key = 'Sha';      Value = 'abc' }
        @{ Name = 'a prefix with a space';                   Key = 'Prefix';   Value = 'hfm test' }
        @{ Name = 'a prefix with a path separator';          Key = 'Prefix';   Value = '..\evil' }
        @{ Name = 'a host with a quote';                     Key = 'HostName'; Value = "q'); import os; ('" }
        @{ Name = 'a port of 0';                             Key = 'Port';     Value = '0' }
        @{ Name = 'a port above 65535';                      Key = 'Port';     Value = '65536' }
        @{ Name = 'a port that is not a number';             Key = 'Port';     Value = '60x5' }
    ) {
        $v = $script:Good.Clone(); $v[$Key] = $Value
        { Assert-Inputs @v } | Should -Throw
    }
    It 'refuses a port with no host' {
        $v = $script:Good.Clone(); $v.HostName = ''
        { Assert-Inputs @v } | Should -Throw
    }
}

Describe 'ConvertFrom-PackageList' {
    It 'returns an empty list for an empty string' {
        $r = ConvertFrom-PackageList -List ''
        @($r).Count | Should -Be 0
    }
    It 'splits on semicolons and trims' {
        $r = ConvertFrom-PackageList -List ' jupyterlab==4.4.5 ; pandas;'
        $r | Should -Be @('jupyterlab==4.4.5', 'pandas')
    }
    It 'accepts extras and a compound version clause' {
        $r = ConvertFrom-PackageList -List 'pykx[pyarrow]>=4.2,<5'
        $r | Should -Be @('pykx[pyarrow]>=4.2,<5')
    }
    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a pip option';        Value = '--index-url=https://example.invalid' }
        @{ Name = 'a URL';               Value = 'https://example.invalid/x.whl' }
        @{ Name = 'a space in a name';   Value = 'pandas numpy' }
        @{ Name = 'a quote';             Value = 'pandas"' }
        @{ Name = 'a local path';        Value = 'C:\temp\x.whl' }
    ) {
        { ConvertFrom-PackageList -List $Value } | Should -Throw -ExpectedMessage '*Not a package requirement*'
    }
}

Describe 'Test-UvVersionText' {
    It 'matches uv''s own output' { Test-UvVersionText -Text 'uv 0.8.0 (0b2357294 2025-07-17)' -Version '0.8.0' | Should -BeTrue }
    It 'matches bare output'      { Test-UvVersionText -Text 'uv 0.8.0' -Version '0.8.0' | Should -BeTrue }
    It 'does not take 0.8.01 for 0.8.0' { Test-UvVersionText -Text 'uv 0.8.01' -Version '0.8.0' | Should -BeFalse }
    It 'does not take 0.8.10 for 0.8.1' { Test-UvVersionText -Text 'uv 0.8.10 (x)' -Version '0.8.1' | Should -BeFalse }
    It 'treats a dot in the pin literally' { Test-UvVersionText -Text 'uv 0x8x0' -Version '0.8.0' | Should -BeFalse }
    It 'is false for no output' { Test-UvVersionText -Text '' -Version '0.8.0' | Should -BeFalse }
}

Describe 'Get-WrapperContent' {
    It 'always writes PREFIX-python, passing arguments through' {
        $w = Get-WrapperContent -Prefix 'hfm'
        $w.Keys | Should -Contain 'hfm-python.cmd'
        $w['hfm-python.cmd'] | Should -BeLike '*venv\Scripts\python.exe" %*'
    }
    It 'finds the venv relative to the .cmd itself' {
        (Get-WrapperContent -Prefix 'hfm')['hfm-python.cmd'] | Should -BeLike '*%~dp0..\venv*'
    }
    It 'writes no test command without a check host' {
        (Get-WrapperContent -Prefix 'hfm').Keys | Should -Not -Contain 'hfm-test.cmd'
    }
    It 'writes PREFIX-test with the host, port and a timeout' {
        $t = (Get-WrapperContent -Prefix 'hfm' -HostName 'q.example.invalid' -Port '6005')['hfm-test.cmd']
        $t | Should -BeLike "*SyncQConnection('q.example.invalid', 6005, timeout=10)*"
        $t | Should -BeLike "*tables``[``]*"
    }
    It 'uses CRLF line endings for cmd.exe' {
        (Get-WrapperContent -Prefix 'hfm')['hfm-python.cmd'] | Should -BeLike "*`r`n"
    }
}

Describe 'PATH editing' {
    BeforeAll { $script:Bin = 'C:\Program Files\HFM\bin' }
    It 'appends a new entry' {
        Add-PathEntry -PathValue '%SystemRoot%\system32;C:\x' -Entry $script:Bin |
            Should -Be "%SystemRoot%\system32;C:\x;$($script:Bin)"
    }
    It 'keeps %SystemRoot% unexpanded' {
        Add-PathEntry -PathValue '%SystemRoot%\system32' -Entry $script:Bin | Should -BeLike '%SystemRoot%*'
    }
    It 'does not add an entry twice' {
        $p = "C:\x;$($script:Bin)"
        Add-PathEntry -PathValue $p -Entry $script:Bin | Should -Be $p
    }
    It 'treats a trailing backslash as the same entry' {
        $p = "C:\x;$($script:Bin)\"
        Add-PathEntry -PathValue $p -Entry $script:Bin | Should -Be $p
    }
    It 'works on an empty PATH' { Add-PathEntry -PathValue '' -Entry $script:Bin | Should -Be $script:Bin }
    It 'removes only its own entry' {
        Remove-PathEntry -PathValue "C:\a;$($script:Bin);C:\b" -Entry $script:Bin | Should -Be 'C:\a;C:\b'
    }
    It 'leaves a PATH without the entry unchanged' {
        Remove-PathEntry -PathValue 'C:\a;C:\b' -Entry $script:Bin | Should -Be 'C:\a;C:\b'
    }
    It 'does not remove a longer path that starts the same' {
        Remove-PathEntry -PathValue "$($script:Bin)2" -Entry $script:Bin | Should -Be "$($script:Bin)2"
    }
}

Describe 'Invoke-Main' {
    BeforeEach {
        $script:Machine = @{ Path = '%SystemRoot%\system32'; PYKX_UNLICENSED = $null }
        $script:Written = @{}
        $script:UvCalls = @()
        $script:PykxReported = '4.2.0'
        $script:CheckExit = 0

        Mock Out-Line { }
        Mock Write-Log { }
        Mock Initialize-Log { }
        Mock New-Item { }
        Mock Remove-Item { }
        Mock Set-Content { }
        Mock Test-Path { $false }
        Mock Test-VcRuntime { $true }
        Mock Install-VcRuntime { }
        Mock Install-Uv { }
        Mock Get-MachinePath { $script:Machine.Path }
        Mock Set-MachinePath { param($Value) $script:Machine.Path = $Value }
        Mock Get-MachineVariable { param($Name) $script:Machine[$Name] }
        Mock Set-MachineVariable { param($Name, $Value) $script:Machine[$Name] = $Value }
        Mock Get-PykxVersion { $script:PykxReported }
        Mock Get-PythonVersion { '3.12.11' }
        Mock Invoke-Native {
            param($File, $Arguments)
            if ($Arguments -contains '--version') { return [pscustomobject]@{ Code = 0; Text = 'uv 0.8.0 (x 2025-07-17)' } }
            if ($Arguments -contains '/c') { return [pscustomobject]@{ Code = $script:CheckExit; Text = 'instinfo quote trade' } }
            $script:UvCalls += ,@($Arguments)
            return [pscustomobject]@{ Code = 0; Text = '' }
        }
        Mock Invoke-Checked { param($File, $Arguments) $script:UvCalls += ,@($Arguments) }

        $script:Root = Join-Path ([IO.Path]::GetTempPath()) "pykx-test-$(Get-Random)"
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($script:Root, 'bin'))
        $script:MainArgs = @{
            Mode = 'install'; PykxVer = '4.2.0'; PythonVer = '3.12'; UvVer = '0.8.0'
            UvHash = ('a' * 64); Extra = ''; Root = $script:Root; Prefix = 'hfm'
            HostName = ''; Port = ''
        }
    }
    AfterEach {
        [IO.Directory]::Delete($script:Root, $true)
    }

    It 'succeeds and reports the versions it read back' {
        Invoke-Main @script:MainArgs | Should -Be 0
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_STATUS=success' }
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_PYKX_VERSION=4.2.0' }
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_PYTHON_VERSION=3.12.11' }
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_CHECK=skipped' }
    }
    It 'pins PyKX and compiles bytecode' {
        Invoke-Main @script:MainArgs | Out-Null
        $pip = $script:UvCalls | Where-Object { $_[0] -eq 'pip' }
        $pip | Should -Contain 'pykx==4.2.0'
        $pip | Should -Contain '--compile-bytecode'
    }
    It 'builds the venv from a uv-managed Python only' {
        Invoke-Main @script:MainArgs | Out-Null
        $venv = $script:UvCalls | Where-Object { $_[0] -eq 'venv' }
        $venv | Should -Contain 'only-managed'
    }
    It 'sets PYKX_UNLICENSED and puts bin on the machine PATH' {
        Invoke-Main @script:MainArgs | Out-Null
        $script:Machine.PYKX_UNLICENSED | Should -Be 'true'
        $script:Machine.Path | Should -BeLike "%SystemRoot%\system32;*bin"
    }
    It 'writes the user commands' {
        $script:MainArgs.HostName = 'q.example.invalid'; $script:MainArgs.Port = '6005'
        Invoke-Main @script:MainArgs | Out-Null
        [IO.File]::Exists([IO.Path]::Combine($script:Root, 'bin', 'hfm-python.cmd')) | Should -BeTrue
        [IO.File]::Exists([IO.Path]::Combine($script:Root, 'bin', 'hfm-test.cmd')) | Should -BeTrue
    }
    It 'installs the VC++ runtime only when msvcr100.dll is missing' {
        Invoke-Main @script:MainArgs | Out-Null
        Should -Invoke Install-VcRuntime -Times 0
        Mock Test-VcRuntime { $false }
        Invoke-Main @script:MainArgs | Out-Null
        Should -Invoke Install-VcRuntime -Times 1
    }
    It 'FAILS when the PyKX read back is not the pinned version' {
        $script:PykxReported = '4.1.0'
        Invoke-Main @script:MainArgs | Should -Be 1
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_STATUS=failed' }
        Should -Invoke Out-Line -ParameterFilter { $Text -like 'AVD_REASON=*4.1.0*' }
    }
    It 'reports the check as ok when the query succeeds' {
        $script:MainArgs.HostName = 'q.example.invalid'; $script:MainArgs.Port = '6005'
        Invoke-Main @script:MainArgs | Should -Be 0
        Should -Invoke Out-Line -ParameterFilter { $Text -eq 'AVD_CHECK=ok' }
    }
    It 'FAILS when a configured check fails, and says why' {
        $script:MainArgs.HostName = 'q.example.invalid'; $script:MainArgs.Port = '6005'
        $script:CheckExit = 1
        Invoke-Main @script:MainArgs | Should -Be 1
        Should -Invoke Out-Line -ParameterFilter { $Text -like 'AVD_REASON=*firewall*' }
    }
    It 'FAILS on bad input before downloading anything' {
        $script:MainArgs.UvHash = 'abc'
        Invoke-Main @script:MainArgs | Should -Be 1
        Should -Invoke Install-Uv -Times 0
        Should -Invoke Install-VcRuntime -Times 0
    }
    It 'remove takes out the PATH entry and the variable' {
        Invoke-Main @script:MainArgs | Out-Null
        $script:MainArgs.Mode = 'remove'
        Invoke-Main @script:MainArgs | Should -Be 0
        $script:Machine.Path | Should -Be '%SystemRoot%\system32'
        $script:Machine.PYKX_UNLICENSED | Should -BeNullOrEmpty
    }
}
