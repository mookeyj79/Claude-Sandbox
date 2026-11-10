# `sbx` as the wrappers see it

`sbx` runs only on the host, never inside a sandbox, so an agent working on the wrappers can't run it. This page is what we know about the `sbx` calls the wrappers make, captured from real output. `tests/fake-sbx/sbx` imitates it, so keep the two in step.

If you need behaviour that isn't here, ask the user to run the command on the host and paste the output. Then add it to this page in the same change.

Minimum version: **0.51.0** (`sbx version`), the first one with the read-only mounts the wrappers add.

## `sbx skills add`

```
❯ sbx skills add --help

  EXPERIMENTAL: this command may change or be removed in future releases.

  Description:
    Install skills from a Git repository for use in Docker Sandboxes. The
    repository must contain one or more valid SKILL.md files.

    All discovered skills are installed when --skill is omitted. Use --skill one
    or more times, or pass a comma-separated list, to install only named skills.
    Replacing an installed skill requires confirmation; use --force to skip
    prompts.

    The repository can be specified as a Git URL or as GitHub owner/repository
    shorthand. Skills installed with this command can later be refreshed with
    'sbx skills update'.

  Usage:
    sbx skills add REPOSITORY [flags]

  Flags:
    -f, --force               Overwrite existing skills without prompting
    -h, --help                help for add
    -s, --skill stringArray   Add only the named skill (repeatable or comma-separated)

  Global Flags:
        --cloud      Dispatch to Docker Cloud Sandboxes API instead of local sandboxd
    -D, --debug      Enable debug logging
        --no-input   Never prompt; commands that need an answer fail with the command to run instead
```

**Already installed:** `sbx` asks before replacing each skill:

```
❯ sbx skills add mookeyj79/Claude-Sandbox

  Overwrite "clean-git"? (y/N) y

  Replaced skill clean-git

  Overwrite "update-readme"? (y/N) y

  Replaced skill update-readme
  Added 2 skills into C:\Users\mooke\AppData\Local\DockerSandboxes\sandboxes\state\agent-skills
  Sandboxes sharing skills read-only link store entries at start, so a newly stored skill appears there after their next start; read-write sandboxes see it immediately. Agents may also scan skills only on startup.
```

How that question fails with no one to answer it:

| Run as | Output | Exit |
|---|---|---|
| stdin not a terminal (no `--no-input`) | `error: stdin is not a terminal; run this command in a terminal to answer the prompt` | non-zero |
| `--no-input` | `error: prompts are disabled by --no-input; run without --no-input to answer the prompt` | 1 |

With stdin attached to a console and output hidden, it waits for an answer forever. That was the 30-minute launch hang fixed in #8.

The wrappers install one skill (or one whole repo) per call with `--no-input`. Overwriting is the only question `sbx skills add --skill <name>` asks, so the `--no-input` error means the skill is already installed.

## `sbx skills update`

Re-downloads every skill installed with `sbx skills add` from the repo it came from. It **doesn't** add skills that were never installed, which is why the wrappers install new repo skills themselves (#11).

## `sbx ls`

The table, real output. A stopped sandbox has a hollow `○`, a running one `●`. The STATUS column holds both the dot and the word, so with plain whitespace splitting the word is field 3 or 4.

```
❯ sbx ls

  SANDBOX                               AGENT    STATUS      PORTS   WORKSPACE                                                                                               CREATED
  claude-claude-sandbox-a2047990-vsqj   claude   ● running           D:\Dev\Claude-Sandbox, C:\Users\mooke\AppData\Local\claude-sandbox\history:/claude-history-sandbox:ro   48m
  stop-test                             claude   ○ stopped           C:\Users\mooke
```

`sbx ls --json` (the PowerShell wrapper reads `name` and `status`):

```json
[
  {
    "name": "stop-test",
    "id": "f0754bfc-9847-4e8c-ad4a-7a8002107bc9",
    "agent": "claude",
    "status": "stopped",
    "last_used_at": "2026-11-09T20:58:47.2102051Z",
    "mounts": [
      "C:\\Users\\mooke:/c/Users/mooke",
      "C:\\Users\\mooke\\AppData\\Local\\DockerSandboxes\\sandboxes\\state\\agent-skills:/home/agent/.claude/skills:ro"
    ],
    "workspaces": [
      "C:\\Users\\mooke"
    ],
    "created_at": "2026-11-09T20:58:32Z"
  }
]
```

## Not captured yet

The wrappers also call these. Their behaviour is known only from the wrappers working in practice, not from captured `--help` or error output:

- `sbx create --name <name> claude <workspace> [<host>:<path>:ro ...]`: the extra mounts fail on `sbx` older than 0.51.0, and the wrappers retry without them.
- `sbx cp <src> <dest>`: one side is `<sandbox>:<path>`. Files copied in arrive owned by root.
- `sbx exec [-it] <sandbox> <command...>`: used instead of `sbx run`, which always adds `--dangerously-skip-permissions`.
- `sbx stop <sandbox>` and `sbx rm --force <sandbox>`.
- `sbx policy ...`: see [`NETWORK-POLICY.md`](../NETWORK-POLICY.md).
