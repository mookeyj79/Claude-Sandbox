# The whole `claude` function, end to end against the fake sbx.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'claude' {
    BeforeEach {
        $root = Initialize-FakeSbx
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $script:ClaudeSandboxStateDir = Join-Path $root 'home'
        # Skill sync has its own tests; keep it quiet here.
        Get-ChildItem -Directory (Join-Path $RepoRoot 'skills') | ForEach-Object Name |
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
        Pop-Location
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs claude in a new sandbox, then saves history and deletes it' {
        New-Item -ItemType Directory -Force (Join-Path $store 'projects/p') | Out-Null
        claude --resume 6>$null
        $calls = Get-SbxCall
        ($calls -like 'create --name *')[0] | Should -BeLike "create --name $key-???? claude $project *"
        $calls -like 'exec *setup.sh opus medium auto' | Should -Not -BeNullOrEmpty
        $calls -like 'exec * claude --resume' | Should -Not -BeNullOrEmpty
        $calls -like "cp *$key $key-????:/tmp/claude-hist" | Should -Not -BeNullOrEmpty
        $calls -like "rm --force $key-*" | Should -Not -BeNullOrEmpty
        @(Get-ChildItem $boxes) | Should -HaveCount 0
    }

    It 'takes model, effort and permission mode from the environment' {
        $env:CLAUDE_SANDBOX_MODEL = 'sonnet'
        $env:CLAUDE_SANDBOX_EFFORT = ''
        $env:CLAUDE_SANDBOX_PERMISSION_MODE = 'bypassPermissions'
        claude 6>$null
        # PowerShell can't pass an empty env var (setting '' removes it), so effort falls back.
        Get-SbxCall | Where-Object { $_ -like 'exec *setup.sh*' } | Should -BeLike '*setup.sh sonnet * bypassPermissions'
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
}
