#Requires -Modules Pester
<#
    Pester tests for Install-VisualStudio.ps1.

    The install itself cannot be exercised without a Windows VM, so the external
    edges (download, installer process, vswhere) are mocked and the decision
    logic is tested directly. The central property under test is that the script
    only ever reports success when it has positively verified a C++ compiler on
    disk - a passing installer exit code alone must NOT produce success.
#>

BeforeAll {
    $env:AVD_VS_LIB_ONLY = '1'
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Install-VisualStudio.ps1'
    . $script:ScriptPath

    # Never touch a real log directory during tests.
    function Initialize-Log { param([string]$Dir) $script:LogFile = $null }
}

AfterAll {
    Remove-Item Env:\AVD_VS_LIB_ONLY -ErrorAction SilentlyContinue
}

Describe 'Script is valid PowerShell as shipped to the VM' {
    # Regression guard. The driver once prepended a variable assignment ahead of
    # param(), which must be the first statement in a script - the guest failed
    # to parse the whole file and the run died in under a second. Mocked-CLI
    # tests could not catch that, because nothing ever parsed the script.

    BeforeAll {
        $script:Tokens = $null
        $script:Errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
    }

    It 'parses with no errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'has param() as its first statement' {
        $script:Ast.ParamBlock | Should -Not -BeNullOrEmpty
    }

    It 'exposes the parameter names the driver passes via --parameters' {
        $names = $script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'ExpectedVersion'
        $names | Should -Contain 'AllowVersionDrift'
    }

    It 'declares AllowVersionDrift as a validated string, not a switch or bool' {
        # run-command hands parameters over as strings, and [bool]'false' is $true.
        $p = $script:Ast.ParamBlock.Parameters |
             Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowVersionDrift' }
        $p.StaticType.Name | Should -Be 'String'
        ($p.Attributes.TypeName.Name -join ',') | Should -Match 'ValidateSet'
    }

    It 'still parses when a parameter assignment is appended after it' {
        # Proves param() placement is what matters, not the presence of extra code.
        $body = (Get-Content -Raw $script:ScriptPath) + "`n`$Extra = 1`n"
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$e) | Out-Null
        $e | Should -BeNullOrEmpty
    }

    It 'FAILS to parse when an assignment is prepended before param() (the original bug)' {
        $body = "`$ExpectedVersion='18.10.0'`n" + (Get-Content -Raw $script:ScriptPath)
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$e) | Out-Null
        $e | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-VersionMatch' {
    # $Actual is catalog.productDisplayVersion ('18.10.0'), NOT
    # installationVersion ('18.10.12201.205') whose third component is the build
    # number. An earlier version compared the first three components of
    # installationVersion and flagged a correct 18.10.0 install as drift.

    It 'matches the advertised display version' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' | Should -BeTrue
    }
    It 'rejects a different display version' {
        Test-VersionMatch -Actual '18.11.0' -Expected '18.10.0' | Should -BeFalse
    }
    It 'rejects an empty version rather than treating it as a match' {
        Test-VersionMatch -Actual '' -Expected '18.10.0' | Should -BeFalse
    }
    It 'does NOT accept a raw installationVersion as the display version' {
        Test-VersionMatch -Actual '18.10.12201.205' -Expected '18.10.0' | Should -BeFalse
    }
    It 'ignores the build when no build pin is given' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' -ActualBuild '18.10.99999.1' |
            Should -BeTrue
    }
    It 'accepts a build pin given as the published tail (12201.205)' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' `
            -ActualBuild '18.10.12201.205' -ExpectedBuild '12201.205' | Should -BeTrue
    }
    It 'accepts a build pin given in full' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' `
            -ActualBuild '18.10.12201.205' -ExpectedBuild '18.10.12201.205' | Should -BeTrue
    }
    It 'rejects a mismatched build pin' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' `
            -ActualBuild '18.10.12201.205' -ExpectedBuild '12128.139' | Should -BeFalse
    }
    It 'rejects a build pin when the actual build is unknown' {
        Test-VersionMatch -Actual '18.10.0' -Expected '18.10.0' -ExpectedBuild '12201.205' |
            Should -BeFalse
    }
}

