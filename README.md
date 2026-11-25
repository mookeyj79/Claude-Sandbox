# Claude Code in Docker Sandboxes

[![Lint](https://github.com/mookeyj79/Claude-Sandbox/actions/workflows/lint.yml/badge.svg)](https://github.com/mookeyj79/Claude-Sandbox/actions/workflows/lint.yml)

Run Claude Code in an isolated [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`) while typing `claude` exactly as before.

- **Same commands:** `claude`, `claude --resume`, `claude -c`, `claude "fix the bug"`, ...
- **A fresh sandbox every run,** deleted when Claude exits. Packages, binaries and stray processes never touch your machine.
- **History is kept:** sessions are saved on your machine and restored into the next sandbox, so `--resume` works.
- **Old chats are searchable:** Claude can read earlier sessions from your other projects and from host Claude, read-only.
- **Any number of windows,** in the same folder or different ones. Each gets its own sandbox.
- **Your defaults:** Opus, medium effort, auto permission mode.
- **Commits as your GitHub noreply address**, so a push is never rejected for publishing a private email. Setup reads the account with `gh api user` and leaves an identity you already set.
- **Chromium, PowerShell (`pwsh`) and [prek](https://github.com/j178/prek) installed** in every sandbox before Claude starts, alongside the Claude Code update (about a minute). If an install fails, the launch says so and how to retry.
- **Skills installed for you:** [Matt Pocock's skills](https://github.com/mattpocock/skills) and this repo's own [`/clean-git`](skills/clean-git/SKILL.md), [`/clean-repo`](skills/clean-repo/SKILL.md), [`/clean-docs`](skills/clean-docs/SKILL.md), [`/create-human-guide`](skills/create-human-guide/SKILL.md), [`/land`](skills/land/SKILL.md) and [`/update-readme`](skills/update-readme/SKILL.md), refreshed daily.

| File | Purpose |
|---|---|
| `claude-sandbox.ps1` | PowerShell wrapper (Windows) |
| `claude-sandbox.sh` | bash/zsh wrapper (Linux, macOS, Git Bash) |
| `sandbox/` | Everything that runs inside the sandbox. The wrappers copy it into each new sandbox. |
| `sandbox/setup.sh` | Prepares each new sandbox: restores history, points Claude at earlier sessions, adds the sandbox's working rules to `~/.claude/CLAUDE.md` and moves the image's rarely needed guidance (network, git auth, workspace mode) to `~/.claude/sbx-reference.md` behind a pointer list, sets the git identity, installs Chromium, PowerShell and prek, updates Claude Code and applies defaults. The defaults are set here. |
| `sandbox/statusline.sh` | Status line (model, folder, branch, context %, tokens, rate limits), installed into each sandbox |
| `skills/` | Skills this repo adds to every sandbox, installed by the wrappers on the first run after each one appears |
| `tests/` | Tests for both wrappers, run against a fake `sbx` (needs Python 3): `tests/check.sh` runs ShellCheck and bats as CI does; `Invoke-Pester tests` (Pester 5) on Windows |
| `docs/sbx-cli.md` | Real `sbx` output the wrappers depend on, for working on them from inside a sandbox, where `sbx` isn't available |
| `GLOSSARY.md` | The terms the code and docs use (project key, history store, sweep, ...) |
| `CODING_STANDARDS.md` | What a review checks beyond the linters: both wrappers changed together, real `sbx` behaviour, messages that show the wrapper's commit |
| `.githooks/` | Optional pre-commit lint: `git config core.hooksPath .githooks` |

Keep these files and `skills/` together, as the clone leaves them: the wrappers look for the others next to themselves.

**Contents:** [New system](#new-system-what-you-do-what-happens-on-its-own) · [Setup](#setup) · [Skills](#skills) · [Verify it's working](#verify-its-working) · [Usage](#usage) · [How it works](#how-it-works) · [Managing sandboxes](#managing-sandboxes) · [Updating](#updating) · [Limitations](#limitations) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall)

## New system: what you do, what happens on its own

### You do this once

First check the [requirements](#1-requirements). On Windows, that means Windows Hypervisor Platform must be enabled. On Linux, it means KVM must be available.

**Windows (PowerShell):**

```powershell
# 1. Tools. Then close ALL terminal windows and open a new one, so they're on your PATH.
winget install -h Docker.sbx
winget install -h Git.Git
winget install -h GitHub.cli

# 2. Sign in (each opens a browser)
gh auth login                                # GitHub, on your machine
sbx login                                    # Docker

# 3. Sandbox settings, shared by every sandbox
sbx policy init balanced                     # network policy
sbx secret set github -t "$(gh auth token)"  # lets sandboxes git push and use gh

# 4. Get the scripts and load the wrapper in every new terminal
git clone https://github.com/mookeyj79/Claude-Sandbox.git
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content $PROFILE "`n. $PWD\Claude-Sandbox\claude-sandbox.ps1"
```

**Linux:** step 1 depends on your package manager. The rest is the same everywhere.

*1a. `apt`: Ubuntu 24.04+ or Debian 13*

```bash
# Git, and the GitHub CLI from GitHub's own repository. The gh in Ubuntu's and Debian's
# repositories (2.45/2.46) no longer works with GitHub's API.
sudo apt update && sudo apt install -y git curl
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt update && sudo apt install -y gh

# sbx on Ubuntu: from Docker's apt repository, so `apt upgrade` keeps it current
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt install -y docker-sbx

# sbx on Debian: Docker's repository has no sbx for Debian, so install the release package instead
deb=DockerSandboxes-linux-$(dpkg --print-architecture)-ubuntu2404.deb
curl -fLo "/tmp/$deb" "https://github.com/docker/sbx-releases/releases/latest/download/$deb"
sudo apt install -y "/tmp/$deb"
```

*1b. `dnf`: Fedora, or RHEL 9+ and its rebuilds (Rocky, Alma)*

```bash
# Git and the GitHub CLI. On Fedora, gh is in the distro's repositories:
sudo dnf install -y git gh
# On RHEL, Rocky or Alma, it isn't, so add GitHub's repository instead:
sudo dnf install -y git 'dnf-command(config-manager)'
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh

# sbx: Docker publishes an .rpm but no dnf repository
sudo dnf install -y "https://github.com/docker/sbx-releases/releases/latest/download/DockerSandboxes-linux-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')-rockylinux8.rpm"
```

*2–5. Every distro*

```bash
# 2. Let your user start VMs: sbx runs each sandbox as a KVM microVM
sudo usermod -aG kvm "$USER"                 # then log out and back in (or reboot)
sbx version                                  # 0.51.0 or newer

# 3. Sign in (each opens a browser)
gh auth login                                # GitHub, on your machine
sbx login                                    # Docker

# 4. Sandbox settings, shared by every sandbox
sbx policy init balanced                     # network policy
sbx secret set github -t "$(gh auth token)"  # lets sandboxes git push and use gh

# 5. Get the scripts and load the wrapper in every new terminal
git clone https://github.com/mookeyj79/Claude-Sandbox.git
echo "source $PWD/Claude-Sandbox/claude-sandbox.sh" >> ~/.bashrc   # or ~/.zshrc
```

Other distros (Arch, openSUSE, Debian 12, ...): see [Install `sbx`](#2-install-sbx) for the tarball.

**macOS (Sonoma 14+, Apple silicon):** `brew trust docker/tap && brew install docker/tap/sbx git gh`, then steps 3–5 above.

**Then, in a new terminal:**

```
cd <some project>
claude          # first run downloads the sandbox image (~430 MB)
/login          # inside Claude, once. Later sandboxes start signed in.
```

Setup is done. Check it worked with [Verify it's working](#verify-its-working). The [Setup](#setup) section below explains each step.

### Every `claude` run does this for you

| What | When |
|---|---|
| Installs [Matt Pocock's skills](https://github.com/mattpocock/skills) and this repo's [skills](#skills) | First run. A new skill in this repo is installed on the next run after a `git pull`. |
| Refreshes installed skills | At most once a day, in the background |
| Saves and deletes sandboxes left over from earlier runs | Every run |
| Creates a fresh sandbox, restores this folder's history, mounts earlier sessions read-only | Every run |
| Updates Claude Code, sets Opus / medium effort / auto mode, installs the status line | Every run, inside the sandbox |
| Saves history back to your machine and deletes the sandbox | When Claude exits |

### You redo these only when something changes

| When | Run |
|---|---|
| Your GitHub token changes (new `gh auth login`, expired or rotated token) | `sbx secret set github -t "$(gh auth token)"` |
| You want a newer version of these scripts | `git pull` in the cloned folder, then open a new terminal |
| A site you need is blocked | `sbx policy allow network <host>` |
| `sbx` itself is out of date | See [Updating](#updating) |

---

## Setup

### 1. Requirements

**Windows 11** (Home is fine), 64-bit Intel/AMD, with **Windows Hypervisor Platform** enabled:

```powershell
(Get-CimInstance Win32_OptionalFeature -Filter "Name='HypervisorPlatform'").InstallState   # 1 = enabled
```

If it isn't, run this from an **elevated** PowerShell and reboot:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
```

**Linux**, 64-bit Intel/AMD or Arm, with **KVM**. Docker supports Ubuntu 24.04+ and publishes packages for Ubuntu and Rocky Linux 8. The steps below also cover Debian 13, Fedora and RHEL 9+ (and Rocky, Alma), which use those same packages. If Linux itself runs in a VM, that VM needs nested virtualization. Check KVM:

```bash
ls -l /dev/kvm          # must exist
lsmod | grep kvm        # kvm_intel, kvm_amd or kvm (Arm)
```

If `/dev/kvm` is missing, turn on virtualization (Intel VT-x / AMD-V, sometimes called SVM) in the BIOS/UEFI. Then add yourself to the `kvm` group, and log out and back in so it applies:

```bash
sudo usermod -aG kvm "$USER"
id -nG | grep -w kvm    # after logging back in: prints your groups, including kvm
```

**macOS:** Sonoma 14 or newer, on Apple silicon.

You don't need Docker Desktop or Docker Engine. You do need [Git](https://git-scm.com/), to clone the scripts, and the [GitHub CLI](https://cli.github.com/), signed in with `gh auth login`, for [GitHub access](#5-github-access). The [quick start](#you-do-this-once) installs both for each OS. On Ubuntu and Debian, install `gh` from GitHub's repository as shown there: the `gh` in the distro's own repositories (2.45/2.46) no longer works with GitHub's API.

### 2. Install `sbx`

You need **0.51.0 or newer** for Claude to read [earlier sessions](#earlier-sessions). Check with `sbx version` after installing.

**Windows:**

```powershell
winget install -h Docker.sbx
```

The install is per-user and needs no admin rights. **Close every terminal window** and open a new one so `sbx` is on your PATH.

**Ubuntu 24.04+ (`apt`):** from Docker's apt repository. The script only adds the repository; it doesn't install Docker Engine.

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt install -y docker-sbx
```

**Debian 13 (`apt`):** Docker's Debian repository doesn't carry `sbx`, but its Ubuntu 24.04 package installs on Debian 13. It needs glibc 2.39, so it doesn't work on Debian 12: use the tarball below there.

```bash
deb=DockerSandboxes-linux-$(dpkg --print-architecture)-ubuntu2404.deb
curl -fLo "/tmp/$deb" "https://github.com/docker/sbx-releases/releases/latest/download/$deb"
sudo apt install -y "/tmp/$deb"
```

**Fedora, RHEL 9+, Rocky, Alma (`dnf`):** Docker publishes an `.rpm` (built on Rocky Linux 8) but no dnf repository, so `dnf upgrade` won't update it. See [Updating](#updating).

```bash
sudo dnf install -y "https://github.com/docker/sbx-releases/releases/latest/download/DockerSandboxes-linux-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')-rockylinux8.rpm"
```

**Any other Linux (tarball):** installs into `~/.docker/sbx` without root. Docker doesn't test these distros. The package needs `dbus-daemon`, so install it with your package manager if it isn't already there.

```bash
arch=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
mkdir -p /tmp/sbx && curl -fL "https://github.com/docker/sbx-releases/releases/latest/download/DockerSandboxes-linux-$arch.tar.gz" | tar xz -C /tmp/sbx
/tmp/sbx/docker-sbx/install.sh
echo 'export PATH="$HOME/.docker/sbx/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc; then open a new terminal
```

**macOS:**

```bash
brew trust docker/tap
brew install docker/tap/sbx
```

### 3. Sign in to Docker

```
sbx login
```

### 4. Network policy

```
sbx policy init balanced
```

| Preset | Meaning |
|---|---|
| `balanced` (recommended) | Blocks everything except a standard list of AI APIs, package managers, code hosts and registries |
| `allow-all` | No restrictions |
| `deny-all` | Nothing until you allow it |

Allow a host with `sbx policy allow network example.com`. See blocked requests waiting for approval with `sbx policy approval ls`. Undo the preset with `sbx policy reset`.

Doing a lot of web research, or need Claude to reach a service on your machine? [NETWORK-POLICY.md](NETWORK-POLICY.md) shows how to allow public websites and your machine's localhost while blocking the rest of your local network.

### 5. GitHub access

```
sbx secret set github -t "$(gh auth token)"
```

This copies your host GitHub CLI token into `sbx`, and its proxy then adds it to Git and `gh` traffic from every sandbox. Without it, `git push` fails with `could not read Username for 'https://github.com'` or a rejected-token error. You need the [GitHub CLI](https://cli.github.com/) installed and signed in on the host (`gh auth login`).

**Run it once, not every time.** The secret is global, and every `claude` run creates a new sandbox, so each one picks it up. `gh auth status` inside the sandbox will still say "not logged in". That's expected, because the token is added at the network level.

**Run it again if the token changes:** after you sign in again with `gh auth login`, rotate a personal access token, or the token expires or is revoked. The secret is a copy taken when you ran the command, so it doesn't follow those changes. Sandboxes that are already running keep the old token. Exit Claude and start it again to pick up the new one.

### 6. Get the scripts

Clone this repo anywhere you like. The next step points at that folder.

```
git clone https://github.com/mookeyj79/Claude-Sandbox.git
```

### 7. Load the wrapper

**PowerShell:** add this line to your profile (`notepad $PROFILE`), using the folder you cloned into:

```powershell
. C:\path\to\Claude-Sandbox\claude-sandbox.ps1
```

The leading `. ` (dot, space) is required. Without it the `claude` function disappears as soon as the script ends. If your profile is split into include files (such as `conf.d\*.ps1`), the line can go in one of those.

**bash / zsh / Git Bash:** add this to `~/.bashrc` or `~/.zshrc`:

```bash
source /path/to/Claude-Sandbox/claude-sandbox.sh
```

### 8. First run

```
cd D:\Dev\my-project
claude
```

- The first run downloads the sandbox image, about 430 MB. After that, a run starts in about 30 seconds, including the Claude Code update.
- Run `/login` inside Claude. You only need to **once**: `sbx` stores the login globally (`sbx secret ls` shows `anthropic (oauth configured)`), and later sandboxes start logged in.
- To use an API key instead: `sbx secret set anthropic`. The key stays in Windows Credential Manager or the OS keychain and is added by a proxy, so the sandbox never sees it.

## Skills

There's nothing to set up. The first time you run `claude`, the wrapper installs these into `sbx`, so every sandbox has them:

- **All of [Matt Pocock's skills](https://github.com/mattpocock/skills)** (`mattpocock/skills`), including drafts that the Claude plugin leaves out.
- **This repo's own skills:**

| Skill | What it does |
|---|---|
| `/clean-git` | Merges open PRs that are ready (not a draft, no conflicts, checks passing), then removes dead worktrees and merged branches. Keeps anything with unpushed or unmerged work and reports it. |
| `/clean-repo` | Tidies the files on disk: deletes leftover junk (OS and editor files, merge leftovers, logs, stale build output), untracks junk that was committed, and adds `.gitignore` patterns so it stays out. Never deletes anything it can't identify as junk, runs the repo's checks afterwards, and leaves the change uncommitted for you to review. |
| `/clean-docs` | Cleans AI leftovers out of the docs people read: the agent explaining its own choices, decision records and "alternatives considered" inside a guide, echoed prompts and notes-to-self. Decisions worth keeping move to `docs/adr/` or the agent docs (`CLAUDE.md`, `docs/agents/`); the rest is deleted. Claude can also run it on its own when a doc reads like an agent's notes. Leaves the change uncommitted for you to review. |
| `/create-human-guide` | For the `ready-for-human` issues: tasks Claude can't do for you, because they need your machine, a login, a secret, a browser or your decision. Turns them all into one step-by-step guide so you can clear them in one sitting: tasks in dependency order, copy-paste commands checked against the repo, where to run each one, how to confirm it worked, and how to close the issue. Writes `human-guide.md` and leaves it uncommitted. |
| `/land` | Commits the current work, opens a PR (or uses the one already open), waits for CI on that commit, then squash-merges and updates your local default branch. Stops without merging if a check fails. |
| `/update-readme` | Writes or refreshes the project's README as a complete GitHub/GitLab front page: overview, install, usage, configuration, development, license. Checks every command, link and badge against the repo, and leaves the change uncommitted for you to review. |

This happens silently. If an install fails, you'll see a message, and it's retried on the next run. Installed skills are refreshed at most once a day. A new skill in this repo is installed on the next run after a `git pull`. A skill added to `mattpocock/skills` after the first install isn't picked up by the refresh, so run `sbx skills add mattpocock/skills` to get it.

To remove one of the installed skills, run `sbx skills rm <name>`. It stays removed, because the wrapper installs each skill and skill repo only once.

To also copy in skills you already have locally (`~/.claude/skills`, `~/.agents/skills`, ...), run `sbx skills import`. Add `--dry-run` first to preview. List the installed skills with `sbx skills ls`.

## Verify it's working

| Check | Sandboxed | Not sandboxed |
|---|---|---|
| `Get-Command claude` (PowerShell) / `type claude` (bash) | `Function` / `claude is a function` | `Application` / a file path |
| On launch | `claude-sandbox: starting claude-<folder>-<hash>-<id>` | nothing |
| `! echo $SANDBOX_NAME` inside Claude | `claude-my-project-1a2b3c4d-x7k2` | empty |
| `! whoami` inside Claude | `agent` | your username |
| `sbx ls` in another terminal | sandbox listed as `● running` | nothing |

## Usage

| Command | What happens |
|---|---|
| `claude` | Fresh sandbox for this folder, history restored, Claude starts. Deleted on exit. |
| `claude --resume` / `claude -c` | Resume an earlier session from this folder. |
| `claude "do X"` | Start with a prompt. |
| `claude.exe ...` (PowerShell) / `command claude ...` (bash) | Run the real Claude Code on the host. |
| `$env:CLAUDE_NO_SANDBOX='1'` / `export CLAUDE_NO_SANDBOX=1` | Use the host for the rest of this shell session. |

### Defaults

New sandboxes start with **Opus, medium effort, auto mode**. A flag overrides these for one run (`claude --model sonnet`), and so do in-session changes (`/model`, Shift+Tab). To change the defaults, set these in your profile (bash: `export ...`):

```powershell
$env:CLAUDE_SANDBOX_MODEL           = 'opus'      # any model alias or ID
$env:CLAUDE_SANDBOX_EFFORT          = 'medium'    # low | medium | high | ...
$env:CLAUDE_SANDBOX_PERMISSION_MODE = 'auto'      # auto | bypassPermissions | default | acceptEdits | plan
```

`unset` keeps the sandbox's own default (bash also accepts an empty string). For the permission mode, that default is `bypassPermissions`. The defaults themselves are at the top of `sandbox/setup.sh`.

### Earlier sessions

Claude can look things up in earlier chats, including ones from other projects. Each sandbox gets two read-only mounts, and `sandbox/setup.sh` adds a note to the sandbox's `~/.claude/CLAUDE.md` saying where they are:

| Path in the sandbox | Contents |
|---|---|
| `/claude-history-sandbox` | The history store: sessions run in sandboxes, for every project |
| `/claude-history-host` | The host's `~/.claude/projects`: sessions run directly on the host (mounted only if the folder exists) |

Ask naturally, such as "check how we fixed this in the blog project". Other limits:

- **Reading, not resuming:** `--resume` still only finds the current folder's sessions, so run it from the project the session belongs to.
- **Open windows:** a sandbox's sessions reach the store when it exits, so a chat in a window that's still open isn't visible yet.
- **Privacy:** transcripts hold everything from those sessions, including file contents, command output and anything you pasted, so any sandboxed agent can read all of it. To keep them out, set `CLAUDE_SANDBOX_SHARE_HISTORY` to `0`. Sessions from the current folder are still restored, because `--resume` needs them.

**Why auto and not bypass?** The sandbox protects your machine, but your project folder is mounted read-write and GitHub is reachable. Auto mode runs routine work without prompts and still blocks risky actions like deleting the project or force-pushing. Choose `bypassPermissions` only if your work is always committed and pushed.

## How it works

Each `claude` run:

1. **Cleans up** stopped sandboxes left from earlier runs (for example a window closed with the X button): saves their history, then deletes them. If the save fails, it warns you and keeps the sandbox to retry on the next run.
2. **Creates** a sandbox named `claude-<folder>-<hash>-<id>`. The hash of the full path keeps `D:\Dev\api` and `D:\Work\api` apart. The random id lets several windows share a folder.
3. **Prepares** the sandbox: copies in `sandbox/` and that folder's history, then runs `sandbox/setup.sh`. Setup restores the history, adds the sandbox's working rules to Claude's instructions, sets the git identity, installs Chromium, PowerShell and prek, updates Claude Code and applies your defaults. If any of this fails, Claude isn't started and the message says why. Earlier sessions are mounted read-only when the sandbox is created.
4. **Starts Claude** with `sbx exec`. It doesn't use `sbx run`, because that always adds `--dangerously-skip-permissions`, which overrides any permission mode.
5. **On exit**, including Ctrl+C, copies the history back out and deletes the sandbox. If the save fails, it warns you and stops the sandbox instead, so the next run can retry.

**History store:** `%LOCALAPPDATA%\claude-sandbox\history\` on Windows (shared by PowerShell and Git Bash), or `~/.local/share/claude-sandbox/history/` on Linux/macOS (under `$XDG_DATA_HOME` instead, if you set it). There's one folder per project, holding session files (`projects/`) and prompt history (`history.jsonl`). Delete a project's folder to forget its history.

**Good to know:**
- Several windows on one folder never lose sessions, because session files have unique names. Only the up-arrow prompt history keeps whichever window closed last.
- Anything Claude installs inside the sandbox (apt packages, global npm/pip tools) is gone next run. Files in your project folder are kept.
- Sandboxes are microVMs, not Docker containers, so `docker ps` won't show them. Use `sbx ls`.

## Managing sandboxes

Normally there's nothing to manage. If something gets stuck:

```
sbx ls                       # list sandboxes (normally only the ones open right now)
sbx exec -it <name> bash     # shell into a running sandbox
sbx stop <name>              # stop it; the next `claude` run saves its history and removes it
sbx rm --force <name>        # delete immediately (history is NOT saved)
```

The cleanup step leaves **running** sandboxes alone, since they may belong to another open window. A sandbox can stay running after its window closes if a Claude background session is still alive in it. Stop it with `sbx stop <name>`.

## Updating

- **Skills** update automatically: the wrapper runs `sbx skills update` in the background at most once a day. To update now: `sbx skills update`.
- **Claude Code** updates inside each sandbox before it starts, so a new session is already on the latest version. If the update fails, Claude starts on the image's version.
- **`sbx`:**
  - Windows: `winget upgrade Docker.sbx`
  - Ubuntu: `sudo apt update && sudo apt upgrade docker-sbx`
  - Debian, Fedora, RHEL, tarball: these installs have no repository to update from, so run the same [install command](#2-install-sbx) again. It downloads the latest release.
  - macOS: `brew upgrade sbx`
- **These scripts:** run `git pull` in the folder you cloned. The next `claude` run uses the new versions (open a new terminal first, so the wrapper reloads).

## Limitations

- **Host `~/.claude` isn't used:** global settings, status line, plugins, MCP servers and memory stay on the host. Project-level config in the repo (`.claude/`, `CLAUDE.md`, `.mcp.json`) *is* used.
- **Separate history:** `--resume` doesn't mix host and sandboxed sessions, or sessions from different folders. Claude can still [read them](#earlier-sessions).
- **Pasting images** is off by default. Turn it on with `sbx settings set clipboard.imagePaste true`.
- **Linux only inside:** Windows tools (`powershell.exe`, host `.exe` files) aren't available. PowerShell 7 for Linux (`pwsh`) is.
- **Blocked traffic:** local-network UDP (mDNS/SSDP) and ICMP (`ping`).

## Troubleshooting

| Problem | Fix |
|---|---|
| `sbx: command not found` after installing | Close **all** terminal windows and open a new one. With the Linux tarball, check that `~/.docker/sbx/bin` is on your `PATH`. |
| Linux: sandbox won't start, with an error about `/dev/kvm` or permission denied | Check [KVM](#1-requirements): `/dev/kvm` must exist, and `id -nG` must list `kvm`. After `usermod -aG kvm`, log out and back in. |
| Ubuntu/Debian: `gh` fails with API errors | It's the distro's `gh` 2.45/2.46. Install it from GitHub's repository, as in the [quick start](#you-do-this-once). |
| A fix you pulled doesn't seem to apply | The wrapper's messages show its commit, as in `claude-sandbox (3fd4520): starting ...`. Compare it with `git -C <cloned folder> log -1 --format=%h`. If they differ, open a new terminal so the wrapper reloads. If they match and the commit is old, run `git pull` in that folder. |
| `claude` starts normal Claude | The wrapper isn't loaded: `Get-Command claude` shows `Application`, or `type claude` shows a file path. Check the profile line, including the leading `. ` (PowerShell), or the `source` line in `~/.bashrc` / `~/.zshrc`. Then open a new terminal. |
| `error: not signed in to Docker` | `sbx login` |
| `git push` fails: `could not read Username`, or the GitHub token is rejected | On the host: `sbx secret set github -t "$(gh auth token)"`, then exit and restart `claude`. If the token itself expired, run `gh auth login` first. |
| Requests to a site fail or hang | `sbx policy approval ls`, or `sbx policy allow network <host>` |
| "not a tty" errors in Git Bash | Use Git Bash inside Windows Terminal, not the old mintty window. |
| `couldn't mount earlier sessions` on startup | `sbx` rejected the read-only mounts, so Claude started without them and the rest works as normal. The message includes the reason. These mounts need `sbx` 0.51.0 or newer, so check `sbx version` first and [upgrade](#updating) if it's older. |
| `couldn't save history from <name>` | The sandbox was kept so its sessions aren't lost, and each `claude` run retries the save. If it keeps failing and you don't need those sessions, run `sbx rm --force <name>`. |
| `couldn't install skill <name>, will retry next run` | Claude still starts without that skill, and the next run tries again. To install it now, run the `sbx skills add ...` command printed in the message. If it keeps failing, check `sbx login` and that GitHub is reachable. |
| `--resume` shows no sessions | Check that the history store has a folder for this project and that the `sandbox/` folder is next to the wrapper. |
| `setting up <name> failed` or `couldn't copy setup files` | Claude wasn't started, because the sandbox wasn't fully prepared. The lines above the message say what failed. Run `claude` again; if it keeps failing, check that `sandbox/` is next to the wrapper (`git pull` brings it back). |
| Anything else | `sbx diagnose`. As a last resort, `sbx reset` deletes all sandboxes **and your stored login**. Saved history isn't affected. |

## Uninstall

1. Remove the wrapper line from your PowerShell profile or `~/.bashrc`.
2. `sbx reset` deletes all sandboxes, secrets and the network policy. Then uninstall `sbx`:
   - Windows: `winget uninstall Docker.sbx`
   - `apt`: `sudo apt remove docker-sbx`
   - `dnf`: `sudo dnf remove docker-sbx`
   - Tarball: `rm -rf ~/.docker/sbx`, and remove the `PATH` line from `~/.bashrc`
   - macOS: `brew uninstall sbx`
3. Optionally delete the saved history (`%LOCALAPPDATA%\claude-sandbox\` on Windows, `~/.local/share/claude-sandbox/` on Linux/macOS), `~/.claude-sandbox-skills-updated`, `~/.claude-sandbox-skills-added` and the folder you cloned.

## Issues

Report bugs and requests in [GitHub Issues](https://github.com/mookeyj79/Claude-Sandbox/issues).

## License

[MIT](LICENSE)
