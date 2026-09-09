#Requires -Modules Pester
<#
    Pester tests for Set-PublicDesktopShortcuts.ps1.

    The COM/filesystem edges are mocked; what is tested is the parsing of the
    'Name=Target' spec (a typo must fail loudly rather than quietly produce zero
    shortcuts) and the rule that a shortcut only counts as done once it resolves
    to a file that actually exists.
#>

BeforeAll {
    $env:AVD_VS_LIB_ONLY = '1'
    $script:ShortcutScript = Join-Path $PSScriptRoot '..' 'scripts' 'Set-PublicDesktopShortcuts.ps1'
    . $script:ShortcutScript -Shortcuts 'Dummy=C:\dummy.exe'
}

AfterAll {
    Remove-Item Env:\AVD_VS_LIB_ONLY -ErrorAction SilentlyContinue
}

Describe 'Shortcut script is valid PowerShell as shipped' {
    BeforeAll {
        $script:SErrors = $null
        $script:SAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ShortcutScript, [ref]$null, [ref]$script:SErrors)
    }
    It 'parses with no errors' { $script:SErrors | Should -BeNullOrEmpty }
    It 'has param() as its first statement' { $script:SAst.ParamBlock | Should -Not -BeNullOrEmpty }
    It 'exposes the parameters the driver passes' {
        $names = $script:SAst.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'Shortcuts'
        $names | Should -Contain 'Action'
    }
}

Describe 'ConvertFrom-ShortcutSpec' {
    It 'parses a single pair' {
        $r = @(ConvertFrom-ShortcutSpec -Spec 'Excel=C:\Office\EXCEL.EXE')
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Excel'
        $r[0].Target | Should -Be 'C:\Office\EXCEL.EXE'
    }
    It 'parses several pairs' {
        $r = @(ConvertFrom-ShortcutSpec -Spec 'Excel=C:\a\EXCEL.EXE;Word=C:\a\WINWORD.EXE')
        $r.Count | Should -Be 2
        $r[1].Name | Should -Be 'Word'
    }
    It 'keeps a target containing spaces intact' {
        $r = @(ConvertFrom-ShortcutSpec -Spec 'Excel=C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE')
        $r[0].Target | Should -Be 'C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE'
    }
    It 'does not split a target on the drive colon or extra equals signs' {
        $r = @(ConvertFrom-ShortcutSpec -Spec 'Thing=C:\a\b.exe /flag=1')
        $r[0].Target | Should -Be 'C:\a\b.exe /flag=1'
    }
    It 'tolerates trailing and repeated separators' {
        $r = @(ConvertFrom-ShortcutSpec -Spec 'Excel=C:\a\EXCEL.EXE;;')
        $r.Count | Should -Be 1
    }
    It 'THROWS on a pair with no target rather than skipping it' {
        { ConvertFrom-ShortcutSpec -Spec 'Excel=' } | Should -Throw -ExpectedMessage '*Malformed*'
    }
    It 'THROWS on a pair with no name' {
        { ConvertFrom-ShortcutSpec -Spec '=C:\a.exe' } | Should -Throw -ExpectedMessage '*Malformed*'
    }
    It 'THROWS on a spec with no equals sign at all' {
        { ConvertFrom-ShortcutSpec -Spec 'Excel' } | Should -Throw -ExpectedMessage '*Malformed*'
    }
    It 'THROWS on an empty spec rather than reporting zero successes' {
        { ConvertFrom-ShortcutSpec -Spec '' } | Should -Throw -ExpectedMessage '*No shortcuts*'
    }
}

