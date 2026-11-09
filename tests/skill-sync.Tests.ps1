# Skill sync: Sync-ClaudeSandboxSkill <repo-dir>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'Sync-ClaudeSandboxSkill' {
    BeforeEach {
        $root  = Initialize-FakeSbx
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $script:ClaudeSandboxStateDir = Join-Path $root 'home'
        $repo  = Join-Path $root 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'skills/alpha'), (Join-Path $repo 'skills/beta') | Out-Null
        $added = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-added'
        $stamp = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-updated'
        # Most tests aren't about the daily refresh: make it look recent.
        Set-Content $stamp (Get-Date -Format o)
    }
    AfterEach { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'installs every repo skill and records it' {
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-Content $added | Should -Be @('alpha', 'beta')
        Get-SbxCall | Should -Be @(
            'skills add mookeyj79/Claude-Sandbox --skill alpha',
            'skills add mookeyj79/Claude-Sandbox --skill beta')
    }

    It 'skips skills already recorded' {
        Set-Content $added 'alpha'
        Sync-ClaudeSandboxSkill $repo
        Get-SbxCall | Should -Be @('skills add mookeyj79/Claude-Sandbox --skill beta')
        Get-Content $added | Should -Be @('alpha', 'beta')
    }

    It "counts a skill sbx won't overwrite without a terminal as installed" {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'notty'
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-Content $added | Should -Be @('alpha', 'beta')
    }

    It 'reports a failed install, does not record it, and retries next run' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'fail'
        $out = (Sync-ClaudeSandboxSkill $repo 6>&1) -join "`n"
        $out | Should -Match 'network error'
        $out | Should -Match "couldn't install skill alpha, will retry next run"
        Get-Content $added | Should -Be @('beta')

        Remove-Item (Join-Path $env:FAKE_SBX_DIR 'skill-alpha')
        Sync-ClaudeSandboxSkill $repo
        Get-Content $added | Should -Be @('beta', 'alpha')
    }

    It 'cuts off a stuck install at the time limit' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'hang'
        $script:ClaudeSandboxSkillTimeoutSec = 2
        $t = [Diagnostics.Stopwatch]::StartNew()
        $out = (Sync-ClaudeSandboxSkill $repo 6>&1) -join "`n"
        $t.Elapsed.TotalSeconds | Should -BeLessThan 15
        $out | Should -Match 'installing skill alpha took over 2s, skipped\.'
        $out | Should -Match "couldn't install skill alpha"
        Get-Content $added | Should -Be @('beta')
    }

    It 'does nothing when the repo has no skills' {
        Remove-Item (Join-Path $repo 'skills/*') -Recurse
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-SbxCall | Should -BeNullOrEmpty
    }

    It 'refreshes installed skills when the last refresh is over a day old' {
        Set-Content $added 'alpha', 'beta'
        (Get-Item $stamp).LastWriteTime = (Get-Date).AddDays(-2)
        Sync-ClaudeSandboxSkill $repo
        foreach ($i in 1..25) { if (Get-SbxCall) { break }; Start-Sleep -Milliseconds 200 }
        Get-SbxCall | Should -Be @('skills update')
        (Get-Item $stamp).LastWriteTime | Should -BeGreaterThan (Get-Date).AddMinutes(-1)
    }

    It "doesn't refresh twice in a day" {
        Set-Content $added 'alpha', 'beta'
        Sync-ClaudeSandboxSkill $repo
        Start-Sleep -Milliseconds 500
        Get-SbxCall | Should -BeNullOrEmpty
    }
}
