# Image cleanup: Remove-ClaudeSandboxUnusedImage

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
}

Describe 'Remove-ClaudeSandboxUnusedImage' {
    BeforeEach {
        $root = Initialize-FakeSbx
        . (Join-Path $RepoRoot 'claude-sandbox.ps1')
        $script:ClaudeSandboxStateDir = Join-Path $root 'home'
        $stamp = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-images-pruned'
        # Rows as `sbx df --verbose` shows them: one image can be listed tagged and untagged.
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'images') @(
            'docker.io/library/sandbox-kit-assembled 3344a263200166f7 55dabccee96c 0',
            'docker.io/sbx/claude <none> 55dabccee96c 0',
            'docker.io/library/sandbox-kit-assembled 8c076eb8c89a6a0d 6925fc818508 1',
            'docker.io/sbx/claude <none> 6925fc818508 1',
            'docker.io/sbx/claude <none> 01b847e74f7a 0',
            'docker.io/sbx/claude <none> fa91ca160b08 2')
        function Get-Removal { @(Get-SbxCall | Where-Object { $_ -like 'template rm*' }) }
    }
    AfterEach { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'removes each image no sandbox uses, once, and keeps the ones in use' {
        $out = (Remove-ClaudeSandboxUnusedImage 6>&1) -join "`n"
        $out | Should -Match 'removing 2 unused sandbox images'
        Get-Removal | Should -Be @(
            'template rm --force --no-input 55dabccee96c',
            'template rm --force --no-input 01b847e74f7a')
    }

    It 'runs at most once a day' {
        Remove-ClaudeSandboxUnusedImage 6>&1 | Out-Null
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'calls') -Value $null
        Remove-ClaudeSandboxUnusedImage 6>&1 | Should -BeNullOrEmpty
        Get-SbxCall | Should -BeNullOrEmpty

        (Get-Item $stamp -Force).LastWriteTime = (Get-Date).AddDays(-2)
        Remove-ClaudeSandboxUnusedImage 6>&1 | Out-Null
        Get-Removal | Should -Not -BeNullOrEmpty
    }

    It 'says nothing when every image is in use' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'images') 'docker.io/sbx/claude <none> 6925fc818508 1'
        Remove-ClaudeSandboxUnusedImage 6>&1 | Should -BeNullOrEmpty
        Get-Removal | Should -BeNullOrEmpty
    }

    It 'reports a failed removal with the command, and the rest still go' {
        Set-Content (Join-Path $env:FAKE_SBX_DIR 'image-55dabccee96c') 'fail'
        $out = (Remove-ClaudeSandboxUnusedImage 6>&1) -join "`n"
        $out | Should -Match "couldn't remove image 55dabccee96c. To try now: sbx template rm 55dabccee96c"
        Get-Removal | Should -Contain 'template rm --force --no-input 01b847e74f7a'
    }
}
