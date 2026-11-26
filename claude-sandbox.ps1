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
# Defaults: $env:CLAUDE_SANDBOX_MODEL, $env:CLAUDE_SANDBOX_EFFORT and
# $env:CLAUDE_SANDBOX_PERMISSION_MODE override the ones in sandbox/setup.sh; set one to 'unset'
# to keep the sandbox's own setting.
#
# Earlier sessions from every project are mounted read-only so Claude can look things up in them.
#   $env:CLAUDE_SANDBOX_SHARE_HISTORY    = '0'        # keep them out (this folder's own sessions are still restored)
#
# Escape hatches:
#   claude.exe ...                  run the real Claude Code on the host
#   $env:CLAUDE_NO_SANDBOX = '1'    make `claude` use the host for this shell session

$script:ClaudeSandboxDir   = $PSScriptRoot
# Prefix for the lines users paste back when something goes wrong. `claude` adds the wrapper's
# commit, so a stale checkout shows at a glance.
$script:ClaudeSandboxTag   = 'claude-sandbox'
$script:ClaudeSandboxStore = Join-Path $env:LOCALAPPDATA 'claude-sandbox\history'

$script:ClaudeSandboxStateDir      = $HOME   # skill-sync markers; tests point this elsewhere
$script:ClaudeSandboxSkillTimeoutSec = 120
# Skill repos every sandbox gets in full, besides this repo's own skills/. Each is installed
# once; after that the daily `sbx skills update` keeps it current.
$script:ClaudeSandboxSkillRepos = @('mattpocock/skills')

function Sync-ClaudeSandboxSkill {
    # Skill sync: make sure every skill in this repo's skills/, and every repo in
    # $script:ClaudeSandboxSkillRepos, is installed in sbx, and refresh installed skills at most
    # once a day. Never stops Claude from starting: a failed or stuck install prints how to
    # retry, and the next run tries again.
    # State in $script:ClaudeSandboxStateDir: .claude-sandbox-skills-added (installed skills and
    # skill repos, one per line) and .claude-sandbox-skills-updated (time of the last refresh).
    param([string]$RepoDir)
    $added = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-added'
    $stamp = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-skills-updated'
    $sbx   = (Get-Command sbx -CommandType Application | Select-Object -First 1).Source

    # `sbx skills update` won't install new skills, only refresh installed ones, so a skill
    # added to the repo by `git pull` is installed here.
    $have = @(if (Test-Path $added) { Get-Content $added })
    $missing = @(Get-ChildItem -Directory (Join-Path $RepoDir 'skills') -ErrorAction SilentlyContinue |
        ForEach-Object Name | Where-Object { $have -notcontains $_ })
    foreach ($skill in $missing) {
        Add-ClaudeSandboxSkill $sbx $added $skill @('mookeyj79/Claude-Sandbox', '--skill', $skill)
    }
    foreach ($src in $script:ClaudeSandboxSkillRepos) {
        if ($have -notcontains $src) { Add-ClaudeSandboxSkill $sbx $added $src @($src) }
    }
    Invoke-ClaudeSandboxSkillPrune $sbx $RepoDir $added

    if (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddHours(-24)) {
        Set-Content -Path $stamp -Value (Get-Date -Format o)
        Start-Process $sbx -ArgumentList 'skills', 'update' -WindowStyle Hidden
    }
}

function Invoke-ClaudeSandboxSkillPrune {
    # Remove skills this repo installed that are no longer in its skills/ (deleted or renamed),
    # or every sandbox keeps loading them from sbx's store.
    # Only bare names in the added file are this repo's skills; owner/repo lines are skill repos.
    # The name is dropped from the added file whether or not `sbx skills rm` worked, so a skill
    # that was already removed by hand isn't retried on every run; a failure prints the command.
    param([string]$Sbx, [string]$RepoDir, [string]$Added)
    $skills = Join-Path $RepoDir 'skills'
    if (-not (Test-Path $skills -PathType Container) -or -not (Test-Path $Added)) { return }
    $stale = @(Get-Content $Added | Where-Object {
        $_ -and $_ -notmatch '/' -and -not (Test-Path (Join-Path $skills $_) -PathType Container) })
    foreach ($skill in $stale) {
        $out = (& $Sbx skills rm --force $skill --no-input 2>&1 | Out-String).TrimEnd()
        if ($LASTEXITCODE -ne 0) {
            if ($out) { Write-Host $out }
            Write-Host "$($script:ClaudeSandboxTag): couldn't remove skill $skill, which is no longer in this repo. To remove it: sbx skills rm $skill" -ForegroundColor Yellow
        }
        Set-Content -Path $Added -Value @(Get-Content $Added | Where-Object { $_ -ne $skill })
    }
}