Describe 'Set-OneShortcut' {
    BeforeEach {
        Mock Out-Line { }
        Mock Write-Log { }
    }

    It 'refuses a target that does not exist' {
        Mock Test-Path { $false }
        { Set-OneShortcut -Name 'Excel' -Target 'C:\nope\EXCEL.EXE' -DesktopDir 'C:\Users\Public\Desktop' } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'prefers the vendor Start Menu shortcut when one exists' {
        Mock Test-Path { $true }
        Mock Find-StartMenuShortcut { 'C:\ProgramData\...\Excel.lnk' }
        Mock Copy-Item { }
        Mock New-Shortcut { throw 'should not synthesise when a vendor lnk exists' }
        Mock Get-ShortcutTarget { 'C:\Office\EXCEL.EXE' }

        # Existing desktop lnk points elsewhere, so it must be replaced.
        $script:Calls = 0
        Mock Get-ShortcutTarget {
            $script:Calls++
            if ($script:Calls -eq 1) { return 'C:\old\OTHER.EXE' }
            return 'C:\Office\EXCEL.EXE'
        }

        Set-OneShortcut -Name 'Excel' -Target 'C:\Office\EXCEL.EXE' -DesktopDir 'C:\Users\Public\Desktop' |
            Should -BeTrue
        Should -Invoke Copy-Item -Times 1
        Should -Invoke New-Shortcut -Times 0
    }

    It 'synthesises a shortcut when the app registered none' {
        Mock Test-Path { $true }
        Mock Find-StartMenuShortcut { $null }
        Mock Copy-Item { throw 'nothing to copy' }
        Mock New-Shortcut { }
        $script:Calls = 0
        Mock Get-ShortcutTarget {
            $script:Calls++
            if ($script:Calls -eq 1) { return 'C:\old\OTHER.EXE' }
            return 'C:\Tools\thing.exe'
        }

        Set-OneShortcut -Name 'Thing' -Target 'C:\Tools\thing.exe' -DesktopDir 'C:\Users\Public\Desktop' |
            Should -BeTrue
        Should -Invoke New-Shortcut -Times 1
    }

    It 'is idempotent when the shortcut already points at the target' {
        Mock Test-Path { $true }
        Mock Get-ShortcutTarget { 'C:\Office\EXCEL.EXE' }
        Mock Copy-Item { throw 'must not rewrite an identical shortcut' }
        Mock New-Shortcut { throw 'must not rewrite an identical shortcut' }

        Set-OneShortcut -Name 'Excel' -Target 'C:\Office\EXCEL.EXE' -DesktopDir 'C:\Users\Public\Desktop' |
            Should -BeTrue
        Should -Invoke Copy-Item -Times 0
    }

    It 'FAILS when the created shortcut resolves to a missing file' {
        # Target exists, the .lnk gets written, but it points at nothing usable.
        $script:TP = 0
        Mock Test-Path {
            $script:TP++
            if ($script:TP -eq 1) { return $true }   # target exists
            if ($script:TP -eq 2) { return $false }  # no pre-existing desktop lnk
            if ($script:TP -eq 3) { return $true }   # lnk was created
            return $false                            # resolved target missing
        }
        Mock Find-StartMenuShortcut { $null }
        Mock New-Shortcut { }
        Mock Get-ShortcutTarget { 'C:\gone\thing.exe' }

        { Set-OneShortcut -Name 'Thing' -Target 'C:\Tools\thing.exe' -DesktopDir 'C:\Users\Public\Desktop' } |
            Should -Throw -ExpectedMessage '*resolves to a missing file*'
    }

    It 'FAILS when the shortcut has no target after creation' {
        $script:TP = 0
        Mock Test-Path {
            $script:TP++
            if ($script:TP -eq 1) { return $true }
            if ($script:TP -eq 2) { return $false }
            return $true
        }
        Mock Find-StartMenuShortcut { $null }
        Mock New-Shortcut { }
        Mock Get-ShortcutTarget { '' }

        { Set-OneShortcut -Name 'Thing' -Target 'C:\Tools\thing.exe' -DesktopDir 'C:\Users\Public\Desktop' } |
            Should -Throw -ExpectedMessage '*no target*'
    }
}

Describe 'Remove-OneShortcut' {
    BeforeEach {
        Mock Out-Line { }
        Mock Write-Log { }
    }

    It 'is a no-op when the shortcut is absent' {
        Mock Test-Path { $false }
        Mock Remove-Item { throw 'nothing to remove' }
        Remove-OneShortcut -Name 'Excel' -DesktopDir 'C:\Users\Public\Desktop' | Should -BeTrue
    }

    It 'removes an existing shortcut and confirms it is gone' {
        $script:TP = 0
        Mock Test-Path { $script:TP++; return ($script:TP -eq 1) }
        Mock Remove-Item { }
        Remove-OneShortcut -Name 'Excel' -DesktopDir 'C:\Users\Public\Desktop' | Should -BeTrue
        Should -Invoke Remove-Item -Times 1
    }

    It 'FAILS when the file is still there afterwards' {
        Mock Test-Path { $true }
        Mock Remove-Item { }
        { Remove-OneShortcut -Name 'Excel' -DesktopDir 'C:\Users\Public\Desktop' } |
            Should -Throw -ExpectedMessage '*Failed to remove*'
    }
}

Describe 'Shortcut Invoke-Main contract' {
    BeforeEach {
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Out-Line { $script:Lines.Add($Text) }
        Mock Write-Log { }
        Mock Initialize-Log { }
        Mock Get-PublicDesktop { 'C:\Users\Public\Desktop' }
        Mock Test-Path { $true }
    }

    It 'reports the number of shortcuts actually processed' {
        Mock Set-OneShortcut { $true }
        $rc = Invoke-Main -Spec 'Excel=C:\a\EXCEL.EXE;Word=C:\a\WINWORD.EXE' -Mode 'create'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        $script:Lines | Should -Contain 'AVD_SHORTCUT_COUNT=2'
        $script:Lines | Should -Contain 'AVD_SHORTCUT_OK=Excel'
        $script:Lines | Should -Contain 'AVD_SHORTCUT_OK=Word'
        $rc | Should -Be 0
    }

    It 'FAILS and reports zero when one shortcut throws' {
        Mock Set-OneShortcut { throw 'target for Word does not exist' }
        $rc = Invoke-Main -Spec 'Word=C:\nope\WINWORD.EXE' -Mode 'create'
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        $script:Lines | Should -Contain 'AVD_SHORTCUT_COUNT=0'
        $rc | Should -Be 1
    }

    It 'FAILS when the public desktop directory is missing' {
        Mock Test-Path { $false }
        $rc = Invoke-Main -Spec 'Excel=C:\a\EXCEL.EXE' -Mode 'create'
        $script:Lines | Should -Contain 'AVD_STATUS=failed'
        ($script:Lines -join ' ') | Should -Match 'Public desktop directory not found'
    }

    It 'routes remove mode to the remover, not the creator' {
        Mock Remove-OneShortcut { $true }
        Mock Set-OneShortcut { throw 'must not create in remove mode' }
        $rc = Invoke-Main -Spec 'Excel=C:\a\EXCEL.EXE' -Mode 'remove'
        $script:Lines | Should -Contain 'AVD_STATUS=success'
        Should -Invoke Remove-OneShortcut -Times 1
        $rc | Should -Be 0
    }

    It 'emits markers on every path so the driver never sees silence' {
        Mock Get-PublicDesktop { throw 'catastrophic failure' }
        $rc = Invoke-Main -Spec 'Excel=C:\a\EXCEL.EXE' -Mode 'create'
        ($script:Lines -join ' ') | Should -Match 'AVD_STATUS='
        ($script:Lines -join ' ') | Should -Match 'AVD_SHORTCUT_COUNT='
        ($script:Lines -join ' ') | Should -Match 'AVD_REASON='
    }
}
