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
# Defaults (override per shell, or set to 'unset' to keep the sandbox's own default):
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

$script:ClaudeSandboxStateDir      = $HOME   # skill-sync markers; tests point this elsewhere
$script:ClaudeSandboxSkillTimeoutSec = 120

function Sync-ClaudeSandboxSkill {
    # Skill sync: make sure every skill in this repo's skills/ is installed in sbx, and refresh
    # installed skills at most once a day. Never stops Claude from starting: a failed or stuck
    # install prints how to retry, and the next run tries again.
    # State in $script:ClaudeSandboxStateDir: .claude-sandbox-skills-added (installed skills, one
    # per line) and .claude-sandbox-skills-updated (time of the last refresh).
    param([string]$RepoDir)
    $added = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-added'
    $stamp = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-updated'
    $sbx   = (Get-Command sbx -CommandType Application | Select-Object -First 1).Source

    # `sbx skills update` won't install new skills, only refresh installed ones, so a skill
    # added to the repo by `git pull` is installed here.
    $have = @(if (Test-Path $added) { Get-Content $added })
    $missing = @(Get-ChildItem -Directory (Join-Path $RepoDir 'skills') -ErrorAction SilentlyContinue |
        ForEach-Object Name | Where-Object { $have -notcontains $_ })
    # Empty stdin and a time limit: if sbx asks a question, it gets no answer instead of
    # waiting forever behind hidden output, and Claude still starts.
    # One skill per call. If the skill is already installed (say, by an earlier manual
    # `sbx skills add`), sbx asks "Overwrite?" and, with no terminal to answer, fails with
    # "stdin is not a terminal". With a single named skill that question is the only one it
    # can ask, so the skill is there and counts as installed.
    foreach ($skill in $missing) {
        $in  = New-TemporaryFile
        $log = New-TemporaryFile
        $err = New-TemporaryFile
        try {
            $p = Start-Process $sbx -ArgumentList 'skills', 'add', 'mookeyj79/Claude-Sandbox', '--skill', $skill -NoNewWindow -PassThru `
                -RedirectStandardInput $in -RedirectStandardOutput $log -RedirectStandardError $err
            $null = $p.Handle   # without this, ExitCode can come back empty
            if (-not $p.WaitForExit($script:ClaudeSandboxSkillTimeoutSec * 1000)) {
                # Whole tree: sbx (or a .cmd shim) may have started children that hold the logs open.
                try { $p.Kill($true) } catch { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
                $null = $p.WaitForExit(5000)
                Write-Host "claude-sandbox: installing skill $skill took over $($script:ClaudeSandboxSkillTimeoutSec)s, skipped." -ForegroundColor Yellow
                $timedOut = $true
            } else {
                $timedOut = $false
            }
            $out = (Get-Content $log, $err -Raw -ErrorAction SilentlyContinue) -join ''
            if (-not $timedOut -and ($p.ExitCode -eq 0 -or $out -match 'not a terminal')) {
                Add-Content -Path $added -Value $skill
            } else {
                if ($out) { Write-Host $out.TrimEnd() }
                Write-Host "claude-sandbox: couldn't install skill $skill, will retry next run. To try now: sbx skills add mookeyj79/Claude-Sandbox --skill $skill" -ForegroundColor Yellow
            }
        } finally {
            Remove-Item $in, $log, $err -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddHours(-24)) {
        Set-Content -Path $stamp -Value (Get-Date -Format o)
        Start-Process $sbx -ArgumentList 'skills', 'update' -WindowStyle Hidden
    }
}

# ---- History store ------------------------------------------------------------------------
# Session history lives on the host, one folder per project, so --resume works across
# throwaway sandboxes. Callers only need: Get-ClaudeSandboxProjectKey, Get-ClaudeSandboxNewName,
# Push-ClaudeSandboxHistory, Close-ClaudeSandbox (and Move-ClaudeSandboxLegacyHistory, for now).
# The sandbox name carries the project key, so a leftover sandbox can be traced to its folder.

function Get-ClaudeSandboxProjectKey {
    # Project key for a folder: claude-<leaf>-<hash>. Must match the bash wrapper exactly, since
    # Git Bash and PowerShell share the history store (see tests/project-keys.tsv).
    param([string]$Path, [switch]$Legacy)
    $norm = ($Path -replace '/', '\').TrimEnd('\')
    # Lowercase A-Z only, as Git Bash's `tr` does. Before this matched, PowerShell lowercased
    # every letter (-Legacy), so a path with non-ASCII capitals got a different key.
    $norm = if ($Legacy) { $norm.ToLowerInvariant() }
            else { [regex]::Replace($norm, '[A-Z]', { param($m) $m.Value.ToLowerInvariant() }) }
    $sha  = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    $hash = (-join ($sha[0..3] | ForEach-Object { '{0:x2}' -f $_ }))
    $leaf = $norm.Substring($norm.LastIndexOfAny([char[]]'\/') + 1) -replace '[^a-z0-9-]+', '-'
    $leaf = $leaf.Trim('-')
    if ($leaf.Length -gt 24) { $leaf = $leaf.Substring(0, 24).TrimEnd('-') }
    if (-not $leaf) { $leaf = 'root' }
    "claude-$leaf-$hash"
}

function Move-ClaudeSandboxLegacyHistory {
    # One-time move of a project's history saved under its -Legacy key (see
    # Get-ClaudeSandboxProjectKey), so --resume still finds it. Only when the new folder doesn't
    # exist yet; otherwise both are left alone.
    param([string]$Path)
    $new = Join-Path $script:ClaudeSandboxStore (Get-ClaudeSandboxProjectKey $Path)
    $old = Join-Path $script:ClaudeSandboxStore (Get-ClaudeSandboxProjectKey $Path -Legacy)
    if ($old -ne $new -and (Test-Path $old) -and -not (Test-Path $new)) {
        Move-Item $old $new -ErrorAction SilentlyContinue
    }
}

function Get-ClaudeSandboxNewName {
    # A fresh sandbox name for a project: <key>-<4 random chars>, so several windows can share a folder.
    param([string]$Key)
    "$Key-" + (-join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ }))
}

function Get-ClaudeSandboxProject {
    # The project key a sandbox belongs to, or $null if the sandbox isn't one of ours.
    # (Names without the random part come from older versions of the wrappers.)
    param([string]$Sandbox)
    if ($Sandbox -cmatch '^(claude-.+-[0-9a-f]{8})(-[a-z0-9]{4})?$') { $Matches[1] } else { $null }
}

function Push-ClaudeSandboxHistory {
    # Copy the project's saved history into a new sandbox, where sandbox-setup.sh restores it.
    param([string]$Sandbox)
    $store = Join-Path $script:ClaudeSandboxStore (Get-ClaudeSandboxProject $Sandbox)
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    & sbx cp $store "${Sandbox}:/tmp/claude-hist" *> $null
}

function Save-ClaudeSandboxHistory {
    # Copy a sandbox's session history into the store for its project. Returns $false if anything
    # went wrong. A missing projects/ folder counts as a failure: sandbox-setup.sh always creates
    # it, so missing means the copy didn't work.
    param([string]$Sandbox)
    $store = Join-Path $script:ClaudeSandboxStore (Get-ClaudeSandboxProject $Sandbox)
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

function Close-ClaudeSandbox {
    # Close a sandbox: save its history, then delete it. If the save fails the sandbox is kept,
    # stopped, so the next run's sweep retries it; nothing is lost. Returns $true if deleted.
    param([string]$Sandbox)
    if (Save-ClaudeSandboxHistory $Sandbox) {
        & sbx rm --force $Sandbox *> $null
        return $true
    }
    & sbx stop $Sandbox *> $null
    Write-Host "claude-sandbox: WARNING: couldn't save history from $Sandbox, so the sandbox was kept. The next claude run will retry. To give up on it and delete it: sbx rm --force $Sandbox" -ForegroundColor Yellow
    return $false
}

function Invoke-ClaudeSandboxSweep {
    # Sweep: close sandboxes left behind (window closed with X, crash).
    # Only *stopped* ones are touched; a running one may belong to another open window.
    $list = & sbx ls --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    foreach ($s in @($list)) {
        if ($s.status -ne 'stopped' -or -not (Get-ClaudeSandboxProject $s.name)) { continue }
        Write-Host "claude-sandbox: cleaning up leftover sandbox $($s.name)" -ForegroundColor DarkGray
        $null = Close-ClaudeSandbox $s.name
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

    Sync-ClaudeSandboxSkill $script:ClaudeSandboxDir
    Invoke-ClaudeSandboxSweep

    $path = (Get-Location).ProviderPath
    Move-ClaudeSandboxLegacyHistory $path
    $name = Get-ClaudeSandboxNewName (Get-ClaudeSandboxProjectKey $path)

    # Unset: the default. Set but empty (PowerShell 7.5+ can hold that): 'unset', meaning leave
    # the sandbox's own setting. Never pass '' itself: PowerShell drops empty arguments to
    # native commands, which would shift the rest along.
    $model  = if ($null -eq $env:CLAUDE_SANDBOX_MODEL)           { 'opus' }   elseif ($env:CLAUDE_SANDBOX_MODEL)           { $env:CLAUDE_SANDBOX_MODEL }           else { 'unset' }
    $effort = if ($null -eq $env:CLAUDE_SANDBOX_EFFORT)          { 'medium' } elseif ($env:CLAUDE_SANDBOX_EFFORT)          { $env:CLAUDE_SANDBOX_EFFORT }          else { 'unset' }
    $mode   = if ($null -eq $env:CLAUDE_SANDBOX_PERMISSION_MODE) { 'auto' }   elseif ($env:CLAUDE_SANDBOX_PERMISSION_MODE) { $env:CLAUDE_SANDBOX_PERMISSION_MODE } else { 'unset' }

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
        Push-ClaudeSandboxHistory $name
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
        $null = Close-ClaudeSandbox $name
    }
}