Describe 'Format-Argument' {
    # Start-Process joins -ArgumentList with spaces and does not quote. Verified
    # on the guest: unquoted, 'C:\Program Files\...' arrives as four separate
    # arguments and Visual Studio installs to 'C:\Program'.

    It 'quotes a value containing spaces' {
        Format-Argument 'C:\Program Files\Microsoft Visual Studio\2026\Community' |
            Should -Be '"C:\Program Files\Microsoft Visual Studio\2026\Community"'
    }
    It 'leaves a value without whitespace untouched' {
        Format-Argument 'Microsoft.VisualStudio.Workload.NativeDesktop' |
            Should -Be 'Microsoft.VisualStudio.Workload.NativeDesktop'
    }
    It 'quotes a value containing a tab' {
        $expected = '"a' + "`t" + 'b"'
        Format-Argument "a`tb" | Should -Be $expected
    }
    It 'handles an empty value without throwing' {
        { Format-Argument '' } | Should -Not -Throw
    }
}

Describe 'Test-InstallLocation' {
    It 'accepts any location when none was requested' {
        Test-InstallLocation -Actual 'C:\Program' -Expected '' | Should -BeTrue
    }
    It 'accepts the requested location' {
        Test-InstallLocation -Actual 'C:\Program Files\MSVS' -Expected 'C:\Program Files\MSVS' |
            Should -BeTrue
    }
    It 'ignores a trailing backslash' {
        Test-InstallLocation -Actual 'C:\VS\' -Expected 'C:\VS' | Should -BeTrue
    }
    It 'REJECTS the truncated path produced by the unquoted-argument bug' {
        Test-InstallLocation -Actual 'C:\Program' `
            -Expected 'C:\Program Files\Microsoft Visual Studio\2026\Community' | Should -BeFalse
    }
}

Describe 'Resolve-SetupExitCode' {
    It 'treats 0 as success with no reboot' {
        $r = Resolve-SetupExitCode -ExitCode 0
        $r.Ok | Should -BeTrue
        $r.Reboot | Should -BeFalse
    }
    It 'treats 3010 as success requiring a reboot' {
        $r = Resolve-SetupExitCode -ExitCode 3010
        $r.Ok | Should -BeTrue
        $r.Reboot | Should -BeTrue
    }
    It 'treats 1602 (cancelled) as failure' {
        (Resolve-SetupExitCode -ExitCode 1602).Ok | Should -BeFalse
    }
    It 'treats 1618 (another install running) as failure' {
        (Resolve-SetupExitCode -ExitCode 1618).Ok | Should -BeFalse
    }
    It 'treats an unrecognised non-zero code as failure and names it' {
        $r = Resolve-SetupExitCode -ExitCode 4242
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match '4242'
    }
}

Describe 'Get-Bootstrapper' {
    BeforeEach {
        $script:TempFile = Join-Path ([IO.Path]::GetTempPath()) "vs-boot-$([guid]::NewGuid()).exe"
    }
    AfterEach {
        Remove-Item -LiteralPath $script:TempFile -ErrorAction SilentlyContinue
    }

    It 'accepts a plausible PE bootstrapper' {
        Mock Invoke-WebRequest {
            $bytes = [byte[]]::new(2MB)
            $bytes[0] = 0x4D; $bytes[1] = 0x5A   # MZ
            [IO.File]::WriteAllBytes($script:TempFile, $bytes)
        }
        { Get-Bootstrapper -Url 'https://example.invalid/vs.exe' -Destination $script:TempFile } |
            Should -Not -Throw
    }

    It 'rejects a too-small download (blocked egress returns an error page)' {
        Mock Invoke-WebRequest {
            [IO.File]::WriteAllText($script:TempFile, '<html>403 Forbidden</html>')
        }
        { Get-Bootstrapper -Url 'https://example.invalid/vs.exe' -Destination $script:TempFile } |
            Should -Throw -ExpectedMessage '*egress is probably blocked*'
    }

    It 'rejects a large file that is not a PE (intercepting proxy)' {
        Mock Invoke-WebRequest {
            $bytes = [byte[]]::new(2MB)
            $bytes[0] = 0x3C; $bytes[1] = 0x21   # "<!"
            [IO.File]::WriteAllBytes($script:TempFile, $bytes)
        }
        { Get-Bootstrapper -Url 'https://example.invalid/vs.exe' -Destination $script:TempFile } |
            Should -Throw -ExpectedMessage '*not a PE executable*'
    }

    It 'retries a transient failure before giving up' {
        $script:Calls = 0
        Mock Invoke-WebRequest {
            $script:Calls++
            if ($script:Calls -lt 2) { throw 'transient network error' }
            $bytes = [byte[]]::new(2MB); $bytes[0] = 0x4D; $bytes[1] = 0x5A
            [IO.File]::WriteAllBytes($script:TempFile, $bytes)
        }
        Mock Start-Sleep { }
        { Get-Bootstrapper -Url 'https://example.invalid/vs.exe' -Destination $script:TempFile } |
            Should -Not -Throw
        $script:Calls | Should -Be 2
    }
}

Describe 'Logging must not pollute the success stream' {
    # Regression guard for the second real failure. Write-Log used Write-Output,
    # so every function returned its log lines as part of its return value:
    # Get-InstalledVs returned a string instead of $null, StrictMode threw on
    # .Version, and `exit (Invoke-Main)` swallowed the whole transcript - the
    # run reported exit 0 with completely empty output.

    It 'Write-Log returns nothing on the success stream' {
        Mock Out-Line { }
        $r = Write-Log -Message 'hello'
        $r | Should -BeNullOrEmpty
    }

    It 'Write-Result returns nothing on the success stream' {
        Mock Out-Line { }
        $r = Write-Result -Status success -Version '18.10.0' -Build 'b' -Reason 'ok'
        $r | Should -BeNullOrEmpty
    }

    It 'Write-Result emits exactly the four markers the driver parses' {
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Out-Line { $script:Lines.Add($Text) }
        Write-Result -Status success -Version '18.10.0' -Build '18.10.12201.205' -Reason 'ok' -RebootNeeded $true
        $script:Lines.Count | Should -Be 5
        $script:Lines[0] | Should -Be 'AVD_STATUS=success'
        $script:Lines[1] | Should -Be 'AVD_VERSION=18.10.0'
        $script:Lines[2] | Should -Be 'AVD_BUILD=18.10.12201.205'
        $script:Lines[3] | Should -Be 'AVD_REBOOT_REQUIRED=true'
        $script:Lines[4] | Should -Be 'AVD_REASON=ok'
    }

    It 'Get-InstalledVs returns exactly $null when vswhere is absent' {
        # This is the exact shape of the bug: a truthy log string here made
        # $existing.Version throw under StrictMode.
        Mock Out-Line { }
        Mock Test-Path { $false }
        $r = Get-InstalledVs
        ($null -eq $r) | Should -BeTrue
    }

    It 'Invoke-VsSetup returns an integer exit code, not a transcript' {
        Mock Out-Line { }
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 3010 } }
        $r = Invoke-VsSetup -Bootstrapper 'x.exe' -Mode install -InstallPath 'C:\VS' -Workloads @('W') -Components @('C')
        $r | Should -BeOfType [int]
        $r | Should -Be 3010
    }

    It 'no function in the script logs via Write-Output' {
        # Cheap structural check so the pattern cannot creep back in.
        $body = Get-Content -Raw $script:ScriptPath
        $body | Should -Not -Match 'Write-Output\s+"AVD_'
        $body | Should -Not -Match 'Write-Output\s+\$line'
    }
}

Describe 'Invoke-Main verification contract' {
    BeforeEach {
        # Markers go to the host stream, not the pipeline, so collect them by
        # intercepting the single sink every writer funnels through.
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Out-Line { $script:Lines.Add($Text) }
        Mock Write-Log { }
        Mock Initialize-Log { }
        Mock Get-Bootstrapper { 'C:\Temp\vs_community.exe' }
        # Defaults for this suite, passed explicitly to Invoke-Main below.
        $script:MainArgs = @{ Version = '18.10.0'; Build = ''; TargetPath = '' }
    }

    It 'is idempotent: reports success without installing when already correct' {
        Mock Get-InstalledVs { [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' } }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { throw 'installer must not run when already installed' }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        $script:Lines | Should -Contain 'AVD_REASON=already installed'
        $rc | Should -Be 0
        Should -Invoke Invoke-VsSetup -Times 0
    }

    It 'FAILS when the installer exits 0 but no C++ compiler is on disk' {
        # The whole point: a green exit code is not evidence of a working toolchain.
        Mock Get-InstalledVs { [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' } }
        Mock Test-CppToolchain { $false }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'no usable x64 cl\.exe'
        $rc | Should -Be 1
    }

    It 'FAILS when vswhere finds no instance after a clean installer exit' {
        Mock Get-InstalledVs { $null }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'vswhere reports no VS instance'
    }

    It 'FAILS on version drift by default' {
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return $null }
            [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.11.12300.1'; DisplayVersion = '18.11.0'; BuildVersion = '18.11.12300.1'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'Version drift'
    }

    It 'accepts version drift when explicitly allowed' {
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return $null }
            [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.11.12300.1'; DisplayVersion = '18.11.0'; BuildVersion = '18.11.12300.1'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs -AllowDrift $true
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        $script:Lines | Should -Contain 'AVD_VERSION=18.11.0'
    }

    It 'propagates the reboot-required flag from exit code 3010' {
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return $null }
            [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 3010 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        $script:Lines | Should -Contain 'AVD_REBOOT_REQUIRED=true'
    }

    It 'FAILS when the installer itself returns a bad exit code' {
        Mock Get-InstalledVs { $null }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 1618 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match '1618'
    }

    It 'emits the marker set on every path so the driver never sees silence' {
        Mock Get-InstalledVs { throw 'catastrophic failure' }

        $rc = Invoke-Main @script:MainArgs
        ($script:Lines -join ' ') | Should -Match 'AVD_STATUS='
        ($script:Lines -join ' ') | Should -Match 'AVD_VERSION='
        ($script:Lines -join ' ') | Should -Match 'AVD_REBOOT_REQUIRED='
        ($script:Lines -join ' ') | Should -Match 'AVD_REASON='
    }

    It 'runs modify rather than install when a mismatched VS already exists' {
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return [PSCustomObject]@{ InstallationPath = 'C:\Existing'; Version = '18.9.12105.275'; DisplayVersion = '18.9.0'; BuildVersion = '18.9.12105.275'; ProductId = 'Community' } }
            [PSCustomObject]@{ InstallationPath = 'C:\Existing'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        Should -Invoke Invoke-VsSetup -Times 1 -ParameterFilter { $Mode -eq 'modify' }
    }

    It 'FAILS when the install lands somewhere other than the requested path' {
        # The C:\Program bug: installer exits 0, cl.exe exists, version is right,
        # but Visual Studio is in the wrong directory. Must not pass.
        $script:MainArgs.TargetPath = 'C:\Program Files\Microsoft Visual Studio\2026\Community'
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return $null }
            [PSCustomObject]@{ InstallationPath = 'C:\Program'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -BeLike '*landed at*C:\Program*'
        $rc | Should -Be 1
    }

    It 'FAILS when the build pin does not match' {
        $script:MainArgs.Build = '12128.139'
        $script:Seen = 0
        Mock Get-InstalledVs {
            $script:Seen++
            if ($script:Seen -eq 1) { return $null }
            [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' }
        }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { 0 }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'Version drift'
    }

    It 'reports the display version and build, not installationVersion' {
        Mock Get-InstalledVs { [PSCustomObject]@{ InstallationPath = 'C:\VS'; Version = '18.10.12201.205'; DisplayVersion = '18.10.0'; BuildVersion = '18.10.12201.205'; ProductId = 'Community' } }
        Mock Test-CppToolchain { $true }
        Mock Invoke-VsSetup { throw 'must not run' }

        $rc = Invoke-Main @script:MainArgs
        $script:Lines | Should -Contain 'AVD_VERSION=18.10.0'
        $script:Lines | Should -Contain 'AVD_BUILD=18.10.12201.205'
        $script:Lines | Should -Not -Contain 'AVD_VERSION=18.10.12201.205'
    }
}

Describe 'Invoke-VsSetup argument construction' {
    BeforeEach {
        Mock Out-Line { }
        Mock Write-Log { }
    }

    It 'quotes an install path containing spaces' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        Invoke-VsSetup -Bootstrapper 'b.exe' -Mode install `
            -InstallPath 'C:\Program Files\MSVS' -Workloads @('W1') -Components @() | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -like '*--installPath "C:\Program Files\MSVS"*'
        }
    }

    It 'omits --installPath entirely when none is requested' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        Invoke-VsSetup -Bootstrapper 'b.exe' -Mode install `
            -InstallPath '' -Workloads @('W1') -Components @() | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -notlike '*--installPath*'
        }
    }

    It 'does not quote workload ids, which never contain spaces' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        Invoke-VsSetup -Bootstrapper 'b.exe' -Mode install `
            -InstallPath '' -Workloads @('Microsoft.VisualStudio.Workload.NativeDesktop') -Components @() | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -like '*--add Microsoft.VisualStudio.Workload.NativeDesktop*'
        }
    }

    It 'always passes --quiet --wait --norestart' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        Invoke-VsSetup -Bootstrapper 'b.exe' -Mode install `
            -InstallPath '' -Workloads @('W1') -Components @() | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $joined = $ArgumentList -join ' '
            ($joined -like '*--quiet*') -and ($joined -like '*--wait*') -and ($joined -like '*--norestart*')
        }
    }
}