function Invoke-ClaudeSandboxImagePrune {
    # Image cleanup: sbx keeps every image it has pulled, and never deletes one, so a new
    # sbx/claude image every few days adds up to tens of GB (docs/sbx-cli.md). Once a day, remove
    # each image no sandbox uses, running or stopped. Called just after this window's sandbox is
    # created, so the image it runs on is in use and kept; otherwise a run with no other sandbox
    # would remove the current image and the next one would download it again.
    # State in $script:ClaudeSandboxStateDir: .claude-sandbox-images-pruned (time of the last cleanup).
    $stamp = Join-Path $script:ClaudeSandboxStateDir '.claude-sandbox-images-pruned'
    if ((Test-Path $stamp) -and (Get-Item $stamp -Force).LastWriteTime -gt (Get-Date).AddHours(-24)) { return }
    Set-Content -Path $stamp -Value (Get-Date -Format o)
    $ids = @(Get-ClaudeSandboxUnusedImage)
    if (-not $ids) { return }
    Write-Host "$($script:ClaudeSandboxTag): removing $($ids.Count) unused sandbox images (checked once a day)" -ForegroundColor DarkGray
    foreach ($id in $ids) {
        & sbx template rm --force --no-input $id *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "$($script:ClaudeSandboxTag): couldn't remove image $id. To try now: sbx template rm $id" -ForegroundColor Yellow
        }
    }
}

function Get-ClaudeSandboxUnusedImage {
    # Image IDs no sandbox uses, from the Images table of `sbx df --verbose`:
    # REPOSITORY TAG IMAGE-ID CREATED SIZE SHARED-SIZE UNIQUE-SIZE CONTAINERS. One image can show
    # on several rows (a tag and an untagged one); it's in use if any of them has containers.
    $on = $false
    $used = @{}
    $seen = [Collections.Generic.List[string]]::new()
    foreach ($line in @(& sbx df --verbose 2>$null)) {
        if ($line -match 'Images space usage') { $on = $true; continue }
        if ($line -match 'space usage') { $on = $false; continue }
        $f = -split $line
        if (-not $on -or $f.Count -lt 8 -or $f[2] -notmatch '^[0-9a-f]+$' -or $f[-1] -notmatch '^[0-9]+$') { continue }
        if ([int]$f[-1] -gt 0) { $used[$f[2]] = $true } elseif (-not $seen.Contains($f[2])) { $seen.Add($f[2]) }
    }
    $seen | Where-Object { -not $used.ContainsKey($_) }
}

