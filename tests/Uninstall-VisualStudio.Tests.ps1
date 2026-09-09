#Requires -Modules Pester
<#
    Pester tests for Uninstall-VisualStudio.ps1.

    This script shipped without unit coverage and immediately failed on the VM:
    'setup.exe uninstall' does not accept --wait (that is a bootstrapper option),
    so it exited 87 "Option 'wait' is unknown" in two seconds. The argument-list
    tests below exist so that class of mistake is caught here instead.
#>

BeforeAll {
    $env:AVD_VS_LIB_ONLY = '1'
    $script:UninstallScript = Join-Path $PSScriptRoot '..' 'scripts' 'Uninstall-VisualStudio.ps1'
    # TargetInstallPath is Mandatory, so dot-sourcing without a value would
    # block on a prompt.
    . $script:UninstallScript -TargetInstallPath 'C:\Dummy'
}

AfterAll {
    Remove-Item Env:\AVD_VS_LIB_ONLY -ErrorAction SilentlyContinue
}

Describe 'Uninstall script is valid PowerShell as shipped' {
    BeforeAll {
        $script:UErrors = $null
        $script:UAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:UninstallScript, [ref]$null, [ref]$script:UErrors)
    }

    It 'parses with no errors' {
        $script:UErrors | Should -BeNullOrEmpty
    }
    It 'has param() as its first statement' {
        $script:UAst.ParamBlock | Should -Not -BeNullOrEmpty
    }
    It 'requires TargetInstallPath so it can never guess a target' {
        $p = $script:UAst.ParamBlock.Parameters |
             Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetInstallPath' }
        $p | Should -Not -BeNullOrEmpty
        $p.Extent.Text | Should -Match 'Mandatory'
    }
}

Describe 'Invoke-VsUninstall argument list' {
    BeforeEach {
        Mock Out-Line { }
        Mock Write-Log { }
        Mock Test-Path { $true }
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
    }

    It 'does NOT pass --wait, which setup.exe uninstall rejects with exit 87' {
        Invoke-VsUninstall -InstallPath 'C:\Program' | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -notlike '*--wait*'
        }
    }

    It 'passes the uninstall verb with --quiet and --norestart' {
        Invoke-VsUninstall -InstallPath 'C:\Program' | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $joined = $ArgumentList -join ' '
            ($joined -like 'uninstall *') -and ($joined -like '*--quiet*') -and ($joined -like '*--norestart*')
        }
    }

    It 'quotes an install path containing spaces' {
        Invoke-VsUninstall -InstallPath 'C:\Program Files\Microsoft Visual Studio\2026\Community' | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -like '*--installPath "C:\Program Files\Microsoft Visual Studio\2026\Community"*'
        }
    }

    It 'returns the exit code as an integer' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 87 } }
        $r = Invoke-VsUninstall -InstallPath 'C:\Program'
        $r | Should -BeOfType [int]
        $r | Should -Be 87
    }

    It 'throws a clear error when the setup engine is missing' {
        Mock Test-Path { $false }
        { Invoke-VsUninstall -InstallPath 'C:\Program' } |
            Should -Throw -ExpectedMessage '*setup engine not found*'
    }
}

Describe 'Test-PathMatch' {
    It 'matches identical paths' {
        Test-PathMatch -Actual 'C:\Program' -Expected 'C:\Program' | Should -BeTrue
    }
    It 'ignores a trailing backslash' {
        Test-PathMatch -Actual 'C:\Program\' -Expected 'C:\Program' | Should -BeTrue
    }
    It 'does not treat a prefix as a match' {
        Test-PathMatch -Actual 'C:\Program Files\MSVS' -Expected 'C:\Program' | Should -BeFalse
    }
    It 'rejects empty input rather than matching everything' {
        Test-PathMatch -Actual '' -Expected 'C:\Program' | Should -BeFalse
        Test-PathMatch -Actual 'C:\Program' -Expected '' | Should -BeFalse
    }
}

Describe 'Wait-ForRemoval' {
    BeforeEach {
        Mock Out-Line { }
        Mock Write-Log { }
        Mock Start-Sleep { }
    }

    It 'returns true once the instance disappears' {
        $script:Polls = 0
        Mock Get-VsInstances {
            $script:Polls++
            if ($script:Polls -lt 3) { return @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
            return @()
        }
        Wait-ForRemoval -InstallPath 'C:\Program' -TimeoutSeconds 300 -PollSeconds 1 | Should -BeTrue
        $script:Polls | Should -Be 3
    }

    It 'returns false when the instance never goes away' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
        Wait-ForRemoval -InstallPath 'C:\Program' -TimeoutSeconds 1 -PollSeconds 1 | Should -BeFalse
    }

    It 'ignores instances at other paths' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program Files\MSVS'; DisplayVersion = '18.10.0' }) }
        Wait-ForRemoval -InstallPath 'C:\Program' -TimeoutSeconds 300 -PollSeconds 1 | Should -BeTrue
    }
}

Describe 'Uninstall Invoke-Main contract' {
    BeforeEach {
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Out-Line { $script:Lines.Add($Text) }
        Mock Write-Log { }
        Mock Initialize-Log { }
        Mock Start-Sleep { }
        Mock Test-Path { $false }   # no leftover directory to remove
    }

    It 'is a no-op when no instance exists at the target path' {
        Mock Get-VsInstances { @() }
        Mock Invoke-VsUninstall { throw 'uninstaller must not run' }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        ($script:Lines -join ' ') | Should -Match 'nothing to do'
        $rc | Should -Be 0
        Should -Invoke Invoke-VsUninstall -Times 0
    }

    It 'does not touch an instance at a different path' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program Files\MSVS'; DisplayVersion = '18.10.0' }) }
        Mock Invoke-VsUninstall { throw 'uninstaller must not run' }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        Should -Invoke Invoke-VsUninstall -Times 0
    }

    It 'FAILS and names the exit code when the uninstaller rejects its arguments' {
        # The real failure: exit 87 from an unknown option.
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
        Mock Invoke-VsUninstall { 87 }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match '87'
        $rc | Should -Be 1
    }

    It 'FAILS when the uninstaller exits 0 but the instance is still registered' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
        Mock Invoke-VsUninstall { 0 }
        Mock Wait-ForRemoval { $false }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'still lists an instance'
        $rc | Should -Be 1
    }

    It 'succeeds once the instance is confirmed gone' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
        Mock Invoke-VsUninstall { 0 }
        Mock Wait-ForRemoval { $true }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        ($script:Lines -join ' ') | Should -Match 'removed instance'
        $rc | Should -Be 0
    }

    It 'treats 3010 (reboot required) as an acceptable uninstall exit code' {
        Mock Get-VsInstances { @([PSCustomObject]@{ Path = 'C:\Program'; DisplayVersion = '18.10.0' }) }
        Mock Invoke-VsUninstall { 3010 }
        Mock Wait-ForRemoval { $true }

        $rc = Invoke-Main -Target 'C:\Program'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
    }

    It 'emits markers on every path so the driver never sees silence' {
        Mock Get-VsInstances { throw 'catastrophic failure' }

        $rc = Invoke-Main -Target 'C:\Program'
        ($script:Lines -join ' ') | Should -Match 'AVD_STATUS='
        ($script:Lines -join ' ') | Should -Match 'AVD_REASON='
    }
}
