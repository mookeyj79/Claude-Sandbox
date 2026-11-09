# Runs `claude` inside a throwaway Docker Sandbox (sbx) instead of directly on Windows.
#
# Install: add this line to your PowerShell profile (open it with `notepad $PROFILE`):
#     . C:\path\to\Claude-Sandbox\claude-sandbox.ps1
#
# Usage is unchanged: cd into a project and run `claude`, `claude --resume`, `claude "fix the bug"`, ...
#   - Every run gets a fresh sandbox that is deleted when Claude exits.
#   - Session history is saved on the host and restored into the next sandbox, so --resume works.
#   - Several windows (same or different folders) each get their own sandbox.
#
# Defaults (override per shell, or set to '' to keep the sandbox's own default):
#   $env:CLAUDE_SANDBOX_MODEL            = 'opus'
#   $env:CLAUDE_SANDBOX_EFFORT           = 'medium'
#   $env:CLAUDE_SANDBOX_PERMISSION_MODE  = 'auto'     # or 'bypassPermissions'
#
# Earlier sessions from every project are mounted read-only so Claude can look things up in them.
#   $env:CLAUDE_SANDBOX_SHARE_HISTORY    = '0'        # keep them out (this folder's own sessions are still restored)
#
# Escape hatches:
#   claude.exe ...                  run the real Claude Code on the host
#   $env:CLAUDE_NO_SANDBOX = '1'    make `claude` use the host for this shell session

$script:ClaudeSandboxDir   = $PSScriptRoot
$script:ClaudeSandboxStore = Join-Path $env:LOCALAPPDATA 'claude-sandbox\history'

function Get-ClaudeSandboxName {
    param([string]$Path)
    # Normalize like the bash wrapper does: backslashes, lowercase.
    $norm = ($Path -replace '/', '\').TrimEnd('\').ToLowerInvariant()
    $sha  = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    $hash = (-join ($sha[0..3] | ForEach-Object { '{0:x2}' -f $_ }))
    $leaf = (Split-Path $norm -Leaf) -replace '[^a-z0-9-]+', '-'
    $leaf = $leaf.Trim('-')
    if ($leaf.Length -gt 24) { $leaf = $leaf.Substring(0, 24).TrimEnd('-') }
    if (-not $leaf) { $leaf = 'root' }
    "claude-$leaf-$hash"
}

function Save-ClaudeSandboxHistory {
    # Copy a sandbox's session history into the host store for its project.
    # Returns $false if anything went wrong, in which case the sandbox must not be deleted.
    param([string]$Sandbox, [string]$Base)
    $store = Join-Path $script:ClaudeSandboxStore $Base
    $tmp   = Join-Path ([IO.Path]::GetTempPath()) "claude-sandbox-$Sandbox"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp, (Join-Path $store 'projects') | Out-Null
    $ok = $true
    & sbx cp "${Sandbox}:/home/agent/.claude/projects" (Join-Path $tmp 'projects') *> $null
    if ($LASTEXITCODE -ne 0) { $ok = $false }
    # Not checked: history.jsonl doesn't exist until the first prompt is typed.
    & sbx cp "${Sandbox}:/home/agent/.claude/history.jsonl" (Join-Path $tmp 'history.jsonl') *> $null
    Remove-Item (Join-Path $tmp 'projects\lost+found') -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $tmp 'projects')) {
        # Merge (session files have unique names, so concurrent windows don't clobber each other)
        robocopy (Join-Path $tmp 'projects') (Join-Path $store 'projects') /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { $ok = $false }   # robocopy: 0-7 mean success, 8 and up mean failure
        $global:LASTEXITCODE = 0
    } else {
        $ok = $false
    }
    if (Test-Path (Join-Path $tmp 'history.jsonl')) {
        try { Copy-Item (Join-Path $tmp 'history.jsonl') $store -Force -ErrorAction Stop }
        catch { $ok = $false }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $ok
}

function Write-ClaudeSandboxKeptWarning {
    param([string]$Sandbox)
    Write-Host "claude-sandbox: WARNING: couldn't save history from $Sandbox, so the sandbox was kept. The next claude run will retry. To give up on it and delete it: sbx rm --force $Sandbox" -ForegroundColor Yellow
}

function Invoke-ClaudeSandboxSweep {
    # Sandboxes left behind (window closed with X, crash): save their history, then delete them.
    # A sandbox whose save fails stays stopped, so the next run retries it.
    # Only *stopped* ones are touched; a running one may belong to another open window.
    $list = & sbx ls --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    foreach ($s in @($list)) {
        if ($s.status -ne 'stopped') { continue }
        if ($s.name -match '^(claude-.+-[0-9a-f]{8})(-[a-z0-9]{4})?$') {
            Write-Host "claude-sandbox: cleaning up leftover sandbox $($s.name)" -ForegroundColor DarkGray
            if (Save-ClaudeSandboxHistory $s.name $Matches[1]) {
                & sbx rm --force $s.name *> $null
            } else {
                Write-ClaudeSandboxKeptWarning $s.name
            }
        }
    }
}

