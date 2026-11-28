# install.ps1 end to end, against fakes of winget, gh and Get-CimInstance (functions defined here)
# and sbx (tests/fake-sbx), with a throwaway home folder and profile. PATH holds only the fake
# sbx (once "installed"), git and python, so a real gh or sbx on this machine stays out of it.
# The bash side is tests/install.bats.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:InstallScript = Join-Path $RepoRoot 'install.ps1'
    $script:OnWindows = $env:OS -eq 'Windows_NT'
    $script:Git = (Get-Command git).Source
    $script:Python = if ($OnWindows) { (Get-Command python).Source } else { (Get-Command python3).Source }

    # The one-liner, as irm hands it over; -FromClone runs the file instead. Sets $Output (the
    # lines it printed) and $Failure (the error that stopped it, or $null).
    function Invoke-Install([switch]$FromClone) {
        $sb = if ($FromClone) { { & $InstallScript } } else { [scriptblock]::Create((Get-Content -Raw $InstallScript)) }
        $lines = New-Object System.Collections.Generic.List[string]
        $script:Failure = $null
        try { & $sb 6>&1 | ForEach-Object { $lines.Add("$_") } } catch { $script:Failure = $_.Exception.Message }
        $script:Output = $lines -join "`n"
        Write-Host $script:Output   # shown when a test fails
    }

    function Enable-FakeGh {
        function global:gh {
            $global:FakeCalls.Add("gh $($args -join ' ')")
            $global:LASTEXITCODE = 0
            switch ("$($args[0]) $($args[1])") {
                'auth status' { if (-not $global:FakeState.GhSignedIn) { $global:LASTEXITCODE = 1 } }
                'auth login' { if ($global:FakeState.GhLoginFails) { $global:LASTEXITCODE = 1 } else { $global:FakeState.GhSignedIn = $true } }
                'auth token' { 'gho_fake' }
            }
        }
    }
    function Enable-FakeSbx {
        $fake = Join-Path $RepoRoot 'tests/fake-sbx'
        if ($OnWindows) {
            Copy-Item (Join-Path $fake 'sbx'), (Join-Path $fake 'sbx.cmd') $SbxBin
        } else {
            New-Item -ItemType SymbolicLink -Path (Join-Path $SbxBin 'sbx') -Target (Join-Path $fake 'sbx') | Out-Null
        }
    }
    function Get-ToolCall([string]$Like) { @($global:FakeCalls | Where-Object { $_ -like $Like }) }
    function Get-SbxCallLike([string]$Like) { @(Get-SbxCall | Where-Object { $_ -like $Like }) }
    function Get-BlockCount([string]$Path) { @(Get-Content $Path | Where-Object { $_ -eq '# >>> claude-sandbox >>>' }).Count }

    # Everything already done
    function Set-Ready {
        Enable-FakeGh
        Enable-FakeSbx
        $global:FakeState.GhSignedIn = $true
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'signed-in'), (Join-Path $env:FAKE_SBX_DIR 'policy-set') | Out-Null
    }

    # A bootstrapped Nowhere: its clone, its stub at the profile and its local override
    function Set-Nowhere {
        New-Item -ItemType Directory -Force (Join-Path $HomeDir 'Nowhere/bootstrap'), (Join-Path $HomeDir '.config/nowhere') | Out-Null
        New-Item -ItemType File (Join-Path $HomeDir 'Nowhere/bootstrap/bootstrap.ps1') | Out-Null
        New-Item -ItemType Directory -Force (Split-Path $ProfilePath) | Out-Null
        Set-Content $ProfilePath "`$env:NOWHERE_ROLE = 'devbox'`n. '$HomeDir/Nowhere/powershell/profile.ps1'"
        Set-Content $LocalPath "# my settings`n`$NowhereGotoBookmarks = @{ src = 'C:\src' }"
    }
}

