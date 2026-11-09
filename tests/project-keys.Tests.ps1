# The PowerShell wrapper gives the project keys in project-keys.tsv.
# tests/project-keys.bats checks the bash wrapper against the same file.

BeforeDiscovery {
    $cases = Get-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'project-keys.tsv') |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object { $p, $k = $_ -split "`t"; @{ Path = $p; Key = $k } }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $null = Initialize-FakeSbx
    . (Join-Path $RepoRoot 'claude-sandbox.ps1')
}

Describe 'Get-ClaudeSandboxProjectKey' {
    It '<Path> is <Key>' -ForEach $cases {
        Get-ClaudeSandboxProjectKey $Path | Should -BeExactly $Key
    }
}
