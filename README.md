# Claude Code in Docker Sandboxes

Run Claude Code in an isolated [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`) while typing `claude` exactly as before.

- **Same commands:** `claude`, `claude --resume`, `claude -c`, `claude "fix the bug"`, ...
- **A fresh sandbox every run,** deleted when Claude exits. Packages, binaries and stray processes never touch your machine.
- **History is kept:** sessions are saved on your machine and restored into the next sandbox, so `--resume` works.
- **Old chats are searchable:** Claude can read earlier sessions from your other projects and from host Claude, read-only.
- **Any number of windows,** in the same folder or different ones. Each gets its own sandbox.
- **Your defaults:** Opus, medium effort, auto permission mode.
- **Matt Pocock's skills** are preloaded and refreshed daily.

| File | Purpose |
|---|---|
| `claude-sandbox.ps1` | PowerShell wrapper (Windows) |
| `claude-sandbox.sh` | bash/zsh wrapper (Linux, macOS, Git Bash) |
| `sandbox-setup.sh` | Runs inside each new sandbox to restore history, point Claude at earlier sessions, update Claude Code and apply defaults |
| `statusline.sh` | Status line (model, folder, branch, context %, tokens, rate limits), installed into each sandbox |

Keep all four files in the same folder.

## Quick start (Windows)

```powershell
winget install -h Docker.sbx                 # then close ALL terminal windows and open a new one
sbx login                                    # sign in to Docker (device code in the browser)
sbx policy init balanced                     # network policy
sbx secret set github -t "$(gh auth token)"  # GitHub access for git push / gh
sbx skills add mattpocock/skills             # preload skills
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
git clone https://github.com/mookeyj79/Claude-Sandbox.git                  # get the scripts
Add-Content $PROFILE "`n. $PWD\Claude-Sandbox\claude-sandbox.ps1"          # load the wrapper
```

Open a new terminal, `cd` into a project, run `claude`, then `/login` once. Each step is explained below.

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

**Linux** (Ubuntu 24.04+, with KVM) and **macOS**: see https://docs.docker.com/ai/sandboxes/install/

You don't need Docker Desktop. You do need [Git](https://git-scm.com/), to clone the scripts (`winget install -h Git.Git`).

### 2. Install `sbx`

```powershell
winget install -h Docker.sbx
```

The install is per-user and needs no admin rights. **Close every terminal window** and open a new one so `sbx` is on your PATH, then check it with `sbx version`. You need **0.51.0 or newer** for Claude to read [earlier sessions](#earlier-sessions).

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

Doing a lot of web research? [NETWORK-POLICY.md](NETWORK-POLICY.md) shows how to allow public websites while blocking private networks.

### 5. GitHub access

```
sbx secret set github -t "$(gh auth token)"
```

This copies your host GitHub CLI token into `sbx`, and its proxy then adds it to Git and `gh` traffic from every sandbox. Without it, `git push` fails with `could not read Username for 'https://github.com'` or a rejected-token error. You need the [GitHub CLI](https://cli.github.com/) installed and signed in on the host (`gh auth login`).

**Run it once, not every time.** The secret is global, and every `claude` run creates a new sandbox, so each one picks it up. `gh auth status` inside the sandbox will still say "not logged in". That's expected, because the token is added at the network level.

**Run it again if the token changes:** after you sign in again with `gh auth login`, rotate a personal access token, or the token expires or is revoked. The secret is a copy taken when you ran the command, so it doesn't follow those changes. Sandboxes that are already running keep the old token. Exit Claude and start it again to pick up the new one.

### 6. Skills

```
sbx skills add mattpocock/skills
```

This installs every skill in the repo, including drafts that the Claude plugin leaves out. Remove one with `sbx skills rm <name>`, or install only some:

```
sbx skills add mattpocock/skills --skill grilling --skill wayfinder --skill tdd
```

To also copy in skills you already have locally (`~/.claude/skills`, `~/.agents/skills`, ...), run `sbx skills import`. Add `--dry-run` first to preview. List the installed skills with `sbx skills ls`.

### 7. Get the scripts

Clone this repo anywhere you like. The next step points at that folder.

```
git clone https://github.com/mookeyj79/Claude-Sandbox.git
```

### 8. Load the wrapper

**PowerShell:** add this line to your profile (`notepad $PROFILE`), using the folder you cloned into:

```powershell
. C:\path\to\Claude-Sandbox\claude-sandbox.ps1
```

The leading `. ` (dot, space) is required. Without it the `claude` function disappears as soon as the script ends. If your profile is split into include files (such as `conf.d\*.ps1`), the line can go in one of those.

**bash / zsh / Git Bash:** add this to `~/.bashrc` or `~/.zshrc`:

```bash
source /path/to/Claude-Sandbox/claude-sandbox.sh
```

### 9. First run

```
cd D:\Dev\my-project
claude
```

- The first run downloads the sandbox image, about 430 MB. After that, a run starts in about 30 seconds, including the Claude Code update.
- Run `/login` inside Claude. You only need to **once**: `sbx` stores the login globally (`sbx secret ls` shows `anthropic (oauth configured)`), and later sandboxes start logged in.
- To use an API key instead: `sbx secret set anthropic`. The key stays in Windows Credential Manager or the OS keychain and is added by a proxy, so the sandbox never sees it.

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

An empty string keeps the sandbox's own default. For the permission mode, that default is `bypassPermissions`.

### Earlier sessions

Claude can look things up in earlier chats, including ones from other projects. Each sandbox gets two read-only mounts, and `sandbox-setup.sh` adds a note to the sandbox's `~/.claude/CLAUDE.md` saying where they are:

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
3. **Restores** that folder's history, mounts earlier sessions read-only, updates Claude Code and applies your defaults, using `sandbox-setup.sh`.
4. **Starts Claude** with `sbx exec`. It doesn't use `sbx run`, because that always adds `--dangerously-skip-permissions`, which overrides any permission mode.
5. **On exit**, including Ctrl+C, copies the history back out and deletes the sandbox. If the save fails, it warns you and stops the sandbox instead, so the next run can retry.

**History store:** `%LOCALAPPDATA%\claude-sandbox\history\` on Windows (shared by PowerShell and Git Bash), or `~/.local/share/claude-sandbox/history/` on Linux/macOS. There's one folder per project, holding session files (`projects/`) and prompt history (`history.jsonl`). Delete a project's folder to forget its history.

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
- **`sbx`:** `winget upgrade Docker.sbx`
- **These scripts:** run `git pull` in the folder you cloned. The next `claude` run uses the new versions (open a new terminal first, so the wrapper reloads).

## Limitations

- **Host `~/.claude` isn't used:** global settings, status line, plugins, MCP servers and memory stay on the host. Project-level config in the repo (`.claude/`, `CLAUDE.md`, `.mcp.json`) *is* used.
- **Separate history:** `--resume` doesn't mix host and sandboxed sessions, or sessions from different folders. Claude can still [read them](#earlier-sessions).
- **Pasting images** is off by default. Turn it on with `sbx settings set clipboard.imagePaste true`.
- **Linux only inside:** Windows tools (`powershell.exe`, host `.exe` files) aren't available.
- **Blocked traffic:** local-network UDP (mDNS/SSDP) and ICMP (`ping`).

## Troubleshooting

| Problem | Fix |
|---|---|
| `sbx: command not found` after installing | Close **all** terminal windows and open a new one. |
| `claude` starts normal Claude | `Get-Command claude` shows `Application`, so the wrapper isn't loaded. Check the profile line, including the leading `. `. |
| `error: not signed in to Docker` | `sbx login` |
| `git push` fails: `could not read Username`, or the GitHub token is rejected | On the host: `sbx secret set github -t "$(gh auth token)"`, then exit and restart `claude`. If the token itself expired, run `gh auth login` first. |
| Requests to a site fail or hang | `sbx policy approval ls`, or `sbx policy allow network <host>` |
| "not a tty" errors in Git Bash | Use Git Bash inside Windows Terminal, not the old mintty window. |
| `couldn't mount earlier sessions` on startup | `sbx` rejected the read-only mounts, so Claude started without them and the rest works as normal. The message includes the reason. These mounts need `sbx` 0.51.0 or newer, so check `sbx version` first and upgrade if it's older (`winget upgrade Docker.sbx` on Windows). |
| `couldn't save history from <name>` | The sandbox was kept so its sessions aren't lost, and each `claude` run retries the save. If it keeps failing and you don't need those sessions, run `sbx rm --force <name>`. |
| `--resume` shows no sessions | Check that the history store has a folder for this project and that `sandbox-setup.sh` is next to the wrapper. |
| Anything else | `sbx diagnose`. As a last resort, `sbx reset` deletes all sandboxes **and your stored login**. Saved history isn't affected. |

## Uninstall

1. Remove the wrapper line from your PowerShell profile or `~/.bashrc`.
2. `sbx reset` deletes all sandboxes, secrets and the network policy. Then run `winget uninstall Docker.sbx`.
3. Optionally delete the saved history (`%LOCALAPPDATA%\claude-sandbox\`), `~/.claude-sandbox-skills-updated` and the folder you cloned.

## Issues

Report bugs and requests in [GitHub Issues](https://github.com/mookeyj79/Claude-Sandbox/issues).

## License

[MIT](LICENSE)