function claude {
    if ($env:CLAUDE_NO_SANDBOX -eq '1') {
        $real = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $real.Source @args
        return
    }
    if (-not (Get-Command sbx -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Error "claude-sandbox: 'sbx' not found. Install with: winget install -h Docker.sbx  (or use claude.exe)"
        return
    }

    # Install this repo's skills (skills/) that aren't installed yet, so a skill added to the
    # repo is picked up after `git pull`. The marker lists the installed skills, one per line.
    # `sbx skills update` won't do this: it only refreshes skills that are already installed.
    # Retried on the next run if it fails.
    $added = Join-Path $HOME '.claude-sandbox-skills-added'
    $have = @(if (Test-Path $added) { Get-Content $added })
    $missing = @(Get-ChildItem -Directory (Join-Path $script:ClaudeSandboxDir 'skills') -ErrorAction SilentlyContinue |
        ForEach-Object Name | Where-Object { $have -notcontains $_ })
    if ($missing.Count -gt 0) {
        $skillArgs = @($missing | ForEach-Object { '--skill', $_ })
        Write-Host "claude-sandbox: installing skills from mookeyj79/Claude-Sandbox: $($missing -join ' ')" -ForegroundColor DarkGray
        # Empty stdin and a time limit: if sbx asks a question, it gets no answer instead of
        # waiting forever behind hidden output, and Claude still starts.
        $in  = New-TemporaryFile
        $log = New-TemporaryFile
        $err = New-TemporaryFile
        try {
            $p = Start-Process sbx -ArgumentList (@('skills', 'add', 'mookeyj79/Claude-Sandbox') + $skillArgs) -NoNewWindow -PassThru `
                -RedirectStandardInput $in -RedirectStandardOutput $log -RedirectStandardError $err
            $null = $p.Handle   # without this, ExitCode can come back empty
            if (-not $p.WaitForExit(120000)) {
                $p | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Host "claude-sandbox: skill install took over 2 minutes, skipped." -ForegroundColor Yellow
            }
            if ($p.HasExited -and $p.ExitCode -eq 0) {
                Add-Content -Path $added -Value $missing
            } else {
                Get-Content $log, $err | Write-Host
                Write-Host "claude-sandbox: couldn't install skills, will retry next run. To try now: sbx skills add mookeyj79/Claude-Sandbox $($skillArgs -join ' ')" -ForegroundColor Yellow
            }
        } finally {
            Remove-Item $in, $log, $err -ErrorAction SilentlyContinue
        }
    }

    # Refresh skills added with `sbx skills add` at most once a day, in the background.
    $stamp = Join-Path $HOME '.claude-sandbox-skills-updated'
    if (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddHours(-24)) {
        Set-Content -Path $stamp -Value (Get-Date -Format o)
        Start-Process sbx -ArgumentList 'skills', 'update' -WindowStyle Hidden
    }

    Invoke-ClaudeSandboxSweep

    $path  = (Get-Location).ProviderPath
    $base  = Get-ClaudeSandboxName $path
    $name  = "$base-" + (-join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ }))
    $store = Join-Path $script:ClaudeSandboxStore $base
    New-Item -ItemType Directory -Force -Path $store | Out-Null

    $model  = if ($null -ne $env:CLAUDE_SANDBOX_MODEL)           { $env:CLAUDE_SANDBOX_MODEL }           else { 'opus' }
    $effort = if ($null -ne $env:CLAUDE_SANDBOX_EFFORT)          { $env:CLAUDE_SANDBOX_EFFORT }          else { 'medium' }
    $mode   = if ($null -ne $env:CLAUDE_SANDBOX_PERMISSION_MODE) { $env:CLAUDE_SANDBOX_PERMISSION_MODE } else { 'auto' }

    # Read-only views of earlier sessions. sandbox-setup.sh tells Claude where they are.
    $mounts = @()
    if ($env:CLAUDE_SANDBOX_SHARE_HISTORY -ne '0') {
        $mounts += "${script:ClaudeSandboxStore}:/claude-history-sandbox:ro"
        $hostSessions = Join-Path $HOME '.claude\projects'
        if (Test-Path $hostSessions) { $mounts += "${hostSessions}:/claude-history-host:ro" }
    }

    Write-Host "claude-sandbox: starting $name" -ForegroundColor DarkGray
    $out = & sbx create --name $name claude $path @mounts 2>&1
    if ($LASTEXITCODE -ne 0 -and $mounts.Count -gt 0) {
        # Earlier sessions are a convenience: a bad mount shouldn't stop Claude from starting.
        Write-Host "claude-sandbox: couldn't mount earlier sessions, starting without them: $out" -ForegroundColor Yellow
        Write-Host "claude-sandbox: these mounts need sbx 0.51.0 or newer. Check with: sbx version. Upgrade with: winget upgrade Docker.sbx" -ForegroundColor Yellow
        & sbx rm --force $name *> $null
        $out = & sbx create --name $name claude $path 2>&1
    }
    if ($LASTEXITCODE -ne 0) { $out | Write-Host; return }

    try {
        & sbx cp $store "${name}:/tmp/claude-hist" *> $null
        & sbx cp (Join-Path $script:ClaudeSandboxDir 'sandbox-setup.sh') "${name}:/tmp/claude-sandbox-setup.sh" *> $null
        & sbx cp (Join-Path $script:ClaudeSandboxDir 'statusline.sh') "${name}:/tmp/claude-statusline.sh" *> $null
        & sbx exec $name bash /tmp/claude-sandbox-setup.sh $model $effort $mode

        # `sbx exec`, not `sbx run`: run always adds --dangerously-skip-permissions, which overrides
        # the permission mode set in settings.json. exec runs exactly the command we give it.
        $tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' } else { '-it' }
        & sbx exec $tty $name claude @args
    }
    finally {
        Write-Host "claude-sandbox: saving history and removing $name" -ForegroundColor DarkGray
        if (Save-ClaudeSandboxHistory $name $base) {
            & sbx rm --force $name *> $null
        } else {
            # Stopped, not left running: the sweep only retries stopped sandboxes.
            & sbx stop $name *> $null
            Write-ClaudeSandboxKeptWarning $name
        }
    }
}
