# =============================================================================
#  install.ps1: the install for Windows (see GLOSSARY.md).
#
#    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mookeyj79/Claude-Sandbox/main/install.ps1)))
#
#  or from a clone: powershell -ExecutionPolicy Bypass -File install.ps1
#  Runs in Windows PowerShell 5.1 or PowerShell 7.
#
#    1. Windows Hypervisor Platform must be on; when it isn't, says how and stops
#    2. tools with winget: PowerShell 7, Git, the GitHub CLI and sbx
#    3. the clone: the one this script runs from, else CLAUDE_SANDBOX_DIR
#       (default ~\Claude-Sandbox), cloned when absent, fast-forwarded when not
#    4. sign-ins: gh auth login and sbx login, each only when not signed in
#    5. sandbox settings: sbx policy init balanced when there is no global
#       policy yet, and the github secret as the command 'gh auth token'
#    6. the wrapper in new shells: a marked block in Nowhere's local override
#       (~\.config\nowhere\local.ps1, with a 'goto cs' bookmark) when Nowhere is
#       bootstrapped, else in PowerShell 7's profile, even when run from 5.1
#       (docs/adr/0003-install-is-nowhere-aware-not-nowhere-dependent.md)
#
#  Safe to re-run: a step that is already done is skipped, and the block is
#  rewritten in place. Steps 4 and 5 never stop the install: what they couldn't
#  do is listed at the end, with the commands to run. Anything else that fails
#  stops it with an error, without closing the window.
#
#  CLAUDE_SANDBOX_REPO points it at another remote. The tests move the home
#  folder and PowerShell 7's profile with CLAUDE_SANDBOX_HOME and
#  CLAUDE_SANDBOX_PROFILE. Keep this file ASCII: 5.1 reads it as ANSI.
# =============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Tag = 'claude-sandbox install'
$Repo = if ($env:CLAUDE_SANDBOX_REPO) { $env:CLAUDE_SANDBOX_REPO } else { 'https://github.com/mookeyj79/Claude-Sandbox.git' }
$InstallHome = if ($env:CLAUDE_SANDBOX_HOME) { $env:CLAUDE_SANDBOX_HOME } else { $HOME }
$BeginMark = '# >>> claude-sandbox >>>'
$EndMark = '# <<< claude-sandbox <<<'
$SbxMin = [version]'0.51.0'
$Left = New-Object System.Collections.Generic.List[string]   # commands left for you, listed at the end

function Write-Step([string]$Message) { Write-Host "==> $Message" }
function Write-InstallWarning([string]$Message) { Write-Host "${Tag}: $Message" -ForegroundColor Yellow }
function Exit-Install([string]$Message) { throw "${Tag}: $Message" }

function Invoke-Quiet {
    # Runs a command with its output and errors captured as text. Windows PowerShell turns
    # redirected stderr into errors, which would stop the script, so errors don't stop here.
    param([scriptblock]$Command)
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $text = & $Command 2>&1 | ForEach-Object { "$_" } | Out-String
    [pscustomobject]@{ Output = $text; ExitCode = $global:LASTEXITCODE }
}

function Test-Tool([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Add-RegistryPath {
    # winget puts new tools on the machine and user PATH; pick them up in this session too.
    $sep = [IO.Path]::PathSeparator
    foreach ($scope in 'Machine', 'User') {
        $value = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not $value) { continue }
        foreach ($dir in ([Environment]::ExpandEnvironmentVariables($value) -split ';')) {
            if ($dir -and (($env:PATH -split $sep) -notcontains $dir)) { $env:PATH = $env:PATH + $sep + $dir }
        }
    }
}

function Install-WingetTool([string]$Command, [string]$Id) {
    if (Test-Tool $Command) { return }
    Write-Step "installing $Id with winget"
    $global:LASTEXITCODE = 0
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Exit-Install "winget couldn't install $Id (exit $LASTEXITCODE); run: winget install --id $Id --exact, then re-run"
    }
    Add-RegistryPath
    if (-not (Test-Tool $Command)) { Exit-Install "$Id is installed, but $Command isn't on PATH yet; open a new terminal and re-run" }
}

# --- Platform -------------------------------------------------------------------------
if (-not (Test-Tool winget)) {
    Exit-Install "winget not found. Install App Installer from the Microsoft Store, or follow the README's Setup by hand."
}

# --- 1. Windows Hypervisor Platform ---------------------------------------------------
Write-Step 'checking Windows Hypervisor Platform'
$feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='HypervisorPlatform'"
if (-not $feature -or $feature.InstallState -ne 1) {
    Exit-Install "Windows Hypervisor Platform is off, and sbx needs it. From an elevated PowerShell run: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All ; then reboot and re-run."
}

# --- 2. Tools -------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) { Install-WingetTool pwsh Microsoft.PowerShell }
Install-WingetTool git Git.Git
Install-WingetTool gh GitHub.cli
Install-WingetTool sbx Docker.sbx
$sbxVersion = (Invoke-Quiet { sbx version }).Output
if ($sbxVersion -match '(\d+\.\d+\.\d+)' -and [version]$Matches[1] -lt $SbxMin) {
    Write-InstallWarning "sbx $($Matches[1]) is older than $SbxMin, which the wrappers need; update it (README: Updating)"
}

