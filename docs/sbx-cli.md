# `sbx` as the wrappers see it

`sbx` runs only on the host, never inside a sandbox, so an agent working on the wrappers can't run it. This page is what we know about the `sbx` calls the wrappers make, captured from real output. `tests/fake-sbx/sbx` imitates it, so keep the two in step.

If you need behaviour that isn't here, ask the user to run the command on the host and paste the output. Then add it to this page in the same change.

Last captured from **0.54.0**. Minimum version: **0.51.0** (`sbx version`), the first one with the read-only mounts the wrappers add.

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

## `sbx skills rm` and `sbx skills ls`

`sbx skills rm SKILL... [-f|--force]` (aliases `remove`, `delete`) removes skills from the store; it asks for confirmation unless given `--force`. Removal reaches running sandboxes at once: their link to the skill stops resolving.

The wrappers remove a skill they installed from this repo's `skills/` once it's gone from there (deleted or renamed), so sandboxes stop loading it. What `rm` prints for a skill that isn't installed isn't captured yet; the wrappers treat any failure the same way.

`sbx skills ls` lists every installed skill and its store:

```
❯ sbx skills ls

  SKILL                             STORE
  ai-behavior-trees-utility-ai      C:\Users\mooke\AppData\Local\DockerSandboxes\sandboxes\state\agent-skills
  land                              C:\Users\mooke\AppData\Local\DockerSandboxes\sandboxes\state\agent-skills
```

## Disk usage: `sbx df`, `sbx prune`, `sbx reset`

Nearly all of sbx's disk use is under `%LOCALAPPDATA%\DockerSandboxes\sandboxes\state\sandboxd\containerd`, and most of it is cached images, not sandboxes. With one sandbox running (sbx 0.54.0), that folder held 62.7 GB: 44.6 GB of image snapshots (`io.containerd.snapshotter.v1.erofs`), 8 GB of image layers (`io.containerd.content.v1.content`) and 10 GB of block volumes. `sbx df` showed 23 images with one in use, and couldn't measure their size:

```
❯ sbx df

  TYPE            TOTAL   ACTIVE   SIZE      RECLAIMABLE
  Images          23      1        unknown   unknown
  Containers      1       1        1.285GB   0B (0%)
  Local Volumes   1       1        9.503MB   0B (0%)
```

`sbx df` also takes `--format table|json|yaml` / `--json` (JSON shape not captured). `--verbose` lists each image, container and volume. Most images are untagged old `sbx/claude` pulls; `CONTAINERS` counts stopped sandboxes too. An image shows on two rows (same IMAGE ID) when it's also tagged as a template:

```
❯ sbx df --verbose

  Images space usage
  REPOSITORY                                TAG                IMAGE ID       CREATED   SIZE      SHARED SIZE   UNIQUE SIZE   CONTAINERS
  docker.io/library/sandbox-kit-assembled   3344a263200166f7   55dabccee96c   2w        unknown   0B            unknown       0
  docker.io/sbx/claude                      <none>             55dabccee96c   2w        unknown   0B            unknown       0
  docker.io/library/sandbox-kit-assembled   8c076eb8c89a6a0d   6925fc818508   3h        unknown   0B            unknown       1
  docker.io/sbx/claude                      <none>             6925fc818508   3h        unknown   0B            unknown       1
  docker.io/sbx/claude                      <none>             01b847e74f7a   1w        unknown   25.71kB       unknown       0

  Containers space usage
  CONTAINER ID   IMAGE                                    LOCAL VOLUMES   SIZE      CREATED   STATUS    NAMES
  26fd3c64ec27   sandbox-kit-assembled:8c076eb8c89a6a0d   1               1.332GB   16m       running   claude-ai-environment-48af6ad7-7oab

  Local volumes space usage
  VOLUME NAME                                  LINKS   SIZE
  claude-ai-environment-48af6ad7-7oab-docker   1       9.503MB
```

`sbx template ls` lists only the tagged `sandbox-kit-assembled` images, but `sbx template rm TAG|DIGEST|ID` (aliases `remove`, `delete`; `-f/--force` skips the confirmation) removes any image by ID or ID prefix, untagged ones included:

```
❯ sbx template rm fd56087ae3f3

  Remove template "fd56087ae3f3"? This cannot be undone. (y/N) y

  Removed template fd56087ae3f3
```

Removing the image ID removes all of its rows. Once a day the wrappers remove every image whose rows all show 0 containers, just after creating their own sandbox, so the image it runs on is in use. sbx has no command of its own to prune images.

`sbx prune` removes only **stopped sandboxes**, never images. `--dry-run` lists them, `--force` skips the confirmation, and `--filter until=<RFC 3339 | Unix time | Go duration>` keeps sandboxes stopped more recently. It also deletes secrets scoped to each pruned sandbox.

`sbx reset` (`--force`, `--preserve-secrets`) returns sbx to a fresh install. It clears the image cache, but it also stops every sandbox, deletes all local policy rules (see [`NETWORK-POLICY.md`](../NETWORK-POLICY.md)), signs you out and deletes stored secrets unless `--preserve-secrets` is passed.

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
