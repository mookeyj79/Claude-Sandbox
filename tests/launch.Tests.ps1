# The whole `claude` function, end to end against the fake sbx.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'claude' {
    BeforeEach {
        $savedPath = $env:PATH
        $root = Initialize-FakeSbx
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $script:ClaudeSandboxStateDir = Join-Path $root 'home'
        # Skill sync has its own tests; keep it quiet here.
        @(Get-ChildItem -Directory (Join-Path $RepoRoot 'skills') | ForEach-Object Name) + $script:ClaudeSandboxSkillRepos |
            Set-Content (Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-added')
        Set-Content (Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-updated') (Get-Date -Format o)
        $project = Join-Path $root 'My Project'
        New-Item -ItemType Directory -Force $project | Out-Null
        Push-Location $project
        $key = Get-ClaudeSandboxProjectKey $project
        $store = Join-Path $env:LOCALAPPDATA "claude-sandbox\history\$key"
        $boxes = Join-Path $env:FAKE_SBX_DIR 'sandboxes'
        foreach ($v in 'CLAUDE_SANDBOX_MODEL', 'CLAUDE_SANDBOX_EFFORT', 'CLAUDE_SANDBOX_PERMISSION_MODE', 'CLAUDE_SANDBOX_SHARE_HISTORY') {
            Remove-Item "env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        $env:PATH = $savedPath
        Pop-Location
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs claude in a new sandbox, then saves history and deletes it' {
        New-Item -ItemType Directory -Force (Join-Path $store 'projects/p') | Out-Null
        claude --resume 6>$null
        $calls = Get-SbxCall
        ($calls -like 'create --name *')[0] | Should -BeLike "create --name $key-???? claude $project *"
        $calls -like 'exec * bash /tmp/claude-sandbox/setup.sh - - -' | Should -Not -BeNullOrEmpty
        $calls -like 'exec * claude --resume' | Should -Not -BeNullOrEmpty
        $calls -like "cp *sandbox $key-????:/tmp/claude-sandbox" | Should -Not -BeNullOrEmpty
        $calls -like "cp *$key $key-????:/tmp/claude-sandbox/history" | Should -Not -BeNullOrEmpty
        $calls -like "rm --force $key-*" | Should -Not -BeNullOrEmpty
        @(Get-ChildItem $boxes) | Should -HaveCount 0
    }

    It 'passes model, effort and permission mode on as set, set-but-empty, or not set' {
        $env:CLAUDE_SANDBOX_MODEL = 'sonnet'
        $env:CLAUDE_SANDBOX_EFFORT = ''
        claude 6>$null
        # Setting '' deletes the variable before PowerShell 7.5 (effort: not set, '-') and keeps
        # it empty from 7.5 on ('='). Either way three arguments arrive, in order.
        Get-SbxCall | Where-Object { $_ -like 'exec *setup.sh*' } |
            Should -Match 'setup\.sh =sonnet (-|=) -$'
    }

    It "doesn't start Claude in a sandbox whose setup failed" {
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'setup-fails') | Out-Null
        $out = (claude 6>&1) -join "`n"
        $out | Should -Match "ERROR: setting up $key-.*failed \(see above\), so Claude wasn't started"
        Get-SbxCall | Where-Object { $_ -like 'exec * claude' } | Should -BeNullOrEmpty
    }

    It 'mounts earlier sessions read-only unless turned off' {
        claude 6>$null
        Get-SbxCall | Where-Object { $_ -like 'create *' } | Should -BeLike '*:/claude-history-sandbox:ro*'
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'calls') ''
        $env:CLAUDE_SANDBOX_SHARE_HISTORY = '0'
        claude 6>$null
        Get-SbxCall | Where-Object { $_ -like 'create *' } | Should -Not -BeLike '*claude-history*'
    }

    It 'starts without the mounts if sbx rejects them' {
        New-Item -ItemType File (Join-Path $env:FAKE_SBX_DIR 'create-fails-with-mounts') | Out-Null
        $out = (claude 6>&1) -join "`n"
        $out | Should -Match "couldn't mount earlier sessions, starting without them"
        @(Get-SbxCall | Where-Object { $_ -like 'create *' }) | Should -HaveCount 2
        Get-SbxCall | Where-Object { $_ -like 'exec * claude' } | Should -Not -BeNullOrEmpty
    }

    It 'cleans up a leftover sandbox from an earlier window before starting' {
        New-FakeSandbox "$key-old1" stopped
        Set-FakeSandboxFile "$key-old1" /home/agent/.claude/projects/p/s1.jsonl 's'
        $out = (claude 6>&1) -join "`n"
        $out | Should -Match "cleaning up leftover sandbox $key-old1"
        Join-Path $store 'projects/p/s1.jsonl' | Should -Exist
    }

    It 'defines claude-local to run the host claude, if there is one' {
        $bin = Join-Path $root 'hostbin'
        New-Item -ItemType Directory -Force $bin | Out-Null
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            Set-Content (Join-Path $bin 'claude.cmd') '@echo host claude %*'
        } else {
            Set-Content (Join-Path $bin 'claude') "#!/bin/sh`necho host claude `"`$*`""
            chmod +x (Join-Path $bin 'claude')
        }
        $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        claude-local -p hi | Should -Be 'host claude -p hi'
        Get-SbxCall | Should -BeNullOrEmpty
    }

    It "doesn't define claude-local when there's no host claude" {
        # A fresh shell, with every folder holding a claude taken off PATH.
        $sep = [IO.Path]::PathSeparator
        $env:PATH = ($env:PATH -split $sep | Where-Object {
            $_ -and -not (Get-ChildItem -Path $_ -Filter 'claude*' -File -ErrorAction SilentlyContinue)
        }) -join $sep
        $shell = (Get-Process -Id $PID).Path
        $defined = & $shell -NoProfile -Command {
            param($Wrapper)
            . $Wrapper
            [bool](Get-Command claude-local -ErrorAction SilentlyContinue)
        } -args (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $defined | Should -BeFalse
    }

    It 'says which commit of the wrapper is running' {
        $rev = & git -C $RepoRoot rev-parse --short HEAD
        $out = (claude 6>&1) -join "`n"
        $out | Should -Match ([regex]::Escape("claude-sandbox ($rev): starting $key-"))
    }

    It 'removes unused images only after its own sandbox exists, so its image is kept' {
        claude 6>&1 | Out-Null
        @(Get-SbxCall | Where-Object { $_ -match '^(create|df) ' } | ForEach-Object { ($_ -split ' ')[0] }) |
            Should -Be @('create', 'df')
    }
}