# --- 3. The clone ---------------------------------------------------------------------
$self = $null
if ($PSCommandPath) {
    $here = Split-Path -Parent $PSCommandPath
    if (Test-Path -LiteralPath (Join-Path $here 'claude-sandbox.ps1')) { $self = $here }
}
if ($self) {
    $Dir = $self
    Write-Step "using the clone at $Dir"
} else {
    $Dir = if ($env:CLAUDE_SANDBOX_DIR) { $env:CLAUDE_SANDBOX_DIR } else { Join-Path $InstallHome 'Claude-Sandbox' }
    if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
        Write-Step "updating $Dir"
        $r = Invoke-Quiet { git -C $Dir pull --ff-only }
        if ($r.ExitCode -ne 0) { Write-Host $r.Output; Exit-Install "couldn't fast-forward $Dir; sort it out by hand, then re-run" }
    } elseif (Test-Path -LiteralPath $Dir) {
        Exit-Install "$Dir exists and isn't a git clone; move it or set CLAUDE_SANDBOX_DIR, then re-run"
    } else {
        Write-Step "cloning Claude-Sandbox into $Dir"
        $r = Invoke-Quiet { git clone $Repo $Dir }
        if ($r.ExitCode -ne 0) { Write-Host $r.Output; Exit-Install 'git clone failed; fix the error above and re-run' }
    }
    $Dir = (Resolve-Path -LiteralPath $Dir).ProviderPath
}
$Wrapper = Join-Path $Dir 'claude-sandbox.ps1'
if (-not (Test-Path -LiteralPath $Wrapper)) { Exit-Install "$Dir has no claude-sandbox.ps1; is it a Claude-Sandbox clone?" }

# --- 4. Sign-ins ----------------------------------------------------------------------
if ((Invoke-Quiet { gh auth status }).ExitCode -eq 0) {
    Write-Step 'GitHub: signed in'
} else {
    Write-Step 'signing in to GitHub (gh auth login)'
    $global:LASTEXITCODE = 0
    gh auth login
    if ($LASTEXITCODE -ne 0) { Write-InstallWarning "gh auth login didn't finish" }
}
$ghOk = (Invoke-Quiet { gh auth status }).ExitCode -eq 0
if (-not $ghOk) { $Left.Add('gh auth login') }

# sbx has no status command; sbx diagnose reports both the sign-in and the global policy.
function Get-SbxDiagnosis { (Invoke-Quiet { sbx diagnose }).Output }
$authPattern = '(?m)Authentication\s+\S+\s+authenticated\s*$'
$policyPattern = '(?m)Global network policy\s+\S+\s+initialized\s*$'

Write-Step 'checking sbx (sbx diagnose)'
$diagnosis = Get-SbxDiagnosis
if ($diagnosis -match $authPattern) {
    Write-Step 'Docker: signed in'
} else {
    Write-Step 'signing in to Docker (sbx login)'
    $global:LASTEXITCODE = 0
    sbx login
    if ($LASTEXITCODE -eq 0) { $diagnosis = Get-SbxDiagnosis } else { Write-InstallWarning "sbx login didn't finish" }
}

# --- 5. Sandbox settings --------------------------------------------------------------
$secretCmd = "sbx secret set github --command 'gh auth token' -f"
if ($diagnosis -notmatch $authPattern) {
    $Left.Add('sbx login')
    $Left.Add('sbx policy init balanced   # skip it if sbx diagnose says the global network policy is initialized')
    $Left.Add($secretCmd)
} else {
    if ($diagnosis -match $policyPattern) {
        Write-Step 'network policy: already set'
    } else {
        Write-Step 'setting the network policy (sbx policy init balanced)'
        $r = Invoke-Quiet { sbx policy init balanced --no-input }
        if ($r.ExitCode -ne 0) { Write-Host $r.Output; Write-InstallWarning 'sbx policy init failed'; $Left.Add('sbx policy init balanced') }
    }
    if ($ghOk) {
        # Stored as a command, so sbx reads the current token itself and a new token needs nothing.
        Write-Step "giving sandboxes GitHub access (the github secret, as 'gh auth token')"
        $r = Invoke-Quiet { sbx secret set github --command 'gh auth token' -f --no-input }
        if ($r.ExitCode -ne 0) { Write-Host $r.Output; Write-InstallWarning "couldn't store the github secret"; $Left.Add($secretCmd) }
    } else {
        $Left.Add("$secretCmd   # after gh auth login")
    }
}

