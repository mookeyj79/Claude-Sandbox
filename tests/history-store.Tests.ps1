# History store, close and sweep.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'History store' {
    BeforeEach {
        $root = Initialize-FakeSbx
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $script:ClaudeSandboxStateDir = Join-Path $root 'home'
        $store = Join-Path $env:LOCALAPPDATA 'claude-sandbox\history'
        $key = 'claude-proj-0123abcd'
        $box = "$key-x1y2"
        $boxes = Join-Path $env:FAKE_SBX_DIR 'sandboxes'
    }
    AfterEach { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'moves history saved under the old (full Unicode lowercase) key to the new one' {
        $path = "C:\Users\$([char]0xD6)laf\Projekt"   # O-umlaut; non-ASCII kept out of this file for PowerShell 5.1
        $old = Join-Path $store (Get-ClaudeSandboxProjectKey $path -Legacy)
        $new = Join-Path $store (Get-ClaudeSandboxProjectKey $path)
        $old | Should -Not -Be $new
        New-Item -ItemType Directory -Force (Join-Path $old 'projects') | Out-Null
        Move-ClaudeSandboxLegacyHistory $path
        Join-Path $new 'projects' | Should -Exist
        $old | Should -Not -Exist
    }

    It 'leaves both folders alone when the new key already has history' {
        $path = "C:\Users\$([char]0xD6)laf\Projekt"   # O-umlaut; non-ASCII kept out of this file for PowerShell 5.1
        $old = Join-Path $store (Get-ClaudeSandboxProjectKey $path -Legacy)
        $new = Join-Path $store (Get-ClaudeSandboxProjectKey $path)
        New-Item -ItemType Directory -Force $old, $new | Out-Null
        Move-ClaudeSandboxLegacyHistory $path
        $old | Should -Exist
        $new | Should -Exist
    }

    It 'gives new names that are unique per window but trace back to the project' {
        $a = Get-ClaudeSandboxNewName $key
        $b = Get-ClaudeSandboxNewName $key
        $a | Should -Not -Be $b
        Get-ClaudeSandboxProject $a | Should -Be $key
    }

    It 'accepts old names without the random part and rejects others' {
        Get-ClaudeSandboxProject $key | Should -Be $key
        Get-ClaudeSandboxProject 'my-own-sandbox' | Should -BeNullOrEmpty
    }

    It "pushes the project's store into the sandbox" {
        New-Item -ItemType Directory -Force (Join-Path $store "$key/projects/p") | Out-Null
        Set-Content -NoNewline -Path (Join-Path $store "$key/projects/p/s1.jsonl") -Value 's1'
        New-FakeSandbox $box running
        Push-ClaudeSandboxHistory $box
        Get-Content -Raw (Join-Path $boxes "$box/fs/tmp/claude-hist/projects/p/s1.jsonl") | Should -Be 's1'
    }

    It 'merges sessions and copies prompt history on save' {
        New-Item -ItemType Directory -Force (Join-Path $store "$key/projects/p") | Out-Null
        Set-Content -NoNewline -Path (Join-Path $store "$key/projects/p/s0.jsonl") -Value 'old'
        New-FakeSandbox $box stopped
        Set-FakeSandboxFile $box /home/agent/.claude/projects/p/s1.jsonl 'new'
        Set-FakeSandboxFile $box /home/agent/.claude/projects/lost+found/junk 'x'
        Set-FakeSandboxFile $box /home/agent/.claude/history.jsonl 'prompts'
        Save-ClaudeSandboxHistory $box | Should -BeTrue
        Get-Content -Raw (Join-Path $store "$key/projects/p/s0.jsonl") | Should -Be 'old'
        Get-Content -Raw (Join-Path $store "$key/projects/p/s1.jsonl") | Should -Be 'new'
        Join-Path $store "$key/projects/lost+found" | Should -Not -Exist
        Get-Content -Raw (Join-Path $store "$key/history.jsonl") | Should -Be 'prompts'
    }

    It 'fails the save when the sandbox has no projects folder' {
        New-FakeSandbox $box stopped
        Save-ClaudeSandboxHistory $box | Should -BeFalse
    }

    It 'deletes the sandbox on close once history is saved' {
        New-FakeSandbox $box running
        Set-FakeSandboxFile $box /home/agent/.claude/projects/p/s1.jsonl 's'
        Close-ClaudeSandbox $box | Should -BeTrue
        Join-Path $boxes $box | Should -Not -Exist
        Join-Path $store "$key/projects/p/s1.jsonl" | Should -Exist
    }

    It 'keeps the sandbox, stopped, when the save fails' {
        New-FakeSandbox $box running
        Set-FakeSandboxFile $box /home/agent/.claude/projects/p/s1.jsonl 's'
        New-Item -ItemType File (Join-Path $boxes "$box/fail-cp") | Out-Null
        $out = Close-ClaudeSandbox $box 6>&1
        $out | Where-Object { $_ -is [bool] } | Should -BeFalse
        ($out -join "`n") | Should -Match "couldn't save history from $box, so the sandbox was kept"
        Get-Content -Raw (Join-Path $boxes "$box/status") | Should -Be 'stopped'
    }

    It 'sweeps our stopped sandboxes and leaves everything else' {
        New-FakeSandbox $box stopped
        Set-FakeSandboxFile $box /home/agent/.claude/projects/p/s1.jsonl 's'
        New-FakeSandbox "$key-busy" running
        New-FakeSandbox 'someone-elses' stopped
        $out = (Invoke-ClaudeSandboxSweep 6>&1) -join "`n"
        $out | Should -Match "cleaning up leftover sandbox $box"
        Join-Path $boxes $box | Should -Not -Exist
        Join-Path $boxes "$key-busy" | Should -Exist
        Join-Path $boxes 'someone-elses' | Should -Exist
        Join-Path $store "$key/projects/p/s1.jsonl" | Should -Exist
    }

    It 'retries a sandbox whose save failed last time' {
        New-FakeSandbox $box stopped
        New-Item -ItemType File (Join-Path $boxes "$box/fail-cp") | Out-Null
        Invoke-ClaudeSandboxSweep 6>$null
        Join-Path $boxes $box | Should -Exist
        Remove-Item (Join-Path $boxes "$box/fail-cp")
        Set-FakeSandboxFile $box /home/agent/.claude/projects/p/s1.jsonl 's'
        Invoke-ClaudeSandboxSweep 6>$null
        Join-Path $boxes $box | Should -Not -Exist
    }
}
