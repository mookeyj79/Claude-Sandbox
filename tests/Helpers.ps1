# Shared setup for the PowerShell wrapper tests (Pester 5): a fake sbx on PATH and throwaway
# state folders. Dot-source in BeforeAll; in BeforeEach call Initialize-FakeSbx, then dot-source
# claude-sandbox.ps1 so it picks up the test's LOCALAPPDATA.

$script:RepoRoot = Split-Path $PSScriptRoot -Parent

function Initialize-FakeSbx {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("claude-sandbox-test-" + [guid]::NewGuid())
    $env:FAKE_SBX_DIR = Join-Path $root 'sbx'
    $env:LOCALAPPDATA = Join-Path $root 'localappdata'
    New-Item -ItemType Directory -Force -Path $env:FAKE_SBX_DIR, $env:LOCALAPPDATA, (Join-Path $root 'home') | Out-Null
    New-Item -ItemType File -Path (Join-Path $env:FAKE_SBX_DIR 'calls') | Out-Null
    $fake = Join-Path $script:RepoRoot 'tests/fake-sbx'
    if (-not ($env:PATH -split [IO.Path]::PathSeparator -contains $fake)) {
        $env:PATH = $fake + [IO.Path]::PathSeparator + $env:PATH
    }
    # The caller dot-sources claude-sandbox.ps1 next (doing it here would define its functions
    # in this function's scope only), then sets $script:ClaudeSandboxStateDir to "$root/home".
    $root
}

# The sbx calls made so far, arguments joined by spaces.
function Get-SbxCall {
    @(Get-Content (Join-Path $env:FAKE_SBX_DIR 'calls') | Where-Object { $_ } |
        ForEach-Object { (ConvertFrom-Json $_) -join ' ' })
}

function New-FakeSandbox {
    param([string]$Name, [string]$Status)
    $dir = Join-Path $env:FAKE_SBX_DIR "sandboxes/$Name"
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'fs') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $dir 'status') -Value $Status
}

function Set-FakeSandboxFile {
    param([string]$Name, [string]$Path, [string]$Content)
    $f = Join-Path $env:FAKE_SBX_DIR "sandboxes/$Name/fs/$($Path.TrimStart('/'))"
    New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
    Set-Content -NoNewline -Path $f -Value $Content
}