function Add-ClaudeSandboxSkill {
    # One `sbx skills add`, recorded in the added file if it worked. $What is the name recorded
    # and reported; $SbxArgs go after `sbx skills add`.
    # Empty stdin and a time limit, so a stuck install can't keep Claude from starting.
    # Runs with --no-input. If the skill is already installed (say, by an earlier manual
    # `sbx skills add`), sbx would ask before overwriting it; --no-input makes it fail with
    # "prompts are disabled by --no-input" instead. That's the only question it asks, so the
    # skill is there and counts as installed.
    param([string]$Sbx, [string]$Added, [string]$What, [string[]]$SbxArgs)
    $in  = New-TemporaryFile
    $log = New-TemporaryFile
    $err = New-TemporaryFile
    try {
        $p = Start-Process $Sbx -ArgumentList (@('skills', 'add') + $SbxArgs + '--no-input') -NoNewWindow -PassThru `
            -RedirectStandardInput $in -RedirectStandardOutput $log -RedirectStandardError $err
        $null = $p.Handle   # without this, ExitCode can come back empty
        if (-not $p.WaitForExit($script:ClaudeSandboxSkillTimeoutSec * 1000)) {
            # Whole tree: sbx (or a .cmd shim) may have started children that hold the logs open.
            try { $p.Kill($true) } catch { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
            $null = $p.WaitForExit(5000)
            Write-Host "$($script:ClaudeSandboxTag): installing skill $What took over $($script:ClaudeSandboxSkillTimeoutSec)s, skipped." -ForegroundColor Yellow
            $timedOut = $true
        } else {
            $timedOut = $false
        }
        $out = (Get-Content $log, $err -Raw -ErrorAction SilentlyContinue) -join ''
        if (-not $timedOut -and ($p.ExitCode -eq 0 -or $out -match 'prompts are disabled by --no-input')) {
            Add-Content -Path $Added -Value $What
        } else {
            if ($out) { Write-Host $out.TrimEnd() }
            Write-Host "$($script:ClaudeSandboxTag): couldn't install skill $What, will retry next run. To try now: sbx skills add $($SbxArgs -join ' ')" -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $in, $log, $err -ErrorAction SilentlyContinue
    }
}

# ---- History store ------------------------------------------------------------------------
# Session history lives on the host, one folder per project, so --resume works across
# throwaway sandboxes. Callers only need: Get-ClaudeSandboxProjectKey, Get-ClaudeSandboxNewName,
# Initialize-ClaudeSandbox, Close-ClaudeSandbox (and Move-ClaudeSandboxLegacyHistory, for now).
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

# Where a new sandbox gets this repo's sandbox/ folder, with the project's history in history/.
# sandbox/setup.sh finds everything relative to itself, so this is the one path both sides share.
$script:ClaudeSandboxStage = '/tmp/claude-sandbox'

function ConvertTo-ClaudeSandboxSetting {
    # One user setting for sandbox/setup.sh: '-' if the variable isn't set, else '=<value>' (so
    # "set but empty", possible from PowerShell 7.5, survives as '='). Never '' itself:
    # PowerShell drops empty arguments to native commands, which would shift the rest along.
    param([AllowNull()][string]$Value, [bool]$IsSet)
    if ($IsSet) { "=$Value" } else { '-' }
}

function Initialize-ClaudeSandbox {
    # Prepare a new sandbox: copy in sandbox/ and the project's history, then run setup once.
    # Returns $false, having said why, if any step failed; Claude shouldn't start in a
    # half-prepared sandbox.
    param([string]$Sandbox)
    $store = Join-Path $script:ClaudeSandboxStore (Get-ClaudeSandboxProject $Sandbox)
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    # sandbox/ first: copied to a path that doesn't exist yet, it lands as the folder itself.
    & sbx cp (Join-Path $script:ClaudeSandboxDir 'sandbox') "${Sandbox}:$($script:ClaudeSandboxStage)" *> $null
    $ok = $LASTEXITCODE -eq 0
    if ($ok) {
        & sbx cp $store "${Sandbox}:$($script:ClaudeSandboxStage)/history" *> $null
        $ok = $LASTEXITCODE -eq 0
    }
    if (-not $ok) {
        Write-Host "$($script:ClaudeSandboxTag): ERROR: couldn't copy setup files and history into $Sandbox, so Claude wasn't started. Run claude again to retry." -ForegroundColor Red
        return $false
    }
    $settings = foreach ($v in 'CLAUDE_SANDBOX_MODEL', 'CLAUDE_SANDBOX_EFFORT', 'CLAUDE_SANDBOX_PERMISSION_MODE') {
        $item = Get-Item "env:$v" -ErrorAction SilentlyContinue
        ConvertTo-ClaudeSandboxSetting -Value $item.Value -IsSet ($null -ne $item)
    }
    & sbx exec $Sandbox bash "$($script:ClaudeSandboxStage)/setup.sh" @settings | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$($script:ClaudeSandboxTag): ERROR: setting up $Sandbox failed (see above), so Claude wasn't started. Run claude again to retry." -ForegroundColor Red
        return $false
    }
    return $true
}

function Save-ClaudeSandboxHistory {
    # Copy a sandbox's session history into the store for its project. Returns $false if anything
    # went wrong. A missing projects/ folder counts as a failure: sandbox/setup.sh always creates
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
    Write-Host "$($script:ClaudeSandboxTag): WARNING: couldn't save history from $Sandbox, so the sandbox was kept. The next claude run will retry. To give up on it and delete it: sbx rm --force $Sandbox" -ForegroundColor Yellow
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

    $rev = $null
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $rev = & git -C $script:ClaudeSandboxDir rev-parse --short HEAD 2>$null
    }
    if (-not $rev) { $rev = 'unknown' }
    $script:ClaudeSandboxTag = "claude-sandbox ($rev)"

    Sync-ClaudeSandboxSkill $script:ClaudeSandboxDir
    Invoke-ClaudeSandboxSweep

    $path = (Get-Location).ProviderPath
    Move-ClaudeSandboxLegacyHistory $path
    $name = Get-ClaudeSandboxNewName (Get-ClaudeSandboxProjectKey $path)

    # Read-only views of earlier sessions. sandbox/setup.sh tells Claude where they are.
    $mounts = @()
    if ($env:CLAUDE_SANDBOX_SHARE_HISTORY -ne '0') {
        $mounts += "${script:ClaudeSandboxStore}:/claude-history-sandbox:ro"
        $hostSessions = Join-Path $HOME '.claude\projects'
        if (Test-Path $hostSessions) { $mounts += "${hostSessions}:/claude-history-host:ro" }
    }

    Write-Host "$($script:ClaudeSandboxTag): starting $name" -ForegroundColor DarkGray
    $out = & sbx create --name $name claude $path @mounts 2>&1
    if ($LASTEXITCODE -ne 0 -and $mounts.Count -gt 0) {
        # Earlier sessions are a convenience: a bad mount shouldn't stop Claude from starting.
        Write-Host "$($script:ClaudeSandboxTag): couldn't mount earlier sessions, starting without them: $out" -ForegroundColor Yellow
        Write-Host "claude-sandbox: these mounts need sbx 0.51.0 or newer. Check with: sbx version. Upgrade with: winget upgrade Docker.sbx" -ForegroundColor Yellow
        & sbx rm --force $name *> $null
        $out = & sbx create --name $name claude $path 2>&1
    }
    if ($LASTEXITCODE -ne 0) { $out | Write-Host; return }

    try {
        Invoke-ClaudeSandboxImagePrune
        if (-not (Initialize-ClaudeSandbox $name)) { return }

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
