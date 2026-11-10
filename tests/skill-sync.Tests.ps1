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
        Get-Content $added | Should -Be @('alpha', 'beta', 'mattpocock/skills')
        Get-SbxCall | Should -Be @(
            'skills add mookeyj79/Claude-Sandbox --skill alpha --no-input',
            'skills add mookeyj79/Claude-Sandbox --skill beta --no-input',
            'skills add mattpocock/skills --no-input')
    }

    It 'skips skills already recorded' {
        Set-Content $added 'alpha', 'mattpocock/skills'
        Sync-ClaudeSandboxSkill $repo
        Get-SbxCall | Should -Be @('skills add mookeyj79/Claude-Sandbox --skill beta --no-input')
        Get-Content $added | Should -Be @('alpha', 'mattpocock/skills', 'beta')
    }

    It "counts a skill that is already installed as installed" {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'exists'
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-Content $added | Should -Be @('alpha', 'beta', 'mattpocock/skills')
    }

    It 'reports a failed install, does not record it, and retries next run' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'fail'
        $out = (Sync-ClaudeSandboxSkill $repo 6>&1) -join "`n"
        $out | Should -Match 'network error'
        $out | Should -Match "couldn't install skill alpha, will retry next run"
        Get-Content $added | Should -Be @('beta', 'mattpocock/skills')

        Remove-Item (Join-Path $env:FAKE_SBX_DIR 'skill-alpha')
        Sync-ClaudeSandboxSkill $repo
        Get-Content $added | Should -Be @('beta', 'mattpocock/skills', 'alpha')
    }

    It 'cuts off a stuck install at the time limit' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-alpha') 'hang'
        $script:ClaudeSandboxSkillTimeoutSec = 2
        $t = [Diagnostics.Stopwatch]::StartNew()
        $out = (Sync-ClaudeSandboxSkill $repo 6>&1) -join "`n"
        $t.Elapsed.TotalSeconds | Should -BeLessThan 15
        $out | Should -Match 'installing skill alpha took over 2s, skipped\.'
        $out | Should -Match "couldn't install skill alpha"
        Get-Content $added | Should -Be @('beta', 'mattpocock/skills')
    }

    It 'installs only the skill repos when the repo has no skills' {
        Remove-Item (Join-Path $repo 'skills/*') -Recurse
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-SbxCall | Should -Be @('skills add mattpocock/skills --no-input')
    }

    It 'installs mattpocock/skills once, whole' {
        Set-Content $added 'alpha', 'beta'
        Sync-ClaudeSandboxSkill $repo
        Get-SbxCall | Should -Be @('skills add mattpocock/skills --no-input')
        Sync-ClaudeSandboxSkill $repo
        Get-SbxCall | Should -Be @('skills add mattpocock/skills --no-input')
    }

    It 'counts mattpocock/skills added by hand as installed' {
        Set-Content $added 'alpha', 'beta'
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-mattpocock__skills') 'exists'
        Sync-ClaudeSandboxSkill $repo 6>&1 | Should -BeNullOrEmpty
        Get-Content $added | Should -Be @('alpha', 'beta', 'mattpocock/skills')
    }

    It 'reports a failed mattpocock/skills install with the retry command' {
        Set-Content $added 'alpha', 'beta'
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'skill-mattpocock__skills') 'fail'
        $out = (Sync-ClaudeSandboxSkill $repo 6>&1) -join "`n"
        $out | Should -Match "couldn't install skill mattpocock/skills, will retry next run\. To try now: sbx skills add mattpocock/skills"
        Get-Content $added | Should -Be @('alpha', 'beta')
    }

    It 'refreshes installed skills when the last refresh is over a day old' {
        Set-Content $added 'alpha', 'beta', 'mattpocock/skills'
        (Get-Item $stamp).LastWriteTime = (Get-Date).AddDays(-2)
        Sync-ClaudeSandboxSkill $repo
        foreach ($i in 1..25) { if (Get-SbxCall) { break }; Start-Sleep -Milliseconds 200 }
        Get-SbxCall | Should -Be @('skills update')
        (Get-Item $stamp).LastWriteTime | Should -BeGreaterThan (Get-Date).AddMinutes(-1)
    }

    It "doesn't refresh twice in a day" {
        Set-Content $added 'alpha', 'beta', 'mattpocock/skills'
        Sync-ClaudeSandboxSkill $repo
        Start-Sleep -Milliseconds 500
        Get-SbxCall | Should -BeNullOrEmpty
    }
}