Describe 'install.ps1' {
    BeforeEach {
        $savedPath = $env:PATH
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("claude-sandbox-install-" + [guid]::NewGuid())
        $script:HomeDir = Join-Path $Root 'home'
        $script:SbxBin = Join-Path $Root 'sbxbin'
        $sys = Join-Path $Root 'sys'
        $env:FAKE_SBX_DIR = Join-Path $Root 'sbx'
        New-Item -ItemType Directory -Force $HomeDir, $SbxBin, $sys, $env:FAKE_SBX_DIR | Out-Null
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'calls') | Out-Null
        if ($OnWindows) {
            $dirs = @((Split-Path $Git), (Split-Path $Python), (Join-Path $env:SystemRoot 'System32'))
        } else {
            New-Item -ItemType SymbolicLink -Path (Join-Path $sys 'git') -Target $Git | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $sys 'python3') -Target $Python | Out-Null
            $dirs = @($sys)
        }
        $env:PATH = (@($SbxBin) + $dirs) -join [IO.Path]::PathSeparator

        # The remote: a repo with the wrapper in it
        $script:Origin = Join-Path $Root 'origin'
        New-Item -ItemType Directory $Origin | Out-Null
        Set-Content (Join-Path $Origin 'claude-sandbox.ps1') '# wrapper'
        git -C $Origin init -q
        git -C $Origin add claude-sandbox.ps1
        git -C $Origin -c user.name=t -c user.email=t@example.com commit -qm init

        $env:CLAUDE_SANDBOX_REPO = $Origin
        $env:CLAUDE_SANDBOX_HOME = $HomeDir
        $script:ProfilePath = Join-Path $HomeDir 'Documents/PowerShell/Microsoft.PowerShell_profile.ps1'
        $env:CLAUDE_SANDBOX_PROFILE = $ProfilePath
        $script:LocalPath = Join-Path $HomeDir '.config/nowhere/local.ps1'
        $script:Clone = Join-Path $HomeDir 'Claude-Sandbox'
        foreach ($v in 'CLAUDE_SANDBOX_DIR', 'NOWHERE_ROLE', 'NOWHERE_DIR') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }

        $global:FakeCalls = New-Object System.Collections.Generic.List[string]
        $global:FakeState = @{ Hypervisor = 1; GhSignedIn = $false; GhLoginFails = $false; WingetFails = $false }
        function global:Get-CimInstance { [pscustomobject]@{ InstallState = $global:FakeState.Hypervisor } }
        function global:winget {
            $global:FakeCalls.Add("winget $($args -join ' ')")
            $global:LASTEXITCODE = 0
            if ($global:FakeState.WingetFails) { $global:LASTEXITCODE = 1; return }
            switch ($args[[array]::IndexOf($args, '--id') + 1]) {
                'GitHub.cli' { Enable-FakeGh }
                'Docker.sbx' { Enable-FakeSbx }
            }
        }
    }
    AfterEach {
        $env:PATH = $savedPath
        foreach ($f in 'gh', 'winget', 'Get-CimInstance') { Remove-Item "Function:\$f" -ErrorAction SilentlyContinue }
        foreach ($v in 'CLAUDE_SANDBOX_REPO', 'CLAUDE_SANDBOX_HOME', 'CLAUDE_SANDBOX_PROFILE', 'CLAUDE_SANDBOX_DIR', 'NOWHERE_DIR') {
            Remove-Item "env:$v" -ErrorAction SilentlyContinue
        }
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'fresh machine: installs the tools, signs in, sets up sbx and loads the wrapper' {
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-ToolCall 'winget install --id GitHub.cli --exact *' | Should -HaveCount 1
        Get-ToolCall 'winget install --id Docker.sbx --exact *' | Should -HaveCount 1
        Get-ToolCall 'winget install --id Git.Git *' | Should -HaveCount 0   # already there
        Join-Path $Clone 'claude-sandbox.ps1' | Should -Exist
        Get-ToolCall 'gh auth login' | Should -HaveCount 1
        Get-SbxCallLike 'login' | Should -HaveCount 1
        Get-SbxCallLike 'policy init balanced --no-input' | Should -HaveCount 1
        Get-SbxCallLike 'secret set github --command gh auth token -f --no-input' | Should -HaveCount 1
        Get-Content (Join-Path $env:FAKE_SBX_DIR 'secret-github') | Should -Be 'gh auth token'
        Get-Content $ProfilePath | Should -Contain ". '$(Join-Path $Clone 'claude-sandbox.ps1')'"
        Get-BlockCount $ProfilePath | Should -Be 1
        Get-Content $ProfilePath -Raw | Should -Not -Match 'NowhereGotoBookmarks'
        $Output | Should -Not -Match 'Still to do'
    }

    It 'a re-run changes nothing' {
        Invoke-Install
        $first = Get-Content $ProfilePath -Raw
        $global:FakeCalls.Clear()
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'calls') -Value $null
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-ToolCall 'winget *' | Should -HaveCount 0
        Get-ToolCall 'gh auth login' | Should -HaveCount 0
        Get-SbxCallLike 'login*' | Should -HaveCount 0
        Get-SbxCallLike 'policy*' | Should -HaveCount 0
        Get-Content $ProfilePath -Raw | Should -BeExactly $first
        $Output | Should -Match 'already up to date'
    }

    It 'keeps an existing network policy and sign-ins' {
        Set-Ready
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-SbxCallLike 'login*' | Should -HaveCount 0
        Get-SbxCallLike 'policy*' | Should -HaveCount 0
        Get-ToolCall 'gh auth login' | Should -HaveCount 0
        $Output | Should -Match 'network policy: already set'
    }

    It 'keeps the rest of the file, its CRLF and its BOM, and appends the block after a blank line' {
        Set-Ready
        New-Item -ItemType Directory -Force (Split-Path $ProfilePath) | Out-Null
        [IO.File]::WriteAllText($ProfilePath, "Set-Alias ll Get-ChildItem`r`n# caf" + [char]0xE9, (New-Object Text.UTF8Encoding($true)))
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        $bytes = [IO.File]::ReadAllBytes($ProfilePath)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = [IO.File]::ReadAllText($ProfilePath)
        $text | Should -BeLike ("Set-Alias ll Get-ChildItem`r`n# caf" + [char]0xE9 + "`r`n`r`n# >>> claude-sandbox >>>`r`n*")
        $text | Should -Not -Match '[^\r]\n'
    }

    It 'a clone that moved: the block is rewritten, not added again' {
        Set-Ready
        $env:CLAUDE_SANDBOX_DIR = Join-Path $Root 'a'
        Invoke-Install
        $env:CLAUDE_SANDBOX_DIR = Join-Path $Root 'b'
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-BlockCount $ProfilePath | Should -Be 1
        Get-Content $ProfilePath -Raw | Should -Match ([regex]::Escape((Join-Path $Root 'b')))
        Get-Content $ProfilePath -Raw | Should -Not -Match ([regex]::Escape((Join-Path $Root 'a')))
    }

    It "Nowhere: the block goes in its local override, with a goto bookmark" {
        Set-Ready
        Set-Nowhere
        $stub = Get-Content $ProfilePath -Raw
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        $local = Get-Content $LocalPath
        $local[0..1] | Should -Be @('# my settings', '$NowhereGotoBookmarks = @{ src = ''C:\src'' }')
        $local | Should -Contain ". '$(Join-Path $Clone 'claude-sandbox.ps1')'"
        $local | Should -Contain "`$NowhereGotoBookmarks['cs'] = '$Clone'"
        Get-Content $ProfilePath -Raw | Should -BeExactly $stub
    }

    It 'Nowhere: the bookmark adds to the ones already set' {
        Set-Ready
        Set-Nowhere
        Invoke-Install
        $bookmarks = & { $NowhereGotoBookmarks = $null; . $LocalPath; $NowhereGotoBookmarks }
        $bookmarks['src'] | Should -Be 'C:\src'
        $bookmarks['cs'] | Should -Be $Clone
    }

    It 'Nowhere: found through NOWHERE_DIR too' {
        Set-Ready
        Set-Nowhere
        Move-Item (Join-Path $HomeDir 'Nowhere') (Join-Path $Root 'nw')
        $env:NOWHERE_DIR = Join-Path $Root 'nw'
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-BlockCount $LocalPath | Should -Be 1
    }

    It "a Nowhere clone that was never bootstrapped doesn't count" {
        Set-Ready
        New-Item -ItemType Directory -Force (Join-Path $HomeDir 'Nowhere/bootstrap') | Out-Null
        New-Item -ItemType File (Join-Path $HomeDir 'Nowhere/bootstrap/bootstrap.ps1') | Out-Null
        Invoke-Install
        Get-BlockCount $ProfilePath | Should -Be 1
        $LocalPath | Should -Not -Exist
    }

    It 'a wrapper already loaded by hand from the same clone is left alone' {
        Set-Ready
        git clone -q $Origin $Clone
        New-Item -ItemType Directory -Force (Split-Path $ProfilePath) | Out-Null
        Set-Content $ProfilePath ". $(Join-Path $Clone 'claude-sandbox.ps1')"
        $before = Get-Content $ProfilePath -Raw
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-Content $ProfilePath -Raw | Should -BeExactly $before
        $Output | Should -Match 'already loads the wrapper'
    }

    It 'Nowhere: a hand-added line in its stub gets a warning, and the block goes in the override' {
        Set-Ready
        Set-Nowhere
        git clone -q $Origin $Clone
        Add-Content $ProfilePath ". ~/Claude-Sandbox/claude-sandbox.ps1"
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        $Output | Should -Match ([regex]::Escape("$ProfilePath also loads the wrapper (line 3)") + '.*remove that line')
        Get-Content $LocalPath | Should -Contain ". '$(Join-Path $Clone 'claude-sandbox.ps1')'"
    }

    It 'a wrapper loaded from another clone stops the install' {
        Set-Ready
        $other = Join-Path $Root 'other'
        git clone -q $Origin $other
        New-Item -ItemType Directory -Force (Split-Path $ProfilePath) | Out-Null
        Set-Content $ProfilePath ". '$(Join-Path $other 'claude-sandbox.ps1')'"
        $before = Get-Content $ProfilePath -Raw
        Invoke-Install
        $Failure | Should -BeLike "claude-sandbox install: $ProfilePath already loads a wrapper from another clone*CLAUDE_SANDBOX_DIR*"
        Get-Content $ProfilePath -Raw | Should -BeExactly $before
    }

    It 'failed sign-ins are listed at the end, and the install carries on' {
        Enable-FakeGh
        Enable-FakeSbx
        $global:FakeState.GhLoginFails = $true
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'login-fails') | Out-Null
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        Get-SbxCallLike 'policy*' | Should -HaveCount 0
        $Output | Should -Match "(?s)Still to do, in a terminal:.*gh auth login.*sbx login.*sbx policy init balanced.*sbx secret set github --command 'gh auth token' -f"
        Get-BlockCount $ProfilePath | Should -Be 1
    }

    It "a failed secret doesn't stop the install" {
        Set-Ready
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'secret-fails') | Out-Null
        Invoke-Install
        $Failure | Should -BeNullOrEmpty
        $Output | Should -Match "claude-sandbox install: couldn't store the github secret"
        $Output | Should -Match "(?s)Still to do.*sbx secret set github --command 'gh auth token' -f"
        Get-BlockCount $ProfilePath | Should -Be 1
    }

    It 'run from a clone, it uses that clone' {
        Set-Ready
        Invoke-Install -FromClone
        $Failure | Should -BeNullOrEmpty
        $Output | Should -Match ([regex]::Escape("using the clone at $RepoRoot"))
        $Clone | Should -Not -Exist
        Get-Content $ProfilePath | Should -Contain ". '$(Join-Path $RepoRoot 'claude-sandbox.ps1')'"
    }

    It "a folder in the clone's place that isn't a clone stops the install" {
        Set-Ready
        New-Item -ItemType Directory $Clone | Out-Null
        Invoke-Install
        $Failure | Should -BeLike "*$Clone exists and isn't a git clone*"
    }

    It 'Windows Hypervisor Platform off stops before installing anything' {
        $global:FakeState.Hypervisor = 2
        Invoke-Install
        $Failure | Should -BeLike '*Windows Hypervisor Platform is off*Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All*'
        Get-ToolCall 'winget *' | Should -HaveCount 0
    }

    It 'no winget stops before anything else' {
        Remove-Item Function:\winget
        Invoke-Install
        $Failure | Should -BeLike 'claude-sandbox install: winget not found*'
    }

    It 'a failed winget install stops the install' {
        $global:FakeState.WingetFails = $true
        Invoke-Install
        $Failure | Should -BeLike "*winget couldn't install GitHub.cli (exit 1)*"
    }

    It 'an sbx older than 0.51.0 gets a warning' {
        Set-Ready
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'version') 'v0.50.2 abc'
        Invoke-Install
        $Output | Should -Match 'sbx 0\.50\.2 is older than 0\.51\.0'
    }
}