# --- 6. The wrapper in new shells -----------------------------------------------------
$nowhereLocal = Join-Path $InstallHome '.config/nowhere/local.ps1'
$pwshProfile = if ($env:CLAUDE_SANDBOX_PROFILE) { $env:CLAUDE_SANDBOX_PROFILE } else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
}
function Test-Nowhere {
    if (-not (Test-Path -LiteralPath $nowhereLocal)) { return $false }
    if ($env:NOWHERE_ROLE) { return $true }
    if ($env:NOWHERE_DIR -and (Test-Path -LiteralPath (Join-Path $env:NOWHERE_DIR 'bootstrap/bootstrap.ps1'))) { return $true }
    Test-Path -LiteralPath (Join-Path $InstallHome 'Nowhere/bootstrap/bootstrap.ps1')
}
$nowhere = Test-Nowhere
if ($nowhere) {
    $target = $nowhereLocal
    $files = @($nowhereLocal, $pwshProfile)   # the profile is Nowhere's stub, which bootstrap rewrites
    Write-Step 'Nowhere found: loading the wrapper from its local override'
} else {
    $target = $pwshProfile
    $files = @($pwshProfile)
}

function Read-TextFile([string]$Path) {
    # The text, its lines (the last one without its newline), its newline and its encoding, so
    # a rewrite keeps a BOM, UTF-16 or CRLF the file already had.
    $text = ''
    $encoding = New-Object Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $Path) {
        $reader = New-Object IO.StreamReader($Path, $encoding, $true)
        try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
    }
    $newline = if ($text -match '\r\n') { "`r`n" } elseif ($text -match '\n') { "`n" } else { [Environment]::NewLine }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($text) {
        $lines.AddRange([string[]]($text -split '\r?\n'))
        if ($lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    }
    [pscustomobject]@{ Text = $text; Lines = $lines; Newline = $newline; Encoding = $encoding }
}

function Get-OutsideBlock($Lines) {
    # Each line outside our block, with its line number
    $inBlock = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $BeginMark) { $inBlock = $true; continue }
        if ($inBlock) { if ($Lines[$i] -eq $EndMark) { $inBlock = $false }; continue }
        [pscustomobject]@{ Number = $i + 1; Text = $Lines[$i] }
    }
}

function Test-SameClone([string]$Path) {
    $p = $Path
    foreach ($prefix in '~', '$HOME', '${HOME}', '$env:USERPROFILE', '$env:HOME') {
        if ($p.StartsWith($prefix + '\') -or $p.StartsWith($prefix + '/')) { $p = $InstallHome + $p.Substring($prefix.Length); break }
    }
    $d = Split-Path -Parent $p
    if (-not $d -or -not (Test-Path -LiteralPath $d)) { return $false }
    $full = { param($x) [IO.Path]::GetFullPath($x).TrimEnd('\', '/') }
    (& $full (Resolve-Path -LiteralPath $d).ProviderPath) -eq (& $full $Dir)
}

$loaded = $false
foreach ($f in $files) {
    foreach ($line in (Get-OutsideBlock (Read-TextFile $f).Lines)) {
        if ($line.Text -notmatch '^\s*\.\s+(.*claude-sandbox\.ps1)\S*\s*(#.*)?$') { continue }
        $path = $Matches[1].Trim().Trim("'", '"')
        if (-not (Test-SameClone $path)) {
            Exit-Install "$f already loads a wrapper from another clone ($path, line $($line.Number)). Remove that line, or re-run with CLAUDE_SANDBOX_DIR set to that clone."
        }
        if ($f -eq $target) {
            $loaded = $true
        } else {
            Write-InstallWarning "$f also loads the wrapper (line $($line.Number)). Nowhere's bootstrap rewrites that file, so the line will be lost then; the local override loads it now, so remove that line."
        }
    }
}

function ConvertTo-Literal([string]$s) { "'" + $s.Replace("'", "''") + "'" }
$body = New-Object System.Collections.Generic.List[string]
if ($loaded) {
    Write-Step "$target already loads the wrapper; leaving that line as it is"
} else {
    $body.Add('. ' + (ConvertTo-Literal $Wrapper))
}
if ($nowhere) {
    $body.Add('if ($NowhereGotoBookmarks -isnot [hashtable]) { $NowhereGotoBookmarks = @{} }')
    $body.Add('$NowhereGotoBookmarks[''cs''] = ' + (ConvertTo-Literal $Dir))
}
$block = @()
if ($body.Count) {
    $block = @($BeginMark, "# Written by Claude-Sandbox's install.ps1; re-running it rewrites this block.") + $body + @($EndMark)
}

# Replace our block in the file with $block (or drop it when $block is empty), keeping the rest.
$file = Read-TextFile $target
$kept = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-OutsideBlock $file.Lines)) { $kept.Add($line.Text) }
if ($block.Count) {
    if ($kept.Count -and $kept[$kept.Count - 1] -ne '') { $kept.Add('') }
    $kept.AddRange([string[]]$block)
}
$new = if ($kept.Count) { ($kept -join $file.Newline) + $file.Newline } else { '' }
if ($new -ceq $file.Text) {
    Write-Step "${target}: already up to date"
} else {
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($target, $new, $file.Encoding)
    Write-Step "${target}: wrapper block written"
}

# --- Done -----------------------------------------------------------------------------
Write-Host ''
Write-Step "Claude-Sandbox installed in $Dir"
if ($Left.Count) {
    Write-Host 'Still to do, in a terminal:'
    foreach ($c in $Left) { Write-Host "    $c" }
}
Write-Host 'Open a new PowerShell 7 window (pwsh), cd into a project and run claude. Inside Claude, run /login once.'
